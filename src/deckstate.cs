using System;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace IRDeck
{
    // One input frame keeps the deck and dashboard on the same fail-closed table.
    public sealed class Snapshot
    {
        public bool Sim, Ui, Fresh, Connected, SessionKnown, OnTrack, Replay, TestOrAi;
        public double Speed;
    }

    public sealed class DeckState
    {
        public string Primary, Label, Reason, Action;
        public DeckState(string primary, string label, string reason, string action)
        { Primary = primary; Label = label; Reason = reason; Action = action; }
    }

    public static class DeckStateResolver
    {
        // Tick counters are signed in the SDK header but advance as unsigned values.
        public static bool TelemetryAdvanced(int first, int second)
        {
            if (first == -1 || second == -1) return false;
            uint delta = unchecked((uint)second - (uint)first);
            return delta > 0 && delta < 0x80000000u;
        }

        public static DeckState Resolve(Snapshot s)
        {
            if (s == null) return Wait();
            if (!s.Sim) return s.Ui ? new DeckState("HOME", "HOME", "", "home") : new DeckState("RIGON", "RIG ON", "", "rigon");
            if (!s.Fresh || !s.Connected || !s.SessionKnown) return Wait();
            if (s.Replay) return Wait();
            if (!s.OnTrack)
            {
                if (s.TestOrAi) return new DeckState("SKIP", "SKIP", "", "confirm skip skip");
                return new DeckState("GETIN", "GET IN", "", "drive-only");
            }
            if (s.Speed >= 1.0) return new DeckState("DRIVE", "DRIVE", "", "");
            return new DeckState("RESET", "RESET", "", "tow");
        }

        static DeckState Wait() { return new DeckState("WAIT", "WAIT", "", ""); }
    }
}
