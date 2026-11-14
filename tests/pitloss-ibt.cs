// Feeds .ibt files through PitLoss (tests\pitloss-test.ps1 section 5; also used to look for a real stop).
// args: <data dir for pitloss.tsv> <file.ibt> [more files]. Read-only on the .ibt. Prints per file: pit-road entries, stops measured, why not.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using IRDash;

static class PitLossIbt
{
    static int Main(string[] args)
    {
        Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal;
        Log.FilePath = Path.Combine(args[0], "irdash.log");
        PitLoss.Init(args[0]);
        int measured = 0;
        for (int a = 1; a < args.Length; a++)
        {
            IbtFile f = IbtFile.Open(args[a], true);
            if (f == null) { Console.WriteLine("skip (not telemetry): " + Path.GetFileName(args[a])); continue; }
            try
            {
                string track = f.YamlValue("TrackDisplayName"), cfg = f.YamlValue("TrackConfigName");
                double[][] c = f.Channels(new string[] { "SessionTime", "OnPitRoad", "Lap", "LapDistPct", "SessionFlags", "IsOnTrack", "PlayerTrackSurface", "PitstopActive", "SessionNum" }, 0, f.Records);
                if (c[0] == null || c[1] == null || c[2] == null) { Console.WriteLine("skip (no channels): " + Path.GetFileName(args[a])); continue; }
                int n = c[0].Length, entries = 0, before = PitLoss.Measured;
                string lastWhy = ""; bool prev = false; bool verbose = Environment.GetEnvironmentVariable("PITLOSS_VERBOSE") == "1";
                double[] spd = verbose ? f.Channel("Speed", 0, f.Records) : null;
                int spanStart = 0, active = 0, still = 0;
                for (int i = 0; i < n; i++)
                {
                    bool pit = c[1][i] > 0.5;
                    if (pit && !prev) { entries++; spanStart = i; active = 0; still = 0; }
                    if (pit) { if (c[7] != null && c[7][i] > 0.5) active++; if (spd != null && spd[i] < 0.3) still++; }
                    if (verbose && !pit && prev)
                        Console.WriteLine("  pit span: t=" + c[0][spanStart].ToString("0.0", CultureInfo.InvariantCulture) + " lap " + (int)c[2][spanStart] + "->" + (int)c[2][i] + " " + ((i - spanStart) / 60.0).ToString("0.0", CultureInfo.InvariantCulture)
                            + " s, PitstopActive " + (active / 60.0).ToString("0.0", CultureInfo.InvariantCulture) + " s, speed<0.3 " + (still / 60.0).ToString("0.0", CultureInfo.InvariantCulture) + " s");
                    prev = pit;
                    if (verbose && i > 0 && c[2][i] != c[2][i - 1])
                        Console.WriteLine("  line: lap " + (int)c[2][i - 1] + "->" + (int)c[2][i] + " t=" + c[0][i].ToString("0.0", CultureInfo.InvariantCulture) + " flags 0x" + ((uint)c[4][i]).ToString("x") + " surface " + (c[6] == null ? -9 : c[6][i]) + " pit " + pit);
                    if (verbose && c[6] != null && c[6][i] == 0 && (i == 0 || c[6][i - 1] != 0)) Console.WriteLine("  off track at t=" + c[0][i].ToString("0.0", CultureInfo.InvariantCulture) + " lap " + (int)c[2][i]);
                    if (i % 4 != 0) continue;           // 60 Hz in the file, 15 Hz like the live frame
                    PitLoss.Feed(c[0][i], pit, (int)c[2][i], c[3] == null ? 0 : c[3][i], c[4] == null ? 0 : (int)(uint)c[4][i], c[5] == null || c[5][i] > 0.5,
                                 c[6] == null ? 3 : (int)c[6][i], c[7] != null && c[7][i] > 0.5, track, cfg, c[8] == null ? 0 : (int)c[8][i]);
                    if (verbose && PitLoss.LastWhy != lastWhy) { lastWhy = PitLoss.LastWhy; Console.WriteLine("  verdict at t=" + c[0][i].ToString("0.0", CultureInfo.InvariantCulture) + " lap " + (int)c[2][i] + ": " + lastWhy); }
                }
                Console.WriteLine(Path.GetFileName(args[a]) + ": " + track + " | " + n + " records, pit-road entries " + entries + ", stops measured "
                    + (PitLoss.Measured - before) + ", last verdict '" + PitLoss.LastWhy + "'");
                measured += PitLoss.Measured - before;
            }
            finally { f.Dispose(); }
        }
        Log.Flush(3000);
        Console.WriteLine("total measured: " + measured + "; For = " + PitLoss.Json());
        return 0;
    }
}
