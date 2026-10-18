// coverage.cs - where to watch in the U.S.: a curated, dated list (dash\coverage.json) and the one action that opens it.
//   GET /watch/coverage                      -> {"rows":[...], "asOf": newest verifiedAt}  (HOME matches rows to events)
//   GET /api/watch/open?series=F1&session=Race -> opens THAT series' provider page in the default browser
// Rules: a URL is only ever taken from coverage.json (never from the request); nothing opens while the sim runs (the
// browser would land on the race screens); unknown coverage stays unknown, never a guess. C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class Coverage
    {
        static readonly object gate = new object();
        static string file = ""; static DateTime stamp = DateTime.MinValue;
        static List<Dictionary<string, object>> rows = new List<Dictionary<string, object>>();
        static string json = "{\"rows\":[],\"asOf\":\"\"}";

        public static void Init(string rootDir) { file = Path.Combine(rootDir, @"dash\coverage.json"); }

        static void Load()
        {
            try
            {
                if (file.Length == 0 || !File.Exists(file)) { rows = new List<Dictionary<string, object>>(); json = "{\"rows\":[],\"asOf\":\"\"}"; return; }
                DateTime w = File.GetLastWriteTimeUtc(file);
                if (w == stamp) return;
                object o = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(file, Encoding.UTF8));
                List<Dictionary<string, object>> list = new List<Dictionary<string, object>>();
                object[] arr = o as object[];
                if (arr != null) foreach (object x in arr) { Dictionary<string, object> d = x as Dictionary<string, object>; if (d != null && S(d, "series").Length > 0 && Regex.IsMatch(S(d, "url"), "^https://")) list.Add(d); }
                string asOf = "";
                StringBuilder sb = new StringBuilder("{\"rows\":[");
                for (int i = 0; i < list.Count; i++)
                {
                    Dictionary<string, object> d = list[i]; if (i > 0) sb.Append(',');
                    string v = S(d, "verifiedAt"); if (string.CompareOrdinal(v, asOf) > 0) asOf = v;
                    sb.Append("{\"series\":").Append(Json_.S(S(d, "series"))).Append(",\"scope\":").Append(Json_.S(S(d, "scope")))
                      .Append(",\"sessions\":").Append(SessionsJson(d)).Append(",\"service\":").Append(Json_.S(S(d, "service")))
                      .Append(",\"url\":").Append(Json_.S(S(d, "url"))).Append(",\"subscription\":").Append(BoolOrNull(d, "subscription"))
                      .Append(",\"confidence\":").Append(Json_.S(S(d, "confidence"))).Append(",\"verifiedAt\":").Append(Json_.S(v)).Append('}');
                }
                sb.Append("],\"asOf\":").Append(Json_.S(asOf)).Append('}');
                rows = list; json = sb.ToString(); stamp = w;
            }
            catch (Exception ex) { Log.W("coverage: could not read dash\\coverage.json (" + ex.Message + ")"); }
        }

        static string S(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, System.Globalization.CultureInfo.InvariantCulture) : ""; }
        static string BoolOrNull(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o is bool ? ((bool)o ? "true" : "false") : "null"; }
        static string SessionsJson(Dictionary<string, object> d)
        {
            object o; object[] a = d.TryGetValue("sessions", out o) ? o as object[] : null;
            if (a == null) return "[]";
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < a.Length; i++) { if (i > 0) sb.Append(','); sb.Append(Json_.S(Convert.ToString(a[i]).ToLowerInvariant())); }
            return sb.Append(']').ToString();
        }

        // the kind of a session as the coverage rows name it
        public static string Kind(string session)
        {
            string s = (session ?? "").ToLowerInvariant();
            if (Regex.IsMatch(s, "qualif|hyperpole|shootout")) return "qualifying";
            if (s.Contains("sprint")) return "sprint";
            if (Regex.IsMatch(s, "practice|\\bfp\\d|warm")) return "practice";
            if (s.Contains("race") || Regex.IsMatch(s, "\\bhours?\\b")) return "race";
            return "other";
        }

        // the row that covers this series and session: a session-scoped row that names the kind wins over a series row
        static Dictionary<string, object> Find(string series, string session)
        {
            string kind = Kind(session);
            Dictionary<string, object> whole = null;
            foreach (Dictionary<string, object> d in rows)
            {
                if (!string.Equals(S(d, "series"), series, StringComparison.OrdinalIgnoreCase)) continue;
                if (S(d, "scope") == "session")
                {
                    object o; object[] a = d.TryGetValue("sessions", out o) ? o as object[] : null;
                    if (a != null) foreach (object k in a) if (string.Equals(Convert.ToString(k), kind, StringComparison.OrdinalIgnoreCase) || (kind == "sprint" && string.Equals(Convert.ToString(k), "race", StringComparison.OrdinalIgnoreCase))) return d;
                }
                else if (whole == null) whole = d;
            }
            return whole;
        }

        public static string Route(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            lock (gate)
            {
                Load();
                if (path == "/watch/coverage") return json;
                if (path != "/api/watch/open") { code = 404; return "{\"error\":\"not found\"}"; }
                string series, session; q.TryGetValue("series", out series); q.TryGetValue("session", out session);
                Dictionary<string, object> d = Find(series ?? "", session ?? "");
                if (d == null) { code = 404; return "{\"ok\":false,\"error\":\"no coverage known for this series\"}"; }
                if (Program.IsDriving || Process.GetProcessesByName("iRacingSim64DX11").Length > 0) { code = 409; return "{\"ok\":false,\"error\":\"not while the sim runs\"}"; }
                string url = S(d, "url");
                try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
                catch (Exception ex) { Log.W("coverage: could not open " + url + " (" + ex.Message + ")"); code = 500; return "{\"ok\":false,\"error\":\"could not open the browser\"}"; }
                Log.W("coverage: opened " + S(d, "service") + " for " + series + " " + session);
                return "{\"ok\":true,\"service\":" + Json_.S(S(d, "service")) + "}";
            }
        }
    }
}
