# Proves a failing Check inside a function that returns a value still shows up.
# The old Check wrote to the success stream, so Out-Null or an assignment ate the FAIL line
# while the script's own counter and exit code still said it failed.
#   powershell -ExecutionPolicy Bypass -File tests\harness-check-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Section($title) { Assert-RigFree -Where $title; Write-Host $title }

'Harness check test'
Section '1. a failure inside a returning function still shows'
$child = Join-Path $env:TEMP 'paddock-c24-hidden.ps1'
$out = Join-Path $env:TEMP 'paddock-c24-hidden.txt'
@'
$pass = 0; $fail = 0
function Check($what, $ok) {
  if ($ok) { $script:pass++; Write-Host "  ok    $what" }
  else { $script:fail++; Write-Host "  FAIL  $what" }
}
function Returns {
  Check "a failure inside a returning function" $false
  return "value"
}
$null = Returns | Out-Null
"0 passed, 1 failed"
if ($fail -gt 0) { exit 1 }
'@ | Set-Content -Encoding ASCII $child
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $child *> $out
$rc = $LASTEXITCODE
$text = @(Get-Content $out -ErrorAction SilentlyContinue)
Check 'the FAIL line is in the captured output' (@($text | Where-Object { $_ -match 'FAIL\s+a failure inside a returning function' }).Count -eq 1)
Check 'the return value was swallowed, not the FAIL line' (@($text | Where-Object { $_ -eq 'value' }).Count -eq 0)
Check 'the child says 1 failed and exits non-zero' ($rc -ne 0 -and @($text | Where-Object { $_ -match '0 passed, 1 failed' }).Count -eq 1)
Remove-Item $child, $out -Force -ErrorAction SilentlyContinue

Section '2. run-all counts a non-zero exit, and trusts the summary line'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-all.ps1') -SelfTest
Check 'run-all -SelfTest passed' ($LASTEXITCODE -eq 0)

''
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
