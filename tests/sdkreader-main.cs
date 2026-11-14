// Entry point for tests\sdkreader-test.ps1 only (W2-1): compiled with dash\src\*.cs (csc /main:IRDash.SdkReaderMain) into a throw-away exe.
// It runs irdash's real Sdk pretend-session pump, IbtReplay and Server on a test port (never 8199) over a throw-away www folder:
//   1. the session YAML is parsed once per SessionVersion (200 frames, then a version bump), and what one parse costs
//   2. Sdk.Session from the 12 Nov YAML: drivers by CarIdx, Peter's row, the pace car, the incident limit, the tank
//   3. /stream?set=race: exactly the 24 keys, arrays, 15 frames a second; ?vars= as before
//   4. the race state part: null out of a session, every contract name, at most 4 changes a second at 20x
// Nothing here starts the SDK reader (no shared memory), touches iRacing, the deck or the live irdash.
//   sdkreader.exe <port> <www dir> <race-12nov.ibt>
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
    static class SdkReaderMain
    {
        static int pass, fail, port;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly JavaScriptSerializer J = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };
        static void Ok(string what, bool cond, string why) { if (cond) { pass++; Console.WriteLine("  ok   " + what); } else { fail++; Console.WriteLine("  FAIL " + what + (string.IsNullOrEmpty(why) ? "" : "  (" + why + ")")); } }
        static void Info(string s) { Console.WriteLine("  info " + s); }
        static Dictionary<string, object> Obj(string json) { try { return J.DeserializeObject(json) as Dictionary<string, object>; } catch { return null; } }
        static Dictionary<string, object> Sub(Dictionary<string, object> o, string k) { return o != null && o.ContainsKey(k) ? o[k] as Dictionary<string, object> : null; }

        static bool WaitFrames(long n, int ms)
        {
            long s0 = Sdk.Latest.Seq; Stopwatch sw = Stopwatch.StartNew();
            while (Sdk.Latest.Seq - s0 < n && sw.ElapsedMilliseconds < ms) Thread.Sleep(5);
            return Sdk.Latest.Seq - s0 >= n;
        }

        // a stream's events for ms milliseconds: (elapsed ms, event name, data)
        static List<string[]> Listen(string target, int ms)
        {
            List<string[]> evs = new List<string[]>();
            using (TcpClient c = new TcpClient("127.0.0.1", port))
            {
                c.ReceiveTimeout = 300;
                NetworkStream ns = c.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("GET " + target + " HTTP/1.1\r\nHost: localhost:" + port + "\r\n\r\n"); ns.Write(req, 0, req.Length);
                StreamReader rd = new StreamReader(ns, Encoding.UTF8);
                Stopwatch sw = Stopwatch.StartNew();
                string ev = "message", data = null;
                while (sw.ElapsedMilliseconds < ms)
                {
                    string line;
                    try { line = rd.ReadLine(); } catch (IOException) { continue; }
                    if (line == null) break;
                    if (line.StartsWith("event: ")) ev = line.Substring(7);
                    else if (line.StartsWith("data: ")) data = line.Substring(6);
                    else if (line.Length == 0 && data != null) { evs.Add(new[] { sw.ElapsedMilliseconds.ToString(Inv), ev, data }); ev = "message"; data = null; }
                    else if (line.Length == 0) ev = "message";
                }
            }
            return evs;
        }

        static string Get(string target)
        {
            using (TcpClient c = new TcpClient("127.0.0.1", port))
            {
                c.ReceiveTimeout = 5000; NetworkStream s = c.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("GET " + target + " HTTP/1.1\r\nHost: localhost:" + port + "\r\nConnection: close\r\n\r\n"); s.Write(req, 0, req.Length);
                string all = new StreamReader(s, Encoding.UTF8).ReadToEnd();
                int b = all.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                return b < 0 ? "" : all.Substring(b + 4);
            }
        }

        static int Main(string[] a)
        {
            port = int.Parse(a[0]);
            string www = a[1], ibt = a[2];
            Log.FilePath = Path.Combine(Path.GetTempPath(), "sdkreader-test-" + port + ".log");
            IbtFile file = IbtFile.Open(ibt, false);
            string yaml = file.Yaml; file.Dispose();

            Console.WriteLine("Section 1. the session YAML is parsed once per SessionVersion");
            Ok("out of a session the race part is null", StateBuilder.RacePart() == "null" && Sdk.Session == null, StateBuilder.RacePart());
            int p0 = Sdk.SessionParses;
            Sdk.FakePumpMs = 2;
            Sdk.FakeSession(yaml);
            Dictionary<string, double> v = new Dictionary<string, double>();
            v["PlayerCarIdx"] = 2; v["SessionNum"] = 2; v["IsOnTrack"] = 1; v["Lap"] = 3; v["SessionTime"] = 500; v["FuelLevel"] = 80;
            Sdk.FakeSet(v);
            bool got200 = WaitFrames(200, 15000);
            int p1 = Sdk.SessionParses - p0;
            Ok("200 frames with the same version: " + p1 + " parse (want 1)", got200 && p1 == 1, "frames " + got200);
            int ver = Sdk.Latest.SessionVersion;
            Sdk.FakeSession(yaml + "\n");      // a new version (iRacing's SessionInfoUpdate moved)
            WaitFrames(20, 5000);
            int p2 = Sdk.SessionParses - p0;
            Ok("one more after the version bump (" + ver + " -> " + Sdk.Latest.SessionVersion + "): " + p2 + " parses (want 2)", p2 == 2 && Sdk.Latest.SessionVersion != ver, "");
            SdkSession ss = Sdk.Session;
            Ok("Sdk.Session follows the frame's version", ss != null && ss.Ver == Sdk.Latest.SessionVersion, ss == null ? "null" : ss.Ver + " vs " + Sdk.Latest.SessionVersion);
            Ok("driving (IsOnTrack on a fresh frame): the race part is made", StateBuilder.RacePart() != "null", "");
            Dictionary<string, double> v2 = new Dictionary<string, double>(); v2["IsOnTrack"] = 0;
            Sdk.FakeSet(v2); WaitFrames(10, 5000);
            Ok("connected but not driving (the garage, spectating): the race part is null", StateBuilder.RacePart() == "null", StateBuilder.RacePart());
            v2["IsOnTrack"] = 1; v2["IsReplayPlaying"] = 1;
            Sdk.FakeSet(v2); WaitFrames(10, 5000);
            Ok("on track but an in-sim replay is playing: the race part is null", StateBuilder.RacePart() == "null", StateBuilder.RacePart());
            v2["IsReplayPlaying"] = 0;
            Sdk.FakeSet(v2); WaitFrames(10, 5000);
            Ok("back in the car: the race part is made again", StateBuilder.RacePart() != "null", "");
            Frame fr = Sdk.Latest;
            string part = StateBuilder.SessionPart(true, fr.SessionVersion, fr.SessionYaml);
            Ok("the session state part is the reader's parse (the same string, no second parse) and the same JSON as before W2-1",
                ss != null && ReferenceEquals(part, ss.Json) && part == StateBuilder.SessionJson(fr.SessionYaml, fr.SessionVersion), "");
            // what one read and one parse cost (iRacing's SessionInfoUpdate moves a few times a session, not per frame)
            byte[] raw = Encoding.GetEncoding(28591).GetBytes(yaml);
            Stopwatch sw = Stopwatch.StartNew();
            for (int i = 0; i < 50; i++) { int z = Array.IndexOf(raw, (byte)0); Encoding.GetEncoding(28591).GetString(raw, 0, z < 0 ? raw.Length : z); }
            double readMs = sw.Elapsed.TotalMilliseconds / 50;
            sw.Restart();
            for (int i = 0; i < 20; i++) SdkSession.Parse(yaml, i);
            double parseMs = sw.Elapsed.TotalMilliseconds / 20;
            Info("YAML " + yaml.Length + " chars: decoding it (ReadYaml's work) " + readMs.ToString("0.00", Inv) + " ms, one parse (tree + session + JSON) " + parseMs.ToString("0.0", Inv) + " ms"
                + "; per frame at 60 Hz that would have been " + (readMs * 60 / 10).ToString("0.0", Inv) + " % and " + (parseMs * 60 / 10).ToString("0", Inv) + " % of a core");
            Ok("one parse of the biggest fixture YAML (" + yaml.Length + " chars) takes " + parseMs.ToString("0.00", Inv) + " ms (ceiling 5 ms)", parseMs < 5, "");

            Console.WriteLine("Section 2. Sdk.Session from the 12 Nov YAML");
            int cars = 0; foreach (SdkDriver d in ss.Drivers) if (d != null) cars++;
            Ok("drivers by CarIdx: " + cars + " rows (19 cars, CarIdx 0-18, + the pace car), " + ss.Field(-1) + " racing", cars == 20 && ss.Field(-1) == 19, "");
            SdkDriver me = ss.Me;
            Ok("Peter's row by DriverCarIdx 2: number " + (me == null ? "?" : me.Num) + ", short name " + (me == null ? "?" : me.ShortName) + ", class " + (me == null ? "?" : me.ClassId + " " + me.ClassShort + " " + me.ClassColor),
                ss.PlayerIdx == 2 && me != null && me.Idx == 2 && me.Num == "3" && me.ShortName == "Adamis" && me.ClassId == 4012 && me.ClassColor == "#ffffff" && !me.IsPaceCar, "");
            SdkDriver pace = ss.Driver(64);
            Ok("the pace car (CarIdx 64) is flagged and not in the field", pace != null && pace.IsPaceCar && ss.Drivers.Length >= 65, "");
            Ok("car 0's short name is the surname without iRacing's duplicate digits (Diogo Santos11 -> " + ss.Driver(0).ShortName + ")", ss.Driver(0).ShortName == "Santos", "");
            Ok("IncidentLimit 17 (WeekendInfo.WeekendOptions); unlimited reads 0", ss.IncidentLimit == 17 && SdkSession.Parse(yaml.Replace("IncidentLimit: 17", "IncidentLimit: unlimited"), 1).IncidentLimit == 0, ss.IncidentLimit.ToString(Inv));
            Ok("the current session: Race, number 2, no lap count, 900 s (" + ss.Type + " " + ss.Num + " " + ss.Laps + " " + ss.TimeSec + ")", ss.Type == "Race" && ss.Num == 2 && ss.Laps == 0 && Math.Abs(ss.TimeSec - 900) < 0.01, "");
            Ok("three sessions; Lone Qualify has 2 laps", ss.Sessions.Count == 3 && ss.For(1) != null && ss.For(1).Type == "Lone Qualify" && ss.For(1).Laps == 2, "");
            Ok("one class (not multiclass), track Road Atlanta, tank 83.333 L, estimated lap 91.25 s", !ss.Multiclass && ss.Track == "Road Atlanta" && Math.Abs(ss.FuelMaxL - 83.333) < 0.001 && Math.Abs(ss.EstLap - 91.2545) < 0.001, ss.Track + " " + ss.FuelMaxL);
            Sdk.FakeEnd();
            Thread.Sleep(200);
            Ok("after the pretend session ends: Sdk.Session and the race part are null again", Sdk.Session == null && StateBuilder.RacePart() == "null", "");
            // the FakeEnd race: a pump frame that was on its way when the session ended
            Frame late = new Frame(); late.Connected = true; late.Vars = new Dictionary<string, VarDef>(); late.Data = new byte[8]; late.SessionVersion = 99; late.SessionYaml = yaml;
            bool out1 = Sdk.PublishPumpFrame(late);
            Ok("a pump frame after FakeEnd is dropped: Session stays null, the latest frame stays disconnected", !out1 && Sdk.Session == null && !Sdk.Latest.Connected, "published " + out1);

            Console.WriteLine("Section 2b. multiclass: of / classOf count the cars in the world");
            // CarIdx 0-4 made class 77 in the YAML; cars 10-18 not in the world (no position, LapDistPct -1)
            List<string> yl = new List<string>(); int cur = -1;
            foreach (string line in yaml.Split('\n'))
            {
                string l = line; string tl = l.Trim();
                if (tl.StartsWith("- CarIdx: ")) int.TryParse(tl.Substring(10).Trim(), out cur);
                if (cur >= 0 && cur <= 4 && tl.StartsWith("CarClassID:")) l = l.Replace("4012", "77");
                yl.Add(l);
            }
            Sdk.FakeSession(string.Join("\n", yl.ToArray()));
            Dictionary<string, double> mc = new Dictionary<string, double>();
            mc["PlayerCarIdx"] = 2; mc["SessionNum"] = 2; mc["IsOnTrack"] = 1; mc["Lap"] = 3; mc["SessionTime"] = 500;
            for (int k = 0; k < 19; k++) { mc["CarIdxPosition_" + k] = k < 10 ? k + 1 : 0; mc["CarIdxLapDistPct_" + k] = k < 10 ? 0.5 : -1; }
            Sdk.FakeSet(mc); WaitFrames(20, 5000);
            Dictionary<string, object> mo = Obj(StateBuilder.RacePart());
            Ok("multiclass: 10 cars in the world (of), 5 in Peter's class 77 (classOf), multiclass true: " + (mo == null ? "null" : mo["of"] + " / " + mo["classOf"] + " / " + mo["multiclass"]),
                mo != null && Convert.ToInt32(mo["of"], Inv) == 10 && Convert.ToInt32(mo["classOf"], Inv) == 5 && (bool)mo["multiclass"], "");
            Sdk.FakeEnd(); Thread.Sleep(200);

            Console.WriteLine("Section 3. /stream?set=race on irdash's real Server (port " + port + ")");
            Server srv = new Server(port, www, Path.GetTempPath());
            srv.Start();
            Stopwatch boot = Stopwatch.StartNew();
            while (StateBuilder.Seq < 1 && boot.ElapsedMilliseconds < 8000) Thread.Sleep(50);
            Sdk.FakePumpMs = 16;                 // 60 frames a second, like the sim
            string err = IbtReplay.Start(ibt, 1, 60, 0);        // 60 s in: lap 1 under green (the fixture starts in the formation lap)
            Ok("the 12 Nov fixture replays at 1x from 60 s (" + Path.GetFileName(ibt) + ")", err == null, err);
            Thread.Sleep(1500);
            List<string[]> evs = Listen("/stream?set=race", 5000);
            List<string[]> frames = evs.FindAll(delegate (string[] e) { return e[1] == "message"; });
            Ok("15 frames a second over 5 s (" + frames.Count + " frames; 70-80 = 15 +-1 a second)", frames.Count >= 70 && frames.Count <= 80, "");
            Ok("no raw session YAML on the race set (the parsed session is in the state)", !evs.Exists(delegate (string[] e) { return e[1] == "session"; }), "");
            Dictionary<string, object> f0 = frames.Count > 0 ? Obj(frames[frames.Count - 1][2]) : null;
            Dictionary<string, object> vals = Sub(f0, "v");
            List<string> keys = vals == null ? new List<string>() : new List<string>(vals.Keys);
            List<string> missing = new List<string>(), extra = new List<string>();
            foreach (string n in Sdk.RaceSet) if (!keys.Contains(n)) missing.Add(n);
            foreach (string k in keys) if (Array.IndexOf(Sdk.RaceSet, k) < 0) extra.Add(k);
            Ok("exactly the 28 keys on the wire (" + keys.Count + "; a channel the file lacks is null): missing [" + string.Join(" ", missing.ToArray()) + "], extra [" + string.Join(" ", extra.ToArray()) + "]", keys.Count == 28 && missing.Count == 0 && extra.Count == 0 && Sdk.RaceSet.Length == 28, "");
            bool arrays = true; string badArr = "";
            foreach (string n in Sdk.RaceSet)
                if (n.StartsWith("CarIdx")) { object[] arr = vals != null && vals.ContainsKey(n) ? vals[n] as object[] : null; if (arr == null || arr.Length != 64) { arrays = false; badArr += n + " "; } }
            Ok("the 8 CarIdx channels are 64-slot arrays", arrays, badArr);
            int pi = vals != null && vals["PlayerCarIdx"] != null ? Convert.ToInt32(vals["PlayerCarIdx"], Inv) : -1;
            object[] lapPct = vals != null ? vals["CarIdxLapDistPct"] as object[] : null;
            Ok("Peter's slot (" + pi + ") has his lap fraction; his class id is in CarIdxClass", pi == 2 && lapPct != null && Convert.ToDouble(lapPct[2], Inv) > 0 && Convert.ToInt32(((object[])vals["CarIdxClass"])[2], Inv) == 4012, "");
            int bytes = frames.Count > 0 ? Encoding.UTF8.GetByteCount(frames[frames.Count - 1][2]) : 0;
            Info("one race frame is " + bytes + " bytes; " + (bytes * 15 / 1024.0).ToString("0.0", Inv) + " KB a second");
            List<string[]> old = Listen("/stream?vars=Lap,Speed,FuelLevel,NoSuchVar", 1500);
            List<string[]> oldF = old.FindAll(delegate (string[] e) { return e[1] == "message"; });
            Dictionary<string, object> ov = oldF.Count > 0 ? Sub(Obj(oldF[oldF.Count - 1][2]), "v") : null;
            Ok("?vars= as before: only the asked names that exist (no null for a missing one), and the raw YAML event once", ov != null && ov.Count == 3 && ov.ContainsKey("Speed") && !ov.ContainsKey("NoSuchVar") && old.FindAll(delegate (string[] e) { return e[1] == "session"; }).Count == 1, ov == null ? "none" : string.Join(",", new List<string>(ov.Keys).ToArray()));
            List<string[]> both = Listen("/stream?set=race&vars=Speed", 800);
            Dictionary<string, object> bv = both.FindAll(delegate (string[] e) { return e[1] == "message"; }).Count > 0 ? Sub(Obj(both.FindAll(delegate (string[] e) { return e[1] == "message"; })[0][2]), "v") : null;
            Ok("set=race wins over vars= (still exactly the 28)", bv != null && bv.Count == 28 && !bv.ContainsKey("Speed"), "");

            Console.WriteLine("Section 3b. the stream's beat after a stall (no frames for 1.5 s)");
            Thread stall = new Thread(delegate () { Thread.Sleep(1000); Sdk.FakePumpMs = 1500; Thread.Sleep(1300); Sdk.FakePumpMs = 16; });
            stall.IsBackground = true; stall.Start();
            List<string[]> se = Listen("/stream?set=race", 4500).FindAll(delegate (string[] e) { return e[1] == "message"; });
            List<long> ft = new List<long>(); foreach (string[] e in se) ft.Add(long.Parse(e[0], Inv));
            int gi = 1; for (int i = 2; i < ft.Count; i++) if (ft[i] - ft[i - 1] > ft[gi] - ft[gi - 1]) gi = i;
            long gap = ft.Count > 1 ? ft[gi] - ft[gi - 1] : 0; int after = 0;
            for (int i = gi; i < ft.Count; i++) if (ft[i] - ft[gi] < 300) after++;
            Ok("after a " + gap + " ms stall the stream sends " + after + " frames in the next 300 ms (15 Hz = 5, one frame of catch-up allowed: at most 6, no burst)", gap >= 1000 && after <= 6 && after >= 3, "");

            Console.WriteLine("Section 4. the race state part");
            Thread.Sleep(400);
            string rj = StateBuilder.RacePart();
            Info("race part at 1x: " + rj);
            Dictionary<string, object> st = Obj(Get("/state"));
            Dictionary<string, object> race = Sub(st, "race");
            Ok("GET /state carries the race part during a session", race != null, "");
            string[] top = { "on", "type", "multiclass", "me", "pos", "of", "classPos", "classOf", "lapNum", "laps", "toGo", "timeLeft", "clock", "inc", "flags", "pit", "units", "fuel", "lap" };
            string[][] subs = { new[] { "me", "idx", "num", "name", "classId", "classColor" }, new[] { "inc", "n", "limit" }, new[] { "flags", "caution", "green", "raw" },
                                new[] { "pit", "onRoad", "limiter", "loss", "rejoin" }, new[] { "fuel", "state", "measured", "stale", "level", "burn", "burnLong", "lapsOfFuel", "toEnd", "spare", "margin", "save", "stops", "window" },
                                new[] { "lap", "last", "best", "lastIsBest", "delta", "deltaOk" } };
            List<string> miss = new List<string>();
            Dictionary<string, object> ro = Obj(rj);
            foreach (string k in top) if (ro == null || !ro.ContainsKey(k)) miss.Add(k);
            foreach (string[] s in subs) { Dictionary<string, object> so = Sub(ro, s[0]); for (int i = 1; i < s.Length; i++) if (so == null || !so.ContainsKey(s[i])) miss.Add(s[0] + "." + s[i]); }
            Ok("every contract name is there: missing [" + string.Join(" ", miss.ToArray()) + "]", miss.Count == 0, "");
            int lapKeys = 0; for (int at = rj.IndexOf("\"lap\":", StringComparison.Ordinal); at >= 0; at = rj.IndexOf("\"lap\":", at + 1, StringComparison.Ordinal)) lapKeys++;
            Ok("the lap number is \"lapNum\", \"lap\" is the times object, written once (no duplicate key); units " + Convert.ToString(ro["units"], Inv) + " (the file has no DisplayUnits: metric)", lapKeys == 1 && ro["lap"] is Dictionary<string, object> && ro["lapNum"] is int && (string)ro["units"] == "metric" && Sub(ro, "pit")["limiter"] is bool, "");
            Dictionary<string, object> rme = Sub(ro, "me");
            Ok("me = Peter (idx 2, number 3, Adamis), type Race, one class, 1 car in the world (a disk replay has only his own slot), lap 1, a position, timed: laps null, timeLeft and toGo set, incident limit 17",
                rme != null && Convert.ToInt32(rme["idx"], Inv) == 2 && (string)rme["num"] == "3" && (string)rme["name"] == "Adamis" && (string)ro["type"] == "Race" && !(bool)ro["multiclass"]
                && Convert.ToInt32(ro["of"], Inv) == 1 && Convert.ToInt32(ro["classOf"], Inv) == 1 && Convert.ToInt32(ro["lapNum"], Inv) == 1 && ro["pos"] != null
                && ro["laps"] == null && ro["timeLeft"] != null && ro["toGo"] != null && Convert.ToInt32(Sub(ro, "inc")["limit"], Inv) == 17, "");
            Ok("pit.loss and pit.rejoin stay null (W2-3's hook is not wired here)", Sub(ro, "pit")["loss"] == null && Sub(ro, "pit")["rejoin"] == null, "");
            IbtReplay.Stop(); Thread.Sleep(300);

            // 20x: the part changes at most 4 times a second (the builder's tick), however fast the frames come
            err = IbtReplay.Start(ibt, 20, 0, 0);
            List<string[]> pushes = Listen("/stream?state=1", 6000);
            List<long> raceAt = new List<long>();
            string lastFuel = "";
            foreach (string[] e in pushes)
            {
                if (e[1] != "state") continue;
                Dictionary<string, object> po = Obj(e[2]);
                if (po != null && po.ContainsKey("race") && !po.ContainsKey("full")) { raceAt.Add(long.Parse(e[0], Inv)); Dictionary<string, object> rf = Sub(Sub(po, "race"), "fuel"); if (rf != null) lastFuel = J.Serialize(rf); }
            }
            // the builder bumps at most every 250 ms; arrival times jitter by a few ms, so a window is 950 ms
            int worst = 0; long minGap = long.MaxValue;
            for (int i = 0; i < raceAt.Count; i++) { int k = 0; for (int j = i; j < raceAt.Count && raceAt[j] - raceAt[i] < 950; j++) k++; worst = Math.Max(worst, k); if (i > 0) minGap = Math.Min(minGap, raceAt[i] - raceAt[i - 1]); }
            double span = raceAt.Count > 1 ? (raceAt[raceAt.Count - 1] - raceAt[0]) / 1000.0 : 0;
            Ok("at 20x the race part changed " + raceAt.Count + " times (" + (span > 0 ? ((raceAt.Count - 1) / span).ToString("0.00", Inv) : "?") + " a second), at most " + worst + " in any 950 ms, closest two " + minGap + " ms apart (ceiling 4 a second)",
                raceAt.Count >= 8 && worst <= 4 && span > 0 && (raceAt.Count - 1) / span <= 4.05, "");
            Info("the last fuel pushed at 20x: " + lastFuel);
            IbtReplay.Stop(); Sdk.FakeEnd(); Thread.Sleep(600);
            Ok("after the session the race part is null", StateBuilder.RacePart() == "null", "");

            Console.WriteLine("  " + pass + " passed, " + fail + " failed");
            Console.WriteLine("DONE");
            Environment.Exit(fail > 0 ? 1 : 0);
            return 0;
        }
    }
}
