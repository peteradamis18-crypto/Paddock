// RigState (W0-2): the ONE answer to "is Peter busy?". Before this there were seven different tests (IsDriving, CarMoving, RealBusy,
// official's Busy, realworld's BusyWhy by reflection, Sdk.Latest.Connected, inline process lookups) and several actions that click,
// launch or delete used the wrong one (IsOnTrack is false in the garage with a session connected).
//   SimRunning   the sim program exists (checked every 2 s on a small background thread, never on the SDK or UI thread)
//   SessionOn    the SDK is connected and the sim program exists or its frames are still arriving (or the test hook's pretend session)
//   Driving      SessionOn and IsOnTrack (fed from every SDK frame)
//   StartPressed a START key was pressed in the last 10 minutes (dash\start-mark.txt; "TEST" marks do not count)
//   Busy         SessionOn || SimRunning || StartPressed (the same rule as tests\guard.ps1 Get-RigBusy), BusyWhy says why in one sentence
// Gate (below) holds the rules every route and command asks: the session guards, the X-Paddock header rule and the phone's lists.
// This file depends on nothing in irdash but Log, so tests\rigstate-test.ps1 and tests\session-guards-test.ps1 compile it alone.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

namespace IRDash
{
    static class RigState
    {
        public const string SimProcess = "iRacingSim64DX11";
        public const string NotInSession = "Not while a session is on.";

        static readonly object gate = new object();
        static volatile bool connected, onTrack, pretend, sim, start;
        static DateTime connectedSince = DateTime.MinValue, drivingSince = DateTime.MinValue, simSince = DateTime.MinValue, startSince = DateTime.MinValue;
        static DateTime lastProbe = DateTime.MinValue;
        static long lastFrameTicks;      // the last connected frame: frames still arriving means the sim is there, whatever its program is called
        static Thread prober;

        // test seams: a pretend sim process and clock (tests only; null = the real ones)
        public static Func<bool> SimProbe;
        public static Func<DateTime> Clock;
        public static string MarkFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "start-mark.txt");

        static DateTime Now { get { return Clock != null ? Clock() : DateTime.UtcNow; } }

        // ---- inputs ----
        // every SDK frame (Sdk.Publish): cheap, no scans, no files
        public static void Feed(bool isConnected, bool isOnTrack, bool isPretend)
        {
            if (isConnected) lastFrameTicks = Now.Ticks;
            bool track = isConnected && isOnTrack;
            if (isConnected != connected || track != onTrack)
            {
                lock (gate)
                {
                    DateTime now = Now;
                    if (isConnected != connected) connectedSince = now;
                    if (track != onTrack) drivingSince = now;
                    connected = isConnected; onTrack = track;
                }
            }
            pretend = isPretend;
        }

        // the sim process and the START mark, every 2 s on its own thread (a process scan must never delay a frame or the delta bar)
        public static void Start()
        {
            if (prober != null) return;
            Probe();
            prober = new Thread(delegate ()
            {
                while (true)
                {
                    Thread.Sleep(2000);
                    try { Probe(); } catch (Exception ex) { Log.W("rig state: " + ex.Message); }
                }
            });
            prober.IsBackground = true; prober.Priority = ThreadPriority.BelowNormal; prober.Name = "RigState"; prober.Start();
        }

        static Process held;     // once found, the sim is watched through its handle (HasExited costs nothing); a scan only while it is not there
        static bool SimAlive()
        {
            if (SimProbe != null) return SimProbe();
            try { if (held != null && !held.HasExited) return true; } catch { }
            if (held != null) { try { held.Dispose(); } catch { } held = null; }
            Process[] ps;
            try { ps = Process.GetProcessesByName(SimProcess); } catch { return false; }
            for (int i = 1; i < ps.Length; i++) { try { ps[i].Dispose(); } catch { } }
            if (ps.Length == 0) return false;
            // Reading Handle makes .NET open and KEEP a real handle: without it HasExited reopens the process by id on every look, and an id
            // reused by another program within the 2 s between looks would keep SimRunning true. No handle (a protected process): scan each time.
            try { IntPtr h = ps[0].Handle; if (h != IntPtr.Zero) held = ps[0]; else ps[0].Dispose(); } catch { try { ps[0].Dispose(); } catch { } }
            return true;
        }

