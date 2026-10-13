// irdeck: set up iRacing's Test Drive screen by name - car, track, track layout and "Disable Car Damage" -
// then launch it. Mapped on the 2026 iRacing UI (2026-10-09):
//   Test Drive dialog: a car card and a track card ("Click the cards to change your selection"). Under each
//   card's picture: unnamed buttons (Car Info, Paint Car / Track Info) and the name as a Text element.
//   Car card -> "Set Car" panel: Search box (Edit), rows are DataItems named after the car with a "Select" cell,
//                and the "Disable Car Damage" switch (a Group whose AutomationId starts with toggle-switch;
//                green when on - it exposes no on/off state, so the colour is read).
//   Track card -> "Set Track" panel: Search box, rows named "<track> button"; their "Select" cell opens a list
//                of layouts (Hyperlinks named after each layout).
//   tdsetup "<car>" "<track>" ["<layout>"] [--damage-off | --damage-on] [--launch]
//   tdfind car|track "<text>"      list what the search shows (7 at most)
//   tdfind layout "<track>"        list the layouts iRacing offers for that track
// Lookups and setup only ever click when the Test Drive dialog (or its Set Car / Set Track panel) is verified on
// screen, and refuse while a sim session is running (the sim covers the UI then, so a click would land on the sim).
// TdWhy holds a plain-English reason for the last failure; My Drive shows it on the deck.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Automation;

namespace IRDeck
{
    static partial class Program
    {
        sealed class UEl { public AutomationElement E; public string Name; public ControlType Type; public Rect R; public string Id; public bool Owned = true; }

        static string TdWhy = "";   // why the last Test Drive step failed, in plain words

