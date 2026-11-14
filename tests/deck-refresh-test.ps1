# deck-refresh-test.ps1 (W3-4 review): tools\deck-refresh.ps1 makes the key pictures BEFORE it stops Stream Deck, and a render that fails
# stops it with Stream Deck untouched. OFFLINE: a pretend build-deck.ps1 whose -Preview fails; only that path is run (it never reaches the
# part that closes Stream Deck). The rest is read from the script.
#   powershell -ExecutionPolicy Bypass -File tests\deck-refresh-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; ''; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
'deck-refresh test (W3-4 review)'

Section '1. a render that fails stops before Stream Deck is touched'
$tmp = Join-Path $env:TEMP ('deck-refresh-test-' + $PID); New-Item -ItemType Directory -Force $tmp | Out-Null
$fake = Join-Path $tmp 'build-deck.ps1'; $calls = Join-Path $tmp 'calls.txt'
[IO.File]::WriteAllText($fake, "param([switch]`$Preview, [switch]`$NoRender)`r`nAdd-Content -LiteralPath '$calls' -Value ('called ' + `$(if (`$Preview) { 'Preview' } elseif (`$NoRender) { 'NoRender' } else { 'build' }))`r`n'the key pictures were not made (tools\deck-render.ps1): Chrome not found'`r`nexit 1`r`n")
$before = @(Get-Process StreamDeck -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\deck-refresh.ps1') -BuildDeck $fake 2>&1 | ForEach-Object { "$_" }
$rc = $LASTEXITCODE
$after = @(Get-Process StreamDeck -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$c = @(Get-Content $calls -ErrorAction SilentlyContinue)
Check "deck-refresh exits 1 and says the pictures could not be made ($($o -join ' '))" ($rc -eq 1 -and ($o -join ' ') -match 'pictures could not be made - Stream Deck was not touched')
Check "the pretend build-deck was asked for -Preview only, never to build ($($c -join ', '))" ($c.Count -eq 1 -and $c[0] -eq 'called Preview')
Check "Stream Deck is exactly as it was (processes before: $($before -join ','); after: $($after -join ','))" ((($before | Sort-Object) -join ',') -eq (($after | Sort-Object) -join ','))
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Section '2. the rest of the script'
$s = [IO.File]::ReadAllText((Join-Path $root 'tools\deck-refresh.ps1'))
$iPreview = $s.IndexOf('-File $BuildDeck -Preview'); $iKill = $s.IndexOf('Stop-Process')
Check 'the pictures are made (-Preview) before Stream Deck is stopped' ($iPreview -gt 0 -and $iKill -gt $iPreview)
Check 'each try builds with -NoRender (no Chrome while Stream Deck is closed)' ($s -match '-File \$BuildDeck -NoRender')
Check 'a try with no "built:" line fails (the old pages are back) instead of saying the deck is whole' ($s -match "'\^built: '" -and $s -match 'if \(-not \$built\) \{[^}]*exit 1 \}')
Check 'the profile must list exactly the page ids the build printed ("pages:")' ($s -match "'\^pages: '" -and $s -match '\$sameIds -and \$dirs\.Count -eq \$want\.Count')
Check 'build-deck''s NOT DONE line (keys left off: the installed add-on lacks their action) makes deck-refresh fail' ($s -match "'\^NOT DONE'" -and $s -match 'if \(\$notDone\) \{ "deck rebuilt, but \$notDone"; exit 1 \}')
$bd = [IO.File]::ReadAllText((Join-Path $root 'build-deck.ps1'))
Check 'build-deck.ps1 prints the page ids it wrote, before "built:"' ($bd -match '"pages: " \+' -and $bd.IndexOf('"pages: "') -lt $bd.IndexOf('"built: "'))
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
