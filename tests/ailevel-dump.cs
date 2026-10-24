using System;
using System.IO;
using IRDash;

// tests\ailevel-screen-test.ps1 compiles this with dash\src\ailevel.cs (and the stubs in tests\ailevel-unit.cs is NOT used): it prints the
// real /ailevel answer for three saved choices, so the screen test paints exactly what irdash would send.
namespace IRDash
{
    static class Program { public static string RootDir; }
    static class Watch { public static string IrdeckPath; }
    static class Log { public static void W(string s) { } }
    static class Json_ { public static string S(string s) { return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; } }
    static class KeyMsg { public static string Set(string k, string t, string kd) { return t; } }
}

static class AiLevelDump
{
    static void Main()
    {
        Program.RootDir = Path.Combine(Path.GetTempPath(), "ailevel-dump-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        Directory.CreateDirectory(Program.RootDir);
        try
        {
            Console.WriteLine("DEFAULT\t" + AiLevel.Json());
            AiLevel.Do("ailevel", "high");
            Console.WriteLine("HIGH\t" + AiLevel.Json());
            AiLevel.Do("ailevel", "range");
            for (int i = 0; i < 3; i++) AiLevel.Do("ailevel", "min+");     // 25 -> 40
            for (int i = 0; i < 4; i++) AiLevel.Do("ailevel", "max+");     // 50 -> 70
            Console.WriteLine("RANGE\t" + AiLevel.Json());
        }
        finally { try { Directory.Delete(Program.RootDir, true); } catch { } }
    }
}
