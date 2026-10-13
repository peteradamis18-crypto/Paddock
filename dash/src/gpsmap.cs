// Real GPS track maps from .ibt Lat/Lon/Alt (card P0-05). Reads only Peter's own telemetry, and only through the lap
// store in analysis.cs (which never picks the newest file while a session runs). Lat/Lon become local metres with the
// same projection the map builder uses (x east, y north), the fixes stay ordered by LapDistPct (nonfinite, duplicate
// and gapped fixes are rejected), and the measured lap is fitted onto the track geometry irdash already holds with a
// uniform scale, rotation and translation (least squares over corresponding resampled points, never nearest segments).
// Alt is kept in the JSON as metadata only; it never touches screen x/y. The result is a sidecar
// dash\maps\<key>.gps.json that TrackMaps appends to /trackmap as "gps". Nothing here draws.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDash
{
    static partial class Analysis
    {
        static readonly CultureInfo GInv = CultureInfo.InvariantCulture;

        // one measured lap, before any fitting (60 Hz fixes)
        sealed class GpsLap
        {
            public string File = "", Key = "", Track = "", TrackName = "", Config = "";
            public int Lap; public double Time, LengthM;
            public int N;
            public double[] Pct, X, Y, Alt;
        }

        // the measured lap fitted onto the geometry irdash already holds
        sealed class GpsFit
        {
            public string File = "", Key = "", Track = "", Config = "", RefSource = "";
            public int Lap; public double LapTime;
            public int N;
            public double Scale = 1, RotationDeg, MeanErr, MaxErr;
            public int ApexCount; public double ApexMaxErr = -1;
            public double[] Pct, X, Y, Alt;             // fitted line, same metres as the map geometry; Alt is metadata
        }

        // ---- reading: the quickest clean full lap in one file that also carries Lat/Lon ----
        static GpsLap ReadLap(string path, out string why)
        {
            why = "";
            Sess s;
            try { s = Load(path); }
            catch (Exception ex) { why = ex.Message; return null; }
            LapTrace pick = null;
            foreach (LapTrace l in s.Laps)
            {
                if (!l.Clean || l.Time < 15 || l.Time > 900 || l.Tm == null) continue;     // valid lap, no pit, not off track
                if (pick == null || l.Time < pick.Time) pick = l;
            }
            if (pick == null) { why = "no clean full lap"; return null; }

            TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
            if (t == null) { why = "not a telemetry file"; return null; }
            using (t.fs)
            {
                VarDef vPct = V(t, "LapDistPct"), vLat = V(t, "Lat"), vLon = V(t, "Lon"), vAlt = V(t, "Alt");
                if (vPct == null || vLat == null || vLon == null) { why = "this file has no Lat/Lon"; return null; }
                int a = pick.RecA, b = pick.RecB;
                long cnt = b - a;
                if (cnt < 50 || cnt > 400000) { why = "lap too short to map"; return null; }
                byte[] buf = new byte[cnt * t.bufLen];
                t.fs.Position = t.dataOff + (long)a * t.bufLen;
                int got = 0;
                while (got < buf.Length) { int r = t.fs.Read(buf, got, buf.Length - got); if (r <= 0) break; got += r; }
                int recs = got / t.bufLen;

                List<double> p = new List<double>(), xs = new List<double>(), ys = new List<double>(), al = new List<double>();
                double lon0 = 0, lat0 = 0, last = -1; bool first = true;
                for (int k = 0; k < recs; k++)
                {
                    int o = k * t.bufLen;
                    double pct = Read(buf, o + vPct.Offset, vPct.Type);
                    double lat = Read(buf, o + vLat.Offset, vLat.Type);
                    double lon = Read(buf, o + vLon.Offset, vLon.Type);
                    double alt = vAlt != null ? Read(buf, o + vAlt.Offset, vAlt.Type) : 0;
                    if (double.IsNaN(pct) || double.IsInfinity(pct) || double.IsNaN(lat) || double.IsInfinity(lat) || double.IsNaN(lon) || double.IsInfinity(lon)) continue;
                    if (lat == 0 && lon == 0) continue;                     // no fix
                    if (pct < 0 || pct > 1) continue;
                    if (first) { lon0 = lon; lat0 = lat; first = false; }
                    else
                    {
                        if (pct - last > 0.05) { why = "a gap of " + ((pct - last) * 100).ToString("0.0", GInv) + "% in the lap"; return null; }
                        if (pct <= last + 1e-6) continue;                    // duplicate lap fraction
                    }
                    last = pct;
                    double kx = 111320.0 * Math.Cos(lat0 * Math.PI / 180.0), ky = 110540.0;
                    p.Add(pct); xs.Add((lon - lon0) * kx); ys.Add((lat - lat0) * ky); al.Add(alt);
                }
                if (p.Count < 100) { why = "only " + p.Count + " GPS fixes in the lap"; return null; }
                GpsLap g = new GpsLap();
                g.File = s.File; g.Key = s.Key; g.Track = s.Track; g.TrackName = s.TrackName; g.Config = s.Config;
                g.Lap = pick.Lap; g.Time = pick.Time; g.LengthM = s.LengthM;
                g.N = p.Count; g.Pct = p.ToArray(); g.X = xs.ToArray(); g.Y = ys.ToArray(); g.Alt = al.ToArray();
                return g;
            }
        }

        static string KeyOf(string path)
        {
            try
            {
                TrackMaps.Ibt t = TrackMaps.OpenIbt(path, false);
                if (t == null) return null;
                using (t.fs) return TrackMaps.MakeKey(TrackMaps.YamlValue(t.yaml, "TrackID"), TrackMaps.YamlValue(t.yaml, "TrackName"));
            }
            catch { return null; }
        }

        // ---- the lap fraction grid and the fit ----
        static void ResampleGps(GpsLap g, int n, double[] pct, double[] x, double[] y, double[] alt)
        {
            int N = g.N;
            for (int i = 0; i < n; i++)
            {
                double q = i / (double)n;
                pct[i] = q;
                if (q <= g.Pct[0]) { x[i] = g.X[0]; y[i] = g.Y[0]; alt[i] = g.Alt[0]; continue; }
                if (q >= g.Pct[N - 1]) { x[i] = g.X[N - 1]; y[i] = g.Y[N - 1]; alt[i] = g.Alt[N - 1]; continue; }
                int lo = 0, hi = N - 1;
                while (lo + 1 < hi) { int mid = (lo + hi) >> 1; if (g.Pct[mid] <= q) lo = mid; else hi = mid; }
                double span = g.Pct[hi] - g.Pct[lo], f = span > 1e-9 ? (q - g.Pct[lo]) / span : 0;
                x[i] = g.X[lo] + (g.X[hi] - g.X[lo]) * f;
                y[i] = g.Y[lo] + (g.Y[hi] - g.Y[lo]) * f;
                alt[i] = g.Alt[lo] + (g.Alt[hi] - g.Alt[lo]) * f;
            }
        }

        // uniform scale + rotation + translation, least squares over corresponding points: X = a x - b y + tx, Y = b x + a y + ty
        static void Similarity(double[] x, double[] y, double[] X, double[] Y, int n,
                               out double a, out double b, out double tx, out double ty, out double mean, out double max)
        {
            double mx = 0, my = 0, mX = 0, mY = 0;
            for (int i = 0; i < n; i++) { mx += x[i]; my += y[i]; mX += X[i]; mY += Y[i]; }
            mx /= n; my /= n; mX /= n; mY /= n;
            double S = 0, Ac = 0, Bc = 0;
            for (int i = 0; i < n; i++)
            {
                double px = x[i] - mx, py = y[i] - my, Xc = X[i] - mX, Yc = Y[i] - mY;
                S += px * px + py * py; Ac += Xc * px + Yc * py; Bc += Yc * px - Xc * py;
            }
            if (S < 1e-9) { a = 1; b = 0; tx = mX - mx; ty = mY - my; mean = 0; max = 0; return; }
            a = Ac / S; b = Bc / S;
            tx = mX - (a * mx - b * my); ty = mY - (b * mx + a * my);
            double sum = 0; max = 0;
            for (int i = 0; i < n; i++)
            {
                double qx = a * x[i] - b * y[i] + tx, qy = b * x[i] + a * y[i] + ty;
                double d = Math.Sqrt((qx - X[i]) * (qx - X[i]) + (qy - Y[i]) * (qy - Y[i]));
                sum += d; if (d > max) max = d;
            }
            mean = sum / n;
        }

        // the reference geometry irdash holds for a track (dash\maps\<key>.json): pts are x east / y north metres
        static double[] ReadRef(string mapPath, out double[] ry, out int n, out string source)
        {
            ry = null; n = 0; source = "";
            string text = File.ReadAllText(mapPath, Encoding.UTF8);
            Match sm = Regex.Match(text, "\"source\"\\s*:\\s*\"([^\"]*)\"");
            if (sm.Success) source = sm.Groups[1].Value;
            Match pm = Regex.Match(text, "\"pts\"\\s*:\\s*\\[(.*?)\\]\\s*,\\s*\"pit\"", RegexOptions.Singleline);
            if (!pm.Success) pm = Regex.Match(text, "\"pts\"\\s*:\\s*\\[(.*?)\\]\\s*\\}", RegexOptions.Singleline);
            if (!pm.Success) return null;
            MatchCollection pair = Regex.Matches(pm.Groups[1].Value, "\\[(-?[0-9.]+),(-?[0-9.]+)\\]");
            if (pair.Count < 200) return null;
            n = pair.Count;
            double[] rx = new double[n]; ry = new double[n];
            for (int i = 0; i < n; i++)
            {
                rx[i] = double.Parse(pair[i].Groups[1].Value, NumberStyles.Float, GInv);
                ry[i] = double.Parse(pair[i].Groups[2].Value, NumberStyles.Float, GInv);
            }
            return rx;
        }

        // where Lovely has corner names: the worst distance from a named turn's apex to the measured line
        static void ApexErrors(GpsLap lap, int refN, double[] rx, double[] ry, double[] fx, double[] fy, GpsFit fit)
        {
            LovelyEntry le = Corners.FindLovely(lap.Track, lap.Config);
            if (le == null) le = Corners.FindLovely(lap.TrackName, lap.Config);
            if (le == null) return;
            string root = Corners.DataRoot ?? Program.RootDir;
            string file = Path.Combine(root, @"data\corners\lovely", le.File);
            if (!File.Exists(file)) return;
            CornerSet cs = Corners.ParseLovely(File.ReadAllText(file, Encoding.UTF8));
            if (cs == null || cs.Turns.Count == 0) return;
            fit.ApexCount = cs.Turns.Count;
            double worst = 0;
            foreach (CornerTurn tr in cs.Turns)
            {
                int idx = ((int)Math.Round(tr.Pa * refN) % refN + refN) % refN;
                double ax = rx[idx], ay = ry[idx];
                double best = double.MaxValue;
                for (int i = 0; i < refN; i++)
                {
                    double dx = fx[i] - ax, dy = fy[i] - ay, d = dx * dx + dy * dy;
                    if (d < best) best = d;
                }
                best = Math.Sqrt(best);
                if (best > worst) worst = best;
            }
            fit.ApexMaxErr = worst;
        }

        // Build the fitted GPS map for one track key from its telemetry files (already picked out of a folder).
        static GpsFit BuildGps(string key, List<FileInfo> mine, string mapPath, out string why)
        {
            why = "";
            List<FileInfo> files = new List<FileInfo>();
            foreach (FileInfo fi in mine)
            {
                if (fi.LastWriteTime > DateTime.Now.AddMinutes(-2)) continue;      // never a file still being written
                files.Add(fi);
            }
            if (files.Count == 0) { why = "no telemetry for this track"; return null; }
            files.Sort(delegate (FileInfo p, FileInfo q) { return q.LastWriteTime.CompareTo(p.LastWriteTime); });

            GpsLap g = null; string lastWhy = "";
            int read = 0; long budget = 150L << 20;                                // at most 150 MB of files read for one track
            foreach (FileInfo fi in files)
            {
                if (read >= 4 || budget <= 0) break;
                if (Program.IsDriving || Sdk.Latest.Connected) { why = "session active; telemetry read stopped"; return null; }
                read++; budget -= fi.Length;
                try { g = ReadLap(fi.FullName, out lastWhy); } catch (Exception ex) { lastWhy = ex.Message; g = null; }
                if (g != null) break;
            }
            if (g == null) { why = lastWhy.Length > 0 ? lastWhy : "no clean lap"; return null; }

            GpsFit fit = new GpsFit();
            fit.File = g.File; fit.Key = key; fit.Track = g.Track; fit.Config = g.Config; fit.Lap = g.Lap; fit.LapTime = g.Time;

            double[] rx = null, ry = null; int refN = 0; string refSource = "";
            if (mapPath != null && File.Exists(mapPath))
            {
                try { rx = ReadRef(mapPath, out ry, out refN, out refSource); } catch { rx = null; }
            }
            if (rx == null || refN < 200)
            {
                // no geometry to fit to: the measured line is the map, un-fitted
                fit.RefSource = ""; fit.N = g.N; fit.Pct = g.Pct; fit.X = g.X; fit.Y = g.Y; fit.Alt = g.Alt;
                why = "the measured line (no track geometry to fit to)";
                return fit;
            }

            fit.RefSource = refSource; fit.N = refN;
            double[] gp = new double[refN], gx = new double[refN], gy = new double[refN], ga = new double[refN];
            ResampleGps(g, refN, gp, gx, gy, ga);
            double a, b, tx, ty, mean, max;
            Similarity(gx, gy, rx, ry, refN, out a, out b, out tx, out ty, out mean, out max);
            fit.Scale = Math.Sqrt(a * a + b * b); fit.RotationDeg = Math.Atan2(b, a) * 180.0 / Math.PI;
            fit.MeanErr = mean; fit.MaxErr = max;
            fit.Pct = gp; fit.X = new double[refN]; fit.Y = new double[refN]; fit.Alt = ga;
            for (int i = 0; i < refN; i++) { fit.X[i] = a * gx[i] - b * gy[i] + tx; fit.Y[i] = b * gx[i] + a * gy[i] + ty; }
            try { ApexErrors(g, refN, rx, ry, fit.X, fit.Y, fit); } catch { }
            why = "fitted to " + (refSource.Length > 0 ? refSource : "the outline") + " (mean " + mean.ToString("0.0", GInv) + " m, max " + max.ToString("0.0", GInv) + " m)";
            return fit;
        }

        static string InnerJson(GpsFit f)
        {
            StringBuilder sb = new StringBuilder(32000);
            sb.Append("{\"source\":\"telemetry\",\"file\":").Append(Json_.S(f.File))
              .Append(",\"lap\":").Append(f.Lap).Append(",\"lapTime\":").Append(f.LapTime.ToString("0.000", GInv))
              .Append(",\"track\":").Append(Json_.S(f.Track)).Append(",\"config\":").Append(Json_.S(f.Config))
              .Append(",\"refSource\":").Append(Json_.S(f.RefSource))
              .Append(",\"scale\":").Append(f.Scale.ToString("0.0000", GInv))
              .Append(",\"rotationDeg\":").Append(f.RotationDeg.ToString("0.000", GInv))
              .Append(",\"meanErrorM\":").Append(f.MeanErr.ToString("0.0", GInv))
              .Append(",\"maxErrorM\":").Append(f.MaxErr.ToString("0.0", GInv))
              .Append(",\"apexCount\":").Append(f.ApexCount)
              .Append(",\"apexMaxErrorM\":").Append(f.ApexCount > 0 ? f.ApexMaxErr.ToString("0.0", GInv) : "null")
              .Append(",\"n\":").Append(f.N).Append(",\"pts\":[");
            for (int i = 0; i < f.N; i++) { if (i > 0) sb.Append(','); sb.Append('[').Append(f.X[i].ToString("0.0", GInv)).Append(',').Append(f.Y[i].ToString("0.0", GInv)).Append(']'); }
            sb.Append("],\"alt\":[");
            for (int i = 0; i < f.N; i++) { if (i > 0) sb.Append(','); sb.Append(f.Alt[i].ToString("0.0", GInv)); }
            sb.Append("]}");
            return sb.ToString();
        }

        // ---- what the server calls ----
        static void SaveGps(GpsFit fit, string mapsDir)
        {
            Directory.CreateDirectory(mapsDir);
            string file = Path.Combine(mapsDir, fit.Key + ".gps.json");
            File.WriteAllText(file + ".tmp", InnerJson(fit), new UTF8Encoding(false));
            if (File.Exists(file)) File.Delete(file);
            File.Move(file + ".tmp", file);
        }

        // Group a folder's .ibt files by track key (header reads only).
        static Dictionary<string, List<FileInfo>> GroupByKey(string dir)
        {
            Dictionary<string, List<FileInfo>> by = new Dictionary<string, List<FileInfo>>();
            if (dir == null || !Directory.Exists(dir)) return by;
            foreach (string f in Directory.GetFiles(dir, "*.ibt"))
            {
                string k = KeyOf(f);
                if (k == null || k.Length == 0) continue;
                List<FileInfo> l;
                if (!by.TryGetValue(k, out l)) { l = new List<FileInfo>(); by[k] = l; }
                l.Add(new FileInfo(f));
            }
            return by;
        }

        // The sidecar for /trackmap, or null when there is none yet.
        public static string GpsFragmentFor(string key, string mapsDir)
        {
            try
            {
                if (mapsDir == null) return null;
                string file = Path.Combine(mapsDir, key + ".gps.json");
                if (!File.Exists(file)) return null;
                string s = File.ReadAllText(file, Encoding.UTF8).Trim();
                return s.Length > 2 && s[0] == '{' && s[s.Length - 1] == '}' ? s : null;
            }
            catch { return null; }
        }

        // With no established geometry, the measured line itself is served as the map (only when a sidecar exists).
        public static string GpsOnlyMap(string key, string mapsDir)
        {
            string gps = GpsFragmentFor(key, mapsDir);
            if (gps == null) return null;
            Match pm = Regex.Match(gps, "\"pts\"\\s*:\\s*(\\[.*?\\])\\s*,\\s*\"alt\"", RegexOptions.Singleline);
            if (!pm.Success) return null;
            StringBuilder sb = new StringBuilder(32000);
            sb.Append("{\"v\":2,\"source\":\"gps\",\"key\":").Append(Json_.S(key))
              .Append(",\"track\":").Append(Json_.S(key)).Append(",\"n\":720,\"recorded\":\"").Append(DateTime.Now.ToString("s", GInv))
              .Append("\",\"pts\":").Append(pm.Groups[1].Value).Append(",\"pit\":[],\"gps\":").Append(gps).Append('}');
            return sb.ToString();
        }

        // Background: build the sidecar for every track found in the telemetry folder, once, never while a session runs.
        public static void BuildAllGps(string telemetryDir, string mapsDir)
        {
            if (telemetryDir == null || !Directory.Exists(telemetryDir) || mapsDir == null) return;
            for (int i = 0; i < 60 && (Program.IsDriving || Sdk.Latest.Connected); i++) System.Threading.Thread.Sleep(20000);
            if (Program.IsDriving || Sdk.Latest.Connected) return;
            Dictionary<string, List<FileInfo>> by = GroupByKey(telemetryDir);
            foreach (KeyValuePair<string, List<FileInfo>> kv in by)
            {
                if (File.Exists(Path.Combine(mapsDir, kv.Key + ".gps.json"))) continue;      // built once
                if (Program.IsDriving || Sdk.Latest.Connected) return;                       // a session started again: stop
                try { string why; GpsFit fit = BuildGps(kv.Key, kv.Value, Path.Combine(mapsDir, kv.Key + ".json"), out why); if (fit != null) SaveGps(fit, mapsDir); Log.W("gpsmap: " + kv.Key + " - " + why); }
                catch (Exception ex) { Log.W("gpsmap: " + kv.Key + " failed: " + ex.Message); }
            }
        }

        // ---- one-shot for tests\gpsmap-test.ps1: --analysis --gpsmap --root <deck> --dir <folder of .ibt> --out <folder> ----
        static int GpsMapCli(string[] args)
        {
            string root = Arg(args, "--root"), dir = Arg(args, "--dir"), outDir = Arg(args, "--out");
            if (root.Length == 0 || dir.Length == 0 || outDir.Length == 0) return 2;
            Corners.DataRoot = root;
            Directory.CreateDirectory(outDir);
            string mapsDir = Path.Combine(root, @"dash\maps");
            Dictionary<string, List<FileInfo>> by = GroupByKey(dir);
            List<string> keys = new List<string>(by.Keys);
            keys.Sort(StringComparer.Ordinal);
            StringBuilder sum = new StringBuilder(4000);
            StringBuilder skip = new StringBuilder(4000);
            sum.Append("{\"root\":").Append(Json_.S(root)).Append(",\"dir\":").Append(Json_.S(dir)).Append(",\"fixtures\":[");
            bool first = true, firstSkip = true; int built = 0;
            foreach (string key in keys)
            {
                string why;
                GpsFit fit = null;
                try { fit = BuildGps(key, by[key], Path.Combine(mapsDir, key + ".json"), out why); } catch (Exception ex) { why = ex.Message; }
                if (fit == null)
                {
                    Log.W("gpsmap: " + key + " - " + why);
                    if (!firstSkip) skip.Append(','); firstSkip = false;
                    skip.Append("{\"key\":").Append(Json_.S(key)).Append(",\"why\":").Append(Json_.S(why)).Append('}');
                    continue;
                }
                File.WriteAllText(Path.Combine(outDir, key + ".json"), InnerJson(fit), new UTF8Encoding(false));
                if (!first) sum.Append(','); first = false; built++;
                sum.Append("{\"key\":").Append(Json_.S(key)).Append(",\"out\":").Append(Json_.S(key + ".json"))
                   .Append(",\"file\":").Append(Json_.S(fit.File)).Append(",\"lap\":").Append(fit.Lap)
                   .Append(",\"lapTime\":").Append(fit.LapTime.ToString("0.000", GInv))
                   .Append(",\"n\":").Append(fit.N).Append(",\"refSource\":").Append(Json_.S(fit.RefSource))
                   .Append(",\"meanErrorM\":").Append(fit.MeanErr.ToString("0.0", GInv))
                   .Append(",\"maxErrorM\":").Append(fit.MaxErr.ToString("0.0", GInv))
                   .Append(",\"apexCount\":").Append(fit.ApexCount)
                   .Append(",\"apexMaxErrorM\":").Append(fit.ApexCount > 0 ? fit.ApexMaxErr.ToString("0.0", GInv) : "null")
                   .Append(",\"altCount\":").Append(fit.Alt != null ? fit.Alt.Length : 0).Append('}');
            }
            sum.Append("],\"skipped\":[").Append(skip).Append("],\"fixtureCount\":").Append(built).Append('}');
            File.WriteAllText(Path.Combine(outDir, "summary.json"), sum.ToString(), new UTF8Encoding(false));
            return built > 0 ? 0 : 1;
        }
    }
}
