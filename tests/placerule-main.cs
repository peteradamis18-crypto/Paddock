// placerule-main.cs - the harness of tests\placerule-test.ps1 (W1-12): the start and finish place of the 2026-11-14 21:27 Road Atlanta
// race, from REVIEW's path and from the YouTube pack's path, from the race's real field log and the real session info of its .ibt.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class PlaceRuleMain
    {
        static int fails;
        static void Ok(string what, bool cond, string why)
        {
            if (cond) Console.WriteLine("ok " + what);
            else { fails++; Console.WriteLine("FAIL " + what + (string.IsNullOrEmpty(why) ? "" : " (" + why + ")")); }
        }

        static void Ok(string what, bool cond) { Ok(what, cond, ""); }

        // REVIEW's path: the story from the field log, the rule applied with the .ibt's session info (review.cs does exactly this)
        static Dictionary<string, object> Review(string logJson, string yaml, int sessNum)
        {
            string sj = Debrief.RaceStory(logJson);
            Dictionary<string, object> story = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(sj) as Dictionary<string, object>;
            PlaceRule.Apply(story, yaml, sessNum);
            return story["result"] as Dictionary<string, object>;
        }

        // the pack's path: the sidecar's facts (Library.FactsOf), then Pack.Story from the field log
        static Facts Pack_(string fdir, long startMs, int sideStart, int sideFinish)
        {
            Pack.FieldDirOverride = fdir;
            RaceInfo r = new RaceInfo(); r.Id = "race-x"; r.IsRace = true; r.StartMs = startMs; r.Sec = 1196; r.Laps = 10; r.Car = "Toyota GR86"; r.Track = "Road Atlanta";
            r.File = Path.Combine(fdir, "none.mp4"); r.Start = sideStart; r.Finish = sideFinish;
            RecSess s = new RecSess(); s.Id = r.Id;
            Facts f = new Facts(); f.Car = r.Car; f.Track = r.Track; f.Start = sideStart; f.Finish = sideFinish;
            Pack.Story(r, s, new CutPlan(), f, new List<Moment>());
            return f;
        }

        static int Main(string[] a)
        {
            string logPath = a[0], yamlPath = a[1], tmp = a[2];
            Directory.CreateDirectory(tmp); Log.FilePath = Path.Combine(tmp, "pr.log");
            string fdir = Path.Combine(tmp, "field"); Directory.CreateDirectory(fdir);
            string logText = File.ReadAllText(logPath, Encoding.UTF8);
            File.WriteAllText(Path.Combine(fdir, "f20261114-212650-2.json"), logText, new UTF8Encoding(false));
            string yaml = File.ReadAllText(yamlPath, Encoding.GetEncoding(1252));
            RfData d = RfData.FromJson(logText);
            string full = d.ToJson(false, RfSummary.Build(d), true);
            long ms = d.StartMs + 57000;

            // the sources, one by one (the evidence for the report)
            int grid = RacePlace.Grid(yaml, RacePlace.DriverIdx(yaml));
            Ok("1. the session info's grid for car 6 (qualifying P6) is 6", grid == 6, grid.ToString());
            RfCar me = d.Car(d.Me); int firstPos = 0, n0 = int.MaxValue; foreach (RfLap l in me.Laps) if (l.N < n0) { n0 = l.N; firstPos = l.Pos; }
            Ok("1. the field log's first crossing also says 6", firstPos == 6, firstPos.ToString());

            // the real race: both paths, with the sidecar's real numbers (start 6, finish 4) and without any sidecar numbers
            Dictionary<string, object> rv = Review(full, yaml, 2);
            Facts withSide = Pack_(fdir, ms, 6, 4), noSide = Pack_(fdir, ms, 0, 0);
            Ok("2. REVIEW says P4 from P6", Convert.ToInt32(rv["finishPosition"]) == 4 && Convert.ToInt32(rv["startPosition"]) == 6, rv["startPosition"] + " -> " + rv["finishPosition"]);
            Ok("2. the pack (sidecar numbers) says P6 -> P4", withSide.Start == 6 && withSide.Finish == 4, withSide.Start + " -> " + withSide.Finish);
            Ok("2. the pack (no sidecar numbers, the field log only) says P6 -> P4", noSide.Start == 6 && noSide.Finish == 4, noSide.Start + " -> " + noSide.Finish);
            Ok("2. REVIEW and the pack agree on start and finish", Convert.ToInt32(rv["startPosition"]) == withSide.Start && Convert.ToInt32(rv["finishPosition"]) == withSide.Finish);
            Ok("2. the pack's story title says P6 to P4", Cuts.StoryTitle(withSide).Contains("P6 to P4"), Cuts.StoryTitle(withSide));

            // the rule where the sources differ: a grid of 7 in the session info and 7 in the sidecar beat the log's 6, in BOTH paths
            string qi = "QualifyResultsInfo:";
            int qa = yaml.IndexOf(qi);
            string swapped = yaml.Substring(0, qa) + SwapGrid(yaml.Substring(qa)); // cars 6 and 17 trade places 6 <-> 7
            Ok("3. (a made-up grid: P7 in qualifying) the session info gives 7", RacePlace.Grid(swapped, 6) == 7, RacePlace.Grid(swapped, 6).ToString());
            Dictionary<string, object> rv7 = Review(full, swapped, 2);
            Facts p7 = Pack_(fdir, ms, RacePlace.Grid(swapped, 6), 4);
            Ok("3. REVIEW takes the grid (7), not the first crossing (6)", Convert.ToInt32(rv7["startPosition"]) == 7, rv7["startPosition"].ToString());
            Ok("3. the pack (sidecar start 7) says 7 too", p7.Start == 7, p7.Start.ToString());
            Ok("3. gain follows: REVIEW +3", Convert.ToInt32(rv7["positionsGained"]) == 3, rv7["positionsGained"].ToString());
            Dictionary<string, object> rvNo = Review(full, "", 2);
            Ok("3. no session info: REVIEW falls back to the first crossing (6) and the log order (4)", Convert.ToInt32(rvNo["startPosition"]) == 6 && Convert.ToInt32(rvNo["finishPosition"]) == 4);
            Ok("3. PlaceRule.Start/Finish: known wins, else the fallback, else 0", PlaceRule.Start(7, 6) == 7 && PlaceRule.Start(0, 6) == 6 && PlaceRule.Start(0, 0) == 0 && PlaceRule.Finish(5, 4) == 5 && PlaceRule.Finish(0, 4) == 4);

            Console.WriteLine("DONE");
            return fails == 0 ? 0 : 1;
        }

        // the block's Position rows of car 6 and car 17 swap their Position/ClassPosition (5 <-> 6)
        static string SwapGrid(string block)
        {
            string a = "- Position: 5\n   ClassPosition: 5\n   CarIdx: 6\n", b = "- Position: 6\n   ClassPosition: 6\n   CarIdx: 17\n";
            string a2 = "- Position: 6\n   ClassPosition: 6\n   CarIdx: 6\n", b2 = "- Position: 5\n   ClassPosition: 5\n   CarIdx: 17\n";
            block = block.Replace("\r\n", "\n");
            return block.Replace(a, "@@A").Replace(b, "@@B").Replace("@@A", a2).Replace("@@B", b2);
        }
    }
}
