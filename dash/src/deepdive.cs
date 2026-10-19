// Corner deep-dive engines (card C-34; docs\DESIGN-workbench.md 5, docs\research\pi-toolbox-features.md 5.1). Offline: reads .ibt files, never the sim.
//   GET /analysis/deep?id=<vault id or file name>&lap=<n>&ref=pb|session|<id>:<lap>      JSON, 503 while Peter drives
// One lap against its reference lap, both on the lap store's 1 m grid (workbench.cs LapChannels), the same corners as /analysis/lap.
// A corner's "zone" runs from where its braking starts (the last pedal application in the 250 m before the apex, joined with earlier ones
// less than 40 m before it; the corner start when there is none or when the braking belongs to the corner before) to the corner exit.
//   1 lock-up / wheelspin   a wheel 8 % slower than the car with the brake over 10 %; a REAR wheel 8 % faster on the throttle (over 10 %, brake off).
//                           Events merged when 3 m apart, at least 0.05 s. Reported with distance, wheel, seconds, worst slip %.
//   2 ABS                   BrakeABSactive pulses less than 30 m apart merge into a zone. Per corner: share of the braking time (brake over 10 %)
//                           with ABS active, and the peak cut. BrakeABScutPct in the file is a PRESSURE MULTIPLIER (1 = no cut, 0.92 = 8 % cut).
//   3 braking profile       the first brake application over 10 % in the zone: peak, seconds to reach 98 % of the peak, release (last 90 % of the
//                           peak until the pedal is under 2 %), trail = release time with the wheel turned 5 degrees or more, coast gap = brake
//                           off (under 2 %) to throttle on (over 5 %), coast = zone time with neither pedal.
//   4 wheel clipping        share of the corner (P0..P1) with SteeringWheelPctTorque >= 0.98 (counted on the file's own 60 Hz records, time-weighted),
//                           peak % and the peak in Nm at the setting SteeringWheelMaxForceNm.
//   5 racing line           Lat/Lon (Float32 after taking the lap's start point off) in metres; offset = my line from the reference line at the
//                           same distance, + = to the LEFT of the direction of travel. Turn-in = start of the steering (5 degrees or a quarter of
//                           the peak) that reaches the peak; apex = the tightest point of the turn (yaw rate / speed, smoothed over 7 m);
//                           minSpeedM = where the car was slowest (the apex of /analysis/lap).
//   6 g-g                   LatAccel / LongAccel in g (median of 9 m, so kerb spikes do not count) every 4 m of the zone; peaks and G total
//                           (Cosworth: sqrt(lat^2 + long^2)). LatAccel + = left, LongAccel + = forward, as in the file.
//   7 tyres per stint       a stint = laps between pit visits. Surface L/M/R and pressure: mean and peak over the stint's last clean lap.
//                           Carcass L/M/R and tread wear: the value at the stint's last record. iRacing only refreshes those two in the pits,
//                           so "live" says whether they changed during the stint.
//   8 setting changes       dcBrakeBias, dcTractionControl, dcABS; changes less than 3 s apart are one change. Up to 3 clean laps before and
//                           after (the lap with the change in it is left out), best of each side and the difference.
//   9 car balance           per phase (entry = turn-in to 12 % of the corner (10 to 40 m) before the apex, mid = that much either side of the apex,
//                           exit = the rest to the corner end), only where lateral g (smoothed) > 0.3, speed > 30 km/h and yaw rate > 0.02 rad/s
//                           (Cosworth's gate), and at least 0.25 s of it. Needs no car constants:
//                           steering needed to hold a 100 m radius (need100Deg), steering per g (degPerG), yaw gain, chassis slip angle, all with the
//                           wheel turned the way of the corner. Compared with the reference lap the same way: more steering for the same curve =
//                           more understeer than the reference. With the car's wheelbase (and weight split from the file's own setup): rear slip
//                           angle. With the steering ratio as well: Cosworth's understeer angle = wheel angle / ratio - wheelbase * yaw rate / speed
//                           (positive = understeer), front slip angle = understeer angle + rear slip angle, and the balance flags (oversteer: rear
//                           over 3 degrees and over front; understeer: front over 4.8 and rear under 5).
// Car constants come from CarTable below only; a channel that needs one is left out (and named in "hidden"), never guessed.
// Numbers only: no sentences here (the C-30 sentence rules live in analysis.cs).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static partial class Analysis
    {
        const double Gs = 9.80665;
        const double RadDeg = 180.0 / Math.PI;

        static readonly string[] DpNames = { "Speed", "Brake", "Throttle", "LFspeed", "RFspeed", "LRspeed", "RRspeed", "BrakeABSactive", "BrakeABScutPct",
            "SteeringWheelAngle", "YawRate", "LatAccel", "LongAccel", "Lat", "Lon", "VelocityX", "VelocityY", "SteeringWheelPctTorque", "SteeringWheelMaxForceNm" };
        const int cSpd = 0, cBrk = 1, cThr = 2, cLF = 3, cRF = 4, cLR = 5, cRR = 6, cAbs = 7, cCut = 8, cStr = 9, cYaw = 10, cLat = 11, cLon = 12, cLa = 13, cLo = 14, cVx = 15, cVy = 16, cTq = 17, cFnm = 18;
        static readonly string[] WheelName = { "LF", "RF", "LR", "RR" };

        // ---------------- car constants (the only place they live) ----------------
        // Wheelbase of the REAL car (iRacing's model is assumed to match; not measured). Steering ratio: iRacing does not publish it and a fit from
        // Peter's own telemetry was not repeatable (26 to 47 for the same car across files, 2026-10-11), so it stays 0 = unknown, and the road-wheel
        // understeer angle and the balance flags stay hidden until someone supplies a sourced number.
        sealed class CarConst { public string Name = "", Source = ""; public double Wheelbase, Ratio; }
        static CarConst MakeCar(string name, double wheelbase, double ratio, string source)
        {
            CarConst c = new CarConst(); c.Name = name; c.Wheelbase = wheelbase; c.Ratio = ratio; c.Source = source; return c;
        }
        static readonly CarConst[] CarTable = new CarConst[] {
            MakeCar("Ferrari 296 GT3", 2.660, 0, "wheelbase 2,660 mm: Ferrari's 296 GT3 launch spec sheet (autointernational.com.my, 2022-09-05) and Frikadelli Racing's car page; real car, iRacing model assumed equal. Steering ratio: not published."),
            MakeCar("Chevrolet Corvette Z06 GT3.R", 2.723, 0, "wheelbase 107.2 in = 2,723 mm: Wikipedia technical table (TF Sport lists 2,722 mm), also on simracing.wiki's iRacing page; real car, iRacing model assumed equal. Steering ratio: not published."),
            // P4 (2026-10-11): from iRacing's own manuals (docs\research\car-assets-steering.md B5). The names are the exact CarScreenName of Peter's .ibt files; the manuals
            // print no steering ratio and no steering lock, so Ratio stays 0 (understeer angle and balance flags stay hidden).
            MakeCar("BMW M4 GT3 EVO", 2.916, 0, "wheelbase 2916 mm (114.8 in): iRacing's own BMW M4 GT3 manual (BMW-M4-GT3-Manual_V3.pdf, page 4 technical specifications: \"WHEELBASE 2916 mm\"); real car, iRacing model assumed equal. Steering ratio: not in the manual."),
            MakeCar("BMW M4 GT3", 2.916, 0, "wheelbase 2916 mm (114.8 in): iRacing's own BMW M4 GT3 manual (BMW-M4-GT3-Manual_V3.pdf, page 4 technical specifications: \"WHEELBASE 2916 mm\"); real car, iRacing model assumed equal. Steering ratio: not in the manual."),
            MakeCar("Toyota GR86", 2.575, 0, "wheelbase 2575 mm: iRacing's own Toyota GR86 manual (Toyota_GR86_Manual_V2.pdf, technical data: \"WHEELBASE 2575 mm\"; the inch figure printed beside it does not match, the mm figure agrees with Toyota's road-car sheet, 2,575 mm); real car, iRacing model assumed equal. Steering ratio: not in the manual (the road car's 2.5 turns lock to lock is a road-car figure and is not used).")
        };

        static CarConst CarFor(string screenName)
        {
            foreach (CarConst c in CarTable) if (string.Equals(c.Name, screenName ?? "", StringComparison.OrdinalIgnoreCase)) return c;
            return null;
        }

        // Front weight share from the file's own setup block ("FWtdist: 46.9%"); 0 when the setup does not say.
        static double FrontWeight(string yaml)
        {
            Match m = Regex.Match(yaml ?? "", @"FWtdist:\s*([0-9.]+)\s*%");
            double v;
            if (m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float, Inv, out v) && v > 30 && v < 70) return v / 100.0;
            return 0;
        }

        // ---------------- one lap on the grid ----------------
        sealed class DpLap
        {
            public LapTrace Lap; public int M, N; public double L;
            public float[][] C; public bool[] Has;
            public double[] T, Dt, X, Y;          // T: pinned lap time at each grid sample (N), Dt: seconds to the next sample (M), X/Y: metres east/north of the lap start
            public double Fnm;
            public bool Line;
            public float[] LatS, LonS;            // LatAccel / LongAccel, median of 9 grid samples (about 9 m): kerbs add spikes of 4 g that are not cornering
            public List<double[]> Raw;            // wheel torque straight from the 60 Hz records: [distance m, torque 0..1, seconds to the next record]
        }

        sealed class DpEv
        {
            public string Kind = "", Wheel = "";
            public double M0, M1, Secs, Depth, Aux;
            public int Corner = -1;               // index in the lap's corner list, -1 = between corners
        }

        sealed class DpPhase
        {
            public bool Ok, HasRear, HasUa;
            public double Secs, LatG, SteerDeg, Need100, DegPerG, YawGain, SlipDeg, RearSlip, Ua, FrontSlip, OsShare, UsShare;
        }

        sealed class DpCorner
        {
            public int LockN, SpinN, AbsZones;
            public double LockSecs, SpinSecs, LockWorst = double.NaN, SpinWorst = double.NaN;
            public string LockWheel = "", SpinWheel = "";
            public bool HasAbs; public double AbsShare, AbsPeak, AbsBrakeSecs, AbsSecs;
            public bool HasBrake, HasCoastGap; public double BrkStartM, BrkLenM, BrkPeak, BrkToPeak, BrkRelease, BrkTrail, CoastGap, Coast;
            public bool HasClip; public double ClipShare, ClipPeakPct, ClipPeakNm, ClipFnm;
            public bool HasGG; public double PkLat, PkBrake, PkAccel, PkTotal; public List<double[]> GG = new List<double[]>();
            public bool HasTurn, HasXY, HasOffset; public double TurnInM, ApexM, MinSpeedM, TurnInX, TurnInY, ApexX, ApexY, OffTurnIn, OffApex, OffExit, OffMax;
            public DpPhase Entry = new DpPhase(), Mid = new DpPhase(), Exit = new DpPhase();
            public double ZoneM0, ZoneM1;
        }

        static string Nn(double v, string fmt) { return double.IsNaN(v) || double.IsInfinity(v) ? "null" : v.ToString(fmt, Inv); }
        static double Fwd(double a, double b, double L) { double x = (b - a) % L; if (x < 0) x += L; return x; }
        static int Ix(DpLap g, double d) { double x = DistNorm(d, g.L); int i = (int)Math.Round(x * g.M / g.L); return i % g.M; }
        static double DistOf(DpLap g, int i) { return i * g.L / g.M; }

        // grid indices from distance a to distance b along the lap (over the start/finish line when b < a)
        static List<int> Zone(DpLap g, double a, double b)
        {
            List<int> ix = new List<int>();
            double span = Fwd(a, b, g.L);
            int i0 = Ix(g, a), cnt = (int)Math.Floor(span * g.M / g.L) + 1;
            if (cnt > g.M) cnt = g.M;
            for (int k = 0; k < cnt; k++) ix.Add((i0 + k) % g.M);
            return ix;
        }

        static double SumDt(DpLap g, List<int> ix, int a, int b)
        {
            double s = 0;
            for (int j = a; j < b && j < ix.Count; j++) s += g.Dt[ix[j]];
            return s;
        }

        // Where the braking for each corner starts: the lap table's braking point (the main pedal application over 10 % in the 250 m before the
        // corner's apex, analysis.cs MeasureOne), so the deep-dive and the table can never disagree. When that start lies before the PREVIOUS
        // corner's apex the braking belongs to that corner: this one gets its own corner start and ownBrake false. No braking found: corner start.
        static double[] ZoneStarts(DpLap g, List<Met> mets, bool[] ownBrake)
        {
            double L = g.L;
            double[] zs = new double[mets.Count];
            for (int k = 0; k < mets.Count; k++)
            {
                Met m = mets[k];
                zs[k] = m.P0 * L; ownBrake[k] = false;
                if (!g.Has[cBrk]) continue;
                // DATA TRUTH (2026-10-18): the zone starts where the lap table's braking point is (analysis.cs MeasureOne: the MAIN
                // application, most pedal area). It used to take the LAST press and chain earlier ones <40 m apart, so Braking() below
                // measured a light first tap or a late blip: BMW Road America T3 lap 4 showed "brake 12 m, peak 10 %" for a 100 % stop
                // that started at 981 m, and T5/T14 likewise, while the lap table said 981 / 2079 / 5587.
                if (!m.HasBrake) continue;
                double sd = DistNorm(m.BrakeM, L);
                bool shared = k > 0 && Fwd(sd, mets[k - 1].Pa * L, L) < Fwd(sd, m.Pa * L, L);
                if (shared)
                {
                    // The main press began before the previous corner's apex. If the pedal was released after that apex and pressed again
                    // (a separate press: Corvette Road Atlanta T7 after T6, 2052 m), that second press is this corner's braking; a press that
                    // simply runs on (linked corners, T3 and T4) stays shared and this corner has none of its own.
                    int ia = Ix(g, m.Pa * L), ip = Ix(g, mets[k - 1].Pa * L), M = g.M, span = (ia - ip + M) % M, s0 = -1;
                    float[] brk2 = g.C[cBrk]; double bestA = 0, a2 = 0; int bestS = -1; bool released = false; float pk2 = 0;
                    for (int j = 0; j <= span; j++)
                    {
                        float v = brk2[(ip + j) % M]; bool on = v > 0.10f;
                        if (!on) released = true;
                        if (on && s0 < 0 && released) { s0 = j; a2 = 0; pk2 = 0; }
                        if (on && s0 >= 0) { a2 += v; if (v > pk2) pk2 = v; }
                        // a real application (30 % pedal or more), not a tap on the way past: T10b after T10a showed 'brake 8 m, 10 %'
                        if ((!on || j == span) && s0 >= 0) { if (a2 > bestA && pk2 >= 0.30f) { bestA = a2; bestS = s0; } s0 = -1; }
                    }
                    if (bestS < 0) continue;
                    sd = DistNorm(DistOf(g, (ip + bestS) % M), L);
                }
                zs[k] = sd; ownBrake[k] = true;
            }
            return zs;
        }

        // The corner (index in the list) whose zone holds distance d; where zones overlap, the one whose apex is nearest ahead.
        static int CornerAt(List<Met> mets, double[] zs, double d, double L)
        {
            int best = -1; double bestAhead = double.MaxValue;
            for (int k = 0; k < mets.Count; k++)
            {
                Met m = mets[k];
                double z0 = zs[k], z1 = m.P1 * L;
                if (Fwd(z0, d, L) > Fwd(z0, z1, L)) continue;
                double ahead = Fwd(d, m.Pa * L, L);
                if (ahead < bestAhead) { bestAhead = ahead; best = k; }
            }
            return best;
        }

        static bool FirstLatLon(LapTrace lap, out double lat, out double lon)
        {
            lat = 0; lon = 0;
            TrackMaps.Ibt t = TrackMaps.OpenIbt(lap.Path, true);
            if (t == null) return false;
            using (t.fs)
            {
                VarDef vLa = V(t, "Lat"), vLo = V(t, "Lon");
                if (vLa == null || vLo == null) return false;
                byte[] buf = new byte[t.bufLen];
                t.fs.Position = t.dataOff + (long)lap.RecA * t.bufLen;
                if (t.fs.Read(buf, 0, buf.Length) != buf.Length) return false;
                lat = Read(buf, vLa.Offset, vLa.Type); lon = Read(buf, vLo.Offset, vLo.Type);
                return Math.Abs(lat) > 1e-6 && Math.Abs(lon) > 1e-6;
            }
        }

        // median of 9 samples (about 9 m) around the lap; the last sample is the start line again, so it is left out. A median, not an average:
        // a kerb is a spike a few metres wide and an average would only spread it.
        static float[] Smooth(float[] a, int M)
        {
            float[] s = new float[M], w = new float[9];
            for (int i = 0; i < M; i++)
            {
                for (int k = -4; k <= 4; k++) w[k + 4] = a[(i + k + M) % M];
                Array.Sort(w);
                s[i] = w[4];
            }
            return s;
        }

        // A one-record clip (a kerb hit) can fall between two cells of the 1 m grid, so wheel clipping is counted on the file's own records.
        static List<double[]> RawTorque(LapTrace lap)
        {
            List<double[]> pts = new List<double[]>();
            TrackMaps.Ibt t = TrackMaps.OpenIbt(lap.Path, true);
            if (t == null) return pts;
            using (t.fs)
            {
                VarDef vTq = V(t, "SteeringWheelPctTorque"), vPct = V(t, "LapDistPct"), vSt = V(t, "SessionTime");
                long cnt = lap.RecB - lap.RecA;
                if (vTq == null || vPct == null || vSt == null || cnt <= 1 || cnt > 400000) return pts;
                byte[] buf = new byte[cnt * t.bufLen];
                t.fs.Position = t.dataOff + (long)lap.RecA * t.bufLen;
                int got = 0;
                while (got < buf.Length) { int r = t.fs.Read(buf, got, buf.Length - got); if (r <= 0) break; got += r; }
                int recs = got / t.bufLen;
                for (int k = 0; k + 1 < recs; k++)
                {
                    double dt = Read(buf, (k + 1) * t.bufLen + vSt.Offset, vSt.Type) - Read(buf, k * t.bufLen + vSt.Offset, vSt.Type);
                    if (dt <= 0 || dt > 0.05) continue;
                    pts.Add(new double[] { Read(buf, k * t.bufLen + vPct.Offset, vPct.Type) * lap.LengthM, Read(buf, k * t.bufLen + vTq.Offset, vTq.Type), dt });
                }
            }
            return pts;
        }

        static DpLap LoadDp(LapTrace lap, double lat0, double lon0)
        {
            DpLap g = new DpLap();
            g.Lap = lap; g.M = lap.Metres; g.N = lap.Metres + 1; g.L = lap.LengthM;
            List<Chan> chans = new List<Chan>();
            foreach (string nm in DpNames) { Chan c = new Chan(); c.Key = nm; c.Name = nm; chans.Add(c); }
            chans[cLa].Bias = lat0; chans[cLo].Bias = lon0;
            g.C = LapChannels(lap, chans, g.N, true);
            g.Has = new bool[chans.Count];
            for (int i = 0; i < chans.Count; i++) g.Has[i] = chans[i].Ok;
            g.T = new double[g.N]; g.Dt = new double[g.M];
            for (int i = 0; i < g.N; i++) g.T[i] = TAt(lap, i >= g.M ? g.L : i * g.L / g.M);
            for (int i = 0; i < g.M; i++) g.Dt[i] = Math.Max(0, g.T[i + 1] - g.T[i]);
            g.Fnm = g.Has[cFnm] ? g.C[cFnm][g.M / 2] : 0;
            if (g.Has[cTq]) g.Raw = RawTorque(lap);
            g.LatS = Smooth(g.C[cLat], g.M); g.LonS = Smooth(g.C[cLon], g.M);
            g.Line = g.Has[cLa] && g.Has[cLo] && (lat0 != 0 || lon0 != 0);
            if (g.Line)
            {
                const double R = 6371000.0;
                double kx = Math.PI / 180.0 * R * Math.Cos(lat0 * Math.PI / 180.0), ky = Math.PI / 180.0 * R;
                g.X = new double[g.M]; g.Y = new double[g.M];
                for (int i = 0; i < g.M; i++) { g.X[i] = g.C[cLo][i] * kx; g.Y[i] = g.C[cLa][i] * ky; }
            }
            return g;
        }

        // ---------------- events: lock-ups, wheelspin, ABS ----------------
        static void CloseRun(DpLap g, List<DpEv> evs, string kind, string wheel, int a, int b, double depth, double aux)
        {
            double secs = 0;
            for (int i = a; i <= b && i < g.M; i++) secs += g.Dt[i];
            if (secs < 0.05) return;
            DpEv e = new DpEv();
            e.Kind = kind; e.Wheel = wheel; e.M0 = DistOf(g, a); e.M1 = DistOf(g, b + 1); e.Secs = secs; e.Depth = depth; e.Aux = aux;
            evs.Add(e);
        }

        static List<DpEv> SlipEvents(DpLap g, bool lockUps)
        {
            List<DpEv> evs = new List<DpEv>();
            if (!g.Has[cSpd] || !g.Has[cBrk] || !g.Has[cThr]) return evs;
            for (int w = lockUps ? 0 : 2; w <= 3; w++)
            {
                if (!g.Has[cLF + w]) continue;
                float[] wh = g.C[cLF + w], v = g.C[cSpd], brk = g.C[cBrk], thr = g.C[cThr];
                int start = -1, last = -1; double depth = 0, aux = 0;
                // ABS holds a wheel 8-15 % slow on purpose: that is the brake working, not a lock-up. A lock-up is a wheel stuck slow
                // with no ABS working within 15 m (2026-10-18: a clean lap showed 32 'lock-ups' that were ABS pulses).
                // (looked at both ways: the wheel slows first and the ABS cuts in a few metres later)
                bool[] nearAbs = null;
                if (lockUps && g.Has[cAbs])
                {
                    nearAbs = new bool[g.M + 1]; int gapM = (int)Math.Ceiling(15.0 * g.M / g.L), run = -1000000;
                    for (int i = 0; i < g.M; i++) { if (g.C[cAbs][i] >= 0.5f) run = i; if (i - run <= gapM) nearAbs[i] = true; }
                    run = 1000000;
                    for (int i = g.M - 1; i >= 0; i--) { if (g.C[cAbs][i] >= 0.5f) run = i; if (run - i <= gapM) nearAbs[i] = true; }
                }
                for (int i = 0; i <= g.M; i++)
                {
                    bool on = false; double slip = 0;
                    if (i < g.M && v[i] > 5)
                    {
                        slip = wh[i] / v[i] - 1.0;
                        on = lockUps ? (brk[i] > 0.10 && slip <= -0.08 && (nearAbs == null || !nearAbs[i])) : (thr[i] > 0.10 && brk[i] < 0.02 && slip >= 0.08);
                    }
                    if (on)
                    {
                        if (start < 0) { start = i; depth = 0; aux = 0; }
                        last = i;
                        double s = Math.Abs(slip) * 100.0; if (s > depth) depth = s;
                        double a = lockUps ? brk[i] : thr[i]; if (a > aux) aux = a;
                    }
                    else if (start >= 0 && (i - last > 3 || i >= g.M))
                    {
                        CloseRun(g, evs, lockUps ? "lock" : "spin", WheelName[w], start, last, depth, aux);
                        start = -1;
                    }
                }
            }
            evs.Sort(delegate (DpEv a, DpEv b) { return a.M0.CompareTo(b.M0); });
            return evs;
        }

        static List<DpEv> AbsEvents(DpLap g)
        {
            List<DpEv> evs = new List<DpEv>();
            if (!g.Has[cAbs] || !g.Has[cCut]) return evs;
            float[] on = g.C[cAbs], cut = g.C[cCut];
            int gap = (int)Math.Ceiling(30.0 * g.M / g.L);
            int start = -1, last = -1; double active = 0, peak = 0;
            for (int i = 0; i <= g.M; i++)
            {
                bool a = i < g.M && on[i] >= 0.5f;
                if (a)
                {
                    if (start < 0) { start = i; active = 0; peak = 0; }
                    last = i; active += g.Dt[i];
                    double c = (1.0 - cut[i]) * 100.0; if (c > peak) peak = c;
                }
                else if (start >= 0 && (i - last >= gap || i >= g.M))
                {
                    DpEv e = new DpEv();
                    e.Kind = "abs"; e.M0 = DistOf(g, start); e.M1 = DistOf(g, last + 1); e.Secs = SumDt(g, Zone(g, e.M0, e.M1), 0, int.MaxValue); e.Aux = active; e.Depth = peak;
                    evs.Add(e); start = -1;
                }
            }
            return evs;
        }

        // ---------------- one corner ----------------
        static void Braking(DpLap g, List<int> zone, DpCorner c)
        {
            if (!g.Has[cBrk] || !g.Has[cThr]) return;
            float[] brk = g.C[cBrk], thr = g.C[cThr], str = g.C[cStr];
            int n = zone.Count, ks = -1;
            for (int j = 0; j < n; j++) if (brk[zone[j]] > 0.10f) { ks = j; break; }
            if (ks < 0) return;
            int ke = n;
            for (int j = ks + 1; j < n; j++) if (brk[zone[j]] < 0.02f) { ke = j; break; }
            double peak = 0;
            for (int j = ks; j < ke; j++) if (brk[zone[j]] > peak) peak = brk[zone[j]];
            int kp = ks;
            for (int j = ks; j < ke; j++) if (brk[zone[j]] >= 0.98 * peak) { kp = j; break; }
            int kr = kp;
            for (int j = kp; j < ke; j++) if (brk[zone[j]] >= 0.90 * peak) kr = j;
            c.HasBrake = true; c.BrkPeak = peak * 100.0;
            c.BrkStartM = DistOf(g, zone[ks]); c.BrkLenM = (ke - ks) * g.L / g.M;
            c.BrkToPeak = SumDt(g, zone, ks, kp);
            c.BrkRelease = SumDt(g, zone, kr, ke);
            double trail = 0;
            if (g.Has[cStr]) for (int j = kr; j < ke; j++) if (Math.Abs(str[zone[j]]) >= 0.087f) trail += g.Dt[zone[j]];
            c.BrkTrail = trail;
            if (ke < n)
            {
                int kt = -1;
                for (int j = ke; j < n; j++) if (thr[zone[j]] > 0.05f) { kt = j; break; }
                if (kt >= 0) { c.HasCoastGap = true; c.CoastGap = SumDt(g, zone, ke, kt); }
            }
            double coast = 0;
            for (int j = ks; j < n; j++) if (brk[zone[j]] <= 0.02f && thr[zone[j]] <= 0.05f) coast += g.Dt[zone[j]];
            c.Coast = coast;
        }

        // start of the sustained steering that reaches the corner's peak; -1 when the wheel never turns 5 degrees
        static int TurnIn(DpLap g, List<int> ix)
        {
            float[] str = g.C[cStr];
            int kp = -1; double peak = 0;
            for (int j = 0; j < ix.Count; j++) { double a = Math.Abs(str[ix[j]]); if (a > peak) { peak = a; kp = j; } }
            if (kp < 0 || peak < 0.087) return -1;
            double thr = Math.Max(0.087, 0.25 * peak);
            int j0 = kp;
            while (j0 > 0 && Math.Abs(str[ix[j0 - 1]]) >= thr) j0--;
            return ix[j0];
        }

        // my line from the reference line at grid sample i, + = to the left of the direction of travel
        static double LineOffset(DpLap me, DpLap rf, int i)
        {
            int M = me.M, a = (i + M - 3) % M, b = (i + 3) % M;
            double tx = rf.X[b] - rf.X[a], ty = rf.Y[b] - rf.Y[a], len = Math.Sqrt(tx * tx + ty * ty);
            if (len < 1e-6) return double.NaN;
            tx /= len; ty /= len;
            return (me.X[i] - rf.X[i]) * (-ty) + (me.Y[i] - rf.Y[i]) * tx;
        }

        static DpPhase BalancePhase(DpLap g, List<int> ix, double wb, double fw, double ratio)
        {
            DpPhase p = new DpPhase();
            if (!g.Has[cSpd] || !g.Has[cStr] || !g.Has[cYaw] || !g.Has[cLat]) return p;
            float[] spd = g.C[cSpd], str = g.C[cStr], yaw = g.C[cYaw], lat = g.LatS, vx = g.C[cVx], vy = g.C[cVy];
            bool vel = g.Has[cVx] && g.Has[cVy], rear = vel && wb > 0 && fw > 0, ua = rear && ratio > 0;
            double secs = 0, sSt = 0, sK = 0, sLat = 0, sYaw = 0, sBeta = 0, sAr = 0, sUa = 0, sOs = 0, sUs = 0;
            foreach (int i in ix)
            {
                double v = spd[i], r = yaw[i];
                if (v < 8.333 || Math.Abs(lat[i]) < 0.3 * Gs || Math.Abs(r) < 0.02) continue;
                double dt = g.Dt[i], sg = r > 0 ? 1.0 : -1.0;
                secs += dt; sSt += str[i] * sg * dt; sK += Math.Abs(r) / v * dt; sLat += Math.Abs(lat[i]) / Gs * dt; sYaw += Math.Abs(r) * dt;
                if (!vel) continue;
                double vxx = Math.Max(1.0, vx[i]);
                sBeta += -sg * Math.Atan2(vy[i], vxx) * dt;                       // + = the car's path points outside the corner
                if (!rear) continue;
                double b = wb * fw, ar = -sg * Math.Atan2(vy[i] - b * r, vxx);   // rear axle slip angle, + = rear sliding outward
                sAr += ar * dt;
                if (!ua) continue;
                double u = str[i] * sg / ratio - wb * Math.Abs(r) / v;           // Cosworth understeer angle, + = understeer
                double af = u + ar;
                sUa += u * dt;
                if (ar * RadDeg > 3.0 && ar > af) sOs += dt;
                if (af * RadDeg > 4.8 && ar * RadDeg < 5.0) sUs += dt;
            }
            if (secs < 0.25) return p;
            p.Ok = true; p.Secs = secs;
            p.LatG = sLat / secs; p.SteerDeg = sSt / secs * RadDeg;
            p.Need100 = sK > 1e-9 ? sSt / sK / 100.0 * RadDeg : double.NaN;
            p.DegPerG = sLat > 1e-9 ? sSt * RadDeg / sLat : double.NaN;
            p.YawGain = Math.Abs(sSt) > 1e-9 ? sYaw / sSt : double.NaN;
            p.SlipDeg = vel ? sBeta / secs * RadDeg : double.NaN;
            p.HasRear = rear; p.RearSlip = rear ? sAr / secs * RadDeg : double.NaN;
            p.HasUa = ua;
            if (ua) { p.Ua = sUa / secs * RadDeg; p.FrontSlip = p.Ua + p.RearSlip; p.OsShare = sOs / secs; p.UsShare = sUs / secs; }
            return p;
        }

        // the sample of tightest turning (yaw rate over speed, smoothed over 7 samples) from the turn-in to the corner exit
        static int ApexOf(DpLap g, int ti, double p1)
        {
            List<int> ix = Zone(g, DistOf(g, ti), p1);
            float[] yaw = g.C[cYaw], spd = g.C[cSpd];
            int best = ti; double bk = -1;
            for (int j = 0; j < ix.Count; j++)
            {
                double s = 0;
                for (int d = -3; d <= 3; d++) { int i = (ix[j] + d + g.M) % g.M; s += Math.Abs(yaw[i]) / Math.Max(5.0, spd[i]); }
                if (s > bk) { bk = s; best = ix[j]; }
            }
            return best;
        }

        // z0 = where this corner's own braking starts (its corner start when ownBrake is false)
        static DpCorner CornerDive(DpLap g, Met m, int k, double z0, bool ownBrake, List<DpEv> locks, List<DpEv> spins, List<DpEv> abs, DpLap other, double wb, double fw, double ratio)
        {
            DpCorner c = new DpCorner();
            double L = g.L, p0 = m.P0 * L, p1 = m.P1 * L;
            c.ZoneM0 = z0; c.ZoneM1 = p1; c.MinSpeedM = m.MinM;
            foreach (DpEv e in locks)
                if (e.Corner == k)
                {
                    c.LockN++; c.LockSecs += e.Secs;
                    if (double.IsNaN(c.LockWorst) || e.Depth > c.LockWorst) { c.LockWorst = e.Depth; c.LockWheel = e.Wheel; }
                }
            foreach (DpEv e in spins)
                if (e.Corner == k)
                {
                    c.SpinN++; c.SpinSecs += e.Secs;
                    if (double.IsNaN(c.SpinWorst) || e.Depth > c.SpinWorst) { c.SpinWorst = e.Depth; c.SpinWheel = e.Wheel; }
                }
            foreach (DpEv e in abs) if (e.Corner == k) c.AbsZones++;
            List<int> zone = Zone(g, z0, p1);
            // ABS share of the braking time, peak cut
            if (ownBrake && g.Has[cBrk] && g.Has[cAbs] && g.Has[cCut])
            {
                double bs = 0, ab = 0, pk = 0;
                foreach (int i in zone)
                    if (g.C[cBrk][i] > 0.10f)
                    {
                        bs += g.Dt[i];
                        if (g.C[cAbs][i] >= 0.5f) ab += g.Dt[i];
                        double cut = (1.0 - g.C[cCut][i]) * 100.0; if (cut > pk) pk = cut;
                    }
                if (bs > 0) { c.HasAbs = true; c.AbsBrakeSecs = bs; c.AbsSecs = ab; c.AbsShare = ab / bs; c.AbsPeak = pk; }
            }
            if (ownBrake) Braking(g, zone, c);
            // wheel clipping
            if (g.Raw != null && g.Raw.Count > 0)
            {
                double all = 0, clip = 0, pk = 0, span = Fwd(p0, p1, L);
                foreach (double[] r in g.Raw)
                {
                    if (Fwd(p0, r[0], L) > span) continue;
                    all += r[2];
                    if (r[1] >= 0.98) clip += r[2];
                    if (r[1] > pk) pk = r[1];
                }
                if (all > 0) { c.HasClip = true; c.ClipShare = clip / all; c.ClipPeakPct = pk * 100.0; c.ClipFnm = g.Fnm; c.ClipPeakNm = pk * g.Fnm; }
            }
            // g-g
            if (g.Has[cLat] && g.Has[cLon] && zone.Count > 0)
            {
                c.HasGG = true;
                double minLong = 0, maxLong = 0, maxLat = 0, maxTot = 0;
                for (int j = 0; j < zone.Count; j++)
                {
                    int i = zone[j];
                    double la = g.LatS[i] / Gs, lo = g.LonS[i] / Gs;
                    if (Math.Abs(la) > maxLat) maxLat = Math.Abs(la);
                    if (lo < minLong) minLong = lo;
                    if (lo > maxLong) maxLong = lo;
                    double tot = Math.Sqrt(la * la + lo * lo); if (tot > maxTot) maxTot = tot;
                    if (j % 4 == 0) c.GG.Add(new double[] { Math.Round(la, 2), Math.Round(lo, 2) });
                }
                c.PkLat = maxLat; c.PkBrake = -minLong; c.PkAccel = maxLong; c.PkTotal = maxTot;
            }
            // turn-in and apex (the tightest point of the turn), racing line, and the balance phases which hang on them
            if (g.Has[cStr] && g.Has[cYaw] && g.Has[cSpd])
            {
                List<int> win = Zone(g, p0 - 30, p1);
                int ti = TurnIn(g, win);
                if (ti >= 0)
                {
                    int ai = ApexOf(g, ti, p1);
                    c.HasTurn = true; c.TurnInM = DistOf(g, ti); c.ApexM = DistOf(g, ai);
                    if (g.Line)
                    {
                        c.HasXY = true; c.TurnInX = g.X[ti]; c.TurnInY = g.Y[ti]; c.ApexX = g.X[ai]; c.ApexY = g.Y[ai];
                        if (other != null && other.Line && other.M == g.M)
                        {
                            c.HasOffset = true;
                            c.OffTurnIn = LineOffset(g, other, ti); c.OffApex = LineOffset(g, other, ai); c.OffExit = LineOffset(g, other, Ix(g, p1));
                            double big = 0;
                            foreach (int i in win) { double o = LineOffset(g, other, i); if (!double.IsNaN(o) && Math.Abs(o) > Math.Abs(big)) big = o; }
                            c.OffMax = big;
                        }
                    }
                    // entry = turn-in to 12 % of the way (10 to 40 m) before the apex, mid = that much either side of the apex, exit = the rest
                    double dT = c.TurnInM, span = Fwd(dT, p1, L), toA = Fwd(dT, c.ApexM, L), w = Math.Max(10.0, Math.Min(40.0, 0.12 * span));
                    double oA = Math.Max(0.0, toA - w), oB = Math.Min(span, toA + w);
                    c.Entry = BalancePhase(g, Zone(g, dT, dT + oA), wb, fw, ratio);
                    c.Mid = BalancePhase(g, Zone(g, dT + oA, dT + oB), wb, fw, ratio);
                    c.Exit = BalancePhase(g, Zone(g, dT + oB, dT + span), wb, fw, ratio);
                }
            }
            return c;
        }

        // ---------------- JSON ----------------
        static void PhaseJson(StringBuilder sb, DpPhase p)
        {
            if (!p.Ok) { sb.Append("null"); return; }
            sb.Append("{\"secs\":").Append(Nn(p.Secs, "0.000")).Append(",\"latG\":").Append(Nn(p.LatG, "0.00")).Append(",\"steerDeg\":").Append(Nn(p.SteerDeg, "0.0"));
            sb.Append(",\"need100Deg\":").Append(Nn(p.Need100, "0.00")).Append(",\"degPerG\":").Append(Nn(p.DegPerG, "0.00")).Append(",\"yawGain\":").Append(Nn(p.YawGain, "0.0000"));
            sb.Append(",\"slipDeg\":").Append(Nn(p.SlipDeg, "0.00")).Append(",\"rearSlipDeg\":").Append(p.HasRear ? Nn(p.RearSlip, "0.00") : "null");
            sb.Append(",\"understeerDeg\":").Append(p.HasUa ? Nn(p.Ua, "0.00") : "null").Append(",\"frontSlipDeg\":").Append(p.HasUa ? Nn(p.FrontSlip, "0.00") : "null");
            sb.Append(",\"oversteerShare\":").Append(p.HasUa ? Nn(p.OsShare, "0.000") : "null").Append(",\"understeerShare\":").Append(p.HasUa ? Nn(p.UsShare, "0.000") : "null").Append('}');
        }

        static void PhaseDiff(StringBuilder sb, DpPhase a, DpPhase b)
        {
            if (!a.Ok || !b.Ok) { sb.Append("null"); return; }
            sb.Append("{\"need100Deg\":").Append(Nn(a.Need100 - b.Need100, "0.00")).Append(",\"need100Pct\":").Append(Math.Abs(b.Need100) > 1e-6 ? Nn((a.Need100 / b.Need100 - 1.0) * 100.0, "0.0") : "null");
            sb.Append(",\"degPerG\":").Append(Nn(a.DegPerG - b.DegPerG, "0.00")).Append(",\"slipDeg\":").Append(Nn(a.SlipDeg - b.SlipDeg, "0.00"));
            sb.Append(",\"rearSlipDeg\":").Append(a.HasRear && b.HasRear ? Nn(a.RearSlip - b.RearSlip, "0.00") : "null");
            sb.Append(",\"understeerDeg\":").Append(a.HasUa && b.HasUa ? Nn(a.Ua - b.Ua, "0.00") : "null").Append('}');
        }

        static void CornerJson(StringBuilder sb, DpCorner c)
        {
            sb.Append("{\"lock\":{\"n\":").Append(c.LockN).Append(",\"secs\":").Append(Nn(c.LockSecs, "0.000")).Append(",\"worstPct\":").Append(Nn(c.LockWorst, "0.0")).Append(",\"wheel\":").Append(Json_.S(c.LockWheel)).Append('}');
            sb.Append(",\"spin\":{\"n\":").Append(c.SpinN).Append(",\"secs\":").Append(Nn(c.SpinSecs, "0.000")).Append(",\"worstPct\":").Append(Nn(c.SpinWorst, "0.0")).Append(",\"wheel\":").Append(Json_.S(c.SpinWheel)).Append('}');
            sb.Append(",\"abs\":");
            if (!c.HasAbs) sb.Append("null");
            else sb.Append("{\"share\":").Append(Nn(c.AbsShare, "0.000")).Append(",\"peakCutPct\":").Append(Nn(c.AbsPeak, "0.0")).Append(",\"zones\":").Append(c.AbsZones)
                   .Append(",\"brakeSecs\":").Append(Nn(c.AbsBrakeSecs, "0.000")).Append(",\"activeSecs\":").Append(Nn(c.AbsSecs, "0.000")).Append('}');
            sb.Append(",\"brake\":");
            if (!c.HasBrake) sb.Append("null");
            else sb.Append("{\"startM\":").Append(Nn(c.BrkStartM, "0.0")).Append(",\"lenM\":").Append(Nn(c.BrkLenM, "0.0")).Append(",\"peakPct\":").Append(Nn(c.BrkPeak, "0.0"))
                   .Append(",\"toPeakS\":").Append(Nn(c.BrkToPeak, "0.000")).Append(",\"releaseS\":").Append(Nn(c.BrkRelease, "0.000")).Append(",\"trailS\":").Append(Nn(c.BrkTrail, "0.000"))
                   .Append(",\"coastGapS\":").Append(c.HasCoastGap ? Nn(c.CoastGap, "0.000") : "null").Append(",\"coastS\":").Append(Nn(c.Coast, "0.000")).Append('}');
            sb.Append(",\"clip\":");
            if (!c.HasClip) sb.Append("null");
            else sb.Append("{\"share\":").Append(Nn(c.ClipShare, "0.000")).Append(",\"peakPct\":").Append(Nn(c.ClipPeakPct, "0.0")).Append(",\"peakNm\":").Append(Nn(c.ClipPeakNm, "0.00")).Append(",\"maxForceNm\":").Append(Nn(c.ClipFnm, "0.00")).Append('}');
            sb.Append(",\"gg\":");
            if (!c.HasGG) sb.Append("null");
            else
            {
                sb.Append("{\"peakLatG\":").Append(Nn(c.PkLat, "0.000")).Append(",\"peakBrakeG\":").Append(Nn(c.PkBrake, "0.000")).Append(",\"peakAccelG\":").Append(Nn(c.PkAccel, "0.000")).Append(",\"peakTotalG\":").Append(Nn(c.PkTotal, "0.000")).Append(",\"pts\":[");
                for (int i = 0; i < c.GG.Count; i++) { if (i > 0) sb.Append(','); sb.Append('[').Append(F(c.GG[i][0], "0.00")).Append(',').Append(F(c.GG[i][1], "0.00")).Append(']'); }
                sb.Append("]}");
            }
            sb.Append(",\"line\":");
            if (!c.HasTurn) sb.Append("null");
            else
            {
                sb.Append("{\"turnInM\":").Append(Nn(c.TurnInM, "0.0")).Append(",\"apexM\":").Append(Nn(c.ApexM, "0.0")).Append(",\"minSpeedM\":").Append(Nn(c.MinSpeedM, "0.0"));
                if (c.HasXY) sb.Append(",\"turnInXY\":[").Append(Nn(c.TurnInX, "0.00")).Append(',').Append(Nn(c.TurnInY, "0.00")).Append("],\"apexXY\":[").Append(Nn(c.ApexX, "0.00")).Append(',').Append(Nn(c.ApexY, "0.00")).Append(']');
                else sb.Append(",\"turnInXY\":null,\"apexXY\":null");
                sb.Append(",\"offsetTurnInM\":").Append(c.HasOffset ? Nn(c.OffTurnIn, "0.00") : "null").Append(",\"offsetApexM\":").Append(c.HasOffset ? Nn(c.OffApex, "0.00") : "null");
                sb.Append(",\"offsetExitM\":").Append(c.HasOffset ? Nn(c.OffExit, "0.00") : "null").Append(",\"offsetMaxM\":").Append(c.HasOffset ? Nn(c.OffMax, "0.00") : "null").Append('}');
            }
            sb.Append(",\"balance\":{\"entry\":"); PhaseJson(sb, c.Entry); sb.Append(",\"mid\":"); PhaseJson(sb, c.Mid); sb.Append(",\"exit\":"); PhaseJson(sb, c.Exit); sb.Append("}}");
        }

        static void EventsJson(StringBuilder sb, List<DpEv> locks, List<DpEv> spins, List<DpEv> abs, List<Met> mets)
        {
            sb.Append("{\"lock\":["); EvList(sb, locks, mets); sb.Append("],\"spin\":["); EvList(sb, spins, mets); sb.Append("],\"abs\":["); EvList(sb, abs, mets); sb.Append("]}");
        }

        static void EvList(StringBuilder sb, List<DpEv> evs, List<Met> mets)
        {
            for (int i = 0; i < evs.Count; i++)
            {
                DpEv e = evs[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"m\":").Append(F(e.M0, "0.0")).Append(",\"m1\":").Append(F(e.M1, "0.0")).Append(",\"secs\":").Append(F(e.Secs, "0.000"));
                if (e.Kind == "abs") sb.Append(",\"activeSecs\":").Append(F(e.Aux, "0.000")).Append(",\"peakCutPct\":").Append(F(e.Depth, "0.0"));
                else sb.Append(",\"wheel\":").Append(Json_.S(e.Wheel)).Append(",\"worstPct\":").Append(F(e.Depth, "0.0")).Append(e.Kind == "lock" ? ",\"brakePeakPct\":" : ",\"throttlePeakPct\":").Append(F(e.Aux * 100.0, "0.0"));
                sb.Append(",\"corner\":").Append(e.Corner >= 0 ? mets[e.Corner].N.ToString(Inv) : "null").Append(",\"label\":").Append(e.Corner >= 0 ? Json_.S(mets[e.Corner].Label) : "null").Append('}');
            }
        }

        // ---------------- session level: stints (7) and setting changes (8) ----------------
        sealed class DpSession { public int N; public Dictionary<string, float[]> A = new Dictionary<string, float[]>(); }

        static readonly string[] TyreSuffix = { "tempL", "tempM", "tempR", "tempCL", "tempCM", "tempCR", "pressure", "wearL", "wearM", "wearR", "coldPressure" };
        static readonly string[] SettingNames = { "dcBrakeBias", "dcTractionControl", "dcABS" };
        static readonly string[] RideNames = { "LFrideHeight", "RFrideHeight", "LRrideHeight", "RRrideHeight" };

        // every record of the file, the channels this part needs, as Float32 (about 50 x 4 bytes per record)
        static DpSession ReadSessionChannels(string path)
        {
            DpSession s = new DpSession();
            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
            if (t == null) throw new IOException("not a telemetry file");
            using (t.fs)
            {
                List<string> names = new List<string>();
                names.Add("SessionTime"); names.Add("Lap"); names.Add("LapDistPct"); names.Add("FuelLevel");
                foreach (string sn in SettingNames) names.Add(sn);
                foreach (string rn in RideNames) names.Add(rn);
                foreach (string w in WheelName) foreach (string suf in TyreSuffix) names.Add(w + suf);
                int n = (int)Math.Min(t.records, 800000L);
                List<string> have = new List<string>(); List<VarDef> defs = new List<VarDef>();
                foreach (string nm in names) { VarDef d = V(t, nm); if (d != null) { have.Add(nm); defs.Add(d); s.A[nm] = new float[n]; } }
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
                        for (int c = 0; c < defs.Count; c++) s.A[have[c]][i] = (float)Read(buf, o + defs[c].Offset, defs[c].Type);
                    }
                    if (recs < want) break;
                }
                s.N = i;
            }
            return s;
        }

        static double RangeMean(float[] a, int r0, int r1) { double s = 0; int n = 0; for (int i = r0; i < r1 && i < a.Length; i++) { s += a[i]; n++; } return n > 0 ? s / n : double.NaN; }
        static double RangePeak(float[] a, int r0, int r1) { double p = double.NaN; for (int i = r0; i < r1 && i < a.Length; i++) if (double.IsNaN(p) || a[i] > p) p = a[i]; return p; }
        static double RangeSpread(float[] a, int r0, int r1)
        {
            double lo = double.MaxValue, hi = double.MinValue;
            for (int i = r0; i < r1 && i < a.Length; i++) { if (a[i] < lo) lo = a[i]; if (a[i] > hi) hi = a[i]; }
            return hi >= lo ? hi - lo : 0;
        }

        sealed class DpStint { public int First, Last, Clean, RecA, RecB; public double Best = double.NaN; public LapTrace FirstClean, LastClean; }

        static List<DpStint> Stints(Sess s)
        {
            List<DpStint> list = new List<DpStint>();
            DpStint cur = null;
            foreach (LapTrace lp in s.Laps)
            {
                if (lp.Skip == "pit") { cur = null; continue; }
                if (cur == null) { cur = new DpStint(); cur.First = lp.Lap; cur.RecA = lp.RecA; list.Add(cur); }
                cur.Last = lp.Lap; cur.RecB = lp.RecB;
                if (lp.Clean && lp.Tm != null)
                {
                    cur.Clean++;
                    if (cur.FirstClean == null) cur.FirstClean = lp;
                    cur.LastClean = lp;
                    if (double.IsNaN(cur.Best) || lp.Time < cur.Best) cur.Best = lp.Time;
                }
                if (lp.Skip == "in") cur = null;
            }
            return list;
        }

        static void TyresJson(StringBuilder sb, DpSession ss, DpStint st)
        {
            int a = st.LastClean != null ? st.LastClean.RecA : st.RecA, b = st.LastClean != null ? st.LastClean.RecB : st.RecB;
            int endRec = Math.Min(st.RecB, ss.N) - 1, startRec = Math.Min(st.RecA, ss.N - 1);
            sb.Append('{');
            for (int w = 0; w < 4; w++)
            {
                string p = WheelName[w];
                if (w > 0) sb.Append(',');
                sb.Append(Json_.S(p)).Append(":{");
                string[] sides = { "L", "M", "R" };
                float[] arr;
                sb.Append("\"surface\":{");
                for (int k = 0; k < 3; k++)
                {
                    if (k > 0) sb.Append(',');
                    sb.Append(Json_.S(sides[k])).Append(":");
                    if (ss.A.TryGetValue(p + "temp" + sides[k], out arr)) sb.Append("{\"mean\":").Append(Nn(RangeMean(arr, a, b), "0.0")).Append(",\"peak\":").Append(Nn(RangePeak(arr, a, b), "0.0")).Append('}'); else sb.Append("null");
                }
                sb.Append("},\"carcass\":{");
                double spread = 0;
                for (int k = 0; k < 3; k++)
                {
                    if (k > 0) sb.Append(',');
                    sb.Append(Json_.S(sides[k])).Append(":");
                    if (ss.A.TryGetValue(p + "tempC" + sides[k], out arr)) { sb.Append(Nn(arr[endRec], "0.0")); spread = Math.Max(spread, RangeSpread(arr, startRec, endRec + 1)); } else sb.Append("null");
                }
                sb.Append(",\"live\":").Append(spread > 0.05 ? "true" : "false").Append("},\"pressure\":{");
                if (ss.A.TryGetValue(p + "pressure", out arr)) sb.Append("\"startKpa\":").Append(Nn(arr[startRec], "0.0")).Append(",\"endKpa\":").Append(Nn(RangeMean(arr, a, b), "0.0")).Append(",\"peakKpa\":").Append(Nn(RangePeak(arr, a, b), "0.0"));
                else sb.Append("\"startKpa\":null,\"endKpa\":null,\"peakKpa\":null");
                sb.Append(",\"coldKpa\":").Append(ss.A.TryGetValue(p + "coldPressure", out arr) ? Nn(arr[startRec], "0.0") : "null");
                sb.Append("},\"wear\":{");
                spread = 0;
                for (int k = 0; k < 3; k++)
                {
                    if (k > 0) sb.Append(',');
                    sb.Append(Json_.S(sides[k])).Append(":");
                    if (ss.A.TryGetValue(p + "wear" + sides[k], out arr)) { sb.Append(Nn(arr[endRec] * 100.0, "0.0")); spread = Math.Max(spread, RangeSpread(arr, startRec, endRec + 1)); } else sb.Append("null");
                }
                sb.Append(",\"live\":").Append(spread > 0.0005 ? "true" : "false").Append("}}");
            }
            sb.Append('}');
        }

        static void StintsJson(StringBuilder sb, Sess mine, DpSession ss)
        {
            sb.Append('[');
            List<DpStint> list = ss.N > 0 ? Stints(mine) : new List<DpStint>();
            float[] tm; ss.A.TryGetValue("SessionTime", out tm);
            for (int i = 0; i < list.Count; i++)
            {
                DpStint st = list[i];
                if (i > 0) sb.Append(',');
                int endRec = Math.Min(st.RecB, ss.N) - 1, startRec = Math.Min(st.RecA, ss.N - 1);
                sb.Append("{\"n\":").Append(i + 1).Append(",\"lapFirst\":").Append(st.First).Append(",\"lapLast\":").Append(st.Last).Append(",\"cleanLaps\":").Append(st.Clean);
                sb.Append(",\"best\":").Append(Nn(st.Best, "0.000")).Append(",\"statLap\":").Append(st.LastClean != null ? st.LastClean.Lap.ToString(Inv) : "null");
                sb.Append(",\"minutes\":").Append(tm != null && endRec > startRec ? Nn((tm[endRec] - tm[startRec]) / 60.0, "0.0") : "null").Append(",\"tyres\":");
                TyresJson(sb, ss, st);
                sb.Append('}');
            }
            sb.Append(']');
        }

        // C-41 (workbench TYRES & STINT): one row per timed lap with its stint, the fuel it burned and each tyre's mean surface temperature
        // (L/M/R) and pressure over the lap. fuelUsed = level at the start minus level at the end of the lap's own records, null when it is
        // negative (a refuel) or the lap is an in/out lap. C-41c: lowRide = each wheel's raw minimum ride height (mm) and its lap distance (m).
        static void LapsJson(StringBuilder sb, Sess mine, DpSession ss)
        {
            sb.Append('[');
            if (ss.N > 0)
            {
                List<DpStint> st = Stints(mine);
                float[] fuel; ss.A.TryGetValue("FuelLevel", out fuel);
                float[] pctArr; ss.A.TryGetValue("LapDistPct", out pctArr);
                float[][] rideArr = new float[4][];
                for (int rw = 0; rw < 4; rw++) { float[] ra; rideArr[rw] = ss.A.TryGetValue(RideNames[rw], out ra) ? ra : null; }
                bool first = true;
                foreach (LapTrace lp in mine.Laps)
                {
                    int a = Math.Max(0, lp.RecA), b = Math.Min(lp.RecB, ss.N);
                    if (lp.Tm == null || b <= a) continue;
                    int stint = 0;
                    for (int k = 0; k < st.Count; k++) if (lp.Lap >= st[k].First && lp.Lap <= st[k].Last) stint = k + 1;
                    if (!first) sb.Append(','); first = false;
                    double used = fuel != null && lp.Skip.Length == 0 ? fuel[a] - fuel[b - 1] : double.NaN;
                    if (!double.IsNaN(used) && used < 0) used = double.NaN;
                    sb.Append("{\"lap\":").Append(lp.Lap).Append(",\"stint\":").Append(stint).Append(",\"time\":").Append(F(lp.Time, "0.000")).Append(",\"clean\":").Append(lp.Clean ? "true" : "false");
                    sb.Append(",\"fuelStart\":").Append(fuel != null ? Nn(fuel[a], "0.000") : "null").Append(",\"fuelUsed\":").Append(Nn(used, "0.000")).Append(",\"tyre\":{");
                    for (int w = 0; w < 4; w++)
                    {
                        float[] arr;
                        if (w > 0) sb.Append(',');
                        sb.Append(Json_.S(WheelName[w])).Append(":{");
                        string[] sides = { "L", "M", "R" };
                        for (int k = 0; k < 3; k++)
                            sb.Append(Json_.S(sides[k])).Append(':').Append(ss.A.TryGetValue(WheelName[w] + "temp" + sides[k], out arr) ? Nn(RangeMean(arr, a, b), "0.0") : "null").Append(',');
                        sb.Append("\"kpa\":").Append(ss.A.TryGetValue(WheelName[w] + "pressure", out arr) ? Nn(RangeMean(arr, a, b), "0.0") : "null").Append('}');
                    }
                    sb.Append("},\"lowRide\":");
                    LowRideJson(sb, rideArr, pctArr, a, b, lp.LengthM);
                    sb.Append('}');
                }
            }
            sb.Append(']');
        }

        // C-41c: each wheel's lowest ride height in a lap and the lap distance where it happened, from the file's own 60 Hz records.
        // The 1 m grid of /analysis/channels cannot give a minimum: it misses a dip one record wide (lap 7 of the PB session, RF: raw -1.09 mm,
        // grid 1.01 mm). mm = the channel (metres) x 1000; atM = LapDistPct x the lap's length. A tie takes the first record; a record that is not
        // a number is skipped. "null" when the file has no ride-height channel or the lap has no record.
        static void LowRideJson(StringBuilder sb, float[][] ride, float[] pct, int a, int b, double lengthM)
        {
            StringBuilder t = new StringBuilder();
            t.Append('{');
            for (int w = 0; w < 4; w++)
            {
                float[] r = ride[w];
                int at = -1;
                if (r != null && pct != null)
                    for (int i = Math.Max(0, a); i < b && i < r.Length && i < pct.Length; i++)
                        if (!float.IsNaN(r[i]) && (at < 0 || r[i] < r[at])) at = i;
                if (at < 0) { sb.Append("null"); return; }
                if (w > 0) t.Append(',');
                t.Append(Json_.S(WheelName[w])).Append(":{\"mm\":").Append(F(r[at] * 1000.0, "0.000")).Append(",\"atM\":").Append(F(pct[at] * lengthM, "0.0")).Append('}');
            }
            sb.Append(t.ToString()).Append('}');
        }

        // The same numbers for one lap read straight from its own file: the reference lap is usually in another session file than the lap on screen.
        static void RawLowRideJson(StringBuilder sb, LapTrace lap)
        {
            TrackMaps.Ibt t = TrackMaps.OpenIbt(lap.Path, true);
            if (t == null) { sb.Append("null"); return; }
            float[][] ride = new float[4][];
            float[] pct = null;
            using (t.fs)
            {
                VarDef vPct = V(t, "LapDistPct");
                VarDef[] vr = new VarDef[4];
                long cnt = lap.RecB - lap.RecA;
                bool ok = vPct != null && cnt > 0 && cnt <= 400000;
                for (int w = 0; w < 4; w++) { vr[w] = V(t, RideNames[w]); if (vr[w] == null) ok = false; }
                if (!ok) { sb.Append("null"); return; }
                byte[] buf = new byte[cnt * t.bufLen];
                t.fs.Position = t.dataOff + (long)lap.RecA * t.bufLen;
                int got = 0;
                while (got < buf.Length) { int r = t.fs.Read(buf, got, buf.Length - got); if (r <= 0) break; got += r; }
                int recs = got / t.bufLen;
                pct = new float[recs];
                for (int w = 0; w < 4; w++) ride[w] = new float[recs];
                for (int k = 0; k < recs; k++)
                {
                    int o = k * t.bufLen;
                    pct[k] = (float)Read(buf, o + vPct.Offset, vPct.Type);
                    for (int w = 0; w < 4; w++) ride[w][k] = (float)Read(buf, o + vr[w].Offset, vr[w].Type);
                }
            }
            LowRideJson(sb, ride, pct, 0, pct.Length, lap.LengthM);
        }

        sealed class DpChange { public string Ch = ""; public double From, To, T; public int RecA, RecB; }

        static void ChangesJson(StringBuilder sb, Sess mine, DpSession ss)
        {
            float[] tm;
            ss.A.TryGetValue("SessionTime", out tm);
            List<DpChange> list = new List<DpChange>();
            foreach (string nm in SettingNames)
            {
                float[] a;
                if (!ss.A.TryGetValue(nm, out a) || tm == null || ss.N < 2) continue;
                DpChange cur = null; double prev = a[0];
                for (int r = 1; r < ss.N; r++)
                {
                    if (Math.Abs(a[r] - prev) > 1e-4)
                    {
                        if (cur != null && tm[r] - tm[cur.RecB] < 3.0) { cur.To = a[r]; cur.RecB = r; }
                        else { if (cur != null) list.Add(cur); cur = new DpChange(); cur.Ch = nm; cur.From = prev; cur.To = a[r]; cur.RecA = r; cur.RecB = r; cur.T = tm[r]; }
                    }
                    prev = a[r];
                }
                if (cur != null) list.Add(cur);
            }
            list.Sort(delegate (DpChange x, DpChange y) { return x.RecA.CompareTo(y.RecA); });
            float[] lapNo, pct;
            ss.A.TryGetValue("Lap", out lapNo); ss.A.TryGetValue("LapDistPct", out pct);
            sb.Append('[');
            for (int i = 0; i < list.Count; i++)
            {
                DpChange c = list[i];
                if (i > 0) sb.Append(',');
                List<LapTrace> before = new List<LapTrace>(), after = new List<LapTrace>();
                foreach (LapTrace lp in mine.Laps)
                {
                    if (!lp.Clean || lp.Tm == null) continue;
                    if (lp.RecB <= c.RecA) { before.Add(lp); if (before.Count > 3) before.RemoveAt(0); }
                    else if (lp.RecA >= c.RecB && after.Count < 3) after.Add(lp);
                }
                double bb = double.NaN, ba = double.NaN;
                foreach (LapTrace lp in before) if (double.IsNaN(bb) || lp.Time < bb) bb = lp.Time;
                foreach (LapTrace lp in after) if (double.IsNaN(ba) || lp.Time < ba) ba = lp.Time;
                bool pit = false;
                if (before.Count > 0 && after.Count > 0)
                    foreach (LapTrace lp in mine.Laps)
                        if (lp.RecA >= before[before.Count - 1].RecB && lp.RecB <= after[0].RecA && (lp.Skip == "in" || lp.Skip == "out" || lp.Skip == "pit")) pit = true;
                sb.Append("{\"channel\":").Append(Json_.S(c.Ch)).Append(",\"from\":").Append(Nn(c.From, "0.####")).Append(",\"to\":").Append(Nn(c.To, "0.####"));
                sb.Append(",\"t\":").Append(Nn(c.T, "0.0")).Append(",\"lap\":").Append(lapNo != null ? ((int)lapNo[c.RecA]).ToString(Inv) : "null");
                sb.Append(",\"atM\":").Append(pct != null ? Nn(pct[c.RecA] * mine.LengthM, "0") : "null");
                sb.Append(",\"before\":["); for (int k = 0; k < before.Count; k++) { if (k > 0) sb.Append(','); sb.Append("{\"lap\":").Append(before[k].Lap).Append(",\"time\":").Append(F(before[k].Time, "0.000")).Append('}'); }
                sb.Append("],\"after\":["); for (int k = 0; k < after.Count; k++) { if (k > 0) sb.Append(','); sb.Append("{\"lap\":").Append(after[k].Lap).Append(",\"time\":").Append(F(after[k].Time, "0.000")).Append('}'); }
                sb.Append("],\"bestBefore\":").Append(Nn(bb, "0.000")).Append(",\"bestAfter\":").Append(Nn(ba, "0.000"));
                sb.Append(",\"delta\":").Append(!double.IsNaN(bb) && !double.IsNaN(ba) ? Nn(ba - bb, "0.000") : "null").Append(",\"pitBetween\":").Append(pit ? "true" : "false").Append('}');
            }
            sb.Append(']');
        }

        // ---------------- the route and the whole answer ----------------
        public static string DeepRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
            string id = Q(q, "id"), rf = Q(q, "ref");
            if (rf.Length == 0) rf = "pb";
            int lap;
            if (!int.TryParse(Q(q, "lap"), NumberStyles.Integer, Inv, out lap)) { code = 400; return Err("lap must be a number"); }
            string file = ResolveFile(id);
            if (file == null) { code = 404; return Err("no such lap file"); }
            try { if (Career.OnlineOnly(new FileInfo(file))) { code = 409; return Err("Online-only in OneDrive: run tools\\keep-iracing-local.cmd"); } }
            catch { code = 404; return Err("no such lap file"); }
            ThreadPriority was = Thread.CurrentThread.Priority;
            try
            {
                Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
                string dir = TrackMaps.TelemetryDir;
                if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) dir = Path.GetDirectoryName(file);
                return BuildDeep(file, lap, rf, dir, true, 0, out code);
            }
            catch (Exception ex) { Log.W("deep: " + ex.Message); code = 500; return Err("could not read that file"); }
            finally { try { Thread.CurrentThread.Priority = was; } catch { } }
        }

        static void LineJson(StringBuilder sb, DpLap me, DpLap rf)
        {
            // the two paths every 5 m, in metres east / north of the lap's start; offset = me from ref, + = left of travel
            int step = Math.Max(1, (int)Math.Round(5.0 * me.M / me.L));
            sb.Append("{\"stepM\":").Append(F(step * me.L / me.M, "0.00")).Append(",\"me\":{\"x\":[");
            bool first = true;
            for (int i = 0; i < me.M; i += step) { if (!first) sb.Append(','); first = false; sb.Append(F(me.X[i], "0.00")); }
            sb.Append("],\"y\":[");
            first = true;
            for (int i = 0; i < me.M; i += step) { if (!first) sb.Append(','); first = false; sb.Append(F(me.Y[i], "0.00")); }
            sb.Append("]}");
            if (rf != null && rf.Line && rf.M == me.M)
            {
                sb.Append(",\"ref\":{\"x\":[");
                first = true;
                for (int i = 0; i < rf.M; i += step) { if (!first) sb.Append(','); first = false; sb.Append(F(rf.X[i], "0.00")); }
                sb.Append("],\"y\":[");
                first = true;
                for (int i = 0; i < rf.M; i += step) { if (!first) sb.Append(','); first = false; sb.Append(F(rf.Y[i], "0.00")); }
                sb.Append("]},\"offset\":[");
                first = true;
                for (int i = 0; i < me.M; i += step) { if (!first) sb.Append(','); first = false; sb.Append(Nn(LineOffset(me, rf, i), "0.00")); }
                sb.Append(']');
            }
            sb.Append('}');
        }

        // ratioOverride: test only (tests\analysis-test.ps1 --ratio), 0 = use the car table
        static string BuildDeep(string file, int lapNo, string spec, string dir, bool liveRules, double ratioOverride, out int code)
        {
            code = 200;
            List<Sess> sessions = Gather(file, dir, liveRules);
            Sess mine = sessions[0];
            CornerSet cs = LoadCorners(mine);
            LapTrace me = null;
            foreach (LapTrace lap in mine.Laps) if (lap.Lap == lapNo && (me == null || lap.Clean)) me = lap;
            if (me == null) { code = 404; return Err("no such lap in this file"); }
            if (me.Tm == null)
            {
                // The deep-dive engines (stints, per-lap fuel and tyres, the racing line against the reference) need a whole lap. Not a refusal:
                // a 200 that says why and what the part-lap covers, so a page can show the rest and offer ALL THE DATA (rawdata.html).
                LapTrace pv = PartialOf(me);
                StringBuilder pb = new StringBuilder(600);
                pb.Append("{\"v\":1,\"partial\":true,\"reason\":").Append(Json_.S("Lap " + lapNo.ToString(Inv) + " is not a full lap (" + (me.Skip.Length > 0 ? me.Skip : "partial") + "): the corner deep dive needs a whole lap. Every channel of it is in ALL THE DATA."))
                  .Append(",\"file\":").Append(Json_.S(me.File)).Append(",\"lap\":").Append(me.Lap).Append(",\"car\":").Append(Json_.S(me.Car)).Append(",\"track\":").Append(Json_.S(me.Track)).Append(",\"config\":").Append(Json_.S(me.Config))
                  .Append(",\"lengthM\":").Append(F(me.LengthM, "0.0")).Append(",\"cover\":");
                if (pv != null) AppendCover(pb, pv); else pb.Append("null");
                pb.Append(",\"raw\":").Append(Json_.S("rawdata.html?id=" + Uri.EscapeDataString(me.File))).Append(",\"corners\":[],\"laps\":[]}");
                return pb.ToString();
            }
            foreach (LapTrace lap in mine.Laps) if (lap.Clean) Measure(lap, cs);
            Measure(me, cs);      // a whole lap with a long off-track (skip "off") is a whole lap too: its corners are measured (it used to be a 409)
            List<LapTrace> clean = CleanOf(sessions);
            string kind;
            LapTrace rf = FindRefLap(clean, me, spec, sessions, cs, out kind);
            if (rf != null && (SameLap(rf, me) || rf.Tm == null || Math.Abs(rf.LengthM - me.LengthM) > 1 || rf.Metres != me.Metres)) rf = null;
            if (rf != null && !rf.Measured) Measure(rf, cs);

            double lat0 = 0, lon0 = 0;
            FirstLatLon(me, out lat0, out lon0);
            DpLap a = LoadDp(me, lat0, lon0);
            DpLap b = rf != null ? LoadDp(rf, lat0, lon0) : null;

            CarConst cc = CarFor(me.Car);
            double wb = cc != null ? cc.Wheelbase : 0, ratio = ratioOverride > 0 ? ratioOverride : (cc != null ? cc.Ratio : 0), fw = FrontWeight(mine.Yaml);
            List<string> hidden = new List<string>();
            if (!(wb > 0 && fw > 0)) hidden.Add("rearSlipDeg");
            if (!(wb > 0 && fw > 0 && ratio > 0)) { hidden.Add("understeerDeg"); hidden.Add("frontSlipDeg"); hidden.Add("balanceFlags"); }

            List<DpEv> lockA = SlipEvents(a, true), spinA = SlipEvents(a, false), absA = AbsEvents(a);
            List<DpEv> lockB = b != null ? SlipEvents(b, true) : new List<DpEv>(), spinB = b != null ? SlipEvents(b, false) : new List<DpEv>(), absB = b != null ? AbsEvents(b) : new List<DpEv>();
            bool[] ownA = new bool[me.Corners.Count], ownB = rf != null ? new bool[rf.Corners.Count] : null;
            double[] zsA = ZoneStarts(a, me.Corners, ownA), zsB = rf != null ? ZoneStarts(b, rf.Corners, ownB) : null;
            foreach (DpEv e in lockA) e.Corner = CornerAt(me.Corners, zsA, e.M0, me.LengthM);
            foreach (DpEv e in spinA) e.Corner = CornerAt(me.Corners, zsA, e.M0, me.LengthM);
            foreach (DpEv e in absA) e.Corner = CornerAt(me.Corners, zsA, e.M0, me.LengthM);
            if (rf != null)
            {
                foreach (DpEv e in lockB) e.Corner = CornerAt(rf.Corners, zsB, e.M0, rf.LengthM);
                foreach (DpEv e in spinB) e.Corner = CornerAt(rf.Corners, zsB, e.M0, rf.LengthM);
                foreach (DpEv e in absB) e.Corner = CornerAt(rf.Corners, zsB, e.M0, rf.LengthM);
            }

            StringBuilder sb = new StringBuilder(60000);
            sb.Append("{\"v\":1,\"file\":").Append(Json_.S(me.File)).Append(",\"lap\":").Append(me.Lap).Append(",\"car\":").Append(Json_.S(me.Car)).Append(",\"track\":").Append(Json_.S(me.Track)).Append(",\"config\":").Append(Json_.S(me.Config));
            sb.Append(",\"lengthM\":").Append(F(me.LengthM, "0.0")).Append(",\"time\":").Append(F(me.Time, "0.000"));
            sb.Append(",\"ref\":"); if (rf == null) sb.Append("null"); else { AppendLapInfo(sb, rf, kind); }
            sb.Append(",\"carConst\":{\"known\":").Append(cc != null ? "true" : "false").Append(",\"wheelbaseM\":").Append(wb > 0 ? F(wb, "0.000") : "null");
            sb.Append(",\"steerRatio\":").Append(ratio > 0 ? F(ratio, "0.00") : "null").Append(",\"frontWeight\":").Append(fw > 0 ? F(fw, "0.000") : "null");
            sb.Append(",\"source\":").Append(Json_.S(ratioOverride > 0 ? "steering ratio: test override" : (cc != null ? cc.Source : "this car is not in the table: no wheelbase, no steering ratio"))).Append(",\"hidden\":[");
            for (int i = 0; i < hidden.Count; i++) { if (i > 0) sb.Append(','); sb.Append(Json_.S(hidden[i])); }
            sb.Append("]},\"events\":{\"me\":"); EventsJson(sb, lockA, spinA, absA, me.Corners);
            sb.Append(",\"ref\":"); if (rf == null) sb.Append("null"); else EventsJson(sb, lockB, spinB, absB, rf.Corners);
            sb.Append("},\"line\":"); if (a.Line) LineJson(sb, a, b); else sb.Append("null");
            sb.Append(",\"corners\":[");
            for (int k = 0; k < me.Corners.Count; k++)
            {
                Met m = me.Corners[k];
                DpCorner ca = CornerDive(a, m, k, zsA[k], ownA[k], lockA, spinA, absA, b, wb, fw, ratio), cb = null;
                Met mr = rf != null ? ByN(rf.Corners, m.N) : null;
                if (mr != null)
                {
                    int kr = rf.Corners.IndexOf(mr);
                    cb = CornerDive(b, mr, kr, zsB[kr], ownB[kr], lockB, spinB, absB, null, wb, fw, ratio);
                }
                if (k > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(m.N).Append(",\"label\":").Append(Json_.S(m.Label)).Append(",\"name\":").Append(Json_.S(m.Name)).Append(",\"p0\":").Append(F(m.P0, "0.0000")).Append(",\"pa\":").Append(F(m.Pa, "0.0000")).Append(",\"p1\":").Append(F(m.P1, "0.0000"));
                sb.Append(",\"zone\":{\"m0\":").Append(F(ca.ZoneM0, "0.0")).Append(",\"m1\":").Append(F(ca.ZoneM1, "0.0")).Append("},\"me\":"); CornerJson(sb, ca);
                sb.Append(",\"ref\":"); if (cb == null) sb.Append("null"); else CornerJson(sb, cb);
                sb.Append(",\"d\":"); if (cb == null) sb.Append("null");
                else { sb.Append("{\"entry\":"); PhaseDiff(sb, ca.Entry, cb.Entry); sb.Append(",\"mid\":"); PhaseDiff(sb, ca.Mid, cb.Mid); sb.Append(",\"exit\":"); PhaseDiff(sb, ca.Exit, cb.Exit); sb.Append('}'); }
                sb.Append('}');
            }
            sb.Append("],\"stints\":");
            DpSession ss = ReadSessionChannels(mine.Path);
            StintsJson(sb, mine, ss);
            sb.Append(",\"laps\":");
            LapsJson(sb, mine, ss);
            sb.Append(",\"refLowRide\":"); if (rf == null) sb.Append("null"); else RawLowRideJson(sb, rf);
            sb.Append(",\"settings\":{");
            for (int i = 0; i < SettingNames.Length; i++)
            {
                float[] arr;
                if (i > 0) sb.Append(',');
                sb.Append(Json_.S(SettingNames[i])).Append(':').Append(ss.A.TryGetValue(SettingNames[i], out arr) && ss.N > 0 ? Nn(arr[0], "0.####") : "null");
            }
            sb.Append("},\"changes\":");
            ChangesJson(sb, mine, ss);
            sb.Append('}');
            return sb.ToString();
        }
    }
}
