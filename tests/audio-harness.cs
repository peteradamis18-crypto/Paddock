// Test harness for dash\src\recaudio.cs (tests\audio-test.ps1 compiles the two files together; nothing of irdash is needed).
//   audio-harness tone <dir> <secs> <amp 0..1> <sessvol 0..1> <self|system>
//     records this program's own sound (process loopback of itself) or the whole PC's while it plays a short tone through
//     the default output, then prints one JSON line: the chunks, the wall clock of the run, where the tone was found in the capture
//     and where it was asked to start. <sessvol> is this program's own volume in the Windows mixer (0 = nothing audible, if the
//     capture is taken before that volume). Writes <dir>\capture.pcm (48 kHz s16le stereo) of the whole run for the mux test.
//   audio-harness open-system  : can the whole-PC loopback open (shared mode) - 1 s, prints the state
//   audio-harness open auto    : the real choice (iRacing + CrewChief by name, else the whole PC) - 1 s, prints what it picked
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using IRDash;

static class Harness
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    [DllImport("winmm.dll")] static extern int waveOutSetVolume(IntPtr h, uint vol);
    static string N(double d) { return d.ToString("0.000", Inv); }

    static int Main(string[] a)
    {
        StringBuilder log = new StringBuilder();
        RecAudio.Say = delegate (string m) { lock (log) log.Append(m.Replace("\"", "'")).Append(" | "); };
        try
        {
            if (a.Length >= 1 && (a[0] == "open-system" || a[0] == "open"))
            {
                // open <mode>: auto finds iRacing / CrewChief by name (nothing is played; a silent program is still opened)
                string md = a[0] == "open" && a.Length > 1 ? a[1] : "system";
                string d = Path.Combine(Path.GetTempPath(), "aud-open-" + Guid.NewGuid().ToString("N").Substring(0, 6));
                RecAudio.Start(d, md); Thread.Sleep(1200); string st = RecAudio.State, src = RecAudio.Source; RecAudio.Stop();
                Console.WriteLine("{\"state\":\"" + st + "\",\"source\":\"" + src + "\",\"status\":" + RecAudio.StatusJson() + ",\"log\":\"" + log + "\"}");
                try { Directory.Delete(d, true); } catch { }
                return 0;
            }
            if (a.Length < 6 || a[0] != "tone") { Console.WriteLine("usage: tone <dir> <secs> <amp> <sessvol> <self|system> | open-system"); return 2; }
            string dir = a[1]; double secs = double.Parse(a[2], Inv), amp = double.Parse(a[3], Inv), vol = double.Parse(a[4], Inv); string how = a[5];
            Directory.CreateDirectory(dir);
            uint v = (uint)Math.Round(Math.Max(0, Math.Min(1, vol)) * 0xFFFF); waveOutSetVolume(IntPtr.Zero, v | (v << 16));
            // the tone: 440 Hz at amp, with 20 ms of fade in/out so it does not click
            int n = (int)(secs * 48000);
            MemoryStream wav = new MemoryStream(); BinaryWriter w = new BinaryWriter(wav);
            w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + n * 4); w.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16); w.Write((short)1); w.Write((short)2); w.Write(48000); w.Write(48000 * 4); w.Write((short)4); w.Write((short)16);
            w.Write(Encoding.ASCII.GetBytes("data")); w.Write(n * 4);
            for (int i = 0; i < n; i++) { double env = Math.Min(1.0, Math.Min(i, n - 1 - i) / 960.0); short s = (short)(32767 * amp * env * Math.Sin(2 * Math.PI * 440 * i / 48000.0)); w.Write(s); w.Write(s); }
            w.Flush(); wav.Position = 0;
            SoundPlayer sp = new SoundPlayer(wav); sp.Load();
            string mode = how == "system" ? "system" : "pid:" + System.Diagnostics.Process.GetCurrentProcess().Id;
            double runStart = RecAudio.WallMs();
            TimeSpan cpu0 = System.Diagnostics.Process.GetCurrentProcess().TotalProcessorTime;
            RecAudio.Start(dir, mode);
            for (int i = 0; i < 100 && RecAudio.State == "starting"; i++) Thread.Sleep(20);
            Thread.Sleep(700);
            string st0 = RecAudio.State;
            double asked = RecAudio.WallMs(); sp.PlaySync(); double done = RecAudio.WallMs();
            Thread.Sleep(800);
            RecAudio.Stop();
            double runEnd = RecAudio.WallMs();
            double cpuMs = (System.Diagnostics.Process.GetCurrentProcess().TotalProcessorTime - cpu0).TotalMilliseconds;   // capture + the player together: an upper bound
            List<AudChunk> ch = RecAudio.Snapshot();
            StringBuilder cj = new StringBuilder("["); long frames = 0;
            for (int i = 0; i < ch.Count; i++) { if (i > 0) cj.Append(','); cj.Append("{\"startMs\":" + N(ch[i].StartMs) + ",\"frames\":" + ch[i].Frames + "}"); frames += ch[i].Frames; }
            cj.Append(']');
            double c0 = ch.Count > 0 ? ch[0].StartMs : 0, c1 = ch.Count > 0 ? ch[ch.Count - 1].EndMs : 0;
            // the whole run as one file, then where the tone is (RMS over 10 ms windows above 1/4 of the loudest window)
            string pcm = Path.Combine(dir, "capture.pcm"); long tot; double cov = 0;
            if (ch.Count > 0) cov = RecAudio.BuildPcm(pcm, new double[] { c0 }, new double[] { c1 }, out tot); else tot = 0;
            double onMs = -1, offMs = -1, peak = 0, rmsMax = 0;
            if (tot > 0)
            {
                byte[] b = File.ReadAllBytes(pcm); int win = 480, nw = (int)(tot / win); double[] r = new double[nw];
                for (int k = 0; k < nw; k++) { double s2 = 0; for (int j = 0; j < win; j++) { int o = (k * win + j) * 4; short x = (short)(b[o] | (b[o + 1] << 8)); s2 += (double)x * x; if (Math.Abs(x) > peak) peak = Math.Abs(x); } r[k] = Math.Sqrt(s2 / win); if (r[k] > rmsMax) rmsMax = r[k]; }
                for (int k = 0; k < nw; k++) if (r[k] > rmsMax / 4 && rmsMax > 30) { if (onMs < 0) onMs = c0 + k * 10.0; offMs = c0 + (k + 1) * 10.0; }
            }
            Console.WriteLine("{\"mode\":\"" + mode + "\",\"stateWhilePlaying\":\"" + st0 + "\",\"source\":\"" + RecAudio.LastRunSource + "\",\"runStart\":" + N(runStart) + ",\"runEnd\":" + N(runEnd) +
                ",\"cpuMs\":" + N(cpuMs) + ",\"asked\":" + N(asked) + ",\"playDone\":" + N(done) + ",\"chunkStart\":" + N(c0) + ",\"chunkEnd\":" + N(c1) + ",\"frames\":" + frames + ",\"coverage\":" + N(cov) +
                ",\"toneOn\":" + N(onMs) + ",\"toneOff\":" + N(offMs) + ",\"peak\":" + peak.ToString("0", Inv) + ",\"rmsMax\":" + rmsMax.ToString("0", Inv) + ",\"pcm\":\"" + pcm.Replace("\\", "\\\\") + "\",\"chunks\":" + cj +
                ",\"status\":" + RecAudio.StatusJson() + ",\"log\":\"" + log.ToString().Replace("\\", "/") + "\"}");
            return 0;
        }
        catch (Exception ex) { Console.WriteLine("{\"error\":\"" + ex.Message.Replace("\"", "'").Replace("\\", "/") + "\",\"log\":\"" + log + "\"}"); return 1; }
    }
}
