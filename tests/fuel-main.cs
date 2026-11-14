// Test main for dash\src\fuel.cs (tests\fuel-test.ps1 compiles fuel.cs + lapstore.cs + ibtfile.cs with this). Prints "  ok ..." /
// "  FAIL ..." / "  info ..." lines. Offline: reads old .ibt files (only reads), no irdash, no rig.
//   fuel-main.exe [<12 Nov race .ibt> [<a lap-limited session .ibt>]]
using System;
using System.Collections.Generic;
using System.Globalization;
using IRDash;

namespace IRDash
{
    static class Json { public static string Str(string s) { return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; } }
    static class Json_ { public static string S(string s) { return Json.Str(s ?? ""); } }
    static class Log { public static void W(string m) { } }
}

static class FuelTest
{
    static int pass, fail;
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    static void Check(string what, bool ok) { if (ok) { pass++; Console.WriteLine("  ok    " + what); } else { fail++; Console.WriteLine("  FAIL  " + what); } }
    static void Info(string s) { Console.WriteLine("  info  " + s); }
    static string F(double v) { return v.ToString("0.0000", Inv); }
    static string F(double? v) { return v.HasValue ? F(v.Value) : "null"; }
    static bool Near(double? a, double b, double tol) { return a.HasValue && Math.Abs(a.Value - b) <= tol; }
    static string Cells(string[] w) { return w == null ? "null" : string.Join(",", w); }
    static string Rep(string c, int n) { string[] a = new string[n]; for (int i = 0; i < n; i++) a[i] = c; return string.Join(",", a); }
    static string LapNs(FuelTracker t) { List<string> s = new List<string>(); foreach (FuelLap l in t.Laps) s.Add(l.N.ToString(Inv)); return string.Join(",", s.ToArray()); }

    // ---- a made-up session: 15 samples a second, laps of lapTime seconds burning `burn` litres ----
    sealed class Gen
    {
        public FuelTracker T = new FuelTracker();
        public double Time = 100, Level = 60; public int Lap = 0; public double TimeRemain = 3000;
        public bool LapRace; public int LapsRemain = 32767;
        // one lap: flags all the way, pitSecs on pit road at its start (refuel litres added there), offSecs off the track in the middle
        public void Drive(double burn, uint flags, double pitSecs, double refuel, double offSecs, double lapTime)
        {
            int n = (int)Math.Round(lapTime * 15);
            for (int i = 0; i < n; i++)
            {
                double sec = i / 15.0;
                FuelSample s = new FuelSample();
                s.Time = Time; s.SessionNum = 2; s.Lap = Lap; s.Pct = sec / lapTime; s.Flags = flags; s.OnTrack = true;
                s.OnPitRoad = sec < pitSecs;
                if (refuel > 0 && sec < pitSecs && sec >= pitSecs / 2) Level += refuel / (pitSecs / 2 * 15);
                s.Surface = offSecs > 0 && sec >= lapTime / 2 && sec < lapTime / 2 + offSecs ? 0 : 3;
                s.Level = Level; s.HaveBest = false; s.LapRace = LapRace; s.LapsRemain = LapsRemain; s.TimeRemain = TimeRemain;
                T.Feed(s);
                Time += 1 / 15.0; TimeRemain -= 1 / 15.0; Level -= burn / n;
            }
            Lap++;
            if (LapRace && LapsRemain > 0) LapsRemain--;
        }
        public void Clean(double burn) { Drive(burn, 0x10040000, 0, 0, 0, 60); }
        // the first sample of the next lap (the line itself)
        public void Line()
        {
            FuelSample s = new FuelSample(); s.Time = Time; s.SessionNum = 2; s.Lap = Lap; s.Pct = 0; s.Level = Level; s.OnTrack = true; s.Flags = 0x10040000;
            s.LapRace = LapRace; s.LapsRemain = LapsRemain; s.TimeRemain = TimeRemain;
            T.Feed(s); Time += 1 / 15.0;
        }
    }

