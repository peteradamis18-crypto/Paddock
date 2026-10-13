// Session Review data (card C-40, docs\DESIGN-analysis.md section 3A): everything the timing screen needs about ONE
// telemetry file, in one JSON reply. It sits on top of the lap store in analysis.cs: the same laps, the same lap times
// pinned to iRacing's own figure, the same corner model and the same C-30 thresholds for the data notes. Offline: reads
// .ibt files only, never the sim.
//   GET /analysis/session?id=<vault id | telemetry file name | last>
//   "last" = the newest .ibt in iRacing's telemetry folder (the session that just ended).
// Rules (docs\TASKS.md C-40):
//   - a lap time is iRacing's own figure to 0.001 (LapLastLapTime); sectors are cut at the session's own split points
//     (SplitTimeInfo.Sectors in the file's session info - Road Atlanta has four), so S1..Sn add up to the lap time;
//   - a "valid" lap is a full lap that did not touch the pits and that iRacing timed AND counted (L-1, LapRules.Judge in analysis.cs): a lap without iRacing's
//     time never counts; for a timed lap iRacing's own best lap is the evidence (a lap that became its best counted, a quicker lap that did not change it did not),
//     and the off-track record decides only where that says nothing. A lap that does not count is flagged OFF when the car was seen off track, INVALID when nothing
//     was seen. Each lap carries "timed", "offTrack", "offSamples", "bestBefore" / "bestAfter" (iRacing's best at the end of the lap and 2 s after the line) and
//     "countedBy" (the evidence that decided, in words);
//   - optimal = the best iRacing sectors of this session joined; the 24 mini-sectors only colour the strip;
//   - the reference for the map and the notes is the best valid lap of OTHER sessions (his previous best), else the
//     second best valid lap of this session, never the lap itself;
//   - a data note exists only where C-30 says one corner has one clear cause (CompareMet), at most three.
// 503 while Peter drives. BelowNormal. Never writes anything.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static partial class Analysis
    {
        public static string SessionRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
            string id = Q(q, "id");
            string dir = TrackMaps.TelemetryDir;
            string file = id == "last" ? NewestTelemetry(dir) : ResolveFile(id);
            if (file == null) { code = 404; return Err("no such lap file"); }
            try { if (Career.OnlineOnly(new FileInfo(file))) { code = 409; return Err("Online-only in OneDrive: run tools\\keep-iracing-local.cmd"); } }
            catch { code = 404; return Err("no such lap file"); }
            ThreadPriority was = Thread.CurrentThread.Priority;
            try
            {
                Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
                if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) dir = Path.GetDirectoryName(file);
                int focus; int.TryParse(Q(q, "lap"), NumberStyles.Integer, Inv, out focus);      // optional: describe this lap instead of the best one
                return BuildSession(file, dir, true, focus, Q(q, "corners") == "1");              // corners=1: the workbench's SPLITS page also wants every lap's corner times
            }
            catch (Exception ex) { Log.W("session review: " + ex.Message); code = 500; return Err("could not read that file"); }
            finally { try { Thread.CurrentThread.Priority = was; } catch { } }
        }

        // The newest telemetry file by write time. A file iRacing is still writing is fine: nothing is shown while he drives.
        static string NewestTelemetry(string dir)
        {
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return null;
            string best = null; DateTime bt = DateTime.MinValue;
            foreach (string f in Directory.GetFiles(dir, "*.ibt"))
            {
                DateTime w = File.GetLastWriteTimeUtc(f);
                if (best == null || w > bt) { best = f; bt = w; }
            }
            return best;
        }

        // one-shot for tests\session-review-test.ps1 (its own tiny exe, see tests\sr-main.cs): no window, no deploy, only the folder it is given
        public static int SrCli(string[] args)
        {
            try
            {
                Process p = Process.GetCurrentProcess();
                p.PriorityClass = ProcessPriorityClass.BelowNormal;
                int cores = Environment.ProcessorCount;
                if (cores > 2)
                {
                    long mask = 0;
                    for (int i = 0; i < 2; i++) mask |= 1L << (cores - 1 - i);
                    p.ProcessorAffinity = (IntPtr)mask;
                }
            }
            catch { }
            string root = Arg(args, "--root"), dir = Arg(args, "--dir"), id = Arg(args, "--id"), outPath = Arg(args, "--out");
            int focus; int.TryParse(Arg(args, "--lap"), NumberStyles.Integer, Inv, out focus);
            string json;
            if (root.Length == 0 || dir.Length == 0 || id.Length == 0 || outPath.Length == 0) json = Err("need --root --dir --id --out");
            else
            {
                Corners.DataRoot = root;
                TrackMaps.MapsDir = Path.Combine(root, @"dash\maps");
                string file = Path.Combine(dir, id);
                if (!File.Exists(file)) json = Err("no such file");
                else
                {
                    try { json = BuildSession(file, dir, false, focus, Array.IndexOf(args, "--corners") >= 0); }
                    catch (Exception ex) { json = Err(ex.Message); }
                }
            }
            try { File.WriteAllText(outPath, json, new UTF8Encoding(false)); }
            catch { return 1; }
            return json.StartsWith("{\"error\"", StringComparison.Ordinal) ? 1 : 0;
        }

        // A lap that counts (L-1, LapRules): a full lap, clean by the C-30 rules, with the time iRacing announced for it, that iRacing COUNTED -
        // no off-track record in it and its own best lap not slower than the lap's time (a timed lap with a short off-track is not counted by iRacing).
        static bool Valid(LapTrace lap) { return Counted(lap); }

        static string FlagOf(LapTrace lap, bool first)
        {
            if (Valid(lap)) return "";
            if (lap.Skip == "out" || (first && lap.Skip.Length == 0)) return "OUT";      // the lap he joined on (a race start lap is timed from the grid, not line to line)
            if (lap.Skip == "in") return "IN";
            if (lap.Skip == "pit") return "PIT";
            // Only facts: OFF when the car was seen off track - for long by our own rule (skip "off"), or at all in a lap iRacing timed but did not count;
            // INVALID (iRacing's own word) when iRacing gave the lap no time (-1) or timed it but its best lap says it did not count it (nothing seen).
            if (lap.Tm != null)
            {
                if (lap.Skip.Length == 0) return Timed(lap) && lap.OffAny ? "OFF" : "INVALID";
                return lap.Skip.ToUpperInvariant();      // "off" -> OFF, "partial" -> PARTIAL
            }
            return "";
        }

        static string DriverField(string yaml, string key)
        {
            string me = TrackMaps.YamlValue(yaml ?? "", "DriverCarIdx");
            Match block = Regex.Match(yaml ?? "", "- CarIdx: " + Regex.Escape(me) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
            return me.Length > 0 && block.Success ? TrackMaps.YamlValue(block.Groups[1].Value, key) : "";
        }

        // header: ticks per second (60) - needed for the time he spent on track
        static int TickRate(string path)
        {
            try
            {
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    byte[] h = new byte[16];
                    if (fs.Read(h, 0, 16) < 16) return 60;
                    int r = BitConverter.ToInt32(h, 8);
                    return r > 0 && r <= 1000 ? r : 60;
                }
            }
            catch { return 60; }
        }

        static string Fact(string code, Met a, Met b, Diff d)
        {
            if (code == "brake") return "braking starts " + Metres(d.DBr) + " m " + (d.DBr > 0 ? "later" : "earlier");
            if (code == "entry") return "entry speed " + Kmh(a.Entry) + " vs " + Kmh(b.Entry) + " km/h";
            if (code == "min") return "minimum " + Kmh(a.Min) + " vs " + Kmh(b.Min) + " km/h";
            if (code == "pickup") return "full throttle " + Metres(d.DPk) + " m " + (d.DPk > 0 ? "later" : "earlier");
            if (code == "exit") return "exit speed " + Kmh(a.Exit) + " vs " + Kmh(b.Exit) + " km/h";
            return "";
        }

        sealed class NoteRow { public Met A, B; public Diff D; }

        static void AppendNums(StringBuilder sb, double[] v, string fmt)
        {
            sb.Append('[');
            if (v != null) for (int i = 0; i < v.Length; i++) { if (i > 0) sb.Append(','); sb.Append(F(v[i], fmt)); }
            sb.Append(']');
        }

        // withCorners (C-41, workbench SPLITS): each lap also carries "cornerT" = its seconds through every corner of the
        // corner model, in the order of the reply's "turns" (the lap store already holds what Measure needs: no file is read again)
        static string BuildSession(string file, string dir, bool liveRules, int focusLap, bool withCorners)
        {
            List<Sess> sessions = Gather(file, dir, liveRules);
            Sess mine = sessions[0];
            CornerSet cs = LoadCorners(mine);
            int ns = mine.SectorAt != null ? mine.SectorAt.Length : 0;

            // one row per lap number: timed laps, plus the out and in laps even when iRacing gave them no time
            List<LapTrace> rows = new List<LapTrace>();
            foreach (LapTrace lap in mine.Laps)
            {
                if (lap.Tm == null && lap.Skip != "out" && lap.Skip != "in") continue;
                int at = -1;
                for (int i = 0; i < rows.Count; i++) if (rows[i].Lap == lap.Lap) at = i;
                if (at < 0) rows.Add(lap);
                else if ((Valid(lap) && !Valid(rows[at])) || (lap.Tm != null && rows[at].Tm == null)) rows[at] = lap;
            }
            rows.Sort(delegate (LapTrace a, LapTrace b) { return a.Lap.CompareTo(b.Lap); });

            List<LapTrace> ok = new List<LapTrace>();
            foreach (LapTrace lap in rows) if (Valid(lap) && lap.SectorT != null && lap.SectorT.Length == ns && lap.Mini != null && lap.Mini.Length == 24) ok.Add(lap);
            LapTrace best = Fastest(ok, null, null);

            // his history on this car and track: the other files the store gathered (same car, track and layout)
            LapTrace prev = null; int histLaps = 0, pureHist = 0;
            double[] everSec = new double[ns], everMini = new double[24];      // best ever sectors: joined only from laps with no off-track record (Pure), like the optimal
            for (int i = 0; i < ns; i++) everSec[i] = double.MaxValue;
            for (int i = 0; i < 24; i++) everMini[i] = double.MaxValue;
            for (int si = 1; si < sessions.Count; si++)
                foreach (LapTrace lap in sessions[si].Laps)
                {
                    if (!Valid(lap) || lap.SectorT == null || lap.SectorT.Length != ns || lap.Mini == null || lap.Mini.Length != 24 || Math.Abs(lap.LengthM - mine.LengthM) > 1) continue;
                    histLaps++;
                    if (prev == null || Better(lap, prev)) prev = lap;
                    if (!Pure(lap)) continue;
                    pureHist++;
                    for (int i = 0; i < ns; i++) if (lap.SectorT[i] < everSec[i]) everSec[i] = lap.SectorT[i];
                    for (int i = 0; i < 24; i++) if (lap.Mini[i] < everMini[i]) everMini[i] = lap.Mini[i];
                }

            // optimal: the best iRacing sectors of THIS session joined. Each sector counts at the millisecond it is shown at,
            // so S1 + S2 + ... on the screen add up to the optimal lap shown.
            // L-1b: only from counted laps with no off-track record at all (Pure); with none there is no optimal (sectors across the grass are not a lap anyone can drive)
            double[] bestSec = new double[ns];
            for (int i = 0; i < ns; i++) bestSec[i] = double.MaxValue;
            int pureN = 0;
            foreach (LapTrace lap in ok)
            {
                if (!Pure(lap)) continue;
                pureN++;
                for (int i = 0; i < ns; i++)
                {
                    double ms = Math.Round(lap.SectorT[i], 3, MidpointRounding.AwayFromZero);
                    if (ms < bestSec[i]) bestSec[i] = ms;
                }
            }
            double optimal = 0; bool haveOpt = pureN > 0 && ns > 0;
            for (int i = 0; i < ns; i++) { if (bestSec[i] > 1e8) haveOpt = false; else optimal += bestSec[i]; }
            if (haveOpt && best != null && optimal > best.Time + 0.0005) haveOpt = false;      // the best lap itself had an off-track and is quicker than anything that can be joined: no optimal

            // consistency: the average of his best 5 valid laps and the spread (standard deviation) of those laps
            List<double> times = new List<double>();
            foreach (LapTrace lap in ok) times.Add(lap.Time);
            times.Sort();
            int n5 = times.Count < 5 ? times.Count : 5;
            double avg5 = 0, sd5 = 0;
            for (int i = 0; i < n5; i++) avg5 += times[i];
            if (n5 > 0) avg5 /= n5;
            for (int i = 0; i < n5; i++) sd5 += (times[i] - avg5) * (times[i] - avg5);
            if (n5 > 0) sd5 = Math.Sqrt(sd5 / n5);

            // The lap the map and the notes are about: the best one (default), or the one asked for with &lap=n (tests, later a picker).
            LapTrace shown = best;
            if (focusLap > 0) foreach (LapTrace lap in ok) if (lap.Lap == focusLap) shown = lap;

            // the reference: previous best from other sessions, else the second best lap of this one. Never the lap itself.
            LapTrace rf = null; string refKind = "";
            if (shown != null && prev != null) { rf = prev; refKind = "previous"; }
            else if (shown != null) { rf = Fastest(ok, null, shown); if (rf != null) refKind = "session"; }
            if (rf != null && SameLap(rf, shown)) { rf = null; refKind = ""; }

            // corner differences (C-30): a note only where CompareMet found one clear cause
            List<NoteRow> notes = new List<NoteRow>();
            StringBuilder cj = new StringBuilder();
            if (shown != null && rf != null && cs != null && cs.Turns != null && cs.Turns.Count > 0)
            {
                Measure(shown, cs); Measure(rf, cs);
                bool first = true;
                foreach (Met m in shown.Corners)
                {
                    Met o = ByN(rf.Corners, m.N);
                    if (o == null) continue;
                    Diff d = CompareMet(m, o, shown.LengthM);
                    if (!first) cj.Append(','); first = false;
                    cj.Append("{\"n\":").Append(m.N).Append(",\"label\":").Append(Json_.S(m.Label)).Append(",\"name\":").Append(Json_.S(m.Name)).Append(",\"official\":").Append(Json_.S(m.Official)).Append(",\"dTime\":").Append(F(d.DTime, "0.000")).Append('}');
                    if (d.Cause.Length > 0 && Fact(d.Code, m, o, d).Length > 0) { NoteRow nr = new NoteRow(); nr.A = m; nr.B = o; nr.D = d; notes.Add(nr); }
                }
                notes.Sort(delegate (NoteRow x, NoteRow y) { return Math.Abs(y.D.DTime).CompareTo(Math.Abs(x.D.DTime)); });
                if (notes.Count > 3) notes.RemoveRange(3, notes.Count - 3);
            }

            // the time he spent in the car, from the records of every run in the file
            int rate = TickRate(mine.Path);
            long recs = 0;
            foreach (LapTrace lap in mine.Laps) recs += Math.Max(0, lap.RecB - lap.RecA);
            double seconds = recs / (double)rate;
            long startMs = mine.HeaderTicks > 1000000000L && mine.HeaderTicks < 4000000000L ? mine.HeaderTicks * 1000L : 0;
            long modMs = 0;      // when the file was last written: the page uses it to tell this session from an older one
            try { modMs = (long)(File.GetLastWriteTimeUtc(mine.Path) - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; } catch { }
            if (startMs == 0) startMs = modMs;
            string type = Career.SessionTypeOf(mine.Yaml, -1);
            if (type.Length == 0) type = TrackMaps.YamlValue(mine.Yaml, "EventType");
            string user = DriverField(mine.Yaml, "UserName"), team = DriverField(mine.Yaml, "TeamName"), number = DriverField(mine.Yaml, "CarNumber");
            if (team == user) team = "";

            StringBuilder sb = new StringBuilder(12000);
            sb.Append("{\"v\":1,\"file\":").Append(Json_.S(mine.File)).Append(",\"car\":").Append(Json_.S(mine.Car)).Append(",\"driver\":").Append(Json_.S(user)).Append(",\"team\":").Append(Json_.S(team)).Append(",\"carNumber\":").Append(Json_.S(number));
            sb.Append(",\"track\":").Append(Json_.S(mine.Track)).Append(",\"config\":").Append(Json_.S(mine.Config)).Append(",\"lengthM\":").Append(F(mine.LengthM, "0.0"));
            sb.Append(",\"type\":").Append(Json_.S(type)).Append(",\"startMs\":").Append(startMs.ToString(Inv)).Append(",\"modMs\":").Append(modMs.ToString(Inv)).Append(",\"seconds\":").Append(F(seconds, "0")).Append(",\"credit\":").Append(Json_.S(cs != null ? cs.Credit : ""));
            sb.Append(",\"sectorFrom\":").Append(Json_.S(mine.SectorFrom)).Append(",\"sectorAt\":"); AppendNums(sb, mine.SectorAt, "0.000000");
            sb.Append(",\"laps\":[");
            for (int i = 0; i < rows.Count; i++)
            {
                LapTrace lap = rows[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(lap.Lap).Append(",\"time\":").Append(lap.Tm != null ? F(lap.Time, "0.000") : "null").Append(",\"official\":").Append(lap.HasOfficial ? "true" : "false");
                sb.Append(",\"valid\":").Append(Valid(lap) ? "true" : "false").Append(",\"timed\":").Append(Timed(lap) ? "true" : "false").Append(",\"offTrack\":").Append(lap.Tm != null && lap.OffAny ? "true" : "false").Append(",\"offSamples\":").Append(lap.OffSamples).Append(",\"bestBefore\":").Append(F(lap.BestBefore, "0.000")).Append(",\"bestAfter\":").Append(F(lap.BestAfter, "0.000")).Append(",\"countedBy\":").Append(Json_.S(lap.Tm != null && lap.HasOfficial ? CountedBy(lap) : "iRacing gave the lap no time")).Append(",\"flag\":").Append(Json_.S(FlagOf(lap, i == 0))).Append(",\"skip\":").Append(Json_.S(lap.Skip));
                sb.Append(",\"sectors\":"); if (lap.Tm != null && lap.SectorT != null) AppendNums(sb, lap.SectorT, "0.000"); else sb.Append("null");
                sb.Append(",\"mini\":"); if (lap.Tm != null && lap.Mini != null) AppendNums(sb, lap.Mini, "0.000"); else sb.Append("null");
                if (withCorners)
                {
                    sb.Append(",\"cornerT\":");
                    if (lap.Tm != null && lap.Clean && cs != null && cs.Turns != null && cs.Turns.Count > 0)
                    {
                        Measure(lap, cs);
                        sb.Append('[');
                        for (int k = 0; k < lap.Corners.Count; k++) { if (k > 0) sb.Append(','); sb.Append(F(lap.Corners[k].Time, "0.000")); }
                        sb.Append(']');
                    }
                    else sb.Append("null");
                }
                sb.Append('}');
            }
            sb.Append("]");
            if (withCorners)
            {
                sb.Append(",\"turns\":[");
                if (cs != null && cs.Turns != null)
                    for (int k = 0; k < cs.Turns.Count; k++)
                    {
                        CornerTurn tn = cs.Turns[k];
                        if (k > 0) sb.Append(',');
                        sb.Append("{\"n\":").Append(tn.N).Append(",\"label\":").Append(Json_.S(LabelOf(tn))).Append(",\"name\":").Append(Json_.S(tn.Name ?? "")).Append(",\"official\":").Append(Json_.S(tn.Official ?? "")).Append('}');
                    }
                sb.Append(']');
            }
            sb.Append(",\"best\":");
            if (best == null) sb.Append("null"); else sb.Append("{\"lap\":").Append(best.Lap).Append(",\"time\":").Append(F(best.Time, "0.000")).Append('}');
            sb.Append(",\"shown\":");
            if (shown == null) sb.Append("null"); else sb.Append("{\"lap\":").Append(shown.Lap).Append(",\"time\":").Append(F(shown.Time, "0.000")).Append('}');
            sb.Append(",\"prev\":");
            if (prev == null) sb.Append("null,\"ever\":null");
            else
            {
                sb.Append("{\"file\":").Append(Json_.S(prev.File)).Append(",\"lap\":").Append(prev.Lap).Append(",\"time\":").Append(F(prev.Time, "0.000")).Append(",\"date\":").Append(Json_.S(DateOf(prev.File))).Append(",\"laps\":").Append(histLaps).Append('}');
                if (pureHist > 0) { sb.Append(",\"ever\":{\"sectors\":"); AppendNums(sb, everSec, "0.000"); sb.Append(",\"mini\":"); AppendNums(sb, everMini, "0.000"); sb.Append('}'); }
                else sb.Append(",\"ever\":null");
            }
            sb.Append(",\"ref\":");
            if (rf == null) sb.Append("null");
            else sb.Append("{\"kind\":").Append(Json_.S(refKind)).Append(",\"file\":").Append(Json_.S(rf.File)).Append(",\"lap\":").Append(rf.Lap).Append(",\"time\":").Append(F(rf.Time, "0.000")).Append(",\"spec\":").Append(Json_.S(rf.File + ":" + rf.Lap.ToString(Inv))).Append('}');
            sb.Append(",\"bestSectors\":"); if (haveOpt) AppendNums(sb, bestSec, "0.000"); else sb.Append("null");
            sb.Append(",\"optimal\":").Append(haveOpt ? F(optimal, "0.000") : "null");
            sb.Append(",\"consistency\":").Append(n5 > 0 ? "{\"n\":" + n5.ToString(Inv) + ",\"avg\":" + F(avg5, "0.000") + ",\"sd\":" + F(sd5, "0.000") + "}" : "null");
            sb.Append(",\"validLaps\":").Append(ok.Count);
            sb.Append(",\"corners\":[").Append(cj).Append("],\"notes\":[");
            for (int i = 0; i < notes.Count; i++)
            {
                NoteRow nr = notes[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(nr.A.N).Append(",\"label\":").Append(Json_.S(nr.A.Label)).Append(",\"dTime\":").Append(F(nr.D.DTime, "0.000")).Append(",\"code\":").Append(Json_.S(nr.D.Code));
                sb.Append(",\"fact\":").Append(Json_.S(Fact(nr.D.Code, nr.A, nr.B, nr.D))).Append(",\"cause\":").Append(Json_.S(nr.D.Cause));
                sb.Append(",\"dBrakeM\":").Append(nr.D.HasBr ? F(nr.D.DBr, "0.00") : "null").Append(",\"dEntryKmh\":").Append(nr.D.HasEn ? F(nr.D.DEn, "0.00") : "null").Append(",\"dMinKmh\":").Append(nr.D.HasMn ? F(nr.D.DMn, "0.00") : "null");
                sb.Append(",\"dPickupM\":").Append(nr.D.HasPk ? F(nr.D.DPk, "0.00") : "null").Append(",\"dExitKmh\":").Append(nr.D.HasEx ? F(nr.D.DEx, "0.00") : "null").Append('}');
            }
            sb.Append("]}");
            return sb.ToString();
        }
    }
}
