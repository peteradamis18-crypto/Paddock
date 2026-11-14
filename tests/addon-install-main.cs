// Test main for dash\src\addon.cs (tests\addon-install-test.ps1 compiles both). Prints "  ok ..." / "  FAIL ..." lines.
// args: <tmp dir>. The file moves are real (scratch folders); stopping/starting Stream Deck and the connect wait are hooks.
// Log, Json_, Showcase and IRDeck.DeckProfile are tiny stand-ins so addon.cs compiles alone.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using IRDash;

namespace IRDash
{
    static class Log { public static List<string> Lines = new List<string>(); public static void W(string m) { Lines.Add(m); } }
    static class Json_ { public static string S(string s) { return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; } }
    static class Showcase { public static double DeckPollAge = 1; }
}
namespace IRDeck
{
    static class DeckProfile { public static string ProfileDir() { return "x"; } public static string SetCurrentToMain(string d) { return "already"; } }
}

static class AddonTest
{
    static int pass, fail;
    static void Check(string what, bool ok) { if (ok) { pass++; Console.WriteLine("  ok    " + what); } else { fail++; Console.WriteLine("  FAIL  " + what); } }

    static void Make(string dir, string ver, string marker)
    {
        Directory.CreateDirectory(Path.Combine(dir, "img"));
        File.WriteAllText(Path.Combine(dir, "manifest.json"), "{\r\n  \"UUID\": \"com.peter.rigintro\",\r\n  \"Version\": \"" + ver + "\"\r\n}");
        File.WriteAllText(Path.Combine(dir, "plugin.html"), "<html>" + marker + "</html>");
        File.WriteAllBytes(Path.Combine(dir, "img", "tile.png"), new byte[] { 1, 2, 3, 4, (byte)marker.Length });
        File.WriteAllBytes(Path.Combine(dir, "RigRaces.streamDeckProfile"), Encoding.ASCII.GetBytes("profile-" + marker));
    }
    static bool Same(string a, string b)
    {
        List<string> fa = new List<string>(Directory.GetFiles(a, "*", SearchOption.AllDirectories)), fb = new List<string>(Directory.GetFiles(b, "*", SearchOption.AllDirectories));
        if (fa.Count != fb.Count) return false;
        foreach (string f in fa)
        {
            string o = Path.Combine(b, f.Substring(a.Length).TrimStart('\\'));
            if (!File.Exists(o)) return false;
            byte[] x = File.ReadAllBytes(f), y = File.ReadAllBytes(o);
            if (x.Length != y.Length) return false;
            for (int i = 0; i < x.Length; i++) if (x[i] != y[i]) return false;
        }
        return true;
    }

    static int stops, starts, waits; static bool connect;
    static void Reset(bool conn) { stops = 0; starts = 0; waits = 0; connect = conn; AddOn.AfterOldAside = null; }

