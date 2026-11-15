# blackbox-test.ps1 - offline (W0-9): the black box, fed by the 12 Nov race through W0-8's pretend pump (irdash's real IbtReplay and the real
# dash\src\blackbox.cs, compiled with stand-ins: tests\tools\blackbox-harness.cs). Rows at 1/s, the file size of a 20-minute race, fast mode on a
# synthetic 30 % drop (about 150 rows in 15 s, then back to 1/s), the measured CPU cost, the real lap-9 freeze read back, the 8-week tidy.
# No irdash, no sim, no port; files go to %TEMP% only. The 12 Nov source is only read, to cut the fixtures when they are missing.
#   powershell -ExecutionPolicy Bypass -File tests\blackbox-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tests\tools'; $fx = Join-Path $root 'tests\fixtures'
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$inv = [Globalization.CultureInfo]::InvariantCulture
function Num($s) { [double]::Parse($s, $inv) }

'W0-9 black box'
$source = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt'
$race = Join-Path $fx 'race-12nov.ibt'; $frz = Join-Path $fx 'race-12nov-freeze.ibt'
$tmp = Join-Path $env:TEMP "blackbox-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  # ---------------------------------------------------------------- 1. fixtures
  Assert-RigFree -Where '1. fixtures'
  'Section 1. the 12 Nov fixtures'
  if ((-not (Test-Path $race)) -and (Test-Path $source)) { & (Join-Path $tools 'ibt-cut.ps1') -Source $source -Out $race -From 200 -To 380 | Out-Null }
  # 60 s centred on lap 10 starting: the freeze is the second before the line
  if ((-not (Test-Path $frz)) -and (Test-Path $source)) { & (Join-Path $tools 'ibt-cut.ps1') -Source $source -Out $frz -AroundLap 10 -Seconds 60 | Out-Null }
  ok 'race-12nov.ibt (3 minutes) is here' (Test-Path $race)
  ok 'race-12nov-freeze.ibt (60 s around the lap-9 freeze) is here' (Test-Path $frz)
  if (-not (Test-Path $race)) { throw 'no fixture and no 12 Nov source file on this PC' }

  # ---------------------------------------------------------------- 2. compile
  Assert-RigFree -Where '2. compile'
  'Section 2. compile the real BlackBox and IbtReplay with stand-ins'
  $cs = Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw
  $i0 = $cs.IndexOf('    // ---------------- Telemetry replay'); $i1 = $cs.IndexOf('    // ---------------- iRacing SDK reader')
  ok 'IbtReplay found in irdash.cs' ($i0 -gt 0 -and $i1 -gt $i0)
  # W5-3: the real FieldLaps.ScanFile (bench.cs) and the real BlackBox.Running line (perf.cs WireBlackBox) go in too
  $bench = Get-Content (Join-Path $root 'dash\src\bench.cs') -Raw
  $j0 = $bench.IndexOf('        public static List<FieldRow> ScanFile('); $j1 = $bench.IndexOf('        // ---- live: the end of a session with other drivers')
  ok 'FieldLaps.ScanFile found in bench.cs' ($j0 -gt 0 -and $j1 -gt $j0)
  $scanSrc = $bench.Substring($j0, $j1 - $j0)
  ok 'ScanFile tells the black box first ("field laps: reading a telemetry file")' ($scanSrc -match '^\s+public static List<FieldRow> ScanFile\([^)]*\)\s+\{\s+BlackBox\.Event\("field laps: reading a telemetry file"\);')
  $perfSrc = Get-Content (Join-Path $root 'dash\src\perf.cs') -Raw
  $runLine = [regex]::Match($perfSrc, 'BlackBox\.Running = delegate \{[^}]*\};').Value
  ok "perf.cs wires Running from RigState ($runLine)" ($runLine -match 'RigState\.SimRunning \|\| RigState\.SessionOn' -and $runLine -notmatch 'PerfSampler|Sdk\.')
  $h = (Get-Content (Join-Path $tools 'blackbox-harness.cs') -Raw).Replace('//IBTREPLAY//', $cs.Substring($i0, $i1 - $i0)).Replace('//SCANFILE//', $scanSrc).Replace('//RUNNING//', $runLine)
  $hs = Join-Path $tmp 'harness.cs'; [IO.File]::WriteAllText($hs, $h)
  $out = & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -nologo "-out:$tmp\bb.exe" $hs (Join-Path $root 'dash\src\blackbox.cs') (Join-Path $root 'dash\src\nvml.cs') (Join-Path $root 'dash\src\perfdelta.cs') 2>&1
  ok 'blackbox.cs + nvml.cs + perfdelta.cs compile on their own with C# 5 (only Log from irdash)' ($LASTEXITCODE -eq 0) (($out | Where-Object { $_ -match 'error' }) -join ' | ')

  # ---------------------------------------------------------------- 3. rows, fast mode, size, cost
  Assert-RigFree -Where '3. rate'
  'Section 3. 45 s of the race at real speed, a synthetic 30 % drop at 20 s'
  $d3 = Join-Path $tmp 'rate'; New-Item -ItemType Directory -Force $d3 | Out-Null
  $o = & "$tmp\bb.exe" rate $race 30 45 20 $d3
  $o | Where-Object { $_ -match '^(ROWS|COST|STATUS|DROP)' } | ForEach-Object { "    $_" }
  $files = @(Get-ChildItem $d3 -Filter *.tsv)
  ok 'one file, named after the start (yyyyMMdd-HHmmss.tsv)' ($files.Count -eq 1 -and $files[0].Name -match '^\d{8}-\d{6}\.tsv$') ($files.Name -join ',')
  $lines = Get-Content $files[0].FullName
  ok 'the file starts with the v2 row header and the snapshot header' ($lines[0] -like '#v2 t*sessTime*gpuThrottle*vramMb*vramTotalMb*ramFreeMb*gpuPowerW*diskReadMs' -and $lines[1] -like '# snapshot*') $lines[0]
  $rows = @($lines | Where-Object { $_ -and $_[0] -ne '#' -and $_ -notlike 'snapshot*' })
  $snaps = @($lines | Where-Object { $_ -like 'snapshot*' })
  $bad = @($rows | Where-Object { ($_ -split "`t").Count -ne 29 })
  ok "every row has the 29 columns ($($rows.Count) rows)" ($rows.Count -gt 0 -and $bad.Count -eq 0) "$($bad.Count) bad, first: $($bad[0])"
  $t = @($rows | ForEach-Object { Num (($_ -split "`t")[0]) })
  $drop = Num ((($o | Where-Object { $_ -like 'DROP*' }) -split 'unix ')[1])
  $stopAt = Num ((($o | Where-Object { $_ -like 'STOPAT*' }) -split 'unix ')[1])
  $before = @(); for ($i = 1; $i -lt $t.Count; $i++) { if ($t[$i] -lt $drop) { $before += ($t[$i] - $t[$i - 1]) } }
  $mean = ($before | Measure-Object -Average).Average
  $within = @($before | Where-Object { [math]::Abs($_ - 1) -le 0.1 }).Count
  ok ("before the drop: one row a second (mean gap {0:N3} s over {1} gaps, {2} within 0.1 s)" -f $mean, $before.Count, $within) ($before.Count -ge 15 -and [math]::Abs($mean - 1) -le 0.1 -and $within -ge $before.Count - 1)
  $fastIdx = @(); for ($i = 1; $i -lt $t.Count; $i++) { if ($t[$i] - $t[$i - 1] -lt 0.5) { $fastIdx += $i } }
  $fastN = $fastIdx.Count + 1
  $fastStart = if ($fastIdx.Count) { $t[$fastIdx[0] - 1] } else { 0 }; $fastEnd = if ($fastIdx.Count) { $t[$fastIdx[-1]] } else { 0 }
  ok ("fast mode starts at the drop ({0:N2} s after it)" -f ($fastStart - $drop)) ($fastIdx.Count -gt 0 -and ($fastStart - $drop) -ge -0.1 -and ($fastStart - $drop) -le 1.5)
  ok ("fast mode writes about 150 rows in 15 s ({0} rows over {1:N2} s)" -f $fastN, ($fastEnd - $fastStart)) ($fastN -ge 135 -and $fastN -le 160 -and ($fastEnd - $fastStart) -ge 14 -and ($fastEnd - $fastStart) -le 16)
  $after = @(); for ($i = 1; $i -lt $t.Count; $i++) { if ($t[$i - 1] -ge $fastEnd) { $after += ($t[$i] - $t[$i - 1]) } }
  $mA = if ($after.Count) { ($after | Measure-Object -Average).Average } else { 0 }
  ok ("then back to one row a second ({0} gaps, mean {1:N3} s), no second trigger: the 5 s average follows the new level" -f $after.Count, $mA) ($after.Count -ge 5 -and [math]::Abs($mA - 1) -le 0.1)
  ok "one snapshot line, one second into the dip, with the busiest programs ($($snaps.Count))" ($snaps.Count -eq 1 -and ((Num (($snaps[0] -split "`t")[1])) - $drop) -le 2.5 -and ($snaps[0] -split "`t")[9] -match '=') "$($snaps[0])"
  ok 'the drop is written into the events column' (@($rows | Where-Object { ($_ -split "`t")[19] -like 'frame rate drop*' }).Count -eq 1)
  ok 'the SDK numbers are in the rows (lap, lap position, speed, fps, CPU, GPU)' (@($rows | Where-Object { $c = $_ -split "`t"; $c[2] -ne '' -and $c[3] -ne '' -and (Num $c[5]) -gt 50 -and $c[6] -ne '' -and $c[8] -ne '' }).Count -ge $rows.Count - 2)
  ok 'total CPU and the 3 busiest programs are in the rows' (@($rows | Where-Object { $c = $_ -split "`t"; $c[10] -ne '' -and $c[11] -ne '' }).Count -ge $rows.Count - 6)
  $dq = @($rows | Where-Object { ($_ -split "`t")[17] -ne '' }).Count
  ok "disk queue and write time of the drive are in the rows ($dq of $($rows.Count))" ($dq -ge $rows.Count - 2)
  if (Test-Path 'C:\Windows\System32\nvml.dll') {
    $nv = @($rows | Where-Object { $c = $_ -split "`t"; $c[20] -ne '' -and (Num $c[21]) -gt 0 -and (Num $c[22]) -ge 15 -and (Num $c[22]) -le 100 -and (Num $c[24]) -le (Num $c[25]) -and (Num $c[25]) -gt 0 -and (Num $c[27]) -gt 0 })
    ok "the NVML columns are filled (load, clock, temperature, graphics memory used / total, power: $($nv.Count) of $($rows.Count))" ($nv.Count -ge $rows.Count - 2)
    "    ROW SAMPLE (gpuLoad gpuClock gpuTemp gpuThrottle vramMb vramTotalMb ramFreeMb gpuPowerW diskReadMs): " + ((($rows[5] -split "`t")[20..28]) -join ' | ')
  } else { '  skip no nvml.dll on this PC: the NVML columns stay empty' }
  $ramRd = @($rows | Where-Object { $c = $_ -split "`t"; $c[26] -ne '' -and (Num $c[26]) -gt 0 -and $c[28] -ne '' })
  ok "free RAM and the disk read time are in the rows ($($ramRd.Count) of $($rows.Count))" ($ramRd.Count -ge $rows.Count - 2)
  $thr = @($rows | ForEach-Object { ($_ -split "`t")[23] } | Where-Object { $_ -ne '' -and $_ -notin 'thermal', 'power', 'hw' })
  ok 'the throttle column holds only the short words (thermal / power / hw / empty)' ($thr.Count -eq 0) ($thr -join ',')
  ok ("rows stop when the sim stops (last row {0:N2} s after)" -f ($t[-1] - $stopAt)) (($t[-1] - $stopAt) -le 1.2 -and ($o -match 'LOG black box: stopped').Count -eq 1)
  # size: 1-second rows for 20 minutes, plus one dip like this one; and the whole run scaled as if a dip came every 45 s
  $slow = @($rows | Where-Object { $true }) ; $len1 = ($rows | Select-Object -First 15 | ForEach-Object { [Text.Encoding]::UTF8.GetByteCount($_) + 2 } | Measure-Object -Average).Average
  $mb20 = ($len1 * 1200 + $files[0].Length) / 1MB
  $wall = $t[-1] - $t[0]; $mbWorst = $files[0].Length / $wall * 1200 / 1MB
  ok ("a 20-minute race stays under 5 MB: {0:N2} MB (rows of {1:N0} bytes), {2:N2} MB even with a dip every 45 s" -f $mb20, $len1, $mbWorst) ($mb20 -lt 5 -and $mbWorst -lt 5)
  $cost = Num ((($o | Where-Object { $_ -like 'COST *' }) -split ' ')[1]); $costN = Num ((($o | Where-Object { $_ -like 'COSTNORMAL*' }) -split ' ')[1])
  "    SAMPLER COST: {0:N3} % of one core at 1 row a second (programs looked at every 5 s by the black box itself), {1:N3} % over the whole run with the fast mode" -f $costN, $cost
  ok ("the black box costs under 1 % of one core with NVML on ({0:N3} % at 1/s, {1:N3} % with a fast mode)" -f $costN, $cost) ($costN -lt 1 -and $cost -lt 1)

  # ---------------------------------------------------------------- 4. the real freeze
  Assert-RigFree -Where '4. freeze'
  'Section 4. the real lap-9 freeze replayed, read back as one sentence'
  # Only the harness itself counts as a program here, so the cause is fixed: on 12 Nov GPU and CPU went over 300 % together (a stalled
  # frame, not the card), no Paddock work and no page-fault storm -> "inside the sim". Run twice: the black box looking at the programs
  # itself, and as in irdash (programs handed over every 5 s, its own looks only during the dip).
  if (Test-Path $frz) {
    foreach ($mode in 'self', 'fed') {
      $d4 = Join-Path $tmp "freeze-$mode"; New-Item -ItemType Directory -Force $d4 | Out-Null
      $o4 = & "$tmp\bb.exe" freeze $frz 12 44 $d4 $mode
      $o4 | Where-Object { $_ -match '^(ROWS|FREEZE|SNAPPROGS)' } | ForEach-Object { "    [$mode] $_" }
      $fz = @($o4 | Where-Object { $_ -like 'FREEZE*' })
      ok "[$mode] the real drop (112 to 67 fps) switched fast mode on and wrote a snapshot" (($o4 -match '^ROWS \d+ FAST [1-9]\d* SNAPS [1-9]').Count -eq 1) (($o4 | Where-Object { $_ -like 'ROWS*' }) -join '')
      $snap = @($o4 | Where-Object { $_ -like 'SNAPPROGS*' })
      $nows = @(foreach ($sp in $snap) { foreach ($e in (($sp -replace '^SNAPPROGS ?', '') -split ';' | Where-Object { $_ })) { Num (($e -split '=')[1] -split '/')[0] } })
      $maxNow = if ($nows.Count) { ($nows | Measure-Object -Maximum).Maximum } else { 0 }
      ok ("[$mode] the snapshot's CPU figures are measured over a whole second (largest {0:N1} % of a core, a few-ms window reads 15-100 %)" -f $maxNow) ($snap.Count -ge 1 -and $maxNow -lt 10) ($snap -join ' / ')
      ok "[$mode] one freeze found in the file" ($fz.Count -eq 1) ($fz -join ' / ')
      if ($fz.Count -ge 1) {
        $sent = ($fz[0] -split ' \| ')[1]
        "    [$mode] BLACK BOX SENTENCE: $sent"
        ok "[$mode] it says lap 9, start/finish, and the cause is inside the sim (the stalled frame is not blamed on the card or a program)" ($sent -match '^Lap 9, start/finish: the picture froze for \d+ s \(worst second (2\d|3\d)\.\d fps\)\. Likely cause: inside the sim \(likely a graphics hitch\)\.$') $sent
      }
    }
  } else { '  skip the freeze fixture: no 12 Nov source on this PC' }

  # ---------------------------------------------------------------- 5. the 8-week tidy
  Assert-RigFree -Where '5. prune'
  'Section 5. the 8-week tidy on a temp folder'
  $d5 = Join-Path $tmp 'prune'; New-Item -ItemType Directory -Force (Join-Path $d5 'test') | Out-Null
  $old = (Get-Date).AddDays(-60).ToString('yyyyMMdd-HHmmss'); $new = (Get-Date).AddDays(-10).ToString('yyyyMMdd-HHmmss'); $edge = (Get-Date).AddDays(-55).ToString('yyyyMMdd-HHmmss')
  foreach ($n in "$old.tsv", "$new.tsv", "$edge.tsv", "test\$old.tsv", 'odd-name.tsv', 'keep-me.txt') { Set-Content (Join-Path $d5 $n) 'x' }
  (Get-Item (Join-Path $d5 'odd-name.tsv')).LastWriteTime = (Get-Date).AddDays(-70)
  (Get-Item (Join-Path $d5 "$new.tsv")).LastWriteTime = (Get-Date).AddDays(-90)     # the name's date counts, not the file time
  $p = & "$tmp\bb.exe" prune $d5 56
  $left = @(Get-ChildItem $d5 -Recurse -File | ForEach-Object { $_.FullName.Substring($d5.Length + 1) })
  ok "files older than 8 weeks are removed, newer ones kept ($p; left: $($left -join ', '))" ($p -eq 'PRUNED 3' -and $left.Count -eq 3 -and ($left -contains "$new.tsv") -and ($left -contains "$edge.tsv") -and ($left -contains 'keep-me.txt'))

  # ---------------------------------------------------------------- 6. the v2 cause rules (W5-3)
  Assert-RigFree -Where '6. v2 causes'
  'Section 6. the new cause rules on synthetic freezes (v2 files), and v1 files still read'
  $d6 = Join-Path $tmp 'causes'
  $o6 = & "$tmp\bb.exe" causes $d6
  $cz = @{}; foreach ($l in $o6) { if ($l -match '^CAUSE (\S+) \| (.*)$') { $cz[$Matches[1]] = $Matches[2]; "    $l" } }
  $head = '^On track|^Lap 5, 50 % round the lap: the picture froze for 4 s \(worst second 30\.0 fps\)\. '
  ok 'throttle "thermal" at 83 C in the dip -> the graphics card slowed itself down, with the temperature' ($cz['thermal'] -match ($head.Split('|')[1] + 'Likely cause: the graphics card slowed itself down \(83 .C, thermal\)\.$')) $cz['thermal']
  ok 'throttle "power" -> power limit' ($cz['power'] -match 'Likely cause: the graphics card slowed itself down \(76 .C, power limit\)\.$') $cz['power']
  ok 'disk reads of 120 ms in the dip -> the disk' ($cz['disk'] -match 'Likely cause: the disk \(reads took 120 ms\)\.$') $cz['disk']
  ok 'graphics memory 97 % full in the dip -> graphics memory full (N of M GB)' ($cz['vram'] -match 'Likely cause: graphics memory full \(15\.5 of 16 GB\)\.$') $cz['vram']
  ok 'a throttle only in the seconds before the dip is not the cause' ($cz['throttlebefore'] -match 'Likely cause: inside the sim') $cz['throttlebefore']
  ok 'a slow disk read only before the dip is not the cause' ($cz['diskbefore'] -match 'Likely cause: inside the sim') $cz['diskbefore']
  ok 'nothing unusual in v2 columns -> inside the sim' ($cz['quiet'] -match 'Likely cause: inside the sim \(likely a graphics hitch\)\.$') $cz['quiet']
  ok 'a field-laps read just before the dip counts as Paddock' ($cz['fieldlaps'] -match 'Likely cause: Paddock \(field laps: reading a telemetry file\)\.$') $cz['fieldlaps']
  ok 'a v1 file (# t header, 24 columns) still reads: the freeze and its cause' ($cz['v1'] -match 'froze for 4 s.*Likely cause: inside the sim') $cz['v1']
  ok 'a v1 file with only 20 columns still reads' ($cz['v1short'] -match 'froze for 4 s.*Likely cause: inside the sim') $cz['v1short']
  $long = @($cz.Values | ForEach-Object { ($_ -split 'Likely cause: ')[1] } | Where-Object { $_ -and $_.Length -ge 70 })
  ok 'every cause is one clause under 70 characters' ($long.Count -eq 0) ($long -join ' / ')

  # ---------------------------------------------------------------- 7. the field-laps event (W5-3)
  Assert-RigFree -Where '7. field laps'
  'Section 7. the field-laps reader on a fixture while a pretend session records'
  $d7 = Join-Path $tmp 'field'; New-Item -ItemType Directory -Force $d7 | Out-Null
  $o7 = & "$tmp\bb.exe" fieldlaps $race $d7
  $ev = @($o7 | Where-Object { $_ -like 'EVENT *' })
  "    $($ev -join ' / ')"
  ok 'the "field laps" event is in the events column once' (@($ev | Where-Object { $_ -match 'field laps: reading a telemetry file' }).Count -eq 1) ($o7 -join ' / ')

  # ---------------------------------------------------------------- 8. Running follows RigState (W5-3)
  Assert-RigFree -Where '8. rig state'
  'Section 8. BlackBox.Running as perf.cs wires it, on a pretend RigState'
  $d8 = Join-Path $tmp 'rig'; New-Item -ItemType Directory -Force $d8 | Out-Null
  $o8 = & "$tmp\bb.exe" rig $d8
  $rl = @($o8 | Where-Object { $_ -like 'RIG *' }); "    $rl"
  ok 'off, on with the sim program, off, on with a session, off; one file each time' ($rl.Count -eq 1 -and $rl[0] -eq 'RIG off on off on off FILES 2') ($o8 -join ' / ')

  # ---------------------------------------------------------------- 9. the Coach Dave Delta comparison (W5-3)
  Assert-RigFree -Where '9. delta'
  'Section 9. the Delta comparison from fixture reports'
  $o9 = @(& "$tmp\bb.exe" delta | Where-Object { $_ -like 'DELTA *' } | ForEach-Object { $_.Substring(6) })
  $o9 | ForEach-Object { "    $_" }
  if ($o9.Count -eq 3) {
    $j1 = $o9[0] | ConvertFrom-Json; $j2 = $o9[1] | ConvertFrom-Json; $j3 = $o9[2] | ConvertFrom-Json
    ok 'the object has with / without / say' ($null -ne $j1.with -and $null -ne $j1.without -and $j1.say)
    ok '2 with, 2 without: races, avg, worst, freezes' ($j1.with.races -eq 2 -and $j1.with.avg -eq 104 -and $j1.with.worst -eq 23.7 -and $j1.with.freezes -eq 1 -and $j1.without.races -eq 2 -and $j1.without.avg -eq 109 -and $j1.without.worst -eq 71 -and $j1.without.freezes -eq 0) $o9[0]
    ok "the sentence: $($j1.say)" ($j1.say -eq 'With Coach Dave Delta: avg 104 fps, worst 23.7, 1 freeze in 2 races. Without: avg 109, worst 71, none in 2.')
    ok "1 with, 2 without: not enough ($($j2.say))" ($j2.say -eq 'Not enough races yet to compare Coach Dave Delta on and off (1 with, 2 without).' -and $j2.with.races -eq 1)
    ok "the program name forms (Coach Dave Delta, CoachDave...) all count; plural freezes ($($j3.say))" ($j3.say -eq 'With Coach Dave Delta: avg 100 fps, worst 20, 3 freezes in 3 races. Without: avg 111, worst 80, 1 freeze in 2.')
  } else { ok 'the harness printed three delta objects' $false ($o9 -join ' / ') }
}
catch { $script:fail++; "  FAIL stopped: $($_.Exception.Message)" }
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
"blackbox-test: $script:pass ok, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
