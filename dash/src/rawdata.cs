// rawdata.cs - the RAW TIME VIEWER's data (rawdata.html): every channel that matters, over TIME, for ANY drive.
//   GET /analysis/raw?id=<telemetry file | Vault id>&from=<s>&to=<s>&hz=<n>
// Why it exists (Peter 2026-10-18, a qualifying run with one out-lap and no full lap: "just show me the data"): every other
// engine is built on whole laps, so a drive without one showed nothing. This one needs no lap at all. Time is seconds from the
// first record of the file. from / to pick a window (default: the whole drive); hz the sample rate (default: about 3000 points
// in the window, so the first view of an hour-long drive is still quick; the page asks again, finer, when it zooms).
// Values are the file's own records (the one nearest each sample time), never averaged or made up. Speeds in mph, steering in
// degrees, g for the accelerations, fuel in litres (the page shows gallons). A channel the car's file does not have is null.
// Also: events (pit lane in / out, line crossings with iRacing's lap time, incidents, off-tracks, in / out of the car), the
// laps as the lap store sees them (full, out, in, pit, partial: the timeline strip), and a plain summary of the drive
// (coach.cs shows it when there is nothing to compare). 503 while he drives; the newest file while the sim runs is refused
// (iRacing is still writing it). Reads only, BelowNormal.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IRDash
{
    static partial class Analysis
    {
        // key, the file's channel, scale to the unit shown, unit, decimals in the reply
        static readonly string[][] RawChans = new string[][] {
            new string[] { "spd", "Speed", "2.2369363", "mph", "1" },
            new string[] { "thr", "Throttle", "1", "0-1", "3" },
            new string[] { "brk", "Brake", "1", "0-1", "3" },
            new string[] { "steer", "SteeringWheelAngle", "57.2957795", "deg", "1" },
            new string[] { "gear", "Gear", "1", "", "0" },
            new string[] { "rpm", "RPM", "1", "rpm", "0" },
            new string[] { "pct", "LapDistPct", "1", "0-1", "4" },
            new string[] { "lap", "Lap", "1", "", "0" },
            new string[] { "on", "IsOnTrack", "1", "", "0" },
            new string[] { "pit", "OnPitRoad", "1", "", "0" },
            new string[] { "lf", "LFspeed", "2.2369363", "mph", "1" },
            new string[] { "rf", "RFspeed", "2.2369363", "mph", "1" },
            new string[] { "lr", "LRspeed", "2.2369363", "mph", "1" },
            new string[] { "rr", "RRspeed", "2.2369363", "mph", "1" },
            new string[] { "latG", "LatAccel", "0.1019716", "g", "2" },
            new string[] { "longG", "LongAccel", "0.1019716", "g", "2" },
            new string[] { "fuel", "FuelLevel", "1", "l", "2" },
        };
        // read but not sent as traces: events and the summary
        static readonly string[] RawExtra = new string[] { "PlayerTrackSurface", "PlayerCarMyIncidentCount", "LapLastLapTime", "SessionNum" };

        sealed class RawFile
        {
            public string Sig = "", Path = "", File = "", Car = "", Track = "", Config = "", Yaml = "";
            public int N, Rate = 60;
            public double[] St, Lat, Lon;
            public float[][] Ch;                  // RawChans order, null = the file has no such channel
            public float[] Surf, Inc, Llt, Sn;    // RawExtra (null = not in the file)
            public string EventsJson = "[]", LapsJson = "[]", SummaryJson = "null";
        }

        static readonly List<RawFile> rawCache = new List<RawFile>();

        public static string RawRoute(Dictionary<string, string> q, out int code)
        {
            code = 200;
            if (Program.IsDriving) { code = 503; return Err("Not while driving"); }
            string id = Q(q, "id");
            string file = ResolveFile(id);
            if (file == null) { code = 404; return Err("no such drive"); }
            try { if (Career.OnlineOnly(new FileInfo(file))) { code = 409; return Err("Online-only in OneDrive: run tools\\keep-iracing-local.cmd"); } }
            catch { code = 404; return Err("no such drive"); }
            if (StillWriting(file)) { code = 409; return Err("iRacing is still writing this drive. It opens when the sim is closed."); }
            double from = double.NaN, to = double.NaN, hz = 0;
            double.TryParse(Q(q, "from"), NumberStyles.Float, Inv, out from); if (Q(q, "from").Length == 0) from = double.NaN;
            double.TryParse(Q(q, "to"), NumberStyles.Float, Inv, out to); if (Q(q, "to").Length == 0) to = double.NaN;
            double.TryParse(Q(q, "hz"), NumberStyles.Float, Inv, out hz);
            ThreadPriority was = Thread.CurrentThread.Priority;
            try
            {
                Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
                return RawJson(file, from, to, hz);
            }
            catch (Exception ex) { Log.W("raw: " + ex.Message); code = 500; return Err("could not read that file"); }
            finally { try { Thread.CurrentThread.Priority = was; } catch { } }
        }

        // the newest telemetry file while the sim process is up: iRacing is still writing it (CLAUDE.md: never read it during a session)
        static bool StillWriting(string file)
        {
            try
            {
                if (Process.GetProcessesByName("iRacingSim64DX11").Length == 0) return false;
                string dir = Path.GetDirectoryName(file), newest = null; DateTime nt = DateTime.MinValue;
                foreach (string f in Directory.GetFiles(dir, "*.ibt")) { DateTime w = File.GetLastWriteTime(f); if (newest == null || w > nt) { newest = f; nt = w; } }
                return newest != null && string.Equals(Path.GetFullPath(newest), Path.GetFullPath(file), StringComparison.OrdinalIgnoreCase);
            }
            catch { return true; }
        }

        static RawFile RawGet(string path)
        {
            FileInfo fi = new FileInfo(path);
            string sig = fi.FullName + "|" + fi.Length + "|" + fi.LastWriteTimeUtc.Ticks;
            lock (gate) foreach (RawFile r in rawCache) if (r.Sig == sig) return r;
            RawFile n = RawLoad(path);
            n.Sig = sig;
            lock (gate)
            {
                rawCache.Add(n);
                while (rawCache.Count > 2) rawCache.RemoveAt(0);     // an hour of driving is about 15 MB here
            }
            return n;
        }

        static RawFile RawLoad(string path)
        {
            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
            if (t == null) throw new IOException("not a telemetry file");
            RawFile r = new RawFile();
            using (t.fs)
            {
                r.Path = path; r.File = Path.GetFileName(path); r.Yaml = t.yaml ?? "";
                r.Track = TrackMaps.YamlValue(r.Yaml, "TrackDisplayName"); if (r.Track.Length == 0) r.Track = TrackMaps.YamlValue(r.Yaml, "TrackName");
                r.Config = TrackMaps.YamlValue(r.Yaml, "TrackConfigName"); r.Car = CarOf(r.Yaml);
                byte[] h = new byte[12]; t.fs.Position = 0; t.fs.Read(h, 0, 12); int rate = BitConverter.ToInt32(h, 8); if (rate > 0 && rate <= 360) r.Rate = rate;
                VarDef vSt = V(t, "SessionTime");
                if (vSt == null) throw new IOException("the file has no time channel");
                VarDef[] defs = new VarDef[RawChans.Length]; float[] scale = new float[RawChans.Length];
                for (int c = 0; c < RawChans.Length; c++) { defs[c] = V(t, RawChans[c][1]); scale[c] = float.Parse(RawChans[c][2], Inv); }
                VarDef vLat = V(t, "Lat"), vLon = V(t, "Lon");
                VarDef[] ex = new VarDef[RawExtra.Length]; for (int c = 0; c < ex.Length; c++) ex[c] = V(t, RawExtra[c]);
                int n = (int)Math.Min(t.records, 2000000L);
                r.St = new double[n]; r.Ch = new float[RawChans.Length][];
                for (int c = 0; c < RawChans.Length; c++) if (defs[c] != null) r.Ch[c] = new float[n];
                if (vLat != null && vLon != null) { r.Lat = new double[n]; r.Lon = new double[n]; }
                float[][] xs = new float[ex.Length][]; for (int c = 0; c < ex.Length; c++) if (ex[c] != null) xs[c] = new float[n];
                int per = Math.Max(1, (4 << 20) / t.bufLen); byte[] buf = new byte[per * t.bufLen];
                t.fs.Position = t.dataOff;
                int i = 0;
                while (i < n)
                {
                    int want = Math.Min(per, n - i), got = 0;
                    while (got < want * t.bufLen) { int rd = t.fs.Read(buf, got, want * t.bufLen - got); if (rd <= 0) break; got += rd; }
                    int recs = got / t.bufLen; if (recs == 0) break;
                    for (int k = 0; k < recs; k++, i++)
                    {
                        int o = k * t.bufLen;
                        r.St[i] = At(buf, o, vSt);
                        for (int c = 0; c < defs.Length; c++) if (defs[c] != null) r.Ch[c][i] = (float)(At(buf, o, defs[c]) * scale[c]);
                        if (r.Lat != null) { r.Lat[i] = At(buf, o, vLat); r.Lon[i] = At(buf, o, vLon); }
                        for (int c = 0; c < ex.Length; c++) if (ex[c] != null) xs[c][i] = (float)At(buf, o, ex[c]);
                    }
                    if (recs < want) break;
                }
                r.N = i;
                r.Surf = xs[0]; r.Inc = xs[1]; r.Llt = xs[2]; r.Sn = xs[3];
            }
            r.EventsJson = RawEvents(r);
            r.LapsJson = RawLaps(r);
            r.SummaryJson = RawSummary(r);
            return r;
        }

        static float[] RawCh(RawFile r, string key) { for (int c = 0; c < RawChans.Length; c++) if (RawChans[c][0] == key) return r.Ch[c]; return null; }
        static double RelT(RawFile r, int i) { return r.N > 0 ? r.St[i] - r.St[0] : 0; }
        static bool OnAt(RawFile r, float[] on, int i) { return on == null || on[i] > 0.5f; }

        static string RawEvents(RawFile r)
        {
            StringBuilder sb = new StringBuilder(2048); sb.Append('[');
            int count = 0;
            Action<int, string, string> add = delegate (int i, string kind, string extra)
            {
                if (count >= 3000) return;
                if (count++ > 0) sb.Append(',');
                sb.Append("{\"t\":").Append(F(RelT(r, i), "0.00")).Append(",\"k\":").Append(Json_.S(kind)); if (extra != null) sb.Append(extra); sb.Append('}');
            };
            float[] on = RawCh(r, "on"), pit = RawCh(r, "pit"), lap = RawCh(r, "lap"), pct = RawCh(r, "pct");
            int offStart = -1; double runT = r.N > 0 ? r.St[0] : 0;
            for (int i = 1; i < r.N; i++)
            {
                bool gap = r.St[i] - r.St[i - 1] > 0.5;
                bool o0 = OnAt(r, on, i - 1), o1 = OnAt(r, on, i);
                if (o1 && (!o0 || gap)) runT = r.St[i];
                if (on != null && (o1 && (!o0 || gap))) add(i, "carIn", null);                  // on track again (got in, or after a reset / tow)
                if (on != null && (!o1 && o0 && !gap)) add(i, "carOut", null);
                if (!o1) { offStart = -1; continue; }
                // the first second in the car: the sim is still setting its flags (08-36-50: "pit lane" 0.02 s after the start, in the pit box)
                if (pit != null && !gap && o0 && r.St[i] - runT >= 1)
                {
                    if (pit[i] > 0.5f && pit[i - 1] <= 0.5f) add(i, "pitIn", null);
                    if (pit[i] <= 0.5f && pit[i - 1] > 0.5f) add(i, "pitOut", null);
                }
                if (lap != null && pct != null && !gap && o0 && lap[i] > lap[i - 1] && pct[i - 1] > 0.8f && pct[i] < 0.2f)
                {
                    // iRacing's own time for the lap just ended, 1.5 to 2.5 s after the line (when it gave one)
                    double lt = -1; int a = Math.Min(r.N - 1, i + r.Rate * 3 / 2), b = Math.Min(r.N - 1, i + r.Rate * 5 / 2);
                    if (r.Llt != null) for (int k = a; k <= b; k++) if (r.Llt[k] > 1) { lt = r.Llt[k]; break; }
                    add(i, "line", ",\"lap\":" + ((int)lap[i]).ToString(Inv) + (lt > 0 ? ",\"time\":" + F(lt, "0.000") : ""));
                }
                if (r.Inc != null && !gap && r.Inc[i] > r.Inc[i - 1]) add(i, "inc", ",\"n\":" + ((int)(r.Inc[i] - r.Inc[i - 1])).ToString(Inv) + ",\"total\":" + ((int)r.Inc[i]).ToString(Inv));
                if (r.Surf != null)
                {
                    bool off = (int)r.Surf[i] == 0;
                    if (off && offStart < 0) offStart = i;
                    if ((!off || i == r.N - 1) && offStart >= 0)
                    {
                        double dur = r.St[i] - r.St[offStart];
                        if (dur >= 0.1) add(offStart, "off", ",\"dur\":" + F(dur, "0.00"));
                        offStart = -1;
                    }
                }
            }
            sb.Append(']');
            return sb.ToString();
        }

        // the laps as the lap store sees them (the same rules as every other page): the coloured blocks of the timeline strip
        static string RawLaps(RawFile r)
        {
            StringBuilder sb = new StringBuilder(2048); sb.Append('[');
            try
            {
                Sess s = Get(r.Path);
                bool first = true;
                foreach (LapTrace l in s.Laps)
                {
                    int a = Math.Max(0, Math.Min(r.N - 1, l.RecA)), b = Math.Max(0, Math.Min(r.N - 1, l.RecB - 1));
                    if (!first) sb.Append(','); first = false;
                    string kind = l.Clean ? "full" : l.Skip.Length > 0 ? l.Skip : "partial";
                    if (l.Skip == "off" && l.Tm != null) kind = "off";
                    sb.Append("{\"lap\":").Append(l.Lap).Append(",\"kind\":").Append(Json_.S(kind)).Append(",\"from\":").Append(F(RelT(r, a), "0.00")).Append(",\"to\":").Append(F(RelT(r, b), "0.00"));
                    sb.Append(",\"time\":").Append(l.Tm != null ? F(l.Time, "0.000") : "null").Append(",\"counted\":").Append(Counted(l) ? "true" : "false").Append('}');
                }
            }
            catch (Exception ex) { Log.W("raw: no laps for " + r.File + ": " + ex.Message); }      // a file the lap store cannot read still shows its traces
            sb.Append(']');
            return sb.ToString();
        }

        // what the drive held, in plain numbers: the coach shows this when there is nothing to compare, so the screen is never empty
        static string RawSummary(RawFile r)
        {
            float[] on = RawCh(r, "on"), pit = RawCh(r, "pit"), spd = RawCh(r, "spd"), fuel = RawCh(r, "fuel"), rpm = RawCh(r, "rpm"), lat = RawCh(r, "latG"), lng = RawCh(r, "longG");
            double onSec = 0, moving = 0, pitSec = 0, dist = 0, top = 0, topAt = 0, used = 0, maxRpm = 0, maxLat = 0, maxBrakeG = 0;
            int offs = 0, firstOn = -1, lastOn = -1; bool wasOff = false;
            double inc0 = double.NaN, inc1 = double.NaN;
            for (int i = 0; i < r.N; i++)
            {
                if (!OnAt(r, on, i)) { wasOff = false; continue; }
                if (firstOn < 0) firstOn = i; lastOn = i;
                double dt = i > 0 ? r.St[i] - r.St[i - 1] : 0;
                bool cont = i > 0 && dt > 0 && dt < 0.5 && OnAt(r, on, i - 1);
                double v = spd != null ? spd[i] : 0;
                if (cont)
                {
                    onSec += dt;
                    if (v > 2) moving += dt;
                    if (pit != null && pit[i] > 0.5f) pitSec += dt;
                    if (spd != null) dist += 0.5 * (spd[i] + spd[i - 1]) / 3600.0 * dt;      // mph x hours = miles
                    if (fuel != null && fuel[i] < fuel[i - 1]) used += fuel[i - 1] - fuel[i];    // a refuel goes up: not "used"
                }
                if (v > top) { top = v; topAt = RelT(r, i); }
                if (rpm != null && rpm[i] > maxRpm) maxRpm = rpm[i];
                if (lat != null && Math.Abs(lat[i]) > maxLat && Math.Abs(lat[i]) < 8) maxLat = Math.Abs(lat[i]);
                if (lng != null && -lng[i] > maxBrakeG && -lng[i] < 8) maxBrakeG = -lng[i];
                if (r.Inc != null) { if (double.IsNaN(inc0)) inc0 = r.Inc[i]; inc1 = r.Inc[i]; }
                bool off = r.Surf != null && (int)r.Surf[i] == 0;
                if (off && !wasOff) offs++;
                wasOff = off;
            }
            int full = 0, outL = 0, inL = 0, part = 0, pitL = 0; double best = 0;
            try
            {
                Sess s = Get(r.Path);
                foreach (LapTrace l in s.Laps)
                {
                    if (l.Clean || (l.Skip == "off" && l.Tm != null)) { full++; if (Counted(l) && (best <= 0 || l.Time < best)) best = l.Time; }
                    else if (l.Skip == "out") outL++; else if (l.Skip == "in") inL++; else if (l.Skip == "pit") pitL++; else part++;
                }
            }
            catch { }
            string type = "";
            if (r.Sn != null && firstOn >= 0) type = SessionTypeOf(r.Yaml, (int)r.Sn[firstOn]);
            StringBuilder sb = new StringBuilder(600);
            sb.Append("{\"file\":").Append(Json_.S(r.File)).Append(",\"car\":").Append(Json_.S(r.Car)).Append(",\"track\":").Append(Json_.S(r.Track)).Append(",\"config\":").Append(Json_.S(r.Config));
            sb.Append(",\"type\":").Append(Json_.S(type)).Append(",\"date\":").Append(Json_.S(DateOf(r.File)));
            sb.Append(",\"seconds\":").Append(F(r.N > 0 ? r.St[r.N - 1] - r.St[0] : 0, "0.0")).Append(",\"onTrackSec\":").Append(F(onSec, "0.0")).Append(",\"movingSec\":").Append(F(moving, "0.0"));
            sb.Append(",\"pitSec\":").Append(F(pitSec, "0.0")).Append(",\"miles\":").Append(F(dist, "0.00"));
            sb.Append(",\"topMph\":").Append(spd != null ? F(top, "0.0") : "null").Append(",\"topAt\":").Append(F(topAt, "0.0"));
            sb.Append(",\"fuelUsedL\":").Append(fuel != null ? F(used, "0.00") : "null").Append(",\"fuelUsedGal\":").Append(fuel != null ? F(used / 3.785411784, "0.00") : "null");
            sb.Append(",\"incidents\":").Append(double.IsNaN(inc0) ? "null" : ((int)(inc1 - inc0)).ToString(Inv)).Append(",\"offTracks\":").Append(r.Surf != null ? offs.ToString(Inv) : "null");
            sb.Append(",\"maxRpm\":").Append(rpm != null ? F(maxRpm, "0") : "null").Append(",\"maxLatG\":").Append(lat != null ? F(maxLat, "0.00") : "null").Append(",\"maxBrakeG\":").Append(lng != null ? F(maxBrakeG, "0.00") : "null");
            sb.Append(",\"laps\":{\"full\":").Append(full).Append(",\"out\":").Append(outL).Append(",\"in\":").Append(inL).Append(",\"pit\":").Append(pitL).Append(",\"partial\":").Append(part).Append(",\"best\":").Append(best > 0 ? F(best, "0.000") : "null").Append('}');
            sb.Append(",\"from\":").Append(firstOn >= 0 ? F(RelT(r, firstOn), "0.0") : "null").Append(",\"to\":").Append(lastOn >= 0 ? F(RelT(r, lastOn), "0.0") : "null").Append('}');
            return sb.ToString();
        }

        // "Open Qualify", "Practice", "Race" ... for the session number the drive was in
        static string SessionTypeOf(string yaml, int num)
        {
            foreach (Match m in Regex.Matches(yaml ?? "", @"- SessionNum:\s*(\d+)\s*\n(.*?)(?=\n\s*- SessionNum:|\n\S|$)", RegexOptions.Singleline))
                if (m.Groups[1].Value == num.ToString(Inv)) return TrackMaps.YamlValue(m.Groups[2].Value, "SessionType");
            return "";
        }

        internal static string DriveSummary(string file)
        {
            try { return RawGet(file).SummaryJson; }
            catch (Exception ex) { Log.W("raw: summary " + Path.GetFileName(file) + ": " + ex.Message); return "null"; }
        }

        static int RawFind(RawFile r, double tRel)
        {
            double want = r.St[0] + tRel;
            int lo = 0, hi = r.N - 1;
            if (want <= r.St[0]) return 0;
            if (want >= r.St[hi]) return hi;
            while (lo + 1 < hi) { int mid = (lo + hi) >> 1; if (r.St[mid] <= want) lo = mid; else hi = mid; }
            return want - r.St[lo] <= r.St[hi] - want ? lo : hi;
        }

        internal static string RawJson(string file, double from, double to, double hz)
        {
            RawFile r = RawGet(file);
            if (r.N == 0) throw new IOException("the file has no records");
            double total = r.St[r.N - 1] - r.St[0];
            if (double.IsNaN(from) || from < 0) from = 0;
            if (double.IsNaN(to) || to > total) to = total;
            if (to < from) { double x = from; from = to; to = x; }
            int ia = RawFind(r, from), ib = RawFind(r, to);
            if (ib < ia) ib = ia;
            int span = ib - ia + 1;
            int step = hz > 0 ? Math.Max(1, (int)Math.Round(r.Rate / hz)) : Math.Max(1, (int)Math.Ceiling(span / 3000.0));
            step = Math.Max(step, (int)Math.Ceiling(span / 20000.0));       // never more than 20000 points in one reply
            List<int> idx = new List<int>(span / step + 2);
            for (int i = ia; i <= ib; i += step) idx.Add(i);
            if (idx[idx.Count - 1] != ib) idx.Add(ib);
            StringBuilder sb = new StringBuilder(64 + idx.Count * 120);
            sb.Append("{\"v\":1,\"file\":").Append(Json_.S(r.File)).Append(",\"car\":").Append(Json_.S(r.Car)).Append(",\"track\":").Append(Json_.S(r.Track)).Append(",\"config\":").Append(Json_.S(r.Config));
            sb.Append(",\"rate\":").Append(r.Rate).Append(",\"records\":").Append(r.N).Append(",\"total\":").Append(F(total, "0.00"));
            sb.Append(",\"from\":").Append(F(RelT(r, ia), "0.00")).Append(",\"to\":").Append(F(RelT(r, ib), "0.00")).Append(",\"step\":").Append(step).Append(",\"n\":").Append(idx.Count);
            sb.Append(",\"lengthM\":").Append(F(LengthOf(r.Yaml), "0.0"));
            sb.Append(",\"units\":{");
            for (int c = 0; c < RawChans.Length; c++) { if (c > 0) sb.Append(','); sb.Append('"').Append(RawChans[c][0]).Append("\":").Append(Json_.S(RawChans[c][3])); }
            sb.Append("},\"t\":[");
            for (int k = 0; k < idx.Count; k++) { if (k > 0) sb.Append(','); sb.Append(F(RelT(r, idx[k]), "0.000")); }
            sb.Append(']');
            for (int c = 0; c < RawChans.Length; c++)
            {
                sb.Append(",\"").Append(RawChans[c][0]).Append("\":");
                float[] a = r.Ch[c];
                if (a == null) { sb.Append("null"); continue; }
                string fmt = RawChans[c][4] == "0" ? "0" : "0." + new string('#', int.Parse(RawChans[c][4], Inv));
                sb.Append('[');
                for (int k = 0; k < idx.Count; k++)
                {
                    if (k > 0) sb.Append(',');
                    float v = a[idx[k]];
                    if (float.IsNaN(v) || float.IsInfinity(v)) sb.Append("null"); else sb.Append(((double)v).ToString(fmt, Inv));
                }
                sb.Append(']');
            }
            if (r.Lat == null) sb.Append(",\"lat\":null,\"lon\":null");
            else
            {
                sb.Append(",\"lat\":[");
                for (int k = 0; k < idx.Count; k++) { if (k > 0) sb.Append(','); sb.Append(r.Lat[idx[k]].ToString("0.0000000", Inv)); }
                sb.Append("],\"lon\":[");
                for (int k = 0; k < idx.Count; k++) { if (k > 0) sb.Append(','); sb.Append(r.Lon[idx[k]].ToString("0.0000000", Inv)); }
                sb.Append(']');
            }
            sb.Append(",\"events\":").Append(r.EventsJson).Append(",\"laps\":").Append(r.LapsJson).Append(",\"summary\":").Append(r.SummaryJson).Append('}');
            return sb.ToString();
        }
    }
}
