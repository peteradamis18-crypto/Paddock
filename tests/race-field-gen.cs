// The pretend race of tests\race-field-test.ps1 (card W6). It is the TRUTH: every car is driven by a small simulation (Euler steps of 2 ms) and every
// number the test expects (line crossings, lap times, corner times, pit, off-track, passes, positions) is read back from those steps, not from irdash.
// Compile with:  Add-Type -Path tests\race-field-gen.cs -ReferencedAssemblies System.Web.Extensions   (C# 5)
//   20 cars, two classes (idx 0-11 class 4001, idx 12-19 class 4002 which is much slower and gets lapped), Peter = idx 7, a standing start (cars staggered
//   behind the line), a 6 lap race. Scenes: Peter passes car 6 (and others), car 5 passes him again, car 9 makes a pit stop (in lap 4, out lap 5, 6 s in the stall), car 16 flickers pit road for 1.6 s at the entry (no stop),
//   car 3 goes off track in lap 3, car 14 retires in lap 3 (disappears from the world), cars 4 / 10 report the lap counter one sample late / early, cars 11 / 3
//   report LastLapTime one sample late / early, five cars (2 6 9 15 18) have no LastLapTime at all (the sampler must derive the lap times).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Web.Script.Serialization;

public sealed class RgCar
{
    public int Idx, Cls, LcShift, SimShift; public bool Sim;
    public double[] LapK = new double[40];
    public double[] S; public byte[] Pit; public sbyte[] Surf;
    public int RetireStep = -1; public double RetireT = double.NaN;
    public List<double> X = new List<double>();      // X[k] = the time the car reached k laps of distance (X[0] = the start line, X[1] = the end of lap 1 ...)
    public int KEnd = -1; public double TEnd = double.NaN;
    public bool Finished(double t) { return KEnd > 0 && X[KEnd] <= t; }
}

public static class RaceGen
{
    public static double L = 4056.9, T0 = 10.0, Tg = 18.0, Dt = 0.002, TF, TStop = 400.0, TLast;
    public static int Steps, Laps = 6, NC;
    public static double[] CP0, CP1, Bounds, Depth;
    public static RgCar[] Cars;
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    public static readonly int[] NoSim = { 2, 6, 9, 15, 18 };

    static double V(double pct)
    {
        double v = 104.0;
        for (int k = 0; k < NC; k++)
        {
            double a = CP0[k], b = CP1[k] <= a ? 1.0 : CP1[k];
            if (pct >= a && pct <= b) { double u = Math.Sin(Math.PI * (pct - a) / (b - a)); v -= Depth[k] * u * u; break; }
        }
        return v;
    }

    // p0 / p1: the corner list the workbench holds for the track (the test reads it from /corners)
    public static void Init(double[] p0, double[] p1, double length)
    {
        L = length; CP0 = p0; CP1 = p1; NC = p0.Length;
        Bounds = new double[2 * NC]; Depth = new double[NC];
        for (int k = 0; k < NC; k++)
        {
            Bounds[2 * k] = p0[k] - Math.Floor(p0[k]); double b = p1[k] - Math.Floor(p1[k]); Bounds[2 * k + 1] = b >= 1 ? 0 : b;
            Depth[k] = 16 + 24 * (((k * 5) % 7) / 6.0);
        }
        Steps = (int)((TStop - T0) / Dt) + 1;
        Cars = new RgCar[20];
        for (int i = 0; i < 20; i++)
        {
            RgCar c = new RgCar(); c.Idx = i; c.Cls = i < 12 ? 4001 : 4002;
            double bs = i < 12 ? 1.020 - 0.003 * i : 0.800 - 0.002 * (i - 12);
            for (int lap = 1; lap < 40; lap++)
            {
                double noise = (((i * 131 + lap * 977) % 97) / 97.0 - 0.5) * 0.003;
                double k = bs;
                if (i == 7) k = lap == 1 ? 0.999 : lap <= 4 ? 1.016 : 0.985;
                if (i == 8 && lap >= 5) k = 1.025;
                c.LapK[lap] = k * (1 + noise);
            }
            c.Sim = Array.IndexOf(NoSim, i) < 0;
            c.LcShift = i == 4 ? -1 : i == 10 ? 1 : 0; c.SimShift = i == 11 ? -1 : i == 3 ? 1 : 0;
            c.S = new double[Steps]; c.Pit = new byte[Steps]; c.Surf = new sbyte[Steps];
            Simulate(c);
            Cars[i] = c;
        }
        // crossings
        foreach (RgCar c in Cars)
        {
            int idx = 0;
            for (int k = 0; ; k++)
            {
                double target = k * L;
                while (idx < Steps && c.S[idx] < target) idx++;
                if (idx >= Steps || idx == 0) break;
                double a = c.S[idx - 1], b = c.S[idx]; double f = b > a ? (target - a) / (b - a) : 0;
                c.X.Add(T0 + (idx - 1 + f) * Dt);
            }
        }
        TF = 1e18; foreach (RgCar c in Cars) if (c.X.Count > Laps && c.X[Laps] < TF) TF = c.X[Laps];
        TLast = 0;
        foreach (RgCar c in Cars)
        {
            for (int k = 1; k < c.X.Count; k++) if (c.X[k] >= TF - 1e-9) { c.KEnd = k; c.TEnd = c.X[k]; break; }
            if (c.KEnd > 0 && c.TEnd > TLast) TLast = c.TEnd;
        }
    }

