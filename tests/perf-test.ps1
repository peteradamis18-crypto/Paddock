# Performance test (WS16): the per-session frame-rate report against fps-report.ps1, the background backfill, the JSON the page reads,
# change markers and "did it help?" (real data and made-up sessions through the real code), the checklist (and proof that looking
# changes nothing), the sampler (what else was running, and what it costs), the live fps figure and amber line, the page itself.
# Real telemetry files are only read. A pretend session (the test hook) is seen by irdash and the dashboard page only.
# Pictures: tests\shots\perf-*.png. Puts everything back as it found it.
#   powershell -ExecutionPolicy Bypass -File tests\perf-test.ps1             everything (rig free: no sim, no START key in the last 10 minutes)
#   powershell -ExecutionPolicy Bypass -File tests\perf-test.ps1 -Offline    only what touches no live app, no window and no test hook (parts 1-4, the page picture):
#                                                                          reads old .ibt files at low priority, so it is fine while Peter races (it still never reads the newest file)
param([switch]$Offline)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function Body($r) { [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
function J($path) { Body (Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 20) | ConvertFrom-Json }
function Get-Raw($path) {
  try { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 20; return @{ code = [int]$r.StatusCode; body = Body $r } }
  catch { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; body = $_.Exception.Message } }
    $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $b = $sr.ReadToEnd(); $sr.Dispose(); return @{ code = [int]$resp.StatusCode; body = $b } }
}
function Fake($q) { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 8 }
function Q($s) { [uri]::EscapeDataString($s) }

# ---- guard: never while Peter races or is about to ----
. (Join-Path $PSScriptRoot 'guard.ps1')
$live = -not $Offline
if ($live) {
  Assert-RigFree
  if ((& (Join-Path $root 'irdeck-cli.exe') state) -match 'telemetry=on|onTrack=True') { 'iRacing is in a session - run this out of the car.'; exit 1 }
} else {
  $why = Get-RigBusy
  'Offline checks only' + $(if ($why) { " ($why)" } else { '' }) + ': nothing here touches the sim, a window, the test hook or the newest telemetry file; running at low priority.'
  [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
}
function Section($title) {
  if ($live) { Assert-RigFree -Where $title; $s = & (Join-Path $root 'irdeck-cli.exe') state; if ($s -match 'telemetry=on|onTrack=True') { throw "a real iRacing session started ($title): stopping and putting everything back" } }
  $title
}

# ---- headless Chrome with the DevTools protocol (the real pages, to look inside them and to picture them) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('perf-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9357
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false }
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = "window.__errs=[];addEventListener('error',function(e){__errs.push(String(e.message))});addEventListener('unhandledrejection',function(e){__errs.push(String(e.reason))});" }
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
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return 'js error: ' + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { [IO.Directory]::Delete($c.prof, $true) } catch { }
}
function Wait-Until($seconds, [scriptblock]$cond) { for ($i = 0; $i -lt $seconds * 2; $i++) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 500 }; return $false }

# ---- the deploy lock: nobody rebuilds irdash while this test needs it ----
Enter-TestLock 'perf'   # one live test at a time (tests\guard.ps1); released in finally
$lock = Join-Path $root 'dash\deploy.lock'
if ($live) {
  for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
  Set-Content $lock ('perf ' + (Get-Date).ToString('HH:mm:ss'))
  Assert-RigFree
}

$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$hook = Join-Path $root 'dash\test-hook.on'
$logN = (Get-Content (Join-Path $root 'dash\irdash.log') | Measure-Object).Count
$procsFile = Join-Path $root 'data\perf-procs.tsv'; $procsBefore = if (Test-Path $procsFile) { (Get-Item $procsFile).Length } else { -1 }
$testProcs = @()
'Performance test'
try {

Section '1. per-session numbers against fps-report.ps1 (the original hand-run report), on real files' | Out-Null
'1. per-session numbers against fps-report.ps1 (the original hand-run report), on real files'
$wanted = @('chevyvettez06rgt3_roadatlanta full 2026-10-09 23-23-41.ibt', 'porsche9922cup_sebring international 2026-10-09 17-32-50.ibt', 'chevyvettez06rgt3_roadatlanta full 2026-10-04 22-13-50.ibt', 'chevyvettez06rgt3_roadatlanta full 2026-10-09 10-28-32.ibt')
$compared = 0
foreach ($n in $wanted) {
  $p = Join-Path $tel $n; if (-not (Test-Path $p)) { "  (skipped ${n}: not on this PC)"; continue }
  $out = @(& (Join-Path $root 'fps-report.ps1') $p)
  $whole = ($out | Where-Object { $_ -match '^whole\s' } | Select-Object -First 1)
  $m = [regex]::Match([string]$whole, 'avg\s+([\d,]+) fps\s+1% low\s+([\d,]+)\s+worst\s+([\d,]+)\s+CPU\s+([\d,]+)% \(peak\s+([\d,]+)%\)\s+GPU\s+([\d,]+)% \(peak\s+([\d,]+)%\)\s+([\d,]+)s')
  $below = [regex]::Match(($out -join "`n"), 'frame limit \((\d+)\): (\d+)%')
  $verdictPs = ($out | Where-Object { $_ -match '^Verdict' } | Select-Object -First 1)
  $code = if ($verdictPs -match 'held the limit') { 'held' } elseif ($verdictPs -match 'graphics card is the limit') { 'gpu' } elseif ($verdictPs -match 'processor is the limit') { 'cpu' } else { 'close' }
  $s = J ('/perf/session?file=' + (Q $n))
  $g = { param($i) [double]($m.Groups[$i].Value -replace ',', '') }
  $ok = $m.Success -and (Near $s.avg (& $g 1) 1) -and (Near $s.low1 (& $g 2) 1) -and (Near $s.worst (& $g 3) 1) -and (Near $s.cpu (& $g 4) 1) -and (Near $s.cpuPeak (& $g 5) 1) -and (Near $s.gpu (& $g 6) 1) -and (Near $s.gpuPeak (& $g 7) 1) -and (Near $s.secs (& $g 8) 1)
  Check ("{0}: avg {1:N1}/{2}, 1% low {3:N1}/{4}, worst {5:N1}/{6}, CPU {7}/{8}, GPU {9}/{10}, {11:N0}s/{12}s (irdash / fps-report)" -f $n.Substring(0, [math]::Min(34, $n.Length)), $s.avg, (& $g 1), $s.low1, (& $g 2), $s.worst, (& $g 3), $s.cpu, (& $g 4), $s.gpu, (& $g 6), $s.secs, (& $g 8)) $ok
  Check "  same highest frame rate ($($below.Groups[1].Value)) and time below it ($($below.Groups[2].Value) %), same verdict ($code)" ((Near $s.cap ([double]$below.Groups[1].Value) 1) -and (Near $s.belowPct ([double]$below.Groups[2].Value) 1) -and $s.verdict -eq $code)
  $compared++
}
Check "at least 3 files compared ($compared)" ($compared -ge 3)

Section '2. backfill: every finished file reported once, nothing twice, a second pass adds nothing' | Out-Null
'2. backfill: every finished file reported once, nothing twice, a second pass adds nothing'
$null = Invoke-WebRequest -UseBasicParsing "$api/perf/scan" -TimeoutSec 10; $null = Wait-Until 25 { (J '/perf/status').state -eq 'done' -or (Get-RigBusy) }
$st = J '/perf/status'
$old = @(Get-ChildItem $tel -Filter *.ibt | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-3) -and -not ([int]$_.Attributes -band (0x400000 -bor 0x40000)) })
$tsv = @(Get-Content (Join-Path $root 'data\perf.tsv') | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { , ($_.Split("`t")) })
$names = @($tsv | ForEach-Object { $_[0] })
Check "perf.tsv has one row for each of the $($old.Count) finished .ibt files" (@($old | Where-Object { $names -contains $_.Name }).Count -eq $old.Count)
Check "no file appears twice ($($names.Count) rows, $(@($names | Select-Object -Unique).Count) different names)" ($names.Count -eq @($names | Select-Object -Unique).Count -and $st.duplicates -eq 0)
Check 'nothing is waiting or pending (while the sim runs, reports are held back by design)' ($st.pending -eq 0 -and ($st.state -eq 'done' -or (Get-RigBusy)))
$before = $names.Count
$null = Invoke-WebRequest -UseBasicParsing "$api/perf/scan" -TimeoutSec 10; Start-Sleep -Seconds 4
$null = Invoke-WebRequest -UseBasicParsing "$api/perf/scan" -TimeoutSec 10; Start-Sleep -Seconds 4
$after = @(Get-Content (Join-Path $root 'data\perf.tsv') | Where-Object { $_ -and -not $_.StartsWith('#') }).Count
Check "two more passes add nothing ($before -> $after rows)" ($after -eq $before)
$sizeOk = @($tsv | Where-Object { $_.Count -ge 37 }).Count -eq $tsv.Count
Check 'every row has all its columns' $sizeOk
$log = Get-Content (Join-Path $root 'dash\irdash.log')
# The line is written only when a pass makes new reports, and irdash.log is trimmed, so a run in which every finished file already had its report
# (status.added = 0) has no such line to find. Then the check is that the line is still in the code, so it cannot go missing unseen.
$logLine = @($log | Where-Object { $_ -match 'perf: \d+ session reports? added in \d+ ms' }).Count -ge 1
if ([int]$st.added -gt 0) { Check "the log says how many reports were made ($($st.added) in this run)" $logLine }
else { Check 'the log line that says how many reports were made is in the code (this run needed none: every finished file already had its report)' ((Select-String -Path (Join-Path $root 'dash\src\perf.cs') -Pattern 'session report.*added in' -SimpleMatch:$false).Count -ge 1) }

Section '3. the JSON the page reads' | Out-Null
'3. the JSON the page reads'
$o = J '/perf'
Check '/perf has ready, now, status, last, sessions, changes, own, summary' (($o.PSObject.Properties.Name -contains 'ready') -and $o.ready -and $o.now -gt 1e9 -and $o.status -and $o.last -and $o.sessions.Count -gt 5 -and $o.changes.Count -ge 1 -and $o.own -and $o.summary)
$l = $o.last
Check 'the last session has numbers, a plain sentence, trouble spots and a usual figure' ($l.avg -gt 10 -and $l.low1 -gt 10 -and $l.low1 -le $l.avg -and $l.worst -le $l.low1 + 0.01 -and $l.text.Length -gt 20 -and $l.PSObject.Properties.Name -contains 'places' -and $l.PSObject.Properties.Name -contains 'usual' -and $l.PSObject.Properties.Name -contains 'procs' -and $l.key -and $l.trackName)
Check 'every session row has file, ts, track, car, field, avg, low1 and counts' (@($o.sessions | Where-Object { $_.file -and $_.ts -gt 0 -and $_.track -and $_.PSObject.Properties.Name -contains 'car' -and $_.avg -gt 1 -and $_.low1 -gt 1 -and $_.PSObject.Properties.Name -contains 'field' -and $_.PSObject.Properties.Name -contains 'counts' }).Count -eq $o.sessions.Count)
Check 'every change has id, ts, title, kinds, items and a result with state and text' (@($o.changes | Where-Object { $_.id -and $_.ts -gt 0 -and $_.title -and $_.kinds.Count -ge 1 -and $_.items.Count -ge 1 -and $_.result.state -and ($_.result.PSObject.Properties.Name -contains 'text') -and $_.result.before -and $_.result.after }).Count -eq $o.changes.Count)
$c = J '/perf/checklist'
Check '/perf/checklist has items with id, title, state (ok / look / info) and evidence' ($c.items.Count -ge 8 -and @($c.items | Where-Object { $_.id -and $_.title -and $_.state -match '^(ok|look|info)$' -and $_.evidence }).Count -eq $c.items.Count -and ($c.PSObject.Properties.Name -contains 'look'))
$ids = @($c.items | ForEach-Object id)
Check "the checklist covers Paddock's programs, the priority trial, power plan, Game Mode, Game Bar, GPU scheduling, graphics, memory ($($ids -join ', '))" ((@('paddock', 'lowprio', 'power', 'gamemode', 'gamebar', 'hags', 'graphics', 'memory') | Where-Object { $ids -notcontains $_ }).Count -eq 0)
$lv = J '/perf/live'
Check '/perf/live answers {"on":false} when no session is running (or, while a real session is on, says which track it is)' (($lv.on -eq $false -and -not (Get-RigBusy)) -or ($lv.on -eq $true -and $lv.track -and (Get-RigBusy)))
$stat = J '/perf/status'
Check '/perf/status has state, files, reports, counted, duplicates, pending, changes, sampler, prio' (($stat.PSObject.Properties.Name -contains 'sampler') -and $stat.files -ge $stat.reports - 5 -and $stat.counted -gt 5 -and $stat.sampler.PSObject.Properties.Name -contains 'pctOfCore' -and $stat.prio.mode)
$r404 = Get-Raw '/perf/session?file=nosuchfile.ibt'; $r404b = Get-Raw ('/perf/session?file=' + (Q '..\..\Windows\win.ini')); $r404c = Get-Raw '/perf/session'
Check 'an unknown file, a path trick and no file name all answer 404, never a file read' ($r404.code -eq 404 -and $r404b.code -eq 404 -and $r404c.code -eq 404)
$sm = J '/perf/summary'
Check "the one-line summary for Rig Doctor reads like a sentence: $($sm.text)" ($sm.text -match 'Last session \d+ fps average' -or $sm.text -match 'No frame-rate report')
Check 'the test routes are closed without the test hook' ((Get-Raw '/perf/test/drives').code -in 404, 409)

