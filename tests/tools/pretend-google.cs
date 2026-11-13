// pretend-google.cs - a stand-in for Google's token and YouTube resumable-upload endpoints (W0-8), default port 8399.
// Test tool only: nothing here ships to Peter. C# 5, built by pretend-google.ps1. Protocol: docs\rework\evidence\14-youtube-pipeline.md section 3.
//
//   POST /token                                   -> {"access_token":"t-<n>","expires_in":3600}   (fault invalid_grant -> 400)
//   POST /upload/youtube/v3/videos?uploadType=resumable   -> 200 + Location: http://localhost:<port>/upload/session/<id>
//   PUT  /upload/session/<id>   Content-Range: bytes a-b/total  -> 308 + Range (more to come) or 200 + the video JSON (last chunk)
//                               Content-Range: bytes */total    -> 308 + Range (or none when nothing arrived), or 200 when complete
//                               a chunk that does not start where the last one ended -> 400, the session is marked broken
//   POST /upload/youtube/v3/thumbnails/set?videoId=x   -> 200 (fault thumb403 -> 403)
//   GET  /__fault?mode=<name>   queue a fault;  /__stats  what arrived;  /__reset  forget everything
// Faults, one shot each (the next time they can apply): drop (half a chunk arrives, then the socket closes; only whole 256 KiB
// blocks of that half are kept, like Google), 500once, 503once, 401once, 404session (the session is gone).
// Sticky until /__reset: uploadLimitExceeded and forbiddenPrivacySetting (when the start asks for anything but private; the
// start with private works), slow (every chunk answers 2 s late), thumb403, invalid_grant.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

static class PretendGoogle
{
    const int Block = 262144;
    static int port = 8399;
    static HttpListener listener;
    static readonly object gate = new object();
    static int tokenN, sessionN;
    static readonly Dictionary<string, Sess> sessions = new Dictionary<string, Sess>();
    static readonly List<string> once = new List<string>();
    static readonly HashSet<string> sticky = new HashSet<string>();
    static readonly List<string> thumbs = new List<string>();
    static int dropped;

    sealed class Chunk { public long From, To, Len; public string Result; }
    sealed class Sess
    {
        public string Id, Snippet = "", Privacy = "", Auth = "", Final = "", Sha = "";
        public long Total; public MemoryStream Data = new MemoryStream();
        public List<Chunk> Chunks = new List<Chunk>();
        public bool Broken, Twice, Done;
    }

    static int Main(string[] args)
    {
        foreach (string a in args) { int p; if (int.TryParse(a, out p)) port = p; }
        if (port == 8199) { Console.Error.WriteLine("refusing port 8199 (the real irdash)"); return 2; }
        listener = new HttpListener();
        listener.Prefixes.Add("http://localhost:" + port + "/");
        listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
        try { listener.Start(); } catch (Exception e) { Console.Error.WriteLine("cannot listen on " + port + ": " + e.Message); return 1; }
        Console.WriteLine("pretend google on http://localhost:" + port + "/");
        while (true)
        {
            HttpListenerContext c;
            try { c = listener.GetContext(); } catch { break; }
            HttpListenerContext cc = c;
            ThreadPool.QueueUserWorkItem(delegate (object o) { try { Handle(cc); } catch { try { cc.Response.Abort(); } catch { } } });
        }
        return 0;
    }

    static void Reply(HttpListenerContext c, int code, string body, params string[] headers)
    {
        byte[] b = Encoding.UTF8.GetBytes(body ?? "");
        c.Response.StatusCode = code; c.Response.ContentType = "application/json; charset=UTF-8";
        for (int i = 0; i + 1 < headers.Length; i += 2) c.Response.AddHeader(headers[i], headers[i + 1]);
        c.Response.ContentLength64 = b.Length;
        if (b.Length > 0) c.Response.OutputStream.Write(b, 0, b.Length);
        c.Response.Close();
    }

    static string Err(int code, string reason, string msg)
    {
        return "{\"error\":{\"code\":" + code + ",\"message\":" + Str(msg) + ",\"errors\":[{\"reason\":" + Str(reason) + ",\"message\":" + Str(msg) + "}]}}";
    }

