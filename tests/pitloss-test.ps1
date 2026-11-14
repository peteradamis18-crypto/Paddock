# pitloss-test.ps1 (W2-3) - time lost in the pits, learned per track (dash\src\pitloss.cs).
# OFFLINE: compiles pitloss.cs + log.cs with tests\pitloss-main.cs (a pretend car, 10 Hz). Section 5 feeds one real .ibt of Peter's
# through the module when one has a pit stop (read-only, BelowNormal, only while the sim is off); none = says so and skips.
#   powershell -ExecutionPolicy Bypass -File tests\pitloss-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP "pitloss-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
try {
  '0. build'
  $out = & $csc /nologo /target:exe "/out:$tmp\pitloss-main.exe" /r:System.dll /r:System.Core.dll `
    (Join-Path $root 'dash\src\pitloss.cs') (Join-Path $root 'dash\src\log.cs') (Join-Path $PSScriptRoot 'pitloss-main.cs') 2>&1
  Check 'pitloss.cs compiles on its own (C# 5, Windows csc)' ((Test-Path "$tmp\pitloss-main.exe") -and -not ($out | Where-Object { $_ -match 'error' }))
  if (Test-Path "$tmp\pitloss-main.exe") {
    Assert-RigFree -Where 'pitloss rules'
    '1-4. rules (pretend car)'
    & "$tmp\pitloss-main.exe" "$tmp\run" | Out-File "$tmp\out.txt" -Encoding utf8
    foreach ($l in (Get-Content "$tmp\out.txt" -Encoding utf8)) {
      if ($l -match '^\s+ok\s') { $script:pass++; $l } elseif ($l -match '^\s+FAIL\s') { $script:fail++; $l } elseif ($l -notmatch 'passed, .* failed') { $l }
    }
  } else { $out }
  '5. a real .ibt of Peter (read-only, BelowNormal, only while the sim is off)'
  $tele = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry'
  $real = if (Test-Path $tele) { Get-ChildItem $tele -Filter '*.ibt' | Where-Object { $_.Name -like 'porsche9922cup_roadamerica*2026-10-13 16-12-08*' } | Select-Object -First 1 } else { $null }
  if ($real) {
    Assert-RigFree -Where 'pitloss real file'
    $o = & $csc /nologo /target:exe "/out:$tmp\pitloss-ibt.exe" /r:System.dll /r:System.Core.dll (Join-Path $root 'dash\src\pitloss.cs') (Join-Path $root 'dash\src\log.cs') (Join-Path $root 'dash\src\ibtfile.cs') (Join-Path $PSScriptRoot 'pitloss-ibt.cs') 2>&1
    Check 'the .ibt scanner compiles' (Test-Path "$tmp\pitloss-ibt.exe")
    if (Test-Path "$tmp\pitloss-ibt.exe") {
      $p = Start-Process "$tmp\pitloss-ibt.exe" -ArgumentList "`"$tmp\realdata`"", "`"$($real.FullName)`"" -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\real.txt"
      try { $p.PriorityClass = 'BelowNormal' } catch {}
      $p.WaitForExit(120000) | Out-Null
      $txt = Get-Content "$tmp\real.txt"; $txt | ForEach-Object { "    $_" }
      Check 'the real file runs through the module (that file has a reset to the pits and no timed stop, so none is measured)' (($txt -join "`n") -match "stops measured 0" -and ($txt -join "`n") -match "total measured: 0")
    }
  } else { '  skip  no real telemetry file with a pit visit found (none of Peter''s files has a timed mid-session stop: only garage exits and resets to the pits)' }
  '6. wiring and style'
  $b = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))
  Check 'pitloss.cs is in dash\build.ps1' ($b -match 'src\\pitloss\.cs')
  Check 'pitloss.cs stays C# 5 (no $", ?., nameof, out var)' (-not ([IO.File]::ReadAllText((Join-Path $root 'dash\src\pitloss.cs')) -match '\$"|\?\.[A-Za-z]|nameof\(|out var '))
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
''; "$pass ok, $fail FAIL"
if ($fail -gt 0) { exit 1 }
