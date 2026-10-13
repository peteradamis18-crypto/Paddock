// WS13 - "how good am I?" (notes in docs\benchmark.md).
//   - FieldLaps (B1): every other human driver's best lap per car + track + layout, kept in data\fieldlaps.tsv. Filled by reading the
//     session YAML of every .ibt once (backfill) and, from now on, from the live session when it ends (CarIdx telemetry + results).
//   - ProRefs (B3): data\pro-refs.json, real-world official timing, written by hand with a source URL for every number.
//   - Bench (B4): /bench and /bench/list - Peter's personal best against each yardstick, each with its source and sample size.
// Nothing here runs per sim frame: the live capture is a few integer compares on the delta bar's timer and a worker thread every 30 s.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    sealed class FieldRow
    {
        public string Sid = "", Type = "", Car = "", Track = "", Config = "", Lic = "", Src = "";
        public int Num, Uid, Ir, Laps; public long Ts; public double Best; public bool Me;
        public string DedupKey { get { return Sid + "|" + Num + "|" + Uid; } }
    }

    sealed class FieldStats
    {
        public int N;                 // other human drivers with a best lap in this combo
        public double[] Asc = new double[0];
        public double Top5, Top25, Median;
        public int SimN, MyIr; public double SimMedian;   // drivers within 250 iRating of yours
        public bool Enough { get { return N >= Bench.MinField; } }
    }

    // ---------------- B1: other drivers' best laps ----------------
    static class FieldLaps
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly object gate = new object();
        public static string Dir, FieldFile, ScannedFile;
        static readonly Dictionary<string, double> known = new Dictionary<string, double>();     // dedup key -> best written so far
        static readonly HashSet<string> scanned = new HashSet<string>();
        static bool inited;
        const string Header = "#sid\tnum\ttype\tts\tcar\ttrack\tconfig\tuid\tir\tlic\tbest\tlaps\tme\tsrc";

        public static void Init(string dataDir)
        {
            if (inited) return; inited = true;
            Dir = dataDir; FieldFile = Path.Combine(dataDir, "fieldlaps.tsv"); ScannedFile = Path.Combine(dataDir, "fieldlaps.scanned.txt");
            try { Directory.CreateDirectory(dataDir); } catch { }
            foreach (FieldRow r in ReadAll(true)) { double b; if (!known.TryGetValue(r.DedupKey, out b) || r.Best < b) known[r.DedupKey] = r.Best; }
            try { if (File.Exists(ScannedFile)) foreach (string l in File.ReadAllLines(ScannedFile)) if (l.Length > 0) scanned.Add(l); } catch { }
            Thread t = new Thread(delegate ()
            {
                try
                {
                    Thread.Sleep(150000);                          // the boot and the first career scan come first
                    while (true)
                    {
                        while (Program.IsDriving) Thread.Sleep(30000);
                        Backfill();
                        // a finished session writes a new .ibt: look again a few minutes after the next one
                        Thread.Sleep(600000);
                    }
                }
                catch (Exception ex) { Log.W("field laps: " + ex.Message); }
            });
            t.IsBackground = true; t.Priority = ThreadPriority.Lowest; t.Start();
        }

        // ---- reading the YAML (pure: tests call this with real .ibt text) ----
        static string Section(string yaml, string name)
        {
            int s;
            if (yaml.StartsWith(name + ":", StringComparison.Ordinal)) s = 0;
            else { s = yaml.IndexOf("\n" + name + ":", StringComparison.Ordinal); if (s < 0) return ""; s++; }
            Match m = Regex.Match(yaml.Substring(s), @"^\S+:.*?(?=^\S|\z)", RegexOptions.Multiline | RegexOptions.Singleline);
            return m.Success ? m.Value : "";
        }

        sealed class Drv { public int Idx, Uid, Ir, Cls; public bool Ai, Pace, Spec; public string Car = "", Lic = ""; public bool Human { get { return !Ai && !Pace && !Spec && Uid > 0; } } }

        // Every human driver's best lap of every session in the YAML that has results.
        // otherHumans counts the human drivers besides you (0 = an AI or practice-alone session: nothing to record).
        public static List<FieldRow> ParseYaml(string yaml, long ts, string src, out int otherHumans)
        {
            List<FieldRow> rows = new List<FieldRow>();
            otherHumans = 0;
            if (string.IsNullOrEmpty(yaml)) return rows;
            string track = TrackMaps.YamlValue(yaml, "TrackDisplayName"), config = TrackMaps.YamlValue(yaml, "TrackConfigName"), trackName = TrackMaps.YamlValue(yaml, "TrackName");
            int sub; int.TryParse(TrackMaps.YamlValue(yaml, "SubSessionID"), out sub);
            int me; if (!int.TryParse(TrackMaps.YamlValue(yaml, "DriverCarIdx"), out me)) me = -1;
            Dictionary<int, Drv> drivers = new Dictionary<int, Drv>();
            foreach (Match m in Regex.Matches(Section(yaml, "DriverInfo"), @"- CarIdx: (\d+)[ \t]*\r?\n((?:   [^\r\n]*\r?\n?)*)"))
            {
                string b = m.Groups[2].Value; Drv d = new Drv();
                d.Idx = int.Parse(m.Groups[1].Value);
                int.TryParse(TrackMaps.YamlValue(b, "UserID"), out d.Uid); int.TryParse(TrackMaps.YamlValue(b, "IRating"), out d.Ir); int.TryParse(TrackMaps.YamlValue(b, "CarClassID"), out d.Cls);
                d.Ai = TrackMaps.YamlValue(b, "CarIsAI") == "1"; d.Pace = TrackMaps.YamlValue(b, "CarIsPaceCar") == "1"; d.Spec = TrackMaps.YamlValue(b, "IsSpectator") == "1";
                d.Car = TrackMaps.YamlValue(b, "CarScreenName"); d.Lic = TrackMaps.YamlValue(b, "LicString");
                drivers[d.Idx] = d;
            }
            foreach (Drv d in drivers.Values) if (d.Human && d.Idx != me) otherHumans++;
            if (otherHumans == 0) return rows;
            string sid = sub > 0 ? "s" + sub : "t" + ts + "-" + Combo.Slug(trackName);
            string ss = Section(yaml, "SessionInfo");
            MatchCollection heads = Regex.Matches(ss, @"(?m)^ - SessionNum: (\d+)");
            for (int i = 0; i < heads.Count; i++)
            {
                int from = heads[i].Index, to = i + 1 < heads.Count ? heads[i + 1].Index : ss.Length;
                string chunk = ss.Substring(from, to - from);
                int num = int.Parse(heads[i].Groups[1].Value);
                string type = TrackMaps.YamlValue(chunk, "SessionType");
                foreach (Match r in Regex.Matches(chunk, @"- Position: \d+[ \t]*\r?\n((?:     [^\r\n]*\r?\n?)*)"))
                {
                    string b = r.Groups[1].Value;
                    int idx; if (!int.TryParse(TrackMaps.YamlValue(b, "CarIdx"), out idx)) continue;
                    Drv d; if (!drivers.TryGetValue(idx, out d) || !d.Human || d.Car.Length == 0) continue;
                    double best; if (!double.TryParse(TrackMaps.YamlValue(b, "FastestTime"), NumberStyles.Float, Inv, out best) || best < 15 || best > 1800) continue;
                    int laps; int.TryParse(TrackMaps.YamlValue(b, "LapsComplete"), out laps);
                    FieldRow row = new FieldRow();
                    row.Sid = sid; row.Num = num; row.Type = type; row.Ts = ts; row.Car = d.Car; row.Track = track; row.Config = config; row.Uid = d.Uid; row.Ir = d.Ir; row.Lic = d.Lic;
                    row.Best = best; row.Laps = laps; row.Me = idx == me; row.Src = src;
                    rows.Add(row);
                }
            }
            return rows;
        }

        // ---- the file ----
        static string Clean(string s) { return (s ?? "").Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' '); }

        static string Line(FieldRow r)
        {
            return string.Join("\t", new[] { r.Sid, r.Num.ToString(Inv), Clean(r.Type), r.Ts.ToString(Inv), Clean(r.Car), Clean(r.Track), Clean(r.Config), r.Uid.ToString(Inv), r.Ir.ToString(Inv),
                                             Clean(r.Lic), r.Best.ToString("0.000", Inv), r.Laps.ToString(Inv), r.Me ? "1" : "0", Clean(r.Src) });
        }

        // append-only: a row is written only when it is new or faster than what is stored for that session and driver
        public static int Append(List<FieldRow> rows)
        {
            if (rows.Count == 0) return 0;
            StringBuilder sb = new StringBuilder(); int added = 0;
            lock (gate)
            {
                bool fresh = !File.Exists(FieldFile) || new FileInfo(FieldFile).Length == 0;
                if (fresh) sb.Append(Header).Append("\r\n");
                foreach (FieldRow r in rows)
                {
                    double b;
                    if (known.TryGetValue(r.DedupKey, out b) && b <= r.Best + 0.0005) continue;
                    known[r.DedupKey] = r.Best; sb.Append(Line(r)).Append("\r\n"); added++;
                }
                if (added > 0) { Directory.CreateDirectory(Dir); File.AppendAllText(FieldFile, sb.ToString(), new UTF8Encoding(false)); cacheStamp = ""; }
            }
            return added;
        }

        static string cacheStamp = ""; static List<FieldRow> cache = new List<FieldRow>();

        // every row, best per session and driver (a later, faster row replaces an earlier one)
        public static List<FieldRow> ReadAll(bool force)
        {
            lock (gate)
            {
                if (FieldFile == null || !File.Exists(FieldFile)) return new List<FieldRow>();
                FileInfo fi = new FileInfo(FieldFile); string stamp = fi.Length + ":" + fi.LastWriteTimeUtc.Ticks;
                if (!force && stamp == cacheStamp) return cache;
                Dictionary<string, FieldRow> best = new Dictionary<string, FieldRow>();
                foreach (string line in File.ReadAllLines(FieldFile, Encoding.UTF8))
                {
                    if (line.Length == 0 || line[0] == '#') continue;
                    try
                    {
                        string[] f = line.Split('\t'); if (f.Length < 14) continue;
                        FieldRow r = new FieldRow();
                        r.Sid = f[0]; r.Num = int.Parse(f[1]); r.Type = f[2]; r.Ts = long.Parse(f[3]); r.Car = f[4]; r.Track = f[5]; r.Config = f[6]; r.Uid = int.Parse(f[7]); r.Ir = int.Parse(f[8]);
                        r.Lic = f[9]; r.Best = double.Parse(f[10], Inv); r.Laps = int.Parse(f[11]); r.Me = f[12] == "1"; r.Src = f[13];
                        FieldRow o; if (!best.TryGetValue(r.DedupKey, out o) || r.Best < o.Best) best[r.DedupKey] = r;
                    }
                    catch { }
                }
                cache = new List<FieldRow>(best.Values); cacheStamp = stamp;
                return cache;
            }
        }

        // ---- B1 backfill: the YAML of each .ibt, once ----
        // What an .ibt holds is the player's own car only (no CarIdx channels, whatever irsdkLogAllCars says), so the other drivers'
        // best laps come from the session YAML at the moment recording began. That is partial for a session you joined late.
        public static string Backfill()
        {
            string dir = TrackMaps.TelemetryDir;
            if (dir == null || !Directory.Exists(dir)) return "no telemetry folder";
            int files = 0, withOthers = 0, added = 0, skipped = 0;
            foreach (string path in Directory.GetFiles(dir, "*.ibt"))
            {
                if (Program.IsDriving) { skipped++; break; }
                FileInfo fi = new FileInfo(path);
                if ((DateTime.Now - fi.LastWriteTime).TotalMinutes < 2) { skipped++; continue; }      // still being written
                string sig = fi.Name + "|" + fi.Length;
                lock (gate) if (scanned.Contains(sig)) continue;
                if (Career.OnlineOnly(fi)) { skipped++; continue; }
                int others = 0; List<FieldRow> rows = new List<FieldRow>();
                try { rows = ScanFile(path, out others); }
                catch (Exception ex) { Log.W("field laps " + fi.Name + ": " + ex.Message); skipped++; continue; }
                files++; if (others > 0) withOthers++;
                added += Append(rows);
                lock (gate) { scanned.Add(sig); try { File.AppendAllText(ScannedFile, sig + "\r\n", new UTF8Encoding(false)); } catch { } }
                Thread.Sleep(15);
            }
            string msg = "field laps: read " + files + " telemetry files, " + withOthers + " had other human drivers, " + added + " driver laps added" + (skipped > 0 ? " (" + skipped + " left for later)" : "");
            if (files > 0) Log.W(msg);
            return msg;
        }

        // the rows of one file (reads only the header and the session text)
        public static List<FieldRow> ScanFile(string path, out int otherHumans)
        {
            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, false);
            if (t == null) { otherHumans = 0; return new List<FieldRow>(); }
            long ts = 0;
            using (t.fs)
            {
                byte[] h = new byte[144]; t.fs.Position = 0; t.fs.Read(h, 0, 144);
                long sd = BitConverter.ToInt64(h, 112);
                if (sd > 1000000000L && sd < 4000000000L) ts = sd;
                else ts = (long)(new FileInfo(path).LastWriteTimeUtc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
                return ParseYaml(t.yaml, ts, "ibt-start", out otherHumans);
            }
        }

        // ---- live: the end of a session with other drivers ----
        static int capVer = -1, capNum = -1; static string capYaml = ""; static bool capUp, capHumans = true;
        static DateTime capAt = DateTime.MinValue, teleAt = DateTime.MinValue, humansCheckedAt = DateTime.MinValue;
        static readonly float[] teleBest = new float[64];
        static int capBusy; static long capTs;

        // from the delta bar's timer on the UI thread: cheap compares; the work happens on a worker thread
        public static void Tick(Frame f, DateTime now)
        {
            if (!inited) return;
            if (!f.Connected)
            {
                if (capUp) { capUp = false; Queue(capYaml, true); Array.Clear(teleBest, 0, 64); capVer = -1; capNum = -1; }
                return;
            }
            if (!capUp) { capUp = true; capAt = now; capTs = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; humansCheckedAt = DateTime.MinValue; capHumans = true; }
            if (f.SessionVersion != capVer) { capVer = f.SessionVersion; capYaml = f.SessionYaml; }
            if (!capHumans && (now - humansCheckedAt).TotalSeconds < 120) return;     // an AI or solo session: look again now and then (someone may join)
            int num = (int)f.Num("SessionNum");
            if (capNum >= 0 && num != capNum) { Queue(capYaml, false); }               // practice -> qualify -> race: keep the one that just ended
            capNum = num;
            if ((now - teleAt).TotalSeconds >= 5 && capHumans)
            {
                teleAt = now;
                VarDef d;
                if (f.Vars != null && f.Vars.TryGetValue("CarIdxBestLapTime", out d) && d.Count >= 2 && d.Type == 4 && d.Offset >= 0 && d.Offset + 4 * d.Count <= f.Data.Length)
                    for (int i = 0; i < d.Count && i < 64; i++)
                    {
                        float v = BitConverter.ToSingle(f.Data, d.Offset + i * 4);
                        if (v > 15 && v < 1800 && (teleBest[i] <= 0 || v < teleBest[i])) teleBest[i] = v;
                    }
            }
            if ((now - capAt).TotalSeconds >= 30) { capAt = now; Queue(capYaml, false); }
        }

        static void Queue(string yaml, bool final)
        {
            if (string.IsNullOrEmpty(yaml)) return;
            float[] tele = (float[])teleBest.Clone(); long ts = capTs;
            if (Interlocked.Exchange(ref capBusy, 1) == 1 && !final) return;
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    int others;
                    List<FieldRow> rows = ParseYaml(yaml, ts, "live", out others);
                    humansCheckedAt = DateTime.Now; capHumans = others > 0;
                    // the sim's own per-car best (telemetry) fills in a driver the results text has not caught up with yet
                    string cur = TrackMaps.YamlValue(yaml, "CurrentSessionNum");
                    int curNum; int.TryParse(cur, out curNum);
                    if (others > 0)
                    {
                        Dictionary<int, double> have = new Dictionary<int, double>();
                        foreach (FieldRow r in rows) if (r.Num == curNum) have[r.Uid] = r.Best;
                        string track = TrackMaps.YamlValue(yaml, "TrackDisplayName"), config = TrackMaps.YamlValue(yaml, "TrackConfigName"), trackName = TrackMaps.YamlValue(yaml, "TrackName");
                        int sub; int.TryParse(TrackMaps.YamlValue(yaml, "SubSessionID"), out sub);
                        int meIdx; if (!int.TryParse(TrackMaps.YamlValue(yaml, "DriverCarIdx"), out meIdx)) meIdx = -1;
                        string type = Career.SessionTypeOf(yaml, curNum);
                        // car index -> driver, for the telemetry values
                        foreach (Match m in Regex.Matches(Section(yaml, "DriverInfo"), @"- CarIdx: (\d+)[ \t]*\r?\n((?:   [^\r\n]*\r?\n?)*)"))
                        {
                            int idx = int.Parse(m.Groups[1].Value); if (idx >= 64 || tele[idx] <= 0) continue;
                            string b = m.Groups[2].Value;
                            int uid; if (!int.TryParse(TrackMaps.YamlValue(b, "UserID"), out uid) || uid <= 0) continue;
                            if (TrackMaps.YamlValue(b, "CarIsAI") == "1" || TrackMaps.YamlValue(b, "CarIsPaceCar") == "1" || TrackMaps.YamlValue(b, "IsSpectator") == "1") continue;
                            double hv; if (have.TryGetValue(uid, out hv) && hv <= tele[idx] + 0.0005) continue;
                            FieldRow r2 = new FieldRow();
                            r2.Sid = sub > 0 ? "s" + sub : "t" + ts + "-" + Combo.Slug(trackName); r2.Num = curNum; r2.Type = type; r2.Ts = ts;
                            r2.Car = TrackMaps.YamlValue(b, "CarScreenName"); r2.Track = track; r2.Config = config; r2.Uid = uid;
                            int.TryParse(TrackMaps.YamlValue(b, "IRating"), out r2.Ir); r2.Lic = TrackMaps.YamlValue(b, "LicString");
                            r2.Best = tele[idx]; r2.Laps = 0; r2.Me = idx == meIdx; r2.Src = "live-telemetry";
                            if (r2.Car.Length > 0) rows.Add(r2);
                        }
                    }
                    int added = Append(rows);
                    if (added > 0) Log.W("field laps: " + added + " driver laps saved from this session");
                }
                catch (Exception ex) { Log.W("field laps (live): " + ex.Message); }
                finally { Interlocked.Exchange(ref capBusy, 0); }
            });
        }

        // ---- the numbers for one combo ----
        public static FieldStats For(string car, string track, string config, int myIr)
        {
            FieldStats s = new FieldStats(); s.MyIr = myIr;
            Dictionary<int, double[]> byUid = new Dictionary<int, double[]>();     // uid -> { best, iRating at that lap }
            foreach (FieldRow r in ReadAll(false))
            {
                if (r.Me || r.Car != car || r.Track != track || r.Config != config) continue;
                double[] o; if (!byUid.TryGetValue(r.Uid, out o) || r.Best < o[0]) byUid[r.Uid] = new[] { r.Best, (double)r.Ir };
            }
            List<double> all = new List<double>(), sim = new List<double>();
            foreach (double[] v in byUid.Values)
            {
                all.Add(v[0]);
                if (myIr > 0 && v[1] > 1 && Math.Abs(v[1] - myIr) <= 250) sim.Add(v[0]);
            }
            all.Sort(); sim.Sort();
            s.N = all.Count; s.Asc = all.ToArray();
            if (s.N > 0) { s.Top5 = Bench.Percentile(s.Asc, 0.05); s.Top25 = Bench.Percentile(s.Asc, 0.25); s.Median = Bench.Percentile(s.Asc, 0.5); }
            s.SimN = sim.Count; if (sim.Count > 0) s.SimMedian = Bench.Percentile(sim.ToArray(), 0.5);
            return s;
        }
    }

    // ---------------- B3: real-world references (data\pro-refs.json) ----------------
    static class ProRefs
    {
        // Entries are matched on iRacing's own identifiers: the car's folder name (carPath, e.g. chevyvettez06rgt3) and the track's
        // (trackName, e.g. "roadatlanta full" - the layout is part of it). An entry says carClass ("GT3", "GTP": the "classes" list in
        // the file names the car folders in it) or one carPath.
        public static string File_;
        static DateTime stamp = DateTime.MinValue; static List<Dictionary<string, object>> cache = new List<Dictionary<string, object>>(); static string note = "", checkedOn = "";
        static readonly Dictionary<string, List<string>> classes = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        static readonly object gate = new object();

        public static string Note { get { Load(); return note; } }
        public static string CheckedOn { get { Load(); return checkedOn; } }

        static void Load()
        {
            lock (gate)
            {
                if (File_ == null || !System.IO.File.Exists(File_)) { cache = new List<Dictionary<string, object>>(); return; }
                DateTime w = System.IO.File.GetLastWriteTimeUtc(File_);
                if (w == stamp) return;
                stamp = w;
                List<Dictionary<string, object>> l = new List<Dictionary<string, object>>();
                classes.Clear();
                try
                {
                    JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue;
                    Dictionary<string, object> root = js.DeserializeObject(System.IO.File.ReadAllText(File_, Encoding.UTF8)) as Dictionary<string, object>;
                    note = root.ContainsKey("note") ? Convert.ToString(root["note"]) : ""; checkedOn = root.ContainsKey("checked") ? Convert.ToString(root["checked"]) : "";
                    Dictionary<string, object> cl = root.ContainsKey("classes") ? root["classes"] as Dictionary<string, object> : null;
                    if (cl != null) foreach (KeyValuePair<string, object> kv in cl) { List<string> cars = new List<string>(); foreach (object o in (IList)kv.Value) cars.Add(Convert.ToString(o)); classes[kv.Key] = cars; }
                    foreach (object o in (IList)root["refs"]) { Dictionary<string, object> d = o as Dictionary<string, object>; if (d != null) l.Add(d); }
                }
                catch (Exception ex) { Log.W("pro-refs.json: " + ex.Message); }
                cache = l;
            }
        }

        public static string S(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, CultureInfo.InvariantCulture) : ""; }
        public static double Secs(Dictionary<string, object> d) { object o; double v; return d.TryGetValue("seconds", out o) && o != null && double.TryParse(Convert.ToString(o, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : 0; }

        public static List<Dictionary<string, object>> For(string carPath, string trackName)
        {
            Load();
            List<Dictionary<string, object>> l = new List<Dictionary<string, object>>();
            if (string.IsNullOrEmpty(carPath) || string.IsNullOrEmpty(trackName)) return l;
            lock (gate)
                foreach (Dictionary<string, object> d in cache)
                {
                    if (!string.Equals(S(d, "trackName"), trackName, StringComparison.OrdinalIgnoreCase) || Secs(d) < 15) continue;
                    string cp = S(d, "carPath"), cc = S(d, "carClass");
                    List<string> members;
                    bool car = cp.Length > 0 ? string.Equals(cp, carPath, StringComparison.OrdinalIgnoreCase)
                                             : cc.Length > 0 && classes.TryGetValue(cc, out members) && members.Contains(carPath);
                    if (car) l.Add(d);
                }
            // qualifying before race, then fastest first
            l.Sort(delegate (Dictionary<string, object> a, Dictionary<string, object> b) { return Secs(a).CompareTo(Secs(b)); });
            return l;
        }
    }

    // ---------------- B4: the benchmark card's data ----------------
    static class Bench
    {
        public const int MinField = 30;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // Percentile of an ascending list by straight-line interpolation between the closest ranks (p = 0.05 -> the time 5 % of the drivers beat).
        public static double Percentile(double[] asc, double p)
        {
            int n = asc.Length;
            if (n == 0) return 0;
            if (n == 1) return asc[0];
            double h = (n - 1) * Math.Max(0, Math.Min(1, p)); int lo = (int)Math.Floor(h), hi = Math.Min(n - 1, lo + 1);
            return asc[lo] + (h - lo) * (asc[hi] - asc[lo]);
        }

        sealed class Yard
        {
            public string Id = "", Kind = "", Label = "", Detail = "", Source = "", Url = "", Note = "";
            public double Time; public int N;
        }

        static string N3(double d) { return d.ToString("0.000", Inv); }
        static long Ms(DateTime utc) { return (long)(utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }

        public static string ListJson()
        {
            StringBuilder sb = new StringBuilder("{\"combos\":[");
            bool first = true;
            string lic; int ir = Career.LatestIr(out lic);
            foreach (string[] c in Career.Combos())
            {
                double t; string file; DateTime when;
                if (!Career.BestFor(c[0], c[1], c[2], out t, out file, out when)) continue;
                FieldStats fs = FieldLaps.For(c[0], c[1], c[2], ir);
                string cp, tn; Career.IdsFor(c[0], c[1], c[2], out cp, out tn);
                if (!first) sb.Append(','); first = false;
                sb.Append("{\"car\":").Append(Json_.S(c[0])).Append(",\"track\":").Append(Json_.S(c[1])).Append(",\"config\":").Append(Json_.S(c[2])).Append(",\"pb\":").Append(N3(t))
                  .Append(",\"ts\":").Append(Ms(when)).Append(",\"carPath\":").Append(Json_.S(cp)).Append(",\"trackName\":").Append(Json_.S(tn))
                  .Append(",\"pro\":").Append(ProRefs.For(cp, tn).Count).Append(",\"field\":").Append(fs.N).Append('}');
            }
            sb.Append("],\"minField\":").Append(MinField).Append('}');
            return sb.ToString();
        }

        // Peter's best, then each yardstick with its time, gap, pace and where it comes from; the next goal; the history line.
        public static string Json(string car, string track, string config, bool sample)
        {
            if (sample) return SampleJson();
            car = car ?? ""; track = track ?? ""; config = config ?? "";
            double pb; string pbFile; DateTime pbWhen;
            bool have = Career.BestFor(car, track, config, out pb, out pbFile, out pbWhen);
            bool live = false;
            RefData rd = PbRef.Current;
            if (rd != null && rd.Key == Combo.Key(car, track, config) && (!have || rd.Time < pb - 0.0005)) { pb = rd.Time; pbWhen = rd.SetAt.ToUniversalTime(); pbFile = rd.File; have = true; live = true; }
            if (!have) return "{\"car\":" + Json_.S(car) + ",\"track\":" + Json_.S(track) + ",\"config\":" + Json_.S(config) + ",\"pb\":null,\"yardsticks\":[],\"next\":null,\"history\":[],\"minField\":" + MinField + "}";

            int sessions; double laps, secs; string lastType;
            List<double[]> hist = Career.HistoryFor(car, track, config, out sessions, out laps, out secs, out lastType);
            string lic; int ir = Career.LatestIr(out lic);
            List<Yard> ys = new List<Yard>();

            string carPath, trackName; Career.IdsFor(car, track, config, out carPath, out trackName);
            foreach (Dictionary<string, object> d in ProRefs.For(carPath, trackName))
            {
                Yard y = new Yard();
                string ser = ProRefs.S(d, "short"); if (ser.Length == 0) ser = ProRefs.S(d, "series");
                y.Id = "pro-" + Combo.Slug(ser + "-" + ProRefs.S(d, "year") + "-" + ProRefs.S(d, "kind"));
                y.Kind = "pro"; y.Time = ProRefs.Secs(d);
                y.Label = ser + " · " + ProRefs.S(d, "kind");
                y.Detail = (ProRefs.S(d, "event") + " " + ProRefs.S(d, "year")).Trim() + (ProRefs.S(d, "driver").Length > 0 ? " · " + ProRefs.S(d, "driver") : "");
                y.Source = ProRefs.S(d, "sourceName").Length > 0 ? ProRefs.S(d, "sourceName") : "official timing"; y.Url = ProRefs.S(d, "url");
                y.Note = "Real car, real conditions - a guide only";
                ys.Add(y);
            }

            FieldStats fs = FieldLaps.For(car, track, config, ir);
            if (fs.Enough)
            {
                string basis = "based on " + fs.N + " drivers \u00B7 iRacing";
                ys.Add(new Yard { Id = "top5", Kind = "field", Label = "Top 5% of drivers raced", Time = fs.Top5, N = fs.N, Detail = basis, Source = "sessions with other drivers" });
                ys.Add(new Yard { Id = "top25", Kind = "field", Label = "Top 25% of drivers raced", Time = fs.Top25, N = fs.N, Detail = basis, Source = "sessions with other drivers" });
                ys.Add(new Yard { Id = "median", Kind = "field", Label = "Middle of the drivers raced", Time = fs.Median, N = fs.N, Detail = basis, Source = "sessions with other drivers" });
            }
            if (fs.SimN >= MinField)
                ys.Add(new Yard { Id = "similar", Kind = "field", Label = "Drivers within 250 iRating", Time = fs.SimMedian, N = fs.SimN, Detail = "middle lap of " + fs.SimN + " drivers rated " + (ir - 250) + " to " + (ir + 250) + " \u00B7 iRacing", Source = "sessions with other drivers" });
            ys.Sort(delegate (Yard a, Yard b) { return a.Time.CompareTo(b.Time); });

            StringBuilder sb = new StringBuilder(6000);
            sb.Append("{\"car\":").Append(Json_.S(car)).Append(",\"track\":").Append(Json_.S(track)).Append(",\"config\":").Append(Json_.S(config))
              .Append(",\"carPath\":").Append(Json_.S(carPath)).Append(",\"trackName\":").Append(Json_.S(trackName));
            sb.Append(",\"pb\":{\"time\":").Append(N3(pb)).Append(",\"ts\":").Append(Ms(pbWhen)).Append(",\"live\":").Append(live ? "true" : "false")
              .Append(",\"sessions\":").Append(sessions).Append(",\"laps\":").Append(laps.ToString("0", Inv)).Append(",\"hours\":").Append((secs / 3600).ToString("0.0", Inv))
              .Append(",\"source\":").Append(Json_.S(live ? "this session" : "telemetry")).Append(",\"file\":").Append(Json_.S(pbFile ?? "")).Append('}');
            sb.Append(",\"yardsticks\":[");
            Yard next = null;
            for (int i = 0; i < ys.Count; i++)
            {
                Yard y = ys[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"id\":").Append(Json_.S(y.Id)).Append(",\"kind\":").Append(Json_.S(y.Kind)).Append(",\"label\":").Append(Json_.S(y.Label)).Append(",\"detail\":").Append(Json_.S(y.Detail))
                  .Append(",\"source\":").Append(Json_.S(y.Source)).Append(",\"url\":").Append(Json_.S(y.Url)).Append(",\"note\":").Append(Json_.S(y.Note))
                  .Append(",\"time\":").Append(N3(y.Time)).Append(",\"gap\":").Append(N3(pb - y.Time)).Append(",\"pace\":").Append((pb / y.Time * 100).ToString("0.0", Inv)).Append(",\"n\":").Append(y.N > 0 ? y.N.ToString(Inv) : "null").Append('}');
                if (y.Time < pb - 0.0005) next = y;       // the slowest yardstick that is still ahead of you
            }
            sb.Append("],\"next\":");
            if (next == null) sb.Append("null");
            else sb.Append("{\"id\":").Append(Json_.S(next.Id)).Append(",\"label\":").Append(Json_.S(next.Label)).Append(",\"time\":").Append(N3(next.Time)).Append(",\"gap\":").Append(N3(pb - next.Time)).Append('}');
            sb.Append(",\"ahead\":").Append(ys.Count > 0 && next == null ? "true" : "false");
            sb.Append(",\"field\":{\"n\":").Append(fs.N).Append(",\"needed\":").Append(MinField).Append(",\"enough\":").Append(fs.Enough ? "true" : "false").Append('}');
            sb.Append(",\"proNote\":").Append(Json_.S(ProRefs.Note)).Append(",\"proChecked\":").Append(Json_.S(ProRefs.CheckedOn));
            sb.Append(",\"history\":[");
            // a personal best set in the session being played now is not in the career cache yet: it is the last point of the line
            if (live) hist.Add(new[] { (double)Ms(pbWhen), pb });
            double run = double.MaxValue;
            for (int i = 0; i < hist.Count; i++)
            {
                run = Math.Min(run, hist[i][1]);
                if (i > 0) sb.Append(',');
                sb.Append('[').Append(hist[i][0].ToString("0", Inv)).Append(',').Append(N3(hist[i][1])).Append(',').Append(N3(run)).Append(']');
            }
            sb.Append("],\"minField\":").Append(MinField).Append(",\"sample\":false}");
            return sb.ToString();
        }

        // made-up numbers for the picture test and the demo debrief; the card says SAMPLE
        static string SampleJson()
        {
            return "{\"car\":\"Chevrolet Corvette Z06 GT3.R\",\"track\":\"Road Atlanta\",\"config\":\"Full Course\"," +
                   "\"pb\":{\"time\":84.312,\"ts\":" + Ms(new DateTime(2026, 10, 3, 18, 0, 0, DateTimeKind.Utc)) + ",\"live\":false,\"sessions\":23,\"laps\":412,\"hours\":9.4,\"source\":\"telemetry\",\"file\":\"\"}," +
                   "\"yardsticks\":[" +
                   "{\"id\":\"pro-s1\",\"kind\":\"pro\",\"label\":\"Sample series \\u00B7 qualifying best\",\"detail\":\"Sample event 2025 \\u00B7 Sample Driver\",\"source\":\"sample\",\"url\":\"\",\"note\":\"Real car, real conditions - a guide only\",\"time\":81.806,\"gap\":2.506,\"pace\":103.1,\"n\":null}," +
                   "{\"id\":\"top5\",\"kind\":\"field\",\"label\":\"Top 5% of drivers raced\",\"detail\":\"based on 64 drivers raced \\u00B7 iRacing\",\"source\":\"sample\",\"url\":\"\",\"note\":\"\",\"time\":82.940,\"gap\":1.372,\"pace\":101.7,\"n\":64}," +
                   "{\"id\":\"top25\",\"kind\":\"field\",\"label\":\"Top 25% of drivers raced\",\"detail\":\"based on 64 drivers raced \\u00B7 iRacing\",\"source\":\"sample\",\"url\":\"\",\"note\":\"\",\"time\":83.870,\"gap\":0.442,\"pace\":100.5,\"n\":64}," +
                   "{\"id\":\"median\",\"kind\":\"field\",\"label\":\"Middle of the drivers raced\",\"detail\":\"based on 64 drivers raced \\u00B7 iRacing\",\"source\":\"sample\",\"url\":\"\",\"note\":\"\",\"time\":85.610,\"gap\":-1.298,\"pace\":98.5,\"n\":64}]," +
                   "\"next\":{\"id\":\"top25\",\"label\":\"Top 25% of drivers raced\",\"time\":83.870,\"gap\":0.442},\"ahead\":false," +
                   "\"field\":{\"n\":64,\"needed\":30,\"enough\":true},\"proNote\":\"\",\"proChecked\":\"sample\"," +
                   "\"history\":[[1759500000000,88.9,88.9],[1759600000000,87.4,87.4],[1759700000000,87.9,87.4],[1759800000000,86.1,86.1],[1759900000000,86.5,86.1],[1760000000000,85.2,85.2],[1760100000000,84.9,84.9],[1760200000000,84.312,84.312]],\"minField\":30,\"sample\":true}";
        }
    }
}