        static bool MarkFresh()
        {
            try
            {
                string mark = MarkFile;
                if (string.IsNullOrEmpty(mark) || !File.Exists(mark)) return false;
                string[] p = File.ReadAllText(mark).Split('\t'); long t;
                return p.Length > 1 && p[1].Trim() != "TEST" && long.TryParse(p[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out t) &&
                       (Now - new DateTime(t, DateTimeKind.Utc)).TotalMinutes < 10;
            }
            catch { return false; }
        }

        // public for the tests; the prober calls it every 2 s
        static readonly object probeGate = new object();
        public static void Probe()
        {
            lock (probeGate)
            {
                bool s = SimAlive(), m = MarkFresh();
                lock (gate)
                {
                    DateTime now = Now;
                    if (s != sim) simSince = now;
                    if (m != start) startSince = now;
                    sim = s; start = m; lastProbe = now;
                }
            }
        }

        // a "free" answer is never older than the moment it is asked: when the cache says no, look again now (at most 4 times a
        // second, and only while that part is free, so never a scan per call in a race). A "busy" answer may be 2 s old: the safe side.
        static void FreshIfFree()
        {
            if ((Now - lastProbe).TotalMilliseconds < 250) return;
            try { Probe(); } catch { }
        }

        // ---- answers ----
        public static bool SimRunning { get { if (!sim) FreshIfFree(); return sim; } }
        // Connected AND (frames are still arriving OR the sim program exists). A sim that died leaves the SDK memory saying
        // "connected" with no new frames: that is not a session. A renamed sim program (a future DX12 build) with frames flowing still is.
        public static bool SessionOn { get { if (!connected) return false; if (pretend || (Now.Ticks - lastFrameTicks) < 2 * TimeSpan.TicksPerSecond) return true; if (!sim) FreshIfFree(); return sim; } }
        public static bool Driving { get { return onTrack && SessionOn; } }
        public static bool StartPressed { get { if (!start) FreshIfFree(); return start; } }
        public static bool Busy { get { return SessionOn || SimRunning || StartPressed; } }

        // one plain sentence, null = nothing is going on
        public static string BusyWhy
        {
            get
            {
                if (Driving) return "Peter is driving";
                if (SessionOn) return "a session is on";
                if (SimRunning) return "the sim is running";
                if (StartPressed) return "a START key was pressed in the last 10 minutes";
                return null;
            }
        }

        // Sdk.RealBusy (the test hook's gate): a REAL session only. The pretend session is the test hook's own, so it must not close the hook.
        public static string RealBusyWhy()
        {
            if (connected && !pretend) return "iRacing is connected";
            if (SimRunning) return "the sim is running";
            if (StartPressed) return "a START key was pressed in the last 10 minutes";
            return null;
        }

        // GET /rig/state: read-only, any caller (tests\guard.ps1 and the deck can share the one rule later)
        public static string Json()
        {
            bool s = SimRunning, on = SessionOn, d = Driving, st = StartPressed;
            string why = BusyWhy;
            DateTime cs, ds, ss, ts; lock (gate) { cs = connectedSince; ds = drivingSince; ss = simSince; ts = startSince; }
            StringBuilder sb = new StringBuilder("{");
            sb.Append("\"simRunning\":").Append(B(s)).Append(",\"sessionOn\":").Append(B(on)).Append(",\"driving\":").Append(B(d))
              .Append(",\"startPressed\":").Append(B(st)).Append(",\"busy\":").Append(B(why != null))
              .Append(",\"busyWhy\":").Append(why == null ? "null" : "\"" + why + "\"")
              .Append(",\"pretend\":").Append(B(pretend && connected))
              .Append(",\"since\":{\"simRunning\":").Append(T(ss)).Append(",\"sessionOn\":").Append(T(cs)).Append(",\"driving\":").Append(T(ds)).Append(",\"startPressed\":").Append(T(ts)).Append("}}");
            return sb.ToString();
        }
        static string B(bool b) { return b ? "true" : "false"; }
        static string T(DateTime t) { return t == DateTime.MinValue ? "null" : "\"" + t.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture) + "\""; }

