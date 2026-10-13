$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$pass = 0; $fail = 0
function Section([string]$name) { Assert-RigFree -Where $name; "SECTION $name" }
function Check([string]$name, [bool]$ok) { if ($ok) { $script:pass++; "  ok    $name" } else { $script:fail++; "  FAIL  $name" } }
function PressConfirm([string]$id) { & (Join-Path $root 'irdeck-cli.exe') confirm $id state | Out-Null }
function ConfirmCount([string]$id) { @(Get-Content (Join-Path $root 'irdeck.log') -ErrorAction SilentlyContinue | Where-Object { $_ -match "confirm ${id}: confirmed" }).Count }
function WaitLog([string]$id, [int]$before, [int]$ms) { $until = (Get-Date).AddMilliseconds($ms); do { if ((ConfirmCount $id) -gt $before) { return $true }; Start-Sleep -Milliseconds 20 } while ((Get-Date) -lt $until); return $false }
$id = 'dk3test'; $armed = Join-Path $root "armed-$id.txt"; $backup = Join-Path $env:TEMP "dk3-armed-$PID.txt"; $had = Test-Path $armed
if ($had) { Copy-Item $armed $backup -Force }
try {
  Section 'Two processes 0.2 seconds apart confirm'
  $n = ConfirmCount $id
  $p = Start-Process -FilePath (Join-Path $root 'irdeck-cli.exe') -ArgumentList @('confirm',$id,'state') -PassThru -WindowStyle Hidden
  $p.WaitForExit(); Start-Sleep -Milliseconds 200; PressConfirm $id
  Check 'fresh arm confirms at 0.2 seconds despite repeat interval' (WaitLog $id $n 2000)

  Section 'Two processes 0.05 seconds apart count as one press'
  Remove-Item $armed -Force -ErrorAction SilentlyContinue; $n = ConfirmCount $id
  # a real bounce: the second copy of the press STARTS 0.05 s after the first (not after the first one's beeps end)
  $p = Start-Process -FilePath (Join-Path $root 'irdeck-cli.exe') -ArgumentList @('confirm',$id,'state') -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 50
  $q = Start-Process -FilePath (Join-Path $root 'irdeck-cli.exe') -ArgumentList @('confirm',$id,'state') -PassThru -WindowStyle Hidden
  $p.WaitForExit(); $q.WaitForExit()
  Start-Sleep -Milliseconds 250
  Check 'bounce does not confirm' ((ConfirmCount $id) -eq $n)
  Check 'bounce leaves a fresh arm' ((Test-Path $armed) -and (([DateTime]::Parse((Get-Content $armed)) - [DateTime]::Now).TotalSeconds -gt 0))

  Section 'Four seconds apart re-arm'
  Remove-Item $armed -Force -ErrorAction SilentlyContinue; PressConfirm $id; Start-Sleep -Seconds 4; $n = ConfirmCount $id; PressConfirm $id
  Check 'expired arm is replaced and not confirmed' ((ConfirmCount $id) -eq $n -and (Test-Path $armed) -and (([DateTime]::Parse((Get-Content $armed)) - [DateTime]::Now).TotalSeconds -gt 0))
}
finally { if ($had) { Copy-Item $backup $armed -Force } else { Remove-Item $armed -Force -ErrorAction SilentlyContinue }; Remove-Item $backup -Force -ErrorAction SilentlyContinue }
"$pass passed, $fail failed"
if ($fail) { exit 1 }
