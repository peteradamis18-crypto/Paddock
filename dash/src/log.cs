// irdash.log (W0-2). Log.W used to write from every thread straight to the file (the lap-crossing thread and the UI thread waited on
// the disk) and DELETED the whole log at 2 MB. Now every line goes into one queue that a background thread writes; at 2 MB the file
// rolls to irdash.1.log (then .2, .3; the oldest goes). Each line keeps the time it was logged, not the time it was written.
// Crash: one exception on a bare thread used to end irdash with no log line. Crash.Install logs it and keeps the tray alive
// (dash\irdash.exe.config turns on the legacy policy that lets a background thread die without taking the process with it).
// Depends on nothing else in irdash: tests\log-roll-test.ps1 and tests\crash-handler-test.ps1 compile it alone.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;

namespace IRDash
{
    static class Log
    {
        public static string FilePath;
        public const long RollBytes = 2000000;
        public const int Keep = 3;            // irdash.1.log .. irdash.3.log
        static readonly Queue<string> queue = new Queue<string>();
        static readonly object gate = new object();
        static Thread writer;
        static int pending;                   // lines queued or being written (Flush waits for 0)

        public static void W(string m)
        {
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + m + "\r\n";
            lock (gate)
            {
                if (queue.Count > 20000) return;      // the disk is gone: never eat all the memory
                queue.Enqueue(line); pending++;
                if (writer == null)
                {
                    writer = new Thread(Run);
                    writer.IsBackground = true; writer.Priority = ThreadPriority.BelowNormal; writer.Name = "Log";
                    writer.Start();
                }
                Monitor.PulseAll(gate);
            }
        }

        // wait (up to ms) until everything logged so far is on disk: before the process ends, and for the tests
        public static bool Flush(int ms)
        {
            DateTime until = DateTime.UtcNow.AddMilliseconds(ms);
            lock (gate)
            {
                while (pending > 0)
                {
                    int left = (int)(until - DateTime.UtcNow).TotalMilliseconds;
                    if (left <= 0) return false;
                    Monitor.Wait(gate, Math.Min(left, 100));
                }
            }
            return true;
        }

        static void Run()
        {
            List<string> batch = new List<string>();
            while (true)
            {
                lock (gate)
                {
                    while (queue.Count == 0) Monitor.Wait(gate);
                    while (queue.Count > 0) batch.Add(queue.Dequeue());
                }
                try { Write(batch); } catch { }      // a full disk or a locked file must never take irdash down; the lines are dropped
                lock (gate) { pending -= batch.Count; Monitor.PulseAll(gate); }
                batch.Clear();
            }
        }

        static void Write(List<string> batch)
        {
            string f = FilePath;
            if (string.IsNullOrEmpty(f)) return;
            int i = 0;
            while (i < batch.Count)
            {
                long len = 0; try { if (File.Exists(f)) len = new FileInfo(f).Length; } catch { }
                if (len >= RollBytes) Roll(f);
                // write up to the size limit, then roll and go on: a line is never split between two files
                StringBuilder sb = new StringBuilder();
                long size = len >= RollBytes ? 0 : len;
                while (i < batch.Count && (sb.Length == 0 || size + sb.Length + batch[i].Length <= RollBytes)) { sb.Append(batch[i]); i++; }
                using (FileStream fs = new FileStream(f, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                {
                    byte[] b = Encoding.UTF8.GetBytes(sb.ToString());
                    fs.Write(b, 0, b.Length);
                }
            }
        }

        static string Numbered(string f, int n) { return Path.Combine(Path.GetDirectoryName(f), Path.GetFileNameWithoutExtension(f) + "." + n + Path.GetExtension(f)); }

        static void Roll(string f)
        {
            try
            {
                string oldest = Numbered(f, Keep);
                if (File.Exists(oldest)) File.Delete(oldest);
                for (int n = Keep - 1; n >= 1; n--) { string a = Numbered(f, n); if (File.Exists(a)) File.Move(a, Numbered(f, n + 1)); }
                File.Move(f, Numbered(f, 1));
            }
            catch { }   // something holds the file: keep writing to it, try again with the next batch
        }
    }

    static class Crash
    {
        static int count;

        // once, first thing in Main (before any window): log every unhandled exception, keep the tray alive
        public static void Install()
        {
            AppDomain.CurrentDomain.UnhandledException += delegate (object s, UnhandledExceptionEventArgs e)
            {
                Note("a background job failed", e.ExceptionObject as Exception, e.IsTerminating);
                if (e.IsTerminating) Log.Flush(3000);
            };
            try { System.Windows.Forms.Application.SetUnhandledExceptionMode(System.Windows.Forms.UnhandledExceptionMode.CatchException); } catch { }
            System.Windows.Forms.Application.ThreadException += delegate (object s, ThreadExceptionEventArgs e) { Note("the tray thread failed", e.Exception, false); };
        }

        public static void Note(string what, Exception ex, bool closing)
        {
            if (Interlocked.Increment(ref count) > 200) return;      // a loop of the same failure must not fill the disk
            string where = "";
            try { if (ex != null && ex.StackTrace != null) { string[] st = ex.StackTrace.Split('\n'); where = st.Length > 0 ? " at " + st[0].Trim() : ""; } } catch { }
            Log.W("crash: " + what + ": " + (ex == null ? "unknown error" : ex.GetType().Name + ": " + ex.Message) + where + (closing ? " - irdash is closing" : " - irdash keeps running"));
        }

        // a thread body that logs instead of dying silently: new Thread(Crash.Guard("ac send", Send))
        public static ThreadStart Guard(string name, ThreadStart body)
        {
            return delegate ()
            {
                try { body(); }
                catch (ThreadAbortException) { }
                catch (Exception ex) { Note(name, ex, false); }
            };
        }
    }
}
