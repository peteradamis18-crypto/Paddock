// Offline checks for official racing (tests\official-test.ps1 compiles this with dash\src\officialcore.cs and dash\src\official.cs).
//   official-unit unit                 the pure parts: PDF reading, patterns, ownership, eligibility
//   official-unit glue <root>          irdash's side against a pretend root folder (made by the test script)
//   official-unit json <root> <now>    print /official as of that time (the real files, for the picture and the invariants)
// Prints "  ok    ..." / "  FAIL  ..." lines and "RESULT pass fail".
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using IRDash;

namespace IRDash
{
    // the few irdash types official.cs leans on
    static class Log { public static void W(string m) { Console.WriteLine("        [log] " + m); } }
    static class Json_ { public static string S(string s) { s = s ?? ""; StringBuilder sb = new StringBuilder("\""); foreach (char c in s) { if (c == '"') sb.Append("\\\""); else if (c == '\\') sb.Append("\\\\"); else if (c < 32) sb.Append(' '); else sb.Append(c); } return sb.Append('"').ToString(); } }
    class Frame { public bool Connected; }
    static class Sdk { public static bool FakeConnected; public static string FakeBusy; public static Frame Latest { get { Frame f = new Frame(); f.Connected = FakeConnected; return f; } } public static string RealBusy() { return FakeBusy; } }
    static class Program { public static bool Driving; public static bool IsDriving { get { return Driving; } } }
    static class Watch { public static string IrdeckPath; }
}

static class T
{
    static int pass, fail;
    static void Check(string what, bool ok) { if (ok) { pass++; Console.WriteLine("  ok    " + what); } else { fail++; Console.WriteLine("  FAIL  " + what); } }
    static DateTime U(string s) { return DateTime.ParseExact(s, "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal); }
    static string Times(List<DateTime> l) { return string.Join(" ", l.Select(delegate (DateTime d) { return d.ToString("ddd HH:mm", CultureInfo.InvariantCulture); }).ToArray()); }

    static int Main(string[] a)
    {
        string mode = a.Length > 0 ? a[0] : "unit";
        if (mode == "unit") Unit();
        else if (mode == "glue") Glue(a[1]);
        else if (mode == "source") Source(a[1], a.Length > 2 ? a[2] : a[1]);
        else if (mode == "json")
        {
            Official.Init(Path.Combine(a[1], @"data\official"));
            Console.WriteLine(Official.Json(a.Length > 2 ? a[2] : null));
            return 0;
        }
        Console.WriteLine("RESULT " + pass + " " + fail);
        return fail == 0 ? 0 : 1;
    }

    // ---------------------------------------------------------------- a small PDF in the same shape iRacing's is (iText, Flate, Tm + Tj)
    public static byte[] MakePdf(List<List<string[]>> pages)    // page = list of { x, y, text }
    {
        MemoryStream ms = new MemoryStream(); Encoding L = Encoding.GetEncoding(28591);
        Action<string> w = delegate (string s) { byte[] b = L.GetBytes(s); ms.Write(b, 0, b.Length); };
        w("%PDF-1.4\n"); int obj = 1;
        for (int p = 0; p < pages.Count; p++)
        {
            StringBuilder c = new StringBuilder();
            foreach (string[] it in pages[p]) c.Append("BT\n1 0 0 1 " + it[0] + " " + it[1] + " Tm\n/F1 9 Tf\n(" + it[2].Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)") + ")Tj\nET\n");
            byte[] raw = L.GetBytes(c.ToString()); MemoryStream z = new MemoryStream(); z.WriteByte(0x78); z.WriteByte(0x9C);
            using (DeflateStream d = new DeflateStream(z, CompressionMode.Compress, true)) d.Write(raw, 0, raw.Length);
            z.WriteByte(0); z.WriteByte(0); z.WriteByte(0); z.WriteByte(0);
            w(obj + " 0 obj\n<</Type/Page/MediaBox[0 0 612 792]/Resources<</Font<</F1 99 0 R>>>>/Contents " + (obj + 1) + " 0 R>>\nendobj\n");
            w((obj + 1) + " 0 obj\n<</Length " + z.Length + "/Filter/FlateDecode>>stream\r\n"); byte[] zb = z.ToArray(); ms.Write(zb, 0, zb.Length); w("\r\nendstream\nendobj\n");
            obj += 2;
        }
        w("trailer\n<<>>\n%%EOF\n");
        return ms.ToArray();
    }

    static string[] I(int x, int y, string t) { return new string[] { x.ToString(), y.ToString(), t }; }

    // one series block: title, cars, licence, pattern, then the week rows (date, track - layout, length)
    static void Series(List<string[]> pg, ref int y, string title, string[] carLines, string lic, string freq, string[][] weeks)
    {
        pg.Add(I(58, y, title)); y -= 14;
        foreach (string cl in carLines) { pg.Add(I(58, y, cl)); y -= 14; }
        pg.Add(I(58, y, lic)); y -= 14;
        pg.Add(I(58, y, freq)); y -= 12;
        pg.Add(I(58, y, "Min entries for official: 6 | Split at: 20 | Drops: 4")); y -= 12;
        pg.Add(I(58, y, "Penalty every 17 incidents. DQ at 25 incidents.")); y -= 20;
        foreach (string[] wk in weeks)
        {
            pg.Add(I(58, y, "Week " + wk[0] + " (" + wk[1] + ")")); pg.Add(I(158, y, wk[2])); pg.Add(I(358, y, "70F/21C, Rain chance None, Rolling")); pg.Add(I(518, y, wk[3])); y -= 9;
            pg.Add(I(158, y, "(2026-10-10 11:30 1x)")); pg.Add(I(358, y, "start, Local enforced cautions.")); y -= 24;
        }
        y -= 10;
    }

    public static byte[] FixturePdf()
    {
        List<string[]> pg = new List<string[]>(); int y = 740;
        pg.Add(I(302, 18, "1"));
        string[][] wk = new string[][] { new string[] { "1", "2026-10-06", "Silverstone Circuit - Grand Prix", "20 mins" }, new string[] { "2", "2026-10-13", "Circuit Zandvoort - Grand Prix", "20 mins" } };
        Series(pg, ref y, "Alpha GT3 Challenge by Foo - 2026 Season 4", new string[] { "BMW M4 GT3 EVO, Porsche 911 GT3 R (992), Ferrari", "296 GT3, Lamborghini Huracán GT3 EVO" }, "Class C (4.0) --> Pro/WC (4.0)", "Races every 2 hours at :15 past", wk);
        Series(pg, ref y, "Bravo Rookie Cup - 2026 Season 4", new string[] { "Mini Stock" }, "Rookie (1.0) --> Pro/WC (4.0)", "Races hourly at :45", new string[][] { new string[] { "1", "2026-10-06", "Silverstone Circuit - Grand Prix", "12 laps" }, new string[] { "2", "2026-10-13", "Road Atlanta - Full Course", "12 laps" } });
        List<string[]> pg2 = new List<string[]>(); y = 740;
        pg2.Add(I(302, 18, "2"));
        Series(pg2, ref y, "Charlie Endurance - 2026 Season 4", new string[] { "BMW M4 GT3 EVO" }, "Class B (4.0) --> Pro/WC (4.0)", "Races Saturday at 7 & 17:00 GMT & Sunday at 0 GMT", new string[][] { new string[] { "1", "2026-10-06", "Road Atlanta - Full Course", "240 mins" } });
        Series(pg2, ref y, "Delta Draft - 2026 Season 4", new string[] { "See race week for cars in use that week." }, "Rookie (4.0) --> Pro/WC (4.0)", "Races every hour on the hour", new string[][] { new string[] { "1", "2026-10-06", "Silverstone Circuit - Ruf RT 12R Track", "20 mins" } });
        Series(pg2, ref y, "Echo Mini Cup - 2026 Season 4", new string[] { "Mini Stock" }, "Rookie (1.0) --> Pro/WC (4.0)", "Races hourly at :45", new string[][] { new string[] { "1", "2026-10-06", "Silverstone Circuit - Grand Prix", "12 laps" } });
        Series(pg2, ref y, "Foxtrot Slots - 2026 Season 4", new string[] { "Mini Stock" }, "Rookie (1.0) --> Pro/WC (4.0)", "5 Timeslots Per Week", new string[][] { new string[] { "1", "2026-10-06", "Silverstone Circuit - Grand Prix", "12 laps" } });
        return MakePdf(new List<List<string[]>> { pg, pg2 });
    }

    public static readonly string[][] S4Expect = new string[][] {
        new string[] { "GT3 Challenge Fixed by Fanatec", "BMW M4 GT3 EVO", "Silverstone Circuit", "Races every 2 hours at :15 past" },
        new string[] { "Production Car Challenge by Sim-Lab", "Mini Stock", "Road Atlanta", "Races hourly at :45" },
        new string[] { "IMSA iRacing Series", "Ferrari 296 GT3", "Circuit de Spa-Francorchamps", "Races Saturday at 17:00 GMT" },
        new string[] { "Porsche Cup", "Porsche 911 GT3 R (992)", "Silverstone Circuit", "Races every 2 hours on the hour" },
        new string[] { "Ferrari Challenge", "Ferrari 296 GT3", "Road Atlanta", "Races hourly at :30" },
        new string[] { "Global Mazda Cup", "Global Mazda MX-5 Cup", "Silverstone Circuit", "Races every 30 minutes" },
        new string[] { "Formula Vee", "Formula Vee - Classic", "Road Atlanta", "Races hourly at :15" },
        new string[] { "TCR Challenge", "Audi RS3 LMS Gen2 TCR", "Silverstone Circuit", "Races every 2 hours at :45 past" },
        new string[] { "Skip Barber", "Skip Barber Formula 2000", "Road Atlanta", "Races Thursday at 18 GMT" },
        new string[] { "Spec Racer Ford", "SCCA Spec Racer Ford", "Silverstone Circuit", "Races every hour on the hour" }
    };

    static string[][] OneWeek(string track) { return new string[][] { new string[] { "1", "2026-10-06", track, "20 mins" } }; }

    public static byte[] S4FixturePdf()
    {
        List<string[]> p1 = new List<string[]>(); int y = 740; p1.Add(I(302, 18, "1"));
        Series(p1, ref y, "GT3 Challenge Fixed by Fanatec - 2026 Season 4", new string[] { "BMW M4 GT3 EVO" }, "Class C (4.0) --> Pro/WC (4.0)", "Races every 2 hours at :15 past", OneWeek("Silverstone Circuit - Grand Prix"));
        Series(p1, ref y, "Production Car Challenge by Sim-Lab - 2026 Season 4", new string[] { "Mini Stock" }, "Rookie (1.0) --> Pro/WC (4.0)", "Races hourly at :45", OneWeek("Road Atlanta - Full Course"));
        Series(p1, ref y, "IMSA iRacing Series - 2026 Season 4", new string[] { "Ferrari 296 GT3" }, "Class B (4.0) --> Pro/WC (4.0)", "Races Saturday at 17:00 GMT", OneWeek("Circuit de Spa-Francorchamps - Grand Prix Pits"));
        Series(p1, ref y, "Porsche Cup - 2026 Season 4", new string[] { "Porsche 911 GT3 R (992)" }, "Class C (4.0) --> Pro/WC (4.0)", "Races every 2 hours on the hour", OneWeek("Silverstone Circuit - Grand Prix"));
        List<string[]> p2 = new List<string[]>(); y = 740; p2.Add(I(302, 18, "2"));
        Series(p2, ref y, "Ferrari Challenge - 2026 Season 4", new string[] { "Ferrari 296 GT3" }, "Class C (4.0) --> Pro/WC (4.0)", "Races hourly at :30", OneWeek("Road Atlanta - Full Course"));
        Series(p2, ref y, "Global Mazda Cup - 2026 Season 4", new string[] { "Global Mazda MX-5 Cup" }, "Rookie (1.0) --> Pro/WC (4.0)", "Races every 30 minutes", OneWeek("Silverstone Circuit - Grand Prix"));
        Series(p2, ref y, "Formula Vee - 2026 Season 4", new string[] { "Formula Vee - Classic" }, "Rookie (1.0) --> Pro/WC (4.0)", "Races hourly at :15", OneWeek("Road Atlanta - Full Course"));
        Series(p2, ref y, "TCR Challenge - 2026 Season 4", new string[] { "Audi RS3 LMS Gen2 TCR" }, "Class D (4.0) --> Pro/WC (4.0)", "Races every 2 hours at :45 past", OneWeek("Silverstone Circuit - Grand Prix"));
        List<string[]> p3 = new List<string[]>(); y = 740; p3.Add(I(302, 18, "3"));
        Series(p3, ref y, "Skip Barber - 2026 Season 4", new string[] { "Skip Barber Formula 2000" }, "Rookie (1.0) --> Pro/WC (4.0)", "Races Thursday at 18 GMT", OneWeek("Road Atlanta - Full Course"));
        Series(p3, ref y, "Spec Racer Ford - 2026 Season 4", new string[] { "SCCA Spec Racer Ford" }, "Rookie (1.0) --> Pro/WC (4.0)", "Races every hour on the hour", OneWeek("Silverstone Circuit - Grand Prix"));
        return MakePdf(new List<List<string[]>> { p1, p2, p3 });
    }

    public static string S4HtmlTable()
    {
        StringBuilder sb = new StringBuilder("<html><body><table>");
        foreach (string[] e in S4Expect)
        {
            sb.Append("<tr><td>").Append(e[0]).Append(" - 2026 Season 4</td><td>").Append(e[1]).Append("</td><td>Class C (4.0)</td><td>").Append(e[3]).Append("</td></tr>");
            sb.Append("<tr><td>Week 1 (2026-10-06)</td><td>").Append(e[2]).Append(" - Grand Prix</td><td>70F</td><td>20 mins</td></tr>");
        }
        return sb.Append("</table></body></html>").ToString();
    }

    public static string Absent2027Html()
    {
        return "<html><head><title>iRacing 2027 Season 1</title></head><body><p>The 2027 Season 1 schedule has not been published.</p></body></html>";
    }

    // ---------------------------------------------------------------- the pure parts
    static void Unit()
    {
        Console.WriteLine("1. reading a schedule PDF");
        List<OfSeries> ser = OfficialCore.ParseSeason(PdfText.Extract(FixturePdf()));
        Check("six series found in the pretend PDF (found " + ser.Count + ")", ser.Count == 6);
        OfSeries al = ser.Count > 0 ? ser[0] : new OfSeries();
        Check("series name, short name without the season, and licence class", al.Name == "Alpha GT3 Challenge by Foo - 2026 Season 4" && al.Short == "Alpha GT3 Challenge by Foo" && al.Lic == "C");
        Check("cars wrapped over two lines are put back together, accents kept (4 cars: " + string.Join(" / ", al.Cars.ToArray()) + ")", al.Cars.Count == 4 && al.Cars[2] == "Ferrari 296 GT3" && al.Cars[3].StartsWith("Lamborghini Hurac"));
        Check("the repeat pattern text is kept", al.Freq == "Races every 2 hours at :15 past");
        Check("two weeks, each with a track, a layout and a length", al.Weeks.Count == 2 && al.Weeks[0].Track == "Silverstone Circuit" && al.Weeks[0].Layout == "Grand Prix" && al.Weeks[1].Track == "Circuit Zandvoort" && al.Weeks[0].Length == "20 mins");
        Check("a week starts on its Tuesday at midnight UTC", al.Weeks[0].Start == U("2026-10-06 00:00") && al.Weeks[0].Start.DayOfWeek == DayOfWeek.Tuesday);
        Check("licence letters: Rookie = R, Class B = B", ser[1].Lic == "R" && ser[2].Lic == "B");
        Check("'See race week for cars' means no car list", ser[3].Cars.Count == 0 && !ser[3].CarsKnown);
        Check("every series has a stable id (o + 8 hex) and they differ", ser.All(delegate (OfSeries s) { return System.Text.RegularExpressions.Regex.IsMatch(s.Id, "^o[0-9a-f]{8}$"); }) && ser.Select(delegate (OfSeries s) { return s.Id; }).Distinct().Count() == ser.Count);
        Check("short names drop the season and the doubled words (as in the real PDF)",
            OfficialCore.ShortName("NASCAR Class A Series - Fixed - 2026 Season 4 Fixed") == "NASCAR Class A Series - Fixed" && OfficialCore.ShortName("GT3 Challenge Fixed by Fanatec - 2026 Season 4") == "GT3 Challenge Fixed by Fanatec"
            && OfficialCore.ShortName("NASCAR iRacing Class B Series Series - 2026 Season") == "NASCAR iRacing Class B Series");
        Check("garbage is not a schedule (no series, no crash)", OfficialCore.ParseSeason(PdfText.Extract(new byte[] { 1, 2, 3, 4, 5 })).Count == 0);

        Console.WriteLine("2. repeat patterns -> start times (UTC)");
        Func<string, string, string, string> proj = delegate (string text, string from, string to) { return Times(OfficialCore.Project(OfficialCore.ParsePattern(text), U(from), U(to))); };
        Check("every 2 hours at :15 past = even UTC hours, and it is marked est (parity is not stated)", proj("Races every 2 hours at :15 past", "2026-10-10 00:00", "2026-10-10 06:00") == "Sat 00:15 Sat 02:15 Sat 04:15" && OfficialCore.ParsePattern("Races every 2 hours at :15 past").Est);
        Check("every 2 hours on the hour", proj("Races every 2 hours on the hour", "2026-10-10 00:00", "2026-10-10 06:00") == "Sat 00:00 Sat 02:00 Sat 04:00");
        Check("'every odd 2 hours' is odd hours and NOT est", proj("Races every odd 2 hours on the hour", "2026-10-10 00:00", "2026-10-10 06:00") == "Sat 01:00 Sat 03:00 Sat 05:00" && !OfficialCore.ParsePattern("Races every odd 2 hours on the hour").Est);
        Check("'every even 2 hours at :30 past'", proj("Races every even 2 hours at :30 past", "2026-10-10 00:00", "2026-10-10 06:00") == "Sat 00:30 Sat 02:30 Sat 04:30");
        Check("hourly at :45 past is exact (not est)", proj("Races hourly at :45 past", "2026-10-10 00:00", "2026-10-10 03:00") == "Sat 00:45 Sat 01:45 Sat 02:45" && !OfficialCore.ParsePattern("Races hourly at :45 past").Est);
        Check("every 30 minutes", proj("Races every 30 minutes", "2026-10-10 00:00", "2026-10-10 02:00") == "Sat 00:00 Sat 00:30 Sat 01:00 Sat 01:30");
        Check("every 30 minutes at :15 & :45", proj("Races every 30 minutes at :15 & :45", "2026-10-10 00:00", "2026-10-10 02:00") == "Sat 00:15 Sat 00:45 Sat 01:15 Sat 01:45");
        Check("'15 past every 2 hours' and '45 past every 2 hours'", proj("Races at 15 past every 2 hours", "2026-10-10 00:00", "2026-10-10 05:00") == "Sat 00:15 Sat 02:15 Sat 04:15" && proj("Races 45 past every 2 hours", "2026-10-10 00:00", "2026-10-10 05:00") == "Sat 00:45 Sat 02:45 Sat 04:45");
        Check("'Every hour on the :30' and 'every hour at half past'", proj("Every hour on the :30", "2026-10-10 00:00", "2026-10-10 02:00") == "Sat 00:30 Sat 01:30" && proj("Races every hour at half past", "2026-10-10 00:00", "2026-10-10 02:00") == "Sat 00:30 Sat 01:30");
        Check("'at :15 and :45' (every hour)", proj("Races at :15 and :45", "2026-10-10 00:00", "2026-10-10 02:00") == "Sat 00:15 Sat 00:45 Sat 01:15 Sat 01:45");
        Check("a window starting mid-hour only returns later starts", proj("Races hourly at :45", "2026-10-10 05:46", "2026-10-10 07:00") == "Sat 06:45");
        Check("fixed days: Thursday 10 & 18 GMT and Friday 00 & 3 GMT", proj("Races Thursday at 10 & 18 GMT and Friday at 00 & 3 GMT", "2026-10-08 00:00", "2026-10-10 00:00") == "Thu 10:00 Thu 18:00 Fri 00:00 Fri 03:00");
        Check("fixed days: 'Thur & Sat at 10, 19 GMT & Fri & Sun at 1,4 GMT'", proj("Races Thur & Sat at 10, 19 GMT & Fri & Sun at 1,4 GMT", "2026-10-08 00:00", "2026-10-12 00:00") == "Thu 10:00 Thu 19:00 Fri 01:00 Fri 04:00 Sat 10:00 Sat 19:00 Sun 01:00 Sun 04:00");
        Check("fixed days: 'Weds 2 GMT, Sat 8 GMT, Sun 19 GMT, & Mon at 18 GMT'", proj("Races Weds 2 GMT, Sat 8 GMT, Sun 19 GMT, & Mon at 18 GMT", "2026-10-07 00:00", "2026-10-13 00:00") == "Wed 02:00 Sat 08:00 Sun 19:00 Mon 18:00");
        Check("fixed days with 17:00 written out", proj("Races on Saturday at 7 & 17:00 GMT & Sunday at 0 & 13 GMT", "2026-10-10 00:00", "2026-10-12 00:00") == "Sat 07:00 Sat 17:00 Sun 00:00 Sun 13:00");
        OfPattern alt = OfficialCore.ParsePattern("Races every other Saturday at 4 & 15 GMT and Sunday at 0 GMT, 20 GMT");
        Check("'every other Saturday' is est, and 'Sunday at 0 GMT, 20 GMT' keeps both hours", alt.Ok && alt.Est && Times(OfficialCore.Project(alt, U("2026-10-10 00:00"), U("2026-10-12 00:00"))) == "Sat 04:00 Sat 15:00 Sun 00:00 Sun 20:00");
        Check("an event week dated on its own Saturday is exact even for \"every other Saturday\"; a Tuesday week stays est", EstOf("Races every other Saturday at 4 & 15 GMT", "2026-10-10") == false && EstOf("Races every other Saturday at 4 & 15 GMT", "2026-10-06") == true);
        Check("'5 Timeslots Per Week' and empty text cannot be projected (not guessed)", !OfficialCore.ParsePattern("5 Timeslots Per Week").Ok && !OfficialCore.ParsePattern("").Ok);
        Check("a qualifying clause after | is ignored", proj("Races on every hour on the hour | Qualifying every hour at :30", "2026-10-10 00:00", "2026-10-10 02:00") == "Sat 00:00 Sat 01:00");

        Console.WriteLine("3. what Peter owns, from folder lists");
        OfficialCore.OwnedMap o = OfficialCore.BuildOwned(new string[] { "bmwm4gt3", "porsche992rgt3", "ministock", "lamborghinievogt3", "stockcars\\chevycamarozl12022", "mystery\\car" }, new string[] { "silverstone", "roadatlanta", "lemans", "nonesuch" }, null, null);
        Check("a car folder gives its iRacing names (BMW M4 GT3 EVO, Porsche 911 GT3 R (992))", OfficialCore.OwnsCar(o, "BMW M4 GT3 EVO") && OfficialCore.OwnsCar(o, "Porsche 911 GT3 R (992)"));
        Check("spelling differences do not matter (accent, case, spaces)", OfficialCore.OwnsCar(o, "Lamborghini Huracán GT3 EVO") && OfficialCore.OwnsCar(o, "lamborghini huracan gt3 evo"));
        Check("a sub-folder car is its own car (Next Gen Camaro yes, Next Gen Mustang no)", OfficialCore.OwnsCar(o, "NASCAR Cup Series Next Gen Chevrolet Camaro ZL1") && !OfficialCore.OwnsCar(o, "NASCAR Cup Series Next Gen Ford Mustang"));
        Check("cars he does not have are not owned", !OfficialCore.OwnsCar(o, "Ferrari 296 GT3") && !OfficialCore.OwnsCar(o, "McLaren 720S GT3 EVO"));
        Check("tracks: Silverstone yes, Zandvoort no, Le Mans by its long name", OfficialCore.OwnsTrack(o, "Silverstone Circuit") && !OfficialCore.OwnsTrack(o, "Circuit Zandvoort") && OfficialCore.OwnsTrack(o, "Circuit des 24 Heures du Mans"));
        Check("folders we cannot name are listed, not guessed (mystery\\car, nonesuch)", o.UnknownCars.Contains("mystery\\car") && o.UnknownTracks.Contains("nonesuch") && o.UnknownCars.Count == 1);
        OfficialCore.OwnedMap old = OfficialCore.BuildOwned(new string[] { "porsche911rgt3" }, new string[0], null, null);
        Check("the old 991 GT3 R does not stand in for the 992 (no prefix guessing)", OfficialCore.OwnsCar(old, "Porsche 911 GT3 R") && !OfficialCore.OwnsCar(old, "Porsche 911 GT3 R (992)"));
        Dictionary<string, string> learned = new Dictionary<string, string>(); learned["mystery"] = "Mystery Racer 9000";
        OfficialCore.OwnedMap lo = OfficialCore.BuildOwned(new string[] { "mystery" }, new string[0], learned, null);
        Check("a name iRacing gave the car in his own session is used for an unknown folder", OfficialCore.OwnsCar(lo, "Mystery Racer 9000") && lo.UnknownCars.Count == 0);

        Console.WriteLine("4. which races he can enter");
        OfficialCore.OwnedMap own = OfficialCore.BuildOwned(new string[] { "bmwm4gt3", "ministock", "rufrt12r" }, new string[] { "silverstone", "roadatlanta" }, null, null);
        OfficialCore.Query q = new OfficialCore.Query(); q.Owned = own; q.RoadLic = "C"; q.OvalLic = "R"; q.DirtLic = "R";
        OfficialCore.Why why = new OfficialCore.Why();
        List<OfRace> r = OfficialCore.Upcoming(ser, q, U("2026-10-10 00:00"), U("2026-10-11 00:00"), why);
        Func<string, List<OfRace>> of = delegate (string key) { return r.Where(delegate (OfRace x) { return x.S.Short.StartsWith(key); }).ToList(); };
        Check("Alpha (owns BMW M4 GT3 EVO, Silverstone this week, licence C ok): 12 starts, all est", of("Alpha").Count == 12 && of("Alpha").All(delegate (OfRace x) { return x.Est; }) && of("Alpha")[0].Utc == U("2026-10-10 00:15"));
        Check("Bravo: 24 starts at :45, not est", of("Bravo").Count == 24 && of("Bravo").All(delegate (OfRace x) { return !x.Est && x.Utc.Minute == 45; }));
        Check("Charlie is Class B and his road licence is C: left out", of("Charlie").Count == 0 && why.Licence >= 1);
        q.RoadLic = "B"; List<OfRace> rb = OfficialCore.Upcoming(ser, q, U("2026-10-10 00:00"), U("2026-10-11 00:00"), null);
        Check("with a B licence Charlie shows: Saturday 07:00 and 17:00", rb.Where(delegate (OfRace x) { return x.S.Short.StartsWith("Charlie"); }).Select(delegate (OfRace x) { return x.Utc.ToString("HH:mm"); }).SequenceEqual(new string[] { "07:00", "17:00" }));
        q.RoadLic = "C";
        Check("Delta (no car list: his Ruf RT 12R is named in the week's track cell): 24 starts", of("Delta").Count == 24 && OfficialCore.OwnedCarsOf(of("Delta")[0].S, of("Delta")[0].W, own)[0] == "Ruf RT 12R");
        Check("Foxtrot has no usable times: not listed, and counted as such", of("Foxtrot").Count == 0 && why.NoTimes == 1);
        List<OfRace> wk2 = OfficialCore.Upcoming(ser, q, U("2026-10-12 12:00"), U("2026-10-14 12:00"), null);
        Check("the track changes on Tuesday 00:00 UTC: Alpha runs at Silverstone until Mon 24:00, then Zandvoort (not owned) = nothing", wk2.Where(delegate (OfRace x) { return x.S.Short.StartsWith("Alpha"); }).All(delegate (OfRace x) { return x.Utc < U("2026-10-13 00:00"); }) && wk2.Count(delegate (OfRace x) { return x.S.Short.StartsWith("Alpha"); }) == 6);
        Check("Bravo moves to Road Atlanta (owned) on Tuesday", wk2.Any(delegate (OfRace x) { return x.S.Short.StartsWith("Bravo") && x.Utc >= U("2026-10-13 00:00") && x.W.Track == "Road Atlanta"; }));
        q.Favs.Add(ser[5].Key);   // Foxtrot is not listed; favour Echo instead
        q.Favs.Clear(); q.Favs.Add(ser.First(delegate (OfSeries s) { return s.Short.StartsWith("Echo"); }).Key);
        List<OfRace> rf = OfficialCore.Upcoming(ser, q, U("2026-10-10 00:00"), U("2026-10-10 01:00"), null);
        int ie = rf.FindIndex(delegate (OfRace x) { return x.S.Short.StartsWith("Echo"); }), ib = rf.FindIndex(delegate (OfRace x) { return x.S.Short.StartsWith("Bravo"); });
        Check("same start time: the favourite comes first (Echo before Bravo at 00:45)", ie >= 0 && ib >= 0 && ie < ib && rf[ie].Utc == rf[ib].Utc);
        Check("the list is in time order", r.Zip(r.Skip(1), delegate (OfRace x, OfRace y) { return x.Utc <= y.Utc; }).All(delegate (bool b) { return b; }));
        Check("licence: C 2.54 -> C; Rookie / unknown pass; a lower class does not", OfficialCore.LicLetter("C 2.54") == "C" && OfficialCore.LicOk("C", "C") && !OfficialCore.LicOk("C", "B") && OfficialCore.LicOk("", "A") && OfficialCore.LicOk("R", "R") && !OfficialCore.LicOk("R", "D"));
        Check("oval and dirt are told apart from road by the track name", OfficialCore.Category(ser[0], new OfWeek { Track = "Charlotte Motor Speedway", Layout = "Oval" }) == "oval" && OfficialCore.Category(ser[0], new OfWeek { Track = "Lanier National Speedway", Layout = "Dirt" }) == "dirt" && OfficialCore.Category(ser[0], ser[0].Weeks[0]) == "road");

        Console.WriteLine("series eligibility");
        DateTime nowH = U("2026-10-10 12:00");
        List<OfficialCore.SessionHint> sess = new List<OfficialCore.SessionHint>();
        OfficialCore.SessionHint recent = new OfficialCore.SessionHint(); recent.When = U("2026-09-20 12:00"); recent.Series = "Alpha GT3 Challenge by Foo - 2026 Season 4"; sess.Add(recent);
        OfficialCore.SessionHint oldSess = new OfficialCore.SessionHint(); oldSess.When = U("2026-06-01 12:00"); oldSess.Series = "Bravo Rookie Cup - 2026 Season 4"; sess.Add(oldSess);
        HashSet<string> k1 = OfficialCore.HisSeriesKeys(null, sess, nowH);
        Check("recent included", k1.Contains(OfficialCore.Norm("Alpha GT3 Challenge by Foo")));
        Check("older excluded", !k1.Contains(OfficialCore.Norm("Bravo Rookie Cup")));
        HashSet<string> k2 = OfficialCore.HisSeriesKeys(new string[] { "Echo Mini Cup" }, sess, nowH);
        Check("favourite included", k2.Contains(OfficialCore.Norm("Echo Mini Cup")));

        Console.WriteLine("ownership");
        OfficialCore.OwnedMap ow = OfficialCore.BuildOwned(new string[] { "bmwm4gt3" }, new string[] { "silverstone" }, null, null);
        Check("installed car", OfficialCore.OwnsCar(ow, "BMW M4 GT3 EVO"));
        Check("installed track", OfficialCore.OwnsTrack(ow, "Silverstone Circuit"));
        Check("non-installed item rejected", !OfficialCore.OwnsCar(ow, "Ferrari 296 GT3") && !OfficialCore.OwnsTrack(ow, "Circuit Zandvoort"));

        Console.WriteLine("next race");
        TimeZoneInfo gmt = TimeZoneInfo.FindSystemTimeZoneById("GMT Standard Time");
        OfPattern cad = OfficialCore.ParsePattern("Races every 2 hours at :15 past");
        List<DateTime> slots = OfficialCore.Project(cad, U("2026-10-10 00:00"), U("2026-10-10 06:00"));
        Check("UTC cadence projection", slots.Count == 3 && slots[0] == U("2026-10-10 00:15") && slots[2] == U("2026-10-10 04:15"));
        DateTime springUtc = new DateTime(2026, 3, 29, 1, 30, 0, DateTimeKind.Utc);
        DateTime springLocal = TimeZoneInfo.ConvertTimeFromUtc(springUtc, gmt);
        Check("DST spring", springLocal.Hour == 2 && OfficialCore.LocalStart(springUtc, gmt) == springLocal.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture));
        DateTime autumnUtc = new DateTime(2026, 10, 25, 1, 30, 0, DateTimeKind.Utc);
        DateTime autumnLocal = TimeZoneInfo.ConvertTimeFromUtc(autumnUtc, gmt);
        Check("DST autumn", OfficialCore.LocalStart(autumnUtc, gmt) == autumnLocal.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture));
        Check("local date/time", OfficialCore.LocalStart(U("2026-10-10 16:00"), gmt) == TimeZoneInfo.ConvertTimeFromUtc(U("2026-10-10 16:00"), gmt).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture));
        Check("seconds never negative", OfficialCore.CountdownSeconds(U("2026-10-10 12:00"), U("2026-10-10 13:00"), gmt) == 0);
        OfPattern none = OfficialCore.ParsePattern("5 Timeslots Per Week");
        Check("unknown cadence gives no race", !none.Ok && OfficialCore.Project(none, U("2026-10-10 00:00"), U("2026-10-11 00:00")).Count == 0);
    }

    static bool EstOf(string freq, string weekStart)
    {
        OfSeries s = new OfSeries(); s.Id = "o00000001"; s.Short = "X"; s.Key = "x"; s.Freq = freq; s.Lic = "R"; s.Cars.Add("Mini Stock");
        OfWeek w = new OfWeek(); w.N = 1; w.Start = U(weekStart + " 00:00"); w.Track = "Silverstone Circuit"; s.Weeks.Add(w);
        OfficialCore.Query q = new OfficialCore.Query(); q.Owned = OfficialCore.BuildOwned(new string[] { "ministock" }, new string[] { "silverstone" }, null, null);
        List<OfRace> r = OfficialCore.Upcoming(new List<OfSeries> { s }, q, w.Start, w.Start.AddDays(7), null);
        return r.Count > 0 && r[0].Est;
    }

    // ---------------------------------------------------------------- irdash's side
    static Dictionary<string, object> Obj(object o) { return o as Dictionary<string, object>; }
    static object[] Arr(object o) { ArrayList l = o as ArrayList; if (l != null) return l.ToArray(); return o as object[]; }
    static string S(object o) { return Convert.ToString(o, CultureInfo.InvariantCulture); }
    static Dictionary<string, object> Parse(string json) { JavaScriptSerializer js = new JavaScriptSerializer(); js.MaxJsonLength = int.MaxValue; return js.DeserializeObject(json) as Dictionary<string, object>; }

    static void Glue(string root)
    {
        string dir = Path.Combine(root, @"data\official");
        Official.Init(dir);
        Console.WriteLine("5. irdash: nothing loaded yet");
        Dictionary<string, object> j = Parse(Official.Json("2026-10-10T16:00:00Z"));
        Check("before any schedule is loaded the answer says so and has no days", S(j["ready"]) == "True" && S(j["loaded"]) == "False" && S(j["msg"]).Length > 5);

        Console.WriteLine("6. importing the schedule");
        Official.MinSeries = 3;
        string pdf = Path.Combine(dir, "fixture.pdf"); File.WriteAllBytes(pdf, FixturePdf());
        string m1 = Official.ImportPath(pdf, "fixture");
        Check("the pretend PDF is read (6 series)" + (m1 == null ? "" : " - " + m1), m1 == null && File.Exists(Path.Combine(dir, "season.json")));
        string junk = Path.Combine(dir, "junk.pdf"); File.WriteAllBytes(junk, Encoding.ASCII.GetBytes("%PDF-1.4 " + new string('x', 3000)));
        string why = Official.ImportPath(junk, "junk");
        Check("a PDF that is not a schedule is refused with a reason, and the good one stays", why != null && why.Length > 5 && Parse(Official.Json("2026-10-10T16:00:00Z"))["loaded"].ToString() == "True");

        Console.WriteLine("7. the answer for the home screen (Saturday 12:00 local)");
        string nowIso = "2026-10-10T16:00:00Z";
        j = Parse(Official.Json(nowIso));
        Check("loaded, season name read from the titles, ends on a Monday night", S(j["loaded"]) == "True" && S(Obj(j["season"])["name"]) == "2026 Season 4" && S(Obj(j["season"])["ends"]) == "2026-10-20");
        Check("road licence is read from the career cache (C), oval and dirt are assumed Rookie", S(Obj(j["licence"])["road"]) == "C" && S(Obj(j["licence"])["oval"]) == "R" && S(Obj(j["licence"])["ovalKnown"]) == "False");
        object[] days = Arr(j["days"]);
        TimeZoneInfo tz = TimeZoneInfo.Local; DateTime nowLocal = TimeZoneInfo.ConvertTimeFromUtc(U("2026-10-10 16:00"), tz);
        Check("days: today, and Sunday (today is Saturday here), in that order", S(Obj(days[0])["key"]) == "today" && days.Length == 2 && S(Obj(days[1])["key"]) == "sunday" && S(j["view"]) == "weekend" || nowLocal.DayOfWeek != DayOfWeek.Saturday);
        object[] rows = Arr(Obj(days[0])["rows"]);
        Check("today has rows, every one for a car and a track he owns (Alpha, Bravo, Delta, Echo; not Charlie: Class B)", rows.Length >= 3 && rows.All(delegate (object x) { string s = S(Obj(x)["series"]); return s.StartsWith("Alpha") || s.StartsWith("Bravo") || s.StartsWith("Delta") || s.StartsWith("Echo"); }));
        Check("each row carries start (UTC ISO), est flag, car, track, layout, length, licence, id", rows.All(delegate (object x) { Dictionary<string, object> d = Obj(x); return S(d["t"]).EndsWith("Z") && S(d["car"]).Length > 0 && S(d["track"]).Length > 0 && S(d["len"]).Length > 0 && S(d["lic"]).Length == 1 && S(d["id"]).StartsWith("o"); }));
        Check("nothing starts in the past: every row is at or after 'now'", rows.All(delegate (object x) { return DateTime.Parse(S(Obj(x)["t"]), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal) >= U("2026-10-10 16:00"); }));
        Dictionary<string, object> alpha = rows.Select(Obj).FirstOrDefault(delegate (Dictionary<string, object> d) { return S(d["series"]).StartsWith("Alpha"); });
        Dictionary<string, object> bravo = rows.Select(Obj).FirstOrDefault(delegate (Dictionary<string, object> d) { return S(d["series"]).StartsWith("Bravo"); });
        Check("Alpha's start is est (2-hourly, parity guessed), Bravo's is not", alpha != null && S(alpha["est"]) == "True" && bravo != null && S(bravo["est"]) == "False");
        TimeZoneInfo tzRow = TimeZoneInfo.Local;
        DateTime alphaUtc = DateTime.Parse(S(alpha["t"]), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);
        Check("ownedCar ownedTrack localStart countdownSeconds cadence match the fixture", S(alpha["ownedCar"]) == "True" && S(alpha["ownedTrack"]) == "True" && S(alpha["localStart"]) == OfficialCore.LocalStart(alphaUtc, tzRow) && Convert.ToInt32(alpha["countdownSeconds"]) == OfficialCore.CountdownSeconds(alphaUtc, U("2026-10-10 16:00"), tzRow) && Convert.ToInt32(alpha["countdownSeconds"]) >= 0 && S(alpha["cadence"]).Length > 0);
        Check("deck list: one entry per series, soonest first within the favourites-first rule, with ids and tiny names", Arr(j["deck"]).Length == 4 && Arr(j["deck"]).All(delegate (object x) { return S(Obj(x)["tiny"]).Length > 0; }));
        Check("what was left out is counted: Charlie by licence", Convert.ToInt32(Obj(j["left"])["licence"]) >= 1 && Convert.ToInt32(Obj(j["left"])["noTimes"]) == 1);

        Console.WriteLine("8. favourites");
        string idB = S(bravo["id"]);
        Check("star Bravo: accepted", Official.Do("offav", idB));
        string[] favLines = File.ReadAllLines(Path.Combine(dir, "favourites.ini")).Where(delegate (string l) { return l.Trim().Length > 0 && !l.StartsWith(";"); }).ToArray();
        Check("favourites.ini holds the series name without the season", favLines.Length == 1 && favLines[0] == "Bravo Rookie Cup");
        j = Parse(Official.Json(nowIso)); rows = Arr(Obj(Arr(j["days"])[0])["rows"]);
        Check("Bravo is now a favourite and the first row of today", S(Obj(rows[0])["series"]).StartsWith("Bravo") && S(Obj(rows[0])["fav"]) == "True");
        Check("the top favourite's next race is in the header data (next)", j["next"] != null && S(Obj(j["next"])["series"]).StartsWith("Bravo"));
        Check("un-star: the line goes and the favourite flag with it", Official.Do("offav", idB) && !File.ReadAllText(Path.Combine(dir, "favourites.ini")).Contains("Bravo Rookie Cup") && Parse(Official.Json(nowIso))["next"] == null);
        Check("a hand-edited favourites.ini is picked up (Notepad)", Hand(dir, "Echo Mini Cup") && Parse(Official.Json(nowIso))["next"] != null);
        File.WriteAllText(Path.Combine(dir, "favourites.ini"), "");

        Console.WriteLine("9. the whitelist");
        Check("there is no register / join / withdraw command at all", !Official.Handles("ofregister") && !Official.Handles("ofjoin") && !Official.Handles("ofwithdraw") && !Official.Handles("ofpay"));
        Check("a star needs a real series id (no path tricks, no empty, no upper case)", !Official.Do("offav", "") && !Official.Do("offav", "..\\..\\x") && !Official.Do("offav", "o12") && !Official.Do("offav", "oABCDEF12") && !Official.Do("offav", "o00000000"));
        Check("the UI-touching commands refuse while a session is on", Dry());
        Check("import accepts file names only (no folders, no non-PDF)", Route("/official/import", "name", "..\\..\\Windows\\win.ini") == 400 && Route("/official/import", "name", "x.exe") == 400 && Route("/official/import", "name", "nothere.pdf") == 400);

        Console.WriteLine("10. ownership overrules: iRacing's own list said Mini Stock is not his");
        File.WriteAllText(Path.Combine(dir, "owned-ui.json"), "{\"checkedAt\":\"2026-10-10T00:00:00Z\",\"cars\":{\"Mini Stock\":false,\"BMW M4 GT3 EVO\":true},\"tracks\":{}}");
        Official.Do("ofrefresh", "");
        j = Parse(Official.Json(nowIso)); rows = Arr(Obj(Arr(j["days"])[0])["rows"]);
        Check("Bravo and Echo (Mini Stock) are gone from today, Alpha stays", !rows.Any(delegate (object x) { string s = S(Obj(x)["series"]); return s.StartsWith("Bravo") || s.StartsWith("Echo"); }) && rows.Any(delegate (object x) { return S(Obj(x)["series"]).StartsWith("Alpha"); }));
        Check("owned.json is written and lists the folder it could not name", File.ReadAllText(Path.Combine(dir, "owned.json")).Contains("mystery") && S(Obj(Parse(File.ReadAllText(Path.Combine(dir, "owned.json"))))["checkedInIRacing"]) == "2");
        File.Delete(Path.Combine(dir, "owned-ui.json")); Official.Do("ofrefresh", "");

        Console.WriteLine("11. weekdays, Friday evening, and the end of the season");
        j = Parse(Official.Json("2026-10-07T16:00:00Z"));   // Wednesday noon local
        days = Arr(j["days"]);
        Check("Wednesday: today, Saturday, Sunday; view is 'today'", days.Length == 3 && S(Obj(days[1])["key"]) == "saturday" && S(Obj(days[2])["key"]) == "sunday" && S(j["view"]) == "today");
        Check("Saturday's list starts from the evening hour (18:00 local), not midnight", Arr(Obj(days[1])["rows"]).All(delegate (object x) { DateTime t = TimeZoneInfo.ConvertTimeFromUtc(DateTime.Parse(S(Obj(x)["t"]), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal), tz); return t.Hour >= 18 || S(Obj(x)["series"]).StartsWith("Charlie"); }));
        DateTime fri = TimeZoneInfo.ConvertTimeToUtc(new DateTime(2026, 10, 9, 18, 30, 0, DateTimeKind.Unspecified), tz);
        j = Parse(Official.Json(fri.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)));
        Check("Friday 18:30: the weekend is the default view", S(j["view"]) == "weekend");
        j = Parse(Official.Json("2026-12-30T12:00:00Z"));
        Check("after the last week the answer says the season is over (no stale races)", S(Obj(j["season"])["over"]) == "True" && Arr(Obj(Arr(j["days"])[0])["rows"]).Length == 0);

        Console.WriteLine("12. a bad clock value does not break it");
        Check("garbage in ?now= falls back to the real clock", Parse(Official.Json("not a date"))["ready"].ToString() == "True");
    }

    static void WriteProfile(string dir, string auto, string url)
    {
        File.WriteAllText(Path.Combine(dir, "profile.ini"), "autodownload=" + auto + "\r\nscheduleurl=" + url + "\r\nevening=18\r\n");
        File.SetLastWriteTimeUtc(Path.Combine(dir, "profile.ini"), DateTime.UtcNow.AddSeconds(2));
    }

    static void Source(string root, string fixtures)
    {
        string dir = Path.Combine(root, @"data\official");
        Directory.CreateDirectory(dir);
        Directory.CreateDirectory(fixtures);
        byte[] pdf = S4FixturePdf();
        string pdfPath = Path.Combine(fixtures, "2026-s4.pdf");
        File.WriteAllBytes(pdfPath, pdf);
        File.WriteAllText(Path.Combine(fixtures, "2027-s1-absent.html"), Absent2027Html(), new UTF8Encoding(false));

        Console.WriteLine("source page PDF/fallback");
        Check("S4 PDF fixture has a PDF header", pdf.Length > 100 && pdf[0] == (byte)'%' && pdf[1] == (byte)'P');
        string pageWithPdf = "<html><body><a href=\"https://www.iracing.com/seasons/2026-s4/schedule.pdf\">Season PDF</a></body></html>";
        Check("PDF href found on the season page", OfficialCore.FindSeasonPdfHref(pageWithPdf) == "https://www.iracing.com/seasons/2026-s4/schedule.pdf");
        Check("HTML fallback: no PDF href, season table is used", OfficialCore.FindSeasonPdfHref(S4HtmlTable()).Length == 0 && OfficialCore.ParseHtmlSeason(S4HtmlTable()).Count == 10);

        Official.Init(dir);
        Official.MinSeries = 10;
        WriteProfile(dir, "no", "https://www.iracing.com/seasons/2026-s4/");
        Official.TransportCalls = 0; Official.TestTransport = delegate (string u) { return Encoding.UTF8.GetBytes("should not run"); };
        string blocked = Official.FetchIfAllowed();
        Check("profile consent blocks request", blocked == "consent" && Official.TransportCalls == 0);
        Official.TestTransport = null;

        WriteProfile(dir, "yes", "https://www.iracing.com/seasons/2026-s4/");
        Dictionary<string, byte[]> bag = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        bag["https://www.iracing.com/seasons/2026-s4/"] = Encoding.UTF8.GetBytes(pageWithPdf);
        bag["https://www.iracing.com/seasons/2026-s4/schedule.pdf"] = pdf;
        Official.TransportCalls = 0;
        Official.TestTransport = delegate (string u) { byte[] b; return bag.TryGetValue(u, out b) ? b : null; };
        try { File.Delete(Path.Combine(dir, "fetch.txt")); } catch { }
        string gotPdf = Official.FetchIfAllowed();
        Check("season page with PDF href downloads the PDF (no live HTTP)", gotPdf == null && Official.TransportCalls == 2 && File.Exists(Path.Combine(dir, "season.json")));
        Official.TestTransport = null; WriteProfile(dir, "no", "");

        WriteProfile(dir, "yes", "https://www.iracing.com/seasons/2026-s4/");
        bag.Clear();
        bag["https://www.iracing.com/seasons/2026-s4/"] = Encoding.UTF8.GetBytes(S4HtmlTable());
        Official.TransportCalls = 0;
        Official.TestTransport = delegate (string u) { byte[] b; return bag.TryGetValue(u, out b) ? b : null; };
        try { File.Delete(Path.Combine(dir, "fetch.txt")); } catch { }
        string gotHtml = Official.FetchIfAllowed();
        Check("HTML fallback selected only when PDF link is absent", gotHtml == null && Official.TransportCalls == 1);
        Official.TestTransport = null; WriteProfile(dir, "no", "");

        Console.WriteLine("S4 schedule fixture");
        List<OfSeries> s4 = OfficialCore.ParseSeason(PdfText.Extract(File.ReadAllBytes(pdfPath)));
        Check("S4 fixture has 10 named series", s4.Count == 10);
        for (int i = 0; i < S4Expect.Length; i++)
        {
            OfSeries s = i < s4.Count ? s4[i] : new OfSeries();
            string[] e = S4Expect[i];
            Check("S4 " + e[0] + " car", s.Cars.Count > 0 && s.Cars[0] == e[1]);
            Check("S4 " + e[0] + " track", s.Weeks.Count > 0 && s.Weeks[0].Track == e[2]);
            Check("S4 " + e[0] + " cadence", s.Freq == e[3]);
        }

        Console.WriteLine("2027 S1 absent");
        string abs = File.ReadAllText(Path.Combine(fixtures, "2027-s1-absent.html"), Encoding.UTF8);
        Check("2027 S1 remains not published", OfficialCore.SeasonPublishedState(abs) == "not published" && OfficialCore.ParseHtmlSeason(abs).Count == 0 && OfficialCore.FindSeasonPdfHref(abs).Length == 0);

        string good = File.ReadAllText(Path.Combine(dir, "season.json"), Encoding.UTF8);
        Check("prior season.json is a published S4 cache", good.IndexOf("GT3 Challenge Fixed by Fanatec", StringComparison.Ordinal) >= 0);
        Official.MinSeries = 10;
        byte[] junk = Encoding.ASCII.GetBytes("%PDF-1.4 " + new string('x', 3000));
        string junkPath = Path.Combine(dir, "malformed.pdf"); File.WriteAllBytes(junkPath, junk);
        string why = Official.ImportPath(junkPath, "malformed");
        string still = File.ReadAllText(Path.Combine(dir, "season.json"), Encoding.UTF8);
        Check("malformed fixture is refused", why != null && why.Length > 5);
        Check("prior cache retained after malformed fixture", still == good);
        Official.TestTransport = null;
        WriteProfile(dir, "no", "");
    }

    static bool Hand(string dir, string line) { File.WriteAllText(Path.Combine(dir, "favourites.ini"), "; hand written\r\n" + line + "\r\n"); System.Threading.Thread.Sleep(30); File.SetLastWriteTimeUtc(Path.Combine(dir, "favourites.ini"), DateTime.UtcNow.AddSeconds(5)); return true; }
    static bool Dry() { Sdk.FakeConnected = true; bool a = !Official.Do("ofscan", "") && !Official.Do("ofdry", "o00000000"); Sdk.FakeConnected = false; Program.Driving = true; bool b = !Official.Do("ofscan", ""); Program.Driving = false; return a && b; }
    static int Route(string path, string k, string v) { int code; Dictionary<string, string> q = new Dictionary<string, string>(); q[k] = v; Official.Route(path, q, out code); return code; }
}
