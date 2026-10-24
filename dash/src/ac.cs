using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    // The rig room's Midea AC (2026-10-23), all through ac\ac.py (portable Python in tools\python; Midea's server, the Midea Air
    // app's own route, ~7 s a command).
    //  - Auto-cool: every 2 minutes ac.py decides (the rule and its numbers live in ac.py / ac\settings.json). Only network
    //    traffic to the AC: safe while Peter drives. When it switches the AC, the top screen says so for 4 s like a deck key.
    //  - The AC screen on the deck (deck-intro\plugin.html, /ac + /api/do ac...): a press changes what Peter WANTS at once (the
    //    keys show it straight away), and one worker sends everything that changed as one `ac.py set` - so three COOLER presses
    //    in a row are one command, not three 7-second waits. While the screen is open the state is re-read every 20 s.
    static class AcAuto
    {
        static string root;
        public static int EveryMs = 120000;
        static readonly object run = new object();          // one ac.py at a time (auto-cool, the screen, a status read)
        static readonly object gate = new object();
        static readonly Dictionary<string, string> want = new Dictionary<string, string>();       // pressed, not sent yet
        static readonly Dictionary<string, string> sending = new Dictionary<string, string>();    // sent, AC not confirmed yet
        static bool working;
        static DateTime watchedUntil = DateTime.MinValue, readAt = DateTime.MinValue;
        static readonly HashSet<string> Commands = new HashSet<string> { "acpower", "actemp", "acmode", "acfan", "acpreset", "acauto", "acstart" };

        public static void Init(string rootDir) { root = rootDir; }
        public static bool Handles(string c) { return Commands.Contains(c ?? ""); }
        static bool Connected() { return root != null && (File.Exists(Path.Combine(root, @"ac\ac.json")) || File.Exists(Path.Combine(root, @"ac\cloud.bin"))); }

        public static void Start()
        {
            Thread t = new Thread(Loop);
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Name = "AcAuto";
            t.Start();
            Thread w = new Thread(Watch);
            w.IsBackground = true; w.Priority = ThreadPriority.BelowNormal; w.Name = "AcScreen";
            w.Start();
        }

        static void Loop()
        {
            Thread.Sleep(60000);   // never compete with boot
            while (true)
            {
                try { Tick(); } catch (Exception ex) { Log.W("ac auto: " + ex.Message); }
                Thread.Sleep(EveryMs);
            }
        }

        static void Tick()
        {
            if (!Connected()) return;   // not connected yet (local key or Midea Air login)
            string last = RunPy("auto");
            if (last.StartsWith("AUTO ", StringComparison.Ordinal))
            {
                string said = "AC: " + last.Substring(5);
                Log.W("ac auto: " + said);
                KeyMsg.Set("ac-auto", said, "ok");
            }
        }

        // ac.py with these arguments, hidden, BelowNormal, at most 30 s. Returns its last line ("" when it did not answer).
        static string RunPy(string args)
        {
            string py = Path.Combine(root, @"tools\python\python.exe"), script = Path.Combine(root, @"ac\ac.py");
            if (!File.Exists(py) || !File.Exists(script)) return "";
            lock (run)
            {
                ProcessStartInfo psi = new ProcessStartInfo(py, "-I -X utf8 \"" + script + "\" " + args);
                psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
                psi.StandardOutputEncoding = Encoding.UTF8; psi.WorkingDirectory = root;
                using (Process p = Process.Start(psi))
                {
                    try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
                    StringBuilder sb = new StringBuilder();
                    p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                    p.ErrorDataReceived += delegate { };
                    p.BeginOutputReadLine(); p.BeginErrorReadLine();
                    if (!p.WaitForExit(30000)) { try { p.Kill(); } catch { } Log.W("ac: the AC did not answer in 30 s (" + args + ")"); return ""; }
                    p.WaitForExit();
                    readAt = DateTime.UtcNow;
                    string o; lock (sb) o = sb.ToString().Trim();
                    return o.Length == 0 ? "" : o.Substring(o.LastIndexOf('\n') + 1).Trim();
                }
            }
        }

        static Dictionary<string, object> State()
        {
            try { return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(root, @"ac\state.json"))); }
            catch { return new Dictionary<string, object>(); }
        }
        static double Num(Dictionary<string, object> d, string k, double def)
        {
            object o; double v;
            return d.TryGetValue(k, out o) && o != null && double.TryParse(Convert.ToString(o, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : def;
        }
        static bool Bool(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o is bool && (bool)o; }

        // what the AC is (state.json) with what is being sent and what was pressed laid over it, newest last
        static string Cur(Dictionary<string, object> st, string k)
        {
            string v;
            if (want.TryGetValue(k, out v)) return v;
            if (sending.TryGetValue(k, out v)) return v;
            switch (k)
            {
                case "power": return Bool(st, "on") ? "1" : "0";
                case "mode": return ((int)Num(st, "mode", 2)).ToString(CultureInfo.InvariantCulture);
                case "temp": return Num(st, "target_c", 22).ToString("0.0", CultureInfo.InvariantCulture);
                case "fan": return ((int)Num(st, "fan", 102)).ToString(CultureInfo.InvariantCulture);
            }
            return "";
        }

        // A press on the AC screen. Every argument is checked here.
        public static bool Do(string c, string a)
        {
            if (!Connected()) return false;
            a = (a ?? "").Trim().ToLowerInvariant();
            if (c == "acauto" || c == "acstart")
            {
                // Paddock's own settings (ac\settings.json): no AC traffic, done at once
                Dictionary<string, object> s0 = State();
                string args;
                if (c == "acauto") args = "autocool " + (Bool(s0, "auto") ? "off" : "on");
                else
                {
                    if (a != "+1" && a != "-1") return false;
                    args = "startat " + ((int)Num(s0, "on_above_f", 76) + (a == "+1" ? 1 : -1)).ToString(CultureInfo.InvariantCulture);
                }
                new Thread(delegate () { RunPy(args); }) { IsBackground = true }.Start();
                return true;
            }
            lock (gate)
            {
                Dictionary<string, object> st = State();
                switch (c)
                {
                    case "acpower": want["power"] = Cur(st, "power") == "1" ? "0" : "1"; break;
                    case "actemp":
                        {
                            if (a != "+1" && a != "-1") return false;
                            double t = double.Parse(Cur(st, "temp"), CultureInfo.InvariantCulture) + (a == "+1" ? 0.5 : -0.5);   // 0.5 °C = about 1 °F
                            want["temp"] = Math.Max(16.0, Math.Min(30.0, t)).ToString("0.0", CultureInfo.InvariantCulture);
                            if (Cur(st, "power") != "1") want["power"] = "1";
                            break;
                        }
                    case "acmode":
                        {
                            int m = Array.IndexOf(new[] { "", "auto", "cool", "dry", "heat", "fan" }, a);
                            if (m <= 0) return false;
                            want["mode"] = m.ToString(CultureInfo.InvariantCulture); want["power"] = "1";
                            break;
                        }
                    case "acfan":
                        {
                            int f = a == "low" ? 40 : a == "medium" ? 60 : a == "high" ? 80 : a == "auto" ? 102 : 0;
                            if (f == 0) return false;
                            want["fan"] = f.ToString(CultureInfo.InvariantCulture); want["power"] = "1";
                            if (f != 102 && (Cur(st, "mode") == "1" || Cur(st, "mode") == "3")) want["mode"] = "2";   // Midea locks the fan in Auto / Dry
                            break;
                        }
                    case "acpreset":
                        // one press, the whole setting: MAX COOL 64 °F fan high / COMFORT 72 °F fan auto / QUIET 72 °F fan low
                        if (a == "max") { want["power"] = "1"; want["mode"] = "2"; want["temp"] = "18.0"; want["fan"] = "80"; }
                        else if (a == "comfort") { want["power"] = "1"; want["mode"] = "2"; want["temp"] = "22.5"; want["fan"] = "102"; }
                        else if (a == "quiet") { want["power"] = "1"; want["mode"] = "2"; want["temp"] = "22.5"; want["fan"] = "40"; }
                        else return false;
                        break;
                    default: return false;
                }
                if (!working) { working = true; new Thread(Send) { IsBackground = true, Priority = ThreadPriority.BelowNormal }.Start(); }
            }
            return true;
        }

        // sends what was pressed as one `ac.py set`, again while presses keep coming
        static void Send()
        {
            Thread.Sleep(600);   // a quick burst of presses (COOLER x3) goes out as one command
            while (true)
            {
                string args;
                lock (gate)
                {
                    if (want.Count == 0) { working = false; sending.Clear(); return; }
                    sending.Clear();
                    foreach (KeyValuePair<string, string> kv in want) sending[kv.Key] = kv.Value;
                    want.Clear();
                    StringBuilder b = new StringBuilder("set");
                    foreach (KeyValuePair<string, string> kv in sending) b.Append(' ').Append(kv.Key).Append('=').Append(kv.Value);
                    args = b.ToString();
                }
                string last = RunPy(args);
                Log.W("ac screen: " + args + " -> " + (last.Length > 0 ? last : "no answer"));
                lock (gate) { sending.Clear(); }
            }
        }

        // while the AC screen is open: read the AC every 20 s, so a change made with the remote or the app shows too
        static void Watch()
        {
            while (true)
            {
                Thread.Sleep(1000);
                try
                {
                    bool due;
                    lock (gate) due = DateTime.UtcNow < watchedUntil && !working && (DateTime.UtcNow - readAt).TotalSeconds > 20;
                    if (due && Connected()) RunPy("status");
                }
                catch (Exception ex) { Log.W("ac screen: " + ex.Message); }
            }
        }

        // GET /ac (the AC screen and its opener key). ?live=1 = the screen is open, keep it fresh.
        public static string Json(bool live)
        {
            if (live) lock (gate) watchedUntil = DateTime.UtcNow.AddSeconds(5);
            if (!Connected()) return "{\"connected\":false}";
            Dictionary<string, object> st = State();
            string power, mode, temp, fan; bool busy;
            lock (gate) { power = Cur(st, "power"); mode = Cur(st, "mode"); temp = Cur(st, "temp"); fan = Cur(st, "fan"); busy = working || want.Count > 0; }
            double tc = double.Parse(temp, CultureInfo.InvariantCulture);
            double at = Num(st, "at", 0), age = at > 0 ? (DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds - at : -1;
            CultureInfo ci = CultureInfo.InvariantCulture;
            return "{\"connected\":true,\"read\":" + (st.Count > 0 ? "true" : "false") +
                ",\"on\":" + (power == "1" ? "true" : "false") + ",\"mode\":" + mode + ",\"fan\":" + fan +
                ",\"target_c\":" + temp + ",\"target_f\":" + Math.Round(tc * 9 / 5 + 32).ToString(ci) +
                ",\"room_f\":" + (st.ContainsKey("room_f") && st["room_f"] != null ? ((int)Num(st, "room_f", 0)).ToString(ci) : "null") +
                ",\"auto\":" + (Bool(st, "auto") ? "true" : "false") + ",\"paused\":" + (Bool(st, "paused") ? "true" : "false") +
                ",\"on_above_f\":" + ((int)Num(st, "on_above_f", 76)).ToString(ci) + ",\"off_below_f\":" + ((int)Num(st, "off_below_f", 72)).ToString(ci) +
                ",\"busy\":" + (busy ? "true" : "false") + ",\"age\":" + Math.Round(age).ToString(ci) + "}";
        }
    }
}
