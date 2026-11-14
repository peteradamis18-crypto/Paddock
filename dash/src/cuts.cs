// CUTS (W1-3, docs/rework/cards/W1-3.md): the trim plan of a race video (out lap off, 20 s after the finish), its chapters
// (first 0:00, at least 3, 10 s apart) and the five title templates. Pure rules, no screen, no rig; Run is the one ffmpeg call.
// W1-4 calls: Cuts.Plan -> Cuts.Title / Cuts.Description -> Cuts.Run (inside Jobs.Run(whenFree); Run itself never touches Jobs).
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace IRDash
{
    class Chapter
    {
        public double Sec;      // seconds from the start of the CUT video
        public string Label;
        public Chapter(double sec, string label) { Sec = sec; Label = label; }
    }

    class CutPlan
    {
        public double StartSec, EndSec;
        public List<Chapter> Chapters = new List<Chapter>();
        public int Laps;            // lap rows in the sidecar
        public string BestLap = ""; // "1:33.832" or ""
        public string Why = "";
    }

    class Facts
    {
        public string Car = "", Track = "", Config = "", Series = "";
        public DateTime Date;        // default(DateTime) = unknown
        public int Finish, Start;    // 0 = unknown
    }

    static class Cuts
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        const double OutLapLead = 3, AfterFinish = 20, MinGap = 10;
        const long NeedFreeBytes = 10L * 1024 * 1024 * 1024;

        // the test sets this to pretend the disk is nearly full
        public static Func<string, long> FreeBytes = DiskFree;
        // W1-4 review: the cut runs through the recorder's tool runner (BelowNormal, very low disk priority, killed when a session starts).
        // args, timeoutMs -> exit code; Yielded = stopped because a session started (the caller queues it again); -1 = timed out. null = run it here.
        public static Func<string, int, int> Ffmpeg;
        public static Func<string, int, string> Ffprobe;     // args, timeoutMs -> what it printed, null = it failed (tests); null hook = run it here
        public const int Yielded = -2;
        static long DiskFree(string dir)
        {
            try { return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(dir))).AvailableFreeSpace; } catch { return long.MaxValue; }
        }

        // ---------- plan ----------
        class Lap { public int N; public double Offset, Time; public bool Clean, Counted, Pit; }

        static double Num(object o)
        {
            if (o == null) return 0;
            try { return Convert.ToDouble(o, Inv); } catch { return 0; }
        }
        static bool Bool(object o) { return o is bool && (bool)o; }
        static object Get(Dictionary<string, object> d, string k) { object v; return d != null && d.TryGetValue(k, out v) ? v : null; }

        public static CutPlan Plan(string sidecarJson, double durationSec)
        {
            CutPlan p = new CutPlan();
            List<Lap> laps = new List<Lap>();
            List<double[]> incidents = new List<double[]>();   // offset, count
            string type = "";
            try
            {
                Dictionary<string, object> root = new JavaScriptSerializer().DeserializeObject(sidecarJson) as Dictionary<string, object>;
                type = Convert.ToString(Get(root, "sessionType"), Inv) ?? "";
                IEnumerable ls = Get(root, "laps") as IEnumerable;
                if (ls != null) foreach (object o in ls)
                    {
                        Dictionary<string, object> d = o as Dictionary<string, object>; if (d == null) continue;
                        Lap l = new Lap(); l.N = (int)Num(Get(d, "n")); l.Offset = Num(Get(d, "offset")); l.Time = Num(Get(d, "time"));
                        l.Clean = Bool(Get(d, "clean")); l.Counted = Bool(Get(d, "counted")); l.Pit = Bool(Get(d, "pit"));
                        if (l.Time > 0) laps.Add(l);
                    }
                IEnumerable ins = Get(root, "incidents") as IEnumerable;
                if (ins != null) foreach (object o in ins)
                    {
                        Dictionary<string, object> d = o as Dictionary<string, object>; if (d == null) continue;
                        double c = Num(Get(d, "count")); if (c < 1) c = 1;
                        incidents.Add(new double[] { Num(Get(d, "offset")), c });
                    }
            }
            catch { laps.Clear(); incidents.Clear(); }
            p.Laps = laps.Count;

            bool race = type.Equals("Race", StringComparison.OrdinalIgnoreCase);
            Lap first = null, last = null;
            foreach (Lap l in laps) { if (l.N == 1 && first == null) first = l; if (last == null || l.Offset + l.Time > last.Offset + last.Time) last = l; }

            p.StartSec = 0; p.EndSec = durationSec;
            string why;
            if (race && first != null)
            {
                p.StartSec = Math.Max(0, first.Offset - OutLapLead);
                why = "out lap off (lap 1 at " + first.Offset.ToString("0.0", Inv) + " s)";
            }
            else why = race ? "no lap rows, whole video" : "not a race, whole video";
            if (race && last != null)
            {
                double e = last.Offset + last.Time + AfterFinish;
                p.EndSec = durationSec > 0 ? Math.Min(e, durationSec) : e;
                why += ", " + AfterFinish.ToString("0", Inv) + " s after the finish";
            }
            if (p.EndSec <= p.StartSec) { p.StartSec = 0; p.EndSec = durationSec; }   // a sidecar that does not add up: do not cut blind
            double len = p.EndSec - p.StartSec;

            // best lap: quickest counted, else quickest clean
            Lap best = null;
            foreach (Lap l in laps) if (l.Counted && (best == null || l.Time < best.Time)) best = l;
            if (best == null) foreach (Lap l in laps) if (l.Clean && (best == null || l.Time < best.Time)) best = l;
            if (best != null) p.BestLap = LapTime(best.Time);

            // candidates in time order; the earlier one wins inside 10 s
            List<Chapter> cand = new List<Chapter>();
            foreach (double[] i in incidents) cand.Add(new Chapter(i[0] - p.StartSec, "Incident +" + ((int)i[1]).ToString(Inv) + "x"));
            foreach (Lap l in laps) if (l.Pit) cand.Add(new Chapter(l.Offset - p.StartSec, "Pit stop"));
            if (best != null) cand.Add(new Chapter(best.Offset - p.StartSec, "Best lap " + LapTime(best.Time) + " (lap " + best.N.ToString(Inv) + ")"));
            if (race && last != null) cand.Add(new Chapter(last.Offset + last.Time - p.StartSec, "Finish"));
            List<Chapter> sorted = new List<Chapter>();
            foreach (Chapter c in cand) if (c.Sec >= 0 && c.Sec <= len) sorted.Add(c);
            // List.Sort is unstable: a tie (a pit lap that is also the best lap) keeps the order they were added in
            List<Chapter> pool = new List<Chapter>(sorted);
            sorted.Sort(delegate (Chapter a, Chapter b) { int c = a.Sec.CompareTo(b.Sec); return c != 0 ? c : pool.IndexOf(a).CompareTo(pool.IndexOf(b)); });

            p.Chapters.Add(new Chapter(0, "Start"));
            foreach (Chapter c in sorted)
                if (c.Sec - p.Chapters[p.Chapters.Count - 1].Sec >= MinGap) p.Chapters.Add(c);

            if (p.Chapters.Count < 3)
            {
                // YouTube shows the chapter bar only with three; Halfway goes where it is 10 s from its neighbours
                // (a video with no lap rows has only Start, so a second marker is needed there)
                double[] tries = new double[] { 0.5, 0.35, 0.65, 0.25, 0.75, 0.15, 0.85 };
                bool halfway = false;
                foreach (double f in tries)
                {
                    if (p.Chapters.Count >= 3) break;
                    double t = len * f; bool ok = true;
                    foreach (Chapter c in p.Chapters) if (Math.Abs(c.Sec - t) < MinGap) ok = false;
                    if (ok) { p.Chapters.Add(new Chapter(t, halfway ? "Later on" : "Halfway")); halfway = true; }
                }
                p.Chapters.Sort(delegate (Chapter a, Chapter b) { return a.Sec.CompareTo(b.Sec); });
            }
            p.Why = why + ", " + p.Chapters.Count.ToString(Inv) + " chapters";
            return p;
        }

        static string LapTime(double s)
        {
            int m = (int)(s / 60); double r = s - m * 60;
            return m.ToString(Inv) + ":" + r.ToString("00.000", Inv);
        }

        static string Clock(double sec)
        {
            int t = (int)Math.Floor(sec + 0.0001); if (t < 0) t = 0;
            int h = t / 3600, m = (t / 60) % 60, s = t % 60;
            if (h > 0) return h.ToString(Inv) + ":" + m.ToString("00", Inv) + ":" + s.ToString("00", Inv);
            return (t / 60).ToString(Inv) + ":" + s.ToString("00", Inv);
        }

        // ---------- titles ----------
        static string Clean(string s)
        {
            if (s == null) return "";
            return s.Replace("{", "").Replace("}", "").Trim();
        }

        static string DateText(Facts f) { return f.Date.Year < 2000 ? "" : f.Date.ToString("d MMM yyyy", Inv); }

        // keep the first n words (n < 1 = nothing)
        static string Words(string s, int n)
        {
            if (n < 1) return "";
            string[] w = s.Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (w.Length <= n) return s;
            return string.Join(" ", w, 0, n);
        }
        static int WordCount(string s) { return s.Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries).Length; }

        // one rendering: everything already trimmed to what is allowed
        static string Render(int t, string car, string track, string series, string date, int finish, int start)
        {
            bool hasSeries = series.Length > 0, hasDate = date.Length > 0, hasP = finish > 0, hasFrom = finish > 0 && start > 0;
            string fin = "P" + finish.ToString(Inv);
            switch (t)
            {
                case 2:
                    {
                        string core = car + " at " + track;
                        if (hasFrom) return fin + " from P" + start.ToString(Inv) + " · " + core;
                        return hasDate ? core + " · " + date : core;
                    }
                case 3:
                    {
                        string s = hasSeries ? series + ": " + track + " in the " + car : track + " in the " + car;
                        return hasP ? s + " · " + fin : s;
                    }
                case 4:
                    return track + " " + car + " full race" + (hasDate ? " · " + date : "");
                case 5:
                    return hasSeries ? "Full race: " + series + " at " + track + " (" + car + ")" : "Full race: " + track + " (" + car + ")";
                default:
                    {
                        string s = car + " at " + track;
                        if (hasSeries) s += " · iRacing " + series;
                        return hasDate ? s + " · " + date : s;
                    }
            }
        }

        public static string Title(int template, Facts f)
        {
            if (template < 1 || template > 5) template = 1;
            string car = Clean(f.Car), track = Clean(f.Track), cfg = Clean(f.Config), series = Clean(f.Series), date = DateText(f);
            if (car.Length == 0) car = "iRacing";
            if (track.Length == 0) track = "the track";
            // "Full Course" says nothing; a real layout name does
            if (cfg.Equals("Full Course", StringComparison.OrdinalIgnoreCase) || cfg.Equals("Full", StringComparison.OrdinalIgnoreCase)) cfg = "";
            const int Max = 69;   // under 70
            string full = cfg.Length > 0 ? track + " " + cfg : track;
            string r = Render(template, car, full, series, date, f.Finish, f.Start);
            if (r.Length <= Max) return r;
            r = Render(template, car, track, series, date, f.Finish, f.Start);                       // 1. drop the config
            if (r.Length <= Max) return r;
            r = Render(template, car, track, series, "", f.Finish, f.Start);                         // 2. drop the date
            if (r.Length <= Max) return r;
            for (int n = WordCount(series) - 1; n >= 0; n--)                                         // 3. cut the series, a word at a time
            {
                r = Render(template, car, track, Words(series, n), "", f.Finish, f.Start);
                if (r.Length <= Max) return r;
            }
            for (int n = WordCount(track) - 1; n >= 1; n--)                                          // 4. then the track
            {
                r = Render(template, car, Words(track, n), "", "", f.Finish, f.Start);
                if (r.Length <= Max) return r;
            }
            for (int n = WordCount(car) - 1; n >= 1; n--)                                            // last resort: the car, never below one word
            {
                r = Render(template, Words(car, n), Words(track, 1), "", "", f.Finish, f.Start);
                if (r.Length <= Max) return r;
            }
            return r;
        }

        public static string Description(CutPlan p, Facts f)
        {
            StringBuilder sb = new StringBuilder();
            string line = Clean(f.Car) + " at " + Clean(f.Track);
            string d = DateText(f); if (d.Length > 0) line += ", " + d;
            if (p.Laps > 0) line += " · " + p.Laps.ToString(Inv) + (p.Laps == 1 ? " lap" : " laps");
            if (p.BestLap.Length > 0) line += " · best " + p.BestLap;
            sb.Append(line).Append("\n\n");
            foreach (Chapter c in p.Chapters) sb.Append(Clock(c.Sec)).Append(' ').Append(c.Label).Append('\n');
            sb.Append("\nRecorded with Paddock");
            return sb.ToString();
        }

        // ---------- ffmpeg ----------
        static string N(double v) { return v.ToString("0.###", Inv); }

        public static string FfmpegArgs(string inPath, string outPath, CutPlan p)
        {
            return "-hide_banner -y -ss " + N(p.StartSec) + " -to " + N(p.EndSec) + " -i \"" + inPath + "\" -c copy -map 0:v:0 -map 0:a:0"
                + " -tag:v hvc1 -movflags +faststart -avoid_negative_ts make_zero \"" + outPath + "\"";
        }

        public static string Run(string ffmpegPath, string ffprobePath, string inPath, string outDir, CutPlan p, out string outPath)
        {
            outPath = Path.Combine(outDir, Path.GetFileNameWithoutExtension(inPath) + "-cut.mp4");
            try
            {
                if (!File.Exists(inPath)) return "The race video is missing.";
                if (Ffmpeg == null && !File.Exists(ffmpegPath)) return "The video tool is missing.";
                Directory.CreateDirectory(outDir);
                if (FreeBytes(outDir) < NeedFreeBytes) return "Not enough space for the cut (needs 10 GB free)";
                try { if (File.Exists(outPath)) File.Delete(outPath); } catch { }

                string err = "";
                Func<string, int, int> run = Ffmpeg;
                int code = run != null ? run(FfmpegArgs(inPath, outPath, p), 30 * 60 * 1000) : Exec(ffmpegPath, FfmpegArgs(inPath, outPath, p), 30 * 60 * 1000, true, out err);
                if (code == Yielded) { TryDelete(outPath); return "YIELD"; }
                if (code == -1) { TryDelete(outPath); return "The cut took too long, so it was not used."; }
                if (code != 0 || !File.Exists(outPath)) { TryDelete(outPath); return "The cut did not work (the video tool stopped)."; }

                string probe;
                string pargs = "-v error -show_entries format=duration -of default=nw=1:nk=1 \"" + outPath + "\"";
                Func<string, int, string> pr = Ffprobe;
                int pc; if (pr != null) { probe = pr(pargs, 60 * 1000); pc = probe == null ? 1 : 0; } else pc = Exec(ffprobePath, pargs, 60 * 1000, false, out probe);
                double got;
                if (pc != 0 || !double.TryParse((probe ?? "").Trim().Split('\n')[0].Trim(), NumberStyles.Float, Inv, out got))
                { TryDelete(outPath); return "The cut could not be checked, so it was not used."; }
                double want = p.EndSec - p.StartSec;
                if (Math.Abs(got - want) > 2)
                { TryDelete(outPath); return "The cut came out the wrong length (" + N(got) + " s, expected " + N(want) + " s), so it was not used."; }
                return "ok";
            }
            catch (Exception ex) { return "The cut did not work (" + ex.Message + ")."; }
        }

        static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }

        // runs a tool hidden; returns the exit code and the text it printed (stderr for ffmpeg, stdout for ffprobe)
        static int Exec(string exe, string args, int timeoutMs, bool belowNormal, out string text)
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe, args);
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            StringBuilder o = new StringBuilder(), e = new StringBuilder();
            using (Process pr = Process.Start(psi))
            {
                if (belowNormal) { try { pr.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { } }
                pr.OutputDataReceived += delegate (object s, DataReceivedEventArgs a) { if (a.Data != null) lock (o) o.AppendLine(a.Data); };
                pr.ErrorDataReceived += delegate (object s, DataReceivedEventArgs a) { if (a.Data != null) lock (e) { e.AppendLine(a.Data); if (e.Length > 4000) e.Remove(0, e.Length - 2000); } };
                pr.BeginOutputReadLine(); pr.BeginErrorReadLine();
                if (!pr.WaitForExit(timeoutMs)) { try { pr.Kill(); } catch { } text = "timeout"; return -1; }
                pr.WaitForExit();   // flush the async readers
                lock (o) text = belowNormal ? e.ToString() : o.ToString();
                return pr.ExitCode;
            }
        }
    }
}
