// irdeck official racing (WS8, docs\official.md). The home screen's "Race weekend" panel and the OFFICIAL deck screen get
// their data from irdash (/official: iRacing's published season schedule + what is installed); these commands are the
// hands-on side. Nothing here registers, joins, withdraws or pays: SPEC WS8 R6.
//   official list                         print what irdash would show: today / Saturday / Sunday
//   official fav <series id | name>       star or un-star a series (data\official\favourites.ini)
//   official scan owned                   check with iRacing's own Set Car / Set Track lists which installed cars and
//                                         tracks really are yours (data\official\owned-ui.json); out of the car, sim closed
//   official map                          open iRacing's Official page and write every element it shows to
//                                         docs\iracing-ui-map.raw.txt (read only; one sidebar click to get there)
//   official register --dry <series id>   open the Official page, find that series and say which Register / Join controls
//                                         are on its row. Never clicks them.
// UI rules are the Test Drive ones (testdrive.cs): only after the iRacing window is verified, never while a session runs,
// and always under the same lock as My Drive so two steps never fight over the mouse.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Automation;

namespace IRDeck
{
    static partial class Program
    {
        static string OfDir { get { return Path.Combine(Root, @"data\official"); } }

        // Live irdeck sits next to dash\irdash.ini. official=1 is the only ON. A copied exe with no ini (the offline
        // test) keeps the commands, so that test can still write a favourites file without touching iRacing.
        static bool OfSwitchOn()
        {
            string f = Path.Combine(Root, @"dash\irdash.ini");
            if (!File.Exists(f)) return true;
            try
            {
                foreach (string raw in File.ReadAllLines(f))
                {
                    string l = raw.Trim();
                    if (l.Length == 0 || l[0] == ';' || l[0] == '#') continue;
                    int e = l.IndexOf('='); if (e <= 0) continue;
                    if (string.Equals(l.Substring(0, e).Trim(), "official", StringComparison.OrdinalIgnoreCase) && l.Substring(e + 1).Trim() == "1") return true;
                }
            }
            catch { return false; }
            return false;
        }

        static int CmdOfficial(string[] a)
        {
            if (!OfSwitchOn()) { Log("official: switched off (official=0 in dash\\irdash.ini)"); return 1; }
            // The OFFICIAL key on the deck runs plain `official` (keys.map). It used to print this usage line and return 1 = a beep and
            // nothing else, so the key was dead. Plain `official` now opens iRacing's Official page (same press OfMap uses), never in a session.
            if (a.Length == 0)
            {
                if (SessionActive()) { Log("official: a session is running - not touching iRacing"); return 3; }
                return CmdNav(new string[] { "--button", "Official" });
            }
            switch (a[0].ToLowerInvariant())
            {
                case "list": return OfList();
                case "fav": return OfFav(a.Length > 1 ? a[1] : "");
                case "scan": return a.Length > 1 && a[1].ToLowerInvariant() == "owned" ? OfScanOwned() : 1;
                case "map": return OfMap(null);
                case "register":
                    {
                        bool dry = Array.IndexOf(a, "--dry") >= 0;
                        string id = ""; foreach (string t in a) if (Regex.IsMatch(t, "^o[0-9a-f]{8}$")) id = t;
                        if (!dry) { Log("official register: only --dry is built (no registering without Peter pressing a key, and that key is not built yet)"); return 1; }
                        if (id.Length == 0) { Log("official register --dry: give the series id (oXXXXXXXX, see 'official list')"); return 1; }
                        return OfMap(id);
                    }
            }
            Log("official: unknown '" + a[0] + "'");
            return 1;
        }

        static string OfNorm(string s)
        {
            StringBuilder sb = new StringBuilder();
            foreach (char c in (s ?? "").Normalize(NormalizationForm.FormD).ToLowerInvariant()) if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) sb.Append(c);
            return sb.ToString();
        }

