// irdeck sound (the SOUND screen on the Stream Deck): the level of the sim, of the spotter and of Spotify, the ButtKicker and the
// speakers as their own device levels, mute for each, and three presets. Windows' default device and every other Windows setting
// stay exactly as they are: only the volume / mute of the apps and devices named here is ever changed, and only by a key press.
//   sound status                  write <root>\sound\state.json (what the SOUND screen draws; irdash serves it as /sound)
//   sound set <target> <0-100>    set a level
//   sound step <target> <+10|-10> move it
//   sound mute <target> [on|off]  mute / unmute (no word = flip)
//   sound preset race|cruise|night
// targets: sim (iRacing and its menu app), spotter (CrewChief), music (Spotify), speakers and buttkicker (the devices' own level).
// An app that is not playing right now has no Windows audio session and cannot be set; its key says so.
// Tests: PADDOCK_SOUND_PRETEND=<file.json> swaps Windows for a pretend list of devices and apps (the file is read and written back),
// PADDOCK_SOUND_STATE=<file> moves state.json. Nothing of Windows is touched then.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

namespace IRDeck
{
    // Core Audio pieces the older appvol code did not need: a device's own volume / mute, its name, the default device
    [StructLayout(LayoutKind.Sequential)] struct PropKey { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Sequential)] struct PropVar { public ushort vt, r1, r2, r3; public IntPtr p, p2; }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint c);
        [PreserveSig] int GetAt(uint i, out PropKey k);
        [PreserveSig] int GetValue(ref PropKey key, out PropVar v);
    }
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr n);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr n);
        [PreserveSig] int GetChannelCount(out uint n);
        [PreserveSig] int SetMasterVolumeLevel(float db, ref Guid ctx);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
        [PreserveSig] int GetMasterVolumeLevel(out float db);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint ch, float db, ref Guid ctx);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float level, ref Guid ctx);
        [PreserveSig] int GetChannelVolumeLevel(uint ch, out float db);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    static partial class Program
    {
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVar v);

        sealed class SndApp { public string Proc = ""; public float Vol; public bool Mute; public Action<float> SetVol; public Action<bool> SetMute; }
        sealed class SndDev
        {
            public string Name = ""; public float Vol = -1; public bool Mute, Default; public Action<float> SetVol; public Action<bool> SetMute;
            public List<SndApp> Apps = new List<SndApp>();
        }
        sealed class SndStep { public string Target; public int Level; public bool AtMost; public int Mute; }   // Level -1 = leave; Mute 1 = muted, 0 = sound on, -1 = leave

        static readonly string[] SndTargets = { "sim", "spotter", "music", "speakers", "buttkicker" };
        static readonly string[] SndPresetNames = { "race", "cruise", "night" };

        static string[] SndProcs(string id)
        {
            if (id == "sim") return new string[] { "iRacingSim64DX11", "iRacingUI" };
            if (id == "spotter") return new string[] { "CrewChiefV4" };
            if (id == "music") return new string[] { "Spotify" };
            return new string[0];
        }

        static SndStep SndSt(string target, int level, bool atMost, int mute)
        {
            SndStep s = new SndStep(); s.Target = target; s.Level = level; s.AtMost = atMost; s.Mute = mute; return s;
        }

        // RACE: the spotter loud and clear, the music off. CRUISE: music on, the spotter low. NIGHT: everything lower (never louder).
        static SndStep[] SndPreset(string name)
        {
            switch (name)
            {
                case "race": return new SndStep[] { SndSt("sim", 80, false, 0), SndSt("spotter", 100, false, 0), SndSt("music", -1, false, 1) };
                case "cruise": return new SndStep[] { SndSt("sim", 60, false, 0), SndSt("spotter", 40, false, 0), SndSt("music", 60, false, 0) };
                case "night": return new SndStep[] { SndSt("sim", 35, true, -1), SndSt("spotter", 45, true, -1), SndSt("music", 20, true, -1), SndSt("buttkicker", 25, true, -1) };
            }
            return null;
        }

        // ---------------- reading ----------------

        static List<SndDev> SndRead()
        {
            string pretend = Environment.GetEnvironmentVariable("PADDOCK_SOUND_PRETEND");
            if (!string.IsNullOrEmpty(pretend)) return SndReadPretend(pretend);
            return SndReadWindows();
        }

        static string SndName(IMMDevice dev)
        {
            try
            {
                IPropertyStore ps; if (dev.OpenPropertyStore(0, out ps) != 0 || ps == null) return "";
                PropKey k = new PropKey(); k.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); k.pid = 14;   // PKEY_Device_FriendlyName
                PropVar v; if (ps.GetValue(ref k, out v) != 0) return "";
                string s = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : "";
                PropVariantClear(ref v);
                return s ?? "";
            }
            catch { return ""; }
        }

        static List<SndDev> SndReadWindows()
        {
            List<SndDev> list = new List<SndDev>();
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            string defName = "";
            IMMDevice dd; if (en.GetDefaultAudioEndpoint(0, 1, out dd) == 0 && dd != null) defName = SndName(dd);
            IMMDeviceCollection devs; if (en.EnumAudioEndpoints(0, 1, out devs) != 0) return list;
            int n; devs.GetCount(out n);
            Guid epIid = typeof(IAudioEndpointVolume).GUID, smIid = typeof(IAudioSessionManager2).GUID;
            Dictionary<uint, string> names = new Dictionary<uint, string>();
            for (int i = 0; i < n; i++)
            {
                IMMDevice dev; if (devs.Item(i, out dev) != 0 || dev == null) continue;
                SndDev d = new SndDev(); d.Name = SndName(dev); d.Default = d.Name.Length > 0 && d.Name == defName;
                object o;
                if (dev.Activate(ref epIid, 23, IntPtr.Zero, out o) == 0 && o != null)
                {
                    IAudioEndpointVolume ep = (IAudioEndpointVolume)o;
                    float v; bool m;
                    if (ep.GetMasterVolumeLevelScalar(out v) == 0) d.Vol = v;
                    if (ep.GetMute(out m) == 0) d.Mute = m;
                    d.SetVol = delegate (float x) { Guid g = Guid.Empty; ep.SetMasterVolumeLevelScalar(x, ref g); };
                    d.SetMute = delegate (bool x) { Guid g = Guid.Empty; ep.SetMute(x, ref g); };
                }
                object sm;
                if (dev.Activate(ref smIid, 23, IntPtr.Zero, out sm) == 0 && sm != null)
                {
                    IAudioSessionEnumerator se;
                    if (((IAudioSessionManager2)sm).GetSessionEnumerator(out se) == 0)
                    {
                        int cnt; se.GetCount(out cnt);
                        for (int j = 0; j < cnt; j++)
                        {
                            IAudioSessionControl2 ctl; if (se.GetSession(j, out ctl) != 0 || ctl == null) continue;
                            uint pid; ctl.GetProcessId(out pid);
                            if (pid == 0) continue;   // the Windows system sounds
                            string pn;
                            if (!names.TryGetValue(pid, out pn)) { pn = ""; try { pn = Process.GetProcessById((int)pid).ProcessName; } catch { } names[pid] = pn; }
                            if (pn.Length == 0) continue;
                            ISimpleAudioVolume sv = (ISimpleAudioVolume)ctl;
                            SndApp a = new SndApp(); a.Proc = pn;
                            float av; bool am;
                            if (sv.GetMasterVolume(out av) == 0) a.Vol = av;
                            if (sv.GetMute(out am) == 0) a.Mute = am;
                            a.SetVol = delegate (float x) { Guid g = Guid.Empty; sv.SetMasterVolume(x, ref g); };
                            a.SetMute = delegate (bool x) { Guid g = Guid.Empty; sv.SetMute(x, ref g); };
                            d.Apps.Add(a);
                        }
                    }
                }
                list.Add(d);
            }
            return list;
        }

        // the pretend list: { "default": "...", "devices": [ { "name", "vol", "mute", "apps": [ { "proc", "vol", "mute" } ] } ] }
        static Dictionary<string, object> sndPretendRoot; static string sndPretendPath;

        static List<SndDev> SndReadPretend(string path)
        {
            List<SndDev> list = new List<SndDev>();
            sndPretendPath = path;
            sndPretendRoot = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path)) as Dictionary<string, object>;
            if (sndPretendRoot == null) return list;
            string def = sndPretendRoot.ContainsKey("default") ? Convert.ToString(sndPretendRoot["default"]) : "";
            System.Collections.IList arr = sndPretendRoot.ContainsKey("devices") ? sndPretendRoot["devices"] as System.Collections.IList : null;
            if (arr == null) return list;
            foreach (object od in arr)
            {
                Dictionary<string, object> dj = od as Dictionary<string, object>; if (dj == null) continue;
                SndDev d = new SndDev(); d.Name = Convert.ToString(dj["name"]); d.Default = d.Name == def;
                d.Vol = (float)Convert.ToDouble(dj["vol"], CultureInfo.InvariantCulture); d.Mute = dj.ContainsKey("mute") && Convert.ToBoolean(dj["mute"]);
                d.SetVol = delegate (float x) { dj["vol"] = Math.Round(x, 3); }; d.SetMute = delegate (bool x) { dj["mute"] = x; };
                System.Collections.IList apps = dj.ContainsKey("apps") ? dj["apps"] as System.Collections.IList : null;
                if (apps != null)
                    foreach (object oa in apps)
                    {
                        Dictionary<string, object> aj = oa as Dictionary<string, object>; if (aj == null) continue;
                        SndApp a = new SndApp(); a.Proc = Convert.ToString(aj["proc"]);
                        a.Vol = (float)Convert.ToDouble(aj["vol"], CultureInfo.InvariantCulture); a.Mute = aj.ContainsKey("mute") && Convert.ToBoolean(aj["mute"]);
                        a.SetVol = delegate (float x) { aj["vol"] = Math.Round(x, 3); }; a.SetMute = delegate (bool x) { aj["mute"] = x; };
                        d.Apps.Add(a);
                    }
                list.Add(d);
            }
            return list;
        }

        static void SndSavePretend()
        {
            if (sndPretendRoot != null && sndPretendPath != null) File.WriteAllText(sndPretendPath, new JavaScriptSerializer().Serialize(sndPretendRoot), new UTF8Encoding(false));
        }

        // ---------------- which device is which ----------------

        static bool SndHas(SndDev d, string[] procs)
        {
            foreach (SndApp a in d.Apps) foreach (string p in procs) if (p.Equals(a.Proc, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        // the ButtKicker's own output: a device with its name on it (the real amp, not the virtual input the software listens on)
        static SndDev SndButtKicker(List<SndDev> devs)
        {
            SndDev any = null;
            foreach (SndDev d in devs)
            {
                if (d.Name.IndexOf("buttkicker", StringComparison.OrdinalIgnoreCase) < 0 && d.Name.IndexOf("butt kicker", StringComparison.OrdinalIgnoreCase) < 0) continue;
                if (any == null) any = d;
                if (d.Name.IndexOf("virtual", StringComparison.OrdinalIgnoreCase) < 0 && d.Name.IndexOf("input", StringComparison.OrdinalIgnoreCase) < 0) return d;
            }
            return any;
        }

        // the speakers: where the sim or the spotter is playing right now, else the Realtek speakers, else the first device that is not the ButtKicker
        static SndDev SndSpeakers(List<SndDev> devs)
        {
            SndDev bk = SndButtKicker(devs);
            foreach (SndDev d in devs) if (d != bk && (SndHas(d, SndProcs("sim")) || SndHas(d, SndProcs("spotter")))) return d;
            foreach (SndDev d in devs) if (d != bk && d.Name.IndexOf("realtek", StringComparison.OrdinalIgnoreCase) >= 0) return d;
            foreach (SndDev d in devs) if (d != bk) return d;
            return null;
        }

        static List<SndApp> SndAppsOf(List<SndDev> devs, string id)
        {
            List<SndApp> r = new List<SndApp>(); string[] procs = SndProcs(id);
            foreach (SndDev d in devs)
                foreach (SndApp a in d.Apps)
                    foreach (string p in procs) if (p.Equals(a.Proc, StringComparison.OrdinalIgnoreCase)) { r.Add(a); break; }
            return r;
        }

        // ---------------- changing ----------------

        static float SndClamp(double v) { return (float)Math.Max(0.0, Math.Min(1.0, v)); }

        // vol: 0..1, or NaN = leave; atMost: never louder than vol; mute: 1 / 0 / -1 = leave; relative: vol is a step to add. Returns how many sessions / devices were touched.
        static int SndApply(List<SndDev> devs, string id, double vol, bool atMost, int mute, bool relative)
        {
            int touched = 0;
            if (id == "speakers" || id == "buttkicker")
            {
                SndDev d = id == "speakers" ? SndSpeakers(devs) : SndButtKicker(devs);
                if (d == null || d.SetVol == null) return 0;
                if (!double.IsNaN(vol)) { float nv = relative ? SndClamp(d.Vol + vol) : atMost ? Math.Min(d.Vol, SndClamp(vol)) : SndClamp(vol); d.SetVol(nv); d.Vol = nv; }
                if (mute >= 0) { d.SetMute(mute == 1); d.Mute = mute == 1; }
                return 1;
            }
            foreach (SndApp a in SndAppsOf(devs, id))
            {
                if (!double.IsNaN(vol)) { float nv = relative ? SndClamp(a.Vol + vol) : atMost ? Math.Min(a.Vol, SndClamp(vol)) : SndClamp(vol); a.SetVol(nv); a.Vol = nv; }
                if (mute >= 0) { a.SetMute(mute == 1); a.Mute = mute == 1; }
                touched++;
            }
            return touched;
        }

        static bool SndMuted(List<SndDev> devs, string id)
        {
            if (id == "speakers" || id == "buttkicker") { SndDev d = id == "speakers" ? SndSpeakers(devs) : SndButtKicker(devs); return d != null && d.Mute; }
            List<SndApp> apps = SndAppsOf(devs, id);
            if (apps.Count == 0) return false;
            foreach (SndApp a in apps) if (!a.Mute) return false;
            return true;
        }

        // ---------------- the state the screen draws ----------------

        static string SndJ(string s)
        {
            StringBuilder sb = new StringBuilder("\"");
            foreach (char c in s ?? "") { if (c == '"' || c == '\\') sb.Append('\\').Append(c); else if (c < ' ') sb.Append(' '); else sb.Append(c); }
            return sb.Append('"').ToString();
        }

        static int SndPct(float v) { return (int)Math.Round(v * 100.0); }

        // which preset the levels match right now ("" = none). Only when the sim and the spotter are both playing: with the sim off nothing is "RACE".
        static string SndPresetNow(List<SndDev> devs)
        {
            float v0; bool m0;
            if (!SndLevel(devs, "sim", out v0, out m0) || !SndLevel(devs, "spotter", out v0, out m0)) return "";
            foreach (string name in SndPresetNames)
            {
                int live = 0; bool ok = true;
                foreach (SndStep s in SndPreset(name))
                {
                    float vol; bool mute; bool has = SndLevel(devs, s.Target, out vol, out mute);
                    if (!has) continue;
                    live++;
                    if (s.Level >= 0 && (s.AtMost ? SndPct(vol) > s.Level + 4 : Math.Abs(SndPct(vol) - s.Level) > 4)) ok = false;
                    if (s.Mute == 1 && !mute) ok = false;
                    if (s.Mute == 0 && mute) ok = false;
                }
                if (ok && live > 0) return name;
            }
            return "";
        }

        // the level and mute of a target; false when it is not there / not playing
        static bool SndLevel(List<SndDev> devs, string id, out float vol, out bool mute)
        {
            vol = 0; mute = false;
            if (id == "speakers" || id == "buttkicker")
            {
                SndDev d = id == "speakers" ? SndSpeakers(devs) : SndButtKicker(devs);
                if (d == null || d.Vol < 0) return false;
                vol = d.Vol; mute = d.Mute; return true;
            }
            List<SndApp> apps = SndAppsOf(devs, id);
            if (apps.Count == 0) return false;
            vol = apps[0].Vol; mute = SndMuted(devs, id);
            return true;
        }

        static string SndStatusJson(List<SndDev> devs)
        {
            CultureInfo inv = CultureInfo.InvariantCulture;
            string[] names = { "GAME", "SPOTTER", "MUSIC", "SPEAKERS", "BUTTKICKER" };
            StringBuilder sb = new StringBuilder("{\"ok\":true,\"at\":" + (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds + ",\"pretend\":" + (sndPretendRoot != null ? "true" : "false"));
            sb.Append(",\"items\":[");
            for (int i = 0; i < SndTargets.Length; i++)
            {
                string id = SndTargets[i]; float vol; bool mute; bool live = SndLevel(devs, id, out vol, out mute);
                string where = "";
                if (id == "speakers" || id == "buttkicker") { SndDev d = id == "speakers" ? SndSpeakers(devs) : SndButtKicker(devs); where = d == null ? "" : d.Name; }
                else foreach (SndDev d in devs) if (SndHas(d, SndProcs(id))) { where = d.Name; break; }
                if (i > 0) sb.Append(',');
                sb.Append("{\"id\":" + SndJ(id) + ",\"name\":" + SndJ(names[i]) + ",\"kind\":" + SndJ(i < 3 ? "app" : "device") + ",\"live\":" + (live ? "true" : "false") + ",\"vol\":" + (live ? SndPct(vol).ToString(inv) : "0") + ",\"mute\":" + (mute ? "true" : "false") + ",\"device\":" + SndJ(where) + "}");
            }
            sb.Append("]");
            SndDev dflt = null; foreach (SndDev d in devs) if (d.Default) dflt = d;
            SndDev sp = SndSpeakers(devs);
            sb.Append(",\"default\":" + SndJ(dflt == null ? "" : dflt.Name) + ",\"using\":" + SndJ(sp == null ? "" : sp.Name) + ",\"preset\":" + SndJ(SndPresetNow(devs)) + ",\"devices\":" + devs.Count + "}");
            return sb.ToString();
        }

        static string SndStatePath()
        {
            string o = Environment.GetEnvironmentVariable("PADDOCK_SOUND_STATE");
            return string.IsNullOrEmpty(o) ? Path.Combine(Root, @"sound\state.json") : o;
        }

        static void SndWriteState(string json)
        {
            string f = SndStatePath(), tmp = f + ".tmp";
            Directory.CreateDirectory(Path.GetDirectoryName(f));
            File.WriteAllText(tmp, json, new UTF8Encoding(false));
            try { if (File.Exists(f)) File.Replace(tmp, f, null); else File.Move(tmp, f); }
            catch { try { File.Copy(tmp, f, true); File.Delete(tmp); } catch { } }   // a reader had it open: plain copy
        }

        // ---------------- the command ----------------

        static int CmdSound(string[] a)
        {
            string sub = a.Length > 0 ? a[0].ToLowerInvariant() : "status";
            List<SndDev> devs;
            try { devs = SndRead(); }
            catch (Exception ex) { Log("sound: cannot read the audio devices: " + ex.Message); return 1; }
            string target = a.Length > 1 ? a[1].ToLowerInvariant() : "";
            bool known = Array.IndexOf(SndTargets, target) >= 0;
            switch (sub)
            {
                case "status": break;
                case "devices":   // for people: every active output device with its level and the apps playing on it
                    foreach (SndDev d in devs)
                    {
                        List<string> ap = new List<string>(); foreach (SndApp x in d.Apps) ap.Add(x.Proc + " " + SndPct(x.Vol) + "%" + (x.Mute ? " muted" : ""));
                        Log("sound device: " + d.Name + (d.Default ? " (Windows default)" : "") + "  " + (d.Vol < 0 ? "no level" : SndPct(d.Vol) + "%" + (d.Mute ? " muted" : "")) + "  apps: " + (ap.Count == 0 ? "none" : string.Join(", ", ap.ToArray())));
                    }
                    return 0;
                case "set":
                case "step":
                    {
                        double n;
                        if (!known || a.Length < 3 || !double.TryParse(a[2], NumberStyles.Float, CultureInfo.InvariantCulture, out n)) { Log("sound " + sub + ": need a target (" + string.Join("|", SndTargets) + ") and a number"); return 1; }
                        int t = SndApply(devs, target, n / 100.0, false, -1, sub == "step");
                        Log(t == 0 ? "sound: " + target + " is not playing right now, nothing changed" : "sound " + sub + " " + target + " " + a[2]);
                        break;
                    }
                case "mute":
                    {
                        if (!known) { Log("sound mute: need a target (" + string.Join("|", SndTargets) + ")"); return 1; }
                        string how = a.Length > 2 ? a[2].ToLowerInvariant() : "";
                        int want = how == "on" ? 1 : how == "off" ? 0 : (SndMuted(devs, target) ? 0 : 1);
                        int t = SndApply(devs, target, double.NaN, false, want, false);
                        Log(t == 0 ? "sound: " + target + " is not playing right now, nothing changed" : "sound " + target + (want == 1 ? " muted" : " sound on"));
                        break;
                    }
                case "preset":
                    {
                        SndStep[] steps = SndPreset(target);
                        if (steps == null) { Log("sound preset: need race|cruise|night"); return 1; }
                        int t = 0;
                        foreach (SndStep s in steps) t += SndApply(devs, s.Target, s.Level < 0 ? double.NaN : s.Level / 100.0, s.AtMost, s.Mute, false);
                        Log("sound preset " + target + ": " + t + " item(s) set");
                        break;
                    }
                default: Log("sound: need status|set|step|mute|preset"); return 1;
            }
            if (sub != "status") { SndSavePretend(); try { devs = SndRead(); } catch { } }   // the screen shows what is really there now
            string json = SndStatusJson(devs);
            SndWriteState(json);
#if CLI
            if (sub == "status") Console.WriteLine(json);
#endif
            return 0;
        }
    }
}
