// O5 - the all-time personal best as a delta reference (notes in docs\benchmark.md).
//   - Combo: which car + track + layout is loaded (from the session YAML, live or from an .ibt).
//   - PbRef: for one combo, "time at every 0.05 % of the lap" of the best lap ever driven, cached in dash\refs\<car>__<track>.json.
//     Built from the best .ibt (Career knows the best lap per file); after a new best lap it is rebuilt from the live frames,
//     so no restart is needed. The delta bar (deltabar.cs) asks PbRef.Tick on its own timer; nothing here runs per sim frame.
// Everything heavy (YAML, disk, JSON) runs on worker threads at low priority and never while you are driving.
// The per-tick path allocates nothing: two preallocated sample buffers and one reference array.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    // ---------------- which car + track + layout ----------------
    static class Combo
    {
        public sealed class Info
        {
            public string Car = "", CarPath = "", Track = "", Config = "", TrackName = "", Lic = "";
            public int UserId, Ir, SubSession;
            public string Key { get { return Combo.Key(Car, Track, Config); } }
        }

        // letters and digits only, lower case, dashes between words: safe in a file name
        public static string Slug(string s)
        {
            StringBuilder sb = new StringBuilder();
            bool dash = false;
            foreach (char ch in (s ?? "").ToLowerInvariant())
            {
                if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) { if (dash && sb.Length > 0) sb.Append('-'); dash = false; sb.Append(ch); }
                else dash = true;
                if (sb.Length >= 60) break;
            }
            return sb.ToString();
        }

        // <car>__<track>[-<layout>]  (the file name of the cached reference)
        public static string Key(string car, string track, string config)
        {
            return Slug(car) + "__" + Slug(track) + (string.IsNullOrEmpty(config) ? "" : "-" + Slug(config));
        }

        // the player's own car and the track of a session YAML (live or from an .ibt); Car is "" when there is no driver entry yet
        public static Info FromYaml(string yaml)
        {
            Info i = new Info();
            if (string.IsNullOrEmpty(yaml)) return i;
            i.Track = TrackMaps.YamlValue(yaml, "TrackDisplayName"); i.Config = TrackMaps.YamlValue(yaml, "TrackConfigName"); i.TrackName = TrackMaps.YamlValue(yaml, "TrackName");
            int.TryParse(TrackMaps.YamlValue(yaml, "SubSessionID"), out i.SubSession);
            string me = TrackMaps.YamlValue(yaml, "DriverCarIdx");
            Match block = Regex.Match(yaml, "- CarIdx: " + Regex.Escape(me) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
            if (me.Length > 0 && block.Success)
            {
                string b = block.Groups[1].Value;
                i.Car = TrackMaps.YamlValue(b, "CarScreenName"); i.CarPath = TrackMaps.YamlValue(b, "CarPath"); i.Lic = TrackMaps.YamlValue(b, "LicString");
                int.TryParse(TrackMaps.YamlValue(b, "IRating"), out i.Ir); int.TryParse(TrackMaps.YamlValue(b, "UserID"), out i.UserId);
            }
            return i;
        }
    }

    // ---------------- one reference lap ----------------
    sealed class RefData
    {
        public string Key = "", Car = "", Track = "", Config = "", Source = "", File = "";
        public int Lap;
        public int Rules;            // LapRules.Version the lap was chosen under (L-1: only a lap iRacing counted); 0 = a file from before the rule
        public double Time;          // the lap time (s)
        public double CareerBest;    // the best lap the career cache knew when this was made (so a reference is not rebuilt for a lap it cannot use)
        public DateTime SetAt;       // local time the lap was driven
        public double[] T;           // seconds since the line at lap distance g / PbRef.N, g = 0..N

        public string Banner
        {
            get { return "PB " + PbRef.Lap(Time) + "  ·  set " + SetAt.ToString("d MMM", CultureInfo.InvariantCulture); }
        }
    }

    static class PbRef
    {
        public const int N = 2000;
        const int LiveMax = 36000;        // samples of one lap at 30 Hz: 20 minutes
        public static string Dir;         // dash\refs
        static volatile RefData current;
        static readonly object gate = new object();
        public static RefData Current { get { return current; } }

        public static string Lap(double t)
        {
            int m = (int)(t / 60); double s = t - m * 60;
            return (m > 0 ? m.ToString(CultureInfo.InvariantCulture) + ":" + (s < 10 ? "0" : "") : "") + s.ToString("0.000", CultureInfo.InvariantCulture);
        }

        public static void Init(string dir)
        {
            Dir = dir;
            try { Directory.CreateDirectory(dir); } catch { }
        }

        // ---- the reference array ----
        // seconds since the line at lap distance pct (0..1), straight lines between the 2001 points
        public static double At(double[] t, double pct)
        {
            if (pct <= 0) return t[0];
            if (pct >= 1) return t[N];
            double x = pct * N; int i = (int)x;
            return t[i] + (t[i + 1] - t[i]) * (x - i);
        }

        // From the samples of one lap (lap distance and lap time, both rising): the reference array.
        // The line crossings are not sampled, so both ends are tied to 0 s and the official lap time.
        // Returns null when the samples do not make a believable lap (the caller then keeps what it had).
        public static double[] FromSamples(float[] p0, float[] t0, int n0, double lapTime)
        {
            // first drop samples whose timer disagrees: the lap timer can still show the last lap's time for a frame after the line
            // (this once made a reference that jumped to 56 s in its first 0.05 %), or jump during a lap
            float[] p = new float[n0], t = new float[n0]; int n = 0;
            for (int i = 0; i < n0; i++)
            {
                if (n == 0 ? t0[i] > 3.0f : (p0[i] <= p[n - 1] || t0[i] < t[n - 1] - 1e-4f || t0[i] - t[n - 1] > 5.0f)) continue;
                p[n] = p0[i]; t[n] = t0[i]; n++;
            }
            if (n < 30) return null;
            double[] T = new double[N + 1];
            int j = 0;
            for (int g = 1; g < N; g++)
            {
                double x = g / (double)N;
                while (j < n - 1 && p[j + 1] < x) j++;
                double v;
                if (x <= p[0]) v = p[0] > 1e-9 ? t[0] * x / p[0] : 0;
                else if (j >= n - 1) v = t[n - 1] + (lapTime - t[n - 1]) * (x - p[n - 1]) / Math.Max(1e-6, 1 - p[n - 1]);
                else { double w = (x - p[j]) / Math.Max(1e-9, p[j + 1] - p[j]); v = t[j] + (t[j + 1] - t[j]) * w; }
                T[g] = Math.Max(T[g - 1], Math.Min(lapTime, v));
            }
            T[0] = 0; T[N] = lapTime;
            return Sane(T, lapTime) ? T : null;
        }

        // A lap is believable when it starts at 0, never goes back, ends at its lap time, passes half way at about half the time
        // and has no hole: the longest step between two points (0.05 % of the lap) is a second and a half at the very most.
        public static bool Sane(double[] T, double lapTime)
        {
            if (T == null || T.Length != N + 1 || lapTime < 15 || Math.Abs(T[0]) > 1e-9 || Math.Abs(T[N] - lapTime) > 0.01) return false;
            if (T[N / 2] < lapTime * 0.25 || T[N / 2] > lapTime * 0.75) return false;
            for (int i = 1; i <= N; i++) { double d = T[i] - T[i - 1]; if (d < -1e-9 || d > 1.5) return false; }
            return true;
        }

        // ---- cache file ----
        static string PathFor(string key) { return Path.Combine(Dir, key + ".json"); }

        public static string ToJson(RefData r)
        {
            CultureInfo inv = CultureInfo.InvariantCulture;
            StringBuilder sb = new StringBuilder(24000);
            sb.Append("{\"v\":1,\"key\":").Append(Json_.S(r.Key)).Append(",\"car\":").Append(Json_.S(r.Car)).Append(",\"track\":").Append(Json_.S(r.Track)).Append(",\"config\":").Append(Json_.S(r.Config))
              .Append(",\"time\":").Append(r.Time.ToString("0.000", inv)).Append(",\"careerBest\":").Append(r.CareerBest.ToString("0.000", inv))
              .Append(",\"set\":").Append(Json_.S(r.SetAt.ToString("s", inv))).Append(",\"source\":").Append(Json_.S(r.Source)).Append(",\"file\":").Append(Json_.S(r.File))
              .Append(",\"lap\":").Append(r.Lap).Append(",\"rules\":").Append(r.Rules).Append(",\"n\":").Append(N).Append(",\"t\":[");
            for (int i = 0; i <= N; i++) { if (i > 0) sb.Append(','); sb.Append(r.T[i].ToString("0.###", inv)); }
            sb.Append("]}");
            return sb.ToString();
        }

        public static RefData FromJson(string json)
        {
            JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue;
            Dictionary<string, object> d = js.DeserializeObject(json) as Dictionary<string, object>;
            if (d == null || !d.ContainsKey("t")) return null;
            IList arr = d["t"] as IList;
            if (arr == null || arr.Count != N + 1) return null;
            RefData r = new RefData();
            r.Key = S(d, "key"); r.Car = S(d, "car"); r.Track = S(d, "track"); r.Config = S(d, "config"); r.Source = S(d, "source"); r.File = S(d, "file");
            r.Time = Num(d, "time"); r.CareerBest = Num(d, "careerBest"); r.Lap = (int)Num(d, "lap"); r.Rules = (int)Num(d, "rules");
            DateTime when; if (DateTime.TryParse(S(d, "set"), CultureInfo.InvariantCulture, DateTimeStyles.None, out when)) r.SetAt = when;
            r.T = new double[N + 1];
            for (int i = 0; i <= N; i++) r.T[i] = Convert.ToDouble(arr[i], CultureInfo.InvariantCulture);
            if (!Sane(r.T, r.Time)) return null;                    // a damaged or nonsensical file is no reference (it is rebuilt)
            return r;
        }
        static string S(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, CultureInfo.InvariantCulture) : ""; }
        static double Num(Dictionary<string, object> d, string k) { object o; double v; return d.TryGetValue(k, out o) && o != null && double.TryParse(Convert.ToString(o, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : 0; }

        public static RefData Load(string key)
        {
            try
            {
                string f = PathFor(key);
                if (!File.Exists(f)) return null;
                return FromJson(File.ReadAllText(f, Encoding.UTF8));
            }
            catch (Exception ex) { Log.W("pb reference " + key + ": " + ex.Message); return null; }
        }

        public static void Save(RefData r)
        {
            lock (gate)
            {
                Directory.CreateDirectory(Dir);
                string f = PathFor(r.Key);
                File.WriteAllText(f + ".tmp", ToJson(r), new UTF8Encoding(false));
                if (File.Exists(f)) File.Delete(f);
                File.Move(f + ".tmp", f);
            }
        }

        // ---- build from the best .ibt of a combo ----
        // The career cache says which files hold the best laps; the first one whose lap can really be used (a full lap, not through the pits) wins.
        public static RefData BuildFromIbt(string car, string track, string config, out string why)
        {
            why = "";
            List<BestRow> rows = Career.BestFiles(car, track, config);
            if (rows.Count == 0) { why = "no timed lap for this car and track yet"; return null; }
            double careerBest = rows[0].Best;
            int tried = 0;
            foreach (BestRow row in rows)
            {
                if (tried++ >= 6) break;
                string full = IbtLaps.Resolve(row.File);
                if (full == null) { why = "the telemetry file " + row.File + " is gone"; continue; }
                if (Career.OnlineOnly(new FileInfo(full))) { why = "the telemetry file is online-only in OneDrive"; continue; }
                IbtLaps.RefLap rl;
                try { rl = IbtLaps.Reference(full, row.Best, 0.011, N); }
                catch (Exception ex) { why = row.File + ": " + ex.Message; continue; }
                if (rl == null) { why = "the best lap in " + row.File + " is not a full lap through the pits-free part of the track"; continue; }
                if (!Sane(rl.T, rl.Time)) { why = "the best lap in " + row.File + " has holes in its data"; continue; }
                RefData r = new RefData();
                r.Key = Combo.Key(car, track, config); r.Car = car; r.Track = track; r.Config = config;
                r.Time = rl.Time; r.CareerBest = careerBest; r.SetAt = rl.When; r.T = rl.T; r.Source = "ibt"; r.File = row.File; r.Lap = rl.Lap; r.Rules = LapRules.Version;      // IbtLaps.Reference only picks a lap iRacing counted
                why = "";
                return r;
            }
            return null;
        }

        // for the sessions page and tests: build (or reuse) the reference of one combo right now
        public static RefData Ensure(string car, string track, string config, bool force, out string why)
        {
            why = "";
            string key = Combo.Key(car, track, config);
            RefData have = Load(key);
            double cb = 0; string f0; DateTime d0;
            Career.BestFor(car, track, config, out cb, out f0, out d0);
            bool fresh = have != null && (cb <= 0 || have.Time <= cb + 0.0005 || have.CareerBest >= cb - 0.0005) && !NotCounted(have, cb);
            if (have != null && fresh && !force) return have;
            RefData built = BuildFromIbt(car, track, config, out why);
            if (built == null) return NotCounted(have, cb) ? null : have;
            Save(built);
            return built;
        }

        // L-1: a reference file made before the lap rule (Rules 0) from a telemetry file that is quicker than the quickest lap iRacing counted (the career's best) is a lap
        // iRacing did not count: it is never used, the reference is built again from a counted lap. A file made from a live lap is kept: a live lap is only adopted when
        // iRacing's own best lap equals it (CheckPending), i.e. when iRacing counted it. The career best is 0 for the tests' made-up car, so those files are never touched.
        static bool NotCounted(RefData r, double careerBest)
        {
            return r != null && r.Rules < LapRules.Version && r.Source == "ibt" && careerBest > 0 && r.Time < careerBest - 0.0005;
        }

        // ---- live: which combo is loaded, the delta, recording the lap, picking up a new best ----
        static volatile int comboEpoch;
        static string curKey = "";
        static Combo.Info combo = new Combo.Info();
        static double knownBest;                     // the career's best lap for this combo (0 = none)
        static readonly Dictionary<string, double> failedAt = new Dictionary<string, double>();   // key -> career best at the failed build
        static int yamlVer = -1, parseBusy;
        static string latestYaml = ""; static int latestVer;
        static bool wasConnected;

        // what the bar reads (UI thread)
        public static bool Ok;              // a delta against the reference is valid right now
        public static double Delta;         // smoothed seconds, negative = ahead of the reference
        public static bool Flying;          // the lap in progress started with a clean crossing of the line
        public static int FlyingDone;       // clean laps finished since the session (or the reference) loaded: the "first lap" banner stops after one

        static int seenEpoch = -1;
        static long lastSeq = -1; static int lastLap = -1; static double lastPct = -1;
        static bool lapStarted, dirty, haveSmooth; static int bad;
        static double smooth; static DateTime smoothAt = DateTime.MinValue;
        static float[] recP = new float[LiveMax], recT = new float[LiveMax], penP = new float[LiveMax], penT = new float[LiveMax];
        static int recN, penN; static double recLastPct;
        static bool penOn; static double penLastBefore; static DateTime penAt = DateTime.MinValue, penSeen = DateTime.MinValue; static int penLap;

        public static string KeyNow { get { return curKey; } }
        public static Combo.Info ComboNow { get { return combo; } }
        public static double KnownBest { get { return knownBest; } }

        // from the delta bar's timer on the UI thread (30 Hz while shown, 4 Hz hidden)
        public static void Tick(Frame f, bool onTrack, bool inPits, DateTime now)
        {
            if (!f.Connected)
            {
                if (wasConnected) { wasConnected = false; ResetLap(); }
                return;
            }
            if (!wasConnected)
            {
                // a new connection: whatever was loaded belongs to the last session (it stays until now so the debrief can ask about it)
                wasConnected = true; yamlVer = -1; curKey = ""; current = null; knownBest = 0; comboEpoch++;
            }
            if (f.SessionVersion != yamlVer && f.SessionYaml.Length > 0) { yamlVer = f.SessionVersion; QueueParse(f.SessionYaml, f.SessionVersion); }
            if (seenEpoch != comboEpoch) { seenEpoch = comboEpoch; ResetLap(); FlyingDone = 0; }
            if (!onTrack || f.Num("IsReplayPlaying") != 0) { ResetLap(); return; }       // a replay is no lap of yours
            if (f.Seq == lastSeq) return;
            lastSeq = f.Seq;

            int lap = (int)f.Num("Lap");
            double pct = f.Num("LapDistPct"), cur = f.Num("LapCurrentLapTime");
            if (pct < 0 || pct > 1.0001) { dirty = true; lastPct = -1; Flying = false; Ok = false; return; }
            RefData rd = current;
            bool wrapped = lastLap >= 0 && lap != lastLap && lastPct > 0.9 && pct < 0.1;
            if (wrapped)
            {
                // the line: the lap just driven is worth keeping if it was clean from line to line
                if (lapStarted && !dirty)
                {
                    FlyingDone++;
                    if (recN > 30 && recLastPct > 0.97)
                    {
                        float[] a = penP; penP = recP; recP = a; a = penT; penT = recT; recT = a;
                        penN = recN; penOn = true; penLastBefore = lastLastTime; penAt = now; penSeen = DateTime.MinValue; penLap = lastLap;
                    }
                }
                lapStarted = !inPits; dirty = inPits; recN = 0; recLastPct = 0; haveSmooth = false; bad = 0;
            }
            else if (lastPct >= 0)
            {
                double dp = pct - lastPct;
                if (dp < -0.02 || dp > 0.1) { dirty = true; lapStarted = false; }     // a tow, a reset or a jump: this lap is no fair comparison
            }
            if (inPits) { dirty = true; lapStarted = false; }
            lastLap = lap; lastPct = pct;
            lastLastTime = f.Num("LapLastLapTime");
            if (penOn) CheckPending(f, now);

            Flying = lapStarted && !dirty;
            if (!Flying) { Ok = false; return; }
            // keep the lap's samples (rising lap distance only), so a new best can become the reference
            if (pct > recLastPct + 1e-5 && recN < LiveMax)
            {
                if (pct - recLastPct > 0.03) { dirty = true; Flying = false; Ok = false; return; }
                // the lap timer can still show the last lap's time for a frame after the line: such a sample is left out
                bool plausible = recN == 0 ? cur >= 0 && cur <= 3.0 : cur >= recT[recN - 1] - 1e-4 && cur - recT[recN - 1] <= 5.0;
                if (plausible) { recP[recN] = (float)pct; recT[recN] = (float)cur; recN++; recLastPct = pct; }
            }
            if (rd == null) { Ok = false; return; }
            // the line itself: the lap counter and the distance can disagree for one frame
            double pe = pct;
            if (cur < 1.5 && pct > 0.9) pe = 0;
            else if (cur > rd.Time * 0.5 && pct < 0.02) return;
            double raw = cur - At(rd.T, pe);
            if (Math.Abs(raw) > Math.Max(10.0, rd.Time * 0.3)) { if (++bad > 90) { dirty = true; Flying = false; Ok = false; } return; }     // hold the last value
            bad = 0;
            if (!haveSmooth) { smooth = raw; haveSmooth = true; }
            else
            {
                double dt = (now - smoothAt).TotalSeconds;
                smooth += (raw - smooth) * (dt <= 0 ? 1 : 1 - Math.Exp(-dt / 0.12));      // about 0.12 s: calm, but no lag you can feel
            }
            smoothAt = now; Delta = smooth; Ok = true;
        }
        static double lastLastTime;

        static void ResetLap()
        {
            lapStarted = false; dirty = false; haveSmooth = false; Ok = false; Flying = false; recN = 0; recLastPct = 0; lastLap = -1; lastPct = -1; bad = 0; penOn = false;
        }

        // the sim announces a lap's time a moment after the line (up to ~1.5 s); then a counted new best becomes the reference
        static void CheckPending(Frame f, DateTime now)
        {
            double last = f.Num("LapLastLapTime");
            bool changed = Math.Abs(last - penLastBefore) > 0.0005;
            if (changed && penSeen == DateTime.MinValue) penSeen = now;
            if (!changed && (now - penAt).TotalSeconds < 4) return;
            if (changed && (now - penSeen).TotalSeconds < 0.6) return;      // give the sim a moment to update its best-lap time too
            penOn = false; penSeen = DateTime.MinValue;
            if (!changed) return;
            RefData rd = current;
            double bar = rd != null ? rd.Time : (knownBest > 0 ? knownBest : double.MaxValue);
            double best = f.Num("LapBestLapTime");
            // iRacing's own best-lap time only takes laps it counted, so "equals the session best" doubles as the validity check
            if (last < 15 || last >= bar - 0.0005 || Math.Abs(best - last) > 0.0006 || penN < 30) return;
            float[] p = new float[penN], t = new float[penN];
            Array.Copy(penP, p, penN); Array.Copy(penT, t, penN);
            string key = curKey; Combo.Info ci = combo; int n = penN, lapNo = penLap; double kb = knownBest;
            ThreadPool.QueueUserWorkItem(delegate { try { Adopt(key, ci, p, t, n, last, lapNo, kb); } catch (Exception ex) { Log.W("pb reference (live): " + ex.Message); } });
        }

        static void Adopt(string key, Combo.Info ci, float[] p, float[] t, int n, double lapTime, int lapNo, double kb)
        {
            double[] T = FromSamples(p, t, n, lapTime);
            if (T == null) { Log.W("personal best reference: the samples of that " + Lap(lapTime) + " lap were not clean enough to use; the old reference stays (the .ibt will give the right one)"); return; }
            RefData r = new RefData();
            r.Key = key; r.Car = ci.Car; r.Track = ci.Track; r.Config = ci.Config; r.Time = lapTime; r.CareerBest = kb; r.SetAt = DateTime.Now;
            r.Source = "live"; r.Lap = lapNo; r.T = T; r.Rules = LapRules.Version;
            Save(r);
            if (curKey == key) current = r;
            Log.W("personal best reference updated from the live lap: " + ci.Car + " at " + ci.Track + " " + Lap(lapTime));
        }

        // ---- combo changes (worker threads) ----
        static void QueueParse(string yaml, int ver)
        {
            latestYaml = yaml; latestVer = ver;
            if (Interlocked.Exchange(ref parseBusy, 1) == 1) return;
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    int done;
                    do { done = latestVer; Combo.Info ci = Combo.FromYaml(latestYaml); if (ci.Car.Length > 0 && ci.Track.Length > 0) OnCombo(ci); }
                    while (done != latestVer);
                }
                catch (Exception ex) { Log.W("pb reference: " + ex.Message); }
                finally { Interlocked.Exchange(ref parseBusy, 0); }
            });
        }

        static void OnCombo(Combo.Info ci)
        {
            string key = ci.Key;
            if (key == curKey) { combo = ci; return; }
            curKey = key; combo = ci; current = null; knownBest = 0; comboEpoch++;
            RefData have = Load(key);
            double cb; string f0; DateTime d0;
            if (Career.BestFor(ci.Car, ci.Track, ci.Config, out cb, out f0, out d0)) knownBest = cb;
            bool uncounted = NotCounted(have, cb);       // L-1: a lap iRacing did not count is never the reference (see NotCounted)
            current = uncounted ? null : have;
            if (uncounted) Log.W("pb reference: the saved " + Lap(have.Time) + " lap for " + ci.Car + " at " + ci.Track + " is quicker than the best lap iRacing counted (" + Lap(cb) + "); it is not used");
            else if (have != null) Log.W("pb reference loaded: " + ci.Car + " at " + ci.Track + " " + Lap(have.Time) + " (" + have.Source + ")");
            bool stale;
            lock (failedAt)
            {
                double fb; bool failed = failedAt.TryGetValue(key, out fb) && Math.Abs(fb - cb) < 0.0005;
                stale = cb > 0 && !failed && (have == null || uncounted || (have.Time > cb + 0.0005 && cb < have.CareerBest - 0.0005));
            }
            if (!stale) return;
            Thread t = new Thread(delegate ()
            {
                try
                {
                    while (Program.IsDriving && curKey == key) Thread.Sleep(5000);       // a big file never competes with the sim
                    if (curKey != key) return;
                    string why;
                    RefData built = BuildFromIbt(ci.Car, ci.Track, ci.Config, out why);
                    if (built == null)
                    {
                        lock (failedAt) failedAt[key] = cb;
                        Log.W("pb reference: none built for " + ci.Car + " at " + ci.Track + " (" + why + ")");
                        return;
                    }
                    Save(built);
                    if (curKey == key && (current == null || built.Time <= current.Time + 0.0005)) current = built;
                    Log.W("pb reference built: " + ci.Car + " at " + ci.Track + " " + Lap(built.Time) + " from " + built.File + " lap " + built.Lap);
                }
                catch (Exception ex) { Log.W("pb reference build: " + ex.Message); }
            });
            t.IsBackground = true; t.Priority = ThreadPriority.Lowest; t.Start();
        }

        // tests: force a combo, as if its session had just loaded
        public static void TestCombo(Combo.Info ci) { OnCombo(ci); }

        // what the bar is working from right now (for /pbref/state and the tests)
        public static string StateJson()
        {
            RefData rd = current; CultureInfo inv = CultureInfo.InvariantCulture;
            return "{\"key\":" + Json_.S(curKey) + ",\"hasRef\":" + (rd != null ? "true" : "false") + ",\"time\":" + (rd != null ? rd.Time.ToString("0.000", inv) : "null") +
                   ",\"source\":" + Json_.S(rd != null ? rd.Source : "") + ",\"ok\":" + (Ok ? "true" : "false") + ",\"delta\":" + Delta.ToString("0.0000", inv) +
                   ",\"flying\":" + (Flying ? "true" : "false") + ",\"flyingDone\":" + FlyingDone + ",\"knownBest\":" + knownBest.ToString("0.000", inv) + ",\"samples\":" + recN + "}";
        }

        // the cached reference as JSON for /pbref (times left out unless asked for: 2001 numbers)
        public static string RefJson(RefData r, bool withTimes)
        {
            if (r == null) return "null";
            CultureInfo inv = CultureInfo.InvariantCulture;
            StringBuilder sb = new StringBuilder("{\"key\":" + Json_.S(r.Key) + ",\"car\":" + Json_.S(r.Car) + ",\"track\":" + Json_.S(r.Track) + ",\"config\":" + Json_.S(r.Config) +
                ",\"time\":" + r.Time.ToString("0.000", inv) + ",\"set\":" + Json_.S(r.SetAt.ToString("s", inv)) + ",\"source\":" + Json_.S(r.Source) + ",\"file\":" + Json_.S(r.File) +
                ",\"lap\":" + r.Lap + ",\"careerBest\":" + r.CareerBest.ToString("0.000", inv) + ",\"rules\":" + r.Rules + ",\"n\":" + N + ",\"banner\":" + Json_.S(r.Banner));
            if (withTimes)
            {
                sb.Append(",\"t\":[");
                for (int i = 0; i <= N; i++) { if (i > 0) sb.Append(','); sb.Append(r.T[i].ToString("0.###", inv)); }
                sb.Append(']');
            }
            return sb.Append('}').ToString();
        }

        // tests: a reference built from raw samples exactly as the live path does it (see FromSamples), or null when they are not believable
        public static double[] TestFromSamples(float[] p, float[] t, int n, double lapTime) { return FromSamples(p, t, n, lapTime); }

        // tests: a reference from one lap of an .ibt under a made-up car and track, so a real cache file is never touched
        public static RefData TestBuild(string path, int lapNo, string car, string track, string config)
        {
            IbtLaps.RefLap rl = IbtLaps.ReferenceLapNo(path, lapNo, N);
            if (rl == null) return null;
            RefData r = new RefData();
            r.Key = Combo.Key(car, track, config); r.Car = car; r.Track = track; r.Config = config; r.Time = rl.Time; r.SetAt = rl.When; r.T = rl.T; r.Source = "ibt"; r.File = Path.GetFileName(path); r.Lap = rl.Lap;
            Save(r);
            return r;
        }

        public static bool TestClear(string car, string track, string config)
        {
            if (!car.StartsWith("Test ") || !track.StartsWith("Test ")) return false;       // only ever the made-up ones
            string f = PathFor(Combo.Key(car, track, config));
            if (File.Exists(f)) File.Delete(f);
            string cur = curKey;
            if (cur == Combo.Key(car, track, config)) current = null;
            return true;
        }
    }
}