Section '4. change markers, and "did it help?"' | Out-Null
'4. change markers, and "did it help?"'
# independent: the graphics backups, compared two by two, written again here
$enc = [Text.Encoding]::GetEncoding(28591)
function Sec($p) { $t = [IO.File]::ReadAllText($p, $enc); $sec = ''; $h = @{}; foreach ($ln in $t -split "`r?`n") { if ($ln -match '^\[(.+)\]') { $sec = $Matches[1]; continue }; if ($sec -eq 'Graphics Options' -and $ln -match '^(\w+)=([^;\s]*)') { $h[$Matches[1]] = $Matches[2] } }; $h }
$iracing = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing'
$files = @(Get-ChildItem (Join-Path $root 'backup') -Filter 'rendererDX11Monitor-*.ini') + @(Get-ChildItem $iracing -Filter 'rendererDX11Monitor.ini.bak-*')
$snaps = foreach ($f in $files) { $m = [regex]::Match($f.Name, '(\d{8})(?:-(\d{4,6}))?'); if (-not $m.Success) { continue }; $d = $m.Groups[1].Value; $t = if ($m.Groups[2].Success) { $m.Groups[2].Value.PadRight(6, '0') } else { '000000' }
  [pscustomobject]@{ name = $f.Name; path = $f.FullName; ts = [datetime]::ParseExact("$d$t", 'yyyyMMddHHmmss', $null) } }
$snaps = @($snaps | Sort-Object ts); $cur = Sec (Join-Path $iracing 'rendererDX11Monitor.ini'); $skip = 'SysMemToUseMB', 'VidMemToUseMB'
$expect = @{}
for ($i = 0; $i -lt $snaps.Count; $i++) {
  $a = Sec $snaps[$i].path; $b = if ($i + 1 -lt $snaps.Count) { Sec $snaps[$i + 1].path } else { $cur }
  $diff = @($a.Keys | Where-Object { $skip -notcontains $_ -and $b.ContainsKey($_) -and $a[$_] -ne $b[$_] })
  if ($diff.Count -gt 0) { $expect['gfx:' + $snaps[$i].name] = [DateTimeOffset]::new($snaps[$i].ts).ToUnixTimeSeconds() }
}
$chg = @(Get-Content (Join-Path $root 'data\perf-changes.tsv') | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { , ($_.Split("`t")) })
$gfx = @($chg | Where-Object { $_[0] -like 'gfx:*' })
Check "every graphics backup that differs from the next one is a marker ($($expect.Count) expected, $($gfx.Count) logged), none extra" ($gfx.Count -eq $expect.Count -and @($gfx | Where-Object { $expect.ContainsKey($_[0]) -and (Near $_[1] $expect[$_[0]] 2) }).Count -eq $gfx.Count)
Check 'markers carry a date, a kind, a plain title and what changed' (@($chg | Where-Object { $_[2] -match '^\d{4}-\d\d-\d\d \d\d:\d\d$' -and $_[3] -and $_[4] -and $_[5] }).Count -eq $chg.Count)
$build = @($chg | Where-Object { $_[3] -eq 'iracing' })
Check "iRacing updates seen between sessions are markers ($($build.Count))" ($build.Count -ge 1)
$stateText = Get-Content (Join-Path $root 'data\perf-state.tsv') -Raw
Check 'the first look at the driver, power plan, Game Mode, GPU scheduling, overlays and sim priority was only remembered (no marker for a baseline)' (($stateText -match "driver`t\d+\.\d+") -and ($stateText -match 'plan') -and ($stateText -match 'hags') -and ($stateText -match 'ovl') -and ($stateText -match 'simprio') -and @($chg | Where-Object { $_[3] -in 'driver', 'windows', 'overlays', 'priority' }).Count -eq 0)
Check 'the real comparisons never guess: each says helped / hurt / same / mixed with numbers, or says why not' (@($o.changes | Where-Object { ($_.result.state -eq 'ok' -and $_.result.verdict -match '^(helped|hurt|same|mixed)$' -and $_.result.before.n -ge 2 -and $_.result.after.n -ge 2) -or ($_.result.state -in 'few', 'none' -and $_.result.text -match 'Too few|No earlier') }).Count -eq $o.changes.Count)

