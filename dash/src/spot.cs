using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    // Practice loop in a Test Drive (deck keys SAVE SPOT / BACK TO SPOT, irdeck `spot`): the logic is spotcore.cs, this feeds it every
    // telemetry frame and answers irdeck. SAVE SPOT is iRacing's own Active Reset save (Ctrl+Shift+F1), BACK TO SPOT its run (F2); we
    // only watch the car, so nothing here presses anything in the sim. Each finished try is put on the top screen as a key message.
    static class Spot
    {
        static readonly object gate = new object();
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly SpotCore core = new SpotCore();
        static readonly Queue<SpotSample> ring = new Queue<SpotSample>();      // the last ~4 s of frames, to find where the car was when the key was pressed
        static DateTime savedAt = DateTime.MinValue;
        static string saveKey = "";
        static Thread th;
        static volatile bool stop;

        public static void Start()
        {
            if (th != null) return;
            th = new Thread(Loop); th.IsBackground = true; th.Name = "spot"; th.Priority = ThreadPriority.BelowNormal; th.Start();
        }

        static long NowMs() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }

        static void Loop()
        {
            long seq = 0; bool wasUp = false;
            while (!stop)
            {
                Frame f;
                try { f = Sdk.WaitNext(seq, 400); } catch { Thread.Sleep(200); continue; }
                if (f == null || f.Seq == seq) continue;
                seq = f.Seq;
                try { Tick(f, ref wasUp); } catch (Exception ex) { Log.W("spot: " + ex.Message); Thread.Sleep(50); }
            }
        }

        static void Tick(Frame f, ref bool wasUp)
        {
            if (!f.Connected)
            {
                if (wasUp) { lock (gate) { core.Clear(); ring.Clear(); } wasUp = false; }     // the sim closed: iRacing forgot the saved point too
                return;
            }
            wasUp = true;
            SpotSample s = new SpotSample();
            s.Pct = f.Num("LapDistPct"); s.Speed = f.Num("Speed"); s.Time = f.Num("SessionTime"); s.OnTrack = f.Num("IsOnTrack") != 0; s.Ms = NowMs();
            bool garage = f.Num("IsInGarage") != 0;
            SpotResult r = null;
            lock (gate)
            {
                ring.Enqueue(s); while (ring.Count > 260) ring.Dequeue();
                if (garage && core.Saved) { core.Clear(); Log.W("spot: cleared (the garage forgets the saved point)"); return; }
                r = core.Step(s);
            }
            if (r != null)
            {
                string text = SpotCore.Say(r);
                KeyMsg.Set("spot", text, r.NewBest ? "ok" : "wait");
                Log.W("spot: " + text);
            }
        }

        // ---------- what irdeck asks (GET /api/spot?cmd=...; this PC only) ----------
        public static string Route(Dictionary<string, string> q)
        {
            string cmd, t; q.TryGetValue("cmd", out cmd); q.TryGetValue("t", out t);
            long atMs; if (!long.TryParse(t ?? "", NumberStyles.Integer, Inv, out atMs)) atMs = NowMs();
            switch ((cmd ?? "status").ToLowerInvariant())
            {
                case "save": return Save(atMs);
                case "back": lock (gate) { if (!core.Saved) return Reply(false, "nothing saved yet"); core.Back(atMs); return Reply(true, "ok"); }
                case "clear": lock (gate) { core.Clear(); return Reply(true, "cleared"); }
                default: return StatusJson();
            }
        }

        static string Reply(bool ok, string text) { return "{\"ok\":" + (ok ? "true" : "false") + ",\"text\":" + Json_.S(text) + ",\"status\":" + StatusJson() + "}"; }

        static string StatusJson()
        {
            lock (gate)
            {
                StringBuilder sb = new StringBuilder();
                sb.Append("{\"saved\":").Append(core.Saved ? "true" : "false").Append(",\"running\":").Append(core.Running ? "true" : "false")
                  .Append(",\"starts\":").Append(core.Starts).Append(",\"tries\":").Append(core.Times.Count)
                  .Append(",\"where\":").Append(Json_.S(core.Where))
                  .Append(",\"best\":").Append(double.IsNaN(core.Best) ? "null" : core.Best.ToString("0.000", Inv))
                  .Append(",\"last\":").Append(core.Times.Count > 0 ? core.Times[core.Times.Count - 1].ToString("0.000", Inv) : "null")
                  .Append(",\"savedAgoMs\":").Append(core.Saved ? ((long)(DateTime.UtcNow - savedAt).TotalMilliseconds).ToString(Inv) : "null")
                  .Append(",\"cancel\":").Append(Json_.S(core.LastCancel)).Append('}');
                return sb.ToString();
            }
        }

        static string Save(long atMs)
        {
            Frame f = Sdk.Latest;
            if (!f.Connected) return Reply(false, "iRacing is not sending data");
            SpotSample at = null;
            lock (gate)
            {
                // the frame nearest the moment the key was pressed (the car keeps moving while irdeck brings the sim to the front)
                long bestDiff = long.MaxValue;
                foreach (SpotSample s in ring) { long d = Math.Abs(s.Ms - atMs); if (d < bestDiff) { bestDiff = d; at = s; } }
            }
            if (at == null) return Reply(false, "no position yet");
            if (!at.OnTrack) return Reply(false, "get in the car first");

            string yaml = f.SessionYaml ?? "";
            string id = TrackMaps.YamlValue(yaml, "TrackID"), name = TrackMaps.YamlValue(yaml, "TrackName"), cfg = TrackMaps.YamlValue(yaml, "TrackConfigName");
            double lengthM = TrackLengthM(yaml);
            string where; double endPct = EndFor(at.Pct, id, name, cfg, lengthM, out where);
            lock (gate)
            {
                core.Save(at.Pct, at.Speed, endPct, where);
                savedAt = DateTime.UtcNow;
            }
            return Reply(true, "Spot saved - tries are timed " + where);
        }

        static double TrackLengthM(string yaml)
        {
            Match m = Regex.Match(yaml ?? "", @"TrackLength:\s*([\d.]+)\s*km", RegexOptions.IgnoreCase);
            double km; if (m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float, Inv, out km) && km > 0.2) return km * 1000;
            return 5000;
        }

        // where a try ends: the exit of the corner the spot is in or the next one; no corner list = 300 m on
        static double EndFor(double spot, string id, string name, string cfg, double lengthM, out string where)
        {
            double minFrac = 100.0 / lengthM, fallback = 300.0 / lengthM;
            try
            {
                CornerSet cs = Corners.Resolve(name, cfg, id, TrackMaps.MakeKey(id, name), false);
                if (cs != null && cs.Turns != null && cs.Turns.Count > 0)
                {
                    List<double> exits = new List<double>();
                    foreach (CornerTurn t in cs.Turns) exits.Add(t.P1);
                    int i; double end = SpotCore.PickEnd(spot, exits, minFrac, fallback, out i);
                    if (i >= 0)
                    {
                        CornerTurn t = cs.Turns[i];
                        where = "to the exit of " + (t.Name.Length > 0 ? "T" + t.N + " " + t.Name : "turn " + t.N);
                        return end;
                    }
                }
            }
            catch (Exception ex) { Log.W("spot: corners: " + ex.Message); }
            where = "over the next 300 m";
            return (spot + fallback) % 1.0;
        }
    }
}
