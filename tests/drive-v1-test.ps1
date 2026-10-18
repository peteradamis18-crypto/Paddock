# drive-v1-test.ps1 - offline: Drive v1, the in-car fourth screen (dash\www\v2\drive.js + drive.css, design docs\design\drive-v1).
# Opens the real dashboard page from disk in headless Chrome, feeds it session YAML and telemetry frames (tests\drive-fixtures.js),
# and serves /trackmap, /corners and /vault/recorder from saved files. No irdash, no network: safe while Peter races.
# Per state: exact cell words, one unit system, em dash for unknown, no delta on an incomplete lap, honest REC pill, gold only
# for Peter, nothing under 20 px, nothing clipped or overlapping, no network on the render path, the map redraw cap.
# Pictures: tests\shots\drive-<state>.png
#   powershell -ExecutionPolicy Bypass -File tests\drive-v1-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
$root = Split-Path -Parent $PSScriptRoot
$shots = Join-Path $PSScriptRoot 'shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
$pass = 0; $fail = 0
# offline (file page, saved data, no irdash): allowed while Peter races, so no rig guard; Chrome runs BelowNormal on two cores
function Section($name) { $name }
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }

$trackJson = [IO.File]::ReadAllText((Join-Path $root 'dash\maps\t127-roadatlanta-full.json'))
$cornerJson = [IO.File]::ReadAllText((Join-Path $root 'docs\design\drive-v1\data\corners-127.json'))
$fixJs = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'drive-fixtures.js'))
$page = 'file:///' + ((Join-Path $root 'dash\www\v2\index.html') -replace '\\', '/')

# before any page script: no live stream, and the three routes Drive uses answered from saved files; every request is logged
$stub = @"
window.EventSource = function(){ return { addEventListener: function(){}, close: function(){} }; };
window.__fetchLog = []; window.__rec = null;
(function(){
  var T = $trackJson, C = $cornerJson;
  window.fetch = function(u){
    u = String(u); window.__fetchLog.push(u);
    var ok = function(o){ return Promise.resolve(new Response(JSON.stringify(o), { status: 200, headers: { 'Content-Type': 'application/json' } })); };
    if (u.indexOf('/trackmap') === 0) return location.hash === '#nooutline' ? Promise.resolve(new Response('{}', { status: 404 })) : ok(T);
    if (u.indexOf('/corners') === 0) return ok(C);
    if (u.indexOf('/vault/recorder') === 0) return window.__rec ? ok(window.__rec) : Promise.reject(new Error('down'));
    return Promise.resolve(new Response('{}', { status: 404 }));
  };
})();
"@

# CDP plumbing (same as tv-test)
$listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$prof = Join-Path $env:TEMP ('drive-v1-' + [guid]::NewGuid().ToString('N'))
# start /belownormal /affinity: every Chrome child inherits the low priority and the two-core limit (the LAST two cores; the sim lives on the first ones)
$n = [Environment]::ProcessorCount; $mask = '{0:X}' -f ([int64]3 -shl ($n - 2))
$null = Start-Process -FilePath $env:ComSpec -ArgumentList ('/c start "" /belownormal /affinity ' + $mask + ' "' + $chrome + '" --headless=new --disable-gpu --no-first-run --allow-file-access-from-files --user-data-dir="' + $prof + '" --remote-debugging-port=' + $port + ' --window-size=1920,1080 --hide-scrollbars about:blank') -WindowStyle Hidden
$tab = $null; for ($i = 0; $i -lt 50 -and -not $tab; $i++) { Start-Sleep -Milliseconds 200; try { $tab = (Invoke-RestMethod "http://127.0.0.1:$port/json") | Where-Object { $_.type -eq 'page' } | Select-Object -First 1 } catch { } }
if (-not $tab) { '  FAIL  headless Chrome did not start'; exit 1 }
$ws = New-Object System.Net.WebSockets.ClientWebSocket; $null = $ws.ConnectAsync([Uri]$tab.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
$script:cid = 0
function Cdp($method, $params) {
  $script:cid++; $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $script:cid; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
  $null = $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) { $buf = New-Object byte[] 1048576; $sb = New-Object Text.StringBuilder; do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage); $o = $sb.ToString() | ConvertFrom-Json; if ($o.id -eq $script:cid) { return $o } }
}
function Ev($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { throw ('page: ' + $r.result.exceptionDetails.exception.description) }; return $r.result.result.value }
function Shot($path) { $r = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($r.result.data)) }
$null = Cdp 'Page.enable' @{}; $null = Cdp 'Runtime.enable' @{}
$null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = 1920; height = 1080; deviceScaleFactor = 1; mobile = $false }
$null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $stub }

function Load-State($name, $query = '?drive=1') {
  $query += '&s=' + $name     # a different URL each state, so the page really reloads
  $hash = if ($name -eq 'nooutline') { '#nooutline' } else { '' }
  $null = Cdp 'Page.navigate' @{ url = "$page$query$hash" }
  for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 150; try { if ((Ev "typeof Drive!=='undefined'&&typeof setSession==='function'&&document.readyState==='complete'") -eq $true) { break } } catch { } }
  $null = Ev $fixJs.Replace('const DriveFix =', 'window.DriveFix =')
  $null = Ev @"
(function(){
  var s = DriveFix.state('$name');
  window.__state = s; window.__rec = s.rec;
  setSession(s.yaml); onFrame(s.frame);
  L.laps = s.laps; L.lapDirty = s.dirty; L.why = Object.assign(newWhy(), s.why);
  if (s.gapHist) Drive.gapHist = s.gapHist.slice();
  if (s.staleMs) L.lastFrameAt = performance.now() - s.staleMs;
  else window.__feed = setInterval(function(){ onFrame(s.frame); L.lapDirty = s.dirty; }, 100);
  return 'ok';
})()
"@
  Start-Sleep -Milliseconds 1600
}

# one measurement of the whole Drive layer
$audit = @'
(function(){
  var dr = document.getElementById('drive'), q = function(s){ return dr.querySelector(s); };
  var cell = function(id){ var c = document.getElementById(id); return { lbl: c.querySelector('.lbl').textContent, v: c.querySelector('.v').textContent, vCls: c.querySelector('.v').className, s: c.querySelector('.s').textContent, sCls: c.querySelector('.s').className }; };
  var vis = function(e){ if (e.closest('[hidden]') || !e.getClientRects().length) return false; return getComputedStyle(e).visibility !== 'hidden'; };
  var leaves = [].slice.call(dr.querySelectorAll('*')).filter(function(e){ return vis(e) && [].some.call(e.childNodes, function(n){ return n.nodeType === 3 && n.textContent.trim(); }); });
  var small = [], clip = [], off = [], gold = [], text = '';
  leaves.forEach(function(e){
    var cs = getComputedStyle(e), r = e.getBoundingClientRect();
    if (parseFloat(cs.fontSize) < 20) small.push(e.textContent.trim().slice(0, 24) + ' ' + cs.fontSize);
    if (!e.classList.contains('nm') && !e.closest('.nm') && e.scrollWidth > e.clientWidth + 1 && cs.display !== 'inline') clip.push(e.textContent.trim().slice(0, 24));
    if (r.right > 1920.5 || r.bottom > 1080.5 || r.left < -0.5 || r.top < -0.5) off.push(e.textContent.trim().slice(0, 24));
    if (cs.color === 'rgb(242, 194, 48)' && !e.closest('.trow.me')) gold.push(e.textContent.trim().slice(0, 24));
    text += ' ' + e.textContent;
  });
  // text boxes of the band cells and the regions must not overlap
  var boxes = [].slice.call(dr.querySelectorAll('#dBand .lbl, #dBand .v, #dBand .s, #dBand .dbar, #dTop > span, #dFoot > span')).filter(vis).map(function(e){ var r = e.getBoundingClientRect(); return { t: e.textContent.trim().slice(0, 16), r: r, p: e.parentNode }; });
  var over = [];
  for (var i = 0; i < boxes.length; i++) for (var j = i + 1; j < boxes.length; j++) { var a = boxes[i].r, b = boxes[j].r; if (a.width && b.width && Math.min(a.right, b.right) > Math.max(a.left, b.left) + 0.5 && Math.min(a.bottom, b.bottom) > Math.max(a.top, b.top) + 0.5) over.push(boxes[i].t + '|' + boxes[j].t); }
  var reg = ['dMap', 'dTower', 'dBand', 'dFoot', 'dTop'].map(function(id){ var r = document.getElementById(id).getBoundingClientRect(); return { id: id, r: r }; });
  for (var i = 0; i < reg.length; i++) for (var j = i + 1; j < reg.length; j++) { var a = reg[i].r, b = reg[j].r; if (Math.min(a.right, b.right) > Math.max(a.left, b.left) + 0.5 && Math.min(a.bottom, b.bottom) > Math.max(a.top, b.top) + 0.5) over.push(reg[i].id + '|' + reg[j].id); }
  // gold pixels on the map only around Peter's dot
  var cv = document.getElementById('dMapCv'), g = cv.getContext('2d'), im = g.getImageData(0, 0, cv.width, cv.height).data, me = Drive.mePt, goldPx = 0, goldFar = 0;
  for (var y = 0; y < cv.height; y++) for (var x = 0; x < cv.width; x++) { var p = (y * cv.width + x) * 4; if (im[p] > 215 && im[p + 1] > 165 && im[p + 1] < 215 && im[p + 2] < 90) { goldPx++; if (!me || Math.hypot(x - me[0], y - me[1]) > 24) goldFar++; } }
  var rows = [].slice.call(dr.querySelectorAll('#dRows .trow')).map(function(r){ return { idx: +r.dataset.idx, p: r.querySelector('.p').textContent, n: r.querySelector('.n').textContent, nm: r.querySelector('.nm').textContent, g: r.querySelector('.g').textContent, me: r.classList.contains('me'), pit: r.classList.contains('pit'), cls: r.style.getPropertyValue('--class') }; });
  var rec = document.getElementById('dRec');
  var dr0 = dr.getBoundingClientRect();
  return JSON.stringify({
    shown: Drive.shown && vis(dr), rect: [dr0.left, dr0.top, dr0.width, dr0.height], stale: document.body.classList.contains('drive-stale'),
    sess: q('#dSess').textContent, track: q('#dTrack').textContent, clock: q('#dClock').textContent, staleText: q('#dStale').hidden ? '' : q('#dStale').textContent,
    pos: cell('cPos'), gap: cell('cGap'), delta: cell('cDelta'), left: cell('cLeft'), fuel: cell('cFuel'), foot: q('#dLaps').textContent,
    title: q('#dTowerT').textContent, col: q('#dTowerG').textContent, rows: rows, rec: { hidden: rec.hidden, text: rec.textContent.trim(), cls: rec.className },
    small: small, clip: clip, off: off, gold: gold, over: over, goldPx: goldPx, goldFar: goldFar, tags: (Drive.tags || []).length, note: q('#dMapNote').textContent,
    valueColor: getComputedStyle(q('#cPos .v')).color, copy: text
  });
})()
'@
function Audit { (Ev $audit) | ConvertFrom-Json }
function Common($n, $a) {
  Check "$n : Drive covers the 1920 x 1080 screen" ($a.shown -and $a.rect[0] -eq 0 -and $a.rect[1] -eq 0 -and $a.rect[2] -eq 1920 -and $a.rect[3] -eq 1080)
  Check "$n : nothing under 20 px ($($a.small -join '; '))" ($a.small.Count -eq 0)
  Check "$n : no clipped value or label ($($a.clip -join '; '))" ($a.clip.Count -eq 0)
  Check "$n : everything on screen ($($a.off -join '; '))" ($a.off.Count -eq 0)
  Check "$n : no overlapping text or regions ($($a.over -join '; '))" ($a.over.Count -eq 0)
  Check "$n : gold text only in Peter's tower row ($($a.gold -join '; '))" ($a.gold.Count -eq 0)
  Check "$n : copy audit (no '!', no 'you', no 0 standing in for unknown)" ($a.copy -notmatch '!' -and $a.copy -notmatch '(?i)\byou\b' -and $a.copy -notmatch 'NaN|undefined|null|Infinity')
  Check "$n : one unit system (no km/h, kPa, bar, L, litre in imperial)" ($a.copy -notmatch 'km/h|kPa|\bbar\b|litre|\bL\b')
  Check "$n : clock is 12-hour ET" ($a.clock -match '^\d{1,2}:\d\d (AM|PM) ET$')
}

