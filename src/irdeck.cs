// irdeck - helper for Stream Deck keys in iRacing.
//   ui      press a control in the iRacing UI by its name (works from any window, any monitor)
//   pit     official iRacing SDK pit commands (no chat typing needed)
//   chat    open/cancel chat, run chat macros, or type a chat line
//   key     send a keystroke, only when iRacing is the foreground app
//   state   print what the sim is doing; quit-sim closes the sim only when you are not on track
//   ovl     overlays on/off, presets, layout (the OVERLAYS deck screen); doctor = Rig Doctor on the top screen
// Every call is logged to irdeck.log next to the exe.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Automation;

namespace IRDeck
{
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public INPUTUNION u; }

    static class Native
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string s);
        [DllImport("user32.dll")] public static extern bool SendNotifyMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
        [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
        [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool LockWorkStation();
        [StructLayout(LayoutKind.Sequential)] public struct PT { public int X, Y; }
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(PT p);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("powrprof.dll")] public static extern bool SetSuspendState(bool hibernate, bool force, bool disableWake);
    }

    // ---- Windows Core Audio: per-app volume (game vs music) ----
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);   // sound.cs (only read: the default device is never changed)
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore props);   // sound.cs: the device's name
    }
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(IntPtr a, int b, out IntPtr c);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr a, int b, out IntPtr c);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e);
    }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int n);
        [PreserveSig] int GetSession(int i, out IAudioSessionControl2 s);
    }
    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int s);
        [PreserveSig] int GetDisplayName(out IntPtr n);
        [PreserveSig] int SetDisplayName(IntPtr n, IntPtr ctx);
        [PreserveSig] int GetIconPath(out IntPtr p);
        [PreserveSig] int SetIconPath(IntPtr p, IntPtr ctx);
        [PreserveSig] int GetGroupingParam(out Guid g);
        [PreserveSig] int SetGroupingParam(ref Guid g, IntPtr ctx);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr n);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr n);
        [PreserveSig] int GetSessionIdentifier(out IntPtr id);
        [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id);
        [PreserveSig] int GetProcessId(out uint pid);
    }
    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume
    {
        [PreserveSig] int SetMasterVolume(float level, ref Guid ctx);
        [PreserveSig] int GetMasterVolume(out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);   // sound.cs
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    sealed class Cand
    {
        public AutomationElement El; public string Name; public string Type; public bool Off; public bool Enabled; public Rect R;
    }

    // Reads the iRacing SDK shared memory (the same data SimHub uses).
    sealed class Tele : IDisposable
    {
        MemoryMappedFile mmf; MemoryMappedViewAccessor va; int bufOff; public int Tick;
        readonly Dictionary<string, int[]> vars = new Dictionary<string, int[]>();

        public static Tele Open()
        {
            MemoryMappedFile m;
            try { m = MemoryMappedFile.OpenExisting("Local\\IRSDKMemMapFileName", MemoryMappedFileRights.Read); }
            catch { return null; }
            Tele t = new Tele();
            t.mmf = m;
            t.va = m.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read);
            if ((t.va.ReadInt32(4) & 1) == 0) { t.Dispose(); return null; }
            int numVars = t.va.ReadInt32(24), hdrOff = t.va.ReadInt32(28), numBuf = t.va.ReadInt32(32);
            int bestTick = -1;
            for (int i = 0; i < numBuf && i < 4; i++)
            {
                int tick = t.va.ReadInt32(48 + i * 16), off = t.va.ReadInt32(52 + i * 16);
                if (tick > bestTick) { bestTick = tick; t.bufOff = off; }
            }
            t.Tick = bestTick;
            for (int i = 0; i < numVars; i++)
            {
                int b = hdrOff + i * 144;
                byte[] nm = new byte[32];
                for (int k = 0; k < 32; k++) nm[k] = t.va.ReadByte(b + 16 + k);
                int len = Array.IndexOf(nm, (byte)0); if (len < 0) len = 32;
                string name = Encoding.ASCII.GetString(nm, 0, len);
                t.vars[name] = new int[] { t.va.ReadInt32(b), t.va.ReadInt32(b + 4) };
            }
            return t;
        }
        public bool Has(string n) { return vars.ContainsKey(n); }
        public double Num(string n)
        {
            int[] v; if (!vars.TryGetValue(n, out v)) return 0;
            long p = bufOff + v[1];
            switch (v[0])
            {
                case 0: case 1: return va.ReadByte(p);
                case 2: case 3: return va.ReadInt32(p);
                case 4: return va.ReadSingle(p);
                case 5: return va.ReadDouble(p);
            }
            return 0;
        }
        public bool Bool(string n) { return Num(n) != 0; }

        // The session description iRacing publishes as YAML (event type, drivers, AI flags...).
        public string SessionInfo()
        {
            int len = va.ReadInt32(16), off = va.ReadInt32(20);
            if (len <= 0 || off <= 0) return "";
            byte[] bytes = new byte[len];
            va.ReadArray<byte>(off, bytes, 0, len);
            int z = Array.IndexOf(bytes, (byte)0); if (z < 0) z = len;
            return Encoding.GetEncoding(28591).GetString(bytes, 0, z);
        }
        public void Dispose() { if (va != null) va.Dispose(); if (mmf != null) mmf.Dispose(); }
    }

    static partial class Program   // friends mode: guest.cs, test drive setup: testdrive.cs, overlays + Rig Doctor: overlays.cs, My Drive: mydrive.cs (build all five together)
    {
        static readonly string Dir = AppDomain.CurrentDomain.BaseDirectory;
        // key copies of this exe live in <root>\keys; the log and settings stay in <root>
        static readonly string Root = Path.GetFileName(Dir.TrimEnd('\\')).Equals("keys", StringComparison.OrdinalIgnoreCase)
            ? Path.GetDirectoryName(Dir.TrimEnd('\\')) : Dir;

        [DllImport("shell32.dll", SetLastError = true)]
        static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cmd, out int n);
        [DllImport("kernel32.dll")] static extern bool Beep(uint freq, uint ms);

        static string[] SplitArgs(string s)
        {
            int n; IntPtr p = CommandLineToArgvW("x " + s, out n);
            string[] r = new string[Math.Max(0, n - 1)];
            for (int i = 1; i < n; i++) r[i - 1] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, i * IntPtr.Size));
            return r;
        }

        static void Log(string s)
        {
            try
            {
                string p = Path.Combine(Root, "irdeck.log");
                // keep the history: at 1 MB the log moves to irdeck.log.1 (it used to be DELETED at 200 kB, so only 3 days of presses survived)
                if (File.Exists(p) && new FileInfo(p).Length > 1000000) { string old = p + ".1"; try { if (File.Exists(old)) File.Delete(old); File.Move(p, old); } catch { } }
                if (!s.StartsWith("[") && s.IndexOf("repeat press ignored", StringComparison.Ordinal) < 0) LastLog = s;
                File.AppendAllText(p, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + s + "\r\n");
            }
            catch { }
#if CLI
            Console.WriteLine(s);
#endif
        }

        static string[] Slice(string[] a, int n)
        {
            string[] r = new string[Math.Max(0, a.Length - n)];
            Array.Copy(a, n, r, 0, r.Length);
            return r;
        }

        static Mutex keyMutex;   // held for the whole run of a key, so a repeat press finds it taken

        static int Main(string[] a)
        {
            // A copy of this exe named after a key (keys\fuel-plus1.exe) looks its command up in keys\keys.map,
            // so a Stream Deck "Open" action only needs a plain .exe path - no shortcut or arguments.
            string self = Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName);
            string tag = "";
            if (a.Length == 0 && !self.StartsWith("irdeck", StringComparison.OrdinalIgnoreCase))
            {
                string line = null;
                try
                {
                    foreach (string l in File.ReadAllLines(Path.Combine(Dir, "keys.map")))
                    {
                        int i = l.IndexOf('=');
                        if (i > 0 && l.Substring(0, i).Trim().Equals(self, StringComparison.OrdinalIgnoreCase)) { line = l.Substring(i + 1); break; }
                    }
                }
                catch { }
                if (line == null) { Log("[" + self + "] no entry in keys.map"); Beep(300, 400); return 1; }
                a = SplitArgs(line); tag = "[" + self + "] "; KeyId = self;
                // K-01: kids mode ignores every deck key except the kids key and the few a child needs while driving (GET IN, TOW,
                // RESTART, game volume: DeckRules.KidsAllows). The flag file is checked first, so one press of the kids key still
                // unlocks after the hook process has died (the hook dies with it).
                if (KidsLocked() && a.Length > 0 && a[0].Equals("rigon", StringComparison.OrdinalIgnoreCase) && KidsUnlockArmed()) { KidsUnlockByHome(); Say("ok", "Kids mode off"); SayFlush(); return 0; }   // KIDS, then HOME within 4 s
                if (KidsLocked() && !DeckRules.KidsAllows(a))
                {
                    Log(tag + "kids mode: ignored");
                    Say("no", "Kids mode is on"); SayFlush();
                    return 0;
                }
                // One press can reach us two or three times within a fraction of a second (seen 2026-10-09:
                // QUIT TO MAIN x3 in 0.3 s, SLEEP x2 in 50 ms, which also defeated SLEEP's press-twice guard).
                // Drop a repeat while the same key is still running or within 0.7 s of its last start.
                // Volume and seat keys are left alone: pressing them quickly on purpose is normal.
                string verb = a.Length > 0 ? a[0].ToLowerInvariant() : "";
                if (verb != "media" && verb != "key")
                {
                    bool mine;
                    keyMutex = new Mutex(true, "Local\\irdeck-key-" + self, out mine);
                    string stamp = Path.Combine(Path.GetTempPath(), "irdeck-" + self + ".last");
                    long last = 0;
                    try { long.TryParse(File.ReadAllText(stamp), out last); } catch { }
                    // x2 keys (confirm): Peter's own double tap is 0.18-0.66 s apart (log 2026-10-11) and the 0.7 s rule ate
                    // his second tap, so QUIT never fired; a bounce is under 0.1 s (29 ms seen), so 0.12 s is the floor there
                    bool freshArmed = verb == "confirm" && ConfirmArmedFresh(a);
                    int gapMs = 120;
                    if (DateTime.UtcNow.Ticks - last < TimeSpan.FromMilliseconds(gapMs).Ticks)
                    {
                        Log(tag + "repeat press ignored");
                        return 0;
                    }
                    if (!mine && !freshArmed)
                    {
                        Log(tag + "repeat press ignored");
                        return 0;
                    }
                    try { File.WriteAllText(stamp, DateTime.UtcNow.Ticks.ToString()); } catch { }
                    if (freshArmed && mine) { try { keyMutex.ReleaseMutex(); } catch { } }
                }
            }
            if (!(a.Length >= 2 && a[0].Equals("sound", StringComparison.OrdinalIgnoreCase) && a[1].Equals("status", StringComparison.OrdinalIgnoreCase)))   // the SOUND screen asks every 2 s: not in the log
                Log(tag + "> " + string.Join(" ", a));
            int rc = 9;
            try { rc = Run(a); }
            catch (Exception ex) { Log("ERROR " + ex.GetType().Name + ": " + ex.Message); }
            if (tag.Length > 0 && rc != 4) { SayResult(rc); SayFlush(); }
            if (rc == 4) return 0;   // tow gave up, or a second press while one is already waiting: already logged, no beep
#if !CLI
            if (rc != 0) { try { Beep(rc == 3 ? 500u : 300u, 180); } catch { } }   // short beep = the key was received but did nothing
