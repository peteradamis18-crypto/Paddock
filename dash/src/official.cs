// Official racing on the home screen (WS8, docs\official.md): which official races can Peter enter, and when.
// What it knows comes from iRacing's own published season schedule (a PDF: every series, its cars, the weekly track,
// "Races every 2 hours at :15 past") and from what is installed on this PC (cars and tracks he owns). The pure parts
// (PDF reading, patterns, ownership, eligibility) are in officialcore.cs; this file is the irdash side:
//   /official                     the JSON for the idle-screen "Race weekend" panel and the OFFICIAL deck screen
//   /official/import?name=x.pdf   read a season schedule PDF that was put in data\official (or Downloads)
//   /official/owned               what is installed and what each folder is called
//   /official/refresh             read the files again and rebuild now
//   /api/do?c=offav&a=<series id> star / un-star a series (favourites.ini); ofopen / ofclose / ofrefresh; ofscan / ofdry (irdeck)
// Everything lives in <root>\data\official: season.json, owned.json, schedule.json (what the screens last showed),
// favourites.ini, profile.ini. Nothing here touches iRacing's own files (it only lists the folders), never signs in,
// and never registers for anything: there is no register command at all in the whitelist (SPEC WS8 R6).
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class Official
    {
        static string dir = "", rootDir = "";
        static readonly object gate = new object();
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // ---- loaded data ----
        static List<OfSeries> series = new List<OfSeries>(); static DateTime seasonStamp = DateTime.MinValue; static string seasonName = "", seasonSource = ""; static DateTime seasonImported;
        static OfficialCore.OwnedMap owned; static DateTime ownedBuilt = DateTime.MinValue;
        static Dictionary<string, string> profile = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); static DateTime profileStamp = DateTime.MinValue;
        static List<string> favNames = new List<string>(); static DateTime favStamp = DateTime.MinValue;
        static string careerLic = ""; static HashSet<string> familiar = new HashSet<string>(); static List<OfficialCore.SessionHint> careerSessions = new List<OfficialCore.SessionHint>(); static DateTime careerStamp = DateTime.MinValue;
        static string snapJson = ""; static DateTime snapBuilt = DateTime.MinValue, snapNow = DateTime.MinValue;
        static DateTime openUntil = DateTime.MinValue;
        sealed class Special { public string Name = "", Car = "", Track = ""; public DateTime From, To; }
        static List<Special> specials = new List<Special>(); static DateTime specialsStamp = DateTime.MinValue;
        static volatile bool dirty = true;
        static bool enabled = false;   // official=1 in dash\irdash.ini is the only ON when that file exists
        public static bool Enabled { get { return enabled; } }

        // The offline harness (tests\official-unit.cs) has no irdash.ini next to its pretend root, so a missing file
        // leaves the code available for those checks. The live file is always there, and a missing official=1 stays off.
        static void ReadSwitch()
        {
            enabled = false;
            string f = "";
            try { if (!string.IsNullOrEmpty(rootDir)) f = Path.Combine(rootDir, @"dash\irdash.ini"); } catch { f = ""; }
            if (f.Length == 0 || !File.Exists(f)) { enabled = true; return; }
            try
            {
                foreach (string raw in File.ReadAllLines(f))
                {
                    string l = raw.Trim();
                    if (l.Length == 0 || l[0] == ';' || l[0] == '#') continue;
                    int e = l.IndexOf('='); if (e <= 0) continue;
                    if (string.Equals(l.Substring(0, e).Trim(), "official", StringComparison.OrdinalIgnoreCase) && l.Substring(e + 1).Trim() == "1") enabled = true;
                }
            }
            catch (Exception ex) { Log.W("official: irdash.ini: " + ex.Message); }
        }

        public static void Init(string d)
        {
            dir = d;
            rootDir = "";
            try { rootDir = Path.GetDirectoryName(Path.GetDirectoryName(d)); } catch { rootDir = ""; }
            if (rootDir == null) rootDir = "";
            ReadSwitch();
            if (!enabled) { Log.W("official: switched off (official=0 in irdash.ini)"); return; }   // no thread, no files, no download
            try { Directory.CreateDirectory(dir); } catch { }
            Thread t = new Thread(Loop); t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Start();
        }

        static readonly HashSet<string> Commands = new HashSet<string> { "offav", "ofopen", "ofclose", "ofrefresh", "ofscan", "ofdry" };
        public static bool Handles(string c) { return enabled && Commands.Contains(c ?? ""); }

        static bool Busy()
        {
            try { return Program.IsDriving || Sdk.Latest.Connected; } catch { return false; }
        }

        // Sdk.RealBusy exists in irdash; the offline unit stub may omit it. Never start a fetch while he is driving.
        static bool FetchBusy()
        {
            try
            {
                System.Reflection.MethodInfo m = typeof(Sdk).GetMethod("RealBusy", Type.EmptyTypes);
                if (m != null) { object r = m.Invoke(null, null); if (r != null) return true; }
            }
            catch { }
            return Busy();
        }

        // ---- the whitelisted deck presses ----
        public static bool Do(string c, string a)
        {
            if (!enabled) return false;
            a = (a ?? "").Trim();
            switch (c)
            {
                case "ofopen": openUntil = DateTime.UtcNow.AddMinutes(3); return true;      // the add-on repeats this while the screen is up
                case "ofclose": openUntil = DateTime.MinValue; return true;
                case "ofrefresh": dirty = true; ownedBuilt = DateTime.MinValue; return true;
                case "offav":
                    if (!Regex.IsMatch(a, "^o[0-9a-f]{8}$")) return false;
                    return ToggleFav(a);
                case "ofscan":
                    // check which cars and tracks iRacing's own lists show as yours (read-only, out of the car, sim closed)
                    if (Busy()) return false;
                    RunIrdeck("official scan owned"); return true;
                case "ofdry":
                    if (!Regex.IsMatch(a, "^o[0-9a-f]{8}$") || Busy()) return false;
                    RunIrdeck("official register --dry " + a); return true;
            }
            return false;
        }

        static int irdeckBusy;
        static void RunIrdeck(string args)
        {
            if (Watch.IrdeckPath == null || !File.Exists(Watch.IrdeckPath)) { Log.W("official: irdeck.exe not found"); return; }
            if (Interlocked.CompareExchange(ref irdeckBusy, 1, 0) != 0) return;     // one at a time
            Thread t = new Thread(delegate ()
            {
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo(Watch.IrdeckPath, args);
                    psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(Watch.IrdeckPath);
                    using (Process p = Process.Start(psi)) { if (!p.WaitForExit(900000)) { try { p.Kill(); } catch { } Log.W("official: '" + args + "' took too long"); } }
                }
                catch (Exception ex) { Log.W("official: '" + args + "': " + ex.Message); }
                finally { Interlocked.Exchange(ref irdeckBusy, 0); dirty = true; }
            });
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Start();
        }

        // ---- HTTP routes ----
        public static string Route(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (!enabled) return "{\"enabled\":false}";
            try
            {
                if (path == "/official")
                {
                    string now; q.TryGetValue("now", out now);          // ?now=2026-10-09T18:30:00Z shows the panel as of then (screenshots, tests)
                    return Json(now);
                }
                if (path == "/official/refresh") { dirty = true; ownedBuilt = DateTime.MinValue; return Json(null); }
                if (path == "/official/owned") { EnsureData(); return OwnedJson(); }
                if (path == "/official/import")
                {
                    string name; q.TryGetValue("name", out name);
                    string msg = ImportFile(name ?? "");
                    if (msg != null) { code = 400; return "{\"ok\":false,\"msg\":" + Json_.S(msg) + "}"; }
                    return "{\"ok\":true,\"series\":" + series.Count + "}";
                }
            }
            catch (Exception ex) { Log.W("official route: " + ex.Message); code = 500; return "{\"ok\":false}"; }
            return null;
        }

        // ---- background: keep the cached schedule fresh, never during a session ----
        static void Loop()
        {
            Thread.Sleep(20000);
            while (true)
            {
                try
                {
                    if (!Busy())
                    {
                        FetchIfAllowed();
                        if (dirty || snapJson.Length == 0 || (DateTime.UtcNow - snapBuilt).TotalMinutes >= 30) Json(null);
                    }
                }
                catch (Exception ex) { Log.W("official loop: " + ex.Message); }
                Thread.Sleep(60000);
            }
        }

        // ---------------------------------------------------------------- files
        static string P(string name) { return Path.Combine(dir, name); }

        static void WriteFile(string name, string text)
        {
            string f = P(name), tmp = f + ".tmp";
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            try { if (File.Exists(f)) File.Replace(tmp, f, null); else File.Move(tmp, f); }
            catch { try { File.Copy(tmp, f, true); File.Delete(tmp); } catch { } }
        }

        static JavaScriptSerializer Ser() { JavaScriptSerializer s = new JavaScriptSerializer(); s.MaxJsonLength = int.MaxValue; s.RecursionLimit = 100; return s; }
        static string Str(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, Inv) : ""; }

        static void EnsureData()
        {
            lock (gate)
            {
                LoadSeason(); LoadProfile(); LoadFavs(); LoadCareer(); LoadSpecials();
                if (owned == null || (DateTime.UtcNow - ownedBuilt).TotalHours >= 6) BuildOwned();
            }
        }

        // ---- the season (parsed from the PDF once, kept as JSON) ----
        static void LoadSeason()
        {
            string f = P("season.json");
            if (!File.Exists(f)) { if (series.Count > 0) series.Clear(); seasonStamp = DateTime.MinValue; return; }
            DateTime st = File.GetLastWriteTimeUtc(f);
            if (st == seasonStamp) return;
            try
            {
                Dictionary<string, object> root = Ser().DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                List<OfSeries> list = new List<OfSeries>();
                foreach (object o in (IList)root["series"])
                {
                    Dictionary<string, object> d = (Dictionary<string, object>)o;
                    OfSeries s = new OfSeries();
                    s.Id = Str(d, "id"); s.Name = Str(d, "name"); s.Short = Str(d, "short"); s.Key = Str(d, "key"); s.Lic = Str(d, "lic"); s.LicText = Str(d, "licText"); s.Freq = Str(d, "freq");
                    foreach (object c in (IList)d["cars"]) s.Cars.Add(Convert.ToString(c, Inv));
                    foreach (object wo in (IList)d["weeks"])
                    {
                        Dictionary<string, object> wd = (Dictionary<string, object>)wo;
                        OfWeek w = new OfWeek();
                        w.N = int.Parse(Str(wd, "n"), Inv); w.Start = DateTime.SpecifyKind(DateTime.ParseExact(Str(wd, "start"), "yyyy-MM-dd", Inv), DateTimeKind.Utc);
                        w.Track = Str(wd, "track"); w.Layout = Str(wd, "layout"); w.Length = Str(wd, "len");
                        s.Weeks.Add(w);
                    }
                    list.Add(s);
                }
                series = list; seasonStamp = st;
                seasonName = Str(root, "season"); seasonSource = Str(root, "source");
                DateTime.TryParse(Str(root, "importedAt"), Inv, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out seasonImported);
                dirty = true;
                Log.W("official: season schedule loaded - " + list.Count + " series (" + seasonName + ")");
            }
            catch (Exception ex) { Log.W("official: season.json unreadable: " + ex.Message); }
        }

        static string SeasonJson(List<OfSeries> list, string name, string source)
        {
            StringBuilder sb = new StringBuilder("{\"season\":" + Json_.S(name) + ",\"source\":" + Json_.S(source) + ",\"importedAt\":" + Json_.S(DateTime.UtcNow.ToString("o", Inv)) + ",\"series\":[");
            for (int i = 0; i < list.Count; i++)
            {
                OfSeries s = list[i]; if (i > 0) sb.Append(',');
                sb.Append("{\"id\":" + Json_.S(s.Id) + ",\"name\":" + Json_.S(s.Name) + ",\"short\":" + Json_.S(s.Short) + ",\"key\":" + Json_.S(s.Key) + ",\"lic\":" + Json_.S(s.Lic) + ",\"licText\":" + Json_.S(s.LicText) + ",\"freq\":" + Json_.S(s.Freq) + ",\"cars\":[");
                for (int c = 0; c < s.Cars.Count; c++) sb.Append(c > 0 ? "," : "").Append(Json_.S(s.Cars[c]));
                sb.Append("],\"weeks\":[");
                for (int k = 0; k < s.Weeks.Count; k++)
                {
                    OfWeek w = s.Weeks[k]; if (k > 0) sb.Append(',');
                    sb.Append("{\"n\":" + w.N + ",\"start\":" + Json_.S(w.Start.ToString("yyyy-MM-dd", Inv)) + ",\"track\":" + Json_.S(w.Track) + ",\"layout\":" + Json_.S(w.Layout) + ",\"len\":" + Json_.S(w.Length) + "}");
                }
                sb.Append("]}");
            }
            return sb.Append("]}").ToString();
        }

        // Read a schedule PDF that is already on this PC (data\official or Downloads). Returns null when it worked, else why not.
        static string ImportFile(string name)
        {
            if (!Regex.IsMatch(name, @"^[A-Za-z0-9._ -]{3,80}\.pdf$")) return "Give the file name of the PDF (letters, digits and dots only).";
            string f = P(name);
            if (!File.Exists(f)) f = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @"Downloads\" + name);
            if (!File.Exists(f)) return "I can't find " + name + " in data\\official or Downloads.";
            return ImportBytes(File.ReadAllBytes(f), "file " + name);
        }

        // For tools and tests: read a PDF from any path. null = it worked.
        public static string ImportPath(string full, string label)
        {
            if (!File.Exists(full)) return "no such file";
            return ImportBytes(File.ReadAllBytes(full), label);
        }

        public static int MinSeries = 20;      // a real schedule has 150; tests set it lower for their pretend PDF
        static string ImportBytes(byte[] pdf, string source)
        {
            if (pdf.Length < 100 || pdf[0] != '%' || pdf[1] != 'P') return "That is not a PDF.";
            List<OfSeries> list = OfficialCore.ParseSeason(PdfText.Extract(pdf));
            if (list.Count < MinSeries) return "I could not read the schedule in that PDF (" + list.Count + " series found).";
            string name = "";
            foreach (OfSeries s in list) { Match m = Regex.Match(s.Name, @"20\d\d Season( \d)?"); if (m.Success) { name = m.Value; break; } }
            lock (gate) { WriteFile("season.json", SeasonJson(list, name, source)); seasonStamp = DateTime.MinValue; dirty = true; }
            Log.W("official: imported " + list.Count + " series (" + name + ") from " + source);
            EnsureData();
            return null;
        }

        // Tests inject bytes for a URL; null = real HTTP. Never set in the live irdash process.
        public static Func<string, byte[]> TestTransport;
        public static int TransportCalls;

        static bool SeasonPageUrlOk(string url)
        {
            if (string.IsNullOrEmpty(url)) return false;
            if (Regex.IsMatch(url, @"^https://www\.iracing\.com/seasons/20\d\d-s[1-4]/?$", RegexOptions.IgnoreCase)) return true;
            if (Regex.IsMatch(url, @"^https://www\.iracing\.com/seasons/20\d\d-s[1-4]/[A-Za-z0-9._/%-]*$", RegexOptions.IgnoreCase)) return true;
            if (Regex.IsMatch(url, @"^https://www\.iracing\.com/[A-Za-z0-9./_%-]{8,200}\.pdf$", RegexOptions.IgnoreCase)) return true;
            return false;
        }

        static string CacheDir() { return Path.Combine(dir, "source-cache"); }

        static void WriteSourceCache(string name, byte[] bytes, string url, string asOfUtc)
        {
            string c = CacheDir();
            try { Directory.CreateDirectory(c); } catch { }
            string f = Path.Combine(c, name);
            File.WriteAllBytes(f, bytes);
            File.WriteAllText(Path.Combine(c, "asof.txt"), "url=" + url + "\r\nasOf=" + asOfUtc + "\r\nfile=" + name + "\r\n", new UTF8Encoding(false));
        }

        static byte[] GetUrlBytes(string url)
        {
            TransportCalls++;
            if (TestTransport != null) return TestTransport(url);
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
            rq.UserAgent = "Paddock/1.0 (personal sim-rig tool; reads iRacing's public season schedule once a day)";
            rq.Timeout = 30000; rq.ReadWriteTimeout = 30000;
            using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse())
            using (Stream s = rs.GetResponseStream())
            using (MemoryStream ms = new MemoryStream())
            {
                byte[] buf = new byte[16384]; int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0)
                {
                    ms.Write(buf, 0, n);
                    if (ms.Length > 8000000) throw new IOException("too big");
                    int wait = (int)Math.Ceiling(n / 500.0);     // ~500 KB/s
                    if (wait > 0) Thread.Sleep(wait);
                }
                return ms.ToArray();
            }
        }

        static string ImportHtml(string html, string source)
        {
            if (OfficialCore.SeasonPublishedState(html) == "not published") return "not published";
            List<OfSeries> list = OfficialCore.ParseHtmlSeason(html);
            if (list.Count < MinSeries) return "I could not read the schedule in that page (" + list.Count + " series found).";
            string name = "";
            foreach (OfSeries s in list) { Match m = Regex.Match(s.Name, @"20\d\d Season( \d)?"); if (m.Success) { name = m.Value; break; } }
            lock (gate) { WriteFile("season.json", SeasonJson(list, name, source)); seasonStamp = DateTime.MinValue; dirty = true; }
            Log.W("official: imported " + list.Count + " series (" + name + ") from " + source);
            EnsureData();
            return null;
        }

        // Once a day at most, and only when Peter has said yes in profile.ini (autodownload=yes + scheduleurl=...): the public iRacing seasons page or PDF. No default URL.
        public static string FetchIfAllowed()
        {
            LoadProfile();
            if (!"yes".Equals(Pv("autodownload"), StringComparison.OrdinalIgnoreCase)) return "consent";
            string url = Pv("scheduleurl");
            if (!SeasonPageUrlOk(url)) return "url";
            if (FetchBusy()) return "busy";
            string stampFile = P("fetch.txt");
            try { if (File.Exists(stampFile) && (DateTime.UtcNow - File.GetLastWriteTimeUtc(stampFile)).TotalHours < 24) return "fresh"; } catch { }
            try { File.WriteAllText(stampFile, DateTime.UtcNow.ToString("o", Inv)); } catch { }
            try
            {
                byte[] raw = GetUrlBytes(url);
                if (raw == null || raw.Length < 8) return "empty";
                string asOf = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", Inv);
                if (raw.Length >= 4 && raw[0] == '%' && raw[1] == 'P')
                {
                    string why = ImportBytes(raw, url);
                    if (why != null) { Log.W("official: downloaded schedule not used - " + why); return why; }
                    WriteSourceCache("season.pdf", raw, url, asOf);
                    return null;
                }
                string html = Encoding.UTF8.GetString(raw);
                string pdf = OfficialCore.FindSeasonPdfHref(html);
                if (pdf.Length > 0)
                {
                    byte[] pdfBytes = GetUrlBytes(pdf);
                    string why = ImportBytes(pdfBytes, pdf);
                    if (why != null) { Log.W("official: downloaded schedule not used - " + why); return why; }
                    WriteSourceCache("season.pdf", pdfBytes, pdf, asOf);
                    try { Directory.CreateDirectory(CacheDir()); File.WriteAllBytes(Path.Combine(CacheDir(), "season.html"), raw); } catch { }
                    return null;
                }
                string state = OfficialCore.SeasonPublishedState(html);
                if (state == "not published")
                {
                    try { Directory.CreateDirectory(CacheDir()); File.WriteAllText(Path.Combine(CacheDir(), "asof.txt"), "url=" + url + "\r\nasOf=" + asOf + "\r\nstate=not published\r\n", new UTF8Encoding(false)); } catch { }
                    return "not published";
                }
                string hw = ImportHtml(html, url);
                if (hw != null) { Log.W("official: downloaded schedule not used - " + hw); return hw; }
                WriteSourceCache("season.html", raw, url, asOf);
                return null;
            }
            catch (Exception ex) { Log.W("official: schedule download failed - " + ex.Message); return ex.Message; }
        }

        // ---- profile.ini: licence classes, evening hour, download permission ----
        static string Pv(string k) { string v; return profile.TryGetValue(k, out v) ? v : ""; }

        static void LoadProfile()
        {
            string f = P("profile.ini");
            if (!File.Exists(f))
            {
                try
                {
                    WriteFile("profile.ini",
                        "; Paddock official racing - settings. Lines starting with ; are notes.\r\n" +
                        "; Licence class per kind of racing (R D C B A P). Road is read from your last race; oval and dirt are not, so say them here.\r\n" +
                        "; Leave one empty and Paddock treats it as Rookie (it only shows series a Rookie can enter).\r\n" +
                        "road=\r\noval=\r\ndirt=\r\n" +
                        "; The hour (local time) the weekend lists start from, because every series races all day. 18 = from 6 pm.\r\nevening=18\r\n" +
                        "; Peter's yes for reading iRacing's public season schedule PDF once a day (about 0.5 MB). yes / no. scheduleurl is the PDF link.\r\n" +
                        "autodownload=no\r\nscheduleurl=\r\n");
                }
                catch { }
            }
            DateTime st = File.Exists(f) ? File.GetLastWriteTimeUtc(f) : DateTime.MinValue;
            if (st == profileStamp) return;
            profileStamp = st; profile.Clear();
            try
            {
                foreach (string raw in File.ReadAllLines(f))
                {
                    string l = raw.Trim(); if (l.Length == 0 || l.StartsWith(";") || l.StartsWith("#")) continue;
                    int e = l.IndexOf('='); if (e > 0) profile[l.Substring(0, e).Trim()] = l.Substring(e + 1).Trim();
                }
            }
            catch { }
            dirty = true;
        }

        // ---- special events: iRacing publishes dates only (iracing.com/special-events), no start times, so they are a one-line note ----
        static void LoadSpecials()
        {
            string f = P("specials.ini");
            if (!File.Exists(f))
            {
                try
                {
                    WriteFile("specials.ini",
                        "; Special events from iRacing's public calendar (iracing.com/special-events) - dates only, the page gives no start times.\r\n" +
                        "; name | first day | last day | car | track.  Edit or add lines when iRacing announces more.\r\n" +
                        "Bathurst 1000 | 2026-10-02 | 2026-10-04 | Supercars | Mount Panorama Circuit\r\n" +
                        "8 Hours of Indianapolis | 2026-10-16 | 2026-10-18 | GT3 | Indianapolis Motor Speedway\r\n" +
                        "iRacing FF1600 Festival | 2026-10-30 | 2026-10-31 | Ray FF1600 | Brands Hatch Circuit\r\n" +
                        "Homestead Championship | 2026-11-04 | 2026-11-09 | NASCAR Cup Series | Homestead Miami Speedway\r\n" +
                        "SFL Mountain Showdown | 2026-11-13 | 2026-11-15 | Super Formula Lights | Mount Panorama Circuit\r\n" +
                        "SCCA Runoffs | 2026-11-17 | 2026-11-21 | Six classes | \r\n" +
                        "992 Endurance Cup | 2026-11-27 | 2026-11-29 | Porsche 911 Cup (992.2) | \r\n" +
                        "Winter Derby | 2026-12-02 | 2026-12-07 | Super Late Model | Five Flags Speedway\r\n" +
                        "Chili Bowl | 2026-12-15 | 2026-12-20 | Dirt Midget | \r\n" +
                        "THE Production Car Challenge at VIR | 2026-12-18 | 2026-12-19 | Production Car Challenge cars | Virginia International Raceway\r\n");
                }
                catch { }
            }
            DateTime st = File.Exists(f) ? File.GetLastWriteTimeUtc(f) : DateTime.MinValue;
            if (st == specialsStamp) return;
            specialsStamp = st; specials.Clear();
            try
            {
                foreach (string raw in File.ReadAllLines(f, Encoding.UTF8))
                {
                    string l = raw.Trim(); if (l.Length == 0 || l.StartsWith(";") || l.StartsWith("#")) continue;
                    string[] p = l.Split('|'); if (p.Length < 3) continue;
                    Special s = new Special(); s.Name = p[0].Trim(); s.Car = p.Length > 3 ? p[3].Trim() : ""; s.Track = p.Length > 4 ? p[4].Trim() : "";
                    if (DateTime.TryParseExact(p[1].Trim(), "yyyy-MM-dd", Inv, DateTimeStyles.None, out s.From) && DateTime.TryParseExact(p[2].Trim(), "yyyy-MM-dd", Inv, DateTimeStyles.None, out s.To)) specials.Add(s);
                }
            }
            catch { }
            dirty = true;
        }

        // ---- favourites ----
        static void LoadFavs()
        {
            string f = P("favourites.ini");
            DateTime st = File.Exists(f) ? File.GetLastWriteTimeUtc(f) : DateTime.MinValue;
            if (st == favStamp) return;
            favStamp = st; favNames.Clear();
            try
            {
                if (File.Exists(f))
                    foreach (string raw in File.ReadAllLines(f, Encoding.UTF8))
                    {
                        string l = raw.Trim(); if (l.Length == 0 || l.StartsWith(";") || l.StartsWith("#")) continue;
                        if (!favNames.Contains(l)) favNames.Add(l);
                    }
            }
            catch { }
            dirty = true;
        }

        static void SaveFavs()
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("; Paddock favourite series, one per line, newest first. The star key on the OFFICIAL screen adds and removes lines;\r\n");
            sb.Append("; you can edit this with Notepad too. Names ignore the season (\"2026 Season 4\"), so a favourite survives into the next season.\r\n");
            foreach (string n in favNames) sb.Append(n).Append("\r\n");
            WriteFile("favourites.ini", sb.ToString());
            favStamp = File.GetLastWriteTimeUtc(P("favourites.ini"));
        }

        static bool ToggleFav(string id)
        {
            lock (gate)
            {
                LoadSeason(); LoadFavs();
                OfSeries s = series.Find(delegate (OfSeries x) { return x.Id == id; });
                if (s == null) return false;
                int i = favNames.FindIndex(delegate (string n) { return OfficialCore.Norm(n) == OfficialCore.Norm(s.Short); });
                if (i >= 0) { favNames.RemoveAt(i); Log.W("official: star removed from " + s.Short); }
                else { favNames.Insert(0, s.Short); Log.W("official: starred " + s.Short); }
                SaveFavs(); dirty = true; snapJson = "";
                return true;
            }
        }

        static HashSet<string> FavKeys()
        {
            HashSet<string> k = new HashSet<string>();
            foreach (string n in favNames) k.Add(OfficialCore.Norm(n));
            return k;
        }

        // ---- career cache: licence and the cars he drives (read only) ----
        static void LoadCareer()
        {
            string f = Path.Combine(rootDir, @"dash\career-cache.tsv");
            DateTime st = File.Exists(f) ? File.GetLastWriteTimeUtc(f) : DateTime.MinValue;
            if (st == careerStamp) return;
            careerStamp = st;
            HashSet<string> cars = new HashSet<string>(); string lic = ""; long licWhen = 0;
            List<OfficialCore.SessionHint> hints = new List<OfficialCore.SessionHint>();
            try
            {
                if (st != DateTime.MinValue)
                    using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (StreamReader sr = new StreamReader(fs, Encoding.UTF8))
                    {
                        string line;
                        while ((line = sr.ReadLine()) != null)
                        {
                            string[] p = line.Split('\t'); if (p.Length < 13) continue;
                            double secs; long ticks; int ir;
                            if (!double.TryParse(p[2], NumberStyles.Float, Inv, out secs) || secs < 30 || !long.TryParse(p[1], out ticks)) continue;
                            if (p[6].Trim().Length > 0) cars.Add(OfficialCore.Norm(p[6]));
                            OfficialCore.SessionHint h = new OfficialCore.SessionHint();
                            h.When = new DateTime(ticks, DateTimeKind.Utc);
                            h.Car = p[6].Trim();
                            h.Track = p[7].Trim();
                            h.Series = "";
                            hints.Add(h);
                            // a rated session (iRating above the 1 that test drives carry) has his real licence class
                            if (int.TryParse(p[5], out ir) && ir > 1 && p[11].Trim().Length > 0 && ticks > licWhen) { licWhen = ticks; lic = p[11].Trim(); }
                        }
                    }
            }
            catch (Exception ex) { Log.W("official: career cache: " + ex.Message); }
            familiar = cars; careerLic = lic; careerSessions = hints;
        }

        // ---- what is installed ----
        static string IRacingDir()
        {
            string p = Pv("iracing");
            if (p.Length > 0 && Directory.Exists(p)) return p;
            string x86 = Environment.GetEnvironmentVariable("ProgramFiles(x86)");
            return Path.Combine(string.IsNullOrEmpty(x86) ? @"C:\Program Files (x86)" : x86, "iRacing");
        }

        static void BuildOwned()
        {
            string ir = IRacingDir(), cars = Path.Combine(ir, "cars"), tracks = Path.Combine(ir, "tracks");
            List<string> carPaths = new List<string>(), trackDirs = new List<string>();
            try
            {
                if (Directory.Exists(cars))
                    foreach (string f in Directory.GetFiles(cars, "*.dat", SearchOption.AllDirectories))
                    {
                        string rel = f.Substring(cars.Length + 1); rel = rel.Substring(0, rel.Length - 4);
                        string[] seg = rel.Split('\\');
                        if (seg.Length >= 2 && seg[seg.Length - 1] == seg[seg.Length - 2]) rel = string.Join("\\", seg, 0, seg.Length - 1);   // cars\x\y\y.dat is car "x\y"
                        if (rel.IndexOf('\\') < 0 && rel == "cars") continue;
                        if (!carPaths.Contains(rel)) carPaths.Add(rel);
                    }
                if (Directory.Exists(tracks)) foreach (string d in Directory.GetDirectories(tracks)) trackDirs.Add(Path.GetFileName(d));
            }
            catch (Exception ex) { Log.W("official: cannot list the iRacing folders: " + ex.Message); }
            // names iRacing itself gave his cars in his own sessions: telemetry file names start with the car folder
            Dictionary<string, string> learned = LearnCarNames();
            OfficialCore.OwnedMap o = OfficialCore.BuildOwned(carPaths, trackDirs, learned, null);
            ApplyUiCheck(o);
            owned = o; ownedBuilt = DateTime.UtcNow;
            try { WriteFile("owned.json", OwnedJson()); } catch { }
        }

        // owned-ui.json (irdeck "official scan owned"): what iRacing's own Set Car / Set Track lists said. It overrules the folders:
        // an installed car the list does not show as yours is dropped, one it shows is kept.
        static int uiChecked;
        static void ApplyUiCheck(OfficialCore.OwnedMap o)
        {
            uiChecked = 0;
            try
            {
                string f = P("owned-ui.json"); if (!File.Exists(f)) return;
                Dictionary<string, object> root = Ser().DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                foreach (string kind in new string[] { "cars", "tracks" })
                {
                    Dictionary<string, object> d = root[kind] as Dictionary<string, object>; if (d == null) continue;
                    HashSet<string> keys = kind == "cars" ? o.CarKeys : o.TrackKeys;
                    foreach (KeyValuePair<string, object> kv in d)
                    {
                        string k = OfficialCore.Norm(kv.Key);
                        if (Convert.ToBoolean(kv.Value)) keys.Add(k); else keys.Remove(k);
                        uiChecked++;
                    }
                }
            }
            catch (Exception ex) { Log.W("official: owned-ui.json unreadable: " + ex.Message); }
        }

        static Dictionary<string, string> LearnCarNames()
        {
            Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string f = Path.Combine(rootDir, @"dash\career-cache.tsv");
                if (File.Exists(f))
                    using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (StreamReader sr = new StreamReader(fs, Encoding.UTF8))
                    {
                        string line;
                        while ((line = sr.ReadLine()) != null)
                        {
                            string[] p = line.Split('\t'); if (p.Length < 13) continue;
                            int u = p[0].IndexOf('_'); if (u <= 0 || p[6].Trim().Length == 0) continue;
                            d[p[0].Substring(0, u)] = p[6].Trim();
                        }
                    }
            }
            catch { }
            return d;
        }

        static string OwnedJson()
        {
            OfficialCore.OwnedMap o = owned; if (o == null) return "{\"ready\":false}";
            StringBuilder sb = new StringBuilder("{\"builtAt\":" + Json_.S(ownedBuilt.ToString("o", Inv)) + ",\"source\":\"the folders under iRacing\\\\cars and iRacing\\\\tracks\",\"cars\":" + o.CarFolders.Count + ",\"tracks\":" + o.TrackFolders.Count + ",\"checkedInIRacing\":" + uiChecked);
            Action<string, List<string>> arr = delegate (string k, List<string> l)
            {
                sb.Append(",\"" + k + "\":[");
                for (int i = 0; i < l.Count; i++) sb.Append(i > 0 ? "," : "").Append(Json_.S(l[i]));
                sb.Append("]");
            };
            List<string> cn = new List<string>(new SortedDictionary<string, int>(ToDict(o.CarNames)).Keys), tn = new List<string>(new SortedDictionary<string, int>(ToDict(o.TrackNames)).Keys);
            arr("carNames", cn); arr("trackNames", tn); arr("unknownCars", o.UnknownCars); arr("unknownTracks", o.UnknownTracks);
            return sb.Append("}").ToString();
        }
        static Dictionary<string, int> ToDict(List<string> l) { Dictionary<string, int> d = new Dictionary<string, int>(); foreach (string s in l) d[s] = 1; return d; }

        // ---------------------------------------------------------------- the answer
        static string Iso(DateTime utc) { return utc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", Inv); }

        // nowOverride: ISO time for screenshots and tests; null = the real clock
        public static string Json(string nowOverride)
        {
            DateTime nowUtc = DateTime.UtcNow; bool fake = false;
            if (!string.IsNullOrEmpty(nowOverride))
            {
                DateTime t;
                if (DateTime.TryParse(nowOverride, Inv, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out t)) { nowUtc = t; fake = true; }
            }
            try
            {
                EnsureData();
                lock (gate)
                {
                    // rebuild when the minute changes so countdownSeconds does not freeze
                    DateTime clock = DateTime.UtcNow;
                    if (!fake && snapJson.Length > 0 && !dirty && clock.Year == snapNow.Year && clock.Month == snapNow.Month && clock.Day == snapNow.Day && clock.Hour == snapNow.Hour && clock.Minute == snapNow.Minute) return snapJson;
                    string j = Build(nowUtc, fake);
                    if (!fake)
                    {
                        snapJson = j; snapNow = DateTime.UtcNow; dirty = false;
                        if ((DateTime.UtcNow - snapBuilt).TotalMinutes >= 30 || snapBuilt == DateTime.MinValue) { snapBuilt = DateTime.UtcNow; try { WriteFile("schedule.json", j); } catch { } }
                    }
                    return j;
                }
            }
            catch (Exception ex) { Log.W("official json: " + ex.Message + " " + ex.StackTrace); return "{\"ready\":false}"; }
        }

        sealed class Row
        {
            public OfRace R; public int N; public bool Fav, Fam; public OfPattern Pat; public string Car = ""; public int CarCount;
        }

        static string LicWord(string l) { return l == "R" ? "Rookie" : l == "P" ? "Pro" : "Class " + l; }

        static string Build(DateTime nowUtc, bool fake)
        {
            TimeZoneInfo tz = TimeZoneInfo.Local;
            DateTime nowLocal = TimeZoneInfo.ConvertTimeFromUtc(nowUtc, tz);
            DateTime today = nowLocal.Date;
            // this weekend only: on Sunday there is just today; on Saturday today and tomorrow; otherwise the coming Saturday and Sunday
            DateTime sat = today.DayOfWeek == DayOfWeek.Sunday ? today.AddDays(-1) : today.AddDays((int)DayOfWeek.Saturday - (int)today.DayOfWeek), sun = sat.AddDays(1);
            int evening; if (!int.TryParse(Pv("evening"), out evening) || evening < 0 || evening > 23) evening = 18;

            StringBuilder sb = new StringBuilder("{\"ready\":true");
            sb.Append(",\"now\":").Append(Json_.S(Iso(nowUtc))).Append(",\"fake\":").Append(fake ? "true" : "false");
            sb.Append(",\"tz\":").Append(Json_.S(tz.StandardName));
            if (series.Count == 0 || owned == null)
            {
                sb.Append(",\"loaded\":false,\"msg\":").Append(Json_.S(series.Count == 0 ? "No schedule yet" : "Loading"));
                sb.Append(",\"days\":[],\"deck\":[],\"next\":null}");
                return sb.ToString();
            }

            string road = Pv("road").Length > 0 ? OfficialCore.LicLetter(Pv("road")) : OfficialCore.LicLetter(careerLic);
            string oval = OfficialCore.LicLetter(Pv("oval")), dirt = OfficialCore.LicLetter(Pv("dirt"));
            if (oval.Length == 0) oval = "R";
            if (dirt.Length == 0) dirt = "R";                       // not known: assume Rookie (shows only series a Rookie can enter)
            OfficialCore.Query q = new OfficialCore.Query(); q.Owned = owned; q.RoadLic = road; q.OvalLic = oval; q.DirtLic = dirt; q.Favs = FavKeys();
            HashSet<string> his = OfficialCore.HisSeriesKeys(favNames, careerSessions, nowUtc);

            DateTime lastDayEnd = TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(sun.AddDays(1), DateTimeKind.Unspecified), tz);
            DateTime to = nowUtc.AddDays(8) > lastDayEnd ? nowUtc.AddDays(8) : lastDayEnd;
            OfficialCore.Why why = new OfficialCore.Why();
            List<OfRace> races = OfficialCore.Upcoming(series, q, nowUtc, to, why);

            // one entry per series (and day): the first start after `from`, how many more that day, how it repeats
            Dictionary<string, OfPattern> pats = new Dictionary<string, OfPattern>();
            Func<OfSeries, OfPattern> pat = delegate (OfSeries s) { OfPattern p; if (!pats.TryGetValue(s.Id, out p)) { p = OfficialCore.ParsePattern(s.Freq); pats[s.Id] = p; } return p; };
            Func<OfSeries, bool> isFam = delegate (OfSeries s) { foreach (string c in s.Cars) if (familiar.Contains(OfficialCore.Norm(c))) return true; return OfficialCore.IsHisSeries(s, his); };

            List<List<Row>> dayRows = new List<List<Row>>();
            List<DateTime> dayDates = new List<DateTime>(); List<string> dayKeys = new List<string>(), dayLabels = new List<string>();
            dayDates.Add(today); dayKeys.Add("today"); dayLabels.Add("Today");
            if (sat > today) { dayDates.Add(sat); dayKeys.Add("saturday"); dayLabels.Add("Saturday"); }
            if (sun > today) { dayDates.Add(sun); dayKeys.Add("sunday"); dayLabels.Add("Sunday"); }
            if (today == sat) { dayLabels[0] = "Today"; }
            for (int di = 0; di < dayDates.Count; di++)
            {
                DateTime ds = TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(dayDates[di], DateTimeKind.Unspecified), tz), de = TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(dayDates[di].AddDays(1), DateTimeKind.Unspecified), tz);
                DateTime from = di == 0 ? nowUtc : ds.AddHours(evening);       // later days start from the evening hour: every series races all day
                if (di > 0 && from < ds) from = ds;
                Dictionary<string, Row> by = new Dictionary<string, Row>(); List<Row> rows = new List<Row>();
                foreach (OfRace r in races)
                {
                    if (r.Utc < ds || r.Utc >= de) continue;
                    if (his.Count > 0 && !OfficialCore.IsHisSeries(r.S, his)) continue;
                    Row row;
                    if (!by.TryGetValue(r.S.Id, out row)) { row = new Row(); row.R = null; by[r.S.Id] = row; rows.Add(row); }
                    if (r.Utc >= from) { if (row.R == null) row.R = r; row.N++; }
                }
                // nothing at/after the evening hour (a once-a-day series): use the day's first start
                foreach (OfRace r in races)
                {
                    if (r.Utc < ds || r.Utc >= de) continue;
                    if (his.Count > 0 && !OfficialCore.IsHisSeries(r.S, his)) continue;
                    Row row = by[r.S.Id];
                    if (row.R == null) { row.R = r; row.N = 1; }
                }
                rows.RemoveAll(delegate (Row x) { return x.R == null; });
                foreach (Row x in rows)
                {
                    x.Fav = q.Favs.Contains(x.R.S.Key); x.Fam = isFam(x.R.S); x.Pat = pat(x.R.S);
                    List<string> mine = OfficialCore.OwnedCarsOf(x.R.S, x.R.W, owned);
                    x.CarCount = mine.Count; x.Car = mine.Count > 0 ? mine[0] : "";
                    foreach (string c in mine) if (familiar.Contains(OfficialCore.Norm(c))) { x.Car = c; break; }
                }
                rows.Sort(delegate (Row a, Row b)
                {
                    if (a.Fav != b.Fav) return a.Fav ? -1 : 1;
                    if (a.Fam != b.Fam) return a.Fam ? -1 : 1;
                    int c = a.R.Utc.CompareTo(b.R.Utc); if (c != 0) return c;
                    return string.Compare(a.R.S.Short, b.R.S.Short, StringComparison.OrdinalIgnoreCase);
                });
                dayRows.Add(rows);
            }

            // the top favourite's next race (countdown in the idle header)
            OfRace nextFav = null;
            foreach (OfRace r in races) if (q.Favs.Contains(r.S.Key)) { nextFav = r; break; }

            bool weekend = (nowLocal.DayOfWeek == DayOfWeek.Friday && nowLocal.Hour >= 17) || nowLocal.DayOfWeek == DayOfWeek.Saturday || nowLocal.DayOfWeek == DayOfWeek.Sunday;
            DateTime end = DateTime.MinValue; foreach (OfSeries s in series) foreach (OfWeek w in s.Weeks) if (w.Start.AddDays(7) > end) end = w.Start.AddDays(7);
            bool endsSoon = end != DateTime.MinValue && nowUtc >= end;

            sb.Append(",\"loaded\":true,\"view\":").Append(Json_.S(weekend ? "weekend" : "today"));
            sb.Append(",\"asOfUtc\":").Append(Json_.S(Iso(fake ? nowUtc : (snapBuilt == DateTime.MinValue ? DateTime.UtcNow : snapBuilt))));
            sb.Append(",\"season\":{\"name\":").Append(Json_.S(seasonName)).Append(",\"ends\":").Append(Json_.S(end == DateTime.MinValue ? "" : end.ToString("yyyy-MM-dd", Inv))).Append(",\"over\":").Append(endsSoon ? "true" : "false")
              .Append(",\"source\":").Append(Json_.S("iRacing's published season schedule")).Append(",\"loadedUtc\":").Append(Json_.S(seasonImported == DateTime.MinValue ? "" : Iso(seasonImported))).Append("}");
            sb.Append(",\"licence\":{\"road\":").Append(Json_.S(road)).Append(",\"oval\":").Append(Json_.S(oval)).Append(",\"dirt\":").Append(Json_.S(dirt)).Append(",\"ovalKnown\":").Append(Pv("oval").Length > 0 ? "true" : "false").Append(",\"dirtKnown\":").Append(Pv("dirt").Length > 0 ? "true" : "false").Append("}");
            sb.Append(",\"owned\":{\"cars\":").Append(owned.CarFolders.Count).Append(",\"tracks\":").Append(owned.TrackFolders.Count).Append(",\"unknownCars\":").Append(owned.UnknownCars.Count).Append(",\"unknownTracks\":").Append(owned.UnknownTracks.Count).Append("}");
            sb.Append(",\"left\":{\"series\":").Append(why.Total).Append(",\"noTimes\":").Append(why.NoTimes).Append(",\"noCar\":").Append(why.NoCar).Append(",\"noTrack\":").Append(why.NoTrack).Append(",\"licence\":").Append(why.Licence).Append("}");
            sb.Append(",\"favCount\":").Append(favNames.Count).Append(",\"open\":").Append(DateTime.UtcNow < openUntil ? "true" : "false");
            sb.Append(",\"next\":").Append(nextFav == null ? "null" : RaceJson(nextFav, null, q, pat(nextFav.S), owned, isFam, 0, nowUtc, tz));
            // special events from today to three weeks ahead (dates only)
            List<Special> soon = specials.FindAll(delegate (Special s) { return s.To >= today && s.From <= today.AddDays(21) && (s.Track.Length == 0 || OfficialCore.OwnsTrack(owned, s.Track)); });   // only ones at tracks he owns
            soon.Sort(delegate (Special a, Special b) { bool oa = OfficialCore.OwnsTrack(owned, a.Track), ob = OfficialCore.OwnsTrack(owned, b.Track); if (oa != ob) return oa ? -1 : 1; return a.From.CompareTo(b.From); });
            sb.Append(",\"events\":[");
            for (int i = 0; i < soon.Count; i++)
            {
                Special s = soon[i]; if (i > 0) sb.Append(',');
                string when = s.From.Date == s.To.Date ? s.From.ToString("d MMM", Inv) : (s.From.Month == s.To.Month ? s.From.Day + "-" + s.To.ToString("d MMM", Inv) : s.From.ToString("d MMM", Inv) + " - " + s.To.ToString("d MMM", Inv));
                sb.Append("{\"name\":" + Json_.S(s.Name) + ",\"when\":" + Json_.S(when) + ",\"car\":" + Json_.S(s.Car) + ",\"track\":" + Json_.S(TinyTrack(s.Track)) + ",\"ownsTrack\":" + (s.Track.Length == 0 || OfficialCore.OwnsTrack(owned, s.Track) ? "true" : "false") + "}");
            }
            sb.Append("]");
            sb.Append(",\"days\":[");
            for (int di = 0; di < dayRows.Count; di++)
            {
                if (di > 0) sb.Append(',');
                sb.Append("{\"key\":").Append(Json_.S(dayKeys[di])).Append(",\"label\":").Append(Json_.S(dayLabels[di]))
                  .Append(",\"date\":").Append(Json_.S(dayDates[di].ToString("dddd d MMMM", Inv))).Append(",\"total\":").Append(dayRows[di].Count).Append(",\"rows\":[");
                int k = 0;
                foreach (Row x in dayRows[di]) { if (k >= 14) break; if (k++ > 0) sb.Append(','); sb.Append(RaceJson(x.R, x, q, x.Pat, owned, isFam, x.N, nowUtc, tz)); }
                sb.Append("]}");
            }
            sb.Append("]");

            // the OFFICIAL deck screen: every enterable series once, with its next start in the coming week
            sb.Append(",\"deck\":[");
            Dictionary<string, bool> seen = new Dictionary<string, bool>(); List<OfRace> first = new List<OfRace>();
            foreach (OfRace r in races) { if (his.Count > 0 && !OfficialCore.IsHisSeries(r.S, his)) continue; if (seen.ContainsKey(r.S.Id)) continue; seen[r.S.Id] = true; first.Add(r); }
            first.Sort(delegate (OfRace a, OfRace b)
            {
                bool fa = q.Favs.Contains(a.S.Key), fb = q.Favs.Contains(b.S.Key);
                if (fa != fb) return fa ? -1 : 1;
                bool ma = isFam(a.S), mb = isFam(b.S);
                if (ma != mb) return ma ? -1 : 1;
                return a.Utc.CompareTo(b.Utc);
            });
            for (int i = 0; i < first.Count && i < 40; i++) { if (i > 0) sb.Append(','); sb.Append(RaceJson(first[i], null, q, pat(first[i].S), owned, isFam, 0, nowUtc, tz)); }
            sb.Append("],\"deckTotal\":").Append(first.Count).Append("}");
            return sb.ToString();
        }

        // row fields: id, series, tiny, fav, mine, t (UTC ISO), est, more, pattern, every, car, carShort, carsOwned,
        // track, trackShort, layout, len, lic, licName, week, ownedCar, ownedTrack, localStart (yyyy-MM-dd HH:mm local), countdownSeconds (>=0), cadence
        static string RaceJson(OfRace r, Row row, OfficialCore.Query q, OfPattern p, OfficialCore.OwnedMap o, Func<OfSeries, bool> isFam, int n, DateTime nowUtc, TimeZoneInfo tz)
        {
            List<string> mine = OfficialCore.OwnedCarsOf(r.S, r.W, o);
            string car = row != null && row.Car.Length > 0 ? row.Car : (mine.Count > 0 ? mine[0] : "");
            foreach (string c in mine) if (familiar.Contains(OfficialCore.Norm(c))) { car = c; break; }
            bool fav = q.Favs.Contains(r.S.Key);
            bool ownedCar = mine.Count > 0;
            bool ownedTrack = OfficialCore.OwnsTrack(o, r.W.Track);
            int cd = OfficialCore.CountdownSeconds(r.Utc, nowUtc, tz);
            return "{\"id\":" + Json_.S(r.S.Id) + ",\"series\":" + Json_.S(r.S.Short) + ",\"tiny\":" + Json_.S(TinySeries(r.S.Short)) + ",\"fav\":" + (fav ? "true" : "false") + ",\"mine\":" + (isFam(r.S) ? "true" : "false") +
                   ",\"t\":" + Json_.S(Iso(r.Utc)) + ",\"est\":" + (r.Est ? "true" : "false") + ",\"more\":" + Math.Max(0, n - 1) + ",\"pattern\":" + Json_.S(OfficialCore.PatternShort(p)) + ",\"every\":" + Json_.S(OfficialCore.PatternTiny(p)) +
                   ",\"car\":" + Json_.S(car) + ",\"carShort\":" + Json_.S(TinyCar(car)) + ",\"carsOwned\":" + mine.Count +
                   ",\"track\":" + Json_.S(r.W.Track) + ",\"trackShort\":" + Json_.S(TinyTrack(r.W.Track)) + ",\"layout\":" + Json_.S(r.W.Layout) +
                   ",\"len\":" + Json_.S(r.W.Length) + ",\"lic\":" + Json_.S(r.S.Lic) + ",\"licName\":" + Json_.S(LicWord(r.S.Lic)) + ",\"week\":" + r.W.N +
                   ",\"ownedCar\":" + (ownedCar ? "true" : "false") + ",\"ownedTrack\":" + (ownedTrack ? "true" : "false") +
                   ",\"localStart\":" + Json_.S(OfficialCore.LocalStart(r.Utc, tz)) + ",\"countdownSeconds\":" + cd + ",\"cadence\":" + Json_.S(p != null && p.Ok ? OfficialCore.PatternShort(p) : "") + "}";
        }

        // ---- short names for the small deck keys ----
        static readonly string[] Brands = { "Chevrolet", "Ford", "Toyota", "Porsche", "Ferrari", "Mercedes-AMG", "Audi", "McLaren", "Lamborghini", "Aston Martin", "Acura", "Cadillac", "Dallara", "Honda", "Hyundai",
            "Global Mazda", "Mazda", "Nissan", "Subaru", "Volkswagen", "Lotus", "Pontiac", "Radical", "Renault", "Ruf", "Skip Barber", "Williams", "Ligier", "Kia", "BMW", "Supercars", "NASCAR" };
        static readonly string[] TrackTail = { "International", "Raceway", "Circuit", "Speedway", "Motorsports", "Motorsport", "Park", "Motor", "Racing" };

        static string TinyCar(string full)
        {
            string s = Regex.Replace(full ?? "", @"\s*\([^)]*\)", "").Trim();
            foreach (string b in Brands) if (s.StartsWith(b + " ", StringComparison.OrdinalIgnoreCase) && s.Length - b.Length - 1 >= 4) { s = s.Substring(b.Length + 1); break; }
            return s;
        }
        static string TinyTrack(string full)
        {
            List<string> words = new List<string>((full ?? "").Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries));
            while (words.Count > 1 && Array.Exists(TrackTail, delegate (string t) { return t.Equals(words[words.Count - 1], StringComparison.OrdinalIgnoreCase); })) words.RemoveAt(words.Count - 1);
            return string.Join(" ", words.ToArray());
        }
        static string TinySeries(string full)
        {
            string s = Regex.Replace(full ?? "", @"\s+by\s+.*$", "");
            s = Regex.Replace(s, @"\b(Series|Challenge|Cup)\b", "$1");
            return s.Trim();
        }
    }
}
