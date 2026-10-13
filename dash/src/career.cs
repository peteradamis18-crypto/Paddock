// The career (card W6c, docs\DESIGN-workbench.md 2.4 "history across sessions"): ONE car at ONE track over EVERY session Paddock can find,
// not one outing at a time. It sits on the lap store in analysis.cs (the same laps, the same lap times pinned to iRacing's own figure,
// the same corner model, the same "valid lap" rule as the Session Review) and adds the sessions side by side:
//   GET /analysis/career?id=<telemetry file name | vault lap id>      the car + track + layout of that file
//   GET /analysis/career?car=<car>&track=<track>[&config=<layout>]     (the names the files themselves carry)
// What it reads: every .ibt in iRacing's telemetry folder and every copy under vault\telemetry (an original and the Vault's copy of it are
// one session: same start time and size, the original is used). OneDrive online-only files are skipped (no download), and so is a file
// written in the last 2 minutes unless it is the one asked for.
// What it answers (JSON, see CrAggregate): the sessions oldest first, each with its best lap (official times only, iRacing's own figure; a lap
// counts when iRacing counted it - the one rule in analysis.cs, LapRules / Analysis.Counted, which the Session Review, the Vault and the PB reference use too:
// iRacing announces a time for a lap with a brief off-track too but does not count it (its own best lap of the session stays slower or empty); invalid laps never count), the best-5 average and spread, every valid lap, and per corner the best and the median time; the personal
// best and where it came from; the theoretical best (the best iRacing sector ever, joined) against the PB; the races from vault\field
// (only the ones that exist); totals (sessions, laps, clean laps, time driven).
// Caching: a file never changes, so what is worked out from it (CrFile: its valid laps, their sector times and seconds through every
// corner) is kept in memory and in vault\career\c<version>-<hash>.json, keyed by the file's start time + size and the corner list's signature.
// A call after the first one reads no .ibt at all. The first call does the work on ONE BelowNormal thread and answers
// {"building":true,"done":n,"of":m} until it is finished; it stops the moment he gets in the car (Program.IsDriving) and goes on later.
// 503 while he drives ("after your session"). Never writes anything but vault\career. Nothing here is drawn on a screen.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static partial class Analysis
    {
        const int CrVersion = 5;                              // 5: each lap also says whether it had an off-track record (Pure: only such laps are joined into the theoretical best); 4: a lap iRacing did not count is left out, decided by iRacing's own best lap first (LapRules.Judge, L-1); 3 was the off-track record alone
        static readonly object crGate = new object();
        static readonly Dictionary<string, CrFile> crFiles = new Dictionary<string, CrFile>();
        static readonly Dictionary<string, CrMeta> crMeta = new Dictionary<string, CrMeta>();
        static readonly Dictionary<string, CrRace> crRaces = new Dictionary<string, CrRace>();
        static CrJob crJob;
        static volatile int crSlowMs;                         // test hook only: a pause after every file, so a test can step in while the reader is busy

        // a lap that counts, with what the page needs from it: iRacing's own time, its sector times, the seconds through every corner of the corner list
        sealed class CrLap { public int N; public double Time; public double[] Sec, Cor; public bool Pure = true; }      // Pure: no off-track record at all - only such laps are joined into the theoretical best (L-1b)

        // what one telemetry file contributes. Worked out once (the file never changes), kept in memory and on disk.
        sealed class CrFile
        {
            public long Ticks, Size;
            public string Car = "", Track = "", Config = "", Type = "", CornerSig = "";
            public double LengthM, Seconds;
            public int Full, Turns, Uncounted;                // timed full laps; corners in the list; laps iRacing timed (clean otherwise) but did not count
            public double[] SectorAt = new double[0];
            public List<CrLap> Valid = new List<CrLap>();
            public bool Bad;                                  // the file could not be read: counted as skipped, never retried in this run
        }

        // the facts in a file's header (car, track, layout, start): read once per file
        sealed class CrMeta { public string Path = "", Name = "", Car = "", Track = "", Config = "", TrackName = "", TrackId = ""; public long Size, Ticks, ModMs; public bool Vault; }

        sealed class CrCounts { public int Computed, Disk, Mem; }

        sealed class CrJob { public string Key = ""; public int Done, Of; public string Cur = ""; public volatile bool Finished, Aborted; public string Error = ""; }

        sealed class CrRace
        {
            public string Id = "", Name = "", Type = ""; public long StartMs, EndMs; public string Car = "", Key = "", Track = "", Config = "";
            public string CarPath = "", Design = "", Num = "", Color = "";      // P4: his car's picture (type, livery, number, class colour) as the race log has it
            public int Pos, CPos, Field, ClassCars, Laps, GapLaps, Inc; public double Gap = double.NaN, Total = double.NaN, WinTotal = double.NaN, Best = double.NaN; public bool Out, Complete, Class;
        }

        static string CrN(double d, string f) { return double.IsNaN(d) || double.IsInfinity(d) ? "null" : d.ToString(f, Inv); }

        // ---------------- how it is asked ----------------
        public static string CareerRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
            string id = Q(q, "id"), car = Q(q, "car"), track = Q(q, "track"), config = Q(q, "config");
            string dir = TrackMaps.TelemetryDir, vroot = Vault.Root;
            if (string.IsNullOrEmpty(vroot)) vroot = Path.Combine(Program.RootDir, "vault");
            if (Sdk.TestHook)
            {
                // the test hook may point the reader at a scratch copy of some files (tests\career-test.ps1); a real request cannot
                string d2 = Q(q, "dir"), v2 = Q(q, "vault");
                if (d2.Length > 0 && Directory.Exists(d2)) dir = d2;
                if (v2.Length > 0) vroot = v2;
                if (Q(q, "drop") == "1") CrDrop();
                int slow; crSlowMs = int.TryParse(Q(q, "slow"), NumberStyles.Integer, Inv, out slow) ? Math.Max(0, Math.Min(2000, slow)) : 0;
            }
            else crSlowMs = 0;
            string main = null;
            if (id.Length > 0)
            {
                main = CrFind(id, dir, vroot);
                if (main == null) { code = 404; return Err("no such lap file"); }
                try { if (Career.OnlineOnly(new FileInfo(main))) { code = 409; return Err("Online-only in OneDrive: run tools\\keep-iracing-local.cmd"); } }
                catch { code = 404; return Err("no such lap file"); }
            }
            else if (car.Length == 0 || track.Length == 0) { code = 400; return Err("need id= or car= and track="); }
            ThreadPriority was = Thread.CurrentThread.Priority;
            try
            {
                Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
                return CrBuild(dir, vroot, car, track, config, main, true, true, out code);
            }
            catch (Exception ex) { Log.W("career: " + ex.Message); code = 500; return Err("could not read your sessions"); }
            finally { try { Thread.CurrentThread.Priority = was; } catch { } }
        }

        // one-shot for tests\career-test.ps1 (its own tiny exe, see tests\career-main.cs): no window, no deploy, only the folders it is given
        //   --career --root <iRacingDeck> --dir <telemetry folder> --vault <vault folder> (--id <file name> | --car <c> --track <t> [--config <l>]) --out <file> [--sync-only]
        public static int CareerCli(string[] args)
        {
            try
            {
                Process p = Process.GetCurrentProcess();
                p.PriorityClass = ProcessPriorityClass.BelowNormal;
                int cores = Environment.ProcessorCount;
                if (cores > 2)
                {
                    long mask = 0;
                    for (int i = 0; i < 2; i++) mask |= 1L << (cores - 1 - i);
                    p.ProcessorAffinity = (IntPtr)mask;
                }
            }
            catch { }
            string root = Arg(args, "--root"), dir = Arg(args, "--dir"), vroot = Arg(args, "--vault"), id = Arg(args, "--id"), outPath = Arg(args, "--out");
            string car = Arg(args, "--car"), track = Arg(args, "--track"), config = Arg(args, "--config");
            string json; int code = 200;
            if (root.Length == 0 || dir.Length == 0 || outPath.Length == 0 || (id.Length == 0 && (car.Length == 0 || track.Length == 0))) json = Err("need --root --dir --out and --id or --car --track");
            else
            {
                Corners.DataRoot = root;
                TrackMaps.MapsDir = Path.Combine(root, @"dash\maps");
                string main = id.Length > 0 ? CrFind(id, dir, vroot) : null;
                if (id.Length > 0 && main == null) json = Err("no such file");
                else
                {
                    try { json = CrBuild(dir, vroot, car, track, config, main, false, false, out code); }
                    catch (Exception ex) { json = Err(ex.Message); }
                }
            }
            try { File.WriteAllText(outPath, json, new UTF8Encoding(false)); }
            catch { return 1; }
            return json.StartsWith("{\"error\"", StringComparison.Ordinal) ? 1 : 0;
        }

        // test hook: forget what is in memory (the files on disk stay), so the next call proves the disk cache
        static void CrDrop() { lock (crGate) { crFiles.Clear(); crMeta.Clear(); crRaces.Clear(); } }

        // a telemetry file name (the iRacing folder first, then the Vault's copies) or a vault lap id
        static string CrFind(string id, string dir, string vroot)
        {
            if (string.IsNullOrEmpty(id) || id.Length > 160) return null;
            if (!id.EndsWith(".ibt", StringComparison.OrdinalIgnoreCase)) return ResolveFile(id);
            if (!Regex.IsMatch(id, @"^[A-Za-z0-9 _.\-]+\.ibt$")) return null;
            try
            {
                if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir))
                    foreach (string f in Directory.GetFiles(dir, "*.ibt"))
                        if (string.Equals(Path.GetFileName(f), id, StringComparison.OrdinalIgnoreCase)) return f;
            }
            catch { }
            return CrVaultCopy(id, vroot);
        }

        // the Vault keeps a copy of the original under vault\telemetry\<car>\<track>\<stamp>.ibt: found by that name when the original is gone
        static string CrVaultCopy(string name, string vroot)
        {
            if (string.IsNullOrEmpty(name) || !Regex.IsMatch(name, @"^[A-Za-z0-9 _.\-]+\.ibt$")) return null;
            if (string.IsNullOrEmpty(vroot)) vroot = Vault.Root;
            if (string.IsNullOrEmpty(vroot)) vroot = Path.Combine(Program.RootDir, "vault");
            try
            {
                string vt = Path.Combine(vroot, "telemetry");
                if (Directory.Exists(vt)) foreach (string f in Directory.GetFiles(vt, name, SearchOption.AllDirectories)) return f;
            }
            catch { }
            return null;
        }

        // ---------------- which files ----------------
        static CrMeta CrMetaOf(FileInfo fi, bool vault)
        {
            string key = fi.FullName + "|" + fi.Length.ToString(Inv) + "|" + fi.LastWriteTimeUtc.Ticks.ToString(Inv);
            lock (crGate) { CrMeta hit; if (crMeta.TryGetValue(key, out hit)) return hit; }
            CrMeta m = new CrMeta();
            m.Path = fi.FullName; m.Name = fi.Name; m.Size = fi.Length; m.Vault = vault;
            m.ModMs = (long)(fi.LastWriteTimeUtc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            try
            {
                TrackMaps.Ibt t = TrackMaps.OpenIbt(fi.FullName, false);
                if (t != null)
                    using (t.fs)
                    {
                        byte[] h = new byte[8]; t.fs.Position = 112; t.fs.Read(h, 0, 8); m.Ticks = BitConverter.ToInt64(h, 0);
                        string y = t.yaml ?? "";
                        m.Car = CarOf(y); m.Track = TrackMaps.YamlValue(y, "TrackDisplayName"); m.Config = TrackMaps.YamlValue(y, "TrackConfigName");
                        m.TrackName = TrackMaps.YamlValue(y, "TrackName"); m.TrackId = TrackMaps.YamlValue(y, "TrackID");
                    }
            }
            catch { }
            lock (crGate) { if (crMeta.Count > 3000) crMeta.Clear(); crMeta[key] = m; }
            return m;
        }

        static bool CrSame(string a, string b) { return !string.IsNullOrEmpty(a) && !string.IsNullOrEmpty(b) && string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase); }

        // every .ibt of the telemetry folder and of the Vault's copies (with their header facts)
        static List<CrMeta> CrScan(string dir, string vroot, string main, bool live, out int online, out int recent)
        {
            online = 0; recent = 0;
            List<CrMeta> all = new List<CrMeta>();
            List<string> paths = new List<string>(); List<bool> vflag = new List<bool>();
            try { if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir)) foreach (string f in Directory.GetFiles(dir, "*.ibt")) { paths.Add(f); vflag.Add(false); } } catch { }
            try
            {
                string vt = string.IsNullOrEmpty(vroot) ? "" : Path.Combine(vroot, "telemetry");
                if (vt.Length > 0 && Directory.Exists(vt)) foreach (string f in Directory.GetFiles(vt, "*.ibt", SearchOption.AllDirectories)) { paths.Add(f); vflag.Add(true); }
            }
            catch { }
            for (int i = 0; i < paths.Count; i++)
            {
                try
                {
                    FileInfo fi = new FileInfo(paths[i]);
                    if (Career.OnlineOnly(fi)) { online++; continue; }
                    if (live && fi.LastWriteTime > DateTime.Now.AddMinutes(-2) && !CrSame(paths[i], main)) { recent++; continue; }
                    all.Add(CrMetaOf(fi, vflag[i]));
                }
                catch { }
            }
            return all;
        }

        // this car at this track and layout; one entry per session (the original, not the Vault's copy of it), oldest first
        static List<CrMeta> CrCombo(List<CrMeta> all, string car, string track, string config)
        {
            Dictionary<string, CrMeta> by = new Dictionary<string, CrMeta>();
            foreach (CrMeta m in all)
            {
                if (m.Car != car || m.Track != track || m.Config != config) continue;
                string k = m.Ticks.ToString(Inv) + "|" + m.Size.ToString(Inv);
                CrMeta have;
                if (!by.TryGetValue(k, out have) || (have.Vault && !m.Vault)) by[k] = m;
            }
            List<CrMeta> hit = new List<CrMeta>(by.Values);
            hit.Sort(delegate (CrMeta a, CrMeta b) { int c = a.Ticks.CompareTo(b.Ticks); return c != 0 ? c : string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); });
            return hit;
        }

        // the corner list and a short signature of it: a file's cached corner times only count while the corner list is the same
        static CornerSet CrCorners(CrMeta m, out string sig)
        {
            Sess t = new Sess();
            t.Track = m.Track; t.Config = m.Config; t.TrackName = m.TrackName; t.TrackId = m.TrackId; t.Key = TrackMaps.MakeKey(m.TrackId, m.TrackName);
            CornerSet cs = LoadCorners(t);
            if (cs == null) cs = new CornerSet();
            StringBuilder sb = new StringBuilder();
            if (cs.Turns != null) foreach (CornerTurn tn in cs.Turns) sb.Append(tn.N.ToString(Inv)).Append(',').Append(F(tn.P0, "0.00000")).Append(',').Append(F(tn.Pa, "0.00000")).Append(',').Append(F(tn.P1, "0.00000")).Append(';');
            sig = Sha(sb.ToString()).Substring(0, 12) + "-" + (cs.Turns == null ? 0 : cs.Turns.Count).ToString(Inv);
            return cs;
        }

        // ---------------- what one file gives ----------------
        static string CrKey(CrMeta m) { return m.Ticks.ToString(Inv) + "|" + m.Size.ToString(Inv) + "|" + CrVersion.ToString(Inv); }

        static string CrDiskPath(string vroot, string key)
        {
            if (string.IsNullOrEmpty(vroot)) return null;
            string h = Sha(key).Substring(0, 20);
            return Path.Combine(vroot, "career", "c" + CrVersion.ToString(Inv) + "-" + h + ".json");      // the version is in the name: an older format is never read, and CrSweep deletes it
        }

        // memory, then disk; null = this file has to be read
        static CrFile CrLookup(CrMeta m, string sig, string vroot, CrCounts cc)
        {
            string key = CrKey(m);
            lock (crGate) { CrFile f; if (crFiles.TryGetValue(key, out f) && (f.Bad || f.CornerSig == sig)) { cc.Mem++; return f; } }
            string p = CrDiskPath(vroot, key);
            try
            {
                if (p != null && File.Exists(p))
                {
                    CrFile d = CrParse(File.ReadAllText(p, Encoding.UTF8));
                    if (d != null && d.CornerSig == sig && d.Ticks == m.Ticks && d.Size == m.Size)
                    {
                        lock (crGate) crFiles[key] = d;
                        cc.Disk++; return d;
                    }
                }
            }
            catch (Exception ex) { Log.W("career cache: " + ex.Message); }
            return null;
        }

        // reads the .ibt (or takes the lap store's copy when the workbench has it open) and keeps what the career needs
        static CrFile CrCompute(CrMeta m, CornerSet cs, string sig)
        {
            CrFile f = new CrFile();
            f.Ticks = m.Ticks; f.Size = m.Size; f.CornerSig = sig; f.Turns = cs.Turns == null ? 0 : cs.Turns.Count;
            try
            {
                Sess s = null;
                FileInfo fi = new FileInfo(m.Path);
                string csig = fi.FullName + "|" + fi.Length + "|" + fi.LastWriteTimeUtc.Ticks;
                lock (gate) { cache.TryGetValue(csig, out s); }
                if (s == null) s = Load(m.Path);       // not put in the lap store's cache: a hundred files would push out the one he is looking at
                f.Car = s.Car; f.Track = s.Track; f.Config = s.Config; f.LengthM = s.LengthM; f.SectorAt = s.SectorAt ?? new double[0];
                int ns = f.SectorAt.Length;
                string type = Career.SessionTypeOf(s.Yaml, -1);
                if (type.Length == 0) type = TrackMaps.YamlValue(s.Yaml, "EventType");
                f.Type = type;
                HashSet<int> full = new HashSet<int>(), seen = new HashSet<int>();
                long recs = 0;
                foreach (LapTrace lap in s.Laps)
                {
                    recs += Math.Max(0, lap.RecB - lap.RecA);
                    if (lap.Tm != null) full.Add(lap.Lap);
                }
                f.Full = full.Count;
                f.Seconds = Math.Round(recs / (double)TickRate(m.Path), 1);
                foreach (LapTrace lap in s.Laps)
                {
                    // the same lap the Session Review keeps: one per lap number, timed by iRacing, with its sectors ...
                    if (!Timed(lap) || lap.SectorT == null || lap.SectorT.Length != ns || lap.Mini == null || lap.Mini.Length != 24) continue;
                    if (seen.Contains(lap.Lap)) continue;
                    // ... and one iRacing itself counted (LapRules, analysis.cs): it announces a time for a lap with a brief off-track too (our C-30 rule forgives under 0.75 s) but does not
                    // count it - its own best lap of the session stays slower or empty (this file: 80.039 announced, LapBestLapTime stayed 80.916). Such a lap is real data, but it is left out here.
                    if (!Counted(lap)) { f.Uncounted++; continue; }
                    seen.Add(lap.Lap);
                    CrLap cl = new CrLap(); cl.N = lap.Lap; cl.Time = lap.Time; cl.Pure = Pure(lap);     // exact: nothing is rounded before the page shows it, so memory, disk and the Session Review agree to the last digit
                    cl.Sec = new double[ns]; for (int i = 0; i < ns; i++) cl.Sec[i] = lap.SectorT[i];
                    if (f.Turns > 0)
                    {
                        Measure(lap, cs);
                        cl.Cor = new double[f.Turns];
                        for (int k = 0; k < f.Turns; k++) cl.Cor[k] = k < lap.Corners.Count ? lap.Corners[k].Time : double.NaN;
                    }
                    f.Valid.Add(cl);
                }
                f.Valid.Sort(delegate (CrLap a, CrLap b) { return a.N.CompareTo(b.N); });
            }
            catch (Exception ex)
            {
                Log.W("career: could not read " + m.Name + ": " + ex.Message);
                f = new CrFile(); f.Ticks = m.Ticks; f.Size = m.Size; f.CornerSig = sig; f.Bad = true;
            }
            return f;
        }

        // once per run: cache files of an older format (another version number in the name) are of no use any more
        static string crSwept = "";
        static void CrSweep(string vroot)
        {
            string dir = Path.Combine(vroot, "career");
            if (crSwept == dir || !Directory.Exists(dir)) return;
            crSwept = dir;
            try
            {
                string keep = "c" + CrVersion.ToString(Inv) + "-";
                foreach (string f in Directory.GetFiles(dir, "c*-*.json")) if (!Path.GetFileName(f).StartsWith(keep, StringComparison.Ordinal)) File.Delete(f);
            }
            catch { }
        }

        static void CrStore(CrMeta m, CrFile f, string vroot)
        {
            string key = CrKey(m);
            lock (crGate) { if (crFiles.Count > 3000) crFiles.Clear(); crFiles[key] = f; }
            if (f.Bad) return;
            string p = CrDiskPath(vroot, key);
            if (p == null) return;
            try
            {
                CrSweep(vroot);
                Directory.CreateDirectory(Path.GetDirectoryName(p));
                File.WriteAllText(p + ".tmp", CrJson(f), new UTF8Encoding(false));
                if (File.Exists(p)) File.Delete(p);
                File.Move(p + ".tmp", p);
            }
            catch (Exception ex) { Log.W("career cache write: " + ex.Message); }
        }

        static string CrNums(double[] v, string fmt)
        {
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < v.Length; i++) { if (i > 0) sb.Append(','); sb.Append(CrN(v[i], fmt)); }
            return sb.Append(']').ToString();
        }

        static string CrJson(CrFile f)
        {
            StringBuilder sb = new StringBuilder(2048);
            sb.Append("{\"v\":").Append(CrVersion).Append(",\"ticks\":").Append(f.Ticks.ToString(Inv)).Append(",\"size\":").Append(f.Size.ToString(Inv));
            sb.Append(",\"car\":").Append(Json_.S(f.Car)).Append(",\"track\":").Append(Json_.S(f.Track)).Append(",\"config\":").Append(Json_.S(f.Config)).Append(",\"type\":").Append(Json_.S(f.Type));
            sb.Append(",\"lengthM\":").Append(F(f.LengthM, "0.0")).Append(",\"seconds\":").Append(F(f.Seconds, "0.0")).Append(",\"full\":").Append(f.Full).Append(",\"unc\":").Append(f.Uncounted).Append(",\"turns\":").Append(f.Turns);
            sb.Append(",\"cornerSig\":").Append(Json_.S(f.CornerSig)).Append(",\"sectorAt\":").Append(CrNums(f.SectorAt, "R")).Append(",\"laps\":[");
            for (int i = 0; i < f.Valid.Count; i++)
            {
                CrLap l = f.Valid[i]; if (i > 0) sb.Append(',');
                sb.Append('[').Append(l.N).Append(',').Append(CrN(l.Time, "R")).Append(',').Append(CrNums(l.Sec, "R")).Append(',').Append(l.Cor == null ? "null" : CrNums(l.Cor, "R")).Append(',').Append(l.Pure ? 1 : 0).Append(']');
            }
            return sb.Append("]}").ToString();
        }

        static object[] CrArr(object o) { return o as object[] ?? (o is System.Collections.ArrayList ? ((System.Collections.ArrayList)o).ToArray() : new object[0]); }
        static double CrD(object o) { double v; return o != null && double.TryParse(Convert.ToString(o, Inv), NumberStyles.Float, Inv, out v) ? v : double.NaN; }
        static double[] CrDs(object o) { object[] a = CrArr(o); double[] r = new double[a.Length]; for (int i = 0; i < a.Length; i++) r[i] = CrD(a[i]); return r; }

        static CrFile CrParse(string json)
        {
            JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue;
            Dictionary<string, object> d = js.DeserializeObject(json) as Dictionary<string, object>;
            if (d == null || (int)CrD(d.ContainsKey("v") ? d["v"] : null) != CrVersion) return null;
            CrFile f = new CrFile();
            f.Ticks = (long)CrD(d["ticks"]); f.Size = (long)CrD(d["size"]);
            f.Car = Convert.ToString(d["car"], Inv); f.Track = Convert.ToString(d["track"], Inv); f.Config = Convert.ToString(d["config"], Inv); f.Type = Convert.ToString(d["type"], Inv);
            f.LengthM = CrD(d["lengthM"]); f.Seconds = CrD(d["seconds"]); f.Full = (int)CrD(d["full"]); f.Uncounted = (int)CrD(d["unc"]); f.Turns = (int)CrD(d["turns"]); f.CornerSig = Convert.ToString(d["cornerSig"], Inv);
            f.SectorAt = CrDs(d["sectorAt"]);
            foreach (object lo in CrArr(d["laps"]))
            {
                object[] a = CrArr(lo); if (a.Length < 4) continue;
                CrLap l = new CrLap(); l.N = (int)CrD(a[0]); l.Time = CrD(a[1]); l.Sec = CrDs(a[2]); l.Cor = a[3] == null ? null : CrDs(a[3]); l.Pure = a.Length < 5 || CrD(a[4]) != 0;
                f.Valid.Add(l);
            }
            return f;
        }

        // ---------------- one request ----------------
        static string CrBuild(string dir, string vroot, string car, string track, string config, string main, bool live, bool background, out int code)
        {
            code = 200;
            Stopwatch sw = Stopwatch.StartNew();
            CrCounts cc = new CrCounts();
            int online, recent;
            List<CrMeta> all = CrScan(dir, vroot, main, live, out online, out recent);
            if (main != null)
            {
                // the combination is the open file's own
                CrMeta mm = null;
                foreach (CrMeta m in all) if (CrSame(m.Path, main)) { mm = m; break; }
                if (mm == null) mm = CrMetaOf(new FileInfo(main), false);
                if (mm.Car.Length == 0) { code = 404; return Err("not a telemetry file"); }
                car = mm.Car; track = mm.Track; config = mm.Config;
            }
            List<CrMeta> hit = CrCombo(all, car, track, config);
            if (hit.Count == 0) { code = 404; return Err("no laps of this car and track"); }
            string sig;
            CornerSet cs = CrCorners(hit[0], out sig);
            CrFile[] files = new CrFile[hit.Count];
            List<int> need = new List<int>();
            for (int i = 0; i < hit.Count; i++) { files[i] = CrLookup(hit[i], sig, vroot, cc); if (files[i] == null) need.Add(i); }
            if (need.Count > 0)
            {
                string ckey = car + "|" + track + "|" + config;
                if (background)
                {
                    lock (crGate)
                    {
                        if (crJob != null && !crJob.Finished)
                        {
                            CrJob j = crJob;
                            return "{\"building\":true,\"done\":" + j.Done + ",\"of\":" + j.Of + ",\"file\":" + Json_.S(j.Cur) + ",\"same\":" + (j.Key == ckey ? "true" : "false") + "}";
                        }
                        CrJob nj = new CrJob(); nj.Key = ckey; nj.Of = need.Count;
                        crJob = nj;
                        List<CrMeta> todo = new List<CrMeta>(); foreach (int i in need) todo.Add(hit[i]);
                        Thread th = new Thread(delegate () { CrWork(nj, todo, cs, sig, vroot, live); });
                        th.IsBackground = true; th.Priority = ThreadPriority.BelowNormal; th.Name = "Career"; th.Start();
                        return "{\"building\":true,\"done\":0,\"of\":" + need.Count + ",\"file\":\"\",\"same\":true}";
                    }
                }
                foreach (int i in need)
                {
                    files[i] = CrCompute(hit[i], cs, sig); cc.Computed++;
                    CrStore(hit[i], files[i], vroot);
                }
            }
            string reply = CrAggregate(hit, files, cs, vroot, car, track, config, online, recent, cc, sw);
            if (reply.StartsWith("{\"error\"", StringComparison.Ordinal)) code = 404;       // sessions found, but none with a counted lap
            return reply;
        }

        // the background reader: one file at a time, at BelowNormal, and it stops when he gets in the car (what is done stays cached)
        static void CrWork(CrJob job, List<CrMeta> todo, CornerSet cs, string sig, string vroot, bool live)
        {
            Stopwatch sw = Stopwatch.StartNew();
            try
            {
                foreach (CrMeta m in todo)
                {
                    if (live && Program.IsDriving) { job.Aborted = true; break; }
                    job.Cur = m.Name;
                    CrFile f = CrCompute(m, cs, sig);
                    CrStore(m, f, vroot);
                    job.Done++;
                    if (crSlowMs > 0) Thread.Sleep(crSlowMs);
                }
            }
            catch (Exception ex) { job.Error = ex.Message; Log.W("career: " + ex.Message); }
            finally
            {
                job.Finished = true;
                Log.W("career: read " + job.Done + " of " + job.Of + " sessions for " + job.Key + " in " + (sw.ElapsedMilliseconds / 1000.0).ToString("0.0", Inv) + " s" + (job.Aborted ? " (stopped: you got in the car)" : ""));
            }
        }

        // ---------------- the answer ----------------
        sealed class CrSess
        {
            public CrMeta M; public CrFile F; public CrLap Best; public double Avg5, Sd5, PbSoFar; public int N5; public bool NewPb;
            public double[][] Cn;      // per corner: { best, median, laps } or null
            public long StartMs;
        }

        static double CrMedian(List<double> v)
        {
            v.Sort(); int n = v.Count;
            if (n == 0) return double.NaN;
            return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2.0;
        }

        static string CrAggregate(List<CrMeta> hit, CrFile[] files, CornerSet cs, string vroot, string car, string track, string config, int online, int recent, CrCounts cc, Stopwatch sw)
        {
            int nT = cs.Turns == null ? 0 : cs.Turns.Count;
            List<CrSess> ss = new List<CrSess>();
            int skipped = 0, laps = 0, valid = 0, uncounted = 0; double seconds = 0;
            double lengthM = 0;
            for (int i = 0; i < hit.Count; i++)
            {
                CrFile f = files[i];
                if (f == null || f.Bad || f.Valid.Count == 0) { skipped++; continue; }
                CrSess s = new CrSess(); s.M = hit[i]; s.F = f;
                s.StartMs = s.M.Ticks > 1000000000L && s.M.Ticks < 4000000000L ? s.M.Ticks * 1000L : s.M.ModMs;
                List<double> times = new List<double>();
                foreach (CrLap l in f.Valid)
                {
                    times.Add(l.Time);
                    if (s.Best == null || l.Time < s.Best.Time - 1e-9) s.Best = l;
                }
                times.Sort();
                s.N5 = times.Count < 5 ? times.Count : 5;
                for (int k = 0; k < s.N5; k++) s.Avg5 += times[k];
                s.Avg5 /= s.N5;
                for (int k = 0; k < s.N5; k++) s.Sd5 += (times[k] - s.Avg5) * (times[k] - s.Avg5);
                s.Sd5 = Math.Sqrt(s.Sd5 / s.N5);
                s.Cn = new double[nT][];
                for (int k = 0; k < nT; k++)
                {
                    List<double> v = new List<double>(); double b = double.MaxValue;
                    foreach (CrLap l in f.Valid)
                        if (l.Cor != null && k < l.Cor.Length && !double.IsNaN(l.Cor[k])) { v.Add(l.Cor[k]); if (l.Cor[k] < b) b = l.Cor[k]; }
                    s.Cn[k] = v.Count == 0 ? null : new double[] { b, CrMedian(v), v.Count };
                }
                ss.Add(s);
                laps += f.Full; valid += f.Valid.Count; uncounted += f.Uncounted; seconds += f.Seconds;
                if (lengthM <= 0) lengthM = f.LengthM;
            }
            if (ss.Count == 0) return Err("no timed laps of this car and track yet");

            // PB evolution: the best lap of every session, and the running best
            double run = double.MaxValue; CrSess pbS = null;
            foreach (CrSess s in ss)
            {
                s.NewPb = s.Best.Time < run - 1e-9;
                if (s.NewPb) run = s.Best.Time;
                s.PbSoFar = run;
                if (pbS == null || s.Best.Time < pbS.Best.Time - 1e-9) pbS = s;
            }

            // theoretical best: the best iRacing sector ever, joined. Only sessions with the same sector layout.
            double[] refAt = ss[0].F.SectorAt; int nS = refAt.Length;
            double[] bestSec = new double[nS]; CrSess[] bestFrom = new CrSess[nS]; int[] bestLap = new int[nS];
            for (int k = 0; k < nS; k++) bestSec[k] = double.MaxValue;
            foreach (CrSess s in ss)
            {
                bool same = s.F.SectorAt.Length == nS;
                for (int k = 0; same && k < nS; k++) if (Math.Abs(s.F.SectorAt[k] - refAt[k]) > 1e-5) same = false;
                if (!same) continue;
                foreach (CrLap l in s.F.Valid)
                {
                    if (!l.Pure) continue;      // a lap with an off-track record is a counted lap, but its sectors are not joined
                    for (int k = 0; k < nS; k++)
                    {
                        double ms = Math.Round(l.Sec[k], 3, MidpointRounding.AwayFromZero);
                        if (ms < bestSec[k] - 1e-9) { bestSec[k] = ms; bestFrom[k] = s; bestLap[k] = l.N; }
                    }
                }
            }
            bool haveTh = nS > 1; double theo = 0;
            for (int k = 0; k < nS; k++) { if (bestFrom[k] == null) haveTh = false; else theo += bestSec[k]; }
            if (haveTh && pbS != null && theo > pbS.Best.Time + 0.0005) haveTh = false;      // the PB lap had an off-track and is quicker than anything that can be joined: no theoretical

            StringBuilder sb = new StringBuilder(16384);
            sb.Append("{\"v\":1,\"car\":").Append(Json_.S(car)).Append(",\"track\":").Append(Json_.S(track)).Append(",\"config\":").Append(Json_.S(config));
            sb.Append(",\"lengthM\":").Append(F(lengthM, "0.0")).Append(",\"credit\":").Append(Json_.S(cs.Credit ?? "")).Append(",\"cornerSource\":").Append(Json_.S(cs.Source ?? ""));
            sb.Append(",\"turns\":[");
            for (int k = 0; k < nT; k++)
            {
                CornerTurn tn = cs.Turns[k]; if (k > 0) sb.Append(',');
                sb.Append("{\"n\":").Append(tn.N).Append(",\"label\":").Append(Json_.S(LabelOf(tn))).Append(",\"name\":").Append(Json_.S(tn.Name ?? "")).Append(",\"official\":").Append(Json_.S(tn.Official ?? "")).Append('}');
            }
            sb.Append("],\"sectorAt\":").Append(CrNums(refAt, "0.000000")).Append(",\"sessions\":[");
            for (int i = 0; i < ss.Count; i++)
            {
                CrSess s = ss[i]; if (i > 0) sb.Append(',');
                sb.Append("{\"i\":").Append(i).Append(",\"file\":").Append(Json_.S(s.M.Name)).Append(",\"vault\":").Append(s.M.Vault ? "true" : "false").Append(",\"startMs\":").Append(s.StartMs.ToString(Inv));
                sb.Append(",\"type\":").Append(Json_.S(s.F.Type)).Append(",\"seconds\":").Append(F(s.F.Seconds, "0")).Append(",\"laps\":").Append(s.F.Full).Append(",\"valid\":").Append(s.F.Valid.Count).Append(",\"uncounted\":").Append(s.F.Uncounted);
                sb.Append(",\"best\":").Append(F(s.Best.Time, "0.000")).Append(",\"bestLap\":").Append(s.Best.N).Append(",\"newPb\":").Append(s.NewPb ? "true" : "false").Append(",\"pbSoFar\":").Append(F(s.PbSoFar, "0.000"));
                sb.Append(",\"avg5\":").Append(F(s.Avg5, "0.000")).Append(",\"sd5\":").Append(F(s.Sd5, "0.000")).Append(",\"n5\":").Append(s.N5);
                sb.Append(",\"lapN\":["); for (int k = 0; k < s.F.Valid.Count; k++) { if (k > 0) sb.Append(','); sb.Append(s.F.Valid[k].N); }
                sb.Append("],\"lapT\":["); for (int k = 0; k < s.F.Valid.Count; k++) { if (k > 0) sb.Append(','); sb.Append(F(s.F.Valid[k].Time, "0.000")); }
                sb.Append("],\"c\":[");
                for (int k = 0; k < nT; k++)
                {
                    if (k > 0) sb.Append(',');
                    double[] c = s.Cn[k];
                    if (c == null) sb.Append("null"); else sb.Append('[').Append(F(c[0], "0.000")).Append(',').Append(F(c[1], "0.000")).Append(',').Append(((int)c[2]).ToString(Inv)).Append(']');
                }
                sb.Append("]}");
            }
            int pbI = ss.IndexOf(pbS);
            sb.Append("],\"pb\":{\"i\":").Append(pbI).Append(",\"file\":").Append(Json_.S(pbS.M.Name)).Append(",\"lap\":").Append(pbS.Best.N).Append(",\"time\":").Append(F(pbS.Best.Time, "0.000")).Append(",\"startMs\":").Append(pbS.StartMs.ToString(Inv));
            sb.Append(",\"sectors\":").Append(CrNums(pbS.Best.Sec, "0.000")).Append('}');
            sb.Append(",\"theoretical\":");
            if (!haveTh) sb.Append("null");
            else
            {
                sb.Append("{\"time\":").Append(F(theo, "0.000")).Append(",\"gap\":").Append(F(pbS.Best.Time - theo, "0.000")).Append(",\"sectors\":[");
                for (int k = 0; k < nS; k++)
                {
                    if (k > 0) sb.Append(',');
                    sb.Append("{\"k\":").Append(k).Append(",\"time\":").Append(F(bestSec[k], "0.000")).Append(",\"i\":").Append(ss.IndexOf(bestFrom[k])).Append(",\"lap\":").Append(bestLap[k]).Append('}');
                }
                sb.Append("]}");
            }
            DateTime ep = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
            sb.Append(",\"totals\":{\"sessions\":").Append(ss.Count).Append(",\"laps\":").Append(laps).Append(",\"valid\":").Append(valid).Append(",\"uncounted\":").Append(uncounted).Append(",\"seconds\":").Append(F(seconds, "0"))
              .Append(",\"files\":").Append(hit.Count).Append(",\"skipped\":").Append(skipped).Append(",\"online\":").Append(online).Append(",\"recent\":").Append(recent)
              .Append(",\"firstMs\":").Append(ss[0].StartMs.ToString(Inv)).Append(",\"lastMs\":").Append(ss[ss.Count - 1].StartMs.ToString(Inv)).Append('}');
            sb.Append(",\"races\":");
            sb.Append(CrRacesJson(vroot, car, track, config, ss));
            sb.Append(",\"stats\":{\"computed\":").Append(cc.Computed).Append(",\"disk\":").Append(cc.Disk).Append(",\"mem\":").Append(cc.Mem).Append(",\"ms\":").Append(sw.ElapsedMilliseconds).Append("}}");
            return sb.ToString();
        }

        // ---------------- races: the logs of vault\field that are Peter's car at this track (only the ones that exist) ----------------
        static string CrRacesJson(string vroot, string car, string track, string config, List<CrSess> ss)
        {
            List<CrRace> rs = new List<CrRace>();
            try
            {
                string fd = string.IsNullOrEmpty(vroot) ? "" : Path.Combine(vroot, "field");
                if (fd.Length > 0 && Directory.Exists(fd))
                    foreach (string f in Directory.GetFiles(fd, "f*.json"))
                    {
                        CrRace r = CrRaceOf(f);
                        if (r != null && r.Car == car && ((r.Track == track && r.Config == config))) rs.Add(r);
                    }
            }
            catch (Exception ex) { Log.W("career races: " + ex.Message); }
            rs.Sort(delegate (CrRace a, CrRace b) { return a.StartMs.CompareTo(b.StartMs); });
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < rs.Count; i++)
            {
                CrRace r = rs[i]; if (i > 0) sb.Append(',');
                // the session of his own telemetry that ran inside the race's time window (the RACE page of that session shows the race itself)
                int at = -1; long near = long.MaxValue;
                for (int k = 0; k < ss.Count; k++)
                {
                    long a = ss[k].StartMs - 300000, b = Math.Max(ss[k].M.ModMs, ss[k].StartMs + (long)(ss[k].F.Seconds * 1000)) + 300000;
                    if (r.StartMs >= a && r.StartMs <= b && Math.Abs(r.StartMs - ss[k].StartMs) < near) { at = k; near = Math.Abs(r.StartMs - ss[k].StartMs); }
                }
                sb.Append("{\"id\":").Append(Json_.S(r.Id)).Append(",\"startMs\":").Append(r.StartMs.ToString(Inv)).Append(",\"name\":").Append(Json_.S(r.Name)).Append(",\"pos\":").Append(r.Pos).Append(",\"cpos\":").Append(r.CPos)
                  .Append(",\"field\":").Append(r.Field).Append(",\"classCars\":").Append(r.ClassCars).Append(",\"multiClass\":").Append(r.Class ? "true" : "false").Append(",\"laps\":").Append(r.Laps)
                  .Append(",\"gap\":").Append(CrN(r.Gap, "0.000")).Append(",\"gapLaps\":").Append(r.GapLaps).Append(",\"total\":").Append(CrN(r.Total, "0.000")).Append(",\"winTotal\":").Append(CrN(r.WinTotal, "0.000"))
                  .Append(",\"best\":").Append(CrN(r.Best, "0.000")).Append(",\"inc\":").Append(r.Inc).Append(",\"out\":").Append(r.Out ? "true" : "false").Append(",\"complete\":").Append(r.Complete ? "true" : "false")
                  .Append(",\"cpath\":").Append(Json_.S(r.CarPath)).Append(",\"dz\":").Append(Json_.S(r.Design)).Append(",\"num\":").Append(Json_.S(r.Num)).Append(",\"col\":").Append(Json_.S(r.Color))
                  .Append(",\"session\":").Append(at).Append('}');
            }
            return sb.Append(']').ToString();
        }

        // one race log -> his result (null for anything that is not a race of his)
        static CrRace CrRaceOf(string path)
        {
            long mt = File.GetLastWriteTimeUtc(path).Ticks; string key = path + "|" + mt.ToString(Inv);
            lock (crGate) { CrRace hit; if (crRaces.TryGetValue(key, out hit)) return hit; }
            CrRace r = null;
            try
            {
                RfData d = RfData.FromJson(File.ReadAllText(path, Encoding.UTF8));
                if (d != null && d.IsRace && d.Me >= 0)
                {
                    RfCar me = d.Car(d.Me);
                    if (me != null)
                    {
                        JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue;
                        Dictionary<string, object> sm = js.DeserializeObject(RfSummary.Build(d)) as Dictionary<string, object>;
                        object[] tower = sm == null || !sm.ContainsKey("tower") ? new object[0] : CrArr(sm["tower"]);
                        Dictionary<string, object> mine = null, lead = null;
                        int classCars = 0; HashSet<string> classes = new HashSet<string>();
                        foreach (RfCar c in d.Cars) { classes.Add(c.Cls); if (c.Cls == me.Cls) classCars++; }
                        foreach (object to in tower)
                        {
                            Dictionary<string, object> t = to as Dictionary<string, object>; if (t == null) continue;
                            RfCar tc = d.Car((int)CrD(t["i"]));
                            if ((int)CrD(t["i"]) == d.Me) mine = t;
                            if (tc != null && tc.Cls == me.Cls && (int)CrD(t["cpos"]) == 1) lead = t;
                        }
                        if (mine != null)
                        {
                            r = new CrRace();
                            r.Id = d.Id; r.StartMs = d.StartMs; r.EndMs = d.EndMs; r.Name = d.SessName.Length > 0 ? d.SessName : d.SessType; r.Car = me.Car; r.Key = d.Key; r.Track = d.Track; r.Config = d.Config; r.CarPath = me.Path; r.Design = me.Design; r.Num = me.Num; r.Color = me.Color;
                            r.Pos = (int)CrD(mine["pos"]); r.CPos = (int)CrD(mine["cpos"]); r.Field = tower.Length; r.ClassCars = classCars; r.Class = classes.Count > 1;
                            r.Laps = (int)CrD(mine["laps"]); r.GapLaps = (int)CrD(mine["gapLaps"]); r.Gap = CrD(mine["gap"]); r.Total = CrD(mine["total"]); r.Best = CrD(mine["best"]); r.Inc = (int)CrD(mine["inc"]);
                            r.Out = mine["out"] is bool && (bool)mine["out"]; r.Complete = d.Complete;
                            if (lead != null) r.WinTotal = CrD(lead["total"]);
                        }
                    }
                }
            }
            catch (Exception ex) { Log.W("career race " + Path.GetFileName(path) + ": " + ex.Message); r = null; }
            lock (crGate) { if (crRaces.Count > 500) crRaces.Clear(); crRaces[key] = r; }
            return r;
        }
    }
}
