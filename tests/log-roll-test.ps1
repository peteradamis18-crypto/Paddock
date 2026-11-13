# log-roll-test.ps1 (W0-2) - irdash.log used to be DELETED at 2 MB (all history gone) and every thread wrote to the disk itself.
# Now Log.W (dash\src\log.cs) queues the line and one background thread writes it; at 2 MB the file rolls to irdash.1.log (keep 3).
# OFFLINE: compiles log.cs alone with tests\log-roll-harness.cs and writes into a temp folder. Touches no irdash.
#   powershell -ExecutionPolicy Bypass -File tests\log-roll-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP "log-roll-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
# every line the harness wrote, from the oldest kept file to the newest
function AllLines($dir) { $l = New-Object Collections.Generic.List[string]; foreach ($f in @('irdash.3.log', 'irdash.2.log', 'irdash.1.log', 'irdash.log')) { $p = Join-Path $dir $f; if (Test-Path $p) { $l.AddRange([IO.File]::ReadAllLines($p)) } }; return $l }
try {
  '0. build'
  $exe = Join-Path $tmp 'roll.exe'
  $out = & $csc /nologo /target:exe "/out:$exe" /r:System.dll /r:System.Windows.Forms.dll (Join-Path $root 'dash\src\log.cs') (Join-Path $PSScriptRoot 'log-roll-harness.cs') 2>&1
  Check 'log.cs compiles on its own' ((Test-Path $exe) -and -not ($out | Where-Object { $_ -match 'error' }))
  if (-not (Test-Path $exe)) { $out; throw 'no build' }

  ''; '1. 3 MB through Log.W from 4 threads at once'
  $d1 = Join-Path $tmp 'a'; New-Item -ItemType Directory -Force $d1 | Out-Null
  Set-Content (Join-Path $d1 'irdash.log') '2026-11-13 08:00:00  an old line from before the test' -Encoding ASCII
  $r = & $exe $d1 3 4
  "  $r"
  Check 'the writer finished' ($LASTEXITCODE -eq 0 -and "$r" -match 'flushed True')
  $main = Get-Item (Join-Path $d1 'irdash.log'); $one = Join-Path $d1 'irdash.1.log'
  Check "irdash.log is small again ($([math]::Round($main.Length / 1MB, 2)) MB, under 2 MB)" ($main.Length -lt 2000000)
  Check 'irdash.1.log exists (the old lines rolled, not deleted)' ((Test-Path $one) -and (Get-Item $one).Length -ge 1900000)
  Check 'the line from before the test is still there (in irdash.1.log)' ((Get-Content $one -TotalCount 1) -match 'an old line from before the test')
  $all = AllLines $d1
  $n = [int](([regex]::Match("$r", 'perThread (\d+)')).Groups[1].Value)
  $byThread = @{}; $bad = 0; $dupes = 0
  foreach ($line in $all) {
    $m = [regex]::Match($line, '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  t(\d) n(\d{6}) x{70}$')
    if (-not $m.Success) { if ($line -notmatch 'an old line') { $bad++ }; continue }
    $t = $m.Groups[1].Value; $i = [int]$m.Groups[2].Value
    if (-not $byThread.ContainsKey($t)) { $byThread[$t] = New-Object Collections.Generic.List[int] }
    $byThread[$t].Add($i)
  }
  $complete = $true; $ordered = $true
  foreach ($t in '0', '1', '2', '3') {
    $l = $byThread[$t]
    if (-not $l -or $l.Count -ne $n) { $complete = $false; continue }
    for ($k = 0; $k -lt $l.Count; $k++) { if ($l[$k] -ne $k) { $ordered = $false; break } }
  }
  Check "nothing lost at the seam: all $($n * 4) lines are there, once each" ($complete)
  Check 'each thread''s lines are in the order it logged them, across the two files' ($ordered)
  Check 'no line is split or mixed with another (every line is whole)' ($bad -eq 0)
  $us = [double](([regex]::Match("$r", 'usPerCall ([\d.]+)')).Groups[1].Value)
  Check "Log.W itself does not wait for the disk ($us microseconds a call)" ($us -lt 50)

  ''; '2. 9 MB: the files go round, three old ones are kept'
  $d2 = Join-Path $tmp 'b'; New-Item -ItemType Directory -Force $d2 | Out-Null
  $r = & $exe $d2 9 2
  Check 'irdash.log, .1, .2 and .3 exist, no .4' ((Test-Path "$d2\irdash.log") -and (Test-Path "$d2\irdash.1.log") -and (Test-Path "$d2\irdash.2.log") -and (Test-Path "$d2\irdash.3.log") -and -not (Test-Path "$d2\irdash.4.log"))
  $sizes = @(Get-ChildItem $d2 -Filter 'irdash*.log' | ForEach-Object { $_.Length })
  Check 'no file is much bigger than 2 MB' (@($sizes | Where-Object { $_ -gt 2100000 }).Count -eq 0)
  $last = (AllLines $d2)[-1]; $lastN = [int](([regex]::Match("$r", 'perThread (\d+)')).Groups[1].Value) - 1
  Check 'the newest line is in irdash.log' ((Get-Content "$d2\irdash.log" -Tail 1) -match ('n' + $lastN.ToString('000000')))

  ''; '3. wired into irdash (source)'
  $ir = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
  Check 'irdash.cs no longer has its own Log (the one in log.cs is used)' ($ir -notmatch 'static class Log' -and $ir -notmatch 'File\.Delete\(FilePath\)')
  Check 'irdash waits for the last lines when it exits' ($ir -match 'Application\.Run\(\);\s+Log\.Flush\(2000\);')
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
