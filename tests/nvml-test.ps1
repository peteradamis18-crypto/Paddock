# nvml-test.ps1 - offline (W5-3): irdash's real NVML reader (dash\src\nvml.cs) compiled on its own with a small driver
# (tests\tools\nvml-driver.cs). On this PC it reads the graphics card once (temperature, clocks, memory, power), measures the cost of a
# look every 100 ms for 10 s, and checks that a missing nvml.dll gives "nothing" (null), logged once, never an error.
# Read only: NVML is asked, nothing on the card is changed. No irdash, no port. On a PC without NVIDIA only the null path is checked.
#   powershell -ExecutionPolicy Bypass -File tests\nvml-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$inv = [Globalization.CultureInfo]::InvariantCulture
function Num($s) { [double]::Parse($s, $inv) }

'W5-3 NVML'
$tmp = Join-Path $env:TEMP "nvml-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  Assert-RigFree -Where '1. compile'
  'Section 1. compile nvml.cs with the driver (C# 5, Windows csc)'
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $out = & $csc -nologo "-out:$tmp\nv.exe" (Join-Path $root 'dash\src\nvml.cs') (Join-Path $root 'tests\tools\nvml-driver.cs') 2>&1
  ok 'nvml.cs compiles on its own (only Log from irdash)' ($LASTEXITCODE -eq 0) (($out | Where-Object { $_ -match 'error' }) -join ' | ')
  $src = Get-Content (Join-Path $root 'dash\src\nvml.cs') -Raw
  ok 'only C:\Windows\System32\nvml.dll is loaded (no library, no other path)' ($src -match [regex]::Escape('@"C:\Windows\System32\nvml.dll"') -and $src -notmatch 'NVSMI' -and $src -notmatch 'DllImport\("nvml')

  $hasDll = Test-Path 'C:\Windows\System32\nvml.dll'
  Assert-RigFree -Where '2. read'
  'Section 2. one look at the card'
  if ($hasDll) {
    $r = & "$tmp\nv.exe" read
    $row = @($r | Where-Object { $_ -like 'ROW *' })
    "    NVML ROW (load % clock MHz memclock MHz temp C vramMb vramTotalMb powerW throttle word): $($row -replace '^ROW ', '')"
    ok 'the card answered' ($row.Count -eq 1) ($r -join ' / ')
    if ($row.Count -eq 1) {
      $v = ($row[0] -split ' ')
      $load = Num $v[1]; $clk = Num $v[2]; $mclk = Num $v[3]; $temp = Num $v[4]; $used = Num $v[5]; $total = Num $v[6]; $pw = Num $v[7]
      ok "temperature 15-100 C ($temp)" ($temp -ge 15 -and $temp -le 100)
      ok "graphics and memory clocks above 0 ($clk / $mclk MHz)" ($clk -gt 0 -and $mclk -gt 0)
      ok "graphics memory used is at most the total ($used of $total MB)" ($used -ge 0 -and $total -gt 0 -and $used -le $total)
      ok "power above 0 ($pw W)" ($pw -gt 0)
      ok "load is a percentage ($load)" ($load -ge 0 -and $load -le 100)
    }
  } else { '  skip no nvml.dll on this PC (no NVIDIA driver): only the null path is checked' }

  Assert-RigFree -Where '3. cost'
  'Section 3. a look every 100 ms for 10 s (the black box fast mode)'
  if ($hasDll) {
    $c = & "$tmp\nv.exe" cost 100 10
    $line = @($c | Where-Object { $_ -like 'COST *' })
    "    $line"
    $pct = if ($line.Count) { Num (($line[0] -split ' ')[1]) } else { 99 }
    $wpct = if ($line.Count -and $line[0] -match 'WALLPCT ([\d.]+)') { Num $Matches[1] } else { 99 }
    ok ("costs under 1 % of one core at BelowNormal ({0:N3} % by the thread clock, at most {1:N3} % by the time spent inside the read)" -f $pct, $wpct) ($pct -lt 1 -and $wpct -lt 1)
    ok 'every look answered (no failures)' ($line.Count -eq 1 -and $line[0] -match 'FAILS 0$' -and $line[0] -match 'READS (9\d|1\d\d)') ($line -join '')
  }

  Assert-RigFree -Where '4. missing dll'
  'Section 4. the dll path pointed at a missing file'
  $m = & "$tmp\nv.exe" missing (Join-Path $tmp 'no-such\nvml.dll')
  $exit = $LASTEXITCODE
  ok 'two reads give null, nothing thrown' ($exit -eq 0 -and ($m -match '^NULL FAILS 2$').Count -eq 1) ($m -join ' / ')
  ok 'the failure is written to the log once (not every row)' (@($m | Where-Object { $_ -like 'LOG nvml:*' }).Count -eq 1) ($m -join ' / ')
}
catch { $script:fail++; "  FAIL stopped: $($_.Exception.Message)" }
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
"nvml-test: $script:pass ok, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
