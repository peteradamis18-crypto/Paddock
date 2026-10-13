// SOUND deck screen, irdash side (C-39 / C-42): /sound is the state irdeck wrote to <root>\sound\state.json plus how old it is, and the
// whitelisted SOUND key presses (routed here from /api/do) run "irdeck sound ..." one at a time. irdash never touches Windows' audio itself,
// never changes the default device, and nothing here runs unless a key was pressed or the SOUND screen (or its opener key) asks for the state.
// Owned by the deck workstream; irdash.cs only calls Handles / Do / Json.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class Sound
    {
        static readonly HashSet<string> Commands = new HashSet<string> { "sndvol", "sndmute", "sndpreset" };
        public static bool Handles(string c) { return Commands.Contains(c ?? ""); }

        static readonly object gate = new object();
        static readonly Queue<string> q = new Queue<string>();
        static bool working; static DateTime askedAt = DateTime.MinValue;

        // A press on the SOUND screen. Every argument is checked before it reaches irdeck.
        public static bool Do(string c, string a)
        {
            a = (a ?? "").Trim();
            switch (c)
            {
                case "sndvol":      // "sim:+10" = the sim's level up one step (spotter, music, speakers, buttkicker the same)
                    {
                        Match m = Regex.Match(a, "^(sim|spotter|music|speakers|buttkicker):([+-][0-9]{1,2})$");
                        if (!m.Success) return false;
                        Add("sound step " + m.Groups[1].Value + " " + m.Groups[2].Value);
                        return true;
                    }
                case "sndmute":     // one of the five names: flips its mute
                    if (!Regex.IsMatch(a, "^(sim|spotter|music|speakers|buttkicker)$")) return false;
                    Add("sound mute " + a);
                    return true;
                case "sndpreset":   // RACE / CRUISE / NIGHT
                    if (!Regex.IsMatch(a, "^(race|cruise|night)$")) return false;
                    Add("sound preset " + a);
                    return true;
            }
            return false;
        }

        static string StatePath()
        {
            return Watch.IrdeckPath == null ? null : Path.Combine(Path.GetDirectoryName(Watch.IrdeckPath), @"sound\state.json");
        }

        // one irdeck at a time; a status request is not queued twice
        static void Add(string args)
        {
            if (Watch.IrdeckPath == null || !File.Exists(Watch.IrdeckPath)) { Log.W("sound: irdeck.exe not found"); return; }
            lock (gate)
            {
                if (args == "sound status" && q.Contains(args)) return;
                q.Enqueue(args);
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
                lock (gate) { if (q.Count == 0) { working = false; return; } args = q.Dequeue(); }
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo(Watch.IrdeckPath, args);
                    psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(Watch.IrdeckPath);
                    using (Process p = Process.Start(psi))
                        if (!p.WaitForExit(15000)) { try { p.Kill(); } catch { } Log.W("sound: '" + args + "' took too long"); }
                }
                catch (Exception ex) { Log.W("sound: '" + args + "': " + ex.Message); }
            }
        }

        // refresh = ask irdeck for a fresh state when the file is older than ~2 s (the SOUND screen does; the opener key just peeks)
        public static string Json(bool refresh)
        {
            string f = StatePath();
            if (f == null) return "{\"ready\":false,\"busy\":false}";
            bool busy; lock (gate) busy = working;
            try
            {
                double age = File.Exists(f) ? (DateTime.UtcNow - File.GetLastWriteTimeUtc(f)).TotalSeconds : 1e9;
                if (refresh && age > 2.0 && (DateTime.UtcNow - askedAt).TotalSeconds > 1.5) { askedAt = DateTime.UtcNow; Add("sound status"); }
                if (!File.Exists(f)) return "{\"ready\":false,\"busy\":" + (busy ? "true" : "false") + "}";
                string text;
                using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var sr = new StreamReader(fs, System.Text.Encoding.UTF8)) text = sr.ReadToEnd().Trim();
                if (new JavaScriptSerializer().DeserializeObject(text) as Dictionary<string, object> == null) return "{\"ready\":false,\"busy\":false}";   // parsed first: a half-written file can never break the screen
                return text.Substring(0, text.Length - 1) + ",\"ready\":true,\"age\":" + Math.Min(9999, (int)age).ToString(CultureInfo.InvariantCulture) + ",\"busy\":" + (busy ? "true" : "false") + "}";
            }
            catch (Exception ex) { Log.W("sound json: " + ex.Message); return "{\"ready\":false,\"busy\":false}"; }
        }
    }
}
