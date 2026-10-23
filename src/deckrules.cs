// Pure rules behind the one-press deck keys. No sim, no screen, no files: tests\deck-behaviour-test.ps1 compiles this
// file on its own and runs every rule, so what the keys decide is proven offline (C# 5).
using System;
using System.Globalization;

namespace IRDeck
{
    public static class DeckRules
    {
        public const int RaceHopsMax = 3;        // RACE NOW: at most this many session skips
        public const int StopWaitMs = 15000;     // GET OUT / RESTART: how long a moving car is waited for
        public const int ChatRepeatMs = 3000;    // the same chat line inside this window is the deck's doubled press
        public const int SecondNextMs = 10000;   // an AI Qualify that has not moved on after this gets one more Next

        // GET IN: what to do, from what can be seen. The key works the state out; it never asks.
        //   already       on track: nothing to press
        //   go            a session exists (session screen, replay behind it, garage): press the sim's green Drive button
        //   wait-load     the sim was started a moment ago and is still loading: wait for the session, then Drive
        //   open-then-start  the iRacing app is not open: open it (RIG ON), then start the last drive
        //   start         no session: start the last drive (Test Drive with the car and track of MY DRIVE)
        public static string GetInPlan(bool ui, bool simProcess, bool session, bool onTrack, bool startedRecently)
        {
            if (session) return onTrack ? "already" : "go";
            if (simProcess && startedRecently) return "wait-load";
            return ui ? "start" : "open-then-start";
        }

        // 0 = stopped or out of the car (go on), 1 = still moving (keep waiting), 2 = time is up.
        public static int StopWait(bool inCar, double speed, int elapsedMs, int limitMs)
        {
            if (!inCar || speed <= 1.0) return 0;
            return elapsedMs >= limitMs ? 2 : 1;
        }

        // Kids mode: the only deck keys that still work while the keyboard and mouse are locked. `a` is the key's command words
        // (from keys.map): GET IN, TOW TO PITS, RESTART (one press), the game volume pair, and the kids key itself.
        public static bool KidsAllows(string[] a)
        {
            if (a == null || a.Length == 0 || a[0] == null) return false;
            string v = a[0].ToLowerInvariant();
            if (v == "kids" || v == "smart" || v == "tow" || v == "restartrace") return true;
            if (v == "confirm") return a.Length >= 3 && a[1] == "restart-race" && a[2].ToLowerInvariant() == "restartrace";
            if (v == "appvol") return a.Length >= 3 && a[1].ToLowerInvariant() == "game" && (a[2] == "-10" || a[2] == "+10");
            return false;
        }

        // The low-level hooks let input that irdeck itself injected through (SendInput / keybd_event / mouse_event set these flags),
        // so GET IN, RESTART and chat still reach the sim while a child's own keyboard and mouse are blocked.
        public const uint KbdInjected = 0x10;    // LLKHF_INJECTED
        public const uint MouseInjected = 0x01;  // LLMHF_INJECTED
        public static bool HookPasses(uint flags, bool mouse, bool blockInjectedForTest)
        {
            if (blockInjectedForTest) return false;
            return (flags & (mouse ? MouseInjected : KbdInjected)) != 0;
        }

        // Chat: the deck sends one press 2-3 times (THANKS went out twice, 0.96 s apart). The stamp is "ticks<TAB>text".
        public static string ChatNorm(string text) { return (text ?? "").Trim().ToLowerInvariant(); }
        public static string ChatStamp(string text, long nowTicks) { return nowTicks.ToString(CultureInfo.InvariantCulture) + "\t" + ChatNorm(text); }
        public static bool ChatIsRepeat(string stamp, string text, long nowTicks, int windowMs)
        {
            if (string.IsNullOrEmpty(stamp)) return false;
            int tab = stamp.IndexOf('\t');
            if (tab <= 0) return false;
            long then;
            if (!long.TryParse(stamp.Substring(0, tab), NumberStyles.Integer, CultureInfo.InvariantCulture, out then)) return false;
            long age = nowTicks - then;
            if (age < 0 || age >= TimeSpan.FromMilliseconds(windowMs).Ticks) return false;
            return stamp.Substring(tab + 1).TrimEnd('\r', '\n') == ChatNorm(text);
        }

        // NEXT SESSION in an AI Qualify: iRacing sometimes ignores the first Next. One more click when nothing moved after 10 s.
        public static bool IsQualify(string sessionType)
        {
            return (sessionType ?? "").IndexOf("qualif", StringComparison.OrdinalIgnoreCase) >= 0;
        }
        public static bool SecondNextDue(bool qualify, int clicks, int msSinceClick, bool advanced)
        {
            return qualify && clicks == 1 && !advanced && msSinceClick >= SecondNextMs;
        }

        // RACE NOW: keep skipping until the session is the race.
        public static bool IsRaceType(string sessionType)
        {
            return string.Equals((sessionType ?? "").Trim(), "Race", StringComparison.OrdinalIgnoreCase);
        }
    }
}
