using System;
using System.Collections.Generic;
using IRDash;

// tests\spot-test.ps1 compiles this with dash\src\spotcore.cs. Made-up laps at 60 Hz on a 6000 m track; no iRacing, no files.
static class SpotUnit
{
    static int bad = 0;
    static void Check(string what, bool ok) { Console.WriteLine((ok ? "ok    " : "FAIL  ") + what); if (!ok) bad++; }

    const double L = 6000, DT = 1.0 / 60;
    static double clock = 1000;       // session time (keeps running through resets, like iRacing's)
    static long ms = 1700000000000L;

    // drive from pct0 at speed v (m/s) for sec seconds; every frame goes to the core; returns the finished tries
    static List<SpotResult> Drive(SpotCore c, ref double pct, double v, double sec, bool onTrack)
    {
        List<SpotResult> done = new List<SpotResult>();
        int n = (int)Math.Round(sec / DT);
        for (int i = 0; i < n; i++)
        {
            pct = (pct + v * DT / L) % 1.0; clock += DT; ms += 16;
            SpotResult r = c.Step(new SpotSample { Pct = pct, Speed = v, Time = clock, OnTrack = onTrack, Ms = ms });
            if (r != null) done.Add(r);
        }
        return done;
    }

    static SpotResult Frame(SpotCore c, double pct, double v)
    {
        clock += DT; ms += 16;
        return c.Step(new SpotSample { Pct = pct, Speed = v, Time = clock, OnTrack = true, Ms = ms });
    }

