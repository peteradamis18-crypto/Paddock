// The nightly check's pure rules (W5-4): when it is time, and what RIG's "nightly" part says. No irdash types in here, so
// tests\nightly-test.ps1 compiles this one file with a harness (fake clocks, a fixture file).
//   tests\nightly.txt   one line per night, newest last: yyyy-MM-ddTHH:mm <TAB> 1|0 <TAB> text      (written by tests\nightly.ps1)
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace IRDash
{
    static class NightlyRules
    {
        // 03:00 local, once a day. Also at the first tick after 03:00 when irdash was down at 03:00 (a restart at 03:30 still does it),
        // but never from 06:00 on. lastDay = the yyyyMMdd of the last night that has a line or was started ("" = none).
        public static bool IsTime(DateTime now, string lastDay, bool on)
        {
            if (!on) return false;
            if (lastDay == now.ToString("yyyyMMdd", CultureInfo.InvariantCulture)) return false;
            return now.Hour >= 3 && now.Hour < 6;
        }

        // the window closed (06:00 or later) without a run today
        public static bool WindowPassed(DateTime now, string lastDay, bool on)
        {
            return on && now.Hour >= 6 && now.Hour < 9 && lastDay != now.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        }

        // "yyyyMMdd" of the last line in the file, or ""
        public static string LastDay(string file)
        {
            string[] f = LastFields(file);
            return f == null ? "" : f[0].Substring(0, 10).Replace("-", "");
        }

        static string[] LastFields(string file)
        {
            try
            {
                if (file == null || !File.Exists(file)) return null;
                string last = null;
                foreach (string l in File.ReadAllLines(file, Encoding.UTF8)) if (l.Trim().Length > 0) last = l;
                if (last == null) return null;
                string[] f = last.Split('\t');
                if (f.Length < 3 || f[0].Length < 10 || f[2].Trim().Length == 0) return null;
                return f;
            }
            catch { return null; }
        }

        // W5-1's contract: {"at":"2026-11-15T03:00","text":"Rig check 03:00: all good","ok":true}; no file or no usable line = null
        public static string PartJson(string file)
        {
            string[] f = LastFields(file);
            if (f == null) return "null";
            return "{\"at\":" + Str(f[0].Trim()) + ",\"text\":" + Str(f[2].Trim()) + ",\"ok\":" + (f[1].Trim() == "1" ? "true" : "false") + "}";
        }

        // one file line (the script writes the same form)
        public static string Row(DateTime at, bool ok, string text)
        {
            return at.ToString("yyyy-MM-ddTHH:mm", CultureInfo.InvariantCulture) + "\t" + (ok ? "1" : "0") + "\t" + text.Replace("\t", " ").Replace("\r", " ").Replace("\n", " ");
        }

        // add a line, keep the newest 60
        public static void Append(string file, string row)
        {
            List<string> all = new List<string>();
            if (File.Exists(file)) foreach (string l in File.ReadAllLines(file, Encoding.UTF8)) if (l.Trim().Length > 0) all.Add(l);
            all.Add(row);
            if (all.Count > 60) all.RemoveRange(0, all.Count - 60);
            File.WriteAllLines(file, all.ToArray(), new UTF8Encoding(false));
        }

        static string Str(string s)
        {
            StringBuilder b = new StringBuilder("\"");
            foreach (char c in s)
            {
                if (c == '"') b.Append("\\\""); else if (c == '\\') b.Append("\\\\"); else if (c < 32) b.Append(' ');
                else b.Append(c);
            }
            return b.Append('"').ToString();
        }
    }
}
