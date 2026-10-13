// Wheel KEEP button and the after-race review (C-07).
// irdash reads joystick buttons itself through winmm joyGetPosEx (no library, no install). One button can be
// taught: /api/do?c=wheelteach waits up to 10 s for the next press and saves wheel_keep=<device>:<button>
// in irdash.ini. While he is driving that button marks the lap (KEEP). When the after-race review is up it
// means KEEP ALL. Nothing here opens a window or moves the focus. The beep is the one the KEEP key already uses.
// WheelLogic is pure so a test can compile just that part (csc /define:WHEEL_UNIT) and feed it a stub device.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace IRDash
{
    public sealed class WLap
    {
        public int Lap;
        public double Time;
        public string Why = "";
        public string Session = "";
    }

    static class WheelLogic
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        public const int TeachMs = 10000;     // /api/do?c=wheelteach waits this long for one press
        public const int DefaultMs = 60000;   // KEEP ALL if he does nothing; a test may arm a shorter wait

        // 79.8 -> "1:19.8". One decimal, as the review sentence says it.
        public static string Short(double t)
        {
            if (t <= 0) return "0:00.0";
            int m = (int)(t / 60.0);
            double s = t - m * 60.0;
            if (s < 0) s = 0;
            return m.ToString(Inv) + ":" + s.ToString("00.0", Inv);
        }

        // "3 laps saved - lap 14 1:19.8 (PB), lap 9 1:20.4 (top 6%) ..." (past four laps, three are named and the rest is in the list)
        public static string Sentence(List<WLap> laps)
        {
            if (laps == null || laps.Count == 0) return "";
            int show = laps.Count > 4 ? 3 : laps.Count;
            StringBuilder sb = new StringBuilder();
            sb.Append(laps.Count.ToString(Inv));
            sb.Append(laps.Count == 1 ? " lap saved" : " laps saved");
            sb.Append(" \u2014 ");
            for (int i = 0; i < show; i++)
            {
                if (i > 0) sb.Append(", ");
                WLap w = laps[i];
                sb.Append("lap ").Append(w.Lap.ToString(Inv)).Append(' ').Append(Short(w.Time)).Append(" (").Append(w.Why ?? "").Append(')');
            }
            if (laps.Count > show) sb.Append(" \u2026");
            return sb.ToString();
        }

        // Buttons that went down since the previous read. Bit 0 is button 1. "0:3,1:1".
        public static string Edges(uint[] prev, uint[] now)
        {
            if (now == null) now = new uint[0];
            if (prev == null) prev = new uint[0];
            int n = prev.Length > now.Length ? prev.Length : now.Length;
            StringBuilder sb = new StringBuilder();
            for (int d = 0; d < n; d++)
            {
                uint p = d < prev.Length ? prev[d] : 0;
                uint c = d < now.Length ? now[d] : 0;
                uint rose = c & ~p;
                for (int i = 0; i < 32; i++)
                {
                    if ((rose & (1u << i)) == 0) continue;
                    if (sb.Length > 0) sb.Append(',');
                    sb.Append(d.ToString(Inv)).Append(':').Append((i + 1).ToString(Inv));
                }
            }
            return sb.ToString();
        }

        // frames[0] is the baseline (a button already held is not a press). Returns the first new "device:button", or "".
        public static string FirstPress(uint[][] frames)
        {
            if (frames == null || frames.Length == 0) return "";
            uint[] prev = frames[0] ?? new uint[0];
            for (int i = 1; i < frames.Length; i++)
            {
                uint[] cur = frames[i] ?? new uint[0];
                string e = Edges(prev, cur);
                prev = cur;
                if (e.Length > 0) return e.Split(',')[0];
            }
            return "";
        }

        public static bool Bind(string s, out int dev, out int btn)
        {
            dev = 0; btn = 0;
            if (string.IsNullOrEmpty(s)) return false;
            string[] p = s.Split(':');
            if (p.Length != 2) return false;
            if (!int.TryParse(p[0], NumberStyles.Integer, Inv, out dev)) return false;
            if (!int.TryParse(p[1], NumberStyles.Integer, Inv, out btn)) return false;
            if (dev < 0 || dev > 15 || btn < 1 || btn > 32) return false;
            return true;
        }

        // The taught button. Driving wins: he is still in the car, so it marks this lap. Otherwise, while the review is up, it keeps all.
        public static string Act(string bind, int dev, int btn, bool driving, bool review)
        {
            int d, b;
            if (!Bind(bind, out d, out b)) return "";
            if (d != dev || b != btn) return "";
            if (driving) return "keep";
            if (review) return "keepall";
            return "";
        }

        public static List<WLap> ParseLaps(string s)
        {
            List<WLap> list = new List<WLap>();
            if (string.IsNullOrEmpty(s)) return list;
            string[] parts = s.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (string part in parts)
            {
                string[] f = part.Split('|');
                if (f.Length < 3) continue;
                int lap; double time;
                if (!int.TryParse(f[0], NumberStyles.Integer, Inv, out lap)) continue;
                if (!double.TryParse(f[1], NumberStyles.Float, Inv, out time)) continue;
                WLap w = new WLap();
                w.Lap = lap; w.Time = time; w.Why = f[2];
                if (f.Length > 3) w.Session = f[3];
                list.Add(w);
            }
            return list;
        }

        public static uint[] Masks(string csv)
        {
            if (string.IsNullOrEmpty(csv)) return new uint[0];
            string[] p = csv.Split(',');
            uint[] m = new uint[p.Length];
            for (int i = 0; i < p.Length; i++)
            {
                uint v;
                if (!uint.TryParse(p[i].Trim(), NumberStyles.Integer, Inv, out v)) v = 0;
                m[i] = v;
            }
            return m;
        }
    }

