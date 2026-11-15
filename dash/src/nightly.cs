// The nightly self-check, started by irdash's own clock (W5-4). No Windows task: irdash runs all day under the logon task, so at 03:00
// local (or at the first tick after 03:00 if irdash was down then, until 06:00) it starts tests\nightly.ps1 hidden at BelowNormal
// when the rig is free (RigState.Busy null) and the PC has had 10 minutes without keyboard/mouse. The script writes tests\nightly.txt;
// the state part "nightly" is its last line (the rules are in nightlyrules.cs). A test copy of irdash (--test) never runs it.
//   dash\irdash.ini  nightly=off  stops it without a rebuild (default on)
//   GET /api/nightly/run   starts it now (the lead's live check; test hook only, 409 while a real session is on)
//   GET /api/nightly/deck  the script's Stream Deck restart (the watchdog's own restart, so the deck opens on MAIN)
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class Nightly
    {
        [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII p);
        static double IdleMinutes() { LII l = new LII(); l.cbSize = 8; if (!GetLastInputInfo(ref l)) return 0; return ((uint)Environment.TickCount - l.dwTime) / 60000.0; }

        static readonly object gate = new object();
        static bool running;
        public static int Port = 8199;           // irdash's own port (set at start); the script talks to it
        static string startedDay = "";          // the night already started in this irdash (the file also remembers across restarts)
        static DateTime lastLook = DateTime.MinValue;
        static string FileName { get { return Path.Combine(Program.RootDir, @"tests\nightly.txt"); } }

        public static bool Running { get { lock (gate) return running; } }
        public static string PartJson() { try { return NightlyRules.PartJson(FileName); } catch { return "null"; } }

        // dash\irdash.ini: nightly=off (or 0) stops it
        static bool On()
        {
            try
            {
                if (Program.IniFile == null || !File.Exists(Program.IniFile)) return true;
                foreach (string raw in File.ReadAllLines(Program.IniFile))
                {
                    Match m = Regex.Match(raw, @"^\s*nightly\s*=\s*(\S+)", RegexOptions.IgnoreCase);
                    if (m.Success) { string v = m.Groups[1].Value.ToLowerInvariant(); return v != "off" && v != "0" && v != "no"; }
                }
            }
            catch { }
            return true;
        }

        // every irdash tick (about 1 s); looks at the clock only every 20 s
        public static void Tick()
        {
            if (Program.TestMode || Program.RootDir == null) return;
            DateTime now = DateTime.Now;
            if ((now - lastLook).TotalSeconds < 20) return;
            lastLook = now;
            bool on = On();
            string last = NightlyRules.LastDay(FileName); if (startedDay.CompareTo(last) > 0) last = startedDay;
            if (NightlyRules.WindowPassed(now, last, on) && !Running)
            {
                // the whole night passed with the rig or the PC in use: say so, once
                startedDay = now.ToString("yyyyMMdd");
                WriteLine(false, "Rig check 03:00: skipped, " + (waitedWhy.Length > 0 ? waitedWhy : "irdash was not running at 03:00"));
                return;
            }
            if (!NightlyRules.IsTime(now, last, on) || Running) return;
            string why = Why();
            if (why != null) { waitedWhy = why; return; }      // try again on the next look, until 06:00
            Start(false);
        }
        static string waitedWhy = "";

        // null = free; else the reason in Peter's words
        static string Why()
        {
            if (RigState.Busy) return RigState.SimRunning ? "the sim was running" : RigState.StartPressed ? "a START key was pressed lately" : "Peter was driving";
            if (IdleMinutes() < 10) return "Peter was at the PC";
            return null;
        }

        // the lead's hook: refused while a real session is on; the script itself still refuses when the rig is busy
        public static string RunNow()
        {
            if (Program.TestMode) return "refused: this is a test copy of irdash";
            if (Running) return "refused: the check is already running";
            Start(true);
            return null;
        }

        static void Start(bool manual)
        {
            string script = Path.Combine(Program.RootDir, @"tests\nightly.ps1");
            if (!File.Exists(script)) { Log.W("nightly: " + script + " is missing"); return; }
            lock (gate) { if (running) return; running = true; }
            startedDay = DateTime.Now.ToString("yyyyMMdd"); waitedWhy = "";
            Thread t = new Thread(delegate ()
            {
                string said = "";
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -Base http://localhost:" + Port);
                    psi.WorkingDirectory = Program.RootDir; psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WindowStyle = ProcessWindowStyle.Hidden;
                    psi.RedirectStandardOutput = true; psi.StandardOutputEncoding = Encoding.UTF8;
                    Log.W("nightly: the rig check starts" + (manual ? " (asked by hand)" : ""));
                    using (Process p = Process.Start(psi))
                    {
                        try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
                        StringBuilder outp = new StringBuilder();
                        p.OutputDataReceived += delegate (object o, DataReceivedEventArgs e) { if (e.Data != null && outp.Length < 8000) outp.AppendLine(e.Data); };
                        p.BeginOutputReadLine();
                        if (!p.WaitForExit(12 * 60 * 1000))
                        {
                            Log.W("nightly: still running after 12 minutes - stopped");
                            try { Process.Start(new ProcessStartInfo("taskkill", "/PID " + p.Id + " /T /F") { CreateNoWindow = true, UseShellExecute = false }).WaitForExit(5000); } catch { }
                            try { p.Kill(); } catch { }
                            WriteLine(false, "Rig check 03:00: did not finish (it took too long)");
                        }
                        else if (p.ExitCode == 3) said = outp.ToString();     // the guard said no
                        else if (p.ExitCode != 0) WriteLine(false, "Rig check 03:00: did not finish (the check stopped unexpectedly)");
                    }
                    if (said.Length > 0)
                    {
                        Match m = Regex.Match(said, @"NOT SAFE TO TEST: ([^\r\n]*?)\.? Nothing was changed|NOT RUN \(([^)]*)\): ([^\r\n]*?)\.? Nothing was changed");
                        string reason = m.Success ? (m.Groups[1].Success && m.Groups[1].Length > 0 ? m.Groups[1].Value : "another test was using the rig") : "the rig was in use";
                        // only when the script wrote nothing today (it writes its own skipped line for the known reasons)
                        if (NightlyRules.LastDay(FileName) != DateTime.Now.ToString("yyyyMMdd")) WriteLine(false, "Rig check 03:00: skipped, " + reason);
                    }
                }
                catch (Exception ex) { Log.W("nightly: " + ex.Message); try { WriteLine(false, "Rig check 03:00: did not finish (irdash could not start the check)"); } catch { } }
                finally { lock (gate) running = false; StateBuilder.Changed("nightly"); Log.W("nightly: done - " + PartJson()); }
            });
            t.IsBackground = true; t.Name = "Nightly"; t.Start();
        }

        static void WriteLine(bool ok, string text)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FileName));
                NightlyRules.Append(FileName, NightlyRules.Row(DateTime.Now, ok, text));
                StateBuilder.Changed("nightly");
            }
            catch (Exception ex) { Log.W("nightly: line not written: " + ex.Message); }
        }
    }
}
