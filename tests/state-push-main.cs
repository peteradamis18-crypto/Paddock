// Entry point for tests\state-push-test.ps1 only (W0-5): compiled together with dash\src\*.cs (csc /main:IRDash.StatePushMain) into a
// throw-away exe in %TEMP%. It runs irdash's real Server on a test port (never 8199) over a throw-away www folder, and talks to it over
// real sockets: /state, the stream's "event: state" push and its timing, the static file headers, keep-alive, /version, /deck/summary.
// Nothing here starts the SDK reader, touches iRacing, the deck or the live irdash. Prints "ok ..." / "FAIL ..." lines and "info" lines.
//   state-push.exe <port> <www dir> [<session yaml file>]
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class StatePushMain
    {
        static int pass, fail;
        static int port;
        static void Ok(string what, bool cond, string why) { if (cond) { pass++; Console.WriteLine("  ok   " + what); } else { fail++; Console.WriteLine("  FAIL " + what + (why != null && why.Length > 0 ? "  (" + why + ")" : "")); } }
        static void Info(string s) { Console.WriteLine("  info " + s); }
        static readonly JavaScriptSerializer J = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };

        sealed class Reply { public int Code; public Dictionary<string, string> H = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); public string Body = ""; }

        // one request on an open socket; reads exactly one reply (Content-Length)
        static Reply Ask(NetworkStream s, string target, string extra)
        {
            byte[] req = Encoding.ASCII.GetBytes("GET " + target + " HTTP/1.1\r\nHost: localhost:" + port + "\r\n" + (extra ?? "") + "\r\n");
            s.Write(req, 0, req.Length); s.Flush();
            Reply r = new Reply();
            string head = ReadHead(s); if (head == null) return null;
            string[] lines = head.Split(new[] { "\r\n" }, StringSplitOptions.None);
            r.Code = int.Parse(lines[0].Split(' ')[1]);
            for (int i = 1; i < lines.Length; i++) { int k = lines[i].IndexOf(':'); if (k > 0) r.H[lines[i].Substring(0, k).Trim()] = lines[i].Substring(k + 1).Trim(); }
            string cl; int n = r.H.TryGetValue("Content-Length", out cl) ? int.Parse(cl) : 0;
            byte[] b = new byte[n]; int got = 0; while (got < n) { int m = s.Read(b, got, n - got); if (m <= 0) break; got += m; }
            r.Body = Encoding.UTF8.GetString(b, 0, got);
            return r;
        }
        static string ReadHead(NetworkStream s)
        {
            List<byte> buf = new List<byte>();
            while (buf.Count < 65536)
            {
                int b = s.ReadByte(); if (b < 0) return null; buf.Add((byte)b);
                int n = buf.Count; if (n >= 4 && buf[n - 4] == 13 && buf[n - 3] == 10 && buf[n - 2] == 13 && buf[n - 1] == 10) return Encoding.ASCII.GetString(buf.ToArray(), 0, n - 4);
            }
            return null;
        }
        static Reply Get(string target) { return Get(target, ""); }
        static Reply Get(string target, string extra)
        {
            using (TcpClient c = new TcpClient("127.0.0.1", port)) { c.ReceiveTimeout = 5000; return Ask(c.GetStream(), target, (extra ?? "") + "Connection: close\r\n"); }
        }
        static Dictionary<string, object> Obj(string json) { try { return J.DeserializeObject(json) as Dictionary<string, object>; } catch { return null; } }
        static long Seq(Dictionary<string, object> o) { return o == null ? -1 : Convert.ToInt64(o["seq"], CultureInfo.InvariantCulture); }

        // one SSE event (event name + data) from a stream, or null at the deadline
        static string[] NextEvent(StreamReader rd, Stopwatch sw, long untilMs)
        {
            string ev = "message", data = null;
            while (sw.ElapsedMilliseconds < untilMs)
            {
                string line;
                try { line = rd.ReadLine(); } catch (IOException) { continue; }
                if (line == null) return null;
                if (line.StartsWith("event: ")) ev = line.Substring(7);
                else if (line.StartsWith("data: ")) data = line.Substring(6);
                else if (line.Length == 0 && data != null) return new[] { ev, data };
                else if (line.Length == 0) ev = "message";
            }
            return null;
        }

        static int Main(string[] a)
        {
            port = int.Parse(a[0]);
            string www = a[1];
            string yamlFile = a.Length > 2 ? a[2] : "";
            Log.FilePath = Path.Combine(Path.GetTempPath(), "state-push-test-" + port + ".log");
            Server srv = new Server(port, www, Path.GetTempPath());
            srv.Start();
            // wait for the builder's first full look
            Stopwatch boot = Stopwatch.StartNew();
            while (StateBuilder.Seq < 1 && boot.ElapsedMilliseconds < 8000) Thread.Sleep(50);
            Thread.Sleep(600);

            Console.WriteLine("Section 1. /state has every part");
            Reply st = Get("/state");
            Dictionary<string, object> s0 = st == null ? null : Obj(st.Body);
            Ok("GET /state answers 200 with JSON (" + (st == null ? 0 : st.Body.Length) + " bytes)", st != null && st.Code == 200 && s0 != null, st == null ? "no answer" : st.Body.Substring(0, Math.Min(200, st.Body.Length)));
            string[] want = { "seq", "now", "rig", "version", "kids", "tow", "keymsg", "nav", "vaultNav", "perfNav", "debriefNav", "workbench", "showcase", "guest", "mydrive", "doctor", "overlays", "recorder", "health", "session", "lists" };
            List<string> missing = new List<string>();
            foreach (string k in want) if (s0 == null || !s0.ContainsKey(k)) missing.Add(k);
            Ok("every part is there: " + string.Join(", ", want), missing.Count == 0, "missing: " + string.Join(", ", missing.ToArray()));
            Dictionary<string, object> rig = s0 != null && s0.ContainsKey("rig") ? s0["rig"] as Dictionary<string, object> : null;
            Ok("rig carries driving, sessionOn, simRunning, online", rig != null && rig.ContainsKey("driving") && rig.ContainsKey("sessionOn") && rig.ContainsKey("simRunning") && rig.ContainsKey("online"), J.Serialize(rig));
            Ok("the keymsg part has no ageMs (the page works it out from at and now)", st != null && !st.Body.Contains("\"ageMs\""), "");
            Ok("lists carries sessions, vault, races, perf", s0 != null && s0["lists"] is Dictionary<string, object> && ((Dictionary<string, object>)s0["lists"]).Count == 4, "");

            Console.WriteLine("Section 2. seq moves only when a part changes");
            long q0 = Seq(s0);
            Thread.Sleep(1500);
            long q1 = Seq(Obj(Get("/state").Body));
            Ok("1.5 s with nothing changing: seq stays " + q0 + " (got " + q1 + ")", q1 == q0, "");
            // a part whose only change is a seconds counter: not a change
            int ticks = 0;
            StateBuilder.Add("agetest", 100, 100, delegate () { ticks++; return "{\"ok\":true,\"age\":" + ticks + "}"; });
            StateBuilder.Changed("agetest");
            Thread.Sleep(400);
            long q2 = StateBuilder.Seq;
            Thread.Sleep(800);
            Ok("a part whose only change is \"age\" (made " + ticks + " times) does not move seq after its first look", StateBuilder.Seq == q2 && ticks >= 3, "seq " + q2 + " -> " + StateBuilder.Seq);
            long beforeMsg = StateBuilder.Seq;
            KeyMsg.Set("w05-test", "state push one", "ok");
            Thread.Sleep(400);
            long upTo; string part = StateBuilder.Since(beforeMsg, out upTo);
            Ok("KeyMsg.Set (its Changed line) moves seq once (" + beforeMsg + " -> " + upTo + ")", upTo == beforeMsg + 1, "");
            Dictionary<string, object> po = part == null ? null : Obj(part);
            Ok("that push carries the keymsg part and nothing else", po != null && po.ContainsKey("keymsg") && po.Count == 3, part);

            Console.WriteLine("Section 3. the stream pushes event: state within 300 ms of Changed()");
            using (TcpClient sc = new TcpClient("127.0.0.1", port))
            {
                sc.ReceiveTimeout = 200;
                NetworkStream ns = sc.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("GET /stream?state=1 HTTP/1.1\r\nHost: localhost:" + port + "\r\n\r\n"); ns.Write(req, 0, req.Length);
                StreamReader rd = new StreamReader(ns, Encoding.UTF8);
                Stopwatch sw = Stopwatch.StartNew();
                string status = null; try { status = rd.ReadLine(); } catch { }
                Ok("/stream?state=1 answers 200 text/event-stream", status != null && status.Contains("200"), status);
                string[] first = null;
                while (sw.ElapsedMilliseconds < 3000) { first = NextEvent(rd, sw, 3000); if (first == null || first[0] == "state") break; }
                Dictionary<string, object> fo = first == null ? null : Obj(first[1]);
                Ok("the first event is the whole state (full, every part)", first != null && first[0] == "state" && fo != null && fo.ContainsKey("full") && fo.ContainsKey("guest") && fo.ContainsKey("session"), first == null ? "none" : first[0]);
                long worst = 0; int got = 0;
                for (int i = 0; i < 6; i++)
                {
                    Thread.Sleep(i == 0 ? 300 : 120 + 70 * i);
                    string text = "push " + i;
                    Stopwatch t = Stopwatch.StartNew();
                    KeyMsg.Set("w05-test", text, "ok");
                    long until = sw.ElapsedMilliseconds + 2000; string[] e = null;
                    while ((e = NextEvent(rd, sw, until)) != null) if (e[0] == "state" && e[1].Contains(text)) break;
                    if (e != null) { got++; worst = Math.Max(worst, t.ElapsedMilliseconds); }
                }
                Info("the 6 pushes arrived in at most " + worst + " ms after Changed()");
                Ok("all 6 keymsg changes arrived as event: state, the slowest in " + worst + " ms (<= 300)", got == 6 && worst <= 300, got + " of 6");
                // a burst: 20 changes in 200 ms arrive as at most a few pushes (at most 4 a second), the last one included
                Stopwatch b = Stopwatch.StartNew(); int pushes = 0; bool last = false;
                for (int i = 0; i < 20; i++) { KeyMsg.Set("w05-test", "burst " + i, "ok"); Thread.Sleep(10); }
                string[] be;
                while ((be = NextEvent(rd, sw, sw.ElapsedMilliseconds + 900)) != null) { if (be[0] == "state") { pushes++; if (be[1].Contains("burst 19")) { last = true; break; } } }
                Ok("20 changes in 0.2 s: " + pushes + " pushes (at most 4 a second), the last change included", last && pushes <= 3, "pushes " + pushes + " last " + last);
            }
            using (TcpClient sc = new TcpClient("127.0.0.1", port))
            {
                sc.ReceiveTimeout = 200;
                NetworkStream ns = sc.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("GET /stream?hz=30 HTTP/1.1\r\nHost: localhost:" + port + "\r\n\r\n"); ns.Write(req, 0, req.Length);
                StreamReader rd = new StreamReader(ns, Encoding.UTF8);
                Stopwatch sw = Stopwatch.StartNew(); bool anyState = false; string[] e;
                KeyMsg.Set("w05-test", "old stream", "ok");
                while ((e = NextEvent(rd, sw, 1500)) != null) if (e[0] == "state") anyState = true;
                Ok("a stream without state=1 (today's pages, the phone) gets no state events", !anyState, "");
            }

            Console.WriteLine("Section 4. static files: ?v= kept for good, otherwise no-store; pages name their scripts with ?v=");
            string ver = Get("/version").Body.Trim();
            Ok("/version answers the version (" + ver + ")", ver.Length > 5, ver);
            Reply jsV = Get("/v2/a.js?v=" + ver), js = Get("/v2/a.js"), html = Get("/v2/page.html");
            string cc;
            Ok("a.js?v=<version>: Cache-Control public, max-age=31536000, immutable", jsV != null && jsV.Code == 200 && jsV.H.TryGetValue("Cache-Control", out cc) && cc.Contains("max-age=31536000") && cc.Contains("immutable"), jsV == null ? "" : J.Serialize(jsV.H));
            Ok("a.js without ?v=: no-store", js != null && js.Code == 200 && js.H.TryGetValue("Cache-Control", out cc) && cc == "no-store", js == null ? "" : J.Serialize(js.H));
            Ok("the page itself: no-store", html != null && html.H.TryGetValue("Cache-Control", out cc) && cc == "no-store", "");
            Ok("the page's <script src=\"a.js\"> and <link href=\"s.css\"> are served as ?v=" + ver, html != null && html.Body.Contains("src=\"a.js?v=" + ver + "\"") && html.Body.Contains("href=\"s.css?v=" + ver + "\""), html == null ? "" : html.Body);
            Ok("links that are not local scripts or styles are left alone (https://, an image, one with its own query)", html != null && html.Body.Contains("src=\"https://example.invalid/x.js\"") && html.Body.Contains("src=\"pic.png\"") && html.Body.Contains("src=\"b.js?x=1\""), "");
            Dictionary<string, object> sv = Obj(Get("/state").Body);
            Ok("state.version is the same version", sv != null && Convert.ToString(sv["version"]) == ver, sv == null ? "" : Convert.ToString(sv["version"]));
            // a file changes: the watcher counts again, /version and the state follow (no walk per request)
            Thread.Sleep(1100);
            File.WriteAllText(Path.Combine(www, "v2", "a.js"), "/* changed " + DateTime.Now.Ticks + " */\n");
            Stopwatch vw = Stopwatch.StartNew(); string ver2 = ver;
            while (vw.ElapsedMilliseconds < 4000 && ver2 == ver) { Thread.Sleep(100); ver2 = Get("/version").Body.Trim(); }
            Ok("a changed file gives a new version within 4 s (" + vw.ElapsedMilliseconds + " ms)", ver2 != ver, "");
            Thread.Sleep(1300);
            Dictionary<string, object> sv2 = Obj(Get("/state").Body);
            Ok("and the state carries it", sv2 != null && Convert.ToString(sv2["version"]) == ver2, "");
            // a file copied in with an OLDER time (Copy-Item keeps the source's time) still gives a new version: ?v= scripts are kept for good
            string pv = Get("/version").Body.Trim();
            string old = Path.Combine(www, "v2", "a.js");
            File.WriteAllText(old, "/* an older copy " + DateTime.Now.Ticks + " */\n"); File.SetLastWriteTimeUtc(old, new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc));
            Stopwatch ow = Stopwatch.StartNew(); string ov = pv;
            while (ow.ElapsedMilliseconds < 4000 && ov == pv) { Thread.Sleep(100); ov = Get("/version").Body.Trim(); }
            Ok("a file replaced by one with an OLDER time still gives a new version (" + ow.ElapsedMilliseconds + " ms)", ov != pv, pv);
            // the watcher fails: the version still follows (the 15 s walk), and a new watcher is started
            StateBuilder.WatcherFailedForTest();
            Ok("a failed watcher is dropped (the 15 s walk takes over)", !StateBuilder.Watching, "");
            File.WriteAllText(Path.Combine(www, "v2", "s.css"), "body{color:red}/*" + DateTime.Now.Ticks + "*/");
            Stopwatch fw = Stopwatch.StartNew(); string fv = ov;
            while (fw.ElapsedMilliseconds < 20000 && fv == ov) { Thread.Sleep(250); fv = Get("/version").Body.Trim(); }
            Ok("with no watcher a changed file still gives a new version (" + fw.ElapsedMilliseconds + " ms, at most about 15 s)", fv != ov, "");
            Thread.Sleep(5600);
            Ok("a new watcher is running again 5 s later", StateBuilder.Watching, "");
            ver2 = fv;
            Stopwatch walk = Stopwatch.StartNew(); for (int i = 0; i < 50; i++) Get("/version");
            Info("50 /version requests in " + walk.ElapsedMilliseconds + " ms");

            Console.WriteLine("Section 5. keep-alive: two requests, one connection; a small pool of threads");
            using (TcpClient kc = new TcpClient("127.0.0.1", port))
            {
                kc.ReceiveTimeout = 5000;
                NetworkStream ns = kc.GetStream();
                Reply r1 = Ask(ns, "/state", ""), r2 = Ask(ns, "/version", ""), r3 = Ask(ns, "/v2/a.js?v=" + ver2, "");
                string c1;
                Ok("first request on the connection: 200, Connection: keep-alive", r1 != null && r1.Code == 200 && r1.H.TryGetValue("Connection", out c1) && c1 == "keep-alive", r1 == null ? "" : J.Serialize(r1.H));
                Ok("second and third requests answered on the SAME connection", r2 != null && r2.Code == 200 && r2.Body.Trim() == ver2 && r3 != null && r3.Code == 200, "");
                // HEAD: no keep-alive (a body sent to a HEAD would become the start of the next reply on the connection)
                using (TcpClient hc = new TcpClient("127.0.0.1", port))
                {
                    hc.ReceiveTimeout = 5000; NetworkStream hs = hc.GetStream();
                    byte[] hreq = Encoding.ASCII.GetBytes("HEAD /v2/nope.js HTTP/1.1\r\nHost: localhost:" + port + "\r\n\r\n"); hs.Write(hreq, 0, hreq.Length);
                    string hh = ReadHead(hs);
                    Ok("a HEAD request is answered with Connection: close", hh != null && hh.Contains("Connection: close") && !hh.Contains("keep-alive"), hh);
                }
                Reply r4 = Ask(ns, "/version", "Connection: close\r\n");
                Ok("a request that says Connection: close gets close, and the server closes it", r4 != null && r4.H.TryGetValue("Connection", out c1) && c1 == "close" && ns.Read(new byte[1], 0, 1) == 0, "");
            }
            {
                int ok = 0; List<Thread> ts = new List<Thread>(); object lk = new object();
                Stopwatch pw = Stopwatch.StartNew();
                for (int i = 0; i < 30; i++)
                {
                    Thread t = new Thread(delegate () { Reply r = Get("/state"); if (r != null && r.Code == 200) lock (lk) ok++; });
                    t.Start(); ts.Add(t);
                }
                foreach (Thread t in ts) t.Join(10000);
                Ok("30 requests at once are all answered (" + pw.ElapsedMilliseconds + " ms)", ok == 30, ok + " of 30");
                // idle kept connections never block a new one
                List<TcpClient> idle = new List<TcpClient>();
                for (int i = 0; i < 10; i++) { TcpClient ic = new TcpClient("127.0.0.1", port); ic.ReceiveTimeout = 5000; Ask(ic.GetStream(), "/version", ""); idle.Add(ic); }
                Stopwatch nw = Stopwatch.StartNew(); Reply rn = Get("/state");
                Ok("with 10 idle kept connections a new request is answered at once (" + nw.ElapsedMilliseconds + " ms)", rn != null && rn.Code == 200 && nw.ElapsedMilliseconds < 1000, "");
                foreach (TcpClient ic in idle) ic.Close();
            }

            Console.WriteLine("Section 6. /deck/summary and the parsed session");
            Reply ds = Get("/deck/summary");
            Dictionary<string, object> dso = ds == null ? null : Obj(ds.Body);
            List<string> dmiss = new List<string>();
            foreach (string k in new[] { "seq", "showcase", "overlays", "guest", "mydrive", "doctor", "replay", "races", "workbench", "sound", "ac" }) if (dso == null || !dso.ContainsKey(k)) dmiss.Add(k);
            Ok("/deck/summary has showcase, overlays, guest, mydrive, doctor, replay, races, workbench, sound, ac (" + (ds == null ? 0 : ds.Body.Length) + " bytes)", dmiss.Count == 0, string.Join(",", dmiss.ToArray()));
            Ok("/deck/summary is readable by the add-on (Access-Control-Allow-Origin: *)", ds != null && ds.H.ContainsKey("Access-Control-Allow-Origin"), "");
            Dictionary<string, object> dwb = dso == null ? null : dso["workbench"] as Dictionary<string, object>;
            Dictionary<string, object> swb = Obj(Get("/state").Body);
            swb = swb == null ? null : swb["workbench"] as Dictionary<string, object>;
            Ok("the summary's workbench is what the ANALYSIS key shows (/workbench/state: open), the state's is the deck's command for the page (cmd, seq)",
               dwb != null && dwb.ContainsKey("open") && swb != null && swb.ContainsKey("cmd") && swb.ContainsKey("seq"), J.Serialize(dwb) + " / " + J.Serialize(swb));
            if (yamlFile != "" && File.Exists(yamlFile))
            {
                string yaml = File.ReadAllText(yamlFile, Encoding.GetEncoding(28591));
                Stopwatch pw = Stopwatch.StartNew();
                string sj = StateBuilder.SessionJson(yaml, 7);
                long ms = pw.ElapsedMilliseconds;
                Dictionary<string, object> so = Obj(sj);
                Dictionary<string, object> wi = so == null ? null : so["WeekendInfo"] as Dictionary<string, object>;
                Dictionary<string, object> di = so == null ? null : so["DriverInfo"] as Dictionary<string, object>;
                object[] drivers = di == null ? null : di["Drivers"] as object[];
                Dictionary<string, object> si = so == null ? null : so["SessionInfo"] as Dictionary<string, object>;
                object[] sess = si == null ? null : si["Sessions"] as object[];
                Info("session YAML " + yaml.Length + " chars -> " + sj.Length + " chars of JSON in " + ms + " ms");
                Ok("the parsed session names the track, " + (drivers == null ? 0 : drivers.Length) + " drivers and " + (sess == null ? 0 : sess.Length) + " sessions",
                   wi != null && Convert.ToString(wi["TrackDisplayName"]).Length > 0 && drivers != null && drivers.Length > 1 && sess != null && sess.Length > 0, sj.Substring(0, Math.Min(300, sj.Length)));
                Dictionary<string, object> d0 = drivers == null ? null : drivers[0] as Dictionary<string, object>;
                Ok("a driver row has the fields the page reads (CarIdx, UserName, CarNumber, CarClassID, IRating, LicString)", d0 != null && d0.ContainsKey("CarIdx") && d0.ContainsKey("UserName") && d0.ContainsKey("CarNumber") && d0.ContainsKey("CarClassID") && d0.ContainsKey("IRating") && d0.ContainsKey("LicString"), J.Serialize(d0));
                Ok("the parsed session is smaller than the YAML (" + sj.Length + " < " + yaml.Length + ")", sj.Length < yaml.Length, "");
                Ok("the same YAML gives the same answer (cached by version)", StateBuilder.SessionPart(true, 9, yaml) == StateBuilder.SessionPart(true, 9, yaml) && StateBuilder.SessionPart(false, 9, yaml) == "null", "");
            }
            else Info("no session YAML file given: the parsed-session checks are skipped");

            Console.WriteLine("result: " + pass + " ok, " + fail + " FAIL");
            return fail == 0 ? 0 : 1;
        }
    }
}
