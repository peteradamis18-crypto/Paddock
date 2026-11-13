# spotter-guard-test.ps1 - every way into a session gets a working spotter (dash\src\spotterguard.cs), and VOL - can't silence it.
# Offline: reads source and settings, changes nothing, safe while Peter races. The live proof is the log lines in dash\irdash.log
# ("spotter: the sim started - fresh CrewChief") at the next real session.
#   powershell -ExecutionPolicy Bypass -File tests\spotter-guard-test.ps1
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
$g = [IO.File]::ReadAllText((Join-Path $root 'dash\src\spotterguard.cs'))
$ir = [IO.File]::ReadAllText((Join-Path $root 'src\irdeck.cs'))
$main = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
Check 'the guard is in the build' ([IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1')) -match 'spotterguard\.cs')
Check 'irdash starts the guard' ($main -match 'SpotterGuard\.Start\(\)')
Check 'nothing happens while he is on track' ($g -match 'if \(simUp && !simWas && !driving\) Fresh' -and $g -match 'if \(driving\) continue;')
Check 'a CrewChief older than this sim run is replaced' ($g -match 'p\.StartTime < simStart')
Check 'never replaced once the sim is well under way' ($g -match 'TotalSeconds > FreshWindowSeconds\) return')
Check 'started again if it died' ($g -match 'was not running - starting it')
Check 'the sound is checked when the sim connects' ($g -match 'connected && !connectedWas')
Check 'irdeck has the spotter command' ($ir -match 'case "spotter": return CmdSpotter\(\)')
Check 'VOL keys no longer move the spotter' ($ir -match 'which == "game" \? new string\[\] \{ "iRacingSim64DX11", "iRacingUI" \}')
Check 'the spotter has a minimum level and is never lowered by it' ($ir -match 'SpotterMinLevel = 0\.02f' -and $ir -match 'if \(cur < floor\)')
Check 'SPOTTER - / + keys move only CrewChief' ($ir -match 'which == "spotter" \? new string\[\] \{ "CrewChiefV4" \}')
$bd = [IO.File]::ReadAllText((Join-Path $root 'build-deck.ps1'))
Check 'the keys are on the deck, 5 % a press' ($bd -match "'appvol spotter -5'" -and $bd -match "'appvol spotter \+5'")
Check 'the deck rules allow them' ([IO.File]::ReadAllText((Join-Path $root 'src\deckrules.cs')) -match '"spotter"')
$top = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\ui.js')) + [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\index.html')) + [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\core.js'))
Check 'no tire panel on the top screen (Peter 2026-11-02)' ($top -notmatch 'tempCL|id="tires"|tires-note')
$cfg = Get-ChildItem "$env:LOCALAPPDATA\Britton_IT_Ltd" -Recurse -Filter user.config -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($cfg) {
  $s = ([xml](Get-Content $cfg.FullName -Raw)).configuration.userSettings.'CrewChiefV4.Properties.Settings'.setting
  function V($n) { ($s | Where-Object { $_.name -eq $n }).value }
  Check 'CrewChief starts listening by itself' ((V 'run_immediately') -eq 'True')
  Check 'CrewChief is set to iRacing' ((V 'last_game_definition') -eq 'IRACING')
  Check 'CrewChief spotter is on' ((V 'enable_spotter') -eq 'True')
} else { Check 'CrewChief settings found' $false }
foreach ($f in Get-ChildItem (Join-Path $root 'overlays\presets') -Filter *.json) { Check "no on-screen flag in overlay preset $($f.BaseName)" (-not ([IO.File]::ReadAllText($f.FullName) -match '"id":"flag","enabled":true')) }
Check 'new presets have no on-screen flag either' (-not ([IO.File]::ReadAllText((Join-Path $root 'src\overlays.cs')) -match 'new\[\] \{ "flag", "(relative|blindspot)'))
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
