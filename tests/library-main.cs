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
        static void Reload() { typeof(Recorder).GetMethod("LoadSessions", Any).Invoke(null, null); }
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
            int code; string j = Library.Do("racetrash", "p-prac", out code);
            Dictionary<string, object> d = Parse(j);
            string batch = d != null && d.ContainsKey("batch") ? (string)d["batch"] : "";
            Ok("2. racetrash answers batch, count 1, mb, \"Deleted 1 race\"", code == 200 && batch.Length > 0 && Convert.ToInt32(d["count"]) == 1 && d.ContainsKey("mb") && (string)d["say"] == "Deleted 1 race", j);
            Ok("2. the files are in vault\\trash, not in sessions\\", In(Trash, "p-prac") && !File.Exists(Path.Combine(Sess, "p-prac.mp4")) && File.Exists(Path.Combine(Trash, "p-prac.trash")));
            Ok("2. the Videos\\Paddock link is gone", !File.Exists(lp));
            Ok("2. the list no longer has it", SessionIndex.Get("p-prac") == null && !Ids(SessionIndex.All()).Contains("p-prac"));
            List<RaceInfo> t = Library.TrashList();
            Ok("2. the trash lists it with daysLeft 14", t.Count == 1 && t[0].Id == "p-prac" && Library.DaysLeft(t[0]) == 14, t.Count > 0 ? Library.DaysLeft(t[0]) + "" : "empty");
            Ok("2. /api/library's trash part has it with \"daysLeft\":14", Library.Json().Contains("\"trash\":[{\"id\":\"p-prac\"") && Library.Json().Contains("\"daysLeft\":14"));
            j = Library.Do("raceundo", batch, out code);
            Ok("2. undo: \"1 race is back\"", code == 200 && j.Contains("\"say\":\"1 race is back\""), j);
            Ok("2. undo: the files are back in sessions\\, the trash is empty", In(Sess, "p-prac") && !File.Exists(Path.Combine(Trash, "p-prac.mp4")) && !File.Exists(Path.Combine(Trash, "p-prac.trash")) && Library.TrashList().Count == 0);
            Ok("2. undo: re-exported (the hard link is back)", File.Exists(lp));
            Ok("2. undo: listed again", SessionIndex.Get("p-prac") != null);
            j = Library.Do("raceundo", batch, out code);
            Ok("2. undo twice -> \"Nothing to undo\"", code == 409 && j.Contains("Nothing to undo"), j);
            j = Library.Do("raceundo", "b-unknown", out code);
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
            j = Library.Do("racetrash", "q-lone", out code);
            Ok("2. refused while that session is being recorded", code == 409 && j.Contains("still being recorded") && In(Sess, "q-lone"), j);
            SetOpen(null);
            Ok("2. the old racedelete (Vault.Do) now trashes too", Vault.Do("racedelete", "q-lone") && In(Trash, "q-lone"));
            Three();
            j = Library.Do("racetrash", "q-lone|p-prac|../evil", out code);
            Ok("2. several at once: \"Deleted 2 races\", a bad id is ignored", code == 200 && j.Contains("\"count\":2") && j.Contains("Deleted 2 races") && In(Trash, "q-lone") && In(Trash, "p-prac"), j);
            j = Library.Do("racetrash", "nope", out code);
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
                Fix(Saved, "k0", "Race", now - 10 * Day, 1200, (long)(3 * Gb), true);
                Fix(Sess, "s1", "Race", now - 9 * Day, 1200, (long)(3 * Gb), false);
                Fix(Sess, "s2", "Race", now - 8 * Day, 1200, (long)(3 * Gb), false);
                Fix(Sess, "s3", "Race", now - 7 * Day, 1200, (long)(3 * Gb), false);
                Fix(Sess, "s4", "Race", now - 6 * Day, 1200, (long)(3 * Gb), false);
                Reload(); DiskFrom(10, 100, false);
            };
            setup();
            Library.ShareState = null;
            int code; string j = Library.Do("racefree", "", out code);
            Ok("4. no hook: nothing is deleted, and it says so", code == 409 && j.Contains("cannot tell") && In(Sess, "s1") && In(Sess, "s2") && In(Saved, "k0"), j);

            string lk = Export("s1");
            shared = delegate (string id) { return id == "s1" || id == "s2" || id == "k0" ? "{\"kind\":\"shared\",\"privacy\":\"private\",\"url\":\"https://youtu.be/x\"}" : id == "s3" ? "{\"kind\":\"sharing\",\"pct\":41}" : "{\"kind\":\"none\"}"; };
            Library.ShareState = shared;
            j = Library.Do("racefree", "", out code);
            Ok("4. the two shared races go, for good: \"Freed 6 GB: 2 shared races\"", code == 200 && j.Contains("Freed 6 GB: 2 shared races") && Gone("s1") && Gone("s2"), j);
            Ok("4. not via the trash, and the Videos\\Paddock link went too", Library.TrashList().Count == 0 && !File.Exists(lk));
            Ok("4. a Kept shared race, a sharing one and an unshared one stay", In(Saved, "k0") && In(Sess, "s3") && In(Sess, "s4"));

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
            Ok("5. /api/library storage: usedGb 7, freeGb 14, trashGb 1 (0.5 rounds up), moreRaces 4, lowSpace true", Library.Json().StartsWith("{\"storage\":{\"usedGb\":7,\"freeGb\":14,\"trashGb\":1,\"moreRaces\":4,\"lowSpace\":true}"), Library.Json().Substring(0, 90));
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
            Ok("6. Library handles exactly racetrash, raceundo, raceempty, racefree", Library.Handles("racetrash") && Library.Handles("raceundo") && Library.Handles("raceempty") && Library.Handles("racefree") && !Library.Handles("racedelete") && !Library.Handles("recsave"));

            // EMPTY NOW: a job on the Jobs queue
            Three(); Library.Trash(new string[] { "p-prac", "q-lone" });
            int code; j = Library.Do("raceempty", "", out code);
            Ok("6. raceempty: \"Emptying the trash\", then the trash is empty", code == 200 && j.Contains("Emptying the trash") && Wait(delegate { return Library.TrashList().Count == 0; }, 5000) && Gone("p-prac") && Gone("q-lone"), j);
            j = Library.Do("raceempty", "", out code);
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
    }
}
