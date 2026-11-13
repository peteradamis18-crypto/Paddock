# deck-layout-test.ps1 - no key on any deck page ends the PC in one press (W0-1).
# OFFLINE: runs build-deck.ps1 -Preview (writes only %TEMP%\PaddockPreview-* and docs\deck\main-preview.png, which this test puts
# back with git afterwards) and reads its layout.tsv: one line per key (page, col, row, labels, kind, what it does).
#   1. no key that ends the PC (power off / sleep / restart) is a plain key exe on any page; SHUT DOWN PC and SLEEP PC open the
#      add-on's Confirm action, with what= set; keys.map has no power off / sleep line
#   2. the Confirm action exists in the add-on manifest (install.ps1), plugin.html has the screen and its RigConfirm profile
#   3. every page's LEAVE / MORE / BACK key still lands on the page it says (page order LEAVE, MAIN, MORE)
#   powershell -ExecutionPolicy Bypass -File tests\deck-layout-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }

Section '1. the pages (build-deck.ps1 -Preview)'
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-deck.ps1') -Preview 2>&1 | ForEach-Object { "$_" }
$m = [regex]::Match(($o -join "`n"), 'preview written to (\S+)')
Push-Location $root; git checkout -q -- docs/deck/main-preview.png 2>$null; Pop-Location   # -Preview rewrites this tracked picture
Check 'build-deck.ps1 -Preview ran and said where it wrote' $m.Success ($o -join ' ')
$dir = $m.Groups[1].Value
$deck = @(); if ($m.Success) { $deck = @(Get-Content (Join-Path $dir 'layout.tsv') -Encoding UTF8 | ForEach-Object { $f = $_.Split("`t"); [pscustomobject]@{ page = $f[0]; col = [int]$f[1]; row = [int]$f[2]; t1 = $f[3]; t2 = $f[4]; kind = $f[5]; what = $f[6] } }) }
$map = if ($m.Success) { @(Get-Content (Join-Path $dir 'keys.map')) } else { @() }
Check "the layout has MAIN, MORE and LEAVE ($($deck.Count) keys)" (@($deck | Where-Object page -eq 'MAIN').Count -ge 20 -and @($deck | Where-Object page -eq 'MORE').Count -ge 10 -and @($deck | Where-Object page -eq 'LEAVE').Count -ge 4)
$ends = '(^|=)\s*(power\s+(off|sleep|restart)|confirm\s)'
$plain = @($deck | Where-Object { $_.kind -eq 'key' -and $_.what -match $ends })
Check 'no key exe on any page turns the PC off, sleeps or restarts it (and none uses the old confirm/x2)' ($plain.Count -eq 0) (($plain | ForEach-Object { "$($_.page) $($_.t1) $($_.t2)=$($_.what)" }) -join '; ')
Check 'keys.map has no power off / sleep / restart line (so no key exe exists for them, from the deck or the phone)' (@($map | Where-Object { $_ -match $ends }).Count -eq 0) (($map | Where-Object { $_ -match $ends }) -join '; ')
$sd = $deck | Where-Object { $_.page -eq 'LEAVE' -and $_.t1 -eq 'SHUT' }; $sl = $deck | Where-Object { $_.page -eq 'LEAVE' -and $_.t1 -eq 'SLEEP' }
Check 'SHUT DOWN PC (LEAVE 6,3) and SLEEP PC (LEAVE 7,3) open the add-on Confirm action' ($sd.kind -eq 'plugin' -and $sd.what -eq 'com.peter.rigintro.confirm' -and $sd.col -eq 6 -and $sd.row -eq 3 -and $sl.kind -eq 'plugin' -and $sl.what -eq 'com.peter.rigintro.confirm' -and $sl.col -eq 7 -and $sl.row -eq 3)
$bd = [IO.File]::ReadAllText((Join-Path $root 'build-deck.ps1'))
Check "the two keys carry what= shutdown / sleep in their settings, and the real deck only gets them once the installed add-on has Confirm" ($bd -match "plugin = 'com\.peter\.rigintro\.confirm'; name = 'Confirm'; settings = \[ordered\]@\{ what = 'shutdown' \}" -and $bd -match "settings = \[ordered\]@\{ what = 'sleep' \}" -and $bd -match '\$confirmOn = \$Preview -or' -and $bd -match "Settings = \`$\(if \(\`$a\.settings\)")
Check 'no PC-ending key on MAIN or MORE at all (LOCK only locks Windows)' (@($deck | Where-Object { $_.page -ne 'LEAVE' -and ($_.t1 -match 'SHUT|SLEEP' -or $_.what -match 'confirm') }).Count -eq 0)

Section '2. the add-on knows the Confirm action'
$inst = [IO.File]::ReadAllText((Join-Path $root 'deck-intro\install.ps1')); $plug = [IO.File]::ReadAllText((Join-Path $root 'deck-intro\plugin.html'))
Check 'install.ps1: action $uuid.confirm named Confirm, and the RigConfirm profile is listed and built' ($inst -match 'UUID = "\$uuid\.confirm"; Name = ''Confirm''' -and $inst -match "Name = 'RigConfirm'; DeviceType = 2" -and $inst -match "Build-Profile 'RigConfirm' 'confirm'")
Check 'install.ps1: the version went up from 1.8.9.0' ([version]([regex]::Match($inst, "\`$ver = '([\d.]+)'").Groups[1].Value) -gt [version]'1.8.9.0')
Check 'plugin.html: the confirm screen is in SCREENS and switches to RigConfirm' ($plug -match 'const SCREENS = \{[^}]*confirm: Confirm' -and $plug -match "this\.switchTo\('RigConfirm'\)")

Section '3. page keys land where they say'
$order = [regex]::Match($bd, 'Pages = @\(\$ids\.(\w+), \$ids\.(\w+), \$ids\.(\w+)\)')
$pages = @($order.Groups[1].Value, $order.Groups[2].Value, $order.Groups[3].Value) | ForEach-Object { $_.ToUpper() }
Check "the profile lists the pages in the order LEAVE, MAIN, MORE ($($pages -join ', '))" (($pages -join ',') -eq 'LEAVE,MAIN,MORE')
function Lands($k) { $i = [array]::IndexOf($pages, $k.page); if ($k.what -eq 'next') { $i++ } else { $i-- }; if ($i -ge 0 -and $i -lt $pages.Count) { $pages[$i] } else { '(none)' } }
$want = @{ 'MAIN|LEAVE' = 'LEAVE'; 'MAIN|MORE' = 'MORE'; 'LEAVE|BACK' = 'MAIN'; 'MORE|BACK' = 'MAIN' }
foreach ($k in @($deck | Where-Object kind -eq 'page')) {
  $id = "$($k.page)|$($k.t1)"
  Check "$($k.page) $($k.t1) ($($k.what) page) lands on $(Lands $k)" ($want.ContainsKey($id) -and (Lands $k) -eq $want[$id])
}
Check 'all four page keys are there (MAIN LEAVE, MAIN MORE, LEAVE BACK, MORE BACK)' (@($deck | Where-Object kind -eq 'page').Count -eq 4)

if ($dir -and (Test-Path $dir)) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
