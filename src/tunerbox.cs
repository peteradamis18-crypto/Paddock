// The Simucube Tuner's blank grey box (P5, docs\PLAN-v3.md): HIDE it, never close it. RIG ON calls this once at its end; irdash's Rig Doctor
// does the same every 20 s (dash\src\rigwin.cs has the full story and the same rule - keep the two in step; tests\rig-leftovers-test.ps1 runs both).
// The window is ALL of: owned by sc-tuner, class Qt<version>QWindowToolSaveBits, title exactly "Tuner", visible, a topmost tool pop-up of
// 100..400 x 50..250 pixels - and the Tuner's own main window (Qt<version>QWindowIcon) is not open (then someone is using the Tuner).
//   irdeck tunerbox [--dry] [--owner <stand-in program>]     hide it now (--dry = only say where it is; --owner = tests)
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDeck
{
    static partial class Program
    {
        delegate bool TbEnum(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(TbEnum f, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out TbRect r);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
        [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
        [StructLayout(LayoutKind.Sequential)] struct TbRect { public int Left, Top, Right, Bottom; }

        sealed class TbWin { public IntPtr H; public uint Pid; public string Class = "", Title = ""; public int X, Y, W, Ht; public bool Visible, Iconic; public uint Style, Ex; }

        // Hides the box (or counts it, when dry). Returns how many windows matched.
        static int HideTunerBox(bool dry, string owner)
        {
            HashSet<uint> pids = new HashSet<uint>();
            foreach (string n in new[] { "sc-tuner", owner ?? "" })
            {
                if (n.Length == 0) continue;
                foreach (Process p in Process.GetProcessesByName(n)) { try { pids.Add((uint)p.Id); } catch { } }
            }
            if (pids.Count == 0) return 0;
            List<TbWin> all = new List<TbWin>();
            EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                uint pid; Native.GetWindowThreadProcessId(h, out pid);
                if (!pids.Contains(pid)) return true;
                TbWin w = new TbWin(); w.H = h; w.Pid = pid;
                StringBuilder t = new StringBuilder(256); GetWindowText(h, t, 256); w.Title = t.ToString();
                StringBuilder c = new StringBuilder(128); Native.GetClassName(h, c, 128); w.Class = c.ToString();
                TbRect r; if (GetWindowRect(h, out r)) { w.X = r.Left; w.Y = r.Top; w.W = r.Right - r.Left; w.Ht = r.Bottom - r.Top; }
                w.Visible = IsWindowVisible(h); w.Iconic = Native.IsIconic(h);
                w.Style = unchecked((uint)GetWindowLong(h, -16)); w.Ex = unchecked((uint)GetWindowLong(h, -20));
                all.Add(w);
                return true;
            }, IntPtr.Zero);
            Regex box = new Regex("^Qt[0-9]+QWindowToolSaveBits$"), main = new Regex("^Qt[0-9]+QWindowIcon$");
            HashSet<uint> inUse = new HashSet<uint>();
            foreach (TbWin w in all) if (w.Visible && !w.Iconic && main.IsMatch(w.Class)) inUse.Add(w.Pid);
            IntPtr fg = Native.GetForegroundWindow();
            int found = 0;
            foreach (TbWin w in all)
            {
                if (inUse.Contains(w.Pid) || w.H == fg) continue;
                if (!(w.Visible && box.IsMatch(w.Class) && w.Title == "Tuner" && w.W >= 100 && w.W <= 400 && w.Ht >= 50 && w.Ht <= 250
                      && (w.Style & 0x80000000u) != 0 && (w.Ex & 0x8u) != 0 && (w.Ex & 0x80u) != 0)) continue;   // WS_POPUP, WS_EX_TOPMOST, WS_EX_TOOLWINDOW
                found++;
                if (dry) { Log("tunerbox: the Tuner's blank box is here: " + w.W + "x" + w.Ht + " at " + w.X + "," + w.Y); continue; }
                ShowWindowAsync(w.H, 0);   // SW_HIDE, posted: no focus change, no waiting for the Tuner
                Log("tunerbox: hid the Simucube Tuner's blank box (" + w.W + "x" + w.Ht + " at " + w.X + "," + w.Y + "); the Tuner itself keeps running");
            }
            return found;
        }

        static int CmdTunerBox(string[] a)
        {
            string owner = "";
            for (int i = 0; i + 1 < a.Length; i++) if (a[i] == "--owner") owner = a[i + 1];
            int n = HideTunerBox(Array.IndexOf(a, "--dry") >= 0, owner);
            if (n == 0) Log("tunerbox: no blank box to hide");
            return 0;
        }
    }
}
