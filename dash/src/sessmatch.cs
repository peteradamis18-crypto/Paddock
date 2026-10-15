// sessmatch.cs - pure rules for recordings: where a moment lands in the joined video, and which recording belongs
// to a telemetry session. No files, no clocks, no globals, so tests\identity-test.ps1 compiles this file alone.
using System;
using System.Collections.Generic;

namespace IRDash
{
    // one recording as the matcher sees it (from a sidecar)
    sealed class RecCand
    {
        public string Id = "", Track = "", Car = "", Type = "";
        public double StartMs;
        public int SessionNum = -99; public double UniqueId = -1;
    }

    static class SessMatch
    {
        // Where a wall-clock moment falls inside the joined file (seconds), from the segments that really went into it
        // (start/end wall ms, sorted). A moment that is not covered by any of them (a missing segment, out of the car,
        // before or after the recording) is NaN: the video does not have it, so nothing may seek to a later picture.
        public static double WallToFile(double[] starts, double[] ends, double wallMs)
        {
            double cum = 0;
            for (int i = 0; i < starts.Length; i++)
            {
                double s = starts[i], e = ends[i];
                if (e <= s) continue;
                if (wallMs >= s && wallMs <= e) return cum + (wallMs - s) / 1000.0;
                cum += (e - s) / 1000.0;
            }
            return double.NaN;
        }

        // The holes inside the recording: the wall time of every segment that was recorded but is no longer on disk,
        // merged where they touch. Returned as {from, to} pairs in wall ms.
        public static List<double[]> MissingSpans(double[] allStarts, double[] allEnds, bool[] present)
        {
            List<double[]> r = new List<double[]>();
            for (int i = 0; i < allStarts.Length; i++)
            {
                if (present[i] || allEnds[i] <= allStarts[i]) continue;
                if (r.Count > 0 && Math.Abs(r[r.Count - 1][1] - allStarts[i]) < 1) r[r.Count - 1][1] = allEnds[i];
                else r.Add(new double[] { allStarts[i], allEnds[i] });
            }
            return r;
        }

        // "verified" = same iRacing session: SessionUniqueID + SessionNum, the same track, and starting within 12 hours.
        // SessionUniqueID is only a small counter per sim launch (2 is common), so the ids alone repeat across days.
        // "probable" = an old sidecar without that identity, same track, car and type, starting within 2 hours.
        // "none" otherwise. Never newest-wins.
        public static RecCand Pick(List<RecCand> cands, double uniqueId, int sessionNum, string track, string car, string type, double startMs, out string association)
        {
            association = "none";
            if (startMs <= 0) return null;     // without a time the ids cannot tell one day from another
            if (uniqueId > 0 && sessionNum >= 0)
            {
                RecCand v = null; double vd = double.MaxValue;
                foreach (RecCand c in cands)
                {
                    if (c.UniqueId != uniqueId || c.SessionNum != sessionNum) continue;
                    if (track.Length > 0 && c.Track.Length > 0 && !SameName(c.Track, track)) continue;
                    double d = Math.Abs(c.StartMs - startMs);
                    if (d <= 12.0 * 3600 * 1000 && d < vd) { v = c; vd = d; }
                }
                if (v != null) { association = "verified"; return v; }
            }
            RecCand best = null; double bestD = double.MaxValue;
            foreach (RecCand c in cands)
            {
                if (c.UniqueId > 0) continue;   // a sidecar that knows its session and is not this one never stands in
                if (!SameName(c.Track, track)) continue;
                if (car.Length > 0 && c.Car.Length > 0 && !SameName(c.Car, car)) continue;
                if (type.Length > 0 && c.Type.Length > 0 && !string.Equals(c.Type, type, StringComparison.OrdinalIgnoreCase)) continue;
                double d = Math.Abs(c.StartMs - startMs);
                if (d < bestD) { best = c; bestD = d; }
            }
            if (best == null || bestD > 2.0 * 3600 * 1000) return null;
            association = "probable";
            return best;
        }

        static string Alnum(string s) { System.Text.StringBuilder b = new System.Text.StringBuilder(); foreach (char c in (s ?? "")) if (char.IsLetterOrDigit(c)) b.Append(char.ToLowerInvariant(c)); return b.ToString(); }
        public static bool SameName(string a, string b)
        {
            string x = Alnum(a), y = Alnum(b);
            return x.Length > 0 && y.Length > 0 && (x == y || x.Contains(y) || y.Contains(x));
        }
    }
}
