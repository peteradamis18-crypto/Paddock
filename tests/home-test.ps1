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

  Section '2. the page in headless Chrome (1920x1080): data, his car, the button, the grid, the picture, the states'
  Add-Type -AssemblyName System.Drawing
  Cdp-Open "$api/v2/"
  $drawn = Wait-Until "!!document.querySelector('#homePbs .pb') && !!document.querySelector('#homeCareer .w') && !!document.querySelector('#homeWeek .w') && !!document.querySelector('#homeLast .tk') && !!document.querySelector('#homeRace h2') && !!document.querySelector('#homeWeekend .home-event') && !document.getElementById('homeNext').hidden" 20
  Check 'HOME drew its blocks' $drawn
  # The first refresh has finished once every block is present. Stop subsequent polling before controlled fixtures.
  $null = Cdp-Eval "window.__homeTick = Home.tick; clearInterval(Home.tickTimer); clearInterval(Home.nextTimer); clearInterval(Home.phoneTimer); Home.tick = async function(){ return true; }; true"
  Start-Sleep -Seconds 3        # the blocks arrive one after another (about 1.5 s)
  Start-Sleep -Milliseconds 1200
  $heroOk = Wait-Until "document.getElementById('homeHero').classList.contains('on') && document.getElementById('heroImg').naturalWidth > 1000 && getComputedStyle(document.getElementById('homeHero')).opacity > 0.99" 15
  Check 'the hero picture is drawn (>1000 px wide)' $heroOk
  Check 'the overlay (HOME) is shown while no session runs' ((Cdp-Eval "document.getElementById('overlay').classList.contains('show')") -eq $true)
  $dom = Cdp-Json "({ name: document.querySelector('#homeDriver .who b') && document.querySelector('#homeDriver .who b').textContent, num: document.querySelector('#homeDriver .num') && document.querySelector('#homeDriver .num').textContent, pbs: Array.from(document.querySelectorAll('#homePbs .pb')).map(e => ({ track: e.querySelector('.tk').firstChild.textContent, t: e.querySelector('.t').textContent })), career: Array.from(document.querySelectorAll('#homeCareer .w b')).map(e => e.textContent.trim()), since: (function(){ var e = document.querySelector('#homeCareer label .dim'); return e ? { text: e.textContent, fs: parseFloat(getComputedStyle(e).fontSize), bigNums: Array.from(document.querySelectorAll('#homeCareer .w b')).map(b => b.textContent.trim()) } : null; })(), week: Array.from(document.querySelectorAll('#homeWeek .w b')).map(e => e.textContent.trim()), weekLabel: (document.querySelector('#homeWeek label span') || {}).textContent || '', lastWeek: (document.querySelector('#homeWeek .sub') || {}).textContent || '', lastLabel: (document.querySelector('#homeLast label span') || {}).textContent || '', last: document.querySelector('#homeLast .tk') && document.querySelector('#homeLast .tk').textContent, lastBest: (document.querySelector('#homeLast .t') || {}).textContent || '', review: !!document.getElementById('homeReview'), next: document.querySelector('#homeNext b').textContent, nextSub: (document.querySelector('#homeNext span') || {}).textContent || '', phone: document.getElementById('homePhoneNote').textContent, qr: !!document.querySelector('#homePhone canvas') && !document.getElementById('homePhone').hidden })"
  Check 'driver name on screen equals /home' ($dom.name -eq $h.name) "'$($dom.name)'"
  Check 'number on screen equals /home' ($dom.num -eq $h.num) "'$($dom.num)'"
  Check 'number on screen equals the number of the car shown (/home me.num)' ($dom.num -eq $h.me.num -and $dom.num) "'$($dom.num)' vs '$($h.me.num)'"
  Section '2a. driver card fixtures: one YAML row, cached official picture, and text-only fallback'
  $cardFixture = @'
