# nightly-test.ps1 - offline (W5-4): the night check and irdash's clock for it.
#   1. dash\src\nightlyrules.cs on its own (fake clocks): 02:59 no, 03:00 yes, 03:30 after a restart yes, 06:30 no, twice the same day no,
#      nightly=off never; the "nightly" state part from a fixture file and null without one; 60 lines kept
#   2. tests\nightly.ps1 against a pretend irdash (an HttpListener on port 8397, never 8199) and a stand-in irdeck-cli (a .cmd):
#      all good; a Stream Deck that was down (started it); the add-on out of date; a Doctor fault; the add-on silent / the deck not back;
#      the guard busy -> "skipped, ..." and nothing else ran; Peter at the PC; irdash silent -> "did not finish"; 60 lines kept; the time limits
#   3. the wiring in dash\src (part registered, route is test-hook only and 409 in a session, ini switch, 12-minute kill, no test copy)
# Nothing here touches the real irdash, Stream Deck or the sim. powershell -ExecutionPolicy Bypass -File tests\nightly-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tmp = Join-Path $env:TEMP ('nightly-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$port = 8397
$listener = $null; $rs = $null

'W5-4 nightly self-check'
try {
  # ================= 1. the rules (compiled alone) =================
  Assert-RigFree -Where '1. rules'
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $main = @'
using System; using System.IO; using IRDash;
static class M {
  static int fail = 0;
  static void T(string what, bool c) { Console.WriteLine((c ? "ok   " : "FAIL ") + what); if (!c) fail++; }
  static DateTime D(string s) { return DateTime.ParseExact(s, "yyyy-MM-dd HH:mm", null); }
  static int Main(string[] a) {
    string f = a[0];
    T("02:59 is not time", !NightlyRules.IsTime(D("2026-11-15 02:59"), "", true));
    T("03:00 is time", NightlyRules.IsTime(D("2026-11-15 03:00"), "", true));
    T("03:30 after a restart is time", NightlyRules.IsTime(D("2026-11-15 03:30"), "20261113", true));
    T("05:59 is still time", NightlyRules.IsTime(D("2026-11-15 05:59"), "", true));
    T("06:30 is not time", !NightlyRules.IsTime(D("2026-11-15 06:30"), "", true));
    T("twice the same day is not time", !NightlyRules.IsTime(D("2026-11-15 03:05"), "20261115", true));
    T("the next day is time again", NightlyRules.IsTime(D("2026-11-16 03:00"), "20261115", true));
    T("nightly=off is never time", !NightlyRules.IsTime(D("2026-11-15 03:00"), "", false));
    T("the window passing is noticed once it is 06:00", NightlyRules.WindowPassed(D("2026-11-15 06:01"), "20261114", true) && !NightlyRules.WindowPassed(D("2026-11-15 04:00"), "20261114", true) && !NightlyRules.WindowPassed(D("2026-11-15 06:01"), "20261115", true) && !NightlyRules.WindowPassed(D("2026-11-15 06:01"), "", false));
    T("no file: the part is null and there is no last day", NightlyRules.PartJson(f) == "null" && NightlyRules.LastDay(f) == "");
    File.WriteAllText(f, "2026-11-14T03:00\t0\tRig check 03:00: skipped, Peter was at the PC\r\n2026-11-15T03:00\t1\tRig check 03:00: all good\r\n");
    T("the part is the last line, W5-1's shape", NightlyRules.PartJson(f) == "{\"at\":\"2026-11-15T03:00\",\"text\":\"Rig check 03:00: all good\",\"ok\":true,\"notChecked\":[\"recorder\",\"deck start page\"]}");
    T("the last day comes from the last line", NightlyRules.LastDay(f) == "20261115");
    File.WriteAllText(f, "2026-11-15T03:00\t0\tRig check 03:00: 1 thing: \"quote\" and \\slash\r\n");
    T("a not-ok line says ok:false and quotes are escaped", NightlyRules.PartJson(f) == "{\"at\":\"2026-11-15T03:00\",\"text\":\"Rig check 03:00: 1 thing: \\\"quote\\\" and \\\\slash\",\"ok\":false,\"notChecked\":[\"recorder\",\"deck start page\"]}");
    File.WriteAllText(f, "garbage\r\n");
    T("the deck restart gate: no check running, already taken, PC used 3 min ago all refuse; a running check with 11 idle minutes goes", NightlyRules.DeckGate(false, false, 99, 10) != null && NightlyRules.DeckGate(true, true, 99, 10) != null && NightlyRules.DeckGate(true, false, 3, 10) != null && NightlyRules.DeckGate(true, false, 9.9, 10) != null && NightlyRules.DeckGate(true, false, 11, 10) == null);
    T("a broken file is null, never an error", NightlyRules.PartJson(f) == "null");
    File.Delete(f);
    for (int i = 0; i < 75; i++) NightlyRules.Append(f, NightlyRules.Row(new DateTime(2026, 11, 1).AddDays(i % 28), i % 2 == 0, "Rig check 03:00: n" + i));
    string[] all = File.ReadAllLines(f);
    T("the file keeps 60 lines, newest last", all.Length == 60 && all[59].EndsWith("n74") && all[0].EndsWith("n15"));
    return fail;
  }
}
'@
  $mainFile = Join-Path $tmp 'rules-main.cs'; Set-Content -Encoding utf8 $mainFile $main
  $rulesExe = Join-Path $tmp 'rules.exe'
  $cout = & $csc /nologo /target:exe "/out:$rulesExe" (Join-Path $root 'dash\src\nightlyrules.cs') $mainFile 2>&1 | Out-String
  ok 'nightlyrules.cs compiles on its own' (Test-Path $rulesExe) $cout
  if (Test-Path $rulesExe) {
    $out = & $rulesExe (Join-Path $tmp 'rules-part.txt')
    foreach ($l in $out) { ok ("rules: " + ($l -replace '^(ok|FAIL)\s+', '')) ($l -like 'ok*') }
  }

  # ================= 2. the script against a pretend irdash and a stand-in irdeck-cli =================
  Assert-RigFree -Where '2. script'
  # the stand-in irdeck-cli: the answers the real one gives with the sim off (keys-test section 8), one mode file picks a wrong one
  $cliDir = Join-Path $tmp 'cli'; New-Item -ItemType Directory -Force $cliDir | Out-Null
  $cli = Join-Path $cliDir 'irdeck-cli.cmd'
  Set-Content -Encoding ascii $cli @'
@echo off
set MODE=ok
if exist "%~dp0mode.txt" set /p MODE=<"%~dp0mode.txt"
if /i "%1"=="state" (
  if /i "%MODE%"=="simon" ( echo sim=True onTrack=False telemetry=off & exit /b 0 )
  if /i "%MODE%"=="driving" ( echo sim=False onTrack=True telemetry=on & exit /b 0 )
  if /i "%MODE%"=="silent" ( exit /b 0 )
  echo sim=False onTrack=False telemetry=off & exit /b 0 )
if /i "%MODE%"=="badkey" ( if /i "%1"=="getout" ( echo ERROR something broke & exit /b 1 ) )
if /i "%1"=="pittoggle" ( echo no sim session running & exit /b 3 )
if /i "%1"=="getout" ( echo no sim session running & exit /b 3 )
if /i "%1"=="chat" ( echo no sim session running & exit /b 3 )
if /i "%1"=="skip" ( echo no session is running & exit /b 3 )
if /i "%1"=="tow" ( echo tow: stationary & exit /b 0 )
exit /b 2
'@

  # the pretend irdash: an HttpListener in its own runspace; $S is the shared scenario
  $S = [hashtable]::Synchronized(@{ hits = (New-Object Collections.ArrayList) })
  function Reset-Scenario {
    $S.health = [ordered]@{ deck = 'ok'; ui = 'off'; sim = 'off'; cc = 'ok'; overlays = 'ok' }
    $S.items = @(@{ id = 'screens'; name = 'Screens'; state = 'ok'; detail = '3 x 2560x1440'; fix = '' })
    $S.doctorFixesDeck = $true; $S.doctorHangs = $false; $S.deckComesBack = $true; $S.addonSilent = $false; $S.restartedAt = $null
    $S.doctorAt = $null; $S.dead = $false; $S.refuseDeck = $false
    $S.hits.Clear()
  }
  Reset-Scenario
  $listener = New-Object Net.HttpListener; $listener.Prefixes.Add("http://localhost:$port/"); $listener.Start()
  $rs = [runspacefactory]::CreateRunspace(); $rs.Open(); $rs.SessionStateProxy.SetVariable('S', $S); $rs.SessionStateProxy.SetVariable('listener', $listener)
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript({
    function Send($ctx, [int]$code, [string]$body) { $b = [Text.Encoding]::UTF8.GetBytes($body); $ctx.Response.StatusCode = $code; $ctx.Response.ContentType = 'application/json'; $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close() }
    while ($listener.IsListening) {
      try { $ctx = $listener.GetContext() } catch { break }
      try {
        $p = $ctx.Request.Url.AbsolutePath; [void]$S.hits.Add($p)
        if ($S.dead) { $ctx.Response.Abort(); continue }
        $now = Get-Date
        if ($p -eq '/health') {
          $apps = @(); foreach ($k in $S.health.Keys) { $apps += ('{"id":"' + $k + '","name":"' + $k + '","state":"' + $S.health[$k] + '"}') }
          Send $ctx 200 ('{"apps":[' + ($apps -join ',') + '],"events":[]}')
        }
        elseif ($p -eq '/api/doctor/run') { if ($S.doctorFixesDeck -and $S.health['deck'] -ne 'ok') { $S.health['deck'] = 'ok' }; $S.doctorAt = $now; Send $ctx 200 'ok' }
        elseif ($p -eq '/doctor') {
          $items = @(); foreach ($i in $S.items) { $items += ('{"id":"' + $i.id + '","name":"' + $i.name + '","state":"' + $i.state + '","detail":"' + $i.detail + '","fix":"' + $i.fix + '"}') }
          $ran = if ($S.doctorAt) { '"' + $S.doctorAt.ToString('s') + '"' } else { '"2026-11-14T01:00:00"' }
          $running = if ($S.doctorHangs -and $S.doctorAt) { 'true' } else { 'false' }
          $since = if ($S.restartedAt) { ($now - $S.restartedAt).TotalSeconds } else { 5 }
          $age = if ($S.addonSilent) { $since + 40 } else { [math]::Max(0, $since - 3) }
          Send $ctx 200 ('{"ranAt":' + $ran + ',"age":3,"running":' + $running + ',"headline":"pretend headline","deckAge":' + ([int]$age) + ',"items":[' + ($items -join ',') + ']}')
        }
        elseif ($p -eq '/api/nightly/deck') {
          if ($ctx.Request.Headers['X-Paddock'] -ne '1') { Send $ctx 403 'refused: header'; continue }
          if ($S.refuseDeck) { Send $ctx 409 'refused: a session is on'; continue }
          $S.restartedAt = $now; if ($S.deckComesBack) { $S.health['deck'] = 'ok' } else { $S.health['deck'] = 'down' }
          Send $ctx 200 'ok'
        }
        else { Send $ctx 404 'not found' }
      } catch { try { $ctx.Response.Abort() } catch { } }
    }
  })
  $null = $ps.BeginInvoke()

  $outDir = Join-Path $tmp 'out'
  function Run-Night([hashtable]$more = @{}) {
    $opt = @{ TestIdle = '999' }; foreach ($key in $more.Keys) { $opt[$key] = $more[$key] }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'nightly.ps1'), '-Base', "http://localhost:$port", '-Cli', $cli, '-OutDir', $outDir, '-Fast', '-NoLock')
    foreach ($key in $opt.Keys) { $a += "-$key"; $a += [string]$opt[$key] }
    $o = & powershell.exe @a 2>&1 | ForEach-Object { "$_" }
    $f = Join-Path $outDir 'nightly.txt'
    $last = if (Test-Path $f) { (Get-Content $f | Select-Object -Last 1) } else { '' }
    [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n"); line = $last; text = ($last -split "`t", 3)[2]; flag = ($last -split "`t")[1] }
  }
  Set-Content -Encoding ascii (Join-Path $cliDir 'mode.txt') 'ok'

  $r = Run-Night
  ok 'all good: the line says so, flag 1, exit 0' ($r.rc -eq 0 -and $r.text -match '^Rig check 03:00: all good' -and $r.flag -eq '1') "[$($r.text)] rc=$($r.rc) $($r.out)"
  ok 'all good: the RIG line is clean, exactly "Rig check 03:00: all good", no not-checked suffix' ($r.text -eq 'Rig check 03:00: all good')
  ok 'all good: a restart was asked of irdash, the Doctor ran quietly, /health was read' (($S.hits -contains '/api/nightly/deck') -and ($S.hits -contains '/api/doctor/run') -and ($S.hits -contains '/health'))
  ok 'all good: the full log is in tests\last\nightly-<day>.txt with the recorder answer' ((Get-ChildItem (Join-Path $outDir 'last') -Filter 'nightly-*.txt' | Select-Object -First 1 | Get-Content -Raw) -match '(?s)recorder: not checked.*not checked tonight: recorder.*deck start page')

  # one fault: Stream Deck was down, the Doctor started it
  Reset-Scenario; $S.health['deck'] = 'down'
  $r = Run-Night
  ok 'Stream Deck was down and the Doctor started it: "1 thing: Stream Deck was not running (started it)"' ($r.text -match '^Rig check 03:00: 1 thing: Stream Deck was not running \(started it\)' -and $r.flag -eq '0') "[$($r.text)]"

  # two faults: the spotter will not start + the add-on is out of date
  Reset-Scenario; $S.health['cc'] = 'off'; $S.doctorFixesDeck = $false
  $S.items = @(@{ id = 'streamdeck'; name = 'Stream Deck'; state = 'ok'; detail = 'Running - Rig Intro add-on 1.2 (1.3 ready to install)'; fix = '' }, @{ id = 'crewchief'; name = 'CrewChief'; state = 'bad'; detail = 'not running'; fix = 'x' })
  $r = Run-Night
  ok 'a spotter that stays off and an old add-on: "2 things" naming both, the spotter once' ($r.text -match '^Rig check 03:00: 2 things: ' -and $r.text -match 'the Stream Deck add-on is out of date' -and $r.text -match 'the spotter \(CrewChief\) was not running \(could not start it\)' -and ([regex]::Matches($r.text, 'spotter').Count -eq 1)) "[$($r.text)]"

  # a Doctor fault that is not an app
  Reset-Scenario; $S.items = @(@{ id = 'disk'; name = 'Disk'; state = 'warn'; detail = 'only 30 GB free'; fix = 'x' })
  $r = Run-Night
  ok 'a Doctor warning is named: "Disk: only 30 GB free"' ($r.text -match '1 thing: Disk: only 30 GB free') "[$($r.text)]"

  # wrong dry key answer
  Reset-Scenario; Set-Content -Encoding ascii (Join-Path $cliDir 'mode.txt') 'badkey'
  $r = Run-Night
  ok 'a dry key that answers wrongly is named (getout)' ($r.text -match 'deck keys did not answer as expected \(getout\)') "[$($r.text)]"
  Set-Content -Encoding ascii (Join-Path $cliDir 'mode.txt') 'ok'

  # the PC is locked (2026-11-14 21:02): the add-on's page sleeps, so a "silent" Doctor item is not a thing and the deck is not restarted
  Reset-Scenario; $S.items = @(@{ id = 'streamdeck'; name = 'Stream Deck'; state = 'warn'; detail = 'Rig Intro add-on silent for over 2 min'; fix = 'Close and open the Stream Deck app' })
  $r = Run-Night @{ TestLocked = '1' }
  ok 'locked PC: a silent add-on is not a thing and no restart is asked; the line is "all good"' ($r.text -eq 'Rig check 03:00: all good' -and -not ($S.hits -contains '/api/nightly/deck')) "[$($r.text)] hits=$($S.hits -join ' ')"
  ok 'locked PC: the full log says both were not checked because of the lock' ((Get-ChildItem (Join-Path $outDir 'last') -Filter 'nightly-*.txt' | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Raw) -match '(?s)not a fault, the PC is locked.*deck restart: not tonight.*not checked tonight: .*Stream Deck add-on \(the PC is locked\).*Stream Deck restart \(the PC is locked\)')
  Reset-Scenario; $S.items = @(@{ id = 'streamdeck'; name = 'Stream Deck'; state = 'warn'; detail = 'Rig Intro add-on silent for over 2 min'; fix = 'x' })
  $r = Run-Night @{ TestLocked = '0' }
  ok 'unlocked PC: the same silent add-on IS a thing and the restart is asked' ($r.text -match 'Stream Deck: Rig Intro add-on silent' -and ($S.hits -contains '/api/nightly/deck')) "[$($r.text)] hits=$($S.hits -join ' ')"

  # Stream Deck does not come back / add-on silent
  Reset-Scenario; $S.deckComesBack = $false
  $r = Run-Night
  ok 'Stream Deck not back after the restart: the line says so' ($r.text -match 'Stream Deck did not come back after the restart' -and $r.flag -eq '0') "[$($r.text)]"
  Reset-Scenario; $S.addonSilent = $true
  $r = Run-Night
  ok 'app back but the add-on silent: its own sentence' ($r.text -match 'the Stream Deck add-on did not report back after the restart') "[$($r.text)]"
  Reset-Scenario; $S.refuseDeck = $true
  $r = Run-Night
  ok 'irdash refuses the restart (a session started): said, not hidden' ($r.text -match 'the Stream Deck restart was refused') "[$($r.text)]"
  Reset-Scenario; $S.doctorHangs = $true
  $r = Run-Night
  ok 'a Doctor that never finishes: "the rig check did not run", the night goes on to the deck restart' ($r.text -match 'the rig check did not run' -and ($S.hits -contains '/api/nightly/deck')) "[$($r.text)]"

  # the guard busy -> skipped, and nothing else ran
  Reset-Scenario
  $r = Run-Night @{ TestBusy = 'the iRacing sim is running' }
  ok 'guard busy: "skipped, the sim was running", flag 0, exit 0' ($r.text -eq 'Rig check 03:00: skipped, the sim was running' -and $r.flag -eq '0' -and $r.rc -eq 0) "[$($r.text)]"
  ok 'guard busy: nothing else ran (irdash was not asked anything)' ($S.hits.Count -eq 0)
  $r = Run-Night @{ TestBusy = 'a START key was pressed 3 minutes ago' }
  ok 'a START key lately: "skipped, a START key was pressed lately"' ($r.text -eq 'Rig check 03:00: skipped, a START key was pressed lately') "[$($r.text)]"
  Reset-Scenario
  $r = Run-Night @{ TestIdle = 2 }
  ok 'Peter at the PC (2 min since input): "skipped, Peter was at the PC", nothing asked' ($r.text -eq 'Rig check 03:00: skipped, Peter was at the PC' -and $S.hits.Count -eq 0) "[$($r.text)]"
  Set-Content -Encoding ascii (Join-Path $cliDir 'mode.txt') 'simon'
  $r = Run-Night
  ok 'irdeck says sim=True: skipped, the sim was running; irdash not asked' ($r.text -eq 'Rig check 03:00: skipped, the sim was running' -and $S.hits.Count -eq 0) "[$($r.text)]"
  Set-Content -Encoding ascii (Join-Path $cliDir 'mode.txt') 'driving'
  $r = Run-Night
  ok 'irdeck says onTrack=True: skipped, Peter was driving' ($r.text -eq 'Rig check 03:00: skipped, Peter was driving') "[$($r.text)]"
  Set-Content -Encoding ascii (Join-Path $cliDir 'mode.txt') 'silent'
  $r = Run-Night
  ok 'irdeck says nothing: "did not finish (irdeck did not answer)"' ($r.text -eq 'Rig check 03:00: did not finish (irdeck did not answer)') "[$($r.text)]"
  Set-Content -Encoding ascii (Join-Path $cliDir 'mode.txt') 'ok'

  # irdash not answering
  Reset-Scenario; $S.dead = $true
  $r = Run-Night
  ok 'irdash silent: "did not finish (irdash did not answer)", flag 0, exit 0, no stack trace' ($r.text -eq 'Rig check 03:00: did not finish (irdash did not answer)' -and $r.rc -eq 0 -and $r.line -notmatch 'at line|Exception|\.ps1') "[$($r.text)] $($r.out)"
  Reset-Scenario
  $listener.Stop(); $ps.Dispose(); $rs.Dispose(); $listener = $null
  $r = Run-Night
  ok 'nothing listening on the port at all: the same honest line' ($r.text -eq 'Rig check 03:00: did not finish (irdash did not answer)') "[$($r.text)] $($r.out)"

  # the file keeps 60 lines
  $f = Join-Path $outDir 'nightly.txt'
  $n = (Get-Content $f | Where-Object { $_.Trim() }).Count
  1..70 | ForEach-Object { Add-Content -Encoding utf8 $f ("2026-10-01T03:00`t1`tRig check 03:00: old $_") }
  $r = Run-Night @{ TestBusy = 'the iRacing sim is running' }
  $lines = @(Get-Content $f | Where-Object { $_.Trim() })
  ok "the file keeps 60 lines, newest last ($n before, $($lines.Count) now)" ($lines.Count -eq 60 -and $lines[59] -match 'skipped') "count $($lines.Count)"

  # the time limits, in the script text
  $sc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'nightly.ps1'))
  ok 'the script runs at BelowNormal, stops itself after 10 minutes and waits at most 60 s for the Doctor, 120 s for the deck' ($sc -match "BelowNormal" -and $sc -match '\$maxMinutes = 10' -and $sc -match 'TotalSeconds -lt \(60 \* \$k\)' -and $sc -match 'TotalSeconds -lt \(120 \* \$k\)' -and $sc -match '\$k = if \(\$Fast\) \{ 0\.05 \} else \{ 1 \}')
  ok 'the script clicks nothing and starts no sim (no SendKeys, no airace, no startlast, no mouse)' ($sc -notmatch 'SendKeys|airace|startlast|mouse_event|SetCursorPos|rigon')
  ok 'the script uses the guard (Get-RigBusy, idle minutes, the test lock) and exits 0 through Finish' ($sc -match 'Get-RigBusy' -and $sc -match 'IdleMinutes' -and $sc -match "Enter-TestLock 'nightly' 0" -and $sc -match 'exit 0')

  # ================= 3. the wiring in irdash =================
  Assert-RigFree -Where '3. wiring'
  $ird = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
  $ng = [IO.File]::ReadAllText((Join-Path $root 'dash\src\nightly.cs'))
  $bld = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))
  ok 'the part "nightly" is registered at 5000 ms' ($ird -match 'StateBuilder\.Add\("nightly", 5000, 5000, Nightly\.PartJson\)')
  ok 'the clock runs from the irdash tick and never in a test copy' ($ird -match 'if \(!Program\.TestMode\) \{ try \{ Nightly\.Tick\(\)' -and $ng -match 'if \(Program\.TestMode')
  ok '/api/nightly/run answers 409 in a real session and needs the test hook' ($ird -match '(?s)/api/nightly/run.{0,400}Sdk\.RealBusy\(\).{0,200}409.{0,200}Sdk\.TestHook')
  ok '/api/nightly/deck is refused while the rig is busy' ($ird -match '(?s)/api/nightly/deck.{0,600}RigState\.Busy.{0,100}409')
  ok 'the start waits for the rig to be free and the PC idle 10 minutes; BelowNormal, hidden, 12-minute kill' ($ng -match 'RigState\.Busy' -and $ng -match 'IdleMinutes\(\) < 10' -and $ng -match 'BelowNormal' -and $ng -match 'CreateNoWindow = true' -and $ng -match '12 \* 60 \* 1000')
  ok 'nightly=off in irdash.ini stops it (default on)' ($ng -match 'nightly' -and $ng -match '"off"' -and $ng -match 'return true;')
  ok '/api/nightly/deck asks Nightly.TakeDeckRestart (running check + taken once + idle >= NeedIdle 10) before it restarts anything' ($ird -match '(?s)/api/nightly/deck.{0,900}Nightly\.TakeDeckRestart\(\).{0,200}409.{0,200}NightlyDeckRestart' -and $ng -match 'DeckGate\(running, deckTaken, IdleMinutes\(\), NeedIdle\)' -and $ng -match 'NeedIdle = 10' -and $ng -match 'running = true; deckTaken = false')
  ok 'both new files are in dash\build.ps1' ($bld -match 'nightlyrules\.cs' -and $bld -match 'src\\nightly\.cs')
  ok 'no Windows task is made (CLAUDE.md rule 5): no schtasks / Register-ScheduledTask anywhere in the new files' (($ng + $sc) -notmatch 'schtasks|Register-ScheduledTask')
}
finally {
  try { if ($listener) { $listener.Stop() } } catch { }
  try { if ($ps) { $ps.Dispose() } } catch { }
  try { if ($rs) { $rs.Dispose() } } catch { }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
"nightly-test: $script:pass ok, $script:fail FAIL"
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
