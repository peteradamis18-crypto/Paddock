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
  $h = (Get-Content (Join-Path $tools 'blackbox-harness.cs') -Raw).Replace('//IBTREPLAY//', $cs.Substring($i0, $i1 - $i0))
  $hs = Join-Path $tmp 'harness.cs'; [IO.File]::WriteAllText($hs, $h)
  $out = & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -nologo "-out:$tmp\bb.exe" $hs (Join-Path $root 'dash\src\blackbox.cs') 2>&1
  ok 'blackbox.cs compiles on its own with C# 5 (only Log from irdash)' ($LASTEXITCODE -eq 0) (($out | Where-Object { $_ -match 'error' }) -join ' | ')

  # ---------------------------------------------------------------- 3. rows, fast mode, size, cost
  Assert-RigFree -Where '3. rate'
  'Section 3. 45 s of the race at real speed, a synthetic 30 % drop at 20 s'
  $d3 = Join-Path $tmp 'rate'; New-Item -ItemType Directory -Force $d3 | Out-Null
  $o = & "$tmp\bb.exe" rate $race 30 45 20 $d3
  $o | Where-Object { $_ -match '^(ROWS|COST|STATUS|DROP)' } | ForEach-Object { "    $_" }
  $files = @(Get-ChildItem $d3 -Filter *.tsv)
  ok 'one file, named after the start (yyyyMMdd-HHmmss.tsv)' ($files.Count -eq 1 -and $files[0].Name -match '^\d{8}-\d{6}\.tsv$') ($files.Name -join ',')
  $lines = Get-Content $files[0].FullName
  ok 'the file starts with the row header and the snapshot header' ($lines[0] -like '# t*sessTime*gpuThrottle' -and $lines[1] -like '# snapshot*')
  $rows = @($lines | Where-Object { $_ -and $_[0] -ne '#' -and $_ -notlike 'snapshot*' })
  $snaps = @($lines | Where-Object { $_ -like 'snapshot*' })
  $bad = @($rows | Where-Object { ($_ -split "`t").Count -ne 24 })
  ok "every row has the 24 columns ($($rows.Count) rows)" ($rows.Count -gt 0 -and $bad.Count -eq 0) "$($bad.Count) bad, first: $($bad[0])"
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
  ok 'the NVML columns are there and empty (wave 5)' (@($rows | Where-Object { $c = $_ -split "`t"; ($c[20] + $c[21] + $c[22] + $c[23]) -ne '' }).Count -eq 0)
  ok ("rows stop when the sim stops (last row {0:N2} s after)" -f ($t[-1] - $stopAt)) (($t[-1] - $stopAt) -le 1.2 -and ($o -match 'LOG black box: stopped').Count -eq 1)
  # size: 1-second rows for 20 minutes, plus one dip like this one; and the whole run scaled as if a dip came every 45 s
  $slow = @($rows | Where-Object { $true }) ; $len1 = ($rows | Select-Object -First 15 | ForEach-Object { [Text.Encoding]::UTF8.GetByteCount($_) + 2 } | Measure-Object -Average).Average
  $mb20 = ($len1 * 1200 + $files[0].Length) / 1MB
  $wall = $t[-1] - $t[0]; $mbWorst = $files[0].Length / $wall * 1200 / 1MB
  ok ("a 20-minute race stays under 5 MB: {0:N2} MB (rows of {1:N0} bytes), {2:N2} MB even with a dip every 45 s" -f $mb20, $len1, $mbWorst) ($mb20 -lt 5 -and $mbWorst -lt 5)
  $cost = Num ((($o | Where-Object { $_ -like 'COST *' }) -split ' ')[1]); $costN = Num ((($o | Where-Object { $_ -like 'COSTNORMAL*' }) -split ' ')[1])
  "    SAMPLER COST: {0:N3} % of one core at 1 row a second (programs looked at every 5 s by the black box itself), {1:N3} % over the whole run with the fast mode" -f $costN, $cost
  ok ("the black box costs under 1 % of one core ({0:N3} % at 1/s, {1:N3} % with a fast mode)" -f $costN, $cost) ($costN -lt 1 -and $cost -lt 1)

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
}
catch { $script:fail++; "  FAIL stopped: $($_.Exception.Message)" }
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
"blackbox-test: $script:pass ok, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
