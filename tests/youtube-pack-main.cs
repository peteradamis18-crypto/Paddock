// Entry point for tests\youtube-pack-test.ps1 only (W1-11): compiled with dash\src\*.cs (the build.ps1 list) into a throw-away exe in %TEMP%.
// args: <work folder> <ffmpeg.exe> <ffprobe.exe> <fixture clip.mp4> <shots folder>
// 1. titles from 8 fixture stories   2. the description and tags   3. the story from a fixture field log   4. the thumbnail from the
// fixture clip   5. the highlights plan and a real join of the fixture clip   6. the model hook: off by default, the stub path, the key
// never logged. No call reaches the Claude API (Words.Ask is a stub); ffmpeg only ever reads the fixture clip the test made.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDash
{
    static class YouTubePackMain
    {
        static int fails;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static void Ok(string what, bool cond, string why)
        {
            if (cond) Console.WriteLine("ok " + what);
            else { fails++; Console.WriteLine("FAIL " + what + (string.IsNullOrEmpty(why) ? "" : " (" + why + ")")); }
        }
        static void Ok(string what, bool cond) { Ok(what, cond, ""); }

        static Facts F(string car, string track, int start, int finish, int field)
        {
            Facts f = new Facts(); f.Car = car; f.Track = track; f.Start = start; f.Finish = finish; f.Field = field; f.Date = new DateTime(2026, 11, 13, 20, 0, 0);
            return f;
        }

        static int Main(string[] a)
        {
            string tmp = a[0], ffmpeg = a[1], ffprobe = a[2], clip = a[3], shots = a[4];
            Directory.CreateDirectory(tmp);
            Log.FilePath = Path.Combine(tmp, "pack.log");
            YouTube.Dir = Path.Combine(tmp, "yt"); YouTube.IniFile = Path.Combine(tmp, "dash", "irdash.ini");
            Directory.CreateDirectory(Path.GetDirectoryName(YouTube.IniFile));
            try { Titles(); } catch (Exception ex) { Ok("1. titles ran", false, ex.ToString()); }
            try { Description(); } catch (Exception ex) { Ok("2. description ran", false, ex.ToString()); }
            try { Story(tmp); } catch (Exception ex) { Ok("3. story ran", false, ex.ToString()); }
            try { ThumbTest(tmp, ffmpeg, clip, shots); } catch (Exception ex) { Ok("4. thumbnail ran", false, ex.ToString()); }
            try { HighlightsTest(tmp, ffmpeg, ffprobe, clip); } catch (Exception ex) { Ok("5. highlights ran", false, ex.ToString()); }
            try { Model(tmp); } catch (Exception ex) { Ok("6. model hook ran", false, ex.ToString()); }
            Console.WriteLine("DONE");
            return fails == 0 ? 0 : 1;
        }

        // ---------------- 1 ----------------
        static void Titles()
        {
            Facts[] fx = new Facts[8]; string[] want = new string[8];
            fx[0] = F("Toyota GR86", "Road Atlanta", 15, 4, 24); fx[0].BestLap = "1:34.850";
            want[0] = "P15 to P4 at Road Atlanta · Toyota GR86 · 1:34.850";
            fx[1] = F("Porsche 718 Cayman GT4 Clubsport MR", "Circuit de Spa-Francorchamps", 22, 7, 22);
            want[1] = "Last to P7 at Circuit de Spa-Francorchamps · Cayman GT4 Clubsport MR";
            fx[2] = F("BMW M4 GT3", "Monza", 1, 1, 20); fx[2].BestLap = "1:47.212";
            want[2] = "Pole and the win at Monza · BMW M4 GT3 · 1:47.212";
            fx[3] = F("Toyota GR86", "Lime Rock Park", 15, 15, 24); fx[3].Incidents = 0;
            want[3] = "P15 of 24 at Lime Rock Park · Toyota GR86";
            fx[4] = F("Mazda MX-5 Cup", "Okayama", 6, 3, 18);
            want[4] = "P6 to P3 on the podium at Okayama · Mazda MX-5 Cup";
            fx[5] = F("Toyota GR86", "Summit Point", 8, 5, 16); fx[5].LastLapPass = true;
            want[5] = "Last-lap pass for P5 at Summit Point · Toyota GR86";
            fx[6] = F("Ford Mustang GT4", "Watkins Glen International", 18, 9, 24); fx[6].Incidents = 6;
            want[6] = "Recovery drive: P18 to P9 at Watkins Glen International · Mustang GT4";
            fx[7] = F("Toyota GR86", "Oulton Park", 10, 12, 20); fx[7].FastestLap = true; fx[7].BestLap = "1:41.003";
            want[7] = "Fastest lap and P12 at Oulton Park · Toyota GR86 · 1:41.003";
            for (int i = 0; i < 8; i++)
            {
                string t = Cuts.StoryTitle(fx[i]);
                Console.WriteLine("  title " + (i + 1) + ": " + t + " (" + t.Length + ")");
                Ok("1." + (i + 1) + " title reads '" + want[i] + "'", t == want[i], t);
                Ok("1." + (i + 1) + " under YouTube's 100 (and under 70 shown)", t.Length <= 100 && t.Length < 70, t.Length.ToString(Inv));
                bool names = fx[i].Finish == 1 ? Regex.IsMatch(t, "win", RegexOptions.IgnoreCase) : t.Contains("P" + fx[i].Finish.ToString(Inv));
                Ok("1." + (i + 1) + " it names the result", names, t);
                Ok("1." + (i + 1) + " no lie: never 'comeback', never a gain the numbers do not show", !Regex.IsMatch(t, "comeback|charge|storm", RegexOptions.IgnoreCase) &&
                    (fx[i].Start > fx[i].Finish || !Regex.IsMatch(t, "P\\d+ to P\\d+")), t);
            }
            Ok("1. P15 to P15 says 'P15 of 24', never 'P15 to P15'", Cuts.StoryTitle(fx[3]).StartsWith("P15 of 24") && !Cuts.StoryTitle(fx[3]).Contains("to P15"));
            Ok("1. a lost place never says 'to' (P10 -> P12 with the fastest lap)", !Cuts.StoryTitle(fx[7]).Contains("P10"));
            Facts none = F("Toyota GR86", "Road Atlanta", 0, 0, 0);
            Ok("1. no story known: StoryTitle is empty, so the chosen template stands", Cuts.StoryTitle(none) == "" && Cuts.Title(1, none).StartsWith("Toyota GR86 at Road Atlanta"));
            Facts lng = F("Porsche 911 GT3 Cup (992) Long Name Edition", "Nurburgring Combined Gesamtstrecke Long", 30, 2, 40); lng.BestLap = "8:12.004";
            string lt = Cuts.StoryTitle(lng);
            Ok("1. very long names still fit under 70 and keep the hook first", lt.Length < 70 && lt.StartsWith("P30 to P2 on the podium at "), lt + " (" + lt.Length + ")");
        }

        // ---------------- 2 ----------------
        static void Description()
        {
            Facts f = F("Toyota GR86", "Road Atlanta", 15, 4, 24); f.Config = "Full Course"; f.Laps = 20; f.BestLap = "1:34.850"; f.BestLapN = 12;
            f.IrChange = 38; f.IrBefore = 1650; f.Incidents = 2; f.PassLap = 17; f.PassFor = 4; f.PassWhere = "T10"; f.Series = "GR86 Cup";
            CutPlan p = new CutPlan();
            p.Chapters.Add(new Chapter(0, "Start")); p.Chapters.Add(new Chapter(412, "Incident +2x")); p.Chapters.Add(new Chapter(780, "Best lap 1:34.850 (lap 12)")); p.Chapters.Add(new Chapter(1248, "Finish"));
            string d = Cuts.StoryDescription(p, f, "Thanks for watching. Sim rig: Simucube, triple screens.");
            Console.WriteLine("  description:\n" + d.Replace("\n", "\n    | "));
            string[] parts = d.Split(new string[] { "\n\n" }, StringSplitOptions.None);
            Ok("2. three paragraphs (+ the sign-off line)", parts.Length == 4, parts.Length.ToString(Inv));
            Ok("2. paragraph 1 says what happened, the decisive lap from the field log",
                parts[0] == "Started P15, finished P4 of 24 (+11). The move that decided it: the pass for P4 on lap 17 at T10. 2x incidents.", parts[0]);
            Ok("2. paragraph 2: car and track, date, series, laps, lap time and the iRating change",
                parts[1] == "Toyota GR86 at Road Atlanta, 13 Nov 2026 · iRacing GR86 Cup · 20 laps · best 1:34.850 (lap 12) · iRating +38 (1650 to 1688)", parts[1]);
            Ok("2. paragraph 3: the chapters, first 0:00", parts[2].StartsWith("0:00 Start\n6:52 Incident +2x\n13:00 Best lap") && parts[2].EndsWith("20:48 Finish"), parts[2]);
            Ok("2. the sign-off from youtube_signoff= ends it", parts[3] == "Thanks for watching. Sim rig: Simucube, triple screens.");
            Ok("2. no sign-off set: none at all", !Cuts.StoryDescription(p, f, "").Contains("Thanks") && Cuts.StoryDescription(p, f, "").EndsWith("20:48 Finish"));
            Ok("2. under YouTube's 5000", d.Length < 5000);
            Facts z = F("Toyota GR86", "Road Atlanta", 15, 15, 24); z.Incidents = 0;
            Ok("2. P15 to P15 says so plainly, no gain", Cuts.About(z).StartsWith("Started P15, finished P15 of 24. No incidents."), Cuts.About(z));
            List<string> tags = Cuts.Tags(f);
            Ok("2. tags: track, car, series, iRacing, sim racing", string.Join("|", tags.ToArray()) == "Road Atlanta|Toyota GR86|GR86 Cup|iRacing|sim racing", string.Join("|", tags.ToArray()));
            File.WriteAllText(YouTube.IniFile, "youtube_signoff=Thanks for watching\r\n");
            Ok("2. the sign-off is read from irdash.ini (youtube_signoff=)", YouTube.Signoff == "Thanks for watching");
            File.Delete(YouTube.IniFile);
            Ok("2. no ini: no sign-off", YouTube.Signoff == "");
        }

        // ---------------- 3 ----------------
        static RfLap L(int n, double s, double e, int pos) { RfLap l = new RfLap(); l.N = n; l.S = s; l.E = e; l.Pos = pos; l.CPos = pos; l.Sim = e - s; return l; }
        static void Story(string tmp)
        {
            string fdir = Path.Combine(tmp, "field"); Directory.CreateDirectory(fdir);
            Pack.FieldDirOverride = fdir;
            DateTime start = new DateTime(2026, 11, 13, 20, 0, 0, DateTimeKind.Local);
            long ms = (long)(start.ToUniversalTime() - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            RfData d = new RfData(); d.Id = "f20261113-200000-2"; d.StartMs = ms; d.EndMs = ms + 900000; d.SessType = "Race"; d.SessNum = 2; d.Official = true; d.Me = 0;
            d.Track = "roadatlanta"; d.TrackName = "Road Atlanta"; d.Complete = true; d.MeInc = 2;
            RfCar me = new RfCar(); me.Idx = 0; me.Me = true; me.Cls = "GR86"; me.IR = 1650; me.Name = "Peter"; me.Num = "7"; me.Finished = true; me.ResBest = 94.85;
            RfCar b = new RfCar(); b.Idx = 1; b.Cls = "GR86"; b.IR = 1800; b.Name = "B"; b.Num = "2"; b.Finished = true; b.ResBest = 95.20;
            RfCar c = new RfCar(); c.Idx = 2; c.Cls = "GR86"; c.IR = 1500; c.Name = "C"; c.Num = "3"; c.Finished = true; c.ResBest = 95.40;
            // session time 100 = the green; 3 laps of ~95 s; he starts P3, passes C on lap 2 (t 230) and B on lap 3 (t 330): P1
            me.Laps.Add(L(1, 100, 195, 3)); me.Laps.Add(L(2, 195, 290, 2)); me.Laps.Add(L(3, 290, 384.85, 1));
            b.Laps.Add(L(1, 100, 194, 1)); b.Laps.Add(L(2, 194, 289, 1)); b.Laps.Add(L(3, 289, 385, 2));
            c.Laps.Add(L(1, 100, 194.5, 2)); c.Laps.Add(L(2, 194.5, 291, 3)); c.Laps.Add(L(3, 291, 387, 3));
            d.Cars.Add(me); d.Cars.Add(b); d.Cars.Add(c);
            RfPass p1 = new RfPass(); p1.T = 230; p1.Lap = 2; p1.By = 0; p1.Over = 2; p1.Where = "T5";
            RfPass p2 = new RfPass(); p2.T = 330; p2.Lap = 3; p2.By = 0; p2.Over = 1; p2.Where = "T10a";
            d.Passes.Add(p1); d.Passes.Add(p2);
            File.WriteAllText(Path.Combine(fdir, d.Id + ".json"), d.ToJson(true, null, false), new UTF8Encoding(false));

            RaceInfo r = new RaceInfo(); r.Id = "race-1"; r.IsRace = true; r.StartMs = ms - 30000; r.Sec = 420; r.Laps = 3; r.Best = 94.85; r.BestLap = 3;
            r.Car = "Toyota GR86"; r.Track = "Road Atlanta"; r.File = Path.Combine(tmp, "sessions", "race-1.mp4");
            RaceMarker inc = new RaceMarker(); inc.Sec = 150; inc.Kind = "incident"; inc.Label = "Incident +2x"; r.Markers.Add(inc);
            RecSess s = new RecSess(); s.Id = r.Id;
            // the recorder's lap rows: lap 1 starts 40 s into the video (so session time t is video t - 60)
            s.LapRows.Add(new double[] { 1, 40, 95, 1, 0, double.NaN }); s.LapRows.Add(new double[] { 2, 135, 95, 1, 0, double.NaN }); s.LapRows.Add(new double[] { 3, 230, 94.85, 1, 1, double.NaN });
            Facts f = new Facts(); f.Car = r.Car; f.Track = r.Track;
            CutPlan cp = new CutPlan(); cp.BestLap = "1:34.850";
            List<Moment> moments = new List<Moment>();
            double dec = Pack.Story(r, s, cp, f, moments);
            Ok("3. the field log of the race is found by its time", Pack.FieldLog(r) != null);
            Ok("3. start and finish from the REVIEW numbers when the sidecar has none: P3 to P1", f.Start == 3 && f.Finish == 1, f.Start + " -> " + f.Finish);
            Ok("3. fastest lap of his class", f.FastestLap);
            Ok("3. the decisive pass: for P1 on lap 3 at T10a", f.PassLap == 3 && f.PassFor == 1 && f.PassWhere == "T10a", f.PassLap + "/" + f.PassFor + "/" + f.PassWhere);
            Ok("3. a pass on the last lap", f.LastLapPass);
            Ok("3. the iRating change (official, rated field) is known", f.IrChange != int.MinValue && f.IrBefore == 1650, f.IrChange.ToString(Inv));
            Ok("3. the decisive pass in video seconds (session 330 -> video 270)", Math.Abs(dec - 270) < 0.01, dec.ToString(Inv));
            int passes = 0, incs = 0; foreach (Moment m in moments) { if (m.Kind == "pass") passes++; if (m.Kind == "incident") incs++; }
            Ok("3. moments: both passes and the incident", passes == 2 && incs == 1, moments.Count.ToString(Inv));
            Ok("3. the story title from it", Cuts.StoryTitle(f) == "P3 to the win at Road Atlanta · Toyota GR86 · 1:34.850", Cuts.StoryTitle(f));
            Pack.FieldDirOverride = Path.Combine(tmp, "nofield");
            Facts g = new Facts(); g.Car = r.Car; g.Track = r.Track;
            Ok("3. no field log: no story, nothing made up", Pack.Story(r, s, cp, g, new List<Moment>()) < 0 && g.Start == 0 && g.Finish == 0 && !g.FastestLap && g.IrChange == int.MinValue);
        }

        // ---------------- 4 ----------------
        static void ThumbTest(string tmp, string ffmpeg, string clip, string shots)
        {
            Facts f = F("Toyota GR86", "Road Atlanta", 15, 4, 24);
            string jpg = Path.Combine(tmp, "race-1.thumb.jpg");
            string res = Thumb.Make(ffmpeg, clip, 5, f, jpg);
            Ok("4. the thumbnail is made from the fixture clip", res == "ok" && File.Exists(jpg), res);
            if (!File.Exists(jpg)) return;
            long size = new FileInfo(jpg).Length;
            byte[] head = new byte[2]; using (FileStream fs = File.OpenRead(jpg)) fs.Read(head, 0, 2);
            Ok("4. a JPEG under YouTube's 2 MB", head[0] == 0xFF && head[1] == 0xD8 && size < 2 * 1024 * 1024, size.ToString(Inv));
            using (Bitmap bm = new Bitmap(jpg))
            {
                Ok("4. 1280 x 720", bm.Width == 1280 && bm.Height == 720, bm.Width + "x" + bm.Height);
                // the big gold type: many house-gold pixels in the low-left block, none of the fixture's own there
                int gold = 0;
                for (int x = 60; x < 1100; x += 3) for (int y = 330; y < 560; y += 3)
                    {
                        Color c = bm.GetPixel(x, y);
                        if (Math.Abs(c.R - 0xC9) < 30 && Math.Abs(c.G - 0xA2) < 30 && Math.Abs(c.B - 0x4B) < 35) gold++;
                    }
                Ok("4. the big gold type is drawn (" + gold + " gold samples)", gold > 400, gold.ToString(Inv));
                bm.Save(Path.Combine(shots, "yt-thumb-p15-p4.png"), System.Drawing.Imaging.ImageFormat.Png);
            }
            Ok("4. the big words: P15 → P4", Thumb.BigText(f) == "P15 → P4");
            Ok("4. a win says WIN", Thumb.BigText(F("x", "y", 3, 1, 10)) == "WIN");
            Ok("4. no gain: just the place", Thumb.BigText(F("x", "y", 15, 15, 24)) == "P15");
            Ok("4. the frame came from the clip (ffmpeg -ss 5, scale and crop to 1280x720)", Thumb.LastArgs.Contains("-ss 5.000") && Thumb.LastArgs.Contains("crop=1280:720") && Thumb.LastArgs.Contains(Path.GetFileName(clip)));
            Ok("4. no frame or part file left over", !File.Exists(jpg + ".frame.png") && !File.Exists(jpg + ".part.jpg"));
            string win = Path.Combine(tmp, "race-2.thumb.jpg");
            if (Thumb.Make(ffmpeg, clip, 8, F("BMW M4 GT3", "Monza", 1, 1, 20), win) == "ok")
                using (Bitmap bm = new Bitmap(win)) bm.Save(Path.Combine(shots, "yt-thumb-win.png"), System.Drawing.Imaging.ImageFormat.Png);
            Ok("4. a missing video says so, makes nothing", Thumb.Make(ffmpeg, Path.Combine(tmp, "none.mp4"), 5, f, Path.Combine(tmp, "x.jpg")) == "The race video is missing." && !File.Exists(Path.Combine(tmp, "x.jpg")));
            Thumb.Ffmpeg = delegate (string args, int ms) { return Cuts.Yielded; };
            Ok("4. a session starting stops it (YIELD, nothing left)", Thumb.Make(ffmpeg, clip, 5, f, Path.Combine(tmp, "y.jpg")) == "YIELD" && !File.Exists(Path.Combine(tmp, "y.jpg")));
            Thumb.Ffmpeg = null;
        }

        // ---------------- 5 ----------------
        static void HighlightsTest(string tmp, string ffmpeg, string ffprobe, string clip)
        {
            List<Moment> ms = new List<Moment>();
            ms.Add(new Moment(300, "pass", "Pass (lap 4)")); ms.Add(new Moment(120, "pass", "Pass (lap 2)")); ms.Add(new Moment(302, "incident", "Incident +2x"));
            ms.Add(new Moment(200, "passed", "Passed (lap 3)")); ms.Add(new Moment(45, "pass", "Pass (lap 1)"));
            List<HlSeg> p = Highlights.Plan(37, ms, 400, 494, 1200, 1230);
            List<string> kinds = new List<string>(); double total = 0;
            foreach (HlSeg s in p) { kinds.Add(s.Kind + "@" + s.From.ToString("0", Inv)); total += s.Len; }
            Console.WriteLine("  plan: " + string.Join(" ", kinds.ToArray()) + " = " + total.ToString("0.0", Inv) + " s");
            Ok("5. the order: start, the passes and incidents in time order, the best lap, the last lap",
                string.Join(" ", kinds.ToArray()) == "start@37 pass@114 passed@194 pass@294 best@464 last@1175", string.Join(" ", kinds.ToArray()));
            Ok("5. a pass inside the start is in the start already (not twice)", !kinds.Contains("pass@39"));
            Ok("5. a pass and an incident 2 s apart are one cut", p[3].From == 294 && p[3].To == 306, p[3].From + "-" + p[3].To);
            Ok("5. at most 3 minutes", total <= 180, total.ToString(Inv));
            List<Moment> many = new List<Moment>();
            for (int i = 0; i < 40; i++) many.Add(new Moment(100 + i * 25, i % 3 == 0 ? "incident" : i % 3 == 1 ? "passed" : "pass", "m" + i));
            List<HlSeg> q = Highlights.Plan(37, many, 1200, 1294, 1500, 1530);
            double qt = 0; int qp = 0, qi = 0; foreach (HlSeg s in q) { qt += s.Len; if (s.Kind == "pass") qp++; if (s.Kind == "incident" || s.Kind == "passed") qi++; }
            Ok("5. 40 moments: still at most 3 minutes, with the spare second a cut can grow", qt + q.Count <= 180 + 1, (qt + q.Count).ToString(Inv));
            Ok("5. his passes go in first: 13 passes are more than 3 minutes hold, so no pass against him and no incident gets in", qp >= 6 && qi == 0, qp + " passes, " + qi + " others");
            Ok("5. the best lap that is the last lap is not shown twice", Highlights.Plan(37, null, 1170, 1200, 1200, 1230).FindAll(delegate (HlSeg s) { return s.Kind == "best"; }).Count == 0);
            List<Chapter> ch = Highlights.ChaptersOf(p);
            Ok("5. the highlights' own chapters start at 0:00 Start", ch.Count >= 3 && ch[0].Sec == 0 && ch[0].Label == "Start", ch.Count.ToString(Inv));

            // a real join of the fixture clip: three cuts, hard, stream copy
            List<HlSeg> real = new List<HlSeg>();
            foreach (double[] x in new double[][] { new double[] { 0, 2 }, new double[] { 4, 6 }, new double[] { 7, 10 } })
            { HlSeg s = new HlSeg(); s.From = x[0]; s.To = x[1]; s.Kind = "k"; s.Label = "l"; real.Add(s); }
            string outp = Path.Combine(tmp, "race-1.highlights.mp4"); double sec;
            DateTime t0 = DateTime.UtcNow;
            string res = Highlights.Run(ffmpeg, ffprobe, clip, real, outp, out sec);
            double took = (DateTime.UtcNow - t0).TotalSeconds;
            Console.WriteLine("  highlights: " + sec.ToString("0.0", Inv) + " s long, joined in " + took.ToString("0.0", Inv) + " s");
            Ok("5. the fixture's three cuts are joined into one file", res == "ok" && File.Exists(outp), res);
            Ok("5. its length is the cuts' (7 s, keyframes of 1 s: within 2 s)", Math.Abs(sec - 7) <= 2, sec.ToString(Inv));
            Ok("5. stream copy: done in seconds (" + took.ToString("0.0", Inv) + " s)", took < 30);
            Ok("5. no cut or list left over", !Directory.Exists(outp + ".parts") && !File.Exists(Path.Combine(tmp, "race-1.highlights.part.mp4")));
            Highlights.Ffprobe = delegate (string args, int msx) { return "241.0\n"; };
            Ok("5. a join that came out over 3 minutes is not kept", Highlights.Run(ffmpeg, ffprobe, clip, real, Path.Combine(tmp, "long.highlights.mp4"), out sec).Contains("not kept") && !File.Exists(Path.Combine(tmp, "long.highlights.mp4")));
            Highlights.Ffprobe = null;
        }

        // ---------------- 6 ----------------
        static void Model(string tmp)
        {
            Facts f = F("Toyota GR86", "Road Atlanta", 15, 4, 24); f.BestLap = "1:34.850";
            Draft d = new Draft(Cuts.StoryTitle(f), Cuts.About(f));
            int calls = 0; string body = "";
            Words.Ask = delegate (string b) { calls++; body = b; return ""; };
            Words.KeyFileOverride = Path.Combine(tmp, "yt", "claude-key.txt");
            Words.PromptFileOverride = Path.Combine(tmp, "youtube-words.md");
            Ok("6. off by default: no youtube_words in irdash.ini = templates", Words.Mode() == "templates");
            Draft r0 = Words.Improve(f, d);
            Ok("6. off: the templates stand and the API is never asked", r0.Source == "templates" && r0.Title == d.Title && calls == 0);
            File.WriteAllText(YouTube.IniFile, "youtube_words=claude\r\n");
            Ok("6. youtube_words=claude turns it on", Words.Mode() == "claude");
            Ok("6. on but no key file: the templates stand, nothing is asked", Words.Improve(f, d).Source == "templates" && calls == 0);
            Directory.CreateDirectory(Path.GetDirectoryName(Words.KeyFileOverride));
            const string Key = "sk-ant-test-NOT-A-REAL-KEY-7731";
            File.WriteAllText(Words.KeyFileOverride, Key);
            File.Copy(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(System.Reflection.Assembly.GetExecutingAssembly().Location)), "youtube-words.md"), Words.PromptFileOverride, true);
            string good = "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"{\\\"title\\\":\\\"From P15 to P4 at Road Atlanta in the Toyota GR86\\\",\\\"description\\\":\\\"I started P15 of 24 and finished P4.\\\\n\\\\nToyota GR86 at Road Atlanta, best lap 1:34.850.\\\"}\"}]}";
            Words.Ask = delegate (string b) { calls++; body = b; return good; };
            Draft r1 = Words.Improve(f, d);
            Ok("6. the stub path: a good answer is used", r1.Source == "claude" && r1.Title == "From P15 to P4 at Road Atlanta in the Toyota GR86", r1.Title);
            Ok("6. one call per race (asked again: the same answer, no second call)", Words.Improve(f, d).Title == r1.Title && calls == 1, calls.ToString(Inv));
            Ok("6. the request: claude-sonnet-5-5, at most 400 tokens, the fixed prompt, the facts", body.Contains("\"model\":\"claude-sonnet-5-5\"") && body.Contains("\"max_tokens\":400") && body.Contains("clickbait") && body.Contains("started: P15"));
            Ok("6. the key is never in the request body (it goes in a header)", !body.Contains(Key));
            Facts f2 = F("Toyota GR86", "Road Atlanta", 15, 5, 24); Draft d2 = new Draft(Cuts.StoryTitle(f2), Cuts.About(f2));
            Words.Ask = delegate (string b) { return good.Replace("P4", "P2"); };
            Ok("6. an answer with a number the facts do not carry (P2) is thrown away", Words.Improve(f2, d2).Source == "templates");
            Facts f3 = F("Toyota GR86", "Road Atlanta", 15, 6, 24); Draft d3 = new Draft(Cuts.StoryTitle(f3), Cuts.About(f3));
            Words.Ask = delegate (string b) { return good.Replace("P4", "P6").Replace("From P15", "INSANE comeback P15"); };
            Ok("6. clickbait ('insane', 'comeback') is thrown away", Words.Improve(f3, d3).Source == "templates");
            Facts f4 = F("Toyota GR86", "Road Atlanta", 15, 7, 24); Draft d4 = new Draft(Cuts.StoryTitle(f4), Cuts.About(f4));
            Words.Ask = delegate (string b) { throw new System.Net.WebException("no internet"); };
            Ok("6. no internet: the templates stand", Words.Improve(f4, d4).Source == "templates");
            Facts f5 = F("Toyota GR86", "Road Atlanta", 15, 8, 24); Draft d5 = new Draft(Cuts.StoryTitle(f5), Cuts.About(f5));
            Words.Ask = delegate (string b) { return "{\"stop_reason\":\"refusal\",\"content\":[]}"; };
            Ok("6. a refusal: the templates stand", Words.Improve(f5, d5).Source == "templates");
            Log.Flush(3000);
            string log = File.Exists(Log.FilePath) ? File.ReadAllText(Log.FilePath) : "";
            Ok("6. the key is never in the log", !log.Contains(Key) && !log.Contains("NOT-A-REAL"));
            Ok("6. the log says what happened in words", log.Contains("youtube words: the model rewrote") && log.Contains("the templates stay"));
            File.Delete(YouTube.IniFile);
            Words.Ask = null;
        }
    }
}
