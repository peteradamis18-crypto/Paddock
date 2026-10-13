// irdeck friends mode (GUEST page on the Stream Deck). Choices live in guest\state.ini, settings in guest\guest.ini;
// irdash reads both to show the guest screen and leaderboard on the top monitor.
//   guest on | off                 start / end friends mode (off puts your wheel strength back)
//   guest car <key> | track <key>  pick from guest.ini
//   guest driver <name> | guest    who is driving (underscore = space)
//   guest adddriver <name>         add a driver typed on the Stream Deck keyboard (saved in guest\drivers.txt)
//   guest deldriver <name>         remove one
//   guest wheel light|medium|full  how strong the wheel should feel (guest.ini). Full is your own strength.
//                                  Light and medium raise iRacing's Max Force so the same torque uses less of the wheel
//                                  (a lower Max Force clips and feels heavier). Applied when a session is running.
//   guest start                    into the car, then the wheel and the racing line
//   guest reset                    fresh car in the pits (waits if the car is still moving), then the guest wheel again
//   guest next                     next driver: fresh car, wheel back to light (not your full strength)
//   guest line | coach | board     racing line (the key already in guest.ini), coach and leaderboard on/off
//   guest hold | restore           internal: irdash applies a guest wheel that was not sent yet, or puts yours back next session
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

namespace IRDeck
{
    static partial class Program
    {
        static string GuestDir { get { return Path.Combine(Root, "guest"); } }

        // [section] key = value  (values may be "a | b | c")
        static Dictionary<string, Dictionary<string, string>> GuestIni()
        {
            var ini = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
            string sec = "";
            string file = Path.Combine(GuestDir, "guest.ini");
            if (!File.Exists(file)) return ini;
            foreach (string raw in File.ReadAllLines(file))
            {
                string l = raw.Trim();
                if (l.Length == 0 || l.StartsWith(";")) continue;
                if (l.StartsWith("[") && l.EndsWith("]")) { sec = l.Substring(1, l.Length - 2).Trim(); continue; }
                int e = l.IndexOf('='); if (e <= 0) continue;
                if (!ini.ContainsKey(sec)) ini[sec] = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                ini[sec][l.Substring(0, e).Trim()] = l.Substring(e + 1).Trim();
            }
            return ini;
        }

        static string IniGet(Dictionary<string, Dictionary<string, string>> ini, string sec, string key)
        {
            Dictionary<string, string> s; string v;
            return ini.TryGetValue(sec, out s) && s.TryGetValue(key, out v) ? v : "";
        }

        static Dictionary<string, string> GuestState()
        {
            var st = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string file = Path.Combine(GuestDir, "state.ini");
            if (File.Exists(file))
                foreach (string l in File.ReadAllLines(file)) { int e = l.IndexOf('='); if (e > 0) st[l.Substring(0, e)] = l.Substring(e + 1); }
            return st;
        }

        static void SaveGuestState(Dictionary<string, string> st)
        {
            Directory.CreateDirectory(GuestDir);
            var sb = new StringBuilder();
            foreach (var kv in st) sb.Append(kv.Key).Append('=').Append(kv.Value).Append("\r\n");
            File.WriteAllText(Path.Combine(GuestDir, "state.ini"), sb.ToString());
        }

        static string Sv(Dictionary<string, string> st, string k, string def) { string v; return st.TryGetValue(k, out v) && v.Length > 0 ? v : def; }

        // Drivers you have added (typed on the Stream Deck keyboard), most recent first, in guest\drivers.txt.
        // The first time, the names from guest.ini [drivers] are taken over (the "Friend 1..4" placeholders skipped).
        static List<string> Drivers(Dictionary<string, Dictionary<string, string>> ini)
        {
            string file = Path.Combine(GuestDir, "drivers.txt");
            var list = new List<string>();
            if (File.Exists(file)) { foreach (string l in File.ReadAllLines(file)) if (l.Trim().Length > 0) list.Add(l.Trim()); return list; }
            foreach (string id in new[] { "1", "2", "3", "4" })
            {
                string n = IniGet(ini, "drivers", id);
                if (n.Length > 0 && !n.StartsWith("Friend ", StringComparison.OrdinalIgnoreCase)) list.Add(n);
            }
            return list;
        }

