// irdash - iRacing dashboard for the top monitor.
//   Reads the iRacing SDK shared memory (same source SimHub and irdeck use), serves the web dashboard
//   in dash\www on http://localhost:<port>/, streams telemetry to it as Server-Sent Events, and opens it
//   full screen on the top monitor. Lives in the tray; idle when iRacing is not running.
//   Written for the C# 5 compiler that ships with Windows (see build.ps1), so no installs are needed.
//
//   irdash.exe               start (or, if already running, just re-open the dashboard window)
//   irdash.exe --no-browser  start the server only
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Net;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

namespace IRDash
{
    sealed class VarDef { public string Name; public int Type, Offset, Count; }

    sealed class Frame
    {
        public long Seq; public bool Connected; public byte[] Data;
        public Dictionary<string, VarDef> Vars; public int SessionVersion; public string SessionYaml = "";

        public double Num(string name)
        {
            VarDef d;
            if (!Connected || Vars == null || !Vars.TryGetValue(name, out d) || d.Offset < 0 || d.Offset + 8 > Data.Length) return 0;
            switch (d.Type)
            {
                case 0: case 1: return Data[d.Offset];
                case 2: case 3: return BitConverter.ToInt32(Data, d.Offset);
                case 4: return BitConverter.ToSingle(Data, d.Offset);
                case 5: return BitConverter.ToDouble(Data, d.Offset);
            }
            return 0;
        }
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    // Windows' own "this window is full screen, taskbar stay behind it" switch.
    [System.Runtime.InteropServices.ComImport, System.Runtime.InteropServices.Guid("602D4995-B13A-429b-A66E-1935E44F4317"),
     System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
    interface ITaskbarList2
    {
        void HrInit(); void AddTab(IntPtr h); void DeleteTab(IntPtr h); void ActivateTab(IntPtr h); void SetActiveAlt(IntPtr h);
        void MarkFullscreenWindow(IntPtr h, [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] bool full);
    }
    [System.Runtime.InteropServices.ComImport, System.Runtime.InteropServices.Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    class TaskbarListCom { }

    static class Native
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        public const int GWL_STYLE = -16, GWL_EXSTYLE = -20, WS_EX_TOPMOST = 0x8;
        public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2;
        public const int WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000;
        public const uint SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20, SWP_NOOWNERZORDER = 0x200;
    }

    static class Log
    {
        static readonly object gate = new object();
        public static string FilePath;
        public static void W(string m)
        {
            try
            {
                lock (gate)
                {
                    if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 2000000) File.Delete(FilePath);
                    File.AppendAllText(FilePath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + m + "\r\n");
                }
            }
            catch { }
        }
    }

    // ---------------- iRacing SDK reader ----------------
    static class Sdk
    {
        static readonly object gate = new object();
        static Frame latest = new Frame();
        static long seq;
        static DateTime lastFrameAt = DateTime.MinValue;
        public static Frame Latest { get { lock (gate) return latest; } }
        public static bool Fresh { get { lock (gate) return DateTime.UtcNow - lastFrameAt <= TimeSpan.FromSeconds(2); } }
        public static bool FreshDeck { get { lock (gate) return DateTime.UtcNow - lastFrameAt <= TimeSpan.FromSeconds(1); } }

        static void Publish(Frame f)
        {
            lock (gate) { f.Seq = ++seq; latest = f; lastFrameAt = DateTime.UtcNow; Monitor.PulseAll(gate); }
        }
        public static Frame WaitNext(long lastSeq, int timeoutMs)
        {
            lock (gate)
            {
                if (latest.Seq == lastSeq) Monitor.Wait(gate, timeoutMs);
                return latest;
            }
        }
        // ---- test hook (tests\overlays-test.ps1): pretend a session is running, without iRacing ----
        // Only works while the file dash\test-hook.on exists (the test makes it and removes it). The values go to
        // irdash's own readers only (delta bar, timings, restart gate); no other program sees anything.
        static bool fakeUp; static Thread fakePump; static string fakeYaml = ""; static int fakeSess = 1;
        static volatile bool realUp;
        static readonly Dictionary<string, double> fakeVals = new Dictionary<string, double>();
        public static bool TestHook { get { return File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "test-hook.on")) && RealBusy() == null; } }
        // true while the pretend session is on: the REPLAY screen then records its SDK messages instead of broadcasting them (replay.cs)
        public static bool Pretend { get { return fakeUp; } }
        public static volatile int FakePumpMs = 33;      // how often the pretend session publishes a frame; tests\race-field-test.ps1 shortens it (and restores 33) to run a pretend race faster than real time
        static readonly Regex ArrayKey = new Regex("^(CarIdx[A-Za-z0-9]+)_([0-9]{1,2})$");   // test hook: CarIdxPosition_3=5 = slot 3 of that array

