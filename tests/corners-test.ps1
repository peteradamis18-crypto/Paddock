# Corner model test (WS18, docs\corners.md): the offline copy of Lovely Track Data, which owned tracks have numbered corners,
# the /corners endpoint, corners found in real driving, and the real map.js drawing them in headless Chrome with GitHub blocked.
# Telemetry files are only read. Pictures go to tests\shots as c-*.png. Out of the car only (tests\guard.ps1 enforces it).
#   powershell -ExecutionPolicy Bypass -File tests\corners-test.ps1            (irdash on port 8199 must be the current build)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = if ($env:CORNERS_TEST_API) { $env:CORNERS_TEST_API } else { 'http://localhost:8199' }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Note($what) { "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 30; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
# status code and body of a request that may fail (HttpWebRequest, so the body of a 404 or 503 can be read)
function Get-Raw($path) {
  $rq = [Net.HttpWebRequest]::Create("$api$path"); $rq.Timeout = 30000
  try { $resp = $rq.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { return @{ code = 0; body = $_.Exception.Message } } }
  $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); $b = $sr.ReadToEnd(); $sr.Dispose(); $c = [int]$resp.StatusCode; $resp.Close()
  return @{ code = $c; body = $b }
}function Q($s) { [uri]::EscapeDataString($s) }
function Fake($q) { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 8 }

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }

Add-Type -AssemblyName System.Drawing

# ---- cdp: headless Chrome with the DevTools protocol (no window; GitHub and its raw-file host cannot be reached) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('corners-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9361
  $blocked = '"--host-resolver-rules=MAP raw.githubusercontent.com ~NOTFOUND, MAP github.com ~NOTFOUND, MAP *.github.com ~NOTFOUND"'
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', $blocked, 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = "window.__errs = []; window.addEventListener('error', function (e) { window.__errs.push(String(e.message)); });" }
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
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
# a picture of one rectangle of the page (x, y, w, h in page pixels)
function Cdp-Shot($path, $x, $y, $w, $h) {
  $s = Cdp 'Page.captureScreenshot' @{ format = 'png'; clip = @{ x = $x; y = $y; width = $w; height = $h; scale = 1 } }
  [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data))
}
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
# gold pixels (the corner discs) in a picture
function Gold-Pixels($path) {
  $bmp = New-Object System.Drawing.Bitmap $path; $n = 0
  for ($yy = 0; $yy -lt $bmp.Height; $yy += 1) { for ($xx = 0; $xx -lt $bmp.Width; $xx += 1) { $c = $bmp.GetPixel($xx, $yy); if ($c.R -gt 215 -and $c.G -gt 165 -and $c.G -lt 215 -and $c.B -lt 90) { $n++ } } }
  $bmp.Dispose(); return $n
}
# ---- end cdp ----

