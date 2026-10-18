# C-40 Session Review v2 (docs\TASKS.md C-40, look = docs\mockups\session-review.png). Everything offline, out of the car only (guard.ps1):
#   1. copies of old sessions (the vault's own copies, never Documents\iRacing, never the newest file) and a compile
#   2. the data (dash\src\sessionreview.cs) against an independent read of the raw .ibt: lap times = iRacing's own figure to 0.001,
#      sectors cut at the file's own split points (SplitTimeInfo), optimal, consistency, flags, reference never the lap itself
#   3. the rules: previous best from other sessions / next best lap when there is no history, notes only by the C-30 thresholds
#   4. the page in headless Chrome against fixtures made from real laps: numbers, purple/green/yellow rule, map, chart, no overlaps
#   5. the empty state on a real short session, a session with no history, 30 laps, no map, the fallback, a race, scaling
#   6. the dashboard (index.html) against a pretend irdash: the review after a session, the laps-saved bar, ANALYSIS and BACK,
#      nothing while he drives, the demo
#   powershell -ExecutionPolicy Bypass -File tests\session-review-test.ps1            (-WriteDemo also saves dash\www\v2\sr-demo.json)
# Pictures: tests\shots\sr-review.png, sr-notes.png, sr-empty.png, sr-race.png, sr-30laps.png, sr-dashboard.png
param([switch]$WriteDemo)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree

$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function Section($title) { Assert-RigFree -Where $title; Write-Host $title }
$inv = [Globalization.CultureInfo]::InvariantCulture
function F3($x) { ([double]$x).ToString('0.000', $inv) }

$me = Get-Process -Id $PID
$me.PriorityClass = 'BelowNormal'
$cores = [Environment]::ProcessorCount
if ($cores -gt 2) { $mask = [int64]0; for ($i = 0; $i -lt 2; $i++) { $mask = $mask -bor ([int64]1 -shl ($cores - 1 - $i)) }; $me.ProcessorAffinity = [IntPtr]$mask }

$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$www = Join-Path $root 'dash\www\v2'
$shipped = Join-Path $root 'dash\irdash.exe'
$shippedStamp = (Get-Item -LiteralPath $shipped).LastWriteTimeUtc.Ticks
$vaultDir = Join-Path $root 'vault\telemetry\chevrolet-corvette-z06-gt3-r\road-atlanta-full-course'
$pre = 'chevyvettez06rgt3_roadatlanta full '
$pbName = $pre + '2026-10-10 00-13-18.ibt'         # the PB session (lap 7 = 79.549)
$midName = $pre + '2026-10-10 13-28-11.ibt'        # the afternoon: lap 7 = 79.575, his previous best
$oldName = $pre + '2026-10-09 10-28-32.ibt'       # an older session: lap 8 against the PB has one clear cause (a note)
$smallName = $pre + '2026-10-06 21-20-59.ibt'      # a short real session: 3 laps, 2 of them clean
$work = Join-Path $env:TEMP ('sr-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$dAB = Join-Path $work 'ab'; $dB = Join-Path $work 'b'; $dC = Join-Path $work 'c'

# ---- an independent reader of the raw records (PowerShell, straight from the .ibt) ----
function Read-Raw($file) {
  $b = [IO.File]::ReadAllBytes($file)
  $bl = [BitConverter]::ToInt32($b, 36); $bo = [BitConverter]::ToInt32($b, 52); $nv = [BitConverter]::ToInt32($b, 24); $vho = [BitConverter]::ToInt32($b, 28)
  $vars = @{}
  for ($i = 0; $i -lt $nv; $i++) { $p = $vho + 144 * $i; $vars[[Text.Encoding]::ASCII.GetString($b, $p + 16, 32).Trim([char]0)] = [BitConverter]::ToInt32($b, $p + 4) }
  $n = [int](($b.Length - $bo) / $bl)
  $lap = New-Object 'int[]' $n; $llt = New-Object 'double[]' $n; $pct = New-Object 'double[]' $n; $st = New-Object 'double[]' $n; $on = New-Object 'byte[]' $n
  $surf = New-Object 'int[]' $n; $bst = New-Object 'double[]' $n      # L-1: PlayerTrackSurface (0 = off track) and iRacing's own best lap of the session (LapBestLapTime, -1 = none yet)
  $oL = $vars['Lap']; $oT = $vars['LapLastLapTime']; $oP = $vars['LapDistPct']; $oS = $vars['SessionTime']; $oO = $vars['IsOnTrack']; $oSf = $vars['PlayerTrackSurface']; $oBt = $vars['LapBestLapTime']
  for ($r = 0; $r -lt $n; $r++) {
    $base = $bo + $r * $bl
    $lap[$r] = [BitConverter]::ToInt32($b, $base + $oL); $llt[$r] = [BitConverter]::ToSingle($b, $base + $oT)
    $pct[$r] = [BitConverter]::ToSingle($b, $base + $oP); $st[$r] = [BitConverter]::ToDouble($b, $base + $oS); $on[$r] = $b[$base + $oO]
    $surf[$r] = [BitConverter]::ToInt32($b, $base + $oSf); $bst[$r] = [BitConverter]::ToSingle($b, $base + $oBt)
  }
  $yaml = $null
  $ilen = [BitConverter]::ToInt32($b, 16); $ioff = [BitConverter]::ToInt32($b, 20); $yaml = [Text.Encoding]::GetEncoding(28591).GetString($b, $ioff, $ilen)
  return @{ n = $n; lap = $lap; llt = $llt; pct = $pct; st = $st; on = $on; surf = $surf; best = $bst; yaml = $yaml }
}
# the runs of one lap number on track, with the line crossings and iRacing's announced time
function Raw-Laps($raw) {
  $n = $raw.n; $runs = New-Object System.Collections.Generic.List[object]; $k = 0
  while ($k -lt $n) {
    if ($raw.on[$k] -eq 0) { $k++; continue }
    $j = $k + 1
    while ($j -lt $n -and $raw.on[$j] -ne 0 -and $raw.lap[$j] -eq $raw.lap[$k] -and ($raw.st[$j] - $raw.st[$j - 1]) -lt 0.5) { $j++ }
    $runs.Add(@{ n = $raw.lap[$k]; a = $k; b = $j }); $k = $j
  }
  $laps = @{}
  for ($r = 0; $r -lt $runs.Count; $r++) {
    $run = $runs[$r]; $a = $run.a; $b = $run.b
    $pre = $r -gt 0 -and $runs[$r - 1].b -eq $a -and $raw.pct[$a - 1] -gt 0.8 -and $raw.pct[$a] -lt 0.2
    $post = $r + 1 -lt $runs.Count -and $runs[$r + 1].a -eq $b -and $raw.pct[$b - 1] -gt 0.8 -and $raw.pct[$b] -lt 0.2
    if (-not ($pre -and $post)) { continue }
    $cross = { param($i) $p0 = $raw.pct[$i - 1]; $f = (1 - $p0) / ((1 - $p0) + $raw.pct[$i]); $raw.st[$i - 1] + ($raw.st[$i] - $raw.st[$i - 1]) * $f }
    $t0 = & $cross $a; $t1 = & $cross $b
    $at = [math]::Min($b + 90, $runs[$r + 1].b - 1)
    $llt = $raw.llt[$at]
    $computed = $t1 - $t0
    $official = ($llt -gt 1 -and [math]::Abs($llt - $computed) -lt 0.15)
    # L-1, iRacing's verdict from the raw records (nothing shared with Paddock). iRacing's own best lap of the session (LapBestLapTime) is the evidence: read at the
    # last record of the lap and 1.5 to 2.5 s after the line. A lap quicker than the best so far that BECAME the best was counted (whatever the off-track record says);
    # a quicker lap that left the best unchanged was not. Only a lap that is not quicker than the best so far gives no evidence: then any record of the lap with
    # PlayerTrackSurface 0 (off track) decides.
    $offN = 0; for ($x = $a; $x -lt $b; $x++) { if ($raw.surf[$x] -eq 0) { $offN++ } }
    $off = $offN -gt 0
    $bestAfter = -1.0; $lo = $b + 90; $hi = [math]::Min($raw.n, $b + 150)
    for ($x = $lo; $x -lt $hi; $x++) { $v = $raw.best[$x]; if ($v -gt 1 -and ($bestAfter -lt 0 -or $v -lt $bestAfter)) { $bestAfter = $v } }
    $bestBefore = if ($raw.best[$b - 1] -gt 1) { [double]$raw.best[$b - 1] } else { -1.0 }
    $faster = ($bestBefore -le 0) -or ($llt -lt $bestBefore - 0.0015)
    if (-not $official) { $counted = $false; $by = 'iRacing gave the lap no time' }
    elseif ($faster) { $counted = ($bestAfter -gt 0) -and ($bestAfter -le $llt + 0.0015); $by = if ($counted) { "iRacing's best lap became this lap" } else { "quicker than iRacing's best so far, its best lap did not change" } }
    else { $counted = -not $off; $by = if ($off) { "not quicker than iRacing's best so far, so no evidence; off-track record" } else { "not quicker than iRacing's best so far, so no evidence; no off-track record" } }
    $laps[[int]$run.n] = @{ a = $a; b = $b; t0 = $t0; t1 = $t1; computed = $computed; official = $official; llt = $llt; off = $off; offN = $offN; bestBefore = $bestBefore; bestAfter = $bestAfter; counted = $counted; by = $by }
  }
  return $laps
}
# time (s from the lap's start line) at which the lap reached `s` of the lap distance, pinned like iRacing's own figure
function Raw-CrossAt($raw, $lap, $s) {
  for ($i = $lap.a; $i -lt $lap.b; $i++) {
    if ($raw.pct[$i] -ge $s) {
      $p0 = $raw.pct[$i - 1]; $p1 = $raw.pct[$i]
      if ($i -eq $lap.a) { return 0.0 }
      $t = $raw.st[$i - 1] + ($raw.st[$i] - $raw.st[$i - 1]) * (($s - $p0) / ($p1 - $p0))
      return $t - $lap.t0
    }
  }
  return $lap.computed
}
function Raw-Slices($raw, $lap, $bounds) {   # $bounds: the start fractions, the last piece ends at the line
  $scale = if ($lap.official) { $lap.llt / $lap.computed } else { 1.0 }
  $out = @(); $cr = @()
  foreach ($s in $bounds) { $cr += (Raw-CrossAt $raw $lap $s) }
  $cr += $lap.computed
  for ($k = 0; $k -lt $bounds.Count; $k++) { $out += ($cr[$k + 1] - $cr[$k]) * $scale }
  return , $out
}

# ---- headless Chrome with the DevTools protocol (the same harness as workbench-test) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080, $early = $null) {
  $prof = Join-Path $env:TEMP ('sr-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9371
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--allow-file-access-from-files', 'about:blank') -PassThru -WindowStyle Hidden
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0; errors = New-Object System.Collections.Generic.List[string] }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Runtime.enable' @{}
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false }
  if ($early) { $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $early } }
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
function Cdp-Wait($cond, $secs = 15) { for ($i = 0; $i -lt ($secs * 4); $i++) { if ((Cdp-Eval "(function(){try{return !!($cond)}catch(e){return false}})()") -eq $true) { return $true }; Start-Sleep -Milliseconds 250 }; return $false }
function Nav-Page($url, $ready = 'document.querySelector(".sr-tbl")') {
  $null = Cdp-Eval 'window.__old = 1; 1'
  $null = Cdp 'Page.navigate' @{ url = $url }
  return (Cdp-Wait ('!window.__old && typeof SessionReview !== "undefined" && SessionReview.ready && ' + $ready) 25)
}# the pretend irdash is writing this file while we read it: open it shared, try again a moment later if it is busy
function Read-Log {
  for ($i = 0; $i -lt 20; $i++) {
    try { $fs = [IO.File]::Open($script:logPath, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs); $txt = $sr.ReadToEnd(); $sr.Close(); return @($txt -split "`r?`n" | Where-Object { $_ }) }
    catch { Start-Sleep -Milliseconds 100 }
  }
  return @()
}
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
function FileUrl($p) { 'file:///' + ($p -replace '\\', '/') }
# one reply of /analysis/channels: header only (the page reads the arrays itself)
function Read-WbHead($path) {
  $b = [IO.File]::ReadAllBytes($path)
  if ($b.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'PWB1') { return $null }
  $hl = [BitConverter]::ToInt32($b, 4); return [Text.Encoding]::UTF8.GetString($b, 8, $hl) | ConvertFrom-Json
}
# what is on the page: the table rows (time, sector cells and their classes, the strip as a string of p/n/y/g, gap)
$rowsJs = @'
(function(){return Array.prototype.map.call(document.querySelectorAll('.sr .sr-tbl .sr-row[data-lap]'),function(r){var c=r.children,ms=c[c.length-2],sec=[];for(var i=2;i<c.length-2;i++){if(!c[i].classList.contains('ms'))sec.push({t:c[i].textContent,c:c[i].className})}
return {lap:+r.dataset.lap,best:r.classList.contains('sr-best'),grey:r.classList.contains('grey'),time:c[1].textContent,tcls:c[1].className,sec:sec,mini:ms&&ms.classList.contains('ms')?Array.prototype.map.call(ms.children,function(i){return i.className}).join(''):'',gap:c[c.length-1].textContent}})})()
'@
# the colour rule, written again here from the server's numbers (the page must agree with it)
function Expect-Colours($m) {
  $ns = @($m.sectorAt).Count
  $valid = @($m.laps | Where-Object { $_.valid -and $null -ne $_.time })
  $pureV = @($valid | Where-Object { -not $_.offTrack -and $_.skip -ne 'off' })      # L-1b: the best sectors are joined only from counted laps with no off-track record
  $bs = @(); for ($k = 0; $k -lt $ns; $k++) { $bs += [double](($pureV | ForEach-Object { [double]$_.sectors[$k] } | Measure-Object -Minimum).Minimum) }
  $sm = @(); for ($i = 0; $i -lt 24; $i++) { $sm += [double](($pureV | ForEach-Object { [double]$_.mini[$i] } | Measure-Object -Minimum).Minimum) }
  $hist = ($null -ne $m.prev -and $null -ne $m.ever)
  $best = $valid | Sort-Object { [double]$_.time } | Select-Object -First 1
  $newPb = $hist -and $best -and ([double]$best.time -lt [double]$m.prev.time - 0.0005)
  $out = @{}
  foreach ($l in @($m.laps)) {
    $sec = @()
    for ($k = 0; $k -lt $ns; $k++) {
      if ($null -eq $l.sectors) { $sec += 'sg'; continue }
      $v = [double]$l.sectors[$k]
      $c = if (-not $l.valid) { 'sg' } elseif ($l.offTrack -or $l.skip -eq 'off') { 'sy' } elseif ($hist -and $v -le [math]::Min([double]$m.ever.sectors[$k], $bs[$k]) + 1e-6) { 'sp' } elseif ($v -le $bs[$k] + 1e-6) { 'sn' } else { 'sy' }
      $sec += $c
    }
    $mini = ''
    for ($i = 0; $i -lt 24; $i++) {
      if ($null -eq $l.mini) { $mini += 'g'; continue }
      $v = [double]$l.mini[$i]
      $mini += if (-not $l.valid) { 'g' } elseif ($l.offTrack -or $l.skip -eq 'off') { 'y' } elseif ($hist -and $v -le [math]::Min([double]$m.ever.mini[$i], $sm[$i]) + 1e-6) { 'p' } elseif ($v -le $sm[$i] + 1e-6) { 'n' } else { 'y' }
    }
    $isBest = $best -and $l.n -eq $best.n
    $tc = if (-not $l.valid) { 'sg' } elseif ($isBest) { if ($newPb) { 'sp' } else { 'sn' } } else { 'sy' }
    $out[[int]$l.n] = @{ sec = $sec; mini = $mini; time = $tc }
  }
  return $out
}

