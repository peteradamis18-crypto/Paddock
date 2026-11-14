// YOUTUBE (W1-2, docs/rework/cards/W1-2.md, evidence 14): Google sign-in once (loopback + PKCE, the token kept with DPAPI in
// dash\yt\token.bin) and the resumable upload that survives a network drop, a session starting, an irdash or PC restart, never
// uploads a race twice, and says what went wrong in plain words.
//   dash\yt\client.json    Peter's Desktop-app client from Google (docs\YOUTUBE-SETUP.md). Never logged.
//   dash\yt\token.bin      DPAPI (this Windows user) of {"refresh","access","expMs"}. Never logged.
//   dash\yt\session.json   the one upload in flight: its session URL is saved BEFORE the first byte, so a restart resumes it
//   dash\yt\uploads.json   per race id: the "never twice" record and what the RACES page shows
// SignIn() opens the browser on Peter's screens: the lead lists the command (ytsignin) as GuardedDo in rigstate.cs.
// Enqueue() only writes a small record; the upload itself is a Jobs whenFree job (never while a session is on, background
// priority), 8 MiB per PUT, and it stops between two chunks when a session starts (Jobs.ShouldYield).
// The log says "youtube: signed in" and what happened to a race, never a secret, a code, a token or the session URL.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
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
        public static string ApiUrl = "https://www.googleapis.com/youtube/v3";
        public static string Dir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "yt");            // irdash.exe lives in dash\
        public static string IniFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "irdash.ini");
        public static Action<string> OpenBrowser = DefaultOpen;
        public static int ChunkSize = 8 * 1024 * 1024;       // a multiple of 256 KiB (Google's rule for every chunk but the last)
        public static int BackoffBaseMs = 2000, BackoffMaxMs = 300000;   // 2, 4, 8 ... 300 s after a dropped link or a 5xx
        public static int OfflineRetryMs = 60000;            // no internet: look again every minute, for ever
        public static int SignInTimeoutMs = 300000;          // the sign-in page waits 5 minutes for Google's answer
        public static int SliceMs = 120000;                  // a long upload hands the job thread back every 2 minutes
        public static Func<DateTime> Clock;                  // local time, for the "after 9 in the morning" retry (tests)

        public const string Scope = "https://www.googleapis.com/auth/youtube.upload";
        public const string MsgSetup = "Set up YouTube first: docs\\YOUTUBE-SETUP.md";
        public const string MsgSignIn = "Sign in to YouTube";
        public const string MsgSignInAgain = "Sign in to YouTube again";
        public const string MsgQuota = "YouTube says today's upload limit is reached. I'll try again after 9 in the morning";
        public const string MsgOffline = "No internet, waiting";
        public const string MsgAlready = "Already on YouTube";
        public const string SignedInPage = "Paddock is signed in to YouTube. You can close this tab.";
        public const string EntropyText = "Paddock YouTube token";   // extra DPAPI salt: another program of Peter's cannot just call Unprotect
        const string JobName = "youtube upload";

        sealed class Rec
        {
            public string Race = "", Kind = "queued", File = "", Title = "", Desc = "", Want = "private", Thumb = "";
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

        static readonly object gate = new object();
        static List<Rec> recs;               // null = not read from disk yet
        static Tok tok; static bool tokRead;
        static Timer timer;
        static volatile bool signingIn, wantSignIn, paused, busy;
        static bool thumbTold;

        static long NowMs { get { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; } }
        static DateTime LocalNow { get { return Clock != null ? Clock() : DateTime.Now; } }
        static string ClientFile { get { return Path.Combine(Dir, "client.json"); } }
        static string TokenFile { get { return Path.Combine(Dir, "token.bin"); } }
        static string SessionFile { get { return Path.Combine(Dir, "session.json"); } }
        static string UploadsFile { get { return Path.Combine(Dir, "uploads.json"); } }

        // ================= start-up =================

        // irdash start: anything left queued or half-sent (a restart, a PC reboot) carries on when the rig is free
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
        }

        // tests: forget everything held in memory and read it again from dash\yt, as a new irdash process would
        public static void Reset()
        {
            paused = true;
            for (int i = 0; i < 100 && busy; i++) Thread.Sleep(50);
            lock (gate)
            {
                if (timer != null) { try { timer.Dispose(); } catch { } timer = null; }
                recs = null; tok = null; tokRead = false; wantSignIn = false; thumbTold = false;
            }
            paused = false;
        }

        // ================= settings (irdash.ini, section [youtube]) =================

        public static string Privacy { get { string p = IniGet("privacy", "private").ToLowerInvariant(); return p == "public" ? "public" : "private"; } }
        public static int Template { get { int n; return int.TryParse(IniGet("template", "1"), out n) && n >= 1 && n <= 5 ? n : 1; } }

        public static bool SetPrivacy(string p)
        {
            p = (p ?? "").Trim().ToLowerInvariant();
            if (p != "private" && p != "public") return false;
            IniSet("privacy", p); Log.W("youtube: new uploads are " + p); Bump();
            return true;
        }
        public static bool SetTemplate(int n)
        {
            if (n < 1 || n > 5) return false;
            IniSet("template", n.ToString(CultureInfo.InvariantCulture)); Bump();
            return true;
        }

        static string IniGet(string key, string def)
        {
            try
            {
                if (!File.Exists(IniFile)) return def;
                bool inside = false;
                foreach (string raw in File.ReadAllLines(IniFile))
                {
                    string t = raw.Trim();
                    if (t.StartsWith("[")) { inside = t.Equals("[youtube]", StringComparison.OrdinalIgnoreCase); continue; }
                    if (!inside || t.StartsWith(";") || t.StartsWith("#")) continue;
                    int e = t.IndexOf('=');
                    if (e > 0 && t.Substring(0, e).Trim().Equals(key, StringComparison.OrdinalIgnoreCase)) return t.Substring(e + 1).Trim();
                }
            }
            catch { }
            return def;
        }

        // change one key inside [youtube]; every other line of irdash.ini stays as it is
        static void IniSet(string key, string value)
        {
            try
            {
                List<string> o = new List<string>(File.Exists(IniFile) ? File.ReadAllLines(IniFile) : new string[0]);
                int head = -1, end = o.Count;
                for (int i = 0; i < o.Count; i++)
                {
                    string t = o[i].Trim();
                    if (!t.StartsWith("[")) continue;
                    if (head >= 0) { end = i; break; }
                    if (t.Equals("[youtube]", StringComparison.OrdinalIgnoreCase)) head = i;
                }
                if (head < 0) { o.Add(""); o.Add("[youtube]"); o.Add(key + "=" + value); }
                else
                {
                    bool done = false;
                    for (int i = head + 1; i < end; i++)
                    {
                        string t = o[i].Trim(); int e = t.IndexOf('=');
                        if (e > 0 && t.Substring(0, e).Trim().Equals(key, StringComparison.OrdinalIgnoreCase)) { o[i] = key + "=" + value; done = true; break; }
                    }
                    if (!done) { int at = end; while (at > head + 1 && o[at - 1].Trim().Length == 0) at--; o.Insert(at, key + "=" + value); }
                }
                File.WriteAllLines(IniFile, o.ToArray());
            }
            catch (Exception ex) { Log.W("youtube: could not save the " + key + " setting: " + ex.Message); }
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
                    case "failed": case "signin": case "offline": return "{\"kind\":\"" + r.Kind + "\",\"error\":" + Json_.S(r.Error) + "}";
                }
                return "{\"kind\":\"none\"}";
            }
        }

        public static string Json()
        {
            int queue = 0; bool signedIn;
            lock (gate)
            {
                Load();
                foreach (Rec r in recs) if (Pending(r) || r.Kind == "signin") queue++;
                signedIn = LoadToken() != null;
            }
            return "{\"signedIn\":" + B(signedIn) + ",\"privacy\":" + Json_.S(Privacy) + ",\"template\":" + Template.ToString(CultureInfo.InvariantCulture) +
                   ",\"queue\":" + queue.ToString(CultureInfo.InvariantCulture) + ",\"setUp\":" + B(File.Exists(ClientFile)) + ",\"signingIn\":" + B(signingIn) + "}";
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
            if (string.IsNullOrEmpty(raceId) || string.IsNullOrEmpty(file)) { message = "No race video to share"; return false; }
            string want = (privacy ?? "").Trim().ToLowerInvariant();
            if (want != "private" && want != "public") want = Privacy;
            lock (gate)
            {
                Load();
                Rec r = Find(raceId);
                if (r != null && (r.Kind == "shared" || r.Kind == "sharing")) { message = MsgAlready; return false; }   // never twice
                if (r != null && (r.Kind == "queued" || r.Kind == "offline")) { message = "Already waiting to go to YouTube"; }
                else
                {
                    if (r == null) { r = new Rec(); r.Race = raceId; recs.Add(r); }
                    // a failed or signed-out race goes again; a video id it already has (sent, not yet read back) is kept: never twice
                    r.Kind = "queued"; r.Error = ""; r.RetryAtMs = 0; r.Tries = 0; r.Restarts = 0; r.Pct = r.VideoId.Length > 0 ? 100 : 0;
                    r.File = file; r.Title = CleanTitle(title, file); r.Desc = CleanDesc(description); r.Want = want; r.Thumb = thumbJpg ?? "";
                    Save();
                    message = "Going to YouTube when the session is over";
                    Log.W("youtube: " + raceId + " queued (" + want + ")");
                }
                if (LoadToken() == null) wantSignIn = true;     // the first SHARE opens Google's sign-in (docs\YOUTUBE-SETUP.md Part 5)
            }
            Bump();
            Kick(0);
            return true;
        }

        static string CleanTitle(string t, string file)
        {
            t = (t ?? "").Replace("<", "").Replace(">", "").Replace("\r", " ").Replace("\n", " ").Trim();
            if (t.Length == 0) t = Path.GetFileNameWithoutExtension(file ?? "") ?? "iRacing race";
            return t.Length > 100 ? t.Substring(0, 100) : t;
        }
        static string CleanDesc(string d)
        {
            d = (d ?? "").Replace("<", "").Replace(">", "");
            while (Encoding.UTF8.GetByteCount(d) > 5000) d = d.Substring(0, d.Length - 1);
            return d;
        }

        // ================= sign-in (loopback + PKCE) =================

        // the ytsignin command: answers at once, the sign-in runs on its own thread for up to 5 minutes
        public static string SignIn()
        {
            string id, secret;
            if (!ReadClient(out id, out secret)) { Log.W("youtube: sign-in needs dash\\yt\\client.json (docs\\YOUTUBE-SETUP.md)"); return MsgSetup; }
            lock (gate) { if (signingIn) return "Google sign-in is already open in the browser"; signingIn = true; }
            Thread t = new Thread(Crash.Guard("youtube sign-in", delegate ()
            {
                try { SignInRun(id, secret); }
                finally { signingIn = false; Bump(); }
            }));
            t.IsBackground = true; t.Name = "YouTube sign-in"; t.Start();
            Bump();
            return "Google sign-in opened in the browser";
        }

        static void SignInRun(string id, string secret)
        {
            HttpListener l = null; string redirect = null;
            for (int i = 0; i < 5 && l == null; i++)
            {
                int port = FreePort();
                // Google wants 127.0.0.1; if Windows will not give this user that address, localhost works with Google too
                foreach (string host in new[] { "127.0.0.1", "localhost" })
                {
                    HttpListener x = new HttpListener();
                    try { x.Prefixes.Add("http://" + host + ":" + port + "/"); x.Start(); l = x; redirect = "http://" + host + ":" + port; break; }
                    catch { try { x.Close(); } catch { } }
                }
            }
            if (l == null) { Log.W("youtube: sign-in could not open a local port for Google's answer"); return; }
            try
            {
                string verifier = B64Url(RandomBytes(32));
                string challenge;
                using (SHA256 sha = SHA256.Create()) challenge = B64Url(sha.ComputeHash(Encoding.ASCII.GetBytes(verifier)));
                string state = B64Url(RandomBytes(16));
                string url = AuthUrl + "?client_id=" + E(id) + "&redirect_uri=" + E(redirect) + "&response_type=code&scope=" + E(Scope) +
                             "&code_challenge=" + challenge + "&code_challenge_method=S256&state=" + state + "&access_type=offline&prompt=consent";
                try { OpenBrowser(url); } catch (Exception ex) { Log.W("youtube: could not open the browser for the sign-in: " + ex.Message); return; }
                DateTime until = DateTime.UtcNow.AddMilliseconds(SignInTimeoutMs);
                while (true)
                {
                    int left = (int)(until - DateTime.UtcNow).TotalMilliseconds;
                    if (left <= 0) { Log.W("youtube: sign-in stopped - no answer from Google in " + (SignInTimeoutMs / 60000) + " minutes"); return; }
                    IAsyncResult ar = l.BeginGetContext(null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(left)) { Log.W("youtube: sign-in stopped - no answer from Google in " + (SignInTimeoutMs / 60000) + " minutes"); return; }
                    HttpListenerContext ctx = l.EndGetContext(ar);
                    System.Collections.Specialized.NameValueCollection q = ctx.Request.QueryString;
                    if (ctx.Request.Url.AbsolutePath != "/" || q["state"] != state) { Page(ctx, 404, "Not found."); continue; }   // a favicon, an old tab
                    if (!string.IsNullOrEmpty(q["error"]))
                    {
                        Page(ctx, 200, "Paddock was not signed in to YouTube. You can close this tab.");
                        Log.W("youtube: sign-in cancelled on Google's page (" + Safe(q["error"]) + ")");
                        return;
                    }
                    string code = q["code"] ?? "";
                    string err = Exchange(id, secret, code, verifier, redirect);
                    if (err == null)
                    {
                        Page(ctx, 200, SignedInPage);
                        Log.W("youtube: signed in");
                        SignedIn();
                    }
                    else
                    {
                        Page(ctx, 200, "Paddock could not sign in to YouTube. Close this tab and press the sign-in key again.");
                        Log.W("youtube: sign-in failed: " + err);
                    }
                    return;
                }
            }
            finally { try { l.Stop(); } catch { } try { l.Close(); } catch { } }
        }

        // the code for tokens; null = done, else a plain reason (never the answer's text: it holds the tokens)
        static string Exchange(string id, string secret, string code, string verifier, string redirect)
        {
            if (code.Length == 0) return "Google sent no code";
            Resp r;
            try
            {
                r = Form(TokenUrl, "code=" + E(code) + "&client_id=" + E(id) + "&client_secret=" + E(secret) + "&redirect_uri=" + E(redirect) +
                                   "&grant_type=authorization_code&code_verifier=" + E(verifier));
            }
            catch (Exception ex) { return "could not reach Google (" + ex.Message + ")"; }
            if (r.Status != 200) return "Google answered " + r.Status + " " + Safe(Str(Parse(r.Body), "error"));
            Dictionary<string, object> d = Parse(r.Body);
            Tok t = new Tok(); t.Refresh = Str(d, "refresh_token"); t.Access = Str(d, "access_token"); t.ExpMs = NowMs + Num(d, "expires_in", 3600) * 1000;
            if (t.Refresh.Length == 0) return "Google gave no lasting sign-in (no refresh token)";
            lock (gate) { SaveToken(t); }
            return null;
        }

        // signed in: every race waiting for it goes again
        static void SignedIn()
        {
            bool any = false;
            lock (gate)
            {
                Load(); wantSignIn = false;
                foreach (Rec r in recs) if (r.Kind == "signin") { r.Kind = "queued"; r.Error = ""; r.RetryAtMs = 0; any = true; }
                if (any) Save();
            }
            Bump();
            if (any) Kick(0);
        }

        static void Page(HttpListenerContext ctx, int status, string text)
        {
            try
            {
                byte[] b = Encoding.UTF8.GetBytes("<!doctype html><meta charset=\"utf-8\"><title>Paddock</title><body style=\"background:#000;color:#e8c66a;font:28px sans-serif;padding:60px\">" +
                                                  System.Net.WebUtility.HtmlEncode(text) + "</body>");
                ctx.Response.StatusCode = status; ctx.Response.ContentType = "text/html; charset=utf-8";
                ctx.Response.ContentLength64 = b.Length; ctx.Response.OutputStream.Write(b, 0, b.Length); ctx.Response.Close();
            }
            catch { }
        }

        static void DefaultOpen(string url) { System.Diagnostics.Process.Start("explorer.exe", "\"" + url + "\""); }

        static int FreePort()
        {
            TcpListener t = new TcpListener(IPAddress.Loopback, 0);
            t.Start(); int p = ((IPEndPoint)t.LocalEndpoint).Port; t.Stop();
            return p;
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
            Tok t; lock (gate) t = LoadToken();
            if (t == null) throw new Halt("nosignin", MsgSignIn, 0);
            if (!force && t.Access.Length > 0 && t.ExpMs - NowMs > 60000) return t.Access;
            string id, secret;
            if (!ReadClient(out id, out secret)) throw new Halt("setup", MsgSetup, 0);
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

        // ================= the upload job =================

        // run the job now (0) or after ms; the job always picks the race that is due first
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

        // the race to work on: the one already half-sent first, then the oldest; null + wait = nothing due yet
        static Rec NextDue(out long waitMs)
        {
            waitMs = -1;
            Load();
            long now = NowMs;
            Sess s = LoadSession();
            Rec pick = null;
            foreach (Rec r in recs)
            {
                if (!Pending(r)) continue;
                long w = r.RetryAtMs - now;
                if (w > 0) { if (waitMs < 0 || w < waitMs) waitMs = w; continue; }
                if (pick == null || (s != null && r.Race == s.Race && pick.Race != s.Race)) pick = r;
            }
            return pick;
        }

        static void Work()
        {
            if (paused) return;
            busy = true;
            try
            {
                DateTime sliceEnd = DateTime.UtcNow.AddMilliseconds(SliceMs);
                while (!paused)
                {
                    Rec r; long wait;
                    lock (gate) r = NextDue(out wait);
                    if (r == null) { if (wait >= 0) Kick(wait); return; }
                    long o = Turn(r, sliceEnd);
                    if (o == YIELD) { Jobs.Again(JobName, Work); return; }
                    if (o == SLICE) { Jobs.Run(JobName, Work, true); return; }   // other heavy jobs get their turn, then this goes on
                    if (o == STOP) return;
                    if (o >= 0) { lock (gate) NextDue(out wait); Kick(wait >= 0 ? Math.Min(wait, o) : o); return; }
                }
            }
            finally { busy = false; }
        }

        // one race, as far as it goes this time
        static long Turn(Rec r, DateTime sliceEnd)
        {
            try
            {
                if (r.VideoId.Length == 0)
                {
                    long o = Send(r, sliceEnd);
                    if (o != NEXT) return o;
                }
                ReadBack(r);
                Thumbnail(r);
                return NEXT;
            }
            catch (Halt h)
            {
                if (h.Kind == "signout") { DeleteToken(); Log.W("youtube: Google ended the sign-in - press Sign in to YouTube again"); AllPending("signin", MsgSignInAgain); return STOP; }
                if (h.Kind == "setup") { Log.W("youtube: no usable dash\\yt\\client.json - " + MsgSetup); AllPending("signin", MsgSetup); return STOP; }
                if (h.Kind == "nosignin")
                {
                    AllPending("signin", MsgSignIn);
                    if (wantSignIn) { wantSignIn = false; SignIn(); }
                    return STOP;
                }
                if (h.Kind == "signin") { Log.W("youtube: YouTube refused the sign-in twice - " + MsgSignInAgain); AllPending("signin", MsgSignInAgain); return STOP; }
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

        // the resumable upload: NEXT = the file is on YouTube (VideoId set), else YIELD / SLICE / a wait
        static long Send(Rec r, DateTime sliceEnd)
        {
            if (!File.Exists(r.File)) throw new Halt("failed", "The race video file is gone", 0);
            long size = new FileInfo(r.File).Length;
            if (size <= 0) throw new Halt("failed", "The race video file is empty", 0);
            Sess s; lock (gate) s = LoadSession();
            if (s != null && s.Race == r.Race && (s.Size != size || !string.Equals(s.File, r.File, StringComparison.OrdinalIgnoreCase))) { DeleteSession(); s = null; }   // the file changed: start again
            if (s != null && s.Race != r.Race) s = null;           // another race's session stays on disk for its own turn

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
                    if (Jobs.ShouldYield || paused) { lock (gate) { s.Sent = next; SaveSession(s); } Log.W("youtube: " + r.Race + " upload paused at " + r.Pct + "% - a session started"); return YIELD; }
                    if (DateTime.UtcNow >= sliceEnd) return SLICE;
                    int len = (int)Math.Min(ChunkSize, size - next);
                    if (buf == null || buf.Length < len) buf = new byte[Math.Max(len, Math.Min(ChunkSize, (int)Math.Min(size, int.MaxValue)))];
                    fs.Position = next;
                    int got = 0;
                    while (got < len) { int n = fs.Read(buf, got, len - got); if (n <= 0) throw new Halt("failed", "The race video file got shorter while it was being sent", 0); got += n; }
                    Resp p = Authed("PUT", s.Url, "video/mp4", buf, 0, len, "bytes " + next + "-" + (next + len - 1) + "/" + size);
                    if (p.Status == 308)
                    {
                        next = RangeEnd(p) + 1;
                        lock (gate) { s.Sent = next; SaveSession(s); r.Tries = 0; r.Kind = "sharing"; r.Error = ""; r.Pct = (int)Math.Min(99, next * 100 / size); Save(); }
                        Bump();
                    }
                    else if (p.Status == 200 || p.Status == 201) done = p;
                    else if (p.Status == 404 || p.Status == 410) { s = Restart(r, size); next = 0; }
                    else Classify(p);
                }
            }
            string vid = Str(Parse(done.Body), "id");
            if (vid.Length == 0) throw new Halt("failed", "YouTube took the video but did not say its address", 0);
            lock (gate) { r.VideoId = vid; r.Pct = 100; Save(); DeleteSession(); }
            Log.W("youtube: " + r.Race + " sent (" + Mb(size) + " MB), checking it on YouTube");
            Bump();
            return NEXT;
        }

        // a new upload session; its address is on disk before the first byte goes
        static Sess Begin(Rec r, long size)
        {
            string meta = "{\"snippet\":{\"title\":" + Json_.S(r.Title) + ",\"description\":" + Json_.S(r.Desc) + ",\"categoryId\":\"20\"}," +
                          "\"status\":{\"privacyStatus\":" + Json_.S(r.Want) + ",\"selfDeclaredMadeForKids\":false}}";
            byte[] body = Encoding.UTF8.GetBytes(meta);
            Dictionary<string, string> h = new Dictionary<string, string>();
            h["X-Upload-Content-Length"] = size.ToString(CultureInfo.InvariantCulture); h["X-Upload-Content-Type"] = "video/mp4";
            Resp p = Authed("POST", UploadUrl + "/videos?uploadType=resumable&part=snippet,status", "application/json; charset=UTF-8", body, 0, body.Length, null, h);
            if (p.Status != 200 && p.Status != 201) Classify(p);
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
            lock (gate) { DeleteSession(); r.Restarts++; Save(); }
            if (r.Restarts > 3) throw new Halt("failed", "YouTube kept losing the upload. Press Share to try again", 0);
            Log.W("youtube: " + r.Race + " - YouTube forgot the half-sent upload, starting it again");
            return Begin(r, size);
        }

        // read the video back: only YouTube's own answer makes a race "shared" (W1-1's free-up-space trusts that word)
        static void ReadBack(Rec r)
        {
            Resp p = Authed("GET", ApiUrl + "/videos?part=status&id=" + E(r.VideoId), null, null, 0, 0, null);
            if (p.Status != 200) Classify(p);
            Dictionary<string, object> d = Parse(p.Body);
            object[] items = d != null && d.ContainsKey("items") ? d["items"] as object[] : null;
            Dictionary<string, object> it = items != null && items.Length > 0 ? items[0] as Dictionary<string, object> : null;
            Dictionary<string, object> st = it != null && it.ContainsKey("status") ? it["status"] as Dictionary<string, object> : null;
            if (st == null) throw new Transient("YouTube does not show the video yet");
            string up = Str(st, "uploadStatus"), priv = Str(st, "privacyStatus");
            if (up == "rejected" || up == "failed" || up == "deleted")
            {
                string why = Str(st, up == "rejected" ? "rejectionReason" : "failureReason");
                lock (gate) { r.VideoId = ""; r.Pct = 0; r.StartedMs = 0; }
                throw new Halt("failed", "YouTube " + (up == "deleted" ? "deleted" : "rejected") + " the video" + (why.Length > 0 ? " (" + why + ")" : ""), 0);
            }
            lock (gate)
            {
                r.Kind = "shared"; r.Privacy = priv.Length > 0 ? priv : r.Want; r.UploadStatus = up; r.Url = "https://youtu.be/" + r.VideoId;
                r.Pct = 100; r.Error = ""; r.RetryAtMs = 0; r.DoneMs = NowMs; Save();
            }
            Log.W("youtube: " + r.Race + " is on YouTube (" + r.Privacy + ") " + r.Url);
            Bump();
        }

        // the race frame as the thumbnail; a refusal never spoils a shared race
        static void Thumbnail(Rec r)
        {
            if (r.Thumb.Length == 0 || !File.Exists(r.Thumb)) return;
            try
            {
                byte[] jpg = File.ReadAllBytes(r.Thumb);
                Resp p = Authed("POST", UploadUrl + "/thumbnails/set?videoId=" + E(r.VideoId) + "&uploadType=media", "image/jpeg", jpg, 0, jpg.Length, null);
                if (p.Status == 200) return;
                if (p.Status == 403) { if (!thumbTold) { thumbTold = true; Log.W("youtube: thumbnail skipped - YouTube allows custom thumbnails only on a phone-verified channel"); } return; }
                Log.W("youtube: thumbnail not set (YouTube answered " + p.Status + ")");
            }
            catch (Halt) { Log.W("youtube: thumbnail not set (sign-in refused)"); }
            catch (Exception ex) { Log.W("youtube: thumbnail not set (" + ex.GetType().Name + ")"); }
        }

        // a non-2xx/308 answer to a plain-words stop or a retry
        static void Classify(Resp p)
        {
            string reason = Reason(p.Body);
            if (reason == "quotaExceeded" || reason == "uploadLimitExceeded" || reason == "dailyLimitExceeded")
                throw new Halt("failed", MsgQuota, ToMs(NextNine(LocalNow)));
            if (p.Status >= 500 || p.Status == 429) throw new Transient("YouTube answered " + p.Status);
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

        // one call with the access token; a 401 gets one fresh token and one more try
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
                Dictionary<string, object> d = Parse(File.ReadAllText(UploadsFile, Encoding.UTF8));
                if (d == null) return;
                foreach (KeyValuePair<string, object> kv in d)
                {
                    Dictionary<string, object> x = kv.Value as Dictionary<string, object>;
                    if (x == null) continue;
                    Rec r = new Rec(); r.Race = kv.Key;
                    r.Kind = Str(x, "kind"); if (r.Kind.Length == 0) r.Kind = "queued";
                    r.File = Str(x, "file"); r.Title = Str(x, "title"); r.Desc = Str(x, "description"); r.Want = Str(x, "want"); r.Thumb = Str(x, "thumb");
                    r.VideoId = Str(x, "videoId"); r.Url = Str(x, "url"); r.Privacy = Str(x, "privacy"); r.UploadStatus = Str(x, "uploadStatus"); r.Error = Str(x, "error");
                    r.Pct = (int)Num(x, "pct", 0); r.Tries = (int)Num(x, "tries", 0); r.Restarts = (int)Num(x, "restarts", 0);
                    r.StartedMs = Num(x, "startedMs", 0); r.DoneMs = Num(x, "doneMs", 0); r.RetryAtMs = Num(x, "retryAtMs", 0);
                    if (r.Want != "public") r.Want = "private";
                    recs.Add(r);
                }
            }
            catch (Exception ex) { Log.W("youtube: uploads.json could not be read: " + ex.Message); }
        }

        static void Save()
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
                  .Append(",\"want\":").Append(Json_.S(r.Want)).Append(",\"thumb\":").Append(Json_.S(r.Thumb)).Append('}');
            }
            sb.Append("}");
            try { WriteAtomic(UploadsFile, Encoding.UTF8.GetBytes(sb.ToString())); }
            catch (Exception ex) { Log.W("youtube: uploads.json could not be saved: " + ex.Message); }
        }

        static Sess LoadSession()
        {
            try
            {
                if (!File.Exists(SessionFile)) return null;
                Dictionary<string, object> d = Parse(File.ReadAllText(SessionFile, Encoding.UTF8));
                if (d == null) return null;
                Sess s = new Sess(); s.Race = Str(d, "race"); s.File = Str(d, "file"); s.Url = Str(d, "url"); s.Title = Str(d, "title"); s.Privacy = Str(d, "privacy");
                s.Size = Num(d, "size", 0); s.Sent = Num(d, "sent", 0); s.StartedMs = Num(d, "startedMs", 0);
                return s.Url.Length > 0 && s.Race.Length > 0 ? s : null;
            }
            catch { return null; }
        }

        static void SaveSession(Sess s)
        {
            string j = "{\"race\":" + Json_.S(s.Race) + ",\"file\":" + Json_.S(s.File) + ",\"size\":" + s.Size + ",\"url\":" + Json_.S(s.Url) + ",\"sent\":" + s.Sent +
                       ",\"title\":" + Json_.S(s.Title) + ",\"privacy\":" + Json_.S(s.Privacy) + ",\"startedMs\":" + s.StartedMs + "}";
            WriteAtomic(SessionFile, Encoding.UTF8.GetBytes(j));
        }

        static void DeleteSession() { try { File.Delete(SessionFile); } catch { } }

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