        static Dictionary<string, object> OfGet(string path)
        {
            using (WebClient wc = new WebClient())
            {
                wc.Encoding = Encoding.UTF8;
                return Js().DeserializeObject(wc.DownloadString("http://127.0.0.1:8199" + path)) as Dictionary<string, object>;
            }
        }
        static string OfS(Dictionary<string, object> d, string k) { object o; return d != null && d.TryGetValue(k, out o) && o != null ? Convert.ToString(o, CultureInfo.InvariantCulture) : ""; }

        // ---- list ----
        static int OfList()
        {
            Dictionary<string, object> d;
            try { d = OfGet("/official"); }
            catch (Exception ex) { Log("official list: irdash is not answering (" + ex.Message + ")"); return 1; }
            if (OfS(d, "loaded") != "True") { Log("official list: " + (OfS(d, "msg").Length > 0 ? OfS(d, "msg") : "nothing loaded yet")); return 1; }
            Log("official: season " + OfS((Dictionary<string, object>)d["season"], "name") + ", licences road " + OfS((Dictionary<string, object>)d["licence"], "road") + " (oval and dirt are assumed Rookie unless profile.ini says otherwise)");
            foreach (object o in (IList)d["days"])
            {
                Dictionary<string, object> day = (Dictionary<string, object>)o;
                Log("official: " + OfS(day, "label").ToUpperInvariant() + " " + OfS(day, "date") + " - " + OfS(day, "total") + " series");
                int n = 0;
                foreach (object ro in (IList)day["rows"])
                {
                    if (n++ >= 8) break;
                    Dictionary<string, object> r = (Dictionary<string, object>)ro;
                    DateTime t = DateTime.Parse(OfS(r, "t"), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal).ToLocalTime();
                    Log("official:   " + t.ToString("HH:mm") + (OfS(r, "est") == "True" ? " est" : "    ") + "  " + (OfS(r, "fav") == "True" ? "* " : "  ") + OfS(r, "series") + " | " + OfS(r, "car") + " | " + OfS(r, "track") + (OfS(r, "layout").Length > 0 ? " - " + OfS(r, "layout") : "") + " | " + OfS(r, "len") + " | " + OfS(r, "lic") + " | " + OfS(r, "id"));
                }
            }
            return 0;
        }

        // ---- favourites (same file and format irdash writes: one series name per line, newest first) ----
        static int OfFav(string what)
        {
            if (what.Length == 0) { Log("official fav: give a series id or its name"); return 1; }
            if (Regex.IsMatch(what, "^o[0-9a-f]{8}$"))
            {
                try { using (WebClient wc = new WebClient()) wc.DownloadString("http://127.0.0.1:8199/api/do?c=offav&a=" + what); Log("official: star toggled for " + what); return 0; }
                catch (Exception ex) { Log("official fav: irdash is not answering (" + ex.Message + ")"); return 1; }
            }
            string f = Path.Combine(OfDir, "favourites.ini");
            Directory.CreateDirectory(OfDir);
            List<string> names = new List<string>();
            try { if (File.Exists(f)) foreach (string raw in File.ReadAllLines(f, Encoding.UTF8)) { string l = raw.Trim(); if (l.Length > 0 && !l.StartsWith(";") && !l.StartsWith("#")) names.Add(l); } } catch { }
            int i = names.FindIndex(delegate (string n) { return OfNorm(n) == OfNorm(what); });
            if (i >= 0) { names.RemoveAt(i); Log("official: star removed from " + what); } else { names.Insert(0, what.Trim()); Log("official: starred " + what); }
            StringBuilder sb = new StringBuilder();
            sb.Append("; Paddock favourite series, one per line, newest first. The star key on the OFFICIAL screen adds and removes lines;\r\n");
            sb.Append("; you can edit this with Notepad too. Names ignore the season (\"2026 Season 4\"), so a favourite survives into the next season.\r\n");
            foreach (string n in names) sb.Append(n).Append("\r\n");
            string tmp = f + ".tmp";
            File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
            try { if (File.Exists(f)) File.Replace(tmp, f, null); else File.Move(tmp, f); } catch { try { File.Copy(tmp, f, true); File.Delete(tmp); } catch { } }
            return 0;
        }