        static void SaveDrivers(List<string> list)
        {
            Directory.CreateDirectory(GuestDir);
            File.WriteAllLines(Path.Combine(GuestDir, "drivers.txt"), list.GetRange(0, Math.Min(12, list.Count)).ToArray());
        }

        // names arrive from the keys as letters, digits and underscores (underscore = space)
        static string CleanName(string a)
        {
            var sb = new StringBuilder();
            foreach (char ch in (a ?? "").Replace('_', ' ')) if (char.IsLetterOrDigit(ch) || ch == ' ' || ch == '-') sb.Append(ch);
            string s = System.Text.RegularExpressions.Regex.Replace(sb.ToString(), @"\s+", " ").Trim();
            if (s.Length > 14) s = s.Substring(0, 14);
            return s.Length == 0 ? "" : CultureInfo.InvariantCulture.TextInfo.ToTitleCase(s.ToLowerInvariant());
        }

        static int CmdGuest(string[] a)
        {
            if (a.Length == 0) { Log("guest: need on|off|car|track|driver|wheel|start|reset|next|line|coach|board"); return 1; }
            var ini = GuestIni();
            var st = GuestState();
            LoadOwn(st);
            string cmd = a[0].ToLowerInvariant(), arg = a.Length > 1 ? a[1] : "";
            bool wasActive = Sv(st, "active", "0") == "1";
            if (cmd != "off" && cmd != "deldriver" && cmd != "voice" && cmd != "restore" && cmd != "hold" && !wasActive)
            {
                // any guest key switches friends mode on, with gentle defaults. Your wheel strength stays on disk.
                st["active"] = "1";
                if (!st.ContainsKey("car")) st["car"] = FirstKey(ini, "cars");
                if (!st.ContainsKey("track")) st["track"] = FirstKey(ini, "tracks");
                st["driver"] = System.Text.RegularExpressions.Regex.IsMatch(Sv(st, "driver", "guest"), "^[1-4]$") ? "guest" : Sv(st, "driver", "guest");   // old slot numbers
                st["wheel"] = "light";
                st["coach"] = "1"; st["board"] = "1";
                st["line"] = IniGet(ini, "options", "racing_line_default") == "0" ? "0" : "1";
                Log("guest: friends mode on");
            }
            switch (cmd)
            {
                case "on": break;
                case "voice":
                    {
                        // finish a CrewChief name change that had to wait for the car to stop (irdash calls this)
                        string pending = Sv(st, "cc_pending", "");
                        if (pending == "") return 0;
                        if (SetCrewChiefName(pending == "-" ? "" : pending, st) && !wasActive) st["own_cc_name"] = "";
                        SaveGuestState(st);
                        return 0;
                    }
                case "off":
                    if (wasActive && Sv(st, "line_on", "") == "1" && SessionActive())
                    {
                        // one press of the same key turns the line back off. The saved preference (st["line"]) stays.
                        string key = IniGet(ini, "options", "racing_line_key");
                        if (key != "")
                        {
                            int lrc = CmdKey(new[] { key, "--sim" });
                            if (lrc == 0) { st["line_on"] = "0"; Log("guest: racing line off"); }
                            else Log("guest: racing line stayed on (the key was not sent)");
                        }
                    }
                    if (wasActive) RestoreWheel(st);
                    if (Sv(st, "own_cc_name", "") != "")
                    {
                        // your own name back; if the car is moving it is remembered (cc_pending) and irdash finishes it
                        try { string own = st["own_cc_name"]; if (SetCrewChiefName(own == "-" ? "" : own, st)) st["own_cc_name"] = ""; }
                        catch (Exception ex) { Log("guest: CrewChief name: " + ex.Message); }
                    }
                    st["active"] = "0";
                    SaveGuestState(st);
                    Log("guest: friends mode off - your wheel strength is back");
                    return 0;
                case "car":
                    if (IniGet(ini, "cars", arg) == "") { Log("guest: no car '" + arg + "' in guest.ini"); return 1; }
                    st["car"] = arg; break;
                case "track":
                    if (IniGet(ini, "tracks", arg) == "") { Log("guest: no track '" + arg + "' in guest.ini"); return 1; }
                    st["track"] = arg; break;
                case "driver":
                    {
                        string n = arg.ToLowerInvariant() == "guest" ? "" : CleanName(arg);
                        st["driver"] = n.Length > 0 ? n : "guest";
                        if (n.Length > 0) { var list = Drivers(ini); list.RemoveAll(x => x.Equals(n, StringComparison.OrdinalIgnoreCase)); list.Insert(0, n); SaveDrivers(list); }
                        VoiceFor(st);
                        break;
                    }
                case "adddriver":
                    {
                        string n = CleanName(arg);
                        if (n.Length == 0) { Log("guest: no name typed"); SaveGuestState(st); return 1; }
                        var list = Drivers(ini); list.RemoveAll(x => x.Equals(n, StringComparison.OrdinalIgnoreCase)); list.Insert(0, n); SaveDrivers(list);
                        st["driver"] = n;
                        VoiceFor(st);
                        break;
                    }
                case "deldriver":
                    {
                        string n = CleanName(arg);
                        var list = Drivers(ini); list.RemoveAll(x => x.Equals(n, StringComparison.OrdinalIgnoreCase)); SaveDrivers(list);
                        if (Sv(st, "driver", "guest").Equals(n, StringComparison.OrdinalIgnoreCase)) st["driver"] = "guest";
                        break;
                    }
                case "wheel":
                    st["wheel"] = arg.ToLowerInvariant() == "full" ? "full" : arg.ToLowerInvariant() == "medium" ? "medium" : "light";
                    SaveGuestState(st);
                    ApplyWheel(ini, st);
                    SaveGuestState(st);
                    return 0;
                case "coach": st["coach"] = Sv(st, "coach", "1") == "1" ? "0" : "1"; break;
                case "board": st["board"] = Sv(st, "board", "1") == "1" ? "0" : "1"; break;
                case "line":
                    {
                        string key = IniGet(ini, "options", "racing_line_key");
                        if (key == "") { Log("guest: racing line - set racing_line_key in guest\\guest.ini first"); SaveGuestState(st); return 3; }
                        st["line"] = Sv(st, "line", "1") == "1" ? "0" : "1";
                        if (!SessionActive())
                        {
                            Log("guest: racing line will apply when you are in a session");
                            SaveGuestState(st);
                            return 0;
                        }
                        int rc = ApplyLine(ini, st);
                        SaveGuestState(st);
                        return rc;
                    }
                case "start":
                    {
                        SaveGuestState(st);
                        bool fresh = !SessionActive();
                        int rc;
                        if (!fresh) rc = CmdGo();
                        else
                        {
                            MarkStart("guest start");   // irdash times START -> session -> in the car (dash\timings.tsv)
                            // set up Test Drive with the chosen car, track and layout (damage off), launch, then get in
                            string carFull = Part(IniGet(ini, "cars", Sv(st, "car", "")), 1);
                            string[] trk = IniGet(ini, "tracks", Sv(st, "track", "")).Split('|');
                            string trackFull = trk.Length > 1 ? trk[1].Trim() : "", layout = trk.Length > 2 ? trk[2].Trim() : "";
                            if (carFull == "" || trackFull == "") { Log("guest: pick a car and a track first"); return 1; }
                            var args = new List<string> { carFull, trackFull };
                            if (layout != "") args.Add(layout);
                            if (IniGet(ini, "options", "no_damage") != "0") args.Add("--damage-off");
                            args.Add("--launch");
                            rc = CmdTdSetup(args.ToArray());
                            if (rc == 0)
                            {
                                for (int i = 0; i < 480 && !SessionActive(); i++) System.Threading.Thread.Sleep(500);
                                if (!SessionActive()) { Log("guest: the Test Drive session did not load"); return 1; }
                                System.Threading.Thread.Sleep(3000);
                                rc = CmdGo();
                            }
                        }
                        if (rc == 0)
                        {
                            // a brand new session starts with the driving line off, so one key press turns it on
                            if (fresh) st["line_on"] = "0";
                            ApplyWheel(ini, st);
                            int lrc = ApplyLine(ini, st);
                            if (lrc != 0) Log("guest: in the car, racing line still pending");
                            SaveGuestState(st);
                        }
                        return rc;
                    }
                case "reset":
                    {
                        // CmdTow waits if the car is still sliding, then does the same tow as a stopped car.
                        // 4 = it gave up, or a second press arrived while the first was waiting: do not treat that as a fresh car.
                        SaveGuestState(st);
                        int rc = CmdTow();
                        if (rc == 0) { ApplyWheel(ini, st); SaveGuestState(st); }
                        if (rc == 4) return 0;
                        return rc;
                    }
                case "hold":
                    {
                        // irdash calls this while friends mode is on and the friend is in the car. Nothing to do = do not touch the file.
                        if (!wasActive || !SessionActive()) return 0;
                        LoadOwn(st);
                        double max, torque, pct, speed;
                        if (!ReadWheel(out max, out torque, out pct, out speed)) return 0;
                        if (double.IsNaN(max) || double.IsNaN(torque) || double.IsNaN(pct)) return 0;
                        bool changed = false;
                        if (Sv(st, "own_ffb", "") == "" || Sv(st, "wheel_sent", "") == "")
                        {
                            ApplyWheel(ini, st);
                            changed = true;
                        }
                        // SteeringWheelMaxForceNm stays at your own maximum after a send. Comparing it
                        // with the sent force looked like drift and re-applied the old feel over a new one.
                        bool wantOn = Sv(st, "line", "1") != "0", isOn = Sv(st, "line_on", "0") == "1";
                        if (wantOn != isOn && speed < 1.0) { ApplyLine(ini, st); changed = true; }
                        if (!changed) return 0;
                        SaveGuestState(st);
                        return 0;
                    }
                case "restore":
                    if (wasActive) return 0;
                    LoadOwn(st);
                    if (Sv(st, "own_ffb", "") == "") return 0;
                    RestoreWheel(st);
                    SaveGuestState(st);
                    return 0;
                case "next":
                    {
                        // the drivers shown on the WHO row, then Guest, round and round. The next friend stays on Light.
                        var order = Drivers(ini); if (order.Count > 4) order = order.GetRange(0, 4);
                        order.Add("guest");
                        int i = order.FindIndex(x => x.Equals(Sv(st, "driver", "guest"), StringComparison.OrdinalIgnoreCase));
                        st["driver"] = order[(i + 1) % order.Count]; st["wheel"] = "light";
                        SaveGuestState(st);
                        // out of the car first, so CrewChief can switch to the new name, then a fresh car
                        if (OnTrack()) { if (CmdGetOut() != 0) { SaveGuestState(st); return 3; } for (int w = 0; w < 40 && OnTrack(); w++) System.Threading.Thread.Sleep(250); }
                        VoiceFor(st);
                        if (SessionActive()) { System.Threading.Thread.Sleep(1500); CmdGo(); }
                        ApplyWheel(ini, st);
                        SaveGuestState(st);
                        Log("guest: next driver " + DriverName(ini, st["driver"]));
                        return 0;
                    }
                default: Log("guest: unknown '" + cmd + "'"); return 1;
            }
            SaveGuestState(st);
            Log("guest: " + cmd + (arg.Length > 0 ? " " + arg : "") + " (driver " + DriverName(ini, Sv(st, "driver", "guest")) + ", car " + st["car"] + ", track " + st["track"] + ")");
            return 0;
        }

