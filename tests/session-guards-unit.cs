// tests\session-guards-test.ps1 compiles dash\src\rigstate.cs with this file.
//   session-guards-unit.exe unit                     the rules: session guards, the phone's lists, the X-Paddock header rule, the preflight
//   session-guards-unit.exe serve <dir> <sec> <log>  a pretend irdash on 8299 (and a "foreign" site on 8298) that answers /api/do and
//                                                    OPTIONS with the SAME Gate functions irdash uses, for a real browser to try
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace IRDash
{
    static class Log { public static readonly List<string> Lines = new List<string>(); public static void W(string m) { lock (Lines) Lines.Add(m); } }

    static class GuardsUnit
    {
        static int pass, fail;
        static void Check(string what, bool ok) { if (ok) { pass++; Console.WriteLine("  ok    " + what); } else { fail++; Console.WriteLine("  FAIL  " + what); } }
        static Dictionary<string, string> D(params string[] kv) { var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); for (int i = 0; i + 1 < kv.Length; i += 2) d[kv[i]] = kv[i + 1]; return d; }

        // what irdash's /api/do does with a command: the guard first, then (here) a stub that "runs" it
        static string ApiDo(string c, string a, bool phone, List<string> ran)
        {
            string g = Gate.GuardDo(c, a);
            if (g == null && phone && RigState.SessionOn && !Gate.PhoneMayWhileSession(c, a)) g = RigState.Refuse("phone " + c);
            if (g != null) return "409 " + g;
            ran.Add(c + (a == null ? "" : " " + a));
            return "200 ok";
        }
        static string Route(string path, Dictionary<string, string> q, List<string> ran)
        {
            string g = Gate.GuardRoute(path, q);
            if (g != null) return "409 " + g;
            ran.Add(path); return "200";
        }

        static bool simUp;
        static int Unit()
        {
            RigState.SimProbe = delegate { return simUp; };
            RigState.MarkFile = Path.Combine(Path.GetTempPath(), "no-such-start-mark-" + Guid.NewGuid().ToString("N") + ".txt");
            List<string> ran = new List<string>();
            string[][] guardedDo = { new[] { "mdfindcar", "CUP" }, new[] { "mdfindtrack", "LIME" }, new[] { "mdfindlayout", "" }, new[] { "mdstart", "" },
                                     new[] { "ailevel", "start" }, new[] { "ovapply", "" }, new[] { "ovedit", "" }, new[] { "racedelete", "r1" }, new[] { "vkdelete", "m1" } };
            string[][] guardedRoutes = { new[] { "/api/rec/backfill", "" }, new[] { "/api/rec/delete", "" }, new[] { "/vault/delete", "" }, new[] { "/vault/edit", "star" },
                                         new[] { "/analysis/pro/save", "" }, new[] { "/analysis/pro/delete", "" } };

            Console.WriteLine("1. a session is on (the test hook's pretend session: SDK connected, no sim program)");
            simUp = false; RigState.Probe(); RigState.Feed(true, false, true);
            Check("RigState says a session is on (in the garage, not on track)", RigState.SessionOn && !RigState.Driving);
            foreach (string[] g in guardedDo)
            {
                string r = ApiDo(g[0], g[1], false, ran);
                Check("/api/do?c=" + g[0] + (g[1].Length > 0 ? "&a=" + g[1] : "") + " -> 409 \"Not while a session is on.\"", r == "409 Not while a session is on.");
            }
            foreach (string[] g in guardedRoutes)
            {
                string r = Route(g[0], g[1] == "star" ? D("id", "x", "star", "1") : D("id", "x"), ran);
                Check(g[0] + (g[1] == "star" ? "?star=1" : "") + " -> 409 with the sentence", r == "409 Not while a session is on.");
            }
            Check("nothing of that reached the stub", ran.Count == 0);
            Check("the deck keys that only pick or toggle still work in a session (mdpick, ovtoggle, AI LEVEL low, deltaon)",
                  ApiDo("mdpick", "c00000001", false, ran) == "200 ok" && ApiDo("ovtoggle", "relative", false, ran) == "200 ok" && ApiDo("ailevel", "low", false, ran) == "200 ok" && ApiDo("deltaon", null, false, ran) == "200 ok");
            Check("SAVE of the session being recorded still works (recsave is not refused here; Recorder.Save refuses only the big move)", ApiDo("recsave", "", false, ran) == "200 ok" && Route("/api/rec/save", D(), ran) == "200");
            Check("a note or tag on a Vault moment is fine (only star=1 copies 78 MB)", Route("/vault/edit", D("id", "x", "note", "hi"), ran) == "200" && Route("/vault/edit", D("id", "x", "star", "0"), ran) == "200");
            Check("Stream Deck restart in Watch is not one of the guarded commands (it stays allowed)", !Gate.IsGuardedDo("deckrestart", null));

            Console.WriteLine("2. the phone while a session is on: only sound, pit, chat, spotter, black boxes and in-car helpers");
            string[] refusedKeys = { "shutdown", "quit-main", "quit-main2", "restart-race", "skip-session", "race-now", "ai-race", "pause", "kids", "rig-on", "sleep", "lock", "showcase", "smart", "get-out", "official" };
            foreach (string k in refusedKeys) Check("phone key " + k + " mid-session -> refused", ApiDo("key", k, true, ran).StartsWith("409 "));
            string[] okKeys = { "mute", "vol-up", "vol-down", "mute-spotter", "fuel-finish", "pit-tires", "pit-clear", "pit-fr", "pit-ws", "say-gg", "say-sorry", "say-thanks", "bb-f3", "tow" };
            foreach (string k in okKeys) Check("phone key " + k + " mid-session -> allowed", ApiDo("key", k, true, ran) == "200 ok");
            Check("phone sound page (sndmute, sndvol, sndpreset) mid-session -> allowed", ApiDo("sndmute", "game", true, ran) == "200 ok" && ApiDo("sndvol", "game:+10", true, ran) == "200 ok" && ApiDo("sndpreset", "race", true, ran) == "200 ok");
            Check("phone REPLAY tab mid-session -> allowed (SDK replay messages only)", ApiDo("rpplay", null, true, ran) == "200 ok");
            Check("phone MY DRIVE pick and overlay presets mid-session -> refused", ApiDo("mdpick", "c00000001", true, ran).StartsWith("409 ") && ApiDo("ovpreset", "race", true, ran).StartsWith("409 "));
            Check("the same keys from the deck on this PC are not limited by the phone list", ApiDo("key", "quit-main", false, ran) == "200 ok");

            Console.WriteLine("3. the session is over: everything passes through to the stub");
            RigState.Feed(false, false, false);
            ran.Clear();
            foreach (string[] g in guardedDo) ApiDo(g[0], g[1], false, ran);
            foreach (string[] g in guardedRoutes) Route(g[0], g[1] == "star" ? D("star", "1") : D(), ran);
            Check("every guarded command and route ran (" + ran.Count + " of " + (guardedDo.Length + guardedRoutes.Length) + ")", ran.Count == guardedDo.Length + guardedRoutes.Length);
            Check("phone shutdown with no session -> passes the session rule (the deck's own x2 confirm still applies)", ApiDo("key", "shutdown", true, ran) == "200 ok");
            simUp = true; RigState.Probe(); RigState.Feed(true, true, false);
            Check("a REAL session (sim program + SDK, on track) is refused the same way", ApiDo("mdfindcar", "CUP", false, ran).StartsWith("409 ") && ApiDo("key", "shutdown", true, ran).StartsWith("409 "));
            simUp = false; RigState.Probe(); RigState.Feed(false, false, false);

            Console.WriteLine("4. which requests change something (they need the header)");
            Check("/api/do, /api/guest/do, /api/doctor/run, /api/keymsg, /api/open, /api/rec/delete need it", Gate.ChangesState("GET", "/api/do") && Gate.ChangesState("GET", "/api/guest/do") && Gate.ChangesState("GET", "/api/doctor/run") && Gate.ChangesState("GET", "/api/keymsg") && Gate.ChangesState("GET", "/api/open") && Gate.ChangesState("GET", "/api/rec/delete"));
            Check("/vault/edit, /vault/delete, /analysis/pro/save, /analysis/pro/delete, /share/make, /phone/revoke need it", Gate.ChangesState("GET", "/vault/edit") && Gate.ChangesState("GET", "/vault/delete") && Gate.ChangesState("GET", "/analysis/pro/save") && Gate.ChangesState("GET", "/analysis/pro/delete") && Gate.ChangesState("GET", "/share/make") && Gate.ChangesState("GET", "/phone/revoke"));
            Check("any POST needs it", Gate.ChangesState("POST", "/vault/list"));
            Check("reads do not: /deck/state, /rig/state, /api/rec/races, /api/kids, /api/tow-wait, /mydrive, /stream", !Gate.ChangesState("GET", "/deck/state") && !Gate.ChangesState("GET", "/rig/state") && !Gate.ChangesState("GET", "/api/rec/races") && !Gate.ChangesState("GET", "/api/kids") && !Gate.ChangesState("GET", "/api/tow-wait") && !Gate.ChangesState("GET", "/mydrive") && !Gate.ChangesState("GET", "/stream"));

            Console.WriteLine("5. the X-Paddock header rule (null = allowed)");
            const int P = 8199; string H = "localhost:8199";
            Check("a web page's blind fetch (cross-site, foreign Origin, no header) -> refused", Gate.HeaderRefusal(D("Host", H, "Sec-Fetch-Site", "cross-site", "Origin", "https://evil.example"), true, P) != null);
            Check("an <img> or no-cors request from another site (Sec-Fetch-Site only) -> refused", Gate.HeaderRefusal(D("Host", H, "Sec-Fetch-Site", "cross-site"), true, P) != null);
            Check("a page on another local port (same-site but not same-origin) -> refused", Gate.HeaderRefusal(D("Host", H, "Sec-Fetch-Site", "same-site", "Origin", "http://localhost:8080"), true, P) != null);
            Check("an old browser with only a Referer from elsewhere -> refused", Gate.HeaderRefusal(D("Host", H, "Referer", "https://evil.example/x"), true, P) != null);
            Check("X-Paddock: 1 -> ok, from anywhere", Gate.HeaderRefusal(D("Host", H, "X-Paddock", "1", "Sec-Fetch-Site", "cross-site", "Origin", "null"), true, P) == null);
            Check("X-Paddock: 0 is not the header", Gate.HeaderRefusal(D("Host", H, "X-Paddock", "0", "Sec-Fetch-Site", "cross-site", "Origin", "https://evil.example"), true, P) != null);
            Check("the top screen's own pages (Sec-Fetch-Site: same-origin) -> ok", Gate.HeaderRefusal(D("Host", H, "Sec-Fetch-Site", "same-origin"), true, P) == null);
            Check("a same-origin POST (Origin = this server) -> ok", Gate.HeaderRefusal(D("Host", H, "Origin", "http://localhost:8199"), true, P) == null);
            Check("the Stream Deck add-on before Peter re-installs it (a local file page: Origin null, no header) -> ok", Gate.HeaderRefusal(D("Host", "127.0.0.1:8199", "Origin", "null", "Sec-Fetch-Site", "cross-site"), true, P) == null);
            Check("a program on this PC (irdeck, tests: none of a browser's marks) -> ok", Gate.HeaderRefusal(D("Host", "127.0.0.1:8199", "User-Agent", "x"), true, P) == null);
            Check("from the LAN with no header (a phone's browser following a link) -> refused", Gate.HeaderRefusal(D("Host", "192.168.1.5:8199"), false, P) != null);
            Check("from the LAN with the phone app's token header -> ok (the token itself is checked by the phone gate)", Gate.HeaderRefusal(D("Host", "192.168.1.5:8199", "X-Paddock-Token", "abc"), false, P) == null);

            Console.WriteLine("6. the CORS preflight the header causes");
            Check("the add-on (Origin null) may send X-Paddock", Gate.PreflightOk(D("Origin", "null", "Access-Control-Request-Headers", "x-paddock"), P));
            Check("a foreign site may not", !Gate.PreflightOk(D("Origin", "https://evil.example"), P) && !Gate.PreflightOk(D("Origin", "http://localhost:8080"), P) && !Gate.PreflightOk(D(), P));
            Check("Origin null from a PUBLIC page (Chrome adds Access-Control-Request-Private-Network) -> refused", !Gate.PreflightOk(D("Origin", "null", "Access-Control-Request-Private-Network", "true"), P));
            string ph = Gate.PreflightHeaders(D("Origin", "null"));
            Check("the yes names the origin, GET and the two headers", ph.Contains("Access-Control-Allow-Origin: null") && ph.Contains("Access-Control-Allow-Headers: X-Paddock, X-Paddock-Token") && ph.Contains("GET"));

            Console.WriteLine("7. from the LAN: the phone app's own routes only (an allow-list)");
            string[] phoneOk = { "/phone/", "/phone/app.js", "/phone/state", "/phone/pair", "/phone/revoke", "/api/do", "/api/rec/for", "/api/rec/save", "/sound", "/mydrive", "/overlays", "/replay", "/sessions", "/debrief", "/vault", "/vault/list", "/vault/video", "/vault/thumb", "/analysis/session", "/share/make", "/share/video", "/rig/state" };
            string[] phoneNo = { "/phone/qr", "/api/guest/do", "/api/guest/draft", "/api/watch/open", "/api/test/frame", "/perf/status", "/perf/scan", "/vault/edit", "/vault/delete", "/api/rec/delete", "/api/rec/backfill", "/analysis/pro/save", "/share/open", "/api/doctor/run", "/api/open", "/api/keymsg", "/v2/index.html", "/deck/state", "/stream" };
            bool allOk = true; foreach (string p in phoneOk) if (!Gate.PhonePath(p)) { allOk = false; Console.WriteLine("        not allowed but should be: " + p); }
            bool allNo = true; foreach (string p in phoneNo) if (Gate.PhonePath(p)) { allNo = false; Console.WriteLine("        allowed but should not be: " + p); }
            Check("every route the phone page uses is allowed (" + phoneOk.Length + ")", allOk);
            Check("everything else is not (" + phoneNo.Length + " checked, incl. /api/guest/*, /perf/*, /api/watch/open, the test hooks)", allNo);

            Console.WriteLine(pass + " passed, " + fail + " failed.");
            return fail == 0 ? 0 : 1;
        }

        // ---------------- the pretend irdash for the browser ----------------
        static string logFile;
        static void Note(string s) { lock (typeof(GuardsUnit)) File.AppendAllText(logFile, s + "\r\n"); }

        static int Serve(string dir, int seconds)
        {
            foreach (int port in new[] { 8299, 8298 })
            {
                TcpListener l = new TcpListener(IPAddress.Loopback, port); l.Start();
                int p = port;
                Thread t = new Thread(delegate () { while (true) { TcpClient c; try { c = l.AcceptTcpClient(); } catch { return; } new Thread(delegate () { Handle(c, dir, p); }) { IsBackground = true }.Start(); } });
                t.IsBackground = true; t.Start();
            }
            Note("ready");
            Thread.Sleep(seconds * 1000);
            return 0;
        }

        static void Handle(TcpClient c, string dir, int port)
        {
            using (c)
            {
                try
                {
                    NetworkStream s = c.GetStream(); s.ReadTimeout = 5000;
                    StringBuilder head = new StringBuilder(); int last4 = 0;
                    while (head.Length < 16384) { int b = s.ReadByte(); if (b < 0) return; head.Append((char)b); last4 = (last4 << 8) | b; if (last4 == 0x0D0A0D0A) break; }
                    string[] lines = head.ToString().Split(new[] { "\r\n" }, StringSplitOptions.None);
                    string[] req = lines[0].Split(' '); if (req.Length < 2) return;
                    var hdr = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    for (int i = 1; i < lines.Length; i++) { int k = lines[i].IndexOf(':'); if (k > 0) hdr[lines[i].Substring(0, k).Trim()] = lines[i].Substring(k + 1).Trim(); }
                    string method = req[0], target = req[1], path = target, query = "";
                    int q = target.IndexOf('?'); if (q >= 0) { path = target.Substring(0, q); query = target.Substring(q + 1); }
                    string origin; hdr.TryGetValue("Origin", out origin); string site; hdr.TryGetValue("Sec-Fetch-Site", out site);
                    if (method == "OPTIONS")
                    {
                        bool ok = Gate.PreflightOk(hdr, 8299);
                        Note("OPTIONS " + target + " origin=" + origin + " -> " + (ok ? 204 : 403));
                        Send(s, ok ? 204 : 403, "text/plain", "", ok ? Gate.PreflightHeaders(hdr) : "");
                        return;
                    }
                    if (path == "/api/do")
                    {
                        string why = Gate.ChangesState(method, path) ? Gate.HeaderRefusal(hdr, true, 8299) : null;
                        int code = why == null ? 200 : 403;
                        Note("GET " + query + " origin=" + origin + " site=" + site + " paddock=" + (hdr.ContainsKey("X-Paddock") ? hdr["X-Paddock"] : "") + " -> " + code);
                        Send(s, code, "text/plain", code == 200 ? "ok" : "refused: " + why, "Access-Control-Allow-Origin: *\r\n");
                        return;
                    }
                    string f = Path.Combine(dir, path.TrimStart('/'));
                    if (path.EndsWith(".html") && File.Exists(f)) { Send(s, 200, "text/html; charset=utf-8", File.ReadAllText(f), ""); return; }
                    Send(s, 404, "text/plain", "not found", "");
                }
                catch { }
            }
        }
        static void Send(NetworkStream s, int code, string type, string body, string extra)
        {
            byte[] b = Encoding.UTF8.GetBytes(body);
            byte[] h = Encoding.ASCII.GetBytes("HTTP/1.1 " + code + " X\r\nContent-Type: " + type + "\r\nContent-Length: " + b.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n" + extra + "\r\n");
            s.Write(h, 0, h.Length); if (b.Length > 0) s.Write(b, 0, b.Length); s.Flush();
        }

        static int Main(string[] args)
        {
            if (args.Length >= 4 && args[0] == "serve") { logFile = args[3]; return Serve(args[1], int.Parse(args[2])); }
            return Unit();
        }
    }
}