    static void Main()
    {
        // ---- where a try ends ----
        int idx;
        double e = SpotCore.PickEnd(0.50, new double[] { 0.52, 0.60, 0.95 }, 0.015, 0.05, out idx);
        Check("the next corner exit ahead is the end", idx == 0 && Math.Abs(e - 0.52) < 1e-9);
        e = SpotCore.PickEnd(0.50, new double[] { 0.52, 0.60, 0.95 }, 0.03, 0.05, out idx);
        Check("an exit closer than the minimum is skipped (the next corner is timed)", idx == 1 && Math.Abs(e - 0.60) < 1e-9);
        e = SpotCore.PickEnd(0.98, new double[] { 0.02, 0.5 }, 0.015, 0.05, out idx);
        Check("works across the start/finish line", idx == 0 && Math.Abs(e - 0.02) < 1e-9);
        e = SpotCore.PickEnd(0.50, new double[0], 0.015, 0.05, out idx);
        Check("no corner list: a fixed stretch ahead", idx == -1 && Math.Abs(e - 0.55) < 1e-9);
        e = SpotCore.PickEnd(0.97, null, 0.015, 0.05, out idx);
        Check("no corner list at the line wraps", idx == -1 && Math.Abs(e - 0.02) < 1e-9);

        // ---- a try is timed from the reset to the corner exit ----
        SpotCore c = new SpotCore();
        double pct = 0.495;
        Drive(c, ref pct, 40, 2.0, true);
        double spot = pct;
        c.Save(spot, 40, (spot + 240 / L) % 1.0, "to the exit of T5");
        Check("nothing runs before a reset", !c.Running && c.Starts == 0);
        Drive(c, ref pct, 40, 8.0, true);
        Check("driving through the spot without a reset does not start a try", !c.Running && c.Starts == 0 && c.Times.Count == 0);
        // BACK TO SPOT pressed (flag), the sim puts the car back at the spot
        c.Back(ms);
        SpotResult r0 = Frame(c, spot, 40);
        Check("a flagged reset to the spot starts a try", c.Running && c.Starts == 1 && r0 == null);
        pct = spot;
        List<SpotResult> d = Drive(c, ref pct, 30, 12.0, true);      // 240 m at 30 m/s = 8.0 s
        Check("the try finishes at the corner exit", d.Count == 1 && d[0].N == 1);
        Check("... timed to the frame (8.00 s, got " + (d.Count == 1 ? d[0].Seconds.ToString("0.000") : "-") + ")", d.Count == 1 && Math.Abs(d[0].Seconds - 8.0) < 0.03);
        Check("the first try is the one to beat", d.Count == 1 && double.IsNaN(d[0].BestBefore) && d[0].NewBest && SpotCore.Say(d[0]).Contains("the one to beat"));

        // ---- second try, slower; a reset made by hand (no flag) is recognised by the jump + same speed ----
        pct = spot + 0.2; Drive(c, ref pct, 40, 1.0, true);
        SpotResult r1 = Frame(c, spot, 40);       // jumped back, speed 40 = the saved speed
        Check("a reset pressed by hand (jump back to the spot at the saved speed) starts a try", c.Running && c.Starts == 2);
        pct = spot; d = Drive(c, ref pct, 28.8, 14.0, true);          // 240 / 28.8 = 8.333 s
        Check("second try slower: best stays, delta is plus", d.Count == 1 && d[0].N == 2 && !d[0].NewBest && Math.Abs(d[0].Delta - (d[0].Seconds - 8.0)) < 0.03 && d[0].Delta > 0.25);
        Check("... the line says best and the plus", SpotCore.Say(d[0]).Contains("best 8.00") && SpotCore.Say(d[0]).Contains("(+0.3"));

        // ---- third try faster = best yet ----
        pct = spot + 0.2; Drive(c, ref pct, 40, 1.0, true);
        Frame(c, spot, 40);
        pct = spot; d = Drive(c, ref pct, 32, 12.0, true);            // 7.5 s
        Check("a faster try is best yet", d.Count == 1 && d[0].NewBest && d[0].N == 3 && Math.Abs(d[0].Seconds - 7.5) < 0.03 && SpotCore.Say(d[0]).Contains("best yet (-0.5"));

        // ---- a jump that is NOT a reset to the spot starts nothing ----
        int starts = c.Starts;
        pct = 0.1; Drive(c, ref pct, 40, 1.0, true);
        Frame(c, 0.3, 40);          // a tow / a different jump
        Check("a jump somewhere else starts no try", c.Starts == starts && !c.Running);
        pct = spot + 0.3; Drive(c, ref pct, 40, 0.5, true);
        Frame(c, spot, 5);          // lands on the spot but the speed is nothing like the saved one: no flag = not ours
        Check("landing on the spot at another speed (no key pressed) starts no try", c.Starts == starts);

        // ---- a reset in the middle of a try starts over; the abandoned try is not counted ----
        c.Back(ms); Frame(c, spot, 40);
        Check("a flagged reset starts try " + (c.Times.Count + 1), c.Running);
        pct = spot; Drive(c, ref pct, 30, 3.0, true);
        int before = c.Times.Count;
        Frame(c, spot, 40);         // reset again mid-try
        pct = spot; d = Drive(c, ref pct, 30, 12.0, true);
        Check("a reset in the middle of a try starts over, timed from the later reset (8.00 s)", d.Count == 1 && Math.Abs(d[0].Seconds - 8.0) < 0.03 && c.Times.Count == before + 1);

        // ---- leaving the car cancels ----
        c.Back(ms); Frame(c, spot, 40);
        pct = spot; d = Drive(c, ref pct, 30, 2.0, true);
        d = Drive(c, ref pct, 30, 1.0, false);
        Check("getting out of the car drops the try (no result)", !c.Running && d.Count == 0 && c.LastCancel.Length > 0);

        // ---- the line: a spot just before the start/finish line ----
        SpotCore w = new SpotCore();
        double wp = 0.992; w.Save(wp, 40, 0.01, "over the line");
        w.Back(ms); Frame(w, wp, 40);
        pct = wp; d = Drive(w, ref pct, 36, 10.0, true);              // (0.01 - 0.992 + 1) * 6000 = 108 m at 36 m/s = 3.0 s
        Check("a try across the start/finish line is timed (3.00 s)", d.Count == 1 && Math.Abs(d[0].Seconds - 3.0) < 0.03);

        // ---- a new spot starts the count over ----
        c.Save(0.2, 30, 0.23, "x");
        Check("saving a new spot clears the tries", c.Times.Count == 0 && double.IsNaN(c.Best) && !c.Running);
        c.Clear();
        Check("clear forgets the spot", !c.Saved);

        // ---- the back flag times out (a key press that did nothing) ----
        SpotCore z = new SpotCore(); z.Save(0.4, 30, 0.43, "x");
        z.Back(ms); ms += 5000;
        Frame(z, 0.4, 30);
        Check("a back flag older than 4 s is dropped (no try)", !z.Running && z.Starts == 0);

        Console.WriteLine(bad == 0 ? "UNIT-DONE" : "UNIT-FAILED");
    }
}
