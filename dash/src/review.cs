// review.cs - REVIEW (W4-1, docs\rework\cards\W4-1.md, PLAN 4.4): ONE engine behind one API for the after-session review.
//   GET /api/review?id=<telemetry file | Vault id | last>   the whole review of one session (the card, the race story, the plan)
//   GET /api/review/traces?id&lap&ref                        the workbench PWB1 (analysis/channels) for this lap and the reference
//   GET /api/review/corners?id&lap&ref                       the corner table: brake point, minimum speed, throttle point, time
//   GET /api/review/progress?car&track                       one dot per session, the corner trend, the iRating line (estimate)
// How it runs: a review is built ONCE per telemetry file by a whenFree job (Jobs.Run, one BelowNormal background thread, never
// while a session is on) and written to dash\data\review\<file>.json (temp + move). A request answers from that file at once;
// a review not built yet answers {"state":"working"} with 202 and queues the job; the page asks again on data.onList('review')
// (the job bumps the list when it is done). The newest finished session is built by itself when the session ends
// (StateBuilder.SessionEnded). Inside the job every heavy step stops on Jobs.ShouldYield (JobYield) and queues the rest again.
// Rules (PLAN 4.4): the reference is this session's best clean counted lap (LapStore.Best, the one best-lap rule); under 3 clean
// laps his best at this car and track from the lap-store index (ref.kind "ever", with the conditions at that lap's start); cards
// ranked by seconds lost, at most 3, with the sample size and one "try this" line; under 3 clean laps one card with numbers and no
// advice; a race also gets the race story from the field log and at most one card from a clean-air lap. Words: Review.Lint.
// Units follow Peter's iRacing setting (the live DisplayUnits the state builder saw; the .ibt does not carry it). phase is one
// of brake | entry | apex | throttle | exit | "" (no single input). C# 5; reads telemetry only; writes only dash\data\review.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace IRDash
{
    // thrown inside a review job once a session starts (Jobs.ShouldYield): the job stops where it is and queues itself again
    sealed class JobYield : Exception { public JobYield() : base("a session started") { } }

    static class Review
    {
        public const int Version = 1;                        // a cache written by another version is built again
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public static string Dir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"data\review");     // tests set their own
        public const string WorkingSay = "Reading your laps…";
        public const string DefaultUnits = "imperial";      // Peter's iRacing is set to imperial (until the live SDK says otherwise)
        public const string TraceChannels = "Speed,Throttle,Brake,SteeringWheelAngle,Gear,Lat,Lon";

        [ThreadStatic] static bool yielding;               // true on the job thread while a review is being built
        public static void Check() { if (yielding && Jobs.ShouldYield) throw new JobYield(); }

        static string Err(string m) { return "{\"error\":" + Json_.S(m) + "}"; }
        static string Q(Dictionary<string, string> q, string k) { string v; return q != null && q.TryGetValue(k, out v) && v != null ? v : ""; }
        static byte[] U(string s) { return Encoding.UTF8.GetBytes(s); }
        public static string WorkingJson() { return "{\"state\":\"working\",\"say\":" + Json_.S(WorkingSay) + "}"; }

        public static string Units
        {
            get { string u = StateBuilder.LiveUnits; return u == "metric" || u == "imperial" ? u : DefaultUnits; }
        }

        // ================================================================================ routes
        public static byte[] Route(string path, Dictionary<string, string> q, out int code, out string type)
        {
            type = "application/json; charset=utf-8"; code = 200;
            try
            {
                if (path == "/api/review") return U(MainRoute(q, out code));
                if (path == "/api/review/traces") return TracesRoute(q, out code, out type);
                if (path == "/api/review/corners") return U(CornersRoute(q, out code));
                if (path == "/api/review/progress") return U(Progress(Q(q, "car"), Q(q, "track")));
            }
            catch (Exception ex) { Log.W("review: " + path + ": " + ex.Message); code = 500; type = "application/json; charset=utf-8"; return U(Err("could not read that session")); }
            code = 404; return U(Err("not found"));
        }

        static string MainRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            bool pending;
            string file = FileOf(Q(q, "id"), out pending);
            if (file == null)
            {
                if (pending) { QueueLast(); code = 202; return WorkingJson(); }
                code = 404; return Err(Q(q, "id").Length == 0 || Q(q, "id") == "last" ? "no finished session yet" : "no such session");
            }
            string c = Cached(file);
            if (c != null) return c;
            Queue(file);
            code = 202; return WorkingJson();
        }

        // id: a telemetry file name, a Vault id, or "last" (the newest finished session the lap store knows)
        static string FileOf(string id, out bool pending)
        {
            pending = false;
            if (id.Length == 0 || id == "last") return Last(out pending);
            return Analysis.ReviewFile(id);
        }

        // the sim is still writing it: never reviewed (its laps are not final)
        static bool Writing(FileInfo fi)
        {
            bool busy = false; try { busy = RigState.SessionOn || RigState.SimRunning; } catch { }
            return busy && (DateTime.UtcNow - fi.LastWriteTimeUtc).TotalMinutes < 2;
        }

        static List<FileInfo> NewestFirst()
        {
            List<FileInfo> l = new List<FileInfo>();
            string dir = TrackMaps.TelemetryDir;
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return l;
            foreach (string f in Directory.GetFiles(dir, "*.ibt")) l.Add(new FileInfo(f));
            l.Sort(delegate (FileInfo a, FileInfo b) { return Stamp(b).CompareTo(Stamp(a)); });
            return l;
        }
        static DateTime Stamp(FileInfo fi) { DateTime d = IbtFile.StartFromName(fi.Name); return d == DateTime.MinValue ? fi.LastWriteTimeUtc : d; }

        // ONE "last session" picker: the newest finished file with at least one full lap in the lap store. A newer finished file the lap
        // store has not worked out yet = pending (the "review last" job works it out first: nothing heavy on a request thread).
        public static string Last(out bool pending)
        {
            pending = false;
            int looked = 0;
            foreach (FileInfo fi in NewestFirst())
            {
                if (++looked > 60) break;
                if (Writing(fi) || Career.OnlineOnly(fi)) continue;
                FileLaps fl = LapStore.Peek(fi.FullName);
                if (fl == null) { pending = true; return null; }
                if (fl.Laps.Count > 0) return fi.FullName;
            }
            return null;
        }

        // ================================================================================ the cache
        static string Base(string file) { return Path.GetFileNameWithoutExtension(file); }
        public static string CachePath(string file) { return Path.Combine(Dir, Base(file) + ".json"); }
        public static string CornersPath(string file) { return Path.Combine(Dir, Base(file) + ".corners.json"); }
        static string TracePath(string key) { return Path.Combine(Path.Combine(Dir, "traces"), key + ".bin"); }
        public static string Sig(string file)
        {
            long len = 0; try { len = new FileInfo(file).Length; } catch { }
            return Path.GetFileName(file).ToLowerInvariant() + "|" + len.ToString(Inv) + "|r" + LapRules.Version + "|v" + Version;
        }

        // the review as built, or null (none yet, or built for another file of that name, rules or engine version)
        public static string Cached(string file)
        {
            try
            {
                string p = CachePath(file);
                if (!File.Exists(p)) return null;
                string t = File.ReadAllText(p, Encoding.UTF8);
                return t.Contains("\"sig\":" + Json_.S(Sig(file))) ? t : null;
            }
            catch { return null; }
        }

        // written temp + move, so a reader never sees half a file
        public static void Save(string path, string text) { SaveBytes(path, new UTF8Encoding(false).GetBytes(text)); }
        static void SaveBytes(string path, byte[] b)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string tmp = path + ".tmp";
            File.WriteAllBytes(tmp, b);
            if (File.Exists(path)) File.Delete(path);
            File.Move(tmp, path);
        }

        // ================================================================================ the jobs
        public static bool Queue(string file)
        {
            string f = file;
            return Jobs.Run("review " + Path.GetFileName(f), delegate { BuildJob(f); }, true);
        }

        // the session just ended (StateBuilder.SessionEnded): the newest finished session's review, by itself
        public static void QueueLast() { Jobs.Run("review last", LastJob, true); }

        static void LastJob()
        {
            yielding = true;
            try
            {
                int looked = 0;
                foreach (FileInfo fi in NewestFirst())
                {
                    if (++looked > 8) break;
                    if (Writing(fi) || Career.OnlineOnly(fi)) continue;
                    Check();
                    FileLaps fl = LapStore.ForFile(fi.FullName);
                    Check();
                    if (fl == null || fl.Laps.Count == 0) continue;
                    if (Cached(fi.FullName) == null) BuildNow(fi.FullName);
                    break;
                }
                Bump();
            }
            catch (JobYield) { Jobs.Again("review last", LastJob); }
            finally { yielding = false; }
        }

        static void BuildJob(string file)
        {
            yielding = true;
            try { if (Cached(file) == null) BuildNow(file); Bump(); }
            catch (JobYield) { string f = file; Jobs.Again("review " + Path.GetFileName(f), delegate { BuildJob(f); }); }
            finally { yielding = false; }
        }

        static void Bump() { try { StateBuilder.BumpReview(); } catch { } }

        // the build itself (the job thread; tests call it directly). Returns the review JSON it wrote.
        public static string BuildNow(string file)
        {
            string corners = null, json;
            try { json = Analysis.BuildReview(file, Sig(file), Units, out corners); }
            catch (JobYield) { throw; }
            catch (Exception ex) { Log.W("review: " + Path.GetFileName(file) + ": " + ex.Message); json = null; }
            if (json == null) json = "{\"state\":\"error\",\"sig\":" + Json_.S(Sig(file)) + ",\"say\":\"Could not read this session\"}";
            if (corners != null) Save(CornersPath(file), corners);
            Save(CachePath(file), json);
            return json;
        }

        // ================================================================================ traces and corners
        static Dictionary<string, object> Obj(string json)
        {
            try { return new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(json) as Dictionary<string, object>; }
            catch { return null; }
        }
        static object G(Dictionary<string, object> d, string k) { object o; return d != null && d.TryGetValue(k, out o) ? o : null; }
        static int I(object o) { double v; return o != null && double.TryParse(Convert.ToString(o, Inv), NumberStyles.Float, Inv, out v) ? (int)Math.Round(v) : 0; }

        // the review's own best lap and reference ("file:lap"), for the defaults of the traces and the corner table
        static bool Defaults(Dictionary<string, object> rv, out int lap, out string refSpec)
        {
            lap = 0; refSpec = "";
            Dictionary<string, object> s = G(rv, "session") as Dictionary<string, object>;
            Dictionary<string, object> b = G(s, "best") as Dictionary<string, object>, r = G(s, "ref") as Dictionary<string, object>;
            if (b != null) lap = I(G(b, "lap"));
            if (r != null) refSpec = Convert.ToString(G(r, "file"), Inv) + ":" + I(G(r, "lap")).ToString(Inv);
            return lap > 0;
        }

        static byte[] TracesRoute(Dictionary<string, string> q, out int code, out string type)
        {
            type = "application/json; charset=utf-8"; code = 200;
            bool pending; string file = FileOf(Q(q, "id"), out pending);
            if (file == null) { if (pending) { QueueLast(); code = 202; return U(WorkingJson()); } code = 404; return U(Err("no such session")); }
            string rvText = Cached(file);
            if (rvText == null) { Queue(file); code = 202; return U(WorkingJson()); }
            int lap; string rf;
            Defaults(Obj(rvText), out lap, out rf);
            int ql; if (int.TryParse(Q(q, "lap"), NumberStyles.Integer, Inv, out ql) && ql > 0) lap = ql;
            if (Q(q, "ref").Length > 0) rf = Q(q, "ref");
            if (lap <= 0) { code = 404; return U(Err("no full lap in this session")); }
            if (rf.Length > 0 && rf.IndexOf(':') < 0) rf = Path.GetFileName(file) + ":" + rf;      // ref=7: lap 7 of this session
            string key = Regex.Replace(Base(file) + "-" + lap.ToString(Inv) + "-" + rf, "[^A-Za-z0-9._-]+", "_");
            if (key.Length > 150) key = key.Substring(0, 150);
            string bin = TracePath(key), err = bin + ".err";
            if (File.Exists(bin)) { type = "application/octet-stream"; return File.ReadAllBytes(bin); }
            if (File.Exists(err))
            {
                string t = File.ReadAllText(err, Encoding.UTF8); int c = 500; int bar = t.IndexOf('|');
                if (bar > 0) int.TryParse(t.Substring(0, bar), out c);
                code = c; return U(bar > 0 ? t.Substring(bar + 1) : t);
            }
            string f = file, r2 = rf; int l2 = lap;
            Jobs.Run("review traces " + key, delegate { TraceJob(f, l2, r2, bin, err); }, true);
            code = 202; return U(WorkingJson());
        }

        static void TraceJob(string file, int lap, string rf, string bin, string err)
        {
            yielding = true;
            try
            {
                int code; byte[] b = Analysis.ReviewTraces(file, lap, rf, out code);
                if (code == 200) SaveBytes(bin, b); else Save(err, code.ToString(Inv) + "|" + Encoding.UTF8.GetString(b));
                Bump();
            }
            catch (JobYield) { string f = file, r = rf, bb = bin, ee = err; int l = lap; Jobs.Again("review traces " + Path.GetFileNameWithoutExtension(bin), delegate { TraceJob(f, l, r, bb, ee); }); }
            catch (Exception ex) { Log.W("review traces: " + ex.Message); }
            finally { yielding = false; }
        }

        static string CornersRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            bool pending; string file = FileOf(Q(q, "id"), out pending);
            if (file == null) { if (pending) { QueueLast(); code = 202; return WorkingJson(); } code = 404; return Err("no such session"); }
            if (Cached(file) == null) { Queue(file); code = 202; return WorkingJson(); }
            string p = CornersPath(file);
            Dictionary<string, object> d = File.Exists(p) ? Obj(File.ReadAllText(p, Encoding.UTF8)) : null;
            if (d == null || Convert.ToString(G(d, "sig"), Inv) != Sig(file)) { code = 404; return Err("no corner table for this session"); }
            object[] laps = G(d, "laps") as object[] ?? new object[0];
            Dictionary<string, object> rfo = G(d, "ref") as Dictionary<string, object>;
            int lap; int.TryParse(Q(q, "lap"), NumberStyles.Integer, Inv, out lap);
            if (lap <= 0) lap = I(G(d, "best"));
            Dictionary<string, object> mine = null, other = null;
            foreach (object o in laps) { Dictionary<string, object> x = o as Dictionary<string, object>; if (x != null && I(G(x, "n")) == lap) mine = x; }
            if (mine == null) { code = 404; return Err("no corner times for that lap"); }
            string rq = Q(q, "ref");
            if (rq.Length == 0 || (rfo != null && rq == Convert.ToString(G(rfo, "file"), Inv) + ":" + I(G(rfo, "n")).ToString(Inv))) other = rfo;
            else
            {
                int rn; string num = rq.IndexOf(':') >= 0 ? rq.Substring(rq.LastIndexOf(':') + 1) : rq;
                string rfile = rq.IndexOf(':') >= 0 ? rq.Substring(0, rq.LastIndexOf(':')) : Path.GetFileName(file);
                if (!string.Equals(rfile, Path.GetFileName(file), StringComparison.OrdinalIgnoreCase) || !int.TryParse(num, NumberStyles.Integer, Inv, out rn))
                { code = 400; return Err("ref must be a lap of this session or the review's reference"); }
                foreach (object o in laps) { Dictionary<string, object> x = o as Dictionary<string, object>; if (x != null && I(G(x, "n")) == rn) other = x; }
                if (other == null) { code = 404; return Err("no corner times for that reference lap"); }
            }
            JavaScriptSerializer js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
            return "{\"state\":\"ready\",\"units\":" + js.Serialize(G(d, "units")) + ",\"defs\":" + js.Serialize(G(d, "defs")) + ",\"lap\":" + js.Serialize(mine) + ",\"ref\":" + (other == null ? "null" : js.Serialize(other)) + "}";
        }

        // ================================================================================ progress (from the caches only: cheap)
        static double D(object o) { double v; return o != null && double.TryParse(Convert.ToString(o, Inv), NumberStyles.Float, Inv, out v) ? v : double.NaN; }
        static bool Same(string a, string b) { return string.Equals((a ?? "").Trim(), (b ?? "").Trim(), StringComparison.OrdinalIgnoreCase); }

        public static string Progress(string car, string track)
        {
            StringBuilder sb = new StringBuilder(4096);
            sb.Append("{\"car\":").Append(Json_.S(car)).Append(",\"track\":").Append(Json_.S(track)).Append(",\"sessions\":[");
            // one dot per session: the best counted lap and the average of the 5 quickest counted laps (the lap caches: LapStore.Dir)
            List<double[]> dots = new List<double[]>();
            if (Directory.Exists(LapStore.Dir))
                foreach (string f in Directory.GetFiles(LapStore.Dir, "*.json"))
                {
                    Dictionary<string, object> d = Obj(File.ReadAllText(f, Encoding.UTF8));
                    if (d == null || I(G(d, "rules")) != LapRules.Version || !Same(Convert.ToString(G(d, "car"), Inv), car) || !(Same(Convert.ToString(G(d, "track"), Inv), track) || Same(Convert.ToString(G(d, "trackId"), Inv), track))) continue;
                    List<double> t = new List<double>();
                    foreach (object o in G(d, "laps") as object[] ?? new object[0])
                    {
                        Dictionary<string, object> l = o as Dictionary<string, object>;
                        if (l != null && G(l, "counted") is bool && (bool)G(l, "counted")) { double v = D(G(l, "time")); if (v > 0) t.Add(v); }
                    }
                    double ms = D(G(d, "startMs"));
                    if (t.Count == 0 || double.IsNaN(ms)) continue;
                    t.Sort(); int n = Math.Min(5, t.Count); double s = 0; for (int i = 0; i < n; i++) s += t[i];
                    dots.Add(new double[] { ms, t[0], s / n });
                }
            dots.Sort(delegate (double[] a, double[] b) { return a[0].CompareTo(b[0]); });
            for (int i = 0; i < dots.Count; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append("{\"date\":").Append(((long)dots[i][0]).ToString(Inv)).Append(",\"best\":").Append(dots[i][1].ToString("0.000", Inv)).Append(",\"avg5\":").Append(dots[i][2].ToString("0.000", Inv)).Append('}');
            }
            // the corner trend and the iRating line: from the reviews already built (dash\data\review\*.json)
            SortedDictionary<int, List<double[]>> byCorner = new SortedDictionary<int, List<double[]>>(); Dictionary<int, string> labels = new Dictionary<int, string>();
            List<double[]> ir = new List<double[]>();
            if (Directory.Exists(Dir))
                foreach (string f in Directory.GetFiles(Dir, "*.json"))
                {
                    if (f.EndsWith(".corners.json", StringComparison.OrdinalIgnoreCase)) continue;
                    Dictionary<string, object> d = Obj(File.ReadAllText(f, Encoding.UTF8));
                    Dictionary<string, object> s = G(d, "session") as Dictionary<string, object>;
                    if (s == null || Convert.ToString(G(d, "state"), Inv) != "ready" || !Same(Convert.ToString(G(s, "car"), Inv), car) || !Same(Convert.ToString(G(s, "track"), Inv), track)) continue;
                    double ms = D(G(s, "date")); if (double.IsNaN(ms)) continue;
                    foreach (object o in G(d, "cards") as object[] ?? new object[0])
                    {
                        Dictionary<string, object> c = o as Dictionary<string, object>; Dictionary<string, object> cn = G(c, "corner") as Dictionary<string, object>;
                        if (cn == null) continue;
                        int n = I(G(cn, "n")); double lost = D(G(c, "lost")); if (double.IsNaN(lost)) continue;
                        if (!byCorner.ContainsKey(n)) byCorner[n] = new List<double[]>();
                        byCorner[n].Add(new double[] { ms, lost }); labels[n] = Convert.ToString(G(cn, "label"), Inv);
                    }
                    Dictionary<string, object> res = G(s, "result") as Dictionary<string, object>;
                    double chg = D(G(res, "irating")), before = D(G(res, "ir"));
                    if (!double.IsNaN(chg) && before > 0) ir.Add(new double[] { ms, before + chg });
                }
            sb.Append("],\"corners\":[");
            bool first = true;
            foreach (KeyValuePair<int, List<double[]>> kv in byCorner)
            {
                kv.Value.Sort(delegate (double[] a, double[] b) { return a[0].CompareTo(b[0]); });
                if (!first) sb.Append(','); first = false;
                sb.Append("{\"n\":").Append(kv.Key).Append(",\"label\":").Append(Json_.S(labels[kv.Key])).Append(",\"lost\":[");
                for (int i = 0; i < kv.Value.Count; i++) { if (i > 0) sb.Append(','); sb.Append(kv.Value[i][1].ToString("0.000", Inv)); }
                sb.Append("],\"dates\":[");
                for (int i = 0; i < kv.Value.Count; i++) { if (i > 0) sb.Append(','); sb.Append(((long)kv.Value[i][0]).ToString(Inv)); }
                sb.Append("]}");
            }
            ir.Sort(delegate (double[] a, double[] b) { return a[0].CompareTo(b[0]); });
            sb.Append("],\"irating\":[");
            for (int i = 0; i < ir.Count; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append("{\"date\":").Append(((long)ir[i][0]).ToString(Inv)).Append(",\"value\":").Append(((int)Math.Round(ir[i][1])).ToString(Inv)).Append(",\"estimate\":true}");
            }
            return sb.Append("]}").ToString();
        }

        // ================================================================================ the words
        // The "never say" list (PLAN 4.4, docs\research 12): the first rule a line breaks, or null. Lint is for a card's main line
        // ("T5: You braked 14 m earlier than your best lap"): it also needs a corner and a number. LintLine is for "try this" and the plan.
        static readonly Regex Corner = new Regex(@"\b(T\d+[a-z]?|Turn \d+[a-z]?)\b", RegexOptions.IgnoreCase);
        public static string Lint(string text) { return LintText(text, true); }
        public static string LintLine(string text) { return LintText(text, false); }
        static string LintText(string text, bool card)
        {
            string t = text ?? "";
            if (t.IndexOf('%') >= 0 || Regex.IsMatch(t, @"\bper ?cent", RegexOptions.IgnoreCase)) return "no percentages";
            if (Regex.IsMatch(t, @"\b(mistakes?|errors?|bad|badly|worse|terrible|poor)\b", RegexOptions.IgnoreCase)) return "no \"mistake\", \"error\" or \"bad\"";
            if (Regex.IsMatch(t, @"\byou (should|must|need to|have to)\b", RegexOptions.IgnoreCase)) return "no \"you should\"";
            int words = 0; foreach (string w in t.Split(new char[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)) if (Regex.IsMatch(w, "[A-Za-z0-9]")) words++;
            if (words > 14) return "14 words at most";
            if (card)
            {
                // the corner: "T5" / "Turn 5", or a named corner as the card's label ("The Esses: ...")
                Match named = Regex.Match(t, @"^([A-Z][A-Za-z' .-]{1,30}):\s");
                if (!Corner.IsMatch(t) && !named.Success) return "a corner on every card";
                string rest = Corner.Replace(named.Success ? t.Substring(named.Length) : t, "");
                if (!Regex.IsMatch(rest, @"\d")) return "a number on every card";
            }
            return null;
        }
    }

    static partial class Analysis
    {
        internal static string ReviewFile(string id) { return ResolveFile(id); }

        // a part of the workbench reply for the traces route: this lap and the reference, only the files they are in (no 40-file gather)
        internal static byte[] ReviewTraces(string file, int lap, string refSpec, out int code)
        {
            Review.Check();
            return BuildChannels(file, lap, refSpec, Review.TraceChannels, null, false, out code, "");
        }

        sealed class RvCard
        {
            public CoachRow Row; public int Rank; public double Lost; public string Code = "", Phase = "", Happened = "", Try = "", Check = "", Sample = "";
            public bool CleanAir; public LapTrace Lap;
        }

        static string TypeWord(string t)
        {
            string s = (t ?? "").ToLowerInvariant();
            if (s.Contains("race")) return "Race";
            if (s.Contains("qual")) return "Qualify";
            if (s.Contains("test")) return "Test";
            return "Practice";
        }

        static long Ms(DateTime utc) { return utc == DateTime.MinValue ? 0 : (long)(utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }

        // the session of the file the review is about: the race when the file holds one with laps, else the one with the most laps
        static int PickSession(FileLaps fl, string yaml)
        {
            Dictionary<int, int> count = new Dictionary<int, int>();
            foreach (LapRec l in fl.Laps) { int c; count.TryGetValue(l.SessionNum, out c); count[l.SessionNum] = c + 1; }
            int best = int.MinValue, bestN = -1;
            foreach (KeyValuePair<int, int> kv in count)
            {
                bool race = TypeWord(Career.SessionTypeOf(yaml, kv.Key)) == "Race";
                int score = (race ? 100000 : 0) + kv.Value * 10 + Math.Max(0, kv.Key);
                if (score > best) { best = score; bestN = kv.Key; }
            }
            if (count.Count == 0) { int cn; if (int.TryParse(TrackMaps.YamlValue(yaml ?? "", "CurrentSessionNum"), NumberStyles.Integer, Inv, out cn)) return cn; }
            return bestN;
        }

        // his best at this car and track in OTHER sessions, from the lap-store index (LapStore.Peek: never reads an .ibt). A copy or a cut of
        // this same session (the same start time) is not another session.
        static bool EverBest(FileLaps mine, string mainPath, out string path, out LapRec lap, out FileLaps of)
        {
            path = null; lap = null; of = null;
            string dir = TrackMaps.TelemetryDir;
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return false;
            foreach (string f in Directory.GetFiles(dir, "*.ibt"))
            {
                if (string.Equals(Path.GetFullPath(f), Path.GetFullPath(mainPath), StringComparison.OrdinalIgnoreCase)) continue;
                FileLaps fl = LapStore.Peek(f);
                if (fl == null || fl.Car != mine.Car || fl.Track != mine.Track || fl.Config != mine.Config) continue;
                if (mine.StartUtc != DateTime.MinValue && fl.StartUtc == mine.StartUtc) continue;
                LapRec b = fl.BestLap;
                if (b != null && (lap == null || b.Time < lap.Time - 1e-9)) { lap = b; path = f; of = fl; }
            }
            return lap != null;
        }

        // track temperature and fuel at the start of a lap (the .ibt's TrackTemp / FuelLevel at the lap's first record), in his units
        static string ConditionsLine(string path, long rec, bool imperial)
        {
            try
            {
                using (IbtFile t = IbtFile.Open(path, true))
                {
                    if (t == null) return "";
                    double[][] v = t.Channels(new string[] { "TrackTemp", "TrackTempCrew", "FuelLevel" }, Math.Max(0, rec), 1);
                    double tc = v[0] != null && v[0].Length > 0 ? v[0][0] : (v[1] != null && v[1].Length > 0 ? v[1][0] : double.NaN);
                    double fuel = v[2] != null && v[2].Length > 0 ? v[2][0] : double.NaN;
                    List<string> parts = new List<string>();
                    if (!double.IsNaN(tc) && tc > -50 && tc < 90) parts.Add("track " + Math.Round(imperial ? tc * 9 / 5 + 32 : tc).ToString("0", Inv) + "°");
                    if (!double.IsNaN(fuel) && fuel >= 0) parts.Add(imperial ? Math.Round(fuel / 3.785411784, 1).ToString("0.#", Inv) + " gal fuel" : Math.Round(fuel).ToString("0", Inv) + " L fuel");
                    return string.Join(", ", parts.ToArray());
                }
            }
            catch { return ""; }
        }

        static double SpeedIn(double kmh, bool imperial) { return imperial ? kmh / KmhPerMph : kmh; }

        // what was measured, the same rules as the coach (AppendFocus): each typical difference against its noise floor, the side of the apex
        // where the time goes, the biggest difference on that side that LOSES time picks the phase. second = the next fact on that side.
        static string PickCause(CoachRow r, int minSupport, out double value, out string second)
        {
            value = 0; second = "";
            int support = Math.Max(minSupport, (int)Math.Ceiling(r.Lost / 2.0));
            Func<List<double>, double> typical = delegate (List<double> v) { return v.Count >= support ? Median(v) : double.NaN; };
            double br = typical(r.Br), en = typical(r.En), mn = typical(r.Mn), pk = typical(r.Pk), ex = typical(r.Ex);
            bool brake = !double.IsNaN(br) && Math.Abs(br) >= 5 && br < 0, entry = !double.IsNaN(en) && Math.Abs(en) / KmhPerMph >= 3 && en < 0,
                 apex = !double.IsNaN(mn) && Math.Abs(mn) / KmhPerMph >= 3 && mn < 0, pick = !double.IsNaN(pk) && Math.Abs(pk) >= 10 && pk > 0, exit = !double.IsNaN(ex) && Math.Abs(ex) / KmhPerMph >= 3 && ex < 0;
            double tin = Median(r.In), tout = Median(r.Out);
            bool before = double.IsNaN(tout) || (!double.IsNaN(tin) && tin >= tout);
            string code = ""; double size = 0;
            Action<string, bool, double, double> pickIf = delegate (string c, bool ok, double v, double floor) { if (!ok) return; double s = Math.Abs(v) / floor; if (s > size) { size = s; code = c; } };
            Action<bool> side = delegate (bool b4)
            {
                if (b4) { pickIf("brake", brake, br, 5); pickIf("entry", entry, en / KmhPerMph, 3); pickIf("min", apex, mn / KmhPerMph, 3); }
                else { pickIf("pickup", pick, pk, 10); pickIf("exit", exit, ex / KmhPerMph, 3); pickIf("min", apex, mn / KmhPerMph, 3); }
            };
            side(before);
            double other = before ? tout : tin;
            if (code.Length == 0 && !double.IsNaN(other) && other >= CoachMinLoss) { side(!before); if (code.Length > 0) before = !before; }
            switch (code) { case "brake": value = br; break; case "entry": value = en; break; case "min": value = mn; break; case "pickup": value = pk; break; case "exit": value = ex; break; }
            string[] order = before ? new string[] { "brake", "entry", "min" } : new string[] { "pickup", "exit", "min" };
            foreach (string c in order)
            {
                if (c == code) continue;
                bool has = c == "brake" ? brake : c == "entry" ? entry : c == "min" ? apex : c == "pickup" ? pick : exit;
                if (has) { second = c == "brake" ? "braking point" : c == "entry" ? "entry speed" : c == "min" ? "slowest point" : c == "pickup" ? "throttle point" : "exit speed"; break; }
            }
            return code;
        }

        static string PhaseOf(string code) { return code == "brake" ? "brake" : code == "entry" ? "entry" : code == "min" ? "apex" : code == "pickup" ? "throttle" : code == "exit" ? "exit" : ""; }

        static string Happened(string code, double v, double lost, bool imperial)
        {
            string u = imperial ? "mph" : "km/h";
            string sp = Whole(Math.Abs(SpeedIn(v, imperial)));
            switch (code)
            {
                case "brake": return "You braked " + Whole(Math.Abs(v)) + " m earlier than your best lap";
                case "entry": return "You turned in " + sp + " " + u + " slower than your best lap";
                case "min": return "You were " + sp + " " + u + " slower at the slowest point";
                case "pickup": return "Full throttle came " + Whole(Math.Abs(v)) + " m later than your best lap";
                case "exit": return "You left the corner " + sp + " " + u + " slower than your best lap";
            }
            return "No single input explains the " + lost.ToString("0.00", Inv) + " s here";
        }

        // the brake board nearest to the reference's braking point, counted back from the apex: 50 / 100 / 150 / 200 m
        static string Board(Met refM, double L)
        {
            if (refM == null || !refM.HasBrake) return "";
            double d = DeltaM(refM.Pa * L, refM.BrakeM, L);
            if (d <= 0) return "";
            int b = (int)(Math.Round(d / 50.0) * 50); if (b < 50) b = 50; if (b > 200) b = 200;
            return b.ToString(Inv);
        }

        static string TryThis(string code, Met refM, double L)
        {
            switch (code)
            {
                case "brake": { string b = Board(refM, L); return b.Length > 0 ? "Brake at the " + b + " m board" : "Brake later, at your best lap's braking point"; }
                case "entry": return "Carry more speed to the turn-in";
                case "min": return "Keep more speed through the slowest point";
                case "pickup": return "Back on the throttle earlier";
                case "exit": return "Carry more speed onto the exit";
            }
            return "Watch both laps side by side";
        }

        static bool Detected(CornerSet cs, int n)
        {
            if (cs == null) return true;
            foreach (CornerTurn t in cs.Turns) if (t.N == n) return !(t.Source == "lovely" || (t.Source.Length == 0 && cs.Source == "lovely"));
            return cs.Source != "lovely";
        }

        // how Peter says it: the corner's real name when Lovely gave one, else "Turn 5"
        static string Spoken(Met m, bool detected)
        {
            if (!detected && m.Name.Length > 0) return m.Name;
            string l = m.Label ?? "";
            Match x = Regex.Match(l, @"^T(\d+[a-z]?)$", RegexOptions.IgnoreCase);
            return x.Success ? "Turn " + x.Groups[1].Value : (l.Length > 0 ? l : "Turn " + m.N.ToString(Inv));
        }

        static string Lower1(string s) { return string.IsNullOrEmpty(s) ? "" : char.ToLowerInvariant(s[0]) + s.Substring(1); }

        // compare laps with the reference corner by corner (the coach's row: every loss, the losing laps' facts, the typical lap)
        static List<CoachRow> RowsAgainst(LapTrace rf, List<LapTrace> compare)
        {
            List<CoachRow> rows = new List<CoachRow>();
            foreach (Met bm in rf.Corners)
            {
                CoachRow r = new CoachRow(); r.M = bm;
                foreach (LapTrace l in compare)
                {
                    if (SameLap(l, rf) || l.Corners == null) continue;
                    Met a = ByN(l.Corners, bm.N); if (a == null) continue;
                    Diff d = CompareMet(a, bm, rf.LengthM);
                    r.Laps++; r.Loss.Add(d.DTime);
                    if (d.DTime >= CoachMinLoss)
                    {
                        r.Lost++; r.In.Add(d.DIn); r.Out.Add(d.DOut);
                        if (d.HasBr) r.Br.Add(d.DBr); if (d.HasEn) r.En.Add(d.DEn); if (d.HasMn) r.Mn.Add(d.DMn); if (d.HasPk) r.Pk.Add(d.DPk); if (d.HasEx) r.Ex.Add(d.DEx);
                    }
                }
                double med = Median(r.Loss), gap = double.MaxValue;
                foreach (LapTrace l in compare)
                {
                    if (SameLap(l, rf)) continue; Met a = ByN(l.Corners, bm.N); if (a == null) continue;
                    double g = Math.Abs((a.Time - bm.Time) - med);
                    if (g < gap) { gap = g; r.Example = l; r.ExampleLoss = a.Time - bm.Time; }
                }
                if (r.Laps > 0) rows.Add(r);
            }
            rows.Sort(delegate (CoachRow a, CoachRow b) { return Median(b.Loss).CompareTo(Median(a.Loss)); });
            return rows;
        }

        static RvCard MakeCard(CoachRow r, int minSupport, bool advice, LapTrace rf, bool imperial)
        {
            RvCard c = new RvCard(); c.Row = r; c.Lost = Median(r.Loss); c.Lap = r.Example;
            double v = 0; string second = "";
            if (r.Lost > 0) c.Code = PickCause(r, minSupport, out v, out second);
            c.Phase = PhaseOf(c.Code);
            c.Happened = Happened(c.Code, v, c.Lost, imperial);
            c.Try = advice ? TryThis(c.Code, r.M, rf.LengthM) : "";
            c.Check = advice ? second : "";
            return c;
        }

        // a clip of the lap the card shows, when the recorder kept one: its id and the second the corner's run-up starts
        static string ClipJson(string file, LapTrace lap, double p0)
        {
            try
            {
                if (lap == null || lap.Tm == null) return "null";
                RecClip c = Recorder.ClipForShare(Path.GetFileName(file) + ":" + lap.Lap.ToString(Inv));
                if (c == null || c.Id.Length == 0) return "null";
                return "{\"id\":" + Json_.S(c.Id) + ",\"at\":" + F(Math.Max(0, c.LapStartOffset + CueAt(lap, p0)), "0.0") + "}";
            }
            catch { return "null"; }
        }

        static void AppendCorner(StringBuilder sb, Met m, CornerSet cs)
        {
            sb.Append("{\"n\":").Append(m.N).Append(",\"label\":").Append(Json_.S(m.Label)).Append(",\"name\":").Append(Json_.S(m.Name))
              .Append(",\"detected\":").Append(Detected(cs, m.N) ? "true" : "false")
              .Append(",\"p0\":").Append(F(m.P0, "0.0000")).Append(",\"pa\":").Append(F(m.Pa, "0.0000")).Append(",\"p1\":").Append(F(m.P1, "0.0000")).Append('}');
        }

        static void AppendCard(StringBuilder sb, RvCard c, string file, CornerSet cs)
        {
            sb.Append("{\"rank\":").Append(c.Rank).Append(",\"corner\":"); AppendCorner(sb, c.Row.M, cs);
            sb.Append(",\"lost\":").Append(F(c.Lost, "0.00")).Append(",\"happened\":").Append(Json_.S(c.Happened)).Append(",\"tryThis\":").Append(Json_.S(c.Try))
              .Append(",\"sample\":").Append(Json_.S(c.Sample)).Append(",\"phase\":").Append(Json_.S(c.Phase)).Append(",\"clip\":").Append(ClipJson(file, c.Lap, c.Row.M.P0));
            if (c.CleanAir) sb.Append(",\"cleanAir\":true,\"lap\":").Append(c.Lap != null ? c.Lap.Lap : 0);
            sb.Append('}');
        }

        static string Plural(int n, string one) { return n == 1 ? one : one + "s"; }

        // ---------------------------------------------------------------- the build (a whenFree job; never a request thread)
        internal static string BuildReview(string file, string sig, string units, out string cornersJson)
        {
            cornersJson = null;
            bool imperial = units != "metric";
            Review.Check();
            FileLaps fl = LapStore.ForFile(file);
            Review.Check();
            if (fl == null) return null;
            string yaml = "";
            using (IbtFile t = IbtFile.Open(file, false)) if (t != null) yaml = t.Yaml;
            int sn = PickSession(fl, yaml);
            List<LapRec> laps = sn < 0 ? new List<LapRec>(fl.Laps) : LapStore.OfSession(fl, sn);
            string type = TypeWord(Career.SessionTypeOf(yaml, sn));
            LapRec best = LapStore.Best(laps);
            int counted = 0; foreach (LapRec l in laps) if (l.Counted) counted++;

            // the race story first (the field log): it does not need a full lap
            Dictionary<string, object> story = null;
            if (type == "Race")
            {
                Review.Check();
                string log = RaceField.LogFor(Path.GetFileName(file), sn);
                string sj = log != null ? Debrief.RaceStory(log) : null;
                if (sj != null) story = new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(sj) as Dictionary<string, object>;
            }

            StringBuilder sb = new StringBuilder(16000);
            sb.Append("{\"state\":\"ready\",\"v\":").Append(Review.Version).Append(",\"sig\":").Append(Json_.S(sig)).Append(",\"units\":").Append(Json_.S(imperial ? "imperial" : "metric"));
            sb.Append(",\"session\":{\"id\":").Append(Json_.S(Path.GetFileName(file))).Append(",\"track\":").Append(Json_.S(fl.Track)).Append(",\"config\":").Append(Json_.S(fl.Config))
              .Append(",\"car\":").Append(Json_.S(fl.Car)).Append(",\"type\":").Append(Json_.S(type)).Append(",\"sessionNum\":").Append(sn)
              .Append(",\"date\":").Append(Ms(fl.StartUtc).ToString(Inv)).Append(",\"laps\":").Append(laps.Count).Append(",\"clean\":").Append(counted)
              .Append(",\"best\":").Append(best == null ? "null" : "{\"lap\":" + best.N + ",\"time\":" + F(best.Time, "0.000") + "}");

            if (laps.Count == 0)
            {
                // nothing to compare: the facts there are, and the race story when there is one
                sb.Append(",\"ref\":null,\"result\":"); AppendResult(sb, story);
                sb.Append(",\"conditions\":\"\"}");
                sb.Append(",\"cards\":[],\"plan\":\"\",\"race\":"); AppendRace(sb, story, null, null, file, null);
                sb.Append(",\"map\":{\"key\":\"\",\"id\":").Append(TrackIdNum(fl.TrackId)).Append(",\"lap\":null,\"gain\":[],\"marks\":[]}");
                sb.Append(",\"laps\":[],\"optimal\":null,\"note\":").Append(Json_.S("No full lap yet")).Append('}');
                return sb.ToString();
            }

            Review.Check();
            Sess s = Get(file);
            Review.Check();
            CornerSet cs = LoadCorners(s);
            Dictionary<long, LapTrace> byRec = new Dictionary<long, LapTrace>();
            foreach (LapTrace lt in s.Laps) if (lt.Tm != null && !lt.Partial) byRec[lt.RecA] = lt;
            List<LapTrace> traces = new List<LapTrace>(), countedTr = new List<LapTrace>();
            Dictionary<LapTrace, LapRec> recOf = new Dictionary<LapTrace, LapRec>();
            foreach (LapRec r in laps)
            {
                LapTrace lt; if (!byRec.TryGetValue(r.StartRecord, out lt)) continue;
                Measure(lt, cs); traces.Add(lt); recOf[lt] = r;
                if (r.Counted) countedTr.Add(lt);
            }
            LapTrace bestTr = null; foreach (LapTrace lt in countedTr) if (best != null && recOf[lt] == best) bestTr = lt;

            // the reference
            LapTrace rf = null; string refKind = "", refFile = file; LapRec refRec = null; long refDate = Ms(fl.StartUtc); Sess refSess = null;
            if (counted >= 3 && bestTr != null) { rf = bestTr; refKind = "session"; refRec = best; }
            else
            {
                string ep; LapRec er; FileLaps ef;
                if (EverBest(fl, file, out ep, out er, out ef))
                {
                    Review.Check();
                    Sess es = Get(ep);
                    Review.Check();
                    foreach (LapTrace lt in es.Laps) if (lt.RecA == er.StartRecord && lt.Tm != null && !lt.Partial) rf = lt;
                    if (rf != null) { Measure(rf, cs); refKind = "ever"; refFile = ep; refRec = er; refDate = Ms(ef.StartUtc); refSess = es; }
                }
                if (rf == null && bestTr != null && countedTr.Count >= 2) { rf = bestTr; refKind = "session"; refRec = best; }
            }
            string refCond = rf != null ? ConditionsLine(refFile, refRec.StartRecord, imperial) : "";
            sb.Append(",\"ref\":");
            if (rf == null) sb.Append("null");
            else sb.Append("{\"kind\":").Append(Json_.S(refKind)).Append(",\"lap\":").Append(refRec.N).Append(",\"time\":").Append(F(refRec.Time, "0.000"))
                   .Append(",\"date\":").Append(refDate.ToString(Inv)).Append(",\"conditions\":").Append(Json_.S(refCond)).Append(",\"file\":").Append(Json_.S(Path.GetFileName(refFile))).Append('}');
            sb.Append(",\"result\":"); AppendResult(sb, story);
            sb.Append(",\"conditions\":").Append(Json_.S(best != null ? ConditionsLine(file, best.StartRecord, imperial) : "")).Append('}');

            // the cards
            bool haveMap = cs != null && cs.Turns != null && cs.Turns.Count > 0 && rf != null && rf.Corners.Count > 0;
            bool habits = rf != null && refKind == "session" && counted >= 3;
            List<RvCard> cards = new List<RvCard>(); List<CoachRow> rows = new List<CoachRow>();
            List<LapTrace> compare = new List<LapTrace>();
            string note = null;
            if (habits)
            {
                // laps in his rhythm only (within 2 % of the best): a start, a traffic or a cool-down lap is not a habit (the coach's rule)
                foreach (LapTrace lt in countedTr) if (!SameLap(lt, rf) && lt.Time <= rf.Time * 1.02) compare.Add(lt);
            }
            else if (rf != null)
            {
                foreach (LapTrace lt in countedTr) if (!SameLap(lt, rf)) compare.Add(lt);
                if (compare.Count == 0 && counted == 0)
                {
                    LapTrace q = null; foreach (LapTrace lt in traces) if ((lt.Clean || lt.Skip == "off") && (q == null || lt.Time < q.Time)) q = lt;
                    if (q != null && !SameLap(q, rf)) compare.Add(q);
                }
            }
            if (haveMap && compare.Count > 0) rows = RowsAgainst(rf, compare);
            if (habits)
            {
                foreach (CoachRow r in rows)
                {
                    if (cards.Count >= 3) break;
                    double med = Median(r.Loss);
                    if (double.IsNaN(med) || med < CoachMinLoss) break;
                    RvCard c = MakeCard(r, 2, true, rf, imperial); c.Rank = cards.Count + 1;
                    c.Sample = "in " + r.Lost + " of " + r.Laps + " clean " + Plural(r.Laps, "lap");
                    cards.Add(c);
                }
                if (cards.Count == 0) note = haveMap ? "No corner lost 0.05 s lap after lap" : "No corner map for this track yet";
            }
            else
            {
                // under 3 clean laps: the one costliest corner, with numbers and no advice
                if (rows.Count > 0 && Median(rows[0].Loss) > 0)
                {
                    RvCard c = MakeCard(rows[0], 1, false, rf, imperial); c.Rank = 1;
                    c.Sample = counted == 0 ? "on your quickest full lap" : "in " + rows[0].Lost + " of " + rows[0].Laps + " clean " + Plural(rows[0].Laps, "lap");
                    cards.Add(c);
                }
                if (rf == null) note = "First drive here: nothing to compare with yet";
                else if (!haveMap) note = "No corner map for this track yet";
                else note = (counted == 0 ? "No clean lap" : "Only " + counted + " clean " + Plural(counted, "lap")) + ": the costliest corner, no advice";
            }
            sb.Append(",\"cards\":[");
            for (int i = 0; i < cards.Count; i++) { if (i > 0) sb.Append(','); AppendCard(sb, cards[i], file, cs); }
            sb.Append("],\"plan\":");
            string plan = "";
            if (habits && cards.Count > 0)
            {
                RvCard c = cards[0];
                // one line, a corner and a number: the board when the brake is the cause, else what the corner is worth
                string head = "Next time: " + Spoken(c.Row.M, Detected(cs, c.Row.M.N)) + ", " + Lower1(c.Try) + (Regex.IsMatch(c.Try, @"\d") ? "" : ", worth " + F(c.Lost, "0.00") + " s");
                plan = head + (c.Check.Length > 0 ? ", check the " + c.Check : "");
                if (Review.Lint(plan) != null) plan = head;
            }
            sb.Append(Json_.S(plan));

            // the race story: positions, pace against the field, the three costliest corners, one clean-air card
            RvCard air = null;
            if (story != null && rf != null && haveMap)
            {
                List<int> airLaps = new List<int>();
                foreach (object o in story.ContainsKey("air") ? story["air"] as object[] ?? new object[0] : new object[0]) airLaps.Add(Convert.ToInt32(o, Inv));
                LapTrace q = null;
                foreach (LapTrace lt in countedTr) if (!SameLap(lt, rf) && airLaps.Contains(lt.Lap) && (q == null || lt.Time < q.Time)) q = lt;
                if (q != null)
                {
                    List<CoachRow> ar = RowsAgainst(rf, new List<LapTrace> { q });
                    if (ar.Count > 0 && Median(ar[0].Loss) >= CoachMinLoss)
                    {
                        air = MakeCard(ar[0], 1, true, rf, imperial); air.Rank = 1; air.CleanAir = true; air.Sample = "clean-air lap " + q.Lap;
                    }
                }
            }
            sb.Append(",\"race\":"); AppendRace(sb, story, rows, air, file, cs);

            // the map: where the typical lap lost (-) or gained (+) time against the reference, per 1 % of the lap
            LapTrace mapLap = null;
            if (rf != null)
            {
                if (compare.Count > 0)
                {
                    List<double> times = new List<double>(); foreach (LapTrace lt in compare) times.Add(lt.Time);
                    double med = Median(times); foreach (LapTrace lt in compare) if (mapLap == null || Math.Abs(lt.Time - med) < Math.Abs(mapLap.Time - med)) mapLap = lt;
                }
            }
            sb.Append(",\"map\":{\"key\":").Append(Json_.S(s.Key)).Append(",\"id\":").Append(TrackIdNum(s.TrackId)).Append(",\"lap\":").Append(mapLap != null ? mapLap.Lap.ToString(Inv) : "null").Append(",\"gain\":[");
            if (mapLap != null)
                for (int i = 0; i < 100; i++)
                {
                    if (i > 0) sb.Append(',');
                    double a = i / 100.0, b = (i + 1) / 100.0;
                    sb.Append(F(Span(rf, a * rf.LengthM, b * rf.LengthM) - Span(mapLap, a * mapLap.LengthM, b * mapLap.LengthM), "0.000"));
                }
            sb.Append("],\"marks\":[");
            for (int i = 0; i < cards.Count; i++) { if (i > 0) sb.Append(','); sb.Append("{\"n\":").Append(cards[i].Rank).Append(",\"p\":").Append(F(cards[i].Row.M.Pa, "0.0000")).Append('}'); }
            sb.Append("]}");

            // every full lap of the session (lap truth from the lap store), its iRacing sectors
            sb.Append(",\"laps\":[");
            for (int i = 0; i < laps.Count; i++)
            {
                LapRec r = laps[i]; LapTrace lt; byRec.TryGetValue(r.StartRecord, out lt);
                if (i > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(r.N).Append(",\"time\":").Append(F(r.Time, "0.000")).Append(",\"counted\":").Append(r.Counted ? "true" : "false")
                  .Append(",\"why\":").Append(Json_.S(r.Counted ? "" : LapRules.Words(r.Why))).Append(",\"whyCode\":").Append(Json_.S(r.Why)).Append(",\"sectors\":[");
                if (lt != null && lt.SectorT != null) for (int k = 0; k < lt.SectorT.Length; k++) { if (k > 0) sb.Append(','); sb.Append(F(lt.SectorT[k], "0.000")); }
                sb.Append("],\"pb\":").Append(r == best ? "true" : "false").Append('}');
            }
            sb.Append(']');

            // the theoretical best: the quickest of the 24 mini-sectors over the laps that may be joined (counted, no off-track at all), with their dates
            List<LapTrace> pool = new List<LapTrace>();
            foreach (LapTrace lt in countedTr) if (Pure(lt) && lt.Mini != null && lt.Mini.Length == 24) pool.Add(lt);
            Dictionary<string, long> dateOf = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase); dateOf[file] = Ms(fl.StartUtc);
            if (refSess != null)
            {
                dateOf[refFile] = refDate;
                foreach (LapTrace lt in refSess.Laps) if (Pure(lt) && lt.Mini != null && lt.Mini.Length == 24 && Math.Abs(lt.LengthM - s.LengthM) <= 1) pool.Add(lt);
            }
            sb.Append(",\"optimal\":");
            if (pool.Count == 0) sb.Append("null");
            else
            {
                double total = 0; StringBuilder from = new StringBuilder();
                for (int k = 0; k < 24; k++)
                {
                    LapTrace src = null;
                    foreach (LapTrace lt in pool) if (src == null || lt.Mini[k] < src.Mini[k] - 1e-9 || (Math.Abs(lt.Mini[k] - src.Mini[k]) <= 1e-9 && Better(lt, src))) src = lt;
                    total += src.Mini[k];
                    long dt; if (!dateOf.TryGetValue(src.Path, out dt)) dt = 0;
                    if (k > 0) from.Append(',');
                    from.Append("{\"sector\":").Append(k + 1).Append(",\"lap\":").Append(src.Lap).Append(",\"date\":").Append(dt.ToString(Inv)).Append('}');
                }
                sb.Append("{\"time\":").Append(F(total, "0.000")).Append(",\"from\":[").Append(from).Append("]}");
            }
            sb.Append(",\"note\":").Append(note == null ? "null" : Json_.S(note)).Append('}');

            cornersJson = CornerTable(sig, imperial, traces, recOf, best, rf, refRec, refFile, cs);
            return sb.ToString();
        }

        static string TrackIdNum(string id) { int n; return int.TryParse(id ?? "", NumberStyles.Integer, Inv, out n) ? n.ToString(Inv) : "null"; }

        static void AppendResult(StringBuilder sb, Dictionary<string, object> story)
        {
            Dictionary<string, object> r = story != null && story.ContainsKey("result") ? story["result"] as Dictionary<string, object> : null;
            if (r == null) { sb.Append("null"); return; }
            Func<string, string> num = delegate (string k) { object o; return r.TryGetValue(k, out o) && o != null ? Convert.ToString(o, Inv) : "null"; };
            object irv; story.TryGetValue("myIR", out irv);
            sb.Append("{\"finish\":").Append(num("finishPosition")).Append(",\"start\":").Append(num("startPosition")).Append(",\"field\":").Append(story.ContainsKey("field") ? Convert.ToString(story["field"], Inv) : "null")
              .Append(",\"irating\":").Append(num("iratingChange")).Append(",\"ir\":").Append(irv != null && Convert.ToInt32(irv, Inv) > 0 ? Convert.ToString(irv, Inv) : "null").Append('}');
        }

        static void AppendRace(StringBuilder sb, Dictionary<string, object> story, List<CoachRow> rows, RvCard air, string file, CornerSet cs)
        {
            if (story == null) { sb.Append("null"); return; }
            sb.Append("{\"positions\":[");
            object[] pl = story.ContainsKey("positionByLap") ? story["positionByLap"] as object[] ?? new object[0] : new object[0];
            for (int i = 0; i < pl.Length; i++)
            {
                Dictionary<string, object> p = pl[i] as Dictionary<string, object>; object v = p != null && p.ContainsKey("position") ? p["position"] : null;
                if (i > 0) sb.Append(','); sb.Append(v == null ? "null" : Convert.ToString(v, Inv));
            }
            Dictionary<string, object> pace = story.ContainsKey("pace") ? story["pace"] as Dictionary<string, object> : null;
            Func<string, string> pv = delegate (string k) { object o; return pace != null && pace.TryGetValue(k, out o) && o != null ? Convert.ToString(o, Inv) : "null"; };
            sb.Append("],\"pace\":{\"mine\":").Append(pv("hisMedian")).Append(",\"field\":").Append(pv("classMedian")).Append(",\"cars\":").Append(pv("n")).Append('}');
            sb.Append(",\"corners\":[");
            int shown = 0;
            if (rows != null)
                foreach (CoachRow r in rows)
                {
                    double med = Median(r.Loss); if (shown >= 3 || double.IsNaN(med) || med <= 0) break;
                    if (shown > 0) sb.Append(',');
                    sb.Append("{\"n\":").Append(r.M.N).Append(",\"label\":").Append(Json_.S(r.M.Label)).Append(",\"lost\":").Append(F(med, "0.00")).Append(",\"clip\":").Append(ClipJson(file, r.Example, r.M.P0)).Append('}');
                    shown++;
                }
            sb.Append("],\"cleanAir\":");
            if (air == null) sb.Append("null"); else AppendCard(sb, air, file, cs);
            sb.Append('}');
        }

        // the corner table of every lap and of the reference (served by /api/review/corners from its own file)
        static string CornerTable(string sig, bool imperial, List<LapTrace> traces, Dictionary<LapTrace, LapRec> recOf, LapRec best, LapTrace rf, LapRec refRec, string refFile, CornerSet cs)
        {
            StringBuilder sb = new StringBuilder(8000);
            sb.Append("{\"sig\":").Append(Json_.S(sig)).Append(",\"units\":").Append(Json_.S(imperial ? "mph" : "km/h")).Append(",\"best\":").Append(best != null ? best.N.ToString(Inv) : "null");
            sb.Append(",\"defs\":{\"brakeM\":\"brake over 10 %, metres from the line\",\"minSpeed\":\"the lowest speed in the corner\",\"pickupM\":\"throttle over 90 % after the apex, metres from the line\",\"time\":\"seconds from the corner's start to its end\"}");
            sb.Append(",\"laps\":[");
            bool first = true;
            foreach (LapTrace lt in traces)
            {
                if (lt.Corners.Count == 0) continue;
                if (!first) sb.Append(','); first = false;
                AppendTableLap(sb, lt, recOf[lt].N, recOf[lt].Time, null, imperial, cs);
            }
            sb.Append("],\"ref\":");
            if (rf == null || rf.Corners.Count == 0) sb.Append("null"); else AppendTableLap(sb, rf, refRec.N, refRec.Time, Path.GetFileName(refFile), imperial, cs);
            return sb.Append('}').ToString();
        }

        static void AppendTableLap(StringBuilder sb, LapTrace lt, int n, double time, string file, bool imperial, CornerSet cs)
        {
            sb.Append("{\"n\":").Append(n).Append(",\"time\":").Append(F(time, "0.000"));
            if (file != null) sb.Append(",\"file\":").Append(Json_.S(file));
            sb.Append(",\"rows\":[");
            for (int i = 0; i < lt.Corners.Count; i++)
            {
                Met m = lt.Corners[i]; if (i > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(m.N).Append(",\"label\":").Append(Json_.S(m.Label)).Append(",\"detected\":").Append(Detected(cs, m.N) ? "true" : "false")
                  .Append(",\"brakeM\":").Append(NZ(m.HasBrake, m.BrakeM, "0")).Append(",\"minSpeed\":").Append(NZ(m.HasMin, SpeedIn(m.Min, imperial), "0.0"))
                  .Append(",\"pickupM\":").Append(NZ(m.HasPickup, m.Pickup, "0")).Append(",\"time\":").Append(F(m.Time, "0.000")).Append('}');
            }
            sb.Append("]}");
        }
    }
}