    // true = a one-shot fault with this name was waiting and is now used up
    static bool Take(string name)
    {
        lock (gate) { int i = once.IndexOf(name); if (i < 0) return false; once.RemoveAt(i); return true; }
    }
    static bool Sticky(string name) { lock (gate) return sticky.Contains(name); }

    static string Body(HttpListenerRequest r)
    {
        if (!r.HasEntityBody) return "";
        using (StreamReader sr = new StreamReader(r.InputStream, Encoding.UTF8)) return sr.ReadToEnd();
    }

    static void Handle(HttpListenerContext c)
    {
        string path = c.Request.Url.AbsolutePath, method = c.Request.HttpMethod;
        if (path == "/__fault")
        {
            string mode = c.Request.QueryString["mode"] ?? "";
            lock (gate)
            {
                if (mode == "drop" || mode == "500once" || mode == "503once" || mode == "401once" || mode == "404session") once.Add(mode);
                else if (mode == "uploadLimitExceeded" || mode == "forbiddenPrivacySetting" || mode == "slow" || mode == "thumb403" || mode == "invalid_grant") sticky.Add(mode);
                else if (mode == "ok") { once.Clear(); sticky.Clear(); }
                else { Reply(c, 400, "{\"error\":\"unknown fault\"}"); return; }
            }
            Reply(c, 200, "{\"fault\":" + Str(mode) + "}"); return;
        }
        if (path == "/__reset")
        {
            lock (gate) { sessions.Clear(); once.Clear(); sticky.Clear(); thumbs.Clear(); tokenN = 0; sessionN = 0; dropped = 0; }
            Reply(c, 200, "{\"ok\":true}"); return;
        }
        if (path == "/__stats") { Reply(c, 200, Stats()); return; }

        if (method == "POST" && path == "/token")
        {
            Body(c.Request);
            if (Sticky("invalid_grant")) { Reply(c, 400, "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}"); return; }
            int n; lock (gate) n = ++tokenN;
            Reply(c, 200, "{\"access_token\":\"t-" + n + "\",\"expires_in\":3600,\"token_type\":\"Bearer\"}"); return;
        }
        if (method == "POST" && path == "/upload/youtube/v3/videos") { StartUpload(c); return; }
        if (method == "POST" && path == "/upload/youtube/v3/thumbnails/set")
        {
            byte[] jpg = ReadAll(c.Request);
            lock (gate) thumbs.Add((c.Request.QueryString["videoId"] ?? "") + ":" + jpg.Length);
            if (Sticky("thumb403")) { Reply(c, 403, Err(403, "forbidden", "The authenticated user cannot upload custom video thumbnails.")); return; }
            Reply(c, 200, "{\"kind\":\"youtube#thumbnailSetResponse\",\"items\":[{\"default\":{\"url\":\"http://localhost/thumb.jpg\"}}]}"); return;
        }
        Match m = Regex.Match(path, "^/upload/session/([A-Za-z0-9]+)$");
        if (method == "PUT" && m.Success) { Chunked(c, m.Groups[1].Value); return; }
        Reply(c, 404, Err(404, "notFound", "no such route " + path));
    }

    static void StartUpload(HttpListenerContext c)
    {
        string body = Body(c.Request);
        if (c.Request.QueryString["uploadType"] != "resumable") { Reply(c, 400, Err(400, "badRequest", "uploadType must be resumable")); return; }
        string auth = c.Request.Headers["Authorization"] ?? "";
        if (!auth.StartsWith("Bearer ", StringComparison.Ordinal)) { Reply(c, 401, Err(401, "authError", "Login Required")); return; }
        if (Sticky("uploadLimitExceeded")) { Reply(c, 400, Err(400, "uploadLimitExceeded", "The user has exceeded the number of videos they may upload.")); return; }
        Match pm = Regex.Match(body, "\"privacyStatus\"\\s*:\\s*\"([a-z]+)\"");
        string privacy = pm.Success ? pm.Groups[1].Value : "public";    // no setting = public, as Google does
        if (Sticky("forbiddenPrivacySetting") && privacy != "private") { Reply(c, 403, Err(403, "forbiddenPrivacySetting", "Forbidden")); return; }
        long total = 0; long.TryParse(c.Request.Headers["X-Upload-Content-Length"] ?? "0", out total);
        Sess s = new Sess(); s.Snippet = body; s.Privacy = privacy; s.Auth = auth; s.Total = total;
        lock (gate) { s.Id = (++sessionN).ToString("D3"); sessions[s.Id] = s; }
        Reply(c, 200, "", "Location", "http://localhost:" + port + "/upload/session/" + s.Id);
    }

