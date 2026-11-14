# deck-layout-test.ps1 (W3-4): the contract test on deck\layout.json, the ONE deck layout read by build-deck.ps1, the renderer and the add-on.
# OFFLINE: reads files and runs build-deck.ps1 -Preview (it writes deck\keys\, deck\preview-*.png and %TEMP%\PaddockPreview-* only).
#   1. the file: pages LEAVE / MAIN / MORE, one key per cell inside 8 x 4, labels at most 2 lines of 8 characters, a known glyph and role
#   2. every key has a known action: a key exe in keys.map with an irdeck verb, an add-on screen in SCREENS (and in install.ps1), a page, the
#      CONFIRM key; no two keys on a page do the same (QUIT TO MENU is one key over two cells, one exe)
#   3. no PC-ending key without the CONFIRM screen; EXIT at 7,3 on every add-on screen
#   4. MAIN is PLAN 4.6's map; every door is there (HOME, RACES, REVIEW, RIG); TO THE RACE replaces NEXT SESSION and RACE NOW; nothing
#      from the "gone" list is left
#   5. build-deck.ps1 -Preview reads this file, and the page keys land where they say
#   powershell -ExecutionPolicy Bypass -File tests\deck-layout-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; ''; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
function ReadText($rel) { [IO.File]::ReadAllText((Join-Path $root $rel), [Text.Encoding]::UTF8) }
'deck layout contract test (W3-4)'
$L = $null; try { $L = (ReadText 'deck\layout.json') | ConvertFrom-Json } catch { }
$plug = ReadText 'deck-intro\plugin.html'; $inst = ReadText 'deck-intro\install.ps1'; $art = ReadText 'deck\keyart.js'; $ir = ReadText 'src\irdeck.cs'

Section '1. the file'
Check 'deck\layout.json is JSON with pages LEAVE, MAIN, MORE in that order, opening on MAIN' ($L -and (($L.pageOrder) -join ',') -eq 'LEAVE,MAIN,MORE' -and $L.current -eq 'MAIN' -and $L.pages.MAIN -and $L.pages.MORE -and $L.pages.LEAVE)
$keys = @(); foreach ($p in $L.pageOrder) { foreach ($k in $L.pages.$p) { $keys += [pscustomobject]@{ page = $p; c = [int]$k.c; r = [int]$k.r; label = @($k.label); glyph = $k.glyph; role = $k.role; a = $k.action; name = (@($k.label) -join ' ') } } }
Check "every key sits inside the 8 x 4 grid, one key per cell ($($keys.Count) keys)" (@($keys | Where-Object { $_.c -lt 0 -or $_.c -gt 7 -or $_.r -lt 0 -or $_.r -gt 3 }).Count -eq 0 -and @($keys | Group-Object { "$($_.page) $($_.c),$($_.r)" } | Where-Object { $_.Count -gt 1 }).Count -eq 0)
$bad = @($keys | Where-Object { $_.label.Count -lt 1 -or $_.label.Count -gt 2 -or @($_.label | Where-Object { ([string]$_).Length -gt 8 -or ([string]$_).Length -lt 1 }).Count -gt 0 })
Check 'every label is 1 or 2 lines of at most 8 characters' ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.page) $($_.c),$($_.r) '$($_.name)'" }) -join '; ')
$gm = [regex]::Match($art, '(?s)var GLYPHS = \{(.*?)\n  \};'); $glyphs = @([regex]::Matches($gm.Groups[1].Value, '(?m)^\s{4}(\w+): function') | ForEach-Object { $_.Groups[1].Value })
$bad = @($keys | Where-Object { $glyphs -notcontains $_.glyph })
Check "every glyph is one of the $($glyphs.Count) in keyart.js" ($glyphs.Count -ge 20 -and $bad.Count -eq 0) (($bad | ForEach-Object { "$($_.name)=$($_.glyph)" }) -join '; ')
$bad = @($keys | Where-Object { @('gold', 'green', 'red', 'grey', 'white') -notcontains $_.role })
Check 'every role is gold, green, red, grey or white' ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.name)=$($_.role)" }) -join '; ')
$kinds = @($keys | ForEach-Object { $a = $_.a; $n = @(@('exe', 'screen', 'plugin', 'page') | Where-Object { $a.PSObject.Properties.Name -contains $_ }).Count; if ($n -ne 1) { "$($_.page) $($_.name)" } })
Check 'every key has exactly one kind of action (exe, screen, plugin or page)' ($kinds.Count -eq 0) ($kinds -join '; ')

