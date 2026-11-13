// iRacing's own settings, read in one place (W0-9; three [Graphics Options] parsers before: perf diff, the Performance checklist,
// Rig Doctor). Read-only: iRacing's files are never written (CLAUDE.md rule 2).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDash
{
    static class SimSettings
    {
        // the graphics file the sim uses for the monitor setup (Documents\iRacing\rendererDX11Monitor.ini)
        public static string GraphicsFile { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), @"iRacing\rendererDX11Monitor.ini"); } }

        // [Graphics Options] of one file (shared read: iRacing may be writing it)
        public static Dictionary<string, string> Graphics(string path)
        {
            string text;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader r = new StreamReader(fs, Encoding.GetEncoding(28591))) text = r.ReadToEnd();
            return ParseGraphics(text);
        }

        public static Dictionary<string, string> ParseGraphics(string text)
        {
            Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            bool inSec = false;
            foreach (string raw in (text ?? "").Split('\n'))
            {
                string l = raw.Trim();
                if (l.StartsWith("[", StringComparison.Ordinal)) { inSec = l == "[Graphics Options]"; continue; }
                if (!inSec) continue;
                Match m = Regex.Match(l, @"^(\w+)=([^;\s]*)");
                if (m.Success) d[m.Groups[1].Value] = m.Groups[2].Value;
            }
            return d;
        }

        // the frame limit the sim is set to (LimitFrameRate=1, DesiredFPSLimit=160); 0 = no limit or unknown
        public static double FpsCap(Dictionary<string, string> g)
        {
            string on, v; double cap;
            if (g == null || !g.TryGetValue("LimitFrameRate", out on) || on.Trim() != "1") return 0;
            if (!g.TryGetValue("DesiredFPSLimit", out v) || !double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out cap) || cap < 10 || cap > 1000) return 0;
            return cap;
        }

        // the limit now, read at most once a minute
        static double capNow = -1; static DateTime capAt = DateTime.MinValue;
        static readonly object gate = new object();
        public static double FpsCapNow()
        {
            lock (gate)
            {
                if (capNow >= 0 && (DateTime.Now - capAt).TotalSeconds < 60) return capNow;
                capAt = DateTime.Now;
                try { capNow = File.Exists(GraphicsFile) ? FpsCap(Graphics(GraphicsFile)) : 0; } catch { capNow = 0; }
                return capNow;
            }
        }
    }
}
