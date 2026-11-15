// HIGHLIGHTS + PACK (W1-11, docs/rework/cards/W1-11.md): "slice clips" without an editor.
//   Highlights.Plan  the cuts of a race in a fixed order: the start, every pass involving Peter and every incident (in time order),
//                    the best lap, the last lap. Hard cuts, no music, no transitions, at most 3 minutes.
//   Highlights.Run   each cut by stream copy (no re-encode: seconds of disk, no CPU), then ffmpeg's concat demuxer into
//                    <race>.highlights.mp4, checked with ffprobe. Every run goes through the recorder's tool runner (BelowNormal,
//                    killed when a session starts).
//   Pack             per race, after it, in the library's whenFree thumbnail job: the story from the field log (passes, the decisive
//                    lap, fastest lap, iRating), the thumbnail (thumb.cs) and the highlights, saved beside the video in Videos\Paddock
//                    as <race>.thumb.jpg and <race>.highlights.mp4 (+ .highlights.json: its length and its chapters).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace IRDash
{
    sealed class Moment { public double Sec; public string Kind = "", Label = ""; public Moment(double s, string k, string l) { Sec = s; Kind = k; Label = l; } }   // pass | passed | incident
    sealed class HlSeg { public double From, To; public string Kind = "", Label = ""; public double Len { get { return To - From; } } }

    static class Highlights
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public const double MaxSec = 180;
        // each stream-copied cut starts at the keyframe before it (recorder: one a second), so a cut can come out up to 1 s longer:
        // the plan keeps that much spare per cut
        const double StartLen = 25, LastBefore = 25, LastAfter = 5, BestTail = 30, BestWhole = 40, Before = 6, After = 4;
        public static Func<string, int, int> Ffmpeg;          // args, timeoutMs -> exit code (Cuts.Yielded = a session started)
        public static Func<string, int, string> Ffprobe;      // args, timeoutMs -> what it printed (null = failed)

        // startSec: the start of lap 1 (the cut's start, -1 = unknown); bestFrom/bestTo: the best lap (0/0 = none); finish: the line (-1 = unknown)
        public static List<HlSeg> Plan(double startSec, List<Moment> moments, double bestFrom, double bestTo, double finish, double duration)
        {
            List<HlSeg> fixedSegs = new List<HlSeg>();
            HlSeg start = null, best = null, last = null;
            if (duration <= 0) duration = double.MaxValue;
            if (startSec >= 0) start = Seg(startSec, startSec + StartLen, duration, "start", "Start");
            if (finish > 0) last = Seg(finish - LastBefore, finish + LastAfter, duration, "last", "Last lap");
            if (bestTo > bestFrom && bestFrom >= 0)
            {
                best = bestTo - bestFrom <= BestWhole ? Seg(bestFrom, bestTo + 1, duration, "best", "Best lap") : Seg(bestTo - BestTail, bestTo + 1, duration, "best", "Best lap");
                if (best != null && (Overlaps(best, last) || Overlaps(best, start))) best = null;   // the last lap was the best: it is in already
            }
            if (start != null && last != null && Overlaps(start, last)) last = null;               // a race shorter than a minute
            foreach (HlSeg s in new HlSeg[] { start, best, last }) if (s != null) fixedSegs.Add(s);
            double budget = MaxSec;
            foreach (HlSeg s in fixedSegs) budget -= s.Len + 1;

            // moments: his passes first, then the ones against him, then incidents; earlier first inside a kind
            List<Moment> ms = new List<Moment>(moments ?? new List<Moment>());
            ms.Sort(delegate (Moment a, Moment b) { int c = Rank(a.Kind).CompareTo(Rank(b.Kind)); return c != 0 ? c : a.Sec.CompareTo(b.Sec); });
            List<HlSeg> mid = new List<HlSeg>();
            foreach (Moment m in ms)
            {
                HlSeg s = Seg(m.Sec - Before, m.Sec + After, duration, m.Kind, m.Label);
                if (s == null) continue;
                bool clash = false;
                foreach (HlSeg f in fixedSegs) if (Overlaps(s, f)) clash = true;
                if (clash) continue;
                HlSeg join = null;
                foreach (HlSeg x in mid) if (Overlaps(s, x)) { join = x; break; }
                if (join != null)
                {
                    // two moments close together are one cut (a pass and the incident it caused)
                    double from = Math.Min(join.From, s.From), to = Math.Max(join.To, s.To);
                    if ((to - from) - join.Len > budget) continue;
                    budget -= (to - from) - join.Len; join.From = from; join.To = to;
                    continue;
                }
                if (s.Len + 1 > budget) continue;
                budget -= s.Len + 1; mid.Add(s);
            }
            mid.Sort(delegate (HlSeg a, HlSeg b) { return a.From.CompareTo(b.From); });
            List<HlSeg> all = new List<HlSeg>();
            if (start != null) all.Add(start);
            all.AddRange(mid);
            if (best != null) all.Add(best);
            if (last != null) all.Add(last);
            return all;
        }

        static int Rank(string k) { return k == "pass" ? 0 : k == "passed" ? 1 : 2; }
        static bool Overlaps(HlSeg a, HlSeg b) { return a != null && b != null && a.From < b.To && b.From < a.To; }
        static HlSeg Seg(double from, double to, double duration, string kind, string label)
        {
            from = Math.Max(0, from); to = Math.Min(duration, to);
            if (to - from < 2) return null;
            HlSeg s = new HlSeg(); s.From = from; s.To = to; s.Kind = kind; s.Label = label; return s;
        }

        // the chapters of the highlights video itself (each cut's label where it begins in the joined file)
        public static List<Chapter> ChaptersOf(List<HlSeg> segs)
        {
            List<Chapter> c = new List<Chapter>(); double at = 0;
            foreach (HlSeg s in segs)
            {
                if (c.Count == 0 || at - c[c.Count - 1].Sec >= 10) c.Add(new Chapter(at, s.Label));
                at += s.Len;
            }
            return c;
        }

        // "ok" (sec = its real length), "YIELD" or why not
        public static string Run(string ffmpegExe, string ffprobeExe, string video, List<HlSeg> segs, string outPath, out double sec)
        {
            sec = 0;
            string dir = outPath + ".parts", part = outPath.Substring(0, outPath.Length - 4) + ".part.mp4";
            try
            {
                if (segs == null || segs.Count == 0) return "Nothing to cut.";
                if (!File.Exists(video)) return "The race video is missing.";
                if (Ffmpeg == null && !File.Exists(ffmpegExe)) return "The video tool is missing.";
                if (Directory.Exists(dir)) Directory.Delete(dir, true);
                Directory.CreateDirectory(dir);
                StringBuilder list = new StringBuilder();
                for (int i = 0; i < segs.Count; i++)
                {
                    string one = Path.Combine(dir, "c" + i.ToString("00", Inv) + ".mp4");
                    string a = "-v error -y -ss " + N(segs[i].From) + " -i \"" + video + "\" -t " + N(segs[i].Len) +
                               " -map 0:v:0 -map 0:a? -c copy -avoid_negative_ts make_zero \"" + one + "\"";
                    int rc = Tool(ffmpegExe, a, 5 * 60 * 1000);
                    if (rc == Cuts.Yielded) { Clean(dir, part); return "YIELD"; }
                    if (rc != 0 || !File.Exists(one)) { Clean(dir, part); return "A highlight cut did not work (ffmpeg " + rc.ToString(Inv) + ")."; }
                    list.Append("file '").Append(Path.GetFileName(one)).Append("'\n");
                }
                string listFile = Path.Combine(dir, "list.txt");
                File.WriteAllText(listFile, list.ToString(), new UTF8Encoding(false));
                string c = "-v error -y -f concat -safe 0 -i \"" + listFile + "\" -c copy -movflags +faststart \"" + part + "\"";
                int cr = Tool(ffmpegExe, c, 5 * 60 * 1000);
                if (cr == Cuts.Yielded) { Clean(dir, part); return "YIELD"; }
                if (cr != 0 || !File.Exists(part)) { Clean(dir, part); return "The highlights could not be joined (ffmpeg " + cr.ToString(Inv) + ")."; }
                string pargs = "-v error -show_entries format=duration -of default=nw=1:nk=1 \"" + part + "\"";
                string probe = null;
                if (Ffprobe != null) probe = Ffprobe(pargs, 60000);
                else { string o; if (Cuts.Exec(ffprobeExe, pargs, 60000, false, out o) == 0) probe = o; }
                double got;
                if (probe == null || !double.TryParse(probe.Trim().Split('\n')[0].Trim(), NumberStyles.Float, Inv, out got)) { Clean(dir, part); return "The highlights could not be checked."; }
                if (got > MaxSec + 0.5 || got < 1) { Clean(dir, part); return "The highlights came out " + N(got) + " s long, so they were not kept."; }
                Directory.Delete(dir, true);
                if (File.Exists(outPath)) File.Delete(outPath);
                File.Move(part, outPath);
                sec = got;
                return "ok";
            }
            catch (Exception ex) { Clean(dir, part); return "The highlights did not work (" + ex.Message + ")."; }
        }

        static int Tool(string exe, string args, int ms)
        {
            if (Ffmpeg != null) return Ffmpeg(args, ms);
            string e; return Cuts.Exec(exe, args, ms, true, out e);
        }
        static void Clean(string dir, string part)
        {
            try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
            try { if (File.Exists(part)) File.Delete(part); } catch { }
        }
        static string N(double v) { return v.ToString("0.###", Inv); }
    }

    // ---------------------------------------------------------------------------------------------------------------------------
    static class Pack
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public static string FieldDirOverride;              // tests: the field logs' folder (else <vault>\field)
        static string FieldDir { get { return FieldDirOverride ?? Path.Combine(Recorder.LibVaultRoot, "field"); } }

        // beside the video Peter sees (Videos\Paddock, the export's name), else beside the recording
        static string Base(RaceInfo r)
        {
            string v = r.ExportPath != null && r.ExportPath.Length > 0 ? r.ExportPath : r.File;
            return Path.Combine(Path.GetDirectoryName(v), Path.GetFileNameWithoutExtension(v));
        }
        public static string ThumbPath(RaceInfo r) { return Base(r) + ".thumb.jpg"; }
        public static string HlPath(RaceInfo r) { return Base(r) + ".highlights.mp4"; }
        static string HlInfo(RaceInfo r) { return Base(r) + ".highlights.json"; }
        public static bool Done(RaceInfo r) { return File.Exists(ThumbPath(r)) && File.Exists(HlPath(r)) && File.Exists(HlInfo(r)); }

        // the highlights' length in seconds (0 = none) and its chapters, from the note written when it was made
        public static double HlSec(RaceInfo r)
        {
            try { if (!File.Exists(HlPath(r)) || !File.Exists(HlInfo(r))) return 0; } catch { return 0; }
            Dictionary<string, object> d = Info(r);
            object v; return d != null && d.TryGetValue("sec", out v) ? Convert.ToDouble(v, Inv) : 0;
        }
        public static List<Chapter> HlChapters(RaceInfo r)
        {
            List<Chapter> c = new List<Chapter>();
            Dictionary<string, object> d = Info(r); object v;
            if (d != null && d.TryGetValue("chapters", out v) && v is object[])
                foreach (object o in (object[])v)
                {
                    Dictionary<string, object> x = o as Dictionary<string, object>; if (x == null) continue;
                    c.Add(new Chapter(Convert.ToDouble(x["sec"], Inv), Convert.ToString(x["label"], Inv)));
                }
            return c;
        }
        static Dictionary<string, object> Info(RaceInfo r)
        {
            try { return File.Exists(HlInfo(r)) ? new JavaScriptSerializer().DeserializeObject(File.ReadAllText(HlInfo(r), Encoding.UTF8)) as Dictionary<string, object> : null; } catch { return null; }
        }
        public static long Bytes(RaceInfo r) { long b = 0; foreach (string p in new string[] { ThumbPath(r), HlPath(r) }) { try { if (File.Exists(p)) b += new FileInfo(p).Length; } catch { } } return b; }

        // DELETE: the pack goes with the race (made again by itself after an UNDO)
        public static void Forget(RaceInfo r)
        {
            foreach (string p in new string[] { ThumbPath(r), HlPath(r), HlInfo(r) }) { try { if (File.Exists(p)) File.Delete(p); } catch { } }
        }

        // ---------- the story: the sidecar's facts, then the field log's passes, the decisive lap, fastest lap and iRating ----------
        // f has the sidecar's facts already (Library.FactsOf); moments get the passes involving him and his incidents, in video seconds
        public static double Story(RaceInfo r, RecSess s, CutPlan p, Facts f, List<Moment> moments)
        {
            f.Laps = r.Laps; f.BestLap = p != null ? p.BestLap : ""; f.BestLapN = r.BestLap; if (f.Field == 0) f.Field = r.Field;
            foreach (RaceMarker m in r.Markers) if (m.Kind == "incident") moments.Add(new Moment(m.Sec, "incident", m.Label));
            RfData d = FieldLog(r);
            if (d == null) return -1;
            try { return FromField(d, s, f, moments); }
            catch (Exception ex) { Log.W("pack: the field log of " + r.Id + " could not be read (" + ex.Message + ")"); return -1; }
        }

        // the race's field log: a race log that overlaps the recording most (file names carry their start, so only near ones are read)
        internal static RfData FieldLog(RaceInfo r)
        {
            try
            {
                if (!Directory.Exists(FieldDir) || r.StartMs <= 0) return null;
                DateTime at = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(r.StartMs).ToLocalTime();
                double from = r.StartMs, to = r.StartMs + Math.Max(60, r.Sec) * 1000;
                RfData best = null; double bestOv = 0;
                foreach (string file in Directory.GetFiles(FieldDir, "f*.json"))
                {
                    Match mm = Regex.Match(Path.GetFileName(file), @"^f(\d{8}-\d{6})-\d{1,2}\.json$");
                    DateTime t;
                    if (!mm.Success || !DateTime.TryParseExact(mm.Groups[1].Value, "yyyyMMdd-HHmmss", Inv, DateTimeStyles.AssumeLocal, out t)) continue;
                    if (Math.Abs((t - at).TotalHours) > 4) continue;
                    RfData d = RfData.FromJson(File.ReadAllText(file, Encoding.UTF8));
                    if (d == null || !d.IsRace || d.Me < 0 || d.Car(d.Me) == null) continue;
                    double ov = Math.Min(d.EndMs, to) - Math.Max(d.StartMs, from);
                    if (ov > bestOv) { best = d; bestOv = ov; }
                }
                return best;
            }
            catch (Exception ex) { Log.W("pack: field logs: " + ex.Message); return null; }
        }

        static double FromField(RfData d, RecSess s, Facts f, List<Moment> moments)
        {
            RfCar me = d.Car(d.Me);
            // the REVIEW engine's numbers (debrief.cs RaceStory): the same start, finish, field, iRating change and incidents REVIEW shows
            string story = Debrief.RaceStory(d.ToJson(false, RfSummary.Build(d), true));
            Dictionary<string, object> st = story == null ? null : new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(story) as Dictionary<string, object>;
            Dictionary<string, object> res = st != null && st.ContainsKey("result") ? st["result"] as Dictionary<string, object> : null;
            if (res != null)
            {
                if (f.Finish <= 0) f.Finish = Int(res, "finishPosition");
                if (f.Start <= 0) f.Start = Int(res, "startPosition");
                object ir; if (res.TryGetValue("iratingChange", out ir) && ir != null) f.IrChange = Convert.ToInt32(ir, Inv);
                object inc; if (res.TryGetValue("incidents", out inc) && inc != null && Convert.ToInt32(inc, Inv) >= 0) f.Incidents = Convert.ToInt32(inc, Inv);
            }
            if (st != null)
            {
                int field = Int(st, "field"); if (field > 0) f.Field = field;
                int myIr = Int(st, "myIR"); if (myIr > 0) f.IrBefore = myIr;
            }

            // fastest lap: his best against every car of his class (the results' best, else the sim's own lap times)
            double mine = Best(me), cls = double.MaxValue;
            foreach (RfCar c in d.Cars) if (c.Cls == me.Cls) { double b = Best(c); if (b > 0 && b < cls) cls = b; }
            f.FastestLap = mine > 0 && mine <= cls + 0.0005;

            // the video second of a session time: his lap that holds it, the recorder's offset of that lap, plus the time into it
            Dictionary<int, double> off = new Dictionary<int, double>();
            if (s != null) foreach (double[] row in s.LapRows) if (row.Length > 1 && !double.IsNaN(row[1]) && !off.ContainsKey((int)row[0])) off[(int)row[0]] = row[1];
            int maxLap = 0; foreach (RfLap l in me.Laps) if (!double.IsNaN(l.E) && l.N > maxLap) maxLap = l.N;

            RfPass decisive = null;
            foreach (RfPass ps in d.Passes)
            {
                bool by = ps.By == d.Me, over = ps.Over == d.Me;
                if (!by && !over) continue;
                if (by) decisive = ps;                       // the last pass he made ...
                else if (decisive != null) decisive = null;  // ... that nobody took back
                if (by && ps.Lap == maxLap && maxLap > 0) f.LastLapPass = true;
                double v = VideoSec(me, off, ps.T);
                if (v >= 0) moments.Add(new Moment(v, by ? "pass" : "passed", by ? "Pass (lap " + ps.Lap.ToString(Inv) + ")" : "Passed (lap " + ps.Lap.ToString(Inv) + ")"));
            }
            if (decisive != null)
            {
                int pos = 0; foreach (RfLap l in me.Laps) if (l.N == decisive.Lap) pos = l.Pos;
                if (pos > 0) { f.PassLap = decisive.Lap; f.PassFor = pos; f.PassWhere = decisive.Where ?? ""; return VideoSec(me, off, decisive.T); }
            }
            return -1;
        }

        static double VideoSec(RfCar me, Dictionary<int, double> off, double t)
        {
            RfLap hold = null;
            foreach (RfLap l in me.Laps) if (!double.IsNaN(l.S) && l.S <= t && (double.IsNaN(l.E) || t < l.E)) hold = l;
            double o;
            if (hold == null || !off.TryGetValue(hold.N, out o)) return -1;
            return o + (t - hold.S);
        }
        static double Best(RfCar c) { return c.ResBest > 0 ? c.ResBest : c.BestSim; }
        static int Int(Dictionary<string, object> d, string k) { object v; try { return d.TryGetValue(k, out v) && v != null ? Convert.ToInt32(v, Inv) : 0; } catch { return 0; } }

        // ---------- making it: the thumbnail, then the highlights. "ok", "YIELD" or why not ----------
        public static string Make(RaceInfo r, RecSess s, CutPlan p, Facts f, string ffmpegExe, string ffprobeExe)
        {
            if (r == null || !r.IsRace) return "Not a race.";
            List<Moment> moments = new List<Moment>();

            double decisive = Story(r, s, p, f, moments);
            double start = -1, finish = -1, best = -1;
            foreach (RaceMarker m in r.Markers)
            {
                if (m.Kind == "start" && start < 0) start = m.Sec;
                if (m.Kind == "finish") finish = m.Sec;
                if (m.Kind == "best") best = m.Sec;
            }
            // the race's best moment: the decisive pass, else the finish line, else the start once the field is rolling
            double at = decisive >= 0 ? decisive + 0.5 : finish > 0 ? Math.Max(0, finish - 1) : start >= 0 ? start + 8 : Math.Min(60, r.Sec / 2);
            string tp = ThumbPath(r);
            if (!File.Exists(tp))
            {
                string t = Thumb.Make(ffmpegExe, r.File, at, f, tp);
                if (t != "ok") return t;
                Log.W("pack: " + r.Id + " thumbnail made (" + Thumb.BigText(f) + ", the frame at " + at.ToString("0.0", Inv) + " s)");
            }
            string hp = HlPath(r);
            if (!File.Exists(hp))
            {
                double bestFrom = best >= 0 && r.Best > 0 ? best : 0, bestTo = best >= 0 && r.Best > 0 ? best + r.Best : 0;
                List<HlSeg> segs = Highlights.Plan(start >= 0 && r.Laps > 0 ? Math.Max(0, start - 3) : -1, moments, bestFrom, bestTo, finish, r.Sec);
                double sec;
                string h = Highlights.Run(ffmpegExe, ffprobeExe, r.File, segs, hp, out sec);
                if (h != "ok") return h;
                StringBuilder j = new StringBuilder("{\"sec\":" + sec.ToString("0.0", Inv) + ",\"chapters\":[");
                List<Chapter> ch = Highlights.ChaptersOf(segs);
                for (int i = 0; i < ch.Count; i++) { if (i > 0) j.Append(','); j.Append("{\"sec\":" + ch[i].Sec.ToString("0.0", Inv) + ",\"label\":" + Json_.S(ch[i].Label) + "}"); }
                File.WriteAllText(HlInfo(r), j.Append("]}").ToString(), new UTF8Encoding(false));
                Log.W("pack: " + r.Id + " highlights made (" + segs.Count + " cuts, " + Cuts.Clock(sec) + ")");
            }
            return "ok";
        }
    }
}