Section '2. every key has a known action'
$runBody = $ir.Substring($ir.IndexOf('static int Run(string[] a)'), 9000)
$verbs = @([regex]::Matches($runBody, 'case "([^"]+)":') | ForEach-Object { $_.Groups[1].Value })
$exeKeys = @($keys | Where-Object { $_.a.exe })
$bad = @($exeKeys | Where-Object { $verbs -notcontains (([string]$_.a.args).Split(' ')[0]) })
Check "every key exe runs an irdeck verb ($($exeKeys.Count) keys; to-the-race and spotter-tap are verbs)" ($bad.Count -eq 0 -and $verbs -contains 'to-the-race' -and $verbs -contains 'spotter-tap') (($bad | ForEach-Object { "$($_.name)=$($_.a.args)" }) -join '; ')
$sm = [regex]::Match($plug, 'const SCREENS = \{([^}]*)\}'); $screens = @([regex]::Matches($sm.Groups[1].Value, '(\w+):') | ForEach-Object { $_.Groups[1].Value })
$acts = @([regex]::Matches($inst, 'UUID = "\$uuid\.(\w+)"') | ForEach-Object { $_.Groups[1].Value })
$bad = @($keys | Where-Object { $_.a.screen -and ($screens -notcontains $_.a.screen -or $acts -notcontains $_.a.screen -or @($L.screens) -notcontains $_.a.screen -and $_.a.screen -ne 'rig') })
Check "every screen key opens a screen the add-on has (SCREENS: $($screens -join ', ')) and install.ps1 declares" ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.name)=$($_.a.screen)" }) -join '; ')
$bad = @($keys | Where-Object { $_.a.plugin -and ($_.a.plugin -ne 'confirm' -or @('shutdown', 'sleep') -notcontains $_.a.what -or $acts -notcontains 'confirm') })
Check 'the plugin keys are the CONFIRM action with what = shutdown or sleep (the add-on knows both)' ($bad.Count -eq 0 -and $plug -match "shutdown: \{ key:" -and $plug -match "sleep: \{ key:")
Check 'the page keys are next / previous' (@($keys | Where-Object { $_.a.page -and @('next', 'previous') -notcontains $_.a.page }).Count -eq 0)
foreach ($p in $L.pageOrder) {
  $sig = @($keys | Where-Object page -eq $p | ForEach-Object { $a = $_.a; if ($a.exe) { 'exe:' + $a.exe } elseif ($a.screen) { 'screen:' + $a.screen } elseif ($a.plugin) { 'plugin:' + $a.plugin + ':' + $a.what } else { 'page:' + $a.page } })
  $dup = @($sig | Group-Object | Where-Object { $_.Count -gt 1 -and $_.Name -ne 'exe:quit-main' })
  Check "$p : no two keys do the same thing" ($dup.Count -eq 0) (($dup | ForEach-Object { $_.Name }) -join '; ')
}
$q = @($keys | Where-Object { $_.a.exe -eq 'quit-main' })
Check 'QUIT TO MENU is one exe over two side-by-side cells on LEAVE (no second QUIT exe)' ($q.Count -eq 2 -and @($q | Where-Object page -eq 'LEAVE').Count -eq 2 -and [Math]::Abs($q[0].c - $q[1].c) -eq 1 -and $q[0].r -eq $q[1].r -and @($keys | Where-Object { $_.a.args -eq 'quitmain' -and $_.a.exe -ne 'quit-main' }).Count -eq 0)
$names = @{}; $clash = @(); foreach ($k in $exeKeys) { if ($names.ContainsKey($k.a.exe) -and $names[$k.a.exe] -ne $k.a.args) { $clash += $k.a.exe }; $names[$k.a.exe] = $k.a.args }
foreach ($x in @($L.phoneOnly)) { if ($names.ContainsKey($x.exe) -and $names[$x.exe] -ne $x.args) { $clash += $x.exe } }
Check 'one exe name is always the same command (deck keys and the phone-only key exes)' ($clash.Count -eq 0) ($clash -join ', ')
Check 'the phone-only key exes have no key on any deck page' (@($L.phoneOnly | Where-Object { $names.ContainsKey($_.exe) }).Count -eq 0)

