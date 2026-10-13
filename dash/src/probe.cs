// probe.exe: what can a normal program see? Rig Doctor starts this through Explorer (so it runs outside any app
// sandbox, like Stream Deck and the logon launcher do) and reads probe.txt, which this writes next to itself.
// Programs started from the Claude app get private copies of new AppData folders, so the overlays app can be
// "installed" where nothing else can see it (2026-10-09). No window, nothing is changed, nothing is sent anywhere.
using System;
using System.IO;
using System.Text;

static class Probe
{
    static int Main()
    {
        string here = AppDomain.CurrentDomain.BaseDirectory;
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string exe = "MISSING";
        try
        {
            string[] apps = Directory.GetDirectories(Path.Combine(local, "irdashies"), "app-*");
            Array.Sort(apps);
            if (apps.Length > 0 && File.Exists(Path.Combine(apps[apps.Length - 1], "irdashies.exe"))) exe = Path.Combine(apps[apps.Length - 1], "irdashies.exe");
        }
        catch { }
        string cfg = Path.Combine(roaming, @"irdashies\config.json");
        StringBuilder sb = new StringBuilder();
        sb.AppendLine("time=" + DateTime.Now.ToString("o"));
        sb.AppendLine("localappdata=" + local);
        sb.AppendLine("appdata=" + roaming);
        sb.AppendLine("overlays_exe=" + exe);
        sb.AppendLine("config=" + (File.Exists(cfg) ? cfg : "MISSING"));
        File.WriteAllText(Path.Combine(here, "probe.txt"), sb.ToString());
        return 0;
    }
}