#endif
            return rc;
        }

        static int Run(string[] a)
        {
            if (a.Length == 0) { Log("usage: ui|uilist|pit|chat|key|state|quit-sim|focus|kids|racenow ..."); return 1; }
            switch (a[0].ToLowerInvariant())
            {
                case "ui": return CmdUi(Slice(a, 1), false);
                case "uilist": return CmdUi(Slice(a, 1), true);
                case "guest": return CmdGuest(Slice(a, 1));
                case "tdsetup": return CmdTdSetup(Slice(a, 1));   // testdrive.cs
                case "tdfind": return CmdTdFind(Slice(a, 1));
                case "showcase":   // replay the startup intro on the top screen (irdash refuses while driving)
                    try { using (var wc = new System.Net.WebClient()) wc.DownloadString("http://127.0.0.1:8199/api/showcase"); Log("showcase: requested"); return 0; }
                    catch (Exception ex) { Log("showcase: irdash not reachable (" + ex.Message + ")"); return 1; }
                case "pit": return CmdPit(Slice(a, 1));
                case "chat": return CmdChat(Slice(a, 1));
                case "key": return CmdKey(Slice(a, 1));
                case "state": return CmdState();
                case "quit-sim": return CmdQuitSim();
                case "focus": return CmdFocus(Slice(a, 1));
                case "simclick": return CmdSimClick(Slice(a, 1));
                case "testdrive": return CmdTestDrive(Slice(a, 1));
                case "exitcar": return CmdGetOut();
                case "getout": return CmdGetOut();
                case "go": return CmdGo();
                case "smart": return CmdSmart(Slice(a, 1));
                case "quitmain": return CmdQuitMain();
                case "nav": return CmdNav(Slice(a, 1));
                case "airace": return CmdAiRace(Slice(a, 1));
                case "restart": return CmdRestart(Slice(a, 1));
                case "media": return CmdMedia(Slice(a, 1));
                case "appvol": return CmdAppVol(Slice(a, 1));
                case "sound": return CmdSound(Slice(a, 1));   // sound.cs: the SOUND deck screen (levels, mute, presets; never the default device)
                case "dash": return CmdDash(Slice(a, 1));     // a key that irdash handles (TV VIEW, KEEP LAP)
                case "ffb": return CmdFfb(Slice(a, 1));
                case "open": return CmdOpen(Slice(a, 1));
                case "hotkey": return CmdHotkey(Slice(a, 1));
                case "center": return CmdCenter();
                case "confirm": return CmdConfirm(Slice(a, 1));
                case "power": return CmdPower(Slice(a, 1));
                case "ac": return CmdAc(Slice(a, 1));   // the rig room's Midea AC (src\ac.cs, ac\ac.py)
                case "rigon": return CmdRigOn(Slice(a, 1));
                case "startlast": return CmdStartLast(Slice(a, 1));
                case "tow": return CmdTow(Slice(a, 1));
                case "restartrace": return CmdRestartRace();
                case "skip": return CmdSkip();
                case "racenow": return CmdRaceNow();   // from practice or qualify: keep skipping until the race, then get in the car
                case "pittoggle": return CmdPitToggle(Slice(a, 1));
                case "replay": return CmdReplayIncident();
                case "capture": return CmdCapture();
                case "overlays": return CmdOverlays();
                case "ovl": return CmdOvl(Slice(a, 1));       // overlays.cs: the OVERLAYS deck screen
                case "mydrive": return CmdMyDrive(Slice(a, 1));   // mydrive.cs: the MY DRIVE deck screen
                case "official": return CmdOfficial(Slice(a, 1)); // official.cs: official races you can enter (list, favourites, UI checks)
                case "sess": return CmdSess();                    // actions.cs: what the sim says about the session
                case "simdialog": return CmdSimDialog();          // actions.cs: is a sim confirmation dialog showing
                case "doctor": return CmdDoctor();            // overlays.cs: Rig Doctor on the top screen
                case "tunerbox": return CmdTunerBox(Slice(a, 1));   // tunerbox.cs: hide the Simucube Tuner's blank grey box (never closes the Tuner)
                case "kids": return CmdKids(Slice(a, 1));             // kids.cs: one key locks the keyboard and mouse
                case "spot": return CmdSpot(Slice(a, 1));             // spot.cs: SAVE SPOT / BACK TO SPOT (Test Drive practice loop, tries timed by irdash)
                case "pause": return CmdPause();                      // spot.cs: pause the sim and say whether it really stopped
            }
            Log("unknown command " + a[0]);
            return 1;
        }

        // ---------- UI automation (the Chromium-based iRacing UI) ----------

        static AutomationElement FindUiWindow()
        {
            IntPtr h = IracingUiHandle();
            if (h == IntPtr.Zero) return null;
            try { return AutomationElement.FromHandle(h); } catch { return null; }
        }

        // The iRacing UI's main window. Process.MainWindowHandle can point at a small untitled strip the UI opens now and
        // then (2026-10-11 01:47: a 459x25 window took over and every UI lookup saw 0 controls, so START and QUIT TO MAIN
        // would have found nothing). Look at every visible window of the process: the one titled "iRacing" wins, else the largest.
        static IntPtr IracingUiHandle()
        {
            HashSet<uint> pids = new HashSet<uint>();
            foreach (Process p in Process.GetProcessesByName("iRacingUI")) pids.Add((uint)p.Id);
            if (pids.Count == 0) return IntPtr.Zero;
            IntPtr titled = IntPtr.Zero, largest = IntPtr.Zero; double area = 0;
            OvlNative.EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                uint pid; Native.GetWindowThreadProcessId(h, out pid);
                if (!pids.Contains(pid) || !OvlNative.IsWindowVisible(h)) return true;
                StringBuilder t = new StringBuilder(64); OvlNative.GetWindowText(h, t, 64);
                if (titled == IntPtr.Zero && t.ToString() == "iRacing") titled = h;
                try { System.Windows.Rect r = AutomationElement.FromHandle(h).Current.BoundingRectangle; double a = r.Width * r.Height; if (a > area) { area = a; largest = h; } } catch { }
                return true;
            }, IntPtr.Zero);
            return titled != IntPtr.Zero ? titled : largest;
        }

        // The UI prefixes some labels with an invisible icon-font glyph (private use area); drop it.
        static string Clean(string s)
        {
            if (s == null) return "";
            StringBuilder b = new StringBuilder();
            foreach (char ch in s) if (ch < 0xE000 || ch > 0xF8FF) b.Append(ch);
            return b.ToString().Trim();
        }

        static bool RunWithTimeout(ThreadStart f, int ms)
        {
            Thread t = new Thread(f); t.IsBackground = true; t.Start();
            return t.Join(ms);
        }

        static List<Cand> Scan(AutomationElement root)
        {
            List<Cand> list = new List<Cand>();
            RunWithTimeout(delegate
            {
                try
                {
                    ControlType[] types = { ControlType.Button, ControlType.Hyperlink, ControlType.TabItem, ControlType.MenuItem, ControlType.ListItem, ControlType.CheckBox, ControlType.RadioButton };
                    Condition[] cs = new Condition[types.Length];
                    for (int i = 0; i < types.Length; i++) cs[i] = new PropertyCondition(AutomationElement.ControlTypeProperty, types[i]);
                    CacheRequest cr = new CacheRequest();
                    cr.Add(AutomationElement.NameProperty); cr.Add(AutomationElement.ControlTypeProperty);
                    cr.Add(AutomationElement.IsOffscreenProperty); cr.Add(AutomationElement.IsEnabledProperty);
                    cr.Add(AutomationElement.BoundingRectangleProperty);
                    using (cr.Activate())
                    {
                        AutomationElementCollection col = root.FindAll(TreeScope.Descendants, new OrCondition(cs));
                        foreach (AutomationElement e in col)
                        {
                            Cand c = new Cand();
                            c.El = e; c.Name = Clean(e.Cached.Name);
                            c.Type = e.Cached.ControlType.ProgrammaticName.Replace("ControlType.", "");
                            c.Off = e.Cached.IsOffscreen; c.Enabled = e.Cached.IsEnabled; c.R = e.Cached.BoundingRectangle;
                            list.Add(c);
                        }
                    }
                }
                catch (Exception ex) { Log("scan error: " + ex.Message); }
            }, 8000);
            return list;
        }

        static Cand Pick(List<Cand> all, List<string> names, string type, bool last)
        {
            foreach (string n in names)
            {
                Cand hit = null;
                foreach (Cand c in all)
                {
                    if (!c.Enabled || c.Off) continue;
                    if (type != "any" && !c.Type.ToLowerInvariant().StartsWith(type)) continue;
                    if (!string.Equals(c.Name, n.Trim(), StringComparison.OrdinalIgnoreCase)) continue;
                    if (hit == null || last) hit = c;
                }
                if (hit != null) return hit;
            }
            return null;
        }

        static bool Press(Cand c)
        {
            try
            {
                object pat;
                if (c.El.TryGetCurrentPattern(InvokePattern.Pattern, out pat))
                {
                    InvokePattern ip = (InvokePattern)pat;
                    RunWithTimeout(delegate { try { ip.Invoke(); } catch (Exception ex) { Log("invoke error: " + ex.Message); } }, 4000);
                    Log("pressed [" + c.Type + "] " + c.Name);
                    return true;
                }
                if (c.El.TryGetCurrentPattern(SelectionItemPattern.Pattern, out pat))
                {
                    SelectionItemPattern sp = (SelectionItemPattern)pat;
                    RunWithTimeout(delegate { try { sp.Select(); } catch (Exception ex) { Log("select error: " + ex.Message); } }, 4000);
                    Log("selected [" + c.Type + "] " + c.Name);
                    return true;
                }
            }
            catch (Exception ex) { Log("press failed: " + ex.Message); }
            if (!c.R.IsEmpty && c.R.Width > 0)
            {
                Native.SetCursorPos((int)(c.R.X + c.R.Width / 2), (int)(c.R.Y + c.R.Height / 2));
                Thread.Sleep(60);
                Native.mouse_event(0x02, 0, 0, 0, UIntPtr.Zero); Thread.Sleep(40); Native.mouse_event(0x04, 0, 0, 0, UIntPtr.Zero);
                Log("clicked [" + c.Type + "] " + c.Name);
                return true;
            }
            return false;
        }

        static int CmdUi(string[] a, bool listOnly)
        {
            string type = "any"; bool last = false; int timeout = 5000;
            List<string> names = new List<string>();
            foreach (string t in a)
            {
                if (t.StartsWith("--type=")) type = t.Substring(7).ToLowerInvariant();
                else if (t == "--last") last = true;
                else if (t.StartsWith("--timeout=")) timeout = int.Parse(t.Substring(10));
                else names.Add(t);
            }
            AutomationElement root = FindUiWindow();
            if (root == null) { Log("iRacing UI window not found"); return 2; }
            // a minimised UI only exposes its title-bar buttons, so nothing can be found until it is restored
            IntPtr uh = new IntPtr(root.Current.NativeWindowHandle);
            if (!listOnly && Native.IsIconic(uh)) { Native.ShowWindow(uh, 9); Log("restored minimised iRacing UI"); Thread.Sleep(1200); }
            DateTime end = DateTime.Now.AddMilliseconds(timeout);
            List<Cand> c;
            do
            {
                c = Scan(root);
                if (listOnly) break;
                Cand hit = Pick(c, names, type, last);
                if (hit != null) return Press(hit) ? 0 : 1;
                Thread.Sleep(250);
            } while (DateTime.Now < end);
            if (listOnly)
            {
                foreach (Cand x in c)
                    if (!x.Off && x.Name.Length > 0)
                        Log(string.Format("{0,-10} {1}  [{2:0},{3:0} {4:0}x{5:0}]", x.Type, x.Name, x.R.X, x.R.Y, x.R.Width, x.R.Height));
                return 0;
            }
            Log("not found: " + string.Join(" | ", names.ToArray()) + " (type=" + type + ", " + c.Count + " controls seen)");
            return 1;
        }

        // ---------- state helpers ----------

        // The UI preloads the sim silently in the background, so "sim process running" does not mean "in a session".
        // A session is active when the sim publishes telemetry.
        // The iRacing UI in front (another window - the Claude app, a browser - can have come up over it: its pop-ups close when it loses focus).
        static void UiFront()
        {
            IntPtr u = UiWindow();
            if (u != IntPtr.Zero && Native.GetForegroundWindow() != u) { FocusWindow(u); Thread.Sleep(200); }
        }
        static bool SessionActive() { if (Process.GetProcessesByName("iRacingSim64DX11").Length == 0) return false; Tele t = Tele.Open(); if (t == null) return false; t.Dispose(); return true; }
        static bool OnTrack() { Tele t = Tele.Open(); if (t == null) return false; using (t) { return t.Bool("IsOnTrack"); } }
        static List<string> L(params string[] s) { return new List<string>(s); }

        static Snapshot CurrentDeckSnapshot()
        {
            Snapshot s = new Snapshot();
            s.Sim = Process.GetProcessesByName("iRacingSim64DX11").Length > 0;
            s.Ui = Process.GetProcessesByName("iRacingUI").Length > 0;
            if (!s.Sim) return s;
            Tele t = Tele.Open();
            if (t == null) return s;
            using (t)
            {
                s.Fresh = DeckTelemetryFresh(t.Tick);
                s.Connected = t.Has("IsOnTrack") && t.Has("Speed") && t.Has("IsReplayPlaying");
                s.OnTrack = t.Bool("IsOnTrack"); s.Speed = t.Num("Speed"); s.Replay = t.Bool("IsReplayPlaying");
                string info = t.SessionInfo();
                s.SessionKnown = !string.IsNullOrEmpty(info);
                s.TestOrAi = System.Text.RegularExpressions.Regex.IsMatch(info, @"(?m)^\s*EventType:\s*(Test|AI)\s*$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                return s;
            }
        }
        static DeckState CurrentDeckState() { return DeckStateResolver.Resolve(CurrentDeckSnapshot()); }
        static bool DeckTelemetryFresh(int tick)
        {
            if (tick < 0) return false;
            // Each CLI call is a new process, so prove the SDK is advancing in this call.
            // Remembering the first tick seen in a process can make an already stalled tick look fresh.
            int first = tick;
            DateTime end = DateTime.UtcNow.AddMilliseconds(900);
            while (DateTime.UtcNow < end)
            {
                Thread.Sleep(100);
                Tele next = Tele.Open();
                if (next == null) return false;
                int current;
                using (next) current = next.Tick;
                if (DeckStateResolver.TelemetryAdvanced(first, current)) return true;
            }
            return false;
        }
        // GET IN (the `smart` key): ONE press from any state finishes the whole job. It works the state out itself
        // (DeckRules.GetInPlan) and no longer depends on the deck-face resolver: after GET OUT iRacing plays a replay behind its
        // session screen, and the resolver said WAIT for that (15 of 17 real presses did nothing, 20-23 Oct).
        //   in the car                 -> nothing to do
        //   a session (any screen)     -> press the sim's green Drive/Test/Race button until the car is on track (CmdGo)
        //   no session                 -> start the last drive: MY DRIVE's choice, else the Test Drive 'Last settings'
        //   iRacing app not open       -> open it (RIG ON) first
        // `smart --dry` only says which of these it would do. `smart --fake <json>` is the resolver test hook (no sim).
        static int CmdSmart(string[] args)
        {
            bool dry = args != null && Array.IndexOf(args, "--dry") >= 0;
            Snapshot fake = SmartFake(args);
            if (fake != null) return SmartFakeRun(args, fake, dry);
            if (dry) { Log("smart --dry: get in plan = " + SmartPlan()); return 0; }
            return WithNamedLock("Local\\irdeck-getin", "smart", delegate { return SmartGetIn(); });
        }

        static bool StartedRecently(int minutes)
        {
            try
            {
                string[] p = File.ReadAllText(Path.Combine(Root, @"dash\start-mark.txt")).Split('\t');
                long t;
                return long.TryParse(p[0], out t) && t > DateTime.UtcNow.AddMinutes(-minutes).Ticks && t <= DateTime.UtcNow.AddSeconds(5).Ticks;
            }
            catch { return false; }
        }

        static string SmartPlan()
        {
            bool simProc = Process.GetProcessesByName("iRacingSim64DX11").Length > 0;
            bool ui = Process.GetProcessesByName("iRacingUI").Length > 0;
            bool session = SessionActive();
            return DeckRules.GetInPlan(ui, simProc, session, session && OnTrack(), simProc && !session && StartedRecently(4));
        }

        static int SmartGetIn()
        {
            string plan = SmartPlan();
            Log("smart: get in plan = " + plan);
            if (plan == "already") { Log("smart: already in the car"); return 0; }
            if (plan == "go")
            {
                int grc = CmdGo();
                Log(grc == 0 ? "smart: in the car" : "smart: could not get in the car (see the lines above)");
                return grc;
            }
            if (plan == "wait-load")
            {
                Log("smart: iRacing is still loading the session - waiting for it"); Say("wait", "iRacing is loading - getting in when ready");
                for (int i = 0; i < 300 && !SessionActive(); i++) Thread.Sleep(500);
                if (!SessionActive()) { Log("smart: the session did not load - look at the iRacing screen"); return 1; }
                Thread.Sleep(3000);
                int wrc = CmdGo();
                Log(wrc == 0 ? "smart: in the car" : "smart: could not get in the car (see the lines above)");
                return wrc;
            }
            if (plan == "open-then-start")
            {
                Log("smart: the iRacing app is not open - opening the rig first"); Say("wait", "Opening iRacing first");
                int orc = CmdRigOn(new string[0]);
                if (orc != 0) { Log("smart: the rig did not come up - stopped"); return orc; }
                if (SessionActive()) return SmartGetIn();   // a session came up by itself meanwhile
            }
            MdCombo c = MdChosen();
            int rc;
            if (c.Car.Length > 0 && c.Track.Length > 0)
            {
                Log("smart: no session - starting your last drive: " + c.Car + " at " + c.Track);
                rc = MdStart(new string[] { "start" });
            }
            else
            {
                Log("smart: no car and track chosen in MY DRIVE - starting the Test Drive from iRacing's 'Last settings'");
                rc = CmdStartLast(new string[] { "td" });
            }
            Log(rc == 0 ? "smart: in the car" : "smart: the drive did not start (see the lines above)");
            return rc;
        }

        // The old resolver-driven path, now only for tests: `smart --fake <json>` runs the deck-face table without a sim.
        static int SmartFakeRun(string[] args, Snapshot fake, bool dry)
        {
            DeckState s = DeckStateResolver.Resolve(fake);
            if (dry) { Log("smart --dry: " + s.Primary + " | " + s.Label + " | " + (s.Action.Length == 0 ? "none" : s.Action)); return 0; }
            Log("smart: " + s.Primary);
            if (s.Action.Length == 0) return 0;
            if (s.Action == "confirm skip skip")
            {
                int rc;
                if (Array.IndexOf(args, "--fake-bounce") >= 0)
                {
                    Thread bounce = new Thread(delegate() { Thread.Sleep(50); CmdConfirm(new string[] { "skip", "skip" }); });
                    bounce.Start(); rc = CmdConfirm(new string[] { "skip", "skip" }); bounce.Join();
                }
                else rc = CmdConfirm(new string[] { "skip", "skip" });
                return rc;
            }
            return 3;
        }

        // One run at a time for the long keys. A repeat (the deck sends two or three) finds the lock taken and does nothing (rc 4: no beep).
        static int WithNamedLock(string mutexName, string what, Func<int> body)
        {
            Mutex mx = new Mutex(false, mutexName);
            bool mine = false;
            try
            {
                try { mine = mx.WaitOne(0); }
                catch (AbandonedMutexException) { mine = true; }
                if (!mine) { Log(what + ": already in progress"); return 4; }
                return body();
            }
            finally
            {
                if (mine) { try { mx.ReleaseMutex(); } catch { } }
                mx.Dispose();
            }
        }

        static Snapshot SmartFake(string[] args)
        {
            if (args == null) return null;
            int i = Array.IndexOf(args, "--fake");
            if (i < 0 || i + 1 >= args.Length) return null;
            try
            {
                System.Web.Script.Serialization.JavaScriptSerializer json = new System.Web.Script.Serialization.JavaScriptSerializer();
                System.Collections.Generic.Dictionary<string, object> d = json.Deserialize<System.Collections.Generic.Dictionary<string, object>>(args[i + 1]);
                Snapshot s = new Snapshot();
                s.Sim = Convert.ToBoolean(d["sim"], CultureInfo.InvariantCulture);
                s.Ui = Convert.ToBoolean(d["ui"], CultureInfo.InvariantCulture);
                s.Fresh = Convert.ToBoolean(d["fresh"], CultureInfo.InvariantCulture);
                s.Connected = Convert.ToBoolean(d["connected"], CultureInfo.InvariantCulture);
                s.SessionKnown = Convert.ToBoolean(d["sessionKnown"], CultureInfo.InvariantCulture);
                s.OnTrack = Convert.ToBoolean(d["onTrack"], CultureInfo.InvariantCulture);
                s.Speed = Convert.ToDouble(d["speed"], CultureInfo.InvariantCulture);
                s.Replay = Convert.ToBoolean(d["replay"], CultureInfo.InvariantCulture);
                s.TestOrAi = Convert.ToBoolean(d["testOrAi"], CultureInfo.InvariantCulture);
                return s;
            }
            catch { return new Snapshot(); }
        }

        static IntPtr SimWindow()
        {
            foreach (Process p in Process.GetProcessesByName("iRacingSim64DX11"))
                try { if (p.MainWindowHandle != IntPtr.Zero) return p.MainWindowHandle; } catch { }
            return IntPtr.Zero;
        }
        static IntPtr UiWindow() { return IracingUiHandle(); }

        static bool FocusWindow(IntPtr h)
        {
            if (h == IntPtr.Zero) return false;
            if (Native.IsIconic(h)) Native.ShowWindow(h, 9);
            if (Native.GetForegroundWindow() == h) return true;
            Native.keybd_event(0x12, 0, 0, UIntPtr.Zero); Native.keybd_event(0x12, 0, 2, UIntPtr.Zero);   // an Alt tap lets a background process take the foreground
            Native.SetForegroundWindow(h);
            Thread.Sleep(150);
            if (Native.GetForegroundWindow() == h) return true;
            uint pid;
            uint fg = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out pid), me = Native.GetCurrentThreadId();
            Native.AttachThreadInput(me, fg, true); Native.BringWindowToTop(h); Native.SetForegroundWindow(h); Native.AttachThreadInput(me, fg, false);
            Thread.Sleep(150);
            return Native.GetForegroundWindow() == h;
        }

        // The middle race screen, found by position (Windows renumbers monitors after reboots, and the
        // primary monitor is the dashboard screen above the rig, so neither the number nor "primary" works).
        static System.Drawing.Rectangle CentreScreen() { return CentreScreenObj().WorkingArea; }
        // Full bounds of the middle race screen: where the sim draws its session bar and dialogs.
        static System.Drawing.Rectangle SimArea() { return CentreScreenObj().Bounds; }

        static System.Windows.Forms.Screen CentreScreenObj()
        {
            var all = new List<System.Windows.Forms.Screen>(System.Windows.Forms.Screen.AllScreens);
            if (all.Count >= 2)
            {
                // leave out a monitor that sits entirely above the others (the dashboard)
                System.Windows.Forms.Screen top = all[0];
                foreach (var s in all) if (s.Bounds.Y < top.Bounds.Y) top = s;
                bool above = true;
                foreach (var s in all) if (s != top && s.Bounds.Y < top.Bounds.Bottom) above = false;
                if (above) all.Remove(top);
            }
            all.Sort(delegate (System.Windows.Forms.Screen a, System.Windows.Forms.Screen b)
            { return (a.Bounds.X + a.Bounds.Width / 2).CompareTo(b.Bounds.X + b.Bounds.Width / 2); });
            return all[all.Count / 2];
        }

        // Move a window onto the middle race screen and maximise it.
        static void PlaceOnCentre(IntPtr h)
        {
            if (h == IntPtr.Zero) return;
            System.Drawing.Rectangle r = CentreScreen();
            Native.ShowWindow(h, 9);
            Native.SetWindowPos(h, IntPtr.Zero, r.X + 100, r.Y + 100, r.Width - 200, r.Height - 200, 0x0004 | 0x0040);
            Native.ShowWindow(h, 3);
        }

        // ---------- the main flow: GO / GET OUT / QUIT TO MAIN / page keys ----------

        // GO = press whatever the next green button is: the sim's Drive/Test/Race button, or the Test Drive launch in the UI.
        static int CmdGo()
        {
            if (Process.GetProcessesByName("iRacingSim64DX11").Length == 0) { Log("go: sim not running"); return 1; }
            if (SessionActive())
            {
                if (OnTrack()) { Log("go: already in the car"); return 0; }
                FocusWindow(SimWindow());
                DateTime end = DateTime.Now.AddSeconds(40);   // the session screen may still be loading
                int presses = 0;
                while (DateTime.Now < end)
                {
                    int cx, cy, bw;
                    if (FindGreen(out cx, out cy, out bw))
                    {
                        // a press while the session is still loading is ignored, so check the car is really on track
                        Click(cx, cy); presses++;
                        for (int i = 0; i < 16; i++) { Thread.Sleep(500); if (OnTrack()) { Log("go: in the car" + (presses > 1 ? " (press " + presses + ")" : "")); return 0; } }
                        Log("go: pressed the session button but not in the car yet - trying again");
                    }
                    Thread.Sleep(500);
                    if (Native.GetForegroundWindow() != SimWindow()) FocusWindow(SimWindow());
                }
                if (presses > 0) { Log("go: pressed " + presses + " times but the car never went on track"); return 1; }
                Log("go: the sim's green button never appeared (screen saved to " + SaveSimArea("fail-go") + ")");
                return 1;
            }
            return GoUi();
        }

        // SMART may press only the exact Drive control exposed by the sim UI automation tree.
        static bool IsGetInState(DeckState d, bool garageOfTestOrAi)
        {
            return (d.Primary == "GETIN" && d.Action == "drive-only") || (garageOfTestOrAi && d.Primary == "SKIP");
        }

        static int GoDriveOnly(bool garageOfTestOrAi)
        {
            Snapshot before = CurrentDeckSnapshot();
            DeckState beforeState = DeckStateResolver.Resolve(before);
            if (!IsGetInState(beforeState, garageOfTestOrAi) || before.Speed >= 1.0) { Log("smart GET IN: telemetry changed or unsafe; WAIT"); return 3; }
            IntPtr h = SimWindow();
            if (h == IntPtr.Zero) return 3;
            AutomationElement root;
            try { root = AutomationElement.FromHandle(h); } catch { return 3; }
            if (root == null) return 3;
            List<Cand> items = Scan(root);
            Cand drive = null;
            bool garage = false, modalContinue = false;
            foreach (Cand c in items)
            {
                if (!c.Enabled || c.Off) continue;
                if (string.Equals(c.Name, "Drive", StringComparison.OrdinalIgnoreCase) && c.Type == "button")
                { if (drive != null) { Log("smart GET IN: ambiguous Drive controls; WAIT"); return 3; } drive = c; }
                if (string.Equals(c.Name, "Garage", StringComparison.OrdinalIgnoreCase) && c.Type == "button") garage = true;
                if (string.Equals(c.Name, "Continue", StringComparison.OrdinalIgnoreCase) && c.Type == "button") modalContinue = true;
            }
            if (drive == null || !garage || modalContinue || Native.GetForegroundWindow() != h)
            { Log("smart GET IN: session page not verified; WAIT"); return 3; }
            Snapshot last = CurrentDeckSnapshot();
            DeckState lastState = DeckStateResolver.Resolve(last);
            if (!IsGetInState(lastState, garageOfTestOrAi) || last.Speed >= 1.0)
            { Log("smart GET IN: telemetry changed before press; WAIT"); return 3; }
            if (!Press(drive)) return 3;
            Log("smart GET IN: pressed verified Drive control");
            return 0;
        }

        // The UI half of GO: launch an open Test Drive dialog, or press a join/start button if one is showing.
        static int GoUi()
        {
            AutomationElement root = FindUiWindow();
            if (root == null) { Log("go: iRacing UI is not running (press RIG ON)"); return 2; }
            List<Cand> c = Scan(root);
            bool dialog = Pick(c, L("Last settings"), "hyperlink", false) != null && Pick(c, L("Close", "Back"), "hyperlink", false) != null;
            if (dialog) { Cand td = Pick(c, L("Test Drive"), "hyperlink", true); if (td != null) return Press(td) ? 0 : 1; }
            Cand j = Pick(c, L("Join", "Join Session", "Join Race", "Race Now", "Drive", "Start Race", "Start", "Race"), "button", false)
                  ?? Pick(c, L("Race", "Start Race", "Race Now", "Join Race", "Join"), "hyperlink", true);
            if (j != null)
            {
                if (!Press(j)) return 1;
                // a race is launching: wait for the sim, then get in the car
                for (int i = 0; i < 480 && !SessionActive(); i++) Thread.Sleep(500);
                if (!SessionActive()) { Log("go: the session didn't load - check the iRacing UI for an error"); return 1; }
                Thread.Sleep(3000);
                return CmdGo();
            }
            // setup wizards (AI race and others): Continue steps forward; press DRIVE again on the last step
            Cand next = Pick(c, L("Continue"), "hyperlink", true) ?? Pick(c, L("Continue"), "button", true);
            if (next != null) return Press(next) ? 0 : 1;
            Log("go: nothing to start on this screen - open Test Drive or a session first");
            return 1;
        }

        // Wait (200 ms steps, up to limitMs) until the car is under 1 m/s or out of the car. The top screen shows the same
        // "waiting" line as TOW. 0 = stopped / out of the car, 2 = still moving at the limit, 4 = the sim went away.
        static int WaitCarStopped(string tag, int limitMs, ref bool inCar, ref double speed)
        {
            Log(string.Format(CultureInfo.InvariantCulture, "{0}: waiting for the car to stop ({1:0.0} m/s)", tag, speed));
            Say("wait", "Waiting for the car to stop");
            TowWaitFlag(true);
            try
            {
                Stopwatch sw = Stopwatch.StartNew();
                while (true)
                {
                    int d = DeckRules.StopWait(inCar, speed, (int)sw.ElapsedMilliseconds, limitMs);
                    if (d == 0) { Log(string.Format(CultureInfo.InvariantCulture, "{0}: the car has stopped ({1:0.0} m/s)", tag, speed)); return 0; }
                    if (d == 2) { Log(string.Format(CultureInfo.InvariantCulture, "{0}: still moving after {1} s ({2:0.0} m/s)", tag, limitMs / 1000, speed)); return 2; }
                    TowWaitFlag(true);
                    Thread.Sleep(200);
                    Tele n = Tele.Open();
                    if (n == null) { Log(tag + ": the sim left while waiting"); return 4; }
                    using (n) { inCar = n.Bool("IsOnTrack"); speed = n.Num("Speed"); }
                }
            }
            finally { TowWaitFlag(false); }
        }

        // Hold Esc to get out of the car. A moving car is waited for (up to 15 s) until it is nearly stopped, so it can never
        // reset you at speed and Peter does not have to time his press.
        static int CmdGetOut()
        {
            Tele t = Tele.Open();
            if (t == null) { Log("getout: no sim session running"); return 3; }
            bool inCar; double speed;
            using (t) { inCar = t.Bool("IsOnTrack"); speed = t.Num("Speed"); }
            if (!inCar) { Log("getout: you are not in the car"); return 0; }
            if (speed > 1.0)
            {
                // GET OUT used to refuse while the car still rolled (10 of 41 presses, 1-37 m/s): wait for it to stop instead
                int w = WaitCarStopped("getout", DeckRules.StopWaitMs, ref inCar, ref speed);
                if (w != 0) { Log(string.Format(CultureInfo.InvariantCulture, "getout refused: the car is still moving ({0:0.0} m/s) after {1} s - slow down and press again", speed, DeckRules.StopWaitMs / 1000)); return 3; }
                if (!inCar) { Log("getout: you are not in the car"); return 0; }
            }
            if (!FocusWindow(SimWindow())) { Log("getout: could not bring the sim to the front"); return 3; }
            SendCombo("esc", 1800);
            Log("getout: held Esc");
            return 0;
        }

        // Page keys (Home, Official, Test Drive...): press it in the UI, then show the UI unless you're driving.
        static int CmdNav(string[] a)
        {
            List<string> args = new List<string>();
            args.Add(Array.IndexOf(a, "--button") >= 0 ? "--type=button" : "--type=hyperlink");
            foreach (string t in a) if (t != "--button") args.Add(t);
            if (UiWindow() == IntPtr.Zero) { Log("nav: iRacing UI is not running (press RIG ON)"); return 2; }
            int rc = CmdUi(args.ToArray(), false);
            if (rc != 0 && Array.IndexOf(a, "--button") >= 0)
            {
                // iRacing's UI is not consistent about what a sidebar entry is: OFFICIAL is a Hyperlink there, not a Button
                // ("not found: Official (type=button)", 21 Oct). Same exact name, as a Hyperlink or a TabItem.
                List<string> names = new List<string>();
                foreach (string t in a) if (t != "--button" && !t.StartsWith("--")) names.Add(t);
                // Never for "Test Drive": inside its dialog the Hyperlink of that name is the LAUNCH link, so a missing sidebar button must not start a drive.
                if (names.Exists(delegate (string n) { return n.Trim().Equals("Test Drive", StringComparison.OrdinalIgnoreCase); })) names.Clear();
                if (names.Count > 0)
                foreach (string alt in new string[] { "hyperlink", "tabitem" })
                {
                    List<string> again = new List<string>(); again.Add("--type=" + alt); again.AddRange(names); again.Add("--timeout=2500");
                    if (CmdUi(again.ToArray(), false) == 0) { Log("nav: '" + string.Join(" | ", names.ToArray()) + "' is a " + alt + " in this iRacing, not a button - pressed it"); rc = 0; break; }
                }
            }
            if (rc == 0 && !OnTrack()) FocusWindow(UiWindow());
            return rc;
        }

        // RESTART: there is no iRacing command for it, so quit the session and relaunch the same one
        // ("Last settings"), then get back in the car. Test drives and AI races only.
        static int CmdRestart(string[] a)
        {
            bool dry = Array.IndexOf(a, "--dry") >= 0;
            Tele t = Tele.Open();
            if (t == null) { Log("restart: no session running"); return 3; }
            string info; using (t) { info = t.SessionInfo(); }
            bool test = System.Text.RegularExpressions.Regex.IsMatch(info, @"EventType:\s*Test");
            bool ai = System.Text.RegularExpressions.Regex.IsMatch(info, @"CarIsAI:\s*1");
            System.Text.RegularExpressions.Match ev = System.Text.RegularExpressions.Regex.Match(info, @"EventType:\s*(\S+)");
            Log("restart: event type " + (ev.Success ? ev.Groups[1].Value : "?") + ", AI cars " + ai);
            if (!test && !ai) { Log("restart: only test drives and AI races can be restarted"); return 3; }
            if (dry) { Log("restart (dry): would quit and relaunch the " + (test ? "test drive" : "AI race")); return 0; }
            int rc = CmdQuitMain();
            if (rc != 0) { Log("restart: quit didn't finish, not relaunching"); return rc; }
            Thread.Sleep(1500);
            if (test)
            {
                CmdNav(new string[] { "--button", "Test Drive" });
                Thread.Sleep(1500);
                CmdUi(new string[] { "--type=hyperlink", "Last settings", "--timeout=6000" }, false);
                Thread.Sleep(800);
                rc = CmdTestDrive(new string[0]);
                if (rc != 0) return rc;
            }
            else
            {
                CmdAiRace(new string[] { "start" });
                Thread.Sleep(1500);
                CmdUi(new string[] { "--type=hyperlink", "Last Settings", "--timeout=6000" }, false);
                Thread.Sleep(2500);
                if (!SessionActive()) GoUi();   // in case Last Settings opens a setup screen with a start button
            }
            for (int i = 0; i < 240 && !SessionActive(); i++) Thread.Sleep(500);
            if (!SessionActive()) { Log("restart: the new session didn't load"); return 1; }
            Thread.Sleep(3000);
            return CmdGo();
        }

        // ---------- one-press sequences (2026-10 deck) ----------

        static int UiPress(string label)
        {
            int rc = CmdUi(new string[] { "--type=hyperlink", label, "--timeout=6000" }, false);
            if (rc != 0) rc = CmdUi(new string[] { "--type=button", label, "--timeout=3000" }, false);
            return rc;
        }

        // AI RACE > / TEST DRIVE > : last settings, load, then into the car. "startlast ai" or "startlast td" ("--dry": say what it would do).
        // While a session runs this key does nothing (2026-10-10, C-31): it used to quit the session on a second press,
        // and the deck can send one press twice. Ending a session is QUIT x2 or RESTART x2, on purpose.
        static int CmdStartLast(string[] a)
        {
            bool ai = a.Length > 0 && a[0].ToLowerInvariant() == "ai";
            bool dry = Array.IndexOf(a, "--dry") >= 0;
            string id = ai ? "start-ai" : "start-td";
            if (SessionActive())
            {
                Log(id + ": a session is running - nothing was done (use QUIT x2 first)");
                return 3;   // short beep: the key was received, nothing happened
            }
            if (dry) { Log(id + " (dry): no session is running; would open " + (ai ? "AI Single Player" : "Test Drive") + " > Last settings and start it"); return 0; }
            if (UiWindow() == IntPtr.Zero) { Log(id + ": iRacing UI is not running (press RIG ON)"); return 2; }
            MarkStart(id);   // irdash times START -> session -> in the car (dash\timings.tsv)
            if (ai)
            {
                return CmdAiRace(new string[] { "start" });
            }
            else
            {
                UiFront();
                CmdNav(new string[] { "--button", "Test Drive" });
                Thread.Sleep(1500);
                UiFront();
                UiPress("Last settings");
                Thread.Sleep(800);
                int rc = CmdTestDrive(new string[0]);
                if (rc != 0) return rc;
            }
            for (int i = 0; i < 480 && !SessionActive(); i++) Thread.Sleep(500);   // the sim can take a few minutes to load
            if (!SessionActive()) { Log(id + ": the session didn't load - check the iRacing UI for an error"); return 1; }
            Thread.Sleep(3000);
            return CmdGo();
        }

        // TOW TO PITS: get out, then back in at the pit box. Instant in practice; races add iRacing's tow time.
        // A press right after a crash used to refuse while the car was still sliding. Now it waits (about 20 s,
        // reading Speed) and does that same tow once the car is nearly stopped. The stopped-car steps below are unchanged.
        const int TowPollMs = 250;     // how often Speed is read while waiting
        const int TowLimitMs = 20000;  // then give up quietly

        // 0 = stopped, or already out of the car: do the tow. 1 = still moving, keep waiting. 2 = time is up.
        static int TowWaitDecision(bool inCar, double speed, int elapsedMs)
        {
            if (!inCar || speed <= 1.0) return 0;
            if (elapsedMs >= TowLimitMs) return 2;
            return 1;
        }

        // The top screen reads dash\tow-wait.txt (a UTC expiry). Cleared as soon as the wait ends.
        static void TowWaitFlag(bool on)
        {
            string p = Path.Combine(Root, @"dash\tow-wait.txt");
            try
            {
                if (!on) { if (File.Exists(p)) File.Delete(p); return; }
                Directory.CreateDirectory(Path.GetDirectoryName(p));
                File.WriteAllText(p, DateTime.UtcNow.AddSeconds(30).Ticks.ToString(CultureInfo.InvariantCulture));
            }
            catch { }
        }

        // One tow at a time. A second press (the deck sends two or three) finds this taken and does nothing.
        // The tow key also holds its own key mutex for the whole press; this covers RESET CAR and MY DRIVE, which start irdeck with arguments.
        static int WithTowLock(Func<int> body)
        {
            Mutex mx = new Mutex(false, "Local\\irdeck-tow");
            bool mine = false;
            try
            {
                try { mine = mx.WaitOne(0); }
                catch (AbandonedMutexException) { mine = true; }
                if (!mine) { Log("tow: already in progress"); return 4; }
                return body();
            }
            finally
            {
                if (mine) { try { mx.ReleaseMutex(); } catch { } }
                mx.Dispose();
            }
        }

        static int CmdTow() { return CmdTow(new string[0]); }

        static int CmdTow(string[] args)
        {
            string list; int hold;
            if (TowPretendArgs(args, out list, out hold)) return TowPretend(list, hold);
            return WithTowLock(delegate { return CmdTowBody(); });
        }

        // Offline only: tow --pretend 12,8,0.4 [--hold ms]. Each number is one Speed sample, TowPollMs apart. No sim and no keys.
        static bool TowPretendArgs(string[] args, out string list, out int hold)
        {
            list = "";
            hold = 0;
            if (args == null || args.Length == 0) return false;
            bool on = false;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--pretend")
                {
                    on = true;
                    if (i + 1 < args.Length && !args[i + 1].StartsWith("--")) list = args[++i];
                }
                else if (args[i] == "--hold" && i + 1 < args.Length)
                {
                    int h;
                    if (int.TryParse(args[++i], NumberStyles.Integer, CultureInfo.InvariantCulture, out h) && h > 0) hold = h;
                }
            }
            if (hold > 10000) hold = 10000;
            return on;
        }

        static int TowPretend(string list, int hold)
        {
            var speeds = new List<double>();
            foreach (string p in (list ?? "").Split(','))
            {
                double v;
                if (double.TryParse(p.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out v)) speeds.Add(v);
            }
            if (speeds.Count == 0) { Log("tow: pretend needs speeds"); return 1; }
            return WithTowLock(delegate { return TowPretendBody(speeds, hold); });
        }

        static int TowPretendBody(List<double> speeds, int hold)
        {
            if (TowWaitDecision(true, speeds[0], 0) == 0) { Log("tow: stationary"); return 0; }
            Log(string.Format(CultureInfo.InvariantCulture, "tow: waiting for the car to stop ({0:0.0} m/s)", speeds[0]));
            TowWaitFlag(true);
            try
            {
                if (hold > 0) Thread.Sleep(hold);
                for (int i = 0; i < speeds.Count; i++)
                {
                    int d = TowWaitDecision(true, speeds[i], i * TowPollMs);
                    if (d == 0)
                    {
                        Log(string.Format(CultureInfo.InvariantCulture, "tow: the car has stopped ({0:0.0} m/s)", speeds[i]));
                        Log("tow: would tow now");
                        return 0;
                    }
                    if (d == 2)
                    {
                        Log(string.Format(CultureInfo.InvariantCulture, "tow: still moving after 20 s ({0:0.0} m/s), leaving it", speeds[i]));
                        return 4;
                    }
                }
                Log("tow: pretend ended while still waiting");
                return 4;
            }
            finally { TowWaitFlag(false); }
        }

        // Poll Speed until the car is nearly stopped. Shows one line on the top screen the whole time.
        static int TowWaitLive(ref bool inCar, ref double speed)
        {
            Log(string.Format(CultureInfo.InvariantCulture, "tow: waiting for the car to stop ({0:0.0} m/s)", speed));
            TowWaitFlag(true);
            try
            {
                Stopwatch sw = Stopwatch.StartNew();
                while (true)
                {
                    int d = TowWaitDecision(inCar, speed, (int)sw.ElapsedMilliseconds);
                    if (d == 0)
                    {
                        Log(string.Format(CultureInfo.InvariantCulture, "tow: the car has stopped ({0:0.0} m/s)", speed));
                        return 0;
                    }
                    if (d == 2)
                    {
                        Log(string.Format(CultureInfo.InvariantCulture, "tow: still moving after 20 s ({0:0.0} m/s), leaving it", speed));
                        return 4;
                    }
                    TowWaitFlag(true);
                    Thread.Sleep(TowPollMs);
                    Tele n = Tele.Open();
                    if (n == null) { Log("tow: the sim left, leaving it"); return 4; }
                    using (n) { inCar = n.Bool("IsOnTrack"); speed = n.Num("Speed"); }
                }
            }
            finally { TowWaitFlag(false); }
        }

        static int CmdTowBody()
        {
            Tele t = Tele.Open();
            if (t == null) { Log("tow: no sim session running"); return 3; }
            bool inCar; double speed;
            using (t) { inCar = t.Bool("IsOnTrack"); speed = t.Num("Speed"); }
            if (inCar && speed > 1.0)
            {
                int w = TowWaitLive(ref inCar, ref speed);
                if (w != 0) return w;
            }
            if (inCar)
            {
                if (speed > 1.0) { Log(string.Format(CultureInfo.InvariantCulture, "tow refused: the car is moving ({0:0.0} m/s)", speed)); return 3; }
                if (!FocusWindow(SimWindow())) { Log("tow: could not bring the sim to the front"); return 3; }
                SendCombo("esc", 1800);
                for (int i = 0; i < 40 && OnTrack(); i++) Thread.Sleep(250);
                Thread.Sleep(1500);
            }
            int rcGo = CmdGo();
            if (rcGo == 0) { SessSnap n = Snap(); Log("tow: " + (n.OnTrack ? "back in the car" : "NOT in the car") + (n.OnPit ? " in the pits" : " (not on pit road)")); }
            return rcGo;
        }

        // Offsets of the AI session bar's Prev / Next buttons from the green button centre (measured at a 478 px
        // wide green button), saved in irdeck.prevnext as "prevX,prevY,nextX,nextY" once measured.
        static int[] PrevNext()
        {
            try
            {
                string[] p = File.ReadAllText(Path.Combine(Root, "irdeck.prevnext")).Trim().Split(',');
                if (p.Length == 4) return new int[] { int.Parse(p[0]), int.Parse(p[1]), int.Parse(p[2]), int.Parse(p[3]) };
            }
            catch { }
            return null;
        }

        static bool IsAiSession(out string info)
        {
            info = "";
            Tele t = Tele.Open();
            if (t == null) return false;
            using (t) { info = t.SessionInfo(); }
            return System.Text.RegularExpressions.Regex.IsMatch(info, @"CarIsAI:\s*1");
        }

        // Click Prev (-1) or Next (+1) on the AI session bar. Gets out of a stopped car first.
        static int ClickPrevNext(int which, string tag)
        {
            int[] o = PrevNext();
            if (o == null) return -1;
            bool inCar = false; double speed = 0;
            Tele t = Tele.Open();
            if (t != null) using (t) { inCar = t.Bool("IsOnTrack"); speed = t.Num("Speed"); }
            if (inCar && speed > 1.0)
            {
                // wait for a rolling car to stop (15 s) instead of refusing: one press has to finish the job
                int w = WaitCarStopped(tag, DeckRules.StopWaitMs, ref inCar, ref speed);
                if (w != 0) { Log(tag + " refused: the car is still moving"); return 3; }
            }
            if (!FocusWindow(SimWindow())) { Log(tag + ": could not bring the sim to the front"); return 3; }
            if (inCar) { SendCombo("esc", 1800); for (int i = 0; i < 40 && OnTrack(); i++) Thread.Sleep(250); }
            if (inCar) Thread.Sleep(1200);   // the bar slides in
            int cx, cy; double s; bool green;
            BarAnchor(out cx, out cy, out s, out green);
            int dx = which < 0 ? o[0] : o[2], dy = which < 0 ? o[1] : o[3];
            EnsureBar(cx, cy, s);
            ShotSim(tag + "-bar");
            Click(cx + (int)Math.Round(dx * s), cy + (int)Math.Round(dy * s));
            Log(tag + ": clicked " + (which < 0 ? "Prev" : "Next") + (green ? "" : " (bar found by its fixed place: no coloured button showing)"));
            return 0;
        }

        // RESTART RACE: AI races press Prev on the session bar (the sim asks "Restart Session?": confirmed), wait until the
        // session really started over, then Drive. Until Prev is measured, it relaunches the whole event from last settings.
        //
        // ONE press does the whole job (the deck key is `confirm restart-race restartrace`, which now runs this at once): from any state
        // it ends with Peter in the car of the restarted session. A car that still rolls is waited for (like GET OUT), not refused.
        static int CmdRestartRace()
        {
            return WithNamedLock("Local\\irdeck-restartrace", "restartrace", delegate { return CmdRestartRaceBody(); });
        }

        static int CmdRestartRaceBody()
        {
            if (!SessionActive()) { Log("restartrace: no session is running - nothing to restart (GET IN starts one)"); return 3; }
            string info;
            bool ai = IsAiSession(out info);
            if (System.Text.RegularExpressions.Regex.IsMatch(info, @"EventType:\s*Test"))
            {
                // test drive: tow back to the pits (it waits for a rolling car), then make sure Peter is in the car
                Log("restartrace: Test Drive - back to the pits and into the car");
                int trc = CmdTow();
                if (trc == 0 && SessionActive() && !OnTrack()) trc = CmdGo();
                if (trc == 0) Log(OnTrack() ? "restart: test drive - back in the car in the pits" : "restart: NOT in the car yet");   // own words: the top screen says "Back in the pits", not "Race restarted"
                return trc;
            }
            if (!ai) { Log("restartrace: only AI races can be restarted - use TOW TO PITS"); return 3; }
            // a rolling car is waited for (up to 15 s), the same as GET OUT
            bool inCar = false; double speed = 0;
            Tele t0 = Tele.Open();
            if (t0 != null) using (t0) { inCar = t0.Bool("IsOnTrack"); speed = t0.Num("Speed"); }
            if (inCar && speed > 1.0)
            {
                int w = WaitCarStopped("restartrace", DeckRules.StopWaitMs, ref inCar, ref speed);
                if (w != 0) { Log("restartrace refused: the car is still moving - slow down and press again"); return 3; }
            }
            int rc;
            if (PrevNext() != null)
            {
                SessSnap s0 = Snap();
                rc = ClickPrevNext(-1, "restartrace");
                if (rc != 0) return rc;
                Func<bool> restarted = delegate { SessSnap n = Snap(); return n.Live && (n.Time < s0.Time - 3 || n.Num != s0.Num); };
                ConfirmDialogs(restarted, 8000, "restartrace");
                for (int i = 0; i < 40 && !restarted(); i++) Thread.Sleep(500);
                if (!restarted()) { Log("restartrace: the session did not start over (screen saved to " + SaveSimArea("fail-restartrace") + ")"); return 1; }
                Log("restartrace: the session started over");
                Thread.Sleep(2500);
                rc = CmdGo();
            }
            else
            {
                Log("restartrace: Prev button not measured yet - relaunching the event from last settings");
                rc = CmdRestart(new string[0]);
            }
            if (rc == 0) Log(OnTrack() ? "restart: back in the car" : "restart: NOT in the car yet");
            return rc;
        }

        // SKIP: AI races press Next on the session bar and confirm the sim's "Skip to Next Session?"; other sessions you host
        // use the admin command. Done when the sim is really in the next session (SessionNum moved on) or has left the event.
        static int CmdSkip()
        {
            if (!SessionActive()) { Log("skip: no session is running"); return 3; }
            SessSnap s0 = Snap();
            bool testSession = System.Text.RegularExpressions.Regex.IsMatch(s0.Info, @"EventType:\s*Test");
            if (!s0.Ai && !testSession) { Log("skip refused: official sessions cannot be skipped"); return 3; }
            if (s0.OnTrack && s0.Speed > 1.0)
            {
                // wait for a rolling car (15 s) like GET OUT, instead of refusing (NEXT SESSION was the last key that still refused)
                bool inCar = s0.OnTrack; double speed = s0.Speed;
                if (WaitCarStopped("skip", DeckRules.StopWaitMs, ref inCar, ref speed) != 0) { Log("skip refused: the car is still moving - slow down and press again"); return 3; }
                s0 = Snap();
            }
            // A Test Drive is ONE session: the Prev / Next buttons on its screen pick the DRIVER (replay camera), so the old click did
            // nothing and Peter's SKIP SESSION 'never worked' (live 2026-10-19). 'Skip' there means 'finish this and go back to the menu',
            // the same as QUIT, which is what he wants next after a test drive.
            if (testSession && !s0.Ai) { Log("skip: a Test Drive has no next session - ending it and going back to the menu (like QUIT)"); return CmdQuitMain(); }
            // An AI Qualify sometimes ignores the first Next (iRacing then moves you to the race grid on the next one):
            // if nothing moved after 10 s, click Next once more and give it up to 40 s.
            bool qualify = DeckRules.IsQualify(s0.Type);
            int clicks = 0;
            Stopwatch sinceClick = Stopwatch.StartNew();
            Func<bool> advanced = delegate { SessSnap n = Snap(); return !n.Live || n.Num != s0.Num; };
            if (PrevNext() != null)
            {
                int rc = ClickPrevNext(1, "skip");
                if (rc != 0) return rc;
                clicks = 1; sinceClick.Reset(); sinceClick.Start();
                ConfirmDialogs(advanced, 8000, "skip");
            }
            else { Log("skip refused: no verified next-session control"); return 3; }
            DateTime end = DateTime.Now.AddSeconds(40);
            while (DateTime.Now < end)
            {
                SessSnap n = Snap();
                if (!n.Live) { Log("skip: the event is over, the sim left"); return 0; }
                if (n.Num != s0.Num) { Log("skip: now in session " + n.Num + " (" + n.Type + ")" + (clicks > 1 ? " - the second Next did it" : " - the first Next did it")); return 0; }
                if (DeckRules.SecondNextDue(qualify, clicks, (int)sinceClick.ElapsedMilliseconds, false))
                {
                    Log("skip: Qualify did not move on within 10 s - clicking Next once more");
                    int rc2 = ClickPrevNext(1, "skip");
                    if (rc2 != 0) return rc2;
                    clicks = 2; sinceClick.Reset(); sinceClick.Start();
                    ConfirmDialogs(advanced, 8000, "skip");
                    end = DateTime.Now.AddSeconds(40);
                    continue;
                }
                Thread.Sleep(500);
            }
            Log("skip: the session did not advance after " + clicks + " Next click" + (clicks == 1 ? "" : "s") + " (screen saved to " + SaveSimArea("fail-skip") + ")");
            return 1;
        }

        // RACE NOW: from practice or qualify of an AI race, skip ahead (at most 3 session skips) until the session is the race,
        // then get in the car. A rolling car is waited for first. Test drives have no race; official sessions cannot be skipped.
        static int CmdRaceNow()
        {
            return WithNamedLock("Local\\irdeck-racenow", "racenow", delegate { return CmdRaceNowBody(); });
        }

        static int CmdRaceNowBody()
        {
            if (!SessionActive()) { Log("racenow: no session is running"); return 3; }
            SessSnap s = Snap();
            if (!s.Ai) { Log("racenow: only an AI race can be fast-forwarded to its race (a Test Drive has no race, official sessions cannot be skipped)"); return 3; }
            if (!DeckRules.IsRaceType(s.Type))
            {
                if (s.OnTrack && s.Speed > 1.0)
                {
                    bool inCar = s.OnTrack; double speed = s.Speed;
                    if (WaitCarStopped("racenow", DeckRules.StopWaitMs, ref inCar, ref speed) != 0) { Log("racenow refused: the car is still moving - slow down and press again"); return 3; }
                }
                for (int hop = 1; hop <= DeckRules.RaceHopsMax && !DeckRules.IsRaceType(s.Type); hop++)
                {
                    Log("racenow: " + (s.Type.Length > 0 ? s.Type : "this session") + " - skipping to the next session (" + hop + " of up to " + DeckRules.RaceHopsMax + ")"); if (hop == 1) Say("wait", "Skipping to the race");
                    int rc = CmdSkip();
                    if (rc != 0) { Log("racenow: the skip did not work - stopped"); return rc; }
                    s = Snap();
                    if (!s.Live) { Log("racenow: the event is over, the sim left"); return 0; }
                }
                if (!DeckRules.IsRaceType(s.Type)) { Log("racenow: still in " + (s.Type.Length > 0 ? s.Type : "an unknown session") + " after " + DeckRules.RaceHopsMax + " skips - stopped"); return 1; }
                Thread.Sleep(2500);
            }
            else Log("racenow: already in the race session");
            int grc = CmdGo();
            if (grc == 0) Log(OnTrack() ? "racenow: in the race, in the car" : "racenow: the race session is up but you are NOT in the car yet");
            return grc;
        }
        // Pit toggles from the live pit-service flags: tires (all four), fr (fast repair), ws (tear-off).
        static int CmdPitToggle(string[] a)
        {
            string what = a.Length > 0 ? a[0].ToLowerInvariant() : "";
            Tele t = Tele.Open();
            if (t == null) { Log("pittoggle: no sim session running"); return 3; }
            int flags; bool inCar;
            using (t) { flags = (int)t.Num("PitSvFlags"); inCar = t.Bool("IsOnTrack"); }
            if (!inCar) { Log("pittoggle: iRacing only takes pit commands while you are in the car"); return 3; }
            switch (what)
            {
                case "tires":
                    if ((flags & 0x0F) == 0x0F) { Bcast(9, 7, 0); Log("pit: tyre change off"); }
                    else { foreach (int i in new int[] { 3, 4, 5, 6 }) { Bcast(9, i, 0); Thread.Sleep(25); } Log("pit: all four tyres on"); }
                    break;
                case "fr":
                    if ((flags & 0x40) != 0) { Bcast(9, 10, 0); Log("pit: fast repair off"); } else { Bcast(9, 8, 0); Log("pit: fast repair on"); }
                    break;
                case "ws":
                    if ((flags & 0x20) != 0) { Bcast(9, 9, 0); Log("pit: tear-off off"); } else { Bcast(9, 1, 0); Log("pit: tear-off on"); }
                    break;
                default: Log("pittoggle: need tires|fr|ws"); return 1;
            }
            return 0;
        }

        // REPLAY: out of the car, jump to your last incident; press again to go back to live.
        static int CmdReplayIncident()
        {
            Tele t = Tele.Open();
            if (t == null) { Log("replay: no sim session running"); return 3; }
            bool inCar, replay;
            using (t) { inCar = t.Bool("IsOnTrack"); replay = t.Bool("IsReplayPlaying"); }
            if (inCar) { Log("replay: get out of the car first"); return 3; }
            if (replay) { Bcast(5, 1, 0); Thread.Sleep(100); Bcast(3, 1, 0); Log("replay: back to live"); }
            else { Bcast(5, 8, 0); Thread.Sleep(100); Bcast(3, 1, 0); Log("replay: jumped to the last incident"); }
            return 0;
        }

        // OVERLAYS: race-screen overlays off (closes irdashies) / on (starts it again).
        static int CmdOverlays()
        {
            Process[] running = Process.GetProcessesByName("irdashies");
            if (running.Length > 0)
            {
                foreach (Process p in running) { try { p.Kill(); } catch { } }
                Log("overlays: off");
                return 0;
            }
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "irdashies");
            string[] apps = Directory.Exists(root) ? Directory.GetDirectories(root, "app-*") : new string[0];
            if (apps.Length == 0) { Log("overlays: irdashies is not installed"); return 1; }
            Array.Sort(apps, delegate (string x, string y) { return new Version(Path.GetFileName(y).Substring(4)).CompareTo(new Version(Path.GetFileName(x).Substring(4))); });
            ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(apps[0], "irdashies.exe"));
            psi.UseShellExecute = true; psi.WorkingDirectory = apps[0];
            Process.Start(psi);
            Log("overlays: on");
            return 0;
        }

        // Saves the top of the middle race screen to calib.png, used to measure the session bar's buttons.
        static int CmdCapture()
        {
            System.Drawing.Rectangle a = SimArea();
            using (System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(a.Width, 400))
            {
                using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen(a.X, a.Y, 0, 0, bmp.Size);
                bmp.Save(Path.Combine(Root, "calib.png"), System.Drawing.Imaging.ImageFormat.Png);
            }
            int cx, cy, bw;
            if (FindGreen(out cx, out cy, out bw)) Log("capture: green button centre " + (cx - a.X) + "," + (cy - a.Y) + " width " + bw);
            else Log("capture: saved, but no green button on screen");
            return 0;
        }

        // AI RACE: AI Single Player page, then its "Single Race" chooser (Last Settings / New Race).
        static int CmdAiRace(string[] args)
        {
            return CmdAirace(args);
        }

        // ---------- audio / media / FFB ----------

        static void Vk(ushort vk, bool up, bool ext)
        {
            INPUT[] i = new INPUT[1];
            i[0].type = 1; i[0].u.ki.wVk = vk;
            i[0].u.ki.dwFlags = (ext ? 0x0001u : 0u) | (up ? 0x0002u : 0u);
            Native.SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
        }
        static void TapVk(ushort vk) { Vk(vk, false, true); Thread.Sleep(30); Vk(vk, true, true); }

        static int CmdMedia(string[] a)
        {
            string c = a.Length > 0 ? a[0].ToLowerInvariant() : "";
            switch (c)
            {
                case "volup": TapVk(0xAF); TapVk(0xAF); break;     // 2 steps = 4%
                case "voldown": TapVk(0xAE); TapVk(0xAE); break;
                case "mute": TapVk(0xAD); break;
                case "playpause": TapVk(0xB3); break;
                case "next": TapVk(0xB0); break;
                case "prev": TapVk(0xB1); break;
                default: Log("media: unknown " + c); return 1;
            }
            Log("media " + c);
            return 0;
        }

        // appvol game|music +10 / -10 : change just that app's volume in the Windows mixer, on every output device.
        // "game" = the sim, its menu app and the spotter (CrewChief), so VOL - / VOL + on the deck move them together.
        // "--dry" only counts what it would change (tests\keys-test.ps1).
        // MUTE SPOTTER (deck v2): one press mutes CrewChief's voice in the Windows mixer, the next press brings it back.
        // Only that program's own mixer entry is touched; the sim, music and the PC volume stay as they are.
        static int AppMuteToggle(string who)
        {
            string proc = who.Equals("spotter", StringComparison.OrdinalIgnoreCase) ? "CrewChiefV4" : who;
            int touched = 0; bool nowMuted = false;
            try
            {
                IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
                IMMDeviceCollection devs; if (en.EnumAudioEndpoints(0, 1, out devs) != 0) throw new Exception("no audio devices");
                int n; devs.GetCount(out n); Guid iid = typeof(IAudioSessionManager2).GUID;
                bool decided = false, target = true;
                for (int i = 0; i < n; i++)
                {
                    IMMDevice dev; if (devs.Item(i, out dev) != 0) continue;
                    object o; if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) continue;
                    IAudioSessionEnumerator se; if (((IAudioSessionManager2)o).GetSessionEnumerator(out se) != 0) continue;
                    int cnt; se.GetCount(out cnt);
                    for (int j = 0; j < cnt; j++)
                    {
                        IAudioSessionControl2 ctl; if (se.GetSession(j, out ctl) != 0) continue;
                        uint pid; ctl.GetProcessId(out pid);
                        string pn = ""; try { pn = Process.GetProcessById((int)pid).ProcessName; } catch { }
                        if (!proc.Equals(pn, StringComparison.OrdinalIgnoreCase)) continue;
                        ISimpleAudioVolume v = (ISimpleAudioVolume)ctl;
                        if (!decided) { bool m; v.GetMute(out m); target = !m; decided = true; }   // every entry of the program follows the first one
                        Guid g = Guid.Empty; v.SetMute(target, ref g); touched++; nowMuted = target;
                    }
                }
            }
            catch (Exception ex) { Log("appvol mute error: " + ex.Message); return 1; }
            if (touched == 0) { Log("appvol mute: " + proc + " is not making sound right now"); return 3; }
            Log("appvol mute: " + proc + (nowMuted ? " muted" : " sound back on") + " (" + touched + " session(s))");
            return 0;
        }
        static int CmdAppVol(string[] a)
        {
            if (a.Length < 2) { Log("appvol: need game|music and a step like +10"); return 1; }
            string which = a[0].ToLowerInvariant();
            if (which == "mute") return AppMuteToggle(a[1]);
            bool dry = Array.IndexOf(a, "--dry") >= 0;
            double step = double.Parse(a[1], CultureInfo.InvariantCulture) / 100.0;
            string[] procs = which == "game" ? new string[] { "iRacingSim64DX11", "iRacingUI", "CrewChiefV4" } : which == "music" ? new string[] { "Spotify" } : new string[] { a[0] };
            int touched = 0; float last = -1;
            try
            {
                IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
                IMMDeviceCollection devs;
                if (en.EnumAudioEndpoints(0, 1, out devs) != 0) throw new Exception("no audio devices");
                int n; devs.GetCount(out n);
                Guid iid = typeof(IAudioSessionManager2).GUID;
                for (int i = 0; i < n; i++)
                {
                    IMMDevice dev; if (devs.Item(i, out dev) != 0) continue;
                    object o; if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) continue;
                    IAudioSessionEnumerator se; if (((IAudioSessionManager2)o).GetSessionEnumerator(out se) != 0) continue;
                    int cnt; se.GetCount(out cnt);
                    for (int j = 0; j < cnt; j++)
                    {
                        IAudioSessionControl2 ctl; if (se.GetSession(j, out ctl) != 0) continue;
                        uint pid; ctl.GetProcessId(out pid);
                        string pn = ""; try { pn = Process.GetProcessById((int)pid).ProcessName; } catch { }
                        bool match = false; foreach (string p in procs) if (p.Equals(pn, StringComparison.OrdinalIgnoreCase)) match = true;
                        if (!match) continue;
                        ISimpleAudioVolume v = (ISimpleAudioVolume)ctl;
                        float cur; v.GetMasterVolume(out cur);
                        float nv = (float)Math.Max(0.0, Math.Min(1.0, cur + step));
                        if (!dry) { Guid g = Guid.Empty; v.SetMasterVolume(nv, ref g); }
                        touched++; last = nv;
                    }
                }
            }
            catch (Exception ex) { Log("appvol error: " + ex.Message); return 1; }
            if (dry) { Log("appvol " + which + " (dry): " + string.Join("/", procs) + " - " + touched + " audio session(s) right now, nothing changed"); return 0; }
            if (touched == 0) { Log("appvol " + which + ": no audio from " + string.Join("/", procs) + " right now"); return 1; }
            Log(string.Format(CultureInfo.InvariantCulture, "appvol {0}: {1:0}% ({2} session(s))", which, last * 100, touched));
            return 0;
        }

        // dash <command> [--dry] : a deck key that irdash does itself (dash tvview = TV VIEW, dash vkkeep = KEEP LAP). irdash keeps the
        // list of what it accepts (/api/do) and answers no when it cannot, e.g. KEEP LAP with no session: that is a short beep here.
        static int CmdDash(string[] a)
        {
            string c = a.Length > 0 ? a[0].ToLowerInvariant() : "";
            if (!System.Text.RegularExpressions.Regex.IsMatch(c, "^[a-z]{3,20}$")) { Log("dash: need a command like tvview or vkkeep"); return 1; }
            bool dry = Array.IndexOf(a, "--dry") >= 0;
            try
            {
                using (var wc = new System.Net.WebClient())
                {
                    wc.Proxy = null;   // no proxy lookup: it adds seconds
                    if (dry) { wc.DownloadString("http://127.0.0.1:8199/tv"); Log("dash " + c + " (dry): irdash answers, nothing was pressed"); return 0; }
                    wc.DownloadString("http://127.0.0.1:8199/api/do?c=" + c);
                }
                Log("dash " + c + ": done");
                return 0;
            }
            catch (System.Net.WebException ex)
            {
                if (ex.Response != null) { Log("dash " + c + ": irdash said no (nothing to do right now)"); return 3; }
                Log("dash " + c + ": irdash is not reachable (" + ex.Message + ")");
                return 1;
            }
            catch (Exception ex) { Log("dash " + c + ": " + ex.Message); return 1; }
        }

        // ffb +1 / -1 : iRacing's wheel strength (max force, Nm) via the official SDK.
        static int CmdFfb(string[] a)
        {
            double step = a.Length > 0 ? double.Parse(a[0], CultureInfo.InvariantCulture) : 0;
            Tele t = Tele.Open();
            if (t == null) { Log("ffb: no sim session running"); return 3; }
            double cur; bool has;
            using (t) { has = t.Has("SteeringWheelMaxForceNm"); cur = t.Num("SteeringWheelMaxForceNm"); }
            if (!has) { Log("ffb: the sim does not publish SteeringWheelMaxForceNm"); return 1; }
            double nv = Math.Max(1.0, Math.Min(200.0, cur + step));
            Bcast(11, 0, (int)(nv * 65536.0));
            Log(string.Format(CultureInfo.InvariantCulture, "ffb: max force {0:0.0} -> {1:0.0} Nm", cur, nv));
            return 0;
        }

        // ---------- computer ----------

        static int CmdOpen(string[] a)
        {
            if (a.Length == 0) { Log("open: need a path"); return 1; }
            ProcessStartInfo psi = new ProcessStartInfo(a[0], a.Length > 1 ? string.Join(" ", Slice(a, 1)) : "");
            psi.UseShellExecute = true;
            Process.Start(psi);
            Log("open " + a[0]);
            return 0;
        }

        // System shortcuts (win+d, win+prtsc, win+shift+s) - these go to Windows, not to iRacing.
        static int CmdHotkey(string[] a)
        {
            if (a.Length == 0) { Log("hotkey: need a combo"); return 1; }
            List<ushort> keys = new List<ushort>(); List<bool> exts = new List<bool>();
            foreach (string p in a[0].ToLowerInvariant().Split('+'))
            {
                ushort vk; bool ext = false;
                if (p == "win") { vk = 0x5B; ext = true; }
                else if (p == "prtsc") { vk = 0x2C; ext = true; }
                else if (!KeyCode(p, out vk, out ext)) { Log("hotkey: unknown key " + p); return 1; }
                keys.Add(vk); exts.Add(ext);
            }
            for (int i = 0; i < keys.Count; i++) { Vk(keys[i], false, exts[i]); Thread.Sleep(20); }
            Thread.Sleep(40);
            for (int i = keys.Count - 1; i >= 0; i--) { Vk(keys[i], true, exts[i]); Thread.Sleep(20); }
            Log("hotkey " + a[0]);
            return 0;
        }

        // Pull whatever window you're using onto the centre screen, maximised.
        static int CmdCenter()
        {
            IntPtr h = Native.GetForegroundWindow();
            StringBuilder cls = new StringBuilder(64); Native.GetClassName(h, cls, 64);
            string name = ForegroundName();
            if (name == "iRacingSim64DX11" || cls.ToString() == "Progman" || cls.ToString() == "WorkerW" || cls.ToString() == "Shell_TrayWnd")
            { Log("center: nothing to move (" + name + ")"); return 3; }
            PlaceOnCentre(h);
            Log("center: moved " + name);
            return 0;
        }

        // confirm <id> <command...> : first press arms (two quick beeps), a second press within 3 s runs the command.
        static int CmdConfirm(string[] a)
        {
            if (a.Length < 2) { Log("confirm: need an id and a command"); return 1; }
            // SKIP SESSION is ONE press (2026-10-18, Peter: 'skip session doesnt work'). The two-press arm only gave a double beep and
            // a second press never came: every real use in the log (10-15, 10-18) stopped at 'armed'. The command itself already refuses
            // everything risky (official sessions, a moving car) and the key ignores repeats within 0.7 s, so a bounce cannot skip twice.
            // RESTART is one press too (2026-10-23: 15 presses armed, 9 confirmed). restartrace does everything itself: waits for a rolling
            // car, restarts, gets back in. The deck's `confirm restart-race restartrace` therefore works before the layout is rebuilt.
            if (a[0] == "skip-session" || a[0] == "restart-race") { Log("confirm " + a[0] + ": one press, no arming"); return Run(Slice(a, 1)); }
            string f = Path.Combine(Root, "armed-" + a[0] + ".txt");
            DateTime expiry = DateTime.MinValue;
            try { if (File.Exists(f)) expiry = DateTime.Parse(File.ReadAllText(f), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind); } catch { }
            // a bounce reaches us within 0.1 s of the arming press; Peter's own second tap is >= 0.18 s later.
            // An arm younger than 0.15 s is the same press arriving twice: ignore it, never confirm on it.
            double left = (expiry - DateTime.Now).TotalSeconds;
            if (left > 2.85 && left <= 3.1) { Log("confirm " + a[0] + ": repeat press ignored (bounce)"); return 0; }
            if (left <= 0 || left > 3.1)
            {
                File.WriteAllText(f, DateTime.Now.AddSeconds(3).ToString("o", CultureInfo.InvariantCulture));
                try { if (keyMutex != null) keyMutex.ReleaseMutex(); } catch { }
                Log("confirm " + a[0] + ": armed - press again within 3 seconds");
                Beep(1200, 90); Thread.Sleep(60); Beep(1200, 90);
                return 0;
            }
            File.Delete(f);
            Log("confirm " + a[0] + ": confirmed");
            return Run(Slice(a, 1));
        }

        static bool ConfirmArmedFresh(string[] a)
        {
            if (a == null || a.Length == 0) return false;
            string f = Path.Combine(Root, "armed-" + a[0] + ".txt");
            try { DateTime t = DateTime.Parse(File.ReadAllText(f), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind); return (t - DateTime.Now).TotalSeconds > 0 && (t - DateTime.Now).TotalSeconds <= 2.85; }   // armed at least 0.15 s ago (not a bounce)
            catch { return false; }
        }

        static int CmdPower(string[] a)
        {
            string c = a.Length > 0 ? a[0].ToLowerInvariant() : "";
            if ((c == "off" || c == "restart" || c == "sleep") && SessionActive())
            {
                int rc = CmdQuitMain();   // leave iRacing cleanly first; refuses if the car is moving
                if (rc != 0) { Log("power " + c + ": cancelled because iRacing did not quit"); return rc; }
            }
            // the PC is going away: stop the cooling auto-cool started (a manual AC ON is left alone). Never blocks the power step.
            if ((c == "off" || c == "sleep") && (File.Exists(Path.Combine(Root, @"ac\ac.json")) || File.Exists(Path.Combine(Root, @"ac\cloud.bin")))) { try { CmdAc(new string[] { "pcoff" }); } catch { } }
            ProcessStartInfo psi;
            switch (c)
            {
                case "off": psi = new ProcessStartInfo("shutdown.exe", "/s /t 5"); psi.UseShellExecute = false; psi.CreateNoWindow = true; Process.Start(psi); break;
                case "restart": psi = new ProcessStartInfo("shutdown.exe", "/r /t 5"); psi.UseShellExecute = false; psi.CreateNoWindow = true; Process.Start(psi); break;
                case "sleep": Native.SetSuspendState(false, false, false); break;
                case "lock": Native.LockWorkStation(); break;
                default: Log("power: unknown " + c); return 1;
            }
            Log("power " + c);
            return 0;
        }

        // RIG ON (also runs at logon): Simucube Tuner window (shows firmware/update notices), then the
        // iRacing UI on the centre screen. (SimHub dropped 2026-10-09: not used.)
        // Also the rig launcher: the "iRacing Rig" logon task runs "rigon --boot". Order matters: Stream Deck first so
        // the keys work at once, then the dashboard, wheel and haptics apps, and the iRacing UI last.
        static int CmdRigOn(string[] a)
        {
            bool boot = Array.IndexOf(a, "--boot") >= 0;
            // The HOME key is this command. With the rig up and a session running it used to maximise the iRacing UI over the
            // sim on the middle screen and take the keyboard focus from the car. A press in a session now does nothing (short beep).
            if (!boot && SessionActive()) { Log("rigon: a session is running - not moving the iRacing UI over the sim"); return 3; }
            StartApp("StreamDeck", @"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe", false, "--runinbk");
            // At logon the Stream Deck app took 26-28 s to bring the deck up (3 boots on 2026-10-09; 3.5 s when started alone)
            // because five more programs were loading from a cold disk at the same time. So at boot it gets the machine to
            // itself first: the others start when its deck connection is up (or after 30 s). A file boot-stagger.off in the
            // iRacingDeck folder puts the old all-at-once start back.
            if (boot && !File.Exists(Path.Combine(Root, "boot-stagger.off"))) WaitForDeck(30);
            else WaitFor("StreamDeck", boot ? 15 : 3);
            // top-monitor dashboard; if irdash is already running, this just makes sure its window is open
            StartApp("irdash", Path.Combine(Root, @"dash\irdash.exe"), true, null);
            StartApp("sc-tuner", @"C:\Program Files\SimucubeTuner\sc-tuner.exe", false, "--tray");
            StartApp("bk-connect", @"C:\Program Files\ButtKicker\connect\bk-connect.exe", false, "--minimized");
            // race-screen overlays (irdashies starts minimized to the tray; overlays show only while you drive)
            string irdRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "irdashies");
            if (Directory.Exists(irdRoot))
            {
                // newest app-x.y.z folder (irdashies updates itself into a new folder)
                string[] apps = Directory.GetDirectories(irdRoot, "app-*");
                Array.Sort(apps, delegate (string x, string y) { return new Version(Path.GetFileName(y).Substring(4)).CompareTo(new Version(Path.GetFileName(x).Substring(4))); });
                if (apps.Length > 0) StartApp("irdashies", Path.Combine(apps[0], "irdashies.exe"), false, null);
            }
            // voice spotter and race engineer
            StartApp("CrewChiefV4", @"C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4\CrewChiefV4.exe", false, null);
            StartApp("iRacingUI", @"C:\Program Files (x86)\iRacing\ui\iRacingUI.exe", false, null);
            IntPtr ui = IntPtr.Zero;
            for (int i = 0; i < 180 && (ui = UiWindow()) == IntPtr.Zero; i++) Thread.Sleep(500);
            if (ui == IntPtr.Zero) { Log("rigon: the iRacing UI window did not appear"); return 1; }
            Thread.Sleep(3000);
            PlaceOnCentre(ui); FocusWindow(ui);
            Log("rigon: iRacing UI is on the centre screen");
            try { HideTunerBox(false, ""); } catch (Exception ex) { Log("rigon: tuner box: " + ex.Message); }   // the Tuner's blank grey box (hidden, never closed); Rig Doctor keeps watching
            return 0;
        }
        static void WaitFor(string proc, int seconds)
        {
            for (int i = 0; i < seconds * 4 && Process.GetProcessesByName(proc).Length == 0; i++) Thread.Sleep(250);
        }

        // The Stream Deck app opens this pipe the moment it is ready for keys and plugins; the deck itself attaches ~1 s later.
        static void WaitForDeck(int seconds)
        {
            DateTime t0 = DateTime.Now;
            while ((DateTime.Now - t0).TotalSeconds < seconds)
            {
                try { if (File.Exists(@"\\.\pipe\com.elgato.streamdeck.local")) { Thread.Sleep(1200); Log("rigon: Stream Deck is ready after " + (DateTime.Now - t0).TotalSeconds.ToString("0.0", CultureInfo.InvariantCulture) + " s - starting the other programs"); return; } } catch { }
                Thread.Sleep(200);
            }
            Log("rigon: Stream Deck not ready after " + seconds + " s - starting the other programs anyway");
        }

        static void StartApp(string proc, string path, bool evenIfRunning, string args)
        {
            if (!evenIfRunning && Process.GetProcessesByName(proc).Length > 0) { Log("rigon: " + proc + " already running"); return; }
            if (!File.Exists(path)) { Log("rigon: not found " + path); return; }
            ProcessStartInfo psi = new ProcessStartInfo(path, args ?? "");
            psi.UseShellExecute = true; psi.WorkingDirectory = Path.GetDirectoryName(path);
            Process.Start(psi);
            Log("rigon: started " + proc);
        }

        // LAUNCH: open the Test Drive dialog if it is not open, then press its launch button.
        static int CmdTestDrive(string[] a)
        {
            bool dry = Array.IndexOf(a, "--dry") >= 0;
            if (SessionActive()) { Log("testdrive: a sim session is already running - use GO in the sim"); return 3; }
            AutomationElement root = FindUiWindow();
            if (root == null) { Log("iRacing UI window not found (start the iRacing UI first)"); return 2; }
            List<string> td = new List<string>(new string[] { "Test Drive" });
            DateTime end = DateTime.Now.AddSeconds(10);
            bool opened = false;
            while (DateTime.Now < end)
            {
                List<Cand> c = Scan(root);
                bool dialog = Pick(c, new List<string>(new string[] { "Last settings" }), "hyperlink", false) != null
                           && Pick(c, new List<string>(new string[] { "Close", "Back" }), "hyperlink", false) != null;
                if (dialog)
                {
                    Cand go = Pick(c, td, "hyperlink", true);
                    if (go != null) { if (dry) { Log("testdrive (dry): dialog is open, would press launch"); return 0; } return Press(go) ? 0 : 1; }
                }
                else if (!opened)
                {
                    Cand q = Pick(c, td, "button", false);
                    if (q != null) { if (dry) { Log("testdrive (dry): would open the dialog first"); return 0; } Press(q); opened = true; }
                }
                Thread.Sleep(300);
            }
            Log("testdrive: could not find the Test Drive controls");
            return 1;
        }

        // ---------- iRacing SDK broadcast ----------

        static void Bcast(int msg, int var1, int var2)
        {
            uint id = Native.RegisterWindowMessage("IRSDK_BROADCASTMSG");
            IntPtr w = new IntPtr((int)(((ushort)msg) | ((uint)(ushort)var1 << 16)));
            Native.SendNotifyMessage(new IntPtr(0xFFFF), id, w, new IntPtr(var2));
        }

        static readonly Dictionary<string, int> PitCmd = new Dictionary<string, int> {
            {"clear",0},{"ws",1},{"fuel",2},{"lf",3},{"rf",4},{"lr",5},{"rr",6},{"cleartires",7},
            {"fr",8},{"clearws",9},{"clearfr",10},{"clearfuel",11},{"tc",12} };

        static int CmdPit(string[] a)
        {
            if (a.Length == 0) { Log("pit: need a command"); return 1; }
            string c = a[0].ToLowerInvariant();
            double num = a.Length > 1 ? double.Parse(a[1], CultureInfo.InvariantCulture) : 0;
            if (c == "fuel+" || c == "fuel-" || c == "fuelset") return AdjustFuel(c, num);
            if (c == "t" || c == "l" || c == "r")   // all tires / left side / right side
            {
                int[] ids = c == "t" ? new int[] { 3, 4, 5, 6 } : c == "l" ? new int[] { 3, 5 } : new int[] { 4, 6 };
                foreach (int i in ids) { Bcast(9, i, (int)num); Thread.Sleep(25); }
                Log("pit " + c + " sent");
                return 0;
            }
            int id;
            if (!PitCmd.TryGetValue(c, out id)) { Log("pit: unknown command " + c); return 1; }
            Bcast(9, id, (int)num);
            Log("pit " + c + (num != 0 ? " " + num : "") + " sent");
            return 0;
        }

        // fuel+/fuel-: step in the units the sim displays (gallons or litres); fuelset: absolute amount in those units.
        static int AdjustFuel(string c, double amount)
        {
            Tele t = Tele.Open();
            if (t == null) { Log("fuel: sim telemetry not available (is iRacing running?)"); return 1; }
            using (t)
            {
                double lpu = t.Num("DisplayUnits") == 0 ? 3.785411784 : 1.0;
                bool boxed = ((int)t.Num("PitSvFlags") & 0x10) != 0;
                double cur = boxed ? t.Num("PitSvFuel") : 0;
                double next = c == "fuelset" ? amount * lpu : cur + (c == "fuel+" ? 1 : -1) * amount * lpu;
                int litres = (int)Math.Round(next);
                if (litres <= 0) { Bcast(9, 11, 0); Log("fuel: cleared (was " + cur.ToString("0.0", CultureInfo.InvariantCulture) + " L)"); }
                else { Bcast(9, 2, litres); Log("fuel: " + cur.ToString("0.0", CultureInfo.InvariantCulture) + " L -> " + litres + " L"); }
            }
            return 0;
        }

        // The deck sends one press 2-3 times and THANKS once went out twice, 0.96 s apart (past the 0.7 s key filter). The same line within
        // 3 s of the last one sent is dropped. The stamp is in the temp folder like the other repeat guards; a mutex makes check-and-write one step.
        static bool ChatRepeat(string text)
        {
            Mutex mx = new Mutex(false, "Local\\irdeck-chat-stamp");
            bool mine = false;
            try
            {
                try { mine = mx.WaitOne(2000); } catch (AbandonedMutexException) { mine = true; }
                string stampFile = Path.Combine(Path.GetTempPath(), "irdeck-chat-say.last");
                string last = "";
                try { last = File.ReadAllText(stampFile); } catch { }
                long now = DateTime.UtcNow.Ticks;
                if (DeckRules.ChatIsRepeat(last, text, now, DeckRules.ChatRepeatMs)) { Log("chat say: the same message was sent a moment ago - repeat press ignored"); return true; }
                try { File.WriteAllText(stampFile, DeckRules.ChatStamp(text, now)); } catch { }
                return false;
            }
            finally
            {
                if (mine) { try { mx.ReleaseMutex(); } catch { } }
                mx.Dispose();
            }
        }

        static int CmdChat(string[] a)
        {
            if (a.Length == 0) { Log("chat: need begin|reply|cancel|macro N|say TEXT"); return 1; }
            switch (a[0].ToLowerInvariant())
            {
                case "begin": Bcast(8, 1, 0); break;
                case "reply": Bcast(8, 2, 0); break;
                case "cancel": Bcast(8, 3, 0); break;
                case "macro": Bcast(8, 0, int.Parse(a[1])); break;
                case "say":
                    if (!SessionActive()) { Log("chat say: no sim session running"); return 3; }
                    if (ChatRepeat(string.Join(" ", Slice(a, 1)))) return 0;
                    if (!FocusWindow(SimWindow())) { Log("chat say: could not bring the sim to the front"); return 3; }
                    Bcast(8, 1, 0); Thread.Sleep(250);
                    TypeText(string.Join(" ", Slice(a, 1)));
                    Thread.Sleep(80); SendCombo("enter", 0);
                    break;
                default: Log("chat: unknown " + a[0]); return 1;
            }
            Log("chat " + a[0] + " sent");
            return 0;
        }

        // ---------- keystrokes ----------

        static string ForegroundName()
        {
            try
            {
                uint pid; Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out pid);
                return Process.GetProcessById((int)pid).ProcessName;
            }
            catch { return "?"; }
        }
        static bool IRacingForeground() { return ForegroundName().StartsWith("iRacing", StringComparison.OrdinalIgnoreCase); }

        static bool KeyCode(string n, out ushort vk, out bool ext)
        {
            ext = false; vk = 0; n = n.ToLowerInvariant();
            if (n.Length == 1 && n[0] >= 'a' && n[0] <= 'z') { vk = (ushort)char.ToUpper(n[0]); return true; }
            if (n.Length == 1 && n[0] >= '0' && n[0] <= '9') { vk = (ushort)n[0]; return true; }
            if (n.Length >= 2 && n[0] == 'f')
            {
                int f; if (int.TryParse(n.Substring(1), out f) && f >= 1 && f <= 12) { vk = (ushort)(0x70 + f - 1); return true; }
            }
            switch (n)
            {
                case "esc": vk = 0x1B; return true;
                case "pause": vk = 0x13; return true;
                case "enter": vk = 0x0D; return true;
                case "tab": vk = 0x09; return true;
                case "space": vk = 0x20; return true;
                case "backspace": vk = 0x08; return true;
                case "shift": vk = 0xA0; return true;
                case "ctrl": vk = 0xA2; return true;
                case "alt": vk = 0xA4; return true;
                case "up": vk = 0x26; ext = true; return true;
                case "down": vk = 0x28; ext = true; return true;
                case "left": vk = 0x25; ext = true; return true;
                case "right": vk = 0x27; ext = true; return true;
                case "home": vk = 0x24; ext = true; return true;
                case "end": vk = 0x23; ext = true; return true;
                case "pgup": vk = 0x21; ext = true; return true;
                case "pgdn": vk = 0x22; ext = true; return true;
                case "ins": vk = 0x2D; ext = true; return true;
                case "del": vk = 0x2E; ext = true; return true;
                case "/": vk = 0xBF; return true;
                case "[": vk = 0xDB; return true;
                case "]": vk = 0xDD; return true;
                case ";": vk = 0xBA; return true;
            }
            return false;
        }

        static void Key(ushort vk, bool ext, bool up)
        {
            INPUT[] i = new INPUT[1];
            i[0].type = 1;
            i[0].u.ki.wVk = vk;
            i[0].u.ki.wScan = (ushort)Native.MapVirtualKey(vk, 0);
            i[0].u.ki.dwFlags = 0x0008u | (ext ? 0x0001u : 0u) | (up ? 0x0002u : 0u);
            Native.SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
        }

        static void SendCombo(string combo, int holdMs)
        {
            string[] parts = combo.Split('+');
            List<ushort> mods = new List<ushort>();
            for (int i = 0; i < parts.Length - 1; i++) { ushort m; bool e; if (KeyCode(parts[i], out m, out e)) mods.Add(m); }
            ushort vk; bool ext;
            if (!KeyCode(parts[parts.Length - 1], out vk, out ext)) throw new Exception("unknown key " + parts[parts.Length - 1]);
            foreach (ushort m in mods) { Key(m, false, false); Thread.Sleep(15); }
            Key(vk, ext, false);
            Thread.Sleep(holdMs > 0 ? holdMs : 45);
            Key(vk, ext, true);
            for (int i = mods.Count - 1; i >= 0; i--) { Thread.Sleep(15); Key(mods[i], false, true); }
        }

        static void TypeText(string s)
        {
            foreach (char ch in s)
            {
                INPUT[] i = new INPUT[2];
                i[0].type = 1; i[0].u.ki.wScan = ch; i[0].u.ki.dwFlags = 0x0004;
                i[1].type = 1; i[1].u.ki.wScan = ch; i[1].u.ki.dwFlags = 0x0004 | 0x0002;
                Native.SendInput(2, i, Marshal.SizeOf(typeof(INPUT)));
                Thread.Sleep(12);
            }
        }

        static int CmdKey(string[] a)
        {
            string combo = null; int hold = 0; bool force = false; string only = null;
            foreach (string t in a)
            {
                if (t.StartsWith("--hold=")) hold = int.Parse(t.Substring(7));
                else if (t == "--force") force = true;
                else if (t == "--sim") only = "iRacingSim64DX11";   // only when the sim is in front
                else if (t == "--ui") only = "iRacingUI";           // only when the iRacing UI is in front
                else combo = t;
            }
            if (combo == null) { Log("key: need a key, e.g. shift+r"); return 1; }
            // sim keys bring the sim forward themselves when a session is running
            if (only == "iRacingSim64DX11" && !force && ForegroundName() != only && SessionActive()) FocusWindow(SimWindow());
            if (only != null && !force && !ForegroundName().Equals(only, StringComparison.OrdinalIgnoreCase)) { Log("key " + combo + " refused: foreground app is " + ForegroundName() + ", needs " + only); return 3; }
            if (!force && !IRacingForeground()) { Log("key " + combo + " refused: foreground app is " + ForegroundName() + ", not iRacing"); return 3; }
            SendCombo(combo, hold);
            Log("key " + combo + (hold > 0 ? " held " + hold + "ms" : "") + " sent to " + ForegroundName());
            return 0;
        }

        // ---------- sim session-screen buttons (drawn by the sim, so not reachable by name) ----------

        // The bar's big green button (Test / Race / Drive ...) is found by colour along the top of the middle race
        // screen (where the sim draws its session bar); the other buttons sit at fixed offsets from it, scaled by
        // the button's width. Returns screen coordinates.
        static bool FindGreen(out int cx, out int cy, out int bw)
        {
            cx = cy = bw = 0;
            // The button's colour follows the session: green in practice, purple in qualifying, other colours in
            // races (seen 2026-10-09), so look for any strongly coloured bar. Only the middle 1040 px of the
            // session bar are searched: outside it the track scenery (green grass) shows through.
            System.Drawing.Rectangle full = SimArea();
            int half = Math.Min(520, full.Width / 2);
            System.Drawing.Rectangle area = new System.Drawing.Rectangle(full.X + full.Width / 2 - half, full.Y, half * 2, 200);
            int W = area.Width, H = area.Height;
            using (System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(W, H, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
            {
                using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp))
                    g.CopyFromScreen(area.X, area.Y, 0, 0, new System.Drawing.Size(W, H));
                System.Drawing.Imaging.BitmapData d = bmp.LockBits(new System.Drawing.Rectangle(0, 0, W, H),
                    System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                byte[] px = new byte[d.Stride * H];
                Marshal.Copy(d.Scan0, px, 0, px.Length);
                bmp.UnlockBits(d);
                int minX = int.MaxValue, maxX = -1, minY = int.MaxValue, maxY = -1, rows = 0;
                for (int y = 0; y < H; y++)
                {
                    int bestLen = 0, bestStart = 0, run = 0, start = 0;
                    for (int x = 0; x < W; x++)
                    {
                        int i = y * d.Stride + x * 4;
                        int b = px[i], gr = px[i + 1], r = px[i + 2];
                        int hi = Math.Max(r, Math.Max(gr, b)), lo = Math.Min(r, Math.Min(gr, b));
                        bool green = hi > 100 && hi - lo > 60;   // any vivid colour; the bar itself is dark grey
                        if (green) { if (run == 0) start = x; run++; if (run > bestLen) { bestLen = run; bestStart = start; } } else run = 0;
                    }
                    // a button-sized run only: scenery showing through the see-through bar (a blue banner at Lime
                    // Rock, 2026-10-09) makes runs as wide as the whole search strip
                    bool button = bestLen >= 150 && bestLen <= W * 0.7 && bestStart > 2 && bestStart + bestLen < W - 2;
                    if (button)
                    {
                        // the first solid block from the top is the button; stop at the first gap after it
                        if (rows > 0 && y > maxY + 3) break;
                        rows++; minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
                        minX = Math.Min(minX, bestStart); maxX = Math.Max(maxX, bestStart + bestLen);
                    }
                }
                if (rows < 20) return false;
                cx = area.X + (minX + maxX) / 2; cy = area.Y + (minY + maxY) / 2; bw = maxX - minX;
                return true;
            }
        }

        // Saves the whole middle race screen (half size) next to the exe when a session-bar search fails,
        // so the failure can be looked at afterwards.
        static string SaveSimArea(string name)
        {
            try
            {
                System.Drawing.Rectangle a = SimArea();
                string file = Path.Combine(Root, name + ".png");
                using (var full = new System.Drawing.Bitmap(a.Width, a.Height))
                {
                    using (var g = System.Drawing.Graphics.FromImage(full)) g.CopyFromScreen(a.X, a.Y, 0, 0, a.Size);
                    using (var half = new System.Drawing.Bitmap(full, a.Width / 2, a.Height / 2)) half.Save(file, System.Drawing.Imaging.ImageFormat.Png);
                }
                return file;
            }
            catch (Exception ex) { return "nowhere: " + ex.Message; }
        }

        static void Click(int x, int y)
        {
            Native.SetCursorPos(x, y); Thread.Sleep(80);
            Native.mouse_event(0x02, 0, 0, 0, UIntPtr.Zero); Thread.Sleep(60);
            Native.mouse_event(0x04, 0, 0, 0, UIntPtr.Zero);
        }

        static double LoadScale()
        {
            try { return double.Parse(File.ReadAllText(Path.Combine(Root, "irdeck.scale")), CultureInfo.InvariantCulture); } catch { return 1.0; }
        }

        static int CmdSimClick(string[] a)
        {
            bool dry = false; string what = null;
            foreach (string t in a) { if (t == "--dry") dry = true; else what = t.ToLowerInvariant(); }
            if (what == null) { Log("simclick: need test|garage|settings|quit|quitnow|info|laps|rules|admin|yes|cancel"); return 1; }
            // offsets (px, measured with a 478px-wide green button): from the green button centre ...
            Dictionary<string, int[]> off = new Dictionary<string, int[]> {
                {"test",new[]{0,0}},{"quit",new[]{764,120}},{"garage",new[]{593,119}},{"settings",new[]{691,119}},
                {"info",new[]{-669,119}},{"laps",new[]{-743,119}},{"rules",new[]{-593,119}},{"admin",new[]{-499,119}} };
            // ... or from the centre of the screen (the sim's confirmation dialog)
            Dictionary<string, int[]> mid = new Dictionary<string, int[]> { {"yes",new[]{146,58}},{"cancel",new[]{36,58}} };
            bool quitNow = what == "quitnow";
            if (quitNow) what = "quit";
            int[] o; bool fromMid = mid.TryGetValue(what, out o);
            if (!fromMid && !off.TryGetValue(what, out o)) { Log("simclick: unknown button " + what); return 1; }
            if (!dry)
            {
                if (!SessionActive()) { Log("simclick " + what + ": no sim session running"); return 3; }
                if (!FocusWindow(SimWindow())) { Log("simclick " + what + ": could not bring the sim to the front"); return 3; }
                Thread.Sleep(200);
            }
            if (!dry)
            {
                Tele t = Tele.Open();
                if (t != null) { bool on; using (t) { on = t.Bool("IsOnTrack"); } if (on) { Log("simclick refused: your car is on track"); return 3; } }
            }
            int cx, cy; double s; bool found;
            BarAnchor(out cx, out cy, out s, out found);   // the bar is always centred on the screen; only its size follows the coloured button
            if (found) { try { File.WriteAllText(Path.Combine(Root, "irdeck.scale"), s.ToString(CultureInfo.InvariantCulture)); } catch { } }
            int x, y;
            System.Drawing.Rectangle sa = SimArea();
            if (fromMid) { x = sa.X + sa.Width / 2 + (int)Math.Round(o[0] * s); y = sa.Y + sa.Height / 2 + (int)Math.Round(o[1] * s); }
            else
            {
                x = cx + (int)Math.Round(o[0] * s); y = cy + (int)Math.Round(o[1] * s);
            }
            Log("simclick " + what + " (scale " + s.ToString("0.00", CultureInfo.InvariantCulture) + ") -> " + x + "," + y + (dry ? " (dry run)" : ""));
            if (dry) return 0;
            Click(x, y);
            if (quitNow)
            {
                Thread.Sleep(900);
                int[] y2 = mid["yes"];
                Click(sa.X + sa.Width / 2 + (int)Math.Round(y2[0] * s), sa.Y + sa.Height / 2 + (int)Math.Round(y2[1] * s));
                Log("simclick quitnow: confirmed");
            }
            return 0;
        }

        // ---------- state / quit / focus ----------

        static int CmdState()
        {
            bool sim = Process.GetProcessesByName("iRacingSim64DX11").Length > 0;
            bool ui = Process.GetProcessesByName("iRacingUI").Length > 0;
            Tele t = Tele.Open();
            if (t == null) { Log("state: sim=" + sim + " ui=" + ui + " telemetry=off"); return 0; }
            using (t)
            {
                Log(string.Format(CultureInfo.InvariantCulture,
                    "state: sim={0} ui={1} telemetry=on onTrack={2} onPitRoad={3} units={4} fuelLevel={5:0.0}L pitSvFuel={6:0.0}L pitSvFlags={7} foreground={8}",
                    sim, ui, t.Bool("IsOnTrack"), t.Bool("OnPitRoad"), t.Num("DisplayUnits") == 0 ? "imperial" : "metric",
                    t.Num("FuelLevel"), t.Num("PitSvFuel"), (int)t.Num("PitSvFlags"), ForegroundName()));
            }
            return 0;
        }

        static int CmdQuitSim()
        {
            Process[] ps = Process.GetProcessesByName("iRacingSim64DX11");
            if (ps.Length == 0) { Log("quit-sim: sim is not running"); return 0; }
            Tele t = Tele.Open();
            if (t != null)
            {
                bool onTrack; using (t) { onTrack = t.Bool("IsOnTrack"); }
                if (onTrack) { Log("quit-sim refused: your car is on track. Exit to the garage first."); return 3; }
            }
            foreach (Process p in ps) p.CloseMainWindow();
            for (int i = 0; i < 40; i++)
            {
                Thread.Sleep(250);
                if (Process.GetProcessesByName("iRacingSim64DX11").Length == 0) { Log("quit-sim: sim closed"); return 0; }
            }
            Log("quit-sim: sim did not close (it may be showing a confirmation); nothing was forced");
            return 1;
        }

        static int CmdFocus(string[] a)
        {
            string name = a.Length > 0 && a[0].ToLowerInvariant() == "sim" ? "iRacingSim64DX11" : "iRacingUI";
            foreach (Process p in Process.GetProcessesByName(name))
            {
                IntPtr h = IntPtr.Zero; try { h = p.MainWindowHandle; } catch { }
                if (h == IntPtr.Zero) continue;
                if (Native.IsIconic(h)) Native.ShowWindow(h, 9);
                Native.SetForegroundWindow(h);
                Log("focused " + name);
                return 0;
            }
            Log("focus: no window for " + name);
            return 1;
        }
    }
}
