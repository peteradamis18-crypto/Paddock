// Proc (W0-3): the one place irdash looks at the process list, with a counter. About 40 places used to call
// Process.GetProcessesByName inline (never disposed), several every 2 s for the whole race. Now:
//   ByName(name)              a real scan, counted (the caller disposes what it gets)
//   Held(name)                the program's Process, watched through a held handle once found (HasExited costs nothing);
//                             a scan only while it is not there
//   Running(name)             Held(name) != null
//   RunningCached(name, s)    for pages that poll: a held handle answers at once; otherwise the last answer is kept for s
//                             seconds, and while a session is on a program that was missing is not looked for again at all
// Scans / Json(): how many scans, per program name (the load test fails on any scan while a session is on; the perf
// sampler's one 5 s process read for the black box is the only one that does not come through here, on purpose).
// Depends on nothing in irdash: tests\jobs-test.ps1 compiles it with jobs.cs.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace IRDash
{
    static class Proc
    {
        static readonly object gate = new object();
        static readonly Dictionary<string, int> perName = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        static readonly Dictionary<string, Process> held = new Dictionary<string, Process>(StringComparer.OrdinalIgnoreCase);
        static readonly Dictionary<string, KeyValuePair<DateTime, bool>> last = new Dictionary<string, KeyValuePair<DateTime, bool>>(StringComparer.OrdinalIgnoreCase);
        static long scans;

        // is a session on? (Program sets it to RigState.SessionOn; null = never). Never asked from inside RigState's own probe.
        public static Func<bool> InSession;
        static bool Session() { try { return InSession != null && InSession(); } catch { return false; } }

        public static long Scans { get { return Interlocked.Read(ref scans); } }

        static void Count(string name)
        {
            Interlocked.Increment(ref scans);
            lock (gate) { int n; perName.TryGetValue(name ?? "*", out n); perName[name ?? "*"] = n + 1; }
        }

        // a real scan of the process list (counted). The caller owns (and disposes) what comes back.
        public static Process[] ByName(string name)
        {
            Count(name);
            try { return Process.GetProcessesByName(name); } catch { return new Process[0]; }
        }

        // every process (counted as "*")
        public static Process[] All()
        {
            Count("*");
            try { return Process.GetProcesses(); } catch { return new Process[0]; }
        }

        public static void Dispose(Process[] ps) { if (ps == null) return; foreach (Process p in ps) { try { p.Dispose(); } catch { } } }

        // The program's Process, kept with a real handle so the next look is HasExited (no scan). null = not running.
        // Do not dispose what this returns: Proc owns it.
        public static Process Held(string name)
        {
            Process p;
            lock (gate) held.TryGetValue(name, out p);
            if (p != null)
            {
                bool gone; try { gone = p.HasExited; } catch { gone = true; }
                if (!gone) return p;
                lock (gate) { Process q; if (held.TryGetValue(name, out q) && q == p) held.Remove(name); }
                try { p.Dispose(); } catch { }
            }
            Process[] ps = ByName(name);
            Process keep = null;
            for (int i = 0; i < ps.Length; i++)
            {
                if (keep == null)
                {
                    // reading Handle makes .NET open and keep a real handle (otherwise HasExited would re-open by id, which Windows may reuse)
                    try { if (ps[i].Handle != IntPtr.Zero) { keep = ps[i]; continue; } } catch { }
                }
                try { ps[i].Dispose(); } catch { }
            }
            if (keep != null) lock (gate) held[name] = keep;
            lock (gate) last[name] = new KeyValuePair<DateTime, bool>(DateTime.UtcNow, keep != null || ps.Length > 0);
            return keep;
        }

        public static bool Running(string name) { return Held(name) != null; }

        // For pages that poll every few seconds: never a scan per request.
        public static bool RunningCached(string name, double seconds)
        {
            Process p;
            lock (gate) held.TryGetValue(name, out p);
            if (p != null)
            {
                bool gone; try { gone = p.HasExited; } catch { gone = true; }
                if (!gone) return true;
                // it ended: that is known without a scan
                lock (gate) { Process q; if (held.TryGetValue(name, out q) && q == p) held.Remove(name); last[name] = new KeyValuePair<DateTime, bool>(DateTime.UtcNow, false); }
                try { p.Dispose(); } catch { }
            }
            KeyValuePair<DateTime, bool> l; bool have;
            lock (gate) have = last.TryGetValue(name, out l);
            if (have && (Session() || (DateTime.UtcNow - l.Key).TotalSeconds < seconds)) return l.Value;
            return Held(name) != null;
        }

        // GET /api/test/proc (test mode) and the load test: total scans and per program name
        public static string Json()
        {
            StringBuilder sb = new StringBuilder("{\"scans\":");
            sb.Append(Scans).Append(",\"byName\":{");
            lock (gate)
            {
                bool first = true;
                foreach (KeyValuePair<string, int> kv in perName)
                {
                    if (!first) sb.Append(','); first = false;
                    sb.Append('"').Append(kv.Key.Replace("\\", "\\\\").Replace("\"", "\\\"")).Append("\":").Append(kv.Value);
                }
            }
            return sb.Append("}}").ToString();
        }
    }
}