(() => {
  const original = Home.home, oldPic = window.PCarPic;
  const rows = [
    { CarIdx: 2, UserName: 'Wrong Driver', CarNumber: '91', TeamName: 'Decoy Team', CarScreenName: 'Decoy Car', CarPath: 'decoy' },
    { CarIdx: 7, UserName: 'Peter Fixture', CarNumber: '4', TeamName: '', CarScreenName: 'Corvette Fixture', CarPath: 'corvettez06rgt3' }
  ];
  const rootDriverCarIdx = 7;
  const me = rows.filter(r => r.CarIdx === rootDriverCarIdx)[0];
  window.__picCalls = 0; window.__picWidth = 0;
  window.PCarPic = { known: () => ({ corvettez06rgt3: 1 }), key: p => p, html: o => { window.__picCalls++; window.__picWidth = o.w; return '<div class="cpic" data-fixture="official"></div>'; }, refresh: () => {}, ready: () => Promise.resolve() };
  Home.home = { name: me.UserName, num: me.CarNumber, car: me.CarScreenName, me: { name: me.UserName, num: me.CarNumber, team: me.TeamName || 'Pratt Miller Motorsports', car: me.CarScreenName, path: me.CarPath } };
  Home.draw();
  const read = () => ({ name: document.querySelector('#homeDriver .who b').textContent, num: (document.querySelector('#homeDriver .num') || {}).textContent || '', team: (document.querySelector('#homeDriver .car span') || {}).textContent || '', car: (document.querySelector('#homeDriver .car b') || {}).textContent || '', frame: !!document.querySelector('#homeDriver .cpic'), box: !!document.querySelector('#homeDriver .mycar'), emptyImg: !!document.querySelector('#homeDriver img'), calls: window.__picCalls, width: window.__picWidth });
  const cached = read();
  Home.home = { name: 'Peter Fixture', num: '4', me: { name: 'Peter Fixture', num: '4', team: 'Pratt Miller Motorsports', car: 'Corvette Fixture', path: 'unavailable' } };
  window.PCarPic = { known: () => ({}), key: p => p, html: () => { window.__picCalls++; return ''; }, refresh: () => {}, ready: () => Promise.resolve() };
  Home.draw(); const absent = read();
  Home.home = { name: '', num: '', car: '', me: null };
  Home.draw(); const empty = { name: document.querySelector('#homeDriver .who b').textContent, num: !!document.querySelector('#homeDriver .num'), car: !!document.querySelector('#homeDriver .idcar'), text: document.getElementById('homeDriver').innerText };
  Home.home = original; window.PCarPic = oldPic; Home.draw();
  return { cached, absent, empty };
})()
'@
  $fixture = Cdp-Json $cardFixture
  Check 'driver card takes name and number from the DriverCarIdx row, not the other driver' ($fixture.cached.name -eq 'Peter Fixture' -and $fixture.cached.num -eq '4' -and $fixture.cached.car -eq 'Corvette Fixture') ($fixture.cached | ConvertTo-Json -Compress)
  Check 'the other driver row does not leak into HOME' ($fixture.cached.name -ne 'Wrong Driver' -and $fixture.cached.num -ne '91' -and $fixture.cached.team -ne 'Decoy Team') ($fixture.cached | ConvertTo-Json -Compress)
  Check 'team is taken only from the actual row, with no unverified fallback' ($fixture.cached.team -eq 'Pratt Miller Motorsports') "team='$($fixture.cached.team)'"
  Check 'the local official picture uses HOME column size and matching CarPath' ($fixture.cached.frame -and $fixture.cached.calls -eq 1 -and $fixture.cached.width -eq 144) ($fixture.cached | ConvertTo-Json -Compress)
  Check 'an unavailable local picture leaves typography with no frame, image box or fetch request' (-not $fixture.absent.frame -and -not $fixture.absent.box -and -not $fixture.absent.emptyImg -and $fixture.absent.calls -eq 1 -and $fixture.absent.name -eq 'Peter Fixture' -and $fixture.absent.num -eq '4') ($fixture.absent | ConvertTo-Json -Compress)
  Check 'missing YAML identity renders no substitute name, number or car and does not throw' (-not $fixture.empty.name -and -not $fixture.empty.num -and -not $fixture.empty.car -and -not $fixture.empty.text) ($fixture.empty | ConvertTo-Json -Compress)
  $null = Cdp-Eval "window.__savedHome = Home.home; window.__savedPic = window.PCarPic; Home.home = { name: 'Peter Fixture', num: '4', car: 'Corvette Fixture', me: { name: 'Peter Fixture', num: '4', team: 'Pratt Miller Motorsports', car: 'Corvette Fixture', path: 'corvettez06rgt3' } }; window.PCarPic = { known: function(){ return { corvettez06rgt3: 1 }; }, key: function(p){ return p; }, html: function(){ return '<div class=\"cpic\"><img alt=\"\" src=\"/cars/corvettez06rgt3.jpg\"></div>'; }, refresh: function(){ } }; Home.draw(); true"
  Cdp-Shot (Join-Path $shots 'home-driver-card-picture.png')
  $null = Cdp-Eval "window.PCarPic = { known: function(){ return {}; }, key: function(p){ return p; }, html: function(){ return ''; }, refresh: function(){ } }; Home.draw(); true"
  Cdp-Shot (Join-Path $shots 'home-driver-card-text.png')
  $null = Cdp-Eval "Home.home = window.__savedHome; window.PCarPic = window.__savedPic; Home.draw(); true"
  $sched = Cdp-Json "({ race: document.getElementById('homeRace').innerText, weekend: document.getElementById('homeWeekend').innerText })"
  $firstReal = @($timedReal | Sort-Object localStart | Select-Object -First 1)[0]
  # one clock everywhere: New York time, 12-hour, EST/EDT (home.js nyDay/nyTime)
  $ny = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
  $firstRealDate = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse($firstReal.localStart), $ny).ToString('ddd, MMM d', [Globalization.CultureInfo]::InvariantCulture)
  Check 'NEXT RACE and THIS WEEKEND REAL WORLD use the current published local schedule' ($sched.race -match [regex]::Escape($h.nextRace.series) -and $sched.race -match [regex]::Escape($h.nextRace.track) -and $sched.weekend -match [regex]::Escape($firstReal.series) -and $sched.weekend -match [regex]::Escape($firstRealDate) -and $sched.weekend -match '\d{1,2}:\d{2} (AM|PM) E[SD]T') "race='$($sched.race -replace '\s+',' ')'; first='$($sched.weekend -replace '\s+',' ')' wanted=$($firstReal.series) $firstRealDate"
  # P0-04: THIS WEEK and LAST OUTING drawn from /home, with real numbers only
  Check "THIS WEEK on screen equals /home week: $($dom.week -join ' ') (hours, laps, PBs)" (@($dom.week).Count -ge 3 -and $dom.week[0] -eq ([double]$h.week.hours).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) -and ($dom.week[1] -replace ',', '') -eq "$($h.week.laps)" -and ($dom.week[2] -replace ',', '') -eq "$($h.week.pbs)") "week='$($dom.week -join ' ')' vs $($h.week.hours)/$($h.week.laps)/$($h.week.pbs)"
  Check "the THIS WEEK heading is there ('$($dom.weekLabel)')" ($dom.weekLabel -eq 'This week')
  if ($c.week.sessions -eq 0) { Check 'empty THIS WEEK is explicit on HOME: 0.0 h, 0 laps, and a LAST WEEK line' ($h.week.hours -eq 0 -and $h.week.laps -eq 0 -and $dom.week.Count -ge 2 -and $dom.week[0] -eq '0.0' -and $dom.week[1] -eq '0' -and $dom.lastWeek -match '^Last week ') "week=$($dom.week -join '/') lastWeek='$($dom.lastWeek)'" }
  Check "LAST OUTING on screen equals /home lastOuting: '$($dom.last)' ($($dom.lastBest)), heading '$($dom.lastLabel)'" ($dom.lastLabel -eq 'Last outing' -and $dom.last -eq $h.lastOuting.track -and (-not $h.lastOuting.best -or $dom.lastBest -eq (Lap $h.lastOuting.best))) "label='$($dom.lastLabel)' track='$($dom.last)' best='$($dom.lastBest)'"
  # PL-1: no DRAWN car anywhere on HOME (cars.js CARS_DRAWN = false); the car slot holds a real picture only
  $meName = ([string]$h.me.car) -replace '^Chevrolet ', ''
  $nocar = Cdp-Json "(function(){var d=document.getElementById('homeDriver'),t=d.querySelector('.idcar .car b');return {pcars:document.querySelectorAll('svg.pcar').length,mycarSvg:document.querySelectorAll('.mycar svg').length,api:typeof window.PCars,dormant:typeof window.PCarsDormant,txt:t?t.textContent:''}})()"
  Check "no DRAWN car anywhere on HOME (svg.pcar $($nocar.pcars), svg in the car slot $($nocar.mycarSvg), window.PCars is $($nocar.api)): CARS_DRAWN is off, the drawing code is only dormant ($($nocar.dormant))" ($nocar.pcars -eq 0 -and $nocar.mycarSvg -eq 0 -and $nocar.api -eq 'undefined' -and $nocar.dormant -eq 'object')
  Check "the car line names the car of his last real session ('$($nocar.txt)' is $meName)" ($nocar.txt -eq $meName)
  # Lead review: no studio tile on HOME (the hero photo shows the car); the car name stands alone on the left margin
  $tile = Cdp-Json "(function(){var d=document.getElementById('homeDriver'),c=d.querySelector('.idcar .car');return {tiles:d.querySelectorAll('.mycar, .cpic').length,left:c?c.getBoundingClientRect().left:-1}})()"
  Check "driver identity is on the right card; no studio car tile is shown (tiles $($tile.tiles))" ($tile.tiles -eq 0 -and (Cdp-Eval "Math.round(document.getElementById('homeDriver').getBoundingClientRect().left)") -eq 960)
  # 2026-10-11: an invisible full-screen layer (#homeHost, display:flex beat [hidden]) swallowed every click on HOME.
  # Every visible control must receive a click at its centre.
  $clk = Cdp-Json "(function(){var bad=[],n=0;[].forEach.call(document.querySelectorAll('#overlay button, #overlay a, #overlay .idle-link, #overlay [data-act]'),function(el){var r=el.getBoundingClientRect();if(r.width<4||r.height<4||getComputedStyle(el).visibility==='hidden')return;n++;var t=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);if(!(t===el||el.contains(t)))bad.push((el.id||el.className||el.tagName)+' under '+(t?(t.id||t.className||t.tagName):'nothing'))});return {n:n,bad:bad}})()"
  Check "every visible HOME control receives a click at its centre ($($clk.n) controls)" ($clk.n -ge 3 -and @($clk.bad).Count -eq 0) (@($clk.bad) -join '; ')
  $hcJs = "(function(){var d=document.getElementById('homeDriver'),b=d.querySelector('.who b').getBoundingClientRect(),car=d.querySelector('.idcar .car'),f=d.querySelector('.mycar .cpic'),im=f&&f.querySelector('img'),fr=f?f.getBoundingClientRect():null,cr=car?car.getBoundingClientRect():null;return {hasF:!!f,nat:im?im.naturalWidth:0,natH:im?im.naturalHeight:0,src:im?im.getAttribute('src'):'',w:fr?fr.width:0,h:fr?fr.height:0,left:fr?fr.left:0,gapName:fr?fr.top-b.bottom:-99,gapText:fr&&cr?cr.left-fr.right:-99,midDiff:fr&&cr?Math.abs((fr.top+fr.bottom)/2-(cr.top+cr.bottom)/2):-1,broken:[].filter.call(document.querySelectorAll('img'),function(i){return i.complete&&i.naturalWidth===0}).length,frames:document.querySelectorAll('.cpic').length}})()"
  $hc = Cdp-Json $hcJs
  Check "no broken image on HOME ($($hc.broken))" ($hc.broken -eq 0)
  $pbBad = @(); for ($i = 0; $i -lt [math]::Min(3, $h.pbs.Count); $i++) { if ($dom.pbs[$i].track -ne $h.pbs[$i].track -or $dom.pbs[$i].t -ne (Lap $h.pbs[$i].best)) { $pbBad += "$($dom.pbs[$i].track) $($dom.pbs[$i].t) vs $($h.pbs[$i].track) $(Lap $h.pbs[$i].best)" } }
  Check 'personal bests on screen equal /home (track and time), three at most' ($pbBad.Count -eq 0 -and @($dom.pbs).Count -eq [math]::Min(3, $h.pbs.Count)) ($pbBad -join '; ')
  Check 'career hours on screen equal /career' ($dom.career[0] -eq ([double]$c.hours).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)) "'$($dom.career[0])' vs $($c.hours)"
  Check 'career laps, km and races on screen equal /career' ((($dom.career[1] -replace ',', '') -eq "$($c.laps)") -and (($dom.career[2] -replace ',', '') -eq "$([math]::Round([double]$c.km))") -and (($dom.career[3] -replace ',', '') -eq "$($c.races)")) "'$($dom.career -join ' ')'"
  # PL-1: "since May 2023" is one small label beside CAREER, not a number that reads like a statistic
  Check "the career 'since' is one small label ('$($dom.since.text)'): Since <month> <year> as /career says ($($c.since)), 14 px, and no big number on the row is a year" ($dom.since -and $dom.since.text -eq "Since $($c.since)" -and $dom.since.fs -le 14 -and @($dom.since.bigNums | Where-Object { $_ -match '^(19|20)\d\d$' }).Count -eq 0) "since=$($dom.since | ConvertTo-Json -Compress)"
  Check 'last session on screen with its REVIEW button' ($dom.last -eq $h.last.track -and $dom.review) "'$($dom.last)'"

  # DS-1: the one button does exactly what it says. LAST DRIVE names the car and track of his last session and sends: choose that exact car + track
  # (mdpick with the id MY DRIVE gives that drive), then start (mdstart). The click is a dry run here: recorded, never sent.
  $btn = Cdp-Json "(function(){var b=document.getElementById('homeNext'),r=b.getBoundingClientRect();return {label:b.querySelector('b').textContent,sub:(b.querySelector('span')||{}).textContent||'',car:b.getAttribute('data-car'),track:b.getAttribute('data-track'),w:r.width,h:r.height,left:r.left}})()"
  Check "the button says LAST DRIVE and names his last session's car and track on its face ('$($btn.sub)'): $($h.last.car) at $($h.last.track)" ($btn.label -eq 'Last drive' -and $btn.car -ceq $h.last.car -and $btn.track -ceq $h.last.track -and $btn.sub -ceq (([string]$h.last.car -replace '^Chevrolet ', '') + ' ' + [char]0x00B7 + ' ' + $h.last.track)) "label='$($btn.label)' sub='$($btn.sub)' car='$($btn.car)' track='$($btn.track)'"
  Check "the button is a big target: $([math]::Round($btn.w)) x $([math]::Round($btn.h)) px" ($btn.w -ge 480 -and $btn.h -ge 80)
  function Fnv($kind, $text) { [uint32]$x = 2166136261; foreach ($ch in $text.ToLowerInvariant().ToCharArray()) { $x = [uint32](([uint64]($x -bxor [uint32][char]$ch) * 16777619) % 4294967296) }; return $kind + $x.ToString('x8') }
  $null = Cdp-Eval "Home.dry = true; Home.sent = []; Home.busyUntil = 0; true"
  $null = Cdp-Eval "document.getElementById('homeNext').click(); true"
  Start-Sleep -Milliseconds 700
  $sent = Cdp-Json "Home.sent"
  $idWant = Fnv 'r' ("$($btn.car)|$($btn.track)")
  $my = J "$api/mydrive"; $row = @($my.all | Where-Object { $_.id -eq $sent[0].a }) | Select-Object -First 1
  Check "the click (dry run) sends exactly: mdpick $idWant (the id of '$($btn.car)|$($btn.track)'), then mdstart - nothing else" (@($sent).Count -eq 2 -and $sent[0].c -eq 'mdpick' -and $sent[0].a -eq $idWant -and $sent[1].c -eq 'mdstart') ($sent | ConvertTo-Json -Compress)
  Check "that id is the drive MY DRIVE lists as '$($row.car)' at '$($row.track)': the car and track on the button's face are the ones the command chooses" ($row -and $row.car -ceq $btn.car -and $row.track -ceq $btn.track) "all[] has no entry $($sent[0].a)"
  Check 'the button shows STARTING while it works (and presses are ignored then)' ((Cdp-Eval "(function(){ var t = document.querySelector('#homeNext b').textContent; document.getElementById('homeNext').click(); return t + '|' + Home.sent.length; })()") -eq 'Starting|2')
  $null = Cdp-Eval "Home.busyUntil = 0; Home.next(); true"
  # the other states of the one button (a pretend /health through a thin fetch wrapper; nothing is sent)
  $null = Cdp-Eval "(function(){ if (!window.__realFetch) { window.__realFetch = window.fetch; window.__fake = {}; window.fetch = function(u, o) { var k = String(u).split('?')[0]; if (window.__fake[k]) return Promise.resolve({ ok: true, json: function () { return Promise.resolve(window.__fake[k]); } }); return window.__realFetch.call(window, u, o); }; } return true; })()"
  $null = Cdp-Eval "window.__fake['/health'] = { apps: [{ id: 'ui', state: 'off' }, { id: 'sim', state: 'off' }] }; Home.next().then(function(){ return true; })"
  $bn = Cdp-Json "({ label: document.querySelector('#homeNext b').textContent, sub: !!document.querySelector('#homeNext span') })"
  $null = Cdp-Eval "Home.sent = []; Home.busyUntil = 0; document.getElementById('homeNext').click(); true"; Start-Sleep -Milliseconds 400
  $ss = Cdp-Json "Home.sent"
  Check 'iRacing not started: the button says RIG ON, no sub line, and sends the deck key rig-on' ($bn.label -eq 'Rig on' -and -not $bn.sub -and @($ss).Count -eq 1 -and $ss[0].c -eq 'key' -and $ss[0].a -eq 'rig-on') ($ss | ConvertTo-Json -Compress)
  $null = Cdp-Eval "window.__fake['/health'] = { apps: [{ id: 'ui', state: 'ok' }, { id: 'sim', state: 'live' }] }; Home.busyUntil = 0; Home.next().then(function(){ return true; })"
  $bg = Cdp-Json "({ label: document.querySelector('#homeNext b').textContent, sub: !!document.querySelector('#homeNext span') })"
  Check 'a session is open: the button says GET IN, no sub line' ($bg.label -eq 'Get in' -and -not $bg.sub)
  $null = Cdp-Eval "window.__fake['/health'] = { apps: [{ id: 'ui', state: 'ok' }, { id: 'sim', state: 'off' }] }; var keepLast = Home.home.last; Home.home.last = null; Home.busyUntil = 0; (async function(){ await Home.next(); return true; })()"
  $bs = Cdp-Json "({ label: document.querySelector('#homeNext b').textContent, sub: !!document.querySelector('#homeNext span'), car: document.getElementById('homeNext').getAttribute('data-car'), key: Home.act.key, buttonKey: document.getElementById('homeNext').homeAct.key })"
  $null = Cdp-Eval "Home.sent = []; Home.busyUntil = 0; document.getElementById('homeNext').click(); true"; Start-Sleep -Milliseconds 400
  $s3 = Cdp-Json "Home.sent"
  Check 'no last session: START keeps its own command and sends only test-drive-last' ($bs.label -eq 'Start' -and -not $bs.sub -and -not $bs.car -and $bs.key -eq 'test-drive-last' -and $bs.buttonKey -eq 'test-drive-last' -and @($s3).Count -eq 1 -and $s3[0].c -eq 'key' -and $s3[0].a -eq 'test-drive-last') ("state=$($bs | ConvertTo-Json -Compress) sent=$($s3 | ConvertTo-Json -Compress)")
  $null = Cdp-Eval "Home.home.last = keepLast; Home.dry = false; Home.busyUntil = 0; delete window.__fake['/health']; Home.next().then(function(){ return true; })"

  # DS-1 layout: the grid, the car, the type, the words
  $lay = Cdp-Json @'