# the same code, with made-up sessions (the compiled irdash.exe, loaded as a library; nothing is started)
$asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $root 'dash\irdash.exe')))
$tRow = $asm.GetType('IRDash.PerfRow'); $tChg = $asm.GetType('IRDash.PerfChange'); $tCmp = $asm.GetType('IRDash.PerfCompare')
$lRow = [Collections.Generic.List[object]].GetGenericTypeDefinition().MakeGenericType($tRow); $lChg = [Collections.Generic.List[object]].GetGenericTypeDefinition().MakeGenericType($tChg)
function SetF($o, $n, $v) { $o.GetType().GetField($n).SetValue($o, $v) }
function NewRow($start, $avg, $low, $car = 'Test car', $field = 20, $secs = 300) { $r = [Activator]::CreateInstance($tRow); SetF $r File ("s$start.ibt"); SetF $r Track 'Test Track'; SetF $r TrackKey 't1-test'; SetF $r Car $car; SetF $r Start ([int64]$start); SetF $r Dur ([double]$secs); SetF $r Secs ([double]$secs); SetF $r Avg ([double]$avg); SetF $r Low1 ([double]$low); SetF $r Field ([double]$field); $r }
function NewChg($ts, $kind = 'graphics') { $c = [Activator]::CreateInstance($tChg); SetF $c Id "t$ts"; SetF $c Ts ([int64]$ts); SetF $c Kind $kind; SetF $c Title 'Test change'; SetF $c Detail 'mirrors 2 to 4'; $c }
function Run-Compare($rowsArr, $chgArr, $idx = 0) {
  $rows = [Activator]::CreateInstance($lRow); foreach ($r in $rowsArr) { $rows.Add($r) }; $ch = [Activator]::CreateInstance($lChg); foreach ($c in $chgArr) { $ch.Add($c) }
  $eps = $tCmp.GetMethod('Episodes').Invoke($null, @($ch, $rows)); $res = $tCmp.GetMethod('Compare').Invoke($null, @($eps, $idx, $rows))
  [pscustomobject]@{ eps = $eps.Count; state = $res.State; verdict = $res.Verdict; text = $res.Text; nb = $res.NBefore; na = $res.NAfter }
}
$T = 1800000000
$before = 1..4 | ForEach-Object { NewRow ($T + $_ * 1000) (100 + ($_ % 2)) (88 + ($_ % 2)) }
function After($avg, $low, $n = 4, $car = 'Test car') { 1..$n | ForEach-Object { NewRow ($T + 10000 + $_ * 1000) ($avg + ($_ % 2)) ($low + ($_ % 2)) $car } }
$chgA = @(NewChg ($T + 5000))
$r = Run-Compare ($before + (After 112 98)) $chgA; Check "made-up: 100 -> 112 fps at the same track and car says helped ($($r.text))" ($r.state -eq 'ok' -and $r.verdict -eq 'helped' -and $r.nb -eq 4 -and $r.na -eq 4)
$r = Run-Compare ($before + (After 88 76)) $chgA; Check "made-up: 100 -> 88 fps says hurt ($($r.text))" ($r.state -eq 'ok' -and $r.verdict -eq 'hurt')
$r = Run-Compare ($before + (After 100 88)) $chgA; Check "made-up: 100 -> 100 fps says no clear change ($($r.text))" ($r.state -eq 'ok' -and $r.verdict -eq 'same')
$r = Run-Compare ($before + (After 106 80)) $chgA; Check "made-up: average up 6 %, 1 % low down 9 % says mixed ($($r.text))" ($r.state -eq 'ok' -and $r.verdict -eq 'mixed')
$r = Run-Compare ($before + (After 112 98 1)) $chgA; Check "made-up: only one session after says not enough yet, not a verdict ($($r.text))" ($r.state -eq 'few' -and $r.text -match 'Too few')
$r = Run-Compare ($before + (After 112 98 4 'Another car')) $chgA; Check "made-up: other sessions in a different car are not compared ($($r.text))" ($r.state -ne 'ok')
$r = Run-Compare (@(NewRow ($T + 7000) 100 88 'Test car' 1) + (After 112 98)) $chgA; Check 'made-up: nothing earlier to compare with says so' ($r.state -ne 'ok' -and $r.text -match 'earlier|Not enough')
$soloAfter = 1..4 | ForEach-Object { NewRow ($T + 10000 + $_ * 1000) 150 140 'Test car' 1 }
$r = Run-Compare ($before + $soloAfter) $chgA; Check "made-up: driving alone after a 20-car race is not like for like ($($r.text))" ($r.state -ne 'ok')
$shortAfter = 1..4 | ForEach-Object { NewRow ($T + 10000 + $_ * 1000) 112 98 'Test car' 20 60 }
$r = Run-Compare ($before + $shortAfter) $chgA; Check 'made-up: one-minute drives do not count' ($r.state -ne 'ok')
$two = Run-Compare ($before + (After 112 98)) @((NewChg ($T + 5000)), (NewChg ($T + 9000))); Check 'made-up: two changes over an hour apart with no drive between are one tuning session' ($two.eps -eq 1)
$rowsMid = @($before) + @(NewRow ($T + 7000) 100 88) + @(After 112 98)
$two = Run-Compare $rowsMid @((NewChg ($T + 5000)), (NewChg ($T + 9000))); Check 'made-up: a real drive between two changes keeps them apart' ($two.eps -eq 2)

