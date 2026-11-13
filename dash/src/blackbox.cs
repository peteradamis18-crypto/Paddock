// The black box (W0-9, docs\rework\PLAN.md 4.5, evidence 05): Peter's worst freeze (12 Nov, Road Atlanta, lap 9) had no known
// cause because nothing kept per-second numbers. While the sim runs this writes one row a second to
// data\blackbox\<sim start>.tsv; when the frame rate drops 25 % against the last 5 s it writes ten rows a second for 15 s and one
// "snapshot" line (busiest programs, GPU, disk). After the race the rows give one plain sentence: lap, place, how long, likely cause.
// It only reads: the SDK frame irdash already has, Windows' CPU and disk counters, the programs' CPU times. Its own thread at
// BelowNormal, nothing on the UI or render path. Files are kept 8 weeks. NVML (GPU clock, temperature, throttle) is wave 5 (W5-3):
// the gpu* columns are there, empty, so the file layout does not change when it lands.
// Wiring (perf.cs, or a test harness): Running, ReadSdk, GroupOf, Dir, Drives; the modules call BlackBox.Event("clip cut start").
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace IRDash
{
    // the numbers one row takes from the SDK frame
    sealed class BbSdk { public bool Connected; public double SessTime, Lap = -1, Pct = -1, Speed, Fps, CpuFG, CpuBG, Gpu, PageFaults; }

    // what the cause rules look at for one freeze
    sealed class BbDip
    {
        public double Gpu = -1, Cpu = -1, PageFaults = -1;                 // SDK shares of the frame (1 = 100 %), page faults a second
        public List<string> Programs = new List<string>();                 // busiest programs at the dip ...
        public List<double> Now = new List<double>(), Usual = new List<double>();   // ... their CPU (% of one core) then and over the session
        public List<string> Paddock = new List<string>();                  // our own work in the 3 s before (cut, save, scan, job)
    }

    // one freeze found in a black box file
    sealed class BbFreeze { public double At, Lap = -1, Pct = -1, Len, Worst, Avg; public string Cause = ""; }

    static class BlackBox
    {
        // ---- wiring ----
        public static Func<bool> Running;                    // the sim program is running (RigState.SimRunning once W0-2 lands)
        public static Func<BbSdk> ReadSdk;                   // the latest SDK frame
        public static Func<string, int, string> GroupOf;     // program name + pid -> friendly group ("Coach Dave Delta", "Paddock (dashboard program)")
        public static Func<bool> IsTest;                     // a pretend session: rows go to blackbox\test, never next to the real ones
        public static string Dir, SimGroup = "iRacing sim";
        public static string[] Drives = new string[0];       // "C:" etc.: the drives holding the vault and the sim
        public static bool SelfScan;                         // look at the programs every 5 s itself (tests); in irdash PerfSampler hands its 5 s look over

        public const int KeepDays = 56, FastSeconds = 15, FastMs = 100;
        public const double FastDrop = 0.25;
        internal static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public const string Header = "# t\tsessTime\tlap\tlapPct\tspeed\tfps\tcpuFG\tcpuBG\tgpu\tpageFaults\tcpuTotal\ttop1\ttop1Pct\ttop2\ttop2Pct\ttop3\ttop3Pct\tdiskQueue\tdiskWriteMs\tevents\tgpuLoad\tgpuClock\tgpuTemp\tgpuThrottle";
        public const string SnapHeader = "# snapshot\tt\tfps\tavg5\tgpu\tcpuFG\tpageFaults\tdiskQueue\tdiskWriteMs\tprograms(name=now/usual)\tpaddock";

        // ---- state (the black box thread only, unless marked) ----
        static readonly object gate = new object();         // events, groups, status
        static readonly List<string> pending = new List<string>();
        static readonly List<KeyValuePair<DateTime, string>> recentEv = new List<KeyValuePair<DateTime, string>>();
        static Dictionary<string, double> groups = new Dictionary<string, double>();     // the latest look at the programs (% of one core)
        static readonly Dictionary<string, double[]> usual = new Dictionary<string, double[]>();   // program -> {sum, count} outside the fast mode
        static int usualLooks;
        static Thread th; static volatile bool stop;
        static StreamWriter w; static string file = "";
        static readonly List<double> last5 = new List<double>();
        static DateTime lastSecond = DateTime.MinValue, fastUntil = DateTime.MinValue, snapAt = DateTime.MinValue, lastScan = DateTime.MinValue, lastPrune = DateTime.MinValue;
        static double lastLap = -1, snapFps, snapAvg;
        static long sysIdle0, sysTotal0;
        static List<PerformanceCounter> diskQ = new List<PerformanceCounter>(), diskW = new List<PerformanceCounter>();
        // cost (read by the status JSON and the test)
        public static long Rows, FastRows, Snapshots, Bytes; public static double CostCpuMs, RunWallMs;
        static DateTime runStart = DateTime.MinValue;

        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool GetThreadTimes(IntPtr h, out long create, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
        static long ThreadCpu() { long c, e, k, u; return GetThreadTimes(GetCurrentThread(), out c, out e, out k, out u) ? k + u : 0; }   // 100 ns units

        public static void Start()
        {
            if (th != null) return;
            stop = false;
            th = new Thread(Loop); th.IsBackground = true; th.Priority = ThreadPriority.BelowNormal; th.Name = "black box"; th.Start();
        }
        public static void Stop() { stop = true; Thread t = th; if (t != null) t.Join(3000); th = null; }

        // ---- what the rest of Paddock calls ----
        // our own work, written into the next row ("clip cut start lap 9", "session file save", "vault scan"). Cheap; any thread.
        public static void Event(string what)
        {
            if (string.IsNullOrEmpty(what)) return;
            string s = what.Replace('\t', ' ').Replace(';', ',').Replace('\r', ' ').Replace('\n', ' ');
            lock (gate)
            {
                if (pending.Count < 50) pending.Add(s);
                recentEv.Add(new KeyValuePair<DateTime, string>(DateTime.Now, s));
                while (recentEv.Count > 0 && (DateTime.Now - recentEv[0].Key).TotalSeconds > 30) recentEv.RemoveAt(0);
            }
        }

        // PerfSampler's 5 s look at every program (% of one core per group): the black box does not look twice
        public static void Procs(Dictionary<string, double> g)
        {
            if (g == null || SelfScan) return;
            lock (gate) { groups = new Dictionary<string, double>(g); AddUsual(g); }
        }

        static void AddUsual(Dictionary<string, double> g)
        {
            if (DateTime.Now < fastUntil) return;            // the session's usual: not counting the dips themselves
            usualLooks++;
            foreach (KeyValuePair<string, double> kv in g) { double[] a; if (!usual.TryGetValue(kv.Key, out a)) { a = new double[2]; usual[kv.Key] = a; } a[0] += kv.Value; }
        }
        static double UsualOf(string name) { double[] a; return usualLooks > 0 && usual.TryGetValue(name, out a) ? a[0] / usualLooks : 0; }

        public static string StatusJson()
        {
            double wall = RunWallMs;
            return "{\"recording\":" + (w != null ? "true" : "false") + ",\"file\":\"" + Path.GetFileName(file).Replace("\\", "") + "\",\"rows\":" + Rows + ",\"fastRows\":" + FastRows + ",\"snapshots\":" + Snapshots +
                   ",\"bytes\":" + Bytes + ",\"pctOfCore\":" + (wall > 0 ? (CostCpuMs / wall * 100).ToString("0.0000", Inv) : "null") + "}";
        }

        // ---- the loop ----
        static void Loop()
        {
            Stopwatch clock = Stopwatch.StartNew(); double next = 0;
            while (!stop)
            {
                bool run = false;
                try { run = Running != null && Running(); } catch { }
                try
                {
                    if (run && w == null) { Open(); next = clock.Elapsed.TotalMilliseconds; }     // the timetable starts with the file
                    else if (!run && w != null) Close();
                }
                catch (Exception ex) { Log.W("black box: " + ex.Message); }
                if (w == null)
                {
                    // between sessions: the 8-week tidy (a Jobs job once W0-3 has merged)
                    if ((DateTime.Now - lastPrune).TotalHours >= 6 && Dir != null)
                    {
                        lastPrune = DateTime.Now;
                        try { int n = Prune(Dir, DateTime.Now, KeepDays); if (n > 0) Log.W("black box: removed " + n + " file" + (n == 1 ? "" : "s") + " older than 8 weeks"); } catch (Exception ex) { Log.W("black box: tidy: " + ex.Message); }
                    }
                    Thread.Sleep(1000); next = clock.Elapsed.TotalMilliseconds; continue;
                }
                long c0 = ThreadCpu();
                try { Row(); } catch (Exception ex) { Log.W("black box: " + ex.Message); }
                CostCpuMs += (ThreadCpu() - c0) / 1e4;
                RunWallMs = (DateTime.Now - runStart).TotalMilliseconds;
                // a fixed timetable, so Windows' 15.6 ms sleep steps even out (ten rows a second really are ten)
                double step = DateTime.Now < fastUntil ? FastMs : 1000;
                next += step;
                double now = clock.Elapsed.TotalMilliseconds;
                if (next < now - step) next = now;          // fell behind (the PC slept): start the timetable again
                int wait = (int)Math.Max(1, next - now);
                Thread.Sleep(wait);
            }
            try { Close(); } catch { }
        }

        static void Open()
        {
            string dir = Dir; if (dir == null) return;
            bool test = false; try { test = IsTest != null && IsTest(); } catch { }
            if (test) dir = Path.Combine(dir, "test");
            Directory.CreateDirectory(dir);
            file = Path.Combine(dir, DateTime.Now.ToString("yyyyMMdd-HHmmss", Inv) + ".tsv");
            FileStream fs = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            w = new StreamWriter(fs, new UTF8Encoding(false)); w.AutoFlush = true;
            w.WriteLine(Header); w.WriteLine(SnapHeader);
            lock (gate) { pending.Clear(); usual.Clear(); usualLooks = 0; groups = new Dictionary<string, double>(); }
            last5.Clear(); lastLap = -1; fastUntil = DateTime.MinValue; snapAt = DateTime.MinValue; lastSecond = DateTime.MinValue; lastScan = DateTime.MinValue;
            scan.Clear();
            Rows = 0; FastRows = 0; Snapshots = 0; Bytes = 0; CostCpuMs = 0; runStart = DateTime.Now; RunWallMs = 0;
            long k, u; GetSystemTimes(out sysIdle0, out k, out u); sysTotal0 = k + u;
            OpenCounters();
            Log.W("black box: recording (" + Path.GetFileName(file) + (test ? ", pretend session" : "") + ")");
        }

        static void Close()
        {
            if (w == null) return;
            try { w.Dispose(); } catch { }
            w = null;
            foreach (PerformanceCounter c in diskQ) try { c.Dispose(); } catch { }
            foreach (PerformanceCounter c in diskW) try { c.Dispose(); } catch { }
            diskQ.Clear(); diskW.Clear();
            Log.W("black box: stopped - " + Rows + " rows (" + FastRows + " fast), " + Snapshots + " snapshot" + (Snapshots == 1 ? "" : "s") + ", " + (Bytes / 1024) + " KB, " +
                  (RunWallMs > 0 ? (CostCpuMs / RunWallMs * 100).ToString("0.000", Inv) + " % of one core" : "no time measured"));
        }

        static void OpenCounters()
        {
            foreach (string d in Drives)
            {
                try { diskQ.Add(new PerformanceCounter("LogicalDisk", "Current Disk Queue Length", d, true)); } catch { }
                try { PerformanceCounter c = new PerformanceCounter("LogicalDisk", "Avg. Disk sec/Write", d, true); c.NextValue(); diskW.Add(c); } catch { }
            }
        }

        static double DiskQueue() { double m = -1; foreach (PerformanceCounter c in diskQ) try { m = Math.Max(m, c.NextValue()); } catch { } return m; }
        static double DiskWriteMs() { double m = -1; foreach (PerformanceCounter c in diskW) try { m = Math.Max(m, c.NextValue() * 1000); } catch { } return m; }

        static double CpuTotal()
        {
            long idle, k, u; if (!GetSystemTimes(out idle, out k, out u)) return -1;
            long total = k + u, dt = total - sysTotal0, di = idle - sysIdle0;
            sysTotal0 = total; sysIdle0 = idle;
            return dt > 0 ? Math.Max(0, Math.Min(100, 100.0 * (dt - di) / dt)) : -1;
        }

        // ---- own look at the programs (fast mode, the snapshot, tests) ----
        static readonly Dictionary<int, long[]> scan = new Dictionary<int, long[]>();    // pid -> {cpu ticks, gen}
        static readonly Dictionary<int, string> scanName = new Dictionary<int, string>();
        static long scanGen; static DateTime scanAt = DateTime.MinValue;
        static Dictionary<string, double> Scan()
        {
            Dictionary<string, double> g = new Dictionary<string, double>();
            DateTime now = DateTime.Now; double dt = scanAt == DateTime.MinValue ? 0 : (now - scanAt).TotalSeconds; scanAt = now;
            scanGen++;
            Process[] all = Process.GetProcesses();
            foreach (Process p in all)
            {
                try
                {
                    int pid = p.Id; string name; long[] s;
                    if (!scanName.TryGetValue(pid, out name)) { name = p.ProcessName; scanName[pid] = name; }
                    if (!scan.TryGetValue(pid, out s)) { s = new long[] { -1, 0 }; scan[pid] = s; }
                    s[1] = scanGen;
                    if (s[0] == -2) continue;                                // protected program: never asked again
                    long cpu; try { cpu = p.TotalProcessorTime.Ticks; } catch { s[0] = -2; continue; }
                    if (s[0] >= 0 && dt > 0)
                    {
                        double pct = (cpu - s[0]) / 1e7 / dt * 100.0;
                        if (pct > 0.05) { string grp = GroupOf != null ? GroupOf(name, pid) : name; double v; g.TryGetValue(grp, out v); g[grp] = v + pct; }
                    }
                    s[0] = cpu;
                }
                catch { }
                finally { p.Dispose(); }
            }
            List<int> dead = new List<int>();
            foreach (KeyValuePair<int, long[]> kv in scan) if (kv.Value[1] != scanGen) dead.Add(kv.Key);
            foreach (int d in dead) { scan.Remove(d); scanName.Remove(d); }
            return dt > 0 ? g : null;
        }

        static string F(double v, string fmt) { return double.IsNaN(v) || double.IsInfinity(v) ? "" : v.ToString(fmt, Inv); }
        static string Clean(string s) { return (s ?? "").Replace('\t', ' ').Replace(';', ',').Replace('=', '-').Replace('/', '-'); }

        static void Row()
        {
            DateTime now = DateTime.Now;
            BbSdk s = null; try { s = ReadSdk != null ? ReadSdk() : null; } catch { }
            if (s == null) s = new BbSdk();
            bool fast = now < fastUntil;
            // the lap counter going up is a lap crossing (Paddock's own work starts there: lap save, PB reference, clip)
            if (s.Connected && s.Lap >= 0) { if (lastLap >= 0 && s.Lap > lastLap) Event("lap " + s.Lap.ToString("0", Inv)); lastLap = s.Lap; }

            // the programs: every 5 s (handed over by PerfSampler, or our own look in tests), every second while a dip is on
            bool scanNow = (fast || SelfScan) && (now - lastScan).TotalSeconds >= (fast ? 0.95 : 4.95);
            if (scanNow)
            {
                lastScan = now;
                Dictionary<string, double> g = Scan();
                if (g != null) lock (gate) { groups = g; if (!fast) AddUsual(g); }
            }

            // fast mode: 25 % under the last 5 s
            bool second = (now - lastSecond).TotalMilliseconds >= 950;
            if (second && s.Connected && s.Fps > 1)
            {
                if (!fast && last5.Count >= 5)
                {
                    double avg = 0; foreach (double v in last5) avg += v; avg /= last5.Count;
                    if (s.Fps <= avg * (1 - FastDrop))
                    {
                        fastUntil = now.AddSeconds(FastSeconds); fast = true;
                        snapAt = now.AddSeconds(1); snapFps = s.Fps; snapAvg = avg;
                        Event("frame rate drop " + avg.ToString("0", Inv) + " to " + s.Fps.ToString("0", Inv));
                        if (!SelfScan) { lastScan = now; Scan(); }            // a starting point, so the look one second from now has rates
                    }
                }
                last5.Add(s.Fps); while (last5.Count > 5) last5.RemoveAt(0);
            }
            if (second) lastSecond = now;

            Dictionary<string, double> gs; List<string> evs;
            lock (gate) { gs = groups; evs = new List<string>(pending); pending.Clear(); }
            List<KeyValuePair<string, double>> top = new List<KeyValuePair<string, double>>();
            foreach (KeyValuePair<string, double> kv in gs) if (kv.Key != SimGroup) top.Add(kv);
            top.Sort(delegate (KeyValuePair<string, double> a, KeyValuePair<string, double> b) { return b.Value.CompareTo(a.Value); });

            double dq = DiskQueue(), dw = DiskWriteMs();
            StringBuilder sb = new StringBuilder(240);
            sb.Append(F(Unix(now), "0.000")).Append('\t');
            if (s.Connected)
                sb.Append(F(s.SessTime, "0.00")).Append('\t').Append(F(s.Lap, "0")).Append('\t').Append(F(s.Pct, "0.0000")).Append('\t').Append(F(s.Speed, "0.0")).Append('\t')
                  .Append(F(s.Fps, "0.0")).Append('\t').Append(F(s.CpuFG, "0.000")).Append('\t').Append(F(s.CpuBG, "0.000")).Append('\t').Append(F(s.Gpu, "0.000")).Append('\t').Append(F(s.PageFaults, "0")).Append('\t');
            else sb.Append("\t\t\t\t\t\t\t\t\t");
            sb.Append(F(CpuTotal(), "0.0"));
            for (int i = 0; i < 3; i++) { sb.Append('\t'); if (i < top.Count) sb.Append(Clean(top[i].Key)).Append('\t').Append(F(top[i].Value, "0.0")); else sb.Append('\t'); }
            sb.Append('\t').Append(dq >= 0 ? F(dq, "0") : "").Append('\t').Append(dw >= 0 ? F(dw, "0.0") : "").Append('\t').Append(string.Join(";", evs.ToArray()));
            sb.Append("\t\t\t\t");                     // gpuLoad, gpuClock, gpuTemp, gpuThrottle: NVML, wave 5 (W5-3)
            Write(sb.ToString());
            Rows++; if (fast) FastRows++;

            // the snapshot, one second into the dip: who was busy then, against their own usual
            if (snapAt != DateTime.MinValue && now >= snapAt)
            {
                snapAt = DateTime.MinValue;
                if (!SelfScan || (now - lastScan).TotalSeconds > 0.5) { lastScan = now; Dictionary<string, double> g = Scan(); if (g != null) lock (gate) groups = g; }
                List<KeyValuePair<string, double>> all;
                lock (gate) all = new List<KeyValuePair<string, double>>(groups);
                all.RemoveAll(delegate (KeyValuePair<string, double> kv) { return kv.Key == SimGroup || kv.Value < 1; });
                all.Sort(delegate (KeyValuePair<string, double> a, KeyValuePair<string, double> b) { return b.Value.CompareTo(a.Value); });
                StringBuilder pr = new StringBuilder();
                for (int i = 0; i < all.Count && i < 5; i++) { if (pr.Length > 0) pr.Append(';'); pr.Append(Clean(all[i].Key)).Append('=').Append(F(all[i].Value, "0.0")).Append('/').Append(F(UsualOf(all[i].Key), "0.0")); }
                List<string> ours = new List<string>();
                lock (gate) foreach (KeyValuePair<DateTime, string> e in recentEv) if ((now - e.Key).TotalSeconds <= 5 && Ours(e.Value)) ours.Add(e.Value);
                Write("snapshot\t" + F(Unix(now), "0.000") + "\t" + F(snapFps, "0.0") + "\t" + F(snapAvg, "0.0") + "\t" + (s.Connected ? F(s.Gpu, "0.000") : "") + "\t" + (s.Connected ? F(s.CpuFG, "0.000") : "") + "\t" +
                      (s.Connected ? F(s.PageFaults, "0") : "") + "\t" + (dq >= 0 ? F(dq, "0") : "") + "\t" + (dw >= 0 ? F(dw, "0.0") : "") + "\t" + pr + "\t" + string.Join(";", ours.ToArray()));
                Snapshots++;
            }
        }

        static void Write(string line) { if (w == null) return; w.WriteLine(line); Bytes += Encoding.UTF8.GetByteCount(line) + 2; }

        internal static double Unix(DateTime local) { return (local.ToUniversalTime() - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; }

        // Paddock's own work that can cost a frame (a lap crossing alone is not: it is just where the work starts)
        static bool Ours(string e)
        {
            string l = e.ToLowerInvariant();
            return l.IndexOf("cut", StringComparison.Ordinal) >= 0 || l.IndexOf("save", StringComparison.Ordinal) >= 0 || l.IndexOf("scan", StringComparison.Ordinal) >= 0 || l.IndexOf("job", StringComparison.Ordinal) >= 0;
        }

        // ---- the 8-week tidy (also tests\blackbox-test.ps1 on a temp folder) ----
        public static int Prune(string dir, DateTime now, int days)
        {
            if (dir == null || !Directory.Exists(dir)) return 0;
            int n = 0;
            List<string> files = new List<string>(Directory.GetFiles(dir, "*.tsv"));
            string t = Path.Combine(dir, "test"); if (Directory.Exists(t)) files.AddRange(Directory.GetFiles(t, "*.tsv"));
            foreach (string f in files)
            {
                DateTime when;
                if (!DateTime.TryParseExact(Path.GetFileNameWithoutExtension(f), "yyyyMMdd-HHmmss", Inv, DateTimeStyles.None, out when)) when = File.GetLastWriteTime(f);
                if (f == file) continue;
                if ((now - when).TotalDays > days) { try { File.Delete(f); n++; } catch { } }
            }
            return n;
        }

        // ---------------- reading a file back: the freezes and their likely cause ----------------
        sealed class BbRow { public double T, Lap = -1, Pct = -1, Fps, Cpu = -1, Gpu = -1, Pf = -1; public string Ev = ""; public List<string> Top = new List<string>(); public List<double> TopPct = new List<double>(); }
        sealed class BbSnap { public double T, Gpu = -1, Cpu = -1, Pf = -1; public string Programs = "", Paddock = ""; }

        static double D(string s) { double v; return double.TryParse(s, NumberStyles.Float, Inv, out v) ? v : double.NaN; }

        // a freeze = the frame rate under half the session's average (the same rule as the Performance verdict)
        public static List<BbFreeze> Freezes(string path)
        {
            List<BbRow> rows = new List<BbRow>(); List<BbSnap> snaps = new List<BbSnap>();
            string text;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader r = new StreamReader(fs, Encoding.UTF8)) text = r.ReadToEnd();
            foreach (string raw in text.Split('\n'))
            {
                string line = raw.TrimEnd('\r');
                if (line.Length == 0 || line[0] == '#') continue;
                string[] f = line.Split('\t');
                if (f[0] == "snapshot")
                {
                    if (f.Length < 11) continue;
                    BbSnap sn = new BbSnap(); sn.T = D(f[1]); double v;
                    v = D(f[4]); if (!double.IsNaN(v)) sn.Gpu = v; v = D(f[5]); if (!double.IsNaN(v)) sn.Cpu = v; v = D(f[6]); if (!double.IsNaN(v)) sn.Pf = v;
                    sn.Programs = f[9]; sn.Paddock = f[10]; snaps.Add(sn); continue;
                }
                if (f.Length < 20) continue;
                BbRow b = new BbRow(); b.T = D(f[0]);
                double fps = D(f[5]); if (double.IsNaN(fps) || double.IsNaN(b.T)) continue;
                b.Fps = fps; double x;
                x = D(f[2]); if (!double.IsNaN(x)) b.Lap = x; x = D(f[3]); if (!double.IsNaN(x)) b.Pct = x;
                x = D(f[6]); if (!double.IsNaN(x)) b.Cpu = x; x = D(f[8]); if (!double.IsNaN(x)) b.Gpu = x; x = D(f[9]); if (!double.IsNaN(x)) b.Pf = x;
                for (int i = 0; i < 3; i++) { if (f[11 + 2 * i].Length > 0) { b.Top.Add(f[11 + 2 * i]); x = D(f[12 + 2 * i]); b.TopPct.Add(double.IsNaN(x) ? 0 : x); } }
                b.Ev = f[19];
                rows.Add(b);
            }
            List<BbFreeze> res = new List<BbFreeze>();
            // the average, each row weighted by the time it stands for (fast-mode rows are a tenth of a second)
            double sum = 0, wt = 0;
            for (int i = 0; i < rows.Count; i++)
            {
                if (rows[i].Fps <= 1) continue;
                double dt = i + 1 < rows.Count ? Math.Min(1.5, rows[i + 1].T - rows[i].T) : 1; if (dt <= 0) continue;
                sum += rows[i].Fps * dt; wt += dt;
            }
            if (wt < 10) return res;
            double avg = sum / wt;
            int k = 0;
            while (k < rows.Count)
            {
                if (!(rows[k].Fps > 1 && rows[k].Fps < avg * 0.5)) { k++; continue; }
                int a = k, z = k;
                while (z + 1 < rows.Count && rows[z + 1].Fps > 1 && rows[z + 1].Fps < avg * 0.5 && rows[z + 1].T - rows[z].T <= 1.5) z++;
                BbFreeze fr = new BbFreeze(); fr.At = rows[a].T; fr.Lap = rows[a].Lap; fr.Pct = rows[a].Pct; fr.Avg = avg; fr.Worst = double.MaxValue;
                for (int i = a; i <= z; i++) if (rows[i].Fps < fr.Worst) fr.Worst = rows[i].Fps;
                double tail = z + 1 < rows.Count ? Math.Min(1.0, rows[z + 1].T - rows[z].T) : 1.0;
                fr.Len = rows[z].T - rows[a].T + tail;
                // what the cause rules see: the 3 s before the start to the end
                BbDip d = new BbDip();
                double from = fr.At - 3, to = rows[z].T;
                for (int i = 0; i < rows.Count; i++)
                {
                    BbRow b = rows[i]; if (b.T < from || b.T > to) continue;
                    if (b.Gpu > d.Gpu) { d.Gpu = b.Gpu; d.Cpu = b.Cpu; }
                    if (b.Pf > d.PageFaults) d.PageFaults = b.Pf;
                    if (b.T <= fr.At + 0.5) foreach (string e in b.Ev.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)) if (Ours(e) && !d.Paddock.Contains(e)) d.Paddock.Add(e);
                }
                BbSnap best = null;
                foreach (BbSnap sn in snaps) if (sn.T >= fr.At - 20 && sn.T <= to + 5 && (best == null || Math.Abs(sn.T - fr.At) < Math.Abs(best.T - fr.At))) best = sn;
                if (best != null)
                {
                    foreach (string p in best.Programs.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        int eq = p.LastIndexOf('='), sl = p.LastIndexOf('/'); if (eq <= 0 || sl < eq) continue;
                        double n = D(p.Substring(eq + 1, sl - eq - 1)), u = D(p.Substring(sl + 1));
                        if (double.IsNaN(n)) continue;
                        d.Programs.Add(p.Substring(0, eq)); d.Now.Add(n); d.Usual.Add(double.IsNaN(u) ? 0 : u);
                    }
                    foreach (string e in best.Paddock.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)) if (Ours(e) && !d.Paddock.Contains(e)) d.Paddock.Add(e);
                    if (best.Pf > d.PageFaults) d.PageFaults = best.Pf;
                }
                fr.Cause = Cause(d);
                res.Add(fr);
                k = z + 1;
            }
            return res;
        }

        // the freeze nearest a moment (unix seconds), from the black box file that covers it; null when none is recorded
        static readonly Dictionary<string, KeyValuePair<long, List<BbFreeze>>> readCache = new Dictionary<string, KeyValuePair<long, List<BbFreeze>>>();
        public static BbFreeze FreezeNear(double unix, double within)
        {
            if (Dir == null || !Directory.Exists(Dir)) return null;
            BbFreeze best = null;
            foreach (string f in Directory.GetFiles(Dir, "*.tsv"))
            {
                DateTime st;
                if (!DateTime.TryParseExact(Path.GetFileNameWithoutExtension(f), "yyyyMMdd-HHmmss", Inv, DateTimeStyles.None, out st)) continue;
                if (Unix(st) > unix + 60 || Unix(File.GetLastWriteTime(f)) < unix - 60) continue;
                List<BbFreeze> l;
                long len = new FileInfo(f).Length;
                lock (readCache)
                {
                    KeyValuePair<long, List<BbFreeze>> c;
                    if (readCache.TryGetValue(f, out c) && c.Key == len) l = c.Value;
                    else { try { l = Freezes(f); } catch (Exception ex) { Log.W("black box: reading " + Path.GetFileName(f) + ": " + ex.Message); l = new List<BbFreeze>(); } readCache[f] = new KeyValuePair<long, List<BbFreeze>>(len, l); }
                }
                foreach (BbFreeze z in l) if (Math.Abs(z.At - unix) <= within && (best == null || Math.Abs(z.At - unix) < Math.Abs(best.At - unix))) best = z;
            }
            return best;
        }

        // ---------------- the cause rules (pure; tests\perf-verdict-test.ps1 has one case each) ----------------
        // In Peter's words, the part after "Likely cause: ". The order is the order of 05: graphics card, a program, Paddock, memory, the sim.
        // The SDK's GpuUsage / CpuUsageFG are shares of the frame time: in a stalled frame both go over 100 % together (12 Nov: 317 % and
        // 309 %), which says the frame stalled, not that the card was the limit. So "graphics card" needs the card busy and the processor not.
        public static string Cause(BbDip d)
        {
            if (d.Gpu >= 0.95 && (d.Cpu < 0 || d.Cpu < d.Gpu * 0.8)) return "the graphics card (busy " + Math.Round(d.Gpu * 100).ToString("0", Inv) + " % of the frame)";
            string prog = null; double ratio = 0;
            for (int i = 0; i < d.Programs.Count; i++)
            {
                double now = d.Now[i], u = d.Usual[i];
                if (now < 10) continue;                                                 // under a tenth of a core cannot hold up the sim
                double r = u > 0.5 ? now / u : 99;
                if (r >= 3 && r > ratio) { ratio = r; prog = d.Programs[i]; }
            }
            if (prog != null) return prog + (ratio >= 99 ? " (it woke up and took " + Math.Round(d.Now[d.Programs.IndexOf(prog)]).ToString("0", Inv) + " % of a core)" : " (" + Math.Round(ratio).ToString("0", Inv) + "× its usual CPU)");
            if (d.Paddock.Count > 0) return "Paddock (" + d.Paddock[0] + ")";
            if (d.PageFaults > 1000) return "memory (Windows was loading " + Math.Round(d.PageFaults).ToString("0", Inv) + " pages a second from disk)";
            return "inside the sim (likely a graphics hitch)";
        }

        // where on the lap: the line, else the corner the lap fraction is in (or near), else the share of the lap
        public static string Place(double pct, double[] p0, double[] p1, string[] names)
        {
            if (pct < 0) return "";
            if (pct >= 0.97 || pct <= 0.03) return "start/finish";
            if (p0 != null && p1 != null && names != null && p0.Length > 0)
            {
                int near = -1; double nd = 9;
                for (int i = 0; i < p0.Length && i < p1.Length && i < names.Length; i++)
                {
                    if (pct >= p0[i] - 0.01 && pct <= p1[i] + 0.01) return names[i];
                    double dd = Math.Min(Math.Abs(pct - p0[i]), Math.Abs(pct - p1[i]));
                    if (dd < nd) { nd = dd; near = i; }
                }
                if (near >= 0 && nd <= 0.05) return "before " + names[near];
            }
            return Math.Round(pct * 100).ToString("0", Inv) + " % round the lap";
        }

        // "Lap 9, start/finish: the picture froze for 4 s (worst second 23.7 fps, at 09:46:00). Likely cause: Coach Dave Delta (3× its usual CPU)."
        // clock: local "HH:mm:ss" or "" when unknown
        public static string Sentence(double lap, string place, double lenS, double worst, string clock, string cause)
        {
            string head = lap >= 0 ? "Lap " + lap.ToString("0", Inv) + (string.IsNullOrEmpty(place) ? "" : ", " + place) : (string.IsNullOrEmpty(place) ? "On track" : "At " + place);
            int secs = (int)Math.Max(1, Math.Round(lenS));
            string s = head + ": the picture froze for " + secs + " s (worst second " + worst.ToString("0.0", Inv) + " fps" + (string.IsNullOrEmpty(clock) ? "" : ", at " + clock) + ").";
            if (!string.IsNullOrEmpty(cause)) s += " Likely cause: " + cause + ".";
            return s;
        }
    }
}
