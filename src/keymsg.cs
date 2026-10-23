using System;
using System.Net;
using System.Text.RegularExpressions;

namespace IRDeck
{
    // Deck v2: every Stream Deck press says what happened on the top screen for 4 s (irdash /api/keymsg, dash\src\keymsg.cs,
    // shown by dash\www\v2\keymsg.js). Before this, a refused or waiting key only beeped and Peter could not tell why.
    // The words come from the last thing the command logged, put into plain language below; a key that logs nothing new
    // falls back to its result code. Fire and forget: it never throws and never holds a key up.
    static partial class Program
    {
        static string KeyId = "";          // the deck key's exe name ("get-out"); empty for irdeck-cli and tests = silent
        static bool KeyMsgSent;            // something was already said for this press (a waiting message, or kids mode)
        static string LastLog = "";        // the last result line this press logged
        static IAsyncResult sayPending; static DateTime sayAt;

        static void Say(string kind, string text)
        {
            try
            {
                if (KeyId.Length == 0 || string.IsNullOrEmpty(text)) return;
                KeyMsgSent = true;
                HttpWebRequest rq = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:8199/api/keymsg?key=" + Uri.EscapeDataString(KeyId) +
                    "&kind=" + kind + "&text=" + Uri.EscapeDataString(text));
                rq.Timeout = 800; rq.ReadWriteTimeout = 800; rq.Proxy = null; rq.KeepAlive = false;   // no proxy lookup: it adds seconds
                sayAt = DateTime.UtcNow;
                sayPending = rq.BeginGetResponse(delegate (IAsyncResult ar) { try { ((HttpWebRequest)ar.AsyncState).EndGetResponse(ar).Close(); } catch { } }, rq);
            }
            catch { }
        }

        // Lets the last request reach irdash (800 ms at most since it started), then the exe may exit. 127.0.0.1, never "localhost":
        // from a fresh process "localhost" tries IPv6 first and took 2.1 s (live 2026-10-23: every message but the first was lost).
        static void SayFlush()
        {
            try { if (sayPending != null) { int ms = 800 - (int)(DateTime.UtcNow - sayAt).TotalMilliseconds; if (ms > 0) sayPending.AsyncWaitHandle.WaitOne(ms); } } catch { }
        }

        // log wording -> {kind, plain words}. First match wins; $1 copies a captured part.
        static readonly string[][] SayTable = new string[][] {
            new[] { @"already in the car", "ok", "Already in the car" },
            new[] { @"restart: test drive - back in the car", "ok", "Back in the pits, in the car" },
            new[] { @"restart: back in the car", "ok", "Race restarted" },
            new[] { @"tow: back in the car", "ok", "Car reset to the pits" },
            new[] { @"go: in the car|smart: in the car|START -> in the car|back in the car in the pits", "ok", "In the car" },
            new[] { @"getout: held Esc", "ok", "Out of the car" },
            new[] { @"you are not in the car", "ok", "Already out of the car" },
            new[] { @"refused: the car is moving", "no", "Stop the car first" },
            new[] { @"did not stop|never stopped|still moving", "no", "The car did not stop" },
            new[] { @"skip: now in session \d+ \((.+)\)", "ok", "Next session: $1" },
            new[] { @"racenow: only an AI race", "no", "Only AI races can jump to the race" },
            new[] { @"racenow: (in the race, in the car|already in the race|the race session is up)", "ok", "Race starting" },
            new[] { @"racenow: still in", "no", "Could not reach the race" },
            new[] { @"Test Drive has no next session", "ok", "Test drive ended" },
            new[] { @"official sessions cannot be skipped", "no", "Official races cannot be skipped" },
            new[] { @"the session did not advance", "no", "The session did not skip" },
            new[] { @"the session started over", "ok", "Race restarted" },
            new[] { @"only AI races can be restarted", "no", "Only AI races restart" },
            new[] { @"quitmain: back on the main screen|the sim has left the session", "ok", "Back at the menu" },
            new[] { @"no sim session running|no session is running|no session running", "no", "No race running" },
            new[] { @"chat say sent", "ok", "Sent" },
            new[] { @"chat say: .*repeat", "ok", "Sent" },
            new[] { @"pit clear sent", "ok", "Pit stop cleared" },
            new[] { @"pit: (.+)", "ok", "Pit: $1" },
            new[] { @"only takes pit commands while you are in the car", "wait", "Get in the car first" },
            new[] { @"appvol game: (\d+)%", "ok", "Game volume $1 %" },
            new[] { @"appvol mute: \S+ muted", "ok", "Spotter muted" },
            new[] { @"appvol mute: \S+ sound back on", "ok", "Spotter on" },
            new[] { @"not making sound right now|no audio from", "no", "No game sound right now" },
            new[] { @"kids: press HOME", "wait", "Press HOME within 4 seconds to unlock" },
            new[] { @"kids: locked|kids hook: keyboard and mouse locked", "ok", "Kids mode on" },
            new[] { @"kids: unlocked", "ok", "Kids mode off" },
            new[] { @"power \w+: cancelled", "no", "Stopped: iRacing did not quit" },
            new[] { @"^power off$", "ok", "PC turning off in 5 seconds" },
            new[] { @"^power sleep$", "ok", "PC going to sleep" },
            new[] { @"mydrive: START|starting your last drive", "wait", "Starting your last drive" },
            new[] { @"choose a car and track first", "no", "Choose a car and track first" },
            new[] { @"The Test Drive window isn't open|iRacing UI is not running|press RIG ON", "no", "iRacing is not open" },
            new[] { @"is not in the list|has no ", "no", "iRacing could not find that car" },
            new[] { @"pressed \[\w+\] (.+)", "ok", "Opened $1" },
            new[] { @"not found: (.+?) \(", "no", "Could not find $1" },
        };

        static void SayResult(int rc)
        {
            if (KeyId.Length == 0) return;
            string line = LastLog ?? "";
            foreach (string[] r in SayTable)
            {
                Match m = Regex.Match(line, r[0], RegexOptions.IgnoreCase);
                if (!m.Success) continue;
                string text = r[2];
                for (int g = 1; g < m.Groups.Count; g++) text = text.Replace("$" + g, m.Groups[g].Value.Trim());
                if (text.Length > 70) text = text.Substring(0, 70);
                Say(r[1], text);
                return;
            }
            if (KeyMsgSent) return;     // a waiting message already said it
            Say(rc == 0 ? "ok" : rc == 3 ? "wait" : "no", rc == 0 ? "Done" : rc == 3 ? "Not right now" : rc == 2 ? "iRacing is not open" : "That did not work");
        }
    }
}
