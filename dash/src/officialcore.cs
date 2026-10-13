// Official racing, the pure part (WS8 in docs\SPEC-next.md, docs\official.md): reads iRacing's published season schedule
// PDF, works out which series Peter can enter (cars and tracks he owns, licence class), and projects each series' race
// pattern ("Races every 2 hours at :15 past") onto real start times. No files, no web, no irdash types in here, so
// tests\official-test.ps1 compiles this one file on its own and checks it against fixtures.
// C# 5 only (Windows' csc).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace IRDash
{
    public sealed class PdfItem { public int Page; public double X, Y; public string T = ""; }

    // Text out of a PDF made by iText (iRacing's schedule is): Flate streams, plain WinAnsi strings, Tm positions.
    public static class PdfText
    {
        static readonly Encoding Latin = Encoding.GetEncoding(28591);
        static readonly Regex StreamRx = new Regex(@"(\d+) 0 obj\s*(<<(?:(?!endobj).)*?>>)\s*stream\r?\n", RegexOptions.Singleline | RegexOptions.Compiled);
        static readonly Regex PageRx = new Regex(@"(\d+) 0 obj\s*<</Type/Page/[^\r\n]*?/Contents (\[[^\]]*\]|\d+ 0 R)", RegexOptions.Compiled);
        static readonly Regex OpRx = new Regex(@"[\d.\-]+ [\d.\-]+ [\d.\-]+ [\d.\-]+ ([\d.\-]+) ([\d.\-]+) Tm|\(((?:\\.|[^\\)])*)\)\s*Tj|\[((?:\((?:\\.|[^\\)])*\)|[^\]])*)\]\s*TJ", RegexOptions.Compiled);
        static readonly Regex StrRx = new Regex(@"\(((?:\\.|[^\\)])*)\)", RegexOptions.Compiled);

        static string Unescape(string t)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < t.Length; i++)
            {
                char c = t[i];
                if (c == '\\' && i + 1 < t.Length)
                {
                    char n = t[++i];
                    if (n == 'n') sb.Append(' ');
                    else if (n == 'r') { }
                    else if (n == 't') sb.Append(' ');
                    else if (n >= '0' && n <= '7')
                    {
                        int v = n - '0';
                        for (int k = 0; k < 2 && i + 1 < t.Length && t[i + 1] >= '0' && t[i + 1] <= '7'; k++) v = v * 8 + (t[++i] - '0');
                        sb.Append((char)v);
                    }
                    else sb.Append(n);
                }
                else sb.Append(c);
            }
            // WinAnsi punctuation that Latin-1 leaves as control codes
            return sb.ToString().Replace('\u0091', '\'').Replace('\u0092', '\'').Replace('\u0093', '"').Replace('\u0094', '"')
                .Replace('\u0096', '-').Replace('\u0097', '-').Replace('\u0095', '*');
        }

        public static List<PdfItem> Extract(byte[] pdf)
        {
            string s = Latin.GetString(pdf);
            Dictionary<int, string> streams = new Dictionary<int, string>();
            foreach (Match m in StreamRx.Matches(s))
            {
                if (!m.Groups[2].Value.Contains("FlateDecode")) continue;
                int st = m.Index + m.Length, en = s.IndexOf("endstream", st, StringComparison.Ordinal);
                if (en < st + 3) continue;
                try
                {
                    using (MemoryStream ms = new MemoryStream(pdf, st + 2, en - st - 2))      // skip the 2-byte zlib header
                    using (DeflateStream z = new DeflateStream(ms, CompressionMode.Decompress))
                    using (MemoryStream o = new MemoryStream())
                    {
                        z.CopyTo(o);
                        streams[int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)] = Latin.GetString(o.ToArray());
                    }
                }
                catch { }
            }
            List<PdfItem> all = new List<PdfItem>();
            int page = 0;
            foreach (Match m in PageRx.Matches(s))
            {
                page++;
                List<PdfItem> items = new List<PdfItem>();
                foreach (Match r in Regex.Matches(m.Groups[2].Value, @"(\d+) 0 R"))
                {
                    string c;
                    if (!streams.TryGetValue(int.Parse(r.Groups[1].Value, CultureInfo.InvariantCulture), out c)) continue;
                    double x = 0, y = 0;
                    foreach (Match t in OpRx.Matches(c))
                    {
                        if (t.Groups[1].Success)
                        {
                            x = double.Parse(t.Groups[1].Value, CultureInfo.InvariantCulture);
                            y = double.Parse(t.Groups[2].Value, CultureInfo.InvariantCulture);
                            continue;
                        }
                        string u;
                        if (t.Groups[3].Success) u = Unescape(t.Groups[3].Value);
                        else { StringBuilder sb = new StringBuilder(); foreach (Match q in StrRx.Matches(t.Groups[4].Value)) sb.Append(Unescape(q.Groups[1].Value)); u = sb.ToString(); }
                        PdfItem it = new PdfItem(); it.Page = page; it.X = x; it.Y = y; it.T = u;
                        items.Add(it);
                    }
                }
                items.Sort(delegate (PdfItem a, PdfItem b) { int c2 = b.Y.CompareTo(a.Y); return c2 != 0 ? c2 : a.X.CompareTo(b.X); });
                all.AddRange(items);
            }
            return all;
        }
    }

    public sealed class OfWeek
    {
        public int N; public DateTime Start;                 // Start = Tuesday 00:00 UTC, the day iRacing's week turns over
        public string Track = "", Layout = "", Length = "", Weather = "", SimDate = "";
        public string Base { get { return Track; } }
    }

    public sealed class OfSeries
    {
        public string Id = "", Name = "", Short = "", Key = "", Lic = "R", LicText = "", Freq = "", Header = "";
        public List<string> Cars = new List<string>();
        public List<OfWeek> Weeks = new List<OfWeek>();
        public bool CarsKnown { get { return Cars.Count > 0; } }
    }

    // when a series races: "every 2 hours at :15" or fixed days and hours (UTC)
    public sealed class OfPattern
    {
        public bool Ok; public string Text = "";
        public int EveryHours;                               // 1 = every hour, 2 = every second hour; 0 = day slots instead
        public int Parity = -1;                              // 2-hourly: 0 = even UTC hours, 1 = odd, -1 = not stated (even assumed, marked est)
        public List<int> Minutes = new List<int>();
        public List<OfSlotGroup> Slots = new List<OfSlotGroup>();
        public bool Alternate;                               // "every other Saturday": which Saturdays is not published
        public bool Est { get { return Alternate || (EveryHours == 2 && Parity < 0); } }
    }
    public sealed class OfSlotGroup { public List<int> Days = new List<int>(); public List<int> Mins = new List<int>(); }   // Days: 0 = Sunday ... 6 = Saturday; Mins = minutes since midnight UTC

    public sealed class OfRace
    {
        public DateTime Utc; public bool Est; public OfSeries S; public OfWeek W;
    }

    public static class OfficialCore
    {
        // ------------------------------------------------------------------ the season PDF -> series
        static readonly Regex WeekRx = new Regex(@"^Week\s+(\d+)\s*\((\d{4})-(\d\d)-(\d\d)\)", RegexOptions.Compiled);
        static readonly Regex LicRx = new Regex(@"^(Rookie|Class [A-D]|Pro(/WC)?)\b.*\(\d(\.\d)?\)\s*-->|-->\s*(Pro|Class)", RegexOptions.Compiled);

        public static List<OfSeries> ParseSeason(List<PdfItem> items)
        {
            List<OfSeries> list = new List<OfSeries>();
            List<string> buf = new List<string>();            // left-column lines since the last week row: the next series' title and cars
            OfSeries cur = null; OfWeek w = null; int mode = 0;   // 0 = collecting a title, 1 = header lines of a series, 2 = week rows
            List<string> c1 = new List<string>(), c2 = new List<string>(), c3 = new List<string>();
            Action finishWeek = delegate
            {
                if (w == null) return;
                string track = "", sim = "";
                foreach (string t in c1) { if (Regex.IsMatch(t, @"^\(\d{4}-\d\d-\d\d")) sim = t; else track = (track + " " + t).Trim(); }
                int d = track.IndexOf(" - ", StringComparison.Ordinal);
                w.Track = d > 0 ? track.Substring(0, d).Trim() : track;
                w.Layout = d > 0 ? track.Substring(d + 3).Trim() : "";
                w.SimDate = sim; w.Weather = string.Join(" ", c2.ToArray()); w.Length = string.Join(" ", c3.ToArray()).Trim();
                cur.Weeks.Add(w); w = null; c1.Clear(); c2.Clear(); c3.Clear();
            };
            foreach (PdfItem it in items)
            {
                string t = it.T.Trim();
                if (t.Length == 0 || it.Y < 40) continue;                  // page numbers at the bottom
                if (it.X < 120)
                {
                    Match wm = WeekRx.Match(t);
                    if (wm.Success && cur != null)
                    {
                        finishWeek();
                        mode = 2;
                        w = new OfWeek();
                        w.N = int.Parse(wm.Groups[1].Value, CultureInfo.InvariantCulture);
                        w.Start = new DateTime(int.Parse(wm.Groups[2].Value, CultureInfo.InvariantCulture), int.Parse(wm.Groups[3].Value, CultureInfo.InvariantCulture), int.Parse(wm.Groups[4].Value, CultureInfo.InvariantCulture), 0, 0, 0, DateTimeKind.Utc);
                        continue;
                    }
                    if (mode == 2) { finishWeek(); mode = 0; buf.Clear(); }
                    if (mode == 0)
                    {
                        if (LicRx.IsMatch(t))
                        {
                            OfSeries s = new OfSeries();
                            int ti = -1;
                            for (int i = buf.Count - 1; i >= 0; i--) if (Regex.IsMatch(buf[i], @"Season")) { ti = i; break; }
                            if (ti < 0) ti = 0;
                            for (int i = 0; i < buf.Count; i++)
                            {
                                if (i < ti) continue;                       // anything before the title is a stray
                                if (i == ti) s.Name = buf[i];
                                else s.Header += (s.Header.Length > 0 ? " " : "") + buf[i];
                            }
                            s.LicText = t;
                            Match lm = Regex.Match(t, @"^(Rookie|Class ([A-D])|Pro)");
                            s.Lic = !lm.Success ? "R" : lm.Groups[1].Value == "Rookie" ? "R" : lm.Groups[1].Value == "Pro" ? "P" : lm.Groups[2].Value;
                            s.Cars = SplitCars(s.Header);
                            s.Name = Regex.Replace(s.Name, @"\s+", " ").Trim();
                            list.Add(s); cur = s; mode = 1; continue;
                        }
                        buf.Add(t); continue;
                    }
                    if (mode == 1) { cur.Freq += (cur.Freq.Length > 0 ? " " : "") + t; continue; }
                }
                else if (mode == 2 && w != null)
                {
                    if (it.X < 350) c1.Add(t); else if (it.X < 510) c2.Add(t); else c3.Add(t);
                }
            }
            finishWeek();
            // names, ids, pattern text
            Dictionary<string, int> seen = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (OfSeries s in list)
            {
                s.Short = ShortName(s.Name);
                s.Key = Norm(s.Short);
                int n; seen.TryGetValue(s.Key, out n); seen[s.Key] = n + 1;
                s.Id = "o" + Fnv(s.Key + (n > 0 ? "#" + n : ""));
                if (n > 0) s.Key += n;
                s.Freq = PatternText(s.Freq);
            }
            return list;
        }

        // Published iRacing season page: a PDF href on iracing.com, else an HTML season table. Unknown stays empty.
        public static string FindSeasonPdfHref(string html)
        {
            if (string.IsNullOrEmpty(html)) return "";
            foreach (Match m in Regex.Matches(html, @"href\s*=\s*[""']([^""']+\.pdf)[""']", RegexOptions.IgnoreCase))
            {
                string href = (m.Groups[1].Value ?? "").Trim();
                if (href.StartsWith("//")) href = "https:" + href;
                if (href.StartsWith("/")) href = "https://www.iracing.com" + href;
                href = href.Replace("&", "&");
                if (Regex.IsMatch(href, @"^https://(www\.)?iracing\.com/[A-Za-z0-9./_%-]+\.pdf$", RegexOptions.IgnoreCase)) return href;
            }
            return "";
        }

        static string HtmlCell(string raw)
        {
            string t = Regex.Replace(raw ?? "", @"<[^>]+>", " ");
            t = t.Replace("&nbsp;", " ").Replace("&", "&").Replace("<", "<").Replace(">", ">").Replace("&#39;", "'").Replace("&quot;", "\"");
            return Regex.Replace(t, @"\s+", " ").Trim();
        }

        static void FinishHtmlSeries(List<OfSeries> list)
        {
            Dictionary<string, int> seen = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (OfSeries s in list)
            {
                s.Short = ShortName(s.Name);
                s.Key = Norm(s.Short);
                int n; seen.TryGetValue(s.Key, out n); seen[s.Key] = n + 1;
                s.Id = "o" + Fnv(s.Key + (n > 0 ? "#" + n : ""));
                if (n > 0) s.Key += n;
                s.Freq = PatternText(s.Freq);
            }
        }

        // Same OfSeries/OfWeek fields as the PDF parser. Empty when the page has no published table.
        public static List<OfSeries> ParseHtmlSeason(string html)
        {
            List<OfSeries> list = new List<OfSeries>();
            if (string.IsNullOrEmpty(html)) return list;
            OfSeries cur = null;
            foreach (Match row in Regex.Matches(html, @"<tr[^>]*>(.*?)</tr>", RegexOptions.IgnoreCase | RegexOptions.Singleline))
            {
                List<string> cells = new List<string>();
                foreach (Match td in Regex.Matches(row.Groups[1].Value, @"<t[dh][^>]*>(.*?)</t[dh]>", RegexOptions.IgnoreCase | RegexOptions.Singleline))
                    cells.Add(HtmlCell(td.Groups[1].Value));
                if (cells.Count == 0) continue;
                Match wm = WeekRx.Match(cells[0]);
                if (wm.Success && cur != null)
                {
                    OfWeek w = new OfWeek();
                    w.N = int.Parse(wm.Groups[1].Value, CultureInfo.InvariantCulture);
                    w.Start = new DateTime(int.Parse(wm.Groups[2].Value, CultureInfo.InvariantCulture), int.Parse(wm.Groups[3].Value, CultureInfo.InvariantCulture), int.Parse(wm.Groups[4].Value, CultureInfo.InvariantCulture), 0, 0, 0, DateTimeKind.Utc);
                    string track = cells.Count > 1 ? cells[1] : "";
                    int d = track.IndexOf(" - ", StringComparison.Ordinal);
                    w.Track = d > 0 ? track.Substring(0, d).Trim() : track;
                    w.Layout = d > 0 ? track.Substring(d + 3).Trim() : "";
                    if (cells.Count > 3) w.Length = cells[3];
                    else if (cells.Count > 2 && !Regex.IsMatch(cells[2], @"Rain|F/|C,")) w.Length = cells[2];
                    cur.Weeks.Add(w);
                    continue;
                }
                if (cells.Count >= 4 && (cells[0].IndexOf("Season", StringComparison.OrdinalIgnoreCase) >= 0 || row.Groups[0].Value.IndexOf("data-series", StringComparison.OrdinalIgnoreCase) >= 0))
                {
                    OfSeries s = new OfSeries();
                    s.Name = Regex.Replace(cells[0], @"\s+", " ").Trim();
                    s.Cars = SplitCars(cells[1]);
                    s.LicText = cells[2];
                    Match lm = Regex.Match(cells[2], @"^(Rookie|Class ([A-D])|Pro)");
                    s.Lic = !lm.Success ? "R" : lm.Groups[1].Value == "Rookie" ? "R" : lm.Groups[1].Value == "Pro" ? "P" : lm.Groups[2].Value;
                    s.Freq = cells[3];
                    list.Add(s); cur = s;
                }
            }
            FinishHtmlSeries(list);
            return list;
        }

        // "not published" when the page has no PDF and no series table. Never invents a start.
        public static string SeasonPublishedState(string html)
        {
            if (string.IsNullOrEmpty(html)) return "not published";
            if (FindSeasonPdfHref(html).Length > 0) return "published";
            if (ParseHtmlSeason(html).Count > 0) return "published";
            return "not published";
        }

        public sealed class SessionHint { public DateTime When; public string Car = "", Track = "", Series = ""; }

        // Favourites union series named in the last 90 days. Car or track alone never implies a series.
        public static HashSet<string> HisSeriesKeys(IEnumerable<string> favNames, IEnumerable<SessionHint> sessions, DateTime nowUtc)
        {
            HashSet<string> k = new HashSet<string>();
            if (favNames != null)
                foreach (string n in favNames) { string x = Norm(ShortName(n)); if (x.Length > 0) k.Add(x); }
            if (sessions == null) return k;
            DateTime cut = nowUtc.AddHours(-90 * 24);
            foreach (SessionHint h in sessions)
            {
                if (h == null || h.When < cut || h.When > nowUtc) continue;
                string x = Norm(ShortName(h.Series));
                if (x.Length > 0) k.Add(x);
            }
            return k;
        }

        public static bool IsHisSeries(OfSeries s, HashSet<string> keys)
        {
            if (s == null || keys == null || keys.Count == 0) return false;
            return keys.Contains(s.Key) || keys.Contains(Norm(s.Short));
        }

        // "Series name - 2026 Season 4 - Fixed" -> "Series name - Fixed" (the season changes every 12 weeks; favourites must outlive it)
        public static string ShortName(string name)
        {
            string s = Regex.Replace(name ?? "", @"\s*-?\s*20\d\d\s+Season(\s+\d)?", " ", RegexOptions.IgnoreCase);
            s = Regex.Replace(s, @"\s+", " ").Trim().Trim('-').Trim();
            s = Regex.Replace(s, @"Fixed(\s*-?\s*Fixed)+", "Fixed");                   // "- Fixed - 2026 Season 4 Fixed"
            s = Regex.Replace(s, @"\bSeries Series\b", "Series");
            return s;
        }

        // the list of cars in the header paragraph: names separated by ", ", wrapped over lines
        static List<string> SplitCars(string header)
        {
            List<string> cars = new List<string>();
            string h = header ?? "";
            int e = h.IndexOf("-->", StringComparison.Ordinal);
            if (e >= 0) h = h.Substring(0, e);
            // the licence line may be glued behind the cars when it was the first header line: not here (it ends the title block)
            h = Regex.Replace(h, @"\s+", " ").Trim();
            h = Regex.Replace(h, @"(?<=\S)- (?=[A-Za-z])", "-");                       // "V- Series.R" was one name wrapped over two lines
            h = Regex.Replace(h, @"\[(Legacy|Retired)\]\s*", "");
            if (h.Length == 0 || h.StartsWith("See race week", StringComparison.OrdinalIgnoreCase)) return cars;
            foreach (string c in h.Split(new string[] { ", " }, StringSplitOptions.RemoveEmptyEntries))
            {
                string n = c.Trim();
                if (n.Length > 1 && !Regex.IsMatch(n, @"^(Rookie|Class [A-D]|Pro)\b")) cars.Add(n);
            }
            return cars;
        }

        // the part of the header lines that says when the series races
        static string PatternText(string freq)
        {
            string f = Regex.Replace(freq ?? "", @"\s+", " ").Trim();
            Match m = Regex.Match(f, @"(Races?\b|Every\b|\d+ Timeslots).*?(?=Min entries|Penalty|No incident|$)", RegexOptions.IgnoreCase);
            string p = m.Success ? m.Value.Trim() : "";
            int bar = p.IndexOf('|'); if (bar > 0) p = p.Substring(0, bar).Trim();
            return p;
        }

        public static string Norm(string s)
        {
            StringBuilder sb = new StringBuilder();
            foreach (char c in (s ?? "").Normalize(NormalizationForm.FormD).ToLowerInvariant())   // "Huracán" = "Huracan"
                if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) sb.Append(c);
            return sb.ToString();
        }

        public static string Fnv(string text)
        {
            uint h = 2166136261u;
            foreach (char c in (text ?? "").ToLowerInvariant()) { h ^= c; h = unchecked(h * 16777619u); }
            return h.ToString("x8", CultureInfo.InvariantCulture);
        }

        // ------------------------------------------------------------------ when does it race?
        static readonly Regex DayTok = new Regex(@"\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*|\b(\d{1,2})(?::(\d\d))?\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        static readonly string[] DayNames = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

        public static OfPattern ParsePattern(string text)
        {
            OfPattern p = new OfPattern(); p.Text = text ?? "";
            string t = p.Text;
            int bar = t.IndexOf('|'); if (bar > 0) t = t.Substring(0, bar);
            if (t.Length == 0 || Regex.IsMatch(t, @"Timeslots", RegexOptions.IgnoreCase)) return p;
            if (Regex.IsMatch(t, @"GMT|UTC"))
            {
                // fixed days and hours: "Thur & Sat at 10, 19 GMT & Fri & Sun at 1,4 GMT"
                p.Alternate = Regex.IsMatch(t, @"every other", RegexOptions.IgnoreCase);
                OfSlotGroup g = null;
                foreach (Match m in DayTok.Matches(t))
                {
                    if (m.Groups[1].Success)
                    {
                        int d = Array.IndexOf(DayNames, m.Groups[1].Value.ToLowerInvariant());
                        if (d < 0) continue;
                        if (g == null || g.Mins.Count > 0) { g = new OfSlotGroup(); p.Slots.Add(g); }
                        if (!g.Days.Contains(d)) g.Days.Add(d);
                    }
                    else if (g != null)
                    {
                        int h = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture), mi = m.Groups[3].Success ? int.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture) : 0;
                        if (h <= 23 && mi <= 59) g.Mins.Add(h * 60 + mi);
                    }
                }
                p.Slots.RemoveAll(delegate (OfSlotGroup x) { return x.Mins.Count == 0; });
                p.Ok = p.Slots.Count > 0;
                return p;
            }
            // regular pattern
            Match nh = Regex.Match(t, @"(\d+)\s*hours?", RegexOptions.IgnoreCase);
            bool thirty = Regex.IsMatch(t, @"30\s*min|thirty\s*min", RegexOptions.IgnoreCase);
            if (nh.Success && !thirty) p.EveryHours = int.Parse(nh.Groups[1].Value, CultureInfo.InvariantCulture);
            else if (thirty || Regex.IsMatch(t, @"hour|hourly|:\d\d", RegexOptions.IgnoreCase)) p.EveryHours = 1;
            else return p;
            if (p.EveryHours < 1 || p.EveryHours > 12) { p.EveryHours = 0; return p; }
            if (Regex.IsMatch(t, @"\beven\b", RegexOptions.IgnoreCase)) p.Parity = 0;
            else if (Regex.IsMatch(t, @"\bodd\b", RegexOptions.IgnoreCase)) p.Parity = 1;
            foreach (Match m in Regex.Matches(t, @":(\d\d)")) AddMin(p, int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture));
            foreach (Match m in Regex.Matches(t, @"\b(\d\d?)\s+past\b", RegexOptions.IgnoreCase)) AddMin(p, int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture));
            if (p.Minutes.Count == 0)
            {
                if (Regex.IsMatch(t, @"half\s+past", RegexOptions.IgnoreCase)) p.Minutes.Add(30);
                else if (thirty) { p.Minutes.Add(0); p.Minutes.Add(30); }
                else p.Minutes.Add(0);                                // "on the hour", "top of the hour", "on the 00"
            }
            p.Minutes.Sort();
            p.Ok = true;
            return p;
        }
        static void AddMin(OfPattern p, int m) { if (m >= 0 && m < 60 && !p.Minutes.Contains(m)) p.Minutes.Add(m); }

        // every start inside [from, to) UTC
        public static List<DateTime> Project(OfPattern p, DateTime from, DateTime to)
        {
            List<DateTime> r = new List<DateTime>();
            if (!p.Ok) return r;
            if (p.Slots.Count > 0)
            {
                for (DateTime d = from.Date; d < to; d = d.AddDays(1))
                    foreach (OfSlotGroup g in p.Slots)
                        if (g.Days.Contains((int)d.DayOfWeek))
                            foreach (int mi in g.Mins) { DateTime x = d.AddMinutes(mi); if (x >= from && x < to) r.Add(x); }
                r.Sort();
                return r;
            }
            int par = p.Parity < 0 ? 0 : p.Parity;
            DateTime h0 = new DateTime(from.Year, from.Month, from.Day, from.Hour, 0, 0, DateTimeKind.Utc).AddHours(-p.EveryHours);
            for (DateTime h = h0; h < to; h = h.AddHours(1))
            {
                if (p.EveryHours > 1 && (h.Hour % p.EveryHours) != par % p.EveryHours) continue;
                foreach (int mi in p.Minutes) { DateTime x = h.AddMinutes(mi); if (x >= from && x < to) r.Add(x); }
            }
            r.Sort();
            return r;
        }

        // ------------------------------------------------------------------ what Peter owns
        // iRacing's folder names -> the names iRacing's schedule and UI use. The folder lists are what is installed on this PC.
        // "folder|Name|other spelling|..."
        static readonly string[] CarTable = {
            "acuraarx06gtp|Acura ARX-06 GTP", "acuransxevo22gt3|Acura NSX GT3 EVO 22", "amvantageevogt3|Aston Martin Vantage GT3 EVO", "amvantagegt4|Aston Martin Vantage GT4",
            "astonmartin\\dbr9|Aston Martin DBR9 GT1", "audi90gto|Audi 90 GTO", "audir18|Audi R18", "audir8gt3|Audi R8 LMS GT3", "audir8lmsevo2gt3|Audi R8 LMS EVO II GT3",
            "audirs3lms|Audi RS3 LMS Gen2 TCR", "bmwlmdh|BMW M Hybrid V8 (Evo)|BMW M Hybrid V8", "bmwm2csr|BMW M2 CS Racing", "bmwm2g87|BMW M2 Racing (G87)",
            "bmwm4evogt4|BMW M4 G82 GT4 Evo", "bmwm4gt3|BMW M4 GT3 EVO|BMW M4 GT3", "bmwm4gt4|BMW M4 GT4", "bmwm8gte|BMW M8 GTE", "bmwz4gt3|BMW Z4 GT3", "c6r|Chevrolet Corvette C6.R GT1",
            "c7vettedp|Chevrolet Corvette C7 Daytona Prototype", "c8rvettegte|Chevrolet Corvette C8.R GTE", "cadillacctsvr|Cadillac CTS-V Racecar", "cadillacvseriesrgtp|Cadillac V-Series.R GTP",
            "chevyvettez06rgt3|Chevrolet Corvette Z06 GT3.R", "crosscartn11|FIA Cross Car", "dallara|Dallara IR-05", "dallaradw12|Dallara DW12", "dallaraf3|Dallara F3", "dallarail15|Dallara IL-15",
            "dallarair01|Dallara iR-01", "dallarair18|Dallara IR18", "dallarap217|Dallara P217",
            "dirtlatemodel|Dirt Late Model - Limited|Dirt Late Model - Pro|Dirt Late Model - Super", "dirtlatemodel\\350|Dirt Late Model - Limited", "dirtlatemodel\\358|Dirt Late Model - Pro", "dirtlatemodel\\438|Dirt Late Model - Super",
            "dirtmicrosprint|Dirt Micro Sprint Car - Non-Winged|Dirt Micro Sprint Car - Winged", "dirtmicrosprint\\nonwinged|Dirt Micro Sprint Car - Non-Winged", "dirtmicrosprint\\winged|Dirt Micro Sprint Car - Winged",
            "dirtmidget|Dirt Midget", "dirtministock|Dirt Mini Stock", "dirtmodified|Dirt Big Block Modified|Dirt 358 Modified", "dirtmodified\\358|Dirt 358 Modified", "dirtmodified\\bigblock|Dirt Big Block Modified",
            "dirtsprint|Dirt Sprint Car - 410|Dirt Sprint Car - 360|Dirt Sprint Car - 305", "dirtsprint\\winged\\410|Dirt Sprint Car - 410", "dirtsprint\\nonwinged\\410|Dirt Sprint Car - 410 Non-Winged",
            "dirtsprint\\winged\\360|Dirt Sprint Car - 360", "dirtsprint\\nonwinged\\360|Dirt Sprint Car - 360 Non-Winged", "dirtsprint\\winged\\305|Dirt Sprint Car - 305",
            "dirtstreetstock|Dirt Street Stock", "dirtumpmod|Dirt UMP Modified", "ferrari296challenge|Ferrari 296 Challenge", "ferrari296gt3|Ferrari 296 GT3", "ferrari488gt3|Ferrari 488 GT3",
            "ferrari488gte|Ferrari 488 GTE", "ferrari499p|Ferrari 499P", "ferrarievogt3|Ferrari 488 GT3 Evo 2020", "fordfiestarswrc|Ford Fiesta RS WRC", "fordgt|Ford GT GT2", "fordgt\\gt3|Ford GT GT3",
            "fordgt2017|Ford GTE", "fordmustanggt3|Ford Mustang GT3", "fordmustanggt4|Ford Mustang GT4", "fordv8sc|Ford Falcon FG V8 Supercar", "formulair04|Formula iR-04", "formulamazda|Formula Mazda 2000",
            "formularenault20|Formula Renault 2.0", "formularenault35|Formula Renault 3.5", "formulavee|Formula Vee - Classic|Formula Vee - Conqueror|Formula Vee - Sabre", "fr500s|Ford Mustang FR500S",
            "hondacivictyper|Honda Civic Type R TCR", "hpdarx01c|HPD ARX-01c", "hyundaielantracn7|Hyundai Elantra N TCR", "hyundaivelostern|Hyundai Veloster N TCR", "indypropm18|Indy Pro 2000 PM-18",
            "jettatdi|Volkswagen Jetta TDI Cup", "kiaoptima|Kia Optima", "lamborghinievogt3|Lamborghini Huracán GT3 EVO", "latemodel|Late Model Stock", "latemodel2023|Late Model Stock",
            "legends|Legends Ford '34 Coupe", "legends\\ford34c|Legends Ford '34 Coupe", "legends\\dirtford34c|Dirt Legends Ford '34 Coupe", "ligierjsp320|Ligier JS P320", "lotus49|Lotus 49", "lotus79|Lotus 79",
            "mclaren570sgt4|McLaren 570S GT4", "mclaren720sgt3|McLaren 720S GT3 EVO", "mclarenmp4|McLaren MP4-12C GT3", "mclarenmp430|McLaren MP4-30", "mercedesamgevogt3|Mercedes-AMG GT3 2020",
            "mercedesamggt3|Mercedes-AMG GT3", "mercedesamggt4|Mercedes-AMG GT4", "mercedesw12|Mercedes-AMG W12 E Performance", "mercedesw13|Mercedes-AMG W13 E Performance", "ministock|Mini Stock",
            "mx5|Mazda MX-5 Cup - 2010", "mx5\\mx52016|Global Mazda MX-5 Cup", "mx5\\cup|Mazda MX-5 Cup - 2010", "mx5\\roadster|Mazda MX-5 Roadster - 2010", "nissangtpzxt|Nissan GTP ZX-T",
            "porsche718gt4|Porsche 718 Cayman GT4 Clubsport MR", "porsche911cup|Porsche 911 GT3 Cup (991)", "porsche911rgt3|Porsche 911 GT3 R", "porsche919|Porsche 919", "porsche963gtp|Porsche 963 GTP",
            "porsche991rsr|Porsche 911 RSR", "porsche9922cup|Porsche 911 Cup (992.2)", "porsche992cup|Porsche 911 GT3 Cup (992.1)", "porsche992rgt3|Porsche 911 GT3 R (992)", "porschemissionr|Porsche Mission R",
            "protrucks\\pro2lite|Lucas Oil Off Road Pro 2 Lite", "protrucks\\pro2truck|Lucas Oil Off Road Pro 2 Truck", "protrucks\\pro4truck|Lucas Oil Off Road Pro 4 Truck",
            "radical\\sr8|Radical SR8", "radicalsr10|Radical SR10", "raygr22|Ray GR22", "renaultcliocup|Renault Clio", "rileydp|Riley Mk XX Daytona Prototype", "rt2000|Skip Barber Formula 2000",
            "rufrt12r|Ruf RT 12R", "silvercrown|Silver Crown", "skmodified|Modified - SK", "skmodified\\tour|Modified - NASCAR Whelen Tour", "solstice|Pontiac Solstice", "specracer|SCCA Spec Racer Ford",
            "sprint|Sprint Car", "srx|SRX", "stockcarbrasil\\corolla|Stock Car Brasil Toyota Corolla", "stockcarbrasil\\cruze|Stock Car Brasil Chevrolet Cruze",
            "stockcars\\buicklesabre87|NASCAR Legends Buick LeSabre - 1987", "stockcars\\chevymontecarlo87|NASCAR Legends Chevrolet Monte Carlo - 1987", "stockcars\\fordthunderbird87|NASCAR Legends Ford Thunderbird - 1987",
            "stockcars\\pontiacgrandprix87|NASCAR Legends Pontiac Grand Prix - 1987", "stockcars\\chevycamarozl12022|NASCAR Cup Series Next Gen Chevrolet Camaro ZL1",
            "stockcars\\fordmustang2022|NASCAR Cup Series Next Gen Ford Mustang", "stockcars\\toyotacamry2022|NASCAR Cup Series Next Gen Toyota Camry",
            "stockcars\\chevymontecarlo03|Gen 4 Chevrolet Monte Carlo - 2003", "stockcars\\fordtaurus03|Gen 4 Ford Taurus - 2003", "stockcars\\camarozl12018|NASCAR Cup Series Gen 6 Chevrolet Camaro ZL1",
            "stockcars2\\arcachevy25|ARCA Chevrolet SS", "stockcars2\\arcaford25|ARCA Ford Mustang", "stockcars2\\arcatoyota25|ARCA Toyota Camry",
            "stockcars2\\camaro2019|NASCAR O'Reilly Chevrolet Camaro", "stockcars2\\mustang2019|NASCAR O'Reilly Ford Mustang", "stockcars2\\supra2019|NASCAR O'Reilly Toyota Supra",
            "streetstock|Street Stock - Panther C1|Street Stock - Casino M2|Street Stock - Eagle T3", "streetstock\\streetstock2|Street Stock - Panther C1|Street Stock - Casino M2|Street Stock - Eagle T3",
            "streetstock\\streetstock3|Street Stock - Panther C1|Street Stock - Casino M2|Street Stock - Eagle T3", "subaruwrxsti|Subaru WRX STI",
            "supercars\\chevycamarogen3|Supercars Chevrolet Camaro Gen 3", "supercars\\fordmustanggen3|Supercars Ford Mustang Gen 3", "superformulalights324|Super Formula Lights",
            "superformulasf23|Super Formula SF23 - Honda|Super Formula SF23 - Toyota", "superformulasf23\\honda|Super Formula SF23 - Honda", "superformulasf23\\toyota|Super Formula SF23 - Toyota",
            "superlatemodel|Super Late Model", "toyotagr86|Toyota GR86", "trucks\\fordf150|NASCAR Truck Ford F150", "trucks\\silverado2019|NASCAR Truck Chevrolet Silverado",
            "trucks\\toyotatundra2022|NASCAR Truck Toyota Tundra TRD Pro", "trucks\\silverado|NASCAR Truck Chevrolet Silverado - 2008", "usf2000usf17|USF 2000", "vwbeetlegrc|VW Beetle",
            "vwbeetlegrc\\lite|VW Beetle - Lite", "williamsfw31|Williams-Toyota FW31" };
        static readonly string[] TrackTable = {
            "algarve|Algarve International Circuit|Autodromo Internacional do Algarve|Autódromo Internacional do Algarve", "barber|Barber Motorsports Park", "charlotte|Charlotte Motor Speedway", "concordhalf|Concord Speedway",
            "daytona|Daytona International Speedway", "lagunaseca|WeatherTech Raceway at Laguna Seca|Laguna Seca", "lakeland|Lakeland", "langley|Langley Speedway", "lanier|Lanier National Speedway",
            "ledenon|Circuit de Ledenon", "lemans|Circuit des 24 Heures du Mans", "limaland|Limaland Motorsports Park", "limerock|Lime Rock Park", "longbeach|Long Beach Street Circuit", "monza|Autodromo Nazionale Monza",
            "mtwashington|Mount Washington Hillclimb", "mugello|Autodromo Internazionale del Mugello", "navarra|Circuito de Navarra", "nurburgring|Nurburgring Combined|Nürburgring Combined|Nurburgring Grand-Prix-Strecke|Nürburgring Grand-Prix-Strecke|Nurburgring Nordschleife|Nürburgring Nordschleife",
            "okayama|Okayama International Circuit", "oran|Oran Park Raceway", "oschersleben|Motorsport Arena Oschersleben", "oulton|Oulton Park Circuit", "oxford|Oxford Plains Speedway", "phoenix|Phoenix Raceway",
            "pocono|Pocono Raceway", "roadamerica|Road America", "roadatlanta|Road Atlanta", "rudskogen|Rudskogen Motorsenter", "sebring|Sebring International Raceway", "silverstone|Silverstone Circuit",
            "skidpad|Centripetal Circuit", "snetterton|Snetterton Circuit", "sonoma|Sonoma Raceway", "southboston|South Boston Speedway", "southernnational|Southern National Motorsports Park",
            "spa|Circuit de Spa-Francorchamps", "summit|Summit Point Raceway", "thompson|Thompson Speedway Motorsports Park", "tsukuba|Tsukuba Circuit", "virginia|Virginia International Raceway",
            "wildwest|Wild West Motorsports Park", "winton|Winton Motor Raceway" };

        public sealed class OwnedMap
        {
            public List<string> CarFolders = new List<string>(), TrackFolders = new List<string>();
            public List<string> CarNames = new List<string>(), TrackNames = new List<string>();       // display names, one per known folder (aliases included)
            public List<string> UnknownCars = new List<string>(), UnknownTracks = new List<string>();  // installed folders we have no display name for
            public HashSet<string> CarKeys = new HashSet<string>(), TrackKeys = new HashSet<string>(); // Norm() of every name above
        }

        static Dictionary<string, string[]> Table(string[] t)
        {
            Dictionary<string, string[]> d = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
            foreach (string row in t) { string[] p = row.Split('|'); string[] names = new string[p.Length - 1]; Array.Copy(p, 1, names, 0, names.Length); d[p[0]] = names; }
            return d;
        }

        // carPaths: every car under iRacing\cars as a relative path ("stockcars\chevycamarozl12022"); trackFolders: iRacing\tracks.
        // learnedCars/learnedTracks: folder or path -> display name taken from Peter's own sessions; they win and add spellings.
        public static OwnedMap BuildOwned(IEnumerable<string> carPaths, IEnumerable<string> trackFolders, Dictionary<string, string> learnedCars, Dictionary<string, string> learnedTracks)
        {
            OwnedMap o = new OwnedMap();
            Dictionary<string, string[]> ct = Table(CarTable), tt = Table(TrackTable);
            foreach (string f in carPaths) AddOwned(f, ct, learnedCars, o.CarFolders, o.CarNames, o.UnknownCars, o.CarKeys);
            foreach (string f in trackFolders) AddOwned(f, tt, learnedTracks, o.TrackFolders, o.TrackNames, o.UnknownTracks, o.TrackKeys);
            return o;
        }

        static void AddOwned(string path, Dictionary<string, string[]> table, Dictionary<string, string> learned, List<string> folders, List<string> names, List<string> unknown, HashSet<string> keys)
        {
            string p = (path ?? "").Trim().Replace('/', '\\').Trim('\\');
            if (p.Length == 0) return;
            folders.Add(p);
            List<string> all = new List<string>(); string[] t; string l;
            if (learned != null)
            {
                if (learned.TryGetValue(p, out l) && l.Length > 0) all.Add(l);
                string leaf = p.Substring(p.LastIndexOf('\\') + 1);
                if (learned.TryGetValue(leaf, out l) && l.Length > 0) all.Add(l);
            }
            if (table.TryGetValue(p, out t)) all.AddRange(t);
            if (all.Count == 0) { unknown.Add(p); return; }
            foreach (string n in all) { names.Add(n); keys.Add(Norm(n)); }
        }

        // The schedule spells a car the way iRacing's UI does; every spelling is in the table, so only exact matches count
        // (a prefix match would let the old 991 GT3 R stand in for the 992).
        public static bool OwnsCar(OwnedMap o, string seriesCar) { return o.CarKeys.Contains(Norm(seriesCar)); }

        public static bool OwnsTrack(OwnedMap o, string scheduleTrack) { string k = Norm(scheduleTrack); return k.Length > 0 && o.TrackKeys.Contains(k); }
        // ------------------------------------------------------------------ licence
        static int LicRank(string c) { switch ((c ?? "").ToUpperInvariant()) { case "R": return 0; case "D": return 1; case "C": return 2; case "B": return 3; case "A": return 4; case "P": return 5; } return -1; }

        // "C 2.54" -> "C" ("" when unknown)
        public static string LicLetter(string licString)
        {
            Match m = Regex.Match(licString ?? "", @"^\s*(R|D|C|B|A|P|PRO|WC)\b", RegexOptions.IgnoreCase);
            if (!m.Success) return "";
            string c = m.Groups[1].Value.ToUpperInvariant();
            return c == "PRO" || c == "WC" ? "P" : c;
        }

        public static bool LicOk(string have, string need) { int h = LicRank(have), n = LicRank(need); return h < 0 || n < 0 || h >= n; }   // unknown licence = not filtered

        // oval and dirt licences are separate from the road one; the schedule's track names tell which this is
        public static string Category(OfSeries s, OfWeek w)
        {
            string t = (w == null ? "" : w.Track + " " + w.Layout);
            if (Regex.IsMatch(t, @"\bDirt\b", RegexOptions.IgnoreCase)) return "dirt";
            if (w != null && Regex.IsMatch(w.Layout, @"^Oval\b|\bOval$|Oval\b", RegexOptions.IgnoreCase)) return "oval";
            if (w != null && Regex.IsMatch(w.Track, @"(Speedway|Raceway)$") && w.Layout.Length == 0) return "oval";
            return "road";
        }

        // ------------------------------------------------------------------ the list
        public sealed class Query
        {
            public OwnedMap Owned; public string RoadLic = "", OvalLic = "", DirtLic = "";
            public HashSet<string> Favs = new HashSet<string>();    // OfSeries.Key
        }

        public sealed class Why { public int Total, NoCar, NoTrack, Licence, NoWeek, NoTimes; }

        // the week that holds `utc` for this series (null = the schedule has none)
        public static OfWeek WeekAt(OfSeries s, DateTime utc)
        {
            OfWeek best = null;
            foreach (OfWeek w in s.Weeks) if (w.Start <= utc && utc < w.Start.AddDays(7)) best = w;
            return best;
        }

        // Why can't Peter enter this week of this series?  null = he can.
        public static string Blocked(OfSeries s, OfWeek w, Query q)
        {
            if (w == null) return "week";
            if (OwnedCarsOf(s, w, q.Owned).Count == 0) return "car";
            if (!OwnsTrack(q.Owned, w.Track) && !(!s.CarsKnown && TrackStartsWithOwned(q.Owned, w.Track))) return "track";
            string cat = Category(s, w), have = cat == "oval" ? q.OvalLic : cat == "dirt" ? q.DirtLic : q.RoadLic;
            if (!LicOk(have, s.Lic)) return "licence";
            return null;
        }

        // The cars of this series that Peter owns. "See race week for cars in use": the week's own track cell names them
        // ("Nurburgring Nordschleife - Industriefahrten Ruf RT 12R Track"), so look for his cars in that text.
        public static List<string> OwnedCarsOf(OfSeries s, OfWeek w, OwnedMap o)
        {
            List<string> r = new List<string>();
            if (s.CarsKnown) { foreach (string c in s.Cars) if (OwnsCar(o, c)) r.Add(c); return r; }
            if (w == null) return r;
            string text = Norm(w.Track + " " + w.Layout);
            HashSet<string> seen = new HashSet<string>();
            foreach (string n in o.CarNames) { string k = Norm(n); if (k.Length >= 6 && text.Contains(k) && seen.Add(k)) r.Add(n); }
            return r;
        }

        static bool TrackStartsWithOwned(OwnedMap o, string track)
        {
            string k = Norm(track);
            foreach (string have in o.TrackKeys) if (have.Length >= 6 && k.StartsWith(have, StringComparison.Ordinal)) return true;
            return false;
        }

        // every start from `from` to `to` (UTC) of the series Peter can enter, soonest first; Why counts what was left out
        public static List<OfRace> Upcoming(List<OfSeries> all, Query q, DateTime from, DateTime to, Why why)
        {
            List<OfRace> r = new List<OfRace>();
            foreach (OfSeries s in all)
            {
                OfPattern p = ParsePattern(s.Freq);
                if (why != null) why.Total++;
                if (!p.Ok) { if (why != null) why.NoTimes++; continue; }
                // one week at a time: the track changes on Tuesday 00:00 UTC
                bool anyInWindow = false; string firstBlock = null;
                foreach (OfWeek w in s.Weeks)
                {
                    DateTime a = w.Start > from ? w.Start : from, b = w.Start.AddDays(7) < to ? w.Start.AddDays(7) : to;
                    if (a >= b) continue;
                    anyInWindow = true;
                    string blocked = Blocked(s, w, q);
                    if (blocked != null) { if (firstBlock == null) firstBlock = blocked; continue; }
                    // "every other Saturday": when the schedule dates each event on its own Saturday (not a Tuesday), those dates ARE the Saturdays - exact
                    bool est = p.Est && !(p.Alternate && w.Start.DayOfWeek != DayOfWeek.Tuesday);
                    foreach (DateTime t in Project(p, a, b)) { OfRace x = new OfRace(); x.Utc = t; x.Est = est; x.S = s; x.W = w; r.Add(x); }
                }
                if (why != null)
                {
                    if (!anyInWindow) why.NoWeek++;
                    else if (firstBlock == "car") why.NoCar++;
                    else if (firstBlock == "track") why.NoTrack++;
                    else if (firstBlock == "licence") why.Licence++;
                }
            }
            r.Sort(delegate (OfRace x, OfRace y)
            {
                int c = x.Utc.CompareTo(y.Utc);
                if (c != 0) return c;
                bool fx = q.Favs.Contains(x.S.Key), fy = q.Favs.Contains(y.S.Key);
                if (fx != fy) return fx ? -1 : 1;
                return string.Compare(x.S.Short, y.S.Short, StringComparison.OrdinalIgnoreCase);
            });
            return r;
        }

        // ------------------------------------------------------------------ short words for screens
        public static string TrackLine(OfWeek w) { return w.Layout.Length > 0 ? w.Track + " - " + w.Layout : w.Track; }

        // one or two words under the licence chip: "hourly", "every 2 h", "set times"
        public static string PatternTiny(OfPattern p)
        {
            if (!p.Ok) return "";
            if (p.Slots.Count > 0) return p.Alternate ? "set times*" : "set times";
            if (p.EveryHours == 1) return p.Minutes.Count >= 2 ? "every 30 min" : "hourly";
            return "every " + p.EveryHours + " h";
        }

        // "Races every 2 hours at :15 past" -> "every 2 h at :15"
        public static string PatternShort(OfPattern p)
        {
            if (!p.Ok) return "";
            if (p.Slots.Count > 0) return "set times" + (p.Alternate ? ", some weeks" : "");
            StringBuilder sb = new StringBuilder("every ");
            sb.Append(p.EveryHours == 1 ? "hour" : p.EveryHours + " h").Append(" at ");
            for (int i = 0; i < p.Minutes.Count; i++) sb.Append(i > 0 ? " & " : "").Append(':').Append(p.Minutes[i].ToString("00", CultureInfo.InvariantCulture));
            return sb.ToString();
        }

        // Display conversion only. Utc stays the published slot. Seconds never negative.
        public static int CountdownSeconds(DateTime startUtc, DateTime nowUtc, TimeZoneInfo tz)
        {
            if (tz == null) tz = TimeZoneInfo.Utc;
            DateTime startLocal = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(startUtc, DateTimeKind.Utc), tz);
            DateTime nowLocal = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(nowUtc, DateTimeKind.Utc), tz);
            double s = (startLocal - nowLocal).TotalSeconds;
            if (s <= 0) return 0;
            return (int)Math.Floor(s);
        }

        public static string LocalStart(DateTime startUtc, TimeZoneInfo tz)
        {
            if (tz == null) tz = TimeZoneInfo.Utc;
            DateTime local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(startUtc, DateTimeKind.Utc), tz);
            return local.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        }
    }
}