    static int Main(string[] args)
    {
        string tmp = args[0]; Directory.CreateDirectory(tmp);
        string plugins = Path.Combine(tmp, "Plugins"), staged = Path.Combine(tmp, "staged"), inst = Path.Combine(plugins, "com.peter.rigintro.sdPlugin");
        Directory.CreateDirectory(plugins);
        AddOn.PluginsDir = plugins; AddOn.StagedDir = staged; AddOn.LockDir = tmp; AddOn.WaitSeconds = 3;
        AddOn.StopDeck = delegate { stops++; if (File.Exists(Path.Combine(tmp, "deck-build.lock")) == false) throw new Exception("no lock while Stream Deck is down"); };
        AddOn.StartDeck = delegate { starts++; };
        AddOn.WaitConnected = delegate (int s) { waits++; return connect; };
        int code; string r;

        // 1. lower installed version -> replaced
        Make(inst, "1.9.1.0", "old"); Make(staged, "1.9.2.0", "newer"); Reset(true);
        Check("Status before: installed 1.9.1.0, staged 1.9.2.0", AddOn.Status().Contains("\"installed\":\"1.9.1.0\"") && AddOn.Status().Contains("\"staged\":\"1.9.2.0\""));
        r = AddOn.Install(out code);
        Check("lower version: 200 'installed and running' (" + r + ")", code == 200 && r.Contains("Add-on 1.9.2.0 installed and running"));
        Check("lower version: stop once, start once, connect wait once", stops == 1 && starts == 1 && waits == 1);
        Check("lower version: files replaced byte for byte", Same(staged, inst) && AddOn.Version(inst) == "1.9.2.0");
        Check("lower version: no .old / .new left, lock file gone", !Directory.Exists(inst + ".old") && !Directory.Exists(inst + ".new") && !File.Exists(Path.Combine(tmp, "deck-build.lock")));
        Check("lower version: log says installing 1.9.2.0 over 1.9.1.0 and the connect time", Log.Lines.Exists(delegate (string l) { return l == "addon: installing 1.9.2.0 over 1.9.1.0"; }) && Log.Lines.Exists(delegate (string l) { return l.StartsWith("addon: Stream Deck back, add-on connected after "); }));

        // 2. same version -> nothing happens
        Reset(true);
        r = AddOn.Install(out code);
        Check("same version: 200 'already installed' (" + r + ")", code == 200 && r.Contains("Add-on 1.9.2.0 is already installed"));
        Check("same version: no stop, no start, no wait", stops == 0 && starts == 0 && waits == 0);

        // 3. a copy that fails (a staged file held open) -> old one untouched, Stream Deck started again
        Directory.Delete(staged, true); Directory.Delete(inst, true); Make(inst, "1.9.1.0", "old"); Make(staged, "1.9.3.0", "third"); Reset(true);
        string keep = Path.Combine(tmp, "keep-old"); Make(keep, "1.9.1.0", "old");
        using (FileStream lk = new FileStream(Path.Combine(staged, "plugin.html"), FileMode.Open, FileAccess.Read, FileShare.None))
        {
            r = AddOn.Install(out code);
        }
        Check("copy failure: 409 and the words say the old one is back (" + r + ")", code == 409 && r.Contains("was not installed") && r.Contains("the old one is back"));
        Check("copy failure: the old folder is untouched, nothing left beside it", Same(keep, inst) && !Directory.Exists(inst + ".old") && !Directory.Exists(inst + ".new"));
        Check("copy failure: Stream Deck was stopped and started again, no connect wait", stops == 1 && starts == 1 && waits == 0 && !File.Exists(Path.Combine(tmp, "deck-build.lock")));

        // 4. a failure after the old one was moved aside -> moved back
        Reset(true); AddOn.AfterOldAside = delegate { throw new Exception("disk went away"); };
        r = AddOn.Install(out code);
        Check("swap failure: 409 and 'old one is back' (" + r + ")", code == 409 && r.Contains("the old one is back"));
        Check("swap failure: old folder back untouched, no .old/.new", Same(keep, inst) && !Directory.Exists(inst + ".old") && !Directory.Exists(inst + ".new"));
        AddOn.AfterOldAside = null;

        // 5. connect timeout -> 409 with the look-at-the-deck words, files stay in place
        Reset(false);
        r = AddOn.Install(out code);
        Check("connect timeout: 409 'copied, but it has not connected yet - look at the deck' (" + r + ")", code == 409 && r.Contains("Add-on 1.9.3.0 copied, but it has not connected yet - look at the deck"));
        Check("connect timeout: the new files are in place", Same(staged, inst) && waits == 1);

        // 6. a crash left .old behind with no installed folder -> it comes back first, then the install goes on
        Directory.Delete(staged, true); Make(staged, "1.9.4.0", "fourth"); Directory.Move(inst, inst + ".old"); Reset(true);
        r = AddOn.Install(out code);
        Check("leftover .old: install still works, nothing left over (" + r + ")", code == 200 && Same(staged, inst) && !Directory.Exists(inst + ".old"));

        // 7. no staged folder
        Directory.Delete(staged, true); Reset(true);
        r = AddOn.Install(out code);
        Check("nothing staged: 409 and no stop (" + r + ")", code == 409 && stops == 0);

        // 8. Do / Handles / Status shape
        Check("Handles: addoninstall only", AddOn.Handles("addoninstall") && !AddOn.Handles("raceshare"));
        Check("Status says connected true (poll age 1 s)", AddOn.Status().Contains("\"connected\":true"));

        Console.WriteLine(pass + " passed, " + fail + " failed");
        return fail == 0 ? 0 : 1;
    }
}
