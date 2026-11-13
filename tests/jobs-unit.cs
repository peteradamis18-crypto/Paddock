// tests\jobs-test.ps1 compiles this with dash\src\jobs.cs, proc.cs and log.cs: a pretend session, no irdash, no sim.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class JobsUnit
    {
        static int pass, fail;
        static void Check(string what, bool ok) { if (ok) { pass++; Console.WriteLine("  ok    " + what); } else { fail++; Console.WriteLine("  FAIL  " + what); } }
        static volatile bool on;
        static readonly object lk = new object();
        static readonly List<string> events = new List<string>();
        static void Ev(string s) { lock (lk) events.Add(s); }
        static bool WaitFor(Func<bool> f, int ms) { Stopwatch sw = Stopwatch.StartNew(); while (sw.ElapsedMilliseconds < ms) { if (f()) return true; Thread.Sleep(20); } return f(); }
        static int Count(string prefix) { lock (lk) { int n = 0; foreach (string e in events) if (e.StartsWith(prefix)) n++; return n; } }

        static int Main(string[] args)
        {
            string tmp = args.Length > 0 ? args[0] : Path.GetTempPath();
            Log.FilePath = Path.Combine(tmp, "jobs-unit.log");
            Jobs.SessionOn = delegate { return on; };
            Jobs.GraceMs = 1500;           // the real one is 20 s
            Jobs.Start();

            Console.WriteLine("1. a job queued while free runs at once");
            Stopwatch t1 = Stopwatch.StartNew(); long ranAt = -1;
            Jobs.Run("free one", delegate { ranAt = t1.ElapsedMilliseconds; }, true);
            Check("ran within 0.7 s (no session was ever on)", WaitFor(delegate { return ranAt >= 0; }, 2000) && ranAt < 700);

            Console.WriteLine("2. whenFree jobs wait while a session is on, then run one at a time, in order, after the grace period");
            on = true; Thread.Sleep(700);     // the worker sees the session
            List<long[]> spans = new List<long[]>(); Stopwatch t2 = Stopwatch.StartNew();
            for (int i = 1; i <= 3; i++)
            {
                int k = i;
                Jobs.Run("cut " + k, delegate { long s = t2.ElapsedMilliseconds; Ev("cut " + k); Thread.Sleep(150); lock (lk) spans.Add(new long[] { k, s, t2.ElapsedMilliseconds }); }, true);
            }
            Check("a second job with the same name is not queued twice", !Jobs.Run("cut 2", delegate { Ev("dupe"); }, true));
            Thread.Sleep(1500);
            Check("nothing ran while the session was on (1.5 s)", Count("cut ") == 0);
            bool nowRan = false;
            Jobs.Run("light", delegate { nowRan = true; }, false);
            Check("a job that need not wait runs while the session is on", WaitFor(delegate { return nowRan; }, 1500));
            string st = Jobs.Status();
            Check("Status() says the session is on, not free, and lists the 3 waiting jobs", st.Contains("\"sessionOn\":true") && st.Contains("\"free\":false") && st.Contains("\"name\":\"cut 1\"") && st.Contains("\"name\":\"cut 3\""));
            long offAt = t2.ElapsedMilliseconds; on = false;
            Thread.Sleep(900);
            Check("still waiting 0.9 s after the session ended (grace 1.5 s)", Count("cut ") == 0);
            Check("all three ran after the grace period", WaitFor(delegate { lock (lk) return spans.Count == 3; }, 4000));
            lock (lk)
            {
                bool order = spans.Count == 3 && spans[0][0] == 1 && spans[1][0] == 2 && spans[2][0] == 3;
                bool apart = spans.Count == 3 && spans[1][1] >= spans[0][2] && spans[2][1] >= spans[1][2];
                if (!order || !apart) foreach (long[] s in spans) Console.WriteLine("    cut " + s[0] + " " + s[1] + "-" + s[2] + " ms");
                Check("in the order they were queued", order);
                Check("one at a time (no overlap)", apart);
                Check("the first started at least the grace period after the session ended (" + (spans.Count > 0 ? spans[0][1] - offAt : -1) + " ms)", spans.Count > 0 && spans[0][1] - offAt >= 1400);
            }

            Console.WriteLine("3. a job stops at a step when a session starts and the rest runs after it");
            int steps = 0;
            Action work = null;
            Func<int, Action> from = null;
            from = delegate (int start)
            {
                return delegate
                {
                    for (int i = start; i < 10; i++)
                    {
                        if (Jobs.ShouldYield) { int rest = i; Jobs.Again("steps", from(rest)); return; }
                        Thread.Sleep(80); Interlocked.Increment(ref steps);
                        if (i == 2) on = true;          // a session starts during step 3
                    }
                };
            };
            work = from(0);
            Jobs.Run("steps", work, true);
            Check("stopped after the step it was on (3 of 10 done)", WaitFor(delegate { return steps == 3; }, 3000) && WaitFor(delegate { return Jobs.Status().Contains("\"yields\":1"); }, 2000));
            Thread.Sleep(800);
            Check("did not carry on while the session is on", steps == 3);
            on = false;
            Check("the rest ran after the session (10 of 10)", WaitFor(delegate { return steps == 10; }, 5000));
            Check("Status() counts the pause", Jobs.Status().Contains("\"yields\":1"));

            Console.WriteLine("4. Status() JSON");
            Dictionary<string, object> d = null;
            try { d = new JavaScriptSerializer().DeserializeObject(Jobs.Status()) as Dictionary<string, object>; } catch (Exception ex) { Console.WriteLine("    " + ex.Message); }
            Check("parses, with free / running / queued / recent / ran", d != null && d.ContainsKey("free") && d.ContainsKey("running") && d.ContainsKey("queued") && d.ContainsKey("recent") && d.ContainsKey("ran"));
            Check("recent jobs say how long they waited and took", d != null && Jobs.Status().Contains("\"name\":\"cut 1\",\"whenFree\":true,\"waitedS\":"));

            Console.WriteLine("5. the job thread runs in Windows' background mode; a child program gets very low disk priority");
            Check("background mode accepted (THREAD_MODE_BACKGROUND_BEGIN)", Jobs.Background);
            bool lowered = false;
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), "/c ping -n 2 127.0.0.1 >nul");
                psi.UseShellExecute = false; psi.CreateNoWindow = true;
                using (Process p = Process.Start(psi)) { lowered = Jobs.LowerChild(p); p.WaitForExit(5000); }
            }
            catch (Exception ex) { Console.WriteLine("    " + ex.Message); }
            Check("LowerChild set the child's disk priority to very low", lowered);

            Console.WriteLine("6. Proc: one counted way to look at the process list");
            string me = Process.GetCurrentProcess().ProcessName;
            long s0 = Proc.Scans;
            Check("Running(own program) is true", Proc.Running(me));
            long s1 = Proc.Scans;
            Check("the first look is one counted scan", s1 - s0 == 1);
            Check("the next looks use the held handle (no scan)", Proc.Running(me) && Proc.RunningCached(me, 5) && Proc.Scans == s1);
            Check("a missing program: one scan, then the cached answer for 5 s", !Proc.RunningCached("no-such-program-w03", 5) && !Proc.RunningCached("no-such-program-w03", 5) && Proc.Scans == s1 + 1);
            bool inSess = true; Proc.InSession = delegate { return inSess; };
            Thread.Sleep(10);
            Check("while a session is on a missing program is never looked for again", !Proc.RunningCached("no-such-program-w03", 0) && Proc.Scans == s1 + 1);
            inSess = false;
            Check("out of the session the 0 s cache looks again (counted)", !Proc.RunningCached("no-such-program-w03", 0) && Proc.Scans == s1 + 2);
            Check("Json() lists the scans per program", Proc.Json().Contains("\"no-such-program-w03\":2"));

            Console.WriteLine("7. Proc.Held from many threads at once keeps one handle (review #9)");
            Process ping = null;
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "PING.EXE"), "-n 6 127.0.0.1"); psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true;
                ping = Process.Start(psi); Thread.Sleep(300);
                Process[] got = new Process[8]; Thread[] ts = new Thread[8]; ManualResetEvent go = new ManualResetEvent(false);
                for (int i = 0; i < 8; i++) { int k = i; ts[k] = new Thread(delegate () { go.WaitOne(); got[k] = Proc.Held("PING"); }); ts[k].Start(); }
                go.Set(); foreach (Thread t in ts) t.Join();
                bool same = got[0] != null; foreach (Process g in got) if (g != got[0]) same = false;
                bool usable = true; try { bool ex = got[0].HasExited; } catch { usable = false; }
                Check("all 8 callers got the same held Process, and it is still usable (no second handle kept, none disposed under them)", same && usable);
            }
            catch (Exception ex) { Check("Held race: " + ex.Message, false); }
            finally { try { if (ping != null) { ping.Kill(); ping.Dispose(); } } catch { } }

            Console.WriteLine("8. the overlays are raised when the sim covers them (review #1, a pretend z-order)");
            IntPtr top = new IntPtr(1), sim = new IntPtr(2), ovA = new IntPtr(3), ovB = new IntPtr(4);
            // top to bottom: ovA, sim, ovB  (ovB is below the sim although it may still carry the TOPMOST flag)
            Dictionary<IntPtr, IntPtr> up = new Dictionary<IntPtr, IntPtr>(); up[ovA] = top; up[sim] = ovA; up[ovB] = sim; up[top] = IntPtr.Zero;
            Func<IntPtr, IntPtr> above = delegate (IntPtr h) { IntPtr a; return up.TryGetValue(h, out a) ? a : IntPtr.Zero; };
            Check("an overlay above the sim is fine", !ZOrder.SimAbove(ovA, sim, above, 100));
            Check("an overlay below the sim is seen", ZOrder.SimAbove(ovB, sim, above, 100));
            Check("raise when driving starts", ZOrder.ShouldRaise(true, false, false, true, true));
            Check("raise when one is below the sim", ZOrder.ShouldRaise(true, true, true, true, true));
            Check("raise when the sim comes back to the front (a focus steal and return)", ZOrder.ShouldRaise(true, true, false, true, false));
            Check("no raise every tick while all is well (no 5 s loop)", !ZOrder.ShouldRaise(true, true, false, true, true));
            Check("never out of the car", !ZOrder.ShouldRaise(false, true, true, true, false));

            Console.WriteLine("9. two personal bests in one session: the faster one is written, never over a quicker one on disk (review #2)");
            PendingSlot<double[]> slot = new PendingSlot<double[]>(delegate (double[] a, double[] b) { return a[0] <= b[0]; });
            double written = 0; double disk = 0;
            on = true; Thread.Sleep(600);
            Action save = delegate { double[] v = slot.Take("rd"); if (v != null && SaveRule.ShouldWrite(v[0], disk)) { disk = v[0]; written = v[0]; } };
            slot.Put("rd", new double[] { 93.832 }); bool q1 = Jobs.Save("pb save rd", save);
            slot.Put("rd", new double[] { 93.639 }); bool q2 = Jobs.Save("pb save rd", save);
            Check("the second save is the same job (one per name)", q1 && !q2);
            disk = 93.700;      // the reference build ran first after the session and wrote 1:33.700
            on = false;
            WaitFor(delegate { return slot.Count == 0; }, 5000); Thread.Sleep(200);
            Check("the job wrote the second, faster lap (1:33.639), not the first", written == 93.639 && disk == 93.639);
            Check("a slower lap never goes over a quicker one on disk", !SaveRule.ShouldWrite(93.832, 93.639) && SaveRule.ShouldWrite(93.639, 93.700) && SaveRule.ShouldWrite(93.0, 0));

            Console.WriteLine("10. at exit the waiting saves are written at once; heavy jobs are not (review #7)");
            on = true; Thread.Sleep(600);
            bool savedAtExit = false, heavyRan = false;
            Jobs.Save("vault save test", delegate { savedAtExit = true; });
            Jobs.Run("recorder cut test", delegate { heavyRan = true; }, true);
            int drained = Jobs.Drain(2000);
            Check("Drain ran the save while the session was still on", savedAtExit && drained == 1);
            Check("and left the cut for later", !heavyRan && Jobs.Status().Contains("\"name\":\"recorder cut test\""));
            on = false;
            WaitFor(delegate { return heavyRan; }, 5000);

            Log.Flush(2000);
            Console.WriteLine(pass + " passed, " + fail + " failed.");
            return fail > 0 ? 1 : 0;
        }
    }
}
