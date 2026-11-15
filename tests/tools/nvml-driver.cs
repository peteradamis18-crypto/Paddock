// nvml-driver.cs - runs irdash's real Nvml (dash\src\nvml.cs) on its own, for tests\nvml-test.ps1. Read only.
//   read             one look at the card: ROW load clock memclock temp vramMb vramTotalMb powerW throttle word
//   cost <ms> <s>    a look every <ms> for <s> seconds: COST <% of one core> READS n FAILS n
//   missing <path>   the dll path pointed at a file that is not there: NULL / NOTNULL, and THREW when anything escaped
using System;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;

namespace IRDash
{
    static class Log { public static void W(string s) { Console.WriteLine("LOG " + s); } }

    static class NvmlDriver
    {
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool GetThreadTimes(IntPtr h, out long c, out long e, out long k, out long u);
        static long ThreadCpu() { long c, e, k, u; return GetThreadTimes(GetCurrentThread(), out c, out e, out k, out u) ? k + u : 0; }
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        static int Main(string[] a)
        {
            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
            Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
            try
            {
                if (a[0] == "read")
                {
                    NvmlRow r = Nvml.Read();
                    if (r == null) { Console.WriteLine("NULL " + Nvml.LastError); return 0; }
                    Console.WriteLine("ROW " + r.Load.ToString("0", Inv) + " " + r.Clock.ToString("0", Inv) + " " + r.MemClock.ToString("0", Inv) + " " + r.Temp.ToString("0", Inv) + " " +
                                      r.VramMb.ToString("0", Inv) + " " + r.VramTotalMb.ToString("0", Inv) + " " + r.PowerW.ToString("0.0", Inv) + " 0x" + r.Throttle.ToString("x") + " " + (r.ThrottleWord.Length > 0 ? r.ThrottleWord : "-"));
                    Nvml.Shutdown();
                    return 0;
                }
                if (a[0] == "cost")
                {
                    int ms = int.Parse(a[1], Inv); double secs = double.Parse(a[2], Inv);
                    Nvml.Read();                                        // the one-time start is not part of the per-row cost
                    long c0 = ThreadCpu(); Stopwatch sw = Stopwatch.StartNew(); int n = 0;
                    Stopwatch inRead = new Stopwatch();         // wall time inside Read: an upper bound of its CPU, finer than the 15.6 ms thread clock
                    while (sw.Elapsed.TotalSeconds < secs) { inRead.Start(); Nvml.Read(); inRead.Stop(); n++; Thread.Sleep(ms); }
                    double cpuMs = (ThreadCpu() - c0) / 1e4, wallMs = sw.Elapsed.TotalMilliseconds;
                    Console.WriteLine("COST " + (cpuMs / wallMs * 100).ToString("0.0000", Inv) + " CPUMS " + cpuMs.ToString("0.0", Inv) + " PERREAD " + (cpuMs / Math.Max(1, n)).ToString("0.000", Inv) + " WALLPCT " + (inRead.Elapsed.TotalMilliseconds / wallMs * 100).ToString("0.0000", Inv) +
                                      " READMS " + (inRead.Elapsed.TotalMilliseconds / Math.Max(1, n)).ToString("0.000", Inv) + " READS " + Nvml.Reads + " FAILS " + Nvml.Fails);
                    Nvml.Shutdown();
                    return 0;
                }
                if (a[0] == "missing")
                {
                    Nvml.DllPath = a[1];
                    NvmlRow r1 = Nvml.Read(), r2 = Nvml.Read();
                    Console.WriteLine((r1 == null && r2 == null ? "NULL" : "NOTNULL") + " FAILS " + Nvml.Fails);
                    return 0;
                }
            }
            catch (Exception ex) { Console.WriteLine("THREW " + ex.GetType().Name + ": " + ex.Message); return 1; }
            Console.WriteLine("unknown mode"); return 2;
        }
    }
}
