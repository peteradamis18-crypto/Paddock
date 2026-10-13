# Lets the Stream Deck wake the PC from sleep (press any key). Only the Elgato Stream Deck (USB VID 0FD9) is changed.
#   deck-wake.ps1          turn it on   (asks for administrator approval once)
#   deck-wake.ps1 -Undo    turn it off again
param([switch]$Undo)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"' + $(if ($Undo) { ' -Undo' } else { '' }))
  'Asked Windows for administrator approval in a new window.'; exit 0
}
$want = -not $Undo
# keep a log so the result can be checked without reading this window
Start-Transcript -Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'backup\deck-wake.log') -Force | Out-Null
'Stream Deck devices:'; Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_0FD9' } | ForEach-Object { '  ' + $_.FriendlyName + '  ' + $_.InstanceId }
'Wake-capable devices Windows offers:'; powercfg /devicequery wake_programmable | ForEach-Object { '  ' + $_ }
$armedBefore = @(powercfg /devicequery wake_armed)
# method 1: the device's own wake switch (the Device Manager "Allow this device to wake the computer" box)
$hits = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceWakeEnable -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -match 'VID_0FD9' })
if ($hits.Count -eq 0) { 'Method 1: Windows lists no wake switch for the Stream Deck.' }
foreach ($h in $hits) {
  try { Set-CimInstance -InputObject $h -Property @{ Enable = $want } -ErrorAction Stop
    "Method 1: {0}: wake {1}" -f ($h.InstanceName -replace '_0$', ''), $(if ($want) { 'ON' } else { 'OFF' }) }
  catch { "Method 1: {0}: Windows refused ({1})" -f ($h.InstanceName -replace '_0$', ''), $_.Exception.Message }
}
# method 2: powercfg by name. The Stream Deck shows up to Windows as a "HID-compliant consumer control
# device" (the media-key type of device, also used by keyboards and mice, which already wake the PC).
# Names turned on here are saved so -Undo turns exactly those off again.
$namesFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'backup\deck-wake-names.txt'
if ($want -and -not (Compare-Object $armedBefore @(powercfg /devicequery wake_armed))) {
  $cands = @(powercfg /devicequery wake_programmable | Where-Object { $_ -like 'HID-compliant consumer control device*' -and $armedBefore -notcontains $_ })
  foreach ($n in $cands) { powercfg /deviceenablewake "$n" | Out-Null; "Method 2: wake ON for $n" }
  if ($cands) { $cands | Set-Content -LiteralPath $namesFile -Encoding UTF8 }
}
if ($Undo -and (Test-Path $namesFile)) {
  foreach ($n in (Get-Content -LiteralPath $namesFile)) { powercfg /devicedisablewake "$n" | Out-Null; "Method 2: wake OFF for $n" }
  Remove-Item -LiteralPath $namesFile
}
''
'Devices that can wake the PC now:'
powercfg /devicequery wake_armed
''
if ($want) { 'Done. Put the PC to sleep, then press any Stream Deck key to wake it. Run "UNDO deck wake" to turn this off.' } else { 'Done. The Stream Deck no longer wakes the PC.' }
Stop-Transcript | Out-Null
Read-Host 'Press Enter to close' | Out-Null
