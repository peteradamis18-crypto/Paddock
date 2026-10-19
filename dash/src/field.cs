// RACE FIELD (card W6; docs\DESIGN-workbench.md 2.5 and 3 "RACE"): the .ibt files only hold Peter's own car, so while a session with other cars
// runs Paddock logs every car itself.
//   - A BelowNormal thread (RaceField.Run) takes one sample every 0.1 s of SIM time (10 Hz, whatever the frame rate) of the CarIdx arrays
//     (LapDistPct, Lap, LapCompleted, Position, ClassPosition, OnPitRoad, TrackSurface, LastLapTime) and the session text (who is who).
//     It only READS irdash's own latest frame (Sdk.Latest): nothing is ever sent to the sim, no file of iRacing is touched.
//   - From the samples it keeps EVENTS per car: line crossings (time interpolated by distance between two samples; the sim's own LastLapTime is
//     attached when it is there, so a lap time says whether it is "sim" or "derived"), corner-boundary crossings (the corner list the workbench
//     already holds for the track), pit road in / out and the time in the stall (TrackSurface 1), off-track excursions, retirements and, in a race,
//     on-track passes (two cars of one class swap places while both are on track).
//   - Laps, positions, gaps and the rest are worked out from those events (RfData.Snapshot), written as ONE compact JSON per session to
//     <vault>\field\f<yyyyMMdd-HHmmss>-<session number>.json at every leader lap and at session end (a crash loses at most one lap).
//   - /analysis/race?id=<field id | .ibt file name | vault lap id> returns that file plus the race summary (RfSummary): final order, gap to the
//     leader by lap, position by lap, per-corner medians (Peter vs the car ahead / the leader), passes.
//   - Precision, honestly: a time is the interpolation between two 10 Hz samples. In the pretend race of tests\race-field-test.ps1 the error is
//     under 0.002 s; the page states +-0.02 s per lap because the real sim's other cars come from its network feed. The pit lane time and the lap-1
//     start of a standing start are good to the sample step, 0.1 s.
// Test hook (only while dash\test-hook.on exists): /api/test/field?on=1[&ms=<utc ms of the session start>] lets the sampler log a PRETEND session
// (it ignores them otherwise), /api/test/fieldyaml?name= loads a session text from vault-test\, /field/status has the counters and the sampler's CPU.
// Owned by the W6 card; irdash.cs only calls Init / Start / Route.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static partial class Analysis
    {
        // the corner list for the field (same rules as the workbench: the disk copy of Lovely's list, no GitHub fetch while a session runs)
        internal static CornerSet FieldCorners(string track, string trackName, string config, string trackId)
        {
            Sess s = new Sess(); s.Track = track; s.TrackName = trackName; s.Config = config; s.TrackId = trackId; s.Key = TrackMaps.MakeKey(trackId, trackName);
            return LoadCorners(s);
        }
    }

    // ================================================================================================================
    // The stored model (what the file holds and what the endpoint reads back)
    // ================================================================================================================
    sealed class RfCorner { public int N; public string Lab = "", Name = "", Official = ""; public double P0, Pa, P1; }

    sealed class RfLap
    {
        public int N, Pos, CPos, Off;
        public double S = double.NaN, E = double.NaN, Sim = -1;       // start / end line-crossing times (session seconds), the sim's own lap time (-1 = not seen)
        public bool In, Out, GreenStart;                               // pit road entered / left during this lap; the start is the green flag (standing start), not a crossing
        public int[] X;                                                // corner boundary times in ms after S (-1 = not seen); null when S is not known
        public double Dur { get { return !double.IsNaN(S) && !double.IsNaN(E) ? E - S : double.NaN; } }
        // the time we show: the sim's own when it was seen, else the difference of the two line crossings
        public double Time { get { return Sim > 0 ? Sim : Dur; } }
        public string Src { get { return Sim > 0 ? "sim" : !double.IsNaN(Dur) ? (GreenStart ? "green" : "derived") : ""; } }
    }

    sealed class RfPit { public int InLap, OutLap; public double TIn, TOut = double.NaN, Stall; }
    sealed class RfPass { public double T, Pct; public int Lap, By, Over; public string Where = ""; }

    sealed class RfCar
    {
        public int Idx, IR, FinalPos, FinalCPos, ResPos, ResLaps, ResInc, ResBestLap, Off;
        public string Num = "", Name = "", Team = "", Car = "", Cls = "", ClsName = "", Color = "", Lic = "", Reason = "";
        public string Path = "", Design = "";                          // P4: iRacing's CarPath and the livery "pattern,colour1,colour2,colour3" (hex); "" in a log from before P4 -> the page paints the class colour
        public bool Me, Gone, Finished;
        public double GoneT = double.NaN, ResBest = -1, OffS, BestSim = -1;
        public List<RfLap> Laps = new List<RfLap>();
        public List<RfPit> Pits = new List<RfPit>();
    }

    sealed class RfData
    {
        public string Id = "", Track = "", Config = "", TrackName = "", TrackId = "", Key = "", SessType = "", SessName = "", SessLaps = "", CornerSrc = "";
        public long StartMs, EndMs;
        public double LengthM, GreenT = double.NaN, FlagT = double.NaN, T0, EndT;
        public int SessNum, Me = -1, Samples;
        public int MeInc = -1;                                         // his own incident count (PlayerCarMyIncidentCount) at the end of the log; -1 = a log from before it was kept (the sim's results text often says 0)
        public bool Official, Complete;
        public bool IsRace { get { return Regex.IsMatch(SessType ?? "", "race", RegexOptions.IgnoreCase); } }
        public List<RfCorner> Corners = new List<RfCorner>();
        public List<RfCar> Cars = new List<RfCar>();
        public List<RfPass> Passes = new List<RfPass>();

        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public static string N(double d, string f) { return double.IsNaN(d) || double.IsInfinity(d) ? "null" : d.ToString(f, Inv); }
        public static string B(bool b) { return b ? "1" : "0"; }

        public RfCar Car(int idx) { foreach (RfCar c in Cars) if (c.Idx == idx) return c; return null; }

        // withX: the raw corner times too (the file always has them; the endpoint leaves them out unless asked: the summary holds the medians)
        public string ToJson(bool withX, string summary, bool ok)
        {
            StringBuilder sb = new StringBuilder(8192);
            sb.Append('{');
            if (ok) sb.Append("\"ok\":true,");
            sb.Append("\"v\":1,\"id\":").Append(Json_.S(Id)).Append(",\"startMs\":").Append(StartMs).Append(",\"endMs\":").Append(EndMs)
              .Append(",\"track\":").Append(Json_.S(Track)).Append(",\"config\":").Append(Json_.S(Config)).Append(",\"trackName\":").Append(Json_.S(TrackName))
              .Append(",\"trackId\":").Append(Json_.S(TrackId)).Append(",\"key\":").Append(Json_.S(Key)).Append(",\"lengthM\":").Append(N(LengthM, "0.0"))
              .Append(",\"sessNum\":").Append(SessNum).Append(",\"sessType\":").Append(Json_.S(SessType)).Append(",\"sessName\":").Append(Json_.S(SessName))
              .Append(",\"sessLaps\":").Append(Json_.S(SessLaps)).Append(",\"official\":").Append(B(Official)).Append(",\"isRace\":").Append(B(IsRace))
              .Append(",\"me\":").Append(Me).Append(",\"t0\":").Append(N(T0, "0.000")).Append(",\"endT\":").Append(N(EndT, "0.000"))
              .Append(",\"greenT\":").Append(N(GreenT, "0.000")).Append(",\"flagT\":").Append(N(FlagT, "0.000")).Append(",\"samples\":").Append(Samples)
              .Append(",\"mi\":").Append(MeInc).Append(",\"complete\":").Append(B(Complete)).Append(",\"cornerSrc\":").Append(Json_.S(CornerSrc));
            sb.Append(",\"corners\":[");
            for (int i = 0; i < Corners.Count; i++)
            {
                RfCorner c = Corners[i]; if (i > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(c.N).Append(",\"lab\":").Append(Json_.S(c.Lab)).Append(",\"name\":").Append(Json_.S(c.Name)).Append(",\"official\":").Append(Json_.S(c.Official))
                  .Append(",\"p0\":").Append(N(c.P0, "0.00000")).Append(",\"pa\":").Append(N(c.Pa, "0.00000")).Append(",\"p1\":").Append(N(c.P1, "0.00000")).Append('}');
            }
            sb.Append("],\"cars\":[");
            for (int i = 0; i < Cars.Count; i++)
            {
                RfCar c = Cars[i]; if (i > 0) sb.Append(',');
                sb.Append("{\"i\":").Append(c.Idx).Append(",\"num\":").Append(Json_.S(c.Num)).Append(",\"name\":").Append(Json_.S(c.Name)).Append(",\"team\":").Append(Json_.S(c.Team))
                  .Append(",\"car\":").Append(Json_.S(c.Car)).Append(",\"cls\":").Append(Json_.S(c.Cls)).Append(",\"cn\":").Append(Json_.S(c.ClsName)).Append(",\"col\":").Append(Json_.S(c.Color))
                  .Append(",\"path\":").Append(Json_.S(c.Path)).Append(",\"dz\":").Append(Json_.S(c.Design))
                  .Append(",\"ir\":").Append(c.IR).Append(",\"lic\":").Append(Json_.S(c.Lic)).Append(",\"me\":").Append(B(c.Me))
                  .Append(",\"gone\":").Append(B(c.Gone)).Append(",\"goneT\":").Append(N(c.GoneT, "0.000")).Append(",\"fin\":").Append(B(c.Finished))
                  .Append(",\"fp\":").Append(c.FinalPos).Append(",\"fcp\":").Append(c.FinalCPos)
                  .Append(",\"rp\":").Append(c.ResPos).Append(",\"rl\":").Append(c.ResLaps).Append(",\"ri\":").Append(c.ResInc).Append(",\"rbl\":").Append(c.ResBestLap)
                  .Append(",\"rb\":").Append(c.ResBest > 0 ? N(c.ResBest, "0.0000") : "null").Append(",\"rs\":").Append(Json_.S(c.Reason))
                  .Append(",\"off\":").Append(c.Off).Append(",\"offS\":").Append(N(c.OffS, "0.0")).Append(",\"bs\":").Append(c.BestSim > 0 ? N(c.BestSim, "0.0000") : "null");
                sb.Append(",\"L\":[");
                for (int j = 0; j < c.Laps.Count; j++)
                {
                    RfLap l = c.Laps[j]; if (j > 0) sb.Append(',');
                    sb.Append('[').Append(l.N).Append(',').Append(N(l.S, "0.000")).Append(',').Append(N(l.E, "0.000")).Append(',').Append(l.Sim > 0 ? N(l.Sim, "0.0000") : "null").Append(',').Append(l.Pos).Append(',').Append(l.CPos)
                      .Append(',').Append((l.In ? 1 : 0) | (l.Out ? 2 : 0) | (l.GreenStart ? 4 : 0)).Append(',').Append(l.Off);
                    if (withX && l.X != null) { sb.Append(",["); for (int k = 0; k < l.X.Length; k++) { if (k > 0) sb.Append(','); sb.Append(l.X[k]); } sb.Append(']'); }
                    sb.Append(']');
                }
                sb.Append("],\"P\":[");
                for (int j = 0; j < c.Pits.Count; j++)
                {
                    RfPit p = c.Pits[j]; if (j > 0) sb.Append(',');
                    sb.Append('[').Append(p.InLap).Append(',').Append(p.OutLap).Append(',').Append(N(p.TIn, "0.000")).Append(',').Append(N(p.TOut, "0.000")).Append(',').Append(N(p.Stall, "0.0")).Append(']');
                }
                sb.Append("]}");
            }
            sb.Append("],\"passes\":[");
            for (int i = 0; i < Passes.Count; i++)
            {
                RfPass p = Passes[i]; if (i > 0) sb.Append(',');
                sb.Append("{\"t\":").Append(N(p.T, "0.000")).Append(",\"lap\":").Append(p.Lap).Append(",\"pct\":").Append(N(p.Pct, "0.0000")).Append(",\"by\":").Append(p.By).Append(",\"over\":").Append(p.Over)
                  .Append(",\"where\":").Append(Json_.S(p.Where)).Append('}');
            }
            sb.Append(']');
            if (summary != null) sb.Append(",\"summary\":").Append(summary);
            sb.Append('}');
            return sb.ToString();
        }

        // ---- reading a file back ----
        static double Dn(object o) { double v; return o != null && double.TryParse(Convert.ToString(o, Inv), NumberStyles.Float, Inv, out v) ? v : double.NaN; }
        static int In(object o) { double v = Dn(o); return double.IsNaN(v) ? 0 : (int)Math.Round(v); }
        static string Sn(object o) { return o == null ? "" : Convert.ToString(o, Inv); }
        static object G(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) ? o : null; }
        static object[] A(object o) { return o as object[] ?? (o is System.Collections.ArrayList ? ((System.Collections.ArrayList)o).ToArray() : new object[0]); }

        public static RfData FromJson(string json)
        {
            JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue;
            Dictionary<string, object> d = js.DeserializeObject(json) as Dictionary<string, object>;
            if (d == null) return null;
            RfData r = new RfData();
            r.Id = Sn(G(d, "id")); r.StartMs = (long)Dn(G(d, "startMs")); r.EndMs = (long)Dn(G(d, "endMs")); r.Track = Sn(G(d, "track")); r.Config = Sn(G(d, "config")); r.TrackName = Sn(G(d, "trackName"));
            r.TrackId = Sn(G(d, "trackId")); r.Key = Sn(G(d, "key")); r.LengthM = Dn(G(d, "lengthM")); r.SessNum = In(G(d, "sessNum")); r.SessType = Sn(G(d, "sessType")); r.SessName = Sn(G(d, "sessName"));
            r.SessLaps = Sn(G(d, "sessLaps")); r.Official = In(G(d, "official")) != 0; r.Me = In(G(d, "me")); r.T0 = Dn(G(d, "t0")); r.EndT = Dn(G(d, "endT")); r.GreenT = Dn(G(d, "greenT")); r.FlagT = Dn(G(d, "flagT"));
            r.Samples = In(G(d, "samples")); r.MeInc = d.ContainsKey("mi") ? In(G(d, "mi")) : -1; r.Complete = In(G(d, "complete")) != 0; r.CornerSrc = Sn(G(d, "cornerSrc"));
            foreach (object o in A(G(d, "corners")))
            {
                Dictionary<string, object> c = o as Dictionary<string, object>; if (c == null) continue;
                RfCorner k = new RfCorner(); k.N = In(G(c, "n")); k.Lab = Sn(G(c, "lab")); k.Name = Sn(G(c, "name")); k.Official = Sn(G(c, "official")); k.P0 = Dn(G(c, "p0")); k.Pa = Dn(G(c, "pa")); k.P1 = Dn(G(c, "p1"));
                r.Corners.Add(k);
            }
            foreach (object o in A(G(d, "cars")))
            {
                Dictionary<string, object> c = o as Dictionary<string, object>; if (c == null) continue;
                RfCar k = new RfCar(); k.Idx = In(G(c, "i")); k.Num = Sn(G(c, "num")); k.Name = Sn(G(c, "name")); k.Team = Sn(G(c, "team")); k.Car = Sn(G(c, "car")); k.Cls = Sn(G(c, "cls")); k.ClsName = Sn(G(c, "cn"));
                k.Color = Sn(G(c, "col")); k.Path = Sn(G(c, "path")); k.Design = Sn(G(c, "dz")); k.IR = In(G(c, "ir")); k.Lic = Sn(G(c, "lic")); k.Me = In(G(c, "me")) != 0; k.Gone = In(G(c, "gone")) != 0; k.GoneT = Dn(G(c, "goneT")); k.Finished = In(G(c, "fin")) != 0;
                k.FinalPos = In(G(c, "fp")); k.FinalCPos = In(G(c, "fcp")); k.ResPos = In(G(c, "rp")); k.ResLaps = In(G(c, "rl")); k.ResInc = In(G(c, "ri")); k.ResBestLap = In(G(c, "rbl"));
                double rb = Dn(G(c, "rb")); k.ResBest = double.IsNaN(rb) ? -1 : rb; k.Reason = Sn(G(c, "rs")); k.Off = In(G(c, "off")); k.OffS = Dn(G(c, "offS")); if (double.IsNaN(k.OffS)) k.OffS = 0; double bsv = Dn(G(c, "bs")); k.BestSim = double.IsNaN(bsv) ? -1 : bsv;
                foreach (object lo in A(G(c, "L")))
                {
                    object[] a = A(lo); if (a.Length < 8) continue;
                    RfLap l = new RfLap(); l.N = In(a[0]); l.S = Dn(a[1]); l.E = Dn(a[2]); double sm = Dn(a[3]); l.Sim = double.IsNaN(sm) ? -1 : sm; l.Pos = In(a[4]); l.CPos = In(a[5]);
                    int fl = In(a[6]); l.In = (fl & 1) != 0; l.Out = (fl & 2) != 0; l.GreenStart = (fl & 4) != 0; l.Off = In(a[7]);
                    if (a.Length > 8) { object[] xs = A(a[8]); l.X = new int[xs.Length]; for (int q = 0; q < xs.Length; q++) l.X[q] = In(xs[q]); }
                    k.Laps.Add(l);
                }
                foreach (object po in A(G(c, "P")))
                {
                    object[] a = A(po); if (a.Length < 5) continue;
                    RfPit p = new RfPit(); p.InLap = In(a[0]); p.OutLap = In(a[1]); p.TIn = Dn(a[2]); p.TOut = Dn(a[3]); p.Stall = Dn(a[4]); if (double.IsNaN(p.Stall)) p.Stall = 0; k.Pits.Add(p);
                }
                r.Cars.Add(k);
            }
            foreach (object o in A(G(d, "passes")))
            {
                Dictionary<string, object> c = o as Dictionary<string, object>; if (c == null) continue;
                RfPass p = new RfPass(); p.T = Dn(G(c, "t")); p.Lap = In(G(c, "lap")); p.Pct = Dn(G(c, "pct")); p.By = In(G(c, "by")); p.Over = In(G(c, "over")); p.Where = Sn(G(c, "where")); r.Passes.Add(p);
            }
            return r;
        }
    }

    // ================================================================================================================
    // The race summary: everything the RACE page shows, worked out from the stored model (so a file from last week gives the same answer)
    // ================================================================================================================
    static class RfSummary
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public const double CornerPrecision = 0.02;      // seconds, per lap, per corner: what the page says (see the header of this file)

        sealed class Row
        {
            public RfCar C; public int Laps, Pos, CPos, GapLaps, AheadLaps, Pits; public double LastE = double.NaN, Total = double.NaN, Best = -1, Gap = double.NaN, Ahead = double.NaN, PitS, StallS;
            public int BestLap; public string BestSrc = ""; public bool Fastest;
            public Dictionary<int, RfLap> ByLap = new Dictionary<int, RfLap>();
        }

        static string N(double d, string f) { return RfData.N(d, f); }
        static double Median(List<double> v)
        {
            if (v.Count == 0) return double.NaN;
            List<double> s = new List<double>(v); s.Sort(); int n = s.Count;
            return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
        }

        // a lap that is good for comparing pace: a full racing lap (not the start lap of a race, not a pit lap, not an off-track lap)
        static bool Clean(RfLap l, bool race)
        {
            if (l.In || l.Out || l.Off > 0 || double.IsNaN(l.Dur) || l.Dur < 15) return false;
            if (race && l.N < 2) return false;
            return true;
        }

        public static string Where(List<RfCorner> cs, double pct)
        {
            if (cs.Count == 0 || double.IsNaN(pct)) return "";
            double m = 0.002;
            foreach (RfCorner c in cs)
            {
                bool inside = c.P0 <= c.P1 ? (pct >= c.P0 - m && pct <= c.P1 + m) : (pct >= c.P0 - m || pct <= c.P1 + m);
                if (inside) return c.Lab;
            }
            RfCorner prev = null;
            foreach (RfCorner c in cs) if (c.P0 <= c.P1 && c.P1 <= pct && (prev == null || c.P1 > prev.P1)) prev = c;
            return prev == null ? "start/finish straight" : "after " + prev.Lab;
        }

        public static string Build(RfData d)
        {
            bool race = d.IsRace;
            List<Row> rows = new List<Row>();
            foreach (RfCar c in d.Cars)
            {
                Row r = new Row(); r.C = c;
                foreach (RfLap l in c.Laps) { r.ByLap[l.N] = l; if (!double.IsNaN(l.E) && l.N > r.Laps) { r.Laps = l.N; r.LastE = l.E; } }
                RfLap first; if (r.ByLap.TryGetValue(1, out first) && !double.IsNaN(first.S) && !double.IsNaN(r.LastE)) r.Total = r.LastE - first.S;
                // best lap: the sim's own figure from the results text when it gave one, else the quickest racing lap we timed (a standing-start lap 1 is only taken when the sim timed it)
                if (c.ResBest > 15) { r.Best = c.ResBest; r.BestLap = c.ResBestLap; r.BestSrc = "sim"; }
                else if (c.BestSim > 15) { r.Best = c.BestSim; r.BestSrc = "sim"; }                 // the sim's CarIdxBestLapTime (its own figure; the lap number is not known)
                else
                    foreach (RfLap l in c.Laps)
                    {
                        double t = l.Time; if (double.IsNaN(t) || t < 15 || l.In || l.Out) continue;
                        if (race && l.N == 1 && l.Sim <= 0) continue;           // lap 1 of a race starts from a grid or a rolling start: only the sim's own time is trusted for a best lap
                        if (r.Best < 0 || t < r.Best) { r.Best = t; r.BestLap = l.N; r.BestSrc = l.Src; }
                    }
                foreach (RfPit p in c.Pits) { if (!double.IsNaN(p.TOut)) { r.Pits++; r.PitS += p.TOut - p.TIn; } r.StallS += p.Stall; }
                rows.Add(r);
            }
            // The sim's own results (ResultsPositions) are the finishing order when it published them for the whole field: our line-crossing log can miss a
            // lap (2026-10-15 09-27: the winner's lap 5 was never logged, so he sorted LAST and Peter's real P11 showed as P10). Only when his own result agrees with his log.
            bool useRes = false;
            if (race)
            {
                int withRes = 0; Row meRow = null;
                foreach (Row r in rows) { if (r.C.ResPos > 0) withRes++; if (r.C.Me) meRow = r; }
                useRes = meRow != null && meRow.C.ResPos > 0 && meRow.C.ResLaps >= meRow.Laps && withRes >= rows.Count * 0.9;
                if (useRes)
                    foreach (Row r in rows)
                        if (r.C.ResLaps > r.Laps) { r.Laps = r.C.ResLaps; r.LastE = double.NaN; r.Total = double.NaN; }      // the log missed its last lap(s): no time for it, never a made-up gap
            }
            // order: a race is by laps, then by who crossed the line first; anything else by best lap
            rows.Sort(delegate (Row a, Row b)
            {
                if (useRes)
                {
                    int pa = a.C.ResPos > 0 ? a.C.ResPos : 1000, pb = b.C.ResPos > 0 ? b.C.ResPos : 1000;
                    if (pa != pb) return pa.CompareTo(pb);
                    return a.C.Idx.CompareTo(b.C.Idx);
                }
                if (race)
                {
                    if (a.Laps != b.Laps) return b.Laps.CompareTo(a.Laps);
                    double ea = double.IsNaN(a.LastE) ? 1e18 : a.LastE, eb = double.IsNaN(b.LastE) ? 1e18 : b.LastE;
                    int c = ea.CompareTo(eb); return c != 0 ? c : a.C.Idx.CompareTo(b.C.Idx);
                }
                double ba = a.Best > 0 ? a.Best : 1e18, bb = b.Best > 0 ? b.Best : 1e18;
                int q = ba.CompareTo(bb); if (q != 0) return q;
                if (a.Laps != b.Laps) return b.Laps.CompareTo(a.Laps);
                return a.C.Idx.CompareTo(b.C.Idx);
            });
            // classes
            List<string> classes = new List<string>(); Dictionary<string, List<Row>> byClass = new Dictionary<string, List<Row>>();
            for (int i = 0; i < rows.Count; i++)
            {
                rows[i].Pos = i + 1; string cl = rows[i].C.Cls;
                if (!byClass.ContainsKey(cl)) { byClass[cl] = new List<Row>(); classes.Add(cl); }
                byClass[cl].Add(rows[i]); rows[i].CPos = byClass[cl].Count;
            }
            double fastest = -1; Row fastRow = null;
            foreach (Row r in rows) if (r.Best > 0 && (fastest < 0 || r.Best < fastest)) { fastest = r.Best; fastRow = r; }
            if (fastRow != null) fastRow.Fastest = true;
            foreach (string cl in classes)
            {
                List<Row> g = byClass[cl]; Row lead = g[0];
                for (int i = 0; i < g.Count; i++)
                {
                    Row r = g[i];
                    if (race)
                    {
                        if (i > 0) { r.GapLaps = lead.Laps - r.Laps; if (r.GapLaps == 0) r.Gap = r.LastE - lead.LastE; Row ah = g[i - 1]; r.AheadLaps = ah.Laps - r.Laps; if (r.AheadLaps == 0) r.Ahead = r.LastE - ah.LastE; }
                    }
                    else if (i > 0 && r.Best > 0 && lead.Best > 0) { r.Gap = r.Best - lead.Best; Row ah = g[i - 1]; if (ah.Best > 0) r.Ahead = r.Best - ah.Best; }
                }
            }
            Row me = null; foreach (Row r in rows) if (r.C.Me) me = r;
            string focus = me != null ? me.C.Cls : (rows.Count > 0 ? rows[0].C.Cls : "");
            // the class that gets the race trace and the positions chart is Peter's (or the first one when he is not in the field)
            List<Row> fg = byClass.ContainsKey(focus) ? byClass[focus] : new List<Row>();
            int maxLap = 0; foreach (Row r in fg) if (r.Laps > maxLap) maxLap = r.Laps;
            Row ahead = null, behind = null, leader = fg.Count > 0 ? fg[0] : null;
            if (me != null) { int ix = fg.IndexOf(me); if (ix > 0) ahead = fg[ix - 1]; if (ix >= 0 && ix + 1 < fg.Count) behind = fg[ix + 1]; }

            StringBuilder sb = new StringBuilder(16384);
            sb.Append("{\"race\":").Append(race ? "true" : "false").Append(",\"focus\":").Append(Json_.S(focus)).Append(",\"maxLap\":").Append(maxLap)
              .Append(",\"prec\":{\"hz\":10,\"cornerS\":").Append(N(CornerPrecision, "0.00")).Append(",\"lapS\":0.02,\"gapS\":0.02,\"pitS\":0.1},");
            sb.Append("\"ahead\":").Append(ahead != null ? ahead.C.Idx.ToString(Inv) : "null").Append(",\"behind\":").Append(behind != null ? behind.C.Idx.ToString(Inv) : "null")
              .Append(",\"leader\":").Append(leader != null ? leader.C.Idx.ToString(Inv) : "null");
            // classes
            sb.Append(",\"classes\":[");
            for (int i = 0; i < classes.Count; i++)
            {
                RfCar c0 = byClass[classes[i]][0].C; if (i > 0) sb.Append(',');
                sb.Append("{\"id\":").Append(Json_.S(classes[i])).Append(",\"name\":").Append(Json_.S(c0.ClsName)).Append(",\"col\":").Append(Json_.S(c0.Color)).Append(",\"cars\":").Append(byClass[classes[i]].Count).Append('}');
            }
            // the final timing tower
            int mism = 0;
            int meInc = -1;      // his incident count: the sim's results text is often 0 or late; his own counter (kept in the log, else read from the telemetry file) is what the dash showed
            if (race && me != null) { meInc = d.MeInc; if (meInc < 0) { try { meInc = Vault.IncidentsFor(d.StartMs, d.SessNum); } catch { meInc = -1; } } }
            sb.Append("],\"tower\":[");
            for (int i = 0; i < rows.Count; i++)
            {
                Row r = rows[i]; RfCar c = r.C; if (i > 0) sb.Append(',');
                if (race && c.FinalPos > 0 && c.FinalPos != r.Pos && !c.Gone) mism++;
                sb.Append("{\"i\":").Append(c.Idx).Append(",\"pos\":").Append(r.Pos).Append(",\"cpos\":").Append(r.CPos).Append(",\"simPos\":").Append(c.FinalPos)
                  .Append(",\"laps\":").Append(r.Laps).Append(",\"total\":").Append(N(r.Total, "0.000")).Append(",\"gap\":").Append(N(r.Gap, "0.000")).Append(",\"gapLaps\":").Append(r.GapLaps)
                  .Append(",\"ahead\":").Append(N(r.Ahead, "0.000")).Append(",\"aheadLaps\":").Append(r.AheadLaps)
                  .Append(",\"best\":").Append(r.Best > 0 ? N(r.Best, "0.000") : "null").Append(",\"bestLap\":").Append(r.BestLap).Append(",\"bestSrc\":").Append(Json_.S(r.BestSrc)).Append(",\"fastest\":").Append(r.Fastest ? "true" : "false")
                  .Append(",\"pits\":").Append(r.Pits).Append(",\"pitLane\":").Append(N(r.PitS, "0.0")).Append(",\"stall\":").Append(N(r.StallS, "0.0"))
                  .Append(",\"inc\":").Append(c.Me && meInc > c.ResInc ? meInc : c.ResInc).Append(",\"out\":").Append(c.Gone || (c.Reason.Length > 0 && !Regex.IsMatch(c.Reason, "^running$", RegexOptions.IgnoreCase)) ? "true" : "false")
                  .Append(",\"reason\":").Append(Json_.S(c.Reason)).Append(",\"off\":").Append(c.Off).Append('}');
            }
            sb.Append("],\"posMismatch\":").Append(mism);
            // race trace and positions by lap, in the focus class: the gap to the class leader at the end of each lap, and the rank by crossing time
            sb.Append(",\"trace\":[");
            double[] lead_n = new double[maxLap + 1];
            for (int n = 1; n <= maxLap; n++)
            {
                double best = double.NaN;
                foreach (Row r in fg) { RfLap l; if (r.ByLap.TryGetValue(n, out l) && !double.IsNaN(l.E) && (double.IsNaN(best) || l.E < best)) best = l.E; }
                lead_n[n] = best;
            }
            for (int i = 0; i < fg.Count; i++)
            {
                Row r = fg[i]; if (i > 0) sb.Append(',');
                sb.Append("{\"i\":").Append(r.C.Idx).Append(",\"g\":[");
                for (int n = 1; n <= maxLap; n++)
                {
                    if (n > 1) sb.Append(',');
                    RfLap l; if (r.ByLap.TryGetValue(n, out l) && !double.IsNaN(l.E) && !double.IsNaN(lead_n[n])) sb.Append(N(l.E - lead_n[n], "0.000")); else sb.Append("null");
                }
                sb.Append("],\"p\":[");
                for (int n = 1; n <= maxLap; n++)
                {
                    if (n > 1) sb.Append(',');
                    RfLap l; if (r.ByLap.TryGetValue(n, out l) && !double.IsNaN(l.E))
                    {
                        int rk = 1; foreach (Row o in fg) { RfLap ol; if (o != r && o.ByLap.TryGetValue(n, out ol) && !double.IsNaN(ol.E) && ol.E < l.E) rk++; }
                        sb.Append(rk);
                    }
                    else sb.Append("null");
                }
                sb.Append("],\"pit\":[");
                bool fp = true; foreach (RfPit p in r.C.Pits) { if (!fp) sb.Append(','); fp = false; sb.Append(p.InLap); }
                sb.Append("]}");
            }
            sb.Append(']');
            // per-corner medians for every car (the page subtracts: the car's median minus Peter's, positive = Peter faster)
            sb.Append(",\"cm\":[");
            bool firstCm = true;
            foreach (Row r in rows)
            {
                List<RfLap> good = new List<RfLap>();
                foreach (RfLap l in r.C.Laps) if (Clean(l, race)) good.Add(l);
                double med = Median(DurList(good));
                List<RfLap> keep = new List<RfLap>();
                foreach (RfLap l in good) if (l.Dur <= med * 1.07) keep.Add(l);
                if (keep.Count < 3) continue;
                if (!firstCm) sb.Append(','); firstCm = false;
                sb.Append("{\"i\":").Append(r.C.Idx).Append(",\"n\":").Append(keep.Count).Append(",\"lap\":").Append(N(Median(DurList(keep)), "0.000")).Append(",\"c\":[");
                for (int k = 0; k < d.Corners.Count; k++)
                {
                    if (k > 0) sb.Append(',');
                    List<double> vals = new List<double>(); RfCorner cn = d.Corners[k];
                    bool toLine = cn.P1 < 1e-6 || cn.P1 >= 0.99999;       // the corner ends at the start/finish line (Lovely's 1.0 comes back as 0): the lap's own end is its exit
                    bool wrap = !toLine && cn.P1 <= cn.P0;               // the corner runs over the line: its exit is in the next lap
                    foreach (RfLap l in keep)
                    {
                        if (l.X == null || l.X.Length < 2 * d.Corners.Count) continue;
                        int a = l.X[2 * k]; if (a < 0) continue;
                        if (toLine) { double tl = l.Dur - a / 1000.0; if (tl > 0) vals.Add(tl); }
                        else if (!wrap) { int b = l.X[2 * k + 1]; if (b > a) vals.Add((b - a) / 1000.0); }
                        else
                        {
                            RfLap nx; if (!r.ByLap.TryGetValue(l.N + 1, out nx) || !keep.Contains(nx) || nx.X == null || nx.X.Length < 2 * d.Corners.Count) continue;
                            int b = nx.X[2 * k + 1]; if (b >= 0 && !double.IsNaN(l.Dur)) vals.Add(l.Dur - a / 1000.0 + b / 1000.0);
                        }
                    }
                    sb.Append(vals.Count >= 3 ? N(Median(vals), "0.000") : "null");
                }
                sb.Append("]}");
            }
            sb.Append(']');
            // passes (same class only), with the corner they happened in
            sb.Append(",\"passes\":[");
            bool fpz = true;
            foreach (RfPass p in d.Passes)
            {
                if (!fpz) sb.Append(','); fpz = false;
                sb.Append("{\"t\":").Append(N(p.T, "0.000")).Append(",\"lap\":").Append(p.Lap).Append(",\"by\":").Append(p.By).Append(",\"over\":").Append(p.Over).Append(",\"pct\":").Append(N(p.Pct, "0.0000"))
                  .Append(",\"where\":").Append(Json_.S(p.Where.Length > 0 ? p.Where : Where(d.Corners, p.Pct))).Append('}');
            }
            sb.Append("]}");
            return sb.ToString();
        }

        static List<double> DurList(List<RfLap> l) { List<double> v = new List<double>(); foreach (RfLap x in l) v.Add(x.Dur); return v; }
    }

    // ================================================================================================================
    // The sampler
    // ================================================================================================================
    static class RaceField
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        const double Step = 0.095;                  // sim seconds between two samples (10 Hz)
        static string rootDir;
        static Thread th;
        static volatile bool testOn;                // the test hook asked for pretend sessions to be logged
        static long testClockMs;                    // > 0: the pretend session "started" at this UTC time (so the endpoint can find it by a real .ibt's time window)
        static readonly object gate = new object();
        // status counters (read by /field/status)
        static volatile bool active; static string activeId = "", lastFile = "", lastError = ""; static int activeCars, flushes, finals; static long samples;
        static double busyMs, cpuMs, lastSimT, refreshMs; static Stopwatch wall = Stopwatch.StartNew(); static int maxDoneSeen, refreshes; static long lastCpuAt;

        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool GetThreadTimes(IntPtr h, out long c, out long e, out long k, out long u);
        static double ThreadCpuMs() { long c, e, k, u; return GetThreadTimes(GetCurrentThread(), out c, out e, out k, out u) ? (k + u) / 10000.0 : 0; }

        static string FieldDir { get { return Path.Combine(Vault.Root ?? Path.Combine(rootDir, "vault"), "field"); } }

        public static void Init(string root) { rootDir = root; }
        public static void Start()
        {
            if (th != null) return;
            th = new Thread(Run); th.IsBackground = true; th.Priority = ThreadPriority.BelowNormal; th.Name = "RaceField"; th.Start();
        }

        // ---------------- the loop ----------------
        static Live cur; static DateTime discSince = DateTime.MinValue; static int errors;
        static void Run()
        {
            long lastSeq = -1;
            while (true)
            {
                try
                {
                    Frame f = Sdk.WaitNext(lastSeq, 500);
                    bool fresh = f.Seq != lastSeq; lastSeq = f.Seq;
                    Stopwatch sw = Stopwatch.StartNew();
                    Tick(f, fresh);
                    busyMs += sw.Elapsed.TotalMilliseconds;
                    if (wall.ElapsedMilliseconds - lastCpuAt > 250) { lastCpuAt = wall.ElapsedMilliseconds; cpuMs = ThreadCpuMs(); }
                }
                catch (Exception ex)
                {
                    lastError = ex.Message; if (errors++ < 10) Log.W("field: " + ex.Message + " " + ex.StackTrace.Replace("\r\n", " | "));
                    cur = null; active = false;                 // start the session again from the next frame; the file already written stays
                    Thread.Sleep(1000);
                }
            }
        }

        static void Tick(Frame f, bool fresh)
        {
            if (!f.Connected)
            {
                if (cur == null) return;
                if (cur.Pretend) { Finish(); return; }
                if (discSince == DateTime.MinValue) discSince = DateTime.UtcNow;
                else if ((DateTime.UtcNow - discSince).TotalSeconds >= 2) { Finish(); }
                return;
            }
            discSince = DateTime.MinValue;
            if (!fresh) return;
            bool pretend = Sdk.Pretend;
            if (pretend && !testOn) { if (cur != null) Finish(); return; }
            if (!pretend && cur != null && cur.Pretend) Finish();
            if (f.Num("IsReplayPlaying") != 0) return;                 // a replay re-plays old positions: never log them as live
            double t = f.Num("SessionTime"); int snum = (int)f.Num("SessionNum");
            string yaml = f.SessionYaml ?? "";
            // The session text is 40 KB and more. It is read again only when the sim says it changed (SessionVersion), never once per frame.
            if (f.SessionVersion != subVer) { subVal = IntOf(Val(Section(yaml, "WeekendInfo"), "SubSessionID"), 0); subVer = f.SessionVersion; }
            int sub = subVal;
            if (cur != null && (cur.SessNum != snum || cur.Sub != sub)) Finish();
            if (cur == null)
            {
                if (yaml.Length == 0 || t <= 0) return;
                if (f.SessionVersion == idleVer && snum == idleNum && (DateTime.UtcNow - idleAt).TotalSeconds < 10) return;      // a solo session: not looked at again until the text changes (or in 10 s)
                Live l = Live.Start(f, yaml, snum, sub, t, pretend);
                if (l == null) { idleVer = f.SessionVersion; idleNum = snum; idleAt = DateTime.UtcNow; return; }                // fewer than two cars: nothing to log
                cur = l; active = true; activeId = l.D.Id; activeCars = l.Cars.Count; refreshAt = DateTime.UtcNow;
            }
            if (f.SessionVersion != cur.Ver) { cur.PendYaml = yaml; cur.PendVer = f.SessionVersion; }
            if (cur.PendVer != cur.Ver && cur.PendVer >= 0 && (DateTime.UtcNow - refreshAt).TotalSeconds >= 2) DoRefresh(cur);       // the results move on every lap of every car: read them at most every 2 s
            if (cur.LastT >= 0 && t >= cur.LastT && t - cur.LastT < Step) return;      // 10 Hz by sim time, whatever the frame rate
            cur.Sample(f, t);
            samples++; lastSimT = t;
            if (cur.FlushDue) { cur.FlushDue = false; Write(cur.Snapshot(false)); flushes++; }
        }

        static int subVer = -1, subVal, idleVer = -1, idleNum = -1; static DateTime idleAt = DateTime.MinValue, refreshAt = DateTime.MinValue;
        static void DoRefresh(Live l)
        {
            Stopwatch rw = Stopwatch.StartNew(); refreshAt = DateTime.UtcNow;
            try { l.Refresh(l.PendVer, l.PendYaml); activeCars = l.Cars.Count; }
            catch (Exception ex) { l.Ver = l.PendVer; Log.W("field: session text: " + ex.Message); }          // not read again until the sim changes it
            refreshes++; refreshMs += rw.Elapsed.TotalMilliseconds;
        }

        static void Finish()
        {
            Live l = cur; cur = null; active = false; discSince = DateTime.MinValue;
            if (l == null) return;
            try { if (l.PendVer >= 0 && l.PendVer != l.Ver) l.Refresh(l.PendVer, l.PendYaml); } catch (Exception ex) { Log.W("field: last session text: " + ex.Message); }       // the results as they stood at the end
            try { RfData d = l.Snapshot(true); if (l.AnyLap) { Write(d); finals++; } }
            catch (Exception ex) { Log.W("field: could not finish " + l.D.Id + ": " + ex.Message); }
        }

        static void Write(RfData d)
        {
            try
            {
                string dir = FieldDir; Directory.CreateDirectory(dir);
                string path = Path.Combine(dir, d.Id + ".json"), tmp = path + ".tmp";
                File.WriteAllText(tmp, d.ToJson(true, null, false), new UTF8Encoding(false));
                if (File.Exists(path)) File.Delete(path);
                File.Move(tmp, path);
                lastFile = d.Id;
            }
            catch (Exception ex) { Log.W("field: could not write " + d.Id + ": " + ex.Message); }
        }

        // ---------------- reading the session text ----------------
        static string Section(string y, string key)
        {
            Match m = Regex.Match(y, "(?m)^" + key + ":");
            if (!m.Success) return "";
            string rest = y.Substring(m.Index + m.Length);
            Match n = Regex.Match(rest, "(?m)^[A-Za-z]");
            return n.Success ? rest.Substring(0, n.Index) : rest;
        }
        static string Val(string block, string key)
        {
            Match m = Regex.Match(block, "(?m)^[ \\t]*" + key + ":[ \\t]*([^\\r\\n]*?)[ \\t]*\\r?$");
            return m.Success ? m.Groups[1].Value.Trim().Trim('"') : "";
        }
        static int IntOf(string s, int dflt) { int n; return int.TryParse(s, NumberStyles.Integer, Inv, out n) ? n : dflt; }
        static double DblOf(string s, double dflt) { double v; if (s == null) return dflt; int sp = s.IndexOf(' '); if (sp > 0) s = s.Substring(0, sp); return double.TryParse(s, NumberStyles.Float, Inv, out v) ? v : dflt; }
        static int Lead(string chunk) { Match m = Regex.Match(chunk, "^\\s*(-?\\d+)"); int n; return m.Success && int.TryParse(m.Groups[1].Value, out n) ? n : -1; }

        sealed class Drv { public int Idx; public string Name = "", Team = "", Num = "", Car = "", Cls = "", ClsName = "", Color = "", Lic = "", Path = "", Design = ""; public int IR; public bool Pace, Spec; }

        // CarDesignStr "17,391C83,111111,CCFF00" -> "17,391c83,111111,ccff00" (lower case, 1 to 3 hex colours); anything else -> "" (the page then paints the class colour)
        internal static string DesignOf(string raw)
        {
            Match m = Regex.Match(raw ?? "", @"^\s*(\d{1,4})\s*,\s*([0-9a-fA-F]{6})(?:\s*,\s*([0-9a-fA-F]{6}))?(?:\s*,\s*([0-9a-fA-F]{6}))?");
            if (!m.Success) return "";
            string s = m.Groups[1].Value + "," + m.Groups[2].Value.ToLowerInvariant();
            if (m.Groups[3].Success) s += "," + m.Groups[3].Value.ToLowerInvariant();
            if (m.Groups[4].Success) s += "," + m.Groups[4].Value.ToLowerInvariant();
            return s;
        }
        sealed class Res { public int Idx, Pos, Laps, Inc, FastLap; public double Fast = -1; public string Reason = ""; }

        static List<Drv> ReadDrivers(string yaml, out int me)
        {
            List<Drv> l = new List<Drv>(); me = -1;
            string di = Section(yaml, "DriverInfo"); me = IntOf(Val(di, "DriverCarIdx"), -1);
            string[] parts = Regex.Split(di, "(?m)^[ \\t]*- CarIdx:");
            for (int i = 1; i < parts.Length; i++)
            {
                Drv d = new Drv(); d.Idx = Lead(parts[i]); if (d.Idx < 0 || d.Idx > 63) continue;
                d.Name = Val(parts[i], "UserName"); d.Team = Val(parts[i], "TeamName"); d.Num = Val(parts[i], "CarNumber");
                d.Car = Val(parts[i], "CarScreenName"); if (d.Car.Length == 0) d.Car = Val(parts[i], "CarScreenNameShort");
                d.Cls = Val(parts[i], "CarClassID"); d.ClsName = Val(parts[i], "CarClassShortName");
                string col = Val(parts[i], "CarClassColor"); d.Color = Regex.IsMatch(col, "^0x[0-9a-fA-F]{6}$") ? "#" + col.Substring(2).ToLowerInvariant() : "";
                d.Path = Val(parts[i], "CarPath"); d.Design = DesignOf(Val(parts[i], "CarDesignStr"));
                d.IR = IntOf(Val(parts[i], "IRating"), 0); d.Lic = Val(parts[i], "LicString");
                d.Pace = Val(parts[i], "CarIsPaceCar") == "1"; d.Spec = Val(parts[i], "IsSpectator") == "1";
                l.Add(d);
            }
            return l;
        }

        // this session's block in SessionInfo: type, name, laps, and the results so far
        static void ReadSession(string yaml, int num, out string type, out string name, out string laps, out List<Res> results)
        {
            type = ""; name = ""; laps = ""; results = new List<Res>();
            string[] parts = Regex.Split(Section(yaml, "SessionInfo"), "(?m)^[ \\t]*- SessionNum:");
            for (int i = 1; i < parts.Length; i++)
            {
                if (Lead(parts[i]) != num) continue;
                type = Val(parts[i], "SessionType"); name = Val(parts[i], "SessionName"); laps = Val(parts[i], "SessionLaps");
                int rp = parts[i].IndexOf("ResultsPositions:", StringComparison.Ordinal);
                if (rp >= 0)
                {
                    string rb = parts[i].Substring(rp); int ff = rb.IndexOf("ResultsFastestLap:", StringComparison.Ordinal); if (ff > 0) rb = rb.Substring(0, ff);
                    string[] rs = Regex.Split(rb, "(?m)^[ \\t]*- Position:");
                    for (int k = 1; k < rs.Length; k++)
                    {
                        Res r = new Res(); r.Pos = Lead(rs[k]); r.Idx = IntOf(Val(rs[k], "CarIdx"), -1); r.Laps = IntOf(Val(rs[k], "LapsComplete"), 0); r.Inc = IntOf(Val(rs[k], "Incidents"), 0);
                        r.Fast = DblOf(Val(rs[k], "FastestTime"), -1); r.FastLap = IntOf(Val(rs[k], "FastestLap"), 0); r.Reason = Val(rs[k], "ReasonOutStr");
                        if (r.Idx >= 0) results.Add(r);
                    }
                }
                return;
            }
        }

        static double LengthOf(string yaml)
        {
            Match len = Regex.Match(Val(Section(yaml, "WeekendInfo"), "TrackLength"), @"^([\d.]+)\s*(km|mi)");
            double L; if (len.Success && double.TryParse(len.Groups[1].Value, NumberStyles.Float, Inv, out L)) return L * (len.Groups[2].Value == "mi" ? 1609.344 : 1000);
            return 0;
        }

        static long NowMs() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }

        // ================================================================================================================
        // One session being logged
        // ================================================================================================================
        sealed class LX { public double T; public int Lap, Pos, CPos; public double Sim = -1; public bool Finish; }
        sealed class LCar
        {
            public int Idx; public RfCar M;                                         // M: name, car, class ... (the stored car; laps are filled by Snapshot)
            public double PPct = -1, PT, PUn, Un; public int Base, Wraps; public bool Seen, Valid, Jumped, OnPit, Finished;
            public int Done = -1;                                                   // laps completed (the sim's CarIdxLapCompleted) as far as we accepted it
            public double PendX = double.NaN; public int PendXAge, PendLC = -1, PendLCAge;
            public double LastNonCountX = double.NaN, Lap1Start = double.NaN; public bool Lap1Green;
            public List<LX> Xs = new List<LX>(); public List<int> Bk = new List<int>(); public List<double> Bt = new List<double>();
            public double LastSeenLast = -1, NewLast = -1, NewLastAt, BestSim = -1, FinishT = -1; public LX LastEv; public double LastEvT = -100;
            public bool SeenPit, PrevPit, PrevOff; public RfPit CurPit; public List<RfPit> Pits = new List<RfPit>();
            public double LastOffT = -100, OffS; public List<int> OffLaps = new List<int>();
            public double GoneSince = double.NaN; public int Pos, CPos, Errors;
        }

        sealed class Live
        {
            public RfData D = new RfData(); public int SessNum, Sub, Ver = -1, PendVer = -1; public bool Pretend, FlushDue, AnyLap; public string PendYaml;
            public double LastT = -1; public int State = -1;
            public Dictionary<int, LCar> Cars = new Dictionary<int, LCar>(); public List<LCar> Order = new List<LCar>();
            double[] bounds = new double[0]; double[,] pairD = new double[64, 64]; double[,] pairT = new double[64, 64];
            double finishRef = double.NaN; int sessLaps; int maxDone = -1, passErrors;
            VarDef vPct, vLap, vLc, vPos, vCPos, vPit, vSurf, vLast, vBest;
            Dictionary<int, Drv> drivers = new Dictionary<int, Drv>(); Dictionary<int, Res> results = new Dictionary<int, Res>();
            long startRealMs; double firstT = -1;

            public static Live Start(Frame f, string yaml, int snum, int sub, double t, bool pretend)
            {
                int me; List<Drv> ds = ReadDrivers(yaml, out me); int real = 0;
                foreach (Drv d in ds) if (!d.Pace && !d.Spec) real++;
                if (real < 2) return null;
                Live l = new Live(); l.SessNum = snum; l.Sub = sub; l.Pretend = pretend; l.LastT = -1; l.firstT = t;
                l.startRealMs = pretend && testClockMs > 0 ? testClockMs : NowMs();
                RfData d0 = l.D; d0.StartMs = l.startRealMs; d0.T0 = t; d0.SessNum = snum;
                d0.Id = "f" + new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(l.startRealMs).ToLocalTime().ToString("yyyyMMdd-HHmmss", Inv) + "-" + snum;
                string wk = Section(yaml, "WeekendInfo");
                d0.Track = Val(wk, "TrackDisplayName"); d0.Config = Val(wk, "TrackConfigName"); d0.TrackName = Val(wk, "TrackName"); d0.TrackId = Val(wk, "TrackID");
                d0.Key = TrackMaps.MakeKey(d0.TrackId, d0.TrackName); d0.LengthM = LengthOf(yaml); d0.Official = Val(wk, "Official") == "1";
                try
                {
                    CornerSet cs = Analysis.FieldCorners(d0.Track, d0.TrackName, d0.Config, d0.TrackId);
                    d0.CornerSrc = cs.Source;
                    foreach (CornerTurn tn in cs.Turns)
                    {
                        RfCorner c = new RfCorner(); c.N = tn.N; c.Name = tn.Name ?? ""; c.Official = tn.Official ?? ""; c.P0 = tn.P0; c.Pa = tn.Pa; c.P1 = tn.P1;
                        c.Lab = c.Official.Length > 0 ? "T" + c.Official.ToUpperInvariant() : (c.Name.Replace("The ", "").Length > 0 ? c.Name.Replace("The ", "") : "T" + c.N);
                        d0.Corners.Add(c);
                    }
                }
                catch (Exception ex) { Log.W("field: no corner list (" + ex.Message + ")"); }
                l.bounds = new double[d0.Corners.Count * 2];
                for (int i = 0; i < d0.Corners.Count; i++) { l.bounds[2 * i] = Wrap01(d0.Corners[i].P0); l.bounds[2 * i + 1] = Wrap01(d0.Corners[i].P1); }
                for (int i = 0; i < 64; i++) for (int j = 0; j < 64; j++) l.pairD[i, j] = double.NaN;
                l.Refresh(f.SessionVersion, yaml);
                Log.W("field: logging session " + snum + " (" + d0.SessType + ") of " + d0.Track + ": " + l.Cars.Count + " cars, " + d0.Corners.Count + " corners (" + d0.CornerSrc + ") -> " + d0.Id);
                return l;
            }
            static double Wrap01(double p) { p = p - Math.Floor(p); return p >= 1 ? 0 : p; }

            // the session text again (a driver joined, the results moved on)
            public void Refresh(int ver, string yaml)
            {
                Ver = ver; int me; List<Drv> ds = ReadDrivers(yaml, out me); D.Me = me;
                foreach (Drv d in ds)
                {
                    drivers[d.Idx] = d;
                    if (d.Pace || d.Spec || Cars.ContainsKey(d.Idx)) continue;
                    LCar c = new LCar(); c.Idx = d.Idx; c.M = new RfCar(); Cars[d.Idx] = c; Order.Add(c);
                }
                foreach (KeyValuePair<int, LCar> kv in Cars)
                {
                    Drv d; if (!drivers.TryGetValue(kv.Key, out d)) continue; RfCar m = kv.Value.M;
                    m.Idx = d.Idx; m.Num = d.Num; m.Name = d.Name; m.Team = d.Team; m.Car = d.Car; m.Cls = d.Cls; m.ClsName = d.ClsName.Length > 0 ? d.ClsName : ""; m.Color = d.Color; m.Path = d.Path; m.Design = d.Design; m.IR = d.IR; m.Lic = d.Lic; m.Me = d.Idx == me;
                }
                string type, name, laps; List<Res> rs; ReadSession(yaml, SessNum, out type, out name, out laps, out rs);
                D.SessType = type; D.SessName = name; D.SessLaps = laps; sessLaps = IntOf(laps, 0);
                results.Clear(); foreach (Res r in rs) results[r.Idx] = r;
            }

            static double Read(Frame f, VarDef v, int i)
            {
                if (v == null || i >= v.Count) return double.NaN;
                int sz = v.Type <= 1 ? 1 : v.Type == 5 ? 8 : 4, p = v.Offset + i * sz;
                if (p < 0 || p + sz > f.Data.Length) return double.NaN;
                switch (v.Type)
                {
                    case 0: case 1: return f.Data[p];
                    case 2: case 3: return BitConverter.ToInt32(f.Data, p);
                    case 4: return BitConverter.ToSingle(f.Data, p);
                    case 5: return BitConverter.ToDouble(f.Data, p);
                }
                return double.NaN;
            }
            static VarDef V(Frame f, string n) { VarDef d; return f.Vars != null && f.Vars.TryGetValue(n, out d) ? d : null; }

            public void Sample(Frame f, double t)
            {
                vPct = V(f, "CarIdxLapDistPct"); vLap = V(f, "CarIdxLap"); vLc = V(f, "CarIdxLapCompleted"); vPos = V(f, "CarIdxPosition"); vCPos = V(f, "CarIdxClassPosition");
                vPit = V(f, "CarIdxOnPitRoad"); vSurf = V(f, "CarIdxTrackSurface"); vLast = V(f, "CarIdxLastLapTime"); vBest = V(f, "CarIdxBestLapTime");
                if (vPct == null) return;
                double dt = LastT >= 0 ? t - LastT : 0; bool discont = LastT >= 0 && (dt < 0 || dt > 1.5);       // a rewind or a long hole: nothing is carried over
                int st = (int)f.Num("SessionState");
                if (st != State)
                {
                    if (st == 4 && double.IsNaN(D.GreenT) && (State >= 0 && State < 4)) D.GreenT = t;
                    if (st >= 5 && double.IsNaN(D.FlagT)) { D.FlagT = t; if (double.IsNaN(finishRef)) finishRef = t; }
                    State = st;
                }
                bool race = D.IsRace;
                if (race && D.Me >= 0 && State >= 3) { double mi = f.Num("PlayerCarMyIncidentCount"); if (!double.IsNaN(mi) && mi >= 0 && (int)mi > D.MeInc) D.MeInc = (int)mi; }      // his own counter: the results text can say 0 for a race that cost him 13
                // one odd car must not stop the log of the others: a car that throws is skipped for this sample (logged three times at most)
                foreach (LCar c in Order) { try { SampleCar(f, t, dt, discont, c, race); } catch (Exception ex) { c.PPct = -1; if (c.Errors++ < 3) Log.W("field: car " + c.Idx + ": " + ex.Message); } }
                try { if (race && State == 4) Passes(t); else ClearPairs(); } catch (Exception ex) { ClearPairs(); if (passErrors++ < 3) Log.W("field: passes: " + ex.Message); }
                foreach (LCar c in Order) c.PUn = c.Un;
                LastT = t; D.Samples++; D.EndT = t; D.EndMs = startRealMs + (long)((t - firstT) * 1000);
                if (maxDone > maxDoneSeen) maxDoneSeen = maxDone;
            }

            void ClearPairs() { for (int i = 0; i < 64; i++) for (int j = 0; j < 64; j++) pairD[i, j] = double.NaN; }

            void SampleCar(Frame f, double t, double dt, bool discont, LCar c, bool race)
            {
                int i = c.Idx; double pct = Read(f, vPct, i); double surfD = Read(f, vSurf, i); int surf = double.IsNaN(surfD) ? 3 : (int)surfD;
                c.Jumped = false; c.Valid = false;
                if (double.IsNaN(pct) || pct < 0 || surf == -1)
                {
                    if (double.IsNaN(c.GoneSince) && c.Seen) c.GoneSince = t;
                    c.PPct = -1; c.PrevPit = false; c.SeenPit = false; c.PrevOff = false; c.CurPit = null; return;
                }
                if (pct >= 1) pct -= Math.Floor(pct);
                double lcD = Read(f, vLc, i); int lc = double.IsNaN(lcD) ? -1 : (int)lcD; double lapD = Read(f, vLap, i); int lap = double.IsNaN(lapD) ? -1 : (int)lapD;
                double posD = Read(f, vPos, i), cposD = Read(f, vCPos, i); double pitD = Read(f, vPit, i); bool pit = !double.IsNaN(pitD) && pitD != 0; double last = Read(f, vLast, i);
                c.GoneSince = double.NaN;
                if (!c.Seen)
                {
                    c.Seen = true; c.Done = lc >= 0 ? lc : (lap >= 1 ? lap - 1 : 0); c.Base = c.Done; c.LastSeenLast = double.IsNaN(last) ? -1 : last;
                }
                if (discont) { c.PPct = -1; c.PrevPit = pit; c.SeenPit = true; c.PrevOff = surf == 0; }
                if (!double.IsNaN(posD) && posD > 0) c.Pos = (int)posD; if (!double.IsNaN(cposD) && cposD > 0) c.CPos = (int)cposD;
                double dtc = c.PPct >= 0 ? t - c.PT : 0;
                // LastLapTime (the sim's own time of the lap it just closed). Looked at before the finish check: the sim may publish the last lap's time a sample after the line.
                if (!double.IsNaN(last) && last > 0 && Math.Abs(last - c.LastSeenLast) > 1e-6)
                {
                    c.LastSeenLast = last; c.NewLast = last; c.NewLastAt = t;
                    if (c.LastEv != null && c.LastEv.Sim < 0 && t - c.LastEvT < 0.7) { c.LastEv.Sim = last; c.NewLast = -1; }
                }
                // the sim's own best lap of the car (never taken from the cool-down laps after its flag)
                double bestD = Read(f, vBest, i); if (!double.IsNaN(bestD) && bestD > 15 && (!c.Finished || t - c.FinishT < 0.7) && (c.BestSim < 0 || bestD < c.BestSim)) c.BestSim = bestD;
                if (c.Finished) { c.PPct = pct; c.PT = t; return; }          // the flag has fallen for this car: its cool-down laps are not part of the race
                // ---- line and corner crossings between the last sample and this one ----
                if (c.PPct >= 0 && dtc > 0 && dtc <= 1.5)
                {
                    double pp = c.PPct; bool wrap = pp > 0.75 && pct < 0.25;
                    if (wrap)
                    {
                        double span = (1 - pp) + pct;
                        if (span > 0.1) c.Jumped = true;                       // too far for one step: a tow or a reset, not driving
                        else
                        {
                            double X = c.PT + dtc * (1 - pp) / span;
                            for (int k = 0; k < bounds.Length; k++)
                            {
                                double b = bounds[k];
                                if (b > pp) { c.Bk.Add(k); c.Bt.Add(c.PT + dtc * (b - pp) / span); }
                                else if (b <= pct) { c.Bk.Add(k); c.Bt.Add(c.PT + dtc * ((1 - pp) + b) / span); }
                            }
                            c.Wraps++; c.PendX = X; c.PendXAge = 0;
                        }
                    }
                    else if (pp < 0.25 && pct > 0.75) { double span = (1 - pct) + pp; if (span > 0.1) c.Jumped = true; else c.Wraps--; }       // backwards over the line
                    else
                    {
                        double dl = pct - pp;
                        if (dl > 0 && dl <= 0.1)
                        {
                            for (int k = 0; k < bounds.Length; k++) { double b = bounds[k]; if (b > pp && b <= pct) { c.Bk.Add(k); c.Bt.Add(c.PT + dtc * (b - pp) / dl); } }
                        }
                        else if (dl > 0.1 || dl < -0.02) c.Jumped = true;
                    }
                }
                c.Un = c.Base + c.Wraps + pct; c.Valid = true;
                // ---- a line crossing counts when the sim's lap counter moved with it (formation laps and reversing do not move it) ----
                if (lc >= 0 && lc > c.Done) c.PendLC = lc;
                else if (vLc == null && !double.IsNaN(c.PendX)) c.PendLC = c.Done + 1;
                if (!double.IsNaN(c.PendX) && c.PendLC >= 0) AddCross(c, c.PendX, c.PendLC, t, race);
                else
                {
                    if (!double.IsNaN(c.PendX) && ++c.PendXAge > 3) { c.LastNonCountX = c.PendX; c.PendX = double.NaN; c.PendXAge = 0; }
                    if (c.PendLC >= 0 && double.IsNaN(c.PendX) && ++c.PendLCAge > 3) AddCross(c, double.NaN, c.PendLC, t, race);
                }
                // ---- pit road: in, out, the time in the stall ----
                if (c.SeenPit)
                {
                    if (!c.PrevPit && pit) { RfPit p = new RfPit(); p.InLap = c.Done + 1; p.TIn = t; c.CurPit = p; c.Pits.Add(p); }
                    else if (c.PrevPit && !pit && c.CurPit != null) { c.CurPit.TOut = t; c.CurPit.OutLap = c.Done + 1; c.CurPit = null; }
                }
                if (pit && surf == 1 && c.CurPit != null) c.CurPit.Stall += dtc;
                c.PrevPit = pit; c.SeenPit = true; c.OnPit = pit;
                // ---- off track: one excursion = surface 0 for a while (flicker within a second is the same excursion) ----
                if (surf == 0)
                {
                    c.OffS += dtc;
                    if (!c.PrevOff && t - c.LastOffT > 1.0) c.OffLaps.Add(c.Done + 1);
                    c.LastOffT = t;
                }
                c.PrevOff = surf == 0;
                c.PPct = pct; c.PT = t;
            }

            void AddCross(LCar c, double x, int lapNo, double t, bool race)
            {
                LX e = new LX(); e.T = x; e.Lap = lapNo; e.Pos = c.Pos; e.CPos = c.CPos;
                if (lapNo == 1)
                {
                    double cand = c.LastNonCountX; bool useGreen = false;
                    if (double.IsNaN(D.GreenT)) { if (double.IsNaN(cand)) cand = double.NaN; }
                    else if (double.IsNaN(cand) || D.GreenT - cand > 10) { cand = D.GreenT; useGreen = true; }
                    c.Lap1Start = cand; c.Lap1Green = useGreen;
                }
                if (c.NewLast > 0 && t - c.NewLastAt < 0.7) { e.Sim = c.NewLast; c.NewLast = -1; }
                // the chequered flag: this is the car's last lap
                if (race && !double.IsNaN(x))
                {
                    bool fin = false;
                    if (sessLaps > 0 && lapNo >= sessLaps) fin = true;
                    if (!double.IsNaN(finishRef) && x >= finishRef - 0.25) fin = true;
                    if (fin) { e.Finish = true; c.Finished = true; c.FinishT = t; if (double.IsNaN(finishRef)) finishRef = x; }
                }
                c.Xs.Add(e); c.Done = lapNo; c.PendX = double.NaN; c.PendLC = -1; c.PendXAge = 0; c.PendLCAge = 0; c.LastEv = e; c.LastEvT = t;
                AnyLap = true;
                if (lapNo > maxDone) { maxDone = lapNo; FlushDue = true; }
            }

            // ---- on-track passes: two cars of one class change places while both are racing on track ----
            void Passes(double t)
            {
                int n = Order.Count;
                for (int a = 0; a < n; a++)
                    for (int b = a + 1; b < n; b++)
                    {
                        LCar ca = Order[a], cb = Order[b]; int i = ca.Idx, j = cb.Idx;
                        bool ok = ca.Valid && cb.Valid && !ca.Jumped && !cb.Jumped && !ca.OnPit && !cb.OnPit && !ca.Finished && !cb.Finished && ca.M.Cls == cb.M.Cls;
                        if (!ok) { pairD[i, j] = double.NaN; continue; }
                        double dNow = ca.Un - cb.Un, dPrev = pairD[i, j]; double tPrev = pairT[i, j];
                        pairD[i, j] = dNow; pairT[i, j] = t;
                        if (double.IsNaN(dPrev) || dPrev == 0 || dNow == 0) continue;
                        if ((dPrev < 0) == (dNow < 0) || Math.Abs(dPrev) > 0.05 || Math.Abs(dNow) > 0.05) continue;
                        double fz = -dPrev / (dNow - dPrev), tz = tPrev + (t - tPrev) * fz;
                        LCar by = dNow > 0 ? ca : cb, over = dNow > 0 ? cb : ca;
                        double un = by.PUn + (by.Un - by.PUn) * fz; double pctAt = un - Math.Floor(un);
                        bool dup = false;      // two cars trading places inside 3 s are one pass, not a flicker of several
                        foreach (RfPass q in D.Passes) if (q.By == by.Idx && q.Over == over.Idx && tz - q.T < 3.0 && tz >= q.T) dup = true;
                        if (dup) continue;
                        RfPass p = new RfPass(); p.T = tz; p.Lap = by.Done + 1; p.Pct = pctAt; p.By = by.Idx; p.Over = over.Idx; p.Where = RfSummary.Where(D.Corners, pctAt);
                        D.Passes.Add(p);
                    }
            }

            // ---- the stored model, built from the events ----
            public RfData Snapshot(bool complete)
            {
                RfData d = new RfData();
                d.Id = D.Id; d.StartMs = D.StartMs; d.EndMs = D.EndMs; d.Track = D.Track; d.Config = D.Config; d.TrackName = D.TrackName; d.TrackId = D.TrackId; d.Key = D.Key; d.LengthM = D.LengthM;
                d.SessNum = D.SessNum; d.SessType = D.SessType; d.SessName = D.SessName; d.SessLaps = D.SessLaps; d.Official = D.Official; d.Me = D.Me; d.T0 = D.T0; d.EndT = D.EndT; d.GreenT = D.GreenT; d.FlagT = D.FlagT;
                d.Samples = D.Samples; d.MeInc = D.MeInc; d.Complete = complete; d.CornerSrc = D.CornerSrc; d.Corners = D.Corners; d.Passes = new List<RfPass>(D.Passes);
                int nb = bounds.Length;
                foreach (LCar c in Order)
                {
                    if (!c.Seen) continue;
                    RfCar m = c.M, r = new RfCar();
                    r.Idx = m.Idx; r.Num = m.Num; r.Name = m.Name; r.Team = m.Team; r.Car = m.Car; r.Cls = m.Cls; r.ClsName = m.ClsName; r.Color = m.Color; r.Path = m.Path; r.Design = m.Design; r.IR = m.IR; r.Lic = m.Lic; r.Me = m.Me;
                    r.FinalPos = c.Pos; r.FinalCPos = c.CPos; r.Finished = c.Finished; r.Off = c.OffLaps.Count; r.OffS = c.OffS; r.BestSim = c.BestSim;
                    Res rs; if (results.TryGetValue(c.Idx, out rs)) { r.ResPos = rs.Pos; r.ResLaps = rs.Laps; r.ResInc = rs.Inc; r.ResBest = rs.Fast; r.ResBestLap = rs.FastLap; r.Reason = rs.Reason; }
                    if (!double.IsNaN(c.GoneSince) && D.EndT - c.GoneSince >= 30) { r.Gone = true; r.GoneT = c.GoneSince; }
                    // a car skimming the pit entry line flickers pit road on and off: a stop of under 3 s is no stop (the shortest drive-through takes about 6 s)
                    List<RfPit> pits = new List<RfPit>(); foreach (RfPit pp in c.Pits) if (double.IsNaN(pp.TOut) || pp.TOut - pp.TIn >= 3.0) pits.Add(pp);
                    List<LX> xs = new List<LX>(c.Xs); xs.Sort(delegate (LX a, LX b) { return a.Lap.CompareTo(b.Lap); });
                    for (int j = 0; j < xs.Count; j++)
                    {
                        LX e = xs[j]; if (j > 0 && xs[j - 1].Lap == e.Lap) continue;
                        RfLap l = new RfLap(); l.N = e.Lap; l.E = e.T; l.Sim = e.Sim; l.Pos = e.Pos; l.CPos = e.CPos;
                        if (j > 0 && xs[j - 1].Lap == e.Lap - 1 && !double.IsNaN(xs[j - 1].T)) l.S = xs[j - 1].T;
                        else if (e.Lap == 1) { l.S = c.Lap1Start; l.GreenStart = c.Lap1Green && !double.IsNaN(c.Lap1Start); }
                        foreach (RfPit p in pits) { if (p.InLap == l.N) l.In = true; if (p.OutLap == l.N && !double.IsNaN(p.TOut)) l.Out = true; }
                        foreach (int ol in c.OffLaps) if (ol == l.N) l.Off++;
                        if (nb > 0 && !double.IsNaN(l.S) && !double.IsNaN(l.E))
                        {
                            l.X = new int[nb]; for (int k = 0; k < nb; k++) l.X[k] = -1;
                            for (int q = 0; q < c.Bt.Count; q++) { double bt = c.Bt[q]; if (bt >= l.S && bt < l.E && l.X[c.Bk[q]] < 0) l.X[c.Bk[q]] = (int)Math.Round((bt - l.S) * 1000); }
                        }
                        r.Laps.Add(l);
                    }
                    r.Pits = pits;
                    d.Cars.Add(r);
                }
                return d;
            }
        }

        // ================================================================================================================
        // HTTP
        // ================================================================================================================
        sealed class FileIdx { public string Path, Id; public long Mtime, StartMs, EndMs; public int Laps; public string Track = ""; }
        static readonly Dictionary<string, FileIdx> index = new Dictionary<string, FileIdx>();

        static string Err(string m) { return "{\"error\":" + Json_.S(m) + "}"; }
        static string Q(Dictionary<string, string> q, string k) { string v; return q != null && q.TryGetValue(k, out v) && v != null ? v : ""; }

        public static string Route(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            try
            {
                if (path == "/field/status") return Status();
                if (path.StartsWith("/api/test/field", StringComparison.Ordinal))
                {
                    if (!Sdk.TestHook)
                    {
                        string busy = Sdk.RealBusy();
                        if (busy != null) { Log.W("test hook refused: " + busy); code = 409; return Err("refused: " + busy); }
                        code = 404; return Err("not found");
                    }
                    if (path == "/api/test/field")
                    {
                        testOn = Q(q, "on") == "1"; long ms; testClockMs = long.TryParse(Q(q, "ms"), out ms) ? ms : 0;
                        int pump; Sdk.FakePumpMs = testOn && int.TryParse(Q(q, "pump"), out pump) ? Math.Max(4, Math.Min(100, pump)) : 33;      // a faster pretend frame rate for the accelerated race; 33 again when the test is over
                        samples = 0; busyMs = 0; flushes = 0; finals = 0; maxDoneSeen = 0; lastFile = ""; lastError = ""; wall.Restart();
                        return "{\"ok\":true,\"on\":" + (testOn ? "true" : "false") + ",\"dir\":" + Json_.S(FieldDir) + "}";
                    }
                    if (path == "/api/test/fieldyaml")
                    {
                        string name = Q(q, "name");
                        if (!Regex.IsMatch(name, "^[A-Za-z0-9._-]{1,60}$")) { code = 400; return Err("bad name"); }
                        string file = Path.Combine(rootDir, "vault-test", name);
                        if (!File.Exists(file)) { code = 404; return Err("no such file"); }
                        Sdk.FakeSession(File.ReadAllText(file, Encoding.GetEncoding(28591)));
                        return "{\"ok\":true}";
                    }
                    code = 404; return Err("not found");
                }
                if (path == "/analysis/race")
                {
                    if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
                    return RaceRoute(q, out code);
                }
            }
            catch (Exception ex) { Log.W("field route: " + ex.Message); code = 500; return Err("could not do that"); }
            code = 404; return Err("not found");
        }

        static string Status()
        {
            double cpu = cpuMs, w = wall.Elapsed.TotalSeconds;
            return "{\"active\":" + (active ? "true" : "false") + ",\"id\":" + Json_.S(activeId) + ",\"cars\":" + activeCars + ",\"samples\":" + samples + ",\"simT\":" + lastSimT.ToString("0.000", Inv)
                + ",\"flushes\":" + flushes + ",\"finals\":" + finals + ",\"lastFile\":" + Json_.S(lastFile) + ",\"maxDone\":" + maxDoneSeen + ",\"busyMs\":" + busyMs.ToString("0.00", Inv)
                + ",\"refreshes\":" + refreshes + ",\"refreshMs\":" + refreshMs.ToString("0.00", Inv)
                + ",\"cpuMs\":" + cpu.ToString("0.00", Inv) + ",\"wallS\":" + w.ToString("0.00", Inv) + ",\"testOn\":" + (testOn ? "true" : "false") + ",\"error\":" + Json_.S(lastError) + "}";
        }

        // the time window of a telemetry file: from the stamp in its name (iRacing's local clock) to the moment it was last written
        static bool WindowOf(string id, out long fromMs, out long toMs)
        {
            fromMs = 0; toMs = 0;
            string file = id.EndsWith(".ibt", StringComparison.OrdinalIgnoreCase) ? IbtLaps.Resolve(id) : Vault.FileForId(id);
            if (file == null) return false;
            FileInfo fi = new FileInfo(file); if (!fi.Exists) return false;
            DateTime start = fi.CreationTimeUtc;
            Match m = Regex.Match(fi.Name, @"(\d{4})-(\d{2})-(\d{2}) (\d{2})-(\d{2})-(\d{2})\.ibt$");
            if (m.Success)
            {
                try { start = new DateTime(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value), int.Parse(m.Groups[4].Value), int.Parse(m.Groups[5].Value), int.Parse(m.Groups[6].Value), DateTimeKind.Local).ToUniversalTime(); }
                catch { }
            }
            DateTime ep = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
            fromMs = (long)(start - ep).TotalMilliseconds; toMs = (long)(fi.LastWriteTimeUtc - ep).TotalMilliseconds;
            return toMs > fromMs;
        }

        static List<FileIdx> Files()
        {
            List<FileIdx> l = new List<FileIdx>(); string dir = FieldDir;
            if (!Directory.Exists(dir)) return l;
            lock (gate)
            {
                foreach (string f in Directory.GetFiles(dir, "f*.json"))
                {
                    long mt = File.GetLastWriteTimeUtc(f).Ticks; FileIdx x;
                    if (!index.TryGetValue(f, out x) || x.Mtime != mt)
                    {
                        try
                        {
                            RfData d = RfData.FromJson(File.ReadAllText(f, Encoding.UTF8)); if (d == null) continue;
                            x = new FileIdx(); x.Path = f; x.Id = d.Id; x.Mtime = mt; x.StartMs = d.StartMs; x.EndMs = d.EndMs; x.Track = d.TrackName;
                            foreach (RfCar c in d.Cars) foreach (RfLap lp in c.Laps) x.Laps++;
                            index[f] = x;
                        }
                        catch { continue; }
                    }
                    l.Add(x);
                }
            }
            return l;
        }

        static string RaceRoute(Dictionary<string, string> q, out int code)
        {
            code = 200; string id = Q(q, "id");
            if (id.Length == 0 || id.Length > 160) { code = 400; return Err("need id="); }
            string path = null;
            if (Regex.IsMatch(id, "^f[0-9]{8}-[0-9]{6}-[0-9]{1,2}$")) { string p = Path.Combine(FieldDir, id + ".json"); if (File.Exists(p)) path = p; }
            else
            {
                long from, to;
                if (!WindowOf(id, out from, out to)) { code = 404; return Err("no such lap file"); }
                FileIdx best = null; long bestOv = 0;
                foreach (FileIdx x in Files())
                {
                    long ov = Math.Min(x.EndMs, to + 120000) - Math.Max(x.StartMs, from - 120000);
                    if (ov <= 0) continue;
                    if (best == null || ov > bestOv || (ov == bestOv && x.Laps > best.Laps)) { best = x; bestOv = ov; }
                }
                if (best != null) path = best.Path;
            }
            if (path == null) { code = 404; return Err("no field data for this session"); }
            RfData d = RfData.FromJson(File.ReadAllText(path, Encoding.UTF8));
            if (d == null) { code = 500; return Err("could not read the race log"); }
            ThreadPriority was = Thread.CurrentThread.Priority;
            try { Thread.CurrentThread.Priority = ThreadPriority.BelowNormal; return d.ToJson(Q(q, "x") == "1", RfSummary.Build(d), true); }
            finally { try { Thread.CurrentThread.Priority = was; } catch { } }
        }
    }
}
