# WS13 test: the benchmark ("how good am I?"). Out of the car; no iRacing session needed.
# Real telemetry files are only read (their session text, a few KB each). The field database is tested on scratch files in %TEMP%,
# so data\fieldlaps.tsv is never touched; the official-timing links are only asked "do you answer?" (HEAD), nothing is downloaded.
#   1. the field parser on a real session with other drivers (an .ibt of an official practice) and on an AI race (nothing to record)
#   2. percentile maths, and the "30 drivers or nothing" rule, on made-up laps (independent maths in this script)
#   3. /bench for your real car and track: gaps, pace, next goal, history, sources
#   4. data\pro-refs.json: every entry well formed, the seconds match the printed time, every source link answers
#   5. the card as a picture (sessions page and debrief), and its text
#   6. the live capture (end of a session with other drivers) on made-up frames
# Pictures: tests\shots\b-card-sample.png, b-card-real.png, b-debrief.png
#   powershell -ExecutionPolicy Bypass -File tests\bench-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 30; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Get-Raw($path) {
  try { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 30; return @{ code = [int]$r.StatusCode; body = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } }
  catch { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; body = $_.Exception.Message } }
    $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $b = $sr.ReadToEnd(); $sr.Dispose(); return @{ code = [int]$resp.StatusCode; body = $b } }
}
function Q($s) { [uri]::EscapeDataString($s) }
$inv = [Globalization.CultureInfo]::InvariantCulture
# The same lap text the card draws (bench.js lap): minutes, then seconds to 3 places, padded.
function LapText($sec) {
  $t = [double]$sec
  $m = [math]::Floor($t / 60.0)
  $s = $t - ($m * 60.0)
  $body = $s.ToString('0.000', $inv)
  if ($m -le 0) { return $body }
  if ($s -lt 10) { $body = '0' + $body }
  return ([string][int]$m) + ':' + $body
}
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
# headless Chrome: a picture of one page, and the page's text after its scripts ran
function Chrome-Shot($url, $out, $budget = 9000) {
  $dir = Join-Path $env:TEMP ('bench-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  # Start-Process so a stuck Chrome cannot hang the test: one minute at most
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars', "--user-data-dir=$dir", '--window-size=1920,1080', "--virtual-time-budget=$budget", "--screenshot=$out", $url) -PassThru -WindowStyle Hidden
  if (-not $p.WaitForExit(60000)) { try { $p | Stop-Process -Force } catch { } }
  Start-Sleep -Milliseconds 800
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$dir*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 500; try { [IO.Directory]::Delete($dir, $true) } catch { }
}# the text of a page after its scripts ran: headless Chrome driven over the DevTools protocol (like data-test.ps1)
function Chrome-Text($url, $selector, $waitMs = 6000) {
  $dir = Join-Path $env:TEMP ('bench-test-cdp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9356
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$dir", "--remote-debugging-port=$port", '--window-size=1920,1080', 'about:blank') -PassThru -WindowStyle Hidden
  $text = ''
  try {
    $page = $null
    for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
    $id = 0
    $send = { param($method, $params)
      $script:cid++
      $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $script:cid; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
      $null = $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
      while ($true) {
        $buf = New-Object byte[] 262144; $sb = New-Object Text.StringBuilder
        do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage)
        $o = $sb.ToString() | ConvertFrom-Json
        if ($o.id -eq $script:cid) { return $o }
      }
    }
    $script:cid = 0
    $null = & $send 'Page.enable' @{}
    $null = & $send 'Emulation.setDeviceMetricsOverride' @{ width = 1920; height = 1080; deviceScaleFactor = 1; mobile = $false }
    $null = & $send 'Page.navigate' @{ url = $url }
    Start-Sleep -Milliseconds $waitMs
    $r = & $send 'Runtime.evaluate' @{ expression = "(function(){ var e = document.querySelector('$selector'); return e ? e.innerText + '\n#rows=' + document.querySelectorAll('$selector .bn-row').length : ''; })()"; returnByValue = $true }
    $text = [string]$r.result.result.value
    $ws.Dispose()
  } finally {
    try { $p | Stop-Process -Force } catch { }
    Start-Sleep -Milliseconds 500
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$dir*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    Start-Sleep -Milliseconds 300; try { [IO.Directory]::Delete($dir, $true) } catch { }
  }
  return $text
}
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
'Benchmark test'
$scratch = Join-Path $env:TEMP 'bench-test-scratch'; Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $scratch | Out-Null
try {

Section '0. irdash has the new code'
$st = Get-Raw '/bench/list'
if ($st.code -ne 200) { Check 'irdash is running the build with /bench (run dash\build.ps1 once, then this test)' $false; throw 'irdash is still the old build' }
Check 'irdash answers /bench/list' $true

Section '1. the other drivers in a real session (from the session text of an .ibt)'
# find a file whose session had other human drivers (not AI): an official practice is the one real example so far
$human = $null; $aiFile = $null
foreach ($f in (Get-ChildItem $tel -Filter *.ibt | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-3) } | Sort-Object LastWriteTime -Descending)) {
  $o = Get-Raw "/fieldlaps/scan?file=$(Q $f.Name)"
  if ($o.code -ne 200) { continue }
  $j = $o.body | ConvertFrom-Json
  if ($j.otherHumans -gt 0 -and -not $human) { $human = $j }
  if ($j.otherHumans -eq 0 -and -not $aiFile -and $f.Name -match 'chevyvettez06rgt3_roadatlanta') { $aiFile = $j }
  if ($human -and $aiFile) { break }
}
if ($human) {
  Check "a session with other human drivers was found ($($human.file): $($human.otherHumans) others)" ($human.otherHumans -ge 1)
  $first = $human.rows | Select-Object -First 1
  Check "its rows carry session, car, track, driver id, iRating, licence and best lap (e.g. $($first.car), iR $($first.ir), $($first.lic), $($first.best) s)" ($human.rows.Count -ge 1 -and $first.sid -match '^s\d+$' -and $first.uid -gt 0 -and $first.ir -gt 0 -and $first.lic -match '^[A-Z] \d\.\d\d$' -and $first.best -gt 15 -and $first.car -and $first.track)
  Check 'AI cars, the pace car and spectators are never rows, and no driver names are stored' (@($human.rows | Where-Object { $_.PSObject.Properties.Name -contains 'name' }).Count -eq 0)
  # independent check against the file's own text: every best lap in the rows is a FastestTime in the YAML, for the same driver id
  $yaml = & {
    $fs = New-Object IO.FileStream((Join-Path $tel $human.file), 'Open', 'Read', 'ReadWrite,Delete'); try { $h = New-Object byte[] 144; [void]$fs.Read($h, 0, 144); $len = [BitConverter]::ToInt32($h, 16); $off = [BitConverter]::ToInt32($h, 20); $fs.Position = $off; $b = New-Object byte[] $len; [void]$fs.Read($b, 0, $len); $z = [Array]::IndexOf($b, [byte]0); if ($z -lt 0) { $z = $len }; [Text.Encoding]::GetEncoding(28591).GetString($b, 0, $z) } finally { $fs.Dispose() }
  }
  $printed = @([regex]::Matches($yaml, 'FastestTime: ([\d.]+)') | ForEach-Object { [double]::Parse($_.Groups[1].Value, $inv) })
  $ok = $true
  foreach ($r in $human.rows) { if (-not ($printed | Where-Object { [math]::Abs($_ - [double]$r.best) -lt 0.0006 })) { $ok = $false } }
  Check 'each best lap in the rows is a FastestTime printed in that file' $ok
  Check 'the rows are not duplicated (one per session and driver)' (@($human.rows | Group-Object sid, num, uid | Where-Object Count -gt 1).Count -eq 0)
} else { "  (no telemetry file with other human drivers on this PC yet: the real-session checks are skipped)" }
if ($aiFile) { Check "an AI race ($($aiFile.file)) gives no rows: AI sessions are skipped" ($aiFile.otherHumans -eq 0 -and $aiFile.rows.Count -eq 0) }
$bad = Get-Raw '/fieldlaps/scan?file=..\..\x.ibt'
if ($bad.code -ne 404) { Start-Sleep -Seconds 1; $bad = Get-Raw '/fieldlaps/scan?file=..\..\x.ibt' }
Check 'a path instead of a file name is refused (404)' ($bad.code -eq 404)

