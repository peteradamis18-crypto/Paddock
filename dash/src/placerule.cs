// PLACE RULE (W1-12): ONE rule for the place a race started and finished, used by REVIEW (review.cs) and the YouTube pack
// (highlights.cs, which feeds the cuts.cs titles), so the two can never print different places for the same race.
//   START  = the grid place from the session info (QualifyResultsInfo, class place in a mixed field: RacePlace.Grid);
//            if the grid is unknown, the place at the first line crossing in the field log (the best the log has).
//   FINISH = the results place from the session info (ResultsPositions, class place in a mixed field: RacePlace.Results);
//            if the results are not published, the finishing order of the field log (its class place in a mixed field).
// 2026-11-14: the card feared P6 (pack) against P7 (REVIEW); the data of the 21:27 Road Atlanta race says P6 everywhere (the P7 was
// the example text in review.js). The two paths did take the start from different places though (the sidecar's grid against the
// first crossing), which this rule fixes for any race where they differ.
using System;
using System.Collections.Generic;
using System.Globalization;

namespace IRDash
{
    static class PlaceRule
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // a known place wins over the fallback; 0 = unknown
        public static int Start(int grid, int firstCrossing) { return grid > 0 ? grid : (firstCrossing > 0 ? firstCrossing : 0); }
        public static int Finish(int results, int logOrder) { return results > 0 ? results : (logOrder > 0 ? logOrder : 0); }

        // the race story's result block (Debrief.RaceStory) gets the rule applied from the session info text of the same race
        // (the .ibt's yaml); no yaml or no grid in it leaves the story's own first-crossing and log-order numbers
        public static void Apply(Dictionary<string, object> story, string yaml, int sessionNum)
        {
            Dictionary<string, object> r = story != null && story.ContainsKey("result") ? story["result"] as Dictionary<string, object> : null;
            if (r == null || string.IsNullOrEmpty(yaml)) return;
            int me = RacePlace.DriverIdx(yaml); if (me < 0) return;
            int pos, field; RacePlace.Results(yaml, sessionNum, me, out pos, out field);
            int grid = RacePlace.Grid(yaml, me);
            int logStart = Num(r, "startPosition");
            int logFinish = Num(r, "classPosition") > 0 ? Num(r, "classPosition") : Num(r, "finishPosition");
            int s = Start(grid, logStart), f = Finish(pos, logFinish);
            r["startPosition"] = s; r["finishPosition"] = f;
            if (s > 0 && f > 0) r["positionsGained"] = s - f;
        }

        static int Num(Dictionary<string, object> d, string k)
        {
            object o; if (!d.TryGetValue(k, out o) || o == null) return 0;
            try { return Convert.ToInt32(o, Inv); } catch { return 0; }
        }
    }
}
