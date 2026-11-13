// Offline harness for tests\lap-truth-test.ps1 (W0-6 review finding 8): feeds the frames of a real .ibt, in order, through the live judge
// (dash\src\lapstore.cs LiveJudge) the way its two users call it, and compares every verdict with the file judge (LapStore.Read):
//   recorder order (recorder.cs TrackLaps): every frame (60 Hz); Poll first, then Line at the lap counter +1 with the previous frame's
//     LapLastLapTime and LapBestLapTime; every lap is judged; a dirty lap (tow / reset / joined part-way) never counts; a disconnect = Reset.
//   PB reference order (refs.cs Tick): ticks at 30 Hz or 4 Hz (the delta bar shown / hidden); Line only at a clean wrap of a lap that started
//     clean (a dirty lap, a pit lap is never judged); Poll each tick; off track = Cancel.
// Synthetic changes on top of the real frames: --pit N (OnPitRoad set in the middle of lap N), --dirty N (lap N is a tow: not judged by refs,
// dirty for the recorder), --reconnect N (the sim connection drops for 3 s in the middle of lap N).
//   live-judge.exe <ibt> [--pit N] [--dirty N] [--reconnect N]      prints ok / FAIL lines, then LIVE-DONE
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace IRDash
{
    static class Json { public static string Str(string s) { return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; } }
    static class Json_ { public static string S(string s) { return Json.Str(s ?? ""); } }
    static class Log { public static void W(string m) { } }

    static class LiveJudgeHarness
    {
        static int fails;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static void Ok(string what, bool good, string detail) { if (!good) fails++; Console.WriteLine((good ? "ok " : "FAIL ") + what + (good ? "" : " (" + detail + ")")); }
        static int Arg(string[] a, string k) { for (int i = 0; i + 1 < a.Length; i++) if (a[i] == k) return int.Parse(a[i + 1], Inv); return -99; }
        static string V(LapRec r) { return r == null ? "none" : r.Time.ToString("0.000", Inv) + " " + (r.Counted ? "counted" : "not-counted") + " " + (r.Why.Length > 0 ? r.Why : "-"); }

        static int Main(string[] a)
        {
            int pitLap = Arg(a, "--pit"), dirtyLap = Arg(a, "--dirty"), dropLap = Arg(a, "--reconnect");
            FileLaps truth; double[][] c;
            using (IbtFile t = IbtFile.Open(a[0], true))
            {
                truth = LapStore.Read(t);
                c = t.Channels(new string[] { "SessionTime", "Lap", "LapDistPct", "IsOnTrack", "OnPitRoad", "LapLastLapTime", "LapBestLapTime", "PlayerCarMyIncidentCount" }, 0, t.Records);
            }
            double[] st = c[0], lap = c[1], pct = c[2], on = c[3], pit = c[4], llt = c[5], best = c[6], inc = c[7];
            int n = st.Length;
            Dictionary<int, LapRec> file = new Dictionary<int, LapRec>();
            foreach (LapRec l in truth.Laps) file[l.N] = l;
            // synthetic: a pit stop in the middle of lap pitLap, a 3 s disconnect in the middle of lap dropLap
            int dropFrom = -1, dropTo = -1;
            for (int i = 1; i < n; i++)
            {
                if ((int)lap[i] == pitLap && pct[i] > 0.45 && pct[i] < 0.55) pit[i] = 1;
                if ((int)lap[i] == dropLap && pct[i] > 0.5 && dropFrom < 0) { dropFrom = i; dropTo = i + 180; }
            }

            // ---- the recorder's order ----
            Dictionary<int, LapRec> rec = new Dictionary<int, LapRec>();
            {
                LiveJudge j = new LiveJudge();
                double prevLlt = 0, prevBest = 0, lineAt = 0; int curLap = -1, incStart = 0; bool curPit = false, curDirty = true, conn = true; int pendLap = -1; bool pendDirty = false;
                for (int i = 0; i < n; i++)
                {
                    bool c2 = !(i >= dropFrom && i < dropTo);
                    if (!c2) { if (conn) { conn = false; if (pendLap >= 0) { rec[pendLap] = null; pendLap = -1; } j.Reset(); curLap = -1; } continue; }
                    conn = true;
                    double t = st[i];
                    if (pendLap >= 0) { LapRec r = j.Poll(t, llt[i], best[i]); if (r != null) { if (pendDirty) { r.Counted = false; r.Why = "reset"; } rec[pendLap] = r; pendLap = -1; } }
                    if (on[i] == 0) { curLap = -1; prevLlt = llt[i]; prevBest = best[i]; continue; }
                    int l = (int)lap[i];
                    if (curLap < 0) { curLap = l; curDirty = !(pct[i] < 0.05); curPit = false; incStart = (int)inc[i]; lineAt = t; }
                    else if (l == curLap + 1)
                    {
                        if (pendLap >= 0) { rec[pendLap] = null; pendLap = -1; }      // forced, no time
                        j.Line(curLap, t, t - lineAt, prevBest, curPit, (int)inc[i] > incStart, 0, prevLlt);
                        pendLap = curLap; pendDirty = curDirty || curLap == dirtyLap;
                        curLap = l; curDirty = false; curPit = false; incStart = (int)inc[i]; lineAt = t;
                    }
                    if (pit[i] != 0) curPit = true;
                    prevLlt = llt[i]; prevBest = best[i];
                }
            }

            // ---- the PB reference's order, at 30 Hz and at 4 Hz ----
            foreach (int every in new int[] { 2, 15 })
            {
                Dictionary<int, LapRec> refs = new Dictionary<int, LapRec>();
                LiveJudge j = new LiveJudge();
                int lastLap = -1, incStart = 0, penLap = -1; double lastPct = -1, lastLlt = 0, lastBest = 0, lapT0 = 0; bool started = false, dirty = false, penOn = false;
                for (int i = 0; i < n; i += every)
                {
                    if (i >= dropFrom && i < dropTo) continue;           // no frames while disconnected (refs resets on reconnect via ResetLap below)
                    double t = st[i];
                    bool inPits = pit[i] != 0;
                    if (on[i] == 0) { started = false; dirty = false; lastLap = -1; lastPct = -1; penOn = false; j.Cancel(); continue; }
                    int l = (int)lap[i];
                    bool wrapped = lastLap >= 0 && l != lastLap && lastPct > 0.9 && pct[i] < 0.1;
                    if (wrapped)
                    {
                        if (started && !dirty && lastLap != dirtyLap)
                        {
                            penOn = true; penLap = lastLap;
                            j.Line(lastLap, t, t - lapT0, lastBest, false, (int)inc[i] > incStart, 0, lastLlt);
                        }
                        started = !inPits; dirty = inPits; incStart = (int)inc[i]; lapT0 = t;
                    }
                    else if (lastPct >= 0) { double dp = pct[i] - lastPct; if (dp < -0.02 || dp > 0.1) { dirty = true; started = false; } }
                    if (inPits) { dirty = true; started = false; }
                    lastLap = l; lastPct = pct[i];
                    lastLlt = llt[i];
                    if (penOn) { LapRec r = j.Poll(t, llt[i], best[i]); if (r != null) { penOn = false; refs[penLap] = r; } }
                    lastBest = best[i];
                }
                string who = every == 2 ? "PB reference 30 Hz" : "PB reference 4 Hz";
                foreach (KeyValuePair<int, LapRec> kv in refs)
                {
                    if (kv.Key == pitLap || kv.Key == dirtyLap) { Ok(who + ": lap " + kv.Key + " (pit / tow) is never judged", false, V(kv.Value)); continue; }
                    LapRec f; file.TryGetValue(kv.Key, out f);
                    if (f == null) continue;      // a lap the file does not hold whole (the one cut by the disconnect)
                    Ok(who + ": lap " + kv.Key + " " + V(kv.Value) + " = file " + V(f), V(kv.Value) == V(f), "live " + V(kv.Value) + " file " + V(f));
                }
                Ok(who + ": the pit lap and the tow lap were not judged", !refs.ContainsKey(pitLap) && !refs.ContainsKey(dirtyLap), "");
                LapRec b9; refs.TryGetValue(9, out b9);
                Ok(who + ": lap 9 is the new best, counted 93.832 (a PB reference would be adopted)", b9 != null && b9.Counted && Math.Abs(b9.Time - 93.832) < 0.0005, V(b9));
            }

            foreach (KeyValuePair<int, LapRec> kv in rec)
            {
                LapRec f; file.TryGetValue(kv.Key, out f);
                string what = "recorder: lap " + kv.Key + " " + V(kv.Value);
                if (kv.Key == pitLap) Ok(what + " (synthetic pit stop) is not counted, reason pit", kv.Value != null && !kv.Value.Counted && kv.Value.Why == "pit", V(kv.Value));
                else if (kv.Key == dirtyLap) Ok(what + " (synthetic tow) is not counted", kv.Value != null && !kv.Value.Counted, V(kv.Value));
                else if (kv.Key == dropLap || kv.Key <= 0) continue;     // cut by the disconnect / lap 0: no lap for either judge
                else if (f != null) Ok(what + " = file " + V(f), V(kv.Value) == V(f), "live " + V(kv.Value) + " file " + V(f));
            }
            LapRec r9; rec.TryGetValue(9, out r9);
            Ok("recorder: after the reconnect, lap 9 is still the counted 93.832", r9 != null && r9.Counted && Math.Abs(r9.Time - 93.832) < 0.0005, V(r9));
            Console.WriteLine("LIVE-DONE");
            return fails == 0 ? 0 : 1;
        }
    }
}
