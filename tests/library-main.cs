// Entry point for tests\library-test.ps1 only: compiled together with dash\src\*.cs (csc /main:IRDash.LibraryMain) into a throw-away
// exe in tests\library-scratch\bin, so Program.RootDir is tests\library-scratch: the vault (sessions, saved, trash, thumbs) and the
// Videos\Paddock stand-in (videos\, test mode) are scratch folders with 1-KB pretend videos and real schema-2 sidecars.
// The same exe stands in for ffmpeg (--mock, Recorder.Mock), as irdash --test does. Prints "ok ..." / "FAIL ..." lines and DONE.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class LibraryMain
    {
        const BindingFlags Any = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        const double Gb = 1073741824.0, Day = 86400000.0;
        static int fails;
        static void Ok(string what, bool cond, string why)
        {
            if (cond) Console.WriteLine("ok " + what);
            else { fails++; Console.WriteLine("FAIL " + what + (why != null && why.Length > 0 ? " (" + why + ")" : "")); }
        }
        static void Ok(string what, bool cond) { Ok(what, cond, ""); }

        static string Root, Vlt, Sess, Saved, Trash, Thumbs, Videos;
        static double now;
        static volatile bool sessionOn;
        // the pretend disk: free = baseFree + the claimed bytes of fixtures deleted since; or a fixed number
        static long total = (long)(1000 * Gb), baseFree = (long)(500 * Gb), claimedAtStart; static bool fixedDisk;

        static long Claimed()
        {
            long b = 0;
            foreach (string dir in new string[] { Sess, Saved, Trash })
            {
                if (!Directory.Exists(dir)) continue;
                foreach (string j in Directory.GetFiles(dir, "*.json"))
                {
                    if (!File.Exists(Path.ChangeExtension(j, ".mp4"))) continue;
                    Match m = Regex.Match(File.ReadAllText(j), "\"bytes\":([0-9]+)"); if (m.Success) b += long.Parse(m.Groups[1].Value, Inv);
                }
            }
            return b;
        }
        static void DiskFrom(double freeGb, double totalGb, bool fix)
        {
            total = (long)(totalGb * Gb); baseFree = (long)(freeGb * Gb); fixedDisk = fix; claimedAtStart = Claimed();
        }

        static void Clean()
        {
            foreach (string d in new string[] { Sess, Saved, Trash, Thumbs, Videos }) { try { if (Directory.Exists(d)) Directory.Delete(d, true); } catch { } Directory.CreateDirectory(d); }
            Reload();
        }
        static void Reload() { typeof(Recorder).GetMethod("LoadSessions", Any).Invoke(null, null); SessionIndex.Forget(); }
        // a new press of the same command: past the library's 2-s repeat memory
        static string D(string c, string a, out int code) { now += 2500; return Library.Do(c, a, out code); }
        static void Patch(string dir, string id, string from, string to) { string f = Path.Combine(dir, id + ".json"); File.WriteAllText(f, File.ReadAllText(f).Replace(from, to), new UTF8Encoding(false)); }
        static void PeterKeeps(string dir, string id) { Patch(dir, id, "\"recovered\":", "\"keptBy\":\"peter\",\"recovered\":"); }
        static void SetOpen(RecSess s) { typeof(Recorder).GetField("openSess", Any).SetValue(null, s); }

        static string Lap(int n, double offset, double time, bool counted, bool pit)
        {
            return "{\"n\":" + n + ",\"offset\":" + offset.ToString("0.000", Inv) + ",\"time\":" + time.ToString("0.000", Inv) + ",\"clean\":" + (counted ? "true" : "false") +
                   ",\"counted\":" + (counted ? "true" : "false") + ",\"pb\":false,\"startMs\":null,\"pit\":" + (pit ? "true" : "false") + "}";
        }
        // one finished session: <dir>\<id>.mp4 (1 KB) + a schema-2 sidecar
        static void Fix(string dir, string id, string type, double startMs, double dur, long bytes, bool saved, string laps, string incs, double created)
        {
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, id + ".mp4"), new byte[1024]);
            string j = "{\"schema\":2,\"id\":\"" + id + "\",\"uniqueId\":null,\"sessionNum\":0,\"track\":\"Road Atlanta\",\"config\":\"Full Course\",\"car\":\"Toyota GR86\",\"sessionType\":\"" + type + "\"," +
                       "\"startMs\":" + startMs.ToString("0", Inv) + ",\"endMs\":null,\"durationSec\":" + dur.ToString("0.000", Inv) + ",\"durationSource\":\"ffprobe\",\"bytes\":" + bytes + ",\"encoder\":\"hevc_nvenc\"," +
                       "\"state\":\"ready\",\"gaps\":[],\"audio\":\"ok\",\"audioSource\":\"\",\"saved\":" + (saved ? "true" : "false") + ",\"saveWhenDone\":false,\"saveBlocked\":\"\",\"recovered\":false,\"created\":" + created.ToString("0", Inv) +
                       ",\"laps\":[" + (laps ?? "") + "],\"incidents\":[" + (incs ?? "") + "]}";
            File.WriteAllText(Path.Combine(dir, id + ".json"), j, new UTF8Encoding(false));
        }
        static void Fix(string dir, string id, string type, double startMs, double dur, long bytes, bool saved) { Fix(dir, id, type, startMs, dur, bytes, saved, Lap(1, 5, 100, false, false), "", startMs); }
        static void TrashFix(string id, string type, double deletedMs, long bytes)
        {
            Fix(Trash, id, type, deletedMs - Day, 600, bytes, false);
            File.WriteAllText(Path.Combine(Trash, id + ".trash"), deletedMs.ToString("0", Inv) + "\tsessions\t0");
        }

        static bool In(string dir, string id) { return File.Exists(Path.Combine(dir, id + ".mp4")) && File.Exists(Path.Combine(dir, id + ".json")); }
        static bool Gone(string id) { foreach (string d in new string[] { Sess, Saved, Trash }) if (File.Exists(Path.Combine(d, id + ".mp4"))) return false; return true; }
        static string Export(string id) { string p; Recorder.Export(id, out p); return p; }
        static bool Wait(Func<bool> cond, int ms) { for (int i = 0; i < ms / 50; i++) { if (cond()) return true; Thread.Sleep(50); } return cond(); }
        static List<string> Ids(List<RaceInfo> l) { List<string> r = new List<string>(); foreach (RaceInfo x in l) r.Add(x.Id); return r; }
        static Dictionary<string, object> Parse(string j) { return new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(j) as Dictionary<string, object>; }
        static string Missing(Dictionary<string, object> d, string names) { List<string> m = new List<string>(); foreach (string n in names.Split(',')) if (d == null || !d.ContainsKey(n)) m.Add(n); return string.Join(",", m.ToArray()); }

        static int Main(string[] a)
        {
            if (Environment.CommandLine.Contains("--mock ")) return RecMock.Run();
            Program.TestMode = true; Recorder.Mock = true;
            Root = Program.RootDir; Vlt = Path.Combine(Root, "vault");
            Sess = Path.Combine(Vlt, "sessions"); Saved = Path.Combine(Vlt, "saved"); Trash = Path.Combine(Vlt, "trash"); Thumbs = Path.Combine(Vlt, "thumbs"); Videos = Path.Combine(Root, "videos");
            if (!Root.Replace('/', '\\').TrimEnd('\\').EndsWith("library-scratch", StringComparison.OrdinalIgnoreCase)) { Console.WriteLine("FAIL the harness must run from tests\\library-scratch\\bin (root is " + Root + ")"); return 1; }
            now = Recorder.WallMs();
            Library.Clock = delegate { return now; };
            Library.Disk = delegate (string p) { return new long[] { fixedDisk ? baseFree : baseFree + (claimedAtStart - Claimed()), total }; };
            Jobs.SessionOn = delegate { return sessionOn; }; Jobs.GraceMs = 0;
            string only = a.Length > 0 ? a[0] : "";
            Func<int, bool> want = delegate (int n) { return only.Length == 0 || Array.IndexOf(only.Split(','), n.ToString(Inv)) >= 0; };

            try
            {
                if (want(1)) Index();
                if (want(2)) TrashUndo();
                if (want(3)) Retention();
                if (want(4)) FreeUp();
                if (want(5)) StorageMaths();
                if (want(6)) Contract();
                if (want(7)) Thumbnails();
                if (want(8)) Review();
                if (want(9)) ShareChain();
            }
            catch (Exception ex) { Ok("the harness ran without an exception", false, ex.ToString()); }
            Console.WriteLine("DONE");
            return fails > 0 ? 1 : 0;
        }

        // the race of test 1: lap 1 (the start, not counted), lap 2 counted, lap 3 a pit lap, lap 4 the best counted lap; one incident
        static string RaceLaps() { return Lap(1, 10, 100, false, false) + "," + Lap(2, 110, 95.5, true, false) + "," + Lap(3, 205.5, 99, false, true) + "," + Lap(4, 304.5, 93.832, true, false); }

        static void Three()
        {
            Clean();
            Fix(Saved, "r-race", "Race", now - 3 * 3600000, 600, (long)(1.1 * Gb), true, RaceLaps(), "{\"offset\":150.000,\"count\":2}", now - 3 * 3600000);
            Fix(Sess, "q-lone", "Lone Qualify", now - 2 * 3600000, 600, (long)(0.5 * Gb), false);
            Fix(Sess, "p-prac", "Practice", now - 1 * 3600000, 600, (long)(0.6 * Gb), false);
            PeterKeeps(Saved, "r-race");
            Reload();
        }

        static void Index()
        {
            Console.WriteLine("-- 1. the index");
            Three();
            List<RaceInfo> all = SessionIndex.All();
            Ok("1. 3 sessions -> 3 RaceInfo", all.Count == 3, all.Count + "");
            Ok("1. newest first (practice, qualify, race)", string.Join(",", Ids(all).ToArray()) == "p-prac,q-lone,r-race", string.Join(",", Ids(all).ToArray()));
            RaceInfo r = SessionIndex.Get("r-race"), q = SessionIndex.Get("q-lone"), p = SessionIndex.Get("p-prac");
            Ok("1. IsRace: Race yes, Lone Qualify no, Practice no", r != null && q != null && p != null && r.IsRace && !q.IsRace && !p.IsRace);
            Ok("1. Get of an unknown id is null", SessionIndex.Get("nope") == null);
            Ok("1. the race is Kept (it lives in saved)", r.Kept && !p.Kept);
            Ok("1. Best from the sidecar rows: 93.832 on lap 4, 4 laps, 2 counted", Math.Abs(r.Best - 93.832) < 1e-6 && r.BestLap == 4 && r.Laps == 4 && r.Counted == 2, r.Best + " lap " + r.BestLap + ", " + r.Laps + "/" + r.Counted);
            Ok("1. File, Sidecar, Bytes", r.File.EndsWith("r-race.mp4") && r.Sidecar.EndsWith("r-race.json") && r.Bytes == (long)(1.1 * Gb));
            string kinds = "", labels = "", secs = "";
            foreach (RaceMarker m in r.Markers) { kinds += m.Kind + ","; labels += m.Label + "|"; secs += m.Sec.ToString("0.###", Inv) + ","; }
            Ok("1. markers in order: start, incident, pit, best, finish", kinds == "start,incident,pit,best,finish,", kinds);
            Ok("1. marker labels", labels == "Start|Incident +2x|Pit (lap 3)|Best lap 1:33.832 (lap 4)|Finish|", labels);
            Ok("1. marker seconds (lap 1's offset, the incident, lap 3, lap 4, the last lap's end)", secs == "10,150,205.5,304.5,398.332,", secs);
            Ok("1. a session with one uncounted lap has start + finish only", p.Markers.Count == 2 && p.Markers[0].Kind == "start" && p.Markers[1].Kind == "finish", p.Markers.Count + "");
            string rj = Recorder.RacesJson();
            Ok("1. RacesJson (the old deck list) comes from the index: 3 races, min and freeGb", Regex.Matches(rj, "\"id\":").Count == 3 && rj.Contains("\"min\":10") && rj.Contains("\"freeGb\":") && rj.IndexOf("p-prac") < rj.IndexOf("r-race"));
            // the recorder writes the pit flag from now on (SessJson), and reads it back
            RecSess rs = Recorder.LibFind("r-race");
            string sj = (string)typeof(Recorder).GetMethod("SessJson", Any).Invoke(null, new object[] { rs });
            Ok("1. SessJson writes \"pit\" on every lap row (lap 3 true)", Regex.Matches(sj, "\"pit\":").Count == 4 && sj.Contains("\"n\":3,\"offset\":205.500,\"time\":99.000,\"clean\":false,\"counted\":false,\"pb\":false,\"startMs\":null,\"pit\":true"), sj.Length > 300 ? sj.Substring(sj.IndexOf("\"laps\"")) : sj);
            RecSess old = Recorder.LibRead(Path.Combine(Sess, "q-lone.json"));
            File.WriteAllText(Path.Combine(Sess, "q-old.json"), File.ReadAllText(Path.Combine(Sess, "q-lone.json")).Replace(",\"pit\":false", ""));
            RecSess q2 = Recorder.LibRead(Path.Combine(Sess, "q-old.json"));
            string qj = (string)typeof(Recorder).GetMethod("SessJson", Any).Invoke(null, new object[] { q2 });
            Ok("1. an old sidecar without pit stays without it (no made-up pit:false)", old != null && q2 != null && !qj.Contains("\"pit\""));
            File.Delete(Path.Combine(Sess, "q-old.json"));
        }

        static void TrashUndo()
        {
            Console.WriteLine("-- 2. trash and undo");
            Three();
            string lp = Export("p-prac"), lr = Export("r-race");
            Ok("2. setup: both exported to videos\\", File.Exists(lp) && File.Exists(lr));
            int code; string j = D("racetrash", "p-prac", out code);
            Dictionary<string, object> d = Parse(j);
            string batch = d != null && d.ContainsKey("batch") ? (string)d["batch"] : "";
            Ok("2. racetrash answers batch, count 1, mb, \"Deleted 1 race\"", code == 200 && batch.Length > 0 && Convert.ToInt32(d["count"]) == 1 && d.ContainsKey("mb") && (string)d["say"] == "Deleted 1 race", j);
            Ok("2. the files are in vault\\trash, not in sessions\\", In(Trash, "p-prac") && !File.Exists(Path.Combine(Sess, "p-prac.mp4")) && File.Exists(Path.Combine(Trash, "p-prac.trash")));
            Ok("2. the Videos\\Paddock link is gone", !File.Exists(lp));
            Ok("2. the list no longer has it", SessionIndex.Get("p-prac") == null && !Ids(SessionIndex.All()).Contains("p-prac"));
            List<RaceInfo> t = Library.TrashList();
            Ok("2. the trash lists it with daysLeft 14", t.Count == 1 && t[0].Id == "p-prac" && Library.DaysLeft(t[0]) == 14, t.Count > 0 ? Library.DaysLeft(t[0]) + "" : "empty");
            Ok("2. /api/library's trash part has it with \"daysLeft\":14", Library.Json().Contains("\"trash\":[{\"id\":\"p-prac\"") && Library.Json().Contains("\"daysLeft\":14"));
            j = D("raceundo", batch, out code);
            Ok("2. undo: \"1 race is back\"", code == 200 && j.Contains("\"say\":\"1 race is back\""), j);
            Ok("2. undo: the files are back in sessions\\, the trash is empty", In(Sess, "p-prac") && !File.Exists(Path.Combine(Trash, "p-prac.mp4")) && !File.Exists(Path.Combine(Trash, "p-prac.trash")) && Library.TrashList().Count == 0);
            Ok("2. undo: re-exported (the hard link is back)", File.Exists(lp));
            Ok("2. undo: listed again", SessionIndex.Get("p-prac") != null);
            j = D("raceundo", batch, out code);
            Ok("2. undo twice -> \"Nothing to undo\"", code == 409 && j.Contains("Nothing to undo"), j);
            j = D("raceundo", "b-unknown", out code);
            Ok("2. undo of an unknown batch -> \"Nothing to undo\"", code == 409 && j.Contains("Nothing to undo"), j);

            // a Kept race can be trashed by the press; undo puts it back in saved\
            Library.TrashResult k = Library.Trash(new string[] { "r-race" });
            Ok("2. a Kept race is trashed by an explicit press", k.Count == 1 && In(Trash, "r-race") && !File.Exists(Path.Combine(Saved, "r-race.mp4")) && !File.Exists(lr));
            int n; string why = Library.Undo(k.Batch, out n);
            Ok("2. undo puts the Kept race back in saved\\ and re-exports it", why == "" && n == 1 && In(Saved, "r-race") && File.Exists(lr) && SessionIndex.Get("r-race") != null && SessionIndex.Get("r-race").Kept, why);

            // after 60 s the server no longer undoes
            k = Library.Trash(new string[] { "p-prac" });
            now += 61000;
            why = Library.Undo(k.Batch, out n);
            Ok("2. undo after 60 s -> refused, the race stays in the trash", why.StartsWith("Too late") && n == 0 && In(Trash, "p-prac"), why);
            now -= 61000;

            // refused while it is being recorded; through the old command path too
            RecSess open = new RecSess(); open.Id = "q-lone"; SetOpen(open);
            j = D("racetrash", "q-lone", out code);
            Ok("2. refused while that session is being recorded", code == 409 && j.Contains("still being recorded") && In(Sess, "q-lone"), j);
            SetOpen(null);
            Ok("2. the old racedelete (Vault.Do) now trashes too", Vault.Do("racedelete", "q-lone") && In(Trash, "q-lone"));
            Three();
            j = D("racetrash", "q-lone|p-prac|../evil", out code);
            Ok("2. several at once: \"Deleted 2 races\", a bad id is ignored", code == 200 && j.Contains("\"count\":2") && j.Contains("Deleted 2 races") && In(Trash, "q-lone") && In(Trash, "p-prac"), j);
            j = D("racetrash", "nope", out code);
            Ok("2. an unknown id -> \"Nothing to delete\"", code == 409 && j.Contains("Nothing to delete"), j);
        }

        static void Retention()
        {
            Console.WriteLine("-- 3. retention");
            Clean(); DiskFrom(500, 1000, true);
            Fix(Sess, "p15", "Practice", now - 15 * Day, 600, (long)(1 * Gb), false);
            Fix(Sess, "q15", "Qualify", now - 15 * Day, 600, (long)(1 * Gb), false);
            Fix(Sess, "r15", "Race", now - 15 * Day, 240, (long)(1 * Gb), false);         // a short race nobody kept: never removed by itself
            Fix(Saved, "k15", "Practice", now - 15 * Day, 600, (long)(1 * Gb), true);      // a Kept practice
            Fix(Sess, "p13", "Practice", now - 13 * Day, 600, (long)(1 * Gb), false);
            Fix(Sess, "blip", "Practice", now - 20 * 60000, 40, 1000, false, "", "", now - 20 * 60000);
            Fix(Sess, "blipnew", "Practice", now - 2 * 60000, 40, 1000, false, "", "", now - 2 * 60000);
            TrashFix("t15", "Practice", now - 15 * Day, (long)(1 * Gb));
            TrashFix("t3", "Practice", now - 3 * Day, (long)(1 * Gb));
            Reload();
            sessionOn = true;
            Jobs.Routine("library tidy", Library.Tidy);
            Thread.Sleep(1500);
            Ok("3. a session is on: nothing moves", In(Sess, "p15") && In(Sess, "blip") && In(Trash, "t15"));
            sessionOn = false;
            bool ran = Wait(delegate { return In(Trash, "p15") && Gone("t15"); }, 8000);
            Ok("3. the session ends: the tidy runs", ran);
            Ok("3. a 15-day-old practice and qualifying go to the trash", In(Trash, "p15") && In(Trash, "q15") && !File.Exists(Path.Combine(Sess, "p15.mp4")));
            Ok("3. a 15-day-old race does not", In(Sess, "r15"));
            Ok("3. a Kept practice does not", In(Saved, "k15"));
            Ok("3. a 13-day-old practice does not", In(Sess, "p13"));
            Ok("3. a 15-day trash item is deleted for good", Gone("t15") && !File.Exists(Path.Combine(Trash, "t15.json")));
            Ok("3. a 3-day trash item stays", In(Trash, "t3"));
            Ok("3. the blip rule: under 90 s with no lap, 10 minutes old -> deleted (not trashed)", Gone("blip") && !File.Exists(Path.Combine(Trash, "blip.json")));
            Ok("3. a blip written 2 minutes ago stays", In(Sess, "blipnew"));
            // the practice that just went to the trash shows 14 days, not 0 (deleted now, not when it was driven)
            RaceInfo pt = null; foreach (RaceInfo x in Library.TrashList()) if (x.Id == "p15") pt = x;
            Ok("3. it shows 14 days left in the trash", pt != null && Library.DaysLeft(pt) == 14);

            // below the 50 GB floor: the trash first, then the oldest unkept practice, one at a time; never a race
            Clean();
            TrashFix("tOld", "Practice", now - 1 * Day, (long)(5 * Gb));
            Fix(Sess, "pOld", "Practice", now - 5 * Day, 600, (long)(8 * Gb), false);
            Fix(Sess, "pNewer", "Practice", now - 2 * Day, 600, (long)(8 * Gb), false);
            Fix(Sess, "rOld", "Race", now - 9 * Day, 240, (long)(20 * Gb), false);
            Reload(); DiskFrom(40, 1000, false);
            Library.Tidy();
            Ok("3. floor: the trash empties early", Gone("tOld"));
            Ok("3. floor: then the oldest unkept practice goes (pOld), and it stops at 50 GB (pNewer stays)", Gone("pOld") && In(Sess, "pNewer"));
            Ok("3. floor: a race is never removed", In(Sess, "rOld"));
            DiskFrom(500, 1000, true);
        }

        static void FreeUp()
        {
            Console.WriteLine("-- 4. free up space");
            Func<string, string> shared = null;
            Action setup = delegate
            {
                Clean();
                Fix(Saved, "k0", "Race", now - 10 * Day, 1200, (long)(3 * Gb), true); PeterKeeps(Saved, "k0");
                Fix(Saved, "a0", "Race", now - 11 * Day, 1200, (long)(3 * Gb), true);      // kept by AutoKeep (no keptBy): may go once shared
                Fix(Sess, "s1", "Race", now - 9 * Day, 1200, (long)(3 * Gb), false);
                Fix(Sess, "s2", "Race", now - 8 * Day, 1200, (long)(3 * Gb), false);
                Fix(Sess, "s3", "Race", now - 7 * Day, 1200, (long)(3 * Gb), false);
                Fix(Sess, "s4", "Race", now - 6 * Day, 1200, (long)(3 * Gb), false);
                Reload(); DiskFrom(10, 100, false);
            };
            setup();
            Library.ShareState = null;
            int code; string j = D("racefree", "", out code);
            Ok("4. no hook: nothing is deleted, and it says so", code == 409 && j.Contains("cannot tell") && In(Sess, "s1") && In(Sess, "s2") && In(Saved, "k0"), j);

            string lk = Export("s1");
            shared = delegate (string id) { return id == "a0" || id == "s1" || id == "s2" || id == "k0" ? "{\"kind\":\"shared\",\"privacy\":\"private\",\"url\":\"https://youtu.be/x\"}" : id == "s3" ? "{\"kind\":\"sharing\",\"pct\":41}" : "{\"kind\":\"none\"}"; };
            Library.ShareState = shared;
            j = D("racefree", "", out code);
            Ok("4. oldest shared first, for good, until 15 % free: the auto-kept a0 and s1 go (\"Freed 6 GB: 2 shared races\"), s2 stays", code == 200 && j.Contains("Freed 6 GB: 2 shared races") && Gone("a0") && Gone("s1") && In(Sess, "s2"), j);
            Ok("4. not via the trash, and the Videos\\Paddock link went too", Library.TrashList().Count == 0 && !File.Exists(lk));
            Ok("4. a shared race Peter kept by a press, a sharing one and an unshared one stay", In(Saved, "k0") && In(Sess, "s3") && In(Sess, "s4"));

            setup();
            Library.ShareState = delegate (string id) { return id == "s1" || id == "s2" || id == "s3" ? "{\"kind\":\"shared\"}" : "{\"kind\":\"none\"}"; };
            Library.FreeResult fr = Library.FreeUpSpace();
            Ok("4. three shared: oldest first, it stops at 15 % free (s1, s2 gone; s3 stays)", fr.Count == 2 && Gone("s1") && Gone("s2") && In(Sess, "s3"), fr.Say);
            setup(); DiskFrom(20, 100, false);
            fr = Library.FreeUpSpace();
            Ok("4. already 20 % free: nothing deleted", fr.Count == 0 && In(Sess, "s1"), fr.Say);
            Library.ShareState = null;
            DiskFrom(500, 1000, true);
        }

        static void StorageMaths()
        {
            Console.WriteLine("-- 5. storage maths");
            Clean();
            Fix(Sess, "a", "Race", now - 3 * Day, 1200, (long)(2 * Gb), false);
            Fix(Saved, "b", "Race", now - 2 * Day, 1200, (long)(4 * Gb), true);
            Fix(Sess, "c", "Practice", now - 1 * Day, 1200, (long)(1 * Gb), false);
            TrashFix("t", "Practice", now - Day, (long)(0.5 * Gb));
            Reload(); DiskFrom(30, 100, true);
            Library.Store st = Library.Storage();
            Ok("5. used = the listed sessions (7 GB)", st.Used == (long)(7 * Gb), (st.Used / Gb) + "");
            Ok("5. free and the volume from the disk (30 / 100 GB)", st.Free == (long)(30 * Gb) && st.Total == (long)(100 * Gb));
            Ok("5. trash = 0.5 GB", st.Trash == (long)(0.5 * Gb));
            Ok("5. moreRaces = free / the average race (30 / 3 = 10)", st.MoreRaces == 10, st.MoreRaces + "");
            Ok("5. 30 % free is not low", !st.LowSpace);
            DiskFrom(14, 100, true); st = Library.Storage();
            Ok("5. 14 % free is low; moreRaces 4", st.LowSpace && st.MoreRaces == 4, st.MoreRaces + "");
            Ok("5. /api/library storage: usedGb 7, freeGb 14, trashGb 1 (0.5 rounds up), moreRaces 4, lowSpace true (+ W1-4: freeUp when low)", Library.Json().StartsWith("{\"storage\":{\"usedGb\":7,\"freeGb\":14,\"trashGb\":1,\"moreRaces\":4,\"lowSpace\":true,\"freeUp\":{"), Library.Json().Substring(0, 120));
            Clean(); DiskFrom(12, 100, true); st = Library.Storage();
            Ok("5. no race yet: the average is 1.2 GB (12 / 1.2 = 10)", st.MoreRaces == 10, st.MoreRaces + "");
            DiskFrom(500, 1000, true);
        }

        static void Contract()
        {
            Console.WriteLine("-- 6. the JSON contract");
            Three();
            Library.TrashResult t = Library.Trash(new string[] { "q-lone" });
            Dictionary<string, object> d = Parse(Library.Json());
            Ok("6. /api/library parses", d != null);
            if (d == null) return;
            Ok("6. top level: storage, youtube, races, trash", Missing(d, "storage,youtube,races,trash") == "", Missing(d, "storage,youtube,races,trash"));
            Ok("6. storage names", Missing(d["storage"] as Dictionary<string, object>, "usedGb,freeGb,trashGb,moreRaces,lowSpace") == "");
            Dictionary<string, object> yt = d["youtube"] as Dictionary<string, object>;
            Ok("6. youtube default: signedIn false, privacy private, template 1", yt != null && Missing(yt, "signedIn,privacy,template") == "" && (bool)yt["signedIn"] == false && (string)yt["privacy"] == "private" && Convert.ToInt32(yt["template"]) == 1);
            object[] races = d["races"] as object[];
            Ok("6. two races listed (the third is in the trash)", races != null && races.Length == 2);
            Dictionary<string, object> r = null; foreach (object o in races) { Dictionary<string, object> x = o as Dictionary<string, object>; if ((string)x["id"] == "r-race") r = x; }
            string names = "id,track,config,car,type,isRace,startMs,sec,laps,counted,best,bestLap,mb,kept,thumb,state,markers";
            Ok("6. every race name in the contract", r != null && Missing(r, names) == "", r == null ? "no r-race" : Missing(r, names));
            Ok("6. values: isRace, kept, sec 600, laps 4, counted 2, best 93.832, bestLap 4, mb 1126, thumb false", r != null && (bool)r["isRace"] && (bool)r["kept"] && Convert.ToInt32(r["sec"]) == 600 && Convert.ToInt32(r["laps"]) == 4 && Convert.ToInt32(r["counted"]) == 2 && Math.Abs(Convert.ToDouble(r["best"]) - 93.832) < 1e-6 && Convert.ToInt32(r["bestLap"]) == 4 && Convert.ToInt32(r["mb"]) == 1126 && !(bool)r["thumb"]);
            Dictionary<string, object> st = r == null ? null : r["state"] as Dictionary<string, object>;
            Ok("6. state with no hook: {\"kind\":\"none\"}", st != null && (string)st["kind"] == "none");
            object[] mk = r == null ? null : r["markers"] as object[];
            Ok("6. markers have sec, kind, label", mk != null && mk.Length == 5 && Missing(mk[0] as Dictionary<string, object>, "sec,kind,label") == "" && (string)((Dictionary<string, object>)mk[3])["label"] == "Best lap 1:33.832 (lap 4)");
            object[] tr = d["trash"] as object[];
            Ok("6. trash names: id, track, car, type, startMs, mb, deletedMs, daysLeft", tr != null && tr.Length == 1 && Missing(tr[0] as Dictionary<string, object>, "id,track,car,type,startMs,mb,deletedMs,daysLeft") == "");

            Library.ShareState = delegate (string id) { return id == "r-race" ? "{\"kind\":\"sharing\",\"pct\":41}" : null; };
            Library.YouTubeJson = delegate { return "{\"signedIn\":true,\"privacy\":\"public\",\"template\":3}"; };
            string j = Library.Json();
            Ok("6. the hooks pass through: state and youtube", j.Contains("\"state\":{\"kind\":\"sharing\",\"pct\":41}") && j.Contains("\"youtube\":{\"signedIn\":true,\"privacy\":\"public\",\"template\":3}") && j.Contains("\"id\":\"p-prac\"") && Regex.IsMatch(j, "\"id\":\"p-prac\"[^}]*\"state\":\\{\"kind\":\"none\"\\}"));
            Library.ShareState = null; Library.YouTubeJson = null;

            Dictionary<string, object> dk = Parse(Library.DeckJson());
            Ok("6. DeckJson parses: freeGb, storage, races", dk != null && Missing(dk, "freeGb,storage,races") == "" && !dk.ContainsKey("trash"));
            object[] dr = dk == null ? null : dk["races"] as object[];
            Dictionary<string, object> d0 = dr != null && dr.Length > 0 ? dr[0] as Dictionary<string, object> : null;
            string dnames = "id,track,car,type,isRace,startMs,sec,laps,best,mb,kept,thumb,state,min,saved";
            Ok("6. DeckJson races: the card's names plus min and saved, no markers", d0 != null && Missing(d0, dnames) == "" && !d0.ContainsKey("markers"), d0 == null ? "none" : Missing(d0, dnames));
            Clean();
            for (int i = 0; i < 45; i++) Fix(Sess, "m" + i.ToString("00"), "Race", now - (i + 1) * 3600000.0, 600, 1000, false);
            Reload();
            dk = Parse(Library.DeckJson());
            Ok("6. DeckJson: the 40 newest", dk != null && ((object[])dk["races"]).Length == 40 && (string)((Dictionary<string, object>)((object[])dk["races"])[0])["id"] == "m00");

            Ok("6. the four commands wait for the session to end (Gate.GuardedDo)", Gate.IsGuardedDo("racetrash", "x") && Gate.IsGuardedDo("raceundo", "b") && Gate.IsGuardedDo("raceempty", "") && Gate.IsGuardedDo("racefree", "") && Gate.IsGuardedDo("racedelete", "x"));
            Ok("6. /api/library and /api/library/thumb are read-only (no header needed); /api/do still needs it", !Gate.ChangesState("GET", "/api/library") && !Gate.ChangesState("GET", "/api/library/thumb") && Gate.ChangesState("GET", "/api/do"));
            Ok("6. Library handles racetrash, raceundo, raceempty, racefree (+ W1-4: raceshare, ytsignin, ytprivacy, yttemplate), not racedelete or recsave", Library.Handles("racetrash") && Library.Handles("raceundo") && Library.Handles("raceempty") && Library.Handles("racefree") && Library.Handles("raceshare") && Library.Handles("ytsignin") && Library.Handles("ytprivacy") && Library.Handles("yttemplate") && !Library.Handles("racedelete") && !Library.Handles("recsave"));

            // EMPTY NOW: a job on the Jobs queue
            Three(); Library.Trash(new string[] { "p-prac", "q-lone" });
            int code; j = D("raceempty", "", out code);
            Ok("6. raceempty: \"Emptying the trash\", then the trash is empty", code == 200 && j.Contains("Emptying the trash") && Wait(delegate { return Library.TrashList().Count == 0; }, 5000) && Gone("p-prac") && Gone("q-lone"), j);
            j = D("raceempty", "", out code);
            Ok("6. raceempty again: \"The trash is already empty\"", code == 409 && j.Contains("already empty"), j);
        }

        static void Thumbnails()
        {
            Console.WriteLine("-- 7. thumbnails");
            Three();
            Ok("7. before: no thumbnail, /api/library/thumb would 404", Library.Thumb("r-race", "600") == null && !Library.HasThumb("r-race"));
            List<string> order = new List<string>();
            sessionOn = false;
            Library.AfterThumb = delegate (string id) { lock (order) { order.Add(id); if (order.Count == 1) sessionOn = true; } };   // a session starts after the first one
            Library.QueueThumbs();
            bool first = Wait(delegate { lock (order) return order.Count >= 1; }, 15000);
            Thread.Sleep(1500);
            Ok("7. the first (newest) thumbnail is made", first && order.Count >= 1 && order[0] == "p-prac" && Library.HasThumb("p-prac"), string.Join(",", order.ToArray()));
            Ok("7. a session started: the job yields, the others wait", order.Count == 1 && !Library.HasThumb("q-lone") && !Library.HasThumb("r-race") && Jobs.Status().Contains("\"name\":\"race thumbnails\""), string.Join(",", order.ToArray()));
            sessionOn = false;
            bool all = Wait(delegate { return Library.HasThumb("q-lone") && Library.HasThumb("r-race"); }, 15000);
            Library.AfterThumb = null;
            Ok("7. after the session: every race has race-<id>.jpg and race-<id>-144.jpg", all && File.Exists(Path.Combine(Thumbs, "race-r-race.jpg")) && File.Exists(Path.Combine(Thumbs, "race-r-race-144.jpg")));
            Ok("7. newest first: p-prac, q-lone, r-race", string.Join(",", order.ToArray()) == "p-prac,q-lone,r-race", string.Join(",", order.ToArray()));
            byte[] big = Library.Thumb("r-race", "600"), small = Library.Thumb("r-race", "144");
            Ok("7. /api/library/thumb serves JPEGs (w=600 and w=144)", big != null && small != null && big.Length > 2 && big[0] == 0xFF && big[1] == 0xD8 && small[0] == 0xFF);
            Ok("7. no leftover .part files", Directory.GetFiles(Thumbs, "*.part.jpg").Length == 0);
            Ok("7. a bad id is refused", Library.Thumb("..\\x", "600") == null);
            Ok("7. /api/library says thumb:true", Library.Json().Contains("\"thumb\":true"));
        }

        // the review's findings (W1-1 review, 14 items), each as behaviour
        static void Review()
        {
            Console.WriteLine("-- 8. review findings");
            int code; string j;

            // 1 + 2: an unknown type, a recovered session and one being uploaded are never aged or taken by the floor
            Clean(); DiskFrom(500, 1000, true);
            Fix(Sess, "u15", "", now - 15 * Day, 600, (long)(1 * Gb), false);
            Fix(Sess, "rec15", "Practice", now - 15 * Day, 600, (long)(1 * Gb), false); Patch(Sess, "rec15", "\"recovered\":false", "\"recovered\":true");
            Fix(Sess, "sh15", "Practice", now - 15 * Day, 600, (long)(1 * Gb), false);
            Fix(Sess, "qq15", "Qualify", now - 15 * Day, 600, (long)(1 * Gb), false);
            Fix(Sess, "p15", "Practice", now - 15 * Day, 600, (long)(1 * Gb), false);
            Reload();
            Library.ShareState = delegate (string id) { return id == "sh15" ? "{\"kind\":\"sharing\",\"pct\":12}" : id == "qq15" ? "{\"kind\":\"queued\"}" : "{\"kind\":\"none\"}"; };
            Library.Tidy();
            Ok("8.1 a 15-day-old session of unknown type is not aged (it may be a race)", In(Sess, "u15"));
            Ok("8.1 a 15-day-old recovered session is not aged", In(Sess, "rec15"));
            Ok("8.2 a 15-day-old practice being uploaded (sharing) and a queued qualifying stay", In(Sess, "sh15") && In(Sess, "qq15"));
            Ok("8.1 the plain 15-day-old practice still goes to the trash", In(Trash, "p15"));
            Clean();
            Fix(Sess, "u5", "", now - 9 * Day, 600, (long)(8 * Gb), false);
            Fix(Sess, "rec5", "Practice", now - 8 * Day, 600, (long)(8 * Gb), false); Patch(Sess, "rec5", "\"recovered\":false", "\"recovered\":true");
            Fix(Sess, "up5", "Practice", now - 7 * Day, 600, (long)(8 * Gb), false);
            Fix(Sess, "p5", "Practice", now - 3 * Day, 600, (long)(8 * Gb), false);
            Reload(); DiskFrom(40, 1000, false);
            Library.ShareState = delegate (string id) { return id == "up5" ? "{\"kind\":\"sharing\"}" : "{\"kind\":\"none\"}"; };
            Library.Tidy();
            Ok("8.1/8.2 the floor takes the plain practice (p5) and never the unknown, recovered or uploading ones", Gone("p5") && In(Sess, "u5") && In(Sess, "rec5") && In(Sess, "up5"));
            Library.ShareState = null; DiskFrom(500, 1000, true);

            // 3: kept = Peter pressed KEEP; AutoKeep / Backfill = "auto"
            Clean();
            Fix(Saved, "a1", "Race", now - 2 * Day, 1200, 3000, true);
            Fix(Sess, "n1", "Race", now - 1 * Day, 1200, 3000, false);
            Reload();
            Ok("8.3 a race in saved\\ without keptBy (AutoKeep) is not \"kept\"", SessionIndex.Get("a1") != null && !SessionIndex.Get("a1").Kept && SessionIndex.Get("a1").Saved);
            string st = Recorder.Save("a1");
            Ok("8.3 a KEEP press on it (Save(id), the recsave path) makes it Peter's: keptBy peter in the sidecar", st == "SAVED" && File.ReadAllText(Path.Combine(Saved, "a1.json")).Contains("\"keptBy\":\"peter\"") && SessionIndex.Get("a1").Kept, st);
            st = Recorder.Save("n1", false);
            Ok("8.3 the automatic Save(id, false) (Backfill) keeps it as \"auto\"", st == "SAVED" && In(Saved, "n1") && File.ReadAllText(Path.Combine(Saved, "n1.json")).Contains("\"keptBy\":\"auto\"") && !SessionIndex.Get("n1").Kept, st);
            st = Recorder.Save("n1");
            Ok("8.3 then a press makes it Peter's", st == "SAVED" && File.ReadAllText(Path.Combine(Saved, "n1.json")).Contains("\"keptBy\":\"peter\""), st);
            Reload();
            Ok("8.3 keptBy survives a reload", SessionIndex.Get("n1").Kept && SessionIndex.Get("a1").Kept);

            // 4: the trash note cannot be written -> the files go back; an item with no note is never emptied by itself
            Three();
            Library.TestNoteFails = true;
            j = D("racetrash", "p-prac", out code);
            Library.TestNoteFails = false;
            Ok("8.4 no trash note: refused, the files are back in sessions\\", code == 409 && j.Contains("Not deleted") && In(Sess, "p-prac") && !File.Exists(Path.Combine(Trash, "p-prac.mp4")) && !File.Exists(Path.Combine(Trash, "p-prac.json")) && SessionIndex.Get("p-prac") != null, j);
            Clean();
            Fix(Trash, "nn", "Practice", now - 30 * Day, 600, 1000, false, Lap(1, 5, 100, false, false), "", now - 30 * Day);
            long fb; Library.Empty(false, out fb);
            RaceInfo nn = null; foreach (RaceInfo x in Library.TrashList()) if (x.Id == "nn") nn = x;
            Ok("8.4 a trash item without its note (sidecar 30 days old) is not emptied by itself, shows 14 days", In(Trash, "nn") && nn != null && nn.NoNote && Library.DaysLeft(nn) == 14);
            Library.Empty(true, out fb);
            Ok("8.4 EMPTY NOW does delete it", Gone("nn"));

            // 5: a stale list (a session of another vault in the list) is never moved or deleted; undo across a vault switch is refused
            Three();
            string other = Path.Combine(Root, @"other\sessions");
            Fix(other, "stale1", "Race", now - 20 * Day, 1200, (long)(3 * Gb), false);
            RecSess stale = Recorder.LibRead(Path.Combine(other, "stale1.json")); Recorder.LibPut(stale); SessionIndex.Forget();
            Library.TrashResult tr = Library.Trash(new string[] { "stale1" });
            Ok("8.5 trash refuses a file outside the active vault", tr.Count == 0 && tr.Why == "NOT HERE" && In(other, "stale1"), tr.Why);
            Library.ShareState = delegate (string id) { return id == "stale1" ? "{\"kind\":\"shared\"}" : "{\"kind\":\"none\"}"; };
            DiskFrom(1, 100, true);
            Library.FreeResult fr = Library.FreeUpSpace();
            Ok("8.5 free up space leaves a shared race outside the active vault alone", fr.Count == 0 && In(other, "stale1"), fr.Say);
            Library.ShareState = null; DiskFrom(500, 1000, true);
            Reload();
            tr = Library.Trash(new string[] { "p-prac" });
            Vault.Root = Path.Combine(Root, "vault2");
            int un; string uw = Library.Undo(tr.Batch, out un);
            Vault.Root = null;
            Ok("8.5 undo after the vault switched is refused; the race stays in its trash", un == 0 && uw == "Nothing to undo" && In(Trash, "p-prac"), uw);
            Reload();

            // 6: the same press twice: the same JSON answer (not "Nothing to delete"), also for a repeat the server's guard dropped
            Three();
            now += 2500;
            int c1, c2, c3;
            string j1 = Library.Do("racetrash", "p-prac", out c1), j2 = Library.Do("racetrash", "p-prac", out c2), j3 = Library.Recent("racetrash", "p-prac", out c3);
            Ok("8.6 a doubled press gets the first answer again", j1 == j2 && j1 == j3 && c1 == 200 && c2 == 200 && c3 == 200 && j1.Contains("Deleted 1 race"), j2);
            now += 2500;
            j = Library.Do("racetrash", "p-prac", out code);
            Ok("8.6 a new press 2.5 s later is a new press", code == 409 && j.Contains("Nothing to delete"), j);
            Ok("8.6 irdash answers a dropped repeat with Library.Recent", File.Exists(Path.Combine(Root, "..\\..\\dash\\src\\irdash.cs")) ? File.ReadAllText(Path.Combine(Root, "..\\..\\dash\\src\\irdash.cs")).Contains("Library.Handles(dc) ? Library.Recent(dc, da, out rc)") : false);

            // 7 + 8: a partial batch says what was not deleted; a file in use says "Try again in a minute"
            Three();
            RecSess open = new RecSess(); open.Id = "q-lone"; SetOpen(open);
            j = D("racetrash", "q-lone|p-prac", out code);
            SetOpen(null);
            Ok("8.7 \"Deleted 1 race. 1 not deleted: it is still being recorded\"", code == 200 && j.Contains("Deleted 1 race. 1 not deleted: it is still being recorded"), j);
            using (FileStream hold = new FileStream(Path.Combine(Saved, "r-race.mp4"), FileMode.Open, FileAccess.Read, FileShare.None))
                j = D("racetrash", "r-race", out code);
            Ok("8.8 a file held open: \"It is in use. Try again in a minute\"", code == 409 && j.Contains("it is in use. Try again in a minute") && In(Saved, "r-race"), j);

            // 9: undo whose sidecar cannot move back: the video goes back into the trash too (never an orphan)
            Three();
            tr = Library.Trash(new string[] { "p-prac" });
            Library.TestUndoJsonFails = true;
            uw = Library.Undo(tr.Batch, out un);
            Library.TestUndoJsonFails = false;
            Ok("8.9 undo with a stuck sidecar: the video stays in the trash with it", uw == "Nothing to undo" && In(Trash, "p-prac") && !File.Exists(Path.Combine(Sess, "p-prac.mp4")) && File.Exists(Path.Combine(Trash, "p-prac.trash")), uw);

            // 10: the deck's list in a session: no markers and no telemetry (light), trash from file sizes
            Three(); SessionIndex.Forget();
            List<RaceInfo> light = SessionIndex.All(true);
            RaceInfo lr = null; foreach (RaceInfo x in light) if (x.Id == "r-race") lr = x;
            Ok("8.10 the light list has no markers but the sidecar's best lap", lr != null && lr.Markers.Count == 0 && Math.Abs(lr.Best - 93.832) < 1e-6);
            Ok("8.10 after a change the full list is rebuilt (markers back)", SessionIndex.Get("r-race").Markers.Count == 5);

            // 12: under 1 GB the trash is said in MB
            Three(); Library.Trash(new string[] { "p-prac" });
            j = D("raceempty", "", out code);
            Ok("8.12 \"Emptying the trash: 614 MB\"", j.Contains("Emptying the trash: 614 MB"), j);
            Wait(delegate { return Library.TrashList().Count == 0; }, 5000);

            // 14: RetainSessions outside the sandbox (testOn false) deletes nothing by count or budget
            Clean();
            for (int i = 0; i < 5; i++) Fix(Sess, "keep" + i, "Practice", now - (i + 1) * 3600000.0, 600, (long)(2 * Gb), false);
            Reload();
            FieldInfo ks = typeof(Recorder).GetField("keepSessions", Any), rb = typeof(Recorder).GetField("recentBudgetBytes", Any);
            object ks0 = ks.GetValue(null), rb0 = rb.GetValue(null);
            ks.SetValue(null, 1); rb.SetValue(null, 0L);
            typeof(Recorder).GetMethod("RetainSessions", Any).Invoke(null, null);
            ks.SetValue(null, ks0); rb.SetValue(null, rb0);
            bool allThere = true; for (int i = 0; i < 5; i++) if (!In(Sess, "keep" + i)) allThere = false;
            Ok("8.14 RetainSessions (not the sandbox) with keep=1 and a 0-byte budget deletes nothing", allThere && Recorder.LibFinished().Count == 5);
        }

        // W1-4: SHARE TO YOUTUBE (raceshare) against the recorder's pretend ffmpeg and the real YouTube class with its folder in the
        // scratch and its upload job paused (Enqueue records; nothing reaches Google), plus the three settings commands.
        static void ShareChain()
        {
            Console.WriteLine("-- 9. share to YouTube");
            string yt = Path.Combine(Root, "yt"), ini = Path.Combine(Root, "irdash.ini"), cuts = Path.Combine(Vlt, "cuts");
            try { if (Directory.Exists(yt)) Directory.Delete(yt, true); if (Directory.Exists(cuts)) Directory.Delete(cuts, true); File.Delete(ini); } catch { }
            YouTube.Dir = yt; YouTube.IniFile = ini;
            YouTube.AuthUrl = YouTube.TokenUrl = YouTube.UploadUrl = YouTube.ApiUrl = "http://127.0.0.1:9/nothing";
            YouTube.OpenBrowser = delegate (string u) { Console.WriteLine("FAIL 9. a browser was opened"); };
            typeof(YouTube).GetField("paused", Any).SetValue(null, true);       // the upload job returns at once: the record stays "queued"
            Library.ShareState = YouTube.StateJson; Library.YouTubeJson = YouTube.Json;
            List<string[]> seen = new List<string[]>();
            Library.Enqueued = delegate (string id, string file, string title, string desc, string priv, string thumb) { lock (seen) seen.Add(new string[] { id, file, title, desc, priv, thumb }); };
            try
            {
                Three();
                Fix(Saved, "r-two", "Race", now - 5 * 3600000, 1300, (long)(1.2 * Gb), true, RaceLaps(), "", now - 5 * 3600000);
                Reload();
                int code; string j;
                sessionOn = true;       // the press is answered while the work waits for the session to end
                j = D("raceshare", "r-race|r-two|r-race|../x", out code);
                Dictionary<string, object> d = Parse(j);
                Ok("9.1 raceshare answers at once: 2 races, \"Sign in to YouTube first\" (not signed in)", code == 200 && d != null && Convert.ToInt32(d["count"]) == 2 && (bool)d["signin"] && (string)d["say"] == "Sign in to YouTube first", j);
                Ok("9.1 both say \"queued\" from the press, before any cut", Library.Json().Contains("\"id\":\"r-race\"") && Regex.IsMatch(Library.Json(), "\"id\":\"r-race\"[^\\]]*?\"state\":\\{\"kind\":\"queued\"") && Regex.IsMatch(Library.Json(), "\"id\":\"r-two\"[^\\]]*?\"state\":\\{\"kind\":\"queued\""));
                Thread.Sleep(300);
                Ok("9.1 nothing is cut while the session is on", seen.Count == 0 && !Directory.Exists(cuts));
                sessionOn = false;
                Ok("9.2 after the session both are cut and queued for YouTube", Wait(delegate { lock (seen) return seen.Count == 2; }, 15000), seen.Count + " queued");
                string[] q = null; lock (seen) foreach (string[] x in seen) if (x[0] == "r-race") q = x;
                Ok("9.2 the cut is vault\\cuts\\r-race-cut.mp4 and exists (the pretend ffmpeg wrote it)", q != null && q[1] == Path.Combine(cuts, "r-race-cut.mp4") && File.Exists(q[1]), q == null ? "none" : q[1]);
                Ok("9.2 the title is template 1 with the race's facts (no series known)", q != null && q[2].StartsWith("Toyota GR86 at Road Atlanta") && !q[2].Contains("{") && q[2].Length < 70, q == null ? "" : q[2]);
                Ok("9.2 the description starts with the facts and has the chapters from 0:00 Start", q != null && q[3].StartsWith("Toyota GR86 at Road Atlanta") && q[3].Contains("\n0:00 Start") && q[3].Contains("Recorded with Paddock"), q == null ? "" : q[3]);
                Ok("9.2 privacy private (the default), no thumbnail made yet", q != null && q[4] == "private" && q[5] == "");
                Ok("9.3 YouTube's own record says queued (uploads.json)", YouTube.StateJson("r-race").Contains("\"kind\":\"queued\"") && File.ReadAllText(Path.Combine(yt, "uploads.json")).Contains("r-race"));
                Ok("9.3 the page's state is still queued", Regex.IsMatch(Library.Json(), "\"id\":\"r-race\"[^\\]]*?\"state\":\\{\"kind\":\"queued\""));

                lock (seen) seen.Clear();
                j = D("raceshare", "r-race", out code);
                Thread.Sleep(500);
                Ok("9.4 a second press of a queued race: no second cut", code == 200 && seen.Count == 0, j);
                j = Library.Do("raceshare", "r-race", out code); string j2 = Library.Do("raceshare", "r-race", out code);
                Ok("9.4 the same press twice within 2 s gets the same answer", j == j2);

                Library.ShareState = delegate (string id) { return id == "r-race" ? "{\"kind\":\"shared\",\"pct\":100,\"privacy\":\"private\",\"url\":\"https://youtu.be/x\"}" : id == "r-two" ? "{\"kind\":\"sharing\",\"pct\":41}" : "{\"kind\":\"none\"}"; };
                j = D("raceshare", "r-race|r-two", out code);
                Ok("9.5 a shared or sharing race: 409 \"Already on YouTube\", nothing cut", code == 409 && j.Contains("\"say\":\"Already on YouTube\"") && seen.Count == 0, j);

                File.SetLastWriteTimeUtc(Path.Combine(cuts, "r-two-cut.mp4"), DateTime.UtcNow.AddHours(-2));
                Library.Tidy();
                Ok("9.6 the tidy removes the cut of a shared race and keeps the one still uploading", !File.Exists(Path.Combine(cuts, "r-race-cut.mp4")) && File.Exists(Path.Combine(cuts, "r-two-cut.mp4")));
                Library.ShareState = delegate (string id) { return "{\"kind\":\"none\"}"; };
                Library.Tidy();
                Ok("9.6 an old cut nothing waits for goes too", !File.Exists(Path.Combine(cuts, "r-two-cut.mp4")));

                Library.YouTubeJson = delegate { return "{\"signedIn\":true,\"privacy\":\"public\",\"template\":4}"; };
                j = D("raceshare", "q-lone", out code);
                Ok("9.7 signed in: \"Sharing 1 race\"", code == 200 && j.Contains("\"say\":\"Sharing 1 race\""), j);
                Ok("9.7 template 4 and public from the settings", Wait(delegate { lock (seen) return seen.Count == 1; }, 15000) && seen[0][2].StartsWith("Road Atlanta Toyota GR86 full race") && seen[0][4] == "public", seen.Count > 0 ? seen[0][2] + " / " + seen[0][4] : "none");

                lock (seen) seen.Clear();
                Library.CutTool = delegate (string mp4, string outDir, CutPlan p, out string outPath) { outPath = ""; return "Not enough space for the cut (needs 10 GB free)"; };
                j = D("raceshare", "p-prac", out code);
                Ok("9.8 a cut that fails: the race says failed with the reason in plain words", Wait(delegate { return Library.Json().Contains("\"kind\":\"failed\",\"error\":\"Not enough space for the cut (needs 10 GB free)\""); }, 15000) && seen.Count == 0, Library.Json());
                Library.CutTool = null;
                Library.ShareState = YouTube.StateJson; Library.YouTubeJson = YouTube.Json;

                j = D("ytprivacy", "public", out code);
                Ok("9.9 ytprivacy a=public: saved as youtube_privacy=public, \"New uploads are public\"", code == 200 && j.Contains("New uploads are public") && File.ReadAllText(ini).Contains("youtube_privacy=public") && YouTube.Json().Contains("\"privacy\":\"public\""), j);
                j = D("ytprivacy", "everyone", out code);
                Ok("9.9 ytprivacy with a wrong word: 400, nothing changed", code == 400 && YouTube.Privacy == "public", j);
                j = D("ytprivacy", "private", out code);
                Ok("9.9 ytprivacy a=private: back to private", code == 200 && YouTube.Privacy == "private");
                j = D("yttemplate", "3", out code);
                Ok("9.9 yttemplate a=3: template 3", code == 200 && YouTube.Template == 3 && YouTube.Json().Contains("\"template\":3"), j);
                j = D("yttemplate", "9", out code);
                Ok("9.9 yttemplate a=9: 400, still 3", code == 400 && YouTube.Template == 3, j);
                j = D("ytsignin", "", out code);
                Ok("9.9 ytsignin with no client.json: 409 and the set-up words, no browser", code == 409 && j.Contains("Set up YouTube first"), j);

                Dictionary<string, object> lj = Parse(Library.Json());
                object[] titles = lj == null ? null : lj["titles"] as object[];
                Ok("9.10 /api/library has the five titles for the newest race", titles != null && titles.Length == 5 && ((string)titles[0]).StartsWith("Toyota GR86 at Road Atlanta") && ((string)titles[3]).StartsWith("Road Atlanta Toyota GR86 full race"), titles == null ? "none" : string.Join(" | ", Array.ConvertAll(titles, o => (string)o)));

                Ok("9.11 raceshare and ytsignin wait for the session to end; the two settings do not", Gate.IsGuardedDo("raceshare", "x") && Gate.IsGuardedDo("ytsignin", "") && !Gate.IsGuardedDo("ytprivacy", "public") && !Gate.IsGuardedDo("yttemplate", "3"));

                // FREE UP SPACE says what it would delete: 100 GB free of 1000 (under 15 %), two old shared races of 5 GB, one kept
                Clean();
                Fix(Sess, "s1", "Race", now - 9 * Day, 1200, (long)(5 * Gb), false);
                Fix(Sess, "s2", "Race", now - 8 * Day, 1200, (long)(5 * Gb), false);
                Fix(Saved, "s3", "Race", now - 7 * Day, 1200, (long)(5 * Gb), true); PeterKeeps(Saved, "s3");
                Reload();
                DiskFrom(100, 1000, true);
                Library.ShareState = delegate (string id) { return "{\"kind\":\"shared\"}"; };
                Dictionary<string, object> fs = Parse(Library.Json())["storage"] as Dictionary<string, object>;
                Dictionary<string, object> fu = fs == null ? null : fs["freeUp"] as Dictionary<string, object>;
                Ok("9.12 low space: storage.freeUp = 2 races, 10.0 GB (not the kept one)", fu != null && Convert.ToInt32(fu["count"]) == 2 && Math.Abs(Convert.ToDouble(fu["gb"]) - 10.0) < 0.05, fu == null ? "none" : fu["count"] + " / " + fu["gb"]);
                DiskFrom(500, 1000, true);
                fs = Parse(Library.Json())["storage"] as Dictionary<string, object>;
                Ok("9.12 enough space: no freeUp", fs != null && !fs.ContainsKey("freeUp"));
            }
            finally
            {
                Library.ShareState = null; Library.YouTubeJson = null; Library.Enqueued = null; Library.CutTool = null; sessionOn = false;
                DiskFrom(500, 1000, true);
            }
        }
    }
}