# ---- a pretend irdash for the dashboard part: the real www files, canned analysis / review replies, a log of every request ----
$srvScript = {
  param($port, $www, $cfgFile, $logFile)
  $l = New-Object System.Net.HttpListener; $l.Prefixes.Add("http://localhost:$port/"); $l.Start()
  $types = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'; '.png' = 'image/png' }
  while ($l.IsListening) {
    try { $ctx = $l.GetContext() } catch { break }
    $req = $ctx.Request; $res = $ctx.Response; $path = $req.Url.AbsolutePath
    $bytes = $null; $type = 'application/json; charset=utf-8'; $code = 200
    try {
      Add-Content -LiteralPath $logFile -Value ($path + $req.Url.Query) -Encoding UTF8
      $cfg = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
      if ($path -eq '/stop') { $bytes = [Text.Encoding]::ASCII.GetBytes('bye'); $l.Stop() }
      elseif ($path -eq '/analysis/session') {
        if ([int]$cfg.sessionCode -ne 200) { $code = [int]$cfg.sessionCode; $bytes = [Text.Encoding]::UTF8.GetBytes('{"error":"pretend"}') }
        else { $bytes = [IO.File]::ReadAllBytes($cfg.session) }
      }
      elseif ($path -eq '/analysis/channels') { $bytes = [IO.File]::ReadAllBytes($cfg.channels); $type = 'application/octet-stream' }
      elseif ($path -eq '/analysis/race') {      # the race log of a session: 200 when the test says there is one, 404 when not (W6b: RACE button)
        $rc = if ($null -ne $cfg.raceCode) { [int]$cfg.raceCode } else { 404 }
        $code = $rc; $bytes = [Text.Encoding]::UTF8.GetBytes($(if ($rc -eq 200) { '{"ok":true}' } else { '{"error":"no field data for this session"}' }))
      }
      elseif ($path -eq '/vault/review') { $bytes = [Text.Encoding]::UTF8.GetBytes($cfg.review) }
      elseif ($path -eq '/vault/nav') { $bytes = [Text.Encoding]::UTF8.GetBytes('{"enabled":false}') }
      elseif ($path -eq '/api/do' -or $path -eq '/api/nav') { $type = 'text/plain'; $bytes = [Text.Encoding]::ASCII.GetBytes('ok') }
      elseif ($path.StartsWith('/v2/') -and -not $path.Contains('..')) {
        $f = Join-Path $www ($path.Substring(4).Replace('/', '\'))
        if (Test-Path -LiteralPath $f -PathType Leaf) { $bytes = [IO.File]::ReadAllBytes($f); $ext = [IO.Path]::GetExtension($f).ToLower(); $type = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' } }
        else { $code = 404; $bytes = [Text.Encoding]::ASCII.GetBytes('no') }
      }
      else { $code = 404; $bytes = [Text.Encoding]::UTF8.GetBytes('{}') }
    } catch { $code = 500; $bytes = [Text.Encoding]::UTF8.GetBytes('{"error":"pretend server"}') }
    $res.StatusCode = $code; $res.ContentType = $type; $res.ContentLength64 = $bytes.Length
    try { $res.OutputStream.Write($bytes, 0, $bytes.Length); $res.OutputStream.Close() } catch { }
  }
}
$script:job = $null

try {
  New-Item -ItemType Directory -Force $work, $dAB, $dB, $dC | Out-Null
  Section '1. copies of four old sessions (the vault''s own copies) and a compile'
  $newestDoc = $null
  $docTel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
  if (Test-Path -LiteralPath $docTel) { $newestDoc = Get-ChildItem -LiteralPath $docTel -Filter '*.ibt' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
  Check 'none of the copies is the newest telemetry file' (-not $newestDoc -or ($newestDoc.Name -notin @($pbName, $midName, $oldName, $smallName)))
  $plan = @(
    @{ from = '2026-10-10 00-13-18.ibt'; to = $pbName; dirs = @($dAB, $dB) }, @{ from = '2026-10-10 13-28-11.ibt'; to = $midName; dirs = @($dAB) },
    @{ from = '2026-10-09 10-28-32.ibt'; to = $oldName; dirs = @($dB) }, @{ from = '2026-10-06 21-20-59.ibt'; to = $smallName; dirs = @($dC) })
  foreach ($mC in $plan) {
    $from = Join-Path $vaultDir $mC.from
    if (-not (Test-Path -LiteralPath $from)) { $from = Join-Path $docTel ($pre + $mC.from) }      # L-1: the Vault keeps copies only of laps iRacing counted; the same untouched file then comes from the telemetry folder
    Check "the real file is there (the vault's copy, else the original): $($mC.from)" (Test-Path -LiteralPath $from)
    foreach ($d in $mC.dirs) { Copy-Item -LiteralPath $from -Destination (Join-Path $d $mC.to) }
  }
  $build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
  $m = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
  Check 'dash\build.ps1 -NoDeploy compiled (sessionreview.cs is in its list)' ($LASTEXITCODE -eq 0 -and $m.Success -and (Get-Content (Join-Path $root 'dash\build.ps1') -Raw) -match 'sessionreview\.cs')
  if (-not $m.Success) { throw $build }
  $exe = Join-Path $m.Groups[1].Value.Trim() 'irdash.exe'
  Check 'irdash.cs has the /analysis/session route' ((Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw) -match 'path == "/analysis/session"')
  # a throw-away exe from the same sources with its own Main (tests\sr-main.cs): the Session Review data without irdash
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $srcs = @([regex]::Matches((Get-Content (Join-Path $root 'dash\build.ps1') -Raw), '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) }) + @((Join-Path $root 'src\deckstate.cs'), (Join-Path $root 'tests\sr-main.cs'))
  $harness = Join-Path $work 'srharness.exe'
  $cout = & $csc /nologo /target:winexe /optimize+ /platform:anycpu /main:IRDash.SrMain "/out:$harness" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll @srcs | Out-String
  Check 'the data harness compiled from the same sources' ($LASTEXITCODE -eq 0 -and (Test-Path $harness))
  if (-not (Test-Path $harness)) { throw $cout }

  function Invoke-Session($dir, $id, $lap, $tag) {
    $out = Join-Path $work "$tag.json"
    $mA = "--root `"$root`" --dir `"$dir`" --id `"$id`" --out `"$out`""; if ($lap) { $mA += " --lap $lap" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $harness -ArgumentList $mA -PassThru -Wait -WindowStyle Hidden
    $r = @{ exit = $p.ExitCode; ms = $sw.ElapsedMilliseconds; path = $out; text = (Get-Content -LiteralPath $out -Raw) }
    $r.j = $r.text | ConvertFrom-Json
    return $r
  }
  function Invoke-Channels($dir, $id, $lap, $ref, $tag) {
    $out = Join-Path $work "$tag.bin"
    $mA = "--analysis --channels --root `"$root`" --dir `"$dir`" --id `"$id`" --lap $lap --ref `"$ref`" --ch `"Lat,Lon`" --out `"$out`""
    $p = Start-Process -FilePath $exe -ArgumentList $mA -PassThru -Wait -WindowStyle Hidden
    return @{ exit = $p.ExitCode; path = $out; head = (Read-WbHead $out) }
  }

  Section '2. the data against the raw file: lap times, sectors, optimal, consistency (Road Atlanta, the PB session)'
  $runA = Invoke-Session $dAB $pbName 0 'A'
  $mA = $runA.j
  Note "session data: $($runA.text.Length) characters, $($runA.ms) ms (process start, both files read)"
  Check 'the reply is JSON without an error and exit 0' ($runA.exit -eq 0 -and -not $mA.error)
  $raw = Read-Raw (Join-Path $dAB $pbName)
  $rl = Raw-Laps $raw
  $yamlSectors = @([regex]::Matches($raw.yaml, 'SectorStartPct:\s*([0-9.]+)') | ForEach-Object { [double]$_.Groups[1].Value })
  Note "iRacing's own split points in the file (SplitTimeInfo): $($yamlSectors -join ', ')"
  Check 'the sector split points are the ones in the file''s session info (Road Atlanta has four, not three)' (@($mA.sectorAt).Count -eq $yamlSectors.Count -and $yamlSectors.Count -eq 4 -and (Near $mA.sectorAt[1] $yamlSectors[1] 0.000001) -and (Near $mA.sectorAt[3] $yamlSectors[3] 0.000001) -and $mA.sectorFrom -eq 'yaml')
  Check 'identity: the Corvette at Road Atlanta Full Course, 4.06 km, a Race, Peter, car number 64 from the session' ($mA.car -eq 'Chevrolet Corvette Z06 GT3.R' -and $mA.track -eq 'Road Atlanta' -and $mA.config -eq 'Full Course' -and (Near $mA.lengthM 4056.9 0.1) -and $mA.type -eq 'Race' -and $mA.driver -like 'Peter*' -and $mA.carNumber -eq '64')
  $startLocal = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$mA.startMs).ToLocalTime()
  Check 'the session date is the one in the file name (2026-10-10 00:13:18)' ($startLocal.ToString('yyyy-MM-dd HH:mm:ss', $inv) -eq '2026-10-10 00:13:18')
  $laps = @($mA.laps)
  Check 'eleven laps are listed, 1 to 11, once each, in order' ($laps.Count -eq 11 -and (($laps | ForEach-Object { $_.n }) -join ',') -eq '1,2,3,4,5,6,7,8,9,10,11')
  $okTimes = $true; $okFlags = $true; $worst = 0.0; $nOff = 0
  foreach ($l in $laps) {
    $r = $rl[[int]$l.n]
    if ($l.valid) {
      if (-not $r -or -not $r.official -or (F3 $l.time) -ne (F3 $r.llt)) { $okTimes = $false; Note "lap $($l.n): server $($l.time) raw $(F3 $r.llt)" }
    }
  }
  Check 'every valid lap time equals LapLastLapTime, iRacing''s own figure, to 0.001 (3 counted laps: 6, 7, 8)' ($okTimes -and @($laps | Where-Object { $_.valid }).Count -eq 3 -and (($laps | Where-Object { $_.valid } | ForEach-Object { $_.n }) -join ',') -eq '6,7,8')
  # L-1: one lap rule, iRacing's. Worked out here from the raw records alone (off-track surface, iRacing's best lap after the line) for every full lap.
  $ruleOk = $true; $nTimedRaw = 0; $nCountedRaw = 0
  foreach ($l in $laps) {
    $r = $rl[[int]$l.n]; if (-not $r) { continue }      # laps 1 and 11 are not full laps: OUT and IN
    if ($r.official) { $nTimedRaw++ }; if ($r.counted) { $nCountedRaw++ }
    if ([bool]$l.valid -ne [bool]$r.counted -or [bool]$l.timed -ne [bool]$r.official) { $ruleOk = $false; Note "lap $($l.n): server valid=$($l.valid) timed=$($l.timed); raw records say counted=$($r.counted) timed=$($r.official) (off track $($r.off), iRacing's best after the line $($r.bestAfter))" }
  }
  # the evidence per lap (the table of the log): lap, time, off-track records, iRacing's best before / after the line, the verdict and what decided it
  foreach ($l in $laps) { $r = $rl[[int]$l.n]; if ($r -and $r.official) { Note ("lap {0,2}  {1}  off-track records {2,2}  iRacing best before {3} after {4}  -> {5}: {6}" -f $l.n, (F3 $r.llt), $r.offN, (F3 $r.bestBefore), (F3 $r.bestAfter), $(if ($r.counted) { 'COUNTED' } else { 'not counted' }), $r.by) } }
  $evOk = $true
  foreach ($l in $laps) { $r = $rl[[int]$l.n]; if (-not $r -or -not $r.official) { continue }
    if ($l.offSamples -ne $r.offN -or -not (Near $l.bestBefore $r.bestBefore 0.0006) -or -not (Near $l.bestAfter $r.bestAfter 0.0006) -or $l.countedBy -ne $r.by) { $evOk = $false; Note "lap $($l.n): server off $($l.offSamples) before $($l.bestBefore) after $($l.bestAfter) '$($l.countedBy)'; raw off $($r.offN) before $($r.bestBefore) after $($r.bestAfter) '$($r.by)'" } }
  Check 'the evidence the server gives for every timed lap (off-track records, iRacing''s best lap before and after the line, the words that decided) is what the raw records say' $evOk
  Check 'the lap rule is iRacing''s: laps 6, 7, 8 became or stayed iRacing''s best with no off-track record (counted); laps 2 and 5 are quicker than its best so far (it had none) and it did not change (not counted); laps 9 and 10 give no evidence (slower than its best) and have an off-track record (not counted)' ($ruleOk -and $nTimedRaw -eq 7 -and $nCountedRaw -eq 3 -and $rl[6].by -like '*became this lap' -and $rl[7].by -like '*became this lap' -and $rl[8].by -like '*no evidence*no off-track record' -and $rl[2].by -like 'quicker than*did not change' -and $rl[5].by -like 'quicker than*did not change' -and $rl[9].by -like '*no evidence*; off-track record' -and $rl[10].by -like '*no evidence*; off-track record')
  $offTimed = @(2, 5, 9, 10 | ForEach-Object { $laps[$_ - 1] })
  Check 'a timed lap with a short off-track (laps 2, 5, 9, 10) keeps its time, is NOT valid, has no skip of our own, and is flagged OFF - a fact, iRacing''s verdict' (@($offTimed | Where-Object { $_.valid -or -not $_.timed -or -not $_.offTrack -or $_.flag -ne 'OFF' -or $_.skip -ne '' -or $null -eq $_.time -or $null -eq $_.sectors }).Count -eq 0 -and ($offTimed | ForEach-Object { $rl[[int]$_.n].off }) -notcontains $false)
  # and it is left out of everything that counts: the best lap, the optimal, the best-5, the previous-best history
  $timedAll = @($laps | Where-Object { $_.timed -and $_.sectors })
  $allSec = @(0..3 | ForEach-Object { $k = $_; [double](($timedAll | ForEach-Object { [double]$_.sectors[$k] } | Measure-Object -Minimum).Minimum) })
  $valSec = @(0..3 | ForEach-Object { $k = $_; [double](($laps | Where-Object { $_.valid } | ForEach-Object { [double]$_.sectors[$k] } | Measure-Object -Minimum).Minimum) })
  Check 'left out of the optimal: the optimal joins the best sectors of the 3 counted laps; joining all 7 timed laps would give a different (quicker) lap' ((Near $mA.optimal (($valSec | ForEach-Object { [math]::Round($_, 3, 'AwayFromZero') } | Measure-Object -Sum).Sum) 0.0001) -and (($allSec | Measure-Object -Sum).Sum) -lt (($valSec | Measure-Object -Sum).Sum) - 0.005)
  Check 'left out of the best-5 average and the lap count: 3 laps (the counted ones), not the 7 timed ones' ($mA.consistency.n -eq 3 -and $mA.validLaps -eq 3)
  $untimed = (-not $laps[2].valid) -and (-not $laps[3].valid) -and ($rl[3].llt -lt 1) -and ($rl[4].llt -lt 1)
  Check 'the best lap is lap 7, 1:19.549, and the laps iRacing did not time are not valid (laps 3 and 4: LapLastLapTime -1)' ($mA.best.lap -eq 7 -and (F3 $mA.best.time) -eq '79.549' -and $untimed)
  Check 'flags: lap 1 OUT, lap 3 OFF (our rule saw the car off track), lap 4 INVALID (iRacing gave no time, our rules saw nothing), lap 11 IN, the valid laps have none' ($laps[0].flag -eq 'OUT' -and $laps[2].flag -eq 'OFF' -and $laps[2].skip -eq 'off' -and $laps[3].flag -eq 'INVALID' -and $laps[3].skip -eq '' -and $laps[10].flag -eq 'IN' -and @($laps | Where-Object { $_.valid -and $_.flag -ne '' }).Count -eq 0)
  Check 'only facts in the flag words: every lap that does not count is OUT, IN, PIT, OFF (the off-track seen), or INVALID (nothing seen); OFF only where our skip says off or iRacing timed the lap and the records show the off-track; INVALID only where nothing was seen' (@($laps | Where-Object { -not $_.valid -and $_.flag -notin 'OUT', 'IN', 'PIT', 'OFF', 'INVALID' }).Count -eq 0 -and @($laps | Where-Object { $_.flag -eq 'OFF' -and $_.skip -ne 'off' -and -not ($_.timed -and $_.offTrack) }).Count -eq 0 -and @($laps | Where-Object { $_.flag -eq 'INVALID' -and ($_.skip -ne '' -or $_.offTrack) }).Count -eq 0)
  # sectors: cut at the file's own split points, from the raw records, pinned to iRacing's time
  $maxDiff = 0.0; $sumOk = $true; $cnt = 0
  foreach ($l in $laps | Where-Object { $_.valid }) {
    $r = $rl[[int]$l.n]; $exp = Raw-Slices $raw $r $yamlSectors
    $sum = 0.0
    for ($k = 0; $k -lt 4; $k++) { $d = [math]::Abs([double]$l.sectors[$k] - $exp[$k]); if ($d -gt $maxDiff) { $maxDiff = $d }; $sum += [double]$l.sectors[$k]; $cnt++ }
    if ([math]::Abs($sum - [double]$l.time) -gt 0.0025) { $sumOk = $false }
  }
  Note "HAND CHECK sectors: $cnt sector times of the 3 counted laps, largest difference from the raw records $([math]::Round($maxDiff, 4)) s"
  Check 'every sector time equals the one worked out from the raw records (LapDistPct crossing the split point) within 0.002 s' ($cnt -eq 12 -and $maxDiff -lt 0.002)
  Check 'S1 + S2 + S3 + S4 add up to the lap time (within the rounding of four 3-decimal figures)' $sumOk
  $l7 = $laps[6]; $exp7 = Raw-Slices $raw $rl[7] @(0..23 | ForEach-Object { $_ / 24.0 })
  $md = 0.0; $ms = 0.0; for ($i = 0; $i -lt 24; $i++) { $md = [math]::Max($md, [math]::Abs([double]$l7.mini[$i] - $exp7[$i])); $ms += [double]$l7.mini[$i] }
  Check 'lap 7''s 24 mini-sectors match the raw records within 0.002 s and add up to the lap time' ($md -lt 0.002 -and (Near $ms 79.549 0.003))
  $valid = @($laps | Where-Object { $_.valid })
  $bs = @(0..3 | ForEach-Object { $k = $_; [double](($valid | ForEach-Object { [double]$_.sectors[$k] } | Measure-Object -Minimum).Minimum) })
  Check 'optimal = the best iRacing sectors of the counted laps joined, each at the millisecond it is shown (11.577 + 22.441 + 27.577 + 17.566 = 79.161)' ((Near $mA.optimal (($bs | ForEach-Object { [math]::Round($_, 3, 'AwayFromZero') } | Measure-Object -Sum).Sum) 0.0001) -and (F3 $mA.optimal) -eq '79.161' -and (Near $mA.bestSectors[0] 11.577 0.0006) -and (Near $mA.bestSectors[1] 22.441 0.0006) -and (Near $mA.bestSectors[3] 17.566 0.0006))
  $tt = @($valid | ForEach-Object { [double]$_.time } | Sort-Object | Select-Object -First 5); $avg = ($tt | Measure-Object -Average).Average
  $sd = [math]::Sqrt((($tt | ForEach-Object { ($_ - $avg) * ($_ - $avg) }) | Measure-Object -Sum).Sum / $tt.Count)
  Check 'consistency = the average of the best valid laps (3 counted laps: 1:19.786) and their spread (0.17 s)' ($mA.consistency.n -eq 3 -and $tt.Count -eq 3 -and (Near $mA.consistency.avg $avg 0.0006) -and (Near $mA.consistency.sd $sd 0.0006) -and (F3 $mA.consistency.avg) -eq '79.786')
  Check 'seconds on track come from the file: 60508 records at 60 Hz = 1008 s' ((Near $mA.seconds 1008 1) -and $raw.n -eq 60508)
  $modExp = [long]((Get-Item -LiteralPath (Join-Path $dAB $pbName)).LastWriteTimeUtc - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalMilliseconds
  Check 'the reply says when the file was last written (the page tells this session from an older one with it)' ([math]::Abs([double]$mA.modMs - $modExp) -lt 2000)

  Section '3. the rules: previous best, never itself, history colours, notes by the C-30 thresholds'
  Check 'the reference is his previous best from ANOTHER session: the afternoon lap 7, 1:19.575' ($mA.ref.kind -eq 'previous' -and $mA.ref.file -eq $midName -and $mA.ref.lap -eq 7 -and (F3 $mA.ref.time) -eq '79.575' -and $mA.prev.file -eq $midName -and $mA.prev.laps -eq 1)
  # L-1: the afternoon had six timed laps but iRacing counted only lap 7 (laps 2 to 6 each have an off-track record): only lap 7 is history, so the previous best is a lap iRacing counted
  $rlMid = Raw-Laps (Read-Raw (Join-Path $dAB $midName))
  Check 'the previous best is a lap iRacing counted: in the afternoon laps 2 to 6 are timed but have an off-track record in the raw records, only lap 7 counted - so lap 7 (1:19.575) is the whole history' ((@(2..6 | Where-Object { $rlMid[$_].official -and $rlMid[$_].off -and -not $rlMid[$_].counted }).Count -eq 5) -and $rlMid[7].counted -and (F3 $rlMid[7].llt) -eq '79.575')
  Check 'the lap shown is the best one and it is never its own reference' ($mA.shown.lap -eq 7 -and -not ($mA.ref.file -eq $mA.file -and $mA.ref.lap -eq $mA.shown.lap))
  $S2 = Invoke-Session $dAB $midName 0 'A2'
  $other = $S2.j
  $evS = @(0..3 | ForEach-Object { $k = $_; [double](($other.laps | Where-Object { $_.valid } | ForEach-Object { [double]$_.sectors[$k] } | Measure-Object -Minimum).Minimum) })
  $evM = @(0..23 | ForEach-Object { $k = $_; [double](($other.laps | Where-Object { $_.valid } | ForEach-Object { [double]$_.mini[$k] } | Measure-Object -Minimum).Minimum) })
  $evOk = $true; for ($k = 0; $k -lt 4; $k++) { if (-not (Near $mA.ever.sectors[$k] $evS[$k] 0.0006)) { $evOk = $false } }; for ($k = 0; $k -lt 24; $k++) { if (-not (Near $mA.ever.mini[$k] $evM[$k] 0.0006)) { $evOk = $false } }
  Check 'the history (best ever per sector and per mini-sector) is the minimum over the other session''s valid laps' $evOk
  Check 'the same data with the afternoon as the session: its best is lap 7 at 1:19.575 and the PB session is the history (1:19.549, not a new PB)' ($other.best.lap -eq 7 -and (F3 $other.best.time) -eq '79.575' -and (F3 $other.prev.time) -eq '79.549')
  $runC = Invoke-Session $dC $smallName 0 'C'
  $mC = $runC.j
  $rlC = Raw-Laps (Read-Raw (Join-Path $dC $smallName))
  Check 'a short real session (3 laps) reads without a problem: lap 1 OUT, lap 2 valid, lap 3 timed but with an off-track record = OFF and not counted, no history' ($runC.exit -eq 0 -and @($mC.laps).Count -eq 3 -and $mC.laps[0].flag -eq 'OUT' -and $mC.laps[1].valid -and $mC.laps[2].timed -and -not $mC.laps[2].valid -and $mC.laps[2].flag -eq 'OFF' -and $rlC[3].official -and $rlC[3].off -and $mC.validLaps -eq 1 -and $null -eq $mC.prev -and $null -eq $mC.ever)
  Check 'with no history and no other counted lap there is no reference at all - never the best lap itself, and never a lap iRacing did not count (lap 3 is timed 1:20.352 but not counted)' ($null -eq $mC.ref -and $mC.shown.lap -eq 2 -and (F3 $mC.laps[2].time) -eq '80.352')
  $runB = Invoke-Session $dB $oldName 6 'B'
  $mB = $runB.j
  Check 'a chosen lap: lap 6 of an older session is shown against the PB (lap 7 of the PB session), the best lap (9) stays the best' ($mB.shown.lap -eq 6 -and $mB.best.lap -eq 9 -and $mB.ref.lap -eq 7 -and $mB.ref.file -eq $pbName -and $mB.ref.kind -eq 'previous')
  $runB8 = Invoke-Session $dB $oldName 8 'B8'
  Check 'a lap iRacing did not count cannot be the lap shown: asking for lap 8 of that session (timed 1:20.366, off-track) leaves the best lap (9) on the screen' ($runB8.exit -eq 0 -and $runB8.j.shown.lap -eq 9 -and $runB8.j.best.lap -eq 9 -and -not (@($runB8.j.laps)[7].valid) -and (@($runB8.j.laps)[7].flag -eq 'OFF'))
  $runA6 = Invoke-Session $dAB $pbName 6 'A6'
  $mA6 = $runA6.j
  $notes = @($mA6.notes)
  Check 'a chosen lap with a data note: lap 6 of the PB session against the afternoon lap 7 - C-30 finds one clear cause (T1: braking starts 12 m later, -0.06 s), at most three notes' ($mA6.shown.lap -eq 6 -and $mA6.best.lap -eq 7 -and $mA6.ref.file -eq $midName -and $mA6.ref.lap -eq 7 -and $notes.Count -ge 1 -and $notes.Count -le 3 -and $notes[0].label -eq 'T1' -and $notes[0].code -eq 'brake' -and $notes[0].fact -eq 'braking starts 12 m later')
  $okN = $true
  foreach ($n in $notes) {
    $thr = switch ($n.code) { 'brake' { [math]::Abs([double]$n.dBrakeM) -ge 5 } 'entry' { [math]::Abs([double]$n.dEntryKmh) -ge 3 } 'min' { [math]::Abs([double]$n.dMinKmh) -ge 3 } 'pickup' { [math]::Abs([double]$n.dPickupM) -ge 10 } 'exit' { [math]::Abs([double]$n.dExitKmh) -ge 3 } default { $false } }
    if (-not ([math]::Abs([double]$n.dTime) -ge 0.05 -and $thr -and $n.fact.Length -gt 0)) { $okN = $false; Note "note $($n.label) breaks a threshold" }
  }
  Check 'every note passes the C-30 thresholds: the corner differs by 0.05 s or more and its one cause by 5 m / 3 km/h / 10 m' $okN
  Check 'notes are sorted by the time they are about, biggest first' ((@($notes | ForEach-Object { [math]::Abs([double]$_.dTime) }) -join ',') -eq ((@($notes | ForEach-Object { [math]::Abs([double]$_.dTime) }) | Sort-Object -Descending) -join ','))
  Check 'the PB session against its previous best has corners (14) but no note: no clear single cause, so nothing is made up' (@($mA.corners).Count -eq 14 -and @($mA.notes).Count -eq 0)
  $codes = @($mB.corners | ForEach-Object { $_.dTime })
  Check 'every corner carries its time against the reference (the map labels use them)' (@($mB.corners).Count -eq 14 -and ($mB.corners | Where-Object { $null -eq $_.dTime }).Count -eq 0)

  Section '3b. iRacing''s own best lap is the evidence: a lap with an off-track record that BECAME its best counts, whatever our off-track record says'
  # 2026-10-06 21-10-08: laps 2 (42 off-track records) and 3 (34) were quicker than iRacing's best so far and its LapBestLapTime became each of them - it counted them
  $dD = Join-Path $work 'd'; New-Item -ItemType Directory -Force $dD | Out-Null
  $nameD = $pre + '2026-10-06 21-10-08.ibt'
  Copy-Item -LiteralPath (Join-Path $docTel $nameD) -Destination (Join-Path $dD $nameD)
  $runD = Invoke-Session $dD $nameD 0 'D'; $mD = $runD.j
  $rawD = Raw-Laps (Read-Raw (Join-Path $dD $nameD))
  $lD = @($mD.laps)
  foreach ($ln in 1, 2, 3) { $x = @($lD | Where-Object { $_.n -eq $ln })[0]; if ($x) { $r = $rawD[$ln]; Note ("lap {0}  {1}  off-track records {2,2}  iRacing best before {3} after {4}  -> {5}: {6}" -f $ln, (F3 $r.llt), $r.offN, (F3 $r.bestBefore), (F3 $r.bestAfter), $(if ($r.counted) { 'COUNTED' } else { 'not counted' }), $r.by) } }
  $dOk = $runD.exit -eq 0 -and @($lD | Where-Object { $_.n -in 1, 2, 3 }).Count -eq 3
  foreach ($ln in 2, 3) { $x = @($lD | Where-Object { $_.n -eq $ln })[0]; $r = $rawD[$ln]; if (-not ($x -and $x.valid -and $x.offTrack -and $x.flag -eq '' -and $r.counted -and $r.off -and $x.offSamples -eq $r.offN -and $x.countedBy -eq "iRacing's best lap became this lap")) { $dOk = $false; Note "lap $ln not as expected" } }
  Check 'laps 2 (1:21.380, 42 off-track records) and 3 (1:20.695, 34) are COUNTED: iRacing''s best lap became each of them (82.436 then 81.380 then 80.695), so its evidence beats our off-track record; they carry no flag word' ($dOk -and (F3 $rawD[2].llt) -eq '81.380' -and $rawD[2].offN -eq 42 -and (F3 $rawD[3].llt) -eq '80.695' -and $rawD[3].offN -eq 34 -and (F3 $rawD[3].bestBefore) -eq '81.380' -and (F3 $rawD[3].bestAfter) -eq '80.695')
  Check 'so the best lap of that session is lap 3 (1:20.695, a lap with an off-track record that iRacing counted) and 3 laps are valid' ($mD.best.lap -eq 3 -and (F3 $mD.best.time) -eq '80.695' -and $mD.validLaps -eq 3)
  # a practice session (Ferrari, Road Atlanta): the laps have hundreds of off-track records (our C-30 skip is "off") but iRacing's best became every one of them from lap 1 to 4 -
  # lap 4 (1:44.133) is the reference the live delta bar adopted for this car and track. Lap 5 is not quicker than that and has off-track records: no evidence, the record decides.
  $dF = Join-Path $work 'f'; New-Item -ItemType Directory -Force $dF | Out-Null
  $nameF = 'ferrari296gt3_roadatlanta full 2026-10-10 17-45-41.ibt'
  Copy-Item -LiteralPath (Join-Path $docTel $nameF) -Destination (Join-Path $dF $nameF)
  $runF = Invoke-Session $dF $nameF 0 'F'; $mF = $runF.j
  $rawF = Raw-Laps (Read-Raw (Join-Path $dF $nameF))
  $lF = @($mF.laps)
  foreach ($ln in 1, 2, 3, 4, 5) { $r = $rawF[$ln]; if ($r) { Note ("lap {0}  {1}  off-track records {2,4}  iRacing best before {3} after {4}  -> {5}: {6}" -f $ln, (F3 $r.llt), $r.offN, (F3 $r.bestBefore), (F3 $r.bestAfter), $(if ($r.counted) { 'COUNTED' } else { 'not counted' }), $r.by) } }
  $fOk = $runF.exit -eq 0
  foreach ($ln in 1, 2, 3, 4) { $x = @($lF | Where-Object { $_.n -eq $ln })[0]; $r = $rawF[$ln]; if (-not ($x -and $x.valid -and $x.skip -eq 'off' -and $r.counted -and $r.offN -gt 45 -and $x.countedBy -eq "iRacing's best lap became this lap")) { $fOk = $false; Note "ferrari lap $ln not as expected" } }
  $x5 = @($lF | Where-Object { $_.n -eq 5 })[0]
  Check 'practice: laps 1 to 4 have 3107, 1766, 513 and 686 off-track records (over our 45) but iRacing''s best became each of them: all COUNTED; the best lap is lap 4, 1:44.133' ($fOk -and $mF.best.lap -eq 4 -and (F3 $mF.best.time) -eq '104.133' -and $mF.validLaps -eq 4)
  Check 'lap 5 (1:50.527) is not quicker than iRacing''s best so far (104.133), so its best says nothing; it has off-track records: not counted, flagged OFF' ($x5 -and -not $x5.valid -and $x5.flag -eq 'OFF' -and $x5.countedBy -like '*no evidence; off-track record' -and -not $rawF[5].counted)
  # L-1b: the optimal / theoretical best joins sectors only from counted laps with NO off-track record (and not skip "off"). Every counted lap of the Ferrari practice has hundreds of
  # records, so there is nothing to join: no optimal at all (before: 1:30.279 against a best of 1:44.133, built from sectors across the grass). Best lap, best-N stay on iRacing's verdict.
  $pureF = @($lF | Where-Object { $_.valid -and -not $_.offTrack -and $_.skip -ne 'off' })
  Check 'practice Ferrari: no counted lap without an off-track record, so there is NO optimal and no best sectors (null), while the best lap (1:44.133, lap 4) and the best-4 average still follow iRacing''s verdict' ($pureF.Count -eq 0 -and $null -eq $mF.optimal -and $null -eq $mF.bestSectors -and $mF.best.lap -eq 4 -and $mF.consistency.n -eq 4 -and @($lF | Where-Object { $_.valid }).Count -eq 4 -and (@($rawF[1], $rawF[2], $rawF[3], $rawF[4]) | Where-Object { $_.counted -and $_.offN -eq 0 }).Count -eq 0)
  # 21-10-08: laps 2 and 3 are counted but have 42 and 34 records, lap 3 (1:20.695) is the best lap; only lap 1 (1:22.436) is clean, and joining it would give a "best" slower than the best lap: no optimal
  Check '21-10-08: only lap 1 is clean; the best lap (3, 1:20.695) is not, so the optimal that could be joined (from lap 1 alone, 1:22.436) is slower than the best lap: none' ($null -eq $mD.optimal -and $null -eq $mD.bestSectors -and $mD.best.lap -eq 3 -and $mD.validLaps -eq 3)
  # the other practice sessions of the real folder: never an optimal far under the best lap; where one is shown it is joined from clean counted laps only (checked against the reply's own lap list)
  $extra = @(@{ n = 'ferrari296gt3_roadatlanta full 2026-10-10 20-31-24.ibt'; k = 'g' }, @{ n = 'ferrari296gt3_virginia 2022 full 2026-10-10 18-14-24.ibt'; k = 'h' }, @{ n = 'bmwm4gt3_roadatlanta full 2026-10-10 16-40-31.ibt'; k = 'i' })
  foreach ($e in $extra) {
    $dX = Join-Path $work $e.k; New-Item -ItemType Directory -Force $dX | Out-Null
    Copy-Item -LiteralPath (Join-Path $docTel $e.n) -Destination (Join-Path $dX $e.n)
    $rX = Invoke-Session $dX $e.n 0 ('X' + $e.k); $mX = $rX.j
    $pX = @($mX.laps | Where-Object { $_.valid -and -not $_.offTrack -and $_.skip -ne 'off' -and $_.sectors })
    $okX = $rX.exit -eq 0
    if ($null -ne $mX.optimal) {
      $minS = @(0..(@($mX.sectorAt).Count - 1) | ForEach-Object { $k = $_; [double](($pX | ForEach-Object { [math]::Round([double]$_.sectors[$k], 3, 'AwayFromZero') } | Measure-Object -Minimum).Minimum) })
      $okX = $okX -and $pX.Count -gt 0 -and (Near $mX.optimal (($minS | Measure-Object -Sum).Sum) 0.0006) -and ([double]$mX.best.time - [double]$mX.optimal) -lt 1.5 -and ([double]$mX.optimal -le [double]$mX.best.time + 0.0006)
    } else { $okX = $okX -and $null -eq $mX.bestSectors }
    Note ("{0}: {1} counted laps, {2} clean; best {3}; optimal {4}" -f $e.n.Substring($e.n.Length - 23), @($mX.laps | Where-Object { $_.valid }).Count, $pX.Count, (F3 $mX.best.time), $(if ($null -ne $mX.optimal) { F3 $mX.optimal } else { 'none' }))
    Check ("{0}: the optimal is none, or it is the best sectors of the {1} clean counted laps joined and not more than 1.5 s under the best lap" -f $e.n.Substring($e.n.Length - 23), $pX.Count) $okX
  }

  Section '4. the page against real fixtures: numbers, colours, map, chart, notes, no overlaps'
  $mapA = Invoke-Channels $dAB $pbName 7 $mA.ref.spec 'mapA'
  Check 'the map comes from the workbench path: /analysis/channels lap 7 against the same reference, Lat and Lon' ($mapA.exit -eq 0 -and $mapA.head.lap.lap -eq 7 -and $mapA.head.ref.lap -eq 7 -and $mapA.head.ref.file -eq $midName -and @($mapA.head.channels).Count -eq 2)
  Check 'and the map''s reference is not the lap itself' (-not ($mapA.head.ref.file -eq $mapA.head.lap.file -and $mapA.head.ref.lap -eq $mapA.head.lap.lap))
  $urlA = (FileUrl (Join-Path $www 'sessionreview.html')) + '?data=' + (FileUrl $runA.path) + '&map=' + (FileUrl $mapA.path)
  Cdp-Open $urlA
  $ready = Cdp-Wait 'typeof SessionReview !== "undefined" && SessionReview.ready' 20
  Start-Sleep -Milliseconds 400
  Check 'the page loaded the fixture without a JavaScript error' ($ready -and -not (Cdp-Eval 'SessionReview.error || ""') -and $script:cdp.errors.Count -eq 0)
  if ($script:cdp.errors.Count) { Note ('JavaScript: ' + ($script:cdp.errors -join ' / ')) }
  $txt = Cdp-Eval 'document.querySelector(".sr").innerText'
  Check 'identity band: number 64, PETER, the team, the car, the track with its length' ((Cdp-Eval 'document.querySelector(".plate").textContent') -eq '64' -and $txt -match 'PETER' -and $txt -match 'Chevrolet Corvette Z06 GT3\.R' -and $txt -match 'ROAD ATLANTA · FULL COURSE · 4\.06 KM')
  $dateExp = $startLocal.ToString('ddd d MMM', $inv).ToUpper()
  Check "session line: RACE, $dateExp, 11 LAPS; the pill says NEW PERSONAL BEST -0.026" ($txt -match [regex]::Escape("RACE · $dateExp · 11 LAPS") -and $txt -match 'NEW PERSONAL BEST\s+−0\.026')
  $rows = Cdp-Json $rowsJs
  Check 'the table has the 11 laps with 4 sector columns (S1-S4) and a 24-piece strip each' (@($rows).Count -eq 11 -and @($rows[0].sec).Count -eq 4 -and $rows[0].mini.Length -eq 24)
  $fmt = { param($t) $t = [double]$t; $mn = [math]::Floor($t / 60); $s = $t - $mn * 60; "{0}:{1}" -f $mn, ($s.ToString('00.000', $inv)) }
  $textOk = $true
  for ($i = 0; $i -lt 11; $i++) {
    $l = $laps[$i]; $r = $rows[$i]
    if ($r.time -ne (& $fmt $l.time)) { $textOk = $false; Note "lap $($l.n) time shows $($r.time), data $($l.time)" }
    for ($k = 0; $k -lt 4; $k++) { if ($r.sec[$k].t -ne (F3 $l.sectors[$k])) { $textOk = $false; Note "lap $($l.n) S$($k + 1) shows $($r.sec[$k].t), data $($l.sectors[$k])" } }
  }
  Check 'every lap time (m:ss.mmm) and every sector on screen is the number in the data, to 0.001' $textOk
  $gapOk = $true
  for ($i = 0; $i -lt 11; $i++) {
    $l = $laps[$i]; $r = $rows[$i]
    $want = if ($l.valid) { if ($l.n -eq 7) { '' } else { '+' + (F3 ([double]$l.time - 79.549)) } } else { $l.flag }
    if ($r.gap.Trim() -ne $want) { $gapOk = $false; Note "lap $($l.n) gap shows '$($r.gap)' wanted '$want'" }
  }
  Check 'the gap column is the time behind the best lap (blank on the best lap) and OUT / OFF / INVALID / IN on the grey laps' $gapOk
  # C-41b: the longest flag word (INVALID) fits its column, on one line, clear of the lap time and the sector columns beside it
  $fit = Cdp-Json '(function(){var o=[];[].forEach.call(document.querySelectorAll(".sr .sr-flag"),function(f){var r=f.getBoundingClientRect(),p=f.previousElementSibling.getBoundingClientRect(),row=f.parentNode.getBoundingClientRect();o.push({s:f.textContent,w:f.scrollWidth,cw:f.clientWidth,h:r.height,left:r.left,prevRight:p.right,right:r.right,rowRight:row.right})});return o})()'
  Note ('flag words on screen: ' + ((@($fit) | ForEach-Object { "$($_.s) $([math]::Round($_.w))/$([math]::Round($_.cw)) px" }) -join ', '))
  Check 'the flag words OUT, OFF (five laps), INVALID and IN fit the GAP column without being cut or overlapping the cell beside it' (@($fit).Count -eq 8 -and (@($fit | Where-Object { $_.s -eq 'INVALID' }).Count -eq 1) -and (@($fit | Where-Object { $_.s -eq 'OFF' }).Count -eq 5) -and @($fit | Where-Object { $_.w -gt $_.cw + 0.5 -or $_.h -gt 40 -or $_.left -lt $_.prevRight - 0.5 -or $_.right -gt $_.rowRight + 0.5 }).Count -eq 0)
  $exp = Expect-Colours $mA
  $colOk = $true; $seen = @{ sp = 0; sn = 0; sy = 0; sg = 0; p = 0; n = 0; y = 0; g = 0 }
  for ($i = 0; $i -lt 11; $i++) {
    $l = $laps[$i]; $r = $rows[$i]; $e = $exp[[int]$l.n]
    for ($k = 0; $k -lt 4; $k++) { $cls = $r.sec[$k].c.Trim(); $seen[$cls]++; if ($cls -ne $e.sec[$k]) { $colOk = $false; Note "lap $($l.n) S$($k + 1) is $cls, rule says $($e.sec[$k])" } }
    if ($r.mini -ne $e.mini) { $colOk = $false; Note "lap $($l.n) strip $($r.mini) rule $($e.mini)" }
    foreach ($ch in $r.mini.ToCharArray()) { $seen["$ch"]++ }
    if (($r.tcls -split ' ')[1] -ne $e.time) { $colOk = $false; Note "lap $($l.n) time class $($r.tcls), rule $($e.time)" }
  }
  Note "colours seen: sectors purple $($seen.sp) green $($seen.sn) yellow-ish $($seen.sy) grey $($seen.sg); strip purple $($seen.p) green $($seen.n) yellow $($seen.y) grey $($seen.g)"
  Check 'purple = best ever, green = best of the session, yellow = slower, grey = out / in / off: every sector, every mini-sector and every lap time follows the rule' $colOk
  Check 'purple, yellow and grey sectors and all four strip colours really occur on this session (the rule is exercised, not vacuous)' ($seen.sp -gt 0 -and $seen.sy -gt 0 -and $seen.sg -gt 0 -and $seen.p -gt 0 -and $seen.n -gt 0 -and $seen.y -gt 0 -and $seen.g -gt 0)
  Note ('best row: ' + ($rows[6] | ConvertTo-Json -Compress -Depth 4))
  Check 'the best lap row is gold and its time is purple (a new personal best)' ($rows[6].best -and $rows[6].tcls -match 'sp' -and @($rows | Where-Object { $_.best }).Count -eq 1 -and $rows[0].grey -and $rows[10].grey -and -not $rows[6].grey)
  Check 'the OPTIMAL row shows 1:19.161, the best sectors of the counted laps joined, and −0.388 against the best lap' ($txt -match '1:19\.161' -and $txt -match 'OPTIMAL' -and $txt -match '−0\.388')
  $nums = Cdp-Eval '(function(){return Array.prototype.map.call(document.querySelectorAll(".sr .nums > div"),function(d){return d.innerText.replace(/\s+/g," ")}).join(" | ")})()'
  Check 'the four numbers: best lap 1:19.549 (new PB, -0.026 s, lap 7), optimal, consistency 1:19.786 ±0.17 s over the best 3, laps 11 · 3 clean · 17 min' ($nums -match 'BEST LAP 1:19\.549 new PB, −0\.026 s · lap 7' -and $nums -match 'OPTIMAL 1:19\.16\d' -and $nums -match 'CONSISTENCY 1:19\.786 average of best 3 · spread ±0\.17 s' -and $nums -match 'LAPS 11 · 3 clean 17 min on track')
  # the map: coloured by gain / loss of lap 7 against the afternoon lap 7
  $mp = Cdp-Json '(function(){var s=document.querySelector(".mapbox"),L=s.querySelectorAll("line"),g=0,r=0,n=0;L.forEach(function(l){var c=l.getAttribute("stroke");if(c.indexOf("60,207,126")>0)g++;else if(c.indexOf("229,83,75")>0)r++;else n++});var ci=s.querySelectorAll("circle");var lab=Array.prototype.map.call(s.querySelectorAll("text"),function(t){return t.textContent});return {seg:L.length,g:g,r:r,n:n,circles:ci.length,labels:lab}})()'
  Note "map: $($mp.seg) segments (green $($mp.g), red $($mp.r), grey $($mp.n)), $($mp.circles) corner rings"
  Check 'the map is coloured by time gained (green) and lost (red) along the whole lap' ($mp.seg -gt 900 -and $mp.g -gt 40 -and $mp.r -gt 40 -and $mp.n -gt 20)
  $top3 = @($mA.corners | Where-Object { [math]::Abs([double]$_.dTime) -ge 0.05 } | Sort-Object { [math]::Abs([double]$_.dTime) } -Descending | Select-Object -First 3)
  $labsOk = $mp.circles -eq 14; foreach ($t in $top3) { $want = $(if ([double]$t.dTime -lt 0) { '−' } else { '+' }) + ([math]::Abs([double]$t.dTime)).ToString('0.00', $inv) + ' s'; if ($mp.labels -notcontains $want) { $labsOk = $false; Note "missing map label $want" } }
  Check '14 corners are marked and the three biggest differences carry their time (T10a, T10b, T5)' ($labsOk -and $top3.Count -eq 3 -and $top3[0].label -eq 'T10a')
  $onTrack = Cdp-Json '(function(){var s=document.querySelector(".mapbox"),pl=s.querySelector("polyline").getAttribute("points").trim().split(" ").map(function(p){var q=p.split(",");return [+q[0],+q[1]]}),bad=[];s.querySelectorAll("text").forEach(function(t){if(+t.getAttribute("font-size")<14)return;var b=t.getBBox();if(pl.some(function(p){return p[0]>b.x-4&&p[0]<b.x+b.width+4&&p[1]>b.y-4&&p[1]<b.y+b.height+4}))bad.push(t.textContent)});return bad})()'
  Check 'no map label (the three times, S/F) sits on the track line' (@($onTrack).Count -eq 0)
  Check 'the map says what it compares: best lap 1:19.549 against his previous best 1:19.575, green gained, red lost' ($txt -match 'BEST LAP 1:19\.549 VS PREVIOUS BEST 1:19\.575 · GREEN = GAINED · RED = LOST')
  Check 'Lovely Track Data is credited under the map' ($txt -match 'Lovely Track Data')
  $ch = Cdp-Json '(function(){var s=document.querySelector("svg.chart");if(!s)return null;var t=s.textContent;return {dots:s.querySelectorAll("circle").length,pb:/PREVIOUS PB 1:19\.575/.test(t),title:/LAP TIMES/.test(t)}})()'
  Check 'the lap-time chart is there (11 laps): a dot per lap, the previous PB as a rule' ($ch -and $ch.dots -eq 11 -and $ch.pb -and $ch.title)
  Check 'no corner is made up: there is no notes block (the C-30 engine found no single cause)' ($txt -notmatch 'Lap 7 against previous best' -and $txt -notmatch 'No corner differs')
  Check 'ANALYSIS is on the screen and no other button' ((Cdp-Eval 'document.querySelector("#srAnalysis") && !document.querySelector("#srAnalysis").hidden') -eq $true -and (Cdp-Eval 'document.querySelectorAll(".sr button:not([hidden])").length') -eq 1)
  $ov = Cdp-Json 'SessionReview.overlaps(document.querySelector(".sr"))'
  Note "text boxes measured: $($ov.boxes)"; if ($ov.bad.Count) { Note ('overlapping: ' + ($ov.bad -join '; ')) }
  Check 'no text overlaps another (every DOM and map text box measured against every other)' ($ov.boxes -gt 120 -and $ov.bad.Count -eq 0)
  $small = Cdp-Json '(function(){return SessionReview.boxes(document.querySelector(".sr")).filter(function(b){return b.fs<14}).map(function(b){return b.s+" "+b.fs})})()'
  Check 'every text is 14 px or larger (the only exception: the corner numbers inside the map rings)' (@($small | Where-Object { $_ -notmatch '^[0-9A-Z]{1,3} ' }).Count -eq 0)
  Cdp-Shot (Join-Path $shots 'sr-review.png')
  Check 'picture tests\shots\sr-review.png written (compare with docs\mockups\session-review.png)' ((Get-Item (Join-Path $shots 'sr-review.png')).Length -gt 80000)

  Section '5. other states: notes, the empty state on a real short session, no history, 30 laps, no map, the fallback, a race, scaling'
  # notes (lap 6 of the PB session against the afternoon's lap 7)
  $mapA6 = Invoke-Channels $dAB $pbName 6 $mA6.ref.spec 'mapA6'
  $ready = Nav-Page ((FileUrl (Join-Path $www 'sessionreview.html')) + '?data=' + (FileUrl $runA6.path) + '&map=' + (FileUrl $mapA6.path))
  $txtB = Cdp-Eval 'document.querySelector(".sr").innerText'
  $nb = Cdp-Json '(function(){return Array.prototype.map.call(document.querySelectorAll(".sr .notes .n"),function(n){return {label:n.children[0].textContent,t:n.children[1].textContent,tc:n.children[1].className,fact:n.children[2].textContent}})})()'
  Check 'the note is on screen: T1, -0.06 s in green (time gained), "braking starts 12 m later"' ($ready -and @($nb).Count -eq 1 -and $nb[0].label -eq 'T1' -and $nb[0].t -eq '−0.06 s' -and $nb[0].tc -eq 'gain' -and $nb[0].fact -eq 'braking starts 12 m later')
  Check 'its title says which lap and against what: LAP 6 AGAINST PREVIOUS BEST; the map label says LAP 6' ($txtB -match 'Lap 6 against previous best' -and $txtB -match 'LAP 6 1:19\.931 VS PREVIOUS BEST 1:19\.575')
  $ovA6 = Cdp-Json 'SessionReview.overlaps(document.querySelector(".sr"))'
  if ($ovA6.bad.Count) { Note ('overlapping: ' + ($ovA6.bad -join '; ')) }
  Check 'no text overlaps on the notes screen' ($ovA6.bad.Count -eq 0 -and $ovA6.boxes -gt 120)
  Cdp-Shot (Join-Path $shots 'sr-notes.png')
  Check 'picture tests\shots\sr-notes.png written' ((Get-Item (Join-Path $shots 'sr-notes.png')).Length -gt 80000)
  # a session that is slower than his PB: lap 6 of the older session, its best is lap 9
  $mapB = Invoke-Channels $dB $oldName 6 $mB.ref.spec 'mapB'
  $ready = Nav-Page ((FileUrl (Join-Path $www 'sessionreview.html')) + '?data=' + (FileUrl $runB.path) + '&map=' + (FileUrl $mapB.path))
  Check 'this session is slower than his PB: no purple lap time, no new-PB pill (it says BEST ...)' ($ready -and (Cdp-Eval 'document.querySelector(".pill").textContent') -match '^BEST 1:19\.648' -and (Cdp-Json $rowsJs | Where-Object { $_.best }).tcls -notmatch 'sp')
  # the colour rule again, on a session that is slower than the history: here sectors are GREEN (best of this session, not best ever)
  $rowsB = Cdp-Json $rowsJs; $expB = Expect-Colours $mB; $okB = $true; $greenB = 0; $purpleB = 0
  for ($i = 0; $i -lt @($mB.laps).Count; $i++) {
    $l = @($mB.laps)[$i]; $r = $rowsB[$i]; $e = $expB[[int]$l.n]
    for ($k = 0; $k -lt 4; $k++) { $cls = $r.sec[$k].c.Trim(); if ($cls -ne $e.sec[$k]) { $okB = $false; Note "lap $($l.n) S$($k + 1) is $cls, rule says $($e.sec[$k])" }; if ($cls -eq 'sn') { $greenB++ }; if ($cls -eq 'sp') { $purpleB++ } }
    if ($r.mini -ne $e.mini) { $okB = $false; Note "lap $($l.n) strip $($r.mini) rule $($e.mini)" }
  }
  Check 'the colour rule holds on this session too, and now there are green sectors (best of the session, but not better than his history)' ($okB -and $greenB -gt 0)
  $ovB = Cdp-Json 'SessionReview.overlaps(document.querySelector(".sr"))'
  if ($ovB.bad.Count) { Note ('overlapping: ' + ($ovB.bad -join '; ')) }
  Note "text boxes measured on the slower-than-his-PB screen: $($ovB.boxes)"
  Check 'no text overlaps on the slower-than-his-PB screen (no note there, so fewer boxes than the notes screen)' ($ovB.bad.Count -eq 0 -and $ovB.boxes -gt 100)
  # the empty state: a real session with one counted lap (and one timed lap iRacing did not count)
  $mapC = Invoke-Channels $dC $smallName 2 $mC.ref.spec 'mapC'
  $ready = Nav-Page ((FileUrl (Join-Path $www 'sessionreview.html')) + '?data=' + (FileUrl $runC.path) + '&map=' + (FileUrl $mapC.path))
  $txtC = Cdp-Eval 'document.querySelector(".sr").innerText'
  $mpC = Cdp-Json '(function(){var s=document.querySelector(".mapbox");if(!s)return null;var g=0;s.querySelectorAll("line").forEach(function(l){var c=l.getAttribute("stroke");if(c.indexOf("rgba")==0)g++});return {seg:s.querySelectorAll("line").length,colour:g}})()'
  Check 'fewer than 3 clean laps: the best lap and no hint text (no notes, no optimal, no consistency, no chart)' ($ready -and $txtC -notmatch 'Drive 3 clean laps' -and $txtC -notmatch 'against next best' -and $txtC -match 'BEST LAP 1:20\.191' -and $txtC -notmatch 'CONSISTENCY' -and $txtC -notmatch 'OPTIMAL' -and -not (Cdp-Eval '!!document.querySelector("svg.chart")'))
  Check 'the map is still drawn, but plain (no green or red) because nothing can be compared yet' ($mpC -and $mpC.seg -gt 900 -and $mpC.colour -eq 0)
  $rowsC = Cdp-Json $rowsJs
  Check 'the table still lists the 3 laps (OUT, the one counted lap, and the timed lap iRacing did not count: OFF, grey) with their sectors' (@($rowsC).Count -eq 3 -and $rowsC[0].gap.Trim() -eq 'OUT' -and $rowsC[1].best -and $rowsC[2].gap.Trim() -eq 'OFF' -and $rowsC[2].grey -and (Cdp-Json '[...document.querySelectorAll(".sr .nums > div")].length') -eq 2)
  $ovC = Cdp-Json 'SessionReview.overlaps(document.querySelector(".sr"))'
  Check 'no text overlaps on the empty state' ($ovC.bad.Count -eq 0 -and $ovC.boxes -gt 40)
  Cdp-Shot (Join-Path $shots 'sr-empty.png')
  Check 'picture tests\shots\sr-empty.png written' ((Get-Item (Join-Path $shots 'sr-empty.png')).Length -gt 50000)

  # variants of the real session made on the page (the page recomputes everything from the lap list)
  $null = Nav-Page $urlA
  $null = Cdp-Eval @'
window.BASE = JSON.parse(JSON.stringify(SessionReview.state.last.M)); window.MP = SessionReview.state.last.mp;
window.V = function (mut, opts) { var M = JSON.parse(JSON.stringify(window.BASE)); if (mut) mut(M); opts = opts || {}; window.done = 0;
  return SessionReview.mount(document.getElementById('sr'), Object.assign({ model: M, mapData: opts.noMap ? null : window.MP }, opts)).then(function () { window.done = 1; return SessionReview.state.last.D; }); };
// keep only some laps of the real session (by index) and say which one is the best now
window.PICK = function (idx, force) { return function (M) { M.laps = idx.map(function (i) { var l = M.laps[i]; if (force && force.indexOf(i) >= 0) { l.valid = true; l.flag = ''; } return l; }); var b = null; M.laps.forEach(function (l) { if (l.valid && (!b || l.time < b.time)) b = l; }); M.best = b ? { lap: b.n, time: b.time } : null; M.shown = M.best; }; };
true
'@
  $null = Cdp-Eval 'V(function(M){M.prev=null;M.ever=null;M.ref={kind:"session",file:M.file,lap:6,time:79.931,spec:M.file+":6"}})'
  $null = Cdp-Wait 'window.done === 1' 5
  $txtN = Cdp-Eval 'document.querySelector(".sr").innerText'
  $rowsN = Cdp-Json $rowsJs
  $classes = ($rowsN | ForEach-Object { ($_.sec | ForEach-Object { $_.c }) -join ' ' }) -join ' '
  Check 'no history: no purple anywhere, the best lap is green, the pill says BEST 1:19.549, the map compares against his next best lap' ($classes -notmatch 'sp' -and (($rowsN | ForEach-Object { $_.mini }) -join '') -notmatch 'p' -and ($rowsN | Where-Object { $_.best }).tcls -match 'sn' -and $txtN -match 'BEST 1:19\.549' -and $txtN -notmatch 'NEW PERSONAL BEST' -and $txtN -match 'VS NEXT BEST' -and $txtN -notmatch 'first time here')
  # lap-count thresholds. In the real session laps 6, 7 and 8 (index 5, 6, 7) are valid; 1 is OUT, 3 is OFF, 4 is INVALID and 2, 5, 9, 10 are timed but have an
  # off-track record (not counted). The 4- and 5-lap cases need more valid laps than the session has, so they switch the listed laps to valid on the page (force).
  $cases = @(
    @{ idx = '[0,5,6]'; force = ''; what = '2 valid laps (OUT + 2)'; chart = $false; empty = $true; tile = '' },
    @{ idx = '[5,6,7]'; force = ''; what = '3 valid laps'; chart = $false; empty = $false; tile = 'average of best 3' },
    @{ idx = '[4,5,6,7]'; force = '[4]'; what = '4 laps, all valid'; chart = $false; empty = $false; tile = 'average of best 4' },
    @{ idx = '[1,4,5,6,7]'; force = '[1,4]'; what = '5 laps, all valid'; chart = $true; empty = $false; tile = 'average of best 5' },
    @{ idx = '[0,2,3,5,6,7]'; force = ''; what = '6 laps listed but only 3 valid'; chart = $true; empty = $false; tile = 'average of best 3' })
  foreach ($case in $cases) {
    $null = Cdp-Eval "V(PICK($($case.idx), $(if ($case.force) { $case.force } else { 'null' })))"
    $null = Cdp-Wait 'window.done === 1' 5
    $tt = Cdp-Eval 'document.querySelector(".sr").innerText'
    $hasChart = (Cdp-Eval '!!document.querySelector("svg.chart")') -eq $true
    $okCase = ($hasChart -eq $case.chart) -and (-not ($case.empty -and ($tt -match 'Lap \d+ against'))) -and ($case.empty -or $tt -match $case.tile)
    Check "$($case.what): the lap chart is $(if ($case.chart) { 'shown' } else { 'not shown' }) (only with 5+ laps), $(if ($case.empty) { 'there is no notes block' } else { "the consistency tile says $($case.tile)" })" $okCase
  }
  # a long session: 30 laps. The table keeps to its place: the latest laps, and the best lap on top when it is older; it says so.
  $null = Cdp-Eval @'
V(function(M){var rows=[];for(var i=0;i<30;i++){var l=JSON.parse(JSON.stringify(M.laps[1+(i%9)]));l.n=i+1;if(i===0){l.valid=false;l.flag='OUT'}rows.push(l)}M.laps=rows;M.best={lap:6,time:rows[5].time};M.shown=M.best})
'@
  $null = Cdp-Wait 'window.done === 1' 5
  $w30 = Cdp-Json '(function(){var r=document.querySelectorAll(".sr-tbl .sr-row[data-lap]");var b=document.querySelector(".sr-tbl").getBoundingClientRect();var nn=document.querySelector(".notes");var n=nn?nn.getBoundingClientRect():{top:99999};return {rows:r.length,first:+r[0].dataset.lap,last:+r[r.length-1].dataset.lap,laps:Array.prototype.map.call(r,function(x){return +x.dataset.lap}),bottom:b.bottom,notesTop:n.top,note:(document.querySelector(".tnote")||{}).textContent||"",best:+(document.querySelector(".sr-tbl .sr-row.sr-best")||{dataset:{lap:0}}).dataset.lap}})()'
  Note "30 laps: $($w30.rows) rows ($($w30.laps -join ',')), table bottom $([math]::Round($w30.bottom)) px, notes start $([math]::Round($w30.notesTop)) px, '$($w30.note)'"
  $ov30 = Cdp-Json 'SessionReview.overlaps(document.querySelector(".sr"))'
  Check '30 laps: at most 19 rows, the latest lap (30) is the last, the best lap (6) is kept on top, the table ends above the notes, and it says "best + last 18 of 30 laps"' ($w30.rows -le 19 -and $w30.last -eq 30 -and $w30.first -eq 6 -and $w30.best -eq 6 -and $w30.bottom -lt $w30.notesTop -and $w30.note -match 'best \+ last 18 of 30 laps')
  Check '30 laps: no text overlaps' ($ov30.bad.Count -eq 0)
  Cdp-Shot (Join-Path $shots 'sr-30laps.png')
  # no map (the channel reply failed): a plain message, the rest unchanged
  $null = Cdp-Eval 'window.done=0; V(null, { noMap: true }).then(function(){window.done=1})'; $null = Cdp-Wait 'window.done === 1' 5
  $tm = Cdp-Eval 'document.querySelector(".sr").innerText'
  Check 'no map data: "No map" and everything else is still there' ($tm -match 'No map' -and $tm -match 'BEST LAP' -and (Cdp-Json $rowsJs).Count -eq 11)
  # the fallback: the file cannot be read, the laps the dashboard saw live
  # (C-41c) a lap the dashboard did not call clean is dimmed; it carries a word only when the dashboard gave the reason (a row's why: out, in, pit, off).
  # Lap 1 here says why:"out" and gets OUT; lap 5 says nothing and gets no word (it used to be OFF for every such lap, and OUT for the first row).
  $null = Cdp-Eval 'window.done=0; SessionReview.mount(document.getElementById("sr"), { model: SessionReview.liveModel({ type: "Practice", track: "Road Atlanta · Full Course", car: "Corvette Z06 GT3.R", mins: 12, startMs: Date.now(), rows: [{n:1,time:84.1,clean:false,why:"out"},{n:2,time:80.5,clean:true},{n:3,time:80.2,clean:true},{n:4,time:80.9,clean:true},{n:5,time:81.7,clean:false}] }) }).then(function(){window.done=1})'
  $null = Cdp-Wait 'window.done === 1' 5
  $tf = Cdp-Eval 'document.querySelector(".sr").innerText'; $ovF = Cdp-Json 'SessionReview.overlaps(document.querySelector(".sr"))'
  Check 'the fallback (the file could not be read) lists the laps he drove with their gaps, has no ANALYSIS button and no overlaps' ($tf -match '1:20\.2' -and $tf -match 'OUT' -and (Cdp-Eval 'document.querySelector("#srAnalysis").hidden') -eq $true -and $ovF.bad.Count -eq 0)
  $fb = Cdp-Json ('[].map.call(document.querySelectorAll(".sr-tbl .sr-row[data-lap]"),function(r){return {n:+r.dataset.lap,grey:r.classList.contains("grey"),gap:r.lastElementChild.textContent.trim()}})')
  Note ('fallback rows on screen: ' + (($fb | ForEach-Object { "lap $($_.n) " + $(if ($_.grey) { 'dim' } else { 'normal' }) + " '$($_.gap)'" }) -join ', '))
  Check 'fallback: lap 1 (the dashboard said why: out) is dim and says OUT; lap 5 (not clean, no reason given) is dim with no word; the clean laps are not dim; the word OFF is nowhere' ($fb.Count -eq 5 -and $fb[0].grey -eq $true -and $fb[0].gap -eq 'OUT' -and $fb[4].grey -eq $true -and $fb[4].gap -eq '' -and @($fb[1..3] | Where-Object { $_.grey }).Count -eq 0 -and $tf -notmatch '\bOFF\b')
  $lm = Cdp-Json ('SessionReview.liveModel({ rows: [{n:1,time:84,clean:false},{n:2,time:80,clean:true,why:"out"},{n:3,time:85,clean:false,why:"pit"},{n:4,time:85,clean:false,why:"IN"},{n:5,time:85,clean:false,why:"out"},{n:6,time:85,clean:false,why:"off"},{n:7,time:85,clean:false,why:"constructor"},{n:8,time:85,clean:false,why:"parked"}] }).laps.map(function(l){return l.valid+":"+l.flag})')
  $lt = Cdp-Json ('SessionReview.liveModel({ times: [{t:84,clean:false},{t:80,clean:true},{t:85,clean:false,why:"in"}] }).laps.map(function(l){return l.valid+":"+l.flag})')
  Note ('liveModel flags: ' + ($lm -join ' ') + ' | from times: ' + ($lt -join ' '))
  Check 'liveModel: the first row is no longer called OUT without proof; a word comes only from the row''s own reason (PIT, IN, OUT, OFF, any case); an unknown reason, a made-up key and a clean lap get none' (($lm -join ',') -eq 'false:,true:,false:PIT,false:IN,false:OUT,false:OFF,false:,false:' -and ($lt -join ',') -eq 'false:,true:,false:IN')
  # scaling to another window
  Cdp-Close
  Cdp-Open $urlA 1280 720
  $null = Cdp-Wait 'typeof SessionReview !== "undefined" && SessionReview.ready && document.querySelector(".sr-tbl")' 20
  $sc = Cdp-Json '(function(){var r=document.querySelector(".sr-stage").getBoundingClientRect();return {w:r.width,h:r.height,l:r.left,t:r.top}})()'
  Check 'in a 1280 x 720 window the whole 1920 x 1080 stage is scaled to fit, nothing cut off' ((Near $sc.w 1280 2) -and (Near $sc.h 720 2) -and $sc.l -ge -1 -and $sc.t -ge -1)
  Cdp-Close
  # a race: position and incidents next to the session line
  Cdp-Open ($urlA + '&race=1&pos0=9&pos=5&inc=2')
  $null = Cdp-Wait 'typeof SessionReview !== "undefined" && SessionReview.ready && document.querySelector(".sr-tbl")' 20
  $txtR = Cdp-Eval 'document.querySelector(".sr").innerText'
  $ovR = Cdp-Json 'SessionReview.overlaps(document.querySelector(".sr"))'
  Check 'race extras: "P9 → P5 +4 · 2 INCIDENTS" under the session line, nothing overlaps' ($txtR -match 'P9 → P5 \+4 · 2 INCIDENTS' -and $ovR.bad.Count -eq 0)
  Cdp-Shot (Join-Path $shots 'sr-race.png')
  Check 'picture tests\shots\sr-race.png written' ((Get-Item (Join-Path $shots 'sr-race.png')).Length -gt 80000)
  Check 'no JavaScript exception during the page runs' ($script:cdp.errors.Count -eq 0)
  if ($WriteDemo) {
    Cdp-Close
    Cdp-Open $urlA
    $null = Cdp-Wait 'typeof SessionReview !== "undefined" && SessionReview.ready && document.querySelector(".sr-tbl")' 20
    $demo = Cdp-Eval '(function(){var s=SessionReview.state.last;var r=function(k,v){return typeof v==="number"?Math.round(v*1e6)/1e6:v};return JSON.stringify({M:s.M,mp:s.mp},r)})()'
    [IO.File]::WriteAllText((Join-Path $www 'sr-demo.json'), $demo, (New-Object Text.UTF8Encoding($false)))
    Note "wrote dash\www\v2\sr-demo.json ($($demo.Length) characters)"
  }
  Cdp-Close

  Section '6. the dashboard (index.html) against a pretend irdash: after a session, the strip, ANALYSIS and BACK, nothing while he drives, the demo'
  $port = 8742
  $cfgFile = Join-Path $work 'cfg.json'; $logFile = Join-Path $work 'requests.log'; $script:logPath = $logFile
  $reviewJson = '{"enabled":true,"up":true,"kept":false,"driving":false,"pending":false,"n":3,"leftMs":8000,"waitMs":60000,"defaultMs":60000,"teachMs":8000,"line":"3 laps saved — lap 7 1:19.549, lap 8 1:19.878, lap 6 1:19.931","wheel":"","laps":[]}'
  function Set-Cfg($code, $session, $channels, $race = 404) { @{ sessionCode = $code; session = $session; channels = $channels; review = $reviewJson; raceCode = $race } | ConvertTo-Json -Compress | Set-Content -LiteralPath $cfgFile -Encoding UTF8 }
  Set-Cfg 200 $runA.path $mapA.path
  Set-Content -LiteralPath $logFile -Value '' -Encoding UTF8
  $script:job = Start-Job -ScriptBlock $srvScript -ArgumentList $port, $www, $cfgFile, $logFile
  $up = $false; for ($i = 0; $i -lt 40 -and -not $up; $i++) { Start-Sleep -Milliseconds 250; try { $up = (Invoke-WebRequest -UseBasicParsing "http://localhost:$port/v2/sessionreview.html" -TimeoutSec 3).StatusCode -eq 200 } catch { } }
  Check 'the pretend irdash is serving the real www files' $up
  $live = '{type:"Race",race:true,track:"Road Atlanta · Full Course",car:"Corvette Z06 GT3.R",laps:11,cleanLaps:7,best:79.549,startMs:Date.now()-20*24*3600*1000,mins:17,inc:2,pos0:9,pos:5,rows:[{n:2,time:80.59,clean:true},{n:5,time:80.205,clean:true},{n:6,time:79.931,clean:true},{n:7,time:79.549,clean:true},{n:8,time:79.878,clean:true},{n:9,time:80.471,clean:true},{n:10,time:80.078,clean:true}]}'
  Cdp-Open "http://localhost:$port/v2/index.html"
  $ok = Cdp-Wait "typeof Debrief !== 'undefined' && typeof SessionReview !== 'undefined'" 25
  Check 'the dashboard loads debrief.js and sessionreview.js' $ok
  $null = Cdp-Eval "Debrief.show($live, true); 1"
  $on = Cdp-Wait "document.querySelector('#debrief.on .sr-tbl')" 15
  Check 'after a session the Session Review is on the top screen (it replaced the old summary)' ($on -and (Cdp-Eval "!document.querySelector('#debrief .db-hero, #debrief .db-bars')"))
  $null = Cdp-Wait "document.querySelector('#debrief #dbReview .db-rev-line') && document.querySelector('#debrief #dbReview .db-rev-line').textContent.indexOf('3 laps saved') === 0" 10
  $log = (Read-Log)
  Check 'it asked irdash for the newest session (id=last) and for the map of that file''s best lap against the same reference' ((@($log | Where-Object { $_ -match '^/analysis/session\?id=last' }).Count -ge 1) -and (@($log | Where-Object { $_ -match '^/analysis/channels\?id=' + [regex]::Escape([uri]::EscapeDataString($pbName)) + '&lap=7&ref=' + [regex]::Escape([uri]::EscapeDataString($midName + ':7')) + '&ch=Lat,Lon' }).Count -ge 1))
  $dtxt = Cdp-Eval "document.querySelector('#debrief').innerText"
  Check 'the real numbers are there (1:19.549 best, 4 sectors, the map label) and so are the race extras (P9 → P5 +4, 2 incidents)' ($dtxt -match 'NEW PERSONAL BEST' -and $dtxt -match '1:19\.549' -and $dtxt -match 'P9 → P5 \+4 · 2 INCIDENTS' -and $dtxt -match 'GREEN = GAINED')
  Check 'the saved-laps bar (C-07 / C-27 code) is inside the review: "3 laps saved — lap 7 ...", KEEPING ALL IN 8 S, KEEP ALL and CHOOSE' ($dtxt -match '3 laps saved — lap 7 1:19\.549, lap 8 1:19\.878, lap 6 1:19\.931' -and $dtxt -match 'KEEPING ALL IN 8 S' -and $dtxt -match 'KEEP ALL' -and $dtxt -match 'CHOOSE')
  $ovD = Cdp-Json 'SessionReview.overlaps(document.querySelector("#debrief"))'
  Check 'no text overlaps on the dashboard version, with the bar and the race extras' ($ovD.bad.Count -eq 0 -and $ovD.boxes -gt 120)
  $btn = Cdp-Json '(function(){var a=document.querySelector("#debrief #dbKeepAll").getBoundingClientRect(),b=document.querySelector("#debrief #dbChoose").getBoundingClientRect(),c=document.querySelector("#debrief #srAnalysis").getBoundingClientRect(),bar=document.querySelector("#debrief #dbReview").getBoundingClientRect();return {k:[a.left,a.right,a.height],c:[b.left,b.right,b.height],a:[c.left,c.right,c.height],bar:[bar.left,bar.right,bar.bottom]}})()'
  Check 'KEEP ALL, CHOOSE and ANALYSIS are big targets (48 px or more high), side by side inside the bottom edge of the screen' ($btn.k[2] -ge 48 -and $btn.c[2] -ge 48 -and $btn.a[2] -ge 48 -and $btn.k[1] -le $btn.c[0] + 1 -and $btn.bar[1] -le $btn.a[0] + 1 -and $btn.a[1] -le 1920 -and $btn.bar[2] -lt 1080)
  # (W6b) no race log (the pretend irdash answers 404 to /analysis/race): irdash is asked once for this session's file, and there is no RACE button
  Start-Sleep -Milliseconds 600
  $pos404 = Cdp-Json '(function(){var a=document.querySelector("#debrief #srAnalysis").getBoundingClientRect();return {ar:a.right,al:a.left,shown:document.querySelectorAll("#debrief button:not([hidden])").length,race:document.querySelector("#debrief #srRace").hidden}})()'
  $askedRace = @((Read-Log) | Where-Object { $_ -match '^/analysis/race\?id=' })
  Note ('RACE: asked ' + ($askedRace -join ' | ') + '; visible buttons ' + $pos404.shown)
  Check 'no race log (404): the review asked /analysis/race for the session''s file, and shows no RACE button (KEEP ALL, CHOOSE and ANALYSIS only)' ($askedRace.Count -ge 1 -and $askedRace[0] -eq ('/analysis/race?id=' + [uri]::EscapeDataString($pbName)) -and $pos404.race -eq $true -and $pos404.shown -eq 3)
  Start-Sleep -Milliseconds 400      # the review fades in over 0.7 s
  Cdp-Shot (Join-Path $shots 'sr-dashboard.png')
  Check 'picture tests\shots\sr-dashboard.png written' ((Get-Item (Join-Path $shots 'sr-dashboard.png')).Length -gt 80000)
  # KEEP ALL goes to the same server call as before
  $null = Cdp-Eval "document.querySelector('#debrief #dbKeepAll').click(); 1"; Start-Sleep -Milliseconds 400
  Check 'KEEP ALL still calls /api/do?c=vkkeepall and does not close the review' (@((Read-Log) | Where-Object { $_ -match 'c=vkkeepall' }).Count -ge 1 -and (Cdp-Eval "!!document.querySelector('#debrief.on')") -eq $true)
  # ANALYSIS opens the workbench on this session's best lap, BACK puts it away
  $null = Cdp-Eval "document.querySelector('#debrief #srAnalysis').click(); 1"
  $wb = Cdp-Wait "document.querySelector('#wbHost iframe')" 5
  $src = Cdp-Eval "(document.querySelector('#wbHost iframe') || {}).getAttribute ? document.querySelector('#wbHost iframe').getAttribute('src') : ''"
  Check 'ANALYSIS opens workbench.html on this session''s best lap against the same reference (an iframe over the review, like the Vault)' ($wb -and $src -eq ('workbench.html?id=' + [uri]::EscapeDataString($pbName) + '&lap=7&ref=' + [uri]::EscapeDataString($midName + ':7')) -and (Cdp-Eval "!!document.querySelector('#debrief.on')") -eq $true)
  Start-Sleep -Milliseconds 700
  $null = Cdp-Eval "document.querySelector('#wbBack').click(); 1"
  $gone = Cdp-Wait "!document.querySelector('#wbHost')" 4
  Check 'BACK closes the workbench and the review is still there' ($gone -and (Cdp-Eval "!!document.querySelector('#debrief.on .sr-tbl')") -eq $true)
  # a click on the review (not on a button) closes it, as the old debrief did
  $null = Cdp-Eval "document.querySelector('#debrief .sr-tbl').click(); 1"
  Check 'a click on the review closes it (the old tap-to-close); the bar and the buttons do not' ((Cdp-Wait "!Debrief.el" 3))
  # (W6b) a race log exists (the pretend irdash now answers 200): a RACE button appears next to ANALYSIS and opens the workbench on its RACE page
  Set-Cfg 200 $runA.path $mapA.path 200
  Set-Content -LiteralPath $logFile -Value '' -Encoding UTF8
  $null = Cdp-Eval "Debrief.show($live, true); 1"
  $on2 = Cdp-Wait "document.querySelector('#debrief.on .sr-tbl')" 15
  $raceUp = Cdp-Wait "document.querySelector('#debrief #srRace') && !document.querySelector('#debrief #srRace').hidden" 10
  Check 'a race log exists (200): a RACE button appears on the review' ($on2 -and $raceUp)
  Start-Sleep -Milliseconds 900
  $rg = Cdp-Json '(function(){var q=function(s){var r=document.querySelector(s).getBoundingClientRect();return {l:r.left,r:r.right,t:r.top,h:r.height}};return {race:q("#debrief #srRace"),an:q("#debrief #srAnalysis"),bar:q("#debrief #dbReview"),text:document.querySelector("#debrief #srRace").innerText,shown:document.querySelectorAll("#debrief button:not([hidden])").length}})()'
  Check "RACE is right next to ANALYSIS (gap $([math]::Round($rg.an.l - $rg.race.r)) px), the same big target ($([math]::Round($rg.race.h)) px high), ANALYSIS has not moved from the right edge ($([math]::Round($rg.an.r)) px; $([math]::Round($pos404.ar)) before), and the saved-laps bar ends before RACE" ($rg.text -eq 'RACE' -and $rg.race.r -le $rg.an.l + 1 -and ($rg.an.l - $rg.race.r) -le 40 -and $rg.race.h -ge 48 -and (Near $rg.an.r $pos404.ar 1.5) -and $rg.bar.r -le $rg.race.l + 1 -and $rg.shown -eq 4)
  $ovRace = Cdp-Json 'SessionReview.overlaps(document.querySelector("#debrief"))'
  Check 'no text overlaps with the RACE button on the review' ($ovRace.bad.Count -eq 0 -and $ovRace.boxes -gt 120)
  Cdp-Shot (Join-Path $shots 'sr-race-button.png')
  Check 'picture tests\shots\sr-race-button.png written' ((Get-Item (Join-Path $shots 'sr-race-button.png')).Length -gt 80000)
  $null = Cdp-Eval "document.querySelector('#debrief #srRace').click(); 1"
  $wb2 = Cdp-Wait "document.querySelector('#wbHost iframe')" 5
  $src2 = Cdp-Eval "(document.querySelector('#wbHost iframe') || {}).getAttribute ? document.querySelector('#wbHost iframe').getAttribute('src') : ''"
  Check 'RACE opens workbench.html on this session''s best lap on the RACE page (page=race), over the review, like ANALYSIS' ($wb2 -and $src2 -eq ('workbench.html?id=' + [uri]::EscapeDataString($pbName) + '&lap=7&ref=' + [uri]::EscapeDataString($midName + ':7') + '&page=race') -and (Cdp-Eval "!!document.querySelector('#debrief.on')") -eq $true)
  Start-Sleep -Milliseconds 700
  $null = Cdp-Eval "document.querySelector('#wbBack').click(); 1"
  Check 'BACK closes it and the review (with RACE) is still there' ((Cdp-Wait "!document.querySelector('#wbHost')" 4) -and (Cdp-Eval "!document.querySelector('#debrief #srRace').hidden") -eq $true)
  Cdp-Close
  # he is driving: irdash answers 503 and nothing appears
  Set-Cfg 503 $runA.path $mapA.path
  Cdp-Open "http://localhost:$port/v2/index.html"
  $null = Cdp-Wait "typeof Debrief !== 'undefined' && typeof SessionReview !== 'undefined'" 25
  $null = Cdp-Eval "Debrief.show($live, false); 1"
  Start-Sleep -Milliseconds 2500
  Check 'while he drives irdash says 503 and the review never appears (nothing on screen, nothing left behind)' ((Cdp-Eval "!document.querySelector('#debrief.on') && !Debrief.el") -eq $true)
  Cdp-Close
  # the session file cannot be read: after one retry the review shows what the dashboard saw live
  Set-Cfg 404 $runA.path $mapA.path
  Cdp-Open "http://localhost:$port/v2/index.html"
  $null = Cdp-Wait "typeof Debrief !== 'undefined' && typeof SessionReview !== 'undefined'" 25
  $null = Cdp-Eval "Debrief.show($live, true); 1"
  $fb = Cdp-Wait "document.querySelector('#debrief.on .sr-tbl')" 12
  $ftxt = Cdp-Eval "document.querySelector('#debrief').innerText"
  Check 'file not readable: the review still comes (the laps he drove, from the live data) with the saved-laps bar' ($fb -and $ftxt -match '1:19\.549' -and $ftxt -match '3 laps saved' -and (Cdp-Eval "document.querySelector('#srAnalysis').hidden") -eq $true)
  Cdp-Close
  # the newest file is OLDER than the stint he just drove (iRacing wrote no file for it): never shown as this session
  Set-Cfg 200 $runA.path $mapA.path
  Cdp-Open "http://localhost:$port/v2/index.html"
  $null = Cdp-Wait "typeof Debrief !== 'undefined' && typeof SessionReview !== 'undefined'" 25
  $liveNew = $live.Replace('startMs:Date.now()-20*24*3600*1000', 'startMs:Date.now()')
  $null = Cdp-Eval "Debrief.show($liveNew, false); 1"
  $st = Cdp-Wait "document.querySelector('#debrief.on .sr-tbl')" 25
  $stxt = Cdp-Eval "document.querySelector('#debrief').innerText"
  Check 'the newest file was written before he got in the car: it is not shown as this session (the laps he drove are, from the live data; no ANALYSIS)' ($st -and $stxt -notmatch '11\.624' -and $stxt -match '1:19\.549' -and (Cdp-Eval "document.querySelector('#srAnalysis').hidden") -eq $true)
  Cdp-Close  # the file is a few laps behind the dashboard (not flushed yet): it waits and retries
  Set-Cfg 200 $runC.path $mapC.path
  Set-Content -LiteralPath $logFile -Value '' -Encoding UTF8
  Cdp-Open "http://localhost:$port/v2/index.html"
  $null = Cdp-Wait "typeof Debrief !== 'undefined' && typeof SessionReview !== 'undefined'" 25
  $null = Cdp-Eval "Debrief.show($live, false); 1"
  $null = Cdp-Wait "document.querySelector('#debrief.on .sr-tbl')" 20
  $nReq = @((Read-Log) | Where-Object { $_ -match '^/analysis/session\?id=last' }).Count
  Check 'the file has fewer laps than the dashboard saw (3 against 7): it asks again a few times, then shows what there is' ($nReq -ge 3 -and (Cdp-Eval "!!document.querySelector('#debrief.on .sr-tbl')") -eq $true)
  Cdp-Close
  # the quick-win checks of tests\quickwins-test.ps1 (it makes them on the real dashboard with offline summaries): same payloads here
  Cdp-Open "http://localhost:$port/v2/index.html"
  $null = Cdp-Wait "typeof Debrief !== 'undefined' && typeof SessionReview !== 'undefined'" 25
  function Qw($payload, $review) {
    $null = Cdp-Eval "Debrief.show($payload, $review); 1"
    $okShow = Cdp-Wait "document.querySelector('#debrief.on .sr-tbl')" 10
    Start-Sleep -Milliseconds 800
    return @{ ok = $okShow; text = (Cdp-Eval "(document.querySelector('#debrief.on') || {}).innerText || ''"); dots = (Cdp-Eval "document.querySelectorAll('#debrief.on svg.chart circle').length"); strip = (Cdp-Eval "!!document.querySelector('#debrief.on #dbReview')"); ov = (Cdp-Json 'SessionReview.overlaps(document.querySelector("#debrief"))') }
  }
  $q1 = Qw "{ type: 'Practice', race: false, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 1, cleanLaps: 1, best: 95.125, times: [{ t: 95.125, clean: true }], inc: 0, mins: 4, offline: true }" 'false'
  Check 'one clean lap: no hint text, never "Very consistent", no chart, no saved-laps strip, no overlaps' ($q1.ok -and $q1.text -notmatch 'Drive 3 clean laps' -and $q1.text -notmatch 'Very consistent' -and $q1.dots -eq 0 -and $q1.strip -eq $false -and $q1.ov.bad.Count -eq 0)
  $q4 = Qw "{ type: 'Practice', race: false, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 4, cleanLaps: 4, best: 95.4, times: [{ t: 95.4, clean: true }, { t: 95.6, clean: true }, { t: 95.8, clean: true }, { t: 96.0, clean: true }], inc: 0, mins: 12, offline: true }" 'false'
  Check 'four clean laps: still no chart (it starts at 5), no notes block, no overlaps' ($q4.ok -and $q4.dots -eq 0 -and $q4.text -notmatch 'No corner differs' -and $q4.ov.bad.Count -eq 0)
  $q5 = Qw "{ type: 'Practice', race: false, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 5, cleanLaps: 5, best: 95.2, times: [{ t: 95.2, clean: true }, { t: 95.4, clean: true }, { t: 95.5, clean: true }, { t: 95.7, clean: true }, { t: 95.9, clean: true }], inc: 1, mins: 15, offline: true }" 'false'
  Check 'five laps: the lap-times chart is there (5 dots)' ($q5.ok -and $q5.dots -eq 5 -and $q5.ov.bad.Count -eq 0)
  $q14 = Qw "{ type: 'Race', race: true, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 14, cleanLaps: 12, best: 95.125, times: (function(){var t=[];for(var i=0;i<14;i++)t.push({t:i===3?95.125:95.5+(i%5)*0.2,clean:i!==1&&i!==8});return t})(), inc: 4, pos0: 8, pos: 2, mins: 28, offline: true }" 'true'
  $null = Cdp-Wait "document.querySelector('#debrief.on #dbReview .db-rev-line') && /KEEP ALL/.test(document.querySelector('#debrief.on #dbReview').textContent)" 8
  Start-Sleep -Milliseconds 300
  $q14.strip = Cdp-Eval "!!document.querySelector('#debrief.on #dbReview')"; $q14.ov = Cdp-Json 'SessionReview.overlaps(document.querySelector("#debrief"))'
  Check 'a race of 14 laps: the chart has 14 dots, the saved-laps strip is inside, the race extras say P8 → P2 +6 · 4 INCIDENTS, no overlaps' ($q14.ok -and $q14.dots -eq 14 -and $q14.strip -eq $true -and (Cdp-Eval "document.querySelector('#debrief').innerText") -match 'P8 → P2 \+6 · 4 INCIDENTS' -and $q14.ov.bad.Count -eq 0)
  Cdp-Close
  # (W6b) the fallback with the REAL core.js: a stint is driven through trackLaps frame by frame, summarise (debrief.js) copies each lap's reason into
  # its rows, and the fallback page says OUT / IN / PIT / OFF only where core.js saw the reason. The old trackLaps is replayed beside it (verbatim) to
  # prove nothing else changed: every lap has the same number, fuel, clean flag, time and moment as before.
  Set-Cfg 200 $runA.path $mapA.path
  Cdp-Open "http://localhost:$port/v2/index.html"
  $null = Cdp-Wait "typeof Debrief !== 'undefined' && typeof SessionReview !== 'undefined' && typeof trackLaps === 'function'" 25
  $stint = @'
(function () {
  window.__old = { laps: [], pending: null, prevLC: null, lapStartFuel: null, lapDirty: true, prevFuel: null };
  window.oldTrack = function (v) {            // trackLaps as it was before W6b (logic copied unchanged)
    var R = window.__old, lc = v.LapCompleted, fuel = v.FuelLevel;
    if (!isNum(lc) || !isNum(fuel)) return;
    if (R.prevFuel != null && fuel > R.prevFuel + 0.2) R.lapDirty = true;
    if (v.OnPitRoad || !v.IsOnTrack) R.lapDirty = true;
    if (R.prevLC === null) { R.prevLC = lc; R.lapStartFuel = fuel; R.lapDirty = true; }
    else if (lc === R.prevLC + 1) {
      var used = R.lapStartFuel - fuel;
      R.pending = { lap: lc, fuel: !R.lapDirty && used > 0.01 ? used : null, clean: !R.lapDirty, at: v.SessionTime };
      R.lapStartFuel = fuel; R.lapDirty = !!v.OnPitRoad; R.prevLC = lc;
    } else if (lc !== R.prevLC) { R.prevLC = lc; R.lapStartFuel = fuel; R.lapDirty = true; }
    if (R.pending && v.SessionTime - R.pending.at > 1.5) { var p = R.pending; R.pending = null; p.time = v.LapLastLapTime > 0 ? v.LapLastLapTime : null; R.laps.push(p); }
    R.prevFuel = fuel;
  };
  resetLive();
  var t = 0, lc = 0, fuel = 60, last = -1;
  function send(o) { var v = { LapCompleted: lc, FuelLevel: fuel, OnPitRoad: false, IsOnTrack: true, LapDistPct: 0.5, SessionTime: t, LapLastLapTime: last }; for (var k in o) v[k] = o[k]; trackLaps(v); window.oldTrack(v); }
  // one lap: frames every 4 % of the lap; pit = [from, to) on pit road, away = [from, to) not on track, refuel = jump in the tank at that point,
  // crossPit = on pit road when the line is crossed, time = the lap time iRacing announces
  function lap(s) {
    for (var i = 0; i < 25; i++) {
      var p = 0.02 + 0.04 * i; t += s.time * 0.04; fuel -= 0.1;
      if (s.refuel && Math.abs(p - s.refuel) < 0.01) fuel += 30;
      send({ LapDistPct: p, OnPitRoad: !!(s.pit && p >= s.pit[0] && p < s.pit[1]) || !!(s.pit2 && p >= s.pit2[0] && p < s.pit2[1]), IsOnTrack: !(s.away && p >= s.away[0] && p < s.away[1]) });
    }
    t += s.time * 0.02; lc++; send({ LapDistPct: 0.002, OnPitRoad: !!s.crossPit }); last = s.time;
  }
  t = 0; send({ LapDistPct: 0.03, OnPitRoad: true });                       // he joins in the pit box
  lap({ time: 85.0, pit: [0, 0.12] });                                       // 1 out lap: from the box to the pit exit
  lap({ time: 80.5 });                                                       // 2 clean
  lap({ time: 81.0, pit: [0.88, 1.0], crossPit: true });                     // 3 in lap: pit entry, the line is crossed in the lane
  lap({ time: 86.0, pit: [0, 0.09] });                                       // 4 out lap: starts in the lane
  lap({ time: 84.0, pit: [0.44, 0.56] });                                    // 5 pit road in the middle of the lap
  lap({ time: 83.0, away: [0.28, 0.42] });                                   // 6 out of the car for a while
  lap({ time: 80.2 });                                                       // 7 clean
  lap({ time: 80.9, refuel: 0.5 });                                          // 8 the tank jumps, no pit road seen
  lap({ time: 88.0, pit: [0, 0.09], pit2: [0.88, 1.0] });                    // 9 pit road at both ends (out of the lane at the line)
  lap({ time: 80.4 });                                                       // 10 clean
  t += 3.4; send({ LapDistPct: 0.02 });                                      // the first frame of the next lap announces lap 10's time
  var key = function (a) { return a.map(function (l) { return JSON.stringify([l.lap, l.fuel, l.clean, l.at, l.time]); }).join(';'); };
  window.__sum = Debrief.summarise({ type: 'Practice', race: false, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', wall0: Date.now() - 900000, t0: 0, inc: 0, inc0: 0, pos0: null, pos: null },
    L.laps.filter(function (l) { return l.at >= 0 && isNum(l.time) && l.time > 0; }));
  return JSON.stringify({ laps: L.laps.map(function (l) { return l.lap + ':' + (l.clean ? 'c' : 'd') + ':' + l.why; }), rows: window.__sum.rows.map(function (r) { return r.n + ':' + (r.clean ? 'c' : 'd') + ':' + r.why; }), same: key(L.laps) === key(window.__old.laps), n: L.laps.length, nOld: window.__old.laps.length });
})()
'@
  $sjRaw = Cdp-Eval $stint; $sj = $null; try { $sj = $sjRaw | ConvertFrom-Json } catch { Note ('stint script said: ' + $sjRaw) }
  if (-not $sj) { $sj = [pscustomobject]@{ laps = @(); rows = @(); same = $false; n = 0; nOld = 0 } }
  Note ('core.js stint: ' + ($sj.laps -join ' '))
  Check 'core.js stores why on each lap it pushes: 1 out, 2 clean (none), 3 in, 4 out, 5 pit, 6 off, 7 clean, 8 pit (tank only), 9 pit (both ends), 10 clean' (($sj.laps -join ',') -eq '1:d:out,2:c:,3:d:in,4:d:out,5:d:pit,6:d:off,7:c:,8:d:pit,9:d:pit,10:c:')
  Check 'nothing else changed in trackLaps: the same 10 laps with the same number, fuel, clean flag, moment and time as the old code gives' ($sj.same -eq $true -and $sj.n -eq 10 -and $sj.nOld -eq 10)
  Check 'summarise (debrief.js) copies each lap''s reason into its rows (the same words, a clean lap has none)' (($sj.rows -join ',') -eq ($sj.laps -join ','))
  $null = Cdp-Eval "Debrief.show(Object.assign({}, window.__sum, { offline: true }), false); 1"
  $okF = Cdp-Wait "document.querySelector('#debrief.on .sr-tbl')" 15
  $fr = Cdp-Json '[].map.call(document.querySelectorAll("#debrief .sr-tbl .sr-row[data-lap]"),function(r){return {n:+r.dataset.lap,grey:r.classList.contains("grey"),gap:r.lastElementChild.textContent.trim()}})'
  Note ('fallback rows on screen: ' + (($fr | ForEach-Object { "lap $($_.n) " + $(if ($_.grey) { 'dim' } else { 'normal' }) + " '$($_.gap)'" }) -join ', '))
  $wanted = @{ 1 = 'OUT'; 3 = 'IN'; 4 = 'OUT'; 5 = 'PIT'; 6 = 'OFF'; 8 = 'PIT'; 9 = 'PIT' }
  $okWords = $okF -and @($fr).Count -eq 10
  foreach ($r in @($fr)) { if ($wanted.ContainsKey([int]$r.n)) { if (-not ($r.grey -and $r.gap -eq $wanted[[int]$r.n])) { $okWords = $false } } elseif ($r.grey -or $r.gap -match '[A-Z]') { $okWords = $false } }
  Check 'the fallback page says OUT for the real out lap (lap 1) and IN / OUT / PIT / OFF where core.js saw the reason; clean laps are not dim and have no word' ($okWords -and $fr[0].gap -eq 'OUT')
  $ovFb = Cdp-Json 'SessionReview.overlaps(document.querySelector("#debrief"))'
  Check 'no text overlaps on that fallback page, and no ANALYSIS / RACE button (there is no file)' ($ovFb.bad.Count -eq 0 -and (Cdp-Eval "document.querySelector('#debrief #srAnalysis').hidden") -eq $true -and (Cdp-Eval "document.querySelector('#debrief #srRace').hidden") -eq $true)
  Check 'no JavaScript exception in the core.js stint' ($script:cdp.errors.Count -eq 0)
  if ($script:cdp.errors.Count) { Note ($script:cdp.errors -join ' / ') }
  Cdp-Close
  # the demo
  Set-Cfg 200 $runA.path $mapA.path
  Cdp-Open "http://localhost:$port/v2/index.html?debrief=demo"
  $dm = Cdp-Wait "document.querySelector('#debrief.on .sr-tbl')" 15
  $dmt = Cdp-Eval "(document.querySelector('#debrief') || {}).innerText || ''"
  if (Test-Path (Join-Path $www 'sr-demo.json')) {
    Check '?debrief=demo shows the saved real session (sr-demo.json): the full review with its map, race extras and no saved-laps strip' ($dm -and $dmt -match '1:19\.549' -and $dmt -match 'P9 → P5' -and $dmt -notmatch 'KEEP ALL' -and (Cdp-Eval "!!document.querySelector('#debrief svg.mapbox')") -eq $true)
  } else { Note 'dash\www\v2\sr-demo.json is not there yet: run this test with -WriteDemo once (the demo then falls back to the live rows)' ; Check '?debrief=demo still shows a review (the fallback, no demo file yet)' ($dm -and $dmt -match '1:24\.3|1:25') }
  Check 'no JavaScript exception on the dashboard' ($script:cdp.errors.Count -eq 0)
  if ($script:cdp.errors.Count) { Note ($script:cdp.errors -join ' / ') }
  Cdp-Close

  Section '7. nothing on screen changed'
  Check 'dash\irdash.exe was not replaced by this test' ((Get-Item -LiteralPath $shipped).LastWriteTimeUtc.Ticks -eq $shippedStamp)
}
finally {
  Cdp-Close
  if ($script:job) { try { Invoke-WebRequest -UseBasicParsing "http://localhost:8742/stop" -TimeoutSec 3 | Out-Null } catch { }; try { Stop-Job $script:job -ErrorAction SilentlyContinue; Remove-Job $script:job -Force -ErrorAction SilentlyContinue } catch { } }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  Assert-RigFree -Where 'done'
}

Write-Host "`nsession-review-test: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