Section '3. safety: no PC-ending key without CONFIRM; EXIT at 7,3 on every screen'
$ends = '^(power\s+(off|sleep|restart|shutdown)|shutdown|sleep)\b'
Check 'no key exe turns the PC off, sleeps or restarts it' (@($exeKeys | Where-Object { $_.a.args -match $ends }).Count -eq 0)
$pc = @($keys | Where-Object { $_.a.plugin -eq 'confirm' })
Check 'SHUT DOWN PC and SLEEP PC open the CONFIRM screen, and only on LEAVE' ($pc.Count -eq 2 -and @($pc | Where-Object page -ne 'LEAVE').Count -eq 0 -and @($pc | Where-Object { $_.a.what -eq 'shutdown' }).Count -eq 1 -and @($pc | Where-Object { $_.a.what -eq 'sleep' }).Count -eq 1)
Check 'no PC-ending key on MAIN or MORE at all (LOCK only locks Windows)' (@($keys | Where-Object { $_.page -ne 'LEAVE' -and ($_.name -match 'SHUT|SLEEP' -or $_.a.plugin -eq 'confirm') }).Count -eq 0)
Check 'layout.json says EXIT is at 7,3 and the add-on takes it from there (EXIT_AT, exitRegion)' ((($L.exitAt) -join ',') -eq '7,3' -and $plug -match 'const EXIT_AT = KEYART\.exitAt\(DECK\);' -and $plug -match 'function exitRegion\(\) \{ return \{ c: EXIT_AT\[0\], r: EXIT_AT\[1\]')
# every screen a deck key opens: its class has the one EXIT (exitRegion) and no EXIT / exit / BACK-that-leaves key of its own
$cls = @{ friends = 'Friends'; overlays = 'Overlays'; mydrive = 'MyDrive'; replay = 'Replay'; sound = 'Sound'; ac = 'Ac'; races = 'Races'; confirm = 'Confirm' }
foreach ($s in @($L.screens)) {
  $start = $plug.IndexOf("const $($cls[$s]) = new class extends Screen"); $end = $plug.IndexOf("`n};", $start)
  if ($start -lt 0 -or $end -lt 0) { Check "the $s screen is in plugin.html" $false; continue }
  $body = $plug.Substring($start, $end - $start)
  $own = @([regex]::Matches($body, "add\([^;]*'EXIT'|add\([^;]*, 'exit', |'leave'"))
  Check "$($s.ToUpper()): EXIT at 7,3 (exitRegion), no other key of its own that leaves" ($body -match 'exitRegion\(\)' -and $own.Count -eq 0) (($own | ForEach-Object { $_.Value }) -join '; ')
}
Check 'a screen whose irdash stops answering leaves by the same EXIT_AT key' ($plug -match 'if \(this\.offline\) \{ if \(col === EXIT_AT\[0\] && row === EXIT_AT\[1\]\) this\.exit\(\)')
Check 'the 0.7 s guard for add-on toggles, the 2 s fetch timeout, grey opener keys after 3 failed ticks, one summary poll only while an opener shows' ($plug -match 'now - this\.onceAt\[k\] < 700' -and $plug -match 'const FETCH_MS = 2000;' -and $plug -match 'this\.failed >= 3 && !this\.grey' -and $plug -match 'if \(!playing && openerShowing\(\)')

