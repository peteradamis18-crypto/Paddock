# Rig tune: Windows settings sim racers use for iRacing. Reversible: the previous state is saved to
# backup\tune-state.json and -Undo restores it.
#   rig-tune.ps1           preview only (changes nothing)
#   rig-tune.ps1 -Apply    apply (asks for administrator approval once)
#   rig-tune.ps1 -Undo     put everything back
# What it changes:
#   1. Power plan -> High Performance (iRacing support recommends it)
#   2. USB selective suspend -> off (stops Windows powering down the wheel, pedals and Stream Deck)
#   3. "Optimizations for windowed games" -> on (lower latency for borderless iRacing)
#   4. Game Mode -> on
param([switch]$Apply, [switch]$Undo)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $root 'backup\tune-state.json'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Apply -or $Undo) -and -not $isAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '" ' + $(if ($Apply) { '-Apply' } else { '-Undo' }))
  'Asked Windows for administrator approval in a new window.'; exit 0
}
$HIGH = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$USB_SUB = '2a737441-1930-4402-8d77-b2bebba308a3'; $USB_SUSPEND = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$dxKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; $gbKey = 'HKCU:\Software\Microsoft\GameBar'
function ActivePlan { ([regex]::Match((powercfg /getactivescheme), '[0-9a-f]{8}-[0-9a-f-]{27}')).Value }

if ($Undo) {
  if (-not (Test-Path $stateFile)) { 'Nothing to undo.'; exit 0 }
  $s = Get-Content $stateFile -Raw | ConvertFrom-Json
  powercfg /setacvalueindex $s.highPlan $USB_SUB $USB_SUSPEND $s.usbBefore | Out-Null
  powercfg /setactive $s.planBefore | Out-Null; "power plan restored"
  if ($s.dxBefore -eq $null) { Remove-ItemProperty -Path $dxKey -Name DirectXUserGlobalSettings -ErrorAction SilentlyContinue } else { Set-ItemProperty -Path $dxKey -Name DirectXUserGlobalSettings -Value $s.dxBefore }
  if ($s.gmBefore -eq $null) { Remove-ItemProperty -Path $gbKey -Name AutoGameModeEnabled -ErrorAction SilentlyContinue } else { Set-ItemProperty -Path $gbKey -Name AutoGameModeEnabled -Value $s.gmBefore -Type DWord }
  Remove-Item $stateFile; 'Undo finished.'; Read-Host 'Press Enter to close' | Out-Null; exit 0
}

$planBefore = ActivePlan
$havePlan = (powercfg /list) -match $HIGH
$dxBefore = (Get-ItemProperty -Path $dxKey -Name DirectXUserGlobalSettings -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
$gmBefore = (Get-ItemProperty -Path $gbKey -Name AutoGameModeEnabled -ErrorAction SilentlyContinue).AutoGameModeEnabled
"Rig tune - " + $(if ($Apply) { 'APPLYING' } else { 'preview only, nothing will change' }); ''
"  1. power plan: $planBefore -> High Performance$(if (-not $havePlan) { ' (will be created from Windows default)' })"
"  2. USB selective suspend (plugged in): -> off"
"  3. optimizations for windowed games: '$dxBefore' -> SwapEffectUpgradeEnable=1"
"  4. Game Mode: '$gmBefore' -> 1"
if (-not $Apply) { ''; 'Preview only. Run "RIG TUNE" to apply.'; exit 0 }

if (-not $havePlan) { powercfg /duplicatescheme $HIGH $HIGH | Out-Null }
$usbBefore = [Convert]::ToInt32(([regex]::Match(((powercfg /q $HIGH $USB_SUB $USB_SUSPEND) -match 'Current AC Power Setting Index') -join '', '0x[0-9a-f]+')).Value, 16)
powercfg /setacvalueindex $HIGH $USB_SUB $USB_SUSPEND 0 | Out-Null
powercfg /setactive $HIGH | Out-Null
if (-not (Test-Path $dxKey)) { New-Item -Path $dxKey -Force | Out-Null }
$parts = @(); if ($dxBefore) { $parts = @($dxBefore.Split(';') | Where-Object { $_ -and $_ -notmatch '^SwapEffectUpgradeEnable=' }) }
Set-ItemProperty -Path $dxKey -Name DirectXUserGlobalSettings -Value ((($parts + 'SwapEffectUpgradeEnable=1') -join ';') + ';')
if (-not (Test-Path $gbKey)) { New-Item -Path $gbKey -Force | Out-Null }
Set-ItemProperty -Path $gbKey -Name AutoGameModeEnabled -Value 1 -Type DWord
New-Item -ItemType Directory -Force (Split-Path $stateFile) | Out-Null
@{ planBefore = $planBefore; highPlan = $HIGH; usbBefore = $usbBefore; dxBefore = $dxBefore; gmBefore = $gmBefore } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
''; "Done. Active plan: $(powercfg /getactivescheme)"
'Restart iRacing for the windowed-games change to take effect. "UNDO rig tune" reverses everything.'
Read-Host 'Press Enter to close' | Out-Null
