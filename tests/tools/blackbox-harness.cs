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
        internal sealed class Ibt
        {
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
            Console.WriteLine("unknown mode"); return 2;
        }
    }
}
