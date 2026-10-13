// Overlays (O1): what the Stream Deck OVERLAYS screen and the top screen show, and the whitelist of its keys.
// irdashies keeps its overlays in %APPDATA%\irdashies\config.json; irdeck ("ovl") is the only thing that edits it.
// irdash reads it (read-only) for /overlays, hands deck presses to irdeck one at a time, and restarts irdashies
// once - 1.5 s after the last change, and never while the car is moving - so three quick taps cost one restart.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class Overlays
    {
        // the deck screen's overlays, in order: irdashies id, label on the key (same list as src\overlays.cs in irdeck)
        public static readonly string[][] Widgets = {
            new[] { "relative", "RELATIVE" }, new[] { "standings", "STANDINGS" }, new[] { "blindspotmonitor", "BLIND SPOT" }, new[] { "deltaspeed", "SPEED DELTA" },
            new[] { "sectordelta", "SECTORS" }, new[] { "flag", "FLAGS" }, new[] { "fuel", "FUEL" }, new[] { "input", "INPUTS" },
            new[] { "map", "MAP" }, new[] { "flatmap", "FLAT MAP" }, new[] { "pitlanehelper", "PIT LANE" }, new[] { "cornername", "CORNERS" },
            new[] { "laptimelog", "LAP TIMES" }, new[] { "weather", "WEATHER" }, new[] { "battle", "BATTLE" }, new[] { "slowcarahead", "SLOW CAR" } };
        static readonly string[] Presets = { "race", "practice", "quali", "minimal", "friends" };
        static readonly HashSet<string> Commands = new HashSet<string> {
            "ovtoggle", "ovpreset", "ovsave", "ovalloff", "ovedit", "ovapply", "deltaon", "deltaref", "deltaup", "deltadown", "doctor" };

        static string dir;
        static readonly object gate = new object();
        static readonly Queue<string> queue = new Queue<string>();
        static bool working;
        static Timer tick;
        static string cfgKey; static Dictionary<string, bool> cfgOn = new Dictionary<string, bool>();
        static readonly Dictionary<string, KeyValuePair<DateTime, HashSet<string>>> presetCache = new Dictionary<string, KeyValuePair<DateTime, HashSet<string>>>();

        public static void Init(string d)
        {
            dir = d;
            Directory.CreateDirectory(Path.Combine(dir, "presets"));
            if (!File.Exists(Path.Combine(dir, @"presets\race.json"))) Enqueue("ovl init");          // first run: write the five starting presets
            tick = new Timer(delegate { try { ApplyWhenQuiet(); } catch (Exception ex) { Log.W("overlays: " + ex.Message); } }, null, 2000, 500);
        }

        public static bool Handles(string c) { return Commands.Contains(c); }

        static bool IsWidget(string a) { foreach (string[] w in Widgets) if (w[0] == a) return true; return false; }
        static bool IsPreset(string a) { return Array.IndexOf(Presets, a) >= 0; }

        // A press on the OVERLAYS screen. Whitelisted; the arguments are checked against the lists above.
        public static bool Do(string c, string a)
        {
            a = (a ?? "").ToLowerInvariant();
            switch (c)
            {
                case "ovtoggle": if (!IsWidget(a)) return false; Enqueue("ovl set " + a + " toggle --defer"); return true;
                case "ovpreset": if (!IsPreset(a)) return false; Enqueue("ovl preset " + a + " --defer"); return true;
                case "ovsave": if (!IsPreset(a)) return false; Enqueue("ovl save " + a); return true;
                case "ovalloff": Enqueue("ovl alloff --defer"); return true;
                case "ovedit": Enqueue("ovl edit"); return true;
                case "ovapply": Enqueue("ovl apply"); return true;
                case "deltaon": DeltaBar.Toggle(); return true;
                case "deltaref": DeltaBar.CycleRef(); return true;
                case "deltaup": DeltaBar.Nudge(-10); return true;
                case "deltadown": DeltaBar.Nudge(10); return true;
                case "doctor": Doctor.Run(true); return true;
            }
            return false;
        }

        // ---- run irdeck one command at a time (they all edit the same two files) ----
        static void Enqueue(string args)
        {
            if (Watch.IrdeckPath == null || !File.Exists(Watch.IrdeckPath)) { Log.W("overlays: irdeck.exe not found"); return; }
            lock (gate)
            {
                queue.Enqueue(args);
                if (working) return;
                working = true;
            }
            Thread t = new Thread(Work); t.IsBackground = true; t.Start();
        }

        static void Work()
        {
            while (true)
            {
                string args;
                lock (gate) { if (queue.Count == 0) { working = false; return; } args = queue.Dequeue(); }
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo(Watch.IrdeckPath, args);
                    psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(Watch.IrdeckPath);
                    using (Process p = Process.Start(psi)) { if (!p.WaitForExit(45000)) { try { p.Kill(); } catch { } Log.W("overlays: '" + args + "' took too long"); } }
                }
                catch (Exception ex) { Log.W("overlays: '" + args + "': " + ex.Message); }
            }
        }

        public static bool Busy { get { lock (gate) return working || queue.Count > 0; } }

        // overlays\state.ini, written by irdeck
        static Dictionary<string, string> State()
        {
            Dictionary<string, string> st = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string f = Path.Combine(dir, "state.ini");
                if (File.Exists(f)) foreach (string l in File.ReadAllLines(f)) { int e = l.IndexOf('='); if (e > 0) st[l.Substring(0, e)] = l.Substring(e + 1); }
            }
            catch { }
            return st;
        }
        static string Sv(Dictionary<string, string> st, string k) { string v; return st.TryGetValue(k, out v) ? v : ""; }

        // Squirrel (the overlays app's updater) replaces app-*\irdashies.exe while Update.exe in that folder is running.
        // Killing or starting the app then leaves an Explorer error box titled with the exe path (2026-10-10).
        static string IrdRoot()
        {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "irdashies");
            return Directory.Exists(root) ? root : null;
        }

        public static bool Updating()
        {
            string root = IrdRoot();
            if (root == null) return false;
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

        public static string Exe()
        {
            try
            {
                string root = IrdRoot();
                if (root == null) return null;
                string[] apps = Directory.GetDirectories(root, "app-*");
                if (apps.Length == 0) return null;
                Array.Sort(apps, delegate (string x, string y) { return new Version(Path.GetFileName(y).Substring(4)).CompareTo(new Version(Path.GetFileName(x).Substring(4))); });
                string exe = Path.Combine(apps[0], "irdashies.exe");
                return File.Exists(exe) ? exe : null;
            }
            catch { return null; }
        }

        static bool ExeReadable(string exe)
        {
            try
            {
                using (FileStream fs = new FileStream(exe, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    return fs.Length > 1024;
            }
            catch { return false; }
        }

        // true when a start now would fail and leave the Explorer error box (updater running, or the exe locked / half-written)
        public static bool StartWouldFail()
        {
            if (Updating()) return true;
            string exe = Exe();
            return exe != null && !ExeReadable(exe);
        }

        // edits are applied once they stop (1.5 s quiet), when nothing else is running and the car is not moving
        static void ApplyWhenQuiet()
        {
            if (dir == null || Busy) return;
            Dictionary<string, string> st = State();
            if (Sv(st, "pending") != "1") return;
            long ticks; if (!long.TryParse(Sv(st, "changed"), out ticks)) ticks = 0;
            DateTime changed = new DateTime(ticks, DateTimeKind.Utc);
            if ((DateTime.UtcNow - changed).TotalSeconds < 1.5) return;
            if (Program.CarMoving) return;
            if (lastTry > changed && (DateTime.UtcNow - lastTry).TotalSeconds < 8) return;   // a failed restart is retried slowly, not in a loop
            if (Updating())
            {
                lastTry = DateTime.UtcNow;
                Log.W("overlays: not restarting the overlays app while it is updating");
                return;
            }
            lastTry = DateTime.UtcNow;
            Enqueue("ovl apply");
        }
        static DateTime lastTry = DateTime.MinValue;

        static string ConfigFile { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"irdashies\config.json"); } }

        // which widgets are on in irdashies' config right now (read again only when the file changes)
        static Dictionary<string, bool> ReadOn(out bool found)
        {
            found = false;
            string f = ConfigFile;
            if (!File.Exists(f)) return new Dictionary<string, bool>();
            FileInfo fi = new FileInfo(f);
            string key = fi.LastWriteTimeUtc.Ticks + ":" + fi.Length;
            if (key == cfgKey) { found = true; return cfgOn; }
            Dictionary<string, bool> on = new Dictionary<string, bool>();
            try
            {
                JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue; js.RecursionLimit = 200;
                Dictionary<string, object> root = js.DeserializeObject(File.ReadAllText(f)) as Dictionary<string, object>;
                string prof = root.ContainsKey("currentProfile") ? Convert.ToString(root["currentProfile"]) : "default";
                Dictionary<string, object> dash = (root["dashboards"] as Dictionary<string, object>)[prof] as Dictionary<string, object>;
                foreach (object o in (IList)dash["widgets"])
                {
                    Dictionary<string, object> w = o as Dictionary<string, object>;
                    if (w != null && w.ContainsKey("id")) on[Convert.ToString(w["id"])] = w.ContainsKey("enabled") && w["enabled"] is bool && (bool)w["enabled"];
                }
                found = true;
            }
            catch (Exception ex) { Log.W("overlays: cannot read irdashies config: " + ex.Message); }
            cfgKey = key; cfgOn = on;
            return on;
        }

        // the widgets a preset switches on (read again only when its file changes); null = no such preset
        static HashSet<string> PresetOn(string name)
        {
            string f = Path.Combine(dir, @"presets\" + name + ".json");
            if (!File.Exists(f)) return null;
            DateTime stamp = File.GetLastWriteTimeUtc(f);
            KeyValuePair<DateTime, HashSet<string>> c;
            if (presetCache.TryGetValue(name, out c) && c.Key == stamp) return c.Value;
            HashSet<string> set = new HashSet<string>();
            try
            {
                JavaScriptSerializer js = new JavaScriptSerializer();
                Dictionary<string, object> p = js.DeserializeObject(File.ReadAllText(f)) as Dictionary<string, object>;
                foreach (object o in (IList)p["widgets"])
                {
                    Dictionary<string, object> w = o as Dictionary<string, object>;
                    if (w != null && w.ContainsKey("enabled") && w["enabled"] is bool && (bool)w["enabled"]) set.Add(Convert.ToString(w["id"]));
                }
            }
            catch (Exception ex) { Log.W("overlays: preset " + name + ": " + ex.Message); return null; }
            presetCache[name] = new KeyValuePair<DateTime, HashSet<string>>(stamp, set);
            return set;
        }

        // seconds since the last note (what the screens show for a few seconds, then drop)
        static string MsgAge(Dictionary<string, string> st)
        {
            long ticks;
            if (!long.TryParse(Sv(st, "msgAt"), out ticks)) return "null";
            return Math.Max(0, (DateTime.UtcNow - new DateTime(ticks, DateTimeKind.Utc)).TotalSeconds).ToString("0", CultureInfo.InvariantCulture);
        }

        // JSON for the deck screen and the top screen
        public static string Json()
        {
            if (dir == null) return "{\"widgets\":[]}";
            bool found;
            Dictionary<string, bool> on = ReadOn(out found);
            Dictionary<string, string> st = State();
            CultureInfo inv = CultureInfo.InvariantCulture;
            List<string> ws = new List<string>();
            int count = 0;
            foreach (string[] w in Widgets)
            {
                bool known = on.ContainsKey(w[0]), isOn = known && on[w[0]];
                if (isOn) count++;
                ws.Add("{\"id\":" + Json_.S(w[0]) + ",\"name\":" + Json_.S(w[1]) + ",\"on\":" + (isOn ? "true" : "false") + ",\"known\":" + (known ? "true" : "false") + "}");
            }
            // a preset is "gold" when the deck widgets are on exactly as it says
            List<string> ps = new List<string>();
            foreach (string p in Presets)
            {
                HashSet<string> set = PresetOn(p);
                bool match = set != null && found;
                if (match) foreach (string[] w in Widgets) { bool isOn = on.ContainsKey(w[0]) && on[w[0]]; if (isOn != set.Contains(w[0])) { match = false; break; } }
                ps.Add("{\"id\":" + Json_.S(p) + ",\"name\":" + Json_.S(p.ToUpperInvariant()) + ",\"exists\":" + (set != null ? "true" : "false") + ",\"match\":" + (match ? "true" : "false") + "}");
            }
            bool running = Process.GetProcessesByName("irdashies").Length > 0;
            bool pending = Sv(st, "pending") == "1";
            string saveTo = Sv(st, "preset"); if (!IsPreset(saveTo)) saveTo = "race";
            Frame f = Sdk.Latest;
            return "{\"widgets\":[" + string.Join(",", ws.ToArray()) + "],\"presets\":[" + string.Join(",", ps.ToArray()) + "]" +
                   ",\"onCount\":" + count + ",\"saveTo\":" + Json_.S(saveTo) + ",\"running\":" + (running ? "true" : "false") +
                   ",\"busy\":" + (Busy ? "true" : "false") + ",\"pending\":" + (pending ? "true" : "false") +
                   ",\"waiting\":" + (pending && Program.CarMoving ? "true" : "false") + ",\"editing\":" + (Sv(st, "editing") == "1" ? "true" : "false") +
                   ",\"driving\":" + (Program.IsDriving ? "true" : "false") + ",\"session\":" + (f.Connected ? "true" : "false") +
                   ",\"msg\":" + Json_.S(Sv(st, "msg")) + ",\"msgAt\":" + Json_.S(Sv(st, "msgAt")) + ",\"msgAge\":" + MsgAge(st) +
                   ",\"restartSecs\":" + (Sv(st, "restartSecs") == "" ? "null" : Sv(st, "restartSecs")) +
                   ",\"delta\":" + DeltaBar.Json() + "}";
        }
    }
}
