# deck-airace-test.ps1 (W3-4): the AI RACE screen - MY DRIVE's car / track lists and AI LEVEL folded into one screen (profile RigMyDrive).
# OFFLINE: the real add-on page (deck-intro\plugin.html with deck\keyart.js and deck\layout.json) in headless Chrome with the pretend
# Stream Deck app (tests\deck-mock.js) and pretend irdash answers; anything without a pretend answer gets {} (never the real irdash).
#   1. car / track / level / START on one page, EXIT at 7,3 (the only key that leaves), all 32 keys drawn
#   2. nothing is sent until START: opening, the level keys and the picks never start a drive; START sends one ailevel start
#   3. the level: LOW / MEDIUM / HIGH lit from /ailevel, a press lights at once and a doubled press is one request; a range shows as RANGE
#   4. kids mode: KIDS MODE IS ON, nothing sent; irdash refuses START while the kids lock is on (W3-4 review)
#   5. a doubled press right after the deck changes page lands on nothing (SOUND, OVERLAYS, FRIENDS, START, the opener itself)
#   6. in a session: the driving keys, EXIT still at 7,3; irdash not answering
#   5. words on the 3 x 2 START tile (and every multi-key tile) sit inside one key each
# Pictures: tests\shots\rework\airace-*.png
#   powershell -ExecutionPolicy Bypass -File tests\deck-airace-test.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $root 'tests\deck-fixtures.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
function Section($s) { Assert-RigFree -Where $s; ''; $s }
'AI RACE screen test (W3-4)'

$fx = @{ '/guest' = @{}; '/overlays' = @{}; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false } }
$fx['/mydrive'] = New-MyDriveFixture
$fx['/mydrive'].choice.layout = 'Full Course'
$fx['/mydrive/lists'] = @{ recent = @((New-MyDriveCombo 'r00000001' 'Chevrolet Corvette Z06 GT3.R' 'CORVETTE GT3' 'Road Atlanta' 'ROAD ATLANTA' 'Full Course' $true)); cars = @(@{ id = 'c00000001'; name = 'Chevrolet Corvette Z06 GT3.R'; short = 'CORVETTE GT3'; class = 'GT3' }); tracks = @(@{ id = 't00000001'; name = 'Road Atlanta'; short = 'ROAD ATLANTA'; layouts = @('Full Course') }) }
$fx['/ailevel'] = @{ ready = $true; mode = 'adaptive'; level = 'low'; min = 25; max = 50 }
$html = Join-Path $env:TEMP 'deck-airace-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html).Replace("['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1]];", "['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1], ['k-sound', 'com.peter.rigintro.sound', 3, 3]];").Replace("RigMyDrive: 'mydrive',", "RigMyDrive: 'mydrive', RigSound: 'sound',").Replace("return realFetch(url, opt);", "return Promise.resolve(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));")
Check 'the pretend Stream Deck app cannot reach the real irdash' (-not $h.Contains('return realFetch(url, opt);'))
[IO.File]::WriteAllText($html, $h, (New-Object Text.UTF8Encoding($false)))

$b = Start-DeckBrowser 9371
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 3
  $null = Invoke-DeckJs $page "(() => { window.__apis = []; __sd.onApi = p => window.__apis.push(p); return 1; })()"
  function Apis { @(Invoke-DeckJs $page 'window.__apis') }
  function ClearApis { $null = Invoke-DeckJs $page 'window.__apis.length = 0' }
  function Press($c, $r, $wait = 400) { $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep($wait); return 1; })()" }
  function Js($js, $wait = 300) { $null = Invoke-DeckJs $page "(async () => { $js; await __sd.sleep($wait); return 1; })()" }
  function Fx($path, $js, $wait = 300) { $null = Invoke-DeckJs $page "(async () => { const m = __sd.fx['$path']; $js; await __sd.sleep($wait); return 1; })()" }
  function Reg($c, $r) { Invoke-DeckJs $page "(() => { const r = MyDrive.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return r ? { t: r.text, s: r.sub, st: r.style, a: r.act, g: r.arg, w: r.w, h: r.h, k: !!r.key } : null; })()" }
  function Cur { Invoke-DeckJs $page '__sd.cur' }
  function Sheet($name) { $null = Invoke-DeckJs $page "(() => { const s=MyDrive; if(s.live) for(const pos of Object.keys(s.tiles)) if(s.looks[pos]) __sd.images[s.tiles[pos]]=s.encode(pos); return 1; })()"; Start-Sleep -Milliseconds 800; return Save-DeckSheet $page (Join-Path $shots "airace-$name.png") }
  function Starts { @(Apis | Where-Object { $_ -match 'c=mdstart|c=airace|c=ailevel&a=start' }) }
  function Deaf { Start-Sleep -Milliseconds 900 }   # an opener press within 0.8 s of a page change is the doubled press: wait it out

  Section '1. car / track / level / START on one page'
  ClearApis
  $m = Invoke-DeckJs $page "__sd.measureOpen('mydrive')"
  Start-Sleep -Milliseconds 1500
  Check 'AI RACE opens the RigMyDrive screen and all 32 keys get a picture' ((Cur) -eq 'RigMyDrive' -and (Sheet 'home') -eq 32)
  $car = Reg 0 1; $trk = Reg 1 1; $lay = Reg 2 1
  Check "the chosen car, track and layout each have a key ($($car.t) / $($trk.t) / $($lay.s))" ($car.t -match 'CORVETTE' -and $trk.t -eq 'ROAD ATLANTA' -and $lay.t -eq 'LAYOUT' -and $lay.s -eq 'FULL COURSE')
  Check 'the car is on the deck once (no LAST DRIVE key repeating the CAR key: RECENT starts with it)' ((Invoke-DeckJs $page "MyDrive.regions.filter(r => /CORVETTE/.test(r.text)).length") -eq 1)
  Check 'the lists are one press away on the top row: RECENT, CARS, TRACKS, FAVOURITES' ((Reg 0 0).t -eq 'RECENT' -and (Reg 1 0).t -eq 'CARS' -and (Reg 2 0).t -eq 'TRACKS' -and (Reg 3 0).t -eq 'FAVOURITES')
  $lo = Reg 1 2; $me = Reg 2 2; $hi = Reg 3 2; $rg = Reg 3 3
  Check 'the AI LEVEL row: LOW / MEDIUM / HIGH, the saved one (LOW) is gold; RANGE under HIGH says OFF' ((Reg 0 2).t -eq 'AI LEVEL' -and $lo.t -eq 'LOW' -and $lo.st -eq 'sel' -and $me.t -eq 'MEDIUM' -and $me.st -eq '' -and $hi.t -eq 'HIGH' -and $hi.a -eq 'ailevel' -and $hi.g -eq 'high' -and $rg.t -eq 'RANGE' -and $rg.s -eq 'OFF' -and $rg.g -eq 'cycle')
  $st = Reg 4 1
  Check 'START is one big green key, 3 x 2 keys, and it runs AI RACE' ($st.t -eq 'START' -and $st.st -eq 'go' -and $st.w -eq 3 -and $st.h -eq 2 -and $st.a -eq 'aistart')
  $ex = Reg 7 3
  Check 'EXIT at 7,3, drawn as the red EXIT key of every screen' ($ex.t -eq 'EXIT' -and $ex.a -eq 'exit' -and $ex.k -and (Invoke-DeckJs $page "EXIT_AT.join(',')") -eq '7,3')
  Check 'one EXIT and no other key that leaves (no BACK, no second EXIT)' ((Invoke-DeckJs $page "MyDrive.regions.filter(r => r.act === 'exit' || r.act === 'leave' || r.text === 'BACK').length") -eq 1)
  Check 'opening the screen sent nothing that starts anything (only the screen open / clear notes)' ((Starts).Count -eq 0 -and @(Apis | Where-Object { $_ -notmatch 'c=mdopen|c=mdclear' }).Count -eq 0) ((Apis) -join ' ')

  Section '2. nothing is sent until START'
  ClearApis
  Press 3 2 150; Press 3 2 400
  Check 'HIGH lights at once and a doubled press is one request (c=ailevel&a=high)' ((Reg 3 2).st -eq 'sel' -and (Reg 1 2).st -eq '' -and @(Apis | Where-Object { $_ -match 'c=ailevel&a=high' }).Count -eq 1)
  Press 0 0 400; Press 0 1 400
  Check 'RECENT, then its first drive: picks that drive (mdpick) and comes back to these keys' (@(Apis | Where-Object { $_ -match 'c=mdpick&a=r00000001' }).Count -eq 1 -and (Cur) -eq 'RigMyDrive' -and (Reg 4 1).t -eq 'START')
  Press 3 1 400
  Check 'DAMAGE is a setting, not a start' (@(Apis | Where-Object { $_ -match 'c=mddamage' }).Count -eq 1)
  Check 'after the level, a pick and DAMAGE: nothing has started a drive' ((Starts).Count -eq 0) ((Apis) -join ' ')
  $null = Sheet 'high'
  ClearApis
  $t0 = Invoke-DeckJs $page 'performance.now()'
  Js "__sd.pressTile(5, 2); await __sd.sleep(60); __sd.pressTile(4, 1)" 400
  Check 'START (pressed twice, on two of its keys) sends exactly one ailevel start, nothing else that starts' (@(Apis | Where-Object { $_ -match 'c=ailevel&a=start' }).Count -eq 1 -and (Starts).Count -eq 1) ((Apis) -join ' ')
  Check 'START stays on the screen for 0.8 s (a doubled press must not land on PAUSE / SAVE SPOT / BEST LAP CAR under it)' ((Cur) -eq 'RigMyDrive')
  Start-Sleep -Milliseconds 900
  Check '... then the deck is back on your own keys (TO THE RACE, GET OUT are there)' ((Cur) -eq 'main')

  Section '3. the level from irdash, and the RANGE key'
  Fx '/ailevel' "m.mode = 'range'; m.min = 25; m.max = 50"
  Deaf; Js "__sd.pressOpener('mydrive')" 1500
  Check 'a fixed skill range shows as RANGE 25-50 (on AI LEVEL and lit on RANGE), and none of LOW / MEDIUM / HIGH is lit' ((Reg 0 2).s -eq 'RANGE 25-50' -and (Reg 3 3).s -eq '25-50' -and (Reg 3 3).st -eq 'sel' -and (Reg 1 2).st -eq '' -and (Reg 2 2).st -eq '' -and (Reg 3 2).st -eq '')
  $null = Sheet 'range'
  ClearApis; Press 3 3 150; Press 3 3 400
  Check 'RANGE steps the presets (c=ailevel&a=cycle), once for a doubled press' (@(Apis | Where-Object { $_ -match 'c=ailevel&a=cycle' }).Count -eq 1)
  ClearApis; Press 2 2 400
  Check 'one press on MEDIUM goes back to adaptive MEDIUM (lit at once)' ((Reg 2 2).st -eq 'sel' -and @(Apis | Where-Object { $_ -match 'c=ailevel&a=medium' }).Count -eq 1)
  Press 7 3 700
  Fx '/ailevel' "for (const k of Object.keys(m)) delete m[k]"
  Deaf; Js "MyDrive.lvl = null; MyDrive.lvlAt = 0; __sd.pressOpener('mydrive')" 1500
  Check 'irdash without the AI level (an older dashboard): the level keys are dim and do nothing, START still works' ((Reg 0 2).s -eq 'NOT READY' -and (Reg 1 2).st -eq 'dim' -and -not (Reg 1 2).a -and -not (Reg 3 3).a -and (Reg 4 1).a -eq 'aistart')
  Fx '/ailevel' "Object.assign(m, { ready: true, mode: 'adaptive', level: 'low', min: 25, max: 50 })"
  Fx '/mydrive' "m.choice.has = false; m.recent = []"
  Js "MyDrive.view = 'home'; MyDrive.local = {}; MyDrive.relayout()" 1200
  Check 'no car chosen and no drive before: START is dim and says CHOOSE A CAR; LAYOUT shows a dash, not an old layout' ((Reg 4 1).st -eq 'dim' -and -not (Reg 4 1).a -and (Reg 2 1).s -eq ([string][char]0x2014))
  $null = Sheet 'nochoice'
  Fx '/mydrive' "m.choice.has = true"
  Press 7 3 700

  Section '4. kids mode: the screen says so and sends nothing'
  Fx '/ailevel' "m.kids = true"
  ClearApis
  Deaf; Js "MyDrive.lvlAt = 0; __sd.pressOpener('mydrive')" 1500
  Check 'kids lock on: the screen says KIDS MODE IS ON, the only key is EXIT' ((Reg 0 0).t -eq 'KIDS MODE IS ON' -and (Invoke-DeckJs $page "MyDrive.regions.filter(r => r.act && r.act !== 'exit').length") -eq 0)
  $null = Sheet 'kids'
  Press 4 1 300; Press 1 2 300
  Check 'pressing where START and LOW were sends nothing' ((Starts).Count -eq 0 -and @(Apis | Where-Object { $_ -match 'c=ailevel' }).Count -eq 0) ((Apis) -join ' ')
  Press 7 3 700
  Fx '/ailevel' "m.kids = false"
  $null = Invoke-DeckJs $page "(() => { __sd.apiReply = p => /c=ailevel&a=start/.test(p) ? 'kids' : 'ok'; return 1; })()"
  Deaf; Js "MyDrive.lvlAt = 0; __sd.pressOpener('mydrive')" 1500
  ClearApis; Press 4 1 1000
  Check 'kids turned on after the screen opened: irdash answers kids to START, the screen stays and says KIDS MODE IS ON' ((Cur) -eq 'RigMyDrive' -and (Reg 0 0).t -eq 'KIDS MODE IS ON')
  $null = Invoke-DeckJs $page "(() => { __sd.apiReply = null; return 1; })()"
  Press 7 3 700
  $dg = [IO.File]::ReadAllText((Join-Path $root 'src\deckguard.cs')); $ird = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
  Check 'irdash refuses ailevel start and mdstart while the kids lock is on, answering kids (DeckGuard.KidsBlocks + KidsLockOn, before any dispatch)' ($dg -match '\(v == "ailevel" && w == "start"\) \|\| v == "mdstart"' -and $ird -match 'if \(IRDeck\.DeckGuard\.KidsBlocks\(dc, da\) && KidsLockOn\(\)\) \{[^}]*Send\(s, 409, "text/plain", Encoding\.ASCII\.GetBytes\("kids"\)' -and $ird.IndexOf('DeckGuard.KidsBlocks(dc, da)') -lt $ird.IndexOf('AiLevel.Handles(dc) ? AiLevel.Do') -and $ird -match 'AiLevel\.KidsOn = KidsLockOn;')

  Section '5. a doubled press right after the deck changes page'
  # the pretend app opens SOUND, OVERLAYS and FRIENDS from keys placed where they are on MAIN (the second press lands on the new page's key there)
  foreach ($s in @(@('sound', 3, 3, 'c=sndmute', 'SOUND -> MUTE'), @('overlays', 4, 3, 'c=delta|c=ov', 'OVERLAYS -> MOVE'), @('friends', 4, 0, 'guest/do\?c=(driver|adddriver|newdriver)', 'FRIENDS -> a driver'))) {
    Deaf; ClearApis
    Js "__sd.pressOpener('$($s[0])'); await __sd.sleep(300); __sd.pressTile($($s[1]), $($s[2]))" 600
    $hit = @(Apis | Where-Object { $_ -match $s[3] })
    Check "$($s[4]): the second press 0.3 s after the page changed does nothing" ($hit.Count -eq 0) ($hit -join ' ')
    Js "__sd.pressTile(7, 3); await __sd.sleep(400); if (__sd.cur !== 'main') __sd.show('main')" 500   # (the pretend /guest and /overlays are too thin to draw those screens: back to MAIN by hand)
  }
  Deaf; ClearApis
  Js "__sd.pressOpener('mydrive'); await __sd.sleep(250); __sd.pressOpener('mydrive')" 1200
  Check 'a doubled AI RACE press opens the screen once and presses nothing on it' ((Cur) -eq 'RigMyDrive' -and (Starts).Count -eq 0)
  Press 7 3 300
  Js "__sd.pressOpener('mydrive')" 900
  Check 'the opener press arriving again 0.3 s after EXIT does not reopen the screen' ((Cur) -eq 'main')

  Section '6. in a session, and words inside keys'
  Fx '/mydrive' "m.choice.has = true; m.session = true; m.driving = true; m.current = { carShort: 'CORVETTE GT3', trackShort: 'ROAD ATLANTA', layout: 'Full Course', fav: false }" 300
  Deaf; Js "__sd.pressOpener('mydrive')" 1500
  Check 'in a session the driving keys show; EXIT is still at 7,3 and is the only way out' ((Reg 0 0).w -eq 8 -and (Reg 4 1).t -eq 'GET OUT' -and (Reg 7 3).a -eq 'exit' -and (Invoke-DeckJs $page "MyDrive.regions.filter(r => r.act === 'exit').length") -eq 1)
  $null = Sheet 'session'
  Fx '/mydrive' "m.session = false; m.driving = false" 1200
  $nc = Invoke-DeckJs $page @'
(() => {
  const out = { runs: 0, bad: [] }, cv = document.createElement('canvas'); cv.width = 768; cv.height = 384; const g = cv.getContext('2d');
  let cur = null; const ft = g.fillText.bind(g);
  g.fillText = (t, x, y, mw) => { const w = Math.min(g.measureText(t).width, mw || 1e9); out.runs++; const l = x - w / 2, rr = x + w / 2, k = Math.floor(x / 96), kl = k * 96 + 3, kr = k * 96 + 93; if (l < kl - 0.5 || rr > kr + 0.5) out.bad.push(cur + ': "' + t + '"'); };
  for (const r of MyDrive.regions) { if (r.w < 2) continue; cur = r.c + ',' + r.r + ' ' + r.text; g.textAlign = 'center'; KEYART.drawRegion(g, r, r.c * 96 + 3, r.r * 96 + 3, r.w * 96 - 6, r.h * 96 - 6, false); }
  return out;
})()
'@
  Check "every word on a multi-key tile sits inside one key ($($nc.runs) runs looked at)" ($nc.runs -ge 2 -and @($nc.bad).Count -eq 0) (@($nc.bad) -join '; ')
  Press 7 3 700
  Check 'EXIT returns to your own keys' ((Cur) -eq 'main')

  Section '7. irdash not answering'
  Js "__sd.cfg.fakeFetch = false; window.fetch = (u, o) => new Promise((res, rej) => { if (o && o.signal) o.signal.addEventListener('abort', () => rej(new Error('aborted'))); })" 100
  Deaf; Js "__sd.pressOpener('mydrive')" 3500
  Check 'a hung irdash: DASHBOARD NOT ANSWERING on the keys, EXIT at 7,3 still leaves' ((Invoke-DeckJs $page 'MyDrive.offline') -eq $true)
  Start-Sleep -Milliseconds 300
  Press 7 3 700
  Check '... and EXIT took the deck back to your own keys' ((Cur) -eq 'main')
}
finally { Stop-DeckBrowser $b }
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
