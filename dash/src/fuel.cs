// FUEL (W2-1, docs/rework/cards/W2-1.md, PLAN 4.2 "Fuel maths", evidence 08 section 6): burn from the last clean laps, laps to go, fuel
// to the end with the 5 % margin, the pit-window colours and the "save x L/lap" hint, for the race screen's fuel zone.
// Pure rules: no irdash, no clock, no files. FuelTracker is fed one FuelSample per frame (at most 15 a second of sim time; sdkreader.cs
// does that on the reader thread) and read by the state builder at most 4 times a second (View). Litres throughout (the sim's unit).
//   clean lap  = green all the way (no caution, yellow or red flag in SessionFlags), never on pit road, on track (IsOnTrack), not off the
//                track (PlayerTrackSurface 0 for two samples in a row; one blip is not an off, the same as LapRules), and counted by
//                iRacing when the frame has LapBestLapTime (LiveJudge, W0-6); without it the clean rule alone
//   burn       = average fuel used over the last 3 clean laps (burnLong: the last 5); a stop (the level rises) starts again
//   toGo       = SessionLapsRemainEx in a lap race, else time left / average clean lap, rounded up, + 1 (the lap after the flag)
//   toEnd      = toGo x burn x 1.05 - level (litres still to add; negative = spare). The 5 % is the "+1 lap kept back", not a setting.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace IRDash
{
    // what the fuel maths reads from one frame
    sealed class FuelSample
    {
        public double Time;                 // SessionTime, s
        public int SessionNum, Lap;
        public double Level;                // FuelLevel, litres
        public uint Flags;                  // SessionFlags
        public bool OnPitRoad, OnTrack = true;
        public int Surface = 3;             // PlayerTrackSurface: 0 = off track, 3 = on track (-1 not in the world: IsOnTrack says that)
        public int Incidents;               // PlayerCarMyIncidentCount
        public double LastLap, BestLap;     // LapLastLapTime, LapBestLapTime
        public bool HaveBest;               // the frame has LapBestLapTime: iRacing's own verdict can be read (LiveJudge)
        public bool LapRace;                // the session has a lap count (the session YAML; else SessionLapsRemainEx < 32767)
        public int LapsRemain = 32767;      // SessionLapsRemainEx
        public double TimeRemain = -1;      // SessionTimeRemain, s
    }

    sealed class FuelLap { public int N; public double Used, Time; }

    // what the race part shows; the numbers are null until they mean something
    sealed class FuelView
    {
        public string State = "measuring";  // measuring / ok / short / save
        public int Measured;
        public double Level;
        public double? Burn, BurnLong, LapsOfFuel, ToEnd, Spare, Save, AvgLap;
        public int? ToGo;
        public string[] Window;

        static string N(double? v, string fmt) { return v.HasValue && !double.IsNaN(v.Value) && !double.IsInfinity(v.Value) ? v.Value.ToString(fmt, CultureInfo.InvariantCulture) : "null"; }
        public string Json()
        {
            StringBuilder sb = new StringBuilder(200);
            sb.Append("{\"state\":\"").Append(State).Append("\",\"measured\":").Append(Measured)
              .Append(",\"level\":").Append(N(Level, "0.00")).Append(",\"burn\":").Append(N(Burn, "0.000")).Append(",\"burnLong\":").Append(N(BurnLong, "0.000"))
              .Append(",\"lapsOfFuel\":").Append(N(LapsOfFuel, "0.0")).Append(",\"toEnd\":").Append(N(ToEnd, "0.0")).Append(",\"spare\":").Append(N(Spare, "0.0"))
              .Append(",\"save\":").Append(N(Save, "0.00")).Append(",\"window\":");
            if (Window == null) sb.Append("null");
            else { sb.Append('['); for (int i = 0; i < Window.Length; i++) { if (i > 0) sb.Append(','); sb.Append('"').Append(Window[i]).Append('"'); } sb.Append(']'); }
            return sb.Append('}').ToString();
        }
    }

    static class Fuel
    {
        public const double Margin = 1.05;             // "+1 lap kept back" (PLAN): shown, never a setting
        public const int Short = 3, Long = 5;          // laps in the burn average and in the long view
        public const int MaxCells = 60;                // a pit-window bar longer than the screen is no use (a 2-hour practice says 80 laps)
        // the flags that make a lap not green: caution, caution waving, yellow, yellow waving, red (the shared flag table in ui.js; the
        // debris flag 0x40 is a surface warning, not a slow lap: the 12 Nov race had it on laps 2, 3, 4 and 7 at full speed)
        public const uint NotGreenMask = 0x4000 | 0x8000 | 0x8 | 0x100 | 0x10;
        public const uint CautionMask = 0x4000 | 0x8000;
        public static bool NotGreen(uint flags) { return (flags & NotGreenMask) != 0; }
        public static bool Caution(uint flags) { return (flags & CautionMask) != 0; }

        // the live tracker (the reader thread feeds it, the state builder reads it)
        public static readonly FuelTracker Live = new FuelTracker();
        // W2-3: track name -> seconds a stop costs there, null = not measured yet. The lead wires it at merge (Fuel.PitLossFor = PitLoss.For).
        public static Func<string, double?> PitLossFor;

        // laps still to drive: iRacing's own count in a lap race, else from the time left (a "time left" over a day = no limit)
        public static int? ToGo(bool lapRace, int lapsRemain, double timeRemain, double? avgLap)
        {
            if (lapRace || (lapsRemain >= 0 && lapsRemain < 32767)) return lapsRemain >= 0 && lapsRemain < 32767 ? lapsRemain : (int?)null;
            if (timeRemain < 0 || timeRemain > 86400 || !avgLap.HasValue || avgLap.Value <= 0) return null;
            return (int)Math.Ceiling(timeRemain / avgLap.Value - 1e-9) + 1;
        }

        // one cell per lap still to drive (a stop at the end of lap k from now), mgyr's colours:
        //   red    = short: the tank runs dry by that lap if you have not stopped
        //   orange = too early: a full tank put in there still does not reach the end (that stop wastes laps of fuel: you would stop again)
        //   green  = window open: a stop there gets you to the end with the margin
        //   white  = can't finish: no lap is green (the tank runs dry before a stop could cover the rest), so a stop on that lap leaves you short
        // tankL <= 0 = tank size unknown: no orange.
        public static string[] Window(double level, double burn, int toGo, double tankL)
        {
            if (burn <= 0 || toGo <= 0) return new string[0];
            int n = Math.Min(toGo, MaxCells);
            string[] w = new string[n];
            bool green = false;
            for (int k = 1; k <= n; k++)
            {
                double left = level - k * burn, rest = (toGo - k) * burn * Margin;
                if (left < -1e-9) w[k - 1] = "red";
                else if (tankL > 0 && rest > tankL + 1e-9) w[k - 1] = "orange";
                else { w[k - 1] = "green"; green = true; }
            }
            if (!green) for (int i = 0; i < n; i++) if (w[i] == "orange") w[i] = "white";
            return w;
        }

        // litres a lap to save so the fuel lasts to the end with the margin; only when it is within one lap of making it, else null
        public static double? Save(double level, double burn, int toGo)
        {
            if (burn <= 0 || toGo <= 0) return null;
            double need = toGo * burn * Margin;
            if (need <= level) return null;                       // makes it already
            if ((need - level) / burn > 1) return null;            // more than a lap short: a stop, not saving
            return Math.Round(burn - level / (toGo * Margin), 2);
        }
    }

    sealed class FuelTracker
    {
        public const double MinGap = 0.06;              // 15 samples a second of sim time (a 60 Hz feed keeps every 4th frame)
        readonly object gate = new object();
        readonly List<FuelLap> laps = new List<FuelLap>();      // clean laps since the last stop, oldest first (Long kept)
        readonly LiveJudge judge = new LiveJudge();
        FuelLap pending; bool pendingClean;                     // the lap just ended, waiting for iRacing's verdict (at most 4 s)
        int lap = int.MinValue, sess = int.MinValue, offRun;
        double lapStartTime, lapStartLevel; bool dirty, pit, off; int incStart;
        double low; bool filling;                               // the lowest level since the last stop; a stop is being poured now
        double lastTime = double.NaN, lastLevel = double.NaN, lastLlt, lastBest;
        FuelSample last;
        public double TankL;                                    // tank size in litres (DriverCarFuelMaxLtr x DriverCarMaxFuelPct), 0 = unknown
        public double EstLap;                                   // the session's estimate of a lap (DriverCarEstLapTime), used before a lap is timed
        public int Samples, Stops;

        public void Reset()
        {
            lock (gate) { laps.Clear(); judge.Reset(); pending = null; lap = int.MinValue; sess = int.MinValue; lastTime = double.NaN; lastLevel = double.NaN; last = null; offRun = 0; }
        }

        // false = skipped (under 1/15 s of sim time since the last sample kept)
        public bool Feed(FuelSample s)
        {
            if (s == null) return false;
            lock (gate)
            {
                if (!double.IsNaN(lastTime) && s.SessionNum == sess && s.Time >= lastTime && s.Time - lastTime < MinGap) return false;
                Samples++;
                if (s.SessionNum != sess || double.IsNaN(lastTime) || s.Time < lastTime - 1)
                {
                    // a new session (or the clock went back: a new connection): nothing measured carries over
                    laps.Clear(); judge.Reset(); pending = null; sess = s.SessionNum; low = s.Level; filling = false;
                    Start(s); dirty = true;           // joined mid-lap: that lap's fuel is only part of a lap
                }
                else
                {
                    // a stop (or a reset to the pits): the level rose. iRacing pours about 2-3 L a second, 0.2 L a sample, so it is the rise
                    // over the lowest level seen that counts, not one step. The window starts again, the lap with the stop is not clean.
                    if (s.Level < low) low = s.Level;
                    if (s.Level > low + 0.5)
                    {
                        if (!filling) { laps.Clear(); pending = null; judge.Cancel(); Stops++; filling = true; }
                        dirty = true; low = s.Level;
                    }
                    else if (s.Level < lastLevel - 0.0001) filling = false;      // burning again: the stop is over
                    if (Fuel.NotGreen(s.Flags)) dirty = true;
                    if (s.OnPitRoad) pit = true;
                    if (!s.OnTrack) dirty = true;
                    if (s.Surface == 0) { if (++offRun >= 2) off = true; } else offRun = 0;
                    if (s.Lap == lap + 1)
                    {
                        // the line: lap `lap` ended. Lap 0 is the formation lap, never a lap.
                        double used = lapStartLevel - s.Level, lineToLine = s.Time - lapStartTime;
                        bool clean = !dirty && !pit && !off && lap >= 1 && used > 0;
                        if (s.HaveBest)
                        {
                            judge.Line(lap, s.Time, lineToLine, lastBest, pit, s.Incidents > incStart, off ? 1 : 0, lastLlt);
                            pending = new FuelLap { N = lap, Used = used, Time = lineToLine }; pendingClean = clean;
                        }
                        else if (clean) Add(new FuelLap { N = lap, Used = used, Time = lineToLine });
                        Start(s);
                    }
                    else if (s.Lap != lap) { Start(s); dirty = true; }      // a jump (a tow, a reset): not a lap, and the next one starts mid-way
                }
                if (pending != null)
                {
                    LapRec r = judge.Poll(s.Time, s.LastLap, s.BestLap);
                    if (r != null) { if (r.Counted && pendingClean) { pending.Time = r.Time; Add(pending); } pending = null; }
                }
                lastTime = s.Time; lastLevel = s.Level; lastLlt = s.LastLap; lastBest = s.BestLap; last = s;
                return true;
            }
        }

        void Start(FuelSample s)
        {
            lap = s.Lap; lapStartTime = s.Time; lapStartLevel = s.Level; incStart = s.Incidents;
            dirty = Fuel.NotGreen(s.Flags) || !s.OnTrack; pit = s.OnPitRoad; off = false; offRun = 0;
        }

        void Add(FuelLap l) { laps.Add(l); while (laps.Count > Fuel.Long) laps.RemoveAt(0); }

        // the clean laps kept now (oldest first): for the tests and the log
        public List<FuelLap> Laps { get { lock (gate) return new List<FuelLap>(laps); } }

        public FuelView View()
        {
            lock (gate)
            {
                FuelView v = new FuelView();
                int n = laps.Count;
                v.Measured = Math.Min(n, Fuel.Short);
                if (last == null) return v;
                v.Level = last.Level;
                if (n > 0) { double t = 0; for (int i = 0; i < n; i++) t += laps[i].Time; v.AvgLap = t / n; }
                else if (last.LastLap > 1) v.AvgLap = last.LastLap;
                else if (EstLap > 1) v.AvgLap = EstLap;
                v.ToGo = Fuel.ToGo(last.LapRace, last.LapsRemain, last.TimeRemain, v.AvgLap);
                if (n < Fuel.Short) return v;
                double b = 0; for (int i = n - Fuel.Short; i < n; i++) b += laps[i].Used;
                double bl = 0; int nl = Math.Min(n, Fuel.Long); for (int i = n - nl; i < n; i++) bl += laps[i].Used;
                double burn = b / Fuel.Short;
                v.Burn = burn; v.BurnLong = bl / nl;
                v.LapsOfFuel = last.Level / burn;
                v.State = "ok";
                if (v.ToGo.HasValue)
                {
                    int g = v.ToGo.Value;
                    v.ToEnd = g * burn * Fuel.Margin - last.Level;
                    v.Spare = last.Level / burn - g * Fuel.Margin;
                    v.Save = Fuel.Save(last.Level, burn, g);
                    v.Window = Fuel.Window(last.Level, burn, g, TankL);
                    v.State = v.Save.HasValue ? "save" : v.ToEnd.Value > 0 ? "short" : "ok";
                }
                return v;
            }
        }
    }
}