    static void Simulate(RgCar c)
    {
        double g = 6 + 7 * c.Idx, s = -g; bool retired = false; int pitState = 0; double stallLeft = 0;
        for (int i = 0; i < Steps; i++)
        {
            double t = T0 + i * Dt; byte pit = 0; sbyte surf = 3;
            if (retired) { c.S[i] = s; c.Pit[i] = 0; c.Surf[i] = -1; continue; }
            c.S[i] = s;
            double v;
            if (t < Tg) v = 0;
            else
            {
                // one rule from the green flag on: the profile speed, but never faster than 6 m/s^2 of launch (so the speed has no jump at the line)
                double pct = (s / L) - Math.Floor(s / L); int lap = s < 0 ? 1 : (int)Math.Floor(s / L) + 1;
                v = Math.Min(V(pct) * c.LapK[Math.Min(lap, 39)], 6.0 * (t - Tg));
                if (s < 0) { v = Math.Min(v, 6.0 * (t - Tg)); }
                if (c.Idx == 9)
                {
                    if (pitState == 0 && lap == 4 && pct >= 0.94) pitState = 1;
                    if (pitState == 1 && lap == 5 && pct >= 0.03) { pitState = 2; stallLeft = 6.0; }
                    if (pitState == 2 && stallLeft <= 0) pitState = 3;
                    if (pitState == 3 && lap == 5 && pct >= 0.14) pitState = 4;
                    if (pitState == 1 || pitState == 3) { v = 20; pit = 1; surf = 2; }
                    else if (pitState == 2) { v = 0; pit = 1; surf = 1; stallLeft -= Dt; }
                }
                if (c.Idx == 3 && lap == 3 && pct >= 0.40 && pct < 0.40 + 80.0 / L) { surf = 0; v *= 0.55; }
                if (c.Idx == 16 && lap == 3 && pct >= 0.90 && pct < 0.90 + 150.0 / L) { pit = 1; surf = 2; }       // pit road flickers on for 1.6 s while the car races past the entry: not a stop
                if (c.Idx == 14 && lap == 3 && pct >= 0.60) { retired = true; c.RetireStep = i; c.RetireT = t; c.Pit[i] = 0; c.Surf[i] = -1; continue; }
            }
            c.Pit[i] = pit; c.Surf[i] = surf;
            s += v * Dt;
        }
    }

    // ---------------- frames: the query string for the test hook, only the keys that changed ----------------
    static readonly Dictionary<string, string> prev = new Dictionary<string, string>();
    public static void ResetFrames() { prev.Clear(); }
    public static double TimeOf(int j) { return T0 + 0.1 * j; }
    public static int LastFrame() { return (int)Math.Floor((Math.Min(TStop - 1, TLast + 62) - T0) / 0.1); }

    static int CountX(RgCar c, double t) { int n = 0; for (int k = 1; k < c.X.Count; k++) if (c.X[k] <= t) n++; return n; }
    static double SimLap(RgCar c, int k) { return k == 1 ? c.X[1] - Tg : c.X[k] - c.X[k - 1]; }

    static void Rank(double t, int i, out int[] pos, out int[] cpos)
    {
        double[] key = new double[20];
        for (int q = 0; q < 20; q++)
        {
            RgCar c = Cars[q];
            if (c.Finished(t)) key[q] = c.KEnd * L - c.X[c.KEnd] * 1e-6; else key[q] = c.S[i];
        }
        pos = new int[20]; cpos = new int[20];
        for (int q = 0; q < 20; q++)
        {
            int p = 1, cp = 1;
            for (int o = 0; o < 20; o++) if (o != q && key[o] > key[q]) { p++; if (Cars[o].Cls == Cars[q].Cls) cp++; }
            pos[q] = p; cpos[q] = cp;
        }
    }

    // the frame for sample j (time T0 + 0.1 j); the query goes to /api/test/frame
    public static string Frame(int j)
    {
        double t = TimeOf(j); int i = j * 50; StringBuilder sb = new StringBuilder(2048);
        Action<string, string> put = delegate (string k, string v) { string o; if (!prev.TryGetValue(k, out o) || o != v) { prev[k] = v; if (sb.Length > 0) sb.Append('&'); sb.Append(k).Append('=').Append(v); } };
        put("SessionTime", t.ToString("0.0000", Inv)); put("SessionNum", "2");
        put("SessionState", t < Tg ? "3" : t < TF + 0.1 - 1e-9 ? "4" : "5");
        int[] pos, cpos; Rank(t, i, out pos, out cpos);
        foreach (RgCar c in Cars)
        {
            string n = c.Idx.ToString(Inv);
            bool gone = c.Surf[i] == -1; double s = c.S[i];
            double pct = gone ? -1 : (s < 0 ? 1 + s / L : s / L - Math.Floor(s / L));
            put("CarIdxLapDistPct_" + n, pct.ToString("0.0000000", Inv));
            int lc = CountX(c, t - c.LcShift * 0.1 * -1); // -1 shift = late (count what was true 0.1 s ago), +1 = early
            put("CarIdxLapCompleted_" + n, lc.ToString(Inv)); put("CarIdxLap_" + n, (lc + 1).ToString(Inv));
            put("CarIdxPosition_" + n, pos[c.Idx].ToString(Inv)); put("CarIdxClassPosition_" + n, cpos[c.Idx].ToString(Inv));
            put("CarIdxOnPitRoad_" + n, c.Pit[i].ToString(Inv)); put("CarIdxTrackSurface_" + n, c.Surf[i].ToString(Inv));
            string last = "-1";
            if (c.Sim) { int ks = CountX(c, t - c.SimShift * 0.1 * -1); if (ks >= 1) last = SimLap(c, ks).ToString("0.00000", Inv); }
            put("CarIdxLastLapTime_" + n, last);
            string bestS = "-1";
            if (c.Sim) { int kb = CountX(c, t - c.SimShift * 0.1 * -1); double bb = 1e18; for (int k = 1; k <= kb; k++) bb = Math.Min(bb, SimLap(c, k)); if (kb >= 1) bestS = bb.ToString("0.00000", Inv); }
            put("CarIdxBestLapTime_" + n, bestS);
        }
        return sb.ToString();
    }

