# After Peter's session: once the sim has been closed for 3 minutes (and no START press in the last 10, via guard.ps1), run the
# owed offline/guarded tests and rebuild irdeck. No installs, no build-deck, no UI clicks. Results -> docs\tasks\log\after-session.log
param([int]$MaxHours = 6)
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
$log = Join-Path $root 'docs\tasks\log\after-session.log'
function L($t) { Add-Content $log "$(Get-Date -Format s) $t" }
$end = (Get-Date).AddHours($MaxHours); $freeSince = $null
while ((Get-Date) -lt $end) {
  $st = (& .\irdeck-cli.exe state | Out-String)
  if ($st -match 'sim=False') { if (-not $freeSince) { $freeSince = Get-Date } } else { $freeSince = $null }
  if ($freeSince -and ((Get-Date) - $freeSince).TotalMinutes -ge 3) {
    L 'sim closed 3 min - running the owed checks'
    # irdeck is NOT rebuilt here: new irdeck code goes live only after its review (the lead runs build-irdeck.ps1)
    foreach ($t in 'deckstate-test', 'keys-test', 'confirm-test', 'airace-test', 'mydrive-test', 'gpsmap-test', 'home-test') {
      if (-not (Test-Path "tests\$t.ps1")) { L "$t : missing"; continue }
      $o = powershell -ExecutionPolicy Bypass -File "tests\$t.ps1" 2>&1 | Out-String
      $sum = ([regex]::Matches($o, '(?m)^.*(passed|SUMMARY|NOT SAFE).*$') | Select-Object -Last 1 | ForEach-Object { $_.Value.Trim() })
      $fails = ([regex]::Matches($o, '(?m)^\s*FAIL\s.*$') | Select-Object -First 5 | ForEach-Object { $_.Value.Trim() }) -join ' || '
      L "$t : $sum $(if ($fails) { '| ' + $fails })"
      if ($o -match 'sim is running|START was pressed') { L 'rig busy again - stopping'; break }
    }
    L 'done'; break
  }
  Start-Sleep 30
}
