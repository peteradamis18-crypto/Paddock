# Practice loop (SAVE SPOT / BACK TO SPOT with timed tries) and PAUSE. Offline: no sim, no clicks, no keys.
#   1. dash\src\spotcore.cs compiled on its own and run on made-up laps (tests\spot-unit.cs): where a try ends, timing to the frame,
#      resets by key and by hand, a reset mid-try, leaving the car, the start/finish line
#   2. wiring: irdash route (this PC only), the thread starts, both new files are in both builds, irdeck commands and the Test Drive gate,
#      Active Reset's keys match the ones in Peter's controls (Ctrl+Shift+F1 / F2), the messages
#   3. live, only when the rig is free: the real /api/spot route answers (status only, nothing is pressed)
#   powershell -ExecutionPolicy Bypass -File tests\spot-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Section($name) { $name }
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function ReadText($p) { [IO.File]::ReadAllText((Join-Path $root $p)) }

Section '1. the try timer on made-up laps'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP ('spot-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
& $csc /nologo /target:exe "/out:$tmp\unit.exe" /r:System.dll /r:System.Core.dll (Join-Path $root 'dash\src\spotcore.cs') (Join-Path $PSScriptRoot 'spot-unit.cs') | Out-Null
if (-not (Test-Path "$tmp\unit.exe")) { Check 'spotcore.cs and tests\spot-unit.cs compile' $false }
else {
  $u = & "$tmp\unit.exe"
  foreach ($l in $u) { if ($l -match '^ok ') { $script:pass++; "  $l" } elseif ($l -match '^FAIL ') { $script:fail++; "  $l" } }
  Check 'unit run finished' ($u -contains 'UNIT-DONE')
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Section '2. wiring'
$dash = ReadText 'dash\src\irdash.cs'; $glue = ReadText 'dash\src\spot.cs'; $db = ReadText 'dash\build.ps1'; $ib = ReadText 'build-irdeck.ps1'
$ir = ReadText 'src\irdeck.cs'; $sp = ReadText 'src\spot.cs'; $say = ReadText 'src\keymsg.cs'
Check 'irdash: GET /api/spot answers this PC only' ($dash -match '(?s)path == "/api/spot".{0,400}!local')
Check 'irdash starts the spot thread' ($dash -match 'Spot\.Start\(\)')
Check 'both new irdash files are in dash\build.ps1' ($db -match 'spotcore\.cs' -and $db -match 'src\\spot\.cs')
Check 'src\spot.cs is in build-irdeck.ps1' ($ib -match 'src\\spot\.cs')
Check 'irdeck: spot and pause are commands' ($ir -match 'case "spot": return CmdSpot' -and $ir -match 'case "pause": return CmdPause')
Check 'irdeck KeyCode knows the Pause key (0x13, what Peter''s controls bind to Pause)' ($ir -match 'case "pause": vk = 0x13')
Check 'spot save sends iRacing''s Active Reset save, Ctrl+Shift+F1, and back sends Ctrl+Shift+F2' ($sp -match 'SendCombo\("ctrl\+shift\+f1"' -and $sp -match 'SendCombo\("ctrl\+shift\+f2"')
Check 'Active Reset is for a Test Drive only: the gate reads EventType Test and says so otherwise' ($sp -match 'EventType:\\s\*Test' -and $sp -match 'this is for a Test Drive')
Check 'BACK waits out iRacing''s 1.5 s save-to-run cooldown' ($sp -match 'ago < 1700')
Check 'BACK says so when nothing happened (no silent failure)' ($sp -match 'iRacing did not move the car back')
Check 'irdeck talks to irdash at 127.0.0.1 (not localhost: 2 s slower)' ($sp -match '127\.0\.0\.1:8199/api/spot' -and $sp -notmatch 'localhost')
Check 'PAUSE reads the sim''s own clock before and after, and says when the sim did not pause' ($sp -match 'SimClockStands' -and $sp -match 'the sim did not')
$lines = @('spot: ok - Spot saved', 'spot: refused - this is for a Test Drive', 'spot: refused - get in the car first', 'spot: refused - nothing saved yet', 'spot: iRacing did not move the car', 'spot: ok - back at the spot, timing to the exit of T5', 'pause: ok - Paused: press', 'pause: ok - Running again', 'pause: the sim did not pause', 'spot: refused - iRacing is not in a session')
$all = @([regex]::Matches($say, 'new\[\] \{ @"((?:[^"]|"")*)", "(\w+)", "([^"]*)" \}') | ForEach-Object { $_.Groups[1].Value.Replace('""', '"') })
$noMsg = @($lines | Where-Object { $l = $_; -not ($all | Where-Object { [regex]::IsMatch($l, $_, 'IgnoreCase') }) })
Check ('every spot / pause log line has a plain message' + $(if ($noMsg.Count) { ' -> missing: ' + ($noMsg -join '; ') } else { '' })) ($noMsg.Count -eq 0)
# the same table, first match wins, as irdeck does it: the three outcomes read right
$rows = @([regex]::Matches($say, 'new\[\] \{ @"((?:[^"]|"")*)", "(\w+)", "([^"]*)" \}') | ForEach-Object { , @($_.Groups[1].Value.Replace('""', '"'), $_.Groups[2].Value, $_.Groups[3].Value) })
function Words($line) { foreach ($r in $rows) { $m = [regex]::Match($line, $r[0], 'IgnoreCase'); if ($m.Success) { $t = $r[2]; for ($g = 1; $g -lt $m.Groups.Count; $g++) { $t = $t.Replace('$' + $g, $m.Groups[$g].Value.Trim()) }; return $r[1] + '|' + $t } }; return '' }
Check 'saved line reads: Spot saved - tries are timed to the exit of T5 Kettle Bottoms' ((Words 'spot: ok - Spot saved - tries are timed to the exit of T5 Kettle Bottoms') -eq 'ok|Spot saved - tries are timed to the exit of T5 Kettle Bottoms')
Check 'AI race: Test Drive only (not "No race running")' ((Words 'spot: refused - this is for a Test Drive (iRacing''s Active Reset works there only)') -eq 'no|Test Drive only (Active Reset)')
Check 'nothing saved: press SAVE SPOT first' ((Words 'spot: refused - nothing saved yet: press SAVE SPOT where you want to come back to') -eq 'wait|Press SAVE SPOT first')
Check 'paused / running lines' ((Words 'pause: ok - Paused: press PAUSE again to carry on') -eq 'ok|Paused - press again to carry on' -and (Words 'pause: ok - Running again') -eq 'ok|Running again')
Check 'the finished-try line is irdash''s own message (key spot), not irdeck''s' ($glue -match 'KeyMsg\.Set\("spot"')
Check 'irdash forgets the spot when the sim closes or the car enters the garage (iRacing forgets it too)' ($glue -match 'IsInGarage' -and $glue -match 'wasUp')
Check 'the saved spot is the frame nearest the key press, not the frame after the sim came to the front' ($glue -match 'Math\.Abs\(s\.Ms - atMs\)')
Check 'the end of a try comes from the track''s corner list (Corners.Resolve), 300 m on when there is none' ($glue -match 'Corners\.Resolve' -and $glue -match '300\.0 / lengthM')

Section '3. live (status only)'
try { Assert-RigFree } catch { "  info  the rig is busy: $_ - live part skipped"; "$pass passed, $fail failed."; if ($fail -gt 0) { exit 1 } else { exit 0 } }
try {
  $r = Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:8199/api/spot?cmd=status' -TimeoutSec 5
  if ($r.StatusCode -eq 200 -and $r.Content -match '"saved":') { Check 'the running irdash answers /api/spot status' $true }
  else { Check 'the running irdash answers /api/spot status' $false }
} catch {
  if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { "  info  the running irdash does not have /api/spot yet (deploy irdash)" } else { Check "the running irdash answers /api/spot status ($($_.Exception.Message))" $false }
}
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
