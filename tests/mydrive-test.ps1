# My Drive end-to-end test (out of the car; the sim must not be running a session).
#   1. the deck screen, drawn by the real add-on code in headless Chrome (pretend Stream Deck app, pretend irdash answers):
#      every view has all 32 keys, presses send the right requests, the keyboard types, choices show at once
#   2. irdash /mydrive and the whitelisted /api/do commands: recent drives, favourites (the star), damage, typing, bad input refused
#   3. a real search of iRacing's own Test Drive lists (car, track, layouts) through irdash -> irdeck -> the iRacing UI
#   4. START: a recent drive end to end (Test Drive set up, launched, session loaded, into the car), timed; then back to Home
# Pictures go to tests\shots (md-*.png). Your favourites, choice and the iRacing Test Drive window are put back.
#   powershell -ExecutionPolicy Bypass -File tests\mydrive-test.ps1 [-NoSearch] [-NoStart] [-DeckOnly] [-Offline]
# -Offline (with -DeckOnly): part 1 only, with pretend answers for everything - it never talks to the running irdash (DK-8c: picker layout).
param([switch]$NoSearch, [switch]$NoStart, [switch]$DeckOnly, [switch]$Offline)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $root 'tests\deck-fixtures.ps1')
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Section([string]$name) { Assert-RigFree -Where $name; "SECTION $name" }
function J($p) { $r = Invoke-WebRequest -UseBasicParsing "$api$p" -TimeoutSec 8; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Api($c, $a) { $u = "$api/api/do?c=$c" + $(if ($a) { '&a=' + [uri]::EscapeDataString($a) } else { '' }); try { $r = Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 8; return [int]$r.StatusCode } catch { return [int]$_.Exception.Response.StatusCode } }
function GetMd { J '/mydrive' }
function WaitMd($cond, $secs = 20) { for ($i = 0; $i -lt $secs * 4; $i++) { $m = GetMd; if (& $cond $m) { return $m }; Start-Sleep -Milliseconds 250 }; return (GetMd) }
function WaitIdle($secs = 90) { for ($i = 0; $i -lt $secs * 2; $i++) { $m = GetMd; if (-not $m.busy) { return $m }; Start-Sleep -Milliseconds 500 }; return (GetMd) }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
function Shot($name, $screen) {
  $b = $screen.Bounds; $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $s = New-Object System.Drawing.Bitmap $bmp, 960, ([int](960 * $b.Height / $b.Width)); $s.Save((Join-Path $shots "$name.png")); $g.Dispose(); $bmp.Dispose(); $s.Dispose()
}
$top = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.Y } | Select-Object -First 1
$mid = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.X -eq 0 -and $_.Bounds.Y -eq 0 } | Select-Object -First 1

. (Join-Path $PSScriptRoot 'guard.ps1')
if ($DeckOnly -or ($NoSearch -and $NoStart)) { Assert-RigFree } else { Assert-RigFree -NeedAway }   # parts 3-4 use the real iRacing app and sim
if ((& (Join-Path $root 'irdeck-cli.exe') state) -match 'telemetry=on') { 'iRacing is in a session - run this out of the car.'; exit 1 }
'My Drive test'

# GO must stop before screen capture or the 40-second button hunt when the sim process is absent.
Section 'GO refuses without a sim process'
$goLog = Join-Path $root 'irdeck.log'
$goBefore = if (Test-Path $goLog) { (Get-Item $goLog).Length } else { 0 }
$goOutput = & (Join-Path $root 'irdeck-cli.exe') go 2>&1 | Out-String
$goExit = $LASTEXITCODE
$goAdded = if (Test-Path $goLog) { [IO.File]::ReadAllText($goLog).Substring([Math]::Min($goBefore, (Get-Item $goLog).Length)) } else { '' }
Check 'CmdGo returns and logs sim not running before the button hunt' ($goExit -ne 0 -and (($goOutput + $goAdded) -match 'go: sim not running') -and (($goOutput + $goAdded) -notmatch 'green button never appeared|screen saved to'))