        // AI fixture matching is deliberately text based so saved UIA dumps exercise the same refusal rules.
        static string AiPresetPath { get { return Path.Combine(Dir, "mydrive", "ai-preset.ini"); } }
        static string AiStatusPath { get { return Path.Combine(Dir, "mydrive", "ai-status.txt"); } }
        static string AiReason = "";
        static void AiFail(string code, string reason)
        {
            AiReason = reason;
            Log("airace: " + reason);
            try { Directory.CreateDirectory(Path.GetDirectoryName(AiStatusPath)); File.WriteAllText(AiStatusPath, code); } catch { }
        }
        static readonly string[] AiSteps = { "race-sessions", "car", "track", "track-options", "time-of-day", "weather", "race-options", "track-conditions", "ai" };
        static bool AiContains(AutomationElement root, string name)
        {
            // iRacing puts icon glyphs in front of link names ("\uE0xx Last Settings"): compare the cleaned name, never the raw one
            try
            {
                AutomationElementCollection all = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
                foreach (AutomationElement e in all) { try { if (Same(Clean(e.Current.Name), name)) return true; } catch { } }
            }
            catch { }
            return false;
        }
        static AutomationElement AiModal(AutomationElement window)
        {
            AutomationElement title = null;
            try
            {
                AutomationElementCollection all = window.FindAll(TreeScope.Descendants, Condition.TrueCondition);
                foreach (AutomationElement e in all) if (Clean(e.Current.Name).IndexOf("AI Racing", StringComparison.OrdinalIgnoreCase) >= 0) { title = e; break; }
            }
            catch { }
            if (title == null) return null;
            AutomationElement p = title;
            for (int i = 0; i < 12 && p != null; i++)
            {
                if (AiContainsId(p, "create-an-ai-race-modal-wizard") && AiContainsId(p, "wizard-sidebar-link-set-race-sessions") && AiContainsId(p, "wizard-sidebar-link-set-ai")) return p;
                try { p = TreeWalker.ControlViewWalker.GetParent(p); } catch { p = null; }
            }
            return null;
        }
        static bool AiContainsId(AutomationElement root, string idPrefix)
        {
            try
            {
                AutomationElementCollection all = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
                foreach (AutomationElement e in all) if ((e.Current.AutomationId ?? "").StartsWith(idPrefix, StringComparison.Ordinal)) return true;
            }
            catch { }
            return false;
        }
        static List<UEl> AiElements(AutomationElement root)
        {
            var list = new List<UEl>(); AutomationElementCollection all = null;
            RunWithTimeout(delegate { try { all = root.FindAll(TreeScope.Descendants, Condition.TrueCondition); } catch { } }, 15000);
            if (all == null) return list;
            foreach (AutomationElement e in all)
            {
                try { list.Add(new UEl { E = e, Name = Clean(e.Current.Name), Type = e.Current.ControlType, R = e.Current.BoundingRectangle, Id = e.Current.AutomationId ?? "" }); }
                catch { }
            }
            return list;
        }
        // list rows carry iRacing's tags: "[Legacy] BMW Z4 GT3", "New  Aston Martin Valkyrie AMR-LMH" - compare without them
        static string AiRowName(string n)
        {
            n = (n ?? "").Trim();
            if (n.StartsWith("[Legacy]", StringComparison.OrdinalIgnoreCase)) n = n.Substring(8).Trim();
            if (n.StartsWith("New ", StringComparison.OrdinalIgnoreCase)) n = n.Substring(4).Trim();
            return n;
        }
        static UEl AiById(List<UEl> els, string id)
        {
            // the wizard's step links sit in a collapsed sidebar that UIA reports as off screen; they still invoke (2026-10-12 live run)
            return els.Find(u => u.Id == id && u.E.Current.IsEnabled && (!u.E.Current.IsOffscreen || id.StartsWith("wizard-sidebar-link-set-", StringComparison.Ordinal)));
        }
        static UEl AiByName(List<UEl> els, string name, ControlType type)
        {
            List<UEl> matches = els.FindAll(u => AiCandidateMatches("root", "root", u.Type.ProgrammaticName, type.ProgrammaticName, u.Name, name));
            List<UEl> usable = matches.FindAll(u => AiCandidateEligible(u.E.Current.IsEnabled, u.E.Current.IsOffscreen));
            if (usable.Count != 1 && matches.Count != 0)
            {
                StringBuilder b = new StringBuilder("airace survey: ").Append(name).Append(" candidates (eligible=").Append(usable.Count).Append(")");
                foreach (UEl u in matches)
                    b.Append(" | enabled=").Append(u.E.Current.IsEnabled).Append(" offscreen=").Append(u.E.Current.IsOffscreen)
                     .Append(" rect=[").Append(u.R.X).Append(',').Append(u.R.Y).Append(' ').Append(u.R.Width).Append('x').Append(u.R.Height).Append(']');
                Log(b.ToString());
            }
            return usable.Count == 1 ? usable[0] : null;
        }
        static bool AiCandidateEligible(bool enabled, bool offscreen) { return enabled && !offscreen; }
        static bool AiShouldOpenAiPage(bool singleRaceVisible) { return !singleRaceVisible; }
        static AutomationElement AiChooser(AutomationElement window)
        {
            AutomationElementCollection all = null;
            try { all = window.FindAll(TreeScope.Descendants, Condition.TrueCondition); } catch { }
            if (all == null) return null;
            foreach (AutomationElement e in all)
            {
                try
                {
                    if (!Same(Clean(e.Current.Name), "Last Settings")) continue;
                    AutomationElement p = e;
                    for (int i = 0; i < 8 && p != null; i++)
                    {
                        if (AiContains(p, "Last Settings") && AiContains(p, "New Race") && (AiContains(p, "Close") || AiContains(p, "Back"))) return p;   // iRacing renamed the chooser's Close to Back (seen 2026-10-11)
                        p = TreeWalker.ControlViewWalker.GetParent(p);
                    }
                }
                catch { }
            }
            return null;
        }
        static bool AiPress(UEl u)
        {
            if (u == null || !AiPressAllowed(u.Id, u.Name)) return false;
            if (Process.GetProcessesByName("iRacingSim64DX11").Length != 0) { Log("airace survey: sim=True immediately before UI press; stopped"); return false; }
            Log("airace press: " + u.Name + (u.Id.Length > 0 ? " [" + u.Id + "]" : ""));
            try { object p; if (u.E.TryGetCurrentPattern(InvokePattern.Pattern, out p)) { ((InvokePattern)p).Invoke(); return true; } } catch { }
            return ClickEl(u);
        }
        static bool aiAllowNew, aiAllowContinue, aiAllowLayout, aiAllowRace;
        static string aiLayoutName = "";
        static bool AiPressAllowed(string id, string name)
        {
            id = id ?? "";
            return id.StartsWith("wizard-sidebar-link-set-", StringComparison.Ordinal)
                || id.StartsWith("default-close-modal-btn-", StringComparison.Ordinal)
                || Same(name, "AI Single Player") || Same(name, "Single Race")
                || Same(name, "Last Settings") || Same(name, "Close") || Same(name, "Back") || Same(name, "Select")
                || (aiAllowNew && Same(name, "New Race")) || (aiAllowRace && Same(name, "Race"))
                || (aiAllowContinue && Same(name, "Continue"))
                || (aiAllowLayout && Same(name, aiLayoutName));
        }
        static bool AiChooserValid(bool last, bool newRace, bool close)
        {
            return last && newRace && close;
        }
        static bool AiCandidateMatches(string scope, string wantedScope, string type, string wantedType, string name, string wantedName)
        {
            return Same(scope, wantedScope) && Same(type, wantedType) && Same(name, wantedName);
        }
        static bool AiFixtureWizard(string dump)
        {
            bool wizard = false, first = false, last = false;
            foreach (string line in dump.Split('\n')) { if (line.IndexOf("|create-an-ai-race-modal-wizard|", StringComparison.Ordinal) >= 0) wizard = true; if (line.IndexOf("|wizard-sidebar-link-set-race-sessions|", StringComparison.Ordinal) >= 0) first = true; if (line.IndexOf("|wizard-sidebar-link-set-ai|", StringComparison.Ordinal) >= 0) last = true; }
            return wizard && first && last;
        }
        static bool AiFixtureContinue(string dump, bool inModal)
        {
            if (!inModal) return false;
            foreach (string line in dump.Split('\n')) if (line.StartsWith("Hyperlink|") && line.IndexOf("Continue", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            return false;
        }
        static string AiMismatch(bool car, bool track) { return !car ? "CAR NOT FOUND" : (!track ? "TRACK NOT FOUND" : ""); }
        static UEl AiPickRow(AutomationElement modal, string name, bool car)
        {
            UEl edit = null;
            if (!WaitFor(delegate { edit = null; List<UEl> ms = AiElements(modal); UEl panel = Find(ms, u => u.Id.StartsWith(car ? "select-car-id-" : "select-track-id-", StringComparison.Ordinal)); if (panel == null) return false; foreach (UEl x in ms) if (x.Type == ControlType.Edit && x.Name == "Search" && panel.R.Contains(x.R)) { edit = x; break; } return edit != null; /* three Search boxes exist (page behind, sidebar, this panel): only the one inside the car/track select panel */ }, 8000, 250, "UI CHANGED", car ? "car search" : "track search")) return null;
            // ValuePattern needs no focus or click (the background page has a search box too)
            // iRacing's list only filters on real key presses (a programmatic value is ignored; live 2026-10-12): focus this box and type
            if (!TdFront()) return null; try { edit.E.SetFocus(); } catch { return null; } Thread.Sleep(300);
            SendCombo("ctrl+a", 0); SendCombo("backspace", 0); TypeText(name);
            UEl selected = null;
            bool found = WaitFor(delegate
            {
                List<UEl> current = AiElements(modal);
                // wizard rows: "<icon> Car Name" (Clean strips the icon); a row you can use has a Select link (no Owned flag in this list)
                UEl row = Find(current, u => u.Type == ControlType.DataItem && (Same(AiRowName(u.Name), name) || Same(AiRowName(u.Name), name + " button")) && u.R.Y > edit.R.Y && u.R.Y < edit.R.Y + 600);
                if (row == null) return false;
                // cars have a "Select" link; tracks only a "Select" cell with a layout arrow (live 2026-10-12)
                UEl cell = Find(current, u => u.Type == ControlType.Hyperlink && Same(u.Name, "Select") && Math.Abs(u.R.Y - row.R.Y) < 12)
                        ?? Find(current, u => u.Type == ControlType.DataItem && Same(u.Name, "Select") && Math.Abs(u.R.Y - row.R.Y) < 12);
                if (cell == null) return false;
                if (!AiPress(cell)) return false;
                selected = cell;
                return true;
            }, 12000, 250, car ? "CAR NOT FOUND" : "TRACK NOT FOUND", car ? "car row" : "track row");
            return found ? selected : null;
        }
        static bool WaitFor(Func<bool> condition, int timeoutMs, int stepMs, string reason, string what)
        {
            Stopwatch watch = Stopwatch.StartNew();
            DateTime end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            bool ready = false;
            do
            {
                try { ready = condition(); } catch { ready = false; }
                if (ready) break;
                if (DateTime.UtcNow >= end) break;
                Thread.Sleep(stepMs);
            } while (true);
            watch.Stop();
            Log("airace wait: " + what + " " + (ready ? "ready" : reason) + " in " + watch.ElapsedMilliseconds + " ms");
            return ready;
        }
        static bool WaitFor(Func<bool> condition, int timeoutMs, int stepMs = 250)
        {
            return WaitFor(condition, timeoutMs, stepMs, "UI CHANGED", "condition");
        }
        static void AiScreenshot(IntPtr hwnd, string file)
        {
            Rect r = AutomationElement.FromHandle(hwnd).Current.BoundingRectangle;
            if (r.Width < 100 || r.Height < 100) throw new Exception("iRacing window has no usable size");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(file)));
            using (System.Drawing.Bitmap b = new System.Drawing.Bitmap((int)r.Width, (int)r.Height))
            using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(b)) { g.CopyFromScreen((int)r.X, (int)r.Y, 0, 0, b.Size); b.Save(file, System.Drawing.Imaging.ImageFormat.Png); }
        }
        static void AiDump(AutomationElement modal, string path, string step)
        {
            List<UEl> els = AiElements(modal); StringBuilder b = new StringBuilder();
            b.AppendLine("STEP " + step);
            foreach (UEl u in els)
            {
                string state = ""; object p;
                try { if (u.E.TryGetCurrentPattern(TogglePattern.Pattern, out p)) state += " toggle=" + ((TogglePattern)p).Current.ToggleState; } catch { }
                try { if (u.E.TryGetCurrentPattern(ValuePattern.Pattern, out p)) state += " value=" + ((ValuePattern)p).Current.Value; } catch { }
                try { if (u.E.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p)) state += " selected=" + ((SelectionItemPattern)p).Current.IsSelected; } catch { }
                b.AppendLine(u.Type.ProgrammaticName + "|" + u.Name.Replace("|", "/") + "|" + u.Id + "|enabled=" + u.E.Current.IsEnabled + state);
            }
            File.AppendAllText(path, b.ToString());
        }
        static void AiCleanup(AutomationElement window)
        {
            AutomationElement modal = AiModal(window);
            if (modal != null)
            {
                UEl back = AiElements(modal).Find(u => u.Type == ControlType.Hyperlink && u.Id.StartsWith("default-close-modal-btn-") && Same(u.Name, "Back"));
                if (back != null) { AiPress(back); WaitFor(delegate { return AiModal(window) == null; }, 5000, 250, "UI CHANGED", "wizard close"); }
            }
            // Only close a verified chooser; a background page can also contain a Close link.
            AutomationElement chooser = AiChooser(window);
            if (chooser == null) return;
            List<UEl> all = AiElements(chooser);
            bool last = AiByName(all, "Last Settings", ControlType.Hyperlink) != null;
            bool newRace = AiByName(all, "New Race", ControlType.Hyperlink) != null;
            UEl close = AiByName(all, "Close", ControlType.Hyperlink) ?? AiByName(all, "Back", ControlType.Hyperlink);
            if (AiChooserValid(last, newRace, close != null) && close != null) AiPress(close);
        }
        static int CmdAirace(string[] args)
        {
            bool dry = Array.IndexOf(args, "--dry") >= 0;
            string op = args.Length == 0 ? "start" : args[0].ToLowerInvariant(), output = null;
            aiAllowNew = false; aiAllowContinue = false;
            for (int i = 0; i < args.Length; i++) { if (args[i] == "--out" && i + 1 < args.Length) output = args[++i]; else if (args[i] != "--dry" && args[i] != "--new") op = args[i].ToLowerInvariant(); }
            if (op == "start") return CmdAiraceStart(dry);
            if (op == "save") { Log("airace save: not available on the New Race path"); return 1; }
            if (op != "survey") { Log("airace: use start [--dry] or survey [--out file] [--dry]"); return 1; }
            if (Process.GetProcessesByName("iRacingSim64DX11").Length != 0) { Log("airace survey: sim=True; stopped"); return 3; }
            AutomationElement window = FindUiWindow(); if (window == null) { Log("airace survey: iRacing UI is not up"); return 2; }
            List<UEl> current = AiElements(window);
            if (dry)
            {
                AutomationElement scoped = AiModal(window);
                Log("airace survey --dry: modal=" + (scoped != null) + "; no controls pressed");
                if (scoped != null) foreach (UEl u in AiElements(scoped)) if (u.Id.StartsWith("wizard-sidebar-link-set-")) Log("airace survey --dry: " + u.Id + " enabled=" + u.E.Current.IsEnabled);
                return 0;
            }
            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            string dump = output == null ? Path.Combine(Root, @"docs\research\ai-wizard-dump-" + stamp + ".txt") : Path.GetFullPath(output);
            tdUi = new IntPtr(window.Current.NativeWindowHandle);
            try
            {
                UEl single = AiByName(current, "Single Race", ControlType.Button);
                if (AiShouldOpenAiPage(single != null))
                {
                    UEl ai = AiByName(current, "AI Single Player", ControlType.Hyperlink);
                    if (ai == null || !AiPress(ai)) throw new Exception("AI Single Player link was not uniquely available");
                    Thread.Sleep(800); current = AiElements(window);
                    single = AiByName(current, "Single Race", ControlType.Button);
                }
                if (single == null || !AiPress(single)) throw new Exception("Single Race chooser was not verified");
                Thread.Sleep(600); current = AiElements(window);
                UEl last = AiByName(current, "Last Settings", ControlType.Hyperlink);
                if (!AiChooserValid(last != null, AiByName(current, "New Race", ControlType.Hyperlink) != null, (AiByName(current, "Close", ControlType.Hyperlink) ?? AiByName(current, "Back", ControlType.Hyperlink)) != null)) throw new Exception("chooser did not contain Last Settings, New Race, and Close/Back");
                UEl openWith = aiAllowNew ? AiByName(current, "New Race", ControlType.Hyperlink) : last;
                if (!AiPress(openWith)) throw new Exception((aiAllowNew ? "New Race" : "Last Settings") + " could not be pressed");
                Thread.Sleep(1000); AutomationElement modal = AiModal(window);
                if (modal == null) throw new Exception("AI Racing modal could not be verified");
                File.WriteAllText(dump, "AI wizard survey " + stamp + Environment.NewLine);
                foreach (string id in AiSteps)
                {
                    modal = AiModal(window); if (modal == null) throw new Exception("modal disappeared before " + id);
                    current = AiElements(modal); UEl step = AiById(current, "wizard-sidebar-link-set-" + id);
                    if (step == null) { File.AppendAllText(dump, "STEP " + id + " locked" + Environment.NewLine); continue; }
                    if (!AiPress(step)) throw new Exception("step could not be safely pressed: " + id);
                    Thread.Sleep(350); modal = AiModal(window); if (modal == null) throw new Exception("modal disappeared after " + id);
                    AiDump(modal, dump, id);
                    AiScreenshot(tdUi, Path.Combine(Root, @"tests\shots\ai-survey-" + id + ".png"));
                }
                AiCleanup(window);
                current = AiElements(window);
                if (AiByName(current, "AI Single Player", ControlType.Hyperlink) == null) throw new Exception("UI did not return to AI Single Player page after Back and Close");
                Log("airace survey: saved scoped modal dump " + dump); return 0;
            }
            catch (Exception ex) { Log("airace survey: " + ex.Message); AiCleanup(window); return 1; }
        }

        static MdCombo AiCombo()
        {
            MdCombo c = MdChosen();
            if (c.Car.Length > 0 && c.Track.Length > 0) return c;
            List<MdCombo> recent = MdRecents(1);
            return recent.Count == 0 ? null : recent[0];
        }

        static int AiStop(string code, string reason, AutomationElement window)
        {
            AiFail(code, "airace stopped: " + reason);
            AiCleanup(window);
            return 3;
        }

        static int CmdAiraceStart(bool dry)
        {
            if (SessionActive() || Process.GetProcessesByName("iRacingSim64DX11").Length != 0) { Log("airace start: a session is running"); return 3; }
            MdCombo combo = AiCombo();
            if (combo == null || combo.Car.Length == 0 || combo.Track.Length == 0) { AiFail("NO CHOICE", "airace start: no MY DRIVE or last driven car and track"); return 3; }
            Log("airace start" + (dry ? " --dry" : "") + ": " + combo.Car + " at " + combo.Track + (combo.Layout.Length > 0 ? " / " + combo.Layout : ""));
            if (dry) return 0;
            AutomationElement window = FindUiWindow(); if (window == null) { AiFail("UI CHANGED", "airace start: iRacing UI not found"); return 3; }
            tdUi = new IntPtr(window.Current.NativeWindowHandle);
            try
            {
                List<UEl> els = AiElements(window);
                UEl single = AiByName(els, "Single Race", ControlType.Button);
                if (single == null)
                {
                    UEl ai = AiByName(els, "AI Single Player", ControlType.Hyperlink);
                    if (ai == null || !AiPress(ai)) return AiStop("UI CHANGED", "AI Single Player is unavailable", window);
                    if (!WaitFor(delegate { els = AiElements(window); single = AiByName(els, "Single Race", ControlType.Button); return single != null; }, 15000, 250, "UI CHANGED", "Single Race button")) return AiStop("UI CHANGED", "AI Single Player page did not appear", window);
                }
                if (single == null || !AiPress(single)) return AiStop("UI CHANGED", "Single Race is unavailable", window);
                AutomationElement chooser = null;
                if (!WaitFor(delegate { chooser = AiChooser(window); return chooser != null; }, 15000, 250, "UI CHANGED", "Single Race choices")) return AiStop("UI CHANGED", "Single Race choices did not appear", window);
                els = AiElements(chooser);
                UEl last = AiByName(els, "Last Settings", ControlType.Hyperlink), fresh = AiByName(els, "New Race", ControlType.Hyperlink);
                UEl close = AiByName(els, "Close", ControlType.Hyperlink) ?? AiByName(els, "Back", ControlType.Hyperlink);
                if (!AiChooserValid(last != null, fresh != null, close != null)) return AiStop("UI CHANGED", "Single Race choices changed", window);
                // Last Settings is known empty here; only the explicit start path may use New Race.
                aiAllowNew = true; bool opened = AiPress(fresh); aiAllowNew = false;
                if (!opened) return AiStop("UI CHANGED", "New Race could not be opened", window);
                AutomationElement modal = null;
                if (!WaitFor(delegate { modal = AiModal(window); return modal != null; }, 20000, 250, "UI CHANGED", "wizard modal")) return AiStop("UI CHANGED", "AI Racing wizard changed", window);
                els = AiElements(modal);
                UEl carStep = AiById(els, "wizard-sidebar-link-set-car");
                if (carStep == null || !AiPress(carStep)) return AiStop("UI CHANGED", "Your Car step missing", window);
                modal = AiModal(window); UEl pickedCar = AiPickRow(modal, combo.Car, true);
                if (pickedCar == null) return AiStop("CAR NOT FOUND", combo.Car + " is unavailable or not owned", window);
                if (combo.Layout.Length > 0)
                {
                    UEl trackStep = AiById(AiElements(modal), "wizard-sidebar-link-set-track"); if (trackStep == null || !AiPress(trackStep)) return AiStop("UI CHANGED", "Tracks step missing", window);
                    modal = AiModal(window); UEl row = AiPickRow(modal, combo.Track, false);
                    if (row == null) row = AiPickRow(modal, combo.Track + " - " + combo.Layout, false);
                    if (row == null) return AiStop("TRACK NOT FOUND", combo.Track + " is unavailable", window);
                    UEl layout = null;
                    if (!WaitFor(delegate { List<UEl> menus = TdMenuItems(AiElements(modal), row); layout = menus.Find(u => Same(u.Name, combo.Layout)); return layout != null; }, 10000, 250, "TRACK NOT FOUND", "track layout")) return AiStop("TRACK NOT FOUND", combo.Track + " layout is unavailable", window);
                    aiLayoutName = combo.Layout; aiAllowLayout = true;
                    bool layoutPressed = AiPress(new UEl { E = layout.E, Id = layout.Id, Name = layout.Name, Type = layout.Type, R = layout.R });
                    aiAllowLayout = false; aiLayoutName = "";
                    if (!layoutPressed) return AiStop("TRACK NOT FOUND", combo.Track + " layout is unavailable", window);
                }
                else
                {
                    UEl trackStep = AiById(AiElements(modal), "wizard-sidebar-link-set-track"); if (trackStep == null || !AiPress(trackStep)) return AiStop("UI CHANGED", "Tracks step missing", window);
                    modal = AiModal(window); if (AiPickRow(modal, combo.Track, false) == null) return AiStop("TRACK NOT FOUND", combo.Track + " is unavailable", window);
                }
                // Car and track are set: press Continue until the wizard closes (each press moves one step; the last starts the race).
                // The step's elements are replaced after every press, so read them fresh each time and treat a vanished element as "not yet".
                for (int press = 0; press < 12; press++)
                {
                    UEl next = null; bool closed = false;
                    if (!WaitFor(delegate
                    {
                        try
                        {
                            modal = AiModal(window); if (modal == null) { closed = true; return true; }
                            next = AiElements(modal).Find(u => { try { return u.Type == ControlType.Hyperlink && Same(u.Name, "Continue") && u.E.Current.IsEnabled; } catch { return false; } });
                            return next != null;
                        }
                        catch { return false; }
                    }, 15000, 250, "UI CHANGED", "Continue " + (press + 1))) return AiStop("UI CHANGED", "Continue missing", window);
                    if (closed)
                    {
                        // the wizard ends on a "Summary" page (car, track, weather, Back / Race) that has no step sidebar: verify it, then press Race
                        UEl race = null;
                        WaitFor(delegate
                        {
                            try
                            {
                                List<UEl> all = AiElements(window);
                                bool summary = all.Exists(u => Same(u.Name, "Summary"));
                                bool shows = all.Exists(u => AiRowName(u.Name).IndexOf(combo.Car, StringComparison.OrdinalIgnoreCase) >= 0) && all.Exists(u => u.Name.IndexOf(combo.Track, StringComparison.OrdinalIgnoreCase) >= 0);
                                List<UEl> races = all.FindAll(u => (u.Type == ControlType.Hyperlink || u.Type == ControlType.Button) && Same(u.Name, "Race"));
                                race = (summary && shows && races.Count == 1) ? races[0] : null;
                                return race != null;
                            }
                            catch { return false; }
                        }, 10000, 250, "UI CHANGED", "Summary Race");
                        if (race == null) return AiStop("UI CHANGED", "Summary did not show the chosen car and track", window);
                        aiAllowRace = true; bool raced = false; try { raced = AiPress(race); } catch { } aiAllowRace = false;
                        Log("airace start: pressed Race on the Summary (" + combo.Car + " at " + combo.Track + ")");
                        if (!raced) return AiStop("UI CHANGED", "Race failed", window);
                        break;
                    }
                    aiAllowContinue = true; bool pressed = false; try { pressed = AiPress(next); } catch { } aiAllowContinue = false;
                    Log("airace start: pressed Continue " + (press + 1));
                    if (!pressed) return AiStop("UI CHANGED", "Continue failed", window);
                    Thread.Sleep(400);   // let the next step render before reading it again (WaitFor then polls)
                }
                if (!WaitFor(delegate { return Process.GetProcessesByName("iRacingSim64DX11").Length != 0; }, 90000, 250, "UI CHANGED", "sim process")) return AiStop("UI CHANGED", "sim did not start", window);
                // the sim needs ~40 s to load the session; CmdGo only works once the session is up (live 2026-10-12: at 2.7 s it said "nothing to start")
                if (!WaitFor(delegate { Tele tl = Tele.Open(); if (tl == null) return false; tl.Dispose(); return true; }, 150000, 500, "UI CHANGED", "session loaded")) return AiStop("UI CHANGED", "session did not load", window);
                Thread.Sleep(2000);
                int go = CmdGo(); if (go != 0) { Thread.Sleep(3000); go = CmdGo(); }
                if (go != 0) return go;
                if (!WaitFor(delegate { return OnTrack(); }, 120000, 250, "UI CHANGED", "IsOnTrack")) return AiStop("UI CHANGED", "session did not reach the car", window);
                return 0;
            }
            catch (Exception ex) { Log("airace start: " + ex.Message); return AiStop("UI CHANGED", "wizard controls changed", window); }
            finally { aiAllowNew = false; aiAllowContinue = false; aiAllowLayout = false; aiLayoutName = ""; }
        }

        static List<UEl> UiAll(AutomationElement root)
        {
            var list = new List<UEl>();
            AutomationElementCollection all = null;
            RunWithTimeout(delegate { try { all = root.FindAll(TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition); } catch { } }, 15000);
            if (all == null) return list;
            foreach (AutomationElement e in all)
            {
                try
                {
                    // Clean drops the icon-font glyphs the UI puts in front of some labels
                    string raw = e.Current.Name ?? "";
                    // a row that starts with the shopping-cart icon glyph is content you do not own
                    var u = new UEl { E = e, Name = Clean(raw), Type = e.Current.ControlType, R = e.Current.BoundingRectangle, Id = e.Current.AutomationId ?? "", Owned = !(raw.Length > 0 && raw[0] >= 0xE000 && raw[0] <= 0xF8FF) };
                    if (!u.R.IsEmpty) list.Add(u);
                }
                catch { }
            }
            return list;
        }

        static IntPtr tdUi = IntPtr.Zero;   // the iRacing UI window while a Test Drive step runs

        // The iRacing UI is the window at that screen point (nothing - Peter's own apps, the Claude window - is covering it).
        static bool UiOwnsPoint(IntPtr uh, int x, int y)
        {
            IntPtr h = Native.WindowFromPoint(new Native.PT { X = x, Y = y });
            return h != IntPtr.Zero && Native.GetAncestor(h, 2) == uh;   // 2 = the top-level window
        }

        // Click only where the iRacing UI really is on top. A window that has come in front since the last step is
        // moved behind it again; if something still covers the spot, nothing is clicked (2026-10-09: the Claude app
        // came up over the dialog in the middle of a search).
        static bool TdClick(int x, int y)
        {
            if (Process.GetProcessesByName("iRacingSim64DX11").Length != 0) { TdWhy = "A sim session is running."; Log("UI click stopped: sim=True immediately before click"); return false; }
            if (tdUi != IntPtr.Zero && !UiOwnsPoint(tdUi, x, y))
            {
                FocusWindow(tdUi); Thread.Sleep(300);
                if (!UiOwnsPoint(tdUi, x, y)) { TdWhy = "Another window is in front of iRacing. Move it away and try again."; Log("tdsetup: another window (" + ForegroundName() + ") covers the click spot - stopped"); return false; }
            }
            Click(x, y);
            return true;
        }
        static bool ClickEl(UEl u) { return TdClick((int)(u.R.X + u.R.Width / 2), (int)(u.R.Y + u.R.Height / 2)); }

        // Typing only goes to iRacing's own window.
        static bool TdFront()
        {
            if (Process.GetProcessesByName("iRacingSim64DX11").Length != 0) { TdWhy = "A sim session is running."; Log("UI typing stopped: sim=True immediately before typing"); return false; }
            if (IRacingForeground()) return true;
            if (tdUi != IntPtr.Zero) { FocusWindow(tdUi); Thread.Sleep(250); }
            if (IRacingForeground()) return true;
            TdWhy = "Another window is in front of iRacing. Move it away and try again.";
            Log("tdsetup: not typing - " + ForegroundName() + " is in front, not iRacing");
            return false;
        }

        static bool Same(string a, string b) { return string.Equals((a ?? "").Trim(), (b ?? "").Trim(), StringComparison.OrdinalIgnoreCase); }

        // The cards: the three unnamed "button"s just under the pictures (Car Info, Paint Car, Track Info) anchor
        // everything; the car and track names are the Text elements about 50 px below them.
        sealed class Cards { public UEl CarInfo, TrackInfo, CarName, TrackName, Layout; }

        static Cards ReadCards(List<UEl> els)
        {
            var btns = els.FindAll(u => u.Type == ControlType.Button && u.Name == "button" && u.R.Y < 900);
            if (btns.Count < 3) return null;
            btns.Sort((a, b) => a.R.Y != b.R.Y && Math.Abs(a.R.Y - b.R.Y) > 6 ? a.R.Y.CompareTo(b.R.Y) : a.R.X.CompareTo(b.R.X));
            var row = btns.FindAll(u => Math.Abs(u.R.Y - btns[0].R.Y) < 6);
            if (row.Count < 3) return null;
            var c = new Cards { CarInfo = row[0], TrackInfo = row[2] };
            double ny = c.CarInfo.R.Y + 49;
            foreach (var u in els)
            {
                if (Math.Abs(u.R.Y - ny) > 8 || u.Name.Length == 0) continue;
                if (u.Type == ControlType.Text && u.R.X < c.CarInfo.R.X && c.CarName == null) c.CarName = u;
                else if (u.Type == ControlType.Text && u.R.X > c.CarInfo.R.X + 100 && u.R.X < c.TrackInfo.R.X && c.TrackName == null) c.TrackName = u;
                else if (u.Type == ControlType.Button && u.R.X > c.TrackInfo.R.X - 150 && u.R.X < c.TrackInfo.R.X + 150) c.Layout = u;
            }
            return c;
        }

        static UEl Find(List<UEl> els, Predicate<UEl> p) { return els.Find(p); }

        // The Test Drive dialog is on screen: its own Last settings / Close / Test Drive links are all there.
        // (2026-10-10: iRacing's UI now calls the Close link "Back"; both count, or START stops with "not showing".)
        static bool DialogOpen(List<UEl> els)
        {
            return Find(els, u => u.Type == ControlType.Hyperlink && u.Name == "Last settings") != null
                && Find(els, u => u.Type == ControlType.Hyperlink && (u.Name == "Close" || u.Name == "Back")) != null
                && Find(els, u => u.Type == ControlType.Hyperlink && u.Name == "Test Drive") != null;
        }

        // Make sure the Set Car (car = true) or Set Track panel is the one showing. A card click toggles its own
        // panel, so the card is only clicked when that panel is not already open - and only while the dialog is up
        // (a click that misses the dialog lands on iRacing's home page: 2026-10-09 it opened the news and a
        // Steam sign-in). Returns the fresh element list, or null when the panel would not open.
        static List<UEl> EnsurePanel(AutomationElement root, bool car)
        {
            string title = car ? "Set Car" : "Set Track";
            List<UEl> els = UiAll(root);
            if (Find(els, u => u.Type == ControlType.Text && u.Name == title) != null) return els;
            if (!DialogOpen(els)) { TdWhy = "The Test Drive window isn't open in iRacing."; Log("tdsetup: the Test Drive dialog is not showing - stopped"); return null; }
            Cards cards = ReadCards(els);
            if (cards == null) { TdWhy = "iRacing's Test Drive window doesn't look the way it should."; Log("tdsetup: Test Drive cards not found - stopped"); return null; }
            bool clicked = car ? TdClick((int)(cards.CarInfo.R.X - 60), (int)(cards.CarInfo.R.Y - 110)) : TdClick((int)(cards.TrackInfo.R.X - 200), (int)(cards.TrackInfo.R.Y - 110));
            if (!clicked) return null;
            for (int i = 0; i < 12; i++)
            {
                Thread.Sleep(300);
                els = UiAll(root);
                if (Find(els, u => u.Type == ControlType.Text && u.Name == title) != null) return els;
                if (!DialogOpen(els)) break;
            }
            TdWhy = "iRacing's " + title + " list didn't open.";
            Log("tdsetup: the " + title + " panel did not open - stopped");
            return null;
        }

        // Search a picker (Set Car / Set Track) and click the Select cell of the row whose name matches.
        static UEl PickRow(AutomationElement root, string search, string rowName, int tries = 20)
        {
            List<UEl> els = null; UEl edit = null;
            for (int i = 0; i < 20 && edit == null; i++) { els = UiAll(root); edit = Find(els, u => u.Type == ControlType.Edit && u.Name == "Search"); if (edit == null) Thread.Sleep(300); }
            if (edit == null) { TdWhy = "iRacing's search box didn't appear."; Log("tdsetup: the search box did not appear"); return null; }
            if (!ClickEl(edit)) return null;
            Thread.Sleep(200);
            if (!TdFront()) return null;
            SendCombo("ctrl+a", 0); Thread.Sleep(80); SendCombo("backspace", 0); Thread.Sleep(150);
            TypeText(search);
            for (int i = 0; i < tries; i++)
            {
                Thread.Sleep(400);
                els = UiAll(root);
                // the list is virtual: rows far below exist off-screen until the search has filtered it, so only a
                // row just under the search box counts (clicking an off-screen row does nothing)
                UEl row = Find(els, u => u.Owned && u.Type == ControlType.DataItem && Same(u.Name, rowName) && u.R.Y > edit.R.Y && u.R.Y < edit.R.Y + 400);
                if (row == null) continue;
                UEl sel = Find(els, u => u.Type == ControlType.DataItem && u.Name.StartsWith("Select") && Math.Abs(u.R.Y - row.R.Y) < 4);
                if (sel == null) continue;
                if (!ClickEl(sel)) return null;
                return sel;
            }
            TdWhy = "iRacing has no \"" + search + "\" in its list (do you own it?).";
            Log("tdsetup: '" + rowName + "' is not in the list (owned? spelt as in iRacing?)");
            return null;
        }

        // The damage switch is green when on. Returns null when it is not on screen.
        static bool? DamageSwitchOn(UEl sw)
        {
            try
            {
                using (var bmp = new System.Drawing.Bitmap((int)sw.R.Width, (int)sw.R.Height))
                {
                    using (var g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen((int)sw.R.X, (int)sw.R.Y, 0, 0, bmp.Size);
                    int green = 0;
                    for (int x = 0; x < bmp.Width; x += 2) { var p = bmp.GetPixel(x, bmp.Height / 2); if (p.G > 170 && p.R < 170 && p.B < 140) green++; }
                    return green > bmp.Width / 6;
                }
            }
            catch { return null; }
        }

        // The iRacing UI brought up on the Test Drive dialog (restored, in front, dialog verified). Returns the element
        // list, or null with TdWhy set. The sidebar button toggles the dialog, so it is only pressed when the dialog is closed.
        static List<UEl> TdOpenDialog(AutomationElement root, string who)
        {
            IntPtr uh = new IntPtr(root.Current.NativeWindowHandle);
            tdUi = uh;
            if (Native.IsIconic(uh)) Native.ShowWindow(uh, 9);
            FocusWindow(uh);
            List<UEl> els = UiAll(root);
            Predicate<UEl> isLast = u => u.Type == ControlType.Hyperlink && u.Name == "Last settings";
            if (Find(els, isLast) == null)
            {
                CmdNav(new string[] { "--button", "Test Drive" });
                for (int i = 0; i < 20 && Find(els, isLast) == null; i++) { Thread.Sleep(400); els = UiAll(root); }
            }
            if (!DialogOpen(els)) { TdWhy = "The Test Drive window won't open in iRacing."; Log(who + ": the Test Drive dialog did not open - stopped"); return null; }
            return els;
        }

        // The rows the picker's list shows (names only). Only rows just under the search box and inside the window count:
        // the list is virtual and keeps rows far off screen.
        static List<string> TdRows(AutomationElement root, List<UEl> els, UEl edit)
        {
            var names = new List<string>();
            double bottom = double.MaxValue;
            try { bottom = root.Current.BoundingRectangle.Bottom + 4; } catch { }
            foreach (var u in els)
            {
                if (u.Type != ControlType.DataItem || u.R.Y <= edit.R.Y || u.R.Bottom > bottom || u.Name.Length < 2 || u.Name.StartsWith("Select") || u.R.Width < 300) continue;
                if (u.Name == "Car Name" || u.Name == "Track Name" || !u.Owned) continue;
                string n = u.Name.EndsWith(" button") ? u.Name.Substring(0, u.Name.Length - 7) : u.Name;
                if (!names.Contains(n)) names.Add(n);
            }
            return names;
        }

        // Types `text` into the Set Car / Set Track search box and returns what the list then shows (up to `max`).
        // kind = "car" | "track". Returns null (TdWhy says why) when it could not look.
        static List<string> TdLookup(string kind, string text, int max)
        {
            TdWhy = "";
            if (SessionActive()) { TdWhy = "A session is running. Get out of it first."; Log("tdfind: a session is running - stopped"); return null; }
            AutomationElement root = FindUiWindow();
            if (root == null) { TdWhy = "The iRacing screen isn't open (press RIG ON)."; Log("tdfind: iRacing UI is not running"); return null; }
            List<UEl> els = TdOpenDialog(root, "tdfind"); if (els == null) return null;
            els = EnsurePanel(root, kind == "car"); if (els == null) return null;
            UEl edit = Find(els, u => u.Type == ControlType.Edit && u.Name == "Search");
            if (edit == null) { TdWhy = "iRacing's search box didn't appear."; Log("tdfind: no search box"); return null; }
            if (!ClickEl(edit)) return null;
            Thread.Sleep(200);
            if (!TdFront()) return null;
            SendCombo("ctrl+a", 0); Thread.Sleep(80); SendCombo("backspace", 0); Thread.Sleep(150);
            TypeText(text);
            // never carry on if the box did not take the text (it would be the wrong field)
            string typed = EditText(edit);
            if (typed != null && !Same(typed, text)) { TdWhy = "iRacing's search box didn't take the text."; Log("tdfind: the search box shows '" + typed + "', not '" + text + "' - stopped"); return null; }
            // done when the same rows show twice in a row (the list filters a moment after typing)
            List<string> rows = null, prev = null;
            for (int i = 0; i < 14; i++)
            {
                Thread.Sleep(i == 0 ? 900 : 450);
                els = UiAll(root);
                rows = TdRows(root, els, edit);
                if (prev != null && string.Join("|", rows.ToArray()) == string.Join("|", prev.ToArray())) break;
                prev = rows;
            }
            if (rows.Count > max) rows = rows.GetRange(0, max);
            return rows;
        }

        // The text in an Edit control (null when it cannot be read).
        static string EditText(UEl edit)
        {
            try
            {
                object p;
                if (edit.E.TryGetCurrentPattern(ValuePattern.Pattern, out p)) return ((ValuePattern)p).Current.Value;
            }
            catch { }
            return null;
        }

        // The layouts iRacing offers for `track`: search it, press its Select cell (opens the layout list) and read the
        // list without choosing. The list is left open; the next step starts by clicking the search box, which closes it.
        // Returns null (TdWhy says why); an empty list means the track has only one layout.
        static List<string> TdLayouts(string track, int max)
        {
            TdWhy = "";
            if (SessionActive()) { TdWhy = "A session is running. Get out of it first."; Log("tdfind: a session is running - stopped"); return null; }
            AutomationElement root = FindUiWindow();
            if (root == null) { TdWhy = "The iRacing screen isn't open (press RIG ON)."; Log("tdfind: iRacing UI is not running"); return null; }
            List<UEl> els = TdOpenDialog(root, "tdfind"); if (els == null) return null;
            if (EnsurePanel(root, false) == null) return null;
            UEl tsel = PickRow(root, track, track + " button");
            if (tsel == null) return null;
            List<UEl> items = TdLayoutMenu(root, tsel, 12);
            var names = new List<string>();
            foreach (UEl u in items) if (!names.Contains(u.Name)) names.Add(u.Name);
            if (names.Count > max) names = names.GetRange(0, max);
            return names;
        }

        // The layout list that drops down under a track's Select cell, right-aligned with it: links in one tight column
        // starting just under the cell. (The dialog's own Test Drive / Close links are also right-aligned, further down.)
        static List<UEl> TdMenuItems(List<UEl> els, UEl tsel)
        {
            var all = els.FindAll(u => u.Type == ControlType.Hyperlink && u.Name.Length > 0 && u.R.Height > 20 && u.R.Height < 45 && u.R.Y > tsel.R.Y && Math.Abs(u.R.Right - tsel.R.Right) < 80
                                       && u.Name != "Test Drive" && u.Name != "Close" && u.Name != "Back" && u.Name != "Last settings");
            all.Sort((x, y) => x.R.Y.CompareTo(y.R.Y));
            var items = new List<UEl>();
            foreach (UEl u in all)
            {
                if (items.Count == 0 ? u.R.Y - tsel.R.Bottom > 40 : u.R.Y - items[items.Count - 1].R.Y > items[items.Count - 1].R.Height * 1.8) break;
                items.Add(u);
            }
            return items;
        }

        // Waits for that list; empty when it never appears.
        static List<UEl> TdLayoutMenu(AutomationElement root, UEl tsel, int tries)
        {
            var items = new List<UEl>();
            for (int i = 0; i < tries && items.Count == 0; i++)
            {
                Thread.Sleep(300);
                items = TdMenuItems(UiAll(root), tsel);
            }
            return items;
        }

        // tdfind car|track "<text>" | tdfind layout "<track>": list what iRacing shows (to get names exactly right)
        static int CmdTdFind(string[] a)
        {
            if (a.Length < 2 || (a[0] != "car" && a[0] != "track" && a[0] != "layout")) { Log("tdfind: car|track \"text\"  or  layout \"track\""); return 1; }
            List<string> rows = a[0] == "layout" ? TdLayouts(a[1], 12) : TdLookup(a[0], a[1], 12);
            if (rows == null) { Log("tdfind: " + TdWhy); return 1; }
            foreach (string n in rows) Log("tdfind " + a[0] + ": " + n);
            if (rows.Count == 0) Log("tdfind " + a[0] + ": nothing" + (a[0] == "layout" ? " (only one layout)" : " found"));
            return 0;
        }

        static int CmdTdSetup(string[] a)
        {
            var words = new List<string>(); bool noDamage = false, damageOn = false, launch = false;
            foreach (string t in a) { if (t == "--damage-off") noDamage = true; else if (t == "--damage-on") damageOn = true; else if (t == "--launch") launch = true; else words.Add(t); }
            TdWhy = "";
            if (words.Count < 2) { Log("tdsetup: need \"car\" \"track\" [\"layout\"]"); return 1; }
            string car = words[0], track = words[1], layout = words.Count > 2 ? words[2] : "";
            if (SessionActive()) { TdWhy = "A session is already running."; Log("tdsetup: a session is running - leave it first"); return 3; }
            AutomationElement root = FindUiWindow();
            if (root == null) { TdWhy = "The iRacing screen isn't open (press RIG ON)."; Log("tdsetup: iRacing UI is not running (press RIG ON)"); return 2; }
            IntPtr uh = new IntPtr(root.Current.NativeWindowHandle);
            tdUi = uh;
            if (Native.IsIconic(uh)) Native.ShowWindow(uh, 9);
            FocusWindow(uh);

            // 1. the Test Drive dialog (the sidebar button toggles it, so only press it when the dialog is closed)
            List<UEl> els = UiAll(root);
            Predicate<UEl> isLast = u => u.Type == ControlType.Hyperlink && u.Name == "Last settings";
            if (Find(els, isLast) == null)
            {
                CmdNav(new string[] { "--button", "Test Drive" });
                for (int i = 0; i < 20 && Find(els, isLast) == null; i++) { Thread.Sleep(400); els = UiAll(root); }
            }
            Cards cards = ReadCards(els);
            Log("tdsetup: dialog " + (Find(els, isLast) != null ? "open" : "NOT open") + ", " + els.Count + " elements, cards " +
                (cards == null ? "not found" : (cards.CarName != null ? cards.CarName.Name : "?") + " / " + (cards.TrackName != null ? cards.TrackName.Name : "?")));
            if (cards == null || cards.CarName == null || cards.TrackName == null) { TdWhy = "The Test Drive window isn't open in iRacing."; return 1; }

            // 2. car
            if (!Same(cards.CarName.Name, car))
            {
                if (EnsurePanel(root, true) == null) return 1;
                if (PickRow(root, car, car) == null) return 1;
                bool changed = false;
                for (int i = 0; i < 10 && !changed; i++) { Thread.Sleep(400); els = UiAll(root); cards = ReadCards(els); changed = cards != null && cards.CarName != null && Same(cards.CarName.Name, car); }
                if (!changed) { TdWhy = "iRacing didn't switch to " + car + "."; Log("tdsetup: the car did not change to " + car); return 1; }
            }
            // 3. damage off / on (the switch lives in the Set Car panel; green = damage is disabled)
            if (noDamage || damageOn)
            {
                els = EnsurePanel(root, true);
                if (els == null) return 1;
                UEl sw = Find(els, u => u.Id.StartsWith("toggle-switch"));
                bool? on = sw == null ? (bool?)null : DamageSwitchOn(sw);
                bool wantDisabled = noDamage;
                if (on != null && on != wantDisabled)
                {
                    try { ((InvokePattern)sw.E.GetCurrentPattern(InvokePattern.Pattern)).Invoke(); } catch { ClickEl(sw); }
                    Thread.Sleep(500);
                    on = DamageSwitchOn(sw);
                }
                Log("tdsetup: car damage " + (on == null ? "switch not found" : on == wantDisabled ? (wantDisabled ? "disabled" : "enabled") : "could NOT be set"));
            }
            // 4. track and layout
            els = UiAll(root); cards = ReadCards(els);
            bool trackOk = cards != null && Same(cards.TrackName.Name, track) && (layout == "" || (cards.Layout != null && Same(cards.Layout.Name, layout)));
            if (!trackOk && cards != null)
            {
                if (EnsurePanel(root, false) == null) return 1;
                UEl tsel = PickRow(root, track, track + " button", 8);
                if (tsel == null)
                {
                    // iRacing's session info can carry the layout in the track's name ("Tsukuba Circuit 2k Full"): try the
                    // name without its last words, and take those words as the layout ("2k Full" = "2000 Full")
                    string[] w = track.Split(' ');
                    for (int cut = 1; cut < w.Length && tsel == null; cut++)
                    {
                        string shorter = string.Join(" ", w, 0, w.Length - cut);
                        tsel = PickRow(root, shorter, shorter + " button", 5);
                        if (tsel != null)
                        {
                            string rest = Regex.Replace(string.Join(" ", w, w.Length - cut, cut), @"(\d+)k\b", "${1}000", RegexOptions.IgnoreCase);
                            Log("tdsetup: '" + track + "' is track '" + shorter + "' with layout '" + rest + "'");
                            track = shorter; if (layout == "") layout = rest;
                        }
                    }
                    if (tsel == null) { TdWhy = "iRacing has no track called " + words[1] + " in your list."; return 1; }
                }
                // the Select cell opens the list of layouts; pick the named one (exact, then close enough), or the first
                UEl item = null; var offered = new List<string>();
                for (int i = 0; i < 15 && item == null; i++)
                {
                    Thread.Sleep(300);
                    els = UiAll(root);
                    // the layout list drops down under that Select cell, right-aligned with it
                    var items = TdMenuItems(els, tsel);
                    offered = items.ConvertAll(u => u.Name);
                    item = layout != "" ? items.Find(u => Same(u.Name, layout)) : null;
                    if (item == null && layout != "") item = items.Find(u => u.Name.IndexOf(layout, StringComparison.OrdinalIgnoreCase) >= 0 || layout.IndexOf(u.Name, StringComparison.OrdinalIgnoreCase) >= 0);
                    if (item == null && layout == "" && items.Count > 0) item = items[0];
                }
                if (item == null)
                {
                    // a track with a single layout may have been chosen by the Select press itself
                    els = UiAll(root); cards = ReadCards(els);
                    if (cards == null || !Same(cards.TrackName.Name, track) || layout != "")
                    {
                        TdWhy = layout != "" ? "iRacing doesn't offer the " + layout + " layout at " + track + "." : "iRacing didn't show the layouts for " + track + ".";
                        Log("tdsetup: layout '" + layout + "' not offered for " + track + (offered.Count > 0 ? " (offered: " + string.Join(", ", offered.ToArray()) + ")" : ""));
                        return 1;
                    }
                }
                else
                {
                    if (layout != "" && !Same(item.Name, layout)) Log("tdsetup: layout '" + layout + "' taken as '" + item.Name + "'");
                    try { ((InvokePattern)item.E.GetCurrentPattern(InvokePattern.Pattern)).Invoke(); } catch { ClickEl(item); }
                    Thread.Sleep(900);
                }
            }
            // 5. check
            els = UiAll(root); cards = ReadCards(els);
            if (cards == null || !Same(cards.CarName.Name, car) || !Same(cards.TrackName.Name, track))
            { TdWhy = "iRacing shows " + (cards == null ? "nothing" : cards.CarName.Name + " at " + cards.TrackName.Name) + " instead of what was asked."; Log("tdsetup: the cards show " + (cards == null ? "nothing" : cards.CarName.Name + " / " + cards.TrackName.Name) + " - not what was asked"); return 1; }
            Log("tdsetup: " + cards.CarName.Name + " at " + cards.TrackName.Name + (cards.Layout != null ? " (" + cards.Layout.Name + ")" : ""));
            if (!launch) return 0;
            int lrc = CmdTestDrive(new string[0]);
            if (lrc != 0) TdWhy = "iRacing's Test Drive button didn't start the session.";
            return lrc;
        }
    }
}
