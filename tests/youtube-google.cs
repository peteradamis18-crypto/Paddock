// A pretend Google for tests\youtube-test.ps1 only (W1-2): an HttpListener on a free 127.0.0.1 port that plays the sign-in page,
// the token endpoint, the resumable videos upload, the read-back and thumbnails/set, with fault flags. Every value is made up.
// Nothing here talks to the real Google.
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
    sealed class PretendGoogle
    {
        public const string ClientId = "pretend-client-id.apps.example";
        public const string Secret = "pretend-client-secret-Q7xZ";
        public const string Code = "pretend-auth-code-K2pW";
        public const string Refresh = "pretend-refresh-token-M9vB";

        public sealed class Up
        {
            public string Id, Title = "", Privacy = "", Meta = ""; public long Total; public MemoryStream Data = new MemoryStream();
            public int Chunks; public List<string> Events = new List<string>(); public long PutBytes;
        }

        public int Port; public string Base;
        HttpListener l; Thread loop; volatile bool run;
        readonly object gate = new object();

        // what was seen
        public string Challenge = "", ChallengeMethod = "", AuthQuery = "", Verifier = "";
        public bool PkceOk, SecretInBody, SecretInQuery, RedirectOk;
        public int Refreshes, AuthCodeExchanges;
        public List<string> Issued = new List<string>();     // every access token handed out
        public string CurrentAccess = "";
        public string FirstPostToken = "";
        public Dictionary<string, Up> Ups = new Dictionary<string, Up>();
        public List<string> Errors = new List<string>();
        public int ThumbsSet, ThumbsRefused;

        // fault flags
        public int FirstExpiresIn = 30, ExpiresIn = 3600;    // the first token is about to run out: Paddock must refresh it before the upload
        public bool InvalidGrant, Revoked, QuotaOnce, CutOnce, GoneOnce, ThumbForbiddenOnce;
        public string ReadbackPrivacy = "private";
        public Action<Up> AfterChunk;                        // runs after a chunk's 308 has been sent
        public volatile bool StopAfterThis;

        public void Start()
        {
            if (Port == 0) { TcpListener t = new TcpListener(IPAddress.Loopback, 0); t.Start(); Port = ((IPEndPoint)t.LocalEndpoint).Port; t.Stop(); }
            Base = "http://127.0.0.1:" + Port;
            l = new HttpListener(); l.Prefixes.Add(Base + "/"); l.Start(); run = true;
            loop = new Thread(Loop); loop.IsBackground = true; loop.Start();
        }

        public void Stop()
        {
            run = false;
            try { l.Stop(); } catch { } try { l.Close(); } catch { }
        }

        void Loop()
        {
            HttpListener me = l;
            while (run)
            {
                HttpListenerContext c;
                try { c = me.GetContext(); } catch { return; }
                try { Handle(c); } catch (Exception ex) { lock (gate) Errors.Add("handler: " + ex.Message); try { c.Response.Abort(); } catch { } }
                if (StopAfterThis) { StopAfterThis = false; Stop(); return; }
            }
        }

        static void Reply(HttpListenerContext c, int status, string body, string ctype)
        {
            byte[] b = Encoding.UTF8.GetBytes(body ?? "");
            c.Response.StatusCode = status; c.Response.ContentType = ctype ?? "application/json";
            c.Response.ContentLength64 = b.Length; c.Response.OutputStream.Write(b, 0, b.Length); c.Response.Close();
        }

        static string ReadAll(HttpListenerContext c) { using (StreamReader r = new StreamReader(c.Request.InputStream, Encoding.UTF8)) return r.ReadToEnd(); }
        static string B64Url(byte[] b) { return Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }

        bool AuthOk(HttpListenerContext c)
        {
            string h = c.Request.Headers["Authorization"] ?? "";
            return !Revoked && CurrentAccess.Length > 0 && h == "Bearer " + CurrentAccess;
        }

        string NewToken(int expires)
        {
            string a = "pretend-access-" + (Issued.Count + 1) + "-Hx4";
            Issued.Add(a); CurrentAccess = a;
            return "{\"access_token\":\"" + a + "\",\"expires_in\":" + expires + ",\"token_type\":\"Bearer\",\"scope\":\"https://www.googleapis.com/auth/youtube.upload\"";
        }

        void Handle(HttpListenerContext c)
        {
            string path = c.Request.Url.AbsolutePath, m = c.Request.HttpMethod;
            System.Collections.Specialized.NameValueCollection q = c.Request.QueryString;
            if (path == "/o/oauth2/v2/auth")
            {
                lock (gate) { AuthQuery = c.Request.Url.Query; Challenge = q["code_challenge"] ?? ""; ChallengeMethod = q["code_challenge_method"] ?? ""; }
                if (AuthQuery.Contains(Secret)) SecretInQuery = true;
                string redirect = q["redirect_uri"] ?? "";
                RedirectOk = Regex.IsMatch(redirect, "^http://(127\\.0\\.0\\.1|localhost):\\d+$") && q["client_id"] == ClientId && q["response_type"] == "code" &&
                             q["scope"] == "https://www.googleapis.com/auth/youtube.upload" && q["access_type"] == "offline" && q["prompt"] == "consent";
                c.Response.StatusCode = 302;
                c.Response.RedirectLocation = redirect + "/?state=" + Uri.EscapeDataString(q["state"] ?? "") + "&code=" + Code + "&scope=x";
                c.Response.Close();
                return;
            }
            if (path == "/token" && m == "POST")
            {
                if (c.Request.Url.Query.Contains(Secret)) SecretInQuery = true;
                string body = ReadAll(c);
                Dictionary<string, string> f = new Dictionary<string, string>();
                foreach (string kv in body.Split('&')) { int e = kv.IndexOf('='); if (e > 0) f[Uri.UnescapeDataString(kv.Substring(0, e))] = Uri.UnescapeDataString(kv.Substring(e + 1).Replace('+', ' ')); }
                string v;
                if (f.TryGetValue("client_secret", out v) && v == Secret) SecretInBody = true;
                if (!f.TryGetValue("client_id", out v) || v != ClientId) { Reply(c, 401, "{\"error\":\"invalid_client\"}", null); return; }
                string g; f.TryGetValue("grant_type", out g);
                if (g == "authorization_code")
                {
                    AuthCodeExchanges++;
                    string ver; f.TryGetValue("code_verifier", out ver); Verifier = ver ?? "";
                    using (SHA256 sha = SHA256.Create()) PkceOk = ChallengeMethod == "S256" && Challenge.Length > 0 && B64Url(sha.ComputeHash(Encoding.ASCII.GetBytes(Verifier))) == Challenge;
                    string code; f.TryGetValue("code", out code);
                    if (!PkceOk || code != Code) { Reply(c, 400, "{\"error\":\"invalid_grant\"}", null); return; }
                    lock (gate) Reply(c, 200, NewToken(FirstExpiresIn) + ",\"refresh_token\":\"" + Refresh + "\"}", null);
                    return;
                }
                if (g == "refresh_token")
                {
                    string rt; f.TryGetValue("refresh_token", out rt);
                    if (InvalidGrant || rt != Refresh) { Reply(c, 400, "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}", null); return; }
                    lock (gate) { Refreshes++; Reply(c, 200, NewToken(ExpiresIn) + "}", null); }
                    return;
                }
                Reply(c, 400, "{\"error\":\"unsupported_grant_type\"}", null); return;
            }
            if (path == "/upload/youtube/v3/videos" && m == "POST")
            {
                if (!AuthOk(c)) { Reply(c, 401, "{\"error\":{\"code\":401,\"errors\":[{\"reason\":\"authError\"}]}}", null); return; }
                if (FirstPostToken.Length == 0) FirstPostToken = CurrentAccess;
                if (QuotaOnce) { QuotaOnce = false; Reply(c, 403, "{\"error\":{\"code\":403,\"errors\":[{\"domain\":\"youtube.quota\",\"reason\":\"quotaExceeded\"}]}}", null); return; }
                string meta = ReadAll(c);
                long total; long.TryParse(c.Request.Headers["X-Upload-Content-Length"] ?? "", out total);
                bool okq = q["uploadType"] == "resumable" && q["part"] == "snippet,status" && c.Request.Headers["X-Upload-Content-Type"] == "video/mp4";
                bool okm = meta.Contains("\"categoryId\":\"20\"") && meta.Contains("\"selfDeclaredMadeForKids\":false") && meta.Contains("\"privacyStatus\":");
                if (!okq || !okm || total <= 0) { lock (gate) Errors.Add("bad upload start: " + c.Request.Url.Query + " " + meta); Reply(c, 400, "{\"error\":{\"errors\":[{\"reason\":\"badRequest\"}]}}", null); return; }
                Up u = new Up(); u.Total = total; u.Meta = meta;
                Match t = Regex.Match(meta, "\"title\":\"([^\"]*)\""); u.Title = t.Success ? t.Groups[1].Value : "";
                Match p = Regex.Match(meta, "\"privacyStatus\":\"([^\"]*)\""); u.Privacy = p.Success ? p.Groups[1].Value : "";
                lock (gate) { u.Id = "s" + (Ups.Count + 1); Ups[u.Id] = u; }
                c.Response.StatusCode = 200; c.Response.AddHeader("Location", Base + "/upload/session/" + u.Id + "?upload_id=pretend-upload-" + u.Id);
                c.Response.ContentLength64 = 0; c.Response.Close();
                return;
            }
            if (path.StartsWith("/upload/session/") && m == "PUT")
            {
                Up u; lock (gate) Ups.TryGetValue(path.Substring("/upload/session/".Length), out u);
                if (u == null) { Reply(c, 404, "{}", null); return; }
                if (!AuthOk(c)) { Reply(c, 401, "{\"error\":{\"code\":401}}", null); return; }
                if (GoneOnce) { GoneOnce = false; lock (gate) u.Events.Add("gone"); Ups.Remove(u.Id); Reply(c, 404, "{}", null); return; }
                string cr = c.Request.Headers["Content-Range"] ?? "";
                Match all = Regex.Match(cr, "^bytes \\*/(\\d+)$"), part = Regex.Match(cr, "^bytes (\\d+)-(\\d+)/(\\d+)$");
                if (all.Success)
                {
                    lock (gate) u.Events.Add("query " + u.Data.Length);
                    if (u.Data.Length >= u.Total) { Done(c, u); return; }
                    Resume(c, u); return;
                }
                if (!part.Success) { lock (gate) Errors.Add("bad Content-Range: " + cr); Reply(c, 400, "{}", null); return; }
                long a = long.Parse(part.Groups[1].Value), b = long.Parse(part.Groups[2].Value), n = long.Parse(part.Groups[3].Value);
                if (n != u.Total || a != u.Data.Length || b < a) { lock (gate) Errors.Add("noncontinuous or wrong total: " + cr + " have " + u.Data.Length); Reply(c, 400, "{}", null); return; }
                long len = b - a + 1;
                long cutAt = -1;
                if (CutOnce && a < u.Total * 4 / 10 && b >= u.Total * 4 / 10) { CutOnce = false; cutAt = u.Total * 4 / 10; }
                Stream s = c.Request.InputStream; byte[] buf = new byte[65536]; long read = 0;
                long want = cutAt >= 0 ? cutAt - a : len;
                while (read < want) { int k = s.Read(buf, 0, (int)Math.Min(buf.Length, want - read)); if (k <= 0) break; u.Data.Write(buf, 0, k); read += k; }
                lock (gate) u.PutBytes += read;
                if (cutAt >= 0) { lock (gate) u.Events.Add("cut " + u.Data.Length); c.Response.Abort(); return; }    // the link drops at 40 %
                lock (gate) { u.Chunks++; u.Events.Add("put " + a + "-" + b); }
                if (u.Data.Length >= u.Total) { Done(c, u); return; }
                Resume(c, u);
                if (AfterChunk != null) AfterChunk(u);
                return;
            }
            if (path == "/youtube/v3/videos" && m == "GET")
            {
                if (!AuthOk(c)) { Reply(c, 401, "{}", null); return; }
                string id = q["id"] ?? "";
                if (q["part"] != "status") { Reply(c, 400, "{}", null); return; }
                Reply(c, 200, "{\"items\":[{\"id\":\"" + id + "\",\"status\":{\"uploadStatus\":\"uploaded\",\"privacyStatus\":\"" + ReadbackPrivacy + "\"}}]}", null);
                return;
            }
            if (path == "/upload/youtube/v3/thumbnails/set" && m == "POST")
            {
                if (!AuthOk(c)) { Reply(c, 401, "{}", null); return; }
                ReadAll(c);
                if (ThumbForbiddenOnce) { ThumbForbiddenOnce = false; ThumbsRefused++; Reply(c, 403, "{\"error\":{\"code\":403,\"errors\":[{\"reason\":\"forbidden\"}]}}", null); return; }
                ThumbsSet++; Reply(c, 200, "{\"items\":[{}]}", null); return;
            }
            Reply(c, 404, "{}", null);
        }

        void Resume(HttpListenerContext c, Up u)
        {
            c.Response.StatusCode = 308;
            if (u.Data.Length > 0) c.Response.AddHeader("Range", "bytes=0-" + (u.Data.Length - 1));
            c.Response.ContentLength64 = 0; c.Response.Close();
        }

        void Done(HttpListenerContext c, Up u)
        {
            Reply(c, 201, "{\"kind\":\"youtube#video\",\"id\":\"vid-" + u.Id + "\",\"snippet\":{\"title\":\"" + u.Title + "\"},\"status\":{\"uploadStatus\":\"uploaded\",\"privacyStatus\":\"" + u.Privacy + "\"}}", null);
        }

        public static string Hash(byte[] b) { using (SHA256 s = SHA256.Create()) return Convert.ToBase64String(s.ComputeHash(b)); }
    }
}
