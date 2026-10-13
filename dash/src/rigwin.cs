// Windows that belong to other programs (P5, docs\PLAN-v3.md):
//  - TunerBox: the Simucube Tuner leaves a blank grey always-on-top box (Qt class Qt6103QWindowToolSaveBits, title "Tuner", 300x150) on a race
//    screen. Rig Doctor hides it (ShowWindowAsync SW_HIDE: posted, so it never takes the focus and never waits for the Tuner). The Tuner is NEVER
//    closed or killed: the wheel and Paddock's wheel-strength steps rely on it. Only a window that is ALL of these is touched: it belongs to
//    sc-tuner, its class is Qt<version>QWindowToolSaveBits, its title is exactly "Tuner", it is visible, a topmost tool pop-up of 100..400 x 50..250
//    pixels, and the Tuner's own main window (class Qt<version>QWindowIcon) is not open on screen (then someone is using the Tuner and its pop-ups are real).
//  - RigWin.IracingUiHandle: the iRacing UI window without Process.MainWindowHandle, which can point at a tiny untitled strip (459x25) the UI
//    opens now and then. The window titled "iRacing" wins, else the largest visible window of the process (same rule as irdeck's IracingUiHandle).
// tests\rig-leftovers-test.ps1 runs both against stand-in programs (irdash.exe --analysis --rigwin ..., see RigWinCli).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class RigWin
    {
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
        [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

        public sealed class Win
        {
            public IntPtr H; public uint Pid; public string Class = "", Title = "";
            public int X, Y, W, Ht; public bool Visible, Iconic; public uint Style, Ex;
        }

        public static IntPtr Foreground() { return GetForegroundWindow(); }

        public static HashSet<uint> PidsOf(params string[] names)
        {
            HashSet<uint> pids = new HashSet<uint>();
            foreach (string n in names)
            {
                if (string.IsNullOrEmpty(n)) continue;
                foreach (Process p in Process.GetProcessesByName(n)) { try { pids.Add((uint)p.Id); } catch { } }
            }
            return pids;
        }

        // every top-level window of these processes (visible or not)
        public static List<Win> Of(HashSet<uint> pids)
        {
            List<Win> list = new List<Win>();
            if (pids == null || pids.Count == 0) return list;
            EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (!pids.Contains(pid)) return true;
                Win w = new Win(); w.H = h; w.Pid = pid;
                StringBuilder t = new StringBuilder(256); GetWindowText(h, t, 256); w.Title = t.ToString();
                StringBuilder c = new StringBuilder(128); GetClassName(h, c, 128); w.Class = c.ToString();
                RECT r; if (GetWindowRect(h, out r)) { w.X = r.Left; w.Y = r.Top; w.W = r.Right - r.Left; w.Ht = r.Bottom - r.Top; }
                w.Visible = IsWindowVisible(h); w.Iconic = IsIconic(h);
                w.Style = unchecked((uint)GetWindowLong(h, -16)); w.Ex = unchecked((uint)GetWindowLong(h, -20));
                list.Add(w);
                return true;
            }, IntPtr.Zero);
            return list;
        }

        // hide a window without activating it and without waiting for the program that owns it
        public static void Hide(IntPtr h) { ShowWindowAsync(h, 0); }

        // The iRacing UI's main window: the visible one titled "iRacing", else the largest visible window of the process; Zero when there is none.
        public static IntPtr IracingUiHandle() { return IracingUiHandle("iRacingUI"); }
        public static IntPtr IracingUiHandle(string process)
        {
            Win w = IracingUi(process);
            return w == null ? IntPtr.Zero : w.H;
        }
        public static Win IracingUi(string process)
        {
            HashSet<uint> pids = PidsOf(process);
            if (pids.Count == 0) return null;
            Win titled = null, largest = null; long area = 0;
            foreach (Win w in Of(pids))
            {
                if (!w.Visible) continue;
                if (titled == null && w.Title == "iRacing") titled = w;
                long a = (long)w.W * w.Ht;
                if (a > area) { area = a; largest = w; }
            }
            return titled ?? largest;
        }

        // True when the UI is up with its real window (titled "iRacing"), not only a strip
        public static bool IracingUiReady()
        {
            Win w = IracingUi("iRacingUI");
            return w != null && w.Title == "iRacing";
        }

        // Close the UI politely (what Process.CloseMainWindow does: a close request, posted) - on the right window.
        public static bool CloseIracingUi()
        {
            IntPtr h = IracingUiHandle();
            if (h == IntPtr.Zero) return false;
            PostMessage(h, 0x0112, (IntPtr)0xF060, IntPtr.Zero);   // WM_SYSCOMMAND, SC_CLOSE
            return true;
        }
    }

    static class TunerBox
    {
        static readonly object gate = new object();
        static readonly Dictionary<long, int> seen = new Dictionary<long, int>();   // window -> how often it was hidden (a window that keeps coming back must not fill the log)
        static readonly Regex BoxClass = new Regex("^Qt[0-9]+QWindowToolSaveBits$");
        static readonly Regex MainClass = new Regex("^Qt[0-9]+QWindowIcon$");
        public static string OwnerFile;   // dash\tuner-owner.txt: a test names a stand-in program here (the real one is always sc-tuner)

        static string ExtraOwner()
        {
            try
            {
                if (string.IsNullOrEmpty(OwnerFile) || !File.Exists(OwnerFile)) return "";
                string s = File.ReadAllText(OwnerFile);
                int n = s.IndexOfAny(new char[] { '\r', '\n' });
                if (n >= 0) s = s.Substring(0, n);
                s = s.Trim();
                if (s.Length == 0 || s.Length > 40 || s.IndexOf('\\') >= 0 || s.IndexOf('/') >= 0) return "";
                return s;
            }
            catch { return ""; }
        }

        // the blank box and nothing else
        public static bool IsBox(RigWin.Win w)
        {
            return w.Visible && BoxClass.IsMatch(w.Class) && w.Title == "Tuner"
                && w.W >= 100 && w.W <= 400 && w.Ht >= 50 && w.Ht <= 250
                && (w.Style & 0x80000000u) != 0 && (w.Ex & 0x8u) != 0 && (w.Ex & 0x80u) != 0;     // WS_POPUP, WS_EX_TOPMOST, WS_EX_TOOLWINDOW
        }

        public static int HideNow() { return Run(false, null, null); }

        // dry = only count (and describe) the windows it would hide; owner = a stand-in program name (tests), null = the owner file
        public static int Run(bool dry, string owner, List<string> report)
        {
            if (!Monitor.TryEnter(gate)) return 0;
            try
            {
                string extra = owner ?? ExtraOwner();
                HashSet<uint> pids = RigWin.PidsOf("sc-tuner", extra);
                if (pids.Count == 0) return 0;
                List<RigWin.Win> all = RigWin.Of(pids);
                HashSet<uint> inUse = new HashSet<uint>();
                foreach (RigWin.Win w in all) if (w.Visible && !w.Iconic && MainClass.IsMatch(w.Class)) inUse.Add(w.Pid);
                IntPtr fg = RigWin.Foreground();
                int n = 0;
                foreach (RigWin.Win w in all)
                {
                    if (inUse.Contains(w.Pid) || !IsBox(w) || w.H == fg) continue;
                    string what = w.W + "x" + w.Ht + " at " + w.X + "," + w.Y;
                    if (report != null) report.Add(what);
                    n++;
                    if (dry) continue;
                    RigWin.Hide(w.H);
                    int times; long key = w.H.ToInt64(); seen.TryGetValue(key, out times); times++; seen[key] = times;
                    if (seen.Count > 200) seen.Clear();
                    if (times <= 3 || times % 100 == 0)
                        Log.W("Rig Doctor: hid the Simucube Tuner's blank box (" + what + (times > 1 ? ", " + times + " times now" : "") + "); the Tuner itself keeps running");
                }
                return n;
            }
            finally { Monitor.Exit(gate); }
        }
    }

    // one-shot for tests\rig-leftovers-test.ps1:
    //   irdash.exe --analysis --rigwin tunerbox [--dry] [--owner <stand-in program>] --out <file>
    //   irdash.exe --analysis --rigwin uiwindow --proc <program> --out <file>
    static class RigWinCli
    {
        static string Arg(string[] a, string name) { for (int i = 0; i + 1 < a.Length; i++) if (a[i] == name) return a[i + 1] ?? ""; return ""; }

        public static int Run(string[] args)
        {
            string outPath = Arg(args, "--out"), json;
            CultureInfo inv = CultureInfo.InvariantCulture;
            if (outPath.Length == 0) return 2;
            if (Array.IndexOf(args, "tunerbox") >= 0)
            {
                List<string> rep = new List<string>();
                string owner = Arg(args, "--owner");
                int n = TunerBox.Run(Array.IndexOf(args, "--dry") >= 0, owner.Length > 0 ? owner : "", rep);
                StringBuilder sb = new StringBuilder("{\"count\":" + n + ",\"boxes\":[");
                for (int i = 0; i < rep.Count; i++) { if (i > 0) sb.Append(','); sb.Append(Json_.S(rep[i])); }
                json = sb.Append("]}").ToString();
            }
            else if (Array.IndexOf(args, "uiwindow") >= 0)
            {
                RigWin.Win w = RigWin.IracingUi(Arg(args, "--proc"));
                json = w == null ? "{\"found\":false}"
                    : "{\"found\":true,\"hwnd\":" + w.H.ToInt64().ToString(inv) + ",\"pid\":" + w.Pid + ",\"title\":" + Json_.S(w.Title) + ",\"w\":" + w.W + ",\"h\":" + w.Ht + "}";
            }
            else return 2;
            try { File.WriteAllText(outPath, json, new UTF8Encoding(false)); } catch { return 1; }
            return 0;
        }
    }
}
