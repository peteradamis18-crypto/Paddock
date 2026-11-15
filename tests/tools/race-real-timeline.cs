// race-real-timeline.cs (W2-5 step 1) - rebuilds what the race screen was fed during a REAL race, from two finished files:
//   - the .ibt (his own car: lap, fuel, flags, delta, lap times; iRacing's .ibt has no CarIdx arrays), and
//   - irdash's field log (vault\field\f*.json, field.cs: every car's line and corner-boundary crossings, logged live from the sim at 10 Hz).
// The CarIdx arrays are put back by interpolating each car's distance between its logged crossings; the race part is irdash's RacePart
// (statebuilder.cs) with the real fuel tracker (fuel.cs fed every record, as sdkreader.cs does). Output: one JSON timeline, one entry per
// second of sim time: { t, v: <the race set frame>, race: <the race part> }.
// Compiled by tests\race-real-test.ps1 with dash\src\fuel.cs, lapstore.cs, ibtfile.cs. Only READS the two files. Args: <ibt> <field json> <out>
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class Json { public static string Str(string s) { return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; } }
    static class Json_ { public static string S(string s) { return Json.Str(s ?? ""); } }
    static class Log { public static void W(string m) { } }

    static class RaceRealTimeline
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        sealed class Car { public int Idx; public bool Me, Gone; public double GoneT = double.NaN, FirstS = double.NaN; public List<double> T = new List<double>(), D = new List<double>(); public List<double[]> Pits = new List<double[]>(); }

        static double Dn(object o) { if (o == null) return double.NaN; return Convert.ToDouble(o, Inv); }
        static string R(double v, string f) { return double.IsNaN(v) || double.IsInfinity(v) ? "null" : v.ToString(f, Inv); }
        static string Str(string s) { return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; }

        // a car's distance (laps + fraction) at sim time t; NaN = not in the world
        static double DistAt(Car c, double t)
        {
            if (c.Gone && !double.IsNaN(c.GoneT) && t >= c.GoneT) return double.NaN;
            if (c.T.Count == 0) return double.NaN;
            if (t <= c.T[0]) return Math.Max(0, c.D[0] - (c.T[0] - t) / 210.0);          // the formation lap: about 210 s round, lap 0
            int n = c.T.Count;
            if (t >= c.T[n - 1]) return c.D[n - 1];                                          // after its last crossing: where it stopped
            int lo = 0, hi = n - 1;
            while (hi - lo > 1) { int m = (lo + hi) / 2; if (c.T[m] <= t) lo = m; else hi = m; }
            double f = (t - c.T[lo]) / Math.Max(1e-6, c.T[hi] - c.T[lo]);
            return c.D[lo] + f * (c.D[hi] - c.D[lo]);
        }
        // when a car reached distance d (NaN = not reached in the log)
        static double TimeAt(Car c, double d)
        {
            int n = c.D.Count; if (n == 0 || d < c.D[0] || d > c.D[n - 1]) return double.NaN;
            int lo = 0, hi = n - 1;
            while (hi - lo > 1) { int m = (lo + hi) / 2; if (c.D[m] <= d) lo = m; else hi = m; }
            double f = (d - c.D[lo]) / Math.Max(1e-9, c.D[hi] - c.D[lo]);
            return c.T[lo] + f * (c.T[hi] - c.T[lo]);
        }

        static int Main(string[] a)
        {
            if (a.Length < 3) { Console.Error.WriteLine("args: <ibt> <field json> <out>"); return 2; }
            JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue;
            Dictionary<string, object> fl = (Dictionary<string, object>)js.DeserializeObject(File.ReadAllText(a[1]));
            int me = Convert.ToInt32(fl["me"]); double greenT = Dn(fl["greenT"]);
            object[] corners = (object[])fl["corners"];
            double[] cp = new double[corners.Length * 2];
            for (int k = 0; k < corners.Length; k++) { Dictionary<string, object> c = (Dictionary<string, object>)corners[k]; cp[2 * k] = Dn(c["p0"]); cp[2 * k + 1] = Dn(c["p1"]); }
            List<Car> cars = new List<Car>();
            foreach (object o in (object[])fl["cars"])
            {
                Dictionary<string, object> c = (Dictionary<string, object>)o;
                Car car = new Car(); car.Idx = Convert.ToInt32(c["i"]); car.Me = car.Idx == me; car.Gone = Convert.ToInt32(c["gone"]) != 0; car.GoneT = Dn(c["goneT"]);
                object[] L = c["L"] as object[];
                if (L != null)
                    foreach (object lo in L)
                    {
                        object[] l = (object[])lo; int n = Convert.ToInt32(l[0]); double s = Dn(l[1]), e = Dn(l[2]);
                        if (double.IsNaN(car.FirstS)) car.FirstS = s;
                        List<KeyValuePair<double, double>> pts = new List<KeyValuePair<double, double>>();
                        pts.Add(new KeyValuePair<double, double>(s, n));
                        object[] x = l.Length > 8 ? l[8] as object[] : null;
                        if (x != null)
                            for (int k = 0; k < x.Length && k < cp.Length; k++)
                            {
                                double ms = Dn(x[k]); if (!(ms > 0) || !(cp[k] > 0)) continue;
                                pts.Add(new KeyValuePair<double, double>(s + ms / 1000.0, n + cp[k]));
                            }
                        if (e > s) pts.Add(new KeyValuePair<double, double>(e, n + 1));
                        pts.Sort(delegate (KeyValuePair<double, double> p, KeyValuePair<double, double> q) { return p.Key.CompareTo(q.Key); });
                        foreach (KeyValuePair<double, double> p in pts)
                        {
                            // only forward in time and distance (a corner time a sample late must not make the car go backwards)
                            if (car.T.Count > 0 && (p.Key <= car.T[car.T.Count - 1] || p.Value <= car.D[car.D.Count - 1])) continue;
                            car.T.Add(p.Key); car.D.Add(p.Value);
                        }
                    }
                object[] P = c["P"] as object[];
                if (P != null) foreach (object po in P) { object[] p = (object[])po; car.Pits.Add(new double[] { Dn(p[2]), Dn(p[3]) }); }
                cars.Add(car);
            }

            IbtFile ibt = IbtFile.Open(a[0], true);
            string[] names = { "SessionTime", "SessionNum", "Lap", "LapCompleted", "LapDistPct", "FuelLevel", "SessionFlags", "OnPitRoad", "IsOnTrack",
                "PlayerTrackSurface", "PlayerCarMyIncidentCount", "LapLastLapTime", "LapBestLapTime", "LapDeltaToBestLap", "LapDeltaToBestLap_OK",
                "SessionLapsRemainEx", "SessionTimeRemain", "PlayerCarIdx", "DisplayUnits", "EngineWarnings", "FuelUsePerHour" };
            double[][] ch = ibt.Channels(names, 0, ibt.Records);
            Func<int, long, double> V = delegate (int k, long i) { return ch[k] == null ? double.NaN : ch[k][i]; };
            string yaml = ibt.Yaml;
            double tank = 0, maxPct = 1, est = 0; int incLimit = 0;
            double.TryParse(ibt.YamlValue("DriverCarFuelMaxLtr"), NumberStyles.Float, Inv, out tank);
            if (!double.TryParse(ibt.YamlValue("DriverCarMaxFuelPct"), NumberStyles.Float, Inv, out maxPct)) maxPct = 1;
            double.TryParse(ibt.YamlValue("DriverCarEstLapTime"), NumberStyles.Float, Inv, out est);
            int.TryParse(ibt.YamlValue("IncidentLimit"), NumberStyles.Integer, Inv, out incLimit);
            // the race session's row: SessionLaps (a number = a lap race) and its type
            int sessNum = (int)V(1, ibt.Records / 2);
            Match row = Regex.Match(yaml, "- SessionNum: " + sessNum + "\\s*\\n(?:[ \\t]+\\S.*\\n)*?[ \\t]+SessionLaps: (\\S+)[\\s\\S]*?SessionType: ([^\\r\\n]+)");
            int laps = 0; if (row.Success) int.TryParse(row.Groups[1].Value, out laps);
            string type = row.Success ? row.Groups[2].Value.Trim() : "Race";
            // one driver's block in DriverInfo.Drivers (every entry starts "- CarIdx: n"; a tempered match stays inside it)
            Func<int, string, string> drv = delegate (int idx, string key)
            {
                Match m = Regex.Match(yaml, "- CarIdx: " + idx + "\r?\n(?:(?![ \t]*- ).*\r?\n)*?[ \t]*" + key + ": \"?([^\"\r\n]*)");
                return m.Success ? m.Groups[1].Value.Trim() : "";
            };
            string myName = drv(me, "UserName"), myCarNum = drv(me, "CarNumber");
            string[] myWords = myName.Split(' ');
            myName = Regex.Replace(myWords[myWords.Length - 1], "[0-9]+$", "");
            int paceIdx = -1; for (int k = 0; k < 64; k++) if (drv(k, "CarIsPaceCar") == "1") { paceIdx = k; break; }


            FuelTracker tr = new FuelTracker(); tr.TankL = tank * maxPct; tr.EstLap = est;
            StringBuilder sb = new StringBuilder(8 << 20);
            sb.Append("{\"me\":").Append(me).Append(",\"greenT\":").Append(R(greenT, "0.0")).Append(",\"laps\":").Append(laps).Append(",\"type\":").Append(Str(type))
              .Append(",\"tank\":").Append(R(tr.TankL, "0.00")).Append(",\"incLimit\":").Append(incLimit);
            // the session part as irdash sends it (statebuilder.cs SessionJsonOf: the same names, every value a string), the fields the race page reads
            sb.Append(",\"session\":{\"ver\":1,\"WeekendInfo\":{\"TrackID\":").Append(Str(ibt.YamlValue("TrackID"))).Append(",\"TrackName\":").Append(Str(ibt.YamlValue("TrackName")))
              .Append(",\"TrackDisplayName\":").Append(Str(ibt.YamlValue("TrackDisplayName"))).Append("},\"DriverInfo\":{\"DriverCarIdx\":").Append(Str(me.ToString(Inv))).Append(",\"Drivers\":[");
            string[] dk = { "UserName", "CarNumber", "CarClassID", "CarClassShortName", "CarClassColor", "CarIsPaceCar", "IsSpectator", "CarScreenNameShort" };
            bool firstD = true;
            for (int k = 0; k < 64; k++)
            {
                if (!Regex.IsMatch(yaml, "- CarIdx: " + k + "\r?\n")) continue;
                if (!firstD) sb.Append(','); firstD = false;
                sb.Append("{\"CarIdx\":").Append(Str(k.ToString(Inv)));
                foreach (string key in dk) sb.Append(',').Append(Str(key)).Append(':').Append(Str(drv(k, key)));
                sb.Append('}');
            }
            sb.Append("]},\"SessionInfo\":{\"Sessions\":[");
            MatchCollection rows = Regex.Matches(yaml, "- SessionNum: (\\d+)\\s*\\n(?:(?![ \\t]*- SessionNum).*\\n)*?[ \\t]+SessionType: ([^\\r\\n]+)");
            for (int k = 0; k < rows.Count; k++) { if (k > 0) sb.Append(','); sb.Append("{\"SessionNum\":").Append(Str(rows[k].Groups[1].Value)).Append(",\"SessionType\":").Append(Str(rows[k].Groups[2].Value.Trim())).Append('}'); }
            sb.Append("]}},\"entries\":[");
            int width = 0; foreach (Car c in cars) width = Math.Max(width, c.Idx + 1);
            if (paceIdx >= 0) width = Math.Max(width, paceIdx + 1);
            double next = double.NaN; bool firstE = true; int count = 0;
            for (long i = 0; i < ibt.Records; i++)
            {
                double t = V(0, i);
                FuelSample s = new FuelSample();
                s.Time = t; s.SessionNum = (int)V(1, i); s.Lap = (int)V(2, i); s.Pct = V(4, i); s.Level = V(5, i); s.Flags = unchecked((uint)(long)V(6, i));
                s.OnPitRoad = V(7, i) != 0; s.OnTrack = V(8, i) != 0; s.Surface = ch[9] == null ? 3 : (int)V(9, i); s.Incidents = (int)V(10, i);
                s.LastLap = V(11, i); s.BestLap = V(12, i); s.HaveBest = ch[12] != null; s.LapsRemain = ch[15] == null ? 32767 : (int)V(15, i);
                s.TimeRemain = ch[16] == null ? -1 : V(16, i); s.LapRace = laps > 0;
                tr.Feed(s);
                if (!double.IsNaN(next) && t < next) continue;
                next = Math.Floor(t) + 1;
                if (V(8, i) == 0) continue;             // not in the car (RacePart is null then, the page shows nothing new)

                // every car's distance now, the order (by distance; on the grid before the green: the order they crossed the line)
                double[] dist = new double[width]; for (int k = 0; k < width; k++) dist[k] = double.NaN;
                foreach (Car c in cars) dist[c.Idx] = DistAt(c, t);
                List<Car> run = new List<Car>(); foreach (Car c in cars) if (!double.IsNaN(dist[c.Idx])) run.Add(c);
                bool green = t >= greenT;
                run.Sort(delegate (Car p, Car q)
                {
                    if (!green) return (double.IsNaN(p.FirstS) ? 1e9 : p.FirstS).CompareTo(double.IsNaN(q.FirstS) ? 1e9 : q.FirstS);
                    int r = dist[q.Idx].CompareTo(dist[p.Idx]); return r != 0 ? r : p.Idx.CompareTo(q.Idx);
                });
                int[] pos = new int[width]; for (int k = 0; k < run.Count; k++) pos[run[k].Idx] = k + 1;
                Car lead = run.Count > 0 ? run[0] : null;
                double[] f2 = new double[width];
                foreach (Car c in run)
                {
                    if (c == lead || !green) continue;
                    double tl = TimeAt(lead, dist[c.Idx]); f2[c.Idx] = double.IsNaN(tl) ? 0 : Math.Max(0, t - tl);
                }
                StringBuilder fv = new StringBuilder(4096);
                Action<string, Func<int, string>> arr = delegate (string nm, Func<int, string> f)
                {
                    fv.Append(",\"").Append(nm).Append("\":[");
                    for (int k = 0; k < width; k++) { if (k > 0) fv.Append(','); fv.Append(f(k)); }
                    fv.Append(']');
                };
                arr("CarIdxPosition", delegate (int k) { return green ? pos[k].ToString(Inv) : "0"; });
                arr("CarIdxClassPosition", delegate (int k) { return green ? pos[k].ToString(Inv) : "0"; });
                arr("CarIdxF2Time", delegate (int k) { return R(f2[k], "0.000"); });
                arr("CarIdxLap", delegate (int k) { return double.IsNaN(dist[k]) ? "-1" : ((int)Math.Floor(dist[k])).ToString(Inv); });
                arr("CarIdxLapDistPct", delegate (int k) { return double.IsNaN(dist[k]) ? "-1" : R(dist[k] - Math.Floor(dist[k]), "0.0000"); });
                arr("CarIdxEstTime", delegate (int k) { return double.IsNaN(dist[k]) ? "0" : R((dist[k] - Math.Floor(dist[k])) * (est > 1 ? est : 94), "0.000"); });
                arr("CarIdxOnPitRoad", delegate (int k)
                {
                    if (k == me) return V(7, i) != 0 ? "1" : "0";
                    foreach (Car c in cars) if (c.Idx == k) foreach (double[] p in c.Pits) if (t >= p[0] && t <= p[1]) return "1";
                    return "0";
                });
                arr("CarIdxClass", delegate (int k) { return "4012"; });
                Func<string, int, string> sc = delegate (string nm, int k) { double x = V(k, i); return ",\"" + nm + "\":" + R(x, "0.######"); };
                fv.Append(sc("Lap", 2)).Append(sc("LapCompleted", 3)).Append(sc("SessionLapsRemainEx", 15)).Append(sc("SessionTimeRemain", 16)).Append(sc("SessionTime", 0))
                  .Append(sc("PlayerCarMyIncidentCount", 10)).Append(sc("SessionFlags", 6)).Append(sc("FuelLevel", 5)).Append(sc("FuelUsePerHour", 20))
                  .Append(sc("LapLastLapTime", 11)).Append(sc("LapBestLapTime", 12)).Append(sc("LapDeltaToBestLap", 13)).Append(sc("LapDeltaToBestLap_OK", 14))
                  .Append(sc("OnPitRoad", 7)).Append(sc("PlayerCarIdx", 17)).Append(sc("IsOnTrack", 8)).Append(",\"IsReplayPlaying\":0").Append(sc("SessionNum", 1))
                  .Append(sc("DisplayUnits", 18)).Append(sc("EngineWarnings", 19));

                // irdash's RacePart (statebuilder.cs), field for field
                FuelView fuel = tr.View();
                uint raw = unchecked((uint)(long)V(6, i));
                bool caution = Fuel.Caution(raw), isGreen = (raw & (Fuel.NotGreenMask | 0x1)) == 0;
                double last = V(11, i), best = V(12, i), remain = V(16, i);
                int inWorld = run.Count;
                StringBuilder rp = new StringBuilder(800);
                rp.Append("{\"on\":true,\"type\":").Append(Str(type)).Append(",\"multiclass\":false");
                rp.Append(",\"me\":{\"idx\":").Append(me).Append(",\"num\":").Append(Str(myCarNum)).Append(",\"name\":").Append(Str(myName)).Append(",\"classId\":4012,\"classColor\":\"0xffffff\"}");
                rp.Append(",\"pos\":").Append(green && pos[me] > 0 ? pos[me].ToString(Inv) : "null").Append(",\"of\":").Append(inWorld)
                  .Append(",\"classPos\":").Append(green && pos[me] > 0 ? pos[me].ToString(Inv) : "null").Append(",\"classOf\":").Append(inWorld);
                rp.Append(",\"lapNum\":").Append(((int)V(2, i)).ToString(Inv)).Append(",\"laps\":").Append(laps > 0 ? laps.ToString(Inv) : "null")
                  .Append(",\"toGo\":").Append(fuel.ToGo.HasValue ? fuel.ToGo.Value.ToString(Inv) : "null")
                  .Append(",\"timeLeft\":").Append(laps <= 0 && remain >= 0 && remain <= 86400 ? R(remain, "0.0") : "null")
                  .Append(",\"clock\":").Append(R(t, "0.0"));
                rp.Append(",\"inc\":{\"n\":").Append((int)V(10, i)).Append(",\"limit\":").Append(incLimit > 0 ? incLimit.ToString(Inv) : "null").Append('}');
                rp.Append(",\"flags\":{\"caution\":").Append(caution ? "true" : "false").Append(",\"green\":").Append(isGreen ? "true" : "false").Append(",\"raw\":").Append(raw).Append('}');
                rp.Append(",\"pit\":{\"onRoad\":").Append(V(7, i) != 0 ? "true" : "false").Append(",\"limiter\":").Append(((long)V(19, i) & 0x10) != 0 ? "true" : "false").Append(",\"loss\":null,\"rejoin\":null}");
                rp.Append(",\"units\":").Append(ch[18] == null || V(18, i) != 0 ? "\"metric\"" : "\"imperial\"");
                rp.Append(",\"fuel\":").Append(fuel.Json());
                rp.Append(",\"lap\":{\"last\":").Append(last > 0 ? R(last, "0.000") : "null").Append(",\"best\":").Append(best > 0 ? R(best, "0.000") : "null")
                  .Append(",\"lastIsBest\":").Append(last > 0 && best > 0 && Math.Abs(last - best) < 0.0005 ? "true" : "false")
                  .Append(",\"delta\":").Append(R(V(13, i), "0.00")).Append(",\"deltaOk\":").Append(V(14, i) != 0 ? "true" : "false").Append("}}");

                if (!firstE) sb.Append(','); firstE = false; count++;
                sb.Append("{\"t\":").Append(R(t, "0.0")).Append(",\"v\":{").Append(fv.ToString(1, fv.Length - 1)).Append("},\"race\":").Append(rp).Append('}');
            }
            sb.Append("]}");
            File.WriteAllText(a[2], "window.__tl = " + sb.ToString() + ";", new UTF8Encoding(false));
            Console.WriteLine("entries " + count + ", cars " + cars.Count + ", width " + width + ", me " + me + ", laps " + laps + ", type " + type + ", tank " + R(tr.TankL, "0.0") + ", pace car " + paceIdx);
            return 0;
        }
    }
}
