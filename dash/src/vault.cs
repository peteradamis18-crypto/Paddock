// VAULT (WS17 in docs\SPEC-next.md; notes for Peter in docs\vault.md): keep the best races, laps and clips and replay them with the data.
//   V1  moments: a lap or a race saved with everything about it. Finished sessions (.ibt in Documents\iRacing\telemetry) are read once,
//       in the background, at below-normal priority, never while driving. Keepers (never pruned, untouched .ibt copy in vault\telemetry):
//       a new personal best, a lap in the fastest 10% for that car and track, the best 3 laps of that combo, a race win or top 3,
//       an iRating gain of 40 or more. The last 30 days stay as "recent" (no copy). A budget (vault_gb in irdash.ini) prunes recent items, never keepers.
//       OneDrive online-only files are skipped. While the sim is running the newest file is left alone (it may still be growing),
//       unless that session is over (no session running, or chequered flag and out of the car), he is not driving and the file has stopped growing (C-27).
//   V2  clips: the NVIDIA app's Instant Replay saves a clip when Peter presses its hotkey (Alt+F10); the CLIP deck key calls vkclip, which
//       presses that hotkey (only if the NVIDIA overlay is running) and marks the lap. The watcher waits until the new .mp4 is complete, then
//       attaches it by its end time and length, copies it to vault\clips and locks video time to LapDistPct through the .ibt's clock.
// Everything here only reads iRacing's and NVIDIA's files. Owned by the Vault workstream; irdash.cs only calls Init/Start/Handle/Handles/Do.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    // ---------------- one saved moment ----------------
    sealed class VMoment
    {
        public string Id = "", Kind = "lap", Car = "", Track = "", Config = "", TrackId = "", TrackName = "", SType = "", Note = "";
        public string Ibt = "", IbtSrc = "", Session = "", Video = "";
        public long Ts, StartMs, VideoEndMs, Created, IbtSize, VideoSize;
        public bool Official, Finished, Pinned;
        public int Lap, Pos, Field;
        public double LapTime, PbBefore, IrDelta, VideoDur, Nudge, MarkPct;
        public List<string> Tags = new List<string>();

        static readonly string[] KeepTags = { "PB", "BEST LAP", "TOP 10", "WIN", "PODIUM", "BEST RACE", "BIG IR" };
        public bool HasKeepTag() { foreach (string t in Tags) if (Array.IndexOf(KeepTags, t) >= 0) return true; return false; }
        public bool Keeper { get { return Pinned || HasKeepTag(); } }
        public string Combo { get { return IRDash.Combo.Key(Car, Track, Config); } }

        public string Json(bool thumb)
        {
            CultureInfo inv = CultureInfo.InvariantCulture;
            StringBuilder tg = new StringBuilder();
            foreach (string t in Tags) { if (tg.Length > 0) tg.Append(','); tg.Append(Json_.S(t)); }
            return "{\"id\":" + Json_.S(Id) + ",\"kind\":" + Json_.S(Kind) + ",\"ts\":" + Ts + ",\"startMs\":" + StartMs + ",\"car\":" + Json_.S(Car) + ",\"track\":" + Json_.S(Track) + ",\"config\":" + Json_.S(Config) +
                   ",\"trackId\":" + Json_.S(TrackId) + ",\"trackName\":" + Json_.S(TrackName) + ",\"sType\":" + Json_.S(SType) + ",\"official\":" + (Official ? "true" : "false") + ",\"finished\":" + (Finished ? "true" : "false") +
                   ",\"lap\":" + Lap + ",\"lapTime\":" + LapTime.ToString("0.000", inv) + ",\"pbBefore\":" + PbBefore.ToString("0.000", inv) + ",\"pos\":" + Pos + ",\"field\":" + Field + ",\"irDelta\":" + IrDelta.ToString("0.0", inv) +
                   ",\"tags\":[" + tg + "],\"pinned\":" + (Pinned ? "true" : "false") + ",\"keeper\":" + (Keeper ? "true" : "false") + ",\"note\":" + Json_.S(Note) +
                   ",\"ibt\":" + Json_.S(Ibt) + ",\"ibtSrc\":" + Json_.S(IbtSrc) + ",\"session\":" + Json_.S(Session) + ",\"ibtSize\":" + IbtSize +
                   ",\"video\":" + Json_.S(Video) + ",\"videoDur\":" + VideoDur.ToString("0.###", inv) + ",\"videoEndMs\":" + VideoEndMs + ",\"videoSize\":" + VideoSize + ",\"nudge\":" + Nudge.ToString("0.##", inv) +
                   ",\"markPct\":" + MarkPct.ToString("0.0000", inv) + ",\"created\":" + Created + ",\"thumb\":" + (thumb ? "true" : "false") + "}";
        }

        static string S(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, CultureInfo.InvariantCulture) : ""; }
        static double N(Dictionary<string, object> d, string k) { object o; double v; return d.TryGetValue(k, out o) && o != null && double.TryParse(Convert.ToString(o, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : 0; }
        static bool B(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o is bool && (bool)o; }

        public static VMoment FromDict(Dictionary<string, object> d)
        {
            VMoment m = new VMoment();
            m.Id = S(d, "id"); m.Kind = S(d, "kind"); m.Ts = (long)N(d, "ts"); m.StartMs = (long)N(d, "startMs"); m.Car = S(d, "car"); m.Track = S(d, "track"); m.Config = S(d, "config");
            m.TrackId = S(d, "trackId"); m.TrackName = S(d, "trackName"); m.SType = S(d, "sType"); m.Official = B(d, "official"); m.Finished = B(d, "finished");
            m.Lap = (int)N(d, "lap"); m.LapTime = N(d, "lapTime"); m.PbBefore = N(d, "pbBefore"); m.Pos = (int)N(d, "pos"); m.Field = (int)N(d, "field"); m.IrDelta = N(d, "irDelta");
            object tg; if (d.TryGetValue("tags", out tg) && tg is IList) foreach (object t in (IList)tg) m.Tags.Add(Convert.ToString(t, CultureInfo.InvariantCulture));
            m.Pinned = B(d, "pinned"); m.Note = S(d, "note"); m.Ibt = S(d, "ibt"); m.IbtSrc = S(d, "ibtSrc"); m.Session = S(d, "session"); m.IbtSize = (long)N(d, "ibtSize");
            m.Video = S(d, "video"); m.VideoDur = N(d, "videoDur"); m.VideoEndMs = (long)N(d, "videoEndMs"); m.VideoSize = (long)N(d, "videoSize"); m.Nudge = N(d, "nudge");
            m.MarkPct = N(d, "markPct"); m.Created = (long)N(d, "created");
            return m;
        }
    }

    // ---------------- one finished session (a row of vault\sessions.tsv) ----------------
    sealed class VSession
    {
        public string Name = "", Car = "", Track = "", Config = "", TrackId = "", TrackName = "", Type = "";
        public long Size, StartMs, EndMs;
        public bool Official, Finished;
        public double BestValid, Secs, IrDelta;
        public int BestLap, ValidLaps, Pos, Field;
        public int ResV;      // VaultIbt.ResultV: the race-result fix a row has been through (0 = made before the "of 22" field-count fix, re-read cheaply by Vault.FixResults)
        public int Rules;     // L-1: LapRules.Version the laps were judged under; a row made under the old rule (0 = no such column) is read again, see Vault.ScanSessions
        public List<double[]> Top = new List<double[]>();     // every clean lap, quickest first: {lap, time}
        public string Combo { get { return IRDash.Combo.Key(Car, Track, Config); } }
        public bool IsRace { get { return Regex.IsMatch(Type ?? "", "race", RegexOptions.IgnoreCase); } }

        public string Row()
        {
            CultureInfo inv = CultureInfo.InvariantCulture;
            StringBuilder t = new StringBuilder();
            foreach (double[] x in Top) { if (t.Length > 0) t.Append(';'); t.Append(((int)x[0]).ToString(inv)).Append(':').Append(x[1].ToString("0.000", inv)); }
            string[] f = { Name, Size.ToString(inv), StartMs.ToString(inv), EndMs.ToString(inv), Car, Track, Config, TrackId, TrackName, Type, Official ? "1" : "0", BestValid.ToString("0.000", inv), BestLap.ToString(inv),
                           ValidLaps.ToString(inv), t.ToString(), Pos.ToString(inv), Field.ToString(inv), IrDelta.ToString("0.0", inv), Finished ? "1" : "0", Secs.ToString("0", inv), Rules.ToString(inv), ResV.ToString(inv) };
            for (int i = 0; i < f.Length; i++) f[i] = (f[i] ?? "").Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
            return string.Join("\t", f);
        }

        public static VSession FromRow(string line)
        {
            string[] f = line.Split('\t'); CultureInfo inv = CultureInfo.InvariantCulture;
            if (f.Length < 20) return null;
            VSession s = new VSession();
            s.Name = f[0]; long.TryParse(f[1], out s.Size); long.TryParse(f[2], out s.StartMs); long.TryParse(f[3], out s.EndMs); s.Car = f[4]; s.Track = f[5]; s.Config = f[6]; s.TrackId = f[7]; s.TrackName = f[8]; s.Type = f[9];
            s.Official = f[10] == "1"; double.TryParse(f[11], NumberStyles.Float, inv, out s.BestValid); int.TryParse(f[12], out s.BestLap); int.TryParse(f[13], out s.ValidLaps);
            foreach (string p in f[14].Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
            { string[] kv = p.Split(':'); double lap, tm; if (kv.Length == 2 && double.TryParse(kv[0], NumberStyles.Float, inv, out lap) && double.TryParse(kv[1], NumberStyles.Float, inv, out tm)) s.Top.Add(new[] { lap, tm }); }
            int.TryParse(f[15], out s.Pos); int.TryParse(f[16], out s.Field); double.TryParse(f[17], NumberStyles.Float, inv, out s.IrDelta); s.Finished = f[18] == "1"; double.TryParse(f[19], NumberStyles.Float, inv, out s.Secs);
            if (f.Length >= 21) int.TryParse(f[20], out s.Rules);
            if (f.Length >= 22) int.TryParse(f[21], out s.ResV);
            // a stub of a file that could not be read stays a stub; every other row made under an older rule is read again (the rule can add a lap as well as take one away)
            if (s.Rules < LapRules.Version && s.Car.Length == 0) s.Rules = LapRules.Version;
            return s;
        }
    }

    // Valid = the lap iRacing counted (L-1): not through the pits, and the LapRules verdict ("counted" in IbtLaps.LapsJson: timed by iRacing, its own best lap decides, the off-track record only where that says nothing)
    sealed class VLap { public int N; public double Time, T0, T1; public bool Pit, Off, Official, Counted = true; public bool Valid { get { return Time > 15 && !Pit && Counted; } } }
    sealed class VMark { public long Ms; public string Kind = "", Car = "", Track = "", Config = ""; public int Lap; public double Pct, St; public bool Used; }

    // ---------------- reading one .ibt for the Vault ----------------
    static class VaultIbt
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        static double Num(Dictionary<string, object> d, string k) { object o; double v; return d.TryGetValue(k, out o) && o != null && double.TryParse(Convert.ToString(o, Inv), NumberStyles.Float, Inv, out v) ? v : 0; }
        static string Str(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, Inv) : ""; }

        public static Dictionary<string, object> Parse(string json)
        {
            JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue;
            return js.DeserializeObject(json) as Dictionary<string, object>;
        }

        // the laps, the session and (for a race) how it ended
        public static VSession Analyze(string path, out List<VLap> laps, out double st0)
        {
            laps = new List<VLap>(); st0 = 0;
            FileInfo fi = new FileInfo(path);
            Dictionary<string, object> d = Parse(IbtLaps.LapsJson(path));
            if (d == null) return null;
            VSession s = new VSession();
            s.Name = fi.Name; s.Size = fi.Length; s.Rules = LapRules.Version; s.ResV = ResultV;
            s.Car = Str(d, "car"); s.Track = Str(d, "track"); s.Config = Str(d, "config"); s.TrackId = Str(d, "trackId"); s.TrackName = Str(d, "trackName"); s.Type = Str(d, "type");
            s.StartMs = (long)Num(d, "startMs"); st0 = Num(d, "st0"); s.Secs = Num(d, "seconds");
            if (s.StartMs <= 0) s.StartMs = (long)(fi.LastWriteTimeUtc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds - (long)(s.Secs * 1000);
            s.EndMs = s.StartMs + (long)(s.Secs * 1000);
            object ol; IList il = d.TryGetValue("laps", out ol) ? ol as IList : null;
            if (il != null)
                foreach (object o in il)
                {
                    Dictionary<string, object> ld = o as Dictionary<string, object>; if (ld == null) continue;
                    VLap l = new VLap(); l.N = (int)Num(ld, "n"); l.Time = Num(ld, "time"); l.Pit = Num(ld, "pit") != 0; l.Off = Num(ld, "off") != 0; l.Official = Num(ld, "official") != 0; l.T0 = Num(ld, "t0"); l.T1 = Num(ld, "t1");
                    l.Counted = !ld.ContainsKey("counted") || Num(ld, "counted") != 0;
                    laps.Add(l);
                }
            List<VLap> valid = new List<VLap>();
            foreach (VLap l in laps) if (l.Valid) valid.Add(l);
            valid.Sort(delegate (VLap a, VLap b) { int c = a.Time.CompareTo(b.Time); return c != 0 ? c : a.N.CompareTo(b.N); });
            s.ValidLaps = valid.Count;
            if (valid.Count > 0) { s.BestValid = valid[0].Time; s.BestLap = valid[0].N; }
            for (int i = 0; i < valid.Count; i++) s.Top.Add(new[] { (double)valid[i].N, valid[i].Time });
            Result(path, s);
            return s;
        }

        sealed class Drv { public int Idx, Cls, Ir; public bool Pace, Spec; }

        // how a race ended (last record of the file) and what that was worth in iRating; sets Finished / Pos / Field / IrDelta
        public const int ResultV = 1;      // bump when Result() changes what it stores; Vault.FixResults then runs it again on the old rows
        public static void Result(string path, VSession s)
        {
            if (!s.IsRace) return;
            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
            if (t == null) return;
            using (t.fs)
            {
                VarDef vState, vPos, vCls, vNum;
                if (!t.vars.TryGetValue("SessionState", out vState) || !t.vars.TryGetValue("PlayerCarPosition", out vPos) || !t.vars.TryGetValue("PlayerCarClassPosition", out vCls)) return;
                t.vars.TryGetValue("SessionNum", out vNum);
                if (t.records < 10) return;
                byte[] buf = new byte[t.bufLen];
                t.fs.Position = t.dataOff + (t.records - 1) * (long)t.bufLen;
                if (t.fs.Read(buf, 0, t.bufLen) < t.bufLen) return;
                int state = (int)TrackMaps.Read(buf, vState), pos = (int)TrackMaps.Read(buf, vPos), cls = (int)TrackMaps.Read(buf, vCls), num = vNum != null ? (int)TrackMaps.Read(buf, vNum) : -1;
                // the session at the end of the file must be the race (a file can start in qualifying)
                if (num >= 0) { string ty = Career.SessionTypeOf(t.yaml, num); if (ty.Length > 0 && !Regex.IsMatch(ty, "race", RegexOptions.IgnoreCase)) return; }
                if (state < 5) return;                                   // 5 = chequered flag out, 6 = cool down: the result is final
                int classes = 1; int.TryParse(TrackMaps.YamlValue(t.yaml, "NumCarClasses"), out classes);
                int place = classes > 1 ? cls : pos;
                if (place < 1) return;
                s.Finished = true; s.Pos = place;
                // the field: the drivers of my class (not the pace car, not spectators)
                List<Drv> all = new List<Drv>();
                // Only the DriverInfo block, each CarIdx once: the whole-file scan also matched "- CarIdx: 8" and "- CarIdx: 255" in
                // ResultsFastestLap (empty blocks, class 0, not pace, not spectator), so a 20-car race showed "P14 of 22" (2026-10-18 audit).
                string yDrivers = t.yaml; Match dm = Regex.Match(t.yaml, @"(?m)^DriverInfo:[ \t]*\r?\n[\s\S]*?(?=^\S)"); if (dm.Success) yDrivers = dm.Value;
                HashSet<int> seenIdx = new HashSet<int>();
                foreach (Match m in Regex.Matches(yDrivers, @"- CarIdx: (\d+)[ \t]*\r?\n((?:   [^\r\n]*\r?\n?)*)"))
                {
                    if (!seenIdx.Add(int.Parse(m.Groups[1].Value))) continue;
                    string b = m.Groups[2].Value; Drv dv = new Drv(); dv.Idx = int.Parse(m.Groups[1].Value);
                    int.TryParse(TrackMaps.YamlValue(b, "CarClassID"), out dv.Cls); int.TryParse(TrackMaps.YamlValue(b, "IRating"), out dv.Ir);
                    dv.Pace = TrackMaps.YamlValue(b, "CarIsPaceCar") == "1"; dv.Spec = TrackMaps.YamlValue(b, "IsSpectator") == "1";
                    all.Add(dv);
                }
                int meIdx; if (!int.TryParse(TrackMaps.YamlValue(t.yaml, "DriverCarIdx"), out meIdx)) meIdx = -1;
                Drv me = null; foreach (Drv dv in all) if (dv.Idx == meIdx) me = dv;
                if (me == null) return;
                int field = 0; List<double> rated = new List<double>(); int mine = -1;
                foreach (Drv dv in all)
                {
                    if (dv.Pace || dv.Spec || (classes > 1 && dv.Cls != me.Cls)) continue;
                    field++;
                    if (dv.Ir >= 100 || dv.Idx == me.Idx) { if (dv.Idx == me.Idx) mine = rated.Count; rated.Add(dv.Ir); }
                }
                s.Field = field;
                bool official = TrackMaps.YamlValue(t.yaml, "Official") == "1"; s.Official = official;
                // iRating change: official races with a real rated field only (AI cars have none)
                if (official && mine >= 0 && me.Ir >= 100 && rated.Count >= 2 && place <= rated.Count) s.IrDelta = Race.Change(rated, mine, place);
            }
        }
    }

    // ---------------- the Vault ----------------
    static partial class Vault
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly object gate = new object(), workGate = new object();
        static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        // where things live (the sandbox of the tests swaps these for vault-test\...)
        static string realRoot, realSrc;
        public static string Root, SrcDir, NvDirOverride;
        static bool sandbox;
        static long budgetOverride = -1;
        public static int RecentDays = 30;
        static double budgetGb = 60; static string clipMode = "copy"; static bool enabled = false;   // vault=1 in irdash.ini is the only ON
        public static bool Enabled { get { return enabled; } }
        // the test sandbox answers even while vault=0, so the gate can run before the switch is turned on
        public static bool Serving { get { return enabled || sandbox; } }
        public static bool SandboxOn { get { return sandbox; } }

        static readonly Dictionary<string, VMoment> moments = new Dictionary<string, VMoment>();
        static readonly List<VSession> sessions = new List<VSession>();
        static readonly List<VMark> marks = new List<VMark>();
        static readonly List<string[]> pins = new List<string[]>();      // {session name, lap (0 = the race)}
        static readonly HashSet<string> deleted = new HashSet<string>();
        static readonly HashSet<string> dirty = new HashSet<string>();
        static readonly HashSet<string> clipsSeen = new HashSet<string>();
        static readonly HashSet<string> pretendOnline = new HashSet<string>(StringComparer.OrdinalIgnoreCase);   // sandbox only: the test cannot set OneDrive's recall bit on a normal file
        static bool started;
        static string status = "waiting";                // what the worker is doing, for the page
        static int scanLeft; static DateTime lastWork = DateTime.MinValue;
        static double globalNudge;
        static DateTime watchSince = DateTime.UtcNow;

        public static long Now() { return (long)(DateTime.UtcNow - Epoch).TotalMilliseconds; }
        static long Ms(DateTime utc) { return (long)(utc - Epoch).TotalMilliseconds; }
        static string P(string rel) { return Path.Combine(Root, rel); }
        static string N3(double d) { return d.ToString("0.000", Inv); }
        public static string Lap(double t) { return PbRef.Lap(t); }
        static string Slug(string s) { string r = Combo.Slug(s); return r.Length == 0 ? "x" : r; }

        // ---------------- start ----------------
        public static void Init(string rootDir)
        {
            realRoot = Path.Combine(rootDir, "vault"); realSrc = TrackMaps.TelemetryDir;
            Root = realRoot; SrcDir = realSrc;
            ReadIni();
            if (!enabled) { Log.W("vault: switched off (vault=0 in irdash.ini)"); status = "off"; return; }   // no folder, no index, no scan
            try { Directory.CreateDirectory(Root); } catch { }
            Load();
        }

        // irdash.ini:  vault=1 to turn it on (anything else, including a missing line, is off)
        //              vault_gb=60   vault_recent_days=30   vault_clip_mode=copy|move
        static void ReadIni()
        {
            enabled = false; budgetGb = 60; RecentDays = 30; clipMode = "copy";   // a missing line is the default, including after a test changed the window
            try
            {
                if (Program.IniFile == null || !File.Exists(Program.IniFile)) return;
                foreach (string raw in File.ReadAllLines(Program.IniFile))
                {
                    string l = raw.Trim(); if (l.Length == 0 || l.StartsWith(";")) continue;
                    int e = l.IndexOf('='); if (e <= 0) continue;
                    string k = l.Substring(0, e).Trim().ToLowerInvariant(), v = l.Substring(e + 1).Trim();
                    double d; int n;
                    if (k == "vault_gb" && double.TryParse(v, NumberStyles.Float, Inv, out d) && d > 0) budgetGb = d;
                    else if (k == "vault_recent_days" && int.TryParse(v, out n) && n >= 1 && n <= 365) RecentDays = n;
                    else if (k == "vault_clip_mode" && (v == "copy" || v == "move")) clipMode = v;
                    else if (k == "vault") enabled = v == "1";
                }
            }
            catch (Exception ex) { Log.W("vault: irdash.ini: " + ex.Message); }
            try { Wheel.ReadBinding(); } catch { }
        }

        static long BudgetBytes { get { return budgetOverride >= 0 ? budgetOverride : (long)(budgetGb * 1024 * 1024 * 1024); } }

        public static void Start()
        {
            if (!enabled) { status = "off"; return; }
            Wheel.Ensure();
            if (started) return; started = true;
            Thread t = new Thread(Worker); t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Name = "VaultWorker"; t.Start();
        }

        // ---------------- files: load and save ----------------
        static void Load()
        {
            lock (gate)
            {
                moments.Clear(); sessions.Clear(); marks.Clear(); pins.Clear(); deleted.Clear(); clipsSeen.Clear(); dirty.Clear();
                try
                {
                    string f = P("moments.json");
                    if (File.Exists(f))
                    {
                        object o = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(File.ReadAllText(f, Encoding.UTF8));
                        IList l = o as IList;
                        if (l != null) foreach (object x in l) { Dictionary<string, object> d = x as Dictionary<string, object>; if (d == null) continue; VMoment m = VMoment.FromDict(d); if (m.Id.Length > 0) moments[m.Id] = m; }
                    }
                    f = P("sessions.tsv");
                    if (File.Exists(f)) foreach (string line in File.ReadAllLines(f, Encoding.UTF8)) { VSession s = VSession.FromRow(line); if (s != null) sessions.Add(s); }
                    f = P("marks.tsv");
                    if (File.Exists(f))
                        foreach (string line in File.ReadAllLines(f, Encoding.UTF8))
                        {
                            string[] c = line.Split('\t'); if (c.Length < 9) continue;
                            VMark mk = new VMark(); long.TryParse(c[0], out mk.Ms); mk.Kind = c[1]; mk.Car = c[2]; mk.Track = c[3]; mk.Config = c[4]; int.TryParse(c[5], out mk.Lap);
                            double.TryParse(c[6], NumberStyles.Float, Inv, out mk.Pct); double.TryParse(c[7], NumberStyles.Float, Inv, out mk.St); mk.Used = c[8] == "1"; marks.Add(mk);
                        }
                    f = P("pins.tsv");
                    if (File.Exists(f)) foreach (string line in File.ReadAllLines(f, Encoding.UTF8)) { string[] c = line.Split('\t'); if (c.Length >= 2) pins.Add(c); }
                    f = P("deleted.txt");
                    if (File.Exists(f)) foreach (string line in File.ReadAllLines(f, Encoding.UTF8)) if (line.Trim().Length > 0) deleted.Add(line.Trim());
                    f = P("clips-seen.tsv");
                    if (File.Exists(f)) foreach (string line in File.ReadAllLines(f, Encoding.UTF8)) if (line.Trim().Length > 0) clipsSeen.Add(line.Trim());
                    f = P("settings.json");
                    if (File.Exists(f))
                    {
                        Dictionary<string, object> sd = VaultIbt.Parse(File.ReadAllText(f, Encoding.UTF8)); object ov;
                        if (sd != null && sd.TryGetValue("nudge", out ov)) double.TryParse(Convert.ToString(ov, Inv), NumberStyles.Float, Inv, out globalNudge);
                        if (sd != null && sd.TryGetValue("watchSince", out ov)) { long ws; if (long.TryParse(Convert.ToString(ov, Inv), out ws) && ws > 0) watchSince = Epoch.AddMilliseconds(ws); }
                    }
                    else watchSince = DateTime.UtcNow;
                }
                catch (Exception ex) { Log.W("vault: could not read the index (" + ex.Message + ")"); }
            }
        }

        static void WriteAtomic(string file, string text)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file));
            string tmp = file + ".tmp";
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            if (File.Exists(file)) File.Delete(file);
            File.Move(tmp, file);
        }

        static void SaveAll()
        {
            lock (gate)
            {
                try
                {
                    StringBuilder sb = new StringBuilder("[");
                    bool first = true;
                    List<VMoment> list = new List<VMoment>(moments.Values);
                    list.Sort(delegate (VMoment a, VMoment b) { return a.Ts.CompareTo(b.Ts); });
                    foreach (VMoment m in list) { if (!first) sb.Append(",\n"); first = false; sb.Append(m.Json(false)); }
                    sb.Append("]");
                    WriteAtomic(P("moments.json"), sb.ToString());
                    foreach (string id in dirty)
                    {
                        VMoment m; string dir = P(@"items\" + id);
                        if (moments.TryGetValue(id, out m)) { Directory.CreateDirectory(dir); File.WriteAllText(Path.Combine(dir, "moment.json"), m.Json(false), new UTF8Encoding(false)); }
                        else if (Directory.Exists(dir)) { try { Directory.Delete(dir, true); } catch { } }
                    }
                    dirty.Clear();
                    StringBuilder ss = new StringBuilder(); foreach (VSession s in sessions) ss.Append(s.Row()).Append("\r\n");
                    WriteAtomic(P("sessions.tsv"), ss.ToString());
                    StringBuilder mk = new StringBuilder();
                    foreach (VMark m in marks) mk.Append(m.Ms).Append('\t').Append(m.Kind).Append('\t').Append(m.Car.Replace('\t', ' ')).Append('\t').Append(m.Track.Replace('\t', ' ')).Append('\t').Append(m.Config.Replace('\t', ' ')).Append('\t').Append(m.Lap).Append('\t')
                        .Append(m.Pct.ToString("0.0000", Inv)).Append('\t').Append(m.St.ToString("0.000", Inv)).Append('\t').Append(m.Used ? "1" : "0").Append("\r\n");
                    WriteAtomic(P("marks.tsv"), mk.ToString());
                    StringBuilder pn = new StringBuilder(); foreach (string[] p in pins) pn.Append(string.Join("\t", p)).Append("\r\n");
                    WriteAtomic(P("pins.tsv"), pn.ToString());
                    WriteAtomic(P("deleted.txt"), string.Join("\r\n", new List<string>(deleted).ToArray()));
                    WriteAtomic(P("clips-seen.tsv"), string.Join("\r\n", new List<string>(clipsSeen).ToArray()));
                    WriteAtomic(P("settings.json"), "{\"nudge\":" + globalNudge.ToString("0.##", Inv) + ",\"watchSince\":" + Ms(watchSince) + "}");
                }
                catch (Exception ex) { Log.W("vault: could not save the index (" + ex.Message + ")"); }
            }
        }

        // ---------------- the background worker ----------------
        static void Worker()
        {
            Thread.Sleep(45000);          // never compete with boot
            DateTime lastClip = DateTime.MinValue, lastBudget = DateTime.MinValue;
            while (true)
            {
                try
                {
                    bool driving = Program.IsDriving, more = false, ran = false;
                    if (!driving && !sandbox)
                    {
                        lock (workGate)         // the tests swap the vault folders under this same lock
                        {
                            if (!sandbox)
                            {
                                ran = true;
                                more = ScanSessions(false, 3);
                                if ((DateTime.Now - lastBudget).TotalMinutes > 10) { lastBudget = DateTime.Now; Prune(); }
                                Thumbs(2);
                                if ((DateTime.Now - lastClip).TotalSeconds >= 5) { lastClip = DateTime.Now; WatchClips(); }
                            }
                        }
                        if (ran) { status = more ? "reading older sessions" : "up to date"; Thread.Sleep(more ? 4000 : 20000); }
                        else Thread.Sleep(5000);
                    }
                    else { status = driving ? "paused while driving" : "test"; Thread.Sleep(5000); }
                }
                catch (Exception ex) { Log.W("vault worker: " + ex.Message); Thread.Sleep(30000); }
            }
        }

        static bool pretendSim, pretendDisconnected; // sandbox-only safety fixture; never starts the real sim
        static bool SimRunning()
        {
            if (sandbox && pretendSim) return true;
            try { if (Process.GetProcessesByName("iRacingSim64DX11").Length > 0) return true; } catch { }
            return false;
        }

        // ---- C-27: the newest telemetry file of a session that is OVER while the sim program is still open (results, replay) ----
        // The Vault used to leave the newest file alone for as long as iRacingSim64DX11 ran, so after a race the saved laps showed up
        // only when he closed the sim. Now that file is read once (1) no session is running, (2) he is not driving and (3) it has
        // stopped growing. Never in a running session: a live file keeps growing, and a link that is down for under 3 s is a blip.
        static DateTime overSince = DateTime.MinValue, nudgeAt = DateTime.MinValue, growSince = DateTime.MinValue;
        static string growName = ""; static long growSize = -1;
        static int overBusy;                    // 1 while the reader thread works

        // While the sim is open, only positive SDK evidence can prove that the session ended.
        static bool SessionOver()
        {
            bool over = false;
            try
            {
                Frame f = Sdk.Latest;
                bool connected = f.Connected && !(sandbox && pretendDisconnected);
                if (!connected) over = false;                                                        // a lost link may still be an active session
                else over = f.Num("IsOnTrack") == 0 && f.Num("SessionState") >= 5;
                if (over && Program.IsDriving) over = false;
            }
            catch { over = false; }
            if (!over) { overSince = DateTime.MinValue; return false; }
            if (overSince == DateTime.MinValue) overSince = DateTime.Now;
            return (DateTime.Now - overSince).TotalSeconds >= 3;
        }

        // The same size and no write for `secs` seconds. Each call is one look; the first look only starts the clock.
        static bool Settled(FileInfo fi, double secs)
        {
            DateTime now = DateTime.Now;
            if (growName != fi.Name || growSize != fi.Length) { growName = fi.Name; growSize = fi.Length; growSince = now; return false; }
            return (now - growSince).TotalSeconds >= secs && (now - fi.LastWriteTime).TotalSeconds >= secs;
        }

        // The after-race strip asks for this while it waits for laps (wheel.cs Pump). Own BelowNormal thread, so the wheel buttons never wait for a 60 MB read.
        public static void ReadNewestIfOver()
        {
            if (!Serving || (DateTime.Now - nudgeAt).TotalSeconds < 1.5) return;
            nudgeAt = DateTime.Now;
            if (Interlocked.CompareExchange(ref overBusy, 1, 0) != 0) return;
            Thread t = new Thread(delegate ()
            {
                try { lock (workGate) { if (!Program.IsDriving) ScanSessions(false, 1, true); } }
                catch (Exception ex) { Log.W("vault: finished-session read: " + ex.Message); }
                finally { overBusy = 0; }
            });
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Start();
        }

        // Reads telemetry files nobody has read yet (oldest first, so personal bests come out in order), at most `max` per call.
        // Skips a file touched in the last 2 minutes and, while the sim runs, the newest file (unless that session is over and the file has settled).
        // Returns true when more are waiting.
        public static bool ScanSessions(bool test, int max) { return ScanSessions(test, max, false); }

        // newestOnly: only the newest file (the finished session the strip is waiting for); older unread files stay for the worker.
        static bool ScanSessions(bool test, int max, bool newestOnly)
        {
            if (SrcDir == null || !Directory.Exists(SrcDir)) return false;
            if (!test && !Program.IsDriving) FixResults();
            List<FileInfo> files = new List<FileInfo>(new DirectoryInfo(SrcDir).GetFiles("*.ibt"));
            files.Sort(delegate (FileInfo a, FileInfo b) { return string.Compare(StampOf(a.Name), StampOf(b.Name), StringComparison.Ordinal); });
            bool sim = !test && SimRunning();
            bool over = sim && SessionOver();
            FileInfo newest = files.Count > 0 ? files[files.Count - 1] : null;
            HashSet<string> have = new HashSet<string>();
            // a row made under the old lap rule (Rules < LapRules.Version) is read again; one that failed to read again is left alone until irdash restarts
            lock (gate) foreach (VSession s in sessions) if (s.Rules >= LapRules.Version || rereadSkip.Contains(s.Name + "|" + s.Size)) have.Add(s.Name + "|" + s.Size);
            int done = 0, left = 0; bool changed = false;
            foreach (FileInfo fi in files)
            {
                if (have.Contains(fi.Name + "|" + fi.Length)) continue;
                if (newestOnly && (newest == null || fi.Name != newest.Name)) continue;
                bool live = sim && newest != null && fi.Name == newest.Name;                                     // the file the sim may still be writing
                bool settled = live && over && Settled(fi, 6);                                                  // C-27: its session is over and it stopped growing
                if (!test && !settled && (DateTime.Now - fi.LastWriteTime).TotalSeconds < 120) { left++; continue; }       // still being written
                if (live && !settled) { left++; continue; }
                if (Career.OnlineOnly(fi) || (sandbox && pretendOnline.Contains(fi.Name))) continue;            // reading an online-only file would start a OneDrive download
                if (done >= max) { left++; continue; }
                if (!test && Program.IsDriving) { left++; break; }
                if (settled) Log.W("vault: " + fi.Name + " - the session is over and the file has stopped growing, reading it while the sim is still open");
                try { if (ProcessFile(fi)) changed = true; }
                catch (Exception ex) { Log.W("vault: " + fi.Name + ": " + ex.Message); if (HasOldRow(fi)) rereadSkip.Add(fi.Name + "|" + fi.Length); else { AddSessionStub(fi); changed = true; } }
                done++;
                if (!test) Thread.Sleep(150);
            }
            if (!newestOnly) scanLeft = left;
            if (changed || done > 0) { Reconcile(); LinkClips(); SaveAll(); }
            return left > 0;
        }

        // His incident count at the end of the race that a field log (start time startMs) belongs to, read from the telemetry file (last record) - for logs from before
        // the log kept it itself. The file is the one whose first record is nearest the log start (within 90 s); -1 = no file / not a race at its end / still being written.
        static readonly Dictionary<string, int> incCache = new Dictionary<string, int>();
        public static int IncidentsFor(long startMs, int sessNum)
        {
            if (SrcDir == null || !Directory.Exists(SrcDir) || startMs <= 0) return -1;
            string name = null; long bestD = 90000;
            lock (gate) foreach (VSession s in sessions) { long d = Math.Abs(s.StartMs - startMs); if (s.Name.Length > 0 && d <= bestD) { bestD = d; name = s.Name; } }
            // The field log can start long BEFORE the telemetry file (it logs the grid and the pre-race; 2026-10-12: log 15:29:58, file 15:35:30,
            // 5.5 min apart), so no file was found within 90 s and the incident count fell back to the sim's results text (5, really 13).
            // Then: the file whose own span holds the log's start, or that begins within 15 min after it.
            if (name == null) lock (gate) foreach (VSession s in sessions)
            {
                if (s.Name.Length == 0 || s.StartMs <= 0) continue;
                bool inside = startMs >= s.StartMs && startMs <= (s.EndMs > 0 ? s.EndMs : s.StartMs + 14400000), shortlyBefore = s.StartMs >= startMs && s.StartMs - startMs <= 900000;
                long d = Math.Abs(s.StartMs - startMs);
                if ((inside || shortlyBefore) && d < bestD + 900000 && (name == null || d < bestD)) { bestD = d; name = s.Name; }
            }
            if (name == null) return -1;
            return IncidentsOfFile(name, sessNum);
        }

        // His own incident counter at the end of one telemetry file's race session (cached). The debrief knows exactly which file it shows,
        // so it asks by name instead of guessing from the field log's start time (2026-10-12: two files 5 minutes apart, the guess took the first).
        public static int IncidentsOfFile(string name, int sessNum)
        {
            if (SrcDir == null || string.IsNullOrEmpty(name)) return -1;
            lock (incCache) { int hit; if (incCache.TryGetValue(name + "|" + sessNum, out hit)) return hit; }
            int res = -1;
            try
            {
                string p = Path.Combine(SrcDir, name); FileInfo fi = new FileInfo(p);
                if (!fi.Exists || (DateTime.Now - fi.LastWriteTime).TotalSeconds < 120 || Career.OnlineOnly(fi)) return -1;      // not cached: try again later
                TrackMaps.Ibt t = TrackMaps.OpenIbt(p, true);
                if (t != null)
                    using (t.fs)
                    {
                        VarDef vInc, vNum;
                        if (t.records >= 10 && t.vars.TryGetValue("PlayerCarMyIncidentCount", out vInc))
                        {
                            t.vars.TryGetValue("SessionNum", out vNum);
                            byte[] buf = new byte[t.bufLen]; t.fs.Position = t.dataOff + (t.records - 1) * (long)t.bufLen;
                            if (t.fs.Read(buf, 0, t.bufLen) == t.bufLen)
                            {
                                int num = vNum != null ? (int)TrackMaps.Read(buf, vNum) : -1;
                                string ty = num >= 0 ? Career.SessionTypeOf(t.yaml, num) : "race";
                                if ((num < 0 || num == sessNum) && Regex.IsMatch(ty, "race", RegexOptions.IgnoreCase)) res = (int)TrackMaps.Read(buf, vInc);
                            }
                        }
                    }
            }
            catch (Exception ex) { Log.W("vault: incidents for " + name + ": " + ex.Message); return -1; }
            Log.W("vault: incidents for " + name + " (session " + sessNum + ") = " + res);
            lock (incCache) incCache[name + "|" + sessNum] = res;
            return res;
        }

        // Rows read before VaultIbt.ResultV: run only the (cheap, yaml + last record) race result again so a stored "P14 of 22" becomes "P14 of 20" without re-reading every lap.
        static void FixResults()
        {
            List<VSession> todo; lock (gate) todo = sessions.FindAll(delegate (VSession x) { return x.ResV < VaultIbt.ResultV; });
            if (todo.Count == 0) return;
            foreach (VSession s in todo)
            {
                try
                {
                    string p = s.Name.Length > 0 ? Path.Combine(SrcDir, s.Name) : "";
                    if (s.IsRace && s.Finished && p.Length > 0 && File.Exists(p))
                    {
                        FileInfo fi = new FileInfo(p);
                        if ((DateTime.Now - fi.LastWriteTime).TotalSeconds < 120 || Career.OnlineOnly(fi)) continue;      // still being written / would start a OneDrive download: try next time
                        lock (gate) { VaultIbt.Result(p, s); s.ResV = VaultIbt.ResultV; }
                    }
                    else lock (gate) s.ResV = VaultIbt.ResultV;
                }
                catch (Exception ex) { Log.W("vault: result fix " + s.Name + ": " + ex.Message); lock (gate) s.ResV = VaultIbt.ResultV; }
            }
            Reconcile(); LinkClips(); SaveAll();
        }

        static string StampOf(string name) { Match m = Regex.Match(name, @"(\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2})\.ibt$"); return m.Success ? m.Groups[1].Value : name; }

        // a file that could not be read is remembered, so it is not tried again every 20 s
        static void AddSessionStub(FileInfo fi)
        {
            VSession s = new VSession(); s.Name = fi.Name; s.Size = fi.Length; s.StartMs = Ms(fi.LastWriteTimeUtc); s.EndMs = s.StartMs; s.Rules = LapRules.Version;
            lock (gate) sessions.Add(s);
        }

        static readonly HashSet<string> rereadSkip = new HashSet<string>();      // name|size of a file with an old-rule row that could not be read again (this run)
        static bool HasOldRow(FileInfo fi) { lock (gate) { foreach (VSession x in sessions) if (x.Name == fi.Name && x.Size == fi.Length) return true; } return false; }

        static bool ProcessFile(FileInfo fi)
        {
            List<VLap> laps; double st0;
            VSession s = VaultIbt.Analyze(fi.FullName, out laps, out st0);
            if (s == null)
            {
                if (HasOldRow(fi)) { rereadSkip.Add(fi.Name + "|" + fi.Length); return false; }      // keep what the old row said
                AddSessionStub(fi); return true;
            }
            lock (gate)
            {
                sessions.RemoveAll(delegate (VSession x) { return x.Name == s.Name && x.Size == s.Size; });      // L-1: the row made under the old rule is replaced
                sessions.Add(s);
                // keep marks (the KEEP key) made while this session ran
                foreach (VMark mk in marks)
                {
                    if (mk.Used || mk.Kind != "keep" || mk.Ms < s.StartMs - 5000 || mk.Ms > s.EndMs + 5000) continue;
                    mk.Used = true;
                    VLap pick = null;
                    foreach (VLap l in laps) if (l.Valid && l.N <= mk.Lap && (pick == null || l.N > pick.N)) pick = l;       // the lap just driven, else the one before it
                    if (pick == null) foreach (VLap l in laps) if (l.Time > 15 && l.N <= mk.Lap && (pick == null || l.N > pick.N)) pick = l;
                    if (pick != null) pins.Add(new[] { s.Name, pick.N.ToString(Inv), N3(pick.Time) });
                    if (s.IsRace && s.Finished) pins.Add(new[] { s.Name, "0", N3(s.BestValid) });
                }
            }
            Log.W("vault: read " + fi.Name + " (" + s.Car + ", " + s.Track + ", " + s.Type + ", " + s.ValidLaps + " clean laps" + (s.BestValid > 0 ? ", best " + Lap(s.BestValid) : "") + (s.Finished ? ", finished P" + s.Pos + " of " + s.Field : "") + ")");
            return true;
        }

        // ---------------- which moments should exist (the rules) ----------------
        sealed class Want { public string Id, Kind; public VSession S; public int Lap; public double LapTime, PbBefore; public List<string> Tags = new List<string>(); public bool Pin; }

        static string LapId(VSession s, int lap) { return "l" + Epoch.AddMilliseconds(s.StartMs).ToString("yyyyMMdd-HHmmss", Inv) + "-" + lap; }
        static string RaceId(VSession s) { return "r" + Epoch.AddMilliseconds(s.StartMs).ToString("yyyyMMdd-HHmmss", Inv); }

        static void AddTag(Want w, string t) { if (!w.Tags.Contains(t)) w.Tags.Add(t); }

        // Works out, from every session read so far, which laps and races are worth keeping, then makes the moments match.
        // Pure rules over sessions.tsv, pins and clips, so reading a file late gives the same answer as reading it on time.
        public static void Reconcile()
        {
            lock (gate)
            {
                Dictionary<string, Want> want = new Dictionary<string, Want>();
                Func<VSession, int, double, Want> get = delegate (VSession s, int lap, double time)
                {
                    string id = lap > 0 ? LapId(s, lap) : RaceId(s); Want w;
                    if (!want.TryGetValue(id, out w)) { w = new Want(); w.Id = id; w.Kind = lap > 0 ? "lap" : "race"; w.S = s; w.Lap = lap; w.LapTime = time; want[id] = w; }
                    return w;
                };
                Dictionary<string, List<VSession>> byCombo = new Dictionary<string, List<VSession>>();
                foreach (VSession s in sessions)
                {
                    if (s.Car.Length == 0 || s.ValidLaps == 0 && !s.Finished) continue;
                    List<VSession> l; if (!byCombo.TryGetValue(s.Combo, out l)) { l = new List<VSession>(); byCombo[s.Combo] = l; }
                    l.Add(s);
                }
                long recentFrom = Now() - (long)RecentDays * 86400000L;
                foreach (KeyValuePair<string, List<VSession>> kv in byCombo)
                {
                    List<VSession> l = kv.Value;
                    l.Sort(delegate (VSession a, VSession b) { return a.StartMs.CompareTo(b.StartMs); });
                    // 1. a new personal best: the session's quickest clean lap beats every earlier session
                    double run = 0;
                    foreach (VSession s in l)
                    {
                        if (s.BestValid <= 0) continue;
                        if (run > 0 && s.BestValid < run - 0.0005) { Want w = get(s, s.BestLap, s.BestValid); AddTag(w, "PB"); w.PbBefore = run; }
                        if (run == 0 || s.BestValid < run) run = s.BestValid;
                    }
                    // 2. the three quickest clean laps ever on this car and track
                    List<object[]> all = new List<object[]>();
                    foreach (VSession s in l) foreach (double[] t in s.Top) all.Add(new object[] { s, (int)t[0], t[1] });
                    all.Sort(delegate (object[] a, object[] b) { int c = ((double)a[2]).CompareTo((double)b[2]); return c != 0 ? c : ((VSession)a[0]).StartMs.CompareTo(((VSession)b[0]).StartMs); });
                    for (int i = 0; i < all.Count && i < 3; i++) AddTag(get((VSession)all[i][0], (int)all[i][1], (double)all[i][2]), "BEST LAP");
                    // 2b. the fastest tenth of every clean lap on this car and track (the best three above are already inside this when there are 30 or more)
                    int n10 = (int)Math.Ceiling(all.Count * 0.10);
                    for (int i = 0; i < all.Count && i < n10; i++) AddTag(get((VSession)all[i][0], (int)all[i][1], (double)all[i][2]), "TOP 10");
                    // 3. race finishes
                    int priorRaces = 0, bestPrior = 999;
                    foreach (VSession s in l)
                    {
                        if (!(s.IsRace && s.Finished && s.Pos > 0)) continue;
                        Want w = get(s, 0, s.BestValid);
                        if (s.Pos == 1 && s.Field >= 2) AddTag(w, "WIN");
                        else if (s.Pos <= 3 && s.Field >= 4) AddTag(w, "PODIUM");
                        if (s.IrDelta >= 40) AddTag(w, "BIG IR");
                        if (priorRaces >= 2 && s.Pos < bestPrior && s.Field >= 4 && !w.Tags.Contains("WIN")) AddTag(w, "BEST RACE");
                        priorRaces++; if (s.Pos < bestPrior) bestPrior = s.Pos;
                    }
                    // 4. everything else from the last days stays as "recent" (a race for a race, else the quickest lap)
                    foreach (VSession s in l)
                    {
                        if (s.StartMs < recentFrom) continue;
                        if (s.IsRace && s.Finished && s.Pos > 0) get(s, 0, s.BestValid);
                        else if (s.BestValid > 0) get(s, s.BestLap, s.BestValid);
                    }
                }
                // 5. laps and races pinned with the KEEP key
                foreach (string[] p in pins)
                {
                    VSession s = null; foreach (VSession x in sessions) if (x.Name == p[0]) { s = x; break; }
                    int lap; double tm; if (s == null || !int.TryParse(p[1], out lap)) continue; double.TryParse(p.Length > 2 ? p[2] : "0", NumberStyles.Float, Inv, out tm);
                    get(s, lap, tm).Pin = true;
                }
                // make the moments match
                foreach (Want w in want.Values)
                {
                    if (deleted.Contains(w.Id)) continue;
                    VMoment m; bool isNew = !moments.TryGetValue(w.Id, out m);
                    if (isNew)
                    {
                        m = new VMoment(); m.Id = w.Id; m.Kind = w.Kind; m.Created = Now(); moments[w.Id] = m;
                        m.Car = w.S.Car; m.Track = w.S.Track; m.Config = w.S.Config; m.TrackId = w.S.TrackId; m.TrackName = w.S.TrackName; m.SType = w.S.Type; m.StartMs = w.S.StartMs;
                        m.Session = w.S.Name; m.IbtSrc = w.S.Name; m.Official = w.S.Official;
                    }
                    m.Lap = w.Lap > 0 ? w.Lap : (w.S.BestLap > 0 ? w.S.BestLap : 0); m.LapTime = w.LapTime > 0 ? w.LapTime : w.S.BestValid;
                    if (w.Lap > 0 && w.PbBefore > 0) m.PbBefore = w.PbBefore;
                    // lap end / race end
                    m.Ts = w.S.EndMs;
                    if (w.Kind == "race") { m.Finished = w.S.Finished; m.Pos = w.S.Pos; m.Field = w.S.Field; m.IrDelta = w.S.IrDelta; m.Official = w.S.Official; }
                    List<string> keepTags = new List<string>(); foreach (string t in w.Tags) keepTags.Add(t);
                    string oldTags = string.Join("|", m.Tags.ToArray());
                    List<string> nt = new List<string>(keepTags);
                    foreach (string t in m.Tags)
                    {
                        // automatic tags come only from the rules above, so a beaten lap loses BEST LAP. A tag Peter added (OVERTAKE, a note's chip) stays.
                        if (t == "PB" || t == "BEST LAP" || t == "TOP 10" || t == "WIN" || t == "PODIUM" || t == "BEST RACE" || t == "BIG IR") continue;
                        if (!nt.Contains(t)) nt.Add(t);
                    }
                    m.Tags = nt;
                    if (w.Pin && !m.Pinned) m.Pinned = true;
                    if (isNew || oldTags != string.Join("|", m.Tags.ToArray()) || w.Pin) dirty.Add(m.Id);
                }
                // moments nobody wants any more: a recent item that aged out, a best-3 lap that was beaten (never one Peter starred or wrote on, never a clip)
                List<string> drop = new List<string>();
                foreach (VMoment m in moments.Values)
                {
                    if (m.Kind == "clip" || want.ContainsKey(m.Id) || m.Pinned || m.Note.Length > 0 || m.Video.Length > 0) continue;
                    drop.Add(m.Id);
                }
                foreach (string id in drop) RemoveMoment(id, false);
                // a copy of the telemetry for every keeper (and for clips, which need it for the sync)
                foreach (VMoment m in new List<VMoment>(moments.Values))
                {
                    if (m.Kind == "clip" || !m.Keeper || m.Ibt.Length > 0) continue;
                    if (EnsureCopy(m)) dirty.Add(m.Id);
                }
            }
        }

        // ---------------- the untouched telemetry copy ----------------
        static string OriginalPath(VMoment m)
        {
            if (m.IbtSrc.Length == 0 || SrcDir == null) return null;
            string p = Path.Combine(SrcDir, m.IbtSrc);
            return File.Exists(p) ? p : null;
        }

        public static string TelemetryPath(VMoment m)
        {
            if (m.Ibt.Length > 0) { string c = P(m.Ibt); if (File.Exists(c)) return c; }
            string o = OriginalPath(m);
            if (o != null && !Career.OnlineOnly(new FileInfo(o))) return o;
            return null;
        }

        // For the recorder (recorder.cs): where and when a saved lap was driven, so its own video can be found. False for anything that is not a lap.
        internal static bool MomentWhen(string id, out string combo, out int lap, out double lapTime, out long fromMs, out long toMs)
        {
            combo = ""; lap = 0; lapTime = 0; fromMs = 0; toMs = 0;
            if (!ValidId(id)) return false;
            lock (gate)
            {
                VMoment m; if (!moments.TryGetValue(id, out m) || m.Lap <= 0) return false;
                combo = m.Combo; lap = m.Lap; lapTime = m.LapTime; fromMs = m.StartMs; toMs = m.StartMs + 6L * 3600 * 1000;
                foreach (VSession s in sessions) if (s.Name == m.Session) { fromMs = s.StartMs; toMs = s.EndMs; break; }
                return fromMs > 0;
            }
        }

        // For the recorder (recorder.cs): the session a telemetry file belongs to, so a lap named by "<file>.ibt:<lap>" finds its video like a Vault lap does
        // (the Session Review and the Workbench open laps by file name). The name is the file's own or that of the Vault's copy of it; a bare name only, never a path.
        internal static bool SessionWhen(string file, out string combo, out long fromMs, out long toMs)
        {
            combo = ""; fromMs = 0; toMs = 0;
            if (string.IsNullOrEmpty(file) || file.Length > 200 || file.IndexOfAny(new[] { '\\', '/', ':' }) >= 0) return false;
            lock (gate)
            {
                VSession hit = null;
                foreach (VSession s in sessions) if (string.Equals(s.Name, file, StringComparison.OrdinalIgnoreCase)) { hit = s; break; }
                if (hit == null)
                    foreach (VMoment m in moments.Values)
                    {
                        if (m.Ibt.Length == 0 || !string.Equals(Path.GetFileName(m.Ibt), file, StringComparison.OrdinalIgnoreCase)) continue;
                        foreach (VSession s in sessions) if (s.Name == m.Session) { hit = s; break; }
                        break;
                    }
                if (hit == null || hit.StartMs <= 0) return false;
                combo = hit.Combo; fromMs = hit.StartMs; toMs = hit.EndMs > hit.StartMs ? hit.EndMs : hit.StartMs + 6L * 3600 * 1000;
                return true;
            }
        }

        // The file behind a vault moment id, for /analysis/lap?id=. Null when the id is unknown or the file is online-only.
        public static string FileForId(string id)
        {
            if (string.IsNullOrEmpty(id) || !ValidId(id)) return null;
            VMoment m;
            if (!moments.TryGetValue(id, out m) || m == null) return null;
            return TelemetryPath(m);
        }

        static bool EnsureCopy(VMoment m)
        {
            try
            {
                string src = OriginalPath(m);
                if (src == null) return false;
                FileInfo fi = new FileInfo(src);
                if (Career.OnlineOnly(fi)) return false;
                string stamp = Epoch.AddMilliseconds(m.StartMs).ToLocalTime().ToString("yyyy-MM-dd HH-mm-ss", Inv);       // the same clock as iRacing's own file name
                string rel = @"telemetry\" + Slug(m.Car) + @"\" + Slug(m.Track + " " + m.Config) + @"\" + stamp + ".ibt";
                string dest = P(rel);
                if (File.Exists(dest) && new FileInfo(dest).Length == fi.Length) { m.Ibt = rel; m.IbtSize = fi.Length; return true; }
                if (FreeBytes(Root) < fi.Length + 3L * 1024 * 1024 * 1024) { Log.W("vault: not copying " + fi.Name + " - less than 3 GB would be left on the disk"); return false; }
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                CopyFile(src, dest + ".tmp");
                if (File.Exists(dest)) File.Delete(dest);
                File.Move(dest + ".tmp", dest);
                try { File.SetLastWriteTimeUtc(dest, fi.LastWriteTimeUtc); } catch { }
                m.Ibt = rel; m.IbtSize = fi.Length;
                // keepers and clips of the same session share the copy. A recent lap keeps no copy of its own.
                foreach (VMoment o in moments.Values) if (o.Session == m.Session && o.Ibt.Length == 0 && (o.Keeper || o.Kind == "clip")) { o.Ibt = rel; o.IbtSize = fi.Length; dirty.Add(o.Id); }
                Log.W("vault: kept a copy of " + fi.Name + " (" + (fi.Length / 1048576) + " MB) for " + m.Id);
                return true;
            }
            catch (Exception ex) { Log.W("vault: copy for " + m.Id + ": " + ex.Message); return false; }
        }

        // reads with FileShare.ReadWrite, in 1 MB pieces, with a short rest now and then so the sim's disk is never starved
        static void CopyFile(string src, string dest)
        {
            using (FileStream a = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (FileStream b = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                byte[] buf = new byte[1 << 20]; int n, since = 0;
                while ((n = a.Read(buf, 0, buf.Length)) > 0) { b.Write(buf, 0, n); if (++since % 8 == 0 && !sandbox) Thread.Sleep(3); }
            }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetDiskFreeSpaceEx(string dir, out ulong avail, out ulong total, out ulong free);
        static long FreeBytes(string path)
        {
            try { ulong a, t, f; string root = Path.GetPathRoot(Path.GetFullPath(path)); if (GetDiskFreeSpaceEx(root, out a, out t, out f)) return (long)a; } catch { }
            return long.MaxValue;
        }

        // takes a moment away, and its files when nothing else uses them
        static void RemoveMoment(string id, bool tombstone)
        {
            VMoment m; if (!moments.TryGetValue(id, out m)) return;
            moments.Remove(id); dirty.Add(id);
            if (tombstone) deleted.Add(id);
            try { string th = P(@"thumbs\" + id + ".png"); if (File.Exists(th)) File.Delete(th); } catch { }
            try { string fr = FramePath(id); if (File.Exists(fr)) File.Delete(fr); } catch { }
            if (m.Video.Length > 0) { try { string v = P(m.Video); if (File.Exists(v)) File.Delete(v); } catch { } }
            if (m.Ibt.Length > 0)
            {
                bool shared = false; foreach (VMoment o in moments.Values) if (o.Ibt == m.Ibt) shared = true;
                if (!shared) { try { string c = P(m.Ibt); if (File.Exists(c)) File.Delete(c); } catch { } }
            }
        }

        // ---------------- the budget ----------------
        public static long UsedBytes()
        {
            long total = 0;
            string tools = Path.Combine(Root, "bin") + "\\";       // vault\bin holds tools (ffmpeg), not saved moments
            string rolling = Path.Combine(Root, "rec") + "\\";     // vault\rec is the recorder's rolling 3 minutes, not saved moments (clips are in vault\clips)
            try { if (Directory.Exists(Root)) foreach (string f in Directory.GetFiles(Root, "*", SearchOption.AllDirectories)) { if (f.StartsWith(tools, StringComparison.OrdinalIgnoreCase) || f.StartsWith(rolling, StringComparison.OrdinalIgnoreCase)) continue; try { total += new FileInfo(f).Length; } catch { } } }
            catch { }
            return total;
        }

        // keepers are never deleted. Over the budget: the oldest clips nobody starred go first, then the oldest recent items.
        public static string Prune()
        {
            lock (gate)
            {
                long used = UsedBytes(), budget = BudgetBytes;
                if (used <= budget) return "within the budget";
                List<VMoment> clips = new List<VMoment>(), rec = new List<VMoment>();
                foreach (VMoment m in moments.Values)
                {
                    if (m.Keeper) continue;
                    if (m.Kind == "clip") clips.Add(m); else rec.Add(m);
                }
                Comparison<VMoment> byAge = delegate (VMoment a, VMoment b) { return a.Ts.CompareTo(b.Ts); };
                clips.Sort(byAge); rec.Sort(byAge);
                int gone = 0;
                used -= Recorder.TrimClips(used - budget, false);       // Paddock's own recordings nobody starred go first
                foreach (VMoment m in clips)
                {
                    if (used <= budget) break;
                    long freed = m.VideoSize; RemoveMoment(m.Id, true); used -= freed; gone++;
                }
                foreach (VMoment m in rec)
                {
                    if (used <= budget) break;
                    RemoveMoment(m.Id, false); used = UsedBytes(); gone++;
                }
                used = UsedBytes();
                string msg = gone + " old item" + (gone == 1 ? "" : "s") + " removed to stay inside " + (budget / 1048576) + " MB" + (used > budget ? " (keepers alone are over the budget)" : "");
                Log.W("vault: " + msg);
                SaveAll();
                return msg;
            }
        }
    }

    // ---------------- the NVIDIA app (read-only) ----------------
    sealed class VNv
    {
        public string Gallery = "", HotkeyText = "Alt+F10"; public int[] Keys = new[] { 18, 121 };
        public bool IrEnabled, OverlayRunning, AppInstalled, SettingsFound; public int BufferSec;
    }

    static partial class Vault
    {
        // Peter's NVIDIA settings are only looked at: the Instant Replay save hotkey (default Alt+F10), whether Instant Replay is on,
        // where clips go. We never change them.
        public static VNv Nv()
        {
            VNv n = new VNv();
            try
            {
                string ov = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"NVIDIA Corporation\NVIDIA Overlay");
                n.AppInstalled = Directory.Exists(@"C:\Program Files\NVIDIA Corporation\NVIDIA App");
                n.Gallery = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "NVIDIA");
                string share = Path.Combine(ov, "ShareSettings.json"), gal = Path.Combine(ov, "GallerySettings.json");
                if (File.Exists(share))
                {
                    Dictionary<string, object> d = VaultIbt.Parse(File.ReadAllText(share)), st = d != null ? d["settings"] as Dictionary<string, object> : null; n.SettingsFound = st != null;
                    object o;
                    if (st != null && st.TryGetValue("shortcuts", out o) && o is Dictionary<string, object>)
                    {
                        object k; Dictionary<string, object> sc = (Dictionary<string, object>)o;
                        if (sc.TryGetValue("DVRSave", out k) && k is IList && ((IList)k).Count > 0) { List<int> ks = new List<int>(); foreach (object x in (IList)k) ks.Add(Convert.ToInt32(x, Inv)); n.Keys = ks.ToArray(); }
                    }
                    if (st != null && st.TryGetValue("video", out o) && o is Dictionary<string, object>)
                    {
                        Dictionary<string, object> v = (Dictionary<string, object>)o; object e;
                        if (v.TryGetValue("irEnabled", out e) && e is bool) n.IrEnabled = (bool)e;
                        if (v.TryGetValue("irBufferLength", out e)) int.TryParse(Convert.ToString(e, Inv), out n.BufferSec);
                    }
                }
                if (File.Exists(gal))
                {
                    Dictionary<string, object> d = VaultIbt.Parse(File.ReadAllText(gal)), st = d != null ? d["settings"] as Dictionary<string, object> : null; object o;
                    if (st != null && st.TryGetValue("currentDirectoryV2", out o) && Convert.ToString(o, Inv).Length > 0) n.Gallery = Convert.ToString(o, Inv);
                }
                n.HotkeyText = KeyText(n.Keys);
                foreach (string pn in new[] { "NVIDIA Overlay", "NVIDIA Share" })
                    foreach (Process p in Process.GetProcessesByName(pn)) { n.OverlayRunning = true; p.Dispose(); }
            }
            catch (Exception ex) { Log.W("vault: NVIDIA settings: " + ex.Message); }
            if (NvDirOverride != null) n.Gallery = NvDirOverride;
            return n;
        }

        static string KeyText(int[] keys)
        {
            List<string> parts = new List<string>();
            foreach (int vk in keys)
                parts.Add(vk == 18 ? "Alt" : vk == 17 ? "Ctrl" : vk == 16 ? "Shift" : vk == 91 ? "Win" : vk >= 112 && vk <= 135 ? "F" + (vk - 111) : vk >= 65 && vk <= 90 ? ((char)vk).ToString() : vk >= 48 && vk <= 57 ? ((char)vk).ToString() : "key " + vk);
            return string.Join("+", parts.ToArray());
        }

        // ---------------- pressing the recorder's hotkey (SendInput: no focus change, the hotkey is global) ----------------
        [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
        [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
        [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);

        static bool SendHotkey(int[] vks)
        {
            List<int> mods = new List<int>(), rest = new List<int>();
            foreach (int v in vks) { if (v == 16 || v == 17 || v == 18 || v == 91) mods.Add(v); else rest.Add(v); }
            List<int> order = new List<int>(mods); order.AddRange(rest);
            List<INPUT> down = new List<INPUT>(), up = new List<INPUT>();
            foreach (int v in order) down.Add(Key(v, false));
            for (int i = order.Count - 1; i >= 0; i--) up.Add(Key(order[i], true));
            uint a = SendInput((uint)down.Count, down.ToArray(), Marshal.SizeOf(typeof(INPUT)));
            Thread.Sleep(60);
            uint b = SendInput((uint)up.Count, up.ToArray(), Marshal.SizeOf(typeof(INPUT)));
            return a == down.Count && b == up.Count;
        }

        static INPUT Key(int vk, bool up)
        {
            INPUT i = new INPUT(); i.type = 1;
            i.u.ki.wVk = (ushort)vk; i.u.ki.wScan = (ushort)MapVirtualKey((uint)vk, 0); i.u.ki.dwFlags = up ? 2u : 0u;
            return i;
        }

        // a soft beep so he knows in the car (a low double for "could not", a short high one for "done"); async, no window, no focus
        static void Beep(bool ok)
        {
            if (sandbox || Sdk.Pretend) return;
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    int rate = 22050; double[] f = ok ? new[] { 988.0 } : new[] { 330.0, 247.0 }; int ms = ok ? 110 : 120;
                    List<short> sm = new List<short>();
                    foreach (double hz in f)
                    {
                        int n = rate * ms / 1000;
                        for (int i = 0; i < n; i++) { double env = Math.Min(1.0, Math.Min(i / 300.0, (n - i) / 600.0)); sm.Add((short)(Math.Sin(2 * Math.PI * hz * i / rate) * 3200 * env)); }
                        for (int i = 0; i < rate / 40; i++) sm.Add(0);
                    }
                    MemoryStream ms2 = new MemoryStream(); BinaryWriter w = new BinaryWriter(ms2);
                    w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + sm.Count * 2); w.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
                    w.Write(Encoding.ASCII.GetBytes("data")); w.Write(sm.Count * 2); foreach (short x in sm) w.Write(x);
                    ms2.Position = 0;
                    using (System.Media.SoundPlayer sp = new System.Media.SoundPlayer(ms2)) sp.PlaySync();
                }
                catch { }
            });
        }

        // Laps the Vault saved from the session that has just finished (the review sentence). Empty until that file has been read.
        // An older session must not stand in for it: the new file is often still unread, and last week's laps are never listed.
        public static List<WLap> SavedLaps()
        {
            List<WLap> list = new List<WLap>();
            List<double> all = new List<double>();
            long since = 0;
            try { since = Wheel.LiveSince(); } catch { since = 0; }
            lock (gate)
            {
                VSession latest = null;
                foreach (VSession s in sessions) if (latest == null || s.EndMs > latest.EndMs) latest = s;
                if (latest == null || latest.EndMs <= 0 || Now() - latest.EndMs > 20L * 60L * 1000L) return list;
                if (since > 0 && latest.EndMs + 5000 < since) return list;
                foreach (VSession s in sessions) if (s.Combo == latest.Combo) foreach (double[] t in s.Top) all.Add(t[1]);
                all.Sort();
                foreach (VMoment m in moments.Values)
                {
                    if (m.Kind != "lap" || m.Session != latest.Name || m.Lap <= 0 || m.LapTime <= 0) continue;
                    WLap w = new WLap();
                    w.Lap = m.Lap; w.Time = m.LapTime; w.Session = m.Session; w.Why = WhyOf(m, all);
                    list.Add(w);
                }
            }
            list.Sort(delegate (WLap a, WLap b)
            {
                int pa = a.Why == "PB" ? 0 : 1, pb = b.Why == "PB" ? 0 : 1;
                if (pa != pb) return pa.CompareTo(pb);
                int c = a.Time.CompareTo(b.Time);
                if (c != 0) return c;
                return a.Lap.CompareTo(b.Lap);
            });
            return list;
        }

        static string WhyOf(VMoment m, List<double> all)
        {
            if (m.Tags.Contains("PB")) return "PB";
            if (m.Tags.Contains("TOP 10") && all.Count > 0)
            {
                int rank = 1;
                foreach (double t in all) if (t < m.LapTime - 0.0005) rank++;
                int pct = (int)Math.Ceiling(100.0 * rank / all.Count);
                if (pct < 1) pct = 1;
                if (pct > 100) pct = 100;
                return "top " + pct.ToString(Inv) + "%";
            }
            if (m.Tags.Contains("BEST LAP")) return "best 3";
            if (m.Pinned) return "kept";
            if (m.Tags.Contains("WIN")) return "win";
            return "saved";
        }

        // KEEP ALL pins the laps from the review so a recent one is not pruned. Seeded test laps have no session file, so nothing is written.
        public static int PinSaved(List<WLap> laps)
        {
            if (laps == null || laps.Count == 0) return 0;
            int n = 0;
            lock (gate)
            {
                foreach (WLap w in laps)
                {
                    if (w == null || w.Session == null || w.Session.Length == 0 || w.Lap <= 0) continue;
                    string lap = w.Lap.ToString(Inv);
                    bool have = false;
                    foreach (string[] e in pins) if (e.Length >= 2 && e[0] == w.Session && e[1] == lap) have = true;
                    if (have) continue;
                    pins.Add(new string[] { w.Session, lap, w.Time.ToString("0.000", Inv) });
                    n++;
                }
            }
            if (n > 0) SaveAll();
            return n;
        }

        // ---------------- the deck keys ----------------
        static readonly HashSet<string> Commands = new HashSet<string> { "vkkeep", "vkclip", "vkopen", "vkclose", "vkdelete", "vkkeepall", "vkchoose", "wheelteach", "recsave", "db-save", "db-share", "db-cosworth", "db-deepdive" };
        public static bool Handles(string c) { return Serving && c != null && Commands.Contains(c); }
        public static readonly List<string> TestEvents = new List<string>();
        static DateTime lastKeep = DateTime.MinValue, lastClip = DateTime.MinValue;
        public static string LastClipKey = "";
        static readonly object navGate = new object();
        static string navWant = ""; static int navSeq; static DateTime navSince = DateTime.MinValue;

        public static bool Do(string c, string a)
        {
            if (!Serving) return false;
            switch (c)
            {
                case "db-save": case "db-share": case "db-cosworth": case "db-deepdive": return Debrief.Do(c, a);
                case "vkkeep": return KeepPress();
                case "vkclip": return ClipPress();
                case "vkopen": return NavSet("vault");
                case "vkclose": NavSet(""); return true;
                case "vkkeepall": return Wheel.KeepAll();
                case "vkchoose":
                    // The dashboard's "driving" flag lags the SDK by up to 2 s. CHOOSE is pressed the moment he is out.
                    if (Wheel.DrivingNow()) return false;
                    Wheel.CancelForChoose();
                    TestEvents.Add("choose");
                    return NavSet("vault");
                case "recsave": { string st = Recorder.Save(a ?? ""); return st == "SAVED" || st == "SAVING"; }   // the key lights only for a real save, not SAVED FULL / SAVE FAILED / NOTHING
                case "wheelteach": return Wheel.Teach(10000).Length > 0;
                case "vkdelete":
                    {
                        if (Program.IsDriving || !ValidId(a)) return false;
                        lock (gate) { if (!moments.ContainsKey(a)) return false; RemoveMoment(a, true); }
                        SaveAll(); Log.W("vault: deleted " + a); return true;
                    }
            }
            return false;
        }

        static bool ValidId(string id) { return !string.IsNullOrEmpty(id) && Regex.IsMatch(id, "^[a-z0-9-]{3,40}$"); }

        static bool NavSet(string to)
        {
            lock (navGate)
            {
                // SDK frame, not the 2 s dashboard flag: that flag is still true just after he gets out, which is when CHOOSE runs.
                if (to != "" && Wheel.DrivingNow()) return false;
                if (navWant != to) { navWant = to; navSince = DateTime.Now; navSeq++; Log.W("vault: page request: " + (to == "" ? "back to the dashboard" : to)); }
                else navSince = DateTime.Now;
                return true;
            }
        }

        static string NavJson()
        {
            lock (navGate)
            {
                if (navWant != "" && (Wheel.DrivingNow() || (DateTime.Now - navSince).TotalMinutes > 30)) { navWant = ""; navSeq++; }       // a request never outlives the car, or half an hour
                return "{\"to\":" + Json_.S(navWant) + ",\"seq\":" + navSeq + ",\"driving\":" + (Program.IsDriving ? "true" : "false") + "}";
            }
        }

        // where he is right now: from the live frames
        static VMark MarkNow(string kind)
        {
            Frame f = Sdk.Latest;
            if (!f.Connected) return null;
            Combo.Info ci = Combo.FromYaml(f.SessionYaml);
            VMark m = new VMark(); m.Ms = Now(); m.Kind = kind; m.Car = ci.Car; m.Track = ci.Track; m.Config = ci.Config;
            int lap = (int)f.Num("Lap"); double pct = f.Num("LapDistPct");
            // just over the line: he means the lap he has just finished
            m.Lap = (pct >= 0 && pct < 0.08 && lap > 1) ? lap - 1 : lap; m.Pct = pct; m.St = f.Num("SessionTime");
            return m;
        }

        public static bool PressKeep() { return KeepPress(); }
        public static void Chime(bool ok) { Beep(ok); }

        // KEEP: marks this lap (and the race, in a race). Instant, nothing opens, no focus change.
        static bool KeepPress()
        {
            lock (gate)
            {
                if ((DateTime.Now - lastKeep).TotalSeconds < 0.7) return true;             // a deck can repeat a press
                lastKeep = DateTime.Now;
            }
            VMark m = MarkNow("keep");
            if (m == null) { Log.W("vault: KEEP pressed but no session is running"); Beep(false); return false; }
            lock (gate) marks.Add(m);
            SaveAll();
            try { Recorder.Keep(m.Lap); } catch (Exception ex) { Log.W("recorder: KEEP: " + ex.Message); }      // the lap's own video is kept too (if the recorder is on)
            Log.W("vault: KEEP - " + m.Car + " at " + m.Track + ", lap " + m.Lap + " (" + (m.Pct * 100).ToString("0") + " % round); it is kept when the session file is complete");
            TestEvents.Add("keep lap " + m.Lap);
            Beep(true);
            return true;
        }

        // CLIP: presses the recorder's hotkey (only if the NVIDIA overlay is running) and marks the lap for the clip that appears.
        static bool ClipPress()
        {
            lock (gate)
            {
                if ((DateTime.Now - lastClip).TotalSeconds < 0.7) return true;
                lastClip = DateTime.Now;
            }
            VMark m = MarkNow("clip");
            if (m != null) { lock (gate) marks.Add(m); SaveAll(); }
            VNv nv = Nv(); string how; bool pressed = false;
            if (sandbox || Sdk.Pretend) { how = "test: would press " + nv.HotkeyText; TestEvents.Add("clip hotkey " + nv.HotkeyText); pressed = true; }
            else if (!nv.IrEnabled) how = "NVIDIA Instant Replay is off: turn it on in the NVIDIA app";
            else if (!nv.OverlayRunning) how = "the NVIDIA overlay is not running, so the hotkey would do nothing";
            else
            {
                try { pressed = SendHotkey(nv.Keys); how = pressed ? "pressed " + nv.HotkeyText : "Windows refused the key press"; }
                catch (Exception ex) { how = "could not press the key (" + ex.Message + ")"; }
            }
            LastClipKey = how;
            Log.W("vault: CLIP - " + how + (m != null ? "; marked lap " + m.Lap + " of " + m.Track : "; no session is running, nothing marked"));
            Beep(pressed);
            return pressed;
        }

        // ---------------- clips: watch the NVIDIA folder, attach, copy ----------------
        static readonly Dictionary<string, long[]> clipPending = new Dictionary<string, long[]>();      // path -> {size, first seen at (ms)}

        public static int WatchClips() { return WatchClips(false); }

        static int WatchClips(bool test)
        {
            VNv nv = Nv(); int attached = 0;
            if (string.IsNullOrEmpty(nv.Gallery) || !Directory.Exists(nv.Gallery)) return 0;
            if (!test && Program.IsDriving) return 0;                       // copying 45 MB can wait until he is out of the car
            List<string> files = new List<string>();
            try
            {
                files.AddRange(Directory.GetFiles(nv.Gallery, "*.mp4", SearchOption.TopDirectoryOnly));
                foreach (string d in Directory.GetDirectories(nv.Gallery)) files.AddRange(Directory.GetFiles(d, "*.mp4", SearchOption.TopDirectoryOnly));
            }
            catch (Exception ex) { Log.W("vault: clip folder: " + ex.Message); return 0; }
            foreach (string path in files)
            {
                try
                {
                    FileInfo fi = new FileInfo(path);
                    string key = path + "|" + fi.Length + "|" + fi.LastWriteTimeUtc.Ticks;
                    lock (gate) { if (clipsSeen.Contains(key)) continue; }
                    // clips that were already there before the Vault began watching are not ours
                    if (fi.LastWriteTimeUtc < watchSince && !test) { lock (gate) clipsSeen.Add(key); continue; }
                    if (fi.Length < 50000) continue;
                    if (!test && (DateTime.UtcNow - fi.LastWriteTimeUtc).TotalSeconds < 6) continue;
                    long[] pend;
                    if (!clipPending.TryGetValue(path, out pend) || pend[0] != fi.Length) { clipPending[path] = new[] { fi.Length, Now() }; if (!test) continue; }
                    double dur; string why;
                    if (!VaultMp4.Info(path, out dur, out why))
                    {
                        if (Now() - clipPending[path][1] > 300000) { Log.W("vault: " + Path.GetFileName(path) + " never became a readable video (" + why + ") - left alone"); lock (gate) clipsSeen.Add(key); }
                        continue;
                    }
                    if (AttachClip(path, fi, dur, key)) attached++;
                }
                catch (Exception ex) { Log.W("vault: clip " + Path.GetFileName(path) + ": " + ex.Message); }
            }
            if (attached > 0) SaveAll();
            return attached;
        }

        static bool AttachClip(string path, FileInfo fi, double dur, string key)
        {
            long endMs = Ms(fi.LastWriteTimeUtc);
            string id = "c" + Epoch.AddMilliseconds(endMs).ToString("yyyyMMdd-HHmmss", Inv);
            lock (gate)
            {
                if (deleted.Contains(id) || moments.ContainsKey(id)) { clipsSeen.Add(key); return false; }
                // the press that made it: a CLIP mark a little before the file's end time
                VMark best = null;
                foreach (VMark mk in marks)
                {
                    if (mk.Used || mk.Kind != "clip") continue;
                    long gap = endMs - mk.Ms;
                    if (gap < -5000 || gap > 60000) continue;
                    if (best == null || Math.Abs(gap) < Math.Abs(endMs - best.Ms)) best = mk;
                }
                if (FreeBytes(Root) < fi.Length + 3L * 1024 * 1024 * 1024) { Log.W("vault: not copying the clip - less than 3 GB would be left on the disk"); return false; }
                string rel = @"clips\" + id + ".mp4", dest = P(rel);
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                CopyFile(path, dest + ".tmp");
                if (new FileInfo(dest + ".tmp").Length != fi.Length) { try { File.Delete(dest + ".tmp"); } catch { } throw new IOException("the copy is not the same size as the clip"); }
                if (File.Exists(dest)) File.Delete(dest);
                File.Move(dest + ".tmp", dest);
                try { File.SetLastWriteTimeUtc(dest, fi.LastWriteTimeUtc); } catch { }
                VMoment m = new VMoment(); m.Id = id; m.Kind = "clip"; m.Created = Now(); m.Ts = endMs; m.Video = rel; m.VideoDur = dur; m.VideoEndMs = endMs; m.VideoSize = fi.Length; m.Nudge = globalNudge;
                m.Tags.Add("CLIP");
                if (best != null) { best.Used = true; m.Car = best.Car; m.Track = best.Track; m.Config = best.Config; m.Lap = best.Lap; m.MarkPct = best.Pct; }
                moments[id] = m; dirty.Add(id); clipsSeen.Add(key);
                Log.W("vault: clip " + Path.GetFileName(path) + " (" + dur.ToString("0.0", Inv) + " s, " + (fi.Length / 1048576) + " MB) attached as " + id + (best != null ? " to lap " + best.Lap + " of " + best.Track : ", waiting for its session file"));
                if (clipMode == "move") { try { File.Delete(path); Log.W("vault: moved the clip out of the NVIDIA folder (vault_clip_mode=move)"); } catch (Exception ex) { Log.W("vault: could not remove the original clip: " + ex.Message); } }
            }
            LinkClips();
            return true;
        }

        // A clip is tied to its session when the session's .ibt exists: the session that was running at the clip's end time.
        public static void LinkClips()
        {
            lock (gate)
            {
                foreach (VMoment m in new List<VMoment>(moments.Values))
                {
                    if (m.Kind != "clip" || m.Session.Length > 0 || m.VideoEndMs == 0) continue;
                    long end = m.VideoEndMs, start = end - (long)(m.VideoDur * 1000);
                    VSession hit = null;
                    foreach (VSession s in sessions)
                    {
                        if (s.Car.Length == 0 || s.StartMs > end || s.EndMs < start) continue;
                        if (m.Track.Length > 0 && s.Track != m.Track) continue;
                        if (hit == null || s.StartMs > hit.StartMs) hit = s;
                    }
                    if (hit == null) continue;
                    m.Session = hit.Name; m.IbtSrc = hit.Name; m.Car = hit.Car; m.Track = hit.Track; m.Config = hit.Config; m.TrackId = hit.TrackId; m.TrackName = hit.TrackName; m.SType = hit.Type; m.StartMs = hit.StartMs; m.Official = hit.Official;
                    try
                    {
                        string src = Path.Combine(SrcDir, hit.Name);
                        Dictionary<string, object> d = VaultIbt.Parse(IbtLaps.LapsJson(src));
                        double st0 = Convert.ToDouble(d["st0"], Inv);
                        VLap pick = null; double bestOver = 0;
                        foreach (object o in (IList)d["laps"])
                        {
                            Dictionary<string, object> ld = (Dictionary<string, object>)o;
                            double t0 = Convert.ToDouble(ld["t0"], Inv), t1 = Convert.ToDouble(ld["t1"], Inv);
                            long l0 = hit.StartMs + (long)((t0 - st0) * 1000), l1 = hit.StartMs + (long)((t1 - st0) * 1000);
                            double over = Math.Min(end, l1) - Math.Max(start, l0);
                            // the lap he was on when he pressed (the one holding the clip's end), else the one with most of the clip in it
                            bool holdsEnd = end >= l0 && end <= l1;
                            if (holdsEnd) over += 1e9;
                            if (over > bestOver) { bestOver = over; pick = new VLap(); pick.N = Convert.ToInt32(ld["n"], Inv); pick.Time = Convert.ToDouble(ld["time"], Inv); pick.T0 = l0; pick.T1 = l1; }
                        }
                        if (pick != null)
                        {
                            m.Lap = pick.N; m.LapTime = pick.Time;
                            if (m.MarkPct <= 0) m.MarkPct = Math.Max(0, Math.Min(1, (end - pick.T0) / Math.Max(1.0, pick.T1 - pick.T0)));
                        }
                    }
                    catch (Exception ex) { Log.W("vault: could not find the lap of clip " + m.Id + ": " + ex.Message); }
                    EnsureCopy(m);
                    dirty.Add(m.Id);
                    Log.W("vault: clip " + m.Id + " belongs to " + hit.Name + (m.Lap > 0 ? ", lap " + m.Lap : ""));
                }
            }
        }
    }

    // ---------------- reading an .mp4 (length) ----------------
    static class VaultMp4
    {
        static uint U32(byte[] b, int o) { return ((uint)b[o] << 24) | ((uint)b[o + 1] << 16) | ((uint)b[o + 2] << 8) | b[o + 3]; }
        static ulong U64(byte[] b, int o) { return ((ulong)U32(b, o) << 32) | U32(b, o + 4); }

        // true when the file is a complete mp4 (the boxes add up to the file's size, with a movie box) and gives its length in seconds
        public static bool Info(string path, out double seconds, out string why)
        {
            seconds = 0; why = "";
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                long len = fs.Length, pos = 0; bool moov = false; double movie = 0, frag = 0; uint scale = 0; long lastMoofPos = -1, lastMoofSize = 0;
                byte[] h = new byte[16];
                while (pos < len)
                {
                    if (len - pos < 8) { why = "stray bytes at the end"; return false; }
                    fs.Position = pos; fs.Read(h, 0, 8);
                    long size = U32(h, 0); string type = Encoding.ASCII.GetString(h, 4, 4); long hdr = 8;
                    if (size == 1) { fs.Read(h, 8, 8); size = (long)U64(h, 8); hdr = 16; } else if (size == 0) size = len - pos;
                    if (size < hdr || pos + size > len) { why = "the file is still being written (" + type + " box is cut short)"; return false; }
                    if (type == "moov")
                    {
                        moov = true; mvScale = 0;
                        byte[] box = new byte[Math.Min(size - hdr, 8L * 1024 * 1024)]; fs.Position = pos + hdr; fs.Read(box, 0, box.Length);
                        Walk(box, 0, box.Length, ref scale, ref movie, ref frag);
                    }
                    else if (type == "moof") { lastMoofPos = pos; lastMoofSize = size; }
                    pos += size;
                }
                if (!moov) { why = "no movie box yet"; return false; }
                if (movie > 0) { seconds = movie; return true; }
                if (frag > 0) { seconds = frag; return true; }
                // a fragmented file with no total: the last fragment's start time plus its length
                if (lastMoofPos >= 0 && scale > 0)
                {
                    byte[] mf = new byte[Math.Min(lastMoofSize, 4L * 1024 * 1024)]; fs.Position = lastMoofPos; fs.Read(mf, 0, mf.Length);
                    double end = FragmentEnd(mf, scale);
                    if (end > 0) { seconds = end; return true; }
                }
                why = "the length is not in the file"; return false;
            }
        }

        // finds mvhd (length), mehd (fragment total) and the first track's timescale
        static uint mvScale;
        static void Walk(byte[] b, int s, int e, ref uint trackScale, ref double movie, ref double frag)
        {
            int p = s;
            while (p + 8 <= e)
            {
                long size = U32(b, p); string type = Encoding.ASCII.GetString(b, p + 4, 4); int hdr = 8;
                if (size == 1) { size = (long)U64(b, p + 8); hdr = 16; } else if (size == 0) size = e - p;
                if (size < hdr || p + size > e) return;
                int c = p + hdr, end = (int)(p + size);
                if (type == "mvhd")
                {
                    int ver = b[c]; uint ts; double du;
                    if (ver == 1) { ts = U32(b, c + 20); du = U64(b, c + 24); } else { ts = U32(b, c + 12); du = U32(b, c + 16); }
                    if (ts > 0) { movie = du / ts; mvScale = ts; }
                }
                else if (type == "mehd")
                {
                    int ver = b[c]; double du = ver == 1 ? U64(b, c + 4) : U32(b, c + 4);
                    if (mvScale > 0) frag = du / mvScale;
                }
                else if (type == "mdhd" && trackScale == 0) { int ver = b[c]; trackScale = ver == 1 ? U32(b, c + 20) : U32(b, c + 12); }
                else if (type == "trak" || type == "mdia" || type == "mvex") Walk(b, c, end, ref trackScale, ref movie, ref frag);
                p = end;
            }
        }

        // tfdt (where the last fragment starts) + the sum of its sample lengths, in seconds
        static double FragmentEnd(byte[] b, uint scale)
        {
            double baseT = 0; long total = 0; uint defDur = 0; int p = 8;
            while (p + 8 <= b.Length)
            {
                long size = U32(b, p); string type = Encoding.ASCII.GetString(b, p + 4, 4);
                if (size < 8 || p + size > b.Length) break;
                if (type == "traf")
                {
                    int q = p + 8, end = (int)(p + size);
                    while (q + 8 <= end)
                    {
                        long sz = U32(b, q); string ty = Encoding.ASCII.GetString(b, q + 4, 4); if (sz < 8 || q + sz > end) break;
                        int c = q + 8; uint flags = U32(b, c) & 0xFFFFFF; int ver = b[c];
                        if (ty == "tfhd") { int o = c + 8; if ((flags & 1) != 0) o += 8; if ((flags & 2) != 0) o += 4; if ((flags & 8) != 0) defDur = U32(b, o); }
                        else if (ty == "tfdt") baseT = ver == 1 ? U64(b, c + 4) : U32(b, c + 4);
                        else if (ty == "trun")
                        {
                            uint n = U32(b, c + 4); int o = c + 8; if ((flags & 1) != 0) o += 4; if ((flags & 4) != 0) o += 4;
                            for (uint i = 0; i < n && o + 4 <= b.Length; i++)
                            {
                                if ((flags & 0x100) != 0) { total += U32(b, o); o += 4; } else total += defDur;
                                if ((flags & 0x200) != 0) o += 4; if ((flags & 0x400) != 0) o += 4; if ((flags & 0x800) != 0) o += 4;
                            }
                        }
                        q += (int)sz;
                    }
                    break;
                }
                p += (int)size;
            }
            return total > 0 ? (baseT + total) / scale : 0;
        }
    }

    // ---------------- HTTP: /vault, /vault/list, /vault/item, /vault/clip, /vault/thumb ... ----------------
    static partial class Vault
    {
        static void Respond(NetworkStream s, int code, string type, byte[] body, string extra)
        {
            string reason = code == 200 ? "OK" : code == 206 ? "Partial Content" : code == 400 ? "Bad Request" : code == 404 ? "Not Found" : code == 409 ? "Conflict" : code == 416 ? "Range Not Satisfiable" : code == 503 ? "Service Unavailable" : "Error";
            string h = "HTTP/1.1 " + code + " " + reason + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n" + (extra ?? "") + "\r\n";
            byte[] hb = Encoding.ASCII.GetBytes(h);
            s.Write(hb, 0, hb.Length);
            if (body.Length > 0) s.Write(body, 0, body.Length);
            s.Flush();
        }

        static void Reply(NetworkStream s, int code, string json) { Respond(s, code, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json), ""); }
        static string Err(string m) { return "{\"error\":" + Json_.S(m) + "}"; }
        static string Q(Dictionary<string, string> q, string k) { string v; return q.TryGetValue(k, out v) ? v : ""; }

        // Returns true when the request was ours (and has been answered).
        public static bool Handle(NetworkStream s, string path, Dictionary<string, string> q, Dictionary<string, string> hdr)
        {
            if (path != "/vault" && !path.StartsWith("/vault/", StringComparison.Ordinal) && !path.StartsWith("/api/rec/", StringComparison.Ordinal)) return false;
            if (!Serving && !(path.StartsWith("/vault/test/", StringComparison.Ordinal) && Sdk.TestHook)) { try { Reply(s, 200, "{\"enabled\":false}"); } catch { } return true; }
            try
            {
                int code = 200; string j = null;
                switch (path)
                {
                    case "/vault": j = StatusJson(false); break;
                    case "/vault/list": j = StatusJson(true); break;
                    case "/vault/nav": j = NavJson(); break;
                    case "/vault/review": j = Wheel.ReviewJson(Q(q, "open") == "1"); break;
                    case "/vault/scan": ScanKick(); j = "{\"ok\":true}"; break;
                    case "/vault/item": j = ItemJson(Q(q, "id"), out code); break;
                    case "/vault/laps":
                    case "/vault/lap": j = LapRoute(path, q, out code); break;
                    case "/vault/edit": j = EditRoute(q, out code); break;
                    case "/vault/delete": j = DeleteRoute(q, out code); break;
                    case "/vault/open": j = OpenRoute(q, out code); break;
                    case "/vault/clip": return ServeClip(s, Q(q, "id"), hdr);
                    case "/vault/video": return Recorder.ServeVideo(s, Q(q, "id"), hdr);                     // Paddock's own recording of a lap (recorder.cs); Range works, 404 when there is none
                    case "/vault/videoinfo": j = Recorder.InfoJson(Q(q, "id"), out code); break;             // its sidecar: where the lap starts inside the clip
                    case "/vault/recorder": j = Recorder.StatusJson(); break;
                    case "/api/rec/sessions": j = Recorder.SessionsJson(); break;
                    case "/api/rec/for": j = Debrief.RecordingFor(Q(q, "id"), Q(q, "lap")); break;              // the verified recording of one telemetry session (debrief.cs)
                    case "/api/rec/save": j = "{\"state\":" + Json_.S(Recorder.Save(Q(q, "id"))) + "}"; break;
                    case "/api/rec/session-video": return Recorder.ServeSession(s, Q(q, "id"), hdr);
                    case "/vault/thumb": return ServeThumb(s, Q(q, "id"));
                    case "/vault/frame": return ServeFrame(s, Q(q, "id"));                                   // a real picture from the lap's own recording (made in the background, 404 until then)
                }
                if (j == null && path.StartsWith("/vault/test/", StringComparison.Ordinal)) j = TestRoute(path, q, out code);
                if (j == null) { Reply(s, 404, Err("not found")); return true; }
                Reply(s, code, j);
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
            catch (Exception ex) { Log.W("vault: " + path + ": " + ex.Message); try { Reply(s, 500, Err("could not do that")); } catch { } }
            return true;
        }

        static void ScanKick()
        {
            // a pool thread runs at Normal and would compete with the sim; this scan is background work
            ThreadStart scan = delegate { try { if (!Program.IsDriving && !sandbox) { ScanSessions(false, 20); Thumbs(10); } } catch (Exception ex) { Log.W("vault scan: " + ex.Message); } };
            Thread t = new Thread(scan);
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Start();
        }

        // ---- status and the whole list ----
        static string StatusJson(bool withList)
        {
            // which moments have a recording (outside the lock: the recorder's lookup takes the Vault's lock itself)
            Dictionary<string, VFrameSrc> fr = withList ? FrameMap() : null;
            lock (gate)
            {
                int keepers = 0, recent = 0, clips = 0, withVideo = 0; long clipBytes = 0, ibtBytes = 0;
                HashSet<string> seenIbt = new HashSet<string>();
                foreach (VMoment m in moments.Values)
                {
                    if (m.Keeper) keepers++; else recent++;
                    if (m.Kind == "clip") clips++;
                    if (m.Video.Length > 0) { withVideo++; clipBytes += m.VideoSize; }
                    if (m.Ibt.Length > 0 && seenIbt.Add(m.Ibt)) ibtBytes += m.IbtSize;
                }
                long used = UsedBytes(), budget = BudgetBytes;
                VNv nv = Nv(); CosworthInfo cw = Cosworth();
                StringBuilder sb = new StringBuilder(2048);
                sb.Append("{\"ok\":true,\"sandbox\":").Append(sandbox ? "true" : "false").Append(",\"root\":").Append(Json_.S(Root)).Append(",\"usedBytes\":").Append(used).Append(",\"budgetBytes\":").Append(budget)
                  .Append(",\"keepers\":").Append(keepers).Append(",\"recent\":").Append(recent).Append(",\"clips\":").Append(clips).Append(",\"withVideo\":").Append(withVideo).Append(",\"clipBytes\":").Append(clipBytes).Append(",\"telemetryBytes\":").Append(ibtBytes)
                  .Append(",\"sessions\":").Append(sessions.Count).Append(",\"scanLeft\":").Append(scanLeft).Append(",\"status\":").Append(Json_.S(status)).Append(",\"recentDays\":").Append(RecentDays)
                  .Append(",\"nudge\":").Append(globalNudge.ToString("0.##", Inv)).Append(",\"clipMode\":").Append(Json_.S(clipMode)).Append(",\"driving\":").Append(Program.IsDriving ? "true" : "false")
                  .Append(",\"nvidia\":{\"installed\":").Append(nv.AppInstalled ? "true" : "false").Append(",\"found\":").Append(nv.SettingsFound ? "true" : "false").Append(",\"instantReplay\":").Append(nv.IrEnabled ? "true" : "false")
                  .Append(",\"bufferSec\":").Append(nv.BufferSec).Append(",\"hotkey\":").Append(Json_.S(nv.HotkeyText)).Append(",\"overlayRunning\":").Append(nv.OverlayRunning ? "true" : "false").Append(",\"folder\":").Append(Json_.S(nv.Gallery))
                  .Append(",\"lastKey\":").Append(Json_.S(LastClipKey)).Append("},\"cosworth\":{\"installed\":").Append(cw.Installed ? "true" : "false").Append(",\"exe\":").Append(Json_.S(cw.Exe)).Append("}");
                if (withList)
                {
                    // the personal best of every car + track, to show "+0.123" against
                    Dictionary<string, double> pb = new Dictionary<string, double>();
                    foreach (VSession x in sessions) if (x.BestValid > 0) { double v; if (!pb.TryGetValue(x.Combo, out v) || x.BestValid < v) pb[x.Combo] = x.BestValid; }
                    List<VMoment> list = new List<VMoment>(moments.Values);
                    list.Sort(delegate (VMoment a, VMoment b) { return b.Ts.CompareTo(a.Ts); });
                    int frames = 0, vids = 0;
                    foreach (KeyValuePair<string, VFrameSrc> kv in fr) { if (kv.Value.Clip.Length > 0) vids++; if (File.Exists(FramePath(kv.Key))) frames++; }
                    sb.Append(",\"frames\":").Append(frames).Append(",\"vids\":").Append(vids);
                    sb.Append(",\"moments\":[");
                    bool first = true;
                    foreach (VMoment m in list)
                    {
                        if (!first) sb.Append(','); first = false;
                        double best; bool has = pb.TryGetValue(m.Combo, out best);
                        string j = m.Json(File.Exists(P(@"thumbs\" + m.Id + ".png")));
                        VFrameSrc src; fr.TryGetValue(m.Id, out src);
                        sb.Append(j.Substring(0, j.Length - 1)).Append(",\"pb\":").Append(has ? N3(best) : "null").Append(",\"gap\":").Append(has && m.LapTime > 0 ? N3(m.LapTime - best) : "null")
                          .Append(",\"vid\":").Append(Json_.S(src != null ? src.Clip : "")).Append(",\"vidDur\":").Append(src != null && src.Clip.Length > 0 ? src.ClipDur.ToString("0.0", Inv) : "0")
                          .Append(",\"frame\":").Append(src != null && File.Exists(FramePath(m.Id)) ? "true" : "false").Append('}');
                    }
                    sb.Append(']');
                }
                return sb.Append('}').ToString();
            }
        }

        // ---- one moment, with what the detail page needs ----
        static string ItemJson(string id, out int code)
        {
            code = 200;
            if (!ValidId(id)) { code = 400; return Err("bad id"); }
            VMoment m;
            lock (gate) { if (!moments.TryGetValue(id, out m)) { code = 404; return Err("no such moment"); } }
            StringBuilder sb = new StringBuilder(4000);
            double pb = 0; string pbId = "";
            StringBuilder others = new StringBuilder();
            lock (gate)
            {
                foreach (VSession x in sessions) if (x.Combo == m.Combo && x.BestValid > 0 && (pb == 0 || x.BestValid < pb)) pb = x.BestValid;
                List<VMoment> same = new List<VMoment>();
                // a clip of this same file and lap is the lap itself: never offer it as another lap to compare
                foreach (VMoment o in moments.Values) if (o.Id != m.Id && o.Combo == m.Combo && o.Lap > 0 && o.LapTime > 0 && o.Kind != "race" && !(o.Session.Length > 0 && o.Session == m.Session && o.Lap == m.Lap)) same.Add(o);
                // the PB lap, if the Vault holds it
                foreach (VMoment o in moments.Values) if (o.Combo == m.Combo && o.Lap > 0 && o.Tags.Contains("PB") && Math.Abs(o.LapTime - pb) < 0.002) pbId = o.Id;
                same.Sort(delegate (VMoment a, VMoment b) { return a.LapTime.CompareTo(b.LapTime); });
                foreach (VMoment o in same)
                {
                    if (others.Length > 0) others.Append(',');
                    others.Append("{\"id\":").Append(Json_.S(o.Id)).Append(",\"kind\":").Append(Json_.S(o.Kind)).Append(",\"lap\":").Append(o.Lap).Append(",\"lapTime\":").Append(N3(o.LapTime)).Append(",\"ts\":").Append(o.Ts).Append(",\"session\":").Append(Json_.S(o.Session)).Append(",\"keeper\":").Append(o.Keeper ? "true" : "false")
                          .Append(",\"tags\":[").Append(string.Join(",", o.Tags.ConvertAll<string>(delegate (string t) { return Json_.S(t); }).ToArray())).Append("]}");
                }
            }
            string path = TelemetryPath(m);
            sb.Append("{\"m\":").Append(m.Json(File.Exists(P(@"thumbs\" + m.Id + ".png")))).Append(",\"pb\":").Append(pb > 0 ? N3(pb) : "null").Append(",\"pbId\":").Append(Json_.S(pbId))
              .Append(",\"hasTelemetry\":").Append(path != null ? "true" : "false").Append(",\"others\":[").Append(others).Append("]");
            sb.Append(",\"mapKey\":").Append(Json_.S(TrackMaps.MakeKey(m.TrackId, m.TrackName)));
            // video lock: for each lap the clip overlaps, where the line is in video seconds (before the nudge)
            sb.Append(",\"sync\":").Append(path != null && m.Video.Length > 0 ? SyncJson(m, path) : "null");
            CosworthInfo cw = Cosworth();
            sb.Append(",\"cosworth\":{\"installed\":").Append(cw.Installed ? "true" : "false").Append(",\"exe\":").Append(Json_.S(cw.Exe)).Append("}");
            sb.Append(",\"file\":").Append(Json_.S(path ?? "")).Append('}');
            return sb.ToString();
        }

        static string SyncJson(VMoment m, string path)
        {
            try
            {
                Dictionary<string, object> d = VaultIbt.Parse(IbtLaps.LapsJson(path));
                double st0 = Convert.ToDouble(d["st0"], Inv); long startMs = (long)Convert.ToDouble(d["startMs"], Inv);
                double clipStart = (m.VideoEndMs - m.VideoDur * 1000);
                StringBuilder sb = new StringBuilder("{\"clipStartMs\":" + ((long)clipStart) + ",\"clipEndMs\":" + m.VideoEndMs + ",\"dur\":" + m.VideoDur.ToString("0.###", Inv) + ",\"nudge\":" + m.Nudge.ToString("0.##", Inv) + ",\"laps\":[");
                bool first = true;
                foreach (object o in (IList)d["laps"])
                {
                    Dictionary<string, object> ld = (Dictionary<string, object>)o;
                    double t0 = Convert.ToDouble(ld["t0"], Inv), t1 = Convert.ToDouble(ld["t1"], Inv);
                    double w0 = startMs + (t0 - st0) * 1000, w1 = startMs + (t1 - st0) * 1000;
                    double v0 = (w0 - clipStart) / 1000, v1 = (w1 - clipStart) / 1000;
                    if (v1 < -2 || v0 > m.VideoDur + 2) continue;
                    if (!first) sb.Append(','); first = false;
                    sb.Append("{\"n\":").Append(Convert.ToInt32(ld["n"], Inv)).Append(",\"time\":").Append(N3(Convert.ToDouble(ld["time"], Inv))).Append(",\"v0\":").Append(v0.ToString("0.000", Inv)).Append(",\"v1\":").Append(v1.ToString("0.000", Inv)).Append('}');
                }
                return sb.Append("]}").ToString();
            }
            catch (Exception ex) { Log.W("vault: sync for " + m.Id + ": " + ex.Message); return "null"; }
        }

        // ---- lap lists and traces from the Vault's copy (the same engine as the lap analysis) ----
        static string LapRoute(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            string id = Q(q, "id");
            if (!ValidId(id)) { code = 400; return Err("bad id"); }
            if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
            VMoment m; lock (gate) { if (!moments.TryGetValue(id, out m)) { code = 404; return Err("no such moment"); } }
            string file = TelemetryPath(m);
            if (file == null) { code = 404; return Err("The telemetry file for this moment is gone (or online-only in OneDrive)"); }
            try
            {
                if (path == "/vault/laps") return IbtLaps.LapsJson(file);
                int n; if (!int.TryParse(Q(q, "lap"), out n)) { code = 400; return Err("lap must be a number"); }
                string j = IbtLaps.LapJson(file, n);
                if (j == null) { code = 404; return Err("no such lap in this file"); }
                return j;
            }
            catch (Exception ex) { Log.W("vault: lap " + id + ": " + ex.Message); code = 500; return Err("could not read that file"); }
        }

        // ---- notes, tags, star, sync nudge ----
        static string EditRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            string id = Q(q, "id");
            if (!ValidId(id)) { code = 400; return Err("bad id"); }
            lock (gate)
            {
                VMoment m; if (!moments.TryGetValue(id, out m)) { code = 404; return Err("no such moment"); }
                string v;
                if (q.TryGetValue("star", out v))
                {
                    bool on = v == "1";
                    m.Pinned = on;
                    if (!on) pins.RemoveAll(delegate (string[] p) { int lap; return p[0] == m.Session && int.TryParse(p[1], out lap) && (lap == m.Lap || (m.Kind == "race" && lap == 0)); });
                    else if (m.Kind != "clip" && m.Session.Length > 0 && !pins.Exists(delegate (string[] p) { return p[0] == m.Session && p[1] == (m.Kind == "race" ? "0" : m.Lap.ToString(Inv)); })) pins.Add(new[] { m.Session, m.Kind == "race" ? "0" : m.Lap.ToString(Inv), N3(m.LapTime) });
                    if (on && m.Ibt.Length == 0 && m.Kind != "clip") EnsureCopy(m);
                }
                if (q.TryGetValue("note", out v)) m.Note = v.Length > 400 ? v.Substring(0, 400) : v;
                if (q.TryGetValue("tag", out v) && v.Length > 1 && (v[0] == '+' || v[0] == '-' || v[0] == ' '))
                {
                    string t = v.Substring(1).Trim().ToUpperInvariant();
                    if (Regex.IsMatch(t, "^[A-Z ]{2,16}$") && t != "PB" && t != "WIN" && t != "PODIUM" && t != "BEST LAP" && t != "TOP 10" && t != "BEST RACE" && t != "BIG IR")
                    { if (v[0] == '-') m.Tags.Remove(t); else if (!m.Tags.Contains(t) && m.Tags.Count < 8) m.Tags.Add(t); }
                }
                if (q.TryGetValue("nudge", out v))
                {
                    double d; if (double.TryParse(v, NumberStyles.Float, Inv, out d)) { d = Math.Max(-3, Math.Min(3, Math.Round(d * 10) / 10)); m.Nudge = d; globalNudge = d; }       // remembered for the next clip too
                }
                dirty.Add(id);
            }
            SaveAll();
            int c; return ItemJson(id, out c);
        }

        static string DeleteRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            string id = Q(q, "id");
            if (!ValidId(id)) { code = 400; return Err("bad id"); }
            if (Q(q, "confirm") != "yes") { code = 400; return Err("needs confirm=yes (the page asks twice)"); }
            if (Program.IsDriving) { code = 503; return Err("not while driving"); }
            lock (gate)
            {
                if (!moments.ContainsKey(id)) { code = 404; return Err("no such moment"); }
                VMoment m = moments[id];
                // forget a star so it does not come back
                pins.RemoveAll(delegate (string[] p) { return p[0] == m.Session && (p[1] == m.Lap.ToString(Inv) || (m.Kind == "race" && p[1] == "0")); });
                RemoveMoment(id, true);
            }
            SaveAll(); Log.W("vault: deleted " + id);
            return "{\"ok\":true}";
        }

        // ---- OPEN IN COSWORTH / SHARE ----
        // Verified on this PC (docs\cosworth.md, 2026-10-12): Pi Toolbox opens a .pwb workbook from its command line, but a data
        // Pi needs a workbook before it accepts a data file; keep its writable copy outside Program Files.
        sealed class CosworthInfo { public bool Installed; public string Exe = ""; public string Workbook = ""; public string Template = ""; }
        static CosworthInfo cwCache; static DateTime cwAt = DateTime.MinValue;
        static volatile bool cwOpening;       // a Pi launch thread is running (StartCosworth)
        static bool pretendCw, pretendNoCw;  // sandbox only: the tests pretend Pi Toolbox is installed (on=1), is not (on=0; it IS installed on this PC since 2026-10-10), or look for real (on=auto)

        // Looks (read-only) for Cosworth Pi Toolbox: Program Files folders and the uninstall list in the registry.
        static CosworthInfo Cosworth()
        {
            if (pretendNoCw) return new CosworthInfo();
            if (pretendCw) { CosworthInfo fake = new CosworthInfo(); fake.Installed = true; return fake; }
            if (cwCache != null && (DateTime.Now - cwAt).TotalSeconds < 60) return cwCache;
            CosworthInfo ci = new CosworthInfo();
            try
            {
                List<string> dirs = new List<string>();
                foreach (string root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs") })
                {
                    if (!Directory.Exists(root)) continue;
                    foreach (string d in Directory.GetDirectories(root)) if (Regex.IsMatch(Path.GetFileName(d), "cosworth|pi toolbox|pitoolbox", RegexOptions.IgnoreCase)) dirs.Add(d);
                }
                foreach (string hive in new[] { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" })
                    foreach (Microsoft.Win32.RegistryKey rk in new[] { Microsoft.Win32.Registry.LocalMachine, Microsoft.Win32.Registry.CurrentUser })
                        using (Microsoft.Win32.RegistryKey k = rk.OpenSubKey(hive))
                        {
                            if (k == null) continue;
                            foreach (string sub in k.GetSubKeyNames())
                                using (Microsoft.Win32.RegistryKey sk = k.OpenSubKey(sub))
                                {
                                    string name = sk != null ? Convert.ToString(sk.GetValue("DisplayName")) : "";
                                    if (Regex.IsMatch(name ?? "", "pi toolbox", RegexOptions.IgnoreCase)) { string loc = Convert.ToString(sk.GetValue("InstallLocation")); if (!string.IsNullOrEmpty(loc) && Directory.Exists(loc)) dirs.Add(loc); }
                                }
                        }
                foreach (string d in dirs)
                {
                    if (ci.Exe.Length == 0)
                        foreach (string exe in Directory.GetFiles(d, "*.exe", SearchOption.AllDirectories))
                        {
                            string fn = Path.GetFileName(exe);
                            if (Regex.IsMatch(fn, "toolbox", RegexOptions.IgnoreCase) && !Regex.IsMatch(fn, "unins|update|crash", RegexOptions.IgnoreCase)) { ci.Installed = true; ci.Exe = exe; break; }
                        }
                    // The template is read-only; Pi edits its own copy in the project folder.
                    if (ci.Template.Length == 0)
                    {
                        string sim = Path.Combine(d, "Templates", "Sim");
                        if (Directory.Exists(sim))
                            foreach (string wb in Directory.GetFiles(sim, "iRacing*.pwb"))
                                if (Regex.IsMatch(Path.GetFileName(wb), "lite", RegexOptions.IgnoreCase)) { ci.Template = wb; break; }
                    }
                }
            }
            catch (Exception ex) { Log.W("vault: looking for Pi Toolbox: " + ex.Message); }
            cwCache = ci; cwAt = DateTime.Now;
            return ci;
        }

        static bool EnsureCosworthWorkbook(CosworthInfo cw)
        {
            try
            {
                if (cw.Workbook.Length == 0) cw.Workbook = Path.Combine(Program.RootDir, "cosworth", "Paddock.pwb");
                // W-19 cannot mark any workbook ready until its display structure can be edited and verified.
                if (File.Exists(cw.Workbook)) return true;
                if (cw.Template.Length == 0 || !File.Exists(cw.Template)) return false;
                Directory.CreateDirectory(Path.GetDirectoryName(cw.Workbook));
                File.Copy(cw.Template, cw.Workbook, false);
                FileAttributes attr = File.GetAttributes(cw.Workbook);
                if ((attr & FileAttributes.ReadOnly) != 0) File.SetAttributes(cw.Workbook, attr & ~FileAttributes.ReadOnly);
                return true;
            }
            catch (Exception ex) { Log.W("vault: cosworth workbook copy: " + ex.Message); return false; }
        }

        // Pi's file-forwarding pipe only works after a workbook is open (docs\cosworth.md).
        static string PiWorkbookTitle(string workbook)
        {
            return Path.GetFileNameWithoutExtension(workbook) + " - Pi Toolbox";
        }

        static string PiMainTitle()
        {
            try
            {
                foreach (Process p in Process.GetProcessesByName("Pi Toolbox"))
                {
                    p.Refresh();
                    if (p.MainWindowHandle != IntPtr.Zero && p.MainWindowTitle.Length > 0) return p.MainWindowTitle;
                }
            }
            catch { }
            return "";
        }

        static bool PiWorkbookOpen()
        {
            try
            {
                foreach (Process p in Process.GetProcessesByName("Pi Toolbox"))
                {
                    string title = p.MainWindowTitle;
                    if (p.MainWindowHandle != IntPtr.Zero && title.Length > 0 && !title.StartsWith("Untitled", StringComparison.OrdinalIgnoreCase)) return true;
                }
            }
            catch { }
            return false;
        }

        // Opens Pi with the workbook first when no workbook title is present, then forwards the lap's file; that forwarding makes
        // Pi import the .ibt (a cold launch with the file alone shows the New Workbook dialog instead). Own BelowNormal thread.
        static void StartCosworth(CosworthInfo cw, string file)
        {
            if (cw.Exe.Length == 0) return;
            cwOpening = true;
            ThreadStart work = delegate ()
            {
                try
                {
                    string title = PiMainTitle();
                    if (title.StartsWith("Untitled", StringComparison.OrdinalIgnoreCase) || title.Length == 0)
                    {
                        if (!EnsureCosworthWorkbook(cw)) { Log.W("vault: cosworth workbook/template missing; template=" + cw.Template); return; }
                        if (Program.IsDriving) { Log.W("vault: cosworth open refused; driving"); return; }
                        Process.Start(new ProcessStartInfo(cw.Exe, "\"" + cw.Workbook + "\"") { UseShellExecute = false });
                        string expected = "Paddock - Pi Toolbox";
                        for (int i = 0; i < 120; i++)
                        {
                            title = PiMainTitle();
                            if (title.StartsWith(expected, StringComparison.OrdinalIgnoreCase)) break;
                            Thread.Sleep(250);
                        }
                        title = PiMainTitle();
                        Log.W("vault: cosworth launch exe=" + cw.Exe + " argument=\"" + cw.Workbook + "\" title=" + title);
                        if (!title.StartsWith(expected, StringComparison.OrdinalIgnoreCase)) { Log.W("vault: cosworth workbook title not ready; expected prefix=" + expected); return; }
                    }
                    if (Program.IsDriving) { Log.W("vault: cosworth open refused; driving"); return; }
                    Process.Start(new ProcessStartInfo(cw.Exe, "\"" + file + "\"") { UseShellExecute = false });
                    title = PiMainTitle();
                    Log.W("vault: cosworth launch exe=" + cw.Exe + " argument=\"" + file + "\" title=" + title);
                    if (!title.EndsWith("*", StringComparison.Ordinal))
                    {
                        for (int i = 0; i < 40; i++) { Thread.Sleep(250); title = PiMainTitle(); if (title.EndsWith("*", StringComparison.Ordinal)) break; }
                    }
                    Log.W("vault: cosworth lap forwarded title=" + title);
                    if (!title.EndsWith("*", StringComparison.Ordinal)) Log.W("vault: cosworth lap title did not become dirty");
                }
                catch (Exception ex) { Log.W("vault: cosworth open: " + ex.Message); }
                finally { cwOpening = false; }
            };
            Thread t = new Thread(work); t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Name = "CosworthOpen"; t.Start();
        }

        // Resolves an open id: a Vault moment id, a telemetry file name (".ibt", as the Workbench and Session Review use) or "last".
        static string OpenTarget(string id)
        {
            VMoment m; lock (gate) moments.TryGetValue(id, out m);
            if (m != null) return TelemetryPath(m);
            if (id == "last")
            {
                try
                {
                    if (SrcDir == null || !Directory.Exists(SrcDir)) return null;
                    FileInfo best = null;
                    foreach (FileInfo fi in new DirectoryInfo(SrcDir).GetFiles("*.ibt")) if (best == null || fi.LastWriteTimeUtc > best.LastWriteTimeUtc) best = fi;
                    return best != null ? best.FullName : null;
                }
                catch { return null; }
            }
            if (id.EndsWith(".ibt", StringComparison.OrdinalIgnoreCase)) return IbtLaps.Resolve(id);
            return null;
        }

        static string OpenRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            string id = Q(q, "id"), how = Q(q, "how"); bool dry = Q(q, "dry") == "1";
            if (id.Length == 0) { code = 400; return Err("needs an id"); }
            if (Program.IsDriving) { code = 409; return Err("not while driving"); }
            string file = null;
            if (how != "share")
            {
                file = OpenTarget(id);
                if (file == null) { code = 404; return Err("the telemetry file is not there any more"); }
            }
            else
            {
                VMoment m; lock (gate) { if (!moments.TryGetValue(id, out m)) { code = 404; return Err("no such moment"); } }
                file = m.Video.Length > 0 && File.Exists(P(m.Video)) ? P(m.Video) : TelemetryPath(m);
                if (file == null) { code = 404; return Err("the file is not there any more"); }
            }
            CosworthInfo cw = Cosworth();
            string action = how == "cosworth" && cw.Installed && cw.Exe.Length > 0 ? "cosworth" : "folder";
            if (action == "cosworth" && !dry)
            {
                // A second press while Pi is still opening (it takes up to ~30 s) started a second launcher thread: two Pi windows or a
                // "workbook already open" dialog. One open at a time; the later press just says so.
                if (cwOpening) return "{\"ok\":true,\"action\":\"busy\",\"target\":" + Json_.S(file) + ",\"cosworthInstalled\":true,\"dry\":false}";
                // The thread below only logs when Pi's template is missing, so the button said "opening" and nothing happened. Check that now.
                if (PiMainTitle().Length == 0 || PiMainTitle().StartsWith("Untitled", StringComparison.OrdinalIgnoreCase))
                    if (!EnsureCosworthWorkbook(cw)) { code = 424; return Err("Pi Toolbox has no iRacing template on this PC"); }
            }
            if (!dry)
            {
                try
                {
                    // irdash is a normal program of Peter's own session: it can start apps with arguments directly
                    if (action == "cosworth") StartCosworth(cw, file);
                    else Process.Start("explorer.exe", "/select,\"" + file + "\"");
                    if (action != "cosworth") Log.W("vault: folder for " + id + " (" + file + ")");
                }
                catch (Exception ex) { Log.W("vault: open " + id + ": " + ex.Message); code = 500; return Err("could not open that"); }
            }
            return "{\"ok\":true,\"action\":" + Json_.S(action) + ",\"target\":" + Json_.S(file) + ",\"cosworthInstalled\":" + (cw.Installed ? "true" : "false") + ",\"dry\":" + (dry ? "true" : "false") + "}";
        }

        // ---- the video, with Range (the player seeks by asking for byte ranges) ----
        static bool ServeClip(NetworkStream s, string id, Dictionary<string, string> hdr)
        {
            VMoment m = null;
            if (ValidId(id)) lock (gate) moments.TryGetValue(id, out m);
            return ServeMp4(s, m != null && m.Video.Length > 0 ? P(m.Video) : null, hdr);
        }

        // an .mp4 with Range support; a null or missing file is a 404 (also used by the recorder's /vault/video)
        internal static bool ServeMp4(NetworkStream s, string file, Dictionary<string, string> hdr)
        {
            if (file == null || !File.Exists(file)) { Reply(s, 404, Err("no clip")); return true; }
            string rangeHdr; hdr.TryGetValue("Range", out rangeHdr);
            long len = new FileInfo(file).Length, a = 0, b = len - 1; int code = 200;
            if (!string.IsNullOrEmpty(rangeHdr))
            {
                Match r = Regex.Match(rangeHdr, @"^bytes=(\d*)-(\d*)$");
                if (!r.Success) { Respond(s, 416, "text/plain", new byte[0], "Content-Range: bytes */" + len + "\r\n"); return true; }
                if (r.Groups[1].Value.Length > 0) { a = long.Parse(r.Groups[1].Value); if (r.Groups[2].Value.Length > 0) b = Math.Min(len - 1, long.Parse(r.Groups[2].Value)); }
                else if (r.Groups[2].Value.Length > 0) { a = Math.Max(0, len - long.Parse(r.Groups[2].Value)); }
                if (a > b || a >= len) { Respond(s, 416, "text/plain", new byte[0], "Content-Range: bytes */" + len + "\r\n"); return true; }
                code = 206;
            }
            string head = "HTTP/1.1 " + code + (code == 206 ? " Partial Content" : " OK") + "\r\nContent-Type: video/mp4\r\nContent-Length: " + (b - a + 1) + "\r\nAccept-Ranges: bytes\r\nCache-Control: no-cache\r\nConnection: close\r\n" +
                          (code == 206 ? "Content-Range: bytes " + a + "-" + b + "/" + len + "\r\n" : "") + "\r\n";
            byte[] hb = Encoding.ASCII.GetBytes(head); s.Write(hb, 0, hb.Length);
            try
            {
                using (FileStream fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    fs.Position = a; long left = b - a + 1; byte[] buf = new byte[256 * 1024];
                    while (left > 0) { int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, left)); if (n <= 0) break; s.Write(buf, 0, n); left -= n; }
                }
                s.Flush();
            }
            catch (IOException) { }          // the player moved on (a seek closes the old connection)
            return true;
        }

        static bool ServeThumb(NetworkStream s, string id)
        {
            string f = ValidId(id) ? P(@"thumbs\" + id + ".png") : null;
            if (f == null || !File.Exists(f)) { Reply(s, 404, Err("no thumbnail yet")); return true; }
            Respond(s, 200, "image/png", File.ReadAllBytes(f), "");
            return true;
        }

        static bool ServeFrame(NetworkStream s, string id)
        {
            string f = ValidId(id) ? FramePath(id) : null;
            if (f == null || !File.Exists(f)) { Reply(s, 404, Err("no picture yet")); return true; }
            Respond(s, 200, "image/jpeg", File.ReadAllBytes(f), "");
            return true;
        }
    }

    // ---------------- real video frames for the grid cards ----------------
    // 2026-10-18 Peter: "vault is a disaster ... hard to interpret" - every card showed the same track outline. Capture galleries (NVIDIA, Xbox,
    // Steam, YouTube) show a real frame of each recording; a lap that was recorded gets one too. Source: the lap's own recorder clip, else the
    // whole-session recording that holds the lap (vault\sessions, vault\saved; a race: 25 s after its first lap starts). One ffmpeg at a time,
    // BelowNormal, never while he drives, cached in vault\thumbs\f-<id>.jpg (about 40 KB). Until it exists the card shows the map picture.
    static partial class Vault
    {
        sealed class VFrameSrc { public string File = "", Clip = ""; public double At, ClipDur; }
        static readonly object frameGate = new object();
        static bool frameBusy;
        static readonly Dictionary<string, DateTime> frameTried = new Dictionary<string, DateTime>();
        static List<Dictionary<string, object>> sideCache; static DateTime sideAt;

        static string FramePath(string id) { return P(@"thumbs\f-" + id + ".jpg"); }

        // the whole-session sidecars (small JSON beside each recording), read at most every 30 s
        static List<Dictionary<string, object>> SessionSidecars()
        {
            if (sideCache != null && (DateTime.Now - sideAt).TotalSeconds < 30) return sideCache;
            List<Dictionary<string, object>> l = new List<Dictionary<string, object>>();
            foreach (string dir in new[] { P("sessions"), P("saved") })
            {
                try
                {
                    if (!Directory.Exists(dir)) continue;
                    foreach (string f in Directory.GetFiles(dir, "*.json"))
                    {
                        try
                        {
                            string mp4 = Path.ChangeExtension(f, ".mp4"); if (!File.Exists(mp4)) continue;
                            Dictionary<string, object> d = VaultIbt.Parse(File.ReadAllText(f, Encoding.UTF8)); if (d == null) continue;
                            d["_file"] = mp4; l.Add(d);
                        }
                        catch { }
                    }
                }
                catch { }
            }
            sideCache = l; sideAt = DateTime.Now; return l;
        }

        static string SS(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, Inv) : ""; }
        static double SN(Dictionary<string, object> d, string k) { object o; double v; return d.TryGetValue(k, out o) && o != null && double.TryParse(Convert.ToString(o, Inv), NumberStyles.Float, Inv, out v) ? v : 0; }

        static VFrameSrc FrameSource(VMoment m, long from, long to, List<Dictionary<string, object>> side)
        {
            VFrameSrc clip = null;
            if (m.Lap > 0)
            {
                RecClip c = null; try { c = Recorder.ClipForShare(m.Id); } catch { }
                if (c != null && File.Exists(c.File))
                {
                    clip = new VFrameSrc(); clip.File = c.File; clip.ClipDur = c.Duration;
                    if (m.Kind != "race") clip.Clip = c.Id;                       // a race opens its RACE page, not one lap's clip
                    double lt = c.LapTime > 0 ? c.LapTime : c.LapEndOffset - c.LapStartOffset;
                    clip.At = Math.Max(0.5, Math.Min(Math.Max(0.5, c.Duration - 0.5), c.LapStartOffset + 0.3 * Math.Max(0, lt)));
                }
            }
            if (clip != null && m.Kind != "race") return clip;
            string combo = m.Combo;
            foreach (Dictionary<string, object> d in side)
            {
                if (IRDash.Combo.Key(SS(d, "car"), SS(d, "track"), SS(d, "config")) != combo) continue;
                double s0 = SN(d, "startMs"), s1 = SN(d, "endMs");
                if (s0 <= 0 || s0 > to + 120000 || (s1 > 0 && s1 < from - 120000)) continue;
                object lo; if (!d.TryGetValue("laps", out lo) || !(lo is IList)) continue;
                double dur = SN(d, "durationSec");
                foreach (object x in (IList)lo)
                {
                    Dictionary<string, object> L = x as Dictionary<string, object>; if (L == null) continue;
                    int n = (int)SN(L, "n"); double off = SN(L, "offset"), t = SN(L, "time");
                    bool hit = m.Kind == "race" ? n == 1 : (n == m.Lap && (m.LapTime <= 0 || t <= 0 || Math.Abs(t - m.LapTime) < 0.5));
                    if (!hit) continue;
                    VFrameSrc r = new VFrameSrc(); r.File = SS(d, "_file");
                    r.At = off + (m.Kind == "race" ? Math.Min(25, Math.Max(1, t * 0.5)) : 0.3 * Math.Max(0, t));
                    if (dur > 1) r.At = Math.Min(r.At, dur - 0.5);
                    r.At = Math.Max(0.5, r.At);
                    return r;
                }
            }
            return clip;
        }

        // moment id -> its recording; starts the background maker for pictures that are missing
        static Dictionary<string, VFrameSrc> FrameMap()
        {
            Dictionary<string, VFrameSrc> res = new Dictionary<string, VFrameSrc>();
            List<VMoment> ms; Dictionary<string, long[]> win = new Dictionary<string, long[]>();
            lock (gate)
            {
                ms = new List<VMoment>(moments.Values);
                Dictionary<string, VSession> byName = new Dictionary<string, VSession>();
                foreach (VSession s in sessions) if (!byName.ContainsKey(s.Name)) byName[s.Name] = s;
                foreach (VMoment m in ms)
                {
                    long f = m.StartMs, t = m.StartMs + 6L * 3600 * 1000; VSession s;
                    if (m.Session.Length > 0 && byName.TryGetValue(m.Session, out s)) { f = s.StartMs; t = s.EndMs; }
                    win[m.Id] = new[] { f, t };
                }
            }
            List<Dictionary<string, object>> side = SessionSidecars();
            List<KeyValuePair<string, VFrameSrc>> todo = new List<KeyValuePair<string, VFrameSrc>>();
            foreach (VMoment m in ms)
            {
                VFrameSrc src = null;
                try { src = FrameSource(m, win[m.Id][0], win[m.Id][1], side); } catch { }
                if (src == null) continue;
                res[m.Id] = src;
                if (!File.Exists(FramePath(m.Id))) { DateTime t; lock (frameGate) if (frameTried.TryGetValue(m.Id, out t) && (DateTime.Now - t).TotalMinutes < 10) continue; todo.Add(new KeyValuePair<string, VFrameSrc>(m.Id, src)); }
            }
            KickFrames(todo);
            return res;
        }

        static void KickFrames(List<KeyValuePair<string, VFrameSrc>> todo)
        {
            if (todo.Count == 0 || Program.IsDriving) return;
            lock (frameGate) { if (frameBusy) return; frameBusy = true; }
            Thread th = new Thread(delegate ()
            {
                try { foreach (KeyValuePair<string, VFrameSrc> kv in todo) { if (Program.IsDriving) break; MakeFrame(kv.Key, kv.Value); } }
                catch (Exception ex) { Log.W("vault: pictures: " + ex.Message); }
                finally { lock (frameGate) frameBusy = false; }
            });
            th.IsBackground = true; th.Priority = ThreadPriority.BelowNormal; th.Start();
        }

        static void MakeFrame(string id, VFrameSrc src)
        {
            lock (frameGate) frameTried[id] = DateTime.Now;
            string exe = Recorder.FfmpegExe; if (!File.Exists(exe) || !File.Exists(src.File)) return;
            string dest = FramePath(id), tmp = dest + ".tmp.jpg";
            Directory.CreateDirectory(Path.GetDirectoryName(dest));
            // -ss before -i: a fast seek to the nearest key picture; ffmpeg's own autorotate turns the 180-degree recording upright
            string args = "-hide_banner -loglevel error -y -ss " + src.At.ToString("0.000", Inv) + " -i \"" + src.File + "\" -frames:v 1 -vf scale=640:-2 -q:v 4 \"" + tmp + "\"";
            ProcessStartInfo psi = new ProcessStartInfo(exe, args); psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardError = true; psi.RedirectStandardOutput = true;
            try
            {
                using (Process p = Process.Start(psi))
                {
                    try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
                    p.StandardOutput.ReadToEndAsync(); string err = p.StandardError.ReadToEnd();
                    if (!p.WaitForExit(30000)) { try { p.Kill(); } catch { } Log.W("vault: picture of " + id + " timed out"); return; }
                    if (p.ExitCode != 0 || !File.Exists(tmp) || new FileInfo(tmp).Length < 500) { Log.W("vault: no picture for " + id + " (" + err.Trim() + ")"); try { File.Delete(tmp); } catch { } return; }
                }
                if (File.Exists(dest)) File.Delete(dest);
                File.Move(tmp, dest);
            }
            catch (Exception ex) { Log.W("vault: picture of " + id + ": " + ex.Message); }
        }
    }

    // ---------------- thumbnails (no video needed): the labelled track map with the lap's colour trace ----------------
    static partial class Vault
    {
        static readonly Dictionary<string, DateTime> thumbTried = new Dictionary<string, DateTime>();

        public static int Thumbs(int max)
        {
            List<VMoment> todo = new List<VMoment>();
            lock (gate)
                foreach (VMoment m in moments.Values)
                    if (m.Car.Length > 0 && !File.Exists(P(@"thumbs\" + m.Id + ".png"))) todo.Add(m);
            todo.Sort(delegate (VMoment a, VMoment b) { return b.Ts.CompareTo(a.Ts); });
            int made = 0;
            foreach (VMoment m in todo)
            {
                if (made >= max) break;
                DateTime t; if (thumbTried.TryGetValue(m.Id, out t) && (DateTime.Now - t).TotalMinutes < 10) continue;
                thumbTried[m.Id] = DateTime.Now;
                try { if (RenderThumb(m)) made++; }
                catch (Exception ex) { Log.W("vault: thumbnail for " + m.Id + ": " + ex.Message); }
                if (!sandbox) Thread.Sleep(100);
            }
            return made;
        }

        static double D(object o) { return Convert.ToDouble(o, Inv); }

        // the track outline kept in dash\maps (x, y metres, 720 points by lap fraction); null when there is none yet
        static List<double[]> Outline(VMoment m)
        {
            string key = TrackMaps.MakeKey(m.TrackId, m.TrackName);
            string f = TrackMaps.MapsDir != null ? Path.Combine(TrackMaps.MapsDir, key + ".json") : null;
            if (f == null || !File.Exists(f)) return null;
            Dictionary<string, object> d = VaultIbt.Parse(File.ReadAllText(f, Encoding.UTF8)); object o;
            if (d == null || !d.TryGetValue("pts", out o) || !(o is IList)) return null;
            List<double[]> pts = new List<double[]>();
            foreach (object p in (IList)o) { IList xy = p as IList; if (xy != null && xy.Count >= 2) pts.Add(new[] { D(xy[0]), D(xy[1]) }); }
            return pts.Count >= 200 ? pts : null;
        }

        static Font Face(float px, FontStyle st)
        {
            foreach (string n in new[] { "Bahnschrift SemiCondensed", "Bahnschrift", "Segoe UI" })
                foreach (FontFamily ff in FontFamily.Families) if (ff.Name == n) return new Font(ff, px, st, GraphicsUnit.Pixel);
            return new Font(FontFamily.GenericSansSerif, px, st, GraphicsUnit.Pixel);
        }

        static Color Ramp(double t)
        {
            t = Math.Max(0, Math.Min(1, t));
            int r = (int)(110 + t * (255 - 110)), g = (int)(66 + t * (230 - 66)), b = (int)(14 + t * (140 - 14));
            return Color.FromArgb(r, g, b);
        }

        // 640 x 400 PNG: outline (casing, edge, tarmac), the lap drawn over it from dark bronze (slow) to bright gold (fast), the start line, numbered corners
        static bool RenderThumb(VMoment m)
        {
            string file = TelemetryPath(m);
            if (file == null) return false;
            double[] spd = null;
            int lapNo = m.Lap;
            if (lapNo > 0)
            {
                string lj = IbtLaps.LapJson(file, lapNo);
                if (lj != null) { Dictionary<string, object> d = VaultIbt.Parse(lj); IList a = d["spd"] as IList; if (a != null) { spd = new double[a.Count]; for (int i = 0; i < spd.Length; i++) spd[i] = D(a[i]); } }
            }
            List<double[]> pts = Outline(m);
            CornerSet cs = null;
            try { string key = TrackMaps.MakeKey(m.TrackId, m.TrackName); cs = Corners.Resolve(m.TrackName, m.Config, m.TrackId, key, false); } catch { }
            const int W = 640, H = 400;
            using (Bitmap bmp = new Bitmap(W, H, PixelFormat.Format32bppArgb))
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                using (LinearGradientBrush bg = new LinearGradientBrush(new Rectangle(0, 0, W, H), Color.FromArgb(18, 18, 16), Color.FromArgb(5, 5, 5), 60f)) g.FillRectangle(bg, 0, 0, W, H);
                if (pts != null)
                {
                    int N = pts.Count;
                    double x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
                    foreach (double[] p in pts) { x0 = Math.Min(x0, p[0]); x1 = Math.Max(x1, p[0]); y0 = Math.Min(y0, p[1]); y1 = Math.Max(y1, p[1]); }
                    double pad = 44, tw = x1 - x0, th = y1 - y0; if (tw <= 0) tw = 1; if (th <= 0) th = 1;
                    double sA = Math.Min((W - 2 * pad) / tw, (H - 2 * pad) / th), sB = Math.Min((W - 2 * pad) / th, (H - 2 * pad) / tw); bool rot = sB > sA * 1.08; double sc = rot ? sB : sA;
                    PointF[] scr = new PointF[N];
                    for (int i = 0; i < N; i++)
                    {
                        double x = (pts[i][0] - (x0 + x1) / 2) * sc, y = -(pts[i][1] - (y0 + y1) / 2) * sc;
                        if (rot) { double t = x; x = -y; y = t; }
                        scr[i] = new PointF((float)(W / 2 + x), (float)(H / 2 + y));
                    }
                    Func<double, PointF> at = delegate (double pct)
                    {
                        double f = ((pct % 1) + 1) % 1 * N; int i = (int)Math.Floor(f) % N; double t = f - Math.Floor(f); PointF a = scr[i], b = scr[(i + 1) % N];
                        return new PointF((float)(a.X + (b.X - a.X) * t), (float)(a.Y + (b.Y - a.Y) * t));
                    };
                    foreach (object[] pen in new object[][] { new object[] { Color.FromArgb(7, 9, 12), 21f }, new object[] { Color.FromArgb(211, 216, 222), 12.5f }, new object[] { Color.FromArgb(35, 42, 50), 9.5f } })
                        using (Pen p = new Pen((Color)pen[0], (float)pen[1])) { p.LineJoin = LineJoin.Round; p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; g.DrawPolygon(p, scr); }
                    if (spd != null)
                    {
                        double lo = 1e9, hi = -1e9; foreach (double v in spd) { lo = Math.Min(lo, v); hi = Math.Max(hi, v); }
                        if (hi - lo < 1) hi = lo + 1;
                        for (int i = 0; i < N; i++)
                        {
                            double v = spd[Math.Min(spd.Length - 1, (int)Math.Round((i + 0.5) / N * (spd.Length - 1)))];
                            using (Pen p = new Pen(Ramp((v - lo) / (hi - lo)), 5.5f)) { p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; g.DrawLine(p, scr[i], scr[(i + 1) % N]); }
                        }
                    }
                    PointF s0 = at(0), s1 = at(0.003); double dx = s1.X - s0.X, dy = s1.Y - s0.Y, mm = Math.Sqrt(dx * dx + dy * dy); if (mm < 0.001) mm = 1;
                    using (Pen p = new Pen(Color.White, 3.5f)) g.DrawLine(p, (float)(s0.X - dy / mm * 14), (float)(s0.Y + dx / mm * 14), (float)(s0.X + dy / mm * 14), (float)(s0.Y - dx / mm * 14));
                    if (cs != null && cs.Turns.Count > 0)
                        using (Font f = Face(13f, FontStyle.Bold))
                        using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                        {
                            List<PointF> placed = new List<PointF>();
                            foreach (CornerTurn t in cs.Turns)
                            {
                                PointF p0 = at(t.Pa);
                                // a disc that would cover another slides sideways along the normal
                                PointF a = at(t.Pa - 0.004), b = at(t.Pa + 0.004); double nx = -(b.Y - a.Y), ny = b.X - a.X, nm = Math.Sqrt(nx * nx + ny * ny); if (nm < 0.001) nm = 1; nx /= nm; ny /= nm;
                                PointF c = p0;
                                foreach (int k in new[] { 0, 1, -1, 2, -2 })
                                {
                                    PointF cand = new PointF((float)(p0.X + nx * k * 26), (float)(p0.Y + ny * k * 26)); bool clash = false;
                                    foreach (PointF o in placed) if (Math.Abs(o.X - cand.X) < 24 && Math.Abs(o.Y - cand.Y) < 24) clash = true;
                                    if (!clash) { c = cand; break; }
                                }
                                placed.Add(c);
                                using (SolidBrush dark = new SolidBrush(Color.FromArgb(13, 17, 22))) g.FillEllipse(dark, c.X - 12.5f, c.Y - 12.5f, 25, 25);
                                using (Pen gp = new Pen(Color.FromArgb(242, 194, 48), 2f)) g.DrawEllipse(gp, c.X - 11f, c.Y - 11f, 22, 22);
                                using (SolidBrush gb = new SolidBrush(Color.FromArgb(242, 194, 48))) g.DrawString(t.N.ToString(Inv), f, gb, new RectangleF(c.X - 14, c.Y - 13, 28, 26), sf);
                            }
                        }
                }
                else if (spd != null)
                {
                    // no outline for this track yet: the speed profile of the lap, so the card still shows the lap
                    double lo = 1e9, hi = -1e9; foreach (double v in spd) { lo = Math.Min(lo, v); hi = Math.Max(hi, v); }
                    if (hi - lo < 1) hi = lo + 1;
                    PointF[] ln = new PointF[spd.Length];
                    for (int i = 0; i < spd.Length; i++) ln[i] = new PointF(30 + i * (W - 60f) / (spd.Length - 1), (float)(H - 50 - (spd[i] - lo) / (hi - lo) * (H - 110)));
                    using (Pen p = new Pen(Color.FromArgb(242, 194, 48), 3f)) g.DrawLines(p, ln);
                }
                string dir = P("thumbs"); Directory.CreateDirectory(dir);
                string dest = Path.Combine(dir, m.Id + ".png");
                bmp.Save(dest + ".tmp", ImageFormat.Png);
                if (File.Exists(dest)) File.Delete(dest);
                File.Move(dest + ".tmp", dest);
            }
            return true;
        }

        // ---------------- test routes (only while dash\test-hook.on exists, i.e. never during a real session) ----------------
        static string TestRoute(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            // Leaving the scratch vault only puts the real one back, so it works even with the hook shut. A test cut short because the sim
            // started (2026-10-10 23:38) otherwise left irdash in the scratch vault, and his real race was never read.
            bool leaving = sandbox && path == "/vault/test/sandbox" && Q(q, "on") != "1";
            if (!Sdk.TestHook && !leaving)
            {
                string busy = Sdk.RealBusy();
                if (busy != null) { Log.W("test hook refused: " + busy); code = 409; return Err("refused: " + busy); }
                code = 404; return Err("not found");
            }
            string proj = Program.RootDir, tdir = Path.Combine(proj, "vault-test");
            switch (path)
            {
                case "/vault/test/rec": case "/vault/test/recmap": case "/vault/test/recswitch": return Recorder.TestRoute(path, q, out code);       // the recorder's own test routes (recorder.cs)
                case "/vault/test/sandbox":
                    {
                        // a scratch vault under vault-test\ (its own telemetry folder and "NVIDIA" folder); the real one is untouched
                        lock (workGate)
                        if (Q(q, "on") == "1")
                        {
                            sandbox = true;
                            Root = Path.Combine(tdir, "vault"); SrcDir = Path.Combine(tdir, "src"); NvDirOverride = Path.Combine(tdir, "nvidia");
                            if (Q(q, "reset") == "1" && Directory.Exists(Root)) Directory.Delete(Root, true);
                            Directory.CreateDirectory(Root); Directory.CreateDirectory(SrcDir); Directory.CreateDirectory(NvDirOverride);
                            budgetOverride = -1; thumbTried.Clear(); clipPending.Clear(); TestEvents.Clear(); pretendOnline.Clear(); pretendCw = false; pretendNoCw = false; pretendSim = false; pretendDisconnected = false; cwCache = null;
                            growName = ""; growSize = -1; overSince = DateTime.MinValue;
                            Load(); watchSince = DateTime.UtcNow.AddDays(-3650);
                            Wheel.Ensure(); Wheel.ResetTransient();
                            string rd; if (q.TryGetValue("days", out rd)) { int dd; if (int.TryParse(rd, out dd) && dd > 0 && dd < 20000) RecentDays = dd; }
                        }
                        else
                        {
                            sandbox = false; Root = realRoot; SrcDir = realSrc; NvDirOverride = null; budgetOverride = -1; pretendCw = false; pretendNoCw = false; pretendSim = false; pretendDisconnected = false; cwCache = null; ReadIni(); Wheel.ResetTransient(); thumbTried.Clear(); clipPending.Clear(); Load();
                        }
                        Recorder.VaultRootChanged();       // its session list must follow the vault, or retention deletes the other vault's videos
                        return "{\"ok\":true,\"sandbox\":" + (sandbox ? "true" : "false") + ",\"root\":" + Json_.S(Root) + ",\"src\":" + Json_.S(SrcDir) + ",\"nvidia\":" + Json_.S(NvDirOverride ?? "") + "}";
                    }
            }
            if (!sandbox) { code = 409; return Err("start the sandbox first (/vault/test/sandbox?on=1)"); }
            switch (path)
            {
                case "/vault/test/online":
                    pretendOnline.Add(Q(q, "name"));
                    return "{\"ok\":true}";
                case "/vault/test/cosworth":
                    pretendCw = Q(q, "on") == "1"; pretendNoCw = Q(q, "on") == "0"; cwCache = null;
                    return "{\"ok\":true,\"installed\":" + (Cosworth().Installed ? "true" : "false") + "}";
                case "/vault/test/simrunning":
                    // C-27: pretend iRacingSim64DX11 is still open (the test cannot start the real sim, and must not)
                    pretendSim = Q(q, "on") == "1";
                    return "{\"ok\":true,\"simRunning\":" + (SimRunning() ? "true" : "false") + "}";
                case "/vault/test/disconnected":
                    pretendDisconnected = Q(q, "on") == "1";
                    return "{\"ok\":true,\"disconnected\":" + (pretendDisconnected ? "true" : "false") + "}";
                case "/vault/test/overscan":
                    {
                        // C-27: one look at the newest file with the REAL rules (sim pretended open, session over, settled), not the test shortcut
                        int before = sessions.Count; lock (workGate) { ScanSessions(false, 1, true); }
                        return "{\"ok\":true,\"read\":" + (sessions.Count - before) + ",\"sessions\":" + sessions.Count + ",\"moments\":" + moments.Count + "}";
                    }
                case "/vault/test/scan":
                    {
                        bool more = ScanSessions(true, 500);
                        return "{\"ok\":true,\"more\":" + (more ? "true" : "false") + ",\"sessions\":" + sessions.Count + ",\"moments\":" + moments.Count + "}";
                    }
                case "/vault/test/thumbs": return "{\"made\":" + Thumbs(200) + "}";
                case "/vault/test/clips": return "{\"attached\":" + WatchClips(true) + "}";
                case "/vault/test/prune":
                    {
                        long b; if (long.TryParse(Q(q, "bytes"), out b)) budgetOverride = b; else budgetOverride = -1;
                        string msg = Prune();
                        return "{\"ok\":true,\"message\":" + Json_.S(msg) + ",\"used\":" + UsedBytes() + "}";
                    }
                case "/vault/test/mark":
                    {
                        VMark mk = new VMark(); long.TryParse(Q(q, "ms"), out mk.Ms); mk.Kind = Q(q, "kind") == "clip" ? "clip" : "keep"; mk.Car = Q(q, "car"); mk.Track = Q(q, "track"); mk.Config = Q(q, "config");
                        int.TryParse(Q(q, "lap"), out mk.Lap); double.TryParse(Q(q, "pct"), NumberStyles.Float, Inv, out mk.Pct);
                        lock (gate) marks.Add(mk);
                        return "{\"ok\":true,\"marks\":" + marks.Count + "}";
                    }
                case "/vault/test/yaml": Sdk.FakeSession(Wheel.SampleYaml()); return "{\"ok\":true}";
                case "/vault/test/wheel": return Wheel.TestJson(q);
                case "/vault/test/events":
                    {
                        string ev = string.Join("|", TestEvents.ToArray()); if (Q(q, "clear") == "1") TestEvents.Clear();
                        return "{\"events\":" + Json_.S(ev) + ",\"lastClipKey\":" + Json_.S(LastClipKey) + "}";
                    }
                case "/vault/test/reconcile": Reconcile(); LinkClips(); SaveAll(); return "{\"ok\":true,\"moments\":" + moments.Count + "}";
                case "/vault/test/mp4":
                    {
                        // the length of an mp4 in the sandbox's nvidia folder (tests the box reader)
                        string full = Path.GetFullPath(Path.Combine(NvDirOverride, Q(q, "file"))); double dur = 0; string why = "no such file"; bool ok = false;
                        if (full.StartsWith(Path.GetFullPath(NvDirOverride) + "\\", StringComparison.OrdinalIgnoreCase) && File.Exists(full)) ok = VaultMp4.Info(full, out dur, out why);
                        return "{\"ok\":" + (ok ? "true" : "false") + ",\"seconds\":" + dur.ToString("0.###", Inv) + ",\"why\":" + Json_.S(why) + "}";
                    }
            }
            code = 404; return Err("not found");
        }
    }
}
