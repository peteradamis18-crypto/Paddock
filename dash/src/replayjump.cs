// Replay jump (P2 of docs\PLAN-v3.md): "SEE IN iRACING" - take iRacing's own replay to a moment Paddock knows from its telemetry
// (an event in the analysis workbench, a pass on the RACE page), 3 s before it, camera on his car or on the car that passed him, playing at 1x.
// Only SDK broadcast messages (ReplaySearchSessionTime, CamSwitchNum, ReplaySetPlaySpeed): no clicks, no keys, no focus. While the test hook's
// pretend session is on they are RECORDED (/api/test/replaylog), never broadcast - the same switch the REPLAY screen uses.
//   GET /share/jump?id=<telemetry file | Vault lap id>&lap=<n>&t=<seconds into that lap>      (an event on a lap)
//   GET /share/jump?id=<...>&st=<session time in s>                                              (a pass of the race log: its t is session time)
//        &car=<CarIdx> (the car to watch; absent / me = his own)  &lead=<seconds before, default 3>  &dry=1 (only answer whether it can be done)
// It can be done only when the session that telemetry came from is the one iRacing has open right now (same SessionUniqueID, or the same
// SubSessionID of a race weekend) and he is out of the car. Otherwise {"ok":false,"why":"..."} in plain words (HTTP 409 when it was really asked for).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace IRDash
{
    static partial class Replay
    {
        static string JQ(Dictionary<string, string> q, string k) { string v; return q != null && q.TryGetValue(k, out v) && v != null ? v : ""; }
        static string JErr(string m) { return "{\"error\":" + Json_.S(m) + "}"; }

        // is the session of this event the one the sim has now, and may we touch the replay?
        static bool CanJump(ShareEv ev, Snap s, double target, out int liveUnique, out int liveSub, out string why)
        {
            why = ""; liveUnique = 0; liveSub = 0;
            if (!s.Connected) { why = "No session open in iRacing"; return false; }
            if (s.Driving) { why = "Not while driving"; return false; }
            liveUnique = (int)Hv(s.F, "SessionUniqueID");
            liveSub = IntOf(Val(Section(s.F.SessionYaml ?? "", "WeekendInfo"), "SubSessionID"), 0);
            bool sameUnique = ev.Unique > 0 && liveUnique == ev.Unique, sameWeekend = ev.Sub > 0 && liveSub == ev.Sub;
            if (!sameUnique && !sameWeekend) { why = "Another session is open in iRacing"; return false; }
            if (OnTape(s).FindIndex(delegate (Ses e) { return e.Num == ev.SessNum; }) < 0) { why = "Not on iRacing's replay"; return false; }
            double len = SessionLen(s, ev.SessNum);
            if (len > 1 && target > len + 2) { why = "Past the end of the replay"; return false; }
            return true;
        }

        public static string JumpRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            string id = JQ(q, "id"); bool dry = JQ(q, "dry") == "1";
            CultureInfo inv = CultureInfo.InvariantCulture;
            int lap = 0; int.TryParse(JQ(q, "lap"), NumberStyles.Integer, inv, out lap);
            double t = 0, st = 0, lead = 3, ld;
            bool hasT = double.TryParse(JQ(q, "t"), NumberStyles.Float, inv, out t), hasSt = double.TryParse(JQ(q, "st"), NumberStyles.Float, inv, out st);
            if (double.TryParse(JQ(q, "lead"), NumberStyles.Float, inv, out ld) && ld >= 0 && ld <= 30) lead = ld;
            if (id.Length == 0 || (!hasT && !hasSt)) { code = 400; return JErr("id and t (or st) are needed"); }
            ShareEv ev = Analysis.ShareEvent(id, lap, t, hasT, st, hasSt && !hasT);
            if (ev.Err.Length > 0) { code = 404; return JErr(ev.Err); }

            Snap s = Read();
            double target = Math.Max(0, ev.SessTime - lead);
            int ms = (int)Math.Round(target * 1000);
            int liveUnique, liveSub; string why;
            bool ok = CanJump(ev, s, target, out liveUnique, out liveSub, out why);
            string head = "{\"ok\":" + B(ok) + ",\"why\":" + Json_.S(why) + ",\"driving\":" + B(s.Driving) + ",\"session\":" + ev.SessNum + ",\"sessionTime\":" + ev.SessTime.ToString("0.000", inv) +
                          ",\"timeMs\":" + ms + ",\"unique\":" + ev.Unique + ",\"sub\":" + ev.Sub + ",\"liveUnique\":" + liveUnique + ",\"liveSub\":" + liveSub + ",\"dry\":" + B(dry);
            if (!ok) { if (!dry) code = 409; return head + ",\"sent\":false}"; }
            if (dry) return head + ",\"sent\":false}";
            if (Echo("jump|" + id + "|" + ms + "|" + JQ(q, "car"))) return head + ",\"sent\":true,\"echo\":true}";

            // the car to watch: his own unless the caller names another that is in the session
            Drv cam = null; string want = JQ(q, "car");
            int ci;
            if (want.Length > 0 && want != "me" && int.TryParse(want, NumberStyles.Integer, inv, out ci)) { cam = FindDrv(ci); if (cam != null && cam.Pace) cam = null; }
            if (cam == null) cam = FindDrv(s.Me);
            Seq sq = new Seq(); int g, cm;
            if ((s.CamState & AutoShot) != 0 && cam != null)             // iRacing's TV director would pick another camera a few seconds later
            {
                int bits = (s.CamState & Settable) & ~AutoShot; sq.M(2, bits, 0); SetHold("CamCameraState", bits);
            }
            sq.M(12, ev.SessNum, ms);
            if (cam != null) { CamSpec(s, out g, out cm); sq.W(100).M(1, cam.Raw, Pack(g, cm)); SetHold("CamCarIdx", cam.Idx); }
            sq.W(100).M(3, 1, 0);
            SetHold("IsReplayPlaying", 1); SetHold("ReplaySessionNum", ev.SessNum); SetHold("ReplaySessionTime", target); SetSpeedHold(1, false);
            Log.W("replay: jump to session " + ev.SessNum + " at " + target.ToString("0.0", inv) + " s (" + (hasT ? "lap " + lap + " +" + t.ToString("0.0", inv) + " s" : "session time " + st.ToString("0.0", inv)) + ")" + (Recording ? " (pretend session, not sent)" : "") + " -> " + sq.Describe());
            Go(sq);
            return head + ",\"sent\":true,\"car\":" + (cam != null ? cam.Idx : -1) + "}";
        }
    }
}
