// Sends the "iRacing GT3" Stream Deck profile back to its MAIN page (W0-1). Compiled into irdeck (SHUT DOWN / SLEEP) and
// irdash (the deck watchdog), and on its own by tests\deckprofile-test.ps1. C# 5.
// Why: Stream Deck saves the page it was last on as "Current" and opens there after a restart or a wake. On 12 Nov that was
// LEAVE, where SHUT DOWN PC used to be one press: the first stray press after a wake could turn the PC off.
// Only the Current page id in the profile manifest changes; every other byte stays as it was. Stream Deck rewrites the
// manifest while it runs, so the helper never writes while a StreamDeck.exe process exists.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDeck
{
    public static class DeckProfile
    {
        public const string ProfileId = "65E017A2-2219-43EE-A4E4-44D505F5B406";   // the profile build-deck.ps1 writes
        public const string StreamDeckExe = @"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe";

        // Swappable for tests (the real check would see Peter's running Stream Deck).
        public static Func<bool> AppRunning = delegate { return Process.GetProcessesByName("StreamDeck").Length > 0; };

        public static string ProfileDir()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Elgato\StreamDeck\ProfilesV3\" + ProfileId + ".sdProfile");
        }

        // "set" (written), "already" (MAIN was current), "running" (refused), "no-profile", "no-main", "error: ..."
        public static string SetCurrentToMain(string profDir)
        {
            try
            {
                if (AppRunning()) return "running";
                string man = Path.Combine(profDir ?? "", "manifest.json");
                if (!File.Exists(man)) return "no-profile";
                byte[] raw = File.ReadAllBytes(man);
                bool bom = raw.Length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF;
                string text = Encoding.UTF8.GetString(raw, bom ? 3 : 0, raw.Length - (bom ? 3 : 0));
                string main = FindMain(profDir, text);
                if (main == null) return "no-main";
                Match cur = Regex.Match(text, "(\"Current\"\\s*:\\s*\")([0-9A-Fa-f-]+)(\")");
                if (!cur.Success) return "no-main";
                if (cur.Groups[2].Value.Equals(main, StringComparison.OrdinalIgnoreCase)) return "already";
                string next = text.Substring(0, cur.Groups[2].Index) + main + text.Substring(cur.Groups[2].Index + cur.Groups[2].Length);
                byte[] body = Encoding.UTF8.GetBytes(next);
                byte[] outb = bom ? new byte[body.Length + 3] : body;
                if (bom) { outb[0] = 0xEF; outb[1] = 0xBB; outb[2] = 0xBF; Array.Copy(body, 0, outb, 3, body.Length); }
                if (AppRunning()) return "running";   // checked again right before the write
                // SHUT DOWN follows within milliseconds: the new manifest is flushed to disk first, then swapped in by one rename
                // (File.Replace), so a cut-off write can never leave a half manifest and a deck with no profile. The old one is kept.
                string tmp = man + ".paddock-tmp";
                using (FileStream fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
                { fs.Write(outb, 0, outb.Length); fs.Flush(true); }
                File.Replace(tmp, man, man + ".paddock-bak");
                return "set";
            }
            catch (Exception ex) { return "error: " + ex.Message; }
        }

        // The page in the profile's Pages list whose own manifest is named MAIN, spelled as the list spells it.
        public static string FindMain(string profDir, string manifestText)
        {
            var js = new System.Web.Script.Serialization.JavaScriptSerializer();
            Dictionary<string, object> m = js.DeserializeObject(manifestText) as Dictionary<string, object>;
            object pagesO; if (m == null || !m.TryGetValue("Pages", out pagesO)) return null;
            Dictionary<string, object> pages = pagesO as Dictionary<string, object>;
            object listO; if (pages == null || !pages.TryGetValue("Pages", out listO)) return null;
            IEnumerable list = listO as IEnumerable;
            if (list == null) return null;
            foreach (object o in list)
            {
                string id = o as string; if (string.IsNullOrEmpty(id)) continue;
                string pm = Path.Combine(Path.Combine(Path.Combine(profDir, "Profiles"), id.ToUpperInvariant()), "manifest.json");
                if (!File.Exists(pm)) continue;
                Dictionary<string, object> page = js.DeserializeObject(File.ReadAllText(pm, Encoding.UTF8)) as Dictionary<string, object>;
                object name;
                if (page != null && page.TryGetValue("Name", out name) && "MAIN".Equals(name as string, StringComparison.Ordinal)) return id;
            }
            return null;
        }
    }
}
