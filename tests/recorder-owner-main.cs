// Entry point for tests\recorder-owner-test.ps1 only: compiled together with dash\src\*.cs (csc /main:IRDash.RecorderOwnerMain)
// into a throw-away exe in %TEMP%. Sets the recorder's private state by reflection and calls Recorder.AdoptRun, the one
// place that decides which session a run's segments belong to (W0-11). Prints "ok ..." / "FAIL ..." lines and DONE.
using System;
using System.Collections.Generic;
using System.Reflection;

namespace IRDash
{
    static class RecorderOwnerMain
    {
        const BindingFlags Any = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
        static int fails;
        static void Ok(string what, bool cond, string why)
        {
            if (cond) Console.WriteLine("ok " + what);
            else { fails++; Console.WriteLine("FAIL " + what + (why.Length > 0 ? " (" + why + ")" : "")); }
        }

        static FieldInfo F(string name) { return typeof(Recorder).GetField(name, Any); }
        static void Set(string name, object v) { F(name).SetValue(null, v); }
        static List<RecSeg> Segs() { return (List<RecSeg>)F("segs").GetValue(null); }
        static List<RecSess> Finishing() { return (List<RecSess>)F("finishing").GetValue(null); }
        static void Adopt(RecSess s) { typeof(Recorder).GetMethod("AdoptRun", Any).Invoke(null, new object[] { s }); }

        static void Reset()
        {
            Segs().Clear(); Finishing().Clear(); Set("openSess", null); Set("run", null); Set("ff", null);
        }

        static RecSeg Seg(RecRun r, int i)
        {
            RecSeg g = new RecSeg(); g.Run = r.No; g.Name = "rec-" + r.No + "-" + i + ".mkv"; g.Closed = true; g.Size = 1000; g.Owner = r;
            return g;
        }

        static RecSess Sess(string id) { RecSess s = new RecSess(); s.Id = id; return s; }

        static int Main(string[] a)
        {
            if (F("run") == null || F("segs") == null || F("finishing") == null || F("openSess") == null || typeof(Recorder).GetMethod("AdoptRun", Any) == null)
            { Console.WriteLine("FAIL the recorder fields or AdoptRun were not found by reflection"); return 1; }

            // 1. today's sequence: run A recorded S1 (8 closed segments), S1 ended and waits in finishing, ffmpeg is stopped, S2 begins
            Reset();
            RecRun A = new RecRun(); A.No = 1;
            RecSess S1 = Sess("S1"); A.Sess = S1; S1.Open = false;
            for (int i = 0; i < 8; i++) { RecSeg g = Seg(A, i); Segs().Add(g); S1.Segs.Add(g); }
            Finishing().Add(S1); Set("run", A);
            RecSess S2 = Sess("S2"); Set("openSess", S2);
            Adopt(S2);
            Ok("1. a new session does not adopt the previous session's run: S2 has no segments", S2.Segs.Count == 0, "S2 has " + S2.Segs.Count);
            Ok("1. the old run still belongs to S1", A.Sess == S1, "A.Sess is " + (A.Sess == null ? "null" : A.Sess.Id));
            Ok("1. S1 still holds its 8 segments", S1.Segs.Count == 8, "S1 has " + S1.Segs.Count);

            // 2. ffmpeg started before the session was known: run B has no session and 3 closed segments, S3 begins
            Reset();
            RecRun B = new RecRun(); B.No = 2;
            for (int i = 0; i < 3; i++) Segs().Add(Seg(B, i));
            Set("run", B);
            RecSess S3 = Sess("S3"); Set("openSess", S3);
            Adopt(S3);
            Ok("2. a run with no session is adopted by the first one: B.Sess is S3", B.Sess == S3, "B.Sess is " + (B.Sess == null ? "null" : B.Sess.Id));
            Ok("2. S3 has the run's 3 segments", S3.Segs.Count == 3, "S3 has " + S3.Segs.Count);
            Adopt(S3);
            Ok("2. adopting twice does not add them twice", S3.Segs.Count == 3, "S3 has " + S3.Segs.Count);
            RecSess S3b = Sess("S3b"); Set("openSess", S3b);
            Adopt(S3b);
            Ok("2. a later session cannot take B back (B.Sess stays S3)", B.Sess == S3 && S3b.Segs.Count == 0, "B.Sess " + (B.Sess == null ? "null" : B.Sess.Id) + ", S3b has " + S3b.Segs.Count);

            // 3. a segment a finishing session already holds is never adopted, even when its run has no session
            Reset();
            RecRun C = new RecRun(); C.No = 3;
            RecSess S4 = Sess("S4"); S4.Open = false;
            RecSeg held = Seg(C, 0), free1 = Seg(C, 1), free2 = Seg(C, 2);
            Segs().Add(held); Segs().Add(free1); Segs().Add(free2);
            S4.Segs.Add(held); Finishing().Add(S4); Set("run", C);
            RecSess S5 = Sess("S5"); Set("openSess", S5);
            Adopt(S5);
            Ok("3. the segment S4 (finishing) holds is not adopted by S5", !S5.Segs.Contains(held), "");
            Ok("3. S4 keeps it", S4.Segs.Contains(held) && S4.Segs.Count == 1, "S4 has " + S4.Segs.Count);
            Ok("3. the run's free segments still go to S5", S5.Segs.Count == 2 && S5.Segs.Contains(free1) && S5.Segs.Contains(free2), "S5 has " + S5.Segs.Count);

            // 3b. no run at all: nothing happens
            Reset();
            RecSess S6 = Sess("S6"); Set("openSess", S6);
            Adopt(S6);
            Ok("3b. no run: the session starts empty", S6.Segs.Count == 0, "");

            Reset();
            Console.WriteLine("DONE");
            return fails > 0 ? 1 : 0;
        }
    }
}
