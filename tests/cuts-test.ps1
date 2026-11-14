# cuts-test.ps1 (W1-3) - the trim plan, chapters, five title templates, description and ffmpeg cut (dash\src\cuts.cs).
# OFFLINE: compiles cuts.cs + proc.cs with tests\cuts-main.cs; the "ffmpeg"/"ffprobe" are tiny .cmd files. No irdash, no rig, no real video.
#   powershell -ExecutionPolicy Bypass -File tests\cuts-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP "cuts-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
try {
  '0. build'
  $out = & $csc /nologo /target:exe "/out:$tmp\cuts-main.exe" /r:System.dll /r:System.Core.dll /r:System.Web.Extensions.dll `
    (Join-Path $root 'dash\src\cuts.cs') (Join-Path $root 'dash\src\proc.cs') (Join-Path $PSScriptRoot 'cuts-main.cs') 2>&1
  Check 'cuts.cs compiles on its own (C# 5, Windows csc)' ((Test-Path "$tmp\cuts-main.exe") -and -not ($out | Where-Object { $_ -match 'error' }))
  if (Test-Path "$tmp\cuts-main.exe") {
    Assert-RigFree -Where 'cuts rules'
    & "$tmp\cuts-main.exe" "$tmp\run" (Join-Path $PSScriptRoot 'fixtures\cuts-road-atlanta.json') | Out-File "$tmp\out.txt" -Encoding utf8
    foreach ($l in (Get-Content "$tmp\out.txt" -Encoding utf8)) {
      if ($l -match '^\s+ok\s') { $script:pass++; $l } elseif ($l -match '^\s+FAIL\s') { $script:fail++; $l } elseif ($l -notmatch 'passed, .* failed') { $l }
    }
  } else { $out }
  $b = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))
  Check 'cuts.cs is in dash\build.ps1' ($b -match 'src\\cuts\.cs')
  Check 'cuts.cs stays C# 5 (no $", ?., nameof, out var)' (-not ([IO.File]::ReadAllText((Join-Path $root 'dash\src\cuts.cs')) -match '\$"|\?\.[A-Za-z]|nameof\(|out var '))
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
''; "$pass ok, $fail FAIL"
if ($fail -gt 0) { exit 1 }
