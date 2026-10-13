# Deploys irdash on request from a normal (non-Codex) context. A Codex job may not restart irdash itself (an irdash started
# there filmed 0 frames, 2026-10-11), so it writes dash\deploy.request and waits for dash\deploy.result.
#   started once by the lead: Start-Process powershell -WindowStyle Hidden -File tools\deploy-broker.ps1
param([int]$MaxHours = 16)
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
Remove-Item Env:\PADDOCK_NO_DEPLOY -ErrorAction SilentlyContinue
$req = Join-Path $root 'dash\deploy.request'; $res = Join-Path $root 'dash\deploy.result'
$log = Join-Path $root 'docs\tasks\log\deploy-broker.log'
$end = (Get-Date).AddHours($MaxHours)
Add-Content $log "$(Get-Date -Format s) broker started"
while ((Get-Date) -lt $end) {
  if (Test-Path $req) {
    $who = (Get-Content $req -Raw -ErrorAction SilentlyContinue); Remove-Item $req -Force -ErrorAction SilentlyContinue
    $out = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') 2>&1 | Out-String
    $code = $LASTEXITCODE
    Set-Content $res ("exit $code`r`n" + $out) -Encoding UTF8
    Add-Content $log "$(Get-Date -Format s) deploy for '$($who.Trim())' -> exit $code"
  }
  Start-Sleep 3
}
Add-Content $log "$(Get-Date -Format s) broker stopped (time limit)"
