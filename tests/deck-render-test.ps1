# deck-render-test.ps1 (W3-4): ONE renderer for every key picture. OFFLINE: headless Chrome only; writes deck\keys\, deck\preview-*.png
# (both made again by every build) and pictures in tests\shots\rework.
#   1. tools\deck-render.ps1 makes one 144 px PNG per key of deck\layout.json (MAIN, MORE, LEAVE) and the three preview sheets
#   2. the colour says the job: a gold key is gold, a grey key grey, a red key red, a green key green, a plain key black (pixels sampled)
#   3. every label is 20 px or more on the 96 px key and fits the key (measured by render.html as it draws)
#   4. the add-on draws with the same function: its EXIT key on the RACES screen is byte-equal to render.html's EXIT, and an opener key
#      (FRIENDS) the add-on paints is byte-equal to the picture build-deck.ps1 packs for that key
#   powershell -ExecutionPolicy Bypass -File tests\deck-render-test.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'deck-harness.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
function Section($s) { Assert-RigFree -Where $s; ''; $s }
Add-Type -AssemblyName System.Drawing
'deck render test (W3-4)'
$deck = Join-Path $root 'deck'
$L = [IO.File]::ReadAllText((Join-Path $deck 'layout.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json

Section '1. tools\deck-render.ps1'
$t0 = Get-Date
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\deck-render.ps1') 2>&1 | ForEach-Object { "$_" }
Check 'deck-render.ps1 ran and said what it made' ($LASTEXITCODE -eq 0 -and ($o -join ' ') -match 'rendered (\d+) keys') ($o -join ' ')
$want = 0; $bad = @()
foreach ($p in $L.pageOrder) {
  foreach ($k in $L.pages.$p) {
    $want++
    $f = Join-Path $deck "keys\$p\$($k.c),$($k.r).png"
    if (-not (Test-Path -LiteralPath $f)) { $bad += "$p $($k.c),$($k.r) missing"; continue }
    if ((Get-Item -LiteralPath $f).LastWriteTime -lt $t0.AddSeconds(-2)) { $bad += "$p $($k.c),$($k.r) old" }
    $im = [Drawing.Image]::FromFile($f); if ($im.Width -ne 144 -or $im.Height -ne 144) { $bad += "$p $($k.c),$($k.r) is $($im.Width)x$($im.Height)" }; $im.Dispose()
  }
}
$made = @(Get-ChildItem (Join-Path $deck 'keys') -Recurse -Filter '*,*.png').Count
Check "one fresh 144 x 144 picture per key: MAIN $(@($L.pages.MAIN).Count) + MORE $(@($L.pages.MORE).Count) + LEAVE $(@($L.pages.LEAVE).Count) = $want, made $made" ($bad.Count -eq 0 -and $made -eq $want) ($bad -join '; ')
foreach ($p in $L.pageOrder) {
  $f = Join-Path $deck "preview-$p.png"
  $okp = (Test-Path $f) -and (Get-Item $f).LastWriteTime -ge $t0.AddSeconds(-2)
  if ($okp) { $im = [Drawing.Image]::FromFile($f); $okp = $im.Width -eq 1210 -and $im.Height -eq 610; $im.Dispose(); Copy-Item $f (Join-Path $shots "deck-$($p.ToLower()).png") -Force }
  Check "the $p contact sheet deck\preview-$p.png (8 x 4 keys) is there" $okp
}

Section '2. colour by job (pixels)'
function Px($page, $pos, $x = 6, $y = 6) { $bm = New-Object Drawing.Bitmap (Join-Path $deck "keys\$page\$pos.png"); $c = $bm.GetPixel($x, $y); $bm.Dispose(); $c }
function Near($c, $hex) { $w = [Drawing.ColorTranslator]::FromHtml($hex); [Math]::Abs($c.R - $w.R) -le 3 -and [Math]::Abs($c.G - $w.G) -le 3 -and [Math]::Abs($c.B - $w.B) -le 3 }
$art = [IO.File]::ReadAllText((Join-Path $deck 'keyart.js'))
function Tok($n) { [regex]::Match($art, "\b$n\s*:\s*'(#[0-9a-f]{6})'").Groups[1].Value }
$cases = @(@('gold', 'MAIN', '1,0', 'DRIVE', 'gold'), @('green', 'MAIN', '2,0', 'AI RACE', 'green'), @('red', 'MAIN', '0,1', 'GET OUT', 'red'), @('grey', 'MAIN', '5,0', 'KIDS', 'grey'), @('black', 'MAIN', '0,0', 'HOME', 'key'))
foreach ($cs in $cases) {
  $c = Px $cs[1] $cs[2]; $hex = Tok $cs[4]
  Check "$($cs[3]) ($($cs[1]) $($cs[2])) is $($cs[0]) ($hex): rgb $($c.R),$($c.G),$($c.B)" ($hex -and (Near $c $hex))
}
$roleOf = @{}; foreach ($p in $L.pageOrder) { foreach ($k in $L.pages.$p) { $roleOf["$p $($k.c),$($k.r)"] = $k.role } }
$wrong = @(); foreach ($kv in $roleOf.GetEnumerator()) { $pp = $kv.Key.Split(' '); $c = Px $pp[0] $pp[1]; $hex = Tok $(if ($kv.Value -eq 'white') { 'key' } else { $kv.Value }); if (-not (Near $c $hex)) { $wrong += $kv.Key } }
Check "every key's fill is its role colour from keyart.js ($($roleOf.Count) keys)" ($wrong.Count -eq 0) ($wrong -join ', ')
Check 'only one gold key on MAIN (the one thing he most likely wants now: DRIVE)' (@($L.pages.MAIN | Where-Object { $_.role -eq 'gold' }).Count -eq 1)

Section '3. labels: 20 px or more on the key, and they fit'
$m = [IO.File]::ReadAllText((Join-Path $deck 'keys\measure.json')) | ConvertFrom-Json
$small = @(); $nofit = @(); $noglyph = @(); $n = 0
foreach ($p in $m.measure.PSObject.Properties) { foreach ($k in $p.Value.PSObject.Properties) {
  $n++
  foreach ($px in @($k.Value.labelPx)) { if ([double]$px -lt 20) { $small += "$($p.Name) $($k.Name) $px px" } }
  if (-not $k.Value.fits) { $nofit += "$($p.Name) $($k.Name)" }
  if (-not $k.Value.glyph) { $noglyph += "$($p.Name) $($k.Name)" }
} }
Check "every label line is 20 px or more on the 96 px key ($n keys measured)" ($n -eq $want -and $small.Count -eq 0) ($small -join '; ')
Check 'every label fits inside its key at that size' ($nofit.Count -eq 0) ($nofit -join '; ')
Check 'every key has its glyph (a name from the glyph set in keyart.js)' ($noglyph.Count -eq 0) ($noglyph -join '; ')

Section '4. the add-on draws with the same function'
$fx = @{ '/guest' = @{}; '/overlays' = @{}; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false }; '/api/library' = @{ races = @(); storage = @{ freeGb = 280 } } }
$html = Join-Path $env:TEMP 'deck-render-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html).Replace("TILE.RigConfirm = 'confirm';", "TILE.RigConfirm = 'confirm'; OPEN.push(['k-races', 'com.peter.rigintro.races', 5, 3]); TILE.RigRaces = 'races';").Replace("return realFetch(url, opt);", "return Promise.resolve(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));")
[IO.File]::WriteAllText($html, $h, (New-Object Text.UTF8Encoding($false)))
$b = Start-DeckBrowser 9372
try {
  $page = New-DeckPage $b $url
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 2
  $friends = Invoke-DeckJs $page "__sd.images['k-friends'] || ''"
  $pack = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $deck 'keys\MAIN\4,0.png')))
  Check 'the FRIENDS key the add-on paints is byte-equal to the picture build-deck.ps1 packs for MAIN 4,0' ($friends -and $friends.Substring($friends.IndexOf(',') + 1) -eq $pack)
  $null = Invoke-DeckJs $page "(async () => { __sd.pressOpener('races'); await __sd.sleep(1800); return 1; })()"
  $exitUrl = Invoke-DeckJs $page "__sd.images[__sd.tileCtx(7, 3)] || ''"
  if ($exitUrl) { Save-DataUrlPng $exitUrl (Join-Path $shots 'deck-races-exit.png') }
  $ref = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $deck 'keys\exit-96.png')))
  Check 'the RACES screen is open and its EXIT key (7,3) has a picture' ((Invoke-DeckJs $page '__sd.cur') -eq 'RigRaces' -and $exitUrl)
  Check 'that EXIT key is byte-equal to the EXIT render.html draws from the same spec (one drawing function)' ($exitUrl -and $exitUrl.Substring($exitUrl.IndexOf(',') + 1) -eq $ref)
  Check 'plugin.html names no colour of its own (every colour comes from keyart.js)' (-not ([IO.File]::ReadAllText((Join-Path $root 'deck-intro\plugin.html')) -match "#[0-9a-fA-F]{6}\b|'#[0-9a-fA-F]{3}'"))
  Check 'and has no copied colour tables left (FCOLORS ... SNDCOLORS)' (-not ([IO.File]::ReadAllText((Join-Path $root 'deck-intro\plugin.html')) -match '[A-Z]+COLORS'))
}
finally { Stop-DeckBrowser $b }
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