Section '2. percentile maths and the 30-driver rule (made-up laps, scratch file)'
$exe = Join-Path $root 'dash\irdash.exe'
$asm = [Reflection.Assembly]::LoadFile($exe); $bf = [Reflection.BindingFlags]'Static,Public,NonPublic'
function T($name) { $asm.GetType("IRDash.$name") }
function Call($type, $method, [object[]]$a) { (T $type).GetMethod($method, $bf).Invoke($null, $a) }
function SetStatic($type, $field, $value) { (T $type).GetField($field, $bf).SetValue($null, $value) }
function GetStatic($type, $field) { (T $type).GetField($field, $bf).GetValue($null) }
SetStatic 'Log' 'FilePath' (Join-Path $env:TEMP 'bench-test-harness.log')
SetStatic 'TrackMaps' 'TelemetryDir' $tel; SetStatic 'Career' 'TelemetryDir' $tel; SetStatic 'Career' 'CacheFile' (Join-Path $root 'dash\career-cache.tsv')
SetStatic 'ProRefs' 'File_' (Join-Path $root 'data\pro-refs.json')
$asc = [double[]](1..101)
$pc = (T 'Bench').GetMethod('Percentile', $bf)
Check 'percentile of 1..101: top 5 % = 6, top 25 % = 26, median = 51' ((Near $pc.Invoke($null, [object[]]@($asc, 0.05)) 6 1e-9) -and (Near $pc.Invoke($null, [object[]]@($asc, 0.25)) 26 1e-9) -and (Near $pc.Invoke($null, [object[]]@($asc, 0.5)) 51 1e-9))
$odd = [double[]]@(80.0, 81.0, 82.0, 90.0)
Check 'between ranks it is a straight line (4 laps, median = 81.5; top 5 % = 80.15)' ((Near $pc.Invoke($null, [object[]]@($odd, 0.5)) 81.5 1e-9) -and (Near $pc.Invoke($null, [object[]]@($odd, 0.05)) 80.15 1e-9))
Check 'one lap gives that lap, none gives 0' ((Near $pc.Invoke($null, [object[]]@([double[]]@(79.5), 0.05)) 79.5 1e-9) -and (Near $pc.Invoke($null, [object[]]@([double[]]@(), 0.5)) 0 1e-9))

