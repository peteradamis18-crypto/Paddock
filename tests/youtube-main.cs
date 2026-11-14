// Entry point for tests\youtube-test.ps1 only (W1-2): compiled with dash\src\*.cs and tests\youtube-google.cs (csc /main:IRDash.YouTubeMain)
// into a throw-away exe in %TEMP%. Points every YouTube address at the pretend Google, dash\yt at a temp folder, and walks the card's
// cases 1-9 plus the review's. Prints "ok ..." / "FAIL ..." lines and DONE. Every secret and token is made up; nothing reaches the
// real Google. Failure lines never print a token or a secret (only counts and states).
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class YouTubeMain
    {
        static int fails;
        static volatile bool sessionOn;
        static string tmp, yt;
        static PretendGoogle g;
        static readonly List<string> pages = new List<string>();
        static string browserUrl = "";
        static int opens;
        static volatile string mode = "google";       // google = follow Google's redirect; wrongstate = a bad tab, then "Cancel"; none = never answer

        static void Ok(string what, bool cond, string why)
        {
            if (cond) Console.WriteLine("ok " + what);
            else { fails++; Console.WriteLine("FAIL " + what + (string.IsNullOrEmpty(why) ? "" : " (" + why + ")")); }
        }
        static void Ok(string what, bool cond) { Ok(what, cond, ""); }

        static bool WaitFor(Func<bool> f, int ms)
        {
            DateTime until = DateTime.UtcNow.AddMilliseconds(ms);
            while (DateTime.UtcNow < until) { if (f()) return true; Thread.Sleep(20); }
            return f();
        }

        static string Kind(string race) { Match m = Regex.Match(YouTube.StateJson(race), "\"kind\":\"([a-z]+)\""); return m.Success ? m.Groups[1].Value : "?"; }
        static PretendGoogle.Up UpFor(string title) { lock (g.Ups) foreach (PretendGoogle.Up u in g.Ups.Values) if (u.Title == title) return u; return null; }
        static List<PretendGoogle.Up> UpsFor(string title) { List<PretendGoogle.Up> l = new List<PretendGoogle.Up>(); lock (g.Ups) foreach (PretendGoogle.Up u in g.Ups.Values) if (u.Title == title) l.Add(u); return l; }
        static string Events(PretendGoogle.Up u) { return u == null ? "no upload" : string.Join(" | ", u.Events.ToArray()); }
        static string LogText() { Log.Flush(3000); try { return File.ReadAllText(Path.Combine(tmp, "youtube.log")); } catch { return ""; } }
        static int Count(string text, string what) { int n = 0, i = 0; while ((i = text.IndexOf(what, i, StringComparison.Ordinal)) >= 0) { n++; i += what.Length; } return n; }
        static bool Has(byte[] hay, byte[] needle)
        {
            for (int i = 0; i + needle.Length <= hay.Length; i++) { int k = 0; while (k < needle.Length && hay[i + k] == needle[k]) k++; if (k == needle.Length) return true; }
            return false;
        }
        static string Param(string url, string name) { Match m = Regex.Match(url, "[?&]" + name + "=([^&]*)"); return m.Success ? Uri.UnescapeDataString(m.Groups[1].Value) : ""; }
        static string Get(string url)
        {
            try
            {
                HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url); rq.AllowAutoRedirect = true; rq.Timeout = 10000;
                using (WebResponse r = rq.GetResponse()) using (StreamReader sr = new StreamReader(r.GetResponseStream())) return sr.ReadToEnd();
            }
            catch (WebException ex)
            {
                HttpWebResponse r = ex.Response as HttpWebResponse;
                if (r == null) return "ERR " + ex.Status;
                using (StreamReader sr = new StreamReader(r.GetResponseStream())) return "HTTP" + (int)r.StatusCode + " " + sr.ReadToEnd();
            }
        }
        // nothing listens on the sign-in port any more (refused)
        static bool PortClosed(string redirect)
        {
            if (redirect.Length == 0) return false;
            try { using (TcpClient c = new TcpClient()) { c.Connect(new Uri(redirect).Host, new Uri(redirect).Port); return false; } }
            catch { return true; }
        }
        static string Sess(string race) { return Path.Combine(yt, "session-" + race + ".json"); }

        static int Main(string[] a)
        {
            tmp = a.Length > 0 ? a[0] : Path.Combine(Path.GetTempPath(), "yt-test-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(tmp);
            yt = Path.Combine(tmp, "yt");
            Log.FilePath = Path.Combine(tmp, "youtube.log");
            Jobs.SessionOn = delegate () { return sessionOn; };
            Jobs.GraceMs = 0;
            g = new PretendGoogle(); g.Start();
            YouTube.AuthUrl = g.Base + "/o/oauth2/v2/auth"; YouTube.TokenUrl = g.Base + "/token";
            YouTube.UploadUrl = g.Base + "/upload/youtube/v3"; YouTube.ApiUrl = g.Base + "/youtube/v3";
            YouTube.Dir = yt; YouTube.IniFile = Path.Combine(tmp, "irdash.ini");
            YouTube.ChunkSize = 1024 * 1024; YouTube.BackoffBaseMs = 100; YouTube.BackoffMaxMs = 800; YouTube.OfflineRetryMs = 300; YouTube.SignInTimeoutMs = 15000;
            YouTube.OpenBrowser = delegate (string url)
            {
                browserUrl = url; Interlocked.Increment(ref opens);
                string m = mode;
                if (m == "none") return;
                Thread t = new Thread(delegate ()
                {
                    string redirect = Param(url, "redirect_uri"), state = Param(url, "state"), page;
                    if (m == "wrongstate")
                    {
                        page = Get(redirect + "?state=not-this-one&code=x");
                        lock (pages) pages.Add(page);
                        page = Get(redirect + "?state=" + Uri.EscapeDataString(state) + "&error=access_denied");
                    }
                    else page = Get(url);
                    lock (pages) pages.Add(page);
                });
                t.IsBackground = true; t.Start();
            };

            // the race video: 3 MiB of fixed noise, and a small "jpeg"
            byte[] video = new byte[3 * 1024 * 1024]; new Random(20261113).NextBytes(video);
            string file = Path.Combine(tmp, "race.mp4"); File.WriteAllBytes(file, video);
            string thumb = Path.Combine(tmp, "thumb.jpg"); File.WriteAllBytes(thumb, new byte[] { 0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9 });
            string hash = PretendGoogle.Hash(video);

            try { Run(file, thumb, hash, video.Length); }
            catch (Exception ex) { Ok("the harness ran without an exception", false, ex.GetType().Name + ": " + ex.Message); }
            Console.WriteLine("DONE");
            return fails == 0 ? 0 : 1;
        }

        static void Run(string file, string thumb, string hash, long size)
        {
            // ---- 0. a broken uploads.json is kept aside, never overwritten ----
            Directory.CreateDirectory(yt);
            File.WriteAllText(Path.Combine(yt, "uploads.json"), "{\"r-old\":{\"kind\":\"shared\",\"videoId\":\"x\"  <- half written");
            YouTube.Json();
            Ok("0. a corrupt uploads.json is moved aside as uploads.bad-*.json", Directory.GetFiles(yt, "uploads.bad-*.json").Length == 1 && !File.Exists(Path.Combine(yt, "uploads.json")));
            Ok("0. ... with one log line", Count(LogText(), "uploads.json could not be read - kept as uploads.bad-") == 1);

            // ---- 0. no client.json yet: one plain message, no browser ----
            Ok("0. SignIn without client.json says how to set it up", YouTube.SignIn() == YouTube.MsgSetup);
            Ok("0. Json says not set up and not signed in", YouTube.Json().Contains("\"signedIn\":false") && YouTube.Json().Contains("\"setUp\":false"), YouTube.Json());
            g.CutOnce = true; g.ThumbForbiddenOnce = true;
            Ok("0. a race can be queued before YouTube is set up", YouTube.Enqueue("r0", file, "race r0", "0:00 Start\nLap 1", null, thumb));
            Ok("0. ... and shows kind signin with the set-up message", WaitFor(delegate () { return YouTube.StateJson("r0") == "{\"kind\":\"signin\",\"error\":" + Json_.S(YouTube.MsgSetup) + "}"; }, 5000), YouTube.StateJson("r0"));
            File.WriteAllText(Path.Combine(yt, "client.json"), "{\"installed\":{\"client_id\":\"" + PretendGoogle.ClientId + "\",\"project_id\":\"paddock-test\",\"auth_uri\":\"x\",\"token_uri\":\"x\",\"client_secret\":\"" + PretendGoogle.Secret + "\",\"redirect_uris\":[\"http://localhost\"]}}");
            YouTube.Enqueue("r0", file, "race r0", "0:00 Start\nLap 1", null, thumb);
            Ok("0. set up but never signed in: kind signin \"Sign in to YouTube\"", WaitFor(delegate () { return YouTube.StateJson("r0") == "{\"kind\":\"signin\",\"error\":\"Sign in to YouTube\"}"; }, 5000), YouTube.StateJson("r0"));
            Thread.Sleep(300);
            Ok("0. the upload job opened no browser (only the sign-in key does)", opens == 0, opens + " opens");

            // ---- 1a. sign-in: a wrong state is ignored, then Cancel on Google's page ----
            mode = "wrongstate";
            YouTube.SignIn();
            Ok("1a. the sign-in ends after Cancel", WaitFor(delegate () { lock (pages) return pages.Count >= 2; }, 8000) && WaitFor(delegate () { return YouTube.Json().Contains("\"signingIn\":false"); }, 3000), pages.Count + " pages");
            Ok("1a. a request with the wrong state gets \"Not found.\"", pages.Count >= 1 && pages[0].Contains("Not found."), pages.Count > 0 ? pages[0].Substring(0, Math.Min(40, pages[0].Length)) : "none");
            Ok("1a. error=access_denied gets the not-signed-in page", pages.Count >= 2 && pages[1].Contains(YouTube.NotSignedInPage));
            Ok("1a. still signed out, no token.bin", YouTube.Json().Contains("\"signedIn\":false") && !File.Exists(Path.Combine(yt, "token.bin")));
            Ok("1a. the sign-in port is closed", WaitFor(delegate () { return PortClosed(Param(browserUrl, "redirect_uri")); }, 2000));
            Ok("1a. the log says it was cancelled", LogText().Contains("youtube: sign-in cancelled on Google's page (access_denied)"));

            // ---- 1b. sign-in: no answer -> the timeout closes the listener; a second press opens the same page again ----
            mode = "none"; YouTube.SignInTimeoutMs = 1500; opens = 0;
            YouTube.SignIn();
            WaitFor(delegate () { return opens >= 1; }, 2000);
            string first = browserUrl;
            YouTube.SignIn();
            Ok("1b. a second press while the page waits opens the same page again", opens == 2 && browserUrl == first, opens + " opens");
            Ok("1b. after the timeout the sign-in stops", WaitFor(delegate () { return YouTube.Json().Contains("\"signingIn\":false"); }, 5000));
            Ok("1b. ... and its port is closed", PortClosed(Param(first, "redirect_uri")));
            Ok("1b. ... one log line", LogText().Contains("youtube: sign-in stopped - no answer from Google"));
            YouTube.SignInTimeoutMs = 15000; mode = "google";
            lock (pages) pages.Clear();

            // ---- 1. sign-in (the progress sampler for case 3 starts first: r0 goes the moment the sign-in is done) ----
            List<int> pcts = new List<int>();
            bool sampling = true;
            Thread sampler = new Thread(delegate ()
            {
                while (sampling) { Match m = Regex.Match(YouTube.StateJson("r0"), "\"pct\":(\\d+)"); if (m.Success) lock (pcts) pcts.Add(int.Parse(m.Groups[1].Value)); Thread.Sleep(10); }
            });
            sampler.IsBackground = true; sampler.Start();
            g.AfterChunk = delegate (PretendGoogle.Up u) { if (u.Title == "race r0") Thread.Sleep(150); };   // time for the sampler to see the progress
            string said = YouTube.SignIn();
            Ok("1. SignIn answers at once", said.Contains("browser"), said);
            Ok("1. signed in within 10 s", WaitFor(delegate () { return YouTube.Json().Contains("\"signedIn\":true"); }, 10000), YouTube.Json());
            Ok("1. the sign-in URL asks for youtube.upload, offline, consent, S256 and http://127.0.0.1:<port>/", g.RedirectOk && g.ChallengeMethod == "S256");
            Ok("1. the PKCE verifier matches the challenge", g.PkceOk);
            Ok("1. the client secret went in the token POST body, never in a URL", g.SecretInBody && !g.SecretInQuery && !browserUrl.Contains(PretendGoogle.Secret));
            string tokenFile = Path.Combine(yt, "token.bin");
            Ok("1. token.bin exists", File.Exists(tokenFile));
            if (File.Exists(tokenFile))
            {
                byte[] tb = File.ReadAllBytes(tokenFile);
                bool plain = Has(tb, Encoding.UTF8.GetBytes(PretendGoogle.Refresh)) || Has(tb, Encoding.Unicode.GetBytes(PretendGoogle.Refresh)) || Has(tb, Encoding.UTF8.GetBytes("pretend-access"));
                Ok("1. token.bin is not plaintext (no token string in it)", !plain);
                string back = "";
                try { back = Encoding.UTF8.GetString(ProtectedData.Unprotect(tb, Encoding.UTF8.GetBytes(YouTube.EntropyText), DataProtectionScope.CurrentUser)); } catch { }
                Ok("1. token.bin is DPAPI for this Windows user (Unprotect gives the refresh token back)", back.Contains(PretendGoogle.Refresh));
            }
            Ok("1. the browser got one page, and it says signed in", WaitFor(delegate () { lock (pages) return pages.Count >= 1; }, 3000) && pages.Count == 1 && pages[0].Contains(YouTube.SignedInPage));
            Ok("1. the sign-in listener is closed afterwards", WaitFor(delegate () { return PortClosed(Param(browserUrl, "redirect_uri")); }, 2000));

            // ---- 2 + 3. the race waiting for the sign-in goes by itself: refresh first, cut at 40 %, resume ----
            Ok("3. r0 goes to YouTube by itself after the sign-in", WaitFor(delegate () { return Kind("r0") == "shared"; }, 20000), YouTube.StateJson("r0"));
            sampling = false; sampler.Join(500);
            Ok("2. the access token about to run out was refreshed before the upload", g.Refreshes >= 1 && g.FirstPostToken.Length > 0 && g.FirstPostToken != g.Issued[0], "refreshes " + g.Refreshes);
            PretendGoogle.Up u0 = UpFor("race r0");
            Ok("3. one upload session for r0", UpsFor("race r0").Count == 1);
            if (u0 != null)
            {
                long cut = size * 4 / 10;
                Ok("3. the link dropped at 40 %, then Paddock asked */total and carried on from the Range byte", Regex.IsMatch(Events(u0), "cut " + cut + " \\| query " + cut + " \\| put " + cut + "-"), Events(u0));
                Ok("3. chunks are 1 MiB: the first PUT is bytes 0-1048575", Events(u0).StartsWith("put 0-1048575"), Events(u0));
                Ok("3. the file arrived byte-exact (SHA-256)", PretendGoogle.Hash(u0.Data.ToArray()) == hash);
                Ok("3. the upload asked for private (the default setting) and category 20", u0.Privacy == "private" && u0.Meta.Contains("\"categoryId\":\"20\""));
            }
            Ok("3. StateJson is the contract's shared object", YouTube.StateJson("r0") == "{\"kind\":\"shared\",\"pct\":100,\"privacy\":\"private\",\"url\":\"https://youtu.be/vid-s1\"}", YouTube.StateJson("r0"));
            string uploads = File.Exists(Path.Combine(yt, "uploads.json")) ? File.ReadAllText(Path.Combine(yt, "uploads.json")) : "";
            Ok("3. uploads.json says r0 shared, with the url and YouTube's upload status", Regex.IsMatch(uploads, "\"r0\":\\{\"kind\":\"shared\",\"videoId\":\"vid-s1\",\"url\":\"https://youtu.be/vid-s1\",\"privacy\":\"private\",\"uploadStatus\":\"uploaded\",\"pct\":100"));
            bool mid; lock (pcts) mid = pcts.Exists(delegate (int p) { return p > 0 && p < 100; });
            int last; lock (pcts) last = pcts.Count > 0 ? pcts[pcts.Count - 1] : -1;
            Ok("3. pct moved through the middle and reached 100", mid && last == 100, "samples " + pcts.Count + ", last " + last);
            Ok("3. r0's session file is gone once the video is on YouTube", !File.Exists(Sess("r0")));
            g.AfterChunk = null;

            // ---- 8. thumbnail 403 ----
            string log = LogText();
            Ok("8. the thumbnail 403 left r0 shared and wrote one log line", g.ThumbsRefused == 1 && Kind("r0") == "shared" && Count(log, "thumbnail skipped") == 1, "refused " + g.ThumbsRefused + ", lines " + Count(log, "thumbnail skipped"));
            Ok("8. no job failed (no exception)", !Regex.IsMatch(Jobs.Status(), "\"name\":\"youtube upload\"[^}]*\"error\":\"[^\"]+\""));

            // ---- 4. never twice ----
            string msg;
            bool again = YouTube.Enqueue("r0", file, "race r0", "", null, thumb, out msg);
            Ok("4. Enqueue on a shared race is refused: \"Already on YouTube\"", !again && msg == YouTube.MsgAlready, msg);
            Ok("4. ... and nothing new reached Google", UpsFor("race r0").Count == 1);

            // ---- 5. restart mid-way ----
            g.AfterChunk = delegate (PretendGoogle.Up u) { if (u.Title == "race r2" && u.Chunks == 1) g.StopAfterThis = true; };
            YouTube.Enqueue("r2", file, "race r2", "", "private", thumb);
            Ok("5. the pretend Google went away after r2's first chunk", WaitFor(delegate () { PretendGoogle.Up x = UpFor("race r2"); return x != null && x.Chunks == 1; }, 10000));
            Thread.Sleep(1200);                    // Paddock fails to reach it a few times
            Ok("5. r2 is waiting (offline or retrying), not failed", Kind("r2") == "offline" || Kind("r2") == "sharing", YouTube.StateJson("r2"));
            Ok("5. session-r2.json kept the session", File.Exists(Sess("r2")) && File.ReadAllText(Sess("r2")).Contains("\"race\":\"r2\""));
            g.AfterChunk = null;
            YouTube.Reset();                        // a new irdash: everything from disk again
            g.Start();
            YouTube.Start();
            Ok("5. after the restart r2 finishes", WaitFor(delegate () { return Kind("r2") == "shared"; }, 15000), YouTube.StateJson("r2"));
            PretendGoogle.Up u2 = UpFor("race r2");
            if (u2 != null)
            {
                Ok("5. it asked */total and went on from byte 1048576", Regex.IsMatch(Events(u2), "^put 0-1048575 \\| query 1048576 \\| put 1048576-"), Events(u2));
                Ok("5. no byte before the Range byte was sent again", u2.PutBytes == size, u2.PutBytes + " of " + size);
                Ok("5. byte-exact", PretendGoogle.Hash(u2.Data.ToArray()) == hash);
                Ok("5. one upload session for r2 (resumed, not restarted)", UpsFor("race r2").Count == 1);
            }
            Ok("5. the thumbnail was set for r2", g.ThumbsSet >= 1);

            // ---- 6. a session starts mid-upload; another race is queued meanwhile ----
            g.AfterChunk = delegate (PretendGoogle.Up u) { if (u.Title == "race r4" && u.Chunks == 1) sessionOn = true; };
            YouTube.Enqueue("r4", file, "race r4", "", "private", "");
            Ok("6. the session started after r4's first chunk", WaitFor(delegate () { return sessionOn; }, 10000));
            Thread.Sleep(1000);
            PretendGoogle.Up u4 = UpFor("race r4");
            Ok("6. the job stopped within one chunk", u4 != null && u4.Chunks <= 2, u4 == null ? "no upload" : u4.Chunks + " chunks");
            Ok("6. session-r4.json is kept and r4 shows sharing", File.Exists(Sess("r4")) && Kind("r4") == "sharing", YouTube.StateJson("r4"));
            Ok("6. Jobs says the upload is queued again, not running", !Jobs.Status().Contains("\"running\":{\"name\":\"youtube upload\"") && Jobs.Status().Contains("\"queued\":[{\"name\":\"youtube upload\""));
            g.AfterChunk = null;
            YouTube.Enqueue("r9", file, "race r9", "", "private", "");
            Ok("6. a second race queued while r4 is half-sent waits", Kind("r9") == "queued" && UpFor("race r9") == null);
            sessionOn = false;
            Ok("6. the session over, r4 finishes", WaitFor(delegate () { return Kind("r4") == "shared"; }, 10000), YouTube.StateJson("r4"));
            if (u4 != null) Ok("6. byte-exact, nothing sent twice", PretendGoogle.Hash(u4.Data.ToArray()) == hash && u4.PutBytes == size, u4.PutBytes + "");
            Ok("6. r9 goes after r4", WaitFor(delegate () { return Kind("r9") == "shared"; }, 10000), YouTube.StateJson("r9"));
            int d4 = g.Order.IndexOf("done race r4"), s9 = g.Order.IndexOf("start race r9");
            Ok("6. r9 did not start before r4 was finished (one half-sent race at a time)", d4 >= 0 && s9 > d4, string.Join(", ", g.Order.ToArray()));
            Ok("6. one session for r4, one for r9, r4's file untouched by r9", UpsFor("race r4").Count == 1 && UpsFor("race r9").Count == 1 && !File.Exists(Sess("r4")) && !File.Exists(Sess("r9")));

            // ---- 7. daily limit, no internet ----
            YouTube.Clock = delegate () { return new DateTime(2026, 11, 13, 15, 0, 0, DateTimeKind.Local); };
            g.QuotaOnce = true;
            YouTube.Enqueue("r3", file, "race r3", "", "private", "");
            // W1-4 review: a daily-limit race is waiting (queued, gold) with the plain words, not "failed"; the record itself stays failed + a retry time
            Ok("7. quota 403 -> kind queued (waiting for its retry time)", WaitFor(delegate () { return YouTube.RetryAt("r3") > DateTime.MinValue && Kind("r3") == "queued"; }, 10000), YouTube.StateJson("r3"));
            Ok("7. ... with the exact message", YouTube.StateJson("r3") == "{\"kind\":\"queued\",\"pct\":0,\"error\":" + Json_.S(YouTube.MsgDailyWait) + "}", YouTube.StateJson("r3"));
            Ok("7. ... and a retry at 09:00 the next morning", YouTube.RetryAt("r3") == new DateTime(2026, 11, 14, 9, 0, 0), YouTube.RetryAt("r3").ToString("s"));
            Ok("7. before 9 in the morning the retry is the same day", YouTube.NextNine(new DateTime(2026, 11, 14, 8, 0, 0)) == new DateTime(2026, 11, 14, 9, 0, 0));
            YouTube.Clock = null;
            string goodUpload = YouTube.UploadUrl;
            TcpListener dead = new TcpListener(IPAddress.Loopback, 0); dead.Start(); int deadPort = ((IPEndPoint)dead.LocalEndpoint).Port; dead.Stop();
            YouTube.UploadUrl = "http://127.0.0.1:" + deadPort + "/upload/youtube/v3";
            YouTube.Enqueue("r5", file, "race r5", "", "private", "");
            Ok("7. no internet -> kind offline, \"No internet, waiting\"", WaitFor(delegate () { return YouTube.StateJson("r5") == "{\"kind\":\"offline\",\"error\":\"No internet, waiting\"}"; }, 10000), YouTube.StateJson("r5"));
            Thread.Sleep(1000);
            Ok("7. it keeps waiting (still offline after several tries)", Kind("r5") == "offline");
            YouTube.UploadUrl = goodUpload;
            Ok("7. the internet back, r5 finishes by itself", WaitFor(delegate () { return Kind("r5") == "shared"; }, 10000), YouTube.StateJson("r5"));

            // ---- 4b. a failed race may go again ----
            bool re = YouTube.Enqueue("r3", file, "race r3", "", "private", "", out msg);
            Ok("4. Enqueue on a failed race is accepted", re, msg);
            Ok("4. ... and it goes", WaitFor(delegate () { return Kind("r3") == "shared"; }, 10000), YouTube.StateJson("r3"));

            // ---- 3b. 404: the session ran out -> from zero ----
            g.GoneOnce = true;
            YouTube.Enqueue("r8", file, "race r8", "", "private", "");
            Ok("3b. a 404 on the session URL starts again from zero and finishes", WaitFor(delegate () { return Kind("r8") == "shared"; }, 10000), YouTube.StateJson("r8"));
            List<PretendGoogle.Up> u8 = UpsFor("race r8");
            Ok("3b. ... in a second session, byte-exact", u8.Count == 2 && PretendGoogle.Hash(u8[u8.Count - 1].Data.ToArray()) == hash, u8.Count + " sessions");

            // ---- 3c. Google keeps less than was sent: resume from Google's byte ----
            g.ShortRangeOnce = true;
            YouTube.Enqueue("r10", file, "race r10", "", "private", "");
            Ok("3c. a Range smaller than the bytes sent: r10 still finishes", WaitFor(delegate () { return Kind("r10") == "shared"; }, 10000), YouTube.StateJson("r10"));
            PretendGoogle.Up u10 = UpFor("race r10");
            Ok("3c. ... the next PUT starts at Google's byte, and the file is byte-exact", u10 != null && Regex.IsMatch(Events(u10), "^put 0-1048575 kept 524288 \\| put 524288-") && PretendGoogle.Hash(u10.Data.ToArray()) == hash, Events(u10));

            // ---- 3d. irdash dies between the last PUT and YouTube's answer ----
            g.DropFinalOnce = true;
            YouTube.Enqueue("r13", file, "race r13", "", "private", "");
            Ok("3d. the final answer lost: */total gets it again and r13 is shared", WaitFor(delegate () { return Kind("r13") == "shared"; }, 10000), YouTube.StateJson("r13"));
            PretendGoogle.Up u13 = UpFor("race r13");
            Ok("3d. ... nothing re-sent, one session, session file gone", u13 != null && u13.PutBytes == size && UpsFor("race r13").Count == 1 && Events(u13).Contains("dropped final answer | query " + size) && !File.Exists(Sess("r13")), Events(u13));

            // ---- 3e. asked public, YouTube says private: the card shows YouTube's word ----
            g.FinalPrivacy = "private";
            YouTube.Enqueue("r11", file, "race r11", "", "public", "");
            Ok("3e. public asked, YouTube answered private -> the card says private", WaitFor(delegate () { return Kind("r11") == "shared"; }, 10000) && YouTube.StateJson("r11").Contains("\"privacy\":\"private\"") && UpFor("race r11").Privacy == "public", YouTube.StateJson("r11"));
            g.FinalPrivacy = null;

            // ---- 2c. one 401 -> a fresh token, the upload carries on ----
            int refreshesBefore = g.Refreshes;
            g.Reject401Once = true;
            YouTube.Enqueue("r12", file, "race r12", "", "private", "");
            Ok("2c. a 401 gets a fresh token and r12 still finishes", WaitFor(delegate () { return Kind("r12") == "shared"; }, 10000) && g.Rejected401 == 1 && g.Refreshes == refreshesBefore + 1, YouTube.StateJson("r12") + ", refreshes +" + (g.Refreshes - refreshesBefore));

            // ---- 2d. a second 401 -> signed out, token gone ----
            g.Revoked = true;
            YouTube.Enqueue("r14", file, "race r14", "", "private", "");
            Ok("2d. a second 401 -> kind signin \"Sign in to YouTube again\"", WaitFor(delegate () { return YouTube.StateJson("r14") == "{\"kind\":\"signin\",\"error\":\"Sign in to YouTube again\"}"; }, 10000), YouTube.StateJson("r14"));
            Ok("2d. ... token.bin is gone, Json says signed out (the page shows the sign-in key)", !File.Exists(tokenFile) && YouTube.Json().Contains("\"signedIn\":false"));
            g.Revoked = false;
            lock (pages) pages.Clear();
            YouTube.SignIn();
            Ok("2d. signing in again sends the waiting race by itself", WaitFor(delegate () { return Kind("r14") == "shared"; }, 15000), YouTube.StateJson("r14"));

            // ---- 2b. invalid_grant: signed out ----
            g.Revoked = true; g.InvalidGrant = true;
            sessionOn = true; Thread.Sleep(1200);      // the job thread sees the session (it looks every 0.5 s), so both races wait together
            YouTube.Enqueue("r6", file, "race r6", "", "private", "");
            YouTube.Enqueue("r7", file, "race r7", "", "private", "");
            sessionOn = false;
            string again2 = "{\"kind\":\"signin\",\"error\":\"Sign in to YouTube again\"}";
            Ok("2. invalid_grant -> every queued race shows signin, \"Sign in to YouTube again\"", WaitFor(delegate () { return YouTube.StateJson("r6") == again2 && YouTube.StateJson("r7") == again2; }, 10000), YouTube.StateJson("r6") + " " + YouTube.StateJson("r7"));
            Ok("2. ... token.bin is gone and Json says signed out", !File.Exists(tokenFile) && YouTube.Json().Contains("\"signedIn\":false"), YouTube.Json());
            Ok("2. ... a shared race stays shared", Kind("r0") == "shared");

            // ---- settings ----
            Ok("settings: privacy public is saved in irdash.ini", YouTube.SetPrivacy("public") && YouTube.Privacy == "public" && File.ReadAllText(YouTube.IniFile).Contains("youtube_privacy=public"));
            Ok("settings: a wrong privacy is refused", !YouTube.SetPrivacy("everyone") && YouTube.Privacy == "public");
            Ok("settings: template 3 is saved, 9 is refused", YouTube.SetTemplate(3) && !YouTube.SetTemplate(9) && YouTube.Template == 3);
            Ok("settings: Json shows them", YouTube.Json().Contains("\"privacy\":\"public\",\"template\":3"), YouTube.Json());

            // ---- 9. nothing secret in the log ----
            log = LogText();
            List<string> secrets = new List<string>(g.Issued);
            secrets.Add(PretendGoogle.Secret); secrets.Add(PretendGoogle.Refresh); secrets.Add(PretendGoogle.Code); secrets.Add("upload_id"); secrets.Add("pretend-upload");
            if (g.Verifier.Length > 0) secrets.Add(g.Verifier);
            int found = 0;
            foreach (string s in secrets) if (log.Contains(s)) found++;
            Ok("9. the log holds no secret, code, token, verifier or session URL", found == 0, found + " found");
            Ok("9. the log says \"youtube: signed in\"", log.Contains("youtube: signed in"));
            Ok("9. the pretend Google saw no protocol error (and no videos.list call)", g.Errors.Count == 0, string.Join(" | ", g.Errors.ToArray()));
        }
    }
}
