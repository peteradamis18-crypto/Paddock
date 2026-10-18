# brakepoint-test.ps1 - the braking point the coach/lap analysis uses is the MAIN brake application (the one with the pedal),
# the same place the deep-dive engine reports (2026-10-18: a second press near the apex moved the best lap's "braking point" 60 m
# later, and the coach told him to brake EARLIER on a lap where he braked later than the best lap). Reads one old file through
# the running irdash (GET only, no test hook).
#   powershell -ExecutionPolicy Bypass -File tests\brakepoint-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$api = 'http://localhost:8199'; $pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
$n = 'bmwz4gt3_roadamerica 2026 full 2026-10-17 20-51-41.ibt'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
if (-not (Test-Path (Join-Path $tel $n))) { "  (skipped: $n is not in the telemetry folder)"; exit 0 }
$e = [uri]::EscapeDataString($n)
# lap 1 is the out lap (a tap, then the main brake): the two engines may name different applications there, and the coach never uses it
foreach ($l in 2, 3, 4) {
  Assert-RigFree -Where "lap $l"
  $deep = Invoke-RestMethod "$api/analysis/deep?id=$e&lap=$l&ref=pb" -TimeoutSec 200
  $d6 = $deep.corners | Where-Object { $_.label -eq 'T6' }
  $an = Invoke-RestMethod "$api/analysis/lap?id=$e&lap=$l&ref=session" -TimeoutSec 100
  $a6 = @($an.corners | Where-Object { $_.n -eq 5 })[0]
  $diff = [math]::Abs([double]$a6.brakeM - [double]$d6.me.brake.startM)
  Check "lap $l T6: lap analysis brakes at $($a6.brakeM) m, deep dive at $($d6.me.brake.startM) m (within 15 m)" ($diff -le 15)
}
$c = Invoke-RestMethod "$api/analysis/coach?id=$e" -TimeoutSec 150
$t6 = @($c.focus | Where-Object { $_.label -eq 'T6' })[0]
Check 'the coach does not say "braking earlier" at T6: every lap braked within 10 m of the best lap there' (-not $t6 -or -not (@($t6.facts) -match 'Braking \d+ m earlier'))
''
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }


