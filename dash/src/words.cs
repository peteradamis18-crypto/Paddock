// WORDS (W1-11, docs/rework/cards/W1-11.md): the one hook where a language model may rewrite a race's YouTube title and the first two
// paragraphs of its description. OFF by default: dash\irdash.ini youtube_words=templates|claude (templates when missing).
// With "claude" AND a key file dash\yt\claude-key.txt (Peter makes it; never in git, never logged, never in a URL), one call per race
// to the Claude API (claude-sonnet-5-5, at most 400 output tokens, thinking off) with the fixed prompt in docs\youtube-words.md.
// The answer is used only when it keeps the facts: every number in it must be one the templates already wrote, no banned clickbait
// word, YouTube's lengths. On ANY failure (no key, no prompt, no internet, a refusal, a bad answer) the templates stand. The chapters
// and the sign-off are never sent to the model and never changed by it. Tests answer through Ask (a stub); they never call the API.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace IRDash
{
    sealed class Draft
    {
        public string Title = "", About = "", Source = "templates";
        public Draft(string title, string about) { Title = title ?? ""; About = about ?? ""; }
    }

    static class Words
    {
        public const string Model = "claude-sonnet-5-5";
        public const int MaxTokens = 400;
        public static string ApiUrl = "https://api.anthropic.com/v1/messages";
        public static Func<string, string> Ask;            // tests: the request body -> the answer body (a stub); null = the real API
        public static string KeyFileOverride, PromptFileOverride;
        static string KeyFile { get { return KeyFileOverride ?? Path.Combine(YouTube.Dir, "claude-key.txt"); } }
        static string PromptFile { get { return PromptFileOverride ?? Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(Path.GetFullPath(YouTube.IniFile))) ?? "", "docs", "youtube-words.md"); } }
        static readonly Dictionary<string, Draft> done = new Dictionary<string, Draft>();   // one call per race: the same race asks once
        static readonly string[] Banned = { "insane", "unbelievable", "you won't believe", "shocking", "epic", "crazy", "destroyed", "!!", "comeback", "#1", "best ever" };

        public static string Mode()
        {
            try
            {
                if (File.Exists(YouTube.IniFile))
                    foreach (string raw in File.ReadAllLines(YouTube.IniFile))
                    {
                        string t = raw.Trim(); int e = t.IndexOf('=');
                        if (e > 0 && t.Substring(0, e).Trim().Equals("youtube_words", StringComparison.OrdinalIgnoreCase))
                            return t.Substring(e + 1).Trim().Equals("claude", StringComparison.OrdinalIgnoreCase) ? "claude" : "templates";
                    }
            }
            catch { }
            return "templates";
        }

        public static Draft Improve(Facts f, Draft draft)
        {
            if (Mode() != "claude") return draft;
            string key = "";
            try { if (File.Exists(KeyFile)) key = File.ReadAllText(KeyFile).Trim(); } catch { }
            if (key.Length == 0) { RigState.LogOnce("words no key", "youtube words: youtube_words=claude but there is no dash\\yt\\claude-key.txt - the templates stay"); return draft; }
            string prompt = Prompt();
            if (prompt.Length == 0) { RigState.LogOnce("words no prompt", "youtube words: no prompt in docs\\youtube-words.md - the templates stay"); return draft; }
            string memo = draft.Title + "\n" + draft.About;
            lock (done) { Draft had; if (done.TryGetValue(memo, out had)) return had; }
            Draft res = draft;
            try
            {
                string body = Request(prompt, f, draft);
                Func<string, string> ask = Ask;
                string answer = ask != null ? ask(body) : Post(body, key);
                string why;
                Draft got = Read(answer, draft, out why);
                if (got != null) { res = got; Log.W("youtube words: the model rewrote the title and description"); }
                else Log.W("youtube words: the model's answer was not used (" + why + ") - the templates stay");
            }
            catch (WebException ex) { Log.W("youtube words: the Claude API did not answer (" + ex.Status + ") - the templates stay"); }
            catch (Exception ex) { Log.W("youtube words: " + ex.GetType().Name + " - the templates stay"); }
            lock (done) done[memo] = res;
            return res;
        }

        // the fenced block of docs\youtube-words.md is the prompt, word for word
        static string Prompt()
        {
            try
            {
                if (!File.Exists(PromptFile)) return "";
                Match m = Regex.Match(File.ReadAllText(PromptFile, Encoding.UTF8), "```text\\r?\\n(.*?)\\r?\\n```", RegexOptions.Singleline);
                return m.Success ? m.Groups[1].Value.Trim() : "";
            }
            catch { return ""; }
        }

        internal static string Request(string prompt, Facts f, Draft d)
        {
            CultureInfo inv = CultureInfo.InvariantCulture;
            StringBuilder facts = new StringBuilder();
            facts.Append("car: ").Append(f.Car).Append("\ntrack: ").Append(f.Track).Append(f.Config.Length > 0 ? " (" + f.Config + ")" : "");
            if (f.Series.Length > 0) facts.Append("\nseries: ").Append(f.Series);
            if (f.Start > 0) facts.Append("\nstarted: P").Append(f.Start.ToString(inv));
            if (f.Finish > 0) facts.Append("\nfinished: P").Append(f.Finish.ToString(inv));
            if (f.Field > 0) facts.Append("\ncars in class: ").Append(f.Field.ToString(inv));
            if (f.Laps > 0) facts.Append("\nlaps: ").Append(f.Laps.ToString(inv));
            if (f.BestLap.Length > 0) facts.Append("\nbest lap: ").Append(f.BestLap);
            if (f.FastestLap) facts.Append("\nfastest lap of the race: yes");
            if (f.Incidents >= 0) facts.Append("\nincident points: ").Append(f.Incidents.ToString(inv));
            if (f.IrChange != int.MinValue) facts.Append("\niRating change: ").Append(f.IrChange.ToString(inv));
            if (f.PassLap > 0) facts.Append("\ndecisive pass: for P").Append(f.PassFor.ToString(inv)).Append(" on lap ").Append(f.PassLap.ToString(inv));
            string user = "FACTS\n" + facts + "\n\nDRAFT TITLE\n" + d.Title + "\n\nDRAFT DESCRIPTION\n" + d.About;
            return "{\"model\":" + Json_.S(Model) + ",\"max_tokens\":" + MaxTokens.ToString(inv) + ",\"thinking\":{\"type\":\"between_tools\"}" +
                   ",\"system\":" + Json_.S(prompt) + ",\"messages\":[{\"role\":\"user\",\"content\":" + Json_.S(user) + "}]}";
        }

        static string Post(string body, string key)
        {
            try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
            HttpWebRequest q = (HttpWebRequest)WebRequest.Create(ApiUrl);
            q.Method = "POST"; q.ContentType = "application/json"; q.Timeout = 30000; q.ReadWriteTimeout = 30000;
            q.Headers["x-api-key"] = key; q.Headers["anthropic-version"] = "2023-06-01";
            byte[] b = Encoding.UTF8.GetBytes(body);
            using (Stream s = q.GetRequestStream()) s.Write(b, 0, b.Length);
            using (HttpWebResponse r = (HttpWebResponse)q.GetResponse())
            using (StreamReader rd = new StreamReader(r.GetResponseStream(), Encoding.UTF8)) return rd.ReadToEnd();
        }

        // the answer -> a draft, or null with why. The model must answer {"title":"...","description":"..."} and keep every number.
        internal static Draft Read(string answer, Draft draft, out string why)
        {
            why = "";
            JavaScriptSerializer js = new JavaScriptSerializer();
            Dictionary<string, object> r = js.DeserializeObject(answer ?? "") as Dictionary<string, object>;
            if (r == null) { why = "not JSON"; return null; }
            object stop; r.TryGetValue("stop_reason", out stop);
            if (Convert.ToString(stop) != "end_turn") { why = "stopped: " + Convert.ToString(stop); return null; }
            string text = "";
            object[] content = r.ContainsKey("content") ? r["content"] as object[] : null;
            if (content != null) foreach (object o in content) { Dictionary<string, object> c = o as Dictionary<string, object>; if (c != null && Convert.ToString(c["type"]) == "text") text += Convert.ToString(c["text"]); }
            Match m = Regex.Match(text, "\\{.*\\}", RegexOptions.Singleline);
            Dictionary<string, object> w = m.Success ? js.DeserializeObject(m.Value) as Dictionary<string, object> : null;
            if (w == null || !w.ContainsKey("title") || !w.ContainsKey("description")) { why = "no title and description"; return null; }
            string t = Convert.ToString(w["title"]).Replace("\r", " ").Replace("\n", " ").Trim(), a = Convert.ToString(w["description"]).Replace("\r", "").Trim();
            if (t.Length < 10 || t.Length > 100) { why = "the title is " + t.Length + " characters"; return null; }
            if (a.Length < 20 || a.Length > 3000) { why = "the description is " + a.Length + " characters"; return null; }
            if (t.IndexOfAny(new char[] { '<', '>' }) >= 0 || a.IndexOfAny(new char[] { '<', '>' }) >= 0) { why = "angle brackets"; return null; }
            string all = (t + " " + a).ToLowerInvariant();
            foreach (string b in Banned) if (all.Contains(b) && !(draft.Title + " " + draft.About).ToLowerInvariant().Contains(b)) { why = "clickbait (" + b + ")"; return null; }
            // no lie: every number it writes is one the facts already carry
            HashSet<string> known = new HashSet<string>();
            foreach (Match n in Regex.Matches(draft.Title + " " + draft.About, "\\d+(?:[.:]\\d+)*")) known.Add(n.Value);
            foreach (Match n in Regex.Matches(t + " " + a, "\\d+(?:[.:]\\d+)*")) if (!known.Contains(n.Value)) { why = "a number that is not in the facts (" + n.Value + ")"; return null; }
            Draft d = new Draft(t, a); d.Source = "claude";
            return d;
        }
    }
}