# ---- pages: the real map.js (demo field on a real outline) with the internet blocked ----
function Open-Track($name, $id) {
  Cdp-Open "$api/v2/index.html?demo=1&track=$(Q $name)&trackid=$id"
  $st = $null
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 500
    $st = Cdp-Eval "JSON.stringify({ pts: TrackMap.pts ? TrackMap.pts.length : 0, src: TrackInfo.raw ? TrackInfo.raw.source : '', n: TrackInfo.raw ? TrackInfo.raw.turns.length : -1, discs: TrackMap.corners ? TrackMap.corners.discs.length : -1 })"
    if ($st -match '^\{') { $o = $st | ConvertFrom-Json; if ($o.pts -ge 200 -and $o.n -ge 0 -and $o.discs -ge 0) { Start-Sleep -Milliseconds 700; break } }
  }
}
function Pages-Check {
  $cases = @(
    @{ name = 'roadatlanta full'; id = '127'; shot = 'c-roadatlanta-full'; want = 'lovely'; turns = 14 },
    @{ name = 'okayama full'; id = '166'; shot = 'c-okayama-full'; want = 'lovely'; turns = 11 },
    @{ name = 'sebring international'; id = '95'; shot = 'c-sebring-international'; want = 'lovely'; turns = 17 },
    @{ name = 'sonoma long'; id = '98'; shot = 'c-sonoma-long-detected'; want = 'auto'; turns = 0; min = 8 },
    @{ name = 'oxford oval'; id = '990001'; shot = 'c-oxford-oval-from-outline'; want = 'auto'; turns = 4 },
    @{ name = 'phoenix road'; id = '990002'; shot = 'c-phoenix-road-from-outline'; want = 'auto'; turns = 0; min = 6 },
    @{ name = 'monza full'; id = '990003'; shot = 'c-monza-full'; want = 'lovely'; turns = 8 })
  foreach ($c in $cases) {
    Open-Track $c.name $c.id
    $info = (Cdp-Eval "JSON.stringify({ src: TrackInfo.raw.source, n: TrackInfo.raw.turns.length, discs: TrackMap.corners.discs.length, named: TrackMap.corners.names.length, credit: TrackInfo.raw.credit, w: document.getElementById('mapBox').clientWidth, h: document.getElementById('mapBox').clientHeight, gh: performance.getEntriesByType('resource').filter(function (e) { return /github/i.test(e.name); }).length, errs: (window.__errs || []).filter(function (m) { return /Corners|TrackInfo|TrackMap|corners/.test(m); }).length })") | ConvertFrom-Json
    $blocked = Cdp-Eval "fetch('https://raw.githubusercontent.com/Lovely-Sim-Racing/lovely-track-data/main/data/manifest.json').then(function () { return 'reachable'; }).catch(function () { return 'blocked'; })"
    Check "$($c.name): GitHub cannot be reached from this page, yet the corners are there ($($info.n) turns from '$($info.src)')" ($blocked -eq 'blocked' -and $info.src -eq $c.want -and $(if ($c.turns) { $info.n -eq $c.turns } else { $info.n -ge $c.min }))
    Check "$($c.name): the page never asked GitHub for anything, and the corner code raised no errors" ($info.gh -eq 0 -and $info.errs -eq 0)
    Check "$($c.name): every corner has its numbered disc on the map ($($info.discs) discs, $($info.named) with a name beside them)" ($info.discs -eq $info.n -and $info.discs -ge 4)
    $rect = (Cdp-Eval "(function () { var r = document.getElementById('pMap').getBoundingClientRect(); return JSON.stringify([r.left, r.top, r.width, r.height]); })()") | ConvertFrom-Json
    $png = Join-Path $shots ($c.shot + '.png')
    Cdp-Shot $png $rect[0] $rect[1] $rect[2] $rect[3]
    $gold = Gold-Pixels $png
    Check "$($c.name): the picture $($c.shot).png shows gold discs ($gold gold pixels)" ($gold -gt (60 * $info.discs))
    if ($c.name -eq 'roadatlanta full') {
      $at = (Cdp-Eval "JSON.stringify([0.3, 0.99, 0.02].map(function (p) { var a = Corners.at(p); return { t: a.turn ? a.turn.n : 0, nx: a.next.n }; }))") | ConvertFrom-Json
      Check 'Corners.at(): 30 % of the lap is in The Esses (T5) with T6 next; 99 % is in T14 with T1 next (past the line); 2 % is between corners, T1 next' ($at[0].t -eq 5 -and $at[0].nx -eq 6 -and $at[1].t -eq 14 -and $at[1].nx -eq 1 -and $at[2].t -eq 0 -and $at[2].nx -eq 1)
      # the same drawing at the size of the brief's map and of a small card, from the same map.js
      foreach ($z in @(@('c-roadatlanta-large', 1500, 760), @('c-roadatlanta-small', 300, 250))) {
        $null = Cdp-Eval "(function () { S.drivers = new Map(); var old = document.getElementById('bigmap'); if (old) old.remove(); var c = document.createElement('canvas'); c.id = 'bigmap'; c.style.cssText = 'position:fixed;left:0;top:0;width:$($z[1])px;height:$($z[2])px;z-index:99999;background:#030405'; document.body.appendChild(c); TrackMap.draw(c, $($z[1]), $($z[2])); return 1; })()"
        Start-Sleep -Milliseconds 300
        $png2 = Join-Path $shots ($z[0] + '.png'); Cdp-Shot $png2 0 0 $z[1] $z[2]
        $g2 = Gold-Pixels $png2
        Check "$($z[0]).png: $($z[1]) x $($z[2]) px, discs drawn ($g2 gold pixels)" ($g2 -gt 250)
      }
    }
    if ($c.name -eq 'okayama full') {
      # a page with its own outline drawing (like the brief) gives Corners.draw its own projection of TrackMap.at(pct)
      $null = Cdp-Eval "(function () { S.drivers = new Map(); var old = document.getElementById('bigmap'); if (old) old.remove(); var w = 1000, h = 520, pts = TrackMap.pts, x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9; pts.forEach(function (p) { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[0]); y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); }); var pad = 80, tw = x1 - x0, th = y1 - y0, sA = Math.min((w - 2 * pad) / tw, (h - 2 * pad) / th), sB = Math.min((w - 2 * pad) / th, (h - 2 * pad) / tw), rot = sB > sA * 1.08, s = rot ? sB : sA; var sc = function (p) { var x = (p[0] - (x0 + x1) / 2) * s, y = -(p[1] - (y0 + y1) / 2) * s; if (rot) { var t = x; x = -y; y = t; } return [w / 2 + x, h / 2 + y]; }; var c = document.createElement('canvas'); c.id = 'bigmap'; c.width = w; c.height = h; c.style.cssText = 'position:fixed;left:0;top:0;width:' + w + 'px;height:' + h + 'px;z-index:99999;background:#030405'; document.body.appendChild(c); var g = c.getContext('2d'); g.lineJoin = 'round'; g.beginPath(); pts.forEach(function (p, i) { var q = sc(p); if (i) g.lineTo(q[0], q[1]); else g.moveTo(q[0], q[1]); }); g.closePath(); g.strokeStyle = '#171715'; g.lineWidth = 30; g.stroke(); g.strokeStyle = '#4a4740'; g.lineWidth = 11; g.stroke(); window.__r = Corners.draw(g, function (pct) { return sc(TrackMap.at(pct)); }, { data: TrackInfo.raw, w: w, h: h, ticks: false, credit: false }); return 1; })()"
      Start-Sleep -Milliseconds 300
      $png4 = Join-Path $shots 'c-okayama-brief-style.png'; Cdp-Shot $png4 0 0 1000 520
      $nd = Cdp-Eval "window.__r.discs.length"
      Check "c-okayama-brief-style.png: a page with its own projection draws all $nd discs the same way ($(Gold-Pixels $png4) gold pixels)" ($nd -eq 11 -and (Gold-Pixels $png4) -gt 700)
    }
    if ($c.name -eq 'sebring international') {
      $null = Cdp-Eval "(function () { S.drivers = new Map(); var old = document.getElementById('bigmap'); if (old) old.remove(); var c = document.createElement('canvas'); c.id = 'bigmap'; c.style.cssText = 'position:fixed;left:0;top:0;width:1500px;height:760px;z-index:99999;background:#030405'; document.body.appendChild(c); TrackMap.draw(c, 1500, 760); return 1; })()"
      Start-Sleep -Milliseconds 300
      $png3 = Join-Path $shots 'c-sebring-large.png'; Cdp-Shot $png3 0 0 1500 760
      Check 'c-sebring-large.png: 17 corners, several with real names, drawn big' ((Gold-Pixels $png3) -gt 1500)
    }
    Cdp-Close
  }
}
# ---- end pages ----

