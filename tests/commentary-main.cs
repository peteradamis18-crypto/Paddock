// Entry point for tests\commentary-test.ps1 only (W1-6 TALK OVER IT): compiled with dash\src\*.cs (csc /main:IRDash.CommentaryMain) into a
// throw-away exe in tests\commentary-scratch\bin, so the vault is tests\commentary-scratch\vault. The race is a real 3-second video the
// test made; the "player" is this program calling the routes the page calls; the mix runs the real ffmpeg. No browser is opened, nothing
// reaches irdash, YouTube or the rig. Prints "ok ..." / "FAIL ..." lines, "MIXED <path>" for the test's sound check, and DONE.
//   commentary-harness.exe <ffmpeg.exe> <ffprobe.exe> <media dir with v3.mp4, voice.webm, voice-late.webm>
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class CommentaryMain
    {
        const BindingFlags Any = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static int fails;
        static volatile bool sessionOn;
        static void Ok(string what, bool cond, string why)
        {
            if (cond) Console.WriteLine("ok " + what);
            else { fails++; Console.WriteLine("FAIL " + what + (why != null && why.Length > 0 ? " (" + why + ")" : "")); }
        }
        static void Ok(string what, bool cond) { Ok(what, cond, ""); }
        static bool Wait(Func<bool> c, int ms) { for (int i = 0; i < ms / 50; i++) { if (c()) return true; Thread.Sleep(50); } return c(); }
        static Dictionary<string, object> Parse(string j) { try { return new JavaScriptSerializer().DeserializeObject(j) as Dictionary<string, object>; } catch { return null; } }
        static string Kind(string id) { Dictionary<string, object> d = Parse(Commentary.StateJson(id)); return d == null ? "?" : Convert.ToString(d["kind"]); }
        static string Root, Vlt, Sess, Media;
        static double now;

        static void Fix(string id, string file, double startMs)
        {
            Directory.CreateDirectory(Sess);
            File.Copy(file, Path.Combine(Sess, id + ".mp4"), true);
            string j = "{\"schema\":2,\"id\":\"" + id + "\",\"uniqueId\":null,\"sessionNum\":0,\"track\":\"Road Atlanta\",\"config\":\"Full Course\",\"car\":\"Toyota GR86\",\"sessionType\":\"Race\"," +
                       "\"startMs\":" + startMs.ToString("0", Inv) + ",\"endMs\":null,\"durationSec\":40.000,\"durationSource\":\"ffprobe\",\"bytes\":" + new FileInfo(file).Length + ",\"encoder\":\"hevc_nvenc\"," +
                       "\"state\":\"ready\",\"gaps\":[],\"audio\":\"ok\",\"audioSource\":\"\",\"saved\":false,\"saveWhenDone\":false,\"saveBlocked\":\"\",\"recovered\":false,\"created\":" + startMs.ToString("0", Inv) +
                       ",\"laps\":[],\"incidents\":[]}";
            File.WriteAllText(Path.Combine(Sess, id + ".json"), j, new UTF8Encoding(false));
        }
        static void Reload() { typeof(Recorder).GetMethod("LoadSessions", Any).Invoke(null, null); SessionIndex.Forget(); }
        // a new press of the same command: past the library's 2-s repeat memory
        static string D(string c, string a, out int code) { now += 2500; return Library.Do(c, a, out code); }

        static int Main(string[] a)
        {
            if (Environment.CommandLine.Contains("--mock ")) return RecMock.Run();
            Program.TestMode = true; Recorder.Mock = true;
            Root = Program.RootDir; Vlt = Path.Combine(Root, "vault"); Sess = Path.Combine(Vlt, "sessions"); Media = a.Length > 2 ? a[2] : "";
            if (!Root.Replace('/', '\\').TrimEnd('\\').EndsWith("commentary-scratch", StringComparison.OrdinalIgnoreCase)) { Console.WriteLine("FAIL the harness must run from tests\\commentary-scratch\\bin (root is " + Root + ")"); return 1; }
            Jobs.SessionOn = delegate { return sessionOn; }; Jobs.GraceMs = 0;
            Commentary.SessionOn = delegate { return sessionOn; };
            Commentary.FfmpegPath = a[0]; Commentary.FfprobePath = a[1];
            Commentary.VoiceWaitMs = 4000;
            List<string> launched = new List<string>(), closed = new List<string>();
            Commentary.Launch = delegate (string exe, string args) { lock (launched) launched.Add(args); return null; };
            Commentary.CloseHook = delegate (string id) { lock (closed) closed.Add(id); };
            // the cut: the test video as it is (the real cut is a stream copy of the race; Cuts has its own test)
            int cuts = 0;
            Library.CutTool = delegate (string mp4, string outDir, CutPlan p, out string outPath)
            {
                Directory.CreateDirectory(outDir); outPath = Path.Combine(outDir, Path.GetFileNameWithoutExtension(mp4) + "-cut.mp4");
                File.Copy(mp4, outPath, true); Interlocked.Increment(ref cuts); return "ok";
            };
            now = Recorder.WallMs();
            Library.Clock = delegate { return now; };
            Commentary.Start();          // the once-a-second watch (a session starting, a player that never starts)
            try
            {
                Rules();
                Flow(launched, closed, () => cuts);
            }
            catch (Exception ex) { Ok("the harness ran without an exception", false, ex.ToString()); }
            Console.WriteLine("DONE");
            return fails > 0 ? 1 : 0;
        }

        // ---------------- 1a. the pure rules ----------------
        static void Rules()
        {
            Console.WriteLine("-- 1. rules");
            string want = "[1:a]asplit=2[vkey][vmix];[0:a][vkey]sidechaincompress=threshold=0.04:ratio=8:attack=20:release=400[duck];[duck][vmix]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[a]";
            Ok("1.1 the filter string is exactly the decided one (D = 0)", Commentary.Filter("") == want, Commentary.Filter(""));
            string p = Commentary.MixArgs("C:\\c\\cut.mp4", "C:\\c\\voice.webm", 0.8, "C:\\c\\out.mp4");
            Ok("1.2 D = +0.8: the voice input starts 0.8 s in (-ss 0.8 before it), no delay", p.Contains("-i \"C:\\c\\cut.mp4\" -ss 0.8 -i \"C:\\c\\voice.webm\"") && !p.Contains("adelay") && p.Contains("\"" + want + "\""), p);
            string n = Commentary.MixArgs("C:\\c\\cut.mp4", "C:\\c\\voice.webm", -0.3, "C:\\c\\out.mp4");
            Ok("1.2 D = -0.3: the voice is delayed by 0.3 s (adelay=300 on the voice, nothing trimmed)", n.Contains("-i \"C:\\c\\cut.mp4\" -i \"C:\\c\\voice.webm\"") && n.Contains("[1:a]adelay=delays=300:all=1,asplit=2[vkey][vmix];[0:a][vkey]sidechaincompress=threshold=0.04:ratio=8:attack=20:release=400[duck]") && !n.Contains("-ss "), n);
            string z = Commentary.MixArgs("C:\\c\\cut.mp4", "C:\\c\\voice.webm", 0, "C:\\c\\out.mp4");
            Ok("1.2 D = 0: neither", !z.Contains("-ss ") && !z.Contains("adelay") && z.Contains("\"" + want + "\""), z);
            Ok("1.3 video copied, sound AAC 192k, hvc1 tag, faststart, the mix mapped", z.Contains("-map 0:v:0 -map \"[a]\" -c:v copy -c:a aac -b:a 192k -tag:v hvc1 -movflags +faststart \"C:\\c\\out.mp4\""), z);

            string t69 = "Porsche 911 GT3 Cup (992) at Road Atlanta · iRacing Fixed · 13 Nov 2026";
            while (t69.Length < 69) t69 += "x"; if (t69.Length > 69) t69 = t69.Substring(0, 69);
            string tw = Commentary.TitleWith(t69);
            Ok("1.4 a 69-character title: shortened first, the suffix whole, under 70", tw.EndsWith(" (with commentary)") && tw.Length < 70 && tw.StartsWith("Porsche 911 GT3 Cup (992) at Road Atlanta"), tw + " (" + tw.Length + ")");
            string shortT = Commentary.TitleWith("Toyota GR86 at Road Atlanta");
            Ok("1.4 a short title keeps every word", shortT == "Toyota GR86 at Road Atlanta (with commentary)", shortT);
            string dated = Commentary.TitleWith("Toyota GR86 at Road Atlanta Full Course Grand Prix · 13 Nov 2026");
            Ok("1.4 the date goes before any word of the title", dated == "Toyota GR86 at Road Atlanta Full Course Grand Prix (with commentary)", dated);

            foreach (string k in new string[] { "none", "preparing", "talking", "mixing", "ready", "shared", "failed" })
            {
                string j = Commentary.Json(k, 192.4, "Arctis Nova 7P", k == "talking", k == "shared" ? "https://youtu.be/x" : "", k == "failed" ? Commentary.MsgNoMic : "", "", k == "ready" ? "{\"kind\":\"queued\",\"pct\":0}" : null);
                Dictionary<string, object> d = Parse(j);
                Ok("1.5 talk JSON for " + k + " parses with kind, sec, mic, silent, url, error, note, yt", d != null && (string)d["kind"] == k && Convert.ToInt32(d["sec"]) == 192 && (string)d["mic"] == "Arctis Nova 7P" && d.ContainsKey("silent") && d.ContainsKey("url") && d.ContainsKey("error") && d.ContainsKey("note") && d["yt"] is Dictionary<string, object>, j);
            }
            Ok("1.6 racetalk waits for the session to end; racetalkstop does not", Gate.IsGuardedDo("racetalk", "r") && !Gate.IsGuardedDo("racetalkstop", "r") && !Gate.IsGuardedDo("racetalkstop", ""));
        }

        // ---------------- 1b. the flow, with the real ffmpeg for the mix ----------------
        static void Flow(List<string> launched, List<string> closed, Func<int> cuts)
        {
            Console.WriteLine("-- 1. the talk, start to share");
            string yt = Path.Combine(Root, "yt"), ini = Path.Combine(Root, "irdash.ini");
            try { if (Directory.Exists(Vlt)) Directory.Delete(Vlt, true); if (Directory.Exists(yt)) Directory.Delete(yt, true); } catch { }
            Directory.CreateDirectory(yt);
            YouTube.Dir = yt; YouTube.IniFile = ini;
            YouTube.AuthUrl = YouTube.TokenUrl = YouTube.UploadUrl = YouTube.ApiUrl = "http://127.0.0.1:9/nothing";
            YouTube.OpenBrowser = delegate (string u) { Console.WriteLine("FAIL a browser was opened"); };
            YouTube.Reset(); typeof(YouTube).GetField("paused", Any).SetValue(null, true);
            Library.ShareState = YouTube.StateJson;
            Library.YouTubeJson = delegate { return YouTube.Json().Replace("\"signedIn\":false", "\"signedIn\":true"); };
            List<string[]> seen = new List<string[]>();
            Library.Enqueued = delegate (string id, string file, string title, string desc, string priv, string thumb) { lock (seen) seen.Add(new string[] { id, file, title, desc, priv, thumb }); };
            string v3 = Path.Combine(Media, "v3.mp4");
            Fix("t1", v3, now - 3600000); Fix("t2", v3, now - 7200000); Fix("t3", v3, now - 9000000);
            Reload();
            typeof(Commentary).GetField("metas", Any).SetValue(null, null);
            string cutDir = Path.Combine(Vlt, "cuts"), comDir = Path.Combine(Vlt, "commentary");
            int code; string j;

            // a session is on: TALK OVER IT is refused, by the guard (/api/do) and by Start itself
            sessionOn = true;
            j = D("racetalk", "t1", out code);
            Ok("1.7 a session on: racetalk refused (409, plain words), nothing opened, no cut", code == 409 && j.Contains("Not while a session is on") && launched.Count == 0 && cuts() == 0, j);
            sessionOn = false;

            // the press: the cut is made first ("preparing"), then the player opens on the primary screen
            j = D("racetalk", "t1", out code);
            Ok("1.8 TALK OVER IT: 200 \"Getting the race ready\", the race says preparing", code == 200 && j.Contains("Getting the race ready") && (Kind("t1") == "preparing" || launched.Count > 0), j);
            Ok("1.8 the cut is made (Jobs, between sessions) and the player opens", Wait(delegate { return launched.Count == 1; }, 8000) && cuts() == 1 && File.Exists(Path.Combine(cutDir, "t1-cut.mp4")));
            string args = launched.Count > 0 ? launched[0] : "";
            System.Drawing.Rectangle pr = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
            Ok("1.9 the player: its own profile, the Windows primary screen, full screen, sound allowed, the mic without a prompt, player.html of this race",
               args.Contains("player-profile") && !args.Contains("browser-profile") && args.Contains("--window-position=" + pr.X + "," + pr.Y + " --window-size=" + pr.Width + "," + pr.Height) &&
               args.Contains("--start-fullscreen") && args.Contains("--autoplay-policy=no-user-gesture-required") && args.Contains("--use-fake-ui-for-media-stream") && args.EndsWith("--app=http://localhost:8199/v2/player.html?id=t1"), args);
            j = D("racetalk", "t2", out code);
            Ok("1.10 a second race while one is on: 409 \"press STOP first\"", code == 409 && j.Contains("STOP first"), j);
            Ok("1.10 the player's state route: not stopped", Commentary.PlayerState("t1").Contains("\"stop\":false"));

            Commentary.Event("t1", "started", "Arctis Nova 7P", out code);
            Dictionary<string, object> st = Parse(Commentary.StateJson("t1"));
            Ok("1.11 the player says started: talking, with the microphone's name", Kind("t1") == "talking" && (string)st["mic"] == "Arctis Nova 7P", Commentary.StateJson("t1"));
            Commentary.Event("t1", "silent", "", out code);
            Ok("1.11 a silent microphone shows in the state", Commentary.StateJson("t1").Contains("\"silent\":true"));
            Commentary.Event("t1", "loud", "", out code);
            Ok("1.11 and goes when he is heard again", Commentary.StateJson("t1").Contains("\"silent\":false"));
            Ok("1.12 /api/library and the deck's list carry the talk", Library.Json().Contains("\"talk\":{\"kind\":\"talking\"") && Library.DeckJson().Contains("\"talk\":{\"kind\":\"talking\""));
            Ok("1.13 the cut stays while he talks (the tidy leaves it)", Commentary.Holds("t1") && TidyKeeps("t1-cut.mp4"));

            // STOP with a session on is allowed (it only ends things); the player then sends the voice (here at D = +0.5)
            sessionOn = true;
            j = D("racetalkstop", "t1", out code);
            Ok("1.14 STOP with a session on: 200, mixing at once", code == 200 && Kind("t1") == "mixing", j);
            Ok("1.14 the player is told to stop", Commentary.PlayerState("t1").Contains("\"stop\":true"));
            byte[] voice = File.ReadAllBytes(Path.Combine(Media, "voice-late.webm"));
            j = Commentary.OnVoice("t1", voice, 0.5, 2.9, "Arctis Nova 7P", false, out code);
            Ok("1.15 the voice comes in: 200", code == 200, j);
            Thread.Sleep(400);
            Ok("1.15 nothing over 1 MB is written in a session: the voice waits (Jobs.Save)", !File.Exists(Path.Combine(comDir, "t1-voice.webm")) && !File.Exists(Path.Combine(comDir, "t1-commentary.mp4")));
            Ok("1.15 the player window closes", Wait(delegate { lock (closed) return closed.Contains("t1"); }, 3000));
            sessionOn = false;
            bool mixed = Wait(delegate { return Kind("t1") == "ready"; }, 60000);
            Ok("1.16 after the session: kept, mixed with the real ffmpeg, verified, ready", mixed, Commentary.StateJson("t1"));
            string outMp4 = Path.Combine(comDir, "t1-commentary.mp4");
            Ok("1.16 the commentary video exists, the voice file is gone after the check, the note says mixed", File.Exists(outMp4) && !File.Exists(Path.Combine(comDir, "t1-voice.webm")) && File.ReadAllText(Path.Combine(comDir, "t1.json")).Contains("\"mixed\":true"));
            Ok("1.16 the mix used D = +0.5 (the voice trimmed by 0.5 s)", Commentary.LastMixArgs.Contains("-ss 0.5 -i \"") && Commentary.LastMixArgs.Contains("t1-voice.webm"), Commentary.LastMixArgs);
            if (File.Exists(outMp4)) Console.WriteLine("MIXED " + outMp4);
            Ok("1.16 ready says the length and the microphone; the first video is untouched", Commentary.StateJson("t1").Contains("\"sec\":3") && Commentary.StateJson("t1").Contains("Arctis") && YouTube.StateJson("t1") == "{\"kind\":\"none\"}", Commentary.StateJson("t1"));

            // SHARE COMMENTARY: a second video "... (with commentary)", its own record (<id>:c), never twice
            j = D("raceshare", "t2:c", out code);
            Ok("1.17 no commentary yet: 409 \"Talk over the race first\"", code == 409 && j.Contains("Talk over the race first"), j);
            j = D("raceshare", "t1:c", out code);
            string[] s1 = null; lock (seen) foreach (string[] x in seen) if (x[0] == "t1:c") s1 = x;
            Ok("1.18 raceshare a=t1:c: 200 \"Sharing it with your commentary\", queued as t1:c with the commentary file", code == 200 && j.Contains("Sharing it with your commentary") && s1 != null && s1[1] == outMp4 && YouTube.StateJson("t1:c").Contains("\"kind\":\"queued\""), j);
            Ok("1.18 its title ends \" (with commentary)\" and is under 70, the same description", s1 != null && s1[2].EndsWith(" (with commentary)") && s1[2].Length < 70 && s1[2].StartsWith("Toyota GR86 at Road Atlanta") && s1[3].Contains("Recorded with Paddock"), s1 == null ? "" : s1[2]);
            Ok("1.18 the race's own video is not shared by it", YouTube.StateJson("t1") == "{\"kind\":\"none\"}");
            Ok("1.18 the talk says ready with YouTube's queued record", Commentary.StateJson("t1").Contains("\"kind\":\"ready\"") && Commentary.StateJson("t1").Contains("\"yt\":{\"kind\":\"queued\""), Commentary.StateJson("t1"));
            j = D("raceshare", "t1:c", out code);
            Ok("1.19 a second press: \"Already waiting for YouTube\", not queued twice", j.Contains("Already waiting for YouTube") && Count(seen, "t1:c") == 1, j);

            // a session starts while he talks: Paddock stops by itself and keeps what was said
            j = D("racetalk", "t2", out code);
            Ok("1.20 the next race: the cut is made, the player opens", code == 200 && Wait(delegate { return launched.Count == 2; }, 8000), j);
            Commentary.Event("t2", "started", "Default - Microphone (Arctis Nova 7P)", out code);
            sessionOn = true;
            bool stopped = Wait(delegate { return Kind("t2") == "mixing"; }, 3000);
            Ok("1.20 a session starts while he talks: stopped within 2 s, \"what you said is kept\"", stopped && Commentary.StateJson("t2").Contains(Commentary.MsgSession), Commentary.StateJson("t2"));
            j = Commentary.OnVoice("t2", File.ReadAllBytes(Path.Combine(Media, "voice.webm")), -0.3, 2.0, "", false, out code);
            Thread.Sleep(300);
            Ok("1.20 its voice is taken but written only after the session", code == 200 && !File.Exists(Path.Combine(comDir, "t2-voice.webm")));
            sessionOn = false;
            Ok("1.20 after the session it is mixed (D = -0.3: the voice delayed)", Wait(delegate { return Kind("t2") == "ready"; }, 60000) && Commentary.LastMixArgs.Contains("adelay=delays=300:all=1"), Commentary.StateJson("t2") + " " + Commentary.LastMixArgs);

            // no microphone: the plain sentence, the player closes
            lock (closed) closed.Clear();
            j = D("racetalk", "t3", out code);
            Wait(delegate { return launched.Count == 3; }, 8000);
            Commentary.Event("t3", "nomic", "", out code);
            Ok("1.21 no microphone: failed with \"No microphone found. Plug in the headset and press again.\", the player closes", Kind("t3") == "failed" && Commentary.StateJson("t3").Contains(Commentary.MsgNoMic) && Wait(delegate { lock (closed) return closed.Contains("t3"); }, 2000), Commentary.StateJson("t3"));
            j = D("racetalkstop", "", out code);
            Ok("1.22 STOP with nothing on: 409 \"Nothing to stop\"", code == 409 && j.Contains("Nothing to stop"), j);

            // the player never says started: the talk ends by itself
            int keep = Commentary.StartWaitMs; Commentary.StartWaitMs = 1000;
            j = D("racetalk", "t3", out code);
            Ok("1.23 a player that never starts: failed after the wait, closed", Wait(delegate { return Kind("t3") == "failed" && Commentary.StateJson("t3").Contains("did not start"); }, 8000), Commentary.StateJson("t3"));
            Commentary.StartWaitMs = keep;

            // the race is deleted for good: its commentary goes too
            typeof(Library).GetMethod("Erase", Any).Invoke(null, new object[] { SessionIndex.Get("t2") });
            Ok("1.24 a race deleted for good takes its commentary with it", !File.Exists(Path.Combine(comDir, "t2-commentary.mp4")) && !File.Exists(Path.Combine(comDir, "t2.json")) && Kind("t2") == "none");
            Library.ShareState = null; Library.YouTubeJson = null; Library.Enqueued = null; Library.CutTool = null;
        }
        static int Count(List<string[]> seen, string id) { int n = 0; lock (seen) foreach (string[] x in seen) if (x[0] == id) n++; return n; }
        static bool TidyKeeps(string cutName)
        {
            string f = Path.Combine(Path.Combine(Vlt, "cuts"), cutName);
            try { File.SetLastWriteTimeUtc(f, DateTime.UtcNow.AddHours(-5)); } catch { }
            Library.TidyCuts();
            return File.Exists(f);
        }
    }
}
