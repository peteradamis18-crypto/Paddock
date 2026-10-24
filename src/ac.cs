using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace IRDeck
{
    // AC keys (2026-10-23): the Midea AC in the rig room, through ac\ac.py (portable Python + msmart-ng in tools\python,
    // local network only after the one-time key from ac\Connect AC.cmd). ac.py prints one plain line, which becomes the log
    // line and the top-screen message ("AC on - cooling to 70°F - fan auto - room 75°F").
    static partial class Program
    {
        static readonly string[] AcVerbs = { "status", "on", "off", "toggle", "cooler", "warmer", "fan", "auto", "pcoff" };

        static int CmdAc(string[] a)
        {
            string verb = a.Length > 0 ? a[0].ToLowerInvariant() : "status";
            if (Array.IndexOf(AcVerbs, verb) < 0) { Log("ac: need " + string.Join("|", AcVerbs)); return 1; }
            string py = Path.Combine(Root, @"tools\python\python.exe"), script = Path.Combine(Root, @"ac\ac.py");
            if (!File.Exists(py) || !File.Exists(script)) { Log("ac: AC control is not installed"); return 1; }
            if (verb != "status" && verb != "auto" && verb != "pcoff") Say("wait", "Talking to the AC");   // Midea's server takes ~7 s
            string text; int code;
            int rc = RunAcPy(py, script, verb, out text, out code);
            if (rc != 0) { Log("ac: AC did not answer (" + (rc == 2 ? "timed out" : "could not start") + ")"); return 1; }
            Log("ac: " + text);
            return code == 0 ? 0 : code == 2 ? 3 : 1;
        }

        // Runs ac.py hidden, at most 30 s (through Midea's server a command takes about 7 s). -X utf8 so the ° sign survives.
        static int RunAcPy(string py, string script, string verb, out string text, out int code)
        {
            text = ""; code = 1;
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(py, "-I -X utf8 \"" + script + "\" " + verb);
                psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
                psi.StandardOutputEncoding = Encoding.UTF8; psi.WorkingDirectory = Root;
                using (Process p = Process.Start(psi))
                {
                    StringBuilder sb = new StringBuilder();
                    p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                    p.ErrorDataReceived += delegate { };   // drain stderr so a noisy library can't block the pipe
                    p.BeginOutputReadLine(); p.BeginErrorReadLine();
                    if (!p.WaitForExit(30000)) { try { p.Kill(); } catch { } return 2; }
                    p.WaitForExit();   // flushes the async readers
                    string o; lock (sb) o = sb.ToString();
                    string[] lines = o.Replace("\r", "").Trim().Split('\n');
                    text = lines[lines.Length - 1].Trim();
                    if (text.Length == 0) text = "AC did not answer";
                    code = p.ExitCode;
                }
                return 0;
            }
            catch { return 1; }
        }
    }
}
