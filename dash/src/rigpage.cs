// The RIG page's two switches (W5-1, docs/rework/PLAN.md 4.5): the start-up sound and the mic for TALK OVER IT. They live nowhere
// else (YouTube privacy and the title template stay on RACES: one place per setting).
//   ini (dash\irdash.ini, through Config.SetKey like every key): startup_sound=on|off (default on), mic=<the mic's name> (default
//   empty = Windows' default recording device)
//   GET /api/settings  -> {"startupSound":true,"mic":"<name or empty>","mics":[{"name":"...","default":bool}]}  (also the state part "settings")
//   /api/do?c=startupsound&a=on|off      /api/do?c=mic&a=next|default|<name>  (an unknown name is refused: 400)
// The mic list is read from the registry (HKLM ...\MMDevices\Audio\Capture, read only): no process and no COM, so it is cheap enough
// for a 1 s state part; it is cached 10 s anyway (a headset plugged in shows within 10 s).
// Who reads them: app/pages/startup.js stays silent when startupSound is false; v2/player.js opens the mic whose label contains the name.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using Microsoft.Win32;

namespace IRDash
{
    static class RigPage
    {
        // test seams: the ini (null = YouTube.IniFile, irdash's own) and the key the devices are read from (null = HKLM's)
        public static string IniPath;
        public static Func<RegistryKey> CaptureRoot;
        const string CapturePath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture";
        const string PDesc = "{a45c254e-df1c-4efd-8020-67d146a850e0},2";        // "Headset", "Microphone"
        const string PFull = "{a45c254e-df1c-4efd-8020-67d146a850e0},14";       // the full friendly name, when Windows stored one
        const string PIface = "{b3f8fa53-0004-438e-9003-51a46e139bfc},6";       // the device it is on: "Arctis 7P+"
        static readonly HashSet<string> Commands = new HashSet<string> { "startupsound", "mic" };
        static readonly object gate = new object();

        public sealed class Mic { public string Name; public bool Default; }

        public static bool Handles(string c) { return Commands.Contains(c ?? ""); }
        static string Ini { get { return IniPath ?? YouTube.IniFile; } }

        public static bool StartupSound { get { return Get("startup_sound", "on").ToLowerInvariant() != "off"; } }
        public static string MicName { get { return Get("mic", ""); } }

        // Windows' own name for a recording device, as Chrome shows it as the track label: "Headset (Arctis 7P+)"
        public static string NameOf(string desc, string iface, string full)
        {
            desc = (desc ?? "").Trim(); iface = (iface ?? "").Trim(); full = (full ?? "").Trim();
            if (desc.Length > 0 && iface.Length > 0) return desc + " (" + iface + ")";
            if (full.Length > 0) return full;
            return desc.Length > 0 ? desc : iface;
        }

