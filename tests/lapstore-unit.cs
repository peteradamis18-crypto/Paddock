// Unit check for dash\src\lapstore.cs + ibtfile.cs (compiled together with them by tests\laprules-test.ps1 and tests\lap-truth-test.ps1).
//   lapstore-unit.exe judge             the counted rule on made-up laps, one case per rule (ok/FAIL lines)
//   lapstore-unit.exe live              the live judge on made-up frames
//   lapstore-unit.exe file <ibt> <dir>  the laps of one .ibt (cache folder <dir>) as JSON, then a second read from the cache
using System;
using System.Collections.Generic;
using System.Text;

namespace IRDash
{
    static class Json
    {
        public static string Str(string s)
        {
            StringBuilder sb = new StringBuilder(s.Length + 16);
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default: if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4")); else sb.Append(c); break;
                }
            }
            return sb.Append('"').ToString();
        }
    }
    static class Json_ { public static string S(string s) { return Json.Str(s ?? ""); } }
    static class Log { public static void W(string m) { Console.WriteLine("log " + m); } }

    static class Unit
    {
        static int fails;
        static void Ok(string what, bool good, string detail)
        {
            if (!good) fails++;
            Console.WriteLine((good ? "ok " : "FAIL ") + what + (good || detail == null ? "" : " (" + detail + ")"));
        }

        static void Case(string what, bool want, string wantWhy, int lap, double time, bool timed, bool pit, bool inc, bool haveBest, double before, double after)
        {
            string why;
            bool got = LapRules.Judge(lap, time, timed, pit, inc, haveBest, before, after, out why);
            Ok(what, got == want && why == wantWhy, "counted " + got + " why '" + why + "'");
        }

        static int Main(string[] a)
        {
            string mode = a.Length > 0 ? a[0] : "judge";
            if (mode == "judge")
            {
                Case("lap 0 (formation / out lap) is never a lap", false, "lap0", 0, 220.9, true, false, false, true, -1, -1);
                Case("a slower clean lap iRacing timed is counted", true, "", 4, 94.933, true, false, false, true, 93.919, 93.919);
                Case("a new best that iRacing's best lap became is counted", true, "", 9, 93.832, true, false, false, true, 93.919, 93.832);
                Case("an incident lap is not counted, even with a time", false, "incident", 6, 93.639, true, false, true, true, 93.919, 93.919);
                Case("a quicker lap iRacing's best did not follow is not counted", false, "not-best", 6, 93.639, true, false, false, true, 93.919, 93.919);
                Case("a lap with one off-track record but iRacing's own time is counted", true, "", 3, 93.919, true, false, false, true, 94.863, 93.919);
                Case("a pit lap is not counted", false, "pit", 5, 120.0, true, true, false, true, 93.919, 93.919);
                Case("a lap with no official time in the window is not counted (no-time)", false, "no-time", 7, 94.8, false, false, false, true, 93.919, 93.919);
                Case("a lap under 15 s is not a lap", false, "short", 2, 9.5, true, false, false, true, -1, -1);
                Case("the first lap of a session (no best yet) counts when the best becomes it", true, "", 1, 95.1, true, false, false, true, -1, 95.1);
                Case("the first lap of a race: iRacing's best stayed empty (-1) = not counted", false, "not-best", 1, 101.58, true, false, false, true, 0, -1);
                Case("no best-lap channel in the file: a timed clean lap counts", true, "", 3, 94.0, true, false, false, false, -1, -1);
                Ok("LapRules.Version is 4", LapRules.Version == 4, null);
                Ok("the window is about 4 s", LapRules.WindowSec >= 3.9 && LapRules.WindowSec <= 4.1, null);
                List<LapRec> laps = new List<LapRec>();
                double[] t = { 94.0, 93.5, 93.8 }; bool[] c = { true, false, true };
                for (int i = 0; i < 3; i++) { LapRec l = new LapRec(); l.N = i + 1; l.Time = t[i]; l.Counted = c[i]; laps.Add(l); }
                LapRec b = LapStore.Best(laps);
                Ok("Best() is the quickest COUNTED lap (93.8, not the uncounted 93.5)", b != null && b.N == 3, b == null ? "null" : b.N.ToString());
                Ok("Best() of no counted laps is null (shown as no clean lap)", LapStore.Best(new List<LapRec>()) == null && LapStore.BestTime(new List<LapRec>()) == -1, null);
            }
            else if (mode == "live")
            {
                // frames at 60 Hz: the line at t=0, iRacing announces the time at +1.2 s, its best follows in the SAME frame
                LiveJudge j = new LiveJudge(); j.Seen(93.919);
                j.Line(9, 0, 93.84, 93.919, false, false, 0, 93.919);
                LapRec r = null;
                for (int k = 0; k < 300 && r == null; k++) { double s = k / 60.0; bool on = s >= 1.2; r = j.Poll(s, on ? 93.832 : 93.919, on ? 93.832 : 93.919); }
                Ok("live: a same-frame time + best update is a counted new best", r != null && r.Counted && Math.Abs(r.Time - 93.832) < 1e-6, r == null ? "null" : r.Why);
                // the time changes at the line frame itself (no frame between): still seen, because we compare with the last lap seen
                j.Line(10, 10, 94.99, 93.832, false, false, 0, 94.996);
                r = j.Poll(10, 94.996, 93.832);
                Ok("live: a time announced in the same frame as the lap counter is not missed", r != null && r.Counted && Math.Abs(r.Time - 94.996) < 1e-6, r == null ? "null" : r.Why);
                // a quicker lap whose best never follows: not counted, decided when the window ends
                j.Line(6, 20, 93.64, 93.919, false, false, 0, 94.996);
                r = null; double at = 0;
                for (int k = 0; k < 400 && r == null; k++) { double s = 20 + k / 60.0; r = j.Poll(s, s >= 21.2 ? 93.639 : 94.996, 93.919); at = s - 20; }
                Ok("live: a quicker lap iRacing's best does not follow is not counted", r != null && !r.Counted && r.Why == "not-best", r == null ? "null" : r.Why);
                Ok("live: ... and is decided by the end of the 4 s window", at <= 4.05, at.ToString("0.00"));
                // an incident lap
                j.Line(7, 40, 94.83, 93.919, false, true, 20, 93.639);
                r = null; for (int k = 0; k < 300 && r == null; k++) { double s = 40 + k / 60.0; r = j.Poll(s, s >= 41.9 ? 94.831 : 93.639, 93.919); }
                Ok("live: an incident lap is not counted", r != null && !r.Counted && r.Why == "incident", r == null ? "null" : r.Why);
                // no time at all
                j.Line(8, 60, 94.1, 93.919, false, false, 0, 94.831);
                r = null; for (int k = 0; k < 400 && r == null; k++) { double s = 60 + k / 60.0; r = j.Poll(s, 94.831, 93.919); }
                Ok("live: no time within the window = not counted (no-time)", r != null && !r.Counted && r.Why == "no-time", r == null ? "null" : r.Why);
            }
            else if (mode == "file")
            {
                LapStore.Dir = a[2];
                FileLaps f = LapStore.ForFile(a[1]);
                if (f == null) { Console.WriteLine("FAIL the file could not be read"); return 1; }
                Console.WriteLine("JSON " + LapStore.Json(f));
                FileLaps g = LapStore.ForFile(a[1]);       // from memory
                Console.WriteLine("SAME " + (object.ReferenceEquals(f, g) ? "1" : "0"));
            }
            Console.WriteLine("UNIT-DONE");
            return fails == 0 ? 0 : 1;
        }
    }
}
