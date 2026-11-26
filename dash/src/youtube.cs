// YOUTUBE (W1-2, docs/rework/cards/W1-2.md, evidence 14): Google sign-in once (loopback + PKCE, the token kept with DPAPI in
// dash\yt\token.bin) and the resumable upload that survives a network drop, a session starting, an irdash or PC restart, never
// uploads a race twice, and says what went wrong in plain words.
//   dash\yt\client.json           Peter's Desktop-app client from Google (docs\YOUTUBE-SETUP.md). Never logged.
//   dash\yt\token.bin             DPAPI (this Windows user) of {"refresh","access","expMs"}. Never logged.
//   dash\yt\session-<race>.json   one per half-sent race: its session URL is saved BEFORE the first byte, so a restart resumes it
//   dash\yt\uploads.json          per race id: the "never twice" record and what the RACES page shows
// SignIn() is the only thing that opens a browser (the ytsignin press; the lead lists it as GuardedDo in rigstate.cs). The upload
// job never opens anything: a race that needs a sign-in just shows kind "signin".
// Enqueue() only writes a small record; the upload itself is a Jobs whenFree job (never while a session is on, background
// priority), 8 MiB per PUT, and it stops at the next step when a session starts (Jobs.ShouldYield).
// The race is "shared" only when YouTube's own answer to the finished upload names the video and says uploaded/processed.
// (videos.list is not allowed with the youtube.upload scope, so the insert's own answer is the read-back.)
// The log says "youtube: signed in" and what happened to a race, never a secret, a code, a token or the session URL.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class YouTube
    {
        // ---- every Google address and every timing is a static, so the test can point them at its pretend Google ----
        public static string AuthUrl = "https://accounts.google.com/o/oauth2/v2/auth";
        public static string TokenUrl = "https://oauth2.googleapis.com/token";
        public static string UploadUrl = "https://www.googleapis.com/upload/youtube/v3";
        public static string ApiUrl = "https://www.googleapis.com/youtube/v3";       // kept for later calls; the upload needs none
        public static string Dir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "yt");            // irdash.exe lives in dash\
        public static string IniFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "irdash.ini");
        public static Action<string> OpenBrowser = DefaultOpen;
        public static int ChunkSize = 8 * 1024 * 1024;       // a multiple of 256 KiB (Google's rule for every chunk but the last)
        public static int BackoffBaseMs = 2000, BackoffMaxMs = 300000;   // 2, 4, 8 ... 300 s after a dropped link or a 5xx
        public static int OfflineRetryMs = 60000;            // no internet: look again every minute, for ever
        public static int SignInTimeoutMs = 0;               // 0 = the sign-in page waits as long as irdash runs (2026-11-15: a 5-minute window closed twice before Peter got to Chrome); tests set a short one
        public static int SliceMs = 120000;                  // a long upload hands the job thread back every 2 minutes
        public static Func<DateTime> Clock;                  // local time, for the "after 9 in the morning" retry (tests)

        public const string Scope = "https://www.googleapis.com/auth/youtube.upload";
        public const string MsgSetup = "Set up YouTube first: docs\\YOUTUBE-SETUP.md";
        public const string MsgSignIn = "Sign in to YouTube";
        public const string MsgSignInAgain = "Sign in to YouTube again";
        public const string MsgQuota = "YouTube says today's upload limit is reached. I'll try again after 9 in the morning";
        public const string MsgOffline = "No internet, waiting";
        public const string MsgAlready = "Already on YouTube";
        public const string MsgDailyWait = "YouTube's daily limit is reached. Trying again after 9 in the morning";
        public const string MsgChannel = "Make a YouTube channel first: open youtube.com with your Google account";
        public const string SignedInPage = "Paddock is signed in to YouTube.";
        public const string NotSignedInPage = "Paddock was not signed in to YouTube.";
        public const string FailedPage = "Paddock could not sign in to YouTube. Press Sign in to YouTube again.";
        public const string DoneTitle = "Paddock: signed in to YouTube", NotDoneTitle = "Paddock: not signed in to YouTube";   // the final page's title: Paddock closes the sign-in window it opened while it shows that
        public const string ClosesLine = "This window closes by itself. If it stays, close it.";
        public const string GoogleTitle = "Sign in - Google Accounts";   // the title of Google's sign-in pages, as the app-mode window shows it
        public const string OldPage = "This sign-in page is out of date. On the top screen, open RACES and press Sign in to YouTube again.";
        public const string EntropyText = "Paddock YouTube token";   // extra DPAPI salt: another program of Peter's cannot just call Unprotect
        const string JobName = "youtube upload";

        sealed class Rec
        {
            public string Race = "", Kind = "queued", File = "", Title = "", Desc = "", Want = "private", Thumb = "";
            public string Tags = "";        // W1-11: snippet.tags, one per line
            public string ThumbSet = "";    // W1-11: "" not tried, "set", "refused" (403: the channel is not verified), "skipped" (quota), "failed"
            public string VideoId = "", Url = "", Privacy = "", UploadStatus = "", Error = "";
            public int Pct, Tries, Restarts;
            public long StartedMs, DoneMs, RetryAtMs;
        }
        sealed class Sess { public string Race = "", File = "", Url = "", Title = "", Privacy = ""; public long Size, Sent, StartedMs; }
        sealed class Tok { public string Refresh = "", Access = ""; public long ExpMs; }
        sealed class Resp { public int Status; public string Body = ""; public WebHeaderCollection Headers = new WebHeaderCollection(); }

        // how one race's turn ended
        const long NEXT = -1, YIELD = -2, SLICE = -3, STOP = -4;      // >= 0: wait that many ms, then try again

        // a stop that is not a network fault: kind + plain message (+ when to try again)
        sealed class Halt : Exception
        {
            public string Kind, Msg; public long RetryAtMs;
            public Halt(string kind, string msg, long retryAtMs) : base(msg) { Kind = kind; Msg = msg; RetryAtMs = retryAtMs; }
        }
        sealed class Transient : Exception { public Transient(string m) : base(m) { } }
        sealed class YieldNow : Exception { }

        static readonly object gate = new object();
        static List<Rec> recs;               // null = not read from disk yet
        static Tok tok; static bool tokRead;
        static Timer timer;
        static volatile bool signingIn, paused, busy;
        static volatile string openAuthUrl;  // the sign-in page while it waits: a second press opens it again
        static TcpListener listening;        // the sign-in's socket while it waits (Reset closes it as a stopped irdash would)
        static IntPtr signInWindow;          // the sign-in's own browser window (Chrome/Edge app mode); zero when none or not known
        static bool thumbTold;

        static long NowMs { get { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; } }
        static DateTime LocalNow { get { return Clock != null ? Clock() : DateTime.Now; } }
        static string ClientFile { get { return Path.Combine(Dir, "client.json"); } }
        static string TokenFile { get { return Path.Combine(Dir, "token.bin"); } }
        static string PendingFile { get { return Path.Combine(Dir, "pending.bin"); } }   // a sign-in page that waits: port, state, verifier (DPAPI)
        static string UploadsFile { get { return Path.Combine(Dir, "uploads.json"); } }
        static string SessionFile(string race) { return Path.Combine(Dir, "session-" + Regex.Replace(race ?? "", "[^A-Za-z0-9_-]", "_") + ".json"); }

        // ================= start-up =================

        // irdash start (after Jobs.Start): anything left queued or half-sent (a restart, a PC reboot) carries on when the rig is free.
        // Calling it twice does no harm: the job is queued once.
        public static void Start()
        {
            try { ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072; } catch { }   // TLS 1.2 for Google
            long wait = -1;
            lock (gate)
            {
                Load();
                long now = NowMs;
                foreach (Rec r in recs)
                    if (Pending(r)) { long w = Math.Max(0, r.RetryAtMs - now); if (wait < 0 || w < wait) wait = w; }
            }
            if (wait >= 0) Kick(wait);
            ResumeSignIn();
        }

        // tests: forget everything held in memory and read it again from dash\yt, as a new irdash process would
        public static void Reset()
        {
            AbortSignIn();
            paused = true;
            for (int i = 0; i < 100 && busy; i++) Thread.Sleep(50);
            lock (gate)
            {
                if (timer != null) { try { timer.Dispose(); } catch { } timer = null; }
                recs = null; tok = null; tokRead = false; thumbTold = false;
            }
            paused = false;
        }

        // ================= settings (irdash.ini) =================
        // Written with Config.SetKey, the one setter every irdash.ini key goes through (a flat key=value file), so the keys are
        // youtube_privacy and youtube_template.

        public static string Privacy { get { string p = IniGet("youtube_privacy", "private").ToLowerInvariant(); return p == "public" ? "public" : "private"; } }
        public static int Template { get { int n; return int.TryParse(IniGet("youtube_template", "1"), out n) && n >= 1 && n <= 5 ? n : 1; } }

        // W1-11: the line Peter writes once under every description (youtube_signoff=...; empty or missing = none)
        public static string Signoff { get { string s = IniGet("youtube_signoff", ""); return s.Length > 300 ? s.Substring(0, 300) : s; } }

        public static bool SetPrivacy(string p)
        {
            p = (p ?? "").Trim().ToLowerInvariant();
            if (p != "private" && p != "public") return false;
            Config.SetKey(IniFile, "youtube_privacy", p); Log.W("youtube: new uploads are " + p); Bump();
            return true;
        }
        public static bool SetTemplate(int n)
        {
            if (n < 1 || n > 5) return false;
            Config.SetKey(IniFile, "youtube_template", n.ToString(CultureInfo.InvariantCulture)); Bump();
            return true;
        }

        static string IniGet(string key, string def)
        {
            try
            {
                if (!File.Exists(IniFile)) return def;
                foreach (string raw in File.ReadAllLines(IniFile))
                {
                    string t = raw.Trim();
                    if (t.StartsWith(";") || t.StartsWith("#")) continue;
                    int e = t.IndexOf('=');
                    if (e > 0 && t.Substring(0, e).Trim().Equals(key, StringComparison.OrdinalIgnoreCase)) return t.Substring(e + 1).Trim();
                }
            }
            catch { }
            return def;
        }

        // ================= read side (RACES page, deck) =================

        // the "state" object of /api/library for one race
        public static string StateJson(string raceId)
        {
            lock (gate)
            {
                Load();
                Rec r = Find(raceId);
                if (r == null) return "{\"kind\":\"none\"}";
                switch (r.Kind)
                {
                    case "shared": return "{\"kind\":\"shared\",\"pct\":100,\"privacy\":" + Json_.S(r.Privacy) + ",\"url\":" + Json_.S(r.Url) + "}";
                    case "sharing": return "{\"kind\":\"sharing\",\"pct\":" + r.Pct.ToString(CultureInfo.InvariantCulture) + "}";
                    case "queued": return "{\"kind\":\"queued\",\"pct\":0}";
                    case "failed":
                        // the daily limit is not a failure: the race waits for its retry time (W1-4 review: gold, not red, and SHARE does not cut it again)
                        if (r.RetryAtMs > 0) return "{\"kind\":\"queued\",\"pct\":0,\"error\":" + Json_.S(MsgDailyWait) + "}";
                        return "{\"kind\":\"failed\",\"error\":" + Json_.S(r.Error) + "}";
                    case "signin": case "offline": return "{\"kind\":\"" + r.Kind + "\",\"error\":" + Json_.S(r.Error) + "}";
                }
                return "{\"kind\":\"none\"}";
            }
        }

        // 2026-11-14: Peter's setup ends with Google handing him a file called client_secret...json; renaming and moving it was four of the
        // steps. Paddock takes the newest one from his Downloads folder by itself (a look every 10 s while there is no client yet).
        static DateTime lastDownloadsLook = DateTime.MinValue;
        internal static void PickUpClient()
        {
            try
            {
                if (File.Exists(ClientFile) || (DateTime.UtcNow - lastDownloadsLook).TotalSeconds < 10) return;
                lastDownloadsLook = DateTime.UtcNow;
                string dl = Environment.GetEnvironmentVariable("PADDOCK_DOWNLOADS");     // tests point this at a folder of their own
                if (string.IsNullOrEmpty(dl)) dl = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
                if (!Directory.Exists(dl)) return;
                string best = null; DateTime bestAt = DateTime.MinValue;
                foreach (string f in Directory.GetFiles(dl, "client_secret*.json"))
                {
                    DateTime at = File.GetLastWriteTimeUtc(f);
                    if (at > bestAt && (DateTime.UtcNow - at).TotalDays < 7) { best = f; bestAt = at; }
                }
                if (best == null) return;
                string text = File.ReadAllText(best);
                if (text.IndexOf("client_id", StringComparison.Ordinal) < 0 || text.IndexOf("client_secret", StringComparison.Ordinal) < 0) return;   // not Google's file
                Directory.CreateDirectory(Dir);
                File.Copy(best, ClientFile, true);
                Log.W("youtube: took the Google client file from Downloads (" + Path.GetFileName(best) + "): SIGN IN is on");
            }
            catch (Exception ex) { Log.W("youtube: could not take the client file from Downloads: " + ex.Message); }
        }

        public static string Json()
        {
            int queue = 0; bool signedIn;
            PickUpClient();
            lock (gate)
            {
                Load();
                foreach (Rec r in recs) if (Pending(r) || r.Kind == "signin") queue++;
                signedIn = LoadToken() != null;
            }
            return "{\"signedIn\":" + B(signedIn) + ",\"privacy\":" + Json_.S(Privacy) + ",\"template\":" + Template.ToString(CultureInfo.InvariantCulture) +
                   ",\"queue\":" + queue.ToString(CultureInfo.InvariantCulture) + ",\"setUp\":" + B(File.Exists(ClientFile)) + ",\"signingIn\":" + B(signingIn) +
                   ",\"units\":" + UnitsToday().ToString(CultureInfo.InvariantCulture) + ",\"unitsMax\":" + DailyUnits.ToString(CultureInfo.InvariantCulture) + "}";
        }

        // when a race that hit the daily limit tries again (tests, RIG)
        public static DateTime RetryAt(string raceId)
        {
            lock (gate) { Load(); Rec r = Find(raceId); return r == null || r.RetryAtMs <= 0 ? DateTime.MinValue : new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(r.RetryAtMs).ToLocalTime(); }
        }

        // the daily upload limit resets at midnight Pacific = 08:00 or 09:00 UK: 09:00 local is always after it
        public static DateTime NextNine(DateTime local)
        {
            DateTime t = local.Date.AddHours(9);
            return local < t ? t : t.AddDays(1);
        }

        // ================= queue a race =================

        public static bool Enqueue(string raceId, string file, string title, string description, string privacy, string thumbJpg)
        {
            string m; return Enqueue(raceId, file, title, description, privacy, thumbJpg, out m);
        }

        public static bool Enqueue(string raceId, string file, string title, string description, string privacy, string thumbJpg, out string message)
        {
            return Enqueue(raceId, file, title, description, privacy, thumbJpg, null, out message);
        }

        // W1-11: with snippet.tags (track, car, series, "iRacing", "sim racing")
        public static bool Enqueue(string raceId, string file, string title, string description, string privacy, string thumbJpg, IList<string> tags, out string message)
        {
            if (string.IsNullOrEmpty(raceId) || string.IsNullOrEmpty(file)) { message = "No race video to share"; return false; }
            string want = (privacy ?? "").Trim().ToLowerInvariant();
            if (want != "private" && want != "public") want = Privacy;
            lock (gate)
            {
                Load();
                Rec r = Find(raceId);
                if (r != null && (r.Kind == "shared" || r.Kind == "sharing")) { message = MsgAlready; return false; }   // never twice
                if (r != null && (r.Kind == "queued" || r.Kind == "offline")) { message = "Already waiting to go to YouTube"; r.RetryAtMs = 0; }   // a second press tries now
                else
                {
                    if (r == null) { r = new Rec(); r.Race = raceId; recs.Add(r); }
                    // a failed or signed-out race goes again (a half-sent one carries on from its session file)
                    r.Kind = "queued"; r.Error = ""; r.RetryAtMs = 0; r.Tries = 0; r.Restarts = 0; r.Pct = 0; r.VideoId = ""; r.Url = "";
                    r.File = file; r.Title = CleanTitle(title, file); r.Desc = CleanDesc(description); r.Want = want; r.Thumb = thumbJpg ?? "";
                    r.Tags = CleanTags(tags); r.ThumbSet = "";
                    Save();
                    message = "Going to YouTube when the session is over";
                    Log.W("youtube: " + raceId + " queued (" + want + ")");
                }
            }
            Bump();
            Kick(0);
            return true;
        }

        // DELETE of a race that is waiting (W1-4): its record goes, so the trashed race is never uploaded. Only "queued" with nothing sent
        // yet; a race already sending, or on YouTube, is left alone (never a half-told story). true = removed.
        public static bool Cancel(string raceId)
        {
            lock (gate)
            {
                Load();
                Rec r = Find(raceId);
                if (r == null || r.Kind != "queued" || File.Exists(SessionFile(raceId))) return false;
                recs.Remove(r); Save();
            }
            Log.W("youtube: " + raceId + " taken out of the queue (deleted)");
            Bump();
            return true;
        }

        static string CleanTitle(string t, string file)
        {
            t = (t ?? "").Replace("<", "").Replace(">", "").Replace("\r", " ").Replace("\n", " ").Trim();
            if (t.Length == 0) t = Path.GetFileNameWithoutExtension(file ?? "") ?? "iRacing race";
            return t.Length > 100 ? t.Substring(0, 100) : t;
        }
        // YouTube: no < or >, 500 characters for all tags together (a tag with a space counts its quotes too)
        static string CleanTags(IList<string> tags)
        {
            if (tags == null) return "";
            List<string> keep = new List<string>(); int total = 0;
            foreach (string raw in tags)
            {
                string t = (raw ?? "").Replace("<", "").Replace(">", "").Replace(",", " ").Replace("\r", " ").Replace("\n", " ").Trim();
                if (t.Length == 0 || t.Length > 100) continue;
                int cost = t.Length + (t.IndexOf(' ') >= 0 ? 2 : 0) + (keep.Count > 0 ? 1 : 0);
                if (total + cost > 500) break;
                keep.Add(t); total += cost;
            }
            return string.Join("\n", keep.ToArray());
        }
        static string TagsJson(string tags)
        {
            if (tags.Length == 0) return "";
            StringBuilder sb = new StringBuilder(",\"tags\":[");
            string[] all = tags.Split('\n');
            for (int i = 0; i < all.Length; i++) { if (i > 0) sb.Append(','); sb.Append(Json_.S(all[i])); }
            return sb.Append(']').ToString();
        }

        // ================= the daily quota (W1-11) =================
        // Google gives a project 10,000 units a day (it resets at midnight Pacific). videos.insert costs 1600, thumbnails.set 50:
        // one race with its thumbnail is 1650, so six videos a day. Counted here so a thumbnail never pushes an upload over the day's
        // limit; the upload itself still learns the real answer from Google (quotaExceeded -> try again after 9).
        public const int DailyUnits = 10000, InsertUnits = 1600, ThumbUnits = 50;
        static string QuotaFile { get { return Path.Combine(Dir, "quota.json"); } }
        static string PacificDay()
        {
            DateTime utc = Clock != null ? Clock().ToUniversalTime() : DateTime.UtcNow;
            try { return TimeZoneInfo.ConvertTimeFromUtc(utc, TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time")).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture); }
            catch { return utc.AddHours(-8).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture); }
        }
        public static int UnitsToday()
        {
            try
            {
                if (!File.Exists(QuotaFile)) return 0;
                Dictionary<string, object> d = Parse(File.ReadAllText(QuotaFile));
                return Str(d, "day") == PacificDay() ? (int)Num(d, "units", 0) : 0;
            }
            catch { return 0; }
        }
        static readonly object quotaGate = new object();
        static void Spend(int units, string what)
        {
            lock (quotaGate)
            {
                int now = UnitsToday() + units;
                try { Directory.CreateDirectory(Dir); WriteAtomic(QuotaFile, Encoding.UTF8.GetBytes("{\"day\":" + Json_.S(PacificDay()) + ",\"units\":" + now.ToString(CultureInfo.InvariantCulture) + "}")); } catch { }
                Log.W("youtube: " + what + " - " + now.ToString(CultureInfo.InvariantCulture) + " of " + DailyUnits.ToString(CultureInfo.InvariantCulture) + " quota units used today");
            }
        }

        static string CleanDesc(string d)
        {
            d = (d ?? "").Replace("<", "").Replace(">", "");
            while (Encoding.UTF8.GetByteCount(d) > 5000) d = d.Substring(0, d.Length - 1);
            return d;
        }

        // ================= sign-in (loopback + PKCE) =================

        // the ytsignin press: answers at once; the sign-in waits on its own thread for Google's answer, as long as irdash runs
        // (SignInTimeoutMs 0; tests set a short one). The only browser Paddock opens.
        // irdash's guard loop, every 2 s, never while the sim runs or a session is on: a waiting sign-in window stays on the middle screen,
        // filling it. 2026-11-26 09:14: the screens woke from sleep and Windows shuffled the windows; Google's page sat maximized on the
        // dashboard monitor, over the dashboard, until the next press. At most one move every 30 s.
        static DateTime lastKept = DateTime.MinValue;
        public static void KeepWindow()
        {
            IntPtr h = signInWindow;
            if (h == IntPtr.Zero || Win.FillsPrimary(h)) return;
            System.Drawing.Rectangle p = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
            if (p.Width != 2560 || p.Height != 1440) return;          // the screens are still waking up (the gallery saw 1 race screen at 09:14:30)
            if ((DateTime.UtcNow - lastKept).TotalSeconds < 30) return;
            lastKept = DateTime.UtcNow;
            if (Win.Show(h)) Log.W("youtube: the sign-in window was put back on the middle screen");
        }

        public static string SignIn()
        {
            string id, secret;
            if (!ReadClient(out id, out secret)) { Log.W("youtube: sign-in needs dash\\yt\\client.json (docs\\YOUTUBE-SETUP.md)"); return MsgSetup; }
            lock (gate)
            {
                if (signingIn)
                {
                    if (Win.Show(signInWindow)) return "Google's sign-in page is on the middle screen";   // its window is there: in front again, filling the screen
                    string again = openAuthUrl;           // the window was closed or lost: show the same page again
                    if (again != null) { try { OpenBrowser(again); } catch { } }
                    return "Google sign-in is open in the browser";
                }
                signingIn = true;
            }
            SignInThread(id, secret, null);
            Bump();
            return "Google sign-in opened in the browser";
        }

        // irdash start: a sign-in page left waiting when irdash last stopped (a deploy restarts it) is listened for again on the same
        // port with the same state and verifier (dash\yt\pending.bin), so Allow in the tab that is still open lands. A week old is
        // forgotten (2026-11-25: Peter took nine days to get to the page). 2026-11-15: Peter's tab could only get "refused to connect" once the listener had gone with the old irdash.
        static void ResumeSignIn()
        {
            Waiting p = LoadPending();
            if (p == null) return;
            string id, secret;
            if (!ReadClient(out id, out secret) || (DateTime.UtcNow - p.Started).TotalDays > 7) { DeletePending(); return; }
            lock (gate) { if (signingIn) return; signingIn = true; }
            SignInThread(id, secret, p);
            // the window of an earlier irdash (a deploy restarts it): an app-mode window on Google's sign-in has that exact title, a tab
            // in a normal window ends in " - Google Chrome". Found again, a press shows it and the keeper keeps it, instead of a second one.
            // Not for the tests: they replace OpenBrowser, and their irdash copy once adopted Peter's real window (2026-11-26, case 2e).
            string exe = BrowserExe();
            if (exe.Length > 0 && OpenBrowser == new Action<string>(DefaultOpen))
            {
                IntPtr h = Win.Find(Path.GetFileNameWithoutExtension(exe), GoogleTitle);
                if (h != IntPtr.Zero) { signInWindow = h; Log.W("youtube: the waiting sign-in window was found again"); }
            }
        }

        static void SignInThread(string id, string secret, Waiting resume)
        {
            Thread t = new Thread(Crash.Guard("youtube sign-in", delegate ()
            {
                try { SignInRun(id, secret, resume); }
                finally { openAuthUrl = null; signingIn = false; Bump(); }
            }));
            t.IsBackground = true; t.Name = "YouTube sign-in"; t.Start();
        }

        // tests and Reset: close the sign-in's socket as a stopped irdash would. pending.bin stays, so the next Start() picks the page up.
        internal static void AbortSignIn()
        {
            TcpListener l;
            lock (gate) { l = listening; listening = null; }
            if (l == null) return;
            try { l.Stop(); } catch { }
            for (int i = 0; i < 150 && signingIn; i++) Thread.Sleep(20);
        }

        // A plain socket on 127.0.0.1 (no HttpListener: that needs a URL reservation without admin rights and filters on the Host
        // header). Reads one request line, answers one small page, closes.
        static void SignInRun(string id, string secret, Waiting resume)
        {
            TcpListener l = new TcpListener(IPAddress.Loopback, resume != null ? resume.Port : 0);
            try { l.Start(); }
            catch (Exception ex)
            {
                if (resume != null) { Log.W("youtube: the sign-in page from before the restart cannot be listened for again (port " + resume.Port + ": " + ex.GetType().Name + ") - press Sign in to YouTube again"); DeletePending(); }
                else Log.W("youtube: sign-in could not open a local port for Google's answer (" + ex.GetType().Name + ")");
                return;
            }
            lock (gate) listening = l;
            try
            {
                int port = ((IPEndPoint)l.LocalEndpoint).Port;
                string redirect = "http://127.0.0.1:" + port + "/";
                string verifier, state, url;
                if (resume != null)
                {
                    verifier = resume.Verifier; state = resume.State; url = resume.Url;
                    Log.W("youtube: the sign-in page opened at " + resume.Started.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture) + " still waits for Google's answer (port " + port + ")");
                }
                else
                {
                    verifier = B64Url(RandomBytes(32));
                    string challenge;
                    using (SHA256 sha = SHA256.Create()) challenge = B64Url(sha.ComputeHash(Encoding.ASCII.GetBytes(verifier)));
                    state = B64Url(RandomBytes(16));
                    url = AuthUrl + "?client_id=" + E(id) + "&redirect_uri=" + E(redirect) + "&response_type=code&scope=" + E(Scope) +
                          "&code_challenge=" + challenge + "&code_challenge_method=S256&state=" + state + "&access_type=offline&prompt=consent";
                    Waiting p = new Waiting(); p.Port = port; p.State = state; p.Verifier = verifier; p.Url = url; p.Started = DateTime.UtcNow;
                    SavePending(p);
                }
                openAuthUrl = url;
                if (resume == null)
                {
                    try { OpenBrowser(url); } catch (Exception ex) { Log.W("youtube: could not open the browser for the sign-in: " + ex.Message); DeletePending(); return; }
                }
                DateTime until = SignInTimeoutMs > 0 ? DateTime.UtcNow.AddMilliseconds(SignInTimeoutMs) : DateTime.MaxValue;
                while (true)
                {
                    int left = until == DateTime.MaxValue ? -1 : (int)Math.Max(0, Math.Min(int.MaxValue - 1, (until - DateTime.UtcNow).TotalMilliseconds));   // -1 = no limit
                    IAsyncResult ar = left != 0 ? l.BeginAcceptTcpClient(null, null) : null;
                    if (ar == null || !ar.AsyncWaitHandle.WaitOne(left))
                    {
                        Log.W("youtube: sign-in stopped - no answer from Google in " + Math.Max(1, SignInTimeoutMs / 60000) + " minutes");
                        DeletePending();
                        return;
                    }
                    using (TcpClient c = l.EndAcceptTcpClient(ar))
                    {
                        c.ReceiveTimeout = 5000; c.SendTimeout = 5000;
                        NetworkStream ns = c.GetStream();
                        string target = RequestTarget(ns);
                        if (target == null) continue;                  // a browser's empty pre-connect, or junk
                        int qi = target.IndexOf('?');
                        string path = qi < 0 ? target : target.Substring(0, qi);
                        Dictionary<string, string> q = Query(qi < 0 ? "" : target.Substring(qi + 1));
                        string v;
                        if (path == "/favicon.ico") { Answer(ns, 204, ""); continue; }
                        if (path != "/") { Redirect(ns, url); continue; }                                        // any other address on this port: Google's sign-in page itself
                        if (!q.TryGetValue("state", out v) || v != state)
                        {
                            if (!q.ContainsKey("code") && !q.ContainsKey("error")) { Redirect(ns, url); continue; }   // a plain visit of the address: the sign-in page
                            Answer(ns, 404, OldPage); continue;                                                  // Google's answer to an earlier press: never exchanged
                        }
                        IntPtr shown = signInWindow; signInWindow = IntPtr.Zero;                                  // the window this sign-in opened, closed after the final page
                        if (q.TryGetValue("error", out v) && v.Length > 0)
                        {
                            Answer(ns, 200, NotSignedInPage, NotDoneTitle, ClosesLine);
                            Log.W("youtube: sign-in cancelled on Google's page (" + Safe(v) + ")");
                            DeletePending();
                            Win.CloseLater(shown, NotDoneTitle);
                            return;
                        }
                        string code; q.TryGetValue("code", out code);
                        string err = Exchange(id, secret, code ?? "", verifier, redirect);
                        if (err == null)
                        {
                            Answer(ns, 200, SignedInPage, DoneTitle, ClosesLine);
                            Log.W("youtube: signed in");
                            DeletePending();
                            SignedIn();
                            Win.CloseLater(shown, DoneTitle);
                        }
                        else
                        {
                            Answer(ns, 200, FailedPage, NotDoneTitle, ClosesLine);
                            Log.W("youtube: sign-in failed: " + err);
                            DeletePending();
                            Win.CloseLater(shown, NotDoneTitle);
                        }
                        return;
                    }
                }
            }
            catch (Exception ex)
            {
                bool stopped; lock (gate) stopped = listening != l;    // Reset or a stop closed the socket: no failure, the page is kept for the next start
                if (!stopped) { Log.W("youtube: sign-in failed (" + ex.GetType().Name + ")"); DeletePending(); }
            }
            finally { lock (gate) { if (listening == l) listening = null; } try { l.Stop(); } catch { } }
        }

        // ---- a sign-in page that waits across a restart: dash\yt\pending.bin, DPAPI like the token ----
        sealed class Waiting { public int Port; public string State = "", Verifier = "", Url = ""; public DateTime Started; }

        static void SavePending(Waiting p)
        {
            try
            {
                long ms = (long)(p.Started - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
                string json = "{\"port\":" + p.Port.ToString(CultureInfo.InvariantCulture) + ",\"state\":" + Json_.S(p.State) + ",\"verifier\":" + Json_.S(p.Verifier) +
                              ",\"url\":" + Json_.S(p.Url) + ",\"startedMs\":" + ms.ToString(CultureInfo.InvariantCulture) + "}";
                Directory.CreateDirectory(Dir);
                WriteAtomic(PendingFile, ProtectedData.Protect(Encoding.UTF8.GetBytes(json), Encoding.UTF8.GetBytes(EntropyText), DataProtectionScope.CurrentUser));
            }
            catch (Exception ex) { Log.W("youtube: the waiting sign-in could not be noted for a restart (" + ex.GetType().Name + ")"); }
        }

        static Waiting LoadPending()
        {
            try
            {
                if (!File.Exists(PendingFile)) return null;
                byte[] plain = ProtectedData.Unprotect(File.ReadAllBytes(PendingFile), Encoding.UTF8.GetBytes(EntropyText), DataProtectionScope.CurrentUser);
                Dictionary<string, object> d = Parse(Encoding.UTF8.GetString(plain));
                Waiting p = new Waiting();
                p.Port = (int)Num(d, "port", 0); p.State = Str(d, "state"); p.Verifier = Str(d, "verifier"); p.Url = Str(d, "url");
                p.Started = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(Num(d, "startedMs", 0));
                if (p.Port <= 0 || p.State.Length == 0 || p.Verifier.Length == 0 || p.Url.Length == 0) { DeletePending(); return null; }
                return p;
            }
            catch (Exception ex) { Log.W("youtube: the noted sign-in could not be read (" + ex.GetType().Name + ") - press Sign in to YouTube again"); DeletePending(); return null; }
        }

        static void DeletePending() { try { File.Delete(PendingFile); } catch { } }

        // the request line's target ("/?code=...&state=..."); reads the head only (a GET has no body)
        static string RequestTarget(NetworkStream ns)
        {
            try
            {
                byte[] buf = new byte[16384]; int n = 0;
                while (n < buf.Length)
                {
                    int k = ns.Read(buf, n, buf.Length - n);
                    if (k <= 0) break;
                    n += k;
                    if (Encoding.ASCII.GetString(buf, 0, n).Contains("\r\n\r\n")) break;
                }
                string head = Encoding.ASCII.GetString(buf, 0, n);
                int eol = head.IndexOf("\r\n", StringComparison.Ordinal);
                string[] parts = (eol < 0 ? head : head.Substring(0, eol)).Split(' ');
                if (parts.Length < 2 || parts[0] != "GET") return null;
                return parts[1];
            }
            catch { return null; }
        }

        static Dictionary<string, string> Query(string qs)
        {
            Dictionary<string, string> d = new Dictionary<string, string>();
            foreach (string kv in qs.Split('&'))
            {
                if (kv.Length == 0) continue;
                int e = kv.IndexOf('=');
                string k = e < 0 ? kv : kv.Substring(0, e), v = e < 0 ? "" : kv.Substring(e + 1);
                try { d[Uri.UnescapeDataString(k.Replace('+', ' '))] = Uri.UnescapeDataString(v.Replace('+', ' ')); } catch { }
            }
            return d;
        }

        static void Answer(NetworkStream ns, int status, string text) { Answer(ns, status, text, "Paddock", null); }

        // a final page (signed in or not) carries a title of its own: Paddock closes the sign-in window it opened while it shows that title
        static void Answer(NetworkStream ns, int status, string text, string title, string small)
        {
            try
            {
                byte[] body = status == 204 ? new byte[0] : Encoding.UTF8.GetBytes(
                    "<!doctype html><meta charset=\"utf-8\"><title>" + WebUtility.HtmlEncode(title) + "</title><body style=\"background:#000;color:#e8c66a;font:28px sans-serif;padding:60px\">" +
                    WebUtility.HtmlEncode(text) + (small == null ? "" : "<p style=\"color:#9a8a5a;font-size:20px\">" + WebUtility.HtmlEncode(small) + "</p>") + "</body>");
                string reason = status == 200 ? "OK" : status == 204 ? "No Content" : "Not Found";
                string head = "HTTP/1.1 " + status + " " + reason + "\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + body.Length +
                              "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
                byte[] h = Encoding.ASCII.GetBytes(head);
                ns.Write(h, 0, h.Length); ns.Write(body, 0, body.Length); ns.Flush();
            }
            catch { }
        }

        // any other address on the sign-in port shows Google's sign-in page itself (never a "Not found")
        static void Redirect(NetworkStream ns, string to)
        {
            try
            {
                byte[] h = Encoding.ASCII.GetBytes("HTTP/1.1 302 Found\r\nLocation: " + to + "\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
                ns.Write(h, 0, h.Length); ns.Flush();
            }
            catch { }
        }

        // the code for tokens; null = done, else a plain reason (never the answer's text: it holds the tokens)
        static string Exchange(string id, string secret, string code, string verifier, string redirect)
        {
            try
            {
                if (code.Length == 0) return "Google sent no code";
                Resp r = Form(TokenUrl, "code=" + E(code) + "&client_id=" + E(id) + "&client_secret=" + E(secret) + "&redirect_uri=" + E(redirect) +
                                        "&grant_type=authorization_code&code_verifier=" + E(verifier));
                if (r.Status != 200) return "Google answered " + r.Status + " " + Safe(Str(Parse(r.Body), "error"));
                Dictionary<string, object> d = Parse(r.Body);
                Tok t = new Tok(); t.Refresh = Str(d, "refresh_token"); t.Access = Str(d, "access_token"); t.ExpMs = NowMs + Num(d, "expires_in", 3600) * 1000;
                if (t.Refresh.Length == 0) return "Google gave no lasting sign-in (no refresh token)";
                lock (gate) SaveToken(t);
                return null;
            }
            catch (Exception ex) { return "could not finish (" + ex.GetType().Name + ")"; }
        }

        // signed in: every race waiting for it goes again
        static void SignedIn()
        {
            bool any = false;
            lock (gate)
            {
                Load();
                foreach (Rec r in recs) if (r.Kind == "signin") { r.Kind = "queued"; r.Error = ""; r.RetryAtMs = 0; any = true; }
                if (any) Save();
            }
            Bump();
            if (any) Kick(0);
        }

        // The sign-in gets a window of its own: Chrome's or Edge's app mode (no tabs, no address bar), placed to fill the middle
        // (primary) screen, and Paddock closes it when the sign-in ends. 2026-11-25: ShellExecute had put Google's page in a tab of
        // whatever window was on top, among the dead tabs of earlier tries, and Peter clicked through one of those (Chrome's
        // history: consent reached on a port that had gone). ShellExecute stays the fallback for any other browser. Never
        // explorer.exe: it treats the address as a path and cuts it at 260 characters (2026-11-15: Google's ~450-character
        // address lost code_challenge, state, access_type and prompt, Google answered without a state and the listener said
        // "Not found" to Peter twice).
        static void DefaultOpen(string url)
        {
            string exe = BrowserExe();
            if (exe.Length > 0)
            {
                IntPtr h;
                if (Win.OpenApp(exe, url, out h)) { signInWindow = h; return; }
            }
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
            catch { System.Diagnostics.Process.Start("rundll32.exe", "url.dll,FileProtocolHandler " + url); }   // no https handler registered: Windows' own opener
        }

        // the browser for the sign-in window: Chrome when it is installed (Peter's Google account lives there, and the earlier sign-in
        // pages opened there), else Edge; "" = neither, and ShellExecute opens whatever Windows has. 2026-11-25: Windows' own https
        // default on the rig had become Edge, where no Google account is signed in.
        internal static string BrowserExe()
        {
            try
            {
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
            }
            catch { }
            return "";
        }

        // ---- the sign-in window: opened in app mode, put on the middle screen, closed by Paddock when the sign-in ends ----
        static class Win
        {
            delegate bool EnumProc(IntPtr h, IntPtr l);
            [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
            [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
            [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
            [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
            [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
            [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
            [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
            [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
            [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
            [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
            [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
            [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
            [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
            const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, WM_CLOSE = 0x10;
            const int SW_MAXIMIZE = 3, SW_RESTORE = 9;

            // the browser's visible top-level windows (every process of that name: Chrome's windows all belong to one)
            static HashSet<IntPtr> Windows(string procName)
            {
                HashSet<uint> pids = new HashSet<uint>();
                foreach (System.Diagnostics.Process p in System.Diagnostics.Process.GetProcessesByName(procName)) { pids.Add((uint)p.Id); p.Dispose(); }
                HashSet<IntPtr> set = new HashSet<IntPtr>();
                EnumWindows(delegate (IntPtr h, IntPtr l) { uint pid; GetWindowThreadProcessId(h, out pid); if (pids.Contains(pid) && IsWindowVisible(h)) set.Add(h); return true; }, IntPtr.Zero);
                return set;
            }

            // starts the browser in app mode on the address; true when it started (h = the new window once it shows, else zero)
            public static bool OpenApp(string exe, string url, out IntPtr h)
            {
                h = IntPtr.Zero;
                string name = Path.GetFileNameWithoutExtension(exe);
                HashSet<IntPtr> before = Windows(name);
                try { using (System.Diagnostics.Process p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(exe, "--app=\"" + url + "\"") { UseShellExecute = false })) { } }
                catch { return false; }
                for (int i = 0; i < 60 && h == IntPtr.Zero; i++)          // the window takes a moment (up to 6 s)
                {
                    Thread.Sleep(100);
                    foreach (IntPtr w in Windows(name)) if (!before.Contains(w) && Title(w).Length > 0) { h = w; break; }
                }
                if (h != IntPtr.Zero) Place(h);
                return true;
            }

            // onto the middle (primary) screen, whose corner is 0,0, filling it, in front. A window maximized on another screen is restored
            // first: moved while maximized it kept that screen's size (2026-11-26 09:16, after the screens woke from sleep).
            static void Place(IntPtr h)
            {
                try
                {
                    if (IsIconic(h) || IsZoomed(h)) ShowWindow(h, SW_RESTORE);
                    SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
                    ShowWindow(h, SW_MAXIMIZE);
                    SetForegroundWindow(h);
                }
                catch { }
            }

            // the browser's visible window with exactly this title, else zero
            public static IntPtr Find(string procName, string title)
            {
                try { foreach (IntPtr w in Windows(procName)) if (Title(w) == title) return w; } catch { }
                return IntPtr.Zero;
            }

            // true while the window fills the middle (primary) screen: maximized, with its middle on that screen
            public static bool FillsPrimary(IntPtr h)
            {
                try
                {
                    if (!IsWindow(h) || !IsWindowVisible(h) || !IsZoomed(h)) return false;
                    RECT r; if (!GetWindowRect(h, out r)) return false;
                    return System.Windows.Forms.Screen.PrimaryScreen.Bounds.Contains((r.Left + r.Right) / 2, (r.Top + r.Bottom) / 2);
                }
                catch { return false; }
            }

            // the window is still there: show it again (a press while the page waits)
            public static bool Show(IntPtr h)
            {
                if (h == IntPtr.Zero) return false;
                try { if (!IsWindow(h) || !IsWindowVisible(h)) return false; } catch { return false; }
                Place(h);
                return true;
            }

            static string Title(IntPtr h) { StringBuilder s = new StringBuilder(512); GetWindowText(h, s, s.Capacity); return s.ToString(); }

            // a little after the final page: close the window Paddock opened, and only while it still shows that page (its title)
            public static void CloseLater(IntPtr h, string title)
            {
                if (h == IntPtr.Zero) return;
                Thread t = new Thread(delegate ()
                {
                    Thread.Sleep(2500);
                    try { if (IsWindow(h) && Title(h).StartsWith(title)) PostMessage(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); } catch { }
                });
                t.IsBackground = true; t.Start();
            }
        }

        // ================= tokens =================

        static bool ReadClient(out string id, out string secret)
        {
            id = ""; secret = "";
            try
            {
                if (!File.Exists(ClientFile)) return false;
                Dictionary<string, object> d = Parse(File.ReadAllText(ClientFile, Encoding.UTF8));
                Dictionary<string, object> inst = d == null ? null : (d.ContainsKey("installed") ? d["installed"] : null) as Dictionary<string, object>;
                if (inst == null) return false;
                id = Str(inst, "client_id"); secret = Str(inst, "client_secret");
                return id.Length > 0;
            }
            catch { return false; }
        }

        static Tok LoadToken()
        {
            if (tokRead) return tok;
            tokRead = true; tok = null;
            try
            {
                if (!File.Exists(TokenFile)) return null;
                byte[] plain = ProtectedData.Unprotect(File.ReadAllBytes(TokenFile), Encoding.UTF8.GetBytes(EntropyText), DataProtectionScope.CurrentUser);
                Dictionary<string, object> d = Parse(Encoding.UTF8.GetString(plain));
                Tok t = new Tok(); t.Refresh = Str(d, "refresh"); t.Access = Str(d, "access"); t.ExpMs = Num(d, "expMs", 0);
                if (t.Refresh.Length > 0) tok = t;
            }
            catch (Exception ex) { Log.W("youtube: the saved sign-in could not be read (" + ex.GetType().Name + ") - sign in again"); }
            return tok;
        }

        static void SaveToken(Tok t)
        {
            string json = "{\"refresh\":" + Json_.S(t.Refresh) + ",\"access\":" + Json_.S(t.Access) + ",\"expMs\":" + t.ExpMs.ToString(CultureInfo.InvariantCulture) + "}";
            byte[] enc = ProtectedData.Protect(Encoding.UTF8.GetBytes(json), Encoding.UTF8.GetBytes(EntropyText), DataProtectionScope.CurrentUser);
            WriteAtomic(TokenFile, enc);
            tok = t; tokRead = true;
        }

        static void DeleteToken()
        {
            lock (gate) { try { File.Delete(TokenFile); } catch { } tok = null; tokRead = true; }
        }

        // an access token good for at least another minute; force = the last one was refused (401)
        static string AccessToken(bool force)
        {
            string id, secret;
            if (!ReadClient(out id, out secret)) throw new Halt("setup", MsgSetup, 0);      // first: no client = no sign-in either
            Tok t; lock (gate) t = LoadToken();
            if (t == null) throw new Halt("nosignin", MsgSignIn, 0);
            if (!force && t.Access.Length > 0 && t.ExpMs - NowMs > 60000) return t.Access;
            YieldPoint();
            Resp r = Form(TokenUrl, "client_id=" + E(id) + "&client_secret=" + E(secret) + "&grant_type=refresh_token&refresh_token=" + E(t.Refresh));
            if (r.Status == 200)
            {
                Dictionary<string, object> d = Parse(r.Body);
                Tok n = new Tok(); n.Refresh = Str(d, "refresh_token"); if (n.Refresh.Length == 0) n.Refresh = t.Refresh;
                n.Access = Str(d, "access_token"); n.ExpMs = NowMs + Num(d, "expires_in", 3600) * 1000;
                if (n.Access.Length == 0) throw new Transient("Google gave no access token");
                lock (gate) SaveToken(n);
                return n.Access;
            }
            if (r.Status >= 500 || r.Status == 429) throw new Transient("Google's sign-in answered " + r.Status);
            string error = Str(Parse(r.Body), "error");
            if (error == "invalid_client" || error == "unauthorized_client") throw new Halt("setup", MsgSetup, 0);
            throw new Halt("signout", MsgSignInAgain, 0);          // invalid_grant: revoked, password changed, or unused for months
        }

        // inside the job: a session started, stop here (everything sent so far is in the session file)
        static void YieldPoint() { if (Jobs.ShouldYield || paused) throw new YieldNow(); }

        // ================= the upload job =================

        // Run the job now (0) or after ms. The timer's callback only queues the job (whenFree): no file, no network on the timer thread.
        static void Kick(long ms)
        {
            if (ms <= 0) { Jobs.Run(JobName, Work, true); return; }
            lock (gate)
            {
                if (timer == null) timer = new Timer(delegate (object o) { Jobs.Run(JobName, Work, true); }, null, Timeout.Infinite, Timeout.Infinite);
                timer.Change(Math.Min(ms, 0xfffffff0L), Timeout.Infinite);
            }
        }

        static bool Pending(Rec r)
        {
            return r.Kind == "queued" || r.Kind == "sharing" || r.Kind == "offline" || (r.Kind == "failed" && r.RetryAtMs > 0);
        }

        // The race to work on now, or null + the wait until one is due. A half-sent race goes first, and while one is half-sent no
        // other race starts (each would otherwise hold a session on YouTube's side). Races already tried in this run are skipped.
        static Rec NextDue(HashSet<string> tried, out long waitMs)
        {
            waitMs = -1;
            Load();
            long now = NowMs;
            List<Rec> half = new List<Rec>(), rest = new List<Rec>();
            foreach (Rec r in recs) if (Pending(r)) { if (File.Exists(SessionFile(r.Race))) half.Add(r); else rest.Add(r); }
            List<Rec> pool = half.Count > 0 ? half : rest;
            foreach (Rec r in pool)
            {
                long w = r.RetryAtMs - now;
                if (w > 0 || tried.Contains(r.Race)) { long ww = Math.Max(0, w); if (waitMs < 0 || ww < waitMs) waitMs = ww; continue; }
                return r;
            }
            return null;
        }

        static void Work()
        {
            if (paused) return;
            busy = true;
            try
            {
                DateTime sliceEnd = DateTime.UtcNow.AddMilliseconds(SliceMs);
                HashSet<string> tried = new HashSet<string>();
                while (!paused)
                {
                    if (Jobs.ShouldYield) { Jobs.Again(JobName, Work); return; }
                    Rec r; long wait;
                    lock (gate) r = NextDue(tried, out wait);
                    if (r == null) { if (wait >= 0) Kick(Math.Max(wait, 50)); return; }
                    tried.Add(r.Race);
                    long o = Turn(r, sliceEnd);
                    if (o == YIELD) { Jobs.Again(JobName, Work); return; }
                    if (o == SLICE) { Jobs.Run(JobName, Work, true); return; }   // other heavy jobs get their turn, then this goes on
                    if (o == STOP) return;
                    // NEXT or a wait (kept in the race's RetryAtMs): go on with the next race that is due now
                }
            }
            finally { busy = false; }
        }

        // one race, as far as it goes this time
        static long Turn(Rec r, DateTime sliceEnd)
        {
            try
            {
                long o = Send(r, sliceEnd);
                if (o != NEXT) return o;
                if (r.Kind == "shared") Thumbnail(r);
                return NEXT;
            }
            catch (YieldNow) { Log.W("youtube: " + r.Race + " upload paused at " + r.Pct + "% - a session started"); return YIELD; }
            catch (Halt h)
            {
                if (h.Kind == "signout") { DeleteToken(); Log.W("youtube: Google ended the sign-in - press Sign in to YouTube again"); AllPending("signin", MsgSignInAgain); return STOP; }
                if (h.Kind == "setup") { Log.W("youtube: no usable dash\\yt\\client.json - " + MsgSetup); AllPending("signin", MsgSetup); return STOP; }
                if (h.Kind == "nosignin") { AllPending("signin", MsgSignIn); return STOP; }     // only the sign-in key opens Google's page
                if (h.Kind == "signin") { DeleteToken(); Log.W("youtube: YouTube refused the sign-in twice - " + MsgSignInAgain); AllPending("signin", MsgSignInAgain); return STOP; }
                lock (gate) { r.Kind = "failed"; r.Error = h.Msg; r.RetryAtMs = h.RetryAtMs; Save(); }
                Log.W("youtube: " + r.Race + " not shared: " + h.Msg);
                Bump();
                return NEXT;
            }
            catch (WebException ex)
            {
                if (ex.Status == WebExceptionStatus.NameResolutionFailure || ex.Status == WebExceptionStatus.ConnectFailure || ex.Status == WebExceptionStatus.ProxyNameResolutionFailure)
                    return Offline(r);
                return Backoff(r, ex.Status.ToString());
            }
            catch (Transient ex) { return Backoff(r, ex.Message); }
            catch (IOException ex) { return Backoff(r, ex.GetType().Name); }     // the link broke while a chunk was being written
            catch (Exception ex) { return Backoff(r, ex.GetType().Name); }       // anything else (a locked file, DPAPI): never stuck at "Sharing 41%"
        }

        static long Offline(Rec r)
        {
            bool first;
            lock (gate) { first = r.Kind != "offline"; r.Kind = "offline"; r.Error = MsgOffline; r.RetryAtMs = NowMs + OfflineRetryMs; Save(); }
            if (first) { Log.W("youtube: " + r.Race + " - no internet, waiting"); Bump(); }
            return OfflineRetryMs;
        }

        static long Backoff(Rec r, string why)
        {
            long wait;
            lock (gate)
            {
                r.Tries++;
                wait = Math.Min((long)BackoffMaxMs, (long)BackoffBaseMs << Math.Min(r.Tries - 1, 20));
                if (r.Kind == "offline" || r.Kind == "failed") { r.Kind = r.StartedMs > 0 ? "sharing" : "queued"; r.Error = ""; }
                r.RetryAtMs = NowMs + wait; Save();
            }
            Log.W("youtube: " + r.Race + " upload interrupted (" + Safe(why) + ") - trying again in " + (wait / 1000.0).ToString("0.#", CultureInfo.InvariantCulture) + " s");
            Bump();
            return wait;
        }

        static void AllPending(string kind, string msg)
        {
            lock (gate)
            {
                foreach (Rec x in recs) if (Pending(x) || x.Kind == "signin") { x.Kind = kind; x.Error = msg; x.RetryAtMs = 0; }
                Save();
            }
            Bump();
        }

        // the resumable upload, from wherever it got to, to YouTube's final answer
        static long Send(Rec r, DateTime sliceEnd)
        {
            if (!File.Exists(r.File)) throw new Halt("failed", "The race video file is gone", 0);
            long size = new FileInfo(r.File).Length;
            if (size <= 0) throw new Halt("failed", "The race video file is empty", 0);
            Sess s = LoadSession(r.Race);
            if (s != null && (s.Size != size || !string.Equals(s.File, r.File, StringComparison.OrdinalIgnoreCase))) { DeleteSession(r.Race); s = null; }   // the file changed: start again

            YieldPoint();
            long next = 0; Resp done = null;
            if (s == null) s = Begin(r, size);
            else
            {
                Resp q = Authed("PUT", s.Url, null, null, 0, 0, "bytes */" + size);
                if (q.Status == 308) next = RangeEnd(q) + 1;
                else if (q.Status == 200 || q.Status == 201) done = q;
                else if (q.Status == 404 || q.Status == 410) { s = Restart(r, size); next = 0; }
                else Classify(q);
                if (done == null && next > 0) Log.W("youtube: " + r.Race + " carries on from " + Mb(next) + " of " + Mb(size) + " MB");
            }
            lock (gate)
            {
                if (r.StartedMs == 0) r.StartedMs = NowMs;
                r.Kind = "sharing"; r.Error = ""; r.RetryAtMs = 0; r.Pct = (int)Math.Min(99, next * 100 / size); Save();
            }
            Bump();

            byte[] buf = null;
            using (FileStream fs = new FileStream(r.File, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                while (done == null)
                {
                    YieldPoint();
                    if (DateTime.UtcNow >= sliceEnd) return SLICE;
                    int len = (int)Math.Min(ChunkSize, size - next);
                    if (buf == null || buf.Length < len) buf = new byte[len];
                    fs.Position = next;
                    int got = 0;
                    while (got < len) { int n = fs.Read(buf, got, len - got); if (n <= 0) throw new Halt("failed", "The race video file got shorter while it was being sent", 0); got += n; }
                    Resp p = Authed("PUT", s.Url, "video/mp4", buf, 0, len, "bytes " + next + "-" + (next + len - 1) + "/" + size);
                    if (p.Status == 308)
                    {
                        next = RangeEnd(p) + 1;          // Google's byte, even when it kept less than was sent
                        lock (gate) { s.Sent = next; SaveSession(s); r.Tries = 0; r.Kind = "sharing"; r.Error = ""; r.Pct = (int)Math.Min(99, next * 100 / size); Save(); }
                        Bump();
                    }
                    else if (p.Status == 200 || p.Status == 201) done = p;
                    else if (p.Status == 404 || p.Status == 410) { s = Restart(r, size); next = 0; }
                    else Classify(p);
                }
            }
            return Finish(r, done, size);
        }

        // YouTube's answer to the finished upload is the read-back: its id, uploadStatus and the REAL privacyStatus
        static long Finish(Rec r, Resp done, long size)
        {
            Dictionary<string, object> d = Parse(done.Body);
            string vid = Str(d, "id");
            Dictionary<string, object> st = d != null && d.ContainsKey("status") ? d["status"] as Dictionary<string, object> : null;
            string up = Str(st, "uploadStatus"), priv = Str(st, "privacyStatus");
            if (vid.Length == 0)
            {
                DeleteSession(r.Race);
                throw new Halt("failed", "YouTube took the video but did not say its address. Look in YouTube Studio", 0);
            }
            if (up != "uploaded" && up != "processed")
            {
                DeleteSession(r.Race);
                string why = Str(st, up == "rejected" ? "rejectionReason" : "failureReason");
                lock (gate) { r.StartedMs = 0; r.Pct = 0; }
                if (up == "rejected" || up == "failed" || up == "deleted")
                    throw new Halt("failed", "YouTube " + (up == "deleted" ? "deleted" : "rejected") + " the video" + (why.Length > 0 ? " (" + Safe(why) + ")" : ""), 0);
                throw new Halt("failed", "YouTube took the video but did not confirm it. Look in YouTube Studio", 0);
            }
            bool saved;
            lock (gate)
            {
                r.VideoId = vid; r.Kind = "shared"; r.Privacy = priv.Length > 0 ? priv : r.Want; r.UploadStatus = up; r.Url = "https://youtu.be/" + vid;
                r.Pct = 100; r.Error = ""; r.RetryAtMs = 0; r.DoneMs = NowMs;
                saved = Save();
            }
            // never twice: the session file goes only once the video id is on disk; else the next start asks */total and gets this answer again
            if (saved) DeleteSession(r.Race);
            Log.W("youtube: " + r.Race + " is on YouTube (" + r.Privacy + ", " + Mb(size) + " MB) " + r.Url);
            Bump();
            return NEXT;
        }

        // a new upload session; its address is on disk before the first byte goes
        static Sess Begin(Rec r, long size)
        {
            string meta = "{\"snippet\":{\"title\":" + Json_.S(r.Title) + ",\"description\":" + Json_.S(r.Desc) + TagsJson(r.Tags ?? "") + ",\"categoryId\":\"20\"}," +
                          "\"status\":{\"privacyStatus\":" + Json_.S(r.Want) + ",\"selfDeclaredMadeForKids\":false}}";
            byte[] body = Encoding.UTF8.GetBytes(meta);
            Dictionary<string, string> h = new Dictionary<string, string>();
            h["X-Upload-Content-Length"] = size.ToString(CultureInfo.InvariantCulture); h["X-Upload-Content-Type"] = "video/mp4";
            Resp p = Authed("POST", UploadUrl + "/videos?uploadType=resumable&part=snippet,status", "application/json; charset=UTF-8", body, 0, body.Length, null, h);
            if (p.Status != 200 && p.Status != 201) Classify(p);
            Spend(InsertUnits, r.Race + " upload started");      // the insert's units are taken when the session is opened
            string loc = p.Headers["Location"] ?? "";
            if (loc.Length == 0) throw new Transient("YouTube gave no upload address");
            Sess s = new Sess(); s.Race = r.Race; s.File = r.File; s.Size = size; s.Url = loc; s.Title = r.Title; s.Privacy = r.Want; s.StartedMs = NowMs;
            lock (gate) SaveSession(s);
            Log.W("youtube: " + r.Race + " upload started (" + Mb(size) + " MB, " + r.Want + ")");
            return s;
        }

        // the session ran out (404/410): from zero, at most 3 times a race
        static Sess Restart(Rec r, long size)
        {
            lock (gate) { DeleteSession(r.Race); r.Restarts++; Save(); }
            if (r.Restarts > 3) throw new Halt("failed", "YouTube kept losing the upload. Press Share to try again", 0);
            Log.W("youtube: " + r.Race + " - YouTube forgot the half-sent upload, starting it again");
            YieldPoint();
            return Begin(r, size);
        }

        // the race frame as the thumbnail; a refusal never spoils a shared race
        static void Thumbnail(Rec r)
        {
            if (r.Thumb.Length == 0 || !File.Exists(r.Thumb)) return;
            if (Jobs.ShouldYield) { Log.W("youtube: thumbnail skipped - a session started"); return; }
            // W1-11: never let a thumbnail spend the units the next upload needs (the picture stays beside the video for Peter to drag)
            if (UnitsToday() + ThumbUnits > DailyUnits) { ThumbDone(r, "skipped"); Log.W("youtube: thumbnail of " + r.Race + " skipped - today's quota is used up"); return; }
            try
            {
                byte[] jpg = File.ReadAllBytes(r.Thumb);
                if (jpg.Length > 2 * 1024 * 1024) { ThumbDone(r, "failed"); Log.W("youtube: thumbnail of " + r.Race + " not set (over YouTube's 2 MB)"); return; }
                Spend(ThumbUnits, r.Race + " thumbnail");
                Resp p = Authed("POST", UploadUrl + "/thumbnails/set?videoId=" + E(r.VideoId) + "&uploadType=media", "image/jpeg", jpg, 0, jpg.Length, null);
                if (p.Status == 200) { ThumbDone(r, "set"); Log.W("youtube: thumbnail of " + r.Race + " set"); return; }
                // a 403 is how Paddock finds out: the youtube.upload scope cannot ask whether the channel is verified (channels.list needs more)
                if (p.Status == 403) { ThumbDone(r, "refused"); if (!thumbTold) { thumbTold = true; Log.W("youtube: thumbnail skipped - YouTube allows custom thumbnails only on a phone-verified channel"); } return; }
                ThumbDone(r, "failed");
                Log.W("youtube: thumbnail not set (YouTube answered " + p.Status + ")");
            }
            catch (Exception ex) { ThumbDone(r, "failed"); Log.W("youtube: thumbnail not set (" + ex.GetType().Name + ")"); }
        }
        static void ThumbDone(Rec r, string how) { lock (gate) { r.ThumbSet = how; Save(); } }

        // W1-11: how the thumbnail went for a race ("" not tried, set, refused, skipped, failed): tests and the lead's live check
        public static string ThumbState(string raceId) { lock (gate) { Load(); Rec r = Find(raceId); return r == null ? "" : r.ThumbSet; } }

        // a non-2xx/308 answer to a plain-words stop or a retry
        static void Classify(Resp p)
        {
            string reason = Reason(p.Body);
            if (reason == "quotaExceeded" || reason == "uploadLimitExceeded" || reason == "dailyLimitExceeded")
                throw new Halt("failed", MsgQuota, ToMs(NextNine(LocalNow)));
            if (reason == "rateLimitExceeded" || reason == "userRateLimitExceeded" || reason == "backendError" || p.Status >= 500 || p.Status == 429)
                throw new Transient("YouTube answered " + p.Status + (reason.Length > 0 ? " " + reason : ""));
            if (reason == "youtubeSignupRequired") throw new Halt("failed", MsgChannel, 0);
            if (p.Status == 401) throw new Halt("signin", MsgSignInAgain, 0);
            throw new Halt("failed", "YouTube refused the upload (" + (reason.Length > 0 ? reason : p.Status.ToString(CultureInfo.InvariantCulture)) + ")", 0);
        }

        static string Reason(string body)
        {
            Match m = Regex.Match(body ?? "", "\"reason\"\\s*:\\s*\"([A-Za-z]+)\"");
            return m.Success ? m.Groups[1].Value : "";
        }

        // "Range: bytes=0-1048575" -> 1048575; none = nothing arrived (-1)
        static long RangeEnd(Resp p)
        {
            Match m = Regex.Match(p.Headers["Range"] ?? "", "bytes=\\d+-(\\d+)");
            long v; return m.Success && long.TryParse(m.Groups[1].Value, out v) ? v : -1;
        }

        // ================= HTTP =================

        // one call with the access token; a 401 gets one fresh token and one more try; a second 401 = signed out
        static Resp Authed(string method, string url, string ctype, byte[] body, int off, int len, string range) { return Authed(method, url, ctype, body, off, len, range, null); }
        static Resp Authed(string method, string url, string ctype, byte[] body, int off, int len, string range, Dictionary<string, string> extra)
        {
            Resp p = Call(method, url, AccessToken(false), ctype, body, off, len, range, extra);
            if (p.Status != 401) return p;
            p = Call(method, url, AccessToken(true), ctype, body, off, len, range, extra);
            if (p.Status == 401) throw new Halt("signin", MsgSignInAgain, 0);
            return p;
        }

        static Resp Form(string url, string form)
        {
            byte[] b = Encoding.ASCII.GetBytes(form);      // the secret travels in this body, never in a URL
            return Call("POST", url, null, "application/x-www-form-urlencoded", b, 0, b.Length, null, null);
        }

        static Resp Call(string method, string url, string bearer, string ctype, byte[] body, int off, int len, string range, Dictionary<string, string> extra)
        {
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
            rq.Method = method; rq.AllowAutoRedirect = false; rq.KeepAlive = true; rq.UserAgent = "Paddock";
            rq.Timeout = 300000; rq.ReadWriteTimeout = 300000;
            try { rq.ServicePoint.Expect100Continue = false; } catch { }
            if (bearer != null) rq.Headers["Authorization"] = "Bearer " + bearer;
            if (range != null) rq.Headers["Content-Range"] = range;
            if (extra != null) foreach (KeyValuePair<string, string> kv in extra) rq.Headers[kv.Key] = kv.Value;
            if (method != "GET")
            {
                if (ctype != null) rq.ContentType = ctype;
                rq.ContentLength = body == null ? 0 : len;
                rq.AllowWriteStreamBuffering = false;      // 8 MiB straight from the file buffer to the wire
                if (body != null && len > 0) using (Stream s = rq.GetRequestStream()) s.Write(body, off, len);
            }
            try { using (HttpWebResponse r = (HttpWebResponse)rq.GetResponse()) return Read(r); }
            catch (WebException ex)
            {
                HttpWebResponse r = ex.Response as HttpWebResponse;
                if (r == null) throw;
                using (r) return Read(r);
            }
        }

        static Resp Read(HttpWebResponse r)
        {
            Resp p = new Resp(); p.Status = (int)r.StatusCode; p.Headers = r.Headers;
            try { using (StreamReader sr = new StreamReader(r.GetResponseStream(), Encoding.UTF8)) p.Body = sr.ReadToEnd(); } catch { }
            return p;
        }

        // ================= files =================

        static void Load()
        {
            if (recs != null) return;
            recs = new List<Rec>();
            try
            {
                if (!File.Exists(UploadsFile)) return;
                string text = File.ReadAllText(UploadsFile, Encoding.UTF8);
                Dictionary<string, object> d = Parse(text);
                if (d == null)
                {
                    // never twice: a broken file is kept aside, not overwritten by the next save
                    if (text.Trim().Length > 0)
                    {
                        string aside = Path.Combine(Dir, "uploads.bad-" + DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + ".json");
                        try { File.Move(UploadsFile, aside); } catch { }
                        Log.W("youtube: uploads.json could not be read - kept as " + Path.GetFileName(aside) + ", starting a new list");
                    }
                    return;
                }
                foreach (KeyValuePair<string, object> kv in d)
                {
                    Dictionary<string, object> x = kv.Value as Dictionary<string, object>;
                    if (x == null) continue;
                    Rec r = new Rec(); r.Race = kv.Key;
                    r.Kind = Str(x, "kind"); if (r.Kind.Length == 0) r.Kind = "queued";
                    r.File = Str(x, "file"); r.Title = Str(x, "title"); r.Desc = Str(x, "description"); r.Want = Str(x, "want"); r.Thumb = Str(x, "thumb");
                    r.Tags = Str(x, "tags"); r.ThumbSet = Str(x, "thumbSet");
                    r.VideoId = Str(x, "videoId"); r.Url = Str(x, "url"); r.Privacy = Str(x, "privacy"); r.UploadStatus = Str(x, "uploadStatus"); r.Error = Str(x, "error");
                    r.Pct = (int)Num(x, "pct", 0); r.Tries = (int)Num(x, "tries", 0); r.Restarts = (int)Num(x, "restarts", 0);
                    r.StartedMs = Num(x, "startedMs", 0); r.DoneMs = Num(x, "doneMs", 0); r.RetryAtMs = Num(x, "retryAtMs", 0);
                    if (r.Want != "public") r.Want = "private";
                    recs.Add(r);
                }
            }
            catch (Exception ex) { Log.W("youtube: uploads.json could not be read: " + ex.GetType().Name); }
        }

        // true = on disk
        static bool Save()
        {
            StringBuilder sb = new StringBuilder("{");
            for (int i = 0; i < recs.Count; i++)
            {
                Rec r = recs[i];
                if (i > 0) sb.Append(",\r\n");
                sb.Append(Json_.S(r.Race)).Append(":{\"kind\":").Append(Json_.S(r.Kind)).Append(",\"videoId\":").Append(Json_.S(r.VideoId))
                  .Append(",\"url\":").Append(Json_.S(r.Url)).Append(",\"privacy\":").Append(Json_.S(r.Privacy)).Append(",\"uploadStatus\":").Append(Json_.S(r.UploadStatus))
                  .Append(",\"pct\":").Append(r.Pct).Append(",\"error\":").Append(Json_.S(r.Error))
                  .Append(",\"startedMs\":").Append(r.StartedMs).Append(",\"doneMs\":").Append(r.DoneMs).Append(",\"retryAtMs\":").Append(r.RetryAtMs)
                  .Append(",\"tries\":").Append(r.Tries).Append(",\"restarts\":").Append(r.Restarts)
                  .Append(",\"file\":").Append(Json_.S(r.File)).Append(",\"title\":").Append(Json_.S(r.Title)).Append(",\"description\":").Append(Json_.S(r.Desc))
                  .Append(",\"want\":").Append(Json_.S(r.Want)).Append(",\"thumb\":").Append(Json_.S(r.Thumb))
                  .Append(",\"tags\":").Append(Json_.S(r.Tags)).Append(",\"thumbSet\":").Append(Json_.S(r.ThumbSet)).Append('}');
            }
            sb.Append("}");
            try { WriteAtomic(UploadsFile, Encoding.UTF8.GetBytes(sb.ToString())); return true; }
            catch (Exception ex) { Log.W("youtube: uploads.json could not be saved: " + ex.GetType().Name); return false; }
        }

        static Sess LoadSession(string race)
        {
            try
            {
                string f = SessionFile(race);
                if (!File.Exists(f)) return null;
                Dictionary<string, object> d = Parse(File.ReadAllText(f, Encoding.UTF8));
                if (d == null) return null;
                Sess s = new Sess(); s.Race = Str(d, "race"); s.File = Str(d, "file"); s.Url = Str(d, "url"); s.Title = Str(d, "title"); s.Privacy = Str(d, "privacy");
                s.Size = Num(d, "size", 0); s.Sent = Num(d, "sent", 0); s.StartedMs = Num(d, "startedMs", 0);
                return s.Url.Length > 0 && s.Race == race ? s : null;
            }
            catch { return null; }
        }

        static void SaveSession(Sess s)
        {
            string j = "{\"race\":" + Json_.S(s.Race) + ",\"file\":" + Json_.S(s.File) + ",\"size\":" + s.Size + ",\"url\":" + Json_.S(s.Url) + ",\"sent\":" + s.Sent +
                       ",\"title\":" + Json_.S(s.Title) + ",\"privacy\":" + Json_.S(s.Privacy) + ",\"startedMs\":" + s.StartedMs + "}";
            WriteAtomic(SessionFile(s.Race), Encoding.UTF8.GetBytes(j));
        }

        static void DeleteSession(string race) { try { File.Delete(SessionFile(race)); } catch { } }

        // write beside, then swap: a crash mid-write never leaves half a file
        static void WriteAtomic(string path, byte[] data)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string tmp = path + ".tmp";
            File.WriteAllBytes(tmp, data);
            if (File.Exists(path)) File.Replace(tmp, path, null);
            else File.Move(tmp, path);
        }

        static Rec Find(string race) { foreach (Rec r in recs) if (r.Race == race) return r; return null; }

        // ================= small helpers =================

        static void Bump() { try { StateBuilder.BumpLists(false, false, true, false); } catch { } }
        static string B(bool v) { return v ? "true" : "false"; }
        static string E(string s) { return Uri.EscapeDataString(s ?? ""); }
        static string Mb(long b) { return (b / 1048576.0).ToString("0.#", CultureInfo.InvariantCulture); }
        static long ToMs(DateTime local) { return (long)(local.ToUniversalTime() - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }
        // a word from Google for the log: letters, digits and _ only, so nothing secret can ride along
        static string Safe(string s) { s = Regex.Replace(s ?? "", "[^A-Za-z0-9_ .]", ""); return s.Length > 60 ? s.Substring(0, 60) : s; }

        static byte[] RandomBytes(int n) { byte[] b = new byte[n]; using (RNGCryptoServiceProvider g = new RNGCryptoServiceProvider()) g.GetBytes(b); return b; }
        public static string B64Url(byte[] b) { return Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }

        static Dictionary<string, object> Parse(string json)
        {
            try { return new JavaScriptSerializer().DeserializeObject(json ?? "") as Dictionary<string, object>; } catch { return null; }
        }
        static string Str(Dictionary<string, object> d, string k)
        {
            object v; return d != null && d.TryGetValue(k, out v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : "";
        }
        static long Num(Dictionary<string, object> d, string k, long def)
        {
            object v;
            if (d == null || !d.TryGetValue(k, out v) || v == null) return def;
            try { return Convert.ToInt64(v, CultureInfo.InvariantCulture); } catch { return def; }
        }
    }
}
