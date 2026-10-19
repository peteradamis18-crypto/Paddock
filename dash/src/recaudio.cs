// RECORDER SOUND (docs\design\audio-recording.md): the sound under Paddock's own race video.
//   While the video recorder runs, this records what iRacing and CrewChief play, and nothing else: Windows "process loopback"
//   (Windows 10 2004 / build 19041 and later) hands over the sound of one program and its children, so music, Discord or a browser
//   never end up in a clip. Only when Windows cannot do that (or neither program is running) is the whole PC's output recorded instead.
//   Shared mode and read only: it never changes a sound setting, never takes a device for itself, and the game cannot notice it.
//   One BelowNormal thread polls every 10 ms and writes 48 kHz 16-bit stereo raw PCM in ~10 s chunks, <rec dir>\aud-<start, microseconds
//   since 1970>.pcm. Frame k of a chunk is at wall clock start + k/48 ms: the same clock the video frames are stamped with (setpts=RTCTIME),
//   so a picture and its sound meet by time. Nothing playing is written as silence; a hole between chunks means the capture was not running.
//   The recorder (recorder.cs) starts and stops it with ffmpeg and asks BuildPcm for the sound of every file it writes, span by span.
//   This file uses nothing from irdash (its own clock, a log hook), so tests\audio-harness.cs can compile it on its own.
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
    sealed class AudChunk { public string Path = ""; public double StartMs; public long Frames; public bool Open; public double EndMs { get { return StartMs + Frames / 48.0; } } }

    // ---------------- the Windows sound interfaces (only the methods used, in their order) ----------------
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudDeviceEnumerator { [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IntPtr devs); [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IAudDevice dev); }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class AudDeviceEnumerator { }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudDevice { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr prm, [MarshalAs(UnmanagedType.IUnknown)] out object itf); }
    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudClient
    {
        [PreserveSig] int Initialize(int shareMode, uint flags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint frames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long def, out long min);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr h);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object svc);
    }
    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devPos, out ulong qpcPos);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }
    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudActivateOp { [PreserveSig] int GetActivateResult(out int hr, [MarshalAs(UnmanagedType.IUnknown)] out object itf); }
    [ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudActivateHandler { void ActivateCompleted(IAudActivateOp op); }
    // the activation calls back on a Windows thread: the handler must say it is agile (callable from any thread)
    [ComImport, Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudAgile { }
    public sealed class AudActivateDone : IAudActivateHandler, IAudAgile
    {
        public readonly ManualResetEvent Done = new ManualResetEvent(false);
        public void ActivateCompleted(IAudActivateOp op) { Done.Set(); }
    }

    static class RecAudio
    {
        public const int Rate = 48000;
        const int RingFrames = Rate * 4, ChunkFrames = Rate * 10, LagMs = 300, Resync = 960;   // 20 ms: a packet this close to where the last one ended continues it (no clicks)
        const uint LOOPBACK = 0x00020000, EVENTCALLBACK = 0x00040000, AUTOCONVERTPCM = 0x80000000, SRC_DEFAULT_QUALITY = 0x08000000;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), IID_IAudioCaptureClient = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");

        [DllImport("Mmdevapi.dll", ExactSpelling = true)]
        static extern int ActivateAudioInterfaceAsync([MarshalAs(UnmanagedType.LPWStr)] string path, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, IntPtr prm, IAudActivateHandler handler, out IAudActivateOp op);
        [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long ft);
        [DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long c);
        [DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long f);

        public static Action<string> Say = delegate (string m) { };     // the recorder points this at irdash.log
        static readonly object gate = new object();
        static readonly List<AudChunk> chunks = new List<AudChunk>();
        static Thread th; static volatile bool stopWanted;
        static volatile string state = "off", source = "", lastErr = "";
        static string lastRunState = "", lastRunSource = "";
        static long runFrames, runPackets; static double runStartMs, runEndMs;

        public static double WallMs() { long ft; GetSystemTimePreciseAsFileTime(out ft); return (ft - 116444736000000000L) / 10000.0; }
        static double Qpc100() { long c, f; QueryPerformanceCounter(out c); QueryPerformanceFrequency(out f); return c * (10000000.0 / f); }

        // ---------------- start / stop (with the video) ----------------
        public static bool Running { get { Thread t = th; return t != null && t.IsAlive; } }
        // off | starting | ok | failed (live, while a capture runs) and idle when none runs
        static volatile bool active;      // between Start and Stop (a capture that failed at the start stays "failed" until the video stops)
        public static string State { get { return active ? state : "idle"; } }
        public static string Source { get { return source; } }
        public static string LastError { get { return lastErr; } }
        public static string LastRunState { get { return lastRunState; } }
        public static string LastRunSource { get { return lastRunSource; } }

        // mode: auto (iRacing + CrewChief, else the whole PC) | system | pid:<n>[,<n>] | synth (test clicks) | off
        public static void Start(string dir, string mode)
        {
            Stop();
            active = true;
            if (mode == "off") { state = "off"; source = ""; lastRunState = "off"; return; }
            stopWanted = false; state = "starting"; source = ""; lastErr = ""; runDir = dir;
            string d = dir, m = mode ?? "auto";
            Thread t = new Thread(delegate () { Run(d, m); });
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Name = "RecorderSound";
            th = t; t.Start();
        }

        public static void Stop()
        {
            active = false;
            Thread t = th; if (t == null) return;
            stopWanted = true;
            if (!t.Join(4000)) Say("recorder: the sound capture did not stop in 4 s");
            th = null;
        }

        // ---------------- the capture thread ----------------
        sealed class Src
        {
            public string What = "", Kind = ""; public int Pid; public IAudClient Client; public IAudCaptureClient Cap; public AutoResetEvent Ev;
            public bool Float; public int Ch = 2; public long Next = -1, Frames; public bool Alive; public double RetryAt, DeadSince;
            public short[] S16 = new short[0]; public float[] F32 = new float[0];
        }

        static double t0; static long flushed; static int[] acc; static AudChunk cur; static FileStream curFs;

        static void Run(string dir, string mode)
        {
            List<Src> srcs = new List<Src>();
            try
            {
                Directory.CreateDirectory(dir);
                acc = new int[RingFrames * 2];
                t0 = WallMs(); flushed = 0; cur = null; curFs = null;
                runStartMs = t0; runFrames = 0; runPackets = 0;
                string why = OpenAll(srcs, mode);
                if (srcs.Count == 0)
                {
                    state = "failed"; lastErr = why; lastRunState = "failed"; lastRunSource = "";
                    Say("recorder: no sound (" + why + ") - the video records without sound");
                    return;
                }
                source = Describe(srcs); lastRunSource = source; state = "ok";
                Say("recorder: sound on (" + source + ", 48 kHz)");
                double lastFlush = 0, lastScan = WallMs();
                while (!stopWanted)
                {
                    double now = WallMs();
                    bool any = false;
                    foreach (Src s in srcs)
                    {
                        if (!s.Alive && now >= s.RetryAt) Reopen(s);
                        if (s.Alive) Drain(s);
                        if (s.Alive) any = true;
                    }
                    if (any) { state = "ok"; }
                    else
                    {
                        double since = double.MaxValue; foreach (Src s in srcs) since = Math.Min(since, s.DeadSince);
                        if (now - since > 5000 && state != "failed") { state = "failed"; Say("recorder: the sound capture stopped (" + lastErr + ") - trying again every 10 s"); }
                    }
                    // a spotter started later joins; never on top of the whole-PC fallback (that already has it: it would play twice)
                    if (mode == "auto" && now - lastScan > 5000) { lastScan = now; bool sys = false; foreach (Src s in srcs) if (s.Kind == "system") sys = true; if (!sys) { AddNewTargets(srcs); source = Describe(srcs); } }
                    if (now - lastFlush >= 100) { lastFlush = now; Flush((long)Math.Floor((now - t0 - LagMs) * 48.0), any); }
                    Thread.Sleep(10);
                }
                // the last moment: everything delivered so far, then up to now
                bool alive = false; foreach (Src s in srcs) if (s.Alive) { Drain(s); alive = alive || s.Alive; }
                Flush((long)Math.Floor((WallMs() - t0) * 48.0), alive);
                lastRunState = state;
            }
            catch (Exception ex) { state = "failed"; lastErr = ex.Message; lastRunState = "failed"; Say("recorder: sound: " + ex.Message); }
            finally
            {
                CloseChunk();
                foreach (Src s in srcs) Close(s);
                runEndMs = WallMs();
                if (runPackets > 0 || lastRunState == "ok") Say("recorder: sound stopped (" + (runFrames / 48000.0).ToString("0.0", Inv) + " s captured in " + ((runEndMs - runStartMs) / 1000.0).ToString("0.0", Inv) + " s)");
            }
        }

        static string Describe(List<Src> srcs)
        {
            List<string> w = new List<string>();
            foreach (Src s in srcs) if (!w.Contains(s.What)) w.Add(s.What);
            w.Sort(delegate (string a, string b) { int ra = a == "iRacing" ? 0 : a == "CrewChief" ? 1 : 2, rb = b == "iRacing" ? 0 : b == "CrewChief" ? 1 : 2; return ra != rb ? ra.CompareTo(rb) : string.CompareOrdinal(a, b); });
            return string.Join(" + ", w.ToArray());
        }

        static string OpenAll(List<Src> srcs, string mode)
        {
            string why = "";
            if (mode == "synth") { Src s = new Src(); s.Kind = "synth"; s.What = "test clicks"; s.Alive = true; srcs.Add(s); return ""; }
            if (mode == "system") { Src s = new Src(); s.Kind = "system"; s.What = "whole PC"; why = OpenSystem(s); if (s.Alive) srcs.Add(s); return why; }
            if (mode.StartsWith("pid:"))
            {
                foreach (string p in mode.Substring(4).Split(','))
                {
                    int pid; if (!int.TryParse(p.Trim(), out pid)) continue;
                    Src s = new Src(); s.Kind = "process"; s.Pid = pid; s.What = "program " + pid; string w = OpenProcess(s);
                    if (s.Alive) srcs.Add(s); else why = w;
                }
                return why;
            }
            // auto: the game and the spotter, nothing else
            AddNewTargets(srcs);
            if (srcs.Count > 0) return "";
            Src sys = new Src(); sys.Kind = "system"; sys.What = "whole PC";
            why = OpenSystem(sys);
            if (sys.Alive) { srcs.Add(sys); Say("recorder: iRacing's own sound could not be picked out (" + (lastErr.Length > 0 ? lastErr : "not running") + ") - recording the whole PC's sound instead"); }
            return why;
        }

        static readonly Dictionary<int, double> refused = new Dictionary<int, double>();
        static void AddNewTargets(List<Src> srcs)
        {
            Process[] all; try { all = Process.GetProcesses(); } catch { return; }
            foreach (Process p in all)
            {
                string n; try { n = p.ProcessName; } catch { continue; }
                string what = n.StartsWith("iRacingSim", StringComparison.OrdinalIgnoreCase) ? "iRacing" : n.StartsWith("CrewChief", StringComparison.OrdinalIgnoreCase) ? "CrewChief" : null;
                if (what == null) continue;
                bool have = false; foreach (Src x in srcs) if (x.Pid == p.Id) have = true;
                if (have) continue;
                double last; if (refused.TryGetValue(p.Id, out last) && WallMs() - last < 60000) continue;    // a program that refused: not again every 5 s (the wait would stall the writing)
                Src s = new Src(); s.Kind = "process"; s.Pid = p.Id; s.What = what;
                OpenProcess(s);
                if (s.Alive) srcs.Add(s); else refused[p.Id] = WallMs();
            }
        }

        static IntPtr Fmt16()
        {
            IntPtr f = Marshal.AllocHGlobal(18);
            Marshal.WriteInt16(f, 0, 1); Marshal.WriteInt16(f, 2, 2); Marshal.WriteInt32(f, 4, Rate); Marshal.WriteInt32(f, 8, Rate * 4);
            Marshal.WriteInt16(f, 12, 4); Marshal.WriteInt16(f, 14, 16); Marshal.WriteInt16(f, 16, 0);
            return f;
        }

        static string Hr(int hr) { return "0x" + hr.ToString("X8", Inv); }

        // one program and its children: Windows' process loopback (a virtual device; the real device and its settings are never touched)
        static string OpenProcess(Src s)
        {
            // Windows opens a capture for any number, even one no program has (it then just stays silent): check it is a real program first
            try { using (Process p = Process.GetProcessById(s.Pid)) { if (p.HasExited) return Fail(s, "program " + s.Pid + " has ended"); } }
            catch (ArgumentException) { return Fail(s, "program " + s.Pid + " is not running"); }
            catch { }
            IntPtr prm = Marshal.AllocHGlobal(12), pv = Marshal.AllocHGlobal(24), fmt = IntPtr.Zero;
            try
            {
                Marshal.WriteInt32(prm, 0, 1);              // AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
                Marshal.WriteInt32(prm, 4, s.Pid);
                Marshal.WriteInt32(prm, 8, 0);              // PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE
                for (int i = 0; i < 24; i++) Marshal.WriteByte(pv, i, 0);
                Marshal.WriteInt16(pv, 0, 65);              // VT_BLOB
                Marshal.WriteInt32(pv, 8, 12);
                Marshal.WriteIntPtr(pv, 8 + IntPtr.Size, prm);
                AudActivateDone h = new AudActivateDone(); IAudActivateOp op;
                int hr = ActivateAudioInterfaceAsync("VAD\\Process_Loopback", IID_IAudioClient, pv, h, out op);
                if (hr < 0 || op == null) return Fail(s, "process sound is not available on this Windows (" + Hr(hr) + ")");
                if (!h.Done.WaitOne(5000)) return Fail(s, "process sound did not answer in 5 s");
                int ahr; object o; hr = op.GetActivateResult(out ahr, out o);
                try { Marshal.ReleaseComObject(op); } catch { }
                if (hr < 0 || ahr < 0 || o == null) return Fail(s, "process sound refused (" + Hr(hr < 0 ? hr : ahr) + ")");
                IAudClient c = (IAudClient)o;
                fmt = Fmt16();
                uint fl = LOOPBACK | EVENTCALLBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY;
                hr = c.Initialize(0, fl, 10000000, 0, fmt, IntPtr.Zero);                     // 1 s of room: a busy moment on this BelowNormal thread loses nothing
                if (hr < 0) hr = c.Initialize(0, fl, 2000000, 0, fmt, IntPtr.Zero);
                if (hr < 0) { Release(c); return Fail(s, "process sound would not start (" + Hr(hr) + ")"); }
                s.Ev = new AutoResetEvent(false);
                c.SetEventHandle(s.Ev.SafeWaitHandle.DangerousGetHandle());
                return Finish(s, c, false, 2);
            }
            catch (Exception ex) { return Fail(s, ex.Message); }
            finally { Marshal.FreeHGlobal(prm); Marshal.FreeHGlobal(pv); if (fmt != IntPtr.Zero) Marshal.FreeHGlobal(fmt); }
        }

        // the whole PC: loopback of the default output device, shared mode (the fallback)
        static string OpenSystem(Src s)
        {
            IntPtr fmt = IntPtr.Zero, mix = IntPtr.Zero;
            try
            {
                IAudDeviceEnumerator en = (IAudDeviceEnumerator)new AudDeviceEnumerator(); IAudDevice dev;
                int hr = en.GetDefaultAudioEndpoint(0, 0, out dev);      // eRender, eConsole
                Release(en);
                if (hr < 0 || dev == null) return Fail(s, "no sound output device (" + Hr(hr) + ")");
                object o; Guid iid = IID_IAudioClient;
                hr = dev.Activate(ref iid, 23, IntPtr.Zero, out o);
                Release(dev);
                if (hr < 0 || o == null) return Fail(s, "the sound device refused (" + Hr(hr) + ")");
                IAudClient c = (IAudClient)o;
                fmt = Fmt16();
                hr = c.Initialize(0, LOOPBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY, 10000000, 0, fmt, IntPtr.Zero);
                if (hr >= 0) return Finish(s, c, false, 2);
                // older Windows: take the device's own format (float or 16-bit at 48 kHz) and convert here
                if (c.GetMixFormat(out mix) < 0 || mix == IntPtr.Zero) { Release(c); return Fail(s, "the sound device format is unknown (" + Hr(hr) + ")"); }
                int tag = (ushort)Marshal.ReadInt16(mix, 0), ch = Marshal.ReadInt16(mix, 2), rate = Marshal.ReadInt32(mix, 4), bits = Marshal.ReadInt16(mix, 14);
                if (tag == 0xFFFE) tag = Marshal.ReadInt32(mix, 24);
                bool isFloat = tag == 3 && bits == 32, isPcm = tag == 1 && bits == 16;
                if (rate != Rate || ch < 1 || !(isFloat || isPcm)) { Release(c); return Fail(s, "the sound device runs at " + rate + " Hz, " + bits + " bit - only 48 kHz is recorded"); }
                hr = c.Initialize(0, LOOPBACK, 10000000, 0, mix, IntPtr.Zero);
                if (hr < 0) { Release(c); return Fail(s, "the sound device would not start (" + Hr(hr) + ")"); }
                return Finish(s, c, isFloat, ch);
            }
            catch (Exception ex) { return Fail(s, ex.Message); }
            finally { if (fmt != IntPtr.Zero) Marshal.FreeHGlobal(fmt); if (mix != IntPtr.Zero) Marshal.FreeCoTaskMem(mix); }
        }

        static string Finish(Src s, IAudClient c, bool isFloat, int ch)
        {
            object svc; Guid iid = IID_IAudioCaptureClient;
            int hr = c.GetService(ref iid, out svc);
            if (hr < 0 || svc == null) { Release(c); return Fail(s, "no capture service (" + Hr(hr) + ")"); }
            hr = c.Start();
            if (hr < 0) { Release(svc); Release(c); return Fail(s, "the capture would not start (" + Hr(hr) + ")"); }
            s.Client = c; s.Cap = (IAudCaptureClient)svc; s.Float = isFloat; s.Ch = ch; s.Alive = true; s.Next = -1;
            return "";
        }

        static string Fail(Src s, string why) { s.Alive = false; s.RetryAt = WallMs() + 10000; if (s.DeadSince == 0) s.DeadSince = WallMs(); lastErr = why; return why; }

        static void Reopen(Src s)
        {
            Close(s);
            if (s.Kind == "process")
            {
                try { using (Process p = Process.GetProcessById(s.Pid)) { if (p.HasExited) { s.RetryAt = double.MaxValue; return; } } } catch { s.RetryAt = double.MaxValue; return; }   // the program has gone: nothing to come back to
                OpenProcess(s);
            }
            else if (s.Kind == "system") OpenSystem(s);
            if (s.Alive) { s.DeadSince = 0; Say("recorder: sound is back (" + s.What + ")"); }
        }

        static void Release(object o) { try { if (o != null) Marshal.ReleaseComObject(o); } catch { } }

        static void Close(Src s)
        {
            if (s.Client != null) { try { s.Client.Stop(); } catch { } }
            Release(s.Cap); Release(s.Client); s.Cap = null; s.Client = null;
            if (s.Ev != null) { try { s.Ev.Close(); } catch { } s.Ev = null; }
            if (s.Alive) { s.Alive = false; s.DeadSince = WallMs(); s.RetryAt = WallMs() + 3000; }
        }

        // the wall-clock time of a packet's first frame: Windows says when (QPC, 100 ns units); now minus its age
        static double PacketWall(ulong qpc, uint frames)
        {
            if (qpc != 0)
            {
                double age = (Qpc100() - qpc) / 10000.0;
                if (age > -20 && age < 3000) return WallMs() - age;
            }
            return WallMs() - frames / 48.0;
        }

        static void Drain(Src s)
        {
            if (s.Kind == "synth") { Synth(s); return; }
            for (int guard = 0; guard < 400; guard++)
            {
                uint n; int hr = s.Cap.GetNextPacketSize(out n);
                if (hr < 0) { lastErr = "the sound stream broke (" + Hr(hr) + ")"; Close(s); return; }
                if (n == 0) return;
                IntPtr data; uint frames, flags; ulong dp, qp;
                hr = s.Cap.GetBuffer(out data, out frames, out flags, out dp, out qp);
                if (hr < 0) { lastErr = "the sound stream broke (" + Hr(hr) + ")"; Close(s); return; }
                if (hr == 0x08890001 || frames == 0) { if (frames > 0) s.Cap.ReleaseBuffer(frames); return; }     // AUDCLNT_S_BUFFER_EMPTY
                double wall = PacketWall(qp, frames);
                if ((flags & 1) != 0) s.Next = -1;                                                     // a discontinuity: place the packet by its own time
                long idx = (long)Math.Round((wall - t0) * 48.0);
                if (s.Next >= 0 && Math.Abs(idx - s.Next) <= Resync) idx = s.Next;
                if ((flags & 2) == 0) Mix(s, data, (int)frames, idx);                                  // AUDCLNT_BUFFERFLAGS_SILENT: zeros, which the ring already holds
                s.Next = idx + frames; s.Frames += frames; runFrames += frames; runPackets++;
                s.Cap.ReleaseBuffer(frames);
            }
        }

        static void Mix(Src s, IntPtr data, int frames, long idx)
        {
            int n = frames * s.Ch;
            if (s.Float) { if (s.F32.Length < n) s.F32 = new float[n]; Marshal.Copy(data, s.F32, 0, n); }
            else { if (s.S16.Length < n) s.S16 = new short[n]; Marshal.Copy(data, s.S16, 0, n); }
            for (int f = 0; f < frames; f++)
            {
                long a = idx + f; if (a < flushed || a >= flushed + RingFrames) continue;      // too late for the file, or far ahead: dropped
                int r = (int)(a % RingFrames) * 2, k = f * s.Ch;
                int l, rr;
                if (s.Float) { l = (int)(Math.Max(-1f, Math.Min(1f, s.F32[k])) * 32767f); rr = s.Ch > 1 ? (int)(Math.Max(-1f, Math.Min(1f, s.F32[k + 1])) * 32767f) : l; }
                else { l = s.S16[k]; rr = s.Ch > 1 ? s.S16[k + 1] : l; }
                acc[r] += l; acc[r + 1] += rr;
            }
        }

        // test source: a 5 ms 1 kHz click at every whole wall-clock second, exactly in place (proves the alignment, not the device)
        static void Synth(Src s)
        {
            long upto = (long)Math.Floor((WallMs() - t0) * 48.0) - 480;
            if (s.Next < 0) s.Next = Math.Max(flushed, 0);
            for (long a = s.Next; a < upto; a++)
            {
                if (a < flushed || a >= flushed + RingFrames) continue;
                double w = t0 + a / 48.0, ms = w - Math.Floor(w / 1000.0) * 1000.0;
                if (ms < 5.0) { int v = (int)(20000 * Math.Sin(2 * Math.PI * ms)); int r = (int)(a % RingFrames) * 2; acc[r] += v; acc[r + 1] += v; }
            }
            if (upto > s.Next) { runFrames += upto - s.Next; runPackets++; s.Next = upto; }
        }

        static byte[] wbuf = new byte[4800 * 4];
        static void Flush(long target, bool alive)
        {
            while (flushed < target)
            {
                int n = (int)Math.Min(target - flushed, 4800);
                if (alive)
                {
                    for (int i = 0; i < n; i++)
                    {
                        int r = (int)((flushed + i) % RingFrames) * 2;
                        int l = acc[r], rr = acc[r + 1]; acc[r] = 0; acc[r + 1] = 0;
                        if (l > 32767) l = 32767; else if (l < -32768) l = -32768;
                        if (rr > 32767) rr = 32767; else if (rr < -32768) rr = -32768;
                        wbuf[i * 4] = (byte)l; wbuf[i * 4 + 1] = (byte)(l >> 8); wbuf[i * 4 + 2] = (byte)rr; wbuf[i * 4 + 3] = (byte)(rr >> 8);
                    }
                    Write(n);
                }
                else
                {
                    for (int i = 0; i < n; i++) { int r = (int)((flushed + i) % RingFrames) * 2; acc[r] = 0; acc[r + 1] = 0; }
                    CloseChunk();                      // nothing captures now: a hole, not silence
                }
                flushed += n;
            }
        }

        static void Write(int n)
        {
            if (cur == null)
            {
                AudChunk c = new AudChunk(); c.StartMs = t0 + flushed / 48.0; c.Open = true;
                c.Path = Path.Combine(DirOf(), "aud-" + ((long)Math.Round(c.StartMs * 1000.0)).ToString(Inv) + ".pcm");
                curFs = new FileStream(c.Path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                cur = c; lock (gate) chunks.Add(c);
            }
            curFs.Write(wbuf, 0, n * 4); curFs.Flush();
            lock (gate) cur.Frames += n;
            if (cur.Frames >= ChunkFrames) CloseChunk();
        }

        static string runDir = "";
        static string DirOf() { return runDir; }

        static void CloseChunk()
        {
            if (curFs != null) { try { curFs.Dispose(); } catch { } curFs = null; }
            if (cur != null) { lock (gate) cur.Open = false; cur = null; }
        }

        // ---------------- the chunks on disk ----------------
        public static List<AudChunk> Snapshot()
        {
            List<AudChunk> r = new List<AudChunk>();
            lock (gate) foreach (AudChunk c in chunks) { AudChunk x = new AudChunk(); x.Path = c.Path; x.StartMs = c.StartMs; x.Frames = c.Frames; x.Open = c.Open; r.Add(x); }
            r.Sort(delegate (AudChunk a, AudChunk b) { return a.StartMs.CompareTo(b.StartMs); });
            return r;
        }

        public static int Count { get { lock (gate) return chunks.Count; } }

        // closed chunks nobody needs any more go (needed = some video or job still covers that time)
        public static void Prune(Func<double, double, bool> needed, double olderThanMs)
        {
            List<AudChunk> gone = new List<AudChunk>();
            lock (gate)
            {
                foreach (AudChunk c in chunks) if (!c.Open && c.EndMs < olderThanMs && !needed(c.StartMs, c.EndMs)) gone.Add(c);
                foreach (AudChunk c in gone) chunks.Remove(c);
            }
            foreach (AudChunk c in gone) { try { File.Delete(c.Path); } catch { } }
        }

        // chunks an earlier irdash left behind (a crash or a deploy): known again by their names
        public static int Adopt(string dir)
        {
            int n = 0;
            try
            {
                if (!Directory.Exists(dir)) return 0;
                foreach (string f in Directory.GetFiles(dir, "aud-*.pcm"))
                {
                    Match m = Regex.Match(Path.GetFileName(f), "^aud-(\\d+)\\.pcm$"); if (!m.Success) continue;
                    long us; if (!long.TryParse(m.Groups[1].Value, NumberStyles.Integer, Inv, out us)) continue;
                    lock (gate)
                    {
                        bool have = false; foreach (AudChunk c in chunks) if (String.Equals(c.Path, f, StringComparison.OrdinalIgnoreCase)) have = true;
                        if (have) continue;
                        AudChunk x = new AudChunk(); x.Path = f; x.StartMs = us / 1000.0; x.Frames = new FileInfo(f).Length / 4; chunks.Add(x); n++;
                    }
                }
            }
            catch { }
            return n;
        }

        public static void ForgetMissing() { lock (gate) chunks.RemoveAll(delegate (AudChunk c) { return !c.Open && !File.Exists(c.Path); }); }

        // The sound for a file made of these wall-clock spans, one after the other (the same spans the video is made of): raw 48 kHz 16-bit
        // stereo, span i taking exactly round(end of span i) - round(start of span i) frames of the running total, so the sound can never
        // drift from the picture over a long file. Silence where no chunk covers the time. Returns the share of frames that were captured (0 = none).
        public static double BuildPcm(string path, double[] starts, double[] ends, out long total)
        {
            List<AudChunk> list = Snapshot();
            total = 0; long covered = 0; double cum = 0;
            byte[] buf = new byte[65536 * 4];
            using (FileStream o = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read))
            {
                for (int i = 0; i < starts.Length; i++)
                {
                    double len = Math.Max(0, ends[i] - starts[i]) / 1000.0;
                    long a = (long)Math.Round(cum * Rate); cum += len; long b = (long)Math.Round(cum * Rate), n = b - a;
                    for (long k = 0; k < n; k += 65536)
                    {
                        int m = (int)Math.Min(65536, n - k);
                        Array.Clear(buf, 0, m * 4);
                        covered += Fill(list, starts[i], k, m, buf);
                        o.Write(buf, 0, m * 4);
                    }
                    total += n;
                }
            }
            return total > 0 ? (double)covered / total : 0;
        }

        // frames [k, k+m) after wall time w0 into buf; returns how many came from a chunk
        static long Fill(List<AudChunk> list, double w0, long k, int m, byte[] buf)
        {
            long got = 0;
            double wa = w0 + k / 48.0, wb = wa + m / 48.0;
            foreach (AudChunk c in list)
            {
                if (c.EndMs <= wa || c.StartMs >= wb || c.Frames <= 0) continue;
                long first = (long)Math.Round((w0 - c.StartMs) * 48.0) + k;      // chunk frame that goes to buf frame 0
                long j0 = Math.Max(0, -first), j1 = Math.Min(m, c.Frames - first);
                if (j1 <= j0) continue;
                try
                {
                    using (FileStream f = new FileStream(c.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    {
                        f.Seek((first + j0) * 4, SeekOrigin.Begin);
                        int want = (int)((j1 - j0) * 4), off = (int)(j0 * 4), read = 0;
                        while (read < want) { int r = f.Read(buf, off + read, want - read); if (r <= 0) break; read += r; }
                        got += read / 4;
                    }
                }
                catch { }
            }
            return got;
        }

        public static string StatusJson()
        {
            return "{\"state\":\"" + State + "\",\"source\":\"" + Esc(source) + "\",\"error\":\"" + Esc(lastErr) + "\",\"chunks\":" + Count +
                   ",\"lastRun\":\"" + lastRunState + "\",\"lastSource\":\"" + Esc(lastRunSource) + "\",\"runFrames\":" + runFrames + ",\"runPackets\":" + runPackets + ",\"runStartMs\":" + runStartMs.ToString("0.000", Inv) + ",\"runEndMs\":" + runEndMs.ToString("0.000", Inv) + "}";
        }
        static string Esc(string s) { StringBuilder b = new StringBuilder(); foreach (char ch in s ?? "") { if (ch == '"' || ch == '\\') b.Append('\\').Append(ch); else if (ch < ' ') b.Append(' '); else b.Append(ch); } return b.ToString(); }
    }
}
