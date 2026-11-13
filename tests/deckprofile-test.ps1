# deckprofile-test.ps1 - the deck goes back to MAIN before Stream Deck starts (W0-1, src\deckprofile.cs).
# OFFLINE and on a COPY: the real "iRacing GT3" profile tree is copied to %TEMP% and only the copy is changed. The real profile, the
# Stream Deck app and irdash are never touched. deckprofile.cs is compiled on its own with a driver that swaps the "is Stream Deck
# running" check for a pretend one.
#   1. on the copy: Current goes to the MAIN page, every other byte of the manifest stays the same; a second run says "already"
#   2. it refuses while a StreamDeck.exe process exists (pretend), and writes nothing then
#   3. a profile with no MAIN page, or no profile: nothing is written
#   4. wiring: irdash's watchdog and irdeck's SHUT DOWN / SLEEP / RIG ON call it before Stream Deck starts; build-deck writes MAIN as Current
#   powershell -ExecutionPolicy Bypass -File tests\deckprofile-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$tmp = Join-Path $env:TEMP ('deckprofile-test-' + $PID); New-Item -ItemType Directory -Force $tmp | Out-Null
$profId = '65E017A2-2219-43EE-A4E4-44D505F5B406'
$real = Join-Path $env:APPDATA "Elgato\StreamDeck\ProfilesV3\$profId.sdProfile"

$driver = @'
using System;
using IRDeck;
static class D {
  // D <profileDir> <running 0|1>  -> prints the helper's answer
  static void Main(string[] a) {
    bool running = a[1] == "1";
    DeckProfile.AppRunning = delegate { return running; };
    Console.WriteLine(DeckProfile.SetCurrentToMain(a[0]));
  }
}
'@
$dp = Join-Path $tmp 'driver.cs'; Set-Content -LiteralPath $dp -Value $driver -Encoding ASCII
$exe = Join-Path $tmp 'driver.exe'
& $csc -nologo -target:exe -r:System.Web.Extensions.dll "-out:$exe" (Join-Path $root 'src\deckprofile.cs') $dp | Out-Null
Check 'src\deckprofile.cs compiles on its own (C# 5)' ($LASTEXITCODE -eq 0)
function Run($dir, $running) { (& $exe $dir $(if ($running) { '1' } else { '0' }) | Out-String).Trim() }
function Pages($dir) { (Get-Content (Join-Path $dir 'manifest.json') -Raw | ConvertFrom-Json).Pages }
function PageName($dir, $id) { $f = Join-Path $dir "Profiles\$($id.ToUpper())\manifest.json"; if (Test-Path $f) { (Get-Content $f -Raw | ConvertFrom-Json).Name } }