        // the active recording devices (DeviceState 1) under one Capture key; never writes. Default: Windows keeps "Level:0" on a device
        // that was made the default; among the active ones the one that has it, else the only one.
        public static List<Mic> ReadMics(RegistryKey root)
        {
            List<Mic> list = new List<Mic>();
            if (root == null) return list;
            HashSet<string> level = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string id in root.GetSubKeyNames())
            {
                try
                {
                    using (RegistryKey k = root.OpenSubKey(id, false))
                    {
                        if (k == null) continue;
                        object st = k.GetValue("DeviceState");
                        if (!(st is int) || (int)st != 1) continue;
                        string name = "";
                        using (RegistryKey p = k.OpenSubKey("Properties", false))
                            if (p != null) name = NameOf(p.GetValue(PDesc) as string, p.GetValue(PIface) as string, p.GetValue(PFull) as string);
                        if (name.Length == 0 || list.Exists(delegate (Mic m) { return string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase); })) continue;
                        list.Add(new Mic { Name = name });
                        if (k.GetValue("Level:0") != null) level.Add(name);
                    }
                }
                catch { }     // one unreadable device never hides the others
            }
            list.Sort(delegate (Mic a, Mic b) { return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); });
            List<Mic> marked = list.FindAll(delegate (Mic m) { return level.Contains(m.Name); });
            if (marked.Count == 1) marked[0].Default = true;
            else if (list.Count == 1) list[0].Default = true;
            return list;
        }

        static List<Mic> cache; static DateTime cacheAt = DateTime.MinValue;
        public static List<Mic> Mics()
        {
            lock (gate)
            {
                if (cache != null && (DateTime.UtcNow - cacheAt).TotalSeconds < 10) return cache;
                List<Mic> m;
                try
                {
                    if (CaptureRoot != null) { using (RegistryKey r = CaptureRoot()) m = ReadMics(r); }
                    else
                        using (RegistryKey hk = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                        using (RegistryKey r = hk.OpenSubKey(CapturePath, false)) m = ReadMics(r);
                }
                catch { m = new List<Mic>(); }
                cache = m; cacheAt = DateTime.UtcNow;
                return m;
            }
        }
        public static void Forget() { lock (gate) cache = null; }

        public static string Json()
        {
            StringBuilder sb = new StringBuilder(256);
            sb.Append("{\"startupSound\":").Append(StartupSound ? "true" : "false").Append(",\"mic\":").Append(Json_.S(MicName)).Append(",\"mics\":[");
            List<Mic> ms = Mics();
            for (int i = 0; i < ms.Count; i++) sb.Append(i > 0 ? "," : "").Append("{\"name\":").Append(Json_.S(ms[i].Name)).Append(",\"default\":").Append(ms[i].Default ? "true" : "false").Append('}');
            return sb.Append("]}").ToString();
        }

        // a press on RIG: the answer is the settings as they are now plus one sentence for the page; 400 for an argument it does not know
        public static string Do(string c, string a, out int code)
        {
            a = (a ?? "").Trim();
            string say = null;
            List<Mic> ms = c == "mic" ? Mics() : null;
            lock (gate)
            {
                if (c == "startupsound")
                {
                    string v = a.ToLowerInvariant();
                    if (v == "on" || v == "off") { Save("startup_sound", v); say = v == "on" ? "Start-up sound on" : "Start-up sound off"; }
                }
                else if (c == "mic")
                {
                    string pick = null;
                    if (a.ToLowerInvariant() == "next")
                    {
                        // the order: Windows' default, then each mic; round again after the last
                        List<string> order = new List<string> { "" }; foreach (Mic m in ms) order.Add(m.Name);
                        int i = order.FindIndex(delegate (string n) { return string.Equals(n, MicName, StringComparison.OrdinalIgnoreCase); });
                        pick = order[(Math.Max(0, i) + 1) % order.Count];
                    }
                    else if (a.ToLowerInvariant() == "default") pick = "";
                    else foreach (Mic m in ms) if (string.Equals(m.Name, a, StringComparison.OrdinalIgnoreCase)) pick = m.Name;
                    if (pick != null) { Save("mic", pick); say = pick.Length == 0 ? "Mic: Windows' default" : "Mic: " + pick; }
                }
            }
            if (say == null) { code = 400; return "{\"ok\":false,\"say\":" + Json_.S(c == "mic" ? "That mic is not plugged in" : "Not done") + "}"; }
            Log.W("rig page: " + say);
            try { StateBuilder.Changed("settings"); } catch { }
            code = 200;
            string j = Json();
            return "{\"ok\":true,\"say\":" + Json_.S(say) + "," + j.Substring(1);
        }

        // Config.SetKey, read back: another reader of irdash.ini (YouTube, Gallery) can hold the file for a moment and SetKey only logs that
        static void Save(string key, string val)
        {
            for (int i = 0; i < 5; i++)
            {
                Config.SetKey(Ini, key, val);
                if (Get(key, "\u0001") == val) return;
                System.Threading.Thread.Sleep(40);
            }
            Log.W("rig page: could not save " + key);
        }

        static string Get(string key, string def)
        {
            try
            {
                string f = Ini;
                if (string.IsNullOrEmpty(f) || !File.Exists(f)) return def;
                // shared read: this runs every second (the "settings" part) and must never block Config.SetKey writing the same file
                string text;
                using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (StreamReader r = new StreamReader(fs)) text = r.ReadToEnd();
                foreach (string raw in text.Split('\n'))
                {
                    string t = raw.Trim();
                    if (t.StartsWith(";") || t.StartsWith("#")) continue;
                    int e = t.IndexOf('=');
                    if (e > 0 && t.Substring(0, e).Trim().Equals(key, StringComparison.OrdinalIgnoreCase)) return t.Substring(e + 1).Trim();
                }
            }
            catch { }
            return def;
        }
    }
}