        // ---- scan owned: ask iRacing's own lists (the Test Drive Set Car / Set Track panels show what is not yours with a cart) ----
        static string OfSearchText(string name)
        {
            string s = Regex.Replace(Regex.Replace(name ?? "", @"\s*\([^)]*\)", ""), @"[^A-Za-z0-9 -]", " ");
            s = Regex.Replace(s, @"\s+", " ").Trim();
            return s.Length > 24 ? s.Substring(0, 24).Trim() : s;
        }

        static int OfScanOwned()
        {
            if (SessionActive()) { Log("official scan: a session is running - not touching iRacing"); return 3; }
            Dictionary<string, object> owned;
            try { owned = OfGet("/official/owned"); } catch (Exception ex) { Log("official scan: irdash is not answering (" + ex.Message + ")"); return 1; }
            Mutex ui = new Mutex(false, "Local\\irdeck-mydrive-ui");
            bool got = false;
            try { got = ui.WaitOne(8000); } catch (AbandonedMutexException) { got = true; }
            if (!got) { Log("official scan: another step is using iRacing"); ui.Dispose(); return 3; }
            try
            {
                List<string> carNames = new List<string>(), trackNames = new List<string>();
                foreach (object o in (IList)owned["carNames"]) carNames.Add(Convert.ToString(o));
                foreach (object o in (IList)owned["trackNames"]) trackNames.Add(Convert.ToString(o));
                var seenKey = new HashSet<string>();
                var result = new Dictionary<string, object>(); var cars = new Dictionary<string, object>(); var tracks = new Dictionary<string, object>();
                DateTime t0 = DateTime.Now; int checkedN = 0;
                foreach (int pass in new int[] { 0, 1 })
                {
                    foreach (string name in pass == 0 ? carNames : trackNames)
                    {
                        string key = (pass == 0 ? "c:" : "t:") + OfNorm(name);
                        if (!seenKey.Add(key) || OfSearchText(name).Length < 3) continue;
                        if (SessionActive()) { Log("official scan: a session started - stopping"); return 3; }
                        if ((DateTime.Now - t0).TotalMinutes > 25) { Log("official scan: 25 minutes is enough for one go - stopping, run it again to carry on"); break; }
                        List<string> rows = TdLookup(pass == 0 ? "car" : "track", OfSearchText(name), 12);
                        if (rows == null) { Log("official scan: stopped - " + TdWhy); return 1; }
                        bool found = rows.Exists(delegate (string r) { return OfNorm(r) == OfNorm(name); });
                        // 12 rows full and no exact match = the list was too long to tell: unknown, not "not yours"
                        if (found) (pass == 0 ? cars : tracks)[name] = true;
                        else if (rows.Count < 12) (pass == 0 ? cars : tracks)[name] = false;
                        checkedN++;
                        Log("official scan: " + (pass == 0 ? "car " : "track ") + name + " -> " + (found ? "yours" : rows.Count < 12 ? "NOT in your list" : "list too long to tell"));
                    }
                }
                result["checkedAt"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture); result["cars"] = cars; result["tracks"] = tracks;
                Directory.CreateDirectory(OfDir);
                File.WriteAllText(Path.Combine(OfDir, "owned-ui.json"), Js().Serialize(result), new UTF8Encoding(false));
                try { using (WebClient wc = new WebClient()) wc.DownloadString("http://127.0.0.1:8199/official/refresh"); } catch { }
                Log("official scan: " + checkedN + " names checked in " + Math.Round((DateTime.Now - t0).TotalSeconds) + " s");
                return 0;
            }
            finally { try { ui.ReleaseMutex(); } catch { } ui.Dispose(); }
        }

