# Restarts the PC towards the BIOS, after showing the steps. Asks for administrator approval once.
# Windows' "restart to firmware" (shutdown /r /fw) is requested, but this MSI board ignored it on
# 2026-10-09, so the steps also tell you to tap Delete during the restart.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $MyInvocation.MyCommand.Path + '"')
  exit 0
}
Add-Type -AssemblyName System.Windows.Forms
if (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue) {
  [System.Windows.Forms.MessageBox]::Show('Close the iRacing race first, then run this again.', 'Open BIOS') | Out-Null; exit 1 }
$steps = @'
Take a photo of this with your phone - it will disappear when the PC restarts.

As soon as the screens go black, keep tapping the Delete key (about twice a second)
until the MSI BIOS appears. If Windows starts instead, run OPEN BIOS again and tap sooner.
The BIOS may show on a race screen upside down (the flip is a Windows setting) - that's normal.

In the BIOS (MSI):
 1. If you see the simple screen, press F7 for Advanced mode.
 2. Settings > Advanced > Power Management Setup
      ErP Ready = Disabled
 3. Settings > Advanced > Wake Up Event Setup
      Resume By USB Device = Enabled
 4. Press F10, then Yes. The PC restarts into Windows.

Tip: Ctrl+F (or the search box at the top) finds a setting by name - type ErP or USB Device.
Nothing else needs changing. Esc goes back a menu.

Click OK to restart into the BIOS now, or Cancel to stop.
'@
$r = [System.Windows.Forms.MessageBox]::Show($steps, 'Open BIOS - Stream Deck wake', 'OKCancel', 'Information')
if ($r -ne 'OK') { exit 0 }
shutdown /r /fw /t 0