        static string Part(string v, int i) { string[] p = (v ?? "").Split('|'); return i < p.Length ? p[i].Trim() : ""; }

        static string FirstKey(Dictionary<string, Dictionary<string, string>> ini, string sec)
        {
            Dictionary<string, string> s;
            if (ini.TryGetValue(sec, out s)) foreach (var kv in s) return kv.Key;
            return "";
        }

        // ---------- CrewChief says the driver's name ----------
        // CrewChief can only say names it has recordings for (sounds\personalisations\<Name>, 945 of them).
        // Picking a driver sets its name and restarts CrewChief (about 5 s, never while driving); your own
        // name is remembered and put back by EXIT.
        static string CrewChiefVoiceName(string name)
        {
            if (string.IsNullOrEmpty(name) || name.Equals("guest", StringComparison.OrdinalIgnoreCase)) return "";
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"CrewChiefV4\sounds\personalisations");
            string first = name.Split(' ')[0];
            if (!Directory.Exists(dir)) return "";
            foreach (string d in Directory.GetDirectories(dir))
            {
                string n = Path.GetFileName(d);
                if (n.Equals(name, StringComparison.OrdinalIgnoreCase) || n.Equals(first, StringComparison.OrdinalIgnoreCase)) return n;
            }
            return "";
        }

