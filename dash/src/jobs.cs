// Jobs (W0-3): one background queue for the heavy work that must never run while Peter drives (plan rule 2).
// The 12 Nov freeze happened while Paddock cut a 90 MB clip at normal disk priority; housekeeping could delete GB files every
// 5 s; the last session's 1.1 GB encode could run during the next one. None of it waited for the session to end.
//   Run(name, work, whenFree)  whenFree jobs wait until no session has been on for GraceMs (20 s), then run ONE AT A TIME, in
//                              the order they were queued, on one thread in Windows' background mode (THREAD_MODE_BACKGROUND_BEGIN:
//                              low CPU, very low disk and memory priority for this thread). Other jobs run on the same thread at
//                              once. A job with the same name already waiting is not queued twice.
//   ShouldYield                true inside a whenFree job once a session starts: the job finishes the step it is on and queues
//                              the rest again with Again() (which jobs do: see docs in the report / the W0-3 card).
//   LowerChild(p)              a program a job starts (ffmpeg) gets very low disk priority too: background mode is per thread
//                              and does not pass to child processes.
//   Status()                   JSON for RIG and the tests.
// One log line per job: "jobs: <name> ran (waited 12.3 s, took 0.8 s)". Routine upkeep that neither waited nor took a second
// stays out of the log (it runs every 30 s).
// Depends on nothing in irdash but Log: tests\jobs-test.ps1 compiles it with log.cs and a pretend session.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace IRDash
{
    static class Jobs
    {
        sealed class Job { public string Name; public Action Work; public bool WhenFree, Routine; public DateTime Queued; }
        sealed class Ran { public string Name; public double Waited, Took; public bool WhenFree, Yielded; public string Error = ""; public DateTime At; }

        // is a session on? Program sets it to RigState.SessionOn; tests set a stub. null = never.
        public static Func<bool> SessionOn;
        public static Func<DateTime> Clock;                 // tests
        public static int GraceMs = 20000;                  // after a session ends: a practice -> race visit reconnects in seconds

        static readonly object gate = new object();
        static readonly List<Job> queue = new List<Job>();
        static readonly List<Ran> recent = new List<Ran>();
        static Thread worker;
        static Job running; static DateTime runningSince;
        static bool wasOn; static DateTime freeSince = DateTime.MinValue;      // MinValue = no session seen yet: free at once
        static bool yielded;
        static long ranCount, yieldCount;
        [ThreadStatic] static bool onWorker;

        static DateTime Now { get { return Clock != null ? Clock() : DateTime.UtcNow; } }
        static bool On() { try { return SessionOn != null && SessionOn(); } catch { return false; } }

        // one look at the session: remembers when it ended (the grace period counts from there)
        static bool FreeNow(DateTime now)
        {
            bool on = On();
            lock (gate)
            {
                if (on) { wasOn = true; return false; }
                if (wasOn) { wasOn = false; freeSince = now; }
                return freeSince == DateTime.MinValue || (now - freeSince).TotalMilliseconds >= GraceMs;
            }
        }
        public static bool Free { get { return FreeNow(Now); } }

        // irdash start: the worker watches the session from now on, so the grace period after a session is never skipped
        public static void Start() { lock (gate) EnsureWorker(); }
        static void EnsureWorker()
        {
            if (worker != null) return;
            worker = new Thread(Loop);
            worker.IsBackground = true; worker.Name = "Jobs"; worker.Priority = ThreadPriority.BelowNormal;
            worker.Start();
        }

        public static bool Run(string name, Action work, bool whenFree) { return Add(name, work, whenFree, false); }
        // upkeep that runs every few seconds: logged only when it waited for a session or took a second
        public static bool Routine(string name, Action work) { return Add(name, work, true, true); }

        static bool Add(string name, Action work, bool whenFree, bool routine)
        {
            if (work == null) return false;
            lock (gate)
            {
                foreach (Job q in queue) if (q.Name == name) return false;      // already waiting: once is enough
                Job j = new Job(); j.Name = name ?? "job"; j.Work = work; j.WhenFree = whenFree; j.Routine = routine; j.Queued = Now;
                queue.Add(j);
                EnsureWorker();
                Monitor.PulseAll(gate);
            }
            return true;
        }

        // inside a whenFree job: a session has started, stop after this step
        public static bool ShouldYield { get { return onWorker && running != null && running.WhenFree && On(); } }
        public static bool OnWorker { get { return onWorker; } }

        // the rest of a job that stopped for a session: queued again, waiting for the next free moment
        public static void Again(string name, Action rest)
        {
            lock (gate) { yielded = true; yieldCount++; }
            Log.W("jobs: " + name + " paused - a session started; the rest runs after it");
            Add(name, rest, true, false);
        }

        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool SetThreadPriority(IntPtr thread, int priority);
        const int THREAD_MODE_BACKGROUND_BEGIN = 0x00010000;
        public static bool Background;           // true once Windows accepted background mode for the worker

        static void Loop()
        {
            onWorker = true;
            // low CPU, very low disk and memory priority for everything this thread does (deletes, copies, file reads)
            try { Background = SetThreadPriority(GetCurrentThread(), THREAD_MODE_BACKGROUND_BEGIN); } catch { Background = false; }
            if (!Background) Log.W("jobs: Windows did not accept background mode for the job thread - jobs run at below-normal priority only");
            while (true)
            {
                Job j = null;
                try
                {
                    DateTime now = Now;
                    bool free = FreeNow(now);
                    lock (gate)
                    {
                        foreach (Job q in queue) if (!q.WhenFree || free) { j = q; break; }     // the first one that may run, in order
                        if (j == null) { Monitor.Wait(gate, 500); continue; }                  // nothing may run: look again in 0.5 s
                        queue.Remove(j); running = j; runningSince = now; yielded = false;
                    }
                    Stopwatch sw = Stopwatch.StartNew(); string err = "";
                    try { j.Work(); }
                    catch (Exception ex) { err = ex.Message; Log.W("jobs: " + j.Name + " failed: " + ex.Message); }
                    Ran r = new Ran(); r.Name = j.Name; r.WhenFree = j.WhenFree; r.At = Now; r.Error = err;
                    r.Waited = Math.Max(0, (runningSince - j.Queued).TotalSeconds); r.Took = sw.Elapsed.TotalSeconds;
                    lock (gate) { r.Yielded = yielded; running = null; recent.Add(r); if (recent.Count > 40) recent.RemoveAt(0); ranCount++; }
                    if (!j.Routine || r.Waited >= 1 || r.Took >= 1 || r.Yielded || err.Length > 0)
                        Log.W("jobs: " + j.Name + " ran (waited " + S(r.Waited) + " s, took " + S(r.Took) + " s" + (r.Yielded ? ", paused for a session" : "") + ")");
                }
                catch (Exception ex) { lock (gate) running = null; Log.W("jobs: " + ex.Message); Thread.Sleep(1000); }
            }
        }

        static string S(double v) { return v.ToString("0.0", CultureInfo.InvariantCulture); }

        // ---- child programs (ffmpeg, ffprobe) a job starts: very low disk priority, below-normal CPU ----
        [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr process, int cls, ref int info, int len);
        const int ProcessIoPriority = 33;        // 0 = very low, 1 = low, 2 = normal (lowering needs no privilege)
        public static bool LowerChild(Process p)
        {
            if (p == null) return false;
            bool ok = false;
            try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
            try { int io = 0; ok = NtSetInformationProcess(p.Handle, ProcessIoPriority, ref io, 4) == 0; } catch { ok = false; }
            return ok;
        }

        // ---- GET /api/test/jobs (test mode), RIG later ----
        public static string Status()
        {
            DateTime now = Now; bool free = FreeNow(now), on = On();
            StringBuilder sb = new StringBuilder("{");
            lock (gate)
            {
                sb.Append("\"free\":").Append(free ? "true" : "false").Append(",\"sessionOn\":").Append(on ? "true" : "false")
                  .Append(",\"graceS\":").Append(S(GraceMs / 1000.0)).Append(",\"background\":").Append(Background ? "true" : "false")
                  .Append(",\"ran\":").Append(ranCount).Append(",\"yields\":").Append(yieldCount);
                sb.Append(",\"running\":");
                if (running == null) sb.Append("null");
                else sb.Append("{\"name\":").Append(Q(running.Name)).Append(",\"forS\":").Append(S((now - runningSince).TotalSeconds)).Append('}');
                sb.Append(",\"queued\":[");
                for (int i = 0; i < queue.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append("{\"name\":").Append(Q(queue[i].Name)).Append(",\"whenFree\":").Append(queue[i].WhenFree ? "true" : "false")
                      .Append(",\"waitingS\":").Append(S((now - queue[i].Queued).TotalSeconds)).Append('}');
                }
                sb.Append("],\"recent\":[");
                for (int i = 0; i < recent.Count; i++)
                {
                    Ran r = recent[i]; if (i > 0) sb.Append(',');
                    sb.Append("{\"name\":").Append(Q(r.Name)).Append(",\"whenFree\":").Append(r.WhenFree ? "true" : "false")
                      .Append(",\"waitedS\":").Append(S(r.Waited)).Append(",\"tookS\":").Append(r.Took.ToString("0.000", CultureInfo.InvariantCulture))
                      .Append(",\"yielded\":").Append(r.Yielded ? "true" : "false").Append(",\"error\":").Append(Q(r.Error))
                      .Append(",\"at\":").Append(Q(r.At.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture))).Append('}');
                }
                sb.Append("]");
            }
            return sb.Append('}').ToString();
        }

        static string Q(string s)
        {
            StringBuilder b = new StringBuilder("\"");
            foreach (char c in s ?? "")
            {
                if (c == '"' || c == '\\') b.Append('\\').Append(c);
                else if (c < ' ') b.Append("\\u").Append(((int)c).ToString("x4"));
                else b.Append(c);
            }
            return b.Append('"').ToString();
        }
    }
}
