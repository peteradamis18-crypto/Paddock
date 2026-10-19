// partial.cs - a lap that is NOT a full lap (an out-lap, an in-lap, a lap through the pits, a lap cut short) as real data.
// Peter 2026-10-18 (a qualifying run with one out-lap and half a hot lap): "just show me the data". Every engine used to stop at
// "not a full lap". This puts such a lap on the same 1 m distance grid as a full lap, but only over the stretch it really covers:
//   - pit-road records at either end are left out (the pit lane is not the track);
//   - a lap that starts at the line keeps its time from the line (the same crossing rule as Resample); otherwise time 0 is
//     the first record on track;
//   - the stretch ends at the first jump (a reset or a tow: more than 60 m in one record) or at the lap's last record.
// CovA / CovB are the metres it covers. Outside them nothing is known: the corner metrics leave out any corner that is not
// wholly inside (and any figure whose window reaches outside: the brake point, the exit speed, the throttle pick-up), and the
// workbench channels are NaN there. A view is never Clean, never counted and never a reference.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace IRDash
{
    static partial class Analysis
    {
        internal const double PartialMinM = 200;       // under this the "lap" is a reset blip or a roll out of the box

        // the lap itself when it is full; its partial view otherwise (null = less than 200 m of it can be used)
        static LapTrace PartialOf(LapTrace lap)
        {
            if (lap == null) return null;
            if (lap.Tm != null) return lap;          // a whole lap (clean, or with a long off-track: skip "off") is itself, never cut down
            lock (gate) { if (lap.PDone) return lap.PView; }
            LapTrace v = null;
            try { v = BuildPartial(lap); }
            catch (Exception ex) { Log.W("partial: lap " + lap.Lap + " of " + lap.File + ": " + ex.Message); v = null; }
            lock (gate) { lap.PView = v; lap.PDone = true; }
            return v;
        }

        static LapTrace BuildPartial(LapTrace lap)
        {
            TrackMaps.Ibt t = TrackMaps.OpenIbt(lap.Path, true);
            if (t == null) return null;
            using (t.fs)
            {
                VarDef vSt = V(t, "SessionTime"), vPct = V(t, "LapDistPct"), vSpd = V(t, "Speed"), vBrk = V(t, "Brake"), vThr = V(t, "Throttle"), vPit = V(t, "OnPitRoad");
                if (vSt == null || vPct == null || vSpd == null) return null;
                int a = lap.RecA, b = (int)Math.Min((long)lap.RecB, t.records);
                if (b - a < 30) return null;
                int from = a > 0 ? a - 1 : a;
                long cnt = b - from;
                if (cnt <= 0 || cnt > 400000) return null;
                byte[] buf = new byte[cnt * t.bufLen];
                t.fs.Position = t.dataOff + (long)from * t.bufLen;
                int got = 0;
                while (got < buf.Length) { int r = t.fs.Read(buf, got, buf.Length - got); if (r <= 0) break; got += r; }
                int recs = got / t.bufLen;
                if (recs < 2) return null;
                double L = lap.LengthM;
                Func<int, double> st = delegate (int k) { return At(buf, k * t.bufLen, vSt); };
                Func<int, double> pc = delegate (int k) { return At(buf, k * t.bufLen, vPct); };
                Func<int, bool> pit = delegate (int k) { return vPit != null && At(buf, k * t.bufLen, vPit) != 0; };
                // pit road out of both ends: everything up to the LAST pit record of the first half, and from the FIRST pit record of the
                // second half (the first record of a drive can say "not on pit road" before the sim has set it: 08-36-50 lap 0)
                int ka = a - from, k0 = ka, k1 = recs - 1, mid = (ka + recs - 1) / 2;
                for (int k = ka; k <= mid; k++) if (pit(k)) k0 = k + 1;
                for (int k = recs - 1; k > mid; k--) if (pit(k)) k1 = k - 1;
                if (k1 - k0 < 30) return null;
                bool pre = k0 == ka && ka == 1 && st(ka) - st(0) < 0.5 && pc(0) > 0.8 && pc(ka) < 0.2;
                double t0 = st(k0);
                if (pre) { double p0 = pc(0), p1 = pc(ka), sp = (1 - p0) + p1, f = sp > 1e-6 ? (1 - p0) / sp : 1; t0 = st(0) + (st(ka) - st(0)) * Math.Max(0, Math.Min(1, f)); }
                List<Pt> pts = new List<Pt>();
                List<int> recOf = new List<int>();
                Func<int, double, double, Pt> mk = delegate (int k, double d, double tt)
                {
                    recOf.Add(from + k);
                    Pt p = new Pt(); p.D = d; p.T = tt; int o = k * t.bufLen;
                    p.Spd = (float)At(buf, o, vSpd); p.Brk = (float)At(buf, o, vBrk); p.Thr = (float)At(buf, o, vThr); return p;
                };
                double lastD = double.NegativeInfinity;
                if (pre) { pts.Add(mk(0, pc(0) * L - L, st(0) - t0)); pts.Add(mk(ka, 0, 0)); lastD = 0; }
                for (int k = k0; k <= k1; k++)
                {
                    double d = pc(k) * L, tt = st(k) - t0;
                    if (k > k0 && st(k) - st(k - 1) > 0.5) break;                          // a hole in the records
                    if (pts.Count > 0 && !double.IsNegativeInfinity(lastD) && d - lastD > 60)
                    {
                        // a reset or a tow: the stretch ends here, unless what came before it is too short to use (then it starts again here)
                        if (pts[pts.Count - 1].D - Math.Max(0, pts[pre ? 1 : 0].D) >= PartialMinM) break;
                        pts.Clear(); recOf.Clear(); pre = false; t0 = st(k); tt = 0; lastD = double.NegativeInfinity;
                    }
                    if (d <= lastD + 0.05 || d > L || tt < 0) continue;
                    if (pts.Count > 0 && tt + 1e-6 < pts[pts.Count - 1].T) continue;
                    pts.Add(mk(k, d, tt)); lastD = d;
                }
                int firstReal = pre ? 1 : 0;
                if (pts.Count - firstReal < 2) return null;
                double covA = Math.Max(0, pts[firstReal].D), covB = Math.Min(L, pts[pts.Count - 1].D);
                if (covB - covA < PartialMinM) return null;

                LapTrace v = new LapTrace();
                v.Path = lap.Path; v.File = lap.File; v.Car = lap.Car; v.Track = lap.Track; v.Config = lap.Config;
                v.Lap = lap.Lap; v.LengthM = L; v.Skip = lap.Skip.Length > 0 ? lap.Skip : "partial"; v.Clean = false;
                v.SectorAt = lap.SectorAt; v.SectorFrom = lap.SectorFrom; v.RecA = lap.RecA; v.RecB = lap.RecB;
                v.OffSamples = lap.OffSamples; v.OffAny = lap.OffAny;
                v.Partial = true; v.CovA = covA; v.CovB = covB; v.T0 = t0;
                v.Time = pts[pts.Count - 1].T; v.Computed = v.Time;
                v.PD = new double[pts.Count]; for (int i = 0; i < pts.Count; i++) v.PD[i] = pts[i].D;
                v.PRec = recOf.ToArray();
                int m = (int)Math.Round(L); if (m < 10) m = 10;
                v.Metres = m;
                v.Tm = new double[m]; v.Spd = new float[m]; v.Brk = new float[m]; v.Thr = new float[m];
                for (int i = 0; i < m; i++)
                {
                    double tt, sp, bk, th; Lerp(pts, i, out tt, out sp, out bk, out th);       // outside the stretch: held at its ends (never read: see the metrics)
                    v.Tm[i] = tt; v.Spd[i] = (float)sp; v.Brk[i] = (float)bk; v.Thr[i] = (float)th;
                }
                for (int i = 1; i < m; i++) if (v.Tm[i] < v.Tm[i - 1]) v.Tm[i] = v.Tm[i - 1];
                for (int i = 0; i < m; i++) { if (v.Tm[i] < 0) v.Tm[i] = 0; if (v.Tm[i] > v.Time) v.Tm[i] = v.Time; }
                return v;
            }
        }

        // the corners wholly inside the stretch, measured exactly like a full lap's; a figure whose window reaches outside is left out
        static void MeasurePartial(LapTrace v, CornerSet cs)
        {
            if (v == null || v.Measured) return;
            if (!v.Partial) { Measure(v, cs); return; }
            v.Measured = true; v.Corners = new List<Met>(); v.Straights = new List<double>();
            if (cs == null || cs.Turns == null) return;
            double L = v.LengthM;
            for (int ti = 0; ti < cs.Turns.Count; ti++)
            {
                CornerTurn tn = cs.Turns[ti];
                if (tn.P1 < tn.P0) continue;                                  // a corner across the line
                double d0 = tn.P0 * L, da = tn.Pa * L, d1 = tn.P1 * L;
                if (d0 < v.CovA + 1 || d1 > v.CovB - 1) continue;
                Met mt = MeasureOne(v, tn, ti > 0 ? cs.Turns[ti - 1].Pa : cs.Turns[cs.Turns.Count - 1].Pa);
                if (da - 330 < v.CovA) mt.HasBrake = false;                  // the brake search looks 250 m (+80) back from the apex
                if (da + 100 > v.CovB) mt.HasExit = false;
                if (mt.HasPickup && mt.Pickup > v.CovB) mt.HasPickup = false;
                v.Corners.Add(mt);
            }
        }

        // the workbench channels of a partial view on the full-lap grid (n samples): NaN outside the stretch it covers, never a guess
        static float[][] PartialChannels(LapTrace v, List<Chan> chans, int n, bool meta)
        {
            int nc = chans.Count;
            float[][] outp = new float[nc][];
            for (int c = 0; c < nc; c++) { outp[c] = new float[n]; for (int i = 0; i < n; i++) outp[c][i] = float.NaN; }
            if (nc == 0 || v.PD == null || v.PRec == null || v.PD.Length < 2) return outp;
            TrackMaps.Ibt t = TrackMaps.OpenIbt(v.Path, true);
            if (t == null) return outp;
            using (t.fs)
            {
                if (meta) ReadMeta(t, chans);
                VarDef[] defs = new VarDef[nc]; int[] off = new int[nc]; bool[] step = new bool[nc];
                for (int c = 0; c < nc; c++)
                {
                    VarDef d = V(t, chans[c].Name);
                    if (d == null || chans[c].Index < 0 || chans[c].Index >= Math.Max(1, d.Count)) continue;
                    defs[c] = d; off[c] = d.Offset + chans[c].Index * TypeSize(d.Type); step[c] = d.Type < 4;
                    if (meta) chans[c].Ok = true;
                }
                int r0 = int.MaxValue, r1 = -1;
                foreach (int r in v.PRec) { if (r < r0) r0 = r; if (r > r1) r1 = r; }
                long cnt = (long)r1 - r0 + 1;
                if (r0 < 0 || cnt <= 0 || cnt > 400000) return outp;
                byte[] buf = new byte[cnt * t.bufLen];
                t.fs.Position = t.dataOff + (long)r0 * t.bufLen;
                int got = 0;
                while (got < buf.Length) { int rd = t.fs.Read(buf, got, buf.Length - got); if (rd <= 0) break; got += rd; }
                int recs = got / t.bufLen;
                double L = v.LengthM; int m = n - 1, np = v.PD.Length;
                for (int c = 0; c < nc; c++)
                {
                    if (defs[c] == null) continue;
                    float[] val = new float[np]; bool[] have = new bool[np];
                    for (int p = 0; p < np; p++) { int k = v.PRec[p] - r0; if (k >= 0 && k < recs) { val[p] = (float)(Read(buf, k * t.bufLen + off[c], defs[c].Type) - chans[c].Bias); have[p] = true; } }
                    float[] g = outp[c];
                    int j = 0;
                    for (int i = 0; i < n; i++)
                    {
                        double d = i >= m ? L : i * L / m;
                        if (d < v.CovA - 1e-6 || d > v.CovB + 1e-6) continue;      // not driven: stays NaN
                        while (j + 1 < np && v.PD[j + 1] <= d) j++;
                        if (!have[j]) continue;
                        if (j + 1 >= np || d <= v.PD[j] || step[c] || !have[j + 1]) { g[i] = val[j]; continue; }
                        double span = v.PD[j + 1] - v.PD[j], f = span > 1e-9 ? (d - v.PD[j]) / span : 0;
                        g[i] = (float)(val[j] + (val[j + 1] - val[j]) * f);
                    }
                }
            }
            return outp;
        }

        static string CoverText(LapTrace v)
        {
            if (v == null || !v.Partial || v.LengthM <= 0) return "";
            return "covers " + Math.Round(v.CovA / v.LengthM * 100).ToString(Inv) + "-" + Math.Round(v.CovB / v.LengthM * 100).ToString(Inv) + " % of the lap";
        }

        static void AppendCover(System.Text.StringBuilder sb, LapTrace v)
        {
            sb.Append("{\"fromPct\":").Append(F(v.CovA / v.LengthM, "0.0000")).Append(",\"toPct\":").Append(F(v.CovB / v.LengthM, "0.0000"))
              .Append(",\"fromM\":").Append(F(v.CovA, "0.0")).Append(",\"toM\":").Append(F(v.CovB, "0.0")).Append(",\"time\":").Append(F(v.Time, "0.000"))
              .Append(",\"skip\":").Append(Json_.S(v.Skip)).Append(",\"text\":").Append(Json_.S("partial: " + CoverText(v))).Append('}');
        }
    }
}
