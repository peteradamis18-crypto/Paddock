// What the Stream Deck's ANALYSIS screen needs to know about the workbench page (C-42): irdash only relays. The page (workbench.js)
// reports its own state with its 300 ms poll of /workbench/cmd (page, playing, speed, tile, lap ...); the deck reads it back at
// /workbench/state, so its keys show the REAL state and know whether a lap is open at all. KEEP and OPEN IN COSWORTH act on the lap the
// page says it shows (the Vault's own /vault/edit and /vault/open routes). Every value is checked against a pattern before it is kept.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDash
{
    static class DeckFeed
    {
        static readonly HashSet<string> Commands = new HashSet<string> { "wbkeep", "wbcosworth" };
        public static bool Handles(string c) { return Commands.Contains(c ?? ""); }

        static readonly object gate = new object();
        static readonly Dictionary<string, string> wb = new Dictionary<string, string>();
        static DateTime wbAt = DateTime.MinValue;

        // field -> allowed text. Numbers and flags are written into the JSON as they are, so their patterns are strict.
        static readonly string[][] Fields = {
            new[] { "pg", "^[a-z0-9-]{1,24}$" }, new[] { "pgs", "^[a-z0-9,-]{1,200}$" }, new[] { "pl", "^[01]$" }, new[] { "sp", "^[0-9.]{1,4}$" },
            new[] { "tl", "^[01]$" }, new[] { "ax", "^(dist|time)$" }, new[] { "mc", "^[A-Za-z0-9_]{1,24}$" }, new[] { "om", "^[01]$" }, new[] { "of", "^-?[0-9]{1,5}$" },
            new[] { "z", "^[01]$" }, new[] { "id", "^[A-Za-z0-9._ -]{1,140}$" }, new[] { "lap", "^[0-9]{1,3}$" }, new[] { "ref", "^[A-Za-z0-9._: -]{0,140}$" },
            new[] { "nl", "^[0-9]{1,3}$" }, new[] { "ne", "^[0-9]{1,4}$" }, new[] { "nc", "^[0-9]{1,3}$" }, new[] { "lt", "^[0-9.]{1,10}$" }, new[] { "rt", "^[0-9.]{0,10}$" },
            new[] { "rl", "^[0-9]{0,3}$" }, new[] { "car", "^[^\\x00-\\x1f\"\\\\<>]{0,60}$" }, new[] { "trk", "^[^\\x00-\\x1f\"\\\\<>]{0,60}$" } };

        // the page's report (the query of /workbench/cmd): keep what passes its pattern
        public static void Workbench(Dictionary<string, string> q)
        {
            lock (gate)
            {
                if (!q.ContainsKey("pg")) return;   // not a report from the workbench page
                wb.Clear();
                foreach (string[] f in Fields) { string v; if (q.TryGetValue(f[0], out v) && Regex.IsMatch(v ?? "", f[1])) wb[f[0]] = v; }
                wbAt = DateTime.UtcNow;
            }
        }

        static string G(string k, string def) { string v; return wb.TryGetValue(k, out v) ? v : def; }
        static string Num(string k, string def) { string v = G(k, def); return Regex.IsMatch(v, "^-?[0-9]+(\\.[0-9]+)?$") ? v : def; }
        static string B(string k) { return G(k, "0") == "1" ? "true" : "false"; }

        public static string WorkbenchJson()
        {
            lock (gate)
            {
                double age = (DateTime.UtcNow - wbAt).TotalSeconds;
                bool open = wb.Count > 0 && age < 4.0;       // the page reports 3 times a second; a lap change reloads it, which takes about a second
                StringBuilder sb = new StringBuilder("{\"open\":" + (open ? "true" : "false") + ",\"age\":" + (wbAt == DateTime.MinValue ? "9999" : Math.Min(9999, (int)age).ToString(CultureInfo.InvariantCulture)));
                sb.Append(",\"driving\":" + (Program.IsDriving ? "true" : "false"));
                if (open)
                {
                    List<string> pages = new List<string>();
                    foreach (string p in G("pgs", "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) pages.Add(Json_.S(p));
                    sb.Append(",\"page\":" + Json_.S(G("pg", "")) + ",\"pages\":[" + string.Join(",", pages.ToArray()) + "]");
                    sb.Append(",\"playing\":" + B("pl") + ",\"speed\":" + Num("sp", "1") + ",\"tile\":" + B("tl") + ",\"axis\":" + Json_.S(G("ax", "dist")) + ",\"mapColour\":" + Json_.S(G("mc", "gap")));
                    sb.Append(",\"offsetMode\":" + B("om") + ",\"offset\":" + Num("of", "0") + ",\"zoomed\":" + B("z"));
                    sb.Append(",\"id\":" + Json_.S(G("id", "")) + ",\"lap\":" + Num("lap", "0") + ",\"ref\":" + Json_.S(G("ref", "pb")) + ",\"laps\":" + Num("nl", "0") + ",\"events\":" + Num("ne", "0") + ",\"corners\":" + Num("nc", "0"));
                    sb.Append(",\"lapTime\":" + Num("lt", "0") + ",\"refTime\":" + (G("rt", "").Length > 0 ? Num("rt", "0") : "null") + ",\"refLap\":" + (G("rl", "").Length > 0 ? Num("rl", "0") : "null"));
                    sb.Append(",\"car\":" + Json_.S(G("car", "")) + ",\"track\":" + Json_.S(G("trk", "")));
                }
                return sb.Append('}').ToString();
            }
        }

        // KEEP (a = 1 keep / 0 let go) and OPEN IN COSWORTH on the lap the workbench shows. The Vault does the work; never while he is driving.
        public static bool Do(string c, string a)
        {
            string id;
            lock (gate) { id = wb.Count > 0 && (DateTime.UtcNow - wbAt).TotalSeconds < 4.0 ? G("id", "") : ""; }
            if (Program.IsDriving || !Regex.IsMatch(id, "^[a-z0-9-]{3,40}$")) return false;      // a plain .ibt file name is not a Vault moment
            string path;
            if (c == "wbkeep") { if ((a ?? "") != "1" && (a ?? "") != "0") return false; path = "/vault/edit?id=" + id + "&star=" + a; }
            else if (c == "wbcosworth") path = "/vault/open?id=" + id + "&how=cosworth";
            else return false;
            try
            {
                string baseUrl = Environment.GetEnvironmentVariable("PADDOCK_DECKFEED_BASE");   // tests\deck-screens-test.ps1 points this at a pretend local server
                using (WebClient wc = new WebClient())
                {
                    wc.Proxy = null;
                    wc.DownloadString((string.IsNullOrEmpty(baseUrl) ? "http://localhost:8199" : baseUrl) + path);
                }
                return true;
            }
            catch (Exception ex) { Log.W("deckfeed: " + c + ": " + ex.Message); return false; }
        }
    }
}
