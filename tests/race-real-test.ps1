# race-real-test.ps1 (W2-5) - offline: THE RACE SCREEN fed with Peter's REAL race of 14 Nov 21:27 (Road Atlanta, GR86, 18 cars on the grid),
# replayed at 20x into dash\www\v2\race.html in headless Chrome. Nothing reaches irdash (no port at all: the page gets a stand-in data.js).
#   The feed: tests\tools\race-real-timeline.cs rebuilds what irdash sent that night from two finished files: the .ibt (his car) and
#   irdash's field log vault\field\f20261114-212650-2.json (every other car, logged live); the race part is irdash's RacePart with
#   the real fuel tracker (dash\src\fuel.cs). One entry per second of sim time, played at 20 a second.
#   Pictures: tests\shots\rework\race-real<tag>-<moment>.png (formation, start, every race minute, the flag) and contact sheets
#   race-real<tag>-sheet-<n>.png (four pictures each, half size). The words of every zone through the race: tests\last\race-real<tag>.txt.
#   Checks (the layout of W2-5): the standings drawn with the field, names and intervals; the split (delta) visible as a number after the
#   green; the map with every car in the world on it; the fuel line in its one format; nothing outside the screen.
#   powershell -ExecutionPolicy Bypass -File tests\race-real-test.ps1 [-Tag -before] [-NoChecks]
param([string]$Tag = '', [switch]$NoChecks)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\tools\cdp-lib.ps1')
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what $why" } }
function Section($t) { Assert-RigFree -Where $t; $t }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$lastDir = Join-Path $root 'tests\last'; New-Item -ItemType Directory -Force $lastDir | Out-Null
$ibt = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-14 21-27-47.ibt'
$fieldLog = 'C:\Users\peter\iRacingDeck\vault\field\f20261114-212650-2.json'
$outline = Join-Path $root 'dash\maps\t127-roadatlanta-full.json'
$page = 'file:///' + ((Join-Path $root 'dash\www\v2\race.html') -replace '\\', '/')
'RACE SCREEN on the real 14 Nov race (W2-5)'
if (-not (Test-Path $ibt) -or -not (Test-Path $fieldLog)) { '  skip the 14 Nov race files are not on this PC'; '0 passed, 0 failed.'; exit 0 }
if (-not (Test-Path $outline)) { $outline = 'C:\Users\peter\iRacingDeck\dash\maps\t127-roadatlanta-full.json' }

$tmp = Join-Path $env:TEMP "race-real-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  Section '0. the feed from the two files'
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $exe = Join-Path $tmp 'timeline.exe'
  $out = & $csc /nologo /target:exe "/out:$exe" /r:System.Web.Extensions.dll (Join-Path $root 'tests\tools\race-real-timeline.cs') (Join-Path $root 'dash\src\fuel.cs') (Join-Path $root 'dash\src\lapstore.cs') (Join-Path $root 'dash\src\ibtfile.cs') 2>&1
  ok 'the timeline builder compiles with irdash''s own fuel.cs (C# 5, Windows csc)' (Test-Path $exe) (($out | Where-Object { $_ -match 'error' }) -join '; ')
  $tl = Join-Path $tmp 'tl.js'
  $p = New-Object Diagnostics.ProcessStartInfo $exe; $p.Arguments = '"' + $ibt + '" "' + $fieldLog + '" "' + $tl + '"'
  $p.UseShellExecute = $false; $p.RedirectStandardOutput = $true; $p.CreateNoWindow = $true
  $pr = [Diagnostics.Process]::Start($p); try { $pr.PriorityClass = 'BelowNormal'; $pr.ProcessorAffinity = [IntPtr]3 } catch { }
  $said = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
  "  info $($said.Trim())"
  ok 'the feed was built (one entry a second of sim time)' ((Test-Path $tl) -and $said -match 'entries (\d+)' -and [int]$Matches[1] -gt 1000)

  $stub = @'
