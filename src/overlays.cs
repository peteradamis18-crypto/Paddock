// irdeck overlays (the OVERLAYS screen on the Stream Deck): which irdashies widgets are on, where they sit, presets.
// irdashies keeps everything in %APPDATA%\irdashies\config.json and only reads it when it starts (it has no file
// watcher - tested 2026-10-09, and its own code never re-reads it), so a change = edit the file, then restart it.
// A restart takes about 1.5 s with no focus change; the edit always backs the file up first.
//   ovl list [--json]              every widget: on/off, where it sits
//   ovl set <id> on|off|toggle     switch one overlay (restarts irdashies unless --defer)
//   ovl preset <name> [--defer]    race | practice | quali | minimal | friends (overlays\presets\<name>.json)
//   ovl save <name>                save the overlays that are on now, and where they sit, into that preset
//   ovl alloff [--defer]           every overlay off
//   ovl apply                      restart irdashies so it reads the file (refuses while the car is moving)
//   ovl edit                       drag mode on/off (irdashies' own hotkey Ctrl+Alt+Shift+E; never while driving)
//   ovl init [--force]             write the five starting presets from what is on now
//   doctor                         run Rig Doctor on the top screen (irdash does the work)
// --defer = only edit the file; irdash restarts irdashies once, 1.5 s after the last change, so three quick
// taps on the deck cost one restart. State for the screens is in overlays\state.ini.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDeck
{
    static class OvlNative
    {
        public delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    }

    static partial class Program
    {
        // The deck screen's overlays, in order (irdashies id, label). Same list as irdash\src\overlays.cs.
        static readonly string[][] DeckWidgets = {
            new[] { "relative", "RELATIVE" }, new[] { "standings", "STANDINGS" }, new[] { "blindspotmonitor", "BLIND SPOT" }, new[] { "deltaspeed", "SPEED DELTA" },
            new[] { "sectordelta", "SECTORS" }, new[] { "flag", "FLAGS" }, new[] { "fuel", "FUEL" }, new[] { "input", "INPUTS" },
            new[] { "map", "MAP" }, new[] { "flatmap", "FLAT MAP" }, new[] { "pitlanehelper", "PIT LANE" }, new[] { "cornername", "CORNERS" },
            new[] { "laptimelog", "LAP TIMES" }, new[] { "weather", "WEATHER" }, new[] { "battle", "BATTLE" }, new[] { "slowcarahead", "SLOW CAR" } };
        static readonly string[] OvlPresets = { "race", "practice", "quali", "minimal", "friends" };

        // Where a widget goes when it is switched on but its saved place is not on the middle race screen
        // (irdashies' own defaults point at the old top monitor). x,y on a 2560x1440 screen, top-left corner.
        static readonly Dictionary<string, int[]> OvlSpots = new Dictionary<string, int[]> {
            { "standings", new[] { 40, 120 } }, { "input", new[] { 1082, 1330 } }, { "fuel", new[] { 2020, 420 } }, { "map", new[] { 2113, 1173 } },
            { "flatmap", new[] { 880, 1180 } }, { "weather", new[] { 2346, 300 } }, { "cornername", new[] { 1105, 1090 } }, { "laptimelog", new[] { 520, 960 } },
            { "battle", new[] { 1050, 980 } }, { "slowcarahead", new[] { 1055, 380 } } };

        // The starting presets. RACE is what you run today.
        static readonly Dictionary<string, string[]> OvlStart = new Dictionary<string, string[]> {
            { "race", new[] { "flag", "relative", "blindspotmonitor", "pitlanehelper", "sectordelta", "deltaspeed" } },
            { "practice", new[] { "flag", "relative", "blindspotmonitor", "pitlanehelper", "sectordelta", "deltaspeed", "input", "laptimelog", "cornername", "fuel" } },
            { "quali", new[] { "flag", "blindspotmonitor", "pitlanehelper", "sectordelta", "deltaspeed", "laptimelog", "input" } },
            { "minimal", new[] { "flag", "blindspotmonitor", "pitlanehelper" } },
            { "friends", new[] { "flag", "blindspotmonitor", "pitlanehelper", "cornername", "input" } } };

        static string IrdConfig { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"irdashies\config.json"); } }
        static string OvlDir { get { return Path.Combine(Root, "overlays"); } }
        static string OvlPresetFile(string n) { return Path.Combine(OvlDir, @"presets\" + n + ".json"); }
        static string OvlLabel(string id) { foreach (string[] w in DeckWidgets) if (w[0] == id) return w[1]; return id.ToUpperInvariant(); }
        static JavaScriptSerializer Js() { JavaScriptSerializer s = new JavaScriptSerializer(); s.MaxJsonLength = int.MaxValue; s.RecursionLimit = 200; return s; }

        // ---- irdashies config.json ----
        sealed class IrdCfg
        {
            public Dictionary<string, object> Root;
            public List<Dictionary<string, object>> Widgets = new List<Dictionary<string, object>>();
            public Dictionary<string, object> Find(string id)
            {
                foreach (Dictionary<string, object> w in Widgets) if (Convert.ToString(w["id"]) == id) return w;
                return null;
            }
        }

        static IrdCfg LoadIrd()
        {
            string f = IrdConfig;
            if (!File.Exists(f)) return null;
            IrdCfg c = new IrdCfg();
            c.Root = Js().DeserializeObject(File.ReadAllText(f)) as Dictionary<string, object>;
            if (c.Root == null) return null;
            string prof = c.Root.ContainsKey("currentProfile") ? Convert.ToString(c.Root["currentProfile"]) : "default";
            Dictionary<string, object> dashes = c.Root["dashboards"] as Dictionary<string, object>;
            Dictionary<string, object> dash = dashes != null && dashes.ContainsKey(prof) ? dashes[prof] as Dictionary<string, object> : null;
            IList arr = dash != null && dash.ContainsKey("widgets") ? dash["widgets"] as IList : null;
            if (arr == null) return null;
            foreach (object o in arr) { Dictionary<string, object> d = o as Dictionary<string, object>; if (d != null && d.ContainsKey("id")) c.Widgets.Add(d); }
            return c;
        }

        // the config is replaced only after a backup (backup\irdashies, newest 40 kept)
        static void SaveIrd(IrdCfg c)
        {
            string f = IrdConfig;
            string bk = Path.Combine(Root, @"backup\irdashies");
            Directory.CreateDirectory(bk);
            File.Copy(f, Path.Combine(bk, "config-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + ".json"), true);
            string[] old = Directory.GetFiles(bk, "config-*.json");
            Array.Sort(old);
            for (int i = 0; i < old.Length - 40; i++) { try { File.Delete(old[i]); } catch { } }
            string tmp = f + ".irdeck.tmp";
            File.WriteAllText(tmp, Js().Serialize(c.Root), new UTF8Encoding(false));
            File.Copy(tmp, f, true);
            File.Delete(tmp);
        }

        static bool WidgetOn(Dictionary<string, object> w) { object v; return w.TryGetValue("enabled", out v) && v is bool && (bool)v; }

        static int[] WidgetRect(Dictionary<string, object> w)
        {
            object lo; if (!w.TryGetValue("layout", out lo)) return null;
            Dictionary<string, object> l = lo as Dictionary<string, object>;
            if (l == null) return null;
            try { return new[] { Convert.ToInt32(l["x"]), Convert.ToInt32(l["y"]), Convert.ToInt32(l["width"]), Convert.ToInt32(l["height"]) }; }
            catch { return null; }
        }

        static bool OnRaceScreen(int[] r)
        {
            if (r == null) return false;
            System.Drawing.Rectangle b = SimArea();
            return r[0] >= b.X - 10 && r[1] >= b.Y - 10 && r[0] + r[2] <= b.Right + 10 && r[1] + r[3] <= b.Bottom + 10;
        }

        static void PutRect(Dictionary<string, object> w, int x, int y)
        {
            int[] r = WidgetRect(w);
            Dictionary<string, object> l = new Dictionary<string, object>();
            l["x"] = x; l["y"] = y; l["width"] = r != null ? r[2] : 300; l["height"] = r != null ? r[3] : 100;
            w["layout"] = l;
        }

        // a widget that is switched on must be where you can see it
        static bool PlaceIfOff(Dictionary<string, object> w)
        {
            string id = Convert.ToString(w["id"]);
            int[] spot;
            if (OnRaceScreen(WidgetRect(w)) || !OvlSpots.TryGetValue(id, out spot)) return false;
            System.Drawing.Rectangle b = SimArea();
            PutRect(w, b.X + spot[0], b.Y + spot[1]);
            return true;
        }

        // ---- overlays\state.ini (what the deck screen and the top screen show) ----
        static Dictionary<string, string> OvlState()
        {
            Dictionary<string, string> st = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string f = Path.Combine(OvlDir, "state.ini");
            if (File.Exists(f)) foreach (string l in File.ReadAllLines(f)) { int e = l.IndexOf('='); if (e > 0) st[l.Substring(0, e)] = l.Substring(e + 1); }
            return st;
        }
        static void OvlSaveState(Dictionary<string, string> st)
        {
            Directory.CreateDirectory(OvlDir);
            StringBuilder sb = new StringBuilder();
            foreach (KeyValuePair<string, string> kv in st) sb.Append(kv.Key).Append('=').Append(kv.Value).Append("\r\n");
            File.WriteAllText(Path.Combine(OvlDir, "state.ini"), sb.ToString());
        }
        static void OvlNote(Dictionary<string, string> st, string msg, bool pending)
        {
            st["msg"] = msg;
            st["msgAt"] = DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture);
            if (pending) { st["pending"] = "1"; st["changed"] = DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture); }
        }

        // ---- the command ----
        static int CmdOvl(string[] a)
        {
            if (a.Length == 0) { Log("ovl: need list|set|preset|save|alloff|apply|edit|init"); return 1; }
            bool defer = Array.IndexOf(a, "--defer") >= 0, force = Array.IndexOf(a, "--force") >= 0, json = Array.IndexOf(a, "--json") >= 0;
            List<string> args = new List<string>();
            foreach (string t in a) if (!t.StartsWith("--")) args.Add(t);
            string sub = args[0].ToLowerInvariant();
            Mutex mx = new Mutex(false, "Local\\irdeck-ovl");
            try { if (!mx.WaitOne(30000)) { Log("ovl: another overlay change is still running"); return 3; } }
            catch (AbandonedMutexException) { }
            try
            {
                switch (sub)
                {
                    case "list": return OvlList(json);
                    case "set": return OvlSet(args, defer);
                    case "preset": return OvlPreset(args.Count > 1 ? args[1].ToLowerInvariant() : "", defer);
                    case "save": return OvlSave(args.Count > 1 ? args[1].ToLowerInvariant() : "");
                    case "alloff": return OvlAllOff(defer);
                    case "apply": return OvlApply();
                    case "edit": return OvlEdit();
                    case "init": return OvlInit(force);
                }
                Log("ovl: unknown '" + sub + "'");
                return 1;
            }
            finally { mx.ReleaseMutex(); }
        }

        static int OvlList(bool json)
        {
            IrdCfg c = LoadIrd();
            if (c == null) { Log("ovl: no irdashies config at " + IrdConfig); return 1; }
            StringBuilder sb = new StringBuilder("[");
            foreach (Dictionary<string, object> w in c.Widgets)
            {
                string id = Convert.ToString(w["id"]); int[] r = WidgetRect(w); bool on = WidgetOn(w), here = OnRaceScreen(r);
                if (json) { if (sb.Length > 1) sb.Append(','); sb.Append("{\"id\":\"" + id + "\",\"on\":" + (on ? "true" : "false") + ",\"onScreen\":" + (here ? "true" : "false") + "}"); }
                else Log(string.Format("{0,-20} {1}  {2}{3}", id, on ? "ON " : "off", r == null ? "no place saved" : string.Format("x={0} y={1} {2}x{3}", r[0], r[1], r[2], r[3]), here ? "" : "  (not on the middle race screen)"));
            }
            if (json) Log(sb.Append(']').ToString());
            return 0;
        }

        static int OvlSet(List<string> args, bool defer)
        {
            if (args.Count < 3) { Log("ovl set: need <id> on|off|toggle"); return 1; }
            IrdCfg c = LoadIrd();
            if (c == null) { Log("ovl: no irdashies config at " + IrdConfig); return 1; }
            Dictionary<string, object> w = c.Find(args[1]);
            if (w == null) { Log("ovl: irdashies has no overlay called '" + args[1] + "'"); return 1; }
            string mode = args[2].ToLowerInvariant();
            bool now = mode == "on" ? true : mode == "off" ? false : !WidgetOn(w);
            w["enabled"] = now;
            bool moved = now && PlaceIfOff(w);
            SaveIrd(c);
            Dictionary<string, string> st = OvlState();
            OvlNote(st, OvlLabel(args[1]) + (now ? " switched on" : " switched off"), true);
            OvlSaveState(st);
            Log("ovl: " + args[1] + (now ? " on" : " off") + (moved ? " (put on the middle race screen)" : ""));
            return defer ? 0 : OvlApply();
        }

        static int OvlAllOff(bool defer)
        {
            IrdCfg c = LoadIrd();
            if (c == null) { Log("ovl: no irdashies config at " + IrdConfig); return 1; }
            foreach (Dictionary<string, object> w in c.Widgets) w["enabled"] = false;
            SaveIrd(c);
            Dictionary<string, string> st = OvlState();
            OvlNote(st, "All overlays off", true);
            OvlSaveState(st);
            Log("ovl: all overlays off");
            return defer ? 0 : OvlApply();
        }

        // ---- presets: id, enabled and place of every widget ----
        static string PresetJson(string name, IrdCfg c, IDictionary<string, bool> forceOn)
        {
            StringBuilder sb = new StringBuilder("{\"name\":\"" + name + "\",\"saved\":\"" + DateTime.Now.ToString("s") + "\",\"widgets\":[\r\n");
            bool first = true;
            foreach (Dictionary<string, object> w in c.Widgets)
            {
                string id = Convert.ToString(w["id"]);
                bool on = forceOn != null ? forceOn.ContainsKey(id) : WidgetOn(w);
                int[] r = WidgetRect(w);
                if (forceOn != null && on && !OnRaceScreen(r)) { int[] spot; if (OvlSpots.TryGetValue(id, out spot)) { System.Drawing.Rectangle b = SimArea(); r = new[] { b.X + spot[0], b.Y + spot[1], r != null ? r[2] : 300, r != null ? r[3] : 100 }; } }
                if (!first) sb.Append(",\r\n");
                first = false;
                sb.Append("{\"id\":\"" + id + "\",\"enabled\":" + (on ? "true" : "false"));
                if (r != null) sb.Append(",\"layout\":{\"x\":" + r[0] + ",\"y\":" + r[1] + ",\"width\":" + r[2] + ",\"height\":" + r[3] + "}");
                sb.Append('}');
            }
            return sb.Append("\r\n]}\r\n").ToString();
        }

        static void WritePreset(string name, string json)
        {
            string f = OvlPresetFile(name);
            Directory.CreateDirectory(Path.GetDirectoryName(f));
            if (File.Exists(f))
            {
                string bk = Path.Combine(Root, @"backup\overlays");
                Directory.CreateDirectory(bk);
                File.Copy(f, Path.Combine(bk, name + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json"), true);
            }
            File.WriteAllText(f, json, new UTF8Encoding(false));
        }

        static int OvlInit(bool force)
        {
            IrdCfg c = LoadIrd();
            if (c == null) { Log("ovl: no irdashies config at " + IrdConfig); return 1; }
            int made = 0;
            foreach (string name in OvlPresets)
            {
                if (!force && File.Exists(OvlPresetFile(name))) continue;
                Dictionary<string, bool> on = new Dictionary<string, bool>();
                foreach (string id in OvlStart[name]) on[id] = true;
                WritePreset(name, PresetJson(name, c, on));
                made++;
            }
            Log("ovl: " + made + " starting preset(s) written to " + Path.Combine(OvlDir, "presets"));
            return 0;
        }

        static int OvlSave(string name)
        {
            if (Array.IndexOf(OvlPresets, name) < 0) { Log("ovl save: preset must be one of " + string.Join(", ", OvlPresets)); return 1; }
            IrdCfg c = LoadIrd();
            if (c == null) { Log("ovl: no irdashies config at " + IrdConfig); return 1; }
            WritePreset(name, PresetJson(name, c, null));
            Dictionary<string, string> st = OvlState();
            st["preset"] = name;
            OvlNote(st, "Saved as " + name.ToUpperInvariant(), false);
            OvlSaveState(st);
            Log("ovl: saved the overlays that are on now as preset " + name);
            return 0;
        }

        static int OvlPreset(string name, bool defer)
        {
            if (Array.IndexOf(OvlPresets, name) < 0) { Log("ovl preset: must be one of " + string.Join(", ", OvlPresets)); return 1; }
            IrdCfg c = LoadIrd();
            if (c == null) { Log("ovl: no irdashies config at " + IrdConfig); return 1; }
            if (!File.Exists(OvlPresetFile(name))) OvlInit(false);
            IList list = null;
            try { Dictionary<string, object> p = Js().DeserializeObject(File.ReadAllText(OvlPresetFile(name))) as Dictionary<string, object>; list = p != null ? p["widgets"] as IList : null; }
            catch (Exception ex) { Log("ovl: preset " + name + " is not readable: " + ex.Message); return 1; }
            if (list == null) { Log("ovl: preset " + name + " has no widgets"); return 1; }
            int on = 0;
            foreach (object o in list)
            {
                Dictionary<string, object> pw = o as Dictionary<string, object>;
                if (pw == null || !pw.ContainsKey("id")) continue;
                Dictionary<string, object> w = c.Find(Convert.ToString(pw["id"]));
                if (w == null) continue;
                // only the switch and the place come from the preset; each widget's own styling stays as it is
                bool en = pw.ContainsKey("enabled") && pw["enabled"] is bool && (bool)pw["enabled"];
                w["enabled"] = en; if (en) on++;
                Dictionary<string, object> lay = pw.ContainsKey("layout") ? pw["layout"] as Dictionary<string, object> : null;
                if (lay != null) w["layout"] = lay;
                if (en) PlaceIfOff(w);
            }
            SaveIrd(c);
            Dictionary<string, string> st = OvlState();
            st["preset"] = name;
            OvlNote(st, name.ToUpperInvariant() + " overlays (" + on + " on)", true);
            OvlSaveState(st);
            Log("ovl: preset " + name + " (" + on + " overlays on)");
            return defer ? 0 : OvlApply();
        }

        // ---- restart irdashies so it reads the file ----
        static string IrdashiesExe()
        {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "irdashies");
            string[] apps = Directory.Exists(root) ? Directory.GetDirectories(root, "app-*") : new string[0];
            if (apps.Length == 0) return null;
            Array.Sort(apps, delegate (string x, string y) { return new Version(Path.GetFileName(y).Substring(4)).CompareTo(new Version(Path.GetFileName(x).Substring(4))); });
            return Path.Combine(apps[0], "irdashies.exe");
        }

        static List<IntPtr> IrdashiesWindows()
        {
            List<IntPtr> r = new List<IntPtr>();
            OvlNative.EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                StringBuilder t = new StringBuilder(128);
                OvlNative.GetWindowText(h, t, 128);
                if (t.ToString().StartsWith("irDashies -") && OvlNative.IsWindowVisible(h)) r.Add(h);
                return true;
            }, IntPtr.Zero);
            return r;
        }

        // while you drive the sim is the topmost window; the overlays go in front of it (without taking focus)
        static void RaiseIrdashies()
        {
            foreach (IntPtr h in IrdashiesWindows())
                Native.SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10 | 0x200);
        }

        // Update.exe / squirrel.exe living under the irdashies folder means Squirrel is replacing the program file.
        static bool IrdUpdating()
        {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "irdashies");
            if (!Directory.Exists(root)) return false;
            foreach (string name in new string[] { "Update", "squirrel" })
            {
                Process[] ps;
                try { ps = Process.GetProcessesByName(name); } catch { continue; }
                foreach (Process p in ps)
                {
                    try
                    {
                        string path = p.MainModule.FileName;
                        if (!string.IsNullOrEmpty(path) && path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return true;
                    }
                    catch { }
                }
            }
            return false;
        }

        static bool IrdExeReadable(string exe)
        {
            if (string.IsNullOrEmpty(exe) || !File.Exists(exe)) return false;
            try
            {
                using (FileStream fs = new FileStream(exe, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    return fs.Length > 1024;
            }
            catch { return false; }
        }

        static int OvlApply()
        {
            bool session = SessionActive();
            Dictionary<string, string> st = OvlState();
            if (session && CarMoving())
            {
                // never restart anything under a moving car; irdash asks again every few seconds
                Log("ovl: the car is moving - the overlays will restart when it stops");
                st["pending"] = "1"; OvlSaveState(st);
                return 3;
            }
            string exe = IrdashiesExe();
            if (exe == null) { Log("ovl: irdashies is not installed"); return 1; }
            // Squirrel replaces this exe while its Update.exe is running. Killing the app then, or starting a second
            // copy while the file is still locked, leaves an Explorer error box titled with the exe path.
            if (IrdUpdating())
            {
                Log("ovl: the overlays app is updating - leaving it alone");
                st["pending"] = "1"; OvlSaveState(st);
                return 3;
            }
            IntPtr fg0 = Native.GetForegroundWindow(), sim = SimWindow();
            bool simFront = session && sim != IntPtr.Zero && fg0 == sim;
            Stopwatch sw = Stopwatch.StartNew();
            foreach (Process p in Process.GetProcessesByName("irdashies")) { try { p.Kill(); } catch { } }
            for (int i = 0; i < 60 && Process.GetProcessesByName("irdashies").Length > 0; i++) Thread.Sleep(50);
            if (Process.GetProcessesByName("irdashies").Length > 0 || !IrdExeReadable(exe))
            {
                Log("ovl: irdashies is still closing or its program file is in use - not starting another copy");
                st["pending"] = "1"; OvlSaveState(st);
                return 3;
            }
            IrdCfg now = LoadIrd(); int enabled = 0;
            if (now != null) foreach (Dictionary<string, object> w in now.Widgets) if (WidgetOn(w)) enabled++;
            ProcessStartInfo psi = new ProcessStartInfo(exe);
            psi.UseShellExecute = true; psi.WorkingDirectory = Path.GetDirectoryName(exe);
            try { Process.Start(psi); }
            catch (Exception ex)
            {
                Log("ovl: could not start irdashies (" + ex.Message + ")");
                st["pending"] = "1"; OvlSaveState(st);
                return 3;
            }
            // done when its overlay window is on screen (with no overlay switched on there is no window: 2 s is enough)
            bool window = false;
            while (sw.ElapsedMilliseconds < 15000)
            {
                if (IrdashiesWindows().Count > 0) { window = true; break; }
                if (enabled == 0 && sw.ElapsedMilliseconds > 2000 && Process.GetProcessesByName("irdashies").Length > 0) break;
                if (sw.ElapsedMilliseconds > 5000 && Process.GetProcessesByName("irdashies").Length > 0) break;
                Thread.Sleep(50);
            }
            double secs = sw.ElapsedMilliseconds / 1000.0;
            string note = "";
            if (session)
            {
                RaiseIrdashies();
                if (simFront && Native.GetForegroundWindow() != fg0) { FocusWindow(fg0); note = " (the sim had lost focus - gave it back)"; }
            }
            st = OvlState();
            st["pending"] = "0"; st["editing"] = "0";
            st["restartSecs"] = secs.ToString("0.0", CultureInfo.InvariantCulture);
            st["applied"] = DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture);
            OvlNote(st, window ? "Overlays updated" : "Overlays restarted, none switched on", false);
            OvlSaveState(st);
            Log("ovl: irdashies restarted, " + (window ? "overlay window back after " : "running, no overlay window after ") + secs.ToString("0.0", CultureInfo.InvariantCulture) + " s" + note);
            return 0;
        }

        // ---- drag mode ----
        static int OvlEdit()
        {
            if (SessionActive() && OnTrack()) { Log("ovl edit: not while you are in the car"); return 3; }
            if (Process.GetProcessesByName("irdashies").Length == 0) { int rc = OvlApply(); if (rc != 0) return rc; Thread.Sleep(800); }
            Dictionary<string, string> st = OvlState();
            bool editing = Sv(st, "editing", "0") == "1";
            IntPtr before = Native.GetForegroundWindow();
            CmdHotkey(new[] { "ctrl+alt+shift+e" });   // irdashies' "Edit Layout" shortcut (config.json keybindings.toggle-edit-mode)
            if (!editing) st["prevfg"] = before.ToInt64().ToString(CultureInfo.InvariantCulture);   // irdashies grabs focus when drag mode starts
            else
            {
                // give focus back to whatever had it before drag mode
                Thread.Sleep(400);
                long prev; IntPtr back = long.TryParse(Sv(st, "prevfg", "0"), out prev) ? new IntPtr(prev) : IntPtr.Zero;
                if (back != IntPtr.Zero && OvlNative.IsWindow(back) && Native.GetForegroundWindow() != back && IrdashiesWindows().Contains(Native.GetForegroundWindow())) FocusWindow(back);
            }
            st["editing"] = editing ? "0" : "1";
            OvlNote(st, editing ? "Layout locked" : "Drag the overlays, then press EDIT LAYOUT again and SAVE", false);
            OvlSaveState(st);
            Log("ovl: drag mode " + (editing ? "off" : "on"));
            return 0;
        }

        // ---- Rig Doctor ----
        static int CmdDoctor()
        {
            try { using (var wc = new System.Net.WebClient()) { wc.Proxy = null; wc.DownloadString("http://127.0.0.1:8199/api/doctor/run"); } Log("doctor: requested"); return 0; }   // no proxy lookup: it adds seconds
            catch (Exception ex) { Log("doctor: irdash not reachable (" + ex.Message + ")"); return 1; }
        }

        // START timing (irdash writes the result to dash\timings.tsv): the moment a START key was pressed
        static void MarkStart(string what)
        {
            try { File.WriteAllText(Path.Combine(Root, @"dash\start-mark.txt"), DateTime.UtcNow.Ticks + "\t" + MarkLabel(what)); } catch { }
        }

        // PL-1: a test that started the sim itself (it sets RIG_TEST_OWNS_SIM, tests\guard.ps1) is not Peter driving. The label TEST tells irdash, which then
        // keeps that session out of his outings, seat time and HOME (dash\test-sessions.txt). Peter's own key presses never have the variable.
        static string MarkLabel(string what)
        {
            return string.IsNullOrEmpty(Environment.GetEnvironmentVariable("RIG_TEST_OWNS_SIM")) ? what : "TEST";
        }
    }
}
