// Native delta bar (O2, O5): a window irdash draws itself on the middle race screen - no Electron, no browser.
// Layered (per-pixel alpha), click-through, never takes focus, topmost. Drawn with GDI+ at about 30 Hz from
// the SDK frames irdash already reads. Shows only while you are on track and out of the pits; fades out in
// the pits. Settings live in irdash.ini (delta_bar, delta_ref, delta_pos, delta_scale) and the Stream Deck
// OVERLAYS screen changes them through /api/do (deltaon, deltaref, deltaup, deltadown).
// Four references, in the order the VS key cycles them: PB (the best lap you ever drove here, refs.cs; the default
// whenever there is one), BEST (this session), OPTIMAL, SESSION (the last three are iRacing's own deltas).
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace IRDash
{
    sealed class DeltaBar : Form
    {
        // ---- settings (saved in irdash.ini) ----
        public static bool On = true;
        public static string Ref = "pb";            // pb | best | optimal | session
        public static int PosX = int.MinValue;      // left edge on the middle screen; MinValue = centred
        public static int PosY = 160;               // top edge, under the sim's own top bar and our two small irdashies widgets
        public static double Zoom = 1.0;
        public static string LastText = "";             // what the bar shows right now (for the test and for finding problems)

        const int BaseW = 560, BaseH = 156;          // the card is 128 high; the rest holds the small "PB 1:24.312 - set 3 Oct" line
        const int CardH = 128;
        static DeltaBar inst;
        static readonly object ini = new object();

        static readonly string[] Order = { "pb", "best", "optimal", "session" };
        static readonly string[] Labels = { "VS PB", "VS BEST", "VS OPTIMAL", "VS SESSION" };
        static readonly string[] PreviewLabels = { "VS PB  (PREVIEW)", "VS BEST  (PREVIEW)", "VS OPTIMAL  (PREVIEW)", "VS SESSION  (PREVIEW)" };
        static int refIdx;                           // index into Order
        static int layoutVer;                        // bumped when the position or size changes, so the picture is redrawn

        // ---- Win32 ----
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFOHEADER { public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount; public uint biCompression, biSizeImage; public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant; }
        [StructLayout(LayoutKind.Sequential)] struct BITMAPINFO { public BITMAPINFOHEADER h; public uint colors; }
        [DllImport("user32.dll", SetLastError = true)] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
        [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFO bi, uint usage, out IntPtr bits, IntPtr section, uint offset);

        const int WS_EX_TOPMOST = 0x8, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;

        // the window never activates and the mouse goes straight through it
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST;
                return cp;
            }
        }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x21) { m.Result = (IntPtr)3; return; }      // WM_MOUSEACTIVATE -> MA_NOACTIVATE
            if (m.Msg == 0x84) { m.Result = (IntPtr)(-1); return; }   // WM_NCHITTEST -> HTTRANSPARENT
            base.WndProc(ref m);
        }

        // ---- drawing surface: a DIB the GDI+ bitmap draws straight into ----
        int bw, bh; double surfScale;
        IntPtr memDc, dib, oldObj; Bitmap surface; Graphics gfx;
        Font fBig, fMid, fSmall; StringFormat centre, left, right;
        // brushes and pens made once per surface, so drawing a frame creates nothing new
        SolidBrush brCard, brTrack, brGreen, brRed, brInk, brMute, brMute2, brPill;
        Pen penEdge, penTick, penCentre, penPill; GraphicsPath cardPath, pillPath;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        bool shown; int alpha;
        DateTime lastOk = DateTime.MinValue, previewUntil = DateTime.MinValue;
        int errs;

        // predicted lap time needs the reference lap's time: best comes from LapBestLapTime, the others are
        // worked out at the line (last lap time minus the delta we saw at the end of that lap)
        readonly double[] endDelta = new double[3];
        readonly double[] refTime = new double[3];
        int trackedLap = -1;

        // what the picture was last drawn from (a frame that would look the same is not drawn again)
        int drawDms = int.MinValue, drawPms = int.MinValue, drawAi = -1, drawAlpha = -1, drawLayout = -1; bool drawOk, drawBanner, drawPreview;
        string deltaTxt = "", predTxt = "", bannerTxt = "";
        const string PreviewBanner = "PB 1:41.234  ·  set 3 Oct";

        // ---- "is the bar in front of the sim?" check, once a second while driving ----
        DateTime lastFocus = DateTime.MinValue;
        int checks, barFront, simFront; bool wasDriving;
        int simPid; DateTime simPidAt = DateTime.MinValue;

        DeltaBar()
        {
            Text = "irdash delta bar";
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Size = new Size(10, 10);
            timer.Interval = 33;
            timer.Tick += delegate { try { Step(); } catch (Exception ex) { if (errs++ < 5) Log.W("delta bar: " + ex.Message); } };
        }

        static bool IniHas(string key)
        {
            try
            {
                if (Program.IniFile == null || !File.Exists(Program.IniFile)) return false;
                foreach (string raw in File.ReadAllLines(Program.IniFile))
                {
                    string t = raw.TrimStart();
                    if (t.StartsWith(";") || t.StartsWith("#")) continue;
                    if (t.StartsWith(key + "=", StringComparison.OrdinalIgnoreCase)) return true;
                }
            }
            catch { }
            return false;
        }

        public static void Configure(bool on, string refName, string pos, double scale)
        {
            On = on;
            string r = (refName ?? "").ToLowerInvariant();
            // an ini that never said anything gets the all-time personal best; the old default "best" was only a template
            Ref = (r == "best" || r == "optimal" || r == "session") && IniHas("delta_ref") ? r : "pb";
            refIdx = Array.IndexOf(Order, Ref);
            Zoom = scale >= 0.5 && scale <= 3.0 ? scale : 1.0;
            string[] p = (pos ?? "").Split(',');
            int y;
            if (p.Length == 2 && int.TryParse(p[1].Trim(), out y)) PosY = y;
            int x;
            PosX = p.Length == 2 && int.TryParse(p[0].Trim(), out x) ? x : int.MinValue;   // "center,160" or "auto" = centred
            layoutVer++;
        }

        // call once, on the UI thread, when the message loop is running
        public static void Start()
        {
            if (inst != null) return;
            // the personal-best reference, the other drivers' laps and the benchmark all hang off this timer (refs.cs, bench.cs)
            string root = Program.RootDir;
            try { PbRef.Init(Path.Combine(Program.RootDir, @"dash\refs")); } catch (Exception ex) { Log.W("pb reference: " + ex.Message); }
            try { FieldLaps.Init(Path.Combine(root, "data")); } catch (Exception ex) { Log.W("field laps: " + ex.Message); }
            ProRefs.File_ = Path.Combine(root, @"data\pro-refs.json");
            inst = new DeltaBar();
            IntPtr h = inst.Handle;           // creates the window (hidden)
            inst.timer.Start();
            Log.W("delta bar ready (" + (On ? "on" : "off") + ", vs " + Ref + ")");
        }

        // irdash raises the sim and the irdashies windows while you drive; the bar goes in front of them again
        public static void Raise()
        {
            if (inst == null || !inst.shown) return;
            SetWindowPos(inst.Handle, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10 | 0x200);   // topmost, no move/size/activate
        }

        // ---- changes from the Stream Deck (any thread) ----
        public static void Toggle() { On = !On; Save("delta_bar", On ? "1" : "0"); Preview(); }
        // PB is offered when this car and track have a personal best, or when no session is loaded (nothing to be wrong about yet, and
        // the setting must be reachable from the deck at any time); in a session without one it would only show BEST, so the key skips it
        static bool PbOffered() { return PbRef.Current != null || !Sdk.Latest.Connected; }

        // PB -> BEST -> OPTIMAL -> SESSION -> PB
        public static void CycleRef()
        {
            int i = refIdx;
            for (int k = 1; k <= Order.Length; k++)
            {
                int n = (i + k) % Order.Length;
                if (n == 0 && !PbOffered()) continue;
                refIdx = n; break;
            }
            Ref = Order[refIdx];
            Save("delta_ref", Ref); Preview();
        }
        public static void Nudge(int dy)
        {
            PosY = Math.Max(0, Math.Min(2000, PosY + dy));
            Save("delta_pos", (PosX == int.MinValue ? "center" : PosX.ToString(CultureInfo.InvariantCulture)) + "," + PosY.ToString(CultureInfo.InvariantCulture));
            layoutVer++;
            Preview();
        }
        // out of the car there is no live data, so show sample values for a few seconds to see where the bar sits
        public static void Preview() { Preview(5); }
        public static void Preview(int seconds) { if (inst != null) inst.previewUntil = DateTime.Now.AddSeconds(seconds); }

        static void Save(string key, string val) { lock (ini) Config.SetKey(Program.IniFile, key, val); }

        // which reference is really in use: "pb" falls back to "best" while there is no personal best to measure against
        static int ActiveIdx() { int i = refIdx; return i == 0 && PbRef.Current == null ? 1 : i; }

        public static string Json()
        {
            RefData rd = PbRef.Current; int ai = ActiveIdx();
            return "{\"on\":" + (On ? "true" : "false") + ",\"ref\":\"" + Ref + "\",\"active\":\"" + Order[ai] + "\",\"label\":\"" + Labels[ai] + "\",\"y\":" + PosY.ToString(CultureInfo.InvariantCulture) +
                   ",\"pb\":" + (rd == null ? "null" : "{\"time\":" + rd.Time.ToString("0.000", CultureInfo.InvariantCulture) + ",\"text\":" + Json_.S(rd.Banner) + ",\"source\":" + Json_.S(rd.Source) + "}") +
                   ",\"text\":" + Json_.S(LastText) + "}";
        }

        // ---- per-frame work ----
        // iRacing's own deltas (the three non-PB references)
        static readonly string[] DeltaVar = { "LapDeltaToBestLap", "LapDeltaToOptimalLap", "LapDeltaToSessionBestLap" };
        static readonly string[] OkVar = { "LapDeltaToBestLap_OK", "LapDeltaToOptimalLap_OK", "LapDeltaToSessionBestLap_OK" };

        void Step()
        {
            DateTime now = DateTime.Now;
            Frame f = Sdk.Latest;
            bool onTrack = f.Connected && f.Num("IsOnTrack") != 0;
            bool inPits = onTrack && f.Num("OnPitRoad") != 0;
            if (onTrack) FocusCheck(now); else if (wasDriving) EndDriveReport();
            wasDriving = onTrack;
            // the lap is recorded and a new personal best picked up whatever the bar shows (refs.cs); the other drivers' laps are saved (bench.cs)
            PbRef.Tick(f, onTrack, inPits, now);
            FieldLaps.Tick(f, now);

            int ai = onTrack ? ActiveIdx() : refIdx; bool pbMode = ai == 0;       // the out-of-car preview shows the chosen reference as chosen
            bool preview = !onTrack && now < previewUntil;
            double delta = 0, pred = 0; bool ok = false;
            if (preview)
            {
                double t = (now - previewUntil.AddSeconds(-5)).TotalSeconds;
                ok = true; delta = 0.42 * Math.Sin(t * 1.9) - 0.08; pred = 101.234 + delta;
            }
            else if (onTrack)
            {
                TrackLap(f);
                if (pbMode)
                {
                    RefData rd = PbRef.Current;
                    ok = PbRef.Ok && rd != null;
                    if (ok) { delta = PbRef.Delta; pred = rd.Time + delta; lastOk = now; }
                }
                else
                {
                    int si = ai - 1;
                    ok = f.Num(OkVar[si]) != 0;
                    delta = f.Num(DeltaVar[si]);
                    if (ok) { lastOk = now; double rt = RefTime(f, si); pred = rt > 0 ? rt + delta : 0; }
                }
            }
            // against the personal best the bar stays up on the out lap too (it shows the PB line, with no delta until the first flying lap)
            bool want = On && (preview || (onTrack && !inPits && ((now - lastOk).TotalSeconds < 1.5 || (pbMode && PbRef.Current != null))));

            int target = want ? 255 : 0;
            if (alpha < target) alpha = Math.Min(target, alpha + 51);          // fade in over about 0.2 s
            else if (alpha > target) alpha = Math.Max(target, alpha - 24);     // fade out over about 0.35 s
            if (alpha == 0)
            {
                if (shown) { ShowWindow(Handle, 0); shown = false; }
                timer.Interval = onTrack ? 33 : 250;           // on track the timer keeps its pace: the lap samples for a new personal best need it
                return;
            }
            timer.Interval = 33;
            EnsureSurface();

            string banner = null;
            if (pbMode && PbRef.FlyingDone == 0 && !inPits) banner = preview && PbRef.Current == null ? PreviewBanner : (PbRef.Current != null ? PbRef.Current.Banner : null);
            else if (preview && pbMode) banner = PbRef.Current != null ? PbRef.Current.Banner : PreviewBanner;
            if (banner != null && banner != bannerTxt) bannerTxt = banner;

            int dms = ok ? (int)Math.Round(delta * 1000, MidpointRounding.AwayFromZero) : int.MaxValue;
            int pms = ok && pred > 0 ? (int)Math.Round(pred * 1000, MidpointRounding.AwayFromZero) : int.MaxValue;
            bool same = dms == drawDms && pms == drawPms && ok == drawOk && ai == drawAi && alpha == drawAlpha && drawLayout == layoutVer && drawPreview == preview && drawBanner == (banner != null) && shown;
            if (!same)
            {
                if (dms != drawDms) deltaTxt = DeltaText(ok, dms);
                if (pms != drawPms) predTxt = PredText(pms);
                LastText = deltaTxt + (ok && predTxt.Length > 0 ? " " + predTxt : "");
                drawDms = dms; drawPms = pms; drawOk = ok; drawAi = ai; drawAlpha = alpha; drawLayout = layoutVer; drawPreview = preview; drawBanner = banner != null;
                Render(ok, dms, preview, ai, banner != null, now, true);
            }
            if (!shown)
            {
                shown = true;
                ShowWindow(Handle, 4);                                          // SW_SHOWNOACTIVATE
                SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10 | 0x200);
            }
        }

        static string DeltaText(bool ok, int dms)
        {
            return ok ? ((dms < 0 ? "−" : "+") + Math.Min(9.999, Math.Abs(dms) / 1000.0).ToString("0.000", CultureInfo.InvariantCulture)) : "–.–––";
        }
        static string PredText(int pms) { return pms != int.MaxValue ? Lap(pms / 1000.0) : ""; }

        // A picture of the bar for the tests (tests\shots): the same drawing code, on a bitmap in memory. No window is made or shown,
        // so it is safe while the sim runs. ai: 0 PB, 1 BEST, 2 OPTIMAL, 3 SESSION.
        public static string Snapshot(string file, bool ok, double delta, double pred, int ai, string banner)
        {
            DeltaBar b = new DeltaBar();
            try
            {
                b.alpha = 255; b.EnsureSurface();
                int dms = ok ? (int)Math.Round(delta * 1000, MidpointRounding.AwayFromZero) : int.MaxValue;
                int pms = ok && pred > 0 ? (int)Math.Round(pred * 1000, MidpointRounding.AwayFromZero) : int.MaxValue;
                b.deltaTxt = DeltaText(ok, dms); b.predTxt = PredText(pms); b.bannerTxt = banner ?? "";
                b.Render(ok, dms, false, Math.Max(0, Math.Min(3, ai)), banner != null, DateTime.Now, false);
                Directory.CreateDirectory(Path.GetDirectoryName(file));
                // the picture is see-through: lay it on a dark race-track grey, like the top of the middle screen
                using (Bitmap flat = new Bitmap(b.bw, b.bh))
                using (Graphics g = Graphics.FromImage(flat))
                {
                    g.Clear(Color.FromArgb(58, 66, 58)); g.DrawImage(b.surface, 0, 0); flat.Save(file, ImageFormat.Png);
                }
                return file;
            }
            finally { b.FreeSurface(); b.Dispose(); }
        }

        void TrackLap(Frame f)
        {
            int lap = (int)f.Num("Lap");
            double pct = f.Num("LapDistPct");
            if (pct > 0.97)
                for (int i = 0; i < 3; i++) if (f.Num(OkVar[i]) != 0) endDelta[i] = f.Num(DeltaVar[i]);
            if (lap != trackedLap)
            {
                double last = f.Num("LapLastLapTime");
                if (trackedLap >= 0 && last > 0)
                    for (int i = 0; i < 3; i++) if (endDelta[i] != 0) { refTime[i] = last - endDelta[i]; endDelta[i] = 0; }
                trackedLap = lap;
            }
        }

        double RefTime(Frame f, int si)
        {
            if (si == 0) { double b = f.Num("LapBestLapTime"); if (b > 0) return b; }
            return refTime[si];
        }

        // ---- is the bar in front? logged so a focus problem is visible afterwards ----
        void FocusCheck(DateTime now)
        {
            if ((now - lastFocus).TotalMilliseconds < 1000) return;
            lastFocus = now;
            checks++;
            IntPtr fg = GetForegroundWindow();
            if (fg == Handle) { barFront++; Log.W("delta bar: the bar is the front window - it should never be"); }
            if ((now - simPidAt).TotalSeconds > 5)
            {
                simPidAt = now; simPid = 0;
                try { Process[] ps = Process.GetProcessesByName("iRacingSim64DX11"); if (ps.Length > 0) simPid = ps[0].Id; } catch { }
            }
            uint pid; GetWindowThreadProcessId(fg, out pid);
            if (simPid != 0 && pid == (uint)simPid) simFront++;
        }

        void EndDriveReport()
        {
            if (checks > 0)
                Log.W("delta bar focus check: " + checks + " checks while driving, the bar was the front window " + barFront + " times, the sim was in front " + simFront + " times");
            checks = barFront = simFront = 0;
        }

        // ---- drawing ----
        void EnsureSurface()
        {
            if (surface != null && Math.Abs(surfScale - Zoom) < 0.001) return;
            FreeSurface();
            surfScale = Zoom;
            bw = (int)Math.Round(BaseW * Zoom); bh = (int)Math.Round(BaseH * Zoom);
            BITMAPINFO bi = new BITMAPINFO();
            bi.h.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
            bi.h.biWidth = bw; bi.h.biHeight = -bh; bi.h.biPlanes = 1; bi.h.biBitCount = 32;   // top-down 32-bit
            IntPtr screen = GetDC(IntPtr.Zero), bits;
            memDc = CreateCompatibleDC(screen);
            dib = CreateDIBSection(screen, ref bi, 0, out bits, IntPtr.Zero, 0);
            ReleaseDC(IntPtr.Zero, screen);
            oldObj = SelectObject(memDc, dib);
            surface = new Bitmap(bw, bh, bw * 4, PixelFormat.Format32bppPArgb, bits);
            gfx = Graphics.FromImage(surface);
            gfx.SmoothingMode = SmoothingMode.AntiAlias;
            gfx.TextRenderingHint = TextRenderingHint.AntiAlias;      // grey-scale smoothing: ClearType cannot work on a see-through surface
            gfx.ScaleTransform((float)Zoom, (float)Zoom);
            fBig = new Font("Bahnschrift", 58f, FontStyle.Bold, GraphicsUnit.Pixel);
            fMid = new Font("Bahnschrift", 20f, FontStyle.Bold, GraphicsUnit.Pixel);
            fSmall = new Font("Bahnschrift", 13f, FontStyle.Bold, GraphicsUnit.Pixel);
            centre = new StringFormat(); centre.Alignment = StringAlignment.Center; centre.LineAlignment = StringAlignment.Center;
            left = new StringFormat(); left.Alignment = StringAlignment.Near; left.LineAlignment = StringAlignment.Center;
            right = new StringFormat(); right.Alignment = StringAlignment.Far; right.LineAlignment = StringAlignment.Center;
            brCard = new SolidBrush(Color.FromArgb(188, 8, 10, 14)); brTrack = new SolidBrush(Color.FromArgb(46, 255, 255, 255));
            brGreen = new SolidBrush(Color.FromArgb(47, 224, 122)); brRed = new SolidBrush(Color.FromArgb(255, 61, 61));
            brInk = new SolidBrush(Color.FromArgb(244, 241, 234)); brMute = new SolidBrush(Color.FromArgb(150, 158, 168)); brMute2 = new SolidBrush(Color.FromArgb(130, 150, 158, 168));
            brPill = new SolidBrush(Color.FromArgb(188, 8, 10, 14));
            penEdge = new Pen(Color.FromArgb(70, 255, 255, 255), 1f); penTick = new Pen(Color.FromArgb(120, 255, 255, 255), 1f); penCentre = new Pen(Color.FromArgb(230, 255, 255, 255), 2f);
            penPill = new Pen(Color.FromArgb(60, 255, 255, 255), 1f);
            cardPath = Round(new RectangleF(0.5f, 0.5f, BaseW - 1, CardH - 1), 14f);
            pillPath = Round(new RectangleF((BaseW - 250) / 2f, CardH + 6, 250, 20), 10f);
            drawLayout = -1;
        }

        void FreeSurface()
        {
            if (gfx != null) { gfx.Dispose(); gfx = null; }
            if (surface != null) { surface.Dispose(); surface = null; }
            if (memDc != IntPtr.Zero) { SelectObject(memDc, oldObj); DeleteDC(memDc); memDc = IntPtr.Zero; }
            if (dib != IntPtr.Zero) { DeleteObject(dib); dib = IntPtr.Zero; }
            IDisposable[] gone = { fBig, fMid, fSmall, centre, left, right, brCard, brTrack, brGreen, brRed, brInk, brMute, brMute2, brPill, penEdge, penTick, penCentre, penPill, cardPath, pillPath };
            foreach (IDisposable d in gone) if (d != null) d.Dispose();
            fBig = fMid = fSmall = null; centre = left = right = null; brCard = brTrack = brGreen = brRed = brInk = brMute = brMute2 = brPill = null;
            penEdge = penTick = penCentre = penPill = null; cardPath = pillPath = null;
        }

        static string Lap(double t)
        {
            int m = (int)(t / 60); double s = t - m * 60;
            return (m > 0 ? m.ToString(CultureInfo.InvariantCulture) + ":" + (s < 10 ? "0" : "") : "") + s.ToString("0.000", CultureInfo.InvariantCulture);
        }

        static GraphicsPath Round(RectangleF r, float rad)
        {
            GraphicsPath p = new GraphicsPath();
            float d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        void Render(bool ok, int dms, bool preview, int ai, bool banner, DateTime now, bool present)
        {
            Graphics g = gfx;
            g.Clear(Color.Transparent);
            double delta = ok ? dms / 1000.0 : 0;
            SolidBrush tone = !ok ? brMute : dms == 0 ? brInk : dms < 0 ? brGreen : brRed;
            g.FillPath(brCard, cardPath);
            g.DrawPath(penEdge, cardPath);
            g.DrawString(preview ? PreviewLabels[ai] : Labels[ai], fSmall, brMute, new RectangleF(22, 6, 260, 24), left);
            if (ok && predTxt.Length > 0)
            {
                g.DrawString("PREDICTED", fSmall, brMute, new RectangleF(300, 6, 120, 24), right);
                g.DrawString(predTxt, fMid, brInk, new RectangleF(420, 6, 120, 24), right);
            }
            g.DrawString(deltaTxt, fBig, tone, new RectangleF(0, 26, BaseW, 62), centre);
            // the bar: centre = on pace, +-1.0 s is the full width, left = ahead (green), right = behind (red)
            const float x0 = 22, x1 = 538, mid = 280, y0 = 92, hh = 16;
            g.FillRectangle(brTrack, x0, y0, x1 - x0, hh);
            if (ok)
            {
                float len = (float)(Math.Max(-1.0, Math.Min(1.0, delta)) * (x1 - x0) / 2);
                g.FillRectangle(tone, len < 0 ? mid + len : mid, y0, Math.Abs(len), hh);
            }
            g.DrawLine(penTick, mid - 129, y0, mid - 129, y0 + hh); g.DrawLine(penTick, mid + 129, y0, mid + 129, y0 + hh);
            g.DrawLine(penCentre, mid, y0 - 5, mid, y0 + hh + 5);
            g.DrawString("−1.0", fSmall, brMute2, new RectangleF(x0 - 4, 110, 60, 16), left);
            g.DrawString("+1.0", fSmall, brMute2, new RectangleF(x1 - 56, 110, 60, 16), right);
            if (banner)
            {
                g.FillPath(brPill, pillPath); g.DrawPath(penPill, pillPath);
                g.DrawString(bannerTxt, fSmall, brMute, new RectangleF((BaseW - 250) / 2f, CardH + 6, 250, 20), centre);
            }
            if (present) Present(now);
        }

        void Present(DateTime now)
        {
            Rectangle sb = Program.CentreScreen().Bounds;
            int x = PosX == int.MinValue ? sb.X + (sb.Width - bw) / 2 : sb.X + PosX;
            int y = sb.Y + PosY;
            x = Math.Max(sb.X, Math.Min(sb.Right - bw, x)); y = Math.Max(sb.Y, Math.Min(sb.Bottom - bh, y));
            POINT dst = new POINT(); dst.x = x; dst.y = y;
            POINT src = new POINT();
            SIZE size = new SIZE(); size.cx = bw; size.cy = bh;
            BLENDFUNCTION bf = new BLENDFUNCTION(); bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = (byte)alpha; bf.AlphaFormat = 1;   // AC_SRC_ALPHA
            IntPtr screen = GetDC(IntPtr.Zero);
            UpdateLayeredWindow(Handle, screen, ref dst, ref size, memDc, ref src, 0, ref bf, 2);   // ULW_ALPHA
            ReleaseDC(IntPtr.Zero, screen);
        }
    }
}
