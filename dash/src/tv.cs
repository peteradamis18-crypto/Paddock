using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    // Read-only 10 Hz TV data. Every field in a published object comes from one Frame reference.
    static class Tv
    {
        sealed class Driver
        {
            public int Idx, ClassId; public string Num = "", Name = "", ClassName = "", Color = "";
        }
        sealed class Car
        {
            public Driver Driver; public double Pct, Progress, Last, F2, Gap, Interval; public int Lap, Pos, ClassPos; public bool Pit;
        }
        static readonly object Gate = new object();
        static string latest = Empty();
        static Thread worker;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly Dictionary<string, double> PairSince = new Dictionary<string, double>();
        static int SessionVersion = -1; static double PreviousTick = double.NaN;
        static string Director = "LEADER"; static double DirectorSince = double.NaN;

        static string Empty() { return "{\"tick\":null,\"track\":\"\",\"config\":\"\",\"lengthM\":null,\"playerIdx\":-1,\"cars\":[],\"battles\":[],\"director\":\"LEADER\"}"; }
        public static string Json() { lock (Gate) return latest; }
        public static void Start()
        {
            if (worker != null) return;
            worker = new Thread(delegate () { while (true) { try { Frame f = Sdk.Latest; string s = Build(f); lock (Gate) latest = s; } catch (Exception ex) { Log.W("tv sample: " + ex.Message); lock (Gate) latest = Empty(); } Thread.Sleep(100); } });
            worker.IsBackground = true; worker.Priority = ThreadPriority.BelowNormal; worker.Name = "irdash TV data"; worker.Start();
        }
        static string YVal(string block, string key)
        {
            Match m = Regex.Match(block ?? "", "(?m)^[ \\t]*" + Regex.Escape(key) + ":[ \\t]*([^\\r\\n]*?)[ \\t]*\\r?$");
            return m.Success ? m.Groups[1].Value.Trim().Trim('"') : "";
        }
        static string Section(string yaml, string key)
        {
            Match m = Regex.Match(yaml ?? "", "(?m)^" + Regex.Escape(key) + ":"); if (!m.Success) return "";
            string rest = yaml.Substring(m.Index + m.Length); Match n = Regex.Match(rest, "(?m)^[A-Za-z]"); return n.Success ? rest.Substring(0, n.Index) : rest;
        }
        static int Int(string s, int d) { int n; return int.TryParse(s, NumberStyles.Integer, Inv, out n) ? n : d; }
        static VarDef Var(Frame f, string name) { VarDef d; return f.Vars != null && f.Vars.TryGetValue(name, out d) ? d : null; }
        static double Read(Frame f, VarDef d, int i)
        {
            if (d == null || f.Data == null || i < 0 || i >= d.Count) return double.NaN;
            int size = d.Type <= 1 ? 1 : d.Type == 5 ? 8 : 4, p = d.Offset + i * size; if (p < 0 || p + size > f.Data.Length) return double.NaN;
            switch (d.Type) { case 0: case 1: return f.Data[p]; case 2: case 3: return BitConverter.ToInt32(f.Data, p); case 4: return BitConverter.ToSingle(f.Data, p); case 5: return BitConverter.ToDouble(f.Data, p); }
            return double.NaN;
        }
        static string N(double d, string fmt) { return double.IsNaN(d) || double.IsInfinity(d) ? "null" : d.ToString(fmt, Inv); }
        static string Build(Frame f)
        {
            if (f == null || !f.Connected) { PairSince.Clear(); SessionVersion = -1; PreviousTick = double.NaN; Director = "LEADER"; DirectorSince = double.NaN; return Empty(); }
            if (SessionVersion != f.SessionVersion) { PairSince.Clear(); SessionVersion = f.SessionVersion; PreviousTick = double.NaN; Director = "LEADER"; DirectorSince = double.NaN; }
            string yaml = f.SessionYaml ?? "", wk = Section(yaml, "WeekendInfo"), di = Section(yaml, "DriverInfo");
            List<Driver> ds = new List<Driver>(); int player = Int(YVal(di, "DriverCarIdx"), -1);
            string[] blocks = Regex.Split(di, "(?m)^[ \\t]*- CarIdx:");
            for (int b = 1; b < blocks.Length; b++)
            {
                string x = blocks[b]; Driver d = new Driver(); d.Idx = Int((Regex.Match(x, "^\\s*(-?\\d+)").Success ? Regex.Match(x, "^\\s*(-?\\d+)").Groups[1].Value : ""), -1);
                if (d.Idx < 0 || d.Idx >= 64 || YVal(x, "CarIsPaceCar") == "1" || YVal(x, "IsSpectator") == "1") continue;
                d.Name = YVal(x, "UserName"); d.Num = YVal(x, "CarNumberRaw"); if (d.Num.Length == 0) d.Num = YVal(x, "CarNumber");
                d.ClassId = Int(YVal(x, "CarClassID"), -1); d.ClassName = YVal(x, "CarClassShortName");
                string col = YVal(x, "CarClassColor"); d.Color = Regex.IsMatch(col, "^(0x)?[0-9a-fA-F]{6}$") ? Regex.Replace(col, "^(0x)?", "").ToLowerInvariant() : "";
                ds.Add(d);
            }
            double length = 0; Match lm = Regex.Match(YVal(wk, "TrackLength"), @"^([\d.]+)\s*(km|mi)", RegexOptions.IgnoreCase);
            if (lm.Success) { double v; if (double.TryParse(lm.Groups[1].Value, NumberStyles.Float, Inv, out v)) length = v * (lm.Groups[2].Value.ToLowerInvariant() == "mi" ? 1609.344 : 1000.0); }
            VarDef pct = Var(f, "CarIdxLapDistPct"), lap = Var(f, "CarIdxLap"), completed = Var(f, "CarIdxLapCompleted"), pit = Var(f, "CarIdxOnPitRoad"), last = Var(f, "CarIdxLastLapTime");
            VarDef f2 = Var(f, "CarIdxF2Time");
            List<Car> ordered = new List<Car>();
            for (int i = 0; i < ds.Count; i++)
            {
                Driver d = ds[i]; double p = Read(f, pct, d.Idx), la = Read(f, lap, d.Idx), lc = Read(f, completed, d.Idx), pi = Read(f, pit, d.Idx), ls = Read(f, last, d.Idx), gap = Read(f, f2, d.Idx);
                if (double.IsNaN(p) || p < 0 || double.IsNaN(la) || double.IsNaN(pi)) continue;
                if (p >= 1) p -= Math.Floor(p);
                Car c = new Car(); c.Driver = d; c.Pct = p; c.Lap = (int)la; c.Pit = pi != 0; c.Last = ls; c.F2 = gap;
                c.Progress = (double.IsNaN(lc) ? la : lc) + p; ordered.Add(c);
            }
            // Race order uses completed laps plus lap fraction; pit/garage cars follow everyone on track.
            bool race = Regex.IsMatch(yaml, "(?im)^\\s*SessionType:\\s*Race\\s*$");
            ordered.Sort(delegate(Car a, Car b) { if (a.Pit != b.Pit) return a.Pit ? 1 : -1; int n = race ? b.Progress.CompareTo(a.Progress) : BestOrder(a, b); return n != 0 ? n : a.Driver.Idx.CompareTo(b.Driver.Idx); });
            for (int i = 0; i < ordered.Count; i++) { ordered[i].Pos = i + 1; int cpv = 1; for (int j = 0; j < i; j++) if (ordered[j].Driver.ClassId == ordered[i].Driver.ClassId) cpv++; ordered[i].ClassPos = cpv; }
            // Positive F2 values are usable relative timing. Otherwise estimate from distance and a lap-time speed.
            double leaderTime = 0; for (int i = 0; i < ordered.Count; i++) if (!ordered[i].Pit && ordered[i].Last > 0) { leaderTime = ordered[i].Last; break; }
            if (leaderTime <= 0) leaderTime = 90.0;
            double leaderDistance = ordered.Count > 0 ? ordered[0].Progress * length : 0;
            for (int i = 0; i < ordered.Count; i++)
            {
                Car c = ordered[i];
                if (i == 0) { c.Interval = 0; c.Gap = 0; continue; }
                Car ahead = ordered[i - 1]; double dt = c.F2 > 0 ? c.F2 : double.NaN;
                if (double.IsNaN(dt) && length > 0) { double dist = (ahead.Progress - c.Progress) * length; if (dist < 0) dist += length; dt = dist * leaderTime / length; }
                c.Interval = dt;
                double leaderGap = c.F2 > 0 ? ahead.Gap + c.F2 : (length > 0 ? (leaderDistance - c.Progress * length) * leaderTime / length : double.NaN);
                if (leaderGap < 0 && !double.IsNaN(leaderGap)) leaderGap += leaderTime;
                // Pit-lane progress can be behind the leader on the lap fraction while order puts it last.
                // Keep numeric leader gaps consistent with the published running order.
                if (!double.IsNaN(leaderGap) && !double.IsNaN(ahead.Gap) && leaderGap < ahead.Gap) leaderGap = ahead.Gap;
                c.Gap = leaderGap;
            }
            List<string> cars = new List<string>();
            for (int i = 0; i < ordered.Count; i++) { Car c = ordered[i]; Driver d = c.Driver; cars.Add("{\"idx\":" + d.Idx + ",\"num\":" + Json_.S(d.Num) + ",\"name\":" + Json_.S(d.Name) + ",\"classId\":" + (d.ClassId < 0 ? "null" : d.ClassId.ToString(Inv)) + ",\"className\":" + Json_.S(d.ClassName) + ",\"classColor\":" + Json_.S(d.Color) + ",\"pct\":" + N(c.Pct, "0.########") + ",\"pos\":" + c.Pos + ",\"classPos\":" + c.ClassPos + ",\"pit\":" + (c.Pit ? "true" : "false") + ",\"lap\":" + c.Lap + ",\"last\":" + N(c.Last, "0.########") + ",\"gap\":" + N(c.Gap, "0.########") + ",\"interval\":" + N(c.Interval, "0.########") + "}"); }
            List<string> battles = new List<string>(); HashSet<string> active = new HashSet<string>(); double tickValue = f.Num("SessionTime");
            if (!double.IsNaN(PreviousTick) && tickValue < PreviousTick) PairSince.Clear();
            PreviousTick = tickValue;
            HashSet<int> battled = new HashSet<int>();
            if (!double.IsNaN(tickValue)) for (int a = 1; a < ordered.Count; a++)
            {
                Car ca = ordered[a - 1], cb = ordered[a]; if (battled.Contains(ca.Driver.Idx) || battled.Contains(cb.Driver.Idx) || ca.Pit || cb.Pit || ca.Driver.ClassId < 0 || ca.Driver.ClassId != cb.Driver.ClassId || double.IsNaN(cb.Interval) || cb.Interval > 0.8) continue;
                string key = Math.Min(ca.Driver.Idx, cb.Driver.Idx) + ":" + Math.Max(ca.Driver.Idx, cb.Driver.Idx) + ":" + ca.Driver.ClassId; active.Add(key);
                double since; if (!PairSince.TryGetValue(key, out since)) { PairSince[key] = tickValue; continue; }
                if (tickValue - since >= 5.0) { battles.Add("{\"a\":" + ca.Driver.Idx + ",\"b\":" + cb.Driver.Idx + "}"); battled.Add(ca.Driver.Idx); battled.Add(cb.Driver.Idx); }
            }
            List<string> expired = new List<string>(); foreach (string key in PairSince.Keys) if (!active.Contains(key)) expired.Add(key);
            foreach (string key in expired) PairSince.Remove(key);
            string proposed = "LEADER"; int playerAt = -1;
            for (int i = 0; i < ordered.Count; i++) if (ordered[i].Driver.Idx == player) { playerAt = i; break; }
            for (int i = 0; i < battles.Count; i++)
            {
                Match pair = Regex.Match(battles[i], "\\\"a\\\":(\\d+),\\\"b\\\":(\\d+)");
                if (pair.Success && (Int(pair.Groups[1].Value, -2) == player || Int(pair.Groups[2].Value, -2) == player)) { proposed = "BATTLE"; break; }
            }
            if (proposed == "LEADER" && playerAt >= 0 && playerAt + 1 < ordered.Count)
            {
                Car behind = ordered[playerAt + 1];
                if (!behind.Pit && !double.IsNaN(behind.Interval) && behind.Interval >= 0 && behind.Interval <= 1.5) proposed = "CHASE";
            }
            if (proposed == "LEADER" && !double.IsNaN(tickValue) && tickValue % 60.0 < 10.0) proposed = "TRACK";
            if (double.IsNaN(DirectorSince)) DirectorSince = tickValue;
            if (proposed != Director)
            {
                double held = tickValue - DirectorSince;
                if (proposed == "BATTLE" || (proposed == "TRACK" && Director == "LEADER") || (proposed == "CHASE" && Director == "LEADER") || held >= 8.0) { Director = proposed; DirectorSince = tickValue; }
            }
            string tr = YVal(wk, "TrackDisplayName"); if (tr.Length == 0) tr = YVal(wk, "TrackName");
            string cfg = YVal(wk, "TrackConfigName"); double tick = tickValue;
            return "{\"tick\":" + N(tick, "0.000") + ",\"track\":" + Json_.S(tr) + ",\"config\":" + Json_.S(cfg) + ",\"lengthM\":" + (length > 0 ? N(length, "0.###") : "null") + ",\"playerIdx\":" + player + ",\"cars\":[" + string.Join(",", cars.ToArray()) + "],\"battles\":[" + string.Join(",", battles.ToArray()) + "],\"director\":" + Json_.S(Director) + "}";
        }
        static int BestOrder(Car a, Car b) { bool av = a.Last > 0, bv = b.Last > 0; if (av != bv) return av ? -1 : 1; if (av && a.Last != b.Last) return a.Last.CompareTo(b.Last); return b.Pct.CompareTo(a.Pct); }
    }
}
