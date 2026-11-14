// PIT LOSS (W2-3, docs/rework/cards/W2-3.md): time a pit stop costs at each track, learned from Peter's own stops and kept in
// data\pitloss.tsv. Shown only once measured ("YOU REJOIN P7" row; the lead wires Fuel.PitLossFor = PitLoss.For and calls PitLoss.Feed
// once per frame from the SDK frame path). Pure: no timer, no thread, no request path; the one write (a few hundred bytes) happens
// at the moment a stop has been measured.
// How: loss = (in-lap + out-lap) - 2 x reference lap; the reference is the median of the clean laps of the session before the stop
// (green all the way, no pit road, no off-track; W2-1's rule). A caution in the in/out laps or fewer than 2 clean laps: not stored.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace IRDash
{
    static class PitLoss
    {
        // yellow, yellow waving, caution, caution waving, red: a lap with any of these is not a green lap
        const int NotGreen = 0x0008 | 0x0100 | 0x4000 | 0x8000 | 0x10000;
        const int Keep = 20;                      // samples kept per track
        const int OffLimit = 15;                 // more than ~1 s off the track in a lap (15 samples) and it is no reference lap; a brush is fine
        const double StillSec = 2.0;              // stationary this long on pit road = a real stop

        sealed class TrackRec
        {
            public string Track = "", Config = "";
            public int Stops, DriveThroughs;
            public double Last, LastIn, LastOut;
            public string LastWhen = "";
            public List<double> Samples = new List<double>();
        }

        sealed class LapInfo { public double Time; public bool Pit, Caution; public int OffSamples; public bool Off { get { return OffSamples > OffLimit; } } }

        sealed class Pending { public int EntryLap, ExitLap; public bool Stopped; }

        static readonly object gate = new object();
        static readonly Dictionary<string, TrackRec> recs = new Dictionary<string, TrackRec>();
        static string file;

        // session state (all cleared by Reset)
        static string curTrack = "", curConfig = ""; static int curSession = int.MinValue;
        static double lastT = double.NaN, lastPct = double.NaN; static int lastSurface = 3;
        static int curLap = int.MinValue; static double lapStartT = double.NaN; static LapInfo curInfo;
        static readonly Dictionary<int, LapInfo> laps = new Dictionary<int, LapInfo>();
        static bool wasPit, stopSeen; static int entryLap; static double stillSince = double.NaN, lastDist = double.NaN;
        static Pending pending;

        public static int Measured;          // stops measured since start (tests, log)
        public static string LastWhy = "";   // why the last finished pit visit was or was not stored (tests, log)

        // ---------- file ----------
        public static void Init(string dataDir)
        {
            lock (gate)
            {
                recs.Clear(); Reset(); curTrack = ""; Measured = 0; LastWhy = "";
                file = Path.Combine(dataDir, "pitloss.tsv");
                if (!File.Exists(file)) return;
                string[] lines;
                try { lines = File.ReadAllLines(file, Encoding.UTF8); }
                catch (Exception ex) { Log.W("pitloss: cannot read " + file + ": " + ex.Message); return; }
                foreach (string l in lines)
                {
                    if (l.Trim().Length == 0 || l.StartsWith("#")) continue;
                    try
                    {
                        string[] c = l.Split('\t');
                        if (c.Length < 9) throw new FormatException("columns " + c.Length);
                        TrackRec r = new TrackRec(); r.Track = c[0]; r.Config = c[1];
                        r.Stops = int.Parse(c[2], CultureInfo.InvariantCulture);
                        r.Last = Num(c[5]); r.LastWhen = c[6];
                        if (c[7].Length > 0) foreach (string s in c[7].Split(';')) r.Samples.Add(Num(s));
                        r.DriveThroughs = int.Parse(c[8], CultureInfo.InvariantCulture);
                        if (c.Length > 9) r.LastIn = Num(c[9]);
                        if (c.Length > 10) r.LastOut = Num(c[10]);
                        if (r.Track.Length == 0 || r.Stops < 0) throw new FormatException("track/stops");
                        recs[Key(r.Track, r.Config)] = r;
                    }
                    catch (Exception ex) { Log.W("pitloss: skipped a bad line in pitloss.tsv (" + ex.Message + "): " + Cut(l)); }
                }
            }
        }

        static string Cut(string s) { return s.Length > 60 ? s.Substring(0, 60) : s; }
        static double Num(string s) { return double.Parse(s, NumberStyles.Float, CultureInfo.InvariantCulture); }
        static string F(double d) { return d.ToString("0.###", CultureInfo.InvariantCulture); }
        static string Key(string track, string config) { return (track ?? "").Trim().ToLowerInvariant() + "|" + (config ?? "").Trim().ToLowerInvariant(); }

        // temp + move, so a crash never leaves half a file
        static void Save()
        {
            if (file == null) return;
            try
            {
                StringBuilder sb = new StringBuilder();
                sb.Append("# track\tconfig\tstops\tmedian\tmean\tlast\tlastWhen\tsamples\tdriveThroughs\tlastIn\tlastOut\r\n");
                foreach (TrackRec r in recs.Values)
                {
                    string[] s = new string[r.Samples.Count]; for (int i = 0; i < s.Length; i++) s[i] = F(r.Samples[i]);
                    sb.Append(r.Track).Append('\t').Append(r.Config).Append('\t').Append(r.Stops).Append('\t').Append(F(Median(r.Samples))).Append('\t')
                      .Append(F(Mean(r.Samples))).Append('\t').Append(F(r.Last)).Append('\t').Append(r.LastWhen).Append('\t').Append(string.Join(";", s))
                      .Append('\t').Append(r.DriveThroughs).Append('\t').Append(F(r.LastIn)).Append('\t').Append(F(r.LastOut)).Append("\r\n");
                }
                Directory.CreateDirectory(Path.GetDirectoryName(file));
                string tmp = file + ".tmp";
                File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
                if (File.Exists(file)) File.Replace(tmp, file, null); else File.Move(tmp, file);
            }
            catch (Exception ex) { Log.W("pitloss: save failed: " + ex.Message); }
        }

        static double Median(List<double> v)
        {
            if (v.Count == 0) return 0;
            List<double> s = new List<double>(v); s.Sort();
            int n = s.Count; return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
        }
        static double Mean(List<double> v) { if (v.Count == 0) return 0; double t = 0; foreach (double d in v) t += d; return t / v.Count; }

        // ---------- answers ----------
        // seconds a stop costs at this track (no config = the config with the most stops); null until a stop was measured
        public static double? For(string track) { return For(track, null); }
        public static double? For(string track, string config)
        {
            lock (gate)
            {
                TrackRec best = null;
                if (config != null) { recs.TryGetValue(Key(track, config), out best); }
                else
                {
                    string t = (track ?? "").Trim().ToLowerInvariant();
                    foreach (TrackRec r in recs.Values) if (r.Track.Trim().ToLowerInvariant() == t && (best == null || r.Stops > best.Stops)) best = r;
                }
                if (best == null || best.Stops < 1 || best.Samples.Count == 0) return null;
                return Math.Round(Median(best.Samples), 1);
            }
        }

        public static string Json()
        {
            lock (gate)
            {
                StringBuilder sb = new StringBuilder("{\"tracks\":[");
                bool first = true;
                foreach (TrackRec r in recs.Values)
                {
                    if (r.Stops < 1) continue;
                    if (!first) sb.Append(','); first = false;
                    sb.Append("{\"track\":").Append(Q(r.Track)).Append(",\"config\":").Append(Q(r.Config)).Append(",\"stops\":").Append(r.Stops)
                      .Append(",\"median\":").Append(F(Math.Round(Median(r.Samples), 1))).Append(",\"last\":").Append(F(r.Last))
                      .Append(",\"lastIn\":").Append(F(r.LastIn)).Append(",\"lastOut\":").Append(F(r.LastOut))
                      .Append(",\"driveThroughs\":").Append(r.DriveThroughs).Append(",\"lastWhen\":").Append(Q(r.LastWhen)).Append('}');
                }
                return sb.Append("]}").ToString();
            }
        }

        static string Q(string s)
        {
            StringBuilder b = new StringBuilder("\"");
            foreach (char c in s ?? "") { if (c == '"' || c == '\\') b.Append('\\').Append(c); else if (c < 32) b.Append(' '); else b.Append(c); }
            return b.Append('"').ToString();
        }

        // ---------- measuring ----------
        static double JumpOf(double d) { d = Math.Abs(d); return d > 0.5 ? 1 - d : d; }      // the lap wraps at 1

        static void Reset()
        {
            lastT = double.NaN; curLap = int.MinValue; lapStartT = double.NaN; curInfo = null; laps.Clear();
            wasPit = false; stopSeen = false; stillSince = double.NaN; lastDist = double.NaN; pending = null;
        }

        // One sample per frame (at most 15 a second). pitstopActive = iRacing's PitstopActive;
        // surface = PlayerTrackSurface (0 off track, 1 pit stall, 2 pit lane approach, 3 on track, -1 not in the world).
        public static void Feed(double sessionTime, bool onPitRoad, int lap, double distPct, int flags, bool isOnTrack, int surface,
                                bool pitstopActive, string track, string config, int sessionNum)
        {
            lock (gate)
            {
                if (track == null || track.Length == 0) return;
                bool gone = !isOnTrack && surface < 0;      // in the garage / not in the world: nothing to measure
                if (track != curTrack || (config ?? "") != curConfig || sessionNum != curSession || gone || lap < 0
                    || (!double.IsNaN(lastT) && sessionTime < lastT - 1.0))
                {
                    Reset(); curTrack = track; curConfig = config ?? ""; curSession = sessionNum;
                    if (gone || lap < 0) return;
                }
                // a tow or reset to the pits: the car jumps (to the pit stall without passing the pit lane, or 5 % of the lap in one frame). Not a stop.
                bool jumped = (surface == 1 && (lastSurface == 3 || lastSurface == 0)) || (!double.IsNaN(lastPct) && JumpOf(distPct - lastPct) > 0.05);
                lastPct = distPct; lastSurface = surface;
                if (jumped) { Reset(); curTrack = track; curConfig = config ?? ""; curSession = sessionNum; }
                lastT = sessionTime;

                // the line: Lap went up by one
                if (curLap == int.MinValue) { curLap = lap; lapStartT = double.NaN; curInfo = new LapInfo(); }
                else if (lap == curLap + 1)
                {
                    if (!double.IsNaN(lapStartT) && curInfo != null) { curInfo.Time = sessionTime - lapStartT; laps[curLap] = curInfo; }
                    int done = curLap;
                    curLap = lap; lapStartT = sessionTime; curInfo = new LapInfo(); curInfo.Pit = onPitRoad;
                    if (pending != null && pending.ExitLap == done) Finish(pending);
                }
                else if (lap != curLap) { Reset(); curTrack = track; curConfig = config ?? ""; curSession = sessionNum; curLap = lap; curInfo = new LapInfo(); }
                if (curInfo == null) curInfo = new LapInfo();
                if ((flags & NotGreen) != 0) curInfo.Caution = true;
                if (surface == 0) curInfo.OffSamples++;
                if (onPitRoad) curInfo.Pit = true;

                // pit road: in, standing still, out
                if (onPitRoad && !wasPit)
                {
                    entryLap = lap; stopSeen = false; stillSince = double.NaN; lastDist = double.NaN;
                    pending = null;                                   // a new visit before the last was finished: that one is lost
                }
                if (onPitRoad)
                {
                    if (pitstopActive) stopSeen = true;
                    if (!double.IsNaN(lastDist) && Math.Abs(distPct - lastDist) < 0.00001)
                    {
                        if (double.IsNaN(stillSince)) stillSince = sessionTime;
                        else if (sessionTime - stillSince >= StillSec) stopSeen = true;
                    }
                    else stillSince = double.NaN;
                    lastDist = distPct;
                }
                if (!onPitRoad && wasPit)
                {
                    Pending p = new Pending(); p.EntryLap = entryLap; p.ExitLap = lap; p.Stopped = stopSeen;
                    pending = p;
                }
                wasPit = onPitRoad;
            }
        }

        // the out lap has just been completed: work the stop out
        static void Finish(Pending p)
        {
            pending = null;
            if (!p.Stopped)
            {
                // a drive-through (a penalty or a speed-limit lap): counted on its own, never in the median
                TrackRec d = Get(); d.DriveThroughs++; LastWhy = "driveThrough"; Save();
                Log.W("pitloss: " + curTrack + ": drive-through (" + d.DriveThroughs + " so far), not counted in the median");
                return;
            }
            if (p.ExitLap < p.EntryLap || p.ExitLap - p.EntryLap > 1) { LastWhy = "long visit"; return; }
            LapInfo inL, outL;
            if (!laps.TryGetValue(p.EntryLap, out inL) || !laps.TryGetValue(p.ExitLap, out outL)) { LastWhy = "lap not timed"; return; }
            if (inL.Caution || outL.Caution) { LastWhy = "caution"; return; }
            if (inL.Off || outL.Off) { LastWhy = "off track"; return; }                  // a spin in the in/out lap is not the stop
            List<double> clean = new List<double>();
            foreach (KeyValuePair<int, LapInfo> kv in laps)
                if (kv.Key < p.EntryLap && !kv.Value.Pit && !kv.Value.Caution && !kv.Value.Off && kv.Value.Time >= 15) clean.Add(kv.Value.Time);
            if (clean.Count < 2) { LastWhy = "fewer than 2 clean laps"; return; }
            double reference = Median(clean), loss, inLoss, outLoss;
            if (p.EntryLap == p.ExitLap) { loss = inL.Time - reference; inLoss = outLoss = loss / 2; }    // in and out inside one lap: halves unknown
            else { inLoss = inL.Time - reference; outLoss = outL.Time - reference; loss = inLoss + outLoss; }
            if (loss < 1 || loss > 300) { LastWhy = "implausible " + F(loss); return; }
            TrackRec r = Get();
            r.Stops++; r.Last = Math.Round(loss, 3); r.LastIn = Math.Round(inLoss, 3); r.LastOut = Math.Round(outLoss, 3);
            r.LastWhen = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            r.Samples.Add(r.Last); while (r.Samples.Count > Keep) r.Samples.RemoveAt(0);
            Measured++; LastWhy = "stored";
            Save();
            Log.W("pitloss: " + curTrack + ": " + F(Math.Round(loss, 1)) + " s (" + r.Stops + " stops, median " + F(Math.Round(Median(r.Samples), 1)) + ")");
        }

        static TrackRec Get()
        {
            string k = Key(curTrack, curConfig); TrackRec r;
            if (!recs.TryGetValue(k, out r)) { r = new TrackRec(); r.Track = curTrack; r.Config = curConfig; recs[k] = r; }
            return r;
        }
    }
}