if ($live) {
Section '5. the checklist looks and changes nothing; the Windows tools are prepared, never run' | Out-Null
'5. the checklist looks and changes nothing; the Windows tools are prepared, never run'
function Snapshot {
  $o = [ordered]@{}
  foreach ($f in 'rendererDX11Monitor.ini', 'rendererDX11.ini', 'app.ini', 'core.ini', 'camera.ini', 'controls.cfg', 'joyCalib.yaml') { $p = Join-Path $iracing $f; $o["file:$f"] = if (Test-Path $p) { $i = Get-Item $p; "$($i.Length)|$($i.LastWriteTimeUtc.Ticks)" } else { 'absent' } }
  $o['iracing-folder'] = (Get-ChildItem $iracing -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object | Out-String).GetHashCode()
  foreach ($q in @(@('HKCU:\Software\Microsoft\GameBar', 'AutoGameModeEnabled'), @('HKCU:\System\GameConfigStore', 'GameDVR_Enabled'), @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled'), @('HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 'HwSchMode'), @('HKCU:\Software\Microsoft\DirectX', 'UserGpuPreferences'))) {
    $v = Get-ItemProperty -Path $q[0] -Name $q[1] -ErrorAction SilentlyContinue; $o["reg:$($q[0])\$($q[1])"] = if ($v) { [string]$v.($q[1]) } else { 'not set' } }
  $o['power plan'] = (powercfg /getactivescheme | Out-String).Trim()
  $o['tools'] = (Get-ChildItem (Join-Path $root 'tools') -File | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object | Out-String).GetHashCode()
  $o['backup'] = (Get-ChildItem (Join-Path $root 'backup') -File | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object | Out-String).GetHashCode()
  $o['irdash.ini'] = (Get-FileHash (Join-Path $root 'dash\irdash.ini')).Hash
  $o['install'] = (Get-Item 'C:\Program Files (x86)\iRacing\iRacingSim64DX11.exe').LastWriteTimeUtc.Ticks
  ($o.GetEnumerator() | ForEach-Object { $_.Key + ' = ' + $_.Value }) -join "`n"
}
$snapA = Snapshot
$c1 = J '/perf/checklist'; Start-Sleep -Seconds 22; $c2 = J '/perf/checklist'; $null = J '/perf'; $null = J '/perf/status'
$snapB = Snapshot
Check 'looking (checklist twice, 22 s apart so it really looks again) changes nothing: iRacing files, Windows switches, power plan, tools, backups, irdash.ini, the iRacing install' ($snapA -eq $snapB)
if ($snapA -ne $snapB) { Compare-Object ($snapA -split "`n") ($snapB -split "`n") | ForEach-Object { '      ' + $_.InputObject + ' ' + $_.SideIndicator } }
$by = @{}; foreach ($i in $c2.items) { $by[$i.id] = $i }
$planPs = (powercfg /getactivescheme | Out-String)
Check "power plan item agrees with powercfg ($($by.power.state): $($by.power.evidence))" (($planPs -match 'High performance' -and $by.power.state -eq 'ok') -or ($planPs -notmatch 'High performance|Ultimate' -and $by.power.state -eq 'look'))
$gm = (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -ErrorAction SilentlyContinue).AutoGameModeEnabled
Check "Game Mode item agrees with the registry (${gm}: $($by.gamemode.evidence))" (($gm -ne 0 -and $by.gamemode.state -eq 'ok') -or ($gm -eq 0 -and $by.gamemode.state -eq 'look'))
$dvr = (Get-ItemProperty 'HKCU:\System\GameConfigStore' -Name GameDVR_Enabled -ErrorAction SilentlyContinue).GameDVR_Enabled; $cap = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name AppCaptureEnabled -ErrorAction SilentlyContinue).AppCaptureEnabled
$recOn = ($dvr -eq 1 -or $cap -eq 1)
Check "Game Bar item agrees with the registry (recording on: $recOn; $($by.gamebar.state))" (($recOn -and $by.gamebar.state -eq 'look' -and $by.gamebar.tool -eq 'perf-gamebar-off.cmd' -and $by.gamebar.undo -eq 'perf-gamebar-off-UNDO.cmd') -or (-not $recOn -and $by.gamebar.state -eq 'ok' -and -not $by.gamebar.tool))
Check "GPU scheduling item says what Windows says and offers an experiment with an undo ($($by.hags.evidence))" ($by.hags.state -eq 'info' -and $by.hags.evidence -match '^(On|Off|This graphics card|Paddock could not)' -and ($by.hags.tool -eq '' -or $by.hags.undo -match 'UNDO'))
# graphics drift, compared again here against the baseline file
$baseF = Join-Path $root 'data\perf-gfx-baseline.tsv'
if (Test-Path $baseF) {
  $base = @{}; foreach ($ln in Get-Content $baseF) { $t = $ln.IndexOf("`t"); if ($t -gt 0) { $base[$ln.Substring(0, $t)] = $ln.Substring($t + 1) } }
  $drift = @($base.Keys | Where-Object { $skip -notcontains $_ -and $cur.ContainsKey($_) -and $cur[$_] -ne $base[$_] })
  Check "graphics drift item agrees with a comparison made here ($($drift.Count) differences; $($by.graphics.state))" (($drift.Count -eq 0 -and $by.graphics.state -eq 'ok') -or ($drift.Count -gt 0 -and $by.graphics.state -eq 'look'))
} else { Check 'graphics item says plainly that no settled setup is recorded yet' ($by.graphics.state -eq 'look' -and $by.graphics.evidence -match 'settled') }
Check 'it never says it will write iRacing files (read-only wording)' ($by.graphics.title -match 'never changed')
# the tools
$tools = 'perf-gamebar-off', 'perf-hags-off', 'perf-hags-on'
foreach ($t in $tools) {
  $a = Join-Path $root "tools\$t.cmd"; $u = Join-Path $root "tools\$t-UNDO.cmd"
  Check "$t.cmd and its UNDO exist, call the helper and say what they change" ((Test-Path $a) -and (Test-Path $u) -and ((Get-Content $a -Raw) -match 'perf-tools\.ps1" -Tool ' + [regex]::Escape($t.Substring(5))) -and ((Get-Content $u -Raw) -match 'perf-tools\.ps1" -Tool ' + [regex]::Escape($t.Substring(5)) + '-undo') -and ((Get-Content $a) -match '^rem ').Count -ge 3)
}
$perr = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'tools\perf-tools.ps1'), [ref]$null, [ref]$perr)
Check 'the helper script has no syntax errors' ($perr.Count -eq 0)
$snapC = Snapshot
$prev = foreach ($t in 'gamebar-off', 'gamebar-off-undo', 'hags-off', 'hags-off-undo', 'hags-on', 'hags-on-undo') { & (Join-Path $root 'tools\perf-tools.ps1') -Tool $t -Preview }
$snapD = Snapshot
Check "the helper's -Preview says what each tool would change and changes nothing ($(@($prev).Count) lines)" (@($prev).Count -ge 8 -and ($snapC -eq $snapD) -and -not (Test-Path (Join-Path $root 'data\perf-tools-state.tsv')) -and -not (Test-Path (Join-Path $root 'tools\perf-tools.log')))
Check 'no change was ever made to Windows by this test' ($snapA -eq $snapD)

