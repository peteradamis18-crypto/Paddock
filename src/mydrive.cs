// irdeck My Drive (the MY DRIVE screen on the Stream Deck): pick a car and track from your recent drives, your favourites
// or a search of iRacing's own lists, then START = Test Drive set up, launched, and into the car. Everything lives in
// <root>\mydrive: state.ini (the choice, progress, last start time), favourites.ini (edit by hand if you like),
// results.json (the last search, 7 at most). Recent drives come from dash\career-cache.tsv (read only).
//   mydrive show                           print the choice, recent drives and favourites
//   mydrive pick <id>                      choose a recent (r...), favourite (f...) or search result (s...)
//   mydrive set "<car>" "<track>" ["<layout>"]   choose by name
//   mydrive star                           add / remove the star: the combo you are driving now, else the chosen one
//   mydrive damage [on|off]                car damage for the next start (no word = flip)
//   mydrive find car|track "<text>"        look it up in iRacing's Test Drive lists -> results.json
//   mydrive find layout                    the layouts iRacing offers for the chosen track -> results.json
//   mydrive clear                          forget the last search
//   mydrive start [--at <utcTicks>]        Test Drive set up with the choice, launched, wait for the session, into the car
// Only the Test Drive dialog is ever clicked, and only after it is verified on screen (testdrive.cs); nothing here
// touches iRacing's own files.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDeck
{
    static partial class Program
    {
        sealed class MdCombo { public string Car = "", Track = "", Layout = "", File = ""; public DateTime When; }

        static string MdDir { get { return Path.Combine(Root, "mydrive"); } }
        static string MdPath(string name) { return Path.Combine(MdDir, name); }

        // short stable id for a pick: r = recent drive, f = favourite, s = search result (same hash in irdash\src\mydrive.cs)
        static string MdId(char kind, string text)
        {
            uint h = 2166136261u;
            foreach (char c in (text ?? "").ToLowerInvariant()) { h ^= c; h = unchecked(h * 16777619u); }
            return kind + h.ToString("x8", CultureInfo.InvariantCulture);
        }

        static bool MdSame(MdCombo a, MdCombo b)
        {
            return string.Equals(a.Car.Trim(), b.Car.Trim(), StringComparison.OrdinalIgnoreCase) && string.Equals(a.Track.Trim(), b.Track.Trim(), StringComparison.OrdinalIgnoreCase)
                && string.Equals(a.Layout.Trim(), b.Layout.Trim(), StringComparison.OrdinalIgnoreCase);
        }

        // ---- files ----
        static void MdWrite(string name, string content)
        {
            Directory.CreateDirectory(MdDir);
            string f = MdPath(name), tmp = f + ".tmp";
            File.WriteAllText(tmp, content, new UTF8Encoding(false));
            try { if (File.Exists(f)) File.Replace(tmp, f, null); else File.Move(tmp, f); }
            catch { try { File.Copy(tmp, f, true); File.Delete(tmp); } catch { } }   // a reader had it open: plain copy
        }

        static Dictionary<string, string> MdState()
        {
            var st = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string f = MdPath("state.ini");
                if (File.Exists(f)) foreach (string l in File.ReadAllLines(f)) { int e = l.IndexOf('='); if (e > 0) st[l.Substring(0, e)] = l.Substring(e + 1); }
            }
            catch { }
            return st;
        }

        // read, change, write - one writer at a time (a pick can arrive while a start is updating its progress)
        static void MdUpdate(Action<Dictionary<string, string>> change)
        {
            Mutex mx = new Mutex(false, "Local\\irdeck-mydrive");
            try { mx.WaitOne(5000); } catch (AbandonedMutexException) { }
            try
            {
                var st = MdState(); change(st);
                StringBuilder sb = new StringBuilder();
                foreach (KeyValuePair<string, string> kv in st) sb.Append(kv.Key).Append('=').Append((kv.Value ?? "").Replace('\r', ' ').Replace('\n', ' ')).Append("\r\n");
                MdWrite("state.ini", sb.ToString());
            }
            finally { try { mx.ReleaseMutex(); } catch { } mx.Dispose(); }
        }

        static void MdPhase(string phase, string msg)
        {
            MdUpdate(delegate (Dictionary<string, string> st) { st["phase"] = phase; st["msg"] = msg; st["phaseAt"] = DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture); });
        }

        static MdCombo MdChosen()
        {
            var st = MdState(); MdCombo c = new MdCombo();
            c.Car = Sv(st, "car", ""); c.Track = Sv(st, "track", ""); c.Layout = Sv(st, "layout", "");
            return c;
        }

        // favourites.ini: car | track | layout, newest first
        static List<MdCombo> MdFavs()
        {
            var list = new List<MdCombo>();
            try
            {
                string f = MdPath("favourites.ini");
                if (!File.Exists(f)) return list;
                foreach (string raw in File.ReadAllLines(f))
                {
                    string l = raw.Trim();
                    if (l.Length == 0 || l.StartsWith(";") || l.StartsWith("#")) continue;
                    string[] p = l.Split('|');
                    if (p.Length < 2) continue;
                    MdCombo c = new MdCombo(); c.Car = p[0].Trim(); c.Track = p[1].Trim(); c.Layout = p.Length > 2 ? p[2].Trim() : "";
                    if (c.Car.Length > 0 && c.Track.Length > 0) list.Add(c);
                }
            }
            catch { }
            return list;
        }

        static void MdSaveFavs(List<MdCombo> list)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("; My Drive favourites. One per line:  car | track | layout   (layout can be empty = the first one iRacing offers).\r\n");
            sb.Append("; The star key on the deck adds and removes lines here, newest first. You can edit this file with Notepad too.\r\n");
            foreach (MdCombo c in list) sb.Append(c.Car).Append(" | ").Append(c.Track).Append(" | ").Append(c.Layout).Append("\r\n");
            MdWrite("favourites.ini", sb.ToString());
        }

        // last distinct car + track pairs you drove for at least 30 s, newest first (dash\career-cache.tsv, read only)
        static List<MdCombo> MdRecents(int max)
        {
            var map = new Dictionary<string, MdCombo>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string f = Path.Combine(Root, @"dash\career-cache.tsv");
                if (File.Exists(f))
                    using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (var sr = new StreamReader(fs, Encoding.UTF8))
                    {
                        string line;
                        while ((line = sr.ReadLine()) != null)
                        {
                            string[] p = line.Split('\t');
                            if (p.Length < 13) continue;
                            double secs; long ticks;
                            if (!double.TryParse(p[2], NumberStyles.Float, CultureInfo.InvariantCulture, out secs) || secs < 30 || !long.TryParse(p[1], out ticks)) continue;
                            string car = p[6].Trim(), track = p[7].Trim();
                            if (car.Length == 0 || track.Length == 0) continue;
                            DateTime when = new DateTime(ticks, DateTimeKind.Utc); MdCombo c;
                            if (!map.TryGetValue(car + "|" + track, out c)) { c = new MdCombo(); c.Car = car; c.Track = track; c.When = when; c.File = p[0]; map[car + "|" + track] = c; }
                            else if (when > c.When) { c.When = when; c.File = p[0]; }
                        }
                    }
            }
            catch (Exception ex) { Log("mydrive: cannot read the career cache: " + ex.Message); }
            var list = new List<MdCombo>(map.Values);
            list.Sort(delegate (MdCombo x, MdCombo y) { return y.When.CompareTo(x.When); });
            return list.Count > max ? list.GetRange(0, max) : list;
        }

        static string MdYaml(string yaml, string key)
        {
            Match m = Regex.Match(yaml, "^[ \\t]*" + key + ":[ \\t]*([^\\r\\n]*?)[ \\t]*$", RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value.Trim('"') : "";
        }

        // the layout (TrackConfigName) you drove that recent combo on, read from the header of its telemetry file
        static string MdLayoutOf(MdCombo c)
        {
            try
            {
                string name = c.File.Split('|')[0];
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), @"iRacing\telemetry\" + name);
                if (name.Length == 0 || !File.Exists(path)) return "";
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    byte[] h = new byte[32];
                    if (fs.Read(h, 0, 32) < 32) return "";
                    int len = BitConverter.ToInt32(h, 16), off = BitConverter.ToInt32(h, 20);
                    if (len <= 0 || len > 4000000 || off <= 0) return "";
                    byte[] y = new byte[len]; fs.Position = off;
                    int n = fs.Read(y, 0, len);
                    return MdYaml(Encoding.GetEncoding(28591).GetString(y, 0, n), "TrackConfigName");
                }
            }
            catch { return ""; }
        }

        // the combo of the session that is running now (null = none)
        static MdCombo MdCurrent()
        {
            Tele t = Tele.Open(); if (t == null) return null;
            string y; using (t) { y = t.SessionInfo(); }
            if (string.IsNullOrEmpty(y)) return null;
            MdCombo c = new MdCombo();
            c.Track = MdYaml(y, "TrackDisplayName"); c.Layout = MdYaml(y, "TrackConfigName");
            string me = MdYaml(y, "DriverCarIdx");
            Match block = Regex.Match(y, "- CarIdx: " + Regex.Escape(me) + "\\s*\\n(.*?)(?=\\n\\s*- CarIdx:|\\n\\S|$)", RegexOptions.Singleline);
            if (me.Length > 0 && block.Success) c.Car = MdYaml(block.Groups[1].Value, "CarScreenName");
            return c.Car.Length > 0 && c.Track.Length > 0 ? c : null;
        }

        // ---- the command ----
        static int CmdMyDrive(string[] a)
        {
            if (a.Length == 0) { Log("mydrive: need show|pick|set|star|damage|find|clear|start"); return 1; }
            Directory.CreateDirectory(MdDir);
            string sub = a[0].ToLowerInvariant();
            switch (sub)
            {
                case "show": return MdShow();
                case "pick": return MdPick(a.Length > 1 ? a[1] : "");
                case "set":
                    if (a.Length < 3) { Log("mydrive set: need \"car\" \"track\" [\"layout\"]"); return 1; }
                    MdUpdate(delegate (Dictionary<string, string> st) { st["car"] = a[1]; st["track"] = a[2]; st["layout"] = a.Length > 3 ? a[3] : ""; });
                    MdClearResults();
                    Log("mydrive: chose " + a[1] + " at " + a[2] + (a.Length > 3 && a[3] != "" ? " (" + a[3] + ")" : ""));
                    return 0;
                case "star": return MdStar();
                case "damage":
                    {
                        string want = a.Length > 1 ? a[1].ToLowerInvariant() : "";
                        MdUpdate(delegate (Dictionary<string, string> st)
                        {
                            bool on = Sv(st, "damage", "on") == "on";
                            st["damage"] = want == "on" ? "on" : want == "off" ? "off" : on ? "off" : "on";
                            Log("mydrive: car damage " + st["damage"]);
                        });
                        return 0;
                    }
                case "find": return MdFind(a);
                case "clear":
                    MdUpdate(delegate (Dictionary<string, string> st) { st["car"] = ""; st["track"] = ""; st["layout"] = ""; });
                    MdClearResults();
                    Log("mydrive: choices cleared");
                    return 0;
                case "start": return MdStart(a);
            }
            Log("mydrive: unknown '" + sub + "'");
            return 1;
        }

        static int MdShow()
        {
            MdCombo c = MdChosen();
            Log("mydrive: chosen " + (c.Car == "" ? "(nothing)" : c.Car + " at " + c.Track + (c.Layout != "" ? " (" + c.Layout + ")" : "")) + ", damage " + Sv(MdState(), "damage", "on"));
            foreach (MdCombo r in MdRecents(7)) Log("mydrive: recent " + MdId('r', r.Car + "|" + r.Track) + "  " + r.Car + " at " + r.Track + "  (" + r.When.ToLocalTime().ToString("MM-dd HH:mm") + ")");
            foreach (MdCombo f in MdFavs()) Log("mydrive: favourite " + MdId('f', f.Car + "|" + f.Track + "|" + f.Layout) + "  " + f.Car + " at " + f.Track + (f.Layout != "" ? " (" + f.Layout + ")" : ""));
            return 0;
        }

        static void MdClearResults() { try { if (File.Exists(MdPath("results.json"))) File.Delete(MdPath("results.json")); } catch { } }
        static void MdClearAiStatus() { try { string f = MdPath("ai-status.txt"); if (File.Exists(f)) File.Delete(f); } catch { } }

        static int MdPick(string id)
        {
            if (!Regex.IsMatch(id ?? "", "^[rc tlfs][0-9a-f]{8}$".Replace(" ", ""))) { Log("mydrive pick: not a valid id"); return 1; }
            if (id[0] == 'c' || id[0] == 't')
            {
                foreach (MdCombo r in MdRecents(200))
                {
                    string name = id[0] == 'c' ? r.Car : r.Track;
                    if (MdId(id[0], name) != id) continue;
                    MdUpdate(delegate (Dictionary<string, string> st)
                    {
                        if (id[0] == 'c') { st["car"] = r.Car; st["track"] = ""; st["layout"] = ""; }
                        else { st["track"] = r.Track; st["layout"] = ""; }
                    });
                    MdClearResults();
                    MdClearAiStatus();
                    Log("mydrive: chose " + (id[0] == 'c' ? "car " + r.Car : "track " + r.Track));
                    return 0;
                }
            }
            if (id[0] == 'l')
            {
                MdCombo chosen = MdChosen(); string cf = Path.Combine(Root, @"dash\career-cache.tsv");
                try
                {
                    if (chosen.Track.Length > 0 && File.Exists(cf))
                    foreach (string line in File.ReadAllLines(cf))
                    {
                        string[] p = line.Split('\t');
                        if (p.Length >= 16 && string.Equals(p[7], chosen.Track, StringComparison.OrdinalIgnoreCase) && MdId('l', p[7] + "|" + p[15]) == id)
                        {
                            string layout = p[15]; MdUpdate(delegate (Dictionary<string, string> st) { st["layout"] = layout; });
                            MdClearResults(); MdClearAiStatus(); Log("mydrive: chose layout " + layout); return 0;
                        }
                    }
                }
                catch { }
            }
            if (id[0] == 'r')
            {
                foreach (MdCombo r in MdRecents(200))   // not only the 7 on the old row: USUAL, SAME CAR and SAME TRACK pick from every drive (dash\src\mydrive.cs "all")
                    if (MdId('r', r.Car + "|" + r.Track) == id)
                    {
                        string lay = MdLayoutOf(r);
                        MdUpdate(delegate (Dictionary<string, string> st) { st["car"] = r.Car; st["track"] = r.Track; st["layout"] = lay; });
                        MdClearResults();
                        MdClearAiStatus();
                        Log("mydrive: chose recent " + r.Car + " at " + r.Track + (lay != "" ? " (" + lay + ")" : ""));
                        return 0;
                    }
            }
            else if (id[0] == 'f')
            {
                foreach (MdCombo f in MdFavs())
                    if (MdId('f', f.Car + "|" + f.Track + "|" + f.Layout) == id)
                    {
                        MdUpdate(delegate (Dictionary<string, string> st) { st["car"] = f.Car; st["track"] = f.Track; st["layout"] = f.Layout; });
                        MdClearResults();
                        MdClearAiStatus();
                        Log("mydrive: chose favourite " + f.Car + " at " + f.Track + (f.Layout != "" ? " (" + f.Layout + ")" : ""));
                        return 0;
                    }
            }
            else
            {
                string kind = "", name = null;
                try
                {
                    Dictionary<string, object> res = Js().DeserializeObject(File.ReadAllText(MdPath("results.json"))) as Dictionary<string, object>;
                    kind = Convert.ToString(res["kind"]);
                    foreach (object o in (IList)res["items"])
                    {
                        Dictionary<string, object> it = o as Dictionary<string, object>;
                        if (it != null && Convert.ToString(it["id"]) == id) { name = Convert.ToString(it["name"]); break; }
                    }
                }
                catch { }
                if (name != null)
                {
                    MdUpdate(delegate (Dictionary<string, string> st)
                    {
                        if (kind == "car") st["car"] = name;
                        else if (kind == "track") { st["track"] = name; st["layout"] = ""; }
                        else if (kind == "layout") st["layout"] = name;
                    });
                    MdClearResults();
                    MdClearAiStatus();
                    Log("mydrive: chose " + kind + " " + name);
                    return 0;
                }
            }
            Log("mydrive pick: " + id + " is not on the screen any more");
            return 1;
        }

        static int MdStar()
        {
            MdCombo c = MdCurrent();
            string from = "driving";
            if (c == null) { c = MdChosen(); from = "chosen"; }
            if (c.Car.Length == 0 || c.Track.Length == 0) { Log("mydrive star: choose a car and track first"); return 1; }
            Mutex mx = new Mutex(false, "Local\\irdeck-mydrive-favs");
            try { mx.WaitOne(5000); } catch (AbandonedMutexException) { }
            try
            {
                List<MdCombo> favs = MdFavs();
                int i = favs.FindIndex(delegate (MdCombo x) { return MdSame(x, c); });
                if (i >= 0) { favs.RemoveAt(i); Log("mydrive: star removed from the " + from + " combo " + c.Car + " at " + c.Track); }
                else { favs.Insert(0, c); Log("mydrive: starred the " + from + " combo " + c.Car + " at " + c.Track + (c.Layout != "" ? " (" + c.Layout + ")" : "")); }
                MdSaveFavs(favs);
            }
            finally { try { mx.ReleaseMutex(); } catch { } mx.Dispose(); }
            return 0;
        }

        // ---- search iRacing's own lists (UI automation, out of the car only) ----
        static int MdFind(string[] a)
        {
            if (a.Length < 2 || (a[1] != "car" && a[1] != "track" && a[1] != "layout")) { Log("mydrive find: car \"text\" | track \"text\" | layout"); return 1; }
            string kind = a[1], text = a.Length > 2 ? a[2].Trim() : "";
            if (kind != "layout" && !Regex.IsMatch(text, "^[A-Za-z0-9 -]{1,24}$")) { Log("mydrive find: type 1 to 24 letters or digits"); return 1; }
            string track = MdChosen().Track;
            if (kind == "layout") { if (track.Length == 0) { Log("mydrive find: choose a track first"); return 1; } text = track; }
            Mutex ui = new Mutex(false, "Local\\irdeck-mydrive-ui");
            bool got = false;
            try { got = ui.WaitOne(8000); } catch (AbandonedMutexException) { got = true; }
            if (!got) { Log("mydrive find: another My Drive step is still using iRacing"); ui.Dispose(); return 3; }
            try
            {
                MdClearResults();
                DateTime t0 = DateTime.Now;
                List<string> rows = kind == "layout" ? TdLayouts(track, 7) : TdLookup(kind, text, 7);
                var items = new List<object>();
                if (rows != null) foreach (string n in rows) { var d = new Dictionary<string, object>(); d["id"] = MdId('s', kind + "|" + n); d["name"] = n; items.Add(d); }
                var res = new Dictionary<string, object>();
                res["kind"] = kind; res["q"] = text; res["at"] = DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture);
                res["ok"] = rows != null; res["msg"] = rows == null ? TdWhy : (rows.Count == 0 ? (kind == "layout" ? "That track has only one layout." : "Nothing found.") : "");
                res["items"] = items;
                MdWrite("results.json", Js().Serialize(res));
                Log("mydrive: " + (rows == null ? "search failed - " + TdWhy : kind + " '" + text + "': " + rows.Count + " found in " + (DateTime.Now - t0).TotalSeconds.ToString("0.0", CultureInfo.InvariantCulture) + " s"));
                return rows == null ? 1 : 0;
            }
            finally { try { ui.ReleaseMutex(); } catch { } ui.Dispose(); }
        }

        // ---- START ----
        static int MdStart(string[] a)
        {
            // the press time comes from irdash (--at <utc ticks>) so queue time counts; without it, now
            DateTime pressed = DateTime.UtcNow;
            for (int i = 1; i < a.Length - 1; i++)
                if (a[i] == "--at") { long t; if (long.TryParse(a[i + 1], out t) && t > DateTime.UtcNow.AddMinutes(-10).Ticks && t <= DateTime.UtcNow.Ticks) pressed = new DateTime(t, DateTimeKind.Utc); }
            MdCombo c = MdChosen();
            if (c.Car.Length == 0 || c.Track.Length == 0)
            {
                MdPhase("failed", "CHOOSE TRACK"); Log("mydrive start: choose a car and track first"); return 1;
            }
            if (SessionActive())
            {
                // already in a session: START just gets you in the car
                if (OnTrack()) { Log("mydrive start: you are already in the car"); return 0; }
                MdPhase("joining", "Getting in the car");
                int grc = CmdGo();
                MdPhase(grc == 0 ? "done" : "failed", grc == 0 ? "" : "Couldn't get in the car.");
                return grc;
            }
            Mutex ui = new Mutex(false, "Local\\irdeck-mydrive-ui");
            bool got = false;
            try { got = ui.WaitOne(8000); } catch (AbandonedMutexException) { got = true; }
            if (!got) { Log("mydrive start: another My Drive step is still using iRacing"); ui.Dispose(); return 3; }
            try
            {
                var st0 = MdState();
                bool damageOn = Sv(st0, "damage", "on") == "on";
                try { File.WriteAllText(Path.Combine(Root, @"dash\start-mark.txt"), pressed.Ticks + "\t" + MarkLabel("mydrive start")); } catch { }   // irdash times START -> session -> in the car (dash\timings.tsv)
                MdPhase("setup", "Setting up " + c.Car + " at " + c.Track);
                Log("mydrive: START " + c.Car + " at " + c.Track + (c.Layout != "" ? " (" + c.Layout + ")" : "") + ", damage " + (damageOn ? "on" : "off"));
                var args = new List<string> { c.Car, c.Track };
                if (c.Layout != "") args.Add(c.Layout);
                args.Add(damageOn ? "--damage-on" : "--damage-off");
                args.Add("--launch");
                int rc = CmdTdSetup(args.ToArray());
                if (rc != 0) { MdPhase("failed", TdWhy.Length > 0 ? TdWhy : "iRacing didn't take it."); return rc; }
                MdPhase("loading", "iRacing is loading the session");
                for (int i = 0; i < 480 && !SessionActive(); i++) Thread.Sleep(500);   // the sim can take a few minutes to load
                if (!SessionActive()) { MdPhase("failed", "The session didn't load - look at the iRacing screen."); Log("mydrive: the session did not load"); return 1; }
                MdPhase("joining", "Getting in the car");
                Thread.Sleep(3000);
                rc = CmdGo();
                if (rc != 0) { MdPhase("failed", "Loaded, but couldn't get in the car."); return rc; }
                double secs = Math.Round((DateTime.UtcNow - pressed).TotalSeconds);
                MdUpdate(delegate (Dictionary<string, string> st)
                {
                    st["phase"] = "done"; st["msg"] = "";
                    st["lastSecs"] = secs.ToString("0", CultureInfo.InvariantCulture); st["lastAt"] = DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture);
                    st["lastCar"] = c.Car; st["lastTrack"] = c.Track;
                    int n; int.TryParse(Sv(st, "lastSeq", "0"), out n); st["lastSeq"] = (n + 1).ToString(CultureInfo.InvariantCulture);
                });
                Log("mydrive: START -> in the car in " + secs.ToString("0", CultureInfo.InvariantCulture) + " s");
                return 0;
            }
            finally { try { ui.ReleaseMutex(); } catch { } ui.Dispose(); }
        }
    }
}
