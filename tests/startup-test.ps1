# startup-test.ps1 - offline: the start-up (W3-2, dash\www\app\pages\startup.js + app\startup.css, using app\lib\clock.js).
# Headless Chrome on a copy of dash\www\app served by the pretend irdash on 8323 (ES modules do not load from file://; never
# 8199, and 8297-8312 are other builders' tests). Real time: the sequence is 7 s, so this test takes about a minute.
#   1. frames at 0.5 ... 7.5 s show 0, 1, 2, 3, 4, 5, 5 lights and then the dial; 'done' at 7 s +- 0.3; then the layer goes
#      away by itself; five tones of 110 Hz (30 ms up, 400 ms down, -18 dBFS), made in Web Audio: no file, no request
#   2. a key at 2 s resolves 'skipped' within 100 ms with the dial up; a pointer press skips too
#   3. quiet hours (23:00-07:00): no AudioContext is made at all; the default follows the local clock
#   4. ?hold=1 freezes on the fifth light (no dial, no end) until a key
#   5. the triggers moved from intro.js: boot "play", the SHOWCASE seq rising, never while driving, ?intro=1
#   pictures: tests\shots\rework\startup-<second>s.png, startup-skipped.png, startup-hold.png
#   powershell -ExecutionPolicy Bypass -File tests\startup-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tests\tools'
. (Join-Path $tools 'cdp-lib.ps1')
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what $why" } }
function Section($t) { Assert-RigFree -Where $t; $t }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$port = 8323
'START-UP test (W3-2)'

