// COMMENTARY (W1-6, docs/rework/cards/W1-6.md): TALK OVER IT. Peter presses one key; the race's YouTube cut plays full-screen in
// Paddock's own player (dash\www\v2\player.html, Chrome/Edge in app mode on the Windows primary screen = the middle race screen) and
// the browser records the microphone from the same instant (MediaRecorder; the sync is measured in the page, not guessed). STOP
// (page, deck, Esc, the video's end, or a session starting) -> the voice comes back to irdash, which mixes it under the game sound
// (sidechaincompress ducks the game while he talks) into vault\commentary\<id>-commentary.mp4 and offers it as a second YouTube
// video "... (with commentary)" (library.cs raceshare a=<id>:c).
// One talk at a time. Nothing heavy runs in a session: the cut and the mix are Jobs.Run(whenFree); a voice that arrives while a session
// is on is written by Jobs.Save after it.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Management;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class Commentary
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly object gate = new object();

        // ---- wired by irdash at start-up ----
        public static Func<string> Browser;                 // Program.BrowserExe: Chrome or Edge, null = none
        public static int Port = 8199;
        // ---- for the tests ----
        public static Func<bool> SessionOn;                 // null = RigState.SessionOn
        internal static Func<double> Clock;                 // wall ms
        internal static Func<string, string, Process> Launch;   // (exe, args) instead of starting a browser; null = Process.Start
        internal static Action<string> CloseHook;           // instead of closing the player's browser (race id)
        internal static string FfmpegPath, FfprobePath;     // run these directly; null = the recorder's tool runner and its ffprobe
        internal static string LastLaunchArgs = "", LastMixArgs = "";
        public static int VoiceWaitMs = 10000;              // after STOP, how long the player has to send what was said
        public static int StartWaitMs = 40000;              // the player must say "started" this long after it was opened
        public static int PrepareWaitMs = 90000;            // and open this long after the press (the cut waits behind any job): never minutes later
        public static int TidyDays = 30;                    // an unshared commentary video (about 1 GB) goes after this long
        public static int LeftoverGraceMs = 15000;          // at irdash start an old player gets this long to send what was said before it is closed
        public const string MsgBusy = "Paddock was busy, press TALK OVER IT again";
        const string MicSite = "http://localhost:{0},*";    // the player profile's microphone grant (Chrome's content settings key)
        const long VoiceMaxBytes = 300L * 1024 * 1024;      // opus at ~32 kbit/s is ~15 MB an hour; anything near this is not a voice
        public const string Suffix = " (with commentary)";
        public const string MsgNoMic = "No microphone found. Plug in the headset and press again.";
        public const string MsgSilent = "The microphone is silent. Is it muted?";
        public const string MsgCannotPlay = "This PC cannot play the video in Paddock's player";
        public const string MsgSession = "Stopped: a session started. What you said is kept.";
        // the mix, exactly as decided (evidence 14 F); starting values, tuned by ear on the rig
        public const string Duck = "sidechaincompress=threshold=0.04:ratio=8:attack=20:release=400";
        public const string Mix2 = "amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95";

        sealed class Talk
        {
            public string Id = "", Kind = "preparing", Mic = "", Error = "", Note = "";
            public bool Silent, StopAsked, VoiceIn;
            public double AskedMs, OpenedMs, StartedMs, Secs;
            public Process Player;
        }
        static readonly Dictionary<string, Talk> talks = new Dictionary<string, Talk>();

        // what is on disk per race: <id>.json (d, secs, mic, when, silent, mixed), <id>-voice.webm until the mix is verified, <id>-commentary.mp4
        sealed class Meta { public double D, Secs, When, Stall; public string Mic = ""; public bool Silent, Mixed, HasVideo, HasVoice; public long Bytes; }
        static Dictionary<string, Meta> metas;      // null = not read yet (read once; only this file writes the folder)

        static double Now { get { return Clock != null ? Clock() : (DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds; } }
        static bool On() { try { return SessionOn != null ? SessionOn() : RigState.SessionOn; } catch { return false; } }
        static string Dir { get { return Path.Combine(Recorder.LibVaultRoot, "commentary"); } }
        public static string VideoPath(string id) { return Path.Combine(Dir, id + "-commentary.mp4"); }
        static string VoicePath(string id) { return Path.Combine(Dir, id + "-voice.webm"); }
        static string MetaPath(string id) { return Path.Combine(Dir, id + ".json"); }
        static bool Active(string k) { return k == "preparing" || k == "talking" || k == "mixing"; }
        static void Bump() { try { Library.Bump(); } catch { } }

        // ================= pure rules (tests\commentary-test.ps1 section 1) =================

        // D = seconds of voice recorded before the video's first frame (the player measures it: (playing - recorder start) - currentTime).
        // D > 0: the first D seconds were said before the video moved, so the voice starts D seconds in (-ss D on the voice input).
        // D < 0: the voice began after the video did: it is delayed by -D inside the filter (adelay). -itsoffset on the voice input was
        // measured not to move it once it goes through -filter_complex (the voice was heard from 0 s, 2026-11-14), so it is not used.
        public static string MixArgs(string cut, string voice, double d, string outPath) { return MixArgs(cut, voice, d, outPath, true); }
        // hevc: the rig's cuts are HEVC and get YouTube's hvc1 tag; mp4 refuses that tag on any other video (the test's h264 clip)
        public static string MixArgs(string cut, string voice, double d, string outPath, bool hevc)
        {
            string seek = d > 0.0005 ? "-ss " + d.ToString("0.###", Inv) + " " : "";
            string delay = d < -0.0005 ? "adelay=delays=" + Math.Round(-d * 1000).ToString("0", Inv) + ":all=1," : "";
            return "-hide_banner -y -i \"" + cut + "\" " + seek + "-i \"" + voice + "\" -filter_complex \"" + Filter(delay) + "\"" +
                   " -map 0:v:0 -map \"[a]\" -c:v copy -c:a aac -b:a 192k " + (hevc ? "-tag:v hvc1 " : "") + "-movflags +faststart \"" + outPath + "\"";
        }
        // apad: the voice runs on as silence to the end of the race. Without it the ducking stops where he pressed STOP and amix
        // (duration=first) ends the whole sound track there: the rest of the race would be silent (review W1-6 #1).
        public static string Filter(string delay)
        {
            return "[1:a]" + (delay ?? "") + "apad,asplit=2[vkey][vmix];[0:a][vkey]" + Duck + "[duck];[duck][vmix]" + Mix2 + "[a]";
        }

        // the second video's title: under 70 characters with the suffix whole. The title gives way first: its last " · " part, then words.
        public static string TitleWith(string title)
        {
            string t = (title ?? "").Trim();
            if (t.Length == 0) t = "iRacing race";
            const int Max = 69;
            while (t.Length + Suffix.Length > Max)
            {
                int dot = t.LastIndexOf(" · ", StringComparison.Ordinal);
                int sp = t.LastIndexOf(' ');
                if (dot > 0) t = t.Substring(0, dot);
                else if (sp > 0) t = t.Substring(0, sp);
                else t = t.Substring(0, Max - Suffix.Length);
                t = t.TrimEnd(' ', '·', ':', ',', '-');
            }
            return t + Suffix;
        }

        // the "talk" object of /api/library per race
        public static string Json(string kind, double sec, string mic, bool silent, string url, string error, string note, string yt) { return Json(kind, sec, mic, silent, url, error, note, yt, 0); }
        // stall: seconds the video stood still while he talked (buffering); over 0.5 s the words after it may be early by that much
        public static string Json(string kind, double sec, string mic, bool silent, string url, string error, string note, string yt, double stall)
        {
            return "{\"kind\":" + Json_.S(kind) + ",\"sec\":" + Math.Max(0, Math.Round(sec)).ToString("0", Inv) + ",\"mic\":" + Json_.S(mic ?? "") +
                   ",\"silent\":" + (silent ? "true" : "false") + ",\"url\":" + Json_.S(url ?? "") + ",\"error\":" + Json_.S(error ?? "") +
                   ",\"note\":" + Json_.S(note ?? "") + ",\"stall\":" + Math.Max(0, stall).ToString("0.0", Inv) +
                   ",\"yt\":" + (string.IsNullOrEmpty(yt) ? "{\"kind\":\"none\"}" : yt) + "}";
        }

        // ================= state =================
        static string Yt(string id)
        {
            Func<string, string> h = Library.ShareState;
            string j = "";
            if (h != null) { try { j = (h(id + ":c") ?? "").Trim(); } catch { j = ""; } }
            return j.StartsWith("{") && j.EndsWith("}") ? j : "{\"kind\":\"none\"}";
        }
        static string KindOf(string json) { Match m = Regex.Match(json ?? "", "\"kind\"\\s*:\\s*\"([a-z]+)\""); return m.Success ? m.Groups[1].Value : "none"; }
        static string UrlOf(string json) { Match m = Regex.Match(json ?? "", "\"url\"\\s*:\\s*\"([^\"]*)\""); return m.Success ? m.Groups[1].Value : ""; }

        public static string StateJson(string id)
        {
            Talk t; Meta m;
            lock (gate) { talks.TryGetValue(id ?? "", out t); m = MetaOf(id); }
            if (t != null)
            {
                double sec = t.Kind == "talking" ? (Now - t.StartedMs) / 1000.0 : t.Secs;
                return Json(t.Kind, sec, t.Mic, t.Silent, "", t.Error, t.Note, null);
            }
            if (m != null && m.Mixed)
            {
                string yt = Yt(id), k = KindOf(yt);
                if (k == "shared") return Json("shared", m.Secs, m.Mic, m.Silent, UrlOf(yt), "", "", yt, m.Stall);
                if (m.HasVideo || k == "queued" || k == "sharing") return Json("ready", m.Secs, m.Mic, m.Silent, "", "", "", yt, m.Stall);
            }
            if (m != null && m.HasVoice && !m.Mixed) return Json("mixing", m.Secs, m.Mic, m.Silent, "", "", "", null);    // after a restart, the mix waits its turn
            return Json("none", 0, "", false, "", "", "", null);
        }

        // the cut (vault\cuts) and the voice must stay while a talk needs them (Library.TidyCuts asks)
        public static bool Holds(string id)
        {
            lock (gate)
            {
                Talk t; if (talks.TryGetValue(id ?? "", out t) && Active(t.Kind)) return true;
                Meta m = MetaOf(id);
                return m != null && m.HasVoice && !m.Mixed && Now - m.When < 2 * 86400000.0;
            }
        }
        public static bool Ready(string id) { lock (gate) { Meta m = MetaOf(id); return m != null && m.Mixed && m.HasVideo && File.Exists(VideoPath(id)); } }
        public static long Bytes() { long b = 0; lock (gate) { Load(); foreach (Meta m in metas.Values) if (m.HasVideo) b += m.Bytes; } return b; }

        static Meta MetaOf(string id) { Load(); Meta m; return id != null && metas.TryGetValue(id, out m) ? m : null; }
        static void Load()
        {
            if (metas != null) return;
            metas = new Dictionary<string, Meta>();
            try
            {
                if (!Directory.Exists(Dir)) return;
                foreach (string j in Directory.GetFiles(Dir, "*.json"))
                {
                    string id = Path.GetFileNameWithoutExtension(j);
                    if (!Library.IdOk(id)) continue;
                    Meta m = Read(j);
                    m.HasVoice = File.Exists(VoicePath(id));
                    try { FileInfo f = new FileInfo(VideoPath(id)); m.HasVideo = f.Exists; m.Bytes = f.Exists ? f.Length : 0; } catch { }
                    metas[id] = m;
                }
            }
            catch (Exception ex) { Log.W("commentary: could not read its folder (" + ex.Message + ")"); }
        }
        static Meta Read(string path)
        {
            Meta m = new Meta();
            try
            {
                string s = File.ReadAllText(path, Encoding.UTF8);
                m.D = Num(s, "d"); m.Secs = Num(s, "secs"); m.When = Num(s, "when"); m.Stall = Num(s, "stall");
                Match mm = Regex.Match(s, "\"mic\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""); if (mm.Success) m.Mic = Regex.Unescape(mm.Groups[1].Value);
                m.Silent = Regex.IsMatch(s, "\"silent\"\\s*:\\s*true"); m.Mixed = Regex.IsMatch(s, "\"mixed\"\\s*:\\s*true");
            }
            catch { }
            return m;
        }
        static double Num(string s, string k)
        {
            Match m = Regex.Match(s, "\"" + k + "\"\\s*:\\s*(-?[0-9.eE+-]+)");
            double v; return m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float, Inv, out v) ? v : 0;
        }
        static void WriteMeta(string id, Meta m)
        {
            string j = "{\"d\":" + m.D.ToString("0.000", Inv) + ",\"secs\":" + m.Secs.ToString("0.0", Inv) + ",\"stall\":" + m.Stall.ToString("0.00", Inv) + ",\"mic\":" + Json_.S(m.Mic) + ",\"when\":" + m.When.ToString("0", Inv) +
                       ",\"silent\":" + (m.Silent ? "true" : "false") + ",\"mixed\":" + (m.Mixed ? "true" : "false") + "}";
            string p = MetaPath(id), tmp = p + ".tmp";
            File.WriteAllText(tmp, j, new UTF8Encoding(false));
            if (File.Exists(p)) File.Delete(p);
            File.Move(tmp, p);
        }

        // ================= TALK OVER IT (racetalk) =================
        static string Say(bool ok, string say) { return "{\"ok\":" + (ok ? "true" : "false") + ",\"say\":" + Json_.S(say) + "}"; }

        public static string Start(string id, out int code)
        {
            code = 200;
            if (!Library.IdOk(id)) { code = 400; return Say(false, "Pick a race first"); }
            if (On()) { code = 409; return Say(false, "Not while a session is on. Talk over it after the session."); }
            RaceInfo r = SessionIndex.Get(id);
            if (r == null || r.InTrash) { code = 404; return Say(false, "That race is not here any more"); }
            string yk = KindOf(Yt(id));
            if (yk == "shared" || yk == "sharing") { code = 409; return Say(false, "This race is already on YouTube with your commentary"); }
            string exe = Launch != null ? "test" : (Browser != null ? Browser() : null);
            if (exe == null) { code = 409; return Say(false, "No Chrome or Edge found, so Paddock cannot play the race"); }
            Talk t;
            lock (gate)
            {
                foreach (Talk o in talks.Values)
                {
                    if (o.Id == id && (o.Kind == "preparing" || o.Kind == "talking")) return Say(true, "Already talking over this race");
                    if (o.Kind == "preparing" || o.Kind == "talking") { code = 409; return Say(false, "Already talking over another race. Press STOP first."); }
                    if (o.Id == id && o.Kind == "mixing") { code = 409; return Say(false, "Still mixing your last commentary. One moment."); }
                }
                t = new Talk(); t.Id = id; t.AskedMs = Now; talks[id] = t;
            }
            Log.W("commentary: TALK OVER IT pressed for " + id);
            EnsureWatch();
            Bump();
            string cut = Library.CutFile(id);
            if (File.Exists(cut)) OpenPlayer(t);
            else Jobs.Run("talk cut " + id, delegate { PrepareCut(t); }, true);
            return Say(true, "Getting the race ready");
        }

        // on the Jobs worker: the race's YouTube cut, the same file SHARE uploads (made once, a few seconds: stream copy)
        static void PrepareCut(Talk t)
        {
            if (!Mine(t)) return;                                         // STOP while it waited
            string path, res = Library.MakeCut(t.Id, out path);
            if (res == "YIELD" || On()) { Drop(t, MsgSession); return; }
            if (res != "ok") { Fail(t, res); return; }
            if (Mine(t)) OpenPlayer(t);
        }
        static bool Mine(Talk t) { lock (gate) { Talk x; return talks.TryGetValue(t.Id, out x) && x == t && x.Kind == "preparing" && !x.StopAsked; } }

        static void OpenPlayer(Talk t)
        {
            if (On()) { Drop(t, MsgSession); return; }
            CloseLeftovers();                                            // a player left from before: the new one must be the browser's main program
            Rectangle b;
            try { b = System.Windows.Forms.Screen.PrimaryScreen.Bounds; } catch { b = new Rectangle(0, 0, 2560, 1440); }   // the middle race screen (CLAUDE.md: the Windows primary)
            string profile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "player-profile");
            string url = "http://localhost:" + Port.ToString(Inv) + "/v2/player.html?id=" + Uri.EscapeDataString(t.Id);
            // no --use-fake-ui-for-media-stream: real Chrome shows its yellow "unsupported command-line flag" bar for it. The microphone is
            // granted in the player's own profile instead (GrantMic), so Peter still clicks nothing.
            string args = "--user-data-dir=\"" + profile + "\" --no-first-run --no-default-browser-check --hide-crash-restore-bubble --disable-session-crashed-bubble " +
                          "--disable-features=Translate --window-position=" + b.X + "," + b.Y + " --window-size=" + b.Width + "," + b.Height + " --start-fullscreen " +
                          "--autoplay-policy=no-user-gesture-required --app=" + url;
            LastLaunchArgs = args;
            try
            {
                GrantMic(profile);
                if (On() || !Mine(t)) { if (On()) Drop(t, MsgSession); return; }      // the last look before a window appears on his screen
                Process p = Launch != null ? Launch("test", args) : Process.Start(Browser(), args);
                lock (gate) { t.Player = p; t.OpenedMs = Now; }
                Log.W("commentary: player opened for " + t.Id + " on " + b);
            }
            catch (Exception ex) { Fail(t, "Could not open Paddock's player (" + ex.Message + ")"); }
        }

        // The player profile's Default\Preferences says "localhost:<port> may use the microphone" (content setting 1 = allow), merged
        // into what Chrome already wrote there. Written only while no player runs (CloseLeftovers came first). A failure is logged:
        // Chrome then asks once on screen, which is worse but not broken.
        internal static void GrantMic(string profile)
        {
            try
            {
                string dir = Path.Combine(profile, "Default"), file = Path.Combine(dir, "Preferences");
                Directory.CreateDirectory(dir);
                System.Web.Script.Serialization.JavaScriptSerializer js = new System.Web.Script.Serialization.JavaScriptSerializer();
                js.MaxJsonLength = int.MaxValue;
                Dictionary<string, object> root = null;
                if (File.Exists(file)) { try { root = js.DeserializeObject(File.ReadAllText(file, Encoding.UTF8)) as Dictionary<string, object>; } catch { root = null; } }
                if (root == null) root = new Dictionary<string, object>();
                Dictionary<string, object> mic = Child(Child(Child(Child(root, "profile"), "content_settings"), "exceptions"), "media_stream_mic");
                string site = string.Format(Inv, MicSite, Port);
                object cur; Dictionary<string, object> have = mic.TryGetValue(site, out cur) ? cur as Dictionary<string, object> : null;
                if (have != null && Convert.ToString(have.ContainsKey("setting") ? have["setting"] : "", Inv) == "1") return;   // already granted
                Dictionary<string, object> grant = new Dictionary<string, object>(); grant["setting"] = 1;
                mic[site] = grant;
                string tmp = file + ".paddock";
                File.WriteAllText(tmp, js.Serialize(root), new UTF8Encoding(false));
                if (File.Exists(file)) File.Delete(file);
                File.Move(tmp, file);
                Log.W("commentary: the player may use the microphone (" + site + " in player-profile)");
            }
            catch (Exception ex) { Log.W("commentary: could not grant the microphone in the player profile (" + ex.Message + ")"); }
        }
        static Dictionary<string, object> Child(Dictionary<string, object> d, string k)
        {
            object o; Dictionary<string, object> c = d.TryGetValue(k, out o) ? o as Dictionary<string, object> : null;
            if (c == null) { c = new Dictionary<string, object>(); d[k] = c; }
            return c;
        }

        // ================= the player's events (POST /api/talk/event?id=&ev=) =================
        public static string Event(string id, string ev, string mic, out int code)
        {
            code = 200; Talk t;
            lock (gate) { if (!talks.TryGetValue(id ?? "", out t) || !Active(t.Kind)) { code = 409; return "{\"ok\":false}"; } }
            switch (ev)
            {
                case "started":
                    lock (gate) { if (t.Kind == "preparing") { t.Kind = "talking"; t.StartedMs = Now; } t.Mic = Clip(mic); }
                    Log.W("commentary: talking over " + id + " (microphone: " + (t.Mic.Length > 0 ? t.Mic : "no name") + ")");
                    break;
                case "silent": case "loud":
                    bool s = ev == "silent"; bool changed;
                    lock (gate) { changed = t.Silent != s; t.Silent = s; }
                    if (changed) Log.W("commentary: the microphone is " + (s ? "silent (5 s under -50 dB)" : "hearing him again") + " (" + id + ")");
                    if (!changed) return "{\"ok\":true}";
                    break;
                case "nomic": Fail(t, MsgNoMic); CloseSoon(t); break;
                case "cannotplay": Fail(t, MsgCannotPlay); CloseSoon(t); break;
                case "ended": int c; Stop(id, "ended", out c); return "{\"ok\":true}";
                default: code = 400; return "{\"ok\":false}";
            }
            Bump();
            return "{\"ok\":true}";
        }
        static string Clip(string s) { s = (s ?? "").Replace("\r", " ").Replace("\n", " ").Trim(); return s.Length > 80 ? s.Substring(0, 80) : s; }

        // GET /api/talk/state?id=: the player asks once a second while talking ("stop" once STOP was pressed on the deck or the page)
        public static string PlayerState(string id)
        {
            lock (gate)
            {
                Talk t; bool have = talks.TryGetValue(id ?? "", out t);
                bool stop = !have || t.StopAsked || !(t.Kind == "preparing" || t.Kind == "talking");
                return "{\"stop\":" + (stop ? "true" : "false") + ",\"kind\":" + Json_.S(have ? t.Kind : "none") + "}";
            }
        }

        // ================= STOP (racetalkstop: not guarded, it only ends things) =================
        public static string Stop(string id, string why, out int code)
        {
            code = 200; Talk t = null;
            lock (gate)
            {
                if (!string.IsNullOrEmpty(id)) talks.TryGetValue(id, out t);
                else foreach (Talk o in talks.Values) if (o.Kind == "preparing" || o.Kind == "talking") { t = o; break; }   // the deck's STOP: whatever is on
                if (t == null || !(t.Kind == "preparing" || t.Kind == "talking"))
                {
                    if (t != null && t.Kind == "mixing") return Say(true, "Mixing your commentary");
                    code = 409; return Say(false, "Nothing to stop");
                }
                t.StopAsked = true;
                if (t.Kind == "preparing")
                {
                    // nothing was recorded yet: the talk simply ends
                    talks.Remove(t.Id);
                }
                else { t.Kind = "mixing"; t.Secs = (Now - t.StartedMs) / 1000.0; if (why == "session") t.Note = MsgSession; }
            }
            Log.W("commentary: STOP for " + t.Id + (why == "session" ? " - a session started" : why == "ended" ? " - the race video ended" : ""));
            if (!t.VoiceIn && t.StartedMs <= 0) { CloseSoon(t); Bump(); return Say(true, why == "session" ? MsgSession : "Stopped"); }
            WaitThenClose(t);
            Bump();
            return Say(true, why == "session" ? MsgSession : "Mixing your commentary");
        }

        // the player sends what was said within a second of STOP (it polls /api/talk/state); then its window goes
        static void WaitThenClose(Talk t)
        {
            Thread th = new Thread(delegate ()
            {
                Stopwatch sw = Stopwatch.StartNew();
                while (!t.VoiceIn && sw.ElapsedMilliseconds < VoiceWaitMs) Thread.Sleep(100);
                ClosePlayer(t);
                if (!t.VoiceIn)
                {
                    bool mine; lock (gate) { Talk x; mine = talks.TryGetValue(t.Id, out x) && x == t; }
                    if (mine) Fail(t, "Nothing was recorded: the player did not send what you said. Press TALK OVER IT again.");
                }
            });
            th.IsBackground = true; th.Name = "talk stop"; th.Start();
        }
        static void CloseSoon(Talk t) { Thread th = new Thread(delegate () { Thread.Sleep(300); ClosePlayer(t); }); th.IsBackground = true; th.Start(); }

        // ================= the voice (POST /api/talk/voice?id=&D=&secs=&mic=&silent=, the webm as the body) =================
        public static string OnVoice(string id, byte[] voice, double d, double secs, string mic, bool silent, out int code) { return OnVoice(id, voice, d, secs, mic, silent, 0, out code); }
        public static string OnVoice(string id, byte[] voice, double d, double secs, string mic, bool silent, double stall, out int code)
        {
            code = 200; Talk t;
            if (voice == null || voice.Length == 0) { code = 400; return Say(false, "Nothing was recorded"); }
            bool orphan = false;
            lock (gate)
            {
                Talk x; bool have = talks.TryGetValue(id ?? "", out x);
                if (have && x.VoiceIn) { code = 409; return Say(false, "Already have what you said"); }
                if (have && (x.Kind == "talking" || x.Kind == "mixing")) t = x;
                else if (have && x.Kind == "preparing") { code = 409; return Say(false, "Not talking over this race"); }
                else
                {
                    // irdash restarted while he talked (the talk list is empty): the race is still here, so what he said is kept and mixed
                    t = null; orphan = true;
                }
                if (t != null)
                {
                    if (double.IsNaN(d) || Math.Abs(d) > 30) d = 0;          // a clock that went wrong: no shift beats a wild one
                    t.VoiceIn = true; t.StopAsked = true; t.Kind = "mixing"; t.Secs = secs > 0 ? secs : (Now - t.StartedMs) / 1000.0;
                    if (!string.IsNullOrEmpty(mic)) t.Mic = Clip(mic);
                    t.Silent = silent;
                }
            }
            if (orphan)
            {
                RaceInfo r = Library.IdOk(id) ? SessionIndex.Get(id) : null;
                if (r == null || r.InTrash || On()) { code = 409; return Say(false, "Not talking over this race"); }
                if (double.IsNaN(d) || Math.Abs(d) > 30) d = 0;
                lock (gate)
                {
                    t = new Talk(); t.Id = id; t.Kind = "mixing"; t.VoiceIn = true; t.StopAsked = true; t.AskedMs = Now;
                    t.Secs = secs > 0 ? secs : 0; t.Mic = Clip(mic); t.Silent = silent; talks[id] = t;
                }
                Log.W("commentary: a voice for " + id + " with no talk on (irdash restarted while he talked) - kept and mixed");
            }
            if (double.IsNaN(stall) || stall < 0) stall = 0;
            Meta m = new Meta(); m.D = d; m.Secs = t.Secs; m.Mic = t.Mic; m.When = Now; m.Silent = silent; m.HasVoice = true; m.Stall = stall;
            Log.W("commentary: voice in for " + id + " (" + (voice.Length / 1024) + " KB, " + t.Secs.ToString("0", Inv) + " s, D " + d.ToString("0.000", Inv) + " s" +
                  (stall > 0 ? ", the video stood still " + stall.ToString("0.0", Inv) + " s while he talked" : "") + ")");
            // nothing over 1 MB is written in a session (plan rule 2): the voice then waits in memory for the session to end
            if (On()) Jobs.Save("talk voice " + id, delegate { Keep(id, voice, m); });
            else Keep(id, voice, m);
            WaitThenClose(t);         // VoiceIn is set: closes at once
            Bump();
            return Say(true, "Mixing your commentary");
        }

        static void Keep(string id, byte[] voice, Meta m)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                string p = VoicePath(id), tmp = p + ".part";
                File.WriteAllBytes(tmp, voice);
                if (File.Exists(p)) File.Delete(p);
                File.Move(tmp, p);
                WriteMeta(id, m);
                lock (gate) { Load(); metas[id] = m; }
            }
            catch (Exception ex) { Talk t; lock (gate) talks.TryGetValue(id, out t); if (t != null) Fail(t, "Could not keep what you said (" + ex.Message + ")"); return; }
            Jobs.Run("talk mix " + id, delegate { Mix(id); }, true);
        }

        // ================= the mix (Jobs worker, between sessions) =================
        internal static void Mix(string id)
        {
            if (Jobs.ShouldYield) { Jobs.Again("talk mix " + id, delegate { Mix(id); }); return; }
            Meta m; lock (gate) m = MetaOf(id);
            string voice = VoicePath(id), outPath = VideoPath(id), part = Path.Combine(Dir, id + "-commentary.part.mp4");
            if (m == null || !File.Exists(voice)) { MixDone(id, "What you said was not found, so there is nothing to mix"); return; }
            string cut, res = Library.MakeCut(id, out cut);
            if (res == "YIELD") { Jobs.Again("talk mix " + id, delegate { Mix(id); }); return; }
            if (res != "ok") { MixDone(id, res); return; }
            if (Cuts.FreeBytes(Dir) < 3L * 1024 * 1024 * 1024) { MixDone(id, "Not enough space for the commentary video (needs 3 GB free)"); return; }
            try { if (File.Exists(part)) File.Delete(part); } catch { }
            bool hevc = Probe("-v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 \"" + cut + "\"").Trim() == "hevc";
            string args = MixArgs(cut, voice, m.D, part, hevc);
            LastMixArgs = args;
            Stopwatch sw = Stopwatch.StartNew();
            string err; int rc = Ffmpeg(args, 30 * 60 * 1000, out err);
            if (rc == Cuts.Yielded || (rc == -1 && Jobs.ShouldYield)) { TryDelete(part); Log.W("commentary: the mix of " + id + " stopped - a session started; it runs again after it"); Jobs.Again("talk mix " + id, delegate { Mix(id); }); return; }
            if (rc != 0 || !File.Exists(part)) { TryDelete(part); MixDone(id, "The mix did not work (the video tool stopped). Press TALK OVER IT again."); Log.W("commentary: ffmpeg " + rc + ": " + Tail(err)); return; }
            // verified before it counts: two streams, and the SOUND as long as the cut (within 1 s): the file's own length is the
            // video's, so a sound track that stopped early would pass a format-duration check (review W1-6 #1)
            double want = Duration(cut), dur; int streams = Streams(part, out dur);
            double got = AudioDuration(part);
            if (streams != 2 || want <= 0 || Math.Abs(got - want) > 1.0)
            { TryDelete(part); MixDone(id, "The mix came out wrong (" + streams + " streams, sound " + got.ToString("0.0", Inv) + " s of " + want.ToString("0.0", Inv) + " s), so it was not used"); return; }
            try { if (File.Exists(outPath)) File.Delete(outPath); File.Move(part, outPath); }
            catch (Exception ex) { TryDelete(part); MixDone(id, "Could not keep the commentary video (" + ex.Message + ")"); return; }
            m.Mixed = true; m.HasVideo = true; m.HasVoice = false;
            try { m.Bytes = new FileInfo(outPath).Length; WriteMeta(id, m); } catch { }
            TryDelete(voice);         // only now: the mix is verified
            Log.W("commentary: " + id + " mixed in " + sw.Elapsed.TotalSeconds.ToString("0.0", Inv) + " s (" + (m.Bytes / 1048576) + " MB, " + got.ToString("0.0", Inv) + " s, D " + m.D.ToString("0.000", Inv) + " s)");
            MixDone(id, "");
        }
        static void MixDone(string id, string error)
        {
            lock (gate)
            {
                Talk t;
                if (error.Length == 0) talks.Remove(id);        // ready: the files say so from now on
                else
                {
                    if (!talks.TryGetValue(id, out t)) { t = new Talk(); t.Id = id; talks[id] = t; }
                    t.Kind = "failed"; t.Error = error;
                }
            }
            if (error.Length > 0) Log.W("commentary: " + id + " not mixed: " + error);
            Bump();
        }

        static void Fail(Talk t, string error)
        {
            lock (gate) { Talk x; if (talks.TryGetValue(t.Id, out x) && x == t) { t.Kind = "failed"; t.Error = error; t.StopAsked = true; } }
            Log.W("commentary: " + t.Id + ": " + error);
            Bump();
        }
        // a talk that ends with nothing to keep (a session started before he said a word): no red line, just the note
        static void Drop(Talk t, string note)
        {
            lock (gate) { Talk x; if (talks.TryGetValue(t.Id, out x) && x == t) { t.Kind = "failed"; t.Error = ""; t.Note = note; t.StopAsked = true; } }
            Log.W("commentary: " + t.Id + " not started: " + note);
            CloseSoon(t);
            Bump();
        }

        // ================= the player window =================
        static void ClosePlayer(Talk t)
        {
            if (CloseHook != null) { CloseHook(t.Id); return; }
            Process p; lock (gate) { p = t.Player; t.Player = null; }
            try
            {
                if (p != null && !p.HasExited)
                {
                    p.CloseMainWindow();
                    if (!p.WaitForExit(3000)) p.Kill();
                    Log.W("commentary: player closed (" + t.Id + ")");
                }
            }
            catch (Exception ex) { Log.W("commentary: could not close the player (" + ex.Message + ")"); }
            finally { try { if (p != null) p.Dispose(); } catch { } }
            if (!On()) CloseLeftovers();
        }
        // every Chrome/Edge program of the player's own profile (never the dashboard's: that is dash\browser-profile). A process
        // scan, so never in a session.
        static int CloseLeftovers()
        {
            if (Launch != null || CloseHook != null || On()) return 0;
            int killed = 0;
            try
            {
                string prof = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "player-profile");
                using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'chrome.exe' OR Name = 'msedge.exe'"))
                using (ManagementObjectCollection c = s.Get())
                    foreach (ManagementBaseObject o in c)
                        using (o)
                        {
                            string cl = Convert.ToString(o["CommandLine"]);
                            if (cl == null || (cl.IndexOf(prof, StringComparison.OrdinalIgnoreCase) < 0 && cl.IndexOf("/v2/player.html", StringComparison.OrdinalIgnoreCase) < 0)) continue;
                            if (cl.IndexOf("browser-profile", StringComparison.OrdinalIgnoreCase) >= 0) continue;     // never the dashboard
                            // gone before the next start: a dying Chrome still holds the profile ("profile in use", or the new one hands over to it)
                            try { using (Process p = Process.GetProcessById(Convert.ToInt32(o["ProcessId"]))) { p.Kill(); p.WaitForExit(2000); } } catch { }
                            killed++;
                        }
            }
            catch (Exception ex) { Log.W("commentary: could not look for an old player (" + ex.Message + ")"); }
            if (killed > 0) Log.W("commentary: closed " + killed + " program" + (killed == 1 ? "" : "s") + " of an old player");
            return killed;
        }

        // once a second: a session starting while he talks stops it (rule 1); a player that never started or vanished ends the talk
        // The timer runs only while a talk is preparing or talking (review W1-6 #12): started by the press, stopped here when none is.
        static void Watch()
        {
            List<Talk> act = new List<Talk>();
            lock (gate)
            {
                foreach (Talk t in talks.Values) if (t.Kind == "preparing" || t.Kind == "talking") act.Add(t);
                if (act.Count == 0) { if (tick != null) { tick.Dispose(); tick = null; } return; }
            }
            bool on = On();
            foreach (Talk t in act)
            {
                int c;
                if (on) { if (t.Kind == "talking") Stop(t.Id, "session", out c); else Drop(t, MsgSession); continue; }
                bool gone = false; try { gone = t.Player != null && t.Player.HasExited; } catch { }
                // the cut waits behind whatever job runs: past the deadline the player must not pop up minutes after the press
                if (t.Kind == "preparing" && t.OpenedMs <= 0 && Now - t.AskedMs > PrepareWaitMs) Fail(t, MsgBusy);
                else if (t.Kind == "preparing" && t.OpenedMs > 0 && Now - t.OpenedMs > StartWaitMs) { Fail(t, "The player did not start. Press TALK OVER IT again."); CloseSoon(t); }
                else if (gone && !t.VoiceIn) Fail(t, "The player was closed before STOP, so nothing was kept");
            }
        }
        static void EnsureWatch()
        {
            lock (gate) if (tick == null) tick = new Timer(delegate { try { Watch(); } catch (Exception ex) { Log.W("commentary: " + ex.Message); } }, null, 1000, 1000);
        }
        internal static bool Watching { get { lock (gate) return tick != null; } }

        // ================= share, tidy, forget =================
        // Library.TidyCuts: the commentary video is the upload's copy, like the cut: gone once YouTube has it (the voice is long gone)
        internal static void Tidy()
        {
            List<string> ids = new List<string>();
            lock (gate) { Load(); foreach (KeyValuePair<string, Meta> kv in metas) if (kv.Value.HasVideo) ids.Add(kv.Key); }
            foreach (string id in ids)
            {
                if (Jobs.ShouldYield) return;
                string k = KindOf(Yt(id));
                if (k == "queued" || k == "sharing" || Holds(id)) continue;            // YouTube or a talk still needs it
                double days; try { days = (DateTime.UtcNow - File.GetLastWriteTimeUtc(VideoPath(id))).TotalDays; } catch { continue; }
                bool shared = k == "shared", old = days >= TidyDays;
                if (!shared && !old) continue;
                try
                {
                    File.Delete(VideoPath(id));
                    lock (gate) { Meta m = MetaOf(id); if (m != null) { m.HasVideo = false; m.Bytes = 0; } }
                    Log.W("commentary: removed the commentary video of " + id + (shared ? " (it is on YouTube)" : " (not shared in " + TidyDays + " days)"));
                }
                catch { }
            }
        }
        // the race is gone for good: its commentary goes with it (a talk still on over it is ended first: its window closes)
        internal static void Forget(string id)
        {
            if (!Library.IdOk(id)) return;
            Talk t; lock (gate) talks.TryGetValue(id, out t);
            if (t != null && Active(t.Kind)) { lock (gate) t.StopAsked = true; ClosePlayer(t); }
            foreach (string f in new string[] { VideoPath(id), VoicePath(id), MetaPath(id) }) TryDelete(f);
            lock (gate) { Load(); metas.Remove(id); talks.Remove(id); }
        }

        // ================= HTTP (irdash.cs routes /api/library/video and /api/talk/*) =================
        public static bool Route(NetworkStream s, string method, string path, Dictionary<string, string> q, Dictionary<string, string> hdr)
        {
            string id = Q(q, "id");
            if (method == "GET" && path == "/api/library/video")
            {
                // the player's video: the race's cut (cut=1) or the whole recording, with Range so the browser can buffer
                string file = null;
                if (Library.IdOk(id))
                {
                    if (Q(q, "cut") == "1") file = Library.CutFile(id);
                    else { RaceInfo r = SessionIndex.Get(id); if (r != null) file = r.File; }
                }
                return Vault.ServeMp4(s, file, hdr);
            }
            if (method == "GET" && path == "/api/talk/state") { Reply(s, 200, PlayerState(id)); return true; }
            if (method == "POST" && path == "/api/talk/event") { int c; string j = Event(id, Q(q, "ev"), Q(q, "mic"), out c); Reply(s, c, j); return true; }
            if (method == "POST" && path == "/api/talk/voice")
            {
                string cl; hdr.TryGetValue("Content-Length", out cl); long len;
                if (!long.TryParse((cl ?? "").Trim(), NumberStyles.Integer, Inv, out len) || len <= 0 || len > VoiceMaxBytes) { Reply(s, 400, Say(false, "Nothing was recorded")); return true; }
                byte[] body = new byte[len]; int got = 0;
                try { while (got < len) { int n = s.Read(body, got, (int)Math.Min(256 * 1024, len - got)); if (n <= 0) break; got += n; } } catch (IOException) { }
                if (got < len) { Log.W("commentary: the voice of " + id + " came in short (" + got + " of " + len + " bytes)"); Reply(s, 400, Say(false, "What you said did not arrive whole")); return true; }
                double d = Dbl(Q(q, "D")), secs = Dbl(Q(q, "secs"));
                double stall = Dbl(Q(q, "stall")); if (double.IsNaN(stall)) stall = 0;
                int c; string j = OnVoice(id, body, d, secs, Q(q, "mic"), Q(q, "silent") == "1" || Q(q, "silent") == "true", stall, out c);
                Reply(s, c, j); return true;
            }
            return false;
        }
        static string Q(Dictionary<string, string> q, string k) { string v; return q != null && q.TryGetValue(k, out v) ? (v ?? "") : ""; }
        static double Dbl(string s) { double v; return double.TryParse(s, NumberStyles.Float, Inv, out v) ? v : double.NaN; }
        static void Reply(NetworkStream s, int code, string json)
        {
            byte[] body = Encoding.UTF8.GetBytes(json);
            string head = "HTTP/1.1 " + code + (code == 200 ? " OK" : " Error") + "\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: " + body.Length +
                          "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
            byte[] hb = Encoding.ASCII.GetBytes(head);
            s.Write(hb, 0, hb.Length); s.Write(body, 0, body.Length); s.Flush();
        }

        // ================= tools =================
        static int Ffmpeg(string args, int timeoutMs, out string err)
        {
            if (FfmpegPath != null) { return Exec(FfmpegPath, args, timeoutMs, true, out err); }
            int rc = Recorder.LibFfmpeg(args, timeoutMs, out err);      // BelowNormal, very low disk priority, stopped when a session starts
            if (rc == -1 && ((err ?? "").StartsWith("stopped", StringComparison.Ordinal) || Jobs.ShouldYield)) return Cuts.Yielded;
            return rc;
        }
        static string Probe(string args)
        {
            string exe = FfprobePath ?? Recorder.FfprobeExe, o;
            return Exec(exe, args, 60000, false, out o) == 0 ? o : "";
        }
        static double Duration(string file)
        {
            double v; string o = Probe("-v error -show_entries format=duration -of default=nw=1:nk=1 \"" + file + "\"").Trim();
            return double.TryParse(o.Split('\n')[0].Trim(), NumberStyles.Float, Inv, out v) ? v : 0;
        }
        static double AudioDuration(string file)
        {
            double v; string o = Probe("-v error -select_streams a:0 -show_entries stream=duration -of default=nw=1:nk=1 \"" + file + "\"").Trim();
            return double.TryParse(o.Split('\n')[0].Trim(), NumberStyles.Float, Inv, out v) ? v : 0;
        }
        static int Streams(string file, out double dur)
        {
            string o = Probe("-v error -show_entries format=duration:stream=codec_type -of default=nw=1 \"" + file + "\"");
            int n = 0; bool v = false, a = false; dur = 0;
            foreach (string raw in o.Split('\n'))
            {
                string l = raw.Trim();
                if (l == "codec_type=video") { n++; v = true; } else if (l == "codec_type=audio") { n++; a = true; }
                else if (l.StartsWith("duration=")) double.TryParse(l.Substring(9), NumberStyles.Float, Inv, out dur);
            }
            return v && a ? n : 0;
        }
        static int Exec(string exe, string args, int timeoutMs, bool stderr, out string text)
        {
            text = "";
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exe, args);
                psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
                StringBuilder o = new StringBuilder(), e = new StringBuilder();
                using (Process p = Process.Start(psi))
                {
                    try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
                    try { Jobs.LowerChild(p); } catch { }
                    p.OutputDataReceived += delegate (object x, DataReceivedEventArgs a) { if (a.Data != null) lock (o) o.AppendLine(a.Data); };
                    p.ErrorDataReceived += delegate (object x, DataReceivedEventArgs a) { if (a.Data != null) lock (e) { e.AppendLine(a.Data); if (e.Length > 4000) e.Remove(0, e.Length - 2000); } };
                    p.BeginOutputReadLine(); p.BeginErrorReadLine();
                    if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } text = "timeout"; return -1; }
                    p.WaitForExit();
                    lock (o) lock (e) text = stderr ? e.ToString() : o.ToString();
                    return p.ExitCode;
                }
            }
            catch (Exception ex) { text = ex.Message; return -3; }
        }
        static string Tail(string s) { s = (s ?? "").Trim(); return s.Length > 300 ? s.Substring(s.Length - 300) : s; }
        static void TryDelete(string f) { try { if (File.Exists(f)) File.Delete(f); } catch { } }

        // ================= start =================
        static Timer tick;
        public static void Start()
        {
            lock (gate) { if (started) return; started = true; }
            // a voice kept but not mixed (irdash closed in between): mixed after the next session, or now
            List<string> again = new List<string>();
            lock (gate) { Load(); foreach (KeyValuePair<string, Meta> kv in metas) if (kv.Value.HasVoice && !kv.Value.Mixed) again.Add(kv.Key); }
            foreach (string id in again) { string x = id; Jobs.Run("talk mix " + x, delegate { Mix(x); }, true); }
            if (again.Count > 0) Log.W("commentary: " + again.Count + " commentary mix" + (again.Count == 1 ? "" : "es") + " still to do after a restart");
            // a player left open by an irdash that closed mid-talk: it asks /api/talk/state, hears "stop" (no talk) and sends what was
            // said within a second or two (OnVoice keeps it). After a grace it is closed if it is still there (review W1-6 #2).
            Thread th = new Thread(delegate ()
            {
                Thread.Sleep(LeftoverGraceMs);
                bool any; lock (gate) { any = false; foreach (Talk t in talks.Values) if (t.Kind == "preparing" || t.Kind == "talking") any = true; }
                if (!any && !On()) CloseLeftovers();
            });
            th.IsBackground = true; th.Name = "talk leftovers"; th.Start();
        }
        static bool started;
    }
}
