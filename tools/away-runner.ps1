# Waits until Peter is away (sim closed + 10 min no input, guard.ps1 -NeedAway), then runs the checks that need it:
#   1. recorder-test section 10 - films the real middle screen (capture only: no clicks, keys or focus changes)
#   2. airace survey - reads the AI race wizard via Last Settings, scoped to the modal, never New Race/Continue/Race (DK-1s, reviewed)
# Results -> docs\tasks\log\away-runner.log. The guard is asked in a child process (it EXITS when the rig is not free).
param([int]$MaxHours = 14, [switch]$NoSurvey = $true)
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
$log = Join-Path $root 'docs\tasks\log\away-runner.log'
function L($t) { Add-Content $log "$(Get-Date -Format s) $t" }
function Away { powershell -NoProfile -ExecutionPolicy Bypass -Command ". '$root\tests\guard.ps1'; Assert-RigFree -NeedAway" *> $null; return ($LASTEXITCODE -eq 0) }
$end = (Get-Date).AddHours($MaxHours); L 'waiting for an away window'
while ((Get-Date) -lt $end) {
  if (Away) {
    L 'away window - 1. recorder-test section 10 (real middle screen, capture only)'
    $o = powershell -ExecutionPolicy Bypass -File tests\recorder-test.ps1 -Only 10 2>&1 | Out-String
    ([regex]::Matches($o, '(?m)^\s*(ok|FAIL)\s.*$') | ForEach-Object { L ('  ' + $_.Value.Trim()) })
    L ('summary: ' + (([regex]::Matches($o, '(?m)^.*passed.*$') | Select-Object -Last 1).Value))
    if (Away) { L '1b. airace-live (real AI race start -> in car -> quit, 2 rounds)'; $a = powershell -ExecutionPolicy Bypass -File tests\airace-live.ps1 2>&1 | Out-String; ($a -split "`n" | Where-Object { $_ -match '^\s*(ok|FAIL)|passed|round|airace' } | Select-Object -Last 30 | ForEach-Object { L ('  ' + $_.Trim()) }) }
    if (-not $NoSurvey) {
      if (Away) {
        L '2. airace survey (read-only, modal-scoped)'
        $d = & .\irdeck-cli.exe airace survey 2>&1 | Out-String
        ($d -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 25 | ForEach-Object { L ('  ' + $_.Trim()) })
      } else { L 'survey skipped: Peter came back' }
    }
    L 'done'; break
  }
  Start-Sleep 30
}
