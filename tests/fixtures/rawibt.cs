using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

// Independent .ibt reader + corner recompute for the data-truth audit. Own header parse, own maths.
public class RawIbt
{
    public static CultureInfo Inv = CultureInfo.InvariantCulture;
    public int bufLen, nVars, varOff, dataOff, records, tickRate, yamlOff, yamlLen;
    public long startDate; public double startTime, endTime; public int lapCount;
    public string yaml;
    public Dictionary<string, int[]> vars = new Dictionary<string, int[]>();   // name -> {type, offset, count}
    public Dictionary<string, double[]> ch = new Dictionary<string, double[]>();
    public double L;

    public static RawIbt Open(string path, string[] want)
    {
        RawIbt r = new RawIbt();
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            byte[] h = new byte[144]; fs.Read(h, 0, 144);
            r.tickRate = BitConverter.ToInt32(h, 8); r.yamlLen = BitConverter.ToInt32(h, 16); r.yamlOff = BitConverter.ToInt32(h, 20);
            r.nVars = BitConverter.ToInt32(h, 24); r.varOff = BitConverter.ToInt32(h, 28); r.bufLen = BitConverter.ToInt32(h, 36); r.dataOff = BitConverter.ToInt32(h, 52);
            r.startDate = BitConverter.ToInt64(h, 112); r.startTime = BitConverter.ToDouble(h, 120); r.endTime = BitConverter.ToDouble(h, 128);
            r.lapCount = BitConverter.ToInt32(h, 136); r.records = BitConverter.ToInt32(h, 140);
            byte[] y = new byte[r.yamlLen]; fs.Position = r.yamlOff; fs.Read(y, 0, y.Length); r.yaml = Encoding.GetEncoding(1252).GetString(y);
            byte[] vh = new byte[r.nVars * 144]; fs.Position = r.varOff; fs.Read(vh, 0, vh.Length);
            for (int i = 0; i < r.nVars; i++)
            {
                int o = i * 144; int type = BitConverter.ToInt32(vh, o), off = BitConverter.ToInt32(vh, o + 4), cnt = BitConverter.ToInt32(vh, o + 8);
                int e = o + 16; int z = 0; while (z < 32 && vh[e + z] != 0) z++;
                r.vars[Encoding.ASCII.GetString(vh, e, z)] = new int[] { type, off, cnt };
            }
            long size = fs.Length; int recs = (int)Math.Min((long)r.records, (size - r.dataOff) / r.bufLen);
            r.records = recs;
            foreach (string w in want) if (r.vars.ContainsKey(w)) r.ch[w] = new double[recs];
            byte[] buf = new byte[r.bufLen * 4096]; fs.Position = r.dataOff;
            int done = 0;
            while (done < recs)
            {
                int n = Math.Min(4096, recs - done); int got = 0;
                while (got < n * r.bufLen) { int k = fs.Read(buf, got, n * r.bufLen - got); if (k <= 0) break; got += k; }
                n = got / r.bufLen; if (n == 0) break;
                foreach (KeyValuePair<string, double[]> kv in r.ch)
                {
                    int[] v = r.vars[kv.Key];
                    for (int i = 0; i < n; i++)
                    {
                        int p = i * r.bufLen + v[1]; double val = 0;
                        switch (v[0]) { case 0: case 1: val = buf[p]; break; case 2: case 3: val = BitConverter.ToInt32(buf, p); break; case 4: val = BitConverter.ToSingle(buf, p); break; case 5: val = BitConverter.ToDouble(buf, p); break; }
                        kv.Value[done + i] = val;
                    }
                }
                done += n;
            }
        }
        Match m = Regex.Match(r.yaml, @"TrackLength:\s*([\d.]+)\s*(km|mi)");
        if (m.Success) r.L = double.Parse(m.Groups[1].Value, Inv) * (m.Groups[2].Value == "mi" ? 1609.344 : 1000);
        return r;
    }

    public class Lap
    {
        public int Num; public int A, B;       // record range [A,B)
        public double T0, T1, Time;            // crossing times (interpolated), lap time
        public double Official = -1;           // LapLastLapTime 1.5-2.5 s after the end
        public bool Full, Pit, OffAny; public int Off;
        public double[] D, T, S, Br, Th;       // per-record distance m, time s from T0, speed m/s, brake, throttle
    }

    // laps from the LapDistPct wrap, not from the Lap channel
    public List<Lap> Laps()
    {
        double[] pct = ch["LapDistPct"], st = ch["SessionTime"], lap = ch["Lap"], spd = ch["Speed"], brk = ch["Brake"], thr = ch["Throttle"];
        double[] pit = ch.ContainsKey("OnPitRoad") ? ch["OnPitRoad"] : null, surf = ch.ContainsKey("PlayerTrackSurface") ? ch["PlayerTrackSurface"] : null, llt = ch["LapLastLapTime"];
        List<int> wraps = new List<int>();
        for (int i = 1; i < records; i++) if (pct[i - 1] > 0.9 && pct[i] < 0.1 && st[i] - st[i - 1] < 0.5) wraps.Add(i);
        List<Lap> res = new List<Lap>();
        List<double> cross = new List<double>();
        foreach (int w in wraps) { double p0 = pct[w - 1], p1 = pct[w]; double f = (1 - p0) / ((1 - p0) + p1); cross.Add(st[w - 1] + (st[w] - st[w - 1]) * f); }
        for (int k = 0; k + 1 < wraps.Count; k++)
        {
            Lap l = new Lap(); l.A = wraps[k]; l.B = wraps[k + 1]; l.T0 = cross[k]; l.T1 = cross[k + 1]; l.Time = l.T1 - l.T0; l.Num = (int)lap[l.A];
            bool contiguous = true; for (int i = l.A + 1; i < l.B; i++) if (st[i] - st[i - 1] > 0.5) { contiguous = false; break; }
            l.Full = contiguous;
            for (int i = l.A; i < l.B; i++) { if (pit != null && pit[i] != 0) l.Pit = true; if (surf != null && surf[i] == 0) l.Off++; }
            l.OffAny = l.Off > 0;
            // announced time: median LapLastLapTime 1.5..2.5 s after the end crossing
            List<double> v = new List<double>();
            for (int i = l.B; i < records && st[i] < l.T1 + 2.5; i++) if (st[i] >= l.T1 + 1.5) v.Add(llt[i]);
            if (v.Count > 0) { v.Sort(); l.Official = v[v.Count / 2]; }
            int n = l.B - l.A; l.D = new double[n]; l.T = new double[n]; l.S = new double[n]; l.Br = new double[n]; l.Th = new double[n];
            for (int i = 0; i < n; i++) { l.D[i] = pct[l.A + i] * L; l.T[i] = st[l.A + i] - l.T0; l.S[i] = spd[l.A + i]; l.Br[i] = brk[l.A + i]; l.Th[i] = thr[l.A + i]; }
            res.Add(l);
        }
        return res;
    }

    // value of series v at distance d (m) on the lap (linear between records, d monotone)
    public static double At(Lap l, double[] v, double d)
    {
        int n = l.D.Length;
        if (d <= l.D[0]) return v[0];
        if (d >= l.D[n - 1]) return v[n - 1];
        int lo = 0, hi = n - 1;
        while (lo + 1 < hi) { int mid = (lo + hi) / 2; if (l.D[mid] <= d) lo = mid; else hi = mid; }
        double span = l.D[hi] - l.D[lo]; double f = span > 1e-9 ? (d - l.D[lo]) / span : 0;
        return v[lo] + (v[hi] - v[lo]) * f;
    }

    public class Corner { public int N; public string Label; public double P0, Pa, P1; }

    public class Res
    {
        public double Time, In, Out, Entry, Min, MinM, Exit, Pickup, BrakeMain, BrakeFirst, BrakeLast, BrakePeak;
        public bool HasBrake, HasPickup; public double Peak;
    }

    // recompute one corner on one lap, from the raw records
    public Res Measure(Lap l, Corner c, double scale)
    {
        Res r = new Res(); double d0 = c.P0 * L, da = c.Pa * L, d1 = c.P1 * L;
        r.Time = (At(l, l.T, d1) - At(l, l.T, d0)) * scale; r.In = (At(l, l.T, da) - At(l, l.T, d0)) * scale; r.Out = (At(l, l.T, d1) - At(l, l.T, da)) * scale;
        r.Entry = At(l, l.S, d0) * 3.6; r.Exit = At(l, l.S, da + 100) * 3.6;
        double best = 1e9, at = d0;
        for (int i = 0; i < l.D.Length; i++) if (l.D[i] >= d0 && l.D[i] <= d1 && l.S[i] < best) { best = l.S[i]; at = l.D[i]; }
        r.Min = best * 3.6; r.MinM = at;
        // throttle pick-up: first crossing of 0.90 after the apex, within 200 m
        r.HasPickup = false;
        for (int i = 1; i < l.D.Length; i++)
        {
            if (l.D[i] <= da || l.D[i] > da + 200) continue;
            if (l.Th[i] > 0.9 && l.Th[i - 1] <= 0.9 || (l.Th[i] > 0.9 && l.D[i - 1] <= da))
            { double f = (0.9 - l.Th[i - 1]) / (l.Th[i] - l.Th[i - 1] + 1e-12); r.Pickup = l.D[i]; r.HasPickup = true; break; }
        }
        // braking applications (>0.10) in the 250 m before the apex, from raw records
        double w0 = da - 250; double areaBest = 0, peakBest = 0; r.HasBrake = false; double first = -1, last = -1;
        bool on = false; double start = 0, area = 0, peak = 0;
        for (int i = 0; i < l.D.Length; i++)
        {
            if (l.D[i] < w0 - 80 || l.D[i] > da) continue;
            bool b = l.Br[i] > 0.10;
            if (b && !on)
            {
                on = true; area = 0; peak = 0;
                if (i > 0) { double f = (0.10 - l.Br[i - 1]) / (l.Br[i] - l.Br[i - 1] + 1e-12); start = l.D[i - 1] + (l.D[i] - l.D[i - 1]) * f; } else start = l.D[i];
            }
            if (b) { area += l.Br[i] * (i > 0 ? (l.D[i] - l.D[i - 1]) : 0); if (l.Br[i] > peak) peak = l.Br[i]; }
            bool endNow = !b || i == l.D.Length - 1 || l.D[i] >= da;
            if (on && endNow)
            {
                on = false;
                if (!b || l.D[i] >= da)
                {
                    double endD = l.D[i];
                    if (endD >= w0)   // application touches the window
                    {
                        double s = Math.Max(start, w0 - 80);
                        if (first < 0) first = start; last = start;
                        if (area > areaBest) { areaBest = area; r.BrakeMain = start; r.HasBrake = true; }
                        if (peak > peakBest + 1e-9) { peakBest = peak; r.BrakePeak = start; }
                    }
                }
            }
        }
        r.BrakeFirst = first; r.BrakeLast = last; r.Peak = peakBest;
        return r;
    }
}
