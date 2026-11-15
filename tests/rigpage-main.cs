// Entry point for tests\rigpage-test.ps1 only (W5-1): compiled together with dash\src\*.cs (csc /main:IRDash.RigPageMain) into a
// throw-away exe in %TEMP%. It runs irdash's real Server on a test port (never 8199) with RigPage pointed at a throw-away ini and at a
// copied registry tree under HKCU\Software\PaddockTest (HKLM is only READ, to copy its Capture devices), and talks to it over real
// sockets: GET /api/settings, /api/do?c=startupsound|mic, the "settings" and "ac" parts in /state. The test key is deleted at the end.
//   rigpage.exe <port> <www dir> <ini file>
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace IRDash
{
    static class RigPageMain
    {
        static int pass, fail, port;
        static void Ok(string what, bool cond, string why) { if (cond) { pass++; Console.WriteLine("  ok   " + what); } else { fail++; Console.WriteLine("  FAIL " + what + (string.IsNullOrEmpty(why) ? "" : "  (" + why + ")")); } }
        static readonly JavaScriptSerializer J = new JavaScriptSerializer();
        const string Desc = "{a45c254e-df1c-4efd-8020-67d146a850e0},2", Full = "{a45c254e-df1c-4efd-8020-67d146a850e0},14", Iface = "{b3f8fa53-0004-438e-9003-51a46e139bfc},6";

        static string[] Get(string target)
        {
            using (TcpClient c = new TcpClient("127.0.0.1", port))
            {
                c.ReceiveTimeout = 5000;
                NetworkStream s = c.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("GET " + target + " HTTP/1.1\r\nHost: localhost:" + port + "\r\nX-Paddock: 1\r\nConnection: close\r\n\r\n");
                s.Write(req, 0, req.Length);
                MemoryStream ms = new MemoryStream(); byte[] b = new byte[8192]; int n;
                try { while ((n = s.Read(b, 0, b.Length)) > 0) ms.Write(b, 0, n); } catch (IOException) { }
                string all = Encoding.UTF8.GetString(ms.ToArray());
                int h = all.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                string code = all.Length > 12 ? all.Substring(9, 3) : "0";
                return new[] { code, h >= 0 ? all.Substring(h + 4) : "" };
            }
        }
        static Dictionary<string, object> Obj(string j) { try { return J.DeserializeObject(j) as Dictionary<string, object>; } catch { return null; } }
        static string Names(object mics)
        {
            List<string> o = new List<string>();
            object[] a = mics as object[]; if (a == null) return "?";
            foreach (object x in a) { Dictionary<string, object> d = x as Dictionary<string, object>; o.Add(d["name"] + ((bool)d["default"] ? "*" : "")); }
            return string.Join(" | ", o.ToArray());
        }
        static string IniHas(string ini, string key)
        {
            foreach (string l in File.ReadAllLines(ini)) if (l.StartsWith(key + "=", StringComparison.OrdinalIgnoreCase)) return l.Substring(key.Length + 1);
            return null;
        }

        static void Dev(RegistryKey root, string id, int state, string desc, string iface, string full, bool level)
        {
            using (RegistryKey k = root.CreateSubKey(id))
            {
                k.SetValue("DeviceState", state, RegistryValueKind.DWord);
                if (level) k.SetValue("Level:0", new byte[] { 14 }, RegistryValueKind.Binary);
                using (RegistryKey p = k.CreateSubKey("Properties"))
                {
                    if (desc != null) p.SetValue(Desc, desc);
                    if (iface != null) p.SetValue(Iface, iface);
                    if (full != null) p.SetValue(Full, full);
                }
            }
        }

        static int Main(string[] a)
        {
            port = int.Parse(a[0]);
            string www = a[1], ini = a[2];
            Log.FilePath = Path.Combine(Path.GetTempPath(), "rigpage-test-" + port + ".log");
            string testRoot = @"Software\PaddockTest\rigpage-" + System.Diagnostics.Process.GetCurrentProcess().Id;
            try
            {
                Console.WriteLine("Section 1. the names and the registry reader (HKLM only read)");
                Ok("NameOf: \"Headset\" on \"Arctis 7P+\" = \"Headset (Arctis 7P+)\" (Chrome's track label)", RigPage.NameOf("Headset", "Arctis 7P+", null) == "Headset (Arctis 7P+)", RigPage.NameOf("Headset", "Arctis 7P+", null));
                Ok("NameOf: no device name -> the stored full name, else the short one", RigPage.NameOf("Mic", null, "Mic (USB)") == "Mic (USB)" && RigPage.NameOf("Mic", "", "") == "Mic", "");
                // a made-up tree: two active mics (one with Level:0), one unplugged, one disabled, one active with only the full name
                using (RegistryKey fake = Registry.CurrentUser.CreateSubKey(testRoot + @"\fake"))
                {
                    Dev(fake, "{1}", 1, "Headset", "Arctis 7P+", null, true);
                    Dev(fake, "{2}", 1, "Microphone", "Realtek USB2.0 Audio", null, false);
                    Dev(fake, "{3}", 4, "Microphone", "Arctis Nova 7P", null, true);          // unplugged
                    Dev(fake, "{4}", 268435457, "Analog Connector", "Realtek USB2.0 Audio", null, false);   // not exactly 1: left out
                    Dev(fake, "{5}", 1, null, null, "Webcam Mic (C920)", false);
                    using (RegistryKey bad = fake.CreateSubKey("{6}")) bad.SetValue("DeviceState", "x");           // unreadable: skipped
                    List<RigPage.Mic> m = RigPage.ReadMics(fake);
                    string got = string.Join(" | ", m.ConvertAll(delegate (RigPage.Mic x) { return x.Name + (x.Default ? "*" : ""); }).ToArray());
                    Ok("the made-up tree: the three active mics, sorted, the one with Level:0 marked default", got == "Headset (Arctis 7P+)* | Microphone (Realtek USB2.0 Audio) | Webcam Mic (C920)", got);
                }
                using (RegistryKey one = Registry.CurrentUser.CreateSubKey(testRoot + @"\one"))
                {
                    Dev(one, "{1}", 1, "Headset", "AirPods", null, false);
                    Dev(one, "{2}", 4, "Microphone", "Arctis 7P+", null, true);
                    List<RigPage.Mic> m = RigPage.ReadMics(one);
                    Ok("one active mic without Level:0: it is the default", m.Count == 1 && m[0].Default, m.Count.ToString());
                }
                // the real devices, copied (read from HKLM, written under HKCU), read back by the same reader
                int copied = 0;
                using (RegistryKey hk = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (RegistryKey src = hk.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture", false))
                using (RegistryKey dst = Registry.CurrentUser.CreateSubKey(testRoot + @"\copy"))
                {
                    if (src != null)
                    {
                        foreach (string id in src.GetSubKeyNames())
                        {
                            try
                            {
                                using (RegistryKey k = src.OpenSubKey(id, false))
                                using (RegistryKey p = k.OpenSubKey("Properties", false))
                                {
                                    object st = k.GetValue("DeviceState");
                                    Dev(dst, id, st is int ? (int)st : 0, p == null ? null : p.GetValue(Desc) as string, p == null ? null : p.GetValue(Iface) as string, p == null ? null : p.GetValue(Full) as string, k.GetValue("Level:0") != null);
                                    copied++;
                                }
                            }
                            catch { }
                        }
                        List<RigPage.Mic> live = RigPage.ReadMics(src), cp = RigPage.ReadMics(dst);
                        string l1 = string.Join(" | ", live.ConvertAll(delegate (RigPage.Mic x) { return x.Name + (x.Default ? "*" : ""); }).ToArray());
                        string l2 = string.Join(" | ", cp.ConvertAll(delegate (RigPage.Mic x) { return x.Name + (x.Default ? "*" : ""); }).ToArray());
                        Ok("the copied tree of this PC's " + copied + " recording devices reads the same as HKLM itself: " + (l1.Length > 0 ? l1 : "(no active mic)"), l1 == l2, l1 + " vs " + l2);
                    }
                    else Console.WriteLine("  info this PC has no Capture key: the copy check is left out");
                }

                Console.WriteLine("Section 2. the routes on a pretend irdash (port " + port + ")");
                RigPage.IniPath = ini;
                RigPage.CaptureRoot = delegate () { return Registry.CurrentUser.OpenSubKey(testRoot + @"\fake", false); };
                Server srv = new Server(port, www, Path.GetTempPath());
                srv.Start();
                Thread.Sleep(1500);
                string[] r = Get("/api/settings"); Dictionary<string, object> o = Obj(r[1]);
                Ok("GET /api/settings: 200, start-up sound on, no mic (Windows' default), the three mics", r[0] == "200" && o != null && (bool)o["startupSound"] && (string)o["mic"] == "" && Names(o["mics"]) == "Headset (Arctis 7P+)* | Microphone (Realtek USB2.0 Audio) | Webcam Mic (C920)", r[0] + " " + r[1]);
                r = Get("/api/do?c=startupsound&a=off"); o = Obj(r[1]);
                Ok("startupsound off: 200 JSON {ok, say \"Start-up sound off\", startupSound false}; the ini says startup_sound=off", r[0] == "200" && o != null && (bool)o["ok"] && (string)o["say"] == "Start-up sound off" && !(bool)o["startupSound"] && IniHas(ini, "startup_sound") == "off", r[0] + " " + r[1]);
                o = Obj(Get("/api/settings")[1]);
                Ok("read back: /api/settings says startupSound false", o != null && !(bool)o["startupSound"], "");
                Thread.Sleep(800);
                r = Get("/api/do?c=startupsound&a=on");
                Ok("startupsound on: back on, the ini says on", r[0] == "200" && IniHas(ini, "startup_sound") == "on", r[0] + " " + r[1]);
                r = Get("/api/do?c=startupsound&a=loud");
                Ok("startupsound loud: refused 400, the ini unchanged", r[0] == "400" && IniHas(ini, "startup_sound") == "on", r[0] + " " + r[1]);
                List<string> seen = new List<string>();
                for (int i = 0; i < 4; i++) { Thread.Sleep(800); r = Get("/api/do?c=mic&a=next"); o = Obj(r[1]); seen.Add(o == null ? "?" : (string)o["mic"]); }
                Ok("mic next x4: Headset, Realtek, Webcam, then round to Windows' default (empty)", string.Join(" | ", seen.ToArray()) == "Headset (Arctis 7P+) | Microphone (Realtek USB2.0 Audio) | Webcam Mic (C920) | ", string.Join(" | ", seen.ToArray()));
                r = Get("/api/do?c=mic&a=" + Uri.EscapeDataString("microphone (realtek usb2.0 audio)")); o = Obj(r[1]);
                Ok("mic by name (any case): 200, the stored name is the device's own", r[0] == "200" && o != null && (string)o["mic"] == "Microphone (Realtek USB2.0 Audio)" && IniHas(ini, "mic") == "Microphone (Realtek USB2.0 Audio)", r[0] + " " + r[1]);
                r = Get("/api/do?c=mic&a=" + Uri.EscapeDataString("Some Other Mic")); o = Obj(r[1]);
                Ok("an unknown mic name is refused: 400 {ok:false, say}, the ini unchanged", r[0] == "400" && o != null && !(bool)o["ok"] && IniHas(ini, "mic") == "Microphone (Realtek USB2.0 Audio)", r[0] + " " + r[1]);
                Thread.Sleep(800);
                r = Get("/api/do?c=mic&a=default"); o = Obj(r[1]);
                Ok("mic default: back to Windows' default (empty), say \"Mic: Windows' default\"", r[0] == "200" && (string)o["mic"] == "" && (string)o["say"] == "Mic: Windows' default" && IniHas(ini, "mic") == "", r[0] + " " + r[1]);
                Thread.Sleep(800);
                Get("/api/do?c=mic&a=next"); r = Get("/api/do?c=mic&a=next");
                Ok("a second NEXT within 0.7 s is the same press (irdash's repeat guard): the mic moved once", IniHas(ini, "mic") == "Headset (Arctis 7P+)", IniHas(ini, "mic"));
                Thread.Sleep(1500);
                o = Obj(Get("/state")[1]);
                Dictionary<string, object> sp = o != null && o.ContainsKey("settings") ? o["settings"] as Dictionary<string, object> : null;
                Ok("/state has the \"settings\" part with the same JSON (mic Headset) and the \"ac\" part (connected false here)", sp != null && (string)sp["mic"] == "Headset (Arctis 7P+)" && o.ContainsKey("ac") && o["ac"] is Dictionary<string, object> && !(bool)((Dictionary<string, object>)o["ac"])["connected"], o == null ? "no state" : string.Join(",", new List<string>(o.Keys).ToArray()));
            }
            catch (Exception ex) { Ok("the harness ran without an exception", false, ex.ToString()); }
            finally { try { Registry.CurrentUser.DeleteSubKeyTree(testRoot, false); } catch { } }
            using (RegistryKey gone = Registry.CurrentUser.OpenSubKey(testRoot)) Ok("the test key under HKCU is deleted", gone == null, "");
            Console.WriteLine("result: " + pass + " ok, " + fail + " FAIL");
            return fail > 0 ? 1 : 0;
        }
    }
}
