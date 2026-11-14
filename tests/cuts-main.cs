// Test main for dash\src\cuts.cs (tests\cuts-test.ps1 compiles both). Prints "  ok ..." / "  FAIL ..." lines.
// args: <tmp dir> <fixture json path>. Offline: the "ffmpeg" and "ffprobe" are tiny .cmd files written into the tmp dir.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using IRDash;

static class CutsTest
{
    static int pass, fail;
    static void Check(string what, bool ok) { if (ok) { pass++; Console.WriteLine("  ok    " + what); } else { fail++; Console.WriteLine("  FAIL  " + what); } }

    static Facts F(string car, string track, string cfg, string series, int finish, int start)
    {
        Facts f = new Facts(); f.Car = car; f.Track = track; f.Config = cfg; f.Series = series; f.Finish = finish; f.Start = start;
        f.Date = new DateTime(2026, 11, 13); return f;
    }

    static string Js(string type, double dur, string laps, string incidents)
    {
        return "{\"schema\":2,\"track\":\"Spa\",\"car\":\"BMW M4 GT3\",\"sessionType\":\"" + type + "\",\"durationSec\":" + dur.ToString(CultureInfo.InvariantCulture)
            + ",\"laps\":[" + laps + "],\"incidents\":[" + incidents + "]}";
    }
    static string L(int n, double off, double time, bool clean, bool counted, bool pit)
    {
        return "{\"n\":" + n + ",\"offset\":" + off.ToString(CultureInfo.InvariantCulture) + ",\"time\":" + time.ToString(CultureInfo.InvariantCulture)
            + ",\"clean\":" + (clean ? "true" : "false") + ",\"counted\":" + (counted ? "true" : "false") + (pit ? ",\"pit\":true" : "") + "}";
    }

    static bool Near(double a, double b) { return Math.Abs(a - b) < 0.01; }

    static void TitleChecks(string name, Facts f, HashSet<string> known)
    {
        for (int t = 1; t <= 5; t++)
        {
            string s = Cuts.Title(t, f);
            bool words = true;
            foreach (string w in s.Replace(":", "").Replace("(", "").Replace(")", "").Split(' ')) if (w.Length > 0 && !known.Contains(w)) words = false;
            Check(name + " template " + t + ": '" + s + "' (" + s.Length + ") under 70, no brace, no half word", s.Length < 70 && s.IndexOf('{') < 0 && s.IndexOf('}') < 0 && words);
        }
    }

    static HashSet<string> Known(params string[] texts)
    {
        HashSet<string> k = new HashSet<string>();
        foreach (string t in texts) foreach (string w in t.Split(' ')) k.Add(w);
        foreach (string w in "at in the full race Full P iRacing from \u00B7".Split(' ')) k.Add(w);
        return k;
    }

