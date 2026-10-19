# raw-data-test.ps1 - ALL THE DATA and part-laps (Peter 2026-10-18: a qualifying run with one out-lap and no full lap showed
# "Not enough laps" and nothing else: "just show me the data").
#   1-5 offline: a freshly compiled irdash.exe loaded as a library (no server, nothing deployed), BelowNormal, old files only;
#       allowed while Peter races (CLAUDE.md rule 8). /analysis/raw is checked against an independent reader of the raw records
#       (tests\fixtures\rawibt.cs: its own header parse, nothing of Paddock's code) at 5 spot times.
#   6   live, only when the rig is free and the running irdash has the route: the HTTP replies, the Sessions list and pictures
#       of rawdata.html and coach.html (tests\shots\raw-*.png, headless Chrome, nothing on his screens).
#   powershell -ExecutionPolicy Bypass -File tests\raw-data-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$name = 'porsche718gt4_roadamerica 2026 full 2026-10-18 08-36-50.ibt'
$file = Join-Path $tel $name
if (-not (Test-Path $file)) { "  info  $name is not in $tel - nothing to test"; exit 0 }
$newest = Get-ChildItem $tel -Filter *.ibt | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newest.Name -eq $name -and (Get-RigBusy)) { '  info  the evidence file is the newest and the rig is busy: never read it now'; exit 0 }

'1. compile without deploying and load the engines'
$build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
$bm = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
Check 'dash\build.ps1 -NoDeploy compiled (rawdata.cs and partial.cs are in $src)' $bm.Success ($build.Substring([Math]::Max(0, $build.Length - 600)))
if (-not $bm.Success) { exit 1 }
$asm = [Reflection.Assembly]::LoadFile((Join-Path $bm.Groups[1].Value.Trim() 'irdash.exe'))
$bf = [Reflection.BindingFlags]'Static,Public,NonPublic'
$asm.GetType('IRDash.TrackMaps').GetField('TelemetryDir').SetValue($null, [string]$tel)
$asm.GetType('IRDash.Corners').GetField('DataRoot', $bf).SetValue($null, [string]$root)
$an = $asm.GetType('IRDash.Analysis')

'2. /analysis/raw on the drive with no full lap'
$j = $an.GetMethod('RawJson', $bf).Invoke($null, [object[]]@([string]$file, [double]::NaN, [double]::NaN, [double]0))
$o = $j | ConvertFrom-Json
Check "the whole drive is there: $($o.total) s, $($o.n) points (every $($o.step). record)" ([double]$o.total -gt 200 -and $o.n -ge 1000 -and @($o.t).Count -eq $o.n -and @($o.spd).Count -eq $o.n)
$spdMax = ($o.spd | Measure-Object -Maximum -Minimum); $brk = ($o.brk | Measure-Object -Maximum -Minimum); $thr = ($o.thr | Measure-Object -Maximum -Minimum)
Check "sane ranges: speed $($spdMax.Minimum)-$($spdMax.Maximum) mph, brake $($brk.Minimum)-$($brk.Maximum), throttle $($thr.Minimum)-$($thr.Maximum)" ($spdMax.Minimum -ge 0 -and $spdMax.Maximum -le 200 -and $spdMax.Maximum -gt 100 -and $brk.Minimum -ge 0 -and $brk.Maximum -le 1 -and $thr.Minimum -ge 0 -and $thr.Maximum -le 1)
Check 'steering, gear, RPM, lap distance, GPS, wheel speeds and g are all there' ($o.steer -and $o.gear -and $o.rpm -and $o.pct -and $o.lat -and $o.lon -and $o.lf -and $o.rr -and $o.latG -and $o.longG)
$kinds = @($o.laps | ForEach-Object { $_.kind })
Check "the timeline has the out-lap and the part lap ($($kinds -join ', '))" ($kinds -contains 'out' -and $kinds -contains 'partial')
Check "the events have the line crossing ($(@($o.events | ForEach-Object { $_.k }) -join ', '))" (@($o.events | Where-Object { $_.k -eq 'line' -and $_.lap -eq 1 }).Count -eq 1)
$s = $o.summary
Check "the summary: $($s.onTrackSec) s on track, $($s.miles) mi, top $($s.topMph) mph, $($s.fuelUsedGal) gal, $($s.laps.out) out-lap, $($s.laps.partial) part lap, type '$($s.type)'" ([double]$s.onTrackSec -gt 200 -and [double]$s.miles -gt 3 -and [double]$s.topMph -gt 100 -and [double]$s.fuelUsedL -gt 0 -and $s.laps.out -eq 1 -and $s.laps.partial -eq 1 -and $s.laps.full -eq 0)
$w = $an.GetMethod('RawJson', $bf).Invoke($null, [object[]]@([string]$file, [double]176, [double]200, [double]60)) | ConvertFrom-Json
Check "a zoomed window at 60 a second: $($w.from)-$($w.to) s, $($w.n) points, step $($w.step)" ([double]$w.from -ge 175.9 -and [double]$w.to -le 200.1 -and $w.step -eq 1 -and $w.n -ge 1400)

