// tests\log-roll-test.ps1 compiles dash\src\log.cs with this file.
//   log-roll-harness.exe <dir> <MB> <threads>   writes about <MB> MB of numbered lines through Log.W from <threads> threads at once,
//                                                waits for the writer, and prints how long the Log.W calls themselves took
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace IRDash
{
    static class LogRollHarness
    {
        static int Main(string[] args)
        {
            string dir = args[0]; double mb = double.Parse(args[1], System.Globalization.CultureInfo.InvariantCulture); int threads = int.Parse(args[2]);
            Log.FilePath = Path.Combine(dir, "irdash.log");
            string pad = new string('x', 70);
            int perThread = (int)(mb * 1000000 / 120 / threads);     // a line is about 120 bytes with its time stamp
            long[] spent = new long[threads];
            Thread[] ts = new Thread[threads];
            for (int t = 0; t < threads; t++)
            {
                int me = t;
                ts[t] = new Thread(delegate ()
                {
                    Stopwatch sw = new Stopwatch();
                    for (int i = 0; i < perThread; i++)
                    {
                        sw.Start();
                        Log.W("t" + me + " n" + i.ToString("000000") + " " + pad);
                        sw.Stop();
                    }
                    spent[me] = sw.ElapsedTicks;
                });
                ts[t].Start();
            }
            foreach (Thread t in ts) t.Join();
            bool flushed = Log.Flush(30000);
            long total = 0; foreach (long s in spent) total += s;
            Console.WriteLine("lines " + (perThread * threads) + " perThread " + perThread + " flushed " + flushed + " usPerCall " + (total * 1000000.0 / Stopwatch.Frequency / (perThread * threads)).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture));
            return flushed ? 0 : 1;
        }
    }
}
