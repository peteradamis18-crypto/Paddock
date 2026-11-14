# chart-test.ps1 - offline: dash\www\app\lib\chart.js (W4-2), the one trace engine of REVIEW, in headless Chrome on static files.
# The test writes a small PWB1 reply by hand (the byte layout of dash\src\workbench.cs ChannelsRoute: two laps of a 2000 m pretend
# track, 6 channels each, the corners in the header) and labels the laps with the 12 Nov race's lap 8 and lap 9 from the sidecar.
#   1. fromPwb round-trips the fixture   2. six rows on one axis, the delta row first and gold   3. corner bands and names at the right metres
#   4. the cursor line across every row and the readout (both laps, 36 px = --t-read)   5. setRange / zoomCorner / zoomLap (pixels)
#   6. wheel and drag   7. frame time (average of 100)   8. nothing drawn while hidden or idle   9. update / unmount   10. design lint
# Pictures: tests\shots\rework\chart-<state>.png. Nothing reaches irdash.
#   powershell -ExecutionPolicy Bypass -File tests\chart-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'dash\www\app'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'chart test (W4-2)'
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
$tmp = Join-Path $env:TEMP ('chart-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
function Url([string]$p) { 'file:///' + ($p -replace '\\', '/') }

# ---------------- the fixture: a PWB1 reply written by hand ----------------
Section '0. fixture'
$side = Get-Content (Join-Path $root 'tests\fixtures\race-12nov-sidecar.json') -Raw | ConvertFrom-Json
$lapA = $side.laps | Where-Object { $_.n -eq 8 }; $lapR = $side.laps | Where-Object { $_.n -eq 9 }
$M = 2000; $n = $M + 1
# corners (metres): start, apex, end
$corners = @(@(300, 370, 450), @(800, 880, 950), @(1300, 1400, 1500), @(1750, 1800, 1850))
# minimum speed (m/s) at each apex: this lap gains a little at T1, loses at T2 (slower), gains more at T3
$vminA = @(27, 22, 31, 30); $vminR = @(25, 25, 24, 30)
$brakeA = @(110, 150, 110, 80); $brakeR = @(110, 110, 110, 80)   # metres before the apex the brake goes on
function Make-Lap($vmin, $brk) {
  $sp = New-Object float[] $n; $th = New-Object float[] $n; $bk = New-Object float[] $n; $st = New-Object float[] $n; $gr = New-Object float[] $n; $rpm = New-Object float[] $n; $t = New-Object float[] $n
  $vmax = 50.0; $acc = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    $v = $vmax; $b = 0.0; $s = 0.0; $tt = 1.0
    for ($k = 0; $k -lt 4; $k++) {
      $da = $corners[$k][1]; $u = ($i - $da) / 90.0; $w = [Math]::Exp(-$u * $u)
      $vc = $vmax - ($vmax - $vmin[$k]) * $w; if ($vc -lt $v) { $v = $vc }
      $s += $w * 0.5 * $(if ($k % 2) { -1 } else { 1 })
      if ($i -ge $da - $brk[$k] -and $i -lt $da - 30) { $b = 0.85; $tt = 0.0 }
      elseif ($i -ge $da - 30 -and $i -lt $da + 20) { $tt = [Math]::Min($tt, 0.25) }
    }
    $sp[$i] = $v; $th[$i] = $tt; $bk[$i] = $b; $st[$i] = $s
    $gr[$i] = $(if ($v -lt 28) { 2 } elseif ($v -lt 36) { 3 } elseif ($v -lt 44) { 4 } else { 5 })
    $rpm[$i] = 2500 + ($v / 50.0) * 5000
    if ($i -gt 0) { $acc += 2.0 / ($sp[$i] + $sp[$i - 1]) }      # 1 m at the mean speed
    $t[$i] = $acc
  }
  return @{ t = $t; Speed = $sp; Throttle = $th; Brake = $bk; SteeringWheelAngle = $st; Gear = $gr; RPM = $rpm }
}
$A = Make-Lap $vminA $brakeA; $R = Make-Lap $vminR $brakeR
$chans = @('Speed', 'Throttle', 'Brake', 'SteeringWheelAngle', 'Gear', 'RPM')
$units = @{ Speed = 'm/s'; Throttle = '%'; Brake = '%'; SteeringWheelAngle = 'rad'; Gear = ''; RPM = 'revs/min' }
$arrays = @('lap.t') + ($chans | ForEach-Object { "lap.$_" }) + @('ref.t') + ($chans | ForEach-Object { "ref.$_" })
$head = [ordered]@{ v = 1; n = $n; metres = $M; lengthM = 2000.0; step = 1.0; track = 'Pretend Park'; config = ''; car = 'Toyota GR86'
  lap = [ordered]@{ n = 8; time = [double]$lapA.time; kind = 'lap' }; partial = $null; conditions = $null
  ref = [ordered]@{ n = 9; time = [double]$lapR.time; kind = 'session' }
  channels = @($chans | ForEach-Object { [ordered]@{ key = $_; name = $_; unit = $units[$_]; desc = ''; ok = $true } })
  multi = @(); arrays = $arrays; laps = @()
  corners = @(for ($k = 0; $k -lt 4; $k++) { [ordered]@{ n = $k + 1; label = 'T' + ($k + 1); name = ''; official = ''; p0 = $corners[$k][0] / $M; pa = $corners[$k][1] / $M; p1 = $corners[$k][2] / $M } })
  credit = ''; sectorAt = @() }
