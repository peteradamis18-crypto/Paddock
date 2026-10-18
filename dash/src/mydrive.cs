// My Drive (WS3 in docs\SPEC-next.md): Peter's own car/track picker on the Stream Deck.
// irdash side: /mydrive JSON for the add-on and the top screen, and the whitelisted MY DRIVE key presses
// (routed here from /api/do). The work itself is done by irdeck ("mydrive ..." commands, src\mydrive.cs), one at a
// time per lane: quick state changes (a pick, the star, damage) never wait behind a slow search or a START.
// Everything is in <root>\mydrive: state.ini, favourites.ini, results.json (irdeck writes, irdash only reads).
// Owned by the deck workstream; irdash.cs only calls Init / Handles / Do / Json.
using System;
using System.Collections;
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
    static class MyDrive
    {
        static string dir;   // <root>\mydrive (favourites, search results, state written by irdeck)
        static string rootDir;
        static readonly HashSet<string> Commands = new HashSet<string> {
            "mdopen", "mdclose", "mddraft", "mdpick", "mdstar", "mddamage", "mdclear", "mdfindcar", "mdfindtrack", "mdfindlayout",
            "mdstart", "mdcancel", "mdgetout", "mdtow", "mdspeedtest" };

        public static void Init(string d)
        {
            dir = d; rootDir = Path.GetDirectoryName(d);
            try { Directory.CreateDirectory(dir); } catch { }
        }
        public static bool Handles(string c) { return Commands.Contains(c ?? ""); }

        // ---- run irdeck one command at a time, in two lanes ----
        sealed class Lane
        {
            readonly Queue<string[]> q = new Queue<string[]>();   // { arguments, label }
            bool working; Process current; public string Label = ""; int timeoutMs;
            public Lane(int timeoutMs) { this.timeoutMs = timeoutMs; }
            public bool Busy { get { lock (q) return working || q.Count > 0; } }
            public bool Has(string label) { lock (q) { if (working && Label == label) return true; foreach (string[] s in q) if (s[1] == label) return true; return false; } }

            public void Add(string args, string label)
            {
                if (Watch.IrdeckPath == null || !File.Exists(Watch.IrdeckPath)) { Log.W("mydrive: irdeck.exe not found"); return; }
                lock (q)
                {
                    q.Enqueue(new[] { args, label });
                    if (working) return;
                    working = true;
                }
                Thread t = new Thread(Work); t.IsBackground = true; t.Start();
            }

            // stops what is running and drops what is waiting
            public void Cancel()
            {
                Process p;
                lock (q) { q.Clear(); p = current; }
                try { if (p != null && !p.HasExited) p.Kill(); } catch { }
            }

            void Work()
            {
                while (true)
                {
                    string[] job;
                    lock (q) { if (q.Count == 0) { working = false; Label = ""; return; } job = q.Dequeue(); Label = job[1]; }
                    try
                    {
                        ProcessStartInfo psi = new ProcessStartInfo(Watch.IrdeckPath, job[0]);
                        psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(Watch.IrdeckPath);
                        using (Process p = Process.Start(psi))
                        {
                            lock (q) current = p;
                            if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } Log.W("mydrive: '" + job[0] + "' took too long"); }
                            lock (q) current = null;
                        }
                    }
                    catch (Exception ex) { Log.W("mydrive: '" + job[0] + "': " + ex.Message); }
                }
            }
        }
        static readonly Lane fast = new Lane(90000);        // pick, star, damage, clear, get out, tow. Tow may wait 20 s for the car to stop, then do the old reset.
        static readonly Lane slow = new Lane(900000);       // search (Test Drive lists) and START (the sim can take minutes to load)
        static readonly object startGate = new object();    // START admission and its enqueue must be one decision

        // what the screens know about the deck screen: open (top screen shows its card), the name being typed, speed test
        static DateTime openUntil = DateTime.MinValue;
        static string draftKind, draftText;
        static int speedSeq; static string speedWhich = "";

        static readonly Regex IdRx = new Regex("^[rctlfs][0-9a-f]{8}$");
        static readonly Regex TextRx = new Regex("^[A-Za-z0-9 -]{1,24}$");

        // A press on the MY DRIVE screen. Whitelisted; every argument is checked before it reaches irdeck.
        public static bool Do(string c, string a)
        {
            a = (a ?? "").Trim();
            switch (c)
            {
                case "mdopen": openUntil = DateTime.UtcNow.AddMinutes(3); return true;   // the add-on repeats this every minute while the screen is up
                case "mdclose": openUntil = DateTime.MinValue; draftKind = draftText = null; return true;
                case "mddraft":
                    {
                        // "car:COR" while typing, empty when done or cancelled
                        if (a.Length == 0) { draftKind = draftText = null; return true; }
                        Match m = Regex.Match(a, "^(car|track):([A-Za-z0-9 -]{0,24})$");
                        if (!m.Success) return false;
                        draftKind = m.Groups[1].Value; draftText = m.Groups[2].Value.ToUpperInvariant();
                        openUntil = DateTime.UtcNow.AddMinutes(3);
                        return true;
                    }
                case "mdpick":
                    if (!IdRx.IsMatch(a)) return false;
                    lock (startGate) { if (slow.Has("start")) return false; fast.Add("mydrive pick " + a, "pick"); return true; }
                case "mdstar": fast.Add("mydrive star", "star"); return true;
                case "mddamage":
                    lock (startGate) { if (slow.Has("start")) return false; fast.Add("mydrive damage", "damage"); return true; }
                case "mdclear": fast.Add("mydrive clear", "clear"); return true;
                case "mdfindcar": case "mdfindtrack":
                    if (!TextRx.IsMatch(a) || Program.IsDriving) return false;
                    slow.Add("mydrive find " + (c == "mdfindcar" ? "car" : "track") + " \"" + a + "\"", "find");
                    draftKind = draftText = null;
                    return true;
                case "mdfindlayout": if (Program.IsDriving) return false; slow.Add("mydrive find layout", "find"); return true;
                case "mdstart":
                    if (Program.IsDriving) return true;                          // already in the car: nothing to do
                    lock (startGate)
                    {
                        if (!slow.Has("start")) slow.Add("mydrive start --at " + DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture), "start");
                        return true;
                    }
                case "mdcancel": slow.Cancel(); return true;
                case "mdgetout": fast.Add("getout", "getout"); return true;
                case "mdtow": if (!fast.Has("tow")) fast.Add("tow", "tow"); return true;   // a second press while one is waiting does nothing
                case "mdspeedtest":
                    // tests\deck-speed-test.ps1 -Live: the add-on opens that screen once, times it, and goes back (never while driving)
                    if (!Regex.IsMatch(a, "^(friends|overlays|mydrive)$") || Program.IsDriving) return false;
                    speedWhich = a; speedSeq++;
                    return true;
            }
            return false;
        }

        // ---- files ----
        static Dictionary<string, string> State()
        {
            var st = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string f = Path.Combine(dir, "state.ini");
                if (File.Exists(f)) foreach (string l in File.ReadAllLines(f)) { int e = l.IndexOf('='); if (e > 0) st[l.Substring(0, e)] = l.Substring(e + 1); }
            }
            catch { }
            return st;
        }
        static string Sv(Dictionary<string, string> st, string k) { string v; return st.TryGetValue(k, out v) ? v : ""; }

        sealed class Combo { public string Car = "", Track = "", Layout = "", Id = ""; public DateTime When; public int Count; }   // Count: how many drives of 30 s or more (USUAL on the deck)

        // same hash as irdeck's MdId: r = recent drive, f = favourite, s = search result
        static string Id(char kind, string text)
        {
            uint h = 2166136261u;
            foreach (char c in (text ?? "").ToLowerInvariant()) { h ^= c; h = unchecked(h * 16777619u); }
            return kind + h.ToString("x8", CultureInfo.InvariantCulture);
        }

        static List<Combo> Favs()
        {
            var list = new List<Combo>();
            try
            {
                string f = Path.Combine(dir, "favourites.ini");
                if (!File.Exists(f)) return list;
                foreach (string raw in File.ReadAllLines(f))
                {
                    string l = raw.Trim();
                    if (l.Length == 0 || l.StartsWith(";") || l.StartsWith("#")) continue;
                    string[] p = l.Split('|');
                    if (p.Length < 2) continue;
                    Combo c = new Combo(); c.Car = p[0].Trim(); c.Track = p[1].Trim(); c.Layout = p.Length > 2 ? p[2].Trim() : "";
                    if (c.Car.Length == 0 || c.Track.Length == 0) continue;
                    c.Id = Id('f', c.Car + "|" + c.Track + "|" + c.Layout);
                    list.Add(c);
                }
            }
            catch { }
            return list;
        }

        // the last distinct car + track pairs you drove for 30 s or more (dash\career-cache.tsv, read only; irdash's Career writes it)
        static DateTime recStamp; static List<Combo> recCache = new List<Combo>();
        static List<Combo> Recents(int max)
        {
            string f = Path.Combine(rootDir, @"dash\career-cache.tsv");
            try
            {
                DateTime stamp = File.Exists(f) ? File.GetLastWriteTimeUtc(f) : DateTime.MinValue;
                if (stamp == recStamp && stamp != DateTime.MinValue) return recCache.Count > max ? recCache.GetRange(0, max) : recCache;
                var map = new Dictionary<string, Combo>(StringComparer.OrdinalIgnoreCase);
                if (stamp != DateTime.MinValue)
                    using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (var sr = new StreamReader(fs, Encoding.UTF8))
                    {
                        string line;
                        while ((line = sr.ReadLine()) != null)
                        {
                            string[] p = line.Split('\t');
                            if (p.Length < 13) continue;
                            double secs; long ticks;
                            if (!double.TryParse(p[2], NumberStyles.Float, CultureInfo.InvariantCulture, out secs) || secs < 30 || !long.TryParse(p[1], out ticks)) continue;
                            string car = p[6].Trim(), track = p[7].Trim();
                            if (car.Length == 0 || track.Length == 0) continue;
                            DateTime when = new DateTime(ticks, DateTimeKind.Utc); Combo c;
                            if (!map.TryGetValue(car + "|" + track, out c)) { c = new Combo(); c.Car = car; c.Track = track; c.When = when; c.Id = Id('r', car + "|" + track); map[car + "|" + track] = c; }
                            else if (when > c.When) c.When = when;
                            c.Count++;
                        }
                    }
                var list = new List<Combo>(map.Values);
                list.Sort(delegate (Combo x, Combo y) { return y.When.CompareTo(x.When); });
                recCache = list; recStamp = stamp;
            }
            catch (Exception ex) { Log.W("mydrive: career cache: " + ex.Message); }
            return recCache.Count > max ? recCache.GetRange(0, max) : recCache;
        }

        // ---- short names for the small deck keys ----
        static readonly string[] Brands = { "Chevrolet", "Ford", "Toyota", "Porsche", "Ferrari", "Mercedes-AMG", "Audi", "McLaren", "Lamborghini", "Aston Martin", "Acura",
            "Cadillac", "Dallara", "Honda", "Hyundai", "Global Mazda", "Mazda", "Nissan", "Subaru", "Volkswagen", "Lotus", "Pontiac", "Radical", "Renault", "Ruf", "Skip Barber", "Williams", "Ligier", "Kia" };
        static readonly string[] TrackTail = { "International", "Raceway", "Circuit", "Speedway", "Motorsports", "Motorsport", "Park", "Motor" };
        static DateTime iniStamp; static Dictionary<string, string> carShort = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase), trackShort = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        // friends mode's own short names (guest.ini [cars] / [tracks]: short | exact iRacing name | ...) win over the rules
        static void LoadShort()
        {
            try
            {
                string f = Path.Combine(rootDir, @"guest\guest.ini");
                if (!File.Exists(f)) return;
                DateTime st = File.GetLastWriteTimeUtc(f);
                if (st == iniStamp) return;
                iniStamp = st; carShort.Clear(); trackShort.Clear();
                string sec = "";
                foreach (string raw in File.ReadAllLines(f))
                {
                    string l = raw.Trim();
                    if (l.Length == 0 || l.StartsWith(";")) continue;
                    if (l.StartsWith("[") && l.EndsWith("]")) { sec = l.Substring(1, l.Length - 2).Trim().ToLowerInvariant(); continue; }
                    int e = l.IndexOf('='); if (e <= 0 || (sec != "cars" && sec != "tracks")) continue;
                    string[] p = l.Substring(e + 1).Split('|');
                    if (p.Length < 2 || p[1].Trim().Length == 0) continue;
                    (sec == "cars" ? carShort : trackShort)[p[1].Trim()] = p[0].Trim();
                }
            }
            catch { }
        }

        static string ShortCar(string full)
        {
            LoadShort(); string s;
            string exact = (full ?? "").Trim();
            if (exact.Equals("Chevrolet Corvette Z06 GT3.R", StringComparison.OrdinalIgnoreCase)) return "CORVETTE";
            if (exact.Equals("Ferrari 296 GT3", StringComparison.OrdinalIgnoreCase)) return "FERRARI";
            if (carShort.TryGetValue(full ?? "", out s)) return s;
            s = Regex.Replace(full ?? "", @"\s*\([^)]*\)", "").Trim();
            foreach (string b in Brands)
                if (s.StartsWith(b + " ", StringComparison.OrdinalIgnoreCase) && s.Length - b.Length - 1 >= 4) { s = s.Substring(b.Length + 1); break; }
            return s;
        }

        static string ShortTrack(string full)
        {
            LoadShort(); string s;
            if (trackShort.TryGetValue(full ?? "", out s)) return s;
            string exact = (full ?? "").Trim();
            if (exact.Equals("Road Atlanta", StringComparison.OrdinalIgnoreCase)) return "ROAD ATLANTA";
            if (exact.Equals("Sebring International Raceway", StringComparison.OrdinalIgnoreCase)) return "SEBRING";
            if (exact.Equals("Tsukuba Circuit", StringComparison.OrdinalIgnoreCase)) return "TSUKUBA";
            var words = new List<string>((full ?? "").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries));
            while (words.Count > 1 && Array.Exists(TrackTail, delegate (string t) { return t.Equals(words[words.Count - 1], StringComparison.OrdinalIgnoreCase); })) words.RemoveAt(words.Count - 1);
            return string.Join(" ", words.ToArray());
        }

        // one "key: value" line (an empty value stays empty: TrackMaps.YamlValue would read on into the next line)
        static string Yaml(string yaml, string key)
        {
            Match m = Regex.Match(yaml, "^[ \\t]*" + key + ":[ \\t]*([^\\r\\n]*?)[ \\t]*$", RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value.Trim('"') : "";
        }

        // ---- the combo of the session that is running now ----
        static int curVersion = -1; static Combo cur;
        static Combo Current()
        {
            Frame f = Sdk.Latest;
            if (!f.Connected || string.IsNullOrEmpty(f.SessionYaml)) { cur = null; curVersion = -1; return null; }
            if (f.SessionVersion == curVersion) return cur;
            curVersion = f.SessionVersion;
            string y = f.SessionYaml; Combo c = new Combo();
            c.Track = Yaml(y, "TrackDisplayName"); c.Layout = Yaml(y, "TrackConfigName");
            string me = Yaml(y, "DriverCarIdx");
            Match block = Regex.Match(y, "- CarIdx: " + Regex.Escape(me) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
            if (me.Length > 0 && block.Success) c.Car = Yaml(block.Groups[1].Value, "CarScreenName");
            cur = c.Car.Length > 0 && c.Track.Length > 0 ? c : null;
            return cur;
        }

        static bool Same(Combo a, Combo b, bool layout)
        {
            return string.Equals(a.Car, b.Car, StringComparison.OrdinalIgnoreCase) && string.Equals(a.Track, b.Track, StringComparison.OrdinalIgnoreCase)
                && (!layout || string.Equals(a.Layout, b.Layout, StringComparison.OrdinalIgnoreCase));
        }

        static string Ago(DateTime utc)
        {
            int days = (DateTime.Today - utc.ToLocalTime().Date).Days;
            return days <= 0 ? "today" : days == 1 ? "yesterday" : days < 7 ? utc.ToLocalTime().ToString("dddd", CultureInfo.InvariantCulture) : days + " days ago";
        }

        static string ComboJson(Combo c, bool withLayout, string extra)
        {
            return "{\"id\":" + Json_.S(c.Id) + ",\"car\":" + Json_.S(c.Car) + ",\"carShort\":" + Json_.S(ShortCar(c.Car)) + ",\"track\":" + Json_.S(c.Track) +
                   ",\"trackShort\":" + Json_.S(ShortTrack(c.Track)) + (withLayout ? ",\"layout\":" + Json_.S(c.Layout) : "") + extra + "}";
        }

        // The picker catalog comes from Career's cache, which only contains .ibt headers read while the sim was free.
        static DateTime listsStamp = DateTime.MinValue; static string listsJsonCached;
        public static string ListsJson()
        {
            try
            {
                string cacheFile = Path.Combine(rootDir, @"dash\career-cache.tsv");
                DateTime currentStamp = File.Exists(cacheFile) ? File.GetLastWriteTimeUtc(cacheFile) : DateTime.MinValue;
                if (listsJsonCached != null && currentStamp == listsStamp) return listsJsonCached;
                List<Combo> all = Recents(Int32.MaxValue);
                List<string> recent = new List<string>(), cars = new List<string>(), tracks = new List<string>();
                Dictionary<string, Combo> byCar = new Dictionary<string, Combo>(StringComparer.OrdinalIgnoreCase);
                Dictionary<string, Combo> byTrack = new Dictionary<string, Combo>(StringComparer.OrdinalIgnoreCase);
                Dictionary<string, HashSet<string>> layouts = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
                Dictionary<string, string> recentLayouts = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                Dictionary<string, long> recentLayoutTicks = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
                string file = cacheFile;
                try
                {
                    if (!Program.IsDriving && File.Exists(file))
                    using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (var sr = new StreamReader(fs, Encoding.UTF8))
                    {
                        string line;
                        while ((line = sr.ReadLine()) != null)
                        {
                            string[] p = line.Split('\t');
                            // column 16 = layout (TrackConfigName); 15 is the fuel-laps count (this used to read 15: layouts "0", "2", "10")
                            if (p.Length < 17 || p[7].Length == 0 || p[16].Length == 0) continue;
                            HashSet<string> set;
                            if (!layouts.TryGetValue(p[7], out set)) { set = new HashSet<string>(StringComparer.OrdinalIgnoreCase); layouts[p[7]] = set; }
                            set.Add(p[16]);
                            long ticks; long.TryParse(p[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out ticks);
                            string combo = p[6].Trim() + "|" + p[7].Trim(); long oldTicks;
                            if (p[16].Trim().Length > 0 && (!recentLayoutTicks.TryGetValue(combo, out oldTicks) || ticks > oldTicks)) { recentLayoutTicks[combo] = ticks; recentLayouts[combo] = p[16].Trim(); }
                        }
                    }
                }
                catch (Exception ex) { Log.W("mydrive lists: cache layouts: " + ex.Message); }
                int n = 0;
                foreach (Combo c in all)
                {
                    n++;
                    if (n <= 21) { string recentLayout; if (!recentLayouts.TryGetValue(c.Car + "|" + c.Track, out recentLayout)) recentLayout = ""; recent.Add("{\"id\":" + Json_.S(c.Id) + ",\"car\":" + Json_.S(c.Car) + ",\"carShort\":" + Json_.S(ShortCar(c.Car)) + ",\"track\":" + Json_.S(c.Track) + ",\"trackShort\":" + Json_.S(ShortTrack(c.Track)) + ",\"layout\":" + Json_.S(recentLayout) + ",\"last\":" + Json_.S(c.When.ToString("o", CultureInfo.InvariantCulture)) + ",\"count\":" + c.Count + "}"); }
                    if (!byCar.ContainsKey(c.Car)) byCar[c.Car] = c;
                    if (!byTrack.ContainsKey(c.Track)) byTrack[c.Track] = c;
                }
                List<Combo> carList = new List<Combo>(byCar.Values), trackList = new List<Combo>(byTrack.Values);
                carList.Sort(delegate (Combo x, Combo y) { return y.When.CompareTo(x.When); });
                trackList.Sort(delegate (Combo x, Combo y) { return y.When.CompareTo(x.When); });
                foreach (Combo c in carList)
                {
                    string cl = CarClass(c.Car);
                    int count = 0; foreach (Combo x in all) if (string.Equals(x.Car, c.Car, StringComparison.OrdinalIgnoreCase)) count += x.Count;
                    cars.Add("{\"id\":" + Json_.S(Id('c', c.Car)) + ",\"name\":" + Json_.S(c.Car) + ",\"short\":" + Json_.S(ShortCar(c.Car)) + ",\"class\":" + Json_.S(cl) + ",\"last\":" + Json_.S(c.When.ToString("o", CultureInfo.InvariantCulture)) + ",\"count\":" + count + "}");
                }
                foreach (Combo c in trackList)
                {
                    HashSet<string> ls; List<string> lj = new List<string>();
                    if (layouts.TryGetValue(c.Track, out ls)) foreach (string l in ls) lj.Add(Json_.S(l));
                    int count = 0; foreach (Combo x in all) if (string.Equals(x.Track, c.Track, StringComparison.OrdinalIgnoreCase)) count += x.Count;
                    tracks.Add("{\"id\":" + Json_.S(Id('t', c.Track)) + ",\"name\":" + Json_.S(c.Track) + ",\"short\":" + Json_.S(ShortTrack(c.Track)) + ",\"layouts\":[" + string.Join(",", lj.ToArray()) + "],\"last\":" + Json_.S(c.When.ToString("o", CultureInfo.InvariantCulture)) + ",\"count\":" + count + "}");
                }
                listsJsonCached = "{\"recent\":[" + string.Join(",", recent.ToArray()) + "],\"cars\":[" + string.Join(",", cars.ToArray()) + "],\"tracks\":[" + string.Join(",", tracks.ToArray()) + "]}";
                listsStamp = currentStamp;
                return listsJsonCached;
            }
            catch (Exception ex) { Log.W("mydrive lists: " + ex.Message); return "{\"recent\":[],\"cars\":[],\"tracks\":[]}"; }
        }

        static string CarClass(string car)
        {
            string s = (car ?? "").ToUpperInvariant();
            if (s.Contains("GT4")) return "GT4";
            if (s.Contains("GT3")) return "GT3";
            if (s.Contains("GTP") || s.Contains("LMDH") || s.Contains("LMP")) return "GTP";
            if (s.Contains("911 CUP") || s.Contains("PORSCHE CUP") || s.Contains("296 CHALLENGE") || s.Contains("FERRARI CHALLENGE")) return "CUP";
            if (s.Contains("GR86") || s.Contains("MX-5") || s.Contains("MIATA")) return "SPORTS";
            return "SPORTS";
        }

        // last search, as irdeck wrote it (parsed and written again so a half-written file can never break the page)
        static string ResultsJson()
        {
            try
            {
                string f = Path.Combine(dir, "results.json");
                if (!File.Exists(f)) return "null";
                Dictionary<string, object> r = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(f)) as Dictionary<string, object>;
                if (r == null) return "null";
                var items = new List<string>();
                foreach (object o in (IList)r["items"])
                {
                    Dictionary<string, object> it = o as Dictionary<string, object>;
                    if (it == null) continue;
                    string kind = Convert.ToString(r["kind"]), name = Convert.ToString(it["name"]);
                    items.Add("{\"id\":" + Json_.S(Convert.ToString(it["id"])) + ",\"name\":" + Json_.S(name) + ",\"short\":" + Json_.S(kind == "car" ? ShortCar(name) : kind == "track" ? ShortTrack(name) : name) + "}");
                }
                return "{\"kind\":" + Json_.S(Convert.ToString(r["kind"])) + ",\"q\":" + Json_.S(Convert.ToString(r["q"])) + ",\"at\":" + Json_.S(Convert.ToString(r["at"])) +
                       ",\"ok\":" + (Convert.ToBoolean(r["ok"]) ? "true" : "false") + ",\"msg\":" + Json_.S(Convert.ToString(r["msg"])) + ",\"items\":[" + string.Join(",", items.ToArray()) + "]}";
            }
            catch { return "null"; }
        }

        // MOST TO GAIN (RACE SETUP): the drive where his PB is furthest from his theoretical best (gain.cs works it out in the background, never while he
        // drives). Only a drive the pick can start: one of his recent drives, on the layout the pick would use. null until it is known or when there is none.
        static string GainJson(bool has, Combo ch)
        {
            try
            {
                Analysis.GainPoke(false);
                List<Analysis.GainRow> rows = Analysis.GainRows();
                if (rows == null || rows.Count == 0) return "null";
                HashSet<string> ids = new HashSet<string>();
                foreach (Combo r in Recents(200)) ids.Add(r.Id);
                foreach (Analysis.GainRow g in rows)
                {
                    if (g.Gap < Analysis.GainMin) break;             // sorted, biggest first
                    Combo c = new Combo(); c.Car = g.Car; c.Track = g.Track; c.Layout = g.Config; c.Id = Id('r', g.Car + "|" + g.Track);
                    if (!g.Newest || !ids.Contains(c.Id)) continue;
                    CultureInfo inv = CultureInfo.InvariantCulture;
                    return ComboJson(c, true, ",\"chosen\":" + (has && Same(c, ch, false) ? "true" : "false") + ",\"pb\":" + g.Pb.ToString("0.000", inv) +
                                              ",\"theoretical\":" + g.Theo.ToString("0.000", inv) + ",\"gap\":" + g.Gap.ToString("0.000", inv));
                }
            }
            catch (Exception ex) { Log.W("mydrive gain: " + ex.Message); }
            return "null";
        }

        public static string Json()
        {
            if (dir == null) return "{\"ready\":false}";
            try
            {
                CultureInfo inv = CultureInfo.InvariantCulture;
                Dictionary<string, string> st = State();
                Combo ch = new Combo(); ch.Car = Sv(st, "car"); ch.Track = Sv(st, "track"); ch.Layout = Sv(st, "layout");
                List<Combo> recents = Recents(7), favs = Favs();
                bool has = ch.Car.Length > 0 && ch.Track.Length > 0;
                if (!has && recents.Count > 0) { /* nothing chosen yet: START would use the newest recent drive */ }
                bool isFav = has && favs.Exists(delegate (Combo f) { return Same(f, ch, true); });
                string busy = slow.Busy ? (slow.Label == "start" ? "start" : "find") : "";
                bool open = DateTime.UtcNow < openUntil;
                StringBuilder sb = new StringBuilder("{\"ready\":true");
                string aiStatus = "";
                try { string af = Path.Combine(rootDir, @"mydrive\ai-status.txt"); if (File.Exists(af)) aiStatus = File.ReadAllText(af).Trim(); } catch { }
                sb.Append(",\"aiStatus\":").Append(Json_.S(aiStatus));
                sb.Append(",\"open\":").Append(open ? "true" : "false");
                sb.Append(",\"session\":").Append(Sdk.Latest.Connected ? "true" : "false");
                sb.Append(",\"driving\":").Append(Program.IsDriving ? "true" : "false");
                sb.Append(",\"busy\":").Append(Json_.S(busy));
                string phase = Sv(st, "phase"), msg = Sv(st, "msg"); long pt;
                long.TryParse(Sv(st, "phaseAt"), out pt);
                bool showPhase = busy == "start" || ((phase == "failed") && pt > 0 && (DateTime.UtcNow - new DateTime(pt, DateTimeKind.Utc)).TotalSeconds < 20);
                sb.Append(",\"phase\":").Append(Json_.S(showPhase ? phase : "")).Append(",\"msg\":").Append(Json_.S(showPhase ? msg : ""));
                sb.Append(",\"choice\":{\"has\":").Append(has ? "true" : "false")
                  .Append(",\"car\":").Append(Json_.S(ch.Car)).Append(",\"carShort\":").Append(Json_.S(ShortCar(ch.Car)))
                  .Append(",\"track\":").Append(Json_.S(ch.Track)).Append(",\"trackShort\":").Append(Json_.S(ch.Track.Length == 0 ? "CHOOSE" : ShortTrack(ch.Track)))
                  .Append(",\"layout\":").Append(Json_.S(ch.Layout)).Append(",\"damage\":").Append(Json_.S(Sv(st, "damage") == "off" ? "off" : "on"))
                  .Append(",\"fav\":").Append(isFav ? "true" : "false").Append("}");
                var rs = new List<string>();
                foreach (Combo r in recents) rs.Add(ComboJson(r, false, ",\"ago\":" + Json_.S(Ago(r.When)) + ",\"chosen\":" + (has && Same(r, ch, false) ? "true" : "false")));
                sb.Append(",\"recent\":[").Append(string.Join(",", rs.ToArray())).Append("]");
                var fs = new List<string>(); int fi = 0;
                foreach (Combo f in favs) { if (fi++ >= 12) break; fs.Add(ComboJson(f, true, ",\"chosen\":" + (has && Same(f, ch, true) ? "true" : "false"))); }
                sb.Append(",\"favs\":[").Append(string.Join(",", fs.ToArray())).Append("],\"favCount\":").Append(favs.Count);
                // every distinct drive (newest first, 60 at most) with its count: the RACE SETUP keys USUAL / SAME CAR / SAME TRACK / SURPRISE sort and filter these
                var all = new List<string>();
                foreach (Combo r in Recents(60)) all.Add(ComboJson(r, false, ",\"n\":" + r.Count + ",\"ago\":" + Json_.S(Ago(r.When)) + ",\"chosen\":" + (has && Same(r, ch, false) ? "true" : "false")));
                sb.Append(",\"all\":[").Append(string.Join(",", all.ToArray())).Append("]");
                sb.Append(",\"gain\":").Append(GainJson(has, ch));
                Combo c = Current();
                sb.Append(",\"current\":").Append(c == null ? "null" : ComboJson(c, true, ",\"fav\":" + (favs.Exists(delegate (Combo f) { return Same(f, c, true); }) ? "true" : "false")));
                sb.Append(",\"results\":").Append(ResultsJson());
                sb.Append(",\"draft\":").Append(draftText == null ? "null" : "{\"kind\":" + Json_.S(draftKind) + ",\"text\":" + Json_.S(draftText) + "}");
                long la; int ls; long.TryParse(Sv(st, "lastAt"), out la); int.TryParse(Sv(st, "lastSecs"), out ls);
                int seq; int.TryParse(Sv(st, "lastSeq"), out seq);
                if (la > 0) sb.Append(",\"last\":{\"secs\":").Append(ls).Append(",\"seq\":").Append(seq).Append(",\"age\":").Append(Math.Max(0, (int)(DateTime.UtcNow - new DateTime(la, DateTimeKind.Utc)).TotalSeconds))
                               .Append(",\"car\":").Append(Json_.S(Sv(st, "lastCar"))).Append(",\"track\":").Append(Json_.S(Sv(st, "lastTrack"))).Append("}");
                else sb.Append(",\"last\":null");
                sb.Append(",\"speedtest\":{\"seq\":").Append(speedSeq).Append(",\"which\":").Append(Json_.S(speedWhich)).Append("}");
                sb.Append("}");
                return sb.ToString();
            }
            catch (Exception ex) { Log.W("mydrive json: " + ex.Message); return "{\"ready\":false}"; }
        }
    }
}
