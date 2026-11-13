// The spotter and engineer voice (CrewChief) must be there in every session, however it was started (Peter 2026-11-02: "intermittent,
// dont load every time, all sessions"). The START keys only checked it for some of the ways in, and CrewChief ran for 10 days through
// sleeps and sound device changes. So: a fresh CrewChief each time the sim program starts (before he can be in the car), started again
// if it dies, and the sound checked when the sim connects. Nothing here runs while he is on track.
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace IRDash
{
    static class SpotterGuard
    {
        const string SimName = RigState.SimProcess, Name = "CrewChiefV4";
        // The one owner of starting CrewChief (W0-9; 09: Rig Doctor had its own path and copy of this, and two could start within seconds).
        // Rig Doctor asks StartCrewChief; nothing else starts it.
        public const string Exe = @"C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4\CrewChiefV4.exe";
        const int FreshWindowSeconds = 120;    // past this the sim is well under way: leave a running CrewChief alone
        const int SoundChecks = 4, SoundCheckGapSeconds = 10;   // CrewChief's mixer entry can take a few seconds to appear

        public static void Start()
        {
            Thread t = new Thread(Loop);
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Name = "spotter guard";
            t.Start();
        }

        static void Loop()
        {
            bool simWas = false, connectedWas = false;
            int checksLeft = 0; DateTime nextCheck = DateTime.MinValue;
            while (true)
            {
                Thread.Sleep(2000);
                try
                {
                    // W0-2: one rig state; CrewChief is never launched or killed while a session is on (IsOnTrack alone let it happen in the garage)
                    bool simUp = RigState.SimRunning, session = RigState.SessionOn;
                    if (simUp && !simWas && !session) { DateTime st = SimStart(); if (st != DateTime.MinValue) Fresh(st); }
                    simWas = simUp;
                    if (!simUp) { connectedWas = false; checksLeft = 0; continue; }
                    bool connected = Sdk.Latest.Connected;
                    if (!session && Count(Name) == 0) { Log.W("spotter: CrewChief was not running - starting it"); Launch(); }
                    if (Program.IsDriving) { connectedWas = connected; continue; }
                    if (connected && !connectedWas) { checksLeft = SoundChecks; nextCheck = DateTime.Now; }
                    connectedWas = connected;
                    if (checksLeft > 0 && DateTime.Now >= nextCheck)
                    {
                        checksLeft--; nextCheck = DateTime.Now.AddSeconds(SoundCheckGapSeconds);
                        if (CheckSound()) checksLeft = 0;
                    }
                }
                catch (Exception ex) { Log.W("spotter: " + ex.Message); }
            }
        }

        // when the sim program started (MinValue = could not tell); every Process is disposed
        static DateTime SimStart()
        {
            Process[] ps; try { ps = Process.GetProcessesByName(SimName); } catch { return DateTime.MinValue; }
            DateTime t = DateTime.MinValue;
            foreach (Process p in ps) { try { if (t == DateTime.MinValue) t = p.StartTime; } catch { } p.Dispose(); }
            return t;
        }
        static int Count(string name)
        {
            Process[] ps; try { ps = Process.GetProcessesByName(name); } catch { return -1; }
            foreach (Process p in ps) p.Dispose();
            return ps.Length;
        }

        // Started before this sim run? Then it has been through sleeps and device changes: replace it.
        static void Fresh(DateTime simStart)
        {
            if ((DateTime.Now - simStart).TotalSeconds > FreshWindowSeconds) return;
            Process[] cc = Process.GetProcessesByName(Name);
            if (cc.Length == 0) { Log.W("spotter: the sim started, CrewChief was not running - starting it"); Launch(); return; }
            bool old = false;
            foreach (Process p in cc) { try { if (p.StartTime < simStart) old = true; } catch { } }
            if (!old) return;
            foreach (Process p in cc) { try { p.Kill(); p.WaitForExit(4000); } catch { } }
            Log.W("spotter: the sim started - fresh CrewChief");
            Launch();
        }

        static void Launch() { StartCrewChief("spotter guard"); }

        // Starts CrewChief unless it is running or was started in the last 30 s (it takes a few seconds to show up as a process).
        // true = it was started now. who: for the log.
        static readonly object launchGate = new object();
        static DateTime launchedAt = DateTime.MinValue;
        public static bool StartCrewChief(string who)
        {
            lock (launchGate)
            {
                if (!File.Exists(Exe)) { Log.W("spotter: CrewChief is not installed"); return false; }
                if ((DateTime.Now - launchedAt).TotalSeconds < 30) return false;
                Process[] cc = Process.GetProcessesByName(Name);
                bool up = cc.Length > 0; foreach (Process p in cc) p.Dispose();
                if (up) return false;
                ProcessStartInfo psi = new ProcessStartInfo(Exe);
                psi.UseShellExecute = true; psi.WorkingDirectory = Path.GetDirectoryName(Exe);
                Process.Start(psi);
                launchedAt = DateTime.Now;
                Log.W("spotter: CrewChief started (" + who + ")");
                return true;
            }
        }

        // irdeck owns the sound code: "spotter" unmutes CrewChief and brings it up to its minimum level. Exit 0 = its mixer entry was there.
        static bool CheckSound()
        {
            ProcessStartInfo psi = new ProcessStartInfo(Watch.IrdeckPath, "spotter");
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(Watch.IrdeckPath);
            using (Process p = Process.Start(psi))
            {
                if (!p.WaitForExit(15000)) { try { p.Kill(); } catch { } return false; }
                return p.ExitCode == 0;
            }
        }
    }
}
