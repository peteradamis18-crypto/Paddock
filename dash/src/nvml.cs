// NVML (W5-3): the graphics card as its own driver reports it (the calls nvidia-smi makes), for the black box's gpu* columns:
// load, clocks, temperature, memory, power and the "throttle reason" (why the card slowed itself down). The SDK's GpuUsage is a
// share of the frame time, not the card's load, and says nothing about heat or power limits.
// Only C:\Windows\System32\nvml.dll (the NVIDIA driver installs it), loaded with LoadLibrary so a test can point it at a missing file.
// Never throws: no dll, no card or any failed call = null (or that one number empty), logged once; a failed start is tried again
// at most once a minute. Read only; it changes nothing on the card.
using System;
using System.Runtime.InteropServices;

namespace IRDash
{
    sealed class NvmlRow
    {
        public double Load = -1, MemLoad = -1, Clock = -1, MemClock = -1, Temp = -1, VramMb = -1, VramTotalMb = -1, PowerW = -1;
        public ulong Throttle; public bool ThrottleKnown;
        // the short word for the file: what slowed the card down, "" when nothing did (idle and application clocks are normal)
        public string ThrottleWord { get { return Nvml.Word(ThrottleKnown ? Throttle : 0); } }
    }

    static class Nvml
    {
        public static string DllPath = @"C:\Windows\System32\nvml.dll";

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryW(string path);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr GetProcAddress(IntPtr h, string name);

        [StructLayout(LayoutKind.Sequential)] struct Util { public uint Gpu, Memory; }
        [StructLayout(LayoutKind.Sequential)] struct Mem { public ulong Total, Free, Used; }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FInit();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FHandle(uint index, out IntPtr dev);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FUtil(IntPtr dev, out Util u);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FClock(IntPtr dev, int type, out uint mhz);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FTemp(IntPtr dev, int sensor, out uint c);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FMem(IntPtr dev, out Mem m);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FPower(IntPtr dev, out uint mw);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FThrottle(IntPtr dev, out ulong mask);

        static readonly object gate = new object();
        static IntPtr lib, dev;
        static bool up;
        static DateTime lastTry = DateTime.MinValue;
        static FInit init, shutdown; static FHandle handle; static FUtil util; static FClock clock; static FTemp temp; static FMem mem; static FPower power; static FThrottle throttle;
        static int logged;                                    // bit per kind of failure: each is written to the log once
        public static string LastError = "";
        public static long Reads, Fails;

        static void Once(int bit, string msg)
        {
            LastError = msg;
            if ((logged & bit) != 0) return;
            logged |= bit;
            try { Log.W("nvml: " + msg); } catch { }
        }

        static T Fn<T>(string name) where T : class
        {
            IntPtr p = GetProcAddress(lib, name);
            if (p == IntPtr.Zero) return null;
            return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
        }

        static bool Start()
        {
            if (up) return true;
            if (lastTry != DateTime.MinValue && (DateTime.Now - lastTry).TotalSeconds < 60) return false;    // not more than once a minute
            lastTry = DateTime.Now;
            try
            {
                if (lib == IntPtr.Zero)
                {
                    if (!System.IO.File.Exists(DllPath)) { Once(1, "no " + DllPath + " (no NVIDIA driver): the graphics card columns stay empty"); return false; }
                    lib = LoadLibraryW(DllPath);
                    if (lib == IntPtr.Zero) { Once(2, "could not load " + DllPath + " (error " + Marshal.GetLastWin32Error() + ")"); return false; }
                    init = Fn<FInit>("nvmlInit_v2"); shutdown = Fn<FInit>("nvmlShutdown"); handle = Fn<FHandle>("nvmlDeviceGetHandleByIndex_v2");
                    util = Fn<FUtil>("nvmlDeviceGetUtilizationRates"); clock = Fn<FClock>("nvmlDeviceGetClockInfo"); temp = Fn<FTemp>("nvmlDeviceGetTemperature");
                    mem = Fn<FMem>("nvmlDeviceGetMemoryInfo"); power = Fn<FPower>("nvmlDeviceGetPowerUsage"); throttle = Fn<FThrottle>("nvmlDeviceGetCurrentClocksThrottleReasons");
                }
                if (init == null || handle == null || util == null) { Once(4, "nvml.dll lacks nvmlInit_v2 / the device calls"); return false; }
                int r = init();
                if (r != 0) { Once(8, "nvmlInit_v2 returned " + r); return false; }
                IntPtr d;
                r = handle(0, out d);
                if (r != 0 || d == IntPtr.Zero) { Once(16, "no graphics card 0 (nvmlDeviceGetHandleByIndex_v2 returned " + r + ")"); try { if (shutdown != null) shutdown(); } catch { } return false; }
                dev = d; up = true;
                return true;
            }
            catch (Exception ex) { Once(32, "start: " + ex.Message); return false; }
        }

        // one look at card 0; null when NVML is not there or the card did not answer
        public static NvmlRow Read()
        {
            lock (gate)
            {
                if (!Start()) { Fails++; return null; }
                try
                {
                    Util u;
                    int r = util(dev, out u);
                    if (r != 0) { Once(64, "nvmlDeviceGetUtilizationRates returned " + r + ": trying again in a minute"); Down(); Fails++; return null; }
                    NvmlRow x = new NvmlRow(); x.Load = u.Gpu; x.MemLoad = u.Memory;
                    uint v;
                    if (clock != null) { if (clock(dev, 0, out v) == 0) x.Clock = v; else Once(128, "graphics clock not available"); if (clock(dev, 2, out v) == 0) x.MemClock = v; }
                    if (temp != null) { if (temp(dev, 0, out v) == 0) x.Temp = v; else Once(256, "temperature not available"); }
                    Mem m;
                    if (mem != null) { if (mem(dev, out m) == 0) { x.VramMb = m.Used / 1048576.0; x.VramTotalMb = m.Total / 1048576.0; } else Once(512, "memory info not available"); }
                    if (power != null) { if (power(dev, out v) == 0) x.PowerW = v / 1000.0; else Once(1024, "power not available"); }
                    ulong t;
                    if (throttle != null) { if (throttle(dev, out t) == 0) { x.Throttle = t; x.ThrottleKnown = true; } else Once(2048, "throttle reasons not available"); }
                    Reads++;
                    return x;
                }
                catch (Exception ex) { Once(4096, "read: " + ex.Message); Down(); Fails++; return null; }
            }
        }

        static void Down() { try { if (up && shutdown != null) shutdown(); } catch { } up = false; dev = IntPtr.Zero; lastTry = DateTime.Now; }

        // the black box stops (irdash closing): give the driver its handle back
        public static void Shutdown() { lock (gate) { if (up) Down(); lastTry = DateTime.MinValue; } }

        // NVML's throttle bits -> one word. Heat first (it is the one Peter can do something about), then power, then the card's own brake.
        // 0x20 software thermal, 0x40 hardware thermal; 0x4 software power cap, 0x80 power brake; 0x8 hardware slowdown. 0x1 idle and
        // 0x2 application clocks are not a slow-down.
        public static string Word(ulong mask)
        {
            if ((mask & 0x60UL) != 0) return "thermal";
            if ((mask & 0x84UL) != 0) return "power";
            if ((mask & 0x8UL) != 0) return "hw";
            return "";
        }
    }
}