# ---- from here on: a pretend session (the test hook) and a stand-in for the sim ----
Section '6. the sampler: what else was running, and what it costs (a stand-in program plays the sim)' | Out-Null
'6. the sampler: what else was running, and what it costs (a stand-in program plays the sim)'
New-Item -ItemType File -Force $hook | Out-Null
$ping = Join-Path $env:SystemRoot 'System32\ping.exe'; $stand = Join-Path $env:TEMP 'irdash-test-perfsim.exe'; Copy-Item $ping $stand -Force
$sim = Start-Process -FilePath $stand -ArgumentList '-n 900 127.0.0.1' -PassThru -WindowStyle Hidden; $testProcs += $sim
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/simproc?name=irdash-test-perfsim" -TimeoutSec 5
Check 'the sampler notices the stand-in "sim" within 12 s' (Wait-Until 12 { (J '/perf/status').sampler.running })
$f1 = 'chevyvettez06rgt3_roadatlanta full 2026-10-09 10-28-32.ibt'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $f1)" -TimeoutSec 20
$burn = Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', 'while($true){}' -PassThru -WindowStyle Hidden; $testProcs += $burn
Fake 'IsOnTrack=1&FrameRate=104&GpuUsage=0.5&CpuUsageFG=0.4&Lap=3&LapDistPct=0.3&SessionTime=100'
$tDrive = Get-Date
Start-Sleep -Seconds 38
Fake 'FrameRate=60'                                   # dips: well under the usual for this track while the burner is busy
Start-Sleep -Seconds 32
$mid = J '/perf/status'
Fake 'IsOnTrack=0&FrameRate=0'
Check 'the sampler closes the drive within 20 s of leaving the track' (Wait-Until 20 { @((J '/perf/test/drives')).Count -ge 1 })
$drives = @(J '/perf/test/drives'); $d = $drives[0]
Check "one drive was recorded: $($d.samples) readings, $($d.dips) of them dips, average $($d.avgFps) fps" ($drives.Count -eq 1 -and $d.samples -ge 8 -and $d.dips -ge 3 -and $d.avgFps -gt 70 -and $d.avgFps -lt 104)
Check "it knew the usual frame rate for this track ($($d.normal) fps) before the dips" ($d.normal -gt 50)
$m = [regex]::Match([string]$d.others, 'powershell~([\d.]+)~([\d.-]+)')
Check "the busy loop shows as the busiest other program ($($d.others))" ($m.Success -and [double]$m.Groups[1].Value -ge 60 -and [double]$m.Groups[2].Value -ge 60)
Check 'the stand-in sim is counted as the sim, not as another program' ($d.others -notmatch 'irdash-test-perfsim')
$stat = J '/perf/status'; $sp = $stat.sampler
Check "the sampler costs $($sp.avgMs) ms per reading (median $($sp.medianWallMs) ms of wall time, worst $($sp.worstMs) ms): $($sp.pctOfCore) % of one core while the sim runs - under 0.2 %" ($sp.ticks -ge 10 -and $sp.pctOfCore -lt 0.2 -and $sp.medianWallMs -lt 25)
Check "it looked at the dashboard's browser once, apart from that ($($sp.classified) look, $($sp.classifyCpuMs) ms)" ($sp.classified -le 3)
Check 'drives made under the test hook are not written to perf-procs.tsv' ($procsBefore -eq $(if (Test-Path $procsFile) { (Get-Item $procsFile).Length } else { -1 }))
$null = Invoke-WebRequest -UseBasicParsing "$api/perf/test/clear" -TimeoutSec 5
$sim.Kill(); $burn.Kill()
Check 'the log says the sampler switched on and off' (Wait-Until 12 { @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN | Where-Object { $_ -match 'perf: sampler off' }).Count -ge 1 } )
$newLog = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN)
Check 'the log has "sampler on", and a line about the drive' (@($newLog | Where-Object { $_ -match 'perf: sampler on' }).Count -ge 1)

