// Test main for dash\src\fuel.cs (tests\fuel-test.ps1 compiles fuel.cs + lapstore.cs + ibtfile.cs with this). Prints "  ok ..." /
// "  FAIL ..." / "  info ..." lines. Offline: reads one old .ibt (only reads), no irdash, no rig.
//   fuel-main.exe [<12 Nov race .ibt>]
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
                s.Time = Time; s.SessionNum = 2; s.Lap = Lap; s.Flags = flags; s.OnTrack = true;
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
            FuelSample s = new FuelSample(); s.Time = Time; s.SessionNum = 2; s.Lap = Lap; s.Level = Level; s.OnTrack = true; s.Flags = 0x10040000;
            s.LapRace = LapRace; s.LapsRemain = LapsRemain; s.TimeRemain = TimeRemain;
            T.Feed(s); Time += 1 / 15.0;
        }
    }

    static int Main(string[] a)
    {
        Console.WriteLine("Section 1. the pure rules: window, save, laps to go");
        // the card's made-up race: 20 L in the tank, 2.0 L a lap, 15 to go
        string[] w = Fuel.Window(20, 2.0, 15, 24);
        Check("window 20 L / 2.0 / 15 to go / 24 L tank: orange x3 (a full tank there still falls short), green laps 4-10, red 11-15: " + Cells(w),
            Cells(w) == "orange,orange,orange,green,green,green,green,green,green,green,red,red,red,red,red");
        int firstGreen = Array.IndexOf(w, "green");
        Check("the first green cell is lap 4 from now (15-4 = 11 laps x 2.0 x 1.05 = 23.1 L fits the 24 L tank; lap 3 needs 25.2)", firstGreen == 3);
        string[] w2 = Fuel.Window(20, 2.0, 15, 10);
        Check("window with a 10 L tank: no stop can save it -> white up to the dry lap, red after: " + Cells(w2),
            Cells(w2) == "white,white,white,white,white,white,white,white,white,white,red,red,red,red,red");
        string[] w3 = Fuel.Window(20, 2.0, 15, 0);
        Check("tank size unknown: no orange, green until the tank runs dry: " + Cells(w3), Cells(w3) == "green,green,green,green,green,green,green,green,green,green,red,red,red,red,red");
        string[] w4 = Fuel.Window(40, 2.0, 15, 83);
        Check("enough fuel to the end (40 L, 31.5 needed): every cell green, none red", Array.IndexOf(w4, "red") < 0 && Array.IndexOf(w4, "orange") < 0 && w4.Length == 15);
        Check("the bar is capped at " + Fuel.MaxCells + " cells (a long practice)", Fuel.Window(80, 1.0, 500, 90).Length == Fuel.MaxCells);
        double? sv = Fuel.Save(20, 2.0, 10);
        Check("save: 20 L, 2.0 a lap, 10 to go needs 21 L (half a lap short) -> save " + F(sv) + " L a lap (2.0 - 20 / 10.5 = 0.0952 -> 0.10)", Near(sv, 0.10, 0.0001));
        Check("save: more than a lap short (15 to go) -> null (a stop, not saving)", !Fuel.Save(20, 2.0, 15).HasValue);
        Check("save: makes it already (9 to go, 18.9 L needed) -> null", !Fuel.Save(20, 2.0, 9).HasValue);
        Check("laps to go, lap race: iRacing's SessionLapsRemainEx (12)", Fuel.ToGo(true, 12, 600, 90) == 12);
        int? tg = Fuel.ToGo(false, 32767, 514.7, 94.572);
        Check("laps to go, timed race: 514.7 s left / 94.572 a lap = 5.44 -> 6, + 1 = 7 (got " + tg + ")", tg == 7);
        Check("laps to go, timed race on the exact line: 600 s / 60 = 10 -> 10 + 1 = 11", Fuel.ToGo(false, 32767, 600, 60) == 11);
        Check("laps to go: no lap time yet -> null; no limit (a week of practice) -> null", !Fuel.ToGo(false, 32767, 600, null).HasValue && !Fuel.ToGo(false, 32767, 604800, 90).HasValue);
        Check("the not-green flags: caution, yellow, red are; debris and green are not", Fuel.NotGreen(0x4000) && Fuel.NotGreen(0x8000) && Fuel.NotGreen(0x8) && Fuel.NotGreen(0x100) && Fuel.NotGreen(0x10) && !Fuel.NotGreen(0x40) && !Fuel.NotGreen(0x4) && !Fuel.NotGreen(0x10040000));

        Console.WriteLine("Section 2. a made-up race: measuring, caution and pit laps out, reset after a stop, the long view");
        Gen g = new Gen(); g.T.TankL = 60;
        g.Drive(1.0, 0x10000200, 0, 0, 0, 60);                 // lap 0: the formation lap (never a lap)
        g.Clean(2.0); g.Clean(2.0);
        g.Line();
        FuelView v = g.T.View();
        Check("two clean laps: state measuring, measured 2, burn null (" + v.State + ", " + v.Measured + ", " + F(v.Burn) + ")", v.State == "measuring" && v.Measured == 2 && !v.Burn.HasValue);
        Check("the measuring JSON says so: " + v.Json(), v.Json().StartsWith("{\"state\":\"measuring\",\"measured\":2,") && v.Json().Contains("\"burn\":null") && v.Json().Contains("\"window\":null"));
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
        g.Drive(2.0, 0x10040000, 20, 30, 0, 60);              // lap 7: a stop, 30 L in
        g.Line();
        v = g.T.View();
        Check("after a stop (the level rose) the window starts again: measuring, 0 laps, stops 1 (" + v.State + ", " + v.Measured + ", " + g.T.Stops + ")", v.State == "measuring" && v.Measured == 0 && g.T.Stops == 1);
        g.Clean(1.9); g.Clean(2.0); g.Clean(2.1); g.Clean(2.2); g.Clean(2.3);
        g.Line();
        v = g.T.View();
        Check("five clean laps after the stop: burn = last 3 (2.1, 2.2, 2.3) = 2.2 (got " + F(v.Burn) + ")", Near(v.Burn, 2.2, 0.002));
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
        // a lap race: iRacing's count, the save hint and the short state
        Gen lr = new Gen(); lr.LapRace = true; lr.LapsRemain = 14; lr.Level = 30; lr.T.TankL = 50;
        lr.Drive(1.0, 0x10000200, 0, 0, 0, 60); lr.Clean(2.0); lr.Clean(2.0); lr.Clean(2.0); lr.Line();
        FuelView lv = lr.T.View();
        // 30 - 1 (formation) - 3 x 2 = 23 L left, 10 to go (14 - 4 laps driven): 21 L needed -> ok, no save, 1.0 lap spare
        Check("lap race: toGo = SessionLapsRemainEx (" + lv.ToGo + "), 23 L for 21 needed: state ok, save null, spare " + F(lv.Spare) + " laps (11.5 - 10.5)", lv.ToGo == 10 && lv.State == "ok" && !lv.Save.HasValue && Near(lv.Spare, 1.0, 0.01));
        lr.Clean(2.6); lr.Line();          // burn (2 + 2 + 2.6) / 3 = 2.2; 20.4 L left, 9 to go: 20.79 needed, 0.18 of a lap short -> save
        lv = lr.T.View();
        Check("within a lap of making it: state save, save = 2.2 - 20.4 / 9.45 = " + F(lv.Save) + " (" + lv.State + ")", lv.State == "save" && Near(lv.Save, 0.04, 0.0001));
        lr.Clean(3.5); lr.Line();          // burn (2 + 2.6 + 3.5) / 3 = 2.7; 16.9 left, 8 to go: 22.68 needed, 2.1 laps short -> short
        lv = lr.T.View();
        Check("more than a lap short: state short, save null, toEnd " + F(lv.ToEnd) + " L to add (8 x 2.7 x 1.05 - 16.9 = 5.78)", lv.State == "short" && !lv.Save.HasValue && Near(lv.ToEnd, 5.78, 0.02));
        string j = lv.Json();
        string[] names = { "\"state\":", "\"measured\":", "\"level\":", "\"burn\":", "\"burnLong\":", "\"lapsOfFuel\":", "\"toEnd\":", "\"save\":", "\"window\":[" };
        List<string> miss = new List<string>(); foreach (string n in names) if (!j.Contains(n)) miss.Add(n);
        Check("the fuel JSON has every contract name (" + j.Length + " chars): missing " + string.Join(" ", miss.ToArray()), miss.Count == 0);
        Check("samples closer than 1/15 s of sim time are dropped (15 Hz)", !lr.T.Feed(new FuelSample { Time = lr.Time - 1 / 15.0 + 0.01, SessionNum = 2, Lap = lr.Lap, Level = lr.Level }));

        if (a.Length > 0 && System.IO.File.Exists(a[0])) RealRace(a[0]);
        else Info("the 12 Nov race file is not on this PC: section 3 skipped");

        Console.WriteLine("  " + pass + " passed, " + fail + " failed");
        return fail > 0 ? 1 : 0;
    }

    // ---- the 12 Nov Road Atlanta race (timed, 900 s, GR86, tank 83.333 L, no stop, no caution) ----
    static void RealRace(string path)
    {
        Console.WriteLine("Section 3. the 12 Nov race: three clean laps worked out by hand from the file");
        IbtFile t = IbtFile.Open(path, true);
        string[] n = { "SessionTime", "SessionNum", "Lap", "FuelLevel", "SessionFlags", "OnPitRoad", "IsOnTrack", "PlayerTrackSurface", "PlayerCarMyIncidentCount", "LapLastLapTime", "LapBestLapTime", "SessionLapsRemainEx", "SessionTimeRemain" };
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

        FuelTracker tr = new FuelTracker(); tr.TankL = 83.333;
        FuelView at600 = null, at680 = null; double lvl680 = 0, rem680 = 0;
        string history = "";
        for (long i = 0; i < t.Records; i++)
        {
            FuelSample s = new FuelSample();
            s.Time = c[0][i]; s.SessionNum = (int)c[1][i]; s.Lap = (int)c[2][i]; s.Level = c[3][i]; s.Flags = unchecked((uint)(long)c[4][i]);
            s.OnPitRoad = c[5][i] != 0; s.OnTrack = c[6][i] != 0; s.Surface = (int)c[7][i]; s.Incidents = (int)c[8][i];
            s.LastLap = c[9][i]; s.BestLap = c[10][i]; s.HaveBest = true; s.LapRace = false; s.LapsRemain = (int)c[11][i]; s.TimeRemain = c[12][i];
            int before = tr.Laps.Count; string had = LapNs(tr);
            if (!tr.Feed(s)) continue;
            if (LapNs(tr) != had) history += (history.Length > 0 ? " | " : "") + LapNs(tr);
            if (at600 == null && s.Time >= 600) at600 = tr.View();
            if (at680 == null && s.Time >= 680.5) { at680 = tr.View(); lvl680 = s.Level; rem680 = s.TimeRemain; }
        }
        Info("the clean-lap list as it grew: " + history);
        Info("kept " + tr.Samples + " of " + t.Records + " records (" + (tr.Samples / (double)t.Records * 60).ToString("0.0", Inv) + " a second at 60 Hz)");
        Check("about 15 samples a second kept (" + tr.Samples + " of " + t.Records + " records)", Math.Abs(tr.Samples / (double)t.Records * 60 - 15) < 0.5);
        Check("at 600 s (laps 1-3 done): measuring, 2 of 3 (lap 1 is not counted by iRacing): " + at600.State + " " + at600.Measured, at600.State == "measuring" && at600.Measured == 2);
        HashSet<string> ever = new HashSet<string>(history.Replace(" | ", ",").Split(','));
        Check("lap 1 (the start, iRacing gave it no best) and laps 6, 7 (incidents) are never in the list", !ever.Contains("1") && !ever.Contains("6") && !ever.Contains("7") && ever.Contains("2") && ever.Contains("10"));
        Info("at " + "680.5 s: level " + F(lvl680) + " L, time left " + rem680.ToString("0.0", Inv) + " s; tracker: " + at680.Json());
        int handToGo = (int)Math.Ceiling(rem680 / hl) + 1;
        double handLaps = lvl680 / hb, handEnd = handToGo * hb * 1.05 - lvl680;
        Info("hand: lapsOfFuel = " + F(lvl680) + " / " + F(hb) + " = " + handLaps.ToString("0.00", Inv) + "; toGo = ceil(" + rem680.ToString("0.0", Inv) + " / " + hl.ToString("0.000", Inv) + ") + 1 = " + handToGo
             + "; toEnd = " + handToGo + " x " + F(hb) + " x 1.05 - " + F(lvl680) + " = " + handEnd.ToString("0.00", Inv) + " L");
        Check("burn after laps 2, 3, 4 = " + F(at680.Burn) + " (hand " + F(hb) + ", within 0.003 L: the 15 Hz line is up to 3 records late)", Near(at680.Burn, hb, 0.003));
        Check("lapsOfFuel = " + F(at680.LapsOfFuel) + " (hand " + handLaps.ToString("0.000", Inv) + ")", Near(at680.LapsOfFuel, handLaps, 0.2));
        Check("toGo = " + at680.ToGo + " (hand " + handToGo + ", a timed race: time left / average lap + 1)", at680.ToGo == handToGo);
        Check("toEnd = " + F(at680.ToEnd) + " L (hand " + handEnd.ToString("0.000", Inv) + "; negative = spare)", Near(at680.ToEnd, handEnd, 0.03));
        Check("state ok with a full window (no stop needed: every cell green)", at680.State == "ok" && at680.Window != null && at680.Window.Length == handToGo && Array.IndexOf(at680.Window, "green") == 0 && Array.IndexOf(at680.Window, "red") < 0);
        // the end of the race: iRacing counted 2, 3, 4, 5, 8, 9, 10 (tests\lap-truth-test.ps1); the long view = the last 5 of them
        FuelView end = tr.View();
        double hb3 = (used(8) + used(9) + used(10)) / 3, hb5 = (used(4) + used(5) + used(8) + used(9) + used(10)) / 5;
        Info("hand: laps 8, 9, 10 = " + F(used(8)) + ", " + F(used(9)) + ", " + F(used(10)) + " -> " + F(hb3) + "; laps 4, 5, 8, 9, 10 -> " + F(hb5));
        Check("at the flag the kept laps are 4, 5, 8, 9, 10 (" + LapNs(tr) + ")", LapNs(tr) == "4,5,8,9,10");
        Check("burn = laps 8-10 " + F(end.Burn) + " (hand " + F(hb3) + "), long view = 5 laps " + F(end.BurnLong) + " (hand " + F(hb5) + ")", Near(end.Burn, hb3, 0.003) && Near(end.BurnLong, hb5, 0.003));
        Check("no stop seen in the race (the level never rose)", tr.Stops == 0);
        t.Dispose();
    }
}