# the real combination (the one with the most sessions)
$s = J '/sessions'
$pbRow = @($s.pbs | Where-Object { $_.best -gt 15 } | Sort-Object { -[int]$_.sessions })[0]
$car = $pbRow.car; $track = $pbRow.track; $cfg = $pbRow.config
$irArgs = [object[]]@(''); $realIr = [int]((T 'Career').GetMethod('LatestIr', $bf).Invoke($null, $irArgs))
$myIr = if ($realIr -ge 100) { $realIr } else { 1500 }
SetStatic 'FieldLaps' 'Dir' $scratch; SetStatic 'FieldLaps' 'FieldFile' (Join-Path $scratch 'fieldlaps.tsv'); SetStatic 'FieldLaps' 'ScannedFile' (Join-Path $scratch 'fieldlaps.scanned.txt'); SetStatic 'FieldLaps' 'inited' $true
$rowT = $asm.GetType('IRDash.FieldRow')
function MakeRows($n, $car, $track, $cfg, $ir, $baseTime, $sid) {
  $l = [Activator]::CreateInstance(([System.Collections.Generic.List`1]).MakeGenericType($rowT))
  for ($i = 0; $i -lt $n; $i++) {
    $r = [Activator]::CreateInstance($rowT); $r.Sid = $sid; $r.Num = 2; $r.Type = 'Race'; $r.Ts = 1760000000; $r.Car = $car; $r.Track = $track; $r.Config = $cfg; $r.Uid = 100000 + $i; $r.Ir = $ir + (($i % 5) - 2) * 40; $r.Lic = 'B 2.50'
    $r.Best = [math]::Round($baseTime + 0.1 * $i, 3); $r.Laps = 20; $r.Me = $false; $r.Src = 'test'; $l.Add($r)
  }
  return , $l
}
$added = (T 'FieldLaps').GetMethod('Append', $bf).Invoke($null, [object[]]@(,(MakeRows 29 $car $track $cfg $myIr 70.0 's900001')))
Check "29 other drivers saved ($added rows)" ($added -eq 29)
$j29 = (Call 'Bench' 'Json' @($car, $track, $cfg, $false)) | ConvertFrom-Json
Check '29 drivers are not enough: no top 5 %, top 25 %, median or similar-iRating line, and the card says how many it has' (@($j29.yardsticks | Where-Object { $_.kind -eq 'field' }).Count -eq 0 -and $j29.field.n -eq 29 -and $j29.field.enough -eq $false -and $j29.field.needed -eq 30)
$again = (T 'FieldLaps').GetMethod('Append', $bf).Invoke($null, [object[]]@(,(MakeRows 29 $car $track $cfg $myIr 70.0 's900001')))
Check 'saving the same drivers again adds nothing (de-duplicated by session and driver)' ($again -eq 0)
$added30 = (T 'FieldLaps').GetMethod('Append', $bf).Invoke($null, [object[]]@(,(MakeRows 30 $car $track $cfg $myIr 70.0 's900002')))
Check 'a second session with the same drivers adds its rows, but a driver still counts once (30 drivers, not 59)' ($added30 -eq 30)
$j30 = (Call 'Bench' 'Json' @($car, $track, $cfg, $false)) | ConvertFrom-Json
$times = 0..29 | ForEach-Object { [math]::Round(70.0 + 0.1 * $_, 3) }     # the 30 drivers' best laps
function PsPct($a, $p) { $h = ($a.Count - 1) * $p; $lo = [math]::Floor($h); $hi = [math]::Min($a.Count - 1, $lo + 1); return $a[$lo] + ($h - $lo) * ($a[$hi] - $a[$lo]) }
$f5 = $j30.yardsticks | Where-Object id -eq 'top5'; $f25 = $j30.yardsticks | Where-Object id -eq 'top25'; $fm = $j30.yardsticks | Where-Object id -eq 'median'
Check "30 drivers are enough: top 5 % ($($f5.time)), top 25 % ($($f25.time)) and the median ($($fm.time)) appear, each saying 'based on 30 drivers'" ($f5 -and $f25 -and $fm -and (Near $f5.time (PsPct $times 0.05) 0.001) -and (Near $f25.time (PsPct $times 0.25) 0.001) -and (Near $fm.time (PsPct $times 0.5) 0.001) -and $f5.n -eq 30 -and $f5.detail -match 'based on 30 drivers')
$sim = $j30.yardsticks | Where-Object id -eq 'similar'
if ($realIr -ge 100) { Check 'drivers within 250 iRating of you show as their own line (the rows were made to sit around your rating)' ($sim -ne $null -and $sim.n -eq 30) }
else { "  (no real iRating in your sessions yet: the similar-iRating line is skipped)" }
Check '30 drivers: the count on the card is 30 (a driver counts once, with the best lap)' ($j30.field.n -eq 30 -and $j30.field.enough -eq $true)
Check 'the list is ordered from quickest to slowest' ((@($j30.yardsticks | ForEach-Object { [double]$_.time }) -join ',') -eq ((@($j30.yardsticks | ForEach-Object { [double]$_.time } | Sort-Object)) -join ','))

Section '2a. hand-calculated benchmark fixtures (four real JSON paths)'
# Four distinct combos use controlled career-cache rows and independent field samples. This keeps
# PB selection and the seconds/milliseconds contract deterministic while exercising Bench.Json.
$fixtureSets = @(
  @{ name='A'; car='Fixture Car A'; track='Fixture Track A'; cfg='Layout A'; base=70.0; pb=100.123; ts=1760000000000L; count=30 },
  @{ name='B'; car='Fixture Car B'; track='Fixture Track B'; cfg='Layout B'; base=72.0; pb=71.234; ts=1760000100000L; count=30 },
  @{ name='C'; car='Fixture Car C'; track='Fixture Track C'; cfg='Layout C'; base=74.0; pb=75.345; ts=1760000200000L; count=30 },
  @{ name='D'; car='Fixture Car D'; track='Fixture Track D'; cfg='Layout D'; base=76.0; pb=76.456; ts=1760000300000L; count=30 }
)
$careerFixture = Join-Path $scratch 'career-fixtures.tsv'
$careerLines = foreach ($fx in $fixtureSets) {
  $when = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$fx.ts).UtcDateTime
  $start = $when.Ticks
  # the file name is in its own parentheses: without them "+" binds looser than "," and the whole row becomes ONE space-joined string, which the cache reader skips
  @(('fixture-' + $fx.name + '.ibt|0'), $when.Ticks, 3600, 10000, 20, $myIr, $fx.car, $fx.track, 'Test', '', '2', 'B 2.50', '2', $fx.pb, 0, 0, $fx.cfg, '0', $start, 'Race') -join "`t"
}
Set-Content -LiteralPath $careerFixture -Value $careerLines -Encoding UTF8
SetStatic 'Career' 'CacheFile' $careerFixture
(T 'Career').GetField('recs', $bf).GetValue($null).Clear()
(T 'Career').GetField('loaded', $bf).SetValue($null, $false)
foreach ($fx in $fixtureSets) {
  $sid = 's91000' + [string]([array]::IndexOf($fixtureSets, $fx) + 1)
  SetStatic 'FieldLaps' 'FieldFile' (Join-Path $scratch ($sid + '.tsv'))
  SetStatic 'FieldLaps' 'ScannedFile' (Join-Path $scratch ($sid + '.scanned.txt'))
  (T 'FieldLaps').GetField('known', $bf).GetValue($null).Clear()
  SetStatic 'FieldLaps' 'cacheStamp' ''
  $rowsFx = MakeRows $fx.count $fx.car $fx.track $fx.cfg $myIr $fx.base $sid
  [void](T 'FieldLaps').GetMethod('Append', $bf).Invoke($null, [object[]]@(,$rowsFx))
  $outFx = (Call 'Bench' 'Json' @($fx.car, $fx.track, $fx.cfg, $false)) | ConvertFrom-Json
  if ($fx.name -eq 'A') { Write-Output ('  fixture A reply: ' + ($outFx | ConvertTo-Json -Compress -Depth 8)) }
  $vals = @(0..29 | ForEach-Object { [math]::Round([double]$fx.base + $_ * 0.1, 3) })
  $expected5 = PsPct $vals 0.05; $expected25 = PsPct $vals 0.25; $expected50 = PsPct $vals 0.5
  $field5 = $outFx.yardsticks | Where-Object id -eq 'top5'
  $field25 = $outFx.yardsticks | Where-Object id -eq 'top25'
  $field50 = $outFx.yardsticks | Where-Object id -eq 'median'
  $similarFx = $outFx.yardsticks | Where-Object id -eq 'similar'
  $nearest = @($outFx.yardsticks | Where-Object { [double]$_.time -lt [double]$outFx.pb.time - 0.0005 } | Sort-Object { [double]$_.time } | Select-Object -Last 1)
  Check "$($fx.name): selected PB equals the controlled career lap in seconds" ((Near $outFx.pb.time $fx.pb 0.0005) -and $outFx.pb.source -eq 'telemetry')
  Check "$($fx.name): PB timestamp is Unix milliseconds and history retains seconds" (([long]$outFx.pb.ts -eq [long]$fx.ts) -and @($outFx.history).Count -eq 1 -and [long]$outFx.history[0][0] -eq [long]$fx.ts -and (Near $outFx.history[0][1] $fx.pb 0.0005) -and (Near $outFx.history[0][2] $fx.pb 0.0005))
  Check "$($fx.name): top5 interpolation is hand-calculated" ($field5 -and (Near $field5.time $expected5 0.001))
  Check "$($fx.name): top25 interpolation is hand-calculated" ($field25 -and (Near $field25.time $expected25 0.001))
  Check "$($fx.name): median interpolation is hand-calculated" ($field50 -and (Near $field50.time $expected50 0.001))
  Check "$($fx.name): similar-rating median and sample count are measured" ($similarFx -and $similarFx.n -eq 30 -and (Near $similarFx.time $expected50 0.001))
  if ($nearest.Count) { Check "$($fx.name): NEXT is closest faster yardstick and gap is seconds" ($outFx.next.id -in @($outFx.yardsticks | Where-Object { (Near $_.time $nearest[0].time 0.0005) } | ForEach-Object { $_.id }) -and (Near $outFx.next.time $nearest[0].time 0.0005) -and (Near $outFx.next.gap ($outFx.pb.time - $nearest[0].time) 0.001)) }
  else { Check "$($fx.name): no faster yardstick gives null NEXT" ($outFx.next -eq $null -and $outFx.ahead -eq $true) }
  $bestSoFar = 1e9; $historyValid = @($outFx.history).Count -gt 0
  foreach ($hp in $outFx.history) { $bestSoFar = [math]::Min($bestSoFar, [double]$hp[1]); if ($hp.Count -ne 3 -or $hp[0] -le 1000000000000 -or -not (Near $hp[2] $bestSoFar 0.001)) { $historyValid = $false } }
  Check "$($fx.name): history points preserve milliseconds and running-best seconds" ($historyValid -and (Near $bestSoFar $outFx.pb.time 0.001))
}
SetStatic 'Career' 'CacheFile' (Join-Path $root 'dash\career-cache.tsv')
(T 'Career').GetField('recs', $bf).GetValue($null).Clear()
(T 'Career').GetField('loaded', $bf).SetValue($null, $false)

# 29 is suppressed; 30 is present, including its visible source/count detail.
$thresholdFile = Join-Path $scratch 'threshold.tsv'
SetStatic 'FieldLaps' 'FieldFile' $thresholdFile
SetStatic 'FieldLaps' 'ScannedFile' (Join-Path $scratch 'threshold.scanned.txt')
(T 'FieldLaps').GetField('known', $bf).GetValue($null).Clear()
SetStatic 'FieldLaps' 'cacheStamp' ''
$field29 = [Activator]::CreateInstance(([System.Collections.Generic.List`1]).MakeGenericType($rowT))
for ($i = 0; $i -lt 29; $i++) { $r = [Activator]::CreateInstance($rowT); $r.Sid='s920029'; $r.Num=2; $r.Type='Race'; $r.Ts=1760000000; $r.Car=$car; $r.Track=$track; $r.Config=$cfg; $r.Uid=200000+$i; $r.Ir=$myIr; $r.Best=70.0+$i*0.1; $r.Laps=20; $r.Src='test'; $field29.Add($r) }
[void](T 'FieldLaps').GetMethod('Append', $bf).Invoke($null, [object[]]@(,$field29))
$at29 = (Call 'Bench' 'Json' @($car, $track, $cfg, $false)) | ConvertFrom-Json
Check 'n=29 suppresses top5' (@($at29.yardsticks | Where-Object id -eq 'top5').Count -eq 0)
Check 'n=29 suppresses top25' (@($at29.yardsticks | Where-Object id -eq 'top25').Count -eq 0)
Check 'n=29 suppresses median' (@($at29.yardsticks | Where-Object id -eq 'median').Count -eq 0)
SetStatic 'FieldLaps' 'FieldFile' (Join-Path $scratch 'threshold30.tsv')
SetStatic 'FieldLaps' 'ScannedFile' (Join-Path $scratch 'threshold30.scanned.txt')
(T 'FieldLaps').GetField('known', $bf).GetValue($null).Clear()
SetStatic 'FieldLaps' 'cacheStamp' ''
[void](T 'FieldLaps').GetMethod('Append', $bf).Invoke($null, [object[]]@(,(MakeRows 30 $car $track $cfg $myIr 70.0 's920030')))
$at30 = (Call 'Bench' 'Json' @($car, $track, $cfg, $false)) | ConvertFrom-Json
$f30top = $at30.yardsticks | Where-Object id -eq 'top5'
$f30mid = $at30.yardsticks | Where-Object id -eq 'median'
$f30sim = $at30.yardsticks | Where-Object id -eq 'similar'
Check 'n=30 top5 is shown with n=30' ($f30top -and $f30top.n -eq 30)
Check 'n=30 top25 is shown with n=30' (@($at30.yardsticks | Where-Object id -eq 'top25' | Where-Object n -eq 30).Count -eq 1)
Check 'n=30 median and similar band are shown with n=30' ($f30mid -and $f30mid.n -eq 30 -and $f30sim -and $f30sim.n -eq 30)

# Repoint the real reference reader at a valid empty file and confirm missing source data adds no IMSA line.
$emptyRefs = Join-Path $scratch 'empty-pro-refs.json'; Set-Content -LiteralPath $emptyRefs -Value '{"note":"guide only","refs":[],"classes":{}}' -Encoding UTF8
SetStatic 'ProRefs' 'File_' $emptyRefs
$missingPro = (Call 'Bench' 'Json' @($car, $track, $cfg, $false)) | ConvertFrom-Json
Check 'missing IMSA reference hides cleanly without inventing a pro yardstick' (@($missingPro.yardsticks | Where-Object kind -eq 'pro').Count -eq 0)
SetStatic 'ProRefs' 'File_' (Join-Path $root 'data\pro-refs.json')

Section '3. /bench for your real car and track'
$b = J "/bench?car=$(Q $car)&track=$(Q $track)&config=$(Q $cfg)"
# (a best lap set in the session being played right now is on the card before the sessions page has read its file)
Check "the best lap is the sessions page's ($($b.pb.time) / $($pbRow.best)), or quicker when it was set a moment ago, and the card knows the car and track folder names ($($b.carPath) @ $($b.trackName))" (($b.pb.time -le $pbRow.best + 0.002) -and ($b.pb.live -or (Near $b.pb.time $pbRow.best 0.002)) -and $b.carPath -and $b.trackName)
Check "the best lap says where it comes from and how many sessions ($($b.pb.source), $($b.pb.sessions) sessions, $($b.pb.laps) laps)" ($b.pb.source -and $b.pb.sessions -ge 1)
$okGap = $true; $okPace = $true; $okSrc = $true
foreach ($y in $b.yardsticks) {
  if (-not (Near $y.gap ($b.pb.time - $y.time) 0.0015)) { $okGap = $false }
  if (-not (Near $y.pace ($b.pb.time / $y.time * 100) 0.06)) { $okPace = $false }
  if (-not $y.source -or -not $y.detail -or -not $y.label) { $okSrc = $false }
  if ($y.kind -eq 'pro' -and $y.url -notmatch '^https://imsa\.results\.alkamelcloud\.com/') { $okSrc = $false }
}
Check "every yardstick: gap = your best - its time, pace = your best / its time ($(@($b.yardsticks).Count) of them)" ($okGap -and $okPace)
Check 'every yardstick has a label, a source and a detail line; the real-world ones a link to the official timing' $okSrc
$faster = @($b.yardsticks | Where-Object { [double]$_.time -lt [double]$b.pb.time - 0.0005 })
if ($faster.Count) { $expect = ($faster | Sort-Object { [double]$_.time } | Select-Object -Last 1); Check "the next goal is the slowest yardstick that is still ahead of you ($($b.next.label), $($b.next.gap) s)" ($b.next.id -eq $expect.id -and (Near $b.next.gap ($b.pb.time - $expect.time) 0.0015)) }
else { Check 'nothing is ahead of you: no next goal, and the card says so' ($b.next -eq $null -and ($b.ahead -eq $true -or @($b.yardsticks).Count -eq 0)) }
$run = 1e9; $mono = $true; foreach ($h in $b.history) { $run = [math]::Min($run, [double]$h[1]); if (-not (Near $h[2] $run 0.0005)) { $mono = $false } }
Check "the history is your best lap running through your sessions, never getting slower ($(@($b.history).Count) points)" ($mono -and @($b.history).Count -ge 1 -and (Near $b.history[-1][2] $b.pb.time 0.002))
$real = (J '/fieldlaps')
Check "the real field database says how it stands ($($real.rows) rows; yardsticks need $($real.minField) drivers per car and track)" ($real.minField -eq 30)
$bad = (J "/bench?car=$(Q 'No Such Car')&track=$(Q 'Nowhere')&config=")
Check 'an unknown car and track gives an empty card, not an error' ($bad.pb -eq $null -and @($bad.yardsticks).Count -eq 0)
$list = J '/bench/list'
Check 'the list of cars and tracks includes this one' (@($list.combos | Where-Object { $_.car -eq $car -and $_.track -eq $track }).Count -eq 1)
$smp = J '/bench?sample=1'
Check 'the sample card is flagged as sample data' ($smp.sample -eq $true -and $smp.pb.time -eq 84.312)

Section '4. data\pro-refs.json: the real-world references'
$pf = Get-Content (Join-Path $root 'data\pro-refs.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'the file says "real car, real conditions - a guide only"' ($pf.note -match 'guide only')
Check 'every entry has class, track, series, event, year, session, driver, time, seconds and a source link' (@($pf.refs | Where-Object { -not ($_.carClass -and $_.trackName -and $_.series -and $_.event -and $_.year -and $_.session -and $_.driver -and $_.time -and $_.seconds -and $_.url) }).Count -eq 0)
$okSecs = $true; foreach ($r in $pf.refs) { $p = $r.time.Split(':'); $sec = [double]$p[0] * 60 + [double]::Parse($p[1], $inv); if (-not (Near $sec $r.seconds 0.0005)) { $okSecs = $false } }
Check "the seconds match the printed time in all $(@($pf.refs).Count) entries" $okSecs
Check 'all of them come from IMSA''s official timing server' (@($pf.refs | Where-Object { $_.url -notmatch '^https://imsa\.results\.alkamelcloud\.com/Results/25_2025/' }).Count -eq 0)
Check 'every class named by an entry is defined, and its cars are iRacing folder names' (@($pf.refs | Where-Object { $pf.classes.PSObject.Properties.Name -notcontains $_.carClass }).Count -eq 0 -and @($pf.classes.GT3).Count -ge 8 -and @($pf.classes.GTP).Count -ge 4)
Check 'no entry twice (same class, track and session)' (@($pf.refs | Group-Object carClass, trackName, event, session | Where-Object Count -gt 1).Count -eq 0)
$urls = @($pf.refs | ForEach-Object { $_.url } | Sort-Object -Unique); $dead = @()
foreach ($u in $urls) {
  $okPdf = $false
  for ($try = 0; $try -lt 2 -and -not $okPdf; $try++) {
    if ($try -gt 0) { Start-Sleep -Seconds 2 }
    try { $r = Invoke-WebRequest -Method Head -UseBasicParsing $u -TimeoutSec 40; if ($r.StatusCode -eq 200 -and "$($r.Headers['Content-Type'])" -match 'pdf') { $okPdf = $true } } catch { }
  }
  if (-not $okPdf) { $dead += $u }
}
Check "all $($urls.Count) source links answer with a PDF" ($dead.Count -eq 0)
if ($dead.Count) { $dead | ForEach-Object { "        not answering: $_" } }
# the combos Peter drives: which of them get real-world lines
$mine = @($s.pbs | Where-Object { $_.best -gt 15 })
foreach ($m in $mine) { $bb = J "/bench?car=$(Q $m.car)&track=$(Q $m.track)&config=$(Q $m.config)"; "        $($m.car) at $($m.track): $(@($bb.yardsticks | Where-Object kind -eq 'pro').Count) real-world line(s)" }

Section '5. the card as a picture and as text'
Chrome-Shot "$api/v2/sessions.html?bench=sample" (Join-Path $shots 'b-card-sample.png')
Chrome-Shot "$api/v2/sessions.html" (Join-Path $shots 'b-card-real.png')
Chrome-Shot "$api/v2/index.html?debrief=demo" (Join-Path $shots 'b-debrief.png') 14000
Add-Type -AssemblyName System.Drawing
foreach ($n in 'b-card-sample', 'b-card-real', 'b-debrief') { $im = [System.Drawing.Image]::FromFile((Join-Path $shots "$n.png")); Check "$n.png is 1920x1080" ($im.Width -eq 1920 -and $im.Height -eq 1080); $im.Dispose() }
$dom = Chrome-Text "$api/v2/sessions.html?bench=sample" '#benchBox'
Check 'the sample card shows the best, the yardsticks, the next goal, the other-drivers line and the history' ($dom -match 'Best' -and $dom -match '1:24\.312' -and $dom -match 'Top 5% of drivers' -and $dom -match 'Next goal' -and $dom -match 'Best lap over time' -and $dom -match 'sample data')
Check 'it shows gap and pace for each yardstick, with a proper minus sign for the ones you beat' ($dom -match '\+1\.37 s' -and $dom -match "$([char]0x2212)1\.30 s" -and $dom -match '101\.7%')
$dom2 = Chrome-Text "$api/v2/sessions.html" '#benchBox' 9000
# The page opens on the newest timed combo (sessions.js), not the one with the most sessions.
# That changed on 2026-10-10: the card showed Ferrari 296 GT3 at 1:44.133 while this test
# still looked for the Corvette's 1:19.549, so the check failed on a card that was right.
$newest = @($s.pbs | Sort-Object { [double]$_.ts } -Descending)[0]
$bn = J "/bench?car=$(Q $newest.car)&track=$(Q $newest.track)&config=$(Q $newest.config)"
$lap = LapText $bn.pb.time
$pros = @($bn.yardsticks | Where-Object { $_.kind -eq 'pro' })
$hasLap = $dom2 -match [regex]::Escape($lap)
$hasCar = $dom2 -match [regex]::Escape($newest.car)
$hasSrc = $dom2 -match 'imsa\.results\.alkamelcloud\.com'
$expectedVisibleLabels = @($bn.yardsticks | ForEach-Object { $_.label })
$labelsVisible = $true; foreach ($label in $expectedVisibleLabels) { if ($dom2 -notmatch [regex]::Escape($label)) { $labelsVisible = $false } }
$absentLabelsHidden = $true
foreach ($label in @('Top 5% of drivers raced', 'Top 25% of drivers raced', 'Middle of the drivers raced', 'Drivers within 250 iRating')) {
  if (@($bn.yardsticks | Where-Object label -eq $label).Count -eq 0 -and $dom2 -match [regex]::Escape($label)) { $absentLabelsHidden = $false }
}
Check "the real card shows its measured lap and only the yardsticks returned for $($newest.car) at $($newest.track)" ($hasLap -and $hasCar -and $labelsVisible -and $absentLabelsHidden)
if ($pros.Count -gt 0) { Check 'the rendered real-world row includes its official source host' ($dom2 -match 'imsa\.results\.alkamelcloud\.com') }
else { Check 'the rendered card omits an unavailable real-world reference' ($dom2 -notmatch 'IMSA GTD|IMSA GTD PRO|IMSA GTD PRO') }
Check 'the rendered sample row includes its source and 64-driver sample count' ($dom -match 'sample' -and $dom -match 'based on 64 drivers')
# C-40 (2026-10-11): the debrief is now the Session Review and no longer carries this card; the review itself says NEW PERSONAL BEST (tests\session-review-test.ps1)
$dom3 = ''
for ($try = 0; $try -lt 3 -and -not ($dom3 -match 'MINI-SECTORS' -and $dom3 -match 'NEW PERSONAL BEST'); $try++) {
  $dom3 = Chrome-Text "$api/v2/index.html?debrief=demo" '#debrief' 12000
}
Check 'the demo debrief is the Session Review: timing table with the mini-sector strip and the new-personal-best pill' ($dom3 -match 'MINI-SECTORS' -and $dom3 -match 'NEW PERSONAL BEST')

Section '6. the live capture: the end of a session with other drivers (made-up frames, scratch file)'
$yaml = & {
  $name = if ($human) { $human.file } else { $null }
  if (-not $name) { return $null }
  $fs = New-Object IO.FileStream((Join-Path $tel $name), 'Open', 'Read', 'ReadWrite,Delete'); try { $h = New-Object byte[] 144; [void]$fs.Read($h, 0, 144); $len = [BitConverter]::ToInt32($h, 16); $off = [BitConverter]::ToInt32($h, 20); $fs.Position = $off; $b2 = New-Object byte[] $len; [void]$fs.Read($b2, 0, $len); $z = [Array]::IndexOf($b2, [byte]0); if ($z -lt 0) { $z = $len }; [Text.Encoding]::GetEncoding(28591).GetString($b2, 0, $z) } finally { $fs.Dispose() }
}
if ($yaml) {
  $live = Join-Path $scratch 'live'; New-Item -ItemType Directory -Force $live | Out-Null
  SetStatic 'FieldLaps' 'FieldFile' (Join-Path $live 'fieldlaps.tsv'); SetStatic 'FieldLaps' 'Dir' $live; SetStatic 'FieldLaps' 'ScannedFile' (Join-Path $live 'scanned.txt')
  (T 'FieldLaps').GetField('known', $bf).GetValue($null).Clear()
  $tick = (T 'FieldLaps').GetMethod('Tick', $bf)
  function LiveFrame($connected, $ver, $tele) {
    $f = [Activator]::CreateInstance((T 'Frame')); $f.Connected = $connected; if (-not $connected) { return $f }
    $f.SessionVersion = $ver; $f.SessionYaml = $yaml; $f.Data = New-Object byte[] 512
    $dict = [Activator]::CreateInstance(([System.Collections.Generic.Dictionary`2]).MakeGenericType([string], $asm.GetType('IRDash.VarDef')))
    $d = [Activator]::CreateInstance((T 'VarDef')); $d.Name = 'CarIdxBestLapTime'; $d.Type = 4; $d.Offset = 0; $d.Count = 64; $dict.Add('CarIdxBestLapTime', $d)
    for ($i = 0; $i -lt 64; $i++) { $v = if ($tele.ContainsKey($i)) { [single]$tele[$i] } else { [single]-1 }; [BitConverter]::GetBytes($v).CopyTo($f.Data, $i * 4) }
    $f.Vars = $dict; return $f
  }
  $t0 = [DateTime]::Now
  # Car 0 gets a faster live time; the driver's own car index comes from this real session YAML.
  $meIdxMatch = [regex]::Match($yaml, '(?m)^ DriverCarIdx: (\d+)')
  $meIdx = if ($meIdxMatch.Success) { [int]$meIdxMatch.Groups[1].Value } else { 32 }
  $tele = @{ 0 = 70.5; 4 = 211.263 }
  $tele[$meIdx] = 65.0
  [void]$tick.Invoke($null, [object[]]@((LiveFrame $true 1 $tele), $t0))
  [void]$tick.Invoke($null, [object[]]@((LiveFrame $true 1 $tele), $t0.AddSeconds(6)))
  [void]$tick.Invoke($null, [object[]]@((LiveFrame $true 1 $tele), $t0.AddSeconds(32)))
  Start-Sleep -Milliseconds 700
  [void]$tick.Invoke($null, [object[]]@((LiveFrame $false 1 $tele), $t0.AddSeconds(40)))        # the session ends
  Start-Sleep -Milliseconds 900
  $lines = @(Get-Content (Join-Path $live 'fieldlaps.tsv') | Where-Object { $_ -and $_[0] -ne '#' })
  $rows = $lines | ForEach-Object { $c = $_.Split("`t"); [pscustomobject]@{ sid = $c[0]; uid = [int]$c[7]; ir = [int]$c[8]; best = [double]$c[10]; me = $c[12]; src = $c[13] } }
  Check "the end of the session saved the drivers' best laps ($(@($rows).Count) rows)" (@($rows).Count -ge 3)
  Check 'session results and a faster live telemetry value both produce measured driver rows' (@($rows | Where-Object { $_.src -eq 'live' -and $_.best -gt 15 }).Count -ge 1 -and @($rows | Where-Object { $_.src -eq 'live-telemetry' -and (Near $_.best 70.5 0.001) }).Count -eq 1)
  Check 'your own lap is saved with me=1 (it is left out of the field numbers)' (@($rows | Where-Object { $_.me -eq '1' }).Count -ge 1)
  $readRows = (T 'FieldLaps').GetMethod('ReadAll', $bf).Invoke($null, [object[]]@($true))
  Check 'the field reader keeps one best row per session and driver after repeated updates' (@($readRows | Group-Object DedupKey | Where-Object Count -gt 1).Count -eq 0)
  $fileText = Get-Content (Join-Path $live 'fieldlaps.tsv') -Raw
  $names = @([regex]::Matches($yaml, '(?m)^   UserName: (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_.Length -ge 4 })
  Check "the file starts with its header line and holds no driver names (none of the $($names.Count) names in the session text appear in it)" ((Get-Content (Join-Path $live 'fieldlaps.tsv') -TotalCount 1) -match '^#sid\s' -and $names.Count -ge 2 -and -not ($names | Where-Object { $fileText.Contains($_) }))
} else { "  (no real session with other drivers on this PC: the live capture check is skipped)" }

Section '7. nothing is left behind'
}
finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Check 'the scratch files are gone (data\fieldlaps.tsv was never written by this test)' (-not (Test-Path $scratch))
''
"$pass passed, $fail failed. Pictures in $shots"
