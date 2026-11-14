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

        static void Publish(Frame f)
        {
            lock (gate) { f.Seq = ++seq; latest = f; lastFrameAt = DateTime.UtcNow; Monitor.PulseAll(gate); }
            RigState.Feed(f.Connected, f.Connected && f.Num("IsOnTrack") != 0, fakeUp);     // the one "is he busy" answer (rigstate.cs)
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
}