'3. the same numbers as an independent reader of the raw records, at 5 spot times'
Add-Type -TypeDefinition (Get-Content (Join-Path $PSScriptRoot 'fixtures\rawibt.cs') -Raw) -Language CSharp -ErrorAction SilentlyContinue
$r = [RawIbt]::Open($file, [string[]]@('SessionTime', 'Speed', 'Brake', 'Throttle', 'Gear', 'RPM', 'LapDistPct', 'SteeringWheelAngle'))
$st = $r.ch['SessionTime']; $t0 = $st[0]
$full = $an.GetMethod('RawJson', $bf).Invoke($null, [object[]]@([string]$file, [double]::NaN, [double]::NaN, [double]60)) | ConvertFrom-Json
Check "at 60 a second every record is a point ($($full.n) of $($r.records))" ($full.n -eq $r.records -and $full.step -eq 1)
foreach ($k in @([int]($full.n * 0.07), [int]($full.n * 0.31), [int]($full.n * 0.55), [int]($full.n * 0.74), [int]($full.n * 0.93))) {
  $tt = [double]$full.t[$k]; $i = 0; $best = 1e9
  for ($q = 0; $q -lt $r.records; $q++) { $d = [math]::Abs(($st[$q] - $t0) - $tt); if ($d -lt $best) { $best = $d; $i = $q } }
  $mph = $r.ch['Speed'][$i] * 2.2369363
  $ok = $best -lt 0.002 -and [math]::Abs($mph - [double]$full.spd[$k]) -le 0.06 -and [math]::Abs($r.ch['Brake'][$i] - [double]$full.brk[$k]) -le 0.0006 -and [math]::Abs($r.ch['Throttle'][$i] - [double]$full.thr[$k]) -le 0.0006 -and
    $r.ch['Gear'][$i] -eq [double]$full.gear[$k] -and [math]::Abs($r.ch['RPM'][$i] - [double]$full.rpm[$k]) -le 0.6 -and [math]::Abs($r.ch['LapDistPct'][$i] - [double]$full.pct[$k]) -le 0.00006 -and
    [math]::Abs($r.ch['SteeringWheelAngle'][$i] * 57.2957795 - [double]$full.steer[$k]) -le 0.06
  Check ("  at {0:N2} s: {1:N1} mph, brake {2:N3}, throttle {3:N3}, gear {4}, {5:N0} rpm, {6:N4} of the lap (raw record {7})" -f $tt, $mph, $r.ch['Brake'][$i], $r.ch['Throttle'][$i], $r.ch['Gear'][$i], $r.ch['RPM'][$i], $r.ch['LapDistPct'][$i], $i) $ok ("reply: " + $full.spd[$k] + ' ' + $full.brk[$k] + ' ' + $full.thr[$k] + ' ' + $full.gear[$k] + ' ' + $full.rpm[$k] + ' ' + $full.pct[$k])
}

