// LIBRARY (W1-1, docs/rework/cards/W1-1.md): SessionIndex (one list of recorded sessions with their lap truth) and Library
// (the RACES door: trash with undo, retention, thumbnails made between sessions, the storage line, the markers of a race).
// Peter 2026-11-12: "delete when done so I don't nuke the hard drive", "deleting from HD needs to be easy and clear".
// So: a delete is a rename into vault\trash (instant, UNDO for 60 s on the server), the trash empties itself after 14 days,
// practice and qualifying go to the trash after 14 days, and nothing automatic ever removes a race or a Kept session.
// The recorder still owns its session list and its lock (recorder.cs, the Lib* accessors); this file only asks and moves files.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    sealed class RaceMarker { public double Sec; public string Kind = "", Label = ""; public int Order; }

    // one recorded session as every page and the deck sees it
    sealed class RaceInfo
    {
        public string Id = "", Track = "", Config = "", Car = "", Type = "", File = "", Sidecar = "", ExportPath = "";
        public bool IsRace, InTrash;
        public bool Kept;               // Peter pressed KEEP ("keptBy":"peter"); a race kept by AutoKeep is not "Kept" here
        public bool Saved;              // in vault\saved (Peter's KEEP or AutoKeep): nothing automatic removes it
        public bool Recovered;          // rebuilt from segments after a crash: its type may be unknown, so it is treated as a race
        public double StartMs, Sec, Best, DeletedMs, Created;
        public int Laps, Counted, BestLap;
        public long Bytes;
        public List<RaceMarker> Markers = new List<RaceMarker>();
        public string From = "";        // trash only: "sessions" or "saved", where UNDO puts it back
        public bool WasExported;        // trash only: it was in Videos\Paddock, so UNDO puts the link back
        public bool NoNote;             // trash only: its .trash note is missing, so nobody knows when it was deleted: never emptied by itself
        public bool Busy;               // SAVE is moving it right now
        public double MB { get { return Bytes / 1048576.0; } }
    }

    static class SessionIndex
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly object cacheGate = new object();
        static List<RaceInfo> cache; static string cacheKey = ""; static bool cacheLight; static double cacheAt;

        // the rule used everywhere today (deck plugin.html isRace, Recorder.AutoKeep): "race" in the type, not qualifying or practice
        public static bool IsRaceType(string t)
        {
            t = t ?? "";
            return Regex.IsMatch(t, "race", RegexOptions.IgnoreCase) && !Regex.IsMatch(t, "qual|prac", RegexOptions.IgnoreCase);
        }
        // what retention and the low-disk clean-up may ever take by themselves: a session that SAYS practice or qualifying. An unknown
        // type ("", a session rebuilt after a crash) counts as a race: never aged, never taken.
        public static bool PracticeOrQualify(string type, bool recovered)
        {
            return !recovered && Regex.IsMatch(type ?? "", "prac|qual", RegexOptions.IgnoreCase);
        }

        // what changes the list: which sessions, where their files are, how they are kept (cheap: no file is opened)
        static string Key(List<RecSess> all)
        {
            StringBuilder k = new StringBuilder(Library.Version.ToString(Inv));
            foreach (RecSess s in all) k.Append('|').Append(s.Id).Append(s.Saved ? 'S' : 's').Append(s.PeterKept ? 'P' : 'p').Append(s.Saving ? 'B' : 'b').Append(s.Bytes).Append('/').Append(s.LapRows.Count).Append(s.File);
            return k.ToString();
        }

        // every finished session on disk, newest first (the recorder's list; the trash is Library.TrashList).
        // Cached until the list changes; light = no telemetry lookup and no markers (the deck's list during a session).
        public static List<RaceInfo> All() { return All(false); }
        public static List<RaceInfo> All(bool light)
        {
            List<RecSess> sess = Recorder.LibFinished();
            string key = Key(sess);
            lock (cacheGate)
            {
                // a full list goes stale only when the recorder's list changes, or after 2 minutes between sessions (a telemetry file read later can fix a best lap)
                bool fresh = cache != null && cacheKey == key && (light || !cacheLight) && (light || Library.Now - cacheAt < 120000 || RigState.SessionOn);
                if (fresh) return new List<RaceInfo>(cache);
            }
            List<RaceInfo> all = new List<RaceInfo>();
            foreach (RecSess s in sess)
            {
                if (s.File.Length == 0 || !System.IO.File.Exists(s.File)) continue;
                all.Add(From(s, light));
            }
            all.Sort(delegate (RaceInfo a, RaceInfo b) { return b.StartMs.CompareTo(a.StartMs); });
            lock (cacheGate) { cache = all; cacheKey = key; cacheLight = light; cacheAt = Library.Now; }
            return new List<RaceInfo>(all);
        }
        internal static void Forget() { lock (cacheGate) cache = null; }

        public static RaceInfo Get(string id)
        {
            foreach (RaceInfo r in All()) if (r.Id == id) return r;
            return null;
        }

        internal static RaceInfo From(RecSess s) { return From(s, false); }
        internal static RaceInfo From(RecSess s, bool light)
        {
            RaceInfo r = new RaceInfo();
            r.Id = s.Id; r.Track = s.Track; r.Config = s.Config; r.Car = s.Car; r.Type = s.Type; r.IsRace = IsRaceType(s.Type);
            r.StartMs = s.StartMs; r.Sec = s.Duration; r.Kept = s.PeterKept && s.Saved; r.Saved = s.Saved; r.Recovered = s.Recovered; r.Busy = s.Saving; r.Created = s.Created;
            r.File = s.File; r.Sidecar = s.File.Length > 0 ? Path.ChangeExtension(s.File, ".json") : "";
            r.Bytes = s.Bytes;
            if (r.Bytes <= 0) { try { r.Bytes = new FileInfo(s.File).Length; } catch { } }
            try { r.ExportPath = Recorder.LibExportPath(s); } catch { }
            int laps, counted, bestN; double best;
            Recorder.RaceLaps(s, !light, out laps, out counted, out best, out bestN);
            r.Laps = laps; r.Counted = counted; r.Best = best; r.BestLap = bestN;
            if (!light) r.Markers = Markers(s, best, bestN);
            return r;
        }

        // the moments of a race for the OPEN card's timeline and the YouTube chapters, from the sidecar (offsets in seconds into the video)
        public static List<RaceMarker> Markers(RecSess s, double best, int bestN)
        {
            List<RaceMarker> m = new List<RaceMarker>();
            double start = 0; double[] last = null;
            foreach (double[] r in s.LapRows)
            {
                if (r.Length < 3 || double.IsNaN(r[1])) continue;          // a lap with no video (a gap) has no moment to jump to
                if ((int)r[0] == 1) start = r[1];
                if (last == null || r[1] > last[1]) last = r;
            }
            Add(m, start, "start", "Start");
            foreach (double[] r in s.Incidents)
            {
                if (r.Length < 2 || double.IsNaN(r[0])) continue;
                Add(m, r[0], "incident", "Incident +" + ((int)r[1]).ToString(Inv) + "x");
            }
            foreach (double[] r in s.LapRows)
                if (r.Length > 7 && r[7] == 1 && !double.IsNaN(r[1])) Add(m, r[1], "pit", "Pit (lap " + ((int)r[0]).ToString(Inv) + ")");
            if (best > 0 && bestN > 0)
                foreach (double[] r in s.LapRows)
                    if ((int)r[0] == bestN && !double.IsNaN(r[1])) { Add(m, r[1], "best", "Best lap " + PbRef.Lap(best) + " (lap " + bestN.ToString(Inv) + ")"); break; }
            if (last != null && last[2] > 0) Add(m, last[1] + last[2], "finish", "Finish");
            // in time order; on the same second the start comes first and the finish last
            m.Sort(delegate (RaceMarker a, RaceMarker b) { int c = a.Sec.CompareTo(b.Sec); return c != 0 ? c : a.Order.CompareTo(b.Order); });
            return m;
        }

        static void Add(List<RaceMarker> m, double sec, string kind, string label)
        {
            RaceMarker x = new RaceMarker(); x.Sec = Math.Max(0, sec); x.Kind = kind; x.Label = label;
            x.Order = kind == "start" ? 0 : kind == "finish" ? 9 : m.Count + 1;
            m.Add(x);
        }
    }

    static class Library
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly object gate = new object();
        const double Gb = 1073741824.0;
        public const int TrashDays = 14, PracticeDays = 14;
        const double FreeShare = 0.15;              // "low space" and the target of FREE UP SPACE: 15 % of the volume free
        const double UndoMs = 60000;                // the page offers UNDO for 8 s; the server keeps the batch for 60 s (a slow press still works)
        const double DefaultRaceBytes = 1.2 * Gb;   // "about N more races" before any race was recorded
        const double AnswerMs = 2000;               // a repeated press within 2 s gets the first press's answer again

        // ---- the two hooks the lead wires at merge time (W1-2, YouTube, is built in parallel) ----
        public static Func<string, string> ShareState;     // race id -> {"kind":"none|queued|sharing|shared|failed|signin|offline",...}
        public static Func<string> YouTubeJson;            // {"signedIn":..,"privacy":..,"template":..}
        // ---- for the tests ----
        public static Func<string, long[]> Disk;            // path -> {free bytes, volume size}; null = Windows
        public static Func<double> Clock;                   // wall ms; null = the recorder's clock
        internal static Action<string> AfterThumb;          // called after each thumbnail (test 7 starts a session mid-way)

        internal static double Now { get { return Clock != null ? Clock() : Recorder.WallMs(); } }
        static string TrashDir { get { return Path.Combine(Recorder.LibVaultRoot, "trash"); } }
        static string ThumbDir { get { return Path.Combine(Recorder.LibVaultRoot, "thumbs"); } }
        public static string ThumbPath(string id, bool small) { return Path.Combine(ThumbDir, "race-" + id + (small ? "-144" : "") + ".jpg"); }
        public static bool IdOk(string id) { return id != null && Regex.IsMatch(id, "^[A-Za-z0-9._-]{1,80}$"); }

        sealed class Batch { public string Id = ""; public double Ms; public List<RaceInfo> Items = new List<RaceInfo>(); }
        static readonly Dictionary<string, Batch> batches = new Dictionary<string, Batch>();
        static int batchNo;

        // the list's version: every change here; the cached lists (SessionIndex, the trash) are rebuilt when it moves
        static long version;
        internal static long Version { get { return Interlocked.Read(ref version); } }
        static void Changed()
        {
            Interlocked.Increment(ref version);
            try { StateBuilder.BumpLists(false, false, true, false); } catch { }
        }

        // ---------------- disk ----------------
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetDiskFreeSpaceEx(string dir, out ulong avail, out ulong total, out ulong free);
        static long[] Measure()
        {
            string root = Recorder.LibVaultRoot;
            if (Disk != null) return Disk(root);
            try { ulong a, t, f; if (GetDiskFreeSpaceEx(Path.GetPathRoot(Path.GetFullPath(root)), out a, out t, out f)) return new long[] { (long)a, (long)t }; } catch { }
            return new long[] { long.MaxValue / 4, long.MaxValue / 2 };
        }
        static long FreeNow() { return Measure()[0]; }

        static string Kind(string id)
        {
            Func<string, string> h = ShareState;
            if (h == null) return "none";
            try { Match m = Regex.Match(h(id) ?? "", "\"kind\"\\s*:\\s*\"([a-z]+)\""); return m.Success ? m.Groups[1].Value : "none"; } catch { return "none"; }
        }
        // an upload waiting or running holds the file: nothing automatic touches it
        static bool Uploading(string id) { string k = Kind(id); return k == "queued" || k == "sharing"; }

        // ---------------- the trash ----------------
        // <id>.mp4 + <id>.json moved here, and <id>.trash: "deletedMs<TAB>sessions|saved<TAB>1 if it was in Videos\Paddock"
        static List<RaceInfo> trashCache; static string trashKey = "";
        static readonly HashSet<string> noNoteSaid = new HashSet<string>();
        public static List<RaceInfo> TrashList()
        {
            string key = "";
            try { key = Version + "|" + TrashDir + "|" + (Directory.Exists(TrashDir) ? Directory.GetLastWriteTimeUtc(TrashDir).Ticks.ToString(Inv) : "none"); } catch { }
            lock (noNoteSaid) if (trashCache != null && key == trashKey) return new List<RaceInfo>(trashCache);
            List<RaceInfo> list = new List<RaceInfo>();
            try
            {
                if (Directory.Exists(TrashDir))
                    foreach (string j in Directory.GetFiles(TrashDir, "*.json"))
                    {
                        RecSess s = Recorder.LibRead(j);
                        if (s == null || s.Id.Length == 0) continue;
                        RaceInfo r = new RaceInfo();
                        r.Id = s.Id; r.Track = s.Track; r.Config = s.Config; r.Car = s.Car; r.Type = s.Type; r.IsRace = SessionIndex.IsRaceType(s.Type);
                        r.StartMs = s.StartMs; r.Sec = s.Duration; r.Kept = s.PeterKept && s.Saved; r.Saved = s.Saved; r.Recovered = s.Recovered; r.InTrash = true; r.Bytes = s.Bytes;
                        r.File = Path.ChangeExtension(j, ".mp4"); r.Sidecar = j;
                        if (r.Bytes <= 0) { try { r.Bytes = new FileInfo(r.File).Length; } catch { } }
                        try { r.ExportPath = Recorder.LibExportPath(s); } catch { }
                        r.From = s.Saved ? "saved" : "sessions";
                        string mk = Path.ChangeExtension(j, ".trash");
                        try
                        {
                            if (File.Exists(mk))
                            {
                                string[] p = File.ReadAllText(mk).Trim().Split('\t');
                                double d; if (p.Length > 0 && double.TryParse(p[0], NumberStyles.Float, Inv, out d)) r.DeletedMs = d;
                                if (p.Length > 1 && (p[1] == "saved" || p[1] == "sessions")) r.From = p[1];
                                r.WasExported = p.Length > 2 && p[2] == "1";
                            }
                        }
                        catch { }
                        if (r.DeletedMs <= 0)
                        {
                            // never guessed from the sidecar's time (that is when it was recorded): kept until Peter empties the trash himself
                            r.NoNote = true; r.DeletedMs = Now;
                            bool say; lock (noNoteSaid) say = noNoteSaid.Add(r.Id);
                            if (say) Log.W("library: " + r.Id + " is in the trash without its note - it stays until EMPTY NOW");
                        }
                        list.Add(r);
                    }
            }
            catch (Exception ex) { Log.W("library: could not read the trash (" + ex.Message + ")"); }
            list.Sort(delegate (RaceInfo a, RaceInfo b) { return b.DeletedMs.CompareTo(a.DeletedMs); });
            lock (noNoteSaid) { trashCache = list; trashKey = key; }
            return new List<RaceInfo>(list);
        }
        // the trash's size from the file sizes alone (the deck's storage line: no sidecar is read)
        static long TrashBytesQuick()
        {
            long b = 0;
            try { if (Directory.Exists(TrashDir)) foreach (string f in Directory.GetFiles(TrashDir, "*.mp4")) b += new FileInfo(f).Length; } catch { }
            return b;
        }

        public static int DaysLeft(RaceInfo r) { return r.NoNote ? TrashDays : Math.Max(0, (int)Math.Ceiling(TrashDays - (Now - r.DeletedMs) / 86400000.0)); }

        // Move one finished session into the trash. "" = done, else why not (RECORDING / BUSY / NOTHING / IN USE / NOT HERE / NO NOTE).
        static string MoveToTrash(string id, out RaceInfo moved)
        {
            moved = null;
            string busy = Recorder.LibBusy(id);
            if (busy.Length > 0) return busy;
            RecSess s = Recorder.LibFind(id);
            if (s == null || s.File.Length == 0 || !File.Exists(s.File)) return "NOTHING";
            // only files of the vault that is active now (2026-10-15/18: a stale list of the other vault deleted four real race videos)
            if (!Recorder.LibInVault(s.File)) { Log.W("library: " + s.Id + " is not in the active vault - not moved"); return "NOT HERE"; }
            RaceInfo r = SessionIndex.From(s, true);
            r.From = s.File.StartsWith(Recorder.LibSavedDir, StringComparison.OrdinalIgnoreCase) ? "saved" : "sessions";
            r.WasExported = r.ExportPath.Length > 0 && File.Exists(r.ExportPath);
            string mp4 = s.File, json = Path.ChangeExtension(mp4, ".json");
            string tMp4 = Path.Combine(TrashDir, s.Id + ".mp4"), tJson = Path.ChangeExtension(tMp4, ".json"), tMark = Path.ChangeExtension(tMp4, ".trash");
            try
            {
                Directory.CreateDirectory(TrashDir);
                foreach (string old in new string[] { tMp4, tJson, tMark }) if (File.Exists(old)) File.Delete(old);
                File.Move(mp4, tMp4);       // same folder tree, same volume: a rename, instant
            }
            catch (Exception ex) { Log.W("library: could not move " + s.Id + " to the trash (" + ex.Message + ")"); return "IN USE"; }
            try { if (File.Exists(json)) File.Move(json, tJson); }
            catch (Exception ex)
            {
                try { File.Move(tMp4, mp4); } catch { }
                Log.W("library: could not move the sidecar of " + s.Id + " to the trash (" + ex.Message + ")"); return "IN USE";
            }
            // the note says when it was deleted; without it the trash could not age it, so no note = no trash (the files go back)
            try { if (TestNoteFails) throw new IOException("test"); File.WriteAllText(tMark, Now.ToString("0", Inv) + "\t" + r.From + "\t" + (r.WasExported ? "1" : "0")); }
            catch (Exception ex)
            {
                try { File.Delete(tMark); } catch { }
                try { if (File.Exists(tJson)) File.Move(tJson, json); } catch { }
                try { File.Move(tMp4, mp4); } catch { }
                Log.W("library: could not write the trash note of " + s.Id + " (" + ex.Message + ") - left where it was"); return "NO NOTE";
            }
            Recorder.LibForget(s);
            // the Videos\Paddock copy is the same file (a hard link): it goes too, or the space is never freed
            try { if (r.WasExported) File.Delete(r.ExportPath); } catch (Exception ex) { Log.W("library: could not remove the Videos\\Paddock copy of " + s.Id + " (" + ex.Message + ")"); }
            r.File = tMp4; r.Sidecar = tJson; r.InTrash = true; r.DeletedMs = Now;
            moved = r;
            return "";
        }
        internal static bool TestNoteFails;        // test: the .trash note cannot be written

        public sealed class TrashResult { public string Batch = "", Why = ""; public int Count, Refused; public long Bytes; }

        // DELETE (one press, no "are you sure"): into the trash, UNDO-able for 60 s, gone for good after 14 days. A Kept race CAN be
        // trashed by this explicit press (Peter chose it); nothing automatic ever trashes one.
        public static TrashResult Trash(IList<string> ids)
        {
            TrashResult res = new TrashResult();
            lock (gate)
            {
                Batch b = new Batch(); b.Ms = Now; b.Id = "b" + ((long)b.Ms).ToString(Inv) + "-" + (++batchNo).ToString(Inv);
                foreach (string id in ids)
                {
                    if (!IdOk(id)) continue;
                    RaceInfo r; string why = MoveToTrash(id, out r);
                    if (why.Length > 0) { if (res.Why.Length == 0) res.Why = why; res.Refused++; continue; }
                    b.Items.Add(r); res.Count++; res.Bytes += r.Bytes;
                }
                if (b.Items.Count > 0) { batches[b.Id] = b; res.Batch = b.Id; }
                Purge();
            }
            if (res.Count > 0)
            {
                Log.W("library: " + res.Count + " race" + (res.Count == 1 ? "" : "s") + " moved to the trash (" + (res.Bytes / 1048576) + " MB, batch " + res.Batch + ")" + (res.Refused > 0 ? ", " + res.Refused + " not (" + res.Why + ")" : ""));
                Changed();
            }
            return res;
        }

        // the old deck screen's DELETE and /api/rec/delete: the same path, answered in the recorder's old words
        public static string TrashOne(string id)
        {
            TrashResult r = Trash(new string[] { id });
            return r.Count > 0 ? "DELETED" : r.Why.Length > 0 ? r.Why : "NOTHING";
        }

        static void Purge()
        {
            List<string> old = new List<string>();
            foreach (KeyValuePair<string, Batch> kv in batches) if (Now - kv.Value.Ms > 10 * UndoMs) old.Add(kv.Key);
            foreach (string k in old) batches.Remove(k);
        }

        // UNDO: the files back where they were, the Videos\Paddock link back. "" = done; else the plain words for the page.
        public static string Undo(string batch, out int count)
        {
            count = 0; Batch b;
            lock (gate)
            {
                if (batch == null || !batches.TryGetValue(batch, out b)) return "Nothing to undo";
                batches.Remove(batch);
                if (Now - b.Ms > UndoMs) { Log.W("library: undo of " + batch + " refused - more than 60 s later"); return "Too late to undo: they stay in the trash for " + TrashDays + " days"; }
                foreach (RaceInfo r in b.Items)
                {
                    // the trash it went to must be the active vault's (the vault switched to the test copy, or back, in between: leave it)
                    if (!Recorder.LibInVault(r.File)) { Log.W("library: undo of " + r.Id + " refused - its trash is not in the active vault"); continue; }
                    string dir = r.From == "saved" ? Recorder.LibSavedDir : Recorder.LibSessDir;
                    string mp4 = Path.Combine(dir, r.Id + ".mp4"), json = Path.ChangeExtension(mp4, ".json");
                    string tMp4 = r.File, tJson = Path.ChangeExtension(tMp4, ".json"), tMark = Path.ChangeExtension(tMp4, ".trash");
                    try
                    {
                        if (!File.Exists(tMp4)) continue;
                        Directory.CreateDirectory(dir);
                        File.Move(tMp4, mp4);
                    }
                    catch (Exception ex) { Log.W("library: could not put " + r.Id + " back (" + ex.Message + ")"); continue; }
                    try { if (TestUndoJsonFails) throw new IOException("test"); if (File.Exists(tJson)) File.Move(tJson, json); }
                    catch (Exception ex)
                    {
                        // a video without its sidecar is listed nowhere: it goes back into the trash with its sidecar and note
                        try { File.Move(mp4, tMp4); } catch { }
                        Log.W("library: could not put the sidecar of " + r.Id + " back (" + ex.Message + ") - it stays in the trash"); continue;
                    }
                    try { File.Delete(tMark); } catch { }
                    RecSess s = Recorder.LibRead(json);
                    if (s == null) continue;
                    Recorder.LibPut(s);
                    if (r.WasExported) { string p; Recorder.Export(r.Id, out p); }
                    count++;
                }
            }
            if (count == 0) return "Nothing to undo";
            Log.W("library: undo " + batch + " - " + count + " race" + (count == 1 ? "" : "s") + " back");
            Changed();
            return "";
        }
        internal static bool TestUndoJsonFails;    // test: the sidecar cannot be moved back

        // for good: the video, its sidecar, the trash note and the Videos\Paddock link. true when the video is gone.
        static bool Erase(RaceInfo r)
        {
            try { if (r.ExportPath.Length > 0 && File.Exists(r.ExportPath)) File.Delete(r.ExportPath); } catch { }
            try { if (File.Exists(r.File)) File.Delete(r.File); } catch (Exception ex) { Log.W("library: could not delete " + r.Id + " (" + ex.Message + ")"); return false; }
            if (File.Exists(r.File)) return false;
            try { if (File.Exists(r.Sidecar)) File.Delete(r.Sidecar); } catch { }
            try { string mk = Path.ChangeExtension(r.File, ".trash"); if (File.Exists(mk)) File.Delete(mk); } catch { }
            try { File.Delete(ThumbPath(r.Id, false)); File.Delete(ThumbPath(r.Id, true)); } catch { }
            return true;
        }

        // the trash: items older than 14 days (all = EMPTY NOW). Runs on the Jobs worker; stops when a session starts.
        // An item without its note is emptied only by EMPTY NOW.
        internal static int Empty(bool all, out long bytes)
        {
            int n = 0; bytes = 0;
            lock (gate)
            {
                List<RaceInfo> list = TrashList();
                list.Sort(delegate (RaceInfo a, RaceInfo b) { return a.DeletedMs.CompareTo(b.DeletedMs); });
                foreach (RaceInfo r in list)
                {
                    if (!all && (r.NoNote || Now - r.DeletedMs < TrashDays * 86400000.0)) continue;
                    if (!Recorder.LibInVault(r.File)) continue;
                    if (Jobs.ShouldYield) { Jobs.Again(all ? "empty the trash" : "library empty old trash", delegate { long b2; Empty(all, out b2); }); break; }
                    if (Erase(r)) { n++; bytes += r.Bytes; }
                }
            }
            if (n > 0) { Log.W("library: trash emptied - " + n + " race" + (n == 1 ? "" : "s") + " deleted for good (" + (bytes / 1048576) + " MB freed)"); Changed(); }
            return n;
        }
        public static bool EmptyTrash() { return Jobs.Run("library empty old trash", delegate { long b; Empty(false, out b); }, true); }
        public static bool EmptyTrashNow() { return Jobs.Run("empty the trash", delegate { long b; Empty(true, out b); }, true); }

        static string StateJson(string id)
        {
            Func<string, string> h = ShareState;
            if (h != null) { try { string j = (h(id) ?? "").Trim(); if (j.StartsWith("{") && j.EndsWith("}")) return j; } catch { } }
            return "{\"kind\":\"none\"}";
        }

        public sealed class FreeResult { public int Count; public long Bytes; public string Say = ""; }

        // FREE UP SPACE: delete for good the oldest races already on YouTube ("shared"), oldest first, until 15 % of the volume is free.
        // Never a race that is not shared (or still sharing, or failed), never one Peter kept by a press. A race kept by AutoKeep may go
        // once it is on YouTube. Measured again after every file.
        public static FreeResult FreeUpSpace()
        {
            FreeResult res = new FreeResult();
            if (ShareState == null) { res.Say = "Nothing freed: Paddock cannot tell yet which races are on YouTube"; return res; }
            lock (gate)
            {
                long[] d = Measure(); long target = (long)(d[1] * FreeShare);
                if (d[0] >= target) { res.Say = "Nothing to free: " + (d[0] / Gb).ToString("0", Inv) + " GB is free"; return res; }
                List<RaceInfo> all = SessionIndex.All(true);
                all.Sort(delegate (RaceInfo a, RaceInfo b) { return a.StartMs.CompareTo(b.StartMs); });
                foreach (RaceInfo r in all)
                {
                    if (FreeNow() >= target) break;
                    if (r.Kept || r.Busy || Kind(r.Id) != "shared" || Recorder.LibBusy(r.Id).Length > 0) continue;
                    if (!Recorder.LibInVault(r.File)) { Log.W("library: free up space - " + r.Id + " is not in the active vault, left alone"); continue; }
                    RecSess s = Recorder.LibFind(r.Id); if (s == null) continue;
                    long before = FreeNow();
                    if (!Erase(r)) break;          // a locked file: stop rather than spin
                    Recorder.LibForget(s);
                    res.Count++; res.Bytes += r.Bytes;
                    Log.W("library: free up space - deleted the shared race " + r.Id + " (" + (r.Bytes / 1048576) + " MB)");
                    if (FreeNow() - before < r.Bytes / 2) { Log.W("library: free space did not come back after deleting " + r.Id + " - stopping"); break; }
                }
            }
            if (res.Count > 0) Changed();
            res.Say = res.Count == 0 ? "Nothing to free: no race on YouTube can go"
                : "Freed " + Size(res.Bytes) + ": " + res.Count + " shared race" + (res.Count == 1 ? "" : "s");
            return res;
        }

        // ---------------- retention (replaces the recorder's last-8 / 60 GB rule for finished sessions) ----------------
        // practice and qualifying (by their type; not Kept or kept by AutoKeep) -> the trash after 14 days; races, and sessions of unknown
        // type, never go by themselves; the trash empties after 14 days. A blip (under 90 s, no lap, not a recovered session) is deleted
        // after 10 minutes, as before. Below the recorder's hard floor (50 GB) the trash empties early, then the oldest unkept
        // practice/qualifying are deleted, one at a time with a re-measure (2026-10-17: measuring once before deleting picked EVERY
        // session because the free space had not changed yet). Nothing being uploaded is touched. Runs as Jobs.Routine, never in a session.
        internal static void Tidy()
        {
            try
            {
                double now = Now; bool changed = false;
                lock (gate)
                {
                    foreach (RecSess s in Recorder.LibFinished())
                    {
                        if (Jobs.ShouldYield) return;
                        if (s.Saved || s.Saving || s.SaveWhenDone || !Recorder.LibInVault(s.File) || Recorder.LibBusy(s.Id).Length > 0 || Uploading(s.Id)) continue;
                        bool blip = !s.Recovered && s.Duration > 0 && s.Duration < 90 && s.LapRows.Count == 0 && now - s.Created > 600000;
                        if (blip)
                        {
                            RaceInfo r = SessionIndex.From(s, true);
                            if (Erase(r)) { Recorder.LibForget(s); changed = true; Log.W("library: removed the blip " + s.Id + " (" + s.Duration.ToString("0", Inv) + " s, no lap)"); }
                            continue;
                        }
                        if (!SessionIndex.PracticeOrQualify(s.Type, s.Recovered) || now - s.StartMs < PracticeDays * 86400000.0) continue;
                        RaceInfo moved; if (MoveToTrash(s.Id, out moved) == "") { changed = true; Log.W("library: " + s.Type + " " + s.Id + " is " + PracticeDays + " days old - moved to the trash (" + TrashDays + " more days to bring it back)"); }
                    }
                }
                if (Jobs.ShouldYield) return;
                long freed; if (Empty(false, out freed) > 0) changed = true;
                if (Floor()) changed = true;
                if (changed) Changed();
            }
            catch (Exception ex) { Log.W("library: tidy: " + ex.Message); }
        }

        static bool Floor()
        {
            long min = (long)(Recorder.LibMinFreeGb * Gb);
            if (FreeNow() >= min) return false;
            bool any = false;
            lock (gate)
            {
                // 1. the trash, oldest first (an item without its note too: the disk is full, and it was deleted on purpose)
                List<RaceInfo> trash = TrashList();
                trash.Sort(delegate (RaceInfo a, RaceInfo b) { return a.DeletedMs.CompareTo(b.DeletedMs); });
                foreach (RaceInfo r in trash)
                {
                    if (FreeNow() >= min || Jobs.ShouldYield) return any;
                    if (!Recorder.LibInVault(r.File)) continue;
                    long before = FreeNow();
                    if (!Erase(r)) break;
                    any = true; Log.W("library: the disk is nearly full - emptied " + r.Id + " from the trash early");
                    if (FreeNow() - before < r.Bytes / 2) { Log.W("library: free space did not come back - stopping the clean-up"); return any; }
                }
                // 2. the oldest unkept practice / qualifying, one at a time (never a race or an unknown type, never kept, never one written in
                // the last 10 minutes, never one being uploaded)
                for (int guard = 0; guard < 1000 && FreeNow() < min && !Jobs.ShouldYield; guard++)
                {
                    RecSess victim = null; double now = Now;
                    foreach (RecSess s in Recorder.LibFinished())
                        if (!s.Saved && !s.Saving && !s.SaveWhenDone && SessionIndex.PracticeOrQualify(s.Type, s.Recovered) && Recorder.LibInVault(s.File) && now - s.Created > 600000 && Recorder.LibBusy(s.Id).Length == 0 && !Uploading(s.Id) && (victim == null || s.StartMs < victim.StartMs)) victim = s;
                    if (victim == null) break;
                    RaceInfo r = SessionIndex.From(victim, true);
                    long before = FreeNow();
                    if (!Erase(r)) break;
                    Recorder.LibForget(victim); any = true;
                    Log.W("library: the disk is nearly full - deleted the practice/qualifying " + victim.Id + " (" + (r.Bytes / 1048576) + " MB)");
                    if (FreeNow() - before < r.Bytes / 2) { Log.W("library: free space did not come back after " + victim.Id + " - stopping the clean-up"); break; }
                }
            }
            return any;
        }

        // ---------------- thumbnails: one ffmpeg run per race, between sessions, newest first ----------------
        static readonly HashSet<string> thumbFailed = new HashSet<string>();
        public static bool HasThumb(string id) { return File.Exists(ThumbPath(id, false)) && File.Exists(ThumbPath(id, true)); }
        static bool ThumbsMissing()
        {
            foreach (RecSess s in Recorder.LibFinished())
                if (s.File.Length > 0 && !HasThumb(s.Id)) { lock (thumbFailed) if (!thumbFailed.Contains(s.Id)) return true; }
            return false;
        }
        public static bool QueueThumbs() { return Jobs.Run("race thumbnails", delegate { Thumbs(); }, true); }

        internal static int Thumbs()
        {
            int made = 0;
            if (!Recorder.Mock && !File.Exists(Recorder.LibFfmpegPath)) { RigState.LogOnce("library thumbs ffmpeg", "library: no ffmpeg (vault\\bin) - race thumbnails wait"); return 0; }
            List<RaceInfo> all = SessionIndex.All();
            for (int i = 0; i < all.Count; i++)
            {
                RaceInfo r = all[i];
                if (HasThumb(r.Id)) continue;
                lock (thumbFailed) if (thumbFailed.Contains(r.Id)) continue;
                if (Jobs.ShouldYield) { Jobs.Again("race thumbnails", delegate { Thumbs(); }); break; }
                if (MakeThumb(r)) made++;
                else if (Jobs.ShouldYield) { Jobs.Again("race thumbnails", delegate { Thumbs(); }); break; }     // ffmpeg was stopped for a session: not a failure
                else lock (thumbFailed) thumbFailed.Add(r.Id);
                Action<string> after = AfterThumb; if (after != null) after(r.Id);
            }
            if (made > 0) { Log.W("library: " + made + " race thumbnail" + (made == 1 ? "" : "s") + " made"); Changed(); }
            return made;
        }

        static bool MakeThumb(RaceInfo r)
        {
            try
            {
                Directory.CreateDirectory(ThumbDir);
                double at = 60;
                foreach (RaceMarker m in r.Markers) if (m.Kind == "start") { at = m.Sec + 60; break; }
                if (r.Sec > 0 && at > r.Sec - 2) at = Math.Max(0, r.Sec / 2);      // a short session: the middle of it
                string big = ThumbPath(r.Id, false), small = ThumbPath(r.Id, true);
                string tb = Path.Combine(ThumbDir, "race-" + r.Id + ".part.jpg"), ts = Path.Combine(ThumbDir, "race-" + r.Id + "-144.part.jpg");
                string args = "-v error -y -ss " + at.ToString("0.000", Inv) + " -i \"" + r.File + "\" -filter_complex \"[0:v]split=2[a][b];[a]scale=600:-1[o1];[b]scale=144:144:force_original_aspect_ratio=increase,crop=144:144[o2]\"" +
                              " -map \"[o1]\" -frames:v 1 -q:v 3 \"" + tb + "\" -map \"[o2]\" -frames:v 1 -q:v 3 \"" + ts + "\"";
                LastThumbArgs = args;
                string err; int rc = Recorder.LibFfmpeg(args, 60000, out err);
                if (rc != 0 || !File.Exists(tb) || !File.Exists(ts))
                {
                    try { File.Delete(tb); File.Delete(ts); } catch { }
                    if (rc != -1) Log.W("library: no thumbnail for " + r.Id + " (ffmpeg " + rc + ": " + (err ?? "").Trim() + ")");
                    return false;
                }
                if (File.Exists(big)) File.Delete(big); File.Move(tb, big);
                if (File.Exists(small)) File.Delete(small); File.Move(ts, small);
                return true;
            }
            catch (Exception ex) { Log.W("library: thumbnail of " + r.Id + ": " + ex.Message); return false; }
        }
        internal static string LastThumbArgs = "";

        // GET /api/library/thumb?id=&w=600|144: the JPEG, null = not made yet (404)
        public static byte[] Thumb(string id, string w)
        {
            if (!IdOk(id)) return null;
            string f = ThumbPath(id, w == "144");
            try { return File.Exists(f) ? File.ReadAllBytes(f) : null; } catch { return null; }
        }

        // ---------------- storage ----------------
        public sealed class Store { public long Used, Free, Total, Trash; public int MoreRaces; public bool LowSpace; }
        public static Store Storage() { List<RaceInfo> t = TrashList(); long b = 0; foreach (RaceInfo r in t) b += r.Bytes; return Storage(SessionIndex.All(), b); }
        static Store Storage(List<RaceInfo> races, long trashBytes)
        {
            Store st = new Store();
            long[] d = Measure(); st.Free = d[0]; st.Total = d[1];
            long raceBytes = 0; int raceCount = 0;
            foreach (RaceInfo r in races) { st.Used += r.Bytes; if (r.IsRace && r.Bytes > 0) { raceBytes += r.Bytes; raceCount++; } }
            st.Trash = trashBytes;
            double avg = raceCount > 0 ? (double)raceBytes / raceCount : DefaultRaceBytes;
            st.MoreRaces = (int)Math.Max(0, Math.Floor(st.Free / avg));
            st.LowSpace = st.Total > 0 && st.Free < st.Total * FreeShare;
            return st;
        }
        static string GbOf(long b) { return Math.Round(b / Gb, MidpointRounding.AwayFromZero).ToString("0", Inv); }   // half a GB in the trash shows as 1, not 0
        static string Size(long b) { return b < Gb ? Math.Max(1, Math.Round(b / 1048576.0)).ToString("0", Inv) + " MB" : (b / Gb).ToString("0", Inv) + " GB"; }
        static string StoreJson(Store st)
        {
            return "{\"usedGb\":" + GbOf(st.Used) + ",\"freeGb\":" + GbOf(st.Free) + ",\"trashGb\":" + GbOf(st.Trash) +
                   ",\"moreRaces\":" + st.MoreRaces.ToString(Inv) + ",\"lowSpace\":" + (st.LowSpace ? "true" : "false") + "}";
        }

        // ---------------- JSON ----------------
        static string N(double v, string f) { return double.IsNaN(v) || double.IsInfinity(v) ? "0" : v.ToString(f, Inv); }
        static string B(bool b) { return b ? "true" : "false"; }

        // the facts of one race both lists share
        static string RaceFacts(RaceInfo r)
        {
            return "\"id\":" + Json_.S(r.Id) + ",\"track\":" + Json_.S(r.Track) + ",\"config\":" + Json_.S(r.Config) + ",\"car\":" + Json_.S(r.Car) + ",\"type\":" + Json_.S(r.Type) +
                   ",\"isRace\":" + B(r.IsRace) + ",\"startMs\":" + N(r.StartMs, "0") + ",\"sec\":" + N(Math.Round(r.Sec), "0") + ",\"laps\":" + r.Laps + ",\"counted\":" + r.Counted +
                   ",\"best\":" + (r.Best > 0 ? N(r.Best, "0.000") : "0") + ",\"bestLap\":" + r.BestLap + ",\"mb\":" + N(Math.Round(r.MB), "0") + ",\"kept\":" + B(r.Kept) +
                   ",\"thumb\":" + B(HasThumb(r.Id)) + ",\"state\":" + StateJson(r.Id);
        }

        static string YouTube()
        {
            Func<string> h = YouTubeJson;
            if (h != null) { try { string j = (h() ?? "").Trim(); if (j.StartsWith("{") && j.EndsWith("}")) return j; } catch { } }
            return "{\"signedIn\":false,\"privacy\":\"private\",\"template\":1}";
        }

        // a session under 30 s is not shown (the blips the old list hid too)
        static List<RaceInfo> Shown(List<RaceInfo> all) { List<RaceInfo> r = new List<RaceInfo>(); foreach (RaceInfo x in all) if (x.Sec >= 30) r.Add(x); return r; }

        // GET /api/library: the RACES page (W1-4)
        public static string Json()
        {
            List<RaceInfo> all = SessionIndex.All(), trash = TrashList();
            long tb = 0; foreach (RaceInfo r in trash) tb += r.Bytes;
            StringBuilder sb = new StringBuilder("{\"storage\":" + StoreJson(Storage(all, tb)) + ",\"youtube\":" + YouTube() + ",\"races\":[");
            bool first = true;
            foreach (RaceInfo r in Shown(all))
            {
                if (!first) sb.Append(','); first = false;
                sb.Append('{').Append(RaceFacts(r)).Append(",\"markers\":[");
                for (int i = 0; i < r.Markers.Count; i++)
                {
                    RaceMarker m = r.Markers[i]; if (i > 0) sb.Append(',');
                    sb.Append("{\"sec\":" + N(m.Sec, "0.0") + ",\"kind\":" + Json_.S(m.Kind) + ",\"label\":" + Json_.S(m.Label) + "}");
                }
                sb.Append("]}");
            }
            sb.Append("],\"trash\":[");
            for (int i = 0; i < trash.Count; i++)
            {
                RaceInfo r = trash[i]; if (i > 0) sb.Append(',');
                sb.Append("{\"id\":" + Json_.S(r.Id) + ",\"track\":" + Json_.S(r.Track) + ",\"car\":" + Json_.S(r.Car) + ",\"type\":" + Json_.S(r.Type) + ",\"startMs\":" + N(r.StartMs, "0") +
                          ",\"mb\":" + N(Math.Round(r.MB), "0") + ",\"deletedMs\":" + N(r.DeletedMs, "0") + ",\"daysLeft\":" + DaysLeft(r) + "}");
            }
            return sb.Append("]}").ToString();
        }

        // /deck/summary's "races" (asked every 10 s, in a session too): the 40 newest, no markers, no trash list. During a session the list is
        // the cached one, or a light one from the sidecars (never the telemetry folder); the trash is summed from file sizes.
        // min, saved and freeGb stay for the old deck screen until W1-5.
        public static string DeckJson()
        {
            List<RaceInfo> all = SessionIndex.All(RigState.SessionOn);
            Store st = Storage(all, TrashBytesQuick());
            StringBuilder sb = new StringBuilder("{\"freeGb\":" + GbOf(st.Free) + ",\"storage\":" + StoreJson(st) + ",\"races\":[");
            int n = 0;
            foreach (RaceInfo r in Shown(all))
            {
                if (n == 40) break;
                if (n++ > 0) sb.Append(',');
                sb.Append('{').Append(RaceFacts(r)).Append(",\"min\":" + N(Math.Round(r.Sec / 60.0), "0") + ",\"saved\":" + B(r.Saved) + "}");
            }
            return sb.Append("]}").ToString();
        }

        // ---------------- commands (/api/do?c=...; all in Gate.GuardedDo: never while a session is on) ----------------
        public static bool Handles(string c) { return c == "racetrash" || c == "raceundo" || c == "raceempty" || c == "racefree"; }

        static string Say(string json, string say) { return json.Substring(0, json.Length - 1) + (json.Length > 2 ? "," : "") + "\"say\":" + Json_.S(say) + "}"; }
        static string Plural(int n) { return n + " race" + (n == 1 ? "" : "s"); }
        static string WhyWords(string why)
        {
            switch (why)
            {
                case "RECORDING": return "it is still being recorded";
                case "BUSY": return "it is still being saved, try again in a minute";
                case "IN USE": return "it is in use. Try again in a minute";
                case "NOT HERE": return "it is not in this Paddock's video folder";
                case "NO NOTE": return "the trash could not be written. Try again in a minute";
            }
            return "it was not found";
        }

        // the last answer per command + argument: a press the deck or the page sends twice gets the same answer (not "Nothing to delete")
        sealed class Answer { public string Json; public int Code; public double At; public bool Pending; }
        static readonly Dictionary<string, Answer> answers = new Dictionary<string, Answer>();
        // the answer to a repeat of this press; waits up to 3 s for a first press still running; null = none
        public static string Recent(string c, string a, out int code)
        {
            code = 200; string k = c + "\n" + (a ?? "");
            for (int i = 0; i < 60; i++)
            {
                lock (answers)
                {
                    Answer x; if (!answers.TryGetValue(k, out x) || Now - x.At > AnswerMs + 3000) return null;
                    if (!x.Pending) { code = x.Code; return x.Json; }
                }
                Thread.Sleep(50);
            }
            return null;
        }

        public static string Do(string c, string a, out int code)
        {
            string k = c + "\n" + (a ?? "");
            lock (answers)
            {
                Answer x;
                if (answers.TryGetValue(k, out x) && !x.Pending && Now - x.At < AnswerMs) { code = x.Code; return x.Json; }
                Answer p = new Answer(); p.Pending = true; p.At = Now; answers[k] = p;
                List<string> old = new List<string>(); foreach (KeyValuePair<string, Answer> kv in answers) if (Now - kv.Value.At > 60000) old.Add(kv.Key);
                foreach (string o in old) answers.Remove(o);
            }
            string j = "{}"; code = 500;
            try { j = Run(c, a, out code); }
            finally { lock (answers) { Answer done = new Answer(); done.Json = j; done.Code = code; done.At = Now; answers[k] = done; } }
            return j;
        }

        static string Run(string c, string a, out int code)
        {
            code = 200;
            switch (c)
            {
                case "racetrash":
                    {
                        List<string> ids = new List<string>();
                        foreach (string id in (a ?? "").Split('|')) if (IdOk(id.Trim())) ids.Add(id.Trim());
                        TrashResult r = Trash(ids);
                        string j = "{\"batch\":" + Json_.S(r.Batch) + ",\"count\":" + r.Count + ",\"mb\":" + (r.Bytes / 1048576) + "}";
                        if (r.Count == 0) { code = 409; return Say(j, r.Why.Length == 0 || r.Why == "NOTHING" ? "Nothing to delete" : "Not deleted: " + WhyWords(r.Why)); }
                        return Say(j, "Deleted " + Plural(r.Count) + (r.Refused > 0 ? ". " + r.Refused + " not deleted: " + WhyWords(r.Why) : ""));
                    }
                case "raceundo":
                    {
                        int n; string why = Undo(a, out n);
                        if (why.Length > 0) { code = 409; return Say("{\"ok\":false,\"count\":0}", why); }
                        return Say("{\"ok\":true,\"count\":" + n + "}", (n == 1 ? "1 race is" : n + " races are") + " back");
                    }
                case "raceempty":
                    {
                        List<RaceInfo> t = TrashList(); long b = 0; foreach (RaceInfo r in t) b += r.Bytes;
                        if (t.Count == 0) { code = 409; return Say("{\"ok\":false}", "The trash is already empty"); }
                        EmptyTrashNow();
                        return Say("{\"ok\":true,\"count\":" + t.Count + "}", "Emptying the trash: " + Size(b));
                    }
                case "racefree":
                    {
                        FreeResult r = FreeUpSpace();
                        if (r.Count == 0) code = 409;
                        return Say("{\"ok\":" + B(r.Count > 0) + ",\"count\":" + r.Count + ",\"gb\":" + (r.Bytes / Gb).ToString("0.0", Inv) + "}", r.Say);
                    }
            }
            code = 404; return "{\"say\":\"Unknown command\"}";
        }

        // ---------------- start: once a minute the tidy and the missing thumbnails go on the Jobs queue (both wait for the session to end) ----------------
        static Timer tick;
        public static void Start()
        {
            if (tick != null) return;
            tick = new Timer(delegate
            {
                try
                {
                    Jobs.Routine("library tidy", Tidy);
                    if (Jobs.Free && ThumbsMissing()) QueueThumbs();
                }
                catch (Exception ex) { Log.W("library: " + ex.Message); }
            }, null, 15000, 60000);
        }
    }
}
