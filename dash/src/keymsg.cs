// The one-line "what that deck key just did" message on the top screen (dash\www\v2\keymsg.js).
// irdeck (the exe behind every Stream Deck key) sends GET /api/keymsg?key=<deck key id>&text=<plain words>&kind=ok|wait|no after each
// press; the page polls GET /keymsg every 400 ms and shows a new seq for 4 s. Only the last message is kept, in memory only.
// Nothing here touches iRacing, so it is safe while Peter drives. The write route answers this PC only (the phone never writes it).
using System;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDash
{
    static class KeyMsg
    {
        static readonly object gate = new object();
        static long seq;
        static string key = "", text = "", kind = "ok";
        static long atMs;   // unix ms (UTC) of the last message
        static DateTime atUtc = DateTime.MinValue;

        // Returns the sanitized text kept (empty = nothing to show, the route answers 400).
        public static string Set(string k, string t, string kd)
        {
            k = k ?? ""; t = t ?? ""; kd = (kd ?? "").ToLowerInvariant();
            if (!Regex.IsMatch(k, "^[a-z0-9_-]{1,40}$")) k = "";
            if (kd != "ok" && kd != "wait" && kd != "no") kd = "ok";
            // plain words only: control characters and angle brackets out, runs of spaces folded, 80 characters at most
            StringBuilder sb = new StringBuilder(t.Length);
            foreach (char c in t)
            {
                if (c < 32 || c == 127 || c == '<' || c == '>') { sb.Append(' '); continue; }
                sb.Append(c);
            }
            string clean = Regex.Replace(sb.ToString(), "\\s+", " ").Trim();
            if (clean.Length > 80) clean = clean.Substring(0, 80).TrimEnd();
            if (clean.Length == 0) return "";
            lock (gate)
            {
                seq++; key = k; text = clean; kind = kd;
                atUtc = DateTime.UtcNow;
                atMs = (long)(atUtc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            }
            return clean;
        }

        // {seq, key, text, kind, at (unix ms), ageMs}: ageMs lets the page ignore an old message without trusting its own clock
        public static string Current()
        {
            lock (gate)
            {
                long age = seq == 0 ? 0 : (long)(DateTime.UtcNow - atUtc).TotalMilliseconds;
                return "{\"seq\":" + seq.ToString(CultureInfo.InvariantCulture) + ",\"key\":" + IRDash.Json.Str(key) + ",\"text\":" + IRDash.Json.Str(text) +
                       ",\"kind\":" + IRDash.Json.Str(kind) + ",\"at\":" + atMs.ToString(CultureInfo.InvariantCulture) + ",\"ageMs\":" + age.ToString(CultureInfo.InvariantCulture) + "}";
            }
        }
    }
}