    static byte[] ReadAll(HttpListenerRequest r)
    {
        using (MemoryStream ms = new MemoryStream()) { r.InputStream.CopyTo(ms); return ms.ToArray(); }
    }

    static void Chunked(HttpListenerContext c, string id)
    {
        Sess s; lock (gate) sessions.TryGetValue(id, out s);
        if (s == null) { Reply(c, 404, Err(404, "notFound", "Not Found")); return; }
        string cr = c.Request.Headers["Content-Range"] ?? "";
        long len = c.Request.ContentLength64 < 0 ? 0 : c.Request.ContentLength64;
        Match q = Regex.Match(cr, "^bytes \\*/(\\d+|\\*)$"), r = Regex.Match(cr, "^bytes (\\d+)-(\\d+)/(\\d+|\\*)$");

        if (q.Success || (cr == "" && len == 0))
        {
            lock (gate)
            {
                if (q.Success && q.Groups[1].Value != "*") { long t; if (long.TryParse(q.Groups[1].Value, out t) && s.Total == 0) s.Total = t; }
                if (s.Done) { Reply(c, 200, s.Final); return; }
                long got = s.Data.Length;
                if (got == 0) Reply(c, 308, "");
                else Reply(c, 308, "", "Range", "bytes=0-" + (got - 1));
            }
            return;
        }
        // a data chunk: faults first
        if (Take("404session")) { lock (gate) sessions.Remove(id); Reply(c, 404, Err(404, "notFound", "Not Found")); return; }
        if (Take("401once")) { ReadAll(c.Request); Reply(c, 401, Err(401, "authError", "Invalid Credentials")); return; }
        if (Take("500once")) { ReadAll(c.Request); Reply(c, 500, Err(500, "backendError", "Backend Error")); return; }
        if (Take("503once")) { ReadAll(c.Request); Reply(c, 503, Err(503, "backendError", "Service Unavailable")); return; }
        if (Sticky("slow")) Thread.Sleep(2000);

        long a, b, total;
        if (r.Success)
        {
            a = long.Parse(r.Groups[1].Value); b = long.Parse(r.Groups[2].Value);
            total = r.Groups[3].Value == "*" ? 0 : long.Parse(r.Groups[3].Value);
        }
        else if (cr == "") { a = 0; b = len - 1; total = len; }    // the whole file in one request
        else { Reply(c, 400, Err(400, "badRequest", "bad Content-Range " + cr)); return; }
        if (b - a + 1 != len) { ReadAll(c.Request); Reply(c, 400, Err(400, "badRequest", "Content-Range does not match Content-Length")); return; }
        lock (gate) { if (total > 0) s.Total = total; }

        if (Take("drop"))
        {
            // half the chunk arrives, then the line goes dead; only whole 256 KiB blocks of it are kept
            long half = len / 2; byte[] part = new byte[half]; int got = 0;
            while (got < half) { int n = c.Request.InputStream.Read(part, got, (int)(half - got)); if (n <= 0) break; got += n; }
            lock (gate)
            {
                if (a == s.Data.Length)
                {
                    long keep = (got / Block) * Block;
                    if (keep > 0) { s.Data.Write(part, 0, (int)keep); s.Chunks.Add(new Chunk { From = a, To = a + keep - 1, Len = keep, Result = "dropped (kept " + keep + ")" }); }
                    else s.Chunks.Add(new Chunk { From = a, To = b, Len = 0, Result = "dropped (kept 0)" });
                }
                dropped++;
            }
            c.Response.Abort(); return;
        }

        byte[] data = ReadAll(c.Request);
        lock (gate)
        {
            long have = s.Data.Length;
            bool last = s.Total > 0 && b + 1 == s.Total;
            if (a > have) { s.Broken = true; s.Chunks.Add(new Chunk { From = a, To = b, Len = len, Result = "400 gap" }); Reply(c, 400, Err(400, "badRequest", "You cannot upload a noncontinuous block.")); return; }
            if (!last && len % Block != 0) { s.Chunks.Add(new Chunk { From = a, To = b, Len = len, Result = "400 size" }); Reply(c, 400, Err(400, "badRequest", "Chunk size must be a multiple of 256 KiB.")); return; }
            if (a < have) { s.Twice = true; }
            long skip = have - a; if (skip < 0) skip = 0;
            if (skip < data.Length) s.Data.Write(data, (int)skip, (int)(data.Length - skip));
            s.Chunks.Add(new Chunk { From = a, To = b, Len = len, Result = a < have ? "overlap" : "ok" });
            if (s.Total > 0 && s.Data.Length >= s.Total)
            {
                s.Done = true;
                using (SHA256 sha = SHA256.Create()) s.Sha = BitConverter.ToString(sha.ComputeHash(s.Data.ToArray())).Replace("-", "").ToLowerInvariant();
                s.Final = "{\"kind\":\"youtube#video\",\"id\":\"vid" + s.Id + "\",\"status\":{\"uploadStatus\":\"uploaded\",\"privacyStatus\":" + Str(s.Privacy) + "}}";
                Reply(c, 200, s.Final); return;
            }
            Reply(c, 308, "", "Range", "bytes=0-" + (s.Data.Length - 1));
        }
    }