(() => {
  const ov = document.getElementById('overlay'), regions = Home.carRegion();
  const hit = r => regions.some(g => Math.min(r.right, g.right) - Math.max(r.left, g.left) > 1 && Math.min(r.bottom, g.bottom) - Math.max(r.top, g.top) > 1);
  const walker = document.createTreeWalker(ov, NodeFilter.SHOW_TEXT), texts = [], onCar = [], outside = [], sizes = {}, small = [];
  while (walker.nextNode()) {
    const n = walker.currentNode, s = n.textContent.trim(); if (!s) continue;
    const p = n.parentElement; if (p.closest('#homeHero, #homeHost, [hidden]') || !p.offsetParent && getComputedStyle(p).position !== 'fixed') continue;
    const cs = getComputedStyle(p); if (cs.visibility === 'hidden' || cs.display === 'none') continue;
    const rg = document.createRange(); rg.selectNodeContents(n);
    const boxes = cs.textOverflow === 'ellipsis' ? [p.getBoundingClientRect()] : Array.from(rg.getClientRects());
    const facts = p.closest('.home-facts');
    if (facts && getComputedStyle(p.closest('.home-facts > div')).display === 'none') continue;
    sizes[cs.fontSize] = (sizes[cs.fontSize] || 0) + 1;
    if (parseFloat(cs.fontSize) < 14) small.push(cs.fontSize + ' ' + s);
    for (const r of boxes) {
      if (r.width < 1) continue; texts.push(s);
      if (hit(r)) onCar.push(s.slice(0, 24) + ' @' + Math.round(r.left) + ',' + Math.round(r.top));
      if (r.left < -0.5 || r.top < -0.5 || r.right > 1920.5 || r.bottom > 1080.5) outside.push(s.slice(0, 24));
    }
  }
  const blocks = [];
  for (const e of ov.querySelectorAll('button, canvas, .cpic, .home-facts, #homeDriver, .idle-top, .idle-foot')) {
    if (e.closest('#homeHost, [hidden]')) continue; const r = e.getBoundingClientRect(); if (!r.width) continue;
    blocks.push((e.id || e.className || e.tagName));
    if (/BUTTON|CANVAS/.test(e.tagName) || e.classList.contains('cpic')) { if (hit(r)) onCar.push('block ' + (e.id || e.className || e.tagName)); }
    if (r.left < -0.5 || r.top < -0.5 || r.right > 1920.5 || r.bottom > 1080.5) outside.push('block ' + (e.id || e.className || e.tagName));
  }
  const L = s => { const e = document.querySelector(s); if (!e || e.closest('[hidden]')) return null; const r = e.getBoundingClientRect(); return { l: Math.round(r.left * 10) / 10, r: Math.round(r.right * 10) / 10, t: Math.round(r.top * 10) / 10, b: Math.round(r.bottom * 10) / 10 }; };
  return { n: texts.length, onCar: onCar, outside: outside, sizes: sizes, small: small, blocks: blocks.length, car: regions.map(g => [Math.round(g.left), Math.round(g.top), Math.round(g.right), Math.round(g.bottom)]),
    edges: { name: L('.idle-name'), top: L('.idle-top'), driver: L('#homeDriver'), pic: L('#homeDriver .mycar'), next: L('#homeNext'), race: L('#homeRace'), weekend: L('#homeWeekend'), pbs: L('#homePbs'), career: L('#homeCareer'), week: L('#homeWeek'), last: L('#homeLast'), foot: L('.idle-foot'), facts: L('.home-facts') },
    text: ov.innerText };
})()
'@
  Check "no text, button, picture or square sits on the car (the car is $($lay.car.Count) boxes: $(($lay.car | ForEach-Object { $_ -join ',' }) -join ' | ')); $($lay.n) text boxes checked" ($lay.onCar.Count -eq 0) ($lay.onCar -join '; ')
  Check "nothing is outside 1920 x 1080 ($($lay.blocks) blocks, $($lay.n) text boxes)" ($lay.outside.Count -eq 0) ($lay.outside -join '; ')
  $cols = 0..11 | ForEach-Object { 96 + 146 * $_ }; $colsR = 0..11 | ForEach-Object { 96 + 146 * $_ + 122 }
  function OnCol($v, $set) { foreach ($c in $set) { if ([math]::Abs($v - $c) -lt 1.0) { return $true } }; return $false }
  $e = $lay.edges; $gridBad = @()
  if ($e.name.l -ne 96 -or $e.driver.l -ne 960 -or $e.race.l -ne 0 -or $e.race.r -ne 920 -or $e.weekend.l -ne 0 -or $e.weekend.t -ne 640) { $gridBad += 'HOME regions do not match wireframe 3b' }
  if ($e.week.l -ne 968 -or $e.last.l -ne 1432 -or $e.next.l -ne 640) { $gridBad += "week $($e.week.l) / last $($e.last.l) / action $($e.next.l) misplaced" }
  Check "HOME regions match 3b (header, next race, hero, real world, this week, last outing, action)" ($gridBad.Count -eq 0) ($gridBad -join '; ')
  $sz = @($lay.sizes.PSObject.Properties.Name | ForEach-Object { [double]($_ -replace 'px', '') } | Sort-Object)
  Check "HOME body copy is at least 22 px and labels are at least 14 px: $($sz -join ', ') px" ((Cdp-Eval "Array.from(document.querySelectorAll('.home-race p,.home-race h2,.home-event b,.home-event span')).every(function(e){return parseFloat(getComputedStyle(e).fontSize)>=22})") -eq $true -and @($sz | Where-Object { $_ -lt 14 }).Count -eq 0) ("$($sz -join ', ') :: $($lay.small -join '; ')")
  $banned = @('\b(you|your|yours|you''re|you''ve|you''ll)\b', 'good (morning|afternoon|evening)', 'ready when', 'when you are', 'welcome', '\b(just|simply|quietly|automatically|insight|journey|story)\b', 'by itself', 'let''s', 'here''s', '!', '\u2014', '\s\u2013\s', '\w - \w', 'outline from', 'from your own', 'sampled', 'explains', 'is the mean', 'worked out from', 'last time here')
  $hitW = @($banned | Where-Object { ([string]$lay.text) -match "(?i)$_" })
  Check "no banned words or punctuation on HOME (COPY-RULES): $($banned.Count) patterns, the screen has $((([string]$lay.text) -split '\s+').Count) words" ($hitW.Count -eq 0) "found: $($hitW -join ' | ') in: $(([string]$lay.text) -replace '\s+', ' ')"
  $ov = Cdp-Json "(() => { const ids = ['homeDriver','homeNext','homeRace','homeWeekend','homePbs','homeCareer','homeWeek','homeLast','homePhone','idleRig','homePhoneNote']; const els = ids.map(i => document.getElementById(i)).filter(e => e && e.offsetParent !== null && e.innerHTML.trim() && getComputedStyle(e).display !== 'none'); els.push(document.querySelector('.idle-top'));
    const r = els.map(e => ({ id: e.id || e.className, b: e.getBoundingClientRect() })).filter(x => x.b.width > 0 && x.b.height > 0); const bad = [];
    for (let i = 0; i < r.length; i++) for (let j = i + 1; j < r.length; j++) { const a = r[i].b, b = r[j].b; const ox = Math.min(a.right, b.right) - Math.max(a.left, b.left), oy = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top); if (ox > 2 && oy > 2) bad.push(r[i].id + ' x ' + r[j].id + ' (' + Math.round(ox) + 'x' + Math.round(oy) + ')'); }
    return { n: r.length, bad: bad }; })()"
  Check "no overlaps between the HOME blocks ($($ov.n) boxes)" ($ov.bad.Count -eq 0) ($ov.bad -join '; ')
  Check 'REVIEW is a big enough target (44 px tall or more)' ((Cdp-Eval "document.getElementById('homeReview').getBoundingClientRect().height") -ge 44)
  Start-Sleep -Milliseconds 800     # the button's colour fades back after the last press (0.2 s); the picture is taken when it is at rest
  Cdp-Shot (Join-Path $shots 'home-v4-idle.png')
  Check 'no JS errors on HOME'($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')

  # the fixtures below stay deterministic after the live HOME polls are stopped.
  # the states (pictures: home-states-*.png). Each is checked for the same rules: nothing on the car, nothing outside, no overlaps.
  $stateJs = @'
(() => { const regions = Home.carRegion(), hit = r => regions.some(g => Math.min(r.right, g.right) - Math.max(r.left, g.left) > 1 && Math.min(r.bottom, g.bottom) - Math.max(r.top, g.top) > 1);
  const ov = document.getElementById('overlay'), walker = document.createTreeWalker(ov, NodeFilter.SHOW_TEXT), bad = [], tx = [];
  while (walker.nextNode()) { const n = walker.currentNode, s = n.textContent.trim(); if (!s) continue; const p = n.parentElement; if (p.closest('#homeHero, #homeHost, [hidden]')) continue; const cs = getComputedStyle(p); if (cs.display === 'none' || cs.visibility === 'hidden') continue;
    const rg = document.createRange(); rg.selectNodeContents(n); const boxes = cs.textOverflow === 'ellipsis' ? [p.getBoundingClientRect()] : Array.from(rg.getClientRects());
    for (const r of boxes) { if (r.width < 1) continue; tx.push(s); if (hit(r) || r.left < 0 || r.right > 1920 || r.bottom > 1080) bad.push(s.slice(0, 30)); } }
  for (const e of ov.querySelectorAll('button, canvas, .cpic')) { if (e.closest('#homeHost, [hidden]')) continue; const r = e.getBoundingClientRect(); if (r.width && (hit(r) || r.right > 1920 || r.bottom > 1080)) bad.push('block ' + (e.id || e.tagName)); }
  const ids = ['homeDriver','homeNext','homeRace','homeWeekend','homePbs','homeCareer','homeWeek','homeLast','homePhone'], els = ids.map(i => document.getElementById(i)).filter(e => e && !e.hidden && e.innerHTML.trim() && getComputedStyle(e).display !== 'none'), ovl = [];
  const r = els.map(e => ({ id: e.id, b: e.getBoundingClientRect() })); for (let i = 0; i < r.length; i++) for (let j = i + 1; j < r.length; j++) { const a = r[i].b, b = r[j].b; if (Math.min(a.right, b.right) - Math.max(a.left, b.left) > 2 && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 2) ovl.push(r[i].id + ' x ' + r[j].id); }
  const q = id => { const e = document.getElementById(id); if (!e || e.hidden) return null; const b = e.getBoundingClientRect(); return { l: Math.round(b.left), r: Math.round(b.right), t: Math.round(b.top), b: Math.round(b.bottom) }; };
  return { bad: bad, ovl: ovl, career: q('homeCareer'), week: q('homeWeek'), last: q('homeLast'), pbs: q('homePbs'), phone: q('homePhone'), qr: !!document.querySelector('#homePhone canvas'), pbCount: document.querySelectorAll('#homePbs .pb').length, headings: Array.from(document.querySelectorAll('.home-facts label')).filter(l => { const p=l.closest('.home-facts > div'); return !l.closest('[hidden]') && p && getComputedStyle(p).display !== 'none'; }).map(l => l.textContent.trim()), btn: document.querySelector('#homeNext b').textContent, note: document.getElementById('homePhoneNote').textContent, tx: tx.join(' | ') }; })()
'@
  # a. no personal best yet: the block is gone (no empty heading) and the others close up to the margin
  $keepPbs = Cdp-Eval "window.__keepPbs = Home.home.pbs; Home.home.pbs = []; Home.draw(); true"; Start-Sleep -Milliseconds 400
  $s1 = Cdp-Json $stateJs
  Check "state: no personal best yet - no empty best block; THIS WEEK and LAST OUTING remain in 3b regions with no overlap" ($s1.pbCount -eq 0 -and $s1.headings -notcontains 'Personal bests' -and $s1.week.l -eq 968 -and $s1.last.l -eq 1432 -and $s1.bad.Count -eq 0 -and $s1.ovl.Count -eq 0) "pbs=$($s1.pbCount) bad=$($s1.bad -join ',') ovl=$($s1.ovl -join ',') headings=$($s1.headings -join ',') week=$($s1.week.l) last=$($s1.last.l)"
  Cdp-Shot (Join-Path $shots 'home-states-nopb.png')
  $null = Cdp-Eval "Home.home.pbs = window.__keepPbs; Home.draw(); true"
  # b. a long track name: ellipsis inside its own column, REVIEW and the next block stay clear
  $null = Cdp-Eval "window.__keepH = JSON.stringify(Home.home); var hh = Home.home; hh.pbs[1].track = 'Autodromo Nazionale Monza Grand Prix Circuit'; hh.last.track = 'Circuit des 24 Heures du Mans Bugatti Circuit Alternative Layout With The Chicane'; hh.lastOuting.track = 'Circuit des 24 Heures du Mans Bugatti Circuit Alternative Layout With The Chicane'; Home.draw(); true"; Start-Sleep -Milliseconds 400
  $s2 = Cdp-Json $stateJs
  $revGap = Cdp-Json "(function(){var t=document.querySelector('#homeLast .tk'),b=t.getBoundingClientRect(),r=document.getElementById('homeReview').getBoundingClientRect();return {revBelowName:r.top-b.bottom,clipped:t.scrollWidth>t.clientWidth,scroll:t.scrollWidth,client:t.clientWidth,text:t.textContent,ellipsis:getComputedStyle(t).textOverflow}})()"
  Check "state: long track names stay inside LAST OUTING and REVIEW stays clear" ($revGap.clipped -and $revGap.revBelowName -ge -2 -and $s2.bad.Count -eq 0 -and $s2.ovl.Count -eq 0) "bad=$($s2.bad -join ',') ovl=$($s2.ovl -join ',') $($revGap | ConvertTo-Json -Compress)"
  Cdp-Shot (Join-Path $shots 'home-states-longtrack.png')
  $null = Cdp-Eval "Home.home = JSON.parse(window.__keepH); Home.draw(); true"
  # c. the pairing square: shown only while no phone is paired, top right over the dark sky, not on the car
  $qr = J "$api/phone/qr"; $qr.paired = 0; $qrJson = $qr | ConvertTo-Json -Depth 6 -Compress
  $null = Cdp-Eval "window.__fake['/phone/qr'] = $qrJson; Home.phone().then(function(){ return true; })"
  $s3 = Cdp-Json $stateJs
  Check "state: no phone paired - the pairing square shows (140 x 140, top right x $($s3.phone.l)-$($s3.phone.r), y $($s3.phone.t)-$($s3.phone.b)) with the code, nothing on the car, no overlaps" ($s3.qr -and $s3.phone.r -le 1824 -and $s3.phone.t -ge 96 -and ($s3.phone.b - $s3.phone.t) -le 150 -and $s3.bad.Count -eq 0 -and $s3.ovl.Count -eq 0 -and $s3.tx -match [regex]::Escape(($qr.code.Substring(0, 3) + ' ' + $qr.code.Substring(3)))) "bad=$($s3.bad -join ',') ovl=$($s3.ovl -join ',') phone=$($s3.phone | ConvertTo-Json -Compress)"
  Cdp-Shot (Join-Path $shots 'home-states-phone.png')
  $qr.paired = 1; $qrJson = $qr | ConvertTo-Json -Depth 6 -Compress
  $null = Cdp-Eval "window.__fake['/phone/qr'] = $qrJson; Home.phone().then(function(){ return true; })"
  $s3b = Cdp-Json $stateJs
  Check 'state: a phone is paired - no square, one quiet status word at the foot (PHONE PAIRED)' (-not $s3b.qr -and $s3b.note -eq 'Phone paired' -and $s3b.bad.Count -eq 0)
  $qr.allowed = $false; $qrJson = $qr | ConvertTo-Json -Depth 6 -Compress
  $null = Cdp-Eval "window.__fake['/phone/qr'] = $qrJson; Home.phone().then(function(){ return true; })"
  $s3c = Cdp-Json $stateJs
  Check 'state: the phone is not allowed yet - no square, the status line names the one file to run (phone-allow.cmd)' (-not $s3c.qr -and $s3c.note -like '*phone-allow.cmd*' -and $s3c.bad.Count -eq 0) "note='$($s3c.note)'"
  $null = Cdp-Eval "delete window.__fake['/phone/qr']; Home.phone().then(function(){ return true; })"
  # d. iRacing not started yet (RIG ON), shown in full
  $null = Cdp-Eval "window.__fake['/health'] = { apps: [{ id: 'ui', state: 'off' }, { id: 'sim', state: 'off' }] }; Home.busyUntil = 0; Home.next().then(function(){ return true; })"
  $s4 = Cdp-Json $stateJs
  Check "state: iRacing not started - the one gold button reads RIG ON ('$($s4.btn)'), nothing on the car, no overlaps" ($s4.btn -eq 'Rig on' -and $s4.bad.Count -eq 0 -and $s4.ovl.Count -eq 0)
  Cdp-Shot (Join-Path $shots 'home-states-starting.png')
  $null = Cdp-Eval "delete window.__fake['/health']; Home.next().then(function(){ return true; })"
  $null = Cdp-Eval "Home.tick = window.__homeTick; true"

  Check 'hero photo stays in its wireframe region and fades at the panel edges' ((Cdp-Eval "(function(){var h=document.getElementById('homeHero').getBoundingClientRect(),i=document.getElementById('heroImg');return h.left===920&&h.top===60&&h.right===1920&&h.bottom===540&&getComputedStyle(i).maskImage.indexOf('linear-gradient')>=0})()") -eq $true)
  # the credit sits bottom right on black, tiny
  $null = Cdp-Eval "document.getElementById('flatTest').remove(); true"
  $cr = Cdp-Json "(function(){var e=document.getElementById('heroCredit'),r=e.getBoundingClientRect();return {t:e.textContent,r:r.right,b:r.bottom,fs:parseFloat(getComputedStyle(e).fontSize)}})()"
  Check "the picture credit stays factual and small: '$($cr.t)'" ($h.hero.kind -ne 'standin' -or ($cr.t -like 'Photo:*' -and $cr.fs -le 14))
  Check 'no JS errors on HOME through the states' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')
  # the REVIEW button opens the Session Review over HOME, with a back bar
  $null = Cdp-Eval "document.getElementById('homeReview').click(); true"
  $hostOk = Wait-Until "(() => { const h = document.getElementById('homeHost'); return !h.hidden && !!h.querySelector('iframe') && h.querySelector('iframe').src.indexOf('sessionreview.html') > 0; })()" 8
  Check 'REVIEW opens the Session Review over HOME' $hostOk
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
