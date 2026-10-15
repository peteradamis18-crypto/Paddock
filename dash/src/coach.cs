// coach.cs - the session coach: "what to fix next", from every clean lap of one session against his own best clean lap.
//   GET /analysis/coach?id=<telemetry file | Vault id>
// What it does (docs\design\home-v3\insights.md, docs\research\coaching-tools-2026-10.md):
//  - each corner of each clean lap is compared with the same corner of the session's best clean lap (CompareMet, the same
//    measurement the lap analysis uses: braking point, entry, minimum, throttle pick-up, exit);
//  - a corner is advice only when the loss REPEATS: median loss >= 0.05 s and lost in at least half the other clean laps
//    (and at least 2). A big loss in one lap is a mistake, not a habit, and is reported as "inconsistent" instead;
//  - each measured difference must clear its noise floor (5 m, 3 mph, 10 m) or it is left out;
//  - the instruction comes from a fixed table keyed on what was measured. No generated prose;
//  - at least 3 clean laps, or it says how many more are needed. Never a made-up number.
// Speeds are said in mph (Peter's iRacing is set to imperial). C# 5; reads only.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace IRDash
{
    static partial class Analysis
    {
        const double CoachMinLoss = 0.05, KmhPerMph = 1.609344;

        public static string CoachRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
            string id = Q(q, "id");
            string file = ResolveFile(id);
            if (file == null) { code = 404; return Err("no such session"); }
            try { return Coach(file); }
            catch (Exception ex) { Log.W("coach: " + ex.Message); code = 500; return Err("could not read the laps"); }
        }

        sealed class CoachRow
        {
            public Met M; public List<double> In = new List<double>(), Out = new List<double>(), Loss = new List<double>(), Br = new List<double>(), En = new List<double>(), Mn = new List<double>(), Pk = new List<double>(), Ex = new List<double>();
            public Dictionary<string, int> Codes = new Dictionary<string, int>();
            public int Lost, Laps; public LapTrace Example; public double ExampleLoss;
        }

        static double Median(List<double> v)
        {
            if (v == null || v.Count == 0) return double.NaN;
            List<double> s = new List<double>(v); s.Sort(); int n = s.Count;
            return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0;
        }

        internal static string Coach(string file)
        {
            List<Sess> sessions = Gather(file, null, true);     // this session only: the advice is about what he just drove
            Sess mine = sessions[0];
            CornerSet cs = LoadCorners(mine);
            List<LapTrace> clean = new List<LapTrace>();
            foreach (LapTrace lap in mine.Laps) if (lap.Clean && lap.Tm != null) { Measure(lap, cs); clean.Add(lap); }
            StringBuilder sb = new StringBuilder(4096);
            sb.Append("{\"ok\":true,\"file\":").Append(Json_.S(mine.File)).Append(",\"car\":").Append(Json_.S(mine.Car)).Append(",\"track\":").Append(Json_.S(CoachTrackName(mine)))
              .Append(",\"config\":").Append(Json_.S(mine.Config)).Append(",\"units\":\"imperial\",\"clean\":").Append(clean.Count);
            if (clean.Count < 3)
            {
                sb.Append(",\"ready\":false,\"reason\":").Append(Json_.S("Not enough clean laps to compare (" + clean.Count + " of 3)")).Append(",\"focus\":[],\"inconsistent\":[]}");
                return sb.ToString();
            }
            LapTrace best = clean[0];
            foreach (LapTrace l in clean) if (l.Time < best.Time) best = l;
            if (best.Corners == null || best.Corners.Count == 0)
            {
                sb.Append(",\"ready\":false,\"reason\":").Append(Json_.S("No corner map for this track yet")).Append(",\"focus\":[],\"inconsistent\":[]}");
                return sb.ToString();
            }

            List<CoachRow> rows = new List<CoachRow>();
            foreach (Met bm in best.Corners)
            {
                CoachRow r = new CoachRow(); r.M = bm;
                foreach (LapTrace l in clean)
                {
                    if (l == best || l.Corners == null) continue;
                    Met a = ByN(l.Corners, bm.N); if (a == null) continue;
                    Diff d = CompareMet(a, bm, best.LengthM);
                    r.Laps++;
                    r.Loss.Add(d.DTime);
                    if (d.DTime >= CoachMinLoss)
                    {
                        r.Lost++; r.In.Add(d.DIn); r.Out.Add(d.DOut);
                        if (d.HasBr) r.Br.Add(d.DBr); if (d.HasEn) r.En.Add(d.DEn); if (d.HasMn) r.Mn.Add(d.DMn); if (d.HasPk) r.Pk.Add(d.DPk); if (d.HasEx) r.Ex.Add(d.DEx);
                        int c; r.Codes.TryGetValue(d.Code, out c); r.Codes[d.Code] = c + 1;
                    }
                }
                double med = Median(r.Loss);
                // the lap to show: the one whose loss here is closest to the typical (median) loss - a fair example, not the worst
                double bestGap = double.MaxValue;
                foreach (LapTrace l in clean)
                {
                    if (l == best) continue; Met a = ByN(l.Corners, bm.N); if (a == null) continue;
                    double g = Math.Abs((a.Time - bm.Time) - med);
                    if (g < bestGap) { bestGap = g; r.Example = l; r.ExampleLoss = a.Time - bm.Time; }
                }
                rows.Add(r);
            }
            rows.Sort(delegate (CoachRow a, CoachRow b) { return Median(b.Loss).CompareTo(Median(a.Loss)); });

            List<CoachRow> focus = new List<CoachRow>(), shaky = new List<CoachRow>();
            foreach (CoachRow r in rows)
            {
                double med = Median(r.Loss);
                int need = Math.Max(2, (int)Math.Ceiling(r.Laps / 2.0));
                if (!double.IsNaN(med) && med >= CoachMinLoss && r.Lost >= need) { if (focus.Count < 3) focus.Add(r); }
                else
                {
                    double max = double.MinValue; foreach (double v in r.Loss) if (v > max) max = v;
                    if (max >= 0.25 && r.Lost < need && shaky.Count < 3) shaky.Add(r);    // one or two big losses: a mistake, not a habit
                }
            }

            double total = 0; foreach (CoachRow r in focus) total += Median(r.Loss);
            sb.Append(",\"ready\":true,\"reason\":").Append(Json_.S(focus.Count == 0 ? "No corner loses time lap after lap. The laps are consistent." : ""));
            sb.Append(",\"ref\":{\"lap\":").Append(best.Lap).Append(",\"time\":").Append(F(best.Time, "0.000")).Append(",\"kind\":\"session best\"}");
            sb.Append(",\"perLap\":").Append(F(total, "0.000"));
            sb.Append(",\"focus\":[");
            for (int i = 0; i < focus.Count; i++)
            {
                if (i > 0) sb.Append(',');
                AppendFocus(sb, focus[i], best);
            }
            sb.Append("],\"inconsistent\":[");
            for (int i = 0; i < shaky.Count; i++)
            {
                if (i > 0) sb.Append(',');
                CoachRow r = shaky[i]; double max = double.MinValue; foreach (double v in r.Loss) if (v > max) max = v;
                sb.Append("{\"n\":").Append(r.M.N).Append(",\"label\":").Append(Json_.S(r.M.Label)).Append(",\"worst\":").Append(F(max, "0.000")).Append(",\"lost\":").Append(r.Lost).Append(",\"laps\":").Append(r.Laps).Append('}');
            }
            sb.Append("]}");
            return sb.ToString();
        }

        // one advice card: the corner, the typical loss, how often, the measured facts, one instruction, and where to look
        static void AppendFocus(StringBuilder sb, CoachRow r, LapTrace best)
        {
            double br = Median(r.Br), en = Median(r.En), mn = Median(r.Mn), pk = Median(r.Pk), ex = Median(r.Ex);
            // phases (Delta-style): brake, entry, apex, exit. Each: the measured difference, or null under its noise floor.
            bool brake = !double.IsNaN(br) && Math.Abs(br) >= 5, entry = !double.IsNaN(en) && Math.Abs(en) / KmhPerMph >= 3,
                 apex = !double.IsNaN(mn) && Math.Abs(mn) / KmhPerMph >= 3, pick = !double.IsNaN(pk) && Math.Abs(pk) >= 10, exit = !double.IsNaN(ex) && Math.Abs(ex) / KmhPerMph >= 3;
            // Where the time goes: before the apex (braking, entry, slowest point) or after it (throttle, exit). The lap
            // analysis measures both halves; the bigger half picks the instruction, so advice and facts can't disagree.
            double tin = Median(r.In), tout = Median(r.Out);
            bool before = double.IsNaN(tout) || (!double.IsNaN(tin) && tin >= tout);
            // each fact's size against its noise floor; the instruction is the biggest one on the side where the time goes
            string code = ""; double size = 0;
            Action<string, bool, double, double, bool> pickIf = delegate (string c, bool ok, double v, double floor, bool lossDir)
            {
                if (!ok || !lossDir) return;
                double s = Math.Abs(v) / floor; if (s > size) { size = s; code = c; }
            };
            Action<bool> pickSide = delegate (bool b4)
            {
                if (b4) { pickIf("brake", brake, br, 5, br < 0); pickIf("entry", entry, en / KmhPerMph, 3, en < 0); pickIf("min", apex, mn / KmhPerMph, 3, mn < 0); }
                else { pickIf("pickup", pick, pk, 10, pk > 0); pickIf("exit", exit, ex / KmhPerMph, 3, ex < 0); pickIf("min", apex, mn / KmhPerMph, 3, mn < 0); }
            };
            pickSide(before);
            if (code.Length == 0) { pickSide(!before); if (code.Length > 0) before = !before; }     // nothing measured on the side where the time goes: the other side, if it explains a loss
            // the facts: the one behind the instruction first, then the others on the same side, three at most
            List<KeyValuePair<string, string>> all = new List<KeyValuePair<string, string>>();
            // only the differences that LOSE time are facts here (a faster exit next to a slower apex is noise for this card)
            if (brake && br < 0) all.Add(new KeyValuePair<string, string>("brake", "Braking " + Whole(Math.Abs(br)) + " m " + (br < 0 ? "earlier" : "later") + " than the best lap"));
            if (entry && en < 0) all.Add(new KeyValuePair<string, string>("entry", Whole(Math.Abs(en) / KmhPerMph) + " mph " + (en < 0 ? "slower" : "faster") + " into the turn"));
            if (apex && mn < 0) all.Add(new KeyValuePair<string, string>("min", Whole(Math.Abs(mn) / KmhPerMph) + " mph " + (mn < 0 ? "slower" : "faster") + " at the slowest point"));
            if (pick && pk > 0) all.Add(new KeyValuePair<string, string>("pickup", "Throttle " + Whole(Math.Abs(pk)) + " m " + (pk > 0 ? "later" : "earlier")));
            if (exit && ex < 0) all.Add(new KeyValuePair<string, string>("exit", Whole(Math.Abs(ex) / KmhPerMph) + " mph " + (ex < 0 ? "slower" : "faster") + " on the exit"));
            string[] side = before ? new string[] { "brake", "entry", "min" } : new string[] { "pickup", "exit", "min" };
            List<string> facts = new List<string>();
            List<string> shown = new List<string>();      // the phases whose facts are on the card: only these light up
            foreach (KeyValuePair<string, string> kv in all) if (kv.Key == code) { facts.Add(kv.Value); shown.Add(kv.Key); }
            foreach (KeyValuePair<string, string> kv in all) if (kv.Key != code && Array.IndexOf(side, kv.Key) >= 0 && facts.Count < 3) { facts.Add(kv.Value); shown.Add(kv.Key); }
            string say;
            switch (code)
            {
                case "brake": say = "Brake later, at the best lap's braking point."; break;
                case "entry": say = "Carry more speed to the turn-in."; break;
                case "min": say = before ? "Release the brake more gently and keep speed to the apex." : "Keep more speed through the slowest point."; break;
                case "pickup": say = "Back on the throttle earlier."; break;
                case "exit": say = "Open the steering sooner for a faster exit."; break;
                default: say = "No single input explains it. Watch both laps: the line may differ."; break;
            }
            double med = Median(r.Loss);
            sb.Append("{\"n\":").Append(r.M.N).Append(",\"label\":").Append(Json_.S(r.M.Label)).Append(",\"name\":").Append(Json_.S(r.M.Name))
              .Append(",\"p0\":").Append(F(r.M.P0, "0.0000")).Append(",\"pa\":").Append(F(r.M.Pa, "0.0000")).Append(",\"p1\":").Append(F(r.M.P1, "0.0000"))
              .Append(",\"loss\":").Append(F(med, "0.000")).Append(",\"lost\":").Append(r.Lost).Append(",\"laps\":").Append(r.Laps).Append(",\"where\":").Append(Json_.S(before ? "before the apex" : "after the apex"))
              .Append(",\"phase\":{\"brake\":").Append(brake ? F(br, "0.0") : "null").Append(",\"entryMph\":").Append(entry ? F(en / KmhPerMph, "0.0") : "null")
              .Append(",\"apexMph\":").Append(apex ? F(mn / KmhPerMph, "0.0") : "null").Append(",\"throttle\":").Append(pick ? F(pk, "0.0") : "null")
              .Append(",\"exitMph\":").Append(exit ? F(ex / KmhPerMph, "0.0") : "null").Append('}')
              .Append(",\"code\":").Append(Json_.S(code)).Append(",\"say\":").Append(Json_.S(say)).Append(",\"facts\":[");
            for (int i = 0; i < facts.Count; i++) { if (i > 0) sb.Append(','); sb.Append(Json_.S(facts[i])); }
            sb.Append("],\"shown\":[");
            for (int i = 0; i < shown.Count; i++) { if (i > 0) sb.Append(','); sb.Append(Json_.S(shown[i])); }
            sb.Append(']');
            // where to look: lap-relative times of the corner entry (3 s before) on the example lap and on the best lap.
            // Analysis time is pinned to the official lap time (drift is tiny over a corner); good for a cue, not a frame.
            sb.Append(",\"example\":");
            if (r.Example == null) sb.Append("null");
            else sb.Append("{\"lap\":").Append(r.Example.Lap).Append(",\"time\":").Append(F(r.Example.Time, "0.000")).Append(",\"loss\":").Append(F(r.ExampleLoss, "0.000")).Append(",\"at\":").Append(F(CueAt(r.Example, r.M.P0), "0.00")).Append('}');
            sb.Append(",\"best\":{\"lap\":").Append(best.Lap).Append(",\"at\":").Append(F(CueAt(best, r.M.P0), "0.00")).Append("}}");
        }

        // the name iRacing shows ("Road America"), not its internal one ("roadamerica 2026 full")
        static string CoachTrackName(Sess s)
        {
            string n = TrackMaps.YamlValue(s.Yaml ?? "", "TrackDisplayName");
            if (n.Length == 0) n = s.TrackName; if (n.Length == 0) n = s.Track;
            return n;
        }

        static string Whole(double v) { return ((int)Math.Floor(v + 0.5)).ToString(CultureInfo.InvariantCulture); }

        // seconds into the lap, 3 s before the corner window starts (never before the lap)
        static double CueAt(LapTrace lap, double p0)
        {
            if (lap.Tm == null || lap.Metres <= 0) return 0;
            int m = (int)Math.Max(0, Math.Min(lap.Metres - 1, Math.Round(p0 * lap.Metres)));
            return Math.Max(0, lap.Tm[m] - 3.0);
        }
    }
}
