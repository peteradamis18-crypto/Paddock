# Paddock HOME (P1): the top screen between sessions.
#   1. /home answers from real data: every personal best equals the quickest official session best of that track in /sessions,
#      the last session is the newest one with laps, the hero picture is served
#   2. the real page in headless Chrome at 1920x1080: numbers equal /career and /home, the hero is drawn, the big button is there,
#      no overlaps between the blocks, no JS errors (picture tests\shots\home.png)
#   3. hidden while driving: a pretend session through the test hook makes the page live and #overlay (HOME) goes away; back after
#      (picture tests\shots\home-driving.png)
# Needs the deployed irdash (dash\build.ps1). Never runs while Peter races (guard.ps1); the test hook refuses then too (409).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$api = 'http://localhost:8199'
$shots = Join-Path $PSScriptRoot 'shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$script:ok = 0; $script:fail = 0
function Check($name, $cond, $detail = '') { if ($cond) { $script:ok++; Write-Output "  ok    $name" } else { $script:fail++; Write-Output "  FAIL  $name $detail" } }
function Section($t) { Assert-RigFree -Where $t; Write-Output ''; Write-Output $t }
function J($u) { (Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 30).Content | ConvertFrom-Json }
function Lap($t) { $t = [double]$t; if ($t -le 0) { return '-' }; $m = [math]::Floor($t / 60); $s = $t - $m * 60; $ss = $s.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture); if ($m -gt 0 -and $s -lt 10) { $ss = '0' + $ss }; if ($m -gt 0) { return "$m`:$ss" } else { return $ss } }

# ---- headless Chrome with the DevTools protocol (the same harness as career-test, its own port) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('home-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9377
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--autoplay-policy=no-user-gesture-required', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0; errors = New-Object System.Collections.Generic.List[string] }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Runtime.enable' @{}
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false }
  $null = Cdp 'Page.navigate' @{ url = $url }
}
function Cdp($method, $params) {
  $c = $script:cdp; $c.id++
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $c.id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
  $null = $c.ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf = New-Object byte[] 262144; $sb = New-Object Text.StringBuilder
    do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $c.ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage)
    $o = $sb.ToString() | ConvertFrom-Json
    if ($o.method -eq 'Runtime.exceptionThrown') { $c.errors.Add($o.params.exceptionDetails.exception.description) }
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Json($expr) { return (Cdp-Eval "JSON.stringify($expr)") | ConvertFrom-Json }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
function Wait-Until($expr, $secs = 15) { $until = (Get-Date).AddSeconds($secs); while ((Get-Date) -lt $until) { $v = Cdp-Eval $expr; if ($v -eq $true -or $v -eq 'true') { return $true }; Start-Sleep -Milliseconds 300 }; return $false }
$lock = Join-Path $root 'dash\deploy.lock'
$hook = Join-Path $root 'dash\test-hook.on'
# the session text at the top of a telemetry file, read with no code from irdash
function Yaml-Of($path) { $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite'); try { $b = New-Object byte[] 144; [void]$fs.Read($b, 0, 144); $n = [BitConverter]::ToInt32($b, 16); $fs.Position = [BitConverter]::ToInt32($b, 20); $yb = New-Object byte[] $n; [void]$fs.Read($yb, 0, $n) } finally { $fs.Close() }; return [Text.Encoding]::GetEncoding(1252).GetString($yb) }
function Yaml-Me($y, $key) { $idx = [regex]::Match($y, '(?m)^\s*DriverCarIdx:\s*(\d+)').Groups[1].Value; $blk = [regex]::Match($y, "(?s)- CarIdx: $idx\s*\r?\n(.*?)(?=\r?\n\s*- CarIdx:|\r?\n\S|$)").Groups[1].Value; return ([regex]::Match($blk, "(?m)^\s*$key`:\s*(.*?)\s*`$").Groups[1].Value).Trim('"') }
$inv = [Globalization.CultureInfo]::InvariantCulture
Enter-TestLock 'home'   # one live test at a time (tests\guard.ps1); released in finally
try {
  Section '0. outings: a test, and a Test Drive that sat in the pit box, are not Peter driving (a pretend cache, no server)'
  $exe = if ($env:HOME_TEST_EXE) { $env:HOME_TEST_EXE } else { Join-Path $root 'dash\irdash.exe' }
  $tele = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
  $scratch = Join-Path $env:TEMP ('home-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $scratch | Out-Null
  $H1 = 36000000000L; $MIN = 600000000L
  # the pretend cache = the real one (rows copied), minus the no-lap rows whose pit-road flag has not been read yet, plus three rows changed or made here
  $rows = New-Object System.Collections.Generic.List[object]; $dropped = 0
  foreach ($line in [IO.File]::ReadAllLines((Join-Path $root 'dash\career-cache.tsv'), [Text.Encoding]::UTF8)) {
    $f = New-Object 'System.Collections.Generic.List[string]'; $f.AddRange([string[]]$line.Split("`t")); while ($f.Count -lt 22) { $f.Add('') }
    $secs = [double]::Parse($f[2], $inv); $laps = [int]$f[4]
    if ($laps -eq 0 -and $secs -ge 30 -and ($f[21] -eq '' -or $f[21] -eq '1')) { $dropped++; continue }     # '' = not read yet, 1 = the first draft's flag: both are read again by irdash
    $rows.Add([pscustomobject]@{ f = $f; file = $f[0].Substring(0, $f[0].LastIndexOf('|')); secs = $secs; laps = $laps; start = $(if ($f[18]) { [long]$f[18] } else { [long]$f[1] }); tag = '' })
  }
  $realRows = @($rows | Where-Object { $_.laps -gt 0 -and $_.secs -ge 30 })
  $A = $realRows | Sort-Object start -Descending | Select-Object -First 1
  $maxStart = [long]($rows | Sort-Object start -Descending | Select-Object -First 1).start       # not Measure-Object: that gives a double and loses the last digits
  $minStart = [long]($rows | Sort-Object start | Select-Object -First 1).start
  $B = $rows | Where-Object { $_.f[6] -ne $A.f[6] -and $_.laps -gt 0 -and (Test-Path -LiteralPath (Join-Path $tele $_.file)) } | Sort-Object start -Descending | Select-Object -First 1
  Check "the real cache has a session with laps to be his last outing ($($A.file)) and a second car's file for the idle one ($($B.file)); $dropped no-lap rows not yet read for the pit-road flag are left out" ($A -and $B -and (Test-Path -LiteralPath (Join-Path $tele $A.file)))
  # B: that other car's session turned into "120 s in the car, no lap, never left pit road", the newest of all
  $bStart = $maxStart + $H1; $B.tag = 'idle'; $B.f[2] = '120'; $B.f[3] = '0'; $B.f[4] = '0'; $B.f[13] = '0.000'; $B.f[18] = [string]$bStart; $B.f[1] = [string]($bStart + 120 * 10000000L); $B.f[21] = '0'; $B.laps = 0; $B.secs = 120; $B.start = $bStart
  # C: a session WITH laps (3), newer still, in a car no real session has: only a test-started window can keep it out
  $cStart = $maxStart + 2 * $H1; $cf = New-Object 'System.Collections.Generic.List[string]'; $cf.AddRange([string[]]$A.f)
  $cf[0] = 'pl1-test-run.ibt|1'; $cf[2] = '300'; $cf[3] = '5000'; $cf[4] = '3'; $cf[6] = 'Test Car'; $cf[7] = 'Test Track'; $cf[10] = '99'; $cf[13] = '90.000'; $cf[18] = [string]$cStart; $cf[1] = [string]($cStart + 300 * 10000000L); $cf[21] = '2'
  $rows.Add([pscustomobject]@{ f = $cf; file = 'pl1-test-run.ibt'; secs = 300.0; laps = 3; start = $cStart; tag = 'test' })
  # D: newest real outing, no completed lap, but it left pit road.
  $dStart = $maxStart + 3 * $H1; $df = New-Object 'System.Collections.Generic.List[string]'; $df.AddRange([string[]]$A.f)
  $df[0] = 'no-lap-outing.ibt|1'; $df[2] = '90'; $df[3] = '0'; $df[4] = '0'; $df[6] = 'Outing Car'; $df[7] = 'Outing Track'; $df[13] = '0.000'; $df[18] = [string]$dStart; $df[1] = [string]($dStart + 90 * 10000000L); $df[21] = '2'
  $rows.Add([pscustomobject]@{ f = $df; file = 'no-lap-outing.ibt'; secs = 90.0; laps = 0; start = $dStart; tag = 'no-lap' })
  $cache = Join-Path $scratch 'career-cache.tsv'
  [IO.File]::WriteAllText($cache, ((($rows | ForEach-Object { ($_.f -join "`t") }) -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
  $runCovers = Join-Path $scratch 'run-covers.txt'; [IO.File]::WriteAllText($runCovers, "$($cStart - $MIN)`t$($cStart + 5 * $MIN)`r`n")
  $runOpen = Join-Path $scratch 'run-open.txt'; [IO.File]::WriteAllText($runOpen, "$($cStart - 10 * $MIN)`t`r`n")                     # still open: counts for 3 hours at most
  $runStale = Join-Path $scratch 'run-stale.txt'; [IO.File]::WriteAllText($runStale, "$($cStart - 4 * $H1)`t`r`n")                       # open for 4 hours: too old to be this session
  $runElsewhere = Join-Path $scratch 'run-elsewhere.txt'; [IO.File]::WriteAllText($runElsewhere, "$($minStart - 48 * $H1)`t$($minStart - 47 * $H1)`r`n")   # well before every real session: covers nothing
  function Run-Home($tests) {
    $out = Join-Path $scratch ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    $p = Start-Process -FilePath $exe -ArgumentList @('--home', '--cache', "`"$cache`"", '--tests', "`"$tests`"", '--telemetry', "`"$tele`"", '--out', "`"$out`"") -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0 -or -not (Test-Path $out)) { throw "irdash --home failed (exit $($p.ExitCode))" }
    return ([IO.File]::ReadAllText($out, [Text.Encoding]::UTF8) | ConvertFrom-Json)
  }
  function Run-MeYaml($yaml) {
    $yf = Join-Path $scratch ('me-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.yaml')
    $out = Join-Path $scratch ('me-out-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    [IO.File]::WriteAllText($yf, $yaml, [Text.Encoding]::GetEncoding(28591))
    $p = Start-Process -FilePath $exe -ArgumentList @('--home', '--me-yaml', "`"$yf`"", '--out', "`"$out`"") -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0 -or -not (Test-Path $out)) { throw "irdash --home --me-yaml failed (exit $($p.ExitCode))" }
    return ([IO.File]::ReadAllText($out, [Text.Encoding]::UTF8) | ConvertFrom-Json).me
  }
  Section '0a. DriverCarIdx YAML parser: production path with decoy and damaged fields'
  $yamlRows = "DriverCarIdx: 7`nDriverInfo:`n  Drivers:`n  - CarIdx: 2`n    UserName: Wrong Driver`n    CarNumber: 91`n    TeamName: Decoy Team`n    CarScreenName: Decoy Car`n    CarPath: decoy`n  - CarIdx: 7`n    UserName: Peter Fixture`n    CarNumber: 4`n    TeamName: Pratt Miller Motorsports`n    CarScreenName: Corvette Fixture`n    CarPath: corvettez06rgt3`n"
  $parsedMe = Run-MeYaml $yamlRows
  Check 'production YAML parser selects only the DriverCarIdx row' ($parsedMe.name -eq 'Peter Fixture' -and $parsedMe.num -eq '4' -and $parsedMe.car -eq 'Corvette Fixture' -and $parsedMe.team -eq 'Pratt Miller Motorsports' -and $parsedMe.path -eq 'corvettez06rgt3') ($parsedMe | ConvertTo-Json -Compress)
  $yamlMissing = "DriverCarIdx: 7`nDrivers:`n  - CarIdx: 2`n    UserName: Wrong Driver`n    CarNumber: 91`n    TeamName: Decoy Team`n  - CarIdx: 7`n    UserName:`n    CarNumber:`n    TeamName:`n    CarScreenName:`n    CarPath:`n"
  $missingMe = Run-MeYaml $yamlMissing
  Check 'missing row fields stay empty without borrowing the decoy or fixed team text' ($missingMe.name -eq '' -and $missingMe.num -eq '' -and $missingMe.team -eq '' -and $missingMe.car -eq '' -and $missingMe.path -eq '') ($missingMe | ConvertTo-Json -Compress)
  $malformedMe = Run-MeYaml "not: [valid yaml structure`nDriverCarIdx: not-an-index`n"
  Check 'malformed YAML returns null identity without throwing or inventing fields' ($null -eq $malformedMe)
  function Expect($withC) {
    # what counts: 30 s or more in the car, and not (no lap and never off pit road), and not the test-started one when a test run covers it
    $inc = @($rows | Where-Object { $_.secs -ge 30 -and -not ($_.laps -eq 0 -and $_.f[21] -eq '0') -and ($withC -or $_.tag -ne 'test') })
    $newest = $inc | Sort-Object { [long]$_.f[1] } -Descending | Select-Object -First 1
    $wk = (Get-Date).Date.AddDays(-(([int](Get-Date).DayOfWeek + 6) % 7)); $inWeek = @($inc | Where-Object { ([DateTime]::new($_.start, 'Utc')).ToLocalTime() -ge $wk })
    # P0-04: this week's personal bests by the same rule as data.cs WeekJson - a car+track+layout whose best lap is this week and beat an earlier
    # one counts as a PB, a first lap on a new combination counts separately; short runs are already left out of $inc
    $best = @{}; $before = @{}
    foreach ($r in $inc) {
      $b = [double]$r.f[13]; if ($b -le 0 -or $r.f[6].Length -eq 0) { continue }
      $key = "$($r.f[6])|$($r.f[7])|$($r.f[16])"; $d = ([DateTime]::new([long]$r.start, 'Utc')).ToLocalTime()
      if ($d -lt $wk) { $before[$key] = $true }
      $cur = $best[$key]
      if (-not $cur -or $b -lt [double]$cur.b - 0.0005 -or ([math]::Abs($b - [double]$cur.b) -le 0.0005 -and [long]$r.start -lt [long]$cur.t)) { $best[$key] = @{ b = $b; t = [long]$r.start } }
    }
    $pbs = 0; $fresh = 0
    foreach ($k in $best.Keys) { if (([DateTime]::new([long]$best[$k].t, 'Utc')).ToLocalTime() -ge $wk) { if ($before[$k]) { $pbs++ } else { $fresh++ } } }
    return @{ sessions = $inc.Count; laps = ($inc | Measure-Object laps -Sum).Sum; hours = ($inc | Measure-Object secs -Sum).Sum / 3600; lastTrack = $newest.f[7]; lastCar = $newest.f[6];
              weekSessions = $inWeek.Count; weekLaps = ($inWeek | Measure-Object laps -Sum).Sum; weekHours = ($inWeek | Measure-Object secs -Sum).Sum / 3600; weekPbs = $pbs; weekFresh = $fresh }
  }
  function Sess($res, $file) { @($res.sessions.sessions | Where-Object { $_.file -eq $file }) | Select-Object -First 1 }
  $yA = Yaml-Of (Join-Path $tele $A.file); $numA = Yaml-Me $yA 'CarNumber'; $carA = Yaml-Me $yA 'CarScreenName'
  $r1 = Run-Home $runCovers; $e1 = Expect $false
  Check "the idle session ($($B.file): 120 s, no lap, never left pit road, the newest) is not the last session, not the car on HOME: last = $($A.file)" ($r1.home.last.file -eq $A.file -and $r1.home.me.file -eq $A.file) "last=$($r1.home.last.file) me=$($r1.home.me.file)"
  Check "HOME's car is that last real session's: $carA, and the number box is the number in that same session's text ($numA)" ($r1.home.me.car -eq $carA -and $r1.home.num -eq $numA -and $r1.home.me.num -eq $numA -and $numA) "car=$($r1.home.me.car) num=$($r1.home.num) me.num=$($r1.home.me.num) yaml=$carA/$numA"
  Check "the session a test started (3 laps, newest, in a 'Test Car') is not the last session either: the test run covers its start" ($r1.home.last.car -ne 'Test Car')
  $sa = Sess $r1 $A.file; $sb = Sess $r1 $B.file; $sc = Sess $r1 'pl1-test-run.ibt'
  Check 'the sessions list marks the idle one and the test-started one as short runs, and the real one is not' ($sb.short -eq $true -and $sc.short -eq $true -and $sa.short -eq $false) "A=$($sa.short) B=$($sb.short) C=$($sc.short)"
  Check "no outing: the last outing is $($e1.lastCar) at $($e1.lastTrack) (the newest session that counts), not the idle car" ($r1.career.lastCar -eq $e1.lastCar -and $r1.career.lastTrack -eq $e1.lastTrack) "got '$($r1.career.lastCar)' at '$($r1.career.lastTrack)'"
  Check "no seat time: $($e1.sessions) sessions, $($e1.laps) laps, $([math]::Round($e1.hours, 1)) h in the career - the idle 2 minutes and the test's 5 are not in them" ($r1.career.sessions -eq $e1.sessions -and $r1.career.laps -eq $e1.laps -and [math]::Abs($r1.career.hours - $e1.hours) -lt 0.06) "got $($r1.career.sessions) / $($r1.career.laps) / $($r1.career.hours)"
  Check "THIS WEEK leaves them out too: $($e1.weekSessions) sessions, $($e1.weekLaps) laps" ($r1.career.week.sessions -eq $e1.weekSessions -and $r1.career.week.laps -eq $e1.weekLaps) "got $($r1.career.week.sessions) / $($r1.career.week.laps)"
  # P0-04: /home carries THIS WEEK (the same numbers /career serves) and LAST OUTING, worked by hand from the pretend cache
  Check "THIS WEEK on /home is the hand calculation: $($e1.weekSessions) sessions, $($e1.weekLaps) laps, $([math]::Round($e1.weekHours, 1)) h, $($e1.weekPbs) PB" ($r1.home.week.sessions -eq $e1.weekSessions -and $r1.home.week.laps -eq $e1.weekLaps -and [math]::Abs($r1.home.week.hours - $e1.weekHours) -lt 0.06 -and $r1.home.week.pbs -eq $e1.weekPbs) "got $($r1.home.week.sessions) / $($r1.home.week.laps) / $($r1.home.week.hours) / $($r1.home.week.pbs)"
  Check "THIS WEEK on /home equals the week /career serves" ($r1.home.week.hours -eq $r1.career.week.hours -and $r1.home.week.laps -eq $r1.career.week.laps -and $r1.home.week.pbs -eq $r1.career.week.pbs) "home $($r1.home.week.hours)/$($r1.home.week.laps)/$($r1.home.week.pbs) vs career $($r1.career.week.hours)/$($r1.career.week.laps)/$($r1.career.week.pbs)"
  Check "LAST OUTING selects the newest non-short outing with laps; zero-lap drives are not outings" ($r1.home.lastOuting.file -eq $A.file -and $r1.home.lastOuting.laps -gt 0) "got $($r1.home.lastOuting.file) / $($r1.home.lastOuting.laps) laps"
  $expectedType = if ($A.f[19]) { $A.f[19] } else { $A.f[8] }
  $outingFields = @($r1.home.lastOuting.PSObject.Properties | ForEach-Object { $_.Name })
  Check "LAST OUTING date and type match the selected cache row; finish is unknown and incidents are omitted" ($r1.home.lastOuting.date -eq ([DateTime]::new([long]$A.start, 'Utc')).ToLocalTime().ToString('yyyy-MM-dd HH:mm', $inv) -and $r1.home.lastOuting.type -eq $expectedType -and $outingFields -contains 'finish' -and $null -eq $r1.home.lastOuting.finish -and $outingFields -notcontains 'incidents') "date=$($r1.home.lastOuting.date) type=$($r1.home.lastOuting.type) wanted=$expectedType fields=$($outingFields -join ',')"
  $r2 = Run-Home $runElsewhere; $e2 = Expect $true; $sc2 = Sess $r2 'pl1-test-run.ibt'
  Check 'without a test run, its session counts and is last; the zero-lap record remains excluded from LAST OUTING' ($r2.home.last.file -eq 'pl1-test-run.ibt' -and $r2.home.lastOuting.file -eq 'pl1-test-run.ibt' -and $r2.home.last.car -eq 'Test Car' -and $sc2.short -eq $false) "last=$($r2.home.last.file) lastOuting=$($r2.home.lastOuting.file)"
  Check "... and it adds its seat time and laps ($($e2.sessions) sessions, $($e2.laps) laps), the idle one still does not" ($r2.career.sessions -eq $e2.sessions -and $r2.career.laps -eq $e2.laps -and (Sess $r2 $B.file).short -eq $true) "got $($r2.career.sessions) / $($r2.career.laps)"
  $r3 = Run-Home $runOpen
  Check 'a test run that has not closed yet (irdash was stopped mid-run) still covers the session, for up to 3 hours' ($r3.home.last.file -eq $A.file -and (Sess $r3 'pl1-test-run.ibt').short -eq $true)
  $r4 = Run-Home $runStale
  Check 'a run left open for 4 hours does not cover it (it cannot hide his real sessions for ever)' ($r4.home.last.file -eq 'pl1-test-run.ibt' -and (Sess $r4 'pl1-test-run.ibt').short -eq $false)
  Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue

  Section '1. /home from real data'
  # PL-1: the background scan reads, two minutes after irdash starts, whether the car ever left pit road in every session that has no lap
  # The file itself is read here by separate code (one sample a second, the car in the world and off pit road for 3 in a row = it left pit road): every
  # session that has no lap and never moved must be a short run exactly when the car never left pit road (a Test Drive that sat in the box).
  Add-Type -TypeDefinition @'
using System; using System.IO; using System.Collections.Generic; using System.Text;
public static class PitProbe {
  public static bool LeftPit(string path) {
    using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
      byte[] h = new byte[144]; fs.Read(h, 0, 144);
      int numVars = BitConverter.ToInt32(h, 24), varOff = BitConverter.ToInt32(h, 28), bufLen = BitConverter.ToInt32(h, 36), dataOff = BitConverter.ToInt32(h, 52), step = BitConverter.ToInt32(h, 8);
      if (step <= 0) step = 60;
      long records = (fs.Length - dataOff) / bufLen;
      byte[] vh = new byte[numVars * 144]; fs.Position = varOff; fs.Read(vh, 0, vh.Length);
      Dictionary<string, int[]> vars = new Dictionary<string, int[]>();
      for (int i = 0; i < numVars; i++) { int b = i * 144; int len = Array.IndexOf(vh, (byte)0, b + 16, 32) - (b + 16); if (len < 0) len = 32; vars[Encoding.ASCII.GetString(vh, b + 16, len)] = new int[] { BitConverter.ToInt32(vh, b), BitConverter.ToInt32(vh, b + 4) }; }
      int[] on, pit, surf; vars.TryGetValue("IsOnTrack", out on); vars.TryGetValue("OnPitRoad", out pit); vars.TryGetValue("PlayerTrackSurface", out surf);
      if (on == null || pit == null) return true;
      byte[] buf = new byte[bufLen]; int run = 0;
      for (long r = 0; r < records; r += step) {
        fs.Position = dataOff + r * bufLen; if (fs.Read(buf, 0, bufLen) < bufLen) break;
        if (buf[on[1]] == 0) continue;
        bool off = buf[pit[1]] == 0 && (surf == null || BitConverter.ToInt32(buf, surf[1]) >= 0);
        if (off) { if (++run >= 3) return true; } else run = 0;
      }
      return false;
    }
  }
}
'@
  $tele1 = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
  $until = (Get-Date).AddMinutes(6)
  do {
    $s = (J "$api/sessions").sessions; $box = @($s | Where-Object { $_.laps -eq 0 -and $_.secs -ge 30 -and [double]$_.km -lt 0.05 -and -not $_.gone })
    $wrong = @(); $nBox = 0; $nTrack = 0
    foreach ($b in $box) { $left = [PitProbe]::LeftPit((Join-Path $tele1 $b.file)); if ($left) { $nTrack++ } else { $nBox++ }; if ($b.short -eq $left) { $wrong += "$($b.file) (short=$($b.short), left pit road=$left)" } }
    if ($wrong.Count -eq 0) { break }; Start-Sleep -Seconds 10
  } while ((Get-Date) -lt $until)
  Check "the $($box.Count) sessions with no lap that never moved: the $nBox that sat in the pit box are short runs, the $nTrack that sat on the track (off pit road) are not - by the file itself" ($wrong.Count -eq 0 -and $nBox -ge 1) ($wrong -join '; ')
  $h = J "$api/home"; $s = (J "$api/sessions").sessions; $c = J "$api/career"
  $of = J "$api/official"; $rw = J "$api/realworld"
  $mineRows = @($of.deck | Where-Object { $_.mine -and $_.ownedCar -and $_.ownedTrack } | Sort-Object { [DateTimeOffset]::Parse($_.t).UtcDateTime })
  $firstTime = if ($mineRows.Count) { [DateTimeOffset]::Parse($mineRows[0].t).UtcDateTime } else { [DateTime]::MaxValue }
  $earliestRows = @($mineRows | Where-Object { [DateTimeOffset]::Parse($_.t).UtcDateTime -eq $firstTime })
  Check 'NEXT RACE has an earliest eligible owned series with absolute local and UTC starts' ($h.nextRace -and $earliestRows.Count -gt 0 -and @($earliestRows | Where-Object { $_.series -eq $h.nextRace.series -and $_.car -eq $h.nextRace.car -and $_.track -eq $h.nextRace.track }).Count -gt 0 -and $h.nextRace.localStart -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$' -and $h.nextRace.utcStart -match 'Z$' -and $h.nextRace.countdownSeconds -ge 0 -and $h.nextRace.ownedCar -and $h.nextRace.ownedTrack) "home=$($h.nextRace | ConvertTo-Json -Compress)"
  $barcelona = @($rw.events | Where-Object { $_.event -eq '6 Hours of Barcelona' -and $_.source -like '*fiawec.com*' -and ($_.localStart -or ($_.eventDate -eq '2026-10-16' -and $_.tbc)) })
  $timedReal = @($rw.events | Where-Object { $_.session -and $_.session -ne 'Event' })
  Check 'real-world cache is fresh and includes all 15 published timed sessions' ($rw.fresh -and $rw.asOf -and $timedReal.Count -eq 15) "asOf=$($rw.asOf) sessions=$($timedReal.Count)"
  $notShort = @($s | Where-Object { -not $_.short } | Sort-Object { [long]$_.ts } -Descending)
  Check "the last outing on the idle screen is the newest session that counts ($($notShort[0].car) at $($notShort[0].track)), not a session that sat in the box" ($c.lastTrack -eq $notShort[0].track -and $c.lastCar -eq $notShort[0].car) "career says '$($c.lastCar)' at '$($c.lastTrack)'"
  $wk = (Get-Date).Date.AddDays(-(([int](Get-Date).DayOfWeek + 6) % 7)); $weekS = @($notShort | Where-Object { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.ts).LocalDateTime -ge $wk })
  $weekLapTotal = if ($weekS.Count) { [int](($weekS | Measure-Object laps -Sum).Sum) } else { 0 }
  Check "THIS WEEK counts only sessions that count: $($weekS.Count) sessions, $weekLapTotal laps" ($c.week.sessions -eq $weekS.Count -and $c.week.laps -eq $weekLapTotal) "career week $($c.week.sessions) / $($c.week.laps)"
  # P0-04: /home carries THIS WEEK and LAST OUTING from the same career cache (short runs left out)
  Check "THIS WEEK on /home equals the week /career serves ($($c.week.hours) h, $($c.week.laps) laps, $($c.week.pbs) PB)" ($h.week.hours -eq $c.week.hours -and $h.week.laps -eq $c.week.laps -and $h.week.pbs -eq $c.week.pbs) "home $($h.week.hours)/$($h.week.laps)/$($h.week.pbs) vs career $($c.week.hours)/$($c.week.laps)/$($c.week.pbs)"
  $newestLaps = $s | Where-Object { -not $_.short -and $_.laps -gt 0 } | Sort-Object { [long]$_.ts } -Descending | Select-Object -First 1
  Check "LAST OUTING on /home is the newest non-short session with laps ($($newestLaps.car) at $($newestLaps.track)); zero-lap records are excluded" ($h.lastOuting.file -eq $newestLaps.file -and $h.lastOuting.car -eq $newestLaps.car -and $h.lastOuting.track -eq $newestLaps.track) "home '$($h.lastOuting.file)' vs '$($newestLaps.file)'"
  Check 'name and number' ($h.name -and $h.num) "name='$($h.name)' num='$($h.num)'"
  Check 'personal bests present' ($h.pbs.Count -gt 0 -and $h.pbCount -ge $h.pbs.Count) "pbs=$($h.pbs.Count)"
  $bad = @()
  foreach ($p in $h.pbs) {
    $mine = @($s | Where-Object { $_.track -eq $p.track -and $_.config -eq $p.config -and $_.best -gt 0 } | ForEach-Object { [double]$_.best })
    $min = if ($mine.Count) { ($mine | Measure-Object -Minimum).Minimum } else { -1 }
    if ([math]::Abs($min - [double]$p.best) -gt 0.0005) { $bad += "$($p.track): home $($p.best) vs sessions $min" }
    if (-not ($p.best -gt 0)) { $bad += "$($p.track): no time" }
  }
  Check 'every PB equals the quickest official session best of that track' ($bad.Count -eq 0) ($bad -join '; ')
  $newest = $s | Where-Object { $_.laps -gt 0 -and -not $_.short } | Sort-Object { [long]$_.ts } -Descending | Select-Object -First 1
  Check 'last session = the newest session with laps (a short run never is)' ($h.last -and $newest -and $h.last.file -eq $newest.file) "home '$($h.last.file)' vs '$($newest.file)'"
  Check 'last session carries car, track, laps, when' ($h.last.car -and $h.last.track -and $h.last.laps -gt 0 -and $h.last.ago)
  Check 'career numbers come from /career' ($c.hours -gt 0 -and $c.laps -gt 0 -and $c.sessions -gt 0)
  Check 'hero picture named' ($h.hero.src -and $h.hero.kind -ne 'none') "kind=$($h.hero.kind)"
  $img = Invoke-WebRequest -UseBasicParsing "$api/home/hero" -TimeoutSec 30
  Check '/home/hero is a picture' ($img.StatusCode -eq 200 -and $img.Headers['Content-Type'] -like 'image/*' -and $img.Content.Length -gt 50000) "$($img.Headers['Content-Type']) $($img.Content.Length) bytes"
  Check 'a stand-in picture carries its credit' ($h.hero.kind -ne 'standin' -or $h.hero.credit -like 'Photo:*') "credit='$($h.hero.credit)'"
  Check 'phone state is there' ($null -ne $h.phone.allowed -and $h.phone.how -like '*phone-allow.cmd')
  # P4: his car in his own colours, from the session text at the top of his newest telemetry file (the YAML is read here with no code from irdash)
  $meOk = $false; $meDet = 'no "me" in /home'; $yDz = ''; $yPath = ''; $yCar = ''
  if ($h.me -and $h.me.file) {
    $mePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('iRacing\telemetry\' + $h.me.file)
    if (Test-Path -LiteralPath $mePath) {
      $y = Yaml-Of $mePath; $idx = [regex]::Match($y, '(?m)^\s*DriverCarIdx:\s*(\d+)').Groups[1].Value
      $blk = [regex]::Match($y, "(?s)- CarIdx: $idx\s*\r?\n(.*?)(?=\r?\n\s*- CarIdx:|\r?\n\S|$)").Groups[1].Value
      $yDz = [regex]::Match($blk, '(?m)^\s*CarDesignStr:\s*(.*?)\s*$').Groups[1].Value.ToLowerInvariant(); $yPath = [regex]::Match($blk, '(?m)^\s*CarPath:\s*(.*?)\s*$').Groups[1].Value; $yCar = [regex]::Match($blk, '(?m)^\s*CarScreenName:\s*(.*?)\s*$').Groups[1].Value
      $meOk = ($h.me.dz -ceq $yDz -and $h.me.path -ceq $yPath -and $h.me.car -ceq $yCar -and $yDz -match '^\d+,[0-9a-f]{6}'); $meDet = "me=$($h.me.car) '$($h.me.dz)' vs yaml '$yCar' '$yDz'"
    } else { $meDet = "the file $($h.me.file) is not there" }
  }
  Check "/home carries his own car as his newest session's text has it: $($h.me.car), CarPath $($h.me.path), livery $($h.me.dz)" $meOk $meDet
  Check 'that session is one of the sessions /sessions lists' (@($s | Where-Object { $_.file -eq $h.me.file }).Count -eq 1) "file=$($h.me.file)"
  # PL-1: the car on HOME is the car of his last REAL session, and the number box is the number in that same session's text
  $yNum = if ($h.me -and $h.me.file -and (Test-Path -LiteralPath $mePath)) { Yaml-Me $y 'CarNumber' } else { '' }
  Check "the car on HOME is the last real session's ($($h.last.file)) and the number box is that session's number ($yNum)" ($yNum -and $h.num -eq $yNum -and $h.me.num -eq $yNum -and $h.me.file -eq $h.last.file) "num=$($h.num) me.num=$($h.me.num) yaml=$yNum me=$($h.me.file) last=$($h.last.file)"

  Section '2. the page in headless Chrome (1920x1080): HOME v3 - live data, his car, the one button, READY, the states'
  # The layout itself (grid, type sizes, overlaps, eight states) is measured offline by tests\home-v3-test.ps1. Here: the
  # real page against the real irdash - the numbers on screen equal the endpoints, and every control does what it says.
  Add-Type -AssemblyName System.Drawing
  Cdp-Open "$api/v2/"
  $drawn = Wait-Until "!!document.querySelector('#homeWeek b') && !!document.querySelector('#homeLast .val') && !!document.querySelector('#homeRace .lbl') && !!document.querySelector('#homeWeekend .lbl') && !!document.querySelector('#idleRig .head') && !document.getElementById('homeNext').hidden" 20
  Check 'HOME drew its three bands (button, READY, next race, last outing, this week, watch)' $drawn
  $null = Cdp-Eval "window.__homeTick = Home.tick; clearInterval(Home.tickTimer); clearInterval(Home.nextTimer); clearInterval(Home.phoneTimer); Home.tick = async function(){ return true; }; true"
  Start-Sleep -Seconds 2
  Check 'the overlay (HOME) is shown while no session runs' ((Cdp-Eval "document.getElementById('overlay').classList.contains('show')") -eq $true)
  $dom = Cdp-Json "({ name: (document.querySelector('#homeDriver .name') || document.querySelector('#homeCar .big') || {}).textContent || '', num: (document.querySelector('#homeDriver .num') || document.querySelector('#homeCar .big i') || {}).textContent || '', week: Array.from(document.querySelectorAll('#homeWeek b')).map(e => e.firstChild.textContent.trim()), weekLabel: (document.querySelector('#homeWeek .lbl') || {}).textContent || '', lastLabel: (document.querySelector('#homeLast > .lbl') || {}).textContent || '', lastDet: (document.querySelector('#homeLast .det') || {}).textContent || '', lastBest: ((document.querySelector('#homeLast .val b') || {}).firstChild || {}).textContent || '', review: !!document.getElementById('homeReview'), head: (document.querySelector('#idleRig .head b') || {}).textContent || '', rows: Array.from(document.querySelectorAll('#idleRig .row')).map(r => r.querySelector('.k').textContent + '=' + r.querySelector('.v').textContent), clock: document.getElementById('idleClock').textContent })"
  Check 'driver name on screen equals /home' ($dom.name -match [regex]::Escape($h.name)) "'$($dom.name)'"
  Check 'number on screen equals /home and the car shown (me.num)' ($dom.num -eq $h.num -and $dom.num -eq $h.me.num) "'$($dom.num)' vs '$($h.num)' / '$($h.me.num)'"
  Check "the clock is New York time, 12-hour, marked ET ('$($dom.clock)')" ($dom.clock -match '^\d{1,2}:\d{2} (AM|PM) ET$')
  Check "READY says one word and lists Recording and Phone ('$($dom.head)': $($dom.rows -join ', '))" ($dom.head.Length -gt 0 -and @($dom.rows | Where-Object { $_ -like 'Recording=*' }).Count -eq 1 -and @($dom.rows | Where-Object { $_ -like 'Phone=*' }).Count -eq 1)
  $rec = J "$api/vault/recorder"
  $recRow = @($dom.rows | Where-Object { $_ -like 'Recording=*' })[0]
  Check "the Recording row follows irdash's capture verdict ($($rec.capture.state), $([math]::Round([double]$rec.freeGb)) GB free): '$recRow'" ((-not $rec.enabled -and $recRow -match 'Off') -or ($rec.capture.state -eq 'recording' -and $recRow -match '^Recording=On ') -or ($rec.capture.state -in @('idle', 'starting') -and $recRow -match ('^Recording=(Ready|Disk low)'))) "row='$recRow'"

  Section '2a. his car: iRacing''s own picture at native size, or his name in clean type - never a drawing'
  $cardFixture = @'
(() => {
  const original = Home.home, oldPic = window.PCarPic;
  window.__picCalls = 0; window.__picWidth = 0;
  window.PCarPic = { known: () => ({ corvettez06rgt3: 1 }), key: p => p, html: o => { window.__picCalls++; window.__picWidth = o.w; return '<div class="cpic" data-fixture="official"></div>'; }, refresh: () => {}, ready: () => Promise.resolve() };
  Home.home = Object.assign({}, original, { name: 'Peter Fixture', num: '4', me: { name: 'Peter Fixture', num: '4', car: 'Corvette Fixture', path: 'corvettez06rgt3' } });
  Home.draw();
  const read = () => ({ row: document.getElementById('homeDriver').innerText.replace(/\s+/g, ' ').trim(), frame: !!document.querySelector('#homeCar .cpic'), big: (document.querySelector('#homeCar .big') || {}).textContent || '', calls: window.__picCalls, width: window.__picWidth, svg: document.querySelectorAll('#homeCar svg, svg.pcar').length });
  const cached = read();
  Home.home = Object.assign({}, original, { me: { name: 'Peter Fixture', num: '4', car: 'Corvette Fixture', path: 'unavailable' } });
  window.PCarPic = { known: () => ({}), key: p => p, html: () => { window.__picCalls++; return ''; }, refresh: () => {}, ready: () => Promise.resolve() };
  Home.draw(); const absent = read();
  Home.home = Object.assign({}, original, { me: null });
  Home.draw(); const empty = read();
  Home.home = original; window.PCarPic = oldPic; Home.draw();
  return { cached, absent, empty };
})()
'@
  $fixture = Cdp-Json $cardFixture
  Check 'with a picture: the official picture is asked for at its native 480 px, and the name row sits under the button' ($fixture.cached.frame -and $fixture.cached.calls -eq 1 -and $fixture.cached.width -eq 480 -and $fixture.cached.row -match 'Peter Fixture') ($fixture.cached | ConvertTo-Json -Compress)
  Check 'no picture for that car: his number and name take the car slot in clean type, no frame, no drawing' (-not $fixture.absent.frame -and $fixture.absent.big -match '4' -and $fixture.absent.big -match 'Peter Fixture' -and $fixture.absent.svg -eq 0) ($fixture.absent | ConvertTo-Json -Compress)
  Check 'no identity at all: nothing is invented (no name, number or picture)' (-not $fixture.empty.frame -and -not $fixture.empty.big -and -not $fixture.empty.row) ($fixture.empty | ConvertTo-Json -Compress)
  $nocar = Cdp-Json "({ pcars: document.querySelectorAll('svg.pcar').length, api: typeof window.PCars, dormant: typeof window.PCarsDormant, hero: !!document.getElementById('heroImg') })"
  Check "no DRAWN car and no stock photo on HOME (svg.pcar $($nocar.pcars), window.PCars $($nocar.api), hero photo element present: $($nocar.hero))" ($nocar.pcars -eq 0 -and $nocar.api -eq 'undefined' -and -not $nocar.hero)

  Section '2b. the numbers on screen equal the endpoints'
  $sched = Cdp-Json "({ race: document.getElementById('homeRace').innerText, weekend: document.getElementById('homeWeekend').innerText })"
  if ($h.nextRace) { Check "NEXT RACE shows the published series and track ($($h.nextRace.series), $($h.nextRace.track))" ($sched.race -match [regex]::Escape($h.nextRace.series) -and $sched.race -match [regex]::Escape($h.nextRace.track)) ($sched.race -replace '\s+', ' ') }
  else { Check 'no next race: says so, invents nothing' ($sched.race -match 'No race published') }
  $firstReal = @($timedReal | Sort-Object localStart | Select-Object -First 1)[0]
  Check "WATCH shows the published schedule ($($firstReal.series) first), New York times, never the word Live" ($sched.weekend -match [regex]::Escape($firstReal.series) -and $sched.weekend -match '\d{1,2}:\d{2} (AM|PM)' -and $sched.weekend -notmatch '\bLive\b') ($sched.weekend -replace '\s+', ' ')
  Check "THIS WEEK on screen equals /home week: $($dom.week -join ' ') (hours, laps, PBs)" (@($dom.week).Count -ge 3 -and $dom.week[0] -eq ([double]$h.week.hours).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) -and ($dom.week[1] -replace ',', '') -eq "$($h.week.laps)" -and ($dom.week[2] -replace ',', '') -eq "$($h.week.pbs)") "week='$($dom.week -join ' ')' vs $($h.week.hours)/$($h.week.laps)/$($h.week.pbs)"
  Check "the THIS WEEK heading is there ('$($dom.weekLabel)')" ($dom.weekLabel -eq 'This week')
  Check "LAST OUTING on screen equals /home lastOuting: '$($dom.lastDet)' ($($dom.lastBest))" ($dom.lastLabel -like 'Last outing*' -and $dom.lastDet -like "$($h.lastOuting.track)*" -and (-not $h.lastOuting.best -or $dom.lastBest -eq (Lap $h.lastOuting.best)) -and $dom.review) "label='$($dom.lastLabel)' det='$($dom.lastDet)' best='$($dom.lastBest)'"
  # 2026-10-11: an invisible full-screen layer swallowed every click on HOME. Every visible control must receive a click at its centre.
  $clk = Cdp-Json "(function(){var bad=[],n=0;[].forEach.call(document.querySelectorAll('#overlay button, #overlay a, #overlay .idle-link, #overlay [data-act]'),function(el){var r=el.getBoundingClientRect();if(r.width<4||r.height<4||getComputedStyle(el).visibility==='hidden')return;n++;var t=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);if(!(t===el||el.contains(t)))bad.push((el.id||el.className||el.tagName)+' under '+(t?(t.id||t.className||t.tagName):'nothing'))});return {n:n,bad:bad}})()"
  Check "every visible HOME control receives a click at its centre ($($clk.n) controls)" ($clk.n -ge 3 -and @($clk.bad).Count -eq 0) (@($clk.bad) -join '; ')
  Check "no broken image on HOME" ((Cdp-Eval "[].filter.call(document.querySelectorAll('#overlay img'),function(i){return i.complete&&i.naturalWidth===0}).length") -eq 0)
  $lay = Cdp-Json "(function(){var ov=document.getElementById('overlay'),out=[],small=[],w=document.createTreeWalker(ov,NodeFilter.SHOW_TEXT);while(w.nextNode()){var n=w.currentNode,s=n.textContent.trim();if(!s)continue;var p=n.parentElement;if(p.closest('#homeHost, [hidden], .idle-foot'))continue;var cs=getComputedStyle(p);if(cs.display==='none'||cs.visibility==='hidden')continue;var rg=document.createRange();rg.selectNodeContents(n);var r=rg.getBoundingClientRect();if(r.width<1)continue;if(r.left<-0.5||r.top<-0.5||r.right>1920.5||r.bottom>1080.5)out.push(s.slice(0,24));if(parseFloat(cs.fontSize)<20&&!p.closest('.tiny'))small.push(cs.fontSize+' '+s.slice(0,20));}var t=ov.cloneNode(true);[].forEach.call(t.querySelectorAll('.ser, .ev .n, #homeHost'),function(e){e.remove();});return {out:out,small:small,text:t.innerText};})()"
  Check "nothing is outside 1920 x 1080 ($(@($lay.out) -join '; '))" (@($lay.out).Count -eq 0)
  Check "no text under 20 px except the source line ($(@($lay.small) -join '; '))" (@($lay.small).Count -eq 0)
  # COPY-RULES; series and event names are iRacing's / the organisers' own words (e.g. "SENSIT!") and are left out of this check
  $banned = @('\b(you|your|yours|you''re|you''ve|you''ll)\b', 'good (morning|afternoon|evening)', 'ready when', 'when you are', 'welcome', '\b(just|simply|quietly|automatically|insight|journey|story)\b', 'by itself', 'let''s', 'here''s', '!', '\s–\s', '\w - \w', 'outline from', 'from your own', 'sampled', 'explains', 'is the mean', 'worked out from', 'last time here')
  $hitW = @($banned | Where-Object { ([string]$lay.text) -match "(?i)$_" })
  Check "no banned words or punctuation on HOME (COPY-RULES, $($banned.Count) patterns)" ($hitW.Count -eq 0) "found: $($hitW -join ' | ') in: $(([string]$lay.text) -replace '\s+', ' ')"
  Check 'REVIEW is a big enough target (44 px tall or more)' ((Cdp-Eval "document.getElementById('homeReview').getBoundingClientRect().height") -ge 44)
  Cdp-Shot (Join-Path $shots 'home-v3-live-idle.png')

  Section '2c. the one button does exactly what it says (dry run: recorded, never sent)'
  $btn = Cdp-Json "(function(){var b=document.getElementById('homeNext'),r=b.getBoundingClientRect();return {label:b.querySelector('b').textContent,sub:(b.querySelector('span')||{}).innerText||'',car:b.getAttribute('data-car'),track:b.getAttribute('data-track'),w:r.width,h:r.height}})()"
  $shortCar = ([string]$h.last.car -replace '^Chevrolet ', '')
  Check "the button says LAST DRIVE and names his last car and track on its face ('$($btn.sub -replace '\s+', ' ')')" ($btn.label -eq 'Last drive' -and $btn.car -ceq $h.last.car -and $btn.track -ceq $h.last.track -and $btn.sub -match [regex]::Escape($shortCar) -and $btn.sub -match [regex]::Escape($h.last.track)) "label='$($btn.label)' car='$($btn.car)' track='$($btn.track)'"
  Check "the button is a big target: $([math]::Round($btn.w)) x $([math]::Round($btn.h)) px" ($btn.w -ge 700 -and $btn.h -ge 200)
  function Fnv($kind, $text) { [uint32]$x = 2166136261; foreach ($ch in $text.ToLowerInvariant().ToCharArray()) { $x = [uint32](([uint64]($x -bxor [uint32][char]$ch) * 16777619) % 4294967296) }; return $kind + $x.ToString('x8') }
  $null = Cdp-Eval "Home.dry = true; Home.sent = []; Home.busyUntil = 0; true"
  $null = Cdp-Eval "document.getElementById('homeNext').click(); true"
  Start-Sleep -Milliseconds 700
  $sent = Cdp-Json "Home.sent"
  $idWant = Fnv 'r' ("$($btn.car)|$($btn.track)")
  $my = J "$api/mydrive"; $row = @($my.all | Where-Object { $_.id -eq $sent[0].a }) | Select-Object -First 1
  Check "the click (dry run) sends exactly: mdpick $idWant, then mdstart - nothing else" (@($sent).Count -eq 2 -and $sent[0].c -eq 'mdpick' -and $sent[0].a -eq $idWant -and $sent[1].c -eq 'mdstart') ($sent | ConvertTo-Json -Compress)
  Check "that id is the drive MY DRIVE lists as '$($row.car)' at '$($row.track)'" ($row -and $row.car -ceq $btn.car -and $row.track -ceq $btn.track) "all[] has no entry $($sent[0].a)"
  Check 'the button shows STARTING while it works (and presses are ignored then)' ((Cdp-Eval "(function(){ var t = document.querySelector('#homeNext b').textContent; document.getElementById('homeNext').click(); return t + '|' + Home.sent.length; })()") -eq 'Starting|2')
  $null = Cdp-Eval "Home.busyUntil = 0; Home.next(); true"
  $null = Cdp-Eval "(function(){ if (!window.__realFetch) { window.__realFetch = window.fetch; window.__fake = {}; window.fetch = function(u, o) { var k = String(u).split('?')[0]; if (window.__fake[k]) return Promise.resolve({ ok: true, json: function () { return Promise.resolve(window.__fake[k]); } }); return window.__realFetch.call(window, u, o); }; } return true; })()"
  $null = Cdp-Eval "window.__fake['/health'] = { apps: [{ id: 'ui', name: 'iRacing UI', state: 'off' }, { id: 'sim', state: 'off' }] }; Home.next().then(function(){ return true; })"
  $bn = Cdp-Json "({ label: document.querySelector('#homeNext b').textContent, sub: (document.querySelector('#homeNext span') || {}).textContent || '', head: (document.querySelector('#idleRig .head b') || {}).textContent || '' })"
  $null = Cdp-Eval "Home.sent = []; Home.busyUntil = 0; document.getElementById('homeNext').click(); true"; Start-Sleep -Milliseconds 400
  $ss = Cdp-Json "Home.sent"
  Check "iRacing not started: the button says RIG ON ('$($bn.sub)'), READY names it ('$($bn.head)'), and the press sends the deck key rig-on" ($bn.label -eq 'Rig on' -and $bn.sub -eq 'iRacing UI off' -and $bn.head -match 'off' -and @($ss).Count -eq 1 -and $ss[0].c -eq 'key' -and $ss[0].a -eq 'rig-on') ($ss | ConvertTo-Json -Compress)
  Cdp-Shot (Join-Path $shots 'home-v3-live-rigon.png')
  $null = Cdp-Eval "window.__fake['/health'] = { apps: [{ id: 'ui', state: 'ok' }, { id: 'sim', state: 'live' }] }; Home.busyUntil = 0; Home.next().then(function(){ return true; })"
  $bg = Cdp-Json "({ label: document.querySelector('#homeNext b').textContent, head: (document.querySelector('#idleRig .head b') || {}).textContent || '' })"
  Check "a session is open: the button says GET IN and READY says LIVE ('$($bg.head)')" ($bg.label -eq 'Get in' -and $bg.head -eq 'Live')
  $null = Cdp-Eval "window.__fake['/health'] = { apps: [{ id: 'ui', state: 'ok' }, { id: 'sim', state: 'off' }] }; var keepLast = Home.home.last; Home.home.last = null; Home.busyUntil = 0; (async function(){ await Home.next(); return true; })()"
  $bs = Cdp-Json "({ label: document.querySelector('#homeNext b').textContent, sub: !!document.querySelector('#homeNext span'), car: document.getElementById('homeNext').getAttribute('data-car'), key: Home.act.key, buttonKey: document.getElementById('homeNext').homeAct.key })"
  $null = Cdp-Eval "Home.sent = []; Home.busyUntil = 0; document.getElementById('homeNext').click(); true"; Start-Sleep -Milliseconds 400
  $s3 = Cdp-Json "Home.sent"
  Check 'no last session: START keeps its own command and sends only test-drive-last' ($bs.label -eq 'Start' -and -not $bs.sub -and -not $bs.car -and $bs.key -eq 'test-drive-last' -and $bs.buttonKey -eq 'test-drive-last' -and @($s3).Count -eq 1 -and $s3[0].c -eq 'key' -and $s3[0].a -eq 'test-drive-last') ("state=$($bs | ConvertTo-Json -Compress) sent=$($s3 | ConvertTo-Json -Compress)")
  $null = Cdp-Eval "Home.home.last = keepLast; Home.dry = false; Home.busyUntil = 0; delete window.__fake['/health']; Home.next().then(function(){ return true; })"

  Section '2d. the phone: the pairing square only while no phone is paired, otherwise one row in READY'
  $qr = J "$api/phone/qr"
  if ($qr.rows -and @($qr.rows).Count) {
    $qr.paired = 0; $qr.allowed = $true; $qrJson = $qr | ConvertTo-Json -Depth 6 -Compress
    $null = Cdp-Eval "window.__fake['/phone/qr'] = $qrJson; Home.phone().then(function(){ return true; })"
    $p1 = Cdp-Json "({ qr: !!document.querySelector('#homePhone canvas') && !document.getElementById('homePhone').hidden, txt: document.getElementById('homePhone').innerText, car: !document.getElementById('homeCar').hidden, row: Array.from(document.querySelectorAll('#idleRig .row')).map(r => r.innerText).join('|') })"
    Check "no phone paired: the pairing square and its code take the car slot ('$($p1.txt -replace '\s+', ' ')')" ($p1.qr -and -not $p1.car -and $p1.txt -match [regex]::Escape(($qr.code.Substring(0, 3) + ' ' + $qr.code.Substring(3))) -and $p1.row -match 'not paired')
    Cdp-Shot (Join-Path $shots 'home-v3-live-pair.png')
    $qr.paired = 1; $qrJson = $qr | ConvertTo-Json -Depth 6 -Compress
    $null = Cdp-Eval "window.__fake['/phone/qr'] = $qrJson; Home.phone().then(function(){ return true; })"
    $p2 = Cdp-Json "({ qr: !document.getElementById('homePhone').hidden, row: Array.from(document.querySelectorAll('#idleRig .row')).map(r => r.innerText).join('|') })"
    Check 'a phone is paired: no square, READY says Phone paired' (-not $p2.qr -and $p2.row -match 'Phone\s+paired')
  } else { '  info  no home network address: the pairing square cannot be shown here (skipped)' }
  $qr.allowed = $false; $qrJson = $qr | ConvertTo-Json -Depth 6 -Compress
  $null = Cdp-Eval "window.__fake['/phone/qr'] = $qrJson; Home.phone().then(function(){ return true; })"
  $p3 = Cdp-Json "Array.from(document.querySelectorAll('#idleRig .row')).map(r => r.innerText).join('|')"
  Check "the phone is not allowed yet: READY names the one file to run ('$p3')" ($p3 -match 'phone-allow\.cmd')
  $null = Cdp-Eval "delete window.__fake['/phone/qr']; Home.phone().then(function(){ return true; })"
  $null = Cdp-Eval "Home.tick = window.__homeTick; true"
  Check 'no JS errors on HOME through the states' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')
  # the REVIEW button opens the Session Review over HOME, with a back bar
  $null = Cdp-Eval "document.getElementById('homeReview').click(); true"
  $hostOk = Wait-Until "(() => { const h = document.getElementById('homeHost'); return !h.hidden && !!h.querySelector('iframe') && h.querySelector('iframe').src.indexOf('coach.html') > 0; })()" 8
  Check 'REVIEW opens the session coach over HOME (all laps and data are one press away inside it)' $hostOk
  Start-Sleep -Seconds 4
  Cdp-Shot (Join-Path $shots 'home-review.png')
  $null = Cdp-Eval "document.querySelector('#homeHost .bar button').click(); true"
  Start-Sleep -Milliseconds 900
  Check 'HOME comes back after the back bar' ((Cdp-Eval "document.getElementById('homeHost').hidden") -eq $true)

  Section '3. hidden while driving (pretend session through the test hook)'
  $tsFile = Join-Path $root 'dash\test-sessions.txt'; $markFile = Join-Path $root 'dash\start-mark.txt'
  $tsBefore = if (Test-Path $tsFile) { [IO.File]::ReadAllText($tsFile) } else { $null }
  Set-Content $lock 'home-test' -Encoding ASCII
  New-Item -ItemType File -Force $hook | Out-Null
  $r = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?IsOnTrack=1&Speed=42&SessionNum=0&Lap=2&SessionTime=120&FuelLevel=30" -TimeoutSec 20
  Check 'test hook accepted the pretend session' ($r.StatusCode -eq 200)
  $hidden = Wait-Until "!document.getElementById('overlay').classList.contains('show') && getComputedStyle(document.getElementById('overlay')).display === 'none'" 12
  Check 'HOME (#overlay) is gone the moment the session is live' $hidden
  Check 'the server says driving' ((J "$api/phone/state").driving -eq $true)
  Check 'HOME stops asking for data while driving' ((Cdp-Eval "Home.shown()") -eq $false)
  Cdp-Shot (Join-Path $shots 'home-driving.png')
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 20
  Remove-Item $hook -Force -ErrorAction SilentlyContinue
  $back = Wait-Until "document.getElementById('overlay').classList.contains('show')" 15
  Check 'HOME is back after the session' $back
  Check 'no JS errors through the whole run' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')
  $tsAfter = if (Test-Path $tsFile) { [IO.File]::ReadAllText($tsFile) } else { $null }
  Check 'a session with no TEST mark (like his own START) is not written to dash\test-sessions.txt' ($tsAfter -eq $tsBefore)

  Section '4. a session a test started is logged (pretend session with a TEST mark), and irdeck writes that mark'
  # irdeck writes "<ticks> TEST" into dash\start-mark.txt when the test that pressed START set RIG_TEST_OWNS_SIM; irdash logs the run while it lasts
  $markBefore = if (Test-Path $markFile) { [IO.File]::ReadAllText($markFile) } else { $null }
  [IO.File]::WriteAllText($markFile, ([DateTime]::UtcNow.AddSeconds(-20).Ticks.ToString() + "`tTEST"))
  Set-Content $lock 'home-test' -Encoding ASCII
  New-Item -ItemType File -Force $hook | Out-Null
  $t0 = [DateTime]::UtcNow.Ticks
  $r = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?IsOnTrack=1&Speed=42&SessionNum=0&Lap=2&SessionTime=120&FuelLevel=30" -TimeoutSec 20
  Check 'test hook accepted the pretend session (a TEST mark does not make the rig busy)' ($r.StatusCode -eq 200)
  Start-Sleep -Seconds 2
  $lines = @(if (Test-Path $tsFile) { [IO.File]::ReadAllLines($tsFile) } else { @() }); $last = if ($lines.Count) { $lines[-1].Split("`t") } else { @() }
  Check 'irdash opened a line for it: the start moment, no end yet' ($last.Count -ge 2 -and [long]$last[0] -ge $t0 - 60 * 10000000L -and [long]$last[0] -le [DateTime]::UtcNow.Ticks -and $last[1].Trim() -eq '') "line='$($lines[-1])'"
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 20
  Remove-Item $hook -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  $lines = @(if (Test-Path $tsFile) { [IO.File]::ReadAllLines($tsFile) } else { @() }); $last = if ($lines.Count) { $lines[-1].Split("`t") } else { @() }
  Check 'and closed it when the session ended: end after start, both just now' ($last.Count -ge 2 -and $last[1].Trim() -ne '' -and [long]$last[1] -ge [long]$last[0] -and [long]$last[1] -le [DateTime]::UtcNow.Ticks -and [long]$last[1] -ge $t0) "line='$($lines[-1])'"
  # put dash\test-sessions.txt and the mark back as they were
  if ($null -eq $tsBefore) { Remove-Item $tsFile -Force -ErrorAction SilentlyContinue } else { [IO.File]::WriteAllText($tsFile, $tsBefore) }
  if ($null -eq $markBefore) { Remove-Item $markFile -Force -ErrorAction SilentlyContinue } else { [IO.File]::WriteAllText($markFile, $markBefore) }
  $ov = [IO.File]::ReadAllText((Join-Path $root 'src\overlays.cs')); $md = [IO.File]::ReadAllText((Join-Path $root 'src\mydrive.cs'))
  Check 'irdeck: both START marks go through MarkLabel, which says TEST when RIG_TEST_OWNS_SIM is set' ($ov -match 'static string MarkLabel' -and $ov -match 'RIG_TEST_OWNS_SIM' -and $ov -match 'MarkLabel\(what\)' -and $md -match 'MarkLabel\("mydrive start"\)')
  $exeBytes = [IO.File]::ReadAllBytes((Join-Path $root 'irdeck-cli.exe')); $needle = [Text.Encoding]::Unicode.GetBytes('RIG_TEST_OWNS_SIM'); $found = $false
  for ($i = 0; $i -le $exeBytes.Length - $needle.Length -and -not $found; $i++) { if ($exeBytes[$i] -eq $needle[0]) { $m = $true; for ($j = 1; $j -lt $needle.Length; $j++) { if ($exeBytes[$i + $j] -ne $needle[$j]) { $m = $false; break } }; if ($m) { $found = $true } } }
  Check 'the built irdeck-cli.exe really contains the RIG_TEST_OWNS_SIM check (it was rebuilt after the change)' $found
  # the tests that start the real sim set the variable BEFORE pressing START
  $rf = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'recorder-fps.ps1')); $rp = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'replay-test.ps1'))
  Check 'recorder-fps.ps1 and replay-test.ps1 set RIG_TEST_OWNS_SIM before their startlast' ($rf.IndexOf('RIG_TEST_OWNS_SIM') -ge 0 -and $rf.IndexOf('RIG_TEST_OWNS_SIM') -lt $rf.IndexOf('startlast') -and $rp.IndexOf("`$env:RIG_TEST_OWNS_SIM = '1'") -lt $rp.IndexOf('Ir startlast ai'))
}
catch { Write-Output "  FAIL  $($_.Exception.Message)"; $script:fail++ }
finally {
  try { Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8 | Out-Null } catch { }
  Remove-Item $hook -Force -ErrorAction SilentlyContinue
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  Cdp-Close
}
Write-Output ''
Write-Output "$($script:ok) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
