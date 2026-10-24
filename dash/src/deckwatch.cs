using System;

namespace IRDash
{
    // When the Stream Deck app must be restarted (the rules only; Watch in irdash.cs acts on them). 2026-10-24 18:32: the PC woke
    // from sleep, Windows reset the deck's USB connection, and the Stream Deck app kept the dead one: it said "Device connected"
    // at once, the keys did nothing, it only noticed 36 s later ("Read Keys: DISCONNECTED"), and the old check waited 25 s more.
    // 67 s of a dead deck. Now: a wake restarts the app as soon as the deck is back on USB, and a lost device is restarted at once.
    static class DeckWatch
    {
        public const double WakeGapSec = 15;       // Windows slept this long between two watchdog ticks (wall clock minus awake time)
        public const double LostRestartSec = 2;     // a "Device disconnected" that is still the last word after one more tick
        public const double NeverSawSec = 25;       // the app has run this long and never logged the deck as connected
        public const double CooldownSec = 30;       // never two restarts closer than this (a restart takes ~7 s)

        // wallSec: wall-clock time between two ticks; awakeSec: the same on Windows' "unbiased" clock, which stops while asleep.
        // Only a real sleep counts: irdash freezing for a while (both clocks run) must never restart the deck mid-race.
        public static bool IsWake(double wallSec, double awakeSec) { return wallSec - awakeSec > WakeGapSec; }

        // logTail: the end of the current StreamDeck.log (the app starts a new file each run). Returns "lost", "never" or "".
        public static string Action(string logTail, bool appRunning, double appAgeSec, bool devicePresent, double lostForSec, double sinceRestartSec)
        {
            if (!appRunning || !devicePresent || sinceRestartSec < CooldownSec || logTail == null) return "";
            int conn = logTail.LastIndexOf("Device connected, id:", StringComparison.Ordinal);
            int disc = logTail.LastIndexOf("Device disconnected, id:", StringComparison.Ordinal);
            if (disc > conn && lostForSec >= LostRestartSec) return "lost";
            if (conn < 0 && disc < 0 && appAgeSec >= NeverSawSec) return "never";
            return "";
        }

        // is the last thing the app said about the deck "connected" (after a restart: did it come back)
        public static bool Connected(string logTail)
        {
            if (logTail == null) return false;
            int conn = logTail.LastIndexOf("Device connected, id:", StringComparison.Ordinal);
            return conn >= 0 && conn > logTail.LastIndexOf("Device disconnected, id:", StringComparison.Ordinal);
        }
    }
}
