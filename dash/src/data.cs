// The data tool (WS4 / WS5 in docs\SPEC-next.md; notes in docs\data.md):
//   - sessions page + weekly progress + pre-session brief: questions asked of the career cache (Career, in irdash.cs)
//   - lap analysis: reads one .ibt from the telemetry folder and answers with a lap list or one lap's traces
//   - race extras: strength of field and an estimated iRating change, from the session YAML
//   - page requests (open the sessions page from a Stream Deck key), sim priority, and the test routes for tests\data-test.ps1
// Everything here only reads: telemetry files are opened read-only and the heavy ones are refused while you drive.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDash
{
    // ---------------- HTTP routes ----------------
    static class DataApi
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        static byte[] Utf8(string s) { return Encoding.UTF8.GetBytes(s); }
        static void Err(out int code, out string type, out byte[] body, int c, string msg)
        { code = c; type = "application/json"; body = Utf8("{\"error\":" + Json_.S(msg) + "}"); }

        // Returns true when the path is one of ours. The caller writes the answer.
        public static bool TryHandle(string path, Dictionary<string, string> q, out int code, out string type, out byte[] body)
        {
            code = 200; type = "application/json"; body = null;
            string v;
            switch (path)
            {
                case "/sessions": body = Utf8(Career.SessionsJson()); return true;
                case "/brief": body = Utf8(Career.BriefJson()); return true;
                case "/race": body = Utf8(Race.Json()); return true;
                case "/nav": body = Utf8(Nav.Json()); return true;
                case "/api/nav":
                    q.TryGetValue("to", out v);
                    if (!Nav.Set(v == "sessions" ? "sessions" : "")) { Err(out code, out type, out body, 409, "not while driving"); return true; }
                    body = Utf8("{\"ok\":true}"); return true;
                case "/api/sessions/open":
                    if (!Nav.Set("sessions")) { Err(out code, out type, out body, 409, "not while driving"); return true; }
                    body = Utf8("{\"ok\":true}"); return true;
                case "/api/sessions/close": Nav.Set(""); body = Utf8("{\"ok\":true}"); return true;
                case "/irating":
                    {
                        // pure arithmetic, used by tests\data-test.ps1: /irating?irs=2800,2500,2200&me=0&pos=1
                        string irs, me, pos; q.TryGetValue("irs", out irs); q.TryGetValue("me", out me); q.TryGetValue("pos", out pos);
                        List<double> r = new List<double>();
                        foreach (string p in (irs ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
                        { double d; if (double.TryParse(p, NumberStyles.Float, Inv, out d) && d > 0) r.Add(d); }
                        int mi, mp;
                        if (r.Count < 2 || r.Count > 200 || !int.TryParse(me ?? "0", out mi) || !int.TryParse(pos ?? "1", out mp) || mi < 0 || mi >= r.Count || mp < 1 || mp > r.Count)
                        { Err(out code, out type, out body, 400, "need irs=a,b,c (2 or more) and me=<index>&pos=<1..n>"); return true; }
                        body = Utf8("{\"n\":" + r.Count + ",\"sof\":" + Race.Sof(r).ToString("0.000", Inv) + ",\"expected\":" + Race.Expected(r, mi).ToString("0.0000", Inv) +
                                    ",\"delta\":" + Race.Change(r, mi, mp).ToString("0.000", Inv) + "}");
                        return true;
                    }
                // ---- WS13 / O5 (refs.cs, bench.cs): the benchmark card, the personal-best reference, the other drivers' laps ----
                case "/bench":
                    {
                        // live=1: the car and track of the session loaded now (what the debrief asks for); sample=1: made-up numbers for pictures
                        string car, track, config, sample, live; q.TryGetValue("car", out car); q.TryGetValue("track", out track); q.TryGetValue("config", out config); q.TryGetValue("sample", out sample); q.TryGetValue("live", out live);
                        if (live == "1") { Combo.Info ci = PbRef.ComboNow; car = ci.Car; track = ci.Track; config = ci.Config; }
                        body = Utf8(Bench.Json(car, track, config, sample == "1")); return true;
                    }
                case "/bench/list": body = Utf8(Bench.ListJson()); return true;
                case "/api/delta/snapshot":
                    {
                        // a picture of the delta bar drawn in memory into tests\shots\<name>.png (no window, nothing on a screen):
                        // /api/delta/snapshot?name=pb-ahead&delta=-0.214&pred=79.386&ref=0&banner=PB 1:19.600 · set 9 Oct
                        string nm, dv, pv, rf, bn; q.TryGetValue("name", out nm); q.TryGetValue("delta", out dv); q.TryGetValue("pred", out pv); q.TryGetValue("ref", out rf); q.TryGetValue("banner", out bn);
                        double dd = 0, pp = 0; int ri = 0;
                        if (nm == null || !Regex.IsMatch(nm, "^[a-z0-9-]{1,40}$")) { Err(out code, out type, out body, 400, "name: letters, digits and dashes only"); return true; }
                        bool okd = double.TryParse(dv ?? "", NumberStyles.Float, Inv, out dd); double.TryParse(pv ?? "", NumberStyles.Float, Inv, out pp); int.TryParse(rf ?? "0", out ri);
                        string pngFile = Path.Combine(Program.RootDir, @"tests\shots\" + nm + ".png");
                        body = Utf8("{\"file\":" + Json_.S(DeltaBar.Snapshot(pngFile, okd, dd, pp, ri, string.IsNullOrEmpty(bn) ? null : bn)) + "}"); return true;
                    }
                case "/pbref/state": body = Utf8(PbRef.StateJson()); return true;
                case "/pbref":
                    {
                        // no car given: the reference the delta bar is using now. With car + track (+ config): that combo's cached reference;
                        // build=1 makes it from the best .ibt first (force=1 even if the cache looks fresh)
                        string car, track, config, build, force, times; q.TryGetValue("car", out car); q.TryGetValue("track", out track); q.TryGetValue("config", out config);
                        q.TryGetValue("build", out build); q.TryGetValue("force", out force); q.TryGetValue("times", out times);
                        if (string.IsNullOrEmpty(car)) { body = Utf8("{\"current\":" + PbRef.RefJson(PbRef.Current, times == "1") + ",\"key\":" + Json_.S(PbRef.KeyNow) + "}"); return true; }
                        config = config ?? ""; track = track ?? "";
                        string why = ""; RefData rd;
                        if (build == "1")
                        {
                            if (Program.IsDriving) { Err(out code, out type, out body, 503, "Not while driving"); return true; }
                            try { rd = PbRef.Ensure(car, track, config, force == "1", out why); }
                            catch (Exception ex) { Log.W("pbref " + car + ": " + ex.Message); Err(out code, out type, out body, 500, "could not build that reference"); return true; }
                        }
                        else rd = PbRef.Load(Combo.Key(car, track, config));
                        body = Utf8("{\"ref\":" + PbRef.RefJson(rd, times == "1") + ",\"why\":" + Json_.S(why) + "}"); return true;
                    }
                case "/fieldlaps":
                    {
                        // the other drivers' laps: numbers for one combo (car + track), or a count of the whole file; scan=1 reads new telemetry files now
                        string car, track, config, scan, ir; q.TryGetValue("car", out car); q.TryGetValue("track", out track); q.TryGetValue("config", out config); q.TryGetValue("scan", out scan); q.TryGetValue("ir", out ir);
                        string msg = "";
                        if (scan == "1")
                        {
                            if (Program.IsDriving) { Err(out code, out type, out body, 503, "Not while driving"); return true; }
                            msg = FieldLaps.Backfill();
                        }
                        if (string.IsNullOrEmpty(car))
                        {
                            List<FieldRow> all = FieldLaps.ReadAll(false);
                            Dictionary<string, HashSet<int>> per = new Dictionary<string, HashSet<int>>();
                            foreach (FieldRow r in all) { if (r.Me) continue; string k = r.Car + "|" + r.Track + "|" + r.Config; HashSet<int> hs; if (!per.TryGetValue(k, out hs)) { hs = new HashSet<int>(); per[k] = hs; } hs.Add(r.Uid); }
                            StringBuilder cb = new StringBuilder();
                            foreach (KeyValuePair<string, HashSet<int>> kv in per) { if (cb.Length > 0) cb.Append(','); cb.Append("{\"combo\":").Append(Json_.S(kv.Key)).Append(",\"drivers\":").Append(kv.Value.Count).Append('}'); }
                            body = Utf8("{\"rows\":" + all.Count + ",\"combos\":[" + cb + "],\"minField\":" + Bench.MinField + ",\"message\":" + Json_.S(msg) + "}"); return true;
                        }
                        int myIr = 0; int.TryParse(ir ?? "", out myIr);
                        if (myIr == 0) { string lic; myIr = Career.LatestIr(out lic); }
                        FieldStats fs = FieldLaps.For(car, track ?? "", config ?? "", myIr);
                        body = Utf8("{\"n\":" + fs.N + ",\"enough\":" + (fs.Enough ? "true" : "false") + ",\"top5\":" + fs.Top5.ToString("0.000", Inv) + ",\"top25\":" + fs.Top25.ToString("0.000", Inv) + ",\"median\":" + fs.Median.ToString("0.000", Inv) +
                                    ",\"simN\":" + fs.SimN + ",\"simMedian\":" + fs.SimMedian.ToString("0.000", Inv) + ",\"myIr\":" + fs.MyIr + ",\"message\":" + Json_.S(msg) + "}"); return true;
                    }
                case "/fieldlaps/scan":
                    {
                        // dry run on one telemetry file: the rows its session text would give (nothing is written)
                        string file; q.TryGetValue("file", out file);
                        if (Program.IsDriving) { Err(out code, out type, out body, 503, "Not while driving"); return true; }
                        string full = IbtLaps.Resolve(file);
                        if (full == null) { Err(out code, out type, out body, 404, "no such telemetry file"); return true; }
                        if (Career.OnlineOnly(new FileInfo(full))) { Err(out code, out type, out body, 409, "Online-only in OneDrive: run tools\\keep-iracing-local.cmd"); return true; }
                        try
                        {
                            int others; List<FieldRow> rows = FieldLaps.ScanFile(full, out others);
                            StringBuilder rb = new StringBuilder();
                            foreach (FieldRow r in rows)
                            {
                                if (rb.Length > 0) rb.Append(',');
                                rb.Append("{\"sid\":").Append(Json_.S(r.Sid)).Append(",\"num\":").Append(r.Num).Append(",\"type\":").Append(Json_.S(r.Type)).Append(",\"car\":").Append(Json_.S(r.Car)).Append(",\"track\":").Append(Json_.S(r.Track))
                                  .Append(",\"config\":").Append(Json_.S(r.Config)).Append(",\"uid\":").Append(r.Uid).Append(",\"ir\":").Append(r.Ir).Append(",\"lic\":").Append(Json_.S(r.Lic)).Append(",\"best\":").Append(r.Best.ToString("0.000", Inv)).Append(",\"laps\":").Append(r.Laps).Append(",\"me\":").Append(r.Me ? "true" : "false").Append('}');
                            }
                            body = Utf8("{\"file\":" + Json_.S(Path.GetFileName(full)) + ",\"otherHumans\":" + others + ",\"rows\":[" + rb + "]}"); return true;
                        }
                        catch (Exception ex) { Log.W("fieldlaps " + file + ": " + ex.Message); Err(out code, out type, out body, 500, "could not read that file"); return true; }
                    }
                case "/ibt/laps":
                case "/ibt/lap":
                    {
                        string file, lap; q.TryGetValue("file", out file); q.TryGetValue("lap", out lap);
                        if (Program.IsDriving) { Err(out code, out type, out body, 503, "Not while driving"); return true; }
                        string full = IbtLaps.Resolve(file);
                        if (full == null) { Err(out code, out type, out body, 404, "no such telemetry file"); return true; }
                        if (Career.OnlineOnly(new FileInfo(full))) { Err(out code, out type, out body, 409, "Online-only in OneDrive: run tools\\keep-iracing-local.cmd"); return true; }
                        try
                        {
                            if (path == "/ibt/laps") { body = Utf8(IbtLaps.LapsJson(full)); return true; }
                            int n;
                            if (!int.TryParse(lap ?? "", out n)) { Err(out code, out type, out body, 400, "lap must be a number"); return true; }
                            string j = IbtLaps.LapJson(full, n);
                            if (j == null) { Err(out code, out type, out body, 404, "no such lap in this file"); return true; }
                            body = Utf8(j); return true;
                        }
                        catch (Exception ex) { Log.W("ibt " + file + ": " + ex.Message); Err(out code, out type, out body, 500, "could not read that file"); return true; }
                    }
            }
            // ---- test routes (only while dash\test-hook.on exists) ----
            if (path.StartsWith("/api/test/") && (path == "/api/test/session" || path == "/api/test/simproc" || path == "/api/test/priority" || path == "/api/test/pbref" || path == "/api/test/pbclear"))
            {
                if (!Sdk.TestHook)
                {
                    string busy = Sdk.RealBusy();
                    if (busy != null) { Log.W("test hook refused: " + busy); Err(out code, out type, out body, 409, "refused: " + busy); }
                    else Err(out code, out type, out body, 404, "not found");
                    return true;
                }
                string file, irs, off, name, pid, mode;
                if (path == "/api/test/pbref" || path == "/api/test/pbclear")
                {
                    // a personal-best reference from one lap of a real .ibt, saved under a made-up car and track ("Test ..."), so the real cache is never touched
                    string tcar, ttrack, tcfg, tlap; q.TryGetValue("file", out file); q.TryGetValue("lap", out tlap);
                    if (!q.TryGetValue("car", out tcar)) tcar = "Test Car"; if (!q.TryGetValue("track", out ttrack)) ttrack = "Test Track"; if (!q.TryGetValue("config", out tcfg)) tcfg = "Test Layout";
                    if (path == "/api/test/pbclear")
                    {
                        if (!PbRef.TestClear(tcar, ttrack, tcfg)) { Err(out code, out type, out body, 400, "only reference files for 'Test ...' cars and tracks can be cleared"); return true; }
                        body = Utf8("{\"ok\":true}"); return true;
                    }
                    if (!tcar.StartsWith("Test ") || !ttrack.StartsWith("Test ")) { Err(out code, out type, out body, 400, "test references use a car and a track that start with 'Test '"); return true; }
                    string tfull = IbtLaps.Resolve(file); int tn;
                    if (tfull == null || !int.TryParse(tlap ?? "", out tn)) { Err(out code, out type, out body, 404, "no such telemetry file or lap"); return true; }
                    RefData made = PbRef.TestBuild(tfull, tn, tcar, ttrack, tcfg);
                    if (made == null) { Err(out code, out type, out body, 404, "no such full lap in that file"); return true; }
                    body = Utf8("{\"ref\":" + PbRef.RefJson(made, false) + "}"); return true;
                }
                if (path == "/api/test/session")
                {
                    // a pretend session whose YAML comes from a real .ibt; irs= gives the first drivers (car 0, 1, 2 ...) those iRatings;
                    // rename=1 swaps the car and track names for "Test Car" / "Test Track" (so the pretend session has its own reference file)
                    string rename; q.TryGetValue("rename", out rename);
                    q.TryGetValue("file", out file); q.TryGetValue("irs", out irs); q.TryGetValue("official", out off);
                    string full = IbtLaps.Resolve(file);
                    if (full == null) { Err(out code, out type, out body, 404, "no such telemetry file"); return true; }
                    TrackMaps.Ibt t = TrackMaps.OpenIbt(full, false);
                    if (t == null) { Err(out code, out type, out body, 400, "unreadable"); return true; }
                    string yaml; using (t.fs) yaml = t.yaml;
                    string[] ratings = (irs ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
                    int k = 0;
                    if (ratings.Length > 0)
                        yaml = Regex.Replace(yaml, "(?m)^(   IRating: )\\d+", delegate (Match m) { string r = k < ratings.Length ? ratings[k] : "0"; k++; return m.Groups[1].Value + Regex.Replace(r, "[^0-9]", ""); });
                    if (off != null) yaml = Regex.Replace(yaml, "(?m)^( Official: )\\d+", "${1}" + (off == "1" ? "1" : "0"));
                    if (rename == "1")
                    {
                        yaml = Regex.Replace(yaml, "(?m)^(   CarScreenName: ).*$", "${1}Test Car");
                        yaml = Regex.Replace(yaml, "(?m)^( TrackDisplayName: ).*$", "${1}Test Track");
                        yaml = Regex.Replace(yaml, "(?m)^( TrackConfigName: ).*$", "${1}Test Layout");
                    }
                    Sdk.FakeSession(yaml);
                    body = Utf8("{\"ok\":true,\"yaml\":" + yaml.Length + "}"); return true;
                }
                if (path == "/api/test/simproc")
                {
                    // the process name the sim-priority code looks for (a harmless test program instead of the real sim)
                    q.TryGetValue("name", out name);
                    SimPriority.ProcName = Regex.IsMatch(name ?? "", "^irdash-test-[a-z0-9-]{1,20}$") ? name : "iRacingSim64DX11";
                    body = Utf8("{\"ok\":true}"); return true;
                }
                q.TryGetValue("pid", out pid); q.TryGetValue("mode", out mode);
                int p;
                if (!int.TryParse(pid ?? "", out p)) { Err(out code, out type, out body, 400, "pid"); return true; }
                string was = SimPriority.ApplyTo(p, mode == "normal" ? "normal" : "high", true);
                body = Utf8("{\"result\":" + Json_.S(was) + "}"); return true;
            }
            return false;
        }
    }

    // ---------------- Sessions, weekly progress and the brief (queries on the career cache) ----------------
    static partial class Career
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // The type of one session in an iRacing YAML ("Practice", "Qualify", "Race" ...); num < 0 = the one being recorded.
        internal static string SessionTypeOf(string yaml, int num)
        {
            if (yaml == null) return "";
            if (num < 0) { int cn; if (!int.TryParse(TrackMaps.YamlValue(yaml, "CurrentSessionNum"), out cn)) return ""; num = cn; }
            Match m = Regex.Match(yaml, "- SessionNum: " + num + "\\b");
            if (!m.Success) return "";
            int next = yaml.IndexOf("- SessionNum:", m.Index + 5, StringComparison.Ordinal), ty = yaml.IndexOf("SessionType:", m.Index, StringComparison.Ordinal);
            if (ty < 0 || (next >= 0 && ty > next)) return "";
            int eol = yaml.IndexOf('\n', ty); if (eol < 0) eol = yaml.Length;
            return yaml.Substring(ty + 12, eol - ty - 12).Trim().Trim('"');
        }

        static string Ago(DateTime local)
        {
            int days = (DateTime.Today - local.Date).Days;
            return local.ToString(local.Year == DateTime.Today.Year ? "ddd d MMM" : "d MMM yyyy", Inv);   // a date, not "yesterday"
        }

        static long Ms(DateTime utc) { return (long)(utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }
        static string N3(double d) { return d.ToString("0.000", Inv); }
        static string TypeOf(Rec r) { return r.SType.Length > 0 ? r.SType : r.Ev; }

        // every session (newest first) and the best lap per car + track + layout, for the sessions page
        public static string SessionsJson()
        {
            lock (gate)
            {
                Load();
                List<Rec> list = new List<Rec>(recs.Values);
                list.Sort(delegate (Rec a, Rec b) { return b.Date.CompareTo(a.Date); });
                HashSet<string> have = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                try { if (TelemetryDir != null && Directory.Exists(TelemetryDir)) foreach (string f in Directory.GetFiles(TelemetryDir, "*.ibt")) have.Add(Path.GetFileName(f)); } catch { }
                StringBuilder sb = new StringBuilder(16000);
                sb.Append("{\"sessions\":[");
                bool first = true;
                Dictionary<string, Rec> pb = new Dictionary<string, Rec>(); Dictionary<string, double[]> sums = new Dictionary<string, double[]>();
                foreach (Rec r in list)
                {
                    if (!first) sb.Append(','); first = false;
                    sb.Append("{\"file\":").Append(Json_.S(r.FileName)).Append(",\"ts\":").Append(Ms(r.Date)).Append(",\"car\":").Append(Json_.S(r.Car))
                      .Append(",\"track\":").Append(Json_.S(r.Track)).Append(",\"config\":").Append(Json_.S(r.Config)).Append(",\"type\":").Append(Json_.S(TypeOf(r)))
                      .Append(",\"laps\":").Append(r.Laps).Append(",\"best\":").Append(r.Best > 0 ? N3(r.Best) : "null").Append(",\"secs\":").Append(Math.Round(r.Secs).ToString(Inv))
                      .Append(",\"km\":").Append((r.Meters / 1000).ToString("0.0", Inv)).Append(",\"fuel\":").Append(r.Fuel > 0 ? N3(r.Fuel) : "null")
                      .Append(",\"short\":").Append(r.Short ? "true" : "false").Append(",\"gone\":").Append(have.Contains(r.FileName) ? "false" : "true").Append('}');
                    if (r.Short || r.Car.Length == 0) continue;
                    string key = r.Car + "|" + r.Track + "|" + r.Config;
                    double[] s; if (!sums.TryGetValue(key, out s)) { s = new double[3]; sums[key] = s; }
                    s[0]++; s[1] += r.Laps; s[2] += r.Secs;
                    Rec b; if (r.Best > 0 && (!pb.TryGetValue(key, out b) || r.Best < b.Best - 0.0005 || (Math.Abs(r.Best - b.Best) <= 0.0005 && r.Date < b.Date))) pb[key] = r;
                }
                sb.Append("],\"pbs\":[");
                first = true;
                List<Rec> pbl = new List<Rec>(pb.Values);
                pbl.Sort(delegate (Rec a, Rec b) { int c = string.Compare(a.Track, b.Track, StringComparison.OrdinalIgnoreCase); return c != 0 ? c : string.Compare(a.Car, b.Car, StringComparison.OrdinalIgnoreCase); });
                foreach (Rec r in pbl)
                {
                    double[] s = sums[r.Car + "|" + r.Track + "|" + r.Config];
                    if (!first) sb.Append(','); first = false;
                    sb.Append("{\"car\":").Append(Json_.S(r.Car)).Append(",\"track\":").Append(Json_.S(r.Track)).Append(",\"config\":").Append(Json_.S(r.Config))
                      .Append(",\"best\":").Append(N3(r.Best)).Append(",\"file\":").Append(Json_.S(r.FileName)).Append(",\"ts\":").Append(Ms(r.Date)).Append(",\"type\":").Append(Json_.S(TypeOf(r)))
                      .Append(",\"sessions\":").Append(s[0].ToString("0")).Append(",\"laps\":").Append(s[1].ToString("0")).Append(",\"secs\":").Append(Math.Round(s[2]).ToString(Inv)).Append('}');
                }
                sb.Append("],\"scanning\":").Append(scanning ? "true" : "false").Append(",\"upgrading\":").Append(pendingUpgrade).Append('}');
                return sb.ToString();
            }
        }

        // this week (Monday 00:00 on) against last week; PBs = layouts where this week's lap is now your best.
        // Called by Json() with the lock held.
        static string WeekJson()
        {
            DateTime now = DateTime.Now;
            DateTime weekStart = now.Date.AddDays(-(((int)now.DayOfWeek + 6) % 7)), prevStart = weekStart.AddDays(-7);
            double secs = 0, prevSecs = 0; int laps = 0, prevLaps = 0, sess = 0, pbs = 0, fresh = 0;
            Dictionary<string, Rec> best = new Dictionary<string, Rec>(); HashSet<string> before = new HashSet<string>();
            foreach (Rec r in recs.Values)
            {
                if (r.Short) continue;
                DateTime d = r.Date.ToLocalTime();
                if (d >= weekStart) { secs += r.Secs; laps += r.Laps; sess++; }
                else if (d >= prevStart) { prevSecs += r.Secs; prevLaps += r.Laps; }
                if (r.Best <= 0 || r.Car.Length == 0) continue;
                string key = r.Car + "|" + r.Track + "|" + r.Config;
                if (d < weekStart) before.Add(key);
                Rec b; if (!best.TryGetValue(key, out b) || r.Best < b.Best - 0.0005 || (Math.Abs(r.Best - b.Best) <= 0.0005 && r.Date < b.Date)) best[key] = r;
            }
            foreach (KeyValuePair<string, Rec> kv in best)
                if (kv.Value.Date.ToLocalTime() >= weekStart) { if (before.Contains(kv.Key)) pbs++; else fresh++; }
            return "\"week\":{\"hours\":" + (secs / 3600).ToString("0.0", Inv) + ",\"laps\":" + laps + ",\"pbs\":" + pbs + ",\"fresh\":" + fresh + ",\"sessions\":" + sess +
                   ",\"lastHours\":" + (prevSecs / 3600).ToString("0.0", Inv) + ",\"lastLaps\":" + prevLaps + ",\"from\":" + Json_.S(weekStart.ToString("ddd d MMM", Inv)) + "}";
        }

        // ---- for the personal-best reference and the benchmark card (refs.cs, bench.cs) ----
        static bool SameCombo(Rec r, string car, string track, string config) { return r.Car == car && r.Track == track && r.Config == config && !r.Short; }

        // the best lap ever for one car + track + layout, and the file and date it came from (the same rule as the personal-best table)
        internal static bool BestFor(string car, string track, string config, out double time, out string file, out DateTime date)
        {
            time = 0; file = ""; date = DateTime.MinValue;
            lock (gate)
            {
                Load();
                foreach (Rec r in recs.Values)
                {
                    if (r.Best <= 0 || !SameCombo(r, car, track, config)) continue;
                    if (time == 0 || r.Best < time - 0.0005 || (Math.Abs(r.Best - time) <= 0.0005 && r.Date < date)) { time = r.Best; file = r.FileName; date = r.Date; }
                }
            }
            return time > 0;
        }

        // every file with a timed lap for the combo, fastest first (the reference tries them in this order)
        internal static List<BestRow> BestFiles(string car, string track, string config)
        {
            List<BestRow> l = new List<BestRow>();
            lock (gate)
            {
                Load();
                foreach (Rec r in recs.Values)
                    if (r.Best > 0 && SameCombo(r, car, track, config)) { BestRow b = new BestRow(); b.File = r.FileName; b.Best = r.Best; b.Date = r.Date; l.Add(b); }
            }
            l.Sort(delegate (BestRow a, BestRow b) { int c = a.Best.CompareTo(b.Best); return c != 0 ? c : a.Date.CompareTo(b.Date); });
            return l;
        }

        // one row per session of the combo, oldest first: best lap, laps, seat time (for the benchmark's history line)
        internal static List<double[]> HistoryFor(string car, string track, string config, out int sessions, out double laps, out double secs, out string lastType)
        {
            sessions = 0; laps = 0; secs = 0; lastType = "";
            List<Rec> rows = new List<Rec>();
            lock (gate)
            {
                Load();
                foreach (Rec r in recs.Values) if (SameCombo(r, car, track, config)) rows.Add(r);
            }
            rows.Sort(delegate (Rec a, Rec b) { return a.Date.CompareTo(b.Date); });
            List<double[]> h = new List<double[]>();
            foreach (Rec r in rows)
            {
                sessions++; laps += r.Laps; secs += r.Secs; lastType = TypeOf(r);
                if (r.Best > 0) h.Add(new[] { (double)Ms(r.Date), r.Best });
            }
            return h;
        }

        // iRacing's own names for the combo (car folder, track and layout), read from the telemetry file names:
        //   <car folder>_<track and layout> <yyyy-mm-dd hh-mm-ss>.ibt   e.g. chevyvettez06rgt3_roadatlanta full 2026-10-09 14-58-37.ibt
        internal static bool IdsFor(string car, string track, string config, out string carPath, out string trackName)
        {
            carPath = ""; trackName = "";
            lock (gate)
            {
                Load();
                foreach (Rec r in recs.Values)
                {
                    if (!SameCombo(r, car, track, config)) continue;
                    Match m = Regex.Match(r.FileName, @"^(.+?)_(.+) \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\.ibt$");
                    if (m.Success) { carPath = m.Groups[1].Value; trackName = m.Groups[2].Value; return true; }
                }
            }
            return false;
        }

        // your newest real iRating and licence (AI sessions list you as a rookie with iRating 1, so they do not count)
        internal static int LatestIr(out string lic)
        {
            lic = ""; int ir = 0; DateTime when = DateTime.MinValue;
            lock (gate)
            {
                Load();
                foreach (Rec r in recs.Values)
                    if (r.IR > 1 && r.Lic.Length > 0 && r.When > when) { when = r.When; ir = r.IR; lic = r.Lic; }
            }
            return ir;
        }

        // every car + track + layout with a timed lap, for /bench/list
        internal static List<string[]> Combos()
        {
            List<string[]> l = new List<string[]>(); HashSet<string> seen = new HashSet<string>();
            lock (gate)
            {
                Load();
                foreach (Rec r in recs.Values)
                {
                    if (r.Best <= 0 || r.Short || r.Car.Length == 0) continue;
                    string k = r.Car + "|" + r.Track + "|" + r.Config;
                    if (seen.Add(k)) l.Add(new[] { r.Car, r.Track, r.Config });
                }
            }
            l.Sort(delegate (string[] a, string[] b) { int c = string.Compare(a[1], b[1], StringComparison.OrdinalIgnoreCase); return c != 0 ? c : string.Compare(a[0], b[0], StringComparison.OrdinalIgnoreCase); });
            return l;
        }

        // Pre-session brief: what the history says about the car and track that are loaded right now.
        public static string BriefJson()
        {
            Frame f = Sdk.Latest;
            string yaml = f.Connected ? f.SessionYaml : "";
            if (string.IsNullOrEmpty(yaml)) return "{\"ready\":false}";
            string track = TrackMaps.YamlValue(yaml, "TrackDisplayName"), config = TrackMaps.YamlValue(yaml, "TrackConfigName"), car = "";
            string me = TrackMaps.YamlValue(yaml, "DriverCarIdx");
            Match block = Regex.Match(yaml, "- CarIdx: " + Regex.Escape(me) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
            if (me.Length > 0 && block.Success) car = TrackMaps.YamlValue(block.Groups[1].Value, "CarScreenName");
            lock (gate)
            {
                Load();
                Rec pb = null, pbAny = null, lastHere = null, lastCar = null;
                int here = 0, hereCar = 0; double secsCar = 0, lapsCar = 0; List<double> fuels = new List<double>(); int fuelLaps = 0;
                foreach (Rec r in recs.Values)
                {
                    // a row from before the layout was recorded matches on the track name alone
                    if (r.Track != track || (config.Length > 0 && r.Config.Length > 0 && r.Config != config)) continue;
                    bool real = !r.Short, mine = car.Length > 0 && r.Car == car;
                    if (real) { here++; if (lastHere == null || r.Date > lastHere.Date) lastHere = r; }
                    if (r.Best > 0 && (pbAny == null || r.Best < pbAny.Best)) pbAny = r;
                    if (!mine) continue;
                    if (real) { hereCar++; secsCar += r.Secs; lapsCar += r.Laps; if (lastCar == null || r.Date > lastCar.Date) lastCar = r; }
                    if (r.Best > 0 && (pb == null || r.Best < pb.Best)) pb = r;
                    if (r.Fuel > 0 && r.FuelLaps >= 2) { fuels.Add(r.Fuel); fuelLaps += r.FuelLaps; }
                }
                StringBuilder sb = new StringBuilder("{\"ready\":true,\"track\":" + Json_.S(track) + ",\"config\":" + Json_.S(config) + ",\"car\":" + Json_.S(car));
                sb.Append(",\"pb\":").Append(pb == null ? "null" : "{\"time\":" + N3(pb.Best) + ",\"ts\":" + Ms(pb.Date) + ",\"ago\":" + Json_.S(Ago(pb.Date.ToLocalTime())) + ",\"type\":" + Json_.S(TypeOf(pb)) + "}");
                sb.Append(",\"pbAny\":").Append(pbAny == null || (pb != null && pbAny.Best >= pb.Best - 0.0005) ? "null" : "{\"time\":" + N3(pbAny.Best) + ",\"car\":" + Json_.S(pbAny.Car) + "}");
                sb.Append(",\"lastCar\":").Append(lastCar == null ? "null" : "{\"ts\":" + Ms(lastCar.Date) + ",\"ago\":" + Json_.S(Ago(lastCar.Date.ToLocalTime())) + "}");
                sb.Append(",\"lastHere\":").Append(lastHere == null ? "null" : "{\"ts\":" + Ms(lastHere.Date) + ",\"ago\":" + Json_.S(Ago(lastHere.Date.ToLocalTime())) + ",\"car\":" + Json_.S(lastHere.Car) + "}");
                sb.Append(",\"sessions\":").Append(here).Append(",\"sessionsCar\":").Append(hereCar).Append(",\"hoursCar\":").Append((secsCar / 3600).ToString("0.0", Inv)).Append(",\"lapsCar\":").Append(lapsCar.ToString("0"));
                sb.Append(",\"fuel\":").Append(fuels.Count > 0 ? N3(Median(fuels)) : "null").Append(",\"fuelLaps\":").Append(fuelLaps).Append(",\"fuelFiles\":").Append(fuels.Count).Append('}');
                return sb.ToString();
            }
        }
    }

    sealed class BestRow { public string File; public double Best; public DateTime Date; }

    // ---------------- Lap analysis (reads one .ibt at a time) ----------------
    static class IbtLaps
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // Only a plain file name from the telemetry folder: the name is matched against what the folder actually
        // holds, so nothing the browser sends is ever used as (part of) a path.
        public static string Resolve(string name)
        {
            if (string.IsNullOrEmpty(name) || name.Length > 160 || !Regex.IsMatch(name, @"^[A-Za-z0-9 _.\-]+\.ibt$")) return null;
            string dir = TrackMaps.TelemetryDir;
            if (dir == null || !Directory.Exists(dir)) return null;
            foreach (string f in Directory.GetFiles(dir, "*.ibt"))
                if (string.Equals(Path.GetFileName(f), name, StringComparison.OrdinalIgnoreCase)) return f;
            return null;
        }

        sealed class Lap { public int N, Start, End; public double Time, T0, T1; public bool Full, Pit, Off, Official, Counted; public int Inc; }   // Counted: iRacing counted the lap (LapRules, analysis.cs)

        // the whole file, kept as plain arrays (about 3 MB for an hour of driving)
        sealed class Chan
        {
            public string Sig, Track = "", Config = "", TrackName = "", TrackId = "", Car = "", SType = "", Ev = "";
            public DateTime Start; public double LengthM; public int N, Rate;
            public double[] St; public float[] Pct, Spd, Thr, Brk, Steer, Llt, LBest; public short[] Gear; public int[] LapNo, Inc; public byte[] Flags, Surf;   // Flags: 1 on track, 2 pit road; LBest: iRacing's own best lap of the session (null when the file has no such channel)
            public List<Lap> Laps = new List<Lap>(); public int Best = -1, Partial;
        }

        static readonly object gate = new object();
        static readonly List<Chan> cache = new List<Chan>();

        static double At(byte[] b, int o, VarDef d)
        {
            if (d == null) return 0;
            int p = o + d.Offset;
            switch (d.Type)
            {
                case 0: case 1: return b[p];
                case 2: case 3: return BitConverter.ToInt32(b, p);
                case 4: return BitConverter.ToSingle(b, p);
                case 5: return BitConverter.ToDouble(b, p);
            }
            return 0;
        }

        static Chan Get(string path)
        {
            FileInfo fi = new FileInfo(path);
            string sig = fi.Name + "|" + fi.Length + "|" + fi.LastWriteTimeUtc.Ticks;
            lock (gate)
            {
                foreach (Chan c in cache) if (c.Sig == sig) { cache.Remove(c); cache.Insert(0, c); return c; }
                Chan n = Load(path); n.Sig = sig;
                cache.Insert(0, n); while (cache.Count > 4) cache.RemoveAt(cache.Count - 1);
                return n;
            }
        }

        static Chan Load(string path)
        {
            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
            if (t == null) throw new IOException("not a telemetry file");
            using (t.fs)
            {
                Chan c = new Chan();
                c.Track = TrackMaps.YamlValue(t.yaml, "TrackDisplayName"); c.Config = TrackMaps.YamlValue(t.yaml, "TrackConfigName");
                c.TrackName = TrackMaps.YamlValue(t.yaml, "TrackName"); c.TrackId = TrackMaps.YamlValue(t.yaml, "TrackID"); c.Ev = TrackMaps.YamlValue(t.yaml, "EventType"); c.SType = Career.SessionTypeOf(t.yaml, -1);
                string me = TrackMaps.YamlValue(t.yaml, "DriverCarIdx");
                Match block = Regex.Match(t.yaml, "- CarIdx: " + Regex.Escape(me) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
                if (me.Length > 0 && block.Success) c.Car = TrackMaps.YamlValue(block.Groups[1].Value, "CarScreenName");
                Match len = Regex.Match(TrackMaps.YamlValue(t.yaml, "TrackLength"), @"^([\d.]+)\s*(km|mi)");
                double L; if (len.Success && double.TryParse(len.Groups[1].Value, NumberStyles.Float, Inv, out L)) c.LengthM = L * (len.Groups[2].Value == "mi" ? 1609.344 : 1000);
                byte[] h = new byte[144]; t.fs.Position = 0; t.fs.Read(h, 0, 144);
                c.Rate = BitConverter.ToInt32(h, 8); if (c.Rate <= 0) c.Rate = 60;
                long sd = BitConverter.ToInt64(h, 112);
                if (sd > 1000000000L && sd < 4000000000L) c.Start = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(sd);
                VarDef vSt = Var(t, "SessionTime"), vPct = Var(t, "LapDistPct"), vLap = Var(t, "Lap"), vOn = Var(t, "IsOnTrack"), vPit = Var(t, "OnPitRoad"), vSurf = Var(t, "PlayerTrackSurface"),
                       vSpd = Var(t, "Speed"), vThr = Var(t, "Throttle"), vBrk = Var(t, "Brake"), vGear = Var(t, "Gear"), vSteer = Var(t, "SteeringWheelAngle"), vLlt = Var(t, "LapLastLapTime"), vInc = Var(t, "PlayerCarMyIncidentCount"), vBest = Var(t, "LapBestLapTime");
                if (vSt == null || vPct == null || vLap == null || vOn == null) throw new IOException("this file has no lap data");
                int n = (int)Math.Min(t.records, 2000000L);
                if (vBest != null) c.LBest = new float[n];
                c.N = n; c.St = new double[n]; c.Pct = new float[n]; c.Spd = new float[n]; c.Thr = new float[n]; c.Brk = new float[n]; c.Steer = new float[n]; c.Llt = new float[n];
                c.Gear = new short[n]; c.LapNo = new int[n]; c.Inc = new int[n]; c.Flags = new byte[n]; c.Surf = new byte[n];
                int per = Math.Max(1, (4 << 20) / t.bufLen);
                byte[] buf = new byte[per * t.bufLen];
                t.fs.Position = t.dataOff;
                int i = 0;
                while (i < n)
                {
                    int want = Math.Min(per, n - i), got = 0;
                    while (got < want * t.bufLen) { int r = t.fs.Read(buf, got, want * t.bufLen - got); if (r <= 0) break; got += r; }
                    int recs = got / t.bufLen;
                    if (recs == 0) break;
                    for (int k = 0; k < recs; k++, i++)
                    {
                        int o = k * t.bufLen;
                        c.St[i] = At(buf, o, vSt); c.Pct[i] = (float)At(buf, o, vPct); c.LapNo[i] = (int)At(buf, o, vLap);
                        c.Spd[i] = (float)At(buf, o, vSpd); c.Thr[i] = (float)At(buf, o, vThr); c.Brk[i] = (float)At(buf, o, vBrk);
                        c.Steer[i] = (float)At(buf, o, vSteer); c.Llt[i] = (float)At(buf, o, vLlt); c.Gear[i] = (short)At(buf, o, vGear);
                        if (c.LBest != null) c.LBest[i] = (float)At(buf, o, vBest);
                        c.Inc[i] = (int)At(buf, o, vInc); c.Surf[i] = (byte)(vSurf == null ? 3 : Math.Max(0, Math.Min(255, At(buf, o, vSurf) + 1)));   // stored +1 so -1 (not in world) fits a byte
                        c.Flags[i] = (byte)((At(buf, o, vOn) != 0 ? 1 : 0) | (vPit != null && At(buf, o, vPit) != 0 ? 2 : 0));
                    }
                    if (recs < want) break;
                }
                c.N = i;
                Segment(c);
                return c;
            }
        }

        static VarDef Var(TrackMaps.Ibt t, string name) { VarDef d; return t.vars.TryGetValue(name, out d) ? d : null; }

        // where (in session seconds) the car crossed the line between record k-1 and k
        static double Cross(Chan c, int k)
        {
            double p0 = c.Pct[k - 1], p1 = c.Pct[k], span = (1 - p0) + p1;
            double f = span > 1e-6 ? (1 - p0) / span : 1;
            return c.St[k - 1] + (c.St[k] - c.St[k - 1]) * Math.Max(0, Math.Min(1, f));
        }

        // Cuts the file into laps: a run is one lap counter value while on track. A lap is "full" when it began
        // and ended with a clean crossing of the line (not the first lap after getting in, not a tow or reset).
        static void Segment(Chan c)
        {
            List<Lap> runs = new List<Lap>();
            int i = 0;
            while (i < c.N)
            {
                if ((c.Flags[i] & 1) == 0) { i++; continue; }
                int j = i + 1;
                while (j < c.N && (c.Flags[j] & 1) != 0 && c.LapNo[j] == c.LapNo[i] && c.St[j] - c.St[j - 1] < 0.5) j++;
                Lap r = new Lap(); r.N = c.LapNo[i]; r.Start = i; r.End = j; runs.Add(r);
                i = j;
            }
            for (int k = 0; k < runs.Count; k++)
            {
                Lap r = runs[k];
                bool pre = k > 0 && runs[k - 1].End == r.Start && runs[k - 1].N == r.N - 1 && c.Pct[r.Start - 1] > 0.8 && c.Pct[r.Start] < 0.2;
                bool post = k + 1 < runs.Count && r.End == runs[k + 1].Start && runs[k + 1].N == r.N + 1 && c.Pct[r.End - 1] > 0.8 && c.Pct[r.End] < 0.2;
                if (!(pre && post)) { c.Partial++; continue; }
                r.Full = true;
                r.T0 = Cross(c, r.Start); r.T1 = Cross(c, r.End);
                double computed = r.T1 - r.T0, official = 0;
                int at = Math.Min(r.End + 90, runs[k + 1].End - 1);       // iRacing announces the time a moment after the line
                if (at >= 0 && at < c.N) official = c.Llt[at];
                if (official > 1 && Math.Abs(official - computed) < 0.15) { r.Time = official; r.Official = true; } else r.Time = computed;
                int off = 0;
                for (int x = r.Start; x < r.End; x++) { if ((c.Flags[x] & 2) != 0) r.Pit = true; if (c.Surf[x] == 1) off++; }   // stored +1: 1 = off track
                r.Off = off >= 45;
                // L-1: the lap rule, the same one as the Session Review's (LapRules.Judge): timed by iRacing, then iRacing's own best lap decides, the off-track record only where that says nothing
                r.Counted = LapRules.Counted(r.Official && !r.Pit && r.Time >= 15 && r.Time <= 900, off > 0, c.LBest != null,
                    c.LBest != null ? LapRules.BestBefore(c.LBest, c.N, r.End) : -1, c.LBest != null ? LapRules.BestAfter(c.LBest, c.N, r.End) : -1, r.Time);
                r.Inc = Math.Max(0, c.Inc[r.End - 1] - c.Inc[r.Start]);
                c.Laps.Add(r);
            }
            // best: the quickest lap iRacing counted (L-1); when none was counted, the quickest that did not go through the pits (the lap list still needs a lap to draw against)
            for (int k = 0; k < c.Laps.Count; k++)
            {
                Lap r = c.Laps[k];
                if (r.Time < 15) continue;
                if (c.Best < 0) { c.Best = k; continue; }
                Lap b = c.Laps[c.Best];
                if (r.Counted != b.Counted ? r.Counted : ((b.Pit && !r.Pit) || (b.Pit == r.Pit && r.Time < b.Time))) c.Best = k;
            }
        }

        static string F(double d, string fmt) { return d.ToString(fmt, Inv); }

        public static string LapsJson(string path)
        {
            Chan c = Get(path);
            StringBuilder sb = new StringBuilder(4000);
            sb.Append("{\"file\":").Append(Json_.S(Path.GetFileName(path))).Append(",\"track\":").Append(Json_.S(c.Track)).Append(",\"config\":").Append(Json_.S(c.Config))
              .Append(",\"trackName\":").Append(Json_.S(c.TrackName)).Append(",\"trackId\":").Append(Json_.S(c.TrackId)).Append(",\"car\":").Append(Json_.S(c.Car)).Append(",\"type\":").Append(Json_.S(c.SType.Length > 0 ? c.SType : c.Ev))
              .Append(",\"start\":").Append(c.Start == DateTime.MinValue ? "null" : Json_.S(c.Start.ToLocalTime().ToString("s", Inv))).Append(",\"lengthM\":").Append(F(c.LengthM, "0"))
              .Append(",\"startMs\":").Append(c.Start == DateTime.MinValue ? "null" : ((long)(c.Start - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds).ToString()).Append(",\"st0\":").Append(c.N > 0 ? F(c.St[0], "0.000") : "null")   // Vault (vault.cs): wall clock of the first sample and its SessionTime
              .Append(",\"seconds\":").Append(F(c.N / (double)c.Rate, "0")).Append(",\"partial\":").Append(c.Partial).Append(",\"best\":").Append(c.Best < 0 ? "null" : c.Laps[c.Best].N.ToString())
              .Append(",\"laps\":[");
            for (int k = 0; k < c.Laps.Count; k++)
            {
                Lap r = c.Laps[k];
                if (k > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(r.N).Append(",\"time\":").Append(F(r.Time, "0.000")).Append(",\"pit\":").Append(r.Pit ? 1 : 0).Append(",\"off\":").Append(r.Off ? 1 : 0).Append(",\"counted\":").Append(r.Counted ? 1 : 0)
                  .Append(",\"inc\":").Append(r.Inc).Append(",\"official\":").Append(r.Official ? 1 : 0).Append(",\"t0\":").Append(F(r.T0, "0.000")).Append(",\"t1\":").Append(F(r.T1, "0.000")).Append('}');   // t0/t1: SessionTime at the line (Vault video sync)
            }
            sb.Append("]}");
            return sb.ToString();
        }

        // ---- a reference lap for the delta bar (refs.cs): the lap time at every 1/points of the lap ----
        public sealed class RefLap { public int Lap; public double Time; public DateTime When; public double[] T; }

        // The full, pits-free lap in the file whose time is within tol of target (the best lap the career cache found there).
        // L-1: only a lap iRacing COUNTED can be the reference (LapRules); a lap it timed but left out of its best lap is never picked, even when its time is the closest.
        public static RefLap Reference(string path, double target, double tol, int points)
        {
            Chan c = Get(path);
            Lap pick = null;
            foreach (Lap x in c.Laps)          // c.Laps holds full laps only (both line crossings seen)
            {
                if (x.Pit || x.Time < 15 || !x.Counted) continue;
                double d = Math.Abs(x.Time - target);
                if (d <= tol && (pick == null || d < Math.Abs(pick.Time - target))) pick = x;
            }
            if (pick == null) return null;
            RefLap rl = new RefLap();
            rl.Lap = pick.N; rl.Time = pick.Time; rl.T = Times(c, pick, points);
            rl.When = c.Start == DateTime.MinValue ? DateTime.Now : c.Start.AddSeconds(pick.T1 - c.St[0]).ToLocalTime();
            return rl;
        }

        // one chosen lap (tests): the same result as Reference
        public static RefLap ReferenceLapNo(string path, int lapNo, int points)
        {
            Chan c = Get(path);
            foreach (Lap x in c.Laps)
            {
                if (x.N != lapNo) continue;
                RefLap rl = new RefLap();
                rl.Lap = x.N; rl.Time = x.Time; rl.T = Times(c, x, points);
                rl.When = c.Start == DateTime.MinValue ? DateTime.Now : c.Start.AddSeconds(x.T1 - c.St[0]).ToLocalTime();
                return rl;
            }
            return null;
        }

        // the same walk as LapJson, for the time only: points + 1 values, 0 at the line and the lap time at the end
        static double[] Times(Chan c, Lap r, int points)
        {
            int a = r.Start, b = Math.Min(c.N, r.End + 3), m = b - a;
            double[] X = new double[m];
            for (int k = 0; k < m; k++)
            {
                double x = c.Pct[a + k] + (a + k >= r.End ? 1 : 0);
                X[k] = k > 0 && x < X[k - 1] ? X[k - 1] : x;
            }
            double scale = r.Official && r.T1 - r.T0 > 1 ? r.Time / (r.T1 - r.T0) : 1;
            double[] T = new double[points + 1];
            int j = 1;
            for (int g = 0; g <= points; g++)
            {
                double target = g / (double)points;
                while (j < m - 1 && X[j] < target) j++;
                int i1 = a + j, i0 = a + j - 1;
                double w = X[j] - X[j - 1] > 1e-9 ? (target - X[j - 1]) / (X[j] - X[j - 1]) : 0;
                w = Math.Max(0, Math.Min(1, w));
                if (target <= X[0]) w = 0;
                double t = (c.St[i0] + (c.St[i1] - c.St[i0]) * w - r.T0) * scale;
                if (g == 0) t = 0;
                if (g == points) t = r.Time;
                T[g] = g > 0 ? Math.Max(T[g - 1], t) : t;
            }
            return T;
        }

        const int Points = 1000;   // 1001 samples, one per 0.1 % of the lap

        // One full lap resampled onto an even grid of lap distance, so two laps line up point for point.
        public static string LapJson(string path, int lapNo)
        {
            Chan c = Get(path);
            Lap r = null;
            foreach (Lap x in c.Laps) if (x.N == lapNo) { r = x; break; }
            if (r == null) return null;
            int a = r.Start, b = Math.Min(c.N, r.End + 3);
            int m = b - a;
            double[] X = new double[m];
            for (int k = 0; k < m; k++)
            {
                double x = c.Pct[a + k] + (a + k >= r.End ? 1 : 0);
                X[k] = k > 0 && x < X[k - 1] ? X[k - 1] : x;               // never goes backwards (noise at the line)
            }
            double scale = r.Official && r.T1 - r.T0 > 1 ? r.Time / (r.T1 - r.T0) : 1;
            StringBuilder spd = new StringBuilder(8000), thr = new StringBuilder(4000), brk = new StringBuilder(4000), gear = new StringBuilder(3000), steer = new StringBuilder(6000), tm = new StringBuilder(8000);
            int j = 1;
            for (int g = 0; g <= Points; g++)
            {
                double target = g / (double)Points;
                while (j < m - 1 && X[j] < target) j++;
                int i1 = a + j, i0 = a + j - 1;
                double w = X[j] - X[j - 1] > 1e-9 ? (target - X[j - 1]) / (X[j] - X[j - 1]) : 0;
                w = Math.Max(0, Math.Min(1, w));
                if (target <= X[0]) w = 0;
                Func<float[], double> lerp = delegate (float[] arr) { return arr[i0] + (arr[i1] - arr[i0]) * w; };
                // elapsed time since the line (session seconds, interpolated), stretched a hair to match iRacing's own lap time
                double t = (c.St[i0] + (c.St[i1] - c.St[i0]) * w - r.T0) * scale;
                if (g == 0) t = 0;
                if (g == Points) t = r.Time;
                string sep = g > 0 ? "," : "";
                spd.Append(sep).Append(F(lerp(c.Spd), "0.00"));
                thr.Append(sep).Append(F(Math.Max(0, Math.Min(1, lerp(c.Thr))) * 100, "0"));
                brk.Append(sep).Append(F(Math.Max(0, Math.Min(1, lerp(c.Brk))) * 100, "0"));
                gear.Append(sep).Append(c.Gear[w < 0.5 ? i0 : i1]);
                steer.Append(sep).Append(F(lerp(c.Steer) * 180 / Math.PI, "0.0"));
                tm.Append(sep).Append(F(t, "0.000"));
            }
            return "{\"lap\":" + r.N + ",\"time\":" + F(r.Time, "0.000") + ",\"points\":" + (Points + 1) + ",\"lengthM\":" + F(c.LengthM, "0") + ",\"official\":" + (r.Official ? 1 : 0) +
                   ",\"spd\":[" + spd + "],\"thr\":[" + thr + "],\"brk\":[" + brk + "],\"gear\":[" + gear + "],\"steer\":[" + steer + "],\"t\":[" + tm + "]}";
        }
    }

    // ---------------- Strength of field and iRating estimate ----------------
    // The community formula for iRating (iRacing has never published theirs, but this one matches it closely):
    //   BR1 = 1600 / ln 2.   Chance that A beats B = (1-a)·b / ((1-a)·b + a·(1-b)),  a = e^(-Ra/BR1),  b = e^(-Rb/BR1)
    //   Expected score of a driver = the sum of that chance against every other driver in the class
    //   Change = (starters - finishing place - expected score) * 200 / starters       (nobody retiring is assumed)
    //   Strength of field = -BR1 * ln( average of e^(-R/BR1) )
    static class Race
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public static readonly double BR1 = 1600.0 / Math.Log(2.0);

        public static double Chance(double ra, double rb)
        {
            double a = Math.Exp(-ra / BR1), b = Math.Exp(-rb / BR1), den = (1 - a) * b + a * (1 - b);
            return den <= 0 ? 0.5 : (1 - a) * b / den;
        }
        public static double Sof(IList<double> r)
        {
            double s = 0; foreach (double x in r) s += Math.Exp(-x / BR1);
            return -BR1 * Math.Log(s / r.Count);
        }
        public static double Expected(IList<double> r, int me)
        {
            double e = 0; for (int j = 0; j < r.Count; j++) if (j != me) e += Chance(r[me], r[j]);
            return e;
        }
        public static double Change(IList<double> r, int me, int place) { return (r.Count - place - Expected(r, me)) * 200.0 / r.Count; }

        sealed class Drv { public int Idx, Cls, Ir; public bool Pace, Spec; public string Name = "", ClsName = ""; }

        static List<Drv> Drivers(string yaml)
        {
            List<Drv> l = new List<Drv>();
            foreach (Match m in Regex.Matches(yaml, @"- CarIdx: (\d+)[ \t]*\r?\n((?:   [^\r\n]*\r?\n?)*)"))
            {
                string b = m.Groups[2].Value; Drv d = new Drv();
                d.Idx = int.Parse(m.Groups[1].Value);
                int.TryParse(TrackMaps.YamlValue(b, "CarClassID"), out d.Cls); int.TryParse(TrackMaps.YamlValue(b, "IRating"), out d.Ir);
                d.Pace = TrackMaps.YamlValue(b, "CarIsPaceCar") == "1"; d.Spec = TrackMaps.YamlValue(b, "IsSpectator") == "1";
                d.Name = TrackMaps.YamlValue(b, "UserName"); d.ClsName = TrackMaps.YamlValue(b, "CarClassShortName");
                l.Add(d);
            }
            return l;
        }

        static int cachedVer = -1, cachedLen = -1; static List<Drv> cached;

        public static string Json()
        {
            Frame f = Sdk.Latest;
            if (!f.Connected || string.IsNullOrEmpty(f.SessionYaml)) return "{\"on\":false,\"why\":\"no session\"}";
            string yaml = f.SessionYaml;
            string type = Career.SessionTypeOf(yaml, (int)f.Num("SessionNum"));
            if (!Regex.IsMatch(type, "race", RegexOptions.IgnoreCase)) return "{\"on\":false,\"why\":\"not a race\"}";
            List<Drv> all;
            lock (typeof(Race))
            {
                if (cached == null || cachedVer != f.SessionVersion || cachedLen != yaml.Length) { cached = Drivers(yaml); cachedVer = f.SessionVersion; cachedLen = yaml.Length; }
                all = cached;
            }
            int meIdx; if (!int.TryParse(TrackMaps.YamlValue(yaml, "DriverCarIdx"), out meIdx)) meIdx = (int)f.Num("PlayerCarIdx");
            Drv me = null; foreach (Drv d in all) if (d.Idx == meIdx) me = d;
            if (me == null) return "{\"on\":false,\"why\":\"not in the driver list\"}";
            // your class only; drivers without a rating (AI cars, pace car, spectators) are not part of the field
            List<double> field = new List<double>(); int mine = -1;
            foreach (Drv d in all)
            {
                if (d.Cls != me.Cls || d.Pace || d.Spec || d.Ir < 1 || (d.Idx != me.Idx && d.Ir < 100)) continue;
                if (d.Idx == me.Idx) mine = field.Count;
                field.Add(d.Ir);
            }
            if (mine < 0 || me.Ir < 100 || field.Count < 2) return "{\"on\":false,\"why\":\"not a rated field\"}";
            bool official = TrackMaps.YamlValue(yaml, "Official") == "1";
            int pos = (int)f.Num("PlayerCarClassPosition");
            string delta = "null";
            if (official && pos >= 1 && pos <= field.Count) delta = Change(field, mine, pos).ToString("0.0", Inv);
            return "{\"on\":true,\"official\":" + (official ? "true" : "false") + ",\"n\":" + field.Count + ",\"sof\":" + Math.Round(Sof(field)).ToString("0", Inv) + ",\"ir\":" + me.Ir +
                   ",\"pos\":" + (pos >= 1 ? pos.ToString() : "null") + ",\"delta\":" + delta + ",\"cls\":" + Json_.S(me.ClsName) + "}";
        }
    }

    // ---------------- Page requests: "show the sessions page" from a Stream Deck key ----------------
    // The dashboard page asks /nav every couple of seconds (never while you drive) and shows or hides the
    // sessions page over itself. Nothing is asked of Windows: no window opens or moves.
    static class Nav
    {
        static readonly object gate = new object();
        static string want = ""; static int seq; static DateTime since = DateTime.MinValue;

        public static bool Handles(string c) { return c == "sessions" || c == "sessionsclose"; }
        public static bool Do(string c, string a) { return Set(c == "sessions" ? "sessions" : ""); }

        public static bool Set(string to)
        {
            lock (gate)
            {
                if (to != "" && Program.IsDriving) return false;
                if (want != to) { want = to; since = DateTime.Now; seq++; Log.W("page request: " + (to == "" ? "back to the dashboard" : to)); }
                else since = DateTime.Now;
                return true;
            }
        }

        // from the 2 s guard timer: a request never outlives the start of driving, or half an hour
        public static void Tick(bool driving)
        {
            lock (gate)
                if (want != "" && (driving || (DateTime.Now - since).TotalMinutes > 30)) { want = ""; seq++; }
        }

        public static string Json() { lock (gate) return "{\"to\":" + Json_.S(want) + ",\"seq\":" + seq + ",\"driving\":" + (Program.IsDriving ? "true" : "false") + "}"; }
    }

    // ---------------- Sim priority (S2) ----------------
    // When a session starts, the sim program is raised to High priority (irdash.ini sim_priority=high, the default;
    // sim_priority=normal leaves it alone). Only the priority class changes, once per sim process.
    static class SimPriority
    {
        public static string Mode = "high";
        public static string ProcName = "iRacingSim64DX11";
        public static string Last = "";            // for Rig Doctor: what happened to the sim running now
        static int donePid = -1;

        public static void Tick(bool connected)
        {
            if (Mode != "high" || !connected) return;
            foreach (Process p in Process.GetProcessesByName(ProcName))
            {
                if (p.Id == donePid) return;
                donePid = p.Id;
                Last = ApplyTo(p.Id, "high", false);
                return;
            }
        }

        // returns what was done, in words (also logged)
        public static string ApplyTo(int pid, string mode, bool force)
        {
            try
            {
                using (Process p = Process.GetProcessById(pid))
                {
                    ProcessPriorityClass was = p.PriorityClass;
                    if (mode != "high") return "left at " + was + " (sim_priority=normal)";
                    if (was == ProcessPriorityClass.High || was == ProcessPriorityClass.RealTime)
                    { string s0 = "already " + was; Log.W("sim priority: " + p.ProcessName + " (" + pid + ") " + s0); return s0; }
                    p.PriorityClass = ProcessPriorityClass.High;
                    string s = "raised from " + was + " to High";
                    Log.W("sim priority: " + p.ProcessName + " (" + pid + ") " + s);
                    return s;
                }
            }
            catch (Exception ex)
            {
                string s = "could not raise the priority (" + ex.Message + ")";
                Log.W("sim priority: " + s);
                return s;
            }
        }

        // what Rig Doctor shows: the setting, and the priority of the sim if it is running
        public static string Describe(out bool problem)
        {
            problem = false;
            if (Mode != "high") return "Off (sim_priority=normal in irdash.ini): the sim keeps Windows' normal priority";
            Process[] ps = Process.GetProcessesByName(ProcName);
            if (ps.Length == 0) return "On: the sim is raised to High priority when a session starts";
            try
            {
                ProcessPriorityClass c = ps[0].PriorityClass;
                if (c == ProcessPriorityClass.High || c == ProcessPriorityClass.RealTime) return "On: the sim is running at High priority";
                if (!Sdk.Latest.Connected) return "On: the sim is running at " + c + " priority and will be raised when a session starts";
                problem = true;
                return "On, but the sim is running at " + c + " priority" + (Last.Length > 0 ? " (" + Last + ")" : "");
            }
            catch (Exception ex) { problem = true; return "On, but the sim's priority cannot be read (" + ex.Message + ")"; }
        }
    }
}