        // ---- refusals: one plain sentence back, one log line a minute at most per action ----
        static readonly Dictionary<string, DateTime> lastSaid = new Dictionary<string, DateTime>();
        public static void LogOnce(string key, string line) { LogEvery(key, 60, line); }
        public static void LogEvery(string key, int seconds, string line)
        {
            lock (lastSaid)
            {
                DateTime t; DateTime now = Now;
                if (lastSaid.TryGetValue(key, out t) && (now - t).TotalSeconds < seconds) return;
                lastSaid[key] = now;
            }
            Log.W(line);
        }
        public static string Refuse(string what)
        {
            LogOnce("refuse " + what, "refused " + what + ": " + (BusyWhy ?? "a session is on"));
            return NotInSession;
        }
    }

    // The rules every route and command asks (one place, unit-tested). Only DeckSecret (below) reads a file.
    static class Gate
    {
        // ---- session guards: these click in iRacing, launch, restart or change files, so never while a session is on ----
        static readonly HashSet<string> GuardedDo = new HashSet<string> {
            "mdfindcar", "mdfindtrack", "mdfindlayout", "mdstart",      // MY DRIVE: iRacing UI automation (irdeck mydrive)
            "ovapply", "ovedit",                                         // OVERLAYS: restarts irdashies / sends its hotkey and moves focus
            "racedelete", "vkdelete",                                    // the Vault and the recorder: deletes of GB files
            "raceexport", "racewatch", "db-cosworth" };                  // RACES / DEBRIEF: open Explorer, a browser, the video player or Pi Toolbox on his screens
        // recsave and /api/rec/save are not here on purpose: SAVE of the session being recorded only writes a small note and must work
        // mid-session (recorder-test 13). Recorder.Save itself refuses the big move of a FINISHED session while one is on ("SESSION").

        // null = go ahead; else the command is one that must wait for the session to end
        public static bool IsGuardedDo(string c, string a)
        {
            if (c == null) return false;
            if (c == "ailevel") return (a ?? "").Trim().ToLowerInvariant() == "start";      // AI LEVEL's START runs irdeck airace (UI automation)
            return GuardedDo.Contains(c);
        }
        public static bool IsGuardedRoute(string path, IDictionary<string, string> q)
        {
            switch (path)
            {
                case "/api/rec/backfill": case "/api/rec/delete":
                case "/vault/delete":
                case "/vault/open": case "/share/open":                  // open Explorer / Pi Toolbox / the folder on his screens
                case "/analysis/pro/save": case "/analysis/pro/delete":
                    return true;
                case "/vault/edit":
                    { string v; return q != null && q.TryGetValue("star", out v) && v == "1"; }   // a star copies the 78 MB telemetry file
            }
            return false;
        }
        // the sentence to answer with (409), or null to go ahead
        public static string GuardDo(string c, string a) { return IsGuardedDo(c, a) && RigState.SessionOn ? RigState.Refuse(c + (c == "ailevel" ? " start" : "")) : null; }
        public static string GuardRoute(string path, IDictionary<string, string> q) { return IsGuardedRoute(path, q) && RigState.SessionOn ? RigState.Refuse(path) : null; }

        // ---- the X-Paddock header rule: a web page's blind fetch('http://localhost:8199/api/do?c=...') must not work ----
        static readonly HashSet<string> ReadOnlyApi = new HashSet<string> {
            "/api/tow-wait", "/api/kids", "/api/rec/races", "/api/rec/sessions", "/api/rec/for", "/api/rec/session-video" };
        public static bool ChangesState(string method, string path)
        {
            if (path == null) return false;
            if (method == "POST") return true;
            if (path.StartsWith("/api/", StringComparison.Ordinal)) return !ReadOnlyApi.Contains(path);
            switch (path)
            {
                case "/vault/edit": case "/vault/delete": case "/vault/open": case "/vault/scan":
                case "/analysis/pro/save": case "/analysis/pro/delete":
                case "/share/make": case "/share/open": case "/share/jump":
                case "/phone/revoke": case "/perf/scan":
                    return true;
            }
            return path.StartsWith("/vault/test/", StringComparison.Ordinal) || path.StartsWith("/perf/test/", StringComparison.Ordinal) || path.StartsWith("/share/test/", StringComparison.Ordinal);
        }

        static string H(IDictionary<string, string> hdr, string k) { string v; return hdr != null && hdr.TryGetValue(k, out v) ? (v ?? "") : ""; }

        // An opaque origin ("null"): the Stream Deck add-on (a local file page), but ALSO any web page that puts itself in a sandboxed or
        // data: iframe or goes through a cross-origin redirect. So "null" alone proves nothing: it needs the add-on's secret (DeckSecret).
        public static bool Opaque(string origin) { return origin == "null" || origin.StartsWith("file:", StringComparison.OrdinalIgnoreCase); }

        // origins that are Paddock's own: the top screen (same server). Never "null" (see Opaque).
        public static bool OwnOrigin(string origin, string host, int port)
        {
            if (origin == "http://localhost:" + port || origin == "http://127.0.0.1:" + port) return true;
            return host.Length > 0 && origin == "http://" + host;
        }

        // null = allowed; else why not (the request is answered 403)
        // local: the caller is this PC (and did not ask to be treated as a phone)
        public static string HeaderRefusal(IDictionary<string, string> hdr, bool local, int port) { return HeaderRefusal(hdr, local, port, DeckSecret.Active()); }
        // secret: the add-on's secret in force (dash\deck-secret.txt); null = the add-on is not yet installed with one
        public static string HeaderRefusal(IDictionary<string, string> hdr, bool local, int port, string secret)
        {
            string x = H(hdr, "X-Paddock"), site = H(hdr, "Sec-Fetch-Site"), origin = H(hdr, "Origin"), host = H(hdr, "Host");
            if (Opaque(origin))
            {
                if (secret != null) return x == secret ? null : "an opaque origin needs the Stream Deck add-on's secret";
                // Transition: until Peter clicks Install for the add-on that carries its secret, the deck keeps working as today.
                // That add-on's first request proves it is installed: from then on the secret is required (DeckSecret.Offer).
                if (x.Length > 1 && DeckSecret.Offer(x)) return null;
                RigState.LogEvery("deck-secret", 3600, "http: deck add-on not yet installed with its secret: a page with an opaque origin is still let through (deck-intro\\install.ps1, then Peter clicks Install)");
                return null;
            }
            if (x == "1" || (secret != null && x == secret)) return null;   // a foreign origin cannot send a custom header: its preflight is refused
            if (H(hdr, "X-Paddock-Token").Length > 0) return null;          // the phone app (a custom header: a page cannot send it blind either)
            if (site == "same-origin") return null;                         // the top-screen pages (Chrome tells us; a page cannot fake it)
            if (origin.Length > 0 && OwnOrigin(origin, host, port)) return null;
            // A program on this PC (irdeck, the tests, PowerShell) sends none of a browser's marks. A web page always does: Chrome, Edge and
            // Firefox add Sec-Fetch-Site (and Origin on a cross-site fetch) to every request to localhost, and neither can be removed by the page.
            if (local && site.Length == 0 && origin.Length == 0 && H(hdr, "Referer").Length == 0) return null;
            if (site == "none") return null;                                // typed in the address bar by hand
            return "a state-changing request needs the X-Paddock: 1 header";
        }

        // CORS preflight for the X-Paddock header: only from Paddock's own pages. A public web page asking for a local address carries
        // Access-Control-Request-Private-Network (Chrome) and is refused whatever its origin says.
        public static bool PreflightOk(IDictionary<string, string> hdr, int port)
        {
            string origin = H(hdr, "Origin");
            // an opaque origin may ASK (the add-on must be able to send the header); its real request then needs the secret
            if (origin.Length == 0 || !(Opaque(origin) || OwnOrigin(origin, H(hdr, "Host"), port))) return false;
            if (H(hdr, "Access-Control-Request-Private-Network").Length > 0) return false;
            return true;
        }
        public static string PreflightHeaders(IDictionary<string, string> hdr)
        {
            return "Access-Control-Allow-Origin: " + H(hdr, "Origin") + "\r\nAccess-Control-Allow-Methods: GET, POST\r\nAccess-Control-Allow-Headers: X-Paddock, X-Paddock-Token\r\nAccess-Control-Max-Age: 600\r\nVary: Origin\r\n";
        }

        // ---- the phone: only its own routes from the LAN (an allow-list, not a deny-list) ----
        static readonly HashSet<string> PhoneRoutes = new HashSet<string> {
            "/api/do", "/api/rec/for", "/api/rec/save", "/rig/state",
            "/sound", "/mydrive", "/overlays", "/replay", "/sessions", "/debrief",
            "/vault", "/vault/list", "/vault/open", "/vault/recorder", "/vault/thumb", "/vault/video",
            "/analysis/career", "/analysis/race", "/analysis/session",
            "/share/make", "/share/status", "/share/video" };
        // which network adapters the phone listener uses: the default-route one or any with a gateway, never a VPN or virtual one
        // (a full-tunnel VPN takes the default route; Hyper-V, WSL, VMware and the like have private addresses nobody's phone is on)
        static readonly string[] VirtualWords = { "vpn", "virtual", "hyper-v", "vethernet", "wsl", "vmware", "virtualbox", "tap-", "tap adapter", "tunnel", "wireguard", "openvpn", "nordlynx", "tailscale", "zerotier", "wintun", "loopback", "bluetooth" };
        public static bool PhoneAdapter(string name, string description, bool defaultRoute, bool hasGateway)
        {
            string s = ((name ?? "") + " " + (description ?? "")).ToLowerInvariant();
            foreach (string w in VirtualWords) if (s.Contains(w)) return false;
            return defaultRoute || hasGateway;
        }

        public static bool PhonePath(string path)
        {
            if (path == null) return false;
            if (path == "/phone" || path.StartsWith("/phone/", StringComparison.Ordinal)) return path != "/phone/qr";
            return PhoneRoutes.Contains(path);
        }

        // what a phone may still do while a session is on, taken from the phone page's own buttons (dash\www\phone\app.js KEYS that are
        // deck keys in keys\keys.map; tests\session-guards-test.ps1 checks the lists agree): the pit, chat, volume and black-box groups and
        // the in-car helpers of the session group. Start, quit, restart, skip and the PC keys wait.
        public static readonly string[] PhoneSessionKeyList = {
            "get-out", "tow", "spot-save", "spot-back",                                                // in the car: get out, reset, mark / back to spot
            "fuel-finish", "pit-tires", "pit-clear", "pit-fr", "pit-ws", "seat-down", "seat-up",      // pit
            "say-sorry", "say-thanks", "say-gg",                                                       // chat
            "vol-down", "vol-up", "mute",                                                              // volume
            "bb-f3", "bb-f1", "bb-f2", "bb-f4", "bb-f5", "bb-f8", "bb-f11" };                          // the sim's black boxes
        static readonly HashSet<string> PhoneSessionKeys = new HashSet<string>(PhoneSessionKeyList, StringComparer.OrdinalIgnoreCase);
        static readonly HashSet<string> PhoneSessionCmds = new HashSet<string> { "sndmute", "sndvol", "sndpreset", "deltaon", "deltaref" };
        public static bool PhoneMayWhileSession(string c, string a)
        {
            if (c == null) return false;
            if (c == "key") return PhoneSessionKeys.Contains((a ?? "").Trim());
            if (c.StartsWith("rp", StringComparison.Ordinal)) return true;      // the REPLAY tab: SDK replay messages only
            return PhoneSessionCmds.Contains(c);
        }
    }

    // The Stream Deck add-on's secret (W0-2 review). deck-intro\install.ps1 puts a random value into the installed plugin.html (its
    // PADDOCK_SECRET, sent as X-Paddock) and, while none is in force, into dash\deck-secret-new.txt. The first request that carries it
    // proves the new add-on is installed (Peter clicked Install): the value moves to dash\deck-secret.txt and from then on a page with an
    // opaque origin needs it. Waiting for that first request keeps today's add-on working until the click. Both files are gitignored (*.txt).
    static class DeckSecret
    {
        public static string Dir = AppDomain.CurrentDomain.BaseDirectory;
        static readonly object gate = new object();
        static string cached; static DateTime readAt = DateTime.MinValue;
        static string ActiveFile { get { return Path.Combine(Dir, "deck-secret.txt"); } }
        static string NewFile { get { return Path.Combine(Dir, "deck-secret-new.txt"); } }
        static string Read(string f) { try { if (!File.Exists(f)) return null; string v = File.ReadAllText(f).Trim(); return v.Length >= 16 ? v : null; } catch { return null; } }

        // the secret in force (null = none yet); the file is read again at most every 10 s
        public static string Active()
        {
            lock (gate)
            {
                if ((DateTime.UtcNow - readAt).TotalSeconds >= 10) { cached = Read(ActiveFile); readAt = DateTime.UtcNow; }
                return cached;
            }
        }
        public static void Forget() { lock (gate) readAt = DateTime.MinValue; }      // tests: read the files again now

        // a request carried this value: if it is the newly installed add-on's, it is in force from now on
        public static bool Offer(string value)
        {
            lock (gate)
            {
                string pending = Read(NewFile);
                if (pending == null || value != pending) return false;
                try { File.WriteAllText(ActiveFile, pending); try { File.Delete(NewFile); } catch { } }
                catch (Exception ex) { Log.W("http: could not store the deck add-on's secret: " + ex.Message); return false; }
                cached = pending; readAt = DateTime.UtcNow;
            }
            Log.W("http: the Stream Deck add-on is installed with its secret - a page with an opaque origin now needs it");
            return true;
        }
    }
}
