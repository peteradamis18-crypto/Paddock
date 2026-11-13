// perf-verdict-driver.cs - compiled together with every irdash source by tests\perf-verdict-test.ps1 (/main picks this Main), so the
// real code runs: the cause rules, the freeze sentence, the place on the lap, the 12 Nov verdict, "still being processed", the fps cap,
// the session start time and the perf.tsv row format. Prints "ok ..." / "FAIL ..." lines and SENTENCE / VERDICT lines. Args: <ibt or ->
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

namespace IRDash
{
    static class VerdictDriver
    {
        static int pass, fail;
        static void Ok(string what, bool cond, string why)
        {
            if (cond) { pass++; Console.WriteLine("  ok   " + what); }
            else { fail++; Console.WriteLine("  FAIL " + what + " " + (why ?? "")); }
        }

        static BbDip Dip(double gpu, double cpu, double pf) { BbDip d = new BbDip(); d.Gpu = gpu; d.Cpu = cpu; d.PageFaults = pf; return d; }

        static int Main(string[] a)
        {
            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
            CultureInfo inv = CultureInfo.InvariantCulture;

            // ---- the cause rules, one case each ----
            string c;
            c = BlackBox.Cause(Dip(0.98, 0.50, 5));
            Ok("cause: graphics card at 95 %+ with the processor not -> \"the graphics card\" (" + c + ")", c.StartsWith("the graphics card", StringComparison.Ordinal), c);
            BbDip p = Dip(0.45, 0.32, 5); p.Programs.Add("Coach Dave Delta"); p.Now.Add(39); p.Usual.Add(13); p.Programs.Add("SimHub"); p.Now.Add(15); p.Usual.Add(15);
            c = BlackBox.Cause(p);
            Ok("cause: one program at 3x its own session average -> that program (" + c + ")", c == "Coach Dave Delta (3× its usual CPU)", c);
            BbDip q = Dip(0.45, 0.32, 5); q.Paddock.Add("clip cut start lap 9");
            c = BlackBox.Cause(q);
            Ok("cause: a cut in the 3 s before -> Paddock (what) (" + c + ")", c == "Paddock (clip cut start lap 9)", c);
            c = BlackBox.Cause(Dip(0.45, 0.32, 1500));
            Ok("cause: page faults over 1000/s -> memory (" + c + ")", c.StartsWith("memory", StringComparison.Ordinal), c);
            c = BlackBox.Cause(Dip(0.45, 0.32, 5));
            Ok("cause: nothing unusual -> inside the sim (" + c + ")", c == "inside the sim (likely a graphics hitch)", c);
            c = BlackBox.Cause(Dip(3.17, 3.09, 8));
            Ok("cause: a stalled frame (12 Nov: GPU 317 % and CPU 309 % together) is not blamed on the graphics card (" + c + ")", c == "inside the sim (likely a graphics hitch)", c);
            c = BlackBox.Cause(Dip(1.5, 1.1, 8));
            Ok("cause: GPU 150 % with CPU 110 % is a stalled frame, not the graphics card (" + c + ")", c == "inside the sim (likely a graphics hitch)", c);
            // read back from a file: a busy card in the normal driving before, a stall with a quiet card inside the freeze
            string tmpf = Path.Combine(Path.GetTempPath(), "bb-driver-" + Process.GetCurrentProcess().Id + ".tsv");
            Func<double, double, double, double, string> row = delegate (double t, double fps, double gpu, double cpu)
            { return t.ToString("0.000", inv) + "\t100\t5\t0.5000\t40\t" + fps.ToString("0.0", inv) + "\t" + cpu.ToString("0.000", inv) + "\t0.1\t" + gpu.ToString("0.000", inv) + "\t5\t20\tSimHub\t15\t\t\t\t\t0\t1\t\t\t\t\t"; };
            Func<double, double, string> both = delegate (double fg, double fc)
            {
                StringBuilder sb = new StringBuilder(BlackBox.Header + "\r\n" + BlackBox.SnapHeader + "\r\n");
                for (int i = 0; i < 30; i++) sb.Append(row(1000 + i, 110, 0.98, 0.5)).Append("\r\n");             // normal driving, card at 98 %
                for (int i = 0; i < 4; i++) sb.Append(row(1030 + i, 30, fg, fc)).Append("\r\n");                 // the freeze
                for (int i = 0; i < 10; i++) sb.Append(row(1034 + i, 110, 0.6, 0.4)).Append("\r\n");
                File.WriteAllText(tmpf, sb.ToString());
                List<BbFreeze> fz = BlackBox.Freezes(tmpf);
                return fz.Count == 1 ? fz[0].Cause : "freezes: " + fz.Count;
            };
            c = both(0.5, 0.4);
            Ok("a low-GPU stall after normal rows with a busy card is not blamed on the card (" + c + ")", c == "inside the sim (likely a graphics hitch)", c);
            c = both(0.99, 0.5);
            Ok("a freeze with the card at 99 % and the processor at 50 % inside it is the graphics card (" + c + ")", c.StartsWith("the graphics card", StringComparison.Ordinal), c);
            try { File.Delete(tmpf); } catch { }
            BbDip small = Dip(0.45, 0.32, 5); small.Programs.Add("Spotify"); small.Now.Add(3); small.Usual.Add(0.6);
            Ok("cause: a program at 5x of almost nothing (3 % of a core) is not a cause", BlackBox.Cause(small) == "inside the sim (likely a graphics hitch)", BlackBox.Cause(small));

            // ---- the sentence and the place ----
            string s = BlackBox.Sentence(9, "start/finish", 4.2, 23.7, "09:46:00", "Coach Dave Delta (3× its usual CPU)");
            Ok("sentence in Peter's words: " + s, s == "Lap 9, start/finish: the picture froze for 4 s (worst second 23.7 fps, at 09:46:00). Likely cause: Coach Dave Delta (3× its usual CPU).", s);
            Ok("place: 0.993 of the lap is start/finish", BlackBox.Place(0.993, null, null, null) == "start/finish", BlackBox.Place(0.993, null, null, null));
            double[] p0 = { 0.10, 0.45 }, p1 = { 0.15, 0.55 }; string[] nm = { "Turn 1", "The Esses" };
            Ok("place: inside a named corner gives its name", BlackBox.Place(0.50, p0, p1, nm) == "The Esses", BlackBox.Place(0.50, p0, p1, nm));
            Ok("place: just before a corner says so", BlackBox.Place(0.42, p0, p1, nm) == "before The Esses", BlackBox.Place(0.42, p0, p1, nm));
            Ok("place: no corner list gives the share of the lap", BlackBox.Place(0.5, null, null, null) == "50 % round the lap", BlackBox.Place(0.5, null, null, null));

            // ---- the fps cap from the sim's own setting ----
            string ini = "[Display]\r\nDesiredFPSLimit=60\r\n[Graphics Options]\r\nLimitFrameRate=1          ; limit frame rate\r\nDesiredFPSLimit=160        ; frames per second\r\nNvReflexMode=0\r\n[Other]\r\nLimitFrameRate=0\r\n";
            Dictionary<string, string> g = SimSettings.ParseGraphics(ini);
            Ok("fps cap read from a sample rendererDX11 ini: 160 (the [Graphics Options] value, comment stripped)", SimSettings.FpsCap(g) == 160, SimSettings.FpsCap(g).ToString(inv));
            Ok("fps cap: LimitFrameRate=0 means no cap (0)", SimSettings.FpsCap(SimSettings.ParseGraphics("[Graphics Options]\nLimitFrameRate=0\nDesiredFPSLimit=160\n")) == 0, "");
            Ok("fps cap: no graphics section means unknown (0)", SimSettings.FpsCap(SimSettings.ParseGraphics("[Display]\nLimitFrameRate=1\n")) == 0, "");

            // ---- the limit a session had (not today's) ----
            Func<string, double> backups = delegate (string n) { return n == "rendererDX11Monitor-20261020-1200.ini" ? 120 : 0; };
            List<PerfChange> chg = new List<PerfChange>();
            Ok("limit: no graphics change known -> today's limit", PerfChanges.LimitFrom(chg, 1000, 160, backups) == 160, "");
            PerfChange g1 = new PerfChange(); g1.Id = "gfx:rendererDX11Monitor-20261020-1200.ini"; g1.Kind = "graphics"; g1.Ts = 2000; chg.Add(g1);
            Ok("limit: a session after the last graphics change -> today's limit", PerfChanges.LimitFrom(chg, 2500, 160, backups) == 160, "");
            Ok("limit: a session before a gfx-set change -> the limit in that change's backup (120)", PerfChanges.LimitFrom(chg, 1500, 160, backups) == 120, PerfChanges.LimitFrom(chg, 1500, 160, backups).ToString(inv));
            PerfChange g0 = new PerfChange(); g0.Id = "gfxapp:1800"; g0.Kind = "graphics"; g0.Ts = 1800; chg.Add(g0);
            Ok("limit: a session before a change made inside iRacing (no backup) -> unknown (0)", PerfChanges.LimitFrom(chg, 1500, 160, backups) == 0, "");
            PerfChange other = new PerfChange(); other.Id = "build:1"; other.Kind = "iracing"; other.Ts = 9000; chg.Add(other);
            Ok("limit: other kinds of change do not count", PerfChanges.LimitFrom(chg, 2500, 160, backups) == 160, "");

            // ---- the session start ----
            DateTime lw = new DateTime(2026, 11, 13, 8, 0, 0, DateTimeKind.Utc);
            Ok("start: the header time first", PerfReport.StartOf("x 2026-11-12 09-28-07.ibt", 1794493687L, lw) == 1794493687L, "");
            long fromName = PerfReport.StartOf("toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt", 0, lw);
            Ok("start: a bad header falls back to the time in the file name (12 Nov 09:28:07 local)", PerfText.When(fromName) == "12 Nov 09:28", PerfText.When(fromName));
            Ok("start: neither gives the last write, never the creation time", PerfReport.StartOf("odd.ibt", 0, lw) == Perf.ToUnix(lw), "");

            // ---- perf.tsv rows: v2 round trip, v1 rows still read ----
            PerfRow r2 = new PerfRow(); r2.File = "a.ibt"; r2.Size = 5; r2.Start = 1794493687; r2.Avg = 114; r2.Secs = 1180; r2.Worst = 23.7; r2.FrzLap = 9; r2.FrzPct = 0.993; r2.FrzAt = 1794494760; r2.FrzLen = 3.8; r2.Limit = 160; r2.Track = "Road Atlanta";
            PerfRow back = PerfRow.Parse(r2.ToLine());
            Ok("perf.tsv v2 row keeps the freeze (lap, place, time, length) and the limit", back != null && back.FrzLap == 9 && Math.Abs(back.FrzPct - 0.993) < 1e-6 && back.FrzAt == 1794494760 && Math.Abs(back.FrzLen - 3.8) < 1e-6 && back.Limit == 160 && back.V == 2, back == null ? "null" : back.ToLine());
            string v1 = string.Join("\t", new string[] { "b.ibt", "9", "1794493687", "100", "90", "T", "", "k", "t", "car", "Race", "1", "0", "1", "1", "114", "92", "23.7", "130", "5", "2", "30", "40", "45", "60", "-1", "-1", "close", "-1", "-1", "-1", "-1", "-1", "-1", "", "1794493700", "1" });
            PerfRow old = PerfRow.Parse(v1);
            Ok("a v1 row (37 columns) still reads, with no freeze and version 1 (so it is done again once)", old != null && old.V == 1 && old.FrzLen == 0 && old.FrzLap == -1, old == null ? "null" : "");
            string l1 = PerfText.LastLine(old);
            Ok("a v1 report never says \"No freezes\" (it never looked): " + l1, !l1.Contains("No freezes") && l1.Contains("not checked for freezes"), l1);

            // ---- "still being processed" ----
            PerfRow ra = new PerfRow(); ra.File = "older 2026-11-12 09-28-07.ibt"; ra.Size = 100; ra.Start = 1794493687; ra.Secs = 1180; ra.Avg = 114; ra.Track = "Road Atlanta";
            List<PerfRow> rows = new List<PerfRow>(); rows.Add(ra);
            PerfFile fa = new PerfFile(); fa.Name = ra.File; fa.Size = 100; fa.Start = 1794493687;
            PerfFile fb = new PerfFile(); fb.Name = "newer 2026-11-12 16-57-00.ibt"; fb.Size = 200; fb.Start = 1794520620;
            string pend;
            PerfRow got = Perf.LastSession(rows, new List<PerfFile> { fa, fb }, false, out pend);
            Ok("the newest file has no report yet: \"still being processed\", never the older file (" + pend + ")", got == null && pend != null && pend.Contains("still being processed") && pend.Contains("12 Nov 16:57"), pend);
            got = Perf.LastSession(rows, new List<PerfFile> { fa, fb }, true, out pend);
            Ok("while the sim is open it says the report comes once the sim is closed", got == null && pend != null && pend.Contains("once the sim is closed"), pend);
            PerfRow rb = new PerfRow(); rb.File = fb.Name; rb.Size = 200; rb.Start = fb.Start; rb.Secs = 0;
            rows.Add(rb);
            got = Perf.LastSession(rows, new List<PerfFile> { fa, fb }, false, out pend);
            Ok("a newer file with no driving in it (a replay) is passed over: the race is the last session", got == ra && pend == null, pend);
            fb.Size = 300;
            got = Perf.LastSession(rows, new List<PerfFile> { fa, fb }, false, out pend);
            Ok("a report of another size (the file grew) counts as not processed", got == null && pend != null, pend);
            got = Perf.LastSession(new List<PerfRow> { ra }, new List<PerfFile> { fa }, false, out pend);
            Ok("the newest file has its report: that session", got == ra && pend == null, pend);

            // ---- the 12 Nov race ----
            if (a.Length > 0 && a[0] != "-" && File.Exists(a[0]))
            {
                Stopwatch sw = Stopwatch.StartNew();
                PerfRow r = PerfReport.Compute(a[0], 160);
                Console.WriteLine("READ " + Path.GetFileName(a[0]) + " in " + sw.ElapsedMilliseconds + " ms");
                Ok("12 Nov: the worst second is 23.7 fps", r.Worst.ToString("0.0", inv) == "23.7", r.Worst.ToString(inv));
                Ok("12 Nov: the worst second is under half the average, so it is a freeze (avg " + r.Avg.ToString("0.0", inv) + ")", r.FrzLen > 0 && r.Worst < r.Avg * 0.5, "");
                Ok("12 Nov: the freeze starts on lap 9 at the line (lap " + r.FrzLap + ", " + r.FrzPct.ToString("0.000", inv) + " of the lap)", r.FrzLap == 9 && (r.FrzPct >= 0.97 || r.FrzPct <= 0.03), "");
                Ok("12 Nov: it lasts about 4 s (" + r.FrzLen.ToString("0.0", inv) + " s)", r.FrzLen >= 3 && r.FrzLen <= 6, "");
                string clock = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(r.FrzAt).ToLocalTime().ToString("HH:mm:ss", inv);
                Ok("12 Nov: at about 09:46 (" + clock + ")", clock.StartsWith("09:45:5", StringComparison.Ordinal) || clock.StartsWith("09:46:0", StringComparison.Ordinal), clock);
                Ok("12 Nov: the limit is the sim's own 160, and the race did not hold it", r.Limit == 160 && r.Verdict != "held", r.Verdict);
                string line = PerfText.LastLine(r), verdict = PerfText.Verdict(r);
                Console.WriteLine("SENTENCE " + line);
                Console.WriteLine("VERDICT " + verdict);
                Ok("12 Nov sentence names the track and the date", line.StartsWith("Road Atlanta, 12 Nov 09:28.", StringComparison.Ordinal), line);
                Ok("12 Nov sentence names lap 9, start/finish and 23.7 fps", line.Contains("Lap 9, start/finish") && line.Contains("23.7 fps"), line);
                Ok("12 Nov Performance verdict leads with the freeze", verdict.StartsWith("Lap 9, start/finish: the picture froze for", StringComparison.Ordinal), verdict);
            }
            else Console.WriteLine("  skip the 12 Nov file: not given");

            Console.WriteLine("DRIVER " + pass + " ok, " + fail + " FAIL");
            return fail > 0 ? 1 : 0;
        }
    }
}