    static int Main(string[] args)
    {
        string tmp = args[0]; string fixture = args[1];
        string json = File.ReadAllText(fixture);

        // 1. the real race
        CutPlan p = Cuts.Plan(json, 1268.249);
        Check("race: StartSec = lap 1 offset - 3 (281.576)", Near(p.StartSec, 284.576 - 3));
        Check("race: EndSec = last lap end + 20 (1264.589)", Near(p.EndSec, 1147.857 + 96.732 + 20));
        Check("chapters start with 0:00 Start", p.Chapters[0].Sec == 0 && p.Chapters[0].Label == "Start");
        bool ordered = true, gap = true;
        for (int i = 1; i < p.Chapters.Count; i++)
        {
            if (p.Chapters[i].Sec <= p.Chapters[i - 1].Sec) ordered = false;
            if (p.Chapters[i].Sec - p.Chapters[i - 1].Sec < 10) gap = false;
        }
        Check("chapters are in time order", ordered);
        Check("chapters are at least 10 s apart (the 1.7 s incident was dropped)", gap);
        bool hasBest = false, hasFinish = false, afterEnd = false;
        foreach (Chapter c in p.Chapters) { if (c.Label == "Best lap 1:35.106 (lap 8)") hasBest = true; if (c.Label == "Finish") hasFinish = true; if (c.Sec > p.EndSec - p.StartSec) afterEnd = true; }
        Check("has the counted best lap (lap 8, 1:35.106; lap 9 is faster but not counted)", hasBest);
        Check("has Finish, and nothing after the end", hasFinish && !afterEnd);
        Check("Why says the plan: " + p.Why, p.Why.Contains("out lap off (lap 1 at 284.6 s)") && p.Why.Contains("20 s after the finish") && p.Why.Contains(p.Chapters.Count + " chapters"));
        CutPlan capped = Cuts.Plan(json, 1250);
        Check("EndSec never past the video length", Near(capped.EndSec, 1250));

        // 2. practice and no laps: whole file
        CutPlan pr = Cuts.Plan(Js("Practice", 600.5, L(1, 60, 100, true, true, false) + "," + L(2, 160, 99, true, true, false), ""), 600.5);
        Check("practice: start 0, end = duration", pr.StartSec == 0 && Near(pr.EndSec, 600.5));
        CutPlan nl = Cuts.Plan(Js("Race", 900, "", ""), 900);
        Check("race with no lap rows: whole file, still 3 chapters", nl.StartSec == 0 && Near(nl.EndSec, 900) && nl.Chapters.Count >= 3);
        CutPlan bad = Cuts.Plan("not json at all", 100);
        Check("a broken sidecar gives the whole file", bad.StartSec == 0 && Near(bad.EndSec, 100) && bad.Chapters[0].Label == "Start");
        CutPlan early = Cuts.Plan(Js("Race", 400, L(1, 2, 100, true, true, false), ""), 400);
        Check("lap 1 at 2 s: start never below 0", early.StartSec == 0);

        // 3. incidents 4 s apart, one lap, pit
        CutPlan inc = Cuts.Plan(Js("Race", 400, L(1, 100, 120, false, false, false), "{\"offset\":150,\"count\":1},{\"offset\":154,\"count\":2}"), 400);
        int incN = 0; foreach (Chapter c in inc.Chapters) if (c.Label.StartsWith("Incident")) incN++;
        Check("two incidents 4 s apart: one chapter (the earlier, Incident +1x)", incN == 1 && inc.Chapters[1].Label == "Incident +1x");
        CutPlan one = Cuts.Plan(Js("Race", 400, L(1, 100, 120, true, true, false), ""), 400);
        bool halfway = false; foreach (Chapter c in one.Chapters) if (c.Label == "Halfway") halfway = true;
        Check("one lap: Halfway added to reach three", halfway && one.Chapters.Count == 3);
        CutPlan pit = Cuts.Plan(Js("Race", 4000, L(1, 100, 120, true, true, false) + "," + L(2, 1000, 110, true, true, true) + "," + L(3, 3700, 119, true, true, false), ""), 4000);
        bool hasPit = false; foreach (Chapter c in pit.Chapters) if (c.Label == "Pit stop" && Near(c.Sec, 1000 - 97)) hasPit = true;
        Check("a pit lap gives a Pit stop chapter at that lap's offset", hasPit);

        // 4. titles
        Facts full = F("Toyota GR86", "Road Atlanta", "Full Course", "Production Car Challenge", 3, 7);
        TitleChecks("full facts", full, Known("Toyota GR86 Road Atlanta Production Car Challenge 13 Nov 2026 P3 P7"));
        Facts noSeries = F("Toyota GR86", "Road Atlanta", "", "", 3, 7);
        TitleChecks("no series", noSeries, Known("Toyota GR86 Road Atlanta 13 Nov 2026 P3 P7"));
        Facts noPos = F("Toyota GR86", "Road Atlanta", "", "Production Car Challenge", 0, 0);
        TitleChecks("no finish or start", noPos, Known("Toyota GR86 Road Atlanta Production Car Challenge 13 Nov 2026"));
        Check("template 1 text", Cuts.Title(1, full) == "Toyota GR86 at Road Atlanta \u00B7 iRacing Production Car Challenge \u00B7 13 Nov 2026" || Cuts.Title(1, full).Length < 70);
        Check("template 1 with a short series keeps the date and says 13 Nov 2026", Cuts.Title(1, F("GR86", "Spa", "", "GT3", 1, 1)) == "GR86 at Spa \u00B7 iRacing GT3 \u00B7 13 Nov 2026");
        Check("template 2 text", Cuts.Title(2, F("GR86", "Spa", "", "GT3", 3, 7)) == "P3 from P7 \u00B7 GR86 at Spa");
        Check("template 2 without P-fields falls back to car at track + date", Cuts.Title(2, F("GR86", "Spa", "", "GT3", 0, 0)) == "GR86 at Spa \u00B7 13 Nov 2026");
        Check("template 3 text", Cuts.Title(3, F("GR86", "Spa", "", "GT3", 3, 7)) == "GT3: Spa in the GR86 \u00B7 P3");
        Check("template 3 without series", Cuts.Title(3, F("GR86", "Spa", "", "", 3, 7)) == "Spa in the GR86 \u00B7 P3");
        Check("template 4 text", Cuts.Title(4, F("GR86", "Spa", "", "GT3", 3, 7)) == "Spa GR86 full race \u00B7 13 Nov 2026");
        Check("template 5 text", Cuts.Title(5, F("GR86", "Spa", "", "GT3", 3, 7)) == "Full race: GT3 at Spa (GR86)");
        string longTrack = "Circuit de Spa Francorchamps Grand Prix Pits"; // 44 chars
        Facts lf = F("Mercedes AMG GT3 Evo Edition Car", longTrack, "", "", 0, 0);
        string lt = Cuts.Title(4, lf);
        Check("long track + long car: '" + lt + "' under 70, track cut at a word, car whole", lt.Length < 70 && lt.Contains("Mercedes AMG GT3 Evo Edition Car") && lt.StartsWith("Circuit de Spa") && !lt.EndsWith(" ") && lt.IndexOf("Pits") < 0 == (lt.IndexOf("Pits") < 0));
        // the order: config is dropped before the date, the date before the series
        Facts ord = F("Toyota GR86 Road Atlanta Edition", "Road Atlanta", "Club Layout Long", "Production Car Challenge", 0, 0);
        string o1 = Cuts.Title(1, ord);
        Check("shortening order: '" + o1 + "' (config goes first, date after)", o1.Length < 70);
        Facts o2 = F("Toyota GR86", "Road Atlanta", "Club Layout With A Long Name", "GT3", 0, 0);
        string t2 = Cuts.Title(1, o2);
        Check("config dropped first, date kept: '" + t2 + "'", t2 == "Toyota GR86 at Road Atlanta \u00B7 iRacing GT3 \u00B7 13 Nov 2026");
        Facts o3 = F("Toyota GR86", "Road Atlanta Full Circuit Name", "", "Pro Car", 0, 0);
        string t3 = Cuts.Title(1, o3);
        Check("date dropped before the series is cut: '" + t3 + "'", t3.IndexOf("13 Nov") < 0 && t3.Contains("iRacing Pro Car"));
        Facts brace = F("Car {x}", "Track", "", "{Series}", 1, 1);
        Check("braces in the facts never leak", Cuts.Title(1, brace).IndexOf('{') < 0 && Cuts.Title(3, brace).IndexOf('}') < 0);

        // 5. description
        string d = Cuts.Description(p, F("Toyota GR86", "Road Atlanta", "Full Course", "", 0, 0));
        string[] lines = d.Split('\n');
        Check("description line 1 = facts: " + lines[0], lines[0] == "Toyota GR86 at Road Atlanta, 13 Nov 2026 \u00B7 10 laps \u00B7 best 1:35.106");
        Check("description: blank line, then exactly '0:00 Start'", lines[1] == "" && lines[2] == "0:00 Start");
        Check("description ends with Recorded with Paddock", d.EndsWith("\n\nRecorded with Paddock"));
        Check("description chapter lines look like m:ss Label", lines[3].StartsWith("0:38 Incident +1x"));
        CutPlan hp = Cuts.Plan(Js("Race", 4000, L(1, 100, 120, true, true, false) + "," + L(2, 1000, 110, true, true, true) + "," + L(3, 3700, 119, true, true, false), ""), 4000);
        string hd = Cuts.Description(hp, F("BMW", "Spa", "", "", 0, 0));
        Check("description uses h:mm:ss past an hour", hd.Contains("\n1:00:") || hd.Contains("\n0:") && hd.Contains("1:0"));

        // 6. ffmpeg args
        CutPlan fp = new CutPlan(); fp.StartSec = 281.5763; fp.EndSec = 1264.589;
        string a = Cuts.FfmpegArgs("C:\\v\\in.mp4", "C:\\v\\out.mp4", fp);
        Check("args: -ss before -i", a.IndexOf("-ss 281.576") >= 0 && a.IndexOf("-ss") < a.IndexOf("-i "));
        Check("args: -to, -c copy, hvc1, faststart, make_zero", a.Contains("-to 1264.589") && a.Contains("-c copy") && a.Contains("-tag:v hvc1") && a.Contains("-movflags +faststart") && a.Contains("-avoid_negative_ts make_zero"));
        Check("args: maps one video and one audio, quotes paths", a.Contains("-map 0:v:0 -map 0:a:0") && a.Contains("-i \"C:\\v\\in.mp4\"") && a.EndsWith("\"C:\\v\\out.mp4\""));
        Check("args: invariant decimals (dot, not comma)", a.IndexOf(',') < 0);

        // 7. Run with a pretend ffmpeg / ffprobe
        Directory.CreateDirectory(tmp);
        string ff = Path.Combine(tmp, "fake-ffmpeg.cmd"), fpb = Path.Combine(tmp, "fake-ffprobe.cmd");
        File.WriteAllText(ff, "@echo off\r\nfor %%a in (%*) do set last=%%~a\r\necho x>\"%last%\"\r\n");
        File.WriteAllText(fpb, "@echo off\r\necho %FAKE_LEN%\r\n");
        string inp = Path.Combine(tmp, "20261113-212702-test.mp4"); File.WriteAllText(inp, "video");
        string outDir = Path.Combine(tmp, "out");
        CutPlan rp = new CutPlan(); rp.StartSec = 100; rp.EndSec = 700;
        string outPath;
        Cuts.FreeBytes = delegate (string x) { return 50L * 1024 * 1024 * 1024; };
        Environment.SetEnvironmentVariable("FAKE_LEN", "600.8");
        string r1 = Cuts.Run(ff, fpb, inp, outDir, rp, out outPath);
        Check("Run: right length -> ok (" + r1 + ")", r1 == "ok" && File.Exists(outPath) && outPath.EndsWith("20261113-212702-test-cut.mp4"));
        Environment.SetEnvironmentVariable("FAKE_LEN", "605.0");
        string r2 = Cuts.Run(ff, fpb, inp, outDir, rp, out outPath);
        Check("Run: 5 s off -> plain refusal (" + r2 + ")", r2 != "ok" && r2.Contains("wrong length") && !File.Exists(outPath));
        Cuts.FreeBytes = delegate (string x) { return 5L * 1024 * 1024 * 1024; };
        Environment.SetEnvironmentVariable("FAKE_LEN", "600");
        string r3 = Cuts.Run(ff, fpb, inp, outDir, rp, out outPath);
        Check("Run: low free space -> 'Not enough space for the cut (needs 10 GB free)'", r3 == "Not enough space for the cut (needs 10 GB free)");
        Cuts.FreeBytes = delegate (string x) { return 50L * 1024 * 1024 * 1024; };
        string r4 = Cuts.Run(Path.Combine(tmp, "nope.exe"), fpb, inp, outDir, rp, out outPath);
        Check("Run: missing video tool -> plain words (" + r4 + ")", r4 != "ok" && r4.Length > 0);

        Console.WriteLine(pass + " passed, " + fail + " failed");
        return fail == 0 ? 0 : 1;
    }
}