$hb = [Text.Encoding]::UTF8.GetBytes(($head | ConvertTo-Json -Depth 6 -Compress))
$pad = (4 - $hb.Length % 4) % 4
$ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter($ms)
$bw.Write([byte[]][char[]]'PWB1'); $bw.Write([int]($hb.Length + $pad)); $bw.Write($hb); for ($i = 0; $i -lt $pad; $i++) { $bw.Write([byte]32) }
foreach ($L in @($A, $R)) { foreach ($k in @('t') + $chans) { foreach ($v in $L[$k]) { $bw.Write([single]$v) } } }
$bw.Flush(); [IO.File]::WriteAllBytes("$tmp\fixture.pwb", $ms.ToArray()); $bw.Dispose()
# what the page must read back (worked out here, not by chart.js)
$expect = [ordered]@{ n = $n; lapN = 8; refN = 9; tA = [double]$A.t[$M]; tR = [double]$R.t[$M]; dEnd = [double]([single]$A.t[$M] - [single]$R.t[$M])
  d880 = [double]([single]$A.t[880] - [single]$R.t[880]); mph880A = [Math]::Round([single]$A.Speed[880] * 2.236936); mph880R = [Math]::Round([single]$R.Speed[880] * 2.236936)
  lapLabel = 'Lap 8 ' + $lapA.time; refLabel = 'Lap 9 ' + $lapR.time }
$bytes = (Get-Item "$tmp\fixture.pwb").Length
if ($bytes -eq 8 + $hb.Length + $pad + 2 * 7 * $n * 4) { $pass++; "  ok    fixture: two laps, 2000 m, $bytes bytes (lap 8 $($lapA.time) s vs lap 9 $($lapR.time) s from the 12 Nov sidecar)" } else { $fail++; "  FAIL  fixture size $bytes" }

# ---------------- the page ----------------
$html = @"
<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="$(Url "$app\design.css")">
<style>body{padding:0} #wrap{position:absolute;left:24px;top:24px;right:24px;bottom:24px;display:flex;gap:24px}
#c{flex:1;position:relative} #r{width:372px;flex:none}</style></head>
<body><div id="wrap"><div id="c"></div><div id="r"></div></div>
<script type="module">
import { Chart } from '$(Url "$app\lib\chart.js")';
import Def from '$(Url "$app\lib\chart.js")';
window.Chart = Chart; window.ChartDefault = Def; window.EXPECT = $($expect | ConvertTo-Json -Compress);
window.loadPwb = () => new Promise((res, rej) => { const x = new XMLHttpRequest(); x.open('GET', '$(Url "$tmp\fixture.pwb")'); x.responseType = 'arraybuffer'; x.onload = () => res(x.response); x.onerror = rej; x.send(); });
window.ready = true;
</script></body></html>
"@
[IO.File]::WriteAllText("$tmp\page.html", $html, (New-Object Text.UTF8Encoding($false)))

