// irlearn - "learn wheel" window. Shows one prompt at a time ("press the button you want for push-to-talk"),
// reads the SC-Link Hub directly over HID and records which button number each Savu Pro control sends.
// Results go to learn.txt next to the exe (one "IracingControl=hidButton" per line). --probe just checks the hub.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

namespace IRLearn
{
    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS
    {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
            NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices, NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    static class Native
    {
        [DllImport("hid.dll")] public static extern void HidD_GetHidGuid(out Guid g);
        [DllImport("hid.dll", SetLastError = true)] public static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr pp);
        [DllImport("hid.dll")] public static extern int HidP_GetCaps(IntPtr pp, out HIDP_CAPS caps);
        [DllImport("hid.dll")] public static extern int HidP_GetUsages(int reportType, ushort usagePage, ushort link, [In, Out] ushort[] list, ref int len, IntPtr pp, byte[] report, int reportLen);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr en, IntPtr hwnd, int flags);
        [DllImport("setupapi.dll", SetLastError = true)] public static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr info, ref Guid g, int idx, ref SP_DEVICE_INTERFACE_DATA d);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA d, IntPtr detail, int size, out int req, IntPtr info);
        [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    }

    // The SC-Link Hub's joystick collection, read as raw HID reports.
    sealed class Hub
    {
        public SafeFileHandle H; public IntPtr PP; public HIDP_CAPS Caps; public string Path;

        public static Hub Open()
        {
            Guid g; Native.HidD_GetHidGuid(out g);
            IntPtr set = Native.SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
            try
            {
                for (int i = 0; ; i++)
                {
                    SP_DEVICE_INTERFACE_DATA d = new SP_DEVICE_INTERFACE_DATA(); d.cbSize = Marshal.SizeOf(d);
                    if (!Native.SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d)) break;
                    int req; Native.SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
                    IntPtr buf = Marshal.AllocHGlobal(req);
                    try
                    {
                        Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                        if (!Native.SetupDiGetDeviceInterfaceDetail(set, ref d, buf, req, out req, IntPtr.Zero)) continue;
                        string path = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4));
                        if (path.IndexOf("vid_16d0&pid_0d66", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        SafeFileHandle h = Native.CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                        if (h.IsInvalid) continue;
                        IntPtr pp; HIDP_CAPS caps;
                        if (!Native.HidD_GetPreparsedData(h, out pp)) { h.Close(); continue; }
                        Native.HidP_GetCaps(pp, out caps);
                        if (caps.UsagePage == 1 && (caps.Usage == 4 || caps.Usage == 5))
                        {
                            Hub hub = new Hub(); hub.H = h; hub.PP = pp; hub.Caps = caps; hub.Path = path; return hub;
                        }
                        h.Close();
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                }
            }
            finally { Native.SetupDiDestroyDeviceInfoList(set); }
            return null;
        }

        // Blocks until the next input report; returns the HID button usages (1-based) held down in it, or null.
        public List<int> Read(FileStream fs)
        {
            byte[] rep = new byte[Caps.InputReportByteLength];
            int n = fs.Read(rep, 0, rep.Length);
            if (n <= 0) return null;
            ushort[] list = new ushort[256]; int len = list.Length;
            int st = Native.HidP_GetUsages(0, 9, 0, list, ref len, PP, rep, rep.Length);
            if (st != 0x00110000) return null;
            List<int> r = new List<int>();
            for (int i = 0; i < len; i++) r.Add(list[i]);
            return r;
        }
    }

    sealed class Step
    {
        public string Key, Title, Hint; public string CheckOf;
        public Step(string k, string t, string h) { Key = k; Title = t; Hint = h; }
    }

    sealed class LearnForm : Form
    {
        readonly List<Step> steps = new List<Step>();
        readonly Dictionary<string, int> got = new Dictionary<string, int>();
        readonly Label lblStep = new Label(), lblTitle = new Label(), lblHint = new Label(), lblStatus = new Label();
        readonly string outFile;
        int idx = 0; DateTime quietUntil = DateTime.MinValue;

        public LearnForm(string outPath)
        {
            outFile = outPath;
            Text = "Learn wheel buttons"; TopMost = true; StartPosition = FormStartPosition.Manual;
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            Size = new Size(1200, 520); Location = new Point(wa.X + (wa.Width - 1200) / 2, wa.Y + (wa.Height - 520) / 2);
            BackColor = Color.FromArgb(24, 26, 30); ForeColor = Color.White; FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false;
            Font f = new Font("Segoe UI", 12);
            lblStep.SetBounds(40, 24, 1100, 30); lblStep.Font = new Font("Segoe UI", 13); lblStep.ForeColor = Color.FromArgb(160, 170, 185);
            lblTitle.SetBounds(40, 70, 1100, 140); lblTitle.Font = new Font("Segoe UI Semibold", 30);
            lblHint.SetBounds(40, 215, 1100, 90); lblHint.Font = new Font("Segoe UI", 16); lblHint.ForeColor = Color.FromArgb(200, 205, 215);
            lblStatus.SetBounds(40, 310, 1100, 70); lblStatus.Font = new Font("Segoe UI", 16);
            Button skip = new Button(), back = new Button();
            skip.Text = "Skip this one"; skip.SetBounds(40, 400, 220, 56); skip.Font = f; skip.ForeColor = Color.Black; skip.Click += delegate { Advance(null); };
            back.Text = "Back"; back.SetBounds(280, 400, 160, 56); back.Font = f; back.ForeColor = Color.Black; back.Click += delegate { if (idx > 0) { idx--; Show(); } };
            Controls.AddRange(new Control[] { lblStep, lblTitle, lblHint, lblStatus, skip, back });
            BuildSteps(); Show();
        }

        void S(string key, string title, string hint) { steps.Add(new Step(key, title, hint)); }
        void Check(string of, string title) { Step s = new Step(of + "#check", title, "Same direction again. This checks the switch is in encoder mode."); s.CheckOf = of; steps.Add(s); }

        void BuildSteps()
        {
            S("ShiftDown", "Pull the LEFT shift paddle", "Already set up. This just confirms the numbering.");
            S("ShiftUp", "Pull the RIGHT shift paddle", "Already set up.");
            S("PitSpeedLimiter", "Press the button for PIT LIMITER", "Pick any of the 12 buttons. Use the one you want for this job.");
            S("VChatPushToTalk", "Press the button for PUSH-TO-TALK", "Team radio while driving.");
            S("HeadlightFlash", "Press the button for HEADLIGHT FLASH", "");
            S("TriggerWindshieldWipers", "Press the button for WIPERS", "");
            S("Reset", "Press the button for ENTER / EXIT / TOW", "");
            S("SPCCShutUp", "Press the button for SPOTTER SILENCE", "");
            S("Ignition", "Press the button for IGNITION", "Rarely used, only after a stall.");
            S("Starter", "Press the button for STARTER", "Rarely used, only after a stall.");
            S("BrakeBiasInc", "BRAKE BIAS: turn its encoder one click to MORE FRONT", "Top thumb encoder, left, in the plan. One click only.");
            S("BrakeBiasDec", "BRAKE BIAS: one click the other way (MORE REAR)", "");
            S("DashPageInc", "DASH PAGE: turn its encoder one click forward", "Top thumb encoder, right, in the plan.");
            S("DashPageDec", "DASH PAGE: one click back", "");
            S("TractionControlInc", "TC: turn the LEFT 12-position switch one click UP", "Set this switch to encoder mode in Simucube Tuner first.");
            Check("TractionControlInc", "TC: one more click UP");
            S("TractionControlDec", "TC: one click DOWN", "");
            S("ABSInc", "ABS: turn the RIGHT 12-position switch one click UP", "Set this switch to encoder mode in Simucube Tuner first.");
            Check("ABSInc", "ABS: one more click UP");
            S("ABSDec", "ABS: one click DOWN", "");
            S("IncFFB", "FFB STRENGTH: turn front encoder 1 one click STRONGER", "");
            S("DecFFB", "FFB STRENGTH: one click LIGHTER", "");
            S("TractionControl2Inc", "TC2: turn front encoder 2 one click UP", "Only some GT3s use TC2. Skip if you like.");
            S("TractionControl2Dec", "TC2: one click DOWN", "");
            S("SPCCVolumeUp", "SPOTTER VOLUME: turn front encoder 3 one click UP", "");
            S("SPCCVolumeDown", "SPOTTER VOLUME: one click DOWN", "");
            S("BlackBoxPrev", "LEFT 7-way switch: push UP", "Black box: select the previous item.");
            S("BlackBoxNext", "LEFT 7-way switch: push DOWN", "Black box: select the next item.");
            S("BlackBoxDec", "LEFT 7-way switch: push LEFT", "Black box: value down.");
            S("BlackBoxInc", "LEFT 7-way switch: push RIGHT", "Black box: value up.");
            S("BlackBoxToggle", "LEFT 7-way switch: press IN", "Black box: toggle the selected item.");
            S("BlackBoxShowNext", "LEFT 7-way switch: ROTATE one click clockwise", "Next black box page. Skip if your switch doesn't rotate.");
            S("BlackBoxShowPrev", "LEFT 7-way switch: ROTATE one click counter-clockwise", "Previous black box page.");
            S("BlackBoxF3", "RIGHT 7-way switch: push UP", "Opens Relative (F3).");
            S("BlackBoxF2", "RIGHT 7-way switch: push DOWN", "Opens Standings (F2).");
            S("BlackBoxF4", "RIGHT 7-way switch: push LEFT", "Opens Fuel (F4).");
            S("BlackBoxF7", "RIGHT 7-way switch: push RIGHT", "Opens Pit stop (F7).");
            S("BlackBoxF8", "RIGHT 7-way switch: press IN", "Opens In-car adjustments (F8).");
        }

        new void Show()
        {
            if (idx >= steps.Count) { Finish(); return; }
            Step s = steps[idx];
            lblStep.Text = string.Format("Step {0} of {1}", idx + 1, steps.Count);
            lblTitle.Text = s.Title; lblHint.Text = s.Hint;
            lblStatus.ForeColor = Color.FromArgb(120, 200, 140);
            lblStatus.Text = got.ContainsKey(s.Key) ? "Already recorded as button " + got[s.Key] + ". Press again to change it, or Skip." : "Waiting for you to press it...";
        }

        public void OnPress(int usage)
        {
            if (idx >= steps.Count || DateTime.Now < quietUntil) return;
            Step s = steps[idx];
            if (s.CheckOf != null)
            {
                int first;
                if (got.TryGetValue(s.CheckOf, out first) && first != usage)
                {
                    lblStatus.ForeColor = Color.FromArgb(240, 120, 110);
                    lblStatus.Text = "Different button (" + usage + " vs " + first + "): this switch is NOT in encoder mode. Set it in Tuner, then press Back and redo it.";
                    quietUntil = DateTime.Now.AddMilliseconds(700);
                    return;
                }
                Advance(usage); return;
            }
            foreach (KeyValuePair<string, int> kv in got)
                if (kv.Value == usage && kv.Key != s.Key && !kv.Key.EndsWith("#check"))
                {
                    lblStatus.ForeColor = Color.FromArgb(240, 120, 110);
                    lblStatus.Text = "Button " + usage + " is already used for " + kv.Key + ". Press a different control, or Skip.";
                    quietUntil = DateTime.Now.AddMilliseconds(500);
                    return;
                }
            Advance(usage);
        }

        void Advance(int? usage)
        {
            Step s = steps[idx];
            if (usage.HasValue && s.CheckOf == null) got[s.Key] = usage.Value;
            Save();
            idx++; quietUntil = DateTime.Now.AddMilliseconds(450);
            Show();
        }

        void Save()
        {
            StringBuilder b = new StringBuilder();
            foreach (KeyValuePair<string, int> kv in got) b.AppendLine(kv.Key + "=" + kv.Value);
            File.WriteAllText(outFile, b.ToString());
        }

        void Finish()
        {
            Save();
            lblStep.Text = "Done";
            lblTitle.Text = "All recorded: " + got.Count + " controls";
            lblHint.Text = "You can close this window. Tell Claude \"done\" and it will write them into iRacing.";
            lblStatus.Text = "";
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            Hub hub = Hub.Open();
            if (args.Length > 0 && args[0] == "--probe")
            {
                string msg = hub == null ? "SC-Link Hub joystick not found" :
                    string.Format("found SC-Link Hub: usagePage={0} usage={1} reportBytes={2} buttonCaps={3}", hub.Caps.UsagePage, hub.Caps.Usage, hub.Caps.InputReportByteLength, hub.Caps.NumberInputButtonCaps);
                File.WriteAllText(Path.Combine(dir, "learn-probe.txt"), msg);
                return hub == null ? 1 : 0;
            }
            if (hub == null) { MessageBox.Show("Couldn't find the SC-Link Hub. Is the wheel on and Simucube Tuner running?", "Learn wheel buttons"); return 1; }
            Application.EnableVisualStyles();
            LearnForm form = new LearnForm(Path.Combine(dir, "learn.txt"));
            FileStream fs = new FileStream(hub.H, FileAccess.Read, hub.Caps.InputReportByteLength, false);
            Thread t = new Thread(delegate ()
            {
                HashSet<int> prev = new HashSet<int>();
                while (true)
                {
                    List<int> cur;
                    try { cur = hub.Read(fs); } catch { return; }
                    if (cur == null) continue;
                    foreach (int u in cur)
                        if (!prev.Contains(u)) { int uu = u; try { form.BeginInvoke((MethodInvoker)delegate { form.OnPress(uu); }); } catch { } }
                    prev = new HashSet<int>(cur);
                }
            });
            t.IsBackground = true; t.Start();
            Application.Run(form);
            return 0;
        }
    }
}
