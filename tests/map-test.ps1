# map-test.ps1 - offline: dash\www\app\lib\map.js (W4-2), the one track map of REVIEW, in headless Chrome on static files.
# fetch is a stand-in: /trackmap answers with Road Atlanta's outline (dash\maps\t127-roadatlanta-full.json, the shape irdash sends),
# or 404 for the "no outline" case. Every request is counted.
#   1. the outline from the fixture answer, one fetch and no polling   2. colour(): gains green, losses red, zero ink (pixels)
#   3. marks 1-3 at the right places   4. the cursor moves   5. cars, Peter in gold   6. no outline: one retry after 5 s, then
#   "Map not available", nothing after that   7. unmount   8. idle: nothing drawn, no polling
# Pictures: tests\shots\rework\map-<state>.png. Nothing reaches irdash.
#   powershell -ExecutionPolicy Bypass -File tests\map-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'dash\www\app'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'map test (W4-2)'
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
$tmp = Join-Path $env:TEMP ('map-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
function Url([string]$p) { 'file:///' + ($p -replace '\\', '/') }

$outline = Join-Path $root 'dash\maps\t127-roadatlanta-full.json'
$html = @"
<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="$(Url "$app\design.css")">
<style>#m{position:absolute;left:40px;top:40px;width:1000px;height:1000px;background:var(--bg)} #side{position:absolute;left:1100px;top:60px;font-size:var(--t-read)}</style></head>
<body><div id="m"></div><div id="side"></div>
<script>
// the pretend irdash: /trackmap answers with the fixture outline (mode ok) or 404 (mode none); every request is counted
window.__req = []; window.__mode = 'ok';
window.__outline = new Promise(res => { const x = new XMLHttpRequest(); x.open('GET', '$(Url $outline)'); x.onload = () => res(x.responseText); x.send(); });
window.fetch = async (url) => {
  window.__req.push(String(url));
  if (window.__mode === 'ok' && /^\/trackmap\?/.test(url)) { const t = await window.__outline; return new Response(t, { status: 200, headers: { 'Content-Type': 'application/json' } }); }
  return new Response('{"error":"no outline"}', { status: 404 });
};
</script>
<script type="module">
import { Map as TrackMap } from '$(Url "$app\lib\map.js")';
import Def from '$(Url "$app\lib\map.js")';
window.TrackMap = TrackMap; window.MapDefault = Def; window.ready = true;
</script></body></html>
"@
[IO.File]::WriteAllText("$tmp\page.html", $html, (New-Object Text.UTF8Encoding($false)))

# ---- cdp: headless Chrome with the DevTools protocol (the corners-test pattern) ----
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $tmp 'prof'; $port = 9374
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", '--allow-file-access-from-files', "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
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
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "FAIL js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
}
# ---- end cdp ----
function Run-Js([string]$js) {
  $v = Cdp-Eval $js
  foreach ($l in @($v)) { $s = [string]$l; if ($s -match '^ok ') { $script:pass++; "  ok    " + $s.Substring(3) } else { $script:fail++; "  FAIL  " + ($s -replace '^FAIL ', '') } }
}
function Shot([string]$name) { $png = Join-Path $shots "map-$name.png"; Cdp-Shot $png; if (Test-Path $png) { $script:pass++; "  ok    picture: $png" } else { $script:fail++; "  FAIL  no picture $name" } }

$H = @'
window.T = {
  out: [], ok(name, cond, why) { this.out.push((cond ? 'ok ' : 'FAIL ') + name + (cond || why == null ? '' : ' (' + why + ')')); },
  cv() { return document.querySelector('#m canvas'); },
  px(p) { const d = this.cv().getContext('2d').getImageData(Math.round(p[0]), Math.round(p[1]), 1, 1).data; return [d[0], d[1], d[2], d[3]]; },
  col(name) { const s = getComputedStyle(document.documentElement).getPropertyValue('--' + name).trim(); return [1, 3, 5].map(i => parseInt(s.substr(i, 2), 16)); },
  near(p, c, tol) { return Math.abs(p[0] - c[0]) <= tol && Math.abs(p[1] - c[1]) <= tol && Math.abs(p[2] - c[2]) <= tol; },
  around(p, r, fn) { const g = this.cv().getContext('2d'), d = g.getImageData(Math.round(p[0] - r), Math.round(p[1] - r), 2 * r, 2 * r).data; let n = 0; for (let i = 0; i < d.length; i += 4) if (fn([d[i], d[i + 1], d[i + 2]])) n++; return n; },
  async frame() { await new Promise(r => requestAnimationFrame(() => r())); await new Promise(r => setTimeout(r, 0)); },
  wait: ms => new Promise(r => setTimeout(r, ms)),
  done() { const o = this.out; this.out = []; return o; },
};
'@

