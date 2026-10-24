using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using IRDash;

// tests\ailevel-test.ps1 compiles this with dash\src\ailevel.cs. The few irdash things ailevel.cs leans on are stubbed below.
namespace IRDash
{
    static class Program { public static string RootDir; }
    static class Watch { public static string IrdeckPath; }
    static class Log { public static void W(string s) { } }
    static class Json_ { public static string S(string s) { return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; } }
    static class KeyMsg { public static string Last = ""; public static string Set(string k, string t, string kd) { Last = t; return t; } }
}

static class AiLevelUnit
{
    static int bad = 0;
    static void Check(string what, bool ok) { Console.WriteLine((ok ? "ok    " : "FAIL  ") + what); if (!ok) bad++; }

    static string File_() { return Path.Combine(Program.RootDir, @"ai\level.json"); }
    static string Saved() { return File.Exists(File_()) ? File.ReadAllText(File_()) : ""; }

    static void Main()
    {
        Program.RootDir = Path.Combine(Path.GetTempPath(), "ailevel-unit-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        Directory.CreateDirectory(Program.RootDir);
        try { Run(); } finally { try { Directory.Delete(Program.RootDir, true); } catch { } }
        Console.WriteLine(bad == 0 ? "UNIT-DONE" : "UNIT-FAILED");
    }

    static string Json() { return AiLevel.Json(); }

    static void Run()
    {
        Check("it handles the ailevel command and nothing else", AiLevel.Handles("ailevel") && !AiLevel.Handles("sndvol") && !AiLevel.Handles(null));
        string j = Json();
        Check("no file yet: adaptive, low (iRacing's own start-up setting), and 25 to 50 if you switch to a range", j.Contains("\"mode\":\"adaptive\"") && j.Contains("\"level\":\"low\"") && j.Contains("\"min\":25") && j.Contains("\"max\":50"));

        Check("HIGH is saved", AiLevel.Do("ailevel", "high") && Saved().Contains("\"level\":\"high\"") && Saved().Contains("\"mode\":\"adaptive\""));
        Check("the top screen is told", KeyMsg.Last.Contains("adaptive AI, high"));
        Check("LOW then MEDIUM", AiLevel.Do("ailevel", "low") && Saved().Contains("\"level\":\"low\"") && AiLevel.Do("ailevel", "medium") && Saved().Contains("\"level\":\"medium\""));
        Check("a word that is not a level is refused and changes nothing", !AiLevel.Do("ailevel", "extreme") && Saved().Contains("\"level\":\"medium\""));
        Check("a command injection through the argument is refused", !AiLevel.Do("ailevel", "low; del *") && !AiLevel.Do("ailevel", "") && !AiLevel.Do("ailevel", null));

        // range
        Check("RANGE switches the mode", AiLevel.Do("ailevel", "range") && Saved().Contains("\"mode\":\"range\""));
        string before = Saved();
        Check("MIN + steps by " + AiLevel.RangeStep, AiLevel.Do("ailevel", "min+") && Regex.IsMatch(Saved(), "\"min\":" + (25 + AiLevel.RangeStep)));
        Check("MAX - steps down", AiLevel.Do("ailevel", "max-") && Regex.IsMatch(Saved(), "\"max\":" + (50 - AiLevel.RangeStep)));
        for (int i = 0; i < 40; i++) AiLevel.Do("ailevel", "min+");
        Match m = Regex.Match(Saved(), "\"min\":(\\d+),\"max\":(\\d+)");
        int mn = int.Parse(m.Groups[1].Value), mx = int.Parse(m.Groups[2].Value);
        Check("MIN can never pass MAX (they stay " + AiLevel.RangeMinGap + " apart) (" + mn + " / " + mx + ")", mx - mn >= AiLevel.RangeMinGap && mx <= AiLevel.RangeHi);
        for (int i = 0; i < 60; i++) AiLevel.Do("ailevel", "max-");
        m = Regex.Match(Saved(), "\"min\":(\\d+),\"max\":(\\d+)");
        mn = int.Parse(m.Groups[1].Value); mx = int.Parse(m.Groups[2].Value);
        Check("MAX pushes MIN down, and nothing goes below the floor (" + mn + " / " + mx + ")", mn >= AiLevel.RangeLo && mx - mn >= AiLevel.RangeMinGap);
        for (int i = 0; i < 60; i++) AiLevel.Do("ailevel", "max+");
        m = Regex.Match(Saved(), "\"min\":(\\d+),\"max\":(\\d+)");
        Check("MAX stops at the top of the scale (" + m.Groups[2].Value + ")", int.Parse(m.Groups[2].Value) == AiLevel.RangeHi);
        Check("a level key switches back to adaptive", AiLevel.Do("ailevel", "high") && Saved().Contains("\"mode\":\"adaptive\""));

        // a damaged file never breaks the screen
        File.WriteAllText(File_(), "{\"mode\":\"range\",\"level\":\"pro\",\"min\":9,\"max\":900}");
        j = Json();
        Check("a file with nonsense values comes back inside the limits", j.Contains("\"mode\":\"range\"") && j.Contains("\"level\":\"low\"") && Regex.IsMatch(j, "\"min\":\\d+") && j.Contains("\"max\":" + AiLevel.RangeHi));
        File.WriteAllText(File_(), "not json at all");
        Check("a file that is not JSON gives the defaults", Json().Contains("\"mode\":\"adaptive\""));

        // the key list
        AiLevel.Do("ailevel", "medium");
        j = Json();
        MatchCollection regs = Regex.Matches(j, "\\{\"c\":(\\d+),\"r\":(\\d+),\"w\":(\\d+),\"h\":(\\d+),\"text\":\"((?:[^\"\\\\]|\\\\.)*)\",\"sub\":\"((?:[^\"\\\\]|\\\\.)*)\",\"act\":(null|\"[a-z]+\"),\"arg\":(null|\"[a-z+-]+\"),\"style\":\"([a-z]*)\",\"wrap\":(\\d+)\\}");
        Check("the key list parses (" + regs.Count + " keys)", regs.Count >= 14 && j.Contains("\"ready\":true"));
        bool inside = true, one = true; HashSet<string> cells = new HashSet<string>(); bool dup = false;
        List<string> acts = new List<string>();
        foreach (Match r in regs)
        {
            int c = int.Parse(r.Groups[1].Value), rw = int.Parse(r.Groups[2].Value), w = int.Parse(r.Groups[3].Value), h = int.Parse(r.Groups[4].Value);
            if (c < 0 || rw < 0 || c + w > 8 || rw + h > 4) inside = false;
            if (w != 1 || h != 1) one = false;
            for (int x = c; x < c + w; x++) for (int y = rw; y < rw + h; y++) if (!cells.Add(x + "," + y)) dup = true;
            if (r.Groups[7].Value != "null") acts.Add(r.Groups[7].Value.Trim('"') + ":" + r.Groups[8].Value.Trim('"'));
        }
        Check("every key is inside the 8 x 4 deck and no two share a cell", inside && !dup);
        Check("every label sits on ONE key (the bezels cut through text across two keys)", one);
        Check("it has EXIT and START", acts.Contains("exit:null") && acts.Contains("ailevel:start"));
        bool allValid = true;
        foreach (string a in acts) { if (a.StartsWith("ailevel:")) { string arg = a.Substring(8); File.Delete(File_()); if (arg != "start" && !AiLevel.Do("ailevel", arg)) allValid = false; } }
        Check("every key the screen offers is accepted by Do", allValid);
        AiLevel.Do("ailevel", "high");
        j = Json();
        Check("the chosen level is lit (sel) and only that one", Regex.Matches(j, "\"text\":\"HIGH\",[^}]*\"style\":\"sel\"").Count == 1 && Regex.Matches(j, "\"text\":\"(LOW|MEDIUM)\",[^}]*\"style\":\"sel\"").Count == 0);
        Check("START without irdeck.exe known says no rather than pretending", !AiLevel.Do("ailevel", "start"));
    }
}
