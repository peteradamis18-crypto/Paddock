# Deck screens test (C-42): the ANALYSIS screen, the SOUND screen (C-39), the RACE SETUP screen = MY DRIVE v2 (C-33), and what they stand on.
# OFFLINE: nothing here talks to the running irdash, to iRacing or to the Stream Deck app, and nothing is deployed.
#   1. ANALYSIS - the real add-on page (deck-intro\plugin.html) in headless Chrome with a pretend Stream Deck app and pretend irdash answers
#   2. SOUND    - the same for the SOUND screen
#   3. RACE SETUP - the same for MY DRIVE: LAST DRIVE, USUAL, SAME CAR / TRACK, FAVOURITES, SURPRISE, START, no "coming later" key
#   4. irdeck sound - the new command against a PRETEND list of audio devices and apps (PADDOCK_SOUND_PRETEND); Windows' audio is never touched
#   5. irdash side - dash\src\sound.cs and dash\src\deckfeed.cs compiled with stand-ins and run: the report of the workbench page, the
#      checks on what comes in, the SOUND key presses reaching irdeck (pretend list), KEEP / COSWORTH asking the Vault's own routes (a pretend local server)
# Pictures go to tests\shots (deck-analysis*.png, deck-sound*.png, deck-racesetup*.png). A press that would reach the real irdash is impossible:
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
$fx['/deck/state'] = @{ primary = 'GETIN'; label = 'GET IN'; reason = ''; armed = @{ quit = 0; restart = 0; skip = 0 } }
$fx['/vault/item'] = @{ m = @{ id = 'l20261010-041318-7'; pinned = $false; keeper = $false }; cosworth = @{ installed = $true } }
$fx['/vault'] = @{ cosworth = @{ installed = $true } }
$fx['/debrief/state'] = @{ open = $false }
$html = Join-Path $env:TEMP 'deck-screens-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html)
# the mock knows three opener keys: add ANALYSIS and SOUND and their profiles; whatever has no pretend answer gets {} (never the real irdash)
$h2 = $h.Replace("['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1]];", "['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1], ['k-analysis', 'com.peter.rigintro.analysis', 4, 0], ['k-sound', 'com.peter.rigintro.sound', 5, 0]];").Replace("RigMyDrive: 'mydrive',", "RigMyDrive: 'mydrive', RigAnalysis: 'analysis', RigSound: 'sound',").Replace("return realFetch(url, opt);", "return Promise.resolve(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));")
Check 'the pretend Stream Deck app got the ANALYSIS and SOUND keys and profiles, and cannot reach the real irdash' ($h2.Contains('RigAnalysis') -and $h2.Contains('RigSound') -and -not $h2.Contains('return realFetch(url, opt);'))
[IO.File]::WriteAllText($html, $h2, (New-Object Text.UTF8Encoding($false)))

