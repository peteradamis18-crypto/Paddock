// AI LEVEL deck screen, irdash side: how hard the AI is for the next AI RACE. iRacing's AI Opponents step has two ways to set it
// (iracing.com/ai-racing): ADAPTIVE AI, where the AI follows your pace and you pick Low, Medium or High challenge, and FIXED SKILL RANGE,
// where you give a minimum and maximum skill and every opponent is spread inside it.
// This file keeps the choice in <root>\ai\level.json ({"mode":"adaptive|range","level":"low|medium|high","min":N,"max":N}); irdeck reads that file
// when AI RACE gets to the AI Opponents step (src\testdrive.cs AiApplyLevel). The screen itself is drawn by the add-on from the key list
// /ailevel gives (the add-on only paints regions and sends presses back), so changing this screen never needs another add-on install.
// Owned by the deck workstream; irdash.cs only calls Handles / Do / Json.
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
    static class AiLevel
    {
        public static bool Handles(string c) { return c == "ailevel"; }

        // the skill scale of the Fixed Skill Range (set from what iRacing's own control shows: docs\research\ai-opponents-dump-*.txt)
        public const int RangeLo = 20, RangeHi = 120, RangeStep = 5, RangeMinGap = 5;
        const int DefMin = 60, DefMax = 85;

        static readonly object gate = new object();
        static string Path_() { return Path.Combine(Program.RootDir, @"ai\level.json"); }

        sealed class St { public string Mode = "adaptive", Level = "medium"; public int Min = DefMin, Max = DefMax; }

        static St Load()
        {
            St s = new St();
            try
            {
                string f = Path_();
                if (!File.Exists(f)) return s;
                string t = File.ReadAllText(f);
                Match m;
                m = Regex.Match(t, "\"mode\"\\s*:\\s*\"(adaptive|range)\""); if (m.Success) s.Mode = m.Groups[1].Value;
                m = Regex.Match(t, "\"level\"\\s*:\\s*\"(low|medium|high)\""); if (m.Success) s.Level = m.Groups[1].Value;
                m = Regex.Match(t, "\"min\"\\s*:\\s*(\\d{1,3})"); if (m.Success) s.Min = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                m = Regex.Match(t, "\"max\"\\s*:\\s*(\\d{1,3})"); if (m.Success) s.Max = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                Clamp(s);
            }
            catch (Exception ex) { Log.W("ailevel: " + ex.Message); }
            return s;
        }

        static void Clamp(St s)
        {
            s.Min = Math.Max(RangeLo, Math.Min(RangeHi - RangeMinGap, s.Min));
            s.Max = Math.Max(s.Min + RangeMinGap, Math.Min(RangeHi, s.Max));
        }

        static void Save(St s)
        {
            string f = Path_();
            Directory.CreateDirectory(Path.GetDirectoryName(f));
            string body = "{\"mode\":\"" + s.Mode + "\",\"level\":\"" + s.Level + "\",\"min\":" + s.Min + ",\"max\":" + s.Max + "}";
            File.WriteAllText(f + ".tmp", body, new UTF8Encoding(false));
            if (File.Exists(f)) File.Delete(f);
            File.Move(f + ".tmp", f);
        }

        // A press on the screen. a: low | medium | high | range | min- | min+ | max- | max+ | start
        public static bool Do(string c, string a)
        {
            a = (a ?? "").Trim().ToLowerInvariant();
            if (a == "start") return Start();
            lock (gate)
            {
                St s = Load();
                switch (a)
                {
                    case "low": case "medium": case "high": s.Mode = "adaptive"; s.Level = a; break;
                    case "adaptive": s.Mode = "adaptive"; break;
                    case "range": s.Mode = "range"; break;
                    case "min-": s.Mode = "range"; s.Min -= RangeStep; break;
                    case "min+": s.Mode = "range"; s.Min += RangeStep; if (s.Max < s.Min + RangeMinGap) s.Max = s.Min + RangeMinGap; break;
                    case "max-": s.Mode = "range"; s.Max -= RangeStep; if (s.Min > s.Max - RangeMinGap) s.Min = s.Max - RangeMinGap; break;
                    case "max+": s.Mode = "range"; s.Max += RangeStep; break;
                    default: return false;
                }
                Clamp(s);
                try { Save(s); } catch (Exception ex) { Log.W("ailevel: could not save: " + ex.Message); return false; }
                KeyMsg.Set("ailevel", "Next AI race: " + Summary(s), "ok");
                return true;
            }
        }

        static string Summary(St s)
        {
            return s.Mode == "range" ? "skill range " + s.Min + " to " + s.Max : "adaptive AI, " + s.Level + " challenge";
        }

        // AI RACE from the deck screen: the same command as the AI RACE key
        static bool Start()
        {
            if (Watch.IrdeckPath == null || !File.Exists(Watch.IrdeckPath)) { Log.W("ailevel: irdeck.exe not found"); return false; }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(Watch.IrdeckPath, "airace start");
                psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(Watch.IrdeckPath);
                Process.Start(psi);
                return true;
            }
            catch (Exception ex) { Log.W("ailevel: " + ex.Message); return false; }
        }

        // ---------- the key list the add-on paints ----------
        static void Reg(StringBuilder b, int c, int r, int w, int h, string text, string sub, string act, string arg, string style, int wrap)
        {
            if (b.Length > 1) b.Append(',');
            b.Append("{\"c\":").Append(c).Append(",\"r\":").Append(r).Append(",\"w\":").Append(w).Append(",\"h\":").Append(h)
             .Append(",\"text\":").Append(Json_.S(text)).Append(",\"sub\":").Append(Json_.S(sub))
             .Append(",\"act\":").Append(act == null ? "null" : Json_.S(act)).Append(",\"arg\":").Append(arg == null ? "null" : Json_.S(arg))
             .Append(",\"style\":").Append(Json_.S(style)).Append(",\"wrap\":").Append(wrap).Append('}');
        }

        public static string Json()
        {
            St s; lock (gate) s = Load();
            bool ad = s.Mode == "adaptive", rg = !ad;
            StringBuilder b = new StringBuilder("[");
            // every label sits on ONE key: the deck's bezels between keys cut through text spread over two keys (found on the AC screen, 2026-10-23)
            Reg(b, 0, 0, 1, 1, "AI LEVEL", "next AI race", null, null, "banner", 2);
            Reg(b, 1, 0, 1, 1, ad ? "ADAPTIVE" : "RANGE", ad ? s.Level.ToUpperInvariant() : s.Min + " - " + s.Max, null, null, "gold", 2);
            Reg(b, 0, 1, 1, 1, "ADAPTIVE", "follows your pace", "ailevel", "adaptive", ad ? "sel" : "label", 2);
            Reg(b, 1, 1, 1, 1, "LOW", "easier", "ailevel", "low", ad && s.Level == "low" ? "sel" : "", 2);
            Reg(b, 2, 1, 1, 1, "MEDIUM", "", "ailevel", "medium", ad && s.Level == "medium" ? "sel" : "", 2);
            Reg(b, 3, 1, 1, 1, "HIGH", "harder", "ailevel", "high", ad && s.Level == "high" ? "sel" : "", 2);
            Reg(b, 0, 2, 1, 1, "RANGE", "you set the skill", "ailevel", "range", rg ? "sel" : "label", 2);
            Reg(b, 1, 2, 1, 1, "MIN", "lower", "ailevel", "min-", "", 2);
            Reg(b, 2, 2, 1, 1, s.Min.ToString(CultureInfo.InvariantCulture), "slowest AI", null, null, rg ? "on" : "off", 1);
            Reg(b, 3, 2, 1, 1, "MIN", "higher", "ailevel", "min+", "", 2);
            Reg(b, 4, 2, 1, 1, "MAX", "lower", "ailevel", "max-", "", 2);
            Reg(b, 5, 2, 1, 1, s.Max.ToString(CultureInfo.InvariantCulture), "fastest AI", null, null, rg ? "on" : "off", 1);
            Reg(b, 6, 2, 1, 1, "MAX", "higher", "ailevel", "max+", "", 2);
            Reg(b, 0, 3, 1, 1, "START", "AI RACE", "ailevel", "start", "go", 2);
            Reg(b, 7, 3, 1, 1, "EXIT", "AI LEVEL", "exit", null, "stop", 2);
            b.Append(']');
            return "{\"ready\":true,\"mode\":" + Json_.S(s.Mode) + ",\"level\":" + Json_.S(s.Level) + ",\"min\":" + s.Min + ",\"max\":" + s.Max + ",\"regions\":" + b + "}";
        }
    }
}
