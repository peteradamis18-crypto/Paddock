// Real-world race calendars for HOME (H-05): IMSA, WEC, F1, GTWC session times from published sources.
// No live HTTP unless AllowLive (Peter's yes). Never while Sdk.RealBusy(). Cache data\official\realworld.json.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    public sealed class RwEvent
    {
        public string Series = "", Event = "", Track = "", Session = "", Source = "", AsOf = "", LocalStart = "", EventDate = "";
        public List<string> Classes = new List<string>();
        public bool Tbc;
        public DateTime Utc;
    }

    public sealed class RwRss
    {
        public string Title = "", Summary = "", Url = "", PubDate = "";
    }

    static class RealWorld
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly object gate = new object();
        static string dir = "";
        static string cacheJson = "{\"asOf\":\"\",\"fresh\":false,\"events\":[]}";
        static DateTime cacheAsOf = DateTime.MinValue;
        static List<RwEvent> events = new List<RwEvent>();
        static int fetchLock;

        public static Func<string, byte[]> TestTransport;
        public static Func<string> TestBusy;
        public static DateTime TestNow;
        public static int TransportCalls;
        public static bool AllowLive;
        public static bool PreviewLines;
        public static Func<string, string, string> TestPreviewHttp;
        public static int PreviewCalls;
        public static string PreviewModel = "deepseek/deepseek-v4.1-flash";
        static readonly Dictionary<string, string> previewCache = new Dictionary<string, string>();

        static DateTime NowUtc()
        {
            if (TestNow.Kind == DateTimeKind.Utc && TestNow != DateTime.MinValue) return TestNow;
            if (TestNow != DateTime.MinValue) return DateTime.SpecifyKind(TestNow, DateTimeKind.Utc);
            return DateTime.UtcNow;
        }

        static string BusyWhy()
        {
            if (TestBusy != null) return TestBusy();
            try
            {
                System.Reflection.MethodInfo m = typeof(Sdk).GetMethod("RealBusy", Type.EmptyTypes);
                if (m != null) { object r = m.Invoke(null, null); if (r != null) return Convert.ToString(r, Inv); }
            }
            catch { }
            return null;
        }

        static void W(string m)
        {
            try { Log.W("realworld: " + m); } catch { }
        }

        static string Js(string s)
        {
            s = s ?? "";
            StringBuilder sb = new StringBuilder("\"");
            foreach (char c in s)
            {
                if (c == '"') sb.Append("\\\"");
                else if (c == '\\') sb.Append("\\\\");
                else if (c < 32) sb.Append(' ');
                else sb.Append(c);
            }
            return sb.Append('"').ToString();
        }

        public static void Init(string dataDir)
        {
            dir = dataDir ?? "";
            AllowLive = true;
            try { Directory.CreateDirectory(dir); } catch { }
            LoadCache();
            Thread t = new Thread(Loop);
            t.IsBackground = true;
            t.Priority = ThreadPriority.BelowNormal;
            t.Start();
        }

        static void Loop()
        {
            Thread.Sleep(30000);
            while (true)
            {
                int wait = 21600000;
                try
                {
                    if (AllowLive)
                    {
                        if (BusyWhy() == null) TryRefresh();
                        else wait = 60000;
                    }
                }
                catch (Exception ex) { W(ex.Message); }
                Thread.Sleep(wait);
            }
        }

        public static string Route(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (path != "/realworld") return null;
            lock (gate)
            {
                LoadCache();
                return cacheJson;
            }
        }

        static string CachePath() { return Path.Combine(dir, "realworld.json"); }

        public static void LoadCache()
        {
            string f = CachePath();
            if (string.IsNullOrEmpty(dir) || !File.Exists(f)) return;
            try
            {
                string text = File.ReadAllText(f, Encoding.UTF8);
                List<RwEvent> list = EventsFromCacheJson(text);
                if (list != null)
                {
                    events = list;
                    cacheJson = text;
                    Match am = Regex.Match(text, "\"asOf\"\\s*:\\s*\"([^\"]*)\"");
                    DateTime a;
                    if (am.Success && DateTime.TryParse(am.Groups[1].Value, Inv, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out a)) cacheAsOf = a;
                }
            }
            catch (Exception ex) { W("cache: " + ex.Message); }
        }

        public static void SaveCache(List<RwEvent> list, DateTime asOf)
        {
            events = list;
            cacheAsOf = asOf;
            cacheJson = EventsJson(list, asOf, (NowUtc() - asOf).TotalHours < 6);
            if (string.IsNullOrEmpty(dir)) return;
            try
            {
                Directory.CreateDirectory(dir);
                string f = CachePath(), tmp = f + ".tmp";
                File.WriteAllText(tmp, cacheJson, new UTF8Encoding(false));
                try { if (File.Exists(f)) File.Replace(tmp, f, null); else File.Move(tmp, f); }
                catch { try { File.Copy(tmp, f, true); File.Delete(tmp); } catch { } }
            }
            catch (Exception ex) { W("save: " + ex.Message); }
        }

        public static string EventsJson(List<RwEvent> list, DateTime asOf, bool fresh)
        {
            StringBuilder sb = new StringBuilder("{\"asOf\":" + Js(asOf == DateTime.MinValue ? "" : asOf.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", Inv)) + ",\"fresh\":" + (fresh ? "true" : "false") + ",\"events\":[");
            for (int i = 0; i < list.Count; i++)
            {
                RwEvent e = list[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"series\":").Append(Js(e.Series)).Append(",\"event\":").Append(Js(e.Event)).Append(",\"track\":").Append(Js(e.Track));
                sb.Append(",\"session\":").Append(Js(e.Session)).Append(",\"classes\":[");
                for (int c = 0; c < e.Classes.Count; c++) { if (c > 0) sb.Append(','); sb.Append(Js(e.Classes[c])); }
                sb.Append("],\"localStart\":").Append(e.LocalStart.Length == 0 ? "null" : Js(e.LocalStart)).Append(",\"eventDate\":").Append(Js(e.EventDate));
                sb.Append(",\"tbc\":").Append(e.Tbc ? "true" : "false").Append(",\"source\":").Append(Js(e.Source)).Append(",\"asOf\":").Append(Js(e.AsOf));
                if (!string.IsNullOrEmpty(e.Event) && previewCache.ContainsKey(PreviewKey(e, asOf))) { }
                AppendPreview(sb, e, asOf);
                sb.Append("}");
            }
            return sb.Append("]}").ToString();
        }

        static void AppendPreview(StringBuilder sb, RwEvent e, DateTime weekHint)
        {
            string k = PreviewKey(e, weekHint);
            string blob;
            if (!previewCache.TryGetValue(k, out blob) || blob.Length == 0) return;
            string[] p = blob.Split('\n');
            if (p.Length < 3) return;
            sb.Append(",\"preview\":").Append(Js(p[0])).Append(",\"previewSource\":").Append(Js(p[1])).Append(",\"previewDate\":").Append(Js(p[2]));
        }

        static List<RwEvent> EventsFromCacheJson(string text)
        {
            JavaScriptSerializer ser = new JavaScriptSerializer(); ser.MaxJsonLength = int.MaxValue;
            Dictionary<string, object> root = ser.DeserializeObject(text) as Dictionary<string, object>;
            if (root == null) return null;
            List<RwEvent> list = new List<RwEvent>();
            object ev;
            if (!root.TryGetValue("events", out ev) || ev == null) return list;
            foreach (object o in (IList)ev)
            {
                Dictionary<string, object> d = o as Dictionary<string, object>;
                if (d == null) continue;
                RwEvent e = new RwEvent();
                e.Series = Str(d, "series"); e.Event = Str(d, "event"); e.Track = Str(d, "track"); e.Session = Str(d, "session");
                e.Source = Str(d, "source"); e.AsOf = Str(d, "asOf"); e.LocalStart = Str(d, "localStart"); e.EventDate = Str(d, "eventDate");
                object tbc; if (d.TryGetValue("tbc", out tbc) && tbc != null) e.Tbc = Convert.ToBoolean(tbc);
                object cls; if (d.TryGetValue("classes", out cls) && cls is IList)
                    foreach (object c in (IList)cls) e.Classes.Add(Convert.ToString(c, Inv));
                DateTimeOffset dto;
                if (!e.Tbc && e.LocalStart.Length > 0 && DateTimeOffset.TryParse(e.LocalStart, Inv, DateTimeStyles.None, out dto)) e.Utc = dto.UtcDateTime;
                list.Add(e);
            }
            return list;
        }

        static string Str(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null && !(o is DBNull) ? Convert.ToString(o, Inv) : ""; }

        public static List<RwEvent> ParseF1(string json, string source, string asOf)
        {
            List<RwEvent> list = new List<RwEvent>();
            if (string.IsNullOrEmpty(json)) return list;
            try
            {
                JavaScriptSerializer ser = new JavaScriptSerializer(); ser.MaxJsonLength = int.MaxValue;
                Dictionary<string, object> root = ser.DeserializeObject(json) as Dictionary<string, object>;
                Dictionary<string, object> mr = root != null && root.ContainsKey("MRData") ? root["MRData"] as Dictionary<string, object> : null;
                Dictionary<string, object> table = mr != null && mr.ContainsKey("RaceTable") ? mr["RaceTable"] as Dictionary<string, object> : null;
                IList races = table != null && table.ContainsKey("Races") ? table["Races"] as IList : null;
                string[] fields = { "FirstPractice", "SecondPractice", "ThirdPractice", "Sprint", "Qualifying", "Race" };
                string[] labels = { "First Practice", "Second Practice", "Third Practice", "Sprint", "Qualifying", "Race" };
                if (races != null) foreach (object item in races)
                {
                    Dictionary<string, object> race = item as Dictionary<string, object>; if (race == null) continue;
                    string eventName = Str(race, "raceName");
                    Dictionary<string, object> circuit = race.ContainsKey("Circuit") ? race["Circuit"] as Dictionary<string, object> : null;
                    string track = circuit != null ? Str(circuit, "circuitName") : "";
                    for (int i = 0; i < fields.Length; i++)
                    {
                        Dictionary<string, object> session = null;
                        if (fields[i] == "Race") session = race;
                        else if (race.ContainsKey(fields[i])) session = race[fields[i]] as Dictionary<string, object>;
                        if (session == null) continue;
                        RwEvent e = new RwEvent(); e.Series = "F1"; e.Event = eventName; e.Track = track; e.Session = labels[i]; e.Source = source; e.AsOf = asOf;
                        string date = Str(session, "date"), time = Str(session, "time");
                        FillWhen(e, date.Length > 0 ? date + (time.Length > 0 ? "T" + time : "") : "");
                        list.Add(e);
                    }
                }
            }
            catch { }
            return list;
        }

        public static List<RwEvent> ParseOpenF1(string json, string source, string asOf)
        {
            List<RwEvent> list = new List<RwEvent>();
            JavaScriptSerializer js = new JavaScriptSerializer();
            object root = js.DeserializeObject(json);
            object[] rows = root as object[];
            if (rows == null) return list;
            foreach (object item in rows)
            {
                Dictionary<string, object> row = item as Dictionary<string, object>;
                if (row == null) continue;
                string name = Str(row, "meeting_name"), session = Str(row, "session_name"), date = Str(row, "date_start");
                if (name.Length == 0 || session.Length == 0) continue;
                RwEvent e = new RwEvent();
                e.Series = "F1"; e.Event = name; e.Track = Str(row, "circuit_short_name");
                if (e.Track.Length == 0) e.Track = Str(row, "location");
                e.Session = session; e.Source = source; e.AsOf = asOf;
                FillWhen(e, date);
                list.Add(e);
            }
            return list;
        }

        static void WalkF1(object o, List<RwEvent> list, string source, string asOf)
        {
            Dictionary<string, object> d = o as Dictionary<string, object>;
            if (d != null)
            {
                if (d.ContainsKey("raceName") || d.ContainsKey("session_name"))
                {
                    RwEvent e = new RwEvent();
                    e.Series = "F1";
                    e.Event = Str(d, "raceName");
                    if (e.Event.Length == 0) e.Event = Str(d, "meeting_name");
                    e.Session = Str(d, "session_name");
                    if (e.Session.Length == 0) e.Session = "Race";
                    Dictionary<string, object> cir = null;
                    object co; if (d.TryGetValue("Circuit", out co)) cir = co as Dictionary<string, object>;
                    e.Track = cir != null ? Str(cir, "circuitName") : Str(d, "circuit_short_name");
                    if (e.Track.Length == 0) e.Track = Str(d, "location");
                    string date = Str(d, "date"), time = Str(d, "time"), start = Str(d, "date_start");
                    FillWhen(e, start.Length > 0 ? start : (date.Length > 0 ? date + (time.Length > 0 ? "T" + time : "") : ""));
                    e.Source = source; e.AsOf = asOf;
                    if (e.Event.Length > 0 || e.Track.Length > 0) list.Add(e);
                    return;
                }
                foreach (KeyValuePair<string, object> kv in d) WalkF1(kv.Value, list, source, asOf);
                return;
            }
            IList arr = o as IList;
            if (arr != null) foreach (object x in arr) WalkF1(x, list, source, asOf);
        }

        static void FillWhen(RwEvent e, string raw)
        {
            raw = (raw ?? "").Trim();
            if (raw.Length == 0) { e.Tbc = true; e.LocalStart = ""; e.Utc = DateTime.MaxValue; return; }
            if (Regex.IsMatch(raw, @"^\d{4}-\d{2}-\d{2}$")) { e.Tbc = true; e.LocalStart = ""; DateTime day; if (DateTime.TryParseExact(raw, "yyyy-MM-dd", Inv, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out day)) e.Utc = day; else e.Utc = DateTime.MaxValue; return; }
            DateTimeOffset dto;
            if (!DateTimeOffset.TryParse(raw, Inv, DateTimeStyles.None, out dto)) { e.Tbc = true; e.LocalStart = ""; e.Utc = DateTime.MaxValue; return; }
            e.Tbc = false;
            e.Utc = dto.UtcDateTime;
            e.LocalStart = new DateTimeOffset(e.Utc).ToOffset(TimeZoneInfo.Local.GetUtcOffset(e.Utc)).ToString("yyyy-MM-dd'T'HH:mm:sszzz", Inv);
        }

        public static List<RwEvent> ParseImsa(string html, string source, string asOf) { return ParseTable(html, "IMSA", source, asOf); }
        public static List<RwEvent> ParseWec(string html, string source, string asOf) { return ParseTable(html, "WEC", source, asOf); }
        public static List<RwEvent> ParseGtwc(string html, string source, string asOf) { return ParseTable(html, "GTWC", source, asOf); }

        // SRO uses distinct calendar sites, while older cache rows used the shared GTWC label.
        public static List<RwEvent> ParseGtwcEurope(string html, string source, string asOf) { return ParseSro(html, "GTWC Europe", source, asOf); }
        public static List<RwEvent> ParseGtwcAmerica(string html, string source, string asOf) { return ParseSro(html, "GTWC America", source, asOf); }

        // Public RaceTagger iCalendar exports carry one timed row per published session.
        public static List<RwEvent> ParseIcs(string body, string series, string source, string asOf)
        {
            List<RwEvent> list = new List<RwEvent>();
            if (string.IsNullOrEmpty(body)) return list;
            string unfolded = Regex.Replace(body.Replace("\r\n", "\n").Replace("\r", "\n"), "\n[ \\t]", "");
            foreach (Match vm in Regex.Matches(unfolded, "(?is)BEGIN:VEVENT\\s*(.*?)\\s*END:VEVENT"))
            {
                string summary = "", start = "";
                foreach (string line in vm.Groups[1].Value.Split('\n'))
                {
                    int colon = line.IndexOf(':');
                    if (colon < 0) continue;
                    string key = line.Substring(0, colon);
                    string value = line.Substring(colon + 1).Trim();
                    if (key.StartsWith("SUMMARY", StringComparison.OrdinalIgnoreCase)) summary = IcsText(value);
                    else if (key.StartsWith("DTSTART", StringComparison.OrdinalIgnoreCase))
                    {
                        Match tz = Regex.Match(key, "(?i)(?:^|;)TZID=([^;]+)");
                        start = value;
                        if (tz.Success) start = "TZID=" + tz.Groups[1].Value + ";" + value;
                    }
                }
                if (summary.Length == 0 || start.Length == 0) continue;
                string session, eventName;
                int split = summary.IndexOf(" - ", StringComparison.Ordinal);
                if (split > 0)
                {
                    string first = summary.Substring(0, split).Trim();
                    eventName = summary.Substring(split + 3).Trim();
                    session = string.Equals(first, eventName, StringComparison.OrdinalIgnoreCase) || Regex.IsMatch(first, "(?i)\\b(hours?|hrs?)\\b") ? "Race" : first;
                }
                else { session = "Race"; eventName = summary; }
                RwEvent e = new RwEvent();
                e.Series = series; e.Event = eventName; e.Session = session; e.Source = source; e.AsOf = asOf;
                FillIcsWhen(e, start);
                if (!e.Tbc) list.Add(e);
            }
            return list;
        }

        static string IcsText(string value)
        {
            return (value ?? "").Replace("\\n", " ").Replace("\\N", " ").Replace("\\,", ",").Replace("\\;", ";").Replace("\\\\", "\\").Trim();
        }

        static void FillIcsWhen(RwEvent e, string raw)
        {
            string tzid = "";
            if (raw.StartsWith("TZID=", StringComparison.OrdinalIgnoreCase))
            {
                int semi = raw.IndexOf(';');
                if (semi < 0) { e.Tbc = true; return; }
                tzid = raw.Substring(5, semi - 5); raw = raw.Substring(semi + 1);
            }
            DateTime parsed;
            string fmt = raw.Length == 8 ? "yyyyMMdd" : (raw.EndsWith("Z", StringComparison.OrdinalIgnoreCase) ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss");
            if (!DateTime.TryParseExact(raw, fmt, Inv, DateTimeStyles.None, out parsed)) { e.Tbc = true; return; }
            if (raw.EndsWith("Z", StringComparison.OrdinalIgnoreCase)) e.Utc = DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
            else if (tzid.Length > 0)
            {
                try { e.Utc = TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(parsed, DateTimeKind.Unspecified), TimeZoneInfo.FindSystemTimeZoneById(WindowsZone(tzid))); }
                catch { e.Tbc = true; return; }
            }
            else { e.Tbc = true; return; }
            e.Tbc = false;
            e.LocalStart = new DateTimeOffset(e.Utc).ToOffset(TimeZoneInfo.Local.GetUtcOffset(e.Utc)).ToString("yyyy-MM-dd'T'HH:mm:sszzz", Inv);
        }

        static string WindowsZone(string tzid)
        {
            if (tzid == "Europe/Lisbon" || tzid == "Europe/London") return "GMT Standard Time";
            if (tzid == "Europe/Paris" || tzid == "Europe/Berlin" || tzid == "Europe/Rome" || tzid == "Europe/Madrid") return "Romance Standard Time";
            if (tzid == "Europe/Helsinki" || tzid == "Europe/Athens") return "FLE Standard Time";
            if (tzid == "America/New_York" || tzid == "America/Toronto") return "Eastern Standard Time";
            if (tzid == "America/Chicago" || tzid == "America/Winnipeg") return "Central Standard Time";
            if (tzid == "America/Denver") return "Mountain Standard Time";
            if (tzid == "America/Los_Angeles" || tzid == "America/Vancouver") return "Pacific Standard Time";
            if (tzid == "Asia/Tokyo") return "Tokyo Standard Time";
            if (tzid == "Asia/Shanghai") return "China Standard Time";
            if (tzid == "Australia/Sydney") return "AUS Eastern Standard Time";
            return tzid;
        }

        static List<RwEvent> ParseSro(string html, string series, string source, string asOf)
        {
            List<RwEvent> list = new List<RwEvent>();
            foreach (Match m in Regex.Matches(html ?? "", "(?is)<(?:tr|div)[^>]*data-series\\s*=\\s*[\\\"']GTWC[\\\"'][^>]*>.*?</(?:tr|div)>"))
            {
                RwEvent e = RowEvent(m.Value, m.Value, "GTWC", source, asOf);
                if (e == null) continue;
                e.Series = series;
                list.Add(e);
            }
            return list;
        }

        public static List<RwEvent> ParseWecProgram(string html, string source, string asOf)
        {
            List<RwEvent> list = new List<RwEvent>();
            Match ym = Regex.Match(html ?? "", "(?i)\\b(20\\d{2})\\s+FIA\\s+WEC\\b");
            if (!ym.Success) return list;
            int year = int.Parse(ym.Groups[1].Value, Inv);
            MatchCollection cards = Regex.Matches(html, "(?is)<span[^>]*class=\"name\"[^>]*>(.*?)</span>.*?<span[^>]*class=\"month\"[^>]*>(.*?)</span>.*?<span[^>]*class=\"dates\"[^>]*>(.*?)</span>");
            foreach (Match m in cards)
            {
                string name = Regex.Replace(m.Groups[1].Value, "<[^>]+>", "").Trim();
                string month = Regex.Replace(m.Groups[2].Value, "<[^>]+>", "").Trim().ToLowerInvariant();
                string dates = Regex.Replace(m.Groups[3].Value, "<[^>]+>", "").Trim();
                int mo = MonthNumber(month), day;
                Match dm = Regex.Match(dates, "^([0-9]{1,2})");
                if (name.Length == 0 || mo == 0 || !dm.Success || !int.TryParse(dm.Groups[1].Value, out day)) continue;
                RwEvent e = new RwEvent(); e.Series = "WEC"; e.Event = name; e.Track = ""; e.Session = "Event";
                e.Source = source; e.AsOf = asOf; e.Tbc = true;
                try { DateTime date = new DateTime(year, mo, day); e.Utc = DateTime.SpecifyKind(date, DateTimeKind.Utc); e.EventDate = date.ToString("yyyy-MM-dd", Inv); }
                catch { continue; }
                list.Add(e);
            }
            return list;
        }

        static int MonthNumber(string month)
        {
            string[] names = { "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december" };
            for (int i = 0; i < names.Length; i++) if (month.StartsWith(names[i], StringComparison.OrdinalIgnoreCase)) return i + 1;
            return 0;
        }

        static List<RwEvent> ParseTable(string html, string series, string source, string asOf)
        {
            List<RwEvent> list = new List<RwEvent>();
            if (string.IsNullOrEmpty(html)) return list;
            foreach (Match m in Regex.Matches(html, "<tr[^>]*data-series\\s*=\\s*[\"']" + Regex.Escape(series) + "[\"'][^>]*>(.*?)</tr>", RegexOptions.IgnoreCase | RegexOptions.Singleline))
            {
                RwEvent e = RowEvent(m.Value, m.Groups[1].Value, series, source, asOf);
                if (e != null) list.Add(e);
            }
            foreach (Match m in Regex.Matches(html, "<div[^>]*data-series\\s*=\\s*[\"']" + Regex.Escape(series) + "[\"'][^>]*>", RegexOptions.IgnoreCase))
            {
                RwEvent e = AttrEvent(m.Value, series, source, asOf);
                if (e != null) list.Add(e);
            }
            return list;
        }

        static string Attr(string tag, string name)
        {
            Match m = Regex.Match(tag, name + "\\s*=\\s*[\"']([^\"']*)[\"']", RegexOptions.IgnoreCase);
            return m.Success ? HtmlText(m.Groups[1].Value) : "";
        }

        static string HtmlText(string raw)
        {
            string t = Regex.Replace(raw ?? "", "<[^>]+>", " ");
            t = t.Replace("&nbsp;", " ").Replace("&", "&").Replace("<", "<").Replace(">", ">").Replace("&#39;", "'").Replace("&quot;", "\"");
            return Regex.Replace(t, "\\s+", " ").Trim();
        }

        static RwEvent AttrEvent(string tag, string series, string source, string asOf)
        {
            RwEvent e = new RwEvent();
            e.Series = series;
            e.Event = Attr(tag, "data-event");
            e.Track = Attr(tag, "data-track");
            e.Session = Attr(tag, "data-session");
            if (e.Session.Length == 0) e.Session = "Race";
            foreach (string c in Attr(tag, "data-classes").Split(new char[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)) e.Classes.Add(c.Trim());
            FillWhen(e, Attr(tag, "data-start"));
            e.Source = source; e.AsOf = asOf;
            if (e.Event.Length == 0 && e.Track.Length == 0) return null;
            return e;
        }

        static RwEvent RowEvent(string tag, string inner, string series, string source, string asOf)
        {
            RwEvent e = AttrEvent(tag, series, source, asOf);
            List<string> cells = new List<string>();
            foreach (Match td in Regex.Matches(inner, "<t[dh][^>]*>(.*?)</t[dh]>", RegexOptions.IgnoreCase | RegexOptions.Singleline))
                cells.Add(HtmlText(td.Groups[1].Value));
            if (e == null) { e = new RwEvent(); e.Series = series; }
            if (e.Event.Length == 0 && cells.Count > 0) e.Event = cells[0];
            if (e.Track.Length == 0 && cells.Count > 1) e.Track = cells[1];
            if ((e.Session.Length == 0 || e.Session == "Race") && cells.Count > 2 && cells[2].Length > 0) e.Session = cells[2];
            if (e.LocalStart.Length == 0 && !e.Tbc && cells.Count > 3) FillWhen(e, cells[3]);
            if (e.Classes.Count == 0 && cells.Count > 4)
                foreach (string c in cells[4].Split(new char[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)) e.Classes.Add(c.Trim());
            e.Source = source; e.AsOf = asOf;
            if (e.Event.Length == 0 && e.Track.Length == 0) return null;
            return e;
        }

        public static List<RwEvent> MergeFilterSort(IEnumerable<RwEvent> all, DateTime nowUtc, TimeZoneInfo tz)
        {
            if (tz == null) tz = TimeZoneInfo.Utc;
            DateTime nowLocal = TimeZoneInfo.ConvertTimeFromUtc(nowUtc, tz);
            DateTime from = nowLocal.Date;
            DateTime to = from.AddDays(15);
            List<RwEvent> list = new List<RwEvent>();
            HashSet<string> seen = new HashSet<string>();
            foreach (RwEvent e in all)
            {
                if (e == null) continue;
                if (e.Series != "F1" && e.Series != "IMSA" && e.Series != "WEC" && e.Series != "GTWC" && e.Series != "GTWC Europe" && e.Series != "GTWC America") continue;
                DateTime localDay;
                if (e.Tbc && e.Utc != DateTime.MaxValue && e.Utc != DateTime.MinValue) localDay = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(e.Utc, DateTimeKind.Utc), tz).Date;
                else if (!e.Tbc && e.Utc != DateTime.MinValue && e.Utc != DateTime.MaxValue) localDay = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(e.Utc, DateTimeKind.Utc), tz).Date;
                else continue;
                if (localDay < from || localDay >= to) continue;
                string key = e.Series + "|" + e.Event + "|" + e.Session + "|" + e.Utc.ToString("o", Inv);
                if (!seen.Add(key)) continue;
                list.Add(e);
            }
            list.Sort(delegate (RwEvent a, RwEvent b)
            {
                int c = a.Utc.CompareTo(b.Utc);
                if (c != 0) return c;
                return string.Compare(a.Series, b.Series, StringComparison.Ordinal);
            });
            return list;
        }

        public static byte[] GetBytes(string url)
        {
            TransportCalls++;
            if (TestTransport != null) return TestTransport(url);
            if (!AllowLive) return null;
            if (BusyWhy() != null) return null;
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
            rq.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/129.0 Safari/537.36";
            rq.Accept = "application/json, text/html, application/xhtml+xml, */*;q=0.8";
            rq.Timeout = 10000; rq.ReadWriteTimeout = 10000;
            using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse())
            using (Stream s = rs.GetResponseStream())
            using (MemoryStream ms = new MemoryStream())
            {
                byte[] buf = new byte[16384]; int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0)
                {
                    ms.Write(buf, 0, n);
                    if (ms.Length > 8000000) throw new IOException("too big");
                    int wait = (int)Math.Ceiling(n / 500.0);
                    if (wait > 0) Thread.Sleep(wait);
                }
                return ms.ToArray();
            }
        }

        public static string TryRefresh()
        {
            if (BusyWhy() != null) return "busy";
            if (Interlocked.CompareExchange(ref fetchLock, 1, 0) != 0) return "busy";
            try
            {
                if (cacheAsOf != DateTime.MinValue && (NowUtc() - cacheAsOf).TotalHours < 6) return "fresh";
                if (!AllowLive && TestTransport == null) return "off";
                DateTime asOf = NowUtc();
                string asOfS = asOf.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", Inv);
                List<RwEvent> all = new List<RwEvent>();
                Exception problem = null;
                try { string u = "https://api.jolpi.ca/ergast/f1/current.json"; byte[] b = GetBytes(u); if (b != null) all.AddRange(ParseF1(Encoding.UTF8.GetString(b), u, asOfS)); } catch (Exception ex) { problem = ex; W("F1: " + ex.Message); }
                try { string u = "https://racetagger.cloud/api/calendar/ical?championship_id=9df731ac-2a96-41c3-96f1-80e73731da96"; byte[] b = GetBytes(u); if (b != null) all.AddRange(ParseIcs(Encoding.UTF8.GetString(b), "IMSA", u, asOfS)); } catch (Exception ex) { if (problem == null) problem = ex; W("IMSA ICS: " + ex.Message); }
                try { string u = "https://racetagger.cloud/api/calendar/ical?championship_id=e1edb481-9432-4e5a-af11-287ace8cf999"; byte[] b = GetBytes(u); if (b != null) all.AddRange(ParseIcs(Encoding.UTF8.GetString(b), "WEC", u, asOfS)); } catch (Exception ex) { if (problem == null) problem = ex; W("WEC ICS: " + ex.Message); }
                try { string u = "https://racetagger.cloud/api/calendar/ical?championship_id=a4eb8c77-eff5-4e23-8306-86256bcf5035"; byte[] b = GetBytes(u); if (b != null) all.AddRange(ParseIcs(Encoding.UTF8.GetString(b), "GTWC Europe", u, asOfS)); } catch (Exception ex) { if (problem == null) problem = ex; W("GTWC ICS: " + ex.Message); }
                if (problem != null)
                {
                    if (events.Count > 0) { cacheJson = EventsJson(events, cacheAsOf, false); return "kept"; }
                    if (all.Count > 0) { SaveCache(MergeFilterSort(all, asOf, TimeZoneInfo.Local), asOf); W("saved events from sources that answered"); return "partial"; }
                    return problem.Message;
                }
                if (all.Count == 0 && events.Count > 0) { cacheJson = EventsJson(events, cacheAsOf, false); return "kept"; }
                List<RwEvent> next = MergeFilterSort(all, asOf, TimeZoneInfo.Local);
                SaveCache(next, asOf);
                return null;
            }
            finally { Interlocked.Exchange(ref fetchLock, 0); }
        }

        public static void PutCache(List<RwEvent> list, DateTime asOf) { lock (gate) SaveCache(list, asOf); }

        public static bool CacheFresh(DateTime now)
        {
            return cacheAsOf != DateTime.MinValue && (now - cacheAsOf).TotalHours < 6;
        }

        public static DateTime CacheAsOf { get { return cacheAsOf; } }
        public static List<RwEvent> Events { get { return events; } }

        public static string PreviewKey(RwEvent e, DateTime when)
        {
            DateTime u = when.Kind == DateTimeKind.Utc ? when : DateTime.SpecifyKind(when, DateTimeKind.Utc);
            int week = CultureInfo.InvariantCulture.Calendar.GetWeekOfYear(u, CalendarWeekRule.FirstFourDayWeek, DayOfWeek.Monday);
            return (e.Series + "|" + e.Event + "|" + e.Session + "|" + u.Year + "-W" + week.ToString("00", Inv));
        }

        public static bool PreviewBanned(string text)
        {
            if (string.IsNullOrEmpty(text)) return true;
            if (Regex.IsMatch(text, "(?i)\\byou(?:r|rs|rself|'re|'ve|'ll)?\\b")) return true;
            if (Regex.IsMatch(text, "(?i)\\bgood (?:morning|afternoon|evening|night)\\b|\\bwelcome\\b|\\bready when\\b|\\bhello\\b")) return true;
            if (Regex.IsMatch(text, "(?i)\\b(?:just|simply|quietly|let's|here's|insights?|journey|stories|story|by itself|by themselves|automatically)\\b")) return true;
            if (Regex.IsMatch(text, "[A-Za-z0-9\\)\\]]!(?:\\s|$|[\"'<])")) return true;
            if (Regex.IsMatch(text, "\\u2014|[A-Za-z0-9\\.\\)] \\u2013 [A-Za-z]|[a-z]{3,} - [A-Za-z]{3,}")) return true;
            if (Regex.IsMatch(text, "[\\u2600-\\u27BF]|[\\uD83C-\\uD83E]")) return true;
            if (Regex.IsMatch(text, "[\\u00C2\\u00C3]")) return true;
            if (Regex.IsMatch(text, "(?i)outline from|from your own|sampled \\d|explains \\d|is the mean|mean over|worked out from|last time here")) return true;
            return false;
        }

        public static bool ApplyPreview(RwEvent e, string text, string src, string dateAbs, DateTime week)
        {
            if (!PreviewLines) return false;
            if (PreviewBanned(text)) return false;
            string k = PreviewKey(e, week);
            previewCache[k] = (text ?? "").Trim() + "\n" + src + "\n" + dateAbs;
            return true;
        }

        public static string PreviewPayload(RwEvent e, RwRss rss)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("series=").Append(e.Series).Append('\n');
            sb.Append("event=").Append(e.Event).Append('\n');
            sb.Append("track=").Append(e.Track).Append('\n');
            sb.Append("session=").Append(e.Session).Append('\n');
            sb.Append("classes=").Append(string.Join(",", e.Classes.ToArray())).Append('\n');
            sb.Append("localStart=").Append(e.LocalStart).Append('\n');
            sb.Append("tbc=").Append(e.Tbc ? "true" : "false").Append('\n');
            sb.Append("source=").Append(e.Source).Append('\n');
            sb.Append("asOf=").Append(e.AsOf).Append('\n');
            if (rss != null)
            {
                sb.Append("rssTitle=").Append(rss.Title).Append('\n');
                sb.Append("rssSummary=").Append(rss.Summary).Append('\n');
                sb.Append("rssUrl=").Append(rss.Url).Append('\n');
                sb.Append("rssPubDate=").Append(rss.PubDate).Append('\n');
            }
            return sb.ToString();
        }

        public static bool RequestPreview(RwEvent e, RwRss rss, DateTime week)
        {
            if (!PreviewLines) return false;
            if (BusyWhy() != null) return false;
            string k = PreviewKey(e, week);
            if (previewCache.ContainsKey(k)) return false;
            PreviewCalls++;
            string body = null;
            try
            {
                if (TestPreviewHttp != null) body = TestPreviewHttp(PreviewPayload(e, rss), PreviewModel);
                else return false;
            }
            catch { return false; }
            if (string.IsNullOrEmpty(body) || body.Length > 32768) return false;
            string src = rss != null && rss.Url.Length > 0 ? rss.Url : e.Source;
            string dateAbs = rss != null && rss.PubDate.Length > 0 ? rss.PubDate : e.AsOf;
            return ApplyPreview(e, body, src, dateAbs, week);
        }

        public static void ClearPreview() { previewCache.Clear(); PreviewCalls = 0; }

        public static string CostLogPath = "";
        public static void RecordCost(string provider, string model, string utc, string tokensIn, string tokensOut, string billed)
        {
            if (string.IsNullOrEmpty(CostLogPath)) return;
            try
            {
                string line = (provider ?? "") + "\t" + (model ?? "") + "\t" + (utc ?? "") + "\t" + (tokensIn ?? "") + "\t" + (tokensOut ?? "") + "\t" + (billed ?? "") + "\r\n";
                File.AppendAllText(CostLogPath, line, new UTF8Encoding(false));
            }
            catch { }
        }
    }
}
