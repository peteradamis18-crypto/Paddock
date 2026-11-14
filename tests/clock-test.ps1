# clock-test.ps1 - offline: the dial (W3-2, dash\www\app\lib\clock.js). Headless Chrome on a copy of dash\www\app served by the
# pretend irdash on 8321 (ES modules do not load from file://; never 8199, and 8297-8312 are other builders' tests).
#   1. a fixed time (10:08:30) puts the hour, minute and seconds hands at the right angles (pixels sampled on each hand, and
#      where the hand must NOT be); the seconds hand sweeps (10:08:30.5 is half a degree on, not a tick)
#   2. the ring at 0, 0.5, 1 and null; the readout text under 12
#   3. nothing is drawn while document.hidden, drawing resumes when visible; unmount stops it and removes the canvas
#   4. one frame costs under 1 ms (average of 100)
#   5. no colour literal in the new files (and tests\design-lint-test.ps1 passes)
#   pictures: tests\shots\rework\clock-<state>.png
#   powershell -ExecutionPolicy Bypass -File tests\clock-test.ps1
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
$port = 8321
'CLOCK test (W3-2)'

# a throw-away web root: the real app folder (copied each run) and one harness page
$www = Join-Path $env:TEMP ('w32-clock-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path $www 't') | Out-Null
Copy-Item -Recurse (Join-Path $root 'dash\www\app') (Join-Path $www 'app')
$harness = @'
<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="../app/design.css"></head>
<body><div id="c" style="position:absolute;left:600px;top:120px;width:720px;height:720px"></div>
<script type="module">
import { Clock } from '../app/lib/clock.js';
window.Clock = Clock;
// what the dial shows at a point: the angle in degrees from 12, clockwise, and the radius in css px from the centre
window.__px = function (deg, r) {
  var h = Clock.current, cv = h.cv, k = cv.width / 720, a = deg * Math.PI / 180;
  var x = Math.round((360 + r * Math.sin(a)) * k), y = Math.round((360 - r * Math.cos(a)) * k);
  var d = cv.getContext('2d').getImageData(x, y, 1, 1).data; return [d[0], d[1], d[2], d[3]];
};
window.__tok = function (k) { var e = document.createElement('i'); e.style.color = 'var(' + k + ')'; document.body.appendChild(e);
  var m = getComputedStyle(e).color.match(/[\d.]+/g).map(Number); e.remove(); return m; };
window.__near = function (p, t, tol) { return Math.abs(p[0] - t[0]) <= tol && Math.abs(p[1] - t[1]) <= tol && Math.abs(p[2] - t[2]) <= tol && p[3] > 200; };
// ink hands have a shaded facet (ink with a quarter of black over it), so ink gets a wider tolerance than gold
window.__is = function (deg, r, k) { return __near(__px(deg, r), __tok(k), k === '--ink' ? 70 : 40); };
window.__at = function (h, m, s, ms) { Clock.now = function () { return new Date(2026, 10, 14, h, m, s, ms || 0); }; };
// light pixels in the readout's box under 12 (x 170-550, y 150-290)
window.__light = function () { var cv = Clock.current.cv, k = cv.width / 720, d = cv.getContext('2d').getImageData(170 * k, 150 * k, 380 * k, 140 * k).data, n = 0;
  for (var i = 0; i < d.length; i += 4) if (d[i] > 110 && d[i + 3] > 200) n++; return n; };
window.__ready = true;
</script></body></html>
'@
[IO.File]::WriteAllText((Join-Path $www 't\clock.html'), $harness, (New-Object Text.UTF8Encoding($false)))

function Shot($name) { $p = Join-Path $shots "clock-$name.png"; Cdp-Shot $p; ok "picture tests\shots\rework\clock-$name.png" (Test-Path $p) }
function Shot-Dial($name) {
  # the dial alone at full size, for a close look at the drawing
  $s = Cdp 'Page.captureScreenshot' @{ format = 'png'; clip = @{ x = 600; y = 120; width = 720; height = 720; scale = 1 } }
  $p = Join-Path $shots "clock-$name.png"; [IO.File]::WriteAllBytes($p, [Convert]::FromBase64String($s.result.data))
  ok "picture tests\shots\rework\clock-$name.png" (Test-Path $p)
}

try {
  & (Join-Path $tools 'pretend-irdash.ps1') -Port $port -Stop | Out-Null
  $null = & (Join-Path $tools 'pretend-irdash.ps1') -Port $port -Www $www
  Cdp-Open "http://localhost:$port/t/clock.html" -Port 9441
  ok 'the harness loads the clock module' (Wait-Until 'window.__ready === true' 10)

  Section '1. the hands at 10:08:30'
  $null = Cdp-Eval "__at(10, 8, 30); Clock.mount(document.getElementById('c'), { size: 720 }); 1"
  Start-Sleep -Milliseconds 300
  # hour: (10 + 8.5/60) * 30 = 304.25 deg; minute: 8.5 * 6 = 51 deg; seconds: 30 * 6 = 180 deg
  ok 'hour hand at 304.25 deg (warm white at 120 px out)' ((Cdp-Eval '__is(304.25, 120, "--ink")') -eq $true)
  ok 'hour hand is not at 124 deg' ((Cdp-Eval '__is(124.25, 120, "--ink")') -eq $false)
  ok 'minute hand at 51 deg (warm white at 220 px out)' ((Cdp-Eval '__is(51, 220, "--ink")') -eq $true)
  ok 'minute hand is not at 231 deg' ((Cdp-Eval '__is(231, 220, "--ink")') -eq $false)
  ok 'seconds hand at 180 deg (gold at 250 px out)' ((Cdp-Eval '__is(180, 250, "--gold")') -eq $true)
  ok 'seconds hand is not at 90 deg' ((Cdp-Eval '__is(90, 250, "--gold")') -eq $false)
  ok 'seconds hand has a tail with a counterweight wider than the needle (gold 4 px off the axis at 74 px)' ((Cdp-Eval '__is(3, 74, "--gold") && __is(-3, 74, "--gold") && !__is(3, 250, "--gold")') -eq $true)
  ok 'the tail ends after the counterweight (not gold at 0 deg, 104 px)' ((Cdp-Eval '__is(0, 104, "--gold")') -eq $false)
  ok 'warm-white indices (12, 3, 9, 1 and 5 o''clock at 300 px; 6 is under the seconds hand)' ((Cdp-Json '[0, 90, 270, 30, 150].map(function (a) { return __is(a === 0 ? 2 : a, 300, "--ink") || __is(a === 0 ? -2 : a, 300, "--ink"); })') -notcontains $false)
  ok 'the quarters are longer (ink at 3 o''clock 260 px, none at 1 o''clock 260 px)' ((Cdp-Eval '__is(90, 260, "--ink") && !__is(30, 260, "--ink")') -eq $true)
  Shot '1008'
  Shot-Dial 'dial'
  $null = Cdp-Eval '__at(10, 8, 30, 500); 1'; Start-Sleep -Milliseconds 200
  ok 'the seconds hand sweeps: at 10:08:30.5 it is at 183 deg, not 180' ((Cdp-Eval '__is(183, 250, "--gold") && !__is(180, 290, "--gold")') -eq $true)

  Section '2. the ring and the readout'
  $null = Cdp-Eval '__at(10, 8, 30); Clock.set({ ring: 0 }); 1'; Start-Sleep -Milliseconds 150
  ok 'ring 0: a faint track, no gold' ((Cdp-Eval '!__is(90, 352, "--gold") && !__is(270, 352, "--gold") && __px(90, 352)[3] > 0') -eq $true)
  Shot 'ring-0'
  $null = Cdp-Eval 'Clock.set({ ring: 0.5 }); 1'; Start-Sleep -Milliseconds 150
  ok 'ring 0.5: gold from 12 to 6 clockwise (at 3), not at 9' ((Cdp-Eval '__is(90, 352, "--gold") && !__is(270, 352, "--gold")') -eq $true)
  Shot 'ring-half'
  $null = Cdp-Eval 'Clock.set({ ring: 1 }); 1'; Start-Sleep -Milliseconds 150
  ok 'ring 1: gold all round (at 3 and at 9)' ((Cdp-Eval '__is(90, 352, "--gold") && __is(270, 352, "--gold")') -eq $true)
  Shot 'ring-full'
  $null = Cdp-Eval 'Clock.set({ ring: null }); 1'; Start-Sleep -Milliseconds 150
  ok 'ring null: nothing outside the bezel' ((Cdp-Eval '__px(90, 352)[3] === 0 && __px(270, 352)[3] === 0') -eq $true)
  $before = Cdp-Eval '__light()'
  $null = Cdp-Eval '__at(10, 8, 30); Clock.set({ ring: 0.62, readout: "NEXT GREEN FLAG 1:42:09" }); 1'; Start-Sleep -Milliseconds 200
  $after = Cdp-Eval '__light()'
  ok "the readout is drawn under 12 ($before -> $after light pixels in its box)" ([int]$after -gt [int]$before + 1500)
  ok 'the readout is kept and read out (aria-label)' ((Cdp-Eval 'Clock.current.readout === "NEXT GREEN FLAG 1:42:09" && Clock.current.cv.getAttribute("aria-label") === "Clock. NEXT GREEN FLAG 1:42:09"') -eq $true)
  Shot 'readout'
  Shot-Dial 'readout-dial'
  $null = Cdp-Eval 'Clock.set({ readout: null, ring: null }); 1'

  Section '3. hidden page and unmount'
  $null = Cdp-Eval 'Clock.now = function () { return new Date(); }; 1'
  $f1 = Cdp-Eval 'Clock.current.frames'; Start-Sleep -Milliseconds 400; $f2 = Cdp-Eval 'Clock.current.frames'
  ok "it draws while visible ($f1 -> $f2 frames in 0.4 s)" ([int]$f2 -gt [int]$f1 + 5)
  ok 'the default clock is local time (Clock.now() = new Date())' ((Cdp-Eval 'Math.abs(Clock.now() - new Date()) < 50 && Clock.now().getHours() === new Date().getHours()') -eq $true)
  $null = Cdp-Eval 'window.__hid = true; Object.defineProperty(document, "hidden", { configurable: true, get: function () { return window.__hid; } }); document.dispatchEvent(new Event("visibilitychange")); 1'
  Start-Sleep -Milliseconds 100
  $h1 = Cdp-Eval 'Clock.current.frames'; Start-Sleep -Milliseconds 600; $h2 = Cdp-Eval 'Clock.current.frames'
  ok "nothing is drawn while document.hidden ($h1 -> $h2 frames in 0.6 s)" ($h1 -eq $h2)
  $null = Cdp-Eval 'window.__hid = false; document.dispatchEvent(new Event("visibilitychange")); 1'
  Start-Sleep -Milliseconds 400; $h3 = Cdp-Eval 'Clock.current.frames'
  ok "drawing resumes when visible again ($h2 -> $h3)" ([int]$h3 -gt [int]$h2 + 5)

  Section '4. the cost of a frame'
  # the canvas records draw calls and paints later, so the honest number forces the paint (a 1-pixel read) after every frame
  $cost = Cdp-Json '(function () { var h = Clock.current, g = h.cv.getContext("2d"); h.draw(); var t = performance.now(); for (var i = 0; i < 100; i++) h.draw(); var a = (performance.now() - t) / 100;
    t = performance.now(); for (i = 0; i < 100; i++) { h.draw(); g.getImageData(360, 360, 1, 1); } var p = (performance.now() - t) / 100; return { avg: a, paint: p, loop: h.cost / h.frames }; })()'
  ok ("a frame draws in under 1 ms (average of 100: {0:N3} ms to draw, {1:N3} ms painted and read back; {2:N3} ms in the running loop)" -f $cost.avg, $cost.paint, $cost.loop) ($cost.avg -lt 1 -and $cost.paint -lt 1)
  $null = Cdp-Eval 'var __h = Clock.current; Clock.unmount(); 1'
  $u1 = Cdp-Eval '__h.frames'; Start-Sleep -Milliseconds 300; $u2 = Cdp-Eval '__h.frames'
  ok 'unmount removes the canvas and stops drawing' ((Cdp-Eval '!document.querySelector("#c canvas") && Clock.current === null') -eq $true -and $u1 -eq $u2)
  $null = Cdp-Eval 'var a = Clock.mount(document.getElementById("c"), {}); var b = Clock.mount(document.body, { size: 200 }); Clock.set({ ring: 1 }); window.__two = [a.ring, b.ring]; b.unmount(); a.unmount(); 1'
  ok 'two dials at once (start-up and HOME): Clock.set acts on the one mounted last' ((Cdp-Eval 'JSON.stringify(__two) === "[null,1]"') -eq $true)
  ok 'no script errors' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')

  Section '5. design rules'
  $hex = '(?i)(#[0-9a-f]{3,8}\b|\brgba?\s*\(|\bhsla?\s*\()'
  foreach ($f in @('dash\www\app\lib\clock.js', 'dash\www\app\pages\startup.js', 'dash\www\app\startup.css')) {
    $t = [IO.File]::ReadAllText((Join-Path $root $f))
    $t = [regex]::Replace($t, '(?s)/\*.*?\*/', ''); $t = [regex]::Replace($t, '(?m)(^|[^:"''\\])//.*$', '$1')
    ok "$f has no colour literal" (-not ([regex]::IsMatch($t, $hex)))
  }
  $lint = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\design-lint-test.ps1') 2>&1 | Out-String
  $sum = (($lint -split "`n" | Where-Object { $_ -match '\d+ passed' }) -join ' ').Trim()
  ok "tests\design-lint-test.ps1 passes ($sum)" ($lint -cnotmatch '\bFAIL\b' -and $sum -match ', 0 failed')
}
finally {
  Cdp-Close
  & (Join-Path $tools 'pretend-irdash.ps1') -Port $port -Stop | Out-Null
  Remove-Item -LiteralPath $www -Recurse -Force -ErrorAction SilentlyContinue
}
''
"clock: $script:pass ok, $script:fail FAIL"
if ($script:fail) { exit 1 }