#if !WHEEL_UNIT
    // The live side: poll, teach, and the review timer. Wired only into the full irdash build.
    static class Wheel
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly object gate = new object();
        const int JOY_RETURNBUTTONS = 0x80;

        [StructLayout(LayoutKind.Sequential)]
        struct JOYINFOEX
        {
            public int dwSize, dwFlags, dwXpos, dwYpos, dwZpos, dwRpos, dwUpos, dwVpos;
            public int dwButtons, dwButtonNumber, dwPOV, dwReserved1, dwReserved2;
        }

        [DllImport("winmm.dll", CallingConvention = CallingConvention.StdCall)]
        static extern int joyGetNumDevs();
        [DllImport("winmm.dll", CallingConvention = CallingConvention.StdCall)]
        static extern int joyGetPosEx(int id, ref JOYINFOEX info);

        static bool started, teaching, havePrev, up, kept, wasConn;
        static string binding = "";
        static uint[] prevMask, stub;
        static int testWaitMs, waitMs = 60000;
        static long until, liveSince;
        static DateTime lastAct = DateTime.MinValue;
        static List<WLap> snapshot = new List<WLap>();
        static List<WLap> seed;
        static bool winmmLogged;

        public static void ReadBinding()
        {
            string found = "";
            try
            {
                if (Program.IniFile != null && File.Exists(Program.IniFile))
                {
                    foreach (string raw in File.ReadAllLines(Program.IniFile))
                    {
                        string l = raw.Trim();
                        if (l.Length == 0 || l.StartsWith(";")) continue;
                        int e = l.IndexOf('=');
                        if (e <= 0) continue;
                        if (!l.Substring(0, e).Trim().Equals("wheel_keep", StringComparison.OrdinalIgnoreCase)) continue;
                        found = l.Substring(e + 1).Trim();
                    }
                }
            }
            catch (Exception ex) { Log.W("wheel: ini: " + ex.Message); }
            SetBinding(found, false);
        }

        public static void SetBinding(string v, bool save)
        {
            int d, b;
            string norm = "";
            if (WheelLogic.Bind(v, out d, out b)) norm = d.ToString(Inv) + ":" + b.ToString(Inv);
            lock (gate) binding = norm;
            if (save && norm.Length > 0 && Program.IniFile != null) Config.SetKey(Program.IniFile, "wheel_keep", norm);
        }

        public static int SetSeed(List<WLap> laps, int secs)
        {
            lock (gate)
            {
                seed = laps;
                int n = laps == null ? 0 : laps.Count;
                // The telemetry file can finish saving while the panel is already up. Fill the blank list and leave the timer.
                if (up && !kept && n > 0 && (snapshot == null || snapshot.Count == 0)) { snapshot = laps; return n; }
                testWaitMs = secs > 0 ? secs * 1000 : 0;
                up = false; kept = false;
                return n;
            }
        }

        public static void SetStub(uint[] masks) { lock (gate) stub = masks; }

        // The next poll treats whatever is down now as already held, so only a new press counts.
        public static void Baseline()
        {
            lock (gate) { prevMask = Copy(ReadNow()); havePrev = true; }
        }

        public static void ResetTransient()
        {
            lock (gate)
            {
                up = false; kept = false; testWaitMs = 0; havePrev = false;
                snapshot = new List<WLap>(); seed = null; stub = null; prevMask = null;
            }
        }

        public static void Ensure()
        {
            lock (gate) { if (started) return; started = true; }
            Thread t = new Thread(Loop);
            t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal; t.Name = "Wheel"; t.Start();
            Log.W("wheel: listening for a KEEP button");
        }

        static bool Driving()
        {
            try { Frame f = Sdk.Latest; return f.Connected && f.Num("IsOnTrack") != 0; }
            catch { return false; }
        }

        static List<WLap> TakeLaps()
        {
            List<WLap> s;
            lock (gate) s = seed;
            if (s != null && s.Count > 0) return s;
            try { return Vault.SavedLaps(); }
            catch (Exception ex) { Log.W("wheel: saved laps: " + ex.Message); return new List<WLap>(); }
        }

        static void Loop()
        {
            while (true)
            {
                try
                {
                    if (!Vault.Serving) { Thread.Sleep(400); continue; }
                    NoteConn();
                    if (!teaching)
                    {
                        Pump();
                        string bound;
                        lock (gate) bound = binding;
                        if (bound != null && bound.Length > 0)
                        {
                            string edges = Poll();
                            if (edges.Length > 0) OnEdges(edges);
                        }
                    }
                }
                catch (Exception ex) { Log.W("wheel: " + ex.Message); }
                Thread.Sleep(40);
            }
        }

        static void OnEdges(string edges)
        {
            string[] parts = edges.Split(',');
            for (int i = 0; i < parts.Length; i++)
            {
                int d, b;
                if (!WheelLogic.Bind(parts[i], out d, out b)) continue;
                string bound; bool rev;
                lock (gate) { bound = binding; rev = up && !kept; }
                string act = WheelLogic.Act(bound, d, b, Driving(), rev);
                if (act.Length == 0) continue;
                if ((DateTime.UtcNow - lastAct).TotalSeconds < 0.7) return;
                lastAct = DateTime.UtcNow;
                if (act == "keep")
                {
                    Log.W("wheel: KEEP (button " + parts[i] + ")");
                    Vault.TestEvents.Add("wheel keep");
                    Vault.PressKeep();
                }
                else if (act == "keepall")
                {
                    Log.W("wheel: KEEP ALL (button " + parts[i] + ")");
                    Vault.TestEvents.Add("wheel keepall");
                    KeepAll();
                }
                return;
            }
        }

        public static bool DrivingNow() { return Driving(); }

        // Wall-clock ms when this connection started. SavedLaps uses it so a session that ended earlier cannot fill the review.
        public static long LiveSince() { lock (gate) return liveSince; }

        static void NoteConn()
        {
            bool conn = false;
            try { conn = Sdk.Latest.Connected; } catch { conn = false; }
            lock (gate)
            {
                if (conn && !wasConn) liveSince = Vault.Now();
                wasConn = conn;
            }
        }

        // Back in the car, the review closes and the button means KEEP this lap. Otherwise fill a blank list without
        // moving the 60 s deadline, keep all once that list is in and the time is up, and never keep an empty list.
        static void Pump()
        {
            if (Driving())
            {
                lock (gate) if (up) { up = false; Log.W("vault: review closed, back in the car"); }
                return;
            }
            bool need = false;
            lock (gate) need = up && !kept && (snapshot == null || snapshot.Count == 0);
            if (need)
            {
                // C-27: the finished session's file may be readable now even though the sim program is still open (results, replay)
                try { Vault.ReadNewestIfOver(); } catch (Exception ex) { Log.W("wheel: finished-session read: " + ex.Message); }
                List<WLap> fresh = TakeLaps();
                if (fresh != null && fresh.Count > 0)
                    lock (gate) if (up && !kept && (snapshot == null || snapshot.Count == 0)) snapshot = fresh;
            }
            bool fire = false, give = false;
            lock (gate)
            {
                bool empty = snapshot == null || snapshot.Count == 0;
                if (up && !kept && Vault.Now() >= until)
                {
                    if (!empty) fire = true;
                    else if (Vault.Now() >= until + 120000) give = true;
                }
            }
            if (fire) KeepAll();
            else if (give)
                lock (gate) if (up && !kept && (snapshot == null || snapshot.Count == 0)) { up = false; Log.W("vault: review closed, the laps were not ready"); }
        }

        // He opened the Vault to choose. Stop the 60 s KEEP ALL; the laps stay saved either way.
        public static void CancelForChoose() { lock (gate) up = false; }

        public static bool KeepAll()
        {
            if (Driving()) return false;
            List<WLap> laps;
            lock (gate)
            {
                if (!up) return kept;
                kept = true; up = false; laps = snapshot;
            }
            try { Vault.PinSaved(laps); } catch (Exception ex) { Log.W("vault: keep all: " + ex.Message); }
            Vault.TestEvents.Add("keepall");
            Log.W("vault: KEEP ALL");
            try { Vault.Chime(true); } catch { }
            return true;
        }

        // Blocks the caller (its own request thread) until the next new press, or 10 s.
        public static string Teach(int ms)
        {
            if (ms < 200) ms = 200;
            if (ms > WheelLogic.TeachMs) ms = WheelLogic.TeachMs;
            teaching = true;
            try
            {
                lock (gate) { havePrev = false; }
                Poll();
                DateTime end = DateTime.UtcNow.AddMilliseconds(ms);
                while (DateTime.UtcNow < end)
                {
                    string edges = Poll();
                    if (edges.Length > 0)
                    {
                        string first = edges.Split(',')[0];
                        int d, b;
                        if (!WheelLogic.Bind(first, out d, out b)) return "";
                        SetBinding(first, true);
                        Vault.TestEvents.Add("teach " + first);
                        Log.W("wheel: taught button " + first);
                        return first;
                    }
                    Thread.Sleep(30);
                }
                Log.W("wheel: no button in " + ms + " ms");
                return "";
            }
            finally { teaching = false; }
        }

        public static string ReviewJson(bool open)
        {
            if (!Vault.Serving) return "{\"enabled\":false}";
            if (Driving())
            {
                Pump();
                return "{\"enabled\":true,\"up\":false,\"driving\":true,\"kept\":false,\"n\":0,\"defaultMs\":" + WheelLogic.DefaultMs + ",\"teachMs\":" + WheelLogic.TeachMs + ",\"line\":\"\",\"wheel\":" + Json_.S(binding) + "}";
            }
            if (open)
            {
                bool start;
                // C-27: until this irdash has seen a session at all (it was just restarted) nothing has ended, so there is no strip to show
                lock (gate) start = !up && (liveSince > 0 || Vault.SandboxOn);
                if (start)
                {
                    List<WLap> laps = TakeLaps();
                    lock (gate)
                    {
                        if (!up)
                        {
                            kept = false; up = true; snapshot = laps ?? new List<WLap>();
                            int w = (Vault.SandboxOn && testWaitMs > 0) ? testWaitMs : WheelLogic.DefaultMs;
                            waitMs = w; until = Vault.Now() + w;
                            Log.W("vault: after-race review is up (" + w + " ms, " + snapshot.Count + " laps)");
                        }
                    }
                }
            }
            Pump();
            return Body();
        }

        static string Body()
        {
            bool u, k; int n, left, w; string line, wheel; List<WLap> laps;
            lock (gate)
            {
                u = up; k = kept; w = waitMs; laps = snapshot ?? new List<WLap>();
                n = laps.Count; wheel = binding ?? "";
                left = u ? (int)Math.Max(0, until - Vault.Now()) : 0;
            }
            line = WheelLogic.Sentence(laps);
            bool pending = u && !k && n == 0;
            StringBuilder sb = new StringBuilder(256);
            sb.Append("{\"enabled\":true,\"up\":").Append(u ? "true" : "false").Append(",\"kept\":").Append(k ? "true" : "false")
              .Append(",\"driving\":false,\"pending\":").Append(pending ? "true" : "false").Append(",\"n\":").Append(n)
              .Append(",\"leftMs\":").Append(left).Append(",\"waitMs\":").Append(w).Append(",\"defaultMs\":").Append(WheelLogic.DefaultMs).Append(",\"teachMs\":").Append(WheelLogic.TeachMs).Append(",\"line\":")
              .Append(Json_.S(line)).Append(",\"wheel\":").Append(Json_.S(wheel)).Append(",\"laps\":[");
            for (int i = 0; i < laps.Count; i++)
            {
                if (i > 0) sb.Append(',');
                WLap x = laps[i];
                sb.Append("{\"lap\":").Append(x.Lap).Append(",\"time\":").Append(x.Time.ToString("0.000", Inv)).Append(",\"why\":").Append(Json_.S(x.Why ?? "")).Append('}');
            }
            sb.Append("]}");
            return sb.ToString();
        }

        static string Poll()
        {
            uint[] now = Copy(ReadNow());
            lock (gate)
            {
                if (!havePrev) { prevMask = now; havePrev = true; return ""; }
                string e = WheelLogic.Edges(prevMask, now);
                prevMask = now;
                return e;
            }
        }

        static uint[] Copy(uint[] a)
        {
            if (a == null) return new uint[0];
            uint[] c = new uint[a.Length];
            if (a.Length > 0) Array.Copy(a, c, a.Length);
            return c;
        }

        static uint[] ReadNow()
        {
            uint[] s;
            lock (gate) s = stub;
            if (s != null) return Copy(s);
            return ReadWinmm();
        }

        static uint[] ReadWinmm()
        {
            try
            {
                int n = joyGetNumDevs();
                if (n < 1) return new uint[0];
                if (n > 16) n = 16;
                uint[] m = new uint[n];
                for (int i = 0; i < n; i++)
                {
                    JOYINFOEX j = new JOYINFOEX();
                    j.dwSize = Marshal.SizeOf(typeof(JOYINFOEX));
                    j.dwFlags = JOY_RETURNBUTTONS;
                    if (joyGetPosEx(i, ref j) != 0) continue;
                    m[i] = (uint)j.dwButtons;
                }
                return m;
            }
            catch (Exception ex)
            {
                if (!winmmLogged) { winmmLogged = true; Log.W("wheel: joyGetPosEx: " + ex.Message); }
                return new uint[0];
            }
        }

        public static string SampleYaml()
        {
            return string.Join("\n", new string[] {
                "---",
                "WeekendInfo:",
                " TrackName: roadatlanta",
                " TrackID: 1",
                " TrackLength: 4.08 km",
                " TrackDisplayName: Road Atlanta",
                " TrackConfigName: Full Course",
                " WeekendOptions:",
                "  IncidentLimit: 17",
                "SessionInfo:",
                " Sessions:",
                " - SessionNum: 0",
                "   SessionType: Practice",
                "   SessionName: PRACTICE",
                " - SessionNum: 2",
                "   SessionType: Race",
                "   SessionName: RACE",
                "DriverInfo:",
                " DriverCarIdx: 0",
                " Drivers:",
                " - CarIdx: 0",
                "   UserName: Peter Pratt",
                "   CarNumber: \"4\"",
                "   CarScreenNameShort: Corvette Z06 GT3.R",
                "   CarIsPaceCar: 0",
                "   IsSpectator: 0",
                "   CarClassID: 1",
                "..."
            });
        }

        static string Q(Dictionary<string, string> q, string k) { string v; return q != null && q.TryGetValue(k, out v) ? v : ""; }

        // Test hook only (vault.cs checks that before calling). Stub masks stand in for a wheel.
        public static string TestJson(Dictionary<string, string> q)
        {
            string op = Q(q, "op");
            if (op == "edge") return "{\"edges\":" + Json_.S(WheelLogic.Edges(WheelLogic.Masks(Q(q, "prev")), WheelLogic.Masks(Q(q, "now")))) + "}";
            if (op == "act")
            {
                int dev, btn;
                int.TryParse(Q(q, "dev"), out dev); int.TryParse(Q(q, "btn"), out btn);
                string act = WheelLogic.Act(Q(q, "bind"), dev, btn, Q(q, "driving") == "1", Q(q, "review") == "1");
                return "{\"action\":" + Json_.S(act) + "}";
            }
            if (op == "line")
            {
                List<WLap> laps = WheelLogic.ParseLaps(Q(q, "laps"));
                return "{\"n\":" + laps.Count + ",\"line\":" + Json_.S(WheelLogic.Sentence(laps)) + "}";
            }
            if (op == "const") return "{\"teachMs\":" + WheelLogic.TeachMs + ",\"defaultMs\":" + WheelLogic.DefaultMs + "}";
            if (op == "stub")
            {
                if (Q(q, "off") == "1") SetStub(null);
                else SetStub(WheelLogic.Masks(Q(q, "masks")));
                return "{\"ok\":true}";
            }
            if (op == "baseline") { Baseline(); return "{\"ok\":true}"; }
            if (op == "bind") { SetBinding(Q(q, "val"), Q(q, "save") == "1"); return "{\"wheel\":" + Json_.S(binding) + "}"; }
            if (op == "reload") { ReadBinding(); return "{\"wheel\":" + Json_.S(binding) + "}"; }
            if (op == "seed")
            {
                if (Q(q, "clear") == "1") { SetSeed(null, 0); return "{\"ok\":true}"; }
                int secs; int.TryParse(Q(q, "secs"), out secs);
                int n = SetSeed(WheelLogic.ParseLaps(Q(q, "laps")), secs);
                return "{\"ok\":true,\"n\":" + n + "}";
            }
            if (op == "teach")
            {
                int ms; if (!int.TryParse(Q(q, "ms"), out ms) || ms <= 0) ms = 10000;
                string got = Teach(ms);
                return "{\"bind\":" + Json_.S(got) + "}";
            }
            return "{\"error\":\"bad op\"}";
        }
    }
#endif
}