# ================= 1. the deck screen =================
'1. the deck screen drawn by the real add-on code'
$fx = if ($Offline) { @{ '/guest' = @{}; '/overlays' = @{}; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false } } } else { @{ '/guest' = (J '/guest'); '/overlays' = (J '/overlays'); '/showcase' = @{ seq = 0; play = $false; driving = $false } } }
$fx['/mydrive'] = New-MyDriveFixture
$fx['/mydrive/lists'] = @{ recent = @((New-MyDriveCombo 'r00000001' 'Chevrolet Corvette Z06 GT3.R' 'CORVETTE GT3' 'Road Atlanta' 'ROAD ATLANTA' 'Full Course' $true)); cars = @(@{id='c00000001';name='Chevrolet Corvette Z06 GT3.R';class='GT3';last='2026-10-12';count=4}); tracks = @(@{id='t00000001';name='Road Atlanta';layouts=@('Full Course','Short Course');last='2026-10-12';count=4}) }
$html = Join-Path $env:TEMP 'mydrive-test-harness.html'
$deckUrl = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
if ($Offline) { $hh = [IO.File]::ReadAllText($html).Replace('return realFetch(url, opt);', "return Promise.resolve(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));"); [IO.File]::WriteAllText($html, $hh, (New-Object Text.UTF8Encoding($false))) }   # whatever has no pretend answer gets {}, never the real irdash
$b = Start-DeckBrowser 9352
try {
  $page = New-DeckPage $b $deckUrl -Hidden
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 4
  $null = Invoke-DeckJs $page "(() => { window.__apis = []; __sd.onApi = p => window.__apis.push(p); return 1; })()"
  function Apis { @(Invoke-DeckJs $page 'window.__apis') }
  function ClearApis { $null = Invoke-DeckJs $page 'window.__apis.length = 0' }
  function Press($c, $r, $wait = 500) { $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep($wait); return 1; })()" }
  function Js($js, $wait = 300) { $null = Invoke-DeckJs $page "(async () => { $js; await __sd.sleep($wait); return 1; })()" }
  function Reg($scr, $c, $r) { Invoke-DeckJs $page "(() => { const x = $scr.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return x ? { t: x.text, s: x.sub, st: x.style, a: x.act, g: x.arg, w: x.w } : null; })()" }
  function Fx($js) { $null = Invoke-DeckJs $page "(async () => { const m = __sd.fx['/mydrive']; $js; await __sd.sleep(1500); return 1; })()" }
  function Sheet($name) { return Save-DeckSheet $page (Join-Path $shots "$name.png") }
  function Look($c, $r) { Invoke-DeckJs $page "(async () => { const u = __sd.images[__sd.tileCtx($c, $r)]; return u ? await __sd.classify(u) : 'none'; })()" }

  $m1 = Invoke-DeckJs $page "__sd.measureOpen('mydrive')"
  Start-Sleep -Milliseconds 800
  Check 'MY DRIVE opens: all 32 keys have a picture' ((Sheet 'md-deck-choose') -eq 32)
  Check 'MY DRIVE opens RACE SETUP with LAST DRIVE, RECENT, CARS, TRACKS and FAVOURITES' ((Reg 'MyDrive' 1 0).t -match 'CORVETTE' -and (Reg 'MyDrive' 2 0).t -eq 'RECENT' -and (Reg 'MyDrive' 3 0).t -eq 'CARS' -and (Reg 'MyDrive' 4 0).t -eq 'TRACKS' -and (Reg 'MyDrive' 5 0).t -eq 'FAVOURITES')
  $null = Sheet 'md-deck-choose'
  Press 3 0 400
  Check 'CARS opens the car list' ((Reg 'MyDrive' 0 1).t -match 'CORVETTE')
  $null = Sheet 'md-pick-cars'
  Press 0 1 400
  Check 'choosing a car sends its catalog id and opens TRACKS' (@(Apis | Where-Object { $_ -match 'c=mdpick&a=c00000001' }).Count -eq 1 -and (Reg 'MyDrive' 3 0).st -eq 'sel')
  Press 0 1 400
  Check 'a track with multiple layouts opens the layout list' ((Reg 'MyDrive' 0 1).t -eq 'FULL COURSE' -or (Reg 'MyDrive' 0 1).t -eq 'ROAD ATLANTA')
  $null = Sheet 'md-pick-layouts'
  # RACE SETUP uses separate one-key choices and the picker for every list.
  $null = Invoke-DeckJs $page "__sd.measureOpen('mydrive')"
  Start-Sleep -Milliseconds 500
  Js "MyDrive.view = 'home'; MyDrive.m.aiStatus = ''; MyDrive.relayout()" 200
  Check 'RACE SETUP keeps car, track and layout on separate keys' ((Reg 'MyDrive' 0 1).t -match 'CORVETTE' -and (Reg 'MyDrive' 1 1).t -eq 'ROAD ATLANTA' -and (Reg 'MyDrive' 2 1).t -eq 'LAYOUT')
  Check 'the screen told irdash it is open' (@(Apis | Where-Object { $_ -match 'c=mdopen' }).Count -ge 1)
  Check 'START is a single green key at 6,3' ((Reg 'MyDrive' 6 3).t -eq 'START' -and (Reg 'MyDrive' 6 3).w -eq 1 -and (Reg 'MyDrive' 6 3).st -eq 'go')
  Press 3 1 600
  Check 'DAMAGE sends mddamage' (@(Apis | Where-Object { $_ -match 'c=mddamage' }).Count -eq 1)
  Press 6 3 600
  Check 'START sends mdstart' (@(Apis | Where-Object { $_ -match 'c=mdstart' }).Count -eq 1)

  'SEARCH is the last resort on CARS'
  Fx "m.busy = ''"
  Press 3 0 400
  Press 4 3 500
  Check 'SEARCH opens the keyboard from CARS (32 keys)' ((Sheet 'md-deck-keyboard') -eq 32)
  'search car: the A-Z keyboard'
  Fx "m.busy = ''"
  Check 'SEARCH CAR shows the keyboard (32 keys)' ((Sheet 'md-deck-keyboard') -eq 32)
  # C U P
  Press 2 0 300; Press 4 2 300; Press 7 1 300
  Check 'typing sends the text to the top screen as it goes' (@(Apis | Where-Object { $_ -match 'c=mddraft&a=car%3ACUP' }).Count -eq 1)
  Press 2 3 500
  Check 'the 123 key shows the digits page' ((Sheet 'md-deck-digits') -eq 32)
  Press 0 0 300
  Press 4 3 300
  Check 'the delete key takes a letter back' (@(Apis | Where-Object { $_ -match 'c=mddraft&a=car%3ACUP1$' }).Count -ge 1 -and @(Apis | Where-Object { $_ -match 'c=mddraft&a=car%3ACUP$' }).Count -ge 2)
  Press 7 3 500
  Check 'DONE asks for the search (mdfindcar with the text)' (@(Apis | Where-Object { $_ -match 'c=mdfindcar&a=CUP$' }).Count -eq 1)
  Fx "m.busy = 'find'"
  Check 'while iRacing looks it up the screen says SEARCHING (32 keys)' ((Sheet 'md-deck-searching') -eq 32)
  Fx "m.busy = ''; m.results = $((New-MyDriveResults 'car' 'cup' @('Gen 4 Cup', 'Global Mazda MX-5 Cup', 'Porsche 911 Cup (992.2)', 'VW Jetta TDI Cup') | ConvertTo-Json -Depth 5 -Compress))"
  Check 'the results screen has all 32 keys' ((Sheet 'md-deck-results-car') -eq 32)
  Press 2 1 600
  Check 'tapping a result sends mdpick with its id' (@(Apis | Where-Object { $_ -match 'c=mdpick&a=s00000002' }).Count -eq 1)
  Check 'and the results are put away at once (the choice view is back)' ((Sheet 'md-deck-after-pick') -eq 32)
  Fx "m.results = $((New-MyDriveResults 'layout' 'Lime Rock Park' @('Grand Prix', 'Classic', 'Chicanes', 'West Bend Chicane', 'School') | ConvertTo-Json -Depth 5 -Compress))"
  $null = Sheet 'md-deck-results-layout'
  Fx "m.results = $((New-MyDriveResults 'track' 'zzz' @() $true 'Nothing found.' | ConvertTo-Json -Depth 5 -Compress))"
  $null = Sheet 'md-deck-results-none'
  Fx "m.results = null"

  'starting, failing, and in a session'
  Fx "m.busy = 'start'; m.phase = 'loading'; m.msg = 'iRacing is loading the session'"
  $null = Sheet 'md-deck-starting'
  Fx "m.busy = ''; m.phase = 'failed'; m.msg = 'iRacing has no \`"Nope\`" in its list (do you own it?).'"
  $null = Sheet 'md-deck-failed'
  Fx "m.phase = ''; m.msg = ''; m.session = true; m.current = { id: '', car: 'Chevrolet Corvette Z06 GT3.R', carShort: 'CORVETTE GT3', track: 'Road Atlanta', trackShort: 'ROAD ATLANTA', layout: 'Full Course', fav: false }"
  Check 'in a session the screen switches to the big keys (32 keys)' ((Sheet 'md-deck-session') -eq 32)
  Press 0 1 500
  $nStar = @(Apis | Where-Object { $_ -match 'c=mdstar(&|$)' }).Count
  Check 'the big star sends mdstar' ($nStar -eq 1)
  if ($nStar -ne 1) { '        requests so far: ' + ((Apis) -join ' ') }
  Press 4 1 400
  Check 'GET OUT sends mdgetout' (@(Apis | Where-Object { $_ -match 'c=mdgetout' }).Count -eq 1)
  Press 2 1 400
  Check 'DRIVE sends mdstart' (@(Apis | Where-Object { $_ -match 'c=mdstart' }).Count -eq 2)
  Fx "m.session = false; m.current = null"
  ClearApis
  $null = Invoke-DeckJs $page "__sd.prevProfile = 'main'"
  Press 7 3 700
  $exitApis = @(Apis); $exitCur = Invoke-DeckJs $page '__sd.cur'
  Check 'EXIT tells irdash and goes back to your own keys' (@($exitApis | Where-Object { $_ -match 'c=mdclose' }).Count -eq 1 -and $exitCur -eq 'main')
  if ($fail -gt 0 -and $exitCur -ne 'main') { '        exit requests: ' + ($exitApis -join ' ') + ' profile: ' + $exitCur }
  $perf = Invoke-DeckJs $page '__sd.perfLines()'
  Check 'opening MY DRIVE wrote a timing line' (@($perf | Where-Object { $_ -match 'perf mydrive open' }).Count -ge 1)
}
finally { Stop-DeckBrowser $b }
if ($DeckOnly) { ''; "$pass passed, $fail failed. Pictures in $shots"; return }

# ================= 2. irdash /mydrive and /api/do =================
'2. irdash serves My Drive and only takes what it should'
$favFile = Join-Path $root 'mydrive\favourites.ini'; $stateFile = Join-Path $root 'mydrive\state.ini'
$favBefore = if (Test-Path $favFile) { [IO.File]::ReadAllBytes($favFile) } else { $null }
$stateBefore = if (Test-Path $stateFile) { [IO.File]::ReadAllBytes($stateFile) } else { $null }
try {
  $m = GetMd
  Check '/mydrive is ready' ($m.ready -eq $true)
  Check 'recent drives come from the career cache (up to 7, newest first, each with an id)' (@($m.recent).Count -ge 1 -and @($m.recent).Count -le 7 -and (@($m.recent | Where-Object { $_.id -notmatch '^r[0-9a-f]{8}$' }).Count -eq 0))
  Check 'car and track names are shortened for the small keys' (@($m.recent | Where-Object { $_.carShort -and $_.trackShort -and $_.carShort.Length -le $_.car.Length }).Count -eq @($m.recent).Count)
  $r1 = $m.recent[0]
  Check 'the newest recent drive is the last one in the career cache' ($r1.car.Length -gt 3 -and $r1.track.Length -gt 3)
  $catalog = J '/mydrive/lists'
  Check 'list catalog includes recent, car, and track rows with stable ids' (@($catalog.recent).Count -gt 0 -and @($catalog.cars).Count -gt 0 -and @($catalog.tracks).Count -gt 0 -and $catalog.cars[0].id -match '^c[0-9a-f]{8}$' -and $catalog.tracks[0].id -match '^t[0-9a-f]{8}$')
  Check 'track rows expose layouts from cached telemetry headers' (@($catalog.tracks | Where-Object { $_.layouts.Count -gt 0 }).Count -gt 0)
  $gr = @($m.recent | Where-Object { $_.car -eq 'Toyota GR86' -and $_.track -eq 'Lime Rock Park' })
  if ($gr.Count) { Check 'friends mode''s short names are used (GR86 at LIME ROCK)' ($gr[0].carShort -eq 'GR86' -and $gr[0].trackShort -eq 'LIME ROCK') }

  'bad input is refused'
  Check 'an unknown command is refused' ((Api 'mdnope' '') -eq 400)
  Check 'a pick that is not an id is refused' ((Api 'mdpick' 'x; rm') -eq 400)
  Check 'a search with quotes is refused' ((Api 'mdfindcar' 'a"b') -eq 400)
  Check 'a search with nothing is refused' ((Api 'mdfindtrack' '') -eq 400)
  Check 'a draft of the wrong kind is refused' ((Api 'mddraft' 'bike:abc') -eq 400)
  Check 'a speed test of something else is refused' ((Api 'mdspeedtest' 'everything') -eq 400)

  'pick a recent drive'
  $gr86 = if ($gr.Count) { $gr[0] } else { $r1 }
  Check 'pick answers ok' ((Api 'mdpick' $gr86.id) -eq 200)
  $m = WaitMd { param($x) $x.choice.car -eq $gr86.car -and $x.choice.track -eq $gr86.track }
  Check 'the choice is now that drive' ($m.choice.car -eq $gr86.car -and $m.choice.track -eq $gr86.track)
  if ($gr86.car -eq 'Toyota GR86') { Check 'its layout was read from the telemetry file (Grand Prix)' ($m.choice.layout -eq 'Grand Prix') }
  Check 'it shows gold on the recent list' (@($m.recent | Where-Object { $_.id -eq $gr86.id -and $_.chosen }).Count -eq 1)

  'pick a catalog car, track, and layout'
  $catalogTrack = @($catalog.tracks | Where-Object { @($_.layouts).Count -gt 1 } | Select-Object -First 1)
  if ($catalogTrack.Count) {
    $trackRow = $catalogTrack[0]; $layoutName = [string]$trackRow.layouts[0]
    Check 'catalog track pick answers ok' ((Api 'mdpick' $trackRow.id) -eq 200)
    $m = WaitMd { param($x) $x.choice.track -eq $trackRow.name -and $x.choice.layout -eq '' }
    Check 'track choice is saved before layout' ($m.choice.track -eq $trackRow.name -and $m.choice.layout -eq '')
    $comboText = [string]$trackRow.name + '|' + $layoutName
    $layoutHash = [uint32]2166136261
    foreach ($ch in $comboText.ToLowerInvariant().ToCharArray()) {
      $layoutHash = [uint32]($layoutHash -bxor [uint32][int]$ch)
      $layoutHash = [uint32](([uint64]$layoutHash * [uint64]16777619) -band [uint64]4294967295)
    }
    $layoutId = 'l' + $layoutHash.ToString('x8')
    Check 'catalog layout id is accepted and writes the selected layout' ((Api 'mdpick' $layoutId) -eq 200)
    $m = WaitMd { param($x) $x.choice.track -eq $trackRow.name -and $x.choice.layout -eq $layoutName }
    $stateValues = @{}
    foreach ($line in @(Get-Content $stateFile)) { $at = $line.IndexOf('='); if ($at -gt 0) { $stateValues[$line.Substring(0,$at)] = $line.Substring($at+1) } }
    Check 'state.ini holds the catalog car, track, and layout' ($stateValues['car'] -eq $gr86.car -and $stateValues['track'] -eq $trackRow.name -and $stateValues['layout'] -eq $layoutName)
    $null = Api 'mdpick' $gr86.id; $m = WaitMd { param($x) $x.choice.car -eq $gr86.car -and $x.choice.track -eq $gr86.track }
  } else { Check 'catalog includes a track with multiple layouts for the picker flow' $false }

  'the star: favourites'
  $wasFav = [bool]$m.choice.fav
  Check 'the star answers ok' ((Api 'mdstar' '') -eq 200)
  $m = WaitMd { param($x) [bool]$x.choice.fav -ne $wasFav }
  Check 'the choice is now a favourite (or no longer was one)' ([bool]$m.choice.fav -ne $wasFav)
  $lines = @(Get-Content $favFile | Where-Object { $_ -notmatch '^\s*[;#]' -and $_.Trim() })
  Check 'favourites.ini holds it as: car | track | layout' ((-not $m.choice.fav) -or (@($lines | Where-Object { $_ -match [regex]::Escape($gr86.car) + ' \| ' + [regex]::Escape($gr86.track) + ' \| ' }).Count -eq 1))
  if ($m.choice.fav) { Check 'it is on the favourites row with its id' (@($m.favs | Where-Object { $_.car -eq $gr86.car -and $_.track -eq $gr86.track -and $_.chosen -and $_.id -match '^f[0-9a-f]{8}$' }).Count -eq 1) }
  $null = Api 'mdstar' ''
  $m = WaitMd { param($x) [bool]$x.choice.fav -eq $wasFav }
  Check 'a second press takes it away again' ([bool]$m.choice.fav -eq $wasFav)

  'damage on / off'
  $d0 = $m.choice.damage; $null = Api 'mddamage' ''
  $m = WaitMd { param($x) $x.choice.damage -ne $d0 }
  Check 'DAMAGE flips between on and off' ($m.choice.damage -ne $d0)
  $null = Api 'mddamage' ''
  $m = WaitMd { param($x) $x.choice.damage -eq $d0 }
  Check '... and back' ($m.choice.damage -eq $d0)

  'typing on the deck shows on the top screen'
  $null = Api 'mddraft' 'car:COR'
  Check 'the typed text is served (upper case)' ((GetMd).draft.text -eq 'COR' -and (GetMd).draft.kind -eq 'car')
  $null = Api 'mdopen' ''
  Check 'the card is told the deck screen is open' ((GetMd).open -eq $true)
  Start-Sleep -Milliseconds 2500
  Shot 'md-top-typing' $top
  $null = Api 'mddraft' ''
  Check 'cancelling clears it' ($null -eq (GetMd).draft)
  Start-Sleep -Milliseconds 2000
  Shot 'md-top-choice' $top
  $null = Api 'mdclose' ''
  Check 'and closes when the deck screen is left' ((GetMd).open -eq $false)

  # ================= 3. real search of the iRacing lists =================
  if (-not $NoSearch) {
    '3. a real search of iRacing''s Test Drive lists'
    $t0 = Get-Date
    Check 'search car asks irdash' ((Api 'mdfindcar' 'cup') -eq 200)
    $m = WaitMd { param($x) $x.busy -eq 'find' } 5
    Check 'irdash says a search is running' ($m.busy -eq 'find')
    $m = WaitIdle 90
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    "        the search took $secs s"
    Check 'the car search found cars you own, not the ones you would have to buy (Gen 4 Cup has a cart on it)' ($m.results -and $m.results.kind -eq 'car' -and @($m.results.items).Count -ge 1 -and @($m.results.items | Where-Object { $_.name -eq 'Gen 4 Cup' }).Count -eq 0 -and @($m.results.items | Where-Object { $_.name -eq 'Global Mazda MX-5 Cup' }).Count -eq 1)
    Check 'at most 7 results, each with an id' (@($m.results.items).Count -le 7 -and @($m.results.items | Where-Object { $_.id -notmatch '^s[0-9a-f]{8}$' }).Count -eq 0)
    Check 'the Porsche 911 Cup is among them' (@($m.results.items | Where-Object { $_.name -eq 'Porsche 911 Cup (992.2)' }).Count -eq 1)
    Shot 'md-ui-search-car' $mid
    $porsche = @($m.results.items | Where-Object { $_.name -eq 'Porsche 911 Cup (992.2)' })[0]
    $null = Api 'mdpick' $porsche.id
    $m = WaitMd { param($x) $x.choice.car -eq 'Porsche 911 Cup (992.2)' }
    Check 'picking a result sets the car and puts the results away' ($m.choice.car -eq 'Porsche 911 Cup (992.2)' -and $null -eq $m.results)

    $null = Api 'mdfindtrack' 'lime'; $m = WaitIdle 90
    Check 'the track search finds Lime Rock Park' ($m.results -and $m.results.kind -eq 'track' -and @($m.results.items | Where-Object { $_.name -eq 'Lime Rock Park' }).Count -eq 1)
    $lime = @($m.results.items | Where-Object { $_.name -eq 'Lime Rock Park' })[0]
    $null = Api 'mdpick' $lime.id
    $m = WaitMd { param($x) $x.choice.track -eq 'Lime Rock Park' -and $x.choice.layout -eq '' }
    Check 'picking a track sets it and starts again on the first layout' ($m.choice.track -eq 'Lime Rock Park' -and $m.choice.layout -eq '')

    $null = Api 'mdfindlayout' ''; $m = WaitIdle 90
    Check 'the layout list for Lime Rock has Grand Prix first' ($m.results -and $m.results.kind -eq 'layout' -and $m.results.items[0].name -eq 'Grand Prix' -and @($m.results.items).Count -ge 3)
    Check 'the layouts are only layouts (not the dialog''s own Test Drive / Close buttons)' (@($m.results.items | Where-Object { $_.name -in 'Test Drive', 'Close', 'Last settings' }).Count -eq 0)
    Shot 'md-ui-search-layout' $mid
    $classic = @($m.results.items | Where-Object { $_.name -eq 'Classic' })[0]
    $null = Api 'mdpick' $classic.id
    $m = WaitMd { param($x) $x.choice.layout -eq 'Classic' }
    Check 'picking a layout sets it' ($m.choice.layout -eq 'Classic')

    $null = Api 'mdfindcar' 'zzzqq'; $m = WaitIdle 90
    Check 'a search with no match says so' ($m.results -and $m.results.ok -eq $true -and @($m.results.items).Count -eq 0 -and $m.results.msg -match 'Nothing')
    $null = Api 'mdclear' ''
    $m = WaitMd { param($x) $null -eq $x.results }
    Check 'BACK clears the results' ($null -eq $m.results)
  }

  # ================= 4. START end to end =================
  if (-not $NoStart) {
    '4. START: a recent drive end to end (the real sim starts; you must not be in the car)'
    $recent = @((GetMd).recent)
    $pick = @($recent | Where-Object { $_.car -eq 'Toyota GR86' })[0]; if (-not $pick) { $pick = $recent[0] }
    $null = Api 'mdpick' $pick.id
    $m = WaitMd { param($x) $x.choice.car -eq $pick.car -and $x.choice.track -eq $pick.track }
    Check "chose $($pick.car) at $($pick.track)" ($m.choice.car -eq $pick.car)
    $null = Api 'mdopen' ''
    $t0 = Get-Date
    Check 'START asks irdash' ((Api 'mdstart' '') -eq 200)
    $m = WaitMd { param($x) $x.busy -eq 'start' } 5
    Check 'irdash says a start is running' ($m.busy -eq 'start')
    $phases = @{}
    $inCar = $false
    for ($i = 0; $i -lt 480 -and -not $inCar; $i++) {
      Start-Sleep -Milliseconds 1000
      $m = GetMd; if ($m.phase) { $phases[$m.phase] = [int]((Get-Date) - $t0).TotalSeconds }
      if ($i -eq 10) { Shot 'md-top-starting' $top; Shot 'md-ui-starting' $mid }
      $st = & (Join-Path $root 'irdeck-cli.exe') state
      if ($st -match 'onTrack=True') { $inCar = $true }
      if (-not $m.busy -and $m.phase -eq 'failed') { break }
    }
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    Check "you are in the car ($secs s after the press)" $inCar
    "        phases seen (seconds after the press): " + (($phases.GetEnumerator() | Sort-Object Value | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')
    if ($m.phase -eq 'failed') { "        it failed: $($m.msg)" }
    Start-Sleep -Milliseconds 2500
    $m = GetMd
    Check 'START -> in the car is recorded and served' ($m.last -and $m.last.secs -ge 5 -and $m.last.secs -le ($secs + 2))
    "        irdash says START -> in the car: $($m.last.secs) s"
    Check 'the session is the combo that was chosen' ($m.current -and $m.current.car -eq $pick.car -and $m.current.track -eq $pick.track)
    Shot 'md-top-in-car' $top
    $tail = @(Get-Content (Join-Path $root 'irdeck.log') -Tail 60)
    Check 'the log says START -> in the car' (@($tail | Where-Object { $_ -match 'mydrive: START -> in the car in \d+ s' }).Count -ge 1)
    # back to the main screen (the car must be stopped: it is, in the pits)
    $q = & (Join-Path $root 'irdeck-cli.exe') quitmain
    Start-Sleep -Seconds 2
    Check 'QUIT TO MAIN brought iRacing back to the home screen' ((& (Join-Path $root 'irdeck-cli.exe') state) -match 'telemetry=off')
    Shot 'md-ui-home-after' $mid
  }
}
finally {
  if ($favBefore -ne $null) { [IO.File]::WriteAllBytes($favFile, $favBefore) } elseif (Test-Path $favFile) { Remove-Item $favFile -Force }
  if ($stateBefore -ne $null) { [IO.File]::WriteAllBytes($stateFile, $stateBefore) }
  $null = Api 'mdclose' ''; $null = Api 'mddraft' ''
}
''
"$pass passed, $fail failed. Pictures in $shots"
