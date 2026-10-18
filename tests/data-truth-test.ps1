# data-truth-test.ps1 - the numbers Peter sees against the raw telemetry, recomputed by an INDEPENDENT reader (tests\fixtures\rawibt.cs:
# its own .ibt header parse and its own maths). 2026-10-18 audit. Reads two old files + GETs on the running irdash (no test hook, no deploy).
#   1. lap times: Session Review time == the time iRacing announced (LapLastLapTime) == the line-to-line time
#   2. lap table (brakeM, entry, min, minM, exit, time) per corner, 3 laps, against the raw records
#   3. deep dive brake start == lap table brake point (it once measured a light first tap / a late blip: "brake 12 m, peak 10 %" for a 100 % stop)
#   4. the coach: every "Braking N m earlier" card is true on the raw laps (median over its losing laps)
#   5. HOME 'This week' hours / laps == the sum over this week's telemetry files (on-track seconds, line crossings)
#   powershell -ExecutionPolicy Bypass -File tests\data-truth-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'; try { (Get-Process -Id $PID).ProcessorAffinity = [IntPtr]3 } catch { }
$api = 'http://localhost:8199'; $pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
function Med($a) { $s = @($a | Sort-Object); if ($s.Count -eq 0) { return $null }; $n = $s.Count; if ($n % 2) { $s[[int][math]::Floor($n / 2)] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 } }
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\rawibt.cs') -ReferencedAssemblies System.dll
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
if (-not (Test-Path $tel)) { $tel = Join-Path $env:USERPROFILE 'OneDrive\Documents\iRacing\telemetry' }
$want = 'Speed', 'Brake', 'Throttle', 'LapDistPct', 'Lap', 'LapCompleted', 'LapLastLapTime', 'SessionTime', 'OnPitRoad', 'PlayerTrackSurface'
$n = 'bmwz4gt3_roadamerica 2026 full 2026-10-17 20-51-41.ibt'
if (-not (Test-Path (Join-Path $tel $n))) { "  (skipped: $n is not in the telemetry folder)"; exit 0 }
$e = [uri]::EscapeDataString($n)

Assert-RigFree -Where '1. lap times'
$b = [RawIbt]::Open((Join-Path $tel $n), $want); $raw = $b.Laps()
$ses = Invoke-RestMethod "$api/analysis/session?id=$e" -TimeoutSec 200
foreach ($l in $raw) {
  $sv = @($ses.laps | Where-Object { $_.n -eq $l.Num })[0]
  if (-not $sv -or $l.Official -lt 1 -or -not $sv.official) { continue }     # the out lap (flag OUT) is timed from the pits: iRacing's figure is not line to line (served 132.7 s vs announced 138.5 s, flagged OUT, not counted)
  Check "lap $($l.Num): served $($sv.time) = announced $([math]::Round($l.Official, 3)) (0.002 s)" ([math]::Abs([double]$sv.time - $l.Official) -le 0.002)
  Check "lap $($l.Num): served $($sv.time) = line to line $([math]::Round($l.Time, 3)) (0.15 s)" ([math]::Abs([double]$sv.time - $l.Time) -le 0.15)
}

Assert-RigFree -Where '2. corner stats'
$tableBrake = @{}
foreach ($lapNo in 2, 3, 4) {
  $srv = Invoke-RestMethod "$api/analysis/lap?id=$e&lap=$lapNo&ref=session" -TimeoutSec 200
  $l = $raw | Where-Object { $_.Num -eq $lapNo }; $sc = 1; if ([math]::Abs($l.Official - $l.Time) -lt 0.15) { $sc = $l.Official / $l.Time }
  $bad = @()
  foreach ($c in $srv.corners) {
    $cc = New-Object RawIbt+Corner; $cc.P0 = $c.p0; $cc.Pa = $c.pa; $cc.P1 = $c.p1
    $r = $b.Measure($l, $cc, $sc)
    if ([math]::Abs($c.time - $r.Time) -gt 0.02) { $bad += "$($c.label) time $($c.time) vs $([math]::Round($r.Time, 3))" }
    if ([math]::Abs($c.entryKmh - $r.Entry) -gt 0.5) { $bad += "$($c.label) entry $($c.entryKmh) vs $([math]::Round($r.Entry, 2))" }
    if ([math]::Abs($c.minKmh - $r.Min) -gt 0.5) { $bad += "$($c.label) min $($c.minKmh) vs $([math]::Round($r.Min, 2))" }
    if ([math]::Abs($c.minM - $r.MinM) -gt 1.5) { $bad += "$($c.label) minM $($c.minM) vs $([math]::Round($r.MinM, 1))" }
    if ([math]::Abs($c.exitKmh - $r.Exit) -gt 0.5) { $bad += "$($c.label) exit $($c.exitKmh) vs $([math]::Round($r.Exit, 2))" }
    if ($r.HasBrake -and $c.brakeM) { if ([math]::Abs($c.brakeM - $r.BrakeMain) -gt 1.5) { $bad += "$($c.label) brake $($c.brakeM) vs main application $([math]::Round($r.BrakeMain, 1))" } }
    elseif ([bool]$r.HasBrake -ne [bool]$c.brakeM) { $bad += "$($c.label) brake presence: served '$($c.brakeM)' raw $($r.HasBrake)" }
    $tableBrake["$lapNo/$($c.n)"] = $c.brakeM
  }
  Check "lap ${lapNo}: all $(@($srv.corners).Count) corners match the raw records (1.5 m, 0.5 km/h, 0.02 s)" ($bad.Count -eq 0) ($bad -join '; ')
}

