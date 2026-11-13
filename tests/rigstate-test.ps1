# rigstate-test.ps1 (W0-2) - the ONE "is Peter busy?" answer (dash\src\rigstate.cs): the truth table of SimRunning / SessionOn /
# Driving / StartPressed -> Busy and BusyWhy, the test hook's own rule (RealBusyWhy), freshness, the /rig/state JSON, and that the old
# helpers are now forwarders to it. OFFLINE: compiles rigstate.cs alone with a pretend SDK frame, sim process and clock
# (tests\rigstate-unit.cs). Touches no irdash, no sim, no screen. Safe while Peter races.
#   powershell -ExecutionPolicy Bypass -File tests\rigstate-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP "rigstate-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
try {
  '0. build'
  $out = & $csc /nologo /target:exe "/out:$tmp\rigstate-unit.exe" /r:System.dll /r:System.Core.dll /r:System.Web.Extensions.dll (Join-Path $root 'dash\src\rigstate.cs') (Join-Path $PSScriptRoot 'rigstate-unit.cs') 2>&1
  Check 'rigstate.cs compiles on its own (C# 5, Windows csc, only Log from irdash)' ((Test-Path "$tmp\rigstate-unit.exe") -and -not ($out | Where-Object { $_ -match 'error' }))
  if (Test-Path "$tmp\rigstate-unit.exe") {
    $lines = & "$tmp\rigstate-unit.exe" $tmp
    foreach ($l in $lines) {
      if ($l -match '^\s+ok\s') { $script:pass++; $l } elseif ($l -match '^\s+FAIL\s') { $script:fail++; $l } elseif ($l -notmatch 'passed, .* failed') { $l }
    }
  } else { $out }

  ''; '5. everyone asks RigState (source)'
  $src = @{}; foreach ($f in 'irdash', 'official', 'realworld', 'overlays', 'spotterguard', 'doctor', 'vault', 'recorder') { $src[$f] = [IO.File]::ReadAllText((Join-Path $root "dash\src\$f.cs")) }
  $build = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))
  Check 'rigstate.cs and log.cs are in dash\build.ps1' ($build -match 'src\\rigstate\.cs' -and $build -match 'src\\log\.cs')
  Check 'every SDK frame feeds it (Sdk.Publish)' ($src.irdash -match 'RigState\.Feed\(f\.Connected, f\.Connected && f\.Num\("IsOnTrack"\) != 0, fakeUp\)')
  Check 'its prober is started with irdash' ($src.irdash -match 'RigState\.Start\(\);')
  Check 'Program.IsDriving is a one-line forwarder (dozens of callers)' ($src.irdash -match 'public static bool IsDriving \{ get \{ return RigState\.Driving; \} \}')
  Check 'Sdk.RealBusy is a one-line forwarder (more than five callers)' ($src.irdash -match 'public static string RealBusy\(\) \{ return RigState\.RealBusyWhy\(\); \}')
  Check 'CarMoving is gone (overlays asks SessionOn)' ($src.irdash -notmatch 'CarMoving' -and $src.overlays -notmatch 'CarMoving' -and $src.overlays -match 'if \(RigState\.SessionOn\) \{ Jobs\.Run\("overlays apply"')
  Check 'official: no reflection, Busy() is the rig state' ($src.official -notmatch 'GetMethod\("RealBusy"' -and $src.official -match 'static bool Busy\(\) \{ return RigState\.SessionOn; \}')
  Check 'realworld: no reflection' ($src.realworld -notmatch 'GetMethod\("RealBusy"' -and $src.realworld -match 'return Sdk\.RealBusy\(\);')
  Check 'the spotter guard asks the rig state' ($src.spotterguard -match 'RigState\.SimRunning' -and $src.spotterguard -match 'RigState\.SessionOn')
  Check 'irdash.cs has no inline "is the sim running" scan left' ($src.irdash -notmatch 'GetProcessesByName\("iRacingSim64DX11"\)\.Length > 0')
  Check 'the map builder asks once per build, not a scan per .ibt file (W0-3)' ($src.irdash -match 'bool simUp = RigState\.SimRunning;' -and $src.irdash -match 'return simUp && \(DateTime\.Now - fi\.LastWriteTime\)\.TotalMinutes < 30;')
  Check '/rig/state is served, read-only, to any caller' ($src.irdash -match 'path == "/rig/state"\) \{ Send\(s, 200, "application/json", Encoding\.UTF8\.GetBytes\(RigState\.Json\(\)\), "Access-Control-Allow-Origin: \*\\r\\n"\)')
  $rs = [IO.File]::ReadAllText((Join-Path $root 'dash\src\rigstate.cs'))
  Check 'the sim is watched through a REAL handle (Handle read once when picked), so a reused process id cannot keep SimRunning true' ($rs -match 'IntPtr h = ps\[0\]\.Handle; if \(h != IntPtr\.Zero\) held = ps\[0\];' -and $rs -match 'held != null && !held\.HasExited')
  Check 'one constant for the sim program name' ([IO.File]::ReadAllText((Join-Path $root 'dash\src\rigstate.cs')) -match 'public const string SimProcess = "iRacingSim64DX11";' -and $src.spotterguard -match 'SimName = RigState\.SimProcess')
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
