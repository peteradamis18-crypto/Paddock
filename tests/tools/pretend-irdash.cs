// pretend-irdash.cs - a stand-in for irdash on another port (default 8299) for page and deck-add-on tests (W0-8).
// Test tool only: nothing here ships to Peter. C# 5 (Windows' own csc), built by pretend-irdash.ps1.
//
//   pretend-irdash.exe [port] [--fixtures <dir>] [--ibt <file>] [--speed 20] [--loop] [--www <dir>]
//
// GET routes   answered from <fixtures>\<route>.json  (slashes -> _, "/sound?peek=1" -> "sound~peek=1.json", "/" -> "_root.json")
// /api/do      answers "ok" and logs the whole request into /__stats ("do" list), so deck tests can check what was sent
// /stream      with --ibt: server-sent events in irdash's exact wire format, played from the .ibt at <speed>x
// /__fault     ?mode=ok|500|slow|hung|down[&route=/x]   500 = error, slow = 5 s late, hung = never answers, down = refuses until ok
// /__stats     per-route counts, requests per second over the last 10 s, the /api/do log;   /__reset clears them
// anything else: a file under --www (so a page can be opened from this server), else 404
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

static class PretendIrdash
{
    static int port = 8299;
    static string fixtures = "", ibtFile = "", www = "";
    static double speed = 20; static bool loop;
    static HttpListener listener;
    static readonly object gate = new object();
    static string globalMode = "ok";
    static readonly Dictionary<string, string> routeMode = new Dictionary<string, string>();
    static readonly Dictionary<string, List<long>> hits = new Dictionary<string, List<long>>();
    static readonly Dictionary<string, long> counts = new Dictionary<string, long>();
    static readonly List<string> doLog = new List<string>();
    static readonly ManualResetEvent release = new ManualResetEvent(false);
    static readonly Stopwatch clock = Stopwatch.StartNew();
    static long streamsOpen, framesSent;