Section '4. the map (PLAN 4.6)'
$minus = [string][char]0x2212
$plan = [ordered]@{
  '0,0' = 'HOME'; '1,0' = 'DRIVE'; '2,0' = 'AI RACE'; '3,0' = 'OFFICIAL'; '4,0' = 'FRIENDS'; '5,0' = 'KIDS'; '6,0' = 'AC'; '7,0' = 'MORE'
  '0,1' = 'GET OUT'; '1,1' = 'RESET CAR'; '2,1' = 'RESTART'; '3,1' = 'TO THE RACE'; '4,1' = 'PAUSE'; '5,1' = 'SAVE SPOT'; '6,1' = 'BACK TO SPOT'; '7,1' = 'LEAVE'
  '0,2' = 'FUEL TO FINISH'; '1,2' = 'TIRES'; '2,2' = 'FAST REPAIR'; '3,2' = 'CLEAR PIT'; '4,2' = 'BEST LAP CAR'; '5,2' = 'REPLAY'
  '0,3' = "VOL $minus"; '1,3' = 'VOL +'; '2,3' = 'SPOTTER'; '3,3' = 'SOUND'; '4,3' = 'OVERLAYS'; '5,3' = 'RACES'; '6,3' = 'REVIEW'; '7,3' = 'RIG' }