        static string CrewChiefConfig()
        {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Britton_IT_Ltd");
            if (!Directory.Exists(root)) return null;
            string best = null; DateTime bt = DateTime.MinValue;
            foreach (string f in Directory.GetFiles(root, "user.config", SearchOption.AllDirectories))
                if (File.GetLastWriteTime(f) > bt) { bt = File.GetLastWriteTime(f); best = f; }
            return best;
        }

        static string GetCrewChiefName()
        {
            string f = CrewChiefConfig(); if (f == null) return "";
            var m = System.Text.RegularExpressions.Regex.Match(File.ReadAllText(f), "name=\"PERSONALISATION_NAME\"[^>]*>\\s*<value>([^<]*)</value>");
            return m.Success ? m.Groups[1].Value : "";
        }

        // CrewChief restarts to take a new name (about 5 s without the spotter), so never while the car is moving.
        static bool CarMoving()
        {
            Tele t = Tele.Open(); if (t == null) return false;
            using (t) return t.Bool("IsOnTrack") && t.Num("Speed") > 1.0;
        }

        // Returns false when the change had to wait (car moving); the caller keeps what still has to happen.
        static bool SetCrewChiefName(string voice, Dictionary<string, string> st)
        {
            string f = CrewChiefConfig(); if (f == null) return true;
            string cur = GetCrewChiefName();
            if (!st.ContainsKey("own_cc_name") || st["own_cc_name"] == "") st["own_cc_name"] = cur.Length > 0 ? cur : "-";
            if (cur == voice) return true;
            if (CarMoving()) { Log("guest: CrewChief will switch to " + (voice.Length > 0 ? voice : "no name") + " once the car stops"); st["cc_pending"] = voice.Length > 0 ? voice : "-"; return false; }
            st["cc_pending"] = "";
            Process[] cc = Process.GetProcessesByName("CrewChiefV4");
            string exe = null;
            foreach (Process p in cc) { try { exe = p.MainModule.FileName; } catch { } }
            foreach (Process p in cc) { try { p.Kill(); p.WaitForExit(4000); } catch { } }
            string xml = File.ReadAllText(f);
            if (xml.Contains("name=\"PERSONALISATION_NAME\""))
                xml = System.Text.RegularExpressions.Regex.Replace(xml, "(name=\"PERSONALISATION_NAME\"[^>]*>\\s*<value>)[^<]*(</value>)", "${1}" + voice + "${2}");
            else
                xml = xml.Replace("<CrewChiefV4.Properties.Settings>", "<CrewChiefV4.Properties.Settings>\r\n            <setting name=\"PERSONALISATION_NAME\" serializeAs=\"String\">\r\n                <value>" + voice + "</value>\r\n            </setting>");
            File.WriteAllText(f, xml, new UTF8Encoding(false));
            if (cc.Length > 0)
            {
                if (exe == null) exe = @"C:\Program Files (x86)\Britton IT Ltd\CrewChiefV4\CrewChiefV4.exe";
                var psi = new System.Diagnostics.ProcessStartInfo(exe); psi.UseShellExecute = true; psi.WorkingDirectory = Path.GetDirectoryName(exe);
                System.Diagnostics.Process.Start(psi);
            }
            Log("guest: CrewChief now calls the driver " + (voice.Length > 0 ? voice : "(no name)"));
            return true;
        }