        // Why the test hook must stay shut: Peter is racing or about to (2026-10-09 a test's pretend race mixed with his real one).
        // null = nothing real is going on.
        public static string RealBusy()
        {
            if (realUp) return "iRacing is connected";
            try { if (Process.GetProcessesByName("iRacingSim64DX11").Length > 0) return "the sim is running"; } catch { }
            try
            {
                string mark = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "start-mark.txt");
                if (File.Exists(mark))
                {
                    string[] p = File.ReadAllText(mark).Split('\t'); long t;
                    if (p.Length > 1 && p[1].Trim() != "TEST" && long.TryParse(p[0], out t) && (DateTime.UtcNow - new DateTime(t, DateTimeKind.Utc)).TotalMinutes < 10)
                        return "a START key was pressed in the last 10 minutes";
                }
            }
            catch { }
            return null;
        }

        public static void FakeSet(Dictionary<string, double> v)
        {
            lock (fakeVals) foreach (KeyValuePair<string, double> kv in v) fakeVals[kv.Key] = kv.Value;
            if (fakeUp) return;
            fakeUp = true;
            Log.W("test hook: pretending a session is running");
            Timings.OnConnected();
            fakePump = new Thread(delegate ()
            {
                while (fakeUp)
                {
                    if (realUp) { Log.W("test hook: a real session started - the pretend one stops now"); new Thread(FakeEnd) { IsBackground = true }.Start(); return; }
                    Frame f = new Frame(); f.Connected = true; f.Vars = new Dictionary<string, VarDef>(); f.SessionVersion = fakeSess; f.SessionYaml = fakeYaml;
                    lock (fakeVals)
                    {
                        // CarIdxPosition_3=5 style keys are slots of a 64-car array (the REPLAY screen reads those); the rest are single values.
                        // A lap fraction such as CarIdxLapDistPct was stored as an int, so 0.42 became 0 and every car sat on the start line.
                        // Whole-number arrays stay ints. One fractional slot stores that whole array as floats (still 4 bytes a slot).
                        var arrays = new Dictionary<string, double[]>();
                        var whole = new Dictionary<string, bool>();
                        int scalars = 0;
                        foreach (KeyValuePair<string, double> kv in fakeVals)
                        {
                            Match am = ArrayKey.Match(kv.Key);
                            if (!am.Success) { scalars++; continue; }
                            string an = am.Groups[1].Value;
                            double[] arr; if (!arrays.TryGetValue(an, out arr)) { arr = new double[64]; arrays[an] = arr; whole[an] = true; }
                            int slot; if (!int.TryParse(am.Groups[2].Value, out slot) || slot < 0 || slot >= 64) continue;
                            arr[slot] = kv.Value;
                            if (Math.Abs(kv.Value - Math.Round(kv.Value)) > 1e-6) whole[an] = false;
                        }
                        int arrBase = 8 * Math.Max(1, scalars), ai = 0;
                        f.Data = new byte[arrBase + 256 * arrays.Count];
                        foreach (KeyValuePair<string, double[]> ar in arrays)
                        {
                            bool isWhole = whole[ar.Key];
                            VarDef av = new VarDef(); av.Name = ar.Key; av.Type = isWhole ? 2 : 4; av.Count = 64; av.Offset = arrBase + 256 * ai++;
                            for (int k = 0; k < 64; k++)
                            {
                                byte[] raw = isWhole ? BitConverter.GetBytes((int)ar.Value[k]) : BitConverter.GetBytes((float)ar.Value[k]);
                                Array.Copy(raw, 0, f.Data, av.Offset + 4 * k, 4);
                            }
                            f.Vars[ar.Key] = av;
                        }
                        int i = 0;
                        foreach (KeyValuePair<string, double> kv in fakeVals)
                        {
                            if (ArrayKey.IsMatch(kv.Key)) continue;
                            VarDef d = new VarDef(); d.Name = kv.Key; d.Count = 1; d.Offset = i * 8;
                            bool flag = kv.Key == "IsOnTrack" || kv.Key == "OnPitRoad" || kv.Key.EndsWith("_OK");
                            d.Type = flag ? 1 : kv.Key == "Lap" ? 2 : 4;
                            if (flag) f.Data[d.Offset] = (byte)(kv.Value != 0 ? 1 : 0);
                            else if (d.Type == 2) Array.Copy(BitConverter.GetBytes((int)kv.Value), 0, f.Data, d.Offset, 4);
                            else Array.Copy(BitConverter.GetBytes((float)kv.Value), 0, f.Data, d.Offset, 4);
                            f.Vars[kv.Key] = d; i++;
                        }
                    }
                    Publish(f);
                    Timings.OnFrame(f);
                    Thread.Sleep(FakePumpMs);
                }
            });
            fakePump.IsBackground = true; fakePump.Start();
        }

        // a pretend session's YAML (taken from a real .ibt by the test); the page gets it through /stream like the real one
        public static void FakeSession(string yaml) { fakeYaml = yaml ?? ""; fakeSess++; }

        public static void FakeEnd()
        {
            if (!fakeUp) return;
            fakeUp = false; fakeYaml = "";
            lock (fakeVals) fakeVals.Clear();
            Thread.Sleep(80);
            Publish(new Frame());
            Timings.OnDisconnected();
            Log.W("test hook: the pretend session ended");
        }

        public static void Run()
        {
            MemoryMappedFile mmf = null; MemoryMappedViewAccessor va = null; EventWaitHandle ev = null;
            Dictionary<string, VarDef> vars = null;
            int numVarsSeen = -1, lastUpd = -1, sessVer = 0, lastTick = -1;
            string yaml = "";
            DateTime offSince = DateTime.MinValue, lastIdle = DateTime.MinValue;
            bool wasConnected = false;
            while (true)
            {
                try
                {
                    if (va == null)
                    {
                        try
                        {
                            mmf = MemoryMappedFile.OpenExisting("Local\\IRSDKMemMapFileName", MemoryMappedFileRights.Read);
                            va = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read);
                        }
                        catch { Close(ref mmf, ref va, ref ev); }
                        if (va != null)
                        {
                            try { ev = EventWaitHandle.OpenExisting("Local\\IRSDKDataValidEvent", EventWaitHandleRights.Synchronize); }
                            catch { ev = null; }
                            vars = null; numVarsSeen = -1; lastUpd = -1; lastTick = -1; offSince = DateTime.Now;
                        }
                    }
                    if (va == null) { Idle(ref lastIdle, ref wasConnected); Thread.Sleep(1000); continue; }

                    if (ev != null) ev.WaitOne(250); else Thread.Sleep(16);

                    int status = va.ReadInt32(4);
                    if ((status & 1) == 0)
                    {
                        Idle(ref lastIdle, ref wasConnected);
                        // Let go of the mapping after a while so a fresh sim launch is picked up cleanly.
                        if ((DateTime.Now - offSince).TotalSeconds > 5) Close(ref mmf, ref va, ref ev);
                        Thread.Sleep(250);
                        continue;
                    }
                    offSince = DateTime.Now;

                    int numVars = va.ReadInt32(24);
                    int upd = va.ReadInt32(12);
                    if (vars == null || numVars != numVarsSeen || upd != lastUpd) { vars = ReadVars(va, numVars); numVarsSeen = numVars; }
                    if (upd != lastUpd) { yaml = ReadYaml(va); lastUpd = upd; sessVer++; }

                    int numBuf = Math.Min(4, va.ReadInt32(32)), bufLen = va.ReadInt32(36);
                    byte[] data = null; int tick = -1;
                    for (int attempt = 0; attempt < 3 && data == null; attempt++)
                    {
                        int best = -1, bestI = 0;
                        for (int i = 0; i < numBuf; i++)
                        {
                            int t = va.ReadInt32(48 + i * 16);
                            if (t > best) { best = t; bestI = i; }
                        }
                        int off = va.ReadInt32(52 + bestI * 16);
                        byte[] b = new byte[bufLen];
                        va.ReadArray<byte>(off, b, 0, bufLen);
                        // The sim may have started rewriting this slot while we copied it; only keep a clean copy.
                        if (va.ReadInt32(48 + bestI * 16) == best) { data = b; tick = best; }
                    }
                    if (data == null || tick == lastTick) continue;
                    lastTick = tick;
                    if (!wasConnected) { Log.W("iRacing connected"); wasConnected = true; realUp = true; if (fakeUp) FakeEnd(); Timings.OnConnected(); }
                    Frame f = new Frame();
                    f.Connected = true; f.Data = data; f.Vars = vars; f.SessionVersion = sessVer; f.SessionYaml = yaml;
                    Publish(f);
                    Timings.OnFrame(f);
                }
                catch (Exception ex)
                {
                    Log.W("sdk: " + ex.Message);
                    Close(ref mmf, ref va, ref ev);
                    Thread.Sleep(1000);
                }
            }
        }

        static void Idle(ref DateTime lastIdle, ref bool wasConnected)
        {
            if (wasConnected) { Log.W("iRacing disconnected"); wasConnected = false; realUp = false; Timings.OnDisconnected(); }
            if ((DateTime.Now - lastIdle).TotalMilliseconds < 1000 || fakeUp) return;
            lastIdle = DateTime.Now;
            Publish(new Frame());
        }

        static void Close(ref MemoryMappedFile mmf, ref MemoryMappedViewAccessor va, ref EventWaitHandle ev)
        {
            try { if (va != null) va.Dispose(); } catch { }
            try { if (mmf != null) mmf.Dispose(); } catch { }
            try { if (ev != null) ev.Dispose(); } catch { }
            va = null; mmf = null; ev = null;
        }

        static Dictionary<string, VarDef> ReadVars(MemoryMappedViewAccessor va, int numVars)
        {
            int hdrOff = va.ReadInt32(28);
            var d = new Dictionary<string, VarDef>(StringComparer.Ordinal);
            byte[] nm = new byte[32];
            for (int i = 0; i < numVars; i++)
            {
                int b = hdrOff + i * 144;
                va.ReadArray<byte>(b + 16, nm, 0, 32);
                int len = Array.IndexOf(nm, (byte)0); if (len < 0) len = 32;
                VarDef v = new VarDef();
                v.Name = Encoding.ASCII.GetString(nm, 0, len);
                v.Type = va.ReadInt32(b); v.Offset = va.ReadInt32(b + 4); v.Count = Math.Max(1, va.ReadInt32(b + 8));
                d[v.Name] = v;
            }
            return d;
        }

        static string ReadYaml(MemoryMappedViewAccessor va)
        {
            int len = va.ReadInt32(16), off = va.ReadInt32(20);
            if (len <= 0 || off <= 0) return "";
            byte[] bytes = new byte[len];
            va.ReadArray<byte>(off, bytes, 0, len);
            int z = Array.IndexOf(bytes, (byte)0); if (z < 0) z = len;
            return Encoding.GetEncoding(28591).GetString(bytes, 0, z);
        }

        // ---- JSON for one frame, limited to the variables a client asked for ----
        static int Size(int type) { return type <= 1 ? 1 : (type == 5 ? 8 : 4); }

        static void Val(StringBuilder sb, VarDef d, byte[] data, int p)
        {
            if (p < 0 || p + Size(d.Type) > data.Length) { sb.Append("null"); return; }
            switch (d.Type)
            {
                case 0: sb.Append(data[p]); break;
                case 1: sb.Append(data[p] != 0 ? '1' : '0'); break;
                case 2: sb.Append(BitConverter.ToInt32(data, p)); break;
                case 3: sb.Append(BitConverter.ToUInt32(data, p)); break;
                case 4:
                    {
                        float f = BitConverter.ToSingle(data, p);
                        if (float.IsNaN(f) || float.IsInfinity(f)) sb.Append("null");
                        else sb.Append(f.ToString("G7", CultureInfo.InvariantCulture));
                        break;
                    }
                case 5:
                    {
                        double x = BitConverter.ToDouble(data, p);
                        if (double.IsNaN(x) || double.IsInfinity(x)) sb.Append("null");
                        else sb.Append(x.ToString("G15", CultureInfo.InvariantCulture));
                        break;
                    }
                default: sb.Append("null"); break;
            }
        }

        public static string FrameJson(Frame f, string[] names)
        {
            StringBuilder sb = new StringBuilder(12000);
            sb.Append("{\"seq\":").Append(f.Seq).Append(",\"v\":{");
            bool first = true;
            foreach (string n in names)
            {
                VarDef d;
                if (!f.Vars.TryGetValue(n, out d)) continue;
                if (!first) sb.Append(',');
                first = false;
                sb.Append('"').Append(n).Append("\":");
                int sz = Size(d.Type);
                if (d.Count > 1)
                {
                    sb.Append('[');
                    for (int k = 0; k < d.Count; k++) { if (k > 0) sb.Append(','); Val(sb, d, f.Data, d.Offset + k * sz); }
                    sb.Append(']');
                }
                else Val(sb, d, f.Data, d.Offset);
            }
            sb.Append("}}");
            return sb.ToString();
        }
    }

    static class Json
    {
        public static string Str(string s)
        {
            StringBuilder sb = new StringBuilder(s.Length + 16);
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }
    }

    // ---------------- Tiny local HTTP server (loopback only) ----------------
    sealed class Server
    {
        readonly int port; readonly string www, maps;
        public Action OpenRequested;
        public Server(int port, string www, string maps) { this.port = port; this.www = Path.GetFullPath(www); this.maps = maps; }

        // 2026-10-15: Pi Toolbox, started by irdash (Cosworth), inherited the listening socket and kept port 8199 after irdash
        // stopped, so the next irdash could not start. A socket that no child process can inherit cannot be held that way.
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(IntPtr h, int mask, int flags);
        internal static void NoInherit(Socket s) { try { if (s != null) SetHandleInformation(s.Handle, 1, 0); } catch { } }

        public void Start()
        {
            TcpListener l = new TcpListener(IPAddress.Loopback, port);
            l.Start();
            NoInherit(l.Server);
            Thread t = new Thread(delegate ()
            {
                while (true)
                {
                    TcpClient c;
                    try { c = l.AcceptTcpClient(); NoInherit(c.Client); } catch { Thread.Sleep(100); continue; }
                    Thread h = new Thread(delegate () { Handle(c); });
                    h.IsBackground = true;
                    h.Start();
                }
            });
            t.IsBackground = true;
            t.Start();
            // the phone (phone.cs): LAN listeners only while Peter's one-time permission file exists; checked every 30 s, no restart needed
            Thread lan = new Thread(delegate ()
            {
                while (true)
                {
                    try { Phone.Sync(port, Handle); } catch (Exception ex) { Log.W("phone: " + ex.Message); }
                    Thread.Sleep(30000);
                }
            });
            lan.IsBackground = true;
            lan.Start();
        }

        static readonly Dictionary<string, string> Types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { ".html", "text/html; charset=utf-8" }, { ".js", "text/javascript; charset=utf-8" },
            { ".css", "text/css; charset=utf-8" }, { ".json", "application/json" }, { ".svg", "image/svg+xml" },
            { ".png", "image/png" }, { ".ico", "image/x-icon" }, { ".woff2", "font/woff2" },
            { ".jpg", "image/jpeg" }, { ".webmanifest", "application/manifest+json" }
        };

        static string DeckStateJson()
        {
            Frame f = Sdk.Latest;
            IRDeck.Snapshot s = new IRDeck.Snapshot();
            s.Sim = Process.GetProcessesByName("iRacingSim64DX11").Length > 0;
            s.Ui = Process.GetProcessesByName("iRacingUI").Length > 0;
            s.Fresh = Sdk.FreshDeck;
            s.Connected = f.Connected && f.Vars != null && f.Vars.ContainsKey("IsOnTrack") && f.Vars.ContainsKey("Speed") && f.Vars.ContainsKey("IsReplayPlaying");
            s.SessionKnown = !string.IsNullOrEmpty(f.SessionYaml);
            s.OnTrack = f.Num("IsOnTrack") != 0; s.Speed = f.Num("Speed"); s.Replay = f.Num("IsReplayPlaying") != 0;
            string info = f.SessionYaml ?? "";
            s.TestOrAi = Regex.IsMatch(info, @"(?m)^\s*EventType:\s*(Test|AI)\s*$", RegexOptions.IgnoreCase);
            IRDeck.DeckState state = IRDeck.DeckStateResolver.Resolve(s);
            return "{\"primary\":\"" + state.Primary + "\",\"label\":\"" + state.Label + "\",\"reason\":\"" + state.Reason + "\",\"armed\":{\"quit\":" + ArmedSeconds("quit-main") + ",\"restart\":" + ArmedSeconds("restart-race") + ",\"skip\":" + Math.Max(ArmedSeconds("skip"), ArmedSeconds("skip-session")) + "}}";
        }
        static int ArmedSeconds(string name)
        {
            try
            {
                string p = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "armed-" + name + ".txt");
                if (!File.Exists(p)) return 0;
                double left = 3.0 - (DateTime.UtcNow - File.GetLastWriteTimeUtc(p)).TotalSeconds;
                return left <= 0 ? 0 : (int)Math.Ceiling(left);
            }
            catch { return 0; }
        }

        void Handle(TcpClient c)
        {
            using (c)
            {
                try
                {
                    c.NoDelay = true;
                    NetworkStream s = c.GetStream();
                    s.ReadTimeout = 5000;
                    string head = ReadHead(s);
                    if (head == null) return;
                    string[] lines = head.Split(new[] { "\r\n" }, StringSplitOptions.None);
                    string[] req = lines[0].Split(' ');
                    if (req.Length < 2) return;
                    string method = req[0], target = req[1];
                    var hdr = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    for (int i = 1; i < lines.Length; i++)
                    {
                        int k = lines[i].IndexOf(':');
                        if (k > 0) hdr[lines[i].Substring(0, k).Trim()] = lines[i].Substring(k + 1).Trim();
                    }
                    // Only answer requests addressed to this machine by name or by its own LAN address (blocks DNS-rebinding tricks).
                    string host; hdr.TryGetValue("Host", out host);
                    if (host != "localhost:" + port && host != "127.0.0.1:" + port && !Phone.IsOurHost(host, port)) { Send(s, 403, "text/plain", Encoding.ASCII.GetBytes("forbidden")); return; }

                    string path = target, query = "";
                    int q = target.IndexOf('?');
                    if (q >= 0) { path = target.Substring(0, q); query = target.Substring(q + 1); }
                    path = Uri.UnescapeDataString(path);

                    if (method == "GET" && path == "/deck/state") { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(DeckStateJson()), "Access-Control-Allow-Origin: *\r\n"); return; }

                    // The phone's gate (phone.cs): anything not from this PC needs a pairing token, and the test hooks are never reachable
                    // from the LAN. ?asphone=1 asks for the same treatment from this PC (stricter only; tests\phone-test.ps1).
                    bool local = Phone.IsLocal(c);
                    if (!local || query.Contains("asphone=1"))
                    {
                        if (Phone.Hidden(path, method)) { Send(s, 404, "text/plain", Encoding.ASCII.GetBytes("not found")); return; }
                        if (!Phone.Open(path) && !Phone.TokenOk(ParseQuery(query), hdr)) { Send(s, 401, "application/json", Encoding.UTF8.GetBytes("{\"pair\":true}"), "Access-Control-Allow-Origin: *\r\n"); return; }
                    }
                    if (method == "GET" && path.StartsWith("/phone/", StringComparison.Ordinal))
                    {
                        int pc; string px; string pj = Phone.Route(path, ParseQuery(query), hdr, local, port, out pc, out px);
                        if (pj != null) { Send(s, pc, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(pj), px); return; }
                    }
                    if (method == "GET" && path == "/home") { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(Home.WithNextRace()), "Access-Control-Allow-Origin: *\r\n"); return; }   // HOME (home.cs)
                    if (method == "GET" && path == "/home/hero")
                    {
                        string ht; byte[] hb = Home.HeroBytes(out ht);
                        if (hb == null) Send(s, 404, "text/plain", Encoding.ASCII.GetBytes("no picture yet"));
                        else SendCached(s, ht, hb);
                        return;
                    }

                    if (method == "GET" && (path.StartsWith("/cars/", StringComparison.Ordinal) || path == "/api/test/cars"))      // CP-1: iRacing's own car pictures (cars.cs)
                    {
                        int cc; string ctp; byte[] cb; bool ccache;
                        if (Cars.TryHandle(path, ParseQuery(query), out cc, out ctp, out cb, out ccache))
                        {
                            if (ccache) SendCached(s, ctp, cb); else Send(s, cc, ctp, cb, "Access-Control-Allow-Origin: *\r\n");
                            return;
                        }
                    }

                    if (method == "GET" && path == "/stream") { Stream(s, ParseQuery(query)); return; }
                    if (method == "GET" && path == "/api/open")
                    {
                        if (OpenRequested != null) OpenRequested();
                        Send(s, 200, "text/plain", Encoding.ASCII.GetBytes("ok"));
                        return;
                    }
                    // read by the dashboard page and the Stream Deck add-on (its own origin, hence the CORS header)
                    if (method == "GET" && path == "/guest") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Guest.Json()), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/api/guest/draft")
                    {
                        // n absent = finished typing; letters, digits, spaces and hyphens only, 14 at most
                        string dn; bool typing = ParseQuery(query).TryGetValue("n", out dn);
                        Guest.Draft = typing ? Regex.Replace(dn ?? "", "[^A-Za-z0-9 -]", "").ToUpperInvariant() : null;
                        if (Guest.Draft != null && Guest.Draft.Length > 14) Guest.Draft = Guest.Draft.Substring(0, 14);
                        Send(s, 200, "text/plain", Encoding.ASCII.GetBytes("ok"), "Access-Control-Allow-Origin: *\r\n");
                        return;
                    }
                    if (method == "GET" && path == "/api/guest/do")
                    {
                        var gq = ParseQuery(query); string gc, ga; gq.TryGetValue("c", out gc); gq.TryGetValue("a", out ga);
                        bool ok = Guest.Do(gc ?? "", ga);
                        Send(s, ok ? 200 : 400, "text/plain", Encoding.ASCII.GetBytes(ok ? "ok" : "no"), "Access-Control-Allow-Origin: *\r\n");
                        return;
                    }
                    // one dispatcher for every Stream Deck screen: friends commands go to Guest, the rest to Overlays (both whitelisted)
                    if (method == "GET" && path == "/api/do")
                    {
                        var dq = ParseQuery(query); string dc, da; dq.TryGetValue("c", out dc); dq.TryGetValue("a", out da);
                        // the flat data-drawn TV map was rejected; the real TV view is not built yet, so this one command is off (P0-03)
                        if (dc == "tvview") { Send(s, 400, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("TV view rebuild")); return; }
                        if (dc == "vault") dc = "vkopen";      // the deck's VAULT key sends "vault"; it had no handler (2026-10-18), the Vault's open command is vkopen
                        bool ok = TvView.Handles(dc ?? "") ? TvView.Do(dc, da) : Nav.Handles(dc ?? "") ? Nav.Do(dc, da) : Overlays.Handles(dc ?? "") ? Overlays.Do(dc, da) : MyDrive.Handles(dc) ? MyDrive.Do(dc, da)
                            : Replay.Handles(dc) ? Replay.Do(dc, da) : Gallery.Handles(dc) ? Gallery.Do(dc, da) : Perf.Handles(dc) ? Perf.Do(dc, da) : Vault.Handles(dc) ? Vault.Do(dc, da) : Official.Handles(dc) ? Official.Do(dc, da) : Workbench.Handles(dc) ? Workbench.Do(dc, da) : Sound.Handles(dc) ? Sound.Do(dc, da) : DeckFeed.Handles(dc) ? DeckFeed.Do(dc, da) : Debrief.Handles(dc) ? Debrief.Do(dc, da) : Phone.Handles(dc) ? Phone.Do(dc, da) : Guest.Do(dc ?? "", da);
                        Send(s, ok ? 200 : 400, "text/plain", Encoding.ASCII.GetBytes(ok ? "ok" : "no"), "Access-Control-Allow-Origin: *\r\n");
                        return;
                    }
                    if (method == "GET" && path == "/mydrive") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(MyDrive.Json()), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/mydrive/lists") { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(MyDrive.ListsJson()), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/replay") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Replay.Json()), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/api/test/replaylog")
                    {
                        // test hook for tests\replay-test.ps1: the SDK messages the REPLAY screen would have sent while the pretend session is on (?clear=1 empties the list)
                        if (!Sdk.TestHook)
                        {
                            string rbusy = Sdk.RealBusy();
                            if (rbusy != null) { Log.W("test hook refused: " + rbusy); Send(s, 409, "text/plain", Encoding.UTF8.GetBytes("refused: " + rbusy)); return; }
                            Send(s, 404, "text/plain", Encoding.ASCII.GetBytes("not found")); return;
                        }
                        Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Replay.TestLog(ParseQuery(query).ContainsKey("clear"))));
                        return;
                    }
                    if (method == "GET" && path == "/gallery") { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(Gallery.Json()), "Access-Control-Allow-Origin: *\r\n"); return; }   // charset: captions have accents
                    if (method == "GET" && (path == "/corners" || path.StartsWith("/corners/")))      // corner model (corners.cs, docs\corners.md)
                    {
                        int cc; string cj = Corners.Route(path, ParseQuery(query), out cc);
                        if (cj != null) { Send(s, cc, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(cj), "Access-Control-Allow-Origin: *\r\n"); return; }
                    }
                    if (method == "GET" && path.StartsWith("/analysis/pro/", StringComparison.Ordinal))      // maths channels + CSV / Excel export (protools.cs): JSON, PWB1 or a file; 503 while he drives
                    {
                        int pc; string pt, ph; byte[] pb = Analysis.ProRoute(path, ParseQuery(query), out pc, out pt, out ph);
                        Send(s, pc, pt, pb, ph); return;
                    }
                    if (method == "GET" && path == "/analysis/channels")      // workbench channel arrays (workbench.cs): binary reply, JSON error, 503 while he is driving
                    {
                        int wc; byte[] wb = Analysis.ChannelsRoute(ParseQuery(query), out wc);
                        Send(s, wc, wc == 200 ? "application/octet-stream" : "application/json; charset=utf-8", wb, "Access-Control-Allow-Origin: *\r\n"); return;
                    }
                    if (method == "GET" && path == "/workbench/cmd") { DeckFeed.Workbench(ParseQuery(query)); Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Workbench.Json()), "Access-Control-Allow-Origin: *\r\n"); return; }   // the deck's last wb-* command for the page (the page's own state rides on the query: deckfeed.cs)
                    if (method == "GET" && path == "/workbench/state") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(DeckFeed.WorkbenchJson()), "Access-Control-Allow-Origin: *\r\n"); return; }   // what the ANALYSIS deck screen reads
                    if (method == "GET" && path == "/sound") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Sound.Json(!ParseQuery(query).ContainsKey("peek"))), "Access-Control-Allow-Origin: *\r\n"); return; }   // the SOUND deck screen (sound.cs); ?peek=1 = the opener key, no refresh
                    if (method == "GET" && (path == "/analysis/race" || path == "/field/status" || path.StartsWith("/api/test/field", StringComparison.Ordinal)))      // the race field log (field.cs, W6): every car's laps, gaps, pits, passes; test hook routes check Sdk.TestHook themselves
                    { int fc; string fj = RaceField.Route(path, ParseQuery(query), out fc); Send(s, fc, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(fj), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/debrief") { int dc; string dj = Debrief.Route(path, ParseQuery(query), out dc); Send(s, dc, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(dj), "Access-Control-Allow-Origin: *\r\n"); return; }   // D-01 debrief engine (debrief.cs): result, position by lap, pace vs field, practice fallback
                    if (method == "GET" && path == "/debrief/state") { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(Debrief.StateJson()), "Access-Control-Allow-Origin: *\r\n"); return; }   // D-05: what the deck's DEBRIEF row acts on
                    if (method == "GET" && path == "/debrief/active") { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(Debrief.ActiveJson(ParseQuery(query))), "Access-Control-Allow-Origin: *\r\n"); return; }   // D-05: visible-screen lease for deck actions
                    if (method == "GET" && path == "/debrief/nav") { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(Debrief.NavJson()), "Access-Control-Allow-Origin: *\r\n"); return; }   // D-05: the DEEP DIVE the deck asked for, for the dashboard's debrief screen
                    if (method == "GET" && path == "/debrief/video") { var vq = ParseQuery(query); string vid; vq.TryGetValue("id", out vid); Debrief.ServeVideo(s, vid, hdr); return; }   // D-04: the corner/incident clip this engine cut (Range works)
                    if (method == "GET" && path == "/analysis/session") { int sc; string sj = Analysis.SessionRoute(ParseQuery(query), out sc); Send(s, sc, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(sj), "Access-Control-Allow-Origin: *\r\n"); return; }   // Session Review data (sessionreview.cs, C-40): one JSON for the whole timing screen, 503 while he drives
                    if (method == "GET" && (path == "/analysis/lap" || path.StartsWith("/analysis/")))      // lap analysis engines (analysis.cs). Reads old files only; 503 while he is driving.
                    {
                        int ac; string aj = Analysis.Route(path, ParseQuery(query), out ac);
                        Send(s, ac, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(aj), "Access-Control-Allow-Origin: *\r\n"); return;
                    }
                    if (method == "GET" && path.StartsWith("/share/", StringComparison.Ordinal) && Share.Handle(s, path, ParseQuery(query), hdr, local && !query.Contains("asphone=1"))) return;      // share studio + replay jump (share.cs, replayjump.cs); /share/open and /share/jump are for this PC only
                    // Vault (vault.cs) and the recorder's session video (S1, /api/rec/*). Off until vault=1. The test hook may use /vault/test while it is off.
                    if ((method == "GET" || method == "POST") && (path == "/vault" || path.StartsWith("/vault/") || path.StartsWith("/api/rec/", StringComparison.Ordinal)))
                    {
                        bool vaultTest = path.StartsWith("/vault/test/", StringComparison.Ordinal) && Sdk.TestHook;
                        if (!Vault.Serving && !vaultTest) { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"enabled\":false}"), "Access-Control-Allow-Origin: *\r\n"); return; }
                        if (Vault.Handle(s, path, ParseQuery(query), hdr)) return;
                    }
                    if (method == "GET" && (path == "/watch/coverage" || path == "/api/watch/open"))      // where to watch in the U.S. (coverage.cs)
                    {
                        int wc; string wj = Coverage.Route(path, ParseQuery(query), out wc);
                        Send(s, wc, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(wj)); return;
                    }
                    if (method == "GET" && path == "/realworld")
                    {
                        int rc; string rj = RealWorld.Route(path, ParseQuery(query), out rc);
                        if (rj != null) { Send(s, rc, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(rj), "Access-Control-Allow-Origin: *\r\n"); return; }
                    }
                    if (method == "GET" && (path == "/official" || path.StartsWith("/official/")))      // official racing (official.cs). Off until official=1.
                    {
                        if (!Official.Enabled) { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"enabled\":false}"), "Access-Control-Allow-Origin: *\r\n"); return; }
                        int oc; string oj = Official.Route(path, ParseQuery(query), out oc);
                        if (oj != null) { Send(s, oc, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(oj), "Access-Control-Allow-Origin: *\r\n"); return; }
                    }
                    if (method == "GET" && (path == "/perf" || path.StartsWith("/perf/")))
                    {
                        int pc; string pj = Perf.Route(path, ParseQuery(query), out pc);
                        if (pj != null) { Send(s, pc, "application/json", Encoding.UTF8.GetBytes(pj), "Access-Control-Allow-Origin: *\r\n"); return; }
                    }
                    if (method == "GET" && path == "/tv") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(TvView.On ? "{\"on\":true}" : "{\"on\":false}"), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/tv/data") { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(Tv.Json()), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/overlays") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Overlays.Json()), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/doctor") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Doctor.Json()), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/api/doctor/run") { Doctor.Run(!ParseQuery(query).ContainsKey("quiet")); Send(s, 200, "text/plain", Encoding.ASCII.GetBytes("ok")); return; }   // ?quiet=1: check without showing the list
                    if (method == "GET" && path == "/api/delta/preview")
                    {
                        string secs; int sn = 5; if (ParseQuery(query).TryGetValue("s", out secs)) int.TryParse(secs, out sn);
                        DeltaBar.Preview(Math.Max(1, Math.Min(30, sn)));
                        Send(s, 200, "text/plain", Encoding.ASCII.GetBytes("ok"));
                        return;
                    }
                    if (method == "GET" && (path == "/api/test/frame" || path == "/api/test/end"))
                    {
                        // test hook for tests\overlays-test.ps1: a pretend session for irdash's own readers. Off unless dash\test-hook.on exists.
                        if (!Sdk.TestHook)
                        {
                            // /api/test/end always works (it only ever stops a pretend session)
                            string busy = Sdk.RealBusy();
                            if (path == "/api/test/end") { Sdk.FakeEnd(); Send(s, 200, "text/plain", Encoding.ASCII.GetBytes("ok")); return; }
                            if (busy != null) { Log.W("test hook refused: " + busy); Send(s, 409, "text/plain", Encoding.UTF8.GetBytes("refused: " + busy)); return; }
                            Send(s, 404, "text/plain", Encoding.ASCII.GetBytes("not found")); return;
                        }
                        if (path == "/api/test/end") Sdk.FakeEnd();
                        else
                        {
                            var vals = new Dictionary<string, double>();
                            foreach (KeyValuePair<string, string> kv in ParseQuery(query))
                            { double dv; if (Regex.IsMatch(kv.Key, "^[A-Za-z0-9_]{1,40}$") && double.TryParse(kv.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out dv)) vals[kv.Key] = dv; }
                            Sdk.FakeSet(vals);
                        }
                        Send(s, 200, "text/plain", Encoding.ASCII.GetBytes("ok"));
                        return;
                    }
                    if (method == "GET")
                    {
                        // sessions page, lap analysis, pre-session brief, race extras, page requests (data.cs)
                        int dcode; string dtype; byte[] dbody;
                        if (DataApi.TryHandle(path, ParseQuery(query), out dcode, out dtype, out dbody)) { Send(s, dcode, dtype, dbody); return; }
                    }
                    if (method == "GET" && path == "/api/guest/lap")
                    {
                        string ts; double lt;
                        if (ParseQuery(query).TryGetValue("t", out ts) && double.TryParse(ts, NumberStyles.Float, CultureInfo.InvariantCulture, out lt)) Guest.Lap(lt);
                        Send(s, 204, "text/plain", new byte[0]);
                        return;
                    }
                    if (method == "GET" && path == "/timings") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Timings.Json()), "Access-Control-Allow-Origin: *\r\n"); return; }
                    if (method == "GET" && path == "/career") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Career.Json())); return; }
                    if (method == "GET" && path == "/systems") { Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Systems.Json())); return; }
                    if (method == "GET" && path == "/showcase")
                    {
                        string who; ParseQuery(query).TryGetValue("who", out who);
                        // readable by the Stream Deck add-on (a local page with its own origin); holds only play/seq flags
                        Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Showcase.Json(who)), "Access-Control-Allow-Origin: *\r\n");
                        return;
                    }
                    if (method == "GET" && path == "/api/showcase") { Showcase.Request(); Send(s, 200, "text/plain", Encoding.ASCII.GetBytes("ok")); return; }
                    if (method == "GET" && path == "/health")
                    {
                        Send(s, 200, "application/json", Encoding.UTF8.GetBytes(Watch.Json(Sdk.Latest.Connected)));
                        return;
                    }
                    if (method == "GET" && path == "/api/tow-wait")
                    {
                        // irdeck writes dash\tow-wait.txt (a UTC expiry) while RESET CAR waits for the car to stop
                        bool on = false;
                        try
                        {
                            string tw = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "tow-wait.txt");
                            long ticks;
                            if (File.Exists(tw) && long.TryParse(File.ReadAllText(tw).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out ticks))
                                on = ticks > DateTime.UtcNow.Ticks;
                        }
                        catch { }
                        Send(s, 200, "application/json", Encoding.UTF8.GetBytes(on ? "{\"on\":true}" : "{\"on\":false}"), "Access-Control-Allow-Origin: *\r\n");
                        return;
                    }
                    if (method == "GET" && path == "/keymsg") { Send(s, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(KeyMsg.Current()), "Access-Control-Allow-Origin: *\r\n"); return; }   // the top screen's "what that deck key did" line (keymsg.cs)
                    if (method == "GET" && path == "/api/keymsg")
                    {
                        // irdeck says what a deck key did. This PC only; the phone never writes it. Nothing here touches iRacing.
                        if (!local || query.Contains("asphone=1")) { Send(s, 404, "text/plain", Encoding.ASCII.GetBytes("not found")); return; }
                        var kq = ParseQuery(query); string kk, kt, kd;
                        kq.TryGetValue("key", out kk); kq.TryGetValue("text", out kt); kq.TryGetValue("kind", out kd);
                        string kept = KeyMsg.Set(kk, kt, kd);
                        Send(s, kept.Length > 0 ? 200 : 400, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes(kept.Length > 0 ? "ok" : "no text"));
                        return;
                    }
                    if (method == "GET" && path == "/api/kids")
                    {
                        // irdeck writes dash\kids.lock (this boot's id). The top screen says so while that lock is current.
                        bool kidsOn = KidsLockOn();
                        string kidsBody = kidsOn ? "{\"on\":true,\"text\":\"KIDS MODE  -  keyboard and deck locked  -  to unlock press KIDS, then HOME\"}" : "{\"on\":false,\"text\":\"\"}";
                        Send(s, 200, "application/json", Encoding.UTF8.GetBytes(kidsBody), "Access-Control-Allow-Origin: *\r\n");
                        return;
                    }
                    if (method == "GET" && path == "/version")
                    {
                        // newest change to the dashboard files or the exe; the page reloads itself when this changes
                        long v = File.GetLastWriteTimeUtc(System.Reflection.Assembly.GetExecutingAssembly().Location).Ticks;
                        foreach (string f in Directory.GetFiles(www, "*", SearchOption.AllDirectories))
                            if (!f.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) v = Math.Max(v, File.GetLastWriteTimeUtc(f).Ticks);
                        Send(s, 200, "text/plain", Encoding.ASCII.GetBytes(v.ToString()));
                        return;
                    }
                    if (method == "GET" && path == "/trackmap")
                    {
                        var tq = ParseQuery(query);
                        string key, id, name;
                        tq.TryGetValue("key", out key); tq.TryGetValue("id", out id); tq.TryGetValue("name", out name);
                        if (key == null || !Regex.IsMatch(key, "^[a-z0-9_-]{1,80}$")) { Send(s, 400, "text/plain", Encoding.ASCII.GetBytes("bad key")); return; }
                        string json = TrackMaps.Resolve(key, id, name);
                        if (json == null) Send(s, 202, "application/json", Encoding.UTF8.GetBytes(TrackMaps.BuildState(key)));
                        else Send(s, 200, "application/json", Encoding.UTF8.GetBytes(json));
                        return;
                    }
                    if (path.StartsWith("/maps/")) { Maps(s, method, path.Substring(6), hdr); return; }
                    if (method != "GET") { Send(s, 405, "text/plain", Encoding.ASCII.GetBytes("method not allowed")); return; }

                    string rel = path.EndsWith("/") ? path.TrimStart('/').Replace('/', '\\') + "index.html" : path.TrimStart('/').Replace('/', '\\');
                    // A path with a colon or other odd characters ("/v2/a:b") makes GetFullPath throw: the page used to get no answer at all
                    // and the log filled with "http: The given path's format is not supported." (15 times in the 2026-10-18 17:22 drive). It is just "not found".
                    string full;
                    try { full = Path.GetFullPath(Path.Combine(www, rel)); }
                    catch (ArgumentException) { Send(s, 404, "text/plain", Encoding.ASCII.GetBytes("not found")); return; }
                    catch (NotSupportedException) { Send(s, 404, "text/plain", Encoding.ASCII.GetBytes("not found")); return; }
                    if (!full.StartsWith(www + "\\", StringComparison.OrdinalIgnoreCase) || !File.Exists(full))
                    { Send(s, 404, "text/plain", Encoding.ASCII.GetBytes("not found")); return; }
                    string ct; if (!Types.TryGetValue(Path.GetExtension(full), out ct)) ct = "application/octet-stream";
                    Send(s, 200, ct, File.ReadAllBytes(full));
                }
                catch (IOException) { }
                catch (ObjectDisposedException) { }
                catch (Exception ex) { Log.W("http: " + ex.Message); }
            }
        }

        void Maps(NetworkStream s, string method, string name, Dictionary<string, string> hdr)
        {
            if (!Regex.IsMatch(name, "^[A-Za-z0-9_.-]{1,100}\\.json$") || name.Contains(".."))
            { Send(s, 400, "text/plain", Encoding.ASCII.GetBytes("bad name")); return; }
            string file = Path.Combine(maps, name);
            if (method == "GET")
            {
                if (File.Exists(file)) Send(s, 200, "application/json", File.ReadAllBytes(file));
                else Send(s, 404, "text/plain", Encoding.ASCII.GetBytes("no map"));
                return;
            }
            if (method == "PUT")
            {
                string cl; int len;
                if (!hdr.TryGetValue("Content-Length", out cl) || !int.TryParse(cl, out len) || len <= 0 || len > 4000000)
                { Send(s, 411, "text/plain", Encoding.ASCII.GetBytes("length required")); return; }
                byte[] body = new byte[len];
                int got = 0;
                while (got < len) { int n = s.Read(body, got, len - got); if (n <= 0) return; got += n; }
                Directory.CreateDirectory(maps);
                string tmp = file + ".tmp";
                File.WriteAllBytes(tmp, body);
                if (File.Exists(file)) File.Delete(file);
                File.Move(tmp, file);
                Log.W("saved track map " + name);
                Send(s, 204, "text/plain", new byte[0]);
                return;
            }
            Send(s, 405, "text/plain", Encoding.ASCII.GetBytes("method not allowed"));
        }

        void Stream(NetworkStream s, Dictionary<string, string> q)
        {
            string varList; q.TryGetValue("vars", out varList);
            string[] names = (varList ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
            string hzs; int hz;
            if (!q.TryGetValue("hz", out hzs) || !int.TryParse(hzs, out hz)) hz = 30;
            hz = Math.Max(1, Math.Min(60, hz));
            int interval = 1000 / hz;

            Write(s, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 1000\n\n");
            long lastSeq = -1; int sentSess = -1;
            Stopwatch sw = Stopwatch.StartNew();
            long lastSend = -100000;
            while (true)
            {
                Frame f = Sdk.WaitNext(lastSeq, 1000);
                if (f.Seq == lastSeq) { Write(s, ": ping\n\n"); continue; }
                long wait = interval - (sw.ElapsedMilliseconds - lastSend);
                if (wait > 0) { Thread.Sleep((int)wait); f = Sdk.Latest; }
                lastSend = sw.ElapsedMilliseconds;
                lastSeq = f.Seq;
                if (!f.Connected)
                {
                    sentSess = -1;
                    Write(s, "event: status\ndata: {\"connected\":false}\n\n");
                    continue;
                }
                StringBuilder sb = new StringBuilder();
                if (f.SessionVersion != sentSess)
                {
                    sb.Append("event: session\ndata: ").Append(Json.Str(f.SessionYaml)).Append("\n\n");
                    sentSess = f.SessionVersion;
                }
                sb.Append("data: ").Append(Sdk.FrameJson(f, names)).Append("\n\n");
                Write(s, sb.ToString());
            }
        }

        static void Write(NetworkStream s, string text)
        {
            byte[] b = Encoding.UTF8.GetBytes(text);
            s.Write(b, 0, b.Length);
            s.Flush();
        }

        // K-01. Keep this in step with src\kids.cs KidsBootId: kernel BootTime, else clock minus uptime in whole minutes.
        [System.Runtime.InteropServices.DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, byte[] info, int len, out int ret);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern ulong GetTickCount64();
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern void GetSystemTimeAsFileTime(out long ft);
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
        static bool KidsLockOn()
        {
            try
            {
                string dir = AppDomain.CurrentDomain.BaseDirectory;
                if (File.Exists(Path.Combine(dir, "kids.stop"))) return false;
                string p = Path.Combine(dir, "kids.lock");
                if (!File.Exists(p)) return false;
                long boot = 0, until = 0;
                foreach (string line in File.ReadAllLines(p))
                {
                    int i = line.IndexOf('=');
                    if (i <= 0) continue;
                    string k = line.Substring(0, i).Trim();
                    string v = line.Substring(i + 1).Trim();
                    if (k == "boot") long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out boot);
                    else if (k == "until") long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out until);
                }
                long nowBoot = KidsBootId();
                if (boot == 0 || nowBoot == 0 || boot != nowBoot) return false;
                if (until > 0 && DateTime.UtcNow.Ticks > until) return false;
                return true;
            }
            catch { return false; }
        }

        static void Send(NetworkStream s, int code, string type, byte[] body) { Send(s, code, type, body, ""); }

        // a picture that may be cached for an hour (the hero: the page adds ?v=<file time>, so a new file still shows at once)
        static void SendCached(NetworkStream s, string type, byte[] body)
        {
            string h = "HTTP/1.1 200 OK\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n";
            byte[] hb = Encoding.ASCII.GetBytes(h);
            s.Write(hb, 0, hb.Length);
            s.Write(body, 0, body.Length);
            s.Flush();
        }

        static void Send(NetworkStream s, int code, string type, byte[] body, string extraHeaders)
        {
            string reason = code == 200 ? "OK" : code == 202 ? "Accepted" : code == 204 ? "No Content" : code == 404 ? "Not Found" : code == 503 ? "Service Unavailable" : "Error";
            string h = "HTTP/1.1 " + code + " " + reason + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length +
                       "\r\nCache-Control: no-store\r\nConnection: close\r\n" + extraHeaders + "\r\n";
            byte[] hb = Encoding.ASCII.GetBytes(h);
            s.Write(hb, 0, hb.Length);
            if (body.Length > 0) s.Write(body, 0, body.Length);
            s.Flush();
        }

        static string ReadHead(NetworkStream s)
        {
            List<byte> buf = new List<byte>(1024);
            while (buf.Count < 16384)
            {
                int b = s.ReadByte();
                if (b < 0) return null;
                buf.Add((byte)b);
                int n = buf.Count;
                if (n >= 4 && buf[n - 4] == 13 && buf[n - 3] == 10 && buf[n - 2] == 13 && buf[n - 1] == 10)
                    return Encoding.ASCII.GetString(buf.ToArray(), 0, n - 4);
            }
            return null;
        }

        static Dictionary<string, string> ParseQuery(string q)
        {
            var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string part in q.Split('&'))
            {
                if (part.Length == 0) continue;
                int e = part.IndexOf('=');
                string k = e < 0 ? part : part.Substring(0, e), v = e < 0 ? "" : part.Substring(e + 1);
                d[Uri.UnescapeDataString(k)] = Uri.UnescapeDataString(v.Replace('+', ' '));
            }
            return d;
        }
    }

    // ---------------- Track maps ----------------
    // iRacing does not put GPS (Lat/Lon) in the live SDK data, only in the .ibt files it logs to disk.
    // So maps come from, in order: your own .ibt laps (exact), then the SIMRacingApps library (Apache-2.0,
    // keyed by lap percentage so it lines up with LapDistPct). Results are saved in dash\maps\<key>.json.
    static class TrackMaps
    {
        public const int N = 720;
        public static string MapsDir, TelemetryDir;
        static readonly object gate = new object();
        static readonly Dictionary<string, string> fileKey = new Dictionary<string, string>();      // ibt path|size -> track key
        static readonly HashSet<string> ibtFailed = new HashSet<string>();                           // ibt path|size|key that had no clean lap
        static readonly Dictionary<string, DateTime> libTried = new Dictionary<string, DateTime>();

        public static string MakeKey(string id, string name)
        {
            string k = ("t" + (string.IsNullOrEmpty(id) ? "0" : id) + "-" + (string.IsNullOrEmpty(name) ? "track" : name)).ToLowerInvariant();
            k = Regex.Replace(k, "[^a-z0-9_-]+", "-");
            return k.Length > 80 ? k.Substring(0, 80) : k;
        }

        // Returns the cached map JSON for a track, or null ("building"). Never reads telemetry or the network here: this
        // runs on the HTTP thread the top screen polls, and it used to rebuild from up to 15 .ibt files under the same
        // lock BuildAll holds for minutes at startup (the straight-bar placeholder). A missing or library-only map is
        // queued for the background builder instead.
        public static string Resolve(string key, string id, string name)
        {
            string file = Path.Combine(MapsDir, key + ".json"), json = null;
            try { if (File.Exists(file)) json = File.ReadAllText(file); } catch (IOException) { json = null; }   // mid-Save: treat as building
            if (json == null)
            {
                // the offline library copy is one small local file: cheap enough for the request, so a cold start still has a map
                // no lock: BuildAll may hold the builder lock for minutes at startup; a clashing Save just fails and the builder writes it later
                try { json = FromLibrary(key, name, true); if (json != null) Save(file, json); } catch (Exception ex) { Log.W("maps: " + key + ": " + ex.Message); }
            }
            if (json == null || !json.Contains("\"source\":\"ibt\"")) QueueBuild(key, name);
            return AddGps(key, json);
        }

        // ---- background builder: one thread, below normal, the active telemetry file excluded ----
        static readonly object qgate = new object();
        static readonly Queue<string[]> buildQ = new Queue<string[]>();
        static readonly Dictionary<string, DateTime> nextTry = new Dictionary<string, DateTime>();
        static readonly Dictionary<string, int> fails = new Dictionary<string, int>();
        static readonly Dictionary<string, string> lastError = new Dictionary<string, string>();
        static Thread builder;

        static void QueueBuild(string key, string name)
        {
            lock (qgate)
            {
                DateTime t;
                if (nextTry.TryGetValue(key, out t) && DateTime.UtcNow < t) return;
                foreach (string[] q in buildQ) if (q[0] == key) return;
                buildQ.Enqueue(new string[] { key, name ?? "" });
                nextTry[key] = DateTime.UtcNow.AddSeconds(30);     // no re-queue while this one is pending
                if (builder == null)
                {
                    builder = new Thread(BuildLoop) { IsBackground = true, Priority = ThreadPriority.BelowNormal, Name = "map builder" };
                    builder.Start();
                }
                Monitor.Pulse(qgate);
            }
        }

        static void BuildLoop()
        {
            while (true)
            {
                string[] job;
                lock (qgate) { while (buildQ.Count == 0) Monitor.Wait(qgate); job = buildQ.Dequeue(); }
                string key = job[0], name = job[1], file = Path.Combine(MapsDir, key + ".json"), err = "";
                bool ok = false;
                try
                {
                    lock (gate)
                    {
                        string have = File.Exists(file) ? File.ReadAllText(file) : null;
                        if (have != null && have.Contains("\"source\":\"ibt\"")) ok = true;
                        else
                        {
                            string built = FromIbt(key);
                            if (built != null) { Save(file, built); ok = true; }
                            else if (have == null)
                            {
                                string lib = FromLibrary(key, name);
                                if (lib != null) { Save(file, lib); ok = true; }
                                else err = "no clean lap in telemetry and no library outline";
                            }
                            else ok = true;     // a library map stays until telemetry can do better
                        }
                    }
                }
                catch (Exception ex) { err = ex.Message; }
                lock (qgate)
                {
                    // retry 1 / 5 / 15 / 60 minutes after failures; a success re-checks in 15 min (new laps may improve it)
                    int n; fails.TryGetValue(key, out n);
                    if (ok) { fails[key] = 0; lastError.Remove(key); nextTry[key] = DateTime.UtcNow.AddMinutes(15); }
                    else
                    {
                        n++; fails[key] = n; lastError[key] = err;
                        int[] back = { 1, 5, 15, 60 };
                        nextTry[key] = DateTime.UtcNow.AddMinutes(back[Math.Min(n - 1, back.Length - 1)]);
                        Log.W("maps: " + key + " not built (" + err + ") - next try in " + back[Math.Min(n - 1, back.Length - 1)] + " min");
                    }
                }
            }
        }

        // what the builder knows about one track, for the 202 answer
        public static string BuildState(string key)
        {
            lock (qgate)
            {
                DateTime t; string e; int retry = 15;
                if (nextTry.TryGetValue(key, out t)) retry = Math.Max(5, Math.Min(3600, (int)(t - DateTime.UtcNow).TotalSeconds));
                lastError.TryGetValue(key, out e);
                return "{\"status\":\"building\",\"retryAfter\":" + retry + ",\"lastError\":" + Json_.S(e ?? "") + "}";
            }
        }

        // the telemetry file iRacing may be writing right now: never read on any map path
        static bool ActiveIbt(FileInfo fi)
        {
            if ((DateTime.Now - fi.LastWriteTime).TotalSeconds < 120) return true;
            return Process.GetProcessesByName("iRacingSim64DX11").Length > 0 && (DateTime.Now - fi.LastWriteTime).TotalMinutes < 30;
        }

        // The measured GPS line (gpsmap.cs) is exposed beside the geometry; with no geometry at all it is the map.
        static string AddGps(string key, string json)
        {
            string gps = Analysis.GpsFragmentFor(key, MapsDir);
            if (gps == null) return json;
            if (json == null) return Analysis.GpsOnlyMap(key, MapsDir);
            if (json.IndexOf("\"gps\":", StringComparison.Ordinal) >= 0) return json;      // already added
            int close = json.LastIndexOf('}');
            return close < 0 ? json : json.Substring(0, close) + ",\"gps\":" + gps + "}";
        }

        static void Save(string file, string json)
        {
            Directory.CreateDirectory(MapsDir);
            File.WriteAllText(file + ".tmp", json);
            if (File.Exists(file)) File.Delete(file);
            File.Move(file + ".tmp", file);
        }

        // ---- .ibt (disk telemetry) ----
        internal sealed class Ibt
        {
            public FileStream fs; public int bufLen, dataOff; public long records; public string yaml = "";
            public Dictionary<string, VarDef> vars = new Dictionary<string, VarDef>();
        }

        internal static Ibt OpenIbt(string path, bool wantVars)
        {
            FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            byte[] h = new byte[144];
            if (fs.Read(h, 0, h.Length) < h.Length) { fs.Dispose(); return null; }
            Ibt t = new Ibt();
            t.fs = fs;
            int infoLen = BitConverter.ToInt32(h, 16), infoOff = BitConverter.ToInt32(h, 20);
            int numVars = BitConverter.ToInt32(h, 24), varOff = BitConverter.ToInt32(h, 28);
            t.bufLen = BitConverter.ToInt32(h, 36); t.dataOff = BitConverter.ToInt32(h, 52);
            if (t.bufLen <= 0 || t.dataOff <= 0 || infoLen <= 0 || infoLen > 4000000) { fs.Dispose(); return null; }
            t.records = (fs.Length - t.dataOff) / t.bufLen;
            byte[] info = new byte[infoLen];
            fs.Position = infoOff; fs.Read(info, 0, infoLen);
            int z = Array.IndexOf(info, (byte)0); if (z < 0) z = infoLen;
            t.yaml = Encoding.GetEncoding(28591).GetString(info, 0, z);
            if (wantVars)
            {
                byte[] vh = new byte[numVars * 144];
                fs.Position = varOff; fs.Read(vh, 0, vh.Length);
                for (int i = 0; i < numVars; i++)
                {
                    int b = i * 144;
                    int len = Array.IndexOf(vh, (byte)0, b + 16, 32) - (b + 16); if (len < 0) len = 32;
                    VarDef v = new VarDef();
                    v.Name = Encoding.ASCII.GetString(vh, b + 16, len);
                    v.Type = BitConverter.ToInt32(vh, b); v.Offset = BitConverter.ToInt32(vh, b + 4); v.Count = BitConverter.ToInt32(vh, b + 8);
                    t.vars[v.Name] = v;
                }
            }
            return t;
        }

        internal static string YamlValue(string yaml, string key)
        {
            // spaces and tabs only (not \s): an empty value such as "TrackConfigName:" must not pick up the next line
            Match m = Regex.Match(yaml, "^[ \\t]*" + key + ":[ \\t]*(.*?)[ \\t\\r]*$", RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value.Trim('"') : "";
        }

        static string IbtKey(string path, out string sig)
        {
            FileInfo fi = new FileInfo(path);
            sig = path + "|" + fi.Length;
            string k;
            if (fileKey.TryGetValue(sig, out k)) return k;
            try
            {
                Ibt t = OpenIbt(path, false);
                if (t == null) return null;
                using (t.fs) k = MakeKey(YamlValue(t.yaml, "TrackID"), YamlValue(t.yaml, "TrackName"));
            }
            catch { return null; }
            fileKey[sig] = k;
            return k;
        }

        public static List<string> IbtTracks()
        {
            var keys = new List<string>();
            if (TelemetryDir == null || !Directory.Exists(TelemetryDir)) return keys;
            foreach (string f in Directory.GetFiles(TelemetryDir, "*.ibt"))
            {
                string sig, k = IbtKey(f, out sig);
                if (k != null && !keys.Contains(k)) keys.Add(k);
            }
            return keys;
        }

        // Combines every clean on-track sample from all of your sessions at a track (newest 15 files),
        // so short runs and partial laps still add up to a full outline.
        sealed class Acc { public double[] lat = new double[N], lon = new double[N]; public int[] cnt = new int[N]; public List<double[]> pit = new List<double[]>(); public double pitLen; public int files; }
        static readonly Dictionary<string, string> ibtFailedSig = new Dictionary<string, string>();

        static string FromIbt(string key)
        {
            if (TelemetryDir == null || !Directory.Exists(TelemetryDir)) return null;
            var files = new List<FileInfo>(new DirectoryInfo(TelemetryDir).GetFiles("*.ibt"));
            files.Sort(delegate (FileInfo a, FileInfo b) { return b.LastWriteTime.CompareTo(a.LastWriteTime); });
            var mine = new List<FileInfo>(); StringBuilder sigs = new StringBuilder();
            foreach (FileInfo fi in files)
            {
                if (ActiveIbt(fi)) continue;
                string sig, k = IbtKey(fi.FullName, out sig);
                if (k != key) continue;
                mine.Add(fi); sigs.Append(sig).Append(';');
                if (mine.Count >= 15) break;
            }
            if (mine.Count == 0) return null;
            string all = sigs.ToString(), failed;
            if (ibtFailedSig.TryGetValue(key, out failed) && failed == all) return null;   // nothing new since last try

            Acc acc = new Acc(); string yaml = "";
            foreach (FileInfo fi in mine)
            {
                try { string y = AddIbt(fi.FullName, acc); if (y != null) { acc.files++; if (yaml == "") yaml = y; } }
                catch (Exception ex) { Log.W("ibt " + fi.Name + ": " + ex.Message); }
            }
            int filled = 0, gap = 0, maxGap = 0;
            for (int i = 0; i < 2 * N; i++)
            {
                if (acc.cnt[i % N] > 0) { if (i < N) filled++; gap = 0; }
                else { gap++; if (gap > maxGap) maxGap = gap; }
            }
            if (filled < N * 0.96 || maxGap > 15)
            {
                Log.W("map " + key + ": not enough track covered yet (" + (filled * 100 / N) + "% from " + acc.files + " session" + (acc.files == 1 ? "" : "s") + ", biggest gap " + (maxGap * 100.0 / N).ToString("0.0", CultureInfo.InvariantCulture) + "% of a lap)");
                ibtFailedSig[key] = all;
                return null;
            }
            double[] lat = new double[N], lon = new double[N];
            for (int i = 0; i < N; i++) if (acc.cnt[i] > 0) { lat[i] = acc.lat[i] / acc.cnt[i]; lon[i] = acc.lon[i] / acc.cnt[i]; }
            FillHoles(lat, lon, acc.cnt);
            string name = YamlValue(yaml, "TrackDisplayName"), cfg = YamlValue(yaml, "TrackConfigName");
            Log.W("built map " + key + " from " + acc.files + " telemetry file" + (acc.files == 1 ? "" : "s") + " (" + (filled * 100 / N) + "% recorded)");
            return ToJson("ibt", "telemetry, " + acc.files + " session" + (acc.files == 1 ? "" : "s"), key,
                          name + (cfg.Length > 0 ? " - " + cfg : ""), lat, lon, acc.pit);
        }

        internal static double Read(byte[] b, VarDef d)
        {
            switch (d.Type)
            {
                case 0: case 1: return b[d.Offset];
                case 2: case 3: return BitConverter.ToInt32(b, d.Offset);
                case 4: return BitConverter.ToSingle(b, d.Offset);
                case 5: return BitConverter.ToDouble(b, d.Offset);
            }
            return 0;
        }

        // Adds one .ibt file's clean samples to the accumulator. Returns its session YAML, or null if unusable.
        static string AddIbt(string path, Acc acc)
        {
            Ibt t = OpenIbt(path, true);
            if (t == null) return null;
            using (t.fs)
            {
                VarDef vLat, vLon, vPct, vPit, vSpd, vSurf, vOn;
                if (!t.vars.TryGetValue("Lat", out vLat) || !t.vars.TryGetValue("Lon", out vLon) || !t.vars.TryGetValue("LapDistPct", out vPct)) return null;
                t.vars.TryGetValue("OnPitRoad", out vPit); t.vars.TryGetValue("Speed", out vSpd);
                t.vars.TryGetValue("PlayerTrackSurface", out vSurf); t.vars.TryGetValue("IsOnTrack", out vOn);

                var pitRun = new List<double[]>(); double pitLen = 0;
                byte[] buf = new byte[t.bufLen];
                t.fs.Position = t.dataOff;
                double prevPct = -1;
                for (long r = 0; r < t.records; r++)
                {
                    if (t.fs.Read(buf, 0, t.bufLen) < t.bufLen) break;
                    double lat = Read(buf, vLat), lon = Read(buf, vLon), pct = Read(buf, vPct);
                    bool pit = vPit != null && Read(buf, vPit) != 0;
                    bool on = vOn == null || Read(buf, vOn) != 0;
                    double spd = vSpd != null ? Read(buf, vSpd) : 10;
                    int surf = vSurf != null ? (int)Read(buf, vSurf) : 3;
                    bool gps = on && (lat != 0 || lon != 0) && pct >= 0 && pct <= 1;

                    // longest single pass through pit lane, for drawing the pit road
                    if (gps && pit && spd > 1)
                    {
                        if (pitRun.Count > 0) { double[] p = pitRun[pitRun.Count - 1]; pitLen += Dist(p[0], p[1], lat, lon); }
                        pitRun.Add(new[] { lat, lon });
                    }
                    else if (pitRun.Count > 0)
                    {
                        if (pitLen > acc.pitLen) { acc.pitLen = pitLen; acc.pit = pitRun; }
                        pitRun = new List<double[]>(); pitLen = 0;
                    }

                    // only racing-surface samples at speed, moving forward smoothly (no resets, tows or pit lane)
                    if (!gps || pit || surf != 3 || spd < 5) { prevPct = -1; continue; }
                    if (prevPct >= 0)
                    {
                        double dp = pct - prevPct;
                        if (dp < -0.5) dp += 1;
                        if (dp < -0.002 || dp > 0.02) { prevPct = pct; continue; }
                    }
                    else { prevPct = pct; continue; }        // need two samples in a row to trust it
                    prevPct = pct;
                    int bin = Math.Min(N - 1, (int)(pct * N));
                    acc.cnt[bin]++; acc.lat[bin] += lat; acc.lon[bin] += lon;
                }
                if (pitLen > acc.pitLen) { acc.pitLen = pitLen; acc.pit = pitRun; }
                return t.yaml;
            }
        }

        static double Dist(double la1, double lo1, double la2, double lo2)
        {
            double kx = 111320 * Math.Cos(la1 * Math.PI / 180), dx = (lo2 - lo1) * kx, dy = (la2 - la1) * 110540;
            return Math.Sqrt(dx * dx + dy * dy);
        }

        static void FillHoles(double[] lat, double[] lon, int[] cnt)
        {
            for (int i = 0; i < N; i++)
            {
                if (cnt[i] > 0) continue;
                int a = i, b = i, da = 0, db = 0;
                while (cnt[a] == 0 && da < N) { a = (a - 1 + N) % N; da++; }
                while (cnt[b] == 0 && db < N) { b = (b + 1) % N; db++; }
                double f = (double)da / (da + db);
                lat[i] = lat[a] + (lat[b] - lat[a]) * f; lon[i] = lon[a] + (lon[b] - lon[a]) * f;
            }
        }

        static string ToJson(string source, string detail, string key, string track, double[] lat, double[] lon, List<double[]> pit)
        {
            double lat0 = 0, lon0 = 0;
            for (int i = 0; i < N; i++) { lat0 += lat[i]; lon0 += lon[i]; }
            lat0 /= N; lon0 /= N;
            double kx = 111320 * Math.Cos(lat0 * Math.PI / 180), ky = 110540;
            CultureInfo ci = CultureInfo.InvariantCulture;
            StringBuilder sb = new StringBuilder(32000);
            sb.Append("{\"v\":2,\"source\":").Append(Json.Str(source)).Append(",\"detail\":").Append(Json.Str(detail))
              .Append(",\"key\":").Append(Json.Str(key)).Append(",\"track\":").Append(Json.Str(track))
              .Append(",\"n\":").Append(N).Append(",\"origin\":[").Append(lat0.ToString("R", ci)).Append(',').Append(lon0.ToString("R", ci))
              .Append("],\"recorded\":\"").Append(DateTime.Now.ToString("s")).Append("\",\"pts\":[");
            for (int i = 0; i < N; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append('[').Append(Math.Round((lon[i] - lon0) * kx, 1).ToString(ci)).Append(',')
                  .Append(Math.Round((lat[i] - lat0) * ky, 1).ToString(ci)).Append(']');
            }
            sb.Append("],\"pit\":[");
            double lx = double.NaN, ly = double.NaN; bool first = true;
            if (pit != null)
                foreach (double[] p in pit)
                {
                    double x = (p[1] - lon0) * kx, y = (p[0] - lat0) * ky;
                    if (!double.IsNaN(lx) && Math.Sqrt((x - lx) * (x - lx) + (y - ly) * (y - ly)) < 4) continue;
                    if (!first) sb.Append(',');
                    first = false; lx = x; ly = y;
                    sb.Append('[').Append(Math.Round(x, 1).ToString(ci)).Append(',').Append(Math.Round(y, 1).ToString(ci)).Append(']');
                }
            sb.Append("]}");
            return sb.ToString();
        }

        // ---- SIMRacingApps library (only files whose outline is keyed by lap percentage) ----
        static string FromLibrary(string key, string trackName) { return FromLibrary(key, trackName, false); }
        static string FromLibrary(string key, string trackName, bool localOnly)
        {
            if (string.IsNullOrEmpty(trackName)) return null;
            if (localOnly)
            {
                string ln = Regex.Replace(trackName.Trim().ToLowerInvariant(), "\\s+", "_");
                if (!Regex.IsMatch(ln, "^[a-z0-9_.-]{1,80}$") || !File.Exists(Path.Combine(Program.RootDir, @"data\corners\library\" + ln + ".json"))) return null;
            }
            else
            {
                // the builder's own 1/5/15/60-minute backoff paces the download; this only stops a hammering loop
                DateTime when;
                if (libTried.TryGetValue(key, out when) && (DateTime.Now - when).TotalMinutes < 1) return null;
                libTried[key] = DateTime.Now;
            }
            string name = Regex.Replace(trackName.Trim().ToLowerInvariant(), "\\s+", "_");
            if (!Regex.IsMatch(name, "^[a-z0-9_.-]{1,80}$")) return null;
            string text;
            string local = Path.Combine(Program.RootDir, @"data\corners\library\" + name + ".json");      // offline copy (docs\corners.md): read first, no internet needed
            try
            {
                if (File.Exists(local)) text = File.ReadAllText(local, Encoding.UTF8);
                else
                {
                    ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;    // TLS 1.2
                    using (WebClient wc = new WebClient())
                    {
                        wc.Encoding = Encoding.UTF8;
                        text = wc.DownloadString("https://raw.githubusercontent.com/SIMRacingApps/SIMRacingAppsServer/master/src/com/SIMRacingApps/Tracks/" + name + ".json");
                    }
                }
            }
            catch (Exception ex) { Log.W("library map " + name + ": " + ex.Message); return null; }

            List<double[]> on = PctSection(text, "ONTRACK");
            if (on.Count < 150) { Log.W("library map " + name + ": no lap-keyed outline"); return null; }
            on.Sort(delegate (double[] a, double[] b) { return a[0].CompareTo(b[0]); });
            double[] lat = new double[N], lon = new double[N];
            int j = 0;
            for (int i = 0; i < N; i++)
            {
                double pct = 100.0 * i / N;
                while (j + 1 < on.Count && on[j + 1][0] <= pct) j++;
                double[] a = on[j], b = on[(j + 1) % on.Count];
                double span = b[0] - a[0]; if (span <= 0) span += 100;
                double f = span > 0 ? (pct - a[0] + (pct < a[0] ? 100 : 0)) / span : 0;
                f = Math.Max(0, Math.Min(1, f));
                lat[i] = a[1] + (b[1] - a[1]) * f; lon[i] = a[2] + (b[2] - a[2]) * f;
            }
            List<double[]> pitPts = new List<double[]>();
            List<double[]> pit = PctSection(text, "ONPITROAD");
            pit.Sort(delegate (double[] a, double[] b) { return a[0].CompareTo(b[0]); });
            foreach (double[] p in pit) pitPts.Add(new[] { p[1], p[2] });
            Match tn = Regex.Match(text, "\"Copyright\"\\s*:\\s*\"([^\"]*)\"");
            Log.W("library map " + name + (File.Exists(local) ? " read from the local copy (" : " downloaded (") + on.Count + " points)");
            return ToJson("library", "SIMRacingApps track data, Apache License 2.0" + (tn.Success ? ", " + tn.Groups[1].Value : ""),
                          key, trackName, lat, lon, pitPts);
        }

        static List<double[]> PctSection(string text, string section)
        {
            var list = new List<double[]>();
            int s = text.IndexOf("\"" + section + "\"", StringComparison.Ordinal);
            if (s < 0) return list;
            int open = text.IndexOf('{', s);
            if (open < 0) return list;
            int depth = 0, end = open;
            for (; end < text.Length; end++) { if (text[end] == '{') depth++; else if (text[end] == '}' && --depth == 0) break; }
            string body = text.Substring(open, end - open);
            foreach (Match m in Regex.Matches(body, "\"(-?\\d+(?:\\.\\d+)?)\"\\s*:\\s*\\{\\s*\"Latitude\"\\s*:\\s*(-?[\\d.]+)\\s*,\\s*\"Longitude\"\\s*:\\s*(-?[\\d.]+)"))
            {
                double p, la, lo;
                if (double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out p) &&
                    double.TryParse(m.Groups[2].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out la) &&
                    double.TryParse(m.Groups[3].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out lo) &&
                    p >= 0 && p < 100 && (la != 0 || lo != 0))
                    list.Add(new[] { p, la, lo });
            }
            return list;
        }

        // Builds maps for every track found in the telemetry folder (used at startup and by --build-maps).
        public static void BuildAll()
        {
            lock (gate)
            {
                foreach (string key in IbtTracks())
                {
                    string file = Path.Combine(MapsDir, key + ".json");
                    if (File.Exists(file) && File.ReadAllText(file).Contains("\"source\":\"ibt\"")) continue;
                    string json = FromIbt(key);
                    if (json != null) Save(file, json);
                }
            }
        }
    }

    // ---------------- Watchdog and health ----------------
    // Restarts Stream Deck if it disappears, and clears a sim that froze while loading (or an anti-cheat launcher
    // stuck on an error), then restarts the iRacing UI. Never touches a sim that is connected to a session.
    static class Watch
    {
        static readonly object gate = new object();
        static readonly List<KeyValuePair<DateTime, string>> events = new List<KeyValuePair<DateTime, string>>();
        static DateTime deckMissingSince = DateTime.MinValue, lastDeckStart = DateTime.MinValue;
        static DateTime launcherAloneSince = DateTime.MinValue, lastRecovery = DateTime.MinValue;
        static int simPid = -1;
        static readonly List<KeyValuePair<DateTime, double>> cpu = new List<KeyValuePair<DateTime, double>>();
        static readonly List<DateTime> recoveries = new List<DateTime>();
        public static string SimState = "off";
        public static string IrdeckPath;

        static bool Running(string name) { return Process.GetProcessesByName(name).Length > 0; }

        public static void Note(string msg)
        {
            Log.W("watchdog: " + msg);
            lock (gate) { events.Add(new KeyValuePair<DateTime, string>(DateTime.Now, msg)); if (events.Count > 20) events.RemoveAt(0); }
        }

        public static void Tick(bool sdConnected)
        {
            DateTime now = DateTime.Now;

            // Stream Deck: restart it if it has been gone for 10 s (at most once a minute)
            // ...except while build-deck / tools\deck-refresh.ps1 rewrite the profile (dash\deck-build.lock, fresh for 5 min): a restart
            // in the middle read a half-written MAIN page ("import_profile ERROR ... failbit"), and Stream Deck then deleted MAIN
            // (2026-10-23 13:39, 13:40, 15:16 - the "deck sometimes loses MAIN" bug).
            string deckBuild = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "deck-build.lock");
            if (Running("StreamDeck")) deckMissingSince = DateTime.MinValue;
            else if (File.Exists(deckBuild) && (now - File.GetLastWriteTime(deckBuild)).TotalMinutes < 5) deckMissingSince = now;
            else
            {
                if (deckMissingSince == DateTime.MinValue) deckMissingSince = now;
                string exe = @"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe";
                if ((now - deckMissingSince).TotalSeconds > 10 && (now - lastDeckStart).TotalSeconds > 60 && File.Exists(exe))
                {
                    lastDeckStart = now;
                    try { Process.Start(new ProcessStartInfo(exe, "--runinbk") { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(exe) }); Note("Stream Deck was not running: restarted it"); }
                    catch (Exception ex) { Log.W("watchdog: Stream Deck start failed: " + ex.Message); }
                }
            }

            // Stream Deck app lost the device (USB blip) but Windows can see it again: restart the app (2026-10-09)
            try { CheckDeckDevice(now); } catch (Exception ex) { Log.W("watchdog: deck device check: " + ex.Message); }

            // Sim health
            Process[] sims = Process.GetProcessesByName("iRacingSim64DX11");
            bool launcher = Running("start_protected_game");
            if (sdConnected) { SimState = "live"; simPid = -1; cpu.Clear(); launcherAloneSince = DateTime.MinValue; return; }
            if (sims.Length == 0)
            {
                simPid = -1; cpu.Clear();
                if (launcher)
                {
                    // the anti-cheat launcher stays open with no sim only when it is showing a launch error
                    if (launcherAloneSince == DateTime.MinValue) launcherAloneSince = now;
                    SimState = "starting";
                    if ((now - launcherAloneSince).TotalSeconds > 60) Recover("the anti-cheat launcher was stuck on a launch error");
                }
                else { launcherAloneSince = DateTime.MinValue; SimState = "off"; }
                return;
            }
            launcherAloneSince = DateTime.MinValue;
            Process p = sims[0];
            try
            {
                if (p.Id != simPid) { simPid = p.Id; cpu.Clear(); }
                p.Refresh();
                double c = p.TotalProcessorTime.TotalSeconds;
                cpu.Add(new KeyValuePair<DateTime, double>(now, c));
                while (cpu.Count > 0 && (now - cpu[0].Key).TotalSeconds > 75) cpu.RemoveAt(0);
                double age = (now - p.StartTime).TotalSeconds;
                bool window = p.MainWindowHandle != IntPtr.Zero;
                double span = (now - cpu[0].Key).TotalSeconds, grew = c - cpu[0].Value;
                SimState = "loading";
                // frozen: two minutes old, never showed a window, and almost no CPU use over the last minute
                if (age > 120 && !window && span >= 60 && grew < 3)
                {
                    SimState = "stuck";
                    Recover("the sim froze while loading (no window, " + grew.ToString("0.0", CultureInfo.InvariantCulture) + " s of CPU in a minute)");
                }
            }
            catch (Exception ex) { Log.W("watchdog: sim check: " + ex.Message); }
        }

        static DateTime lastDeckCheck = DateTime.MinValue, deckLostSince = DateTime.MinValue, lastDeckRestart = DateTime.MinValue;

        static void CheckDeckDevice(DateTime now)
        {
            if ((now - lastDeckCheck).TotalSeconds < 10 || !Running("StreamDeck")) return;
            lastDeckCheck = now;
            string logFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Elgato\StreamDeck\logs\StreamDeck.log");
            if (!File.Exists(logFile)) return;
            string tail;
            using (FileStream fs = new FileStream(logFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                long start = Math.Max(0, fs.Length - 200000); fs.Position = start;
                byte[] b = new byte[fs.Length - start]; int n = fs.Read(b, 0, b.Length);
                tail = Encoding.UTF8.GetString(b, 0, n);
            }
            int conn = tail.LastIndexOf("Device connected, id:"), disc = tail.LastIndexOf("Device disconnected, id:");
            if (disc < 0 || disc < conn) { deckLostSince = DateTime.MinValue; return; }      // last event was a connect
            if (deckLostSince == DateTime.MinValue) { deckLostSince = now; return; }
            if ((now - deckLostSince).TotalSeconds < 15 || (now - lastDeckRestart).TotalMinutes < 2) return;
            // is the Stream Deck (USB VID 0FD9) actually plugged in?
            bool present = false;
            using (var q = new System.Management.ManagementObjectSearcher("SELECT DeviceID FROM Win32_PnPEntity WHERE DeviceID LIKE 'USB\\\\VID_0FD9%'"))
                foreach (var o in q.Get()) { present = true; break; }
            if (!present) return;
            lastDeckRestart = now; deckLostSince = DateTime.MinValue;
            foreach (Process p in Process.GetProcessesByName("StreamDeck")) { try { p.Kill(); } catch { } }
            Thread.Sleep(2000);
            string exe = @"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe";
            Process.Start(new ProcessStartInfo(exe, "--runinbk") { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(exe) });
            Note("Stream Deck lost its USB connection: restarted the Stream Deck app");
        }

        static void Recover(string why)
        {
            DateTime now = DateTime.Now;
            recoveries.RemoveAll(delegate (DateTime when) { return (now - when).TotalMinutes > 60; });
            if ((now - lastRecovery).TotalMinutes < 3 || recoveries.Count >= 3) return;   // never loop
            lastRecovery = now; recoveries.Add(now);
            Note("cleared a stuck launch: " + why + ". Restarting the iRacing UI: start the session again.");
            foreach (string n in new[] { "start_protected_game", "iRacingSim64DX11" })
                foreach (Process x in Process.GetProcessesByName(n)) { try { x.Kill(); } catch (Exception ex) { Log.W("watchdog: could not end " + n + ": " + ex.Message); } }
            try { System.Media.SystemSounds.Exclamation.Play(); } catch { }
            // the UI keeps believing the old sim is running until it restarts
            Thread t = new Thread(delegate ()
            {
                try
                {
                    try { RigWin.CloseIracingUi(); } catch { }   // a polite close on the real "iRacing" window (the process's "main window" guess can be a tiny strip: rigwin.cs)
                    for (int i = 0; i < 20 && Running("iRacingUI"); i++) Thread.Sleep(1000);
                    foreach (Process u in Process.GetProcessesByName("iRacingUI")) { try { u.Kill(); } catch { } }
                    Thread.Sleep(2000);
                    if (IrdeckPath != null && File.Exists(IrdeckPath))
                        Process.Start(new ProcessStartInfo(IrdeckPath, "rigon") { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(IrdeckPath) });
                }
                catch (Exception ex) { Log.W("watchdog: UI restart: " + ex.Message); }
            });
            t.IsBackground = true;
            t.Start();
        }

        // Health for the dashboard's status strip.
        public static string Json(bool sdConnected)
        {
            StringBuilder sb = new StringBuilder("{\"apps\":[");
            Action<string, string, string> app = delegate (string id, string name, string state)
            {
                if (sb[sb.Length - 1] == '}') sb.Append(',');
                sb.Append("{\"id\":").Append(Json_.S(id)).Append(",\"name\":").Append(Json_.S(name)).Append(",\"state\":").Append(Json_.S(state)).Append('}');
            };
            app("deck", "Stream Deck", Running("StreamDeck") ? "ok" : "down");
            app("ui", "iRacing UI", Running("iRacingUI") ? "ok" : "off");
            app("sim", "Sim", sdConnected ? "live" : SimState);
            if (File.Exists(@"C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4\CrewChiefV4.exe") || Running("CrewChiefV4")) app("cc", "CrewChief", Running("CrewChiefV4") ? "ok" : "off");
            // always listed when installed, so overlays that failed to start show up as "off"
            if (Running("irdashies") || Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "irdashies")))
                app("overlays", "Overlays", Running("irdashies") ? "ok" : "off");
            sb.Append("],\"events\":[");
            lock (gate)
            {
                for (int i = 0; i < events.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append("{\"t\":").Append(Json_.S(events[i].Key.ToString("s"))).Append(",\"msg\":").Append(Json_.S(events[i].Value)).Append('}');
                }
            }
            sb.Append("]}");
            return sb.ToString();
        }
    }

    static class Json_ { public static string S(string s) { return Json.Str(s ?? ""); } }

    // Live TV view on the top screen (C-22). The deck key calls /api/do?c=tvview once. The choice is
    // remembered as tv_view=1. This only tells the dashboard page to draw; it never touches iRacing, and it
    // is allowed while Peter is driving.
    static class TvView
    {
        public static bool On;
        public static bool Handles(string c) { return c == "tvview"; }
        public static bool Do(string c, string a)
        {
            On = !On;
            Config.SetKey(Program.IniFile, "tv_view", On ? "1" : "0");
            Log.W("tv view: " + (On ? "on" : "off"));
            return true;
        }
    }

    // ---------------- Settings (dash\irdash.ini, key=value) ----------------
    sealed class Config
    {
        public int Port = 8199;
        public string Screen = "auto";   // "auto" = the highest monitor, or a device name like \\.\DISPLAY4
        public string Browser = "auto";  // "auto" = Chrome, else Edge; or a full path to a Chromium browser
        public bool Kiosk = true;
        public bool OpenOnStart = true;
        public bool KeepDash = true;      // put the dashboard back on its monitor (and reopen it) if it moves or closes
        public bool PlaceSim = true;      // stretch the iRacing sim window across the race monitors
        public string SimRect = "auto";   // "auto" = every monitor except the dashboard one, or "x,y,width,height"
        public bool LogAllCars = true;    // keep iRacing's irsdkLogAllCars=1 so big fields are not cut at 64 cars
        public bool HideTaskbar = true;   // keep the dashboard and sim windows above the taskbar on their monitors
        public bool SyncSimIni = false;   // write iRacing's rendererDX11Monitor.ini window position (off: never touch iRacing files)
        public bool Watchdog = true;      // restart Stream Deck if it vanishes; clear a sim that froze while loading
        public string Page = "";          // dashboard page under www: "" = version 1, "v2/" = version 2
        public bool DeltaOn = true;       // native delta bar on the middle race screen (deltabar.cs)
        public string DeltaRef = "best";  // best | optimal | session
        public string DeltaPos = "auto";  // "auto" (centred) or "x,y" / "center,y": top-left on the middle screen
        public double DeltaScale = 1.0;
        public string SimPriority = "high"; // high | normal: raise the sim to High priority when a session starts (data.cs)
        public bool TvOn;                    // live TV view (tv_view=1). Missing line means off.

        // Change one key in the ini (the Stream Deck changes the delta bar settings live); other lines stay as they are.
        public static void SetKey(string file, string key, string value)
        {
            try
            {
                string[] lines = File.Exists(file) ? File.ReadAllLines(file) : new string[0];
                List<string> o = new List<string>(lines);
                bool done = false;
                for (int i = 0; i < o.Count; i++)
                {
                    string t = o[i].TrimStart();
                    if (t.StartsWith(key + "=", StringComparison.OrdinalIgnoreCase)) { o[i] = key + "=" + value; done = true; break; }
                }
                if (!done) o.Add(key + "=" + value);
                File.WriteAllLines(file, o.ToArray());
            }
            catch (Exception ex) { Log.W("ini: could not save " + key + ": " + ex.Message); }
        }

        public static Config Load(string file)
        {
            Config c = new Config();
            if (!File.Exists(file))
            {
                try
                {
                    File.WriteAllText(file,
                        "; irdash settings. Restart irdash after changing.\r\n" +
                        "port=8199\r\n" +
                        "; auto = the highest monitor (your top screen). Or e.g. \\\\.\\DISPLAY4\r\n" +
                        "screen=auto\r\n" +
                        "; auto = Chrome if installed, else Edge. Or a full path to chrome.exe / msedge.exe\r\n" +
                        "browser=auto\r\n" +
                        "; 1 = borderless full screen (exit with Alt+F4), 0 = normal window\r\n" +
                        "kiosk=1\r\n" +
                        "; open the dashboard window when irdash starts\r\n" +
                        "open_on_start=1\r\n" +
                        "; 1 = keep the dashboard on its monitor and reopen it if closed (never while you are on track)\r\n" +
                        "keep_dash=1\r\n" +
                        "; 1 = stretch the iRacing sim window across the race monitors\r\n" +
                        "place_sim=1\r\n" +
                        "; auto = every monitor except the dashboard one. Or x,y,width,height\r\n" +
                        "sim_rect=auto\r\n");
                }
                catch { }
                return c;
            }
            foreach (string raw in File.ReadAllLines(file))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith(";") || line.StartsWith("#")) continue;
                int e = line.IndexOf('=');
                if (e < 0) continue;
                string k = line.Substring(0, e).Trim().ToLowerInvariant(), v = line.Substring(e + 1).Trim();
                int n;
                switch (k)
                {
                    case "port": if (int.TryParse(v, out n) && n > 1024 && n < 65536) c.Port = n; break;
                    case "screen": c.Screen = v; break;
                    case "browser": c.Browser = v; break;
                    case "kiosk": c.Kiosk = v != "0"; break;
                    case "open_on_start": c.OpenOnStart = v != "0"; break;
                    case "keep_dash": c.KeepDash = v != "0"; break;
                    case "place_sim": c.PlaceSim = v != "0"; break;
                    case "sim_rect": c.SimRect = v; break;
                    case "log_all_cars": c.LogAllCars = v != "0"; break;
                    case "hide_taskbar": c.HideTaskbar = v != "0"; break;
                    case "sync_sim_ini": c.SyncSimIni = v == "1"; break;
                    case "watchdog": c.Watchdog = v != "0"; break;
                    case "page": c.Page = Regex.IsMatch(v, "^[A-Za-z0-9_-]*/?$") ? v : ""; break;
                    case "delta_bar": c.DeltaOn = v != "0"; break;
                    case "delta_ref": c.DeltaRef = v.ToLowerInvariant(); break;
                    case "delta_pos": c.DeltaPos = v; break;
                    case "delta_scale": double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out c.DeltaScale); break;
                    case "sim_priority": c.SimPriority = v.ToLowerInvariant() == "normal" ? "normal" : "high"; break;
                    case "tv_view": c.TvOn = v == "1"; break;
                    case "career_hours": double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out Career.BaseHours); break;
                    case "career_laps": int.TryParse(v, out Career.BaseLaps); break;
                    case "career_km": double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out Career.BaseKm); break;
                    case "career_races": int.TryParse(v, out Career.BaseRaces); break;
                }
            }
            return c;
        }
    }

    // ---------------- Tray app + dashboard window launcher ----------------
    // ---------------- Career stats for the startup intro ----------------
    // Seat time, laps and distance from your .ibt telemetry files. Each file is read once (about one record a
    // second, low thread priority) and remembered in career-cache.tsv, so later scans only read new files.
    // Scans run a couple of minutes after start and never while you are driving.
    // Cache format 2 (2026-10-09) also keeps each file's best lap, typical fuel per lap, track layout and start time
    // (sessions page, pre-session brief, weekly progress). Rows written by format 1 are read again once, in the
    // background, by the same low-priority scan; the query side of this class is in data.cs.
    static partial class Career
    {
        public static string TelemetryDir, CacheFile;
        // totals from before telemetry was logged (irdash.ini career_*), added on top of what the files show
        public static double BaseHours, BaseKm; public static int BaseLaps, BaseRaces;
        sealed class Rec
        {
            public string Sig, Car = "", Track = "", Ev = "", Name = "", Num = "", Lic = "", Config = "", TrackId = "", SType = "";
            public DateTime When, Start; public double Secs, Meters, Best, Fuel; public int Laps, IR, Ver, FuelLaps;
            public int Rules;      // L-1: LapRules.Version the best lap was worked out under (column 21; a row without it is from before the rule and is read again if it has a best lap)
            public int Left = -1;  // PL-1: 2 = the car left pit road (3 s or more off it, in the world), 0 = it never did, -1 = not read yet (column 22; a row without it, or with the first draft's 1, and no laps in it is read again)
            // when the session began (format 1 rows only know when the file was last written)
            public DateTime Date { get { return Start != DateTime.MinValue ? Start : When; } }
            // PL-1: a session that is not an outing: under 30 s in the car, or no lap and never off pit road (a Test Drive that sat in the box), or one a test started.
            // It does not count as seat time, laps, the last outing, the car on HOME or the newest session anywhere.
            public bool Short { get { return Secs < 30 || (Laps == 0 && Left == 0) || TestRuns.Covers(Date); } }
            public string FileName { get { int k = Sig.LastIndexOf('|'); return k > 0 ? Sig.Substring(0, k) : Sig; } }
        }
        static readonly object gate = new object();
        static readonly Dictionary<string, Rec> recs = new Dictionary<string, Rec>();
        static bool loaded, scanning; static int lastCount = -1, pendingUpgrade; static DateTime lastScanEnd = DateTime.MinValue;

        public static void ScanLater(int delayMs)
        {
            lock (gate) { if (scanning) return; scanning = true; }
            Thread t = new Thread(delegate ()
            {
                try
                {
                    Thread.Sleep(delayMs);
                    while (Program.IsDriving) Thread.Sleep(30000);
                    Scan();
                }
                catch (Exception ex) { Log.W("career: " + ex.Message); }
                finally { lock (gate) scanning = false; }
            });
            t.IsBackground = true; t.Priority = ThreadPriority.Lowest; t.Start();
        }

        static void Load()
        {
            if (loaded) return; loaded = true;
            if (CacheFile == null || !File.Exists(CacheFile)) return;
            CultureInfo inv = CultureInfo.InvariantCulture;
            foreach (string line in File.ReadAllLines(CacheFile, Encoding.UTF8))
            {
                try
                {
                    string[] f = line.Split('\t');
                    if (f.Length < 13) continue;
                    Rec r = new Rec();
                    r.Sig = f[0]; r.When = new DateTime(long.Parse(f[1]), DateTimeKind.Utc);
                    r.Secs = double.Parse(f[2], inv); r.Meters = double.Parse(f[3], inv);
                    r.Laps = int.Parse(f[4]); r.IR = int.Parse(f[5]); r.Car = f[6]; r.Track = f[7]; r.Ev = f[8]; r.Name = f[9]; r.Num = f[10]; r.Lic = f[11];
                    // format 2: version, best lap, fuel per lap, laps behind that, layout, track id, start (UTC ticks), session type
                    if (f.Length >= 20 && f[12] == "2")
                    {
                        r.Ver = 2;
                        double.TryParse(f[13], NumberStyles.Float, inv, out r.Best); double.TryParse(f[14], NumberStyles.Float, inv, out r.Fuel);
                        int.TryParse(f[15], out r.FuelLaps); r.Config = f[16]; r.TrackId = f[17];
                        long st; if (long.TryParse(f[18], out st) && st > 0) r.Start = new DateTime(st, DateTimeKind.Utc);
                        r.SType = f[19];
                        if (f.Length >= 21) int.TryParse(f[20], out r.Rules);
                        if (f.Length >= 22 && !int.TryParse(f[21], out r.Left)) r.Left = -1;
                        if (r.Left == 1) r.Left = -1;       // the first draft (2026-10-11) wrote 1 after one frame off pit road at the very start of a session: read again
                        // a row made under an older lap rule is read again (the rule can give a best lap as well as take one away), except one that never had a lap in it
                        if (r.Rules < LapRules.Version && r.Best <= 0 && r.Laps == 0) r.Rules = LapRules.Version;
                    }
                    recs[r.Sig] = r;
                }
                catch (Exception ex) { Log.W("career cache: skipped a bad line (" + ex.Message + ")"); }
            }
        }

        static void Save()
        {
            CultureInfo inv = CultureInfo.InvariantCulture;
            StringBuilder sb = new StringBuilder();
            foreach (Rec r in recs.Values)
            {
                string[] f = { r.Sig, r.When.Ticks.ToString(), r.Secs.ToString("0.#", inv), r.Meters.ToString("0", inv),
                               r.Laps.ToString(), r.IR.ToString(), r.Car, r.Track, r.Ev, r.Name, r.Num, r.Lic,
                               r.Ver >= 2 ? "2" : "", r.Ver >= 2 ? r.Best.ToString("0.000", inv) : "", r.Ver >= 2 ? r.Fuel.ToString("0.000", inv) : "", r.Ver >= 2 ? r.FuelLaps.ToString() : "",
                               r.Config, r.TrackId, r.Start == DateTime.MinValue ? "" : r.Start.Ticks.ToString(), r.SType, r.Ver >= 2 ? r.Rules.ToString() : "", r.Ver >= 2 ? r.Left.ToString() : "" };
                for (int i = 0; i < f.Length; i++) f[i] = (f[i] ?? "").Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');
                sb.Append(string.Join("\t", f)).Append("\r\n");
            }
            File.WriteAllText(CacheFile + ".tmp", sb.ToString(), new UTF8Encoding(false));
            if (File.Exists(CacheFile)) File.Delete(CacheFile);
            File.Move(CacheFile + ".tmp", CacheFile);
        }

        // OneDrive "online-only" files: opening one starts a download, so the background scan leaves them alone
        // (tools\keep-iracing-local.cmd keeps them on this PC).
        internal static bool OnlineOnly(FileInfo fi) { return ((int)fi.Attributes & (0x400000 | 0x40000)) != 0; }

        static void Scan()
        {
            if (TelemetryDir == null || !Directory.Exists(TelemetryDir)) return;
            string[] files = Directory.GetFiles(TelemetryDir, "*.ibt");
            int added = 0, upgraded = 0, left = 0;
            lock (gate) Load();
            foreach (string path in files)
            {
                if (Program.IsDriving) { left++; break; }   // pick it up next time
                FileInfo fi = new FileInfo(path);
                if ((DateTime.Now - fi.LastWriteTime).TotalSeconds < 30) continue;   // still being written
                string sig = fi.Name + "|" + fi.Length;
                Rec old; bool have;
                lock (gate) have = recs.TryGetValue(sig, out old);
                // PL-1: a row with no laps in it is read once more for whether the car ever left pit road (rows with laps are outings already)
                if (have && old.Ver >= 2 && old.Rules >= LapRules.Version && !(old.Left < 0 && old.Laps == 0 && old.Secs >= 30)) continue;
                if (OnlineOnly(fi)) { left++; continue; }
                Rec r = null;
                try { r = Read(path, fi); } catch (Exception ex) { Log.W("career " + fi.Name + ": " + ex.Message); }
                if (r == null)
                {
                    if (have) { lock (gate) { old.Ver = 2; old.Rules = LapRules.Version; if (old.Left < 0) old.Left = 2; } upgraded++; continue; }      // unreadable: keep what the old row said (and count it)
                    r = new Rec(); r.When = fi.LastWriteTimeUtc;
                }
                r.Sig = sig; r.Ver = 2; r.Rules = LapRules.Version;
                lock (gate) recs[sig] = r;
                if (have) upgraded++; else added++;
                Thread.Sleep(have ? 60 : 20);
            }
            lock (gate)
            {
                lastCount = left == 0 ? files.Length : -1; pendingUpgrade = left; lastScanEnd = DateTime.Now;
                if (added + upgraded > 0) Save();
            }
            if (added > 0) Log.W("career: read " + added + " new telemetry file" + (added == 1 ? "" : "s"));
            if (upgraded > 0) Log.W("career: read " + upgraded + " older telemetry file" + (upgraded == 1 ? "" : "s") + " again for best laps and fuel use");
        }

        static double Median(List<double> v)
        {
            if (v.Count == 0) return 0;
            List<double> s = new List<double>(v); s.Sort();
            return s.Count % 2 == 1 ? s[s.Count / 2] : (s[s.Count / 2 - 1] + s[s.Count / 2]) / 2;
        }

        static VarDef Var(TrackMaps.Ibt t, string name) { VarDef d; return t.vars.TryGetValue(name, out d) ? d : null; }

        // About one record a second: seat time, distance and laps; plus each lap's official time (LapLastLapTime
        // changes when a lap is completed) for the best lap, and fuel burnt on clean full laps for a typical use per lap.
        static Rec Read(string path, FileInfo fi)
        {
            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
            if (t == null) return null;
            using (t.fs)
            {
                Rec r = new Rec(); r.When = fi.LastWriteTimeUtc; r.Ver = 2;
                r.Track = TrackMaps.YamlValue(t.yaml, "TrackDisplayName");
                r.Config = TrackMaps.YamlValue(t.yaml, "TrackConfigName");
                r.TrackId = TrackMaps.YamlValue(t.yaml, "TrackID");
                r.Ev = TrackMaps.YamlValue(t.yaml, "EventType");
                r.SType = Career.SessionTypeOf(t.yaml, -1);
                // your own entry in the driver list
                string me = TrackMaps.YamlValue(t.yaml, "DriverCarIdx");
                Match block = Regex.Match(t.yaml, "- CarIdx: " + Regex.Escape(me) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
                if (me.Length > 0 && block.Success)
                {
                    string b = block.Groups[1].Value;
                    r.Car = TrackMaps.YamlValue(b, "CarScreenName"); r.Name = TrackMaps.YamlValue(b, "UserName");
                    r.Num = TrackMaps.YamlValue(b, "CarNumber"); r.Lic = TrackMaps.YamlValue(b, "LicString");
                    int ir; if (int.TryParse(TrackMaps.YamlValue(b, "IRating"), out ir)) r.IR = ir;
                }
                byte[] h = new byte[144]; t.fs.Position = 0; t.fs.Read(h, 0, 144);
                int tick = BitConverter.ToInt32(h, 8); if (tick <= 0) tick = 60;
                long startUnix = BitConverter.ToInt64(h, 112);                       // when the session recording began
                if (startUnix > 1000000000L && startUnix < 4000000000L) r.Start = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(startUnix);
                VarDef onT = Var(t, "IsOnTrack"), spd = Var(t, "Speed"), lap = Var(t, "Lap");
                if (onT == null || spd == null || lap == null) return r;
                VarDef vLast = Var(t, "LapLastLapTime"), vBest = Var(t, "LapBestLapTime"), vPct = Var(t, "LapDistPct"),
                       vFuel = Var(t, "FuelLevel"), vPit = Var(t, "OnPitRoad"), vSt = Var(t, "SessionTime");
                byte[] buf = new byte[t.bufLen];
                int lastLap = -1;
                double prevSt = 0, prevFuel = 0, prevPct = 0, bT = 0, bFuel = 0, prevLlt = -999, sessionBest = 0;
                bool haveB = false, dirty = false, havePrev = false;
                r.Left = 0;                                       // PL-1: set to 2 once the car has been in the world and off pit road for 3 samples (3 s) in a row
                int offPit = 0; VarDef vSurf = Var(t, "PlayerTrackSurface");   // -1 = not in the world yet: the first frame of a Test Drive says "on track, off pit road, surface -1" for a moment
                List<double> cands = new List<double>();          // lap times iRacing announced during this file
                List<double[]> flaps = new List<double[]>();      // clean full laps: {time, fuel burnt}
                for (long i = 0; i < t.records; i += tick)   // one record per second
                {
                    t.fs.Position = t.dataOff + i * t.bufLen;
                    if (t.fs.Read(buf, 0, t.bufLen) < t.bufLen) break;
                    if (TrackMaps.Read(buf, onT) == 0) { lastLap = -1; havePrev = false; haveB = false; continue; }
                    r.Secs += 1; r.Meters += Math.Max(0, TrackMaps.Read(buf, spd));
                    int l = (int)TrackMaps.Read(buf, lap);
                    bool pit = vPit != null && TrackMaps.Read(buf, vPit) != 0;
                    if (!pit && (vSurf == null || TrackMaps.Read(buf, vSurf) >= 0)) { if (++offPit >= 3) r.Left = 2; } else offPit = 0;   // no pit-road channel counts as "left" (never hide a session on a guess)
                    double st = vSt != null ? TrackMaps.Read(buf, vSt) : 0;
                    double fuel = vFuel != null ? TrackMaps.Read(buf, vFuel) : -1, pct = vPct != null ? TrackMaps.Read(buf, vPct) : -1;
                    if (vLast != null)
                    {
                        // a new value means a lap was just completed; the first one is left over from before the file began
                        double llt = TrackMaps.Read(buf, vLast);
                        if (prevLlt > -900 && llt > 1 && Math.Abs(llt - prevLlt) > 0.0005) cands.Add(llt);
                        prevLlt = llt;
                    }
                    if (vBest != null) { double bl = TrackMaps.Read(buf, vBest); if (bl > 1) sessionBest = bl; }
                    if (pit || (havePrev && fuel > prevFuel + 0.05)) dirty = true;      // pit lane or a refuel spoils the lap's fuel figure
                    if (lastLap >= 0 && l == lastLap + 1)
                    {
                        r.Laps++;
                        if (havePrev && fuel >= 0 && pct >= 0 && st - prevSt > 0 && st - prevSt < 3 && prevPct > 0.5 && pct < 0.5)
                        {
                            double span = (1 - prevPct) + pct, frac = span > 1e-6 ? (1 - prevPct) / span : 1;
                            double tx = prevSt + (st - prevSt) * frac, fx = prevFuel + (fuel - prevFuel) * frac;   // fuel at the line itself
                            if (haveB && !dirty && bFuel - fx > 0.01) flaps.Add(new[] { tx - bT, bFuel - fx });
                            bT = tx; bFuel = fx; haveB = true; dirty = pit;
                        }
                        else haveB = false;
                    }
                    else if (lastLap >= 0 && l != lastLap) haveB = false;              // a jump (reset, tow)
                    lastLap = l; prevSt = st; prevFuel = fuel; prevPct = pct; havePrev = true;
                }
                // best lap: the quickest time iRacing announced, ignoring anything it did not count (faster than the
                // session's own best lap) and anything far too short to be a real lap
                double best = 0;
                if (cands.Count > 0)
                {
                    List<double> s = new List<double>(cands); s.Sort();
                    double med = Median(s);
                    foreach (double c in s)
                    {
                        if (c < 15 || c < med * 0.7 || (sessionBest > 0 && c < sessionBest - 0.002)) continue;
                        best = c; break;
                    }
                }
                if (flaps.Count > 0)
                {
                    double fastest = double.MaxValue;
                    foreach (double[] x in flaps) if (x[0] < fastest) fastest = x[0];
                    if (best <= 0 && fastest > 15) best = fastest;
                    List<double> fuels = new List<double>();
                    foreach (double[] x in flaps) if (x[0] <= fastest * 1.07) fuels.Add(x[1]);
                    if (fuels.Count >= 2) { r.Fuel = Median(fuels); r.FuelLaps = fuels.Count; }
                }
                // L-1: the file's best is the quickest lap iRacing COUNTED (LapRules, analysis.cs), not the quickest time it announced: a lap with an off-track
                // gets a time too, but is left out of iRacing's own best. -1 = the file could not be read as laps: the estimate above stays.
                if (cands.Count > 0 || flaps.Count > 0) { double cb = Analysis.CountedBest(path); if (cb >= 0) best = cb; }
                r.Best = best;
                return r;
            }
        }

        public static string Json()
        {
            lock (gate)
            {
                Load();
                bool changed = TelemetryDir != null && Directory.Exists(TelemetryDir) && Directory.GetFiles(TelemetryDir, "*.ibt").Length != lastCount;
                // files left over for later (driving, online-only) are retried every few minutes, not on every request
                if (changed && !Program.IsDriving && (lastCount >= 0 || (DateTime.Now - lastScanEnd).TotalMinutes > 3)) ScanLater(0);
                double secs = 0, m = 0; int laps = 0, sessions = 0, races = 0; DateTime first = DateTime.MaxValue, todayStart = DateTime.Today.ToUniversalTime();
                double today = 0;
                var byCar = new Dictionary<string, double>(); var byTrack = new Dictionary<string, double>();
                Rec newest = null, lastRun = null;
                foreach (Rec r in recs.Values)
                {
                    if (r.Short) continue;      // PL-1: a test or a Test Drive that sat in the pit box is not an outing
                    if (lastRun == null || r.When > lastRun.When) lastRun = r;
                    secs += r.Secs; m += r.Meters; laps += r.Laps; sessions++;
                    if (r.Ev == "Race") races++;
                    if (r.When < first) first = r.When;
                    if (r.When >= todayStart) today += r.Secs;
                    if (r.Car.Length > 0) { double v; byCar.TryGetValue(r.Car, out v); byCar[r.Car] = v + r.Secs; }
                    if (r.Track.Length > 0) { double v; byTrack.TryGetValue(r.Track, out v); byTrack[r.Track] = v + r.Secs; }
                    // AI sessions list you as a rookie with iRating 1, so only real sessions count for licence and iRating
                    if (r.Lic.Length > 0 && r.IR > 1 && (newest == null || r.When > newest.When)) newest = r;
                }
                Func<Dictionary<string, double>, string> top = delegate (Dictionary<string, double> d)
                { string best = ""; double bv = -1; foreach (var kv in d) if (kv.Value > bv) { bv = kv.Value; best = kv.Key; } return best; };
                var inv = CultureInfo.InvariantCulture;
                bool based = BaseHours > 0 || BaseLaps > 0 || BaseKm > 0 || BaseRaces > 0;
                string ago = "";
                if (lastRun != null)
                {
                    DateTime lw = lastRun.When.ToLocalTime();
                    int days = (DateTime.Today - lw.Date).Days;
                    ago = lw.ToString(lw.Year == DateTime.Today.Year ? "ddd d MMM" : "d MMM yyyy", inv);   // a date, not "yesterday"
                }
                return "{\"hours\":" + (BaseHours + secs / 3600).ToString("0.0", inv) + ",\"todayMin\":" + Math.Round(today / 60) +
                       ",\"laps\":" + (BaseLaps + laps) + ",\"km\":" + Math.Round(BaseKm + m / 1000) + ",\"sessions\":" + sessions +
                       ",\"races\":" + (BaseRaces + races) + ",\"based\":" + (based ? "true" : "false") +
                       ",\"since\":" + Json_.S(first == DateTime.MaxValue ? "" : first.ToLocalTime().ToString("MMMM yyyy", inv)) +
                       ",\"topCar\":" + Json_.S(top(byCar)) + ",\"topTrack\":" + Json_.S(top(byTrack)) +
                       ",\"name\":" + Json_.S(newest == null ? "" : newest.Name) + ",\"lic\":" + Json_.S(newest == null ? "" : newest.Lic) +
                       ",\"ir\":" + (newest == null ? 0 : newest.IR) +
                       ",\"lastTrack\":" + Json_.S(lastRun == null ? "" : lastRun.Track) + ",\"lastCar\":" + Json_.S(lastRun == null ? "" : lastRun.Car) +
                       ",\"lastAgo\":" + Json_.S(ago) + ",\"scanning\":" + (scanning ? "true" : "false") + ",\"upgrading\":" + pendingUpgrade + "," + WeekJson() + "}";
            }
        }
    }

    // ---------------- Friends mode (guest page on the Stream Deck) ----------------
    // irdeck writes the choices to guest\state.ini; the settings are in guest\guest.ini. This serves both to the
    // dashboard, and keeps each driver's best lap per car and track in guest\board.tsv.
    static class Guest
    {
        public static string Dir;
        static readonly object gate = new object();

        static Dictionary<string, Dictionary<string, string>> Ini()
        {
            var ini = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
            string file = Path.Combine(Dir, "guest.ini"), sec = "";
            if (!File.Exists(file)) return ini;
            foreach (string raw in File.ReadAllLines(file))
            {
                string l = raw.Trim();
                if (l.Length == 0 || l.StartsWith(";")) continue;
                if (l.StartsWith("[") && l.EndsWith("]")) { sec = l.Substring(1, l.Length - 2).Trim(); continue; }
                int e = l.IndexOf('='); if (e <= 0) continue;
                if (!ini.ContainsKey(sec)) ini[sec] = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                ini[sec][l.Substring(0, e).Trim()] = l.Substring(e + 1).Trim();
            }
            return ini;
        }
        static string Get(Dictionary<string, Dictionary<string, string>> ini, string sec, string key)
        { Dictionary<string, string> s; string v; return ini.TryGetValue(sec, out s) && s.TryGetValue(key, out v) ? v : ""; }
        static string Part(string v, int i) { string[] p = v.Split('|'); return i < p.Length ? p[i].Trim() : ""; }

        static Dictionary<string, string> State()
        {
            var st = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string file = Path.Combine(Dir, "state.ini");
            if (File.Exists(file)) foreach (string l in File.ReadAllLines(file)) { int e = l.IndexOf('='); if (e > 0) st[l.Substring(0, e)] = l.Substring(e + 1); }
            return st;
        }
        static string Sv(Dictionary<string, string> st, string k) { string v; return st.TryGetValue(k, out v) ? v : ""; }

        static string DriverName(Dictionary<string, Dictionary<string, string>> ini, string id)
        { return string.IsNullOrEmpty(id) || id.Equals("guest", StringComparison.OrdinalIgnoreCase) ? "Guest" : id; }

        // drivers added on the Stream Deck keyboard, most recent first (irdeck writes guest\drivers.txt)
        static List<string> Drivers(Dictionary<string, Dictionary<string, string>> ini)
        {
            var list = new List<string>();
            string file = Path.Combine(Dir, "drivers.txt");
            if (File.Exists(file)) { foreach (string l in File.ReadAllLines(file)) if (l.Trim().Length > 0) list.Add(l.Trim()); return list; }
            foreach (string id in new[] { "1", "2", "3", "4" })
            { string n = Get(ini, "drivers", id); if (n.Length > 0 && !n.StartsWith("Friend ", StringComparison.OrdinalIgnoreCase)) list.Add(n); }
            return list;
        }

        // the name being typed on the Stream Deck keyboard right now (shown big on the top screen); null = not typing
        public static string Draft;

        // names CrewChief has recordings for (it can only say those); read once
        static HashSet<string> voices;
        static bool VoiceKnown(string name)
        {
            if (string.IsNullOrEmpty(name) || name.Equals("guest", StringComparison.OrdinalIgnoreCase)) return false;
            if (voices == null)
            {
                voices = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"CrewChiefV4\sounds\personalisations");
                if (Directory.Exists(dir)) foreach (string d in Directory.GetDirectories(dir)) voices.Add(Path.GetFileName(d));
            }
            string n = name.Trim();
            return voices.Contains(n) || voices.Contains(n.Split(' ')[0]);
        }

        public static string Json()
        {
            lock (gate)
            {
                if (Dir == null) return "{\"active\":false}";
                var ini = Ini(); var st = State();
                bool active = Sv(st, "active") == "1";
                string car = Sv(st, "car"), track = Sv(st, "track"), drv = Sv(st, "driver");
                if (drv == "") drv = "guest";
                var inv = CultureInfo.InvariantCulture;
                // this car and track's leaderboard: best per driver, fastest first
                var best = new Dictionary<string, double>();
                string bf = Path.Combine(Dir, "board.tsv");
                if (File.Exists(bf))
                    foreach (string l in File.ReadAllLines(bf))
                    {
                        string[] f = l.Split('\t'); double t;
                        if (f.Length < 4 || f[1] != car || f[2] != track || !double.TryParse(f[3], NumberStyles.Float, inv, out t)) continue;
                        double b; if (!best.TryGetValue(f[0], out b) || t < b) best[f[0]] = t;
                    }
                var rows = new List<KeyValuePair<string, double>>(best);
                rows.Sort(delegate (KeyValuePair<string, double> a, KeyValuePair<string, double> b) { return a.Value.CompareTo(b.Value); });
                var board = new List<string>();
                foreach (var kv in rows) board.Add("{\"name\":" + Json_.S(kv.Key) + ",\"time\":" + kv.Value.ToString("0.000", inv) + "}");
                var drivers = new List<string>();
                foreach (string n in Drivers(ini)) drivers.Add(Json_.S(n));
                var cars = new List<string>(); var tracks = new List<string>();
                Dictionary<string, string> sec;
                if (ini.TryGetValue("cars", out sec)) foreach (var kv in sec) cars.Add("{\"key\":" + Json_.S(kv.Key) + ",\"name\":" + Json_.S(Part(kv.Value, 0)) + ",\"aids\":" + Json_.S(Part(kv.Value, 2)) + "}");
                if (ini.TryGetValue("tracks", out sec)) foreach (var kv in sec) tracks.Add("{\"key\":" + Json_.S(kv.Key) + ",\"name\":" + Json_.S(Part(kv.Value, 0)) + "}");
                Frame lf = Sdk.Latest;
                return "{\"active\":" + (active ? "true" : "false") +
                       ",\"session\":" + (lf.Connected ? "true" : "false") + ",\"driving\":" + (Program.IsDriving ? "true" : "false") +
                       ",\"event\":" + ((DateTime.Now - eventAt).TotalSeconds < 30 ? eventJson : "null") +
                       ",\"driverId\":" + Json_.S(drv) + ",\"draft\":" + (Draft == null ? "null" : Json_.S(Draft)) +
                       ",\"voiceDriver\":" + (VoiceKnown(drv) ? "true" : "false") + ",\"voiceDraft\":" + (VoiceKnown(Draft) ? "true" : "false") + ",\"carList\":[" + string.Join(",", cars.ToArray()) + "],\"trackList\":[" + string.Join(",", tracks.ToArray()) + "]" +
                       ",\"driver\":" + Json_.S(DriverName(ini, drv)) +
                       ",\"car\":{\"key\":" + Json_.S(car) + ",\"name\":" + Json_.S(Part(Get(ini, "cars", car), 0)) + ",\"full\":" + Json_.S(Part(Get(ini, "cars", car), 1)) + ",\"aids\":" + Json_.S(Part(Get(ini, "cars", car), 2)) + "}" +
                       ",\"track\":{\"key\":" + Json_.S(track) + ",\"name\":" + Json_.S(Part(Get(ini, "tracks", track), 0)) + ",\"full\":" + Json_.S(Part(Get(ini, "tracks", track), 1)) + "}" +
                       ",\"wheel\":" + Json_.S(Sv(st, "wheel")) +
                       ",\"wheelFeel\":" + WheelNum(ini, st, inv) + ",\"wheelSent\":" + NumOrNull(Sv(st, "wheel_sent"), inv) +
                       ",\"wheelRead\":" + NumOrNull(Sv(st, "wheel_read"), inv) + ",\"wheelOwn\":" + NumOrNull(Sv(st, "own_ffb"), inv) +
                       ",\"line\":" + (Sv(st, "line") != "0" ? "true" : "false") +
                       ",\"lineKey\":" + (Get(ini, "options", "racing_line_key") != "" ? "true" : "false") +
                       ",\"coach\":" + (Sv(st, "coach") != "0" ? "true" : "false") + ",\"board\":" + (Sv(st, "board") != "0" ? "true" : "false") +
                       ",\"drivers\":[" + string.Join(",", drivers.ToArray()) + "],\"times\":[" + string.Join(",", board.ToArray()) + "]}";
            }
        }

        static string NumOrNull(string s, CultureInfo inv)
        {
            double v;
            return double.TryParse(s, NumberStyles.Float, inv, out v) ? v.ToString("0.0", inv) : "null";
        }

        // Feel in Nm for the top screen. Full uses your saved strength once a session has seen it.
        static string WheelNum(Dictionary<string, Dictionary<string, string>> ini, Dictionary<string, string> st, CultureInfo inv)
        {
            string w = Sv(st, "wheel");
            if (w == "" || w == "full") return NumOrNull(Sv(st, "own_ffb"), inv);
            double v;
            if (double.TryParse(Get(ini, "wheel", w), NumberStyles.Float, inv, out v) && v > 0) return v.ToString("0.0", inv);
            return w == "light" ? "8.0" : "14.0";
        }

        // A press on the Stream Deck friends screen: run the matching irdeck command (whitelisted, no free text).
        public static bool Do(string c, string a)
        {
            if (Watch.IrdeckPath == null || !File.Exists(Watch.IrdeckPath)) return false;
            a = Regex.IsMatch(a ?? "", "^[A-Za-z0-9_-]{0,40}$") ? (a ?? "") : "";
            string args;
            switch (c)
            {
                case "on": case "off": case "start": case "reset": case "next": case "line": case "coach": case "board": args = "guest " + c; break;
                case "car": case "track": case "driver": case "wheel": case "adddriver": case "deldriver":
                    if (a == "") return false; args = "guest " + c + " " + a; break;
                case "getout": args = "getout"; break;
                case "seatdown": args = "key --sim ctrl+["; break;
                case "seatup": args = "key --sim ctrl+]"; break;
                case "voldown": args = "media voldown"; break;
                case "volup": args = "media volup"; break;
                default: return false;
            }
            if (c == "on" && Sv(State(), "active") != "1") friendsSince = DateTime.Now;
            if (c == "off") lock (gate) { if (friendsSince == DateTime.MinValue) friendsSince = DateTime.Today; Podium(); friendsSince = DateTime.MinValue; }
            var psi = new ProcessStartInfo(Watch.IrdeckPath, args);
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(Watch.IrdeckPath);
            Process.Start(psi);
            return true;
        }

        // Every 15 s: finish a CrewChief name that waited for the car to stop, put Peter's wheel back once a
        // session is up and he is not in the car, or send a guest wheel that never went out and a racing line iRacing reset.
        static DateTime lastVoiceTry = DateTime.MinValue;
        public static void Tick()
        {
            try
            {
                if (Dir == null || (DateTime.Now - lastVoiceTry).TotalSeconds < 15) return;
                if (Watch.IrdeckPath == null || !File.Exists(Watch.IrdeckPath)) return;
                string args = null;
                if (Sv(State(), "cc_pending") != "") args = "guest voice";
                else if (!Sdk.Pretend)
                {
                    try { if (Process.GetProcessesByName("irdeck").Length > 0) return; } catch { }
                    Frame lf = Sdk.Latest;
                    if (lf.Connected)
                    {
                        var st = State();
                        bool active = Sv(st, "active") == "1";
                        // own_ffb in state.ini, or the disk copy if a crash landed between the two writes
                        bool ownSaved = Sv(st, "own_ffb") != "";
                        if (!ownSaved) { try { ownSaved = File.Exists(Path.Combine(Dir, "own-ffb.txt")); } catch { } }
                        if (!active && ownSaved && lf.Num("IsOnTrack") == 0 && lf.Num("Speed") < 1.0)
                            args = "guest restore";
                        else if (active && lf.Num("IsOnTrack") != 0)
                        {
                            bool need = false;
                            double sent;
                            // No force sent yet: apply it once. SteeringWheelMaxForceNm stays at Peter's own
                            // maximum after a send, so it must not be what calls hold (that re-applied the old feel).
                            if (!double.TryParse(Sv(st, "wheel_sent"), NumberStyles.Float, CultureInfo.InvariantCulture, out sent) || sent < 1.0) need = true;
                            string want = Sv(st, "line"); if (want == "") want = "1";
                            string on = Sv(st, "line_on"); if (on == "") on = "0";
                            if (want != on && lf.Num("Speed") < 1.0) need = true;
                            if (need) args = "guest hold";
                        }
                    }
                }
                if (args == null) return;
                lastVoiceTry = DateTime.Now;
                var psi = new ProcessStartInfo(Watch.IrdeckPath, args);
                psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(Watch.IrdeckPath);
                Process.Start(psi);
            }
            catch (Exception ex) { Log.W("guest tick: " + ex.Message); }
        }

        // ---- moments worth celebrating: shown on the top screen and flashed on the Stream Deck ----
        // kind: "record" (fastest anyone has gone in this car at this track), "pb" (the driver's own best),
        // "podium" (EXIT: tonight's top three). id changes each time, so the screens notice a new one.
        static int eventId; static string eventJson = "null"; static DateTime eventAt = DateTime.MinValue;
        static DateTime friendsSince = DateTime.MinValue;

        static void Event(string kind, string body)
        {
            eventId++; eventAt = DateTime.Now;
            eventJson = "{\"id\":" + eventId + ",\"kind\":" + Json_.S(kind) + "," + body + "}";
        }

        static List<string[]> Board()
        {
            var rows = new List<string[]>();
            string bf = Path.Combine(Dir, "board.tsv");
            if (File.Exists(bf)) foreach (string l in File.ReadAllLines(bf)) { string[] f = l.Split('\t'); if (f.Length >= 5) rows.Add(f); }
            return rows;
        }

        // a clean lap by the current guest driver (sent by the dashboard page)
        public static void Lap(double t)
        {
            lock (gate)
            {
                if (Dir == null || t < 10 || t > 3600) return;
                var ini = Ini(); var st = State();
                if (Sv(st, "active") != "1") return;
                string drv = Sv(st, "driver"); if (drv == "") drv = "guest";
                string name = DriverName(ini, drv), car = Sv(st, "car"), track = Sv(st, "track");
                var inv = CultureInfo.InvariantCulture;
                double record = double.MaxValue, mine = double.MaxValue; string holder = "";
                foreach (var f in Board())
                {
                    double x; if (f[1] != car || f[2] != track || !double.TryParse(f[3], NumberStyles.Float, inv, out x)) continue;
                    if (x < record) { record = x; holder = f[0]; }
                    if (f[0] == name && x < mine) mine = x;
                }
                string line = string.Join("\t", new[] { name, car, track, t.ToString("0.000", inv), DateTime.Now.ToString("yyyy-MM-dd HH:mm") });
                File.AppendAllText(Path.Combine(Dir, "board.tsv"), line + "\r\n");
                string carName = Part(Get(ini, "cars", car), 0), trackName = Part(Get(ini, "tracks", track), 0);
                string common = "\"name\":" + Json_.S(name) + ",\"time\":" + t.ToString("0.000", inv) + ",\"car\":" + Json_.S(carName) + ",\"track\":" + Json_.S(trackName);
                if (t < record)
                    Event("record", common + ",\"beat\":" + Json_.S(holder == name ? "" : holder) + ",\"by\":" + (record == double.MaxValue ? "0" : (record - t).ToString("0.000", inv)));
                else if (t < mine && mine != double.MaxValue)
                    Event("pb", common + ",\"by\":" + (mine - t).ToString("0.000", inv));
            }
        }

        // EXIT: tonight's top three (each driver's best since friends mode was switched on, this car and track or not)
        static void Podium()
        {
            var best = new Dictionary<string, string[]>();
            var inv = CultureInfo.InvariantCulture;
            foreach (var f in Board())
            {
                DateTime when; double x;
                if (!DateTime.TryParseExact(f[4], "yyyy-MM-dd HH:mm", inv, DateTimeStyles.None, out when) || when < friendsSince.AddMinutes(-1)) continue;
                if (!double.TryParse(f[3], NumberStyles.Float, inv, out x)) continue;
                string[] b; double bx;
                if (!best.TryGetValue(f[0], out b) || (double.TryParse(b[3], NumberStyles.Float, inv, out bx) && x < bx)) best[f[0]] = f;
            }
            if (best.Count == 0) return;
            var list = new List<string[]>(best.Values);
            list.Sort(delegate (string[] a, string[] b) { return double.Parse(a[3], inv).CompareTo(double.Parse(b[3], inv)); });
            var ini = Ini(); var items = new List<string>();
            for (int i = 0; i < Math.Min(3, list.Count); i++)
                items.Add("{\"name\":" + Json_.S(list[i][0]) + ",\"time\":" + list[i][3] + ",\"car\":" + Json_.S(Part(Get(ini, "cars", list[i][1]), 0)) + ",\"track\":" + Json_.S(Part(Get(ini, "tracks", list[i][2]), 0)) + "}");
            Event("podium", "\"top\":[" + string.Join(",", items.ToArray()) + "]");
        }
    }

    // ---------------- Startup intro triggers ----------------
    // The dashboard page and the Stream Deck add-on each play the intro once per Windows start, and again
    // whenever the SHOWCASE key bumps the sequence number. Never while you are driving.
    static class Showcase
    {
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern ulong GetTickCount64();
        static readonly object gate = new object();
        static int seq; static bool deckSeen; static DateTime deckPollAt = DateTime.MinValue;
        static readonly HashSet<string> bootPlayed = new HashSet<string>();
        public static double UptimeSec { get { return GetTickCount64() / 1000.0; } }
        // seconds since the Stream Deck add-on last asked us anything (it asks every 2 s); Rig Doctor uses this
        public static double DeckPollAge { get { lock (gate) return deckPollAt == DateTime.MinValue ? double.MaxValue : (DateTime.Now - deckPollAt).TotalSeconds; } }

        static DateTime introUntil = DateTime.MinValue;
        // The intro is playing or about to (about 14 s long plus the page's polling delay); the side-screen gallery waits for it.
        public static bool IntroActive
        {
            get
            {
                lock (gate)
                {
                    if (DateTime.Now < introUntil) return true;
                    return UptimeSec < 600 && !bootPlayed.Contains("page") && (DateTime.Now - Program.StartedAt).TotalSeconds < 60;
                }
            }
        }

        public static void Request() { lock (gate) if (!Program.IsDriving) { seq++; introUntil = DateTime.Now.AddSeconds(18); } }

        public static string Json(string who)
        {
            lock (gate)
            {
                who = (who == "deck") ? "deck" : "page";
                if (who == "deck") deckPollAt = DateTime.Now;
                if (who == "deck" && !deckSeen) { deckSeen = true; Log.W("showcase: Stream Deck add-on connected"); }
                bool play = false;
                if (!Program.IsDriving && UptimeSec < 600 && !bootPlayed.Contains(who)) { play = true; bootPlayed.Add(who); introUntil = DateTime.Now.AddSeconds(18); }
                return "{\"play\":" + (play ? "true" : "false") + ",\"seq\":" + seq + ",\"driving\":" + (Program.IsDriving ? "true" : "false") + "}";
            }
        }
    }

    // ---------------- Systems check for the intro ----------------
    static class Systems
    {
        static string cached; static DateTime cachedAt;
        static bool Running(string name) { return Process.GetProcessesByName(name).Length > 0; }

        static bool UsbPresent(string vid)
        {
            try
            {
                using (var s = new System.Management.ManagementObjectSearcher("SELECT PNPDeviceID FROM Win32_PnPEntity WHERE PNPDeviceID LIKE 'USB%VID_" + vid + "%'"))
                using (var r = s.Get()) return r.Count > 0;
            }
            catch { return false; }
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Ansi)]
        struct DEVMODE
        {
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string name;
            public short spec, drv, size, extra; public int fields, px, py, orient, fixedOut; public short color, duplex, yres, tt, collate;
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string form;
            public short lp; public int bpp, w, h, flags, hz, x1, x2, x3, x4, x5, x6, x7, x8;
        }
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Ansi)]
        static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);

        // What Windows is running each screen at right now (Rig Doctor): size, refresh rate, rotation (0, 1=90, 2=180, 3=270).
        public sealed class Disp { public Rectangle Bounds; public int W, H, Hz, Orient; public bool Primary; }
        public static List<Disp> Displays()
        {
            List<Disp> list = new List<Disp>();
            foreach (Screen sc in Screen.AllScreens)
            {
                DEVMODE m = new DEVMODE(); m.size = (short)System.Runtime.InteropServices.Marshal.SizeOf(typeof(DEVMODE));
                Disp d = new Disp(); d.Bounds = sc.Bounds; d.Primary = sc.Primary;
                if (EnumDisplaySettings(sc.DeviceName, -1, ref m)) { d.W = m.w; d.H = m.h; d.Hz = m.hz; d.Orient = m.orient; }
                list.Add(d);
            }
            return list;
        }

        public static string Json()
        {
            lock (typeof(Systems))
            {
                if (cached != null && (DateTime.Now - cachedAt).TotalSeconds < 10) return cached;
                var items = new List<string>();
                Action<string, bool, string> add = delegate (string name, bool ok, string detail)
                { items.Add("{\"name\":" + Json_.S(name) + ",\"ok\":" + (ok ? "true" : "false") + ",\"detail\":" + Json_.S(detail) + "}"); };
                bool base_ = UsbPresent("16D0");
                add("Wheelbase", base_, base_ ? (Running("sc-tuner") ? "Simucube · tuner ready" : "Simucube connected") : "not detected");
                bool deck = Running("StreamDeck");
                add("Stream Deck", deck, deck ? "32 keys live" : "not running");
                int race = 0, hz = 0;
                foreach (Screen sc in Screen.AllScreens)
                {
                    DEVMODE m = new DEVMODE(); m.size = (short)System.Runtime.InteropServices.Marshal.SizeOf(typeof(DEVMODE));
                    if (EnumDisplaySettings(sc.DeviceName, -1, ref m) && m.w == 2560 && m.h == 1440) { race++; hz = Math.Max(hz, m.hz); }
                }
                add("Displays", race >= 3, race + " × 2560×1440 · " + hz + " Hz");
                bool ir = Running("iRacingService64") || Running("iRacingUI");
                add("iRacing", ir, ir ? "telemetry link armed" : "not running");
                bool cc = Running("CrewChiefV4");
                add("Spotter", cc, cc ? "CrewChief on the radio" : "not running");
                bool ov = Running("irdashies");
                add("Overlays", ov, ov ? "relative · blind spot · delta" : "not running");
                bool bk = Running("bk-connect");
                add("Haptics", bk, bk ? "ButtKicker connected" : "not running");
                cached = "{\"items\":[" + string.Join(",", items.ToArray()) + "]}";
                cachedAt = DateTime.Now;
                return cached;
            }
        }
    }

    static class Program
    {
        static readonly string Dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        // Read from the latest frame each time, not from the 2-second guard tick: the Session Review asks the moment he gets out of
        // the car and the old cached flag still said "driving" for up to 2 s, so the review answered 503 and was thrown away (2026-10-11).
        public static bool IsDriving { get { try { Frame lf = Sdk.Latest; return lf.Connected && lf.Num("IsOnTrack") != 0; } catch { return false; } } }
        public static string RootDir { get { return Path.GetDirectoryName(Dir); } }   // the iRacingDeck folder
        public static string IniFile;
        public static DateTime StartedAt = DateTime.Now;
        const string WindowTitle = "iRacing Dash";
        static Config cfg;
        static NotifyIcon tray;

        // In the car and rolling: nothing may restart or pop up (same rule irdeck uses for the CrewChief name).
        public static bool CarMoving
        {
            get { Frame f = Sdk.Latest; return f.Connected && f.Num("IsOnTrack") != 0 && f.Num("Speed") > 1.0; }
        }

        // The middle race screen, found by position like irdeck does (the primary one is the dashboard screen
        // above the rig on older layouts, so neither the number nor "primary" can be trusted).
        public static Screen CentreScreen()
        {
            List<Screen> all = new List<Screen>(Screen.AllScreens);
            if (all.Count >= 2)
            {
                Screen top = all[0];
                foreach (Screen s in all) if (s.Bounds.Y < top.Bounds.Y) top = s;
                bool above = true;
                foreach (Screen s in all) if (s != top && s.Bounds.Y < top.Bounds.Bottom) above = false;
                if (above) all.Remove(top);
            }
            all.Sort(delegate (Screen a, Screen b) { return (a.Bounds.X + a.Bounds.Width / 2).CompareTo(b.Bounds.X + b.Bounds.Width / 2); });
            return all[all.Count / 2];
        }

        [STAThread]
        static void Main(string[] args)
        {
            // Public calendar and image hosts require modern TLS on the bundled .NET runtime.
            try
            {
                SecurityProtocolType protocols = SecurityProtocolType.Tls12;
                foreach (string name in Enum.GetNames(typeof(SecurityProtocolType)))
                    if (name == "Tls13") protocols |= (SecurityProtocolType)12288;
                ServicePointManager.SecurityProtocol = protocols;
            }
            catch { ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; }
            // Offline lap analysis for tests\analysis-test.ps1. Exit before the log, the config and the window.
            if (args != null && Array.IndexOf(args, "--analysis") >= 0) Environment.Exit(Analysis.Cli(args));
            if (args != null && Array.IndexOf(args, "--home") >= 0) Environment.Exit(Career.HomeCli(args));      // HOME / outings over a pretend cache (home.cs, tests\home-test.ps1)
            Log.FilePath = Path.Combine(Dir, "irdash.log");
            IniFile = Path.Combine(Dir, "irdash.ini");
            cfg = Config.Load(IniFile);
            TvView.On = cfg.TvOn;
            DeltaBar.Configure(cfg.DeltaOn, cfg.DeltaRef, cfg.DeltaPos, cfg.DeltaScale);
            SimPriority.Mode = cfg.SimPriority;
            bool noBrowser = Array.IndexOf(args, "--no-browser") >= 0;
            Watch.IrdeckPath = Path.Combine(Path.GetDirectoryName(Dir), "irdeck.exe");
            TrackMaps.MapsDir = Path.Combine(Dir, "maps");
            TrackMaps.TelemetryDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "iRacing\\telemetry");
            if (Array.IndexOf(args, "--build-maps") >= 0)
            {
                // one-shot: build maps from every .ibt file, report to the log, exit
                Log.W("build-maps: tracks in telemetry folder: " + string.Join(", ", TrackMaps.IbtTracks().ToArray()));
                TrackMaps.BuildAll();
                Log.W("build-maps: done");
                return;
            }

            bool created;
            Mutex mutex = new Mutex(true, "Local\\IRDashSingleInstance", out created);
            if (!created)
            {
                // Already running: ask that copy to (re)open the dashboard window.
                if (!noBrowser)
                {
                    try { using (WebClient wc = new WebClient()) wc.DownloadString("http://localhost:" + cfg.Port + "/api/open"); }
                    catch { }
                }
                return;
            }

            Application.EnableVisualStyles();
            Log.W("irdash starting on port " + cfg.Port);
            Server server = new Server(cfg.Port, Path.Combine(Dir, "www"), Path.Combine(Dir, "maps"));
            // The port can still be held for a few seconds by the copy that just closed (a restart) or by a program that inherited it.
            // Wait for it instead of giving up on the first try, which left Peter with no Paddock at all after a restart.
            Exception startErr = null;
            for (int attempt = 0; attempt < 20; attempt++)
            {
                try { server.Start(); startErr = null; break; }
                catch (Exception ex) { startErr = ex; Log.W("server start try " + (attempt + 1) + ": " + ex.Message); Thread.Sleep(1000); }
            }
            if (startErr != null)
            {
                MessageBox.Show("Paddock could not start: another program is holding port " + cfg.Port + ".\n\nRestart the PC. If it happens again, tell Claude.\n\n(" + startErr.Message + ")", "Paddock", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            Thread sdk = new Thread(Sdk.Run);
            sdk.IsBackground = true;
            sdk.Start();
            // career stats for the intro: first read two minutes after start, so it never competes with boot
            Career.TelemetryDir = TrackMaps.TelemetryDir;
            Career.CacheFile = Path.Combine(Dir, "career-cache.tsv");
            Guest.Dir = Path.Combine(Path.GetDirectoryName(Dir), "guest");
            Timings.Init(Path.Combine(Dir, "timings.tsv"), Path.Combine(Dir, "start-mark.txt"));
            Overlays.Init(Path.Combine(RootDir, "overlays"));
            MyDrive.Init(Path.Combine(RootDir, "mydrive"));
            Replay.Init(Path.Combine(RootDir, "replay"));
            Gallery.Init(Path.Combine(RootDir, @"paddock\gallery"));
            try { Cars.Init(RootDir); } catch (Exception ex) { Log.W("cars: could not start: " + ex.Message); }   // CP-1: iRacing's own car pictures
            Perf.Init(Path.Combine(RootDir, "data"));
            try { Perf.Start(); } catch (Exception ex) { Log.W("perf: could not start: " + ex.Message); }
            try { Vault.Init(RootDir); Vault.Start(); } catch (Exception ex) { Log.W("vault: could not start: " + ex.Message); }   // vault=0: both return at once
            try { Recorder.Init(RootDir); Recorder.Start(); } catch (Exception ex) { Log.W("recorder: could not start: " + ex.Message); }   // recorder=0 (the default): Start returns at once; Init only reads the clips already made
            try { RaceField.Init(RootDir); RaceField.Start(); } catch (Exception ex) { Log.W("field: could not start: " + ex.Message); }   // W6: logs every car while a session with other cars runs (reads only; BelowNormal)
            try { Tv.Start(); } catch (Exception ex) { Log.W("tv: could not start: " + ex.Message); }
            try { Official.Init(Path.Combine(RootDir, @"data\official")); } catch (Exception ex) { Log.W("official: could not start: " + ex.Message); }   // official=0: returns at once
            try { RealWorld.Init(Path.Combine(RootDir, @"data\official")); } catch (Exception ex) { Log.W("realworld: could not start: " + ex.Message); }
            Coverage.Init(RootDir);   // where to watch in the U.S. (dash\coverage.json, coverage.cs)
            Doctor.Init(RootDir, Dir);
            Phone.Init(RootDir, Dir); Home.Init(RootDir, cfg.Port);   // P1: the phone app's pairing + HOME's hero picture
            Career.ScanLater(File.Exists(Career.CacheFile) ? 120000 : 5000);
            Thread maps = new Thread(delegate () { try { TrackMaps.BuildAll(); } catch (Exception ex) { Log.W("maps: " + ex.Message); } });
            maps.IsBackground = true;
            maps.Start();
            // real GPS lines from Peter's own telemetry (gpsmap.cs): built once, below normal, never while a session runs
            Thread gpsmaps = new Thread(delegate () { try { Analysis.BuildAllGps(TrackMaps.TelemetryDir, TrackMaps.MapsDir); } catch (Exception ex) { Log.W("gpsmap: " + ex.Message); } });
            gpsmaps.IsBackground = true;
            gpsmaps.Priority = ThreadPriority.BelowNormal;
            gpsmaps.Start();

            SynchronizationContext ui = null;
            server.OpenRequested = delegate { if (ui != null) ui.Post(delegate { OpenDashboard(); }, null); };

            tray = new NotifyIcon();
            tray.Icon = MakeIcon();
            tray.Text = "Paddock";
            tray.Visible = true;
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("Open dashboard", null, delegate { OpenDashboard(); });
            menu.Items.Add("Open demo (fake race)", null, delegate { OpenDashboard("?demo=1"); });
            menu.Items.Add("Play intro", null, delegate { Showcase.Request(); });
            menu.Items.Add("Open folder", null, delegate { Process.Start("explorer.exe", "\"" + Dir + "\""); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit", null, delegate { CloseDashboard(); tray.Visible = false; Application.Exit(); });
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += delegate { OpenDashboard(); };

            System.Windows.Forms.Timer tip = new System.Windows.Forms.Timer();
            tip.Interval = 2000;
            tip.Tick += delegate { tray.Text = Sdk.Latest.Connected ? "Paddock live" : "Paddock waiting for iRacing"; };
            tip.Start();

            System.Windows.Forms.Timer first = new System.Windows.Forms.Timer();
            first.Interval = 300;
            first.Tick += delegate
            {
                first.Stop();
                ui = SynchronizationContext.Current;
                if (cfg.OpenOnStart && !noBrowser) OpenDashboard();
                try { DeltaBar.Start(); } catch (Exception ex) { Log.W("delta bar: could not start: " + ex.Message); }
                try { Gallery.Start(); } catch (Exception ex) { Log.W("gallery: could not start: " + ex.Message); }
            };
            first.Start();

            // Every 2 s: keep the sim window across the race monitors and the dashboard on its monitor.
            System.Windows.Forms.Timer guard = new System.Windows.Forms.Timer();
            guard.Interval = 2000;
            guard.Tick += delegate
            {
                try { Frame lf = Sdk.Latest; Driving = lf.Connected && lf.Num("IsOnTrack") != 0; } catch { Driving = false; }
                try { if (Driving && (DateTime.Now - lastOverlayRaise).TotalSeconds > 5) RaiseOverlays(); } catch { }
                try { if (cfg.PlaceSim) PlaceSim(); } catch (Exception ex) { Log.W("place sim: " + ex.Message); }
                try { if (cfg.KeepDash && !noBrowser) KeepDash(); } catch (Exception ex) { Log.W("keep dash: " + ex.Message); }
                try { if (cfg.LogAllCars) EnsureLogAllCars(); } catch (Exception ex) { Log.W("log all cars: " + ex.Message); }
                try { if (cfg.SyncSimIni) EnsureSimIni(); } catch (Exception ex) { Log.W("sim ini: " + ex.Message); }
                try { if (cfg.Watchdog) Watch.Tick(Sdk.Latest.Connected); } catch (Exception ex) { Log.W("watchdog: " + ex.Message); }
                Guest.Tick();
                try { Timings.Tick(); } catch (Exception ex) { Log.W("timings: " + ex.Message); }
                try { SimPriority.Tick(Sdk.Latest.Connected); } catch (Exception ex) { Log.W("sim priority: " + ex.Message); }
                try { Nav.Tick(Driving); } catch { }
                try { Doctor.Tick(); } catch (Exception ex) { Log.W("doctor: " + ex.Message); }
            };
            guard.Start();

            Application.Run();
            GC.KeepAlive(mutex);
        }

        static Icon MakeIcon()
        {
            Bitmap bmp = new Bitmap(32, 32);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                // little checkered flag
                for (int y = 0; y < 4; y++)
                    for (int x = 0; x < 4; x++)
                        using (SolidBrush b = new SolidBrush((x + y) % 2 == 0 ? Color.White : Color.FromArgb(30, 30, 30)))
                            g.FillRectangle(b, 4 + x * 6, 3 + y * 6, 6, 6);
                using (Pen p = new Pen(Color.FromArgb(255, 200, 0), 3)) g.DrawLine(p, 4, 3, 4, 30);
            }
            return Icon.FromHandle(bmp.GetHicon());
        }

        static Screen PickScreen()
        {
            Screen[] all = Screen.AllScreens;
            if (!string.IsNullOrEmpty(cfg.Screen) && cfg.Screen != "auto")
                foreach (Screen sc in all)
                    if (string.Equals(sc.DeviceName, cfg.Screen, StringComparison.OrdinalIgnoreCase)) return sc;
            Screen best = all[0];
            foreach (Screen sc in all) if (sc.Bounds.Y < best.Bounds.Y) best = sc;
            return best;
        }

        // "auto" means the screen strictly above all the others (the 1080p dashboard monitor above the race screens). When that monitor is off
        // or asleep at logon, every remaining screen sits at y 0 and PickScreen used to take a race screen: the kiosk dashboard then covered
        // it and the sim was placed over only two screens. Better no dashboard until the monitor is back (KeepDash retries every 2 s).
        static bool DashScreenFound()
        {
            Screen[] all = Screen.AllScreens;
            if (all.Length <= 1 || (!string.IsNullOrEmpty(cfg.Screen) && cfg.Screen != "auto")) return true;
            Screen best = PickScreen();
            foreach (Screen sc in all) if (!sc.Equals(best) && sc.Bounds.Y <= best.Bounds.Y) return false;
            return true;
        }

        static string BrowserExe()
        {
            if (!string.IsNullOrEmpty(cfg.Browser) && cfg.Browser != "auto" && File.Exists(cfg.Browser)) return cfg.Browser;
            string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string[] candidates = {
                Path.Combine(pf, @"Google\Chrome\Application\chrome.exe"),
                Path.Combine(pf86, @"Google\Chrome\Application\chrome.exe"),
                Path.Combine(local, @"Google\Chrome\Application\chrome.exe"),
                Path.Combine(pf86, @"Microsoft\Edge\Application\msedge.exe"),
                Path.Combine(pf, @"Microsoft\Edge\Application\msedge.exe")
            };
            foreach (string c in candidates) if (File.Exists(c)) return c;
            return null;
        }

        static List<Process> DashWindows()
        {
            List<Process> r = new List<Process>();
            foreach (string n in new[] { "chrome", "msedge" })
                foreach (Process p in Process.GetProcessesByName(n))
                {
                    try { string wt = p.MainWindowTitle; if (wt.StartsWith(WindowTitle) || wt.StartsWith("localhost:" + cfg.Port + "/")) r.Add(p); } catch { }
                }
            return r;
        }

        static void OpenDashboard() { OpenDashboard(""); }

        static void OpenDashboard(string query)
        {
            List<Process> open = DashWindows();
            if (open.Count > 0)
            {
                if (query == "") return;          // already up
                CloseDashboard();                 // switching to/from demo: reopen with the new address
                Thread.Sleep(800);
            }
            string exe = BrowserExe();
            if (exe == null)
            {
                MessageBox.Show("No Chrome or Edge found. Set browser= in irdash.ini.", "Paddock");
                return;
            }
            if (!DashScreenFound()) { Log.W("dashboard not opened: the dashboard monitor is not there (only the race screens are)"); return; }
            Rectangle b = PickScreen().Bounds;
            string profile = Path.Combine(Dir, "browser-profile");
            string url = "http://localhost:" + cfg.Port + "/" + cfg.Page + query;
            string args =
                "--user-data-dir=\"" + profile + "\" --no-first-run --no-default-browser-check " +
                "--hide-crash-restore-bubble --disable-session-crashed-bubble --disable-features=Translate " +
                "--window-position=" + b.X + "," + b.Y + " --window-size=" + b.Width + "," + b.Height + " " +
                (cfg.Kiosk ? "--kiosk " : "") + "--app=" + url;
            try
            {
                Process.Start(exe, args);
                // The new window has no title for the first seconds, so DashWindows() cannot see it. Without this stamp KeepDash (every 2 s)
                // saw "no dashboard" right after the start-up open and opened a SECOND kiosk window on the same screen.
                lastAutoOpen = DateTime.Now;
                Log.W("opened dashboard on " + b + " with " + Path.GetFileName(exe));
            }
            catch (Exception ex) { Log.W("open: " + ex.Message); }
        }

        // ---- window placement guard ----
        static IntPtr simHwnd = IntPtr.Zero;
        static int simTries;
        static DateTime lastAutoOpen = DateTime.MinValue;

        public static Rectangle SimTarget()
        {
            if (!string.IsNullOrEmpty(cfg.SimRect) && cfg.SimRect != "auto")
            {
                string[] p = cfg.SimRect.Split(',');
                int x, y, w, h;
                if (p.Length == 4 && int.TryParse(p[0].Trim(), out x) && int.TryParse(p[1].Trim(), out y) &&
                    int.TryParse(p[2].Trim(), out w) && int.TryParse(p[3].Trim(), out h) && w > 0 && h > 0)
                    return new Rectangle(x, y, w, h);
            }
            Rectangle dash = DashScreenFound() ? PickScreen().Bounds : Rectangle.Empty, u = Rectangle.Empty;
            foreach (Screen s in Screen.AllScreens)
                if (s.Bounds != dash) u = u.IsEmpty ? s.Bounds : Rectangle.Union(u, s.Bounds);
            return u;
        }

        static void PlaceSim()
        {
            Process[] ps = Process.GetProcessesByName("iRacingSim64DX11");
            if (ps.Length == 0) { simHwnd = IntPtr.Zero; return; }
            IntPtr h = ps[0].MainWindowHandle;
            if (h == IntPtr.Zero || Native.IsIconic(h)) return;
            RECT r;
            if (!Native.GetWindowRect(h, out r)) return;
            if (r.Right - r.Left < 1200) return;                 // loading splash, not the sim view
            if (h != simHwnd) { simHwnd = h; simTries = 0; }
            Rectangle t = SimTarget();
            if (t.IsEmpty) return;
            int style = Native.GetWindowLong(h, Native.GWL_STYLE);
            bool framed = (style & (Native.WS_CAPTION | Native.WS_THICKFRAME)) != 0;
            if (!framed && r.Left == t.Left && r.Top == t.Top && r.Right == t.Right && r.Bottom == t.Bottom) { simTries = 0; OverTaskbar(h, "iRacing"); return; }
            if (simTries >= 5) return;                           // something keeps moving it back; don't fight it
            simTries++;
            if (framed) Native.SetWindowLong(h, Native.GWL_STYLE, style & ~(Native.WS_CAPTION | Native.WS_THICKFRAME));
            Native.SetWindowPos(h, IntPtr.Zero, t.X, t.Y, t.Width, t.Height,
                Native.SWP_NOZORDER | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER | Native.SWP_FRAMECHANGED);
            Log.W("placed iRacing window at " + t + " (was " + r.Left + "," + r.Top + " " + (r.Right - r.Left) + "x" + (r.Bottom - r.Top) + ")");
        }

        static void KeepDash()
        {
            if (!DashScreenFound()) return;       // never drag the dashboard onto a race screen
            List<Process> ws = DashWindows();
            Rectangle b = PickScreen().Bounds;
            if (ws.Count == 0)
            {
                // Reopen a closed dashboard, but never pop a window up while you are driving.
                Frame f = Sdk.Latest;
                if (f.Connected && f.Num("IsOnTrack") != 0) return;
                if ((DateTime.Now - lastAutoOpen).TotalSeconds < 20) return;
                lastAutoOpen = DateTime.Now;
                IntPtr prev = Native.GetForegroundWindow();
                OpenDashboard();
                // hand focus back to whatever had it (e.g. the sim) once the browser window is up
                System.Windows.Forms.Timer back = new System.Windows.Forms.Timer();
                back.Interval = 2500;
                back.Tick += delegate { back.Stop(); back.Dispose(); GiveFocus(prev); };
                back.Start();
                return;
            }
            foreach (Process p in ws)
            {
                IntPtr h = p.MainWindowHandle;
                RECT r;
                if (h == IntPtr.Zero || !Native.GetWindowRect(h, out r)) continue;
                if (Native.IsIconic(h)) { Native.ShowWindow(h, 4); continue; }   // SW_SHOWNOACTIVATE
                if (r.Left != b.Left || r.Top != b.Top || r.Right != b.Right || r.Bottom != b.Bottom)
                {
                    Native.SetWindowPos(h, IntPtr.Zero, b.X, b.Y, b.Width, b.Height,
                        Native.SWP_NOZORDER | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
                    Log.W("moved dashboard back to " + b);
                }
                OverTaskbar(h, "dashboard");
            }
        }

        // Tells the Windows taskbar this window is full screen (so it steps behind it) and keeps the window on top.
        static bool Driving;              // in the car, on track (updated every guard tick)
        static DateTime lastOverlayRaise = DateTime.MinValue;

        delegate bool EnumProc(IntPtr h, IntPtr l);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);

        // irdashies overlay windows (titled "irDashies - <display>") must sit in front of the sim while driving.
        static void RaiseOverlays()
        {
            lastOverlayRaise = DateTime.Now;
            EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                StringBuilder t = new StringBuilder(128);
                GetWindowText(h, t, 128);
                if (t.ToString().StartsWith("irDashies -") && IsWindowVisible(h))
                    Native.SetWindowPos(h, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
                return true;
            }, IntPtr.Zero);
            DeltaBar.Raise();      // our own delta bar goes above the sim the same way
        }
        static ITaskbarList2 taskbar;
        static readonly HashSet<IntPtr> marked = new HashSet<IntPtr>();
        static void OverTaskbar(IntPtr h, string what)
        {
            if (!cfg.HideTaskbar || h == IntPtr.Zero) return;
            if (!marked.Contains(h))
            {
                marked.Add(h);
                try
                {
                    if (taskbar == null) { taskbar = (ITaskbarList2)new TaskbarListCom(); taskbar.HrInit(); }
                    taskbar.MarkFullscreenWindow(h, true);
                    Log.W("marked " + what + " window full screen for the taskbar");
                }
                catch (Exception ex) { Log.W("taskbar: " + ex.Message); }
            }
            // Above the taskbar only while you are driving. Out of the car (menus, loading, launch errors) these
            // windows are normal, so EasyAntiCheat errors and other prompts can never hide behind them (2026-10-08).
            bool top = (Native.GetWindowLong(h, Native.GWL_EXSTYLE) & Native.WS_EX_TOPMOST) != 0;
            if (Driving && !top)
            {
                Native.SetWindowPos(h, Native.HWND_TOPMOST, 0, 0, 0, 0,
                    Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
                Log.W(what + " window above the taskbar while driving");
                RaiseOverlays();     // keep irdashies overlays in front of the sim we just raised
            }
            else if (!Driving && top)
            {
                Native.SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0,     // HWND_NOTOPMOST
                    Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
                Log.W(what + " window back to normal (out of the car)");
            }
        }

        // iRacing 2026 S3 added [Misc] irsdkLogAllCars to app.ini; 1 lets the CarIdx arrays cover every car.
        // The sim rewrites app.ini when it exits, so only touch it while the sim is closed.
        static DateTime lastIniCheck = DateTime.MinValue;
        static void EnsureLogAllCars()
        {
            if ((DateTime.Now - lastIniCheck).TotalSeconds < 30) return;
            lastIniCheck = DateTime.Now;
            if (Process.GetProcessesByName("iRacingSim64DX11").Length > 0) return;
            string ini = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "iRacing\\app.ini");
            if (!File.Exists(ini)) return;
            string text = File.ReadAllText(ini, Encoding.GetEncoding(28591));
            Regex re = new Regex("(?m)^(irsdkLogAllCars=)0");
            if (!re.IsMatch(text)) return;
            string bak = Path.Combine(Path.GetDirectoryName(Dir), "backup\\app-" + DateTime.Now.ToString("yyyyMMdd-HHmm") + ".ini");
            Directory.CreateDirectory(Path.GetDirectoryName(bak));
            File.Copy(ini, bak, true);
            File.WriteAllText(ini, re.Replace(text, "${1}1", 1), Encoding.GetEncoding(28591));
            Log.W("set irsdkLogAllCars=1 in app.ini (backup " + Path.GetFileName(bak) + ")");
        }

        // Keeps iRacing's saved window position (rendererDX11Monitor.ini) matching the race screens, so the sim
        // opens in the right place even after the monitor layout changes. Only while the sim is closed.
        static DateTime lastSimIniCheck = DateTime.MinValue;
        static void EnsureSimIni()
        {
            if ((DateTime.Now - lastSimIniCheck).TotalSeconds < 30) return;
            lastSimIniCheck = DateTime.Now;
            if (Process.GetProcessesByName("iRacingSim64DX11").Length > 0) return;
            string ini = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "iRacing\\rendererDX11Monitor.ini");
            if (!File.Exists(ini)) return;
            Rectangle t = SimTarget();
            if (t.IsEmpty) return;
            Encoding enc = Encoding.GetEncoding(28591);
            string text = File.ReadAllText(ini, enc), was = text;
            var want = new Dictionary<string, string> {
                { "windowedXPos", t.X.ToString() }, { "windowedYPos", t.Y.ToString() }, { "windowedWidth", t.Width.ToString() },
                { "windowedHeight", t.Height.ToString() }, { "windowedAlignment", "0" }, { "windowedMaximized", "0" }, { "fullScreen", "0" }, { "border", "0" } };
            foreach (var kv in want) text = Regex.Replace(text, "(?m)^(" + kv.Key + "=)[^\\s;]*", "${1}" + kv.Value);
            if (text == was) return;
            string bak = Path.Combine(Path.GetDirectoryName(Dir), "backup\\rendererDX11Monitor-" + DateTime.Now.ToString("yyyyMMdd-HHmm") + ".ini");
            Directory.CreateDirectory(Path.GetDirectoryName(bak));
            File.Copy(ini, bak, true);
            File.WriteAllText(ini, text, enc);
            Log.W("updated iRacing window position to " + t + " (backup " + Path.GetFileName(bak) + ")");
        }

        static void GiveFocus(IntPtr h)
        {
            if (h == IntPtr.Zero) return;
            uint pid;
            uint target = Native.GetWindowThreadProcessId(h, out pid), fg = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out pid);
            uint me = Native.GetCurrentThreadId();
            Native.AttachThreadInput(me, fg, true);
            Native.AttachThreadInput(me, target, true);
            Native.SetForegroundWindow(h);
            Native.AttachThreadInput(me, target, false);
            Native.AttachThreadInput(me, fg, false);
        }

        static void CloseDashboard()
        {
            foreach (Process p in DashWindows()) { try { p.CloseMainWindow(); } catch { } }
        }

        static string StartupLink()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "iRacing Dash.lnk");
        }

        // Adds or removes a shortcut in the user's Startup folder. Returns the new state.
        static bool ToggleStartup()
        {
            string link = StartupLink();
            try
            {
                if (File.Exists(link)) { File.Delete(link); Log.W("removed from startup"); return false; }
                Type t = Type.GetTypeFromProgID("WScript.Shell");
                object shell = Activator.CreateInstance(t);
                object sc = t.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { link });
                Type st = sc.GetType();
                st.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { Path.Combine(Dir, "irdash.exe") });
                st.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { Dir });
                st.InvokeMember("Description", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { "iRacing dashboard on the top monitor" });
                st.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, sc, null);
                Log.W("added to startup");
                return true;
            }
            catch (Exception ex)
            {
                Log.W("startup: " + ex.Message);
                return File.Exists(link);
            }
        }
    }
}
