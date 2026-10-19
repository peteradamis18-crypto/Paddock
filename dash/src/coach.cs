// coach.cs - the session coach: "what to fix next", from every clean lap of one session against his own best clean lap.
//   GET /analysis/coach?id=<telemetry file | Vault id>
// What it does (docs\design\home-v3\insights.md, docs\research\coaching-tools-2026-10.md):
//  - each corner of each clean lap is compared with the same corner of the session's best clean lap (CompareMet, the same
//    measurement the lap analysis uses: braking point, entry, minimum, throttle pick-up, exit);
//  - a corner is advice only when the loss REPEATS: median loss >= 0.05 s and lost in at least half the other clean laps
//    (and at least 2). A big loss in one lap is a mistake, not a habit, and is reported as "inconsistent" instead;
//  - each measured difference must clear its noise floor (5 m, 3 mph, 10 m) or it is left out;
//  - the instruction comes from a fixed table keyed on what was measured. No generated prose;
//  - habits need at least 3 clean laps. Fewer is still data (CoachFew): 2 laps against each other, 1 lap or a part-lap against
//    his best lap ever here, each with plain "treat it as a hint" words; nothing comparable = the drive's summary and the raw
//    data (rawdata.cs). The reply always carries "summary". Never a made-up number.
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
            List<LapTrace> all = new List<LapTrace>();
            foreach (LapTrace lap in mine.Laps) if (lap.Clean && lap.Tm != null) { Measure(lap, cs); all.Add(lap); }
            // the reference: the fastest lap iRacing fully counted (no corner cut, no tow); clean-only if there is none
            List<LapTrace> pure = PureOf(all);
            LapTrace best = null;
            foreach (LapTrace l in (pure.Count > 0 ? pure : all)) if (best == null || l.Time < best.Time) best = l;
            // laps in his normal rhythm only: within 2 % of that best. A race start, a traffic lap or a cool-down lap is not
            // a habit and would make every corner look slow.
            List<LapTrace> clean = new List<LapTrace>();
            foreach (LapTrace l in all) if (best != null && l.Time <= best.Time * 1.02) clean.Add(l);
            StringBuilder sb = new StringBuilder(4096);
            sb.Append("{\"ok\":true,\"file\":").Append(Json_.S(mine.File)).Append(",\"car\":").Append(Json_.S(mine.Car)).Append(",\"track\":").Append(Json_.S(CoachTrackName(mine)))
              .Append(",\"config\":").Append(Json_.S(mine.Config)).Append(",\"units\":\"imperial\",\"clean\":").Append(clean.Count);
            // what the drive held (rawdata.cs): always there, so the screen is never only a refusal
            sb.Append(",\"summary\":").Append(DriveSummary(file));
            // Fewer than 3 laps in rhythm is not a habit, but it is still data (Peter 2026-10-18): 2 laps are compared with each other,
            // 1 lap (or the part of a lap that was driven) with his best lap ever in this car here. Plain words say how much it is worth.
            if (clean.Count < 3) return CoachFew(sb, file, mine, cs, clean, all);
            if (best.Corners == null || best.Corners.Count == 0)
            {
                sb.Append(",\"ready\":false,\"mode\":\"drive\",\"reason\":").Append(Json_.S("No corner map for this track yet")).Append(",\"focus\":[],\"inconsistent\":[]}");
                return sb.ToString();
            }
            sb.Append(",\"mode\":\"habit\"");

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
                // the best lap must be repeatable here: another lap within 0.10 s of it. Otherwise the "habit" is only the
                // best lap having been lucky in this corner, and copying luck is not advice.
                double nearest = double.MaxValue; foreach (double v in r.Loss) if (v < nearest) nearest = v;
                bool repeatable = nearest <= 0.10;
                if (!double.IsNaN(med) && med >= CoachMinLoss && r.Lost >= need && repeatable) { if (focus.Count < 3) focus.Add(r); }
                else
                {
                    double max = double.MinValue; foreach (double v in r.Loss) if (v > max) max = v;
                    if (max >= 0.25 && r.Lost < need && shaky.Count < 3) shaky.Add(r);    // one or two big losses: a mistake, not a habit
                }
            }

            double total = 0; foreach (CoachRow r in focus) total += Median(r.Loss);
            sb.Append(",\"ready\":true,\"reason\":").Append(Json_.S(focus.Count == 0 ? "No corner loses time lap after lap." : ""));
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
        // minSupport: 2 for habits (one lap's braking point is not "typical"); 1 when only one lap is compared (the page says it is a hint).
        // bestHere: the best lap is in this session's file (its video cue means something); false for a best lap from another session.
        static void AppendFocus(StringBuilder sb, CoachRow r, LapTrace best, int minSupport = 2, bool bestHere = true)
        {
            // a fact must stand on at least half of the losing laps (and minSupport)
            int support = Math.Max(minSupport, (int)Math.Ceiling(r.Lost / 2.0));
            Func<List<double>, double> typical = delegate (List<double> v) { return v.Count >= support ? Median(v) : double.NaN; };
            double br = typical(r.Br), en = typical(r.En), mn = typical(r.Mn), pk = typical(r.Pk), ex = typical(r.Ex);
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
            // nothing measured on the side where the time goes: the other side, but only if real time is lost there too
            double other = before ? tout : tin;
            if (code.Length == 0 && !double.IsNaN(other) && other >= CoachMinLoss) { pickSide(!before); if (code.Length > 0) before = !before; }
            // the facts: the one behind the instruction first, then the others on the same side, three at most
            List<KeyValuePair<string, string>> all = new List<KeyValuePair<string, string>>();
            // only the differences that LOSE time are facts here (a faster exit next to a slower apex is noise for this card)
            if (brake && br < 0) all.Add(new KeyValuePair<string, string>("brake", "Braking " + Whole(Math.Abs(br)) + " m " + (br < 0 ? "earlier" : "later") + " than the best lap"));
            if (entry && en < 0) all.Add(new KeyValuePair<string, string>("entry", Whole(Math.Abs(en) / KmhPerMph) + " mph " + (en < 0 ? "slower" : "faster") + " into the turn"));
            if (apex && mn < 0) all.Add(new KeyValuePair<string, string>("min", Whole(Math.Abs(mn) / KmhPerMph) + " mph " + (mn < 0 ? "slower" : "faster") + " at the slowest point"));
            if (pick && pk > 0) all.Add(new KeyValuePair<string, string>("pickup", "Throttle " + Whole(Math.Abs(pk)) + " m later than the best lap"));
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
                case "min": say = "Keep more speed through the slowest point."; break;      // only what is measured: speed, not how the brake is released
                case "pickup": say = "Back on the throttle earlier."; break;
                case "exit": say = "Carry more speed onto the exit."; break;                 // steering is not read, so it is not named
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
            else
            {
                // a partial lap that does not start at the line has no lap-start time in the recording: no cue (WATCH says so)
                bool cue = !r.Example.Partial || r.Example.CovA <= 1;
                sb.Append("{\"lap\":").Append(r.Example.Lap).Append(",\"time\":").Append(F(r.Example.Time, "0.000")).Append(",\"loss\":").Append(F(r.ExampleLoss, "0.000")).Append(",\"at\":").Append(cue ? F(CueAt(r.Example, r.M.P0), "0.00") : "null").Append(",\"partial\":").Append(r.Example.Partial ? "true" : "false").Append('}');
            }
            if (bestHere) sb.Append(",\"best\":{\"lap\":").Append(best.Lap).Append(",\"at\":").Append(F(CueAt(best, r.M.P0), "0.00")).Append("}}");
            else sb.Append(",\"best\":null}");
        }

        // ---------------- fewer than 3 laps in rhythm: still the data, with honest words ----------------
        //   2 laps: the slower one against the quicker one ("only 2 laps: treat this as a hint");
        //   1 lap: that lap against his best lap EVER in this car here (the laps iRacing counted, every session: the PB rule);
        //   0 full laps: the part of a lap he drove (partial.cs) against that same best lap, corner by corner, over what it covers;
        //   nothing comparable: what the drive held (the summary) and the raw data, one press away (the page draws the button).
        static string CoachFew(StringBuilder sb, string file, Sess mine, CornerSet cs, List<LapTrace> rhythm, List<LapTrace> all)
        {
            bool haveMap = cs != null && cs.Turns != null && cs.Turns.Count > 0;
            LapTrace me = null, rf = null; string mode, hint = "", refKind = ""; bool refHere = false;
            if (rhythm.Count == 2)
            {
                LapTrace a = rhythm[0], b = rhythm[1];
                rf = a.Time <= b.Time ? a : b; me = rf == a ? b : a;
                mode = "two"; refKind = "session best"; refHere = true;
                hint = "Only 2 laps at race pace: lap " + me.Lap + " against lap " + rf.Lap + ". Treat this as a hint, not a habit.";
            }
            else
            {
                if (rhythm.Count == 1) me = rhythm[0];
                else foreach (LapTrace l in all) if (me == null || l.Time < me.Time) me = l;
                bool offLap = false;
                if (me == null && haveMap)
                {
                    // no clean lap: a whole lap with an off-track is still a whole lap of data, unless it is quicker than the best lap ever
                    // (then the off-track was a short cut: Ferrari 17-45-41 lap 4 "gained" 10.9 s in T4), which compares nothing
                    string pdir = TrackMaps.TelemetryDir;
                    if (string.IsNullOrEmpty(pdir) || !Directory.Exists(pdir)) pdir = Path.GetDirectoryName(file);
                    LapTrace ever = Fastest(CleanOf(Gather(file, pdir, true)), null, null);
                    foreach (LapTrace l in mine.Laps)
                        if (l.Skip == "off" && l.Tm != null && ever != null && l.Time >= ever.Time - 0.05 && !SameLap(l, ever) && (me == null || l.Time < me.Time)) { me = l; offLap = true; }
                }
                mode = me != null ? "pb" : "partial";
                if (me == null) me = BestPartial(mine, cs);
                if (offLap) hint = "No clean lap: lap " + me.Lap + " (it had an off-track) against the best lap ever in this car here. Treat it as a hint.";
                if (me != null && haveMap)
                {
                    string dir = TrackMaps.TelemetryDir;
                    if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) dir = Path.GetDirectoryName(file);
                    rf = Fastest(CleanOf(Gather(file, dir, true)), null, me);
                    if (rf != null)
                    {
                        refHere = string.Equals(rf.Path, me.Path, StringComparison.OrdinalIgnoreCase);
                        refKind = !me.Partial && me.Time < rf.Time ? "next best ever" : "best ever";
                    }
                }
                if (offLap) { }
                else if (me != null && mode == "pb")
                    hint = "Only 1 lap at race pace: lap " + me.Lap + " against the " + (refKind == "next best ever" ? "next best lap ever (this lap is the best)" : "best lap ever") + " in this car here. Treat it as a hint.";
                else if (me != null)
                {
                    string pa = Math.Round(me.CovA / me.LengthM * 100).ToString(Inv), pz = Math.Round(me.CovB / me.LengthM * 100).ToString(Inv);
                    hint = "No full lap in this drive. " + (me.Skip == "out" ? "The out-lap" : me.Skip == "in" ? "The in-lap" : "Lap " + me.Lap) + " was driven " +
                        (me.CovA <= 1 ? "from the line to " + pz + " %" : "from " + pa + " % to " + pz + " %") + " of the lap: those corners against the best lap ever here." +
                        (me.Skip == "out" ? " Out-lap tyres are cold." : "") + " Treat it as a hint.";
                }
            }
            Func<string, string> none = delegate (string why)
            {
                sb.Append(",\"ready\":true,\"mode\":\"drive\",\"hint\":").Append(Json_.S(hint)).Append(",\"reason\":").Append(Json_.S(why)).Append(",\"focus\":[],\"corners\":[],\"inconsistent\":[]}");
                return sb.ToString();
            };
            if (me == null) return none(all.Count == 0 ? "No lap long enough to compare. Here is everything the drive held." : "Nothing to compare yet.");
            if (!haveMap) return none("No corner map for this track yet. Here is everything the drive held.");
            if (rf == null) return none("First drive in this car here: nothing to compare with yet.");
            if (me.Partial) MeasurePartial(me, cs); else Measure(me, cs);
            if (!rf.Measured) Measure(rf, cs);
            if (me.Corners.Count == 0) return none("The part of the lap that was driven holds no whole corner.");

            List<CoachRow> rows = new List<CoachRow>();
            List<Diff> diffs = new List<Diff>();
            foreach (Met m in me.Corners)
            {
                Met o = ByN(rf.Corners, m.N); if (o == null) continue;
                Diff d = CompareMet(m, o, rf.LengthM);
                CoachRow r = new CoachRow(); r.M = o; r.Laps = 1; r.Loss.Add(d.DTime); r.Example = me; r.ExampleLoss = d.DTime;
                if (d.DTime >= CoachMinLoss)
                {
                    r.Lost = 1; r.In.Add(d.DIn); r.Out.Add(d.DOut);
                    if (d.HasBr) r.Br.Add(d.DBr); if (d.HasEn) r.En.Add(d.DEn); if (d.HasMn) r.Mn.Add(d.DMn); if (d.HasPk) r.Pk.Add(d.DPk); if (d.HasEx) r.Ex.Add(d.DEx);
                }
                rows.Add(r); diffs.Add(d);
            }
            if (rows.Count == 0) return none("The corners of this lap could not be matched with the best lap.");
            List<CoachRow> focus = new List<CoachRow>();
            foreach (CoachRow r in rows) if (r.Loss[0] >= CoachMinLoss) focus.Add(r);
            focus.Sort(delegate (CoachRow x, CoachRow y) { return y.Loss[0].CompareTo(x.Loss[0]); });
            if (focus.Count > 3) focus.RemoveRange(3, focus.Count - 3);
            double total = 0; foreach (CoachRow r in focus) total += r.Loss[0];

            sb.Append(",\"ready\":true,\"mode\":").Append(Json_.S(mode)).Append(",\"hint\":").Append(Json_.S(hint));
            sb.Append(",\"reason\":").Append(Json_.S(focus.Count == 0 ? "No corner lost 0.05 s or more against the " + (mode == "two" ? "quicker lap." : "best lap ever.") : ""));
            sb.Append(",\"ref\":{\"lap\":").Append(rf.Lap).Append(",\"time\":").Append(F(rf.Time, "0.000")).Append(",\"kind\":").Append(Json_.S(refKind))
              .Append(",\"file\":").Append(Json_.S(rf.File)).Append(",\"date\":").Append(Json_.S(DateOf(rf.File))).Append(",\"here\":").Append(refHere ? "true" : "false").Append('}');
            sb.Append(",\"lap\":{\"lap\":").Append(me.Lap).Append(",\"time\":").Append(F(me.Time, "0.000")).Append(",\"partial\":").Append(me.Partial ? "true" : "false").Append(",\"cover\":");
            if (me.Partial) AppendCover(sb, me); else sb.Append("null");
            if (me.Partial) sb.Append(",\"refStretch\":").Append(F(Span(rf, me.CovA, me.CovB), "0.000"));
            sb.Append('}');
            sb.Append(",\"perLap\":").Append(F(total, "0.000"));
            sb.Append(",\"focus\":[");
            for (int i = 0; i < focus.Count; i++) { if (i > 0) sb.Append(','); AppendFocus(sb, focus[i], rf, 1, refHere); }
            sb.Append("],\"corners\":[");
            for (int i = 0; i < rows.Count; i++)
            {
                if (i > 0) sb.Append(',');
                Diff d = diffs[i]; Met m = rows[i].M;
                sb.Append("{\"n\":").Append(m.N).Append(",\"label\":").Append(Json_.S(m.Label)).Append(",\"dTime\":").Append(F(d.DTime, "0.000"))
                  .Append(",\"dBrakeM\":").Append(NZ(d.HasBr, d.DBr, "0.0")).Append(",\"dEntryMph\":").Append(NZ(d.HasEn, d.DEn / KmhPerMph, "0.0"))
                  .Append(",\"dMinMph\":").Append(NZ(d.HasMn, d.DMn / KmhPerMph, "0.0")).Append(",\"dExitMph\":").Append(NZ(d.HasEx, d.DEx / KmhPerMph, "0.0"))
                  .Append(",\"dPickupM\":").Append(NZ(d.HasPk, d.DPk, "0.0")).Append('}');
            }
            sb.Append("],\"inconsistent\":[]}");
            return sb.ToString();
        }

        // the part-lap worth comparing: a hot lap cut short before an off-track lap, before an in-lap, before an out-lap (cold tyres); then the most corners
        static LapTrace BestPartial(Sess mine, CornerSet cs)
        {
            LapTrace pick = null; int pickRank = -1, pickN = -1; double pickCov = 0;
            foreach (LapTrace l in mine.Laps)
            {
                if ((l.Clean && l.Tm != null) || l.Skip == "off") continue;      // whole laps are handled above (an off-track lap is not a part-lap)
                LapTrace v = PartialOf(l); if (v == null) continue;
                MeasurePartial(v, cs);
                int rank = v.Skip == "partial" ? 4 : v.Skip == "off" ? 3 : v.Skip == "in" ? 2 : v.Skip == "pit" ? 1 : 0;
                double cov = v.CovB - v.CovA;
                bool better = pick == null || v.Corners.Count > 0 && pickN == 0 || (v.Corners.Count > 0) == (pickN > 0) && (rank > pickRank || rank == pickRank && (v.Corners.Count > pickN || v.Corners.Count == pickN && cov > pickCov));
                if (better) { pick = v; pickRank = rank; pickN = v.Corners.Count; pickCov = cov; }
            }
            return pick;
        }

        // the name iRacing shows ("Road America"), not its internal one ("roadamerica 2026 full")
        static string CoachTrackName(Sess s)
        {
            string n = TrackMaps.YamlValue(s.Yaml ?? "", "TrackDisplayName");
            if (n.Length == 0) n = s.TrackName; if (n.Length == 0) n = s.Track;
            return n;
        }

        static string Whole(double v) { return ((int)Math.Floor(v + 0.5)).ToString(CultureInfo.InvariantCulture); }

        // seconds into the lap, 3 s before the corner window starts. It may be negative for a corner just after the line:
        // the video runs on from the previous lap, so the run-up is still there (coach.js clamps at the start of the file)
        static double CueAt(LapTrace lap, double p0)
        {
            if (lap.Tm == null || lap.Metres <= 0) return 0;
            int m = (int)Math.Max(0, Math.Min(lap.Metres - 1, Math.Round(p0 * lap.Metres)));
            return lap.Tm[m] - 3.0;
        }
    }
}
