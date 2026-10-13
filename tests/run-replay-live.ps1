# Waits until the rig is free and Peter has been away 10 minutes, then runs the live replay test (a real AI race that is
# spectated) and saves its output. Safe to start while he is still at the PC: it just waits (up to -WaitMinutes).
#   powershell -ExecutionPolicy Bypass -File tests\run-replay-live.ps1
param([int]$WaitMinutes = 180)
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
$mx = New-Object Threading.Mutex($false, 'Local\paddock-run-all'); if (-not $mx.WaitOne(0)) { 'another test run is active - waiting for it'; [void]$mx.WaitOne($WaitMinutes * 60000) }
$until = (Get-Date).AddMinutes($WaitMinutes); $out = Join-Path $PSScriptRoot 'last\replay-live.txt'
New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot 'last') | Out-Null
while ((Get-Date) -lt $until) {
  $lock = Join-Path $root 'dash\deploy.lock'
  $busy = Get-RigBusy
  if (-not $busy -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15) { $busy = 'lock' }
  if (-not $busy -and (Test-Path (Join-Path $root 'dash\test-hook.on'))) { $busy = 'hook' }
  if (-not $busy -and [RigGuard]::IdleMinutes() -ge 10) { break }
  Start-Sleep -Seconds 30
}
if ((Get-Date) -ge $until) { "gave up waiting $(Get-Date -Format HH:mm:ss)" | Set-Content $out; exit 3 }
"live run started $(Get-Date -Format HH:mm:ss)" | Set-Content $out
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'replay-test.ps1') -Live *>> $out
"live run finished $(Get-Date -Format HH:mm:ss) exit $LASTEXITCODE" | Add-Content $out
