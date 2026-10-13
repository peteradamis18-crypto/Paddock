// Replay (WS15 in docs\SPEC-next.md): the REPLAY screen on the Stream Deck - iRacing's replay without its menus.
// irdash side: /replay JSON for the add-on, and the whitelisted REPLAY key presses (routed here from /api/do). Presses
// become iRacing SDK broadcast messages (IRSDK_BROADCASTMSG) sent straight from irdash: no clicks, no keys, no focus,
// no exe start per press. State comes from irdash's own SDK frames (Sdk.Latest) and the session YAML.
// While the test hook's pretend session is on, messages are RECORDED (/api/test/replaylog) and never broadcast.
// Never sent: ReplaySetState (msg 6) - it erases the tape. Nothing here writes iRacing's own files.
// Owned by the replay workstream; irdash.cs only calls Init / Handles / Do / Json (+ the test log route).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class RpNative
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string s);
        [DllImport("user32.dll")] public static extern bool SendNotifyMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    }

    static partial class Replay      // partial: the jump to a moment of a session (replayjump.cs, P2)
    {
        static string dir;       // <root>\replay (only the pretend-session test folders live here)
        static string rootDir;   // <root>
        static readonly object gate = new object();
        static readonly HashSet<string> Commands = new HashSet<string> {
            "rpjump", "rpsession", "rplive", "rpstart", "rplapprev", "rplapnext", "rprew", "rpplay", "rpfast", "rpslow", "rpback10",
            "rpincprev", "rpincnext", "rpmycar", "rpahead", "rpbehind", "rpleader", "rpcar", "rpmyinc",
            "rpcamprev", "rpcamnext", "rpgroup", "rpautotv", "rphideui", "rpphoto" };

        // set only by a scratch test program that compiles this file; production never sets it
        internal static bool ForceRecord;
        static bool Recording { get { return ForceRecord || Sdk.Pretend; } }

        const int UiHidden = 0x08, AutoShot = 0x10, Settable = 0x1FC;   // CamCameraState bits we may set (not the read-only "session screen" bits)
        const int EchoMs = 250;                                          // the same press again within this long is an echo, ignored
        static readonly int[] FastLadder = { 2, 4, 8, 16 }, RewLadder = { 1, 2, 4, 8, 16 }, SlowLadder = { 1, 3, 7 };   // slow motion: raw N plays at 1/(N+1)
        static readonly int[] AllowedMsgs = { 0, 1, 2, 3, 4, 5, 12, 13 };

        public static void Init(string d)
        {
            dir = d; rootDir = Path.GetDirectoryName(d);
            try { Directory.CreateDirectory(dir); } catch { }
        }
        public static bool Handles(string c) { return Commands.Contains(c ?? ""); }

        // ================= small data classes =================
        sealed class Msg { public int Id, V1, V2; }
        sealed class Step { public int Msg, V1, V2, Wait; }
        sealed class Hold { public double V; public DateTime Until; }
        sealed class Cam { public int Num, Count; public string Name = ""; public bool Scenic; }
        sealed class Drv { public int Idx, Raw; public string Name = "", Num = "", Class = "", Color = ""; public bool Pace, Spectator; }
        sealed class Ses { public int Num, Laps; public string Name = "", Type = ""; public double Limit; public bool Skipped; }

        // a list of messages (and waits) sent one after the other
        sealed class Seq
        {
            public readonly List<Step> L = new List<Step>();
            public Seq M(int msg, int v1, int v2) { Step s = new Step(); s.Msg = msg; s.V1 = v1; s.V2 = v2; L.Add(s); return this; }
            public Seq W(int ms) { Step s = new Step(); s.Wait = ms; L.Add(s); return this; }
            public string Describe()
            {
                var parts = new List<string>();
                foreach (Step s in L) if (s.Wait == 0) parts.Add(MsgName(s.Msg) + " " + s.V1 + " " + s.V2);
                return string.Join(", ", parts.ToArray());
            }
        }

        // everything the keys need to know right now (telemetry with the last presses laid over it)
        sealed class Snap
        {
            public Frame F; public bool Connected, OnTrack, Replaying, Driving, Slow, AtLive;
            public int Raw, ReplaySess, LiveSess, FramesEnd, CamCar, CamGroup, CamCamera, CamState, Me;
            public double ReplayTime, LiveTime, Rate;
            public string Mode = "live";
            public int Sess { get { return Replaying ? ReplaySess : LiveSess; } }
            public double Time { get { return Replaying ? ReplayTime : LiveTime; } }
        }

        // ================= telemetry, with the last presses laid over it for a moment =================
        // A press changes what the keys should show at once; the sim confirms a few frames later. Until then (1.5 s) we answer
        // with what we just asked for, so the next press (cycling REWIND, FAST ...) builds on it and the keys do not flicker.
        static readonly Dictionary<string, Hold> holds = new Dictionary<string, Hold>();
        static double Hv(Frame f, string name)
        {
            lock (gate)
            {
                Hold h;
                if (holds.TryGetValue(name, out h)) { if (DateTime.UtcNow < h.Until) return h.V; holds.Remove(name); }
            }
            return f.Num(name);
        }
        static void SetHold(string name, double v) { lock (gate) { Hold h = new Hold(); h.V = v; h.Until = DateTime.UtcNow.AddMilliseconds(1500); holds[name] = h; } }
        static void SetSpeedHold(int raw, bool slow) { SetHold("IsReplayPlaying", 1); SetHold("ReplayPlaySpeed", raw); SetHold("ReplayPlaySlowMotion", slow ? 1 : 0); }

        // one slot of an int array (CarIdxPosition ...)
        static int At(Frame f, string name, int idx)
        {
            VarDef d;
            if (!f.Connected || f.Vars == null || !f.Vars.TryGetValue(name, out d) || idx < 0 || idx >= d.Count) return 0;
            int p = d.Offset + idx * 4;
            if (p < 0 || p + 4 > f.Data.Length) return 0;
            return d.Type == 4 ? (int)BitConverter.ToSingle(f.Data, p) : BitConverter.ToInt32(f.Data, p);
        }

        static Snap Read()
        {
            Snap s = new Snap(); Frame f = Sdk.Latest; s.F = f; s.Connected = f.Connected;
            if (!s.Connected) { lock (gate) { maxT.Clear(); } return s; }
            EnsureYaml(f);
            s.OnTrack = Hv(f, "IsOnTrack") != 0;
            s.Replaying = Hv(f, "IsReplayPlaying") != 0;
            s.Driving = s.OnTrack && !s.Replaying;       // in the car and not watching a replay of it
            s.Raw = (int)Hv(f, "ReplayPlaySpeed"); s.Slow = Hv(f, "ReplayPlaySlowMotion") != 0;
            s.LiveSess = (int)Hv(f, "SessionNum"); s.LiveTime = Hv(f, "SessionTime");
            s.ReplaySess = (int)Hv(f, "ReplaySessionNum"); s.ReplayTime = Hv(f, "ReplaySessionTime");
            s.FramesEnd = (int)Hv(f, "ReplayFrameNumEnd");
            s.CamCar = (int)Hv(f, "CamCarIdx"); s.CamGroup = (int)Hv(f, "CamGroupNumber"); s.CamCamera = (int)Hv(f, "CamCameraNumber");
            s.CamState = (int)Hv(f, "CamCameraState");
            lock (gate) { s.Me = yMe >= 0 ? yMe : (int)f.Num("PlayerCarIdx"); }
            if (!s.Replaying) { s.Mode = "live"; s.Rate = 1; }
            else if (s.Raw == 0) { s.Mode = "paused"; s.Rate = 0; }
            else if (s.Slow) { s.Rate = Math.Sign(s.Raw) / (Math.Abs(s.Raw) + 1.0); s.Mode = s.Raw > 0 ? "slow" : "slowrew"; }
            else { s.Rate = s.Raw; s.Mode = s.Raw == 1 ? "play" : s.Raw > 1 ? "fast" : "rewind"; }
            // Out of the car at the live edge the sim may still report "replay playing" with next to nothing left to the end
            // of the tape (5 frames = 0.08 s): that is live, whatever the flag says.
            s.AtLive = !s.Replaying || (s.Mode == "play" && s.ReplaySess == s.LiveSess && s.FramesEnd <= 5);
            if (s.Replaying && s.AtLive) { s.Mode = "live"; s.Rate = 1; }
            Track(s);
            return s;
        }

        // ================= the session YAML: cameras, drivers, sessions (read again only when it changes) =================
        static int yVer = -1, yLen = -1, yMe = -1; static string ySub = "";
        static List<Cam> cams = new List<Cam>(); static List<Drv> drivers = new List<Drv>(); static List<Ses> sessions = new List<Ses>();

        static string Section(string y, string key)
        {
            Match m = Regex.Match(y, "(?m)^" + key + ":");
            if (!m.Success) return "";
            string rest = y.Substring(m.Index + m.Length);
            Match n = Regex.Match(rest, "(?m)^[A-Za-z]");     // the next top-level key
            return n.Success ? rest.Substring(0, n.Index) : rest;
        }
        static string Val(string block, string key)
        {
            Match m = Regex.Match(block, "(?m)^[ \\t]*" + key + ":[ \\t]*([^\\r\\n]*?)[ \\t]*\\r?$");
            return m.Success ? m.Groups[1].Value.Trim().Trim('"') : "";
        }
        static int Lead(string chunk) { Match m = Regex.Match(chunk, "^\\s*(-?\\d+)"); int n; return m.Success && int.TryParse(m.Groups[1].Value, out n) ? n : -1; }
        static int IntOf(string s, int dflt) { int n; return int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out n) ? n : dflt; }

        static void EnsureYaml(Frame f)
        {
            string y = f.SessionYaml ?? "";
            lock (gate)
            {
                if (f.SessionVersion == yVer && y.Length == yLen) return;
                yVer = f.SessionVersion; yLen = y.Length;
                var nc = new List<Cam>(); var nd = new List<Drv>(); var ns = new List<Ses>(); int me = -1;
                try
                {
                    string[] parts = Regex.Split(Section(y, "CameraInfo"), "(?m)^[ \\t]*- GroupNum:");
                    for (int i = 1; i < parts.Length; i++)
                    {
                        Cam c = new Cam(); c.Num = Lead(parts[i]); c.Name = Val(parts[i], "GroupName"); c.Scenic = Val(parts[i], "IsScenic") == "true";
                        c.Count = Regex.Matches(parts[i], "CameraNum:").Count;
                        if (c.Num > 0) nc.Add(c);
                    }
                    string di = Section(y, "DriverInfo");
                    me = IntOf(Val(di, "DriverCarIdx"), -1);
                    parts = Regex.Split(di, "(?m)^[ \\t]*- CarIdx:");
                    for (int i = 1; i < parts.Length; i++)
                    {
                        Drv d = new Drv(); d.Idx = Lead(parts[i]); d.Name = Val(parts[i], "UserName"); d.Num = Val(parts[i], "CarNumber");
                        d.Raw = IntOf(Val(parts[i], "CarNumberRaw"), IntOf(d.Num, 0)); d.Class = Val(parts[i], "CarClassID");
                        string col = Val(parts[i], "CarClassColor"); d.Color = Regex.IsMatch(col, "^0x[0-9a-fA-F]{6}$") ? "#" + col.Substring(2).ToLowerInvariant() : "";
                        d.Pace = Val(parts[i], "CarIsPaceCar") == "1"; d.Spectator = Val(parts[i], "IsSpectator") == "1";
                        if (d.Idx >= 0) nd.Add(d);
                    }
                    parts = Regex.Split(Section(y, "SessionInfo"), "(?m)^[ \\t]*- SessionNum:");
                    for (int i = 1; i < parts.Length; i++)
                    {
                        Ses e = new Ses(); e.Num = Lead(parts[i]); e.Type = Val(parts[i], "SessionType"); e.Name = Val(parts[i], "SessionName");
                        e.Laps = IntOf(Val(parts[i], "SessionLaps"), 0); e.Skipped = Val(parts[i], "SessionSkipped") == "1";
                        double lim; string tl = Val(parts[i], "SessionTime"); int sp = tl.IndexOf(' '); if (sp > 0) tl = tl.Substring(0, sp);
                        e.Limit = double.TryParse(tl, NumberStyles.Float, CultureInfo.InvariantCulture, out lim) ? lim : 0;
                        if (e.Num >= 0) ns.Add(e);
                    }
                    string sub = Val(Section(y, "WeekendInfo"), "SubSessionID");
                    if (sub != ySub) { ySub = sub; maxT.Clear(); }
                }
                catch (Exception ex) { Log.W("replay: could not read the session info: " + ex.Message); }
                cams = nc; drivers = nd; sessions = ns; yMe = me;
            }
        }

        static Drv FindDrv(int idx) { lock (gate) { foreach (Drv d in drivers) if (d.Idx == idx) return d; } return null; }
        static Cam FindCam(int num) { lock (gate) { foreach (Cam c in cams) if (c.Num == num) return c; } return null; }
        static Ses FindSes(int num) { lock (gate) { foreach (Ses e in sessions) if (e.Num == num) return e; } return null; }

        static string SesName(Ses e)
        {
            if (e == null) return "SESSION";
            string n = (e.Name.Length > 0 ? e.Name : e.Type).ToUpperInvariant();
            if (n.Contains("QUAL")) return "QUALIFY";
            if (n.Contains("PRACTICE")) return "PRACTICE";
            if (n.Contains("RACE")) return "RACE";
            if (n.Contains("TEST")) return "TESTING";
            if (n.Contains("WARM")) return "WARM UP";
            return n.Length > 0 ? n : "SESSION";
        }

        // the sessions that can be on the tape: up to the one running now, skipped ones left out
        static List<Ses> OnTape(Snap s)
        {
            var l = new List<Ses>();
            lock (gate) { foreach (Ses e in sessions) if (e.Num <= s.LiveSess && !e.Skipped) l.Add(e); }
            return l;
        }

        // ================= how long is a session? (for the timeline) =================
        // The live session: the time it has now (a replay position plus the time left to the end of the tape gives the same).
        // An older one: the longest time we saw while it was live. Last resort: its time limit, if it has a real one.
        static readonly Dictionary<int, double> maxT = new Dictionary<int, double>();
        static void Track(Snap s)
        {
            lock (gate)
            {
                double b;
                if (s.LiveTime > 0) { maxT.TryGetValue(s.LiveSess, out b); if (s.LiveTime > b) maxT[s.LiveSess] = s.LiveTime; }
                if (s.Replaying && s.ReplayTime > 0) { maxT.TryGetValue(s.ReplaySess, out b); if (s.ReplayTime > b) maxT[s.ReplaySess] = s.ReplayTime; }
            }
        }
        static double SessionLen(Snap s, int sn)
        {
            double best = 0;
            lock (gate) { maxT.TryGetValue(sn, out best); }
            if (sn == s.LiveSess)
            {
                double l = s.Replaying && s.ReplaySess == sn ? s.ReplayTime + s.FramesEnd / 60.0 : s.LiveTime;   // the tape runs at 60 frames a second
                if (l > best) best = l;
            }
            if (best > 1) return best;
            Ses e = FindSes(sn);
            return e != null && e.Limit > 0 && e.Limit < 80000 ? e.Limit : -1;
        }

        // ================= sending =================
        static readonly List<Msg> sent = new List<Msg>();
        static uint bcastId;

        static string MsgName(int m)
        {
            switch (m)
            {
                case 0: return "CamSwitchPos"; case 1: return "CamSwitchNum"; case 2: return "CamSetState"; case 3: return "ReplaySetPlaySpeed";
                case 4: return "ReplaySetPlayPosition"; case 5: return "ReplaySearch"; case 12: return "ReplaySearchSessionTime"; case 13: return "VideoCapture";
            }
            return "msg" + m;
        }

        // the same packing irdeck's Bcast uses: wParam = MAKELONG(msg, var1), lParam = var2
        static void Bcast(int msg, int v1, int v2)
        {
            if (msg == 6) { Log.W("replay: refused to send ReplaySetState (it erases the tape)"); return; }
            if (Array.IndexOf(AllowedMsgs, msg) < 0) { Log.W("replay: refused to send message " + msg); return; }
            lock (gate)
            {
                if (Recording) { Msg m = new Msg(); m.Id = msg; m.V1 = v1; m.V2 = v2; sent.Add(m); if (sent.Count > 500) sent.RemoveAt(0); return; }
            }
            if (bcastId == 0) bcastId = RpNative.RegisterWindowMessage("IRSDK_BROADCASTMSG");
            IntPtr w = new IntPtr(unchecked((int)(((ushort)msg) | ((uint)(ushort)v1 << 16))));
            RpNative.SendNotifyMessage(new IntPtr(0xFFFF), bcastId, w, new IntPtr(v2));
        }

        static readonly Queue<List<Step>> work = new Queue<List<Step>>(); static Thread worker;
        // presses are sent in order from one thread, so a press never waits for the one before it and the answer to the deck is instant
        static void Go(Seq q)
        {
            if (Recording) { foreach (Step st in q.L) if (st.Wait == 0) Bcast(st.Msg, st.V1, st.V2); return; }
            lock (work)
            {
                work.Enqueue(q.L);
                if (worker == null) { worker = new Thread(Work); worker.IsBackground = true; worker.Start(); }
                Monitor.Pulse(work);
            }
        }
        static void Work()
        {
            while (true)
            {
                List<Step> steps;
                lock (work) { while (work.Count == 0) Monitor.Wait(work); steps = work.Dequeue(); }
                foreach (Step st in steps)
                {
                    try { if (st.Wait > 0) Thread.Sleep(st.Wait); else Bcast(st.Msg, st.V1, st.V2); }
                    catch (Exception ex) { Log.W("replay: send: " + ex.Message); }
                }
            }
        }

        static readonly Dictionary<string, DateTime> lastPress = new Dictionary<string, DateTime>();
        static bool Echo(string key)
        {
            lock (gate)
            {
                DateTime t, now = DateTime.UtcNow;
                if (lastPress.TryGetValue(key, out t) && (now - t).TotalMilliseconds < EchoMs) return true;
                lastPress[key] = now; return false;
            }
        }

        // ================= test hook =================
        public static string TestLog(bool clear)
        {
            lock (gate)
            {
                var items = new List<string>();
                foreach (Msg m in sent) items.Add("{\"m\":" + m.Id + ",\"a\":" + m.V1 + ",\"b\":" + m.V2 + ",\"n\":" + Json_.S(MsgName(m.Id)) + "}");
                string j = "{\"recording\":" + B(Recording) + ",\"msgs\":[" + string.Join(",", items.ToArray()) + "]}";
                if (clear) { sent.Clear(); holds.Clear(); lastPress.Clear(); photoState = "idle"; }
                return j;
            }
        }

        // ================= the presses =================
        static int Pack(int group, int camera) { return (group & 0xFFFF) | (camera << 16); }   // MAKELONG(group, camera)

        public static bool Do(string c, string a)
        {
            a = (a ?? "").Trim();
            try { return DoInner(c, a); }
            catch (Exception ex) { Log.W("replay: " + c + ": " + ex.Message); return false; }
        }

        static bool DoInner(string c, string a)
        {
            if (!Commands.Contains(c)) return false;
            Snap s = Read();
            if (!s.Connected) { Log.W("replay: " + c + " - no session, nothing sent"); return false; }
            if (s.Driving) { Log.W("replay: " + c + " - you are driving, nothing sent"); return false; }
            if (Echo(c + "|" + a)) return true;
            Seq q = new Seq();
            int g, cm;
            switch (c)
            {
                case "rplive":
                    q.M(5, 1, 0).W(100).M(3, 1, 0);
                    SetHold("IsReplayPlaying", 0); SetHold("ReplayPlaySpeed", 1); SetHold("ReplayPlaySlowMotion", 0);
                    break;
                case "rpstart":
                    q.M(12, s.Sess, 0);
                    SetHold("IsReplayPlaying", 1); SetHold("ReplaySessionNum", s.Sess); SetHold("ReplaySessionTime", 0);
                    break;
                case "rpjump":
                    {
                        int i = IntOf(a, -1); double len = SessionLen(s, s.Sess);
                        if (i < 0 || i > 4 || len <= 0) { Log.W("replay: jump " + a + " - the length of this session is not known"); return false; }
                        double t = len * (i + 0.5) / 5.0;                    // the middle of the fifth that was tapped
                        q.M(12, s.Sess, (int)Math.Round(t * 1000));
                        SetHold("IsReplayPlaying", 1); SetHold("ReplaySessionNum", s.Sess); SetHold("ReplaySessionTime", t);
                        if (s.Sess == s.LiveSess) SetHold("ReplayFrameNumEnd", Math.Round((len - t) * 60));
                        break;
                    }
                case "rpsession":
                    {
                        List<Ses> tape = OnTape(s);
                        if (tape.Count < 2) return false;
                        int at = tape.FindIndex(delegate (Ses e) { return e.Num == s.Sess; });
                        Ses next = tape[(at + 1) % tape.Count];
                        q.M(12, next.Num, 0);
                        SetHold("IsReplayPlaying", 1); SetHold("ReplaySessionNum", next.Num); SetHold("ReplaySessionTime", 0);
                        break;
                    }
                case "rplapprev": q.M(5, 4, 0); SetHold("IsReplayPlaying", 1); break;
                case "rplapnext": q.M(5, 5, 0); SetHold("IsReplayPlaying", 1); break;
                case "rprew":
                    if (s.Mode == "paused") { q.M(5, 6, 0); break; }                // paused: one frame back
                    {
                        int n = NextStep(s.Mode == "rewind" ? -s.Raw : 0, RewLadder);   // 0 = the end of the ladder: back to normal
                        if (n == 0) { q.M(3, 1, 0); SetSpeedHold(1, false); } else { q.M(3, -n, 0); SetSpeedHold(-n, false); }
                        break;
                    }
                case "rpfast":
                    if (s.Mode == "paused") { q.M(5, 7, 0); break; }                // paused: one frame on
                    {
                        int n = NextStep(s.Mode == "fast" ? s.Raw : 0, FastLadder);
                        if (n == 0) { q.M(3, 1, 0); SetSpeedHold(1, false); } else { q.M(3, n, 0); SetSpeedHold(n, false); }
                        break;
                    }
                case "rpslow":
                    {
                        int n = NextStep(s.Mode == "slow" ? s.Raw : 0, SlowLadder);
                        if (n == 0) { q.M(3, 1, 0); SetSpeedHold(1, false); } else { q.M(3, n, 1); SetSpeedHold(n, true); }
                        break;
                    }
                case "rpplay":
                    if (s.Mode == "paused") { q.M(3, 1, 0); SetSpeedHold(1, false); }
                    else { q.M(3, 0, 0); SetSpeedHold(0, false); }
                    break;
                case "rpback10":
                    {
                        int ms = (int)Math.Max(0, Math.Round((s.Time - 10) * 1000));
                        q.M(12, s.Sess, ms).W(100).M(3, 1, 0);
                        SetSpeedHold(1, false); SetHold("ReplaySessionNum", s.Sess); SetHold("ReplaySessionTime", ms / 1000.0);
                        break;
                    }
                case "rpincprev": q.M(5, 8, 0).W(100).M(3, 1, 0); SetSpeedHold(1, false); break;
                case "rpincnext": q.M(5, 9, 0).W(100).M(3, 1, 0); SetSpeedHold(1, false); break;
                case "rpmyinc":
                    {
                        // what the old REPLAY key did: your last incident, played. From the end of the tape, on your car.
                        Drv me = FindDrv(s.Me);
                        if (s.Replaying) q.M(5, 1, 0).W(100);
                        q.M(5, 8, 0).W(100);
                        if (me != null) { CamSpec(s, out g, out cm); q.M(1, me.Raw, Pack(g, cm)).W(50); SetHold("CamCarIdx", me.Idx); }
                        q.M(3, 1, 0); SetSpeedHold(1, false);
                        break;
                    }
                case "rpmycar":
                    {
                        Drv me = FindDrv(s.Me); if (me == null) return false;
                        CamSpec(s, out g, out cm); q.M(1, me.Raw, Pack(g, cm)); SetHold("CamCarIdx", me.Idx);
                        break;
                    }
                case "rpahead":
                case "rpbehind":
                    {
                        Drv d = Neighbour(s, c == "rpahead" ? -1 : 1); if (d == null) return false;
                        CamSpec(s, out g, out cm); q.M(1, d.Raw, Pack(g, cm)); SetHold("CamCarIdx", d.Idx);
                        break;
                    }
                case "rpcar":
                    {
                        Drv d = FindDrv(IntOf(a, -1)); if (d == null || d.Pace) return false;
                        CamSpec(s, out g, out cm); q.M(1, d.Raw, Pack(g, cm)); SetHold("CamCarIdx", d.Idx);
                        break;
                    }
                case "rpleader":
                    {
                        CamSpec(s, out g, out cm); q.M(0, -2, Pack(g, cm));          // -2 = "follow the leader" (the SDK's special focus)
                        Drv lead = CarAtPosition(s, 1); if (lead != null) SetHold("CamCarIdx", lead.Idx);
                        break;
                    }
                case "rpcamprev":
                case "rpcamnext":
                    {
                        List<int[]> list = CamList(); if (list.Count == 0) return false;
                        int at = list.FindIndex(delegate (int[] p) { return p[0] == s.CamGroup && p[1] == s.CamCamera; });
                        int k = at < 0 ? 0 : (at + (c == "rpcamnext" ? 1 : list.Count - 1)) % list.Count;
                        SendCam(q, s, list[k][0], list[k][1]);
                        break;
                    }
                case "rpgroup":
                    {
                        Cam grp = GroupByKind(a); if (grp == null) return false;
                        SendCam(q, s, grp.Num, s.CamGroup == grp.Num && s.CamCamera > 0 ? s.CamCamera : 1);
                        break;
                    }
                case "rpautotv":
                case "rphideui":
                    {
                        int bit = c == "rpautotv" ? AutoShot : UiHidden;
                        int bits = (s.CamState & Settable) ^ bit;
                        q.M(2, bits, 0); SetHold("CamCameraState", bits);
                        break;
                    }
                case "rpphoto":
                    return StartPhoto(s);
                default: return false;
            }
            Log.W("replay: " + (Recording ? "(pretend session, not sent) " : "") + c + (a.Length > 0 ? " " + a : "") + " -> " + q.Describe());
            Go(q);
            return true;
        }

        // the next speed on a ladder after "cur" (0 = not on it); 0 back = past the end, go back to normal
        static int NextStep(int cur, int[] ladder)
        {
            if (cur <= 0) return ladder[0];
            foreach (int v in ladder) if (v > cur) return v;
            return 0;
        }

        // ================= cameras =================
        static Cam DefaultCam()
        {
            lock (gate)
            {
                foreach (Cam c in cams) if (c.Name.Equals("TV1", StringComparison.OrdinalIgnoreCase)) return c;
                foreach (Cam c in cams) if (!c.Scenic) return c;
            }
            return null;
        }

        // the camera to keep when we only change who is watched: the one on now, or TV1 when there is none (or a scenic one: no car in it)
        static void CamSpec(Snap s, out int group, out int camera)
        {
            Cam cur = FindCam(s.CamGroup);
            if (cur == null || cur.Scenic) { Cam d = DefaultCam(); group = d != null ? d.Num : 0; camera = d != null ? 1 : 0; return; }
            group = cur.Num; camera = Math.Max(1, s.CamCamera);
        }

        static readonly Regex SkipCam = new Regex("Susp|Gyro|Gearbox|Roll ?Bar", RegexOptions.IgnoreCase);
        // every (group, camera) the CAMERA keys step through: the useful views, not the five suspension cameras
        static List<int[]> CamList()
        {
            var l = new List<int[]>();
            lock (gate) { foreach (Cam c in cams) { if (SkipCam.IsMatch(c.Name)) continue; for (int k = 1; k <= Math.Max(1, c.Count); k++) l.Add(new[] { c.Num, k }); } }
            return l;
        }

        static void SendCam(Seq q, Snap s, int group, int camera)
        {
            // Choosing a view by hand: iRacing's TV director (auto shot selection, on by default when you are out of the car, seen in the
            // live run of 2026-10-10) would pick another camera a few seconds later, so the director goes off first. AUTO TV turns it on again.
            if ((s.CamState & AutoShot) != 0) { int bits = (s.CamState & Settable) & ~AutoShot; q.M(2, bits, 0); SetHold("CamCameraState", bits); }
            Cam grp = FindCam(group); Drv d = FindDrv(s.CamCar);
            if (d != null && grp != null && !grp.Scenic) q.M(1, d.Raw, Pack(group, camera));   // same car, other camera
            else q.M(0, 0, Pack(group, camera));                                                // position 0 = whoever is in focus
            SetHold("CamGroupNumber", group); SetHold("CamCameraNumber", camera);
        }

        static Cam GroupByKind(string kind)
        {
            lock (gate)
            {
                foreach (Cam c in cams)
                {
                    if (kind == "tv" && Regex.IsMatch(c.Name, "^TV ?1$", RegexOptions.IgnoreCase)) return c;
                    if (kind == "cockpit" && c.Name.Equals("Cockpit", StringComparison.OrdinalIgnoreCase)) return c;
                    if (kind == "chase" && c.Name.Equals("Chase", StringComparison.OrdinalIgnoreCase)) return c;
                }
                if (kind == "tv") foreach (Cam c in cams) if (c.Name.StartsWith("TV", StringComparison.OrdinalIgnoreCase)) return c;
            }
            return null;
        }

        // ================= cars =================
        static bool MultiClass()
        {
            lock (gate)
            {
                string first = null;
                foreach (Drv d in drivers) { if (d.Pace || d.Spectator) continue; if (first == null) first = d.Class; else if (d.Class != first) return true; }
            }
            return false;
        }
        static int PosOf(Frame f, Drv d, bool multi) { return At(f, multi ? "CarIdxClassPosition" : "CarIdxPosition", d.Idx); }

        // the car in overall position pos (1 = the leader); null when positions are not known yet
        static Drv CarAtPosition(Snap s, int pos)
        {
            foreach (Drv d in Racers()) if (At(s.F, "CarIdxPosition", d.Idx) == pos) return d;
            return null;
        }
        static List<Drv> Racers() { var l = new List<Drv>(); lock (gate) { foreach (Drv d in drivers) if (!d.Pace && !d.Spectator) l.Add(d); } return l; }

        // the car in front of (-1) or behind (+1) the one being watched; by class position when there is more than one class
        static Drv Neighbour(Snap s, int dir)
        {
            Drv w = FindDrv(s.CamCar); if (w == null) w = FindDrv(s.Me);
            if (w == null) return null;
            bool multi = MultiClass(); int mine = PosOf(s.F, w, multi);
            if (mine <= 0 || mine + dir < 1) return null;
            foreach (Drv d in Racers())
            {
                if (multi && d.Class != w.Class) continue;
                if (PosOf(s.F, d, multi) == mine + dir) return d;
            }
            return null;
        }

        // "Casey Seitz" -> SEITZ (the family name fits a key); "Dale Earnhardt Jr." -> EARNHARDT
        static string Last(string name)
        {
            string n = (name ?? "").Trim();
            n = Regex.Replace(n, "\\s+(Jr\\.?|Sr\\.?|II|III|IV)$", "", RegexOptions.IgnoreCase);
            int sp = n.LastIndexOf(' ');
            return (sp > 0 ? n.Substring(sp + 1) : n).ToUpperInvariant();
        }

        // ================= PHOTO: hide the UI, iRacing's own screenshot, UI back, a copy into the gallery =================
        static string photoState = "idle", photoMsg = ""; static DateTime photoAt = DateTime.MinValue; static bool photoBusy;

        // iRacing only takes a screenshot (by the SDK or its own key) when "Video and Screen Capture" is on in its Interface settings
        // (app.ini vidCaptureEnable, needs a sim restart). The sim says so in VidCapEnabled; -1 = it does not say.
        static int CaptureOn(Frame f)
        {
            VarDef d;
            if (f == null || !f.Connected || f.Vars == null || !f.Vars.TryGetValue("VidCapEnabled", out d)) return -1;
            return f.Num("VidCapEnabled") != 0 ? 1 : 0;
        }

        static bool StartPhoto(Snap s)
        {
            if (CaptureOn(s.F) == 0) { Log.W("replay: photo refused - iRacing's screen capture is switched off (Settings, Interface, Camera & Screen Capture)"); return false; }
            lock (gate) { if (photoBusy) return true; photoBusy = true; photoState = "working"; photoMsg = ""; photoAt = DateTime.UtcNow; }
            Thread t = new Thread(PhotoWork); t.IsBackground = true; t.Start((s.CamState & Settable));
            return true;
        }

        static string ShotsDir() { return Recording ? Path.Combine(dir, "test\\shots") : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "iRacing\\screenshots"); }
        static string MineDir() { return Recording ? Path.Combine(dir, "test\\mine") : Path.Combine(rootDir, "paddock\\gallery\\mine"); }

        static Dictionary<string, long> ListShots(string d)
        {
            var l = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (!Directory.Exists(d)) return l;
                foreach (string f in Directory.GetFiles(d, "*.*", SearchOption.AllDirectories))
                {
                    string e = Path.GetExtension(f).ToLowerInvariant();
                    if (e == ".png" || e == ".jpg" || e == ".jpeg" || e == ".bmp" || e == ".tga") l[f] = File.GetLastWriteTimeUtc(f).Ticks;
                }
            }
            catch { }
            return l;
        }

        static int ImageWidth(string path)
        {
            try
            {
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (System.Drawing.Image im = System.Drawing.Image.FromStream(fs, false, false)) return im.Width;   // headers only
            }
            catch { return 0; }
        }

        static void PhotoWork(object state)
        {
            int bits = (int)state; bool wasHidden = (bits & UiHidden) != 0, rec = Recording;
            string st = "failed", msg = "";
            try
            {
                Dictionary<string, long> before = ListShots(ShotsDir());
                if (!wasHidden) { Bcast(2, bits | UiHidden, 0); SetHold("CamCameraState", bits | UiHidden); Thread.Sleep(rec ? 100 : 500); }   // let the screen redraw without the menus
                Bcast(13, 0, 0);
                string found = null; DateTime end = DateTime.UtcNow.AddSeconds(rec ? 8 : 12);
                while (DateTime.UtcNow < end && found == null)
                {
                    Thread.Sleep(150);
                    foreach (KeyValuePair<string, long> kv in ListShots(ShotsDir()))
                    {
                        long was;
                        if (before.TryGetValue(kv.Key, out was) && was == kv.Value) continue;
                        // the file is done when its size stops changing
                        long n1 = new FileInfo(kv.Key).Length; Thread.Sleep(250); long n2 = new FileInfo(kv.Key).Length;
                        if (n1 > 0 && n1 == n2) { found = kv.Key; break; }
                    }
                }
                if (!wasHidden) { Bcast(2, bits & ~UiHidden, 0); SetHold("CamCameraState", bits & ~UiHidden); }     // the menus back, whatever happened
                if (found == null) { msg = "iRacing did not save a picture"; }
                else if (ImageWidth(found) < 2560) { st = "small"; msg = "taken, but too small for the side screens"; }
                else
                {
                    string mine = MineDir(); Directory.CreateDirectory(mine);
                    string to = Path.Combine(mine, "me-" + DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + Path.GetExtension(found).ToLowerInvariant());
                    File.Copy(found, to, false);
                    st = "saved"; msg = Path.GetFileName(to);
                }
            }
            catch (Exception ex) { msg = ex.Message; if (!wasHidden) { try { Bcast(2, bits & ~UiHidden, 0); } catch { } } }
            lock (gate) { photoState = st; photoMsg = msg; photoAt = DateTime.UtcNow; photoBusy = false; }
            Log.W("replay: photo " + st + (msg.Length > 0 ? " (" + msg + ")" : ""));
        }

        static string PhotoJson(Snap s)
        {
            lock (gate)
            {
                string st = photoState; int age = photoAt == DateTime.MinValue ? 0 : (int)(DateTime.UtcNow - photoAt).TotalSeconds;
                if (st != "working" && st != "idle" && age > 5) st = "idle";            // the result shows on the key for a few seconds
                return "{\"state\":" + Json_.S(st) + ",\"age\":" + age + ",\"msg\":" + Json_.S(photoMsg) + ",\"capture\":" + CaptureOn(s.F) + "}";
            }
        }

        // ================= saved replays (out of a session) =================
        // Documents\iRacing\replay\...\*.rpy, newest first. Only listed: nothing in iRacing opens a saved replay from outside
        // its own Replay screen (docs\replay.md), so the deck says where to open it instead of guessing with clicks.
        static DateTime scanAt = DateTime.MinValue; static string scanJson = "{\"count\":0,\"items\":[]}";
        static string ReplaysJson()
        {
            lock (gate)
            {
                if ((DateTime.UtcNow - scanAt).TotalSeconds < 20) return scanJson;
                scanAt = DateTime.UtcNow;
                try
                {
                    string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "iRacing\\replay");
                    var files = new List<FileInfo>();
                    if (Directory.Exists(root)) foreach (string f in Directory.GetFiles(root, "*.rpy", SearchOption.AllDirectories)) files.Add(new FileInfo(f));
                    files.Sort(delegate (FileInfo x, FileInfo y) { return y.LastWriteTimeUtc.CompareTo(x.LastWriteTimeUtc); });
                    var items = new List<string>();
                    for (int i = 0; i < files.Count && i < 8; i++)
                    {
                        FileInfo fi = files[i]; string rel = fi.DirectoryName.Length > root.Length ? fi.DirectoryName.Substring(root.Length).Trim('\\') : "";
                        int days = (DateTime.Today - fi.LastWriteTime.Date).Days;
                        string when = days <= 0 ? "today" : days == 1 ? "yesterday" : days < 7 ? fi.LastWriteTime.ToString("dddd", CultureInfo.InvariantCulture) : fi.LastWriteTime.ToString("d MMM yyyy", CultureInfo.InvariantCulture);
                        items.Add("{\"name\":" + Json_.S(Path.GetFileNameWithoutExtension(fi.Name)) + ",\"where\":" + Json_.S(rel.Replace('\\', ' ').Trim()) +
                                  ",\"when\":" + Json_.S(when) + ",\"mb\":" + Math.Round(fi.Length / 1048576.0).ToString(CultureInfo.InvariantCulture) + "}");
                    }
                    scanJson = "{\"count\":" + files.Count + ",\"items\":[" + string.Join(",", items.ToArray()) + "]}";
                }
                catch (Exception ex) { Log.W("replay: saved replays: " + ex.Message); scanJson = "{\"count\":0,\"items\":[]}"; }
                return scanJson;
            }
        }

        // ================= /replay =================
        static string B(bool v) { return v ? "true" : "false"; }
        static string D(double v) { return v.ToString("0.###", CultureInfo.InvariantCulture); }

        static string CarJson(Snap s, Drv d, bool multi)
        {
            if (d == null) return "null";
            return "{\"idx\":" + d.Idx + ",\"num\":" + Json_.S(d.Num) + ",\"name\":" + Json_.S(Last(d.Name)) + ",\"pos\":" + PosOf(s.F, d, multi) + "}";
        }

        public static string Json()
        {
            if (dir == null) return "{\"ready\":false}";
            try
            {
                Snap s = Read();
                StringBuilder sb = new StringBuilder("{\"ready\":true");
                sb.Append(",\"inSession\":").Append(B(s.Connected)).Append(",\"driving\":").Append(B(s.Driving));
                sb.Append(",\"photo\":").Append(PhotoJson(s));
                if (!s.Connected) { sb.Append(",\"replays\":").Append(ReplaysJson()).Append("}"); return sb.ToString(); }

                bool multi = MultiClass();
                sb.Append(",\"live\":").Append(B(s.AtLive)).Append(",\"mode\":").Append(Json_.S(s.Mode));
                sb.Append(",\"raw\":").Append(s.Raw).Append(",\"slow\":").Append(B(s.Slow)).Append(",\"rate\":").Append(D(s.Rate));

                // where on the tape: the session being watched, its length, the marker, the time from live, the lap of the car watched
                Ses cs = FindSes(s.Sess); double len = SessionLen(s, s.Sess);
                double frac = s.Replaying ? (len > 0 ? Math.Min(1, s.Time / len) : -1) : (len > 0 ? 1 : -1);
                bool liveSess = s.Sess == s.LiveSess;
                Drv watch = FindDrv(s.CamCar); Drv me = FindDrv(s.Me); Drv lapCar = watch != null ? watch : me;
                int lap = lapCar != null ? Math.Max(0, At(s.F, "CarIdxLap", lapCar.Idx)) : 0;
                sb.Append(",\"session\":{\"num\":").Append(s.Sess).Append(",\"name\":").Append(Json_.S(SesName(cs)))
                  .Append(",\"laps\":").Append(cs != null ? cs.Laps : 0).Append(",\"time\":").Append(D(s.Time)).Append(",\"len\":").Append(D(len))
                  .Append(",\"frac\":").Append(D(frac)).Append(",\"fromLive\":").Append(s.Replaying ? (liveSess ? (int)Math.Round(s.FramesEnd / 60.0) : -1) : 0)
                  .Append(",\"lap\":").Append(lap).Append("}");
                List<Ses> tape = OnTape(s); var sl = new List<string>();
                foreach (Ses e in tape) sl.Add("{\"num\":" + e.Num + ",\"name\":" + Json_.S(SesName(e)) + "}");
                sb.Append(",\"sessions\":[").Append(string.Join(",", sl.ToArray())).Append("]");
                int at = tape.FindIndex(delegate (Ses e) { return e.Num == s.Sess; });
                sb.Append(",\"nextSession\":").Append(tape.Count > 1 ? "{\"num\":" + tape[(at + 1) % tape.Count].Num + ",\"name\":" + Json_.S(SesName(tape[(at + 1) % tape.Count])) + "}" : "null");

                // cameras
                Cam cc = FindCam(s.CamGroup); Cam tv = GroupByKind("tv"), cp = GroupByKind("cockpit"), ch = GroupByKind("chase");
                sb.Append(",\"camera\":{\"group\":").Append(s.CamGroup).Append(",\"name\":").Append(Json_.S(cc != null ? cc.Name : ""))
                  .Append(",\"camera\":").Append(s.CamCamera).Append(",\"count\":").Append(cc != null ? cc.Count : 0)
                  .Append(",\"autoTv\":").Append(B((s.CamState & AutoShot) != 0)).Append(",\"uiHidden\":").Append(B((s.CamState & UiHidden) != 0))
                  .Append(",\"tv\":").Append(B(tv != null)).Append(",\"cockpit\":").Append(B(cp != null)).Append(",\"chase\":").Append(B(ch != null))
                  .Append(",\"onTv\":").Append(B(tv != null && s.CamGroup == tv.Num)).Append(",\"onCockpit\":").Append(B(cp != null && s.CamGroup == cp.Num))
                  .Append(",\"onChase\":").Append(B(ch != null && s.CamGroup == ch.Num)).Append("}");

                // cars: watched, mine, neighbours, leader, and the list for PICK CAR (by position, mine marked)
                sb.Append(",\"multiClass\":").Append(B(multi));
                sb.Append(",\"watch\":").Append(CarJson(s, watch, multi)).Append(",\"me\":").Append(CarJson(s, me, multi));
                sb.Append(",\"ahead\":").Append(CarJson(s, Neighbour(s, -1), multi)).Append(",\"behind\":").Append(CarJson(s, Neighbour(s, 1), multi));
                sb.Append(",\"leader\":").Append(CarJson(s, CarAtPosition(s, 1), multi));
                var racers = Racers();
                racers.Sort(delegate (Drv x, Drv y)
                {
                    int px = At(s.F, "CarIdxPosition", x.Idx), py = At(s.F, "CarIdxPosition", y.Idx);
                    if (px <= 0) px = 9999; if (py <= 0) py = 9999;
                    return px != py ? px.CompareTo(py) : x.Idx.CompareTo(y.Idx);
                });
                var cl = new List<string>();
                foreach (Drv d in racers)
                    cl.Add("{\"idx\":" + d.Idx + ",\"pos\":" + At(s.F, "CarIdxPosition", d.Idx) + ",\"num\":" + Json_.S(d.Num) + ",\"name\":" + Json_.S(Last(d.Name)) +
                           ",\"me\":" + B(d.Idx == s.Me) + ",\"watch\":" + B(d.Idx == s.CamCar) + ",\"color\":" + Json_.S(d.Color) + "}");
                sb.Append(",\"cars\":[").Append(string.Join(",", cl.ToArray())).Append("]");
                sb.Append("}");
                return sb.ToString();
            }
            catch (Exception ex) { Log.W("replay json: " + ex.Message); return "{\"ready\":false}"; }
        }
    }
}
