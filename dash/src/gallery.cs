// Side-screen gallery (WS14 in docs\SPEC-next.md): a slideshow on the left and right race screens while the sim is not
// running. Calm by design (Peter, 2026-10-09/10): both screens change at the SAME moment, to a matched PAIR of pictures
// (similar light and colour), very slowly (a change every 120 s, a 5 s soft crossfade). No wordmark, no logo, no app
// name, no bar: the only text is one small quiet line in the bottom-left corner of each screen (track · car, and the
// photographer + licence only where the licence requires it, e.g. CC BY), taken from credits.json, fading in after the
// picture is in. Credits for every picture stay in credits.json and in the /gallery JSON either way.
// Windows sit at the bottom of the z-order, never take focus, are click-through, and stop completely (timers off,
// pictures released, windows destroyed) while the sim runs, during the start-up intro, and if the three race screens
// are not laid out as expected.
// Pictures: <root>\paddock\gallery\*.jpg|png (+ credits.json) and ...\mine\*.jpg|png, 2560 px wide or more.
// /gallery JSON for tests and the deck; gallery commands via /api/do (galon, galoff, galnext, galrescan).
// How it stays cheap: each side has two stacked layered windows. The back one shows the current picture, the front
// one is given the next picture and faded in with SetLayeredWindowAttributes (the desktop compositor does the blend
// on the GPU), then the back one is hidden and its picture freed. Pictures are made once on worker threads (scaled to
// fill). The caption is a third window per side that is only as big as its text. Pairs are planned a whole round at a
// time, so every picture is shown once before any comes round again.
// Owned by the gallery workstream; irdash.cs only calls Init / Start / Handles / Do / Json.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace IRDash
{
    // ---- Win32 bits the gallery windows need ----
    static class GalNative
    {
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx, cy; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [StructLayout(LayoutKind.Sequential)]
        public struct BITMAPINFOHEADER { public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount; public uint biCompression, biSizeImage; public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant; }
        [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFO { public BITMAPINFOHEADER h; public uint colors; }
        [StructLayout(LayoutKind.Sequential)] public struct WINDOWPOS { public IntPtr hwnd, hwndInsertAfter; public int x, y, cx, cy; public uint flags; }
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
        public delegate bool EnumProc(IntPtr h, IntPtr l);

        public const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;
        public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;
        public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);

        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
        [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFO bi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    }

    // A picture the windows can show: a 32-bit DIB section (so painting is one BitBlt) with a GDI+ bitmap on top of it.
    sealed class GalPic : IDisposable
    {
        public readonly int W, H;
        public IntPtr MemDc, Dib, OldObj;
        public Bitmap Bmp; public Graphics G;
        bool gone; int refs = 1;       // in "same" mode both sides show one picture: it is made once and freed when both let go

        public GalPic(int w, int h)
        {
            W = w; H = h;
            GalNative.BITMAPINFO bi = new GalNative.BITMAPINFO();
            bi.h.biSize = (uint)Marshal.SizeOf(typeof(GalNative.BITMAPINFOHEADER));
            bi.h.biWidth = w; bi.h.biHeight = -h; bi.h.biPlanes = 1; bi.h.biBitCount = 32;   // top-down 32-bit
            IntPtr screen = GalNative.GetDC(IntPtr.Zero), bits;
            MemDc = GalNative.CreateCompatibleDC(screen);
            Dib = GalNative.CreateDIBSection(screen, ref bi, 0, out bits, IntPtr.Zero, 0);
            GalNative.ReleaseDC(IntPtr.Zero, screen);
            if (Dib == IntPtr.Zero) { GalNative.DeleteDC(MemDc); throw new OutOfMemoryException("no memory for a gallery picture"); }
            OldObj = GalNative.SelectObject(MemDc, Dib);
            Bmp = new Bitmap(w, h, w * 4, PixelFormat.Format32bppPArgb, bits);
            G = Graphics.FromImage(Bmp);
        }

        public GalPic Share() { refs++; return this; }

        public void Dispose()
        {
            if (--refs > 0 || gone) return;
            gone = true;
            if (G != null) { G.Dispose(); G = null; }
            if (Bmp != null) { Bmp.Dispose(); Bmp = null; }
            if (MemDc != IntPtr.Zero) { GalNative.SelectObject(MemDc, OldObj); GalNative.DeleteDC(MemDc); MemDc = IntPtr.Zero; }
            if (Dib != IntPtr.Zero) { GalNative.DeleteObject(Dib); Dib = IntPtr.Zero; }
        }
    }

    // Base of every gallery window: never activates, mouse goes straight through, always sinks to the bottom.
    class GalForm : Form
    {
        public GalForm()
        {
            Text = "irdash gallery";
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Size = new Size(10, 10);
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                // layered + transparent = see-through to clicks; no-activate + tool window = no focus, no taskbar, no Alt-Tab
                cp.ExStyle |= GalNative.WS_EX_LAYERED | GalNative.WS_EX_TRANSPARENT | GalNative.WS_EX_NOACTIVATE | GalNative.WS_EX_TOOLWINDOW;
                return cp;
            }
        }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x21) { m.Result = (IntPtr)3; return; }       // WM_MOUSEACTIVATE -> MA_NOACTIVATE
            if (m.Msg == 0x84) { m.Result = (IntPtr)(-1); return; }    // WM_NCHITTEST -> HTTRANSPARENT
            if (m.Msg == 0x46)                                          // WM_WINDOWPOSCHANGING: any z-order change goes to the bottom
            {
                GalNative.WINDOWPOS wp = (GalNative.WINDOWPOS)Marshal.PtrToStructure(m.LParam, typeof(GalNative.WINDOWPOS));
                if ((wp.flags & GalNative.SWP_NOZORDER) == 0 && wp.hwndInsertAfter != GalNative.HWND_BOTTOM)
                {
                    wp.hwndInsertAfter = GalNative.HWND_BOTTOM;
                    Marshal.StructureToPtr(wp, m.LParam, false);
                    Gallery.ZOrderNudged();
                }
            }
            base.WndProc(ref m);
        }
    }

    // The picture window. Its see-through level is set from outside with SetLayeredWindowAttributes (that is the crossfade).
    sealed class GalWin : GalForm
    {
        public GalPic Image;
        public GalWin()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.Opaque, true);
        }
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            GalPic p = Image;
            if (p == null || p.MemDc == IntPtr.Zero) return;
            IntPtr hdc = e.Graphics.GetHdc();
            try { GalNative.BitBlt(hdc, 0, 0, p.W, p.H, p.MemDc, 0, 0, 0x00CC0020); }   // SRCCOPY
            finally { e.Graphics.ReleaseHdc(hdc); }
        }
    }

    // The caption window: only as big as its line of text, per-pixel alpha; the fade is the constant alpha of UpdateLayeredWindow.
    sealed class CapWin : GalForm
    {
        public GalPic Image;
        public int X, Y;
        public void Present(int alpha)
        {
            GalPic p = Image;
            if (p == null || p.MemDc == IntPtr.Zero || !IsHandleCreated) return;
            GalNative.POINT dst = new GalNative.POINT(); dst.x = X; dst.y = Y;
            GalNative.POINT src = new GalNative.POINT();
            GalNative.SIZE size = new GalNative.SIZE(); size.cx = p.W; size.cy = p.H;
            GalNative.BLENDFUNCTION bf = new GalNative.BLENDFUNCTION(); bf.SourceConstantAlpha = (byte)Math.Max(0, Math.Min(255, alpha)); bf.AlphaFormat = 1;   // AC_SRC_ALPHA
            IntPtr screen = GalNative.GetDC(IntPtr.Zero);
            GalNative.UpdateLayeredWindow(Handle, screen, ref dst, ref size, p.MemDc, ref src, 0, ref bf, 2);   // ULW_ALPHA
            GalNative.ReleaseDC(IntPtr.Zero, screen);
        }
    }

    // How a picture looks, in three numbers: brightness, warmth (red minus blue), colour strength. Used to pair pictures.
    sealed class GalSig { public double L, W, S; }

    sealed class GalEntry
    {
        public string Path, File, Key, Title = "", Author = "", Site = "", Licence = "", Source = "";
        public int CreditReq = -1;     // creditRequired from the credits file: 1 yes, 0 no, -1 not said (then the licence decides)
        public bool Bad;
        public volatile GalSig Sig;
    }

    // Two pictures being made for one change (one for each side); the last one finished posts the result to the UI thread.
    sealed class GalJob : IDisposable
    {
        public int Gen; public int[] Idx; public GalEntry[] E;
        public GalPic[] P = new GalPic[2], C = new GalPic[2]; public string[] Err = new string[2]; public int Left = 2;   // P = pictures, C = their captions
        public void Dispose() { for (int k = 0; k < 2; k++) { if (P[k] != null) { P[k].Dispose(); P[k] = null; } if (C[k] != null) { C[k].Dispose(); C[k] = null; } } }
    }

    // One side screen: its two picture windows, its caption window, and what they show.
    sealed class GalSide
    {
        public string Name; public Rectangle Bounds;
        public GalWin[] W = new GalWin[2]; public int Cur = -1;     // Cur = the window that shows the current picture
        public CapWin Cap;
        public GalEntry Entry; public int EntryIdx = -1;             // on screen now
        public GalEntry NewEntry; public int NewIdx = -1; public GalPic NewCap;   // coming in
        public int Over; public int LastAlpha = -1, LastCap = -1; public bool CapSwapped; public int Changes;
        public string Caption = "";                                  // the line shown now (also on /gallery)
        public long H0, H1, HC;                                      // window handles, kept here so /gallery can read them from another thread
    }

    static class Gallery
    {
        const int PicW = 2560, PicH = 1440;
        static string dir;   // <root>\paddock\gallery
        static readonly HashSet<string> Commands = new HashSet<string> { "galon", "galoff", "galnext", "galrescan", "galmode", "galtiming", "galsim" };
        static readonly object gate = new object();
        static readonly Random rng = new Random();
        static readonly Stopwatch clock = Stopwatch.StartNew();

        // settings (irdash.ini: gallery, gallery_secs 30-600 (120), gallery_fade (5), gallery_captions (1), gallery_mode same|pair (same))
        static volatile bool wanted = true, captions = true;
        static int secs = 120; static double fadeSecs = 5.0;
        static volatile string mode = "same";   // same = the identical picture on both screens, faded in lockstep; pair = two pictures that look alike
        static string simName = "iRacingSim64DX11", standIn = "";   // standIn: a test program's name (tests only)

        static SynchronizationContext ui;
        static System.Windows.Forms.Timer watch, dwell, fadeTimer;
        static volatile bool running;
        static int gen;                       // bumped on every start/stop so late worker results are dropped
        static string why = "starting";       // "" = showing; otherwise the code of why not
        static string whyText = "starting";
        static GalSide left, right;
        static readonly List<GalEntry> entries = new List<GalEntry>();
        static readonly Dictionary<string, GalSig> sigCache = new Dictionary<string, GalSig>();
        static Thread sigThread;
        static readonly List<int[]> pairQueue = new List<int[]>();
        static int[] curPair, newPair; static double curDist; static int rounds;
        static bool busy, pairWait; static double fadeT0; static int retries;
        static int phase;                     // 0 = still, 1 = the pictures are crossfading, 2 = the captions are fading in
        static int skipped, totalChanges, fgHits;
        static string screensNote = "";
        static DateTime lastScan = DateTime.MinValue, lastSimCheck = DateTime.MinValue; static bool simUp;
        static int logged;
        static bool reorderQueued;

        public static void Init(string d)
        {
            dir = d;
            try { Directory.CreateDirectory(dir); } catch { }
        }

        // called on the UI thread once irdash is up (next to DeltaBar.Start)
        public static void Start()
        {
            ui = SynchronizationContext.Current;
            LoadSettings();
            watch = new System.Windows.Forms.Timer(); watch.Interval = 1000;
            watch.Tick += delegate { try { Evaluate(); } catch (Exception ex) { Log.W("gallery: " + ex.Message); } };
            dwell = new System.Windows.Forms.Timer();
            dwell.Tick += delegate { try { DwellTick(); } catch (Exception ex) { Log.W("gallery: " + ex.Message); } };
            fadeTimer = new System.Windows.Forms.Timer(); fadeTimer.Interval = 30;
            fadeTimer.Tick += delegate { try { FadeStep(); } catch (Exception ex) { Log.W("gallery: " + ex.Message); } };
            watch.Start();
            Log.W("gallery ready (" + (wanted ? "on" : "off") + ", both screens change together every " + secs + " s, fade " + Fade().ToString("0.0", CultureInfo.InvariantCulture) + " s, captions " + (captions ? "on" : "off") + ")");
            try { Evaluate(); } catch (Exception ex) { Log.W("gallery: " + ex.Message); }
        }

        public static bool Handles(string c) { return Commands.Contains(c ?? ""); }

        // Stream Deck / test commands (any thread). Everything that touches windows is posted to the UI thread.
        public static bool Do(string c, string a)
        {
            switch (c)
            {
                case "galon": wanted = true; Save("gallery", "1"); Post(Evaluate); Log.W("gallery: switched on"); return true;
                case "galoff": wanted = false; Save("gallery", "0"); Post(Evaluate); Log.W("gallery: switched off"); return true;
                case "galnext": Post(NextNow); return true;
                case "galrescan": Post(Rescan); return true;
                case "galmode":        // same | pair; saved in irdash.ini
                    {
                        string m = (a ?? "").Trim().ToLowerInvariant();
                        if (m != "same" && m != "pair") return false;
                        mode = m; Save("gallery_mode", m); Log.W("gallery: mode " + m);
                        Post(Restart);
                        return true;
                    }
                case "galtiming":      // tests only: "secs,fade", faster than the 30-600 s the ini allows; empty = back to the ini values
                    {
                        if (!Sdk.TestHook) return false;
                        if (string.IsNullOrEmpty(a)) { LoadSettings(); Log.W("gallery: timing back to the ini values"); Post(Restart); return true; }
                        string[] p = a.Split(',');
                        int s; double f;
                        if (p.Length != 2 || !int.TryParse(p[0].Trim(), out s) || !double.TryParse(p[1].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out f)) return false;
                        secs = Math.Max(2, Math.Min(600, s)); fadeSecs = Math.Max(0.2, Math.Min(10.0, f));
                        Log.W("gallery: test timing " + secs + " s / " + Fade().ToString("0.0", CultureInfo.InvariantCulture) + " s fade");
                        Post(Restart);
                        return true;
                    }
                case "galsim":         // tests only: pretend this program is the sim ("" = back to the real name)
                    {
                        if (!Sdk.TestHook) return false;
                        string n = (a ?? "").Trim();
                        if (n.Length > 0 && !System.Text.RegularExpressions.Regex.IsMatch(n, "^irdash-test-[a-z0-9-]{1,20}$")) return false;
                        standIn = n;
                        Log.W("gallery: test stand-in sim name '" + n + "'");
                        Post(delegate { lastSimCheck = DateTime.MinValue; Evaluate(); });
                        return true;
                    }
            }
            return false;
        }

        // the crossfade can never be longer than half of the time between changes
        static double Fade() { return Math.Min(fadeSecs, secs / 2.0); }

        // ---- JSON for the deck and for tests ----
        public static string Json()
        {
            try { return JsonBody(); }
            catch (Exception ex) { return "{\"ready\":false,\"error\":" + Json_.S(ex.Message) + "}"; }
        }

        static string JsonBody()
        {
            StringBuilder sb = new StringBuilder("{\"ready\":" + (watch != null ? "true" : "false"));
            sb.Append(",\"on\":" + (wanted ? "true" : "false") + ",\"shown\":" + (running ? "true" : "false") + ",\"mode\":" + Json_.S(mode));
            sb.Append(",\"why\":" + Json_.S(why) + ",\"whyText\":" + Json_.S(whyText));
            int captioned = 0; lock (gate) foreach (GalEntry ce in entries) if (CaptionText(ce).Length > 0) captioned++;
            sb.Append(",\"count\":" + entries.Count + ",\"captioned\":" + captioned + ",\"creditFiles\":" + creditFiles + ",\"skipped\":" + skipped + ",\"secs\":" + secs + ",\"fade\":" + Fade().ToString("0.0#", CultureInfo.InvariantCulture));
            sb.Append(",\"captions\":" + (captions ? "true" : "false") + ",\"changes\":" + totalChanges + ",\"foregroundHits\":" + fgHits + ",\"fading\":" + (phase == 1 ? "true" : "false") + ",\"phase\":" + phase);
            sb.Append(",\"pairDist\":" + curDist.ToString("0.000", CultureInfo.InvariantCulture) + ",\"pairsQueued\":" + pairQueue.Count + ",\"rounds\":" + rounds);
            sb.Append(",\"simName\":" + Json_.S(simName) + ",\"standIn\":" + Json_.S(standIn) + ",\"screens\":" + Json_.S(screensNote));
            sb.Append(",\"left\":" + SideJson(left) + ",\"right\":" + SideJson(right));
            sb.Append(",\"z\":" + ZJson());
            sb.Append("}");
            return sb.ToString();
        }

        static string SideJson(GalSide s)
        {
            if (s == null || !running) return "null";
            StringBuilder sb = new StringBuilder("{");
            GalEntry e = s.Entry;
            sb.Append("\"file\":" + Json_.S(e == null ? "" : e.File) + ",\"title\":" + Json_.S(e == null ? "" : e.Title) + ",\"credit\":" + Json_.S(e == null ? "" : Credit(e)));
            sb.Append(",\"author\":" + Json_.S(e == null ? "" : e.Author) + ",\"licence\":" + Json_.S(e == null ? "" : e.Licence) + ",\"source\":" + Json_.S(e == null ? "" : e.Source));
            Rectangle wa = WorkOf(s.Bounds);
            sb.Append(",\"caption\":" + Json_.S(s.Caption) + ",\"x\":" + s.Bounds.X + ",\"y\":" + s.Bounds.Y + ",\"w\":" + s.Bounds.Width + ",\"h\":" + s.Bounds.Height + ",\"workX\":" + wa.X + ",\"workBottom\":" + wa.Bottom);
            sb.Append(",\"changes\":" + s.Changes + ",\"hwnds\":[");
            bool first = true;
            foreach (long h in new long[] { s.H0, s.H1, s.HC })
            {
                if (h == 0) continue;
                if (!first) sb.Append(",");
                sb.Append(h.ToString(CultureInfo.InvariantCulture)); first = false;
            }
            sb.Append("]}");
            return sb.ToString();
        }

        // "Osajus Photography / Wikimedia Commons / CC BY 2.0" - the credit line (never drawn on a screen; JSON only)
        static string Credit(GalEntry e)
        {
            if (e.Author.Length == 0) return "";
            string s = e.Author;
            if (e.Site.Length > 0) s += " / " + e.Site;
            if (e.Licence.Length > 0) s += " / " + e.Licence;
            return s;
        }

        // Is anything normal sitting below our windows in the z-order? (Progman / WorkerW, the desktop itself, may.)
        static string ZJson()
        {
            try
            {
                HashSet<long> mine = new HashSet<long>();
                foreach (GalSide s in new GalSide[] { left, right })
                    if (s != null) foreach (long h in new long[] { s.H0, s.H1, s.HC }) if (h != 0) mine.Add(h);
                if (mine.Count == 0) return "{\"ok\":true,\"below\":0,\"names\":\"\"}";
                bool seen = false; int below = 0; string names = "";
                GalNative.EnumWindows(delegate (IntPtr h, IntPtr l)
                {
                    // our hidden windows sit near the top of the list (new windows start there); only the ones on screen count
                    if (mine.Contains(h.ToInt64())) { if (GalNative.IsWindowVisible(h)) seen = true; return true; }
                    if (!seen || !GalNative.IsWindowVisible(h)) return true;
                    int cloaked; if (GalNative.DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
                    GalNative.RECT r; if (!GalNative.GetWindowRect(h, out r) || r.right - r.left < 50 || r.bottom - r.top < 50) return true;
                    StringBuilder cn = new StringBuilder(64); GalNative.GetClassName(h, cn, 64);
                    string c = cn.ToString();
                    if (c == "Progman" || c == "WorkerW") return true;
                    below++; if (names.Length < 160) names += c + ";";
                    return true;
                }, IntPtr.Zero);
                return "{\"ok\":" + (below == 0 ? "true" : "false") + ",\"below\":" + below + ",\"names\":" + Json_.S(names) + "}";
            }
            catch (Exception ex) { return "{\"ok\":false,\"below\":-1,\"names\":" + Json_.S(ex.Message) + "}"; }
        }

        // ---- settings ----
        static string IniGet(string key)
        {
            try
            {
                foreach (string raw in File.ReadAllLines(Program.IniFile))
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith(";") || line.StartsWith("#")) continue;
                    int e = line.IndexOf('=');
                    if (e > 0 && string.Equals(line.Substring(0, e).Trim(), key, StringComparison.OrdinalIgnoreCase)) return line.Substring(e + 1).Trim();
                }
            }
            catch { }
            return null;
        }

        static void LoadSettings()
        {
            secs = 120; fadeSecs = 5.0;
            string v;
            v = IniGet("gallery"); wanted = v == null || v != "0";
            v = IniGet("gallery_captions"); captions = v == null || v != "0";
            v = IniGet("gallery_mode"); mode = v != null && v.Trim().ToLowerInvariant() == "pair" ? "pair" : "same";
            int s; v = IniGet("gallery_secs"); if (v != null && int.TryParse(v, out s)) secs = Math.Max(30, Math.Min(600, s));
            double f; v = IniGet("gallery_fade"); if (v != null && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out f)) fadeSecs = Math.Max(0.5, Math.Min(10.0, f));
        }

        static void Save(string key, string val) { lock (gate) Config.SetKey(Program.IniFile, key, val); }

        static void Post(Action a)
        {
            SynchronizationContext c = ui;
            if (c == null) return;
            c.Post(delegate { try { a(); } catch (Exception ex) { Log.W("gallery: " + ex.Message); } }, null);
        }

        // ---- is it allowed to show right now? checked once a second, always on the UI thread ----
        static bool Exists(string procName)
        {
            if (procName.Length == 0) return false;
            Process[] ps = null;
            try { ps = Process.GetProcessesByName(procName); return ps.Length > 0; }
            catch { return false; }
            finally { if (ps != null) foreach (Process p in ps) p.Dispose(); }
        }

        static bool SimRunning()
        {
            // the process list costs a little, so look once a second while showing and every 3 s when not
            double every = running ? 0.5 : 3.0;
            if ((DateTime.Now - lastSimCheck).TotalSeconds >= every)
            {
                lastSimCheck = DateTime.Now;
                bool was = simUp;
                simUp = Exists(simName) || Exists(standIn);
                if (simUp && !was) simStart = StartOf(simName, standIn);
            }
            return simUp;
        }

        // when the sim program started (for the log line that shows how fast the gallery got out of the way)
        static DateTime simStart = DateTime.MinValue;
        static DateTime StartOf(string a, string b)
        {
            foreach (string n in new string[] { a, b })
            {
                if (n.Length == 0) continue;
                Process[] ps = null;
                try { ps = Process.GetProcessesByName(n); if (ps.Length > 0) return ps[0].StartTime; }
                catch { }
                finally { if (ps != null) foreach (Process p in ps) p.Dispose(); }
            }
            return DateTime.MinValue;
        }