# ---- cdp: headless Chrome with the DevTools protocol (the corners-test pattern) ----
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $tmp 'prof'; $port = 9373
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
function Shot([string]$name) { $png = Join-Path $shots "chart-$name.png"; Cdp-Shot $png; if (Test-Path $png) { $script:pass++; "  ok    picture: $png" } else { $script:fail++; "  FAIL  no picture $name" } }

# shared page helpers: pixels of the chart canvas, rows, frames
$H = @'
window.T = {
  out: [], ok(name, cond, why) { this.out.push((cond ? 'ok ' : 'FAIL ') + name + (cond || why == null ? '' : ' (' + why + ')')); },
  cv() { return document.querySelector('#c canvas'); },
  px(x, y) { const d = this.cv().getContext('2d').getImageData(Math.round(x), Math.round(y), 1, 1).data; return [d[0], d[1], d[2]]; },
  col(name) { const s = getComputedStyle(document.documentElement).getPropertyValue('--' + name).trim(); return [1, 3, 5].map(i => parseInt(s.substr(i, 2), 16)); },
  near(p, c, tol) { return Math.abs(p[0] - c[0]) <= tol && Math.abs(p[1] - c[1]) <= tol && Math.abs(p[2] - c[2]) <= tol; },
  count(x0, y0, x1, y1, fn) { const g = this.cv().getContext('2d'), w = Math.round(x1 - x0), h = Math.round(y1 - y0), d = g.getImageData(Math.round(x0), Math.round(y0), w, h).data; let n = 0; for (let i = 0; i < d.length; i += 4) if (fn([d[i], d[i + 1], d[i + 2]])) n++; return n; },
  box(key) { return Chart.rowsBox().find(b => b.key === key); },
  async frame() { await new Promise(r => requestAnimationFrame(() => r())); await new Promise(r => setTimeout(r, 0)); },
  ro(key) { const e = document.querySelector('#r .chro-row[data-key="' + key + '"]'); return e ? [...e.querySelectorAll('.chro-v')].map(v => v.textContent) : null; },
  done() { const o = this.out; this.out = []; return o; },
};
'@