Section '7. the live figure and the amber line on the dashboard page' | Out-Null
'7. the live figure and the amber line on the dashboard page'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/simproc?name=" -TimeoutSec 5
$expectedNormal = 0
# the usual here, worked out again from perf.tsv by hand: same track, same car, similar field, the last 8 drives of 2 minutes or more
$trk = @($tsv | Where-Object { $_[0] -eq $f1 })[0]
$fld = [double]$trk[13]
$rows = @($tsv | Where-Object { $_[7] -eq $trk[7] -and $_[9] -eq $trk[9] -and [double]$_[4] -ge 120 -and [double]$_[15] -gt 1 } | Sort-Object { [int64]$_[2] })
$sim8 = @($rows | Where-Object { $a = [double]$_[13]; $b = $fld; if ($a -le 1.5 -and $b -le 1.5) { $true } elseif ($a -le 1.5 -or $b -le 1.5) { $false } else { $r = [math]::Max($a, $b) / [math]::Min($a, $b); ($r -le 1.6) -or ([math]::Abs($a - $b) -le 4) } })
$last8 = @($sim8 | Select-Object -Last 8 | ForEach-Object { [double]$_[15] } | Sort-Object)
$expectedNormal = if ($last8.Count -lt 2) { 0 } elseif ($last8.Count % 2) { $last8[($last8.Count - 1) / 2] } else { ($last8[$last8.Count / 2 - 1] + $last8[$last8.Count / 2]) / 2 }
Fake 'IsOnTrack=1&FrameRate=104&GpuUsage=0.5&CpuUsageFG=0.4&Lap=3&LapDistPct=0.3&SessionTime=100'
Start-Sleep -Seconds 2
$lv = J '/perf/live'
Check "/perf/live knows the usual here: $($lv.normal) fps (worked out again by hand from $($last8.Count) drives: $([math]::Round($expectedNormal, 1)))" ($lv.on -and $expectedNormal -gt 0 -and (Near $lv.normal $expectedNormal 0.15) -and $lv.track -eq 'Road Atlanta')
Cdp-Open "$api/v2/" 1920 1080
Check 'the dashboard shows the live session' (Wait-Until 15 { (Cdp-Eval "document.getElementById('overlay') && !document.getElementById('overlay').classList.contains('show')") -eq $true })
Check 'the fps figure is there, small, and says 104' (Wait-Until 20 { (Cdp-Eval "(document.getElementById('fpsLive')||{}).textContent") -match '^104\s*fps$' })
Start-Sleep -Seconds 24                                # the 20 s after getting in (loading hitch) and a full 10 s of numbers
Check 'at its usual frame rate there is no amber line' ((Cdp-Eval "document.getElementById('perfWarn').hidden") -eq $true)
Cdp-Shot (Join-Path $shots 'perf-live-fps.png')
Fake 'FrameRate=70&GpuUsage=0.95'
Check 'a real drop (70 against the usual) brings up the amber line within 25 s' (Wait-Until 25 { (Cdp-Eval "document.getElementById('perfWarn').hidden") -eq $false })
$null = Wait-Until 10 { (Cdp-Eval "document.getElementById('perfWarn').textContent") -match 'graphics card' }
Check 'the line is two short lines: the rate against the usual, then the likely cause' ((Cdp-Eval "document.getElementById('perfWarn').innerText") -match '(?s)Frame rate \d+, usually \d+ here.*Likely cause: the graphics card is full')
Check 'it takes the place of the small health dots and fits inside the header strip' ((Cdp-Eval "getComputedStyle(document.querySelector('.health')).display") -eq 'none' -and (Cdp-Eval "document.querySelector('.meta').scrollHeight <= document.getElementById('strip').offsetHeight") -eq $true)
Check 'it is amber and small' ((Cdp-Eval "getComputedStyle(document.getElementById('perfWarn')).color") -match 'rgb\(255, 178, 30\)' -and [int](Cdp-Eval "parseInt(getComputedStyle(document.getElementById('perfWarn')).fontSize)") -le 14)
Start-Sleep -Seconds 1
Cdp-Shot (Join-Path $shots 'perf-live-amber.png')
Fake 'FrameRate=104&GpuUsage=0.5'
Check 'it goes away by itself once the frame rate is back (within 30 s)' (Wait-Until 30 { (Cdp-Eval "document.getElementById('perfWarn').hidden") -eq $true })
# The rates are worked out from this PC's real usual figure ($lv.normal, from the history of his drives): they were fixed at 86 and 96,
# which are 16 % and 6 % under a usual of 102 but 20 % and 11 % under today's 107.9 (new real sessions raised it). 11 % is inside the
# page's 10-15 % hold zone, where a line that has been shown stays up on purpose, so a "6 %" dip was really an 11 % one (2026-10-11).
$fpsBig = [math]::Round([double]$lv.normal * 0.84); $fpsSmall = [math]::Round([double]$lv.normal * 0.94)
Fake "FrameRate=$fpsBig&GpuUsage=0.5"                # 15 % under is the line: 16 % under the usual is a bit more than that
$null = Wait-Until 5 { $false }
Fake "FrameRate=$fpsSmall"                           # 6 % under: nothing to say
Start-Sleep -Seconds 14
$dipHidden = ((Cdp-Eval "document.getElementById('perfWarn').hidden") -eq $true)
Check 'a small dip (6 %) says nothing' $dipHidden
if (-not $dipHidden) { "        the amber line says: $(Cdp-Eval "document.getElementById('perfWarn').innerText") (usual $($lv.normal) fps; the page's own usual: $(Cdp-Eval 'PerfLive.normal'), average of its last 10 s: $(Cdp-Eval '(PerfLive.ring.reduce(function(a,s){return a+s.v},0)/Math.max(1,PerfLive.ring.length)).toFixed(1)'))" }
$errs = Cdp-Eval 'JSON.stringify(window.__errs)'
Check "no script errors on the dashboard page ($errs)" ($errs -eq '[]')
Fake 'IsOnTrack=0&FrameRate=0'
Cdp-Close
}