$main = @($keys | Where-Object page -eq 'MAIN'); $bad = @()
foreach ($pos in $plan.Keys) { $c, $r = $pos.Split(',') | ForEach-Object { [int]$_ }; $k = $main | Where-Object { $_.c -eq $c -and $_.r -eq $r }; if (-not $k) { $bad += "$pos missing" } elseif ($k.name -ne $plan[$pos]) { $bad += "$pos is '$($k.name)', the plan says '$($plan[$pos])'" } }
foreach ($k in $main) { if (-not $plan.Contains("$($k.c),$($k.r)")) { $bad += "$($k.c),$($k.r) '$($k.name)' is not in the plan (6,2 and 7,2 are the spares)" } }
Check 'MAIN rows 0-3 are PLAN 4.6 cell by cell (two spares in row 2)' ($bad.Count -eq 0) ($bad -join '; ')
function K($name) { $keys | Where-Object { $_.page -eq 'MAIN' -and $_.name -eq $name } | Select-Object -First 1 }
Check 'the doors: HOME is rig-on, RACES opens the RACES screen, REVIEW is the debrief door, RIG opens the top screen''s RIG page' ((K 'HOME').a.args -eq 'rigon' -and (K 'RACES').a.screen -eq 'races' -and (K 'REVIEW').a.args -eq 'dash debrief' -and (K 'RIG').a.screen -eq 'rig' -and $plug -match "sendCmd\('/api/nav\?to=rig'\)")
Check 'DRIVE is GET IN (smart); AI RACE opens the one AI RACE screen (car / track / level / START)' ((K 'DRIVE').a.args -eq 'smart' -and (K 'AI RACE').a.screen -eq 'mydrive')
Check 'TO THE RACE is there (to-the-race); NEXT SESSION and RACE NOW are gone' ((K 'TO THE RACE').a.args -eq 'to-the-race' -and @($keys | Where-Object { $_.a.args -match '^(skip|racenow)$' -or $_.name -match 'NEXT SESSION|RACE NOW' }).Count -eq 0)
Check 'SPOTTER is one key: a tap mutes / unmutes (spotter-tap); SPOTTER - / + are gone (the level is on SOUND)' ((K 'SPOTTER').a.args -eq 'spotter-tap' -and @($keys | Where-Object { $_.a.args -match '^appvol (spotter|mute)' }).Count -eq 0)
$gone = @($keys | Where-Object { $_.a.args -match '^key --sim f\d+' -or $_.name -match '^(SORRY|GOOD RACE|SEAT|MUTE|SHOWCASE|VAULT|ANALYSIS|WIPE|AI LEVEL|CAR TRACK|GHOST|LAST DRIVE|KIDS MODE|MY DRIVE)' -or $_.a.args -match '^(media mute|showcase|dash vault|pittoggle ws)' -or $_.a.screen -match 'analysis|ailevel' })
Check 'nothing from the gone list: the sim F-keys, SORRY / GOOD RACE, SEAT, MUTE, SHOWCASE, VAULT, ANALYSIS, WIPE, AI LEVEL, CAR TRACK' ($gone.Count -eq 0) (($gone | ForEach-Object { "$($_.page) $($_.name)" }) -join '; ')
$more = @($keys | Where-Object page -eq 'MORE' | ForEach-Object { $_.name }); $leave = @($keys | Where-Object page -eq 'LEAVE' | ForEach-Object { $_.name })
Check "MORE is BACK, THANKS, AC COOLER, AC WARMER, LOCK ($($more -join ', '))" ((($more | Sort-Object) -join ',') -eq 'AC COOLER,AC WARMER,BACK,LOCK,THANKS')
Check "LEAVE is BACK, QUIT TO MENU (two cells), SHUT DOWN PC, SLEEP PC ($($leave -join ', '))" ((($leave | Sort-Object) -join ',') -eq 'BACK,QUIT TO MENU,QUIT TO MENU,SHUT DOWN PC,SLEEP PC')
Check 'install.ps1: the RigAiLevel profile is gone; the rig action is there; the ailevel action stays for one release, hidden, and opens the AI RACE screen (W3-4 review: a deck not rebuilt yet has no dead key)' ($inst -notmatch "Name = 'RigAiLevel'" -and $inst -notmatch "Build-Profile 'RigAiLevel'" -and $acts -contains 'rig' -and $inst -match '(?s)UUID = "\$uuid\.ailevel".{0,400}VisibleInActionsList = \$false' -and $plug -match "e\.action === UUID \+ '\.ailevel' \? MyDrive : null" -and $plug -notmatch "switchTo\('RigAiLevel'\)")
Check 'the ANALYSIS screen is gone from the add-on and the installer (W3-4 review)' ($plug -notmatch 'const Analysis = new class' -and $inst -notmatch '\$uuid\.analysis' -and $inst -notmatch "RigAnalysis")
function G($page, $name) { ($keys | Where-Object { $_.page -eq $page -and $_.name -eq $name } | Select-Object -First 1).glyph }
Check "each key has its own glyph where two could be mixed up: GET OUT ($(G MAIN 'GET OUT')) / LEAVE ($(G MAIN 'LEAVE')), KIDS ($(G MAIN 'KIDS')) / LOCK ($(G MORE 'LOCK'))" ((G MAIN 'GET OUT') -ne (G MAIN 'LEAVE') -and (G MAIN 'KIDS') -ne (G MORE 'LOCK') -and (G MAIN 'LEAVE') -eq 'door' -and (G MAIN 'KIDS') -eq 'child')
$qq = @($keys | Where-Object { $_.a.exe -eq 'quit-main' } | Sort-Object c)
Check 'QUIT TO MENU reads as one wide key: the picture on the left cell, the words on the right' ($qq.Count -eq 2 -and ($L.pages.LEAVE | Where-Object { $_.c -eq $qq[0].c -and $_.r -eq $qq[0].r }).show -eq 'glyph' -and ($L.pages.LEAVE | Where-Object { $_.c -eq $qq[1].c -and $_.r -eq $qq[1].r }).show -eq 'label')
# a press reaches the deck 2-3 times: the second one lands on the next page's key in the SAME place (W3-4 review). MAIN's MORE key sits at 7,0,
# so MORE 7,0 must not end anything; MAIN's LEAVE key sits at 7,1, so LEAVE 7,1 must be empty.
$main70 = $keys | Where-Object { $_.page -eq 'MAIN' -and $_.a.page -eq 'next' }; $main71 = $keys | Where-Object { $_.page -eq 'MAIN' -and $_.a.page -eq 'previous' }
$under = @($keys | Where-Object { ($_.page -eq 'MORE' -and $_.c -eq $main70.c -and $_.r -eq $main70.r) -or ($_.page -eq 'LEAVE' -and $_.c -eq $main71.c -and $_.r -eq $main71.r) })
Check "the key under MAIN's MORE / LEAVE keys on the next page is empty (a doubled press there hits nothing; LOCK moved to MORE 7,3)" ($under.Count -eq 0 -and ($keys | Where-Object { $_.page -eq 'MORE' -and $_.name -eq 'LOCK' }).c -eq 7 -and ($keys | Where-Object { $_.page -eq 'MORE' -and $_.name -eq 'LOCK' }).r -eq 3) (($under | ForEach-Object { "$($_.page) $($_.name)" }) -join ', ')
Check 'the add-on ignores presses for 0.8 s after the deck changes page (screens and opener keys), and AI RACE START leaves only after that' ($plug -match 'const SWITCH_DEAF_MS = 800;' -and $plug -match 'switchTo\(profile\) \{ switchedAt = performance\.now\(\);' -and $plug -match 'if \(deafNow\(\)\) \{ log\(this\.name' -and $plug -match 'if \(keyScreen && deafNow\(\)\)' -and $plug -match 'await sleep\(SWITCH_DEAF_MS\);\s*this\.exit\(\); return;')

