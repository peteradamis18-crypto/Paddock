// Test main for dash\src\pitloss.cs (tests\pitloss-test.ps1 compiles both with log.cs). Prints "  ok ..." / "  FAIL ..." lines.
// args: <tmp dir>. Offline: a pretend driver feeds PitLoss.Feed at 10 Hz; no irdash, no rig, no real file.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using IRDash;

static class PitLossTest
{
    static int pass, fail;
    static void Check(string what, bool ok) { if (ok) { pass++; Console.WriteLine("  ok    " + what); } else { fail++; Console.WriteLine("  FAIL  " + what); } }
    static bool Near(double? a, double b) { return a.HasValue && Math.Abs(a.Value - b) < 0.05; }

    // a pretend car: laps of a given length, 10 samples a second
    class Car
    {
        public string Track = "Road Atlanta", Config = ""; public int Session = 1, Lap = 1;
        public double T = 100; public bool InPit; public int OffNext; public bool Direct;     // OffNext: the next lap starts with that many samples off the track
        public void Cross() { Lap++; }

        // one lap. entryAt/exitAt: seconds into the lap the car enters/leaves pit road (-1 none). stopAt/stopLen: standing still (inside pit road).
        public void Run(double dur, double entryAt, double exitAt, double stopAt, double stopLen, bool pitstopActive, int flags)
        {
            double t0 = T;
            double moved = 0, movingDur = dur - (stopLen > 0 ? stopLen : 0);      // the car does not advance while it stands in its box
            for (double s = 0; s < dur - 0.001; s += 0.1)
            {
                if (entryAt >= 0 && s >= entryAt - 0.001) InPit = true;
                if (exitAt >= 0 && s >= exitAt - 0.001) InPit = false;
                bool still = InPit && stopLen > 0 && s >= stopAt - 0.001 && s < stopAt + stopLen - 0.001;
                double dist = Math.Min(0.999, moved / movingDur);
                if (!still) moved += 0.1;
                Send(t0 + s, dist, still && pitstopActive, flags, s < OffNext * 0.1 - 0.001 ? 0 : (InPit ? (Direct ? 1 : 2) : 3));
            }
            T = t0 + dur; Lap++; OffNext = 0;
        }
        public void Green(double dur) { Run(dur, -1, -1, 0, 0, false, 0); }
        // the typical stop: enters 8 s before the line, stands 20 s (a stop), stays on pit road past the line, leaves 5 s into the out lap
        public void Stop(double inLap, double outLap, bool real, int outFlags)
        {
            Run(inLap, inLap - 28, -1, inLap - 22, real ? 20 : 0, real, 0);
            Run(outLap, -1, 5, 0, 0, false, outFlags);
        }
        public void Send(double t, double dist, bool active, int flags, int surface)
        {
            PitLoss.Feed(t, InPit, Lap, dist, flags, true, surface, active, Track, Config, Session);
        }
        public void Final() { Send(T, 0.0, false, 0, 3); }    // the line that ends the last lap
    }

    static int Lines(string path)
    {
        int n = 0; foreach (string l in File.ReadAllLines(path)) if (l.Trim().Length > 0 && !l.StartsWith("#")) n++; return n;
    }