        static void VoiceFor(Dictionary<string, string> st)
        {
            try { SetCrewChiefName(CrewChiefVoiceName(Sv(st, "driver", "guest")), st); }
            catch (Exception ex) { Log("guest: CrewChief name: " + ex.Message); }
        }

        static string DriverName(Dictionary<string, Dictionary<string, string>> ini, string d)
        {
            return d == null || d.Length == 0 || d.Equals("guest", StringComparison.OrdinalIgnoreCase) ? "Guest" : d;
        }

        // Your Max Force (Nm), in state.ini and again in guest\own-ffb.txt. Friends mode must not wipe it:
        // a later "on" used to forget it and then save the guest number as if it were yours.
        static string OwnPath()
        {
            return Path.Combine(GuestDir, "own-ffb.txt");
        }

        static void LoadOwn(Dictionary<string, string> st)
        {
            if (Sv(st, "own_ffb", "") != "") return;
            try
            {
                if (!File.Exists(OwnPath())) return;
                double v;
                if (double.TryParse(File.ReadAllText(OwnPath()).Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out v) && v >= 1.0)
                    st["own_ffb"] = v.ToString("0.0", CultureInfo.InvariantCulture);
            }
            catch { }
        }

        static void StoreOwn(Dictionary<string, string> st, double own)
        {
            string s = own.ToString("0.0", CultureInfo.InvariantCulture);
            st["own_ffb"] = s;
            try { Directory.CreateDirectory(GuestDir); File.WriteAllText(OwnPath(), s); } catch { }
        }

