// Quiet PC (W5-2): while a session is on, Windows Update, search indexing and OneDrive are paused, and handed back when it ends.
// irdash is not elevated, so it never stops a service itself: Peter's one click (tools\quiet-pc-setup.cmd) registered two tasks of
// his own with highest privileges, and a user may start his own task (schtasks /Run) without a prompt. The task does the services;
// OneDrive (which refuses administrator rights) is quit and restarted by tools\quiet-pc.ps1 run from here, not elevated.
// The session hooks are the ONLY callers: there is no command to press and nothing to forget.
//   SessionStarted  (StateBuilder, when SessionOn rises)   -> "on", once per session, only when data\quiet-pc\setup.json exists
//   SessionEnded    (StateBuilder, session off / sim closed) -> "off", once, only after an "on"
//   Start           (irdash start) -> "off" when the state files still say quiet and no session is on (a crash must not leave it quiet)
// State part "quiet" (W5-1 renders it): {"setup","on","since","say","items":[update, search, onedrive, simprio]}.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class QuietPC
    {
        public const string TaskOn = "Paddock Quiet PC on", TaskOff = "Paddock Quiet PC off";
        public static readonly string[] UpdateServices = { "wuauserv", "UsoSvc" };
        public const string SearchService = "WSearch";

        // test seams (null = the real ones)
        public static string Dir;                       // data\quiet-pc
        public static Func<string, string> ReadService;  // service name -> "Running" / "Stopped" / null (not there)
        public static Func<bool> ReadOneDrive;
        public static int StartDelayMs = 20000;          // irdash start: the SDK has had time to say whether a session is on
        public static int RunTimeoutMs = 10000;

        static string D { get { return Dir ?? Path.Combine(Program.RootDir, @"data\quiet-pc"); } }
        static string ScriptPath { get { return Path.Combine(Program.RootDir, @"tools\quiet-pc.ps1"); } }
        public static bool IsSetUp { get { try { return File.Exists(Path.Combine(D, "setup.json")); } catch { return false; } } }

        static readonly object runGate = new object();
        static volatile bool onThisSession, warnedRestart;
        static int runs;
        public static int Runs { get { return runs; } }

        // ---- the hooks ----
        public static void SessionStarted()
        {
            if (onThisSession) return;          // a second start inside the same session does nothing
            onThisSession = true; warnedRestart = false;
            if (!IsSetUp) { RigState.LogOnce("quiet not set up", "quiet pc: not set up (tools\\quiet-pc-setup.cmd), nothing paused"); return; }
            Run("on");
        }

        public static void SessionEnded()
        {
            bool was = onThisSession; onThisSession = false;
            if (!was) return;                   // fires twice (the session ends, later the sim closes): one "off"
            if (!IsSetUp && !StateSaysOn()) return;
            Run("off");
        }

        public static void Start()
        {
            Thread t = new Thread(delegate ()
            {
                try
                {
                    Thread.Sleep(StartDelayMs);
                    bool on = false; try { on = RigState.SessionOn; } catch { }
                    if (!on && !onThisSession && StateSaysOn())
                    {
                        Log.W("quiet pc: irdash started with the PC still quiet and no session on: handing everything back");
                        Run("off");
                    }
                }
                catch (Exception ex) { Log.W("quiet pc start: " + ex.Message); }
            });
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Name = "QuietPC start"; t.Start();
        }

        // ---- running the task and the script: never on the UI thread, one at a time, BelowNormal, 10 s each at most ----
        static void Run(string verb)
        {
            Thread t = new Thread(delegate ()
            {
                lock (runGate)
                {
                    string said;
                    try
                    {
                        string stub = Environment.GetEnvironmentVariable("PADDOCK_QUIETPC_CMD");
                        if (!string.IsNullOrEmpty(stub)) said = "stub " + Exec("cmd.exe", "/c \"\"" + stub + "\" " + verb + "\"");
                        else if (Program.TestMode) said = "skipped (test mode)";
                        else
                        {
                            string sw = verb == "on" ? "-On" : "-Off";
                            said = "services: task " + Exec("schtasks.exe", "/Run /TN \"" + (verb == "on" ? TaskOn : TaskOff) + "\"") +
                                   "; OneDrive: " + Exec("powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ScriptPath + "\" " + sw);
                        }
                    }
                    catch (Exception ex) { said = "failed: " + ex.Message; }
                    Interlocked.Increment(ref runs);
                    Log.W("quiet pc " + verb + ": " + said);
                    readAt = -100000;
                    try { StateBuilder.Changed("quiet"); } catch { }
                }
            });
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Name = "QuietPC " + verb; t.Start();
        }

        static string Exec(string file, string args)
        {
            ProcessStartInfo psi = new ProcessStartInfo(file, args);
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process p = Process.Start(psi))
            {
                try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
                if (!p.WaitForExit(RunTimeoutMs)) return "still running after " + (RunTimeoutMs / 1000) + " s";
                return "exit " + p.ExitCode;
            }
        }

        // ---- the state files (written by tools\quiet-pc.ps1) ----
        static string ReadFile(string name) { try { string f = Path.Combine(D, name); return File.Exists(f) ? File.ReadAllText(f) : ""; } catch { return ""; } }
        static bool True(string json, string key) { return Regex.IsMatch(json, "\"" + key + "\"\\s*:\\s*true"); }
        static long Num(string json, string key) { Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*([0-9]+)"); long v; return m.Success && long.TryParse(m.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : 0; }
        static List<string> List(string json, string key)
        {
            List<string> r = new List<string>();
            Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\\[([^\\]]*)\\]");
            if (m.Success) foreach (Match s in Regex.Matches(m.Groups[1].Value, "\"([^\"]*)\"")) r.Add(s.Groups[1].Value);
            return r;
        }
        static bool StateSaysOn() { return True(ReadFile("state.json"), "on") || True(ReadFile("onedrive.json"), "paused"); }

        // ---- the real states: at most every 10 s, cached ----
        static readonly Stopwatch clock = Stopwatch.StartNew();
        static long readAt = -100000;
        static string update = "unknown", search = "unknown", onedrive = "running", simprio = "unknown";
        static void ReadReal()
        {
            long now = clock.ElapsedMilliseconds;
            if (now - readAt < 10000) return;
            readAt = now;
            update = Item(UpdateServices); search = Item(new[] { SearchService });
            bool od = true; try { od = ReadOneDrive != null ? ReadOneDrive() : OneDriveRunning(); } catch { }
            onedrive = od ? "running" : "paused";
            try { simprio = SimPriority.ItemState(); } catch { simprio = "unknown"; }
        }
        static string Item(string[] names)
        {
            bool known = false, any = false;
            foreach (string n in names) { string s = Service(n); if (s != null) { known = true; if (s == "Running") any = true; } }
            return !known ? "unknown" : any ? "running" : "paused";
        }
        static bool OneDriveRunning()
        {
            Process[] ps = Proc.ByName("OneDrive");
            try { int me = Process.GetCurrentProcess().SessionId; foreach (Process p in ps) { try { if (p.SessionId == me) return true; } catch { } } return false; }
            finally { Proc.Dispose(ps); }
        }

        // the service's state without System.ServiceProcess (no new reference for every harness that compiles dash\src)
        [DllImport("advapi32.dll", SetLastError = true)] static extern IntPtr OpenSCManager(string machine, string db, uint access);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr OpenService(IntPtr scm, string name, uint access);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool QueryServiceStatus(IntPtr svc, int[] status);
        [DllImport("advapi32.dll")] static extern bool CloseServiceHandle(IntPtr h);
        static string Service(string name)
        {
            if (ReadService != null) return ReadService(name);
            IntPtr scm = OpenSCManager(null, null, 0x0001), svc = IntPtr.Zero;      // SC_MANAGER_CONNECT: no administrator needed
            if (scm == IntPtr.Zero) return null;
            try
            {
                svc = OpenService(scm, name, 0x0004);                                // SERVICE_QUERY_STATUS
                if (svc == IntPtr.Zero) return null;
                int[] st = new int[7];
                if (!QueryServiceStatus(svc, st)) return null;
                return st[1] == 4 ? "Running" : st[1] == 1 ? "Stopped" : "Changing";    // SERVICE_RUNNING / SERVICE_STOPPED
            }
            finally { if (svc != IntPtr.Zero) CloseServiceHandle(svc); CloseServiceHandle(scm); }
        }

        // ---- the "quiet" state part ----
        public static string Json()
        {
            bool setup = IsSetUp;
            string st = ReadFile("state.json"), od = ReadFile("onedrive.json");
            bool svcOn = True(st, "on"), odOn = True(od, "paused"), on = svcOn || odOn;
            long since = 0;
            if (svcOn) since = Num(st, "since");
            if (odOn) { long s2 = Num(od, "since"); if (s2 > 0 && (since == 0 || s2 < since)) since = s2; }
            ReadReal();
            if (svcOn && update == "running" && !warnedRestart) { warnedRestart = true; Log.W("quiet pc: Windows Update is running again while Quiet PC is on (Windows restarted it)"); }
            string dot = " · ", say;
            if (!setup) say = "Quiet PC" + dot + "not set up";
            else if (on) say = "Quiet PC on since " + (since > 0 ? new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(since).ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture) : "now") + dot + PausedWords(svcOn ? List(st, "services") : new List<string>(), odOn);
            else say = "Quiet PC off" + dot + "everything handed back";
            StringBuilder sb = new StringBuilder("{");
            sb.Append("\"setup\":").Append(setup ? "true" : "false").Append(",\"on\":").Append(on ? "true" : "false")
              .Append(",\"since\":").Append(since.ToString(CultureInfo.InvariantCulture)).Append(",\"say\":").Append(Json_.S(say))
              .Append(",\"items\":[").Append(ItemJson("update", "Windows Update", update)).Append(',').Append(ItemJson("search", "Search indexing", search))
              .Append(',').Append(ItemJson("onedrive", "OneDrive", onedrive)).Append(',').Append(ItemJson("simprio", "Sim priority", simprio)).Append("]}");
            return sb.ToString();
        }
        static string ItemJson(string id, string name, string state) { return "{\"id\":\"" + id + "\",\"name\":\"" + name + "\",\"state\":\"" + state + "\"}"; }

        public static string PausedWords(List<string> services, bool od)
        {
            List<string> w = new List<string>();
            if (services.Contains("wuauserv") || services.Contains("UsoSvc")) w.Add("Windows Update");
            if (services.Contains(SearchService)) w.Add("search");
            if (od) w.Add("OneDrive");
            if (w.Count == 0) return "nothing needed pausing";
            if (w.Count == 1) return w[0] + " paused";
            return string.Join(", ", w.GetRange(0, w.Count - 1).ToArray()) + " and " + w[w.Count - 1] + " paused";
        }
    }
}
