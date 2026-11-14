# pi-check-test.ps1 - offline (W4-6): the "Pi check" of docs\rework\PLAN.md section 6 and evidence 06 section 4.
# One lap, the 12 Nov 09:28 race lap 9 (tests\fixtures\race-12nov-lap9-whole.ibt, 1:33.832), through Paddock's own engine
# (irdash.exe --analysis: the /analysis/lap corner numbers and the /analysis/channels traces, the code behind W4-1's
# /api/review/corners and /api/review/traces) and through an INDEPENDENT reader of the raw .ibt (tests\fixtures\rawibt.cs: its own
# header parse and its own corner maths, nothing of Paddock's code). Pi Toolbox itself cannot be run here (the lead does, steps in
# docs\rework\evidence\16-pi-check.md): this test compares Paddock with the raw file and writes the numbers, dated, into that file.
#   1. Paddock's engine runs on the fixture: lap 9, 1:33.832, 14 corners, the 1 m trace grid
#   2. the raw reader finds the same two laps (9 and 10) and the same times
#   3. every corner: time, entry, minimum speed and where, exit, throttle pick-up, brake point within the stated tolerances
#   4. three metre marks (1000, 2028, 3000 m): time into the lap, delta against lap 10, speed, lateral and longitudinal g
#   5. the numbers are written into the evidence file (two tables between markers; the rest of the file is written by hand)
# Tolerances (stated, not tuned to pass): time 0.02 s; speed 0.3 km/h at a corner, 0.5 km/h at a mark; a distance 2 m; g 0.05 g;
# delta 0.03 s. (One record is 1/60 s: at 40 m/s that is 0.67 m and 0.016 s; Paddock puts the lap on a 1 m grid.)
#   powershell -ExecutionPolicy Bypass -File tests\pi-check-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" + $(if ($why) { " -> $why" } else { '' }) } }
function Section($t) { Assert-RigFree -Where $t; $t }
'Pi check test (W4-6)'

# ---- the fixtures: ignored by git, so a worktree finds them in the main checkout (read-only) ----
$common = $null; try { $g = (& git -C $root rev-parse --git-common-dir 2>$null); if ($g) { if (-not [IO.Path]::IsPathRooted($g)) { $g = Join-Path $root $g }; $common = Split-Path -Parent ([IO.Path]::GetFullPath($g)) } } catch { }
function Find-File($rel) { foreach ($b in @($root, $common)) { if ($b) { $p = Join-Path $b $rel; if (Test-Path $p) { return $p } } } return $null }
$ibt = Find-File 'tests\fixtures\race-12nov-lap9-whole.ibt'
$lovelyDir = Find-File 'data\corners\lovely\roadatlanta-full.json'
if (-not $ibt -or -not $lovelyDir) { '  info  the fixture .ibt or the Lovely corner file is missing here and in the main checkout: skipped'; "0 passed, 0 failed."; exit 0 }
$lovelyDir = Split-Path -Parent $lovelyDir

