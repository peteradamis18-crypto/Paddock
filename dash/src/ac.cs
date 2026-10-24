using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace IRDash
{
    // Auto-cool (2026-10-23): while the PC is on, irdash asks ac\ac.py every 2 minutes to cool the rig room when it is warm and
    // to stop again when it is cool (the rule and its numbers live in ac.py / ac\settings.json). Only network traffic to the AC:
    // safe while Peter drives. When it switches the AC, the top screen says so for 4 s like a deck key.
    static class AcAuto
    {
        static string root;
        public static int EveryMs = 120000;

        public static void Init(string rootDir) { root = rootDir; }

        public static void Start()
        {
            Thread t = new Thread(Loop);
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Name = "AcAuto";
            t.Start();
        }

        static void Loop()
        {
            Thread.Sleep(60000);   // never compete with boot
            while (true)
            {
                try { Tick(); } catch (Exception ex) { Log.W("ac auto: " + ex.Message); }
                Thread.Sleep(EveryMs);
            }
        }

        static void Tick()
        {
            string py = Path.Combine(root, @"tools\python\python.exe"), script = Path.Combine(root, @"ac\ac.py");
            if ((!File.Exists(Path.Combine(root, @"ac\ac.json")) && !File.Exists(Path.Combine(root, @"ac\cloud.bin"))) || !File.Exists(py) || !File.Exists(script)) return;   // not connected yet (local key or Midea Air login)
            ProcessStartInfo psi = new ProcessStartInfo(py, "-I -X utf8 \"" + script + "\" auto");
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8; psi.WorkingDirectory = root;
            using (Process p = Process.Start(psi))
            {
                try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
                StringBuilder sb = new StringBuilder();
                p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                p.ErrorDataReceived += delegate { };
                p.BeginOutputReadLine(); p.BeginErrorReadLine();
                if (!p.WaitForExit(30000)) { try { p.Kill(); } catch { } Log.W("ac auto: the AC did not answer in 30 s"); return; }
                p.WaitForExit();
                string o; lock (sb) o = sb.ToString().Trim();
                string last = o.Length == 0 ? "" : o.Substring(o.LastIndexOf('\n') + 1).Trim();
                if (last.StartsWith("AUTO ", StringComparison.Ordinal))
                {
                    string said = "AC: " + last.Substring(5);
                    Log.W("ac auto: " + said);
                    KeyMsg.Set("ac-auto", said, "ok");
                }
            }
        }
    }
}
