// ADD-ON INSTALL (W1-8, docs/rework/cards/W1-8.md): irdash installs the Stream Deck add-on itself, so Peter never clicks Install.
// Why irdash: the lead's Claude session runs in a packaged app whose %APPDATA% writes are redirected to a private copy that Stream
// Deck never sees (CLAUDE.md rule 3); irdash runs outside it. deck-intro\install.ps1 -Stage builds the folder inside the repo,
// tools\addon-update.ps1 then asks /api/do?c=addoninstall: copy the folder in place (atomic swap), restart Stream Deck on MAIN,
// wait for the add-on to connect. Every step the test must not really do is a hook (Func/Action field) the test replaces.
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class AddOn
    {
        const string Uuid = "com.peter.rigintro";
        const string StreamDeckExe = @"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe";
        static readonly object gate = new object();
        static bool busy;

        // ---- hooks (null = the real thing); the file moves are always real ----
        public static string PluginsDir;                 // %APPDATA%\Elgato\StreamDeck\Plugins
        public static string StagedDir;                  // <repo>\deck-intro\build\com.peter.rigintro.sdPlugin
        public static string LockDir;                    // where deck-build.lock goes (the watchdog leaves Stream Deck alone while it is fresh)
        public static Action StopDeck;                   // stop the Stream Deck app
        public static Action StartDeck;                  // set the deck to MAIN and start the app
        public static Func<int, bool> WaitConnected;     // seconds to wait -> did the add-on connect (asked after the start)
        public static Action AfterOldAside;              // test only: runs between "installed -> .old" and ".new -> installed"
        public static int WaitSeconds = 30;

        static string Plugins { get { return PluginsDir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Elgato\StreamDeck\Plugins"); } }
        static string Installed { get { return Path.Combine(Plugins, Uuid + ".sdPlugin"); } }
        static string Staged
        {
            get
            {
                if (StagedDir != null) return StagedDir;
                string root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
                return Path.Combine(root, @"deck-intro\build\" + Uuid + ".sdPlugin");
            }
        }

        public static bool Handles(string c) { return c == "addoninstall"; }

        public static string Version(string dir)
        {
            try
            {
                string m = Path.Combine(dir, "manifest.json");
                if (!File.Exists(m)) return "";
                Match v = Regex.Match(File.ReadAllText(m), "\"Version\"\\s*:\\s*\"([0-9.]+)\"");
                return v.Success ? v.Groups[1].Value : "";
            }
            catch { return ""; }
        }

        static bool Connected()
        {
            try { return Showcase.DeckPollAge < 6; } catch { return false; }
        }

        // GET /api/addon
        public static string Status()
        {
            return "{\"installed\":" + Json_.S(Version(Installed)) + ",\"staged\":" + Json_.S(Version(Staged)) + ",\"connected\":" + (Connected() ? "true" : "false") + "}";
        }

        // /api/do?c=addoninstall -> {"say":"..."}; code 200 = done or already there, 409 = not done
        public static string Do(string c, string a, out int code)
        {
            return Install(out code);
        }

        static string Say(string say) { return "{\"say\":" + Json_.S(say) + "}"; }

        static void Stop() { if (StopDeck != null) StopDeck(); else RealStop(); }
        static void Start() { if (StartDeck != null) StartDeck(); else RealStart(); }
        static bool Wait(int s) { return WaitConnected != null ? WaitConnected(s) : RealWait(s); }

        public static string Install(out int code)
        {
            lock (gate) { if (busy) { code = 409; return Say("The add-on is being installed already - wait a moment"); } busy = true; }
            string lockFile = null;
            try
            {
                string staged = Staged, inst = Installed;
                string sv = Version(staged), iv = Version(inst);
                if (sv == "") { code = 409; Log.W("addon: nothing staged at " + staged); return Say("No new add-on is ready - run tools\\addon-update.ps1"); }
                if (sv == iv) { code = 200; Log.W("addon: " + sv + " is already installed"); return Say("Add-on " + sv + " is already installed"); }
                Log.W("addon: installing " + sv + " over " + (iv == "" ? "nothing" : iv));

                // the watchdog restarts a missing Stream Deck after 10 s; its own lock file says "somebody is rebuilding it"
                try { lockFile = Path.Combine(LockDir ?? AppDomain.CurrentDomain.BaseDirectory, "deck-build.lock"); File.WriteAllText(lockFile, "addon " + sv); }
                catch (Exception ex) { Log.W("addon: no lock file: " + ex.Message); lockFile = null; }

                Stop();
                Log.W("addon: Stream Deck stopped");

                string nw = inst + ".new", old = inst + ".old"; string err = null; bool asideDone = false;
                try
                {
                    Directory.CreateDirectory(Plugins);
                    // a crash last time can leave pieces: put the installed one back before anything else
                    if (Directory.Exists(old)) { if (Directory.Exists(inst)) Directory.Delete(old, true); else Directory.Move(old, inst); }
                    if (Directory.Exists(nw)) Directory.Delete(nw, true);
                    CopyDir(staged, nw);
                    if (Directory.Exists(inst)) { Directory.Move(inst, old); asideDone = true; }
                    if (AfterOldAside != null) AfterOldAside();
                    Directory.Move(nw, inst);
                    asideDone = false;
                }
                catch (Exception ex)
                {
                    err = ex.Message;
                    try { if (Directory.Exists(nw)) Directory.Delete(nw, true); } catch { }
                    try { if (asideDone && Directory.Exists(old)) { if (Directory.Exists(inst)) Directory.Delete(inst, true); Directory.Move(old, inst); } } catch (Exception ex2) { Log.W("addon: could not put the old one back: " + ex2.Message); }
                }
                if (err != null)
                {
                    Log.W("addon: copy failed, the old add-on is back: " + err);
                    try { Start(); } catch (Exception ex) { Log.W("addon: Stream Deck start failed: " + ex.Message); }
                    code = 409; return Say("Add-on " + sv + " was not installed (" + err + "); the old one is back");
                }
                try { if (Directory.Exists(old)) Directory.Delete(old, true); } catch (Exception ex) { Log.W("addon: could not delete the old copy: " + ex.Message); }
                Log.W("addon: files in place");

                DateTime t0 = DateTime.Now;
                Start();
                bool back = Wait(WaitSeconds);
                string secs = (DateTime.Now - t0).TotalSeconds.ToString("0", CultureInfo.InvariantCulture);
                if (back) { Log.W("addon: Stream Deck back, add-on connected after " + secs + " s"); code = 200; return Say("Add-on " + sv + " installed and running"); }
                Log.W("addon: Stream Deck started but the add-on has not connected after " + secs + " s");
                code = 409; return Say("Add-on " + sv + " copied, but it has not connected yet - look at the deck");
            }
            catch (Exception ex)
            {
                Log.W("addon: install failed: " + ex.Message);
                try { Start(); } catch { }
                code = 409; return Say("Add-on not installed (" + ex.Message + ")");
            }
            finally
            {
                try { if (lockFile != null && File.Exists(lockFile)) File.Delete(lockFile); } catch { }
                lock (gate) busy = false;
            }
        }

        static void CopyDir(string from, string to)
        {
            Directory.CreateDirectory(to);
            foreach (string f in Directory.GetFiles(from)) File.Copy(f, Path.Combine(to, Path.GetFileName(f)), true);
            foreach (string d in Directory.GetDirectories(from)) CopyDir(d, Path.Combine(to, Path.GetFileName(d)));
        }

        // ---- the real steps (the same ones the watchdog uses: kill, wait, MAIN, start --runinbk) ----
        static void RealStop()
        {
            foreach (Process p in Process.GetProcessesByName("StreamDeck")) { try { p.Kill(); } catch { } }
            for (int i = 0; i < 30 && Process.GetProcessesByName("StreamDeck").Length > 0; i++) Thread.Sleep(100);
        }
        static void RealStart()
        {
            try { string r = IRDeck.DeckProfile.SetCurrentToMain(IRDeck.DeckProfile.ProfileDir()); if (r != "already") Log.W("addon: deck page before the start: " + r); }
            catch (Exception ex) { Log.W("addon: deck page: " + ex.Message); }
            Thread.Sleep(800);
            if (!File.Exists(StreamDeckExe)) throw new Exception("Stream Deck is not installed");
            Process.Start(new ProcessStartInfo(StreamDeckExe, "--runinbk") { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(StreamDeckExe) });
        }
        // the add-on asks irdash every 2 s: a poll newer than the start of this wait proves the NEW add-on page is running
        static bool RealWait(int seconds)
        {
            DateTime t0 = DateTime.Now;
            while ((DateTime.Now - t0).TotalSeconds < seconds)
            {
                Thread.Sleep(500);
                double age = Showcase.DeckPollAge;
                if (age < 4 && age < (DateTime.Now - t0).TotalSeconds - 0.5) return true;
            }
            return false;
        }
    }
}
