// ibtfile.cs - the one reader of iRacing's .ibt telemetry files (W0-6).
// An .ibt is: a 144-byte header, a list of variables (144 bytes each), the session YAML, then fixed-size records
// (one per sample, 60 per second). Everything that opens an .ibt goes through IbtFile.Open; TrackMaps.OpenIbt is a
// thin wrapper over it for the older callers. Header layout (irsdk_header + irsdk_diskSubHeader):
//   8 tickRate, 16 sessionInfoLen, 20 sessionInfoOffset, 24 numVars, 28 varHeaderOffset, 36 bufLen, 52 first record,
//   112 sessionStartDate (unix seconds), 120 sessionStartTime, 128 sessionEndTime, 136 sessionLapCount, 140 sessionRecordCount.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDash
{
    sealed class VarDef { public string Name; public int Type, Offset, Count; }

    sealed class IbtFile : IDisposable
    {
        public string Path = "";
        public FileStream Fs;
        public int Tick = 60, BufLen, DataOff, HeaderRecords, HeaderLaps;
        public long Records;                      // whole records on disk now
        public long StartUnix;                    // header 112: 0 when the sim did not write it
        public string Yaml = "";
        public readonly Dictionary<string, VarDef> Vars = new Dictionary<string, VarDef>();

        static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        // null = not a telemetry file (too short, a broken header). wantVars = false skips the variable list (header + YAML only, cheap).
        public static IbtFile Open(string path, bool wantVars)
        {
            FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            try
            {
                byte[] h = new byte[144];
                if (ReadFull(fs, h, 0, h.Length) < h.Length) { fs.Dispose(); return null; }
                IbtFile t = new IbtFile();
                t.Path = path; t.Fs = fs;
                t.Tick = BitConverter.ToInt32(h, 8); if (t.Tick <= 0 || t.Tick > 1000) t.Tick = 60;
                int infoLen = BitConverter.ToInt32(h, 16), infoOff = BitConverter.ToInt32(h, 20);
                int numVars = BitConverter.ToInt32(h, 24), varOff = BitConverter.ToInt32(h, 28);
                t.BufLen = BitConverter.ToInt32(h, 36); t.DataOff = BitConverter.ToInt32(h, 52);
                if (t.BufLen <= 0 || t.DataOff <= 0 || infoLen <= 0 || infoLen > 4000000) { fs.Dispose(); return null; }
                t.StartUnix = BitConverter.ToInt64(h, 112);
                t.HeaderLaps = BitConverter.ToInt32(h, 136); t.HeaderRecords = BitConverter.ToInt32(h, 140);
                t.Records = Math.Max(0, (fs.Length - t.DataOff) / t.BufLen);
                byte[] info = new byte[infoLen];
                fs.Position = infoOff; ReadFull(fs, info, 0, infoLen);
                int z = Array.IndexOf(info, (byte)0); if (z < 0) z = infoLen;
                t.Yaml = Encoding.GetEncoding(28591).GetString(info, 0, z);
                if (wantVars && numVars > 0 && numVars < 10000)
                {
                    byte[] vh = new byte[numVars * 144];
                    fs.Position = varOff; ReadFull(fs, vh, 0, vh.Length);
                    for (int i = 0; i < numVars; i++)
                    {
                        int b = i * 144;
                        int len = Array.IndexOf(vh, (byte)0, b + 16, 32) - (b + 16); if (len < 0) len = 32;
                        VarDef v = new VarDef();
                        v.Name = Encoding.ASCII.GetString(vh, b + 16, len);
                        v.Type = BitConverter.ToInt32(vh, b); v.Offset = BitConverter.ToInt32(vh, b + 4); v.Count = BitConverter.ToInt32(vh, b + 8);
                        t.Vars[v.Name] = v;
                    }
                }
                return t;
            }
            catch { fs.Dispose(); throw; }
        }

        public void Dispose() { if (Fs != null) Fs.Dispose(); }

        static int ReadFull(Stream s, byte[] b, int off, int len)
        {
            int got = 0;
            while (got < len) { int r = s.Read(b, off + got, len - got); if (r <= 0) break; got += r; }
            return got;
        }

        public VarDef Var(string name) { VarDef d; return Vars.TryGetValue(name, out d) ? d : null; }

        // one value of a variable in a record that starts at byte o of buf (0 when the file has no such variable)
        public static double At(byte[] b, int o, VarDef d)
        {
            if (d == null) return 0;
            int p = o + d.Offset;
            switch (d.Type)
            {
                case 0: case 1: return b[p];
                case 2: case 3: return BitConverter.ToInt32(b, p);
                case 4: return BitConverter.ToSingle(b, p);
                case 5: return BitConverter.ToDouble(b, p);
            }
            return 0;
        }

        public string YamlValue(string key)
        {
            // spaces and tabs only (not \s): an empty value such as "TrackConfigName:" must not pick up the next line
            Match m = Regex.Match(Yaml, "^[ \\t]*" + key + ":[ \\t]*(.*?)[ \\t\\r]*$", RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value.Trim('"') : "";
        }

        // The sim writes the record count into the header when it closes the file; while it is still writing it is 0.
        public bool IsFinished { get { return HeaderRecords > 0 && HeaderRecords <= Records; } }

        // When the recording began: the header first, then the name ("car_track 2026-11-12 09-28-07.ibt", local time);
        // never the file's creation or write time (OneDrive and copies change those). MinValue = unknown.
        public DateTime StartUtc
        {
            get
            {
                if (StartUnix > 1000000000L && StartUnix < 4000000000L) return Epoch.AddSeconds(StartUnix);
                return StartFromName(System.IO.Path.GetFileName(Path));
            }
        }

        public static DateTime StartFromName(string name)
        {
            Match m = Regex.Match(name ?? "", @"(\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2})");
            DateTime d;
            if (m.Success && DateTime.TryParseExact(m.Groups[1].Value, "yyyy-MM-dd HH-mm-ss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out d)) return d.ToUniversalTime();
            return DateTime.MinValue;
        }

        // The iRacing session this file belongs to: SessionUniqueID from the first record that has one (0 = none).
        public int SessionUniqueID
        {
            get
            {
                VarDef d = Var("SessionUniqueID");
                if (d == null || Records == 0) return 0;
                byte[] buf = new byte[BufLen];
                long n = Math.Min(Records, 600);
                for (long r = 0; r < n; r += 60)
                {
                    if (ReadRecords(r, 1, buf) < 1) break;
                    int v = (int)At(buf, 0, d);
                    if (v != 0) return v;
                }
                return 0;
            }
        }

        // Reads count records from record `from` into buf (which must hold count * BufLen bytes). Returns the whole records read.
        public int ReadRecords(long from, int count, byte[] buf)
        {
            if (from < 0 || from >= Records || count <= 0) return 0;
            Fs.Position = DataOff + from * (long)BufLen;
            int got = ReadFull(Fs, buf, 0, count * BufLen);
            return got / BufLen;
        }

        // Several channels at once, one pass over records [from, from + count): result[i][k] = channel i at record from + k.
        // A channel the file does not have comes back as null. Reads in 4 MB blocks.
        public double[][] Channels(string[] names, long from, long count)
        {
            if (from < 0) from = 0;
            count = Math.Max(0, Math.Min(count, Records - from));
            VarDef[] defs = new VarDef[names.Length];
            double[][] outp = new double[names.Length][];
            for (int i = 0; i < names.Length; i++) { defs[i] = Var(names[i]); if (defs[i] != null) outp[i] = new double[count]; }
            int per = Math.Max(1, (4 << 20) / BufLen);
            byte[] buf = new byte[per * BufLen];
            long k = 0;
            while (k < count)
            {
                int want = (int)Math.Min(per, count - k);
                int recs = ReadRecords(from + k, want, buf);
                if (recs <= 0) break;
                for (int r = 0; r < recs; r++, k++)
                {
                    int o = r * BufLen;
                    for (int i = 0; i < defs.Length; i++) if (defs[i] != null) outp[i][k] = At(buf, o, defs[i]);
                }
                if (recs < want) break;
            }
            if (k < count) for (int i = 0; i < outp.Length; i++) if (outp[i] != null) Array.Resize(ref outp[i], (int)k);
            return outp;
        }

        public double[] Channel(string name, long from, long count) { return Channels(new string[] { name }, from, count)[0]; }
    }
}
