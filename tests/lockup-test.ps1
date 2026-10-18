# lockup-test.ps1 - braking lock-ups are real lock-ups, not ABS pulses (2026-10-18: a clean BMW lap showed 32 "lock-ups"; the
# Braking tab said "9 LF, 10 RF"). Reads old .ibt files through the running irdash (GET /analysis/deep, no test hook).
#   powershell -ExecutionPolicy Bypass -File tests\lockup-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$api = 'http://localhost:8199'; $pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$f = Get-ChildItem $tel -Filter 'bmwz4gt3_roadamerica*' | Where-Object { $_.Length -gt 5MB } | Sort-Object LastWriteTime | Select-Object -First 1
Check "a BMW Z4 GT3 race file to read: $($f.Name)" ($null -ne $f)
if ($f) {
  $id = [uri]::EscapeDataString($f.Name)
  $s = Invoke-RestMethod "$api/analysis/session?id=$id" -TimeoutSec 120
  $lap = @($s.laps | Where-Object { $_.valid -and $_.time -gt 100 })[0].n
  Assert-RigFree -Where 'deep'
  $d = Invoke-RestMethod "$api/analysis/deep?id=$id&lap=$lap&ref=pb" -TimeoutSec 180
  $locks = @($d.events.me.lock)
  $abs = @($d.events.me.abs)
  Check "lap $lap has ABS working ($($abs.Count) ABS events) - the car does brake with ABS" ($abs.Count -ge 3)
  Check "...and no lock-up is counted inside an ABS event ($($locks.Count) lock-ups): ABS holding a wheel slow is not a lock" (@($locks | Where-Object { $l = $_; @($abs | Where-Object { $l.m -lt ($_.m1 + 15) -and $l.m1 -gt ($_.m - 15) }).Count -gt 0 }).Count -eq 0)
}
''
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }

