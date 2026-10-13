// MOST TO GAIN (P5, docs\PLAN-v3.md; docs\tasks\log\C-42.md "NEEDS LEAD 7"): the car and track where his personal best is furthest from his
// theoretical best. Facts only, nothing invented:
//   personal best     = his quickest counted lap (official times only: iRacing's own figure, a lap that iRacing counted - the one rule, LapRules.Counted in analysis.cs)
//   theoretical best  = the best iRacing sector ever of that car and track, joined (the same rule as the Career page's THEORETICAL tile: career.cs CrAggregate)
//   gap               = personal best - theoretical best, in seconds; the biggest gap wins.
// It reuses the Career engine's per-file results (vault\career\c-*.json; a file is read once, ever), so opening a Career page and this share the work.
// The Stream Deck's RACE SETUP screen draws MOST TO GAIN from the "gain" object of /mydrive (mydrive.cs); GET /analysis/gain lists every combination.
// Work: ONE BelowNormal thread, never while the sim is connected or he drives, stops at once when he gets in the car (what is done stays cached),
// and looks again only when the set of telemetry files changed. Reads old files only (the career scan skips a file written in the last 2 minutes).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

namespace IRDash
{
    static partial class Analysis
    {
        public const double GainMin = 0.01;       // below 10 ms the "gap" is rounding, not something to practise

        public sealed class GainRow
        {
            public string Car = "", Track = "", Config = "";
            public double Pb, Theo, Gap;
            public int Sessions, Laps;
            public bool Newest;      // this layout is the one his newest session of this car and track was on (what a MY DRIVE pick of that drive starts on)
        }

        static readonly object gnGate = new object();
        static List<GainRow> gnRows;                 // biggest gap first; null until a whole pass has finished
        static string gnSig = "";                    // the files gnRows was worked out from
        static volatile bool gnBusy;
        static DateTime gnCheckedAt = DateTime.MinValue;
        static int gnDone, gnOf; static long gnMs; static int gnFiles;

        public static List<GainRow> GainRows() { lock (gnGate) return gnRows == null ? null : new List<GainRow>(gnRows); }

        // Called on every /mydrive poll, so it is cheap: one clock look unless a pass is due. A pass is due 3 minutes after irdash started (the rig
        // is still starting apps), then at most once a minute, and never while the sim is connected or he is in the car. now = the route (tests).
        public static void GainPoke(bool now)
        {
            if (gnBusy) return;
            if (Program.IsDriving) return;
            if (!now)
            {
                if ((DateTime.Now - Program.StartedAt).TotalSeconds < 180) return;
                if ((DateTime.UtcNow - gnCheckedAt).TotalSeconds < 60) return;
                if (Sdk.Latest.Connected) return;
            }
            else if (gnRows != null && (DateTime.UtcNow - gnCheckedAt).TotalSeconds < 60) return;     // the route asked again within a minute: the list is current
            lock (gnGate)
            {
                if (gnBusy) return;
                gnBusy = true; gnCheckedAt = DateTime.UtcNow; gnDone = 0; gnOf = 0;
            }
            Thread th = new Thread(GainWork);
            th.IsBackground = true; th.Priority = ThreadPriority.BelowNormal; th.Name = "Gain";
            th.Start();
        }

        static void GainWork()
        {
            Stopwatch sw = Stopwatch.StartNew();
            try
            {
                string dir = TrackMaps.TelemetryDir, vroot = Vault.Root;
                if (string.IsNullOrEmpty(vroot)) vroot = Path.Combine(Program.RootDir, "vault");
                int online, recent;
                List<CrMeta> all = CrScan(dir, vroot, null, true, out online, out recent);
                string sig = GainSig(all, recent);
                lock (gnGate) { if (gnRows != null && sig == gnSig) return; }
                bool aborted;
                List<GainRow> rows = GainCompute(all, vroot, true, out aborted);
                gnMs = sw.ElapsedMilliseconds;
                if (aborted) { Log.W("gain: stopped, you got in the car (what was read stays cached)"); return; }
                lock (gnGate) { gnRows = rows; gnSig = sig; gnFiles = all.Count; }
                Log.W("gain: " + rows.Count + " car and track combinations worked out from " + all.Count + " files in " + (sw.ElapsedMilliseconds / 1000.0).ToString("0.0", Inv) + " s" +
                      (rows.Count > 0 ? "; most to gain: " + rows[0].Car + " at " + rows[0].Track + ", " + F(rows[0].Gap, "0.000") + " s" : ""));
            }
            catch (Exception ex) { Log.W("gain: " + ex.Message); }
            finally { gnBusy = false; }
        }

        static string GainSig(List<CrMeta> all, int recent)
        {
            long size = 0, mod = 0;
            foreach (CrMeta m in all) { size += m.Size; if (m.ModMs > mod) mod = m.ModMs; }
            return all.Count.ToString(Inv) + "|" + size.ToString(Inv) + "|" + mod.ToString(Inv) + "|" + recent.ToString(Inv);
        }

        // Every car + track + layout of these files. live: stop when he gets in the car.
        static List<GainRow> GainCompute(List<CrMeta> all, string vroot, bool live, out bool aborted)
        {
            aborted = false;
            List<GainRow> rows = new List<GainRow>();
            Dictionary<string, CrMeta> newest = new Dictionary<string, CrMeta>();          // car|track -> its newest session (any layout)
            List<string[]> combos = new List<string[]>(); HashSet<string> seen = new HashSet<string>();
            foreach (CrMeta m in all)
            {
                if (m.Car.Length == 0 || m.Track.Length == 0) continue;
                string ct = m.Car + "|" + m.Track; CrMeta have;
                if (!newest.TryGetValue(ct, out have) || m.Ticks > have.Ticks) newest[ct] = m;
                if (seen.Add(ct + "|" + m.Config)) combos.Add(new[] { m.Car, m.Track, m.Config });
            }
            combos.Sort(delegate (string[] a, string[] b) { return string.CompareOrdinal(a[0] + "|" + a[1] + "|" + a[2], b[0] + "|" + b[1] + "|" + b[2]); });
            gnOf = combos.Count; gnDone = 0;
            foreach (string[] c in combos)
            {
                if (live && Program.IsDriving) { aborted = true; return rows; }
                List<CrMeta> hit = CrCombo(all, c[0], c[1], c[2]);
                if (hit.Count == 0) { gnDone++; continue; }
                string sig; CornerSet cs;
                try { cs = CrCorners(hit[0], out sig); }
                catch (Exception ex) { Log.W("gain: no corner list for " + c[1] + " (" + ex.Message + ")"); cs = new CornerSet(); sig = "gain-nocorners"; }
                CrFile[] files = new CrFile[hit.Count]; CrCounts cc = new CrCounts();
                for (int i = 0; i < hit.Count; i++)
                {
                    files[i] = CrLookup(hit[i], sig, vroot, cc);
                    if (files[i] != null) continue;
                    if (live && Program.IsDriving) { aborted = true; return rows; }
                    files[i] = CrCompute(hit[i], cs, sig);
                    CrStore(hit[i], files[i], vroot);
                    if (live) Thread.Sleep(100);          // one file at a time, leave the disk and the processor to the rest
                }
                GainRow r = GainOf(c, hit, files);
                if (r != null)
                {
                    CrMeta nw; r.Newest = newest.TryGetValue(c[0] + "|" + c[1], out nw) && nw.Config == c[2];
                    rows.Add(r);
                }
                gnDone++;
            }
            rows.Sort(delegate (GainRow a, GainRow b)
            {
                int d = b.Gap.CompareTo(a.Gap);
                return d != 0 ? d : string.CompareOrdinal(a.Car + "|" + a.Track + "|" + a.Config, b.Car + "|" + b.Track + "|" + b.Config);
            });
            return rows;
        }

