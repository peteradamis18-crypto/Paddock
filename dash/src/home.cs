// Paddock HOME (P1): the top screen when no session runs. Two routes, nothing else:
//   GET /home        one JSON: his name and number, the personal best at every track he has driven (iRacing's own best-lap figure of a
//                    session, the same rule the Sessions page uses: never a lap iRacing did not time), the last session, the hero picture
//                    and the phone's pairing state.
//   GET /home/hero   the hero picture. paddock\home\hero.jpg (the lead's own capture of HIS Corvette from a replay) wins the moment it
//                    exists; until then the newest of his own replay photos (paddock\gallery\mine), and as the stand-in the credited
//                    Corvette Z06 GT3.R photo the side-screen gallery already holds (CC BY 4.0, paddock\home\credits.json).
// The page (dash\www\v2\home.js) only draws while #overlay is shown, which ui.js hides the moment a session is live.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace IRDash
{
    static partial class Career
    {
        sealed class Pb { public string Track = "", Config = "", Car = "", File = ""; public double Best; public DateTime When, Latest; public int Sessions; }

        public static string HomeJson() { return HomeJson(true); }

        // full = false leaves out the hero picture and the phone block (tests\home-test.ps1 runs this over a pretend cache, with no server around)
        static string HomeJson(bool full)
        {
            lock (gate)
            {
                Load();
                var inv = CultureInfo.InvariantCulture;
                var pbs = new Dictionary<string, Pb>();
                var byCar = new Dictionary<string, double>();
                Rec last = null, lastAny = null, lastOuting = null, numRec = null;
                foreach (Rec r in recs.Values)
                {
                    if (r.Short) continue;      // PL-1: a test, or a Test Drive that sat in the pit box, is not an outing (Rec.Short)
                    if (lastAny == null || r.Date > lastAny.Date) lastAny = r;
                    if (r.Laps > 0 && (last == null || r.Date > last.Date)) last = r;
                    if (r.Laps > 0 && (lastOuting == null || r.Date > lastOuting.Date)) lastOuting = r; // an outing needs a completed lap
                    if (r.Car.Length > 0) { double v; byCar.TryGetValue(r.Car, out v); byCar[r.Car] = v + r.Secs; }
                    if (r.Track.Length == 0) continue;
                    string key = r.Track + "|" + r.Config;
                    Pb p; if (!pbs.TryGetValue(key, out p)) { p = new Pb(); p.Track = r.Track; p.Config = r.Config; pbs[key] = p; }
                    p.Sessions++;
                    if (r.Date > p.Latest) p.Latest = r.Date;
                    if (r.Best > 0 && (p.Best <= 0 || r.Best < p.Best)) { p.Best = r.Best; p.Car = r.Car; p.File = r.FileName; p.When = r.Date; }
                }
                if (last == null) last = lastAny;
                string topCar = ""; double tv = -1;
                foreach (var kv in byCar) if (kv.Value > tv) { tv = kv.Value; topCar = kv.Key; }
                // his number: the one on the car he drives most (the last session may have been a one-off in another car)
                foreach (Rec r in recs.Values)
                    if (r.Num.Length > 0 && (r.Car == topCar || topCar.Length == 0) && (numRec == null || r.Date > numRec.Date)) numRec = r;
                if (numRec == null) foreach (Rec r in recs.Values) if (r.Num.Length > 0 && (numRec == null || r.Date > numRec.Date)) numRec = r;

                List<Pb> list = new List<Pb>();
                foreach (Pb p in pbs.Values) if (p.Best > 0) list.Add(p);
                list.Sort(delegate (Pb a, Pb b) { return b.Latest.CompareTo(a.Latest); });   // the tracks he drives now first

                // PL-1: the car on HOME is the car of his last real session with laps, and the number box is that same car's number
                string meNum, meName; string meJ = MeCarJson(last, out meNum, out meName);
                StringBuilder sb = new StringBuilder("{\"name\":").Append(Json_.S(meName)).Append(",\"num\":").Append(Json_.S(meNum));
                sb.Append(",\"car\":").Append(Json_.S(topCar)).Append(",\"pbs\":[");
                for (int i = 0; i < list.Count && i < 8; i++)
                {
                    Pb p = list[i];
                    if (i > 0) sb.Append(',');
                    sb.Append("{\"track\":").Append(Json_.S(p.Track)).Append(",\"config\":").Append(Json_.S(p.Config)).Append(",\"car\":").Append(Json_.S(p.Car))
                      .Append(",\"best\":").Append(p.Best.ToString("0.000", inv)).Append(",\"date\":").Append(Json_.S(p.When.ToLocalTime().ToString("yyyy-MM-dd", inv)))
                      .Append(",\"ago\":").Append(Json_.S(AgoWord(p.When))).Append(",\"sessions\":").Append(p.Sessions).Append(",\"file\":").Append(Json_.S(p.File)).Append('}');
                }
                sb.Append("],\"pbCount\":").Append(list.Count);
                sb.Append(",\"last\":");
                if (last == null) sb.Append("null");
                else
                    sb.Append("{\"file\":").Append(Json_.S(last.FileName)).Append(",\"car\":").Append(Json_.S(last.Car)).Append(",\"track\":").Append(Json_.S(last.Track))
                      .Append(",\"config\":").Append(Json_.S(last.Config)).Append(",\"type\":").Append(Json_.S(last.SType.Length > 0 ? last.SType : last.Ev))
                      .Append(",\"laps\":").Append(last.Laps).Append(",\"best\":").Append(last.Best > 0 ? last.Best.ToString("0.000", inv) : "null")
                      .Append(",\"mins\":").Append(Math.Round(last.Secs / 60)).Append(",\"date\":").Append(Json_.S(last.Date.ToLocalTime().ToString("yyyy-MM-dd HH:mm", inv)))
                      .Append(",\"ago\":").Append(Json_.S(AgoWord(last.Date))).Append('}');
                // Reuse /career's exact week calculation and JSON contract.
                sb.Append(',').Append(WeekJson());
                // P0-04: finish and incidents are not in the cache; expose no guessed values.

                sb.Append(",\"lastOuting\":");
                if (lastOuting == null) sb.Append("null");
                else
                    sb.Append("{\"file\":").Append(Json_.S(lastOuting.FileName)).Append(",\"car\":").Append(Json_.S(lastOuting.Car)).Append(",\"track\":").Append(Json_.S(lastOuting.Track))
                      .Append(",\"config\":").Append(Json_.S(lastOuting.Config)).Append(",\"type\":").Append(Json_.S(lastOuting.SType.Length > 0 ? lastOuting.SType : lastOuting.Ev))
                      .Append(",\"laps\":").Append(lastOuting.Laps).Append(",\"best\":").Append(lastOuting.Best > 0 ? lastOuting.Best.ToString("0.000", inv) : "null")
                      .Append(",\"finish\":null")
                      .Append(",\"date\":").Append(Json_.S(lastOuting.Date.ToLocalTime().ToString("yyyy-MM-dd HH:mm", inv)))
                      .Append(",\"ago\":").Append(Json_.S(AgoWord(lastOuting.Date))).Append('}');
                sb.Append(",\"me\":").Append(meJ);
                if (full)
                {
                    sb.Append(",\"hero\":").Append(Home.HeroJson());
                    sb.Append(",\"phone\":").Append(Phone.InfoJson(Home.Port));
                }
                return sb.Append('}').ToString();
            }
        }

        // P4: his car in his own colours, from the session text at the top of his last real session's telemetry file (his own entry in DriverInfo: CarPath,
        // CarDesignStr, number, class colour). Read once per file (the header only, never the lap data) and kept; "null" when it cannot be read.
        static string meFile = "", meJson = "null", meNumber = "", meName = "";
        static string MeCarJson(Rec rec, out string num, out string name)
        {
            num = ""; name = "";
            if (rec == null || string.IsNullOrEmpty(TelemetryDir)) return "null";
            if (rec.FileName == meFile) { num = meNumber; name = meName; return meJson; }
            string json = "null", number = "", driverName = "";
            try
            {
                string path = Path.Combine(TelemetryDir, rec.FileName);
                FileInfo fi = new FileInfo(path);
                if (fi.Exists && !OnlineOnly(fi))
                {
                    TrackMaps.Ibt t = TrackMaps.OpenIbt(path, false);
                    if (t != null)
                        using (t.fs)
                        {
                            json = MeCarYamlJson(t.yaml, rec.FileName, out number, out driverName);
                        }
                }
            }
            catch (Exception ex) { Log.W("home: his car's livery: " + ex.Message); }
            meFile = rec.FileName; meJson = json; meNumber = number; meName = driverName;
            num = number; name = driverName;
            return json;
        }

        // Shared by the telemetry reader and the deterministic CLI fixture gate.
        internal static string MeCarYamlJson(string yaml, string file, out string number, out string driverName)
        {
            number = ""; driverName = "";
            try
            {
                if (string.IsNullOrEmpty(yaml)) return "null";
                string me = TrackMaps.YamlValue(yaml, "DriverCarIdx");
                int carIdx;
                if (!int.TryParse(me, out carIdx) || carIdx < 0) return "null";
                Match block = Regex.Match(yaml, "(?m)^\\s*- CarIdx: " + carIdx.ToString(CultureInfo.InvariantCulture) + "[ \\t]*\\r?\\n(.*?)(?=^\\s*- CarIdx:|^\\S|\\z)", RegexOptions.Singleline);
                if (!block.Success) return "null";
                string b = block.Groups[1].Value, col = TrackMaps.YamlValue(b, "CarClassColor");
                number = TrackMaps.YamlValue(b, "CarNumber");
                driverName = TrackMaps.YamlValue(b, "UserName");
                string team = TrackMaps.YamlValue(b, "TeamName");
                return "{\"name\":" + Json_.S(driverName) + ",\"team\":" + Json_.S(team) + ",\"car\":" + Json_.S(TrackMaps.YamlValue(b, "CarScreenName")) + ",\"path\":" + Json_.S(TrackMaps.YamlValue(b, "CarPath")) +
                       ",\"dz\":" + Json_.S(RaceField.DesignOf(TrackMaps.YamlValue(b, "CarDesignStr"))) + ",\"num\":" + Json_.S(number) +
                       ",\"col\":" + Json_.S(Regex.IsMatch(col, "^0x[0-9a-fA-F]{6}$") ? "#" + col.Substring(2).ToLowerInvariant() : "") + ",\"file\":" + Json_.S(file) + "}";
            }
            catch { number = ""; driverName = ""; return "null"; }
        }

        // tests\home-test.ps1: HOME, the career block, the week and the sessions list over a pretend cache file (rows copied from the real one, some changed
        // into "never left the pit box" and "a test started this" sessions). No server, no window, nothing written except --out.
        //   irdash.exe --home --cache <tsv> --tests <test-sessions.txt> --telemetry <dir> --out <json file>
        public static int HomeCli(string[] args)
        {
            string yamlPath = ArgOf(args, "--me-yaml");
            if (yamlPath.Length > 0)
            {
                try
                {
                    string n, u, yaml = File.ReadAllText(yamlPath, Encoding.GetEncoding(28591));
                    string result = MeCarYamlJson(yaml, "fixture.ibt", out n, out u);
                    File.WriteAllText(ArgOf(args, "--out"), "{\"me\":" + result + "}", new UTF8Encoding(false));
                    return 0;
                }
                catch { return 1; }
            }
            string cache = ArgOf(args, "--cache"), tests = ArgOf(args, "--tests"), tele = ArgOf(args, "--telemetry"), outPath = ArgOf(args, "--out");
            if (cache.Length == 0 || outPath.Length == 0) return 2;
            try
            {
                CacheFile = cache; TelemetryDir = tele.Length > 0 ? tele : null; TestRuns.FilePath = tests.Length > 0 ? tests : null;
                lock (gate) { Load(); lastCount = TelemetryDir != null && Directory.Exists(TelemetryDir) ? Directory.GetFiles(TelemetryDir, "*.ibt").Length : 0; }   // no background scan
                string json = "{\"home\":" + HomeJson(false) + ",\"career\":" + Json() + ",\"sessions\":" + SessionsJson() + "}";
                File.WriteAllText(outPath, json, new UTF8Encoding(false));
                return 0;
            }
            catch (Exception ex) { try { File.WriteAllText(outPath, "{\"error\":" + Json_.S(ex.Message) + "}", new UTF8Encoding(false)); } catch { } return 1; }
        }
        static string ArgOf(string[] a, string name) { for (int i = 0; i + 1 < a.Length; i++) if (a[i] == name) return a[i + 1] ?? ""; return ""; }

        static string AgoWord(DateTime utc)
        {
            DateTime lw = utc.ToLocalTime();
            int days = (DateTime.Today - lw.Date).Days;
            return lw.ToString(lw.Year == DateTime.Today.Year ? "ddd d MMM" : "d MMM yyyy", CultureInfo.InvariantCulture);   // a date, not "yesterday"
        }
    }

    // PL-1: the sessions a TEST started (irdeck writes TEST as the label in dash\start-mark.txt when the test has set RIG_TEST_OWNS_SIM).
    // Timings.OnConnected opens a line in dash\test-sessions.txt, Timings.OnDisconnected closes it: "<start ticks>\t<end ticks>" (UTC).
    // A telemetry file that began inside such a run is the test's, not Peter's: Rec.Short asks Covers(). An open line counts for 3 hours at most.
    static class TestRuns
    {
        public static string FilePath;
        static readonly object gate = new object();
        static readonly List<long[]> runs = new List<long[]>();
        static long seenLen = -1, seenTicks; static string seenPath;
        const long Cap = 3L * 36000000000L, Before = 3L * 600000000L, After = 1L * 600000000L;   // 3 h, 3 min before the run, 1 min after

        public static void Begin()
        {
            lock (gate)
                try
                {
                    if (string.IsNullOrEmpty(FilePath)) return;
                    File.AppendAllText(FilePath, DateTime.UtcNow.Ticks + "\t\r\n");
                    List<string> l = new List<string>(File.ReadAllLines(FilePath));
                    if (l.Count > 400) File.WriteAllLines(FilePath, l.GetRange(l.Count - 300, 300).ToArray());
                    Log.W("test run: a test started this session - it will not count as an outing");
                }
                catch (Exception ex) { Log.W("test runs: " + ex.Message); }
        }

        public static void End()
        {
            lock (gate)
                try
                {
                    if (string.IsNullOrEmpty(FilePath) || !File.Exists(FilePath)) return;
                    string[] l = File.ReadAllLines(FilePath);
                    for (int i = l.Length - 1; i >= 0; i--)
                    {
                        string[] p = l[i].Split('\t'); long s;
                        if (p.Length < 2 || p[1].Trim().Length > 0 || !long.TryParse(p[0], out s)) continue;
                        if (DateTime.UtcNow.Ticks - s < Cap) { l[i] = p[0] + "\t" + DateTime.UtcNow.Ticks; File.WriteAllLines(FilePath, l); }
                        break;      // only the newest open line, and only a recent one
                    }
                }
                catch (Exception ex) { Log.W("test runs: " + ex.Message); }
        }

        static DateTime checkedAt = DateTime.MinValue;
        static void Read()
        {
            try
            {
                if ((DateTime.UtcNow - checkedAt).TotalSeconds < 2 && seenPath == FilePath) return;      // one look at the file per two seconds, not one per session row
                checkedAt = DateTime.UtcNow;
                FileInfo fi = string.IsNullOrEmpty(FilePath) ? null : new FileInfo(FilePath);
                if (fi == null || !fi.Exists) { runs.Clear(); seenLen = -1; seenPath = FilePath; return; }
                if (fi.FullName == seenPath && fi.Length == seenLen && fi.LastWriteTimeUtc.Ticks == seenTicks) return;
                runs.Clear();
                foreach (string line in File.ReadAllLines(FilePath))
                {
                    string[] p = line.Split('\t'); long s, e;
                    if (p.Length < 1 || !long.TryParse(p[0], out s)) continue;
                    if (p.Length < 2 || !long.TryParse(p[1], out e) || e < s || e - s > Cap) e = s + Cap;
                    runs.Add(new[] { s, e });
                }
                seenPath = fi.FullName; seenLen = fi.Length; seenTicks = fi.LastWriteTimeUtc.Ticks;
            }
            catch { }
        }

        // true when a session whose recording began at this UTC time belongs to a test run
        public static bool Covers(DateTime utc)
        {
            if (utc == DateTime.MinValue) return false;
            lock (gate)
            {
                Read();
                long t = utc.Ticks;
                foreach (long[] r in runs) if (t >= r[0] - Before && t <= r[1] + After) return true;
            }
            return false;
        }
    }

    static class Home
    {
        public static int Port = 8199;
        static string rootDir;
        public static void Init(string root, int port) { rootDir = root; Port = port; try { Directory.CreateDirectory(Path.Combine(root, @"paddock\home")); } catch { } }

        // Add schedule data after Career.HomeJson releases its cache lock.
        public static string WithNextRace()
        {
            string home = Career.HomeJson();
            try
            {
                JavaScriptSerializer js = new JavaScriptSerializer();
                Dictionary<string, object> h = js.Deserialize<Dictionary<string, object>>(home);
                Dictionary<string, object> official = js.Deserialize<Dictionary<string, object>>(Official.Json(null));
                object raw; Dictionary<string, object> next = null;
                if (official != null && official.TryGetValue("next", out raw) && raw is Dictionary<string, object>) next = (Dictionary<string, object>)raw;
                if (next == null && official != null && official.TryGetValue("deck", out raw) && raw is IList)
                {
                    DateTime soon = DateTime.MaxValue, mineSoon = DateTime.MaxValue;
                    Dictionary<string, object> first = null, firstMine = null;
                    foreach (object item in (IList)raw)
                    {
                        Dictionary<string, object> candidate = item as Dictionary<string, object>;
                        if (candidate == null) continue;
                        DateTime start;
                        if (!DateTime.TryParse(Val(candidate, "t"), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out start)) continue;
                        if (start < soon) { soon = start; first = candidate; }
                        if (Val(candidate, "mine") == "True" && start < mineSoon) { mineSoon = start; firstMine = candidate; }
                    }
                    next = firstMine ?? first;
                }
                if (next == null) h["nextRace"] = null;
                else
                {
                    Dictionary<string, object> race = new Dictionary<string, object>();
                    string car = Val(next, "car"), track = Val(next, "track"), config = Val(next, "layout");
                    race["series"] = Val(next, "series"); race["car"] = car; race["track"] = track;
                    race["localStart"] = Val(next, "localStart"); race["utcStart"] = Val(next, "t");
                    race["countdownSeconds"] = next.ContainsKey("countdownSeconds") ? next["countdownSeconds"] : 0;
                    race["ownedCar"] = next.ContainsKey("ownedCar") ? next["ownedCar"] : false;
                    race["ownedTrack"] = next.ContainsKey("ownedTrack") ? next["ownedTrack"] : false;
                    race["cadence"] = Val(next, "cadence");
                    double pbTime; string pbFile; DateTime pbDate;
                    if (car.Length > 0 && track.Length > 0 && Career.BestFor(car, track, config, out pbTime, out pbFile, out pbDate)) race["pb"] = new Dictionary<string, object> { { "time", pbTime }, { "file", pbFile ?? "" } };
                    else race["pb"] = null;
                    double median = 0; int fieldN = 0;
                    Dictionary<string, object> bench = null;
                    if (car.Length > 0 && track.Length > 0) bench = js.Deserialize<Dictionary<string, object>>(Bench.Json(car, track, config, false));
                    object fv; if (bench != null && bench.TryGetValue("field", out fv) && fv is Dictionary<string, object>) fieldN = Convert.ToInt32(((Dictionary<string, object>)fv)["n"], CultureInfo.InvariantCulture);
                    object ys; if (bench != null && bench.TryGetValue("yardsticks", out ys) && ys is IList) foreach (object item in (IList)ys)
                    {
                        Dictionary<string, object> y = item as Dictionary<string, object>;
                        if (y == null || Val(y, "id") != "median") continue;
                        int n; if (int.TryParse(Val(y, "n"), out n) && n >= 30) median = Convert.ToDouble(y["time"], CultureInfo.InvariantCulture);
                    }
                    race["fieldMedian"] = median > 0 ? (object)median : null; race["fieldN"] = fieldN;
                    h["nextRace"] = race;
                }
                return js.Serialize(h);
            }
            catch (Exception ex) { Log.W("home next race: " + ex.Message); return home; }
        }

        static string Val(Dictionary<string, object> d, string key) { object v; return d != null && d.TryGetValue(key, out v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : ""; }

        // the picture to show, best first; kind says where it came from so the page can word the credit
        public static string HeroPath(out string kind, out string credit)
        {
            kind = "none"; credit = "";
            try
            {
                string own = Path.Combine(rootDir, @"paddock\home\hero.jpg");
                if (File.Exists(own)) { kind = "own"; credit = "Corvette"; return own; }
                string mine = Path.Combine(rootDir, @"paddock\gallery\mine");
                if (Directory.Exists(mine))
                {
                    string newest = null; DateTime nt = DateTime.MinValue;
                    foreach (string f in Directory.GetFiles(mine))
                    {
                        string e = Path.GetExtension(f).ToLowerInvariant();
                        if (e != ".jpg" && e != ".jpeg" && e != ".png") continue;
                        DateTime t = File.GetLastWriteTimeUtc(f); if (t > nt) { nt = t; newest = f; }
                    }
                    if (newest != null) { kind = "photo"; credit = "Photo \u00B7 " + nt.ToLocalTime().ToString("d MMM yyyy", CultureInfo.InvariantCulture); return newest; }
                }
                string standin = Path.Combine(rootDir, @"paddock\home\corvette-z06-gt3r-le-mans.jpg");
                if (File.Exists(standin)) { kind = "standin"; credit = "Photo: Mickael Le rouzic \u00B7 CC BY 4.0"; return standin; }
            }
            catch { }
            return null;
        }

        public static string HeroJson()
        {
            string kind, credit; string p = HeroPath(out kind, out credit);
            long v = 0; try { if (p != null) v = File.GetLastWriteTimeUtc(p).Ticks / 10000000; } catch { }
            return "{\"src\":" + Json_.S(p == null ? "" : "/home/hero?v=" + v) + ",\"kind\":" + Json_.S(kind) + ",\"credit\":" + Json_.S(credit) + "}";
        }

        public static byte[] HeroBytes(out string type)
        {
            string kind, credit; string p = HeroPath(out kind, out credit);
            type = "image/jpeg";
            if (p == null) return null;
            if (p.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) type = "image/png";
            try { return File.ReadAllBytes(p); } catch { return null; }
        }
    }
}
