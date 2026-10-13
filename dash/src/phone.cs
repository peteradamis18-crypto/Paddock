// The iPhone app's server side (P1, docs\PLAN-v3.md): Paddock on Peter's phone over the home Wi-Fi.
//   - LAN listeners. irdash listens on the LAN address ONLY after Peter's one-time permission: tools\phone-allow.cmd (his double-click,
//     UAC) adds the firewall rule and writes dash\phone-allowed.txt. Paddock never changes Windows itself. The flag is re-read every
//     30 s, so no restart is needed; tools\phone-undo.cmd removes it all and the listeners stop by themselves.
//   - Pairing. Anything that does not come from this PC needs a token. The top screen asks /phone/qr (localhost only) for a one-time
//     6-digit code and draws the QR (the app URL + the code). The phone opens /phone/?pair=<code>, calls /phone/pair, gets a token
//     (kept as a SHA-256 in dash\phone-tokens.txt; the phone keeps the raw one) and sends it back as a cookie, a header or ?t=.
//     Tokens can be revoked (/phone/revoke). The test hook routes are never reachable from the LAN, token or not.
//   - ?asphone=1 on any request makes irdash treat it as if it came from the LAN (stricter, never looser): tests\phone-test.ps1 uses it.
//   - /api/do?c=key&a=<name> runs keys\<name>.exe: the very same exe the Stream Deck MAIN/MORE key runs (keys.map, the 0.7 s repeat
//     guard, the x2 confirm). The phone can never do what the deck cannot.
//   - The QR code is written here (byte mode, level M, versions 1-6, the ISO 18004 layout). No library: Paddock uses none.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static class Phone
    {
        static string rootDir, dashDir;
        static readonly object gate = new object();
        static readonly Dictionary<string, TcpListener> listeners = new Dictionary<string, TcpListener>();   // ip -> listener
        static readonly List<Device> devices = new List<Device>();
        static string code; static DateTime codeUntil = DateTime.MinValue; static bool codeUsed; static int codeUses;
        static string lastPaired = ""; static DateTime lastPairedAt = DateTime.MinValue;
        static string healthCache = ""; static DateTime healthAt = DateTime.MinValue;
        static Dictionary<string, string> keyMap; static DateTime keyMapAt = DateTime.MinValue;
        static readonly Regex NameRx = new Regex("^[A-Za-z0-9 ._'-]{1,24}$");

        sealed class Device { public string Id = "", Hash = "", Name = ""; public DateTime Since, Seen; }

        public static void Init(string root, string dash)
        {
            rootDir = root; dashDir = dash;
            LoadDevices();
        }

        // ---------------- files ----------------
        static string FlagFile { get { return Path.Combine(dashDir, "phone-allowed.txt"); } }
        static string TokenFile { get { return Path.Combine(dashDir, "phone-tokens.txt"); } }
        public static bool Allowed { get { try { return File.Exists(FlagFile); } catch { return false; } } }

        static void LoadDevices()
        {
            lock (gate)
            {
                devices.Clear();
                try
                {
                    if (!File.Exists(TokenFile)) return;
                    foreach (string l in File.ReadAllLines(TokenFile))
                    {
                        string[] p = l.Split('\t');
                        if (p.Length < 5 || p[1].Length != 64) continue;
                        Device d = new Device(); d.Id = p[0]; d.Hash = p[1]; d.Name = p[2];
                        long t; d.Since = long.TryParse(p[3], out t) ? new DateTime(t, DateTimeKind.Utc) : DateTime.UtcNow;
                        d.Seen = long.TryParse(p[4], out t) ? new DateTime(t, DateTimeKind.Utc) : d.Since;
                        devices.Add(d);
                    }
                }
                catch (Exception ex) { Log.W("phone: tokens: " + ex.Message); }
            }
        }

        static void SaveDevices()
        {
            lock (gate)
            {
                try
                {
                    StringBuilder sb = new StringBuilder();
                    foreach (Device d in devices) sb.Append(d.Id).Append('\t').Append(d.Hash).Append('\t').Append(d.Name).Append('\t').Append(d.Since.Ticks).Append('\t').Append(d.Seen.Ticks).Append("\r\n");
                    File.WriteAllText(TokenFile, sb.ToString());
                }
                catch (Exception ex) { Log.W("phone: tokens: " + ex.Message); }
            }
        }

        static string Sha(string s)
        {
            using (SHA256 h = SHA256.Create())
            {
                byte[] b = h.ComputeHash(Encoding.UTF8.GetBytes(s));
                StringBuilder sb = new StringBuilder(64);
                foreach (byte x in b) sb.Append(x.ToString("x2"));
                return sb.ToString();
            }
        }

        static string RandomHex(int bytes)
        {
            byte[] b = new byte[bytes];
            using (RNGCryptoServiceProvider r = new RNGCryptoServiceProvider()) r.GetBytes(b);
            StringBuilder sb = new StringBuilder(bytes * 2);
            foreach (byte x in b) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }

        // ---------------- LAN listeners (called by the server every 30 s and once at start) ----------------
        public static List<string> LocalIps()
        {
            List<string> ips = new List<string>();
            try
            {
                foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback || ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                    foreach (UnicastIPAddressInformation u in ni.GetIPProperties().UnicastAddresses)
                    {
                        if (u.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        byte[] b = u.Address.GetAddressBytes();
                        bool priv = b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);   // home networks only
                        if (priv && !ips.Contains(u.Address.ToString())) ips.Add(u.Address.ToString());
                    }
                }
            }
            catch (Exception ex) { Log.W("phone: ips: " + ex.Message); }
            return ips;
        }

        public static void Sync(int port, Action<TcpClient> handle)
        {
            // irdash starts this loop before Phone.Init has set the folders (irdash.cs): the first pass does nothing, the next one (30 s later) does the work
            if (dashDir == null) return;
            List<string> want = Allowed ? LocalIps() : new List<string>();
            lock (gate)
            {
                if (devices.Count > 0 && !File.Exists(TokenFile)) { devices.Clear(); Log.W("phone: every paired phone forgotten (tools\\phone-undo.cmd)"); }
                else if (devices.Count == 0 && File.Exists(TokenFile)) LoadDevices();
                List<string> gone = new List<string>();
                foreach (string ip in listeners.Keys) if (!want.Contains(ip)) gone.Add(ip);
                foreach (string ip in gone)
                {
                    try { listeners[ip].Stop(); } catch { }
                    listeners.Remove(ip);
                    Log.W("phone: stopped listening on " + ip + ":" + port + (Allowed ? " (address gone)" : " (permission removed: tools\\phone-undo.cmd)"));
                }
                foreach (string ip in want)
                {
                    if (listeners.ContainsKey(ip)) continue;
                    try
                    {
                        TcpListener l = new TcpListener(IPAddress.Parse(ip), port);
                        l.Start();
                        listeners[ip] = l;
                        Thread t = new Thread(delegate ()
                        {
                            while (true)
                            {
                                TcpClient c;
                                try { c = l.AcceptTcpClient(); } catch { break; }   // Stop() ends the loop
                                Thread h = new Thread(delegate () { handle(c); }); h.IsBackground = true; h.Start();
                            }
                        });
                        t.IsBackground = true; t.Start();
                        Log.W("phone: listening on " + ip + ":" + port + " (LAN, paired phones only)");
                    }
                    catch (Exception ex) { Log.W("phone: cannot listen on " + ip + ":" + port + ": " + ex.Message); }
                }
            }
        }

        public static bool LanOn { get { lock (gate) return listeners.Count > 0; } }
        public static string LanIp { get { lock (gate) { foreach (string ip in listeners.Keys) return ip; } List<string> l = LocalIps(); return l.Count > 0 ? l[0] : ""; } }
        public static bool IsOurHost(string host, int port)
        {
            if (host == null) return false;
            lock (gate) return listeners.ContainsKey(host.EndsWith(":" + port) ? host.Substring(0, host.Length - (":" + port).Length) : "");
        }
        public static string AppUrl(int port) { string ip = LanIp; return ip.Length == 0 ? "" : "http://" + ip + ":" + port + "/phone/"; }

        // ---------------- the gate ----------------
        public static bool IsLocal(TcpClient c)
        {
            try { return IPAddress.IsLoopback(((IPEndPoint)c.Client.RemoteEndPoint).Address); } catch { return false; }
        }

        // what a phone may fetch before it is paired: the app itself and the pairing call
        public static bool Open(string path)
        {
            return path == "/phone" || path == "/phone/" || path == "/phone/pair" ||
                   Regex.IsMatch(path, "^/phone/(index\\.html|app\\.css|app\\.js|icon\\.png|manifest\\.webmanifest)$");
        }

        // never from the LAN, token or not
        public static bool Hidden(string path, string method)
        {
            return method != "GET" || path.StartsWith("/api/test/", StringComparison.Ordinal) || path.StartsWith("/vault/test/", StringComparison.Ordinal) ||
                   path == "/api/open" || path == "/phone/qr" || path.StartsWith("/maps/", StringComparison.Ordinal) ||
                   path == "/share/open" || path == "/share/jump" || path.StartsWith("/share/test/", StringComparison.Ordinal);      // share studio: the folder and the sim's replay are this PC's business
        }

        public static bool TokenOk(Dictionary<string, string> q, Dictionary<string, string> hdr)
        {
            string tok = null;
            if (hdr != null) hdr.TryGetValue("X-Paddock-Token", out tok);
            if (string.IsNullOrEmpty(tok) && q != null) q.TryGetValue("t", out tok);
            if (string.IsNullOrEmpty(tok) && hdr != null)
            {
                string ck; if (hdr.TryGetValue("Cookie", out ck))
                    foreach (string part in ck.Split(';')) { string p = part.Trim(); if (p.StartsWith("pt=")) { tok = p.Substring(3); break; } }
            }
            if (string.IsNullOrEmpty(tok) || !Regex.IsMatch(tok, "^[0-9a-f]{48}$")) return false;
            string h = Sha(tok);
            lock (gate)
            {
                foreach (Device d in devices)
                    if (d.Hash == h)
                    {
                        if ((DateTime.UtcNow - d.Seen).TotalMinutes > 5) { d.Seen = DateTime.UtcNow; SaveDevices(); }
                        return true;
                    }
            }
            return false;
        }

        // ---------------- routes: /phone/* (static files fall through when this returns null) ----------------
        public static string Route(string path, Dictionary<string, string> q, Dictionary<string, string> hdr, bool local, int port, out int code, out string extra)
        {
            code = 200; extra = "Access-Control-Allow-Origin: *\r\n";
            switch (path)
            {
                case "/phone/state": return StateJson(port);
                case "/phone/qr":
                    if (!local) { code = 404; return "{\"error\":\"not found\"}"; }
                    return QrJson(port, q);
                case "/phone/pair":
                    {
                        string c, name, ua; q.TryGetValue("code", out c); q.TryGetValue("name", out name); hdr.TryGetValue("User-Agent", out ua);
                        string id; string tok = Pair(c ?? "", name, ua ?? "", out name, out id);
                        if (tok == null) { code = 403; return "{\"ok\":false,\"why\":\"That code is not right or has expired. Scan the code on the top screen again.\"}"; }
                        extra += "Set-Cookie: pt=" + tok + "; Path=/; Max-Age=31536000; SameSite=Lax\r\n";
                        return "{\"ok\":true,\"token\":" + Json_.S(tok) + ",\"name\":" + Json_.S(name) + ",\"id\":" + Json_.S(id) + "}";
                    }
                case "/phone/devices": return DevicesJson();
                case "/phone/revoke":
                    {
                        string id; q.TryGetValue("id", out id);
                        int n = Revoke(q.ContainsKey("all") ? null : (id ?? ""));
                        return "{\"ok\":true,\"removed\":" + n + "}";
                    }
            }
            return null;
        }

        static string Pair(string c, string name, string ua, out string finalName, out string id)
        {
            finalName = ""; id = "";
            lock (gate)
            {
                if (code == null || codeUsed || DateTime.UtcNow > codeUntil || c.Trim() != code) { Log.W("phone: pairing refused (code " + (c.Length > 0 ? "wrong" : "missing") + ")"); return null; }
                // Safari and the Home Screen app keep separate storage, so one code may pair up to 3 times in its 10 minutes
                if (++codeUses >= 3) codeUsed = true;
                string tok = RandomHex(24);
                Device d = new Device();
                d.Id = RandomHex(4); d.Hash = Sha(tok); d.Since = d.Seen = DateTime.UtcNow;
                if (name == null || !NameRx.IsMatch(name)) name = ua.Contains("iPad") ? "iPad" : ua.Contains("iPhone") ? "iPhone" : ua.Contains("Android") ? "Android phone" : "Phone";
                d.Name = name; devices.Add(d);
                SaveDevices();
                lastPaired = name; lastPairedAt = DateTime.UtcNow;
                finalName = name; id = d.Id;
                Log.W("phone: paired " + name + " (" + d.Id + ")");
                return tok;
            }
        }

        static int Revoke(string id)
        {
            lock (gate)
            {
                int n = devices.RemoveAll(delegate (Device d) { return id == null || d.Id == id; });
                if (n > 0) { SaveDevices(); Log.W("phone: forgot " + n + " phone(s)" + (id == null ? "" : " (" + id + ")")); }
                return n;
            }
        }

        static string DevicesJson()
        {
            lock (gate)
            {
                StringBuilder sb = new StringBuilder("{\"devices\":[");
                for (int i = 0; i < devices.Count; i++)
                {
                    Device d = devices[i];
                    if (i > 0) sb.Append(',');
                    sb.Append("{\"id\":").Append(Json_.S(d.Id)).Append(",\"name\":").Append(Json_.S(d.Name)).Append(",\"since\":").Append(Json_.S(d.Since.ToLocalTime().ToString("d MMM yyyy", CultureInfo.InvariantCulture)))
                      .Append(",\"seen\":").Append(Json_.S(Ago(d.Seen))).Append('}');
                }
                return sb.Append("]}").ToString();
            }
        }

        static string Ago(DateTime utc)
        {
            TimeSpan t = DateTime.UtcNow - utc;
            if (t.TotalMinutes < 2) return "now";
            if (t.TotalHours < 1) return (int)t.TotalMinutes + " min ago";
            if (t.TotalDays < 1) return (int)t.TotalHours + " h ago";
            return (int)t.TotalDays + " days ago";
        }

        // what the top screen shows: the state of the LAN permission and, when it is on, the QR code with a fresh one-time code
        public static string InfoJson(int port)
        {
            bool allowed = Allowed; string ip = LanIp;
            int n; lock (gate) n = devices.Count;
            return "{\"allowed\":" + (allowed ? "true" : "false") + ",\"lan\":" + (LanOn ? "true" : "false") + ",\"ip\":" + Json_.S(ip) +
                   ",\"url\":" + Json_.S(AppUrl(port)) + ",\"paired\":" + n + ",\"how\":" + Json_.S("tools\\phone-allow.cmd") + "}";
        }

        static string QrJson(int port, Dictionary<string, string> q)
        {
            string info = InfoJson(port);
            bool test = q.ContainsKey("test") && Sdk.TestHook;   // tests\phone-test.ps1: a code before the LAN permission exists (this route never answers the LAN)
            if ((!Allowed || !LanOn) && !test) return info;
            string url = AppUrl(port);
            if (url.Length == 0 || !LanOn) url = "http://127.0.0.1:" + port + "/phone/";
            lock (gate)
            {
                if (code == null || codeUsed || (codeUntil - DateTime.UtcNow).TotalSeconds < 60)
                {
                    using (RNGCryptoServiceProvider r = new RNGCryptoServiceProvider()) { byte[] b = new byte[4]; r.GetBytes(b); code = (100000 + (int)(BitConverter.ToUInt32(b, 0) % 900000u)).ToString(CultureInfo.InvariantCulture); }
                    codeUntil = DateTime.UtcNow.AddMinutes(10); codeUsed = false; codeUses = 0;
                }
                string text = url + "?pair=" + code;
                bool[][] m = Qr.Encode(text);
                StringBuilder sb = new StringBuilder(info.Substring(0, info.Length - 1));
                sb.Append(",\"url\":").Append(Json_.S(url)).Append(",\"text\":").Append(Json_.S(text)).Append(",\"code\":").Append(Json_.S(code))
                  .Append(",\"secs\":").Append((int)(codeUntil - DateTime.UtcNow).TotalSeconds);
                if (lastPaired.Length > 0 && (DateTime.UtcNow - lastPairedAt).TotalMinutes < 3) sb.Append(",\"justPaired\":").Append(Json_.S(lastPaired));
                sb.Append(",\"size\":").Append(m == null ? 0 : m.Length).Append(",\"rows\":[");
                if (m != null)
                    for (int y = 0; y < m.Length; y++)
                    {
                        if (y > 0) sb.Append(',');
                        sb.Append('"'); for (int x = 0; x < m.Length; x++) sb.Append(m[y][x] ? '1' : '0'); sb.Append('"');
                    }
                return sb.Append("]}").ToString();
            }
        }

        // ---------------- the phone's HOME: one small JSON every 2 s ----------------
        static string StateJson(int port)
        {
            Frame f = Sdk.Latest;
            bool connected = f.Connected, onTrack = connected && f.Num("IsOnTrack") != 0;
            string yaml = f.SessionYaml ?? "";
            string track = connected ? TrackMaps.YamlValue(yaml, "TrackDisplayName") : "";
            string car = connected ? MyCar(yaml) : "";
            string stype = connected ? SessionType(yaml, (int)f.Num("SessionNum")) : "";
            string health;
            lock (gate)
            {
                if ((DateTime.UtcNow - healthAt).TotalSeconds > 5) { healthCache = Watch.Json(connected); healthAt = DateTime.UtcNow; }   // process checks are not free: 5 s is plenty
                health = healthCache;
            }
            bool tow = false;
            try
            {
                string tw = Path.Combine(dashDir, "tow-wait.txt"); long ticks;
                if (File.Exists(tw) && long.TryParse(File.ReadAllText(tw).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out ticks)) tow = ticks > DateTime.UtcNow.Ticks;
            }
            catch { }
            var inv = CultureInfo.InvariantCulture;
            StringBuilder sb = new StringBuilder("{\"t\":").Append((long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds);
            sb.Append(",\"connected\":").Append(connected ? "true" : "false").Append(",\"onTrack\":").Append(onTrack ? "true" : "false").Append(",\"driving\":").Append(Program.IsDriving ? "true" : "false");
            sb.Append(",\"replay\":").Append(connected && f.Num("IsReplayPlaying") != 0 ? "true" : "false");
            sb.Append(",\"track\":").Append(Json_.S(track)).Append(",\"car\":").Append(Json_.S(car)).Append(",\"session\":").Append(Json_.S(stype));
            if (connected)
            {
                sb.Append(",\"pos\":").Append((int)f.Num("PlayerCarClassPosition")).Append(",\"lap\":").Append((int)f.Num("Lap")).Append(",\"inc\":").Append((int)f.Num("PlayerCarMyIncidentCount"));
                sb.Append(",\"speed\":").Append(Math.Round(f.Num("Speed") * 3.6)).Append(",\"fuel\":").Append(f.Num("FuelLevel").ToString("0.0", inv));
                sb.Append(",\"best\":").Append(f.Num("LapBestLapTime").ToString("0.000", inv)).Append(",\"last\":").Append(f.Num("LapLastLapTime").ToString("0.000", inv));
                sb.Append(",\"pits\":").Append(f.Num("OnPitRoad") != 0 ? "true" : "false");
            }
            sb.Append(",\"towWait\":").Append(tow ? "true" : "false");
            sb.Append(",\"health\":").Append(health);
            sb.Append(",\"nav\":").Append(Nav.Json());
            sb.Append(",\"phone\":").Append(InfoJson(port));
            return sb.Append('}').ToString();
        }

        static string MyCar(string yaml)
        {
            try
            {
                Match me = Regex.Match(yaml, @"DriverCarIdx:\s*(\d+)");
                if (!me.Success) return "";
                Match blk = Regex.Match(yaml, @"- CarIdx:\s*" + me.Groups[1].Value + @"\s*\r?\n((?:   [^\r\n]*\r?\n?)*)");
                if (!blk.Success) return "";
                Match cs = Regex.Match(blk.Groups[1].Value, @"CarScreenName:\s*(.+)");
                return cs.Success ? cs.Groups[1].Value.Trim() : "";
            }
            catch { return ""; }
        }

        static string SessionType(string yaml, int num)
        {
            try
            {
                Match m = Regex.Match(yaml, @"- SessionNum:\s*" + num + @"\s*\r?\n((?:   [^\r\n]*\r?\n?)*)");
                if (!m.Success) return "";
                Match t = Regex.Match(m.Groups[1].Value, @"SessionType:\s*(.+)");
                return t.Success ? t.Groups[1].Value.Trim() : "";
            }
            catch { return ""; }
        }

        // ---------------- /api/do?c=key&a=<deck key name>: the MAIN / MORE keys, the exact exe the deck runs ----------------
        public static bool Handles(string c) { return c == "key"; }

        static Dictionary<string, string> KeyMap()
        {
            lock (gate)
            {
                if (keyMap != null && (DateTime.UtcNow - keyMapAt).TotalSeconds < 60) return keyMap;
                var m = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                try
                {
                    foreach (string l in File.ReadAllLines(Path.Combine(rootDir, @"keys\keys.map")))
                    { int i = l.IndexOf('='); if (i > 0) m[l.Substring(0, i).Trim()] = l.Substring(i + 1).Trim(); }
                }
                catch (Exception ex) { Log.W("phone: keys.map: " + ex.Message); }
                keyMap = m; keyMapAt = DateTime.UtcNow;
                return m;
            }
        }

        // keys that make no sense from a phone while he is in the car (the deck's physical keys are his own choice)
        static readonly HashSet<string> NotWhileDriving = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "rig-on", "test-drive-last", "showcase", "sleep", "lock" };

        public static bool Do(string c, string a)
        {
            a = (a ?? "").Trim();
            if (!Regex.IsMatch(a, "^[a-z0-9-]{1,30}$")) return false;
            string cmd; if (!KeyMap().TryGetValue(a, out cmd)) { Log.W("phone: key '" + a + "' is not a deck key"); return false; }
            if (Program.IsDriving && NotWhileDriving.Contains(a)) { Log.W("phone: key '" + a + "' refused while driving"); return false; }
            string exe = Path.Combine(rootDir, @"keys\" + a + ".exe");
            if (!File.Exists(exe)) { Log.W("phone: " + exe + " is missing"); return false; }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exe);
                psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(exe);
                Process.Start(psi);     // the key logs itself in irdeck.log; START keys can run for minutes, so nobody waits
                Log.W("phone: key " + a + " (" + cmd + ")");
                return true;
            }
            catch (Exception ex) { Log.W("phone: key " + a + ": " + ex.Message); return false; }
        }
    }

    // ---------------- QR code writer: byte mode, error level M, versions 1-6 (up to 106 characters) ----------------
    // The layout follows ISO/IEC 18004 (and project-nayuki's reference, whose conventions these names keep: x = column, y = row).
    static class Qr
    {
        static readonly int[] EcPerBlock = { 0, 10, 16, 26, 18, 24, 16 };
        static readonly int[] NumBlocks = { 0, 1, 1, 1, 2, 2, 4 };
        static readonly int[] RawCodewords = { 0, 26, 44, 70, 100, 134, 172 };

        public static bool[][] Encode(string text)
        {
            byte[] data = Encoding.UTF8.GetBytes(text ?? "");
            int ver = 0;
            for (int v = 1; v <= 6; v++) if ((RawCodewords[v] - EcPerBlock[v] * NumBlocks[v]) * 8 >= 12 + data.Length * 8) { ver = v; break; }
            if (ver == 0) return null;
            int dataCw = RawCodewords[ver] - EcPerBlock[ver] * NumBlocks[ver];
            // bit stream: mode 0100, 8-bit count, the bytes, terminator, byte padding
            List<bool> bits = new List<bool>();
            AddBits(bits, 4, 4); AddBits(bits, data.Length, 8);
            foreach (byte b in data) AddBits(bits, b, 8);
            int cap = dataCw * 8;
            AddBits(bits, 0, Math.Min(4, cap - bits.Count));
            while (bits.Count % 8 != 0) bits.Add(false);
            for (int pad = 0xEC; bits.Count < cap; pad ^= 0xEC ^ 0x11) AddBits(bits, pad, 8);
            byte[] cw = new byte[dataCw];
            for (int i = 0; i < bits.Count; i++) if (bits[i]) cw[i >> 3] |= (byte)(1 << (7 - (i & 7)));
            byte[] all = Interleave(cw, ver);
            int size = ver * 4 + 17;
            bool[][] mod = new bool[size][]; bool[][] fn = new bool[size][];
            for (int i = 0; i < size; i++) { mod[i] = new bool[size]; fn[i] = new bool[size]; }
            DrawFunctions(mod, fn, ver);
            DrawCodewords(mod, fn, all);
            int best = 0; long bestPen = long.MaxValue;
            for (int m = 0; m < 8; m++)
            {
                Mask(mod, fn, m); DrawFormat(mod, fn, m);
                long p = Penalty(mod);
                if (p < bestPen) { bestPen = p; best = m; }
                Mask(mod, fn, m);   // undo (xor)
            }
            Mask(mod, fn, best); DrawFormat(mod, fn, best);
            return mod;
        }

        static void AddBits(List<bool> bits, int val, int n) { for (int i = n - 1; i >= 0; i--) bits.Add(((val >> i) & 1) != 0); }

        static byte[] Interleave(byte[] data, int ver)
        {
            int numBlocks = NumBlocks[ver], ecc = EcPerBlock[ver], raw = RawCodewords[ver];
            int numShort = numBlocks - raw % numBlocks, shortLen = raw / numBlocks;
            byte[] div = RsDivisor(ecc);
            List<byte[]> blocks = new List<byte[]>();
            for (int i = 0, k = 0; i < numBlocks; i++)
            {
                int dl = shortLen - ecc + (i < numShort ? 0 : 1);
                byte[] dat = new byte[dl]; Array.Copy(data, k, dat, 0, dl); k += dl;
                byte[] block = new byte[shortLen + 1]; Array.Copy(dat, block, dl);
                byte[] e = RsRemainder(dat, div); Array.Copy(e, 0, block, block.Length - ecc, ecc);
                blocks.Add(block);
            }
            byte[] res = new byte[raw]; int r = 0;
            for (int i = 0; i < blocks[0].Length; i++)
                for (int j = 0; j < blocks.Count; j++)
                    if (i != shortLen - ecc || j >= numShort) res[r++] = blocks[j][i];
            return res;
        }

        static byte[] RsDivisor(int degree)
        {
            byte[] res = new byte[degree]; res[degree - 1] = 1; int root = 1;
            for (int i = 0; i < degree; i++)
            {
                for (int j = 0; j < degree; j++) { res[j] = (byte)(Mul(res[j], root) ^ (j + 1 < degree ? res[j + 1] : 0)); }
                root = Mul(root, 2);
            }
            return res;
        }

        public static byte[] RsRemainder(byte[] data, byte[] div)
        {
            byte[] res = new byte[div.Length];
            foreach (byte b in data)
            {
                int factor = b ^ res[0];
                Array.Copy(res, 1, res, 0, res.Length - 1); res[res.Length - 1] = 0;
                for (int i = 0; i < res.Length; i++) res[i] ^= (byte)Mul(div[i], factor);
            }
            return res;
        }

        static int Mul(int x, int y)
        {
            int z = 0;
            for (int i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >> 7) * 0x11D); z ^= ((y >> i) & 1) * x; }
            return z & 0xFF;
        }

        static void Set(bool[][] mod, bool[][] fn, int x, int y, bool dark) { mod[y][x] = dark; fn[y][x] = true; }

        static void DrawFunctions(bool[][] mod, bool[][] fn, int ver)
        {
            int size = mod.Length;
            for (int i = 0; i < size; i++) { Set(mod, fn, 6, i, i % 2 == 0); Set(mod, fn, i, 6, i % 2 == 0); }
            Finder(mod, fn, 3, 3); Finder(mod, fn, size - 4, 3); Finder(mod, fn, 3, size - 4);
            if (ver >= 2) { int a = size - 7; for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) Set(mod, fn, a + dx, a + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1); }
            DrawFormat(mod, fn, 0);   // reserve the format areas (overwritten with the chosen mask later)
        }

        static void Finder(bool[][] mod, bool[][] fn, int x, int y)
        {
            int size = mod.Length;
            for (int dy = -4; dy <= 4; dy++)
                for (int dx = -4; dx <= 4; dx++)
                {
                    int xx = x + dx, yy = y + dy;
                    if (xx < 0 || yy < 0 || xx >= size || yy >= size) continue;
                    int d = Math.Max(Math.Abs(dx), Math.Abs(dy));
                    Set(mod, fn, xx, yy, d != 2 && d != 4);
                }
        }

        static void DrawFormat(bool[][] mod, bool[][] fn, int mask)
        {
            int data = (0 << 3) | mask;   // level M = 00
            int rem = data;
            for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
            int bits = ((data << 10) | rem) ^ 0x5412;
            int size = mod.Length;
            for (int i = 0; i <= 5; i++) Set(mod, fn, 8, i, Bit(bits, i));
            Set(mod, fn, 8, 7, Bit(bits, 6)); Set(mod, fn, 8, 8, Bit(bits, 7)); Set(mod, fn, 7, 8, Bit(bits, 8));
            for (int i = 9; i < 15; i++) Set(mod, fn, 14 - i, 8, Bit(bits, i));
            for (int i = 0; i < 8; i++) Set(mod, fn, size - 1 - i, 8, Bit(bits, i));
            for (int i = 8; i < 15; i++) Set(mod, fn, 8, size - 15 + i, Bit(bits, i));
            Set(mod, fn, 8, size - 8, true);
        }

        static bool Bit(int v, int i) { return ((v >> i) & 1) != 0; }

        static void DrawCodewords(bool[][] mod, bool[][] fn, byte[] data)
        {
            int size = mod.Length, i = 0;
            for (int right = size - 1; right >= 1; right -= 2)
            {
                if (right == 6) right = 5;
                for (int vert = 0; vert < size; vert++)
                    for (int j = 0; j < 2; j++)
                    {
                        int x = right - j;
                        bool up = ((right + 1) & 2) == 0;
                        int y = up ? size - 1 - vert : vert;
                        if (!fn[y][x] && i < data.Length * 8) { mod[y][x] = Bit(data[i >> 3], 7 - (i & 7)); i++; }
                    }
            }
        }

        static void Mask(bool[][] mod, bool[][] fn, int m)
        {
            int size = mod.Length;
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    if (fn[y][x]) continue;
                    bool inv;
                    switch (m)
                    {
                        case 0: inv = (x + y) % 2 == 0; break;
                        case 1: inv = y % 2 == 0; break;
                        case 2: inv = x % 3 == 0; break;
                        case 3: inv = (x + y) % 3 == 0; break;
                        case 4: inv = (x / 3 + y / 2) % 2 == 0; break;
                        case 5: inv = x * y % 2 + x * y % 3 == 0; break;
                        case 6: inv = (x * y % 2 + x * y % 3) % 2 == 0; break;
                        default: inv = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
                    }
                    if (inv) mod[y][x] = !mod[y][x];
                }
        }

        static long Penalty(bool[][] mod)
        {
            int size = mod.Length; long p = 0; int dark = 0;
            for (int y = 0; y < size; y++)
            {
                int run = 0; bool prev = false; int runX = 0; bool prevX = false;
                for (int x = 0; x < size; x++)
                {
                    bool c = mod[y][x]; if (c) dark++;
                    if (x > 0 && c == prev) { run++; if (run == 5) p += 3; else if (run > 5) p++; } else run = 1; prev = c;
                    bool cx = mod[x][y];
                    if (x > 0 && cx == prevX) { runX++; if (runX == 5) p += 3; else if (runX > 5) p++; } else runX = 1; prevX = cx;
                    if (x > 0 && y > 0 && c == mod[y][x - 1] && c == mod[y - 1][x] && c == mod[y - 1][x - 1]) p += 3;
                    if (x >= 10)
                    {
                        if (Pattern(mod, y, x, true)) p += 40;
                        if (Pattern(mod, y, x, false)) p += 40;
                    }
                }
            }
            int total = size * size;
            int k = (Math.Abs(dark * 20 - total * 10) + total - 1) / total - 1;
            return p + k * 10;
        }

        // finder-like 1:1:3:1:1 run with 4 light modules on one side, ending at (x,y) along a row (horiz) or a column
        static bool Pattern(bool[][] mod, int y, int x, bool horiz)
        {
            bool[] w = new bool[11];
            for (int i = 0; i < 11; i++) w[i] = horiz ? mod[y][x - 10 + i] : mod[x - 10 + i][y];
            bool a = !w[0] && !w[1] && !w[2] && !w[3] && w[4] && !w[5] && w[6] && w[7] && w[8] && !w[9] && w[10];
            bool b = w[0] && !w[1] && w[2] && w[3] && w[4] && !w[5] && w[6] && !w[7] && !w[8] && !w[9] && !w[10];
            return a || b;
        }
    }
}