Section '1. on a copy of the real profile'
$haveReal = Test-Path (Join-Path $real 'manifest.json')
Check 'the real "iRacing GT3" profile is there to copy (read only)' $haveReal $real
if ($haveReal) {
  $copy = Join-Path $tmp "$profId.sdProfile"
  Copy-Item -LiteralPath $real -Destination $copy -Recurse
  $realBefore = (Get-FileHash (Join-Path $real 'manifest.json')).Hash
  $p = Pages $copy
  $mainId = @($p.Pages | Where-Object { (PageName $copy $_) -eq 'MAIN' })[0]
  Check "the copy has a MAIN page among its pages ($mainId)" ([bool]$mainId)
  # make the copy look like 12 Nov: Current = LEAVE (or any page that is not MAIN)
  $other = @($p.Pages | Where-Object { $_ -ne $mainId })[0]
  $man = Join-Path $copy 'manifest.json'
  $txt = [IO.File]::ReadAllText($man)
  $txt = [regex]::Replace($txt, '("Current"\s*:\s*")[0-9A-Fa-f-]+(")', ('${1}' + $other + '${2}'))
  [IO.File]::WriteAllText($man, $txt, (New-Object Text.UTF8Encoding $false))
  $before = [IO.File]::ReadAllBytes($man)
  Check "the copy now opens on a page that is not MAIN ($(PageName $copy $other))" ((Pages $copy).Current -eq $other)
  $r = Run $copy $true
  Check "Stream Deck running (pretend): refused ('$r'), the manifest is byte-identical" ($r -eq 'running' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($man)) -eq [Convert]::ToBase64String($before))
  $r = Run $copy $false
  $after = [IO.File]::ReadAllBytes($man)
  Check "Stream Deck stopped: set ('$r'), Current is now MAIN" ($r -eq 'set' -and (Pages $copy).Current -eq $mainId)
  $bt = [Text.Encoding]::UTF8.GetString($before); $at = [Text.Encoding]::UTF8.GetString($after)
  $i = $bt.IndexOf('"Current"'); $j = $at.IndexOf('"Current"')
  $sameOutside = ($i -ge 0 -and $i -eq $j -and $bt.Substring(0, $i) -eq $at.Substring(0, $j) -and $bt.Length -eq $at.Length -and
                  $bt.Substring($i + 11 + 2 + $other.Length) -eq $at.Substring($j + 11 + 2 + $mainId.Length))
  Check 'every other byte of the manifest is the same (only the Current id changed, same length, same encoding)' ($sameOutside -and $after.Length -eq $before.Length)
  $pagesSame = (Compare-Object @(Get-ChildItem (Join-Path $copy 'Profiles') -Recurse -File | Get-FileHash | ForEach-Object Hash) @(Get-ChildItem (Join-Path $real 'Profiles') -Recurse -File | Get-FileHash | ForEach-Object Hash)) -eq $null
  Check 'the page folders are untouched (same files as the real profile)' $pagesSame
  $r = Run $copy $false
  Check "a second run says 'already' and writes nothing ('$r')" ($r -eq 'already' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($man)) -eq [Convert]::ToBase64String($after))
  Check 'no temp file is left beside the manifest' (-not (Test-Path "$man.paddock-tmp"))
  Check 'the REAL profile manifest was not changed by this test' ((Get-FileHash (Join-Path $real 'manifest.json')).Hash -eq $realBefore)

  Section '3. no MAIN, no profile'
  $nomain = Join-Path $tmp 'nomain.sdProfile'; Copy-Item -LiteralPath $copy -Destination $nomain -Recurse
  $mm = Join-Path $nomain "Profiles\$($mainId.ToUpper())\manifest.json"
  [IO.File]::WriteAllText($mm, ([IO.File]::ReadAllText($mm) -replace '"Name"\s*:\s*"MAIN"', '"Name":"MAYN"'), (New-Object Text.UTF8Encoding $false))
  $nm = Join-Path $nomain 'manifest.json'; $nb = (Get-FileHash $nm).Hash
  $r = Run $nomain $false
  Check "a profile with no page named MAIN: '$r', nothing written" ($r -eq 'no-main' -or $r -eq 'already')
  Check '... the manifest is unchanged' ((Get-FileHash $nm).Hash -eq $nb)
}
$r = Run (Join-Path $tmp 'not-there') $false
Check "no profile folder: '$r'" ($r -eq 'no-profile')

Section '4. wiring'
$dash = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs')); $ir = [IO.File]::ReadAllText((Join-Path $root 'src\irdeck.cs')); $bd = [IO.File]::ReadAllText((Join-Path $root 'build-deck.ps1'))
$rs = $dash.Substring($dash.IndexOf('static void RestartDeck(string why)'), 2500)
Check 'watchdog restart: kill, wait, set MAIN, then start (in that order)' ($rs.IndexOf('p.Kill()') -lt $rs.IndexOf('DeckToMain(why)') -and $rs.IndexOf('DeckToMain(why)') -lt $rs.IndexOf('Process.Start('))
Check 'watchdog "Stream Deck was not running": MAIN first, then start' ($dash -match 'lastDeckStart = now; DeckToMain\("start"\);')
Check 'irdash DeckToMain uses IRDeck.DeckProfile.SetCurrentToMain' ($dash -match 'IRDeck\.DeckProfile\.SetCurrentToMain\(IRDeck\.DeckProfile\.ProfileDir\(\)\)')
$pw = $ir.Substring($ir.IndexOf('static int CmdPower(string[] a)'), 2600)
Check 'SHUT DOWN / SLEEP: deck to MAIN before the PC goes (sleep starts Stream Deck again)' ($pw.IndexOf('DeckToMain(c == "sleep")') -gt 0 -and $pw.IndexOf('DeckToMain(c == "sleep")') -lt $pw.IndexOf('shutdown.exe') -and $ir -match 'static void DeckToMain\(bool startAgain\)')
Check 'RIG ON: MAIN before it starts Stream Deck' ($ir.IndexOf('DeckProfile.SetCurrentToMain') -lt $ir.IndexOf('StartApp("StreamDeck"'))
Check 'build-deck.ps1 writes MAIN as Current' ($bd -match 'Current = \$ids\.main')
Check 'both builds compile deckprofile.cs' (([IO.File]::ReadAllText((Join-Path $root 'build-irdeck.ps1'))) -match 'deckprofile\.cs' -and ([IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))) -match 'deckprofile\.cs')

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
