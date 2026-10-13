# Helper for the perf-*.cmd tools (WS16 F4). Peter double-clicks a .cmd; the .cmd calls this with one tool name.
# Every tool changes ONE Windows setting, writes down what it was before (data\perf-tools-state.tsv) and says what it did in
# tools\perf-tools.log. The matching -UNDO.cmd puts the old value back. Nothing here is ever run by Paddock or Claude on its own.
#   -Preview   only look and say what would change (changes nothing; used by tests\perf-test.ps1)
param([Parameter(Mandatory = $true)][string]$Tool, [switch]$Preview)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stateFile = Join-Path $root 'data\perf-tools-state.tsv'
$logFile = Join-Path $PSScriptRoot 'perf-tools.log'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Say($t) { $t; if (-not $Preview) { Add-Content -LiteralPath $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $t) } }
function Get-State { $h = @{}; if (Test-Path $stateFile) { foreach ($l in Get-Content $stateFile) { $i = $l.IndexOf("`t"); if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1) } } }; $h }
function Set-State($k, $v) {
  $h = Get-State; $h[$k] = $v
  New-Item -ItemType Directory -Force (Split-Path $stateFile) | Out-Null
  Set-Content -LiteralPath $stateFile -Value (($h.GetEnumerator() | ForEach-Object { $_.Key + "`t" + $_.Value }) -join "`r`n") -Encoding UTF8
}
function Read-Reg($path, $name) { $v = Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue; if ($v) { $v.$name } else { $null } }
function Put-Reg($path, $name, $value) {
  if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
  Set-ItemProperty -LiteralPath $path -Name $name -Value $value -Type DWord
}
function Show($v) { if ($null -eq $v) { 'not set' } else { [string]$v } }

# --- the settings, one entry per tool (what it sets, where, and what "back" means) ---
$gb = @(@{ P = 'HKCU:\System\GameConfigStore'; N = 'GameDVR_Enabled' }, @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'AppCaptureEnabled' })
$hagsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; $hagsName = 'HwSchMode'

function Restart-AsAdmin {
  if ($isAdmin -or $Preview) { return }
  Start-Process powershell -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Tool ' + $Tool)
  'Windows will ask for permission once (administrator) in a new window.'; exit 0
}

switch ($Tool) {
  'gamebar-off' {
    Say 'Xbox Game Bar: switching background recording off'
    foreach ($e in $gb) {
      $before = Read-Reg $e.P $e.N
      Say ("  {0}: {1} -> 0" -f $e.N, (Show $before))
      if (-not $Preview) { Set-State ('gamebar-' + $e.N) (Show $before); Put-Reg $e.P $e.N 0 }
    }
    if (-not $Preview) { Say 'Done. It takes effect the next time Windows starts a game. To go back: perf-gamebar-off-UNDO.cmd' }
  }
  'gamebar-off-undo' {
    Say 'Xbox Game Bar: putting the background recording settings back'
    $st = Get-State
    foreach ($e in $gb) {
      $was = $st['gamebar-' + $e.N]
      $cur = Read-Reg $e.P $e.N
      if ($null -eq $was) { Say ("  {0}: nothing saved, leaving it at {1}" -f $e.N, (Show $cur)); continue }
      Say ("  {0}: {1} -> {2}" -f $e.N, (Show $cur), $was)
      if ($Preview) { continue }
      if ($was -eq 'not set') { Remove-ItemProperty -LiteralPath $e.P -Name $e.N -ErrorAction SilentlyContinue } else { Put-Reg $e.P $e.N ([int]$was) }
    }
    if (-not $Preview) { Say 'Done.' }
  }
  { $_ -in 'hags-off', 'hags-on' } {
    $want = if ($Tool -eq 'hags-off') { 1 } else { 2 }
    Restart-AsAdmin
    $before = Read-Reg $hagsPath $hagsName
    Say ("Hardware GPU scheduling: {0} -> {1} ({2})" -f (Show $before), $want, $(if ($want -eq 1) { 'off' } else { 'on' }))
    if (-not $Preview) {
      Set-State ($Tool + '-before') (Show $before)
      Put-Reg $hagsPath $hagsName $want
      Say 'Done. Restart the PC for it to take effect, then drive a few laps at the same track: Paddock marks the change and compares. To go back: the matching UNDO file.'
    }
  }
  { $_ -in 'hags-off-undo', 'hags-on-undo' } {
    $base = $Tool -replace '-undo$', ''
    Restart-AsAdmin
    $was = (Get-State)[$base + '-before']
    $cur = Read-Reg $hagsPath $hagsName
    if ($null -eq $was) { Say 'Nothing saved to go back to; leaving the setting as it is.'; break }
    Say ("Hardware GPU scheduling: {0} -> {1}" -f (Show $cur), $was)
    if (-not $Preview) {
      if ($was -eq 'not set') { Remove-ItemProperty -LiteralPath $hagsPath -Name $hagsName -ErrorAction SilentlyContinue } else { Put-Reg $hagsPath $hagsName ([int]$was) }
      Say 'Done. Restart the PC for it to take effect.'
    }
  }
  default { throw "unknown tool: $Tool" }
}
