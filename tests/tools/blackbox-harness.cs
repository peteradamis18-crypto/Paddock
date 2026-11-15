// blackbox-harness.cs - runs irdash's real BlackBox (dash\src\blackbox.cs) fed by irdash's real IbtReplay (W0-8's pretend pump, cut out of
// dash\src\irdash.cs by tests\blackbox-test.ps1) against stand-ins for the rest of irdash. No irdash, no sim, no port.
//   rate   <ibt> <from s> <seconds> <drop at s> <dir>   replay at 1x, FrameRate x0.7 from <drop at> on (a synthetic 30 % drop)
//   freeze <ibt> <from s> <to s> <dir>                  replay a real stretch, then read the file back: the freezes and their sentence
//   prune  <dir> <days>                                 the 8-week tidy on a folder
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

namespace IRDash
{
    sealed class VarDef { public string Name; public int Type, Offset, Count; }
    static class Log { public static void W(string s) { Console.WriteLine("LOG " + s); } }
    static class Json { public static string Str(string s) { return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "\\n") + "\""; } }

    static class Sdk
    {
        public static volatile int FakePumpMs = 33;
        public static bool Pretend = false;
        public static string Yaml = "";
        public static Dictionary<string, double> Last = new Dictionary<string, double>();
        public static void FakeSession(string y) { Yaml = y; }
        public static void FakeSet(Dictionary<string, double> v) { Pretend = true; lock (Last) foreach (KeyValuePair<string, double> kv in v) Last[kv.Key] = kv.Value; }
    }

    static class TrackMaps
    {
        internal sealed class IbtHead { public DateTime StartUtc = DateTime.MinValue; }
        internal sealed class Ibt
        {
            public IbtHead File = new IbtHead();                         // W5-3: FieldLaps.ScanFile asks t.File.StartUtc (MinValue = use the file time)
            public FileStream fs; public int bufLen, dataOff; public long records; public string yaml = "";
            public Dictionary<string, VarDef> vars = new Dictionary<string, VarDef>();
        }
        // same as irdash's TrackMaps.OpenIbt (and tests\tools\ibt-replay-harness.cs)
        internal static Ibt OpenIbt(string path, bool wantVars)
        {
            FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            byte[] h = new byte[144];
            if (fs.Read(h, 0, h.Length) < h.Length) { fs.Dispose(); return null; }
            Ibt t = new Ibt();
            t.fs = fs;
            int infoLen = BitConverter.ToInt32(h, 16), infoOff = BitConverter.ToInt32(h, 20);
            int numVars = BitConverter.ToInt32(h, 24), varOff = BitConverter.ToInt32(h, 28);
            t.bufLen = BitConverter.ToInt32(h, 36); t.dataOff = BitConverter.ToInt32(h, 52);
            t.records = (fs.Length - t.dataOff) / t.bufLen;
            byte[] info = new byte[infoLen];
            fs.Position = infoOff; fs.Read(info, 0, infoLen);
            int z = Array.IndexOf(info, (byte)0); if (z < 0) z = infoLen;
            t.yaml = Encoding.GetEncoding(28591).GetString(info, 0, z);
            byte[] vh = new byte[numVars * 144];
            fs.Position = varOff; fs.Read(vh, 0, vh.Length);
            for (int i = 0; i < numVars; i++)
            {
                int b = i * 144;
                int len = Array.IndexOf(vh, (byte)0, b + 16, 32) - (b + 16); if (len < 0) len = 32;
                VarDef v = new VarDef();
                v.Name = Encoding.ASCII.GetString(vh, b + 16, len);
                v.Type = BitConverter.ToInt32(vh, b); v.Offset = BitConverter.ToInt32(vh, b + 4); v.Count = BitConverter.ToInt32(vh, b + 8);
                t.vars[v.Name] = v;
            }
            return t;
        }
    }

    // ---- IbtReplay is pasted here by the test ----
