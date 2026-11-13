// lapstore.cs - lap truth (W0-6): ONE lap record, ONE "counted" rule, ONE best lap, for every page.
//   LapRules.Judge   the rule (pure, tested on its own by tests\laprules-test.ps1)
//   LapStore.ForFile the laps of one .ibt, worked out once and cached in dash\data\laps\<file>.json
//   LapStore.Best    the quickest COUNTED lap: the only "best lap" any page may show
//   LiveJudge        the same rule for laps as they happen (the recorder and the PB reference each keep one)
// Why: the 12 Nov Road Atlanta race showed three different bests (1:33.639 from a lap iRacing did not count,
// 1:33.919 because the old window missed iRacing's own times, and the real 1:33.832). See docs\rework\evidence\09 section 1a.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace IRDash
{
    // One lap. n = iRacing's lap number (lap 0, the formation or out lap, is never a lap). time = iRacing's own time when it gave one.
    // counted = iRacing counted it (only a counted lap can be a best). why = "" when counted, else lap0 / pit / no-time / short / incident / not-best.
    // off = the car had a wheel off the track at some record (information only: iRacing decides). start = SessionTime at the line.
    sealed class LapRec
    {
        public int N, OffRecords; public double Time, Start; public bool Counted, Pit, Off, Incident; public string Why = "";
        public long StartRecord, EndRecord;
    }

    static class LapRules
    {
        // ONE rules version for everything worked out under this rule (the lap cache, the career cache, the Vault rows, the PB reference files).
        // A cache with a lower number is worked out again. 4 (W0-6): lap 0 out, incident laps out, 4 s window, one off-track record no longer fatal.
        public const int Version = 4;
        // iRacing announces a lap's time 1.2-2.0 s after the line in a file (12 Nov race: 71 to 122 records); 4 s leaves room for a slow frame.
        public const double WindowSec = 4.0;
        public const double MinLap = 15, MaxLap = 900;      // shorter is a reset or a blip, longer is a car parked on track
        // The first change of LapLastLapTime after the line is iRacing's time for that lap. Ours (line to line) can differ: lap 1 of a race is timed
        // by iRacing from the start (12 Nov: 101.580 against our 98.809). More than 5 % apart = something else happened (a reset): not its time.
        public const double TimeTolPart = 0.05;
        public const double Slack = 0.0015;                 // the figures are 32-bit floats

        // timed: iRacing gave the lap a time (LapLastLapTime changed to it within the window). bestBefore: iRacing's best lap of the session just
        // before the line (<= 0 none). bestAfter: its best lap within the window after the line (-1 none). haveBest: the file has that channel.
        public static bool Judge(int lapNo, double time, bool timed, bool pit, bool incident, bool haveBest, double bestBefore, double bestAfter, out string why)
        {
            if (lapNo <= 0) { why = "lap0"; return false; }                       // the formation or out lap: never a lap
            if (pit) { why = "pit"; return false; }
            if (!timed) { why = "no-time"; return false; }
            if (time < MinLap || time > MaxLap) { why = "short"; return false; }
            if (incident) { why = "incident"; return false; }                    // iRacing leaves an incident lap out of its best
            if (haveBest && (bestBefore <= 0 || time < bestBefore - Slack))
            {
                // quicker than iRacing's best so far: its own best must become this lap, or it did not count it
                if (!(bestAfter > 0 && Math.Abs(bestAfter - time) <= Slack)) { why = "not-best"; return false; }
            }
            why = "";
            return true;
        }

        public static string Words(string why)
        {
            switch (why)
            {
                case "": return "counted";
                case "lap0": return "formation or out lap";
                case "pit": return "went through the pits";
                case "no-time": return "iRacing gave it no time";
                case "short": return "not a full lap";
                case "incident": return "incident in the lap";
                case "not-best": return "iRacing did not count it";
            }
            return why;
        }
    }

    // The same rule, live: a lap ends at the line, then iRacing announces its time (LapLastLapTime) and, if it is a new best,
    // LapBestLapTime follows. Compare with the LAST LAP SEEN, not the previous frame, so a same-frame update is never missed.
    sealed class LiveJudge
    {
        double lastSeen = double.NaN;      // the last lap time iRacing announced that this watcher saw
        bool pending; double lineAt, computed, bestBefore, seenBest = -1; int lapNo; bool pit, incident; int offRecords; double announced;

        public bool Pending { get { return pending; } }

        // every frame (also between laps): remembers what iRacing shows as its last lap
        public void Seen(double llt) { if (!pending && double.IsNaN(lastSeen)) lastSeen = llt; }

        // the car crossed the line: lap lapNo ended. nowSec: any clock in seconds. best: LapBestLapTime just before the line.
        public void Line(int lap, double nowSec, double lineToLine, double best, bool wasPit, bool hadIncident, int offs, double llt)
        {
            if (double.IsNaN(lastSeen)) lastSeen = llt;
            pending = true; lineAt = nowSec; lapNo = lap; computed = lineToLine; bestBefore = best; pit = wasPit; incident = hadIncident; offRecords = offs;
            announced = double.NaN; seenBest = -1;
        }

        // each frame while pending: null until the lap is decided (iRacing's time and best seen, or the window is over)
        public LapRec Poll(double nowSec, double llt, double best)
        {
            if (!pending) return null;
            bool over = nowSec - lineAt >= LapRules.WindowSec;
            if (double.IsNaN(announced) && llt > 1 && Math.Abs(llt - lastSeen) > 0.0005) announced = llt;
            if (!double.IsNaN(announced) && best > 1 && (seenBest < 0 || best < seenBest)) seenBest = best;
            if (double.IsNaN(announced) && !over) return null;
            bool needBest = !double.IsNaN(announced) && (bestBefore <= 0 || announced < bestBefore - LapRules.Slack);
            if (needBest && !(seenBest > 0 && Math.Abs(seenBest - announced) <= LapRules.Slack) && !over) return null;    // the best follows the time, give it the window
            // an identical time to the last lap: it never "changes"; take it when it matches our line-to-line time
            if (double.IsNaN(announced) && over && llt > 1 && Math.Abs(llt - computed) < 0.01) announced = llt;
            pending = false;
            LapRec r = new LapRec(); r.N = lapNo; r.Pit = pit; r.Incident = incident; r.OffRecords = offRecords; r.Off = offRecords > 0;
            bool timed = !double.IsNaN(announced);
            r.Time = timed ? announced : computed;
            if (timed) lastSeen = announced;
            string why;
            r.Counted = LapRules.Judge(lapNo, r.Time, timed, pit, incident, true, bestBefore, seenBest, out why);
            r.Why = why;
            return r;
        }

        public void Reset() { pending = false; lastSeen = double.NaN; }
    }

    // The laps of one .ibt file.
    sealed class FileLaps
    {
        public string File = "", Car = "", Track = "", Config = "", TrackId = ""; public long Size; public int Rules; public DateTime StartUtc = DateTime.MinValue;
        public List<LapRec> Laps = new List<LapRec>();
        public LapRec BestLap { get { return LapStore.Best(Laps); } }
        public int CountedLaps { get { int n = 0; foreach (LapRec l in Laps) if (l.Counted) n++; return n; } }
    }

    static class LapStore
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly object gate = new object();
        static readonly Dictionary<string, FileLaps> mem = new Dictionary<string, FileLaps>();
        // irdash.exe lives in dash\, so this is dash\data\laps (tests set it to a folder of their own)
        public static string Dir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"data\laps");

        // THE best lap: the quickest counted lap. null = no counted lap ("no clean lap").
        public static LapRec Best(List<LapRec> laps)
        {
            LapRec b = null;
            if (laps == null) return null;
            foreach (LapRec l in laps) if (l.Counted && l.Time > 0 && (b == null || l.Time < b.Time - 1e-9)) b = l;
            return b;
        }

        // seconds, or -1 when nothing counted
        public static double BestTime(List<LapRec> laps) { LapRec b = Best(laps); return b == null ? -1 : b.Time; }

        // The laps of a telemetry file: from memory, else the cache file, else read from the .ibt (and cached). Never throws: null = unreadable.
        // A file the sim is still writing is read but not cached on disk.
        public static FileLaps ForFile(string path)
        {
            try
            {
                FileInfo fi = new FileInfo(path);
                if (!fi.Exists) return null;
                string sig = fi.Name.ToLowerInvariant() + "|" + fi.Length;
                FileLaps f;
                lock (gate) if (mem.TryGetValue(sig, out f)) return f;
                f = LoadCache(fi);
                bool finished = true;
                if (f == null)
                {
                    using (IbtFile t = IbtFile.Open(path, true))
                    {
                        if (t == null) return null;
                        f = Read(t);
                        finished = t.IsFinished;
                    }
                    if (finished) SaveCache(f);
                }
                if (finished) lock (gate) { mem[sig] = f; if (mem.Count > 400) mem.Clear(); }
                return f;
            }
            catch (Exception ex) { try { Log.W("lap store " + Path.GetFileName(path) + ": " + ex.Message); } catch { } return null; }
        }

        static string CachePath(string name) { return Path.Combine(Dir, Path.GetFileNameWithoutExtension(name) + ".json"); }

        // Cuts a file into laps and judges each one. A lap is full when both ends are clean crossings of the line (lap counter +1, distance wraps).
        public static FileLaps Read(IbtFile t)
        {
            FileLaps f = new FileLaps();
            f.File = Path.GetFileName(t.Path); f.Size = t.Fs.Length; f.Rules = LapRules.Version; f.StartUtc = t.StartUtc;
            f.Track = t.YamlValue("TrackDisplayName"); f.Config = t.YamlValue("TrackConfigName"); f.TrackId = t.YamlValue("TrackID");
            f.Car = CarOf(t.Yaml);
            VarDef vSt = t.Var("SessionTime"), vLap = t.Var("Lap"), vPct = t.Var("LapDistPct"), vOn = t.Var("IsOnTrack"), vPit = t.Var("OnPitRoad"),
                   vSurf = t.Var("PlayerTrackSurface"), vLlt = t.Var("LapLastLapTime"), vBest = t.Var("LapBestLapTime"), vInc = t.Var("PlayerCarMyIncidentCount");
            if (vSt == null || vLap == null || vPct == null || vOn == null) return f;
            int n = (int)Math.Min(t.Records, 4000000L);
            double[] st = new double[n]; int[] lap = new int[n]; float[] pct = new float[n], llt = new float[n], best = vBest != null ? new float[n] : null;
            short[] inc = new short[n]; byte[] fl = new byte[n];          // fl: 1 on track, 2 pit road, 4 off track
            int per = Math.Max(1, (4 << 20) / t.BufLen); byte[] buf = new byte[per * t.BufLen];
            int i = 0;
            while (i < n)
            {
                int want = Math.Min(per, n - i), recs = t.ReadRecords(i, want, buf);
                if (recs <= 0) break;
                for (int k = 0; k < recs; k++, i++)
                {
                    int o = k * t.BufLen;
                    st[i] = IbtFile.At(buf, o, vSt); lap[i] = (int)IbtFile.At(buf, o, vLap); pct[i] = (float)IbtFile.At(buf, o, vPct);
                    llt[i] = (float)IbtFile.At(buf, o, vLlt); if (best != null) best[i] = (float)IbtFile.At(buf, o, vBest);
                    inc[i] = (short)Math.Min(32000, IbtFile.At(buf, o, vInc));
                    int surf = vSurf == null ? 3 : (int)IbtFile.At(buf, o, vSurf);
                    fl[i] = (byte)((IbtFile.At(buf, o, vOn) != 0 ? 1 : 0) | (vPit != null && IbtFile.At(buf, o, vPit) != 0 ? 2 : 0) | (surf == 0 ? 4 : 0));
                }
                if (recs < want) break;
            }
            n = i;
            int win = (int)(LapRules.WindowSec * t.Tick);
            // runs: one lap counter value, on track, no gap in time
            List<int[]> runs = new List<int[]>();
            for (int k = 0; k < n; )
            {
                if ((fl[k] & 1) == 0) { k++; continue; }
                int j = k + 1;
                while (j < n && (fl[j] & 1) != 0 && lap[j] == lap[k] && st[j] - st[j - 1] < 0.5) j++;
                runs.Add(new int[] { k, j }); k = j;
            }
            for (int r = 0; r < runs.Count; r++)
            {
                int a = runs[r][0], b = runs[r][1];
                bool pre = a > 0 && r > 0 && runs[r - 1][1] == a && lap[a - 1] == lap[a] - 1 && pct[a - 1] > 0.8 && pct[a] < 0.2;
                bool post = b < n && r + 1 < runs.Count && runs[r + 1][0] == b && lap[b] == lap[a] + 1 && pct[b - 1] > 0.8 && pct[b] < 0.2;
                if (!pre || !post) continue;                       // not a full lap (got in part-way, a tow, the file ended)
                if (lap[a] <= 0) continue;                         // lap 0: the formation or out lap is never a lap
                LapRec l = new LapRec(); l.N = lap[a]; l.StartRecord = a; l.EndRecord = b;
                double t0 = Cross(st, pct, a), t1 = Cross(st, pct, b), computed = t1 - t0;
                l.Start = t0;
                for (int x = a; x < b; x++) { if ((fl[x] & 2) != 0) l.Pit = true; if ((fl[x] & 4) != 0) l.OffRecords++; }
                l.Off = l.OffRecords > 0;
                l.Incident = inc[b - 1] > inc[a];
                // iRacing's time: the first change of LapLastLapTime after the line (against the last lap it announced), within the window
                int end = Math.Min(n, b + win);
                double before = llt[b - 1], announced = -1; int at = -1;
                for (int x = b; x < end; x++) if (llt[x] > 1 && Math.Abs(llt[x] - before) > 0.0005) { announced = llt[x]; at = x; break; }
                if (announced < 0 && before > 1 && Math.Abs(before - computed) < 0.01) { announced = before; at = b; }   // the same time as the lap before: it never changes
                bool timed = announced > 0 && Math.Abs(announced - computed) < computed * LapRules.TimeTolPart;
                l.Time = timed ? announced : computed;
                double bb = -1, ba = -1;
                if (best != null)
                {
                    bb = best[b - 1];
                    for (int x = Math.Max(b, at); x < end; x++) if (best[x] > 1 && (ba < 0 || best[x] < ba)) ba = best[x];
                }
                string why;
                l.Counted = LapRules.Judge(l.N, l.Time, timed, l.Pit, l.Incident, best != null, bb, ba, out why);
                l.Why = why;
                f.Laps.Add(l);
            }
            return f;
        }

        // where (in session seconds) the car crossed the line between record k-1 and k
        static double Cross(double[] st, float[] pct, int k)
        {
            double p0 = pct[k - 1], p1 = pct[k], span = (1 - p0) + p1;
            double fr = span > 1e-6 ? (1 - p0) / span : 1;
            return st[k - 1] + (st[k] - st[k - 1]) * Math.Max(0, Math.Min(1, fr));
        }

        public static string CarOf(string yaml)
        {
            Match me = Regex.Match(yaml ?? "", "^[ \\t]*DriverCarIdx:[ \\t]*(\\d+)", RegexOptions.Multiline);
            if (!me.Success) return "";
            Match block = Regex.Match(yaml, "- CarIdx: " + me.Groups[1].Value + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
            if (!block.Success) return "";
            Match c = Regex.Match(block.Groups[1].Value, "^[ \\t]*CarScreenName:[ \\t]*(.*?)[ \\t\\r]*$", RegexOptions.Multiline);
            return c.Success ? c.Groups[1].Value.Trim('"') : "";
        }

        // ---- the cache: dash\data\laps\<file>.json, one per telemetry file ----
        public static string Json(FileLaps f)
        {
            StringBuilder sb = new StringBuilder(2000);
            LapRec b = f.BestLap;
            sb.Append("{\"rules\":").Append(f.Rules).Append(",\"file\":").Append(Json_.S(f.File)).Append(",\"size\":").Append(f.Size.ToString(Inv))
              .Append(",\"startMs\":").Append(f.StartUtc == DateTime.MinValue ? "null" : ((long)(f.StartUtc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds).ToString(Inv))
              .Append(",\"car\":").Append(Json_.S(f.Car)).Append(",\"track\":").Append(Json_.S(f.Track)).Append(",\"config\":").Append(Json_.S(f.Config)).Append(",\"trackId\":").Append(Json_.S(f.TrackId))
              .Append(",\"lapCount\":").Append(f.Laps.Count).Append(",\"counted\":").Append(f.CountedLaps)
              .Append(",\"best\":").Append(b == null ? "null" : "{\"n\":" + b.N + ",\"time\":" + b.Time.ToString("0.000", Inv) + "}")
              .Append(",\"laps\":[");
            for (int i = 0; i < f.Laps.Count; i++)
            {
                if (i > 0) sb.Append(',');
                AppendLap(sb, f.Laps[i]);
            }
            sb.Append("]}");
            return sb.ToString();
        }

        public static void AppendLap(StringBuilder sb, LapRec l)
        {
            sb.Append("{\"n\":").Append(l.N).Append(",\"time\":").Append(l.Time.ToString("0.000", Inv)).Append(",\"counted\":").Append(l.Counted ? "true" : "false")
              .Append(",\"why\":").Append(Json_.S(l.Why)).Append(",\"pit\":").Append(l.Pit ? "true" : "false").Append(",\"off\":").Append(l.Off ? "true" : "false")
              .Append(",\"offRecords\":").Append(l.OffRecords).Append(",\"incident\":").Append(l.Incident ? "true" : "false")
              .Append(",\"start\":").Append(l.Start.ToString("0.000", Inv)).Append(",\"startRecord\":").Append(l.StartRecord.ToString(Inv)).Append(",\"endRecord\":").Append(l.EndRecord.ToString(Inv)).Append('}');
        }

        static void SaveCache(FileLaps f)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                string p = CachePath(f.File);
                File.WriteAllText(p + ".tmp", Json(f), new UTF8Encoding(false));
                if (File.Exists(p)) File.Delete(p);
                File.Move(p + ".tmp", p);
            }
            catch { }       // a cache that cannot be written is read again next time: nothing is lost
        }

        // null = no cache, an older rules version, or a different file of the same name (size)
        static FileLaps LoadCache(FileInfo fi)
        {
            string p = CachePath(fi.Name);
            if (!File.Exists(p)) return null;
            try
            {
                Dictionary<string, object> d = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(p, Encoding.UTF8)) as Dictionary<string, object>;
                if (d == null || Num(d, "rules") != LapRules.Version || (long)Num(d, "size") != fi.Length) return null;
                FileLaps f = new FileLaps();
                f.File = fi.Name; f.Size = fi.Length; f.Rules = LapRules.Version;
                f.Car = Str(d, "car"); f.Track = Str(d, "track"); f.Config = Str(d, "config"); f.TrackId = Str(d, "trackId");
                if (d.ContainsKey("startMs") && d["startMs"] != null) f.StartUtc = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(Num(d, "startMs"));
                object[] laps = d.ContainsKey("laps") ? d["laps"] as object[] : null;
                if (laps != null)
                    foreach (object o in laps)
                    {
                        Dictionary<string, object> x = o as Dictionary<string, object>; if (x == null) continue;
                        LapRec l = new LapRec();
                        l.N = (int)Num(x, "n"); l.Time = Num(x, "time"); l.Counted = Bool(x, "counted"); l.Why = Str(x, "why"); l.Pit = Bool(x, "pit"); l.Off = Bool(x, "off");
                        l.OffRecords = (int)Num(x, "offRecords"); l.Incident = Bool(x, "incident"); l.Start = Num(x, "start");
                        l.StartRecord = (long)Num(x, "startRecord"); l.EndRecord = (long)Num(x, "endRecord");
                        f.Laps.Add(l);
                    }
                return f;
            }
            catch { return null; }
        }

        static double Num(Dictionary<string, object> d, string k)
        {
            object o; if (!d.TryGetValue(k, out o) || o == null) return 0;
            try { return Convert.ToDouble(o, Inv); } catch { return 0; }
        }
        static string Str(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? o.ToString() : ""; }
        static bool Bool(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o is bool && (bool)o; }

        // A lap of a file by its number (null = not a full lap there)
        public static LapRec Lap(FileLaps f, int n) { if (f != null) foreach (LapRec l in f.Laps) if (l.N == n) return l; return null; }
    }
}
