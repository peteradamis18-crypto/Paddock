# C-29 quick wins: no dead Cosworth button, no clip wording without a video, one card per lap,
# no comparison against the lap itself, and a debrief whose text does not overlap at 1920x1080.
# Headless Chrome, real irdash, scratch vault only. Pictures: tests\shots\qw-*.png.
#   powershell -ExecutionPolicy Bypass -File tests\quickwins-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = if ($env:VAULT_TEST_API) { $env:VAULT_TEST_API } else { 'http://localhost:8199' }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 600; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Qs($s) { [uri]::EscapeDataString([string]$s) }

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; Write-Host ''; Write-Host $title }

function Count-Cards($moments) {
  $seen = @{}
  $n = 0
  foreach ($m in @($moments)) {
    $lapN = 0; if ($m.lap) { $lapN = [int]$m.lap }
    $k = ''
    if ("$($m.kind)" -ne 'race' -and $lapN -gt 0 -and "$($m.session)") { $k = "$($m.session)|$lapN" }
    if ($k) { if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true }
    $n++
  }
  return $n
}

$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('qw-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9393
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--autoplay-policy=no-user-gesture-required', 'about:blank') -PassThru -WindowStyle Hidden
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
function Cdp-Shot($path) {
  $s = Cdp 'Page.captureScreenshot' @{ format = 'png'; clip = @{ x = 0; y = 0; width = 1920; height = 1080; scale = 1 } }
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
function Wait-Page($expr, $secs = 30) { for ($i = 0; $i -lt ($secs * 4); $i++) { $v = Cdp-Eval $expr; if ($v -eq $true) { return $true }; Start-Sleep -Milliseconds 250 }; return $false }

Enter-TestLock 'quickwins'   # one live test at a time (tests\guard.ps1); released in finally
$lock = Join-Path $root 'dash\deploy.lock'
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Set-Content $lock ('quickwins ' + (Get-Date).ToString('HH:mm:ss'))
$hook = Join-Path $root 'dash\test-hook.on'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$tdir = Join-Path $root 'vault-test'; $src = Join-Path $tdir 'src'; $nv = Join-Path $tdir 'nvidia'
$ffmpeg = Join-Path $root 'vault\bin\ffmpeg.exe'
$epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
$fA = 'chevyvettez06rgt3_roadatlanta full 2026-10-09 14-58-37.ibt'
$fB = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'

'Quick wins'
try {
Set-Content $hook 'quickwins test'

Section '1. debrief: chart, empty state, no overlaps'
Check 'Chrome is on this PC' (Test-Path $chrome)
if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force }
$null = J '/vault/test/sandbox?on=1&reset=1'
Cdp-Open "$api/v2/index.html"
$up = Wait-Page "(typeof Debrief !== 'undefined' && !!Debrief.show)" 20
Check 'the debrief script is on the real dashboard' $up
$null = Cdp-Eval @'
window.__qwOverlap = function () {
  var root = document.querySelector('#debrief.on');
  if (!root) return JSON.stringify({ n: -1, pairs: 'no debrief' });
  function hidden(el) {
    if (!el || el.hidden) return true;
    var s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return true;
    return false;
  }
  var nodes = [], all = root.querySelectorAll('*');
  for (var i = 0; i < all.length; i++) {
    var el = all[i], p = el, hide = false;
    while (p && p !== root) { if (hidden(p)) { hide = true; break; } p = p.parentElement; }
    if (hide || hidden(el)) continue;
    var has = false;
    for (var c = el.firstChild; c; c = c.nextSibling) { if (c.nodeType === 3 && c.nodeValue.replace(/\s/g, '').length) { has = true; break; } }
    if (!has) continue;
    var r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;
    nodes.push({ t: (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 42), x: r.left, y: r.top, w: r.width, h: r.height });
  }
  var pairs = [];
  for (var a = 0; a < nodes.length; a++) for (var b = a + 1; b < nodes.length; b++) {
    var A = nodes[a], B = nodes[b];
    var iw = Math.min(A.x + A.w, B.x + B.w) - Math.max(A.x, B.x);
    var ih = Math.min(A.y + A.h, B.y + B.h) - Math.max(A.y, B.y);
    if (iw <= 2 || ih <= 2) continue;
    var Ac = A.x >= B.x - 2 && A.y >= B.y - 2 && A.x + A.w <= B.x + B.w + 2 && A.y + A.h <= B.y + B.h + 2;
    var Bc = B.x >= A.x - 2 && B.y >= A.y - 2 && B.x + B.w <= A.x + A.w + 2 && B.y + B.h <= A.y + A.h + 2;
    if (Ac || Bc) continue;
    pairs.push(A.t + ' ~ ' + B.t);
  }
  return JSON.stringify({ n: pairs.length, pairs: pairs.slice(0, 6).join(' || ') });
};
'ready'
'@

function Show-Debrief($js) {
  $shown = Cdp-Eval $js
  Start-Sleep -Milliseconds 900
  $on = Wait-Page "!!document.querySelector('#debrief.on')" 8
  return ($shown -eq 'shown' -and $on)
}
function Overlap-Count {
  $raw = Cdp-Eval 'window.__qwOverlap()'
  if (-not $raw -or "$raw" -like 'js error*') { return @{ n = -1; pairs = "$raw" } }
  return ($raw | ConvertFrom-Json)
}

$one = Show-Debrief @'
(function () {
  Debrief.show({ type: 'Practice', race: false, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 1, cleanLaps: 1, best: 95.125, opt: 94.9, sd: null, mean: 95.125, times: [{ t: 95.125, clean: true }], inc: 0, pos0: null, pos: null, mins: 4, loss: [{ name: 'T1', lost: 0.22, best: 3.1 }], offline: true }, false);
  return 'shown';
})()
'@
Start-Sleep -Milliseconds 200
$oneText = Cdp-Eval "(document.querySelector('#debrief.on') || {}).innerText || ''"
$oneChart = Cdp-Eval "!!document.querySelector('#debrief.on svg.chart')"
$oneRev = Cdp-Eval "!!document.querySelector('#debrief.on #dbReview')"
$ov1 = Overlap-Count
Check 'one clean lap: no lap-times chart' (($one) -and ("$oneChart" -eq 'False'))
Check 'one clean lap has no hint text and no notes block, and does not claim the lap was consistent' (($oneText -notmatch 'Drive 3 clean laps') -and ($oneText -notmatch 'against next best') -and ($oneText -notmatch 'Very consistent'))
Check 'one clean lap has no saved-laps strip' ("$oneRev" -eq 'False')
Check "one clean lap: $($ov1.n) overlapping text boxes" ($ov1.n -eq 0)
if ($ov1.n -ne 0) { Note ("overlaps: " + $ov1.pairs) }
Cdp-Shot (Join-Path $shots 'qw-debrief-1lap.png')
Check 'qw-debrief-1lap.png saved' (Test-Path (Join-Path $shots 'qw-debrief-1lap.png'))

$four = Show-Debrief @'
(function () {
  Debrief.show({ type: 'Practice', race: false, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 4, cleanLaps: 4, best: 95.4, opt: null, sd: 0.2, mean: 95.7, times: [{ t: 95.4, clean: true }, { t: 95.6, clean: true }, { t: 95.8, clean: true }, { t: 96.0, clean: true }], inc: 0, pos0: null, pos: null, mins: 12, loss: [], offline: true }, false);
  return 'shown';
})()
'@
$fourText = Cdp-Eval "(document.querySelector('#debrief.on') || {}).innerText || ''"
$fourChart = Cdp-Eval "!!document.querySelector('#debrief.on svg.chart')"
$ov4 = Overlap-Count
Check 'four laps: still no chart (it starts at 5)' (($four) -and ("$fourChart" -eq 'False'))
Check 'four clean laps with nothing to point at show no notes block and no made-up corner (Session Review, C-40)' ($fourText -notmatch 'No corner differs' -and $fourText -notmatch 'Lap \d+ against')
Check "four laps: $($ov4.n) overlapping text boxes" ($ov4.n -eq 0)
if ($ov4.n -ne 0) { Note ("overlaps: " + $ov4.pairs) }

$five = Show-Debrief @'
(function () {
  Debrief.show({ type: 'Practice', race: false, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 5, cleanLaps: 5, best: 95.2, opt: null, sd: 0.18, mean: 95.5, times: [{ t: 95.2, clean: true }, { t: 95.4, clean: true }, { t: 95.5, clean: true }, { t: 95.7, clean: true }, { t: 95.9, clean: true }], inc: 1, pos0: null, pos: null, mins: 15, loss: [], offline: true }, false);
  return 'shown';
})()
'@
$fiveBars = Cdp-Eval "document.querySelectorAll('#debrief.on svg.chart circle').length"
Check 'five laps: the lap-times chart is there (5 dots)' (($five) -and ("$fiveBars" -eq '5'))

Section '2. debrief after a race, with the saved-laps strip'
$null = J ('/vault/test/wheel?op=seed&secs=30&laps=' + (Qs '14|95.125|PB;9|95.4|top 6%;7|96.1|best 3'))
$race = Show-Debrief @'
(function () {
  var times = [];
  for (var i = 0; i < 14; i++) times.push({ t: i === 3 ? 95.125 : 95.5 + (i % 5) * 0.2, clean: i !== 1 && i !== 8 });
  Debrief.show({ type: 'Race', race: true, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 14, cleanLaps: 12, best: 95.125, opt: 94.802, sd: 0.41, mean: 96.2, times: times, inc: 4, pos0: 8, pos: 2, mins: 28, loss: [{ name: 'T10a', lost: 0.18, best: 4.21 }, { name: 'T1', lost: 0.09, best: 3.14 }, { name: 'The long left before the bridge', lost: 0.07, best: 5.44 }], offline: true }, true);
  return 'shown';
})()
'@
$rev = Wait-Page "(function(){var d=document.querySelector('#debrief.on'),r=document.getElementById('dbReview');return !!(d&&r&&d.contains(r)&&/KEEP ALL/.test(r.textContent));})()" 12
Start-Sleep -Milliseconds 400
$ovR = Overlap-Count
$raceChart = Cdp-Eval "document.querySelectorAll('#debrief.on svg.chart circle').length"
$errs = Cdp-Eval "(window.__errs || []).length"
Check 'the race debrief shows the lap chart and the saved-laps strip' (($race) -and ($rev) -and ("$raceChart" -eq '14'))
Check "race debrief: $($ovR.n) overlapping text boxes, $errs script errors" (($ovR.n -eq 0) -and ("$errs" -eq '0'))
if ($ovR.n -ne 0) { Note ("overlaps: " + $ovR.pairs) }
Cdp-Shot (Join-Path $shots 'qw-debrief-race.png')
Check 'qw-debrief-race.png saved' (Test-Path (Join-Path $shots 'qw-debrief-race.png'))
$null = J '/vault/test/wheel?op=seed&clear=1'

# W4-5: sections 3 to 5 tested the Vault page (vault.html), which is gone: RACES is the door now (tests\races-page-test.ps1).
Section '6. Performance says which page it is and its headline number (P0-06)'
# P0-06: Peter opens each from HOME; the top 160 px must say which one it is and its headline number, and the two
# tops must not look alike. The old pictures (qw-*-old.png) were taken before the change; the new ones here.
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class QwPix {
  public static double TopDiff(string a, string b, int hTop) {
    using (var ia = new Bitmap(a)) using (var ib = new Bitmap(b)) {
      int w = Math.Min(ia.Width, ib.Width), h = Math.Min(hTop, Math.Min(ia.Height, ib.Height));
      var r = new Rectangle(0, 0, w, h); var f = PixelFormat.Format24bppRgb;
      var da = ia.LockBits(r, ImageLockMode.ReadOnly, f); var db = ib.LockBits(r, ImageLockMode.ReadOnly, f);
      byte[] ba = new byte[da.Stride * h]; byte[] bb = new byte[db.Stride * h];
      Marshal.Copy(da.Scan0, ba, 0, ba.Length); Marshal.Copy(db.Scan0, bb, 0, bb.Length);
      ia.UnlockBits(da); ib.UnlockBits(db);
      long n = 0, d = 0;
      for (int y = 0; y < h; y++) { int ra = y * da.Stride, rb = y * db.Stride;
        for (int x = 0; x < w; x++) { int oa = ra + x * 3, ob = rb + x * 3;
          int diff = Math.Abs(ba[oa] - bb[ob]) + Math.Abs(ba[oa + 1] - bb[ob + 1]) + Math.Abs(ba[oa + 2] - bb[ob + 2]);
          n++; if (diff > 30) d++; } }
      return 100.0 * d / n;
    }
  }
}
'@ -ReferencedAssemblies System.Drawing -ErrorAction Stop

$vlist = J '/vault/list'
$perfd = J '/perf'
$used = [double]$vlist.usedBytes
$momN = @($vlist.moments).Count
$avgN = [int][math]::Round([double]$perfd.last.avg)


Cdp-Open "$api/v2/perf.html" 1920 1080
$pWait = Wait-Page "!!document.getElementById('idNum') && /fps/.test(document.getElementById('idNum').textContent)" 30
Start-Sleep -Milliseconds 600
$pHead = Cdp-Eval "(function(){var e=document.getElementById('idbar');return e?e.innerText.replace(/\s+/g,' ').trim():'';})()"
Cdp-Shot (Join-Path $shots 'qw-perf-new.png')
$pShot = Test-Path (Join-Path $shots 'qw-perf-new.png')
$pm = [regex]::Match([string]$pHead, '(?i)\bperformance\b')
$fm = [regex]::Match([string]$pHead, '(\d+)\s*fps')
Check "the Performance top names the page and the last average frame rate ($($fm.Groups[1].Value) of $avgN fps) ('$pHead')" ($pWait -and $pm.Success -and $fm.Success -and ([int]$fm.Groups[1].Value -eq $avgN))
Cdp-Close

$idCopy = "$pHead"
Check 'the two headers pass the copy rules (no you, no dashes, no filler)' ($idCopy -notmatch '(?i)\byou(?:r|rs|rself|''re|''ve|''ll)?\b|\u2014|!|\bjust\b|\bsimply\b|\bwelcome\b')

}
catch {
  $script:fail++
  "  FAIL  the test stopped: $($_.Exception.Message)"
}
finally {
  try { Cdp-Close } catch { }
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8 } catch { }
  try { $null = J '/vault/test/cosworth?on=auto' } catch { }
  try { $null = J '/vault/test/sandbox?on=0' } catch { }
  Remove-Item $hook -Force -ErrorAction SilentlyContinue
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  Exit-TestLock
  try { if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force } } catch { }
}
Write-Host ''
Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