//IBTREPLAY//

    // ---- W5-3 stand-ins: the rig state, the JSON quote, and FieldLaps with its real ScanFile pasted in from dash\src\bench.cs ----
    static class Json_ { public static string S(string s) { return Json.Str(s ?? ""); } }
    static class RigState { public static volatile bool SimRunning, SessionOn; }
    sealed class FieldRow { }
    static class FieldLaps
    {
        static List<FieldRow> ParseYaml(string yaml, long ts, string src, out int otherHumans) { otherHumans = 0; return new List<FieldRow>(); }
//SCANFILE//
    }
    static class RigWire
    {
        public static void Wire()
        {
//RUNNING//
        }
    }

    static class Harness
    {
        static volatile bool running;
        static volatile float factor = 1f;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        static double G(Dictionary<string, double> d, string k) { double v; return d.TryGetValue(k, out v) ? v : 0; }

        static void Wire(string dir)
        {
            BlackBox.Dir = dir; BlackBox.Drives = new string[] { "C:" }; BlackBox.SelfScan = true;
            BlackBox.Running = delegate { return running && Sdk.Pretend; };
            BlackBox.IsTest = delegate { return false; };
            BlackBox.GroupOf = delegate (string n, int pid) { return n; };
            BlackBox.ReadSdk = delegate
            {
                BbSdk s = new BbSdk();
                lock (Sdk.Last)
                {
                    if (Sdk.Last.Count == 0) return s;
                    s.Connected = true; s.SessTime = G(Sdk.Last, "SessionTime"); s.Lap = G(Sdk.Last, "Lap"); s.Pct = G(Sdk.Last, "LapDistPct"); s.Speed = G(Sdk.Last, "Speed");
                    s.Fps = G(Sdk.Last, "FrameRate") * factor; s.CpuFG = G(Sdk.Last, "CpuUsageFG"); s.CpuBG = G(Sdk.Last, "CpuUsageBG"); s.Gpu = G(Sdk.Last, "GpuUsage"); s.PageFaults = G(Sdk.Last, "MemPageFaultSec");
                }
                return s;
            };
        }

        static int Main(string[] a)
        {
            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
            if (a[0] == "prune")
            {
                int n = BlackBox.Prune(a[1], DateTime.Now, int.Parse(a[2], Inv));
                Console.WriteLine("PRUNED " + n);
                return 0;
            }
            if (a[0] == "rate")
            {
                string ibt = a[1]; double from = double.Parse(a[2], Inv), secs = double.Parse(a[3], Inv), dropAt = double.Parse(a[4], Inv);
                Wire(a[5]);
                string err = IbtReplay.Start(ibt, 1, from, from + secs + 30);
                if (err != null) { Console.WriteLine("START-FAILED " + err); return 1; }
                Thread.Sleep(500);                       // the first frames are in
                running = true; BlackBox.Start();
                Stopwatch sw = Stopwatch.StartNew();
                double normalCpu = -1, normalWall = -1; long normalRows = 0;
                while (sw.Elapsed.TotalSeconds < secs)
                {
                    if (factor == 1f && sw.Elapsed.TotalSeconds >= dropAt)
                    {
                        normalCpu = BlackBox.CostCpuMs; normalWall = BlackBox.RunWallMs; normalRows = BlackBox.Rows;
                        factor = 0.7f; Console.WriteLine("DROP at " + DateTime.Now.ToString("HH:mm:ss.fff", Inv) + " unix " + BlackBox.Unix(DateTime.Now).ToString("0.000", Inv));
                    }
                    Thread.Sleep(50);
                }
                Console.WriteLine("STOPAT unix " + BlackBox.Unix(DateTime.Now).ToString("0.000", Inv));
                running = false;
                Thread.Sleep(2500);                      // the black box sees "not running" and closes the file
                Console.WriteLine("ROWS " + BlackBox.Rows + " FAST " + BlackBox.FastRows + " SNAPS " + BlackBox.Snapshots + " BYTES " + BlackBox.Bytes);
                Console.WriteLine("COST " + (BlackBox.CostCpuMs / BlackBox.RunWallMs * 100).ToString("0.0000", Inv) + " CPUMS " + BlackBox.CostCpuMs.ToString("0.0", Inv) + " WALLMS " + BlackBox.RunWallMs.ToString("0", Inv));
                if (normalWall > 0) Console.WriteLine("COSTNORMAL " + (normalCpu / normalWall * 100).ToString("0.0000", Inv) + " ROWS " + normalRows);
                Console.WriteLine("STATUS " + BlackBox.StatusJson());
                BlackBox.Stop(); IbtReplay.Stop();
                return 0;
            }
            if (a[0] == "freeze")
            {
                string ibt = a[1]; double from = double.Parse(a[2], Inv), to = double.Parse(a[3], Inv);
                Wire(a[4]);
                // Only this harness is counted as a program, so the cause does not depend on what else this PC is doing.
                // "fed" = as in irdash: no own look every 5 s, the programs handed over every 5 s (PerfSampler), own looks only in a dip.
                int me = Process.GetCurrentProcess().Id;
                BlackBox.GroupOf = delegate (string n, int pid) { return pid == me ? "blackbox harness" : null; };
                bool fed = a.Length > 5 && a[5] == "fed";
                BlackBox.SelfScan = !fed;
                if (fed)
                {
                    Thread feeder = new Thread(delegate ()
                    {
                        long c0 = Process.GetCurrentProcess().TotalProcessorTime.Ticks; DateTime t0 = DateTime.Now;
                        while (true)
                        {
                            Thread.Sleep(5000);
                            long c1; using (Process p = Process.GetCurrentProcess()) c1 = p.TotalProcessorTime.Ticks;
                            DateTime t1 = DateTime.Now;
                            Dictionary<string, double> g = new Dictionary<string, double>();
                            g["blackbox harness"] = (c1 - c0) / 1e7 / (t1 - t0).TotalSeconds * 100;
                            c0 = c1; t0 = t1;
                            BlackBox.Procs(g);
                        }
                    });
                    feeder.IsBackground = true; feeder.Start();
                }
                string err = IbtReplay.Start(ibt, 1, from, to);
                if (err != null) { Console.WriteLine("START-FAILED " + err); return 1; }
                Thread.Sleep(500);
                running = true; BlackBox.Start();
                Stopwatch sw = Stopwatch.StartNew();
                while (sw.Elapsed.TotalSeconds < (to - from) - 1) Thread.Sleep(100);
                running = false; Thread.Sleep(2500);
                Console.WriteLine("ROWS " + BlackBox.Rows + " FAST " + BlackBox.FastRows + " SNAPS " + BlackBox.Snapshots);
                BlackBox.Stop(); IbtReplay.Stop();
                foreach (string f in Directory.GetFiles(a[4], "*.tsv"))
                    foreach (string l in File.ReadAllLines(f)) if (l.StartsWith("snapshot\t", StringComparison.Ordinal)) Console.WriteLine("SNAPPROGS " + l.Split('\t')[9]);
                foreach (string f in Directory.GetFiles(a[4], "*.tsv"))
                    foreach (BbFreeze z in BlackBox.Freezes(f))
                        Console.WriteLine("FREEZE lap " + z.Lap.ToString("0", Inv) + " pct " + z.Pct.ToString("0.000", Inv) + " len " + z.Len.ToString("0.0", Inv) + " worst " + z.Worst.ToString("0.0", Inv) + " avg " + z.Avg.ToString("0.0", Inv) +
                                          " | " + BlackBox.Sentence(z.Lap, BlackBox.Place(z.Pct, null, null, null), z.Len, z.Worst, "", z.Cause));
                return 0;
            }
            // ---- W5-3 ----
            if (a[0] == "causes")
            {
                // synthetic files read back through the real Freezes + Cause: 30 s of normal driving, a 4 s freeze, 10 s after
                string dir = a[1]; Directory.CreateDirectory(dir);
                Func<string, bool, Func<int, bool, string>, string> run = delegate (string name, bool v1, Func<int, bool, string> extra)
                {
                    string f = Path.Combine(dir, name + ".tsv");
                    StringBuilder sb = new StringBuilder();
                    if (v1) sb.Append("# t\tsessTime\tlap\tlapPct\tspeed\tfps\tcpuFG\tcpuBG\tgpu\tpageFaults\tcpuTotal\ttop1\ttop1Pct\ttop2\ttop2Pct\ttop3\ttop3Pct\tdiskQueue\tdiskWriteMs\tevents\tgpuLoad\tgpuClock\tgpuTemp\tgpuThrottle\r\n");
                    else sb.Append(BlackBox.Header).Append("\r\n");
                    sb.Append(BlackBox.SnapHeader).Append("\r\n");
                    for (int i = 0; i < 44; i++)
                    {
                        bool frz = i >= 30 && i < 34;
                        sb.Append((1000 + i).ToString(Inv)).Append("\t100\t5\t0.5000\t40\t").Append(frz ? "30.0" : "110.0").Append("\t0.500\t0.1\t0.600\t5\t20\tSimHub\t15\t\t\t\t\t0\t1\t");
                        sb.Append(extra(i, frz)).Append("\r\n");
                    }
                    File.WriteAllText(f, sb.ToString());
                    List<BbFreeze> fz = BlackBox.Freezes(f);
                    return fz.Count == 1 ? BlackBox.Sentence(fz[0].Lap, BlackBox.Place(fz[0].Pct, null, null, null), fz[0].Len, fz[0].Worst, "", fz[0].Cause) : "freezes: " + fz.Count;
                };
                // v2 tail: events gpuLoad gpuClock gpuTemp gpuThrottle vramMb vramTotalMb ramFreeMb gpuPowerW diskReadMs
                Func<string, string, double, double, double, string> v2 = delegate (string ev, string thr, double temp, double vram, double disk)
                { return ev + "\t98\t2600\t" + temp.ToString("0", Inv) + "\t" + thr + "\t" + vram.ToString("0", Inv) + "\t16376\t20000\t310.5\t" + disk.ToString("0.0", Inv); };
                Console.WriteLine("CAUSE thermal | " + run("thermal", false, delegate (int i, bool frz) { return frz ? v2("", "thermal", 83, 8000, 1) : v2("", "", 70, 8000, 1); }));
                Console.WriteLine("CAUSE power | " + run("power", false, delegate (int i, bool frz) { return frz ? v2("", "power", 76, 8000, 1) : v2("", "", 70, 8000, 1); }));
                Console.WriteLine("CAUSE disk | " + run("disk", false, delegate (int i, bool frz) { return v2("", "", 70, 8000, frz ? 120 : 1); }));
                Console.WriteLine("CAUSE vram | " + run("vram", false, delegate (int i, bool frz) { return v2("", "", 70, frz ? 15900 : 9000, 1); }));
                Console.WriteLine("CAUSE throttlebefore | " + run("throttlebefore", false, delegate (int i, bool frz) { return v2("", i >= 27 && i < 30 ? "thermal" : "", 83, 8000, 1); }));
                Console.WriteLine("CAUSE diskbefore | " + run("diskbefore", false, delegate (int i, bool frz) { return v2("", "", 70, 8000, i == 29 ? 300 : 1); }));
                Console.WriteLine("CAUSE quiet | " + run("quiet", false, delegate (int i, bool frz) { return v2("", "", 70, 8000, 1); }));
                Console.WriteLine("CAUSE fieldlaps | " + run("fieldlaps", false, delegate (int i, bool frz) { return v2(i == 29 ? "field laps: reading a telemetry file" : "", "", 70, 8000, 1); }));
                Console.WriteLine("CAUSE v1 | " + run("v1", true, delegate (int i, bool frz) { return "\t\t\t\t"; }));
                Console.WriteLine("CAUSE v1short | " + run("v1short", true, delegate (int i, bool frz) { return ""; }));
                return 0;
            }
            if (a[0] == "delta")
            {
                // fixture reports: name list of the other programs, average, worst second, froze
                string[][] sets = new string[][] {
                    new string[] { "Coach Dave Delta,SimHub|104.2|23.7|1", "SimHub,Coach Dave Delta|103.8|88|0", "SimHub,Discord|109.1|71|0", "Discord|108.9|90|0" },
                    new string[] { "Coach Dave Delta|104.2|23.7|1", "SimHub|109.1|71|0", "Discord|108.9|90|0" },
                    new string[] { "CoachDaveDelta|100|50|1", "CoachDave Academy Delta|102|40|1", "Coach Dave Delta|98|20|1", "Spotify|110|80|0", "Spotify|112|85|1" } };
                foreach (string[] set in sets)
                {
                    List<DcRace> races = new List<DcRace>();
                    foreach (string line in set)
                    {
                        string[] p = line.Split('|'); DcRace r = new DcRace();
                        foreach (string n in p[0].Split(',')) if (DeltaCompare.IsDelta(n)) r.Delta = true;
                        r.Avg = double.Parse(p[1], Inv); r.Worst = double.Parse(p[2], Inv); r.Froze = p[3] == "1";
                        races.Add(r);
                    }
                    Console.WriteLine("DELTA " + DeltaCompare.Json(races));
                }
                return 0;
            }
            if (a[0] == "fieldlaps")
            {
                // the real FieldLaps.ScanFile (pasted from bench.cs) on a fixture .ibt while a pretend session records
                Wire(a[2]);
                RigWire.Wire();
                Dictionary<string, double> v = new Dictionary<string, double>(); v["FrameRate"] = 110; v["Lap"] = 3; v["LapDistPct"] = 0.4; v["SessionTime"] = 100;
                Sdk.FakeSet(v);
                RigState.SessionOn = true; BlackBox.Start();
                Thread.Sleep(1600);
                int others; List<FieldRow> rows = FieldLaps.ScanFile(a[1], out others);
                Thread.Sleep(1600);
                RigState.SessionOn = false; Thread.Sleep(2500); BlackBox.Stop();
                foreach (string f in Directory.GetFiles(a[2], "*.tsv"))
                    foreach (string l in File.ReadAllLines(f)) { string[] c = l.Split('\t'); if (c.Length > 19 && c[19].Length > 0 && l[0] != '#') Console.WriteLine("EVENT " + c[19]); }
                return 0;
            }
            if (a[0] == "rig")
            {
                // BlackBox.Running exactly as perf.cs wires it (the line is pasted in), driven by a pretend RigState
                Wire(a[1]);
                RigWire.Wire();
                BlackBox.Start();
                Func<string> st = delegate { return BlackBox.StatusJson().Contains("\"recording\":true") ? "on" : "off"; };
                Thread.Sleep(2200); string s0 = st();
                RigState.SimRunning = true; Thread.Sleep(2200); string s1 = st();
                RigState.SimRunning = false; Thread.Sleep(2200); string s2 = st();
                RigState.SessionOn = true; Thread.Sleep(2200); string s3 = st();
                RigState.SessionOn = false; Thread.Sleep(2200); string s4 = st();
                BlackBox.Stop();
                Console.WriteLine("RIG " + s0 + " " + s1 + " " + s2 + " " + s3 + " " + s4 + " FILES " + Directory.GetFiles(a[1], "*.tsv").Length);
                return 0;
            }
            Console.WriteLine("unknown mode"); return 2;
        }
    }
}
