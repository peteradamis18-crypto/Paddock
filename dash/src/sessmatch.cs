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
        public double StartMs, EndMs;        // wall clock (UTC ms) of the first and last recorded picture; EndMs 0 = unknown (old sidecar)
        public int SessionNum = -99; public double UniqueId = -1;
    }

    static class SessMatch
    {
        // How far a moment may sit before a recorded span and still show that span's first picture (encoder start-up).
        public const double SnapMs = 3000;
        // Slack around a recording's span when asking "was this lap driven during this recording?" (file-name clock, seconds).
        public const double SpanSlackMs = 120000;

        // Where a wall-clock moment falls inside the joined file (seconds), from the spans that really went into it
        // (start/end wall ms, sorted). A moment up to SnapMs before a span shows that span's first picture; anything
        // else not covered (a missing segment, out of the car, after the end) is NaN: the video does not have it, so
        // nothing may seek to a later picture and call it this moment.
        public static double WallToFile(double[] starts, double[] ends, double wallMs)
        {
            double cum = 0;
            for (int i = 0; i < starts.Length; i++)
            {
                double s = starts[i], e = ends[i];
                if (e <= s) continue;
                if (wallMs >= s && wallMs <= e) return cum + (wallMs - s) / 1000.0;
                if (wallMs < s) return s - wallMs <= SnapMs ? cum : double.NaN;
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

        // lapMs = the wall-clock time the analysed lap was driven (from the telemetry file).
        // "verified" = same iRacing session (SessionUniqueID + SessionNum; the uid is only a small counter per sim
        //              launch, so it repeats across launches) AND the lap was driven while this recording ran.
        // "probable" = an old sidecar without identity: same track, car and type, and the lap inside its span.
        // "none" otherwise. Never newest-wins, never nearest-in-time.
        public static RecCand Pick(List<RecCand> cands, double uniqueId, int sessionNum, string track, string car, string type, double lapMs, out string association)
        {
            association = "none";
            if (lapMs <= 0) return null;
            if (uniqueId > 0 && sessionNum >= 0)
                foreach (RecCand c in cands)
                {
                    if (c.UniqueId != uniqueId || c.SessionNum != sessionNum || c.EndMs <= 0) continue;
                    if (track.Length > 0 && c.Track.Length > 0 && !SameName(c.Track, track)) continue;
                    if (lapMs >= c.StartMs - SpanSlackMs && lapMs <= c.EndMs + SpanSlackMs) { association = "verified"; return c; }
                }
            foreach (RecCand c in cands)
            {
                if (c.UniqueId > 0) continue;   // a sidecar that knows its session and is not this one never stands in
                if (!SameName(c.Track, track)) continue;
                if (car.Length > 0 && c.Car.Length > 0 && !SameName(c.Car, car)) continue;
                if (type.Length > 0 && c.Type.Length > 0 && !string.Equals(c.Type, type, StringComparison.OrdinalIgnoreCase)) continue;
                double end = c.EndMs > 0 ? c.EndMs : c.StartMs + 3600000;   // old sidecars: duration excludes time out of the car
                if (lapMs >= c.StartMs - SpanSlackMs && lapMs <= end + SpanSlackMs) { association = "probable"; return c; }
            }
            return null;
        }

        static string Alnum(string s) { System.Text.StringBuilder b = new System.Text.StringBuilder(); foreach (char c in (s ?? "")) if (char.IsLetterOrDigit(c)) b.Append(char.ToLowerInvariant(c)); return b.ToString(); }
        public static bool SameName(string a, string b)
        {
            string x = Alnum(a), y = Alnum(b);
            return x.Length > 0 && y.Length > 0 && (x == y || x.Contains(y) || y.Contains(x));
        }
    }
}