try {
  # ---------- practice ----------
  Section '1. practice'
  Load-State 'practice'; $a = Audit; Shot (Join-Path $shots 'drive-practice.png')
  Common 'practice' $a
  Check 'practice: P4 of 18 by best lap' ($a.pos.lbl -eq 'Position' -and $a.pos.v -eq 'P4' -and $a.pos.s -eq "of 18 $([char]0xB7) best lap")
  Check 'practice: best lap and the gap to the fastest' ($a.gap.lbl -eq 'Best lap' -and $a.gap.v -eq '1:24.902' -and $a.gap.s -eq '+0.591 to fastest')
  Check 'practice: delta -0.27 in green on a clean lap' ($a.delta.v -eq "$([char]0x2212)0.27" -and $a.delta.vCls -match 'gain' -and $a.delta.s -eq '')
  Check 'practice: time left 42:10, lap 12' ($a.left.lbl -eq 'Time left' -and $a.left.v -eq '42:10' -and $a.left.s -eq 'lap 12')
  Check 'practice: fuel 9.4 laps, 3.1 gal at 0.33 a lap' ($a.fuel.v -eq '9.4laps' -and $a.fuel.s -eq "3.1 gal $([char]0xB7) 0.33 a lap")
  Check 'practice: tower is 7 best-lap rows, Peter 4th row' ($a.title -eq 'Best laps' -and $a.rows.Count -eq 7 -and $a.rows[3].me -and $a.rows[3].nm -eq 'Peter Adamis' -and $a.rows[0].g -eq '1:24.311' -and (($a.rows | ForEach-Object { $_.p }) -join ',') -eq '1,2,3,4,5,6,7')
  Check 'practice: REC 32:12 from the recorder verdict' ($a.rec.text -eq 'REC 32:12' -and $a.rec.cls -eq '' -and -not $a.rec.hidden)
  Check 'practice: map shows six numbered cars near Peter and the corner credit' ($a.tags -eq 6 -and $a.note -match 'Lovely Track Data')
  Check 'practice: gold on the map only at Peter' ($a.goldPx -gt 50 -and $a.goldFar -eq 0)
  Check 'practice: footer last and best' ($a.foot -eq "Last 1:25.302 $([char]0xB7) Best 1:24.902")
  # the render path never touches the network, and the map redraw is capped
  $net = Ev "(function(){ var n = __fetchLog.length, t0 = performance.now(); for (var i = 0; i < 50; i++) { var m = Drive.build(); Drive.paint(m); Drive.drawMap(document.getElementById('dMapCv'), Drive.mapCars(), { stale: false, multi: S.multiClass }); } return JSON.stringify({ calls: __fetchLog.length - n, ms: (performance.now() - t0) / 50 }); })()" | ConvertFrom-Json
  "  info  build + paint + map: $([math]::Round($net.ms, 2)) ms a pass"
  Check 'render path makes no network request (50 passes)' ($net.calls -eq 0)
  Check "one build + paint + map pass under 8 ms ($([math]::Round($net.ms, 2)) ms)" ($net.ms -lt 8)
  $cap = Ev "new Promise(function(res){ var n = 0, d = Drive.drawMap; Drive.drawMap = function(){ n++; return d.apply(Drive, arguments); }; setTimeout(function(){ var still = n; n = 0; var f = __state.frame, k = 0; var mv = setInterval(function(){ k++; f.CarIdxLapDistPct = f.CarIdxLapDistPct.map(function(x){ return x >= 0 ? (x + 0.002) % 1 : x; }); }, 16); setTimeout(function(){ clearInterval(mv); Drive.drawMap = d; res(JSON.stringify({ still: still, moving: n })); }, 2000); }, 2000); })" | ConvertFrom-Json
  Check "map does not redraw while nothing moves ($($cap.still) draws in 2 s)" ($cap.still -le 1)
  Check "map redraws stay at 30 fps or less while cars move ($($cap.moving) in 2 s)" ($cap.moving -gt 5 -and $cap.moving -le 61)

  # ---------- multiclass race ----------
  Section '2. multiclass race'
  Load-State 'race'; $a = Audit; Shot (Join-Path $shots 'drive-race.png')
  Common 'race' $a
  Check 'race: class position P5 GT3, P16 overall of 23' ($a.pos.lbl -eq 'Class position' -and $a.pos.v -eq 'P5GT3' -and $a.pos.s -eq "P16 overall $([char]0xB7) 23 cars")
  Check 'race: gap ahead 1.4 s to #8, closing 0.3 a lap in green' ($a.gap.lbl -eq 'Gap ahead' -and $a.gap.v -eq '1.4s' -and $a.gap.s -eq "#8 $([char]0xB7) closing 0.3 a lap" -and $a.gap.sCls -match 'gain')
  Check 'race: delta +0.18 in ink, bar from the centre' ($a.delta.v -eq '+0.18' -and $a.delta.vCls -notmatch 'gain')
  Check 'race: 12 laps left, lap 9 of 20' ($a.left.lbl -eq 'Laps left' -and $a.left.v -eq '12' -and $a.left.s -eq 'lap 9 of 20')
  Check 'race: fuel 7.7 laps, +1.4 gal to finish in amber' ($a.fuel.v -eq '7.7laps' -and $a.fuel.s -eq '+1.4 gal to finish' -and $a.fuel.sCls -match 'warn')
  Check 'race: battle tower is GT3 P2..P8 centred on Peter, class strips' ($a.title -eq "Battle $([char]0xB7) GT3" -and $a.col -eq 'Gap' -and (($a.rows | ForEach-Object { $_.p }) -join ',') -eq '2,3,4,5,6,7,8' -and $a.rows[3].me -and @($a.rows | Where-Object { $_.cls -ne '#ae6bff' }).Count -eq 0)
  Check 'race: tower gaps from F2 times; Peter row shows his last lap' ($a.rows[2].g -eq '1.4' -and $a.rows[4].g -eq '0.8' -and $a.rows[3].g -eq '1:25.100')
  Check 'race: gold on the map only at Peter' ($a.goldPx -gt 50 -and $a.goldFar -eq 0)
  $honest = Ev "(function(){ clearInterval(__feed); var o = []; L.lapDirty = true; L.why = Object.assign(newWhy(), { joined: true }); var m = Drive.build(); o.push(m.delta.v + '|' + m.delta.s); L.lapDirty = false; L.why = newWhy(); Drive.offLap = L.v.LapCompleted; m = Drive.build(); o.push(m.delta.v + '|' + m.delta.s); Drive.offLap = null; L.v.LapDeltaToBestLap_OK = false; m = Drive.build(); o.push(m.delta.v + '|' + m.delta.s); L.v.LapDeltaToBestLap_OK = true; return JSON.stringify(o); })()" | ConvertFrom-Json
  $d = [char]0x2014; $dot = [char]0xB7
  Check 'incomplete (out) lap shows no delta even when iRacing has one' ($honest[0] -eq "$d|out lap $dot no delta")
  Check 'a lap with an off-track moment shows no delta' ($honest[1] -eq "$d|off track $dot no delta")
  Check 'iRacing delta not valid shows no delta' ($honest[2] -eq "$d|no delta yet $dot no delta")
  $leader = Ev "(function(){ var f = JSON.parse(JSON.stringify(__state.frame)); var me = f.PlayerCarIdx; var g3 = []; for (var i = 0; i < 64; i++) if (S.drivers.get(i) && S.drivers.get(i).classId === S.drivers.get(me).classId) g3.push(i); g3.forEach(function(i){ if (f.CarIdxClassPosition[i] < f.CarIdxClassPosition[me]) { f.CarIdxClassPosition[i]++; } }); f.CarIdxClassPosition[me] = 1; onFrame(f); var m = Drive.build(); onFrame(__state.frame); return JSON.stringify({ lbl: m.gap.lbl, s: m.gap.s, pos: m.pos.v }); })()" | ConvertFrom-Json
  Check 'leading the class: the cell becomes GAP BEHIND / leading' ($leader.lbl -eq 'Gap behind' -and $leader.s -eq 'leading')
  $garage = Ev "(function(){ var f = Object.assign({}, __state.frame, { IsOnTrack: false }); onFrame(f); Drive.tick(performance.now() + 1e6); var off = !Drive.shown && document.getElementById('drive').hidden; onFrame(__state.frame); Drive.at = 0; Drive.tick(performance.now() + 2e6); return off && Drive.shown; })()"
  Check 'out of the car (garage) the old grid shows; back in the car Drive returns' ($garage -eq $true)
  $tv = Ev "(function(){ Tv.set(true); var h = document.getElementById('tvHero'), m = document.getElementById('dMap'), a = h.getBoundingClientRect(), b = m.getBoundingClientRect(), placed = Tv.place(); var r = JSON.stringify({ on: document.body.classList.contains('tv-on'), shown: getComputedStyle(h).display !== 'none', map: getComputedStyle(document.getElementById('dMapCv')).visibility, same: Math.abs(a.left - b.left) < 1 && Math.abs(a.top - b.top) < 1 && Math.abs(a.width - b.width) < 1 && Math.abs(a.height - b.height) < 1, placed: placed, band: getComputedStyle(document.getElementById('dBand')).display !== 'none' }); Tv.set(false); return r; })()" | ConvertFrom-Json
  Check 'TV VIEW puts the camera exactly in the map slot; band and tower stay' ($tv.on -and $tv.shown -and $tv.map -eq 'hidden' -and $tv.same -and $tv.placed -and $tv.band)
  $recw = Ev "(function(){ var o = []; var t = function(d){ Tower.showRec(d); var e = document.getElementById('dRec'); o.push((e.hidden ? 'hidden' : e.textContent.trim()) + '|' + e.className); }; t({ capture: { state: 'paused-disk' } }); t({ capture: { state: 'starting' } }); t({ capture: { state: 'stalled' } }); t(null); t({ capture: { state: 'off' } }); t({ capture: { state: 'recording', secs: 3725 } }); return JSON.stringify(o); })()" | ConvertFrom-Json
  Check 'REC pill words: paused amber, starting amber, stalled red, unknown amber, off hidden, hours' (($recw -join ';') -eq 'REC PAUSED: DISK FULL|warn;REC STARTING|warn;NOT RECORDING|bad;RECORDING UNKNOWN|warn;hidden|;REC 1:02:05|')

  # ---------- pit lane ----------
  Section '3. pit lane'
  Load-State 'pit'; $a = Audit; Shot (Join-Path $shots 'drive-pit.png')
  Common 'pit' $a
  Check 'pit: the delta cell becomes PIT LANE 43 mph, limit 45 mph, limiter on' ($a.delta.lbl -eq 'Pit lane' -and $a.delta.v -eq '43mph' -and $a.delta.s -eq "limit 45 mph $([char]0xB7) limiter on" -and $a.delta.sCls -notmatch 'warn')
  Check 'pit: Peter tower row says PIT and shows no lap' ($a.rows[3].me -and $a.rows[3].pit -and $a.rows[3].nm -eq 'Peter AdamisPIT' -and $a.rows[3].g -eq '')
  $met = Ev "(function(){ clearInterval(__feed); L.v.EngineWarnings = 0; var m1 = Drive.build(); Units.metric = true; var m = Drive.build(); Units.metric = false; return JSON.stringify({ off: m1.delta.s, scls: m1.delta.scls, v: m.delta.v, s: m.delta.s, fuel: m.fuel.s }); })()" | ConvertFrom-Json
  Check 'pit: limiter off turns amber' ($met.off -match 'limiter off$' -and $met.scls -eq 'warn')
  Check "metric iRacing shows km/h and litres instead, never both ($($met.v) / $($met.fuel))" ($met.v -match 'km/h' -and $met.s -match '^limit 72 km/h' -and $met.fuel -match ' L to finish$' -and $met.fuel -notmatch 'gal')

  # ---------- stale ----------
  Section '4. stale data'
  Load-State 'stale'; $a = Audit; Shot (Join-Path $shots 'drive-stale.png')
  Common 'stale' $a
  Check "stale: amber age at the top ('$($a.staleText)')" ($a.staleText -match '^No data for \d+ s$' -and $a.stale)
  Check 'stale: values grey, no gold anywhere on the map' ($a.valueColor -eq 'rgb(93, 90, 84)' -and $a.goldPx -eq 0)
  $gone = Ev "(function(){ L.lastFrameAt = performance.now() - 61000; Drive.tick(performance.now() + 1e6); return !Drive.shown; })()"
  Check 'a feed frozen for a minute gives the screen back to HOME' ($gone -eq $true)

  # ---------- not recording ----------
  Section '5. not recording'
  Load-State 'norec'; $a = Audit; Shot (Join-Path $shots 'drive-norec.png')
  Common 'norec' $a
  Check 'not recording: red NOT RECORDING pill' ($a.rec.text -eq 'NOT RECORDING' -and $a.rec.cls -eq 'bad' -and -not $a.rec.hidden)

  # ---------- unknowns and no outline ----------
  Section '6. just joined, nothing known yet'
  Load-State 'fresh'; $a = Audit; Shot (Join-Path $shots 'drive-fresh.png')
  Common 'fresh' $a
  Check 'unknown values are an em dash, never 0' ($a.pos.v -eq $d -and $a.gap.v -eq $d -and $a.delta.v -eq $d -and $a.fuel.v -eq $d -and $a.foot -eq "Last $d $dot Best $d")
  Check 'unknown reasons in words' ($a.gap.s -eq 'no timed lap yet' -and $a.delta.s -eq 'no best lap yet' -and $a.fuel.s -eq 'after one clean lap')
  Section '7. no track outline'
  Load-State 'nooutline'
  $no = Ev "(function(){ var cv = document.getElementById('dMapCv'), g = cv.getContext('2d'), arcs = 0, texts = [], a = g.arc, t = g.fillText; g.arc = function(){ arcs++; return a.apply(this, arguments); }; g.fillText = function(s){ texts.push(String(s)); return t.apply(this, arguments); }; Drive.drawMap(cv, Drive.mapCars(), { stale: false, multi: true }); g.arc = a; g.fillText = t; return JSON.stringify({ arcs: arcs, texts: texts }); })()" | ConvertFrom-Json
  Shot (Join-Path $shots 'drive-nooutline.png')
  Check "no outline: one status line ('$($no.texts -join ' ')') and no car dots" ($no.arcs -eq 0 -and $no.texts.Count -eq 1 -and $no.texts[0].Length -gt 0)
  Section '8. old grid on request'
  Load-State 'race' '?grid=1'
  Check '?grid=1 keeps the old grid for old tests' ((Ev 'Drive.shown') -eq $false)
}
catch { $script:fail++; "  FAIL  $($_.Exception.Message)" }
finally {
  try { $ws.Dispose() } catch { }; Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$prof*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }; Start-Sleep -Milliseconds 300; Remove-Item -LiteralPath $prof -Recurse -Force -ErrorAction SilentlyContinue
}
"$pass ok, $fail FAIL"
if ($fail -gt 0) { exit 1 }
