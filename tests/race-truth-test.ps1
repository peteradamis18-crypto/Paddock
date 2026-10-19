# race-truth-test.ps1 - what Paddock says about Peter's RACES, against the raw telemetry (2026-10-18 audit). Offline: reads old .ibt files with the
# independent reader (tests\fixtures\rawibt.cs) + GETs on the running irdash (no test hook, no deploy). Skips a file that is not in the telemetry folder.
#   1. Vault race cards: 'P14 of N' - N is the number of drivers in the race (DriverInfo), once each. It once counted the 'CarIdx: 8' / '255' lines of
#      ResultsFastestLap too, so a 20-car race said 'of 22'.
#   2. /debrief: finishing position, laps, incidents, start position against the last records of the file (and the winner's missing lap 5 of the
#      09-27 race that moved Peter from P11 to P10)
#   powershell -ExecutionPolicy Bypass -File tests\race-truth-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'; try { (Get-Process -Id $PID).ProcessorAffinity = [IntPtr]3 } catch { }
$api = 'http://localhost:8199'; $pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\rawibt.cs') -ReferencedAssemblies System.dll
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
if (-not (Test-Path $tel)) { $tel = Join-Path $env:USERPROFILE 'OneDrive\Documents\iRacing\telemetry' }
$races = @(
  'bmwz4gt3_roadamerica 2026 full 2026-10-17 20-22-14.ibt', 'bmwz4gt3_roadamerica 2026 full 2026-10-17 20-51-41.ibt',
  'bmwz4gt3_roadamerica 2026 full 2026-10-15 09-27-41.ibt', 'bmwz4gt3_roadamerica 2026 full 2026-10-15 13-14-15.ibt', 'bmwz4gt3_roadatlanta full 2026-10-12 15-35-30.ibt')
$want = 'SessionTime', 'SessionState', 'SessionNum', 'LapCompleted', 'PlayerCarPosition', 'PlayerCarClassPosition', 'PlayerCarMyIncidentCount'

function DriverCount($yaml) {      # drivers of the race: DriverInfo only, each CarIdx once, no pace car, no spectator
  $m = [regex]::Match($yaml, '(?m)^DriverInfo:[ \t]*\r?\n[\s\S]*?(?=^\S)').Value; $seen = @{}; $n = 0
  foreach ($x in [regex]::Matches($m, '- CarIdx: (\d+)[ \t]*\r?\n((?:   [^\r\n]*\r?\n?)*)')) {
    $i = $x.Groups[1].Value; if ($seen[$i]) { continue }; $seen[$i] = 1; $g = $x.Groups[2].Value
    if ($g -match 'CarIsPaceCar: 1' -or $g -match 'IsSpectator: 1') { continue }; $n++
  }
  $n
}

Assert-RigFree -Where '1. vault race cards'
$vl = Invoke-RestMethod "$api/vault/list" -TimeoutSec 120
$cards = @($vl.moments | Where-Object { $_.kind -eq 'race' -and $_.finished })
foreach ($n in $races) {
  $p = Join-Path $tel $n; if (-not (Test-Path $p)) { "  (skipped: $n is not in the telemetry folder)"; continue }
  $b = [RawIbt]::Open($p, $want); $e = $b.records - 1
  $card = @($cards | Where-Object { $_.ibt -eq $n -or $_.session -eq $n })
  $fieldRaw = DriverCount $b.yaml
  if ($card.Count -eq 0) { $card = @($cards | Where-Object { [math]::Abs([double]$_.startMs - [double]($b.startDate * 1000)) -lt 60000 }) }
  if ($card.Count -eq 0) { "  (no Vault race card matched $n)"; continue }
  Check "$n : card says P$($card[0].pos) of $($card[0].field); raw P$($b.ch['PlayerCarPosition'][$e]) of $fieldRaw" ($card[0].pos -eq $b.ch['PlayerCarPosition'][$e] -and $card[0].field -eq $fieldRaw)
}

Assert-RigFree -Where '2. debrief'
foreach ($n in $races) {
  $p = Join-Path $tel $n; if (-not (Test-Path $p)) { continue }
  $b = [RawIbt]::Open($p, $want); $e = $b.records - 1; $pos = $b.ch['PlayerCarPosition']; $st = $b.ch['SessionState']
  $g = -1; for ($i = 0; $i -lt $b.records; $i++) { if ($st[$i] -eq 4) { $g = $i; break } }
  $start = 0; for ($i = $g; $i -lt $b.records; $i++) { if ($pos[$i] -gt 0) { $start = $pos[$i]; break } }
  $d = Invoke-RestMethod "$api/debrief?id=$([uri]::EscapeDataString($n))" -TimeoutSec 200
  if (-not $d.ok -or -not $d.race) { Check "$n : debrief is a race" $false "ok=$($d.ok) race=$($d.race) $($d.error)"; continue }
  $r = $d.result
  Check "$n : finish P$($r.finishPosition) = raw P$($pos[$e])" ($r.finishPosition -eq $pos[$e])
  Check "$n : class position P$($r.classPosition) = raw P$($b.ch['PlayerCarClassPosition'][$e])" ($r.classPosition -eq $b.ch['PlayerCarClassPosition'][$e])
  Check "$n : laps $($r.totalLaps) = raw $($b.ch['LapCompleted'][$e])" ($r.totalLaps -eq $b.ch['LapCompleted'][$e])
  Check "$n : incidents $($r.incidents) = raw $($b.ch['PlayerCarMyIncidentCount'][$e])" ($r.incidents -eq $b.ch['PlayerCarMyIncidentCount'][$e])
  Check "$n : start P$($r.startPosition) = raw P$start" ($r.startPosition -eq $start)
  Check "$n : clean laps $($r.cleanLaps) of $($r.totalLaps) (never more than driven)" ($r.cleanLaps -le $r.totalLaps)
  $last = @($d.positionByLap | Where-Object { $_.position })[-1]
  if ($last) { Check "$n : position by lap ends at P$($last.position) = finish" ($last.position -eq $r.finishPosition) }
  if ($r.finishPosition -gt 1 -and $r.gapLaps -le 0 -and $r.gapToWinner -ne $null) { Check "$n : gap to winner $($r.gapToWinner) s is under a lap" ([double]$r.gapToWinner -lt 140) }
}
"$pass passed, $fail failed"; if ($fail -gt 0) { exit 1 }
