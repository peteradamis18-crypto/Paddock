// D-01 DEBRIEF ENGINE (docs\cards\v4\D-01.md, the wireframe in docs\SPEC-v4.md 3a): one JSON for the session that just
// ended - his race result, his position lap by lap, his pace against the field and, for a practice with no race log, a
// pace story against his PB and optimal. No screen; the screen cards (D-03...) render this.
//   GET /debrief?id=<field id | telemetry file name | Vault lap id>
// A race: the log is found with the same rules as /analysis/race (RaceField.Route); the position by lap is taken
// straight from the summary RfSummary.Build already made (never recomputed). No log -> the lap analysis reference store
// (Analysis.Route). Only a Vault/session id is ever resolved; never an arbitrary path. 503 while Peter drives.
// C# 5 only; reads only; never writes iRacing's files.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class Debrief
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // D-05: the debrief that is on the top screen right now, kept here so the Stream Deck's DEBRIEF row and the
        // phone can act on it (SAVE / SHARE / OPEN IN COSWORTH / DEEP DIVE). Filled by every /debrief reply, good for
        // as long as the screen stays up (15 minutes); the dashboard's own reload keeps it fresh.
        static readonly object dbGate = new object();
        static string dbId = "", dbRec = "", dbShare = "", dbDdId = "", dbDdCorner = "";
        static bool dbSaved, dbOpen; static int dbDdLap, dbDdN; static DateTime dbAt = DateTime.MinValue;
        static bool ddGo; static int ddSeq; static DateTime ddAt = DateTime.MinValue;   // the DEEP DIVE the deck asked for

        static string Err(string m) { return "{\"error\":" + Json_.S(m) + "}"; }
        static string Q(Dictionary<string, string> q, string k) { string v; return q != null && q.TryGetValue(k, out v) && v != null ? v : ""; }
        static string N(double d, string f) { return RfData.N(d, f); }
        static string B(bool b) { return b ? "true" : "false"; }

        // ---- tiny helpers for the summary's plain objects (the same JavaScriptSerializer Json_ uses) ----
        static Dictionary<string, object> Obj(string json)
        {
            try
            {
                JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue;
                return js.DeserializeObject(json) as Dictionary<string, object>;
            }
            catch { return null; }
        }
        static object G(Dictionary<string, object> d, string k) { object o; return d != null && d.TryGetValue(k, out o) ? o : null; }
        static Dictionary<string, object> O(object o) { return o as Dictionary<string, object>; }
        static object[] A(object o) { return o as object[] ?? new object[0]; }
        static string S(object o) { return o == null ? "" : Convert.ToString(o, Inv); }
        static double D(object o) { double v; return o != null && double.TryParse(Convert.ToString(o, Inv), NumberStyles.Float, Inv, out v) ? v : double.NaN; }
        static int I(object o) { double v = D(o); return double.IsNaN(v) ? 0 : (int)Math.Round(v); }
        static bool Bl(object o) { if (o is bool) return (bool)o; string s = S(o); return s == "true" || s == "1"; }

        // a lap good for comparing pace: a full racing lap (RfSummary.Clean's own rule)
        static bool Clean(RfLap l, bool race)
        {
            if (l.In || l.Out || l.Off > 0 || double.IsNaN(l.Dur) || l.Dur < 15) return false;
            if (race && l.N < 2) return false;
            return true;
        }
        static double Median(List<double> v)
        {
            if (v.Count == 0) return double.NaN;
            List<double> s = new List<double>(v); s.Sort(); int n = s.Count;
            return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0;
        }
        static double LastE(RfCar c) { double e = double.NaN; int n = -1; foreach (RfLap l in c.Laps) if (!double.IsNaN(l.E) && l.N > n) { n = l.N; e = l.E; } return e; }
        static int MaxLap(RfCar c) { int n = 0; foreach (RfLap l in c.Laps) if (l.N > n) n = l.N; return n; }

        // ================================================================================================================
        public static string Route(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
            string id = Q(q, "id");
            if (id.Length == 0 || id.Length > 160) { code = 400; return Err("need id="); }
            string lapq = Q(q, "lap");

            // a race: the same id resolution as /analysis/race (a field id, a telemetry file or a Vault lap id)
            Dictionary<string, string> fq = new Dictionary<string, string>();
            fq["id"] = id;
            int rc; string raceJson = RaceField.Route("/analysis/race", fq, out rc);
            if (rc == 200 && raceJson != null && raceJson.StartsWith("{\"ok\":true", StringComparison.Ordinal))
                return RaceJson(raceJson, id, lapq, out code);
            if (rc == 400) { code = 400; return Err("need id="); }
            if (rc == 500 || rc == 503) { code = rc; return Err(rc == 503 ? "Not while driving" : "could not read the race log"); }

            // no field log for this session: a practice pace story from the lap analysis
            return PracticeJson(q, id, lapq, out code);
        }

        // ================================================================================================================
        // A race: result, position by lap and pace against the field, from the field log's own summary
        // ================================================================================================================
        static string RaceJson(string json, string id, string lapq, out int code)
        {
            code = 200;
            RfData d = RfData.FromJson(json);
            Dictionary<string, object> sm = O(G(Obj(json), "summary"));
            if (d == null || sm == null || d.Me < 0 || d.Car(d.Me) == null) { code = 500; return Err("could not read the race log"); }
            RfCar me = d.Car(d.Me);
            string focus = S(G(sm, "focus"));
            object[] tower = A(G(sm, "tower"));

            StringBuilder sb = new StringBuilder(8192);
            sb.Append("{\"ok\":true,\"v\":1,\"race\":").Append(B(d.IsRace)).Append(",\"id\":").Append(Json_.S(d.Id));
            sb.Append(",\"meta\":{\"track\":").Append(Json_.S(d.Track)).Append(",\"config\":").Append(Json_.S(d.Config)).Append(",\"trackName\":").Append(Json_.S(d.TrackName))
              .Append(",\"type\":").Append(Json_.S(d.SessType)).Append(",\"sessNum\":").Append(d.SessNum).Append(",\"sessName\":").Append(Json_.S(d.SessName))
              .Append(",\"official\":").Append(B(d.Official)).Append(",\"me\":").Append(d.Me).Append(",\"class\":").Append(Json_.S(focus))
              .Append(",\"startMs\":").Append(d.StartMs).Append(",\"endMs\":").Append(d.EndMs).Append('}');
            Result(sb, d, me, sm, tower, focus);
            Positions(sb, d, sm);
            Pace(sb, d, me, sm, tower, focus);
            sb.Append(TailSection(id, lapq, d.TrackName.Length > 0 ? d.TrackName : d.Track, d.StartMs));
            sb.Append('}');
            return sb.ToString();
        }

        static void Result(StringBuilder sb, RfData d, RfCar me, Dictionary<string, object> sm, object[] tower, string focus)
        {
            Dictionary<string, object> mt = null; int leadIdx = -1;
            foreach (object o in tower)
            {
                Dictionary<string, object> t = O(o); if (t == null) continue; int i = I(G(t, "i"));
                if (i == d.Me) mt = t; if (I(G(t, "pos")) == 1) leadIdx = i;
            }
            int finish = mt != null ? I(G(mt, "pos")) : 0;
            int classPos = mt != null ? I(G(mt, "cpos")) : 0;
            int totalLaps = mt != null ? I(G(mt, "laps")) : MaxLap(me);

            // the position he was in on his first lap (the closest thing the log has to a grid place); the summary's
            // position by lap is the fallback when the log has no first-lap position
            int startN = int.MaxValue; RfLap first = null;
            foreach (RfLap l in me.Laps) if (l.N < startN) { startN = l.N; first = l; }
            int startPos = first != null ? first.Pos : 0;
            if (startPos <= 0)
            {
                foreach (object o in A(G(sm, "trace")))
                {
                    Dictionary<string, object> t = O(o); if (t == null || I(G(t, "i")) != d.Me) continue;
                    object[] p = A(G(t, "p")); if (p.Length > 0) startPos = I(p[0]);
                }
            }

            int clean = 0; foreach (RfLap l in me.Laps) if (Clean(l, d.IsRace)) clean++;

            RfCar lead = leadIdx >= 0 ? d.Car(leadIdx) : null;
            int gapLaps = 0; double gapWinner = double.NaN;
            if (finish == 1) gapWinner = 0;
            else if (lead != null)
            {
                gapLaps = MaxLap(lead) - MaxLap(me);
                if (gapLaps <= 0 && !double.IsNaN(LastE(lead)) && !double.IsNaN(LastE(me))) gapWinner = LastE(me) - LastE(lead);
            }

            // iRating change: the community formula (data.cs Race.Change), only with a real field (two or more rated drivers) and an official race
            double irChange = double.NaN;
            List<double> ratings = new List<double>(); int meAt = -1;
            foreach (object o in tower)
            {
                Dictionary<string, object> t = O(o); if (t == null) continue; int i = I(G(t, "i")); RfCar c = d.Car(i);
                if (c == null || c.Cls != focus || c.IR < 100) continue;
                if (i == d.Me) meAt = ratings.Count; ratings.Add(c.IR);
            }
            if (d.Official && ratings.Count >= 2 && meAt >= 0 && classPos >= 1) irChange = Race.Change(ratings, meAt, classPos);

            sb.Append(",\"result\":{\"finishPosition\":").Append(finish).Append(",\"classPosition\":").Append(classPos)
              .Append(",\"startPosition\":").Append(startPos).Append(",\"positionsGained\":").Append(startPos - finish)
              .Append(",\"iratingChange\":").Append(double.IsNaN(irChange) ? "null" : ((int)Math.Round(irChange)).ToString(Inv))
              .Append(",\"gapToWinner\":").Append(double.IsNaN(gapWinner) ? "null" : N(gapWinner, "0.000")).Append(",\"gapLaps\":").Append(gapLaps)
              .Append(",\"incidents\":").Append(me.ResInc).Append(",\"cleanLaps\":").Append(clean).Append(",\"totalLaps\":").Append(totalLaps).Append('}');
        }

        static void Positions(StringBuilder sb, RfData d, Dictionary<string, object> sm)
        {
            Dictionary<string, object> mtr = null;
            foreach (object o in A(G(sm, "trace"))) { Dictionary<string, object> t = O(o); if (t != null && I(G(t, "i")) == d.Me) mtr = t; }
            object[] g = mtr != null ? A(G(mtr, "g")) : new object[0];
            object[] p = mtr != null ? A(G(mtr, "p")) : new object[0];
            object[] passes = A(G(sm, "passes"));
            int maxLap = I(G(sm, "maxLap"));
            RfCar me = d.Car(d.Me);
            sb.Append(",\"positionByLap\":[");
            for (int n = 1; n <= maxLap; n++)
            {
                if (n > 1) sb.Append(',');
                object pv = n - 1 < p.Length ? p[n - 1] : null;
                object gv = n - 1 < g.Length ? g[n - 1] : null;
                bool pit = false; foreach (RfPit pt in me.Pits) if (pt.InLap == n) pit = true;
                int pass = 0;
                foreach (object o in passes)
                {
                    Dictionary<string, object> ps = O(o); if (ps == null) continue;
                    if (I(G(ps, "lap")) == n && (I(G(ps, "by")) == d.Me || I(G(ps, "over")) == d.Me)) pass++;
                }
                sb.Append("{\"lap\":").Append(n).Append(",\"position\":").Append(pv == null ? "null" : I(pv).ToString(Inv))
                  .Append(",\"gapToLeader\":").Append(gv == null ? "null" : N(D(gv), "0.000"))
                  .Append(",\"pitStop\":").Append(B(pit)).Append(",\"pass\":").Append(pass).Append('}');
            }
            sb.Append(']');
        }

        static void Pace(StringBuilder sb, RfData d, RfCar me, Dictionary<string, object> sm, object[] tower, string focus)
        {
            double hisMedian = double.NaN, hisBest = double.NaN, classBest = double.NaN;
            List<double> carMed = new List<double>(); List<double> allClean = new List<double>();

            // the per-car median lap the summary already worked out (cm), his class only
            foreach (object o in A(G(sm, "cm")))
            {
                Dictionary<string, object> c = O(o); if (c == null) continue; int i = I(G(c, "i")); RfCar cc = d.Car(i);
                if (cc == null || cc.Cls != focus) continue;
                double lap = D(G(c, "lap")); if (!double.IsNaN(lap)) carMed.Add(lap);
                if (i == d.Me) hisMedian = lap;
            }
            if (double.IsNaN(hisMedian)) { List<double> mine = new List<double>(); foreach (RfLap l in me.Laps) if (Clean(l, d.IsRace)) mine.Add(l.Dur); hisMedian = Median(mine); }

            // every clean lap of the class: the raw pool behind the median and the top 5 %
            foreach (RfCar cc in d.Cars) if (cc.Cls == focus) foreach (RfLap l in cc.Laps) if (Clean(l, d.IsRace)) allClean.Add(l.Dur);
            allClean.Sort();

            // best laps from the timing tower (iRacing's own figure where the log has it)
            foreach (object o in tower)
            {
                Dictionary<string, object> t = O(o); if (t == null) continue; int i = I(G(t, "i")); RfCar cc = d.Car(i);
                if (cc == null || cc.Cls != focus) continue;
                double b = D(G(t, "best"));
                if (!double.IsNaN(b) && (double.IsNaN(classBest) || b < classBest)) classBest = b;
                if (i == d.Me) hisBest = b;
            }

            double top5 = double.NaN;
            if (allClean.Count > 0) { int idx = (int)Math.Floor(0.05 * (allClean.Count - 1)); if (idx < 0) idx = 0; top5 = allClean[idx]; }
            double classMedian = Median(carMed);

            sb.Append(",\"pace\":{\"hisBest\":").Append(double.IsNaN(hisBest) ? "null" : N(hisBest, "0.000"))
              .Append(",\"hisMedian\":").Append(double.IsNaN(hisMedian) ? "null" : N(hisMedian, "0.000"))
              .Append(",\"classBest\":").Append(double.IsNaN(classBest) ? "null" : N(classBest, "0.000"))
              .Append(",\"classMedian\":").Append(double.IsNaN(classMedian) ? "null" : N(classMedian, "0.000"))
              .Append(",\"n\":").Append(carMed.Count)
              .Append(",\"top5\":").Append(double.IsNaN(top5) ? "null" : N(top5, "0.000")).Append('}');
        }

        // ================================================================================================================
        // No race log: a practice pace story against the analysis reference store (pb and optimal)
        // ================================================================================================================
        static string PracticeJson(Dictionary<string, string> q, string id, string lapq, out int code)
        {
            code = 200;
            int sc; string sj = Analysis.SessionRoute(q, out sc);
            if (sc != 200) { code = sc <= 0 ? 404 : sc; return sj; }
            Dictionary<string, object> s = Obj(sj);
            if (s == null) { code = 500; return Err("could not read the lap file"); }

            Dictionary<string, object> best = O(G(s, "best"));
            int bestLap = best != null ? I(G(best, "lap")) : 0;
            double bestTime = best != null ? D(G(best, "time")) : double.NaN;

            // the reference store (all-time PB, optimal, this session's best): one more read of the same cached session
            double pb = double.NaN, optimal = double.NaN, sessBest = double.NaN;
            int lapNo = bestLap;
            if (lapNo <= 0) { object[] rows = A(G(s, "laps")); if (rows.Length > 0) lapNo = I(G(O(rows[0]), "n")); }
            if (lapNo > 0)
            {
                Dictionary<string, string> lq = new Dictionary<string, string>();
                lq["id"] = id; lq["lap"] = lapNo.ToString(Inv); lq["ref"] = "pb";
                int lc; string lj = Analysis.Route("/analysis/lap", lq, out lc);
                Dictionary<string, object> store = O(G(Obj(lj), "store"));
                if (store != null)
                {
                    Dictionary<string, object> pbo = O(G(store, "pb")); pb = pbo != null ? D(G(pbo, "time")) : double.NaN;
                    Dictionary<string, object> sbo = O(G(store, "sessionBest")); sessBest = sbo != null ? D(G(sbo, "time")) : double.NaN;
                    optimal = D(G(store, "optimal"));
                }
            }

            // the median of the laps iRacing counted in this session
            List<double> valid = new List<double>();
            foreach (object o in A(G(s, "laps"))) { Dictionary<string, object> l = O(o); if (l != null && Bl(G(l, "valid"))) { double t = D(G(l, "time")); if (!double.IsNaN(t)) valid.Add(t); } }
            double med = Median(valid);
            double showBest = double.IsNaN(sessBest) ? bestTime : sessBest;

            StringBuilder sb = new StringBuilder(2048);
            sb.Append("{\"ok\":true,\"v\":1,\"race\":false,\"id\":").Append(Json_.S(id));
            sb.Append(",\"meta\":{\"file\":").Append(Json_.S(S(G(s, "file")))).Append(",\"track\":").Append(Json_.S(S(G(s, "track")))).Append(",\"config\":").Append(Json_.S(S(G(s, "config"))))
              .Append(",\"type\":").Append(Json_.S(S(G(s, "type")))).Append(",\"driver\":").Append(Json_.S(S(G(s, "driver")))).Append('}');
            sb.Append(",\"practice\":{\"best\":").Append(double.IsNaN(showBest) ? "null" : N(showBest, "0.000"))
              .Append(",\"pb\":").Append(double.IsNaN(pb) ? "null" : N(pb, "0.000"))
              .Append(",\"optimal\":").Append(double.IsNaN(optimal) ? "null" : N(optimal, "0.000"))
              .Append(",\"median\":").Append(double.IsNaN(med) ? "null" : N(med, "0.000"))
              .Append(",\"n\":").Append(valid.Count).Append(",\"lap\":").Append(bestLap).Append('}');
            sb.Append(TailSection(id, lapq, S(G(s, "track")), 0));
            sb.Append('}');
            return sb.ToString();
        }

        // ================================================================================================================
        // D-02 Corner video pairs (docs\cards\v4\D-02.md): the three corners that cost the most time against his best lap,
        // each with a looping pair cut from the recorder's own clips. This lap's clip and the reference lap's clip are
        // resolved through Recorder.ClipFor (only real clips; nothing is fabricated). The corner's start/end LapDistPct is
        // turned into seconds into the lap from the telemetry (Analysis.LapAxis) and then into a time in the clip:
        // clipTime = lapStartOffset + elapsedSec. Both clips are cut from corner start - 2 s and share one duration so a
        // side-by-side player starts them at the same marker. The reference lap having no video gives referenceVideo: null.
        // Cuts run one at a time on a BelowNormal background thread with ffmpeg -c copy (no re-encode); never while driving.
        // ================================================================================================================
        sealed class CvJob
        {
            public string Id = "", Src = "", Out = "";
            public double Start, Dur;
            public string State = "queued";
        }

        static readonly object cvGate = new object();
        static readonly List<CvJob> cvJobs = new List<CvJob>();
        static Thread cvWorker;
        static string cvPriority = "";
        // Lets the guarded test place a session start in the worker's launch window.
        internal static Action CvBeforeLaunch;

        static void CvEnsure()
        {
            lock (cvGate)
            {
                if (cvWorker != null) return;
                cvWorker = new Thread(CvLoop);
                cvWorker.IsBackground = true; cvWorker.Priority = ThreadPriority.BelowNormal; cvWorker.Name = "debrief-video"; cvWorker.Start();
            }
        }

        static void CvLoop()
        {
            while (true)
            {
                CvJob j = null;
                lock (cvGate) { foreach (CvJob o in cvJobs) if (o.State == "queued") { j = o; break; } }
                if (j == null) { Thread.Sleep(250); continue; }
                if (Program.IsDriving) { Thread.Sleep(1000); continue; }        // he is driving: not a single cut now
                CvRun(j);
            }
        }

        static void CvRun(CvJob j)
        {
            try
            {
                Action beforeLaunch = CvBeforeLaunch;
                if (beforeLaunch != null) beforeLaunch();
                if (Program.IsDriving) return; // leave it queued for the next safe window
                lock (cvGate) { if (j.State != "queued") return; j.State = "making"; }
                string tmp = j.Out + ".tmp";
                string args = "-hide_banner -y -loglevel error -ss " + j.Start.ToString("0.000", Inv) + " -t " + j.Dur.ToString("0.000", Inv) +
                              " -i \"" + j.Src + "\" -c copy -movflags +faststart -f mp4 \"" + tmp + "\"";
                string so, se;
                int rc = CvTool(Recorder.FfmpegExe, args, 120000, out so, out se);
                if (rc == -2) { lock (cvGate) { j.State = "queued"; } return; }
                if (rc != 0 || !File.Exists(tmp) || new FileInfo(tmp).Length < 1000)
                { try { File.Delete(tmp); } catch { } lock (cvGate) { j.State = "error"; } Log.W("debrief: could not cut " + j.Id + " (" + (se ?? "").Trim() + ")"); return; }
                if (File.Exists(j.Out)) File.Delete(j.Out);
                File.Move(tmp, j.Out);
                lock (cvGate) { j.State = "ready"; }
                Log.W("debrief: corner clip " + j.Id + " cut (" + j.Dur.ToString("0.0", Inv) + " s, -c copy)");
            }
            catch (Exception ex) { lock (cvGate) { j.State = "error"; } Log.W("debrief: corner clip " + j.Id + ": " + ex.Message); }
        }

        // ffmpeg at BelowNormal, like every other tool irdash runs. The actual priority is kept for the test to read.
        static int CvTool(string exe, string args, int timeoutMs, out string stdout, out string stderr)
        {
            stdout = ""; stderr = "";
            ProcessStartInfo psi = new ProcessStartInfo(exe, args);
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            if (Program.IsDriving) return -2;
            using (Process p = Process.Start(psi))
            {
                try { p.PriorityClass = ProcessPriorityClass.BelowNormal; lock (cvGate) cvPriority = p.PriorityClass.ToString(); } catch { }
                StringBuilder se = new StringBuilder();
                p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) lock (se) se.AppendLine(e.Data); };
                p.BeginErrorReadLine();
                if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } stderr = "timed out"; return -1; }
                p.WaitForExit();
                lock (se) stderr = se.ToString();
                return p.ExitCode;
            }
        }

        static string CvSlug(string id)
        {
            StringBuilder b = new StringBuilder();
            foreach (char c in (id ?? ""))
            {
                if (b.Length >= 30) break;
                if (char.IsLetterOrDigit(c)) b.Append(c);
                else if (c == ' ' || c == '-' || c == '_') b.Append('-');
            }
            string s = b.ToString().Trim('-');
            return s.Length == 0 ? "session" : s;
        }

        static double PctTime(double[] tm, int metres, double pct)
        {
            if (tm == null || metres <= 0 || tm.Length == 0) return double.NaN;
            if (pct < 0) pct = 0; if (pct > 1) pct = 1;
            int i = (int)Math.Round(pct * metres);
            if (i < 0) i = 0; if (i >= tm.Length) i = tm.Length - 1;
            return tm[i];
        }

        // corner start/end seconds into the lap -> a bounded cut of the source clip (start - 2 s, end + 1 s)
        static bool PlanClip(RecClip c, double cs, double ce, out double cutStart, out double dur, out double offset)
        {
            cutStart = 0; dur = 0; offset = 0;
            if (c == null || double.IsNaN(cs) || double.IsNaN(ce)) return false;
            double a = c.LapStartOffset + cs, b = c.LapStartOffset + ce;
            if (b < a) b = a;
            double s = a - 2.0, e = b + 1.0;
            double lo = c.VideoStart, hi = c.VideoStart + (c.Duration > 0 ? c.Duration : 1e9);
            if (s < lo) s = lo;
            if (e > hi) e = hi;
            if (e - s < 0.5) return false;
            cutStart = s; dur = e - s; offset = a - s;
            return true;
        }

        static void QueueCut(string oid, RecClip src, double cutStart, double dur, string outPath)
        {
            lock (cvGate)
            {
                if (File.Exists(outPath) && new FileInfo(outPath).Length > 1000) return;
                foreach (CvJob o in cvJobs) if (o.Id == oid) return;
                CvJob j = new CvJob();
                j.Id = oid; j.Src = src.File; j.Out = outPath; j.Start = cutStart; j.Dur = dur;
                cvJobs.Add(j);
            }
            CvEnsure();
        }

        // D-04: the same bounded -c copy cut, but from a plain source file (the recorder's session mp4 around an incident)
        static void QueueCutFile(string oid, string srcFile, double cutStart, double dur, string outPath)
        {
            lock (cvGate)
            {
                if (File.Exists(outPath) && new FileInfo(outPath).Length > 1000) return;
                foreach (CvJob o in cvJobs) if (o.Id == oid) return;
                CvJob j = new CvJob();
                j.Id = oid; j.Src = srcFile; j.Out = outPath; j.Start = cutStart; j.Dur = dur;
                cvJobs.Add(j);
            }
            CvEnsure();
        }

        static string CvState(string outPath)
        {
            if (File.Exists(outPath) && new FileInfo(outPath).Length > 1000) return "ready";
            lock (cvGate)
            {
                foreach (CvJob o in cvJobs)
                    if (string.Equals(o.Out, outPath, StringComparison.OrdinalIgnoreCase)) return o.State == "ready" ? "ready" : o.State;
            }
            return "none";
        }

        // ---- D-04: the one-press bar and the incident clips (docs\cards\v4\D-04.md) ----
        // The recorder's own S1 sidecar (vault\sessions|saved\<id>.json) names the incidents (offset seconds into the session file,
        // points) and the session's laps (offset + time). Each incident is turned into a lap and a corner from that lap's own time
        // axis, and a ~30 s clip is cut around it from the session mp4 with D-02's bounded -c copy method; /debrief/video serves it.
        // The bar names the recorder session to SAVE, the analysed lap's clip to SHARE, the telemetry file to open in Cosworth and
        // the worst corner for DEEP DIVE. Nothing is guessed: no sidecar, no incidents.
        sealed class Cx
        {
            public string File = "", RefFile = "", WorstLabel = "";
            public int Lap, RefLap, WorstN;
            public double[] Tm; public int Metres;
            public List<Dictionary<string, object>> Corners = new List<Dictionary<string, object>>();
            public List<Dictionary<string, object>> Top = new List<Dictionary<string, object>>();
            public RecClip Clip;
        }

        // the analysed lap and its corners (the same lookup the corners section always did), worked out once
        static Cx Analyse(string id, string lapStr)
        {
            Cx cx = new Cx();
            try
            {
                Dictionary<string, string> sq = new Dictionary<string, string>(); sq["id"] = id;
                int sc; string sj = Analysis.SessionRoute(sq, out sc);
                if (sc != 200) return cx;
                Dictionary<string, object> s = Obj(sj); if (s == null) return cx;
                Dictionary<string, object> best = O(G(s, "best"));
                int lap = 0; int.TryParse(lapStr, NumberStyles.Integer, Inv, out lap);
                if (lap <= 0 && best != null) lap = I(G(best, "lap"));
                if (lap <= 0) { object[] rows = A(G(s, "laps")); if (rows.Length > 0) lap = I(G(O(rows[0]), "n")); }
                if (lap <= 0) return cx;

                Dictionary<string, string> lq = new Dictionary<string, string>();
                lq["id"] = id; lq["lap"] = lap.ToString(Inv); lq["ref"] = "pb";
                int lc; string lj = Analysis.Route("/analysis/lap", lq, out lc);
                if (lc != 200) return cx;
                Dictionary<string, object> l = Obj(lj); if (l == null) return cx;
                cx.Lap = I(G(l, "lap")); cx.File = S(G(l, "file"));
                if (cx.Lap <= 0) cx.Lap = lap;
                Dictionary<string, object> rfo = O(G(l, "ref"));
                cx.RefLap = rfo != null ? I(G(rfo, "lap")) : 0;
                cx.RefFile = rfo != null ? S(G(rfo, "file")) : "";

                double meLen, meTime; double[] meTm = null; int meM = 0;
                bool meAxis = Analysis.LapAxis(cx.File, cx.Lap, out meLen, out meTm, out meM, out meTime);
                cx.Tm = meTm; cx.Metres = meM;
                if (meAxis) cx.Clip = Recorder.ClipForShare(cx.File + ":" + cx.Lap.ToString(Inv));

                foreach (object o in A(G(l, "corners"))) { Dictionary<string, object> c = O(o); if (c != null) cx.Corners.Add(c); }
                List<Dictionary<string, object>> pos = new List<Dictionary<string, object>>();
                foreach (Dictionary<string, object> c in cx.Corners) { double loss = D(G(c, "dTime")); if (!double.IsNaN(loss) && loss > 0.0005) pos.Add(c); }
                for (int i = 0; i < 3 && pos.Count > 0; i++)
                {
                    int bi = 0; double bv = D(G(pos[0], "dTime"));
                    for (int k = 1; k < pos.Count; k++) { double v = D(G(pos[k], "dTime")); if (v > bv) { bv = v; bi = k; } }
                    cx.Top.Add(pos[bi]); pos.RemoveAt(bi);
                }
                if (cx.Top.Count > 0) { cx.WorstLabel = S(G(cx.Top[0], "label")); cx.WorstN = I(G(cx.Top[0], "n")); }
            }
            catch (Exception ex) { Log.W("debrief: analyse: " + ex.Message); }
            return cx;
        }

        static string TailSection(string id, string lapStr, string track, double startMs)
        {
            Cx cx = Analyse(id, lapStr);
            return CornersSection(cx, id) + IncidentsSection(cx, track, startMs) + BarSection(cx, id, track, startMs);
        }

        static string CornersSection(Cx cx, string id)
        {
            try
            {
                if (cx.Corners.Count == 0) return ",\"corners\":[]";
                double refLen, refTime; double[] refTm = null; int refM = 0;
                bool refAxis = cx.RefLap > 0 && cx.RefFile.Length > 0 && Analysis.LapAxis(cx.RefFile, cx.RefLap, out refLen, out refTm, out refM, out refTime);
                RecClip meClip = cx.Clip;
                RecClip refClip = refAxis ? Recorder.ClipForShare(cx.RefFile + ":" + cx.RefLap.ToString(Inv)) : null;

                string slug = CvSlug(id);
                StringBuilder arr = new StringBuilder();
                bool first = true;
                foreach (Dictionary<string, object> c in cx.Top)
                {
                    if (!first) arr.Append(','); first = false;
                    int n = I(G(c, "n")); string label = S(G(c, "label"));
                    double p0 = D(G(c, "p0")), p1 = D(G(c, "p1")), loss = D(G(c, "dTime"));
                    if (p1 <= p0) p1 = 1.0;
                    string baseId = "debrief-" + slug + "-" + cx.Lap.ToString(Inv) + "-" + n.ToString(Inv);
                    string vidOut = Path.Combine(Recorder.ClipFolder, baseId + ".mp4");
                    string ridOut = Path.Combine(Recorder.ClipFolder, baseId + "-ref.mp4");

                    double meS = cx.Metres > 0 ? PctTime(cx.Tm, cx.Metres, p0) : double.NaN;
                    double meE = cx.Metres > 0 ? PctTime(cx.Tm, cx.Metres, p1) : double.NaN;
                    double refS = refAxis ? PctTime(refTm, refM, p0) : double.NaN;
                    double refE = refAxis ? PctTime(refTm, refM, p1) : double.NaN;

                    double mcS, mcD, mcO, rcS, rcD, rcO;
                    bool haveMe = PlanClip(meClip, meS, meE, out mcS, out mcD, out mcO);
                    bool haveRef = PlanClip(refClip, refS, refE, out rcS, out rcD, out rcO);
                    if (haveMe && haveRef) { double d2 = Math.Min(mcD, rcD); mcD = d2; rcD = d2; }
                    if (haveMe) QueueCut(baseId, meClip, mcS, mcD, vidOut);
                    if (haveRef) QueueCut(baseId + "-ref", refClip, rcS, rcD, ridOut);

                    arr.Append("{\"n\":").Append(n).Append(",\"label\":").Append(Json_.S(label));
                    arr.Append(",\"p0\":").Append(N(p0, "0.0000")).Append(",\"p1\":").Append(N(p1, "0.0000")).Append(",\"loss\":").Append(N(loss, "0.000"));
                    arr.Append(",\"lap\":").Append(cx.Lap).Append(",\"refLap\":").Append(cx.RefLap > 0 ? cx.RefLap.ToString(Inv) : "null");
                    arr.Append(",\"videoId\":").Append(haveMe ? Json_.S(baseId) : "null").Append(",\"video\":").Append(haveMe ? Json_.S("clips\\" + baseId + ".mp4") : "null");
                    arr.Append(",\"referenceId\":").Append(haveRef ? Json_.S(baseId + "-ref") : "null").Append(",\"referenceVideo\":").Append(haveRef ? Json_.S("clips\\" + baseId + "-ref.mp4") : "null");
                    arr.Append(",\"startOffset\":").Append(N(haveMe ? mcO : 0.0, "0.000"));
                    arr.Append(",\"referenceStartOffset\":").Append(N(haveRef ? rcO : 0.0, "0.000"));
                    arr.Append(",\"duration\":").Append(N(haveMe ? mcD : 0.0, "0.000"));
                    arr.Append(",\"status\":").Append(Json_.S(CvState(vidOut))).Append('}');
                }
                return ",\"corners\":[" + arr.ToString() + "]";
            }
            catch (Exception ex) { Log.W("debrief: corners: " + ex.Message); return ",\"corners\":[]"; }
        }

        // The recorder session that ran this debrief session: the same track and, when the debrief knows it, the nearest start time.
        static Dictionary<string, object> FindSession(string track, double startMs)
        {
            try
            {
                string root = Vault.Root ?? Path.Combine(Program.RootDir, "vault");
                Dictionary<string, object> best = null; double bestD = double.MaxValue;
                foreach (string dir in new string[] { Path.Combine(root, "sessions"), Path.Combine(root, "saved") })
                {
                    if (!Directory.Exists(dir)) continue;
                    foreach (string f in Directory.GetFiles(dir, "*.json"))
                    {
                        try
                        {
                            Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                            if (d == null) continue;
                            if (track.Length > 0 && !SameTrack(S(G(d, "track")), track)) continue;
                            double sm = D(G(d, "startMs"));
                            double dist = startMs > 0 ? Math.Abs(sm - startMs) : -sm;     // with no start hint the newest session wins
                            if (best == null || dist < bestD) { best = d; bestD = dist; }
                        }
                        catch { }
                    }
                }
                if (best != null && startMs > 0 && bestD > 6L * 3600 * 1000) return null;   // a start hint means a session within 6 hours
                return best;
            }
            catch (Exception ex) { Log.W("debrief: sessions: " + ex.Message); return null; }
        }

        static string OnlyAlnum(string s) { StringBuilder b = new StringBuilder(); foreach (char c in (s ?? "")) if (char.IsLetterOrDigit(c)) b.Append(char.ToLowerInvariant(c)); return b.ToString(); }
        static bool SameTrack(string a, string b)
        {
            if (string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b)) return false;
            if (string.Equals(a, b, StringComparison.OrdinalIgnoreCase)) return true;
            string x = OnlyAlnum(a), y = OnlyAlnum(b);
            return x.Length > 0 && (x == y || x.Contains(y) || y.Contains(x));
        }

        static string CornerAt(List<Dictionary<string, object>> corners, double[] tm, int metres, double t)
        {
            if (tm == null || metres <= 0) return "";
            foreach (Dictionary<string, object> c in corners)
            {
                double p0 = D(G(c, "p0")), p1 = D(G(c, "p1"));
                if (double.IsNaN(p0) || double.IsNaN(p1)) continue;
                double s = PctTime(tm, metres, p0), e = PctTime(tm, metres, p1);
                if (e < s) e = s;
                if (t >= s - 0.2 && t <= e + 0.2) return S(G(c, "label"));
            }
            return "";
        }

        static string IncidentsSection(Cx cx, string track, double startMs)
        {
            try
            {
                Dictionary<string, object> sess = FindSession(track, startMs);
                if (sess == null) return ",\"incidents\":[]";
                string recId = S(G(sess, "id"));
                double duration = D(G(sess, "durationSec"));
                string mp4 = null;
                if (recId.Length > 0)
                {
                    string root = Vault.Root ?? Path.Combine(Program.RootDir, "vault");
                    string a = Path.Combine(Path.Combine(root, "sessions"), recId + ".mp4");
                    string b = Path.Combine(Path.Combine(root, "saved"), recId + ".mp4");
                    if (File.Exists(a)) mp4 = a; else if (File.Exists(b)) mp4 = b;
                }
                List<Dictionary<string, object>> laps = new List<Dictionary<string, object>>();
                foreach (object o in A(G(sess, "laps"))) { Dictionary<string, object> p = O(o); if (p != null) laps.Add(p); }
                object[] incs = A(G(sess, "incidents"));
                StringBuilder arr = new StringBuilder();
                bool first = true;
                for (int i = 0; i < incs.Length; i++)
                {
                    Dictionary<string, object> inc = O(incs[i]); if (inc == null) continue;
                    double off = D(G(inc, "offset")); int count = I(G(inc, "count"));
                    if (double.IsNaN(off)) continue;
                    int lapN = 0; double lapOff = 0;
                    foreach (Dictionary<string, object> p in laps)
                    {
                        double o0 = D(G(p, "offset")), t = D(G(p, "time"));
                        if (double.IsNaN(o0)) continue;
                        if (t > 0 && off >= o0 && off <= o0 + t && o0 >= lapOff) { lapN = I(G(p, "n")); lapOff = o0; }
                    }
                    double timeSec = lapN > 0 ? off - lapOff : off;
                    string corner = "";
                    if (lapN > 0 && cx.File.Length > 0)
                    {
                        double len, lt; double[] tm = null; int mm = 0;
                        if (Analysis.LapAxis(cx.File, lapN, out len, out tm, out mm, out lt)) corner = CornerAt(cx.Corners, tm, mm, timeSec);
                    }
                    string vid = null, status = "none";
                    if (mp4 != null && duration > 0)
                    {
                        double s = off - 20.0, e = off + 10.0;
                        if (s < 0) s = 0; if (e > duration) e = duration;
                        if (e - s > 0.5)
                        {
                            vid = "debrief-inc-" + CvSlug(recId) + "-" + i.ToString(Inv);
                            string outPath = Path.Combine(Recorder.ClipFolder, vid + ".mp4");
                            QueueCutFile(vid, mp4, s, e - s, outPath);
                            status = CvState(outPath);
                        }
                    }
                    if (!first) arr.Append(','); first = false;
                    arr.Append("{\"lap\":").Append(lapN);
                    arr.Append(",\"corner\":").Append(Json_.S(corner));
                    arr.Append(",\"type\":").Append(Json_.S(count > 0 ? count + "x" : ""));
                    arr.Append(",\"timeSec\":").Append(lapN > 0 ? N(timeSec, "0.000") : "null");
                    arr.Append(",\"videoId\":").Append(vid != null ? Json_.S(vid) : "null");
                    arr.Append(",\"status\":").Append(Json_.S(status)).Append('}');
                }
                return ",\"incidents\":[" + arr.ToString() + "]";
            }
            catch (Exception ex) { Log.W("debrief: incidents: " + ex.Message); return ",\"incidents\":[]"; }
        }

        static string BarSection(Cx cx, string id, string track, double startMs)
        {
            Dictionary<string, object> sess = FindSession(track, startMs);
            string recId = sess != null ? S(G(sess, "id")) : "";
            bool saved = sess != null && Bl(G(sess, "saved"));
            string shareId = cx.Clip != null && cx.Clip.Id.Length > 0 ? cx.Clip.Id : "";
            string ddId = cx.File.Length > 0 ? cx.File : "";
            // D-05: remember this debrief so the deck/phone keys can act on it (SAVE, SHARE, COSWORTH, DEEP DIVE)
            lock (dbGate)
            {
                dbId = id ?? ""; dbRec = recId; dbSaved = saved; dbShare = shareId;
                dbDdId = ddId; dbDdLap = cx.Lap; dbDdCorner = cx.WorstLabel; dbDdN = cx.WorstN;
                dbAt = DateTime.UtcNow; dbOpen = false;
            }
            return ",\"bar\":{\"recId\":" + (recId.Length > 0 ? Json_.S(recId) : "null")
              + ",\"saved\":" + B(saved)
              + ",\"shareId\":" + (shareId.Length > 0 ? Json_.S(shareId) : "null")
              + ",\"deepDive\":{\"id\":" + (ddId.Length > 0 ? Json_.S(ddId) : "null") + ",\"lap\":" + cx.Lap + ",\"corner\":" + Json_.S(cx.WorstLabel) + ",\"cornerN\":" + cx.WorstN + "}"
              + "},\"videoPriority\":" + Json_.S(cvPriority);
        }

        // ================================================================================================================
        // D-05 (docs\cards\v4\D-05.md): the four debrief keys. The current debrief (the one on the top screen) is what
        // every one of them acts on; a key that does not name it is refused and does nothing. Never while he drives.
        //   db-save      keeps the recorder session (recorder.cs Recorder.Save)
        //   db-share     queues the analysed lap's clip on the share studio (/share/make)
        //   db-cosworth  opens the telemetry file in Pi Toolbox, only when it is really installed (/vault/open)
        //   db-deepdive  asks the top screen to open the Workbench on the corner that cost the most (/debrief/nav)
        // ================================================================================================================
        static readonly HashSet<string> Commands = new HashSet<string> { "db-save", "db-share", "db-cosworth", "db-deepdive" };
        public static bool Handles(string c) { return Commands.Contains(c ?? ""); }

        public static bool Do(string c, string a)
        {
            if (!Handles(c) || Program.IsDriving) return false;
            a = (a ?? "").Trim();
            if (a.Length == 0 || a.Length > 160) return false;
            string id, rec, share, ddId; int ddLap, ddN;
            lock (dbGate)
            {
                if (!dbOpen || dbAt == DateTime.MinValue || (DateTime.UtcNow - dbAt).TotalSeconds > 15) return false;
                if (!string.Equals(a, dbId, StringComparison.Ordinal)) return false;
                id = dbId; rec = dbRec; share = dbShare; ddId = dbDdId; ddLap = dbDdLap; ddN = dbDdN;
            }
            switch (c)
            {
                case "db-save":
                    if (rec.Length == 0) return false;
                    {
                        string st = Recorder.Save(rec);
                        Log.W("debrief: SAVE " + rec + " -> " + st);
                        return st == "SAVED" || st == "SAVING";
                    }
                case "db-share":
                    if (share.Length == 0) return false;
                    return LocalGet("/share/make?id=" + Uri.EscapeDataString(share) + "&ref=&stripe=0");
                case "db-cosworth":
                    if (ddId.Length == 0 || !CosworthInstalled()) return false;
                    return LocalGet("/vault/open?how=cosworth&id=" + Uri.EscapeDataString(ddId));
                case "db-deepdive":
                    if (ddId.Length == 0 || ddN <= 0) return false;
                    lock (dbGate) { ddGo = true; ddSeq++; ddAt = DateTime.UtcNow; }
                    Log.W("debrief: deep dive -> " + ddId + " lap " + ddLap + " corner " + dbDdCorner);
                    return true;
            }
            return false;
        }

        // what the deck's DEBRIEF row reads: is a debrief showing, and what can each key act on
        public static string StateJson()
        {
            lock (dbGate)
            {
                bool driving = Program.IsDriving;
                bool open = !driving && dbOpen && dbAt != DateTime.MinValue && (DateTime.UtcNow - dbAt).TotalSeconds < 15;
                int age = dbAt == DateTime.MinValue ? 9999 : (int)Math.Min(9999, (DateTime.UtcNow - dbAt).TotalSeconds);
                StringBuilder sb = new StringBuilder(512);
                sb.Append("{\"open\":").Append(open ? "true" : "false").Append(",\"driving\":").Append(driving ? "true" : "false").Append(",\"age\":").Append(age);
                if (open)
                {
                    sb.Append(",\"id\":").Append(Json_.S(dbId))
                      .Append(",\"recId\":").Append(dbRec.Length > 0 ? Json_.S(dbRec) : "null")
                      .Append(",\"saved\":").Append(dbSaved ? "true" : "false")
                      .Append(",\"shareId\":").Append(dbShare.Length > 0 ? Json_.S(dbShare) : "null")
                      .Append(",\"deepDive\":{\"id\":").Append(dbDdId.Length > 0 ? Json_.S(dbDdId) : "null").Append(",\"lap\":").Append(dbDdLap)
                      .Append(",\"corner\":").Append(Json_.S(dbDdCorner)).Append(",\"cornerN\":").Append(dbDdN).Append('}');
                }
                return sb.Append('}').ToString();
            }
        }

        // The visible dashboard owns this lease; deck reads must not keep a closed debrief alive.
        public static string ActiveJson(Dictionary<string, string> q)
        {
            string id = Q(q, "id"), open = Q(q, "open");
            lock (dbGate)
            {
                if (id.Length == 0 || !string.Equals(id, dbId, StringComparison.Ordinal)) return "{\"ok\":false}";
                dbOpen = open == "1" && !Program.IsDriving;
                dbAt = dbOpen ? DateTime.UtcNow : DateTime.MinValue;
                return "{\"ok\":true}";
            }
        }

        // the DEEP DIVE the deck asked for; the dashboard's debrief screen polls this and opens the Workbench
        public static string NavJson()
        {
            lock (dbGate)
            {
                if (ddGo && (Program.IsDriving || (DateTime.UtcNow - ddAt).TotalSeconds > 60)) { ddGo = false; ddSeq++; }
                return "{\"go\":" + (ddGo ? "true" : "false") + ",\"seq\":" + ddSeq + "}";
            }
        }

        // a call to this PC's own irdash (the same base the DeckFeed relay uses; tests point PADDOCK_DECKFEED_BASE elsewhere)
        static bool LocalGet(string path)
        {
            try
            {
                string baseUrl = Environment.GetEnvironmentVariable("PADDOCK_DECKFEED_BASE");
                using (WebClient wc = new WebClient())
                {
                    wc.Proxy = null;
                    wc.DownloadString((string.IsNullOrEmpty(baseUrl) ? "http://localhost:8199" : baseUrl) + path);
                }
                return true;
            }
            catch (Exception ex) { Log.W("debrief: " + path + ": " + ex.Message); return false; }
        }

        static bool CosworthInstalled()
        {
            try
            {
                string baseUrl = Environment.GetEnvironmentVariable("PADDOCK_DECKFEED_BASE");
                string j;
                using (WebClient wc = new WebClient())
                {
                    wc.Proxy = null;
                    j = wc.DownloadString((string.IsNullOrEmpty(baseUrl) ? "http://localhost:8199" : baseUrl) + "/vault");
                }
                Dictionary<string, object> root = Obj(j);
                Dictionary<string, object> cw = O(G(root, "cosworth"));
                return cw != null && Bl(G(cw, "installed"));
            }
            catch (Exception ex) { Log.W("debrief: cosworth check: " + ex.Message); return false; }
        }

        // /debrief/video?id=<debrief-... | debrief-inc-...>: the clip this engine cut, from the recorder's clips folder (Range works)
        public static bool ServeVideo(NetworkStream s, string id, Dictionary<string, string> hdr)
        {
            string file = null;
            if (!string.IsNullOrEmpty(id) && id.Length <= 100 && Regex.IsMatch(id, "^[A-Za-z0-9_.-]+$") && id.IndexOf("..", StringComparison.Ordinal) < 0)
            {
                string f = Path.Combine(Recorder.ClipFolder, id + ".mp4");
                if (File.Exists(f)) file = f;
            }
            return Vault.ServeMp4(s, file, hdr);
        }
    }
}