        // The Career page's rule (career.cs CrAggregate), kept in step with it on purpose: tests\rig-leftovers-test.ps1 compares the two.
        // Sessions are oldest first; the sector layout of the first session with a counted lap is the reference; a session with another layout adds nothing.
        static GainRow GainOf(string[] combo, List<CrMeta> hit, CrFile[] files)
        {
            List<CrFile> ss = new List<CrFile>();
            for (int i = 0; i < files.Length; i++) { CrFile f = files[i]; if (f != null && !f.Bad && f.Valid.Count > 0) ss.Add(f); }
            if (ss.Count == 0) return null;
            double pb = double.MaxValue; int laps = 0;
            foreach (CrFile f in ss) foreach (CrLap l in f.Valid) { laps++; if (l.Time < pb) pb = l.Time; }
            double[] refAt = ss[0].SectorAt; int nS = refAt.Length;
            if (nS < 2 || laps < 2) return null;
            double[] best = new double[nS]; bool[] got = new bool[nS];
            for (int k = 0; k < nS; k++) best[k] = double.MaxValue;
            foreach (CrFile f in ss)
            {
                bool same = f.SectorAt.Length == nS;
                for (int k = 0; same && k < nS; k++) if (Math.Abs(f.SectorAt[k] - refAt[k]) > 1e-5) same = false;
                if (!same) continue;
                foreach (CrLap l in f.Valid)
                {
                    if (!l.Pure) continue;      // the theoretical lap joins only laps with no off-track record (the personal best above still counts every counted lap)
                    for (int k = 0; k < nS; k++)
                    {
                        double ms = Math.Round(l.Sec[k], 3, MidpointRounding.AwayFromZero);
                        if (ms < best[k] - 1e-9) { best[k] = ms; got[k] = true; }
                    }
                }
            }
            double theo = 0;
            for (int k = 0; k < nS; k++) { if (!got[k]) return null; theo += best[k]; }
            if (theo > pb + 0.0005) return null;      // the PB lap had an off-track and is quicker than anything that can be joined: no theoretical, nothing to gain to show
            GainRow r = new GainRow();
            r.Car = combo[0]; r.Track = combo[1]; r.Config = combo[2];
            r.Pb = pb; r.Theo = theo; r.Gap = pb - theo; r.Sessions = ss.Count; r.Laps = laps;
            return r;
        }

        static string GainRowJson(GainRow r)
        {
            return "{\"car\":" + Json_.S(r.Car) + ",\"track\":" + Json_.S(r.Track) + ",\"config\":" + Json_.S(r.Config) + ",\"pb\":" + F(r.Pb, "0.000") + ",\"theoretical\":" + F(r.Theo, "0.000") +
                   ",\"gap\":" + F(r.Gap, "0.000") + ",\"sessions\":" + r.Sessions + ",\"laps\":" + r.Laps + ",\"newest\":" + (r.Newest ? "true" : "false") + "}";
        }

        static string GainJson(List<GainRow> rows, int files, long ms)
        {
            StringBuilder sb = new StringBuilder("{\"v\":1,\"ready\":true,\"min\":" + F(GainMin, "0.000") + ",\"combos\":[");
            for (int i = 0; i < rows.Count; i++) { if (i > 0) sb.Append(','); sb.Append(GainRowJson(rows[i])); }
            sb.Append("],\"best\":");
            GainRow best = null;
            foreach (GainRow r in rows) if (r.Gap >= GainMin) { best = r; break; }
            sb.Append(best == null ? "null" : GainRowJson(best));
            return sb.Append(",\"files\":").Append(files).Append(",\"ms\":").Append(ms).Append('}').ToString();
        }

        // GET /analysis/gain: every car and track with its PB, theoretical best and gap; "building" while the first pass runs. 503 while he drives.
        public static string GainRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
            GainPoke(true);
            List<GainRow> rows; int files; long ms;
            lock (gnGate) { rows = gnRows == null ? null : new List<GainRow>(gnRows); files = gnFiles; ms = gnMs; }
            if (rows == null) return "{\"building\":true,\"done\":" + gnDone + ",\"of\":" + gnOf + "}";
            return GainJson(rows, files, ms);
        }

        // one-shot for tests\rig-leftovers-test.ps1: no window, no deploy, only the folders it is given
        //   --analysis --gain --root <iRacingDeck> --dir <telemetry folder> --vault <vault folder> --out <file>
        public static int GainCli(string[] args)
        {
            string root = Arg(args, "--root"), dir = Arg(args, "--dir"), vroot = Arg(args, "--vault"), outPath = Arg(args, "--out"), json;
            if (root.Length == 0 || dir.Length == 0 || vroot.Length == 0 || outPath.Length == 0) json = Err("need --root --dir --vault --out");
            else
            {
                Corners.DataRoot = root;
                TrackMaps.MapsDir = Path.Combine(root, @"dash\maps");
                try
                {
                    Stopwatch sw = Stopwatch.StartNew(); int online, recent; bool aborted;
                    List<CrMeta> all = CrScan(dir, vroot, null, false, out online, out recent);
                    List<GainRow> rows = GainCompute(all, vroot, false, out aborted);
                    json = GainJson(rows, all.Count, sw.ElapsedMilliseconds);
                }
                catch (Exception ex) { json = Err(ex.Message); }
            }
            try { File.WriteAllText(outPath, json, new UTF8Encoding(false)); }
            catch { return 1; }
            return json.StartsWith("{\"error\"", StringComparison.Ordinal) ? 1 : 0;
        }
    }
}
