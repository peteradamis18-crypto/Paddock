// `irdeck state`: the one line every safety rule reads (CLAUDE.md rule 1, build-irdeck.ps1, deck-intro\install.ps1, tests).
// Pure rules only, so tests\deckstate-line-test.ps1 compiles this file on its own (C# 5). Also compiled into irdash.
// The line keeps every field it printed before (scripts match 'sim=True', 'telemetry=on', 'onTrack=True') and adds
// fresh= (the SDK tick moved within 0.9 s), replay= and event=. telemetry=on needs the sim process: after a crash the
// memory map can stay "connected" while CrewChief, irdash or irdashies still hold it (audit 11, top finding 5).
using System;
using System.Globalization;
using System.Text.RegularExpressions;

namespace IRDeck
{
    public static class RigState
    {
        // Tick counters are signed in the SDK header but advance as unsigned values.
        public static bool TelemetryAdvanced(int first, int second)
        {
            if (first == -1 || second == -1) return false;
            uint delta = unchecked((uint)second - (uint)first);
            return delta > 0 && delta < 0x80000000u;
        }

        // a map left behind by a crashed sim is not a session
        public static bool TelemetryOn(bool simProcess, bool mapConnected) { return simProcess && mapConnected; }

        // Test / AI / Race / Practice / Qualify / none. eventType = the YAML's EventType, ai = an AI car is in the field,
        // sessionType = the current session's SessionType.
        public static string EventKind(bool telemetryOn, string eventType, bool ai, string sessionType)
        {
            if (!telemetryOn) return "none";
            string e = (eventType ?? "").Trim(), s = (sessionType ?? "").Trim();
            if (e.Equals("Test", StringComparison.OrdinalIgnoreCase)) return "Test";
            if (ai || e.Equals("AI", StringComparison.OrdinalIgnoreCase)) return "AI";
            if (Regex.IsMatch(s, "qualif", RegexOptions.IgnoreCase)) return "Qualify";
            if (Regex.IsMatch(s, "race", RegexOptions.IgnoreCase)) return "Race";
            if (Regex.IsMatch(s, "practice|warm", RegexOptions.IgnoreCase)) return "Practice";
            return "none";
        }

        public sealed class Facts
        {
            public bool Sim, Ui, MapConnected, OnTrack, OnPitRoad, Metric, Fresh, Replay;
            public double FuelLevel, PitSvFuel;
            public int PitSvFlags;
            public string Foreground = "", EventType = "", SessionType = "";
            public bool Ai;
        }

        public static string Line(Facts f)
        {
            bool tele = TelemetryOn(f.Sim, f.MapConnected);
            string tail = string.Format(CultureInfo.InvariantCulture, " fresh={0} replay={1} event={2}",
                tele && f.Fresh, tele && f.Replay, EventKind(tele, f.EventType, f.Ai, f.SessionType));
            if (!tele) return "state: sim=" + f.Sim + " ui=" + f.Ui + " telemetry=off" + (f.MapConnected ? " map=left-over" : "") + tail;
            return string.Format(CultureInfo.InvariantCulture,
                "state: sim={0} ui={1} telemetry=on onTrack={2} onPitRoad={3} units={4} fuelLevel={5:0.0}L pitSvFuel={6:0.0}L pitSvFlags={7} foreground={8}",
                f.Sim, f.Ui, f.OnTrack, f.OnPitRoad, f.Metric ? "metric" : "imperial", f.FuelLevel, f.PitSvFuel, f.PitSvFlags, f.Foreground) + tail;
        }
    }
}
