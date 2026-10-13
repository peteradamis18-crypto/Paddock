// Share studio (P2 of docs\PLAN-v3.md): a kept lap video becomes a SHARE video with a broadcast-style data overlay burned in -
// speed, gear, throttle / brake bars, the lap time running, the gap to his reference lap, a small track map with the car dot,
// his name / number / car / track and a small Paddock mark. 1080p60, upright (the clips carry a 180 degree flag; the copy does not
// rely on it), encoded on the graphics card (h264_nvenc; libx264 when the chip refuses).
//   The data comes from the lap's own telemetry records (60 Hz, read from the .ibt itself, not from the 1 m grid) and is tied to the
//   picture by the clip's sidecar: video time = lapStartOffset + the lap's time. Each output picture is drawn for the time of the clip
//   picture it covers (the clip's own packet times, probed with ffprobe), so the numbers are right to the frame.
//   Routes (this file): /share/make /share/status /share/video (Range) /share/open (this PC only) /share/jump (this PC only, replayjump.cs)
//   and /share/test/frame (test hook). Jobs run one at a time on a BelowNormal thread and only when he is not driving.
// Files, next to the clip: vault\clips\share-<clip id>.mp4 + .json (the name does not start with rec-, so the recorder never takes the sidecar for a clip).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    // one lap, ready to be drawn: per telemetry record the lap time and the values (read from the .ibt records themselves)
    sealed class ShareLap
    {
        public string Err = "", File = "", Name = "", Num = "", CarName = "", TrackName = "", RefKind = "";
        public int Lap, SessNum, UniqueId;
        public double LapTime, RefTime, T0;
        public double[] T, Spd, Thr, Brk, Gap, PX, PY, OutX, OutY, OutT;     // per record: lap time s, km/h, 0..1, 0..1, gap to the reference s (NaN = none), map metres east / north
        public int[] Gear;
        public bool HasRef, HasMap;

        // the record at or before t, and how far t is towards the next one (clamped at both ends)
        public void Find(double t, out int k, out double f)
        {
            int n = T.Length;
            if (t <= T[0]) { k = 0; f = 0; return; }
            if (t >= T[n - 1]) { k = n - 1; f = 0; return; }
            int lo = 0, hi = n - 1;
            while (lo + 1 < hi) { int m = (lo + hi) >> 1; if (T[m] <= t) lo = m; else hi = m; }
            k = lo; double span = T[hi] - T[lo]; f = span > 1e-9 ? (t - T[lo]) / span : 0;
        }
        public double Lerp(double[] a, int k, double f) { return k + 1 < a.Length ? a[k] + (a[k + 1] - a[k]) * f : a[k]; }
    }

    // where in the session an event is, and which session it was (for the replay jump)
    sealed class ShareEv { public string Err = ""; public int SessNum, Unique, Sub; public double SessTime; }

    static partial class Analysis
    {
        static readonly DateTime ShareEpoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        // "<file>.ibt:<lap>", a bare file name or a Vault lap id -> the telemetry file
        internal static string ShareFile(string spec, out int lapInSpec)
        {
            lapInSpec = 0;
            if (string.IsNullOrEmpty(spec) || spec.Length > 260) return null;
            Match m = Regex.Match(spec, @"^(.+\.ibt):(\d+)$", RegexOptions.IgnoreCase);
            if (m.Success) { lapInSpec = int.Parse(m.Groups[2].Value, Inv); spec = m.Groups[1].Value; }
            return ResolveFile(spec);
        }

        // a clip made by the recorder names no file: the telemetry file that was being written when the lap began (iRacing's own file name is its start time, local)
        internal static string ShareFileForClip(RecClip c)
        {
            string dir = TrackMaps.TelemetryDir;
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir) || c == null || c.LapStartMs <= 0) return null;
            DateTime lap = ShareEpoch.AddMilliseconds(c.LapStartMs).ToLocalTime();
            string best = null; DateTime bestStart = DateTime.MinValue;
            foreach (string f in Directory.GetFiles(dir, "*.ibt"))
            {
                Match m = Regex.Match(Path.GetFileName(f), @"(\d{4})-(\d\d)-(\d\d) (\d\d)-(\d\d)-(\d\d)");
                if (!m.Success) continue;
                DateTime st;
                try { st = new DateTime(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value), int.Parse(m.Groups[4].Value), int.Parse(m.Groups[5].Value), int.Parse(m.Groups[6].Value), DateTimeKind.Local); }
                catch (Exception) { continue; }
                DateTime end = File.GetLastWriteTime(f);
                if (st <= lap.AddSeconds(5) && lap <= end.AddSeconds(60) && st > bestStart) { best = f; bestStart = st; }
            }
            return best;
        }

        // everything the overlay needs about one lap, from the .ibt records (pre / post seconds around the lap: the clip starts before the line and ends after it)
        internal static ShareLap ShareCollect(string spec, RecClip clip, double pre, double post, string refSpec)
        {
            ShareLap r = new ShareLap();
            try
            {
                int hint;
                string file = spec.StartsWith("rec-", StringComparison.Ordinal) ? null : ShareFile(spec, out hint);
                if (file == null) file = ShareFileForClip(clip);
                if (file == null) { r.Err = "Telemetry file missing"; return r; }
                try { if (Career.OnlineOnly(new FileInfo(file))) { r.Err = "Telemetry file is online-only (OneDrive)"; return r; } } catch (Exception) { r.Err = "Telemetry file missing"; return r; }
                string dir = TrackMaps.TelemetryDir;
                if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) dir = Path.GetDirectoryName(file);
                List<Sess> sessions = Gather(file, dir, true);
                Sess mine = sessions[0];
                LapTrace me = null;
                foreach (LapTrace lap in mine.Laps) if (lap.Lap == clip.Lap && (me == null || lap.Clean)) me = lap;
                if (me == null || me.Tm == null || me.RecB <= me.RecA) { r.Err = "Lap " + clip.Lap + " is not a full lap"; return r; }
                double shown = me.HasOfficial ? me.Official : me.Time;
                if (clip.LapTime > 0 && Math.Abs(shown - clip.LapTime) > 0.5) { r.Err = "Video does not match the lap"; return r; }
                string kind = ""; LapTrace rf = null;
                try { rf = FindRefLap(CleanOf(sessions), me, string.IsNullOrEmpty(refSpec) ? "pb" : refSpec, sessions, null, out kind); } catch (Exception) { rf = null; }
                if (rf != null && (SameLap(rf, me) || rf.Tm == null)) rf = null;

                TrackMaps.Ibt t = TrackMaps.OpenIbt(me.Path, true);
                if (t == null) { r.Err = "Telemetry unreadable"; return r; }
                using (t.fs)
                {
                    VarDef vSt = V(t, "SessionTime"), vPct = V(t, "LapDistPct"), vSpd = V(t, "Speed"), vThr = V(t, "Throttle"), vBrk = V(t, "Brake"), vGear = V(t, "Gear"),
                           vLat = V(t, "Lat"), vLon = V(t, "Lon"), vSn = V(t, "SessionNum"), vUid = V(t, "SessionUniqueID");
                    if (vSt == null || vPct == null || vSpd == null) { r.Err = "No speed channel"; return r; }
                    int a = Math.Max(0, me.RecA - (int)Math.Ceiling(Math.Max(0, pre) * 60.0));
                    int b = (int)Math.Min(t.records, (long)me.RecB + (long)Math.Ceiling(Math.Max(0, post) * 60.0));
                    int cnt = b - a;
                    if (cnt < 10 || cnt > 30000) { r.Err = "Lap too long or too short"; return r; }
                    byte[] buf = new byte[(long)cnt * t.bufLen];
                    t.fs.Position = t.dataOff + (long)a * t.bufLen;
                    int got = 0;
                    while (got < buf.Length) { int rd = t.fs.Read(buf, got, buf.Length - got); if (rd <= 0) break; got += rd; }
                    int recs = got / t.bufLen;
                    double L = me.LengthM;
                    List<double> T = new List<double>(), Spd = new List<double>(), Thr = new List<double>(), Brk = new List<double>(), Gap = new List<double>(), Lat = new List<double>(), Lon = new List<double>();
                    List<int> Gear = new List<int>(), Rec = new List<int>();
                    for (int k = 0; k < recs; k++)
                    {
                        int o = k * t.bufLen;
                        double tl = Read(buf, o + vSt.Offset, vSt.Type) - me.T0;
                        if (T.Count > 0 && tl <= T[T.Count - 1] + 1e-6) continue;
                        double pct = Read(buf, o + vPct.Offset, vPct.Type);
                        T.Add(tl);
                        Spd.Add(Read(buf, o + vSpd.Offset, vSpd.Type) * 3.6);
                        Thr.Add(vThr != null ? Read(buf, o + vThr.Offset, vThr.Type) : 0);
                        Brk.Add(vBrk != null ? Read(buf, o + vBrk.Offset, vBrk.Type) : 0);
                        Gear.Add(vGear != null ? (int)Read(buf, o + vGear.Offset, vGear.Type) : 0);
                        double gap = double.NaN;
                        int rec = a + k;
                        if (rf != null && rec >= me.RecA && rec < me.RecB && tl >= 0 && tl <= me.Time) gap = tl - TAt(rf, Math.Max(0, Math.Min(L, pct * L)));
                        Gap.Add(gap);
                        Lat.Add(vLat != null ? Read(buf, o + vLat.Offset, vLat.Type) : 0);
                        Lon.Add(vLon != null ? Read(buf, o + vLon.Offset, vLon.Type) : 0);
                        Rec.Add(rec);
                    }
                    if (T.Count < 10) { r.Err = "Too few telemetry records"; return r; }
                    r.T = T.ToArray(); r.Spd = Spd.ToArray(); r.Thr = Thr.ToArray(); r.Brk = Brk.ToArray(); r.Gap = Gap.ToArray(); r.Gear = Gear.ToArray();
                    // the map: metres east / north of the first record of the lap (a flat projection is exact enough over one circuit)
                    int o0 = 0; for (int k = 0; k < Rec.Count; k++) if (Rec[k] >= me.RecA) { o0 = k; break; }
                    double lat0 = Lat[o0], lon0 = Lon[o0], cosl = Math.Cos(lat0 * Math.PI / 180.0);
                    bool anyGps = false; for (int k = 0; k < Lat.Count; k += 50) if (Math.Abs(Lat[k]) > 0.001 && Math.Abs(Lon[k]) > 0.001) { anyGps = true; break; }
                    r.PX = new double[T.Count]; r.PY = new double[T.Count];
                    List<double> ox = new List<double>(), oy = new List<double>(), ot = new List<double>();
                    for (int k = 0; k < T.Count; k++)
                    {
                        r.PX[k] = (Lon[k] - lon0) * 111320.0 * cosl; r.PY[k] = (Lat[k] - lat0) * 110540.0;
                        if (Rec[k] >= me.RecA && Rec[k] < me.RecB && (Rec[k] - me.RecA) % 8 == 0) { ox.Add(r.PX[k]); oy.Add(r.PY[k]); ot.Add(T[k]); }
                    }
                    r.OutX = ox.ToArray(); r.OutY = oy.ToArray(); r.OutT = ot.ToArray();
                    r.HasMap = anyGps && ox.Count > 20;
                    // who, what, where (the file's session text)
                    string y = t.yaml ?? "";
                    string meIdx = TrackMaps.YamlValue(y, "DriverCarIdx");
                    Match blk = Regex.Match(y, "- CarIdx: " + Regex.Escape(meIdx) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
                    string bl = meIdx.Length > 0 && blk.Success ? blk.Groups[1].Value : "";
                    r.Name = TrackMaps.YamlValue(bl, "UserName"); r.Num = TrackMaps.YamlValue(bl, "CarNumber"); r.CarName = TrackMaps.YamlValue(bl, "CarScreenName");
                    r.TrackName = TrackMaps.YamlValue(y, "TrackDisplayName");
                    if (r.CarName.Length == 0) r.CarName = me.Car;
                    if (r.TrackName.Length == 0) r.TrackName = me.Track;
                    r.Lap = me.Lap; r.File = Path.GetFileName(me.Path); r.T0 = me.T0;
                    r.LapTime = shown;
                    if (rf != null) { r.HasRef = true; r.RefTime = rf.HasOfficial ? rf.Official : rf.Time; r.RefKind = kind; }
                    int rk = Math.Max(0, Math.Min(recs - 1, me.RecA - a));
                    if (vSn != null) r.SessNum = (int)Read(buf, rk * t.bufLen + vSn.Offset, vSn.Type);
                    if (vUid != null) r.UniqueId = (int)Read(buf, rk * t.bufLen + vUid.Offset, vUid.Type);
                }
            }
            catch (Exception ex) { Log.W("share: reading the lap: " + ex.Message); r.Err = "Telemetry unreadable"; }
            return r;
        }

        // where an event is in the SESSION (iRacing's clock) and which session it belongs to: by lap + time into the lap, or by session time (race passes)
        internal static ShareEv ShareEvent(string spec, int lapNo, double tLap, bool hasT, double st, bool hasSt)
        {
            ShareEv ev = new ShareEv();
            try
            {
                int hint; string file = ShareFile(spec, out hint);
                if (file == null) { ev.Err = "Telemetry file missing"; return ev; }
                if (lapNo <= 0) lapNo = hint;
                TrackMaps.Ibt t = TrackMaps.OpenIbt(file, true);
                if (t == null) { ev.Err = "Telemetry unreadable"; return ev; }
                using (t.fs)
                {
                    VarDef vSt = V(t, "SessionTime"), vSn = V(t, "SessionNum"), vUid = V(t, "SessionUniqueID");
                    if (vSt == null || t.records < 2) { ev.Err = "No session clock"; return ev; }
                    double first = ShareRecord(t, 0, vSt), last = ShareRecord(t, t.records - 1, vSt);
                    if (hasT)
                    {
                        LapTrace me = null;
                        foreach (LapTrace lap in Get(file).Laps) if (lap.Lap == lapNo && (me == null || lap.Clean)) me = lap;
                        if (me == null || me.RecB <= me.RecA) { ev.Err = "Lap " + lapNo + " is not in the file"; return ev; }
                        ev.SessTime = me.T0 + tLap;
                    }
                    else if (hasSt) ev.SessTime = st;
                    else { ev.Err = "No time given."; return ev; }
                    if (ev.SessTime < first - 1 || ev.SessTime > last + 1) { ev.Err = "Moment not in the file"; return ev; }
                    int rec = (int)Math.Max(0, Math.Min(t.records - 1, (long)Math.Round((ev.SessTime - first) * 60.0)));      // 60 records a second: close enough to read the session number
                    if (vSn != null) ev.SessNum = (int)ShareRecord(t, rec, vSn);
                    if (vUid != null) ev.Unique = (int)ShareRecord(t, rec, vUid);
                    int sub; if (int.TryParse(TrackMaps.YamlValue(t.yaml ?? "", "SubSessionID"), NumberStyles.Integer, Inv, out sub)) ev.Sub = sub;
                }
            }
            catch (Exception ex) { Log.W("share: reading an event: " + ex.Message); ev.Err = "Telemetry unreadable"; }
            return ev;
        }

        static double ShareRecord(TrackMaps.Ibt t, long rec, VarDef v)
        {
            byte[] b = new byte[8]; int n = TypeSize(v.Type);
            t.fs.Position = t.dataOff + rec * t.bufLen + v.Offset;
            int got = 0; while (got < n) { int rd = t.fs.Read(b, got, n - got); if (rd <= 0) break; got += rd; }
            return got < n ? 0 : Read(b, 0, v.Type);
        }
    }

    // ---------------- the picture ----------------
    // Strip (bottom 200 px, drawn every frame) + plate (name / car / track, top left, and the Paddock mark, top right, drawn once).
    sealed class ShareDraw : IDisposable
    {
        public const int W = 1920, H = 1080, SY = 880, SH = 200, PH = 140;
        static readonly Color Gold = Color.FromArgb(242, 194, 48), Ink = Color.FromArgb(245, 245, 247), Mute = Color.FromArgb(160, 166, 176), Green = Color.FromArgb(60, 207, 126), Red = Color.FromArgb(229, 83, 75);
        readonly ShareLap D; readonly bool stripe; readonly string refWord;
        FontFamily fam; Font fGear, fSpeed, fTime, fLab, fUnit, fName, fCar, fMark, fMini, fRef;
        Bitmap bg, cur; Graphics gc;
        readonly byte[] buf = new byte[W * SH * 4];
        readonly StringFormat SF;
        readonly Dictionary<string, float> wc = new Dictionary<string, float>();
        readonly SolidBrush bInk = new SolidBrush(Ink), bGold = new SolidBrush(Gold), bMute = new SolidBrush(Mute), bGreen = new SolidBrush(Green), bRed = new SolidBrush(Red), bDim = new SolidBrush(Color.FromArgb(70, 255, 255, 255)), bBlack = new SolidBrush(Color.Black), bWhite = new SolidBrush(Color.White);
        PointF[] line; float mapX = 1692, mapY = 8, mapW = 192, mapH = 176;

        public ShareDraw(ShareLap lap, bool stripeMode)
        {
            D = lap; stripe = stripeMode;
            // the reference is never the lap itself: for the best lap it is the next best one (named by its time in the REF box)
            refWord = "GAP";   // the reference time sits beside it ("REF"), so which lap it is needs no words
            fam = PickFamily();
            fGear = F(98); fSpeed = F(104); fTime = F(78); fLab = F(15); fUnit = F(22); fName = F(40); fCar = F(22); fMark = F(26); fMini = F(13); fRef = F(46);
            SF = (StringFormat)StringFormat.GenericTypographic.Clone(); SF.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;
            cur = new Bitmap(W, SH, PixelFormat.Format32bppArgb);
            gc = Graphics.FromImage(cur); Smooth(gc);
            bg = new Bitmap(W, SH, PixelFormat.Format32bppArgb);
            BuildMap();
            BuildBackground();
        }

        static FontFamily PickFamily()
        {
            foreach (string n in new string[] { "Bahnschrift SemiBold", "Bahnschrift", "Segoe UI Semibold", "Segoe UI", "Arial" })
                try { return new FontFamily(n); } catch (Exception) { }
            return FontFamily.GenericSansSerif;
        }
        Font F(float px) { return new Font(fam, px, FontStyle.Regular, GraphicsUnit.Pixel); }
        static void Smooth(Graphics g) { g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.InterpolationMode = InterpolationMode.HighQualityBicubic; }

        float Asc(Font f) { return fam.GetCellAscent(FontStyle.Regular) * f.Size / fam.GetEmHeight(FontStyle.Regular); }
        float CW(Graphics g, Font f, char c)
        {
            string k = f.Size.ToString(CultureInfo.InvariantCulture) + "|" + c; float w;
            if (!wc.TryGetValue(k, out w)) { w = g.MeasureString(c.ToString(), f, new PointF(0, 0), SF).Width; wc[k] = w; }
            return w;
        }
        float CellW(Graphics g, Font f, char c, float cell) { return c >= '0' && c <= '9' ? cell : CW(g, f, c); }
        // a number in fixed digit cells (the digits do not jitter while they run); returns the width
        float Num(Graphics g, string s, Font f, Brush br, float x, float baseline, bool right)
        {
            float cell = CW(g, f, '0'), tot = 0;
            foreach (char c in s) tot += CellW(g, f, c, cell);
            float px = right ? x - tot : x;
            foreach (char c in s)
            {
                float w = CellW(g, f, c, cell);
                if (c != ' ') g.DrawString(c.ToString(), f, br, px + (c >= '0' && c <= '9' ? (w - CW(g, f, c)) / 2 : 0), baseline - Asc(f), SF);
                px += w;
            }
            return tot;
        }
        // small caps label with letter spacing
        float Lab(Graphics g, string s, Font f, Brush br, float x, float y, float sp, bool right)
        {
            float tot = 0; foreach (char c in s) tot += CW(g, f, c) + sp;
            float px = right ? x - tot + sp : x;
            foreach (char c in s) { if (c != ' ') g.DrawString(c.ToString(), f, br, px, y, SF); px += CW(g, f, c) + sp; }
            return tot;
        }

        void BuildMap()
        {
            if (!D.HasMap) return;
            double minx = 1e18, maxx = -1e18, miny = 1e18, maxy = -1e18;
            for (int i = 0; i < D.OutX.Length; i++) { minx = Math.Min(minx, D.OutX[i]); maxx = Math.Max(maxx, D.OutX[i]); miny = Math.Min(miny, D.OutY[i]); maxy = Math.Max(maxy, D.OutY[i]); }
            double pad = 16, bw = mapW - 2 * pad, bh = mapH - 2 * pad, sc = Math.Min(bw / Math.Max(1, maxx - minx), bh / Math.Max(1, maxy - miny));
            mx0 = minx; my1 = maxy; msc = sc; mox = mapX + pad + (bw - (maxx - minx) * sc) / 2; moy = mapY + pad + (bh - (maxy - miny) * sc) / 2;
            line = new PointF[D.OutX.Length];
            for (int i = 0; i < line.Length; i++) line[i] = MapPt(D.OutX[i], D.OutY[i]);
        }
        double mx0, my1, msc, mox, moy;
        PointF MapPt(double x, double y) { return new PointF((float)(mox + (x - mx0) * msc), (float)(moy + (my1 - y) * msc)); }

        void Panel(Graphics g, float x, float y, float w, float h, int alpha)
        {
            using (SolidBrush b = new SolidBrush(Color.FromArgb(alpha, 8, 8, 10))) g.FillRectangle(b, x, y, w, h);
            using (Pen p = new Pen(Color.FromArgb(90, Gold), 1.5f)) g.DrawRectangle(p, x, y, w, h);
            g.FillRectangle(bGold, x, y, 6, h);
        }

        void BuildBackground()
        {
            using (Graphics g = Graphics.FromImage(bg))
            {
                Smooth(g); g.Clear(Color.Transparent);
                using (LinearGradientBrush lg = new LinearGradientBrush(new Rectangle(0, 0, W, SH + 1), Color.FromArgb(0, 0, 0, 0), Color.FromArgb(150, 0, 0, 0), 90f)) g.FillRectangle(lg, 0, 0, W, SH);
                Panel(g, 36, 56, 1636, 128, 214);
                Lab(g, "GEAR", fLab, bGold, 64, 66, 3, false);
                Lab(g, "SPEED", fLab, bGold, 190, 66, 3, false);
                Lab(g, "KM/H", fUnit, bMute, 414, 152, 2, false);
                Lab(g, "THR", fMini, bMute, 520, 166, 1.5f, false);
                Lab(g, "BRK", fMini, bMute, 570, 166, 1.5f, false);
                using (Pen sep = new Pen(Color.FromArgb(40, 255, 255, 255), 1)) { g.DrawLine(sep, 626, 70, 626, 170); g.DrawLine(sep, 1090, 70, 1090, 170); if (D.HasRef) g.DrawLine(sep, 1380, 70, 1380, 170); }
                if (D.HasRef) { Lab(g, "REF", fLab, bGold, 1404, 66, 3, false); Num(g, LapStr(D.RefTime), fRef, bMute, 1404, 160, false); }
                // pedal bar frames
                using (Pen pf = new Pen(Color.FromArgb(120, 255, 255, 255), 1.5f)) { g.DrawRectangle(pf, 520, 70, 28, 92); g.DrawRectangle(pf, 570, 70, 28, 92); }
                // map card
                Panel(g, mapX, mapY, mapW, mapH, 214);
                if (D.HasMap)
                    using (Pen lp = new Pen(Color.FromArgb(120, 255, 255, 255), 3.5f)) { lp.LineJoin = LineJoin.Round; lp.StartCap = LineCap.Round; lp.EndCap = LineCap.Round; g.DrawLines(lp, line); }
                else Lab(g, "NO MAP", fLab, bMute, mapX + mapW / 2 + 36, mapY + mapH / 2 - 8, 2, true);
            }
        }

        static string LapStr(double t)
        {
            if (t < 0) t = 0;
            int ms = (int)Math.Round(t * 1000); int m = ms / 60000, s = (ms / 1000) % 60, r = ms % 1000;
            return m + ":" + (s < 10 ? "0" : "") + s + "." + (r < 10 ? "00" : r < 100 ? "0" : "") + r;
        }
        static string GearStr(int g) { return g < 0 ? "R" : g == 0 ? "N" : g.ToString(CultureInfo.InvariantCulture); }

        // BGRA bytes of the strip for lap time t (negative before the line, beyond the lap time after it)
        public byte[] Frame(double t)
        {
            int k; double fr; D.Find(t, out k, out fr);
            double spd = Math.Max(0, D.Lerp(D.Spd, k, fr)), thr = Math.Max(0, Math.Min(1, D.Lerp(D.Thr, k, fr))), brk = Math.Max(0, Math.Min(1, D.Lerp(D.Brk, k, fr)));
            int gear = D.Gear[k];
            double shown = t < 0 ? 0 : (t > D.LapTime ? D.LapTime : t);
            double gap = double.NaN;
            if (D.HasRef)
            {
                if (t >= D.LapTime) gap = D.LapTime - D.RefTime;
                else if (t > 0)
                {
                    gap = D.Lerp(D.Gap, k, fr);
                    if (double.IsNaN(gap)) gap = D.Gap[k];
                    if (double.IsNaN(gap) && k + 1 < D.Gap.Length) gap = D.Gap[k + 1];
                }
            }
            Graphics g = gc;
            g.CompositingMode = CompositingMode.SourceCopy; g.DrawImageUnscaled(bg, 0, 0); g.CompositingMode = CompositingMode.SourceOver;
            // gear and speed
            string gs = GearStr(gear);
            g.DrawString(gs, fGear, bGold, 64 + (80 - CW(g, fGear, gs[0])) / 2, 176 - Asc(fGear), SF);
            Num(g, ((int)Math.Round(spd)).ToString(CultureInfo.InvariantCulture), fSpeed, bInk, 402, 176, true);
            // pedals
            float th = (float)(92 * thr), bh = (float)(92 * brk);
            g.FillRectangle(bGreen, 520, 70 + 92 - th, 28, th);
            g.FillRectangle(bRed, 570, 70 + 92 - bh, 28, bh);
            // lap time
            Lab(g, "LAP " + D.Lap, fLab, bGold, 650, 66, 3, false);
            Num(g, LapStr(shown), fTime, t < 0 ? (Brush)bMute : bInk, 650, 160, false);
            // gap to the reference
            if (D.HasRef)
            {
                Lab(g, refWord, fLab, bGold, 1114, 66, 3, false);
                if (!double.IsNaN(gap) && Math.Abs(gap) < 100)
                {
                    string gt = (gap < -0.0005 ? "-" : "+") + Math.Abs(gap).ToString("0.000", CultureInfo.InvariantCulture);
                    Num(g, gt, fTime, gap < -0.0005 ? (Brush)bGreen : (gap > 0.0005 ? (Brush)bRed : bInk), 1114, 160, false);
                }
            }
            // the map: the driven part in gold, the car as a dot
            if (D.HasMap)
            {
                int n = 0; while (n < D.OutT.Length && D.OutT[n] <= t) n++;
                if (n >= 2)
                {
                    PointF[] part = new PointF[n]; Array.Copy(line, part, n);
                    using (Pen gp = new Pen(Gold, 4.5f)) { gp.LineJoin = LineJoin.Round; gp.StartCap = LineCap.Round; gp.EndCap = LineCap.Round; g.DrawLines(gp, part); }
                }
                PointF c = MapPt(D.Lerp(D.PX, k, fr), D.Lerp(D.PY, k, fr));
                g.FillEllipse(bBlack, c.X - 9, c.Y - 9, 18, 18);
                g.FillEllipse(bWhite, c.X - 6.5f, c.Y - 6.5f, 13, 13);
                using (Pen rp = new Pen(Gold, 2.5f)) g.DrawEllipse(rp, c.X - 9, c.Y - 9, 18, 18);
            }
            if (stripe) Stripe(g, spd, gear, thr, brk, t, gap);
            BitmapData bd = cur.LockBits(new Rectangle(0, 0, W, SH), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try { Marshal.Copy(bd.Scan0, buf, 0, buf.Length); } finally { cur.UnlockBits(bd); }
            return buf;
        }

        // test mode only: 80 black / white blocks along the bottom edge say what this picture was drawn for, so a test can read the numbers back from the video
        //   speed (km/h x 100, 17 bits) | gear + 1 (4) | throttle (x 1000, 10) | brake (x 1000, 10) | lap time ((t + 20) s in ms, 20) | gap ((gap + 30) s in ms, 16; 65535 = none) | 3 spare
        void Stripe(Graphics g, double spd, int gear, double thr, double brk, double t, double gap)
        {
            ulong[] fv = { (ulong)Math.Max(0, Math.Round(spd * 100)), (ulong)Math.Max(0, gear + 1), (ulong)Math.Round(thr * 1000), (ulong)Math.Round(brk * 1000), (ulong)Math.Max(0, Math.Round((t + 20) * 1000)),
                           double.IsNaN(gap) ? 65535UL : (ulong)Math.Max(0, Math.Min(65534, Math.Round((gap + 30) * 1000))) };
            int[] fb = { 17, 4, 10, 10, 20, 16 };
            int idx = 0;
            g.CompositingMode = CompositingMode.SourceCopy; g.SmoothingMode = SmoothingMode.None;
            for (int i = 0; i < fv.Length; i++)
                for (int bit = fb[i] - 1; bit >= 0; bit--)
                {
                    bool on = ((fv[i] >> bit) & 1UL) != 0;
                    g.FillRectangle(on ? bWhite : bBlack, 8 + idx * 18, SH - 10, 18, 10);
                    idx++;
                }
            g.CompositingMode = CompositingMode.SourceOver; g.SmoothingMode = SmoothingMode.AntiAlias;
        }

        public void SavePlate(string path)
        {
            using (Bitmap bm = new Bitmap(W, PH, PixelFormat.Format32bppArgb))
            using (Graphics g = Graphics.FromImage(bm))
            {
                Smooth(g); g.Clear(Color.Transparent);
                string name = (D.Name.Length > 0 ? D.Name : "DRIVER").ToUpperInvariant();
                string num = D.Num.Length > 0 ? "#" + D.Num : "";
                string l2 = (D.CarName + (D.CarName.Length > 0 && D.TrackName.Length > 0 ? "   |   " : "") + D.TrackName).ToUpperInvariant();
                float nw = 0; foreach (char c in name) nw += CW(g, fName, c) + 1.5f;
                float cw2 = 0; foreach (char c in l2) cw2 += CW(g, fCar, c) + 1.5f;
                float chip = num.Length > 0 ? 24 + num.Length * 24 : 0;
                float w = Math.Max(nw + (chip > 0 ? chip + 18 : 0), cw2) + 44;
                Panel(g, 36, 30, w, 92, 214);
                Lab(g, name, fName, bInk, 60, 40, 1.5f, false);
                if (chip > 0)
                {
                    g.FillRectangle(bGold, 60 + nw + 18, 44, chip, 40);
                    Lab(g, num, fName, bBlack, 60 + nw + 18 + 12, 40, 0, false);
                }
                Lab(g, l2, fCar, bMute, 60, 88, 1.5f, false);
                Lab(g, "PADDOCK", fMark, bGold, 1884, 38, 9, true);
                Lab(g, "LAP " + D.Lap + "  |  " + LapStr(D.LapTime), fCar, bInk, 1884, 74, 1.5f, true);
                bm.Save(path, ImageFormat.Png);
            }
        }

        public Bitmap Current { get { return cur; } }

        public void Dispose()
        {
            try { gc.Dispose(); cur.Dispose(); bg.Dispose(); } catch (Exception) { }
        }
    }

    // ---------------- the jobs ----------------
    sealed class ShareJob
    {
        public string Key = "", Spec = "", Ref = "", State = "queued", Reason = "", Encoder = "";
        public bool Stripe;
        public int Done, Total; public double Seconds; public long Asked;
    }

    static class Share
    {
        static readonly object gate = new object();
        static readonly List<ShareJob> jobs = new List<ShareJob>();
        static Thread worker;
        static DateTime busySince = DateTime.UtcNow; static bool lastSim;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        const int Keep = 10;          // share videos kept (the newest)

        static string Err(string m) { return "{\"error\":" + Json_.S(m) + "}"; }
        static string Q(Dictionary<string, string> q, string k) { string v; return q != null && q.TryGetValue(k, out v) && v != null ? v : ""; }
        static string N3(double d) { return d.ToString("0.000", Inv); }
        static string SharePath(RecClip c) { return Path.Combine(Recorder.ClipFolder, "share-" + c.Id + ".mp4"); }
        static string SideFile(RecClip c) { return Path.Combine(Recorder.ClipFolder, "share-" + c.Id + ".json"); }
        static bool FileOk(RecClip c)
        {
            try
            {
                string p = SharePath(c);
                return File.Exists(p) && File.Exists(SideFile(c)) && new FileInfo(p).Length > 100000 && File.GetLastWriteTimeUtc(p) >= File.GetLastWriteTimeUtc(c.File).AddSeconds(-2);
            }
            catch (Exception) { return false; }
        }
        static ShareJob Find(string key) { foreach (ShareJob j in jobs) if (j.Key == key) return j; return null; }
        static bool Active(ShareJob j) { return j.State == "queued" || j.State == "waiting" || j.State == "making"; }

        static void Reply(NetworkStream s, int code, string type, byte[] body)
        {
            string reason = code == 200 ? "OK" : code == 400 ? "Bad Request" : code == 403 ? "Forbidden" : code == 404 ? "Not Found" : code == 409 ? "Conflict" : code == 503 ? "Service Unavailable" : "Error";
            byte[] hb = Encoding.ASCII.GetBytes("HTTP/1.1 " + code + " " + reason + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
            s.Write(hb, 0, hb.Length);
            if (body.Length > 0) s.Write(body, 0, body.Length);
            s.Flush();
        }

        // Returns true when the request was ours (and has been answered).
        public static bool Handle(NetworkStream s, string path, Dictionary<string, string> q, Dictionary<string, string> hdr, bool local)
        {
            try
            {
                int code = 200; string j = null;
                switch (path)
                {
                    case "/share/make": j = Make(Q(q, "id"), Q(q, "ref"), Q(q, "stripe") == "1" && Sdk.TestHook, Q(q, "force") == "1", out code); break;
                    case "/share/status": j = Status(Q(q, "id"), out code); break;
                    case "/share/video":
                        {
                            RecClip c = Recorder.ClipForShare(Q(q, "id"));
                            return Vault.ServeMp4(s, c != null && FileOk(c) ? SharePath(c) : null, hdr);        // Range works; 404 when it has not been made
                        }
                    case "/share/open": if (!local) { code = 403; j = Err("Only on the PC"); } else j = Open(Q(q, "id"), Q(q, "dry") == "1", out code); break;
                    case "/share/jump": if (!local) { code = 403; j = Err("Only on the PC"); } else j = Replay.JumpRoute(q, out code); break;
                    case "/share/test/frame": if (!Sdk.TestHook) return false; return TestFrame(s, q);
                    default: return false;
                }
                Reply(s, code, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(j));
                return true;
            }
            catch (Exception ex)
            {
                Log.W("share: " + path + ": " + ex.Message);
                try { Reply(s, 500, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(Err("Failed"))); } catch (Exception) { }
                return true;
            }
        }

        // ---------------- asking, status ----------------
        static string Make(string id, string refSpec, bool stripe, bool force, out int code)
        {
            code = 200;
            RecClip c = Recorder.ClipForShare(id);
            if (c == null || !File.Exists(c.File)) { code = 404; return Err("No video for this lap"); }
            if (Program.IsDriving) { code = 409; return Err("Not while driving"); }
            lock (gate)
            {
                ShareJob j = Find(c.Id);
                if (j != null && Active(j)) return StatusOf(c, j);
                if (!force && FileOk(c) && !stripe && refSpec.Length == 0) return StatusOf(c, j);       // already made: the same answer, nothing is made twice
                if (j != null) jobs.Remove(j);
                j = new ShareJob(); j.Key = c.Id; j.Spec = id; j.Ref = refSpec; j.Stripe = stripe; j.Asked = (long)(DateTime.UtcNow - Epoch).TotalMilliseconds;
                j.Reason = "In line";
                jobs.Add(j);
                if (worker == null) { worker = new Thread(Work); worker.IsBackground = true; worker.Priority = ThreadPriority.BelowNormal; worker.Name = "share"; worker.Start(); }
                Monitor.PulseAll(gate);
                return StatusOf(c, j);
            }
        }

        static string Status(string id, out int code)
        {
            code = 200;
            RecClip c = Recorder.ClipForShare(id);
            if (c == null) { code = 404; return "{\"state\":\"none\",\"error\":\"No video for this lap\"}"; }
            lock (gate) return StatusOf(c, Find(c.Id));
        }

        static string NiceName(RecClip c)
        {
            string tr = Regex.Replace((c.Track ?? "lap").ToLowerInvariant(), "[^a-z0-9]+", "-").Trim('-');
            string lt = Regex.Replace(PbRef.Lap(c.LapTime), "[^0-9]+", "-").Trim('-');
            return "paddock-" + (tr.Length > 0 ? tr : "lap") + "-" + lt + "-share.mp4";
        }

        static string StatusOf(RecClip c, ShareJob j)
        {
            string state = "none", reason = ""; int pct = 0, queue = 0; bool ready = FileOk(c);
            if (j != null)
            {
                state = j.State; reason = j.Reason;
                pct = j.Total > 0 ? Math.Min(99, (int)(100.0 * j.Done / j.Total)) : 0;
                if (j.State == "done") pct = 100;
                if (Active(j)) { foreach (ShareJob o in jobs) { if (o == j) break; if (Active(o)) queue++; } }
            }
            else if (ready) { state = "done"; pct = 100; }
            if (state == "done" && !ready) { state = "none"; pct = 0; }
            long size = 0; string enc = "", made = "0", secs = "0", stripe = "false";
            if (ready)
            {
                try
                {
                    size = new FileInfo(SharePath(c)).Length;
                    Dictionary<string, object> d = new System.Web.Script.Serialization.JavaScriptSerializer().DeserializeObject(File.ReadAllText(SideFile(c), Encoding.UTF8)) as Dictionary<string, object>;
                    if (d != null) { object o; if (d.TryGetValue("encoder", out o)) enc = Convert.ToString(o, Inv); if (d.TryGetValue("made", out o)) made = Convert.ToString(o, Inv); if (d.TryGetValue("seconds", out o)) secs = Convert.ToString(o, Inv); if (d.TryGetValue("stripe", out o)) stripe = (o is bool && (bool)o) ? "true" : "false"; }
                }
                catch (Exception) { }
            }
            return "{\"id\":" + Json_.S(c.Id) + ",\"state\":" + Json_.S(state) + ",\"pct\":" + pct + ",\"reason\":" + Json_.S(reason) + ",\"queue\":" + queue + ",\"ready\":" + (ready ? "true" : "false") +
                   ",\"size\":" + size + ",\"name\":" + Json_.S(NiceName(c)) + ",\"lap\":" + c.Lap + ",\"lapTime\":" + N3(c.LapTime) + ",\"encoder\":" + Json_.S(enc) + ",\"made\":" + made + ",\"seconds\":" + secs + ",\"stripe\":" + stripe + "}";
        }

        static string Open(string id, bool dry, out int code)
        {
            code = 200;
            RecClip c = Recorder.ClipForShare(id);
            if (c == null || !FileOk(c)) { code = 404; return Err("Not made yet"); }
            if (!dry)
            {
                try { Process.Start("explorer.exe", "/select,\"" + SharePath(c) + "\""); Log.W("share: opened the folder of " + Path.GetFileName(SharePath(c))); }
                catch (Exception ex) { code = 500; Log.W("share: open: " + ex.Message); return Err("Folder not opened"); }
            }
            return "{\"ok\":true,\"dry\":" + (dry ? "true" : "false") + ",\"name\":" + Json_.S(Path.GetFileName(SharePath(c))) + "}";
        }

        // ---------------- when it may run ----------------
        // Never while he is driving or about to. The sim being open is not enough to stop it (he may sit in the replay for hours), but then it waits two quiet minutes
        // after he leaves the car (or after the sim opens), so a render never starts under a session he is just getting into.
        static bool Allowed(out string why)
        {
            why = ""; DateTime now = DateTime.UtcNow;
            bool drv = Program.IsDriving, sim = false;
            try { sim = Process.GetProcessesByName("iRacingSim64DX11").Length > 0; } catch (Exception) { }
            string busy = null; try { busy = Sdk.RealBusy(); } catch (Exception) { }
            lock (gate)
            {
                if (drv || (sim && !lastSim)) busySince = now;
                lastSim = sim;
                if (drv) { why = "Driving: made after the session"; return false; }
                if (busy != null && busy.StartsWith("a START key", StringComparison.Ordinal)) { why = "iRacing starting: made afterwards"; return false; }
                if (sim && (now - busySince).TotalSeconds < 120) { why = "iRacing open: made 2 min after the car stops"; return false; }
            }
            return true;
        }

        // ---------------- the worker ----------------
        static void Work()
        {
            while (true)
            {
                ShareJob j = null;
                lock (gate)
                {
                    foreach (ShareJob o in jobs) if (o.State == "queued" || o.State == "waiting") { j = o; break; }
                    if (j == null) { Monitor.Wait(gate, 2000); continue; }
                }
                string why;
                if (!Allowed(out why)) { lock (gate) { j.State = "waiting"; j.Reason = why; } Thread.Sleep(1500); continue; }
                try { Render(j); }
                catch (Exception ex) { Log.W("share: " + ex.Message); Fail(j, "Failed"); }
            }
        }

        static void Fail(ShareJob j, string why) { lock (gate) { j.State = "error"; j.Reason = why; } Log.W("share: " + j.Key + ": " + why); }

        static int Run(string exe, string args, string cwd, int timeoutMs, out string stdout, out string stderr)
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe, args); psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            if (cwd != null) psi.WorkingDirectory = cwd;
            using (Process p = Process.Start(psi))
            {
                try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch (Exception) { }
                StringBuilder so = new StringBuilder(), se = new StringBuilder();
                p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) lock (so) so.AppendLine(e.Data); };
                p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) lock (se) se.AppendLine(e.Data); };
                p.BeginOutputReadLine(); p.BeginErrorReadLine();
                if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch (Exception) { } stdout = ""; stderr = "timed out"; return -1; }
                p.WaitForExit();
                lock (so) stdout = so.ToString(); lock (se) stderr = se.ToString();
                return p.ExitCode;
            }
        }

        // the clip's own picture times (presentation order): the overlay is drawn for exactly these
        static List<double> ProbePts(string mp4)
        {
            List<double> pts = new List<double>(); string o, e;
            if (Run(Recorder.FfprobeExe, "-v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 \"" + mp4 + "\"", null, 60000, out o, out e) != 0) return pts;
            foreach (string ln in o.Split('\n'))
            {
                string t = ln.Trim().TrimEnd(','); double v;
                if (t.Length > 0 && double.TryParse(t, NumberStyles.Float, Inv, out v)) pts.Add(v);
            }
            pts.Sort();
            return pts;
        }

        static void Tidy()
        {
            try
            {
                string dir = Recorder.ClipFolder;
                if (!Directory.Exists(dir)) return;
                List<FileInfo> mine = new List<FileInfo>();
                foreach (string f in Directory.GetFiles(dir, "share-*.mp4"))
                {
                    string clip = Path.Combine(dir, Path.GetFileName(f).Substring(6, Path.GetFileName(f).Length - 6 - 4) + ".mp4");
                    if (!File.Exists(clip)) { Gone(f); continue; }          // the clip was cleaned up: its share video goes too
                    mine.Add(new FileInfo(f));
                }
                mine.Sort(delegate (FileInfo a, FileInfo b) { return b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc); });
                for (int i = Keep; i < mine.Count; i++) Gone(mine[i].FullName);
                foreach (string f in Directory.GetFiles(dir, "share-*.tmp")) if ((DateTime.UtcNow - File.GetLastWriteTimeUtc(f)).TotalHours > 1) { try { File.Delete(f); } catch (Exception) { } }
            }
            catch (Exception ex) { Log.W("share: tidy: " + ex.Message); }
        }
        static void Gone(string mp4) { try { File.Delete(mp4); File.Delete(Path.ChangeExtension(mp4, ".json")); Log.W("share: removed " + Path.GetFileName(mp4)); } catch (Exception) { } }

        static void Render(ShareJob j)
        {
            Stopwatch sw = Stopwatch.StartNew();
            lock (gate) { j.State = "making"; j.Reason = "Making"; j.Done = 0; j.Total = 0; }
            RecClip clip = Recorder.ClipForShare(j.Spec);
            if (clip == null || !File.Exists(clip.File)) { Fail(j, "Video gone"); return; }
            Tidy();
            double pre = Math.Max(0, clip.LapStartOffset - clip.VideoStart) + 0.3, post = Math.Max(0, clip.VideoStart + clip.Duration - clip.LapEndOffset) + 0.3;
            ShareLap d = Analysis.ShareCollect(j.Spec, clip, Math.Min(pre, 20), Math.Min(post, 20), j.Ref);
            if (d.Err.Length > 0) { Fail(j, d.Err); return; }
            List<double> pts = ProbePts(clip.File);
            if (pts.Count < 30) { Fail(j, "Video unreadable"); return; }
            lock (gate) j.Total = pts.Count;
            string finalMp4 = SharePath(clip), tmp = finalMp4 + ".tmp";
            string tdir = Path.Combine(Path.GetTempPath(), "paddock-share-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(tdir);
            try
            {
                using (ShareDraw dr = new ShareDraw(d, j.Stripe))
                {
                    string plate = Path.Combine(tdir, "plate.png"); dr.SavePlate(plate);
                    string why; int rc = RunFfmpeg(j, clip, pts, dr, plate, tmp, tdir, "h264_nvenc", out why);
                    if (rc == 1 && Regex.IsMatch(why, "nvenc|NVENC|nvcuda|OpenEncodeSession|No capable devices", RegexOptions.IgnoreCase))
                    {
                        Log.W("share: the video chip refused (" + FirstLine(why) + ") - using the processor");
                        lock (gate) j.Done = 0;
                        rc = RunFfmpeg(j, clip, pts, dr, plate, tmp, tdir, "libx264", out why);
                    }
                    if (rc == 2) { try { File.Delete(tmp); } catch (Exception) { } lock (gate) { j.State = "waiting"; j.Reason = why; j.Done = 0; } return; }
                    if (rc != 0) { try { File.Delete(tmp); } catch (Exception) { } Fail(j, "ffmpeg failed: " + FirstLine(why)); return; }
                }
                // what came out: 1920x1080, as many pictures as the clip, no rotation flag (upright without help)
                string po, pe; int w = 0, h = 0, frames = 0; bool rotated = false; double dur = 0;
                if (Run(Recorder.FfprobeExe, "-v error -select_streams v:0 -show_entries stream=width,height,nb_frames,duration:stream_side_data=rotation -of default=nw=1 \"" + tmp + "\"", null, 30000, out po, out pe) == 0)
                    foreach (string ln in po.Split('\n'))
                    {
                        string t = ln.Trim(); double v;
                        if (t.StartsWith("width=") && double.TryParse(t.Substring(6), NumberStyles.Float, Inv, out v)) w = (int)v;
                        else if (t.StartsWith("height=") && double.TryParse(t.Substring(7), NumberStyles.Float, Inv, out v)) h = (int)v;
                        else if (t.StartsWith("nb_frames=") && double.TryParse(t.Substring(10), NumberStyles.Float, Inv, out v)) frames = (int)v;
                        else if (t.StartsWith("duration=") && double.TryParse(t.Substring(9), NumberStyles.Float, Inv, out v)) dur = v;
                        else if (t.StartsWith("rotation=") && double.TryParse(t.Substring(9), NumberStyles.Float, Inv, out v) && Math.Abs(v) > 0.5) rotated = true;
                    }
                if (w != 1920 || h != 1080 || rotated || (frames > 0 && Math.Abs(frames - pts.Count) > 2)) { try { File.Delete(tmp); } catch (Exception) { } Fail(j, "Video check failed (" + w + "x" + h + ", " + frames + " pictures, rotated " + rotated + ")."); return; }
                try { if (File.Exists(finalMp4)) File.Delete(finalMp4); File.Move(tmp, finalMp4); } catch (Exception ex) { Fail(j, "Could not save: " + ex.Message); return; }
                long made = (long)(DateTime.UtcNow - Epoch).TotalMilliseconds;
                string side = "{\"clip\":" + Json_.S(clip.Id) + ",\"lap\":" + clip.Lap + ",\"lapTime\":" + N3(clip.LapTime) + ",\"width\":" + w + ",\"height\":" + h + ",\"fps\":60,\"frames\":" + pts.Count + ",\"duration\":" + N3(dur) +
                              ",\"encoder\":" + Json_.S(j.Encoder) + ",\"overlay\":\"v1\",\"upright\":true,\"ref\":" + Json_.S(d.HasRef ? d.RefKind : "") + ",\"refTime\":" + N3(d.RefTime) + ",\"units\":\"kmh\",\"stripe\":" + (j.Stripe ? "true" : "false") +
                              ",\"made\":" + made + ",\"seconds\":" + N3(sw.Elapsed.TotalSeconds) + ",\"size\":" + new FileInfo(finalMp4).Length + "}";
                File.WriteAllText(SideFile(clip), side, new UTF8Encoding(false));
                lock (gate) { j.State = "done"; j.Reason = ""; j.Done = j.Total; j.Seconds = sw.Elapsed.TotalSeconds; }
                Log.W("share: " + Path.GetFileName(finalMp4) + " made (" + pts.Count + " pictures, " + (new FileInfo(finalMp4).Length / 1048576) + " MB, " + sw.Elapsed.TotalSeconds.ToString("0.0", Inv) + " s, " + j.Encoder + ")");
            }
            finally { try { Directory.Delete(tdir, true); } catch (Exception) { } }
        }

        static string FirstLine(string s) { s = (s ?? "").Trim(); int n = s.IndexOf('\n'); return (n > 0 ? s.Substring(0, n) : s).Trim(); }

        // 0 = made, 1 = ffmpeg failed (why = its words), 2 = stopped because he is driving (why = the plain reason)
        static int RunFfmpeg(ShareJob j, RecClip clip, List<double> pts, ShareDraw dr, string plate, string tmp, string tdir, string enc, out string why)
        {
            why = "";
            // main: frame n at n/60 (setpts), upright by ffmpeg's own autorotate (the flag is applied and dropped), 1080p, letterboxed if the screen was not 16:9.
            // overlays: the strip comes in on the pipe at 60 pictures a second (picture n = clip picture n), the plate is one picture. Colours in BT.709.
            string graph = "[0:v]setpts=N/(60*TB),scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p[bg];" +
                           "[1:v]scale=out_color_matrix=bt709,format=yuva420p[dyn];[2:v]scale=out_color_matrix=bt709,format=yuva420p[plt];" +
                           "[bg][plt]overlay=0:0:format=auto[a];[a][dyn]overlay=0:" + ShareDraw.SY + ":format=auto,format=yuv420p[o]";
            File.WriteAllText(Path.Combine(tdir, "graph.txt"), graph, new UTF8Encoding(false));
            string venc = enc == "libx264" ? "-c:v libx264 -preset veryfast -crf 21 -maxrate 20M -bufsize 40M -g 120 -profile:v high"
                                            : "-c:v h264_nvenc -preset p5 -tune hq -rc vbr -cq 22 -b:v 0 -maxrate 20M -bufsize 40M -g 120 -profile:v high";
            string args = "-hide_banner -y -loglevel error -i \"" + clip.File + "\" -f rawvideo -pix_fmt bgra -video_size " + ShareDraw.W + "x" + ShareDraw.SH + " -framerate 60 -i pipe:0 -i \"" + plate + "\" " +
                          "-/filter_complex \"" + Path.Combine(tdir, "graph.txt") + "\" -map \"[o]\" -an " + venc + " -pix_fmt yuv420p -r 60 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -movflags +faststart -f mp4 \"" + tmp + "\"";
            lock (gate) j.Encoder = enc;
            ProcessStartInfo psi = new ProcessStartInfo(Recorder.FfmpegExe, args); psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardInput = true; psi.RedirectStandardError = true; psi.WorkingDirectory = tdir;
            Process p = Process.Start(psi);
            try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch (Exception) { }
            try { RecJob.Add(p); } catch (Exception) { }          // ffmpeg ends with irdash (the recorder's job object): no render is left running by a restart
            StringBuilder err = new StringBuilder();
            p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) lock (err) { if (err.Length < 6000) err.AppendLine(e.Data); } };
            p.BeginErrorReadLine();
            bool stopped = false; string stopWhy = "";
            try
            {
                Stream si = p.StandardInput.BaseStream;
                for (int i = 0; i < pts.Count; i++)
                {
                    if ((i & 31) == 0)
                    {
                        string w; if (!Allowed(out w)) { stopped = true; stopWhy = w; break; }
                        if (p.HasExited) break;
                    }
                    byte[] fb = dr.Frame(pts[i] - clip.LapStartOffset);
                    si.Write(fb, 0, fb.Length);
                    lock (gate) j.Done = i + 1;
                }
                if (!stopped) { si.Flush(); p.StandardInput.Close(); }
            }
            catch (IOException) { }                  // ffmpeg quit early: its words say why
            catch (ObjectDisposedException) { }
            if (stopped) { try { p.Kill(); } catch (Exception) { } try { p.WaitForExit(5000); } catch (Exception) { } why = stopWhy; return 2; }
            if (!p.WaitForExit(180000)) { try { p.Kill(); } catch (Exception) { } why = "ffmpeg did not finish"; return 1; }
            p.WaitForExit();
            lock (err) why = err.ToString();
            return p.ExitCode == 0 && File.Exists(tmp) ? 0 : 1;
        }

        // ---------------- test hook: the strip as a picture ----------------
        static bool TestFrame(NetworkStream s, Dictionary<string, string> q)
        {
            RecClip c = Recorder.ClipForShare(Q(q, "id"));
            double t; if (c == null || !double.TryParse(Q(q, "t"), NumberStyles.Float, Inv, out t)) { Reply(s, 404, "application/json", Encoding.UTF8.GetBytes(Err("no clip or no t"))); return true; }
            ShareLap d = Analysis.ShareCollect(Q(q, "id"), c, 6, 6, Q(q, "ref"));
            if (d.Err.Length > 0) { Reply(s, 404, "application/json", Encoding.UTF8.GetBytes(Err(d.Err))); return true; }
            using (ShareDraw dr = new ShareDraw(d, Q(q, "stripe") == "1"))
            {
                dr.Frame(t);
                using (MemoryStream ms = new MemoryStream()) { dr.Current.Save(ms, ImageFormat.Png); Reply(s, 200, "image/png", ms.ToArray()); }
            }
            return true;
        }
    }
}
