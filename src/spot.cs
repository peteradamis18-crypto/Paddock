using System;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDeck
{
    // Practice loop and PAUSE (2026-10-23, from what Peter does: 81 of his last 101 sessions were AI races, the rest Test Drives, and he
    // restarts over and over to get one corner right).
    //   spot save   SAVE SPOT:    iRacing's Active Reset save (Ctrl+Shift+F1: car, speed, fuel, tyres, damage). Test Drive only.
    //   spot back   BACK TO SPOT: Active Reset run (Ctrl+Shift+F2), then irdash times the try from the spot to the end of the next
    //               corner and puts "Try 3: 9.82 s - best 9.61 (+0.21)" on the top screen (dash\src\spot.cs).
    //   pause       PAUSE:        iRacing's pause key; says whether the sim really stopped (offline sessions only).
    // Active Reset has a 1.5 s cooldown between save and run, so BACK waits that out after a save.
    static partial class Program
    {
        static string SpotGet(string query, int ms)
        {
            try
            {
                HttpWebRequest rq = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:8199/api/spot?" + query);
                rq.Timeout = ms; rq.ReadWriteTimeout = ms; rq.Proxy = null; rq.KeepAlive = false;
                using (WebResponse rs = rq.GetResponse())
                using (StreamReader sr = new StreamReader(rs.GetResponseStream(), Encoding.UTF8)) return sr.ReadToEnd();
            }
            catch { return null; }
        }

        static long UnixMs() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }

        static string JsonStr(string json, string key)
        {
            Match m = Regex.Match(json ?? "", "\"" + key + "\":\"((?:[^\"\\\\]|\\\\.)*)\"");
            return m.Success ? Regex.Unescape(m.Groups[1].Value) : "";
        }
        static long JsonNum(string json, string key)
        {
            Match m = Regex.Match(json ?? "", "\"" + key + "\":(-?\\d+)");
            long v; return m.Success && long.TryParse(m.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : -1;
        }
        static bool JsonTrue(string json, string key) { return Regex.IsMatch(json ?? "", "\"" + key + "\":true"); }

        // Active Reset is for a Test Drive in the car. Null = fine, else the reason (already logged).
        static int SpotGate(out bool ok)
        {
            ok = false;
            Tele t = Tele.Open();
            if (t == null) { Log("spot: refused - iRacing is not in a session"); return 3; }
            string info; bool inCar;
            using (t) { info = t.SessionInfo(); inCar = t.Bool("IsOnTrack"); }
            if (!Regex.IsMatch(info, @"EventType:\s*Test")) { Log("spot: refused - this is for a Test Drive (iRacing's Active Reset works there only)"); return 3; }
            if (!inCar) { Log("spot: refused - get in the car first"); return 3; }
            ok = true; return 0;
        }

        static int CmdSpot(string[] a)
        {
            string verb = a.Length > 0 ? a[0].ToLowerInvariant() : "";
            if (verb == "clear") { SpotGet("cmd=clear", 1500); Log("spot: cleared"); return 0; }
            if (verb != "save" && verb != "back") { Log("spot: need save | back | clear"); return 1; }
            bool ok; int gate = SpotGate(out ok);
            if (!ok) return gate;
            if (verb == "save")
            {
                if (!FocusWindow(SimWindow())) { Log("spot: could not bring the sim to the front"); return 3; }
                long at = UnixMs();
                SendCombo("ctrl+shift+f1", 80);
                string r = SpotGet("cmd=save&t=" + at.ToString(CultureInfo.InvariantCulture), 2500);
                if (r == null) { Log("spot: ok - Spot saved in iRacing (the dashboard did not answer, so tries will not be timed)"); return 0; }
                if (!JsonTrue(r, "ok")) { Log("spot: refused - " + JsonStr(r, "text")); return 3; }
                Log("spot: ok - " + JsonStr(r, "text"));
                return 0;
            }
            // back
            string st = SpotGet("cmd=status", 1500);
            if (st == null) { Log("spot: refused - the dashboard did not answer, so the spot is not known (press SAVE SPOT)"); return 3; }
            if (!JsonTrue(st, "saved")) { Log("spot: refused - nothing saved yet: press SAVE SPOT where you want to come back to"); return 3; }
            long ago = JsonNum(st, "savedAgoMs"), seq0 = JsonNum(st, "starts");
            if (ago >= 0 && ago < 1700) Thread.Sleep((int)(1700 - ago));        // iRacing waits 1.5 s between a save and a run
            if (!FocusWindow(SimWindow())) { Log("spot: could not bring the sim to the front"); return 3; }
            SpotGet("cmd=back&t=" + UnixMs().ToString(CultureInfo.InvariantCulture), 1500);
            SendCombo("ctrl+shift+f2", 80);
            for (int i = 0; i < 24; i++)
            {
                Thread.Sleep(125);
                string n = SpotGet("cmd=status", 800);
                if (n != null && JsonNum(n, "starts") > seq0)
                {
                    long tries = JsonNum(n, "tries");
                    Log("spot: ok - back at the spot, timing " + JsonStr(n, "where") + (tries > 0 ? " (" + tries + " tries so far)" : ""));
                    return 0;
                }
            }
            Log("spot: iRacing did not move the car back - nothing is saved in iRacing (the garage clears it): press SAVE SPOT again");
            return 3;
        }

        // PAUSE: one press of iRacing's pause key; the answer comes from the sim's own clock (SessionTime stands still while paused).
        static bool SimClockStands()
        {
            double t0, t1;
            Tele a = Tele.Open(); if (a == null) return false;
            using (a) t0 = a.Num("SessionTime");
            Thread.Sleep(350);
            Tele b = Tele.Open(); if (b == null) return false;
            using (b) t1 = b.Num("SessionTime");
            return Math.Abs(t1 - t0) < 0.0005;
        }

        static int CmdPause()
        {
            if (Tele.Open() == null) { Log("pause: refused - iRacing is not in a session"); return 3; }
            bool was = SimClockStands();
            if (!FocusWindow(SimWindow())) { Log("pause: could not bring the sim to the front"); return 3; }
            SendCombo("pause", 70);
            Thread.Sleep(500);
            bool now = SimClockStands();
            if (now == was) { Log("pause: the sim did not " + (was ? "restart" : "pause") + " (pause works in a Test Drive or an AI race, not online)"); return 3; }
            Log(now ? "pause: ok - Paused: press PAUSE again to carry on" : "pause: ok - Running again");
            return 0;
        }
    }
}