(function () {
  var ls = { state: [], frame: [] };
  window.__req = [];
  // the map's one fetch: Road Atlanta's outline from dash\maps (the shape irdash's /trackmap sends); nothing else answers
  window.fetch = function (u) {
    window.__req.push(String(u));
    if (/^\/trackmap\?/.test(String(u))) return new Promise(function (res) { var x = new XMLHttpRequest(); x.open('GET', '__OUTLINE__'); x.onload = function () { res(new Response(x.responseText, { status: 200, headers: { 'Content-Type': 'application/json' } })); }; x.onerror = function () { res(new Response('{}', { status: 404 })); }; x.send(); });
    return Promise.reject(new Error('no network in this test'));
  };
  window.data = { __paddock: true, state: {}, seq: 0, online: true, set: '',
    get rig() { return { driving: true, sessionOn: true, simRunning: true, online: true }; },
    at: function () { return 0; }, on: function (n, f) { (ls[n] = ls[n] || []).push(f); return function () { }; },
    telemetry: function (v) { window.data.set = typeof v === 'string' ? v : ''; },
    json: function (u) { return window.fetch(u); }, fetch: function (u) { return window.fetch(u); }, reloadOnVersion: function () { }, onList: function () { } };
  window.__push = function (m) { var ch = {}; for (var k in m) { window.data.state[k] = m[k]; ch[k] = true; } window.data.seq++; ls.state.forEach(function (f) { f(window.data.state, ch); }); };
  window.__frame = function (v) { ls.frame.forEach(function (f) { f(v); }); };
  document.addEventListener('DOMContentLoaded', function () { if (window.RacePage) window.RacePage.flagFrom = function () { return ''; }; });
  // the replay: one entry every 50 ms (20x), stops at each mark for its picture
  window.__play = function (marks) {
    var E = window.__tl.entries; window.__i = 0; window.__marks = marks; window.__paused = ''; window.__done = false;
    window.__push({ session: window.__tl.session });
    clearInterval(window.__timer);
    window.__timer = setInterval(function () {
      if (window.__paused) { window.__frame(E[Math.max(0, window.__i - 1)].v); return; }       // the feed keeps coming while the picture is taken
      if (window.__i >= E.length) { window.__done = true; clearInterval(window.__timer); return; }
      var e = E[window.__i++]; window.__cur = e;
      window.__push({ race: e.race }); window.__frame(e.v);
      if (window.__marks.length && e.t >= window.__marks[0].t) window.__paused = window.__marks.shift().name;
    }, 50);
  };
  // every zone's words while it plays (innerText: only what is on screen), a line each time they change
  window.__log = []; window.__seen = {};
  setInterval(function () {
    if (!window.__cur || !document.getElementById('race')) return;
    var z = ['zA', 'zB', 'zC', 'zD'].map(function (id) { var e = document.getElementById(id); return e ? e.innerText.replace(/\s+/g, ' ').trim() : ''; });
    var rows = [].slice.call(document.querySelectorAll('#eRows .row')).filter(function (r) { return !r.hidden; });
    var k = z.join(' | ') + ' | E ' + rows.length + ' rows';
    var shape = k.replace(/[0-9]/g, '9');        // a new line only when the words change, not every number
    if (!window.__seen[shape]) { window.__seen[shape] = 1; window.__log.push(window.__cur.t.toFixed(0) + ' s  ' + k); }
  }, 260);
  window.__peek = function () {
    var vis = function (el) { if (!el || el.hidden) return false; var r = el.getBoundingClientRect(); if (r.width < 1 || r.height < 1) return false; var cs = getComputedStyle(el); return cs.visibility !== 'hidden' && cs.display !== 'none' && +cs.opacity > 0.05; };
    var txt = function (id) { var e = document.getElementById(id); return e && vis(e) ? e.innerText.replace(/\s+/g, ' ').trim() : ''; };
    var out = [];
    var walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walk.nextNode()) { var n = walk.currentNode, el = n.parentElement; if (!n.nodeValue.trim() || !vis(el)) continue; var r = el.getBoundingClientRect(); if (r.left < 0 || r.top < 0 || r.right > 1920.5 || r.bottom > 1080.5) out.push(n.nodeValue.trim()); }
    var rows = [].slice.call(document.querySelectorAll('#eRows .row')).filter(function (r) { return !r.hidden; }).map(function (r) {
      return { cls: r.className, p: r.children[0].textContent, n: r.children[1].textContent, nm: r.children[2].textContent, iv: r.children[3].textContent }; });
    var M = window.RacePage && window.RacePage.map;
    return { t: window.__cur.t, race: window.__cur.race, A: txt('zA'), B: txt('zB'), C: txt('zC'), D: txt('zD'), rows: rows, out: out,
      fuel: txt('cFuel'), split: txt('dNum'), splitVis: vis(document.getElementById('dNum')),
      map: M ? { status: M.status, cars: (window.RacePage.mapCars || []).length, inWorld: window.__cur.v.CarIdxLapDistPct.filter(function (p) { return p >= 0; }).length } : null };
  };
})();
'@
  $stub = $stub.Replace('__OUTLINE__', ('file:///' + ($outline -replace '\\', '/')))

  Section '1. the race, at 20x'
  Cdp-Open 'about:blank' -Port 9397 -Extra @('--allow-file-access-from-files')
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $stub }
  $null = Cdp 'Page.navigate' @{ url = $page }
  $up = $false; for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 150; if ((Cdp-Eval '!!(window.RacePage && RacePage.slots.length)') -eq $true) { $up = $true; break } }
  ok 'race.html started with the stand-in data.js' $up
  $null = Cdp-Eval ("(() => { const s = document.createElement('script'); s.src = '" + ('file:///' + ($tl -replace '\\', '/')) + "'; document.head.appendChild(s); return 1; })()")
  ok 'the feed is loaded into the page' (Wait-Until '!!window.__tl' 20)
  $green = [double](Cdp-Eval '__tl.greenT')
  $marks = @(@{ t = 150; name = 'formation' }, @{ t = $green + 8; name = 'start' })
  for ($m = 1; $m -le 15; $m++) { $marks += @{ t = $green + 60 * $m; name = ('m{0:00}' -f $m) } }
  $marks += @{ t = 1214; name = 'flag' }
  $null = Cdp-Eval ('__play(' + ($marks | ConvertTo-Json -Compress) + '); 1')
  $looks = [ordered]@{}; $pics = @()
  while ($true) {
    $st = Cdp-Json '({ p: window.__paused || "", d: !!window.__done })'
    if ($st.d) { break }
    if ($st.p) {
      Start-Sleep -Milliseconds 800              # two draws (4 a second) and the 250 ms hold on a changed gap
      $l = Cdp-Json '__peek()'; $looks[$st.p] = $l
      $png = Join-Path $shots "race-real$Tag-$($st.p).png"; Cdp-Shot $png; $pics += $png
      "  info $($st.p) at $([math]::Round($l.t)) s: A '$($l.A)' | B '$($l.B)' | C '$($l.C)' | D '$($l.D)' | E $(@($l.rows).Count) rows"
      $null = Cdp-Eval 'window.__paused = ""; 1'
    } else { Start-Sleep -Milliseconds 120 }
  }
  $log = Cdp-Json 'window.__log'
  $logFile = Join-Path $lastDir "race-real$Tag.txt"
  [IO.File]::WriteAllLines($logFile, [string[]]$log)
  "  info every different screen through the race: $(@($log).Count) lines in tests\last\race-real$Tag.txt"
  ok "a picture at every mark ($($pics.Count) of $($marks.Count))" ($pics.Count -eq $marks.Count)

  # contact sheets: four pictures at half size on one 1920 x 1080 sheet, so all of them can be looked at
  Add-Type -AssemblyName System.Drawing
  $n = 0
  for ($s = 0; $s -lt $pics.Count; $s += 4) {
    $n++; $bmp = New-Object Drawing.Bitmap 1920, 1080; $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::Black)
    for ($k = 0; $k -lt 4 -and $s + $k -lt $pics.Count; $k++) {
      $im = [Drawing.Image]::FromFile($pics[$s + $k]); $g.DrawImage($im, ($k % 2) * 960, [math]::Floor($k / 2) * 540, 960, 540); $im.Dispose()
      $g.DrawString([IO.Path]::GetFileNameWithoutExtension($pics[$s + $k]), (New-Object Drawing.Font 'Segoe UI', 14), [Drawing.Brushes]::Magenta, ($k % 2) * 960 + 6, [math]::Floor($k / 2) * 540 + 4)
    }
    $g.Dispose(); $bmp.Save((Join-Path $shots "race-real$Tag-sheet-$n.png")); $bmp.Dispose()
  }
  "  info $n contact sheets: tests\shots\rework\race-real$Tag-sheet-1..$n.png"

  if (-not $NoChecks) {
    Section '2. what the screen showed (the W2-5 layout)'
    $fuelRx = '^FUEL( \d+(\.\d)? L)?( · \d+(\.\d)? LAPS)?( · [+−]\d+(\.\d)?)?$|^FUEL \d/3 LAPS$|^PIT · \d+(\.\d)? L$'
    $racing = @($looks.Keys | Where-Object { $_ -ne 'formation' -and $_ -ne 'flag' })
    $bad = @(); $badD = @(); $badF = @(); $badM = @(); $badO = @()
    foreach ($k in $racing) {
      $l = $looks[$k]; $cars = @($l.rows | Where-Object { $_.cls -match '^row( me)?( pit)?$' })
      $me = @($cars | Where-Object { $_.cls -match '\bme\b' })
      $named = @($cars | Where-Object { $_.nm -match '\w' -and $_.n -match '^#\d+$' })
      $ivs = @($cars | Select-Object -Skip 1 | Where-Object { $_.iv -match '^\+\d+\.\d$|^\+\d+ laps?$' })
      if ($cars.Count -lt 10 -or $me.Count -ne 1 -or $named.Count -ne $cars.Count -or $ivs.Count -lt $cars.Count - 2 -or ($l.race.pos -and $me[0].p -ne [string]$l.race.pos)) { $bad += "$k ($($cars.Count) cars, me P$($me[0].p) vs race P$($l.race.pos), $($ivs.Count) intervals)" }
      if (-not $l.splitVis -or $l.split -notmatch '^[+−]\d+\.\d\d$') { $badD += "$k ('$($l.split)')" }
      if ($l.fuel -cnotmatch $fuelRx) { $badF += "$k ('$($l.fuel)')" }
      if (-not $l.map -or $l.map.status -ne 'ready' -or $l.map.cars -ne $l.map.inWorld) { $badM += "$k ($($l.map | ConvertTo-Json -Compress))" }
      if (@($l.out).Count) { $badO += "$k ($(@($l.out) -join ', '))" }
    }
    ok "E: at every race minute the standings show 10+ cars with number, name and interval, YOU's row at the race part's position" ($bad.Count -eq 0) ($bad -join '; ')
    ok "D: the split (delta to his best) is the big number at every race minute" ($badD.Count -eq 0) ($badD -join '; ')
    ok "C: the fuel line is one line of numbers at every race minute ($(($racing | ForEach-Object { $looks[$_].fuel } | Select-Object -Unique) -join ' / '))" ($badF.Count -eq 0) ($badF -join '; ')
    ok 'C: the map is drawn with every car in the world on it' ($badM.Count -eq 0) ($badM -join '; ')
    ok 'nothing outside 1920 x 1080' ($badO.Count -eq 0) ($badO -join '; ')
    $f = $looks['formation']
    ok "formation lap: the map and the field are up before the green ($(@($f.rows).Count) rows, map $($f.map.status))" (@($f.rows).Count -ge 10 -and $f.map.status -eq 'ready')
    ok "the map's outline came from one /trackmap fetch, nothing else was asked for ($(Cdp-Eval 'window.__req.join(" ")'))" ((Cdp-Eval 'window.__req.length === 1 && /^\/trackmap\?key=t127-roadatlanta-full&id=127$/.test(window.__req[0])') -eq $true)
  }
} catch {
  $script:fail++; "  FAIL  the test stopped: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))"
} finally {
  Cdp-Close
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"$($script:pass) passed, $($script:fail) failed."
if ($script:fail -gt 0 -or $script:pass -eq 0) { exit 1 }
