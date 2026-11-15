# placerule-test.ps1 - offline: ONE start and finish place for REVIEW and the YouTube pack (W1-12, dash\src\placerule.cs).
# The 2026-11-14 21:27 Road Atlanta race's real field log and real .ibt session info (tests\fixtures) go through REVIEW's path
# (Debrief.RaceStory + PlaceRule.Apply, as review.cs does) and the pack's path (Pack.Story); both must say P6 -> P4. A made-up grid
# of P7 proves the rule (the grid beats the first crossing) in both paths. Nothing touches irdash, the sim or any app.
#   powershell -ExecutionPolicy Bypass -File tests\placerule-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tmp = Join-Path $env:TEMP ('placerule-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$buildList = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
$srcs = @([regex]::Matches($buildList, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) }) +
        @([regex]::Matches($buildList, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) }) +
        @(Join-Path $PSScriptRoot 'placerule-main.cs')
$harness = Join-Path $tmp 'placerule-harness.exe'
'W1-12 one start and finish place'
try {
  Assert-RigFree -Where '1. compile'
  'Section 1. the harness'
  $cout = & $csc /nologo /target:exe /platform:anycpu /main:IRDash.PlaceRuleMain "/out:$harness" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.Security.dll @srcs 2>&1 | Out-String
  ok 'the harness compiles' (Test-Path $harness) $cout
  if (-not (Test-Path $harness)) { throw 'no harness' }
  Assert-RigFree -Where '2. cases'
  'Section 2. the 21:27 race'
  $p = Start-Process $harness -ArgumentList ('"' + (Join-Path $PSScriptRoot 'fixtures\f20261114-212650-2.json') + '" "' + (Join-Path $PSScriptRoot 'fixtures\race-14nov-sessioninfo.yaml') + '" "' + $tmp + '\work"') -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt"
  if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { }; ok 'the harness finished within 2 minutes' $false }
  $lines = @(Get-Content "$tmp\out.txt" -Encoding UTF8 -ErrorAction SilentlyContinue)
  foreach ($l in $lines) { if ($l -match '^ok (.*)') { ok $Matches[1] $true } elseif ($l -match '^FAIL (.*)') { ok $Matches[1] $false } }
  ok 'the harness ran to the end' ($lines -contains 'DONE') ((Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) + '')
  'Section 3. source'
  $rev = Get-Content (Join-Path $root 'dash\src\review.cs') -Raw; $hl = Get-Content (Join-Path $root 'dash\src\highlights.cs') -Raw; $pr = Get-Content (Join-Path $root 'dash\src\placerule.cs') -Raw
  ok 'review.cs and highlights.cs both use PlaceRule' ($rev -match 'PlaceRule\.Apply' -and $hl -match 'PlaceRule\.Start' -and $hl -match 'PlaceRule\.Finish')
  ok 'placerule.cs is C# 5 and in dash\build.ps1' ((-not ($pr -match '(^|[\s(=,+:])\$"|\?\.[A-Za-z]|\bnameof\(|out var ')) -and $buildList -match 'src\\placerule\.cs')
} catch { ok 'the test ran without an exception' $false $_.Exception.Message }
finally { try { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
"$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
