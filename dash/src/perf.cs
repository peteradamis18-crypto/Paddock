// Performance (WS16 in docs\SPEC-next.md; notes in docs\performance.md): the frame-rate report for every session, what
// else was running when it dipped, markers for things that changed, and "did it help?" answered with like-for-like sessions.
//   F1 report  : every finished .ibt becomes one row in data\perf.tsv (port of fps-report.ps1; older files are done once, in the background)
//   F2 sampler : while the sim runs, one thread looks at every program's CPU time every 5 s (data\perf-procs.tsv, one row per drive)
//   F3 changes : data\perf-changes.tsv (graphics backups, sim priority, overlays, delta bar, driver, iRacing build, Windows switches)
//   F4 checklist: measured items only, read-only checks of Windows and iRacing's graphics file
//   F5 live    : /perf/live gives the browser the "usual" frame rate for this track and the likely cause of a drop
// Everything here only reads: telemetry files are opened read-only (never while driving), iRacing's and Windows' settings are
// only looked at. Owned by the performance workstream; irdash.cs only calls Init / Start / Route / Handles / Do.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

namespace IRDash
{
    static class Perf
    {
        internal static string Dir;
        internal static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly HashSet<string> Commands = new HashSet<string> { "perf", "perfclose", "perfshow", "perfscan" };
        static bool started;
        static readonly object navGate = new object();
        static string want = ""; static int navSeq; static DateTime navSince = DateTime.MinValue;

        public static long Now() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; }
        internal static long ToUnix(DateTime utc) { return (long)(utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; }
        internal static string N(double v, string fmt) { return double.IsNaN(v) || double.IsInfinity(v) ? "null" : v.ToString(fmt, Inv); }
        internal static string N2(double v) { return N(v, "0.##"); }
        internal static string B(bool b) { return b ? "true" : "false"; }

        public static void Init(string d)
        {
            Dir = d;
            try { Directory.CreateDirectory(Dir); } catch { }
            PerfStore.Init(Dir);
            PerfChanges.Init(Dir);
            PerfSampler.Init(Dir);
            PerfPrio.Init(Dir);
        }

        // background threads; called once at startup
        public static void Start()
        {
            if (started) return; started = true;
            PerfReports.Start();
            PerfSampler.Start();
        }

        // GET /perf and /perf/... ; return null when the path is not ours
        public static string Route(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            try
            {
                switch (path)
                {
                    case "/perf": return PerfJson.Overview();
                    case "/perf/status": return PerfJson.Status();
                    case "/perf/live": return PerfLive.Json();
                    case "/perf/checklist": return PerfCheck.Json();
                    case "/perf/summary": return "{\"text\":" + Json_.S(Summary()) + "}";
                    case "/perf/nav": return NavJson();
                    case "/perf/scan": PerfReports.Kick(); return "{\"ok\":true}";
                    case "/perf/session":
                        {
                            string file; q.TryGetValue("file", out file);
                            string j = PerfJson.One(file);
                            if (j == null) { code = 404; return "{\"error\":\"no report for that file\"}"; }
                            return j;
                        }
                }
                if (path.StartsWith("/perf/test/", StringComparison.Ordinal)) return PerfTest.Route(path, q, out code);
            }
            catch (Exception ex)
            {
                Log.W("perf: " + path + ": " + ex.Message);
                code = 500; return "{\"error\":\"could not answer\"}";
            }
            return null;
        }

        public static bool Handles(string c) { return Commands.Contains(c ?? ""); }

        // "perf" opens the page over the top screen (like the sessions page); never while driving
        public static bool Do(string c, string a)
        {
            switch (c)
            {
                case "perf": return NavSet("perf");
                case "perfclose": NavSet(""); return true;
                case "perfscan": PerfReports.Kick(); return true;
                case "perfshow": return ShowTool(a);
            }
            return false;
        }

        static bool NavSet(string to)
        {
            lock (navGate)
            {
                if (to != "" && Program.IsDriving) return false;
                if (want != to) { want = to; navSince = DateTime.Now; navSeq++; Log.W("perf: page request: " + (to == "" ? "back to the dashboard" : to)); }
                else navSince = DateTime.Now;
                return true;
            }
        }

        // from the sampler's 5 s loop: a request never outlives the start of driving, or half an hour
        internal static void NavTick(bool driving)
        {
            lock (navGate)
                if (want != "" && (driving || (DateTime.Now - navSince).TotalMinutes > 30)) { want = ""; navSeq++; }
        }

        static string NavJson() { lock (navGate) return "{\"to\":" + Json_.S(want) + ",\"seq\":" + navSeq + ",\"driving\":" + B(Program.IsDriving) + "}"; }

        // "show me the file": opens Explorer with one of our tools selected so Peter can double-click it. Only names we made.
        static bool ShowTool(string name)
        {
            if (Program.IsDriving || string.IsNullOrEmpty(name) || !Regex.IsMatch(name, @"^perf-[a-z0-9-]{1,40}(-UNDO)?\.cmd$")) return false;
            string p = Path.Combine(Path.Combine(Program.RootDir, "tools"), name);
            if (!File.Exists(p)) return false;
            try { Process.Start("explorer.exe", "/select,\"" + p + "\""); Log.W("perf: showed " + name + " in Explorer"); return true; }
            catch (Exception ex) { Log.W("perf: show " + name + ": " + ex.Message); return false; }
        }

        // one plain sentence for Rig Doctor and the deck
        public static string Summary()
        {
            PerfRow last = PerfJson.LastRow(PerfStore.All());
            if (last == null) return PerfReports.State == "done" ? "No frame-rate report yet" : "Frame-rate reports are being prepared.";
            string s = "Last session " + (int)Math.Round(last.Avg) + " fps average, " + (int)Math.Round(last.Low1) + " at the low end. " + PerfText.Short(last);
            int look = PerfCheck.AttentionCount();
            if (look > 0) s += " " + look + (look == 1 ? " thing" : " things") + " to look at on the Performance page.";
            return s;
        }
    }

    // ---------------- one row of data\perf.tsv = one session (one .ibt file) ----------------
    sealed class PerfRow
    {
        public string File = "", Track = "", Config = "", TrackKey = "", TrackRaw = "", Car = "", Type = "", Build = "", Verdict = "", Worst3 = "";
        public long Size, Start, Computed;
        public bool Online;
        public double Dur, Secs, Cars = -1, Field, Avg, Low1, Worst, Cap, Below, Dip, CpuAvg, CpuPeak, GpuAvg, GpuPeak,
                      BgAvg = -1, BgPeak = -1, LatAvg = -1, LatMax = -1, Qual = -1, Partner = -1, PfAvg = -1, PfPeak = -1;

        public const int Version = 1;
        public static readonly string Header = "# file\tsize\tstart\tdur\tsecs\ttrack\tconfig\ttrackKey\ttrackRaw\tcar\ttype\tbuild\tonline\tfield\tcars\tavg\tlow1\tworst\tcap\tbelowPct\tdipPct\t" +
            "cpuAvg\tcpuPeak\tgpuAvg\tgpuPeak\tbgAvg\tbgPeak\tverdict\tlatMs\tlatMax\tqual\tpartner\tpfAvg\tpfPeak\tworstPlaces\tcomputed\tv";

        static string D(double v) { return v.ToString("0.###", CultureInfo.InvariantCulture); }
        static string T(string s) { return (s ?? "").Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' '); }

        public string ToLine()
        {
            return string.Join("\t", new string[] { T(File), Size.ToString(), Start.ToString(), D(Dur), D(Secs), T(Track), T(Config), T(TrackKey), T(TrackRaw), T(Car), T(Type), T(Build), Online ? "1" : "0",
                D(Field), D(Cars), D(Avg), D(Low1), D(Worst), D(Cap), D(Below), D(Dip), D(CpuAvg), D(CpuPeak), D(GpuAvg), D(GpuPeak), D(BgAvg), D(BgPeak), T(Verdict),
                D(LatAvg), D(LatMax), D(Qual), D(Partner), D(PfAvg), D(PfPeak), T(Worst3), Computed.ToString(), Version.ToString() });
        }

        public static PerfRow Parse(string line)
        {
            if (line.Length == 0 || line[0] == '#') return null;
            string[] f = line.Split('\t');
            if (f.Length < 37) return null;
            CultureInfo inv = CultureInfo.InvariantCulture;
            Func<int, double> d = delegate (int i) { double v; return double.TryParse(f[i], NumberStyles.Float, inv, out v) ? v : 0; };
            PerfRow r = new PerfRow();
            r.File = f[0]; long.TryParse(f[1], out r.Size); long.TryParse(f[2], out r.Start); r.Dur = d(3); r.Secs = d(4);
            r.Track = f[5]; r.Config = f[6]; r.TrackKey = f[7]; r.TrackRaw = f[8]; r.Car = f[9]; r.Type = f[10]; r.Build = f[11]; r.Online = f[12] == "1";
            r.Field = d(13); r.Cars = d(14); r.Avg = d(15); r.Low1 = d(16); r.Worst = d(17); r.Cap = d(18); r.Below = d(19); r.Dip = d(20);
            r.CpuAvg = d(21); r.CpuPeak = d(22); r.GpuAvg = d(23); r.GpuPeak = d(24); r.BgAvg = d(25); r.BgPeak = d(26); r.Verdict = f[27];
            r.LatAvg = d(28); r.LatMax = d(29); r.Qual = d(30); r.Partner = d(31); r.PfAvg = d(32); r.PfPeak = d(33); r.Worst3 = f[34];
            long.TryParse(f[35], out r.Computed);
            return r;
        }