    // ================= truth read-outs for the test =================
    public static double[] Xs(int idx) { return Cars[idx].X.ToArray(); }
    public static int Completed(int idx) { RgCar c = Cars[idx]; if (c.KEnd > 0) return c.KEnd; int n = 0; for (int k = 1; k < c.X.Count; k++) if (double.IsNaN(c.RetireT) || c.X[k] <= c.RetireT) n++; return n; }
    public static double LapSim(int idx, int k) { return SimLap(Cars[idx], k); }
    // the sim's own fastest lap of a car as the results text would give it: { time, lap number }, over every lap it completed (lap 1 counts from the green flag)
    public static double[] BestSim(int idx)
    {
        double best = 1e18; int bl = 0; int n = Completed(idx);
        for (int k = 1; k <= n; k++) { double t = SimLap(Cars[idx], k); if (t < best) { best = t; bl = k; } }
        return new double[] { best, bl };
    }
    public static int ClassOf(int idx) { return Cars[idx].Cls; }
    public static bool HasSim(int idx) { return Cars[idx].Sim; }

    // time the car reached distance s (m); NaN when it never did
    static double TimeAtS(RgCar c, double target)
    {
        int lo = 0, hi = Steps - 1;
        if (c.S[hi] < target || c.S[0] > target) return double.NaN;
        while (lo + 1 < hi) { int m = (lo + hi) >> 1; if (c.S[m] < target) lo = m; else hi = m; }
        double a = c.S[lo], b = c.S[hi]; double f = b > a ? (target - a) / (b - a) : 0;
        return T0 + (lo + f) * Dt;
    }
    // where the corner boundary kb is for lap n, relative to the lap's start (ms, rounded like the sampler stores it)
    public static double BoundaryRel(int idx, int n, int kb)
    {
        RgCar c = Cars[idx]; double t = TimeAtS(c, (n - 1) * L + Bounds[kb] * L);
        return double.IsNaN(t) ? double.NaN : (t - c.X[n - 1]) * 1000.0;
    }
    public static int NCorners() { return NC; }

    // "" when the scene is clean: nobody crosses the line in the 0.8 s before the leader's flag (the sampler's 0.25 s rule could not tell), no pass happens around the flag
    public static string Sanity()
    {
        foreach (RgCar c in Cars) for (int k = 1; k < c.X.Count; k++) if (c.X[k] > TF - 0.8 && c.X[k] < TF - 1e-9) return "car " + c.Idx + " crosses " + (TF - c.X[k]).ToString("0.00", Inv) + " s before the flag";
        foreach (Pass p in TruthPasses()) if (p.T > TF - 0.5 && p.T < TF + 0.6) return "a pass at " + p.T.ToString("0.00", Inv) + " is too close to the flag";
        int n = 0; foreach (RgCar c in Cars) if (c.KEnd > 0) n++;
        return n == 19 ? "" : "expected 19 finishers, found " + n;
    }

    // the pit stop and the off-track truth (read from the steps)
    public static double[] PitTruth(int idx)      // inTime, outTime, stallSeconds, inLap, outLap  (NaN when no stop)
    {
        RgCar c = Cars[idx]; double ti = double.NaN, to = double.NaN, stall = 0; int il = 0, ol = 0;
        for (int i = 0; i < Steps; i++)
        {
            double t = T0 + i * Dt;
            if (c.Pit[i] != 0 && double.IsNaN(ti)) { ti = t; il = (int)Math.Floor(c.S[i] / L) + 1; }
            if (c.Pit[i] == 0 && !double.IsNaN(ti) && double.IsNaN(to)) { to = t; ol = (int)Math.Floor(c.S[i] / L) + 1; }
            if (c.Surf[i] == 1) stall += Dt;
        }
        return new double[] { ti, to, stall, il, ol };
    }
    public static double[] OffTruth(int idx)      // number of excursions, seconds off, first lap
    {
        RgCar c = Cars[idx]; int n = 0; double secs = 0; int lap = 0; bool was = false;
        for (int i = 0; i < Steps; i++)
        {
            bool off = c.Surf[i] == 0; if (off) secs += Dt;
            if (off && !was) { n++; if (lap == 0) lap = (int)Math.Floor(c.S[i] / L) + 1; }
            was = off;
        }
        return new double[] { n, secs, lap };
    }

