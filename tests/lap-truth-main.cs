// Entry point for tests\lap-truth-test.ps1 only: compiled together with dash\src\*.cs (csc /main:IRDash.LapTruthMain) into a throw-away
// exe in %TEMP%, so every place that shows a best lap can be asked about one .ibt offline, without irdash running.
//   lap-truth.exe <ibt> <lap cache dir> <root> <sidecar json> <telemetry dir>
// Prints "KEY value" lines; the test compares them.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class LapTruthMain
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static void P(string k, object v) { Console.WriteLine(k + " " + Convert.ToString(v, Inv)); }
        static string T(double v) { return v.ToString("0.000", Inv); }

        static object Field(object o, string name)
        {
            FieldInfo f = o.GetType().GetField(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
            return f == null ? null : f.GetValue(o);
        }

        static int Main(string[] a)
        {
            string ibt = a[0], cache = a[1], root = a[2], sidecar = a[3], teleDir = a[4];
            LapStore.Dir = cache;
            Corners.DataRoot = root;
            TrackMaps.MapsDir = Path.Combine(root, @"dash\maps");
            string name = Path.GetFileName(ibt);

            // 1. the lap store itself
            FileLaps f = LapStore.ForFile(ibt);
            if (f == null) { P("ERROR", "the lap store could not read the file"); return 1; }
            LapRec b = f.BestLap;
            P("store.laps", f.Laps.Count); P("store.counted", f.CountedLaps);
            P("store.best", b == null ? "none" : T(b.Time)); P("store.bestLap", b == null ? 0 : b.N);
            foreach (LapRec l in f.Laps) P("store.lap" + l.N, T(l.Time) + " " + (l.Counted ? "counted" : "not-counted") + " " + (l.Why.Length > 0 ? l.Why : "-") + (l.Incident ? " incident" : "") + (l.Off ? " off" : ""));
            P("store.cacheFile", File.Exists(Path.Combine(cache, Path.GetFileNameWithoutExtension(name) + ".json")) ? 1 : 0);

            // 2. the lap list (Vault card's laps, /ibt/laps)
            try
            {
                Dictionary<string, object> d = new JavaScriptSerializer().DeserializeObject(IbtLaps.LapsJson(ibt)) as Dictionary<string, object>;
                P("ibtlaps.bestLap", d["best"]); P("ibtlaps.best", d["bestTime"]); P("ibtlaps.counted", d["countedLaps"]);
                int lap0 = 0; foreach (object o in (object[])d["laps"]) if (Convert.ToInt32(((Dictionary<string, object>)o)["n"]) <= 0) lap0++;
                P("ibtlaps.lap0", lap0);
            }
            catch (Exception ex) { P("ibtlaps.error", ex.Message); }

            // 3. the Vault card and sessions.tsv row (VSession)
            try
            {
                List<VLap> vl; double st0;
                VSession v = VaultIbt.Analyze(ibt, out vl, out st0);
                P("vault.best", T(v.BestValid)); P("vault.bestLap", v.BestLap); P("vault.counted", v.ValidLaps);
                string[] row = v.Row().Split('\t'); P("vault.row", row[11] + "/" + row[12] + "/" + row[13]);
            }
            catch (Exception ex) { P("vault.error", ex.Message); }

            // 4. the Sessions page row and HOME (the career cache row, Career.Read)
            try
            {
                Type career = typeof(Career);
                MethodInfo read = career.GetMethod("Read", BindingFlags.NonPublic | BindingFlags.Static, null, new Type[] { typeof(string), typeof(FileInfo) }, null);
                object r = read.Invoke(null, new object[] { ibt, new FileInfo(ibt) });
                P("sessions.best", T((double)Field(r, "Best"))); P("sessions.laps", Field(r, "Laps")); P("sessions.counted", Field(r, "Counted"));
            }
            catch (Exception ex) { P("sessions.error", (ex.InnerException ?? ex).Message); }

            // 5. Analysis.CountedBest (the PB reference build and the old callers)
            P("countedBest", T(Analysis.CountedBest(ibt)));

            // 6. My Races (/api/rec/races, the deck RACES list): the 12 Nov sidecar, with the telemetry folder (truth from the .ibt) and without it (sidecar only)
            try
            {
                Dictionary<string, object> sc = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(sidecar)) as Dictionary<string, object>;
                RecSess s = new RecSess();
                s.Id = (string)sc["id"]; s.Track = (string)sc["track"]; s.Car = (string)sc["car"]; s.StartMs = Convert.ToDouble(sc["startMs"], Inv); s.Duration = Convert.ToDouble(sc["durationSec"], Inv); s.SessionNum = Convert.ToInt32(sc["sessionNum"], Inv); s.Type = (string)sc["sessionType"];
                foreach (object o in (object[])sc["laps"])
                {
                    Dictionary<string, object> l = (Dictionary<string, object>)o;
                    s.LapRows.Add(new double[] { Convert.ToDouble(l["n"], Inv), Convert.ToDouble(l["offset"], Inv), Convert.ToDouble(l["time"], Inv), (bool)l["clean"] ? 1 : 0, (bool)l["pb"] ? 1 : 0, Convert.ToDouble(l["startMs"], Inv) });
                }
                foreach (object o in (object[])sc["incidents"]) { Dictionary<string, object> x = (Dictionary<string, object>)o; s.Incidents.Add(new double[] { Convert.ToDouble(x["offset"], Inv), Convert.ToDouble(x["count"], Inv) }); }
                int laps, counted, bestN; double best;
                TrackMaps.TelemetryDir = teleDir;
                Recorder.RaceLaps(s, out laps, out counted, out best, out bestN);
                P("races.best", T(best)); P("races.bestLap", bestN); P("races.laps", laps); P("races.counted", counted);
                string empty = Path.Combine(cache, "no-telemetry"); Directory.CreateDirectory(empty);
                TrackMaps.TelemetryDir = empty; s.Id = s.Id + "-b";
                Recorder.RaceLaps(s, out laps, out counted, out best, out bestN);
                P("racesNoIbt.best", T(best)); P("racesNoIbt.bestLap", bestN); P("racesNoIbt.laps", laps); P("racesNoIbt.counted", counted);
            }
            catch (Exception ex) { P("races.error", (ex.InnerException ?? ex).Message); }

            // 7. Session Review (this file only)
            try
            {
                MethodInfo bs = typeof(Analysis).GetMethod("BuildSession", BindingFlags.NonPublic | BindingFlags.Static);
                string j = (string)bs.Invoke(null, new object[] { ibt, null, false, 0, false });
                Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(j) as Dictionary<string, object>;
                Dictionary<string, object> best = d["best"] as Dictionary<string, object>;
                P("review.best", best == null ? "none" : T(Convert.ToDouble(best["time"], Inv))); P("review.bestLap", best == null ? 0 : best["lap"]);
                int c = 0; foreach (object o in (object[])d["laps"]) if ((bool)((Dictionary<string, object>)o)["counted"]) c++;
                P("review.counted", c);
            }
            catch (Exception ex) { P("review.error", (ex.InnerException ?? ex).Message); }

            // 8. Coach
            try
            {
                Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(Analysis.Coach(ibt)) as Dictionary<string, object>;
                P("coach.best", d.ContainsKey("bestTime") && d["bestTime"] != null ? T(Convert.ToDouble(d["bestTime"], Inv)) : "none"); P("coach.bestLap", d.ContainsKey("bestLap") ? d["bestLap"] : 0); P("coach.counted", d.ContainsKey("counted") ? d["counted"] : -1);
            }
            catch (Exception ex) { P("coach.error", (ex.InnerException ?? ex).Message); }

            // 9. Career (the per-car-and-track report), over a folder that holds only this file
            try
            {
                string dir = Path.GetDirectoryName(ibt), outp = Path.Combine(cache, "career.json"), vault = Path.Combine(cache, "vault");
                Directory.CreateDirectory(vault);
                int rc = Analysis.CareerCli(new string[] { "--career", "--root", root, "--dir", dir, "--vault", vault, "--id", name, "--out", outp });
                Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(File.ReadAllText(outp)) as Dictionary<string, object>;
                if (d.ContainsKey("error")) P("career.error", d["error"]);
                else
                {
                    Dictionary<string, object> mine = null;
                    foreach (object o in (object[])d["sessions"]) { Dictionary<string, object> x = (Dictionary<string, object>)o; if ((string)x["file"] == name) mine = x; }
                    if (mine == null) P("career.error", "the session is not in the report");
                    else { P("career.best", T(Convert.ToDouble(mine["best"], Inv))); P("career.bestLap", mine["bestLap"]); P("career.counted", mine["valid"]); }
                }
            }
            catch (Exception ex) { P("career.error", (ex.InnerException ?? ex).Message); }
            P("DONE", 1);
            return 0;
        }
    }
}
