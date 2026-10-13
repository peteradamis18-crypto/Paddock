// Rig Doctor (WS6) and the timing log (S1).
// Rig Doctor checks the whole rig in about 5 seconds, and FIXES what it safely can by itself (see Fixes below): an app that
// is not running is started, CrewChief's name is put back, OneDrive is told to keep iRacing's files on this PC. It does that
// only when no sim session is running, tries each fix a few times at most, and logs every one ("Rig Doctor fixed: ...").
// What only you can do (a cable, an add-on update) stays in the list when you open it (RIG DOCTOR key, deck OVERLAYS screen,
// or irdeck doctor) and does not nag on the idle screen, which says "All good" unless something truly needs you.
// Timings records how long START, loading and getting in the car take.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class Doctor
    {
        // Ask: the one short line the idle screen may show for this item (empty = it does not need you)
        sealed class Item { public string Id, Name, State, Detail, Fix, Ask = "", Done = ""; }

        static readonly object gate = new object();
        static List<Item> items = new List<Item>();
        static DateTime ranAt = DateTime.MinValue, showUntil = DateTime.MinValue;
        static bool running, autoShow, auto1, auto2;
        static int showSeq;
        static string root, dash;
        static string lastFix = ""; static DateTime lastFixAt = DateTime.MinValue;

        public static void Init(string rootDir, string dashDir) { root = rootDir; dash = dashDir; TunerBox.OwnerFile = Path.Combine(dashDir, "tuner-owner.txt"); }

        // show = also put the list on the top screen for a minute (never while you are driving)
        public static void Run(bool show)
        {
            lock (gate)
            {
                if (show && !Program.IsDriving) { showUntil = DateTime.Now.AddSeconds(60); showSeq++; }
                if (running) return;
                running = true;
            }
            Thread t = new Thread(delegate ()
            {
                List<Item> list = new List<Item>();
                try { ClearStrayDialogs(); } catch (Exception ex) { Log.W("doctor: stray dialogs: " + ex.Message); }
                try { TunerBox.HideNow(); } catch (Exception ex) { Log.W("doctor: tuner box: " + ex.Message); }
                try { list = RunChecks(); list = ApplyFixes(list); }
                catch (Exception ex) { Log.W("doctor: " + ex.Message); }
                int bad = 0, warn = 0;
                foreach (Item i in list) { if (i.State == "bad") bad++; else if (i.State == "warn") warn++; }
                lock (gate)
                {
                    items = list; ranAt = DateTime.Now; running = false;
                    // a problem found a few minutes after the rig started is put in front of you once
                    if (autoShow) { autoShow = false; if ((bad > 0 || warn > 0) && Showcase.UptimeSec < 1800 && !Program.IsDriving) { showUntil = DateTime.Now.AddSeconds(45); showSeq++; } }
                }
                Log.W("doctor: " + (list.Count - bad - warn) + " fine, " + warn + " to look at, " + bad + " to fix");
                foreach (Item i in list) if (i.State != "ok") Log.W("doctor: " + i.Name + ": " + i.Detail + " - " + i.Fix);
            });
            t.IsBackground = true; t.Start();
        }

        // first check 100 s after irdash starts (the rig is still starting apps), again at 5 minutes, then every 30 minutes out of the car.
        // Between those, every 20 s a cheap look at the programs the doctor can start: one that has been missing for 45 s
        // (not just restarting) brings the full check - and its fixes - forward.
        static DateTime lastQuick = DateTime.MinValue, lastStray = DateTime.MinValue;
        public static void Tick()
        {
            if (root == null) return;
            // The error box sits behind the sim for the whole session. WM_CLOSE does not move the focus, so this
            // one look is safe while you drive. Everything else the doctor does still waits until you are out.
            if ((DateTime.Now - lastStray).TotalSeconds >= 20)
            {
                lastStray = DateTime.Now;
                try { ClearStrayDialogs(); } catch (Exception ex) { Log.W("doctor: stray dialogs: " + ex.Message); }
                // The Simucube Tuner's blank grey box: hidden (never closed). ShowWindowAsync is posted, so this is safe while you drive too.
                try { TunerBox.HideNow(); } catch (Exception ex) { Log.W("doctor: tuner box: " + ex.Message); }
            }
            if (Program.IsDriving) return;      // never while you drive
            double age = (DateTime.Now - Program.StartedAt).TotalSeconds;
            if (!auto1 && age >= 100) { auto1 = true; Run(false); }
            else if (!auto2 && age >= 300) { auto2 = true; lock (gate) autoShow = true; Run(false); }
            else if (auto2 && !Program.IsDriving && (DateTime.Now - ranAt).TotalMinutes > 30) Run(false);
            else if (auto2 && (DateTime.Now - lastQuick).TotalSeconds >= 20)
            {
                lastQuick = DateTime.Now;
                if (CanFix() && QuickMissing()) Run(false);
            }
        }

        static Item Mk(string id, string name, string state, string detail, string fix)
        { Item i = new Item(); i.Id = id; i.Name = name; i.State = state; i.Detail = detail; i.Fix = state == "ok" ? "" : fix; return i; }

        sealed class Check { public string Id, Name; public Func<Item> Run; }
        static readonly List<Check> checks = new List<Check>();
        static void Reg(string id, string name, Func<Item> run) { Check c = new Check(); c.Id = id; c.Name = name; c.Run = run; checks.Add(c); }

        static Item RunOne(Check c)
        {
            try { return c.Run(); }
            catch (Exception ex) { return Mk(c.Id, c.Name, "warn", "Check failed (" + ex.Message + ")", "Ask Claude"); }
        }

        static List<Item> RunChecks()
        {
            lock (checks)
                if (checks.Count == 0)
                {
                    Reg("overlays_visible", "Overlays app visible", CheckOverlaysVisible);
                    Reg("overlays_running", "Overlays running", CheckOverlaysRunning);
                    Reg("crewchief", "Spotter (CrewChief)", CheckCrewChief);
                    Reg("streamdeck", "Stream Deck", CheckStreamDeck);
                    Reg("irdash", "Paddock program", CheckIrdash);
                    Reg("screens", "Race screens", CheckScreens);
                    Reg("graphics", "iRacing graphics", CheckGraphics);
                    Reg("disk", "Disk space", CheckDisk);
                    Reg("telemetry", "Telemetry saving", CheckTelemetry);
                    Reg("sim_priority", "Sim priority", CheckSimPriority);
                    Reg("onedrive", "iRacing files on this PC", CheckOneDrive);
                    Reg("timings", "Start and load times", delegate { return Mk("timings", "Start and load times", "ok", Timings.Summary(), ""); });
                    Reg("performance", "Frame rate", CheckPerf);
                }
            List<Item> l = new List<Item>();
            foreach (Check c in checks) l.Add(RunOne(c));
            return l;
        }

        // ---- the fixes ----
        // Only safe ones, only with no sim session running, each tried at most 3 times (then it asks for help, once the
        // tries are used up it waits two hours before trying again). Everything is started by irdash, which runs outside
        // the Claude app, so what it starts is visible to the Stream Deck, Explorer and the other programs.
        sealed class Fix { public string Id, Giveup; public Func<string> Do; }
        sealed class Tries { public int N; public DateTime Last = DateTime.MinValue, Missing = DateTime.MinValue; }
        static readonly Dictionary<string, Fix> fixes = new Dictionary<string, Fix>();
        static readonly Dictionary<string, Tries> tries = new Dictionary<string, Tries>();

        static Tries TriesFor(string id) { Tries t; lock (tries) { if (!tries.TryGetValue(id, out t)) { t = new Tries(); tries[id] = t; } } return t; }

        static void RegFixes()
        {
            if (fixes.Count > 0) return;
            fixes["overlays_running"] = new Fix { Id = "overlays_running", Do = FixOverlays, Giveup = "Overlays would not start: ask Claude" };
            fixes["crewchief"] = new Fix { Id = "crewchief", Do = FixCrewChief, Giveup = "Spotter would not start: ask Claude" };
            fixes["streamdeck"] = new Fix { Id = "streamdeck", Do = FixStreamDeck, Giveup = "Stream Deck would not start: ask Claude" };
            fixes["onedrive"] = new Fix { Id = "onedrive", Do = FixOneDrive, Giveup = "" };
        }

        // no sim session and not driving (the sim program itself may be sitting idle: the iRacing UI keeps it warm)
        static bool CanFix() { return root != null && !Program.IsDriving && !Sdk.Latest.Connected && Showcase.UptimeSec > 150; }

        // the programs the doctor can start, as cheap process checks (no files read): true when one has been gone for 45 s
        static bool QuickMissing()
        {
            RegFixes(); bool go = false; DateTime now = DateTime.Now;
            Func<string, bool, bool> gone = delegate (string id, bool missing)
            {
                Tries t = TriesFor(id);
                if (!missing) { t.Missing = DateTime.MinValue; return false; }
                if (t.Missing == DateTime.MinValue) t.Missing = now;
                return (now - t.Missing).TotalSeconds >= 45 && !(t.N >= 3 && (now - t.Last).TotalMinutes < 120) && (t.N == 0 || (now - t.Last).TotalSeconds >= 60);
            };
            string irdRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "irdashies");
            if (gone("overlays_running", Directory.Exists(irdRoot) && !Running("irdashies") && !Overlays.Busy)) go = true;
            if (gone("crewchief", File.Exists(CrewChiefExe) && !Running("CrewChiefV4"))) go = true;
            if (gone("streamdeck", File.Exists(StreamDeckExe) && !Running("StreamDeck"))) go = true;
            return go;
        }

        static List<Item> ApplyFixes(List<Item> list)
        {
            RegFixes();
            bool can = CanFix();
            for (int k = 0; k < list.Count; k++)
            {
                Item it = list[k]; Fix fx; Tries t = TriesFor(it.Id);
                if (it.State == "ok") { t.N = 0; t.Missing = DateTime.MinValue; continue; }
                if (!fixes.TryGetValue(it.Id, out fx)) continue;
                bool spent = t.N >= 3 && (DateTime.Now - t.Last).TotalMinutes < 120;
                if (!can || spent || (t.N > 0 && (DateTime.Now - t.Last).TotalSeconds < 60))
                { if (spent && fx.Giveup.Length > 0) it.Ask = fx.Giveup; continue; }
                // Starting irdashies while Squirrel is replacing it (or the exe is locked) is what leaves the
                // Explorer error box. Skip without using up a try, and look again on the next check.
                if (it.Id == "overlays_running" && Overlays.StartWouldFail())
                { Log.W("doctor: overlays app is updating or its program file is in use - not starting it yet"); continue; }
                t.N++; t.Last = DateTime.Now;
                string did = null;
                try { did = fx.Do(); } catch (Exception ex) { Log.W("Rig Doctor: fixing " + it.Name + ": " + ex.Message); }
                Check c = null; foreach (Check x in checks) if (x.Id == it.Id) c = x;
                Item again = c != null ? RunOne(c) : it;
                if (again.State == "ok")
                {
                    again.Done = did ?? "fixed";
                    Log.W("Rig Doctor fixed: " + it.Name + " - " + again.Done + " (it was: " + it.Detail + ")");
                    lock (gate) { lastFix = again.Done; lastFixAt = DateTime.Now; }
                    t.N = 0; t.Missing = DateTime.MinValue;
                }
                else
                {
                    Log.W("Rig Doctor tried to fix " + it.Name + (did != null ? " (" + did + ")" : "") + " but it still shows: " + again.Detail + " (try " + t.N + " of 3)");
                    if (t.N >= 3 && fx.Giveup.Length > 0) again.Ask = fx.Giveup;
                }
                list[k] = again;
            }
            return list;
        }

        const string CrewChiefExe = @"C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4\CrewChiefV4.exe";
        const string StreamDeckExe = @"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe";

        static bool WaitRunning(string name, int seconds) { for (int i = 0; i < seconds * 4 && !Running(name); i++) Thread.Sleep(250); return Running(name); }

        static void StartProgram(string exe, string args)
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe, args ?? ""); psi.UseShellExecute = true; psi.WorkingDirectory = Path.GetDirectoryName(exe);
            Process.Start(psi);
        }

        static string FixStreamDeck()
        {
            if (Running("StreamDeck") || !File.Exists(StreamDeckExe)) return null;
            StartProgram(StreamDeckExe, "--runinbk");
            return WaitRunning("StreamDeck", 20) ? "started the Stream Deck app" : null;
        }

        // the same restart the OVERLAYS screen uses (irdeck ovl apply, one irdeck command at a time through irdash)
        static string FixOverlays()
        {
            string irdRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "irdashies");
            if (!Directory.Exists(irdRoot) || Running("irdashies") || Overlays.Busy) return null;
            Overlays.Do("ovapply", null);
            for (int i = 0; i < 200 && (Overlays.Busy || i < 4); i++) Thread.Sleep(250);
            return WaitRunning("irdashies", 15) ? "started the overlays app" : null;
        }

        // not running: start it. Running with the wrong name while friends mode is off: put your own name back (the irdeck
        // guest commands that EXIT and the "waiting for the car to stop" retry use).
        static string FixCrewChief()
        {
            if (!Running("CrewChiefV4"))
            {
                if (!File.Exists(CrewChiefExe)) return null;
                StartProgram(CrewChiefExe, null);
                return WaitRunning("CrewChiefV4", 25) ? "started CrewChief" : null;
            }
            string how = CrewChiefNameFix();
            if (how == null || Watch.IrdeckPath == null || !File.Exists(Watch.IrdeckPath)) return null;
            ProcessStartInfo psi = new ProcessStartInfo(Watch.IrdeckPath, "guest " + how);
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(Watch.IrdeckPath);
            using (Process p = Process.Start(psi)) { if (!p.WaitForExit(45000)) { try { p.Kill(); } catch { } return null; } }
            Thread.Sleep(7000);      // CrewChief restarts to take the name (about 5 s)
            return "reset the CrewChief driver name";
        }

        // Documents\iRacing in OneDrive: pin it (tools\keep-iracing-local.cmd). Started by irdash with no window; irdash runs
        // outside the Claude app, so it is the same as double-clicking it. The tool writes "pinned: N of M" to its log when done.
        static string FixOneDrive()
        {
            string cmd = Path.Combine(root, @"tools\keep-iracing-local.cmd"), log = Path.Combine(root, @"tools\keep-iracing-local.log");
            if (!File.Exists(cmd) || Process.GetProcessesByName("iRacingSim64DX11").Length > 0) return null;
            DateTime t0 = DateTime.Now;
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/c \"\"" + cmd + "\"\"");
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(cmd);
            using (Process p = Process.Start(psi))
            {
                for (int i = 0; i < 240; i++)
                {
                    Thread.Sleep(250);
                    try { if (File.Exists(log) && File.GetLastWriteTime(log) >= t0 && File.ReadAllText(log).Contains("pinned:")) break; } catch { }
                    if (p.HasExited) break;
                }
            }
            return "set Documents\\iRacing to always stay on this PC (OneDrive)";
        }
        // ---- the checks ----
        static bool Running(string name) { return Process.GetProcessesByName(name).Length > 0; }

        // A helper started through Explorer runs outside any app sandbox, so it sees what normal programs see:
        // programs started from the Claude app get private AppData copies (2026-10-09, see tools\fix-overlay-install.cmd).
        static Item CheckOverlaysVisible()
        {
            string probe = Path.Combine(dash, "probe.exe"), res = Path.Combine(dash, "probe.txt");
            if (!File.Exists(probe)) return Mk("overlays_visible", "Overlays app visible", "warn", "Check helper dash\\probe.exe missing", "Run dash\\build.ps1");
            DateTime t0 = DateTime.Now;
            try { if (File.Exists(res)) File.Delete(res); } catch { }
            // explorer.exe shows a #32770 titled with the path when the file it was told to open is locked or half-written
            // (a deploy replacing probe.exe). Do not hand it a file we cannot read.
            try { using (FileStream fs = new FileStream(probe, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) { } }
            catch { return Mk("overlays_visible", "Overlays app visible", "warn", "Check helper in use", "Run the check again in a minute"); }
            Process.Start("explorer.exe", "\"" + probe + "\"");
            for (int i = 0; i < 100 && !(File.Exists(res) && File.GetLastWriteTime(res) >= t0.AddSeconds(-1)); i++) Thread.Sleep(100);
            if (!File.Exists(res)) return Mk("overlays_visible", "Overlays app visible", "warn", "Check helper did not answer", "Run the check again");
            Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            Thread.Sleep(100);
            foreach (string line in File.ReadAllLines(res)) { int e = line.IndexOf('='); if (e > 0) d[line.Substring(0, e)] = line.Substring(e + 1); }
            string exe = d.ContainsKey("overlays_exe") ? d["overlays_exe"] : "MISSING", cfg = d.ContainsKey("config") ? d["config"] : "MISSING";
            if (exe == "MISSING" || cfg == "MISSING")
                return Mk("overlays_visible", "Overlays app visible", "bad", (exe == "MISSING" ? "Overlays app" : "Overlays settings") + " not visible to normal programs (private copy)",
                    "Double-click tools\\fix-overlay-install.cmd, then press OVERLAYS and a preset");
            return Mk("overlays_visible", "Overlays app visible", "ok", "Overlays app and settings visible", "");
        }

        static Item CheckOverlaysRunning()
        {
            string irdRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "irdashies");
            if (!Directory.Exists(irdRoot)) return Mk("overlays_running", "Overlays running", "bad", "Overlays app (irdashies) not installed", "Run tools\\fix-overlay-install.cmd");
            if (!Running("irdashies")) return Mk("overlays_running", "Overlays running", "bad", "Overlays app not running: no overlays on the race screens", "Press OVERLAYS on the deck, then a preset such as RACE");
            string j = Overlays.Json();
            Match m = Regex.Match(j, "\"onCount\":(\\d+)");
            int n = m.Success ? int.Parse(m.Groups[1].Value) : 0;
            if (n == 0) return Mk("overlays_running", "Overlays running", "ok", "Running \u00B7 all overlays off", "");
            return Mk("overlays_running", "Overlays running", "ok", "Running \u00B7 " + n + " overlay" + (n == 1 ? "" : "s") + " on", "");
        }

        static string CrewChiefName()
        {
            string rootDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Britton_IT_Ltd");
            if (!Directory.Exists(rootDir)) return null;
            string best = null; DateTime bt = DateTime.MinValue;
            foreach (string f in Directory.GetFiles(rootDir, "user.config", SearchOption.AllDirectories))
                if (File.GetLastWriteTime(f) > bt) { bt = File.GetLastWriteTime(f); best = f; }
            if (best == null) return null;
            Match m = Regex.Match(File.ReadAllText(best), "name=\"PERSONALISATION_NAME\"[^>]*>\\s*<value>([^<]*)</value>");
            return m.Success ? m.Groups[1].Value : "";
        }

        // friends mode changes CrewChief's name on purpose; with it off, your own name must be back. Returns the irdeck guest
        // command that puts it right ("voice": a change that was waiting for the car to stop; "off": the remembered own name), or null.
        static string CrewChiefNameFix()
        {
            string dir = Guest.Dir; if (dir == null) return null;
            string f = Path.Combine(dir, "state.ini"); if (!File.Exists(f)) return null;
            Dictionary<string, string> st = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string l in File.ReadAllLines(f)) { int e = l.IndexOf('='); if (e > 0) st[l.Substring(0, e)] = l.Substring(e + 1); }
            Func<string, string> g = delegate (string k) { string v; return st.TryGetValue(k, out v) ? v.Trim() : ""; };
            if (g("active") == "1") return null;
            string cur = CrewChiefName(); if (cur == null) return null;
            if (g("cc_pending") != "") return "voice";
            string own = g("own_cc_name");
            if (own != "" && cur != (own == "-" ? "" : own)) return "off";
            return null;
        }

        static Item CheckCrewChief()
        {
            if (!Running("CrewChiefV4")) return Mk("crewchief", "Spotter (CrewChief)", "warn", "CrewChief not running: no spotter or engineer voice", "Press RIG ON");
            string n = CrewChiefName();
            if (CrewChiefNameFix() != null) return Mk("crewchief", "Spotter (CrewChief)", "warn", "Running \u00B7 driver name is " + (string.IsNullOrEmpty(n) ? "empty" : n) + " (friends mode leftover)", "Reset when no session is running");
            return Mk("crewchief", "Spotter (CrewChief)", "ok", "Running" + (n == null ? "" : n.Length > 0 ? " \u00B7 driver name " + n : " \u00B7 no driver name"), "");
        }
        static string FileText(string path) { using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) using (StreamReader r = new StreamReader(fs, Encoding.GetEncoding(28591))) return r.ReadToEnd(); }

        static Item CheckStreamDeck()
        {
            if (!Running("StreamDeck")) return Mk("streamdeck", "Stream Deck", "bad", "Stream Deck app not running: the keys do nothing", "Starts when no session is running");
            string installed = "", ready = "";
            string man = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Elgato\StreamDeck\Plugins\com.peter.rigintro.sdPlugin\manifest.json");
            if (File.Exists(man)) { Match m = Regex.Match(FileText(man), "\"Version\"\\s*:\\s*\"([\\d.]+)\""); if (m.Success) installed = m.Groups[1].Value; }
            string inst = Path.Combine(root, @"deck-intro\install.ps1");
            if (File.Exists(inst)) { Match m = Regex.Match(FileText(inst), "\\$ver\\s*=\\s*'([\\d.]+)'"); if (m.Success) ready = m.Groups[1].Value; }
            if (installed == "") return Mk("streamdeck", "Stream Deck", "warn", "Rig Intro add-on not installed (friends mode, overlays)", "Run deck-intro\\install.ps1, then click Install in Stream Deck");
            if (ready != "" && installed != ready) return Mk("streamdeck", "Stream Deck", "ok", "Running \u00B7 Rig Intro add-on " + installed + " (" + ready + " ready to install)", "");
            // the add-on asks every 2 s, but an older add-on page is slowed to about once a minute when hidden: only 2.5 minutes of silence counts
            if (Showcase.DeckPollAge > 150) return Mk("streamdeck", "Stream Deck", "warn", "Rig Intro add-on silent for over 2 min", "Close and open the Stream Deck app");
            return Mk("streamdeck", "Stream Deck", "ok", "Running \u00B7 Rig Intro add-on " + installed, "");
        }

        static string Duration(TimeSpan t) { return t.TotalHours >= 1 ? (int)t.TotalHours + " h " + t.Minutes + " min" : (int)t.TotalMinutes + " min"; }

        static Item CheckIrdash()
        {
            DateTime built = File.GetLastWriteTime(Assembly.GetExecutingAssembly().Location);
            return Mk("irdash", "Paddock program", "ok", "Built " + built.ToString("d MMM HH:mm", CultureInfo.InvariantCulture) + " \u00B7 running " + Duration(DateTime.Now - Program.StartedAt) + (Sdk.Latest.Connected ? " \u00B7 linked to iRacing" : " \u00B7 waiting for iRacing"), "");
        }

        static Item CheckScreens()
        {
            List<Systems.Disp> all = Systems.Displays(), race = new List<Systems.Disp>();
            foreach (Systems.Disp d in all) if (d.W == 2560 && d.H == 1440) race.Add(d);
            if (race.Count < 3) return Mk("screens", "Race screens", "bad", "Windows shows " + race.Count + " race screen" + (race.Count == 1 ? "" : "s") + " (2560\u00D71440), not 3", "Check display cables and screen power");
            int hz = int.MaxValue, notFlipped = 0; bool middleMain = false, layout = false; int left = 0, right = 0;
            foreach (Systems.Disp d in race)
            {
                hz = Math.Min(hz, d.Hz);
                if (d.Orient != 2) notFlipped++;
                if (d.Bounds.X == 0 && d.Bounds.Y == 0 && d.Primary) middleMain = true;
                if (d.Bounds.X == -2560 && d.Bounds.Y == 0) left++;
                if (d.Bounds.X == 2560 && d.Bounds.Y == 0) right++;
            }
            layout = left == 1 && right == 1 && middleMain;
            string detail = race.Count + " \u00D7 2560\u00D71440 at " + hz + " Hz, " + (notFlipped == 0 ? "rotated 180\u00B0" : notFlipped + " not rotated") + (layout ? " \u00B7 middle is main" : "");
            if (hz < 165) return Mk("screens", "Race screens", "warn", detail, "Set 165 Hz in Windows display settings (Advanced display)");
            if (notFlipped > 0) return Mk("screens", "Race screens", "warn", detail, "Double-click FLIP SIM SCREENS.cmd");
            if (!layout) return Mk("screens", "Race screens", "warn", detail + " \u00B7 wrong screen order", "Double-click MAKE MIDDLE SCREEN MAIN.cmd, or SWAP SCREENS 1 and 3.cmd");
            return Mk("screens", "Race screens", "ok", detail, "");
        }

        // iRacing's own graphics file, read-only (iRacing rewrites it when the sim closes)
        static Item CheckGraphics()
        {
            string ini = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), @"iRacing\rendererDX11Monitor.ini");
            if (!File.Exists(ini)) return Mk("graphics", "iRacing graphics", "warn", "Graphics file not found", "Start iRacing once");
            Dictionary<string, string> v = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            bool inSec = false;
            foreach (string raw in FileText(ini).Split('\n'))
            {
                string l = raw.Trim();
                if (l.StartsWith("[")) { inSec = l == "[Graphics Options]"; continue; }
                if (!inSec) continue;
                Match m = Regex.Match(l, @"^(\w+)=([^;\s]*)");
                if (m.Success) v[m.Groups[1].Value] = m.Groups[2].Value;
            }
            Func<string, string> g = delegate (string k) { string s; return v.TryGetValue(k, out s) ? s : "?"; };
            string cap = g("LimitFrameRate") == "0" ? "no frame limit" : "frame limit " + g("DesiredFPSLimit");
            string reflex = g("NvReflexMode") == "0" ? "Reflex off" : "Reflex on";
            string mirrors = g("MaxCockpitMirrors") + " mirrors, " + (g("MirrorDetail") == "1" ? "high" : "low") + " detail" + (g("VirtualMirrors") == "1" ? ", virtual mirror on" : "");
            string detail = cap + " · " + reflex + " · " + mirrors;
            // the settled setup of 2026-10-09 (about 104 fps in a 23-car race)
            bool settled = g("LimitFrameRate") == "1" && g("DesiredFPSLimit") == "160" && g("NvReflexMode") == "0" && g("MaxCockpitMirrors") == "4" && g("MirrorDetail") == "1";
            if (!settled) return Mk("graphics", "iRacing graphics", "warn", detail + " (expected: limit 160, Reflex off, 4 mirrors high)", "Ask Claude to check iRacing's graphics");
            return Mk("graphics", "iRacing graphics", "ok", detail, "");
        }

        static Item CheckDisk()
        {
            string[] paths = { @"C:\Program Files (x86)\iRacing", TrackMaps.TelemetryDir };
            double free = double.MaxValue; string where = "";
            foreach (string p in paths)
            {
                if (string.IsNullOrEmpty(p) || !Directory.Exists(p)) continue;
                DriveInfo di = new DriveInfo(Path.GetPathRoot(p));
                double gb = di.AvailableFreeSpace / 1073741824.0;
                if (gb < free) { free = gb; where = di.Name.TrimEnd('\\'); }
            }
            if (free == double.MaxValue) return Mk("disk", "Disk space", "warn", "iRacing drive not found", "Ask Claude");
            double tel = 0; int files = 0;
            try { foreach (string f in Directory.GetFiles(TrackMaps.TelemetryDir, "*.ibt")) { tel += new FileInfo(f).Length; files++; } } catch { }
            string detail = where + " has " + free.ToString("0") + " GB free" + (files > 0 ? "; telemetry files take " + (tel / 1073741824.0).ToString("0.0", CultureInfo.InvariantCulture) + " GB (" + files + " files)" : "");
            if (free < 15) { Item low = Mk("disk", "Disk space", "bad", detail, "Delete old .ibt files in Documents\\iRacing\\telemetry"); low.Ask = "Disk nearly full: " + free.ToString("0") + " GB left"; return low; }
            if (free < 40) return Mk("disk", "Disk space", "warn", detail, "Delete old .ibt files in Documents\\iRacing\\telemetry");
            return Mk("disk", "Disk space", "ok", detail, "");
        }

        static Item CheckTelemetry()
        {
            string ini = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), @"iRacing\app.ini");
            if (!File.Exists(ini)) return Mk("telemetry", "Telemetry saving", "warn", "app.ini not found", "Start iRacing once");
            string t = FileText(ini);
            bool disk = Regex.IsMatch(t, @"(?m)^irsdkEnableDisk=1"), auto = Regex.IsMatch(t, @"(?m)^irsdkAutoLogDisk=1");
            if (disk && auto) return Mk("telemetry", "Telemetry saving", "ok", "Saving a telemetry file every session", "");
            return Mk("telemetry", "Telemetry saving", "warn", "iRacing is not saving telemetry: no new track maps or lap analysis", "Ask Claude to switch it on (sim closed)");
        }

        // irdash.ini sim_priority: the sim is raised to High priority when a session starts (data.cs)
        // last session's frame rate in one sentence (perf.cs); amber only when the Performance page found something for Peter to look at
        static Item CheckPerf()
        {
            int look = PerfCheck.AttentionCount();
            return Mk("performance", "Frame rate", look > 0 ? "warn" : "ok", Perf.Summary(), look > 0 ? "Open the Performance page" : "");
        }

        static Item CheckSimPriority()
        {
            bool problem; string d = SimPriority.Describe(out problem);
            if (problem) return Mk("sim_priority", "Sim priority", "warn", d, "Ask Claude: priority not raised (the sim may run as administrator)");
            return Mk("sim_priority", "Sim priority", "ok", d, "");
        }

        // Documents\iRacing lives in OneDrive on this PC. "Always keep on this device" (the pinned attribute) stops OneDrive
        // from turning settings and telemetry into online-only files. Read-only: tools\keep-iracing-local.cmd sets it.
        static Item CheckOneDrive()
        {
            string docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), dir = Path.Combine(docs, "iRacing");
            if (!Directory.Exists(dir)) return Mk("onedrive", "iRacing files on this PC", "warn", "Documents\\iRacing folder not found", "Start iRacing once");
            string od = Environment.GetEnvironmentVariable("OneDrive");
            bool inOneDrive = docs.IndexOf("OneDrive", StringComparison.OrdinalIgnoreCase) >= 0 || (!string.IsNullOrEmpty(od) && dir.StartsWith(od, StringComparison.OrdinalIgnoreCase));
            if (!inOneDrive) return Mk("onedrive", "iRacing files on this PC", "ok", "Documents\\iRacing is not in OneDrive", "");
            int attr = (int)File.GetAttributes(dir);
            bool pinned = (attr & 0x80000) != 0, unpinned = (attr & 0x100000) != 0;
            int online = 0, total = 0;
            try { foreach (string f in Directory.GetFiles(TrackMaps.TelemetryDir, "*.ibt")) { total++; if (Career.OnlineOnly(new FileInfo(f))) online++; } } catch { }
            const string fix = "Double-click tools\\keep-iracing-local.cmd";
            if (online > 0) return Mk("onedrive", "iRacing files on this PC", "warn", online + " of " + total + " telemetry files are online-only in OneDrive: lap data and track maps skip them", fix);
            if (unpinned) return Mk("onedrive", "iRacing files on this PC", "warn", "Documents\\iRacing is set to \"free up space\" in OneDrive", fix);
            if (!pinned) return Mk("onedrive", "iRacing files on this PC", "warn", "Documents\\iRacing is not set to \"always keep on this device\" in OneDrive", fix);
            return Mk("onedrive", "iRacing files on this PC", "ok", "Documents\\iRacing is kept on this PC (OneDrive)", "");
        }

        // ---- stray launcher dialogs (WS6 follow-up, 2026-10-10) ----
        // Starting an app through explorer.exe leaves a standard dialog (class #32770, title = the exe path, one OK
        // button) when the launch fails — for example while Squirrel is replacing irdashies.exe. It has no owner on
        // screen, so it sat on the middle screen, behind the sim, for a whole session. WM_CLOSE does not activate it.
        // The owner is explorer.exe. tests\doctor-test.ps1 writes dash\stray-owner.txt with a stand-in process name
        // so the same check can close a fake dialog that explorer does not own.
        delegate bool StrayEnum(IntPtr h, IntPtr l);
        static readonly object strayGate = new object();
        [DllImport("user32.dll")] static extern bool EnumWindows(StrayEnum f, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, StrayEnum f, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

        static string ExtraOwner()
        {
            try
            {
                if (dash == null) return "";
                string f = Path.Combine(dash, "stray-owner.txt");
                if (!File.Exists(f)) return "";
                string s = File.ReadAllText(f);
                int n = s.IndexOfAny(new char[] { '\r', '\n' });
                if (n >= 0) s = s.Substring(0, n);
                s = s.Trim();
                if (s.Length == 0 || s.Length > 40) return "";
                if (s.IndexOf('\\') >= 0 || s.IndexOf('/') >= 0) return "";
                return s;
            }
            catch { return ""; }
        }

        static bool StrayTitle(string title)
        {
            if (string.IsNullOrEmpty(title) || title.IndexOf('\\') < 0) return false;
            string t = title.ToLowerInvariant();
            if (t.IndexOf("irdashies") >= 0) return true;
            if (t.IndexOf("irdash.exe") >= 0) return true;
            if (t.IndexOf("crewchief") >= 0) return true;
            if (t.IndexOf("streamdeck") >= 0) return true;
            return false;
        }

        static bool LauncherOwns(IntPtr h, string extra)
        {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == 0) return false;
            string name;
            try { name = Process.GetProcessById((int)pid).ProcessName; }
            catch { return false; }
            if (name.Equals("explorer", StringComparison.OrdinalIgnoreCase)) return true;
            return extra.Length > 0 && name.Equals(extra, StringComparison.OrdinalIgnoreCase);
        }

        static string DialogText(IntPtr h)
        {
            StringBuilder acc = new StringBuilder();
            StrayEnum cb = delegate (IntPtr c, IntPtr l)
            {
                StringBuilder cls = new StringBuilder(64);
                GetClassName(c, cls, 64);
                if (cls.ToString() != "Static") return true;
                StringBuilder t = new StringBuilder(1024);
                GetWindowText(c, t, 1024);
                string s = t.ToString().Trim();
                if (s.Length == 0) return true;
                if (acc.Length > 0) acc.Append(' ');
                if (acc.Length < 500) acc.Append(s);
                return true;
            };
            EnumChildWindows(h, cb, IntPtr.Zero);
            return acc.ToString().Trim();
        }

        static int ClearStrayDialogs()
        {
            if (!Monitor.TryEnter(strayGate)) return 0;
            try
            {
                string extra = ExtraOwner();
                List<IntPtr> hit = new List<IntPtr>();
                StrayEnum cb = delegate (IntPtr h, IntPtr l)
                {
                    if (!IsWindowVisible(h)) return true;
                    StringBuilder cls = new StringBuilder(32);
                    GetClassName(h, cls, 32);
                    if (cls.ToString() != "#32770") return true;
                    StringBuilder tb = new StringBuilder(512);
                    GetWindowText(h, tb, 512);
                    if (!StrayTitle(tb.ToString())) return true;
                    if (!LauncherOwns(h, extra)) return true;
                    hit.Add(h);
                    return true;
                };
                EnumWindows(cb, IntPtr.Zero);
                int closed = 0;
                foreach (IntPtr h in hit)
                {
                    if (!IsWindowVisible(h)) continue;
                    StringBuilder tb = new StringBuilder(512);
                    GetWindowText(h, tb, 512);
                    string title = tb.ToString();
                    string text = DialogText(h);
                    if (text.Length > 400) text = text.Substring(0, 400);
                    PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero);   // WM_CLOSE. Posted, so it cannot steal focus.
                    string show = title.Length > 300 ? title.Substring(0, 300) : title;
                    Log.W("Rig Doctor: closed a launcher error (" + show + ")" + (text.Length > 0 ? " - " + text : ""));
                    closed++;
                }
                return closed;
            }
            finally { Monitor.Exit(strayGate); }
        }

        // ---- JSON for the top screen ----
        public static string Json()
        {
            lock (gate)
            {
                CultureInfo inv = CultureInfo.InvariantCulture;
                int ok = 0, warn = 0, bad = 0;
                List<string> js = new List<string>(); string ask = "";
                foreach (Item i in items)
                {
                    if (i.State == "ok") ok++; else if (i.State == "warn") warn++; else bad++;
                    js.Add("{\"id\":" + Json_.S(i.Id) + ",\"name\":" + Json_.S(i.Name) + ",\"state\":" + Json_.S(i.State) + ",\"detail\":" + Json_.S(i.Detail) + ",\"fix\":" + Json_.S(i.Fix) + ",\"done\":" + Json_.S(i.Done) + ",\"ask\":" + Json_.S(i.Ask) + "}");
                    if (i.Ask.Length > 0 && ask.Length == 0) ask = i.Ask;
                }
                string head = ranAt == DateTime.MinValue ? (running ? "Checking the rig" : "Not checked yet")
                            : bad > 0 ? bad + (bad == 1 ? " thing needs fixing" : " things need fixing")
                            : warn > 0 ? warn + (warn == 1 ? " thing to look at" : " things to look at") : "All " + ok + " checks pass";
                bool show = DateTime.Now < showUntil && !Program.IsDriving;
                return "{\"ranAt\":" + (ranAt == DateTime.MinValue ? "null" : Json_.S(ranAt.ToString("s"))) + ",\"age\":" + (ranAt == DateTime.MinValue ? "null" : (DateTime.Now - ranAt).TotalSeconds.ToString("0", inv)) +
                       ",\"ask\":" + Json_.S(ask) + ",\"fixed\":" + Json_.S(lastFixAt != DateTime.MinValue && (DateTime.Now - lastFixAt).TotalMinutes < 120 ? lastFix : "") + ",\"running\":" + (running ? "true" : "false") + ",\"show\":" + (show ? "true" : "false") + ",\"showSeq\":" + showSeq +
                       ",\"ok\":" + ok + ",\"warn\":" + warn + ",\"bad\":" + bad + ",\"headline\":" + Json_.S(head) +
                       ",\"deckAge\":" + (Showcase.DeckPollAge > 86400 ? "null" : Showcase.DeckPollAge.ToString("0", inv)) + ",\"timings\":" + Json_.S(Timings.Summary()) + ",\"items\":[" + string.Join(",", js.ToArray()) + "]}";
            }
        }
    }

    // ---------------- Timing log (S1) ----------------
    // dash\timings.tsv: when, event, seconds, note. Events:
    //   boot_irdash      Windows start -> this program running
    //   boot_ui          Windows start -> the iRacing UI window is up
    //   start_to_sim     START pressed -> the sim program started (only when START had to start it)
    //   sim_to_session   sim started -> session loaded (telemetry flowing)
    //   start_to_session START pressed -> session loaded
    //   start_to_car     START pressed -> in the car on track
    //   session_to_car   session loaded -> in the car on track
    //   sim_exit         session ended -> sim program gone
    // irdeck writes dash\start-mark.txt when a START key runs; the rest irdash sees for itself.
    static class Timings
    {
        static string file, markFile;
        static readonly object gate = new object();
        static DateTime connectedAt = DateTime.MinValue, disconnectedAt = DateTime.MinValue;
        static bool carLogged = true, exitPending;
        static Process exiting;
        static bool bootUiDone;
        static DateTime bootAt;

        public static void Init(string tsv, string mark)
        {
            file = tsv; markFile = mark;
            try { if (!string.IsNullOrEmpty(mark)) TestRuns.FilePath = Path.Combine(Path.GetDirectoryName(mark), "test-sessions.txt"); } catch { }   // PL-1: sessions a test started (home.cs)
            bootAt = DateTime.Now.AddSeconds(-Showcase.UptimeSec);
            try
            {
                // keep the log short
                if (File.Exists(file)) { string[] l = File.ReadAllLines(file); if (l.Length > 2000) File.WriteAllLines(file, new List<string>(l).GetRange(l.Length - 1500, 1500).ToArray()); }
            }
            catch { }
            if (Showcase.UptimeSec < 900 && !LoggedSinceBoot("boot_irdash")) Add("boot_irdash", Showcase.UptimeSec, "");
            bootUiDone = Showcase.UptimeSec > 1200 || LoggedSinceBoot("boot_ui");
        }

        public static void Add(string ev, double secs, string note)
        {
            if (file == null) return;
            try
            {
                lock (gate)
                    File.AppendAllText(file, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\t" + ev + "\t" + secs.ToString("0.0", CultureInfo.InvariantCulture) + "\t" + (note ?? "") + "\r\n");
                Log.W("timing: " + ev + " " + secs.ToString("0.0", CultureInfo.InvariantCulture) + " s");
            }
            catch (Exception ex) { Log.W("timings: " + ex.Message); }
        }

        static bool LoggedSinceBoot(string ev)
        {
            try
            {
                if (!File.Exists(file)) return false;
                foreach (string l in File.ReadAllLines(file))
                {
                    string[] f = l.Split('\t'); DateTime when;
                    if (f.Length >= 3 && f[1] == ev && DateTime.TryParseExact(f[0], "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out when) && when >= bootAt.AddSeconds(-10)) return true;
                }
            }
            catch { }
            return false;
        }

        // the START key's moment (UTC ticks, then a tab and what pressed it); only trusted for 20 minutes
        static bool Mark(out DateTime when)
        {
            when = DateTime.MinValue;
            try
            {
                if (markFile == null || !File.Exists(markFile)) return false;
                long t; string[] p = File.ReadAllText(markFile).Split('\t');
                if (!long.TryParse(p[0].Trim(), out t)) return false;
                when = new DateTime(t, DateTimeKind.Utc).ToLocalTime();
                return (DateTime.Now - when).TotalMinutes < 20 && when < DateTime.Now;
            }
            catch { return false; }
        }

        // the label after the START key's moment: "TEST" when a test that owns the sim pressed it (irdeck: MarkLabel)
        static bool MarkIsTest()
        {
            try { string[] p = File.ReadAllText(markFile).Split('\t'); return p.Length > 1 && p[1].Trim() == "TEST"; }
            catch { return false; }
        }

        // ---- called by the SDK reader thread ----
        public static void OnConnected()
        {
            connectedAt = DateTime.Now; carLogged = false; exitPending = false;
            try
            {
                DateTime mark; bool hasMark = Mark(out mark);
                if (hasMark && MarkIsTest()) TestRuns.Begin();      // PL-1: this session is a test's, not Peter's (it does not count as an outing)
                DateTime simStart = DateTime.MinValue;
                Process[] sims = Process.GetProcessesByName("iRacingSim64DX11");
                if (sims.Length > 0) { try { simStart = sims[0].StartTime; } catch { } }
                // the sim program is often already warm (the UI preloads it), so these only count when it started after START
                bool fresh = simStart != DateTime.MinValue && (hasMark ? simStart > mark : (DateTime.Now - simStart).TotalMinutes < 10);
                if (fresh && hasMark) Add("start_to_sim", (simStart - mark).TotalSeconds, "");
                if (fresh) Add("sim_to_session", (connectedAt - simStart).TotalSeconds, "");
                if (hasMark) Add("start_to_session", (connectedAt - mark).TotalSeconds, "");
            }
            catch (Exception ex) { Log.W("timings: " + ex.Message); }
        }

        public static void OnFrame(Frame f)
        {
            if (carLogged || f.Num("IsOnTrack") == 0) return;
            carLogged = true;
            if (connectedAt != DateTime.MinValue) Add("session_to_car", (DateTime.Now - connectedAt).TotalSeconds, "");
            DateTime mark;
            if (Mark(out mark)) { Add("start_to_car", (DateTime.Now - mark).TotalSeconds, ""); try { File.Delete(markFile); } catch { } }
        }

        public static void OnDisconnected()
        {
            disconnectedAt = DateTime.Now; carLogged = true; exitPending = true;
            TestRuns.End();
            try { Process[] s = Process.GetProcessesByName("iRacingSim64DX11"); exiting = s.Length > 0 ? s[0] : null; } catch { exiting = null; }
            try { if (markFile != null && File.Exists(markFile)) File.Delete(markFile); } catch { }   // a START that never got into the car
        }

        // guard tick: boot events and the sim's exit time
        public static void Tick()
        {
            if (file == null) return;
            if (!bootUiDone)
            {
                // the window titled "iRacing", not the process's own "main window" guess (a tiny untitled strip can take that over: rigwin.cs)
                try { if (RigWin.IracingUiReady()) { bootUiDone = true; Add("boot_ui", Showcase.UptimeSec, ""); } } catch { }
                if (Showcase.UptimeSec > 1200) bootUiDone = true;
            }
            if (exitPending)
            {
                try
                {
                    if (exiting == null || exiting.HasExited)
                    {
                        exitPending = false;
                        if (exiting != null) { double s = (exiting.ExitTime - disconnectedAt).TotalSeconds; if (s >= 0 && s < 120) Add("sim_exit", s, ""); }
                    }
                    else if ((DateTime.Now - disconnectedAt).TotalSeconds > 120) exitPending = false;   // the sim stays loaded between sessions
                }
                catch { exitPending = false; }
            }
        }

        static string Fmt(double s) { return s < 60 ? Math.Round(s).ToString("0") + " s" : (int)(s / 60) + " min " + Math.Round(s % 60).ToString("0") + " s"; }

        // newest value of each event (read again only when the file changes: the screens ask every 1.5 s)
        static string latestKey; static Dictionary<string, KeyValuePair<string, double>> latestCache = new Dictionary<string, KeyValuePair<string, double>>();
        static Dictionary<string, KeyValuePair<string, double>> Latest()
        {
            lock (gate)
            {
                try
                {
                    if (file == null || !File.Exists(file)) { latestKey = null; return new Dictionary<string, KeyValuePair<string, double>>(); }
                    FileInfo fi = new FileInfo(file);
                    string key = fi.LastWriteTimeUtc.Ticks + ":" + fi.Length;
                    if (key == latestKey) return latestCache;
                    Dictionary<string, KeyValuePair<string, double>> d = new Dictionary<string, KeyValuePair<string, double>>();
                    foreach (string l in File.ReadAllLines(file))
                    {
                        string[] f = l.Split('\t'); double s;
                        if (f.Length >= 3 && f[1] != "test" && double.TryParse(f[2], NumberStyles.Float, CultureInfo.InvariantCulture, out s)) d[f[1]] = new KeyValuePair<string, double>(f[0], s);
                    }
                    latestKey = key; latestCache = d;
                    return d;
                }
                catch { return new Dictionary<string, KeyValuePair<string, double>>(); }
            }
        }

        // one plain-English line for the idle screen and Rig Doctor
        public static string Summary()
        {
            Dictionary<string, KeyValuePair<string, double>> d = Latest();
            KeyValuePair<string, double> v;
            List<string> start = new List<string>();
            if (d.TryGetValue("start_to_session", out v)) start.Add("session loaded in " + Fmt(v.Value));
            if (d.TryGetValue("start_to_car", out v)) start.Add("in the car in " + Fmt(v.Value));
            else if (d.TryGetValue("session_to_car", out v)) start.Add("in the car " + Fmt(v.Value) + " after loading");
            List<string> parts = new List<string>();
            if (start.Count > 0) parts.Add("Last start: " + string.Join(", ", start.ToArray()));
            if (d.TryGetValue("sim_exit", out v)) parts.Add("sim closes in " + Fmt(v.Value));
            if (d.TryGetValue("boot_ui", out v)) parts.Add("iRacing ready " + Fmt(v.Value) + " after Windows starts");
            return parts.Count > 0 ? string.Join(" \u00B7 ", parts.ToArray()) : "No start timed yet";
        }

        public static string Json()
        {
            Dictionary<string, KeyValuePair<string, double>> d = Latest();
            List<string> o = new List<string>();
            foreach (KeyValuePair<string, KeyValuePair<string, double>> kv in d)
                o.Add(Json_.S(kv.Key) + ":{\"when\":" + Json_.S(kv.Value.Key) + ",\"secs\":" + kv.Value.Value.ToString("0.0", CultureInfo.InvariantCulture) + "}");
            return "{\"latest\":{" + string.Join(",", o.ToArray()) + "},\"text\":" + Json_.S(Summary()) + "}";
        }
    }
}
