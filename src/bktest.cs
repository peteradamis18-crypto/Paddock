// bktest - plays a short low-frequency rumble on one specific playback device, to check a bass shaker.
//   bktest.exe "SPDIF Interface"  [hz] [seconds]
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

static class BkTest
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WAVEOUTCAPS { public ushort wMid, wPid; public uint vDriverVersion; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname; public uint dwFormats; public ushort wChannels, wReserved1; public uint dwSupport; }
    [StructLayout(LayoutKind.Sequential)]
    struct WAVEFORMATEX { public ushort wFormatTag, nChannels; public uint nSamplesPerSec, nAvgBytesPerSec; public ushort nBlockAlign, wBitsPerSample, cbSize; }
    [StructLayout(LayoutKind.Sequential)]
    struct WAVEHDR { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded; public IntPtr dwUser; public uint dwFlags, dwLoops; public IntPtr lpNext, reserved; }

    [DllImport("winmm.dll")] static extern int waveOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int waveOutGetDevCaps(UIntPtr id, ref WAVEOUTCAPS caps, int size);
    [DllImport("winmm.dll")] static extern int waveOutOpen(out IntPtr h, uint id, ref WAVEFORMATEX fmt, IntPtr cb, IntPtr inst, uint flags);
    [DllImport("winmm.dll")] static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveOutClose(IntPtr h);

    static int Main(string[] a)
    {
        string want = a.Length > 0 ? a[0] : "SPDIF Interface";
        double hz = a.Length > 1 ? double.Parse(a[1]) : 40;
        double secs = a.Length > 2 ? double.Parse(a[2]) : 3;
        string log = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "bktest.log");
        int dev = -1; string names = "";
        for (int i = 0; i < waveOutGetNumDevs(); i++)
        {
            WAVEOUTCAPS c = new WAVEOUTCAPS();
            waveOutGetDevCaps(new UIntPtr((uint)i), ref c, Marshal.SizeOf(c));
            names += i + ": " + c.szPname + "\r\n";
            if (dev < 0 && c.szPname.IndexOf(want, StringComparison.OrdinalIgnoreCase) >= 0) dev = i;
        }
        if (dev < 0) { File.WriteAllText(log, "no device matching '" + want + "'\r\n" + names); return 1; }

        const int rate = 48000;
        int n = (int)(rate * secs);
        short[] pcm = new short[n * 2];
        for (int i = 0; i < n; i++)
        {
            double env = Math.Min(1.0, Math.Min(i / (rate * 0.2), (n - i) / (rate * 0.2)));   // 0.2 s fade in/out, no clicks
            short v = (short)(Math.Sin(2 * Math.PI * hz * i / rate) * 0.6 * env * short.MaxValue);
            pcm[2 * i] = v; pcm[2 * i + 1] = v;
        }
        WAVEFORMATEX fmt = new WAVEFORMATEX();
        fmt.wFormatTag = 1; fmt.nChannels = 2; fmt.nSamplesPerSec = rate; fmt.wBitsPerSample = 16;
        fmt.nBlockAlign = 4; fmt.nAvgBytesPerSec = rate * 4;
        IntPtr h;
        int r = waveOutOpen(out h, (uint)dev, ref fmt, IntPtr.Zero, IntPtr.Zero, 0);
        if (r != 0) { File.WriteAllText(log, "could not open device " + dev + " (error " + r + ")\r\n" + names); return 2; }
        GCHandle data = GCHandle.Alloc(pcm, GCHandleType.Pinned);
        WAVEHDR hdr = new WAVEHDR(); hdr.lpData = data.AddrOfPinnedObject(); hdr.dwBufferLength = (uint)(pcm.Length * 2);
        IntPtr ph = Marshal.AllocHGlobal(Marshal.SizeOf(hdr)); Marshal.StructureToPtr(hdr, ph, false);
        waveOutPrepareHeader(h, ph, Marshal.SizeOf(hdr));
        waveOutWrite(h, ph, Marshal.SizeOf(hdr));
        Thread.Sleep((int)(secs * 1000) + 300);
        waveOutUnprepareHeader(h, ph, Marshal.SizeOf(hdr));
        waveOutClose(h); Marshal.FreeHGlobal(ph); data.Free();
        File.WriteAllText(log, DateTime.Now.ToString("HH:mm:ss") + "  played " + hz + " Hz for " + secs + " s on device " + dev + "\r\n" + names);
        return 0;
    }
}