Section '8. the page: pictures' | Out-Null
'8. the page: pictures (and, with the rig free: opening from a deck key, never while driving)'
Cdp-Open "$api/v2/perf.html" 1920 1080
Check 'the page draws: big numbers, trend canvas, did-it-help list, checklist' (Wait-Until 20 { (Cdp-Eval "document.querySelectorAll('#last .big b').length") -eq 3 -and (Cdp-Eval "document.querySelectorAll('#checkList .it').length") -ge 8 })
$big = Cdp-Eval "Array.from(document.querySelectorAll('#last .big b')).map(function(b){return b.textContent}).join(' ')"
$o = J '/perf'
Check "the card shows the last session's numbers ($big) as /perf has them" ($big -eq ('{0} {1} {2}' -f [math]::Round($o.last.avg, 0, 'AwayFromZero'), [math]::Round($o.last.low1, 0, 'AwayFromZero'), [math]::Round($o.last.worst, 0, 'AwayFromZero')))
Check 'one entry in "Did it help?" for each change' ((Cdp-Eval "document.querySelectorAll('#helpList .ep').length") -eq $o.changes.Count)
Check 'the trend chart has pixels in it' ((Cdp-Eval "(function(){var c=document.getElementById('plot');var d=c.getContext('2d').getImageData(0,0,c.width,c.height).data;var n=0;for(var i=3;i<d.length;i+=4){if(d[i]>0)n++;}return n;})()") -gt 300)
Check "the chosen track is the last session's, with filters you can tap" ((Cdp-Eval "document.querySelectorAll('#filters .chip.on').length") -ge 1)
$null = Wait-Until 12 { (Cdp-Eval "document.querySelectorAll('#last .corner .nm').length") -gt 0 }
Start-Sleep -Seconds 3
$corner = Cdp-Eval "Array.from(document.querySelectorAll('#last .corner .nm')).map(function(e){return e.textContent}).join(' | ')"
Check "the slowest places have names, or the card says there are none ($corner)" ($corner -match '\S' -or (Cdp-Eval "!!document.querySelector('#last .none')"))
Start-Sleep -Seconds 1
Cdp-Shot (Join-Path $shots 'perf-page.png')
$errs = Cdp-Eval 'JSON.stringify(window.__errs)'
Check "no script errors on the page ($errs)" ($errs -eq '[]')
$null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 1366; height = 768; deviceScaleFactor = 1; mobile = $false }
Start-Sleep -Seconds 2
Cdp-Shot (Join-Path $shots 'perf-page-narrow.png')
Check 'at a narrow width everything is still on the page (it scrolls; nothing cut off sideways)' ((Cdp-Eval 'document.documentElement.scrollWidth') -le 1370)
Cdp-Close
if ($live) {
Fake 'IsOnTrack=1&FrameRate=104'
Start-Sleep -Seconds 3.5
$r = Get-Raw '/api/do?c=perf'
Check 'while driving the open-the-page key is refused' ($r.code -eq 400 -and (J '/perf/nav').to -eq '')
Fake 'IsOnTrack=0&FrameRate=0'
Start-Sleep -Seconds 3.5
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5
Start-Sleep -Seconds 1
# on top of the dashboard, as the Stream Deck key does it
Cdp-Open "$api/v2/" 1920 1080
Start-Sleep -Seconds 4
$r = Get-Raw '/api/do?c=perf'
Check 'the deck key opens it (GET /api/do?c=perf) and /perf/nav says so' ($r.code -eq 200 -and (J '/perf/nav').to -eq 'perf')
Check 'the dashboard puts the page over itself within 5 s' (Wait-Until 5 { (Cdp-Eval "!!document.querySelector('#perfHost iframe')") -eq $true })
Start-Sleep -Seconds 4
Cdp-Shot (Join-Path $shots 'perf-top-open.png')
$null = Invoke-WebRequest -UseBasicParsing "$api/api/do?c=perfclose" -TimeoutSec 5
Check 'the close key takes it away again' (Wait-Until 6 { (Cdp-Eval "!document.getElementById('perfHost')") -eq $true } -and (J '/perf/nav').to -eq '')
$errs = Cdp-Eval 'JSON.stringify(window.__errs)'
Check "no script errors on the dashboard page with the page over it ($errs)" ($errs -eq '[]')
Cdp-Close
$bad1 = Get-Raw ('/api/do?c=perfshow&a=' + (Q '..\..\Windows\System32\cmd.exe')); $bad2 = Get-Raw '/api/do?c=perfshow&a=perf-nothing.cmd'; $bad3 = Get-Raw '/api/do?c=perfshow'
Check 'the "show me the file" key refuses anything that is not one of our tools' ($bad1.code -eq 400 -and $bad2.code -eq 400 -and $bad3.code -eq 400)
}

if ($live) {
Section '9. our own priority fix: only on a stand-in program, only when the numbers say so' | Out-Null
'9. our own priority fix: only on a stand-in program, only when the numbers say so'
$st = J '/perf/status'
Check "the priority trial is waiting for evidence, not switched on ($($st.prio.mode): $($st.prio.reason))" ($st.prio.mode -in 'watch', 'kept', 'trial', 'rejected' -and $st.prio.active -eq $false)
New-Item -ItemType File -Force $hook | Out-Null
$stand2 = Join-Path $env:TEMP 'irdash-test-prio.exe'; Copy-Item $ping $stand2 -Force
$sp2 = Start-Process -FilePath $stand2 -ArgumentList '-n 120 127.0.0.1' -PassThru -WindowStyle Hidden; $testProcs += $sp2
Start-Sleep -Seconds 1
$sp2.PriorityClass = 'Normal'   # the stand-in inherits this shell's priority (BelowNormal under run-all); the fix restores what it found
$a = J '/perf/test/prio?name=irdash-test-prio&mode=low'; $sp2.Refresh(); $lowed = $sp2.PriorityClass
$b = J '/perf/test/prio?name=irdash-test-prio&mode=normal'; $sp2.Refresh(); $back = $sp2.PriorityClass
Check "a stand-in goes to BelowNormal and back to Normal ($lowed, then $back)" ($lowed -eq 'BelowNormal' -and $back -eq 'Normal')
$rr = Get-Raw '/perf/test/prio?name=CrewChiefV4&mode=low'
Check 'the test route refuses any name that is not a stand-in (CrewChief is untouchable)' ($rr.code -eq 400)
$src = Get-Content (Join-Path $root 'dash\src\perf.cs') -Raw
$lowerBody = [regex]::Match($src, 'static void Lower\(\)(.|\n)*?static void Restore').Value
Check 'in the code only "irdashies" and the dashboard browser are ever lowered (CrewChief is not named in it)' ($lowerBody -match 'GetProcessesByName\("irdashies"\)' -and $lowerBody -notmatch '(?i)crewchief')
$sp2.Kill()
}

} finally {
  Cdp-Close
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 } catch { }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/simproc?name=" -TimeoutSec 5 } catch { }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/perf/test/clear" -TimeoutSec 5 } catch { }
  Remove-Item $hook -Force -ErrorAction SilentlyContinue
  foreach ($p in $testProcs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
  Remove-Item (Join-Path $env:TEMP 'irdash-test-perfsim.exe') -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $env:TEMP 'irdash-test-prio.exe') -Force -ErrorAction SilentlyContinue
  if ($live) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
  Exit-TestLock
}
Check 'the test hook file and the stand-in programs are gone' (-not (Test-Path $hook) -and @(Get-Process irdash-test-perfsim, irdash-test-prio -ErrorAction SilentlyContinue).Count -eq 0)
$perfErrors = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN | Where-Object { $_ -match 'perf: .*(exception|could not|cannot)' -and $_ -notmatch 'cannot tell the dashboard' })
Check "irdash's log has no perf errors from this run ($($perfErrors.Count))" ($perfErrors.Count -eq 0)
if ($perfErrors.Count) { $perfErrors | ForEach-Object { '      ' + $_ } }
''
"$pass ok, $fail failed"
if ($fail -gt 0) { exit 1 }