Section '5. build-deck.ps1 -Preview reads this file'
$before = @(git -C $root status --porcelain --untracked-files=all | Where-Object { $_ -notmatch ' deck/(keys/|preview-)' })
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-deck.ps1') -Preview 2>&1 | ForEach-Object { "$_" }
$m = [regex]::Match(($o -join "`n"), 'preview written to (\S+)')
Check 'build-deck.ps1 -Preview ran and said where it wrote (no Stream Deck needed)' ($m.Success) ($o -join ' ')
$after = @(git -C $root status --porcelain --untracked-files=all | Where-Object { $_ -notmatch ' deck/(keys/|preview-)' })
Check 'it wrote nothing in the repo outside deck\ (docs\deck\main-preview.png is no longer rewritten)' ((($before | Sort-Object) -join '|') -eq (($after | Sort-Object) -join '|')) ((Compare-Object $before $after | ForEach-Object { $_.InputObject }) -join '; ')
$dir = $m.Groups[1].Value
$tsv = @(); if ($m.Success) { $tsv = @(Get-Content (Join-Path $dir 'layout.tsv') -Encoding UTF8 | ForEach-Object { $f = $_.Split("`t"); [pscustomobject]@{ page = $f[0]; c = [int]$f[1]; r = [int]$f[2]; kind = $f[5]; what = $f[6] } }) }
Check "layout.tsv has every key of layout.json ($($tsv.Count) of $($keys.Count))" ($tsv.Count -eq $keys.Count)
$map = if ($m.Success) { @(Get-Content (Join-Path $dir 'keys.map')) } else { @() }
$phoneOnly = @($L.phoneOnly | ForEach-Object { "$($_.exe)=$($_.args)" })
$wantMap = @(@($exeKeys | ForEach-Object { "$($_.a.exe)=$($_.a.args)" }) + $phoneOnly | Select-Object -Unique)
Check "keys.map is one line per key exe plus the $($phoneOnly.Count) the phone still offers ($($map.Count)): to-the-race and spotter-tap in, race-now / spot-up / spot-down / mute-spotter / quit-main2 out" ($map.Count -eq $wantMap.Count -and @($wantMap | Where-Object { $map -notcontains $_ }).Count -eq 0 -and ($map -contains 'to-the-race=to-the-race') -and ($map -contains 'spotter-tap=spotter-tap') -and @($map | Where-Object { $_ -match '^(race-now|spot-up|spot-down|mute-spotter|quit-main2)=' }).Count -eq 0)
$pages = @($L.pageOrder)
function Lands($p, $dirn) { $i = [array]::IndexOf($pages, $p); if ($dirn -eq 'next') { $i++ } else { $i-- }; if ($i -ge 0 -and $i -lt $pages.Count) { $pages[$i] } else { '(none)' } }
$want = @{ 'MAIN|MORE' = 'MORE'; 'MAIN|LEAVE' = 'LEAVE'; 'LEAVE|BACK' = 'MAIN'; 'MORE|BACK' = 'MAIN' }
foreach ($k in @($keys | Where-Object { $_.a.page })) { $id = "$($k.page)|$($k.name)"; Check "$($k.page) $($k.name) ($($k.a.page) page) lands on $(Lands $k.page $k.a.page)" ($want.ContainsKey($id) -and (Lands $k.page $k.a.page) -eq $want[$id]) }
Check 'all four page keys are there' (@($keys | Where-Object { $_.a.page }).Count -eq 4)
$bd = ReadText 'build-deck.ps1'
Check 'build-deck.ps1 draws nothing itself (no System.Drawing) and packages deck\keys\<page>\<c>,<r>.png' ($bd -notmatch 'System\.Drawing|Drawing\.Bitmap' -and $bd -match 'keys\\\$name\\\$pos\.png' -and $bd -match "tools\\deck-render\.ps1")
if ($dir -and (Test-Path $dir)) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
