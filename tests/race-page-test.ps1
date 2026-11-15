# race-page-test.ps1 - offline: THE RACE SCREEN (W2-2; dash\www\v2\race.html, race.css, dash\www\app\pages\race.js) and the switch
# that puts it over every page (W3-1: the shell's driving guard, dash\www\app\shell.js; it was v2\ui.js RaceSwitch). Headless Chrome only; the pretend irdash on 8311 (never 8199; 8299 is often busy with other builders' tests).
#   1. every state from fixtures (tests\fixtures\race\*.json, the W2-1 contract): one picture each in tests\shots\rework\race-<state>.png;
#      nothing under 24 px on screen, the zones where PLAN 4.2 puts them, nothing outside 1920 x 1080
#   2. no flicker: a gap or interval changes at most 4 times a second and only when its tenth changes (DOM text changes counted)
#   3. the standings: the order is the stream's CarIdxClassPosition at three moments; YOU is the gold row; the class leader is
#      pinned when YOU is far down; PIT chips follow CarIdxOnPitRoad; class header only in a multiclass race
#   4. the fuel line for fuel.state measuring / ok / short / save, stale, caution, pit road, gallons (W2-5: zone C is the map with
#      one line of fuel numbers; the pit-window bar and its words went; the map's one /trackmap is the only fetch)
#   5. on the 12 Nov replay through the pretend irdash at 20x: requests besides the stream at most 1 a second
#   6. the switch: rig.driving true -> the race screen covers HOME (the stream asks for the race set); 5 s after it ends HOME is back;
#      ?race=1 shows it directly
#   powershell -ExecutionPolicy Bypass -File tests\race-page-test.ps1
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
$fxDir = Join-Path $root 'tests\fixtures\race'
$page = 'file:///' + ((Join-Path $root 'dash\www\v2\race.html') -replace '\\', '/')
'RACE SCREEN test (W2-2)'

# ---------------- the stand-in for data.js and a pretend field of 22 cars ----------------
$fx = @{}
foreach ($f in Get-ChildItem $fxDir -Filter *.json) { $fx[$f.BaseName] = [IO.File]::ReadAllText($f.FullName) }
$fxJs = '{' + (($fx.Keys | Sort-Object | ForEach-Object { '"' + $_ + '":' + $fx[$_] }) -join ',') + '}'
# the stand-in for data.js and a pretend field of 19 cars: tests/tools/race-stub.js (tests/copy-lint-test.ps1 uses it too)
$stub = [IO.File]::ReadAllText((Join-Path $tools 'race-stub.js'), [Text.Encoding]::UTF8)
$stub = $stub.Replace('__FX__', $fxJs).Replace('__OUTLINE__', ('file:///' + ((Join-Path $root 'dash\maps\t127-roadatlanta-full.json') -replace '\\', '/')))

function Open-Fixture() {
  # a fresh page with the stand-in data.js, before any of the page's own scripts
  $null = Cdp 'Page.navigate' @{ url = 'about:blank' }; Start-Sleep -Milliseconds 200
  $null = Cdp 'Page.navigate' @{ url = $page }
  for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 100; if ((Cdp-Eval '!!(window.RacePage && RacePage.slots.length === 12)') -eq $true) { return } }
  throw 'race.html did not start'
}
function Look() { return Cdp-Json '__look()' }
function Shot($state) { $p = Join-Path $shots "race-$state.png"; Cdp-Shot $p; ok "picture tests\shots\rework\race-$state.png" (Test-Path $p) }
function Common($state, $l) {
  ok "$state : nothing on screen under 24 px" ($l.small.Count -eq 0) ($l.small -join '; ')
  ok "$state : nothing outside 1920 x 1080" ($l.out.Count -eq 0) ($l.out -join '; ')
}

