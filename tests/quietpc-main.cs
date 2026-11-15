// Entry point for tests\quietpc-test.ps1 only (W5-2): compiled with dash\src\*.cs (csc /main:IRDash.QuietPcMain) into a throw-away exe in
// %TEMP%. It runs irdash's real Server on a test port (never 8199) and drives a PRETEND session through RigState.Feed, so the real hooks
// (StateBuilder.SessionStarted / SessionEnded -> QuietPC) fire. PADDOCK_QUIETPC_CMD (set by the test) points at a stub .cmd that only
// writes its argument to a file: no task is run, no service is touched. The services and OneDrive are pretend (QuietPC.ReadService /
// ReadOneDrive). SimPriority is proved on a stand-in process the test started (a copy of cmd.exe waiting on "pause").
//   quietpc-main.exe <port> <www dir> <data dir> <record file> <stand-in exe>
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
    static class QuietPcMain
    {
        static int pass, fail, port;
        static void Ok(string what, bool cond, string why) { if (cond) { pass++; Console.WriteLine("  ok   " + what); } else { fail++; Console.WriteLine("  FAIL " + what + (why != null && why.Length > 0 ? "  (" + why + ")" : "")); } }
        static void Info(string s) { Console.WriteLine("  info " + s); }
        static readonly JavaScriptSerializer J = new JavaScriptSerializer();
        static readonly Dictionary<string, string> svc = new Dictionary<string, string>();
        static bool od = true; static int svcReads;
        static string record, data;

        static string Get(string target)
        {
            using (TcpClient c = new TcpClient("127.0.0.1", port))
            {
                c.ReceiveTimeout = 5000; NetworkStream s = c.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("GET " + target + " HTTP/1.1\r\nHost: localhost:" + port + "\r\nConnection: close\r\n\r\n");
                s.Write(req, 0, req.Length);
                MemoryStream ms = new MemoryStream(); byte[] b = new byte[8192]; int n;
                while ((n = s.Read(b, 0, b.Length)) > 0) ms.Write(b, 0, n);
                string all = Encoding.UTF8.GetString(ms.ToArray()); int k = all.IndexOf("\r\n\r\n");
                return k < 0 ? "" : all.Substring(k + 4);
            }
        }
        static Dictionary<string, object> Quiet()
        {
            try { Dictionary<string, object> o = J.DeserializeObject(Get("/state")) as Dictionary<string, object>; return o == null ? null : o["quiet"] as Dictionary<string, object>; } catch { return null; }
        }
        static string ItemState(Dictionary<string, object> q, string id)
        {
            if (q == null) return null;
            foreach (object o in (object[])q["items"]) { Dictionary<string, object> d = (Dictionary<string, object>)o; if ((string)d["id"] == id) return (string)d["state"]; }
            return null;
        }
        static string[] Recorded() { try { return File.Exists(record) ? File.ReadAllLines(record) : new string[0]; } catch { return new string[0]; } }
        static string Joined() { return string.Join(",", Array.ConvertAll(Recorded(), delegate (string x) { return x.Trim(); })); }
        static bool WaitFor(int lines, int ms) { Stopwatch w = Stopwatch.StartNew(); while (w.ElapsedMilliseconds < ms) { if (Recorded().Length >= lines) return true; Thread.Sleep(100); } return Recorded().Length >= lines; }
        static void Session(bool on) { RigState.Feed(on, false, on); StateBuilder.Changed("lists"); Thread.Sleep(900); }
        static long NowMs() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }

        static int Main(string[] a)
        {
            port = int.Parse(a[0]); string www = a[1]; data = a[2]; record = a[3]; string standin = a[4];
            Log.FilePath = Path.Combine(Path.GetTempPath(), "quietpc-test-" + port + ".log");
            try { File.Delete(Log.FilePath); } catch { }
            RigState.SimProbe = delegate { return false; };      // never the real sim
            QuietPC.Dir = data;
            QuietPC.ReadService = delegate (string n) { Interlocked.Increment(ref svcReads); string s; lock (svc) return svc.TryGetValue(n, out s) ? s : null; };
            QuietPC.ReadOneDrive = delegate { return od; };
            lock (svc) { svc["wuauserv"] = "Stopped"; svc["UsoSvc"] = "Running"; svc["WSearch"] = "Running"; }
            // the same two hook lines as irdash.cs (Review is left out: no library here)
            StateBuilder.SessionEnded = QuietPC.SessionEnded;
            StateBuilder.SessionStarted = QuietPC.SessionStarted;
            Server srv = new Server(port, www, Path.GetTempPath());
            srv.Start();
            Stopwatch boot = Stopwatch.StartNew();
            while (StateBuilder.Seq < 1 && boot.ElapsedMilliseconds < 8000) Thread.Sleep(50);
            Thread.Sleep(600);

            Console.WriteLine("Section 1. not set up: nothing runs, setup:false");
            Dictionary<string, object> q = Quiet();
            Ok("/state has the quiet part with setup, on, since, say, items", q != null && q.ContainsKey("setup") && q.ContainsKey("on") && q.ContainsKey("since") && q.ContainsKey("say") && q.ContainsKey("items"), J.Serialize(q));
            string ids = "";
            if (q != null) foreach (object o in (object[])q["items"]) { Dictionary<string, object> d = (Dictionary<string, object>)o; ids += (ids.Length > 0 ? "," : "") + d["id"] + "=" + d["name"]; }
            Ok("the four items in order: update=Windows Update, search=Search indexing, onedrive=OneDrive, simprio=Sim priority (" + ids + ")", ids == "update=Windows Update,search=Search indexing,onedrive=OneDrive,simprio=Sim priority", "");
            Ok("not set up: setup false, on false, since 0, say \"Quiet PC · not set up\"", q != null && !(bool)q["setup"] && !(bool)q["on"] && Convert.ToInt64(q["since"]) == 0 && (string)q["say"] == "Quiet PC · not set up", J.Serialize(q));
            Ok("the real-state reads: update running (UsoSvc runs), search running, onedrive running", ItemState(q, "update") == "running" && ItemState(q, "search") == "running" && ItemState(q, "onedrive") == "running", J.Serialize(q));
            Session(true); Thread.Sleep(600);
            Ok("a session starts without setup.json: nothing runs", Recorded().Length == 0, Joined());
            Session(false); Thread.Sleep(600);
            Ok("and its end runs nothing either", Recorded().Length == 0, Joined());

            Console.WriteLine("Section 2. set up: a session start runs \"on\" once, its end \"off\" once");
            Directory.CreateDirectory(data);
            File.WriteAllText(Path.Combine(data, "setup.json"), "{\"at\":\"2026-11-14T20:00:00\",\"user\":\"PETER\\\\peter\",\"logon\":\"S4U\",\"tasks\":[\"Paddock Quiet PC on\",\"Paddock Quiet PC off\"]}");
            // what the task and the script would leave behind (the stub does not), and the PC as it then is
            long since = NowMs() - 60000;
            File.WriteAllText(Path.Combine(data, "state.json"), "{\"on\":true,\"since\":" + since + ",\"services\":[\"UsoSvc\",\"WSearch\"],\"at\":\"x\"}");
            File.WriteAllText(Path.Combine(data, "onedrive.json"), "{\"paused\":true,\"since\":" + (since + 5000) + ",\"path\":\"x\"}");
            lock (svc) { svc["UsoSvc"] = "Stopped"; svc["WSearch"] = "Stopped"; } od = false;
            Session(true);
            WaitFor(1, 4000); Ok("the session start ran \"on\" once (" + Joined() + ")", Joined() == "on", Joined());
            QuietPC.SessionStarted(); Thread.Sleep(1200);
            Ok("a second start inside the same session runs nothing (" + Joined() + ")", Joined() == "on", Joined());
            Thread.Sleep(1200);
            q = Quiet();
            string hhmm = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(since).ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture);
            string sayOn = "Quiet PC on since " + hhmm + " · Windows Update, search and OneDrive paused";
            Ok("on: setup true, on true, since = the earlier of the two files", q != null && (bool)q["setup"] && (bool)q["on"] && Convert.ToInt64(q["since"]) == since, J.Serialize(q));
            Ok("say: \"" + sayOn + "\"", q != null && (string)q["say"] == sayOn, q == null ? "" : (string)q["say"]);
            Ok("items: update paused, search paused, onedrive paused", ItemState(q, "update") == "paused" && ItemState(q, "search") == "paused" && ItemState(q, "onedrive") == "paused", J.Serialize(q));
            string sp = ItemState(q, "simprio");
            Ok("simprio is on, off or unknown (" + sp + ")", sp == "on" || sp == "off" || sp == "unknown", "");
            Ok("irdash.log has one line for the on", File.Exists(Log.FilePath) && File.ReadAllText(Log.FilePath).Contains("quiet pc on: stub exit 0"), "");
            // the 10 s cache: five seconds of the part being made every second, at most one real read (three service reads)
            int r0 = svcReads; Thread.Sleep(5000); int r1 = svcReads;
            Ok("the real states are read at most every 10 s (" + (r1 - r0) + " service reads in 5 s)", r1 - r0 <= 3, "");
            Session(false);
            WaitFor(2, 4000); Ok("the session end ran \"off\" once (" + Joined() + ")", Joined() == "on,off", Joined());
            QuietPC.SessionEnded(); Thread.Sleep(1200);      // the sim closing later fires SessionEnded again
            Ok("the sim closing afterwards (SessionEnded again) runs nothing more (" + Joined() + ")", Joined() == "on,off", Joined());
            File.WriteAllText(Path.Combine(data, "state.json"), "{\"on\":false,\"since\":0,\"services\":[],\"offAt\":1}");
            File.WriteAllText(Path.Combine(data, "onedrive.json"), "{\"paused\":false,\"since\":0}");
            lock (svc) { svc["UsoSvc"] = "Running"; svc["WSearch"] = "Running"; } od = true;
            Stopwatch cw = Stopwatch.StartNew(); q = Quiet();
            while (cw.ElapsedMilliseconds < 12000 && ItemState(q, "search") != "running") { Thread.Sleep(500); q = Quiet(); }
            Ok("off: say \"Quiet PC off · everything handed back\", on false, since 0", q != null && !(bool)q["on"] && Convert.ToInt64(q["since"]) == 0 && (string)q["say"] == "Quiet PC off · everything handed back", J.Serialize(q));
            Ok("and the items follow the PC within the 10 s cache (" + cw.ElapsedMilliseconds + " ms): update, search, onedrive running", ItemState(q, "update") == "running" && ItemState(q, "search") == "running" && ItemState(q, "onedrive") == "running", J.Serialize(q));
            Ok("one word list: only what was paused is named", QuietPC.PausedWords(new List<string> { "WSearch" }, false) == "search paused" && QuietPC.PausedWords(new List<string>(), false) == "nothing needed pausing" && QuietPC.PausedWords(new List<string> { "wuauserv" }, true) == "Windows Update and OneDrive paused", "");

            Console.WriteLine("Section 3. irdash starts with the PC still quiet");
            File.WriteAllText(Path.Combine(data, "state.json"), "{\"on\":true,\"since\":" + NowMs() + ",\"services\":[\"WSearch\"]}");
            QuietPC.StartDelayMs = 300; QuietPC.Start();
            WaitFor(3, 4000); Ok("no session on: \"off\" runs by itself (" + Joined() + ")", Joined() == "on,off,off", Joined());
            Session(true);
            WaitFor(4, 4000); Ok("a session then starts: \"on\" (" + Joined() + ")", Joined() == "on,off,off,on", Joined());
            QuietPC.Start(); Thread.Sleep(1500);
            Ok("irdash starting while a session is on hands nothing back (" + Joined() + ")", Joined() == "on,off,off,on", Joined());
            Session(false);
            WaitFor(5, 4000); Ok("its end: \"off\" (" + Joined() + ")", Joined() == "on,off,off,on,off", Joined());

            Console.WriteLine("Section 4. sim priority kept: lowered mid-session, raised back within 30 s");
            Process pr = null;
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(standin, "/c pause");
                psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardInput = true; psi.RedirectStandardOutput = true;
                pr = Process.Start(psi);
                Thread.Sleep(500);
                SimPriority.Mode = "high"; SimPriority.ProcName = Path.GetFileNameWithoutExtension(standin);
                Ok("the 30 s re-check is the default (RecheckMs " + SimPriority.RecheckMs + ")", SimPriority.RecheckMs == 30000, "");
                RigState.Feed(true, false, true);
                SimPriority.Tick(true);
                pr.Refresh();
                Ok("the first look raises the stand-in to High (" + pr.PriorityClass + ", " + SimPriority.Last + ")", pr.PriorityClass == ProcessPriorityClass.High, SimPriority.Last);
                pr.PriorityClass = ProcessPriorityClass.Normal;
                Stopwatch w = Stopwatch.StartNew();
                while (w.ElapsedMilliseconds < 35000) { SimPriority.Tick(true); pr.Refresh(); if (pr.PriorityClass == ProcessPriorityClass.High) break; Thread.Sleep(250); }
                long took = w.ElapsedMilliseconds;
                Ok("lowered to Normal mid-session, it is High again after " + (took / 1000.0).ToString("0.0", CultureInfo.InvariantCulture) + " s (<= 30.5 s)", pr.PriorityClass == ProcessPriorityClass.High && took <= 30500, SimPriority.Last);
                SimPriority.RecheckMs = 500;
                pr.PriorityClass = ProcessPriorityClass.BelowNormal;
                Stopwatch w2 = Stopwatch.StartNew();
                while (w2.ElapsedMilliseconds < 5000) { SimPriority.Tick(true); pr.Refresh(); if (pr.PriorityClass == ProcessPriorityClass.High) break; Thread.Sleep(100); }
                Thread.Sleep(1500);
                string lg = File.Exists(Log.FilePath) ? File.ReadAllText(Log.FilePath) : "";
                int n = 0, at = 0; while ((at = lg.IndexOf("mid-session: raised to High again", at)) >= 0) { n++; at++; }
                Ok("lowered a second time it is raised again, and the log says so once per session (" + n + " line)", pr.PriorityClass == ProcessPriorityClass.High && n == 1, "");
                Ok("the Quiet PC item says simprio on", SimPriority.ItemState() == "on", SimPriority.ItemState());
                RigState.Feed(false, false, false);
            }
            catch (Exception ex) { Ok("the stand-in ran", false, ex.Message); }
            finally { if (pr != null) { try { pr.Kill(); } catch { } pr.Dispose(); } }

            Console.WriteLine("result: " + pass + " ok, " + fail + " FAIL");
            return fail == 0 ? 0 : 1;
        }
    }
}
