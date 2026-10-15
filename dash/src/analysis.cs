// Lap analysis engines (docs\DESIGN-analysis.md section 7.1-7.5). Offline: reads .ibt files, never the sim.
//   1. Distance: each clean lap resampled to 1 m by LapDistPct x the session's track length.
//   2. Corners from the corner model (names and credit kept) plus 24 equal mini-sectors.
//      S1..Sn from the session YAML's SectorStartPct when it has them, otherwise equal thirds.
//   3. Per corner: time, brake point (brake rises through 10% before the apex), entry speed,
//      minimum speed and where, throttle-on (throttle through 90% after the apex), exit speed 100 m after the apex.
//   4. A cause sentence only when the corner's time differs by at least 0.05 s AND exactly one metric
//      is clearly different (brake >= 5 m, a speed >= 3 km/h, throttle-on >= 10 m) in the part of the
//      corner where that time went, and that metric moved the way the time did (an earlier brake, a
//      lower speed or a later throttle with a loss; the opposite with a gain). The time has to sit in
//      one part (the other part under 0.05 s). Two causes, a split corner, or a number that does not
//      explain the time: no sentence.
//   5. Per car + track: the PB (never the lap itself when it is the reference), the session best,
//      the optimal lap (best mini-sectors joined), consistency (best vs the average of the best 5, and the spread),
//      and a goal line of the form "Next: 1:19.4 - in your best corners (T10a 0.18, T1 0.09)".
// Speed in the file is m/s. Brake and throttle are 0 to 1. Nothing here is drawn on a screen.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static partial class Analysis      // partial: workbench.cs adds the channel endpoint on top of this lap store
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly object gate = new object();
        static readonly Dictionary<string, Sess> cache = new Dictionary<string, Sess>();
        static readonly Dictionary<string, CornerSet> cornerCache = new Dictionary<string, CornerSet>();

        sealed class Pt { public double D, T; public float Spd, Brk, Thr; }

        sealed class Met
        {
            public int N;
            public string Name = "", Official = "", Label = "";
            public double P0, Pa, P1, Time, InTime, OutTime;
            public double BrakeM, Entry, Min, MinM, Pickup, Exit;
            public bool HasBrake, HasEntry, HasMin, HasPickup, HasExit;
        }

        sealed class Diff
        {
            public double DTime, DIn, DOut, DBr, DEn, DMn, DPk, DEx;
            public bool HasBr, HasEn, HasMn, HasPk, HasEx;
            public string Cause = "", Code = "";
        }

        sealed class LapTrace
        {
            public string Path = "", File = "", Car = "", Track = "", Config = "", Skip = "", Sig = "";
            public int Lap, Metres;
            public int RecA, RecB;                    // the lap's records in the file [RecA, RecB): workbench.cs reads any channel from them
            public double T0, Computed;               // line-crossing time and the unpinned lap time (set for full laps)
            public double LengthM, Time, Official, Drift;
            public bool Clean, DriftOk, HasOfficial, Measured;
            // L-1, iRacing's verdict (LapRules): any off-track record in the lap's records, and what its own best-lap channel said just after the line
            public bool OffAny, BestChan;
            public int OffSamples;                    // records of the lap with PlayerTrackSurface 0
            public double BestBefore = -1, BestAfter = -1;      // iRacing's best lap of the session at the end of the lap, and 1.5 to 2.5 s after the line (-1 = none)
            public double[] Tm, Mini, SectorT, SectorAt;
            public float[] Spd, Brk, Thr;
            public string SectorFrom = "";
            public List<Met> Corners = new List<Met>();
            public List<double> Straights = new List<double>();
        }

        sealed class Sess
        {
            public string Path = "", File = "", Car = "", Track = "", Config = "", TrackId = "", TrackName = "", Key = "", Yaml = "";
            public double LengthM;
            public long HeaderTicks;
            public double[] SectorAt;
            public string SectorFrom = "";
            public List<LapTrace> Laps = new List<LapTrace>();
        }

        static string Err(string m) { return "{\"error\":" + Json_.S(m) + "}"; }
        static string Q(Dictionary<string, string> q, string k) { string v; return q != null && q.TryGetValue(k, out v) && v != null ? v : ""; }
        static string Arg(string[] args, string name)
        {
            for (int i = 0; i + 1 < args.Length; i++) if (args[i] == name) return args[i + 1] ?? "";
            return "";
        }
        static string F(double d, string fmt) { return d.ToString(fmt, Inv); }
        static int Sgn(double x) { return x > 1e-9 ? 1 : x < -1e-9 ? -1 : 0; }

        // Conditions belong to the records of this lap, not the latest SDK frame.
        static string Conditions(LapTrace lap)
        {
            string[] names = new string[] { "AirTemp", "TrackTempCrew", "WindVel", "WindDir", "Skies", "TrackWetness" };
            double?[] values = new double?[names.Length];
            TrackMaps.Ibt t = TrackMaps.OpenIbt(lap.Path, true);
            if (t == null) return "{\"airC\":null,\"trackC\":null,\"windMs\":null,\"windDirDeg\":null,\"skies\":null,\"wetness\":null}";
            using (t.fs)
            {
                VarDef[] defs = new VarDef[names.Length];
                for (int i = 0; i < names.Length; i++) defs[i] = V(t, names[i]);
                int a = Math.Max(0, lap.RecA), b = (int)Math.Min(Math.Min(t.records, lap.RecB), (long)a + 400000);
                if (b > a)
                {
                    byte[] buf = new byte[(b - a) * t.bufLen]; t.fs.Position = t.dataOff + (long)a * t.bufLen;
                    int got = 0; while (got < buf.Length) { int n = t.fs.Read(buf, got, buf.Length - got); if (n <= 0) break; got += n; }
                    List<double>[] nums = new List<double>[4]; for (int i = 0; i < 4; i++) nums[i] = new List<double>();
                    Dictionary<int, int> skies = new Dictionary<int, int>(), wet = new Dictionary<int, int>();
                    int count = got / t.bufLen;
                    for (int r = 0; r < count; r++) for (int c = 0; c < defs.Length; c++)
                    {
                        if (defs[c] == null) continue;
                        double v = At(buf, r * t.bufLen, defs[c]); if (double.IsNaN(v) || double.IsInfinity(v)) continue;
                        if (c < 4) nums[c].Add(v);
                        else { Dictionary<int, int> d = c == 4 ? skies : wet; int k = (int)Math.Round(v); int old; d.TryGetValue(k, out old); d[k] = old + 1; }
                    }
                    for (int c = 0; c < 4; c++) if (nums[c].Count > 0) { nums[c].Sort(); int n = nums[c].Count; values[c] = n % 2 == 1 ? nums[c][n / 2] : (nums[c][n / 2 - 1] + nums[c][n / 2]) / 2.0; }
                    values[4] = Mode(skies); values[5] = Mode(wet);
                }
            }
            if (values[3].HasValue) values[3] = values[3].Value * 180.0 / Math.PI;
            return "{\"airC\":" + Nullable(values[0], "0.00") + ",\"trackC\":" + Nullable(values[1], "0.00") + ",\"windMs\":" + Nullable(values[2], "0.00") + ",\"windDirDeg\":" + Nullable(values[3], "0.0") + ",\"skies\":" + Nullable(values[4], "0") + ",\"wetness\":" + Nullable(values[5], "0") + "}";
        }
        static double? Mode(Dictionary<int, int> d) { int best = -1, value = 0; foreach (KeyValuePair<int, int> p in d) if (p.Value > best) { best = p.Value; value = p.Key; } return best < 0 ? (double?)null : value; }
        static string Nullable(double? v, string fmt) { return v.HasValue ? F(v.Value, fmt) : "null"; }

        // ---- one-shot for tests\analysis-test.ps1: no window, no deploy, reads only the folder it is given ----
        public static int Cli(string[] args)
        {
            try
            {
                Process p = Process.GetCurrentProcess();
                p.PriorityClass = ProcessPriorityClass.BelowNormal;
                int cores = Environment.ProcessorCount;
                if (cores > 2)
                {
                    long mask = 0;
                    for (int i = 0; i < 2; i++) mask |= 1L << (cores - 1 - i);   // leave the sim the lower cores
                    p.ProcessorAffinity = (IntPtr)mask;
                }
            }
            catch { }
            if (Array.IndexOf(args, "--career") >= 0) return CareerCli(args);      // the career over a folder of copies (career.cs, tests\career-test.ps1)
            if (Array.IndexOf(args, "--pro") >= 0) return ProCli(args);            // maths channels + CSV / Excel export (protools.cs, tests\pro-tools-test.ps1)
            if (Array.IndexOf(args, "--gain") >= 0) return GainCli(args);          // MOST TO GAIN over a folder of copies (gain.cs, tests\rig-leftovers-test.ps1)
            if (Array.IndexOf(args, "--rigwin") >= 0) return RigWinCli.Run(args);  // the Tuner box and the iRacing UI window finder against stand-in programs (rigwin.cs, same test)
            if (Array.IndexOf(args, "--gpsmap") >= 0) return GpsMapCli(args);      // real GPS maps over a folder of copies (gpsmap.cs, tests\gpsmap-test.ps1)
            string root = Arg(args, "--root"), dir = Arg(args, "--dir"), id = Arg(args, "--id"), lapS = Arg(args, "--lap"), rf = Arg(args, "--ref"), outPath = Arg(args, "--out"), dump = Arg(args, "--dump");
            if (rf.Length == 0) rf = "pb";
            int lap; string json;
            if (root.Length == 0 || dir.Length == 0 || id.Length == 0 || outPath.Length == 0 || !int.TryParse(lapS, NumberStyles.Integer, Inv, out lap))
                json = Err("need --root --dir --id --lap --out");
            else
            {
                Corners.DataRoot = root;
                TrackMaps.MapsDir = Path.Combine(root, @"dash\maps");
                string file = Path.Combine(dir, id);
                if (!File.Exists(file)) json = Err("no such file");
                else if (Array.IndexOf(args, "--channels") >= 0)
                {
                    // --channels --ch Speed,Throttle,...: the workbench's binary reply (tests\workbench-test.ps1), same code as the route
                    int cc; byte[] bb;
                    try { bb = BuildChannels(file, lap, rf, Arg(args, "--ch"), dir, false, out cc, Arg(args, "--laps")); }
                    catch (Exception ex) { bb = Utf8(Err(ex.Message)); cc = 500; }
                    try { File.WriteAllBytes(outPath, bb); } catch { return 1; }
                    return cc == 200 ? 0 : 1;
                }
                else if (Array.IndexOf(args, "--session") >= 0)
                {
                    // --session [--corners]: the Session Review / workbench SPLITS reply (sessionreview.cs) for this file (tests\workbench-test.ps1)
                    try { json = BuildSession(file, dir, false, lap, Array.IndexOf(args, "--corners") >= 0); }
                    catch (Exception ex) { json = Err(ex.Message); }
                }
                else if (Array.IndexOf(args, "--deep") >= 0)
                {
                    // --deep [--ratio 14.5]: the corner deep-dive engines (deepdive.cs). --ratio is a test-only steering ratio, so the
                    // road-wheel understeer maths can be checked on a car that has no ratio in the table.
                    double ratio = 0; double.TryParse(Arg(args, "--ratio"), NumberStyles.Float, Inv, out ratio);
                    int dc;
                    try { json = BuildDeep(file, lap, rf, dir, false, ratio, out dc); }
                    catch (Exception ex) { json = Err(ex.Message); }
                }
                else
                {
                    try { json = Build(file, lap, rf, dir, false, dump); }
                    catch (Exception ex) { json = Err(ex.Message); }
                }
            }
            try { File.WriteAllText(outPath, json, new UTF8Encoding(false)); }
            catch { return 1; }
            return json.StartsWith("{\"error\"", StringComparison.Ordinal) ? 1 : 0;
        }

        public static string Route(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (path == "/analysis/deep") return DeepRoute(q, out code);       // corner deep-dive engines (deepdive.cs)
            if (path == "/analysis/career") return CareerRoute(q, out code);   // one car + track over every session (career.cs, W6c)
            if (path == "/analysis/gain") return GainRoute(q, out code);       // every car + track: PB, theoretical best, gap (gain.cs, MOST TO GAIN)
            if (path == "/analysis/coach") return CoachRoute(q, out code);     // what to fix next, from every clean lap of one session (coach.cs)
            if (path != "/analysis/lap") { code = 404; return Err("not found"); }
            if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
            string id = Q(q, "id"), rf = Q(q, "ref");
            if (rf.Length == 0) rf = "pb";
            int lap;
            if (!int.TryParse(Q(q, "lap"), NumberStyles.Integer, Inv, out lap)) { code = 400; return Err("lap must be a number"); }
            string file = ResolveFile(id);
            if (file == null) { code = 404; return Err("no such lap file"); }
            try { if (Career.OnlineOnly(new FileInfo(file))) { code = 409; return Err("Online-only in OneDrive: run tools\\keep-iracing-local.cmd"); } }
            catch { code = 404; return Err("no such lap file"); }
            ThreadPriority was = Thread.CurrentThread.Priority;
            try
            {
                Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
                string dir = TrackMaps.TelemetryDir;
                if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) dir = Path.GetDirectoryName(file);
                return Build(file, lap, rf, dir, true, null);
            }
            catch (Exception ex) { Log.W("analysis: " + ex.Message); code = 500; return Err("could not read that file"); }
            finally { try { Thread.CurrentThread.Priority = was; } catch { } }
        }

        // A vault moment id, or a plain telemetry file name (never a path: the name is looked up in the folder).
        static string ResolveFile(string id)
        {
            if (string.IsNullOrEmpty(id)) return null;
            if (id.EndsWith(".ibt", StringComparison.OrdinalIgnoreCase)) return IbtLaps.Resolve(id) ?? CrVaultCopy(id, null);   // the Vault's own copy when the original is gone (career.cs)
            return Vault.FileForId(id);
        }

        // ---------------- corners, without asking GitHub ----------------
        static CornerSet LoadCorners(Sess s)
        {
            string key = s.Key;
            lock (gate) { CornerSet hit; if (cornerCache.TryGetValue(key, out hit)) return hit; }
            LovelyEntry e = Corners.FindLovely(s.TrackName, s.Config);
            if (e == null) e = Corners.FindLovely(s.Track, s.Config);
            string root = Corners.DataRoot ?? Program.RootDir;
            string lovely = e == null ? null : Path.Combine(root, @"data\corners\lovely", e.File);
            bool onDisk = lovely != null && File.Exists(lovely);
            bool fresh = onDisk && (DateTime.UtcNow - File.GetLastWriteTimeUtc(lovely)).TotalDays <= 45;
            CornerSet cs;
            // Resolve would fetch a missing or stale Lovely file. Read the disk copy instead, or skip Lovely.
            if (fresh || e == null) cs = Corners.Resolve(s.TrackName.Length > 0 ? s.TrackName : s.Track, s.Config, s.TrackId, key, false);
            else cs = Corners.ParseLovely(File.ReadAllText(lovely, Encoding.UTF8));
            if (cs == null) cs = new CornerSet();
            if (cs.Credit.Length == 0 && cs.Turns.Count > 0 && cs.Source == "lovely") cs.Credit = Corners.LovelyCredit;
            lock (gate) cornerCache[key] = cs;
            return cs;
        }

        static string CarOf(string yaml)
        {
            string me = TrackMaps.YamlValue(yaml, "DriverCarIdx");
            Match block = Regex.Match(yaml ?? "", "- CarIdx: " + Regex.Escape(me) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
            return me.Length > 0 && block.Success ? TrackMaps.YamlValue(block.Groups[1].Value, "CarScreenName") : "";
        }

        static double LengthOf(string yaml)
        {
            Match len = Regex.Match(TrackMaps.YamlValue(yaml, "TrackLength"), @"^([\d.]+)\s*(km|mi)");
            double L;
            if (len.Success && double.TryParse(len.Groups[1].Value, NumberStyles.Float, Inv, out L))
                return L * (len.Groups[2].Value == "mi" ? 1609.344 : 1000);
            return 0;
        }

        // iRacing writes SectorStartPct for each sector (Road Atlanta has four). No list: three equal pieces.
        static double[] SectorsOf(string yaml, out string from)
        {
            List<double> v = new List<double>();
            foreach (Match m in Regex.Matches(yaml ?? "", @"SectorStartPct:\s*([0-9]*\.?[0-9]+)"))
            {
                double x;
                if (!double.TryParse(m.Groups[1].Value, NumberStyles.Float, Inv, out x) || x < 0 || x >= 0.999) continue;
                bool seen = false;
                foreach (double h in v) if (Math.Abs(h - x) < 0.0001) seen = true;
                if (!seen) v.Add(x);
            }
            v.Sort();
            if (v.Count == 0 || v[0] > 0.001) v.Insert(0, 0);
            if (v.Count >= 2) { from = "yaml"; return v.ToArray(); }
            from = "thirds";
            return new double[] { 0, 1.0 / 3.0, 2.0 / 3.0 };
        }

        static string LabelOf(CornerTurn t)
        {
            if (t.Official != null && t.Official.Length > 0) return "T" + t.Official.ToLowerInvariant();
            if (t.Name != null && t.Name.Length > 0) return t.Name;
            return "T" + t.N.ToString(Inv);
        }

        static double Cross(double[] st, float[] pct, int k)
        {
            double p0 = pct[k - 1], p1 = pct[k], span = (1 - p0) + p1, f = span > 1e-6 ? (1 - p0) / span : 1;
            return st[k - 1] + (st[k] - st[k - 1]) * Math.Max(0, Math.Min(1, f));
        }

        static double At(byte[] b, int o, VarDef d)
        {
            if (d == null) return 0;
            int p = o + d.Offset;
            switch (d.Type)
            {
                case 0: case 1: return b[p];
                case 2: case 3: return BitConverter.ToInt32(b, p);
                case 4: return BitConverter.ToSingle(b, p);
                case 5: return BitConverter.ToDouble(b, p);
            }
            return 0;
        }

        static VarDef V(TrackMaps.Ibt t, string name) { VarDef d; return t.vars.TryGetValue(name, out d) ? d : null; }

        // ---------------- read one file ----------------
        static Sess Get(string path)
        {
            FileInfo fi = new FileInfo(path);
            string sig = fi.FullName + "|" + fi.Length + "|" + fi.LastWriteTimeUtc.Ticks;
            lock (gate) { Sess s; if (cache.TryGetValue(sig, out s)) return s; }
            Sess n = Load(path);
            lock (gate)
            {
                cache[sig] = n;
                if (cache.Count > 8)
                {
                    string drop = null;
                    foreach (string k in cache.Keys) if (k != sig) { drop = k; break; }
                    if (drop != null) cache.Remove(drop);
                }
            }
            return n;
        }

        static Sess Load(string path)
        {
            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
            if (t == null) throw new IOException("not a telemetry file");
            using (t.fs)
            {
                Sess s = new Sess();
                s.Path = path; s.File = Path.GetFileName(path); s.Yaml = t.yaml ?? "";
                s.Track = TrackMaps.YamlValue(s.Yaml, "TrackDisplayName");
                s.Config = TrackMaps.YamlValue(s.Yaml, "TrackConfigName");
                s.TrackName = TrackMaps.YamlValue(s.Yaml, "TrackName");
                s.TrackId = TrackMaps.YamlValue(s.Yaml, "TrackID");
                s.Car = CarOf(s.Yaml);
                s.Key = TrackMaps.MakeKey(s.TrackId, s.TrackName);
                s.LengthM = LengthOf(s.Yaml);
                s.SectorAt = SectorsOf(s.Yaml, out s.SectorFrom);
                byte[] hh = new byte[8]; t.fs.Position = 112; t.fs.Read(hh, 0, 8); s.HeaderTicks = BitConverter.ToInt64(hh, 0);
                if (s.LengthM < 200) throw new IOException("the file does not say how long the track is");
                VarDef vSt = V(t, "SessionTime"), vPct = V(t, "LapDistPct"), vLap = V(t, "Lap"), vOn = V(t, "IsOnTrack"), vPit = V(t, "OnPitRoad"), vSurf = V(t, "PlayerTrackSurface"),
                       vSpd = V(t, "Speed"), vThr = V(t, "Throttle"), vBrk = V(t, "Brake"), vLlt = V(t, "LapLastLapTime"), vBest = V(t, "LapBestLapTime");
                if (vSt == null || vPct == null || vLap == null || vOn == null || vSpd == null) throw new IOException("this file has no lap data");
                int n = (int)Math.Min(t.records, 2000000L);
                double[] st = new double[n]; float[] pct = new float[n], spd = new float[n], thr = new float[n], brk = new float[n], llt = new float[n];
                float[] lbt = vBest != null ? new float[n] : null;      // iRacing's own best lap of the session, for the lap rule (laprules: LapRules.Counted)
                int[] lap = new int[n]; byte[] fl = new byte[n];
                int per = Math.Max(1, (4 << 20) / t.bufLen); byte[] buf = new byte[per * t.bufLen];
                t.fs.Position = t.dataOff;
                int i = 0;
                while (i < n)
                {
                    int want = Math.Min(per, n - i), got = 0;
                    while (got < want * t.bufLen) { int r = t.fs.Read(buf, got, want * t.bufLen - got); if (r <= 0) break; got += r; }
                    int recs = got / t.bufLen; if (recs == 0) break;
                    for (int k = 0; k < recs; k++, i++)
                    {
                        int o = k * t.bufLen;
                        st[i] = At(buf, o, vSt); pct[i] = (float)At(buf, o, vPct); lap[i] = (int)At(buf, o, vLap);
                        spd[i] = (float)At(buf, o, vSpd); thr[i] = (float)At(buf, o, vThr); brk[i] = (float)At(buf, o, vBrk); llt[i] = (float)At(buf, o, vLlt);
                        if (lbt != null) lbt[i] = (float)At(buf, o, vBest);
                        int surf = vSurf == null ? 3 : (int)At(buf, o, vSurf);
                        fl[i] = (byte)((At(buf, o, vOn) != 0 ? 1 : 0) | (vPit != null && At(buf, o, vPit) != 0 ? 2 : 0) | (surf == 0 ? 4 : 0));
                    }
                    if (recs < want) break;
                }
                n = i;
                List<int[]> runs = new List<int[]>();
                for (int k = 0; k < n; )
                {
                    if ((fl[k] & 1) == 0) { k++; continue; }
                    int j = k + 1;
                    while (j < n && (fl[j] & 1) != 0 && lap[j] == lap[k] && st[j] - st[j - 1] < 0.5) j++;
                    runs.Add(new int[] { k, j }); k = j;
                }
                for (int r = 0; r < runs.Count; r++)
                {
                    int a = runs[r][0], b = runs[r][1];
                    bool pre = r > 0 && runs[r - 1][1] == a && lap[a - 1] == lap[a] - 1 && pct[a - 1] > 0.8 && pct[a] < 0.2;
                    bool post = r + 1 < runs.Count && runs[r + 1][0] == b && lap[b] == lap[a] + 1 && pct[b - 1] > 0.8 && pct[b] < 0.2;
                    int pit = 0, off = 0, pitHead = 0, pitTail = 0, len = b - a, head = Math.Max(1, len / 5), tail = len - head;
                    for (int x = a; x < b; x++)
                    {
                        if ((fl[x] & 2) != 0) { pit++; if (x - a < head) pitHead++; if (x >= a + tail) pitTail++; }
                        if ((fl[x] & 4) != 0) off++;
                    }
                    string skip = "";
                    bool full = pre && post;
                    if (!full) skip = pitHead > 0 && pitTail == 0 ? "out" : pitTail > 0 && pitHead == 0 ? "in" : pit > 0 ? "pit" : "partial";
                    else if (pit > 0) skip = pitHead > 0 && pitTail == 0 ? "out" : pitTail > 0 && pitHead == 0 ? "in" : "pit";
                    else if (off >= 45) skip = "off";
                    double secs = st[b - 1] - st[a];
                    if (!full && secs < 2) continue;   // a reset blip, not a lap
                    LapTrace lapTr = new LapTrace();
                    lapTr.Path = path; lapTr.File = s.File; lapTr.Car = s.Car; lapTr.Track = s.Track; lapTr.Config = s.Config;
                    lapTr.Lap = lap[a]; lapTr.LengthM = s.LengthM; lapTr.Skip = skip; lapTr.Clean = skip.Length == 0;
                    lapTr.SectorAt = s.SectorAt; lapTr.SectorFrom = s.SectorFrom;
                    lapTr.RecA = a; lapTr.RecB = b;
                    lapTr.OffSamples = off; lapTr.OffAny = off > 0;      // PlayerTrackSurface 0 at any record of the lap (the C-30 rule above needs 45 of them to call the lap not clean)
                    lapTr.BestChan = lbt != null;
                    if (lbt != null) { lapTr.BestBefore = LapRules.BestBefore(lbt, n, b); lapTr.BestAfter = LapRules.BestAfter(lbt, n, b); }
                    if (full)
                    {
                        double t0 = Cross(st, pct, a), t1 = Cross(st, pct, b), computed = t1 - t0;
                        lapTr.T0 = t0; lapTr.Computed = computed;
                        int at = r + 1 < runs.Count ? Math.Min(b + 90, runs[r + 1][1] - 1) : -1;
                        if (at >= 0 && at < n && llt[at] > 1 && Math.Abs(llt[at] - computed) < 0.15) { lapTr.Official = llt[at]; lapTr.HasOfficial = true; }
                        if (computed > 1 && computed < 900) Resample(lapTr, st, pct, spd, brk, thr, a, b, t0, computed);
                        else lapTr.Clean = false;
                        if (lapTr.Clean && (lapTr.Time < 15 || lapTr.Time > 900)) { lapTr.Clean = false; lapTr.Skip = "partial"; }
                    }
                    s.Laps.Add(lapTr);
                }
                return s;
            }
        }

        // 1 m grid. Time is scaled onto the announced lap time when iRacing's figure is within 0.15 s,
        // so the pieces add up to the lap time Peter was shown.
        static void Resample(LapTrace lap, double[] st, float[] pct, float[] spd, float[] brk, float[] thr, int a, int b, double t0, double computed)
        {
            double L = lap.LengthM;
            List<Pt> pts = new List<Pt>();
            if (a > 0 && st[a] - st[a - 1] < 0.5 && pct[a - 1] > 0.5)
            {
                Pt pre = new Pt(); pre.D = pct[a - 1] * L - L; pre.T = st[a - 1] - t0; pre.Spd = spd[a - 1]; pre.Brk = brk[a - 1]; pre.Thr = thr[a - 1];
                pts.Add(pre);
            }
            Pt z = new Pt(); z.D = 0; z.T = 0; z.Spd = spd[a]; z.Brk = brk[a]; z.Thr = thr[a]; pts.Add(z);
            double lastD = 0;
            for (int i = a; i < b; i++)
            {
                double d = pct[i] * L, t = st[i] - t0;
                if (d <= lastD + 0.05 || d > L || t < 0) continue;
                if (pts.Count > 0 && t + 1e-6 < pts[pts.Count - 1].T) continue;
                Pt p = new Pt(); p.D = d; p.T = t; p.Spd = spd[i]; p.Brk = brk[i]; p.Thr = thr[i];
                pts.Add(p); lastD = d;
            }
            if (pts[pts.Count - 1].D < L - 0.01) { Pt end = new Pt(); end.D = L; end.T = computed; end.Spd = spd[b - 1]; end.Brk = brk[b - 1]; end.Thr = thr[b - 1]; pts.Add(end); }
            else { pts[pts.Count - 1].D = L; pts[pts.Count - 1].T = computed; }
            double dist = 0;
            for (int i = 1; i < pts.Count; i++)
            {
                if (pts[i].D < 0 || pts[i - 1].D > L) continue;
                double dt = pts[i].T - pts[i - 1].T;
                if (dt > 0 && dt < 5) dist += 0.5 * (pts[i].Spd + pts[i - 1].Spd) * dt;
            }
            lap.Drift = L > 0 ? (dist - L) / L : 0;
            lap.DriftOk = Math.Abs(lap.Drift) <= 0.005;
            double scale = 1;
            if (lap.HasOfficial && computed > 1) scale = lap.Official / computed;
            lap.Time = computed * scale;
            int m = (int)Math.Round(L);
            if (m < 10) m = 10;
            lap.Metres = m;
            lap.Tm = new double[m]; lap.Spd = new float[m]; lap.Brk = new float[m]; lap.Thr = new float[m];
            for (int i = 0; i < m; i++)
            {
                double d = i < L ? i : L;
                double tt, sp, bk, th; Lerp(pts, d, out tt, out sp, out bk, out th);
                lap.Tm[i] = tt * scale; lap.Spd[i] = (float)sp; lap.Brk[i] = (float)bk; lap.Thr[i] = (float)th;
            }
            lap.Tm[0] = 0;
            for (int i = 1; i < m; i++) if (lap.Tm[i] < lap.Tm[i - 1]) lap.Tm[i] = lap.Tm[i - 1];
            for (int i = 0; i < m; i++) if (lap.Tm[i] > lap.Time) lap.Tm[i] = lap.Time;
            lap.Mini = new double[24];
            for (int i = 0; i < 24; i++) lap.Mini[i] = Span(lap, i / 24.0 * L, (i + 1) / 24.0 * L);
            lap.SectorT = new double[lap.SectorAt.Length];
            for (int i = 0; i < lap.SectorAt.Length; i++)
            {
                double aa = lap.SectorAt[i] * L, bb = (i + 1 < lap.SectorAt.Length ? lap.SectorAt[i + 1] : 1.0) * L;
                lap.SectorT[i] = Span(lap, aa, bb);
            }
            lap.Sig = Sha(Canon(lap));
        }

        static void Lerp(List<Pt> pts, double d, out double t, out double spd, out double brk, out double thr)
        {
            t = 0; spd = 0; brk = 0; thr = 0;
            if (pts.Count == 0) return;
            if (d <= pts[0].D) { t = pts[0].T; spd = pts[0].Spd; brk = pts[0].Brk; thr = pts[0].Thr; return; }
            int last = pts.Count - 1;
            if (d >= pts[last].D) { t = pts[last].T; spd = pts[last].Spd; brk = pts[last].Brk; thr = pts[last].Thr; return; }
            int lo = 0, hi = last;
            while (lo + 1 < hi) { int mid = (lo + hi) >> 1; if (pts[mid].D <= d) lo = mid; else hi = mid; }
            double span = pts[hi].D - pts[lo].D, f = span > 1e-9 ? (d - pts[lo].D) / span : 0;
            t = pts[lo].T + (pts[hi].T - pts[lo].T) * f;
            spd = pts[lo].Spd + (pts[hi].Spd - pts[lo].Spd) * f;
            brk = pts[lo].Brk + (pts[hi].Brk - pts[lo].Brk) * f;
            thr = pts[lo].Thr + (pts[hi].Thr - pts[lo].Thr) * f;
        }

        static double DistNorm(double d, double L)
        {
            if (L <= 1) return 0;
            d %= L; if (d < 0) d += L; return d;
        }

        static double TAt(LapTrace lap, double d)
        {
            if (lap.Metres <= 0) return 0;
            if (d <= 0) return 0;
            if (d >= lap.LengthM) return lap.Time;
            int i = (int)Math.Floor(d);
            if (i >= lap.Metres - 1)
            {
                double d0 = lap.Metres - 1, span = lap.LengthM - d0, f = span > 1e-6 ? (d - d0) / span : 0;
                return lap.Tm[lap.Metres - 1] + (lap.Time - lap.Tm[lap.Metres - 1]) * f;
            }
            if (i < 0) i = 0;
            return lap.Tm[i] + (lap.Tm[i + 1] - lap.Tm[i]) * (d - i);
        }

        static double ChAt(LapTrace lap, float[] ch, double d)
        {
            d = DistNorm(d, lap.LengthM);
            if (lap.Metres <= 1) return ch[0];
            if (d >= lap.Metres - 1) return ch[lap.Metres - 1];
            int i = (int)Math.Floor(d);
            if (i < 0) i = 0;
            if (i >= lap.Metres - 1) return ch[lap.Metres - 1];
            return ch[i] + (ch[i + 1] - ch[i]) * (d - i);
        }

        static double Span(LapTrace lap, double a, double b)
        {
            if (b >= a) return TAt(lap, b) - TAt(lap, a);
            return (lap.Time - TAt(lap, a)) + TAt(lap, b);
        }

        // Shortest signed metres from b to a. Positive: a is further along the lap than b.
        static double DeltaM(double a, double b, double L)
        {
            double d = a - b;
            if (L > 1) { if (d > L / 2) d -= L; if (d < -L / 2) d += L; }
            return d;
        }

        static string Canon(LapTrace lap)
        {
            StringBuilder sb = new StringBuilder(lap.Metres * 28);
            for (int i = 0; i < lap.Metres; i++)
            {
                if (i > 0) sb.Append('\n');
                sb.Append(F(lap.Tm[i], "0.000")).Append(',').Append(lap.Spd[i].ToString("0.00", Inv)).Append(',').Append(lap.Brk[i].ToString("0.000", Inv)).Append(',').Append(lap.Thr[i].ToString("0.000", Inv));
            }
            return sb.ToString();
        }

        static string Sha(string text)
        {
            using (SHA256 sha = SHA256.Create())
            {
                byte[] b = sha.ComputeHash(Encoding.UTF8.GetBytes(text));
                StringBuilder h = new StringBuilder(b.Length * 2);
                for (int i = 0; i < b.Length; i++) h.Append(b[i].ToString("x2"));
                return h.ToString();
            }
        }

        // ---------------- corner metrics on the 1 m grid ----------------
        static void Measure(LapTrace lap, CornerSet cs)
        {
            if (lap.Measured) return;
            lap.Measured = true;
            lap.Corners = new List<Met>();
            lap.Straights = new List<double>();
            if (!lap.Clean || cs == null || cs.Turns == null) return;
            foreach (CornerTurn t in cs.Turns) lap.Corners.Add(MeasureOne(lap, t));
            List<double[]> iv = new List<double[]>();
            foreach (Met m in lap.Corners)
            {
                if (m.P1 >= m.P0) iv.Add(new double[] { m.P0, m.P1 });
                else { iv.Add(new double[] { m.P0, 1 }); iv.Add(new double[] { 0, m.P1 }); }
            }
            iv.Sort(delegate (double[] x, double[] y) { return x[0].CompareTo(y[0]); });
            double cursor = 0;
            foreach (double[] r in iv)
            {
                if (r[0] > cursor + 1e-6) lap.Straights.Add(Span(lap, cursor * lap.LengthM, r[0] * lap.LengthM));
                if (r[1] > cursor) cursor = r[1];
            }
            if (cursor < 1 - 1e-6) lap.Straights.Add(Span(lap, cursor * lap.LengthM, lap.LengthM));
        }

        static Met MeasureOne(LapTrace lap, CornerTurn t)
        {
            double L = lap.LengthM;
            Met m = new Met();
            m.N = t.N; m.Name = t.Name ?? ""; m.Official = t.Official ?? ""; m.Label = LabelOf(t);
            m.P0 = t.P0; m.Pa = t.Pa; m.P1 = t.P1;
            double d0 = t.P0 * L, da = DistNorm(t.Pa * L, L), d1 = t.P1 * L;
            m.Time = Span(lap, d0, d1);
            m.InTime = Span(lap, d0, da);
            m.OutTime = Span(lap, da, d1);
            m.Entry = ChAt(lap, lap.Spd, d0) * 3.6; m.HasEntry = true;
            m.Exit = ChAt(lap, lap.Spd, da + 100) * 3.6; m.HasExit = true;
            double best = 0, at = d0; bool any = false;
            double end = d1 >= d0 ? d1 : d1 + L;
            for (double x = d0; x <= end + 0.1; x += 1)
            {
                double step = x > end ? end : x;
                double dd = step >= L ? step - L : step;
                double s = ChAt(lap, lap.Spd, dd);
                if (!any || s < best) { best = s; at = dd; any = true; }
                if (step >= end) break;
            }
            m.HasMin = any; m.Min = best * 3.6; m.MinM = at;
            // The braking point is the start of the last application that reaches the apex,
            // not an earlier tap. Search the 250 m before the apex, and 80 m further if already on the brakes.
            bool found = false; double brakeAt = 0;
            bool prev = ChAt(lap, lap.Brk, da - 250) > 0.10;
            if (prev)
            {
                found = true; brakeAt = DistNorm(da - 250, L);
                for (int k = 1; k <= 80; k++)
                {
                    double x = DistNorm(da - 250 - k, L);
                    if (ChAt(lap, lap.Brk, x) <= 0.10) { brakeAt = DistNorm(da - 250 - k + 1, L); break; }
                    brakeAt = x;
                }
            }
            for (int step = 1; step <= 250; step++)
            {
                double x = DistNorm(da - 250 + step, L);
                bool on = ChAt(lap, lap.Brk, x) > 0.10;
                if (on && !prev) { found = true; brakeAt = x; }
                prev = on;
            }
            m.HasBrake = found; if (found) m.BrakeM = brakeAt;
            for (int k = 1; k <= 200; k++)
            {
                double x = DistNorm(da + k, L);
                if (ChAt(lap, lap.Thr, x) > 0.90) { m.HasPickup = true; m.Pickup = x; break; }
            }
            return m;
        }

        // ---------------- reference, optimal, goal ----------------
        static bool SameLap(LapTrace a, LapTrace b) { return a != null && b != null && a.Lap == b.Lap && string.Equals(a.Path, b.Path, StringComparison.OrdinalIgnoreCase); }

        static bool Better(LapTrace a, LapTrace b)
        {
            if (a.Time < b.Time - 1e-6) return true;
            if (b.Time < a.Time - 1e-6) return false;
            int c = string.Compare(a.File, b.File, StringComparison.OrdinalIgnoreCase);
            if (c != 0) return c < 0;
            return a.Lap < b.Lap;
        }

        // L-1: a lap iRacing timed (it announced LapLastLapTime for it) that is a whole lap through the track: not the pits, not a part lap. A long off-track (our C-30 skip "off", 45
        // records or more) does NOT keep a lap out of here: whether such a lap counts is iRacing's to say (it counts them in practice sessions, not in the AI races) ...
        static bool Timed(LapTrace lap) { return lap != null && (lap.Clean || lap.Skip == "off") && lap.Tm != null && lap.HasOfficial; }

        // ... and one iRacing COUNTED, decided by its own best lap first and by the off-track record only where that says nothing (LapRules.Judge).
        // The one place that decides what counts: Session Review, SPLITS, the career, the PB reference, the Vault's PB, the Sessions page's best.
        static bool Counted(LapTrace lap) { string why; return Timed(lap) && LapRules.Judge(true, lap.OffAny, lap.BestChan, lap.BestBefore, lap.BestAfter, lap.Time, out why); }
        static string CountedBy(LapTrace lap) { string why = "iRacing gave the lap no time"; if (Timed(lap)) LapRules.Judge(true, lap.OffAny, lap.BestChan, lap.BestBefore, lap.BestAfter, lap.Time, out why); return why; }

        // The pool the references and the statistics are counted from (the PB, the session best, the optimal lap, the best-5 average):
        // laps iRacing counted. A lap it did not count is still real data and can be asked for by name (FindRef's "file:lap"), it just never becomes "the best".
        // L-1b (lead): a lap whose sectors may be JOINED (the optimal / theoretical best, the best-sector rows): counted by iRacing AND no off-track record at all (and not skip "off").
        // Sectors driven across the grass are real times but meaningless in a joined lap. Everything that is a best lap or a count stays on iRacing's verdict (Counted).
        static bool Pure(LapTrace lap) { return Counted(lap) && lap.Skip != "off" && !lap.OffAny; }
        static List<LapTrace> PureOf(List<LapTrace> laps) { List<LapTrace> r = new List<LapTrace>(); foreach (LapTrace l in laps) if (Pure(l)) r.Add(l); return r; }

        static List<LapTrace> CleanOf(List<Sess> sessions)
        {
            List<LapTrace> all = new List<LapTrace>();
            foreach (Sess s in sessions) foreach (LapTrace lap in s.Laps) if (Counted(lap)) all.Add(lap);
            all.Sort(delegate (LapTrace a, LapTrace b) { int c = a.Time.CompareTo(b.Time); return c != 0 ? c : a.Lap.CompareTo(b.Lap); });
            return all;
        }

        static LapTrace Fastest(List<LapTrace> laps, string pathOrNull, LapTrace notThis)
        {
            LapTrace best = null;
            foreach (LapTrace lap in laps)
            {
                if (pathOrNull != null && !string.Equals(lap.Path, pathOrNull, StringComparison.OrdinalIgnoreCase)) continue;
                if (SameLap(lap, notThis)) continue;
                if (best == null || Better(lap, best)) best = lap;
            }
            return best;
        }

        static LapTrace BuildOptimal(List<LapTrace> laps, LapTrace like, CornerSet cs)
        {
            LapTrace o = new LapTrace();
            o.Path = ""; o.File = ""; o.Lap = 0; o.Car = like.Car; o.Track = like.Track; o.Config = like.Config;
            o.LengthM = like.LengthM; o.Metres = like.Metres; o.Clean = true; o.SectorFrom = like.SectorFrom; o.SectorAt = like.SectorAt;
            o.Tm = new double[like.Metres]; o.Spd = new float[like.Metres]; o.Brk = new float[like.Metres]; o.Thr = new float[like.Metres];
            LapTrace[] srcs = new LapTrace[24];
            double[] bestT = new double[24];
            for (int s = 0; s < 24; s++)
            {
                bestT[s] = double.MaxValue;
                foreach (LapTrace lap in laps)
                {
                    if (lap.Mini == null || lap.Mini.Length != 24 || Math.Abs(lap.LengthM - like.LengthM) > 1) continue;
                    double tm = lap.Mini[s];
                    bool take = srcs[s] == null || tm < bestT[s] - 1e-9 || (Math.Abs(tm - bestT[s]) <= 1e-9 && Better(lap, srcs[s]));
                    if (take) { bestT[s] = tm; srcs[s] = lap; }
                }
                if (srcs[s] == null) { srcs[s] = like; bestT[s] = like.Mini[s]; }
            }
            double[] acc = new double[25];
            for (int s = 0; s < 24; s++) acc[s + 1] = acc[s] + bestT[s];
            for (int i = 0; i < o.Metres; i++)
            {
                int s = (int)(i / o.LengthM * 24.0);
                if (s < 0) s = 0; if (s > 23) s = 23;
                LapTrace src = srcs[s];
                double a0 = s / 24.0 * o.LengthM;
                double dt = TAt(src, i) - TAt(src, a0);
                if (dt < 0) dt = 0;
                if (dt > bestT[s]) dt = bestT[s];
                o.Tm[i] = acc[s] + dt;
                int j = i < src.Metres ? i : src.Metres - 1;
                o.Spd[i] = src.Spd[j]; o.Brk[i] = src.Brk[j]; o.Thr[i] = src.Thr[j];
            }
            o.Time = acc[24];
            for (int i = 1; i < o.Metres; i++) if (o.Tm[i] < o.Tm[i - 1]) o.Tm[i] = o.Tm[i - 1];
            o.Mini = new double[24];
            for (int s = 0; s < 24; s++) o.Mini[s] = bestT[s];
            Measure(o, cs);
            return o;
        }

        static string Clock1(double sec)
        {
            if (sec < 0 || double.IsNaN(sec) || double.IsInfinity(sec)) sec = 0;
            int tenths = (int)Math.Floor(sec * 10.0 + 0.5);
            int mins = tenths / 600, rem = tenths % 600;
            return mins.ToString(Inv) + ":" + (rem / 10).ToString("00", Inv) + "." + (rem % 10).ToString(Inv);
        }

        // The time left in the PB's slowest corners, against the best each corner has been driven.
        static string GoalOf(LapTrace pb, List<LapTrace> laps)
        {
            if (pb == null || pb.Corners.Count == 0) return "";
            int n = pb.Corners.Count;
            double[] best = new double[n];
            for (int i = 0; i < n; i++) best[i] = double.MaxValue;
            foreach (LapTrace lap in laps)
            {
                if (lap.Corners.Count != n) continue;
                for (int i = 0; i < n; i++) if (lap.Corners[i].Time < best[i]) best[i] = lap.Corners[i].Time;
            }
            List<int> idx = new List<int>();
            List<double> gap = new List<double>();
            for (int i = 0; i < n; i++)
            {
                double g = pb.Corners[i].Time - best[i];
                if (g >= 0.05) { idx.Add(i); gap.Add(g); }
            }
            for (int i = 0; i < idx.Count; i++)
                for (int j = i + 1; j < idx.Count; j++)
                    if (gap[j] > gap[i]) { double tg = gap[i]; gap[i] = gap[j]; gap[j] = tg; int ti = idx[i]; idx[i] = idx[j]; idx[j] = ti; }
            int take = idx.Count < 3 ? idx.Count : 3;
            double sum = 0;
            for (int i = 0; i < take; i++) sum += gap[i];
            StringBuilder sb = new StringBuilder();
            sb.Append("Next: ").Append(Clock1(pb.Time - sum)).Append(" in best corners");
            if (take > 0)
            {
                sb.Append(" (");
                for (int i = 0; i < take; i++) { if (i > 0) sb.Append(", "); sb.Append(pb.Corners[idx[i]].Label).Append(' ').Append(gap[i].ToString("0.00", Inv)); }
                sb.Append(')');
            }
            return sb.ToString();
        }

        static Diff CompareMet(Met a, Met b, double L)
        {
            Diff d = new Diff();
            d.DTime = a.Time - b.Time; d.DIn = a.InTime - b.InTime; d.DOut = a.OutTime - b.OutTime;
            d.HasEn = a.HasEntry && b.HasEntry; if (d.HasEn) d.DEn = a.Entry - b.Entry;
            d.HasEx = a.HasExit && b.HasExit; if (d.HasEx) d.DEx = a.Exit - b.Exit;
            d.HasMn = a.HasMin && b.HasMin; if (d.HasMn) d.DMn = a.Min - b.Min;
            d.HasBr = a.HasBrake && b.HasBrake; if (d.HasBr) d.DBr = DeltaM(a.BrakeM, b.BrakeM, L);
            d.HasPk = a.HasPickup && b.HasPickup; if (d.HasPk) d.DPk = DeltaM(a.Pickup, b.Pickup, L);
            int sTime = Sgn(d.DTime);
            bool inBig = Math.Abs(d.DIn) >= 0.05 && Sgn(d.DIn) == sTime;
            bool outBig = Math.Abs(d.DOut) >= 0.05 && Sgn(d.DOut) == sTime;
            // Both parts moved: the time did not sit in one place, so there is nothing to say.
            bool inHolds = inBig && !outBig;
            bool outHolds = outBig && !inBig;
            // Positive: the slowest point is before the apex. Within 8 m it is the apex itself, so it
            // is not blamed on the entry or the exit.
            double before = DeltaM(a.Pa * L, a.MinM, L);
            string minPart = before >= 8 ? "in" : before <= -8 ? "out" : "";
            List<string> hits = new List<string>();
            if (inHolds)
            {
                if (d.HasBr && Math.Abs(d.DBr) >= 5) hits.Add("brake");
                if (d.HasEn && Math.Abs(d.DEn) >= 3) hits.Add("entry");
                if (minPart == "in" && d.HasMn && Math.Abs(d.DMn) >= 3) hits.Add("min");
            }
            if (outHolds)
            {
                if (d.HasPk && Math.Abs(d.DPk) >= 10) hits.Add("pickup");
                if (d.HasEx && Math.Abs(d.DEx) >= 3) hits.Add("exit");
                if (minPart == "out" && d.HasMn && Math.Abs(d.DMn) >= 3) hits.Add("min");
            }
            if (Math.Abs(d.DTime) < 0.05) d.Code = "small";
            else if (!inHolds && !outHolds) d.Code = "split";
            else if (hits.Count == 0) d.Code = "none";
            else if (hits.Count > 1) d.Code = "ambiguous";
            else if (!Explains(hits[0], d)) d.Code = "none";
            else
            {
                d.Code = hits[0];
                bool onTheWayIn = hits[0] == "brake" || hits[0] == "entry" || (hits[0] == "min" && minPart == "in");
                d.Cause = Sentence(hits[0], d, onTheWayIn ? d.DIn : d.DOut, onTheWayIn);
            }
            return d;
        }

        // Earlier braking, a lower speed, or a later throttle explains a loss. The opposite explains a gain.
        static bool Explains(string code, Diff d)
        {
            int t = Sgn(d.DTime);
            if (t == 0) return false;
            if (code == "pickup") return Sgn(d.DPk) == t;
            if (code == "brake") return Sgn(d.DBr) == -t;
            if (code == "entry") return Sgn(d.DEn) == -t;
            if (code == "min") return Sgn(d.DMn) == -t;
            if (code == "exit") return Sgn(d.DEx) == -t;
            return false;
        }

        static string Metres(double m) { return ((int)Math.Floor(Math.Abs(m) + 0.5)).ToString(Inv); }
        static string Kmh(double k) { return ((int)Math.Floor(Math.Abs(k) + 0.5)).ToString(Inv); }

        static string Sentence(string code, Diff d, double part, bool onTheWayIn)
        {
            string way = part > 0 ? "lost" : "gained";
            string sec = Math.Abs(part).ToString("0.00", Inv);
            string where = onTheWayIn ? "on the way in." : "on the way out.";
            if (code == "brake") return "Braked " + Metres(d.DBr) + " m " + (d.DBr > 0 ? "later" : "earlier") + " and " + way + " " + sec + " s " + where;
            if (code == "entry") return "Entry speed " + Kmh(d.DEn) + " km/h " + (d.DEn > 0 ? "higher" : "lower") + " and " + way + " " + sec + " s " + where;
            if (code == "min") return "Minimum speed " + Kmh(d.DMn) + " km/h " + (d.DMn > 0 ? "higher" : "lower") + " and " + way + " " + sec + " s " + where;
            if (code == "pickup") return "Throttle " + Metres(d.DPk) + " m " + (d.DPk > 0 ? "later" : "earlier") + " and " + way + " " + sec + " s " + where;
            if (code == "exit") return "Exit speed " + Kmh(d.DEx) + " km/h " + (d.DEx > 0 ? "higher" : "lower") + " and " + way + " " + sec + " s " + where;
            return "";
        }

        static Met ByN(List<Met> list, int n) { foreach (Met m in list) if (m.N == n) return m; return null; }

        static bool HeaderMatch(string path, string car, string track, string config, out long ticks, out long size)
        {
            ticks = 0; size = 0;
            try
            {
                FileInfo fi = new FileInfo(path); size = fi.Length;
                TrackMaps.Ibt t = TrackMaps.OpenIbt(path, false);
                if (t == null) return false;
                using (t.fs)
                {
                    byte[] h = new byte[8]; t.fs.Position = 112; t.fs.Read(h, 0, 8); ticks = BitConverter.ToInt64(h, 0);
                    string yaml = t.yaml ?? "";
                    return CarOf(yaml) == car && TrackMaps.YamlValue(yaml, "TrackDisplayName") == track && TrackMaps.YamlValue(yaml, "TrackConfigName") == config;
                }
            }
            catch { return false; }
        }

        static List<Sess> Gather(string mainPath, string dir, bool liveRules)
        {
            Sess main = Get(mainPath);
            List<Sess> list = new List<Sess>();
            list.Add(main);
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return list;
            string[] all = Directory.GetFiles(dir, "*.ibt");
            Array.Sort(all, delegate (string a, string b) { return File.GetLastWriteTimeUtc(b).CompareTo(File.GetLastWriteTimeUtc(a)); });
            string newest = null; DateTime nt = DateTime.MinValue;
            foreach (string f in all) { DateTime w = File.GetLastWriteTime(f); if (newest == null || w > nt) { newest = f; nt = w; } }
            bool sim = liveRules && (Program.IsDriving || Process.GetProcessesByName("iRacingSim64DX11").Length > 0);
            int extra = 0;
            foreach (string f in all)
            {
                if (extra >= 40) break;
                string full = Path.GetFullPath(f);
                if (string.Equals(full, Path.GetFullPath(mainPath), StringComparison.OrdinalIgnoreCase)) continue;
                FileInfo fi = new FileInfo(f);
                if (Career.OnlineOnly(fi)) continue;
                if (liveRules && fi.LastWriteTime > DateTime.Now.AddMinutes(-2)) continue;
                if (sim && newest != null && string.Equals(full, Path.GetFullPath(newest), StringComparison.OrdinalIgnoreCase)) continue;
                long ticks, size;
                if (!HeaderMatch(f, main.Car, main.Track, main.Config, out ticks, out size)) continue;
                if (ticks == main.HeaderTicks && size == new FileInfo(mainPath).Length) continue;
                list.Add(Get(f));
                extra++;
            }
            return list;
        }

        static LapTrace FindRef(List<LapTrace> clean, LapTrace me, string spec, List<Sess> sessions, CornerSet cs, out string kind, out LapTrace optimal)
        {
            kind = spec; optimal = null;
            if (spec == "optimal") { List<LapTrace> pure = PureOf(clean); optimal = pure.Count > 0 ? BuildOptimal(pure, me, cs) : null; kind = "optimal"; return optimal; }      // joined only from laps with no off-track record; none = no optimal
            if (spec == "session") { kind = "session"; return Fastest(clean, me.Path, me); }
            if (spec == "pb" || spec.Length == 0) { kind = "pb"; return Fastest(clean, null, me); }
            int colon = spec.LastIndexOf(':');
            int n;
            if (colon > 0 && int.TryParse(spec.Substring(colon + 1), NumberStyles.Integer, Inv, out n))
            {
                string id = spec.Substring(0, colon);
                kind = "lap";
                foreach (LapTrace lap in clean)
                    if (lap.Lap == n && (string.Equals(lap.File, id, StringComparison.OrdinalIgnoreCase) || string.Equals(Path.GetFileName(lap.Path), id, StringComparison.OrdinalIgnoreCase)))
                        return lap;
                foreach (Sess s in sessions)
                    foreach (LapTrace lap in s.Laps)
                        if (lap.Lap == n && lap.Clean && (string.Equals(lap.File, id, StringComparison.OrdinalIgnoreCase)))
                            return lap;
            }
            kind = "lap";
            return null;
        }

        static string NZ(bool has, double v, string fmt) { return has ? F(v, fmt) : "null"; }

        static void AppendMet(StringBuilder sb, Met m, Diff d, bool hasRef)
        {
            sb.Append("{\"n\":").Append(m.N).Append(",\"name\":").Append(Json_.S(m.Name)).Append(",\"official\":").Append(Json_.S(m.Official)).Append(",\"label\":").Append(Json_.S(m.Label));
            sb.Append(",\"p0\":").Append(F(m.P0, "0.0000")).Append(",\"pa\":").Append(F(m.Pa, "0.0000")).Append(",\"p1\":").Append(F(m.P1, "0.0000"));
            sb.Append(",\"time\":").Append(F(m.Time, "0.000")).Append(",\"in\":").Append(F(m.InTime, "0.000")).Append(",\"out\":").Append(F(m.OutTime, "0.000"));
            sb.Append(",\"brakeM\":").Append(NZ(m.HasBrake, m.BrakeM, "0.0")).Append(",\"entryKmh\":").Append(F(m.Entry, "0.00")).Append(",\"minKmh\":").Append(F(m.Min, "0.00")).Append(",\"minM\":").Append(F(m.MinM, "0.0"));
            sb.Append(",\"pickupM\":").Append(NZ(m.HasPickup, m.Pickup, "0.0")).Append(",\"exitKmh\":").Append(F(m.Exit, "0.00"));
            if (!hasRef) { sb.Append(",\"dTime\":null,\"dIn\":null,\"dOut\":null,\"dBrakeM\":null,\"dEntryKmh\":null,\"dMinKmh\":null,\"dPickupM\":null,\"dExitKmh\":null,\"cause\":").Append(Json_.S("")).Append(",\"causeCode\":\"\"}"); return; }
            sb.Append(",\"dTime\":").Append(F(d.DTime, "0.000")).Append(",\"dIn\":").Append(F(d.DIn, "0.000")).Append(",\"dOut\":").Append(F(d.DOut, "0.000"));
            sb.Append(",\"dBrakeM\":").Append(NZ(d.HasBr, d.DBr, "0.00")).Append(",\"dEntryKmh\":").Append(NZ(d.HasEn, d.DEn, "0.00"));
            sb.Append(",\"dMinKmh\":").Append(NZ(d.HasMn, d.DMn, "0.00")).Append(",\"dPickupM\":").Append(NZ(d.HasPk, d.DPk, "0.00")).Append(",\"dExitKmh\":").Append(NZ(d.HasEx, d.DEx, "0.00"));
            sb.Append(",\"cause\":").Append(Json_.S(d.Cause)).Append(",\"causeCode\":").Append(Json_.S(d.Code)).Append('}');
        }

        static string LapBrief(LapTrace lap)
        {
            if (lap == null) return "null";
            return "{\"file\":" + Json_.S(lap.File) + ",\"lap\":" + lap.Lap + ",\"time\":" + F(lap.Time, "0.000") + "}";
        }

        static string Build(string file, int lapNo, string spec, string dir, bool liveRules, string dump)
        {
            List<Sess> sessions = Gather(file, dir, liveRules);
            Sess mine = sessions[0];
            CornerSet cs = LoadCorners(mine);
            foreach (Sess s in sessions) foreach (LapTrace lap in s.Laps) if (lap.Clean) Measure(lap, cs);
            LapTrace me = null;
            foreach (LapTrace lap in mine.Laps) if (lap.Lap == lapNo && (me == null || lap.Clean)) me = lap;
            if (me == null) return Err("no such lap in this file");
            if (dump != null && dump.Length > 0 && me.Clean) File.WriteAllText(dump, Canon(me), new UTF8Encoding(false));
            List<LapTrace> clean = CleanOf(sessions);
            string kind = spec;
            LapTrace optimal = null;
            LapTrace rf = me.Clean ? FindRef(clean, me, spec, sessions, cs, out kind, out optimal) : null;
            if (rf != null && rf != me && !rf.Measured) Measure(rf, cs);
            LapTrace pb = Fastest(clean, null, null);
            LapTrace sessionBest = Fastest(clean, me.Path, null);
            List<LapTrace> pure = PureOf(clean);      // the laps whose sectors are joined (optimal, sector / third / mini bests, the goal): counted and no off-track record at all
            if (optimal == null && pure.Count > 0) optimal = BuildOptimal(pure, me.Clean && Pure(me) ? me : pure[0], cs);
            int n5 = clean.Count < 5 ? clean.Count : 5;
            double sum5 = 0, worst = n5 > 0 ? clean[0].Time : 0, bestT = n5 > 0 ? clean[0].Time : 0;
            for (int i = 0; i < n5; i++) { sum5 += clean[i].Time; if (clean[i].Time > worst) worst = clean[i].Time; }
            double avg5 = n5 > 0 ? sum5 / n5 : 0, spread = n5 > 0 ? worst - bestT : 0;
            string goal = GoalOf(pb, pure);
            // thirdBest is three equal pieces: the figure the lead checks (Road Atlanta, 79.269).
            // sectorBest uses the session's own splits. miniMin is the quickest 24th, so a wrapped
            // start/finish cannot hide inside the optimal lap.
            int ns = me.SectorAt != null ? me.SectorAt.Length : 0;
            double[] secBest = new double[ns];
            for (int i = 0; i < ns; i++) secBest[i] = double.MaxValue;
            double t0b = double.MaxValue, t1b = double.MaxValue, t2b = double.MaxValue, miniMin = double.MaxValue;
            foreach (LapTrace lap in pure)
            {
                if (lap.SectorT != null && lap.SectorT.Length == ns)
                    for (int i = 0; i < ns; i++) if (lap.SectorT[i] < secBest[i]) secBest[i] = lap.SectorT[i];
                double Ls = lap.LengthM;
                double u0 = Span(lap, 0, Ls / 3.0), u1 = Span(lap, Ls / 3.0, 2 * Ls / 3.0), u2 = Span(lap, 2 * Ls / 3.0, Ls);
                if (u0 < t0b) t0b = u0; if (u1 < t1b) t1b = u1; if (u2 < t2b) t2b = u2;
                if (lap.Mini != null) for (int i = 0; i < lap.Mini.Length; i++) if (lap.Mini[i] < miniMin) miniMin = lap.Mini[i];
            }
            double sectorBestSum = 0;
            bool haveSecBest = ns > 0 && pure.Count > 0;
            for (int i = 0; i < ns; i++) { if (secBest[i] < 1e8) sectorBestSum += secBest[i]; else haveSecBest = false; }
            double thirdBestSum = (t0b < 1e8 ? t0b : 0) + (t1b < 1e8 ? t1b : 0) + (t2b < 1e8 ? t2b : 0);
            int files = 0;
            foreach (Sess s in sessions) { bool any = false; foreach (LapTrace lap in s.Laps) if (lap.Clean) any = true; if (any) files++; }

            StringBuilder sb = new StringBuilder(8000);
            sb.Append("{\"file\":").Append(Json_.S(me.File)).Append(",\"lap\":").Append(me.Lap).Append(",\"car\":").Append(Json_.S(me.Car)).Append(",\"track\":").Append(Json_.S(me.Track)).Append(",\"config\":").Append(Json_.S(me.Config));
            sb.Append(",\"lengthM\":").Append(F(me.LengthM, "0.0")).Append(",\"clean\":").Append(me.Clean ? "true" : "false").Append(",\"skip\":").Append(Json_.S(me.Skip));
            sb.Append(",\"time\":").Append(me.Tm != null ? F(me.Time, "0.000") : "null").Append(",\"official\":").Append(me.HasOfficial ? F(me.Official, "0.000") : "null");
            sb.Append(",\"metres\":").Append(me.Metres).Append(",\"sig\":").Append(Json_.S(me.Sig ?? ""));
            sb.Append(",\"conditions\":").Append(Conditions(me));
            sb.Append(",\"drift\":").Append(me.Tm != null ? F(me.Drift, "0.0000") : "null").Append(",\"driftOk\":").Append(me.Tm != null && me.DriftOk ? "true" : "false");
            sb.Append(",\"credit\":").Append(Json_.S(cs != null ? cs.Credit : ""));
            sb.Append(",\"sectorFrom\":").Append(Json_.S(me.SectorFrom)).Append(",\"sectorAt\":[");
            if (me.SectorAt != null) for (int i = 0; i < me.SectorAt.Length; i++) { if (i > 0) sb.Append(','); sb.Append(F(me.SectorAt[i], "0.000000")); }
            sb.Append("],\"sectors\":[");
            if (me.SectorT != null) for (int i = 0; i < me.SectorT.Length; i++) { if (i > 0) sb.Append(','); sb.Append(F(me.SectorT[i], "0.000")); }
            sb.Append("],\"mini\":[");
            if (me.Mini != null) for (int i = 0; i < me.Mini.Length; i++) { if (i > 0) sb.Append(','); sb.Append(F(me.Mini[i], "0.000")); }
            sb.Append("],\"straights\":[");
            for (int i = 0; i < me.Straights.Count; i++) { if (i > 0) sb.Append(','); sb.Append(F(me.Straights[i], "0.000")); }
            sb.Append("],\"probe\":[");
            if (me.Clean && me.Metres > 0)
            {
                int[] at = new int[] { 0, Math.Min(1000, me.Metres - 1), me.Metres / 2, me.Metres - 1 };
                bool first = true;
                foreach (int i in at)
                {
                    if (!first) sb.Append(','); first = false;
                    sb.Append("{\"m\":").Append(i).Append(",\"t\":").Append(F(me.Tm[i], "0.000")).Append(",\"kmh\":").Append(F(me.Spd[i] * 3.6, "0.00")).Append(",\"brk\":").Append(F(me.Brk[i], "0.000")).Append(",\"thr\":").Append(F(me.Thr[i], "0.000")).Append('}');
                }
            }
            sb.Append("],\"corners\":[");
            bool anyC = false;
            foreach (Met m in me.Corners)
            {
                if (anyC) sb.Append(','); anyC = true;
                Diff d = null; bool has = false;
                if (rf != null)
                {
                    Met o = ByN(rf.Corners, m.N);
                    if (o != null) { d = CompareMet(m, o, me.LengthM); has = true; }
                }
                if (!has) d = new Diff();
                AppendMet(sb, m, d, has);
            }
            sb.Append("],\"ref\":");
            if (rf == null) sb.Append("null,\"gap\":null");
            else
            {
                sb.Append("{\"kind\":").Append(Json_.S(kind)).Append(",\"file\":").Append(Json_.S(rf.File)).Append(",\"lap\":").Append(rf.Lap).Append(",\"time\":").Append(F(rf.Time, "0.000"));
                sb.Append(",\"same\":").Append(SameLap(rf, me) ? "true" : "false").Append("},\"gap\":").Append(F(me.Time - rf.Time, "0.000"));
            }
            sb.Append(",\"laps\":[");
            for (int i = 0; i < mine.Laps.Count; i++)
            {
                LapTrace lap = mine.Laps[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(lap.Lap).Append(",\"time\":").Append(lap.Tm != null ? F(lap.Time, "0.000") : "null").Append(",\"official\":").Append(lap.HasOfficial ? F(lap.Official, "0.000") : "null");
                sb.Append(",\"clean\":").Append(lap.Clean ? "true" : "false").Append(",\"skip\":").Append(Json_.S(lap.Skip)).Append('}');
            }
            sb.Append("],\"store\":{\"car\":").Append(Json_.S(mine.Car)).Append(",\"track\":").Append(Json_.S(mine.Track)).Append(",\"config\":").Append(Json_.S(mine.Config));
            sb.Append(",\"files\":").Append(files).Append(",\"cleanLaps\":").Append(clean.Count);
            sb.Append(",\"pb\":").Append(LapBrief(pb)).Append(",\"sessionBest\":").Append(LapBrief(sessionBest));
            sb.Append(",\"optimal\":").Append(optimal != null ? F(optimal.Time, "0.000") : "null");
            sb.Append(",\"sectorBest\":").Append(haveSecBest ? F(sectorBestSum, "0.000") : "null");
            sb.Append(",\"thirdBest\":").Append(t0b < 1e8 ? F(thirdBestSum, "0.000") : "null");
            sb.Append(",\"miniMin\":").Append(miniMin < 1e8 ? F(miniMin, "0.000") : "null");
            sb.Append(",\"consistency\":{\"best\":").Append(F(bestT, "0.000")).Append(",\"avg5\":").Append(F(avg5, "0.000")).Append(",\"spread\":").Append(F(spread, "0.000")).Append(",\"n\":").Append(n5).Append('}');
            sb.Append(",\"goal\":").Append(Json_.S(goal)).Append("}}");
            return sb.ToString();
        }

        // D-02: the lap's own time axis on its 1 m grid (tm[i] = seconds into the lap at distance i / metres of the lap), so a corner's
        // LapDistPct can be turned into seconds into the lap, which the recorder's sidecar (lapStartOffset) turns into a time in the clip.
        internal static bool LapAxis(string id, int lap, out double lengthM, out double[] tm, out int metres, out double lapTime)
        {
            lengthM = 0; tm = null; metres = 0; lapTime = 0;
            try
            {
                string file = ResolveFile(id);
                if (file == null) return false;
                Sess s = Get(file);
                if (s == null || s.Laps == null) return false;
                foreach (LapTrace l in s.Laps)
                    if (l.Lap == lap && l.Tm != null && l.Tm.Length > 0 && l.Metres > 0)
                    { lengthM = l.LengthM; tm = l.Tm; metres = l.Metres; lapTime = l.Time; return true; }
            }
            catch { }
            return false;
        }

        // The quickest lap iRacing counted in one telemetry file (the Sessions page's best for that session and so the delta bar's PB reference).
        // -1 = the file cannot be read as laps (the caller keeps its own estimate); 0 = it has laps but none counted.
        internal static double CountedBest(string path)
        {
            try
            {
                Sess s = Load(path);
                double best = 0;
                foreach (LapTrace lap in s.Laps) if (Counted(lap) && (best <= 0 || lap.Time < best)) best = lap.Time;
                return best;
            }
            catch { return -1; }
        }
    }

    // L-1: ONE rule for "did iRacing count this lap", used everywhere a lap can become a best (docs\tasks\log\L-1-laprules.md).
    // iRacing shows a lap time for every lap, but only a lap it COUNTED can be its session best. So its own best lap (LapBestLapTime) is the evidence, read at
    // the end of the lap and 1.5 to 2.5 s after the line; the off-track record (PlayerTrackSurface 0) decides only where that evidence says nothing:
    //   1. iRacing gave the lap no time                                        -> not counted
    //   2. the lap is quicker than iRacing's best so far (or it had none):
    //        its best became this lap's time                                   -> COUNTED, whatever the off-track record says (practice sessions count laps with long off-tracks)
    //        its best did not change                                           -> NOT counted (W6c: 13-28-11 laps 2-6, in the AI races an off-track lap is left out)
    //   3. the lap is not quicker than the best so far: its best cannot tell   -> the off-track record decides: any off-track record = not counted, none = counted
    // A file without the best-lap channel has no evidence: the off-track record decides alone.
    // The callers read their records their own way (Analysis.Load, IbtLaps.Load) and hand the plain facts here, so the rule is written once.
    static class LapRules
    {
        public const int Version = 3;                     // stored with what was worked out under the rule (Vault rows, the career cache, the PB reference files, the Sessions page cache); a lower number = made under an older rule and read again
        const int AfterFrom = 90, AfterTo = 150;          // records after the line (60 per second): where the sim has updated its best-lap time
        const double Slack = 0.0015;                      // the figures are 32-bit floats

        // iRacing's best lap of the session as the file says it just after record `end` (the line): the lowest positive value there, -1 when there is none or the file ends first
        public static double BestAfter(float[] best, int n, long end)
        {
            long from = end + AfterFrom, to = Math.Min((long)n, end + AfterTo);
            if (from >= n || to <= from) return -1;
            double b = -1;
            for (long k = from; k < to; k++) { double v = best[k]; if (v > 1 && (b < 0 || v < b)) b = v; }
            return b;
        }

        // iRacing's best lap of the session at the last record of the lap (before it can know the lap): -1 when it had none
        public static double BestBefore(float[] best, int n, long end)
        {
            if (end < 1 || end - 1 >= n) return -1;
            double v = best[end - 1];
            return v > 1 ? v : -1;
        }

        // timed: iRacing gave the lap a time. offTrack: any off-track record in it. haveBest: the file has the best-lap channel. bestBefore / bestAfter: see above. time: the lap's time.
        // why: the evidence that decided, in words.
        public static bool Judge(bool timed, bool offTrack, bool haveBest, double bestBefore, double bestAfter, double time, out string why)
        {
            if (!timed) { why = "iRacing gave the lap no time"; return false; }
            if (!haveBest) { why = offTrack ? "no best-lap channel in the file; off-track record" : "no best-lap channel in the file; no off-track record"; return !offTrack; }
            bool faster = bestBefore <= 0 || time < bestBefore - Slack;
            if (faster)
            {
                bool became = bestAfter > 0 && bestAfter <= time + Slack;
                why = became ? "iRacing's best lap became this lap" : "quicker than iRacing's best so far, its best lap did not change";
                return became;
            }
            why = offTrack ? "not quicker than iRacing's best so far, so no evidence; off-track record" : "not quicker than iRacing's best so far, so no evidence; no off-track record";
            return !offTrack;
        }

        public static bool Counted(bool timed, bool offTrack, bool haveBest, double bestBefore, double bestAfter, double time) { string why; return Judge(timed, offTrack, haveBest, bestBefore, bestAfter, time, out why); }
    }
}