    // on-track passes between cars of one class while both are racing: the zero crossings of the distance difference
    public sealed class Pass { public int By, Over, Lap; public double T, Pct; }
    public static List<Pass> TruthPasses()
    {
        List<Pass> l = new List<Pass>();
        int i0 = (int)((Tg - T0) / Dt) + 1, i1 = (int)((TF + 0.1 - T0) / Dt);
        for (int a = 0; a < 20; a++)
            for (int b = a + 1; b < 20; b++)
            {
                RgCar ca = Cars[a], cb = Cars[b]; if (ca.Cls != cb.Cls) continue;
                for (int i = i0; i < i1 && i < Steps; i++)
                {
                    double t = T0 + i * Dt, tp = t - Dt;
                    if (ca.Finished(t) || cb.Finished(t) || ca.Pit[i] != 0 || cb.Pit[i] != 0 || ca.Pit[i - 1] != 0 || cb.Pit[i - 1] != 0 || ca.Surf[i] == -1 || cb.Surf[i] == -1) continue;
                    double d0 = ca.S[i - 1] - cb.S[i - 1], d1 = ca.S[i] - cb.S[i];
                    if (d0 == 0 || d1 == 0 || (d0 < 0) == (d1 < 0)) continue;
                    double f = -d0 / (d1 - d0), tz = tp + f * Dt;
                    RgCar by = d1 > 0 ? ca : cb, over = d1 > 0 ? cb : ca;
                    double s = by.S[i - 1] + (by.S[i] - by.S[i - 1]) * f;
                    Pass p = new Pass(); p.By = by.Idx; p.Over = over.Idx; p.T = tz; p.Lap = (int)Math.Floor(s / L) + 1; p.Pct = s / L - Math.Floor(s / L);
                    bool dup = false; foreach (Pass q in l) if (q.By == p.By && q.Over == p.Over && p.T - q.T < 3.0 && p.T >= q.T) dup = true;
                    if (!dup) l.Add(p);
                }
            }
        l.Sort(delegate (Pass x, Pass y) { return x.T.CompareTo(y.T); });
        return l;
    }

    // the finishing order the sim's own positions follow at the end (laps, then who crossed first); retired cars last by distance
    public static int[] FinalOrder()
    {
        List<int> ids = new List<int>(); for (int i = 0; i < 20; i++) ids.Add(i);
        ids.Sort(delegate (int a, int b)
        {
            int ka = Completed(a), kb = Completed(b); if (ka != kb) return kb.CompareTo(ka);
            double ta = Cars[a].X.Count > ka ? Cars[a].X[ka] : 1e18, tb = Cars[b].X.Count > kb ? Cars[b].X[kb] : 1e18; return ta.CompareTo(tb);
        });
        return ids.ToArray();
    }

    // the clean laps of a car the way the page's medians define them: not lap 1, not a pit lap (4 and 5 of car 9), not an off-track lap (lap 3 of car 3), 15 s or more, then within 107 % of the median
    static List<int> CleanLaps(int idx)
    {
        RgCar c = Cars[idx]; List<int> good = new List<int>(); List<double> du = new List<double>(); int n = Completed(idx);
        for (int k = 2; k <= n; k++)
        {
            if (idx == 9 && (k == 4 || k == 5)) continue; if (idx == 3 && k == 3) continue;
            double d = c.X[k] - c.X[k - 1]; if (d < 15) continue; good.Add(k); du.Add(d);
        }
        double med = Median(du); List<int> keep = new List<int>();
        foreach (int k in good) if (c.X[k] - c.X[k - 1] <= med * 1.07) keep.Add(k);
        return keep;
    }
    static double Median(List<double> v) { if (v.Count == 0) return double.NaN; List<double> s = new List<double>(v); s.Sort(); int n = s.Count; return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2; }

    // { number of laps used, median lap, corner 1 median, corner 2 ... } ; the corner entries are NaN with fewer than 3 values
    public static double[] Medians(int idx)
    {
        RgCar c = Cars[idx]; List<int> keep = CleanLaps(idx); double[] r = new double[2 + NC];
        r[0] = keep.Count; List<double> du = new List<double>(); foreach (int k in keep) du.Add(c.X[k] - c.X[k - 1]); r[1] = keep.Count < 3 ? double.NaN : Median(du);
        for (int q = 0; q < NC; q++)
        {
            List<double> vals = new List<double>();
            foreach (int k in keep)
            {
                double a = BoundaryRel(idx, k, 2 * q) / 1000.0, dur = c.X[k] - c.X[k - 1];
                bool toLine = CP1[q] < 1e-6 || CP1[q] >= 0.99999;
                double b = toLine ? dur : BoundaryRel(idx, k, 2 * q + 1) / 1000.0;
                if (b > a) vals.Add(b - a);
            }
            r[2 + q] = vals.Count >= 3 ? Median(vals) : double.NaN;
        }
        return r;
    }

    // ================= the check of the endpoint's reply =================
    static double D(object o) { return o == null ? double.NaN : Convert.ToDouble(o, Inv); }
    static int I(object o) { return o == null ? 0 : (int)Math.Round(Convert.ToDouble(o, Inv)); }
    static Dictionary<string, object> M(object o) { return o as Dictionary<string, object>; }
    static object[] A(object o) { return o as object[] ?? new object[0]; }
    static string Sx(object o) { return o == null ? "" : Convert.ToString(o, Inv); }

    sealed class R
    {
        public List<string> Lines = new List<string>(); public int Fails;
        public void Chk(string what, bool ok, string detail) { if (!ok) Fails++; Lines.Add((ok ? "ok|" : "FAIL|") + what + (detail.Length > 0 ? " (" + detail + ")" : "")); }
        public void Info(string t) { Lines.Add("info|" + t); }
    }