        // ---- map / register --dry: look at the Official page, read only ----
        static int OfMap(string seriesId)
        {
            if (SessionActive()) { Log("official: a session is running - not touching iRacing"); return 3; }
            AutomationElement root = FindUiWindow();
            if (root == null) { Log("official: the iRacing screen isn't open (press RIG ON)"); return 2; }
            Mutex ui = new Mutex(false, "Local\\irdeck-mydrive-ui");
            bool got = false;
            try { got = ui.WaitOne(8000); } catch (AbandonedMutexException) { got = true; }
            if (!got) { Log("official: another step is using iRacing"); ui.Dispose(); return 3; }
            try
            {
                IntPtr uh = new IntPtr(root.Current.NativeWindowHandle); tdUi = uh;
                if (Native.IsIconic(uh)) Native.ShowWindow(uh, 9);
                FocusWindow(uh);
                string wantName = "";
                if (seriesId != null)
                {
                    try
                    {
                        Dictionary<string, object> d = OfGet("/official");
                        foreach (object o in (IList)d["deck"]) { Dictionary<string, object> r = (Dictionary<string, object>)o; if (OfS(r, "id") == seriesId) wantName = OfS(r, "series"); }
                    }
                    catch { }
                    if (wantName.Length == 0) { Log("official register --dry: irdash does not list " + seriesId); return 1; }
                }
                // the sidebar's Official button (the OFFICIAL key on the MAIN deck page does the same)
                int rc = CmdNav(new string[] { "--button", "Official" });
                if (rc != 0) { Log("official: the Official button was not found in the iRacing sidebar"); return rc; }
                Thread.Sleep(3500);
                List<UEl> els = UiAll(root);
                if (els.Count < 20) { Log("official: the Official page shows only " + els.Count + " elements - not reading it"); return 1; }
                if (seriesId == null)
                {
                    StringBuilder sb = new StringBuilder();
                    sb.Append("# iRacing Official page, raw UI Automation dump ").Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm")).Append("\r\n# type | name | automation id | x,y w x h\r\n");
                    foreach (UEl u in els) sb.Append(u.Type.ProgrammaticName.Replace("ControlType.", "")).Append(" | ").Append(u.Name).Append(" | ").Append(u.Id).Append(" | ").Append((int)u.R.X).Append(',').Append((int)u.R.Y).Append(' ').Append((int)u.R.Width).Append('x').Append((int)u.R.Height).Append("\r\n");
                    string path = Path.Combine(Root, @"docs\iracing-ui-map.raw.txt");
                    File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
                    Log("official map: " + els.Count + " elements written to " + path);
                    return 0;
                }
                // dry run: the row that names the series, and the buttons level with it
                string key = OfNorm(wantName);
                UEl row = els.Find(delegate (UEl u) { return u.Name.Length > 3 && OfNorm(u.Name).StartsWith(key.Length > 14 ? key.Substring(0, 14) : key); });
                if (row == null) { Log("official register --dry: '" + wantName + "' is not on the page that is showing (nothing was clicked)"); return 1; }
                List<string> near = new List<string>();
                foreach (UEl u in els) if ((u.Type == ControlType.Button || u.Type == ControlType.Hyperlink) && Math.Abs(u.R.Y - row.R.Y) < 70 && u.Name.Length > 0) near.Add(u.Name);
                bool hasReg = near.Exists(delegate (string n) { return n.IndexOf("Register", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("Join", StringComparison.OrdinalIgnoreCase) >= 0; });
                Log("official register --dry: row '" + row.Name + "', controls on it: " + (near.Count == 0 ? "none seen" : string.Join(", ", near.ToArray())) + (hasReg ? "  -> a Register/Join control is there. STOPPED, nothing was clicked." : "  -> no Register/Join control seen. Nothing was clicked."));
                return 0;
            }
            finally { try { ui.ReleaseMutex(); } catch { } ui.Dispose(); }
        }
    }
}