# the deploy lock: nobody rebuilds irdash while this test needs it (same rule as the other tests)
Enter-TestLock 'corners'   # one live test at a time (tests\guard.ps1); released in finally
$lock = Join-Path $root 'dash\deploy.lock'
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Set-Content $lock ('corners ' + (Get-Date).ToString('HH:mm:ss'))
$hook = Join-Path $root 'dash\test-hook.on'
$logN = (Get-Content (Join-Path $root 'dash\irdash.log') | Measure-Object).Count
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$big = 'chevyvettez06rgt3_roadatlanta full 2026-10-09 10-28-32.ibt'      # 11 laps at Road Atlanta
$lovelyDir = Join-Path $root 'data\corners\lovely'; $autoDir = Join-Path $root 'data\corners\auto'
'Corner model test'
try {

Section '1. the offline copy of Lovely Track Data'
$idx = Get-Content (Join-Path $lovelyDir 'index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$files = @(Get-ChildItem $lovelyDir -Filter *.json | Where-Object { $_.Name -ne 'index.json' })
$bad = @($files | Where-Object { try { $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; -not $j.trackId } catch { $true } })
$kb = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1KB, 1)
Check "$($files.Count) Lovely files are kept on this PC ($kb KB), every one valid JSON for a track" ($files.Count -ge 80 -and $bad.Count -eq 0)
Check 'the index lists every iRacing track in Lovely''s manifest and says which are kept' (@($idx.tracks).Count -ge 130 -and @($idx.tracks | Where-Object { $_.folder }).Count -eq $files.Count)
$readme = Get-Content (Join-Path $lovelyDir 'README.txt') -Raw
Check 'the credit and licence note is kept with them (CC BY-NC-SA 4.0, source, no edits)' ($readme -match 'CC BY-NC-SA 4\.0' -and $readme -match 'Lovely-Sim-Racing/lovely-track-data' -and $readme -match 'Lovely Sim Racing')
$ra = Get-Content (Join-Path $lovelyDir 'roadatlanta-full.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'Road Atlanta is the file as published: 14 corner entries, pit lane 0.94 / 0.131' (@($ra.turn).Count -eq 14 -and $ra.pitentry -eq 0.94 -and $ra.pitexit -eq 0.131)

Section '1b. the SIMRacingApps outline copies (Peter said yes to these, 2026-10-10)'
$libDir = Join-Path $root 'data\corners\library'
$lib = @(Get-ChildItem $libDir -Filter *.json)
$libBad = @($lib | Where-Object { $x = [IO.File]::ReadAllText($_.FullName); -not ($x -match 'Apache License 2\.0' -and $x -match 'Jeffrey Gilliam' -and [regex]::Matches($x, '"\d+(\.\d+)?"\s*:\s*\{\s*"Latitude"').Count -ge 300) })
Check "$($lib.Count) outline copies kept ($([math]::Round(($lib | Measure-Object Length -Sum).Sum / 1MB, 2)) MB), each a lap-keyed outline with the Apache licence and credit in it" ($lib.Count -ge 14 -and $libBad.Count -eq 0)
$libReadme = Get-Content (Join-Path $libDir 'README.txt') -Raw
Check 'their README gives the source, the Apache 2.0 licence and the credit' ($libReadme -match 'Apache License 2\.0' -and $libReadme -match 'Jeffrey Gilliam' -and $libReadme -match 'SIMRacingApps')
$tm = Get-Raw '/trackmap?key=t990001-oxford-oval&id=990001&name=oxford%20oval'
$tmj = if ($tm.code -eq 200) { $tm.body | ConvertFrom-Json } else { $null }
Check 'irdash''s map reads the local copy with no internet (oxford oval: 720 points, source library, a closed loop)' ($tm.code -eq 200 -and $tmj.source -eq 'library' -and @($tmj.pts).Count -eq 720 -and ([math]::Abs($tmj.pts[0][0] - $tmj.pts[719][0]) + [math]::Abs($tmj.pts[0][1] - $tmj.pts[719][1])) -lt 40)

Section '2. the endpoint'
$r = J ('/corners?track=' + (Q 'roadatlanta full') + '&config=' + (Q 'Full Course') + '&id=127&key=t127-roadatlanta-full')
Check 'Road Atlanta answers from the local copy: source lovely, 14 turns, the credit line' ($r.source -eq 'lovely' -and @($r.turns).Count -eq 14 -and $r.credit -match 'Lovely Track Data.*CC BY-NC-SA 4\.0' -and $r.lovely -eq 'roadatlanta-full.json')
$t = @($r.turns)
$okShape = $true; $prev = -1
foreach ($x in $t) {
  foreach ($f in 'n', 'name', 'pct0', 'pctApex', 'pct1', 'source') { if ($x.PSObject.Properties.Name -notcontains $f) { $okShape = $false } }
  if ($x.pctApex -le $prev) { $okShape = $false }; $prev = $x.pctApex
  $in = if ($x.pct1 -ge $x.pct0) { $x.pctApex -ge $x.pct0 - 0.001 -and $x.pctApex -le $x.pct1 + 0.001 } else { $x.pctApex -ge $x.pct0 -or $x.pctApex -le $x.pct1 }
  if (-not $in) { $okShape = $false }
}
Check 'each turn has n, name, pct0, pctApex, pct1 and source; the apex lies inside its stretch; the list runs in lap order' ($okShape -and (@($t | ForEach-Object { $_.n }) -join ',') -eq (1..14 -join ','))
Check 'numbers are lap order: The Esses is T5, and "Turn 5" (the circuit''s own number) is T6 with official=5' ($t[4].name -eq 'The Esses' -and $t[5].name -eq '' -and $t[5].official -eq '5' -and $t[10].official -eq '10A')
Check 'pit lane and sectors: pit in 0.94, pit out 0.131, four sectors starting at the line' (Near $r.pitIn 0.94 0.0001 -and (Near $r.pitOut 0.131 0.0001) -and @($r.sectors).Count -eq 4 -and $r.sectors[0] -eq 0 -and $r.sf -eq 0)
Check 'with an outline on file the dot goes to the tightest point of Lovely''s stretch (not always the middle)' (@($t | Where-Object { [math]::Abs($_.pctApex - ($_.pct0 + $(if ($_.pct1 -ge $_.pct0) { $_.pct1 - $_.pct0 } else { $_.pct1 + 1 - $_.pct0 }) / 2)) -gt 0.002 }).Count -ge 3)
$o = J ('/corners?track=' + (Q 'Road Atlanta') + '&config=' + (Q 'Full Course'))
Check 'asking by the display name and layout (no id, no key) finds Road Atlanta too' ($o.source -eq 'lovely' -and @($o.turns).Count -eq 14 -and $o.turns[4].name -eq 'The Esses')
$ok = J ('/corners?track=' + (Q 'okayama full') + '&id=166')
Check 'Okayama: 11 turns, "First Corner" is T1, "Last Corner" is T11' ($ok.source -eq 'lovely' -and @($ok.turns).Count -eq 11 -and $ok.turns[0].name -eq 'First Corner' -and $ok.turns[10].name -eq 'Last Corner')
$dy = J ('/corners?track=' + (Q 'daytona 2011 road'))
Check 'files that give each corner as one marker (Daytona, Long Beach) work too: 12 numbered corners' ($dy.source -eq 'lovely' -and @($dy.turns).Count -eq 12 -and $dy.turns[0].n -eq 1 -and $dy.turns[11].n -eq 12)
$s = J ('/corners?track=' + (Q 'sebring international') + '&id=95')
Check 'Sebring: "Turn One" and "T3" become official numbers; "Gurney Bend" is a name' ($s.turns[0].name -eq '' -and $s.turns[0].official -eq '1' -and $s.turns[2].official -eq '3' -and $s.turns[5].name -eq 'Gurney Bend')
$n = J ('/corners?track=' + (Q 'navarra speedmedium'))
Check 'a layout whose first word is misspelt in Lovely''s own data still matches (navara), and one with no corner list is not an error' ($n.lovelyListed -eq $true -and @($n.turns).Count -eq 0 -and $n.source -eq 'none')
$tk = J ('/corners?track=' + (Q 'tsukuba 1kfull'))
Check '1k and 2k Tsukuba are not mixed up: a name one letter apart matches only itself' ((J ('/corners?track=' + (Q 'tsukuba 2kfull'))).lovely -eq 'tsukuba-2kfull.json' -and $tk.lovely -eq 'tsukuba-1kfull.json')
$u = J ('/corners?track=' + (Q 'madeup nowhere') + '&id=99999')
Check 'a track nobody has data for answers source none with an empty list (the map then shows the outline only)' ($u.source -eq 'none' -and @($u.turns).Count -eq 0 -and $u.credit -eq '')
$ov = J ('/corners?track=' + (Q 'oxford oval') + '&id=990001&key=t990001-oxford-oval')
$ovA = @($ov.turns | ForEach-Object { $_.pctApex })
$ovGaps = if ($ovA.Count -eq 4) { @(0..3 | ForEach-Object { $d = $ovA[($_ + 1) % 4] - $ovA[$_]; if ($d -lt 0) { $d += 1 }; $d }) } else { @(9) }
Check 'an oval (no Lovely list) is found from its outline as four turns, T1-T4, about a quarter of a lap apart, no names, no credit line' ($ov.source -eq 'auto' -and $ov.basis -eq 'outline' -and @($ov.turns).Count -eq 4 -and @($ov.turns | Where-Object { $_.name -ne '' }).Count -eq 0 -and $ov.credit -eq '' -and $ov.detail -match 'SIMRacingApps' -and @($ovGaps | Where-Object { $_ -lt 0.15 -or $_ -gt 0.4 }).Count -eq 0)
$ph = J ('/corners?track=' + (Q 'phoenix road') + '&id=990002&key=t990002-phoenix-road')
Check 'a road course with no Lovely list is numbered 1..n from the shape of its outline, marked auto / outline' ($ph.source -eq 'auto' -and $ph.basis -eq 'outline' -and @($ph.turns).Count -ge 6 -and (@($ph.turns | ForEach-Object { $_.n }) -join ',') -eq (1..@($ph.turns).Count -join ','))
Check 'where Lovely has the corners it still wins over the outline (Monza: 8 turns, Prima Variante first)' ((J ('/corners?track=' + (Q 'monza full'))).source -eq 'lovely' -and (J ('/corners?track=' + (Q 'monza full'))).turns[0].name -eq 'Prima Variante')
Check 'rubbish in the query is harmless' ((Get-Raw ('/corners?track=' + (Q ('x' * 400)) + '&key=..\..\x&id=abc')).code -eq 200)
Check 'the detection dry run refuses names that are not telemetry files' ((Get-Raw '/corners/detect?file=..\..\Windows\win.ini').code -eq 404 -and (Get-Raw '/corners/detect').code -eq 404)

Section '3. corners found in real driving (Road Atlanta, 11 laps, compared with Lovely)'
$d = J ('/corners/detect?file=' + (Q $big))
$cnt = @($d.turns).Count
Check "the best clean lap gives a believable number of corners for Road Atlanta: $cnt (Lovely lists 14, the circuit has 12)" ($cnt -ge 10 -and $cnt -le 18)
Check 'numbered 1..n in lap order, apexes rising' ((@($d.turns | ForEach-Object { $_.n }) -join ',') -eq (1..$cnt -join ',') -and (@($d.turns | ForEach-Object { $_.pctApex }) | Sort-Object { [double]$_ }) -join ',' -eq (@($d.turns | ForEach-Object { $_.pctApex }) -join ','))
# the same lap time found independently, straight from the file (LapLastLapTime changes when iRacing announces a lap)
function Ibt-Best($file) {
  $b = [IO.File]::ReadAllBytes($file)
  $bl = [BitConverter]::ToInt32($b, 36); $bo = [BitConverter]::ToInt32($b, 52); $rc = [BitConverter]::ToInt32($b, 140); $nv = [BitConverter]::ToInt32($b, 24); $vho = [BitConverter]::ToInt32($b, 28)
  $vars = @{}; for ($i = 0; $i -lt $nv; $i++) { $p = $vho + 144 * $i; $vars[[Text.Encoding]::ASCII.GetString($b, $p + 16, 32).Trim([char]0)] = [BitConverter]::ToInt32($b, $p + 4) }
  $oL = $vars['LapLastLapTime']; $oOn = $vars['IsOnTrack']; $oP = $vars['OnPitRoad']; $prev = -999.0; $best = 9999.0
  for ($r = 0; $r -lt $rc; $r++) {
    $base = $bo + $r * $bl; if ($b[$base + $oOn] -eq 0) { continue }
    $v = [double][BitConverter]::ToSingle($b, $base + $oL)
    if ($prev -gt -900 -and $v -gt 15 -and [math]::Abs($v - $prev) -gt 0.0005 -and $v -lt $best) { $best = $v }
    $prev = $v
  }
  return $best
}
$hand = Ibt-Best (Join-Path $tel $big)
Check "the lap it used ($($d.lapTime) s, lap $($d.lap)) is the file's quickest lap by hand ($([math]::Round($hand, 3)) s)" (Near $d.lapTime $hand 0.003)
$lov = @($r.turns); $hit = 0; $order = $true; $last = -1
foreach ($lt in $lov) {
  $m = @($d.turns | Where-Object { $a = $_.pctApex; if ($lt.pct1 -ge $lt.pct0) { $a -ge $lt.pct0 - 0.012 -and $a -le $lt.pct1 + 0.012 } else { $a -ge $lt.pct0 - 0.012 -or $a -le $lt.pct1 + 0.012 } })
  if ($m.Count -gt 0) { $hit++; if ($m[0].n -lt $last) { $order = $false }; $last = $m[0].n }
}
Check "Lovely's order is kept: $hit of 14 Lovely stretches hold a detected apex, and they come in the same order" ($hit -ge 11 -and $order)
$nl = Get-Raw ('/corners/detect?file=' + (Q 'bmwm4evogt4_okayama full 2026-10-09 22-50-16.ibt'))
Check 'a file with no full clean lap says so plainly instead of guessing' ($nl.code -eq 404 -and $nl.body -match 'no clean full lap')
Check 'a lap number that is not a number is refused' ((Get-Raw ('/corners/detect?file=' + (Q $big) + '&lap=abc')).code -eq 400)

Section '4. a track Lovely has no corners for (Sonoma Long): found from the outline irdash holds'
$autoFile = Join-Path $autoDir 't98-sonoma-long.json'
$b1 = J '/corners?track=sonoma%20long&id=98&build=1'
Check "built from his own data: source auto, basis $($b1.basis), $(@($b1.turns).Count) corners numbered 1..n" ($b1.source -eq 'auto' -and @($b1.turns).Count -ge 8 -and (@($b1.turns | ForEach-Object { $_.n }) -join ',') -eq (1..@($b1.turns).Count -join ','))
Check 'the result is kept in data\corners\auto\t98-sonoma-long.json and asking again gives the same list' ((Test-Path $autoFile) -and (J '/corners?track=sonoma%20long&id=98').turns.Count -eq @($b1.turns).Count)
Check 'there is no credit line for corners we found ourselves' ($b1.credit -eq '')
$ra2 = J '/corners?track=roadatlanta%20full&id=127&build=1'
Check 'Lovely wins where both exist: asking for a build at Road Atlanta keeps Lovely''s list and writes no auto file' ($ra2.source -eq 'lovely' -and -not (Test-Path (Join-Path $autoDir 't127-roadatlanta-full.json')))

Section '5. coverage of the 43 owned tracks'
$au = J '/corners/audit'
$rows = @($au.layouts); $inst = @($rows | Where-Object { $_.installed })
$tracksOwned = @(Get-ChildItem $au.tracksDir -Directory | ForEach-Object { $_.Name.ToLowerInvariant() })
Check "$($tracksOwned.Count) track folders are installed and every one is in the list" ($tracksOwned.Count -eq 43 -and @($inst | Group-Object folder).Count -eq $tracksOwned.Count)
$covered = @(); $uncovered = @()
foreach ($f in $tracksOwned) {
  $mine = @($inst | Where-Object { $_.folder -eq $f })
  if (@($mine | Where-Object { $_.lovelyTurns -gt 0 -or $_.autoTurns -gt 0 -or $_.libTurns -gt 0 }).Count -gt 0) { $covered += $f } else { $uncovered += $f }
}
Note "$($covered.Count) of 43 owned tracks have numbered corners on at least one layout (Lovely, found in his laps, or found from the shape of the outline copy)"
Note ("no corner list: never driven, Lovely has none and there is no outline copy: " + ($uncovered -join ', '))
$drivenRows = @($rows | Where-Object { $_.driven -gt 0 })
$drivenNo = @($drivenRows | Where-Object { $_.lovelyTurns -le 0 -and $_.autoTurns -le 0 -and $_.libTurns -le 0 })
Check "every layout he has driven has numbered corners ($(@($drivenRows).Count) layouts: $((@($drivenRows | ForEach-Object { $_.id }) -join ', ')))" ($drivenRows.Count -ge 5 -and $drivenNo.Count -eq 0)
Check 'a track without corner numbers is one he has not driven (on its installed layouts) and Lovely has no corner names for' (@($uncovered | Where-Object { $f = $_; @($inst | Where-Object { $_.folder -eq $f -and ($_.driven -gt 0 -or $_.lovelyTurns -gt 0 -or $_.libTurns -gt 0) }).Count -gt 0 }).Count -eq 0)
Check 'most of them are covered (the rest are listed above, with the reason)' ($covered.Count -ge 30)

Section '6. the real map.js with the internet blocked'
Pages-Check

Section '7. nothing is read while you drive'
Set-Content $hook 'on for the test'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/session?file=$(Q $big)" -TimeoutSec 8
Fake 'IsOnTrack=1&OnPitRoad=0&SessionNum=2&PlayerCarIdx=0&Lap=4&LapDistPct=0.4&Speed=45&Gear=4&SessionFlags=0'
Start-Sleep -Milliseconds 2600
Check 'the detection dry run is refused while driving (HTTP 503)' ((Get-Raw ('/corners/detect?file=' + (Q $big))).code -eq 503)
Check 'so is building and the coverage list' ((Get-Raw '/corners?track=sonoma%20long&id=98&build=1').code -eq 503 -and (Get-Raw '/corners/audit').code -eq 503)
Check 'but the corner list itself still answers (it only reads small files)' ((Get-Raw '/corners?track=roadatlanta%20full&id=127').code -eq 200)
Fake 'IsOnTrack=0&Speed=0'; Start-Sleep -Milliseconds 800

Section '8. the log'
$log = @(Get-Content (Join-Path $root 'dash\irdash.log') | Select-Object -Skip $logN)
Check 'irdash logged what it did with "corners:" lines (and nothing failed)' (@($log | Where-Object { $_ -match 'corners: ' }).Count -ge 1 -and @($log | Where-Object { $_ -match 'corners: .*(failed|Exception)' }).Count -eq 0)

} finally {
  Cdp-Close
  # the made-up track ids of this test (990001 ...) leave nothing behind
  Get-ChildItem (Join-Path $root 'dash\maps') -Filter 't99000*.json' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
  Get-ChildItem $autoDir -Filter 't99000*.json' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 } catch { }
  Remove-Item $hook -ErrorAction SilentlyContinue
  Remove-Item $lock -ErrorAction SilentlyContinue
  Exit-TestLock
}
"`n$pass ok, $fail FAIL"
if ($fail) { exit 1 }