    public static string[] Verify(string json)
    {
        R r = new R();
        JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue;
        Dictionary<string, object> root = M(js.DeserializeObject(json));
        Dictionary<string, object> sm = M(root["summary"]);
        Dictionary<int, Dictionary<string, object>> cars = new Dictionary<int, Dictionary<string, object>>();
        foreach (object o in A(root["cars"])) cars[I(M(o)["i"])] = M(o);
        Dictionary<int, Dictionary<string, object>> tower = new Dictionary<int, Dictionary<string, object>>();
        foreach (object o in A(sm["tower"])) tower[I(M(o)["i"])] = M(o);
        // ---- who is in the field ----
        bool all = cars.Count == 20; for (int i = 0; i < 20; i++) if (!cars.ContainsKey(i)) all = false;
        r.Chk("the field has the 20 racing cars (idx 0-19), no pace car, no spectator", all && !cars.ContainsKey(20) && !cars.ContainsKey(21), cars.Count + " cars");
        r.Chk("Peter is idx 7 and the only car marked as him", I(root["me"]) == 7 && Sx(cars[7]["me"]) == "1" && Sx(cars[6]["me"]) == "0", "me=" + root["me"]);
        object[] cls = A(sm["classes"]);
        r.Chk("two classes, with their colours (#ffda59, #33ceff) and 12 + 8 cars", cls.Length == 2 && Sx(M(cls[0])["col"]) == "#ffda59" && Sx(M(cls[1])["col"]) == "#33ceff" && I(M(cls[0])["cars"]) == 12 && I(M(cls[1])["cars"]) == 8, "");
        r.Chk("names, numbers, team, car and iRating come from the session text", Sx(cars[7]["name"]) == "Peter Pretend" && Sx(cars[7]["num"]) == "7" && Sx(cars[12]["team"]).StartsWith("Team Cyan") && Sx(cars[0]["car"]) == "Pretend GT3 Evo" && I(cars[3]["ir"]) == 1800 + 3 * 37 && Sx(cars[3]["lic"]) == "A 4.12", "");
        r.Chk("it is a race of 6 laps on Road Atlanta, and the corner list is the workbench's", Sx(root["isRace"]) == "1" && Sx(root["sessLaps"]) == "6" && Sx(root["trackName"]) == "roadatlanta full" && A(root["corners"]).Length == NC, A(root["corners"]).Length + " corners");
        // ---- laps, lap times, line crossings, corner times ----
        double maxE = 0, maxSim = 0, maxS = 0, maxX = 0; int nE = 0, nSim = 0, nX = 0, badFlags = 0, badCount = 0, badSimPresence = 0;
        for (int idx = 0; idx < 20; idx++)
        {
            RgCar c = Cars[idx]; object[] rows = A(cars[idx]["L"]); int want = Completed(idx);
            if (rows.Length != want) { badCount++; r.Info("car " + idx + ": " + rows.Length + " laps, expected " + want); }
            foreach (object ro in rows)
            {
                object[] a = A(ro); int n = I(a[0]); if (n < 1 || n >= c.X.Count) { badCount++; continue; }
                double e = D(a[2]), s = D(a[1]), sim = D(a[3]); nE++;
                maxE = Math.Max(maxE, Math.Abs(e - c.X[n])); maxS = Math.Max(maxS, Math.Abs(s - c.X[n - 1]));
                if (c.Sim) { if (double.IsNaN(sim)) badSimPresence++; else { maxSim = Math.Max(maxSim, Math.Abs(sim - SimLap(c, n))); nSim++; } }
                else if (!double.IsNaN(sim)) badSimPresence++;
                int fl = I(a[6]), off = I(a[7]); int wantFl = (idx == 9 && n == 4 ? 1 : 0) | (idx == 9 && n == 5 ? 2 : 0), wantOff = idx == 3 && n == 3 ? 1 : 0;
                if (fl != wantFl || off != wantOff) { badFlags++; r.Info("car " + idx + " lap " + n + ": flags " + fl + " off " + off + ", expected " + wantFl + " / " + wantOff); }
                if (a.Length > 8)
                {
                    object[] xs = A(a[8]);
                    if (xs.Length != 2 * NC) { badCount++; continue; }
                    for (int kb = 0; kb < 2 * NC; kb++)
                    {
                        double want2 = BoundaryRel(idx, n, kb), got = D(xs[kb]);
                        if (double.IsNaN(want2)) continue; nX++; maxX = Math.Max(maxX, Math.Abs(got - want2));
                    }
                }
            }
        }
        r.Chk("every car has exactly the laps it drove up to its flag (no cool-down laps, a retired car stops)", badCount == 0, "");
        r.Chk("line crossings: every lap's end time equals the generator's to under 2 ms (" + nE + " laps, worst " + (maxE * 1000).ToString("0.000", Inv) + " ms; the starts " + (maxS * 1000).ToString("0.000", Inv) + " ms)", maxE < 0.002 && maxS < 0.002, "");
        r.Chk("lap times: the sim's own LastLapTime is used where it is there (" + nSim + " laps, worst " + (maxSim * 1000).ToString("0.000", Inv) + " ms) and is missing for the 5 cars that have none", maxSim < 0.001 && badSimPresence == 0, "presence mismatches " + badSimPresence);
        r.Chk("corner crossings: every boundary of every corner of every lap within 3 ms of the generator (" + nX + " crossings, worst " + maxX.ToString("0.00", Inv) + " ms)", nX > 3000 && maxX < 3.0, "");
        r.Chk("lap flags and off-track counts: only car 9 laps 4 (in) and 5 (out), only car 3 lap 3 (off)", badFlags == 0, "");
        // derived lap times: the lap's time as the page shows it
        double maxDer = 0; int nDer = 0;
        foreach (int idx in NoSim) foreach (object ro in A(cars[idx]["L"])) { object[] a = A(ro); int n = I(a[0]); if (n < 2) continue; double t = D(a[2]) - D(a[1]); maxDer = Math.Max(maxDer, Math.Abs(t - (Cars[idx].X[n] - Cars[idx].X[n - 1]))); nDer++; }
        r.Chk("derived lap times (cars without LastLapTime) equal the generator's to under 2 ms (" + nDer + " laps)", nDer > 20 && maxDer < 0.002, "");
        // lap 1 starts at the first crossing of the line for every car
        bool lap1 = true; for (int idx = 0; idx < 20; idx++) { object[] a = A(A(cars[idx]["L"])[0]); if (Math.Abs(D(a[1]) - Cars[idx].X[0]) > 0.002 || (I(a[6]) & 4) != 0) lap1 = false; }
        r.Chk("lap 1 starts at the car's first crossing of the line (the grid is behind it) for all 20 cars", lap1, "");
        // ---- the tower ----
        int[] order = FinalOrder(); bool ordOk = true; string ordTxt = "";
        for (int p = 0; p < 20; p++) { if (I(tower[order[p]]["pos"]) != p + 1) ordOk = false; ordTxt += order[p] + " "; }
        r.Chk("the final order is laps first, then who crossed first: " + ordTxt.Trim(), ordOk, "");
        bool lapsOk = true; for (int idx = 0; idx < 20; idx++) if (I(tower[idx]["laps"]) != Completed(idx)) lapsOk = false;
        r.Chk("laps completed: leaders 6, the slow class one lap down (5), the retired car 2", lapsOk && Completed(0) == 6 && Completed(12) == 5 && Completed(14) == 2, "");
        // gaps to the class leader
        bool gapOk = true; double maxGap = 0; string gapTxt = "";
        foreach (int cl in new int[] { 4001, 4002 })
        {
            List<int> inCl = new List<int>(); foreach (int idx in order) if (Cars[idx].Cls == cl) inCl.Add(idx);
            int lead = inCl[0];
            foreach (int idx in inCl)
            {
                if (idx == lead) continue; Dictionary<string, object> t = tower[idx];
                int kL = Completed(lead), kC = Completed(idx);
                if (kL == kC) { double want = Cars[idx].X[kC] - Cars[lead].X[kL], got = D(t["gap"]); maxGap = Math.Max(maxGap, Math.Abs(want - got)); if (Math.Abs(want - got) > 0.002 || I(t["gapLaps"]) != 0) { gapOk = false; gapTxt += " car" + idx; } }
                else if (I(t["gapLaps"]) != kL - kC || t["gap"] != null) { gapOk = false; gapTxt += " car" + idx + "(laps)"; }
            }
        }
        r.Chk("gap to the class leader: seconds on the same lap (worst " + (maxGap * 1000).ToString("0.000", Inv) + " ms), whole laps when a lap down" + gapTxt, gapOk, "");
        double totalWant = Cars[order[0]].X[Completed(order[0])] - Cars[order[0]].X[0], totalGot = D(tower[order[0]]["total"]);
        r.Chk("the winner's total race time equals the generator's (" + totalGot.ToString("0.000", Inv) + " s)", Math.Abs(totalWant - totalGot) < 0.002, "want " + totalWant.ToString("0.000", Inv));
        // best laps: the first ten cars have their best lap in the results text (the sim's own figure), the rest are worked out from the laps
        bool bestOk = true; double maxBest = 0; string bestTxt = "";
        for (int idx = 0; idx < 20; idx++)
        {
            RgCar c = Cars[idx]; int n = Completed(idx); double want = 1e18; string src;
            if (idx < 10 || idx == 14 || c.Sim) { for (int k = 1; k <= n; k++) want = Math.Min(want, SimLap(c, k)); src = "sim"; }      // the results text, or the sim's CarIdxBestLapTime (the cars with a LastLapTime also publish a best lap)
            else { for (int k = 2; k <= n; k++) { if (idx == 9 && (k == 4 || k == 5)) continue; want = Math.Min(want, c.X[k] - c.X[k - 1]); } src = c.Sim ? "sim" : "derived"; }
            double got = D(tower[idx]["best"]); string gs = Sx(tower[idx]["bestSrc"]);
            if (double.IsNaN(got) || Math.Abs(got - want) > 0.0006 || gs != src) { bestOk = false; bestTxt += " car" + idx + "(" + got.ToString("0.0000", Inv) + "/" + want.ToString("0.0000", Inv) + " " + gs + ")"; } else maxBest = Math.Max(maxBest, Math.Abs(got - want));
        }
        r.Chk("best lap of every car, and where the number came from (the results text for 11 cars, the sim's own best lap for the rest that have one, worked out from the line crossings for the 2 that have neither)" + bestTxt, bestOk, "");
        // ---- pits, off-track, retirement, incidents ----
        double[] pt = PitTruth(9); Dictionary<string, object> t9 = tower[9];
        object[] p9 = A(cars[9]["P"]); object[] pa = p9.Length == 1 ? A(p9[0]) : new object[5];
        r.Chk("car 9: one stop, in lap " + pt[3] + " and out lap " + pt[4] + ", pit lane time " + (pt[1] - pt[0]).ToString("0.0", Inv) + " s, stall " + pt[2].ToString("0.0", Inv) + " s (good to 0.11 s, the sample step)",
            p9.Length == 1 && I(pa[0]) == (int)pt[3] && I(pa[1]) == (int)pt[4] && Math.Abs((D(pa[3]) - D(pa[2])) - (pt[1] - pt[0])) < 0.11 && Math.Abs(D(pa[4]) - pt[2]) < 0.11 && I(t9["pits"]) == 1 && Math.Abs(D(t9["pitLane"]) - (pt[1] - pt[0])) < 0.15, "got " + (p9.Length == 1 ? (D(pa[3]) - D(pa[2])).ToString("0.00", Inv) + " / " + D(pa[4]).ToString("0.0", Inv) : "no stop"));
        bool noOtherPits = true; for (int idx = 0; idx < 20; idx++) if (idx != 9 && (A(cars[idx]["P"]).Length != 0 || I(tower[idx]["pits"]) != 0)) noOtherPits = false;
        r.Chk("no other car has a pit stop (the lap-5 and lap-1 crossings are not pit road, and the 1.6 s flicker of pit road car 16 shows at the entry line is not a stop)", noOtherPits, "");
        double[] ot = OffTruth(3);
        r.Chk("car 3: " + ot[0] + " off-track excursion in lap " + ot[2] + " of " + ot[1].ToString("0.00", Inv) + " s; nobody else is off", I(cars[3]["off"]) == (int)ot[0] && Math.Abs(D(cars[3]["offS"]) - ot[1]) < 0.15 && AllOthersClean(cars), "off " + cars[3]["off"] + ", " + D(cars[3]["offS"]).ToString("0.00", Inv) + " s");
        Dictionary<string, object> t14 = tower[14];
        bool out14 = t14["out"] is bool && (bool)t14["out"];
        r.Chk("car 14 retired in lap 3: gone from the world, marked OUT with 2 laps, last in its class (the reason from the results text is Disconnected)", Sx(cars[14]["gone"]) == "1" && out14 && Sx(t14["reason"]) == "Disconnected" && I(t14["laps"]) == 2 && I(t14["cpos"]) == 8, "out=" + t14["out"] + " laps=" + t14["laps"] + " cpos=" + t14["cpos"] + " reason=" + t14["reason"]);
        bool incOk = true; for (int idx = 0; idx < 10; idx++) if (I(tower[idx]["inc"]) != idx % 4) incOk = false;
        r.Chk("incidents come from this session's results (the qualifying block, which says 99, is not mixed in)", incOk && I(tower[14]["inc"]) == 8, "");
        // ---- the race trace and the positions (class 4001, Peter's) ----
        object[] tr = A(sm["trace"]); bool trOk = tr.Length == 12 && I(sm["maxLap"]) == 6; double maxTr = 0; bool posOk = true; string trTxt = "", posTxt = "";
        foreach (object to in tr)
        {
            Dictionary<string, object> s = M(to); int idx = I(s["i"]); object[] g = A(s["g"]), p = A(s["p"]);
            if (g.Length != 6 || p.Length != 6) { trOk = false; continue; }
            for (int n = 1; n <= 6; n++)
            {
                if (Completed(idx) < n) { if (g[n - 1] != null || p[n - 1] != null) { trOk = false; trTxt += " car" + idx + "lap" + n + "(should be empty)"; } continue; }     // a car that did not complete the lap has no point on it (car 9 is lapped after its stop)
                double lead = 1e18; for (int q = 0; q < 12; q++) if (Completed(q) >= n) lead = Math.Min(lead, Cars[q].X[n]);
                double want = Cars[idx].X[n] - lead; double eg = Math.Abs(want - D(g[n - 1]));
                if (double.IsNaN(eg)) { trTxt += " car" + idx + "lap" + n + "(no gap)"; trOk = false; } else maxTr = Math.Max(maxTr, eg);
                int rk = 1; for (int q = 0; q < 12; q++) if (q != idx && Completed(q) >= n && Cars[q].X[n] < Cars[idx].X[n]) rk++;
                if (rk != I(p[n - 1])) { posOk = false; posTxt += " car" + idx + "lap" + n + "(" + p[n - 1] + "/" + rk + ")"; }
            }
        }
        r.Chk("race trace: the gap to the class leader at the end of each lap for all 12 cars equals the generator's (worst " + (maxTr * 1000).ToString("0.000", Inv) + " ms)" + trTxt, trOk && maxTr < 0.002, "");
        r.Chk("positions by lap: the rank by line-crossing time, every car, every lap" + posTxt, posOk, "");
        // ---- passes ----
        List<Pass> tp = TruthPasses(); object[] rp = A(sm["passes"]); bool passOk = true; string passTxt = ""; int matched = 0;
        List<Dictionary<string, object>> got2 = new List<Dictionary<string, object>>(); foreach (object o in rp) got2.Add(M(o));
        foreach (Pass p in tp)
        {
            if (p.T > TF - 0.5) continue; Dictionary<string, object> hit = null;
            foreach (Dictionary<string, object> g in got2) if (I(g["by"]) == p.By && I(g["over"]) == p.Over && Math.Abs(D(g["t"]) - p.T) < 0.06) hit = g;
            if (hit == null) { passOk = false; passTxt += " missing " + p.By + ">" + p.Over; continue; }
            matched++; if (I(hit["lap"]) != p.Lap) { passOk = false; passTxt += " lap " + p.By + ">" + p.Over; }
            if (Sx(hit["where"]) != WhereOf(root, p.Pct)) { passOk = false; passTxt += " where " + p.By + ">" + p.Over + " (" + Sx(hit["where"]) + " / " + WhereOf(root, p.Pct) + ")"; }
        }
        foreach (Dictionary<string, object> g in got2)
        {
            bool known = false; foreach (Pass p in tp) if (I(g["by"]) == p.By && I(g["over"]) == p.Over && Math.Abs(D(g["t"]) - p.T) < 0.06) known = true;
            if (!known) { passOk = false; passTxt += " extra " + g["by"] + ">" + g["over"] + " at " + D(g["t"]).ToString("0.0", Inv); }
        }
        bool peterPasses = false, peterLost = false; foreach (Pass p in tp) { if (p.By == 7 && p.Over == 6) peterPasses = true; if (p.By == 5 && p.Over == 7) peterLost = true; }
        r.Chk("scene sanity: the generator has Peter passing car 6 and car 5 passing Peter (" + tp.Count + " passes in all)", peterPasses && peterLost && tp.Count >= 3, "");
        r.Chk("passes: every on-track pass of the generator (" + matched + ") is in the list with the right cars, lap, time (to 0.06 s) and corner - and nothing else is (pit stop, lapped traffic, other class)" + passTxt, passOk && matched == tp.FindAll(delegate (Pass q) { return q.T <= TF - 0.5; }).Count, "");
        // ---- per-corner medians ----
        Dictionary<int, Dictionary<string, object>> cm = new Dictionary<int, Dictionary<string, object>>(); foreach (object o in A(sm["cm"])) cm[I(M(o)["i"])] = M(o);
        double maxCm = 0, maxLm = 0; bool cmOk = true; int nCm = 0; string cmTxt = "";
        for (int idx = 0; idx < 20; idx++)
        {
            double[] tm = Medians(idx);
            if (tm[0] < 3) { if (cm.ContainsKey(idx)) { cmOk = false; cmTxt += " car" + idx + "(should have none)"; } continue; }
            if (!cm.ContainsKey(idx)) { cmOk = false; cmTxt += " car" + idx + "(missing)"; continue; }
            if (I(cm[idx]["n"]) != (int)tm[0]) { cmOk = false; cmTxt += " car" + idx + "(n " + cm[idx]["n"] + "/" + tm[0] + ")"; }
            maxLm = Math.Max(maxLm, Math.Abs(D(cm[idx]["lap"]) - tm[1])); object[] cc = A(cm[idx]["c"]);
            for (int q = 0; q < NC; q++) { double w = tm[2 + q], g = D(cc[q]); if (double.IsNaN(w) != double.IsNaN(g)) { cmOk = false; cmTxt += " car" + idx + "c" + q; continue; } if (!double.IsNaN(w)) { nCm++; maxCm = Math.Max(maxCm, Math.Abs(w - g)); } }
        }
        r.Chk("per-corner medians for every car with 3+ clean laps (" + nCm + " numbers; worst " + (maxCm * 1000).ToString("0.00", Inv) + " ms, laps " + (maxLm * 1000).ToString("0.00", Inv) + " ms) and none for the retired car" + cmTxt, cmOk && maxCm < 0.004 && maxLm < 0.003, "");
        // Peter against the car ahead and the leader (what the page shows), recomputed from the truth
        int ahead = I(sm["ahead"]), leaderIdx = I(sm["leader"]);
        int[] orderA = new int[12]; int ia = 0; foreach (int idx in order) if (Cars[idx].Cls == 4001) orderA[ia++] = idx;
        int pi = Array.IndexOf(orderA, 7);
        r.Chk("Peter finishes P" + (pi + 1) + " in his class; the car ahead is " + (pi > 0 ? orderA[pi - 1].ToString() : "-") + " and the leader " + orderA[0], pi > 0 && ahead == orderA[pi - 1] && leaderIdx == orderA[0], "ahead=" + ahead + " leader=" + leaderIdx);
        // meta
        r.Chk("the race log knows the green flag (" + Sx(root["greenT"]) + ", true " + Tg.ToString("0.0", Inv) + ") and the chequered flag (" + Sx(root["flagT"]) + ", true " + TF.ToString("0.0", Inv) + ")", D(root["greenT"]) >= Tg - 1e-6 && D(root["greenT"]) <= Tg + 0.11 && D(root["flagT"]) >= TF && D(root["flagT"]) <= TF + 0.21, "");
        r.Chk("the sim's own positions seen at the end agree with the order worked out from the line crossings (posMismatch " + sm["posMismatch"] + ")", I(sm["posMismatch"]) == 0, "");
        r.Info("worst errors: line crossing " + (maxE * 1000).ToString("0.000", Inv) + " ms, corner crossing " + maxX.ToString("0.00", Inv) + " ms, corner median " + (maxCm * 1000).ToString("0.00", Inv) + " ms, gap " + (maxGap * 1000).ToString("0.000", Inv) + " ms - the page states +-20 ms");
        r.Info("finish: leader " + order[0] + " at " + TF.ToString("0.00", Inv) + " s, last car " + TLast.ToString("0.00", Inv) + " s; races of " + Steps + " generator steps");
        return r.Lines.ToArray();
    }

    static bool AllOthersClean(Dictionary<int, Dictionary<string, object>> cars) { for (int i = 0; i < 20; i++) if (i != 3 && I(cars[i]["off"]) != 0) return false; return true; }

    // the corner a pass happened in, by the corner list of the reply (the same rule the page states: inside a corner, else "after Tn", else the start/finish straight)
    static string WhereOf(Dictionary<string, object> root, double pct)
    {
        object[] cs = A(root["corners"]); double m = 0.002; string prev = null; double prevP1 = -1;
        foreach (object o in cs)
        {
            Dictionary<string, object> c = M(o); double p0 = D(c["p0"]), p1 = D(c["p1"]);
            bool inside = p0 <= p1 ? (pct >= p0 - m && pct <= p1 + m) : (pct >= p0 - m || pct <= p1 + m);
            if (inside) return Sx(c["lab"]);
            if (p0 <= p1 && p1 <= pct && p1 > prevP1) { prev = Sx(c["lab"]); prevP1 = p1; }
        }
        return prev == null ? "start/finish straight" : "after " + prev;
    }
}
