// StateBuilder (W0-5): ONE answer to "what does the top screen need to know?". Before this the page asked 14 routes on their own
// timers (about 16 requests a second sitting idle, 11 while Peter drives) and the deck add-on 6 routes every 2 s, each a new
// connection and a new thread. Now:
//   GET /state          one JSON object: every part below plus "seq" (rises when any part changed) and "now" (irdash's clock, unix ms)
//   /stream?state=1     the same parts pushed as "event: state" whenever seq rises (at most 4 times a second, only the parts that
//                       changed), so a page with the stream open never asks
//   GET /deck/summary   what every opener key on the deck paints, from the same parts (deck-only parts are made only when asked)
// Each part is one module's existing JSON, made on this one background thread at its own pace (faster when a module says Changed(),
// slower while Peter drives). A part only counts as changed when its words change (a seconds-ago counter does not).
// Also here: the www version (computed at start and when a file changes, never by walking the folder per request) and the
// session YAML parsed once into the few fields the pages use.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class StateBuilder
    {
        sealed class Part
        {
            public string Name; public Func<string> Make; public int IdleMs, DriveMs; public bool Deck;
            public string Json = "null", Cmp = null; public long Ver; public long At = -10000000; public volatile bool Dirty = true;
        }

        static readonly object gate = new object();
        static readonly List<Part> parts = new List<Part>();
        static readonly Dictionary<string, Part> byName = new Dictionary<string, Part>();
        static readonly Stopwatch clock = Stopwatch.StartNew();
        static readonly AutoResetEvent wake = new AutoResetEvent(false);
        static long seq, lastBump = -10000000, hotUntil;
        static Thread worker;

        // test seams: what "driving" means here (null = RigState.Driving) and the cached sim answer
        public static Func<bool> DrivingProbe;
        static volatile bool simCached; static long simAt = -10000000;

        public static long UnixMs { get { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; } }
        static bool Driving() { try { return DrivingProbe != null ? DrivingProbe() : RigState.Driving; } catch { return false; } }

        // ---- the parts ----
        public static void Add(string name, int idleMs, int driveMs, Func<string> make) { AddPart(name, idleMs, driveMs, make, false); }
        public static void AddDeck(string name, int everyMs, Func<string> make) { AddPart(name, everyMs, everyMs, make, true); }
        static void AddPart(string name, int idleMs, int driveMs, Func<string> make, bool deck)
        {
            lock (gate)
            {
                Part p;
                if (!byName.TryGetValue(name, out p)) { p = new Part(); p.Name = name; parts.Add(p); byName[name] = p; }
                p.Make = make; p.IdleMs = idleMs; p.DriveMs = driveMs; p.Deck = deck; p.Dirty = true;
            }
        }

        // a module changed something the screens show: look at that part now (not at its next turn)
        public static void Changed(string name)
        {
            Part p; lock (gate) byName.TryGetValue(name ?? "", out p);
            if (p != null) p.Dirty = true;
            wake.Set();
        }

        // a request that changes something came in (a deck press, a command): look at everything now, and keep looking twice a second
        // for 5 s, because the program the press started (irdeck) finishes a moment later. Not while he drives: one look only.
        public static void Poke(bool lists)
        {
            lock (gate) foreach (Part p in parts) if (!p.Deck) p.Dirty = true;
            if (!Driving()) hotUntil = clock.ElapsedMilliseconds + 5000;
            if (lists) BumpLists(true, true, true, true);
            wake.Set();
        }

        public static void Start()
        {
            lock (gate)
            {
                if (worker != null) return;
                worker = new Thread(Loop) { IsBackground = true, Priority = ThreadPriority.BelowNormal, Name = "state builder" };
                worker.Start();
            }
        }

        static void Loop()
        {
            while (true)
            {
                try { Tick(); } catch (Exception ex) { RigState.LogOnce("state tick", "state: " + ex.Message); }
                wake.WaitOne(250);
                // at most 4 changes a second: a Changed() right after a change waits for the rest of the 250 ms
                long gap = 250 - (clock.ElapsedMilliseconds - lastBump);
                if (gap > 0) Thread.Sleep((int)gap);
            }
        }

        // public for the tests (state-push-test drives it without the thread)
        public static void Tick()
        {
            long now = clock.ElapsedMilliseconds;
            bool driving = Driving(), hot = now < hotUntil;
            if (now - simAt >= 2000) { simAt = now; try { simCached = RigState.SimRunning; } catch { } }
            ListsTick(now);
            List<Part> todo = new List<Part>();
            lock (gate) foreach (Part p in parts) if (!p.Deck) todo.Add(p);
            List<Part> changed = new List<Part>();
            foreach (Part p in todo)
            {
                int every = driving ? p.DriveMs : p.IdleMs;
                if (hot && every > 500) every = 500;
                if (!p.Dirty && now - p.At < every) continue;
                p.Dirty = false; p.At = now;
                Make(p, changed);
            }
            if (changed.Count > 0)
            {
                lock (gate)
                {
                    seq++;
                    foreach (Part p in changed) p.Ver = seq;
                    lastBump = clock.ElapsedMilliseconds;
                    Monitor.PulseAll(gate);
                }
            }
        }

        // make one part; true (and added to changed) when its words changed
        static bool Make(Part p, List<Part> changed)
        {
            string j;
            try { j = p.Make(); }
            catch (Exception ex) { RigState.LogOnce("state part " + p.Name, "state: " + p.Name + ": " + ex.Message); return false; }
            if (string.IsNullOrEmpty(j)) j = "null";
            string c = Stable(j);
            if (c == p.Cmp) return false;
            lock (gate) { p.Json = j; p.Cmp = c; }
            changed.Add(p);
            return true;
        }

        // numbers that only count seconds (how long ago a check ran) are not a change worth a push
        static readonly Regex Ages = new Regex("\"(?:age|ageMs|deckAge)\":-?[0-9.]+", RegexOptions.Compiled);
        public static string Stable(string j) { return Ages.Replace(j, "\"age\":0"); }

        // ---- answers ----
        public static long Seq { get { lock (gate) return seq; } }

        // blocks up to ms for seq to move past last; returns the current seq
        public static long Wait(long last, int ms)
        {
            lock (gate) { if (seq == last) Monitor.Wait(gate, ms); return seq; }
        }

        // the whole object (GET /state, and the first push on a stream)
        public static string Json()
        {
            lock (gate)
            {
                StringBuilder sb = new StringBuilder(8192);
                sb.Append("{\"seq\":").Append(seq).Append(",\"now\":").Append(UnixMs).Append(",\"full\":true");
                foreach (Part p in parts) if (!p.Deck) sb.Append(",\"").Append(p.Name).Append("\":").Append(p.Json);
                return sb.Append('}').ToString();
            }
        }

        // only the parts that changed after seq "since" (a stream's later pushes); null when nothing did
        public static string Since(long since, out long upTo)
        {
            lock (gate)
            {
                upTo = seq;
                if (seq <= since) return null;
                StringBuilder sb = new StringBuilder(1024);
                sb.Append("{\"seq\":").Append(seq).Append(",\"now\":").Append(UnixMs);
                foreach (Part p in parts) if (!p.Deck && p.Ver > since) sb.Append(",\"").Append(p.Name).Append("\":").Append(p.Json);
                return sb.Append('}').ToString();
            }
        }

        public static string PartJson(string name) { lock (gate) { Part p; return byName.TryGetValue(name, out p) ? p.Json : "null"; } }

        // GET /deck/summary: the deck's opener keys. showcase is the deck's own /showcase?who=deck answer (it marks the deck as seen).
        // Deck-only parts are made here, on the asking thread, when they are older than their own interval.
        static readonly object deckGate = new object();
        public static string DeckJson(string showcase)
        {
            lock (deckGate)
            {
                long now = clock.ElapsedMilliseconds;
                List<Part> due = new List<Part>();
                lock (gate) foreach (Part p in parts) if (p.Deck && (p.Dirty || now - p.At >= p.IdleMs)) due.Add(p);
                List<Part> changed = new List<Part>();
                foreach (Part p in due) { p.Dirty = false; p.At = now; Make(p, changed); }
                if (changed.Count > 0) lock (gate) { long v = seq; foreach (Part p in changed) p.Ver = v; }
            }
            lock (gate)
            {
                StringBuilder sb = new StringBuilder(16384);
                sb.Append("{\"seq\":").Append(seq).Append(",\"now\":").Append(UnixMs).Append(",\"showcase\":").Append(string.IsNullOrEmpty(showcase) ? "null" : showcase);
                foreach (string[] n in DeckParts) { Part p; sb.Append(",\"").Append(n[0]).Append("\":").Append(byName.TryGetValue(n[1], out p) ? p.Json : "null"); }
                return sb.Append('}').ToString();
            }
        }
        // the summary's name -> the part: the shared parts the deck reads, then its own ("deckWorkbench" is what the ANALYSIS key shows,
        // /workbench/state; the page's "workbench" part is the deck's last command for the page)
        static readonly string[][] DeckParts = { new[] { "overlays", "overlays" }, new[] { "guest", "guest" }, new[] { "mydrive", "mydrive" }, new[] { "doctor", "doctor" },
            new[] { "replay", "replay" }, new[] { "races", "races" }, new[] { "workbench", "deckWorkbench" }, new[] { "sound", "sound" }, new[] { "ac", "ac" } };

        // ---- the lists an open page shows (Sessions, Vault, My Races, Performance): a number that rises when the list may have changed ----
        static long lSessions, lVault, lRaces, lPerf, lastBackstop;
        static bool wasSession; static readonly List<long> followUps = new List<long>();
        public static Func<int> PerfVersion;    // PerfStore + PerfChanges versions (set by the server; null in tests)
        public static void BumpLists(bool sessions, bool vault, bool races, bool perf)
        {
            if (sessions) Interlocked.Increment(ref lSessions);
            if (vault) Interlocked.Increment(ref lVault);
            if (races) Interlocked.Increment(ref lRaces);
            if (perf) Interlocked.Increment(ref lPerf);
            Changed("lists");
        }
        // after a session the files arrive over a few minutes (telemetry, the Vault copy, the race video): look again at 5 s, 30 s, 2 and 5 min.
        // Every 2 minutes anyway, so a list never stays wrong for long (today's pages asked every 10-20 s).
        static void ListsTick(long now)
        {
            bool on = false; try { on = RigState.SessionOn; } catch { }
            if (wasSession && !on) lock (followUps) { followUps.Clear(); foreach (int s in new[] { 5, 30, 120, 300 }) followUps.Add(now + s * 1000L); }
            wasSession = on;
            bool due = false;
            lock (followUps) for (int i = followUps.Count - 1; i >= 0; i--) if (now >= followUps[i]) { followUps.RemoveAt(i); due = true; }
            if (now - lastBackstop >= 120000) { if (lastBackstop != 0) due = true; lastBackstop = now; }
            if (due) BumpLists(true, true, true, false);
        }
        public static string ListsJson()
        {
            int pv = 0; try { if (PerfVersion != null) pv = PerfVersion(); } catch { }
            return "{\"sessions\":" + Interlocked.Read(ref lSessions) + ",\"vault\":" + Interlocked.Read(ref lVault) + ",\"races\":" + Interlocked.Read(ref lRaces) + ",\"perf\":" + (Interlocked.Read(ref lPerf) + pv) + "}";
        }

        public static string RigJson()
        {
            bool d = false, on = false; try { d = RigState.Driving; on = RigState.SessionOn; } catch { }
            if (DrivingProbe != null) d = Driving();
            return "{\"driving\":" + (d ? "true" : "false") + ",\"sessionOn\":" + (on ? "true" : "false") + ",\"simRunning\":" + (simCached ? "true" : "false") + ",\"online\":true}";
        }

        // ---- the www version: newest change to the dashboard files or the exe. The page reloads itself when it changes. ----
        static string wwwDir; static volatile string version = "0"; static FileSystemWatcher watcher; static Timer recount; static long lastWalk = -10000000;
        public static string Version
        {
            get
            {
                // no watcher (it could not start): walk at most every 15 s instead of on every request
                if (watcher == null && wwwDir != null && clock.ElapsedMilliseconds - lastWalk > 15000) Recount();
                return version;
            }
        }
        public static void WatchWww(string www)
        {
            wwwDir = www;
            recount = new Timer(delegate (object o) { Recount(); if (watcher == null) StartWatcher(); });
            Recount();
            StartWatcher();
        }
        static void StartWatcher()
        {
            FileSystemWatcher w = null;
            try
            {
                w = new FileSystemWatcher(wwwDir) { IncludeSubdirectories = true, NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.Size };
                FileSystemEventHandler later = delegate (object s, FileSystemEventArgs e) { try { recount.Change(400, Timeout.Infinite); } catch { } };   // a save is several events: count once after they settle
                w.Changed += later; w.Created += later; w.Deleted += later;
                w.Renamed += delegate (object s, RenamedEventArgs e) { try { recount.Change(400, Timeout.Infinite); } catch { } };
                // a watcher that fails (buffer overflow, the folder gone for a moment) stops for good: drop it, so the 15 s walk takes over
                // at once, and try a new one with the next count (in 5 s)
                w.Error += delegate (object s, ErrorEventArgs e)
                {
                    FileSystemWatcher dead = watcher; watcher = null;
                    try { if (dead != null) dead.Dispose(); } catch { }
                    RigState.LogOnce("www watcher", "www watcher stopped: " + (e.GetException() != null ? e.GetException().Message : "?") + " (recounting, a new watcher in 5 s)");
                    try { recount.Change(5000, Timeout.Infinite); } catch { }
                };
                w.EnableRaisingEvents = true;
                watcher = w;
            }
            catch (Exception ex)
            {
                watcher = null; try { if (w != null) w.Dispose(); } catch { }
                RigState.LogOnce("www watcher", "www watcher: " + ex.Message + " (the version is recounted every 15 s instead)");
                try { recount.Change(15000, Timeout.Infinite); } catch { }
            }
        }
        // test seam: what happens when the watcher fails
        public static void WatcherFailedForTest() { FileSystemWatcher dead = watcher; watcher = null; try { if (dead != null) dead.Dispose(); } catch { } try { recount.Change(5000, Timeout.Infinite); } catch { } }
        public static bool Watching { get { return watcher != null; } }
        static readonly object walkGate = new object();
        static void Recount()
        {
            lock (walkGate)
            {
                lastWalk = clock.ElapsedMilliseconds;
                try
                {
                    // a hash over every file's name, size and time (and the exe's time): a file copied in with an OLDER time still
                    // changes it (the newest time alone did not, and ?v= scripts are kept by the browser for good)
                    ulong h = 14695981039346656037UL;
                    Action<string> mix = delegate (string t) { foreach (char ch in t) { h ^= ch; h *= 1099511628211UL; } h ^= 0xFF; h *= 1099511628211UL; };
                    try { mix(File.GetLastWriteTimeUtc(System.Reflection.Assembly.GetExecutingAssembly().Location).Ticks.ToString(CultureInfo.InvariantCulture)); } catch { }
                    if (wwwDir != null)
                    {
                        string[] files = Directory.GetFiles(wwwDir, "*", SearchOption.AllDirectories);
                        Array.Sort(files, StringComparer.OrdinalIgnoreCase);
                        foreach (string f in files)
                        {
                            if (f.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) continue;
                            FileInfo fi = new FileInfo(f);
                            mix(f.Substring(wwwDir.Length).ToLowerInvariant()); mix(fi.Length.ToString(CultureInfo.InvariantCulture)); mix(fi.LastWriteTimeUtc.Ticks.ToString(CultureInfo.InvariantCulture));
                        }
                    }
                    string s = (h % 1000000000000000000UL).ToString(CultureInfo.InvariantCulture);
                    if (s != version) { version = s; Changed("version"); }
                }
                catch (Exception ex) { RigState.LogOnce("www version", "www version: " + ex.Message); }
            }
        }

        // ---- the session: iRacing's YAML parsed once here, only the fields the pages read, under the same names ----
        // ---- W2-1: the race screen's part (PLAN 4.2; the card's JSON is the contract docs/rework/cards/W2-1.md item 4) ----
        // Made on this thread's 4 Hz tick from the latest frame, the parsed session and the fuel tracker; "null" out of a session.
        // Standings order is not here: the page sorts the stream's CarIdxClassPosition and takes the names from the session part.
        // The card's JSON names "lap" twice (the lap number, then the lap times object): both are written in that order, so JSON.parse
        // keeps the object; the number is also "lapNum".
        static string R(double v, string fmt) { return double.IsNaN(v) || double.IsInfinity(v) ? "null" : v.ToString(fmt, CultureInfo.InvariantCulture); }
        static string Pos(double v) { return v >= 1 ? ((int)v).ToString(CultureInfo.InvariantCulture) : "null"; }
        public static string RacePart()
        {
            Frame f = Sdk.Latest;
            SdkSession s = Sdk.Session;
            if (f == null || !f.Connected || s == null) return "null";
            int me = Sdk.Has(f, "PlayerCarIdx") ? (int)f.Num("PlayerCarIdx") : s.PlayerIdx;
            SdkDriver d = s.Driver(me);
            int sessNum = (int)f.Num("SessionNum");
            SdkSessionRow row = s.For(sessNum);
            string type = row != null ? row.Type : s.Type;
            int laps = row != null ? row.Laps : s.Laps;
            FuelView fv = Fuel.Live.View();
            double remain = f.Num("SessionTimeRemain");
            bool lapRace = laps > 0;
            uint raw = unchecked((uint)(long)f.Num("SessionFlags"));
            bool caution = Fuel.Caution(raw), green = (raw & (Fuel.NotGreenMask | 0x1)) == 0;
            double last = f.Num("LapLastLapTime"), best = f.Num("LapBestLapTime");
            string loss = "null";
            if (Fuel.PitLossFor != null) { try { double? pl = Fuel.PitLossFor(s.Track); if (pl.HasValue) loss = R(pl.Value, "0.0"); } catch { } }
            string lapNo = ((int)f.Num("Lap")).ToString(CultureInfo.InvariantCulture);
            StringBuilder sb = new StringBuilder(700);
            sb.Append("{\"on\":true,\"type\":").Append(IRDash.Json.Str(type)).Append(",\"multiclass\":").Append(s.Multiclass ? "true" : "false");
            sb.Append(",\"me\":{\"idx\":").Append(me).Append(",\"num\":").Append(IRDash.Json.Str(d == null ? "" : d.Num)).Append(",\"name\":").Append(IRDash.Json.Str(d == null ? "" : d.ShortName))
              .Append(",\"classId\":").Append(d == null ? 0 : d.ClassId).Append(",\"classColor\":").Append(IRDash.Json.Str(d == null ? "" : d.ClassColor)).Append('}');
            sb.Append(",\"pos\":").Append(Pos(Sdk.NumAt(f, "CarIdxPosition", me))).Append(",\"of\":").Append(s.Field(-1))
              .Append(",\"classPos\":").Append(Pos(Sdk.NumAt(f, "CarIdxClassPosition", me))).Append(",\"classOf\":").Append(s.Field(d == null ? -1 : d.ClassId));
            sb.Append(",\"lap\":").Append(lapNo).Append(",\"lapNum\":").Append(lapNo).Append(",\"laps\":").Append(lapRace ? laps.ToString(CultureInfo.InvariantCulture) : "null")
              .Append(",\"toGo\":").Append(fv.ToGo.HasValue ? fv.ToGo.Value.ToString(CultureInfo.InvariantCulture) : "null")
              .Append(",\"timeLeft\":").Append(!lapRace && remain >= 0 && remain <= 86400 ? R(remain, "0.0") : "null")
              .Append(",\"clock\":").Append(R(f.Num("SessionTime"), "0.0"));
            sb.Append(",\"inc\":{\"n\":").Append((int)f.Num("PlayerCarMyIncidentCount")).Append(",\"limit\":").Append(s.IncidentLimit > 0 ? s.IncidentLimit.ToString(CultureInfo.InvariantCulture) : "null").Append('}');
            sb.Append(",\"flags\":{\"caution\":").Append(caution ? "true" : "false").Append(",\"green\":").Append(green ? "true" : "false").Append(",\"raw\":").Append(raw).Append('}');
            sb.Append(",\"pit\":{\"onRoad\":").Append(f.Num("OnPitRoad") != 0 ? "true" : "false").Append(",\"loss\":").Append(loss).Append(",\"rejoin\":null}");
            sb.Append(",\"fuel\":").Append(fv.Json());
            sb.Append(",\"lap\":{\"last\":").Append(last > 0 ? R(last, "0.000") : "null").Append(",\"best\":").Append(best > 0 ? R(best, "0.000") : "null")
              .Append(",\"lastIsBest\":").Append(last > 0 && best > 0 && Math.Abs(last - best) < 0.0005 ? "true" : "false")
              .Append(",\"delta\":").Append(R(f.Num("LapDeltaToBestLap"), "0.00")).Append(",\"deltaOk\":").Append(f.Num("LapDeltaToBestLap_OK") != 0 ? "true" : "false").Append('}');
            return sb.Append('}').ToString();
        }

        // W2-1: the SDK reader has already parsed this version (Sdk.Session, on its own thread): its JSON is used, no second parse
        static int sessVer = int.MinValue; static string sessJson = "null";
        public static string SessionPart(bool connected, int ver, string yaml)
        {
            if (!connected) { sessVer = int.MinValue; sessJson = "null"; return sessJson; }
            if (ver == sessVer) return sessJson;
            sessVer = ver;
            SdkSession s = Sdk.Session;
            sessJson = s != null && s.Ver == ver && ReferenceEquals(s.Yaml, yaml) ? s.Json : SessionJson(yaml, ver);
            return sessJson;
        }

        static readonly string[] DriverInfoKeys = { "DriverCarIdx", "DriverUserID", "DriverCarFuelMaxLtr", "DriverCarMaxFuelPct", "DriverCarSLFirstRPM", "DriverCarSLShiftRPM", "DriverCarSLLastRPM", "DriverCarSLBlinkRPM", "DriverCarRedLine", "DriverCarIdleRPM" };
        static readonly string[] DriverKeys = { "CarIdx", "UserName", "TeamName", "CarNumber", "CarScreenName", "CarScreenNameShort", "CarClassID", "CarClassShortName", "CarClassColor", "CarClassEstLapTime", "IRating", "LicString", "LicColor", "CarIsPaceCar", "IsSpectator", "CarPath", "CarID", "UserID" };
        static readonly string[] SessionKeys = { "SessionNum", "SessionType", "SessionName", "SessionLaps", "SessionTime" };
        static readonly string[] ResultKeys = { "CarIdx", "Position", "ClassPosition", "FastestTime", "LastTime", "LapsComplete" };

        public static string SessionJson(string yaml, int ver)
        {
            if (string.IsNullOrEmpty(yaml)) return "null";
            Dictionary<string, object> y;
            try { y = ParseYaml(yaml); } catch (Exception ex) { RigState.LogOnce("session yaml", "state: session yaml: " + ex.Message); return "null"; }
            return SessionJsonOf(y, ver);
        }
        // the same JSON from a YAML already parsed (sdkreader.cs parses once per version and hands the tree here)
        public static string SessionJsonOf(Dictionary<string, object> y, int ver)
        {
            if (y == null) return "null";
            StringBuilder sb = new StringBuilder(8192);
            sb.Append("{\"ver\":").Append(ver);
            object wi; if (y.TryGetValue("WeekendInfo", out wi)) { sb.Append(",\"WeekendInfo\":"); Write(sb, wi); }
            Dictionary<string, object> di = Map(y, "DriverInfo");
            if (di != null)
            {
                sb.Append(",\"DriverInfo\":{");
                bool first = true;
                foreach (string k in DriverInfoKeys) { object v; if (di.TryGetValue(k, out v) && v is string) { if (!first) sb.Append(','); first = false; sb.Append(IRDash.Json.Str(k)).Append(':').Append(IRDash.Json.Str((string)v)); } }
                if (!first) sb.Append(',');
                sb.Append("\"Drivers\":"); Rows(sb, List(di, "Drivers"), DriverKeys, null, null);
                sb.Append('}');
            }
            Dictionary<string, object> si = Map(y, "SessionInfo");
            if (si != null) { sb.Append(",\"SessionInfo\":{\"Sessions\":"); Rows(sb, List(si, "Sessions"), SessionKeys, "ResultsPositions", ResultKeys); sb.Append('}'); }
            Dictionary<string, object> st = Map(y, "SplitTimeInfo");
            if (st != null) { sb.Append(",\"SplitTimeInfo\":{\"Sectors\":"); Rows(sb, List(st, "Sectors"), new[] { "SectorNum", "SectorStartPct" }, null, null); sb.Append('}'); }
            return sb.Append('}').ToString();
        }

        static Dictionary<string, object> Map(Dictionary<string, object> d, string k) { object v; return d != null && d.TryGetValue(k, out v) ? v as Dictionary<string, object> : null; }
        static List<object> List(Dictionary<string, object> d, string k) { object v; return d != null && d.TryGetValue(k, out v) ? v as List<object> : null; }
        static void Rows(StringBuilder sb, List<object> rows, string[] keys, string subName, string[] subKeys)
        {
            sb.Append('[');
            bool firstRow = true;
            if (rows != null)
                foreach (object o in rows)
                {
                    Dictionary<string, object> r = o as Dictionary<string, object>; if (r == null) continue;
                    if (!firstRow) sb.Append(','); firstRow = false;
                    sb.Append('{'); bool first = true;
                    foreach (string k in keys) { object v; if (r.TryGetValue(k, out v) && v is string) { if (!first) sb.Append(','); first = false; sb.Append(IRDash.Json.Str(k)).Append(':').Append(IRDash.Json.Str((string)v)); } }
                    if (subName != null) { if (!first) sb.Append(','); sb.Append(IRDash.Json.Str(subName)).Append(':'); Rows(sb, List(r, subName), subKeys, null, null); }
                    sb.Append('}');
                }
            sb.Append(']');
        }
        static void Write(StringBuilder sb, object o)
        {
            Dictionary<string, object> m = o as Dictionary<string, object>;
            if (m != null) { sb.Append('{'); bool f = true; foreach (KeyValuePair<string, object> kv in m) { if (!f) sb.Append(','); f = false; sb.Append(IRDash.Json.Str(kv.Key)).Append(':'); Write(sb, kv.Value); } sb.Append('}'); return; }
            List<object> l = o as List<object>;
            if (l != null) { sb.Append('['); for (int i = 0; i < l.Count; i++) { if (i > 0) sb.Append(','); Write(sb, l[i]); } sb.Append(']'); return; }
            if (o == null) { sb.Append("null"); return; }
            sb.Append(IRDash.Json.Str(o.ToString()));
        }

        // iRacing's session YAML: the same small parser the page used (core.js parseYaml), so the values are the same strings
        sealed class YLine { public int Ind; public string S; }
        public static Dictionary<string, object> ParseYaml(string text)
        {
            List<YLine> lines = new List<YLine>();
            foreach (string raw0 in text.Split('\n'))
            {
                string raw = raw0.TrimEnd('\r');
                string t = raw.Trim();
                if (t.Length == 0 || t == "---" || t == "..." || t.StartsWith("#", StringComparison.Ordinal)) continue;
                lines.Add(new YLine { Ind = raw.Length - raw.TrimStart().Length, S = t });
            }
            int[] i = { 0 };
            Dictionary<string, object> root = new Dictionary<string, object>();
            while (i[0] < lines.Count)
            {
                int before = i[0];
                foreach (KeyValuePair<string, object> kv in YMap(lines, i, lines[i[0]].Ind)) root[kv.Key] = kv.Value;
                if (i[0] == before) i[0]++;
            }
            return root;
        }
        static bool IsItem(YLine l) { return l.S == "-" || l.S.StartsWith("- ", StringComparison.Ordinal); }
        static string Scalar(string v)
        {
            v = v.Trim();
            if (v.Length >= 2 && ((v[0] == '"' && v[v.Length - 1] == '"') || (v[0] == '\'' && v[v.Length - 1] == '\''))) return v.Substring(1, v.Length - 2);
            return v;
        }
        static object YNode(List<YLine> lines, int[] i)
        {
            if (i[0] >= lines.Count) return null;
            return IsItem(lines[i[0]]) ? (object)YList(lines, i, lines[i[0]].Ind) : YMap(lines, i, lines[i[0]].Ind);
        }
        static Dictionary<string, object> YMap(List<YLine> lines, int[] i, int ind)
        {
            Dictionary<string, object> obj = new Dictionary<string, object>();
            while (i[0] < lines.Count && lines[i[0]].Ind == ind && !IsItem(lines[i[0]]))
            {
                string s = lines[i[0]].S; int c = s.IndexOf(':');
                i[0]++;
                if (c < 0) continue;
                string k = s.Substring(0, c).Trim(), v = s.Substring(c + 1).Trim();
                if (v.Length > 0) obj[k] = Scalar(v);
                else if (i[0] < lines.Count && (lines[i[0]].Ind > ind || (lines[i[0]].Ind == ind && IsItem(lines[i[0]])))) obj[k] = YNode(lines, i);
                else obj[k] = "";
            }
            return obj;
        }
        static List<object> YList(List<YLine> lines, int[] i, int ind)
        {
            List<object> arr = new List<object>();
            while (i[0] < lines.Count && lines[i[0]].Ind == ind && IsItem(lines[i[0]]))
            {
                string rest = lines[i[0]].S.Substring(1).TrimStart();
                if (rest.Length == 0) { i[0]++; arr.Add(YNode(lines, i)); continue; }
                int itemInd = ind + (lines[i[0]].S.Length - rest.Length);
                if (rest.IndexOf(':') < 0) { arr.Add(Scalar(rest)); i[0]++; continue; }
                lines[i[0]] = new YLine { Ind = itemInd, S = rest };      // the item's first key sits on the dash line
                arr.Add(YMap(lines, i, itemInd));
            }
            return arr;
        }
    }
}