    static int Main(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i]; int p;
            if (a == "--fixtures" && i + 1 < args.Length) fixtures = args[++i];
            else if (a == "--ibt" && i + 1 < args.Length) ibtFile = args[++i];
            else if (a == "--www" && i + 1 < args.Length) www = args[++i];
            else if (a == "--speed" && i + 1 < args.Length) double.TryParse(args[++i], NumberStyles.Float, CultureInfo.InvariantCulture, out speed);
            else if (a == "--loop") loop = true;
            else if (int.TryParse(a, out p)) port = p;
        }
        if (port == 8199) { Console.Error.WriteLine("refusing port 8199 (the real irdash)"); return 2; }
        if (fixtures == "") fixtures = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", "fixtures", "irdash");
        if (!StartListener()) return 1;
        StartControl();
        Console.WriteLine("pretend irdash on http://localhost:" + port + "/  fixtures=" + Path.GetFullPath(fixtures) + (ibtFile != "" ? "  ibt=" + ibtFile + " x" + speed : ""));
        Thread.Sleep(Timeout.Infinite);
        return 0;
    }

    // ---------- listener (down = closed, ok = open again) ----------
    static bool StartListener()
    {
        lock (gate)
        {
            if (listener != null) return true;
            HttpListener l = new HttpListener();
            l.Prefixes.Add("http://localhost:" + port + "/");
            l.Prefixes.Add("http://127.0.0.1:" + port + "/");
            try { l.Start(); }
            catch (Exception e) { Console.Error.WriteLine("cannot listen on " + port + ": " + e.Message); return false; }
            listener = l;
            Thread t = new Thread(delegate () { AcceptLoop(l); });
            t.IsBackground = true; t.Start();
            return true;
        }
    }

    // a second listener on port+1 that only answers /__fault, /__reset and /__stats, so a test can lift "down" (the main listener is closed then)
    static void StartControl()
    {
        try
        {
            HttpListener l = new HttpListener();
            l.Prefixes.Add("http://localhost:" + (port + 1) + "/"); l.Prefixes.Add("http://127.0.0.1:" + (port + 1) + "/");
            l.Start();
            Thread t = new Thread(delegate () { AcceptLoop(l); });
            t.IsBackground = true; t.Start();
        }
        catch (Exception e) { Console.Error.WriteLine("no control port " + (port + 1) + ": " + e.Message); }
    }

    static void StopListener()
    {
        lock (gate)
        {
            if (listener == null) return;
            try { listener.Close(); } catch { }
            listener = null;
        }
    }

    static void AcceptLoop(HttpListener l)
    {
        while (true)
        {
            HttpListenerContext c;
            try { c = l.GetContext(); } catch { return; }
            HttpListenerContext cc = c;
            ThreadPool.QueueUserWorkItem(delegate (object o) { try { Handle(cc); } catch { try { cc.Response.Abort(); } catch { } } });
        }
    }

    // ---------- one request ----------
    static string FixtureKey(string path, string query)
    {
        string k = path.Trim('/').Replace('/', '_');
        if (k == "") k = "_root";
        return query != "" ? k + "~" + query.Replace('/', '_').Replace(':', '_').Replace('*', '_').Replace('"', '_').Replace('<', '_').Replace('>', '_').Replace('|', '_') : k;
    }

    static void Json(HttpListenerContext c, int code, string body)
    {
        byte[] b = Encoding.UTF8.GetBytes(body);
        c.Response.StatusCode = code; c.Response.ContentType = "application/json; charset=utf-8";
        c.Response.AddHeader("Access-Control-Allow-Origin", "*"); c.Response.AddHeader("Cache-Control", "no-store");
        c.Response.ContentLength64 = b.Length; c.Response.OutputStream.Write(b, 0, b.Length); c.Response.Close();
    }

    static string Q(HttpListenerRequest r, string name)
    {
        string v = r.QueryString[name]; return v == null ? "" : v;
    }

    static void Handle(HttpListenerContext c)
    {
        string path = c.Request.Url.AbsolutePath;
        string query = c.Request.Url.Query.TrimStart('?');
        string method = c.Request.HttpMethod;
        bool control = c.Request.LocalEndPoint.Port == port + 1;
        if (control && !path.StartsWith("/__", StringComparison.Ordinal)) { Json(c, 404, "{\"error\":\"control port\"}"); return; }

        if (path == "/__fault")
        {
            string mode = Q(c.Request, "mode"), route = Q(c.Request, "route");
            if (mode != "ok" && mode != "500" && mode != "slow" && mode != "hung" && mode != "down") { Json(c, 400, "{\"error\":\"mode must be ok|500|slow|hung|down\"}"); return; }
            lock (gate)
            {
                if (route != "") { if (mode == "ok") routeMode.Remove(route); else routeMode[route] = mode; }
                else { globalMode = mode; if (mode == "ok") routeMode.Clear(); }
            }
            if (mode == "ok") { release.Set(); Thread.Sleep(50); release.Reset(); StartListener(); }
            Json(c, 200, "{\"mode\":\"" + mode + "\"}");
            if (mode == "down" && route == "") StopListener();
            return;
        }
        if (path == "/__reset")
        {
            lock (gate) { hits.Clear(); counts.Clear(); doLog.Clear(); framesSent = 0; }
            Json(c, 200, "{\"ok\":true}"); return;
        }
        if (path == "/__stats") { Json(c, 200, Stats()); return; }

        string rkey = path;
        lock (gate)
        {
            long now = clock.ElapsedMilliseconds;
            long n; counts.TryGetValue(rkey, out n); counts[rkey] = n + 1;
            List<long> h; if (!hits.TryGetValue(rkey, out h)) { h = new List<long>(); hits[rkey] = h; }
            h.Add(now); while (h.Count > 0 && now - h[0] > 10000) h.RemoveAt(0);
        }
        string fm;
        lock (gate) { if (!routeMode.TryGetValue(path, out fm)) fm = globalMode; }
        if (fm == "500") { Json(c, 500, "{\"error\":\"pretend failure\"}"); return; }
        if (fm == "hung") { release.WaitOne(10 * 60 * 1000); try { c.Response.Abort(); } catch { } return; }
        if (fm == "slow") Thread.Sleep(5000);

        if (path == "/api/do")
        {
            string body = "";
            if (c.Request.HasEntityBody) { using (StreamReader sr = new StreamReader(c.Request.InputStream, Encoding.UTF8)) body = sr.ReadToEnd(); }
            lock (gate) doLog.Add(method + " " + path + (query != "" ? "?" + query : "") + (body != "" ? " " + body : ""));
            byte[] ok = Encoding.ASCII.GetBytes("ok");
            c.Response.StatusCode = 200; c.Response.ContentType = "text/plain"; c.Response.AddHeader("Access-Control-Allow-Origin", "*");
            c.Response.ContentLength64 = ok.Length; c.Response.OutputStream.Write(ok, 0, ok.Length); c.Response.Close();
            return;
        }
        if (path == "/stream") { StreamSse(c); return; }

        if (method == "GET" || method == "POST")
        {
            string file = Path.Combine(fixtures, FixtureKey(path, query) + ".json");
            if (!File.Exists(file)) file = Path.Combine(fixtures, FixtureKey(path, "") + ".json");
            if (File.Exists(file)) { Json(c, 200, File.ReadAllText(file, Encoding.UTF8)); return; }
            string txt = Path.Combine(fixtures, FixtureKey(path, query) + ".txt");
            if (!File.Exists(txt)) txt = Path.Combine(fixtures, FixtureKey(path, "") + ".txt");
            if (File.Exists(txt))
            {
                byte[] tb = File.ReadAllBytes(txt);
                c.Response.StatusCode = 200; c.Response.ContentType = "text/plain; charset=utf-8"; c.Response.AddHeader("Access-Control-Allow-Origin", "*");
                c.Response.ContentLength64 = tb.Length; c.Response.OutputStream.Write(tb, 0, tb.Length); c.Response.Close(); return;
            }
            if (www != "")
            {
                string rel = path.TrimStart('/'); if (rel == "") rel = "index.html";
                string full = Path.GetFullPath(Path.Combine(www, rel.Replace('/', Path.DirectorySeparatorChar)));
                if (full.StartsWith(Path.GetFullPath(www), StringComparison.OrdinalIgnoreCase) && File.Exists(full))
                {
                    byte[] b = File.ReadAllBytes(full);
                    string ext = Path.GetExtension(full).ToLowerInvariant();
                    c.Response.ContentType = ext == ".html" ? "text/html; charset=utf-8" : ext == ".js" ? "text/javascript; charset=utf-8" : ext == ".css" ? "text/css" : ext == ".json" ? "application/json" : ext == ".png" ? "image/png" : ext == ".svg" ? "image/svg+xml" : "application/octet-stream";
                    c.Response.ContentLength64 = b.Length; c.Response.OutputStream.Write(b, 0, b.Length); c.Response.Close();
                    return;
                }
            }
        }
        Json(c, 404, "{\"error\":\"no fixture for " + path + "\"}");
    }

    static string Stats()
    {
        StringBuilder sb = new StringBuilder("{\"routes\":{");
        lock (gate)
        {
            long now = clock.ElapsedMilliseconds; bool first = true; long total = 0;
            foreach (KeyValuePair<string, long> kv in counts)
            {
                List<long> h = hits[kv.Key]; int recent = 0;
                foreach (long t in h) if (now - t <= 10000) recent++;
                if (!first) sb.Append(','); first = false; total += kv.Value;
                sb.Append(Str(kv.Key)).Append(":{\"count\":").Append(kv.Value).Append(",\"rps\":").Append((recent / 10.0).ToString("0.##", CultureInfo.InvariantCulture)).Append('}');
            }
            sb.Append("},\"total\":").Append(total).Append(",\"mode\":").Append(Str(globalMode)).Append(",\"streams\":").Append(streamsOpen).Append(",\"frames\":").Append(framesSent).Append(",\"do\":[");
            for (int i = 0; i < doLog.Count; i++) { if (i > 0) sb.Append(','); sb.Append(Str(doLog[i])); }
            sb.Append("]}");
        }
        return sb.ToString();
    }

    static string Str(string s)
    {
        StringBuilder sb = new StringBuilder("\"");
        foreach (char ch in s)
        {
            if (ch == '"') sb.Append("\\\""); else if (ch == '\\') sb.Append("\\\\"); else if (ch == '\n') sb.Append("\\n"); else if (ch == '\r') sb.Append("\\r"); else if (ch == '\t') sb.Append("\\t");
            else if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4")); else sb.Append(ch);
        }
        return sb.Append('"').ToString();
    }

    // ---------- /stream from an .ibt (same bytes on the wire as irdash's Stream()) ----------
    sealed class Var { public string Name; public int Type, Offset, Count; }

    static void StreamSse(HttpListenerContext c)
    {
        HttpListenerResponse r = c.Response;
        r.StatusCode = 200; r.ContentType = "text/event-stream"; r.SendChunked = true;
        r.AddHeader("Cache-Control", "no-store"); r.AddHeader("Access-Control-Allow-Origin", "*");
        Interlocked.Increment(ref streamsOpen);
        try
        {
            Stream os = r.OutputStream;
            Action<string> w = delegate (string t) { byte[] b = Encoding.UTF8.GetBytes(t); os.Write(b, 0, b.Length); os.Flush(); };
            w("retry: 1000\n\n");
            if (ibtFile == "")
            {
                // no telemetry: what irdash says with the sim off
                w("event: status\ndata: {\"connected\":false}\n\n");
                while (true) { Thread.Sleep(1000); w(": ping\n\n"); }
            }
            string[] names = Q(c.Request, "vars").Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
            int hz; if (!int.TryParse(Q(c.Request, "hz"), out hz)) hz = 30; hz = Math.Max(1, Math.Min(60, hz));
            using (FileStream fs = new FileStream(ibtFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                byte[] h = new byte[144]; fs.Read(h, 0, 144);
                int tick = BitConverter.ToInt32(h, 8), infoLen = BitConverter.ToInt32(h, 16), infoOff = BitConverter.ToInt32(h, 20);
                int numVars = BitConverter.ToInt32(h, 24), varOff = BitConverter.ToInt32(h, 28), bufLen = BitConverter.ToInt32(h, 36), dataOff = BitConverter.ToInt32(h, 52);
                long records = (fs.Length - dataOff) / bufLen;
                byte[] info = new byte[infoLen]; fs.Position = infoOff; fs.Read(info, 0, infoLen);
                int z = Array.IndexOf(info, (byte)0); if (z < 0) z = infoLen;
                string yaml = Encoding.GetEncoding(28591).GetString(info, 0, z);
                byte[] vh = new byte[numVars * 144]; fs.Position = varOff; fs.Read(vh, 0, vh.Length);
                Dictionary<string, Var> vars = new Dictionary<string, Var>();
                for (int i = 0; i < numVars; i++)
                {
                    int b = i * 144; int len = Array.IndexOf(vh, (byte)0, b + 16, 32) - (b + 16); if (len < 0) len = 32;
                    Var v = new Var(); v.Name = Encoding.ASCII.GetString(vh, b + 16, len);
                    v.Type = BitConverter.ToInt32(vh, b); v.Offset = BitConverter.ToInt32(vh, b + 4); v.Count = Math.Max(1, BitConverter.ToInt32(vh, b + 8));
                    vars[v.Name] = v;
                }
                w("event: session\ndata: " + Str(yaml) + "\n\n");
                byte[] rec = new byte[bufLen]; long seq = 0;
                Stopwatch sw = Stopwatch.StartNew(); int interval = 1000 / hz;
                while (true)
                {
                    double ts = sw.Elapsed.TotalSeconds * speed;
                    long idx = (long)(ts * tick);
                    if (idx >= records) { if (loop) { sw.Restart(); continue; } idx = records - 1; }
                    fs.Position = dataOff + idx * bufLen;
                    int got = 0; while (got < bufLen) { int n = fs.Read(rec, got, bufLen - got); if (n <= 0) break; got += n; }
                    StringBuilder sb = new StringBuilder(12000);
                    sb.Append("data: {\"seq\":").Append(++seq).Append(",\"v\":{");
                    bool first = true;
                    foreach (string nm in names)
                    {
                        Var v;
                        if (!vars.TryGetValue(nm, out v))
                        {
                            // iRacing's .ibt has no CarIdx arrays: the car's own channels go in its own slot, the rest stay empty (same as irdash's replay)
                            int di = Array.IndexOf(DerivedName, nm); Var pv;
                            if (di < 0 || !vars.TryGetValue("PlayerCarIdx", out pv)) continue;
                            if (!first) sb.Append(','); first = false;
                            int pidx = (int)Num(pv, rec); double mine = DerivedIdle[di]; Var fv;
                            if (DerivedFrom[di] != "" && vars.TryGetValue(DerivedFrom[di], out fv)) mine = Num(fv, rec);
                            sb.Append('"').Append(nm).Append("\":[");
                            for (int k = 0; k < 64; k++) { if (k > 0) sb.Append(','); sb.Append((k == pidx ? mine : DerivedIdle[di]).ToString("G7", CultureInfo.InvariantCulture)); }
                            sb.Append(']');
                            continue;
                        }
                        if (!first) sb.Append(','); first = false;
                        sb.Append('"').Append(nm).Append("\":");
                        int sz = v.Type <= 1 ? 1 : (v.Type == 5 ? 8 : 4);
                        if (v.Count > 1) { sb.Append('['); for (int k = 0; k < v.Count; k++) { if (k > 0) sb.Append(','); Val(sb, v.Type, rec, v.Offset + k * sz); } sb.Append(']'); }
                        else Val(sb, v.Type, rec, v.Offset);
                    }
                    sb.Append("}}\n\n");
                    w(sb.ToString());
                    Interlocked.Increment(ref framesSent);
                    Thread.Sleep(interval);
                }
            }
        }
        catch { }
        finally { Interlocked.Decrement(ref streamsOpen); try { r.Abort(); } catch { } }
    }

    static readonly string[] DerivedName = { "CarIdxLapDistPct", "CarIdxLap", "CarIdxLapCompleted", "CarIdxPosition", "CarIdxClassPosition", "CarIdxOnPitRoad", "CarIdxTrackSurface", "CarIdxGear", "CarIdxRPM", "CarIdxLastLapTime", "CarIdxBestLapTime", "CarIdxEstTime", "CarIdxF2Time" };
    static readonly string[] DerivedFrom = { "LapDistPct", "Lap", "LapCompleted", "PlayerCarPosition", "PlayerCarClassPosition", "OnPitRoad", "PlayerTrackSurface", "Gear", "RPM", "LapLastLapTime", "LapBestLapTime", "", "" };
    static readonly double[] DerivedIdle = { -1, -1, -1, 0, 0, 0, -1, 0, 0, 0, 0, 0, 0 };

    static double Num(Var v, byte[] d)
    {
        switch (v.Type)
        {
            case 0: case 1: return d[v.Offset];
            case 2: return BitConverter.ToInt32(d, v.Offset);
            case 3: return BitConverter.ToUInt32(d, v.Offset);
            case 4: return BitConverter.ToSingle(d, v.Offset);
            default: return BitConverter.ToDouble(d, v.Offset);
        }
    }

    // the same number formats as irdash's Sdk.Val
    static void Val(StringBuilder sb, int type, byte[] data, int p)
    {
        int sz = type <= 1 ? 1 : (type == 5 ? 8 : 4);
        if (p < 0 || p + sz > data.Length) { sb.Append("null"); return; }
        switch (type)
        {
            case 0: sb.Append(data[p]); break;
            case 1: sb.Append(data[p] != 0 ? '1' : '0'); break;
            case 2: sb.Append(BitConverter.ToInt32(data, p)); break;
            case 3: sb.Append(BitConverter.ToUInt32(data, p)); break;
            case 4: { float f = BitConverter.ToSingle(data, p); if (float.IsNaN(f) || float.IsInfinity(f)) sb.Append("null"); else sb.Append(f.ToString("G7", CultureInfo.InvariantCulture)); break; }
            case 5: { double x = BitConverter.ToDouble(data, p); if (double.IsNaN(x) || double.IsInfinity(x)) sb.Append("null"); else sb.Append(x.ToString("G15", CultureInfo.InvariantCulture)); break; }
            default: sb.Append("null"); break;
        }
    }
}