$b = Start-DeckBrowser 9360
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 3

  try { Assert-RigFree -Where '0. SMART key' } catch { "$_"; throw }
  '0. SMART key and armed countdown render (offline state fixtures)'
  $smartCases = @(
    @{ label = 'GET IN'; reason = '' }, @{ label = 'RESET'; reason = 'SLOW DOWN' }, @{ label = 'SKIP'; reason = '' },
    @{ label = 'WAIT'; reason = '' }, @{ label = 'NOT ALLOWED'; reason = '' }
  )
  $rendered = @()
  foreach ($case in $smartCases) {
    $jsCase = ($case | ConvertTo-Json -Compress).Replace("'", "\\'")
    $draw = Invoke-DeckJs $page "(() => { deckState = Object.assign({armed:{}}, $jsCase); let words=[]; const f=CanvasRenderingContext2D.prototype.fillText; CanvasRenderingContext2D.prototype.fillText=function(t){words.push(String(t));return f.apply(this,arguments)}; paintStateKey('test-smart','smart'); CanvasRenderingContext2D.prototype.fillText=f; return {words:words, image:__sd.images['test-smart']}; })()"
    $reasonOk = -not $case.reason -or ($draw.words -contains $case.reason)
    Check ("SMART key draws " + $case.label + " with its small reason") ($draw.words -contains $case.label -and $reasonOk -and $draw.image -like 'data:image/png;base64,*')
    $rendered += $draw.image
  }
  $armed = Invoke-DeckJs $page "(() => { deckState={label:'GET IN',reason:'',armed:{quit:3}}; let words=[]; const f=CanvasRenderingContext2D.prototype.fillText; CanvasRenderingContext2D.prototype.fillText=function(t){words.push(String(t));return f.apply(this,arguments)}; paintStateKey('test-armed','quit'); CanvasRenderingContext2D.prototype.fillText=f; return {words:words,image:__sd.images['test-armed']}; })()"
  Check 'QUIT draws ARMED 3 while its armed seconds are three' ($armed.words -contains 'ARMED 3' -and $armed.image -like 'data:image/png;base64,*')
  $smartSheet = Invoke-DeckJs $page "(() => { const cv=document.createElement('canvas'); cv.width=6*100; cv.height=100; const g=cv.getContext('2d'); const urls=$($rendered | ConvertTo-Json -Compress); const all=urls.concat($($armed.image | ConvertTo-Json -Compress)); return Promise.all(all.map((u,i)=>new Promise(ok=>{const im=new Image();im.onload=()=>{g.drawImage(im,i*100,0,100,100);ok()};im.src=u}))).then(()=>cv.toDataURL('image/png')); })()"
  Save-DataUrlPng $smartSheet (Join-Path $shots 'deck-smart-states.png')
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

  # ================= DK-8 PICK =================
  try { Assert-RigFree -Where 'DK-8 PICK' } catch { "$_"; throw }
  'DK-8c RACE SETUP home and list picker'
  $pickOpen = Invoke-DeckJs $page "__sd.measureOpen('mydrive')"
  Start-Sleep -Milliseconds 1200
  Check 'MY DRIVE opens the RACE SETUP home with the five one-key choices' ((Cur) -eq 'RigMyDrive' -and (Reg 'MyDrive' 1 0).t -match 'CORVETTE' -and (Reg 'MyDrive' 2 0).t -eq 'RECENT' -and (Reg 'MyDrive' 3 0).t -eq 'CARS' -and (Reg 'MyDrive' 4 0).t -eq 'TRACKS' -and (Reg 'MyDrive' 5 0).t -eq 'FAVOURITES')
  $null = Sheet 'deck-pick-home'
  Press 2 0 300
  Check 'RECENT opens from the home row' ((Reg 'MyDrive' 1 0).t -eq 'RECENT' -and (Reg 'MyDrive' 0 1).t -match 'CORVETTE')
  $null = Sheet 'deck-pick-recent'
  $q=PickerQuality; Check 'RECENT tiles stay on one key, uppercase, within 12/14 characters, with BACK and EXIT fixed' ($q.single -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Check 'RECENT pages forward and back' ((Reg 'MyDrive' 5 3).t -eq 'PREV' -and (Reg 'MyDrive' 6 3).t -eq 'NEXT')
  Press 6 3 300
  Check 'RECENT page two can return to page one' ((Reg 'MyDrive' 5 3).t -eq 'PREV')
  Press 5 3 300
  Press 2 0 300
  Check 'CARS pages forward and back' ((Reg 'MyDrive' 5 3).t -eq 'PREV' -and (Reg 'MyDrive' 6 3).t -eq 'NEXT')
  $q=PickerQuality; Check 'CARS tiles stay on one key, uppercase, within 12/14 characters, with BACK and EXIT fixed' ($q.single -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Req 0 1 'c=mdpick&a=c00000001' 'choosing a car'
  Check 'a car pick advances to TRACKS without starting' ((Reg 'MyDrive' 3 0).t -eq 'TRACKS' -and @(Apis | Where-Object { $_ -match 'c=mdstart' }).Count -eq 0)
  $null = Sheet 'deck-pick-tracks'
  $q=PickerQuality; Check 'TRACKS tiles stay on one key, uppercase, within 12/14 characters, with BACK and EXIT fixed' ($q.single -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Press 0 1 300
  Check 'the chosen track is saved before layout choices' (@(Apis | Where-Object { $_ -match 'c=mdpick&a=t00000001' }).Count -eq 1)
  Check 'a track with multiple layouts presents its layout names' ((Reg 'MyDrive' 0 1).t -eq 'FULL COURSE' -and (Reg 'MyDrive' 1 1).t -eq 'SHORT COURSE')
  $null = Sheet 'deck-pick-layouts'
  $q=PickerQuality; Check 'LAYOUT tiles stay on one key, uppercase, within 12/14 characters, with BACK and EXIT fixed' ($q.single -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Press 0 0 300
  Check 'BACK at 0,0 returns to MAIN' ((Cur) -eq 'main')
  Fx '/mydrive' "m.choice.has = false; m.aiStatus = 'NO CHOICE'" 200
  Js "MyDrive.autoPrompted = false; MyDrive.keyTick()" 800
  Check 'NO CHOICE opens the picker without starting AI RACE' ((Cur) -eq 'RigMyDrive' -and (Reg 'MyDrive' 1 0).t -eq 'RECENT' -and @(Apis | Where-Object { $_ -match 'c=airace|c=mdstart' }).Count -eq 0)
  $null = Sheet 'deck-pick-empty-choice'
  Fx '/mydrive' "m.aiStatus = ''; m.choice.has = true; m.choice.carShort='CORVETTE'; m.choice.trackShort='ROAD ATLANTA'; m.choice.layout='Full Course'" 100
  Js "MyDrive.view='home'; MyDrive.relayout()" 250
  Check 'RACE SETUP keeps car, track and layout on separate keys; START is one green key' ((Reg 'MyDrive' 0 1).t -eq 'CORVETTE' -and (Reg 'MyDrive' 1 1).t -eq 'ROAD ATLANTA' -and (Reg 'MyDrive' 2 1).t -eq 'LAYOUT' -and (Reg 'MyDrive' 6 3).t -eq 'START' -and (Reg 'MyDrive' 6 3).st -eq 'go')
  $null = Sheet 'deck-pick-choice'
  Js "MyDrive.exit({test:true})" 250

  # ================= 1. ANALYSIS =================
  try { Assert-RigFree -Where '1. ANALYSIS' } catch { "$_"; throw }
  '1. the ANALYSIS screen (the workbench open on lap 7)'
  $m1 = Invoke-DeckJs $page "__sd.measureOpen('analysis')"
  Start-Sleep -Milliseconds 2000                                            # the Vault answer (KEEP, COSWORTH) comes with the first refresh
  Check 'ANALYSIS opens: it asked for the RigAnalysis profile and all 32 keys have a picture' ((Cur) -eq 'RigAnalysis' -and (Sheet 'deck-analysis') -eq 32)
  Check 'all 32 pictures are on the keys within 100 ms of the deck showing the screen' ($m1.allPicturesMs -ge 0 -and ($m1.allPicturesMs - $m1.firstAppearMs) -le 100)
  $r = Reg 'Analysis' 1 0; Check 'the banner says LAP 7, the lap time and the reference' ($r.t -match 'LAP 7' -and $r.t -match '1:19\.549' -and $r.s -match 'vs PB' -and $r.s -match '1:19\.575' -and $r.s -match '0\.026')
  $r = Reg 'Analysis' 6 1; Check 'PLAY / PAUSE: paused now, so it says PLAY (green) and PAUSED' ($r.t -eq 'PLAY' -and $r.s -eq 'PAUSED' -and $r.st -eq 'go' -and $r.a -eq 'wb-toggle-play' -and $r.w -eq 2)
  $r = Reg 'Analysis' 6 2; Check 'TILE shows its real state (off)' ($r.t -eq 'TILE' -and $r.s -eq 'OFF' -and $r.st -eq 'off')
  $r = Reg 'Analysis' 3 2; Check 'SPEED shows x1' ($r.t -eq 'SPEED' -and $r.s -eq ([string][char]0xD7 + '1') -and $r.st -eq '')
  $r = Reg 'Analysis' 4 2; Check 'COMPARE shows what the lap is compared with (PB)' ($r.t -eq 'COMPARE' -and $r.s -eq 'PB')
  $r = Reg 'Analysis' 7 2; Check 'MAP COLOUR shows GAP' ($r.t -eq 'MAP COLOUR' -and $r.s -eq 'GAP')
  $r = Reg 'Analysis' 0 3; $r2 = Reg 'Analysis' 2 3; Check 'row 4 has the two pages, DRIVER (showing, gold) and GRIP' ($r.t -eq 'DRIVER' -and $r.st -eq 'sel' -and $r.w -eq 2 -and $r2.t -eq 'GRIP' -and $r2.st -eq '' -and $r2.a -eq 'wb-page' -and $r2.g -eq 'grip')
  $r = Reg 'Analysis' 6 0; Check 'KEEP is there (the lap is in the Vault, not kept yet)' ($r.t -eq 'KEEP' -and $r.a -eq 'keep' -and $r.st -eq '')
  $r = Reg 'Analysis' 7 0; Check 'COSWORTH is there because Pi Toolbox is installed' ($r.t -eq 'COSWORTH' -and $r.a -eq 'cosworth')
  Check 'the only empty cells are the four page keys that do not exist (two pages), nothing else is left blank' ((Blank 'Analysis') -eq 4)
  Check 'opening ANALYSIS wrote a timing line' (@((Invoke-DeckJs $page '__sd.perfLines()') | Where-Object { $_ -match 'perf analysis open' }).Count -ge 1)

  'a press that arrives twice at once does not flip a toggle back'
  ClearApis; Js '__sd.pressTile(6, 2); __sd.pressTile(6, 2); __sd.pressTile(6, 2)' 500
  Check 'TILE pressed three times within a blink sends one request' (@(Apis | Where-Object { $_ -match 'c=wb-tile' }).Count -eq 1)
  Start-Sleep -Milliseconds 800; ClearApis; Press 6 2 300
  Check 'a real second press a moment later still works' (@(Apis | Where-Object { $_ -match 'c=wb-tile' }).Count -eq 1)
  ClearApis; Js '__sd.pressTile(1, 1); __sd.pressTile(1, 1)' 500
  Check 'a step key (LAP >) is not held back: quick taps all count' (@(Apis | Where-Object { $_ -match 'c=wb-lap-next' }).Count -eq 2)

  'every key sends its request'
  Req 0 1 'c=wb-lap-prev' '< LAP'
  Req 1 1 'c=wb-lap-next' 'LAP >'
  Req 2 1 'c=wb-prev-corner' '< CORNER'
  Req 3 1 'c=wb-next-corner' 'CORNER >'
  Req 4 1 'c=wb-prev-event' '< EVENT'
  Req 5 1 'c=wb-next-event' 'EVENT >'
  Req 6 1 'c=wb-toggle-play' 'PLAY / PAUSE'
  Req 0 2 'c=wb-zoom-out' 'ZOOM -'
  Req 1 2 'c=wb-zoom-in' 'ZOOM +'
  Req 2 2 'c=wb-zoom-reset' 'WHOLE LAP'
  Req 3 2 'c=wb-speed' 'SPEED'
  Req 4 2 'c=wb-ref-cycle' 'COMPARE'
  Req 5 2 'c=wb-offset-auto' 'ALIGN'
  Req 6 2 'c=wb-tile' 'TILE'
  Req 7 2 'c=wb-map-colour' 'MAP COLOUR'
  Req 2 3 'c=wb-page&a=grip' 'the GRIP page'
  Req 6 0 'c=wbkeep&a=1' 'KEEP (keeps it)'
  Req 7 0 'c=wbcosworth' 'COSWORTH'
  'a press shows at once, before the page has confirmed it'
  Js 'Analysis.local = {}' 100
  Press 6 2 300; Check 'TILE says ON the moment it is pressed' ((Reg 'Analysis' 6 2).s -eq 'ON')
  Press 3 2 300; Check 'SPEED says x2 the moment it is pressed' ((Reg 'Analysis' 3 2).s -eq ([string][char]0xD7 + '2'))
  Press 0 3 300; Check 'the DRIVER tab is the gold one the moment it is pressed' ((Reg 'Analysis' 0 3).st -eq 'sel')
  Press 2 3 300; Check 'the GRIP tab is the gold one the moment it is pressed' ((Reg 'Analysis' 2 3).st -eq 'sel' -and (Reg 'Analysis' 0 3).st -eq '')

  'the page says what is really on: the keys follow it'
  Js 'Analysis.local = {}' 100
  Fx '/workbench/state' "m.playing = true; m.speed = 2; m.tile = true; m.mapColour = 'speed'; m.page = 'grip'; m.zoomed = true; m.offset = 4; m.ref = 'file.ibt:5'"
  $r = Reg 'Analysis' 6 1; Check 'playing: the key says PAUSE and PLAYING x2' ($r.t -eq 'PAUSE' -and $r.s -eq ('PLAYING ' + [char]0xD7 + '2') -and $r.st -eq '')
  $r = Reg 'Analysis' 6 2; Check 'tile on: TILE says ON' ($r.s -eq 'ON' -and $r.st -eq 'on')
  $r = Reg 'Analysis' 3 2; Check 'SPEED says x2 and is gold (not normal speed)' ($r.s -eq ([string][char]0xD7 + '2') -and $r.st -eq 'sel')
  $r = Reg 'Analysis' 7 2; Check 'MAP COLOUR says SPEED' ($r.s -eq 'SPEED')
  $r = Reg 'Analysis' 2 3; $r0 = Reg 'Analysis' 0 3; Check 'the GRIP tab is the gold one now' ($r.st -eq 'sel' -and $r0.st -eq '')
  $r = Reg 'Analysis' 2 2; Check 'WHOLE LAP is gold while zoomed in' ($r.st -eq 'sel' -and $r.s -eq 'ZOOMED IN')
  $r = Reg 'Analysis' 5 2; Check 'ALIGN shows the offset (+4 M, gold)' ($r.s -eq '+4 M' -and $r.st -eq 'sel')
  $r = Reg 'Analysis' 4 2; Check 'COMPARE says LAP 5 for another lap of the session' ($r.s -eq 'LAP 5')
  $null = Sheet 'deck-analysis-playing'
  Req 6 1 'c=wb-toggle-play' 'PAUSE while playing'

  'KEEP shows the real state; COSWORTH only when Pi Toolbox is installed'
  Fx '/vault/item' "m.m.pinned = true" 100; Js 'Analysis.vtAt = 0' 1500
  $r = Reg 'Analysis' 6 0; Check 'kept: KEPT in gold, TAP TO LET GO' ($r.t -eq 'KEPT' -and $r.st -eq 'sel' -and $r.s -eq 'TAP TO LET GO')
  Req 6 0 'c=wbkeep&a=0' 'KEPT (lets it go)'
  Fx '/vault/item' "m.cosworth.installed = false; m.m.pinned = false" 100; Fx '/vault' "m.cosworth.installed = false" 100; Js 'Analysis.vtAt = 0' 1500
  Check 'Pi Toolbox not installed: there is no COSWORTH key (the cell is empty)' ($null -eq (Reg 'Analysis' 7 0))
  Fx '/vault/item' "delete m.m; m.error = 'no such moment'" 100; Js 'Analysis.vtAt = 0' 1500
  $r = Reg 'Analysis' 6 0; Check 'a lap that is not in the Vault: KEEP is dim and says so (no press)' ($r.t -eq 'KEEP' -and $r.s -eq 'NOT IN VAULT' -and $r.st -eq 'dim' -and -not $r.a)
  NoReq 6 0 'the dim KEEP'
  Fx '/vault/item' "m.m = { pinned: false, keeper: false }; m.cosworth = { installed: true }; delete m.error" 100; Fx '/vault' "m.cosworth.installed = true" 100; Js 'Analysis.vtAt = 0' 1500

  'one page only: no tab row; many pages: narrow tabs'
  Fx '/workbench/state' "m.pages = ['driver']; m.page = 'driver'; m.playing = false; m.zoomed = false"
  Check 'with one page there is no choice, so no tab keys' ($null -eq (Reg 'Analysis' 0 3))
  # the six pages the workbench really reports (C-41 / C-41b): short labels, the whole row used (8 keys: DRIVER and GRIP wide, the other four narrow)
  Fx '/workbench/state' "m.pages = ['driver', 'grip', 'braking', 'tyres', 'suspension', 'splits']; m.page = 'driver'"
  $six = @(); foreach ($c in 0, 2, 4, 5, 6, 7) { $six += , (Reg 'Analysis' $c 3) }
  Check 'six pages: six page keys in the bottom row, labelled DRIVER, GRIP, BRAKES, TYRES, SUSP., SPLITS' (@($six | Where-Object { $_ }).Count -eq 6 -and (($six | ForEach-Object { $_.t }) -join ',') -eq 'DRIVER,GRIP,BRAKES,TYRES,SUSP.,SPLITS')
  Check 'six pages: each key opens its own page (wb-page with the page id braking / tyres / suspension / splits ...)' ((($six | ForEach-Object { $_.a + ':' + $_.g }) -join ',') -eq 'wb-page:driver,wb-page:grip,wb-page:braking,wb-page:tyres,wb-page:suspension,wb-page:splits')
  Check 'six pages: DRIVER and GRIP are two keys wide, the other four one wide, so the row is full (no empty cell, no dead key)' ((($six | ForEach-Object { $_.w }) -join ',') -eq '2,2,1,1,1,1' -and (Blank 'Analysis') -eq 0)
  Check 'six pages: the page on show is the gold one (DRIVER, SHOWING), the others are plain' ($six[0].st -eq 'sel' -and $six[0].s -eq 'SHOWING' -and @($six[1..5] | Where-Object { $_.st -ne '' }).Count -eq 0)
  Check 'six pages: every label is 7 characters or fewer on the narrow keys (16 at most anywhere)' (@($six | Where-Object { $_.t.Length -gt $(if ($_.w -eq 1) { 7 } else { 16 }) }).Count -eq 0)
  $null = Sheet 'deck-analysis-sixpages'
  Req 5 3 'c=wb-page&a=tyres' 'the TYRES key'
  Req 7 3 'c=wb-page&a=splits' 'the SPLITS key'
  Js 'Analysis.local = {}' 100

  # PL-1: more than 8 pages (a clip and a race log make ten): the row shows the first 7 and a PAGES key, which opens a picker with every page and a BACK
  'seven, eight, nine and ten pages (DRIVER GRIP BRAKES TYRES SUSP. SPLITS VIDEO RACE CAREER PRO)'
  Fx '/workbench/state' "m.pages = ['driver', 'grip', 'braking', 'tyres', 'suspension', 'splits', 'career']; m.page = 'driver'"
  $r7 = @(); $col = 0; foreach ($w in 2, 1, 1, 1, 1, 1, 1) { $r7 += , (Reg 'Analysis' $col 3); $col += $w }
  Check 'seven pages: DRIVER wide, then GRIP BRAKES TYRES SUSP. SPLITS CAREER narrow; the 8 keys are all used, no PAGES key' ((($r7 | ForEach-Object { $_.t }) -join ',') -eq 'DRIVER,GRIP,BRAKES,TYRES,SUSP.,SPLITS,CAREER' -and (($r7 | ForEach-Object { $_.w }) -join ',') -eq '2,1,1,1,1,1,1' -and (Blank 'Analysis') -eq 0 -and @($r7 | Where-Object { $_.a -eq 'pages' }).Count -eq 0)
  Fx '/workbench/state' "m.pages = ['driver', 'grip', 'braking', 'tyres', 'suspension', 'splits', 'video', 'race']; m.page = 'driver'"
  $r8 = @(); foreach ($c in 0..7) { $r8 += , (Reg 'Analysis' $c 3) }
  Check 'eight pages: unchanged - eight narrow page keys DRIVER..RACE, no PAGES key, nothing blank' ((($r8 | ForEach-Object { $_.t }) -join ',') -eq 'DRIVER,GRIP,BRAKES,TYRES,SUSP.,SPLITS,VIDEO,RACE' -and @($r8 | Where-Object { $_.w -ne 1 -or $_.a -ne 'wb-page' }).Count -eq 0 -and (Blank 'Analysis') -eq 0)
  Fx '/workbench/state' "m.pages = ['driver', 'grip', 'braking', 'tyres', 'suspension', 'splits', 'video', 'race', 'career']; m.page = 'driver'"
  $r9 = @(); foreach ($c in 0..7) { $r9 += , (Reg 'Analysis' $c 3) }
  Check 'nine pages: seven page keys and PAGES (the 8th and 9th pages are behind it)' ((($r9 | ForEach-Object { $_.t }) -join ',') -eq 'DRIVER,GRIP,BRAKES,TYRES,SUSP.,SPLITS,VIDEO,PAGES' -and $r9[7].a -eq 'pages' -and $r9[7].s -eq 'ALL 9')
  $ten = "['driver', 'grip', 'braking', 'tyres', 'suspension', 'splits', 'video', 'race', 'career', 'pro']"
  Fx '/workbench/state' "m.pages = $ten; m.page = 'driver'"
  $r10 = @(); foreach ($c in 0..7) { $r10 += , (Reg 'Analysis' $c 3) }
  Check 'ten pages: the row is DRIVER GRIP BRAKES TYRES SUSP. SPLITS VIDEO and PAGES, 8 keys, all one wide, nothing blank' ((($r10 | ForEach-Object { $_.t }) -join ',') -eq 'DRIVER,GRIP,BRAKES,TYRES,SUSP.,SPLITS,VIDEO,PAGES' -and @($r10 | Where-Object { $_.w -ne 1 }).Count -eq 0 -and (Blank 'Analysis') -eq 0)
  Check 'ten pages: the seven page keys open their pages, PAGES opens the picker (and says ALL 10); DRIVER is the gold one' ((($r10[0..6] | ForEach-Object { $_.a + ':' + $_.g }) -join ',') -eq 'wb-page:driver,wb-page:grip,wb-page:braking,wb-page:tyres,wb-page:suspension,wb-page:splits,wb-page:video' -and $r10[7].a -eq 'pages' -and $r10[7].s -eq 'ALL 10' -and $r10[7].st -eq '' -and $r10[0].st -eq 'sel')
  $null = Sheet 'deck-analysis-pages'
  Fx '/workbench/state' "m.page = 'pro'"
  $r = Reg 'Analysis' 7 3; Check 'the page on show is behind PAGES (PRO): the PAGES key is the gold one and names it' ($r.t -eq 'PAGES' -and $r.st -eq 'sel' -and $r.s -eq 'PRO' -and @(0..6 | Where-Object { (Reg 'Analysis' $_ 3).st -eq 'sel' }).Count -eq 0)
  Fx '/workbench/state' "m.page = 'driver'"
  ClearApis; Press 7 3 150; Press 2 3 100          # PAGES, and the same press arriving again at once: on the picker's layout that key is PRO
  $dup = @(Apis | Where-Object { $_ -match 'c=wb' }).Count
  $r = Reg 'Analysis' 0 0; Check 'PAGES opened the picker: BACK is the top-left key (it returns to the analysis keys, it does not leave them)' ($r.t -eq 'BACK' -and $r.a -eq 'pagesback' -and (Cur) -eq 'RigAnalysis')
  Check 'the PAGES press arriving again at once did not pick a page by accident (nothing sent)' ($dup -eq 0)
  $r = Reg 'Analysis' 1 0; Check 'the picker has a title line' ($r.t -eq 'PAGES' -and -not $r.a)
  $pk = @(); foreach ($p in @(@(0, 1), @(2, 1), @(4, 1), @(6, 1), @(0, 2), @(2, 2), @(4, 2), @(6, 2), @(0, 3), @(2, 3))) { $pk += , (Reg 'Analysis' $p[0] $p[1]) }
  Check 'the picker shows every page as a big key, in order, named DRIVER GRIP BRAKES TYRES SUSP. SPLITS VIDEO RACE CAREER PRO' (@($pk | Where-Object { $_ }).Count -eq 10 -and (($pk | ForEach-Object { $_.t }) -join ',') -eq 'DRIVER,GRIP,BRAKES,TYRES,SUSP.,SPLITS,VIDEO,RACE,CAREER,PRO')
  Check 'picker: each key opens its own page (wb-page with the id), every key two wide, DRIVER (on show) gold' ((($pk | ForEach-Object { $_.a + ':' + $_.g }) -join ',') -eq 'wb-page:driver,wb-page:grip,wb-page:braking,wb-page:tyres,wb-page:suspension,wb-page:splits,wb-page:video,wb-page:race,wb-page:career,wb-page:pro' -and @($pk | Where-Object { $_.w -ne 2 }).Count -eq 0 -and $pk[0].st -eq 'sel' -and $pk[0].s -eq 'SHOWING' -and @($pk[1..9] | Where-Object { $_.st -ne '' }).Count -eq 0)
  Check 'picker: opening it sent nothing to the analysis page (no wb- command)' (@(Apis | Where-Object { $_ -match 'c=wb' }).Count -eq 0)
  $null = Sheet 'deck-analysis-picker'
  Start-Sleep -Milliseconds 900
  ClearApis; Press 2 3 150; Press 2 3 100          # PRO in the picker, and the same press arriving again: on the analysis keys that key is BRAKES
  $sent = @(Apis | Where-Object { $_ -match 'c=wb' })
  Check 'the PRO key in the picker asks the page for PRO, once (the repeat is ignored, it would have been BRAKES)' ($sent.Count -eq 1 -and $sent[0] -match 'c=wb-page&a=pro')
  $r = Reg 'Analysis' 0 0; $r7k = Reg 'Analysis' 7 3
  Check 'a page picked: the picker closed by itself, the analysis keys are back (BACK leaves) and PAGES shows PRO in gold at once' ($r.a -eq 'back' -and $r7k.a -eq 'pages' -and $r7k.s -eq 'PRO' -and $r7k.st -eq 'sel' -and (Cur) -eq 'RigAnalysis')
  Js 'Analysis.local = {}' 900
  Press 7 3 900
  Press 0 0 100                                    # BACK in the picker, then the same press again: on the analysis keys that key leaves the screen
  Press 0 0 100
  $r = Reg 'Analysis' 0 0; Check 'BACK in the picker closes the picker and stays on the analysis keys (a second BACK press at once does not leave them)' ($r.a -eq 'back' -and (Cur) -eq 'RigAnalysis' -and (Reg 'Analysis' 7 3).a -eq 'pages')
  Fx '/workbench/state' "m.pages = ['driver', 'grip']; m.page = 'driver'"
  Check 'with only two pages again there is no PAGES key and no picker left open' ((Reg 'Analysis' 7 3) -eq $null -and (Reg 'Analysis' 0 0).a -eq 'back')
  Js 'Analysis.local = {}' 100
  Fx '/workbench/state' "m.pages = ['driver', 'grip']; m.laps = 1; m.corners = 0; m.events = 0; m.refTime = null; m.ref = 'pb'"
  $r = Reg 'Analysis' 0 1; $r2 = Reg 'Analysis' 2 1; $r3 = Reg 'Analysis' 4 1
  Check 'one lap, no corners, no events: those keys are dim and say why (no press)' ($r.st -eq 'dim' -and $r.s -eq 'ONLY ONE' -and -not $r.a -and $r2.st -eq 'dim' -and $r2.s -eq 'NONE FOUND' -and $r3.st -eq 'dim' -and -not $r3.a)
  $r = Reg 'Analysis' 1 0; Check 'no reference lap: the banner says so' ($r.s -eq 'no reference lap')
  NoReq 0 1 'a dim LAP key'
  $null = Sheet 'deck-analysis-nothing-to-step'

  'no lap open / in the car / program not updated'
  Fx '/workbench/state' "m.open = false"
  $r = Reg 'Analysis' 0 1; Check 'no lap open: it says NO LAP OPEN and only BACK is a key' ($r.t -eq 'NO LAP OPEN' -and -not $r.a -and (Reg 'Analysis' 0 0).a -eq 'back' -and $null -eq (Reg 'Analysis' 6 1).a)
  Check 'no lap open: all 32 keys still have a picture' ((Sheet 'deck-analysis-nolap') -eq 32)
  Fx '/workbench/state' "m.open = true; m.driving = true"
  $r = Reg 'Analysis' 0 1; Check 'in the car: GET OUT OF THE CAR, nothing else to press' ($r.t -eq 'GET OUT OF THE CAR' -and -not (Reg 'Analysis' 3 1).a)
  $null = Sheet 'deck-analysis-driving'
  Js "Analysis.readState = async function () { this.a = { open: false, off: true, driving: false }; }" 1500
  $r = Reg 'Analysis' 0 1; Check 'irdash not updated yet (no /workbench/state): NOT READY' ($r.t -eq 'NOT READY')
  $null = Sheet 'deck-analysis-notready'
  Press 0 0 700
  Check 'BACK returns to your own keys' ((Cur) -eq 'main')
  Js "delete Analysis.readState" 100
  Fx '/workbench/state' "m.open = true; m.driving = false" 100

  'the page side of the feed: the report dash\www\v2\workbench.js builds (its own code, run here with stand-in data)'
  $wbjs = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\workbench.js'))
  $i0 = $wbjs.IndexOf('function deckReport() {'); $i1 = $wbjs.IndexOf('// the deck: irdash keeps the last wb-* command')
  $reportJs = if ($i0 -gt 0 -and $i1 -gt $i0) { $wbjs.Substring($i0, $i1 - $i0) } else { '' }
  # the page's own lap-counts helpers (C-41b: a lap counts by the session reply when it is there, else the lap store's clean flag), run with the same stand-in data
  $j0 = $wbjs.IndexOf('function sessLap(l)'); $j1 = $wbjs.IndexOf('function header() {'); $reportJs = $(if ($j0 -gt 0 -and $j1 -gt $j0) { $wbjs.Substring($j0, $j1 - $j0) } else { '' }) + $reportJs
  Check 'workbench.js has the deckReport / deckState functions in front of pollDeck, and pollDeck sends the report with its poll' ($reportJs -ne '' -and $wbjs.Contains("fetch('/workbench/cmd?' + deckState()") -and $wbjs.Contains('function deckState()'))
  $stubA = "const D = { head: { lap: { lap: 7, time: 79.549 }, ref: { time: 79.575, lap: 3 }, laps: [{ clean: true }, { clean: false }, { clean: true }], car: 'Chevrolet Corvette Z06 GT3.R', track: 'Road Atlanta' }, events: [1, 2, 3], corners: [1, 2], step: 1 }; const S = { page: 'driver', playing: false, speed: 1, tile: false, axis: 'dist', mapColour: 'gap', offsetMode: false, offset: 0 }; const PAGES = [{ id: 'driver' }, { id: 'grip' }]; const pages = () => PAGES; const zoomed = () => false; const P = { get: k => ({ id: 'l20261010-041318-7' })[k] || null };"
  $stubB = "const D = { head: { lap: { lap: 7, time: 79.549 }, ref: { time: 79.575, lap: 3 }, laps: [{ clean: true }, { clean: false }, { clean: true }], car: 'Chevrolet Corvette Z06 GT3.R', track: 'Road Atlanta' }, events: [1, 2, 3], corners: [1, 2], step: 1 }; const S = { page: 'grip', playing: true, speed: 0.5, tile: true, axis: 'time', mapColour: 'speed', offsetMode: false, offset: -3 }; const PAGES = [{ id: 'driver' }, { id: 'grip' }]; const pages = () => PAGES; const zoomed = () => true; const P = { get: k => ({ id: 'l20261010-041318-7', ref: 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt:5' })[k] || null };"
  $stubC = $stubA.Replace("ref: { time: 79.575, lap: 3 }", "ref: null")
  $qA = Invoke-DeckJs $page "(() => { $stubA; $reportJs; return deckReport(); })()"
  $qB = Invoke-DeckJs $page "(() => { $stubB; $reportJs; return deckReport(); })()"
  $qC = Invoke-DeckJs $page "(() => { $stubC; $reportJs; return deckReport(); })()"
  Check 'the report names the page, the lap and its time, the reference time, the number of clean laps, events and corners' ($qA -match '(^|&)pg=driver(&|$)' -and $qA -match 'pgs=driver%2Cgrip' -and $qA -match '(^|&)lap=7(&|$)' -and $qA -match 'lt=79\.549' -and $qA -match 'rt=79\.575' -and $qA -match '(^|&)nl=2(&|$)' -and $qA -match '(^|&)ne=3(&|$)' -and $qA -match '(^|&)nc=2(&|$)' -and $qA -match '(^|&)id=l20261010-041318-7(&|$)')
  Check 'the report carries the real state: playing, speed 0.5, tile on, zoomed, offset -3, map colour' ($qB -match '(^|&)pl=1(&|$)' -and $qB -match '(^|&)sp=0\.5(&|$)' -and $qB -match '(^|&)tl=1(&|$)' -and $qB -match '(^|&)z=1(&|$)' -and $qB -match '(^|&)of=-3(&|$)' -and $qB -match '(^|&)mc=speed(&|$)' -and $qB -match '(^|&)pg=grip(&|$)')
  Check 'with no reference lap the reference time and lap are empty' ($qC -match '(^|&)rt=(&|$)' -and $qC -match '(^|&)rl=(&|$)')
  $wbQuery = $qB

  # ================= 1b. the DEBRIEF row (D-05) =================
  # The bottom row of the ANALYSIS screen: SAVE / SHARE / COSWORTH / DEEP DIVE act on the debrief the top screen is
  # showing. With no debrief the four keys are dim; with one, each is live only when its action is available, and every
  # key sends the debrief id the /debrief/state reply named (irdash refuses anything else).
  '1b. the DEBRIEF row on the ANALYSIS screen (D-05): four live keys, dim without a debrief'
  Fx '/workbench/state' "m.open = false; m.driving = false" 100
  Fx '/debrief/state' "m.open = false" 100
  $null = Invoke-DeckJs $page "__sd.measureOpen('analysis')"
  Start-Sleep -Milliseconds 1500
  $r = Reg 'Analysis' 0 3; $r2 = Reg 'Analysis' 2 3; $r3 = Reg 'Analysis' 4 3; $r4 = Reg 'Analysis' 6 3
  Check 'no debrief: the four keys say SAVE SHARE COSWORTH DEEP DIVE, all dim, nothing to press' ($r.t -eq 'SAVE' -and $r2.t -eq 'SHARE' -and $r3.t -eq 'COSWORTH' -and $r4.t -eq 'DEEP DIVE' -and $r.st -eq 'dim' -and $r2.st -eq 'dim' -and $r3.st -eq 'dim' -and $r4.st -eq 'dim' -and -not $r.a -and -not $r2.a -and -not $r3.a -and -not $r4.a)
  NoReq 0 3 'a dim SAVE key'
  $null = Sheet 'deck-analysis-debrief-dim'
  Fx '/debrief/state' "Object.assign(m, { open: true, id: 'l20261010-041318-7', recId: '20261010-041318-roadatlanta', saved: false, shareId: 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt:8', deepDive: { id: 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt', lap: 8, corner: 'T10a', cornerN: 10 } })" 100
  Start-Sleep -Milliseconds 900
  $r = Reg 'Analysis' 0 3; $r2 = Reg 'Analysis' 2 3; $r3 = Reg 'Analysis' 4 3; $r4 = Reg 'Analysis' 6 3
  Check 'a debrief showing: all four keys are live, each two keys wide, none dim' ($r.t -eq 'SAVE' -and $r.a -eq 'db-save' -and $r2.t -eq 'SHARE' -and $r2.a -eq 'db-share' -and $r3.t -eq 'COSWORTH' -and $r3.a -eq 'db-cosworth' -and $r4.t -eq 'DEEP DIVE' -and $r4.a -eq 'db-deepdive' -and $r.w -eq 2 -and $r2.w -eq 2 -and $r3.w -eq 2 -and $r4.w -eq 2 -and $r.st -ne 'dim' -and $r2.st -ne 'dim' -and $r3.st -ne 'dim' -and $r4.st -ne 'dim')
  $null = Sheet 'deck-analysis-debrief'
  Req 0 3 'c=db-save&a=l20261010-041318-7' 'SAVE (the recorder session)'
  Req 2 3 'c=db-share&a=l20261010-041318-7' 'SHARE (the lap clip)'
  Req 4 3 'c=db-cosworth&a=l20261010-041318-7' 'COSWORTH'
  Req 6 3 'c=db-deepdive&a=l20261010-041318-7' 'DEEP DIVE'
  'a key is dim when its action is not available'
  Fx '/debrief/state' "m.shareId = null; m.recId = null" 100
  Start-Sleep -Milliseconds 900
  Check 'no recorder session and no clip: SAVE and SHARE are dim (nothing to press)' ((Reg 'Analysis' 0 3).st -eq 'dim' -and -not (Reg 'Analysis' 0 3).a -and (Reg 'Analysis' 2 3).st -eq 'dim' -and -not (Reg 'Analysis' 2 3).a)
  Fx '/vault' "m.cosworth.installed = false" 100
  Fx '/debrief/state' "m.shareId = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt:8'; m.recId = '20261010-041318-roadatlanta'" 100
  Start-Sleep -Milliseconds 7000
  Check 'Pi Toolbox not installed: the COSWORTH key is dim' ((Reg 'Analysis' 4 3).st -eq 'dim' -and -not (Reg 'Analysis' 4 3).a)
  Fx '/vault' "m.cosworth.installed = true" 100
  Fx '/debrief/state' "m.open = false" 100
  Start-Sleep -Milliseconds 900
  Check 'no debrief again: the four keys are dim once more' ((Reg 'Analysis' 0 3).st -eq 'dim' -and -not (Reg 'Analysis' 0 3).a)
  Press 0 0 700
  Check 'BACK leaves the ANALYSIS keys for your own keys' ((Cur) -eq 'main')

  try { Assert-RigFree -Where '2. SOUND' } catch { "$_"; throw }
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

  # ================= 3. RACE SETUP =================
  try { Assert-RigFree -Where '3. RACE SETUP' } catch { "$_"; throw }
  ''; '3. RACE SETUP and the list picker'
  $m3 = Invoke-DeckJs $page "__sd.measureOpen('mydrive')"
  Start-Sleep -Milliseconds 1000
  Js "MyDrive.view='home'; MyDrive.m.choice.has=true; MyDrive.m.choice.carShort='CORVETTE'; MyDrive.m.choice.trackShort='ROAD ATLANTA'; MyDrive.m.choice.layout='Full Course'; MyDrive.relayout()" 250
  Check 'RACE SETUP home renders all 32 keys' ((Sheet 'deck-pick-home') -eq 32)
  Check 'home row has LAST DRIVE, RECENT, CARS, TRACKS and FAVOURITES on single keys' ((Reg 'MyDrive' 1 0).t -match 'CORVETTE' -and (Reg 'MyDrive' 2 0).t -eq 'RECENT' -and (Reg 'MyDrive' 3 0).t -eq 'CARS' -and (Reg 'MyDrive' 4 0).t -eq 'TRACKS' -and (Reg 'MyDrive' 5 0).t -eq 'FAVOURITES')
  Check 'the chosen car, track and layout each have one key; START is one green key' ((Reg 'MyDrive' 0 1).t -eq 'CORVETTE' -and (Reg 'MyDrive' 1 1).t -eq 'ROAD ATLANTA' -and (Reg 'MyDrive' 2 1).t -eq 'LAYOUT' -and (Reg 'MyDrive' 6 3).t -eq 'START' -and (Reg 'MyDrive' 6 3).st -eq 'go')
  Check 'home keeps BACK at 0,0 and EXIT at 7,3' ((Reg 'MyDrive' 0 0).t -eq 'BACK' -and (Reg 'MyDrive' 7 3).t -eq 'EXIT')
  Press 5 0 300
  Check 'FAVOURITES opens its own one-key combo list' ((Reg 'MyDrive' 4 0).t -eq 'FAVOURITES' -and (Reg 'MyDrive' 0 1).a -eq 'mdpick')
  Js 'MyDrive.relayout()' 300
  $null = Sheet 'deck-pick-favourites'
  $q=PickerQuality; Check 'FAVOURITES uses one-key uppercase tiles, two text lines, BACK and EXIT' ($q.single -and $q.twoLines -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Press 1 0 300
  'CARS -> TRACKS -> LAYOUTS'
  Press 2 0 300
  Check 'CARS starts with class tabs and has a one-key car list' ((Reg 'MyDrive' 4 0).t -eq 'GT3' -and (Reg 'MyDrive' 0 1).w -eq 1)
  Js 'MyDrive.relayout()' 300
  $null = Sheet 'deck-pick-cars'
  $q=PickerQuality; Check 'CARS uses one-key uppercase tiles, two text lines, short lines, BACK and EXIT' ($q.single -and $q.twoLines -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Check 'SEARCH is the last key on CARS' ((Reg 'MyDrive' 4 3).t -eq 'SEARCH')
  Press 0 1 300
  Check 'choosing a car advances to TRACKS and sends mdpick' ((Reg 'MyDrive' 3 0).t -eq 'TRACKS' -and @(Apis | Where-Object { $_ -match 'c=mdpick&a=c00000001' }).Count -eq 1 -and @(Apis | Where-Object { $_ -match 'c=mdstart' }).Count -eq 0)
  Js 'MyDrive.relayout()' 300
  $null = Sheet 'deck-pick-tracks'
  $q=PickerQuality; Check 'TRACKS uses one-key uppercase tiles, two text lines, short lines, BACK and EXIT' ($q.single -and $q.twoLines -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Check 'SEARCH is the last key on TRACKS' ((Reg 'MyDrive' 4 3).t -eq 'SEARCH')
  Press 0 1 300
  Check 'choosing a track saves it and opens its layout list' (@(Apis | Where-Object { $_ -match 'c=mdpick&a=t00000001' }).Count -eq 1 -and (Reg 'MyDrive' 0 1).t -eq 'FULL COURSE')
  Js 'MyDrive.relayout()' 300
  $null = Sheet 'deck-pick-layouts'
  $q=PickerQuality; Check 'LAYOUTS uses one-key uppercase tiles, two text lines, short lines, BACK and EXIT' ($q.single -and $q.twoLines -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Press 0 1 300
  Check 'choosing a layout saves it and returns to MAIN' (@(Apis | Where-Object { $_ -match 'c=mdpick&a=l' }).Count -ge 1 -and (Cur) -eq 'main')
  Fx '/mydrive' "m.choice.has = false; m.aiStatus = 'NO CHOICE'" 200
  Js "MyDrive.autoPrompted = false; MyDrive.keyTick()" 800
  Check 'NO CHOICE opens the picker without starting AI RACE' ((Cur) -eq 'RigMyDrive' -and (Reg 'MyDrive' 1 0).t -eq 'RECENT' -and @(Apis | Where-Object { $_ -match 'c=airace|c=mdstart' }).Count -eq 0)
  $null = Sheet 'deck-pick-empty-choice'
  $q=PickerQuality; Check 'RECENT uses one-key uppercase tiles, two text lines, short lines, BACK and EXIT' ($q.single -and $q.twoLines -and $q.upper -and $q.lengths -and $q.back -and $q.exit)
  Fx '/mydrive' "m.aiStatus = ''; m.choice.has = true" 100
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
Check 'MY DRIVE no longer has the dim AI RACE / coming later tile' (-not ($plug -match "'AI RACE'") -and -not ($plug -match 'coming later'))
Check 'the PHOTO key''s long line is short now' (-not $plug.Contains('SWITCH ON IN IRACING SETTINGS') -and $plug.Contains("'PHOTO', 'TURN ON IN IRACING'"))
$inst = [IO.File]::ReadAllText((Join-Path $root 'deck-intro\install.ps1'))
Check 'install.ps1 has a higher version than 1.6.1.0 and bundles the RigAnalysis and RigSound profiles with their actions' ($inst -match "\`$ver = '1\.([7-9]|\d\d)\.\d+\.\d+'" -and $inst.Contains("Build-Profile 'RigAnalysis' 'analysis'") -and $inst.Contains("Build-Profile 'RigSound' 'sound'") -and $inst.Contains('$uuid.analysis') -and $inst.Contains('$uuid.sound'))

''
"$pass passed, $fail failed. Pictures in $shots"
if ($fail -gt 0) { exit 1 }
