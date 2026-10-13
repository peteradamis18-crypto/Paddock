# Real-world calendars (H-05 / H-06). Offline fixtures by default. -Live is opt-in and never part of the gate.
param([switch]$Live)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\guard.ps1')
Assert-RigFree
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Section($t) { Assert-RigFree -Where $t; $t }
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$tmp = Join-Path $env:TEMP "realworld-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$cs = Join-Path $tmp 'rw-unit.cs'
@'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using IRDash;

namespace IRDash {
  static class Log { public static void W(string m) { } }
  class Frame { public bool Connected; }
  static class Sdk { public static string FakeBusy; public static Frame Latest { get { return new Frame(); } } public static string RealBusy() { return FakeBusy; } }
  static class Program { public static bool IsDriving; }
}

static class T {
  static int pass, fail;
  static void Check(string what, bool ok) { if (ok) { pass++; Console.WriteLine("  ok    " + what); } else { fail++; Console.WriteLine("  FAIL  " + what); } }
  const string AsOf = "2026-10-10T12:00:00Z";
  const string F1Json = "{\"MRData\":{\"RaceTable\":{\"Races\":[{\"raceName\":\"United States Grand Prix\",\"Circuit\":{\"circuitName\":\"Circuit of the Americas\"},\"date\":\"2026-10-12\",\"time\":\"19:00:00Z\"}]}}}";
  const string F1SessionsJson = "{\"MRData\":{\"RaceTable\":{\"Races\":[{\"raceName\":\"United States Grand Prix\",\"Circuit\":{\"circuitName\":\"Circuit of the Americas\"},\"FirstPractice\":{\"date\":\"2026-10-23\",\"time\":\"17:30:00Z\"},\"Sprint\":{\"date\":\"2026-10-24\",\"time\":\"18:00:00Z\"},\"Qualifying\":{\"date\":\"2026-10-24\",\"time\":\"22:00:00Z\"},\"date\":\"2026-10-25\",\"time\":\"19:00:00Z\"}]}}}";
  const string OpenF1Json = "[{\"meeting_name\":\"United States Grand Prix\",\"circuit_short_name\":\"Circuit of The Americas\",\"session_name\":\"Qualifying\",\"date_start\":\"2026-10-24T21:00:00+00:00\",\"year\":2026}]";
  const string Imsa = "<table><tr data-series=\"IMSA\"><td>Petit Le Mans</td><td>Michelin Raceway Road Atlanta</td><td>Race</td><td>2026-10-10T12:10:00-04:00</td><td>GTP, LMP2, GTD Pro, GTD</td></tr></table>";
  const string Wec = "<div data-series=\"WEC\" data-event=\"6 Hours of Fuji\" data-track=\"Fuji Speedway\" data-session=\"Race\" data-start=\"2026-10-11T11:00:00+09:00\" data-classes=\"Hypercar,LMGT3\"></div>";
  const string WecProgram = "<h2>2026 FIA WEC</h2><div class=\"race-item\"><div class=\"details\"><span class=\"name\">6 Hours of Barcelona</span><span class=\"month\">october</span><span class=\"dates\">16-18</span></div></div>";
  const string Gtwc = "<table><tr data-series=\"GTWC\" data-event=\"Barcelona\" data-track=\"Circuit de Barcelona-Catalunya\" data-session=\"Race 1\" data-start=\"2026-10-11T13:00:00+02:00\" data-classes=\"Silver,Pro\"><td>Barcelona</td><td>Circuit de Barcelona-Catalunya</td><td>Race 1</td><td>2026-10-11T13:00:00+02:00</td><td>Silver,Pro</td></tr></table>";
  const string GtwcAmerica = "<table><tr data-series=\"GTWC\" data-event=\"Indianapolis\" data-track=\"Indianapolis Motor Speedway\" data-session=\"Qualifying\" data-start=\"2026-10-10T10:00:00-04:00\"><td>Indianapolis</td><td>Indianapolis Motor Speedway</td><td>Qualifying</td><td>2026-10-10T10:00:00-04:00</td></tr></table>";
  const string GtwcTbc = "<table><tr data-series=\"GTWC\" data-event=\"TBC Round\" data-track=\"TBC Track\" data-session=\"Race\" data-start=\"\"><td>TBC Round</td><td>TBC Track</td><td>Race</td><td></td><td></td></tr></table>";
  const string WecIcs = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20261016T090000Z\r\nSUMMARY:Free Practice 1 - 6 Hours of Barcelona\r\nEND:VEVENT\r\nEND:VCALENDAR";
  const string ImsaIcs = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20261023T140000Z\r\nSUMMARY:Practice 1 - Motul Petit Le Mans\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nSUMMARY:Untimed session\r\nEND:VEVENT\r\nEND:VCALENDAR";
  const string GtwcIcs = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20261016T083000Z\r\nSUMMARY:Free Practice 1 - GT World Challenge Europe Endurance Cup - Portimão\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nDTSTART:20261017T170000Z\r\nSUMMARY:Portimão 3 Hours - GT World Challenge Europe Endurance Cup - Portimão\r\nEND:VEVENT\r\nEND:VCALENDAR";
  static int Main(string[] a) {
    string mode = a.Length > 0 ? a[0] : "h05";
    string dir = a.Length > 1 ? a[1] : Path.Combine(Path.GetTempPath(), "rw-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(dir);
    RealWorld.Init(dir);
    RealWorld.TestNow = new DateTime(2026, 10, 10, 12, 0, 0, DateTimeKind.Utc);
    RealWorld.AllowLive = false;
    RealWorld.TransportCalls = 0;
    RealWorld.TestTransport = null;
    RealWorld.TestBusy = null;
    RealWorld.PreviewLines = false;
    if (mode == "h05") H05(dir);
    else if (mode == "h06") H06(dir);
    else if (mode == "live") Live(a, dir);
    Console.WriteLine("RESULT " + pass + " " + fail);
    return fail == 0 ? 0 : 1;
  }

  static void H05(string dir) {
    Console.WriteLine("fixture parse");
    List<RwEvent> f1 = RealWorld.ParseF1(F1Json, "https://api.jolpi.ca/ergast/f1/current.json", AsOf);
    Check("F1 series", f1.Count == 1 && f1[0].Series == "F1");
    Check("F1 session", f1[0].Session == "Race");
    Check("F1 source", f1[0].Source.IndexOf("jolpi") >= 0 && !f1[0].Tbc && f1[0].LocalStart.IndexOf("2026-10-12") >= 0);
    List<RwEvent> f1sessions = RealWorld.ParseF1(F1SessionsJson, "https://api.jolpi.ca/ergast/f1/current.json", AsOf);
    Check("Jolpica session rows", f1sessions.Count == 4 && f1sessions[0].Session == "First Practice" && f1sessions[1].Session == "Sprint" && f1sessions[2].Session == "Qualifying" && f1sessions[3].Session == "Race");

    List<RwEvent> of1 = RealWorld.ParseOpenF1(OpenF1Json, "https://api.openf1.org/v1/sessions?year=2026", AsOf);
    Check("OpenF1 session and event", of1.Count == 1 && of1[0].Event == "United States Grand Prix" && of1[0].Session == "Qualifying");
    Check("OpenF1 source and UTC offset", of1.Count == 1 && of1[0].Source.IndexOf("openf1.org") >= 0 && of1[0].Utc == new DateTime(2026, 10, 24, 21, 0, 0, DateTimeKind.Utc));

    List<RwEvent> im = RealWorld.ParseImsa(Imsa, "https://www.imsa.com/schedule/", AsOf);
    Check("IMSA series", im.Count == 1 && im[0].Series == "IMSA");
    Check("IMSA session", im[0].Session == "Race" && im[0].Event == "Petit Le Mans");
    Check("IMSA source", im[0].Source.IndexOf("imsa.com") >= 0 && im[0].LocalStart.IndexOf("-04:00") >= 0);

    List<RwEvent> we = RealWorld.ParseWec(Wec, "https://www.fiawec.com/en/calendar", AsOf);
    Check("WEC series", we.Count == 1 && we[0].Series == "WEC");
    Check("WEC session", we[0].Session == "Race" && we[0].Event.IndexOf("Fuji") >= 0);
    Check("WEC source and Windows local time", we[0].Source.IndexOf("fiawec.com") >= 0 && we[0].LocalStart == Local(we[0].Utc));
    List<RwEvent> wp = RealWorld.ParseWecProgram(WecProgram, "https://www.fiawec.com/en/page/official-programme", AsOf);
    Check("WEC programme event and date", wp.Count == 1 && wp[0].Event == "6 Hours of Barcelona" && wp[0].EventDate == "2026-10-16");
    Check("WEC unpublished session time remains TBC", wp.Count == 1 && wp[0].Tbc && wp[0].LocalStart.Length == 0 && wp[0].Utc == new DateTime(2026, 10, 16, 0, 0, 0, DateTimeKind.Utc));

    List<RwEvent> gt = RealWorld.ParseGtwc(Gtwc, "https://www.gt-world-challenge-europe.com/calendar", AsOf);
    Check("GTWC series", gt.Count == 1 && gt[0].Series == "GTWC");
    Check("GTWC session", gt[0].Session == "Race 1");
    Check("GTWC source and Windows local time", gt[0].Source.IndexOf("gt-world-challenge") >= 0 && gt[0].LocalStart == Local(gt[0].Utc));
    List<RwEvent> ga = RealWorld.ParseGtwcAmerica(GtwcAmerica, "https://www.gt-world-challenge-america.com/calendar", AsOf);
    Check("GTWC America series and session", ga.Count == 1 && ga[0].Series == "GTWC America" && ga[0].Session == "Qualifying" && ga[0].Event == "Indianapolis");
    Check("GTWC America source and local time", ga.Count == 1 && ga[0].Source.IndexOf("gt-world-challenge-america.com") >= 0 && ga[0].LocalStart == Local(ga[0].Utc));

    List<RwEvent> wi = RealWorld.ParseIcs(WecIcs, "WEC", "https://racetagger.cloud/wec.ics", AsOf);
    Check("WEC ICS timed session", wi.Count == 1 && wi[0].Session == "Free Practice 1" && wi[0].Event == "6 Hours of Barcelona" && wi[0].Utc == new DateTime(2026, 10, 16, 9, 0, 0, DateTimeKind.Utc));
    List<RwEvent> ii = RealWorld.ParseIcs(ImsaIcs, "IMSA", "https://racetagger.cloud/imsa.ics", AsOf);
    Check("IMSA ICS timed session and TBC omitted", ii.Count == 1 && ii[0].Session == "Practice 1" && ii[0].Event == "Motul Petit Le Mans");
    List<RwEvent> gi = RealWorld.ParseIcs(GtwcIcs, "GTWC Europe", "https://racetagger.cloud/gtwc.ics", AsOf);
    Check("GTWC ICS session and repeated race title", gi.Count == 2 && gi[0].Session == "Free Practice 1" && gi[0].Event == "GT World Challenge Europe Endurance Cup - Portimão" && gi[1].Session == "Race");
    List<RwEvent> tz = RealWorld.ParseIcs("BEGIN:VEVENT\r\nDTSTART;TZID=Europe/Lisbon:20261016T093000\r\nSUMMARY:Test - Local time\r\nEND:VEVENT", "WEC", "source", AsOf);
    Check("ICS TZID converted to UTC", tz.Count == 1 && tz[0].Utc == new DateTime(2026, 10, 16, 8, 30, 0, DateTimeKind.Utc));
    Console.WriteLine("timezone");
    Check("DST boundary offset retained", im[0].LocalStart.EndsWith("-04:00") && im[0].Utc == new DateTime(2026, 10, 10, 16, 10, 0, DateTimeKind.Utc));
    Check("local offset follows Windows zone", we[0].LocalStart == Local(we[0].Utc) && gt[0].LocalStart == Local(gt[0].Utc));
    TimeZoneInfo gmt = TimeZoneInfo.FindSystemTimeZoneById("GMT Standard Time");
    DateTime local = TimeZoneInfo.ConvertTimeFromUtc(im[0].Utc, gmt);
    Check("local display conversion", local.Year == 2026 && local.Month == 10 && local.Day == 10);
    List<RwEvent> tbc = RealWorld.ParseGtwc(GtwcTbc, "https://www.gt-world-challenge-europe.com/calendar", AsOf);
    Check("no-time stays TBC", tbc.Count == 1 && tbc[0].Tbc && (tbc[0].LocalStart == null || tbc[0].LocalStart.Length == 0));

    Console.WriteLine("sort/dedupe");
    List<RwEvent> mix = new List<RwEvent>();
    mix.AddRange(f1); mix.AddRange(im); mix.AddRange(we); mix.AddRange(gt); mix.AddRange(ga); mix.AddRange(f1);
    List<RwEvent> sorted = RealWorld.MergeFilterSort(mix, RealWorld.TestNow, TimeZoneInfo.Utc);
    Check("dedupe same F1 row", CountSeries(sorted, "F1") == 1);
    Check("sort by UTC then series", sorted.Count >= 3 && sorted[0].Utc <= sorted[sorted.Count - 1].Utc);

    Console.WriteLine("cache freshness");
    DateTime asOf = new DateTime(2026, 10, 10, 12, 0, 0, DateTimeKind.Utc);
    RealWorld.PutCache(sorted, asOf);
    Check("6 h fresh", RealWorld.CacheFresh(asOf.AddHours(5)));
    Check("stale retains prior asOf", !RealWorld.CacheFresh(asOf.AddHours(7)) && RealWorld.CacheAsOf == asOf);

    Console.WriteLine("failure preserves cache");
    RealWorld.PutCache(sorted, asOf.AddHours(-7));
    DateTime kept = RealWorld.CacheAsOf;
    int n = RealWorld.Events.Count;
    RealWorld.TestTransport = delegate (string u) { throw new InvalidOperationException("timeout"); };
    string fail = RealWorld.TryRefresh();
    Check("timeout keeps prior asOf", RealWorld.CacheAsOf == kept);
    Check("timeout keeps prior events", RealWorld.Events.Count == n && fail != null);
    RealWorld.TestTransport = null;

    Console.WriteLine("busy");
    RealWorld.TransportCalls = 0;
    RealWorld.TestBusy = delegate { return "the sim is running"; };
    string b = RealWorld.TryRefresh();
    Check("Sdk.RealBusy blocks request", b == "busy" && RealWorld.TransportCalls == 0);
    RealWorld.TestBusy = null;
  }

  static void Live(string[] a, string dir) {
    Console.WriteLine("live ICS window");
    RealWorld.TestNow = DateTime.UtcNow;
    List<RwEvent> all = new List<RwEvent>();
    foreach (RwEvent old in RealWorld.Events) if (old.Series == "F1") all.Add(old);
    for (int i = 2; i + 2 < a.Length; i += 3) {
      string series = a[i], path = a[i + 1], source = a[i + 2];
      List<RwEvent> rows = RealWorld.ParseIcs(File.ReadAllText(path, Encoding.UTF8), series, source, DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
      all.AddRange(rows);
    }
    List<RwEvent> upcoming = RealWorld.MergeFilterSort(all, DateTime.UtcNow, TimeZoneInfo.Local);
    int timedNonF1 = 0;
    foreach (RwEvent e in upcoming) if (e.Series != "F1" && !e.Tbc && e.LocalStart.Length > 0) {
      timedNonF1++;
      Console.WriteLine("LIVE " + e.Series + " | " + e.Event + " | " + e.Session + " | " + e.LocalStart);
    }
    Check("at least one timed non-F1 live session in next 14 days", timedNonF1 > 0);
    RealWorld.PutCache(upcoming, DateTime.UtcNow);
  }

  static int CountSeries(List<RwEvent> l, string s) { int n = 0; foreach (RwEvent e in l) if (e.Series == s) n++; return n; }
  static string Local(DateTime utc) { return new DateTimeOffset(utc).ToOffset(TimeZoneInfo.Local.GetUtcOffset(utc)).ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture); }

  static void H06(string dir) {
    Console.WriteLine("preview disabled");
    RealWorld.PreviewLines = false;
    RealWorld.ClearPreview();
    RealWorld.PreviewCalls = 0;
    RwEvent e = RealWorld.ParseImsa(Imsa, "https://www.imsa.com/schedule/", AsOf)[0];
    RwRss rss = new RwRss(); rss.Title = "Petit Le Mans grid"; rss.Summary = "GTP LMP2 GTD Pro GTD at Road Atlanta"; rss.Url = "https://www.imsa.com/news/plm"; rss.PubDate = "6 Oct 2026";
    bool off = RealWorld.RequestPreview(e, rss, RealWorld.TestNow);
    Check("zero requests when off", RealWorld.PreviewCalls == 0 && !off);
    Check("no preview when off", !RealWorld.ApplyPreview(e, "GTP field at Road Atlanta", rss.Url, rss.PubDate, RealWorld.TestNow) || !RealWorld.PreviewLines);

    Console.WriteLine("request mapping");
    RealWorld.PreviewLines = true;
    RealWorld.ClearPreview();
    string sent = "";
    RealWorld.TestPreviewHttp = delegate (string payload, string model) { sent = payload; return "GTP and GTD Pro race 10 h at Road Atlanta."; };
    bool ok1 = RealWorld.RequestPreview(e, rss, RealWorld.TestNow);
    Check("nine event fields plus RSS", sent.IndexOf("series=IMSA") >= 0 && sent.IndexOf("event=Petit Le Mans") >= 0 && sent.IndexOf("track=Michelin Raceway Road Atlanta") >= 0 && sent.IndexOf("session=Race") >= 0 && sent.IndexOf("classes=") >= 0 && sent.IndexOf("localStart=") >= 0 && sent.IndexOf("tbc=") >= 0 && sent.IndexOf("source=") >= 0 && sent.IndexOf("asOf=") >= 0 && sent.IndexOf("rssTitle=Petit Le Mans grid") >= 0 && sent.IndexOf("rssUrl=https://www.imsa.com/news/plm") >= 0);
    Check("zero private fields", sent.IndexOf("ibt") < 0 && sent.IndexOf("telemetry") < 0 && sent.IndexOf("password") < 0 && sent.IndexOf("OPENROUTER") < 0 && ok1);

    Console.WriteLine("cache key");
    int c1 = RealWorld.PreviewCalls;
    bool again = RealWorld.RequestPreview(e, rss, RealWorld.TestNow);
    Check("second call same week suppressed", RealWorld.PreviewCalls == c1 && !again);
    Check("accepted text keeps source and date", ok1);

    Console.WriteLine("banned copy");
    string[] bad = new string[] {
      "You should watch this race",
      "Good morning and welcome to Petit Le Mans",
      "This is just a great journey",
      "What a race!",
      "The race - really big - today",
      "Race \uD83C\uDFCE time",
      "Caf\u00C3\u00A9 grid",
      "outline from your own notes sampled 10"
    };
    int bans = 0;
    foreach (string t in bad) { if (RealWorld.PreviewBanned(t)) bans++; Check("banned: " + t.Substring(0, Math.Min(18, t.Length)), RealWorld.PreviewBanned(t)); }
    Check("eight banned categories rejected", bans >= 8);

    Console.WriteLine("accepted source date");
    RealWorld.ClearPreview();
    Check("accepted factual line", RealWorld.ApplyPreview(e, "Petit Le Mans 10 h GTP LMP2 GTD Pro GTD", rss.Url, "6 Oct 2026", RealWorld.TestNow));
    string json = RealWorld.EventsJson(new List<RwEvent> { e }, RealWorld.TestNow, true);
    Check("source and absolute date independent", json.IndexOf("previewSource") >= 0 && json.IndexOf("6 Oct 2026") >= 0 && json.IndexOf("https://www.imsa.com/news/plm") >= 0);

    Console.WriteLine("busy and error");
    RealWorld.ClearPreview();
    RealWorld.TestBusy = delegate { return "the sim is running"; };
    RealWorld.TestPreviewHttp = delegate (string p, string m) { return "should not"; };
    Check("busy sim no preview", !RealWorld.RequestPreview(e, rss, RealWorld.TestNow) && RealWorld.PreviewCalls == 0);
    RealWorld.TestBusy = null;
    RealWorld.TestPreviewHttp = delegate (string p, string m) { throw new InvalidOperationException("http"); };
    Check("HTTP error no preview", !RealWorld.RequestPreview(e, rss, RealWorld.TestNow));

    Console.WriteLine("cap and timeout");
    RealWorld.ClearPreview();
    RealWorld.TestPreviewHttp = delegate (string p, string m) { return new string('x', 40000); };
    Check("response cap rejects", !RealWorld.RequestPreview(e, rss, RealWorld.TestNow));
    RealWorld.TestPreviewHttp = delegate (string p, string m) { throw new TimeoutException(); };
    Check("timeout no preview", !RealWorld.RequestPreview(e, rss, RealWorld.TestNow));
    RealWorld.PreviewLines = false;
  }
}
'@ | Set-Content -LiteralPath $cs -Encoding ASCII
$exe = Join-Path $tmp 'rw-unit.exe'
$out = & "$fw\csc.exe" -nologo -r:System.Web.Extensions.dll "-out:$exe" $cs "$root\dash\src\realworld.cs" 2>&1
Check 'realworld.cs compiles (C# 5)' ((Test-Path $exe) -and -not ($out | Where-Object { $_ -match 'error CS' }))
if (-not (Test-Path $exe)) { $out; "$pass passed, $fail failed."; exit 1 }

$cache = Join-Path $tmp 'data'
New-Item -ItemType Directory -Force $cache | Out-Null
Section 'fixture parse'
$h05 = @(& $exe h05 $cache)
$h05 | Where-Object { $_ -match '^(  ok|  FAIL|fixture |timezone|sort|cache |failure |busy)' }
$res = ($h05 | Where-Object { $_ -match '^RESULT' } | Select-Object -Last 1) -split ' '
if ($res.Count -ge 3) { $script:pass += [int]$res[1]; $script:fail += [int]$res[2] } else { $script:fail++; '  FAIL  h05 did not finish' }
Section 'timezone'
Section 'sort/dedupe'
Section 'cache freshness'
Section 'failure preserves cache'
Section 'Sdk.RealBusy blocks request'

Section 'preview disabled'
$h06 = @(& $exe h06 $cache)
$h06 | Where-Object { $_ -match '^(  ok|  FAIL|preview |request |cache |banned |accepted |busy |cap )' }
$res6 = ($h06 | Where-Object { $_ -match '^RESULT' } | Select-Object -Last 1) -split ' '
if ($res6.Count -ge 3) { $script:pass += [int]$res6[1]; $script:fail += [int]$res6[2] } else { $script:fail++; '  FAIL  h06 did not finish' }
Section 'request mapping'
Section 'cache key'
Section 'banned copy'
Section 'accepted source date'
Section 'busy and HTTP error'
Section 'response cap and timeout'

if ($Live) {
  Assert-RigFree -Where 'live'
  Section 'live public ICS feeds'
  $feeds = @(
    @{ series='IMSA'; id='9df731ac-2a96-41c3-96f1-80e73731da96'; file='racetagger-imsa.ics' },
    @{ series='WEC'; id='e1edb481-9432-4e5a-af11-287ace8cf999'; file='racetagger-wec.ics' },
    @{ series='GTWC Europe'; id='a4eb8c77-eff5-4e23-8306-86256bcf5035'; file='racetagger-gtwc.ics' }
  )
  $liveArgs = @('live', $cache)
  foreach ($feed in $feeds) {
    $fixture = Join-Path $env:TEMP $feed.file
    if (-not (Test-Path $fixture) -or ((Get-Date) - (Get-Item $fixture).LastWriteTime).TotalHours -ge 6) {
      try {
        $url = "https://racetagger.cloud/api/calendar/ical?championship_id=$($feed.id)"
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 10 -Headers @{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/129.0 Safari/537.36 PADDOCK-calendar-check'; 'Accept'='text/calendar' }
        [IO.File]::WriteAllText($fixture, [string]$response.Content, [Text.Encoding]::UTF8)
        Start-Sleep -Seconds 2
      } catch { "  feed unavailable: $($feed.series) $($_.Exception.Message)"; continue }
    }
    $url = "https://racetagger.cloud/api/calendar/ical?championship_id=$($feed.id)"
    $liveArgs += @($feed.series, $fixture, $url)
  }
  $prior = Join-Path $root 'data\official\realworld.json'
  if (Test-Path $prior) { Copy-Item -LiteralPath $prior -Destination (Join-Path $cache 'realworld.json') -Force }
  $lv = @(& $exe @liveArgs)
  $lv | ForEach-Object { if ($_ -match '^(  ok|  FAIL|LIVE )') { $_ } }
  $lr = ($lv | Where-Object { $_ -match '^RESULT' } | Select-Object -Last 1) -split ' '
  if ($lr.Count -ge 3) { $script:pass += [int]$lr[1]; $script:fail += [int]$lr[2] } else { $script:fail++; '  FAIL  live feed section did not finish' }
  if ($script:fail -eq 0 -and (Test-Path (Join-Path $cache 'realworld.json'))) {
    $liveCache = Join-Path $root 'data\official\realworld.json'
    Remove-Item -LiteralPath $liveCache -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $cache 'realworld.json') -Destination $liveCache -Force
    '  ok    replaced real-world cache with fresh parsed feed rows'
  }
}

try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }


