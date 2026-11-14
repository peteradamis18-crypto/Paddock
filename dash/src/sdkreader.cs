// SDK READER (W2-1, docs/rework/cards/W2-1.md): iRacing's shared memory, the test hook's pretend session, the frame JSON for /stream.
// Moved here from irdash.cs as it was (same names). New with W2-1:
//   - the session YAML is parsed ONCE per SessionVersion, on the reader thread, into Sdk.Session (the drivers by CarIdx, the session
//     type, laps, time, incident limit, the tank size) and into the "session" state part's JSON; nothing else needs to parse it again
//     to know who is in car 7. (ReadYaml itself already ran only when iRacing's SessionInfoUpdate changed, not per frame.)
//   - the "race" channel set: /stream?set=race sends exactly the 24 channels the race screen reads (Sdk.RaceSet)
//   - every frame feeds the fuel tracker (fuel.cs) at most 15 times a second of sim time
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Security.AccessControl;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class Sdk
    {
        static readonly object gate = new object();
        static Frame latest = new Frame();
        static long seq;
        static DateTime lastFrameAt = DateTime.MinValue;
        public static Frame Latest { get { lock (gate) return latest; } }
        public static bool Fresh { get { lock (gate) return DateTime.UtcNow - lastFrameAt <= TimeSpan.FromSeconds(2); } }
        public static bool FreshDeck { get { lock (gate) return DateTime.UtcNow - lastFrameAt <= TimeSpan.FromSeconds(1); } }

        static void Publish(Frame f) { Publish(f, false); }
        // fake: a frame of the pretend session's pump. Once FakeEnd has run it is dropped (a pump frame that was on its way must not
        // bring the pretend session, and its parsed Session, back after the end). false = dropped.
        static bool Publish(Frame f, bool fake)
        {
            lock (gate) { if (fake && !fakeUp) return false; f.Seq = ++seq; latest = f; lastFrameAt = DateTime.UtcNow; Monitor.PulseAll(gate); }
            RigState.Feed(f.Connected, f.Connected && f.Num("IsOnTrack") != 0, fakeUp);     // the one "is he busy" answer (rigstate.cs)
            // W2-1: after the frame is out, so a new YAML never holds a frame back; Sdk.Session follows one frame late at a version change
            ParseSession(f);
            FeedFuel(f);
            return true;
        }

        // ---- W2-1: the session YAML, parsed once per SessionVersion on the publishing (reader's) thread ----
        static readonly object sessGate = new object();
        static SdkSession session;
        static int parsedVer = int.MinValue; static string parsedYaml;
        static int parses;
        public static SdkSession Session { get { lock (sessGate) return session; } }
        public static int SessionParses { get { lock (sessGate) return parses; } }       // the tests count them
        // internal for the tests: the FakeEnd race (a pump frame after the end)
        internal static bool PublishPumpFrame(Frame f) { return Publish(f, true); }
        static void ParseSession(Frame f)
        {
            lock (sessGate)
            {
                if (f.Seq < Latest.Seq) return;          // a newer frame is already out: its own call parses (or clears)
                if (!f.Connected) { session = null; parsedVer = int.MinValue; parsedYaml = null; return; }
                // the version and the very same string: a pretend session and a real one can both be at version 2
                if (f.SessionVersion == parsedVer && ReferenceEquals(f.SessionYaml, parsedYaml)) return;
                parsedVer = f.SessionVersion; parsedYaml = f.SessionYaml;
                parses++;
                SdkSession s = null;
                try { s = SdkSession.Parse(f.SessionYaml, f.SessionVersion); }
                catch (Exception ex) { RigState.LogOnce("sdk session", "sdk: session yaml: " + ex.Message); }
                session = s;
            }
        }

        // ---- W2-1: the race screen's one channel set (PLAN 4.2, zones A-E, + 4 from the race page review = 28): /stream?set=race sends exactly these, at 15 Hz ----
        public static readonly string[] RaceSet = {
            "CarIdxPosition", "CarIdxClassPosition", "CarIdxF2Time", "CarIdxLapDistPct", "CarIdxEstTime", "CarIdxOnPitRoad", "CarIdxClass",
            "CarIdxLap", "Lap", "LapCompleted", "SessionLapsRemainEx", "SessionTimeRemain", "SessionTime", "PlayerCarMyIncidentCount",
            "SessionFlags", "FuelLevel", "FuelUsePerHour", "LapLastLapTime", "LapBestLapTime", "LapDeltaToBestLap", "LapDeltaToBestLap_OK",
            "OnPitRoad", "PlayerCarIdx", "IsOnTrack",
            "IsReplayPlaying", "SessionNum", "DisplayUnits", "EngineWarnings" };      // the race page review: replay gate, session, units, pit limiter
        // the names a stream asked for: ?set=race wins over ?vars= (exactly the 24, nothing else); null = unknown set
        public static string[] SetNames(string set) { return set == "race" ? RaceSet : null; }

        // one slot of an array channel (Frame.Num reads slot 0 only); 0 when the channel or the slot is not there
        public static double NumAt(Frame f, string name, int idx)
        {
            VarDef d;
            if (f == null || !f.Connected || f.Vars == null || !f.Vars.TryGetValue(name, out d) || idx < 0 || idx >= d.Count) return 0;
            int p = d.Offset + idx * Size(d.Type);
            if (p < 0 || p + Size(d.Type) > f.Data.Length) return 0;
            switch (d.Type)
            {
                case 0: case 1: return f.Data[p];
                case 2: return BitConverter.ToInt32(f.Data, p);
                case 3: return BitConverter.ToUInt32(f.Data, p);
                case 4: return BitConverter.ToSingle(f.Data, p);
                case 5: return BitConverter.ToDouble(f.Data, p);
            }
            return 0;
        }
        public static bool Has(Frame f, string name) { return f != null && f.Vars != null && f.Vars.ContainsKey(name); }

        // ---- W2-1: every frame feeds the fuel tracker (fuel.cs), at most 15 samples a second of sim time (it drops the rest itself) ----
        static void FeedFuel(Frame f)
        {
            try
            {
                if (!f.Connected) { if (Fuel.Live.Samples > 0) Fuel.Live.Reset(); return; }
                SdkSession ss = session;
                FuelSample s = new FuelSample();
                s.Time = f.Num("SessionTime"); s.SessionNum = (int)f.Num("SessionNum"); s.Lap = (int)f.Num("Lap");
                s.Pct = f.Num("LapDistPct"); s.Level = f.Num("FuelLevel"); s.Flags = unchecked((uint)(long)f.Num("SessionFlags"));
                s.OnPitRoad = f.Num("OnPitRoad") != 0; s.OnTrack = f.Num("IsOnTrack") != 0;
                s.Surface = Has(f, "PlayerTrackSurface") ? (int)f.Num("PlayerTrackSurface") : 3;
                s.Incidents = (int)f.Num("PlayerCarMyIncidentCount");
                s.LastLap = f.Num("LapLastLapTime"); s.BestLap = f.Num("LapBestLapTime"); s.HaveBest = Has(f, "LapBestLapTime");
                s.LapsRemain = Has(f, "SessionLapsRemainEx") ? (int)f.Num("SessionLapsRemainEx") : 32767;
                s.TimeRemain = Has(f, "SessionTimeRemain") ? f.Num("SessionTimeRemain") : -1;
                SdkSessionRow row = ss == null ? null : ss.For(s.SessionNum);
                s.LapRace = row != null ? row.Laps > 0 : s.LapsRemain < 32767;
                if (ss != null) { Fuel.Live.TankL = ss.FuelMaxL; Fuel.Live.EstLap = ss.EstLap; }
                Fuel.Live.Feed(s);
                if (ss != null) { try { PitLoss.Feed(s.Time, s.OnPitRoad, s.Lap, f.Num("LapDistPct"), unchecked((int)s.Flags), s.OnTrack, s.Surface, Has(f, "PitstopActive") && f.Num("PitstopActive") != 0, ss.Track, ss.Config, s.SessionNum); } catch (Exception ex) { RigState.LogOnce("sdk pitloss", "sdk: pit loss: " + ex.Message); } }   // W2-3: time lost in the pits, learned per track (the ghost row)
            }
            catch (Exception ex) { RigState.LogOnce("sdk fuel", "sdk: fuel: " + ex.Message); }
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
        // Forwarder (more than five callers): the rule itself is RigState.RealBusyWhy (rigstate.cs).
        public static string RealBusy() { return RigState.RealBusyWhy(); }

        // W0-3: a replay sends about 1,100 keys 30 times a second; the regex per key per frame cost the test server 3-5 % of a core (the
        // load test measures irdash, not its test hook). Each key is parsed once.
        static readonly Dictionary<string, KeyValuePair<string, int>> slotOf = new Dictionary<string, KeyValuePair<string, int>>();
        static bool ArraySlot(string key, out string name, out int slot)
        {
            KeyValuePair<string, int> s;
            lock (slotOf)
            {
                if (!slotOf.TryGetValue(key, out s))
                {
                    Match am = ArrayKey.Match(key); int n;
                    s = am.Success && int.TryParse(am.Groups[2].Value, out n) ? new KeyValuePair<string, int>(am.Groups[1].Value, n) : new KeyValuePair<string, int>(null, -1);
                    slotOf[key] = s;
                }
            }
            name = s.Key; slot = s.Value;
            return s.Key != null;
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
                IbtReplay.PumpThread = IbtReplay.CurrentOsThread();
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
                            string an; int slot;
                            if (!ArraySlot(kv.Key, out an, out slot)) { scalars++; continue; }
                            double[] arr; if (!arrays.TryGetValue(an, out arr)) { arr = new double[64]; arrays[an] = arr; whole[an] = true; }
                            if (slot < 0 || slot >= 64) continue;
                            arr[slot] = kv.Value;
                            if (Math.Abs(kv.Value - Math.Round(kv.Value)) > 1e-6) whole[an] = false;
                        }
                        int arrBase = 8 * Math.Max(1, scalars), ai = 0;
                        f.Data = new byte[arrBase + 256 * arrays.Count];
                        foreach (KeyValuePair<string, double[]> ar in arrays)
                        {
                            bool isWhole = whole[ar.Key];
                            VarDef av = new VarDef(); av.Name = ar.Key; av.Type = isWhole ? 2 : 4; av.Count = 64; av.Offset = arrBase + 256 * ai++;
                            if (isWhole) { int[] iv = new int[64]; for (int k = 0; k < 64; k++) iv[k] = (int)ar.Value[k]; Buffer.BlockCopy(iv, 0, f.Data, av.Offset, 256); }
                            else { float[] fv = new float[64]; for (int k = 0; k < 64; k++) fv[k] = (float)ar.Value[k]; Buffer.BlockCopy(fv, 0, f.Data, av.Offset, 256); }
                            f.Vars[ar.Key] = av;
                        }
                        int i = 0;
                        foreach (KeyValuePair<string, double> kv in fakeVals)
                        {
                            string an2; int slot2; if (ArraySlot(kv.Key, out an2, out slot2)) continue;
                            VarDef d = new VarDef(); d.Name = kv.Key; d.Count = 1; d.Offset = i * 8;
                            int rt = IbtReplay.TypeFor(kv.Key);      // an .ibt replay knows the real type (W0-8); -1 = old rules
                            bool flag = rt == 1 || kv.Key == "IsOnTrack" || kv.Key == "OnPitRoad" || kv.Key.EndsWith("_OK");
                            d.Type = flag ? 1 : rt >= 0 ? rt : kv.Key == "Lap" ? 2 : 4;
                            if (flag) f.Data[d.Offset] = (byte)(kv.Value != 0 ? 1 : 0);
                            else if (d.Type == 2 || d.Type == 3) Array.Copy(BitConverter.GetBytes(unchecked((int)(long)kv.Value)), 0, f.Data, d.Offset, 4);
                            else if (d.Type == 5) Array.Copy(BitConverter.GetBytes(kv.Value), 0, f.Data, d.Offset, 8);
                            else Array.Copy(BitConverter.GetBytes((float)kv.Value), 0, f.Data, d.Offset, 4);
                            f.Vars[kv.Key] = d; i++;
                        }
                    }
                    if (!Publish(f, true)) break;      // FakeEnd ran while this frame was being made
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
            lock (gate) fakeUp = false;          // under the publish lock: no pump frame gets out after this
            fakeYaml = "";
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
                    // W0-3: a test copy of irdash (--test) never runs beside a real session: it ends itself the moment iRacing connects
                    if (!wasConnected && Program.TestMode) { Log.W("test mode: a real iRacing session started - this test copy of irdash stops now"); Log.Flush(1000); Environment.Exit(3); }
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
                        // W0-3: whole numbers (positions, laps, the empty car slots: most of a CarIdx array) skip the float formatter; the
                        // text is the same as G7 gives below a million. /stream sends ~800 of these 30 times a second.
                        else if (f > -1000000f && f < 1000000f && f == (float)(int)f) sb.Append((int)f);
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

        public static string FrameJson(Frame f, string[] names) { return FrameJson(f, names, false); }
        // allKeys (a named set such as ?set=race): a channel this frame does not have is sent as null, so the page always gets the same keys
        public static string FrameJson(Frame f, string[] names, bool allKeys)
        {
            StringBuilder sb = new StringBuilder(12000);
            sb.Append("{\"seq\":").Append(f.Seq).Append(",\"v\":{");
            bool first = true;
            foreach (string n in names)
            {
                VarDef d;
                if (!f.Vars.TryGetValue(n, out d))
                {
                    if (!allKeys) continue;
                    if (!first) sb.Append(',');
                    first = false;
                    sb.Append('"').Append(n).Append("\":null");
                    continue;
                }
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

    // ---- W2-1: the session YAML parsed once (Sdk.Session) ----
    sealed class SdkDriver
    {
        public int Idx, ClassId; public string Num = "", ShortName = "", UserName = "", ClassShort = "", ClassColor = ""; public bool IsPaceCar, IsSpectator;
    }
    sealed class SdkSessionRow { public int Num = -1, Laps; public double TimeSec; public string Type = "", Name = ""; }

    sealed class SdkSession
    {
        public int Ver; public string Yaml;
        public string Json = "null";            // the "session" state part (StateBuilder.SessionJsonOf: the same JSON as before W2-1)
        // the current session (SessionInfo.CurrentSessionNum); For(n) when the frame's SessionNum says another one
        public string Type = ""; public int Num = -1, Laps; public double TimeSec;
        public int IncidentLimit;               // WeekendInfo.WeekendOptions.IncidentLimit, "unlimited" = 0
        public bool Multiclass;
        public string Track = "", TrackName = "", Config = "";
        public int PlayerIdx = -1;               // DriverInfo.DriverCarIdx
        public double FuelMaxL, EstLap;          // the tank in litres (DriverCarFuelMaxLtr x DriverCarMaxFuelPct), DriverCarEstLapTime
        public SdkDriver[] Drivers = new SdkDriver[64];     // by CarIdx; null = empty slot (the pace car sits at 64, so it can be longer)
        public readonly List<SdkSessionRow> Sessions = new List<SdkSessionRow>();

        public SdkDriver Driver(int idx) { return idx >= 0 && idx < Drivers.Length ? Drivers[idx] : null; }
        public SdkSessionRow For(int num) { foreach (SdkSessionRow r in Sessions) if (r.Num == num) return r; return null; }
        public SdkDriver Me { get { return Driver(PlayerIdx); } }

        static string Str(Dictionary<string, object> d, string k) { object v; return d != null && d.TryGetValue(k, out v) && v is string ? (string)v : ""; }
        static Dictionary<string, object> Map(Dictionary<string, object> d, string k) { object v; return d != null && d.TryGetValue(k, out v) ? v as Dictionary<string, object> : null; }
        static List<object> List(Dictionary<string, object> d, string k) { object v; return d != null && d.TryGetValue(k, out v) ? v as List<object> : null; }
        // the leading number of "83.333", "1.000 %", "900.0000 sec", "17"; 0 for "unlimited" or nothing
        static double Lead(string s)
        {
            Match m = Regex.Match(s ?? "", "^\\s*(-?[0-9]+(?:\\.[0-9]+)?)");
            double v; return m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : 0;
        }
        static int Int(string s) { return (int)Math.Round(Lead(s)); }

        // "Peter Adamis" -> "Adamis"; iRacing's duplicate-name digits go ("Santos11" -> "Santos"); a suffix is not a surname
        public static string Surname(string user)
        {
            string[] w = (user ?? "").Trim().Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (w.Length == 0) return "";
            int i = w.Length - 1;
            string low = w[i].ToLowerInvariant().TrimEnd('.');
            if (i > 0 && (low == "jr" || low == "sr" || low == "ii" || low == "iii" || low == "iv")) i--;
            string s = w[i].TrimEnd('0', '1', '2', '3', '4', '5', '6', '7', '8', '9');
            return s.Length > 0 ? s : w[i];
        }
        // "0xffda59" -> "#ffda59"
        static string Colour(string c)
        {
            c = (c ?? "").Trim();
            if (c.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) c = c.Substring(2);
            if (!Regex.IsMatch(c, "^[0-9a-fA-F]{1,6}$")) return "";
            return "#" + c.ToLowerInvariant().PadLeft(6, '0');
        }

        public static SdkSession Parse(string yaml, int ver)
        {
            if (string.IsNullOrEmpty(yaml)) return null;
            Dictionary<string, object> y = StateBuilder.ParseYaml(yaml);
            SdkSession s = new SdkSession(); s.Ver = ver; s.Yaml = yaml;
            s.Json = StateBuilder.SessionJsonOf(y, ver);

            Dictionary<string, object> wi = Map(y, "WeekendInfo");
            s.TrackName = Str(wi, "TrackName"); s.Config = Str(wi, "TrackConfigName");
            s.Track = Str(wi, "TrackDisplayName"); if (s.Track.Length == 0) s.Track = s.TrackName;
            s.IncidentLimit = Int(Str(Map(wi, "WeekendOptions"), "IncidentLimit"));     // "unlimited" -> 0
            int classes = Int(Str(wi, "NumCarClasses"));

            Dictionary<string, object> si = Map(y, "SessionInfo");
            List<object> rows = List(si, "Sessions");
            if (rows != null)
                foreach (object o in rows)
                {
                    Dictionary<string, object> r = o as Dictionary<string, object>; if (r == null) continue;
                    SdkSessionRow sr = new SdkSessionRow();
                    string num = Str(r, "SessionNum"); sr.Num = num.Length > 0 ? Int(num) : -1;
                    sr.Type = Str(r, "SessionType"); sr.Name = Str(r, "SessionName");
                    sr.Laps = Int(Str(r, "SessionLaps")); sr.TimeSec = Lead(Str(r, "SessionTime"));
                    s.Sessions.Add(sr);
                }
            string cur = Str(si, "CurrentSessionNum");
            SdkSessionRow now = cur.Length > 0 ? s.For(Int(cur)) : (s.Sessions.Count > 0 ? s.Sessions[s.Sessions.Count - 1] : null);
            if (now != null) { s.Type = now.Type; s.Num = now.Num; s.Laps = now.Laps; s.TimeSec = now.TimeSec; }

            Dictionary<string, object> di = Map(y, "DriverInfo");
            string pi = Str(di, "DriverCarIdx"); s.PlayerIdx = pi.Length > 0 ? Int(pi) : -1;
            double maxL = Lead(Str(di, "DriverCarFuelMaxLtr")), pct = Lead(Str(di, "DriverCarMaxFuelPct"));
            s.FuelMaxL = maxL * (pct > 0 && pct <= 1 ? pct : 1);
            s.EstLap = Lead(Str(di, "DriverCarEstLapTime"));
            List<object> drivers = List(di, "Drivers");
            HashSet<int> seenClass = new HashSet<int>();
            if (drivers != null)
                foreach (object o in drivers)
                {
                    Dictionary<string, object> r = o as Dictionary<string, object>; if (r == null) continue;
                    string idxS = Str(r, "CarIdx"); if (idxS.Length == 0) continue;
                    SdkDriver d = new SdkDriver();
                    d.Idx = Int(idxS); if (d.Idx < 0 || d.Idx > 255) continue;
                    d.Num = Str(r, "CarNumber"); d.UserName = Str(r, "UserName");
                    d.ShortName = Surname(d.UserName);
                    d.ClassId = Int(Str(r, "CarClassID")); d.ClassShort = Str(r, "CarClassShortName"); d.ClassColor = Colour(Str(r, "CarClassColor"));
                    d.IsPaceCar = Str(r, "CarIsPaceCar") == "1"; d.IsSpectator = Str(r, "IsSpectator") == "1";
                    if (d.Idx >= s.Drivers.Length) Array.Resize(ref s.Drivers, d.Idx + 1);
                    s.Drivers[d.Idx] = d;
                    if (!d.IsPaceCar && !d.IsSpectator) seenClass.Add(d.ClassId);
                }
            s.Multiclass = classes > 1 || seenClass.Count > 1;
            return s;
        }

        // the cars racing (no pace car, no spectators), and those in one class
        public int Field(int classId)
        {
            int n = 0;
            foreach (SdkDriver d in Drivers) if (d != null && !d.IsPaceCar && !d.IsSpectator && (classId < 0 || d.ClassId == classId)) n++;
            return n;
        }
    }
}