        static void ClearOwn(Dictionary<string, string> st)
        {
            st["own_ffb"] = "";
            st["wheel_sent"] = "";
            st["wheel_read"] = "";
            try { if (File.Exists(OwnPath())) File.Delete(OwnPath()); } catch { }
        }

        static bool ReadWheel(out double max, out double torque, out double pct, out double speed)
        {
            max = 0; torque = 0; pct = 0; speed = 0;
            Tele t = Tele.Open();
            if (t == null) return false;
            using (t)
            {
                if (!t.Has("SteeringWheelMaxForceNm")) return false;
                max = t.Num("SteeringWheelMaxForceNm");
                if (t.Has("SteeringWheelTorque")) torque = t.Num("SteeringWheelTorque");
                if (t.Has("SteeringWheelPctTorque")) pct = t.Num("SteeringWheelPctTorque");
                speed = t.Num("Speed");
                return true;
            }
        }

        static void SendForce(double nm)
        {
            // irsdk_BroadcastFFBCommand / FFBCommand_MaxForce: 16.16 fixed point, same as the SDK sample.
            Bcast(11, 0, (int)(nm * 65536.0));
        }

        // guest.ini light/medium are the feel you want, in Nm, against your own Max Force.
        // iRacing maps that many Nm of physics torque onto the whole wheel. Sending 8 when the car's
        // own figure is 46 makes the wheel heavy and clips. Sending own*own/feel uses feel/own of the travel.
        static double WheelNm(Dictionary<string, Dictionary<string, string>> ini, Dictionary<string, string> st, double own, out double feel)
        {
            string w = Sv(st, "wheel", "light");
            if (w == "full" || own < 1.0) { feel = own; return Math.Max(1.0, own); }
            double v;
            if (!double.TryParse(IniGet(ini, "wheel", w), NumberStyles.Float, CultureInfo.InvariantCulture, out v) || v <= 0)
                v = w == "light" ? 8.0 : 14.0;
            feel = v;
            if (feel >= own) return own;
            double nm = (own * own) / feel;
            if (nm < 1.0) nm = 1.0;
            if (nm > 300.0) nm = 300.0;
            return nm;
        }