Assert-RigFree -Where '1-10. page'
try {
  Cdp-Open ((Url "$tmp\page.html"))
  for ($i = 0; $i -lt 40; $i++) { if ((Cdp-Eval 'window.ready === true') -eq $true) { break }; Start-Sleep -Milliseconds 150 }
  $null = Cdp-Eval $H

  Section '1. fromPwb'
  Run-Js @'
(async () => {
  const buf = await loadPwb(); const E = EXPECT;
  const rows = Chart.fromPwb(buf, { units: 'mph' }); window.ROWS = rows;
  T.ok('1. fromPwb reads six rows in order delta, speed, pedals, steer, gear, rpm', rows.map(r => r.key).join(',') === 'delta,speed,pedals,steer,gear,rpm', rows.map(r => r.key).join(','));
  T.ok('1. the axis is the header lengthM (2000 m) and every array has n = ' + E.n + ' samples', rows.x.len === 2000 && rows.every(r => r.series.every(s => s.data.length === E.n)));
  const d = rows[0].series[0].data;
  T.ok('1. delta at the line = this lap t - reference t (' + E.dEnd.toFixed(4) + ' s)', Math.abs(d[E.n - 1] - E.dEnd) < 1e-4, d[E.n - 1]);
  T.ok('1. delta at 880 m round-trips (' + E.d880.toFixed(4) + ' s)', Math.abs(d[880] - E.d880) < 1e-4, d[880]);
  const sp = rows[1].series;
  T.ok('1. speed in mph for both laps (880 m: ' + E.mph880A + ' and ' + E.mph880R + ')', rows[1].unit === 'mph' && sp.length === 2 && Math.round(sp[0].data[880]) === E.mph880A && Math.round(sp[1].data[880]) === E.mph880R, sp.map(s => s.data[880]));
  T.ok('1. this lap gold, the reference ink', sp[0].color === 'gold' && sp[1].color === 'ink' && rows[0].series[0].color === 'gold');
  T.ok('1. pedals: throttle and brake for both laps, 0-100 %', rows[2].series.length === 4 && rows[2].min === 0 && rows[2].max === 100 && Math.max(...rows[2].series[2].data) > 84);
  T.ok('1. gear is a step row', rows[4].kind === 'step' && rows[4].series[0].data[880] === 2);
  T.ok('1. corners from the header: four, T2 apex at 0.44 of the lap', rows.corners.length === 4 && Math.abs(rows.corners[1].pa - 0.44) < 1e-6 && rows.corners[1].label === 'T2');
  T.ok('1. the laps are labelled from the header (lap 8 against lap 9)', rows.head.lap.n === 8 && rows.head.ref.n === 9 && /Lap 8/.test(sp[0].label) && /9/.test(sp[1].label));
  const kmh = Chart.fromPwb(buf, { units: 'km/h' });
  T.ok('1. km/h when asked', kmh[1].unit === 'km/h' && Math.abs(kmh[1].series[0].data[880] / sp[0].data[880] - 3.6 / 2.236936) < 1e-4);
  let threw = false; try { Chart.fromPwb(new ArrayBuffer(16)); } catch (e) { threw = true; }
  T.ok('1. a reply that is not PWB1 is refused', threw);
  T.ok('1. Chart is the default export too', ChartDefault === Chart);
  return T.done();
})()
'@

  Section '2-4. mount, rows, bands, cursor, readout'
  Run-Js @'
(async () => {
  const rows = ROWS;
  Chart.mount(document.getElementById('c'), { x: rows.x, rows, corners: rows.corners, readout: document.getElementById('r') });
  Chart.setCursor(880); Chart.flush(); await T.frame();
  const B = Chart.rowsBox(), cv = T.cv(), W = cv.clientWidth;
  T.ok('2. six rows stacked on one axis, delta first', B.length === 6 && B[0].key === 'delta' && B.every((b, i) => !i || b.y0 > B[i - 1].y1));
  T.ok('2. the delta row is the tallest (the one that tells him where to look)', B.every(b => b.y1 - b.y0 <= B[0].y1 - B[0].y0 + 0.5));
  const gold = T.col('gold'), gp = r => T.count(8, r.y0, W - 8, r.y1, p => T.near(p, gold, 26));
  const gd = gp(B[0]);
  T.ok('2. the delta row is drawn in gold (' + gd + ' gold pixels)', gd > 1500, gd);
  const loss = T.col('loss'), gain = T.col('gain');
  // shade: this lap is behind after T2 (red under the line), ahead after T3 (green)
  const yz = B[0].y0 + (B[0].y1 - B[0].y0) / 2;
  T.ok('2. losses shaded red and gains green under the delta line', T.count(8, B[0].y0, W - 8, B[0].y1, p => p[0] > p[1] + 25 && p[0] > 40) > 500 && T.count(8, B[0].y0, W - 8, B[0].y1, p => p[1] > p[0] + 25 && p[1] > 40) > 200);
  // corner bands at the right metres: the top of the steering row is lighter inside T2 (800-950 m) than outside it
  const s = T.box('steer'), y = s.y0 + 2;
  const inB = T.px(Chart.xOf(845), y), outB = T.px(Chart.xOf(610), y), bg = T.col('bg');
  T.ok('3. T2 band is drawn between 800 and 950 m (inside ' + inB + ', outside ' + outB + ')', inB[0] > outB[0] + 6 && T.near(outB, bg, 3));
  T.ok('3. the band edges sit at 800 m and 950 m', T.px(Chart.xOf(803), y)[0] > outB[0] + 6 && T.px(Chart.xOf(797), y)[0] <= outB[0] + 2 && T.px(Chart.xOf(947), y)[0] > outB[0] + 6 && T.px(Chart.xOf(953), y)[0] <= outB[0] + 2);
  const lab = [370, 880, 1400, 1800].map(m => T.count(Chart.xOf(m) - 22, 12, Chart.xOf(m) + 22, 46, p => p[0] > 90));
  T.ok('3. a corner name over each apex (' + lab.join(', ') + ' text pixels)', lab.every(v => v > 30));
  // the cursor: one vertical ink line through every row
  const ink = T.col('ink'), xc = Math.round(Chart.xOf(880));
  const cover = B.map(b => { let n = 0; for (let yy = Math.ceil(b.y0); yy < b.y1; yy++) if (T.near(T.px(xc, yy), ink, 30)) n++; return n / (b.y1 - b.y0); });
  T.ok('4. the cursor line crosses every row (' + cover.map(c => Math.round(c * 100) + '%').join(' ') + ')', cover.every(c => c > 0.6));
  T.ok('4. setCursor(880) puts the cursor at 880 m', Math.abs(Chart.cursor - 880) < 1e-6);
  // the readout column
  const E = EXPECT, top = document.querySelector('#r .chro-m').textContent, cn = document.querySelector('#r .chro-c').textContent;
  T.ok('4. the readout says where: "' + top + ' ' + cn + '"', top === '880 m' && cn === 'T2');
  const dv = T.ro('delta')[0], want = (E.d880 > 0 ? '+' : String.fromCharCode(8722)) + Math.abs(E.d880).toFixed(3);
  T.ok('4. delta readout ' + dv + ' s', dv === want, want);
  T.ok('4. speed readout shows both laps: ' + T.ro('speed').join(' / '), T.ro('speed').join(',') === E.mph880A + ',' + E.mph880R);
  T.ok('4. pedals readout shows throttle and brake for both laps: ' + T.ro('pedals').join(' / '), T.ro('pedals').length === 4 && T.ro('pedals').every(v => /^\d+$/.test(v)));
  T.ok('4. steering, gear, rpm each show both laps', ['steer', 'gear', 'rpm'].every(k => T.ro(k).length === 2 && T.ro(k).every(v => v && v !== String.fromCharCode(8211))) && T.ro('gear').join(',') === '2,2');
  const vals = [...document.querySelectorAll('#r .chro-v')], sizes = vals.map(v => parseFloat(getComputedStyle(v).fontSize));
  const tread = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--t-read'));
  T.ok('4. every readout value is --t-read (' + tread + ' px)', sizes.every(z => z === tread) && tread >= 32, sizes.join(','));
  const all = [...document.querySelectorAll('#r *')].filter(e => e.textContent.trim()).map(e => parseFloat(getComputedStyle(e).fontSize));
  T.ok('4. nothing in the readout under 24 px', all.every(z => z >= 24), Math.min(...all));
  T.ok('4. the delta readout is gold', getComputedStyle(document.querySelector('#r .chro-row[data-key="delta"] .chro-v')).color.replace(/\s/g, '') === 'rgb(' + gold.join(',') + ')');
  const rr = [...document.querySelectorAll('#r .chro-row')].map(e => e.getBoundingClientRect()), cr = cv.getBoundingClientRect();
  T.ok('4. each readout block lines up with its row', rr.every((r, i) => Math.abs((r.top - cr.top) - B[i].y0) < 1.5));
  T.ok('4. no title attributes (no mouse-only tooltips)', !document.querySelector('#c [title], #r [title]'));
  T.ok('4. no page errors', !window.__errs.length, window.__errs.join(' | '));
  return T.done();
})()
'@
  Shot 'lap'

  Section '5. zoom'
  Run-Js @'
(async () => {
  const W = T.cv().clientWidth, s = T.box('steer'), y = s.y0 + 2, bg = T.col('bg');
  Chart.setRange(800, 960); Chart.flush();
  T.ok('5. setRange(800, 960) sets the range', Chart.range[0] === 800 && Chart.range[1] === 960);
  T.ok('5. zoomed: T2 band now fills the middle of the row and ends near the right (pixels)', !T.near(T.px(W * 0.5, y), bg, 3) && T.near(T.px(Chart.xOf(955), y), bg, 3) && Chart.xOf(950) > W * 0.85);
  Chart.zoomCorner(3); Chart.flush(); await T.frame();
  T.ok('5. zoomCorner(3) = T3 with 60 m either side and the cursor on its apex', Math.abs(Chart.range[0] - 1240) < 1e-6 && Math.abs(Chart.range[1] - 1560) < 1e-6 && Chart.cursor === 1400);
  T.ok('5. zoomCorner(3): band at 25 % of the width, none at 5 % (pixels)', !T.near(T.px(W * 0.25, y), bg, 3) && T.near(T.px(W * 0.05, y), bg, 3));
  T.ok('5. the readout follows the cursor to T3', document.querySelector('#r .chro-m').textContent === '1400 m' && document.querySelector('#r .chro-c').textContent === 'T3');
  Chart.zoomLap(); Chart.flush();
  T.ok('5. zoomLap = 0 to 2000 m', Chart.range[0] === 0 && Chart.range[1] === 2000);
  Chart.setRange(1000, 1010); T.ok('5. never closer than 40 m', Math.abs(Chart.range[1] - Chart.range[0] - 40) < 1e-6);
  Chart.setRange(-500, 9000); T.ok('5. never past the lap', Chart.range[0] === 0 && Chart.range[1] === 2000);
  Chart.zoomCorner(99); T.ok('5. an unknown corner changes nothing', Chart.range[0] === 0 && Chart.range[1] === 2000);
  return T.done();
})()
'@
  $null = Cdp-Eval 'Chart.zoomCorner(2); Chart.flush(); T.frame()'
  Shot 'corner'

  Section '6. wheel and drag'
  Run-Js @'
(async () => {
  Chart.zoomLap(); Chart.setCursor(1000); Chart.flush();
  const cv = T.cv(), r = cv.getBoundingClientRect(), seen = [];
  Chart.onCursor(m => seen.push(m));
  cv.dispatchEvent(new WheelEvent('wheel', { deltaY: -100, clientX: r.left + 300, clientY: r.top + 300, bubbles: true, cancelable: true }));
  Chart.flush();
  const g = Chart.range;
  T.ok('6. the wheel zooms in around the cursor (' + g.map(Math.round).join('-') + ' m)', Math.abs((g[1] - g[0]) - 1600) < 1 && g[0] < 1000 && g[1] > 1000 && Math.abs((1000 - g[0]) / (g[1] - g[0]) - 0.5) < 0.01);
  cv.dispatchEvent(new WheelEvent('wheel', { deltaY: 100, clientX: r.left + 300, clientY: r.top + 300, bubbles: true, cancelable: true }));
  T.ok('6. and back out', Math.abs(Chart.range[1] - Chart.range[0] - 2000) < 1);
  Chart.zoomLap(); Chart.flush();
  const X = m => r.left + Chart.xOf(m), Y = r.top + 200;
  cv.dispatchEvent(new PointerEvent('pointerdown', { clientX: X(500), clientY: Y, pointerId: 1, bubbles: true }));
  cv.dispatchEvent(new PointerEvent('pointermove', { clientX: X(600), clientY: Y, pointerId: 1, bubbles: true }));
  cv.dispatchEvent(new PointerEvent('pointermove', { clientX: X(700), clientY: Y, pointerId: 1, bubbles: true }));
  cv.dispatchEvent(new PointerEvent('pointerup', { clientX: X(700), clientY: Y, pointerId: 1, bubbles: true }));
  cv.dispatchEvent(new PointerEvent('pointermove', { clientX: X(900), clientY: Y, pointerId: 1, bubbles: true }));
  T.ok('6. dragging moves the cursor (ends at ' + Math.round(Chart.cursor) + ' m) and stops on release', Math.abs(Chart.cursor - 700) < 3);
  T.ok('6. onCursor hears every move (' + seen.map(Math.round).join(', ') + ')', seen.length === 3 && Math.abs(seen[0] - 500) < 3 && Math.abs(seen[2] - 700) < 3);
  Chart.flush(); await T.frame();
  T.ok('6. the readout shows the dragged position', document.querySelector('#r .chro-m').textContent === Math.round(Chart.cursor) + ' m');
  return T.done();
})()
'@

  Section '7. frame time'
  $perf = Cdp-Eval @'
(async () => {
  Chart.zoomLap(); Chart.flush();
  // the worst case: 6 rows x 2 laps x 4000 points (the fixture's rows on 4000 samples, with a little sensor noise so no run is
  // perfectly straight, as in a real file), a full redraw every frame
  const big = ROWS.map(r => Object.assign({}, r, { series: r.series.map((s, j) => { const d = new Float32Array(4001); for (let i = 0; i <= 4000; i++) d[i] = s.data[Math.floor(i / 2)] * (1 + 0.004 * Math.sin(i * 12.9898 + j)); return Object.assign({}, s, { data: d }); }) }));
  Chart.unmount();
  Chart.mount(document.getElementById('c'), { x: { len: 4000, unit: 'm' }, rows: big, corners: ROWS.corners, readout: document.getElementById('r') });
  Chart.flush();
  const pts = big.reduce((n, r) => n + r.series.reduce((m, s) => m + s.data.length, 0), 0);
  // reading one pixel back makes the canvas really paint now (it would otherwise put the work off and the time would look too good)
  const vis = T.cv().getContext('2d'), sink = () => vis.getImageData(0, 0, 1, 1);
  let t0 = performance.now();
  for (let k = 0; k < 100; k++) { Chart.setRange(k * 5, 4000 - k * 5); Chart.flush(); sink(); }
  const full = (performance.now() - t0) / 100;
  t0 = performance.now();
  for (let k = 0; k < 100; k++) { Chart.setCursor(1000 + k * 7); Chart.flush(); sink(); }
  const cur = (performance.now() - t0) / 100;
  const W = T.cv().clientWidth;
  Chart.unmount();
  Chart.mount(document.getElementById('c'), { x: ROWS.x, rows: ROWS, corners: ROWS.corners, readout: document.getElementById('r') });
  Chart.setCursor(880); Chart.flush();
  return [full, cur, pts, W];
})()
'@
  $full = [double]$perf[0]; $cur = [double]$perf[1]
  $script:frameFull = $full; $script:frameCur = $cur
  if ($full -lt 4) { $pass++; ('  ok    7. a full redraw (rows, bands, ' + $perf[2] + ' points) takes {0:0.00} ms on average over 100 frames at {1} px wide (under 4 ms)' -f $full, $perf[3]) } else { $fail++; ('  FAIL  7. a full redraw takes {0:0.00} ms (over 4 ms)' -f $full) }
  if ($cur -lt 4) { $pass++; ('  ok    7. a cursor move takes {0:0.00} ms on average over 100 frames' -f $cur) } else { $fail++; ('  FAIL  7. a cursor move takes {0:0.00} ms' -f $cur) }

  Section '8. hidden and idle'
  Run-Js @'
(async () => {
  await T.frame(); await T.frame();
  let f0 = Chart.stats.frames;
  await new Promise(r => setTimeout(r, 1200));
  T.ok('8. nothing is drawn while nothing changes (1.2 s, ' + (Chart.stats.frames - f0) + ' frames)', Chart.stats.frames === f0);
  const c = document.getElementById('c'); c.style.display = 'none'; await T.frame(); await T.frame();      // the page hides it; the chart hears its size go to 0
  f0 = Chart.stats.frames; const l0 = Chart.stats.layers;
  Chart.setCursor(1100); Chart.setRange(900, 1300); Chart.flush(); await T.frame(); await T.frame();
  T.ok('8. nothing is drawn while hidden', Chart.stats.frames === f0 && Chart.stats.layers === l0);
  c.style.display = ''; await T.frame(); await T.frame(); Chart.flush();
  T.ok('8. shown again, it catches up (cursor and range applied)', Chart.stats.frames > f0 && Chart.stats.layers > l0 && document.querySelector('#r .chro-m').textContent === '1100 m');
  Chart.zoomLap(); Chart.setCursor(880); Chart.flush();
  return T.done();
})()
'@

  Section '9. update and unmount'
  Run-Js @'
(async () => {
  const before = JSON.stringify(Chart.rowsBox()), s0 = T.ro('speed').join(',');
  // swap the laps: same layout, new data
  const swapped = ROWS.map(r => Object.assign({}, r, { series: r.key === 'delta' ? [Object.assign({}, r.series[0], { data: r.series[0].data.map(v => -v) })] : r.series.slice().reverse() }));
  Chart.update(swapped); Chart.flush(); await T.frame();
  T.ok('9. update keeps the layout', JSON.stringify(Chart.rowsBox()) === before);
  T.ok('9. update shows the new values (' + s0 + ' -> ' + T.ro('speed').join(',') + ')', T.ro('speed').join(',') === s0.split(',').reverse().join(','));
  T.ok('9. ... and keeps the range and the cursor', Chart.range[0] === 0 && Chart.range[1] === 2000 && Chart.cursor === 880);
  Chart.update(ROWS); Chart.flush();
  Chart.unmount();
  T.ok('9. unmount takes the canvas and the readout away', !document.querySelector('#c canvas') && !document.querySelector('#r').textContent && Chart.rowsBox().length === 0);
  Chart.setCursor(5); Chart.zoomLap(); Chart.update([]);
  T.ok('9. calls after unmount do nothing and do not throw', !window.__errs.length);
  Chart.mount(document.getElementById('c'), { x: ROWS.x, rows: ROWS, corners: ROWS.corners, readout: document.getElementById('r') });
  Chart.mount(document.getElementById('c'), { x: ROWS.x, rows: ROWS, corners: ROWS.corners, readout: document.getElementById('r') });
  T.ok('9. mounting twice leaves one canvas', document.querySelectorAll('#c canvas').length === 1);
  return T.done();
})()
'@
  # a short stack (the readout's names go beside the values) and the cursor on a gain
  $null = Cdp-Eval "document.getElementById('wrap').style.bottom = '520px'; Chart.zoomCorner(3); Chart.flush(); T.frame()"
  Run-Js @'
(async () => { await T.frame(); Chart.flush();
  const flat = [...document.querySelectorAll('#r .chro-row')].filter(e => e.classList.contains('flat')).length;
  const ov = [...document.querySelectorAll('#r .chro-row')].some(e => e.scrollHeight > e.clientHeight + 1) || [...document.querySelectorAll('#r .chro-l')].some(e => e.scrollWidth > e.clientWidth + 1);
  T.ok('9. a short stack puts the row names beside the values (' + flat + ' rows) and nothing spills or is cut short', flat >= 4 && !ov);
  return T.done(); })()
'@
  Shot 'short'
} finally { Cdp-Close }

