// Workbench data (docs\DESIGN-workbench.md 5.1, card W1): any channel of the .ibt file for one lap and its reference,
// both on the same distance grid with the time axis pinned to iRacing's official lap time. The lap store in analysis.cs
// already finds the laps, the reference and the pinned time (Resample); this file only adds the raw channels on top.
//   GET /analysis/channels?id=<vault id or file name>&lap=<n>&ref=pb|session|<id>:<lap>&ch=Speed,Throttle,Gear[0],...
// Reply (binary, so two laps x 20 channels load in a few ms): "PWB1", int32 header length, the JSON header padded to a
// multiple of 4 bytes, then Float32 little-endian arrays in the order the header's "arrays" list gives.
// Grid: n = metres + 1 samples, sample i at distance i * lengthM / metres (about 1 m); the last one is the line itself,
// so the time axis ends exactly on the official lap time. Whole-number channels (gear, flags) hold their value between
// samples; the rest are interpolated. Errors are JSON with a non-200 code. 503 while Peter drives (never the newest file).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static partial class Analysis
    {
        // Bias is taken off before the value becomes a Float32 (Lat/Lon at the sim's precision would lose half a metre); 0 for everything else
        sealed class Chan { public string Key = "", Name = "", Unit = "", Desc = ""; public int Index; public bool Ok; public double Bias; }

        public static byte[] ChannelsRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (Program.IsDriving) { code = 503; return Utf8(Err("Not while driving")); }
            string id = Q(q, "id"), rf = Q(q, "ref"), ch = Q(q, "ch"), multi = Q(q, "laps");
            if (rf.Length == 0) rf = "pb";
            int lap;
            if (!int.TryParse(Q(q, "lap"), NumberStyles.Integer, Inv, out lap)) { code = 400; return Utf8(Err("lap must be a number")); }
            string file = ResolveFile(id);
            if (file == null) { code = 404; return Utf8(Err("no such lap file")); }
            try { if (Career.OnlineOnly(new FileInfo(file))) { code = 409; return Utf8(Err("Online-only in OneDrive: run tools\\keep-iracing-local.cmd")); } }
            catch { code = 404; return Utf8(Err("no such lap file")); }
            ThreadPriority was = Thread.CurrentThread.Priority;
            try
            {
                Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
                string dir = TrackMaps.TelemetryDir;
                if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) dir = Path.GetDirectoryName(file);
                return BuildChannels(file, lap, rf, ch, dir, true, out code, multi);
            }
            catch (Exception ex) { Log.W("channels: " + ex.Message); code = 500; return Utf8(Err("could not read that file")); }
            finally { try { Thread.CurrentThread.Priority = was; } catch { } }
        }

        static byte[] Utf8(string s) { return Encoding.UTF8.GetBytes(s); }

        // "Speed,Throttle,CarIdxLapDistPct[3]" -> channels; repeats dropped; at most 64 so a typo cannot ask for everything
        static List<Chan> ParseChannels(string list)
        {
            List<Chan> outp = new List<Chan>();
            HashSet<string> seen = new HashSet<string>();
            foreach (string raw in (list ?? "").Split(','))
            {
                string s = raw.Trim();
                if (s.Length == 0 || outp.Count >= 64) continue;
                Match m = Regex.Match(s, @"^([A-Za-z0-9_]+)(?:\[(\d+)\])?$");
                if (!m.Success || !seen.Add(s)) continue;
                Chan c = new Chan();
                c.Key = s; c.Name = m.Groups[1].Value;
                c.Index = m.Groups[2].Success ? int.Parse(m.Groups[2].Value, Inv) : 0;
                outp.Add(c);
            }
            return outp;
        }

        // The reference lap. "optimal" has no raw channels, so it falls back to the PB. "<vault id>:<lap>" works too.
        static LapTrace FindRefLap(List<LapTrace> clean, LapTrace me, string spec, List<Sess> sessions, CornerSet cs, out string kind)
        {
            if (spec == null || spec.Length == 0 || spec == "optimal") spec = "pb";
            int colon = spec.LastIndexOf(':'); int n;
            if (colon > 0 && int.TryParse(spec.Substring(colon + 1), NumberStyles.Integer, Inv, out n) && !spec.Substring(0, colon).EndsWith(".ibt", StringComparison.OrdinalIgnoreCase))
            {
                string path = null;    // a vault id; plain file names go through FindRef below (it matches by name in the gathered files)
                try { path = ResolveFile(spec.Substring(0, colon)); } catch { }
                if (path != null && File.Exists(path))
                {
                    kind = "lap";
                    foreach (LapTrace lap in Get(path).Laps) if (lap.Lap == n && lap.Clean && lap.Tm != null) return lap;
                    return null;
                }
            }
            LapTrace optimal;
            return FindRef(clean, me, spec, sessions, cs, out kind, out optimal);
        }

        // "2026-10-10 00-13-18" in the file name -> "2026-10-10T00:13:18" (vault copies and iRacing's own names both have it)
        static string DateOf(string file)
        {
            Match m = Regex.Match(file ?? "", @"(\d{4})-(\d\d)-(\d\d) (\d\d)-(\d\d)-(\d\d)");
            return m.Success ? m.Groups[1].Value + "-" + m.Groups[2].Value + "-" + m.Groups[3].Value + "T" + m.Groups[4].Value + ":" + m.Groups[5].Value + ":" + m.Groups[6].Value : "";
        }

        static int TypeSize(int type) { return type == 5 ? 8 : type >= 2 ? 4 : 1; }

        static double Read(byte[] b, int p, int type)
        {
            switch (type)
            {
                case 0: case 1: return b[p];
                case 2: case 3: return BitConverter.ToInt32(b, p);
                case 4: return BitConverter.ToSingle(b, p);
                case 5: return BitConverter.ToDouble(b, p);
            }
            return 0;
        }

        // Units and descriptions from the var table (irsdk_varHeader: name at 16, desc at 48, unit at 112).
        static void ReadMeta(TrackMaps.Ibt t, List<Chan> chans)
        {
            byte[] h = new byte[32]; t.fs.Position = 0; t.fs.Read(h, 0, 32);
            int numVars = BitConverter.ToInt32(h, 24), varOff = BitConverter.ToInt32(h, 28);
            if (numVars <= 0 || numVars > 2000) return;
            byte[] vh = new byte[numVars * 144]; t.fs.Position = varOff; t.fs.Read(vh, 0, vh.Length);
            Dictionary<string, int> at = new Dictionary<string, int>();
            for (int i = 0; i < numVars; i++)
            {
                int b = i * 144, len = Array.IndexOf(vh, (byte)0, b + 16, 32) - (b + 16); if (len < 0) len = 32;
                at[Encoding.ASCII.GetString(vh, b + 16, len)] = b;
            }
            foreach (Chan c in chans)
            {
                int b;
                if (!at.TryGetValue(c.Name, out b)) continue;
                int dl = Array.IndexOf(vh, (byte)0, b + 48, 64) - (b + 48); if (dl < 0) dl = 64;
                int ul = Array.IndexOf(vh, (byte)0, b + 112, 32) - (b + 112); if (ul < 0) ul = 32;
                c.Desc = Encoding.ASCII.GetString(vh, b + 48, dl); c.Unit = Encoding.ASCII.GetString(vh, b + 112, ul);
            }
        }

        // The lap's own records decoded for every wanted channel, then put on the grid with the same point rules as
        // Resample (monotonic distance, the sample before the line for the wrap, the line itself at the end).
        static float[][] LapChannels(LapTrace lap, List<Chan> chans, int n, bool meta)
        {
            if (lap.Partial) return PartialChannels(lap, chans, n, meta);      // a part-lap view: its own points, NaN where it was not driven (partial.cs)
            int nc = chans.Count;
            float[][] outp = new float[nc][];
            for (int c = 0; c < nc; c++) outp[c] = new float[n];
            if (nc == 0 || lap.RecB <= lap.RecA) return outp;
            TrackMaps.Ibt t = TrackMaps.OpenIbt(lap.Path, true);
            if (t == null) return outp;
            using (t.fs)
            {
                if (meta) ReadMeta(t, chans);
                VarDef vSt = V(t, "SessionTime"), vPct = V(t, "LapDistPct");
                if (vSt == null || vPct == null) return outp;
                VarDef[] defs = new VarDef[nc]; int[] off = new int[nc]; bool[] step = new bool[nc];
                for (int c = 0; c < nc; c++)
                {
                    VarDef d = V(t, chans[c].Name);
                    if (d == null || chans[c].Index < 0 || chans[c].Index >= Math.Max(1, d.Count)) continue;
                    defs[c] = d; off[c] = d.Offset + chans[c].Index * TypeSize(d.Type); step[c] = d.Type < 4;
                    if (meta) chans[c].Ok = true;
                }
                int a = lap.RecA, b = lap.RecB, from = a > 0 ? a - 1 : a;
                long cnt = b - from;
                if (cnt <= 0 || cnt > 400000) return outp;
                byte[] buf = new byte[cnt * t.bufLen];
                t.fs.Position = t.dataOff + (long)from * t.bufLen;
                int got = 0;
                while (got < buf.Length) { int r = t.fs.Read(buf, got, buf.Length - got); if (r <= 0) break; got += r; }
                int recs = got / t.bufLen;
                if (recs < b - a) b = from + recs;
                double L = lap.LengthM, t0 = lap.T0, computed = lap.Computed;
                List<double> D = new List<double>(), T = new List<double>();
                List<int> rec = new List<int>();                      // which record each point takes its values from
                int ka = a - from;
                if (a > 0 && ka == 1)
                {
                    double stPrev = Read(buf, 0 * t.bufLen + vSt.Offset, vSt.Type), stA = Read(buf, ka * t.bufLen + vSt.Offset, vSt.Type);
                    double pctPrev = Read(buf, 0 * t.bufLen + vPct.Offset, vPct.Type);
                    if (stA - stPrev < 0.5 && pctPrev > 0.5) { D.Add(pctPrev * L - L); T.Add(stPrev - t0); rec.Add(0); }
                }
                D.Add(0); T.Add(0); rec.Add(ka);
                double lastD = 0;
                for (int k = ka; k < ka + (b - a); k++)
                {
                    int o = k * t.bufLen;
                    double d = Read(buf, o + vPct.Offset, vPct.Type) * L, tt = Read(buf, o + vSt.Offset, vSt.Type) - t0;
                    if (d <= lastD + 0.05 || d > L || tt < 0) continue;
                    if (tt + 1e-6 < T[T.Count - 1]) continue;
                    D.Add(d); T.Add(tt); rec.Add(k); lastD = d;
                }
                if (D[D.Count - 1] < L - 0.01) { D.Add(L); T.Add(computed); rec.Add(ka + (b - a) - 1); }
                else { D[D.Count - 1] = L; T[T.Count - 1] = computed; }
                int np = D.Count, m = n - 1;
                for (int c = 0; c < nc; c++)
                {
                    if (defs[c] == null) continue;
                    float[] v = new float[np];
                    for (int p = 0; p < np; p++) v[p] = (float)(Read(buf, rec[p] * t.bufLen + off[c], defs[c].Type) - chans[c].Bias);
                    float[] g = outp[c];
                    int j = 0;
                    for (int i = 0; i < n; i++)
                    {
                        double d = i >= m ? L : i * L / m;
                        while (j + 1 < np && D[j + 1] <= d) j++;
                        if (j + 1 >= np || d <= D[j] || step[c]) { g[i] = v[j]; continue; }
                        double span = D[j + 1] - D[j], f = span > 1e-9 ? (d - D[j]) / span : 0;
                        g[i] = (float)(v[j] + (v[j + 1] - v[j]) * f);
                    }
                }
            }
            return outp;
        }

        static void AppendLapInfo(StringBuilder sb, LapTrace lap, string kind)
        {
            sb.Append("{\"file\":").Append(Json_.S(lap.File)).Append(",\"lap\":").Append(lap.Lap).Append(",\"time\":").Append(F(lap.Time, "0.000"));
            sb.Append(",\"official\":").Append(lap.HasOfficial ? F(lap.Official, "0.000") : "null").Append(",\"date\":").Append(Json_.S(DateOf(lap.File)));
            sb.Append(",\"car\":").Append(Json_.S(lap.Car)).Append(",\"kind\":").Append(Json_.S(kind ?? "")).Append('}');
        }

        static byte[] BuildChannels(string file, int lapNo, string spec, string chList, string dir, bool liveRules, out int code, string multiSpec = "")
        {
            code = 200;
            List<Sess> sessions = Gather(file, dir, liveRules);
            Sess mine = sessions[0];
            CornerSet cs = LoadCorners(mine);
            LapTrace me = null;
            foreach (LapTrace lap in mine.Laps) if (lap.Lap == lapNo && (me == null || lap.Clean)) me = lap;
            if (me == null) { code = 404; return Utf8(Err("no such lap in this file")); }
            if (!me.Clean || me.Tm == null)
            {
                // not a full lap: the stretch it covers (partial.cs), NaN elsewhere, marked "partial" in the header (Peter 2026-10-18: show the data)
                LapTrace pv = PartialOf(me);
                if (pv == null) { code = 409; return Utf8(Err("lap " + lapNo.ToString(Inv) + " has under 200 m of driving: ALL THE DATA shows it")); }
                me = pv;
            }
            if (!string.IsNullOrEmpty(multiSpec)) spec = ""; // Explicit overlays replace the single reference.
            List<LapTrace> clean = CleanOf(sessions);
            string kind = "";
            LapTrace rf = string.IsNullOrEmpty(multiSpec) ? FindRefLap(clean, me, spec, sessions, cs, out kind) : null;
            if (rf != null && (SameLap(rf, me) || rf.Tm == null)) rf = null;     // a lap against itself shows nothing
            List<Chan> chans = ParseChannels(chList);
            int n = me.Metres + 1;
            float[][] mineV = me.Partial ? PartialChannels(me, chans, n, true) : LapChannels(me, chans, n, true);
            float[][] refV = rf != null ? LapChannels(rf, chans, n, false) : null;
            List<LapTrace> extraLaps = new List<LapTrace>();
            if (!string.IsNullOrEmpty(multiSpec))
            {
                string[] picks = multiSpec.Split(','); HashSet<string> seen = new HashSet<string>();
                if (picks.Length > 5) { code = 400; return Utf8(Err("at most six laps including the open lap")); }
                foreach (string pick in picks)
                {
                    string p = pick.Trim(); if (p.Length == 0) continue;
                    int colon = p.LastIndexOf(':'); int pn;
                    if (colon <= 0 || !int.TryParse(p.Substring(colon + 1), NumberStyles.Integer, Inv, out pn)) { code = 400; return Utf8(Err("each lap must be file:lap or vault-id:lap")); }
                    string key = p.ToLowerInvariant(); if (!seen.Add(key)) { code = 400; return Utf8(Err("duplicate lap")); }
                    string otherId = p.Substring(0, colon);
                    string otherFile = string.Equals(otherId, Path.GetFileName(file), StringComparison.OrdinalIgnoreCase) ? file : ResolveFile(otherId);
                    if (otherFile == null) { code = 404; return Utf8(Err("no such lap file")); }
                    Sess os = Gather(otherFile, dir, liveRules)[0]; LapTrace found = null;
                    foreach (LapTrace candidate in os.Laps) if (candidate.Lap == pn) { found = candidate; break; }
                    if (found == null) { code = 404; return Utf8(Err("no such lap")); }
                    if (SameLap(found, me)) { code = 400; return Utf8(Err("duplicate lap")); }
                    foreach (LapTrace prior in extraLaps) if (SameLap(found, prior)) { code = 400; return Utf8(Err("duplicate lap")); }
                    if (!found.Clean || found.Tm == null)
                    {
                        LapTrace fv = PartialOf(found);        // a part-lap overlays over the stretch it covers (NaN elsewhere)
                        if (fv == null) { code = 409; return Utf8(Err("selected lap has under 200 m of driving")); }
                        found = fv;
                    }
                    if (!string.Equals(found.Track, me.Track, StringComparison.OrdinalIgnoreCase) || !string.Equals(found.Car, me.Car, StringComparison.OrdinalIgnoreCase))
                    { code = 409; return Utf8(Err("selected laps must use the same car and track")); }
                    extraLaps.Add(found);
                }
            }
            List<float[][]> extraValues = new List<float[][]>();
            foreach (LapTrace xlap in extraLaps) extraValues.Add(xlap.Partial ? PartialChannels(xlap, chans, n, false) : LapChannels(xlap, chans, n, false));
            double L = me.LengthM;

            StringBuilder sb = new StringBuilder(6000);
            sb.Append("{\"v\":1,\"n\":").Append(n).Append(",\"metres\":").Append(me.Metres).Append(",\"lengthM\":").Append(F(L, "0.0"));
            sb.Append(",\"step\":").Append(F(L / me.Metres, "0.00000"));
            sb.Append(",\"track\":").Append(Json_.S(me.Track)).Append(",\"config\":").Append(Json_.S(me.Config)).Append(",\"car\":").Append(Json_.S(me.Car));
            sb.Append(",\"lap\":"); AppendLapInfo(sb, me, "lap");
            sb.Append(",\"partial\":"); if (me.Partial) AppendCover(sb, me); else sb.Append("null");
            sb.Append(",\"conditions\":").Append(Conditions(me));
            sb.Append(",\"ref\":"); if (rf == null) sb.Append("null"); else AppendLapInfo(sb, rf, kind);
            sb.Append(",\"channels\":[");
            for (int c = 0; c < chans.Count; c++)
            {
                if (c > 0) sb.Append(',');
                sb.Append("{\"key\":").Append(Json_.S(chans[c].Key)).Append(",\"name\":").Append(Json_.S(chans[c].Name)).Append(",\"unit\":").Append(Json_.S(chans[c].Unit));
                sb.Append(",\"desc\":").Append(Json_.S(chans[c].Desc)).Append(",\"ok\":").Append(chans[c].Ok ? "true" : "false").Append('}');
            }
            sb.Append("],\"multi\":[");
            for (int mi = 0; mi < extraLaps.Count; mi++) { if (mi > 0) sb.Append(','); AppendLapInfo(sb, extraLaps[mi], "multi"); }
            sb.Append("],\"arrays\":[\"lap.t\"");
            foreach (Chan c in chans) sb.Append(",\"lap.").Append(c.Key).Append('"');
            if (rf != null) { sb.Append(",\"ref.t\""); foreach (Chan c in chans) sb.Append(",\"ref.").Append(c.Key).Append('"'); }
            for (int mi = 0; mi < extraLaps.Count; mi++) { sb.Append(",\"m").Append(mi).Append(".t\""); foreach (Chan c in chans) sb.Append(",\"m").Append(mi).Append('.').Append(c.Key).Append('"'); }
            sb.Append("],\"laps\":[");
            for (int i = 0; i < mine.Laps.Count; i++)
            {
                LapTrace lap = mine.Laps[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(lap.Lap).Append(",\"time\":").Append(lap.Tm != null ? F(lap.Time, "0.000") : "null").Append(",\"official\":").Append(lap.HasOfficial ? F(lap.Official, "0.000") : "null");
                sb.Append(",\"clean\":").Append(lap.Clean ? "true" : "false").Append(",\"skip\":").Append(Json_.S(lap.Skip)).Append('}');
            }
            sb.Append("],\"corners\":[");
            bool anyC = false;
            if (cs != null && cs.Turns != null)
                foreach (CornerTurn tn in cs.Turns)
                {
                    if (anyC) sb.Append(','); anyC = true;
                    sb.Append("{\"n\":").Append(tn.N).Append(",\"label\":").Append(Json_.S(LabelOf(tn))).Append(",\"name\":").Append(Json_.S(tn.Name ?? "")).Append(",\"official\":").Append(Json_.S(tn.Official ?? ""));
                    sb.Append(",\"p0\":").Append(F(tn.P0, "0.00000")).Append(",\"pa\":").Append(F(tn.Pa, "0.00000")).Append(",\"p1\":").Append(F(tn.P1, "0.00000")).Append('}');
                }
            sb.Append("],\"credit\":").Append(Json_.S(cs != null ? cs.Credit : "")).Append(",\"sectorAt\":[");
            if (me.SectorAt != null) for (int i = 0; i < me.SectorAt.Length; i++) { if (i > 0) sb.Append(','); sb.Append(F(me.SectorAt[i], "0.000000")); }
            sb.Append("]}");
            byte[] head = Utf8(sb.ToString());
            int pad = (4 - head.Length % 4) % 4;
            int lapsOut = rf != null ? 2 : 1;
            lapsOut += extraLaps.Count;
            long total = 8 + head.Length + pad + (long)lapsOut * (1 + chans.Count) * n * 4;
            byte[] outp = new byte[total];
            outp[0] = (byte)'P'; outp[1] = (byte)'W'; outp[2] = (byte)'B'; outp[3] = (byte)'1';
            Buffer.BlockCopy(BitConverter.GetBytes(head.Length + pad), 0, outp, 4, 4);
            Buffer.BlockCopy(head, 0, outp, 8, head.Length);
            for (int i = 0; i < pad; i++) outp[8 + head.Length + i] = (byte)' ';
            int pos = 8 + head.Length + pad;
            pos = PutTime(outp, pos, me, n); foreach (float[] v in mineV) pos = PutFloats(outp, pos, v);
            if (rf != null) { pos = PutTime(outp, pos, rf, n); foreach (float[] v in refV) pos = PutFloats(outp, pos, v); }
            for (int mi = 0; mi < extraLaps.Count; mi++) { pos = PutTime(outp, pos, extraLaps[mi], n); foreach (float[] v in extraValues[mi]) pos = PutFloats(outp, pos, v); }
            return outp;
        }

        // the pinned time axis on the grid: TAt interpolates the lap store's metre times and returns the official time at the line
        static int PutTime(byte[] outp, int pos, LapTrace lap, int n)
        {
            int m = n - 1; double L = lap.LengthM;
            for (int i = 0; i < n; i++)
            {
                double d = i >= m ? L : i * L / m;
                Buffer.BlockCopy(BitConverter.GetBytes((float)TAt(lap, d)), 0, outp, pos, 4); pos += 4;
            }
            return pos;
        }

        static int PutFloats(byte[] outp, int pos, float[] v)
        {
            Buffer.BlockCopy(v, 0, outp, pos, v.Length * 4);
            return pos + v.Length * 4;
        }
    }

    // One-press deck control (docs\DESIGN-workbench.md 4): /api/do?c=wb-next-corner (&a=<arg>) queues "next-corner";
    // the workbench page polls /workbench/cmd and runs window.WB.cmd(cmd, arg) once per new seq. Only the listed
    // commands get through, and a command older than 10 s is dropped so a page opened later does not replay it.
    static class Workbench
    {
        static readonly object gate = new object();
        static string cmd = "", arg = ""; static int seq; static DateTime at = DateTime.MinValue;
        static readonly string[] Allowed = { "page", "page-next", "page-prev", "lap-next", "lap-prev", "ref-cycle", "next-corner", "prev-corner",
            "next-event", "prev-event", "play", "pause", "toggle-play", "speed", "zoom-in", "zoom-out", "zoom-reset", "zoom-corner", "tile", "offset", "offset-auto",
            "ref-cursor", "step", "cursor", "axis", "map-colour", "video-pip", "video-pip-corner" };
        public static bool Handles(string c) { return c != null && c.StartsWith("wb-", StringComparison.Ordinal); }
        public static bool Do(string c, string a)
        {
            string name = c.Substring(3);
            if (Array.IndexOf(Allowed, name) < 0) return false;
            lock (gate) { cmd = name; arg = a ?? ""; seq++; at = DateTime.Now; }
            return true;
        }
        public static string Json()
        {
            lock (gate)
            {
                bool fresh = (DateTime.Now - at).TotalSeconds < 10;
                // driving: the page pauses playback and stays quiet while he is on track
                return "{\"cmd\":" + Json_.S(fresh ? cmd : "") + ",\"arg\":" + Json_.S(fresh ? arg : "") + ",\"seq\":" + seq.ToString(CultureInfo.InvariantCulture) + ",\"driving\":" + (Program.IsDriving ? "true" : "false") + "}";
            }
        }
    }
}