Assert-RigFree -Where '1-8. page'
try {
  Cdp-Open ((Url "$tmp\page.html"))
  for ($i = 0; $i -lt 40; $i++) { if ((Cdp-Eval 'window.ready === true') -eq $true) { break }; Start-Sleep -Milliseconds 150 }
  $null = Cdp-Eval $H

  Section '1. the outline'
  Run-Js @'
(async () => {
  TrackMap.mount(document.getElementById('m'), { key: 't127-roadatlanta-full', id: 127 });
  for (let i = 0; i < 40 && TrackMap.status !== 'ready'; i++) await T.wait(50);
  await T.frame(); await T.frame();
  T.ok('1. Map is the named export and the default', MapDefault === TrackMap);
  T.ok('1. one fetch of /trackmap with the key and the track id', __req.length === 1 && __req[0] === '/trackmap?key=t127-roadatlanta-full&id=127', __req.join(' '));
  T.ok('1. the outline is in (status ready)', TrackMap.status === 'ready');
  const cv = T.cv();
  T.ok('1. the canvas takes the element size (1000 x 1000)', cv.width === 1000 && cv.height === 1000 && cv.clientWidth === 1000);
  const pts = [0.1, 0.3, 0.5, 0.7, 0.9].map(p => TrackMap.where(p));
  T.ok('1. every point on the lap is inside the picture', pts.every(q => q[0] > 20 && q[0] < 980 && q[1] > 20 && q[1] < 980));
  const panel = T.col('panel'), road = pts.map(q => T.px(q));
  T.ok('1. the road is drawn under every point (dark surface)', road.every(p => p[3] === 255 && T.near(p, panel, 6)), road.map(p => p.slice(0, 3).join(',')).join(' '));
  // the light edge either side of the road
  const q = TrackMap.where(0.3), edge = T.around(q, 14, p => p[0] > 150 && p[1] > 150 && p[2] > 140);
  T.ok('1. the road has its light edge (' + edge + ' edge pixels near 30 %)', edge > 10);
  const blank = T.px([5, 5]);
  T.ok('1. outside the road nothing is drawn', blank[3] === 0);
  T.ok('1. no page errors', !window.__errs.length, window.__errs.join(' | '));
  return T.done();
})()
'@
  Shot 'outline'

  Section '2-5. colour, marks, cursor, cars'
  Run-Js @'
(async () => {
  const gain = new Array(100).fill(0);
  for (let i = 10; i < 20; i++) gain[i] = 0.02 + (i - 10) * 0.004;      // gains (green)
  for (let i = 50; i < 62; i++) gain[i] = -0.05;                        // losses (red)
  TrackMap.colour(gain); await T.frame(); await T.frame();
  const g = T.px(TrackMap.where(0.15)), l = T.px(TrackMap.where(0.55)), z = T.px(TrackMap.where(0.8));
  T.ok('2. a gain paints the road green (' + g.slice(0, 3) + ')', g[1] > g[0] + 40 && g[1] > 90);
  T.ok('2. a loss paints the road red (' + l.slice(0, 3) + ')', l[0] > l[1] + 60 && l[0] > 110);
  T.ok('2. zero is a quiet ink line (' + z.slice(0, 3) + ')', Math.abs(z[0] - z[1]) < 16 && Math.abs(z[1] - z[2]) < 20 && z[0] > 60 && z[0] < 200);
  T.ok('2. a stronger gain is a stronger green', T.px(TrackMap.where(0.19))[1] > T.px(TrackMap.where(0.105))[1]);
  T.ok('2. colour(null) takes the colours off', (TrackMap.colour(null), await T.frame(), await T.frame(), T.near(T.px(TrackMap.where(0.55)), T.col('panel'), 6)));
  TrackMap.colour(gain);
  TrackMap.marks([{ n: 1, p: 0.555 }, { n: 2, p: 0.15 }, { n: 3, p: 0.82 }]); await T.frame(); await T.frame();
  const gold = T.col('gold'), isGold = p => T.near(p, gold, 40);
  const mk = [0.555, 0.15, 0.82].map(p => T.around(TrackMap.where(p), 42, isGold));
  T.ok('3. the marks 1, 2, 3 are gold rings at their places (' + mk.join(', ') + ' gold pixels)', mk.every(n => n > 150));
  T.ok('3. ... and not elsewhere', T.around(TrackMap.where(0.35), 42, isGold) < 10);
  TrackMap.cursor(0.4); await T.frame(); await T.frame();
  const ink = T.col('ink'), isInk = p => T.near(p, ink, 30);
  T.ok('4. the cursor is an ink dot at 40 %', isInk(T.px(TrackMap.where(0.4))));
  TrackMap.cursor(0.45); await T.frame(); await T.frame();
  T.ok('4. cursor(0.45) moves it: one dot, at 45 % and gone from 40 %', isInk(T.px(TrackMap.where(0.45))) && !isInk(T.px(TrackMap.where(0.4))));
  TrackMap.cars([{ p: 0.25 }, { p: 0.27 }, { p: 0.3, me: true }]); await T.frame(); await T.frame();
  const muted = p => p[0] > 110 && p[0] < 170 && Math.abs(p[0] - p[1]) < 12;
  T.ok('5. cars are quiet dots, Peter in gold', muted(T.px(TrackMap.where(0.25))) && muted(T.px(TrackMap.where(0.27))) && isGold(T.px(TrackMap.where(0.3))));
  T.ok('5. still one fetch: the colours, marks, cursor and cars never ask irdash', __req.length === 1);
  document.getElementById('side').textContent = 'gains green at 10-20 %, losses red at 50-62 %';
  return T.done();
})()
'@
  Shot 'colour'
  $null = Cdp-Eval "TrackMap.cars([]); TrackMap.marks([{ n: 1, p: 0.555 }, { n: 2, p: 0.15 }, { n: 3, p: 0.82 }]); T.frame()"

  Section '8. idle'
  Run-Js @'
(async () => {
  const f0 = TrackMap.frames; await T.wait(1200);
  T.ok('8. nothing is drawn while nothing changes', TrackMap.frames === f0);
  T.ok('8. no polling once the outline is in (6 s, still one request)', (await T.wait(5000), __req.length === 1), __req.length);
  return T.done();
})()
'@

  Section '6. no outline'
  Run-Js @'
(async () => {
  TrackMap.unmount();
  T.ok('7. unmount takes the canvas away', !document.querySelector('#m canvas') && !document.querySelector('#m .map-word'));
  TrackMap.cursor(0.3); TrackMap.colour([1]); TrackMap.marks([{ n: 1, p: 0.1 }]);
  T.ok('7. calls after unmount do nothing', !window.__errs.length);
  __req.length = 0; __mode = 'none'; document.getElementById('side').textContent = '';
  TrackMap.mount(document.getElementById('m'), { key: 't999-nowhere', id: 999, size: 700 });
  await T.wait(800);
  T.ok('6. no outline: one fetch, then waiting to try again', __req.length === 1 && TrackMap.status === 'retrying', __req.length + ' ' + TrackMap.status);
  T.ok('6. the size option sets the canvas (700 px)', T.cv().width === 700);
  await T.wait(4800);
  T.ok('6. the one retry comes after 5 s', __req.length === 2, __req.length);
  await T.wait(300);
  const w = document.querySelector('#m .map-word');
  T.ok('6. then the plain words "Map not available"', TrackMap.status === 'missing' && w && !w.hidden && w.textContent === 'Map not available');
  T.ok('6. the words are 24 px or bigger', parseFloat(getComputedStyle(w).fontSize) >= 24);
  T.ok('6. no invented track is drawn', T.around([350, 350], 340, p => p[0] > 30) === 0);
  await T.wait(6000);
  T.ok('6. nothing more is asked after that (12 s, two requests)', __req.length === 2, __req.length);
  return T.done();
})()
'@
  Shot 'missing'
} finally { Cdp-Close }

Section 'source'
$js = [IO.File]::ReadAllText((Join-Path $app 'lib\map.js'))
if ($js -notmatch 'setInterval') { $pass++; '  ok    map.js has no setInterval (no polling)' } else { $fail++; '  FAIL  map.js has a setInterval' }
if (([regex]::Matches($js, 'setTimeout\(')).Count -eq 1) { $pass++; '  ok    map.js has exactly one timer: the one retry' } else { $fail++; '  FAIL  map.js has more than one timer' }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