        public double End { get { return Start + Dur; } }
        // a drive long enough to say anything about (shorter ones are test drives and quick resets)
        public bool Counts { get { return Secs >= 120 && Avg > 1; } }
    }

    // ---------------- data\perf.tsv ----------------
    static class PerfStore
    {
        public static string FilePath;
        static readonly object gate = new object();
        static readonly Dictionary<string, PerfRow> rows = new Dictionary<string, PerfRow>(StringComparer.OrdinalIgnoreCase);
        static bool loaded;
        public static int Version;

        public static void Init(string dir) { FilePath = Path.Combine(dir, "perf.tsv"); }

        static void Load()
        {
            if (loaded) return; loaded = true;
            if (FilePath == null || !File.Exists(FilePath)) return;
            int lines = 0;
            try
            {
                foreach (string line in File.ReadAllLines(FilePath, Encoding.UTF8))
                {
                    if (line.Length == 0 || line[0] == '#') continue;
                    lines++;
                    PerfRow r = null;
                    try { r = PerfRow.Parse(line); } catch { }
                    if (r != null) rows[r.File] = r;       // a file that appears twice keeps its last row
                }
            }
            catch (Exception ex) { Log.W("perf: cannot read perf.tsv: " + ex.Message); }
            if (lines > rows.Count) { Log.W("perf: perf.tsv had " + (lines - rows.Count) + " repeated or unreadable rows - tidied"); try { Rewrite(); } catch (Exception ex) { Log.W("perf: " + ex.Message); } }
        }

        static void Rewrite()
        {
            StringBuilder sb = new StringBuilder();
            sb.Append(PerfRow.Header).Append("\r\n");
            List<PerfRow> l = new List<PerfRow>(rows.Values);
            l.Sort(delegate (PerfRow a, PerfRow b) { return a.Start.CompareTo(b.Start); });
            foreach (PerfRow r in l) sb.Append(r.ToLine()).Append("\r\n");
            File.WriteAllText(FilePath + ".tmp", sb.ToString(), new UTF8Encoding(false));
            if (File.Exists(FilePath)) File.Delete(FilePath);
            File.Move(FilePath + ".tmp", FilePath);
        }

        public static List<PerfRow> All()
        {
            lock (gate)
            {
                Load();
                List<PerfRow> l = new List<PerfRow>(rows.Values);
                l.Sort(delegate (PerfRow a, PerfRow b) { return a.Start.CompareTo(b.Start); });
                return l;
            }
        }

        public static int Count() { lock (gate) { Load(); return rows.Count; } }

        // already reported (same name and size)?
        public static bool Has(string file, long size)
        {
            lock (gate) { Load(); PerfRow r; return rows.TryGetValue(file, out r) && r.Size == size; }
        }

        public static PerfRow Get(string file) { lock (gate) { Load(); PerfRow r; return file != null && rows.TryGetValue(file, out r) ? r : null; } }

        public static void Put(PerfRow r)
        {
            lock (gate)
            {
                Load();
                bool had = rows.ContainsKey(r.File);
                rows[r.File] = r;
                if (had || !File.Exists(FilePath)) Rewrite();
                else File.AppendAllText(FilePath, r.ToLine() + "\r\n", new UTF8Encoding(false));
                Version++;
            }
        }
    }

    // ---------------- F1: the report for one .ibt (the maths of fps-report.ps1, in C#) ----------------
    // Uses only on-track samples, ten a second, and skips the first 5 s after each time the car goes on track (loading hitch).
    // FrameRate is iRacing's 1-second average; CpuUsageFG / GpuUsage are 0..1 shares of the frame budget.
    static class PerfReport
    {
        const int Buckets = 50;   // 2 % of the lap each, for "where on the track"

        static VarDef V(TrackMaps.Ibt t, string n) { VarDef d; return t.vars.TryGetValue(n, out d) ? d : null; }

        static double Rd(byte[] b, int o, VarDef d)
        {
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

        static int Fill(Stream s, byte[] buf, int want)
        {
            int got = 0;
            while (got < want) { int r = s.Read(buf, got, want - got); if (r <= 0) break; got += r; }
            return got;
        }

        // the drivers in the session (not spectators, not the pace car)
        internal static int FieldSize(string yaml)
        {
            int n = 0;
            foreach (Match m in Regex.Matches(yaml, @"- CarIdx: (\d+)[ \t]*\r?\n((?:   [^\r\n]*\r?\n?)*)"))
            {
                string b = m.Groups[2].Value;
                if (TrackMaps.YamlValue(b, "CarIsPaceCar") == "1" || TrackMaps.YamlValue(b, "IsSpectator") == "1") continue;
                n++;
            }
            return n;
        }

        internal static string MyCar(string yaml)
        {
            string me = TrackMaps.YamlValue(yaml, "DriverCarIdx");
            Match block = Regex.Match(yaml, "- CarIdx: " + Regex.Escape(me) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
            return me.Length > 0 && block.Success ? TrackMaps.YamlValue(block.Groups[1].Value, "CarScreenName") : "";
        }

        static double Mean(List<float> l) { if (l.Count == 0) return 0; double s = 0; foreach (float f in l) s += f; return s / l.Count; }
        static double Max(List<float> l) { double m = double.MinValue; foreach (float f in l) if (f > m) m = f; return l.Count == 0 ? 0 : m; }

        // throws when the file cannot be read; a file with no driving gives a row with Secs = 0
        public static PerfRow Compute(string path)
        {
            FileInfo fi = new FileInfo(path);
            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
            if (t == null) throw new IOException("not a telemetry file");
            PerfRow row = new PerfRow();
            row.File = fi.Name; row.Size = fi.Length; row.Computed = Perf.Now();
            using (t.fs)
            {
                string y = t.yaml;
                row.Track = TrackMaps.YamlValue(y, "TrackDisplayName"); row.Config = TrackMaps.YamlValue(y, "TrackConfigName");
                row.TrackRaw = TrackMaps.YamlValue(y, "TrackName");
                row.TrackKey = TrackMaps.MakeKey(TrackMaps.YamlValue(y, "TrackID"), row.TrackRaw);
                row.Car = MyCar(y);
                string ty = Career.SessionTypeOf(y, -1);
                row.Type = ty.Length > 0 ? ty : TrackMaps.YamlValue(y, "EventType");
                row.Build = TrackMaps.YamlValue(y, "BuildVersion");
                int sub; int.TryParse(TrackMaps.YamlValue(y, "SubSessionID"), out sub);
                row.Online = sub > 0 || TrackMaps.YamlValue(y, "Official") == "1";
                row.Field = FieldSize(y);

                byte[] h = new byte[144]; t.fs.Position = 0; t.fs.Read(h, 0, 144);
                int tick = BitConverter.ToInt32(h, 8); if (tick <= 0) tick = 60;
                long startUnix = BitConverter.ToInt64(h, 112);
                row.Start = startUnix > 1000000000L && startUnix < 4000000000L ? startUnix : Perf.ToUnix(fi.CreationTimeUtc);
                int rc = BitConverter.ToInt32(h, 140);
                long n = rc > 0 ? Math.Min((long)rc, t.records) : t.records;
                row.Dur = n / (double)tick;

                VarDef vOn = V(t, "IsOnTrack"), vFps = V(t, "FrameRate"), vCpu = V(t, "CpuUsageFG"), vGpu = V(t, "GpuUsage"), vPct = V(t, "LapDistPct"), vBg = V(t, "CpuUsageBG"),
                       vLat = V(t, "ChanLatency"), vQ = V(t, "ChanQuality"), vPq = V(t, "ChanPartnerQuality"), vPf = V(t, "MemPageFaultSec"), vSurf = V(t, "CarIdxTrackSurface");
                if (vOn == null || vFps == null) throw new IOException("this file has no frame-rate channel");
                if (vSurf != null && (vSurf.Count < 2 || vSurf.Type != 2)) vSurf = null;

                int step = Math.Max(1, tick / 10);   // ten samples a second is plenty for 1-second averages
                List<float> fps = new List<float>(), cpu = new List<float>(), gpu = new List<float>(), pct = new List<float>(), bg = new List<float>(),
                            lat = new List<float>(), qual = new List<float>(), par = new List<float>(), pf = new List<float>();
                List<int> carsOn = new List<int>();
                int per = Math.Max(1, (1 << 20) / t.bufLen);
                byte[] buf = new byte[per * t.bufLen];
                t.fs.Position = t.dataOff;
                long r0 = 0, onSince = -1; int chunk = 0;
                while (r0 < n)
                {
                    int want = (int)Math.Min((long)per, n - r0);
                    int recs = Fill(t.fs, buf, want * t.bufLen) / t.bufLen;
                    if (recs == 0) break;
                    for (long k = ((r0 + step - 1) / step) * step; k < r0 + recs; k += step)
                    {
                        int o = (int)(k - r0) * t.bufLen;
                        if (Rd(buf, o, vOn) == 0) { onSince = -1; continue; }
                        if (onSince < 0) onSince = k;
                        if (k - onSince < 5L * tick) continue;
                        float f = (float)Rd(buf, o, vFps);
                        if (f <= 1) continue;
                        fps.Add(f);
                        cpu.Add(vCpu != null ? (float)Rd(buf, o, vCpu) : 0); gpu.Add(vGpu != null ? (float)Rd(buf, o, vGpu) : 0);
                        pct.Add(vPct != null ? (float)Rd(buf, o, vPct) : 0);
                        if (vBg != null) bg.Add((float)Rd(buf, o, vBg));
                        if (vLat != null) lat.Add((float)Rd(buf, o, vLat));
                        if (vQ != null) qual.Add((float)Rd(buf, o, vQ));
                        if (vPq != null) par.Add((float)Rd(buf, o, vPq));
                        if (vPf != null) pf.Add((float)Rd(buf, o, vPf));
                        if (vSurf != null)
                        {
                            int c = 0, cnt = Math.Min(64, vSurf.Count);
                            for (int i = 0; i < cnt; i++) if (BitConverter.ToInt32(buf, o + vSurf.Offset + 4 * i) >= 0) c++;
                            carsOn.Add(c);
                        }
                    }
                    r0 += recs;
                    if (recs < want) break;
                    if ((++chunk & 3) == 0) Thread.Sleep(1);   // a polite reader: never hogs the disk
                }
                int cntS = fps.Count;
                if (cntS == 0) return row;                      // no on-track driving in this file

                float[] sorted = fps.ToArray(); Array.Sort(sorted);
                double avg = Mean(fps), mx = Max(fps);
                row.Avg = avg; row.Low1 = sorted[(int)Math.Floor(cntS * 0.01)]; row.Worst = sorted[0];
                row.Secs = cntS * (double)step / tick;
                double cap = Math.Round(mx); row.Cap = cap;
                int below = 0, dips = 0; double med = sorted[cntS / 2];
                foreach (float f in fps) { if (f < cap - 5) below++; if (f < med * 0.85) dips++; }
                row.Below = 100.0 * below / cntS; row.Dip = 100.0 * dips / cntS;
                double cpuP = Mean(cpu), gpuP = Mean(gpu);
                row.CpuAvg = cpuP * 100; row.CpuPeak = Max(cpu) * 100; row.GpuAvg = gpuP * 100; row.GpuPeak = Max(gpu) * 100;
                if (bg.Count > 0) { row.BgAvg = Mean(bg) * 100; row.BgPeak = Max(bg) * 100; }
                if (pf.Count > 0) { row.PfAvg = Mean(pf); row.PfPeak = Max(pf); }
                if (carsOn.Count > 0) { double s = 0; foreach (int c in carsOn) s += c; row.Cars = s / carsOn.Count; }
                // the connection only means something online (offline, iRacing reports a fixed 33 ms)
                if (row.Online && lat.Count > 0) { row.LatAvg = Mean(lat) * 1000; row.LatMax = Max(lat) * 1000; if (qual.Count > 0) row.Qual = Mean(qual); if (par.Count > 0) row.Partner = Mean(par); }
                // the verdict, with fps-report.ps1's thresholds
                if (avg >= cap - 3 && gpuP < 0.7 && cpuP < 0.7) row.Verdict = "held";
                else if (gpuP >= 0.9) row.Verdict = "gpu";
                else if (cpuP >= 0.85) row.Verdict = "cpu";
                else row.Verdict = "close";
                row.Worst3 = Places(fps, cpu, gpu, pct, avg);
            }
            return row;
        }

        // The slowest stretches of the lap: 2 % pieces by LapDistPct, neighbours that are also slow joined up. Needs 2 s of samples.
        // Encoded as "from-to:avg:min:samples:gpu%:cpu%;..." (from / to as fractions of the lap).
        static string Places(List<float> fps, List<float> cpu, List<float> gpu, List<float> pct, double avg)
        {
            double[] sum = new double[Buckets], sg = new double[Buckets], sc = new double[Buckets], mn = new double[Buckets]; int[] cnt = new int[Buckets];
            for (int i = 0; i < Buckets; i++) mn[i] = double.MaxValue;
            for (int i = 0; i < fps.Count; i++)
            {
                double p = pct[i]; if (p < 0 || p >= 1) continue;
                int b = (int)(p * Buckets);
                sum[b] += fps[i]; sg[b] += gpu[i]; sc[b] += cpu[i]; cnt[b]++; if (fps[i] < mn[b]) mn[b] = fps[i];
            }
            double[] mean = new double[Buckets]; bool[] ok = new bool[Buckets], used = new bool[Buckets];
            for (int i = 0; i < Buckets; i++) { ok[i] = cnt[i] >= 20; mean[i] = ok[i] ? sum[i] / cnt[i] : double.MaxValue; }
            StringBuilder sb = new StringBuilder();
            for (int found = 0; found < 3; found++)
            {
                int best = -1;
                for (int i = 0; i < Buckets; i++) if (ok[i] && !used[i] && (best < 0 || mean[i] < mean[best])) best = i;
                if (best < 0 || mean[best] > avg * 0.97) break;      // nothing 3 % below the average: no trouble spot to name
                int a = best, z = best; used[best] = true;
                while (a > 0 && ok[a - 1] && !used[a - 1] && mean[a - 1] <= avg * 0.97) { a--; used[a] = true; }
                while (z < Buckets - 1 && ok[z + 1] && !used[z + 1] && mean[z + 1] <= avg * 0.97) { z++; used[z] = true; }
                double s = 0, g = 0, c = 0, m = double.MaxValue; int n = 0;
                for (int i = a; i <= z; i++) { s += sum[i]; g += sg[i]; c += sc[i]; n += cnt[i]; if (mn[i] < m) m = mn[i]; }
                if (sb.Length > 0) sb.Append(';');
                sb.Append((a / (double)Buckets).ToString("0.###", Perf.Inv)).Append('-').Append(((z + 1) / (double)Buckets).ToString("0.###", Perf.Inv)).Append(':')
                  .Append((s / n).ToString("0.#", Perf.Inv)).Append(':').Append(m.ToString("0.#", Perf.Inv)).Append(':').Append(n).Append(':')
                  .Append((100 * g / n).ToString("0", Perf.Inv)).Append(':').Append((100 * c / n).ToString("0", Perf.Inv));
            }
            return sb.ToString();
        }
    }

    // ---------------- plain-English wording for a report ----------------
    static class PerfText
    {
        static string P(double v) { return ((int)Math.Round(v)).ToString(Perf.Inv); }

        // one sentence: what limited the frame rate
        public static string Verdict(PerfRow r)
        {
            if (r.Secs < 1) return "No driving in this file.";
            string s;
            switch (r.Verdict)
            {
                case "held": s = "Held its frame limit with room to spare."; break;
                case "gpu": s = "Limited by the graphics card (busy " + P(r.GpuAvg) + " % of every frame)."; break;
                case "cpu": s = "Limited by the processor (busy " + P(r.CpuAvg) + " % of every frame)."; break;
                default:
                    s = r.GpuAvg < 70 && r.CpuAvg < 70
                        ? "Smooth: graphics card " + P(r.GpuAvg) + " %, processor " + P(r.CpuAvg) + " %."
                        : "Close to the limit.";
                    break;
            }
            if (r.Dip >= 10) s += " Dipped below usual " + P(r.Dip) + " % of the time.";
            return s;
        }

        // the short form for Rig Doctor / the deck
        public static string Short(PerfRow r)
        {
            switch (r.Verdict)
            {
                case "held": return "Held its limit with room to spare.";
                case "gpu": return "The graphics card was the limit.";
                case "cpu": return "The processor was the limit.";
                default: return "Smooth.";
            }
        }
    }

    // ---------------- the background worker that turns finished .ibt files into rows ----------------
    // Newest first, lowest thread priority, never while driving, never a file iRacing may still be writing (touched in the last
    // 2 minutes), never an OneDrive "online-only" file (opening it would start a download). Each file once (name + size).
    static class PerfReports
    {
        public static volatile string State = "waiting";      // waiting | running | done
        public static int Files, Waiting, Pending, Reported, Failed;
        public static volatile bool SimBusy;                  // true while the reports are held back because the sim is running
        public static DateTime LastPass = DateTime.MinValue;
        static readonly AutoResetEvent kick = new AutoResetEvent(false);
        static readonly Dictionary<string, int> fails = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        public static void Start()
        {
            Thread t = new Thread(Run); t.IsBackground = true; t.Priority = ThreadPriority.Lowest; t.Start();
        }
        public static void Kick() { kick.Set(); }

        static void Run()
        {
            kick.WaitOne(150000);                // the career scan reads the same folder after 2 minutes; boot is busy enough
            while (true)
            {
                try { Pass(); } catch (Exception ex) { Log.W("perf: report pass: " + ex.Message); }
                kick.WaitOne(60000);
            }
        }

        static void Pass()
        {
            string dir = TrackMaps.TelemetryDir;
            if (dir == null || !Directory.Exists(dir)) { State = "done"; return; }
            // never while the sim is running (menus, garage and pits included): the files wait for the sim to close
            if (Program.IsDriving || PerfSampler.FindSim()) { SimBusy = true; return; }
            SimBusy = false;
            string[] all = Directory.GetFiles(dir, "*.ibt");
            List<FileInfo> todo = new List<FileInfo>();
            int waiting = 0;
            foreach (string f in all)
            {
                FileInfo fi = new FileInfo(f);
                if (PerfStore.Has(fi.Name, fi.Length)) continue;
                if ((DateTime.Now - fi.LastWriteTime).TotalSeconds < 120 || Career.OnlineOnly(fi)) { waiting++; continue; }
                todo.Add(fi);
            }
            todo.Sort(delegate (FileInfo a, FileInfo b) { return b.LastWriteTime.CompareTo(a.LastWriteTime); });
            Files = all.Length; Waiting = waiting; Pending = todo.Count; LastPass = DateTime.Now;
            if (todo.Count == 0) { State = "done"; return; }
            State = "running";
            int added = 0; Stopwatch sw = Stopwatch.StartNew();
            foreach (FileInfo fi in todo)
            {
                if (Program.IsDriving || PerfSampler.FindSim()) { SimBusy = true; break; }
                PerfRow r = null;
                try { r = PerfReport.Compute(fi.FullName); }
                catch (Exception ex)
                {
                    int n; fails.TryGetValue(fi.Name, out n); n++; fails[fi.Name] = n;
                    bool noChannel = ex.Message.IndexOf("no frame-rate channel", StringComparison.Ordinal) >= 0 || ex.Message.IndexOf("not a telemetry file", StringComparison.Ordinal) >= 0;
                    Log.W("perf: " + fi.Name + ": " + ex.Message + (noChannel || n >= 3 ? " (noted as empty, not tried again)" : " (will try again)"));
                    if (noChannel || n >= 3) { r = new PerfRow(); r.File = fi.Name; r.Size = fi.Length; r.Start = Perf.ToUnix(fi.CreationTimeUtc); r.Computed = Perf.Now(); Failed++; }
                }
                if (r != null) { PerfStore.Put(r); added++; Reported++; Pending--; }
                Thread.Sleep(30);
            }
            if (added > 0)
            {
                Log.W("perf: " + added + " session report" + (added == 1 ? "" : "s") + " added in " + sw.ElapsedMilliseconds + " ms");
                try { PerfChanges.RowsChanged(); PerfPrio.Evaluate(); } catch (Exception ex) { Log.W("perf: " + ex.Message); }
            }
            State = SimBusy ? "waiting" : Pending <= 0 ? "done" : "waiting";
        }
    }

    // ---------------- F2: what the sampler wrote about one drive (data\perf-procs.tsv) ----------------
    sealed class PerfOther { public string Name = ""; public double Avg, Dip = -1; }
    sealed class PerfProc
    {
        public long Start, End; public int N, Dips; public double AvgFps, Sim, Paddock, Irdash, Browser, Overlays, Crew, CostMs, Normal;
        public string TrackKey = "", Ctx = "", OthersRaw = "";
        public List<PerfOther> Others = new List<PerfOther>();
        public static readonly string Header = "# start\tend\tsamples\tavgFps\tsim\tpaddock\tirdash\tbrowser\toverlays\tcrewchief\tothers\tdips\tcostMs\ttrackKey\tctx\tnormal\tv";

        static string D(double v) { return v.ToString("0.##", CultureInfo.InvariantCulture); }
        public string ToLine()
        {
            return string.Join("\t", new string[] { Start.ToString(), End.ToString(), N.ToString(), D(AvgFps), D(Sim), D(Paddock), D(Irdash), D(Browser), D(Overlays), D(Crew), OthersRaw, Dips.ToString(), D(CostMs), TrackKey, Ctx, D(Normal), "1" });
        }
        public static PerfProc Parse(string line)
        {
            if (line.Length == 0 || line[0] == '#') return null;
            string[] f = line.Split('\t');
            if (f.Length < 15) return null;
            CultureInfo inv = CultureInfo.InvariantCulture;
            Func<int, double> d = delegate (int i) { double v; return i < f.Length && double.TryParse(f[i], NumberStyles.Float, inv, out v) ? v : 0; };
            PerfProc p = new PerfProc();
            long.TryParse(f[0], out p.Start); long.TryParse(f[1], out p.End); int.TryParse(f[2], out p.N); p.AvgFps = d(3); p.Sim = d(4); p.Paddock = d(5); p.Irdash = d(6);
            p.Browser = d(7); p.Overlays = d(8); p.Crew = d(9); p.OthersRaw = f[10]; int.TryParse(f[11], out p.Dips); p.CostMs = d(12); p.TrackKey = f[13]; p.Ctx = f[14]; p.Normal = d(15);
            foreach (string o in p.OthersRaw.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string[] x = o.Split('~'); if (x.Length < 3) continue;
                PerfOther po = new PerfOther(); po.Name = x[0]; double.TryParse(x[1], NumberStyles.Float, inv, out po.Avg); double.TryParse(x[2], NumberStyles.Float, inv, out po.Dip);
                p.Others.Add(po);
            }
            return p;
        }
        public double Secs { get { return N * 5.0; } }
    }

    // ---------------- F2: the sampler ----------------
    // One low-priority thread. While the sim runs it looks at every program's CPU time every 5 s (Process.GetProcesses +
    // TotalProcessorTime, no WMI per sample, no per-frame work) and cuts the time you are on track into drives. For each drive it
    // keeps, per program, the average CPU use and the average during dips (frame rate 15 % under your usual / the drive's own median).
    // It measures its own cost with the thread's CPU clock and says so on /perf/status.
    static class PerfSampler
    {
        sealed class PState { public string Name; public long Cpu = -1; public bool Skip; public int Gen; }
        sealed class Seg
        {
            public DateTime Start; public int N, Dips, Off, Warm; public double SumFps, Normal, CostMs; public bool Fake;
            public string TrackKey = "", Car = "", Ctx = "";
            public Dictionary<string, double[]> G = new Dictionary<string, double[]>();    // program -> { sum all, sum in dips }
            public List<float> Fps = new List<float>();
        }

        const string PaddockProg = "Paddock (dashboard program)", PaddockBrowser = "Paddock (dashboard browser)", PaddockKeys = "Paddock (key presses)",
                     OverlaysName = "Overlays (irdashies)", CrewName = "CrewChief", SimName = "iRacing sim";

        static string procsFile;
        static Thread th;
        static readonly object gate = new object();
        static readonly List<PerfProc> procsList = new List<PerfProc>();
        static readonly List<PerfProc> testProcs = new List<PerfProc>();          // drives made while the test hook's pretend session is on: never written to disk
        static readonly Dictionary<int, PState> procs = new Dictionary<int, PState>();
        static readonly HashSet<int> dashPids = new HashSet<int>(), knownBrowsers = new HashSet<int>();
        static int gen; static bool unknownBrowser; static DateTime lastClassify = DateTime.MinValue, lastTick = DateTime.MinValue;
        static Seg seg;
        static readonly List<Dictionary<string, double>> recent = new List<Dictionary<string, double>>();   // the last few ticks, for "likely cause"
        public static volatile bool SimRunning;
        public static int Ticks, Segments; public static double CostCpuMs, CostWorstMs, RunWallMs; public static DateTime RunStart = DateTime.MinValue, LastAt = DateTime.MinValue;
        static long threadStartCpu; static DateTime threadStart = DateTime.Now;
        public static double ClassifyMs, ClassifyCpuMs; public static int Classified;
        static readonly List<double> tickMs = new List<double>();            // the last hour of per-reading wall times (ms), for the median

        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool GetThreadTimes(IntPtr h, out long create, out long exit, out long kernel, out long user);
        static long ThreadCpu() { long c, e, k, u; return GetThreadTimes(GetCurrentThread(), out c, out e, out k, out u) ? k + u : 0; }   // 100 ns units

        public static void Init(string dir)
        {
            procsFile = Path.Combine(dir, "perf-procs.tsv");
            try
            {
                if (File.Exists(procsFile))
                    foreach (string line in File.ReadAllLines(procsFile, Encoding.UTF8))
                    {
                        PerfProc p = null; try { p = PerfProc.Parse(line); } catch { }
                        if (p != null) procsList.Add(p);
                    }
            }
            catch (Exception ex) { Log.W("perf: cannot read perf-procs.tsv: " + ex.Message); }
        }

        public static void Start()
        {
            th = new Thread(Loop); th.IsBackground = true; th.Priority = ThreadPriority.BelowNormal; th.Start();
        }

        // ---- friendly program groups ----
        internal static string GroupOf(string name, int pid, string simProc)
        {
            string n = name.ToLowerInvariant();
            if (n == simProc.ToLowerInvariant()) return SimName;
            switch (n)
            {
                case "irdash": return PaddockProg;
                case "irdeck": case "irdeck-cli": return PaddockKeys;
                case "irdashies": return OverlaysName;
                case "crewchiefv4": case "crewchiefv4-beta": return CrewName;
                case "onedrive": case "onedrive.sync.service": case "filecoauth": return "OneDrive";
                case "msmpeng": case "mpdefendercoreservice": case "nissrv": case "mpcmdrun": case "securityhealthservice": case "securityhealthsystray": return "Windows Defender";
                case "tiworker": case "trustedinstaller": case "waasmedicsvc": case "usocoreworker": case "musnotification": case "musnotifyicon": case "wuauclt": case "sihclient": return "Windows Update";
                case "searchindexer": case "searchprotocolhost": case "searchfilterhost": case "searchhost": return "Windows Search";
                case "chrome": return IsDash(pid) ? PaddockBrowser : "Chrome";
                case "msedge": return IsDash(pid) ? PaddockBrowser : "Edge";
                case "msedgewebview2": return "Edge (web view)";
                case "steam": case "steamwebhelper": case "steamservice": return "Steam";
                case "discord": return "Discord";
                case "teams": case "ms-teams": case "msteams": return "Teams";
                case "gamebar": case "gamebarftserver": case "xboxgamebarwidgets": case "gamingservices": case "gamingservicesnet": return "Xbox Game Bar";
                case "nvcontainer": case "nvidia share": case "nvidia overlay": case "nvidia app": case "nvdisplay.container": case "nvsphelper64": case "nvoawrappercache": return "NVIDIA software";
                case "simhub": case "simhubwpf": return "SimHub";
                case "streamdeck": return "Stream Deck";
                case "spotify": return "Spotify";
                case "iracingui": case "iracingservice64": case "iracinglauncher64": case "iracinglocalserver64": return "iRacing app";
                case "claude": return "Claude (desktop app)";
                case "audiodg": return "Windows audio";
                case "sc-tuner": return "Simucube tuner";
                case "bk-connect": return "ButtKicker software";
                case "dwm": return "Windows desktop (dwm)";
                case "svchost": return "Windows services";
                case "explorer": return "Windows Explorer";
                case "searchapp": return "Windows Search";
                case "msiafterburner": case "rtss": case "rtsshooks64": return "MSI Afterburner / RTSS";
            }
            return name;
        }

        static bool IsDash(int pid) { lock (gate) return dashPids.Contains(pid); }

        // which Chrome / Edge programs belong to the dashboard (started with its own profile folder): asked once per new program, never on track
        static void ClassifyBrowsers()
        {
            Stopwatch sw = Stopwatch.StartNew(); long c0 = ThreadCpu();
            try
            {
                string prof = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "browser-profile");
                using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'chrome.exe' OR Name = 'msedge.exe'"))
                using (ManagementObjectCollection c = s.Get())
                    foreach (ManagementBaseObject o in c)
                        using (o)
                        {
                            int pid = Convert.ToInt32(o["ProcessId"]); string cl = Convert.ToString(o["CommandLine"]);
                            lock (gate)
                            {
                                knownBrowsers.Add(pid);
                                if (cl != null && cl.IndexOf(prof, StringComparison.OrdinalIgnoreCase) >= 0) dashPids.Add(pid); else dashPids.Remove(pid);
                            }
                        }
                Classified++;
            }
            catch (Exception ex) { Log.W("perf: cannot tell the dashboard's browser apart: " + ex.Message); }
            ClassifyMs += sw.Elapsed.TotalMilliseconds; ClassifyCpuMs += (ThreadCpu() - c0) / 1e4; lastClassify = DateTime.Now;
        }

        // the dashboard browser's program ids (for the priority trial)
        internal static List<int> DashBrowserPids() { lock (gate) return new List<int>(dashPids); }

        // ---- the loop ----
        static void Loop()
        {
            threadStartCpu = ThreadCpu(); threadStart = DateTime.Now;
            Thread.Sleep(20000);                   // boot is busy enough
            try { PerfChanges.Poll(true); } catch (Exception ex) { Log.W("perf: " + ex.Message); }
            bool was = false; DateTime lastPoll = DateTime.Now, lastDaily = DateTime.Now;
            while (true)
            {
                Stopwatch sw = Stopwatch.StartNew();
                try
                {
                    bool run = FindSim();
                    if (run && !was) { OnSimStart(); }
                    if (!run && was) { OnSimEnd(); }
                    was = run; SimRunning = run;
                    if (run) Tick();
                    else if ((DateTime.Now - lastPoll).TotalMinutes >= 5)
                    {
                        lastPoll = DateTime.Now;
                        bool daily = (DateTime.Now - lastDaily).TotalHours >= 24; if (daily) lastDaily = DateTime.Now;
                        PerfChanges.Poll(daily);
                        PerfPrio.Evaluate();
                    }
                    Perf.NavTick(Program.IsDriving);
                }
                catch (Exception ex) { Log.W("perf: sampler: " + ex.Message); }
                Thread.Sleep((int)Math.Max(500, 5000 - sw.ElapsedMilliseconds));
            }
        }

        internal static bool FindSim()
        {
            Process[] ps = null;
            try { ps = Process.GetProcessesByName(SimPriority.ProcName); return ps.Length > 0; }
            catch { return false; }
            finally { if (ps != null) foreach (Process p in ps) p.Dispose(); }
        }

        static void OnSimStart()
        {
            RunStart = DateTime.Now; lastTick = DateTime.MinValue; Ticks = 0; CostCpuMs = 0; CostWorstMs = 0; RunWallMs = 0;
            lock (gate) recent.Clear();
            Log.W("perf: sampler on (the sim is running)");
            try { PerfChanges.Poll(true); } catch (Exception ex) { Log.W("perf: " + ex.Message); }
            try { PerfPrio.OnSimStart(); } catch (Exception ex) { Log.W("perf: " + ex.Message); }
        }

        static void OnSimEnd()
        {
            CloseSeg();
            RunWallMs = (DateTime.Now - RunStart).TotalMilliseconds;
            Log.W("perf: sampler off (the sim closed) - " + Ticks + " samples" + (Ticks >= 6 ? ", " + (CostCpuMs / Ticks).ToString("0.0", Perf.Inv) + " ms each, about " + (CostCpuMs / RunWallMs * 100).ToString("0.000", Perf.Inv) + " % of one core" : " (too short a run to measure its cost)"));
            lock (gate) { procs.Clear(); }
            try { PerfPrio.OnSimEnd(); } catch (Exception ex) { Log.W("perf: " + ex.Message); }
            try { PerfChanges.Poll(false); } catch (Exception ex) { Log.W("perf: " + ex.Message); }
            PerfReports.Kick();                // the new .ibt files are old enough 2 minutes from now: the worker's next pass (<= 60 s) finds them
        }

        static void Tick()
        {
            DateTime now = DateTime.Now;
            double dt = lastTick == DateTime.MinValue ? 0 : (now - lastTick).TotalSeconds;
            lastTick = now;
            long cpu0 = ThreadCpu(); double cl0 = ClassifyCpuMs, clw0 = ClassifyMs; Stopwatch sw = Stopwatch.StartNew();
            Dictionary<string, double> g = SampleProcs(dt);
            Frame f = Sdk.Latest;
            bool on = f.Connected && f.Num("IsOnTrack") != 0 && f.Num("IsReplayPlaying") == 0;
            double fps = f.Num("FrameRate");
            if (dt > 0)
            {
                lock (gate) { recent.Add(g); while (recent.Count > 3) recent.RemoveAt(0); }
                LastAt = now;
                Update(on, fps, g, f);
            }
            if (unknownBrowser && !on && (DateTime.Now - lastClassify).TotalSeconds > 60) { unknownBrowser = false; ClassifyBrowsers(); }
            if (PerfPrio.Active) PerfPrio.Maintain();
            double ms = Math.Max(0, (ThreadCpu() - cpu0) / 1e4 - (ClassifyCpuMs - cl0));      // the one-off look at the dashboard browser is counted apart
            Ticks++; CostCpuMs += ms; if (ms > CostWorstMs) CostWorstMs = ms;
            // the thread's CPU clock ticks in 15.6 ms steps (right on average, coarse one by one), so the wall time of each reading is kept too: an upper bound
            double wall = Math.Max(0, sw.Elapsed.TotalMilliseconds - (ClassifyMs - clw0));
            lock (gate) { tickMs.Add(wall); if (tickMs.Count > 720) tickMs.RemoveAt(0); }
            if (seg != null) seg.CostMs += ms;
            RunWallMs = (DateTime.Now - RunStart).TotalMilliseconds;
        }

        static Dictionary<string, double> SampleProcs(double dt)
        {
            Dictionary<string, double> g = new Dictionary<string, double>();
            Process[] all = Process.GetProcesses();
            gen++;
            string simProc = SimPriority.ProcName;
            foreach (Process p in all)
            {
                try
                {
                    int pid = p.Id; string name = p.ProcessName; PState s;
                    if (!procs.TryGetValue(pid, out s) || s.Name != name) { s = new PState(); s.Name = name; procs[pid] = s; }
                    s.Gen = gen;
                    if (s.Skip) continue;
                    if ((name == "chrome" || name == "msedge") && !knownBrowsers.Contains(pid)) unknownBrowser = true;
                    long cpu;
                    try { cpu = p.TotalProcessorTime.Ticks; } catch { s.Skip = true; continue; }       // protected system programs: never asked again
                    if (s.Cpu >= 0 && dt > 0)
                    {
                        double pct = (cpu - s.Cpu) / 1e7 / dt * 100.0;                                   // 100 = one whole core busy
                        if (pct > 0.05) { string grp = GroupOf(name, pid, simProc); double v; g.TryGetValue(grp, out v); g[grp] = v + pct; }
                    }
                    s.Cpu = cpu;
                }
                catch { }
                finally { p.Dispose(); }
            }
            List<int> dead = null;
            foreach (KeyValuePair<int, PState> kv in procs) if (kv.Value.Gen != gen) { if (dead == null) dead = new List<int>(); dead.Add(kv.Key); }
            if (dead != null) foreach (int d in dead) procs.Remove(d);
            return g;
        }

        // ---- cutting the time on track into drives ----
        static void Update(bool on, double fps, Dictionary<string, double> g, Frame f)
        {
            if (on && fps > 1)
            {
                if (seg == null) Open(f);
                seg.Off = 0;
                if (seg.Warm < 3) { seg.Warm++; return; }            // the first 15 s after getting in: loading hitch
                double refFps = seg.Normal > 0 ? seg.Normal : (seg.Fps.Count >= 12 ? Median(seg.Fps) : 0);
                bool dip = refFps > 0 && fps < refFps * 0.85;
                seg.N++; seg.SumFps += fps; seg.Fps.Add((float)fps); if (dip) seg.Dips++;
                foreach (KeyValuePair<string, double> kv in g)
                {
                    double[] a; if (!seg.G.TryGetValue(kv.Key, out a)) { a = new double[2]; seg.G[kv.Key] = a; }
                    a[0] += kv.Value; if (dip) a[1] += kv.Value;
                }
            }
            else if (seg != null && ++seg.Off >= 2) CloseSeg();       // 10 s off the track ends a drive
        }

        static double Median(List<float> l) { float[] a = l.ToArray(); Array.Sort(a); return a[a.Length / 2]; }

        static void Open(Frame f)
        {
            seg = new Seg(); seg.Start = DateTime.Now; seg.Fake = Sdk.TestHook;
            string y = f.SessionYaml ?? "";
            seg.TrackKey = TrackMaps.MakeKey(TrackMaps.YamlValue(y, "TrackID"), TrackMaps.YamlValue(y, "TrackName"));
            seg.Car = PerfReport.MyCar(y);
            seg.Normal = PerfLive.NormalFor(y);
            seg.Ctx = PerfChanges.Context();
        }

        static void CloseSeg()
        {
            Seg s = seg; seg = null;
            if (s == null || s.N < 6) return;                          // under 30 s is not a drive
            PerfProc p = new PerfProc();
            p.Start = Perf.ToUnix(s.Start.ToUniversalTime()); p.End = Perf.ToUnix(DateTime.UtcNow); p.N = s.N; p.Dips = s.Dips; p.AvgFps = s.SumFps / s.N;
            p.TrackKey = s.TrackKey; p.Ctx = s.Ctx; p.Normal = s.Normal; p.CostMs = s.N > 0 ? s.CostMs / (s.N + 3) : 0;
            double sim = 0, irdash = 0, browser = 0, overlays = 0, crew = 0, keys = 0;
            List<PerfOther> others = new List<PerfOther>();
            foreach (KeyValuePair<string, double[]> kv in s.G)
            {
                double avg = kv.Value[0] / s.N, dip = s.Dips > 0 ? kv.Value[1] / s.Dips : -1;
                switch (kv.Key)
                {
                    case SimName: sim = avg; break;
                    case PaddockProg: irdash = avg; break;
                    case PaddockBrowser: browser = avg; break;
                    case PaddockKeys: keys = avg; break;
                    case OverlaysName: overlays = avg; break;
                    case CrewName: crew = avg; break;
                    default:
                        if (Math.Max(avg, dip) >= 1.0) { PerfOther o = new PerfOther(); o.Name = kv.Key.Replace(';', ',').Replace('~', '-').Replace('\t', ' '); o.Avg = avg; o.Dip = dip; others.Add(o); }
                        break;
                }
            }
            others.Sort(delegate (PerfOther a, PerfOther b) { return Math.Max(b.Avg, b.Dip).CompareTo(Math.Max(a.Avg, a.Dip)); });
            if (others.Count > 6) others.RemoveRange(6, others.Count - 6);
            p.Sim = sim; p.Irdash = irdash; p.Browser = browser; p.Overlays = overlays; p.Crew = crew; p.Paddock = irdash + browser + keys;
            p.Others = others;
            StringBuilder sb = new StringBuilder();
            foreach (PerfOther o in others) { if (sb.Length > 0) sb.Append(';'); sb.Append(o.Name).Append('~').Append(o.Avg.ToString("0.#", Perf.Inv)).Append('~').Append(o.Dip.ToString("0.#", Perf.Inv)); }
            p.OthersRaw = sb.ToString();
            lock (gate)
            {
                if (s.Fake) { testProcs.Add(p); return; }
                procsList.Add(p); Segments++;
                try
                {
                    if (!File.Exists(procsFile)) File.WriteAllText(procsFile, PerfProc.Header + "\r\n", new UTF8Encoding(false));
                    File.AppendAllText(procsFile, p.ToLine() + "\r\n", new UTF8Encoding(false));
                }
                catch (Exception ex) { Log.W("perf: cannot write perf-procs.tsv: " + ex.Message); }
            }
            Log.W("perf: drive over - " + p.N + " samples, " + Math.Round(p.AvgFps) + " fps, " + p.Dips + " dips, Paddock " + p.Paddock.ToString("0", Perf.Inv) + " % of a core" +
                  (others.Count > 0 ? ", busiest other: " + others[0].Name + " " + others[0].Avg.ToString("0", Perf.Inv) + " %" : ""));
        }

        // ---- what the rest of Perf asks ----
        // the drive that matches a session file best (the most overlap in time), or null
        public static PerfProc ForSession(PerfRow r)
        {
            if (r.Dur <= 0) return null;
            PerfProc best = null; double bestOv = 0;
            lock (gate)
                foreach (PerfProc p in procsList)
                {
                    double ov = Math.Min(p.End, r.End) - Math.Max(p.Start - 20, r.Start);
                    if (ov > bestOv) { bestOv = ov; best = p; }
                }
            return best != null && bestOv >= Math.Min(30, r.Dur * 0.5) ? best : null;
        }

        public static List<PerfProc> All() { lock (gate) return new List<PerfProc>(procsList); }
        public static List<PerfProc> Test() { lock (gate) return new List<PerfProc>(testProcs); }
        public static void ClearTest() { lock (gate) testProcs.Clear(); }

        // the busiest program that is not the sim in the last 15 s, or null
        public static string BusyNow(out double pct)
        {
            pct = 0; string best = null;
            lock (gate)
            {
                if (recent.Count == 0 || (DateTime.Now - LastAt).TotalSeconds > 20) return null;
                Dictionary<string, double> sum = new Dictionary<string, double>();
                foreach (Dictionary<string, double> d in recent) foreach (KeyValuePair<string, double> kv in d) { double v; sum.TryGetValue(kv.Key, out v); sum[kv.Key] = v + kv.Value / recent.Count; }
                foreach (KeyValuePair<string, double> kv in sum) if (kv.Key != SimName && kv.Value > pct) { pct = kv.Value; best = kv.Key; }
            }
            return best;
        }

        static double MedianMs() { lock (gate) { if (tickMs.Count == 0) return 0; double[] a = tickMs.ToArray(); Array.Sort(a); return a[a.Length / 2]; } }

        public static string StatusJson()
        {
            double lifeMs = (DateTime.Now - threadStart).TotalMilliseconds, lifeCpu = (ThreadCpu() - threadStartCpu) / 1e4;
            double runWall = SimRunning ? (DateTime.Now - RunStart).TotalMilliseconds : RunWallMs;
            return "{\"running\":" + Perf.B(SimRunning) + ",\"ticks\":" + Ticks + ",\"avgMs\":" + (Ticks > 0 ? Perf.N(CostCpuMs / Ticks, "0.00") : "null") + ",\"medianWallMs\":" + Perf.N(MedianMs(), "0.00") + ",\"worstMs\":" + Perf.N(CostWorstMs, "0.0") +
                   ",\"pctOfCore\":" + (runWall > 0 && Ticks > 0 ? Perf.N(CostCpuMs / runWall * 100, "0.0000") : "null") + ",\"lifetimePctOfCore\":" + Perf.N(lifeMs > 0 ? lifeCpu / lifeMs * 100 : 0, "0.0000") +
                   ",\"classified\":" + Classified + ",\"classifyMs\":" + Perf.N(ClassifyMs, "0.0") + ",\"classifyCpuMs\":" + Perf.N(ClassifyCpuMs, "0.0") + ",\"drives\":" + Segments + ",\"inDrive\":" + Perf.B(seg != null) + ",\"open\":" + (seg != null ? seg.N : 0) +
                   ",\"known\":" + procsList.Count + "}";
        }
    }

    // ---------------- read-only looks at Windows switches that matter for frame rate ----------------
    static class PerfWin
    {
        [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] struct EnumAdapters2 { public uint NumAdapters; public IntPtr pAdapters; }
        [StructLayout(LayoutKind.Sequential)] struct AdapterInfo { public uint hAdapter; public LUID Luid; public uint NumOfSources; public int Present; }
        [StructLayout(LayoutKind.Sequential)] struct QueryAdapterInfo { public uint hAdapter; public int Type; public IntPtr pData; public uint Size; }
        [StructLayout(LayoutKind.Sequential)] struct CloseAdapter { public uint hAdapter; }
        [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref EnumAdapters2 a);
        [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QueryAdapterInfo q);
        [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref CloseAdapter c);

        // Hardware-accelerated GPU scheduling, asked of Windows' graphics kernel (a read-only question): on | off | not supported | unknown
        public static string Hags()
        {
            try
            {
                EnumAdapters2 e = new EnumAdapters2();
                if (D3DKMTEnumAdapters2(ref e) != 0 || e.NumAdapters == 0) return "unknown";
                int sz = Marshal.SizeOf(typeof(AdapterInfo));
                e.pAdapters = Marshal.AllocHGlobal(sz * (int)e.NumAdapters);
                bool supported = false, enabled = false;
                try
                {
                    if (D3DKMTEnumAdapters2(ref e) != 0) return "unknown";
                    for (int i = 0; i < e.NumAdapters; i++)
                    {
                        AdapterInfo ai = (AdapterInfo)Marshal.PtrToStructure(new IntPtr(e.pAdapters.ToInt64() + (long)i * sz), typeof(AdapterInfo));
                        IntPtr buf = Marshal.AllocHGlobal(16); Marshal.WriteInt32(buf, 0);
                        QueryAdapterInfo q = new QueryAdapterInfo(); q.hAdapter = ai.hAdapter; q.Type = 70; q.pData = buf; q.Size = 4;   // KMTQAITYPE_WDDM_2_7_CAPS
                        int r = D3DKMTQueryAdapterInfo(ref q); int bits = Marshal.ReadInt32(buf); Marshal.FreeHGlobal(buf);
                        if (r == 0) { if ((bits & 1) != 0) supported = true; if ((bits & 2) != 0) enabled = true; }
                        CloseAdapter c = new CloseAdapter(); c.hAdapter = ai.hAdapter; D3DKMTCloseAdapter(ref c);
                    }
                }
                finally { Marshal.FreeHGlobal(e.pAdapters); }
                return enabled ? "on" : supported ? "off" : "not supported";
            }
            catch { return "unknown"; }
        }

        static object Reg(string key, string name) { try { return Registry.GetValue(key, name, null); } catch { return null; } }
        static string Dw(object o) { return o is int ? ((int)o).ToString() : ""; }

        // the active power plan: name (or the id when it is a custom one)
        public static string PowerPlan(out string guid)
        {
            object o = Reg(@"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes", "ActivePowerScheme");
            guid = o as string ?? "";
            switch (guid.ToLowerInvariant())
            {
                case "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c": return "High performance";
                case "381b4222-f694-41f0-9685-ff5bb260df2e": return "Balanced";
                case "a1841308-3541-4fab-bc81-f71556f20b4a": return "Power saver";
                case "e9a42b02-d5df-448d-aa00-03f14749eb61": return "Ultimate performance";
            }
            return guid.Length > 0 ? "a custom plan" : "unknown";
        }
        public static string PowerPlan() { string g; return PowerPlan(out g); }

        // "1" / "0" / "" (not set = Windows decides)
        public static string GameMode() { return Dw(Reg(@"HKEY_CURRENT_USER\Software\Microsoft\GameBar", "AutoGameModeEnabled")); }
        public static string GameDvr() { return Dw(Reg(@"HKEY_CURRENT_USER\System\GameConfigStore", "GameDVR_Enabled")); }
        public static string GameCapture() { return Dw(Reg(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\GameDVR", "AppCaptureEnabled")); }

        public static string IracingFolder
        {
            get
            {
                string p = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "iRacing");
                return Directory.Exists(p) ? p : @"C:\Program Files (x86)\iRacing";
            }
        }

        public static string IracingBuild()
        {
            try
            {
                string f = Path.Combine(IracingFolder, "version_system.txt");
                if (File.Exists(f)) { string t = File.ReadAllText(f).Trim(); if (t.Length > 0 && t.Length < 40) return t; }
                string exe = Path.Combine(IracingFolder, "iRacingSim64DX11.exe");
                if (File.Exists(exe)) { string v = FileVersionInfo.GetVersionInfo(exe).ProductVersion; if (!string.IsNullOrEmpty(v)) return v.Split(' ')[0]; }
            }
            catch { }
            return "";
        }

        // "32.0.16.1742" is NVIDIA's 617.42
        public static string NvidiaStyle(string wmi)
        {
            string[] p = (wmi ?? "").Split('.');
            if (p.Length != 4) return wmi ?? "";
            string d = p[2] + p[3];
            return d.Length >= 5 ? d.Substring(d.Length - 5, 3) + "." + d.Substring(d.Length - 2) : wmi;
        }

        // the NVIDIA card's driver, once a day (WMI is slow to wake up, so never per sample)
        public static string NvidiaDriver()
        {
            try
            {
                using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT Name, DriverVersion FROM Win32_VideoController"))
                using (ManagementObjectCollection c = s.Get())
                    foreach (ManagementBaseObject o in c)
                        using (o)
                        {
                            string name = Convert.ToString(o["Name"]);
                            if (name != null && name.IndexOf("NVIDIA", StringComparison.OrdinalIgnoreCase) >= 0) return NvidiaStyle(Convert.ToString(o["DriverVersion"]));
                        }
            }
            catch (Exception ex) { Log.W("perf: cannot read the graphics driver version: " + ex.Message); }
            return "";
        }
    }

    // ---------------- F3: markers for things that changed (data\perf-changes.tsv) ----------------
    sealed class PerfChange { public string Id = "", Kind = "", Title = "", Detail = ""; public long Ts; }

    static class PerfChanges
    {
        static string file, stateFile, gfxFile;
        static readonly object gate = new object();
        static readonly List<PerfChange> list = new List<PerfChange>();
        static readonly HashSet<string> ids = new HashSet<string>();
        static readonly Dictionary<string, string> state = new Dictionary<string, string>();
        public static int Version;
        static DateTime lastSlow = DateTime.MinValue;

        // graphics keys iRacing rewrites by itself (memory budgets): not a change you made
        static readonly HashSet<string> Ignore = new HashSet<string> { "SysMemToUseMB", "VidMemToUseMB" };
        static readonly string[] Order = { "DesiredFPSLimit", "LimitFrameRate", "NvReflexMode", "MaxPreRenderedFrames", "MaxCockpitMirrors", "MirrorDetail", "MaxCarsToDraw", "MaxCarsToDrawInMirrors",
            "SSAO", "SSRLevel", "ShadowDetail", "DynamicShadowRes", "ShaderQuality", "CarDetail", "MSAASamples", "VirtualMirrors", "TwoPassTrees", "LODMinFPSTarget" };
        static readonly Dictionary<string, string> Names = new Dictionary<string, string> {
            { "DesiredFPSLimit", "frame limit" }, { "LimitFrameRate", "frame limit on/off" }, { "NvReflexMode", "Reflex" }, { "MaxPreRenderedFrames", "pre-rendered frames" },
            { "MaxCockpitMirrors", "mirrors" }, { "MirrorDetail", "mirror detail" }, { "MaxCarsToDraw", "cars drawn" }, { "MaxCarsToDrawInMirrors", "cars in mirrors" },
            { "SSAO", "ambient shadows" }, { "SSRLevel", "reflections" }, { "SSRRainOnly", "reflections only in rain" }, { "ShadowDetail", "shadow detail" },
            { "DynamicShadowRes", "shadow sharpness" }, { "ShaderQuality", "shader quality" }, { "CarDetail", "car detail" }, { "CrowdDetail", "crowd detail" },
            { "GrandstandDetail", "grandstand detail" }, { "FoliageDetail", "foliage detail" }, { "ParticleDetail", "particles" }, { "MSAASamples", "anti-aliasing" },
            { "AntiAliasMethod", "anti-aliasing type" }, { "TwoPassTrees", "two-pass trees" }, { "VirtualMirrors", "virtual mirror" }, { "LODMinFPSTarget", "detail-drop target" },
            { "PitObjectDetail", "pit detail" }, { "ObjectDetail", "object detail" }, { "WeekendDetail", "weekend detail" }, { "SkyRefreshRate", "sky refresh" },
            { "HeadlightLevel", "headlights" }, { "EnableTireMarks", "tyre marks" }, { "SharpeningClamp", "sharpening" }, { "VRMode", "VR mode" },
            { "MotionBlurDrivingCams", "motion blur" }, { "DNSMEnable", "dynamic shadows" }, { "ShadowMapType", "shadow type" }, { "DynamicShadowMaps", "dynamic shadow maps" },
            { "CarPaint2048x2048", "car paint 2048" }, { "LowQualityTrees", "low-quality trees" }, { "CacheSwap3HighResCars", "high-res cars cache" },
            { "MaxPitObjsToDraw", "pit objects" }, { "MaxPitObjsToDrawInMirrors", "pit objects in mirrors" }, { "HeadlightsInMirrors", "headlights in mirrors" } };

        public static void Init(string dir)
        {
            file = Path.Combine(dir, "perf-changes.tsv"); stateFile = Path.Combine(dir, "perf-state.tsv"); gfxFile = Path.Combine(dir, "perf-gfx-last.tsv");
            try
            {
                if (File.Exists(file))
                    foreach (string line in File.ReadAllLines(file, Encoding.UTF8))
                    {
                        if (line.Length == 0 || line[0] == '#') continue;
                        string[] f = line.Split('\t'); long ts;
                        if (f.Length < 6 || !long.TryParse(f[1], out ts)) continue;
                        PerfChange c = new PerfChange(); c.Id = f[0]; c.Ts = ts; c.Kind = f[3]; c.Title = f[4]; c.Detail = f[5];
                        if (ids.Add(c.Id)) list.Add(c);
                    }
                if (File.Exists(stateFile))
                    foreach (string line in File.ReadAllLines(stateFile, Encoding.UTF8)) { int t = line.IndexOf('\t'); if (t > 0) state[line.Substring(0, t)] = line.Substring(t + 1); }
            }
            catch (Exception ex) { Log.W("perf: cannot read the change log: " + ex.Message); }
        }

        public static List<PerfChange> All()
        {
            lock (gate) { List<PerfChange> l = new List<PerfChange>(list); l.Sort(delegate (PerfChange a, PerfChange b) { return a.Ts.CompareTo(b.Ts); }); return l; }
        }

        public static string StateValue(string key) { lock (gate) { string v; return state.TryGetValue(key, out v) ? v : ""; } }
        public static bool IgnoredKey(string k) { return Ignore.Contains(k); }
        public static string Label(string k) { string n; return Names.TryGetValue(k, out n) ? n : k; }
        public static void AddExternal(string id, long ts, string kind, string title, string detail) { Add(id, ts, kind, title, detail); }

        static void SaveState()
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                foreach (KeyValuePair<string, string> kv in state) sb.Append(kv.Key).Append('\t').Append((kv.Value ?? "").Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ')).Append("\r\n");
                File.WriteAllText(stateFile, sb.ToString(), new UTF8Encoding(false));
            }
            catch (Exception ex) { Log.W("perf: " + ex.Message); }
        }

        static bool Add(string id, long ts, string kind, string title, string detail)
        {
            lock (gate)
            {
                if (ids.Contains(id)) return false;
                PerfChange c = new PerfChange(); c.Id = id; c.Ts = ts; c.Kind = kind; c.Title = title; c.Detail = detail;
                ids.Add(id); list.Add(c); Version++;
                try
                {
                    if (!File.Exists(file)) File.WriteAllText(file, "# id\twhen (unix)\tdate\tkind\ttitle\tdetail\r\n", new UTF8Encoding(false));
                    string when = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(ts).ToLocalTime().ToString("yyyy-MM-dd HH:mm", Perf.Inv);
                    File.AppendAllText(file, string.Join("\t", new string[] { id, ts.ToString(), when, kind, title.Replace('\t', ' '), detail.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ') }) + "\r\n", new UTF8Encoding(false));
                }
                catch (Exception ex) { Log.W("perf: cannot write the change log: " + ex.Message); }
            }
            Log.W("perf: change noted - " + title + (detail.Length > 0 ? ": " + detail : ""));
            return true;
        }

        // watches one value; the first time it is only remembered (a baseline is not a change)
        static void Watch(string key, string now, string kind, string title, Func<string, string, string> detail)
        {
            if (now == null) return;
            string old = null; bool had;
            lock (gate) had = state.TryGetValue(key, out old);
            if (!had) { lock (gate) state[key] = now; SaveState(); return; }
            if (old == now) return;
            lock (gate) state[key] = now;
            SaveState();
            Add(kind + ":" + key + ":" + Perf.Now(), Perf.Now(), kind, title, detail(old, now));
        }

        // ---- one look at everything we can see; the slow looks (driver, via WMI) at most once a day ----
        public static void Poll(bool full)
        {
            Action<string, Action> run = delegate (string what, Action a) { try { a(); } catch (Exception ex) { Log.W("perf: change check (" + what + "): " + ex.Message); } };
            run("graphics", Graphics);
            run("priority", delegate { Watch("simprio", SimPriority.Mode, "priority", "Sim priority setting changed", delegate (string o, string n) { return "irdash.ini sim_priority: " + o + " to " + n; }); });
            run("overlays", Overlay);
            run("delta bar", delegate { string v = IniValue("delta_bar"); if (v != null) Watch("delta", v == "0" ? "0" : "1", "delta bar", "Delta bar turned " + (v == "0" ? "off" : "on"), delegate (string o, string n) { return "irdash.ini delta_bar=" + n; }); });
            run("windows", Windows);
            run("iracing", delegate { string b = PerfWin.IracingBuild(); if (b.Length > 0) Watch("build", b, "iracing", "iRacing updated", delegate (string o, string n) { return o + " to " + n; }); });
            if (full && (DateTime.Now - lastSlow).TotalHours >= 20)
            {
                lastSlow = DateTime.Now;
                run("driver", delegate { string d = PerfWin.NvidiaDriver(); if (d.Length > 0) Watch("driver", d, "driver", "NVIDIA graphics driver updated", delegate (string o, string n) { return o + " to " + n; }); });
            }
            run("rows", RowsChanged);
        }

        static string IniValue(string key)
        {
            try
            {
                if (Program.IniFile == null || !File.Exists(Program.IniFile)) return null;
                foreach (string l in File.ReadAllLines(Program.IniFile)) if (l.StartsWith(key + "=", StringComparison.OrdinalIgnoreCase)) return l.Substring(key.Length + 1).Trim();
            }
            catch { }
            return null;
        }

        // ---- overlays: how many widgets, which, which preset ----
        static void Overlay()
        {
            string j = Overlays.Json();
            if (j.IndexOf("\"known\":true", StringComparison.Ordinal) < 0) return;     // the overlays file is not readable right now (a restart is in progress)
            List<string> on = new List<string>();
            foreach (Match m in Regex.Matches(j, "\\{\"id\":\"(\\w+)\",\"name\":\"[^\"]*\",\"on\":true")) on.Add(m.Groups[1].Value);
            on.Sort(StringComparer.Ordinal);
            Match pm = Regex.Match(j, "\\{\"id\":\"(\\w+)\",\"name\":\"[^\"]*\",\"exists\":true,\"match\":true");
            string sig = on.Count + "|" + string.Join(",", on.ToArray()) + "|" + (pm.Success ? pm.Groups[1].Value : "");
            Watch("ovl", sig, "overlays", "Overlays changed", delegate (string o, string n)
            {
                string[] a = o.Split('|'), b = n.Split('|');
                HashSet<string> sa = new HashSet<string>(a.Length > 1 ? a[1].Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries) : new string[0]);
                HashSet<string> sb2 = new HashSet<string>(b.Length > 1 ? b[1].Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries) : new string[0]);
                List<string> add = new List<string>(), rem = new List<string>();
                foreach (string s in sb2) if (!sa.Contains(s)) add.Add(s);
                foreach (string s in sa) if (!sb2.Contains(s)) rem.Add(s);
                string t = sa.Count + " to " + sb2.Count + " widgets";
                if (add.Count > 0) t += "; added " + string.Join(", ", add.ToArray());
                if (rem.Count > 0) t += "; removed " + string.Join(", ", rem.ToArray());
                if (b.Length > 2 && b[2].Length > 0) t += "; now the " + b[2].ToUpperInvariant() + " preset";
                return t;
            });
        }

        // ---- Windows switches (read only) ----
        static void Windows()
        {
            Watch("plan", PerfWin.PowerPlan(), "windows", "Windows power plan changed", delegate (string o, string n) { return o + " to " + n; });
            Watch("gamemode", PerfWin.GameMode() == "0" ? "off" : "on", "windows", "Windows Game Mode switched", delegate (string o, string n) { return "Game Mode " + n; });
            string rec = PerfWin.GameDvr() == "1" || PerfWin.GameCapture() == "1" ? "on" : "off";
            Watch("gamedvr", rec, "windows", "Xbox Game Bar background recording switched", delegate (string o, string n) { return "background recording " + n; });
            Watch("hags", PerfWin.Hags(), "windows", "Hardware GPU scheduling switched", delegate (string o, string n) { return "GPU scheduling " + n; });
        }

        // ---- graphics: backups made by gfx-set.ps1 give exact times; a difference nobody backed up was made inside iRacing ----
        sealed class Snap { public string Name, Path; public DateTime Local; }

        static List<Snap> Snapshots()
        {
            List<Snap> l = new List<Snap>();
            string backup = Path.Combine(Program.RootDir, "backup");
            string docs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "iRacing");
            List<string> files = new List<string>();
            try { if (Directory.Exists(backup)) files.AddRange(Directory.GetFiles(backup, "rendererDX11Monitor-*.ini")); } catch { }
            try { if (Directory.Exists(docs)) files.AddRange(Directory.GetFiles(docs, "rendererDX11Monitor.ini.bak-*")); } catch { }
            foreach (string f in files)
            {
                string name = Path.GetFileName(f);
                Match m = Regex.Match(name, @"(\d{8})(?:-(\d{4,6}))?");
                if (!m.Success) continue;
                DateTime t;
                string stamp = m.Groups[1].Value + (m.Groups[2].Success ? m.Groups[2].Value.PadRight(6, '0') : "000000");
                if (!DateTime.TryParseExact(stamp, "yyyyMMddHHmmss", Perf.Inv, DateTimeStyles.None, out t)) continue;
                Snap s = new Snap(); s.Name = name; s.Path = f; s.Local = t; l.Add(s);
            }
            l.Sort(delegate (Snap a, Snap b) { return a.Local.CompareTo(b.Local); });
            return l;
        }

        internal static Dictionary<string, string> GfxOptions(string path)
        {
            Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string text;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader r = new StreamReader(fs, Encoding.GetEncoding(28591))) text = r.ReadToEnd();
            bool inSec = false;
            foreach (string raw in text.Split('\n'))
            {
                string l = raw.Trim();
                if (l.StartsWith("[", StringComparison.Ordinal)) { inSec = l == "[Graphics Options]"; continue; }
                if (!inSec) continue;
                Match m = Regex.Match(l, @"^(\w+)=([^;\s]*)");
                if (m.Success) d[m.Groups[1].Value] = m.Groups[2].Value;
            }
            return d;
        }

        internal static string CurrentIni { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), @"iRacing\rendererDX11Monitor.ini"); } }

        // keys whose value differs (present in both), most telling first: "frame limit 120 to 160"
        static List<string> Diff(Dictionary<string, string> a, Dictionary<string, string> b)
        {
            List<string> keys = new List<string>();
            foreach (KeyValuePair<string, string> kv in a) { string v; if (!Ignore.Contains(kv.Key) && b.TryGetValue(kv.Key, out v) && v != kv.Value) keys.Add(kv.Key); }
            keys.Sort(delegate (string x, string y)
            {
                int ix = Array.IndexOf(Order, x), iy = Array.IndexOf(Order, y);
                if (ix < 0) ix = 999; if (iy < 0) iy = 999;
                return ix != iy ? ix.CompareTo(iy) : string.Compare(x, y, StringComparison.Ordinal);
            });
            List<string> l = new List<string>();
            foreach (string k in keys) { string nm; l.Add((Names.TryGetValue(k, out nm) ? nm : k) + " " + a[k] + " to " + b[k]); }
            return l;
        }

        // the whole list is kept in the log (the page shortens it); "name a to b; name c to d"
        static string DiffText(List<string> d)
        {
            int show = Math.Min(40, d.Count);
            return string.Join("; ", d.GetRange(0, show).ToArray()) + (d.Count > show ? "; and " + (d.Count - show) + " more" : "");
        }

        static void Graphics()
        {
            string cur = CurrentIni;
            if (!File.Exists(cur)) return;
            Dictionary<string, string> now = GfxOptions(cur);
            if (now.Count == 0) return;
            List<Snap> snaps = Snapshots();
            long newest = 0;
            for (int i = 0; i < snaps.Count; i++)
            {
                Dictionary<string, string> a, b;
                try { a = GfxOptions(snaps[i].Path); b = i + 1 < snaps.Count ? GfxOptions(snaps[i + 1].Path) : now; } catch { continue; }
                List<string> d = Diff(a, b);
                long ts = Perf.ToUnix(snaps[i].Local.ToUniversalTime());
                if (ts > newest) newest = ts;
                if (d.Count == 0) continue;
                Add("gfx:" + snaps[i].Name, ts, "graphics", d.Count == 1 ? "Graphics setting changed" : "Graphics settings changed (" + d.Count + ")", DiffText(d));
            }
            // a difference no backup explains was made inside iRacing's own menus
            Dictionary<string, string> last = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            long lastAt = 0;
            try
            {
                if (File.Exists(gfxFile))
                    foreach (string line in File.ReadAllLines(gfxFile, Encoding.UTF8))
                    {
                        int t = line.IndexOf('\t'); if (t <= 0) continue;
                        string k = line.Substring(0, t), v = line.Substring(t + 1);
                        if (k == "#saved") long.TryParse(v, out lastAt); else last[k] = v;
                    }
            }
            catch { }
            if (last.Count > 0)
            {
                List<string> d = Diff(last, now);
                if (d.Count > 0 && newest <= lastAt)
                    Add("gfxapp:" + Perf.Now(), Perf.Now(), "graphics", "Graphics changed in iRacing", DiffText(d));
            }
            if (last.Count == 0 || Diff(last, now).Count > 0)
            {
                StringBuilder sb = new StringBuilder("#saved\t" + Perf.Now() + "\r\n");
                foreach (KeyValuePair<string, string> kv in now) sb.Append(kv.Key).Append('\t').Append(kv.Value).Append("\r\n");
                try { File.WriteAllText(gfxFile, sb.ToString(), new UTF8Encoding(false)); } catch { }
            }
        }

        // ---- the build iRacing was on in each session: an update shows up as a change between two sessions ----
        public static void RowsChanged()
        {
            string prev = null;
            foreach (PerfRow r in PerfStore.All())
            {
                if (r.Build.Length == 0) continue;
                if (prev != null && prev != r.Build) Add("build:" + r.Build, r.Start, "iracing", "iRacing updated", prev + " to " + r.Build);
                prev = r.Build;
            }
        }

        // a short label of what is switched on right now, kept with each drive
        public static string Context()
        {
            string ovl = "", delta = "";
            lock (gate)
            {
                string s; if (state.TryGetValue("ovl", out s)) { int i = s.IndexOf('|'); ovl = i > 0 ? s.Substring(0, i) : s; }
                if (state.TryGetValue("delta", out s)) delta = s;
            }
            return "overlays=" + ovl + ";delta=" + delta + ";lowprio=" + (PerfPrio.Active ? "1" : "0");
        }
    }

    // ---------------- F5 + "usual here": what a normal frame rate is at this track, and the likely cause of a drop ----------------
    static class PerfLive
    {
        sealed class Info { public int Ver = -1, Len = -1; public string Key = "", Car = "", Track = ""; public double Field; }
        static Info info = new Info();
        static readonly object gate = new object();

        // sessions with about the same number of cars (alone with alone, a grid with a grid)
        internal static bool SimilarField(double a, double b)
        {
            if (a <= 1.5 && b <= 1.5) return true;
            if (a <= 1.5 || b <= 1.5) return false;
            double r = a > b ? a / b : b / a;
            return r <= 1.6 || Math.Abs(a - b) <= 4;
        }

        static Info Parse(Frame f)
        {
            string y = f.SessionYaml ?? "";
            lock (gate)
            {
                if (info.Ver == f.SessionVersion && info.Len == y.Length) return info;
                Info n = new Info(); n.Ver = f.SessionVersion; n.Len = y.Length;
                if (y.Length > 0)
                {
                    n.Key = TrackMaps.MakeKey(TrackMaps.YamlValue(y, "TrackID"), TrackMaps.YamlValue(y, "TrackName"));
                    n.Track = TrackMaps.YamlValue(y, "TrackDisplayName"); n.Car = PerfReport.MyCar(y); n.Field = PerfReport.FieldSize(y);
                }
                info = n; return n;
            }
        }

        // the typical average at this track in this car with about this many cars: median of the last 8 such sessions; 0 = not enough history
        internal static double Normal(List<PerfRow> rows, string key, string car, double field, long before)
        {
            List<double> v = new List<double>();
            for (int i = rows.Count - 1; i >= 0 && v.Count < 8; i--)
            {
                PerfRow r = rows[i];
                if (!r.Counts || r.TrackKey != key || r.Car != car || (before > 0 && r.Start >= before) || !SimilarField(r.Field, field)) continue;
                v.Add(r.Avg);
            }
            return v.Count < 2 ? 0 : PerfCompare.Median(v);
        }

        public static double NormalFor(string yaml)
        {
            if (string.IsNullOrEmpty(yaml)) return 0;
            string key = TrackMaps.MakeKey(TrackMaps.YamlValue(yaml, "TrackID"), TrackMaps.YamlValue(yaml, "TrackName"));
            return Normal(PerfStore.All(), key, PerfReport.MyCar(yaml), PerfReport.FieldSize(yaml), 0);
        }

        public static string Json()
        {
            Frame f = Sdk.Latest;
            if (!f.Connected || string.IsNullOrEmpty(f.SessionYaml)) return "{\"on\":false}";
            Info i = Parse(f);
            double normal = Normal(PerfStore.All(), i.Key, i.Car, i.Field, 0);
            double busyPct; string busy = PerfSampler.BusyNow(out busyPct);
            double gpu = f.Num("GpuUsage"), cpu = f.Num("CpuUsageFG");
            string cause = "", kind = "";
            if (busy != null && busyPct >= 20) { cause = busy + " is busy (" + (int)Math.Round(busyPct) + " % of a core)"; kind = "program"; }
            else if (gpu >= 0.92) { cause = "the graphics card is full (a busy scene)"; kind = "gpu"; }
            else if (cpu >= 0.88) { cause = "the processor is full (a busy scene)"; kind = "cpu"; }
            return "{\"on\":true,\"track\":" + Json_.S(i.Track) + ",\"car\":" + Json_.S(i.Car) + ",\"field\":" + Perf.N2(i.Field) + ",\"normal\":" + (normal > 0 ? Perf.N(normal, "0.0") : "null") +
                   ",\"cause\":" + Json_.S(cause) + ",\"causeKind\":" + Json_.S(kind) + ",\"gpu\":" + Perf.N(gpu * 100, "0") + ",\"cpu\":" + Perf.N(cpu * 100, "0") + ",\"sampler\":" + Perf.B(PerfSampler.SimRunning) + "}";
        }
    }

    // ---------------- "did it help?": like-for-like sessions before and after a change ----------------
    sealed class PerfEpisode
    {
        public long Start, End; public List<PerfChange> Items = new List<PerfChange>(); public string Id = "";
        public List<string> Kinds() { List<string> k = new List<string>(); foreach (PerfChange c in Items) if (!k.Contains(c.Kind)) k.Add(c.Kind); return k; }

        // graphics settings: what each one went from and to across the whole episode (a setting tried and put back is no change)
        public List<string> NetGraphics()
        {
            List<string> order = new List<string>(); Dictionary<string, string[]> net = new Dictionary<string, string[]>();
            foreach (PerfChange c in Items)
            {
                if (c.Kind != "graphics") continue;
                foreach (string part in c.Detail.Split(new[] { "; " }, StringSplitOptions.RemoveEmptyEntries))
                {
                    Match m = Regex.Match(part, @"^(.*) (\S+) to (\S+)$");
                    if (!m.Success) continue;
                    string[] ft; if (!net.TryGetValue(m.Groups[1].Value, out ft)) { order.Add(m.Groups[1].Value); net[m.Groups[1].Value] = new[] { m.Groups[2].Value, m.Groups[3].Value }; } else ft[1] = m.Groups[3].Value;
                }
            }
            List<string> l = new List<string>();
            foreach (string k in order) if (net[k][0] != net[k][1]) l.Add(k + " " + net[k][0] + " to " + net[k][1]);
            return l;
        }

        bool GraphicsOnly { get { List<string> k = Kinds(); return k.Count == 1 && k[0] == "graphics"; } }

        public string Title
        {
            get
            {
                if (Items.Count == 1) return Items[0].Title.StartsWith("Graphics settings changed (", StringComparison.Ordinal) ? "Graphics settings changed (" + NetGraphics().Count + ")" : Items[0].Title;
                if (GraphicsOnly) { int n = NetGraphics().Count; return n == 0 ? "Graphics tried and put back" : "Graphics tuning (" + n + (n == 1 ? " setting" : " settings") + ")"; }
                List<string> k = Kinds();
                return k.Count == 1 ? Items[0].Title + " (" + Items.Count + " times)" : "Several changes (" + Items.Count + ")";
            }
        }

        public string Detail
        {
            get
            {
                List<string> d = new List<string>();
                List<string> g = NetGraphics();
                if (g.Count > 0) d.Add(string.Join("; ", g.GetRange(0, Math.Min(6, g.Count)).ToArray()) + (g.Count > 6 ? " (+" + (g.Count - 6) + " more)" : ""));
                foreach (PerfChange c in Items)
                {
                    if (c.Kind == "graphics") continue;
                    string t = Items.Count > 1 ? c.Title + (c.Detail.Length > 0 ? ": " + c.Detail : "") : c.Detail;
                    if (t.Length > 0 && !d.Contains(t)) d.Add(t);
                }
                string s = string.Join(" | ", d.ToArray());
                return s.Length > 400 ? s.Substring(0, 397) + "..." : s;
            }
        }
    }

    sealed class PerfResult
    {
        public string State = "none";            // ok | few | none
        public string Verdict = "", Where = "", Text = "";
        public int NBefore, NAfter; public double AvgB, AvgA, LowB, LowA, DAvgPct, DLowPct, Spread;
    }

    static class PerfCompare
    {
        public const int NeedEach = 2, QualifySecs = 120;

        public static double Median(List<double> v)
        {
            if (v.Count == 0) return 0;
            List<double> s = new List<double>(v); s.Sort();
            return s.Count % 2 == 1 ? s[s.Count / 2] : (s[s.Count / 2 - 1] + s[s.Count / 2]) / 2;
        }
        static int FieldClass(double f) { return f <= 1.5 ? 0 : f <= 8 ? 1 : f <= 20 ? 2 : 3; }
        static string FieldText(int c, double med) { return c == 0 ? "driving alone" : "with about " + (int)Math.Round(med) + " cars"; }

        // changes that happened one after another with no real drive in between are one tuning session
        public static List<PerfEpisode> Episodes(List<PerfChange> changes, List<PerfRow> rows)
        {
            List<PerfEpisode> eps = new List<PerfEpisode>();
            foreach (PerfChange c in changes)
            {
                PerfEpisode cur = eps.Count > 0 ? eps[eps.Count - 1] : null;
                bool merge = false;
                if (cur != null)
                {
                    merge = c.Ts - cur.End < 1200;
                    if (!merge)
                    {
                        merge = true;
                        foreach (PerfRow r in rows) if (r.Counts && r.Start > cur.End && r.Start < c.Ts) { merge = false; break; }
                    }
                }
                if (!merge) { cur = new PerfEpisode(); cur.Start = c.Ts; cur.Id = c.Id; eps.Add(cur); }
                cur.Items.Add(c); cur.End = c.Ts;
            }
            return eps;
        }

        public static PerfResult Compare(List<PerfEpisode> eps, int idx, List<PerfRow> rows)
        {
            PerfEpisode ep = eps[idx];
            long prevEnd = idx > 0 ? eps[idx - 1].End : 0, nextStart = idx + 1 < eps.Count ? eps[idx + 1].Start : long.MaxValue;
            Dictionary<string, List<PerfRow>> before = new Dictionary<string, List<PerfRow>>(), after = new Dictionary<string, List<PerfRow>>();
            foreach (PerfRow r in rows)
            {
                if (!r.Counts) continue;
                string k = r.TrackKey + "|" + r.Car + "|" + FieldClass(r.Field);
                List<PerfRow> l;
                if (r.End <= ep.Start && r.Start > prevEnd) { if (!before.TryGetValue(k, out l)) { l = new List<PerfRow>(); before[k] = l; } l.Add(r); }
                else if (r.Start >= ep.End && r.Start < nextStart) { if (!after.TryGetValue(k, out l)) { l = new List<PerfRow>(); after[k] = l; } l.Add(r); }
            }
            PerfResult res = new PerfResult();
            string bestK = null; int bestMin = -1, bestSum = -1, richest = -1; string richK = null;
            foreach (KeyValuePair<string, List<PerfRow>> kv in before)
            {
                int nb = Math.Min(8, kv.Value.Count), na = 0; List<PerfRow> la;
                if (after.TryGetValue(kv.Key, out la)) na = Math.Min(8, la.Count);
                int mn = Math.Min(nb, na);
                if (mn > bestMin || (mn == bestMin && nb + na > bestSum)) { bestMin = mn; bestSum = nb + na; bestK = kv.Key; }
                if (nb > richest) { richest = nb; richK = kv.Key; }
            }
            if (bestK == null)
            {
                res.State = "none";
                res.Text = before.Count == 0 ? "No earlier sessions to compare with." : "";
                return res;
            }
            // the sessions of the chosen combination
            List<PerfRow> lBef = before[bestK], lAft = after.ContainsKey(bestK) ? after[bestK] : new List<PerfRow>();
            if (lBef.Count > 8) lBef = lBef.GetRange(lBef.Count - 8, 8);           // the 8 just before
            if (lAft.Count > 8) lAft = lAft.GetRange(0, 8);                      // the 8 just after
            PerfRow any = lBef[lBef.Count - 1];
            List<double> fields = new List<double>(); foreach (PerfRow r in lBef) fields.Add(r.Field); foreach (PerfRow r in lAft) fields.Add(r.Field);
            res.Where = any.Track + (any.Config.Length > 0 ? " \u00b7 " + any.Config : "") + " \u00b7 " + any.Car + " \u00b7 " + FieldText(FieldClass(any.Field), Median(fields));
            res.NBefore = lBef.Count; res.NAfter = lAft.Count;
            if (lBef.Count < NeedEach || lAft.Count < NeedEach)
            {
                // the most useful hint: where to drive next. Prefer the combination with the most earlier sessions
                if (richK != null && richK != bestK && before[richK].Count >= NeedEach)
                {
                    PerfRow r2 = before[richK][before[richK].Count - 1];
                    res.Where = r2.Track + (r2.Config.Length > 0 ? " \u00b7 " + r2.Config : "") + " \u00b7 " + r2.Car;
                    res.NBefore = Math.Min(8, before[richK].Count); res.NAfter = after.ContainsKey(richK) ? Math.Min(8, after[richK].Count) : 0;
                }
                res.State = "few";
                int need = Math.Max(NeedEach - res.NAfter, 0), needB = Math.Max(NeedEach - res.NBefore, 0);
                res.Text = res.NBefore < NeedEach
                    ? "Too few earlier sessions to compare (" + res.NBefore + " of " + NeedEach + ")."
                    : "Too few sessions since the change: " + res.NAfter + ", " + need + " more needed.";
                if (needB > 0 && res.NBefore >= NeedEach) res.Text = "Too few sessions.";
                return res;
            }
            List<double> aB = new List<double>(), aA = new List<double>(), lB = new List<double>(), lA = new List<double>();
            foreach (PerfRow r in lBef) { aB.Add(r.Avg); lB.Add(r.Low1); }
            foreach (PerfRow r in lAft) { aA.Add(r.Avg); lA.Add(r.Low1); }
            res.AvgB = Median(aB); res.AvgA = Median(aA); res.LowB = Median(lB); res.LowA = Median(lA);
            res.DAvgPct = res.AvgB > 0 ? 100 * (res.AvgA - res.AvgB) / res.AvgB : 0;
            res.DLowPct = res.LowB > 0 ? 100 * (res.LowA - res.LowB) / res.LowB : 0;
            double mnB = double.MaxValue, mxB = 0; foreach (double v in aB) { if (v < mnB) mnB = v; if (v > mxB) mxB = v; }
            res.Spread = res.AvgB > 0 && aB.Count >= 2 ? 100 * (mxB - mnB) / res.AvgB : 0;
            double noise = res.Spread / 2;
            bool up = (res.DAvgPct >= 3 && res.DAvgPct > noise) || (res.DLowPct >= 4 && res.DLowPct > noise);
            bool down = (res.DAvgPct <= -3 && -res.DAvgPct > noise) || (res.DLowPct <= -4 && -res.DLowPct > noise);
            string nums = Math.Round(res.AvgB) + " to " + Math.Round(res.AvgA) + " fps on average, 1 % low " + Math.Round(res.LowB) + " to " + Math.Round(res.LowA);
            res.State = "ok";
            if (up && down) { res.Verdict = "mixed"; res.Text = "Mixed: " + nums + "."; }
            else if (up) { res.Verdict = "helped"; res.Text = "Helped: " + nums + "."; }
            else if (down) { res.Verdict = "hurt"; res.Text = "Hurt: " + nums + "."; }
            else { res.Verdict = "same"; res.Text = "No clear change: " + nums + (res.Spread > 0 ? " (normal spread between sessions " + Math.Round(res.Spread) + " %)." : "."); }
            return res;
        }

        public static string ResultJson(PerfResult r)
        {
            return "{\"state\":" + Json_.S(r.State) + ",\"verdict\":" + Json_.S(r.Verdict) + ",\"where\":" + Json_.S(r.Where) + ",\"text\":" + Json_.S(r.Text) +
                   ",\"before\":{\"n\":" + r.NBefore + ",\"avg\":" + Perf.N(r.AvgB, "0.0") + ",\"low1\":" + Perf.N(r.LowB, "0.0") + "},\"after\":{\"n\":" + r.NAfter + ",\"avg\":" + Perf.N(r.AvgA, "0.0") +
                   ",\"low1\":" + Perf.N(r.LowA, "0.0") + "},\"dAvgPct\":" + Perf.N(r.DAvgPct, "0.0") + ",\"dLowPct\":" + Perf.N(r.DLowPct, "0.0") + ",\"wobblePct\":" + Perf.N(r.Spread, "0.0") + "}";
        }
    }

    // ---------------- the JSON the page reads ----------------
    static class PerfJson
    {
        // newest session worth a card (a real drive of a minute or more)
        public static PerfRow LastRow(List<PerfRow> rows)
        {
            for (int i = rows.Count - 1; i >= 0; i--) if (rows[i].Secs >= 60 && rows[i].Avg > 1) return rows[i];
            return null;
        }

        static string Places(string w)
        {
            StringBuilder sb = new StringBuilder("[");
            foreach (string p in (w ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string[] a = p.Split(':'); string[] ft = a[0].Split('-');
                if (a.Length < 6 || ft.Length != 2) continue;
                if (sb.Length > 1) sb.Append(',');
                sb.Append("{\"from\":").Append(ft[0]).Append(",\"to\":").Append(ft[1]).Append(",\"avg\":").Append(a[1]).Append(",\"min\":").Append(a[2]).Append(",\"n\":").Append(a[3]).Append(",\"gpu\":").Append(a[4]).Append(",\"cpu\":").Append(a[5]).Append('}');
            }
            return sb.Append(']').ToString();
        }

        static string Procs(PerfRow r)
        {
            PerfProc p = PerfSampler.ForSession(r);
            if (p == null) return "null";
            StringBuilder o = new StringBuilder("[");
            foreach (PerfOther x in p.Others) { if (o.Length > 1) o.Append(','); o.Append("{\"name\":").Append(Json_.S(x.Name)).Append(",\"avg\":").Append(Perf.N(x.Avg, "0.0")).Append(",\"dip\":").Append(x.Dip >= 0 ? Perf.N(x.Dip, "0.0") : "null").Append('}'); }
            o.Append(']');
            return "{\"samples\":" + p.N + ",\"dips\":" + p.Dips + ",\"sim\":" + Perf.N(p.Sim, "0.0") + ",\"paddock\":" + Perf.N(p.Paddock, "0.0") + ",\"program\":" + Perf.N(p.Irdash, "0.0") + ",\"browser\":" + Perf.N(p.Browser, "0.0") +
                   ",\"overlays\":" + Perf.N(p.Overlays, "0.0") + ",\"crew\":" + Perf.N(p.Crew, "0.0") + ",\"others\":" + o + ",\"usual\":" + (p.Normal > 0 ? Perf.N(p.Normal, "0.0") : "null") + ",\"ctx\":" + Json_.S(p.Ctx) + "}";
        }

        static string Compact(PerfRow r)
        {
            return "{\"file\":" + Json_.S(r.File) + ",\"ts\":" + r.Start * 1000 + ",\"dur\":" + Perf.N(r.Dur, "0") + ",\"secs\":" + Perf.N(r.Secs, "0") + ",\"track\":" + Json_.S(r.Track) + ",\"config\":" + Json_.S(r.Config) +
                   ",\"key\":" + Json_.S(r.TrackKey) + ",\"car\":" + Json_.S(r.Car) + ",\"type\":" + Json_.S(r.Type) + ",\"field\":" + Perf.N2(r.Field) + ",\"cars\":" + (r.Cars >= 0 ? Perf.N(r.Cars, "0.#") : "null") +
                   ",\"avg\":" + Perf.N(r.Avg, "0.0") + ",\"low1\":" + Perf.N(r.Low1, "0.0") + ",\"worst\":" + Perf.N(r.Worst, "0.0") + ",\"dip\":" + Perf.N(r.Dip, "0.0") + ",\"cpu\":" + Perf.N(r.CpuAvg, "0") + ",\"gpu\":" + Perf.N(r.GpuAvg, "0") +
                   ",\"online\":" + Perf.B(r.Online) + ",\"build\":" + Json_.S(r.Build) + ",\"counts\":" + Perf.B(r.Counts) + "}";
        }

        // everything about one session, for the big card
        static string Full(PerfRow r, List<PerfRow> rows)
        {
            double usual = PerfLive.Normal(rows, r.TrackKey, r.Car, r.Field, r.Start);
            return "{\"file\":" + Json_.S(r.File) + ",\"ts\":" + r.Start * 1000 + ",\"dur\":" + Perf.N(r.Dur, "0") + ",\"secs\":" + Perf.N(r.Secs, "0") + ",\"track\":" + Json_.S(r.Track) + ",\"config\":" + Json_.S(r.Config) +
                   ",\"key\":" + Json_.S(r.TrackKey) + ",\"trackName\":" + Json_.S(r.TrackRaw) + ",\"car\":" + Json_.S(r.Car) + ",\"type\":" + Json_.S(r.Type) + ",\"field\":" + Perf.N2(r.Field) + ",\"cars\":" + (r.Cars >= 0 ? Perf.N(r.Cars, "0.#") : "null") +
                   ",\"online\":" + Perf.B(r.Online) + ",\"build\":" + Json_.S(r.Build) + ",\"avg\":" + Perf.N(r.Avg, "0.0") + ",\"low1\":" + Perf.N(r.Low1, "0.0") + ",\"worst\":" + Perf.N(r.Worst, "0.0") +
                   ",\"cap\":" + Perf.N(r.Cap, "0") + ",\"belowPct\":" + Perf.N(r.Below, "0") + ",\"dip\":" + Perf.N(r.Dip, "0.0") + ",\"cpu\":" + Perf.N(r.CpuAvg, "0") + ",\"cpuPeak\":" + Perf.N(r.CpuPeak, "0") +
                   ",\"gpu\":" + Perf.N(r.GpuAvg, "0") + ",\"gpuPeak\":" + Perf.N(r.GpuPeak, "0") + ",\"bg\":" + (r.BgAvg >= 0 ? Perf.N(r.BgAvg, "0") : "null") + ",\"bgPeak\":" + (r.BgPeak >= 0 ? Perf.N(r.BgPeak, "0") : "null") +
                   ",\"verdict\":" + Json_.S(r.Verdict) + ",\"text\":" + Json_.S(PerfText.Verdict(r)) + ",\"usual\":" + (usual > 0 ? Perf.N(usual, "0.0") : "null") +
                   ",\"net\":" + (r.LatAvg >= 0 ? "{\"ping\":" + Perf.N(r.LatAvg, "0") + ",\"pingMax\":" + Perf.N(r.LatMax, "0") + ",\"quality\":" + Perf.N(r.Qual, "0.00") + ",\"partner\":" + Perf.N(r.Partner, "0.00") + "}" : "null") +
                   ",\"memory\":" + (r.PfAvg >= 0 ? "{\"faults\":" + Perf.N(r.PfAvg, "0") + ",\"peak\":" + Perf.N(r.PfPeak, "0") + "}" : "null") +
                   ",\"places\":" + Places(r.Worst3) + ",\"procs\":" + Procs(r) + "}";
        }

        public static string One(string file)
        {
            PerfRow r = PerfStore.Get(file);
            return r == null ? null : Full(r, PerfStore.All());
        }

        public static string Status()
        {
            List<PerfRow> rows = PerfStore.All(); int counted = 0, empty = 0;
            foreach (PerfRow r in rows) { if (r.Counts) counted++; if (r.Secs < 1) empty++; }
            string[] files = new string[0];
            try { if (TrackMaps.TelemetryDir != null && Directory.Exists(TrackMaps.TelemetryDir)) files = Directory.GetFiles(TrackMaps.TelemetryDir, "*.ibt"); } catch { }
            int dup = 0; HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase); foreach (PerfRow r in rows) if (!seen.Add(r.File)) dup++;
            return "{\"state\":" + Json_.S(PerfReports.State) + ",\"files\":" + files.Length + ",\"reports\":" + rows.Count + ",\"counted\":" + counted + ",\"empty\":" + empty + ",\"duplicates\":" + dup +
                   ",\"waiting\":" + PerfReports.Waiting + ",\"pending\":" + PerfReports.Pending + ",\"added\":" + PerfReports.Reported + ",\"failed\":" + PerfReports.Failed +
                   ",\"changes\":" + PerfChanges.All().Count + ",\"sampler\":" + PerfSampler.StatusJson() + ",\"prio\":" + PerfPrio.Json() + "}";
        }

        static string Own(List<PerfRow> rows)
        {
            List<PerfProc> all = PerfSampler.All();
            int n = Math.Min(10, all.Count);
            double paddock = 0, program = 0, browser = 0, overlays = 0, crew = 0, sim = 0;
            for (int i = all.Count - n; i < all.Count; i++) { PerfProc p = all[i]; paddock += p.Paddock; program += p.Irdash; browser += p.Browser; overlays += p.Overlays; crew += p.Crew; sim += p.Sim; }
            if (n == 0) return "{\"drives\":0,\"sampler\":" + PerfSampler.StatusJson() + "}";
            return "{\"drives\":" + n + ",\"paddock\":" + Perf.N(paddock / n, "0.0") + ",\"program\":" + Perf.N(program / n, "0.0") + ",\"browser\":" + Perf.N(browser / n, "0.0") + ",\"overlays\":" + Perf.N(overlays / n, "0.0") +
                   ",\"crew\":" + Perf.N(crew / n, "0.0") + ",\"sim\":" + Perf.N(sim / n, "0.0") + ",\"sampler\":" + PerfSampler.StatusJson() + "}";
        }

        public static string Overview()
        {
            List<PerfRow> rows = PerfStore.All();
            List<PerfEpisode> eps = PerfCompare.Episodes(PerfChanges.All(), rows);
            PerfRow last = LastRow(rows);
            StringBuilder sb = new StringBuilder(40000);
            sb.Append("{\"ready\":").Append(Perf.B(last != null)).Append(",\"now\":").Append(Perf.Now()).Append(",\"status\":").Append(Status());
            sb.Append(",\"last\":").Append(last == null ? "null" : Full(last, rows));
            sb.Append(",\"sessions\":[");
            bool first = true; int hidden = 0;
            foreach (PerfRow r in rows)
            {
                if (r.Secs < 30 || r.Avg <= 1) { hidden++; continue; }
                if (!first) sb.Append(','); first = false;
                sb.Append(Compact(r));
            }
            sb.Append("],\"hidden\":").Append(hidden).Append(",\"changes\":[");
            for (int i = eps.Count - 1; i >= 0; i--)
            {
                PerfEpisode e = eps[i];
                sb.Append("{\"id\":").Append(Json_.S(e.Id)).Append(",\"ts\":").Append(e.Start * 1000).Append(",\"end\":").Append(e.End * 1000).Append(",\"title\":").Append(Json_.S(e.Title)).Append(",\"detail\":").Append(Json_.S(e.Detail)).Append(",\"kinds\":[");
                List<string> kinds = e.Kinds(); for (int k = 0; k < kinds.Count; k++) { if (k > 0) sb.Append(','); sb.Append(Json_.S(kinds[k])); }
                sb.Append("],\"items\":[");
                for (int k = 0; k < e.Items.Count; k++) { PerfChange c = e.Items[k]; if (k > 0) sb.Append(','); sb.Append("{\"ts\":").Append(c.Ts * 1000).Append(",\"kind\":").Append(Json_.S(c.Kind)).Append(",\"title\":").Append(Json_.S(c.Title)).Append(",\"detail\":").Append(Json_.S(c.Detail)).Append('}'); }
                sb.Append("],\"result\":").Append(PerfCompare.ResultJson(PerfCompare.Compare(eps, i, rows))).Append('}');
                if (i > 0) sb.Append(',');
            }
            sb.Append("],\"own\":").Append(Own(rows)).Append(",\"summary\":").Append(Json_.S(Perf.Summary())).Append('}');
            return sb.ToString();
        }
    }

    // ---------------- F4: the optimisation checklist (measured items only; Windows and iRacing are only looked at) ----------------
    sealed class PerfItem
    {
        public string Id, Title, State = "ok", Evidence = "", Say = "", Tool = "", Undo = ""; public bool Auto;     // State: ok | look | info
        public PerfItem(string id, string title) { Id = id; Title = title; }
        public string Json()
        {
            return "{\"id\":" + Json_.S(Id) + ",\"title\":" + Json_.S(Title) + ",\"state\":" + Json_.S(State) + ",\"evidence\":" + Json_.S(Evidence) + ",\"say\":" + Json_.S(Say) +
                   ",\"tool\":" + Json_.S(Tool) + ",\"undo\":" + Json_.S(Undo) + ",\"auto\":" + Perf.B(Auto) + "}";
        }
    }

    static class PerfCheck
    {
        static readonly object gate = new object();
        static List<PerfItem> cached; static DateTime cachedAt = DateTime.MinValue;

        static string P(double v) { return ((int)Math.Round(v)).ToString(Perf.Inv); }
        // 456 % of one core is 4.6 cores (the sim uses many threads)
        static string Cores(double pct) { return pct >= 100 ? (pct / 100).ToString("0.0", Perf.Inv) + " cores (all its threads together)" : P(pct) + " % of one core"; }

        public static List<PerfItem> Items()
        {
            lock (gate)
            {
                if (cached != null && (DateTime.Now - cachedAt).TotalSeconds < 20) return cached;
                List<PerfItem> l;
                try { l = Build(); } catch (Exception ex) { Log.W("perf: checklist: " + ex.Message); l = new List<PerfItem>(); }
                cached = l; cachedAt = DateTime.Now; return l;
            }
        }

        // things Peter could do something about (what Paddock handles itself is not counted)
        public static int AttentionCount() { int n = 0; foreach (PerfItem i in Items()) if (i.State == "look" && !i.Auto) n++; return n; }

        public static string Json()
        {
            StringBuilder sb = new StringBuilder("{\"items\":[");
            List<PerfItem> l = Items();
            for (int i = 0; i < l.Count; i++) { if (i > 0) sb.Append(','); sb.Append(l[i].Json()); }
            return sb.Append("],\"look\":").Append(AttentionCount()).Append(",\"at\":").Append(Perf.Now()).Append('}').ToString();
        }

        static List<PerfItem> Build()
        {
            List<PerfItem> l = new List<PerfItem>();
            List<PerfRow> rows = PerfStore.All();
            List<PerfProc> all = PerfSampler.All();
            List<PerfProc> recent = all.Count > 10 ? all.GetRange(all.Count - 10, 10) : all;

            // ---- ours ----
            PerfItem a = new PerfItem("paddock", "Paddock's own programs"); a.Auto = true;
            if (recent.Count == 0) { a.State = "info"; a.Evidence = "Not measured yet."; }
            else
            {
                double pad = 0, ovl = 0, sim = 0, prog = 0, brw = 0;
                foreach (PerfProc p in recent) { pad += p.Paddock; ovl += p.Overlays; sim += p.Sim; prog += p.Irdash; brw += p.Browser; }
                int n = recent.Count; pad /= n; ovl /= n; sim /= n; prog /= n; brw /= n;
                a.Evidence = "Last " + n + (n == 1 ? " drive" : " drives") + ": dashboard " + P(prog) + " % of one core, browser " + P(brw) + " %, overlays " + P(ovl) + " %, sim " + Cores(sim) + ".";
                if (pad + ovl >= 60) { a.State = "look"; a.Say = "Heavy for background programs."; }
            }
            l.Add(a);
            l.Add(PerfPrio.Item());

            PerfItem cc = new PerfItem("crew", "CrewChief");
            cc.State = "info";
            if (recent.Count == 0) cc.Evidence = "Left alone on purpose: its spotter calls must stay on time.";
            else { double c = 0; foreach (PerfProc p in recent) c += p.Crew; cc.Evidence = "Used " + P(c / recent.Count) + " % of one core. Left alone on purpose: its spotter calls must stay on time."; }
            l.Add(cc);

            // ---- other programs when the frame rate dipped ----
            PerfItem o = new PerfItem("others", "Other programs during dips");
            int dipDrives = 0; Dictionary<string, int> cnt = new Dictionary<string, int>(); Dictionary<string, double> peak = new Dictionary<string, double>();
            foreach (PerfProc p in recent)
            {
                if (p.Dips < 1) continue;
                dipDrives++;
                foreach (PerfOther x in p.Others)
                    if (x.Dip >= 10 && x.Dip - x.Avg >= 5)
                    {
                        int c; cnt.TryGetValue(x.Name, out c); cnt[x.Name] = c + 1;
                        double pk; peak.TryGetValue(x.Name, out pk); if (x.Dip > pk) peak[x.Name] = x.Dip;
                    }
            }
            string top = null; int topN = 0; foreach (KeyValuePair<string, int> kv in cnt) if (kv.Value > topN) { topN = kv.Value; top = kv.Key; }
            if (recent.Count == 0) { o.State = "info"; o.Evidence = "Not measured yet."; }
            else if (dipDrives == 0) o.Evidence = "No dips in the last " + recent.Count + (recent.Count == 1 ? " drive." : " drives.");
            else if (top != null && topN >= 2 && topN * 2 >= dipDrives)
            {
                o.State = "look"; o.Evidence = top + " busy during dips in " + topN + " of the last " + dipDrives + " dipping drives (up to " + P(peak[top]) + " % of one core).";
                o.Say = "Close " + top + " before a race.";
            }
            else o.Evidence = "Nothing else stood out during dips (" + dipDrives + (dipDrives == 1 ? " drive" : " drives") + " with dips).";
            l.Add(o);

            PerfItem od = new PerfItem("onedrive", "OneDrive");
            double odAvg = 0, odPeak = 0; int odN = 0;
            foreach (PerfProc p in recent) foreach (PerfOther x in p.Others) if (x.Name == "OneDrive") { odAvg += x.Avg; odN++; if (x.Dip > odPeak) odPeak = x.Dip; if (x.Avg > odPeak) odPeak = x.Avg; }
            if (recent.Count == 0) { od.State = "info"; od.Evidence = "Not measured yet."; }
            else if (odN == 0) od.Evidence = "OneDrive not busy in the last " + recent.Count + (recent.Count == 1 ? " drive." : " drives.");
            else
            {
                od.Evidence = "OneDrive busy in " + odN + " of the last " + recent.Count + " drives (about " + P(odAvg / odN) + " % of one core, up to " + P(odPeak) + " %).";
                if (odPeak >= 25) { od.State = "look"; od.Say = "Pause OneDrive syncing for 2 hours before long races."; }
            }
            l.Add(od);

            // ---- Windows (read only; the tools are for Peter to run himself) ----
            PerfItem pw = new PerfItem("power", "Windows power plan");
            string plan = PerfWin.PowerPlan();
            if (plan == "High performance" || plan == "Ultimate performance") pw.Evidence = "Windows is on the " + plan + " plan.";
            else { pw.State = "look"; pw.Evidence = "Windows is on " + (plan == "unknown" ? "a plan Paddock cannot read" : "the " + plan + " plan") + ", which can hold the processor back."; pw.Say = "Double-click RIG TUNE.cmd in the Paddock folder (UNDO rig tune.cmd puts it back)."; }
            l.Add(pw);

            PerfItem gm = new PerfItem("gamemode", "Windows Game Mode");
            if (PerfWin.GameMode() == "0") { gm.State = "look"; gm.Evidence = "Game Mode is off."; gm.Say = "Double-click RIG TUNE.cmd in the Paddock folder (UNDO rig tune.cmd puts it back)."; }
            else gm.Evidence = "Game Mode is on.";
            l.Add(gm);

            PerfItem gb = new PerfItem("gamebar", "Xbox Game Bar background recording");
            if (PerfWin.GameDvr() == "1" || PerfWin.GameCapture() == "1")
            { gb.State = "look"; gb.Evidence = "Windows can record game video in the background, which costs graphics-card time."; gb.Tool = "perf-gamebar-off.cmd"; gb.Undo = "perf-gamebar-off-UNDO.cmd"; gb.Say = "Double-click perf-gamebar-off.cmd in the tools folder."; }
            else gb.Evidence = "Background recording is off.";
            l.Add(gb);

            PerfItem hg = new PerfItem("hags", "Hardware GPU scheduling"); hg.State = "info";
            string hags = PerfWin.Hags();
            if (hags == "on") { hg.Evidence = "On."; hg.Tool = "perf-hags-off.cmd"; hg.Undo = "perf-hags-off-UNDO.cmd"; hg.Say = "To try it off: run perf-hags-off.cmd and restart the PC."; }
            else if (hags == "off") { hg.Evidence = "Off."; hg.Tool = "perf-hags-on.cmd"; hg.Undo = "perf-hags-on-UNDO.cmd"; hg.Say = "To try it on: run perf-hags-on.cmd and restart the PC."; }
            else hg.Evidence = hags == "not supported" ? "Not supported by this graphics card." : "Setting not readable.";
            l.Add(hg);

            l.Add(Graphics());

            // ---- what the telemetry itself says ----
            PerfItem mem = new PerfItem("memory", "Memory");
            List<PerfRow> counted = new List<PerfRow>(); for (int i = rows.Count - 1; i >= 0 && counted.Count < 5; i--) if (rows[i].Counts && rows[i].PfAvg >= 0) counted.Add(rows[i]);
            if (counted.Count == 0) { mem.State = "info"; mem.Evidence = "No memory figures in the recent sessions."; }
            else
            {
                double f = 0, pk = 0; foreach (PerfRow r in counted) { f += r.PfAvg; if (r.PfPeak > pk) pk = r.PfPeak; }
                f /= counted.Count;
                if (f >= 50) { mem.State = "look"; mem.Evidence = "Memory fetched from disk " + P(f) + " times a second on average (peak " + P(pk) + "), last " + counted.Count + " sessions."; mem.Say = "Close browsers and big programs before a race."; }
                else mem.Evidence = "Memory fetched from disk " + P(f) + " times a second on average, last " + counted.Count + " sessions.";
            }
            l.Add(mem);

            List<PerfRow> online = new List<PerfRow>(); for (int i = rows.Count - 1; i >= 0 && online.Count < 5; i--) if (rows[i].Counts && rows[i].Online && rows[i].LatAvg >= 0) online.Add(rows[i]);
            if (online.Count > 0)
            {
                PerfItem net = new PerfItem("network", "Connection (online sessions)");
                double lat = 0, q = 0; foreach (PerfRow r in online) { lat += r.LatAvg; q += r.Qual >= 0 ? r.Qual : 1; }
                lat /= online.Count; q /= online.Count;
                net.Evidence = "Ping " + P(lat) + " ms, connection " + P(q * 100) + " %, last " + online.Count + " online " + (online.Count == 1 ? "session." : "sessions.");
                if (lat >= 100 || q < 0.9) { net.State = "look"; net.Say = "A wired connection helps."; }
                l.Add(net);
            }

            string drv = PerfChanges.StateValue("driver");
            if (drv.Length > 0)
            {
                PerfItem d = new PerfItem("driver", "NVIDIA graphics driver"); d.State = "info";
                d.Evidence = "Driver " + drv + ".";
                foreach (PerfChange c in PerfChanges.All()) if (c.Kind == "driver") d.Evidence += " Updated " + new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(c.Ts).ToLocalTime().ToString("d MMM", Perf.Inv) + " (" + c.Detail + ").";
                l.Add(d);
            }

            PerfItem sm = new PerfItem("sampler", "Paddock's frame-rate sampler");
            if (PerfSampler.Ticks == 0 && all.Count == 0) { sm.State = "info"; sm.Evidence = "Not run yet: it only works while the sim is running."; }
            else
            {
                double ms = PerfSampler.Ticks > 0 ? PerfSampler.CostCpuMs / PerfSampler.Ticks : 0, wall = PerfSampler.SimRunning ? (DateTime.Now - PerfSampler.RunStart).TotalMilliseconds : PerfSampler.RunWallMs;
                double pc = wall > 0 && PerfSampler.Ticks > 0 ? PerfSampler.CostCpuMs / wall * 100 : 0;
                sm.Evidence = PerfSampler.Ticks > 0 ? "Costs " + ms.ToString("0.0", Perf.Inv) + " ms of processor time every 5 seconds: " + pc.ToString("0.000", Perf.Inv) + " % of one core while the sim runs. (Budget: 0.2 %.)" : "No sample taken in this run of Paddock yet.";
                if (pc > 0.2) { sm.State = "look"; sm.Say = "That is more than planned; tell Claude."; }
            }
            l.Add(sm);
            return l;
        }

        // ---- iRacing graphics: drift from the settled setup (read only; iRacing's file is never written) ----
        static string Get(Dictionary<string, string> d, string k) { string v; return d.TryGetValue(k, out v) ? v : "?"; }

        static PerfItem Graphics()
        {
            PerfItem it = new PerfItem("graphics", "iRacing graphics (compared, never changed)");
            string cur = PerfChanges.CurrentIni;
            if (!File.Exists(cur)) { it.State = "info"; it.Evidence = "iRacing's graphics file was not found."; return it; }
            Dictionary<string, string> now = PerfChanges.GfxOptions(cur);
            string baseFile = Path.Combine(Perf.Dir, "perf-gfx-baseline.tsv");
            // the settled setup of 2026-10-09 (about 104 fps in a 23-car race): frame limit 160, Reflex off, 4 mirrors at high detail, 2 pre-rendered frames
            bool settled = Get(now, "LimitFrameRate") == "1" && Get(now, "DesiredFPSLimit") == "160" && Get(now, "NvReflexMode") == "0" && Get(now, "MaxCockpitMirrors") == "4" && Get(now, "MirrorDetail") == "1" && Get(now, "MaxPreRenderedFrames") == "2";
            if (!File.Exists(baseFile) && settled)
            {
                StringBuilder sb = new StringBuilder();
                foreach (KeyValuePair<string, string> kv in now) sb.Append(kv.Key).Append('\t').Append(kv.Value).Append("\r\n");
                try { File.WriteAllText(baseFile, sb.ToString(), new UTF8Encoding(false)); Log.W("perf: remembered your settled graphics setup (" + now.Count + " values) in perf-gfx-baseline.tsv"); } catch { }
            }
            if (!File.Exists(baseFile))
            {
                it.State = "look";
                it.Evidence = "Not the settled setup: frame limit " + Get(now, "DesiredFPSLimit") + ", Reflex " + (Get(now, "NvReflexMode") == "0" ? "off" : "on") + ", " + Get(now, "MaxCockpitMirrors") + " mirrors, " + Get(now, "MaxPreRenderedFrames") + " pre-rendered frames (settled: 160, off, 4, 2).";
                it.Say = "Ask Claude to check iRacing's graphics.";
                return it;
            }
            Dictionary<string, string> b = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string line in File.ReadAllLines(baseFile, Encoding.UTF8)) { int t = line.IndexOf('\t'); if (t > 0) b[line.Substring(0, t)] = line.Substring(t + 1); }
            List<string> d = new List<string>(); int total = 0;
            foreach (KeyValuePair<string, string> kv in b)
            {
                string v; if (PerfChanges.IgnoredKey(kv.Key) || !now.TryGetValue(kv.Key, out v) || v == kv.Value) continue;
                total++;
                if (d.Count < 4) d.Add(PerfChanges.Label(kv.Key) + " is " + v + " (settled: " + kv.Value + ")");
            }
            if (total == 0) it.Evidence = "Matches the settled setup (" + b.Count + " values compared).";
            else
            {
                it.State = "look"; it.Evidence = string.Join("; ", d.ToArray()) + (total > d.Count ? " (+" + (total - d.Count) + " more)" : "") + ".";
                it.Say = "Ask Claude to put them back.";
            }
            return it;
        }
    }

    // ---------------- the one automatic fix that is ours: lower our own background programs during a session - only if it helps ----------------
    // Mode: watch (nothing lowered; waiting for evidence that it would matter) -> trial (lowered; sessions are compared with the ones before)
    //       -> kept (the comparison said it helped) or rejected (it did not: back to normal, and not tried again).
    // Only irdashies (the overlays) and the browser the dashboard runs in. CrewChief, the sim and anything else are never touched.
    static class PerfPrio
    {
        static string file; static readonly object gate = new object();
        public static string Mode = "watch"; static long since; static string markerId = "", reason = "";
        public static volatile bool Active;
        static readonly Dictionary<int, KeyValuePair<string, ProcessPriorityClass>> was = new Dictionary<int, KeyValuePair<string, ProcessPriorityClass>>();
        const double GateCores = 50;     // overlays + Paddock together must use this much of one core (percent) before it is worth trying

        public static void Init(string dir)
        {
            file = Path.Combine(dir, "perf-prio.tsv");
            try
            {
                if (File.Exists(file))
                    foreach (string line in File.ReadAllLines(file, Encoding.UTF8))
                    {
                        int t = line.IndexOf('\t'); if (t <= 0) continue;
                        string k = line.Substring(0, t), v = line.Substring(t + 1);
                        if (k == "mode" && (v == "watch" || v == "trial" || v == "kept" || v == "rejected" || v == "off")) Mode = v;     // "off" (put there by hand): never try it
                        else if (k == "since") long.TryParse(v, out since);
                        else if (k == "marker") markerId = v;
                        else if (k == "reason") reason = v;
                    }
            }
            catch { }
        }

        static void Save()
        {
            try { File.WriteAllText(file, "mode\t" + Mode + "\r\nsince\t" + since + "\r\nmarker\t" + markerId + "\r\nreason\t" + reason.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ') + "\r\n", new UTF8Encoding(false)); } catch { }
        }

        public static string Json()
        {
            return "{\"mode\":" + Json_.S(Mode) + ",\"active\":" + Perf.B(Active) + ",\"since\":" + since + ",\"reason\":" + Json_.S(reason) + "}";
        }

        public static PerfItem Item()
        {
            PerfItem it = new PerfItem("lowprio", "Lower our own programs' priority during sessions"); it.Auto = true; it.State = "info";
            switch (Mode)
            {
                case "trial": it.Evidence = "On trial since " + When() + ": overlays and the dashboard browser at low priority while the sim runs; kept only if the numbers improve. " + reason; break;
                case "kept": it.State = "ok"; it.Evidence = "On. The comparison showed it helps. " + reason; break;
                case "rejected": it.Evidence = "Tried and switched off: no measurable gain. " + reason; break;
                case "off": it.Evidence = "Switched off by hand (mode off in data\\perf-prio.tsv); Paddock will not try it."; break;
                default: it.Evidence = reason.Length > 0 ? reason : "Off."; break;
            }
            return it;
        }

        static string When() { return new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(since).ToLocalTime().ToString("d MMM", Perf.Inv); }

        // called when new reports arrive and every few minutes
        public static void Evaluate()
        {
            lock (gate)
            {
                if (Mode == "watch")
                {
                    List<PerfProc> all = PerfSampler.All(); int n = Math.Min(5, all.Count);
                    if (n < 3) { reason = "Waiting for at least 3 measured drives (have " + all.Count + ")."; return; }
                    double use = 0; for (int i = all.Count - n; i < all.Count; i++) use += all[i].Paddock + all[i].Overlays;
                    use /= n;
                    if (use < GateCores) { string r = "Not needed: Paddock and the overlays together use only " + (int)Math.Round(use) + " % of one core (the trial starts at " + (int)GateCores + " %)."; if (r != reason) { reason = r; Save(); } return; }
                    Mode = "trial"; since = Perf.Now(); markerId = "prio:" + since; reason = "Paddock and the overlays use " + (int)Math.Round(use) + " % of one core.";
                    PerfChanges.AddExternal(markerId, since, "paddock", "Paddock programs now run at low priority during sessions", "overlays and the dashboard browser");
                    Save();
                    Log.W("perf: priority trial started - " + reason);
                }
                else if (Mode == "trial")
                {
                    List<PerfRow> rows = PerfStore.All(); List<PerfEpisode> eps = PerfCompare.Episodes(PerfChanges.All(), rows);
                    for (int i = 0; i < eps.Count; i++)
                    {
                        bool mine = false; foreach (PerfChange c in eps[i].Items) if (c.Id == markerId) mine = true;
                        if (!mine) continue;
                        PerfResult r = PerfCompare.Compare(eps, i, rows);
                        if (r.State != "ok" || r.NBefore < 3 || r.NAfter < 3) return;      // wait for 3 like-for-like sessions each side
                        if (r.Verdict == "helped") { Mode = "kept"; reason = r.Text; Log.W("perf: low priority kept - " + r.Text); }
                        else
                        {
                            Mode = "rejected"; reason = r.Text; Restore();
                            PerfChanges.AddExternal("prio-off:" + Perf.Now(), Perf.Now(), "paddock", "Paddock programs back to normal priority", "the trial showed no gain");
                            Log.W("perf: low priority switched off again - " + r.Text);
                        }
                        Save();
                        return;
                    }
                }
            }
        }

        public static void OnSimStart() { if (Mode == "trial" || Mode == "kept") Lower(); }
        public static void OnSimEnd() { Restore(); }
        public static void Maintain() { if (Active) Lower(); }      // overlays restarted during the session start low as well

        static void Lower()
        {
            List<Process> targets = new List<Process>();
            try { targets.AddRange(Process.GetProcessesByName("irdashies")); } catch { }
            foreach (int pid in PerfSampler.DashBrowserPids()) { try { targets.Add(Process.GetProcessById(pid)); } catch { } }
            foreach (Process p in targets)
            {
                try
                {
                    lock (gate)
                    {
                        ProcessPriorityClass cur = p.PriorityClass;
                        if (!was.ContainsKey(p.Id)) was[p.Id] = new KeyValuePair<string, ProcessPriorityClass>(p.ProcessName, cur);
                        if (cur == ProcessPriorityClass.Normal) p.PriorityClass = ProcessPriorityClass.BelowNormal;
                    }
                }
                catch { }
                finally { p.Dispose(); }
            }
            if (!Active) Log.W("perf: our own programs set to low priority for this session (" + targets.Count + " programs)");
            Active = true;
        }

        static void Restore()
        {
            lock (gate)
            {
                foreach (KeyValuePair<int, KeyValuePair<string, ProcessPriorityClass>> kv in was)
                {
                    try { using (Process p = Process.GetProcessById(kv.Key)) if (p.ProcessName == kv.Value.Key && p.PriorityClass == ProcessPriorityClass.BelowNormal) p.PriorityClass = kv.Value.Value; } catch { }
                }
                if (was.Count > 0 || Active) Log.W("perf: our own programs back to their usual priority");
                was.Clear(); Active = false;
            }
        }

        // for tests: the same lowering on a stand-in program (name irdash-test-...)
        public static string SetNamed(string name, bool low)
        {
            string res = "";
            foreach (Process p in Process.GetProcessesByName(name))
                using (p)
                {
                    try
                    {
                        ProcessPriorityClass cur = p.PriorityClass;
                        if (low) { if (!was.ContainsKey(p.Id)) was[p.Id] = new KeyValuePair<string, ProcessPriorityClass>(p.ProcessName, cur); if (cur == ProcessPriorityClass.Normal) p.PriorityClass = ProcessPriorityClass.BelowNormal; }
                        else { KeyValuePair<string, ProcessPriorityClass> w; if (was.TryGetValue(p.Id, out w)) { p.PriorityClass = w.Value; was.Remove(p.Id); } }
                        res += p.Id + ":" + p.PriorityClass + " ";
                    }
                    catch (Exception ex) { res += p.Id + ":" + ex.Message + " "; }
                }
            return res.Trim();
        }
    }

    // ---------------- routes only for tests\perf-test.ps1 ----------------
    static class PerfTest
    {
        public static string Route(string path, Dictionary<string, string> q, out int code)
        {
            code = 200; string v;
            if (path == "/perf/test/friendly")        // pure naming, harmless
            {
                q.TryGetValue("name", out v);
                return "{\"group\":" + Json_.S(PerfSampler.GroupOf(v ?? "", 0, "iRacingSim64DX11")) + "}";
            }
            if (!Sdk.TestHook)
            {
                string busy = Sdk.RealBusy();
                if (busy != null) { Log.W("perf: test route refused: " + busy); code = 409; return "{\"error\":" + Json_.S("refused: " + busy) + "}"; }
                code = 404; return "{\"error\":\"not found\"}";
            }
            switch (path)
            {
                case "/perf/test/drives":
                    {
                        StringBuilder sb = new StringBuilder("[");
                        foreach (PerfProc p in PerfSampler.Test())
                        {
                            if (sb.Length > 1) sb.Append(',');
                            sb.Append("{\"samples\":").Append(p.N).Append(",\"dips\":").Append(p.Dips).Append(",\"avgFps\":").Append(Perf.N(p.AvgFps, "0.0")).Append(",\"sim\":").Append(Perf.N(p.Sim, "0.0")).Append(",\"paddock\":").Append(Perf.N(p.Paddock, "0.0"))
                              .Append(",\"normal\":").Append(Perf.N(p.Normal, "0.0")).Append(",\"others\":").Append(Json_.S(p.OthersRaw)).Append('}');
                        }
                        return sb.Append(']').ToString();
                    }
                case "/perf/test/clear": PerfSampler.ClearTest(); return "{\"ok\":true}";
                case "/perf/test/prio":
                    {
                        string name, mode; q.TryGetValue("name", out name); q.TryGetValue("mode", out mode);
                        if (!Regex.IsMatch(name ?? "", "^irdash-test-[a-z0-9-]{1,20}$")) { code = 400; return "{\"error\":\"name\"}"; }
                        return "{\"result\":" + Json_.S(PerfPrio.SetNamed(name, mode == "low")) + "}";
                    }
            }
            code = 404; return "{\"error\":\"not found\"}";
        }
    }
}
