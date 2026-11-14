# fuel-test.ps1 (W2-1) - the race screen's fuel maths (dash\src\fuel.cs): burn from the last 3 clean laps (5 for the long view), laps to
# go, fuel to the end with the 5 % margin, the pit-window colours, the "save x L/lap" hint, measuring before 3 laps, caution / pit /
# off-track laps out, the reset after a stop, and three laps of the 12 Nov Road Atlanta race worked out by hand from the file.
# OFFLINE: compiles fuel.cs + lapstore.cs + ibtfile.cs with tests\fuel-main.cs (the cuts-test pattern). Only READS the old 12 Nov .ibt.
# No irdash, no rig, no window. Safe while Peter races.
#   powershell -ExecutionPolicy Bypass -File tests\fuel-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP "fuel-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$race = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt'
# a real lap-limited session (13 Nov Lone Qualify, 2 laps): what SessionLapsRemainEx counts. Both 13 Nov races were 15-minute timed races.
$lapSession = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-13 16-19-00.ibt'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
try {
  'Section 0. build'
  $out = & $csc /nologo /target:exe "/out:$tmp\fuel-main.exe" /r:System.dll /r:System.Core.dll `
    (Join-Path $root 'dash\src\fuel.cs') (Join-Path $root 'dash\src\lapstore.cs') (Join-Path $root 'dash\src\ibtfile.cs') (Join-Path $PSScriptRoot 'fuel-main.cs') 2>&1
  Check 'fuel.cs compiles on its own with the lap judge (C# 5, Windows csc)' ((Test-Path "$tmp\fuel-main.exe") -and -not ($out | Where-Object { $_ -match 'error' }))
  if (Test-Path "$tmp\fuel-main.exe") {
    Assert-RigFree -Where 'fuel rules'
    $p = New-Object Diagnostics.ProcessStartInfo "$tmp\fuel-main.exe"
    $p.Arguments = '"' + $race + '" "' + $lapSession + '"'; $p.UseShellExecute = $false; $p.RedirectStandardOutput = $true; $p.CreateNoWindow = $true
    $pr = [Diagnostics.Process]::Start($p); try { $pr.PriorityClass = 'BelowNormal'; $pr.ProcessorAffinity = [IntPtr]3 } catch { }
    $lines = $pr.StandardOutput.ReadToEnd() -split "`r?`n"; $pr.WaitForExit()
    foreach ($l in $lines) {
      if ($l -match '^\s+ok\s') { $script:pass++; $l } elseif ($l -match '^\s+FAIL\s') { $script:fail++; $l } elseif ($l -match '\S' -and $l -notmatch 'passed, .* failed') { $l }
    }
    Check 'the test main ran to the end' (($lines | Where-Object { $_ -match 'passed, .* failed' }).Count -eq 1)
  } else { $out }
  $b = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))
  Check 'fuel.cs and sdkreader.cs are in dash\build.ps1' ($b -match 'src\\fuel\.cs' -and $b -match 'src\\sdkreader\.cs')
  $fs = [IO.File]::ReadAllText((Join-Path $root 'dash\src\fuel.cs'))
  Check 'fuel.cs stays C# 5 (no $", ?., nameof, out var)' (-not ($fs -match '(^|[\s(=,+])\$"|\?\.[A-Za-z]|nameof\(|out var '))
  Check 'fuel.cs is pure (no File, no Thread, no DateTime.Now, no Sdk)' (-not ($fs -match 'File\.|Thread\.|DateTime\.Now|Sdk\.'))
  Check 'the W2-3 hook is there: Func<string, double?> Fuel.PitLossFor' ($fs -match 'public static Func<string, double\?> PitLossFor;')
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
''; "$pass ok, $fail FAIL"
if ($fail -gt 0) { exit 1 }