#pragma warning disable 649
        static Rectangle[] harnessBounds;   // only ever set by the offscreen test program (reflection); always null inside irdash
#pragma warning restore 649

        // The three race screens in a row (by position, never by device number) plus an optional dashboard monitor above.
        static bool FindSides(out Rectangle l, out Rectangle r, out string reason)
        {
            l = r = Rectangle.Empty; reason = "";
            if (harnessBounds != null) { l = harnessBounds[0]; r = harnessBounds[1]; screensNote = "offscreen harness"; return true; }
            List<Screen> all = new List<Screen>(Screen.AllScreens);
            StringBuilder note = new StringBuilder();
            foreach (Screen s in all) note.Append(s.Bounds.X + "," + s.Bounds.Y + " " + s.Bounds.Width + "x" + s.Bounds.Height + "; ");
            screensNote = note.ToString();
            if (all.Count >= 2)
            {
                Screen top = all[0];
                foreach (Screen s in all) if (s.Bounds.Y < top.Bounds.Y) top = s;
                bool above = true;
                foreach (Screen s in all) if (s != top && s.Bounds.Y < top.Bounds.Bottom) above = false;
                if (above) all.Remove(top);
            }
            if (all.Count != 3) { reason = "there are " + all.Count + " race screens, not 3"; return false; }
            all.Sort(delegate (Screen a, Screen b) { return a.Bounds.X.CompareTo(b.Bounds.X); });
            foreach (Screen s in all)
                if (s.Bounds.Width != PicW || s.Bounds.Height != PicH) { reason = "a race screen is " + s.Bounds.Width + "x" + s.Bounds.Height + ", not " + PicW + "x" + PicH; return false; }
            if (all[0].Bounds.Y != all[1].Bounds.Y || all[1].Bounds.Y != all[2].Bounds.Y || all[0].Bounds.Right != all[1].Bounds.Left || all[1].Bounds.Right != all[2].Bounds.Left)
            { reason = "the three race screens are not side by side"; return false; }
            l = all[0].Bounds; r = all[2].Bounds;
            return true;
        }

        // the part of a screen the taskbar leaves free (the taskbar is always on top of our windows, so the caption must clear it)
        static Rectangle WorkOf(Rectangle bounds)
        {
            if (harnessBounds != null) return bounds;
            try { Rectangle wa = Screen.FromRectangle(bounds).WorkingArea; if (wa.Width > 100 && wa.Height > 100) return wa; } catch { }
            return bounds;
        }

        static int GoodCount() { lock (gate) { int n = 0; foreach (GalEntry e in entries) if (!e.Bad) n++; return n; } }

        static string WhyNot(out string text)
        {
            text = "";
            if (!wanted) { text = "switched off (gallery=0)"; return "off"; }
            if (Showcase.IntroActive) { text = "the start-up intro is playing"; return "intro"; }
            if (Sdk.Latest.Connected) { text = "a session is running"; return "session"; }
            if (SimRunning()) { text = "the sim is running"; return "sim"; }
            Rectangle l, r; string reason;
            if (!FindSides(out l, out r, out reason)) { text = "the screens are not as expected: " + reason; return "screens"; }
            if (running && (left.Bounds != l || right.Bounds != r)) { text = "the screen layout changed"; return "layout"; }
            if (!running && (DateTime.Now - lastScan).TotalSeconds > 30) Scan();
            if (GoodCount() < MinPictures()) { text = "no pictures in paddock\\gallery (2560 px wide or more)" + (mode == "pair" ? ", and pairs need at least two" : ""); return "none"; }
            return "";
        }

        static void Evaluate()
        {
            if (watch == null) return;
            string t, w = WhyNot(out t);
            if (running) CheckForeground();
            whyText = t;
            if (w != why)
            {
                why = w;
                if (w == "") { if (!StartShow()) why = "retry"; }       // "retry": try again on the next tick
                else if (running)
                {
                    StopShow(t);
                    if (w == "sim" && simStart != DateTime.MinValue)
                        Log.W("gallery: the sim program started at " + simStart.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture) + ", the gallery was gone " + (DateTime.Now - simStart).TotalSeconds.ToString("0.0", CultureInfo.InvariantCulture) + " s later");
                }
                else Log.W("gallery: not showing - " + t);
            }
            if (running && pairWait && !busy) BeginPair();              // waited for the picture measurements
        }

        static void CheckForeground()
        {
            IntPtr fg = GalNative.GetForegroundWindow();
            if (fg == IntPtr.Zero) return;
            long f = fg.ToInt64();
            foreach (GalSide s in new GalSide[] { left, right })
                if (s != null && (f == s.H0 || f == s.H1 || (s.HC != 0 && f == s.HC))) { fgHits++; Log.W("gallery: a gallery window became the front window - it should never"); }
        }

        // ---- starting and stopping ----
        static bool StartShow()
        {
            Rectangle l, r; string reason;
            if (!FindSides(out l, out r, out reason)) return false;
            gen++;
            left = new GalSide(); left.Name = "left"; left.Bounds = l;
            right = new GalSide(); right.Name = "right"; right.Bounds = r;
            foreach (GalSide s in new GalSide[] { left, right })
            {
                s.W[0] = new GalWin(); s.W[1] = new GalWin();
                IntPtr h0 = s.W[0].Handle, h1 = s.W[1].Handle;          // creates the (hidden) windows
                GalNative.SetLayeredWindowAttributes(h0, 0, 0, 2); GalNative.SetLayeredWindowAttributes(h1, 0, 0, 2);
                s.H0 = h0.ToInt64(); s.H1 = h1.ToInt64();
                if (captions) { s.Cap = new CapWin(); s.HC = s.Cap.Handle.ToInt64(); }
            }
            running = true; busy = false; phase = 0; pairWait = false; nextQueued = false; retries = 0; curPair = null; newPair = null; curDist = 0;
            pairQueue.Clear();
            watch.Interval = 600;                 // while showing, look every 0.6 s so the sim starting is noticed (and the gallery gone) well inside 2 s
            dwell.Interval = Math.Max(1000, secs * 1000);
            BeginPair();
            dwell.Start();
            Log.W("gallery: showing " + entries.Count + " pictures" + (mode == "pair" ? " in matched pairs" : ", the same one on both screens") + ", both screens change together every " + secs + " s with a " + Fade().ToString("0.0", CultureInfo.InvariantCulture) + " s fade (left " + l.X + "," + l.Y + " right " + r.X + "," + r.Y + ")");
            return true;
        }

        static void StopShow(string reason)
        {
            gen++;
            running = false; busy = false; phase = 0; pairWait = false;
            watch.Interval = 1000;                // hidden: once a second is plenty
            dwell.Stop(); fadeTimer.Stop();
            foreach (GalSide s in new GalSide[] { left, right })
            {
                if (s == null) continue;
                foreach (GalWin w in s.W) if (w != null) { w.Hide(); GalPic p = w.Image; w.Image = null; if (p != null) p.Dispose(); w.Dispose(); }
                if (s.Cap != null) { s.Cap.Hide(); GalPic p = s.Cap.Image; s.Cap.Image = null; if (p != null) p.Dispose(); s.Cap.Dispose(); }
                if (s.NewCap != null) { s.NewCap.Dispose(); s.NewCap = null; }
                s.Entry = null;
            }
            Log.W("gallery: stopped (" + reason + "); " + totalChanges + " picture changes so far");
            left = null; right = null; pairQueue.Clear();
        }

        static void Restart()
        {
            if (running) StopShow("restarting");
            why = "starting"; Evaluate();
        }

        static void Rescan()
        {
            Scan(); pairQueue.Clear();
            Log.W("gallery: " + entries.Count + " pictures (" + skipped + " skipped, under 2560 px wide)");
        }

        public static void ZOrderNudged()
        {
            // somebody asked one of our windows to leave the bottom; the request was turned into "bottom", now put them back in order
            if (reorderQueued || !running) return;
            reorderQueued = true;
            Post(delegate { reorderQueued = false; if (running) { Reorder(left); Reorder(right); } });
        }

        // ---- the picture list ----
        static void Scan()
        {
            lastScan = DateTime.Now;
            List<GalEntry> list = new List<GalEntry>(); int small = 0;
            Dictionary<string, GalEntry> credits = LoadCredits();
            List<string> files = new List<string>();
            try { files.AddRange(Directory.GetFiles(dir)); } catch { }
            string mine = Path.Combine(dir, "mine");
            try { if (Directory.Exists(mine)) files.AddRange(Directory.GetFiles(mine)); } catch { }
            files.Sort(StringComparer.OrdinalIgnoreCase);
            foreach (string f in files)
            {
                string ext = Path.GetExtension(f).ToLowerInvariant();
                if (ext != ".jpg" && ext != ".jpeg" && ext != ".png") continue;
                try
                {
                    int w;
                    using (FileStream fs = File.OpenRead(f))
                    using (Image im = Image.FromStream(fs, false, false)) w = im.Width;      // header only
                    if (w < PicW) { small++; continue; }
                }
                catch { small++; continue; }
                GalEntry e = new GalEntry(); e.Path = f; e.File = Path.GetFileName(f);
                try { FileInfo fi = new FileInfo(f); e.Key = f + "|" + fi.Length + "|" + fi.LastWriteTimeUtc.Ticks; } catch { e.Key = f; }
                bool isMine = string.Equals(Path.GetDirectoryName(f), mine, StringComparison.OrdinalIgnoreCase);
                GalEntry c;
                // a picture without a credits entry is still shown, just with no caption
                if (!isMine && credits.TryGetValue(e.File, out c)) { e.Title = c.Title; e.Author = c.Author; e.Site = c.Site; e.Licence = c.Licence; e.Source = c.Source; e.CreditReq = c.CreditReq; }
                lock (gate) { GalSig sg; if (sigCache.TryGetValue(e.Key, out sg)) e.Sig = sg; }
                list.Add(e);
            }
            lock (gate) { entries.Clear(); entries.AddRange(list); skipped = small; }
            if (mode == "pair") StartMeasuring();
        }

        // credits.json and every other credits-*.json in the folder (e.g. credits-r2.json), all keyed by file name
        static int creditFiles;
        static Dictionary<string, GalEntry> LoadCredits()
        {
            Dictionary<string, GalEntry> map = new Dictionary<string, GalEntry>(StringComparer.OrdinalIgnoreCase);
            List<string> files = new List<string>();
            try { files.AddRange(Directory.GetFiles(dir, "credits*.json")); } catch { }
            files.Sort(StringComparer.OrdinalIgnoreCase);
            creditFiles = 0;
            foreach (string p in files)
            {
                try
                {
                    object o = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(p, Encoding.UTF8));
                    object[] arr = o as object[];
                    if (arr == null) { System.Collections.ArrayList al = o as System.Collections.ArrayList; if (al != null) arr = al.ToArray(); }
                    if (arr == null) continue;
                    creditFiles++;
                    foreach (object item in arr)
                    {
                        Dictionary<string, object> d = item as Dictionary<string, object>;
                        if (d == null) continue;
                        GalEntry e = new GalEntry();
                        e.File = Str(d, "file"); e.Title = Str(d, "title"); e.Author = Str(d, "author"); e.Site = Str(d, "site"); e.Licence = Str(d, "licence"); e.Source = Str(d, "source");
                        object cr; if (d.TryGetValue("creditRequired", out cr) && cr != null) e.CreditReq = (cr is bool ? (bool)cr : cr.ToString().ToLowerInvariant() == "true") ? 1 : 0;
                        if (e.File.Length > 0) map[e.File] = e;
                    }
                }
                catch (Exception ex) { Log.W("gallery: " + Path.GetFileName(p) + ": " + ex.Message); }
            }
            return map;
        }
        static string Str(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v != null ? v.ToString() : ""; }

        // ---- measuring the pictures (once per file, on a background thread): brightness, warmth, colour strength ----
        static void StartMeasuring()
        {
            lock (gate)
            {
                if (sigThread != null) return;
                bool need = false; foreach (GalEntry e in entries) if (e.Sig == null) need = true;
                if (!need) return;
                sigThread = new Thread(MeasureAll); sigThread.IsBackground = true; sigThread.Priority = ThreadPriority.BelowNormal;
                sigThread.Start();
            }
        }

        static void MeasureAll()
        {
            try
            {
                while (true)
                {
                    GalEntry e = null;
                    lock (gate) { foreach (GalEntry x in entries) if (x.Sig == null) { e = x; break; } if (e == null) { sigThread = null; return; } }
                    GalSig sg;
                    try { sg = Measure(e.Path); }
                    catch (Exception ex) { Log.W("gallery: could not measure " + e.File + " (" + ex.Message + ")"); sg = new GalSig(); sg.L = 0.4; sg.W = 0; sg.S = 0.3; }
                    lock (gate) { sigCache[e.Key] = sg; e.Sig = sg; }
                }
            }
            catch (Exception ex) { Log.W("gallery: measuring stopped: " + ex.Message); lock (gate) sigThread = null; }
        }

        static GalSig Measure(string path)
        {
            using (Image src = Image.FromFile(path))
            using (Bitmap sm = new Bitmap(32, 18, PixelFormat.Format24bppRgb))
            {
                using (Graphics g = Graphics.FromImage(sm))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.DrawImage(src, new Rectangle(0, 0, 32, 18), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel);
                }
                BitmapData bd = sm.LockBits(new Rectangle(0, 0, 32, 18), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                byte[] buf = new byte[Math.Abs(bd.Stride) * 18];
                Marshal.Copy(bd.Scan0, buf, 0, buf.Length);
                int stride = Math.Abs(bd.Stride);
                sm.UnlockBits(bd);
                double l = 0, w = 0, s = 0; int n = 0;
                for (int y = 0; y < 18; y++)
                    for (int x = 0; x < 32; x++)
                    {
                        double b = buf[y * stride + x * 3], gg = buf[y * stride + x * 3 + 1], r = buf[y * stride + x * 3 + 2];
                        double mx = Math.Max(r, Math.Max(gg, b)), mn = Math.Min(r, Math.Min(gg, b));
                        l += (0.2126 * r + 0.7152 * gg + 0.0722 * b) / 255.0; w += (r - b) / 255.0; s += mx <= 0 ? 0 : (mx - mn) / mx; n++;
                    }
                GalSig sg = new GalSig(); sg.L = l / n; sg.W = w / n; sg.S = s / n;
                return sg;
            }
        }

        static bool SigsReady()
        {
            if (mode != "pair") return true;             // only matched pairs need the measurements
            lock (gate) { foreach (GalEntry e in entries) if (!e.Bad && e.Sig == null) return false; }
            return true;
        }

        // how different two pictures look side by side: light matters most, then warm/cool, then colour strength
        static double SigDist(GalSig a, GalSig b)
        {
            if (a == null || b == null) return 0.5;
            return 2.0 * Math.Abs(a.L - b.L) + 1.5 * Math.Abs(a.W - b.W) + 0.7 * Math.Abs(a.S - b.S);
        }

        // ---- planning the pairs: a whole round at a time, every picture once before any repeats ----
        struct Edge { public int A, B; public double D; }

        static void PlanRound()
        {
            List<int> idx = new List<int>();
            lock (gate) for (int k = 0; k < entries.Count; k++) if (!entries[k].Bad) idx.Add(k);
            if (mode != "pair")
            {
                // same picture on both screens: shuffle everything once, show each picture once per round
                List<int[]> singles = new List<int[]>();
                foreach (int k in idx) singles.Add(new int[] { k, k });
                for (int k = singles.Count - 1; k > 0; k--) { int j = rng.Next(k + 1); int[] t = singles[k]; singles[k] = singles[j]; singles[j] = t; }
                if (curPair != null && singles.Count > 1 && singles[0][0] == curPair[0]) { int[] t = singles[0]; singles[0] = singles[singles.Count - 1]; singles[singles.Count - 1] = t; }   // never the same picture twice running
                pairQueue.Clear(); pairQueue.AddRange(singles);
                rounds++;
                return;
            }
            if (idx.Count < 2) return;
            // all pairs, nearest first (with a little random jitter, so the pairing differs from round to round);
            // each picture goes into the best pair still open
            List<Edge> edges = new List<Edge>();
            for (int i = 0; i < idx.Count; i++)
                for (int j = i + 1; j < idx.Count; j++)
                {
                    Edge e = new Edge(); e.A = idx[i]; e.B = idx[j];
                    e.D = SigDist(entries[idx[i]].Sig, entries[idx[j]].Sig) * (0.8 + 0.4 * rng.NextDouble());
                    edges.Add(e);
                }
            edges.Sort(delegate (Edge x, Edge y) { return x.D.CompareTo(y.D); });
            HashSet<int> used = new HashSet<int>();
            List<int[]> pairs = new List<int[]>();
            foreach (Edge e in edges)
            {
                if (used.Contains(e.A) || used.Contains(e.B)) continue;
                used.Add(e.A); used.Add(e.B);
                pairs.Add(rng.Next(2) == 0 ? new int[] { e.A, e.B } : new int[] { e.B, e.A });      // which one goes left is chance
            }
            if (idx.Count % 2 == 1)                                  // one picture is left over: pair it with its nearest neighbour
            {
                foreach (int k in idx)
                {
                    if (used.Contains(k)) continue;
                    int best = -1; double bd = double.MaxValue;
                    foreach (int m in idx) { if (m == k) continue; double d = SigDist(entries[k].Sig, entries[m].Sig); if (d < bd) { bd = d; best = m; } }
                    pairs.Add(new int[] { k, best });
                }
            }
            for (int k = pairs.Count - 1; k > 0; k--) { int j = rng.Next(k + 1); int[] t = pairs[k]; pairs[k] = pairs[j]; pairs[j] = t; }
            // the first pair of the new round must not repeat a picture that is on the screens now
            if (curPair != null)
                for (int k = 0; k < pairs.Count; k++)
                    if (pairs[k][0] != curPair[0] && pairs[k][0] != curPair[1] && pairs[k][1] != curPair[0] && pairs[k][1] != curPair[1])
                    { int[] t = pairs[k]; pairs[k] = pairs[0]; pairs[0] = t; break; }
            pairQueue.Clear(); pairQueue.AddRange(pairs);
            rounds++;
        }

        static int[] NextPair()
        {
            for (int round = 0; round < 2; round++)
            {
                while (pairQueue.Count > 0)
                {
                    int[] p = pairQueue[0]; pairQueue.RemoveAt(0);
                    if (p[0] >= entries.Count || p[1] >= entries.Count || entries[p[0]].Bad || entries[p[1]].Bad) continue;
                    return p;
                }
                PlanRound();
                if (pairQueue.Count == 0) return null;
            }
            return null;
        }

        // ---- one change: two pictures, one per side, faded in together ----
        static void DwellTick()
        {
            if (!running) return;
            BeginPair();
            Reorder(left); Reorder(right);             // belt and braces: put the windows back at the bottom
        }

        static bool nextQueued;     // NEXT was pressed during a change: it runs when that change is finished

        static void NextNow()
        {
            if (!running) return;
            if (busy) { nextQueued = true; return; }
            BeginPair();
            dwell.Stop(); dwell.Start();
        }

        // a change is completely finished (pictures and captions): run a waiting NEXT
        static void ChangeDone()
        {
            phase = 0; busy = false; fadeTimer.Stop();
            if (nextQueued) { nextQueued = false; BeginPair(); dwell.Stop(); dwell.Start(); }
        }

        // "same" needs one picture, "pair" needs two
        static int MinPictures() { return mode == "pair" ? 2 : 1; }

        // One change. "same": one picture, made once and shown on both screens. "pair": two pictures that look alike.
        // Only one picture is decoded at a time (makeGate), and only the one on screen and the one coming in are kept.
        static readonly object makeGate = new object();

        static void BeginPair()
        {
            if (!running || busy || left == null || GoodCount() < MinPictures()) return;
            bool pairMode = mode == "pair";
            if (pairMode && !SigsReady()) { StartMeasuring(); pairWait = true; return; }    // the pictures are still being measured (a few seconds the first time)
            pairWait = false;
            int[] pr = NextPair();
            if (pr == null) return;
            GalJob job = new GalJob(); job.Gen = gen; job.Idx = pr;
            job.E = new GalEntry[] { entries[pr[0]], entries[pr[1]] };
            busy = true; bool caps = captions;
            int workers = pairMode ? 2 : 1; job.Left = workers;
            for (int k = 0; k < workers; k++)
            {
                int kk = k;
                Thread t = new Thread(delegate ()
                {
                    GalPic pic = null, cap = null; string err = null;
                    try { lock (makeGate) { pic = MakePicture(job.E[kk]); if (caps) cap = MakeCaption(job.E[kk]); } }
                    catch (Exception ex) { err = ex.Message; }
                    bool last;
                    lock (job)
                    {
                        if (!pairMode)      // both screens get the same picture and caption: one copy in memory, two owners
                        {
                            job.P[0] = pic; job.P[1] = pic == null ? null : pic.Share();
                            job.C[0] = cap; job.C[1] = cap == null ? null : cap.Share();
                            job.Err[0] = job.Err[1] = err;
                        }
                        else { job.P[kk] = pic; job.C[kk] = cap; job.Err[kk] = err; }
                        job.Left--; last = job.Left == 0;
                    }
                    if (!last) return;
                    SynchronizationContext c = ui;
                    if (c == null) { job.Dispose(); return; }
                    c.Post(delegate { try { ApplyPair(job); } catch (Exception ex2) { Log.W("gallery: " + ex2.Message); } }, null);
                });
                t.IsBackground = true; t.Priority = ThreadPriority.BelowNormal;
                t.Start();
            }
        }

        static void ApplyPair(GalJob job)
        {
            if (job.Gen != gen || !running) { job.Dispose(); return; }
            if (job.P[0] == null || job.P[1] == null)
            {
                for (int k = 0; k < 2; k++) if (job.P[k] == null) { job.E[k].Bad = true; Log.W("gallery: cannot show " + job.E[k].File + " (" + job.Err[k] + ") - left out"); }
                job.Dispose(); busy = false;
                if (retries++ < 3) Post(BeginPair);                // pick another pair
                return;
            }
            retries = 0;
            GalSide[] sides = new GalSide[] { left, right };
            for (int k = 0; k < 2; k++)
            {
                GalSide s = sides[k];
                int over = s.Cur == 0 ? 1 : 0;
                GalWin ow = s.W[over];
                ow.Image = job.P[k]; job.P[k] = null;                // the window owns the picture now
                GalNative.SetLayeredWindowAttributes(ow.Handle, 0, 0, 2);
                ow.Bounds = s.Bounds;
                ow.Show();                                           // ShowWithoutActivation + no-activate style: never takes focus
                GalNative.SetWindowPos(ow.Handle, GalNative.HWND_BOTTOM, s.Bounds.X, s.Bounds.Y, s.Bounds.Width, s.Bounds.Height, GalNative.SWP_NOACTIVATE);
                ow.Invalidate(); ow.Update();
                s.Over = over; s.NewEntry = job.E[k]; s.NewIdx = job.Idx[k]; s.LastAlpha = 0;
                if (s.NewCap != null) s.NewCap.Dispose();
                s.NewCap = job.C[k]; job.C[k] = null; s.CapSwapped = false; s.LastCap = -1;
            }
            newPair = job.Idx;
            fadeT0 = clock.Elapsed.TotalSeconds; phase = 1;
            Reorder(left); Reorder(right);
            fadeTimer.Start();
            if (logged++ < 4) Log.W("gallery: " + (mode == "pair" ? job.E[0].File + " | " + job.E[1].File + " (look difference " + SigDist(job.E[0].Sig, job.E[1].Sig).ToString("0.00", CultureInfo.InvariantCulture) + ")" : job.E[0].File + " on both screens"));
        }

        // top to bottom: the caption, the picture window fading in, then the one underneath; each sent to the bottom in that order
        static void Reorder(GalSide s)
        {
            if (s == null) return;
            List<Form> order = new List<Form>();
            if (s.Cap != null && s.Cap.Visible) order.Add(s.Cap);
            if (phase == 1 && s.W[s.Over] != null && s.W[s.Over].Visible) order.Add(s.W[s.Over]);
            if (s.Cur >= 0 && s.W[s.Cur] != null && s.W[s.Cur].Visible) order.Add(s.W[s.Cur]);
            foreach (Form f in order)
                GalNative.SetWindowPos(f.Handle, GalNative.HWND_BOTTOM, 0, 0, 0, 0, GalNative.SWP_NOMOVE | GalNative.SWP_NOSIZE | GalNative.SWP_NOACTIVATE);
        }

        // Caption timeline, seconds from the start of a change: the old line fades out first (0.6 s), the new one fades in
        // (1.6 s) only once the new picture is in.
        const double CapOut = 0.6, CapIn = 1.6;

        static void FadeStep()
        {
            if (phase == 0 || left == null) { fadeTimer.Stop(); return; }
            double fs = Fade();
            double t = clock.Elapsed.TotalSeconds - fadeT0;
            if (phase == 1)
            {
                double a = Math.Max(0, Math.Min(1, t / fs));
                int alpha = (int)Math.Round(a * a * (3 - 2 * a) * 255);          // smooth start and end
                foreach (GalSide s in new GalSide[] { left, right })             // both sides, the same level, in the same tick
                    if (alpha != s.LastAlpha) { GalNative.SetLayeredWindowAttributes(s.W[s.Over].Handle, 0, (byte)alpha, 2); s.LastAlpha = alpha; }
            }
            if (captions) { CaptionStep(left, t); CaptionStep(right, t); }
            if (phase == 1 && t >= fs) FinishPictures();
            if (phase == 2 && t >= Math.Max(fs, CapOut) + CapIn) ChangeDone();
        }

        static void CaptionStep(GalSide s, double t)
        {
            if (s.Cap == null || (s.CapSwapped && s.Cap.Image == null)) return;
            double inStart = Math.Max(Fade(), CapOut), ca;
            if (t < CapOut) ca = 1 - t / CapOut;                                // the old line goes first
            else
            {
                if (!s.CapSwapped)
                {
                    GalPic old = s.Cap.Image;
                    s.Cap.Image = s.NewCap; s.NewCap = null; s.CapSwapped = true; s.LastCap = -1;
                    if (old != null) old.Dispose();
                    s.Caption = s.NewEntry == null ? "" : CaptionText(s.NewEntry);
                    if (s.Cap.Image != null)
                    {
                        Rectangle wa = WorkOf(s.Bounds);                                  // above the taskbar, which these screens have (48 px), not behind it
                        s.Cap.X = wa.X + 24; s.Cap.Y = wa.Bottom - 52;                     // the text sits about 28 px from the left and bottom edges
                        s.Cap.SetBounds(s.Cap.X, s.Cap.Y, s.Cap.Image.W, s.Cap.Image.H);  // in place before it is shown (it must never flash at the parking spot)
                        if (!s.Cap.Visible) { s.Cap.Show(); Reorder(s); }
                    }
                    else if (s.Cap.Visible) s.Cap.Hide();                              // this picture has no caption
                }
                ca = t < inStart ? 0 : Math.Min(1, (t - inStart) / CapIn);       // the new line comes in after the picture
            }
            int cv = (int)Math.Round(ca * ca * (3 - 2 * ca) * 255);
            if (cv != s.LastCap) { s.Cap.Present(cv); s.LastCap = cv; }
        }

        // the crossfade is done: the old pictures go, the new ones stay
        static void FinishPictures()
        {
            foreach (GalSide s in new GalSide[] { left, right })
            {
                GalWin under = s.Cur >= 0 ? s.W[s.Cur] : null, over = s.W[s.Over];
                GalNative.SetLayeredWindowAttributes(over.Handle, 0, 255, 2);
                if (under != null) { under.Hide(); GalPic old = under.Image; under.Image = null; if (old != null) old.Dispose(); }
                s.Cur = s.Over; s.Entry = s.NewEntry; s.EntryIdx = s.NewIdx; s.NewIdx = -1; s.Changes++;
            }
            curPair = newPair; curDist = mode == "pair" ? SigDist(left.Entry == null ? null : left.Entry.Sig, right.Entry == null ? null : right.Entry.Sig) : 0;
            totalChanges++;
            if (captions) phase = 2; else ChangeDone();
        }

        // ---- the caption: one quiet line, as small as is readable ----
        // track · car (or event); the photographer and licence only where the licence asks for it (CC BY and the like).
        // Unsplash and Pexels pictures need no credit on screen; theirs stays in credits.json and the /gallery JSON.
        // (creditRequired in the credits file says it outright; without it, a CC licence needs the credit)
        static bool NeedsCredit(GalEntry e)
        {
            if (e.Author.Length == 0) return false;
            if (e.CreditReq >= 0) return e.CreditReq == 1;
            return e.Licence.StartsWith("CC", StringComparison.OrdinalIgnoreCase);
        }

        // "" = no caption (a picture without a credits entry is shown with none)
        static string CaptionText(GalEntry e)
        {
            if (e.Title.Length == 0) return "";
            string s = e.Title;
            if (NeedsCredit(e)) s += " · Photo: " + e.Author + (e.Licence.Length > 0 ? " · " + e.Licence : "");
            return s;
        }

        // about 16 px, light grey at about 70 % with a very soft shadow, on a see-through bitmap just big enough for the text
        static GalPic MakeCaption(GalEntry e)
        {
            string text = CaptionText(e);
            if (text.Length == 0) return null;
            using (Bitmap probe = new Bitmap(8, 8))
            using (Graphics pg = Graphics.FromImage(probe))
            using (Font f = new Font("Bahnschrift", 16f, FontStyle.Regular, GraphicsUnit.Pixel))
            {
                pg.TextRenderingHint = TextRenderingHint.AntiAlias;
                float tw = pg.MeasureString(text, f, PointF.Empty, StringFormat.GenericTypographic).Width;
                GalPic p = new GalPic(Math.Min((int)Math.Ceiling(tw) + 12, PicW - 80), 26);
                try
                {
                    Graphics g = p.G; g.TextRenderingHint = TextRenderingHint.AntiAlias;
                    using (SolidBrush soft = new SolidBrush(Color.FromArgb(40, 0, 0, 0)))
                    using (SolidBrush near = new SolidBrush(Color.FromArgb(70, 0, 0, 0)))
                    using (SolidBrush ink = new SolidBrush(Color.FromArgb(178, 238, 235, 228)))
                    {
                        g.DrawString(text, f, soft, 5f, 5f, StringFormat.GenericTypographic);
                        g.DrawString(text, f, near, 4.5f, 4f, StringFormat.GenericTypographic);
                        g.DrawString(text, f, ink, 4f, 3f, StringFormat.GenericTypographic);
                    }
                    return p;
                }
                catch { p.Dispose(); throw; }
            }
        }

        // ---- making a picture (worker thread): scaled to fill the screen, centre-cropped, never stretched; nothing drawn on it
        // (no logo, no band, no shade: the picture is shown exactly as it is) ----
        static GalPic MakePicture(GalEntry e)
        {
            GalPic p = new GalPic(PicW, PicH);
            try
            {
                using (Image src = Image.FromFile(e.Path))
                {
                    Graphics g = p.G;
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    float scale = Math.Max((float)PicW / src.Width, (float)PicH / src.Height);
                    float sw = PicW / scale, sh = PicH / scale, sx = (src.Width - sw) / 2f, sy = (src.Height - sh) / 2f;
                    using (ImageAttributes ia = new ImageAttributes())
                    {
                        ia.SetWrapMode(WrapMode.TileFlipXY);
                        g.DrawImage(src, new Rectangle(0, 0, PicW, PicH), sx, sy, sw, sh, GraphicsUnit.Pixel, ia);
                    }
                }
                return p;
            }
            catch { p.Dispose(); throw; }
        }
    }
}