Section '10. design lint'
foreach ($f in @('chart.js', 'map.js')) {
  $t = [IO.File]::ReadAllText((Join-Path $app "lib\$f"))
  $t = [regex]::Replace($t, '(?s)/\*.*?\*/', '')
  if ($t -match '(?i)#[0-9a-f]{3,8}\b|\brgba?\s*\(|\bhsla?\s*\(') { $fail++; "  FAIL  10. lib\$f has a colour literal: $($Matches[0])" } else { $pass++; "  ok    10. lib\$f has no colour literal (colours from design.css tokens)" }
  $small = [regex]::Matches($t, "(\d+)px ") | Where-Object { [int]$_.Groups[1].Value -lt 24 -and $_.Value -match '^\d' } | Where-Object { $t.Substring([Math]::Max(0, $_.Index - 12), 12) -match "font|'" }
  if (@($small).Count) { $fail++; "  FAIL  10. lib\$f draws text under 24 px: " + (($small | ForEach-Object { $_.Value }) -join ' ') } else { $pass++; "  ok    10. lib\$f draws no text under 24 px" }
}
$lint = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'design-lint-test.ps1') 2>&1 | Out-String
$last = ($lint -split "`n" | Where-Object { $_ -match 'passed, \d+ failed' } | Select-Object -Last 1)
if ($LASTEXITCODE -eq 0 -and $lint -match 'app/lib/chart.js has no colour literal' -and $lint -match 'app/lib/map.js has no colour literal') { $pass++; "  ok    10. design-lint passes with both libs in it ($($last.Trim()))" } else { $fail++; "  FAIL  10. design-lint: $last"; ($lint -split "`n" | Where-Object { $_ -match 'FAIL' }) | ForEach-Object { "        $_" } }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
('  frame times: full redraw {0:0.00} ms, cursor move {1:0.00} ms' -f $script:frameFull, $script:frameCur)
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