'4. part-laps through the lap engines (no more "not a full lap")'
$m = $an.GetMethod('BuildChannels', $bf)
$a = [object[]]@([string]$file, [int]1, 'pb', 'Speed,Throttle,Brake', [string]$tel, $false, 0, '')
$b = [byte[]]$m.Invoke($null, $a)
Check "/analysis/channels lap 1 answers 200, not 409 (got $($a[6]))" ($a[6] -eq 200 -and $b[0] -eq 80)
if ($b[0] -eq 80) {
  $hl = [BitConverter]::ToInt32($b, 4); $h = [Text.Encoding]::UTF8.GetString($b, 8, $hl) | ConvertFrom-Json
  $pos = 8 + $hl; $arr = @{}; foreach ($k in $h.arrays) { $x = New-Object float[] $h.n; [Buffer]::BlockCopy($b, $pos, $x, 0, $h.n * 4); $arr[$k] = $x; $pos += $h.n * 4 }
  $sp = $arr['lap.Speed']; $i1 = [int][math]::Floor([double]$h.partial.toM / ([double]$h.lengthM / $h.metres))
  Check "it is marked partial: '$($h.partial.text)'" ($h.partial -and [double]$h.partial.fromPct -lt 0.01 -and [double]$h.partial.toPct -gt 0.45 -and [double]$h.partial.toPct -lt 0.5)
  Check 'no value is made up where the lap was not driven (NaN after the stretch), real values inside it' ([float]::IsNaN($sp[$h.n - 2]) -and [float]::IsNaN($sp[$i1 + 5]) -and -not [float]::IsNaN($sp[1000]) -and $sp[1000] -gt 10)
  # independent: time from the line crossing to the end of the stretch, from the raw records (the line crossing interpolated the same way)
  $rr = [RawIbt]::Open($file, [string[]]@('SessionTime', 'LapDistPct', 'Lap', 'Speed', 'LapLastLapTime')); $p = $rr.ch['LapDistPct']; $l = $rr.ch['Lap']; $s2 = $rr.ch['SessionTime']
  $ia = 0; for ($q = 1; $q -lt $rr.records; $q++) { if ($l[$q] -eq 1 -and $l[$q - 1] -eq 0 -and $p[$q - 1] -gt 0.9) { $ia = $q; break } }
  $f0 = (1 - $p[$ia - 1]) / ((1 - $p[$ia - 1]) + $p[$ia]); $tc = $s2[$ia - 1] + ($s2[$ia] - $s2[$ia - 1]) * $f0
  $ib = $ia; while ($ib + 1 -lt $rr.records -and $p[$ib + 1] -le [double]$h.partial.toPct + 1e-6 -and $l[$ib + 1] -eq 1) { $ib++ }
  $indep = $s2[$ib] - $tc
  Check ("the stretch's time agrees with the raw records: {0:N3} s here, {1:N3} s raw" -f [double]$h.partial.time, $indep) ([math]::Abs([double]$h.partial.time - $indep) -lt 0.05)
}
$bl = $an.GetMethod('Build', $bf)
$lj = $bl.Invoke($null, [object[]]@([string]$file, [int]1, 'pb', [string]$tel, $false, $null)) | ConvertFrom-Json
Check "/analysis/lap lap 1: $(@($lj.corners).Count) corners over the stretch, gap $($lj.gap) s over the same metres, partial '$($lj.partial.text)'" (@($lj.corners).Count -ge 3 -and $lj.partial -and $lj.ref -and $lj.gap -ne $null)
$dp = $an.GetMethod('BuildDeep', $bf)
foreach ($lap in 0, 1) {
  $a3 = [object[]]@([string]$file, [int]$lap, 'pb', [string]$tel, $false, [double]0, 0); $dj = $dp.Invoke($null, $a3) | ConvertFrom-Json
  Check "/analysis/deep lap $lap answers 200 with partial and the reason in words, not 409 ($($dj.reason))" ($a3[6] -eq 200 -and $dj.partial -eq $true -and $dj.reason -match 'ALL THE DATA' -and $dj.raw -match 'rawdata.html')
}
$a0 = [object[]]@([string]$file, [int]0, 'pb', 'Speed', [string]$tel, $false, 0, ''); $null = $m.Invoke($null, $a0)
Check "/analysis/channels lap 0 (the out-lap, from the pit exit) answers 200 too (got $($a0[6]))" ($a0[6] -eq 200)