        static void ApplyWheel(Dictionary<string, Dictionary<string, string>> ini, Dictionary<string, string> st)
        {
            LoadOwn(st);
            string w = Sv(st, "wheel", "light");
            double max, torque, pct, speed;
            bool ok = ReadWheel(out max, out torque, out pct, out speed);
            if (!ok)
            {
                double shown = w == "full" ? 0 : 14;
                double parsed;
                if (w != "full" && double.TryParse(IniGet(ini, "wheel", w), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) && parsed > 0) shown = parsed;
                if (w == "full" && Sv(st, "own_ffb", "") != "") shown = double.Parse(st["own_ffb"], CultureInfo.InvariantCulture);
                Log(string.Format(CultureInfo.InvariantCulture, "guest: wheel {0} ({1:0.0} Nm feel) will apply when you are in a session", w, shown));
                return;
            }
            if (Sv(st, "own_ffb", "") == "")
            {
                if (max < 1.0) { Log("guest: wheel strength is not ready yet"); return; }
                StoreOwn(st, max);
            }
            double own = double.Parse(st["own_ffb"], CultureInfo.InvariantCulture), feel;
            double nm = WheelNm(ini, st, own, out feel);
            SendForce(nm);
            System.Threading.Thread.Sleep(350);
            double got;
            bool gotOk = ReadWheel(out got, out torque, out pct, out speed);
            st["wheel_sent"] = nm.ToString("0.0", CultureInfo.InvariantCulture);
            // The sim's max-force reading stays at your own maximum, so it is not proof the feel landed.
            // Torque while sitting still is only a few Nm, which is also not proof. Log both, and do not warn.
            if (gotOk) st["wheel_read"] = got.ToString("0.0", CultureInfo.InvariantCulture);
            Log(string.Format(CultureInfo.InvariantCulture,
                "guest: wheel {0} feel {1:0.0} Nm -> max force {2:0.0} Nm, sim reads {3} (yours {4:0.0}, torque {5:0.0} Nm, pct {6:0.00})",
                w, feel, nm, gotOk ? got.ToString("0.0", CultureInfo.InvariantCulture) : "n/a", own, gotOk ? torque : 0, gotOk ? pct : 0));
        }

        static void RestoreWheel(Dictionary<string, string> st)
        {
            LoadOwn(st);
            string ownS = Sv(st, "own_ffb", "");
            if (ownS == "") return;
            double own = double.Parse(ownS, CultureInfo.InvariantCulture);
            double max, torque, pct, speed;
            if (!ReadWheel(out max, out torque, out pct, out speed))
            {
                Log(string.Format(CultureInfo.InvariantCulture, "guest: your wheel strength ({0:0.0} Nm) is saved and will be restored in the next session", own));
                return;
            }
            if (Math.Abs(max - own) <= 1.5)
            {
                ClearOwn(st);
                Log(string.Format(CultureInfo.InvariantCulture, "guest: wheel back to yours {0:0.0} Nm, sim reads {1:0.0}", own, max));
                return;
            }
            SendForce(own);
            System.Threading.Thread.Sleep(350);
            double got;
            bool gotOk = ReadWheel(out got, out torque, out pct, out speed);
            if (gotOk && Math.Abs(got - own) > 1.5)
            {
                SendForce(own);
                System.Threading.Thread.Sleep(350);
                gotOk = ReadWheel(out got, out torque, out pct, out speed);
            }
            if (gotOk && Math.Abs(got - own) <= 1.5)
            {
                ClearOwn(st);
                Log(string.Format(CultureInfo.InvariantCulture, "guest: wheel back to yours {0:0.0} Nm, sim reads {1:0.0}", own, got));
            }
            else
                Log(string.Format(CultureInfo.InvariantCulture, "guest: could not put your wheel back yet (yours {0:0.0} Nm, sim reads {1})", own, gotOk ? got.ToString("0.0", CultureInfo.InvariantCulture) : "n/a"));
        }

        // The driving line is a toggle (Options > Controls > Toggle Driving Line, already ctrl+alt+l).
        // A new session starts with it off. line_on is what we believe the sim is showing.
        static int ApplyLine(Dictionary<string, Dictionary<string, string>> ini, Dictionary<string, string> st)
        {
            string key = IniGet(ini, "options", "racing_line_key");
            bool want = Sv(st, "line", "1") != "0";
            if (key == "") { Log("guest: racing line - set racing_line_key in guest\\guest.ini first"); return 3; }
            if (!SessionActive()) { Log("guest: racing line will apply when you are in a session"); return 0; }
            bool on = Sv(st, "line_on", "0") == "1";
            if (on == want)
            {
                Log("guest: racing line already " + (want ? "on" : "off"));
                return 0;
            }
            int rc = CmdKey(new[] { key, "--sim" });
            if (rc == 0)
            {
                st["line_on"] = want ? "1" : "0";
                Log("guest: racing line " + (want ? "on" : "off"));
            }
            else Log("guest: racing line key was not sent (" + rc + ")");
            return rc;
        }
    }
}