    static string Stats()
    {
        StringBuilder sb = new StringBuilder("{\"tokens\":");
        lock (gate)
        {
            sb.Append(tokenN).Append(",\"dropped\":").Append(dropped).Append(",\"pendingFaults\":[");
            for (int i = 0; i < once.Count; i++) { if (i > 0) sb.Append(','); sb.Append(Str(once[i])); }
            sb.Append("],\"thumbnails\":[");
            for (int i = 0; i < thumbs.Count; i++) { if (i > 0) sb.Append(','); sb.Append(Str(thumbs[i])); }
            sb.Append("],\"sessions\":{");
            bool first = true;
            foreach (KeyValuePair<string, Sess> kv in sessions)
            {
                Sess s = kv.Value;
                if (!first) sb.Append(','); first = false;
                sb.Append(Str(kv.Key)).Append(":{\"bytes\":").Append(s.Data.Length).Append(",\"total\":").Append(s.Total)
                  .Append(",\"done\":").Append(s.Done ? "true" : "false").Append(",\"broken\":").Append(s.Broken ? "true" : "false")
                  .Append(",\"rangeTwice\":").Append(s.Twice ? "true" : "false").Append(",\"privacy\":").Append(Str(s.Privacy))
                  .Append(",\"auth\":").Append(Str(s.Auth)).Append(",\"snippet\":").Append(Str(s.Snippet))
                  .Append(",\"final\":").Append(Str(s.Final)).Append(",\"sha256\":").Append(Str(s.Sha)).Append(",\"chunks\":[");
                for (int i = 0; i < s.Chunks.Count; i++)
                {
                    Chunk ch = s.Chunks[i]; if (i > 0) sb.Append(',');
                    sb.Append("{\"from\":").Append(ch.From).Append(",\"to\":").Append(ch.To).Append(",\"len\":").Append(ch.Len).Append(",\"result\":").Append(Str(ch.Result)).Append('}');
                }
                sb.Append("]}");
            }
            sb.Append("}}");
        }
        return sb.ToString();
    }

    static string Str(string s)
    {
        StringBuilder sb = new StringBuilder("\"");
        foreach (char ch in s ?? "")
        {
            if (ch == '"') sb.Append("\\\""); else if (ch == '\\') sb.Append("\\\\"); else if (ch == '\n') sb.Append("\\n"); else if (ch == '\r') sb.Append("\\r"); else if (ch == '\t') sb.Append("\\t");
            else if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4")); else sb.Append(ch);
        }
        return sb.Append('"').ToString();
    }
}
