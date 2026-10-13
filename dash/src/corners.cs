// Corner model (WS18; notes in docs\corners.md): one source of truth for the turns of every track.
//   - Lovely Track Data (CC BY-NC-SA 4.0): corner names, pit lane and sector markers. An offline copy lives in
//     data\corners\lovely\ (irdash reads it first and goes to GitHub only to fill a gap or refresh an old file).
//   - Where Lovely has no corner list: corners found in Peter's own driving (best clean lap in his .ibt files, from yaw rate)
//     or, when no clean lap exists, from the outline irdash already holds for the track. Saved in data\corners\auto\<trackkey>.json.
// Serves /corners?track=&config=&id=&key= (see Route). Everything here only reads: telemetry files are opened read-only,
// never while he is driving, and never a file written in the last 2 minutes.
using System;
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
    sealed class CornerTurn
    {
        public int N;                       // 1..n in lap order from the start/finish line: the same "T5" on every page
        public string Name = "";            // a real name ("The Esses", "Eau Rouge"), or "" for a plain numbered corner
        public string Official = "";        // the circuit's own number when Lovely gave one ("10A"); kept for reference only
        public double P0, Pa, P1;           // lap fractions: start, apex, end
        public string Source = "";          // lovely | auto
        public bool ApexGiven;              // Lovely itself marks the apex (not serialised)
    }

    sealed class CornerSet
    {
        public string Source = "none";      // where the turn list came from: lovely | auto | none
        public string Basis = "";           // auto only: telemetry | outline
        public string Credit = "", LovelyFile = "", Key = "", Track = "", Config = "", Updated = "", PitSource = "", Detail = "";
        public List<CornerTurn> Turns = new List<CornerTurn>();
        public double PitIn = -1, PitOut = -1;
        public List<double> Sectors = new List<double>();
        public bool LovelyListed;           // Lovely knows the layout (it may list sectors and pit lane only)
        public bool Pending;                // a detection is queued or running for this track
    }

    sealed class LovelyEntry { public string TrackId = "", TrackName = "", Path = "", File = "", Folder = ""; }

    // one clean lap read from a telemetry file (what the detector needs)
    sealed class CornerLap
    {
        public string File = "", Track = "", Config = "", TrackId = "", TrackName = "", Key = "";
        public int LapNo; public double Time, LengthM;
        public float[] Pct, Spd, Yaw, LatA;
        public List<double> PitIn = new List<double>(), PitOut = new List<double>();
    }

    // ---------------- finding corners in a curvature trace (pure maths: no files, no irdash state) ----------------
    static class CornerDetect
    {
        // Tuned on Road Atlanta, Okayama, Sebring, Lime Rock and Tsukuba against Lovely's lists (tests\corners-test.ps1 checks it).
        public static double KOn = 0.0009, KOff = 0.0006;      // curvature (1 / metres radius) that starts / ends a corner
        public static double SmoothM = 30;                     // smoothing along the lap
        public static double MergeGapM = 40;                   // same-direction pieces closer than this may be one corner ...
        public static double ValleyRatio = 0.45;               // ... when the dip between them is shallower than this share of the lower peak
        public static double MinTurnDeg = 10, BigTurnDeg = 18; // a corner turns the car at least this much ...
        public static double PeakMin = 0.0018;                 // ... and is tight somewhere (or turns it at least BigTurnDeg)
        public static double MinLenM = 20;
        public static double PeakSepM = 40;                    // two peaks closer than this are one apex

        sealed class Seg { public int A, B, Apex; public double Peak, Deg; public int Sign; }

        // k = signed curvature per equal-distance bin around the closed lap (positive = left), ds = metres per bin
        public static List<CornerTurn> FromCurvature(double[] k, double ds, string source)
        {
            int B = k.Length;
            List<CornerTurn> res = new List<CornerTurn>();
            if (B < 100 || ds <= 0) return res;
            int w = Math.Max(1, (int)Math.Round(SmoothM / ds / 2));
            double[] s = new double[B];
            double run = 0;
            for (int j = -w; j <= w; j++) run += k[(j + B) % B];
            for (int i = 0; i < B; i++)
            {
                s[i] = run / (2 * w + 1);
                run += k[(i + w + 1) % B] - k[((i - w) % B + B) % B];
            }
            // walk the lap from its straightest point so a corner is never cut by the end of the array
            int quiet = 0; double best = double.MaxValue;
            for (int i = 0; i < B; i++)
            {
                double a = 0; for (int j = -w; j <= w; j += 2) a += Math.Abs(s[(i + j + B) % B]);
                if (a < best) { best = a; quiet = i; }
            }
            List<Seg> segs = new List<Seg>();
            bool inSeg = false; int start = 0;
            for (int i = 0; i <= B; i++)
            {
                double v = i < B ? Math.Abs(s[(quiet + i) % B]) : 0;
                int sg = i < B ? (s[(quiet + i) % B] >= 0 ? 1 : -1) : 0;
                bool flip = inSeg && i < B && i > start && sg != Sign(s, quiet, i - 1);
                if (inSeg && (v < KOff || flip)) { segs.Add(Measure(s, quiet, start, i, ds)); inSeg = false; }
                if (!inSeg && i < B && v >= KOn) { inSeg = true; start = i; }
            }
            // pieces of one sweep that fell apart (same direction, a short and shallow dip between them) are one corner;
            // one long piece with two clear peaks and a deep valley between them is two
            List<Seg> merged = new List<Seg>();
            foreach (Seg g in segs)
            {
                Seg last = merged.Count > 0 ? merged[merged.Count - 1] : null;
                if (last != null && last.Sign == g.Sign && (g.A - last.B) * ds < MergeGapM && MinAbs(s, quiet, last.B, g.A) >= ValleyRatio * Math.Min(last.Peak, g.Peak))
                {
                    last.B = g.B; last.Deg += g.Deg;
                    if (g.Peak > last.Peak) { last.Peak = g.Peak; last.Apex = g.Apex; }
                }
                else merged.Add(g);
            }
            List<Seg> cut = new List<Seg>();
            foreach (Seg g in merged) cut.AddRange(SplitAtValleys(s, quiet, g, ds));
            merged = cut;
            foreach (Seg g in merged)
            {
                if ((g.B - g.A) * ds < MinLenM || g.Deg < MinTurnDeg) continue;
                if (g.Peak < PeakMin && g.Deg < BigTurnDeg) continue;
                CornerTurn t = new CornerTurn();
                t.P0 = Wrap((quiet + g.A) / (double)B); t.P1 = Wrap((quiet + g.B) / (double)B); t.Pa = Wrap((quiet + g.Apex) / (double)B);
                t.Source = source;
                res.Add(t);
            }
            res = OvalSplit(res, source);
            res.Sort(delegate (CornerTurn a, CornerTurn b) { return a.Pa.CompareTo(b.Pa); });
            for (int i = 0; i < res.Count; i++) res[i].N = i + 1;
            return res;
        }

        // An oval comes out as two long bends. Every oval is driven as Turns 1-2 and 3-4, so each long bend is cut in half
        // (the apex of each half is the middle of that half). Only when exactly two bends of at least 12 % of the lap sit on opposite sides of it.
        static List<CornerTurn> OvalSplit(List<CornerTurn> t, string source)
        {
            if (t.Count != 2) return t;
            double[] span = new double[2];
            for (int i = 0; i < 2; i++) { span[i] = t[i].P1 - t[i].P0; if (span[i] < 0) span[i] += 1; if (span[i] < 0.12) return t; }
            double apart = Math.Abs(t[0].Pa - t[1].Pa); if (apart > 0.5) apart = 1 - apart;
            if (apart < 0.3) return t;
            List<CornerTurn> res = new List<CornerTurn>();
            for (int i = 0; i < 2; i++)
            {
                double mid = Wrap(t[i].P0 + span[i] / 2);
                CornerTurn a = new CornerTurn(), b = new CornerTurn();
                a.P0 = t[i].P0; a.P1 = mid; a.Pa = Wrap(t[i].P0 + span[i] * 0.25); a.Source = source;
                b.P0 = mid; b.P1 = t[i].P1; b.Pa = Wrap(t[i].P0 + span[i] * 0.75); b.Source = source;
                res.Add(a); res.Add(b);
            }
            return res;
        }

        static int Sign(double[] s, int quiet, int i) { return s[(quiet + i) % s.Length] >= 0 ? 1 : -1; }

        static double MinAbs(double[] s, int quiet, int a, int b)
        {
            double m = double.MaxValue;
            for (int i = a; i < b; i++) m = Math.Min(m, Math.Abs(s[(quiet + i) % s.Length]));
            return m == double.MaxValue ? 0 : m;
        }

        // A piece with two clear peaks at least PeakSepM apart and a deep valley between them is two corners
        // (Road Atlanta 10B / 11 / 12 are one long right-hander in the curvature trace until this cuts it).
        static List<Seg> SplitAtValleys(double[] s, int quiet, Seg g, double ds)
        {
            int B = s.Length, sep = Math.Max(2, (int)(PeakSepM / ds));
            List<int> peaks = new List<int>();
            for (int i = g.A; i < g.B; i++)
            {
                double v = Math.Abs(s[(quiet + i) % B]); bool top = true;
                for (int j = Math.Max(g.A, i - sep); j <= Math.Min(g.B - 1, i + sep) && top; j++)
                {
                    double u = Math.Abs(s[(quiet + j) % B]);
                    if (u > v || (u == v && j < i)) top = false;
                }
                if (top) peaks.Add(i);
            }
            bool again = true;
            while (again && peaks.Count > 1)
            {
                again = false;
                for (int p = 0; p + 1 < peaks.Count; p++)
                {
                    double va = Math.Abs(s[(quiet + peaks[p]) % B]), vb = Math.Abs(s[(quiet + peaks[p + 1]) % B]);
                    if (MinAbs(s, quiet, peaks[p], peaks[p + 1] + 1) >= ValleyRatio * Math.Min(va, vb)) { peaks.RemoveAt(va >= vb ? p + 1 : p); again = true; break; }
                }
            }
            List<Seg> res = new List<Seg>();
            int from = g.A;
            for (int p = 0; p < peaks.Count; p++)
            {
                int to = g.B;
                if (p + 1 < peaks.Count)
                {
                    double lo = double.MaxValue; to = peaks[p];
                    for (int i = peaks[p]; i <= peaks[p + 1]; i++) { double v = Math.Abs(s[(quiet + i) % B]); if (v < lo) { lo = v; to = i; } }
                }
                if (to > from) res.Add(Measure(s, quiet, from, to, ds));
                from = to;
            }
            if (res.Count == 0) res.Add(g);
            return res;
        }
        static double Wrap(double p) { p %= 1.0; if (p < 0) p += 1.0; return p; }

        static Seg Measure(double[] s, int quiet, int a, int b, double ds)
        {
            int B = s.Length; Seg g = new Seg(); g.A = a; g.B = b;
            double sum = 0, peak = 0; int apex = a;
            for (int i = a; i < b; i++)
            {
                double v = s[(quiet + i) % B];
                sum += Math.Abs(v) * ds;
                if (Math.Abs(v) > peak) { peak = Math.Abs(v); apex = i; }
                g.Sign = v >= 0 ? 1 : -1;
            }
            g.Peak = peak; g.Apex = apex; g.Deg = sum * 180.0 / Math.PI;
            return g;
        }

        // curvature of a closed outline of points (x east, y north, metres), resampled to equal distance; also returns the length
        public static double[] OutlineCurvature(List<double[]> pts, int bins, out double lengthM)
        {
            int n = pts.Count;
            double[] cum = new double[n + 1];
            for (int i = 0; i < n; i++)
            {
                double[] p = pts[i], q = pts[(i + 1) % n];
                cum[i + 1] = cum[i] + Math.Sqrt((q[0] - p[0]) * (q[0] - p[0]) + (q[1] - p[1]) * (q[1] - p[1]));
            }
            lengthM = cum[n];
            double[] x = new double[bins], y = new double[bins];
            int j = 0;
            for (int b = 0; b < bins; b++)
            {
                double d = lengthM * b / bins;
                while (j < n - 1 && cum[j + 1] < d) j++;
                double[] p = pts[j], q = pts[(j + 1) % n];
                double f = cum[j + 1] > cum[j] ? (d - cum[j]) / (cum[j + 1] - cum[j]) : 0;
                x[b] = p[0] + (q[0] - p[0]) * f; y[b] = p[1] + (q[1] - p[1]) * f;
            }
            // heading change over a short chord, so the 5 m wobble of a binned outline does not read as a corner
            int h = Math.Max(2, (int)Math.Round(12.0 / (lengthM / bins)));
            double[] k = new double[bins];
            for (int b = 0; b < bins; b++)
            {
                int a0 = ((b - h) % bins + bins) % bins, c0 = (b + h) % bins;
                double h1 = Math.Atan2(y[b] - y[a0], x[b] - x[a0]), h2 = Math.Atan2(y[c0] - y[b], x[c0] - x[b]);
                double dh = h2 - h1; while (dh > Math.PI) dh -= 2 * Math.PI; while (dh < -Math.PI) dh += 2 * Math.PI;
                k[b] = dh / (h * (lengthM / bins));
            }
            return k;
        }

        // curvature along one lap from yaw rate: bins of equal lap distance, each the mean of yaw / speed
        public static double[] LapCurvature(CornerLap lap, int bins)
        {
            double[] sum = new double[bins]; int[] cnt = new int[bins];
            for (int i = 0; i < lap.Pct.Length; i++)
            {
                double sp = lap.Spd[i]; if (sp < 8) continue;
                double kv = lap.Yaw != null ? lap.Yaw[i] / sp : lap.LatA[i] / (sp * sp);
                int b = (int)(lap.Pct[i] * bins); if (b < 0 || b >= bins) continue;
                sum[b] += kv; cnt[b]++;
            }
            double[] k = new double[bins];
            for (int b = 0; b < bins; b++) if (cnt[b] > 0) k[b] = sum[b] / cnt[b];
            for (int b = 0; b < bins; b++)
            {
                if (cnt[b] > 0) continue;
                int a = b, c = b, da = 0, dc = 0;
                while (cnt[a] == 0 && da < bins) { a = (a - 1 + bins) % bins; da++; }
                while (cnt[c] == 0 && dc < bins) { c = (c + 1) % bins; dc++; }
                k[b] = da + dc > 0 && cnt[a] > 0 && cnt[c] > 0 ? k[a] + (k[c] - k[a]) * da / (double)(da + dc) : 0;
            }
            return k;
        }
    }

    // ---------------- the module ----------------
    static class Corners
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public const string LovelyCredit = "Corner names: Lovely Track Data · CC BY-NC-SA 4.0";
        const string LovelyBase = "https://raw.githubusercontent.com/Lovely-Sim-Racing/lovely-track-data/main/data/";
        const int RefreshDays = 45;                      // a local Lovely file older than this is fetched again (quietly, never while driving)
        static readonly object gate = new object();

        internal static string DataRoot = null;                // set only by a test harness; irdash uses the iRacingDeck folder
        static string Root { get { return Path.Combine(DataRoot ?? Program.RootDir, @"data\corners"); } }
        static string LovelyDir { get { return Path.Combine(Root, "lovely"); } }
        static string AutoDir { get { return Path.Combine(Root, "auto"); } }

        static string D(double d) { return d.ToString("0.####", Inv); }
        static string Err(string m) { return "{\"error\":" + Json_.S(m) + "}"; }

        // ---------------- HTTP ----------------
        public static string Route(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            try
            {
                string track, config, id, key, build, file, lap;
                q.TryGetValue("track", out track); q.TryGetValue("config", out config); q.TryGetValue("id", out id); q.TryGetValue("key", out key); q.TryGetValue("build", out build);
                track = Clip(track); config = Clip(config); id = Regex.Replace(id ?? "", "[^0-9]", ""); key = key ?? "";
                if (key.Length > 0 && !Regex.IsMatch(key, "^[a-z0-9_-]{1,80}$")) key = "";
                if (path == "/corners")
                {
                    if (key.Length == 0 && id.Length > 0 && track.Length > 0) key = TrackMaps.MakeKey(id, track);
                    if (key.Length > 0 && id.Length == 0) { Match km = Regex.Match(key, "^t(\\d+)-"); if (km.Success) id = km.Groups[1].Value; }
                    if (build == "1")
                    {
                        if (key.Length == 0) { code = 400; return Err("need key=, or id= and track="); }
                        if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
                        string why;
                        if (Resolve(track, config, id, key, false).Source == "lovely") why = "Lovely Track Data has the corners; nothing to find";     // Lovely names win
                        else BuildAuto(key, track, config, out why);
                        Log.W("corners: build " + key + " - " + why);
                    }
                    return SetJson(Resolve(track, config, id, key, true));
                }
                if (path == "/corners/detect")
                {
                    // dry run on one telemetry file (nothing is written): the corners found in its best clean lap, or in lap=<n>
                    q.TryGetValue("file", out file); q.TryGetValue("lap", out lap);
                    if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
                    string full = IbtLaps.Resolve(file);
                    if (full == null) { code = 404; return Err("no such telemetry file"); }
                    if (Career.OnlineOnly(new FileInfo(full))) { code = 409; return Err("Online-only in OneDrive: run tools\\keep-iracing-local.cmd"); }
                    int want = -1; if (!string.IsNullOrEmpty(lap) && !int.TryParse(lap, out want)) { code = 400; return Err("lap must be a number"); }
                    string why; CornerLap cl = ReadBestLap(full, want, out why);
                    if (cl == null) { code = 404; return Err(why); }
                    List<CornerTurn> t = DetectLap(cl);
                    CornerSet cs = new CornerSet(); cs.Source = "auto"; cs.Basis = "telemetry"; cs.Turns = t; cs.Track = cl.Track; cs.Config = cl.Config; cs.Key = cl.Key;
                    cs.PitIn = Median(cl.PitIn); cs.PitOut = Median(cl.PitOut);
                    return SetJson(cs).TrimEnd('}') + ",\"lap\":" + cl.LapNo + ",\"lapTime\":" + D(cl.Time) + ",\"lengthM\":" + D(cl.LengthM) + ",\"file\":" + Json_.S(cl.File) + "}";
                }
                if (path == "/corners/audit")
                {
                    if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
                    return AuditJson();
                }
            }
            catch (Exception ex) { Log.W("corners: " + ex.Message); code = 500; return Err("could not do that"); }
            return null;
        }

        static string Clip(string s) { s = s ?? ""; return s.Length > 120 ? s.Substring(0, 120) : s; }

        static string SetJson(CornerSet c)
        {
            StringBuilder sb = new StringBuilder(2000);
            sb.Append("{\"source\":").Append(Json_.S(c.Source)).Append(",\"basis\":").Append(Json_.S(c.Basis))
              .Append(",\"track\":").Append(Json_.S(c.Track)).Append(",\"config\":").Append(Json_.S(c.Config)).Append(",\"key\":").Append(Json_.S(c.Key))
              .Append(",\"lovely\":").Append(Json_.S(c.LovelyFile)).Append(",\"lovelyListed\":").Append(c.LovelyListed ? "true" : "false")
              .Append(",\"pending\":").Append(c.Pending ? "true" : "false").Append(",\"updated\":").Append(Json_.S(c.Updated)).Append(",\"detail\":").Append(Json_.S(c.Detail))
              .Append(",\"turns\":[");
            for (int i = 0; i < c.Turns.Count; i++)
            {
                CornerTurn t = c.Turns[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(t.N).Append(",\"name\":").Append(Json_.S(t.Name)).Append(",\"official\":").Append(Json_.S(t.Official))
                  .Append(",\"pct0\":").Append(D(t.P0)).Append(",\"pctApex\":").Append(D(t.Pa)).Append(",\"pct1\":").Append(D(t.P1)).Append(",\"source\":").Append(Json_.S(t.Source)).Append('}');
            }
            sb.Append("],\"pitIn\":").Append(c.PitIn >= 0 ? D(c.PitIn) : "null").Append(",\"pitOut\":").Append(c.PitOut >= 0 ? D(c.PitOut) : "null")
              .Append(",\"pitSource\":").Append(Json_.S(c.PitSource)).Append(",\"sf\":0,\"sectors\":[");
            for (int i = 0; i < c.Sectors.Count; i++) { if (i > 0) sb.Append(','); sb.Append(D(c.Sectors[i])); }
            sb.Append("],\"credit\":").Append(Json_.S(c.Credit)).Append('}');
            return sb.ToString();
        }

        // ---------------- names ----------------
        static string Norm(string s)
        {
            s = (s ?? "").ToLowerInvariant().Normalize(NormalizationForm.FormD);
            StringBuilder sb = new StringBuilder();
            foreach (char c in s)
            {
                if (CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.NonSpacingMark) continue;
                sb.Append(char.IsLetterOrDigit(c) ? c : ' ');
            }
            return Regex.Replace(sb.ToString(), "\\s+", " ").Trim();
        }

        static int EditDistance(string a, string b)
        {
            if (a.Length == 0 || b.Length == 0 || Math.Abs(a.Length - b.Length) > 2) return 99;
            int[] prev = new int[b.Length + 1];
            for (int j = 0; j <= b.Length; j++) prev[j] = j;
            for (int i = 1; i <= a.Length; i++)
            {
                int[] cur = new int[b.Length + 1]; cur[0] = i;
                for (int j = 1; j <= b.Length; j++) cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
                prev = cur;
            }
            return prev[b.Length];
        }

        static readonly string[] NumberWords = { "", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve" };

        // "Turn 10A", "T3", "Turn Two", "5" are the circuit's own numbers, not names
        static string OfficialOf(string name)
        {
            Match m = Regex.Match(name, "^(?:turn|corner|t)\\s*(\\d{1,2}[a-z]?)$", RegexOptions.IgnoreCase);
            if (m.Success) return m.Groups[1].Value.ToUpperInvariant();
            m = Regex.Match(name, "^\\d{1,2}[a-z]?$", RegexOptions.IgnoreCase);
            if (m.Success) return name.ToUpperInvariant();
            m = Regex.Match(name, "^(?:turn|corner)\\s+([a-z]+)$", RegexOptions.IgnoreCase);
            if (m.Success) { int w = Array.IndexOf(NumberWords, m.Groups[1].Value.ToLowerInvariant()); if (w > 0) return w.ToString(Inv); }
            return "";
        }

        // ---------------- Lovely Track Data (local copy first) ----------------
        static List<LovelyEntry> indexCache; static DateTime indexStamp = DateTime.MinValue;

        static List<LovelyEntry> Index()
        {
            string f = Path.Combine(LovelyDir, "index.json");
            lock (gate)
            {
                DateTime m = File.Exists(f) ? File.GetLastWriteTimeUtc(f) : DateTime.MinValue;
                if (indexCache != null && m == indexStamp) return indexCache;
                List<LovelyEntry> l = new List<LovelyEntry>();
                if (m != DateTime.MinValue)
                {
                    try
                    {
                        Dictionary<string, object> doc = new JavaScriptSerializer { MaxJsonLength = 8000000 }.DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                        object[] arr = doc != null && doc.ContainsKey("tracks") ? doc["tracks"] as object[] : null;
                        if (arr != null)
                            foreach (object o in arr)
                            {
                                Dictionary<string, object> d = o as Dictionary<string, object>; if (d == null) continue;
                                LovelyEntry e = new LovelyEntry();
                                e.TrackId = Str(d, "trackId"); e.TrackName = Str(d, "trackName"); e.Path = Str(d, "path"); e.File = Str(d, "file"); e.Folder = Str(d, "folder");
                                if (e.TrackId.Length > 0 && Regex.IsMatch(e.File, "^[a-z0-9._-]{1,80}\\.json$")) l.Add(e);
                            }
                    }
                    catch (Exception ex) { Log.W("corners: lovely index: " + ex.Message); }
                }
                indexCache = l; indexStamp = m;
                return l;
            }
        }

        static string Str(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v != null ? Convert.ToString(v, Inv) : ""; }
        static double Num(Dictionary<string, object> d, string k, double dflt) { object v; double x; return d.TryGetValue(k, out v) && v != null && double.TryParse(Convert.ToString(v, Inv), NumberStyles.Float, Inv, out x) ? x : dflt; }

        // Lovely's layout id is iRacing's own TrackName ("roadatlanta full"); a few ids in the data are misspelt in the first
        // word ("navara", "outlon"), so that word may be one letter off - the rest must match exactly (1k and 2k are different tracks).
        public static LovelyEntry FindLovely(string track, string config)
        {
            List<LovelyEntry> list = Index();
            string id = Norm(track), disp = Norm(track + (config.Length > 0 ? " " + config : ""));
            if (id.Length == 0) return null;
            foreach (LovelyEntry e in list) if (Norm(e.TrackId) == id) return e;
            foreach (LovelyEntry e in list) if (Norm(e.TrackName) == disp) return e;
            string[] mine = id.Split(' ');
            if (id.Length > 5)
            {
                LovelyEntry hit = null; int bestD = 2;
                foreach (LovelyEntry e in list)
                {
                    string[] theirs = Norm(e.TrackId).Split(' ');
                    if (theirs.Length != mine.Length) continue;
                    bool restSame = true; for (int i = 1; i < mine.Length; i++) if (mine[i] != theirs[i]) restSame = false;
                    int dd = EditDistance(mine[0], theirs[0]);
                    if (restSame && dd < bestD) { bestD = dd; hit = e; }
                }
                return hit;
            }
            return null;
        }

        sealed class LovelyData { public DateTime Stamp; public CornerSet Set; }
        static readonly Dictionary<string, LovelyData> lovelyCache = new Dictionary<string, LovelyData>();

        static CornerSet LoadLovely(LovelyEntry e, out DateTime fileTime)
        {
            fileTime = DateTime.MinValue;
            string f = Path.Combine(LovelyDir, e.File);
            if (!File.Exists(f)) return null;
            fileTime = File.GetLastWriteTimeUtc(f);
            lock (gate)
            {
                LovelyData c;
                if (lovelyCache.TryGetValue(f, out c) && c.Stamp == fileTime) return c.Set;
                CornerSet cs = ParseLovely(File.ReadAllText(f, Encoding.UTF8));
                cs.LovelyFile = e.File;
                lovelyCache[f] = new LovelyData { Stamp = fileTime, Set = cs };
                return cs;
            }
        }

        // Lovely file -> turns in lap order (numbered 1..n), pit lane, sectors. Names that are only the circuit's own number
        // ("Turn 5") become Official; the lap-order number is the one used everywhere.
        public static CornerSet ParseLovely(string text)
        {
            CornerSet cs = new CornerSet(); cs.Source = "lovely"; cs.LovelyListed = true;
            Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = 8000000 }.DeserializeObject(text) as Dictionary<string, object>;
            if (d == null) return cs;
            cs.Track = Str(d, "name");
            double pi = Num(d, "pitentry", -1), po = Num(d, "pitexit", -1);
            if (pi >= 0 && pi <= 1) { cs.PitIn = pi; cs.PitSource = "lovely"; }
            if (po >= 0 && po <= 1) { cs.PitOut = po; cs.PitSource = "lovely"; }
            object[] turns = d.ContainsKey("turn") ? d["turn"] as object[] : d.ContainsKey("turns") ? d["turns"] as object[] : null;
            if (turns != null)
                foreach (object o in turns)
                {
                    Dictionary<string, object> t = o as Dictionary<string, object>; if (t == null) continue;
                    // three shapes in the data: start+end (most), start+end+marker (marker = the apex), or marker alone (a point)
                    double s = Num(t, "start", double.NaN), en = Num(t, "end", double.NaN), ap = Num(t, "apex", double.NaN), mk = Num(t, "marker", double.NaN);
                    if (double.IsNaN(ap) && !double.IsNaN(mk)) ap = mk;
                    if (double.IsNaN(s) && double.IsNaN(en) && double.IsNaN(ap)) continue;
                    if (double.IsNaN(s) && double.IsNaN(en)) { s = ap - 0.012; en = ap + 0.012; }       // a point only: a nominal stretch round it
                    if (double.IsNaN(s)) s = en; if (double.IsNaN(en)) en = s;
                    double mid = en >= s ? (s + en) / 2 : ((s + en + 1) / 2) % 1;
                    CornerTurn ct = new CornerTurn(); ct.Source = "lovely"; ct.ApexGiven = !double.IsNaN(ap);
                    ct.P0 = ((s % 1) + 1) % 1; ct.P1 = ((en % 1) + 1) % 1; ct.Pa = ((double.IsNaN(ap) ? mid : ap) % 1 + 1) % 1;
                    string name = Regex.Replace(Str(t, "name").Length > 0 ? Str(t, "name") : Str(t, "naem"), "\\s+", " ").Trim();       // one file spells it "naem"
                    ct.Official = OfficialOf(name); ct.Name = ct.Official.Length > 0 ? "" : name;
                    cs.Turns.Add(ct);
                }
            cs.Turns.Sort(delegate (CornerTurn a, CornerTurn b) { return a.Pa.CompareTo(b.Pa); });
            for (int i = 0; i < cs.Turns.Count; i++) cs.Turns[i].N = i + 1;
            object[] sec = d.ContainsKey("sector") ? d["sector"] as object[] : null;
            if (sec != null)
            {
                List<double> marks = new List<double>();
                foreach (object o in sec) { Dictionary<string, object> t = o as Dictionary<string, object>; if (t != null) { double m = Num(t, "marker", double.NaN); if (!double.IsNaN(m) && m > 0.001 && m < 0.999) marks.Add(m); } }
                marks.Sort();
                if (marks.Count > 0) { cs.Sectors.Add(0); cs.Sectors.AddRange(marks); }
            }
            return cs;
        }

        // ---------------- what we found by ourselves: data\corners\auto\<trackkey>.json ----------------
        static readonly Dictionary<string, LovelyData> autoCache = new Dictionary<string, LovelyData>();

        static CornerSet LoadAuto(string key)
        {
            if (key.Length == 0) return null;
            string f = Path.Combine(AutoDir, key + ".json");
            if (!File.Exists(f)) return null;
            DateTime m = File.GetLastWriteTimeUtc(f);
            lock (gate)
            {
                LovelyData c;
                if (autoCache.TryGetValue(f, out c) && c.Stamp == m) return c.Set;
                CornerSet cs = new CornerSet();
                try
                {
                    Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = 8000000 }.DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                    cs.Source = "auto"; cs.Basis = Str(d, "basis"); cs.Updated = Str(d, "detected"); cs.Track = Str(d, "track"); cs.Config = Str(d, "config"); cs.Key = key;
                    cs.Detail = Str(d, "detail");
                    double pi = Num(d, "pitIn", -1), po = Num(d, "pitOut", -1);
                    if (pi >= 0) { cs.PitIn = pi; cs.PitSource = "own laps"; }
                    if (po >= 0) { cs.PitOut = po; cs.PitSource = "own laps"; }
                    object[] arr = d.ContainsKey("turns") ? d["turns"] as object[] : null;
                    if (arr != null)
                        foreach (object o in arr)
                        {
                            Dictionary<string, object> t = o as Dictionary<string, object>; if (t == null) continue;
                            CornerTurn ct = new CornerTurn(); ct.Source = "auto"; ct.N = (int)Num(t, "n", cs.Turns.Count + 1);
                            ct.P0 = Num(t, "pct0", 0); ct.Pa = Num(t, "pctApex", 0); ct.P1 = Num(t, "pct1", 0);
                            cs.Turns.Add(ct);
                        }
                }
                catch (Exception ex) { Log.W("corners: auto file " + key + ": " + ex.Message); return null; }
                autoCache[f] = new LovelyData { Stamp = m, Set = cs };
                return cs;
            }
        }

        static void SaveAuto(string key, string track, string config, string basis, string detail, List<CornerTurn> turns, double pitIn, double pitOut)
        {
            Directory.CreateDirectory(AutoDir);
            StringBuilder sb = new StringBuilder(1500);
            sb.Append("{\"v\":1,\"key\":").Append(Json_.S(key)).Append(",\"track\":").Append(Json_.S(track)).Append(",\"config\":").Append(Json_.S(config))
              .Append(",\"basis\":").Append(Json_.S(basis)).Append(",\"detail\":").Append(Json_.S(detail)).Append(",\"detected\":").Append(Json_.S(DateTime.Now.ToString("s", Inv)))
              .Append(",\"pitIn\":").Append(pitIn >= 0 ? D(pitIn) : "null").Append(",\"pitOut\":").Append(pitOut >= 0 ? D(pitOut) : "null").Append(",\"turns\":[");
            for (int i = 0; i < turns.Count; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(turns[i].N).Append(",\"pct0\":").Append(D(turns[i].P0)).Append(",\"pctApex\":").Append(D(turns[i].Pa)).Append(",\"pct1\":").Append(D(turns[i].P1)).Append('}');
            }
            sb.Append("]}");
            string f = Path.Combine(AutoDir, key + ".json");
            File.WriteAllText(f + ".tmp", sb.ToString(), new UTF8Encoding(false));
            if (File.Exists(f)) File.Delete(f);
            File.Move(f + ".tmp", f);
        }

        // ---------------- putting it together ----------------
        public static CornerSet Resolve(string track, string config, string id, string key, bool kick)
        {
            CornerSet res = new CornerSet(); res.Key = key; res.Track = track; res.Config = config;
            LovelyEntry le = FindLovely(track, config);
            CornerSet lov = null; DateTime lovTime = DateTime.MinValue;
            if (le != null)
            {
                try { lov = LoadLovely(le, out lovTime); } catch (Exception ex) { Log.W("corners: lovely file " + le.File + ": " + ex.Message); }
                if (lov == null || lovTime == DateTime.MinValue) FetchLater(le);                       // not on disk yet (a track bought after the copy was made)
                else if ((DateTime.UtcNow - lovTime).TotalDays > RefreshDays) FetchLater(le);          // an old copy: look for a newer one
            }
            CornerSet auto = LoadAuto(key);
            res.LovelyListed = lov != null;
            res.LovelyFile = lov != null ? lov.LovelyFile : "";
            if (lov != null && lov.Track.Length > 0 && res.Track.Length == 0) res.Track = lov.Track;
            if (lov != null && lov.Turns.Count > 0) { res.Source = "lovely"; res.Turns = lov.Turns; res.Credit = LovelyCredit; }
            else if (auto != null && auto.Turns.Count > 0) { res.Source = "auto"; res.Basis = auto.Basis; res.Turns = auto.Turns; res.Updated = auto.Updated; res.Detail = auto.Detail; }
            LibCorners lib = LoadLibrary(track);
            if (res.Turns.Count == 0 && lib != null && lib.Turns != null && lib.Turns.Count > 0)      // from the track's shape alone (SIMRacingApps copy)
            { res.Source = "auto"; res.Basis = "outline"; res.Turns = lib.Turns; res.Detail = "the SIMRacingApps outline copy"; }
            // pit lane and sectors: Lovely when it has them, else what our own laps showed (the library's pit road is keyed over the whole lap, so it says nothing about entry and exit)
            if (lov != null && (lov.PitIn >= 0 || lov.PitOut >= 0)) { res.PitIn = lov.PitIn; res.PitOut = lov.PitOut; res.PitSource = "lovely"; if (res.Credit.Length == 0) res.Credit = LovelyCredit; }
            else if (auto != null && (auto.PitIn >= 0 || auto.PitOut >= 0)) { res.PitIn = auto.PitIn; res.PitOut = auto.PitOut; res.PitSource = "own laps"; }
            if (lov != null && lov.Sectors.Count > 1) { res.Sectors = lov.Sectors; if (res.Credit.Length == 0) res.Credit = LovelyCredit; }
            if (res.Turns.Count == 0 && key.Length > 0)
            {
                if (kick) res.Pending = Kick(key, track, config, id);
                else res.Pending = IsQueued(key);
            }
            else if (res.Source == "auto" && res.Basis == "outline" && kick) Kick(key, track, config, id);      // worked out from the outline only: look again when a newer telemetry file has a clean lap
            // Lovely gives each corner as a stretch; put the dot at the tightest point of that stretch when we hold an outline
            if (res.Source == "lovely" && (key.Length > 0 || track.Length > 0)) res.Turns = Refine(res.Turns, key, track);
            return res;
        }

        // the outline irdash drew for this track (dash\maps\<key>.json): its points are equal steps of lap distance
        static List<double[]> LoadOutline(string key)
        {
            try
            {
                if (TrackMaps.MapsDir == null) return null;
                string f = Path.Combine(TrackMaps.MapsDir, key + ".json");
                if (!File.Exists(f)) return null;
                Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = 20000000 }.DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                object[] pts = d != null && d.ContainsKey("pts") ? d["pts"] as object[] : null;
                if (pts == null || pts.Length < 200) return null;
                List<double[]> l = new List<double[]>(pts.Length);
                foreach (object o in pts)
                {
                    object[] p = o as object[]; if (p == null || p.Length < 2) return null;
                    l.Add(new double[] { Convert.ToDouble(p[0], Inv), Convert.ToDouble(p[1], Inv) });
                }
                return l;
            }
            catch { return null; }
        }

        // ---------------- SIMRacingApps outline copies: data\corners\library\<TrackName with _>.json (Apache 2.0) ----------------
        // The same files irdash's map fetches (TrackMaps.FromLibrary reads this folder first). Used here to find a track's bends
        // from geometry when no corner list exists.
        sealed class LibCorners { public DateTime Stamp; public List<double[]> Pts; public List<CornerTurn> Turns; }
        static readonly Dictionary<string, LibCorners> libCache = new Dictionary<string, LibCorners>();
        static string LibDir { get { return Path.Combine(Root, "library"); } }

        static string LibName(string track)
        {
            string n = Regex.Replace((track ?? "").Trim().ToLowerInvariant(), "\\s+", "_");
            return Regex.IsMatch(n, "^[a-z0-9_.-]{1,80}$") ? n : "";
        }

        static List<double[]> LibSection(string text, string section)
        {
            List<double[]> list = new List<double[]>();
            int s = text.IndexOf("\"" + section + "\"", StringComparison.Ordinal);
            if (s < 0) return list;
            int open = text.IndexOf('{', s);
            if (open < 0) return list;
            int depth = 0, end = open;
            for (; end < text.Length; end++) { if (text[end] == '{') depth++; else if (text[end] == '}' && --depth == 0) break; }
            foreach (Match m in Regex.Matches(text.Substring(open, end - open), "\"(-?\\d+(?:\\.\\d+)?)\"\\s*:\\s*\\{\\s*\"Latitude\"\\s*:\\s*(-?[\\d.]+)\\s*,\\s*\"Longitude\"\\s*:\\s*(-?[\\d.]+)"))
            {
                double p, la, lo;
                if (double.TryParse(m.Groups[1].Value, NumberStyles.Float, Inv, out p) && double.TryParse(m.Groups[2].Value, NumberStyles.Float, Inv, out la) &&
                    double.TryParse(m.Groups[3].Value, NumberStyles.Float, Inv, out lo) && p >= 0 && p < 100 && (la != 0 || lo != 0))
                    list.Add(new double[] { p, la, lo });
            }
            list.Sort(delegate (double[] a, double[] b) { return a[0].CompareTo(b[0]); });
            return list;
        }

        // the outline (720 points, metres: the same shape as dash\maps) and the corners found in it, or null when there is no local copy
        static LibCorners LoadLibrary(string track)
        {
            string name = LibName(track);
            if (name.Length == 0) return null;
            string f = Path.Combine(LibDir, name + ".json");
            if (!File.Exists(f)) return null;
            DateTime m = File.GetLastWriteTimeUtc(f);
            lock (gate)
            {
                LibCorners c;
                if (libCache.TryGetValue(f, out c) && c.Stamp == m) return c;
                c = new LibCorners(); c.Stamp = m;
                try
                {
                    string text = File.ReadAllText(f, Encoding.UTF8);
                    List<double[]> on = LibSection(text, "ONTRACK");
                    if (on.Count >= 150)
                    {
                        const int N = 720;
                        double[] lat = new double[N], lon = new double[N]; int j = 0;
                        for (int i = 0; i < N; i++)
                        {
                            double pct = 100.0 * i / N;
                            while (j + 1 < on.Count && on[j + 1][0] <= pct) j++;
                            double[] a = on[j], b = on[(j + 1) % on.Count];
                            double span = b[0] - a[0]; if (span <= 0) span += 100;
                            double fr = span > 0 ? (pct - a[0] + (pct < a[0] ? 100 : 0)) / span : 0; fr = Math.Max(0, Math.Min(1, fr));
                            lat[i] = a[1] + (b[1] - a[1]) * fr; lon[i] = a[2] + (b[2] - a[2]) * fr;
                        }
                        double lat0 = 0, lon0 = 0; for (int i = 0; i < N; i++) { lat0 += lat[i]; lon0 += lon[i]; }
                        lat0 /= N; lon0 /= N;
                        double kx = 111320 * Math.Cos(lat0 * Math.PI / 180), ky = 110540;
                        c.Pts = new List<double[]>(N);
                        for (int i = 0; i < N; i++) c.Pts.Add(new double[] { Math.Round((lon[i] - lon0) * kx, 1), Math.Round((lat[i] - lat0) * ky, 1) });
                        double len; const int B = 1440;
                        c.Turns = CornerDetect.FromCurvature(CornerDetect.OutlineCurvature(c.Pts, B, out len), len / B, "auto");
                    }
                }
                catch (Exception ex) { Log.W("corners: library copy " + name + ": " + ex.Message); }
                libCache[f] = c;
                return c;
            }
        }

        static List<CornerTurn> Refine(List<CornerTurn> turns, string key, string track)
        {
            List<double[]> pts = OutlinePoints(key, track);
            if (pts == null || turns.Count == 0) return turns;
            double len; const int B = 1440;
            double[] k = CornerDetect.OutlineCurvature(pts, B, out len);
            int w = Math.Max(1, (int)Math.Round(30.0 / (len / B) / 2));
            double[] s = new double[B];
            for (int i = 0; i < B; i++) { double a = 0; for (int j = -w; j <= w; j++) a += Math.Abs(k[(i + j + B) % B]); s[i] = a / (2 * w + 1); }
            List<CornerTurn> res = new List<CornerTurn>();
            foreach (CornerTurn t in turns)
            {
                CornerTurn c = new CornerTurn(); c.N = t.N; c.Name = t.Name; c.Official = t.Official; c.P0 = t.P0; c.P1 = t.P1; c.Pa = t.Pa; c.Source = t.Source; c.ApexGiven = t.ApexGiven;
                double span = t.P1 >= t.P0 ? t.P1 - t.P0 : t.P1 + 1 - t.P0;
                int n = (int)Math.Round(span * B), i0 = (int)Math.Round(t.P0 * B);
                double peak = 0; int at = -1;
                for (int j = 0; j <= n; j++) { double v = s[(i0 + j) % B]; if (v > peak) { peak = v; at = (i0 + j) % B; } }
                if (!t.ApexGiven && at >= 0 && peak > 0.0012) c.Pa = at / (double)B;             // a real bend inside the stretch; otherwise keep the middle
                res.Add(c);
            }
            return res;
        }

        // ---------------- GitHub: only to fill a gap or refresh an old copy ----------------
        static readonly HashSet<string> fetching = new HashSet<string>();

        static void FetchLater(LovelyEntry e)
        {
            if (!Regex.IsMatch(e.Path, "^iracing/[a-z0-9._-]{1,80}\\.json$")) return;
            lock (gate) { if (!fetching.Add(e.File)) return; }
            Thread t = new Thread(delegate ()
            {
                try
                {
                    for (int i = 0; i < 60 && (Program.IsDriving || Sdk.Latest.Connected); i++) Thread.Sleep(30000);      // wait for a quiet moment
                    if (Program.IsDriving || Sdk.Latest.Connected) return;
                    string text = Download(LovelyBase + e.Path);
                    if (text == null) return;
                    CornerSet cs = ParseLovely(text);                                                                        // must be a Lovely track file
                    Directory.CreateDirectory(LovelyDir);
                    string f = Path.Combine(LovelyDir, e.File), old = File.Exists(f) ? File.ReadAllText(f, Encoding.UTF8) : null;
                    if (old != text)
                    {
                        File.WriteAllText(f + ".tmp", text, new UTF8Encoding(false));
                        if (File.Exists(f)) File.Delete(f);
                        File.Move(f + ".tmp", f);
                        Log.W("corners: " + (old == null ? "fetched " : "refreshed ") + e.File + " from Lovely Track Data (" + cs.Turns.Count + " turns)");
                    }
                    else { File.SetLastWriteTimeUtc(f, DateTime.UtcNow); Log.W("corners: " + e.File + " is current"); }
                }
                catch (Exception ex) { Log.W("corners: could not fetch " + e.File + ": " + ex.Message); }
                finally { lock (gate) fetching.Remove(e.File); }
            });
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Start();
        }

        static string Download(string url)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;     // TLS 1.2
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
            rq.Timeout = 8000; rq.ReadWriteTimeout = 8000; rq.UserAgent = "Paddock-corners/1 (personal sim rig; read-only)";
            using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse())
            {
                if (rs.ContentLength > 300000) return null;
                using (StreamReader sr = new StreamReader(rs.GetResponseStream(), Encoding.UTF8)) return sr.ReadToEnd();
            }
        }

        // ---------------- reading telemetry ----------------
        sealed class IbtInfo { public string Path = "", Name = "", Id = "", TrackName = "", Display = "", Config = "", Key = ""; public long Size; public DateTime Mtime; public double LengthM; }
        static readonly Dictionary<string, IbtInfo> headers = new Dictionary<string, IbtInfo>(StringComparer.OrdinalIgnoreCase);

        // every readable telemetry file that is not being written right now, with the track it is on (the header is cheap to read)
        static List<IbtInfo> ListIbt()
        {
            List<IbtInfo> l = new List<IbtInfo>();
            string dir = TrackMaps.TelemetryDir;
            if (dir == null || !Directory.Exists(dir)) return l;
            foreach (string f in Directory.GetFiles(dir, "*.ibt"))
            {
                try
                {
                    FileInfo fi = new FileInfo(f);
                    if (Career.OnlineOnly(fi) || fi.LastWriteTime > DateTime.Now.AddMinutes(-2)) continue;       // online-only in OneDrive, or still being written
                    IbtInfo h;
                    string sig = fi.Name + "|" + fi.Length + "|" + fi.LastWriteTimeUtc.Ticks;
                    lock (gate) { if (headers.TryGetValue(sig, out h)) { l.Add(h); continue; } }
                    TrackMaps.Ibt t = TrackMaps.OpenIbt(f, false);
                    if (t == null) continue;
                    h = new IbtInfo(); h.Path = f; h.Name = fi.Name; h.Size = fi.Length; h.Mtime = fi.LastWriteTime;
                    using (t.fs)
                    {
                        h.Id = TrackMaps.YamlValue(t.yaml, "TrackID"); h.TrackName = TrackMaps.YamlValue(t.yaml, "TrackName");
                        h.Display = TrackMaps.YamlValue(t.yaml, "TrackDisplayName"); h.Config = TrackMaps.YamlValue(t.yaml, "TrackConfigName");
                        Match len = Regex.Match(TrackMaps.YamlValue(t.yaml, "TrackLength"), "^([\\d.]+)\\s*(km|mi)");
                        double L; if (len.Success && double.TryParse(len.Groups[1].Value, NumberStyles.Float, Inv, out L)) h.LengthM = L * (len.Groups[2].Value == "mi" ? 1609.344 : 1000);
                    }
                    h.Key = TrackMaps.MakeKey(h.Id, h.TrackName);
                    lock (gate) headers[sig] = h;
                    l.Add(h);
                }
                catch { }
            }
            return l;
        }

        static double AtVar(byte[] b, int o, VarDef d)
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

        // The quickest clean full lap in one file (or lap number onlyLap): no pit lane, hardly any time off the track, both line
        // crossings seen. Also collects where the car entered and left the pit lane, over the whole file.
        public static CornerLap ReadBestLap(string path, int onlyLap, out string why)
        {
            why = "";
            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
            if (t == null) { why = "not a telemetry file"; return null; }
            using (t.fs)
            {
                VarDef vSt = V(t, "SessionTime"), vPct = V(t, "LapDistPct"), vLap = V(t, "Lap"), vOn = V(t, "IsOnTrack"), vPit = V(t, "OnPitRoad"), vSurf = V(t, "PlayerTrackSurface"),
                       vSpd = V(t, "Speed"), vYaw = V(t, "YawRate"), vLat = V(t, "LatAccel"), vLlt = V(t, "LapLastLapTime");
                if (vSt == null || vPct == null || vLap == null || vOn == null || vSpd == null || (vYaw == null && vLat == null)) { why = "this file has no lap or yaw data"; return null; }
                int n = (int)Math.Min(t.records, 2000000L);
                double[] st = new double[n]; float[] pct = new float[n], spd = new float[n], yaw = new float[n], lat = new float[n], llt = new float[n]; int[] lap = new int[n]; byte[] fl = new byte[n];
                int per = Math.Max(1, (4 << 20) / t.bufLen); byte[] buf = new byte[per * t.bufLen];
                t.fs.Position = t.dataOff;
                int i = 0;
                while (i < n)
                {
                    int want = Math.Min(per, n - i), got = 0;
                    while (got < want * t.bufLen) { int r = t.fs.Read(buf, got, want * t.bufLen - got); if (r <= 0) break; got += r; }
                    int recs = got / t.bufLen; if (recs == 0) break;
                    for (int k = 0; k < recs; k++, i++)
                    {
                        int o = k * t.bufLen;
                        st[i] = AtVar(buf, o, vSt); pct[i] = (float)AtVar(buf, o, vPct); lap[i] = (int)AtVar(buf, o, vLap); spd[i] = (float)AtVar(buf, o, vSpd);
                        yaw[i] = (float)AtVar(buf, o, vYaw); lat[i] = (float)AtVar(buf, o, vLat); llt[i] = (float)AtVar(buf, o, vLlt);
                        // 1 on track, 2 pit lane, 4 off the racing surface (PlayerTrackSurface 3 = on track)
                        fl[i] = (byte)((AtVar(buf, o, vOn) != 0 ? 1 : 0) | (vPit != null && AtVar(buf, o, vPit) != 0 ? 2 : 0) | (vSurf != null && AtVar(buf, o, vSurf) < 3 ? 4 : 0));
                    }
                    if (recs < want) break;
                }
                n = i;
                CornerLap cl = new CornerLap(); cl.File = Path.GetFileName(path);
                cl.Track = TrackMaps.YamlValue(t.yaml, "TrackDisplayName"); cl.Config = TrackMaps.YamlValue(t.yaml, "TrackConfigName"); cl.TrackId = TrackMaps.YamlValue(t.yaml, "TrackID"); cl.TrackName = TrackMaps.YamlValue(t.yaml, "TrackName");
                cl.Key = TrackMaps.MakeKey(cl.TrackId, cl.TrackName);
                Match len = Regex.Match(TrackMaps.YamlValue(t.yaml, "TrackLength"), "^([\\d.]+)\\s*(km|mi)");
                double L; if (len.Success && double.TryParse(len.Groups[1].Value, NumberStyles.Float, Inv, out L)) cl.LengthM = L * (len.Groups[2].Value == "mi" ? 1609.344 : 1000);
                if (cl.LengthM < 200) { why = "the file does not say how long the track is"; return null; }

                // pit lane entries and exits over the whole file
                for (int k = 1; k < n; k++)
                {
                    if (st[k] - st[k - 1] > 0.5 || (fl[k] & 1) == 0) continue;
                    bool a = (fl[k - 1] & 2) != 0, b = (fl[k] & 2) != 0;
                    if (!a && b && pct[k] > 0.5) cl.PitIn.Add(pct[k]);
                    else if (a && !b) cl.PitOut.Add(pct[k]);
                }
                // runs of one lap counter on track; a run is a full lap when the line was crossed cleanly at both ends
                List<int[]> runs = new List<int[]>();
                for (int k = 0; k < n;)
                {
                    if ((fl[k] & 1) == 0) { k++; continue; }
                    int j = k + 1;
                    while (j < n && (fl[j] & 1) != 0 && lap[j] == lap[k] && st[j] - st[j - 1] < 0.5) j++;
                    runs.Add(new int[] { k, j }); k = j;
                }
                int bestRun = -1, fullLaps = 0, pitLaps = 0, offLaps = 0; double bestTime = 0;
                for (int r = 1; r + 1 < runs.Count; r++)
                {
                    int a = runs[r][0], b = runs[r][1];
                    bool pre = runs[r - 1][1] == a && lap[a - 1] == lap[a] - 1 && pct[a - 1] > 0.8 && pct[a] < 0.2;
                    bool post = runs[r + 1][0] == b && lap[b] == lap[a] + 1 && pct[b - 1] > 0.8 && pct[b] < 0.2;
                    if (!pre || !post) continue;
                    fullLaps++;
                    if (onlyLap >= 0 && lap[a] != onlyLap) continue;
                    int pit = 0, off = 0; for (int x = a; x < b; x++) { if ((fl[x] & 2) != 0) pit++; if ((fl[x] & 4) != 0) off++; }
                    if (onlyLap < 0 && (pit > 0 || off > 40)) { if (pit > 0) pitLaps++; else offLaps++; continue; }
                    double t0 = Cross(st, pct, a), t1 = Cross(st, pct, b), time = t1 - t0;
                    int at = Math.Min(b + 90, runs[r + 1][1] - 1);
                    if (at >= 0 && at < n && llt[at] > 1 && Math.Abs(llt[at] - time) < 0.15) time = llt[at];
                    if (time < 15 || time > 900) continue;
                    if (bestRun < 0 || time < bestTime) { bestRun = r; bestTime = time; }
                }
                if (bestRun < 0) { why = onlyLap >= 0 ? "no such full lap in this file" : "no clean full lap in this file (" + runs.Count + " runs, " + fullLaps + " full laps, " + pitLaps + " through the pits, " + offLaps + " off the track)"; return null; }
                int s0 = runs[bestRun][0], s1 = runs[bestRun][1], m = s1 - s0;
                cl.LapNo = lap[s0]; cl.Time = bestTime; cl.Pct = new float[m]; cl.Spd = new float[m]; cl.Yaw = vYaw != null ? new float[m] : null; cl.LatA = vLat != null ? new float[m] : null;
                for (int x = 0; x < m; x++) { cl.Pct[x] = pct[s0 + x]; cl.Spd[x] = spd[s0 + x]; if (cl.Yaw != null) cl.Yaw[x] = yaw[s0 + x]; if (cl.LatA != null) cl.LatA[x] = lat[s0 + x]; }
                return cl;
            }
        }

        static VarDef V(TrackMaps.Ibt t, string name) { VarDef d; return t.vars.TryGetValue(name, out d) ? d : null; }

        static double Cross(double[] st, float[] pct, int k)
        {
            double p0 = pct[k - 1], p1 = pct[k], span = (1 - p0) + p1, f = span > 1e-6 ? (1 - p0) / span : 1;
            return st[k - 1] + (st[k] - st[k - 1]) * Math.Max(0, Math.Min(1, f));
        }

        // corners found in the local SIMRacingApps outline copy of a track (null when there is none)
        public static List<CornerTurn> DetectLibrary(string track) { LibCorners l = LoadLibrary(track); return l != null ? l.Turns : null; }

        // the outline irdash holds for a track (dash\maps\<key>.json), else the local SIMRacingApps copy
        static List<double[]> OutlinePoints(string key, string track)
        {
            List<double[]> pts = key.Length > 0 ? LoadOutline(key) : null;
            if (pts != null) return pts;
            LibCorners lc = LoadLibrary(track);
            return lc != null ? lc.Pts : null;
        }

        // corners found in the outline irdash holds for a track (null when there is none)
        public static List<CornerTurn> DetectOutline(string key, string track)
        {
            List<double[]> pts = OutlinePoints(key, track);
            if (pts == null) return null;
            double len; const int B = 1440;
            return CornerDetect.FromCurvature(CornerDetect.OutlineCurvature(pts, B, out len), len / B, "auto");
        }

        public static List<CornerTurn> DetectLap(CornerLap lap)
        {
            const int bins = 2000;
            return CornerDetect.FromCurvature(CornerDetect.LapCurvature(lap, bins), lap.LengthM / bins, "auto");
        }

        // circular median of lap fractions (pit entry sits near 0.95, exit near 0.05: they may straddle the line)
        static double Median(List<double> v)
        {
            if (v.Count == 0) return -1;
            List<double> x = new List<double>(); double r = v[0];
            foreach (double p in v) { double d = p - r; if (d > 0.5) d -= 1; if (d < -0.5) d += 1; x.Add(r + d); }
            x.Sort();
            double m = x.Count % 2 == 1 ? x[x.Count / 2] : (x[x.Count / 2 - 1] + x[x.Count / 2]) / 2;
            return ((m % 1) + 1) % 1;
        }

        // ---------------- finding the corners of a track he has driven (background, never while he drives) ----------------
        static readonly Dictionary<string, DateTime> lastTry = new Dictionary<string, DateTime>();
        static readonly Queue<string[]> todo = new Queue<string[]>();
        static readonly HashSet<string> queued = new HashSet<string>();
        static Thread worker;

        static bool IsQueued(string key) { lock (gate) return queued.Contains(key); }

        // Called when someone asks for a track that has no corner list. Returns true when a search is queued or running.
        static bool Kick(string key, string track, string config, string id)
        {
            lock (gate)
            {
                if (queued.Contains(key)) return true;
                DateTime t;
                if (lastTry.TryGetValue(key, out t) && (DateTime.Now - t).TotalMinutes < 15) return false;      // tried a moment ago and found nothing
                queued.Add(key); todo.Enqueue(new string[] { key, track, config, id });
                if (worker == null || !worker.IsAlive)
                {
                    worker = new Thread(Work); worker.IsBackground = true; worker.Priority = ThreadPriority.BelowNormal; worker.Start();
                }
                return true;
            }
        }

        static void Work()
        {
            while (true)
            {
                string[] job;
                lock (gate) { if (todo.Count == 0) { worker = null; return; } job = todo.Peek(); }
                if (Program.IsDriving || Sdk.Latest.Connected) { Thread.Sleep(20000); continue; }       // reading telemetry waits until the sim is closed
                string why = "";
                try { BuildAuto(job[0], job[1], job[2], out why); }
                catch (Exception ex) { why = "failed: " + ex.Message; }
                if (!why.StartsWith("already") && !why.StartsWith("corners from the outline are in place")) Log.W("corners: " + job[0] + " - " + why);      // not a line every 15 minutes for nothing
                lock (gate) { todo.Dequeue(); queued.Remove(job[0]); lastTry[job[0]] = DateTime.Now; }
            }
        }

        // Finds corners for one track key and stores them. True when a corner list was written.
        static bool BuildAuto(string key, string track, string config, out string why)
        {
            List<IbtInfo> mine = new List<IbtInfo>();
            foreach (IbtInfo h in ListIbt()) if (h.Key == key) mine.Add(h);
            CornerSet have = LoadAuto(key);
            if (have != null && have.Turns.Count > 0)
            {
                if (have.Basis != "outline") { why = "already found"; return false; }
                DateTime made = File.GetLastWriteTime(Path.Combine(AutoDir, key + ".json")); bool newer = false;
                foreach (IbtInfo h in mine) if (h.Mtime > made) newer = true;
                if (!newer) { why = "corners from the outline are in place; no newer telemetry to improve them"; return false; }
            }
            // the files with the quickest known laps first (the career cache has each file's best), then the biggest files
            Dictionary<string, double> best = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (mine.Count > 0)
                    foreach (string[] cb in Career.Combos())
                        if (cb[1] == mine[0].Display && cb[2] == mine[0].Config)
                            foreach (BestRow r in Career.BestFiles(cb[0], cb[1], cb[2])) best[r.File] = r.Best;
            }
            catch { }
            mine.Sort(delegate (IbtInfo a, IbtInfo b)
            {
                double ta, tb; bool ha = best.TryGetValue(a.Name, out ta), hb = best.TryGetValue(b.Name, out tb);
                if (ha && hb) return ta.CompareTo(tb);
                if (ha != hb) return ha ? -1 : 1;
                return b.Size.CompareTo(a.Size);
            });
            CornerLap pick = null; List<double> pitIn = new List<double>(), pitOut = new List<double>(); int read = 0; string lastWhy = "no telemetry files for this track yet";
            foreach (IbtInfo h in mine)
            {
                if (read >= 4) break;
                read++;
                CornerLap cl = ReadBestLap(h.Path, -1, out lastWhy);
                if (cl == null) continue;
                pitIn.AddRange(cl.PitIn); pitOut.AddRange(cl.PitOut);
                if (pick == null || cl.Time < pick.Time) pick = cl;
            }
            string tn = mine.Count > 0 ? mine[0].Display : track, cf = mine.Count > 0 ? mine[0].Config : config;
            if (pick != null)
            {
                List<CornerTurn> turns = DetectLap(pick);
                if (turns.Count >= 2)
                {
                    SaveAuto(key, tn, cf, "telemetry", "lap " + pick.LapNo + " (" + pick.Time.ToString("0.000", Inv) + " s) in " + pick.File, turns, Median(pitIn), Median(pitOut));
                    why = turns.Count + " corners from the best clean lap (" + pick.Time.ToString("0.000", Inv) + " s, " + pick.File + ")";
                    return true;
                }
                lastWhy = "only " + turns.Count + " corners found in the best lap";
            }
            // no clean lap anywhere: use the outline built from his own laps (or the library one irdash already holds)
            {
                List<CornerTurn> turns = DetectOutline(key, track);
                if (turns != null && turns.Count >= 2)
                {
                    SaveAuto(key, tn, cf, "outline", LoadOutline(key) != null ? "the track outline irdash holds" : "the SIMRacingApps outline copy", turns, Median(pitIn), Median(pitOut));
                    why = turns.Count + " corners from the track outline (" + lastWhy + ")";
                    return true;
                }
            }
            why = "nothing yet: " + lastWhy;
            return false;
        }

        // ---------------- coverage list for docs\corners.md (data\corners\audit.ps1 turns it into the table) ----------------
        static string AuditJson()
        {
            string tracks = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"iRacing\tracks");
            StringBuilder sb = new StringBuilder(30000);
            sb.Append("{\"tracksDir\":").Append(Json_.S(tracks)).Append(",\"layouts\":[");
            List<IbtInfo> files = ListIbt();
            Dictionary<string, int> driven = new Dictionary<string, int>(), drivenLaps = new Dictionary<string, int>();
            Dictionary<string, IbtInfo> drivenInfo = new Dictionary<string, IbtInfo>();
            foreach (IbtInfo h in files) { string k = Norm(h.TrackName); int c; driven.TryGetValue(k, out c); driven[k] = c + 1; drivenInfo[k] = h; }
            HashSet<string> seen = new HashSet<string>();
            bool first = true;
            if (Directory.Exists(tracks))
                foreach (string dir in Directory.GetDirectories(tracks))
                {
                    string folder = Path.GetFileName(dir).ToLowerInvariant();
                    List<string> leaves = new List<string>(), parents = new List<string>();
                    FindLayouts(dir, "", leaves, parents);
                    if (leaves.Count == 0 && parents.Count == 0) leaves.Add("");
                    else if (FindLovely(folder, "") != null || driven.ContainsKey(Norm(folder)) || LoadLibrary(folder) != null) leaves.Add("");      // the folder's own (main) layout, e.g. "lagunaseca"
                    foreach (string pr in parents) { string pid = (folder + " " + pr.Replace('\\', ' ')).Trim(); if (FindLovely(pid, "") != null || driven.ContainsKey(Norm(pid))) leaves.Add(pr); }
                    foreach (string rel in leaves)
                    {
                        string id = (folder + " " + rel.Replace('\\', ' ')).Trim();
                        seen.Add(Norm(id));
                        if (!first) sb.Append(','); first = false;
                        AuditRow(sb, folder, rel, id, true, driven, drivenInfo);
                    }
                }
            // layouts he has driven that are not in the folder listing (renamed folders, other content)
            foreach (KeyValuePair<string, IbtInfo> kv in drivenInfo)
            {
                if (seen.Contains(kv.Key)) continue;
                if (!first) sb.Append(','); first = false;
                AuditRow(sb, kv.Value.TrackName.Split(' ')[0], "", kv.Value.TrackName, false, driven, drivenInfo);
            }
            sb.Append("]}");
            return sb.ToString();
        }

        // folders under a track's folder that hold their own .dat: the layouts. A folder with layouts inside it is a layout itself
        // only when something knows it by that name (Lovely's "summit summit raceway" is a folder that also holds "school").
        static void FindLayouts(string dir, string rel, List<string> leaves, List<string> parents)
        {
            bool hasChild = false;
            foreach (string sub in Directory.GetDirectories(dir))
            {
                string name = Path.GetFileName(sub);
                if (!File.Exists(Path.Combine(sub, name + ".dat")) && Directory.GetDirectories(sub).Length == 0) continue;
                int c0 = leaves.Count;
                FindLayouts(sub, rel.Length == 0 ? name : rel + "\\" + name, leaves, parents);
                if (leaves.Count > c0) hasChild = true;
            }
            bool own = rel.Length > 0 && File.Exists(Path.Combine(dir, Path.GetFileName(dir) + ".dat"));
            if (own && !hasChild) leaves.Add(rel); else if (own) parents.Add(rel);
        }
        static void AuditRow(StringBuilder sb, string folder, string rel, string id, bool installed, Dictionary<string, int> driven, Dictionary<string, IbtInfo> info)
        {
            LovelyEntry le = FindLovely(id, "");
            int lturns = 0; string lfile = "";
            if (le != null)
            {
                lfile = le.File;
                try { DateTime ft; CornerSet cs = LoadLovely(le, out ft); lturns = cs != null ? cs.Turns.Count : -1; } catch { lturns = -1; }
            }
            string nid = Norm(id); IbtInfo h; int nfiles; bool isDriven = driven.TryGetValue(nid, out nfiles) && info.TryGetValue(nid, out h);
            h = isDriven ? info[nid] : null;
            string key = h != null ? h.Key : "";
            CornerSet auto = key.Length > 0 ? LoadAuto(key) : null;
            LibCorners lib = LoadLibrary(id);
            sb.Append("{\"library\":").Append(lib != null ? "true" : "false").Append(",\"libTurns\":").Append(lib != null && lib.Turns != null ? lib.Turns.Count : 0).Append(",\"folder\":").Append(Json_.S(folder)).Append(",\"installed\":").Append(installed ? "true" : "false").Append(",\"layout\":").Append(Json_.S(rel.Replace('\\', '/'))).Append(",\"id\":").Append(Json_.S(id))
              .Append(",\"lovelyFile\":").Append(Json_.S(lfile)).Append(",\"lovelyName\":").Append(Json_.S(le != null ? le.TrackName : "")).Append(",\"lovelyTurns\":").Append(lturns)
              .Append(",\"driven\":").Append(isDriven ? nfiles : 0).Append(",\"display\":").Append(Json_.S(h != null ? h.Display : "")).Append(",\"config\":").Append(Json_.S(h != null ? h.Config : ""))
              .Append(",\"key\":").Append(Json_.S(key)).Append(",\"autoTurns\":").Append(auto != null ? auto.Turns.Count : 0).Append(",\"autoBasis\":").Append(Json_.S(auto != null ? auto.Basis : "")).Append('}');
        }
    }
}
