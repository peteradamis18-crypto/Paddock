# AI LEVEL (second screen behind the AI LEVEL key): how hard the AI is for the next AI RACE. Offline: no sim, no clicks.
#   1. dash\src\ailevel.cs compiled on its own (its few irdash neighbours stubbed, tests\ailevel-unit.cs): the saved choice, the range
#      steps and limits, a damaged file, and the key list the screen paints (one label per key, every key accepted)
#   2. wiring: /ailevel route, the whitelisted command, both files in the builds, the add-on screen, its action and profile, the deck key
#   3. AI RACE applies the choice in the wizard (see docs\research\ai-opponents-dump-*.txt for what the step looks like)
#   powershell -ExecutionPolicy Bypass -File tests\ailevel-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($name) { $name }
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function ReadText($p) { [IO.File]::ReadAllText((Join-Path $root $p)) }

Section '1. the saved choice and the key list'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP ('ailevel-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
& $csc /nologo /target:exe "/out:$tmp\unit.exe" /r:System.dll /r:System.Core.dll (Join-Path $root 'dash\src\ailevel.cs') (Join-Path $PSScriptRoot 'ailevel-unit.cs') | Out-Null
if (-not (Test-Path "$tmp\unit.exe")) { Check 'ailevel.cs and tests\ailevel-unit.cs compile' $false }
else {
  $u = & "$tmp\unit.exe"
  foreach ($l in $u) { if ($l -match '^ok ') { $script:pass++; "  $l" } elseif ($l -match '^FAIL ') { $script:fail++; "  $l" } }
  Check 'unit run finished' ($u -contains 'UNIT-DONE')
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Section '2. wiring'
$dash = ReadText 'dash\src\irdash.cs'; $db = ReadText 'dash\build.ps1'; $plug = ReadText 'deck-intro\plugin.html'; $inst = ReadText 'deck-intro\install.ps1'; $bd = ReadText 'build-deck.ps1'
Check 'irdash serves GET /ailevel' ($dash -match 'path == "/ailevel".{0,200}AiLevel\.Json\(\)')
Check 'the ailevel press goes through /api/do to AiLevel.Do' ($dash -match 'AiLevel\.Handles\(dc\) \? AiLevel\.Do\(dc, da\)')
Check 'ailevel.cs is in dash\build.ps1' ($db -match 'src\\ailevel\.cs')
Check 'add-on (W3-4): the level row is on the AI RACE screen (MyDrive): it reads /ailevel and sends ailevel low / medium / high, START sends ailevel start' ($plug -match "this\.get\('/ailevel'\)" -and $plug -match "this\.cmd\('ailevel', r\.arg\)" -and $plug -match "this\.cmd\('ailevel', 'start'\)" -and $plug -notmatch 'const AiLevel = new class')
Check 'add-on (W3-4): the separate AI LEVEL screen is retired (no ailevel action, no RigAiLevel profile)' ($inst -notmatch '\$uuid\.ailevel' -and $inst -notmatch "Name = 'RigAiLevel'" -and $inst -notmatch "Build-Profile 'RigAiLevel'")
$lay = ReadText 'deck\layout.json'
Check 'the deck (deck\layout.json): AI RACE opens that one screen; no AI LEVEL or CAR TRACK key' ($lay -match '"label": \["AI RACE"\][^}]*"screen": "mydrive"' -and $lay -notmatch 'AI LEVEL|CAR TRACK|"ailevel"')
Check 'the add-on version is higher than the one installed before this screen (1.8.5)' ($inst -match "\`$ver = '1\.8\.([6-9]|\d\d)\.")

Section '3. AI RACE applies it'
$td = ReadText 'src\testdrive.cs'
Check 'AI RACE reads <root>\ai\level.json at the AI Opponents step' ($td -match 'ai\\level\.json' -and $td -match 'AiApplyLevel')
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