$www = Join-Path $env:TEMP ('w32-start-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path $www 't') | Out-Null
Copy-Item -Recurse (Join-Path $root 'dash\www\app') (Join-Path $www 'app')
$harness = @'
<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="../app/design.css"></head>
<body><div id="startup" hidden></div>
<script type="module">
import { Startup, isQuietHours } from '../app/pages/startup.js';
import { Clock } from '../app/lib/clock.js';
window.Startup = Startup; window.isQuietHours = isQuietHours; window.Clock = Clock; window.__realNow = Clock.now;
window.__ready = true;
</script></body></html>
'@
[IO.File]::WriteAllText((Join-Path $www 't\startup.html'), $harness, (New-Object Text.UTF8Encoding($false)))

# runs before the page: counts every AudioContext, oscillator and gain ramp; answers /showcase; counts requests and media
$stub = @'
(function () {
  var Real = window.AudioContext;
  window.__ac = 0; window.__osc = []; window.__ramps = []; window.__req = []; window.__media = 0;
  window.AudioContext = function () {
    window.__ac++; var c = new Real();
    var mk = c.createOscillator.bind(c), mg = c.createGain.bind(c);
    c.createOscillator = function () { var o = mk(); window.__osc.push(o); return o; };
    c.createGain = function () { var g = mg(), lin = g.gain.linearRampToValueAtTime.bind(g.gain), ex = g.gain.exponentialRampToValueAtTime.bind(g.gain), t0 = c.currentTime;
      g.gain.linearRampToValueAtTime = function (v, t) { window.__ramps.push({ kind: 'lin', v: v, dt: t - c.currentTime }); return lin(v, t); };
      g.gain.exponentialRampToValueAtTime = function (v, t) { window.__ramps.push({ kind: 'exp', v: v, dt: t - c.currentTime }); return ex(v, t); };
      return g; };
    return c;
  };
  window.webkitAudioContext = window.AudioContext;
  window.__show = { play: false, seq: 0, driving: false };
  var rf = window.fetch;
  window.fetch = function (u, o) { window.__req.push(String(u));
    if (/\/showcase/.test(String(u))) return Promise.resolve(new Response(JSON.stringify(window.__show), { headers: { 'Content-Type': 'application/json' } }));
    return rf(u, o); };
  var xo = XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open = function (m, u) { window.__req.push(String(u)); return xo.apply(this, arguments); };
  var mp = HTMLMediaElement.prototype.play; HTMLMediaElement.prototype.play = function () { window.__media++; return mp.apply(this, arguments); };
  var ls = [];
  window.__data = { __paddock: true, state: {}, rig: { driving: false }, on: function (n, f) { if (n === 'state') ls.push(f); } };
  window.__push = function (m) { var ch = {}; for (var k in m) { window.__data.state[k] = m[k]; ch[k] = true; } ls.forEach(function (f) { f(window.__data.state, ch); }); };
  window.__look = function () {
    var el = document.getElementById('startup'), d = el.querySelector('.dial');
    return { t: Math.round(performance.now() - (window.__t0 || 0)), lights: el.querySelectorAll('.light.on').length, hidden: el.hidden,
      dial: d ? +getComputedStyle(d).opacity : 0, canvas: !!el.querySelector('canvas'), cls: el.className,
      shown: [].slice.call(el.querySelectorAll('.light')).filter(function (x) { return +getComputedStyle(x).opacity > 0.5; }).length };
  };
  window.__go = function (o) { window.__res = null; window.__tres = 0; window.__t0 = performance.now();
    Startup.play(document.getElementById('startup'), o || { sound: true, quiet: false }).then(function (r) { window.__res = r; window.__tres = performance.now() - window.__t0; }); return 1; };
})();
'@

function Shot($name) { $p = Join-Path $shots "startup-$name.png"; Cdp-Shot $p; ok "picture tests\shots\rework\startup-$name.png" (Test-Path $p) }
function Cdp-Await($expr) { return (Cdp-Eval "(async function () { return JSON.stringify(await ($expr)); })()") | ConvertFrom-Json }
function At($sec) { return Cdp-Await ("new Promise(function (r) { setTimeout(function () { r(__look()); }, Math.max(0, " + [int]($sec * 1000) + " - (performance.now() - __t0))); })") }
function Open-Page($q) {
  $null = Cdp 'Page.navigate' @{ url = 'about:blank' }; Start-Sleep -Milliseconds 200
  $null = Cdp 'Page.navigate' @{ url = "http://localhost:$port/t/startup.html$q" }
  return (Wait-Until 'window.__ready === true' 10)
}
function Wait-Gone { return (Wait-Until 'document.getElementById("startup").hidden && !Startup.running' 4) }

try {
  & (Join-Path $tools 'pretend-irdash.ps1') -Port $port -Stop | Out-Null
  $null = & (Join-Path $tools 'pretend-irdash.ps1') -Port $port -Www $www
  Cdp-Open 'about:blank' -Port 9443
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $stub }
  ok 'the harness loads the start-up module' (Open-Page '')

  Section '1. the 7 s sequence, in real time'
  $res0 = Cdp-Eval 'performance.getEntriesByType("resource").length'
  $null = Cdp-Eval '__go({ sound: true, quiet: false })'
  $want = [ordered]@{ '0.5' = 0; '1.5' = 1; '2.5' = 2; '3.5' = 3; '4.5' = 4; '5.5' = 5; '6.5' = 5 }
  foreach ($s in $want.Keys) {
    $l = At ([double]$s)
    ok ("at $s s: $($want[$s]) lights (saw $($l.lights) lit, $($l.shown) visible, dial {0:N2}, at $($l.t) ms)" -f $l.dial) ($l.lights -eq $want[$s] -and $l.shown -eq $want[$s] -and $l.dial -lt 0.05 -and -not $l.hidden)
    Shot ($s + 's')
  }
  $l = At 7.5
  ok ("at 7.5 s: the lights are out and the dial is up (dial {0:N2}, canvas $($l.canvas), lights $($l.shown))" -f $l.dial) ($l.shown -eq 0 -and $l.canvas -and $l.dial -gt 0.5)
  Shot '7.5s'
  $r = Cdp-Json '({ res: window.__res, t: window.__tres })'
  ok ("the Promise resolved 'done' at 7 s +- 0.3 (" + $r.res + ' at ' + [int]$r.t + ' ms)') ($r.res -eq 'done' -and [math]::Abs($r.t - 7000) -le 300)
  ok 'the seconds hand is already sweeping on the start-up dial (frames counted)' ((Cdp-Eval 'Clock.current && Clock.current.frames > 20') -eq $true)
  ok 'the layer then fades and hides itself, the dial unmounted' (Wait-Gone)
  $snd = Cdp-Json '({ ac: __ac, osc: __osc.length, hz: __osc.map(function (o) { return o.frequency.value; }), type: __osc.map(function (o) { return o.type; }), ramps: __ramps })'
  ok "five tones in one AudioContext ($($snd.ac) context, $($snd.osc) tones)" ($snd.ac -eq 1 -and $snd.osc -eq 5)
  ok ('each tone is a 110 Hz sine (' + (($snd.hz | Select-Object -Unique) -join ',') + ' Hz, ' + (($snd.type | Select-Object -Unique) -join ',') + ')') ((@($snd.hz | Where-Object { $_ -ne 110 }).Count -eq 0) -and (@($snd.type | Where-Object { $_ -ne 'sine' }).Count -eq 0))
  $lin = @($snd.ramps | Where-Object { $_.kind -eq 'lin' }); $ex = @($snd.ramps | Where-Object { $_.kind -eq 'exp' })
  ok ("30 ms up to -18 dBFS, 400 ms down (peak {0:N4}, up {1:N3} s, down ends {2:N3} s)" -f $lin[0].v, $lin[0].dt, $ex[0].dt) ($lin.Count -eq 5 -and [math]::Abs($lin[0].v - 0.1259) -lt 0.002 -and [math]::Abs($lin[0].dt - 0.035) -lt 0.01 -and [math]::Abs($ex[0].dt - 0.435) -lt 0.01)
  $net = Cdp-Json '({ req: __req, media: __media, res: performance.getEntriesByType("resource").length })'
  ok "the tones use no file: no request, no audio element, no new resource ($(@($net.req).Count) requests, $($net.media) media, resources $res0 -> $($net.res))" (@($net.req).Count -eq 0 -and $net.media -eq 0 -and $net.res -eq $res0)

  Section '2. a key or a press skips'
  $null = Cdp-Eval '__go({ sound: true, quiet: false })'
  $null = At 2.0
  $k = Cdp-Await 'new Promise(function (r) { var t = performance.now(); window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })); var w = function () { if (window.__res) r({ res: __res, dt: performance.now() - t }); else if (performance.now() - t > 500) r({ res: null, dt: 999 }); else setTimeout(w, 5); }; w(); })'
  ok ("a key at 2 s resolves 'skipped' within 100 ms (" + $k.res + ' in ' + [int]$k.dt + ' ms)') ($k.res -eq 'skipped' -and $k.dt -lt 100)
  Start-Sleep -Milliseconds 150
  $l = Cdp-Json '__look()'
  ok ("after the skip the dial is up at once and the lights are gone (dial {0:N2}, lights $($l.shown))" -f $l.dial) ($l.canvas -and $l.dial -gt 0.99 -and $l.shown -eq 0)
  Shot 'skipped'
  ok 'it clears away after a skip' (Wait-Gone)
  $null = Cdp-Eval '__go({ sound: true, quiet: false })'
  $null = At 1.2
  $null = Cdp-Eval 'document.body.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true })); 1'; Start-Sleep -Milliseconds 100
  ok 'a pointer press skips too' ((Cdp-Eval '__res') -eq 'skipped')
  $null = Wait-Gone

  Section '3. quiet hours'
  $q = Cdp-Json '[[22, 59], [23, 0], [3, 0], [6, 59], [7, 0], [12, 0]].map(function (x) { return isQuietHours(new Date(2026, 10, 14, x[0], x[1])); })'
  ok "quiet from 23:00 to 07:00 local (22:59 23:00 03:00 06:59 07:00 12:00 -> $($q -join ' '))" (($q -join ',') -eq 'False,True,True,True,False,False')
  $null = Cdp-Eval '__ac = 0; __osc = []; __go({ sound: true, quiet: true })'
  $l = At 5.5
  ok "with quiet: five lights and no AudioContext made ($($l.shown) lights, $(Cdp-Eval '__ac') contexts, $(Cdp-Eval '__osc.length') tones)" ($l.shown -eq 5 -and (Cdp-Eval '__ac') -eq 0 -and (Cdp-Eval '__osc.length') -eq 0)
  $null = Cdp-Eval 'window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })); 1'; $null = Wait-Gone
  $null = Cdp-Eval 'Clock.now = function () { return new Date(2026, 10, 14, 23, 30); }; __ac = 0; __go({})'
  $null = At 1.3
  ok 'played with no options at 23:30: silent (the default follows the clock)' ((Cdp-Eval '__ac') -eq 0)
  $null = Cdp-Eval 'window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })); 1'; $null = Wait-Gone
  $null = Cdp-Eval 'Clock.now = function () { return new Date(2026, 10, 14, 12, 0); }; __ac = 0; __go({})'
  $null = At 1.3
  ok 'played with no options at 12:00: the tone sounds' ((Cdp-Eval '__ac') -eq 1)
  $null = Cdp-Eval 'window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })); Clock.now = __realNow; 1'; $null = Wait-Gone

  Section '4. ?hold=1'
  ok 'the harness loads with ?hold=1' (Open-Page '?hold=1')
  $null = Cdp-Eval '__go({ sound: false })'
  $l = At 8.5
  ok "at 8.5 s it still holds the fifth light: 5 lights, no dial, no end ($($l.shown) lights, canvas $($l.canvas), result $(Cdp-Eval 'String(__res)'))" ($l.shown -eq 5 -and -not $l.canvas -and (Cdp-Eval '__res') -eq $null)
  Shot 'hold'
  $null = Cdp-Eval 'window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })); 1'; Start-Sleep -Milliseconds 100
  ok 'a key still ends the hold' ((Cdp-Eval '__res') -eq 'skipped')

  Section '5. when it plays (the intro.js triggers)'
  $null = Open-Page ''
  $null = Cdp-Eval '__show = { play: false, seq: 2, driving: false }; Startup.init(document.getElementById("startup"), { data: __data }); 1'
  Start-Sleep -Milliseconds 400
  ok 'irdash says "no play" at boot: nothing plays' ((Cdp-Eval 'Startup.running') -eq $false -and (Cdp-Eval '__req.join(" ")') -match 'showcase\?who=page')
  $null = Cdp-Eval '__push({ showcase: { seq: 3, driving: false } }); 1'; Start-Sleep -Milliseconds 200
  ok 'the SHOWCASE seq rises (2 -> 3) while not driving: it plays' ((Cdp-Eval 'Startup.running') -eq $true)
  $null = Cdp-Eval 'window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })); 1'; $null = Wait-Gone
  $null = Cdp-Eval '__data.rig.driving = true; __push({ showcase: { seq: 4, driving: false } }); 1'; Start-Sleep -Milliseconds 200
  ok 'seq rises while he is driving (rig.driving): it does not play' ((Cdp-Eval 'Startup.running') -eq $false)
  $null = Cdp-Eval '__data.rig.driving = false; __push({ showcase: { seq: 5, driving: true } }); 1'; Start-Sleep -Milliseconds 200
  ok 'seq rises with showcase.driving: it does not play' ((Cdp-Eval 'Startup.running') -eq $false)
  $null = Cdp-Eval '__push({ showcase: { seq: 5, driving: false } }); 1'; Start-Sleep -Milliseconds 200
  ok 'the same seq again: it does not play' ((Cdp-Eval 'Startup.running') -eq $false)
  $null = Open-Page ''
  $null = Cdp-Eval '__show = { play: true, seq: 7, driving: false }; Startup.init(document.getElementById("startup"), { data: __data }); 1'
  Start-Sleep -Milliseconds 400
  ok 'irdash says "play" (once per boot): it plays' ((Cdp-Eval 'Startup.running') -eq $true)
  $null = Cdp-Eval 'window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })); 1'; $null = Wait-Gone
  $null = Open-Page '?intro=1'
  $null = Cdp-Eval '__show = { play: false, seq: 0, driving: false }; window.__ended = null; Startup.init(document.getElementById("startup"), { data: __data, onEnd: function (r) { window.__ended = r; } }); 1'
  Start-Sleep -Milliseconds 400
  ok '?intro=1 forces it' ((Cdp-Eval 'Startup.running') -eq $true)
  $null = Cdp-Eval 'window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" })); 1'; Start-Sleep -Milliseconds 100
  ok 'onEnd hears how it ended' ((Cdp-Eval '__ended') -eq 'skipped')
  ok 'no script errors' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')
}
finally {
  Cdp-Close
  & (Join-Path $tools 'pretend-irdash.ps1') -Port $port -Stop | Out-Null
  Remove-Item -LiteralPath $www -Recurse -Force -ErrorAction SilentlyContinue
}
''
"start-up: $script:pass ok, $script:fail FAIL"
if ($script:fail) { exit 1 }
