// ibt-replay-harness.cs - runs irdash's real IbtReplay class (cut out of dash\src\irdash.cs by tools-test.ps1) against stand-ins for
// the rest of irdash, so the replay can be tested without irdash, the sim or any port. Args: <ibt> <speed> <seconds to run>
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

namespace IRDash
{
    sealed class VarDef { public string Name; public int Type, Offset, Count; }
    static class Log { public static void W(string s) { Console.Error.WriteLine("log: " + s); } }
    static class Json { public static string Str(string s) { return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "\\n") + "\""; } }

    static class Sdk
    {
        public static volatile int FakePumpMs = 33;
        public static bool Pretend = false;
        public static string Yaml = "";
        public static Dictionary<string, double> Last = new Dictionary<string, double>();
        public static void FakeSession(string y) { Yaml = y; }
        public static void FakeSet(Dictionary<string, double> v) { Pretend = true; lock (Last) foreach (KeyValuePair<string, double> kv in v) Last[kv.Key] = kv.Value; }
    }

    static class TrackMaps
    {
        internal sealed class Ibt
        {
            public FileStream fs; public int bufLen, dataOff; public long records; public string yaml = "";
            public Dictionary<string, VarDef> vars = new Dictionary<string, VarDef>();
        }
        // same as irdash's TrackMaps.OpenIbt
        internal static Ibt OpenIbt(string path, bool wantVars)
        {
            FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            byte[] h = new byte[144];
            if (fs.Read(h, 0, h.Length) < h.Length) { fs.Dispose(); return null; }
            Ibt t = new Ibt();
            t.fs = fs;
            int infoLen = BitConverter.ToInt32(h, 16), infoOff = BitConverter.ToInt32(h, 20);
            int numVars = BitConverter.ToInt32(h, 24), varOff = BitConverter.ToInt32(h, 28);
            t.bufLen = BitConverter.ToInt32(h, 36); t.dataOff = BitConverter.ToInt32(h, 52);
            t.records = (fs.Length - t.dataOff) / t.bufLen;
            byte[] info = new byte[infoLen];
            fs.Position = infoOff; fs.Read(info, 0, infoLen);
            int z = Array.IndexOf(info, (byte)0); if (z < 0) z = infoLen;
            t.yaml = Encoding.GetEncoding(28591).GetString(info, 0, z);
            byte[] vh = new byte[numVars * 144];
            fs.Position = varOff; fs.Read(vh, 0, vh.Length);
            for (int i = 0; i < numVars; i++)
            {
                int b = i * 144;
                int len = Array.IndexOf(vh, (byte)0, b + 16, 32) - (b + 16); if (len < 0) len = 32;
                VarDef v = new VarDef();
                v.Name = Encoding.ASCII.GetString(vh, b + 16, len);
                v.Type = BitConverter.ToInt32(vh, b); v.Offset = BitConverter.ToInt32(vh, b + 4); v.Count = BitConverter.ToInt32(vh, b + 8);
                t.vars[v.Name] = v;
            }
            return t;
        }
    }

    // ---- IbtReplay is pasted here by the test ----
//IBTREPLAY//

    static class Harness
    {
        static int Main(string[] a)
        {
            string err = IbtReplay.Start(a[0], double.Parse(a[1], CultureInfo.InvariantCulture), 0, 0);
            if (err != null) { Console.WriteLine("START-FAILED " + err); return 1; }
            Thread.Sleep((int)(double.Parse(a[2], CultureInfo.InvariantCulture) * 1000));
            Console.WriteLine("STATUS " + IbtReplay.Status());
            Console.WriteLine("YAMLLEN " + Sdk.Yaml.Length);
            lock (Sdk.Last)
            {
                double pi = Sdk.Last.ContainsKey("PlayerCarIdx") ? Sdk.Last["PlayerCarIdx"] : -9;
                Console.WriteLine("PLAYER " + pi);
                Console.WriteLine("LAP " + (Sdk.Last.ContainsKey("Lap") ? Sdk.Last["Lap"] : -9));
                Console.WriteLine("FLAGS " + (Sdk.Last.ContainsKey("SessionFlags") ? Sdk.Last["SessionFlags"] : -9));
                Console.WriteLine("IBTTYPE_FLAGS " + IbtReplay.TypeFor("SessionFlags") + " IBTTYPE_TIME " + IbtReplay.TypeFor("SessionTime") + " IBTTYPE_LAP " + IbtReplay.TypeFor("Lap") + " IBTTYPE_ONPIT " + IbtReplay.TypeFor("OnPitRoad") + " IBTTYPE_SPEED " + IbtReplay.TypeFor("Speed"));
                string k = "CarIdxLapDistPct_" + (int)pi;
                Console.WriteLine("PLAYERSLOT " + (Sdk.Last.ContainsKey(k) ? Sdk.Last[k] : -9) + " OTHERSLOT " + (Sdk.Last.ContainsKey("CarIdxLapDistPct_" + (((int)pi + 1) % 64)) ? Sdk.Last["CarIdxLapDistPct_" + (((int)pi + 1) % 64)] : -9));
            }
            IbtReplay.Stop();
            Thread.Sleep(300);
            Console.WriteLine("STOPPED " + IbtReplay.Status());
            return 0;
        }
    }
}
