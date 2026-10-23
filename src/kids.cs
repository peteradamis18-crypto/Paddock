// Kids mode (K-01). One deck key locks the rig so a child cannot rotate the iRacing view or press other keys.
// On: a low-level keyboard hook and a low-level mouse hook, in their own irdeck process, plus a flag file.
// Every other deck key reads that flag first and does nothing, except the few kids need while driving (DeckRules.KidsAllows:
// GET IN, TOW, RESTART, game volume, the kids key). The wheel is not a keyboard or a mouse, so it still works.
// It can be armed while the sim runs and while driving. The hooks pass INJECTED input (irdeck's own SendInput / keybd_event /
// mouse_event), so those allowed keys still click and type in the sim; only real hardware input is swallowed.
// Off after a reboot: the flag stores this boot's id, and a stale file is not a lock.
// The hook dies with its process. One press of the kids key (or `kids off`, the long press) clears the flag anyway.
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace IRDeck
{
    static partial class Program
    {
        const int KidsKbHookId = 13;   // WH_KEYBOARD_LL
        const int KidsMsHookId = 14;   // WH_MOUSE_LL

        [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, byte[] info, int len, out int ret);
        [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
        [DllImport("kernel32.dll")] static extern void GetSystemTimeAsFileTime(out long ft);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, KidsHookProc proc, IntPtr mod, uint tid);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern int GetMessage(out KidsMsg msg, IntPtr hwnd, uint min, uint max);
        [DllImport("user32.dll")] static extern bool TranslateMessage(ref KidsMsg msg);
        [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref KidsMsg msg);
        [DllImport("user32.dll")] static extern UIntPtr SetTimer(IntPtr hwnd, UIntPtr id, uint ms, IntPtr proc);
        [DllImport("user32.dll")] static extern void PostQuitMessage(int code);

        [StructLayout(LayoutKind.Sequential)]
        struct KidsMsg
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int x, y;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct KidsKbd
        {
            public uint vkCode, scanCode, flags, time;
            public IntPtr extra;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct KidsMouse   // MSLLHOOKSTRUCT
        {
            public int x, y;
            public uint mouseData, flags, time;
            public IntPtr extra;
        }

        delegate IntPtr KidsHookProc(int code, IntPtr wParam, IntPtr lParam);

        static IntPtr kidsKb, kidsMs;
        static KidsHookProc kidsKbProc, kidsMsProc;   // kept alive: a collected hook proc makes Windows drop the hook
        static int kidsVk, kidsN, kidsPass;   // kidsN = swallowed events, kidsPass = injected events let through
        // Test switch only (tests\kids-test.ps1): when set, injected input is swallowed too, so a SendInput key can prove the hook blocks.
        static bool kidsBlockInjected = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("IRDECK_KIDS_BLOCK_INJECTED"));

        static string KidsLockPath() { return Path.Combine(Root, @"dash\kids.lock"); }
        static string KidsStopPath() { return Path.Combine(Root, @"dash\kids.stop"); }
        static string KidsHookPath() { return Path.Combine(Root, @"dash\kids.hook"); }
        static string KidsTapPath() { return Path.Combine(Root, @"dash\kids.tap"); }

        // Same formula as irdash Server.KidsBootId. BootTime from the kernel does not move during a boot.
        // If that call fails, fall back to the clock minus uptime, in whole minutes, so a little drift still matches.
        static long KidsBootId()
        {
            byte[] buf = new byte[64];
            int ret;
            int st = NtQuerySystemInformation(3, buf, 48, out ret);
            if (st != 0) st = NtQuerySystemInformation(3, buf, 64, out ret);
            if (st == 0)
            {
                long boot = BitConverter.ToInt64(buf, 0);
                if (boot != 0) return boot;
            }
            long now;
            GetSystemTimeAsFileTime(out now);
            ulong ms = GetTickCount64();
            long raw = now - (long)ms * 10000L;
            if (raw == 0) return 0;
            return raw / 600000000L;
        }

        static long KidsField(string path, string key)
        {
            long v = 0;
            if (!File.Exists(path)) return 0;
            foreach (string line in File.ReadAllLines(path))
            {
                int i = line.IndexOf('=');
                if (i <= 0) continue;
                if (!line.Substring(0, i).Trim().Equals(key, StringComparison.OrdinalIgnoreCase)) continue;
                long.TryParse(line.Substring(i + 1).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v);
                return v;
            }
            return 0;
        }

        // True only for a lock written in this boot that has not expired and has not been told to stop.
        // A read error stays locked: a sharing clash must not drop the lock. A stale boot is deleted.
        static bool KidsLocked()
        {
            try
            {
                if (File.Exists(KidsStopPath())) return false;
                string p = KidsLockPath();
                if (!File.Exists(p)) return false;
                long boot = KidsField(p, "boot");
                long until = KidsField(p, "until");
                long nowBoot = KidsBootId();
                if (boot == 0 || nowBoot == 0 || boot != nowBoot)
                {
                    try { File.Delete(p); } catch { }
                    return false;
                }
                if (until > 0 && DateTime.UtcNow.Ticks > until)
                {
                    try { File.Delete(p); } catch { }
                    try { File.WriteAllText(KidsStopPath(), "1"); } catch { }
                    return false;
                }
                return true;
            }
            catch { return true; }
        }

        static int KidsHookPid()
        {
            try { return (int)KidsField(KidsHookPath(), "pid"); }
            catch { return 0; }
        }

        static bool KidsProcessIsHook(Process p)
        {
            try
            {
                if (p.HasExited) return false;
                string n = p.ProcessName.ToLowerInvariant();
                if (n.StartsWith("irdeck")) return true;
                string path = "";
                try { path = p.MainModule.FileName; } catch { return false; }
                string root = Root.TrimEnd('\\') + "\\";
                return path.StartsWith(root, StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        static bool KidsHookAlive()
        {
            int pid = KidsHookPid();
            if (pid <= 0 || pid == Process.GetCurrentProcess().Id) return false;
            try
            {
                using (Process p = Process.GetProcessById(pid)) return KidsProcessIsHook(p);
            }
            catch { return false; }
        }

        static void KidsWriteLock(long untilTicks)
        {
            string dir = Path.GetDirectoryName(KidsLockPath());
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            try { if (File.Exists(KidsStopPath())) File.Delete(KidsStopPath()); } catch { }
            string body = "boot=" + KidsBootId().ToString(CultureInfo.InvariantCulture) + "\r\nuntil=" + untilTicks.ToString(CultureInfo.InvariantCulture) + "\r\n";
            File.WriteAllText(KidsLockPath(), body);
        }

        static void KidsWriteHookFile()
        {
            string body = "pid=" + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture)
                + "\r\nkb=1\r\nmouse=1\r\nvk=" + kidsVk.ToString(CultureInfo.InvariantCulture)
                + "\r\nn=" + kidsN.ToString(CultureInfo.InvariantCulture)
                + "\r\npass=" + kidsPass.ToString(CultureInfo.InvariantCulture) + "\r\n";
            try { File.WriteAllText(KidsHookPath(), body); } catch { }
        }

        static void KidsUnhook()
        {
            if (kidsKb != IntPtr.Zero) { try { UnhookWindowsHookEx(kidsKb); } catch { } kidsKb = IntPtr.Zero; }
            if (kidsMs != IntPtr.Zero) { try { UnhookWindowsHookEx(kidsMs); } catch { } kidsMs = IntPtr.Zero; }
            try { if (File.Exists(KidsHookPath())) File.Delete(KidsHookPath()); } catch { }
        }

        static void KidsStartHook()
        {
            if (KidsHookAlive()) return;
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = Process.GetCurrentProcess().MainModule.FileName;
            psi.Arguments = "kids hook";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = Root;
            Process.Start(psi);
        }

        static bool KidsWaitHook()
        {
            for (int i = 0; i < 30; i++)
            {
                if (KidsHookAlive()) return true;
                Thread.Sleep(50);
            }
            return KidsHookAlive();
        }

        static void KidsTurnOff()
        {
            try
            {
                string dir = Path.GetDirectoryName(KidsStopPath());
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.WriteAllText(KidsStopPath(), "1");
            }
            catch { }
            try { if (File.Exists(KidsLockPath())) File.Delete(KidsLockPath()); } catch { }
            int pid = KidsHookPid();
            if (pid > 0 && pid != Process.GetCurrentProcess().Id)
            {
                try
                {
                    using (Process p = Process.GetProcessById(pid))
                    {
                        if (KidsProcessIsHook(p))
                        {
                            if (!p.WaitForExit(800)) p.Kill();
                        }
                    }
                }
                catch { }
            }
            try { if (File.Exists(KidsStopPath())) File.Delete(KidsStopPath()); } catch { }
            try { if (File.Exists(KidsHookPath())) File.Delete(KidsHookPath()); } catch { }
            Log("kids: unlocked");
        }

        static int KidsTurnOn(bool pretend, int forSec)
        {
            if (KidsLocked() && KidsHookAlive()) { Log("kids: already locked"); return 0; }
            // Arms at any time, sim running or not, in the car or not: that is exactly when children drive. (It used to refuse while the sim
            // ran. `pretend` is the old test flag and does nothing now.) The sim stays usable: the wheel is not hooked and irdeck's own injected
            // input passes the hooks, so GET IN, RESTART and chat still reach the sim.
            long until = 0;
            if (forSec > 0) until = DateTime.UtcNow.AddSeconds(forSec).Ticks;
            KidsWriteLock(until);
            KidsStartHook();
            if (!KidsWaitHook())
            {
                try { if (File.Exists(KidsLockPath())) File.Delete(KidsLockPath()); } catch { }
                Log("kids: could not lock the keyboard");
                return 1;
            }
            Log("kids: locked");
            return 0;
        }

        // A deck bounce is a second `kids` within 0.7 s. Explicit on/off are not bounced, so a long press (`kids off`) always unlocks.
        static bool KidsBounce()
        {
            long last = 0;
            try { long.TryParse(File.ReadAllText(KidsTapPath()).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out last); } catch { }
            long now = DateTime.UtcNow.Ticks;
            try
            {
                string dir = Path.GetDirectoryName(KidsTapPath());
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.WriteAllText(KidsTapPath(), now.ToString(CultureInfo.InvariantCulture));
            }
            catch { }
            if (last != 0 && now - last < TimeSpan.FromMilliseconds(700).Ticks)
            {
                Log("kids: repeat press ignored");
                return true;
            }
            return false;
        }

        static void KidsStatus()
        {
            bool on = KidsLocked();
            bool hook = on && KidsHookAlive();
            Log("kids: " + (on ? "on" : "off") + " hook=" + (hook ? "on" : "off") + " boot=" + KidsBootId().ToString(CultureInfo.InvariantCulture));
        }

        static IntPtr KidsKbHook(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                bool pass = false;
                try
                {
                    KidsKbd k = (KidsKbd)Marshal.PtrToStructure(lParam, typeof(KidsKbd));
                    kidsVk = (int)k.vkCode;
                    pass = DeckRules.HookPasses(k.flags, false, kidsBlockInjected);   // LLKHF_INJECTED: irdeck's own keys (GET IN, RESTART, chat)
                    if (pass) kidsPass++; else kidsN++;
                }
                catch { }
                if (pass) return CallNextHookEx(kidsKb, code, wParam, lParam);
                return (IntPtr)1;   // swallow real keys. The wheel never arrives here.
            }
            return CallNextHookEx(kidsKb, code, wParam, lParam);
        }

        static IntPtr KidsMsHook(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                try
                {
                    KidsMouse m = (KidsMouse)Marshal.PtrToStructure(lParam, typeof(KidsMouse));
                    if (DeckRules.HookPasses(m.flags, true, kidsBlockInjected)) { kidsPass++; return CallNextHookEx(kidsMs, code, wParam, lParam); }   // LLMHF_INJECTED
                }
                catch { }
                return (IntPtr)1;
            }
            return CallNextHookEx(kidsMs, code, wParam, lParam);
        }

        static int KidsHookLoop()
        {
            kidsKbProc = KidsKbHook;
            kidsMsProc = KidsMsHook;
            IntPtr mod = GetModuleHandle(null);
            kidsKb = SetWindowsHookEx(KidsKbHookId, kidsKbProc, mod, 0);
            kidsMs = SetWindowsHookEx(KidsMsHookId, kidsMsProc, mod, 0);
            if (kidsKb == IntPtr.Zero || kidsMs == IntPtr.Zero)
            {
                Log("kids hook: could not install (" + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture) + ")");
                KidsUnhook();
                return 1;
            }
            KidsWriteHookFile();
            Log("kids hook: keyboard and mouse locked");
            SetTimer(IntPtr.Zero, (UIntPtr)1, 50, IntPtr.Zero);
            KidsMsg msg;
            while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
            {
                if (msg.message == 0x0113)
                {
                    KidsWriteHookFile();
                    if (!KidsLocked()) PostQuitMessage(0);
                }
                else
                {
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
            }
            KidsUnhook();
            Log("kids hook: stopped");
            return 0;
        }

        static int KidsHookRun()
        {
            bool mine = false;
            Mutex mx = new Mutex(false, "Local\\irdeck-kids-hook");
            try
            {
                try { mine = mx.WaitOne(0); }
                catch (AbandonedMutexException) { mine = true; }
                if (!mine) { Log("kids hook: already running"); return 0; }
                if (!KidsLocked()) { Log("kids hook: no lock"); return 0; }
                return KidsHookLoop();
            }
            finally
            {
                if (mine)
                {
                    KidsUnhook();
                    try { mx.ReleaseMutex(); } catch { }
                }
                try { mx.Dispose(); } catch { }
            }
        }

        static int CmdKids(string[] a)
        {
            bool pretend = false;
            int forSec = 0;
            string verb = "toggle";
            for (int i = 0; i < a.Length; i++)
            {
                string s = a[i];
                if (s.Equals("--pretend-sim", StringComparison.OrdinalIgnoreCase)) { pretend = true; continue; }
                if (s.Equals("--for", StringComparison.OrdinalIgnoreCase))
                {
                    if (i + 1 < a.Length) int.TryParse(a[++i], NumberStyles.Integer, CultureInfo.InvariantCulture, out forSec);
                    continue;
                }
                if (verb == "toggle") verb = s.ToLowerInvariant();
            }
            if (forSec < 0) forSec = 0;
            if (forSec > 30) forSec = 30;   // a test safety net only. The real key does not expire.
            if (verb == "hook") return KidsHookRun();
            if (verb == "status") { KidsStatus(); return 0; }
            if (verb == "off") { KidsTurnOff(); return 0; }
            if (verb == "on") return KidsTurnOn(pretend, forSec);
            if (verb != "toggle") { Log("kids: use on, off, or status"); return 1; }
            if (KidsBounce()) return 0;
            // Locked: the KIDS key alone no longer unlocks (a child mashing the deck hit it). It arms the unlock; HOME within 4 s finishes it
            // (two keys at opposite ends of the top row, in that order). kids off from the PC still unlocks at once.
            if (KidsLocked()) { KidsArmUnlock(); Log("kids: press HOME within 4 seconds to unlock"); return 0; }
            return KidsTurnOn(pretend, forSec);
        }

        static string KidsUnlockPath() { return Path.Combine(Path.GetDirectoryName(KidsTapPath()), "kids-unlock.txt"); }
        static void KidsArmUnlock() { try { File.WriteAllText(KidsUnlockPath(), DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture)); } catch { } }
        // True when KIDS was pressed in the last 4 s (and not just now: the HOME press must be its own press, at least 0.3 s later)
        internal static bool KidsUnlockArmed()
        {
            try
            {
                long t; if (!long.TryParse(File.ReadAllText(KidsUnlockPath()).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out t)) return false;
                double s = (DateTime.UtcNow.Ticks - t) / (double)TimeSpan.TicksPerSecond;
                return s >= 0.3 && s <= 4.0;
            }
            catch { return false; }
        }
        internal static void KidsUnlockByHome() { try { File.Delete(KidsUnlockPath()); } catch { } KidsTurnOff(); Log("kids: unlocked (KIDS then HOME)"); }
    }
}