    static int Main(string[] a)
    {
        Console.WriteLine("Section 1. the pure rules: window, save, laps to go");
        // the card's made-up race: 20 L in the tank, 2.0 L a lap, 15 to go, on the line
        string[] w = Fuel.Window(20, 2.0, 15, 0, 24);
        Check("window 20 L / 2.0 / 15 to go / 24 L tank: orange x3 (a full tank there still falls short), green laps 4-10, red 11-15: " + Cells(w),
            Cells(w) == Rep("orange", 3) + "," + Rep("green", 7) + "," + Rep("red", 5));
        Check("the first green cell is lap 4 from now (15-4 = 11 laps x 2.0 x 1.05 = 23.1 L fits the 24 L tank; lap 3 needs 25.2); one stop", Array.IndexOf(w, "green") == 3 && Fuel.WindowStops(20, 2.0, 15, 0, 24) == 1);
        string[] w2 = Fuel.Window(20, 2.0, 15, 0, 10);
        Check("a two-stop race (10 L tank, 11.5 L to add): the bar is for the NEXT stop, not all white: orange 1-5, green 6-10 (the rest fits in two tanks of 4.76 laps), red 11-15: " + Cells(w2),
            Cells(w2) == Rep("orange", 5) + "," + Rep("green", 5) + "," + Rep("red", 5) && Fuel.WindowStops(20, 2.0, 15, 0, 10) == 2);
        string[] w5 = Fuel.Window(19.9, 2.0, 15, 0, 11.6);
        Check("the fewest full tanks (1) do not work in whole laps (19.9 L, 11.6 L tank): one stop more -> green 4-9, " + Fuel.WindowStops(19.9, 2.0, 15, 0, 11.6) + " stops: " + Cells(w5),
            Cells(w5) == Rep("orange", 3) + "," + Rep("green", 6) + "," + Rep("red", 6) && Fuel.WindowStops(19.9, 2.0, 15, 0, 11.6) == 2);
        string[] w3 = Fuel.Window(20, 2.0, 15, 0, 0);
        Check("tank size unknown: no orange, green until the tank runs dry: " + Cells(w3), Cells(w3) == Rep("green", 10) + "," + Rep("red", 5));
        string[] w4 = Fuel.Window(40, 2.0, 15, 0, 83);
        Check("enough fuel to the end (40 L, 31.5 needed): every cell green, no stop needed", Cells(w4) == Rep("green", 15) && Fuel.WindowStops(40, 2.0, 15, 0, 83) == 0);
        string[] w6 = Fuel.Window(20, 2.0, 15, 0.5, 24);
        Check("half way round the lap (pct 0.5) the lines come half a lap sooner: the tank still reaches line 10 (19 L used), dry before 11: " + Cells(w6), Cells(w6) == Rep("orange", 3) + "," + Rep("green", 7) + "," + Rep("red", 5));
        Check("half way round with 19.5 L: line 10 needs 19 L (green), on the line it needed 20 (red)", Fuel.Window(19.5, 2.0, 15, 0.5, 24)[9] == "green" && Fuel.Window(19.5, 2.0, 15, 0, 24)[9] == "red");
        Check("the bar is capped at " + Fuel.MaxCells + " cells (a long practice)", Fuel.Window(80, 1.0, 500, 0, 90).Length == Fuel.MaxCells);
        double? sv = Fuel.Save(20, 2.0, 10);
        Check("save: 20 L, 2.0 a lap, 10 laps to go needs 21 L (half a lap short) -> save " + F(sv) + " L a lap (2.0 - 20 / 10.5 = 0.0952 -> 0.10)", Near(sv, 0.10, 0.0001));
        Check("save: more than a lap short (15 to go) -> null (a stop, not saving)", !Fuel.Save(20, 2.0, 15).HasValue);
        Check("save: makes it already (9 to go, 18.9 L needed) -> null", !Fuel.Save(20, 2.0, 9).HasValue);
        Check("laps to go, lap race: iRacing's SessionLapsRemainEx (12)", Fuel.ToGo(true, 12, 600, 90, 0.3) == 12);
        int? tg = Fuel.ToGo(false, 32767, 514.7, 94.572, 0);
        Check("laps to go, timed race on the line: 514.7 s left / 94.572 a lap = 5.44 -> 6, + 1 = 7 (got " + tg + ")", tg == 7);
        Check("laps to go, timed race on the exact line: 600 s / 60 = 10 -> 10 + 1 = 11", Fuel.ToGo(false, 32767, 600, 60, 0) == 11);
        Check("laps to go, timed race half way round: 300 s / 60 + 0.5 = 5.5 -> 6 laps with this one, + 1 = 7", Fuel.ToGo(false, 32767, 300, 60, 0.5) == 7);
        Check("laps to go: no lap time yet -> null; no limit (a week of practice) -> null", !Fuel.ToGo(false, 32767, 600, null, 0).HasValue && !Fuel.ToGo(false, 32767, 604800, 90, 0).HasValue);
        Check("the not-green flags: caution, yellow, red are; debris and green are not", Fuel.NotGreen(0x4000) && Fuel.NotGreen(0x8000) && Fuel.NotGreen(0x8) && Fuel.NotGreen(0x100) && Fuel.NotGreen(0x10) && !Fuel.NotGreen(0x40) && !Fuel.NotGreen(0x4) && !Fuel.NotGreen(0x10040000));

        Console.WriteLine("Section 2. a made-up race: measuring, caution and pit laps out, a stop keeps the burn (stale), the long view");
        Gen g = new Gen(); g.T.TankL = 60; g.T.EstLap = 61;
        g.Drive(1.0, 0x10000200, 0, 0, 0, 60);                 // lap 0: the formation lap (never a lap)
        FuelView v0 = g.T.View();
        Check("at the start (no clean lap yet) the average lap is the session's estimate, 61 s (got " + F(v0.AvgLap) + "), toGo = ceil(" + g.TimeRemain.ToString("0", Inv) + " / 61) + 1 = " + v0.ToGo,
            Near(v0.AvgLap, 61, 0.0001) && v0.ToGo == (int)Math.Ceiling(g.TimeRemain / 61 + 1 - 1 / 900.0) + 1);
        g.Clean(2.0); g.Clean(2.0);
        g.Line();
        FuelView v = g.T.View();
        Check("two clean laps: state measuring, measured 2, burn null (" + v.State + ", " + v.Measured + ", " + F(v.Burn) + "), average lap 60 (" + F(v.AvgLap) + ")", v.State == "measuring" && v.Measured == 2 && !v.Burn.HasValue && Near(v.AvgLap, 60, 0.01));
        Check("the measuring JSON says so: " + v.Json(), v.Json().StartsWith("{\"state\":\"measuring\",\"measured\":2,\"stale\":false,") && v.Json().Contains("\"burn\":null") && v.Json().Contains("\"window\":null"));
        g.Drive(0.8, 0x4000, 0, 0, 0, 60);                     // lap 3 under caution, slow and thrifty
        g.Line();
        Check("a caution lap is not a clean lap (still 2 measured)", g.T.View().Measured == 2 && LapNs(g.T) == "1,2");
        g.Clean(2.3);
        g.Line();
        v = g.T.View();
        Check("three clean laps (1, 2, 4): burn = (2.0 + 2.0 + 2.3) / 3 = 2.1 (got " + F(v.Burn) + "), the caution lap's 0.8 is not in it", Near(v.Burn, 2.1, 0.002) && LapNs(g.T) == "1,2,4" && v.State != "measuring");
        g.Drive(3.0, 0x10040000, 8, 0, 0, 60);                 // lap 5 through the pit lane, no fuel taken
        g.Line();
        v = g.T.View();
        Check("a pit lap is not in the average (laps 1, 2, 4; burn still 2.1)", LapNs(g.T) == "1,2,4" && Near(v.Burn, 2.1, 0.002));
        g.Drive(2.0, 0x10040000, 0, 0, 3, 60);                 // lap 6: 3 s off the track
        g.Line();
        Check("an off-track lap is not in the average", LapNs(g.T) == "1,2,4");
        g.Drive(2.0, 0x10040000, 40, 30, 0, 90);              // lap 7: a stop, 30 L in, a 90 s lap
        g.Line();
        v = g.T.View();
        Check("after a stop (the level rose) the burn is kept but stale: " + v.State + ", burn " + F(v.Burn) + ", stale " + v.Stale + ", stops " + g.T.Stops, v.State != "measuring" && Near(v.Burn, 2.1, 0.002) && v.Stale && g.T.Stops == 1 && v.Json().Contains("\"stale\":true"));
        Check("the average lap after the stop stays the clean laps' 60 s, not the 90 s stop lap (got " + F(v.AvgLap) + ", a 15 Hz line is 1/15 s coarse)", Near(v.AvgLap, 60, 0.1));
        g.Clean(1.9); g.Clean(2.0);
        g.Line();
        Check("two new clean laps: still stale", g.T.View().Stale);
        g.Clean(2.1); g.Clean(2.2); g.Clean(2.3);
        g.Line();
        v = g.T.View();
        Check("three new clean laps: no longer stale; burn = last 3 (2.1, 2.2, 2.3) = 2.2 (got " + F(v.Burn) + ")", !v.Stale && Near(v.Burn, 2.2, 0.002));
        Check("the long view = last 5 (1.9 ... 2.3) = 2.1 (got " + F(v.BurnLong) + ")", Near(v.BurnLong, 2.1, 0.002));
        g.Clean(2.4);
        g.Line();
        Check("a sixth lap pushes the oldest out of the long view (2.0 ... 2.4 = 2.2, got " + F(g.T.View().BurnLong) + ")", Near(g.T.View().BurnLong, 2.2, 0.002) && g.T.Laps.Count == 5);
        // a timed race from time left
        Gen tr = new Gen(); tr.TimeRemain = 400; tr.Level = 30;
        tr.Drive(1.0, 0x10000200, 0, 0, 0, 60); tr.Clean(2.0); tr.Clean(2.0); tr.Clean(2.0); tr.Line();
        FuelView tv = tr.T.View();
        double left = tr.TimeRemain;
        int wantToGo = (int)Math.Ceiling(left / 60.0) + 1;
        Check("timed race: toGo from time left " + left.ToString("0.0", Inv) + " s / 60 s laps = " + tv.ToGo + " (want " + wantToGo + ")", tv.ToGo == wantToGo);
        Check("timed race: toEnd = toGo x 2.0 x 1.05 - level = " + F(tv.ToEnd), Near(tv.ToEnd, wantToGo * 2.0 * 1.05 - tr.Level, 0.01));
        // a lap race: iRacing's count, spare and margin, the save hint and the short state
        Gen lr = new Gen(); lr.LapRace = true; lr.LapsRemain = 14; lr.Level = 30; lr.T.TankL = 50;
        lr.Drive(1.0, 0x10000200, 0, 0, 0, 60); lr.Clean(2.0); lr.Clean(2.0); lr.Clean(2.0); lr.Line();
        FuelView lv = lr.T.View();
        // 30 - 1 (formation) - 3 x 2 = 23 L = 11.5 laps, 10 to go: spare 1.5 laps, margin 0.5 lap -> ok, no save
        Check("lap race: toGo = SessionLapsRemainEx (" + lv.ToGo + "), 11.5 laps of fuel: spare " + F(lv.Spare) + " = 11.5 - 10, margin " + F(lv.Margin) + " = 0.05 x 10, state ok", lv.ToGo == 10 && lv.State == "ok" && !lv.Save.HasValue && Near(lv.Spare, 1.5, 0.01) && Near(lv.Margin, 0.5, 0.0001));
        lr.Clean(2.6); lr.Line();          // burn (2 + 2 + 2.6) / 3 = 2.2; 20.4 L left, 9 to go: 20.79 needed, 0.18 of a lap short -> save
        lv = lr.T.View();
        Check("within a lap of making it: state save, save = 2.2 - 20.4 / 9.45 = " + F(lv.Save) + " (" + lv.State + "); spare " + F(lv.Spare) + " under the margin " + F(lv.Margin), lv.State == "save" && Near(lv.Save, 0.04, 0.0001) && lv.Spare < lv.Margin);
        lr.Clean(3.5); lr.Line();          // burn (2 + 2.6 + 3.5) / 3 = 2.7; 16.9 left, 8 to go: 22.68 needed, 2.1 laps short -> short
        lv = lr.T.View();
        Check("more than a lap short: state short, save null, toEnd " + F(lv.ToEnd) + " L to add (8 x 2.7 x 1.05 - 16.9 = 5.78), one stop", lv.State == "short" && !lv.Save.HasValue && Near(lv.ToEnd, 5.78, 0.02) && lv.Stops == 1);
        string j = lv.Json();
        string[] names = { "\"state\":", "\"measured\":", "\"stale\":", "\"level\":", "\"burn\":", "\"burnLong\":", "\"lapsOfFuel\":", "\"toEnd\":", "\"spare\":", "\"margin\":", "\"save\":", "\"stops\":", "\"window\":[" };
        List<string> miss = new List<string>(); foreach (string n in names) if (!j.Contains(n)) miss.Add(n);
        Check("the fuel JSON has every contract name (" + j + "): missing " + string.Join(" ", miss.ToArray()), miss.Count == 0);
        Check("samples closer than 1/15 s of sim time are dropped (15 Hz)", !lr.T.Feed(new FuelSample { Time = lr.Time - 1 / 15.0 + 0.01, SessionNum = 2, Lap = lr.Lap, Level = lr.Level }));
        MidLap();

        if (a.Length > 0 && System.IO.File.Exists(a[0])) RealRace(a[0]);
        else Info("skip: the 12 Nov race file is not on this PC: section 3 skipped");
        if (a.Length > 1 && System.IO.File.Exists(a[1])) LapCount(a[1]);
        else Info("skip: no lap-limited session file could be read: section 4 skipped");

        Console.WriteLine("  " + pass + " passed, " + fail + " failed");
        return fail > 0 ? 1 : 0;
    }

