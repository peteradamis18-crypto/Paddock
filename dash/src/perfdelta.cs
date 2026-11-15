// The Coach Dave Delta comparison (W5-3, docs\rework\DELTA-TEST.md "primary method"): Peter's own races split into "Delta was running"
// and "Delta was not", from the per-session reports that already exist (perf.tsv + the program sampler's list of other programs).
// No new poller, no new file: PerfJson.Overview hands the races over, this does the arithmetic and the one sentence RIG shows.
// Pure (tests\blackbox-test.ps1 compiles it on its own).
using System;
using System.Collections.Generic;
using System.Globalization;

namespace IRDash
{
    sealed class DcRace { public bool Delta; public double Avg, Worst; public bool Froze; }

    static class DeltaCompare
    {
        public const int Need = 2;          // races on each side before the sentence compares
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // the sampler's group for Delta is "Coach Dave Delta"; the bare program name is "CoachDave..." on some installs
        public static bool IsDelta(string program)
        {
            if (string.IsNullOrEmpty(program)) return false;
            return program.IndexOf("Delta", StringComparison.OrdinalIgnoreCase) >= 0 || program.IndexOf("CoachDave", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        sealed class Side { public int N, Freezes; public double Avg, Worst = double.MaxValue; }

        static Side Sum(List<DcRace> races, bool delta)
        {
            Side s = new Side(); double sum = 0;
            foreach (DcRace r in races)
            {
                if (r.Delta != delta) continue;
                s.N++; sum += r.Avg; if (r.Worst < s.Worst) s.Worst = r.Worst; if (r.Froze) s.Freezes++;
            }
            if (s.N > 0) s.Avg = sum / s.N;
            return s;
        }

        static string SideJson(Side s)
        {
            return "{\"races\":" + s.N + ",\"avg\":" + (s.N > 0 ? s.Avg.ToString("0.0", Inv) : "null") + ",\"worst\":" + (s.N > 0 ? s.Worst.ToString("0.0", Inv) : "null") + ",\"freezes\":" + s.Freezes + "}";
        }

        static string Freezes(Side s, bool sayRaces)
        {
            string tail = " in " + s.N + (sayRaces ? (s.N == 1 ? " race" : " races") : "");
            if (s.Freezes == 0) return "none" + tail;
            return s.Freezes + (s.Freezes == 1 ? " freeze" : " freezes") + tail;
        }

        // "With Coach Dave Delta: avg 104 fps, worst 23.7, 1 freeze in 3 races. Without: avg 109, worst 71, none in 2."
        public static string Say(List<DcRace> races)
        {
            Side w = Sum(races, true), o = Sum(races, false);
            if (w.N < Need || o.N < Need) return "Not enough races yet to compare Coach Dave Delta on and off (" + w.N + " with, " + o.N + " without).";
            return "With Coach Dave Delta: avg " + Math.Round(w.Avg).ToString("0", Inv) + " fps, worst " + w.Worst.ToString("0.#", Inv) + ", " + Freezes(w, true) + "." +
                   " Without: avg " + Math.Round(o.Avg).ToString("0", Inv) + ", worst " + o.Worst.ToString("0.#", Inv) + ", " + Freezes(o, false) + ".";
        }

        // the /perf "delta" object: {"with":{races,avg,worst,freezes},"without":{...},"say":"..."}
        public static string Json(List<DcRace> races)
        {
            return "{\"with\":" + SideJson(Sum(races, true)) + ",\"without\":" + SideJson(Sum(races, false)) + ",\"say\":" + Json_.S(Say(races)) + "}";
        }
    }
}