    static int Main(string[] args)
    {
        string tmp = args[0]; Directory.CreateDirectory(tmp);
        Log.FilePath = Path.Combine(tmp, "irdash.log");
        string data = Path.Combine(tmp, "data");
        PitLoss.Init(data);
        Check("nothing measured at the start: For(Road Atlanta) is null", PitLoss.For("Road Atlanta") == null);

        // 1. one stop
        Car c = new Car();
        c.Green(95);                         // lap 1: partial, seen from the middle: not a reference lap
        for (int i = 0; i < 4; i++) c.Green(95);       // laps 2-5
        c.Stop(110, 112, true, 0);           // lap 6 in, lap 7 out
        c.Green(95); c.Green(95);            // laps 8, 9
        string f = Path.Combine(data, "pitloss.tsv");
        Check("one stop measured (lap 8 crossed)", PitLoss.Measured == 1 && PitLoss.LastWhy == "stored");
        Check("loss = 110 + 112 - 2 x 95 = 32.0: For(Road Atlanta) = " + PitLoss.For("Road Atlanta"), Near(PitLoss.For("Road Atlanta"), 32.0));
        Check("For(Road Atlanta, \"\") = 32.0 too", Near(PitLoss.For("Road Atlanta", ""), 32.0));
        Check("For(Spa) is null", PitLoss.For("Spa") == null);
        string js = PitLoss.Json();
        Check("Json has in 15 and out 17", js.Contains("\"lastIn\":15") && js.Contains("\"lastOut\":17") && js.Contains("\"stops\":1") && js.Contains("\"median\":32"));
        Check("the file has one line: stops 1, median 32", File.Exists(f) && Lines(f) == 1 && File.ReadAllText(f).Contains("Road Atlanta\t\t1\t32\t32\t32\t"));

        // 2. a second stop, then a drive-through
        c.Stop(108, 110, true, 0);           // laps 10, 11: 108 + 110 - 190 = 28
        c.Green(95); c.Green(95);            // laps 12, 13
        Check("second stop: stops 2, median of 32 and 28 = 30.0 (" + PitLoss.For("Road Atlanta") + ")", Near(PitLoss.For("Road Atlanta"), 30.0) && Lines(f) == 1);
        c.Stop(104, 103, false, 0);          // laps 14, 15: a drive-through, never still, no PitstopActive
        c.Green(95);                         // lap 16 (crossing 16 finishes it)
        Check("drive-through counted on its own (LastWhy " + PitLoss.LastWhy + "), stops still 2, median still 30.0", PitLoss.LastWhy == "driveThrough" && Near(PitLoss.For("Road Atlanta"), 30.0)
              && PitLoss.Json().Contains("\"stops\":2") && PitLoss.Json().Contains("\"driveThroughs\":1"));

        // standing still without PitstopActive still counts as a stop (the car stationary >= 2 s on pit road)
        c.Run(110, 82, -1, 88, 20, false, 0); c.Run(112, -1, 5, 0, 0, false, 0); c.Green(95);
        Check("stationary 20 s without PitstopActive is a stop: stops 3 (median " + PitLoss.For("Road Atlanta") + ")", PitLoss.LastWhy == "stored" && PitLoss.Json().Contains("\"stops\":3"));

        // 3. a caution during the out lap: not stored. fewer than 2 clean laps: not stored
        Car k = new Car(); k.Session = 2; k.Track = "Spa"; k.Config = "Grand Prix";
        k.Green(140); for (int i = 0; i < 4; i++) k.Green(140);
        k.Stop(160, 170, true, 0x4000);      // caution flag during the out lap
        k.Green(140); k.Green(140);
        Check("caution in the out lap: not stored (" + PitLoss.LastWhy + ")", PitLoss.LastWhy == "caution" && PitLoss.For("Spa") == null);
        Car m = new Car(); m.Session = 3; m.Track = "Monza";
        m.Green(90); m.Green(90);            // lap 1 partial, lap 2: ONE clean lap
        m.Stop(100, 105, true, 0); m.Green(90); m.Green(90);
        Check("fewer than 2 clean laps: not stored (" + PitLoss.LastWhy + ")", PitLoss.LastWhy == "fewer than 2 clean laps" && PitLoss.For("Monza") == null);
        Car q = new Car(); q.Session = 4; q.Track = "Sebring";   // a lap with a yellow is no reference lap: 3 laps, one under yellow = 2 clean left; with 2 yellows = 1 left
        q.Green(100); q.Green(100); q.Run(100, -1, -1, 0, 0, false, 0x0008); q.Run(100, -1, -1, 0, 0, false, 0x4000);
        q.Stop(120, 125, true, 0); q.Green(100); q.Green(100);
        Check("laps under yellow are no reference: not stored (" + PitLoss.LastWhy + ")", PitLoss.LastWhy == "fewer than 2 clean laps" && PitLoss.For("Sebring") == null);

        // off track: a brush (5 samples) in reference laps is fine; a spin (30 samples) in the in lap is not a measurable stop
        Car o = new Car(); o.Session = 7; o.Track = "Lime Rock";
        o.Green(60); o.OffNext = 5; o.Green(60); o.OffNext = 5; o.Green(60);
        o.Stop(80, 82, true, 0); o.Green(60); o.Green(60);
        Check("a brush off track does not spoil the reference: stored " + PitLoss.For("Lime Rock") + " (80 + 82 - 120 = 42)", Near(PitLoss.For("Lime Rock"), 42.0));
        o.OffNext = 30; o.Run(80, 52, -1, 58, 20, true, 0); o.Run(82, -1, 5, 0, 0, false, 0); o.Green(60);
        Check("a spin in the in lap: not stored (" + PitLoss.LastWhy + "), still 1 stop", PitLoss.LastWhy == "off track" && PitLoss.Json().Contains("\"track\":\"Lime Rock\",\"config\":\"\",\"stops\":1"));

        // a tow / reset to the pits (the car appears in the stall without the pit lane) is no stop; the real 13 Oct Road America file had one
        Car w = new Car(); w.Session = 8; w.Track = "Watkins Glen";
        w.Green(90); w.Green(90); w.Green(90); w.Green(90);
        w.Direct = true; w.Stop(130, 140, true, 0); w.Direct = false; w.Green(90); w.Green(90);
        Check("a jump to the pit stall is not a stop (" + PitLoss.LastWhy + ")", PitLoss.For("Watkins Glen") == null && PitLoss.LastWhy != "stored");
        Car x = new Car(); x.Session = 9; x.Track = "Watkins Glen";
        x.Green(90); x.Green(90); x.Green(90);
        x.Send(x.T + 10, 0.1, false, 0, 3); x.Send(x.T + 10.07, 0.6, false, 0, 3);      // 50 % of the lap in one frame: a reset
        x.Lap = 5; x.Stop(130, 140, true, 0); x.Green(90);
        Check("a jump of half the lap in one frame resets the laps: no stop (" + PitLoss.LastWhy + ")", PitLoss.For("Watkins Glen") == null);

        // another track with a stop that is the first at that track (after Road Atlanta): kept apart
        Car b = new Car(); b.Session = 5; b.Track = "Spa"; b.Config = "Grand Prix";
        b.Green(140); for (int i = 0; i < 3; i++) b.Green(140);
        b.Stop(165, 170, true, 0); b.Green(140); b.Green(140);
        Check("Spa kept apart from Road Atlanta: " + PitLoss.For("Spa") + " vs " + PitLoss.For("Road Atlanta"), Near(PitLoss.For("Spa"), 165 + 170 - 280) && PitLoss.For("Road Atlanta") != null);
        Check("Spa asked with another config is null", PitLoss.For("Spa", "Gran Prix Pits") == null);

        // 4. reload: same numbers; a corrupt line is skipped with one log line
        double? ra = PitLoss.For("Road Atlanta"), spa = PitLoss.For("Spa"); string before = PitLoss.Json();
        File.AppendAllText(f, "this is not a line\r\nBad Track\t\tx\t1\t1\t1\twhen\t1;2\t0\r\n");
        PitLoss.Init(data);
        Check("reload keeps the numbers (" + PitLoss.For("Road Atlanta") + ", " + PitLoss.For("Spa") + ")", PitLoss.For("Road Atlanta") == ra && PitLoss.For("Spa") == spa && PitLoss.Json() == before);
        Log.Flush(3000);
        string log = File.Exists(Log.FilePath) ? File.ReadAllText(Log.FilePath) : "";
        int skipped = 0; int ix = 0; while ((ix = log.IndexOf("skipped a bad line", ix)) >= 0) { skipped++; ix++; }
        Check("two corrupt lines: each skipped with one log line (" + skipped + ")", skipped == 2);
        Check("the stop log line is there", log.Contains("pitloss: Road Atlanta: 32 s (1 stops, median 32)"));

        // 20 samples kept at most
        Car z = new Car(); z.Session = 6; z.Track = "Daytona";
        z.Green(80); z.Green(80); z.Green(80);
        for (int i = 0; i < 23; i++) { z.Stop(100 + i, 100, true, 0); z.Green(80); }
        z.Green(80);
        string line = null; foreach (string l in File.ReadAllLines(f)) if (l.StartsWith("Daytona")) line = l;
        Check("23 stops: stops 23 but only 20 samples kept", line != null && line.Split('\t')[2] == "23" && line.Split('\t')[7].Split(';').Length == 20);
        Check("no half-written .tmp left behind", !File.Exists(f + ".tmp"));

        Console.WriteLine(pass + " passed, " + fail + " failed");
        return fail == 0 ? 0 : 1;
    }
}
