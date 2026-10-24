using System;
using System.Collections.Generic;

namespace IRDash
{
    // Practice loop, pure part (no iRacing, no files): SAVE SPOT remembers where the car is, BACK TO SPOT (iRacing's Active
    // Reset) puts it there again, and every try from the spot is timed to the end of the next corner. dash\src\spot.cs feeds
    // this one frame at a time from the live telemetry; tests\spot-test.ps1 runs it on made-up laps.
    // Lap positions are fractions of a lap (0..1, wrapping at the start/finish line), the same as iRacing's LapDistPct.
    sealed class SpotSample
    {
        public double Pct, Speed, Time;      // LapDistPct, m/s, SessionTime (s: keeps running through an Active Reset)
        public bool OnTrack;
        public long Ms;                      // unix ms the frame arrived (to match a key press to a frame)
    }

    sealed class SpotResult
    {
        public int N;                        // this is the Nth finished try since the spot was saved
        public double Seconds;               // the try
        public double BestBefore = double.NaN;   // best of the earlier tries (NaN for the first)
        public double Best;                  // best including this one
        public bool NewBest;                 // faster than every earlier try (the first try counts)
        public double Delta;                 // this try minus the best of the earlier tries (0 for the first)
    }

    sealed class SpotCore
    {
        public const double StartTol = 0.004;        // a reset we asked for puts the car within this much of a lap of the spot
        public const double HandTol = 0.002;         // a reset pressed by hand has to match the spot more tightly ...
        public const double HandSpeedTol = 3.0;      // ... and the speed (m/s)
        public const double JumpMin = 0.004;         // the car cannot move this far in one frame: it was put there
        public const double MaxTrySeconds = 240;

        public bool Saved;
        public double SpotPct, SpotSpeed, EndPct;    // EndPct: where the timed stretch ends (absolute lap fraction)
        public string Where = "";                    // plain words: "T5 Kettle Bottoms exit"
        public bool Running;
        public int Starts;                           // counts every start of a try (the key waits for this to change)
        public readonly List<double> Times = new List<double>();
        public double Best = double.NaN;
        public string LastCancel = "";               // why the last try that did not finish was dropped
        public bool BackPending; public long BackAtMs;

        double tStart, prevProg, prevTime, prevPct = -1;

        public static double Wrap(double d) { d = d % 1.0; if (d > 0.5) d -= 1; if (d < -0.5) d += 1; return d; }
        public static double Fwd(double from, double to) { double d = (to - from) % 1.0; return d < 0 ? d + 1 : d; }
        public double EndProg { get { return Fwd(SpotPct, EndPct); } }

        // Where does the timed stretch end? The first corner exit ahead of the spot that is at least minFrac away (the corner the spot is in,
        // or the next one); with no corner list, fallbackFrac of a lap ahead. exits are lap fractions of the corners' ends. index = which one (-1 none).
        public static double PickEnd(double spot, IList<double> exits, double minFrac, double fallbackFrac, out int index)
        {
            index = -1; double bestAhead = double.MaxValue;
            if (exits != null)
                for (int i = 0; i < exits.Count; i++)
                {
                    double ahead = Fwd(spot, exits[i]);
                    if (ahead >= minFrac && ahead < bestAhead) { bestAhead = ahead; index = i; }
                }
            if (index >= 0) return (spot + bestAhead) % 1.0;
            return (spot + fallbackFrac) % 1.0;
        }

        public void Save(double pct, double speed, double endPct, string where)
        {
            Saved = true; SpotPct = pct; SpotSpeed = speed; EndPct = endPct; Where = where ?? "";
            Running = false; Times.Clear(); Best = double.NaN; LastCancel = ""; BackPending = false; prevPct = -1;
        }

        public void Clear() { Saved = false; Running = false; Times.Clear(); Best = double.NaN; BackPending = false; prevPct = -1; }

        public void Back(long nowMs) { BackPending = true; BackAtMs = nowMs; }

        void Begin(SpotSample s)
        {
            // a reset puts the car back exactly where it was saved: take iRacing's own number over our estimate from the key press
            SpotPct = s.Pct; SpotSpeed = s.Speed;
            Running = true; Starts++; tStart = s.Time; prevProg = 0; prevTime = s.Time; LastCancel = "";
        }

        // One telemetry frame. Returns the finished try, or null.
        public SpotResult Step(SpotSample s)
        {
            SpotResult done = null;
            if (!Saved) { prevPct = s.Pct; return null; }
            bool firstFrame = prevPct < 0;
            double jump = firstFrame ? 0 : Math.Abs(Wrap(s.Pct - prevPct));
            double d = Math.Abs(Wrap(s.Pct - SpotPct));
            if (BackPending && s.Ms - BackAtMs > 4000) BackPending = false;
            bool backFresh = BackPending && s.Ms >= BackAtMs - 150;

            if (backFresh && d < StartTol) { Begin(s); BackPending = false; }
            else if (!firstFrame && jump > JumpMin && d < HandTol && Math.Abs(s.Speed - SpotSpeed) < HandSpeedTol) Begin(s);    // a reset (also one during a try, or one pressed by hand)
            else if (Running)
            {
                double prog = Fwd(SpotPct, s.Pct), end = EndProg;
                if (!s.OnTrack) Cancel("you left the car");
                else if (s.Time < tStart - 0.2) Cancel("the session clock went back");
                else if (s.Time - tStart > MaxTrySeconds) Cancel("too long");
                else if (prog >= end)
                {
                    if (prog < end + 0.2)
                    {
                        double span = prog - prevProg, frac = span > 1e-9 ? (end - prevProg) / span : 1;
                        if (frac < 0) frac = 0; if (frac > 1) frac = 1;
                        double secs = prevTime + frac * (s.Time - prevTime) - tStart;
                        done = Finish(secs);
                    }
                    else Cancel("the car went past the end");
                }
                if (Running) { prevProg = prog; prevTime = s.Time; }
            }
            prevPct = s.Pct;
            return done;
        }

        void Cancel(string why) { Running = false; LastCancel = why; }

        SpotResult Finish(double secs)
        {
            SpotResult r = new SpotResult();
            r.BestBefore = Best;
            Times.Add(secs); r.N = Times.Count; r.Seconds = secs;
            r.NewBest = double.IsNaN(Best) || secs < Best - 0.0005;
            if (r.NewBest) Best = secs;
            r.Best = Best; r.Delta = double.IsNaN(r.BestBefore) ? 0 : secs - r.BestBefore;
            Running = false;
            return r;
        }

        public static string Secs(double s)
        {
            if (s >= 60) { int m = (int)(s / 60); return m + ":" + (s - m * 60).ToString("00.00", System.Globalization.CultureInfo.InvariantCulture); }
            return s.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture);
        }

        // the line for the top screen
        public static string Say(SpotResult r)
        {
            string t = "Try " + r.N + ": " + Secs(r.Seconds) + " s";
            if (double.IsNaN(r.BestBefore)) return t + " - the one to beat";
            if (r.NewBest) return t + " - best yet (" + (r.Delta).ToString("+0.00;-0.00", System.Globalization.CultureInfo.InvariantCulture) + ")";
            return t + " - best " + Secs(r.Best) + " (" + r.Delta.ToString("+0.00;-0.00", System.Globalization.CultureInfo.InvariantCulture) + ")";
        }
    }
}