$work = Join-Path $env:TEMP ('pi-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
  New-Item -ItemType Directory -Force "$work\dir", "$work\root\data\corners\lovely", "$work\root\dash\maps" | Out-Null
  Copy-Item $ibt "$work\dir\race-12nov-lap9-whole.ibt"
  # the saved Road Atlanta track map beside it: the engine puts a corner's apex from it (without it T12's apex moves 65 m: see the evidence file)
  $mapsDir = Find-File 'dash\maps'; if ($mapsDir) { Get-ChildItem $mapsDir -Filter '*roadatlanta*' | Copy-Item -Destination "$work\root\dash\maps\" }
  Copy-Item "$lovelyDir\*.json" "$work\root\data\corners\lovely\"     # a copy: the engine may write beside it, never into the real data folder

  Section '1. Paddock engine on lap 9'
  $build = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
  $bm = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
  Check 'dash\build.ps1 -NoDeploy compiled' ($bm.Success) $build
  if (-not $bm.Success) { throw 'no build' }
  $exe = Join-Path $bm.Groups[1].Value.Trim() 'irdash.exe'
  function Run-Engine([string]$extra, [string]$out) {
    $a = "--analysis --root `"$work\root`" --dir `"$work\dir`" --id race-12nov-lap9-whole.ibt --lap 9 --ref pb $extra --out `"$out`""
    $p = Start-Process $exe -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
  }
  $rc1 = Run-Engine '' "$work\lap.json"
  $rc2 = Run-Engine '--channels --ch Speed,LatAccel,LongAccel' "$work\ch.bin"
  Check 'the engine answered both questions (exit 0, 0)' ($rc1 -eq 0 -and $rc2 -eq 0) "$rc1 $rc2"
  $j = Get-Content "$work\lap.json" -Raw -Encoding UTF8 | ConvertFrom-Json
  Check "lap 9 is $($j.time) s (iRacing's own 93.832), $(@($j.corners).Count) corners, track '$($j.track)'" ([math]::Abs([double]$j.time - 93.832) -lt 0.0005 -and @($j.corners).Count -eq 14) ''
  $b = [IO.File]::ReadAllBytes("$work\ch.bin"); $hl = [BitConverter]::ToInt32($b, 4)
  $h = [Text.Encoding]::UTF8.GetString($b, 8, $hl) | ConvertFrom-Json
  $arr = @{}; $pos = 8 + $hl
  foreach ($k in $h.arrays) { $x = New-Object float[] $h.n; [Buffer]::BlockCopy($b, $pos, $x, 0, $h.n * 4); $arr[$k] = $x; $pos += $h.n * 4 }
  Check "the trace grid: $($h.n) points over $($h.lengthM) m, reference lap $($h.ref.lap) ($($h.ref.time) s)" ($b[0] -eq 80 -and $h.n -gt 4000 -and $h.ref.lap -eq 10 -and $arr.ContainsKey('lap.t') -and $arr.ContainsKey('ref.t')) ''
  $step = [double]$h.step; $G = 9.80665

  Section '2. the independent reader'
  Add-Type -TypeDefinition (Get-Content (Join-Path $PSScriptRoot 'fixtures\rawibt.cs') -Raw) -Language CSharp -ErrorAction SilentlyContinue
  $r = [RawIbt]::Open("$work\dir\race-12nov-lap9-whole.ibt", [string[]]@('SessionTime', 'Lap', 'Speed', 'Brake', 'Throttle', 'LapDistPct', 'LapLastLapTime', 'OnPitRoad', 'PlayerTrackSurface', 'LatAccel', 'LongAccel'))
  $laps = $r.Laps()
  $l9 = $laps | Where-Object { [math]::Abs($_.Time - 93.832) -lt 0.01 } | Select-Object -First 1
  $l10 = $laps | Where-Object { [math]::Abs($_.Time - 94.996) -lt 0.01 } | Select-Object -First 1
  Check "the raw reader finds lap 9 ($([math]::Round($l9.Time, 3)) s from the line crossings) and lap 10 ($([math]::Round($l10.Time, 3)) s)" ($l9 -and $l10 -and [math]::Abs($l9.Time - 93.832) -lt 0.002 -and [math]::Abs($l10.Time - 94.996) -lt 0.002) ''
  Check "the track is $([math]::Round($r.L, 1)) m long in the file's own header; Paddock says $($j.lengthM) m" ([math]::Abs($r.L - [double]$j.lengthM) -lt 0.05) ''
  function Slice($name, $lap) { [double[]]($r.ch[$name][$lap.A..($lap.B - 1)]) }
  $lat9 = Slice 'LatAccel' $l9; $lon9 = Slice 'LongAccel' $l9; $lat10 = Slice 'LatAccel' $l10

  Section '3. every corner'
  $brakeNotes = @(); $cornerRows = @(); $worst = @{ time = [double]0; spd = [double]0; dist = [double]0 }
  foreach ($c in $j.corners) {
    $co = New-Object RawIbt+Corner; $co.N = $c.n; $co.Label = $c.label; $co.P0 = $c.p0; $co.Pa = $c.pa
    $co.P1 = $(if ([double]$c.p1 -le [double]$c.p0) { 1.0 } else { [double]$c.p1 })     # T12 ends at the line: Paddock stores 0.0
    $m = $r.Measure($l9, $co, 1.0)
    $bad = @()
    $dT = [math]::Abs([double]$c.time - $m.Time); if ($dT -gt 0.02) { $bad += "time $dT" }
    $dMin = [math]::Abs([double]$c.minKmh - $m.Min); if ($dMin -gt 0.3) { $bad += "min speed $dMin" }
    $dEnt = [math]::Abs([double]$c.entryKmh - $m.Entry); if ($dEnt -gt 0.3) { $bad += "entry $dEnt" }
    $dEx = [math]::Abs([double]$c.exitKmh - $m.Exit); if ($dEx -gt 0.3) { $bad += "exit $dEx" }
    $dMM = [math]::Abs([double]$c.minM - $m.MinM); if ($dMM -gt 2) { $bad += "min at $dMM m" }
    $dPk = [math]::Abs([double]$c.pickupM - $m.Pickup); if ($dPk -gt 2) { $bad += "pickup $dPk m" }
    # the brake point: every press start (the pedal through 10 %) from 250 m before the apex to the apex, read from the raw records by this
    # test (a press already on 250 m out counts from where it began, up to 80 m further back: Paddock's rule, analysis.cs MeasureOne).
    # Paddock picks the main press (most pedal); it must be one of these starts, and "no brake point" must mean there is none.
    $da = [double]$c.pa * $r.L; $starts = @(); $before = $null
    for ($q = 1; $q -lt $l9.D.Length; $q++) {
      if ($l9.D[$q] -gt $da) { break }
      if ($l9.D[$q] -lt $da - 330 -or $l9.Br[$q] -le 0.10 -or $l9.Br[$q - 1] -gt 0.10) { continue }
      $f = (0.10 - $l9.Br[$q - 1]) / ($l9.Br[$q] - $l9.Br[$q - 1]); $s = $l9.D[$q - 1] + ($l9.D[$q] - $l9.D[$q - 1]) * $f
      if ($s -lt $da - 250) { $before = $s } else { $starts += $s }
    }
    if ($null -ne $before -and [RawIbt]::At($l9, $l9.Br, $da - 250) -gt 0.10) { $starts += $before }
    $pHas = ($null -ne $c.brakeM); $dBr = [double]0; $bRaw = $null
    if ($pHas) { $near = $starts | Sort-Object { [math]::Abs($_ - [double]$c.brakeM) } | Select-Object -First 1; if ($null -eq $near) { $bad += 'brake: Paddock has a brake point, the raw records show no press' } else { $bRaw = $near; $dBr = [math]::Abs([double]$c.brakeM - $near); if ($dBr -gt 2) { $bad += "brake point $dBr m from the nearest press start" } } }
    elseif ($starts.Count -gt 0) { $bad += "brake: Paddock has none, the raw records show a press at $([math]::Round($starts[0])) m" }
    if ($m.HasBrake -and $pHas -and [math]::Abs($m.BrakeMain - [double]$c.brakeM) -gt 2) { $brakeNotes += ('{0}: rawibt.cs picks the press at {1:N0} m, Paddock {2:N0} m (rawibt weighs the whole press, Paddock the part inside the 250 m window)' -f $c.label, $m.BrakeMain, $c.brakeM) }
    if ($m.HasBrake -ne $pHas) { $brakeNotes += ('{0}: rawibt.cs says {1}, Paddock {2} (rawibt skips a press still on at the apex)' -f $c.label, $(if ($m.HasBrake) { 'brake' } else { 'no brake' }), $(if ($pHas) { 'brake' } else { 'no brake' })) }
    if ($pHas -and ($da - [double]$c.brakeM) -gt 200) { $brakeNotes += ('{0}: Paddock''s brake point is {1:N0} m before the apex: the press that began in the corner before (a linked corner), still on 250 m out; the raw records show {2} press start(s) in the window ({3})' -f $c.label, ($da - [double]$c.brakeM), $starts.Count, (($starts | ForEach-Object { '{0:N0} m' -f $_ }) -join ', ')) }
    $worst.time = [math]::Max($worst.time, $dT); $worst.spd = [math]::Max($worst.spd, [math]::Max($dMin, [math]::Max($dEnt, $dEx))); $worst.dist = [math]::Max($worst.dist, [math]::Max($dMM, [math]::Max($dPk, $dBr)))
    Check ("{0,-9} time {1:N3}/{2:N3} s, min {3:N2}/{4:N2} km/h at {5:N0}/{6:N0} m, entry {7:N1}/{8:N1}, exit {9:N1}/{10:N1}, pick-up {11:N0}/{12:N0} m, brake {13}/{14}  (Paddock/raw)" -f $c.label, $c.time, $m.Time, $c.minKmh, $m.Min, $c.minM, $m.MinM, $c.entryKmh, $m.Entry, $c.exitKmh, $m.Exit, $c.pickupM, $m.Pickup, $(if ($pHas) { '{0:N0}' -f $c.brakeM } else { 'none' }), $(if ($null -ne $bRaw) { '{0:N0}' -f $bRaw } else { 'none' })) ($bad.Count -eq 0) ($bad -join '; ')
    $cornerRows += [pscustomobject]@{ L = $c.label; tP = [double]$c.time; tR = $m.Time; mP = [double]$c.minKmh; mR = $m.Min; aP = [double]$c.minM; aR = $m.MinM; pP = [double]$c.pickupM; pR = $m.Pickup; bP = $(if ($pHas) { [double]$c.brakeM } else { $null }); bR = $bRaw }
  }
  Check ('the worst gaps over all 14 corners: time {0:N3} s, speed {1:N2} km/h, distance {2:N1} m' -f $worst.time, $worst.spd, $worst.dist) $true

  Section '4. three metre marks'
  $marks = @(1000, 2028, 3000); $markRows = @()
  foreach ($d in $marks) {
    $i = [int][math]::Round($d / $step)
    $tP = [double]$arr['lap.t'][$i]; $dP = $tP - [double]$arr['ref.t'][$i]
    $vP = [double]$arr['lap.Speed'][$i] * 3.6; $laP = [double]$arr['lap.LatAccel'][$i] / $G; $loP = [double]$arr['lap.LongAccel'][$i] / $G
    $tR = [RawIbt]::At($l9, $l9.T, $d); $dR = $tR - [RawIbt]::At($l10, $l10.T, $d)
    $vR = [RawIbt]::At($l9, $l9.S, $d) * 3.6; $laR = [RawIbt]::At($l9, $lat9, $d) / $G; $loR = [RawIbt]::At($l9, $lon9, $d) / $G
    $bad = @()
    if ([math]::Abs($tP - $tR) -gt 0.02) { $bad += 'time' }; if ([math]::Abs($dP - $dR) -gt 0.03) { $bad += 'delta' }; if ([math]::Abs($vP - $vR) -gt 0.5) { $bad += 'speed' }
    if ([math]::Abs($laP - $laR) -gt 0.05) { $bad += 'lateral g' }; if ([math]::Abs($loP - $loR) -gt 0.05) { $bad += 'longitudinal g' }
    Check ("{0,4} m: time {1:N3}/{2:N3} s, delta {3:+0.000;-0.000}/{4:+0.000;-0.000} s, speed {5:N1}/{6:N1} km/h, lat {7:N2}/{8:N2} g, long {9:N2}/{10:N2} g  (Paddock/raw)" -f $d, $tP, $tR, $dP, $dR, $vP, $vR, $laP, $laR, $loP, $loR) ($bad.Count -eq 0) ($bad -join ', ')
    $markRows += [pscustomobject]@{ D = $d; tP = $tP; tR = $tR; dP = $dP; dR = $dR; vP = $vP; vR = $vR; aP = $laP; aR = $laR; gP = $loP; gR = $loR }
  }

  Section '5. the evidence file'
  $doc = Join-Path $root 'docs\rework\evidence\16-pi-check.md'
  $inv = [Globalization.CultureInfo]::InvariantCulture
  function F($x, $f) { if ($null -eq $x) { return 'none' } return ([double]$x).ToString($f, $inv) }
  $t1 = @("Run: $(Get-Date -Format 'yyyy-MM-dd HH:mm') by ``tests\pi-check-test.ps1`` (Paddock = irdash's own engine; Raw = ``tests\fixtures\rawibt.cs`` on the same file). Tolerances: time 0.02 s, speed 0.3 km/h, distance 2 m.", '',
    '| Corner | Time s: Paddock | Raw | Min km/h: Paddock | Raw | Min at m: Paddock | Raw | Pick-up m: Paddock | Raw | Brake point m: Paddock | Raw |', '|---|---|---|---|---|---|---|---|---|---|---|')
  foreach ($c in $cornerRows) { $t1 += "| $($c.L) | $(F $c.tP 'N3') | $(F $c.tR 'N3') | $(F $c.mP 'N2') | $(F $c.mR 'N2') | $(F $c.aP 'N1') | $(F $c.aR 'N1') | $(F $c.pP 'N1') | $(F $c.pR 'N1') | $(F $c.bP 'N1') | $(F $c.bR 'N1') |" }
  $t1 += ''; $t1 += "Worst gaps: time $(F $worst.time 'N3') s, speed $(F $worst.spd 'N2') km/h, distance $(F $worst.dist 'N1') m. The Raw brake-point column is the nearest press start (pedal through 10 %) the test itself finds in the raw records."
  if ($brakeNotes.Count) { $t1 += ''; $t1 += 'The brake point, wherever it is not a plain match:'; foreach ($n in $brakeNotes) { $t1 += "- $n" } }
  $t1 += ''; $t1 += '| Mark | Time into lap s: Paddock | Raw | Delta vs lap 10 s: Paddock | Raw | Speed km/h: Paddock | Raw | Lateral g: Paddock | Raw | Longitudinal g: Paddock | Raw |'; $t1 += '|---|---|---|---|---|---|---|---|---|---|---|'
  foreach ($m in $markRows) { $t1 += "| $($m.D) m | $(F $m.tP 'N3') | $(F $m.tR 'N3') | $(F $m.dP '+0.000;-0.000') | $(F $m.dR '+0.000;-0.000') | $(F $m.vP 'N1') | $(F $m.vR 'N1') | $(F $m.aP 'N2') | $(F $m.aR 'N2') | $(F $m.gP 'N2') | $(F $m.gR 'N2') |" }
  # the table the lead fills in Pi: Paddock's numbers in, Pi and difference empty
  $t2 = @('| What | Paddock | Pi | Difference |', '|---|---|---|---|')
  foreach ($m in $markRows) {
    $t2 += "| Time into the lap at $($m.D) m (s) | $(F $m.tP 'N3') | | |"; $t2 += "| Delta at $($m.D) m, lap 9 minus lap 10 (s) | $(F $m.dP '+0.000;-0.000') | | |"
    $t2 += "| Speed at $($m.D) m (km/h) | $(F $m.vP 'N1') | | |"; $t2 += "| Lateral g at $($m.D) m | $(F $m.aP 'N2') | | |"; $t2 += "| Longitudinal g at $($m.D) m | $(F $m.gP 'N2') | | |"
  }
  foreach ($c in $cornerRows | Where-Object { $_.L -in 'T1', 'T5', 'T7', 'T10a' }) { $t2 += "| Minimum speed in $($c.L) (km/h) | $(F $c.mP 'N2') | | |" }
  $t2 += "| Lap time (s) | $(F $j.time 'N3') | | |"
  if (Test-Path $doc) {
    $text = [IO.File]::ReadAllText($doc, [Text.Encoding]::UTF8)
    $ok = $true
    foreach ($pair in @(@('PADDOCK-RAW', $t1), @('PI-FILL-IN', $t2))) {
      $rx = "(?s)(<!-- $($pair[0]):BEGIN -->)\r?\n.*?(<!-- $($pair[0]):END -->)"
      if ($text -notmatch $rx) { $ok = $false; continue }
      # the lead's own Pi numbers are never overwritten: once any Pi cell is filled that table stays as it is
      if ($pair[0] -eq 'PI-FILL-IN' -and (($Matches[0] -split "`n") | Where-Object { $_ -match '^\|[^|]+\|[^|]+\|\s*[^|\s][^|]*\|' -and $_ -notmatch '^\|\s*(What|-)' })) { "  info  the Pi table already has the lead's numbers: left as it is"; continue }
      $body = ($pair[1] -join "`n")
      $text = [regex]::Replace($text, $rx, { param($mm) $mm.Groups[1].Value + "`n" + $body + "`n" + $mm.Groups[2].Value })
    }
    if ($ok) { [IO.File]::WriteAllText($doc, $text, (New-Object Text.UTF8Encoding($false))) }
    Check 'the two tables (Paddock against raw; the Pi fill-in with Paddock filled) were written into docs\rework\evidence\16-pi-check.md' $ok 'a marker pair is missing in the file'
    $back = [IO.File]::ReadAllText($doc, [Text.Encoding]::UTF8)
    Check 'the file now carries today''s date and all 14 corners' ($back.Contains((Get-Date -Format 'yyyy-MM-dd')) -and ([regex]::Matches($back, '(?m)^\| (T\d+[ab]?|The Esses) \|')).Count -ge 14) ''
    $pi = [regex]::Match($back, '(?s)<!-- PI-FILL-IN:BEGIN -->(.*?)<!-- PI-FILL-IN:END -->').Groups[1].Value
    Check 'the fill-in table has Paddock''s 20 numbers in (the Pi column is the lead''s to fill)' ((($pi -split "`n") | Where-Object { $_ -match '^\| [A-Z][^|]+\| -?[\d.]+ \|' }).Count -eq 20) ''
  } else { Check 'the evidence file exists' $false $doc }
}
finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
