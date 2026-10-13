// Paddock car pictures (CP-1): iRacing's OWN official pictures of its cars, nothing drawn.
//   GET /cars/<key>.jpg        the picture (paddock\cars\<key>.jpg), cached by the browser; 404 when there is none (the page then shows no picture).
//   GET /cars/manifest.json    {"keys":[...]}  every picture that is on disk now (the pages read it once and show only those)
//   GET /cars/need?path=<CarPath>   the page asks for a car it has no picture for: if iRacing's image server has one and NO session is on,
//                              it is fetched in the background (one file at a time, throttled) and kept for good. {"key","have","queued","why"}
//   GET /cars/status           counters for the tests and the log
// key = the car's iRacing CarPath in lower case with every run of other characters turned into "_" ("mx5 mx52016" -> "mx5_mx52016").
// Where the pictures come from: https://images-static.iracing.com/img/cars/<folder>/<name>-small.jpg (the small picture iRacing's own UI shows;
// 480 x 270). paddock\cars\catalog.json says which CarPath has which file (made by tools\cars-build.ps1; the list of file names comes from the
// Internet Archive, iRacing's /data/car/assets is closed to new apps). A car that is not in the catalog has NO picture: the page shows clean text.
// Never fetches while a session is on (Sdk.RealBusy: sim running, connected, START pressed; and a pretend session of the test hook).
// Test hook (/api/test/cars, only while dash\test-hook.on exists): sandbox=1 reads and writes paddock\cars-test instead and then also
// accepts catalog URLs on this PC (http://localhost:<port>/), so the test never touches the internet or the real folder.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class Cars
    {
        static readonly object gate = new object();
        static string realDir = "", dir = "";
        static bool sandbox;
        static readonly Dictionary<string, string> catalog = new Dictionary<string, string>();   // key -> url
        static readonly HashSet<string> tried = new HashSet<string>();                           // asked for in this run (a failure is not retried until irdash restarts)
        static readonly Queue<string> queue = new Queue<string>();
        static Thread worker;
        static int fetched, refused, failed;
        static string lastWhy = "";
        static DateTime catalogAt = DateTime.MinValue;

        public static void Init(string root)
        {
            realDir = Path.Combine(root, @"paddock\cars"); dir = realDir; sandbox = false;
            try { Directory.CreateDirectory(realDir); } catch { }
            LoadCatalog();
        }

        public static string Key(string carPath)
        {
            string k = Regex.Replace((carPath ?? "").ToLowerInvariant(), "[^a-z0-9]+", "_").Trim('_');
            return k.Length > 80 ? k.Substring(0, 80) : k;
        }

        static void LoadCatalog()
        {
            lock (gate)
            {
                catalog.Clear(); catalogAt = DateTime.UtcNow;
                try
                {
                    string f = Path.Combine(dir, "catalog.json");
                    if (!File.Exists(f)) return;
                    foreach (Match m in Regex.Matches(File.ReadAllText(f), "\"key\":\"([a-z0-9_]+)\"[^}]*?\"url\":\"([^\"]+)\""))
                        catalog[m.Groups[1].Value] = m.Groups[2].Value;
                }
                catch (Exception ex) { Log.W("cars: catalog: " + ex.Message); }
            }
        }

        // why no picture may be fetched right now (null = it may)
        static string Busy()
        {
            string b = Sdk.RealBusy();
            if (b != null) return b;
            if (Sdk.Pretend) return "a session is on";
            return null;
        }

        static string[] Have()
        {
            List<string> keys = new List<string>();
            try { foreach (string f in Directory.GetFiles(dir, "*.jpg")) keys.Add(Path.GetFileNameWithoutExtension(f)); } catch { }
            keys.Sort(StringComparer.Ordinal);
            return keys.ToArray();
        }

        static bool UrlOk(string url)
        {
            if (Regex.IsMatch(url, @"^https://images-static\.iracing\.com/img/cars/[A-Za-z0-9_./-]+\.jpg$") && !url.Contains("..")) return true;
            return sandbox && Regex.IsMatch(url, @"^http://(localhost|127\.0\.0\.1):[0-9]{2,5}/cars/[a-z0-9_]+\.jpg$");
        }

        // ---- the HTTP routes (called from irdash.cs); false = not ours ----
        public static bool TryHandle(string path, Dictionary<string, string> q, out int code, out string type, out byte[] body, out bool cache)
        {
            code = 200; type = "application/json; charset=utf-8"; body = null; cache = false;
            if (!path.StartsWith("/cars/", StringComparison.Ordinal) && path != "/api/test/cars") return false;
            if (path == "/cars/manifest.json")
            {
                string[] h = Have(); StringBuilder sb = new StringBuilder("{\"keys\":[");
                for (int i = 0; i < h.Length; i++) { if (i > 0) sb.Append(','); sb.Append(Json_.S(h[i])); }
                body = Encoding.UTF8.GetBytes(sb.Append("]}").ToString()); return true;
            }
            if (path == "/cars/status") { body = Encoding.UTF8.GetBytes(StatusJson()); return true; }
            if (path == "/cars/need")
            {
                string cp; q.TryGetValue("path", out cp);
                body = Encoding.UTF8.GetBytes(Need(cp ?? "")); return true;
            }
            if (path == "/api/test/cars")
            {
                if (!Sdk.TestHook) { code = 404; type = "text/plain"; body = Encoding.ASCII.GetBytes("not found"); return true; }
                string sb2; q.TryGetValue("sandbox", out sb2);
                lock (gate)
                {
                    bool on = sb2 == "1";
                    if (on != sandbox)
                    {
                        sandbox = on; dir = on ? Path.Combine(Path.GetDirectoryName(realDir), "cars-test") : realDir;
                        queue.Clear(); tried.Clear(); fetched = refused = failed = 0; lastWhy = "";
                        try { if (on) Directory.CreateDirectory(dir); } catch { }
                    }
                }
                LoadCatalog();
                body = Encoding.UTF8.GetBytes(StatusJson()); return true;
            }
            Match m = Regex.Match(path, "^/cars/([a-z0-9_]{1,80})\\.jpg$");
            if (!m.Success) { code = 404; type = "text/plain"; body = Encoding.ASCII.GetBytes("not found"); return true; }
            string file = Path.Combine(dir, m.Groups[1].Value + ".jpg");
            if (!File.Exists(file)) { code = 404; type = "text/plain"; body = Encoding.ASCII.GetBytes("no picture"); return true; }
            try { body = File.ReadAllBytes(file); } catch { code = 404; type = "text/plain"; body = Encoding.ASCII.GetBytes("no picture"); return true; }
            type = "image/jpeg"; cache = true; return true;
        }

        static string StatusJson()
        {
            lock (gate)
                return "{\"sandbox\":" + (sandbox ? "true" : "false") + ",\"have\":" + Have().Length + ",\"catalog\":" + catalog.Count + ",\"queued\":" + queue.Count +
                       ",\"fetched\":" + fetched + ",\"refused\":" + refused + ",\"failed\":" + failed + ",\"busy\":" + Json_.S(Busy() ?? "") + ",\"why\":" + Json_.S(lastWhy) + "}";
        }

        static string Need(string carPath)
        {
            string key = Key(carPath);
            if (key.Length == 0) return "{\"key\":\"\",\"have\":false,\"queued\":false,\"why\":\"no car path\"}";
            if (File.Exists(Path.Combine(dir, key + ".jpg"))) return "{\"key\":" + Json_.S(key) + ",\"have\":true,\"queued\":false,\"why\":\"\"}";
            string url, why = "";
            bool queued = false;
            lock (gate)
            {
                if ((DateTime.UtcNow - catalogAt).TotalMinutes > 10 || catalog.Count == 0) LoadCatalog();
                if (!catalog.TryGetValue(key, out url)) why = "iRacing has no picture for this car on its image server list";
                else if (tried.Contains(key)) why = "already tried";
                else
                {
                    string busy = Busy();
                    if (busy != null) { refused++; why = "not now: " + busy; lastWhy = why; Log.W("cars: " + key + " waits - " + busy); }
                    else
                    {
                        tried.Add(key); queue.Enqueue(key); queued = true;
                        if (worker == null || !worker.IsAlive) { worker = new Thread(Work); worker.IsBackground = true; worker.Priority = ThreadPriority.BelowNormal; worker.Start(); }
                    }
                }
            }
            return "{\"key\":" + Json_.S(key) + ",\"have\":false,\"queued\":" + (queued ? "true" : "false") + ",\"why\":" + Json_.S(why) + "}";
        }

        // one file at a time, 1.5 s apart, about 500 KB/s at most; stops the moment a session starts
        static void Work()
        {
            while (true)
            {
                string key, url, myDir;
                lock (gate)
                {
                    if (queue.Count == 0) { worker = null; return; }
                    key = queue.Dequeue(); myDir = dir;
                    if (!catalog.TryGetValue(key, out url)) continue;
                    string busy = Busy();
                    if (busy != null) { refused++; lastWhy = "not now: " + busy; queue.Clear(); worker = null; Log.W("cars: fetch stopped - " + busy); return; }
                }
                try { Fetch(key, url, myDir); lock (gate) fetched++; }
                catch (Exception ex) { lock (gate) { failed++; lastWhy = key + ": " + ex.Message; } Log.W("cars: " + key + ": " + ex.Message); }
                Thread.Sleep(1500);
            }
        }

        static void Fetch(string key, string url, string toDir)
        {
            if (!UrlOk(url)) throw new Exception("address not allowed");
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;     // TLS 1.2
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
            rq.UserAgent = "Paddock/1.0 (a private sim rig; one picture per car, kept)"; rq.Timeout = 20000; rq.ReadWriteTimeout = 20000;
            byte[] data;
            using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse())
            using (Stream st = rs.GetResponseStream())
            using (MemoryStream ms = new MemoryStream())
            {
                byte[] buf = new byte[16384]; int n;
                while ((n = st.Read(buf, 0, buf.Length)) > 0) { ms.Write(buf, 0, n); if (ms.Length > 3000000) throw new Exception("too big"); Thread.Sleep(30); }
                data = ms.ToArray();
            }
            if (data.Length < 8000 || data[0] != 0xFF || data[1] != 0xD8) throw new Exception("not a picture (" + data.Length + " bytes)");
            Directory.CreateDirectory(toDir);
            string f = Path.Combine(toDir, key + ".jpg"), tmp = f + ".tmp";
            File.WriteAllBytes(tmp, data);
            if (File.Exists(f)) File.Delete(f);
            File.Move(tmp, f);
            try { File.AppendAllText(Path.Combine(toDir, "fetched.txt"), DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) + "\t" + key + "\t" + url + "\t" + data.Length + "\r\n"); } catch { }
            Log.W("cars: fetched " + key + " (" + data.Length + " bytes) from " + url);
        }
    }
}