'5. the coach never only refuses'
$c = $an.GetMethod('Coach', $bf).Invoke($null, [object[]]@([string]$file)) | ConvertFrom-Json
Check "coach: ready, mode '$($c.mode)', summary $($c.summary.onTrackSec) s on track, $(@($c.focus).Count) cards, $(@($c.corners).Count) corners" ($c.ready -and $c.summary -and [double]$c.summary.onTrackSec -gt 200 -and $c.mode -eq 'partial' -and @($c.corners).Count -ge 3)
Check "  the hint says how much it is worth: $($c.hint)" ($c.hint -match 'No full lap' -and $c.hint -match 'hint')
Check '  no "Not enough laps" refusal anywhere in the reply' (-not ($c.reason -match 'Not enough'))

'6. live: the running irdash (only when the rig is free)'
$busy = Get-RigBusy
$api = 'http://localhost:8199'
$q = [uri]::EscapeDataString($name)
if ($busy) { "  info  live part skipped: $busy" }
else {
  $live = $null; try { $live = Invoke-WebRequest "$api/analysis/raw?id=$q" -UseBasicParsing -TimeoutSec 60 } catch { $live = $_.Exception.Response }
  $code = if ($live -and $live.StatusCode) { [int]$live.StatusCode } else { 0 }
  if ($code -ne 200) { "  info  the running irdash does not answer /analysis/raw yet (HTTP $code): deploy (dash\build.ps1) and run this again for the live part" }
  else {
    $lo = $live.Content | ConvertFrom-Json
    Check "GET /analysis/raw: $($lo.total) s of the drive" ([double]$lo.total -gt 200)
    $cl = Invoke-RestMethod "$api/analysis/coach?id=$q" -TimeoutSec 120
    Check "GET /analysis/coach: ready, mode $($cl.mode), summary there" ($cl.ready -and $cl.summary -and $cl.mode -eq 'partial')
    $ss = Invoke-RestMethod "$api/sessions" -TimeoutSec 60
    $row = @($ss.sessions | Where-Object { $_.file -eq $name })
    Check "GET /sessions lists it ($(@($ss.sessions).Count) sessions, short=$($row[0].short))" ($row.Count -eq 1)
    Add-Type -AssemblyName System.Drawing
    foreach ($pg in @(@("rawdata.html?id=$q", 'raw-viewer-0836.png'), @("rawdata.html?id=$q&from=176&to=200", 'raw-viewer-0836-zoom.png'), @("coach.html?id=$q", 'raw-coach-0836.png'), @("workbench.html?id=$q&lap=1&ref=pb", 'raw-workbench-lap1.png'))) {
      $out = Join-Path $PSScriptRoot "shots\$($pg[1])"
      $null = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot.ps1') -Url "$api/v2/$($pg[0])" -Out $out -Wait 12000
      $ok = Test-Path $out; $lit = 0
      if ($ok) { $bmp = [Drawing.Bitmap]::FromFile($out); for ($y = 100; $y -lt 1000; $y += 40) { for ($x = 60; $x -lt 1860; $x += 40) { $px = $bmp.GetPixel($x, $y); if ($px.R + $px.G + $px.B -gt 200) { $lit++ } } }; $bmp.Dispose() }
      Check "picture tests\shots\$($pg[1]) has a drawn page ($lit bright sample points)" ($ok -and $lit -gt 8)   # a trace page is mostly black with thin lines: 11-26 bright samples is a drawn page (looked at: tests\shots\raw-viewer-0836.png)
    }
  }
}

"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