    // the rest of the current lap counts: a lap race, 10 to go (this lap included), half way round
    static void MidLap()
    {
        FuelTracker t = new FuelTracker(); t.TankL = 50;
        double time = 100, level = 30; int lap = 0;
        Action<double, double, int> lapOf = delegate (double burn, double secs, int remain)
        {
            int n = (int)Math.Round(secs * 15);
            for (int i = 0; i < n; i++)
            {
                FuelSample s = new FuelSample { Time = time, SessionNum = 2, Lap = lap, Pct = i / 900.0, Level = level, Flags = lap == 0 ? 0x10000200u : 0x10040000u, LapRace = true, LapsRemain = remain, TimeRemain = -1 };
                t.Feed(s); time += 1 / 15.0; level -= burn / 900;
            }
        };
        lapOf(1.0, 60, 13); lap++; lapOf(2.0, 60, 13); lap++; lapOf(2.0, 60, 12); lap++; lapOf(2.0, 60, 11); lap++;
        lapOf(2.0, 30, 10);             // half of lap 4: SessionLapsRemainEx 10 counts this lap
        FuelView v = t.View();
        double dist = 10 - 0.4989;      // the last sample sat at pct 449/900
        Check("half way round with 10 to go: distance " + F(v.Distance) + " laps (10 - pct), toEnd = " + F(v.ToEnd) + " = distance x 2.0 x 1.05 - " + F(v.Level), v.ToGo == 10 && Near(v.Distance, dist, 0.002) && Near(v.ToEnd, dist * 2.0 * 1.05 - v.Level, 0.01));
    }

    // ---- the 12 Nov Road Atlanta race (timed, 900 s, GR86, tank 83.333 L, no stop, no caution) ----
    static void RealRace(string path)
    {
        Console.WriteLine("Section 3. the 12 Nov race: three clean laps worked out by hand from the file");
        IbtFile t = IbtFile.Open(path, true);
        string[] n = { "SessionTime", "SessionNum", "Lap", "FuelLevel", "SessionFlags", "OnPitRoad", "IsOnTrack", "PlayerTrackSurface", "PlayerCarMyIncidentCount", "LapLastLapTime", "LapBestLapTime", "SessionLapsRemainEx", "SessionTimeRemain", "LapDistPct" };
        double[][] c = t.Channels(n, 0, t.Records);
        // by hand: the records where the lap counter moves (60 Hz), the fuel there, and iRacing's own time for each lap (LapLastLapTime 4 s after the line)
        Dictionary<int, long> line = new Dictionary<int, long>();      // lap N ends at line[N] (the first record of lap N + 1)
        for (long i = 1; i < t.Records; i++) if ((int)c[2][i] == (int)c[2][i - 1] + 1) line[(int)c[2][i - 1]] = i;
        Func<int, double> used = delegate (int lap) { return c[3][line[lap - 1]] - c[3][line[lap]]; };
        Func<int, double> time = delegate (int lap) { long k = Math.Min(t.Records - 1, line[lap] + 240); return c[9][k]; };
        foreach (int lap in new[] { 2, 3, 4 })
            Info("hand: lap " + lap + " fuel " + F(c[3][line[lap - 1]]) + " -> " + F(c[3][line[lap]]) + " = " + F(used(lap)) + " L, iRacing's time " + time(lap).ToString("0.000", Inv) + " s");
        double hb = (used(2) + used(3) + used(4)) / 3, hl = (time(2) + time(3) + time(4)) / 3;
        Info("hand: burn (laps 2, 3, 4) = " + F(hb) + " L a lap, average lap " + hl.ToString("0.000", Inv) + " s");

        FuelTracker tr = new FuelTracker(); tr.TankL = 83.333; tr.EstLap = 91.2545;
        FuelView at600 = null, at680 = null; double lvl680 = 0, rem680 = 0, pct680 = 0;
        string history = "";
        for (long i = 0; i < t.Records; i++)
        {
            FuelSample s = new FuelSample();
            s.Time = c[0][i]; s.SessionNum = (int)c[1][i]; s.Lap = (int)c[2][i]; s.Level = c[3][i]; s.Flags = unchecked((uint)(long)c[4][i]);
            s.OnPitRoad = c[5][i] != 0; s.OnTrack = c[6][i] != 0; s.Surface = (int)c[7][i]; s.Incidents = (int)c[8][i];
            s.LastLap = c[9][i]; s.BestLap = c[10][i]; s.HaveBest = true; s.LapRace = false; s.LapsRemain = (int)c[11][i]; s.TimeRemain = c[12][i]; s.Pct = c[13][i];
            string had = LapNs(tr);
            if (!tr.Feed(s)) continue;
            if (LapNs(tr) != had) history += (history.Length > 0 ? " | " : "") + LapNs(tr);
            if (at600 == null && s.Time >= 600) at600 = tr.View();
            if (at680 == null && s.Time >= 680.5) { at680 = tr.View(); lvl680 = s.Level; rem680 = s.TimeRemain; pct680 = s.Pct; }
        }
        Info("the clean-lap list as it grew: " + history);
        Check("about 15 samples a second kept (" + tr.Samples + " of " + t.Records + " records)", Math.Abs(tr.Samples / (double)t.Records * 60 - 15) < 0.5);
        Check("at 600 s (laps 1-3 done): measuring, 2 of 3 (lap 1 is not counted by iRacing): " + at600.State + " " + at600.Measured, at600.State == "measuring" && at600.Measured == 2);
        HashSet<string> ever = new HashSet<string>(history.Replace(" | ", ",").Split(','));
        Check("lap 1 (the start, iRacing gave it no best) and laps 6, 7 (incidents) are never in the list", !ever.Contains("1") && !ever.Contains("6") && !ever.Contains("7") && ever.Contains("2") && ever.Contains("10"));
        Info("at 680.5 s: level " + F(lvl680) + " L, time left " + rem680.ToString("0.0", Inv) + " s, " + pct680.ToString("0.000", Inv) + " round the lap; tracker: " + at680.Json());
        int handToGo = (int)Math.Ceiling(rem680 / hl + pct680) + 1;
        double dist = handToGo - pct680;
        double handLaps = lvl680 / hb, handEnd = dist * hb * 1.05 - lvl680;
        Info("hand: lapsOfFuel = " + F(lvl680) + " / " + F(hb) + " = " + handLaps.ToString("0.00", Inv) + "; toGo = ceil(" + rem680.ToString("0.0", Inv) + " / " + hl.ToString("0.000", Inv) + " + " + pct680.ToString("0.000", Inv) + ") + 1 = " + handToGo
             + "; distance " + dist.ToString("0.000", Inv) + "; toEnd = " + dist.ToString("0.000", Inv) + " x " + F(hb) + " x 1.05 - " + F(lvl680) + " = " + handEnd.ToString("0.00", Inv) + " L; spare " + (handLaps - dist).ToString("0.00", Inv) + " laps");
        Check("burn after laps 2, 3, 4 = " + F(at680.Burn) + " (hand " + F(hb) + ", within 0.003 L: the 15 Hz line is up to 3 records late)", Near(at680.Burn, hb, 0.003));
        Check("lapsOfFuel = " + F(at680.LapsOfFuel) + " (hand " + handLaps.ToString("0.000", Inv) + ")", Near(at680.LapsOfFuel, handLaps, 0.2));
        Check("toGo = " + at680.ToGo + " (hand " + handToGo + ", a timed race: time left / average lap + the part done + 1)", at680.ToGo == handToGo);
        Check("toEnd = " + F(at680.ToEnd) + " L (hand " + handEnd.ToString("0.000", Inv) + "; negative = spare)", Near(at680.ToEnd, handEnd, 0.03));
        Check("spare " + F(at680.Spare) + " laps (hand " + (handLaps - dist).ToString("0.000", Inv) + "), margin " + F(at680.Margin) + " (0.05 x distance)", Near(at680.Spare, handLaps - dist, 0.2) && Near(at680.Margin, 0.05 * dist, 0.001));
        Check("state ok with a full window (no stop needed: every cell green, stops 0)", at680.State == "ok" && at680.Window != null && at680.Window.Length == handToGo && Array.IndexOf(at680.Window, "red") < 0 && Array.IndexOf(at680.Window, "orange") < 0 && at680.Stops == 0);
        FuelView end = tr.View();
        double hb3 = (used(8) + used(9) + used(10)) / 3, hb5 = (used(4) + used(5) + used(8) + used(9) + used(10)) / 5;
        Info("hand: laps 8, 9, 10 = " + F(used(8)) + ", " + F(used(9)) + ", " + F(used(10)) + " -> " + F(hb3) + "; laps 4, 5, 8, 9, 10 -> " + F(hb5));
        Check("at the flag the kept laps are 4, 5, 8, 9, 10 (" + LapNs(tr) + ")", LapNs(tr) == "4,5,8,9,10");
        Check("burn = laps 8-10 " + F(end.Burn) + " (hand " + F(hb3) + "), long view = 5 laps " + F(end.BurnLong) + " (hand " + F(hb5) + ")", Near(end.Burn, hb3, 0.003) && Near(end.BurnLong, hb5, 0.003));
        Check("no stop seen in the race (the level never rose), never stale", tr.Stops == 0 && !end.Stale);
        t.Dispose();
    }

    // ---- what SessionLapsRemainEx counts, from a real lap-limited session (13 Nov Lone Qualify, 2 laps) ----
    static void LapCount(string path)
    {
        Console.WriteLine("Section 4. SessionLapsRemainEx in a real lap-limited session: " + System.IO.Path.GetFileName(path));
        IbtFile t = IbtFile.Open(path, true);
        string[] n = { "Lap", "LapDistPct", "SessionLapsRemainEx", "SessionNum" };
        double[][] c = t.Channels(n, 0, t.Records);
        Dictionary<string, int> seen = new Dictionary<string, int>();
        int lastLap = -99; bool half = false;
        for (long i = 0; i < t.Records; i++)
        {
            int lap = (int)c[0][i], lre = (int)c[2][i];
            string k = null;
            if (lap != lastLap) { k = "line" + lap; lastLap = lap; half = false; }
            else if (!half && c[1][i] > 0.5) { k = "mid" + lap; half = true; }
            if (k != null && !seen.ContainsKey(k)) { seen[k] = lre; Info(k + ": SessionLapsRemainEx " + lre + " (pct " + c[1][i].ToString("0.000", Inv) + ", session " + c[3][i] + ")"); }
        }
        Func<string, int> at = delegate (string k) { return seen.ContainsKey(k) ? seen[k] : -99; };
        Check("it counts the lap he is on: 2 on lap 1 (both timed laps to go), 1 at the line and half way round lap 2, 0 after its line",
            at("mid1") == 2 && at("line2") == 1 && at("mid2") == 1 && at("line3") == 0);
        int? tg = Fuel.ToGo(true, at("mid2"), -1, null, 0.5);
        Check("so toGo half way round lap 2 = " + tg + " and the distance = 1 - 0.5 = half a lap (the fuel maths take toGo - LapDistPct)", tg == 1);
        t.Dispose();
    }
}