$pret = $null
function Get-J($u) { try { Invoke-RestMethod -Uri $u -TimeoutSec 5 } catch { $null } }
function Push-Part($part, $json) { $null = Get-J ("http://localhost:8312/__push?part=$part&json=" + [uri]::EscapeDataString($json)) }
$driveOn = '{"driving":true,"sessionOn":true,"simRunning":true,"online":true}'; $driveOff = '{"driving":false,"sessionOn":true,"simRunning":true,"online":true}'
$dash = [string][char]0x2013
try {
  Cdp-Open 'about:blank' -Extra @('--allow-file-access-from-files')      # the map is an ES module (lib/map.js): file:// needs this
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $stub }

  # ------------------------------------------------------------------ 1 + 4. every state from fixtures
  Section '1. every state from the fixtures (with 4. the fuel zone)'
  Open-Fixture
  $null = Cdp-Eval "__push({ session: __fx['session-single'], race: __fx['race-green'], rig: { driving: true } }); __run({ mePos: 4 }); 1"
  Start-Sleep -Milliseconds 1500
  $l = Look
  Common 'green' $l
  ok 'green: the zones sit where PLAN 4.2 puts them (A 24,24,1872,96 / B 24,136,912,288 / C 24,440,912,360 / D 24,816,912,240 / E 952,136,944,920)' `
    ($l.boxes.A -eq '24,24,1872,96' -and $l.boxes.B -eq '24,136,912,288' -and $l.boxes.C -eq '24,440,912,360' -and $l.boxes.D -eq '24,816,912,240' -and $l.boxes.E -eq '952,136,944,920') ($l.boxes | ConvertTo-Json -Compress)
  ok "green: the strip says P4 of 19, lap 31/52, 4x / 17 ($($l.A.pos) $($l.A.of) | $($l.A.mid) | $($l.A.inc))" ($l.A.pos -eq 'P4' -and $l.A.of -eq 'of 19' -and $l.A.mid -eq 'Lap 31/52' -and $l.A.inc -eq '4x / 17' -and -not $l.A.incNear -and $l.A.cls -eq '')
  ok "green: the strip's P4 is YOU's row ($(@($l.rows | Where-Object { $_.cls -match '\bme\b' })[0].p))" (@($l.rows | Where-Object { $_.cls -match '\bme\b' })[0].p -eq '4')
  ok "green: the session clock ($($l.A.clock))" ($l.A.clock -eq '1:02:33')
  ok "green: AHEAD and BEHIND with the gap, number and name ($($l.B.ahead) | $($l.B.behind))" ($l.B.ahead -match '^Ahead\s*−1\.4.*#19\s*Okafor' -and $l.B.behind -match '^Behind\s*\+1\.4.*#22\s*Lindqvist')
  ok "4. fuel ok (W2-5): one line, the tank, laps of fuel and irdash's spare in green ($($l.C.fuel))" ($l.C.fuel -eq 'FUEL 55.0 L · 23.8 LAPS · +2.8' -and $l.C.lastColor -eq $l.tok.gain)
  ok "green (W2-5): the map with every car on it, his gold, the leader ringed ($($l.C.map), $($l.C.cars) cars, me $($l.C.me), lead $($l.C.lead))" ($l.C.map -eq 'ready' -and $l.C.canvas -and $l.C.cars -eq 19 -and $l.C.me -eq 1 -and $l.C.lead -eq 1)
  ok "green: last lap, best, the delta bar and the split -0.21 in green ($($l.D.last) / $($l.D.best) / $($l.D.num))" ($l.D.last -eq '1:33.832' -and $l.D.best -eq '1:33.412' -and $l.D.bar -and $l.D.num -eq '−0.21' -and $l.D.numColor -eq $l.tok.gain -and $l.D.lastColor -eq $l.tok.ink)
  ok "green: the key message's place (x 540-1380, y 1012-1070, keymsg.css) covers no text for its 4 s ($($l.km -join ', '))" ($l.km.Count -eq 0)
  ok 'green: ten rows, no class header in a one-class race' ($l.rows.Count -eq 10 -and @($l.rows | Where-Object { $_.cls -match 'head' }).Count -eq 0) ($l.rows.Count)
  ok "green: the page asked irdash for nothing but the map's one /trackmap ($($l.req) other, $($l.mapReq) map)" ($l.req -eq 0 -and $l.mapReq -eq 1)
  ok "green: its own connection would ask for the race set ('$($l.set)')" ($l.set -eq 'race')
  Shot 'green'

  # the fuel states (4): W2-5 made zone C the map with ONE fuel line (Peter: "fuel is way too much text"); the pit-window bar and its
  # words went (no room in a 24 px line beside the numbers); the spare's colour says short / save / enough
  foreach ($fs in 'short', 'save', 'measuring', 'restale') {
    $null = Cdp-Eval "__push({ race: __fx['race-$fs'] }); 1"; Start-Sleep -Milliseconds 700
    $l = Look; Common "fuel $fs" $l
    switch ($fs) {
      'short' {
        ok "4. fuel short: the spare −11.3 in red ($($l.C.fuel))" ($l.C.fuel -eq 'FUEL 22.4 L · 9.7 LAPS · −11.3' -and $l.C.lastColor -eq $l.tok.loss)
        Shot 'fuel-short'
      }
      'save' {
        ok "4. fuel save (within a lap): the spare +0.6 in amber ($($l.C.fuel))" ($l.C.fuel -eq 'FUEL 49.9 L · 21.6 LAPS · +0.6' -and $l.C.lastColor -eq $l.tok.amber)
        Shot 'fuel-save'
      }
      'measuring' {
        ok "4. fuel measuring: 'FUEL 2/3 LAPS' ($($l.C.fuel))" ($l.C.fuel -eq 'FUEL 2/3 LAPS')
        ok "measuring: the last lap is purple when it is the best ($($l.D.last))" ($l.D.lastColor -eq $l.tok.purple)
        Shot 'fuel-measuring'
      }
      'restale' {
        ok "4. after a refuel (fuel.stale): the old numbers, greyed ($($l.C.fuel))" ($l.C.fuel -eq 'FUEL 55.0 L · 23.8 LAPS · +2.8' -and $l.C.cls -match 'restale' -and $l.C.lastColor -eq $l.tok.dim)
        Shot 'fuel-remeasuring'
      }
    }
  }

  # caution
  $null = Cdp-Eval "__push({ race: __fx['race-caution'] }); __run({ mePos: 4, lap: 33, pit: [3, 6] }); 1"; Start-Sleep -Milliseconds 900
  $l = Look; Common 'caution' $l
  ok "caution: CAUTION in amber in the strip ($($l.A.mid))" ($l.A.mid -match '^Caution · Lap 33/52$' -and $l.raceCls -match 'caution')
  ok "caution: the incident chip turns amber within 3 of the limit ($($l.A.inc))" ($l.A.inc -eq '15x / 17' -and $l.A.incNear)
  ok "caution: B is the gap to the leader ($($l.B.one))" ($l.B.one -match '^To leader\s*\+4\.1' -and -not $l.B.aVis)
  ok "caution: C says PIT NOW with the litres still to go in and the litres in ($($l.C.fuel))" ($l.C.fuel -eq 'PIT NOW · 24 L · HAVE 22 L' -and $l.C.firstColor -eq $l.tok.amber)
  ok "caution: D fades ($($l.D.op))" ([double]$l.D.op -lt 0.5)
  $ivs = @($l.rows | Select-Object -Skip 1 | ForEach-Object { $_.iv })
  ok "caution: E shows the gap to the leader ($($ivs -join ' '))" ($ivs[0] -eq '+1.4' -and $ivs[1] -eq '+2.7' -and $ivs[3] -eq '+5.5')
  $pits = @($l.rows | Where-Object { $_.pit } | ForEach-Object { $_.n })
  ok "caution: PIT chips on the cars on pit road ($($pits -join ' '))" (($pits -join ',') -eq '#19,#28')
  Shot 'caution'

  # on pit road: B says PIT ROAD and the limiter (race part), D folds away, C's line is PIT and the tank; the rejoin ghost; gallons
  $pitCases = [ordered]@{
    'pit' = @("__push({ race: __fx['race-pit'] }); __run({ mePos: 4, lap: 34, pit: [2] });", 'Limiter on')
    'pit-rejoin' = @("__push({ race: __fx['race-pit-rejoin'] }); __run({ mePos: 4, lap: 34, pit: [2] });", 'Limiter off')
    'pit-rejoin-far' = @("__push({ race: __fx['race-pit-rejoin-far'] }); __run({ mePos: 15, lap: 34, pit: [2] });", 'Limiter on')
    'gallons' = @("__push({ race: __fx['race-gallons'] }); __run({ mePos: 4, lap: 34, pit: [2] });", 'Limiter on')
  }
  foreach ($ps in $pitCases.Keys) {
    $null = Cdp-Eval ($pitCases[$ps][0] + ' 1'); Start-Sleep -Milliseconds 900
    $l = Look; Common $ps $l
    ok "$ps : B says pit road and the limiter, D folds away ($($l.B.one))" ($l.B.one -match ('^Pit road\s*' + $pitCases[$ps][1] + '$') -and -not $l.B.aVis -and -not $l.D.vis)
    $tankWant = if ($ps -eq 'gallons') { 'PIT · 5.9 GAL' } else { 'PIT · 22.4 L' }
    ok "$ps : C's line is the fuel in the tank ($($l.C.fuel))" ($l.C.fuel -eq $tankWant)
    $ghost = @($l.rows | Where-Object { $_.cls -match 'ghost' })
    $flags = @($l.rows | ForEach-Object { $_.cls -match 'ghost' }); $i = [array]::IndexOf($flags, $true)
    $ps2 = @($l.rows | ForEach-Object { $_.p }) -join ' '
    switch ($ps) {
      'pit' { ok 'pit: no ghost row before the pit loss is measured (rejoin null)' ($ghost.Count -eq 0) }
      'gallons' { ok 'gallons (units imperial): GAL with one decimal' ($ghost.Count -eq 0); Shot 'gallons' }
      'pit-rejoin' { ok "pit-rejoin: the ghost row 'Rejoin P7' sits between P6 and P7 ($ps2)" ($ghost.Count -eq 1 -and $ghost[0].nm -eq 'Rejoin P7' -and $ghost[0].p -eq '' -and $l.rows[$i + 1].p -eq '7' -and $l.rows[$i - 1].p -eq '6') }
      'pit-rejoin-far' { ok "pit-rejoin-far: the window centres on P17 (leader, cut, P12..P16, ghost, P17..P19) and keeps the ghost ($ps2)" ($ghost.Count -eq 1 -and $l.rows[$i + 1].p -eq '17' -and $l.rows[$l.rows.Count - 1].p -eq '19' -and $l.rows[1].cls -match 'cut' -and $l.rows[2].p -eq '12'); Shot 'pit-rejoin-far' }
    }
    if ($ps -ne 'pit-rejoin-far') { ok "$ps : his own row is grey with a PIT chip" (@($l.rows | Where-Object { $_.cls -match '\bme\b' -and $_.cls -match 'pit' -and $_.pit }).Count -eq 1) }
    if ($ps -eq 'pit' -or $ps -eq 'pit-rejoin') { Shot $ps }
  }

  # practice and qualifying: the layout from the session type (the server fills toGo and spare there too), the lap list, the time left
  foreach ($pq in 'practice', 'qualifying') {
    $laps = if ($pq -eq 'practice') { '[{n:5,t:94.863,dirty:false},{n:6,t:93.919,dirty:false},{n:7,t:94.933,dirty:true},{n:8,t:93.832,dirty:false},{n:9,t:93.920,dirty:false}]' } else { '[{n:1,t:93.512,dirty:false}]' }
    $run = if ($pq -eq 'practice') { '__run({ mePos: 6, lap: 10, lc: 9, sessNum: 0, timeRemain: 1214.5 })' } else { '__run({ mePos: 3, lap: 2, lc: 1, sessNum: 1, timeRemain: 252 })' }
    $null = Cdp-Eval "$run; __push({ race: __fx['race-$pq'] }); RacePage.laps = $laps; 1"; Start-Sleep -Milliseconds 900
    $l = Look; Common $pq $l
    $lr = @($l.rows | Where-Object { $_.cls -match 'lapr' -and $_.cls -notmatch 'thead' })
    if ($pq -eq 'practice') {
      ok "practice: B is his best only, no optimal ($($l.B.one))" ($l.B.one -match '^Best\s*1:33\.832$')
      ok "practice: E is the lap list, newest first, with the gap to the best ($(($lr | ForEach-Object { $_.p + ' ' + $_.n + ' ' + $_.nm }) -join ' / '))" ($lr.Count -eq 5 -and $lr[0].p -eq 'Lap 9' -and $lr[0].nm -eq '+0.088' -and $lr[1].nm -eq 'Best' -and $lr[1].cls -match 'best')
      ok "practice: the strip says the time left from SessionTimeRemain ($($l.A.mid))" ($l.A.mid -eq 'Practice · 20:14 left')
      ok "practice: the fuel line has no spare (nothing to finish) even with spare and toGo filled ($($l.C.fuel))" ($l.C.fuel -eq 'FUEL 52.4 L · 22.7 LAPS')
    } else {
      ok "qualifying: B is the best ($($l.B.one))" ($l.B.one -match '^Best\s*1:33\.512$')
      ok 'qualifying: one lap in the list, purple as the best' ($lr.Count -eq 1 -and $lr[0].cls -match 'best')
      ok "qualifying: the strip shows the time left ($($l.A.mid); P$($l.A.pos))" ($l.A.mid -eq 'Qualifying · 4:12 left' -and $l.A.pos -eq 'P3')
    }
    Shot $pq
  }
  # a new session (SessionNum) clears this session's laps
  $null = Cdp-Eval "__run({ mePos: 3, lap: 1, lc: 0, sessNum: 2, timeRemain: 252 }); 1"; Start-Sleep -Milliseconds 700
  $l = Look
  ok "3. a session change (SessionNum 1 -> 2) clears the lap list ($(@($l.rows | ForEach-Object { $_.nm }) -join ' | '))" ((Cdp-Eval 'RacePage.laps.length') -eq 0 -and @($l.rows | Where-Object { $_.cls -match 'lapr' -and $_.cls -notmatch 'thead' }).Count -eq 0)

  # a timed race: the clock in the strip; the fuel line's spare is against the fuel module's laps to go
  $null = Cdp-Eval "__push({ race: __fx['race-timed'] }); __run({ mePos: 4, lap: 12, timeRemain: 1330 }); 1"; Start-Sleep -Milliseconds 900
  $l = Look; Common 'timed' $l
  ok "timed race: the strip says the time left, not a lap count ($($l.A.mid))" ($l.A.mid -eq 'Lap 12 · 22:10 left')
  ok "timed race: the fuel line ($($l.C.fuel))" ($l.C.fuel -eq 'FUEL 42.0 L · 18.2 LAPS · +4.2')
  Shot 'timed'

  # multiclass, Peter far down his class: a class header; 10 cars fit
  Open-Fixture
  $null = Cdp-Eval "__push({ session: __fx['session-multi'], race: __fx['race-multiclass'] }); __run({ mePos: 18, multi: true }); 1"; Start-Sleep -Milliseconds 1200
  $l = Look; Common 'multiclass' $l
  ok "multiclass: one class header row ($(@($l.rows | Where-Object { $_.cls -match 'head' })[0].p))" (@($l.rows | Where-Object { $_.cls -match 'head' }).Count -eq 1 -and $l.rows[0].p -eq 'GT3 · 10 cars')
  $cars = @($l.rows | Where-Object { $_.cls -match '^row( me)?( pit)?$' })
  ok "multiclass: only his class, 10 cars fit, so no cut: P1..P10 with YOU at P9 ($(($cars | ForEach-Object { $_.p }) -join ' '))" ($cars[0].p -eq '1' -and @($l.rows | Where-Object { $_.cls -match 'cut' }).Count -eq 0 -and (($cars | ForEach-Object { $_.p }) -join ' ') -eq '1 2 3 4 5 6 7 8 9 10')
  ok "multiclass: the strip shows the class position, and YOU's row agrees ($($l.A.pos) $($l.A.cls))" ($l.A.cls -eq 'Class P9/10' -and $l.A.pos -eq 'P18' -and @($l.rows | Where-Object { $_.cls -match '\bme\b' })[0].p -eq '9')
  Shot 'multiclass'
  $null = Cdp-Eval "__push({ race: __fx['race-pit-rejoin-multi'] }); __run({ mePos: 18, multi: true, pit: [2] }); 1"; Start-Sleep -Milliseconds 900
  $l = Look; Common 'pit-rejoin-multi' $l
  $flags = @($l.rows | ForEach-Object { $_.cls -match 'ghost' }); $i = [array]::IndexOf($flags, $true)
  ok "multiclass on pit road: header, leader, cut, P3..P9, the ghost before P10, nothing dropped ($(@($l.rows | ForEach-Object { if ($_.cls -match 'ghost') { 'GHOST' } else { $_.p } }) -join ' '))" ($i -gt 0 -and $l.rows[$i + 1].p -eq '10' -and $l.rows[0].cls -match 'head' -and $l.rows[2].cls -match 'cut' -and $l.rows.Count -eq 12)
  Shot 'pit-rejoin-multi'

  # 3. standings order at three moments, YOU gold, pinned leader, PIT chips
  Section '3. standings'
  Open-Fixture
  $null = Cdp-Eval "__push({ session: __fx['session-single'], race: __fx['race-green'] }); 1"
  $moments = @(@{ order = '__order(4)'; pit = '[]' }, @{ order = '[3,1,2,0,8,4,5,6,7,9,10,11,12,13,14,15,16,17,18]'; pit = '[0, 5]' }, @{ order = '__order(15)'; pit = '[14]' })
  $mi = 0
  foreach ($m in $moments) {
    $mi++
    $null = Cdp-Eval "__run({ order: $($m.order), pit: $($m.pit) }); 1"; Start-Sleep -Milliseconds 800
    $l = Look
    $want = Cdp-Json "(() => { const v = __field({ order: $($m.order) }), o = []; for (let i = 0; i < 19; i++) o.push(i); o.sort((a, b) => v.CarIdxClassPosition[a] - v.CarIdxClassPosition[b]); return o.map(i => __fx['session-single'].DriverInfo.Drivers[i].CarNumber); })()"
    $cars = @($l.rows | Where-Object { $_.cls -match '^row( me)?( pit)?$' })
    $shown = @($cars | ForEach-Object { $_.n.TrimStart('#') })
    $pos = @($cars | ForEach-Object { [int]$_.p })
    $exp = @($pos | ForEach-Object { $want[$_ - 1] })
    ok "3. moment $mi : the rows are the stream's CarIdxClassPosition order ($($pos -join ' ') = $($shown -join ' '))" (($shown -join ',') -eq ($exp -join ',') -and $shown.Count -eq 10)
    $me = @($cars | Where-Object { $_.cls -match '\bme\b' })
    ok "3. moment $mi : YOU is the one gold row, 1.3x tall ($($me.Count), $($me[0].h) px, $($me[0].color))" ($me.Count -eq 1 -and $me[0].n -eq '#3' -and $me[0].color -eq $l.tok.gold -and $me[0].h -eq 104)
    $pitWant = Cdp-Json "(() => $($m.pit).map(i => '#' + __fx['session-single'].DriverInfo.Drivers[i].CarNumber))()"
    $pitGot = @($cars | Where-Object { $_.pit } | ForEach-Object { $_.n })
    $pitShown = @($pitWant | Where-Object { $shown -contains $_.TrimStart('#') })
    ok "3. moment $mi : PIT chips follow CarIdxOnPitRoad ($($pitGot -join ' '))" (($pitGot -join ',') -eq ($pitShown -join ','))
    if ($mi -eq 3) {
      ok "3. YOU in P15: the leader pinned on top, a visible cut ('$($l.rows[1].p)'), then P11..P19 ($($pos -join ' '))" ($pos[0] -eq 1 -and $l.rows[1].cls -match 'cut' -and $l.rows[1].p -eq '···' -and (($pos | Select-Object -Skip 1) -join ' ') -eq '11 12 13 14 15 16 17 18 19')
      ok "3. iRacing's duplicate-name digits are dropped ('Sam Whitaker11' shows as '$(($cars | Select-Object -Last 1).nm)')" (($cars | Select-Object -Last 1).nm -eq 'Whitaker')
      Shot 'far'
    }
  }
  # two cars swap: each row's interval follows its car in the same pass
  $ordA = '[0,1,5,2,3,4,6,7,8,9,10,11,12,13,14,15,16,17,18]'; $ordB = '[0,1,5,2,4,3,6,7,8,9,10,11,12,13,14,15,16,17,18]'
  $null = Cdp-Eval "__run({ order: $ordA, f2: { 3: 5.48, 4: 6.0 } }); 1"; Start-Sleep -Milliseconds 1200
  $null = Cdp-Eval "__run({ order: $ordB, f2: { 4: 5.0, 3: 6.9 } }); 1"; Start-Sleep -Milliseconds 330
  $l = Look
  $ok5 = @($l.rows | Where-Object { $_.nm -eq 'Lindqvist' })[0]; $ok6 = @($l.rows | Where-Object { $_.nm -eq 'Okafor' })[0]
  ok "3. two cars swap: one draw later each row shows its own car's interval (P$($ok5.p) Lindqvist $($ok5.iv), P$($ok6.p) Okafor $($ok6.iv))" ($ok5.p -eq '5' -and $ok5.iv -eq '+0.9' -and $ok6.p -eq '6' -and $ok6.iv -eq '+1.9')

  # flag flash (caught mid-flash), a flag already out when the screen comes up, no data, feed frozen
  Section '1. flag flash, no data, feed frozen'
  $null = Cdp-Eval "__run({ mePos: 4 }); 1"; Start-Sleep -Milliseconds 600
  $null = Cdp-Eval "window.__flag = 'blue'; 1"; Start-Sleep -Milliseconds 700
  $l = Look; Common 'flag' $l
  ok "flag: a new flag gives the strip its colour and its name (blue = cyan, '$($l.A.mid)')" ($l.stripCls -match 'flash f-blue' -and $l.stripBg -eq $l.tok.cyan -and $l.A.mid -eq 'Blue flag')
  Shot 'flag'
  Start-Sleep -Milliseconds 1700
  $l = Look
  ok "flag: 2 s later the strip is back to normal while the flag is still out ($($l.stripCls))" ($l.stripCls -eq 'zone strip')
  $null = Cdp-Eval "window.__shown = false; RacePage.shownFrom = () => window.__shown; window.__flag = 'yellow'; 1"; Start-Sleep -Milliseconds 700
  $null = Cdp-Eval "window.__shown = true; 1"; Start-Sleep -Milliseconds 700
  $l = Look
  ok "flag: a flag already out when the screen comes up does not flash ($($l.stripCls))" ($l.stripCls -eq 'zone strip')
  $null = Cdp-Eval "RacePage.shownFrom = null; window.__flag = ''; 1"

  Open-Fixture
  Start-Sleep -Milliseconds 700
  $l = Look; Common 'nodata' $l
  ok "no data: every zone shows the dash in its place, never blank; the strip says 'Waiting' ($($l.texts))" ($l.A.pos -eq $dash -and $l.A.mid -eq 'Waiting' -and $l.B.ahead -match $dash -and $l.B.behind -match $dash -and $l.C.fuel -eq 'FUEL' -and $l.D.last -eq $dash -and $l.D.best -eq $dash -and $l.raceCls -match 'nodata')
  ok "no data: E says so in its place ($(@($l.rows).Count) row)" (@($l.rows).Count -ge 1 -and $l.rows[0].nm -eq $dash)
  Shot 'nodata'

  $null = Cdp-Eval "__push({ session: __fx['session-single'], race: __fx['race-green'] }); __run({ mePos: 4 }); 1"; Start-Sleep -Milliseconds 1000
  $null = Cdp-Eval "__stop(); RacePage.frameAt = performance.now() - 11500; 1"; Start-Sleep -Milliseconds 600
  $l = Look; Common 'frozen' $l
  ok "frozen: the screen stays, greyed, and says 'No data 12s' ($($l.A.clock))" ($l.raceCls -match 'stale' -and $l.A.clock -eq 'No data 12s' -and $l.A.pos -eq 'P4' -and @($l.rows).Count -eq 10)
  Shot 'frozen'

  # ------------------------------------------------------------------ 2. no flicker
  Section '2. no flicker (10 s, gaps moving 20x)'
  Open-Fixture
  $null = Cdp-Eval "__push({ session: __fx['session-single'], race: __fx['race-green'] }); __run({ mePos: 4, wobble: 0.6, rate: 20 }); 1"
  Start-Sleep -Milliseconds 800
  $null = Cdp-Eval @'
(() => { window.__mut = {}; const watch = (key, el) => { window.__mut[key] = []; let last = el.textContent;
  new MutationObserver(() => { const t = el.textContent; if (t !== last) { window.__mut[key].push({ at: performance.now(), from: last, to: t }); last = t; } }).observe(el, { childList: true, characterData: true, subtree: true }); };
  watch('ahead', document.querySelector('#bAhead .g-n')); watch('behind', document.querySelector('#bBehind .g-n'));
  document.querySelectorAll('#eRows .row .iv').forEach((el, i) => watch('iv' + i, el));
  window.__tenths = 0; const t0 = performance.now(); let prev = null;
  window.__probe = setInterval(() => { const v = __field(Object.assign({ t: (performance.now() - t0) / 1000 }, window.__o)); const g = (v.CarIdxF2Time[2] - v.CarIdxF2Time[window.__order(4)[2]]).toFixed(1); if (g !== prev) window.__tenths++; prev = g; }, 66);
  return 1; })()
'@
  Start-Sleep -Seconds 10
  $mut = Cdp-Json "(() => { clearInterval(window.__probe); return { m: window.__mut, tenths: window.__tenths }; })()"
  $worst = 0; $badTenth = 0; $total = 0; $keys = 0
  foreach ($p in $mut.m.PSObject.Properties) {
    $ev = @($p.Value); if (-not $ev.Count) { continue }; $keys++; $total += $ev.Count
    for ($i = 0; $i -lt $ev.Count; $i++) {
      $n = 1; for ($j = $i + 1; $j -lt $ev.Count -and ($ev[$j].at - $ev[$i].at) -lt 1000; $j++) { $n++ }
      if ($n -gt $worst) { $worst = $n }
      $a = $ev[$i].from -replace '[^\d.]', ''; $b = $ev[$i].to -replace '[^\d.]', ''
      if ($a -ne '' -and $b -ne '' -and $a -eq $b) { $badTenth++ }
    }
  }
  "  info $total text changes over $keys gap and interval cells in 10 s; the frames changed the tenth of one gap $($mut.tenths) times"
  ok "2. no gap or interval changed more than 4 times in any second (worst $worst)" ($worst -le 4 -and $total -gt 20)
  ok "2. none changed without its tenth changing ($badTenth)" ($badTenth -eq 0)
  ok "2. the screen held back: the frames moved the tenth $($mut.tenths) times in 10 s, the ahead gap was written $(@($mut.m.ahead).Count) times" (@($mut.m.ahead).Count -le 40 -and $mut.tenths -gt @($mut.m.ahead).Count)
  Cdp-Close

  # ------------------------------------------------------------------ 5 + 6. the pretend irdash: the replay and the switch
  Section '5-6. the 12 Nov replay through the pretend irdash'
  $race = Join-Path $root 'tests\fixtures\race-12nov.ibt'
  if (-not (Test-Path $race)) { '  skip tests\fixtures\race-12nov.ibt is not here (tests\tools-test.ps1 builds it)' }
  else {
    & (Join-Path $tools 'pretend-irdash.ps1') -Port 8311 -Stop | Out-Null
    $null = & (Join-Path $tools 'pretend-irdash.ps1') -Port 8311 -Ibt $race -Speed 20 -Www (Join-Path $root 'dash\www') -Loop
    $pret = $true
    $racing = 'ShellRace.on && !document.getElementById("raceHost").hidden && Shell.cur === ""'
    $atHome = '!ShellRace.on && document.getElementById("raceHost").hidden && Shell.cur === "home"'
    Cdp-Open 'http://localhost:8311/app/index.html?intro=0' -Port 9393
    ok 'the shell is up on the pretend irdash (one stream, the session from the 12 Nov file)' (Wait-Until 'window.Shell && data.online && !!data.state.session' 15)
    ok 'not driving: HOME shows, the race screen does not' ((Cdp-Eval $atHome) -eq $true)
    ok 'the race page is loaded in its frame and borrows HOME''s connection' (Wait-Until '(() => { const w = document.getElementById("raceFrame").contentWindow; return !!(w.RacePage && w.data && w.data.__borrowed); })()' 10)
    Push-Part 'rig' $driveOn
    $t0 = Get-Date
    $on = Wait-Until $racing 5
    $took = [math]::Round(((Get-Date) - $t0).TotalMilliseconds)
    ok "6. rig.driving true with fresh frames: the race screen covers HOME ($took ms after the push)" ($on -and $took -lt 1500)
    ok "6. the one stream now asks for the race set ($(Cdp-Eval 'data.url'))" (Wait-Until '/[?&]set=race/.test(data.url) && data.set === "race"' 5)
    ok '6. the race page gets the race set''s frames through HOME (CarIdxClassPosition and SessionNum in, Speed not; the .ibt has no IsReplayPlaying)' (Wait-Until '(() => { const v = document.getElementById("raceFrame").contentWindow.RacePage.v; return !!(v && "CarIdxClassPosition" in v && "SessionNum" in v && !("Speed" in v)); })()' 6)
    Start-Sleep -Seconds 3
    $null = Cdp-Eval '(() => { const w = document.getElementById("raceFrame").contentWindow; w.__mut = {}; w.document.querySelectorAll("#race b, #race span, #race .iv, #race .g-n").forEach((el, i) => { let last = el.textContent; w.__mut[i] = []; new w.MutationObserver(() => { if (el.textContent !== last) { last = el.textContent; w.__mut[i].push(performance.now()); } }).observe(el, { childList: true, characterData: true, subtree: true }); }); return 1; })()'
    $null = Get-J 'http://localhost:8312/__reset'
    Start-Sleep -Seconds 20
    $s = Get-J 'http://localhost:8312/__stats'
    $n = 0; $by = @(); foreach ($p in $s.routes.PSObject.Properties) { if ($p.Name -eq '/stream') { continue }; $n += $p.Value.count; $by += "$($p.Name) x$($p.Value.count)" }
    $opens = $(if ($s.routes.'/stream') { $s.routes.'/stream'.count } else { 0 }); $n += $opens
    $rate = [math]::Round($n / 20, 2)
    "  info driving on the replay: $n requests in 20 s besides the open stream ($($by -join ', ')), $opens stream opens, $($s.frames) frames"
    ok "5. requests besides the stream while driving: $rate / s (ceiling 1)" ($rate -le 1)
    $worst = Cdp-Eval '(() => { const w = document.getElementById("raceFrame").contentWindow; let worst = 0; for (const k in w.__mut) { const a = w.__mut[k]; for (let i = 0; i < a.length; i++) { let n = 1; for (let j = i + 1; j < a.length && a[j] - a[i] < 1000; j++) n++; if (n > worst) worst = n; } } return worst; })()'
    ok "2. on the 20x replay no text on the race screen changed more than 4 times in a second (worst $worst)" ([int]$worst -le 4)
    Cdp-Shot (Join-Path $shots 'race-replay.png'); ok 'picture tests\shots\rework\race-replay.png' $true
    $rp = Cdp-Json '(() => { const d = document.getElementById("raceFrame").contentDocument; return { pos: d.getElementById("aPos").textContent, of: d.getElementById("aOf").textContent, ahead: d.querySelector("#bAhead .g-n").textContent }; })()'
    ok "the replay (only his own car in the file's arrays): his position and the entry list, never 'Leading' ($($rp.pos) $($rp.of), ahead '$($rp.ahead)')" ($rp.of -eq 'of 19' -and $rp.ahead -ne 'Leading')

    # 1 (review): the screen needs a fresh frame, irdash answering and no replay, not only rig.driving
    $null = Cdp-Eval 'window.__realOnFrame = ShellRace.frame; ShellRace.frame = function () { }; 1'          # frames stop reaching the shell (a hung sim)
    ok '6. a stale frame (hung sim) with rig.driving still true: HOME is back (3 s stale + 5 s)' (Wait-Until $atHome 12)
    $null = Cdp-Eval 'ShellRace.frame = window.__realOnFrame; 1'
    ok '6. frames again: the race screen is back' (Wait-Until $racing 5)
    $null = Cdp-Eval 'ShellRace.frame = function (v) { window.__realOnFrame.call(ShellRace, Object.assign({}, v, { IsReplayPlaying: 1 })); }; 1'
    ok '6. a replay in the sim (IsReplayPlaying): HOME is back after 5 s' (Wait-Until $atHome 9)
    $null = Cdp-Eval 'ShellRace.frame = window.__realOnFrame; 1'
    ok '6. out of the replay: the race screen is back' (Wait-Until $racing 5)
    $null = Get-J 'http://localhost:8312/__fault?mode=down'
    ok '6. irdash down: HOME is back after 5 s (it can say "Paddock program not running")' (Wait-Until "$atHome && !data.online" 12)
    $null = Get-J 'http://localhost:8312/__fault?mode=ok'
    ok '6. irdash back: the race screen is back' (Wait-Until $racing 20)

    Push-Part 'rig' $driveOff
    Start-Sleep -Seconds 3
    ok '6. 3 s after driving ends: still the race screen (a tow or a reset does not flick it)' ((Cdp-Eval 'ShellRace.on && !document.getElementById("raceHost").hidden') -eq $true)
    ok '6. about 5 s after it ends HOME is back' (Wait-Until $atHome 4)
    ok "6. and the stream asks for the shell's four channels again ($(Cdp-Eval 'data.set + "|" + (data.vars || []).join()'))" (Wait-Until 'data.set === "" && (data.vars || []).join() === "SessionFlags,IsReplayPlaying,IsOnTrack,SessionNum"' 5)
    Cdp-Close
    # ?race=1: straight to the race screen (tests, previews) whatever the rig says
    Cdp-Open 'http://localhost:8311/app/index.html?intro=0&race=1' -Port 9394
    ok '6. ?race=1 shows the race screen with rig.driving false' (Wait-Until 'window.ShellRace && ShellRace.on && !document.getElementById("raceHost").hidden' 8)
    Cdp-Close
    # 12 (review): irdash already says driving when the page starts: idle stream, then straight to the race set (two opens, not three)
    Push-Part 'rig' $driveOn
    $null = Get-J 'http://localhost:8312/__reset'
    Cdp-Open 'http://localhost:8311/app/index.html?intro=0' -Port 9396
    $null = Wait-Until $racing 10
    Start-Sleep -Seconds 3
    $s = Get-J 'http://localhost:8312/__stats'
    $opens = $(if ($s.routes.'/stream') { $s.routes.'/stream'.count } else { 0 })
    ok "6. driving at the first frame: the stream opened $opens times (idle, then the race set; no HOME-variables stream in between) ($(Cdp-Eval 'data.url'))" ($opens -eq 2 -and (Cdp-Eval 'data.set') -eq 'race')
    Cdp-Close
    # a guest drive keeps Friends mode's own view
    Push-Part 'guest' '{"active":true}'
    Cdp-Open 'http://localhost:8311/app/index.html?intro=0' -Port 9395
    Start-Sleep -Seconds 4
    ok '6. Friends mode on: no race screen (the guest view is theirs)' ((Cdp-Eval '!ShellRace.on && data.rig.driving && !!(data.state.guest && data.state.guest.active)') -eq $true)
    Cdp-Close
  }
} catch {
  $script:fail++; "  FAIL  the test stopped: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))"
} finally {
  Cdp-Close
  if ($pret) { & (Join-Path $tools 'pretend-irdash.ps1') -Port 8311 -Stop | Out-Null }
}
"$($script:pass) passed, $($script:fail) failed."
if ($script:fail -gt 0 -or $script:pass -eq 0) { exit 1 }
