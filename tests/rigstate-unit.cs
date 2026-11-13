// tests\rigstate-test.ps1 compiles dash\src\rigstate.cs with this file: the truth table of RigState and the /rig/state JSON.
// A pretend SDK frame (RigState.Feed), a pretend sim process (RigState.SimProbe), a pretend clock and a START mark in a temp folder.
using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class Log { public static readonly List<string> Lines = new List<string>(); public static void W(string m) { lock (Lines) Lines.Add(m); } }

    static class RigStateUnit
    {
        static int pass, fail;
        static void Check(string what, bool ok) { if (ok) { pass++; Console.WriteLine("  ok    " + what); } else { fail++; Console.WriteLine("  FAIL  " + what); } }

        static bool simUp;
        static DateTime now = new DateTime(2026, 11, 13, 12, 0, 0, DateTimeKind.Utc);
        static void Tick(double sec) { now = now.AddSeconds(sec); }

        // one row of the table: SDK connected, on track, pretend session, sim process, START mark age in minutes (-1 = none, "TEST" = a test's mark)
        static void Set(bool conn, bool track, bool pretend, bool sim, string mark)
        {
            simUp = sim;
            if (mark == null) { if (File.Exists(RigState.MarkFile)) File.Delete(RigState.MarkFile); }
            else File.WriteAllText(RigState.MarkFile, mark);
            Tick(3);                         // past the 250 ms throttle: the next question may look again
            RigState.Probe();
            RigState.Feed(conn, track, pretend);
        }
        static string Mark(double minutesAgo, string who) { return now.AddMinutes(-minutesAgo).Ticks + "\t" + who; }

        static int Main(string[] args)
        {
            string dir = args.Length > 0 ? args[0] : Path.GetTempPath();
            RigState.MarkFile = Path.Combine(dir, "start-mark.txt");
            RigState.SimProbe = delegate { return simUp; };
            RigState.Clock = delegate { return now; };

            Console.WriteLine("1. the truth table");
            Set(false, false, false, false, null);
            Check("nothing on: not busy, no reason", !RigState.SimRunning && !RigState.SessionOn && !RigState.Driving && !RigState.StartPressed && !RigState.Busy && RigState.BusyWhy == null);
            Set(false, false, false, true, null);
            Check("sim running, no SDK yet (loading): SimRunning and Busy, not SessionOn", RigState.SimRunning && !RigState.SessionOn && !RigState.Driving && RigState.Busy && RigState.BusyWhy == "the sim is running");
            Set(true, false, false, true, null);
            Check("connected in the garage: SessionOn, not Driving, Busy (the case IsDriving missed)", RigState.SessionOn && !RigState.Driving && RigState.Busy && RigState.BusyWhy == "a session is on");
            Set(true, true, false, true, null);
            Check("on track: Driving and SessionOn", RigState.Driving && RigState.SessionOn && RigState.BusyWhy == "Peter is driving");
            Set(true, true, false, false, null);
            Check("SDK says connected but the sim is gone (stale memory): no session, not driving", !RigState.SessionOn && !RigState.Driving && !RigState.Busy && RigState.BusyWhy == null);
            Set(false, true, false, true, null);
            Check("on track without a connection is not driving", !RigState.Driving && !RigState.SessionOn && RigState.Busy);
            Set(false, false, false, false, Mark(2, "START"));
            Check("a START key 2 minutes ago: StartPressed and Busy, no session", RigState.StartPressed && RigState.Busy && !RigState.SessionOn && RigState.BusyWhy == "a START key was pressed in the last 10 minutes");
            Set(false, false, false, false, Mark(11, "START"));
            Check("a START key 11 minutes ago: free again", !RigState.StartPressed && !RigState.Busy);
            Set(false, false, false, false, Mark(1, "TEST"));
            Check("a test's own START mark does not count", !RigState.StartPressed && !RigState.Busy);
            Set(false, false, false, false, "garbage");
            Check("a broken mark file does not count (and does not throw)", !RigState.StartPressed);
            Set(true, false, true, false, null);
            Check("the test hook's pretend session counts as a session (guards refuse) ...", RigState.SessionOn && RigState.Busy);
            Check("... but not as a REAL one: the test hook stays open (Sdk.RealBusy)", RigState.RealBusyWhy() == null);
            Set(true, true, true, false, null);
            Check("pretend session on track: Driving", RigState.Driving);
            Set(true, false, false, true, null);
            Check("a real session closes the test hook", RigState.RealBusyWhy() == "iRacing is connected");
            Set(false, false, false, true, null);
            Check("the sim alone closes the test hook", RigState.RealBusyWhy() == "the sim is running");
            Set(false, false, false, false, Mark(0.5, "START"));
            Check("a START mark closes the test hook", RigState.RealBusyWhy() == "a START key was pressed in the last 10 minutes");

            Console.WriteLine("2. a free answer is never stale; a busy one is at most 2 s old");
            Set(false, false, false, false, null);
            simUp = true;                                    // the sim starts between two probes
            Check("within 250 ms of the last look the cached answer stands", !RigState.SimRunning);
            Tick(0.3);
            Check("after that, a 'not running' answer looks again first", RigState.SimRunning);
            simUp = false; Tick(0.3);
            Check("a 'running' answer is not looked at again on every call (that is the prober's job)", RigState.SimRunning);
            RigState.Probe();
            Check("the prober's next look clears it", !RigState.SimRunning);

            Console.WriteLine("3. /rig/state");
            Set(false, false, false, false, null);
            Tick(10); Set(true, false, false, true, null);
            DateTime onAt = now;
            Tick(5); RigState.Feed(true, true, false);
            Dictionary<string, object> j = new JavaScriptSerializer().DeserializeObject(RigState.Json()) as Dictionary<string, object>;
            Check("it is JSON", j != null);
            if (j != null)
            {
                string[] keys = { "simRunning", "sessionOn", "driving", "startPressed", "busy", "busyWhy", "since" };
                bool all = true; foreach (string k in keys) if (!j.ContainsKey(k)) all = false;
                Check("it has simRunning, sessionOn, driving, startPressed, busy, busyWhy, since", all);
                Check("its values match the state", (bool)j["simRunning"] && (bool)j["sessionOn"] && (bool)j["driving"] && !(bool)j["startPressed"] && (bool)j["busy"] && (string)j["busyWhy"] == "Peter is driving");
                Dictionary<string, object> since = j["since"] as Dictionary<string, object>;
                Check("since: when the session came on and when he got on track", since != null && (string)since["sessionOn"] == onAt.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") && (string)since["driving"] == now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"));
            }
            Set(false, false, false, false, null);
            j = new JavaScriptSerializer().DeserializeObject(RigState.Json()) as Dictionary<string, object>;
            Check("nothing on: busy false, busyWhy null", j != null && !(bool)j["busy"] && j["busyWhy"] == null);

            Console.WriteLine("4. refusals are logged once a minute at most");
            Log.Lines.Clear();
            Set(true, false, false, true, null);
            string said = null; for (int i = 0; i < 5; i++) said = RigState.Refuse("mdfindcar");
            Check("the answer is one plain sentence", said == "Not while a session is on.");
            Check("five refusals in a row: one log line", Log.Lines.Count == 1 && Log.Lines[0].Contains("mdfindcar") && Log.Lines[0].Contains("a session is on"));
            Tick(61); RigState.Refuse("mdfindcar");
            Check("a minute later: one more", Log.Lines.Count == 2);

            Console.WriteLine(pass + " passed, " + fail + " failed.");
            return fail == 0 ? 0 : 1;
        }
    }
}
