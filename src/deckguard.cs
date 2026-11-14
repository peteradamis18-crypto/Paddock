// The repeat guard for every deck press (W0-1). Pure rules, no files, no clock: compiled into irdeck (keys\*.exe) and irdash
// (/api/do), and on its own by tests\deckguard-test.ps1. C# 5.
// Why: the Stream Deck delivers one press two or three times, 29 ms to 1.06 s apart. The old guard dropped a repeat only
// within 0.12 s, so a key that finished fast ran twice (26 double runs 20 Oct - 12 Nov), and `key` / `media` had no guard
// at all, so a doubled GHOST or RELATIVE press opened and closed the box. Now: 0.7 s for every key, 1.5 s for on/off keys,
// and only the keys Peter taps quickly on purpose (volume, spotter level, seat) keep the short bounce floor.
using System;
using System.Collections.Generic;

namespace IRDeck
{
    public static class DeckGuard
    {
        public const int RepeatMs = 700;    // a second start of the same key inside this is the same press
        public const int ToggleMs = 1500;   // on/off keys: a repeat 1 s later flipped MUTE SPOTTER back (2026-10-24)
        public const int BounceMs = 120;    // keys tapped quickly on purpose: only a bounce (< 0.1 s) is dropped

        // Keys Peter presses several times in a row on purpose, by key name (keys.map). Nothing else is exempt.
        static readonly string[] FastKeys = { "vol-up", "vol-down", "spot-up", "spot-down", "seat-up", "seat-down" };

        public static bool IsFastKey(string keyName)
        {
            if (string.IsNullOrEmpty(keyName)) return false;
            return Array.IndexOf(FastKeys, keyName.Trim().ToLowerInvariant()) >= 0;
        }

        // on/off keys: SPOTTER (spotter-tap) and the old MUTE SPOTTER, the pit toggles, AC on/off
        public static bool IsToggle(string[] a)
        {
            if (a == null || a.Length == 0 || a[0] == null) return false;
            string v = a[0].ToLowerInvariant();
            string w = a.Length > 1 && a[1] != null ? a[1].ToLowerInvariant() : "";
            return (v == "appvol" && w == "mute") || v == "spotter-tap" || v == "pittoggle" || (v == "ac" && w == "toggle");
        }

        public static int GapMs(string keyName, string[] a)
        {
            if (IsFastKey(keyName)) return BounceMs;
            return IsToggle(a) ? ToggleMs : RepeatMs;
        }

        // Fast keys do not wait for the previous run (a volume step is quick, and a second tap while it runs is meant).
        public static bool UsesMutex(string keyName) { return !IsFastKey(keyName); }

        // Does this start of a key run? lastTicks = the key's last start (0 = never), mutexFree = no copy of this key is still running.
        public static bool KeyRuns(string keyName, string[] a, long lastTicks, long nowTicks, bool mutexFree)
        {
            if (UsesMutex(keyName) && !mutexFree) return false;
            if (lastTicks <= 0 || nowTicks < lastTicks) return true;   // never ran, or the clock went back: run
            return nowTicks - lastTicks >= TimeSpan.FromMilliseconds(GapMs(keyName, a)).Ticks;
        }

        // ---------- irdash /api/do: one guard by command + argument ----------
        // Commands that are steps or screen housekeeping, sent several times in a row on purpose (a level, a page, the replay
        // timeline, the search draft). Everything else - every command that ends in an irdeck run - gets the 0.7 s rule.
        static readonly string[] DoFree = {
            "mdopen", "mdclose", "mdclear", "mddraft", "mdspeedtest", "on", "off",
            "deltaup", "deltadown", "sndvol", "actemp", "acfan", "volup", "voldown", "seatup", "seatdown",
            "pagenext", "pageprev", "picknext", "pickprev", "pickpagenext", "pickpageprev"
        };

        public static bool DoExempt(string c, string a)
        {
            if (string.IsNullOrEmpty(c)) return true;
            string v = c.ToLowerInvariant();
            if (v.StartsWith("rp", StringComparison.Ordinal) || v.StartsWith("wb-", StringComparison.Ordinal)) return true;   // REPLAY and ANALYSIS steps: SDK messages / page state, never irdeck
            if (v == "key") return IsFastKey(a);   // the phone's deck keys: the same names as the key exes
            return Array.IndexOf(DoFree, v) >= 0;
        }

        public static string DoKey(string c, string a) { return (c ?? "").ToLowerInvariant() + "\t" + (a ?? ""); }

        // ---------- SHUT DOWN / SLEEP through irdash (review of W0-1, finding 1) ----------
        // The 5 s confirm must not live only in the add-on: one GET to /api/do?c=shutdown from any page in a browser on this PC
        // (an <img> needs no CORS) would turn the PC off. So the add-on's CONFIRM screen arms irdash when it opens
        // (c=confirmarm&a=shutdown|sleep), and irdash takes shutdown / sleep only with the X-Paddock: 1 header, from this PC, with
        // the kids lock off, and within ArmMs of an arm for the same thing. The arm is used up by the first YES.
        public const int ArmMs = 5500;   // the screen gives Peter 5 s from opening; half a second for the requests themselves

        public static bool IsPowerCommand(string c) { return c == "shutdown" || c == "sleep"; }

        public sealed class PowerGate
        {
            string what; long at;
            readonly object gate = new object();
            public bool Arm(string w, long nowTicks)
            {
                if (!IsPowerCommand(w)) return false;
                lock (gate) { what = w; at = nowTicks; }
                return true;
            }
            // "ok" (and the arm is gone), or why not: "no-header", "not-local", "kids", "not-armed"
            public string Check(string c, bool headerOk, bool local, bool kidsLocked, long nowTicks)
            {
                if (!local) return "not-local";
                if (!headerOk) return "no-header";
                if (kidsLocked) return "kids";
                lock (gate)
                {
                    bool fresh = what == c && nowTicks >= at && nowTicks - at <= TimeSpan.FromMilliseconds(ArmMs).Ticks;
                    if (!fresh) return "not-armed";
                    what = null; at = 0;
                    return "ok";
                }
            }
        }

        // One per irdash: remembers when each command + argument last ran. Thread-safe (irdash answers on many threads).
        public sealed class DoMemory
        {
            readonly Dictionary<string, long> last = new Dictionary<string, long>();
            readonly object gate = new object();
            public bool Allow(string c, string a, long nowTicks)
            {
                if (DoExempt(c, a)) return true;
                string k = DoKey(c, a);
                lock (gate)
                {
                    long t;
                    if (last.TryGetValue(k, out t) && nowTicks >= t && nowTicks - t < TimeSpan.FromMilliseconds(RepeatMs).Ticks) return false;
                    last[k] = nowTicks;
                    if (last.Count > 500) last.Clear();   // a long day of presses: forgetting old ones is harmless
                    return true;
                }
            }
        }
    }
}