Assert-RigFree -Where '3. deep dive'
foreach ($lapNo in 2, 3, 4) {
  $deep = Invoke-RestMethod "$api/analysis/deep?id=$e&lap=$lapNo&ref=session" -TimeoutSec 200
  $bad = @()
  foreach ($c in $deep.corners) {
    $tb = $tableBrake["$lapNo/$($c.n)"]; $ds = $c.me.brake.startM
    if ($tb -and $ds -and [math]::Abs([double]$tb - [double]$ds) -gt 2) { $bad += "$($c.label) table $tb vs deep $ds (peak $($c.me.brake.peakPct) %, len $($c.me.brake.lenM) m)" }
  }
  Check "lap ${lapNo}: the deep dive's brake start is the lap table's braking point (2 m)" ($bad.Count -eq 0) ($bad -join '; ')
}

Assert-RigFree -Where '4. coach'
$co = Invoke-RestMethod "$api/analysis/coach?id=$e" -TimeoutSec 200
$cl = @($ses.laps | Where-Object { $_.skip -eq '' -and $_.time -and $_.time -le $co.ref.time * 1.02 } | ForEach-Object { $_.n })
foreach ($f in $co.focus) {
  $cc = New-Object RawIbt+Corner; $cc.P0 = $f.p0; $cc.Pa = $f.pa; $cc.P1 = $f.p1
  $M = @{}; foreach ($k in $cl) { $l = $raw | Where-Object { $_.Num -eq $k }; $sc = 1; if ($l.Official -gt 0 -and [math]::Abs($l.Official - $l.Time) -lt 0.15) { $sc = $l.Official / $l.Time }; $M[$k] = $b.Measure($l, $cc, $sc) }
  $ref = $M[[int]$co.ref.lap]; $loss = @(); $brk = @(); $pk = @(); $mn = @()
  foreach ($k in $cl) { if ($k -eq $co.ref.lap) { continue }; $a = $M[$k]; if ($a.Time - $ref.Time -ge 0.05) { $loss += $k; $brk += ($a.BrakeMain - $ref.BrakeMain); $pk += ($a.Pickup - $ref.Pickup); $mn += (($a.Min - $ref.Min) / 1.609344) } }
  Check "$($f.label): served loss $($f.loss) s, lost $($f.lost) of $($f.laps)" ($loss.Count -eq $f.lost)
  foreach ($fact in $f.facts) {
    if ($fact -match 'Braking (\d+) m earlier') { $m = Med $brk; Check "$($f.label): '$fact' - raw median brake shift $([math]::Round($m, 1)) m (negative = earlier)" ($m -lt -3) }
    if ($fact -match 'Braking (\d+) m later') { $m = Med $brk; Check "$($f.label): '$fact' - raw median brake shift $([math]::Round($m, 1)) m" ($m -gt 3) }
    if ($fact -match '(\d+) mph slower at the slowest point') { $m = Med $mn; Check "$($f.label): '$fact' - raw median $([math]::Round($m, 1)) mph" ($m -lt -2 -and [math]::Abs([math]::Abs($m) - [double]$matches[1]) -le 1.5) }
  }
}

Assert-RigFree -Where '5. this week'
$hm = Invoke-RestMethod "$api/home" -TimeoutSec 60
$ses2 = Invoke-RestMethod "$api/sessions" -TimeoutSec 60
$now = Get-Date; $ws = $now.Date.AddDays(-((([int]$now.DayOfWeek) + 6) % 7))
$files = @($ses2.sessions | Where-Object { -not $_.short -and ([DateTimeOffset]::FromUnixTimeMilliseconds($_.ts).LocalDateTime) -ge $ws })
$secs = 0; $laps = 0
foreach ($r in $files) {
  $p = Join-Path $tel $r.file; if (-not (Test-Path $p)) { continue }
  $x = [RawIbt]::Open($p, @('IsOnTrack', 'LapDistPct', 'SessionTime', 'Lap'))
  $on = $x.ch['IsOnTrack']; $pc = $x.ch['LapDistPct']; $cnt = 0
  for ($i = 1; $i -lt $x.records; $i++) { if ($on[$i] -ne 0) { $secs++ ; if ($on[$i - 1] -ne 0 -and $pc[$i - 1] -gt 0.9 -and $pc[$i] -lt 0.1) { $cnt++ } } }
  $laps += $cnt
}
$secs = $secs / 60
# the cache is rebuilt when a new file appears; allow one new file between the two reads
Check "HOME week laps $($hm.week.laps) = line crossings in this week's files ($laps)" ([math]::Abs($hm.week.laps - $laps) -le 2)
Check "HOME week hours $($hm.week.hours) = on-track time in this week's files ($([math]::Round($secs / 3600, 2)))" ([math]::Abs($hm.week.hours - $secs / 3600) -le 0.1)
Check "HOME week starts on the Monday ($($hm.week.from))" ($hm.week.from -eq $ws.ToString('ddd d MMM', [Globalization.CultureInfo]::InvariantCulture))
''
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }

