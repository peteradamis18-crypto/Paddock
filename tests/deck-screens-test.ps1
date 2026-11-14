# Deck screens test (C-42): the SOUND screen (C-39), the AI RACE screen's lists (W3-4), and what they stand on. (The ANALYSIS screen went in the W3-4 review.)
# OFFLINE: nothing here talks to the running irdash, to iRacing or to the Stream Deck app, and nothing is deployed.
#   1. (gone: the ANALYSIS screen)
#   2. SOUND    - the same for the SOUND screen
#   3. AI RACE - the lists of the folded AI RACE screen (W3-4): RECENT, CARS, TRACKS, LAYOUTS, FAVOURITES, one EXIT, nothing to type
#   4. irdeck sound - the new command against a PRETEND list of audio devices and apps (PADDOCK_SOUND_PRETEND); Windows' audio is never touched
#   5. irdash side - dash\src\sound.cs and dash\src\deckfeed.cs compiled with stand-ins and run: the report of the workbench page, the
#      checks on what comes in, the SOUND key presses reaching irdeck (pretend list), KEEP / COSWORTH asking the Vault's own routes (a pretend local server)
# Pictures go to tests\shots (deck-sound*.png, deck-airace*.png). A press that would reach the real irdash is impossible:
# every path the page asks for has a pretend answer, and anything else gets {}.
#   powershell -ExecutionPolicy Bypass -File tests\deck-screens-test.ps1 [-NoBuild]     (-NoBuild: parts 4-5 use the irdeck already built in %TEMP%\ird)
param([switch]$NoBuild)
$ErrorActionPreference = 'Continue'   # native programs write to stderr now and then; a failed page script still throws
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $root 'tests\deck-fixtures.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
'Deck screens test (C-42 / DK-8c)'

# ================= the pretend Stream Deck app =================
$fx = @{ '/guest' = @{}; '/overlays' = @{}; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false } }
$fx['/mydrive'] = New-MyDriveFixture
$fx['/mydrive'].choice.carShort = 'CORVETTE'; $fx['/mydrive'].choice.layout = 'Full Course'
$fx['/mydrive'].recent[0].carShort = 'CORVETTE'; $fx['/mydrive'].favs[0].carShort = 'CORVETTE'
$fx['/mydrive/lists'] = @{ recent = @((New-MyDriveCombo 'r00000001' 'Chevrolet Corvette Z06 GT3.R' 'CORVETTE GT3' 'Road Atlanta' 'ROAD ATLANTA' 'Full Course' $true)); cars = @(@{id='c00000001';name='Chevrolet Corvette Z06 GT3.R';short='CORVETTE GT3';class='GT3';last='2026-10-12';count=4}); tracks = @(@{id='t00000001';name='Road Atlanta';short='ROAD ATLANTA';layouts=@('Full Course','Short Course');last='2026-10-12';count=4}) }
$fx['/mydrive/lists'].recent[0].carShort = 'CORVETTE'
for ($i = 2; $i -le 22; $i++) {
  $hex = '{0:x8}' -f $i
  $fx['/mydrive/lists'].cars += @{ id = "c$hex"; name = "GT3 Car $i"; short = "GT3 $i"; class = 'GT3'; last = '2026-10-11'; count = 1 }
  $fx['/mydrive/lists'].tracks += @{ id = "t$hex"; name = "Track $i"; short = "TRACK $i"; layouts = @('Full Course'); last = '2026-10-11'; count = 1 }
  $fx['/mydrive/lists'].recent += @{ id = "r$hex"; car = "GT3 Car $i"; carShort = "GT3 $i"; track = "Track $i"; trackShort = "TRACK $i"; layout = ''; last = '2026-10-11'; count = 1 }
}
$fx['/workbench/state'] = New-AnalysisFixture
$fx['/sound'] = New-SoundFixture
$fx['/vault/item'] = @{ m = @{ id = 'l20261010-041318-7'; pinned = $false; keeper = $false }; cosworth = @{ installed = $true } }
$fx['/vault'] = @{ cosworth = @{ installed = $true } }
$fx['/debrief/state'] = @{ open = $false }
$html = Join-Path $env:TEMP 'deck-screens-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html)
# the mock knows three opener keys: add SOUND and its profile; whatever has no pretend answer gets {} (never the real irdash)
$h2 = $h.Replace("['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1]];", "['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1], ['k-sound', 'com.peter.rigintro.sound', 5, 0]];").Replace("RigMyDrive: 'mydrive',", "RigMyDrive: 'mydrive', RigSound: 'sound',").Replace("return realFetch(url, opt);", "return Promise.resolve(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));")
Check 'the pretend Stream Deck app got the SOUND key and profile, and cannot reach the real irdash' ($h2.Contains('RigSound') -and -not $h2.Contains('return realFetch(url, opt);'))
[IO.File]::WriteAllText($html, $h2, (New-Object Text.UTF8Encoding($false)))

$b = Start-DeckBrowser 9360
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 3

  try { Assert-RigFree -Where '0. dead state keys' } catch { "$_"; throw }
  '0. the ARMED state keys are gone (W0-1: no add-on action ever used them)'
  Check 'no paintStateKey, pollDeckState or deckState in the running add-on' ((Invoke-DeckJs $page "typeof paintStateKey === 'undefined' && typeof pollDeckState === 'undefined' && typeof deckState === 'undefined'") -eq $true)
  $null = Invoke-DeckJs $page "(() => { window.__apis = []; __sd.onApi = p => window.__apis.push(p); return 1; })()"
  function Apis { @(Invoke-DeckJs $page 'window.__apis') }
  function ClearApis { $null = Invoke-DeckJs $page 'window.__apis.length = 0' }
  function Press($c, $r, $wait = 400) { $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep($wait); return 1; })()" }
  function Fx($path, $js, $wait = 1500) { $null = Invoke-DeckJs $page "(async () => { const m = __sd.fx['$path']; $js; await __sd.sleep($wait); return 1; })()" }
  function Js($js, $wait = 300) { $null = Invoke-DeckJs $page "(async () => { $js; await __sd.sleep($wait); return 1; })()" }
  function Sheet($name) { $null = Invoke-DeckJs $page "(() => { const s=MyDrive; if(s.live) for(const pos of Object.keys(s.tiles)) if(s.looks[pos]) __sd.images[s.tiles[pos]]=s.encode(pos); return 1; })()"; Start-Sleep -Milliseconds 1000; return Save-DeckSheet $page (Join-Path $shots "$name.png") }
  function Reg($scr, $c, $r) { Invoke-DeckJs $page "(() => { const r = $scr.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return r ? { t: r.text, s: r.sub, st: r.style, a: r.act, g: r.arg, w: r.w, x: r.extra || '' } : null; })()" }
  function Blank($scr) { Invoke-DeckJs $page "Object.values($scr.looks).filter(l => l.startsWith('blank')).length" }
  function Req($c, $r, $re, $what, $wait = 400) { ClearApis; Press $c $r $wait; $a = @(Apis); $n = @($a | Where-Object { $_ -match $re }).Count; Check "$what -> $re" ($n -ge 1); if ($n -lt 1) { '        requests: ' + ($a -join ' ') } }
  function NoReq($c, $r, $what) { ClearApis; Press $c $r 300; Check "$what sends nothing" (@(Apis).Count -eq 0) }
  function Cur { Invoke-DeckJs $page '__sd.cur' }
  function PickerQuality { Invoke-DeckJs $page "(() => { const a=MyDrive.regions, rows=a.filter(x=>['mdpick','pickcar','picktrack','picklayout'].includes(x.act)); return {single:a.every(x=>x.w===1&&x.h===1),twoLines:rows.every(x=>x.single),upper:a.every(x=>String(x.text||'')===String(x.text||'').toUpperCase()&&String(x.sub||'')===String(x.sub||'').toUpperCase()),lengths:a.every(x=>String(x.text||'').length<=12&&String(x.sub||'').length<=14),back:a.some(x=>x.c===0&&x.r===0&&x.text==='BACK'),exit:a.some(x=>x.c===7&&x.r===3&&x.text==='EXIT')}; })()" }

  ''; '2. the SOUND screen'
  Start-Sleep -Milliseconds 2200
  $m2 = Invoke-DeckJs $page "__sd.measureOpen('sound')"
  Start-Sleep -Milliseconds 800
  Check 'SOUND opens: it asked for the RigSound profile and all 32 keys have a picture' ((Cur) -eq 'RigSound' -and (Sheet 'deck-sound') -eq 32)
  Check 'all 32 pictures are on the keys within 100 ms of the deck showing the screen' ($m2.allPicturesMs -ge 0 -and ($m2.allPicturesMs - $m2.firstAppearMs) -le 100)
  $ids = 'sim', 'spotter', 'music', 'speakers', 'buttkicker'
  $bad = @(); for ($c = 0; $c -lt 5; $c++) {
    $p = Reg 'Sound' $c 1; $q = Reg 'Sound' $c 2; $mu = Reg 'Sound' $c 3
    if (-not ($p.a -eq 'sndvol' -and $p.g -eq ($ids[$c] + ':+10') -and $q.a -eq 'sndvol' -and $q.g -eq ($ids[$c] + ':-10') -and $mu.a -eq 'sndmute' -and $mu.g -eq $ids[$c])) { $bad += $ids[$c] }
  }
  Check 'five columns (game, spotter, music, speakers, buttkicker): + / - step 10, MUTE flips that one' ($bad.Count -eq 0)
  $x = (Reg 'Sound' 0 0).x | ConvertFrom-Json; Check 'the top key of GAME carries its name and level (70 %, not muted)' ($x[0] -eq 'GAME' -and $x[1] -eq $true -and $x[2] -eq 70 -and $x[3] -eq $false)
  $r = Reg 'Sound' 5 0; Check 'the banner says which device is in use (Realtek USB2.0 Audio), not the Windows default' ($r.t -eq 'SOUND' -and $r.s -eq 'PLAYING ON REALTEK USB2.0 AUDIO')
  $r = Reg 'Sound' 5 2; Check 'the Windows default device (the ButtKicker here) is shown, never changed' ($r.t -eq 'WINDOWS DEFAULT' -and $r.s -eq 'BUTTKICKER PRO' -and -not $r.a)
  $r1 = Reg 'Sound' 5 1; $r2 = Reg 'Sound' 6 1; $r3 = Reg 'Sound' 7 1; Check 'presets RACE / CRUISE / NIGHT, none gold when the levels match none' ($r1.t -eq 'RACE' -and $r1.g -eq 'race' -and $r2.t -eq 'CRUISE' -and $r3.t -eq 'NIGHT' -and $r3.g -eq 'night' -and $r1.st -eq '' -and $r2.st -eq '' -and $r3.st -eq '')
  $acts = (Invoke-DeckJs $page "Array.from(new Set(Sound.regions.map(r => r.act).filter(Boolean))).sort().join(',')")
  Check 'nothing of Windows is changed: the only things this screen can send are a level step, a mute and a preset (and EXIT)' ($acts -eq 'exit,sndmute,sndpreset,sndvol')
  Req 0 1 'c=sndvol&a=sim%3A%2B10' 'GAME +'
  Check 'the level changed at once on the key (70 -> 80) before irdash answered' (((((Reg 'Sound' 0 0).x | ConvertFrom-Json))[2]) -eq 80)
  Req 1 2 'c=sndvol&a=spotter%3A-10' 'SPOTTER -'
  Req 2 3 'c=sndmute&a=music' 'MUSIC MUTE'
  ClearApis; Js '__sd.pressTile(0, 3); __sd.pressTile(0, 3)' 500
  Check 'MUTE pressed twice within a blink sends one request (it must not un-mute itself)' (@(Apis | Where-Object { $_ -match 'c=sndmute&a=sim' }).Count -eq 1)
  Req 0 1 'c=sndvol&a=sim%3A%2B10' 'GAME + (again: level steps are never held back)'
  Req 3 1 'c=sndvol&a=speakers%3A%2B10' 'SPEAKERS +'
  Req 4 2 'c=sndvol&a=buttkicker%3A-10' 'BUTTKICKER -'
  Req 5 1 'c=sndpreset&a=race' 'RACE'
  Req 6 1 'c=sndpreset&a=cruise' 'CRUISE'
  Req 7 1 'c=sndpreset&a=night' 'NIGHT'
  Js "Sound.local = {}" 100
  'the real state: muted, not playing, a preset on'
  Fx '/sound' "m.items[0].mute = true; m.items[1].live = false; m.items[1].vol = 0; m.preset = 'race'"
  $r = Reg 'Sound' 0 3; Check 'a muted sound: the key says MUTED in red, no subtitle' ($r.t -eq 'MUTED' -and $r.st -eq 'stop' -and $r.s -eq '')
  $x = (Reg 'Sound' 0 0).x | ConvertFrom-Json; Check 'and its top key shows muted' ($x[3] -eq $true)
  $p = Reg 'Sound' 1 1; $mu = Reg 'Sound' 1 3; $x = (Reg 'Sound' 1 0).x | ConvertFrom-Json
  Check 'a sound that is not playing (the spotter): its keys are dim with nothing to press, and the top key says so' (-not $p.a -and $p.st -eq 'dim' -and -not $mu.a -and $x[1] -eq $false)
  NoReq 1 1 'the dim SPOTTER +'
  Check 'the preset that matches is gold (RACE)' ((Reg 'Sound' 5 1).st -eq 'sel' -and (Reg 'Sound' 6 1).st -eq '')
  $null = Sheet 'deck-sound-muted-race'
  Fx '/sound' "m.default = m.using"
  Check 'when the Windows default is the same device, the line is not shown' ($null -eq (Reg 'Sound' 5 2))
  Fx '/sound' "m.ready = false; m.off = true"
  $r = Reg 'Sound' 0 0; Check 'irdash not updated (no /sound): SOUND NOT READY, with EXIT' ($r.t -eq 'SOUND NOT READY' -and (Reg 'Sound' 7 3).a -eq 'exit')
  $null = Sheet 'deck-sound-notready'
  Fx '/sound' "m.ready = true; delete m.off" 100
  Press 7 3 700
  Check 'EXIT returns to your own keys' ((Cur) -eq 'main')

  # ================= 3. AI RACE: its lists (W3-4 folded MY DRIVE and AI LEVEL into one screen; car / track / level / START: tests\deck-airace-test.ps1) =================
  try { Assert-RigFree -Where '3. AI RACE lists' } catch { "$_"; throw }
  ''; '3. the AI RACE screen and its lists (one key per item, nothing to type)'
  Start-Sleep -Milliseconds 900   # W3-4 review: an opener press within 0.8 s of a page change is the doubled press and is ignored
  $m3 = Invoke-DeckJs $page "__sd.measureOpen('mydrive')"
  Start-Sleep -Milliseconds 1000
  Js "MyDrive.view='home'; MyDrive.m.choice.has=true; MyDrive.m.choice.carShort='CORVETTE'; MyDrive.m.choice.trackShort='ROAD ATLANTA'; MyDrive.m.choice.layout='Full Course'; MyDrive.relayout()" 250
  Check 'AI RACE renders all 32 keys' ((Sheet 'deck-airace-lists-home') -eq 32)
  Check 'the top row has RECENT, CARS, TRACKS and FAVOURITES on single keys (no second CORVETTE key: the CAR key shows it)' ((Reg 'MyDrive' 0 0).t -eq 'RECENT' -and (Reg 'MyDrive' 1 0).t -eq 'CARS' -and (Reg 'MyDrive' 2 0).t -eq 'TRACKS' -and (Reg 'MyDrive' 3 0).t -eq 'FAVOURITES' -and (Invoke-DeckJs $page "MyDrive.regions.filter(r => /CORVETTE/.test(r.text)).length") -eq 1)
  Check 'one EXIT, at 7,3 (no BACK that also leaves)' ((Reg 'MyDrive' 7 3).t -eq 'EXIT' -and (Reg 'MyDrive' 7 3).a -eq 'exit' -and (Invoke-DeckJs $page "MyDrive.regions.filter(r => r.act === 'exit' || r.act === 'leave').length") -eq 1)
  Press 3 0 300
  Check 'FAVOURITES opens its own one-key list' ((Reg 'MyDrive' 4 0).t -eq 'FAVOURITES' -and (Reg 'MyDrive' 0 1).a -eq 'mdpick')
  $q=PickerQuality; Check 'FAVOURITES: one-key uppercase tiles, two text lines, BACK and EXIT' ($q.single -and $q.twoLines -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Press 0 0 300
  Check 'BACK in a list returns to the AI RACE keys (it does not leave the screen)' ((Cur) -eq 'RigMyDrive' -and (Reg 'MyDrive' 0 0).t -eq 'RECENT' -and (Reg 'MyDrive' 4 1).t -eq 'START')
  Press 0 0 300
  Check 'RECENT opens its list' ((Reg 'MyDrive' 1 0).t -eq 'RECENT' -and (Reg 'MyDrive' 1 0).st -eq 'sel' -and (Reg 'MyDrive' 0 1).t -match 'CORVETTE')
  $null = Sheet 'deck-airace-recent'
  $q=PickerQuality; Check 'RECENT: one-key uppercase tiles within 12/14 characters, BACK and EXIT' ($q.single -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Check 'RECENT pages forward and back (PREV / NEXT, EXIT stays at 7,3)' ((Reg 'MyDrive' 5 3).t -eq 'PREV' -and (Reg 'MyDrive' 6 3).t -eq 'NEXT' -and (Reg 'MyDrive' 7 3).t -eq 'EXIT')
  Press 6 3 300
  Check 'RECENT page two can return to page one' ((Reg 'MyDrive' 5 3).t -eq 'PREV')
  Press 5 3 300
  'CARS -> TRACKS -> LAYOUTS'
  ClearApis
  Press 2 0 300   # the CARS tab of the list
  Check 'CARS starts with class tabs and has a one-key car list' ((Reg 'MyDrive' 4 0).t -eq 'GT3' -and (Reg 'MyDrive' 0 1).w -eq 1)
  $null = Sheet 'deck-airace-cars'
  $q=PickerQuality; Check 'CARS: one-key uppercase tiles, two text lines, short lines, BACK and EXIT' ($q.single -and $q.twoLines -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Check 'no SEARCH key and no keyboard: nothing to type (PLAN rule 6)' ((Invoke-DeckJs $page "MyDrive.regions.filter(r => /SEARCH/.test(r.text) || r.act === 'search' || r.act === 'letter').length") -eq 0)
  Press 0 1 300
  Check 'choosing a car sends mdpick and goes on to TRACKS, nothing started' ((Reg 'MyDrive' 3 0).t -eq 'TRACKS' -and (Reg 'MyDrive' 3 0).st -eq 'sel' -and @(Apis | Where-Object { $_ -match 'c=mdpick&a=c00000001' }).Count -eq 1 -and @(Apis | Where-Object { $_ -match 'c=mdstart|c=airace|a=start' }).Count -eq 0)
  $q=PickerQuality; Check 'TRACKS: one-key uppercase tiles, two text lines, short lines, BACK and EXIT' ($q.single -and $q.twoLines -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Press 0 1 300
  Check 'choosing a track saves it and opens its layout list' (@(Apis | Where-Object { $_ -match 'c=mdpick&a=t00000001' }).Count -eq 1 -and (Reg 'MyDrive' 0 1).t -eq 'FULL COURSE' -and (Reg 'MyDrive' 1 1).t -eq 'SHORT COURSE')
  $null = Sheet 'deck-airace-layouts'
  $q=PickerQuality; Check 'LAYOUTS: one-key uppercase tiles, two text lines, short lines, BACK and EXIT' ($q.single -and $q.twoLines -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Press 0 1 300
  Check 'choosing a layout saves it and comes back to the AI RACE keys, where START is (the deck does not leave)' (@(Apis | Where-Object { $_ -match 'c=mdpick&a=l' }).Count -ge 1 -and (Cur) -eq 'RigMyDrive' -and (Reg 'MyDrive' 4 1).t -eq 'START' -and @(Apis | Where-Object { $_ -match 'c=mdstart|c=airace|a=start' }).Count -eq 0)
  Press 7 3 700
  Check 'EXIT returns to your own keys' ((Cur) -eq 'main')
  Fx '/mydrive' "m.choice.has = false; m.aiStatus = 'NO CHOICE'" 200
  Js "MyDrive.keyTick()" 800
  Check 'NO CHOICE never switches the deck by itself (W0-1, audit 11 A1); the deck stays on your own keys' ((Cur) -eq 'main' -and @(Apis | Where-Object { $_ -match 'c=airace|c=mdstart' }).Count -eq 0)
  Js "__sd.pressOpener('mydrive')" 1500
  Check 'NO CHOICE: a press on AI RACE opens the RECENT list without starting anything' ((Cur) -eq 'RigMyDrive' -and (Reg 'MyDrive' 1 0).t -eq 'RECENT' -and (Reg 'MyDrive' 1 0).st -eq 'sel' -and @(Apis | Where-Object { $_ -match 'c=airace|c=mdstart|a=start' }).Count -eq 0)
  $null = Sheet 'deck-airace-empty-choice'
  Fx '/mydrive' "m.aiStatus = ''; m.choice.has = true" 100
  Js "MyDrive.exit({test:true})" 250
}
finally { Stop-DeckBrowser $b }

# ================= 4. irdeck sound against a pretend list =================
try { Assert-RigFree -Where '4. irdeck sound' } catch { "$_"; throw }
''; '4. irdeck sound against a PRETEND list of devices and apps (Windows audio is not touched)'
$cli = Join-Path $env:TEMP 'ird\irdeck-cli.exe'; $deckExe = Join-Path $env:TEMP 'ird\irdeck.exe'
if (-not $NoBuild) { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-irdeck.ps1') -NoDeploy 2>&1 | ForEach-Object { "$_" }; Check 'build-irdeck.ps1 -NoDeploy compiled irdeck with sound.cs (into %TEMP%\ird, nothing deployed)' (($o -join ' ') -match 'not deployed') }
Check 'the built irdeck-cli.exe and irdeck.exe exist' ((Test-Path $cli) -and (Test-Path $deckExe))
$work = Join-Path $env:TEMP 'deck-screens-test'; New-Item -ItemType Directory -Force $work | Out-Null
$pretend = Join-Path $work 'pretend.json'; $stateOut = Join-Path $work 'state.json'
function Write-Pretend($vbk = $true) {
  $bk = if ($vbk) { '{"name":"Speakers (ButtKicker PRO)","vol":0.3,"mute":false,"apps":[{"proc":"Spotify","vol":0.4,"mute":false}]},' } else { '' }
  $json = '{"default":"Speakers (ButtKicker PRO)","devices":[{"name":"Speakers (Realtek USB2.0 Audio)","vol":0.5,"mute":false,"apps":[{"proc":"iRacingSim64DX11","vol":0.7,"mute":false},{"proc":"iRacingUI","vol":0.7,"mute":false},{"proc":"CrewChiefV4","vol":0.9,"mute":false},{"proc":"chrome","vol":1,"mute":false}]},' + $bk + '{"name":"ButtKicker Input (ButtKicker Virtual Audio Device)","vol":1,"mute":false,"apps":[]},{"name":"LG FHD (NVIDIA High Definition Audio)","vol":1,"mute":false,"apps":[]}]}'
  [IO.File]::WriteAllText($pretend, $json, (New-Object Text.UTF8Encoding($false)))
}
function Pre { [IO.File]::ReadAllText($pretend) | ConvertFrom-Json }
function AppVol($d, $proc) { foreach ($dev in $d.devices) { foreach ($a in $dev.apps) { if ($a.proc -eq $proc) { return $a } } } }
function Dev($d, $name) { $d.devices | Where-Object { $_.name -eq $name } | Select-Object -First 1 }
function Snd { $o = & $cli sound @args 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n") } }
$env:PADDOCK_SOUND_PRETEND = $pretend; $env:PADDOCK_SOUND_STATE = $stateOut
try {
  Write-Pretend
  $s = Snd status; $st = ($s.out -split "`n" | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
  Check 'status is one JSON line with five items and says it is pretend' ($s.rc -eq 0 -and $st.pretend -eq $true -and @($st.items).Count -eq 5)
  $it = @{}; foreach ($i in $st.items) { $it[$i.id] = $i }
  Check 'GAME is the sim (70 %), SPOTTER is CrewChief (90 %), MUSIC is Spotify (40 %)' ($it.sim.vol -eq 70 -and $it.spotter.vol -eq 90 -and $it.music.vol -eq 40 -and $it.sim.live -and $it.spotter.live -and $it.music.live)
  Check 'SPEAKERS is the device the sim plays on (Realtek, 50 %); BUTTKICKER is the ButtKicker output, not its virtual input (30 %)' ($it.speakers.device -eq 'Speakers (Realtek USB2.0 Audio)' -and $it.speakers.vol -eq 50 -and $it.buttkicker.device -eq 'Speakers (ButtKicker PRO)' -and $it.buttkicker.vol -eq 30)
  Check 'the Windows default device is reported (the ButtKicker) and "using" is the speakers' ($st.default -eq 'Speakers (ButtKicker PRO)' -and $st.using -eq 'Speakers (Realtek USB2.0 Audio)')
  Check 'state.json is written where PADDOCK_SOUND_STATE says' ((Test-Path $stateOut) -and (([IO.File]::ReadAllText($stateOut) | ConvertFrom-Json).items.Count -eq 5))

  $null = Snd step sim +10; $d = Pre
  Check 'step sim +10 moves both of the sim''s sessions together (70 -> 80 %), nothing else' ((AppVol $d 'iRacingSim64DX11').vol -eq 0.8 -and (AppVol $d 'iRacingUI').vol -eq 0.8 -and (AppVol $d 'CrewChiefV4').vol -eq 0.9 -and (AppVol $d 'chrome').vol -eq 1)
  $null = Snd step spotter -10; $null = Snd step spotter -100; $d = Pre
  Check 'step is clamped at 0' ((AppVol $d 'CrewChiefV4').vol -eq 0)
  $null = Snd set spotter 100; $null = Snd set music 33; $d = Pre
  Check 'set spotter 100 / set music 33' ((AppVol $d 'CrewChiefV4').vol -eq 1 -and (AppVol $d 'Spotify').vol -eq 0.33)
  $null = Snd step buttkicker +10; $null = Snd step speakers -10; $d = Pre
  Check 'the two devices have their own level: ButtKicker 30 -> 40 %, speakers 50 -> 40 %' ((Dev $d 'Speakers (ButtKicker PRO)').vol -eq 0.4 -and (Dev $d 'Speakers (Realtek USB2.0 Audio)').vol -eq 0.4)
  $null = Snd mute music; $d = Pre; $a = Snd status; $st = ($a.out -split "`n" | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
  Check 'mute with no word flips: music is muted, and the status says so' ((AppVol $d 'Spotify').mute -eq $true -and (@($st.items) | Where-Object { $_.id -eq 'music' }).mute -eq $true)
  $null = Snd mute music; $d = Pre
  Check 'a second one flips it back' ((AppVol $d 'Spotify').mute -eq $false)
  $null = Snd mute spotter on; $null = Snd mute spotter on; $d = Pre; $null = Snd mute spotter off; $d2 = Pre
  Check 'mute on / off are not flips (on twice is still on)' ((AppVol $d 'CrewChiefV4').mute -eq $true -and (AppVol $d2 'CrewChiefV4').mute -eq $false)
  $null = Snd mute buttkicker; $d = Pre; $null = Snd mute buttkicker
  Check 'a device can be muted too' ((Dev $d 'Speakers (ButtKicker PRO)').mute -eq $true -and (Dev (Pre) 'Speakers (ButtKicker PRO)').mute -eq $false)

  $null = Snd preset race; $d = Pre; $a = Snd status; $st = ($a.out -split "`n" | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
  Check 'RACE: game 80, spotter 100, music off (muted); the speakers and the ButtKicker are left alone' ((AppVol $d 'iRacingSim64DX11').vol -eq 0.8 -and (AppVol $d 'CrewChiefV4').vol -eq 1 -and (AppVol $d 'Spotify').mute -eq $true -and (Dev $d 'Speakers (Realtek USB2.0 Audio)').vol -eq 0.4 -and (Dev $d 'Speakers (ButtKicker PRO)').vol -eq 0.4)
  Check 'the status says RACE is on' ($st.preset -eq 'race')
  $null = Snd preset cruise; $d = Pre; $a = Snd status; $st = ($a.out -split "`n" | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
  Check 'CRUISE: music on at 60, the spotter low (40), the game 60' ((AppVol $d 'Spotify').mute -eq $false -and (AppVol $d 'Spotify').vol -eq 0.6 -and (AppVol $d 'CrewChiefV4').vol -eq 0.4 -and (AppVol $d 'iRacingSim64DX11').vol -eq 0.6 -and $st.preset -eq 'cruise')
  $null = Snd set sim 20; $null = Snd preset night; $d = Pre; $a = Snd status; $st = ($a.out -split "`n" | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
  Check 'NIGHT: everything lower, never louder (game was 20 and stays 20; spotter 40 stays; music 60 -> 20; ButtKicker 40 -> 25)' ((AppVol $d 'iRacingSim64DX11').vol -eq 0.2 -and (AppVol $d 'CrewChiefV4').vol -eq 0.4 -and (AppVol $d 'Spotify').vol -eq 0.2 -and (Dev $d 'Speakers (ButtKicker PRO)').vol -eq 0.25 -and $st.preset -eq 'night')
  $null = Snd set sim 50; $a = Snd status
  Check 'no preset is on when the levels are in between' ($a.out -match '"preset":""')
  Check 'the Windows default device is never changed by any of it' ((Pre).default -eq 'Speakers (ButtKicker PRO)')

  $bad = (Snd step bogus +10), (Snd set sim abc), (Snd preset party), (Snd mute nothing), (Snd frobnicate)
  Check 'a target, number or preset that does not exist is refused (exit 1), nothing changes' (@($bad | Where-Object { $_.rc -ne 1 }).Count -eq 0)
  Write-Pretend; $null = Snd set sim 10
  $none = [IO.File]::ReadAllText($pretend).Replace('"proc":"CrewChiefV4"', '"proc":"Other"'); [IO.File]::WriteAllText($pretend, $none)
  $s = Snd step spotter +10
  Check 'a sound that is not playing cannot be set: it says so and changes nothing (exit 0, no beep from a key)' ($s.rc -eq 0 -and $s.out -match 'not playing right now')
  $a = Snd status; $st = ($a.out -split "`n" | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
  Check 'and the status marks it live = false (the key goes dim)' ((@($st.items) | Where-Object { $_.id -eq 'spotter' }).live -eq $false -and $st.preset -eq '')
  Write-Pretend $false
  $a = Snd status; $st = ($a.out -split "`n" | Where-Object { $_ -like '{*' } | Select-Object -First 1) | ConvertFrom-Json
  Check 'with no ButtKicker output on the PC, the ButtKicker''s virtual input is the level (name has "Virtual")' ((@($st.items) | Where-Object { $_.id -eq 'buttkicker' }).device -match 'Virtual')
}
finally { Remove-Item Env:PADDOCK_SOUND_PRETEND -ErrorAction SilentlyContinue; Remove-Item Env:PADDOCK_SOUND_STATE -ErrorAction SilentlyContinue }

# ================= 5. the irdash side, compiled with stand-ins =================
try { Assert-RigFree -Where '5. irdash side' } catch { "$_"; throw }
''; '5. irdash side: dash\src\sound.cs and dash\src\deckfeed.cs, compiled with stand-ins and run (no irdash, no deploy)'
$tdir = Join-Path $env:TEMP 'deck-screens-test-irdash'; New-Item -ItemType Directory -Force $tdir | Out-Null
$stub = @'
using System; using System.Collections.Generic; using System.IO; using System.Net; using System.Text; using System.Threading; using System.Web.Script.Serialization;
namespace IRDash {
  static class Json_ { public static string S(string s) { return new JavaScriptSerializer().Serialize(s ?? ""); } }
  static class Program { public static bool IsDriving = false; }
  static class Log { public static void W(string s) { Console.WriteLine("        [irdash log] " + s); } }
  class Watch { public static string IrdeckPath; }
}
class T {
  static int fails = 0;
  static void Check(string what, bool ok) { if (!ok) fails++; Console.WriteLine((ok ? "  ok    " : "  FAIL  ") + what); }
  static Dictionary<string, object> J(string s) { return new JavaScriptSerializer().DeserializeObject(s) as Dictionary<string, object>; }
  static Dictionary<string, string> Q(params string[] kv) { var d = new Dictionary<string, string>(); for (int i = 0; i < kv.Length; i += 2) d[kv[i]] = kv[i + 1]; return d; }
  static Dictionary<string, string> Report() { return Q("pg", "driver", "pgs", "driver,grip", "pl", "0", "sp", "1", "tl", "0", "ax", "dist", "mc", "gap", "om", "0", "of", "0", "z", "0", "id", "l20261010-041318-7", "lap", "7", "ref", "pb",
      "nl", "8", "ne", "5", "nc", "12", "lt", "79.549", "rt", "79.575", "rl", "3", "car", "Chevrolet Corvette Z06 GT3.R", "trk", "Road Atlanta"); }
  static int Main(string[] a) {
    string irdeck = a[0], pretend = a[1], pageQuery = a.Length > 2 ? a[2] : "";
    // ---- DeckFeed: the workbench page's report ----
    Dictionary<string, object> j = J(IRDash.DeckFeed.WorkbenchJson());
    Check("no report yet: the workbench is not open", (bool)j["open"] == false);
    IRDash.DeckFeed.Workbench(Q("x", "1"));
    Check("a request that is not the page's report (no pg) is ignored", (bool)J(IRDash.DeckFeed.WorkbenchJson())["open"] == false);
    IRDash.DeckFeed.Workbench(Report());
    j = J(IRDash.DeckFeed.WorkbenchJson());
    Check("a report opens it: page, pages, lap, times", (bool)j["open"] && (string)j["page"] == "driver" && ((System.Collections.IList)j["pages"]).Count == 2 && Convert.ToInt32(j["lap"]) == 7 && Convert.ToDouble(j["lapTime"]) == 79.549 && Convert.ToDouble(j["refTime"]) == 79.575);
    Check("flags come out as booleans, the speed as a number", (bool)j["playing"] == false && (bool)j["tile"] == false && (bool)j["zoomed"] == false && Convert.ToDouble(j["speed"]) == 1.0 && (string)j["mapColour"] == "gap");
    Check("car and track come through, the vault id too", (string)j["car"] == "Chevrolet Corvette Z06 GT3.R" && (string)j["track"] == "Road Atlanta" && (string)j["id"] == "l20261010-041318-7");
    var r2 = Report(); r2["pl"] = "1"; r2["sp"] = "2"; r2["tl"] = "1"; r2["rt"] = ""; r2["rl"] = "";
    IRDash.DeckFeed.Workbench(r2); j = J(IRDash.DeckFeed.WorkbenchJson());
    Check("playing / speed 2 / tile on, no reference lap: refTime is null", (bool)j["playing"] && Convert.ToDouble(j["speed"]) == 2.0 && (bool)j["tile"] && j["refTime"] == null);
    var evil = Report(); evil["id"] = "a\"b"; evil["car"] = "x\ny"; evil["sp"] = "fast"; evil["pg"] = "Driver;drop"; evil["lap"] = "7; rm";
    IRDash.DeckFeed.Workbench(evil); j = J(IRDash.DeckFeed.WorkbenchJson());
    Check("values that do not fit their pattern are dropped (id with a quote, car with a line break, speed 'fast', page with ';', lap '7; rm')", (string)j["id"] == "" && (string)j["car"] == "" && Convert.ToDouble(j["speed"]) == 1.0 && (string)j["page"] == "" && Convert.ToInt32(j["lap"]) == 0);
    if (pageQuery.Length > 0) {
      var nv = System.Web.HttpUtility.ParseQueryString(pageQuery); var pd = new Dictionary<string, string>(); foreach (string k in nv.AllKeys) pd[k] = nv[k];
      IRDash.DeckFeed.Workbench(pd); j = J(IRDash.DeckFeed.WorkbenchJson());
      Check("the report workbench.js really builds is accepted whole: grip page, playing, speed 0.5, tile, zoomed, offset -3, map colour speed", (bool)j["open"] && (string)j["page"] == "grip" && (bool)j["playing"] && Convert.ToDouble(j["speed"]) == 0.5 && (bool)j["tile"] && (bool)j["zoomed"] && Convert.ToInt32(j["offset"]) == -3 && (string)j["mapColour"] == "speed" && (string)j["axis"] == "time");
      Check("... and its lap, reference (a file:lap name with spaces), counts and car", Convert.ToInt32(j["lap"]) == 7 && ((string)j["ref"]).EndsWith(".ibt:5") && Convert.ToInt32(j["laps"]) == 2 && Convert.ToInt32(j["events"]) == 3 && Convert.ToInt32(j["corners"]) == 2 && (string)j["car"] == "Chevrolet Corvette Z06 GT3.R" && (string)j["id"] == "l20261010-041318-7");
    }
    // ---- KEEP / COSWORTH: the Vault's own routes, asked of a pretend local server ----
    var seen = new List<string>(); HttpListener l = new HttpListener(); l.Prefixes.Add("http://localhost:18199/"); l.Start();
    Thread srv = new Thread(delegate () { while (true) { try { var c = l.GetContext(); seen.Add(c.Request.RawUrl); byte[] b = Encoding.UTF8.GetBytes("{}"); c.Response.OutputStream.Write(b, 0, b.Length); c.Response.Close(); } catch { return; } } }); srv.IsBackground = true; srv.Start();
    Environment.SetEnvironmentVariable("PADDOCK_DECKFEED_BASE", "http://localhost:18199");
    IRDash.DeckFeed.Workbench(Report());
    Check("wbkeep 1 asks the Vault to keep the lap on show", IRDash.DeckFeed.Do("wbkeep", "1") && seen.Contains("/vault/edit?id=l20261010-041318-7&star=1"));
    Check("wbkeep 0 lets it go", IRDash.DeckFeed.Do("wbkeep", "0") && seen.Contains("/vault/edit?id=l20261010-041318-7&star=0"));
    Check("wbcosworth opens the lap in Pi Toolbox through the Vault", IRDash.DeckFeed.Do("wbcosworth", "") && seen.Contains("/vault/open?id=l20261010-041318-7&how=cosworth"));
    int n = seen.Count;
    Check("wbkeep with a bad argument, and an unknown command, are refused and ask nothing", !IRDash.DeckFeed.Do("wbkeep", "2") && !IRDash.DeckFeed.Do("wbkeep", "") && !IRDash.DeckFeed.Do("wbnope", "1") && seen.Count == n);
    var file = Report(); file["id"] = "chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt"; IRDash.DeckFeed.Workbench(file);
    Check("a lap shown from a plain .ibt file (not a Vault moment) cannot be kept or opened: refused, nothing asked", !IRDash.DeckFeed.Do("wbkeep", "1") && !IRDash.DeckFeed.Do("wbcosworth", "") && seen.Count == n);
    Program_Driving(true); IRDash.DeckFeed.Workbench(Report());
    Check("never while he is driving", !IRDash.DeckFeed.Do("wbkeep", "1") && seen.Count == n);
    Program_Driving(false);
    l.Close();
    Check("DeckFeed.Handles knows its two commands only", IRDash.DeckFeed.Handles("wbkeep") && IRDash.DeckFeed.Handles("wbcosworth") && !IRDash.DeckFeed.Handles("wb-play") && !IRDash.DeckFeed.Handles(null));

    // ---- Sound: key presses to irdeck, the state back (the pretend list is PADDOCK_SOUND_PRETEND) ----
    IRDash.Watch.IrdeckPath = irdeck;
    Check("Sound.Handles knows its three commands only", IRDash.Sound.Handles("sndvol") && IRDash.Sound.Handles("sndmute") && IRDash.Sound.Handles("sndpreset") && !IRDash.Sound.Handles("sndnope") && !IRDash.Sound.Handles(null));
    Check("bad arguments are refused before anything runs", !IRDash.Sound.Do("sndvol", "sim:+1000") && !IRDash.Sound.Do("sndvol", "bogus:+10") && !IRDash.Sound.Do("sndvol", "sim;+10") && !IRDash.Sound.Do("sndvol", "") && !IRDash.Sound.Do("sndmute", "x y") && !IRDash.Sound.Do("sndpreset", "party") && !IRDash.Sound.Do("sndpreset", "race & del"));
    string sj = IRDash.Sound.Json(false);
    Check("no state yet: ready false (a peek asks Windows for nothing)", (bool)J(sj)["ready"] == false);
    IRDash.Sound.Json(true);
    Dictionary<string, object> s = null;
    for (int i = 0; i < 60; i++) { Thread.Sleep(200); s = J(IRDash.Sound.Json(false)); if ((bool)s["ready"]) break; }
    Check("asking for the state makes irdeck write it: ready, five items, the age, not busy", (bool)s["ready"] && ((System.Collections.IList)s["items"]).Count == 5 && s.ContainsKey("age") && (bool)s["pretend"]);
    if (!(bool)s["pretend"]) { Console.WriteLine("  FAIL  STOPPED: irdeck is not on the pretend list - nothing more is pressed"); return 2; }
    Check("Sound.Do sndvol sim:+10 is accepted", IRDash.Sound.Do("sndvol", "sim:+10"));
    bool moved = false; for (int i = 0; i < 60 && !moved; i++) { Thread.Sleep(200); moved = File.ReadAllText(pretend).Contains("\"vol\":0.8"); }
    Check("irdeck did it on the pretend list (sim 70 -> 80 %)", moved);
    Check("sndmute music and sndpreset race are accepted", IRDash.Sound.Do("sndmute", "music") && IRDash.Sound.Do("sndpreset", "race"));
    bool raced = false; for (int i = 0; i < 80 && !raced; i++) { Thread.Sleep(200); Dictionary<string, object> t = J(IRDash.Sound.Json(false)); raced = t.ContainsKey("preset") && (string)t["preset"] == "race"; }
    Check("the state served by irdash now says the preset is RACE", raced);
    Console.WriteLine(fails == 0 ? "IRDASH-SIDE OK" : "IRDASH-SIDE FAILS " + fails);
    return fails == 0 ? 0 : 1;
  }
  static void Program_Driving(bool on) { IRDash.Program.IsDriving = on; }
}
'@
[IO.File]::WriteAllText((Join-Path $tdir 'stub.cs'), $stub, (New-Object Text.UTF8Encoding($false)))
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$o = & $csc /nologo /target:exe /optimize+ "/out:$tdir\t.exe" /r:System.dll /r:System.Core.dll /r:System.Web.dll /r:System.Web.Extensions.dll (Join-Path $tdir 'stub.cs') (Join-Path $root 'dash\src\sound.cs') (Join-Path $root 'dash\src\deckfeed.cs') 2>&1 | ForEach-Object { "$_" }
Check 'dash\src\sound.cs and dash\src\deckfeed.cs compile (C# 5, with stand-ins for the rest of irdash)' ($LASTEXITCODE -eq 0 -and (Test-Path "$tdir\t.exe"))
if ($LASTEXITCODE -ne 0) { $o | Select-Object -First 12 | ForEach-Object { "        $_" } }
if (Test-Path "$tdir\t.exe") {
  Write-Pretend; $irdeckStateDir = Join-Path $env:TEMP 'ird\sound'; Remove-Item (Join-Path $irdeckStateDir 'state.json') -ErrorAction SilentlyContinue
  $env:PADDOCK_SOUND_PRETEND = $pretend; Remove-Item Env:PADDOCK_SOUND_STATE -ErrorAction SilentlyContinue
  try {
    # irdeck writes its state next to itself (%TEMP%\ird\sound\state.json) - where irdash looks - and the pretend list is the only thing it touches
    $out = & "$tdir\t.exe" $deckExe $pretend $wbQuery 2>&1 | ForEach-Object { "$_" }
    $out | Where-Object { $_ -match '^\s+(ok|FAIL)\s' } | ForEach-Object { if ($_ -match '^\s+ok') { $pass++ } else { $fail++ }; $_ }
    $out | Where-Object { $_ -match 'irdash log|STOPPED' } | ForEach-Object { $_ }
    Check 'the irdash-side program finished clean' (($out -join ' ') -match 'IRDASH-SIDE OK')
  }
  finally { Remove-Item Env:PADDOCK_SOUND_PRETEND -ErrorAction SilentlyContinue; Get-Process irdeck -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$env:TEMP\ird\*" } | Stop-Process -Force -ErrorAction SilentlyContinue }
}

# ================= 6. the two fixes from keys-test =================
''; '6. the two keys-test warnings are gone'
$plug = [IO.File]::ReadAllText((Join-Path $root 'deck-intro\plugin.html'))
Check 'MY DRIVE no longer has the dim AI RACE / coming later tile (W3-4: AI RACE is the folded screen itself now; its START key says AI RACE)' (-not ($plug -match "add\(\d+, \d+, \d+, \d+, 'AI RACE'") -and -not ($plug -match 'coming later'))
Check 'the PHOTO key''s long line is short now' (-not $plug.Contains('SWITCH ON IN IRACING SETTINGS') -and $plug.Contains("'PHOTO', 'TURN ON IN IRACING'"))
$inst = [IO.File]::ReadAllText((Join-Path $root 'deck-intro\install.ps1'))
Check 'install.ps1 has a higher version than 1.6.1.0 and bundles the RigSound profile with its action; the ANALYSIS screen is gone (W3-4 review)' ($inst -match "\`$ver = '1\.([7-9]|\d\d)\.\d+\.\d+'" -and -not $inst.Contains("Build-Profile 'RigAnalysis'") -and -not $inst.Contains('$uuid.analysis') -and $inst.Contains("Build-Profile 'RigSound' 'sound'") -and $inst.Contains('$uuid.sound'))

''
"$pass passed, $fail failed. Pictures in $shots"
if ($fail -gt 0) { exit 1 }
