# Rig cleanup: stops non-sim apps from starting with Windows and turns off things that slow startup.
# Everything is reversible: the previous state is saved to backup\cleanup-state.json and -Undo restores it.
#   rig-cleanup.ps1            show what it would change (nothing is changed)
#   rig-cleanup.ps1 -Apply     make the changes (asks for administrator approval once)
#   rig-cleanup.ps1 -Undo      put everything back as it was
# Not touched on purpose: OneDrive (your Documents and iRacing settings live in it), Teams, anything of iRacing's,
# Stream Deck, SimHub, Simucube, Fanatec, ButtKicker, NZXT CAM (may control pump and fans), MSI Center.
param([switch]$Apply, [switch]$Undo)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $root 'backup\cleanup-state.json'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Apply -or $Undo) -and -not $isAdmin) {
  $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '" ' + $(if ($Apply) { '-Apply' } else { '-Undo' })
  Start-Process powershell -Verb RunAs -ArgumentList $arg
  'Asked Windows for administrator approval in a new window.'; exit 0
}

# --- what to change ---
$startupOff = @(   # startup entries to switch off (same as Task Manager > Startup apps > Disable)
  @{ Hive = 'HKLM'; Name = 'Logitech Download Assistant'; Why = 'Logitech update helper only; Logitech software keeps working' },
  @{ Hive = 'HKLM'; Name = 'Logi Download Assistant';     Why = 'Logitech update helper only; Logitech software keeps working' }
)
$services = @(     # Intel Management Engine parts on an AMD board: they fail or idle and slow startup
  @{ Name = 'Intel(R) Platform License Manager Service'; Why = 'failed to start 18 times last week, 45 s each' },
  @{ Name = 'jhi_service';                               Why = 'Intel ME host interface, not used on AMD' },
  @{ Name = 'WMIRegistrationService';                    Why = 'Intel ME WMI provider, not used on AMD' }
)
$tasks = @('NvNodeLauncher_*', 'NvProfileUpdaterOnLogon_*')   # GeForce Experience helpers that run at sign-in
$regValues = @(
  @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; Name = 'StartupDelayInMSec'; Value = 0; Why = 'removes the Windows delay before startup apps' },
  @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0; Why = 'Game Bar background recording off' },
  @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0; Why = 'Game Bar capture off' }
)

function RunKey($hive, $name) {
  foreach ($p in @("${hive}:\Software\Microsoft\Windows\CurrentVersion\Run", "${hive}:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run")) {
    $v = Get-ItemProperty -LiteralPath $p -Name $name -ErrorAction SilentlyContinue
    if ($v) { return @{ Run = $p; Approved = "${hive}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\" + $(if ($p -like '*WOW6432Node*') { 'Run32' } else { 'Run' }) } }
  }
  return $null
}

if ($Undo) {
  if (-not (Test-Path $stateFile)) { 'Nothing to undo: no saved state.'; exit 0 }
  $s = Get-Content $stateFile -Raw | ConvertFrom-Json
  foreach ($e in $s.startup) { if ($e.Before -eq $null) { Remove-ItemProperty -LiteralPath $e.Approved -Name $e.Name -ErrorAction SilentlyContinue } else { Set-ItemProperty -LiteralPath $e.Approved -Name $e.Name -Value ([byte[]]$e.Before) }; "startup restored: $($e.Name)" }
  foreach ($e in $s.services) { Set-Service -Name $e.Name -StartupType $e.Before; "service restored: $($e.Name) -> $($e.Before)" }
  foreach ($e in $s.tasks) { if ($e.Before -ne 'Disabled') { Enable-ScheduledTask -TaskPath $e.Path -TaskName $e.Name | Out-Null; "task re-enabled: $($e.Name)" } }
  foreach ($e in $s.reg) { if ($e.Before -eq $null) { Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue } else { Set-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $e.Before }; "setting restored: $($e.Name)" }
  Remove-Item $stateFile; 'Undo finished. Restart the PC for everything to take effect.'
  Read-Host 'Press Enter to close' | Out-Null; exit 0
}

$state = @{ startup = @(); services = @(); tasks = @(); reg = @() }
"Rig cleanup - " + $(if ($Apply) { 'APPLYING' } else { 'preview only, nothing will change' }); ''
foreach ($e in $startupOff) {
  $k = RunKey $e.Hive $e.Name
  if (-not $k) { "  skip startup '$($e.Name)': not present"; continue }
  $before = (Get-ItemProperty -LiteralPath $k.Approved -Name $e.Name -ErrorAction SilentlyContinue).($e.Name)
  "  startup off: $($e.Name)  ($($e.Why))"
  if ($Apply) {
    if (-not (Test-Path $k.Approved)) { New-Item -Path $k.Approved -Force | Out-Null }
    $state.startup += @{ Name = $e.Name; Approved = $k.Approved; Before = $before }
    Set-ItemProperty -LiteralPath $k.Approved -Name $e.Name -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Type Binary
  }
}
foreach ($e in $services) {
  $svc = Get-Service -Name $e.Name -ErrorAction SilentlyContinue
  if (-not $svc) { "  skip service '$($e.Name)': not present"; continue }
  "  service disabled: $($svc.DisplayName)  ($($e.Why))"
  if ($Apply) { $state.services += @{ Name = $e.Name; Before = [string]$svc.StartType }; Stop-Service -Name $e.Name -Force -ErrorAction SilentlyContinue; Set-Service -Name $e.Name -StartupType Disabled }
}
foreach ($pat in $tasks) {
  foreach ($t in Get-ScheduledTask -TaskName $pat -ErrorAction SilentlyContinue) {
    "  sign-in task off: $($t.TaskName)  (GeForce Experience helper)"
    if ($Apply) { $state.tasks += @{ Path = $t.TaskPath; Name = $t.TaskName; Before = [string]$t.State }; Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName | Out-Null }
  }
}
foreach ($e in $regValues) {
  $before = (Get-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue).($e.Name)
  "  setting: $($e.Name) = $($e.Value)  ($($e.Why))"
  if ($Apply) { $state.reg += @{ Path = $e.Path; Name = $e.Name; Before = $before }; if (-not (Test-Path $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }; Set-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $e.Value -Type DWord }
}
''
if ($Apply) {
  New-Item -ItemType Directory -Force (Split-Path $stateFile) | Out-Null
  $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8
  "Done. Previous state saved to $stateFile"
  'Restart the PC to see the faster start. To reverse everything, run "UNDO rig cleanup".'
  ''
  'Two things to do by hand, if you like:'
  '  - GeForce Experience: Settings > General > In-game overlay: Off (it hooks into games).'
  '  - OneDrive: right-click Documents\iRacing > "Always keep on this device", so iRacing never waits for a download.'
  Read-Host 'Press Enter to close' | Out-Null
} else { 'Preview only. Run "RIG CLEANUP" (or this script with -Apply) to make these changes.' }
