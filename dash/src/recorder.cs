// RECORDER (C-06 in docs\TASKS.md; the plain-English notes are in docs\vault.md): Paddock's own video of the middle race screen.
//   While the sim runs and he is in the car, irdash runs vault\bin\ffmpeg.exe hidden (BelowNormal, no window, no focus):
//   ddagrab of the middle screen -> h264_nvenc (libx264 only if NVENC will not start) -> rolling ~10 s MPEG-TS segments, the last ~3 min kept.
//   Every frame is stamped with the wall clock (setpts=RTCTIME), so a segment's start is an exact time and the start of a lap, which
//   telemetry gives as a wall-clock time too, is an exact place in the video.
//   At each lap end the lap is kept as a clip when it is the session's best clean lap so far, a personal best, or he pressed KEEP:
//   the segments are joined and cut WITHOUT re-encoding into vault\clips\rec-<lap start>-l<lap>.mp4 with a .json sidecar that says
//   where the lap starts inside the clip (lapStartOffset, seconds).
//   The race screens are rotated 180 degrees in Windows and ddagrab hands out the raw, upside-down picture. The clip carries the mp4
//   rotation flag instead of a CPU flip filter, so it plays upright in a browser at no cost.
//   Sound (recaudio.cs, docs\design\audio-recording.md): iRacing's and CrewChief's sound is captured beside the picture on the same wall clock,
//   in raw chunks next to the segments, and encoded (AAC) into every session file and clip as it is written; the picture is still never re-encoded.
//   irdash.ini:  recorder=1 turns it on (anything else, or no line, is off); recorder_audio=0 turns only the sound off. Nothing here touches iRacing's files.
//   Called from outside: Init / Start (irdash.cs), Keep (vault.cs KEEP key), ServeVideo / InfoJson / StatusJson / TestRoute (vault.cs routes).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    // ---------------- which capture output number is which monitor ----------------
    // ddagrab wants an output number (output_idx). Windows renumbers \\.\DISPLAYn, so DXGI is asked for each output's place on the desktop
    // and the middle race screen is found by POSITION.
    static class RecDxgi
    {
        public sealed class Out
        {
            public int Adapter, Index, L, T, W, H, Rotation; public bool Attached; public string Device = "", AdapterName = "";
            public int CX { get { return L + W / 2; } }
            public string Rect { get { return L + "," + T + " " + W + "x" + H; } }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct OUTDESC { [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName; public int L, T, R, B; public int Attached; public int Rotation; public IntPtr Monitor; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct ADESC { [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description; public uint Vendor, Device, SubSys, Rev; public UIntPtr Vram, Sysram, Shared; public long Luid; public uint Flags; }
        [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IFactory1 { void a(); void b(); void c(); void d(); void e(); void f(); void g(); void h(); void i(); [PreserveSig] int EnumAdapters1(uint n, out IAdapter1 ad); }
        [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAdapter1 { void a(); void b(); void c(); void d(); [PreserveSig] int EnumOutputs(uint n, out IOutput o); void GetDesc(); void CheckInterfaceSupport(); [PreserveSig] int GetDesc1(out ADESC d); }
        [ComImport, Guid("ae02eedb-c735-4690-8d52-5a8dc20213aa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IOutput { void a(); void b(); void c(); void d(); [PreserveSig] int GetDesc(out OUTDESC d); }
        [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IFactory1 f);

        // every output of every adapter, in the order DXGI (and so ddagrab) numbers them
        public static List<Out> All()
        {
            List<Out> r = new List<Out>();
            try
            {
                Guid g = new Guid("770aae78-f26f-4dba-a829-253c83d1b387"); IFactory1 f;
                if (CreateDXGIFactory1(ref g, out f) != 0) return r;
                for (uint ai = 0; ; ai++)
                {
                    IAdapter1 a; if (f.EnumAdapters1(ai, out a) != 0) break;
                    ADESC ad; string an = ""; if (a.GetDesc1(out ad) == 0) an = ad.Description;
                    for (uint oi = 0; ; oi++)
                    {
                        IOutput o; if (a.EnumOutputs(oi, out o) != 0) break;
                        OUTDESC d; if (o.GetDesc(out d) != 0) continue;
                        Out x = new Out(); x.Adapter = (int)ai; x.Index = (int)oi; x.L = d.L; x.T = d.T; x.W = d.R - d.L; x.H = d.B - d.T; x.Rotation = d.Rotation; x.Attached = d.Attached != 0; x.Device = d.DeviceName; x.AdapterName = an;
                        r.Add(x);
                    }
                }
            }
            catch (Exception ex) { Log.W("recorder: could not list the screens (" + ex.Message + ")"); }
            return r;
        }

        // The middle race screen: the same rule as Program.CentreScreen (the screen sitting above the rig is the dashboard, the middle of the
        // rest is the race screen), but on DXGI's own desktop coordinates. Null when there is nothing to pick.
        public static Out Middle(List<Out> all, out string why)
        {
            why = "";
            List<Out> a = new List<Out>();
            foreach (Out o in all) if (o.Attached && o.W > 0 && o.H > 0) a.Add(o);
            if (a.Count == 0) { why = "no screen is attached to the desktop"; return null; }
            if (a.Count >= 2)
            {
                Out top = a[0]; foreach (Out o in a) if (o.T < top.T) top = o;
                bool above = true; foreach (Out o in a) if (o != top && o.T < top.T + top.H) above = false;
                if (above) a.Remove(top);
            }
            a.Sort(delegate (Out x, Out y) { return x.CX.CompareTo(y.CX); });
            return a[a.Count / 2];
        }
    }

    // ffmpeg must never outlive irdash (a deploy kills irdash): a job object that kills its processes when the last handle closes
    static class RecJob
    {
        [StructLayout(LayoutKind.Sequential)] struct BASIC { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinWs, MaxWs; public uint ActiveLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] struct IOC { public ulong A, B, C, D, E, F; }
        [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IOC Io; public UIntPtr ProcMem, JobMem, PeakProc, PeakJob; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attr, string name);
        [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
        [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
        static IntPtr job = IntPtr.Zero; static bool tried;

        public static void Add(Process p)
        {
            try
            {
                if (!tried)
                {
                    tried = true;
                    job = CreateJobObject(IntPtr.Zero, null);
                    if (job != IntPtr.Zero)
                    {
                        EXT e = new EXT(); e.Basic.LimitFlags = 0x2000;      // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                        int len = Marshal.SizeOf(typeof(EXT)); IntPtr mem = Marshal.AllocHGlobal(len);
                        try { Marshal.StructureToPtr(e, mem, false); if (!SetInformationJobObject(job, 9, mem, (uint)len)) job = IntPtr.Zero; }
                        finally { Marshal.FreeHGlobal(mem); }
                    }
                }
                if (job != IntPtr.Zero) AssignProcessToJobObject(job, p.Handle);
            }
            catch { }
        }
    }

    sealed class RecSeg { public int Run, Rot; public string Name = "", Enc = ""; public double Start, End, FirstPts, BaseMs, NextProbeMs; public long Size; public bool Closed, ProbeBusy; public RecRun Owner; }
    sealed class RecRun { public int No, Rot, Read; public string List = "", Encoder = ""; public double BaseMs, StartMs; public bool FirstSeg, BlackDone, StuckSaid; public RecSess Sess; }
    sealed class RecCut { public RecLap Lap; public double S, E; public bool Started, Done; public string Result = ""; }

    // one lap seen live
    sealed class RecLap
    {
        public int N; public double Start, End, Time, Bar, SessionTime, OffMs, MaxPct;
        public bool Pit, Off, Dirty, Keep, Resolved, Ended, Queued, Joined;
        public string Car = "", Track = "", Config = "", Why = "";
    }

    // one clip on disk (the .json beside the .mp4)
    sealed class RecClip
    {
        public string Id = "", File = "", Car = "", Track = "", Config = "", Why = "", Encoder = "";
        public int Lap, Rotation; public double LapTime, LapStartMs, LapEndMs, ClipStartMs, LapStartOffset, LapEndOffset, VideoStart, Duration, SessionTime;
        public bool Keep, Pb, Truncated; public long Created, Size;
        public string Audio = "";      // ok | partial | none (no sound track), "" = a clip from before sound was recorded
        static string N(double d, string f) { return d.ToString(f, CultureInfo.InvariantCulture); }

        public string Json()
        {
            return "{\"id\":" + Json_.S(Id) + ",\"lap\":" + Lap + ",\"lapTime\":" + N(LapTime, "0.000") + ",\"lapStartMs\":" + N(Math.Round(LapStartMs), "0") + ",\"lapEndMs\":" + N(Math.Round(LapEndMs), "0") +
                   ",\"clipStartMs\":" + N(Math.Round(ClipStartMs), "0") + ",\"lapStartOffset\":" + N(LapStartOffset, "0.0000") + ",\"lapEndOffset\":" + N(LapEndOffset, "0.0000") + ",\"videoStart\":" + N(VideoStart, "0.0000") +
                   ",\"duration\":" + N(Duration, "0.000") + ",\"fps\":60,\"rotation\":" + Rotation + ",\"encoder\":" + Json_.S(Encoder) + ",\"car\":" + Json_.S(Car) + ",\"track\":" + Json_.S(Track) + ",\"config\":" + Json_.S(Config) +
                   ",\"sessionTime\":" + N(SessionTime, "0.000") + ",\"why\":" + Json_.S(Why) + ",\"keep\":" + (Keep ? "true" : "false") + ",\"pb\":" + (Pb ? "true" : "false") + ",\"truncated\":" + (Truncated ? "true" : "false") +
                   ",\"audio\":" + Json_.S(Audio) + ",\"created\":" + Created + ",\"size\":" + Size + "}";
        }

        static string S(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, CultureInfo.InvariantCulture) : ""; }
        static double D(Dictionary<string, object> d, string k) { object o; double v; return d.TryGetValue(k, out o) && o != null && double.TryParse(Convert.ToString(o, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : 0; }
        static bool B(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o is bool && (bool)o; }

        public static RecClip FromDict(Dictionary<string, object> d)
        {
            RecClip c = new RecClip();
            c.Id = S(d, "id"); c.Lap = (int)D(d, "lap"); c.LapTime = D(d, "lapTime"); c.LapStartMs = D(d, "lapStartMs"); c.LapEndMs = D(d, "lapEndMs"); c.ClipStartMs = D(d, "clipStartMs");
            c.LapStartOffset = D(d, "lapStartOffset"); c.LapEndOffset = D(d, "lapEndOffset"); c.VideoStart = D(d, "videoStart"); c.Duration = D(d, "duration"); c.Rotation = (int)D(d, "rotation"); c.Encoder = S(d, "encoder");
            c.Car = S(d, "car"); c.Track = S(d, "track"); c.Config = S(d, "config"); c.SessionTime = D(d, "sessionTime"); c.Why = S(d, "why"); c.Keep = B(d, "keep"); c.Pb = B(d, "pb"); c.Truncated = B(d, "truncated");
            c.Created = (long)D(d, "created"); c.Size = (long)D(d, "size"); c.Audio = S(d, "audio");
            return c;
        }
    }

    // one whole session (S1): every in-car stint of one iRacing session joined into one file. The .json beside the .mp4 (or, while open, the soon-to-be .mp4).
    sealed class RecSess
    {
        public string Id = "", Track = "", Config = "", Car = "", Type = "", Encoder = "";
        public double StartMs, EndMs; public int SessionNum = -99; public double UniqueId = -1;
        public bool Open = true, SaveWhenDone, Recovered, Saved, Saving, FinishQueued; public double RetryAfterMs;
        public long Bytes, Created; public double Duration;
        public List<RecSeg> Segs = new List<RecSeg>();
        public List<RecLap> Laps = new List<RecLap>();               // while open: the laps seen
        public List<double[]> LapRows = new List<double[]>();        // once written: {n, offset s, time, clean, pb, start wall ms (NaN if unknown)}
        public List<double[]> Incidents = new List<double[]>();     // {wall ms, points added} while open; {offset s, points} once written
        public int IncSeen = -1;
        public string File = "";
        // schema 2: holes where recorded segments went missing ({from, to} wall ms), how the length was measured, and a SAVE that could not happen yet
        public List<double[]> Gaps = new List<double[]>();
        public string DurationSource = "", SaveBlocked = "";
        public string State = "";    // "finalize-stalled" while a finish timed out waiting (overrides ready/partial)
        public double RecEndMs;     // wall clock of the last recorded picture (the review asks "was this lap driven while it ran?")
        public string Audio = "", AudioSource = "";   // ok | partial | none, and whose sound it is ("iRacing + CrewChief", "whole PC")
    }

    // S1: a clip cut around a rise in the player's incident count
    sealed class RecInc { public double At, S, E; public int Points; public string Sess = ""; public bool Ready, Done; public string Result = ""; }

    // ---------------- the recorder ----------------
    static class Recorder
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        static readonly object gate = new object();
        static bool enabled, testOn, started, noPrecise;
        static string source = "screen";                       // "screen" (ddagrab) or "test" (a made-up picture, sandbox only)
        static Thread loop, worker;

        // the free-space rule and the sandbox knobs (a test may change the knobs, nobody else)
        const double MinFreeGb = 50;
        static int keepOverrideSec, segSecs = 10, graceSecs = 20; static double minLap = 15, testBar; static bool testBlack; static long freeOverride = -1;

        // the ffmpeg run
        static Process ff; static RecRun run; static int runNo; static bool expectStop; static double stopAskedMs, inCarSince, outSince, nextStartMs, lastNoteMs;
        static int restarts; static bool gaveUp, fellBack; static string encoder = "hevc_nvenc";    // HEVC halves the file; h264_nvenc, then libx264, if the chip refuses
        static readonly List<string> errLines = new List<string>();
        static string note = "", lastErr = ""; static bool black, blackChecked; static int outIdx = -1, outAdapter, outRot; static string outRect = "";
        // the sound (recaudio.cs): "auto" = iRacing + CrewChief; recorder_audio=0 in irdash.ini is the lead's off switch. A test picks its own (off by default).
        static string audioMode = "auto", testAudio = "off";

        // what is on disk and what is wanted
        static readonly List<RecSeg> segs = new List<RecSeg>(); static readonly List<RecClip> clips = new List<RecClip>(); static readonly List<RecCut> cuts = new List<RecCut>();
        static int probing, busy; static readonly Queue<ThreadStart> work = new Queue<ThreadStart>();
        static string lastCutArgs = "", lastRunArgs = "";

        // S1 whole-session video: one file per iRacing session, kept by rules, SAVE keeps one forever
        // the last 8 sessions / 60 GB: 3 / 30 GB threw away the video of his last outing within a day (2026-10-18: the 08:36 qualifying, the HOME REVIEW session, was gone by evening) with 340 GB free
        const double RecentBudgetGb = 60, SavedBudgetGb = 150, MinFreeGbSession = 50;
        static readonly List<RecSess> sessions = new List<RecSess>();     // finished sessions (on disk), newest last
        static RecSess openSess;                                          // the session being recorded now
        static readonly List<RecSess> finishing = new List<RecSess>();
        static long savedReserved;
        static readonly List<RecInc> incCuts = new List<RecInc>();
        static int keepSessions = 8; static long recentBudgetBytes = -1, savedBudgetBytes = -1;
        static bool diskPaused; static double lastSessHk; static string recState = "";

        // the laps
        static RecLap cur, pendLap; static readonly List<RecLap> recent = new List<RecLap>(); static double lastPct = -1, lastCt = -1, lastLastTime, pendBefore, sessionBest, longestLap, lastTrackMs; static int sessNum = -99;
        static bool haveConn; static int yamlVer = -1; static Combo.Info combo = new Combo.Info(); static double lastHk, lastHookCheck;

        // ---------------- where things are ----------------
        static string VaultRoot { get { return Vault.Root ?? Path.Combine(Program.RootDir, "vault"); } }
        static string RecDir { get { return Path.Combine(VaultRoot, "rec"); } }

        // A SAVE press must outlive a restart: a tiny marker next to the segments (temp + move, like the sidecars).
        static string WishPath(string id)
        {
            string safe = id ?? ""; foreach (char c in Path.GetInvalidFileNameChars()) safe = safe.Replace(c, '_');
            return Path.Combine(RecDir, "save-" + safe + ".wish");
        }
        static void WriteWish(string id)
        {
            try
            {
                Directory.CreateDirectory(RecDir); string f = WishPath(id), t = f + ".tmp";
                File.WriteAllText(t, id ?? "", new UTF8Encoding(false));
                if (File.Exists(f)) File.Delete(f);
                File.Move(t, f);
            }
            catch (Exception ex) { Log.W("recorder: could not remember the SAVE of session " + id + " across a restart (" + ex.Message + ")"); }
        }
        static string ClipDir { get { return Path.Combine(VaultRoot, "clips"); } }
        static string SessDir { get { return Path.Combine(VaultRoot, "sessions"); } }
        static string SavedDir { get { return Path.Combine(VaultRoot, "saved"); } }
        static string FfmpegPath { get { return Path.Combine(Program.RootDir, @"vault\bin\ffmpeg.exe"); } }
        static string FfprobePath { get { return Path.Combine(Program.RootDir, @"vault\bin\ffprobe.exe"); } }
        public static bool Enabled { get { return enabled; } }

        [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long ft);
        // wall clock in ms since 1970 (UTC), microsecond-precise: DateTime.UtcNow only moves in 1 to 15 ms steps
        public static double WallMs()
        {
            if (!noPrecise) { try { long ft; GetSystemTimePreciseAsFileTime(out ft); return (ft - 116444736000000000L) / 10000.0; } catch { noPrecise = true; } }
            return (DateTime.UtcNow - Epoch).TotalMilliseconds;
        }
        static string Stamp(double ms) { return Epoch.AddMilliseconds(ms).ToString("yyyyMMdd-HHmmss", Inv); }
        static string N3(double d) { return d.ToString("0.000", Inv); }
        static string Lap(double t) { return PbRef.Lap(t); }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetDiskFreeSpaceEx(string dir, out ulong avail, out ulong total, out ulong free);
        static long FreeBytes(string path)
        {
            if (freeOverride >= 0) return freeOverride;
            try { ulong a, t, f; string root = Path.GetPathRoot(Path.GetFullPath(path)); if (GetDiskFreeSpaceEx(root, out a, out t, out f)) return (long)a; } catch { }
            return long.MaxValue;
        }

        // ---------------- start ----------------
        // recorder=1 in irdash.ini is the only ON; anything else, including a missing line, is off
        public static bool ParseSwitch(string iniText)
        {
            bool on = false;
            foreach (string raw in (iniText ?? "").Split('\n'))
            {
                string l = raw.Trim(); if (l.Length == 0 || l.StartsWith(";") || l.StartsWith("#")) continue;
                int e = l.IndexOf('='); if (e <= 0) continue;
                if (l.Substring(0, e).Trim().ToLowerInvariant() == "recorder") on = l.Substring(e + 1).Trim() == "1";
            }
            return on;
        }

        // recorder_audio=0 switches the sound off (no line = on: nothing for Peter to set)
        public static bool ParseAudioSwitch(string iniText)
        {
            bool on = true;
            foreach (string raw in (iniText ?? "").Split('\n'))
            {
                string l = raw.Trim(); if (l.Length == 0 || l.StartsWith(";") || l.StartsWith("#")) continue;
                int e = l.IndexOf('='); if (e <= 0) continue;
                if (l.Substring(0, e).Trim().ToLowerInvariant() == "recorder_audio") on = l.Substring(e + 1).Trim() != "0";
            }
            return on;
        }

        public static void Init(string rootDir)
        {
            RecAudio.Say = delegate (string m) { Log.W(m); };
            try { if (Program.IniFile != null && File.Exists(Program.IniFile)) { string t = File.ReadAllText(Program.IniFile); enabled = ParseSwitch(t); audioMode = ParseAudioSwitch(t) ? "auto" : "off"; } } catch (Exception ex) { Log.W("recorder: irdash.ini: " + ex.Message); }
            LoadClips();       // clips already made are served even while the recorder is off
            LoadSessions();
        }

        public static void Start()
        {
            if (!enabled) { Log.W("recorder: switched off (recorder=0 in irdash.ini)"); note = "off"; return; }
            if (!File.Exists(FfmpegPath)) { note = "ffmpeg is missing (vault\\bin\\ffmpeg.exe)"; Log.W("recorder: " + note); return; }
            bool leftoversSaved = FinishLeftovers(); // Keep the only copy when recovery cannot finish.
            if (leftoversSaved) WipeRecDir();
            Log.W("recorder: on - records the middle race screen while you are in the car (ffmpeg, " + encoder + ", 60 fps, one file per session; sound " + (audioMode == "off" ? "off (recorder_audio=0)" : "from iRacing and CrewChief") + ")");
            EnsureLoop();
        }

        static void EnsureLoop()
        {
            lock (gate)
            {
                if (started) return; started = true;
                AppDomain.CurrentDomain.ProcessExit += delegate { try { if (ff != null && !ff.HasExited) ff.Kill(); } catch { } };
                loop = new Thread(Loop); loop.IsBackground = true; loop.Priority = ThreadPriority.BelowNormal; loop.Name = "RecorderLoop"; loop.Start();
                worker = new Thread(WorkerLoop); worker.IsBackground = true; worker.Priority = ThreadPriority.BelowNormal; worker.Name = "RecorderWork"; worker.Start();
            }
        }

        static void WipeRecDir()
        {
            // segments of an earlier irdash cannot be used (the index died with it)
            try { if (Directory.Exists(RecDir)) foreach (string f in Directory.GetFiles(RecDir)) { if (String.Equals(Path.GetExtension(f), ".ts", StringComparison.OrdinalIgnoreCase)) continue; try { File.Delete(f); } catch { } } } catch { }
            RecAudio.ForgetMissing();
        }

        // ---------------- the loop: frames in, laps out, ffmpeg up and down ----------------
        static void Loop()
        {
            long lastSeq = -1;
            while (true)
            {
                try
                {
                    Frame f = Sdk.WaitNext(lastSeq, 250);
                    bool fresh = f.Seq != lastSeq; lastSeq = f.Seq;
                    double now = WallMs();
                    CheckTest(now);
                    if (enabled || testOn)
                    {
                        if (fresh) TrackLaps(f, now);
                        if (fresh) SessionTick(f, now);
                        Lifecycle(f, now);
                    }
                    else if (ff != null) { AskStop("the recorder was switched off", now); Lifecycle(f, now); }
                    Housekeeping(now);
                }
                catch (Exception ex) { Log.W("recorder: " + ex.Message); Thread.Sleep(200); }
            }
        }

        // a test that ends (or whose hook file goes away, or a real sim that starts) must not leave its pretend recorder running
        static void CheckTest(double now)
        {
            if (!testOn || now - lastHookCheck < 2000) return;
            lastHookCheck = now;
            if (!Vault.SandboxOn || !Sdk.TestHook) { Log.W("recorder: the test is over - the pretend recorder stops"); TestOff(); }
        }

        static bool ShouldRecord(Frame f)
        {
            if (!(enabled || testOn) || !f.Connected) return false;
            if (f.Num("IsOnTrack") == 0 || f.Num("IsReplayPlaying") != 0) return false;
            return testOn || !Sdk.Pretend;        // a pretend session never films the real screen, unless a test asked for exactly that (the real-screen section of tests\recorder-test.ps1)
        }

        static void Lifecycle(Frame f, double now)
        {
            bool want = ShouldRecord(f);
            if (want) { outSince = 0; if (inCarSince == 0) inCarSince = now; }
            else { inCarSince = 0; if (outSince == 0) outSince = now; }
            if (ff != null)
            {
                bool exited; try { exited = ff.HasExited; } catch { exited = true; }
                if (exited) { OnExit(now); return; }
                if (expectStop) { if (now - stopAskedMs > 8000) { Log.W("recorder: ffmpeg did not stop by itself - ended it"); try { ff.Kill(); } catch { } } return; }
                if (!want && (!f.Connected || now - outSince >= graceSecs * 1000.0)) AskStop(f.Connected ? "left the car" : "the sim closed", now);
                return;
            }
            if (!want || gaveUp || diskPaused || now < nextStartMs || now - inCarSince < 1000) return;
            StartFfmpeg(now);
        }

        static void AskStop(string why, double now)
        {
            if (ff == null || expectStop) return;
            // A session identity can settle a few frames after capture starts. Keep the encoder alive long enough to emit packets.
            if (why != "the sim closed" && run != null && now - run.StartMs < 5000) return;
            expectStop = true; stopAskedMs = now;
            Log.W("recorder: stopping (" + why + ")");
            try { ff.StandardInput.WriteLine("q"); ff.StandardInput.Flush(); } catch { try { ff.Kill(); } catch { } }
        }

        static void OnExit(double now)
        {
            int code = -1; try { code = ff.ExitCode; } catch { }
            string tail = "", all; lock (errLines) { all = string.Join(" | ", errLines.ToArray()); if (errLines.Count > 0) tail = errLines[errLines.Count - 1]; }
            double lived = now - run.StartMs; bool asked = expectStop;
            RecAudio.Stop();                  // the sound ends with the picture (its last chunk is closed before anyone joins the session)
            try { ff.Dispose(); } catch { }
            ff = null; expectStop = false;
            ReadList(run);                    // the last segment is closed on a clean stop
            QueueFinishing();
            if (asked) { Log.W("recorder: stopped"); return; }
            if (lived < 12000 && run.Encoder.EndsWith("_nvenc") && !fellBack && source == "screen" && Regex.IsMatch(all, "nvenc|cuda|No capable devices|OpenEncodeSession|Cannot load", RegexOptions.IgnoreCase))
            {
                // hevc_nvenc -> h264_nvenc -> libx264
                if (encoder == "hevc_nvenc") { encoder = "h264_nvenc"; Log.W("recorder: the HEVC encoder would not start (" + tail + ") - trying h264_nvenc"); }
                else { encoder = "libx264"; fellBack = true; Log.W("recorder: the NVIDIA encoder would not start (" + tail + ") - using the CPU encoder (libx264) instead"); }
                nextStartMs = now + 500;
                return;
            }
            restarts++; lastErr = tail;
            if (restarts > 3)
            {
                gaveUp = true; note = "ffmpeg keeps stopping; no more recording this session";
                Log.W("recorder: ffmpeg keeps stopping (exit " + code + ") - giving up until the next session. Last message: " + tail);
                return;
            }
            Log.W("recorder: ffmpeg stopped by itself (exit " + code + " after " + (lived / 1000).ToString("0", Inv) + " s: " + tail + ") - starting it again, restart " + restarts + " of 3");
            nextStartMs = now + 2000;
        }

        static void StartFfmpeg(double now)
        {
            string exe = FfmpegPath;
            if (!File.Exists(exe)) { gaveUp = true; note = "ffmpeg is missing (vault\\bin\\ffmpeg.exe)"; Log.W("recorder: " + note); return; }
            try { Directory.CreateDirectory(RecDir); } catch { }
            int idx = 0, adapter = 0, rot = 3; string enc = source == "test" ? "libx264" : encoder;
            if (source == "screen")
            {
                string why; RecDxgi.Out mid = RecDxgi.Middle(RecDxgi.All(), out why);
                if (mid == null)
                {
                    nextStartMs = now + 15000; note = "could not find the middle screen (" + why + ")";
                    if (now - lastNoteMs > 120000) { lastNoteMs = now; Log.W("recorder: " + note); }
                    return;
                }
                idx = mid.Index; adapter = mid.Adapter; rot = mid.Rotation; outIdx = idx; outAdapter = adapter; outRot = rot; outRect = mid.Rect;
            }
            RecRun r = new RecRun(); r.No = ++runNo; r.BaseMs = Math.Floor(WallMs() / 1000.0) * 1000.0; r.Rot = rot; r.Encoder = enc;
            r.List = Path.Combine(RecDir, "list-" + r.No + ".csv"); r.StartMs = now; r.Sess = openSess;
            string args = BuildArgs(r, idx, adapter, enc); lastRunArgs = args;
            ProcessStartInfo psi = new ProcessStartInfo(exe, args);
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardInput = true; psi.RedirectStandardError = true; psi.RedirectStandardOutput = true; psi.WorkingDirectory = RecDir;
            lock (errLines) errLines.Clear();
            Process p = Process.Start(psi);
            try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
            RecJob.Add(p);
            p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) lock (errLines) { errLines.Add(e.Data); if (errLines.Count > 30) errLines.RemoveAt(0); } };
            p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e) { };
            p.BeginErrorReadLine(); p.BeginOutputReadLine();
            ff = p; run = r; expectStop = false; blackChecked = false; black = false; note = "";
            // the sound runs exactly while the picture does: same start, same stop (OnExit), same gaps
            try { RecAudio.Start(RecDir, testOn ? testAudio : audioMode); } catch (Exception ex) { Log.W("recorder: sound: " + ex.Message); }
            Log.W("recorder: started ffmpeg #" + r.No + " (" + enc + (source == "screen" ? ", screen output " + idx + " at " + outRect + ", picture turned " + (rot == 3 ? "180" : rot == 2 ? "90" : rot == 4 ? "270" : "0") + " degrees by the video's rotation flag" : ", test picture") + ")");
        }

        // the real command line. The wall clock goes in as the frame time (setpts=RTCTIME): a frame's time in the file is then its capture time
        // minus the run's base, to the microsecond (ffmpeg keeps it because the encoder time base is 1/1000000)
        static string BuildArgs(RecRun r, int idx, int adapter, string enc)
        {
            string baseUs = ((long)(r.BaseMs * 1000.0)).ToString(Inv);
            string stamp = "settb=1/1000000,setpts=RTCTIME-" + baseUs;
            string fc, hw = "";
            if (source == "test")
            {
                // a made-up screen that is already upside down like ddagrab's: the picture, a 32-block binary clock (milliseconds since the run's base,
                // read back by the test) and a readable clock, then flipped both ways
                string pic = testBlack ? "color=c=black:size=1280x720:rate=60" : "testsrc2=size=1280x720:rate=60";
                fc = pic + ",realtime," + stamp;
                if (!testBlack)
                    fc += ",split=2[a][b];[b]crop=640:32:0:0,format=yuv420p,geq=lum='255*mod(floor(floor(T*1000)/pow(2,floor(X/20))),2)':cb=128:cr=128[c];[a][c]overlay=0:0,drawtext=fontfile='C\\:/Windows/Fonts/arial.ttf':text='%{pts\\:hms}':x=10:y=60:fontsize=48:fontcolor=white:box=1:boxcolor=black@0.7";
                fc += ",hflip,vflip";
            }
            else
            {
                bool nvenc = enc.EndsWith("_nvenc");      // any NVIDIA encoder keeps ddagrab's frames on the GPU (no hwdownload)
                fc = "ddagrab=output_idx=" + idx + ":framerate=60:draw_mouse=0" + (nvenc ? "" : ",hwdownload,format=bgra") + "," + stamp;
                if (adapter != 0) hw = "-init_hw_device d3d11va=dda:" + adapter + " -filter_hw_device dda ";
            }
            string venc;
            if (enc == "hevc_nvenc") venc = "-c:v hevc_nvenc -preset p4 -rc vbr -b:v 8M -maxrate 12M -bufsize 16M -forced-idr 1";
            else if (enc == "h264_nvenc") venc = "-c:v h264_nvenc -preset p4 -profile:v high -rc vbr -b:v 16M -maxrate 20M -bufsize 32M -forced-idr 1";
            else venc = "-c:v libx264 -preset " + (source == "test" ? "ultrafast" : "veryfast") + " -pix_fmt yuv420p -b:v " + (source == "test" ? "4M -maxrate 6M -bufsize 8M" : "16M -maxrate 20M -bufsize 32M");
            return "-hide_banner -y -loglevel error " + hw + "-filter_complex \"" + fc + "\" " + venc +
                   " -g 60 -bf 0 -force_key_frames expr:gte(t,n_forced*1) -enc_time_base 1/1000000 -fps_mode passthrough -muxdelay 0 -muxpreload 0" +
                   " -f segment -segment_time " + (segSecs - 0.1).ToString("0.0", Inv) + " -segment_format mpegts -segment_format_options mpegts_copyts=1 -reset_timestamps 0" +
                   " -segment_list \"" + r.List + "\" -segment_list_type csv \"" + Path.Combine(RecDir, "r" + r.No + "-%05d.ts") + "\"";
        }

        // ---------------- laps from live telemetry ----------------
        static Combo.Info ComboNow(Frame f)
        {
            if (f.SessionVersion != yamlVer && f.SessionYaml.Length > 0) { yamlVer = f.SessionVersion; try { combo = Combo.FromYaml(f.SessionYaml); } catch { } }
            return combo;
        }

        static void ResetTracker()
        {
            cur = null; lastPct = -1; lastCt = -1; sessionBest = 0; pendLap = null; longestLap = 0; lastTrackMs = 0;
            lock (gate) recent.Clear();
        }

        static double KnownBar()
        {
            if (testOn && testBar > 0) return testBar;
            double bar = 0;
            try { RefData r = PbRef.Current; if (r != null && r.Time > 0) bar = r.Time; double kb = PbRef.KnownBest; if (kb > 0 && (bar == 0 || kb < bar)) bar = kb; } catch { }
            return bar;
        }

        static RecLap StartLap(int n, double startMs, bool dirty, Frame f)
        {
            RecLap l = new RecLap(); l.N = n; l.Start = startMs; l.Dirty = dirty; l.SessionTime = f.Num("SessionTime");
            Combo.Info ci = ComboNow(f); l.Car = ci.Car; l.Track = ci.Track; l.Config = ci.Config;
            return l;
        }

        static void TrackLaps(Frame f, double now)
        {
            if (!f.Connected)
            {
                if (haveConn) { haveConn = false; if (pendLap != null) ResolveLap(pendLap, 0, true); ResetTracker(); restarts = 0; gaveUp = false; fellBack = false; }
                return;
            }
            if (!haveConn) { haveConn = true; ResetTracker(); restarts = 0; gaveUp = false; }
            double llt = f.Num("LapLastLapTime"), prevLlt = lastLastTime;
            if (pendLap != null)
            {
                // the lap time is announced up to ~1.5 s after the line
                if (Math.Abs(llt - pendBefore) > 0.0005 && llt > 1) ResolveLap(pendLap, llt, false);
                else if (now - pendLap.End > 3000) ResolveLap(pendLap, 0, true);
            }
            lastLastTime = llt;
            int sess = (int)f.Num("SessionNum");
            if (sess != sessNum) { if (sessNum != -99) { if (pendLap != null) ResolveLap(pendLap, 0, true); ResetTracker(); } sessNum = sess; }
            bool onTrack = f.Num("IsOnTrack") != 0 && f.Num("IsReplayPlaying") == 0;
            if (!onTrack) { if (cur != null) cur.Dirty = true; cur = null; lastPct = -1; lastCt = -1; lastTrackMs = 0; return; }

            int lap = (int)f.Num("Lap"); double pct = f.Num("LapDistPct"), ct = f.Num("LapCurrentLapTime");
            bool pit = f.Num("OnPitRoad") != 0; int surf = (int)f.Num("PlayerTrackSurface");
            double sinceLine = (ct >= 0 && ct < 1500) ? ct * 1000.0 : 0;
            double dt = lastTrackMs > 0 ? now - lastTrackMs : 0;        // time since the last frame looked at: long after a hitch in the sim or a busy moment here
            bool crossed = false;
            if (cur == null)
            {
                // joined a lap part-way (or just got in): it is no fair lap, the next one is
                bool partial = !(pct >= 0 && pct < 0.05 && ct < 3); cur = StartLap(lap, now - sinceLine, partial, f); cur.Joined = partial;
            }
            else if (lap != cur.N)
            {
                if (lap == cur.N + 1)
                {
                    // The sim counts a lap up only at the line, so +1 is the line, however long ago the last frame was (a frame gap before the line once made
                    // this lap vanish without a word). LapCurrentLapTime counts from the line, so the crossing is "now minus that"; the timer can still
                    // show the last lap for one frame. A lap that never got past the middle was not driven over the line (a tow, a reset): not a fair lap.
                    double boundary = (ct >= 0 && ct < 1.0) ? now - ct * 1000.0 : now - 8;
                    if (cur.MaxPct < 0.5) cur.Dirty = true;
                    FinishLap(cur, boundary, f, prevLlt);
                    cur = StartLap(lap, boundary, false, f); cur.Pit = pit; crossed = true;
                }
                else
                {
                    Log.W("recorder: lap " + cur.N + " dropped (the lap counter went from " + cur.N + " to " + lap + ", that is not a line crossing)");
                    cur.Dirty = true; cur = StartLap(lap, now - sinceLine, true, f);
                }
            }
            if (pit) cur.Pit = true;
            if (surf == 0 && lastTrackMs > 0) { cur.OffMs += Math.Min(now - lastTrackMs, 200); if (cur.OffMs >= 750) cur.Off = true; }   // off the track for 0.75 s or more, as the Vault reads a file (counted in time, not frames)
            lastTrackMs = now;
            if (!crossed && pct > cur.MaxPct) cur.MaxPct = pct;
            if (lastPct >= 0 && !crossed)
            {
                // A jump in lap distance means a tow or a reset: the car moved further than the lap timer says there was time for. The timer keeps
                // running through a tow, so it is the yardstick (a hitch in the telemetry moves both, a tow moves only the distance). 0.15 of a lap
                // a second is faster than any car here (a 10 s lap is 0.1).
                double span = (lastCt >= 0 && ct >= lastCt) ? Math.Min(ct - lastCt, 30.0) : Math.Min(dt, 3000.0) / 1000.0;
                double dp = pct - lastPct;
                if ((dp < -0.02 && !(lastPct > 0.9 && pct < 0.1)) || dp > 0.1 + span * 0.15) cur.Dirty = true;
            }
            lastPct = pct; lastCt = ct;
        }

        static void FinishLap(RecLap l, double endMs, Frame f, double lltBefore)
        {
            if (pendLap != null) ResolveLap(pendLap, 0, true);
            l.End = endMs; l.Ended = true; l.Bar = KnownBar();           // the bar before this lap can change it
            if (l.Car.Length == 0) { Combo.Info ci = ComboNow(f); l.Car = ci.Car; l.Track = ci.Track; l.Config = ci.Config; }
            pendLap = l; pendBefore = lltBefore;
        }

        static void ResolveLap(RecLap l, double official, bool computed)
        {
            if (pendLap == l) pendLap = null;
            l.Time = (!computed && official > 1) ? official : (l.End - l.Start) / 1000.0;
            l.Resolved = true;
            lock (gate) { recent.Add(l); if (recent.Count > 12) recent.RemoveAt(0); if (openSess != null && !openSess.Laps.Contains(l)) openSess.Laps.Add(l); }
            if (l.Time > longestLap) longestLap = l.Time;
            Decide(l);
        }

        // the lap is over: is it worth a clip?
        static void Decide(RecLap l)
        {
            bool valid = l.Time > minLap && !l.Pit && !l.Off && !l.Dirty;
            bool pb = valid && l.Bar > 0 && l.Time < l.Bar - 0.0005;
            bool best = valid && (sessionBest <= 0 || l.Time < sessionBest - 0.0005);
            if (valid && (sessionBest <= 0 || l.Time < sessionBest)) sessionBest = l.Time;
            l.Why = l.Keep ? "keep" : pb ? "pb" : best ? "best" : "";
            string what = "lap " + l.N + " " + Lap(l.Time) + " (from " + Epoch.AddMilliseconds(l.Start).ToLocalTime().ToString("HH:mm:ss.fff", Inv) + ")" + (valid ? " clean" : " not clean (" + (l.Pit ? "pits" : l.Off ? "off track" : l.Joined ? "joined part-way" : l.Dirty ? "reset or tow" : "too short") + ")");
            if (l.Why.Length == 0) { Log.W("recorder: " + what + " - no clip (not a session best, not a personal best)"); return; }
            Log.W("recorder: " + what + " - " + (l.Why == "pb" ? "a personal best" : l.Why == "keep" ? "kept (KEEP key)" : "the session's best so far") + ", cutting its clip");
            QueueCut(l);
        }

        static void QueueCut(RecLap l)
        {
            lock (gate)
            {
                if (l.Queued) return; l.Queued = true;
                RecCut c = new RecCut(); c.Lap = l; c.S = l.Start - 1000; c.E = l.End + 1000; cuts.Add(c);
            }
        }

        // the KEEP key: this lap's clip is kept for good (the same lap the Vault marks)
        public static bool Keep(int lapN)
        {
            if (!(enabled || testOn)) return false;
            RecLap l = null; string clipId = "";
            lock (gate)
            {
                if (cur != null && cur.N == lapN) l = cur;
                else if (pendLap != null && pendLap.N == lapN) l = pendLap;
                else for (int i = recent.Count - 1; i >= 0; i--) if (recent[i].N == lapN) { l = recent[i]; break; }
                if (l != null && l.Queued) clipId = ClipId(l);
            }
            if (l == null) { Log.W("recorder: KEEP for lap " + lapN + ", but the recorder has not seen that lap - no clip"); return false; }
            l.Keep = true;
            if (l.Resolved && !l.Queued) { l.Why = "keep"; Log.W("recorder: lap " + l.N + " kept (KEEP key), cutting its clip"); QueueCut(l); }
            else if (clipId.Length > 0)
            {
                RecClip c; lock (gate) c = FindClip(clipId);
                if (c != null && !c.Keep) { c.Keep = true; SaveSidecar(c); Log.W("recorder: the clip of lap " + l.N + " is now kept for good (KEEP key)"); }
            }
            return true;
        }

        // ---------------- housekeeping: new segments, cuts that are ready, the 3-minute window ----------------
        static void Housekeeping(double now)
        {
            if (now - lastHk < 400) return; lastHk = now;
            RecRun r = run;
            if (r != null) ReadList(r);
            RetryProbes(now);
            ResolveCuts(now);
            ResolveIncidents(now);
            PruneSegs(now);
            if (now - lastAudPrune > 2000) { lastAudPrune = now; PruneAudio(now); }
            if (ff == null) QueueFinishing();
            if (now - lastSessHk > 5000) { lastSessHk = now; try { RetainSessions(); } catch { } }
            if (r != null && ff != null && !r.FirstSeg && !r.StuckSaid && now - r.StartMs > 30000)
            {
                r.StuckSaid = true; black = true; note = "no picture came from the screen";
                Log.W("recorder: no video came out of the screen in 30 s. The display may be asleep, or iRacing is in full-screen exclusive mode, which cannot be recorded. Choose Windowed or Borderless in iRacing.");
            }
        }

        static void ReadList(RecRun r)
        {
            string text;
            try
            {
                using (FileStream fs = new FileStream(r.List, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (StreamReader sr = new StreamReader(fs)) text = sr.ReadToEnd();
            }
            catch { return; }
            int nl = text.LastIndexOf('\n'); if (nl < 0) return;
            string[] lines = text.Substring(0, nl).Split('\n');
            for (int i = r.Read; i < lines.Length; i++)
            {
                r.Read = i + 1; string ln = lines[i].Trim(); if (ln.Length == 0) continue;
                string[] c = ln.Split(','); double end;
                if (c.Length < 3 || !double.TryParse(c[2], NumberStyles.Float, Inv, out end)) continue;
                RecSeg s = new RecSeg(); s.Run = r.No; s.Name = c[0]; s.BaseMs = r.BaseMs; s.Rot = r.Rot; s.Enc = r.Encoder; s.End = r.BaseMs + end * 1000.0; s.Owner = r; s.ProbeBusy = true;
                lock (gate) { segs.Add(s); probing++; if (r.Sess != null && !r.Sess.Segs.Contains(s)) r.Sess.Segs.Add(s); }
                RecSeg sc = s; Enqueue(delegate { ProbeSeg(sc, r); });
            }
        }

        // the first frame time inside the segment is its exact start; the file is named by it (UTC) and counted as closed
        static void ProbeSeg(RecSeg s, RecRun r)
        {
            string path = Path.Combine(RecDir, s.Name);
            try
            {
                string o, e; int rc = RunTool(FfprobePath, "-v error -select_streams v:0 -read_intervals %+#1 -show_entries packet=pts_time -of csv=p=0 \"" + path + "\"", null, 20000, out o, out e);
                double first;
                if (rc != 0 || !double.TryParse((o ?? "").Trim().Split('\n')[0].Trim().Split(',')[0], NumberStyles.Float, Inv, out first)) throw new IOException("could not read " + s.Name + " (" + (e ?? "").Trim() + ")");
                string nn = "rec-" + Stamp(r.BaseMs + first * 1000.0) + "-" + ((int)Math.Round((r.BaseMs + first * 1000.0) % 1000.0)).ToString("000", Inv) + ".ts";
                string np = Path.Combine(RecDir, nn);
                for (int i = 0; i < 5; i++) { try { if (File.Exists(np)) File.Delete(np); File.Move(path, np); break; } catch (IOException) { if (i == 4) throw; Thread.Sleep(300); } }
                long size = new FileInfo(np).Length;
                lock (gate)
                {
                    s.FirstPts = first; s.Start = r.BaseMs + first * 1000.0; s.Name = nn; s.Size = size; s.Closed = true; s.ProbeBusy = false; probing--; if (!r.FirstSeg) { r.FirstSeg = true; }
                    // ffmpeg's end time is the last frame plus a guessed frame length; the real end of a segment is where the next one starts
                    RecSeg prev = null; foreach (RecSeg x in segs) if (x != s && x.Closed && x.Run == s.Run && x.Start < s.Start && (prev == null || x.Start > prev.Start)) prev = x;
                    if (prev != null && Math.Abs(prev.End - s.Start) < 200) prev.End = s.Start;
                }
                if (!r.BlackDone) { r.BlackDone = true; BlackCheck(nn); }
            }
            catch (Exception ex)
            {
                lock (gate) { probing--; s.ProbeBusy = false; s.NextProbeMs = WallMs() + 60000; }
                Log.W("recorder: could not probe segment " + s.Name + " (" + ex.Message + ") - keeping it for retry");
            }
        }

        static void RetryProbes(double now)
        {
            List<RecSeg> retry = new List<RecSeg>();
            lock (gate) foreach (RecSeg s in segs) if (!s.Closed && !s.ProbeBusy && now >= s.NextProbeMs) { s.ProbeBusy = true; probing++; retry.Add(s); }
            foreach (RecSeg s in retry) { RecSeg ss = s; Enqueue(delegate { ProbeSeg(ss, ss.Owner); }); }
        }

        // The first segment of a run: is the picture black? (full-screen exclusive, or a blank screen). Looks at 4 keyframes only: a tiny decode.
        static void BlackCheck(string name)
        {
            try
            {
                string path = Path.Combine(RecDir, name); byte[] o; string e;
                int rc = RunBytes(FfmpegPath, "-v error -skip_frame nokey -i \"" + path + "\" -frames:v 4 -vf scale=32:18:flags=area,format=gray -fps_mode passthrough -f rawvideo -", null, 30000, out o, out e);
                int frames = o.Length / 576, dark = 0; double mean = 0;
                for (int k = 0; k < frames; k++) { int mx = 0; long sum = 0; for (int i = 0; i < 576; i++) { int v = o[k * 576 + i]; if (v > mx) mx = v; sum += v; } if (mx <= 24) dark++; mean += sum / 576.0; }
                if (frames > 0) mean /= frames;
                if (rc != 0 || frames == 0) { Log.W("recorder: could not check the picture (" + (e ?? "").Trim() + ")"); return; }
                blackChecked = true;
                if (dark >= Math.Max(1, frames - 1))
                {
                    black = true; note = "the recording is black";
                    Log.W("recorder: the recording is BLACK. iRacing is probably in full-screen exclusive mode, which cannot be recorded. In iRacing's graphics settings choose Windowed or Borderless, then drive again.");
                }
                else Log.W("recorder: picture check ok (" + frames + " frames, average brightness " + mean.ToString("0", Inv) + " of 255)");
            }
            catch (Exception ex) { Log.W("recorder: picture check: " + ex.Message); }
        }

        static double KeepMs()
        {
            if (keepOverrideSec > 0) return keepOverrideSec * 1000.0;
            return Math.Max(180000.0, Math.Min(600000.0, longestLap * 1300.0 + 30000.0));      // ~3 min; a long lap (the Nordschleife) keeps more so it is not cut short
        }

        static void PruneSegs(double now)
        {
            double cutoff = now - KeepMs(), protect = double.MaxValue;
            List<RecSeg> gone = new List<RecSeg>();
            lock (gate)
            {
                foreach (RecCut c in cuts) if (!c.Done) protect = Math.Min(protect, c.S);      // a clip still being cut keeps its video
                long total = 0; foreach (RecSeg s in segs) if (s.Closed) total += s.Size;
                List<RecSeg> byAge = new List<RecSeg>(segs); byAge.Sort(delegate (RecSeg a, RecSeg b) { return a.Start.CompareTo(b.Start); });
                foreach (RecSeg s in byAge)
                {
                    if (!s.Closed || HasSessionOwner(s)) continue;
                    bool old = s.End < cutoff, over = total > 4000000000L;      // a runaway bit rate must not fill the disk
                    if ((old || over) && s.End < protect) { gone.Add(s); total -= s.Size; }
                }
                foreach (RecSeg s in gone) segs.Remove(s);
                for (int i = cuts.Count - 1; i >= 0; i--) if (cuts[i].Done && cuts.Count > 20) cuts.RemoveAt(i);
            }
            foreach (RecSeg s in gone) { try { File.Delete(Path.Combine(RecDir, s.Name)); } catch { } }
        }

        // Sound chunks live exactly as long as some video still needs that time: a segment on disk, the open run or session, a session being
        // written, or a clip still to cut. Everything else goes (so a deleted segment takes its sound with it).
        static double lastAudPrune;
        static void PruneAudio(double now)
        {
            List<double[]> keep = new List<double[]>();
            lock (gate)
            {
                foreach (RecSeg s in segs) keep.Add(new double[] { s.Start > 0 ? s.Start : s.End - 70000, s.End > 0 ? s.End : double.MaxValue });
                if (run != null && ff != null) keep.Add(new double[] { run.StartMs - 1000, double.MaxValue });
                if (openSess != null) keep.Add(new double[] { openSess.StartMs - 1000, double.MaxValue });
                foreach (RecSess s in finishing) keep.Add(new double[] { s.StartMs - 1000, s.EndMs > 0 ? s.EndMs + 1000 : double.MaxValue });
                foreach (RecCut c in cuts) if (!c.Done) keep.Add(new double[] { c.S - 2000, c.E + 2000 });
                foreach (RecInc x in incCuts) if (!x.Done) keep.Add(new double[] { x.S - 2000, x.E + 2000 });
            }
            RecAudio.Prune(delegate (double a, double b) { foreach (double[] k in keep) if (a < k[1] && b > k[0]) return true; return false; }, now - 30000);
        }

        // An open or finishing session owns its segments until its MP4 is written.
        static bool HasSessionOwner(RecSeg seg)
        {
            lock (gate)
            {
                if (seg.Owner != null && seg.Owner.Sess != null) return true;
                if (openSess != null && openSess.Segs.Contains(seg)) return true;
                foreach (RecSess s in finishing) if (s.Segs.Contains(seg)) return true;
                return false;
            }
        }

        static void ResolveCuts(double now)
        {
            lock (gate)
            {
                double lastEnd = 0; foreach (RecSeg s in segs) if (s.Closed && s.End > lastEnd) lastEnd = s.End;
                foreach (RecCut c in cuts)
                {
                    if (c.Started) continue;
                    // wait until the video covers a second past the line (a segment is closed every ~10 s), or no more video is coming
                    bool ready = lastEnd >= c.E || (ff == null && probing == 0) || now > c.E + 30000;
                    if (!ready) continue;
                    c.Started = true; c.Result = ""; RecCut cc = c; Enqueue(delegate { RunCut(cc); });
                }
            }
        }

        // ---------------- cutting a lap out, without re-encoding ----------------
        static string ClipId(RecLap l) { return "rec-" + Stamp(l.Start) + "-l" + l.N; }

        static void RunCut(RecCut job)
        {
            RecLap L = job.Lap;
            try
            {
                string id = ClipId(L), mp4 = Path.Combine(ClipDir, id + ".mp4");
                long free = FreeBytes(ClipDir);
                if (free < (long)(MinFreeGb * 1024 * 1024 * 1024))
                {
                    job.Result = "no disk space";
                    Log.W("recorder: not keeping the clip of lap " + L.N + " - only " + (free / 1073741824.0).ToString("0.0", Inv) + " GB is free on the disk and Paddock keeps " + MinFreeGb.ToString("0", Inv) + " GB free");
                    return;
                }
                // the segments that hold the lap: one run, joined end to end
                List<RecSeg> all; lock (gate) { all = new List<RecSeg>(); foreach (RecSeg s in segs) if (s.Closed) all.Add(s); }
                int bestRun = -1; double bestOv = 0;
                foreach (RecSeg s in all) { double ov = Math.Min(s.End, L.End) - Math.Max(s.Start, L.Start); if (ov > bestOv) { bestOv = ov; bestRun = s.Run; } }
                List<RecSeg> sel = new List<RecSeg>();
                if (bestRun >= 0)
                {
                    List<RecSeg> mine = new List<RecSeg>(); foreach (RecSeg s in all) if (s.Run == bestRun) mine.Add(s);
                    mine.Sort(delegate (RecSeg a, RecSeg b) { return a.Start.CompareTo(b.Start); });
                    foreach (RecSeg s in mine)
                    {
                        if (s.End <= job.S) continue;
                        if (s.Start >= job.E) break;
                        if (sel.Count > 0 && s.Start - sel[sel.Count - 1].End > 300) break;
                        sel.Add(s);
                    }
                }
                if (sel.Count == 0) { job.Result = "no video"; Log.W("recorder: no video of lap " + L.N + " (the recorder was not filming then) - no clip"); return; }

                RecSeg first = sel[0], last = sel[sel.Count - 1];
                // the clip begins on a keyframe at or before the wanted start (a copy can only start there)
                double k0 = first.Start; bool truncated = false;
                if (job.S > first.Start)
                {
                    string o, e; double want = (job.S - first.BaseMs) / 1000.0;
                    int rc = RunTool(FfprobePath, "-v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 \"" + Path.Combine(RecDir, first.Name) + "\"", null, 30000, out o, out e);
                    if (rc == 0)
                        foreach (string ln in o.Split('\n'))
                        {
                            string[] c = ln.Trim().Split(','); double t;
                            if (c.Length >= 2 && c[1].IndexOf('K') >= 0 && double.TryParse(c[0], NumberStyles.Float, Inv, out t) && t <= want + 1e-6) k0 = first.BaseMs + t * 1000.0;
                        }
                }
                double endWall = Math.Min(job.E, last.End);
                if (k0 > L.Start + 5 || last.End < L.End) truncated = true;
                double ss = Math.Max(0.0, (k0 - first.BaseMs) / 1000.0 - first.FirstPts - 0.004);     // the joined input starts at the first packet; -0.004 so the keyframe itself is kept
                double dur = Math.Max(0.5, (endWall - k0) / 1000.0);
                StringBuilder cat = new StringBuilder("concat:");
                for (int i = 0; i < sel.Count; i++) { if (i > 0) cat.Append('|'); cat.Append(sel[i].Name); }
                try { Directory.CreateDirectory(ClipDir); } catch { }
                string tmp = mp4 + ".tmp";
                int rot = first.Rot == 3 ? 180 : first.Rot == 2 ? 90 : first.Rot == 4 ? 270 : 0;
                // the sound of the same stretch: the joined input's time 0 is first.Start, so the sound starts there too and -ss/-t cut both alike
                string pcm, aud; SoundFor("cut-" + id, new double[] { first.Start }, new double[] { endWall }, out pcm, out aud);
                string head = "-hide_banner -y -loglevel error " + (rot != 0 ? "-display_rotation " + rot + " " : "") + "-i \"" + cat + "\"";
                string tail = " -ss " + ss.ToString("0.000", Inv) + " -t " + dur.ToString("0.000", Inv) + " ";
                string fin = (first.Enc == "hevc_nvenc" ? "-tag:v hvc1 " : "") + "-movflags +faststart -f mp4 \"" + tmp + "\"";
                string args = pcm != null ? head + SoundIn(pcm) + tail + SoundOut() + fin : head + tail + "-c copy " + fin;
                lastCutArgs = args;
                Stopwatch sw = Stopwatch.StartNew(); string so, se;
                int crc = RunTool(FfmpegPath, args, RecDir, 180000, out so, out se);
                if (pcm != null && crc != 0 && crc != -1)
                {
                    Log.W("recorder: the clip of lap " + L.N + " could not take its sound (" + (se ?? "").Trim() + ") - cutting it without");
                    aud = "none"; args = head + tail + "-c copy " + fin; lastCutArgs = args;
                    crc = RunTool(FfmpegPath, args, RecDir, 180000, out so, out se);
                }
                if (pcm != null) { try { File.Delete(pcm); } catch { } }
                if (crc != 0 || !File.Exists(tmp) || new FileInfo(tmp).Length < 1000) { if (crc == -1) { job.Result = "retry"; job.Started = false; try { File.Delete(tmp); } catch { } return; } job.Result = "cut failed"; try { File.Delete(tmp); } catch { } throw new IOException("ffmpeg could not cut the clip: " + (se ?? "").Trim()); }
                // where the clip's own clock starts and how long it is
                string po, pe; double vstart = 0, vdur = 0;
                if (RunTool(FfprobePath, "-v error -select_streams v:0 -show_entries stream=start_time,duration -of default=nw=1 \"" + tmp + "\"", null, 20000, out po, out pe) == 0)
                    foreach (string ln in po.Split('\n'))
                    {
                        string t = ln.Trim(); double v;
                        if (t.StartsWith("start_time=") && double.TryParse(t.Substring(11), NumberStyles.Float, Inv, out v)) vstart = v;
                        else if (t.StartsWith("duration=") && double.TryParse(t.Substring(9), NumberStyles.Float, Inv, out v)) vdur = v;
                    }
                // clip time t shows wall-clock time k0 + (t - vstart)
                RecClip c2 = new RecClip();
                c2.Id = id; c2.File = mp4; c2.Lap = L.N; c2.LapTime = L.Time; c2.LapStartMs = L.Start; c2.LapEndMs = L.End; c2.ClipStartMs = k0; c2.VideoStart = vstart; c2.Duration = vdur;
                c2.LapStartOffset = (L.Start - k0) / 1000.0 + vstart; c2.LapEndOffset = (L.End - k0) / 1000.0 + vstart; c2.Rotation = rot; c2.Encoder = run != null ? run.Encoder : "";
                c2.Car = L.Car; c2.Track = L.Track; c2.Config = L.Config; c2.SessionTime = L.SessionTime; c2.Why = L.Why; c2.Keep = L.Keep; c2.Pb = L.Why == "pb" || (L.Bar > 0 && L.Time > 0 && L.Time < L.Bar - 0.0005);
                c2.Truncated = truncated; c2.Created = (long)WallMs(); c2.Audio = aud;
                if (File.Exists(mp4)) File.Delete(mp4);
                File.Move(tmp, mp4);
                c2.Size = new FileInfo(mp4).Length;
                SaveSidecar(c2);
                lock (gate) { RecClip old = FindClip(id); if (old != null) clips.Remove(old); clips.Add(c2); }
                job.Result = "ok";
                Log.W("recorder: clip of lap " + L.N + " saved as " + id + " (" + vdur.ToString("0.0", Inv) + " s of video, " + (c2.Size / 1048576) + " MB, cut in " + sw.ElapsedMilliseconds + " ms, picture not re-encoded, " + (aud == "none" ? "no sound" : aud == "partial" ? "sound for part of it" : "with sound") + (truncated ? ", the lap start is before the video" : "") + ")");
                PruneClips();
            }
            catch (Exception ex) { if (job.Result.Length == 0 || job.Result == "cut failed") job.Result = "error"; Log.W("recorder: clip of lap " + L.N + ": " + ex.Message); }
            finally { lock (gate) if (job.Result != "retry") job.Done = true; }
        }

        static RecClip FindClip(string id) { foreach (RecClip c in clips) if (c.Id == id) return c; return null; }

        // ---------------- the sound for a file (recaudio.cs) ----------------
        // A raw PCM in the rec folder that follows the same wall-clock spans as the picture; pcm = null when nothing was captured then
        // (the file is then written without a sound track, as before). verdict: ok | partial (some of the time had no capture) | none.
        static void SoundFor(string name, double[] starts, double[] ends, out string pcm, out string verdict)
        {
            pcm = null; verdict = "none";
            try
            {
                if (RecAudio.Count == 0 || starts.Length == 0) return;
                string safe = name; foreach (char ch in Path.GetInvalidFileNameChars()) safe = safe.Replace(ch, '_');
                string p = Path.Combine(RecDir, safe + ".pcm"); long frames;
                double cov = RecAudio.BuildPcm(p, starts, ends, out frames);
                if (cov <= 0.001 || frames <= 0) { try { File.Delete(p); } catch { } return; }
                pcm = p; verdict = cov >= 0.99 ? "ok" : "partial";
            }
            catch (Exception ex) { Log.W("recorder: could not gather the sound for " + name + " (" + ex.Message + ") - writing the picture only"); pcm = null; verdict = "none"; }
        }
        static string SoundIn(string pcm) { return " -f s16le -ar 48000 -ac 2 -i \"" + pcm + "\""; }
        // the picture is copied as it is; only the sound is encoded (AAC 160 kbit/s, one thread, so a cut while driving stays light)
        static string SoundOut() { return "-map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 160k -threads 1 "; }

        static void SaveSidecar(RecClip c)
        {
            try
            {
                string f = Path.Combine(ClipDir, c.Id + ".json"), t = f + ".tmp";
                File.WriteAllText(t, c.Json(), new UTF8Encoding(false));
                if (File.Exists(f)) File.Delete(f);
                File.Move(t, f);
            }
            catch (Exception ex) { Log.W("recorder: could not write the sidecar of " + c.Id + " (" + ex.Message + ")"); }
        }

        static void LoadClips()
        {
            lock (gate)
            {
                clips.Clear();
                try
                {
                    if (!Directory.Exists(ClipDir)) return;
                    foreach (string f in Directory.GetFiles(ClipDir, "rec-*.json"))
                    {
                        try
                        {
                            Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                            if (d == null) continue;
                            RecClip c = RecClip.FromDict(d); c.File = Path.Combine(ClipDir, c.Id + ".mp4");
                            if (c.Id.Length > 0 && File.Exists(c.File)) clips.Add(c);
                        }
                        catch { }
                    }
                }
                catch (Exception ex) { Log.W("recorder: could not read the clip list (" + ex.Message + ")"); }
            }
        }

        // Clips nobody starred (no KEEP, not a personal best) go after the Vault's "recent" days, or sooner when the Vault is over its space.
        static void PruneClips() { TrimClips(0, true); }

        // frees up to 'bytes' from the oldest clips nobody starred; old ones (older than the Vault's recent days) always go. Returns the bytes freed.
        public static long TrimClips(long bytes, bool onlyOld)
        {
            long freed = 0; List<RecClip> gone = new List<RecClip>();
            lock (gate)
            {
                double limit = WallMs() - Vault.RecentDays * 86400000.0;
                List<RecClip> byAge = new List<RecClip>(clips); byAge.Sort(delegate (RecClip a, RecClip b) { return a.LapStartMs.CompareTo(b.LapStartMs); });
                foreach (RecClip c in byAge)
                {
                    if (c.Keep || c.Pb) continue;
                    bool old = c.LapStartMs < limit;
                    if (old || (!onlyOld && freed < bytes)) { gone.Add(c); freed += c.Size; }
                }
                foreach (RecClip c in gone) clips.Remove(c);
            }
            foreach (RecClip c in gone)
            {
                try { File.Delete(c.File); File.Delete(Path.Combine(ClipDir, c.Id + ".json")); } catch { }
                Log.W("recorder: removed the clip " + c.Id + " (old, not a keeper)");
            }
            return freed;
        }

        // ---------------- the work thread (ffprobe / ffmpeg runs, one at a time) ----------------
        static void Enqueue(ThreadStart a) { lock (work) { work.Enqueue(a); Monitor.Pulse(work); } }

        static void WorkerLoop()
        {
            while (true)
            {
                ThreadStart a;
                lock (work) { while (work.Count == 0) Monitor.Wait(work); a = work.Dequeue(); busy++; }
                try { a(); } catch (Exception ex) { Log.W("recorder: " + ex.Message); }
                finally { lock (work) busy--; }
            }
        }

        static int RunTool(string exe, string args, string cwd, int timeoutMs, out string stdout, out string stderr)
        {
            byte[] b; int rc = RunBytes(exe, args, cwd, timeoutMs, out b, out stderr);
            stdout = Encoding.UTF8.GetString(b); return rc;
        }

        static int RunBytes(string exe, string args, string cwd, int timeoutMs, out byte[] stdout, out string stderr)
        {
            stdout = new byte[0]; stderr = "";
            ProcessStartInfo psi = new ProcessStartInfo(exe, args); psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            if (cwd != null) psi.WorkingDirectory = cwd;
            using (Process p = Process.Start(psi))
            {
                try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
                MemoryStream ms = new MemoryStream(); StringBuilder se = new StringBuilder();
                Thread t = new Thread(delegate () { try { p.StandardOutput.BaseStream.CopyTo(ms); } catch { } }); t.IsBackground = true; t.Start();
                p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) lock (se) se.AppendLine(e.Data); };
                p.BeginErrorReadLine();
                if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } stderr = "timed out"; return -1; }
                p.WaitForExit(); t.Join(3000);
                lock (ms) stdout = ms.ToArray();
                lock (se) stderr = se.ToString();
                return p.ExitCode;
            }
        }

        // ---------------- serving ----------------
        // Which clip does this id mean? A recorder clip id, or a Vault lap (matched by car, track, lap number and when it was driven).
        static RecClip ClipFor(string id)
        {
            if (string.IsNullOrEmpty(id)) return null;
            RecClip hit = null;
            lock (gate) hit = FindClip(id);
            if (hit != null) return hit;
            if (id.Length > 260) return null;
            string combo; int lap; double lt; long from, to;
            // "<telemetry file>.ibt:<lap>": a lap named by its file, as the Session Review and the Workbench open it (no lap time to compare then)
            int colon = id.LastIndexOf(':'), fl;
            if (colon > 4 && id.Substring(0, colon).EndsWith(".ibt", StringComparison.OrdinalIgnoreCase) && int.TryParse(id.Substring(colon + 1), NumberStyles.Integer, Inv, out fl) && fl > 0)
            {
                lap = fl; lt = 0;
                if (!Vault.SessionWhen(id.Substring(0, colon), out combo, out from, out to)) return null;
            }
            else if (!Vault.MomentWhen(id, out combo, out lap, out lt, out from, out to)) return null;
            lock (gate)
            {
                foreach (RecClip c in clips)
                {
                    if (Combo.Key(c.Car, c.Track, c.Config) != combo) continue;
                    if (c.LapStartMs < from - 120000 || c.LapStartMs > to + 120000) continue;
                    bool sameLap = c.Lap == lap && (lt <= 0 || c.LapTime <= 0 || Math.Abs(c.LapTime - lt) < 0.5);
                    bool sameTime = lt > 0 && Math.Abs(c.LapTime - lt) < 0.005;
                    if ((sameLap || sameTime) && (hit == null || c.Created > hit.Created)) hit = c;
                }
            }
            return hit;
        }

        public static bool ServeVideo(NetworkStream s, string id, Dictionary<string, string> hdr)
        {
            RecClip c = ClipFor(id);
            return Vault.ServeMp4(s, c != null && File.Exists(c.File) ? c.File : null, hdr);      // null = 404, and Range works for the player's seeking
        }

        // the share studio (share.cs) needs the clip behind an id, the clips folder and the two ffmpeg tools
        internal static RecClip ClipForShare(string id) { return ClipFor(id); }
        internal static string ClipFolder { get { return ClipDir; } }
        internal static string FfmpegExe { get { return FfmpegPath; } }
        internal static string FfprobeExe { get { return FfprobePath; } }

        public static string InfoJson(string id, out int code)
        {
            code = 200; RecClip c = ClipFor(id);
            if (c == null || !File.Exists(c.File)) { code = 404; return "{\"error\":\"no clip\"}"; }
            return c.Json();
        }

        public static string StatusJson()
        {
            lock (gate)
            {
                int closed = 0; double oldest = 0, newest = 0; long bytes = 0;
                foreach (RecSeg s in segs) if (s.Closed) { closed++; bytes += s.Size; if (oldest == 0 || s.Start < oldest) oldest = s.Start; if (s.End > newest) newest = s.End; }
                int pending = 0; foreach (RecCut c in cuts) if (!c.Done) pending++;
                string seg0 = "[";
                List<RecSeg> byAge = new List<RecSeg>(segs); byAge.Sort(delegate (RecSeg a, RecSeg b) { return a.Start.CompareTo(b.Start); });
                bool first = true;
                foreach (RecSeg s in byAge) if (s.Closed) { if (!first) seg0 += ","; first = false; seg0 += "{\"name\":" + Json_.S(s.Name) + ",\"startMs\":" + s.Start.ToString("0.000", Inv) + ",\"endMs\":" + s.End.ToString("0.000", Inv) + ",\"run\":" + s.Run + "}"; }
                seg0 += "]";
                string cl = "["; first = true;
                foreach (RecClip c in clips) { if (!first) cl += ","; first = false; cl += c.Json(); }
                cl += "]";
                long sessBytes = 0; double sessSecs = 0;
                if (openSess != null) { foreach (RecSeg g in openSess.Segs) if (g.Closed) sessBytes += g.Size; sessSecs = Math.Max(0, (WallMs() - openSess.StartMs) / 1000.0); }
                return "{\"enabled\":" + (enabled ? "true" : "false") + ",\"test\":" + (testOn ? "true" : "false") + ",\"running\":" + (ff != null ? "true" : "false") + ",\"source\":" + Json_.S(source) +
                       ",\"session\":" + Json_.S(openSess != null ? openSess.Id : "") + ",\"sessionSecs\":" + sessSecs.ToString("0.0", Inv) + ",\"sessionBytes\":" + sessBytes + ",\"saveWhenDone\":" + (openSess != null && openSess.SaveWhenDone ? "true" : "false") +
                       ",\"saveState\":" + Json_.S(recState) + ",\"recentGb\":" + (RecentBytes() / 1073741824.0).ToString("0.0", Inv) + ",\"savedGb\":" + (SavedBytes() / 1073741824.0).ToString("0.0", Inv) +
                       ",\"encoder\":" + Json_.S(source == "test" ? "libx264" : encoder) + ",\"restarts\":" + restarts + ",\"gaveUp\":" + (gaveUp ? "true" : "false") + ",\"run\":" + (run != null ? run.No : 0) + ",\"baseMs\":" + (run != null ? run.BaseMs.ToString("0", Inv) : "0") +
                       ",\"outputIdx\":" + outIdx + ",\"outputAdapter\":" + outAdapter + ",\"outputRect\":" + Json_.S(outRect) + ",\"rotation\":" + outRot + ",\"black\":" + (black ? "true" : "false") + ",\"blackChecked\":" + (blackChecked ? "true" : "false") + ",\"note\":" + Json_.S(note) + ",\"lastError\":" + Json_.S(lastErr) +
                       ",\"segments\":" + closed + ",\"segmentBytes\":" + bytes + ",\"oldestMs\":" + oldest.ToString("0", Inv) + ",\"newestMs\":" + newest.ToString("0", Inv) + ",\"keepSecs\":" + (KeepMs() / 1000.0).ToString("0", Inv) + ",\"probing\":" + probing + ",\"pendingCuts\":" + pending + ",\"busy\":" + busy +
                       ",\"clips\":" + clips.Count + ",\"freeGb\":" + (FreeBytes(ClipDir) / 1073741824.0).ToString("0.0", Inv) + ",\"minFreeGb\":" + MinFreeGb.ToString("0", Inv) + ",\"sessionBest\":" + N3(sessionBest) + ",\"lastCutArgs\":" + Json_.S(lastCutArgs) + ",\"lastRunArgs\":" + Json_.S(lastRunArgs) + ",\"encoderUsed\":" + Json_.S(run != null ? run.Encoder : "") + ",\"ffmpegPid\":" + (ff != null ? SafePid() : 0) +
                       ",\"capture\":" + CaptureJson(newest, sessSecs) + ",\"sound\":" + RecAudio.StatusJson() + ",\"audioMode\":" + Json_.S(testOn ? testAudio : audioMode) + ",\"segList\":" + seg0 + ",\"clipList\":" + cl + "}";
            }
        }

        // The one verdict every screen shows: "recording" only while new segments are really landing on disk (a running
        // ffmpeg alone is not proof). Called under gate. starting | recording | stalled | paused-disk | failed | idle | off
        static string CaptureJson(double newestSegEnd, double sessSecs)
        {
            double now = WallMs(), fresh = segSecs * 1000.0 * 2 + 5000;
            string st;
            if (!enabled) st = "off";
            else if (diskPaused) st = "paused-disk";
            else if (gaveUp) st = "failed";
            else if (ff == null) st = "idle";
            else if (newestSegEnd > 0 && run != null && newestSegEnd >= run.StartMs && now - newestSegEnd <= fresh) st = "recording";
            else if (run != null && now - run.StartMs <= fresh + 10000) st = "starting";
            else st = "stalled";
            // the sound beside it: ok | starting | failed | off (recorder_audio=0) while the picture runs, idle otherwise. Only "failed" is news for Peter ("no sound").
            string au = ff == null ? "idle" : RecAudio.State;
            return "{\"state\":" + Json_.S(st) + ",\"secs\":" + sessSecs.ToString("0", Inv) + ",\"lastSegAgoS\":" + (newestSegEnd > 0 ? ((now - newestSegEnd) / 1000.0).ToString("0.0", Inv) : "null") +
                   ",\"audio\":" + Json_.S(au) + ",\"audioSource\":" + Json_.S(ff == null ? "" : RecAudio.Source) + "}";
        }

        // ---------------- S1: whole-session video, incident clips, retention and SAVE ----------------
        static string DS(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, CultureInfo.InvariantCulture) : ""; }
        static double DD(Dictionary<string, object> d, string k) { object o; double v; return d.TryGetValue(k, out o) && o != null && double.TryParse(Convert.ToString(o, CultureInfo.InvariantCulture), NumberStyles.Float, Inv, out v) ? v : 0; }
        static bool DB(Dictionary<string, object> d, string k) { object o; return d.TryGetValue(k, out o) && o is bool && (bool)o; }

        static string SessionTypeName(Frame f) { try { return Career.SessionTypeOf(f.SessionYaml, (int)f.Num("SessionNum")); } catch { return ""; } }

        // One look per frame: open a session when recording starts, close it when the sim closes or the session identity changes.
        // The identity is SessionUniqueID (real iRacing always sends one); the made-up test frames without it keep the old rolling-window behaviour.
        static void SessionTick(Frame f, double now)
        {
            RecSess current; lock (gate) current = openSess;
            if (!f.Connected)
            {
                if (current != null) EndSession("the sim closed", true);
                return;
            }
            double uid = f.Num("SessionUniqueID"); int snum = (int)f.Num("SessionNum");
            if (current != null)
            {
                if (uid != current.UniqueId || snum != current.SessionNum)
                {
                    // The recorder stops on a segment boundary; keep that tail out of this session.
                    lock (gate) { if (openSess == current) current.EndMs = now; }
                    if (ff != null) AskStop("the session changed", now);
                    EndSession("the session changed", true);
                }
                else lock (gate) { if (openSess == current) current.EndMs = now; }
            }
            lock (gate) current = openSess;
            if (current == null && ff == null && uid != 0 && ShouldRecord(f)) { BeginSession(f, now); lock (gate) current = openSess; }
            if (current != null)
            {
                int inc = (int)f.Num("PlayerCarMyIncidentCount");
                int added = 0;
                lock (gate)
                {
                    if (openSess == current)
                    {
                        if (current.IncSeen < 0) current.IncSeen = inc;
                        else if (inc > current.IncSeen) { added = inc - current.IncSeen; current.IncSeen = inc; }
                        else current.IncSeen = inc;
                    }
                }
                if (added > 0) QueueIncident(current, now, added);
            }
        }

        static void BeginSession(Frame f, double now)
        {
            // Encoder failures belong to a session. Give each new session a fresh hardware attempt.
            restarts = 0; gaveUp = false; fellBack = false; encoder = "hevc_nvenc";
            Combo.Info ci = ComboNow(f);
            RecSess s = new RecSess();
            s.SessionNum = (int)f.Num("SessionNum"); s.UniqueId = f.Num("SessionUniqueID");
            s.Car = ci.Car; s.Track = ci.Track; s.Config = ci.Config; s.Type = SessionTypeName(f);
            s.StartMs = now; s.Created = (long)now; s.Encoder = source == "test" ? "libx264" : encoder;
            string slug = Combo.Slug(ci.Track); if (slug.Length == 0) slug = "session"; if (slug.Length > 30) slug = slug.Substring(0, 30);
            s.Id = Stamp(now) + "-" + slug;
            lock (gate) openSess = s;
            if (run != null)
            {
                run.Sess = s;
                lock (gate) foreach (RecSeg g in segs) if (g.Owner == run && !s.Segs.Contains(g)) s.Segs.Add(g);
            }
            Log.W("recorder: session " + s.Id + " started (" + (s.Car.Length > 0 ? s.Car + ", " : "") + (s.Track.Length > 0 ? s.Track + ", " : "") + (s.Type.Length > 0 ? s.Type : "session") + ")");
        }

        // The session is over: cut any lap clip still waiting, then write the whole thing on the worker (FIFO, so the cuts go first).
        static void EndSession(string why, bool waitVideo)
        {
            RecSess s;
            lock (gate)
            {
                s = openSess; if (s == null) return;
                openSess = null; s.Open = false; finishing.Add(s);
            }
            Log.W("recorder: session " + s.Id + " ended (" + why + ")");
            if (s.Segs.Count == 0 && ff == null) { lock (gate) finishing.Remove(s); Log.W("recorder: nothing was recorded for session " + s.Id); return; }
            lock (gate)
            {
                foreach (RecCut c in cuts)
                {
                    if (c.Started || c.Lap == null || !s.Laps.Contains(c.Lap)) continue;
                    c.Started = true; RecCut cc = c; Enqueue(delegate () { RunCut(cc); });
                }
            }
            if (ff == null) QueueFinish(s, waitVideo);
        }

        static void QueueFinishing()
        {
            List<RecSess> todo = new List<RecSess>();
            lock (gate)
            {
                if (probing != 0) return;
                foreach (RecSess s in finishing)
                {
                    if (s.FinishQueued || WallMs() < s.RetryAfterMs) continue;
                    bool pending = false;
                    foreach (RecSeg g in s.Segs) if (!g.Closed) { pending = true; break; }
                    foreach (RecCut c in cuts) if (c.Lap != null && s.Laps.Contains(c.Lap) && !c.Done) { pending = true; break; }
                    if (!pending) foreach (RecInc x in incCuts) if (x.Sess == s.Id && !x.Done) { pending = true; break; }
                    if (!pending) todo.Add(s);
                }
            }
            foreach (RecSess s in todo) QueueFinish(s, true);
        }

        static void QueueFinish(RecSess s, bool waitVideo)
        {
            lock (gate) { if (s.FinishQueued) return; s.FinishQueued = true; }
            Enqueue(delegate () { FinishSession(s, waitVideo); });
        }

        // A finish that waited too long gives up cleanly: the segments stay, the session says so, and the normal retry picks it up.
        static void FinishStalled(RecSess s, string what)
        {
            lock (gate) { s.State = "finalize-stalled"; s.FinishQueued = false; s.RetryAfterMs = WallMs() + 60000; }
            Log.W("recorder: session " + s.Id + " - finishing stalled (" + what + " still busy after 120 s); keeping the segments and trying again in 60 s");
        }

        // Concat the session's segments, without re-encoding, into sessions\<id>.mp4 + a sidecar, then delete its .ts files.
        static void FinishSession(RecSess s, bool waitVideo)
        {
            List<double[]> wallIncidents = null;     // the incidents in wall time, put back if this attempt fails (a retry must not read file offsets as wall time)
            try
            {
                if (FreeBytes(SessDir) < (long)(MinFreeGb * 1073741824.0)) { lock (gate) s.FinishQueued = false; Log.W("recorder: session " + s.Id + " kept as segments - less than 50 GB is free"); return; }
                // a SAVE pressed before a restart (or before this recovery) is still a SAVE; a recovered session has a new id, so any orphan wish is its
                string wishFile = File.Exists(WishPath(s.Id)) ? WishPath(s.Id) : null;
                // ...but only a wish pressed while THIS session was recording (or within 10 minutes after), never an old one
                if (wishFile == null && s.Recovered)
                {
                    try
                    {
                        string[] w = Directory.Exists(RecDir) ? Directory.GetFiles(RecDir, "save-*.wish") : new string[0];
                        double from = s.StartMs - 60000, to = (s.EndMs > 0 ? s.EndMs : WallMs()) + 600000;
                        foreach (string x in w)
                        {
                            double at = (File.GetLastWriteTimeUtc(x) - Epoch).TotalMilliseconds;
                            if (at >= from && at <= to) { wishFile = x; break; }
                        }
                    }
                    catch { }
                }
                if (wishFile != null && !s.SaveWhenDone) { s.SaveWhenDone = true; Log.W("recorder: session " + s.Id + " - a SAVE pressed earlier is honoured"); }
                if (waitVideo)
                {
                    double ffUntil = WallMs() + 120000;
                    while (ff != null) { if (WallMs() > ffUntil) { FinishStalled(s, "the screen recorder"); return; } Thread.Sleep(100); }
                }
                // the lap and incident clips of this session go first (they read the same .ts)
                for (int i = 0; i < 600; i++)
                {
                    bool pend = false;
                    lock (gate)
                    {
                        foreach (RecCut c in cuts) if (c.Lap != null && s.Laps.Contains(c.Lap) && !c.Done) { pend = true; break; }
                        if (!pend) foreach (RecInc x in incCuts) if (x.Sess == s.Id && !x.Done) { pend = true; break; }
                    }
                    if (!pend) break;
                    Thread.Sleep(100);
                }
                // Never discard source segments while any consumer is still active.
                double consUntil = WallMs() + 120000;
                while (true)
                {
                    bool pend = false;
                    lock (gate)
                    {
                        if (probing > 0) pend = true;
                        foreach (RecCut c in cuts) if (c.Lap != null && s.Laps.Contains(c.Lap) && !c.Done) pend = true;
                        foreach (RecInc x in incCuts) if (x.Sess == s.Id && !x.Done) pend = true;
                    }
                    if (!pend) break;
                    if (WallMs() > consUntil) { FinishStalled(s, "a lap or incident clip"); return; }
                    Thread.Sleep(100);
                }
                s.State = "";
                List<RecSeg> sel = new List<RecSeg>(), closed = new List<RecSeg>(); List<RecLap> lapSnapshot; List<double[]> incidentSnapshot;
                lock (gate)
                {
                    foreach (RecSeg g in s.Segs) if (g.Closed)
                    {
                        closed.Add(g);
                        if (File.Exists(Path.Combine(RecDir, g.Name))) sel.Add(g);
                        else Log.W("recorder: session " + s.Id + " is missing segment " + g.Name + " - joining the remaining video, marked as a gap");
                    }
                    lapSnapshot = new List<RecLap>(s.Laps);
                    incidentSnapshot = new List<double[]>(); foreach (double[] x in s.Incidents) incidentSnapshot.Add((double[])x.Clone());
                    wallIncidents = incidentSnapshot;
                }
                sel.Sort(delegate (RecSeg a, RecSeg b) { return a.Start.CompareTo(b.Start); });
                if (sel.Count == 0) { lock (gate) finishing.Remove(s); Log.W("recorder: session " + s.Id + " had no closed segments - nothing to write"); return; }
                if (s.StartMs <= 0 || sel[0].Start < s.StartMs) s.StartMs = sel[0].Start;
                try { Directory.CreateDirectory(SessDir); } catch { }
                string lst = Path.Combine(RecDir, "sess-" + s.Id + ".txt");
                StringBuilder sb = new StringBuilder("ffconcat version 1.0\n");
                foreach (RecSeg g in sel)
                {
                    double from = Math.Max(g.Start, s.StartMs), to = Math.Min(g.End, s.EndMs > 0 ? s.EndMs : g.End);
                    if (to <= from) continue;
                    sb.Append("file '").Append(g.Name.Replace("'", "'\\''")).Append("'\n");
                    // TS packet timestamps stay relative to the run's base, not the first packet in this segment.
                    if (from > g.Start + 1) sb.Append("inpoint ").Append(((from - g.BaseMs) / 1000.0).ToString("0.000", Inv)).Append('\n');
                    if (to < g.End - 1) sb.Append("outpoint ").Append(((to - g.BaseMs) / 1000.0).ToString("0.000", Inv)).Append('\n');
                    // each piece takes exactly its wall-clock span in the file: the sound below is built from the same spans, and the lap
                    // offsets (ClipSpans / WallToFile) too, so picture, sound and offsets stay together over an hour (no rounding creep)
                    sb.Append("duration ").Append(((to - from) / 1000.0).ToString("0.000000", Inv)).Append('\n');
                }
                File.WriteAllText(lst, sb.ToString(), new UTF8Encoding(false));
                string mp4 = Path.Combine(SessDir, s.Id + ".mp4"), tmp = mp4 + ".tmp";
                int rot = sel[0].Rot == 3 ? 180 : sel[0].Rot == 2 ? 90 : sel[0].Rot == 4 ? 270 : 0;
                double[] ss0, se0; ClipSpans(sel, s, out ss0, out se0);
                string pcm, aud; SoundFor("sess-" + s.Id, ss0, se0, out pcm, out aud);
                double spanAll = 0; for (int i = 0; i < ss0.Length; i++) spanAll += Math.Max(0, se0[i] - ss0[i]) / 1000.0;
                int tmo = 600000 + (int)Math.Min(3000000, spanAll * 200);          // the sound is encoded (~50x real time): a 3-hour race needs longer than 10 min
                string head = "-hide_banner -y -loglevel error " + (rot != 0 ? "-display_rotation " + rot + " " : "") + "-f concat -safe 0 -i \"" + lst + "\"";
                string fin = (sel[0].Enc == "hevc_nvenc" ? "-tag:v hvc1 " : "") + "-movflags +faststart -f mp4 \"" + tmp + "\"";
                string args = pcm != null ? head + SoundIn(pcm) + " " + SoundOut() + fin : head + " -c copy " + fin;
                Stopwatch sw = Stopwatch.StartNew(); string so, se;
                int rc = RunTool(FfmpegPath, args, RecDir, tmo, out so, out se);
                if (pcm != null && rc != 0)
                {
                    Log.W("recorder: session " + s.Id + " - the sound could not be added (" + (((se ?? "") + " " + (so ?? "")).Trim()) + "); writing the picture only");
                    try { File.Delete(tmp); } catch { }
                    aud = "none"; args = head + " -c copy " + fin;
                    rc = RunTool(FfmpegPath, args, RecDir, 600000, out so, out se);
                }
                if (pcm != null) { try { File.Delete(pcm); } catch { } }
                if (rc != 0 || !File.Exists(tmp) || new FileInfo(tmp).Length < 1000) { try { File.Delete(tmp); } catch { } lock (gate) { s.FinishQueued = false; s.RetryAfterMs = WallMs() + 60000; } Log.W("recorder: could not write the session video of " + s.Id + " (" + (((se ?? "") + " " + (so ?? "")).Trim()) + ") - keeping segments for retry"); return; }
                s.Audio = aud; s.AudioSource = aud == "none" ? "" : (s.Recovered ? "" : RecAudio.LastRunSource);
                if (File.Exists(mp4)) File.Delete(mp4);
                File.Move(tmp, mp4);
                try { File.Delete(lst); } catch { }
                s.File = mp4; s.Bytes = new FileInfo(mp4).Length;
                // the same spans that went into the concat list (clipped to the session), so a wall time maps to the picture really in the file
                double[] fs, fe; ClipSpans(sel, s, out fs, out fe);
                s.RecEndMs = fe.Length > 0 ? fe[fe.Length - 1] : 0;
                double spanSec = 0; for (int i = 0; i < fs.Length; i++) spanSec += Math.Max(0, fe[i] - fs[i]) / 1000.0;
                s.Duration = ProbeDuration(mp4); s.DurationSource = "probe";
                if (s.Duration <= 0) { s.Duration = spanSec; s.DurationSource = "segments"; Log.W("recorder: session " + s.Id + " - ffprobe could not measure the video; its length is estimated from the segments"); }
                {
                    double[] as_ = new double[closed.Count], ae = new double[closed.Count]; bool[] pr = new bool[closed.Count];
                    closed.Sort(delegate (RecSeg a, RecSeg b) { return a.Start.CompareTo(b.Start); });
                    for (int i = 0; i < closed.Count; i++) { as_[i] = closed[i].Start; ae[i] = closed[i].End; pr[i] = sel.Contains(closed[i]); }
                    s.Gaps = SessMatch.MissingSpans(as_, ae, pr);
                }
                s.Created = (long)WallMs();
                s.LapRows = new List<double[]>();
                foreach (RecLap l in lapSnapshot) s.LapRows.Add(new double[] { l.N, SessMatch.WallToFile(fs, fe, l.Start), l.Time, (!l.Pit && !l.Off && !l.Dirty && l.Time > minLap) ? 1 : 0, (l.Why == "pb" || (l.Bar > 0 && l.Time > 0 && l.Time < l.Bar - 0.0005)) ? 1 : 0, l.Start });   // [5] = wall start, so a time inside the lap maps through the same spans even over a gap
                List<double[]> inc = new List<double[]>();
                foreach (double[] x in incidentSnapshot) inc.Add(new double[] { SessMatch.WallToFile(fs, fe, x[0]), x[1] });
                s.Incidents = inc;
                lock (gate)
                {
                    long budget = savedBudgetBytes >= 0 ? savedBudgetBytes : (long)(SavedBudgetGb * 1024 * 1024 * 1024);
                    if (s.SaveWhenDone && SavedBytesLocked() + savedReserved + s.Bytes <= budget) { savedReserved += s.Bytes; s.Saving = true; s.Saved = true; s.SaveBlocked = ""; }
                    else if (s.SaveWhenDone)
                    {
                        // never withdraw a SAVE silently: keep the wish, say why it waits, and the next SAVE press can retry
                        s.Saved = false; s.SaveBlocked = "full";
                        Log.W("recorder: SAVE of session " + s.Id + " is waiting - the saved video would pass " + (budget / 1073741824.0).ToString("0", Inv) + " GB");
                    }
                    else s.Saved = false;
                }
                bool sidecarOk;
                if (s.Saved)
                {
                    bool moved = MoveToSaved(s);
                    lock (gate) { savedReserved -= s.Bytes; s.Saving = false; if (!moved) { s.Saved = false; s.SaveBlocked = "failed"; } }
                    sidecarOk = moved || WriteSessJson(s);
                }
                else sidecarOk = WriteSessJson(s);
                if (!sidecarOk)
                {
                    // the video is written but its sidecar is not: keep the segments too, so nothing is lost, and try again later
                    lock (gate) { s.FinishQueued = false; s.RetryAfterMs = WallMs() + 60000; s.Incidents = wallIncidents; }
                    Log.W("recorder: session " + s.Id + " - the sidecar could not be written; keeping the segments and retrying in 60 s");
                    return;
                }
                // the picture must be on the disk itself (not only in the Windows cache) before the segments go
                try { using (FileStream vf = new FileStream(s.File, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete)) vf.Flush(true); }
                catch (Exception ex) { Log.W("recorder: session " + s.Id + " - could not flush the video to disk (" + ex.Message + "); keeping the segments for now"); lock (gate) { s.FinishQueued = false; s.RetryAfterMs = WallMs() + 60000; s.Incidents = wallIncidents; } return; }
                if (wishFile != null) { try { File.Delete(wishFile); } catch { } }   // the sidecar (and video) are durable now, so the marker has done its job
                lock (gate) recState = s.Saved ? "SAVED" : s.SaveBlocked == "full" ? "SAVED FULL" : s.SaveBlocked == "failed" ? "SAVE FAILED" : recState;
                lock (gate) { foreach (RecSeg g in sel) segs.Remove(g); sessions.RemoveAll(delegate (RecSess x) { return x.Id == s.Id; }); sessions.Add(s); finishing.Remove(s); }
                foreach (RecSeg g in sel) { try { File.Delete(Path.Combine(RecDir, g.Name)); } catch { } }
                if (s.Gaps.Count > 0) Log.W("recorder: session " + s.Id + " is partial - " + s.Gaps.Count + " gap(s) where segments were missing; laps inside a gap have no video");
                Log.W("recorder: session " + s.Id + " written (" + s.Duration.ToString("0.0", Inv) + " s, " + (s.Bytes / 1048576) + " MB, " + s.LapRows.Count + " laps, joined in " + sw.ElapsedMilliseconds + " ms, picture not re-encoded, " + (s.Audio == "ok" ? "with sound" : s.Audio == "partial" ? "sound for part of it" : "no sound") + (s.Saved ? ", SAVED" : "") + ")");
                RetainSessions();
            }
            catch (Exception ex) { lock (gate) { s.FinishQueued = false; s.RetryAfterMs = WallMs() + 60000; if (wallIncidents != null) s.Incidents = wallIncidents; } Log.W("recorder: session " + s.Id + ": " + ex.Message); }
        }

        // The wall-time span of each segment that the concat list puts in the file (same clipping as FinishSession's list).
        static void ClipSpans(List<RecSeg> sel, RecSess s, out double[] starts, out double[] ends)
        {
            List<double> a = new List<double>(), b = new List<double>();
            foreach (RecSeg g in sel)
            {
                double from = Math.Max(g.Start, s.StartMs), to = Math.Min(g.End, s.EndMs > 0 ? s.EndMs : g.End);
                if (to <= from) continue;
                a.Add(from); b.Add(to);
            }
            starts = a.ToArray(); ends = b.ToArray();
        }

        static string Num(double v) { return double.IsNaN(v) || double.IsInfinity(v) ? "null" : v.ToString("0.000", Inv); }

        static double ProbeDuration(string path)
        {
            try { string o, e; if (RunTool(FfprobePath, "-v error -show_entries format=duration -of default=nw=1:nk=1 \"" + path + "\"", null, 20000, out o, out e) == 0) { double d; if (double.TryParse((o ?? "").Trim(), NumberStyles.Float, Inv, out d)) return d; } }
            catch { }
            return 0;
        }

        static string SessJson(RecSess s)
        {
            StringBuilder lb = new StringBuilder("[");
            for (int i = 0; i < s.LapRows.Count; i++) { double[] r = s.LapRows[i]; if (i > 0) lb.Append(','); lb.Append("{\"n\":" + ((int)r[0]) + ",\"offset\":" + Num(r[1]) + ",\"time\":" + r[2].ToString("0.000", Inv) + ",\"clean\":" + (r[3] != 0 ? "true" : "false") + ",\"pb\":" + (r[4] != 0 ? "true" : "false") + ",\"startMs\":" + (r.Length > 5 && !double.IsNaN(r[5]) ? r[5].ToString("0", Inv) : "null") + "}"); }
            lb.Append(']');
            StringBuilder ib = new StringBuilder("[");
            for (int i = 0; i < s.Incidents.Count; i++) { double[] r = s.Incidents[i]; if (i > 0) ib.Append(','); ib.Append("{\"offset\":" + Num(r[0]) + ",\"count\":" + ((int)r[1]) + "}"); }
            ib.Append(']');
            StringBuilder gb = new StringBuilder("[");
            for (int i = 0; i < s.Gaps.Count; i++) { if (i > 0) gb.Append(','); gb.Append("{\"fromMs\":" + s.Gaps[i][0].ToString("0", Inv) + ",\"toMs\":" + s.Gaps[i][1].ToString("0", Inv) + ",\"reason\":\"missing segment\"}"); }
            gb.Append(']');
            return "{\"schema\":2,\"id\":" + Json_.S(s.Id) + ",\"uniqueId\":" + (s.UniqueId > 0 ? s.UniqueId.ToString("0", Inv) : "null") + ",\"sessionNum\":" + (s.SessionNum >= 0 ? s.SessionNum.ToString(Inv) : "null") +
                   ",\"track\":" + Json_.S(s.Track) + ",\"config\":" + Json_.S(s.Config) + ",\"car\":" + Json_.S(s.Car) + ",\"sessionType\":" + Json_.S(s.Type) +
                   ",\"startMs\":" + s.StartMs.ToString("0", Inv) + ",\"endMs\":" + (s.RecEndMs > 0 ? s.RecEndMs.ToString("0", Inv) : "null") + ",\"durationSec\":" + s.Duration.ToString("0.000", Inv) + ",\"durationSource\":" + Json_.S(s.DurationSource) + ",\"bytes\":" + s.Bytes + ",\"encoder\":" + Json_.S(s.Encoder) +
                   ",\"state\":" + Json_.S(s.State.Length > 0 ? s.State : s.Gaps.Count > 0 ? "partial" : "ready") + ",\"gaps\":" + gb +
                   ",\"audio\":" + Json_.S(s.Audio.Length > 0 ? s.Audio : "none") + ",\"audioSource\":" + Json_.S(s.AudioSource) +
                   ",\"saved\":" + (s.Saved ? "true" : "false") + ",\"saveWhenDone\":" + (s.SaveWhenDone && !s.Saved ? "true" : "false") + ",\"saveBlocked\":" + Json_.S(s.SaveBlocked) +
                   ",\"recovered\":" + (s.Recovered ? "true" : "false") + ",\"created\":" + s.Created +
                   ",\"laps\":" + lb + ",\"incidents\":" + ib + "}";
        }

        // temp -> read back -> replace with a backup: the previous sidecar is never gone before the new one is on disk
        static bool WriteSessJson(RecSess s) { return s.File.Length > 0 && WriteSidecar(Path.ChangeExtension(s.File, ".json"), SessJson(s), s.Id); }

        static bool WriteSidecar(string f, string json, string id)
        {
            string t = f + ".tmp", bak = f + ".bak";
            try
            {
                byte[] data = new UTF8Encoding(false).GetBytes(json);
                using (FileStream w = new FileStream(t, FileMode.Create, FileAccess.Write, FileShare.None)) { w.Write(data, 0, data.Length); w.Flush(true); }   // on the disk, not just in the cache
                if (File.ReadAllText(t, Encoding.UTF8) != json) throw new IOException("read-back did not match");
                if (File.Exists(f)) { File.Replace(t, f, bak); try { File.Delete(bak); } catch { } }
                else File.Move(t, f);
                return true;
            }
            catch (Exception ex) { try { File.Delete(t); } catch { } Log.W("recorder: could not write the sidecar of session " + id + " (" + ex.Message + ")"); return false; }
        }

        // Saved = the video AND its sidecar are in vault\saved. The new sidecar goes first, so a crash halfway leaves the
        // old pair (unsaved, still listed) rather than a saved video nobody can find.
        static bool MoveToSaved(RecSess s)
        {
            try
            {
                if (s.File.Length == 0 || !File.Exists(s.File)) return false;
                Directory.CreateDirectory(SavedDir);
                if (s.File.StartsWith(SavedDir, StringComparison.OrdinalIgnoreCase)) { s.Saved = true; s.SaveBlocked = ""; bool w = WriteSessJson(s); if (!w) s.Saved = false; return w; }
                string dst = Path.Combine(SavedDir, s.Id + ".mp4"), dstJson = Path.ChangeExtension(dst, ".json"), oldFile = s.File, oldJson = Path.ChangeExtension(oldFile, ".json");
                // the saved sidecar is written from a copy of the state, so nobody sees "saved" before the video has moved
                string json; string oldBlocked;
                lock (gate) { oldBlocked = s.SaveBlocked; s.File = dst; s.Saved = true; s.SaveBlocked = ""; json = SessJson(s); s.File = oldFile; s.Saved = false; s.SaveBlocked = oldBlocked; }
                if (!WriteSidecar(dstJson, json, s.Id)) return false;
                try
                {
                    if (File.Exists(dst)) File.Delete(dst);
                    File.Move(oldFile, dst);
                }
                catch (Exception ex)
                {
                    try { File.Delete(dstJson); } catch { }
                    Log.W("recorder: could not save session " + s.Id + " (" + ex.Message + ")"); return false;
                }
                lock (gate) { s.File = dst; s.Saved = true; s.SaveBlocked = ""; }
                try { if (File.Exists(oldJson)) File.Delete(oldJson); } catch { }
                Log.W("recorder: session " + s.Id + " saved for good (vault\\saved, " + (s.Bytes / 1048576) + " MB)");
                return true;
            }
            catch (Exception ex) { Log.W("recorder: could not save session " + s.Id + " (" + ex.Message + ")"); return false; }
        }

        // a number that may be null in the sidecar (no video for that moment) -> NaN, never a plausible 0
        static double DN(Dictionary<string, object> d, string k) { object o; double v; return d.TryGetValue(k, out o) && o != null && double.TryParse(Convert.ToString(o, CultureInfo.InvariantCulture), NumberStyles.Float, Inv, out v) ? v : double.NaN; }

        static RecSess SessFromDict(Dictionary<string, object> d)
        {
            RecSess s = new RecSess(); s.Open = false;
            s.Id = DS(d, "id"); s.Track = DS(d, "track"); s.Config = DS(d, "config"); s.Car = DS(d, "car"); s.Type = DS(d, "sessionType"); s.Encoder = DS(d, "encoder");
            s.StartMs = DD(d, "startMs"); s.Duration = DD(d, "durationSec"); s.Bytes = (long)DD(d, "bytes"); s.Created = (long)DD(d, "created");
            s.Saved = DB(d, "saved"); s.Recovered = DB(d, "recovered"); s.EndMs = s.StartMs + s.Duration * 1000;
            double uid = DN(d, "uniqueId"), sn = DN(d, "sessionNum"), re = DN(d, "endMs");
            s.RecEndMs = double.IsNaN(re) ? 0 : re;
            s.UniqueId = double.IsNaN(uid) ? -1 : uid; s.SessionNum = double.IsNaN(sn) ? -99 : (int)sn;
            s.DurationSource = DS(d, "durationSource"); s.SaveBlocked = DS(d, "saveBlocked"); s.SaveWhenDone = DB(d, "saveWhenDone") && !s.Saved;
            s.Audio = DS(d, "audio"); s.AudioSource = DS(d, "audioSource");
            try
            {
                System.Collections.IList laps = d.ContainsKey("laps") ? d["laps"] as System.Collections.IList : null;
                if (laps != null) foreach (object o in laps) { Dictionary<string, object> r = o as Dictionary<string, object>; if (r == null) continue; s.LapRows.Add(new double[] { DD(r, "n"), DN(r, "offset"), DD(r, "time"), DB(r, "clean") ? 1 : 0, DB(r, "pb") ? 1 : 0, DN(r, "startMs") }); }
                System.Collections.IList inc = d.ContainsKey("incidents") ? d["incidents"] as System.Collections.IList : null;
                if (inc != null) foreach (object o in inc) { Dictionary<string, object> r = o as Dictionary<string, object>; if (r == null) continue; s.Incidents.Add(new double[] { DN(r, "offset"), DD(r, "count") }); }
                System.Collections.IList gaps = d.ContainsKey("gaps") ? d["gaps"] as System.Collections.IList : null;
                if (gaps != null) foreach (object o in gaps) { Dictionary<string, object> r = o as Dictionary<string, object>; if (r == null) continue; s.Gaps.Add(new double[] { DD(r, "fromMs"), DD(r, "toMs") }); }
            }
            catch { }
            return s;
        }

        static void LoadSessions()
        {
            lock (gate)
            {
                sessions.Clear();
                foreach (string dir in new string[] { SessDir, SavedDir })
                {
                    try
                    {
                        if (!Directory.Exists(dir)) continue;
                        foreach (string f in Directory.GetFiles(dir, "*.json"))
                        {
                            try
                            {
                                Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                                if (d == null) continue;
                                RecSess s = SessFromDict(d); s.File = Path.ChangeExtension(f, ".mp4");
                                if (s.Id.Length == 0 || !File.Exists(s.File)) continue;
                                sessions.RemoveAll(delegate (RecSess x) { return x.Id == s.Id; });
                                sessions.Add(s);
                                // a SAVE pressed before a restart: the finished session keeps it, so retention never deletes it
                                string wf = WishPath(s.Id);
                                if (File.Exists(wf))
                                {
                                    if (!s.Saved) { s.SaveWhenDone = true; Log.W("recorder: session " + s.Id + " - a SAVE pressed before the restart is kept"); }
                                    if (s.Saved || WriteSessJson(s)) { try { File.Delete(wf); } catch { } }   // gone only once the sidecar says so
                                }
                            }
                            catch { }
                        }
                    }
                    catch (Exception ex) { Log.W("recorder: could not read the session list (" + ex.Message + ")"); }
                }
            }
        }

        static long SavedBytes() { long b = 0; lock (gate) foreach (RecSess s in sessions) if (s.Saved) b += s.Bytes; return b; }
        static long RecentBytes() { long b = 0; lock (gate) { foreach (RecSess s in sessions) if (!s.Saved) b += s.Bytes; if (openSess != null) foreach (RecSeg g in openSess.Segs) if (g.Closed) b += g.Size; } return b; }

        // SAVE ("" = the open session, else the newest finished one). SAVED / SAVING / SAVED FULL / NOTHING.
        public static string Save(string id)
        {
            RecSess s = null;
            lock (gate)
            {
                if (string.IsNullOrEmpty(id))
                {
                if (openSess != null) { openSess.SaveWhenDone = true; WriteWish(openSess.Id); recState = "SAVING"; Log.W("recorder: SAVE - the open session " + openSess.Id + " is kept when it ends"); return "SAVING"; }
                    foreach (RecSess x in finishing) if (x.StartMs >= (s == null ? 0 : s.StartMs)) s = x;
                    foreach (RecSess x in sessions) if (x.StartMs >= (s == null ? 0 : s.StartMs)) s = x;
                    if (s == null) { recState = "NOTHING"; return "NOTHING"; }
                    if (finishing.Contains(s)) { s.SaveWhenDone = true; WriteWish(s.Id); recState = "SAVING"; return "SAVING"; }
                    if (s.Saved) { recState = "SAVED"; return "SAVED"; }
                }
                else
                {
                    if (openSess != null && id == openSess.Id) { openSess.SaveWhenDone = true; WriteWish(openSess.Id); recState = "SAVING"; Log.W("recorder: SAVE - the open session " + openSess.Id + " is kept when it ends"); return "SAVING"; }
                    foreach (RecSess x in finishing) if (x.Id == id) { x.SaveWhenDone = true; WriteWish(x.Id); recState = "SAVING"; return "SAVING"; }
                    foreach (RecSess x in sessions) if (x.Id == id) { s = x; break; }
                    if (s == null) { recState = "NOTHING"; return "NOTHING"; }
                    if (s.Saved) { recState = "SAVED"; return "SAVED"; }
                    if (s.Saving) { recState = "SAVING"; return "SAVING"; }
                }
                long budget = savedBudgetBytes >= 0 ? savedBudgetBytes : (long)(SavedBudgetGb * 1024 * 1024 * 1024);
                if (SavedBytesLocked() + savedReserved + s.Bytes > budget) { Log.W("recorder: SAVE refused - the saved video would pass " + (budget / 1073741824.0).ToString("0", Inv) + " GB"); recState = "SAVED FULL"; return "SAVED FULL"; }
                s.Saving = true; savedReserved += s.Bytes;
            }
            bool ok = MoveToSaved(s);
            lock (gate) { savedReserved -= s.Bytes; s.Saving = false; if (!ok) s.SaveBlocked = "failed"; }
            // a failed move is not "nothing to save": say it failed, the video stays where it was and SAVE can be pressed again
            recState = ok ? "SAVED" : "SAVE FAILED";
            return recState;
        }

        static long SavedBytesLocked() { long b = 0; foreach (RecSess x in sessions) if (x.Saved) b += x.Bytes; return b; }

        public static string SessionsJson()
        {
            lock (gate)
            {
                List<RecSess> all = new List<RecSess>(sessions);
                if (openSess != null) all.Add(openSess);
                all.AddRange(finishing);
                all.Sort(delegate (RecSess a, RecSess b) { return a.StartMs.CompareTo(b.StartMs); });
                StringBuilder sb = new StringBuilder("{\"sessions\":[");
                for (int i = 0; i < all.Count; i++)
                {
                    RecSess s = all[i]; if (i > 0) sb.Append(',');
                    double dur = s.Open ? Math.Max(0, (WallMs() - s.StartMs) / 1000.0) : s.Duration;
                    long bytes = s.Bytes; if (s.Open) { bytes = 0; foreach (RecSeg g in s.Segs) if (g.Closed) bytes += g.Size; }
                    int laps = s.Open ? s.Laps.Count : s.LapRows.Count;
                    sb.Append("{\"id\":" + Json_.S(s.Id) + ",\"track\":" + Json_.S(s.Track) + ",\"config\":" + Json_.S(s.Config) + ",\"car\":" + Json_.S(s.Car) + ",\"sessionType\":" + Json_.S(s.Type) +
                              ",\"startMs\":" + s.StartMs.ToString("0", Inv) + ",\"durationSec\":" + dur.ToString("0.000", Inv) + ",\"bytes\":" + bytes +
                              ",\"saved\":" + (s.Saved ? "true" : "false") + ",\"saveWhenDone\":" + (s.SaveWhenDone ? "true" : "false") + ",\"open\":" + (s.Open ? "true" : "false") + ",\"state\":" + Json_.S(s.Open ? "open" : (finishing.Contains(s) ? (s.State == "finalize-stalled" ? s.State : "finishing") : "finished")) +
                              ",\"uniqueId\":" + (s.UniqueId > 0 ? s.UniqueId.ToString("0", Inv) : "null") + ",\"sessionNum\":" + (s.SessionNum >= 0 ? s.SessionNum.ToString(Inv) : "null") + ",\"gaps\":" + s.Gaps.Count + ",\"saveBlocked\":" + Json_.S(s.SaveBlocked) + ",\"recovered\":" + (s.Recovered ? "true" : "false") + ",\"laps\":" + laps + ",\"incidents\":" + s.Incidents.Count + ",\"audio\":" + Json_.S(s.Open ? "" : s.Audio) + "}");
                }
                sb.Append("]}");
                return sb.ToString();
            }
        }

        public static bool ServeSession(NetworkStream s, string id, Dictionary<string, string> hdr)
        {
            string file = null;
            lock (gate) { foreach (RecSess x in sessions) if (x.Id == id) { if (x.File.Length > 0 && File.Exists(x.File)) file = x.File; break; } }
            return Vault.ServeMp4(s, file, hdr);
        }

        // A session file is only ours to delete when it lives under the vault that is active NOW. The tests switch the vault to a scratch
        // copy (vault-test\); the in-memory list used to keep Peter's real sessions, so a pretend session's retention deleted his real videos
        // (2026-10-15 and 2026-10-18: four real race videos gone).
        static bool InActiveVault(string file)
        {
            if (string.IsNullOrEmpty(file)) return false;
            try
            {
                string root = Path.GetFullPath(VaultRoot).TrimEnd('\\') + "\\";
                return Path.GetFullPath(file).StartsWith(root, StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        // The Vault moved to (or back from) the scratch folder: re-read the sessions of the vault that is active now, so the list never mixes the two.
        public static void VaultRootChanged()
        {
            try
            {
                lock (gate) { foreach (RecSess s in sessions) if (s.Open || s.Saving) return; }      // never drop a session that is being written
                LoadSessions();
            }
            catch (Exception ex) { Log.W("recorder: could not re-read sessions after the vault changed (" + ex.Message + ")"); }
        }

        // Retention: keep the last few unsaved sessions and inside the disk budgets; saved ones are never removed here.
        static void RetainSessions()
        {
            try
            {
                long recentBudget = recentBudgetBytes >= 0 ? recentBudgetBytes : (long)(RecentBudgetGb * 1024 * 1024 * 1024);
                List<RecSess> del = new List<RecSess>();
                lock (gate)
                {
                    List<RecSess> un = new List<RecSess>(); foreach (RecSess s in sessions) if (!s.Saved && !s.Saving && !s.SaveWhenDone && InActiveVault(s.File)) un.Add(s);
                    un.Sort(delegate (RecSess a, RecSess b) { return a.StartMs.CompareTo(b.StartMs); });
                    // A blip (under 90 s and no lap) is not a session worth a slot: on 2026-10-17 three of them pushed a 6-lap race and an
                    // 837 MB race out of the last-3. Blips go first (after 10 minutes), and do not count toward the last few.
                    List<RecSess> real = new List<RecSess>();
                    foreach (RecSess s in un)
                    {
                        if (!s.Open && s.Duration > 0 && s.Duration < 90 && s.LapRows.Count == 0 && WallMs() - s.Created > 600000) del.Add(s); else real.Add(s);
                    }
                    long total = 0; foreach (RecSess s in real) total += s.Bytes;
                    int n = real.Count;
                    foreach (RecSess s in real)
                    {
                        if (n <= keepSessions && total <= recentBudget) break;
                        del.Add(s); n--; total -= s.Bytes;
                    }
                    foreach (RecSess s in del) sessions.Remove(s);
                }
                foreach (RecSess s in del) { try { File.Delete(s.File); File.Delete(Path.ChangeExtension(s.File, ".json")); } catch { } Log.W("recorder: removed the oldest unsaved session " + s.Id + " (keeps the last " + keepSessions + " and " + (recentBudget / 1073741824.0).ToString("0", Inv) + " GB)"); }

                long min = (long)(MinFreeGbSession * 1073741824.0), free = FreeBytes(VaultRoot);
                if (free < min)
                {
                    if (freeOverride < 0)
                    {
                        // One at a time: delete the oldest unsaved session, measure again, then decide. (Measuring before any
                        // delete, as this once did, picked EVERY unsaved session because the free space had not changed yet.)
                        // A session someone asked to SAVE is never a candidate, even while the saved budget is full.
                        // Also stop when the bytes already removed cover the shortfall, or when a delete did not raise the free
                        // space (a player holding the file open, or the shortage is outside the vault): never empty the vault
                        // chasing space it cannot win back. A session written in the last 10 minutes is not a candidate.
                        long shortfall = min - FreeBytes(VaultRoot), freed = 0;
                        for (int guard = 0; guard < 1000 && freed < shortfall && FreeBytes(VaultRoot) < min; guard++)
                        {
                            RecSess victim = null;
                            lock (gate)
                            {
                                foreach (RecSess s in sessions)
                                    if (!s.Saved && !s.Saving && !s.SaveWhenDone && InActiveVault(s.File) && WallMs() - s.Created > 600000 && (victim == null || s.StartMs < victim.StartMs)) victim = s;
                            }
                            if (victim == null) break;
                            long before = FreeBytes(VaultRoot);
                            bool deleted = false;
                            try { File.Delete(victim.File); deleted = !File.Exists(victim.File); } catch (Exception ex) { Log.W("recorder: could not remove session " + victim.Id + " (" + ex.Message + ")"); }
                            if (!deleted) break;     // a locked file stays listed and counted; stop rather than spin
                            try { File.Delete(Path.ChangeExtension(victim.File, ".json")); } catch { }
                            lock (gate) sessions.Remove(victim);
                            freed += victim.Bytes;
                            Log.W("recorder: removed the unsaved session " + victim.Id + " - the disk is nearly full");
                            if (FreeBytes(VaultRoot) - before < victim.Bytes / 2) { Log.W("recorder: free space did not come back after removing " + victim.Id + " - stopping the clean-up"); break; }
                        }
                        PruneIncidentClips();
                        TrimClips(0, true);
                        free = FreeBytes(VaultRoot);
                    }
                    if (free < min) { diskPaused = true; note = "Disk nearly full: recording paused"; AskStop("the disk is nearly full", WallMs()); Log.W("recorder: " + note); }
                    else diskPaused = false;
                }
                else if (diskPaused) { diskPaused = false; if (note == "Disk nearly full: recording paused") note = ""; Log.W("recorder: free space is back - recording can start again"); }
            }
            catch (Exception ex) { Log.W("recorder: retention: " + ex.Message); }
        }

        // Incident clips of unsaved sessions older than the Vault's "recent" days go; a kept session's clips stay.
        static void PruneIncidentClips()
        {
            try
            {
                if (!Directory.Exists(ClipDir)) return;
                double limit = WallMs() - Vault.RecentDays * 86400000.0;
                HashSet<string> saved = new HashSet<string>(); lock (gate) foreach (RecSess s in sessions) if (s.Saved) saved.Add(s.Id);
                foreach (string f in Directory.GetFiles(ClipDir, "inc-*.json"))
                {
                    try
                    {
                        Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(File.ReadAllText(f, Encoding.UTF8)) as Dictionary<string, object>;
                        if (d == null) continue;
                        if (saved.Contains(DS(d, "session"))) continue;
                        double at = DD(d, "atMs");
                        if (at > 0 && at >= limit) continue;
                        File.Delete(f); try { File.Delete(Path.ChangeExtension(f, ".mp4")); } catch { }
                        Log.W("recorder: removed an old incident clip (" + Path.GetFileNameWithoutExtension(f) + ")");
                    }
                    catch { }
                }
            }
            catch { }
        }

        // ---------------- incident clips: 20 s before to 10 s after the incident ----------------
        static void QueueIncident(RecSess s, double now, int points)
        {
            RecInc x = new RecInc(); x.At = now; x.S = now - 20000; x.E = now + 10000; x.Points = points; x.Sess = s.Id;
            lock (gate) { incCuts.Add(x); s.Incidents.Add(new double[] { now, points }); }
            Log.W("recorder: incident +" + points + " - cutting a clip around it (20 s before, 10 s after)");
        }

        static void ResolveIncidents(double now)
        {
            lock (gate)
            {
                double lastEnd = 0; foreach (RecSeg g in segs) if (g.Closed && g.End > lastEnd) lastEnd = g.End;
                foreach (RecInc x in incCuts)
                {
                    if (x.Ready) continue;
                    bool ready = lastEnd >= x.E || (ff == null && probing == 0) || now > x.E + 30000;
                    if (!ready) continue;
                    x.Ready = true; x.Result = ""; RecInc xx = x; Enqueue(delegate () { RunIncident(xx); });
                }
            }
        }

        static void RunIncident(RecInc job)
        {
            try
            {
                if (FreeBytes(ClipDir) < (long)(MinFreeGb * 1073741824.0)) { job.Result = "no disk space"; Log.W("recorder: incident clip skipped - less than 50 GB is free"); return; }
                double S = job.S, E = job.E;
                string id = "inc-" + Stamp(job.At), mp4 = Path.Combine(ClipDir, id + ".mp4");
                List<RecSeg> all; lock (gate) { all = new List<RecSeg>(); foreach (RecSeg s in segs) if (s.Closed) all.Add(s); }
                int bestRun = -1; double bestOv = 0;
                foreach (RecSeg s in all) { double ov = Math.Min(s.End, E) - Math.Max(s.Start, S); if (ov > bestOv) { bestOv = ov; bestRun = s.Run; } }
                List<RecSeg> sel = new List<RecSeg>();
                if (bestRun >= 0)
                {
                    List<RecSeg> mine = new List<RecSeg>(); foreach (RecSeg s in all) if (s.Run == bestRun) mine.Add(s);
                    mine.Sort(delegate (RecSeg a, RecSeg b) { return a.Start.CompareTo(b.Start); });
                    foreach (RecSeg s in mine) { if (s.End <= S) continue; if (s.Start >= E) break; if (sel.Count > 0 && s.Start - sel[sel.Count - 1].End > 300) break; sel.Add(s); }
                }
                if (sel.Count == 0) { job.Result = "no video"; Log.W("recorder: no video for the incident clip (the recorder was not filming then)"); return; }
                RecSeg first = sel[0], last = sel[sel.Count - 1];
                double k0 = first.Start;
                if (S > first.Start)
                {
                    string o, e; double want = (S - first.BaseMs) / 1000.0;
                    if (RunTool(FfprobePath, "-v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 \"" + Path.Combine(RecDir, first.Name) + "\"", null, 30000, out o, out e) == 0)
                        foreach (string ln in o.Split('\n')) { string[] c = ln.Trim().Split(','); double t; if (c.Length >= 2 && c[1].IndexOf('K') >= 0 && double.TryParse(c[0], NumberStyles.Float, Inv, out t) && t <= want + 1e-6) k0 = first.BaseMs + t * 1000.0; }
                }
                double endWall = Math.Min(E, last.End);
                double ss = Math.Max(0.0, (k0 - first.BaseMs) / 1000.0 - first.FirstPts - 0.004);
                double dur = Math.Max(0.5, (endWall - k0) / 1000.0);
                StringBuilder cat = new StringBuilder("concat:");
                for (int i = 0; i < sel.Count; i++) { if (i > 0) cat.Append('|'); cat.Append(sel[i].Name); }
                try { Directory.CreateDirectory(ClipDir); } catch { }
                string tmp = mp4 + ".tmp";
                int rot = first.Rot == 3 ? 180 : first.Rot == 2 ? 90 : first.Rot == 4 ? 270 : 0;
                string pcm, aud; SoundFor("cut-" + id, new double[] { first.Start }, new double[] { endWall }, out pcm, out aud);
                string head = "-hide_banner -y -loglevel error " + (rot != 0 ? "-display_rotation " + rot + " " : "") + "-i \"" + cat + "\"";
                string tail = " -ss " + ss.ToString("0.000", Inv) + " -t " + dur.ToString("0.000", Inv) + " ";
                string fin = (first.Enc == "hevc_nvenc" ? "-tag:v hvc1 " : "") + "-movflags +faststart -f mp4 \"" + tmp + "\"";
                string args = pcm != null ? head + SoundIn(pcm) + tail + SoundOut() + fin : head + tail + "-c copy " + fin;
                string so, se2;
                int crc = RunTool(FfmpegPath, args, RecDir, 180000, out so, out se2);
                if (pcm != null && crc != 0 && crc != -1) { aud = "none"; Log.W("recorder: the incident clip could not take its sound (" + (se2 ?? "").Trim() + ") - cutting it without"); crc = RunTool(FfmpegPath, head + tail + "-c copy " + fin, RecDir, 180000, out so, out se2); }
                if (pcm != null) { try { File.Delete(pcm); } catch { } }
                if (crc != 0 || !File.Exists(tmp) || new FileInfo(tmp).Length < 1000) { if (crc == -1) { job.Result = "retry"; job.Ready = false; try { File.Delete(tmp); } catch { } return; } job.Result = "cut failed"; try { File.Delete(tmp); } catch { } Log.W("recorder: incident clip cut failed (" + ((se2 ?? "").Trim()) + ")"); return; }
                if (File.Exists(mp4)) File.Delete(mp4);
                File.Move(tmp, mp4);
                double vdur = ProbeDuration(mp4);
                string j = "{\"id\":" + Json_.S(id) + ",\"kind\":\"incident\",\"points\":" + job.Points + ",\"session\":" + Json_.S(job.Sess) + ",\"atMs\":" + job.At.ToString("0", Inv) +
                           ",\"startMs\":" + k0.ToString("0", Inv) + ",\"endMs\":" + endWall.ToString("0", Inv) + ",\"duration\":" + vdur.ToString("0.000", Inv) + ",\"rotation\":" + rot + ",\"audio\":" + Json_.S(aud) + ",\"created\":" + WallMs().ToString("0", Inv) + "}";
                File.WriteAllText(Path.ChangeExtension(mp4, ".json"), j, new UTF8Encoding(false));
                job.Result = "ok";
                Log.W("recorder: incident clip saved as " + id + " (" + vdur.ToString("0.0", Inv) + " s, " + (new FileInfo(mp4).Length / 1048576) + " MB, picture not re-encoded, " + (aud == "none" ? "no sound" : "with sound") + ")");
            }
            catch (Exception ex) { if (job.Result.Length == 0) job.Result = "error"; Log.W("recorder: incident clip: " + ex.Message); }
            finally { lock (gate) if (job.Result != "retry") job.Done = true; }
        }

        // Salvage: segments an earlier irdash left behind (a crash or a deploy) become one recovered session before the folder is wiped.
        static bool FinishLeftovers()
        {
            try
            {
                if (!Directory.Exists(RecDir)) return true;
                string[] files = Directory.GetFiles(RecDir, "*.ts");
                if (files.Length == 0) return true;
                if (FreeBytes(SessDir) < (long)(MinFreeGb * 1073741824.0)) return false;
                if (!RecAudio.Running) RecAudio.Adopt(RecDir);       // its sound chunks are named by their start: they come along
                List<RecSeg> sel = new List<RecSeg>();
                foreach (string path in files)
                {
                    try
                    {
                        string name = Path.GetFileName(path); double start;
                        Match m = Regex.Match(name, "^rec-(\\d{4})(\\d{2})(\\d{2})-(\\d{2})(\\d{2})(\\d{2})-(\\d{3})\\.ts$");
                        if (m.Success)
                        {
                            DateTime dt = new DateTime(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value), int.Parse(m.Groups[4].Value), int.Parse(m.Groups[5].Value), int.Parse(m.Groups[6].Value), DateTimeKind.Utc);
                            start = (dt - Epoch).TotalMilliseconds + int.Parse(m.Groups[7].Value);
                        }
                        else start = (File.GetLastWriteTimeUtc(path) - Epoch).TotalMilliseconds;
                        double d = ProbeDuration(path);
                        RecSeg g = new RecSeg(); g.Name = name; g.Start = start; g.End = start + (d > 0 ? d * 1000.0 : 0); g.Closed = true; g.Size = new FileInfo(path).Length; g.Rot = 3; g.BaseMs = start;
                        sel.Add(g);
                    }
                    catch { }
                }
                if (sel.Count == 0) return false;
                sel.Sort(delegate (RecSeg a, RecSeg b) { return a.Start.CompareTo(b.Start); });
                RecSess s = new RecSess(); s.Open = false; s.Recovered = true; s.StartMs = sel[0].Start; s.EndMs = sel[sel.Count - 1].End; s.Created = (long)WallMs();
                s.Id = "recovered-" + Stamp(s.StartMs); s.Segs = sel;
                Log.W("recorder: found " + sel.Count + " leftover video segments from an earlier run - keeping them as one session");
                FinishSession(s, false);
                string finished = Path.Combine(SessDir, s.Id + ".mp4");
                if (!File.Exists(finished)) return false;
                foreach (string path in files) if (File.Exists(path)) return false;
                return true;
            }
            catch (Exception ex) { Log.W("recorder: recovered session: " + ex.Message); return false; }
        }

        // ---------------- test routes (only while dash\test-hook.on exists and the Vault sandbox is on) ----------------
        static int SafePid() { try { return ff.Id; } catch { return 0; } }
        static string Err(string m) { return "{\"error\":" + Json_.S(m) + "}"; }
        static string Q(Dictionary<string, string> q, string k) { string v; return q.TryGetValue(k, out v) ? v : ""; }

        static void TestOff()
        {
            double now = WallMs();
            if (ff != null) { AskStop("test over", now); for (int i = 0; i < 60 && ff != null; i++) { try { if (ff.HasExited) break; } catch { break; } Thread.Sleep(150); } if (ff != null) { try { if (!ff.HasExited) ff.Kill(); } catch { } try { ReadList(run); ff.Dispose(); } catch { } ff = null; expectStop = false; } }
            RecAudio.Stop(); testAudio = "off";
            testOn = false; source = "screen"; keepOverrideSec = 0; segSecs = 10; graceSecs = 20; minLap = 15; testBar = 0; testBlack = false; freeOverride = -1; gaveUp = false; restarts = 0; encoder = "hevc_nvenc"; fellBack = false;
            openSess = null; diskPaused = false; recState = ""; keepSessions = 3; recentBudgetBytes = -1; savedBudgetBytes = -1;
            lock (gate) { segs.Clear(); cuts.Clear(); incCuts.Clear(); probing = 0; clips.Clear(); }
            ResetTracker(); haveConn = false; sessNum = -99; black = false; blackChecked = false; note = "";
            if (!enabled) { try { WipeRecDir(); } catch { } }
        }

        public static string TestRoute(string path, Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (path == "/vault/test/recmap")
            {
                // which output number is which monitor, and the one that would be recorded
                List<RecDxgi.Out> all = RecDxgi.All(); string why; RecDxgi.Out mid = RecDxgi.Middle(all, out why);
                StringBuilder sb = new StringBuilder("{\"outputs\":[");
                for (int i = 0; i < all.Count; i++)
                {
                    RecDxgi.Out o = all[i]; if (i > 0) sb.Append(',');
                    sb.Append("{\"adapter\":" + o.Adapter + ",\"index\":" + o.Index + ",\"x\":" + o.L + ",\"y\":" + o.T + ",\"w\":" + o.W + ",\"h\":" + o.H + ",\"rotation\":" + o.Rotation + ",\"attached\":" + (o.Attached ? "true" : "false") + ",\"device\":" + Json_.S(o.Device) + ",\"adapterName\":" + Json_.S(o.AdapterName) + "}");
                }
                sb.Append("],\"middle\":" + (mid == null ? "null" : "{\"adapter\":" + mid.Adapter + ",\"index\":" + mid.Index + ",\"x\":" + mid.L + ",\"y\":" + mid.T + ",\"w\":" + mid.W + ",\"h\":" + mid.H + ",\"rotation\":" + mid.Rotation + "}") + ",\"why\":" + Json_.S(why) + "}");
                return sb.ToString();
            }
            if (path == "/vault/test/recswitch") return "{\"on\":" + (ParseSwitch(Q(q, "text")) ? "true" : "false") + ",\"enabled\":" + (enabled ? "true" : "false") + ",\"audioOn\":" + (ParseAudioSwitch(Q(q, "text")) ? "true" : "false") + ",\"audioMode\":" + Json_.S(audioMode) + "}";
            if (!Vault.SandboxOn) { code = 409; return Err("start the Vault sandbox first (/vault/test/sandbox?on=1)"); }
            if (Q(q, "cmd") == "buildargs")
            {
                // Let the guarded test build the real-screen command without starting a recorder process.
                string why; RecDxgi.Out mid = RecDxgi.Middle(RecDxgi.All(), out why);
                if (mid == null) { code = 409; return Err("could not find the middle screen (" + why + ")"); }
                RecRun r = new RecRun(); r.No = ++runNo; r.BaseMs = Math.Floor(WallMs() / 1000.0) * 1000.0; r.Rot = mid.Rotation; r.Encoder = "hevc_nvenc";
                r.List = Path.Combine(RecDir, "list-" + r.No + ".csv"); r.StartMs = WallMs();
                string args = BuildArgs(r, mid.Index, mid.Adapter, r.Encoder);
                return "{\"outputIdx\":" + mid.Index + ",\"outputRect\":" + Json_.S(mid.Rect) + ",\"args\":" + Json_.S(args) + "}";
            }
            switch (Q(q, "cmd"))
            {
                case "on":
                    {
                        TestOff();
                        int v; double d;
                        keepOverrideSec = int.TryParse(Q(q, "keep"), out v) && v > 5 ? v : 0; segSecs = int.TryParse(Q(q, "seg"), out v) && v >= 3 && v <= 60 ? v : 10; graceSecs = int.TryParse(Q(q, "grace"), out v) && v >= 0 ? v : 20;
                        minLap = double.TryParse(Q(q, "minlap"), NumberStyles.Float, Inv, out d) && d >= 0 ? d : 15; testBar = double.TryParse(Q(q, "bar"), NumberStyles.Float, Inv, out d) && d > 0 ? d : 0; testBlack = Q(q, "black") == "1";
                        try { Directory.CreateDirectory(RecDir); Directory.CreateDirectory(ClipDir); foreach (string f in Directory.GetFiles(RecDir)) File.Delete(f); foreach (string f in Directory.GetFiles(ClipDir, "rec-*")) File.Delete(f); } catch { }
                        RecAudio.ForgetMissing();
                        // the sound of a test: off (default), synth (clicks on every whole second), system, or pid:<n> (one program, e.g. a tone player)
                        string am = Q(q, "audio"); testAudio = am == "synth" || am == "system" || Regex.IsMatch(am, "^pid:[0-9,]+$") ? am : "off";
                        testOn = true; source = Q(q, "source") == "screen" ? "screen" : "test"; lastHookCheck = WallMs();
                        if (Q(q, "enc") == "libx264") { encoder = "libx264"; fellBack = true; }      // the CPU fallback, on purpose
                        EnsureLoop();
                        return StatusJson();
                    }
                case "off": TestOff(); return StatusJson();
                case "status": return StatusJson();
                case "free": { long b; freeOverride = long.TryParse(Q(q, "bytes"), out b) && b >= 0 ? b : -1; return "{\"ok\":true,\"free\":" + freeOverride + "}"; }
                case "reindex": LoadClips(); return "{\"ok\":true,\"clips\":" + clips.Count + "}";
                case "keep": { int n; bool ok = int.TryParse(Q(q, "lap"), out n) && Keep(n); return "{\"ok\":" + (ok ? "true" : "false") + "}"; }
                case "lap":
                    {
                        // a lap handed in directly (the telemetry detector is tested with a pretend session instead)
                        if (!testOn) { code = 409; return Err("switch the test recorder on first (cmd=on)"); }
                        RecLap l = new RecLap(); int n; double st, en, tm;
                        if (!int.TryParse(Q(q, "n"), out n) || !double.TryParse(Q(q, "start"), NumberStyles.Float, Inv, out st) || !double.TryParse(Q(q, "end"), NumberStyles.Float, Inv, out en) || !double.TryParse(Q(q, "time"), NumberStyles.Float, Inv, out tm)) { code = 400; return Err("n, start, end, time (ms since 1970, seconds) are needed"); }
                        l.N = n; l.Start = st; l.End = en; l.Time = tm; l.Ended = true; l.Resolved = true; l.Bar = KnownBar(); l.Pit = Q(q, "pit") == "1"; l.Off = Q(q, "off") == "1"; l.Dirty = Q(q, "dirty") == "1"; l.Keep = Q(q, "keep") == "1";
                        l.Car = Q(q, "car"); l.Track = Q(q, "track"); l.Config = Q(q, "config");
                        lock (gate) { recent.Add(l); if (openSess != null && !openSess.Laps.Contains(l)) openSess.Laps.Add(l); }
                        if (tm > longestLap) longestLap = tm;
                        Decide(l);
                        return "{\"ok\":true,\"why\":" + Json_.S(l.Why) + ",\"clipId\":" + Json_.S(ClipId(l)) + "}";
                    }
                case "sessions": return SessionsJson();
                case "save": return "{\"state\":" + Json_.S(Save(Q(q, "id"))) + "}";
                case "start": enabled = true; Start(); return SessionsJson();
                case "retain": RetainSessions(); return SessionsJson();
                case "reload": LoadSessions(); return SessionsJson();
                case "salvage": FinishLeftovers(); return SessionsJson();
                case "budgets":
                    {
                        int v;
                        if (Q(q, "keep").Length > 0) keepSessions = int.TryParse(Q(q, "keep"), out v) && v >= 0 ? v : 3;
                        long b;
                        recentBudgetBytes = long.TryParse(Q(q, "recent"), out b) && b >= 0 ? b : -1;
                        savedBudgetBytes = long.TryParse(Q(q, "saved"), out b) && b >= 0 ? b : -1;
                        return "{\"ok\":true,\"keep\":" + keepSessions + ",\"recent\":" + recentBudgetBytes + ",\"saved\":" + savedBudgetBytes + "}";
                    }
            }
            code = 404; return Err("not found");
        }
    }
}
