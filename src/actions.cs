// irdeck action keys, second half (2026-10-09): what a key has to leave behind, checked from the sim itself.
//   sess      one line about the running session: number, type, state, event, AI cars, in the car, speed ...
//   quitmain  (QUIT TO MAIN) gets out of a stopped car, presses Quit on the sim's session bar, confirms every "are you sure?"
//             the sim then asks (found by colour: the sim draws them itself), waits until the sim has really gone, then clears
//             what the iRacing UI puts in the way (the results page of a race, the Test Drive window) until it shows Home
//   Set the environment variable IRDECK_SHOTS to a folder and every step saves a picture of the middle screen there.
// The helpers below are what QUIT TO MAIN, SKIP SESSION and RESTART RACE use to know they really finished
// (session number changed, no session any more, the UI back on Home) instead of trusting a click.
using System;
using System.Collections.Generic;
using System.Windows.Automation;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDeck
{
    static partial class Program
    {
        sealed class SessSnap
        {
            public bool Live; public int Num = -1, State, Frame; public double Time, Remain, Speed, Ffb = -1; public bool OnTrack, OnPit, Replay;
            public string Type = "", Event = "", Info = ""; public bool Ai; public List<string> Sessions = new List<string>();
            public override string ToString()
            {
                if (!Live) return "no session";
                return string.Format(CultureInfo.InvariantCulture, "session {0} {1} (state {2}), event {3}, ai={4}, onTrack={5}, onPit={6}, speed={7:0.0}, replay={8}, time={9:0}s, left={10:0}s, frame={12}, ffb={13:0.0}, sessions=[{11}]",
                    Num, Type, State, Event, Ai, OnTrack, OnPit, Speed, Replay, Time, Remain, string.Join(", ", Sessions.ToArray()), Frame, Ffb);
            }
        }

        static SessSnap Snap()
        {
            SessSnap s = new SessSnap();
            Tele t = Tele.Open(); if (t == null) return s;
            using (t)
            {
                s.Live = true; s.Num = (int)t.Num("SessionNum"); s.State = (int)t.Num("SessionState"); s.Time = t.Num("SessionTime"); s.Remain = t.Num("SessionTimeRemain");
                s.Speed = t.Num("Speed"); s.Frame = (int)t.Num("ReplayFrameNum"); s.Ffb = t.Has("SteeringWheelMaxForceNm") ? t.Num("SteeringWheelMaxForceNm") : -1; s.OnTrack = t.Bool("IsOnTrack"); s.OnPit = t.Bool("OnPitRoad"); s.Replay = t.Bool("IsReplayPlaying");
                s.Info = t.SessionInfo();
            }
            s.Ai = Regex.IsMatch(s.Info, @"CarIsAI:\s*1");
            Match ev = Regex.Match(s.Info, @"^\s*EventType:\s*(\S+)", RegexOptions.Multiline); s.Event = ev.Success ? ev.Groups[1].Value : "";
            // the sessions of the weekend, in order: "- SessionNum: 0 ... SessionType: Practice"
            foreach (Match m in Regex.Matches(s.Info, @"-\s*SessionNum:\s*(\d+)[^\r\n]*\r?\n(?:(?!\s*-\s*SessionNum:)[\s\S])*?SessionType:\s*([^\r\n]+)"))
            {
                s.Sessions.Add(m.Groups[1].Value + ":" + m.Groups[2].Value.Trim());
                if (m.Groups[1].Value == s.Num.ToString(CultureInfo.InvariantCulture)) s.Type = m.Groups[2].Value.Trim();
            }
            return s;
        }

        static int CmdSess() { Log("sess: " + Snap().ToString()); return 0; }

        // simdialog: does the sim show a confirmation dialog right now, and where is its button (for tests)
        static int CmdSimDialog()
        {
            SimDialog d = FindSimDialog();
            Log(d == null ? (FindSelectDialog() ? "simdialog: select-a-session-to-restart" : "simdialog: none") : "simdialog: " + d.Kind + " button at " + d.Primary.X + "," + d.Primary.Y + " " + d.Primary.Width + "x" + d.Primary.Height);
            return 0;
        }

        // ---------- pictures for the tests ----------
        static void ShotSim(string name)
        {
            string d = Environment.GetEnvironmentVariable("IRDECK_SHOTS");
            if (string.IsNullOrEmpty(d)) return;
            try
            {
                Directory.CreateDirectory(d);
                Rectangle a = SimArea();
                using (Bitmap full = new Bitmap(a.Width, a.Height))
                {
                    using (Graphics g = Graphics.FromImage(full)) g.CopyFromScreen(a.X, a.Y, 0, 0, a.Size);
                    using (Bitmap half = new Bitmap(full, a.Width / 2, a.Height / 2)) half.Save(Path.Combine(d, "a-" + name + ".png"), ImageFormat.Png);
                }
            }
            catch { }
        }

        // ---------- the sim's session bar and its confirmation dialogs (the sim draws both: found by position and colour) ----------

        // The middle of the session bar. It is always centred on the screen, 48 px down (at 1440p); only its size follows the
        // coloured button when one shows (green, purple, ... - in some states, "Wait" or "Awaiting tech inspection", it is grey).
        static void BarAnchor(out int cx, out int cy, out double scale, out bool coloured)
        {
            int gx, gy, bw;
            coloured = FindGreen(out gx, out gy, out bw);
            Rectangle sa = SimArea();
            scale = coloured ? bw / 478.0 : LoadScale();
            cx = sa.X + sa.Width / 2; cy = sa.Y + (int)Math.Round(48 * scale);
        }

        // The bar hides itself when the mouse has not moved for a few seconds (seen 2026-10-09 after GET OUT: a click at its place
        // then hit nothing). It is on screen when its dark panel shows along the top edge.
        static bool BarVisible(int cx, int cy, double s)
        {
            int ok = 0;
            foreach (int dx in new[] { -700, -520, -340, 340, 520, 700 })
            {
                int x = cx + (int)Math.Round(dx * s), y = cy + (int)Math.Round(62 * s);
                Color c;
                using (Bitmap one = new Bitmap(1, 1)) { using (Graphics g = Graphics.FromImage(one)) g.CopyFromScreen(x, y, 0, 0, new Size(1, 1)); c = one.GetPixel(0, 0); }
                int hi = Math.Max(c.R, Math.Max(c.G, c.B)), lo = Math.Min(c.R, Math.Min(c.G, c.B));
                if (hi < 75 && hi - lo < 28) ok++;
            }
            return ok >= 5;
        }

        // Moves the mouse over the bar until it shows (or 3 s pass). Never clicks.
        static void EnsureBar(int cx, int cy, double s)
        {
            for (int i = 0; i < 12; i++)
            {
                Native.SetCursorPos(cx + (i % 2 == 0 ? 0 : 4), cy + 10);
                Thread.Sleep(250);
                if (BarVisible(cx, cy, s)) return;
            }
            Log("the session bar did not show itself - trying anyway");
        }
        // The Quit button: the red power icon and "Quit" in the bar's second row, right end. (2026-10-09: offsets measured from the
        // coloured button put the click on the very edge of it, which missed in a running race. This is its middle.) Refined to the
        // red label itself when that is where it should be.
        static void QuitSpot(int cx, int cy, double s, out int x, out int y)
        {
            x = cx + (int)Math.Round(764 * s); y = cy + (int)Math.Round(120 * s);
            try
            {
                Rectangle r = new Rectangle(x - 90, y - 30, 180, 60);
                using (Bitmap bmp = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb))
                {
                    using (Graphics g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.X, r.Y, 0, 0, r.Size);
                    long sx = 0, sy = 0; int n = 0;
                    for (int j = 0; j < r.Height; j++) for (int i = 0; i < r.Width; i++)
                    { Color c = bmp.GetPixel(i, j); if (c.R > 190 && c.G < 100 && c.B < 100) { sx += i; sy += j; n++; } }
                    if (n >= 40) { int rx = r.X + (int)(sx / n), ry = r.Y + (int)(sy / n); if (Math.Abs(rx - x) < 40 && Math.Abs(ry - y) < 25) { x = rx; y = ry; } }
                }
            }
            catch { }
        }
        sealed class SimDialog { public Rectangle Primary; public string Kind; }

        // A confirmation dialog in the middle of the sim screen: a dark panel with a grey Cancel and one strongly coloured
        // button (blue "Skip Session" / "Restart", red "Yes, Quit", ...) at its lower right. Returns that button, or null.
        static SimDialog FindSimDialog()
        {
            Rectangle sa = SimArea();
            int cx = sa.X + sa.Width / 2, cy = sa.Y + sa.Height / 2;
            Rectangle area = new Rectangle(cx - 330, cy - 40, 660, 260);
            using (Bitmap bmp = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp)) g.CopyFromScreen(area.X, area.Y, 0, 0, area.Size);
                BitmapData d = bmp.LockBits(new Rectangle(0, 0, area.Width, area.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                byte[] px = new byte[d.Stride * area.Height];
                Marshal.Copy(d.Scan0, px, 0, px.Length);
                bmp.UnlockBits(d);
                int W = area.Width, H = area.Height, stride = d.Stride;
                Func<int, int, int[]> rgb = delegate (int x, int y) { int i = y * stride + x * 4; return new int[] { px[i + 2], px[i + 1], px[i] }; };
                Func<int, int, int> luma = delegate (int x, int y) { int[] c = rgb(x, y); return (c[0] * 3 + c[1] * 6 + c[2]) / 10; };
                // vivid, solid-colour pixels (a button fill is one flat colour: take the commonest vivid colour)
                Dictionary<int, int> votes = new Dictionary<int, int>();
                for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
                {
                    int[] c = rgb(x, y); int hi = Math.Max(c[0], Math.Max(c[1], c[2])), lo = Math.Min(c[0], Math.Min(c[1], c[2]));
                    if (hi > 120 && hi - lo > 110) { int key = (c[0] >> 3) << 10 | (c[1] >> 3) << 5 | (c[2] >> 3); int v; votes.TryGetValue(key, out v); votes[key] = v + 1; }
                }
                // the commonest vivid colours first (scenery can have big vivid areas too: each candidate must pass every test)
                List<KeyValuePair<int, int>> cand = new List<KeyValuePair<int, int>>(votes);
                cand.Sort(delegate (KeyValuePair<int, int> p, KeyValuePair<int, int> q) { return q.Value.CompareTo(p.Value); });
                for (int ci = 0; ci < cand.Count && ci < 8 && cand[ci].Value >= 1500; ci++)
                {
                    int best = cand[ci].Key, br = (best >> 10) & 31, bg = (best >> 5) & 31, bb = best & 31;
                    // separate blobs of that colour (a highlighted option has a thin outline of the same blue as the button)
                    int gw = W / 2, gh = H / 2; bool[] mask = new bool[gw * gh]; bool[] seen = new bool[gw * gh];
                    for (int y = 0; y < gh; y++) for (int x = 0; x < gw; x++)
                    {
                        int[] c = rgb(x * 2, y * 2);
                        mask[y * gw + x] = Math.Abs((c[0] >> 3) - br) <= 1 && Math.Abs((c[1] >> 3) - bg) <= 1 && Math.Abs((c[2] >> 3) - bb) <= 1;
                    }
                    for (int start = 0; start < mask.Length; start++)
                    {
                        if (!mask[start] || seen[start]) continue;
                        int minX = int.MaxValue, maxX = -1, minY = int.MaxValue, maxY = -1, n = 0;
                        Stack<int> stack = new Stack<int>(); stack.Push(start); seen[start] = true;
                        while (stack.Count > 0)
                        {
                            int p = stack.Pop(), px0 = p % gw, py0 = p / gw; n++;
                            if (px0 < minX) minX = px0; if (px0 > maxX) maxX = px0; if (py0 < minY) minY = py0; if (py0 > maxY) maxY = py0;
                            if (px0 > 0 && mask[p - 1] && !seen[p - 1]) { seen[p - 1] = true; stack.Push(p - 1); }
                            if (px0 < gw - 1 && mask[p + 1] && !seen[p + 1]) { seen[p + 1] = true; stack.Push(p + 1); }
                            if (py0 > 0 && mask[p - gw] && !seen[p - gw]) { seen[p - gw] = true; stack.Push(p - gw); }
                            if (py0 < gh - 1 && mask[p + gw] && !seen[p + gw]) { seen[p + gw] = true; stack.Push(p + gw); }
                        }
                        minX *= 2; maxX = maxX * 2 + 1; minY *= 2; maxY = maxY * 2 + 1; n *= 4;
                        int w = maxX - minX + 1, h = maxY - minY + 1;
                        if (w < 70 || w > 220 || h < 28 || h > 64 || n < 0.55 * w * h) continue;   // not button-shaped and solid
                        int midY = (minY + maxY) / 2;
                        // dark panel to the left of and above the button, and the Cancel label (bright letters) to its left
                        if (minX < 40 || minY < 40 || luma(minX - 25, midY) > 80 || luma((minX + maxX) / 2, minY - 25) > 80) continue;
                        int bright = 0;
                        for (int y = minY; y <= maxY; y++) for (int x = Math.Max(0, minX - 150); x < minX - 15; x++) if (luma(x, y) > 190) bright++;
                        if (bright < 25) continue;
                    SimDialog dlg = new SimDialog();
                    dlg.Primary = new Rectangle(area.X + minX, area.Y + minY, w, h);
                    dlg.Kind = bb > 24 && br < 8 ? "blue" : br > 18 && bg < 12 ? "red" : "colour " + (br * 8) + "," + (bg * 8) + "," + (bb * 8);
                    return dlg;
                    }
                }
                return null;
            }
        }
        // The restart question of a race session: "Select a Session to Restart" with two options (this session / the entire
        // weekend) and a Restart button that stays grey until one is chosen - so it has no coloured button to find. It is
        // recognised by its texts at their known places (title, first option, Cancel) on a dark panel. Returns true if showing.
        static bool FindSelectDialog()
        {
            Rectangle sa = SimArea();
            int cx = sa.X + sa.Width / 2, cy = sa.Y + sa.Height / 2;
            Rectangle area = new Rectangle(cx - 260, cy - 140, 520, 280);
            using (Bitmap bmp = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp)) g.CopyFromScreen(area.X, area.Y, 0, 0, area.Size);
                Func<int, int, int> luma = delegate (int x, int y) { Color c = bmp.GetPixel(x - area.X, y - area.Y); return (c.R * 3 + c.G * 6 + c.B) / 10; };
                Func<Rectangle, int> bright = delegate (Rectangle r) { int n = 0; for (int y = r.Y; y < r.Bottom; y++) for (int x = r.X; x < r.Right; x++) if (luma(x, y) > 180) n++; return n; };
                foreach (int[] p in new[] { new[] { -200, -100 }, new[] { 200, -100 }, new[] { -200, 110 }, new[] { 200, 110 } })
                    if (luma(cx + p[0], cy + p[1]) > 60) return false;
                return bright(new Rectangle(cx - 170, cy - 120, 250, 22)) >= 60       // the title
                    && bright(new Rectangle(cx - 170, cy - 62, 150, 22)) >= 40        // "Restart current session"
                    && bright(new Rectangle(cx + 10, cy + 88, 60, 20)) >= 25;         // Cancel
            }
        }
        // After a session-bar button was pressed the sim asks "are you sure?" - sometimes more than once. Presses the strongly
        // coloured button of every such dialog that appears, until done() says the job is finished or `ms` have passed.
        // Only while the car is not on track. Returns how many dialogs it confirmed.
        static int ConfirmDialogs(Func<bool> done, int ms, string tag)
        {
            DateTime end = DateTime.Now.AddMilliseconds(ms); int n = 0;
            while (DateTime.Now < end && !done())
            {
                SimDialog dlg = FindSimDialog();
                if (dlg == null && FindSelectDialog())
                {
                    // choose "Restart current session" (never the entire weekend); the Restart button then turns blue and is found next round
                    if (OnTrack()) { Log(tag + ": a dialog is up but the car is on track - not touching it"); return n; }
                    Rectangle s0 = SimArea(); ShotSim(tag + "-select");
                    Log(tag + ": the sim asks which session to restart - choosing the current session");
                    if (Native.GetForegroundWindow() != SimWindow()) FocusWindow(SimWindow());
                    Click(s0.X + s0.Width / 2 - 100, s0.Y + s0.Height / 2 - 42);
                    Thread.Sleep(700);
                    continue;
                }
                if (dlg != null)
                {
                    if (OnTrack()) { Log(tag + ": a dialog is up but the car is on track - not touching it"); return n; }
                    n++;
                    ShotSim(tag + "-dialog" + n);
                    Log(tag + ": the sim asks to confirm (" + dlg.Kind + " button at " + dlg.Primary.X + "," + dlg.Primary.Y + ") - confirming");
                    if (Native.GetForegroundWindow() != SimWindow()) FocusWindow(SimWindow());
                    Click(dlg.Primary.X + dlg.Primary.Width / 2, dlg.Primary.Y + dlg.Primary.Height / 2);
                    Thread.Sleep(1200);
                    continue;
                }
                Thread.Sleep(250);
            }
            return n;
        }

        // A question the sim is still asking from something that was never finished (a restart or skip that was not confirmed)
        // blocks the session bar: answer it with Cancel before doing anything else.
        static void CancelStrayDialogs(string tag)
        {
            for (int i = 0; i < 3; i++)
            {
                Rectangle sa = SimArea(); int cx = sa.X + sa.Width / 2, cy = sa.Y + sa.Height / 2;
                SimDialog d = FindSimDialog();
                if (d != null) { Log(tag + ": a question from before is still open - cancelling it"); ShotSim(tag + "-stray"); Click(d.Primary.X + d.Primary.Width / 2 - 108, d.Primary.Y + d.Primary.Height / 2); Thread.Sleep(800); continue; }
                if (FindSelectDialog()) { Log(tag + ": a restart question from before is still open - cancelling it"); ShotSim(tag + "-stray"); Click(cx + 43, cy + 98); Thread.Sleep(800); continue; }
                return;
            }
        }
        // ---------- QUIT TO MAIN ----------
        // One press: get out if stopped, Quit + every confirmation, wait for the sim to be gone, then the iRacing UI on Home.
        // Done only when there is no session any more and the UI really shows Home (no results page or Test Drive window over it).
        static int CmdQuitMain()
        {
            if (SessionActive())
            {
                SessSnap s0 = Snap();
                if (s0.OnTrack && s0.Speed > 1.0) { Log("quitmain refused: the car is moving"); return 3; }
                if (!FocusWindow(SimWindow())) { Log("quitmain: could not bring the sim to the front"); return 3; }
                Log("quitmain: leaving " + s0.ToString());
                if (s0.OnTrack)
                {
                    SendCombo("esc", 1800);
                    for (int i = 0; i < 40 && OnTrack(); i++) Thread.Sleep(250);
                    if (OnTrack()) { Log("quitmain: still in the car after holding Esc"); return 1; }
                    Thread.Sleep(1200);   // the session bar slides in
                }
                CancelStrayDialogs("quitmain");
                for (int attempt = 1; attempt <= 3 && SessionActive(); attempt++)
                {
                    int cx, cy; double s; bool coloured;
                    BarAnchor(out cx, out cy, out s, out coloured);
                    EnsureBar(cx, cy, s);
                    ShotSim("quitmain-" + attempt + "-bar");
                    int qx, qy; QuitSpot(cx, cy, s, out qx, out qy);
                    Click(qx, qy);   // Quit
                    Log("quitmain: pressed Quit at " + qx + "," + qy + (attempt > 1 ? " (try " + attempt + ")" : "") + (coloured ? "" : " (bar found by its fixed place)"));
                    int n = ConfirmDialogs(delegate { return !SessionActive(); }, n0(attempt), "quitmain");
                    if (n > 0 && SessionActive()) { for (int i = 0; i < 100 && SessionActive(); i++) Thread.Sleep(250); }   // confirmed: give the sim time to close
                    if (n == 0 && SessionActive()) Log("quitmain: no question came after Quit");
                }
                if (SessionActive()) { Log("quitmain: the sim did not leave the session (screen saved to " + SaveSimArea("fail-quitmain") + ")"); return 1; }
                Log("quitmain: the sim has left the session");
                // A race or AI session opens the results window a few seconds after the sim has gone.
                // 18 s of a clear Home is long enough to see it; a test drive does not open it.
                return LeaveToHome("quitmain", s0.Event == "Test" ? 4 : 18);
            }
            return LeaveToHome("quitmain", 3);
        }
        static int n0(int attempt) { return attempt == 1 ? 9000 : 6000; }

        // The iRacing UI is on Home when its Dashboard and Stream tabs are there and nothing is over them.
        static bool UiOnHome(List<Cand> c)
        {
            bool tabs = Pick(c, L("Dashboard"), "tabitem", false) != null && Pick(c, L("Stream"), "tabitem", false) != null;
            return tabs && !UiResultsOpen(c) && !UiDialogOpen(c);
        }
        // A named control, including one that is greyed out. Pick skips those, and the new results
        // modal's Back link is greyed out, which is why that window used to look like a clear Home.
        static Cand FindNamed(List<Cand> all, string name, string type, bool mustEnable)
        {
            foreach (Cand c in all)
            {
                if (c.Off) continue;
                if (mustEnable && !c.Enabled) continue;
                if (!c.Type.Equals(type, StringComparison.OrdinalIgnoreCase)) continue;
                if (!string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase)) continue;
                return c;
            }
            return null;
        }
        // The results view, old page or new modal: Event Log and Lap Graph tabs. Back may be disabled.
        // (2026-10-10 lead: the new modal reports its unselected tabs as NOT enabled - only the selected Results tab is - so
        // the tabs count whether enabled or not; an enabled-only check missed the modal and Home looked clear.)
        static bool UiResultsOpen(List<Cand> c) { return FindNamed(c, "Event Log", "TabItem", false) != null && FindNamed(c, "Lap Graph", "TabItem", false) != null; }
        // How to dismiss that view. The older page has an enabled Back link. The new modal greys Back
        // out and closes from a small unnamed button on the row of "About License Progression & Scoring
        // System" (not in the named list). Never the window's own Close: that quits the iRacing app.
        // On the 2026-10-10 screenshot the real X sits near (2502, 68); the title-bar Close is at y 0-31.
        static Cand ResultsDismiss(List<Cand> c)
        {
            Cand back = Pick(c, L("Back"), "hyperlink", false);
            if (back != null) return back;
            AutomationElement root = FindUiWindow();
            if (root == null) return null;
            System.Windows.Rect win = root.Current.BoundingRectangle;
            double titleBottom = win.Y + 40;
            Cand about = null;
            foreach (Cand x in c)
            {
                if (x.Off || x.Name.Length == 0) continue;
                if (x.Name.IndexOf("License Progression", StringComparison.OrdinalIgnoreCase) >= 0) { about = x; break; }
            }
            Cand best = null; double bestDx = 1e9;
            foreach (Cand x in c)
            {
                if (!x.Enabled || x.Off || x.R.IsEmpty) continue;
                if (x.Name.Length > 0) continue;
                if (!x.Type.Equals("Button", StringComparison.OrdinalIgnoreCase) && !x.Type.Equals("Hyperlink", StringComparison.OrdinalIgnoreCase)) continue;
                if (x.R.Width < 8 || x.R.Width > 56 || x.R.Height < 8 || x.R.Height > 56) continue;
                if (x.R.Y < titleBottom) continue;
                if (x.R.X < win.X - 2 || x.R.Right > win.Right + 4) continue;
                if (about != null)
                {
                    double mid = x.R.Y + x.R.Height / 2.0, aMid = about.R.Y + about.R.Height / 2.0;
                    if (Math.Abs(mid - aMid) > 22) continue;
                    if (x.R.X + 4 < about.R.Right) continue;
                    double dx = x.R.X - about.R.Right;
                    if (dx > 80) continue;
                    if (dx < bestDx) { bestDx = dx; best = x; }
                }
                else
                {
                    Cand tab = FindNamed(c, "Event Log", "TabItem", false);
                    if (tab == null || x.R.Bottom > tab.R.Y) continue;
                    if (x.R.X < win.Right - 220) continue;
                    if (best == null || x.R.X > best.R.X) best = x;
                }
            }
            return best;
        }
        // Title-bar chrome closes the whole app. A results dismiss control is Back, or the unnamed X.
        static bool SafeResultsClose(Cand c)
        {
            if (c == null || !c.Enabled || c.Off || c.R.IsEmpty || c.R.Width < 8) return false;
            if (c.Name.Equals("Close", StringComparison.OrdinalIgnoreCase)) return false;
            if (c.Name.Equals("Close Window", StringComparison.OrdinalIgnoreCase)) return false;
            if (c.Name.IndexOf("Minimize", StringComparison.OrdinalIgnoreCase) >= 0) return false;
            if (c.Name.IndexOf("Maximize", StringComparison.OrdinalIgnoreCase) >= 0) return false;
            if (c.Name.Equals("Restore", StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }
        // Any window the UI opens over the page (the Test Drive window, the news after a race, ...) has a link named Close;
        // the page itself has none (the title-bar buttons are buttons, not links).
        // (The Test Drive window's Close link is called Back in iRacing's newer UI, so Last settings + Back counts too.)
        static bool UiDialogOpen(List<Cand> c) { return Pick(c, L("Close"), "hyperlink", false) != null || (Pick(c, L("Last settings"), "hyperlink", false) != null && Pick(c, L("Back"), "hyperlink", false) != null); }

        // The iRacing UI on the centre screen at Home: closes what it puts in the way after a session (the results of a race,
        // the Test Drive window), presses Home, and only reports success once Home has stayed up for a few seconds
        // (the results page can open a few seconds after the sim has gone).
        static int LeaveToHome(string tag, int settleSecs)
        {
            IntPtr ui = UiWindow();
            if (ui == IntPtr.Zero) { Log(tag + ": iRacing UI is not running (press RIG ON)"); return 2; }
            PlaceOnCentre(ui); FocusWindow(ui);
            AutomationElement root = FindUiWindow();
            DateTime end = DateTime.Now.AddSeconds(75), homeAt = DateTime.MinValue, quiet = DateTime.Now; int stable = 0, windows = 0; bool shotResults = false;
            while (root != null && DateTime.Now < end)
            {
                List<Cand> c = Scan(root);
                if (UiResultsOpen(c))
                {
                    if (!shotResults) { ShotSim(tag + "-results"); shotResults = true; }
                    Cand close = ResultsDismiss(c);
                    // Verified first: the results tabs are up, and this control is Back or the unnamed X,
                    // not the window's own Close (CLAUDE.md rule 4).
                    if (!SafeResultsClose(close)) { Log(tag + ": the results window is open but its close control is not verified yet"); stable = 0; Thread.Sleep(700); continue; }
                    string how = close.Name.Length == 0 ? "the top-right X" : close.Name;
                    Log(tag + ": closing the results window (" + how + " at " + ((int)close.R.X).ToString(CultureInfo.InvariantCulture) + "," + ((int)close.R.Y).ToString(CultureInfo.InvariantCulture) + ")");
                    Press(close); stable = 0; Thread.Sleep(1000); continue;
                }
                if (UiDialogOpen(c))
                {
                    string what = Pick(c, L("View Results"), "hyperlink", false) != null ? "the news window" : Pick(c, L("Last settings"), "hyperlink", false) != null ? "the Test Drive window" : "a window over Home";
                    ShotSim(tag + "-window" + (++windows));
                    Log(tag + ": closing " + what); Press(Pick(c, L("Close", "Back"), "hyperlink", true)); stable = 0; Thread.Sleep(900); continue;
                }
                if (UiOnHome(c))
                {
                    if (Process.GetProcessesByName("iRacingSim64DX11").Length > 0) { stable = 0; Thread.Sleep(600); continue; }   // the sim is still closing
                    if (stable == 0) quiet = DateTime.Now;
                    stable++;
                    if ((DateTime.Now - quiet).TotalSeconds >= settleSecs) { ShotSim(tag + "-home"); Log(tag + ": back on the main screen"); return 0; }
                    Thread.Sleep(600); continue;
                }
                stable = 0;
                Cand home = Pick(c, L("Home"), "hyperlink", false);
                if (home != null && (DateTime.Now - homeAt).TotalSeconds > 4) { Press(home); homeAt = DateTime.Now; }
                Thread.Sleep(500);
            }
            Log(tag + ": the iRacing UI did not reach Home (screen saved to " + SaveSimArea("fail-" + tag) + ")");
            return 1;
        }
    }
}