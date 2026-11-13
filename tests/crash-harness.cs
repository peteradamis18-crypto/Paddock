// tests\crash-handler-test.ps1 compiles dash\src\log.cs with this file and runs it next to a copy of dash\irdash.exe.config.
//   crash-harness.exe bare  <log>   a bare thread throws (like ac.cs / recaudio.cs used to): one log line, the program goes on
//   crash-harness.exe guard <log>   a thread wrapped in Crash.Guard throws: one log line, the program goes on
//   crash-harness.exe ui    <log>   the tray (UI) thread throws inside its message loop: one log line, the loop goes on
// Each prints "alive" when it is still running 1.5 s after the exception, then exits 0.
using System;
using System.Threading;
using System.Windows.Forms;

namespace IRDash
{
    static class CrashHarness
    {
        // no "has stopped working" box on Peter's screens when the control run (no config) ends the way irdash used to
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern uint SetErrorMode(uint mode);

        [STAThread]
        static int Main(string[] args)
        {
            SetErrorMode(0x0001 | 0x0002);      // SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX
            Log.FilePath = args[1];
            Crash.Install();
            if (args[0] == "bare")
            {
                Thread t = new Thread(delegate () { throw new InvalidOperationException("boom on a bare thread"); });
                t.IsBackground = true; t.Start();
                Thread.Sleep(1500);
            }
            else if (args[0] == "guard")
            {
                Thread t = new Thread(Crash.Guard("ac send", delegate () { throw new FormatException("boom in a guarded thread"); }));
                t.IsBackground = true; t.Start();
                Thread.Sleep(1500);
            }
            else if (args[0] == "ui")
            {
                int ticks = 0;
                System.Windows.Forms.Timer boom = new System.Windows.Forms.Timer(); boom.Interval = 100;
                boom.Tick += delegate { boom.Stop(); throw new ArgumentException("boom on the tray thread"); };
                System.Windows.Forms.Timer later = new System.Windows.Forms.Timer(); later.Interval = 100;
                later.Tick += delegate { if (++ticks >= 15) { later.Stop(); Application.ExitThread(); } };
                boom.Start(); later.Start();
                Application.Run();
                if (ticks < 15) return 2;      // the loop ended early: the exception took it down
            }
            Console.WriteLine("alive");
            Log.Flush(3000);
            return 0;
        }
    }
}
