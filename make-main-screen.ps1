# Makes the MIDDLE race screen the Windows main display (sign-in, taskbar and new windows appear there).
# Keeps the race screens in the same left-to-right order, level with each other, and the dashboard
# monitor centred above them. Finds screens by position, never by monitor number.
#   make-main-screen.ps1           middle race screen becomes main
#   make-main-screen.ps1 -Top      put it back: the top (dashboard) monitor becomes main
#   make-main-screen.ps1 -DryRun   only show what would happen
param([switch]$Top, [switch]$DryRun)

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Disp2 {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr p);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(string dev, IntPtr dm, IntPtr hwnd, int flags, IntPtr p);
  public static int Stage(string dev, int x, int y, bool primary) {
    var d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); EnumDisplaySettings(dev, -1, ref d);
    d.dmFields = 0x20; d.dmPositionX = x; d.dmPositionY = y;
    // CDS_UPDATEREGISTRY | CDS_NORESET, plus CDS_SET_PRIMARY for the new main display
    return ChangeDisplaySettingsEx(dev, ref d, IntPtr.Zero, primary ? 0x10000011 : 0x10000001, IntPtr.Zero);
  }
  public static int Apply() { return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
Add-Type -AssemblyName System.Windows.Forms

$all = [System.Windows.Forms.Screen]::AllScreens
$dash = $all | Sort-Object { $_.Bounds.Y } | Select-Object -First 1
if ($all | Where-Object { $_ -ne $dash -and $_.Bounds.Y -lt $dash.Bounds.Bottom }) { 'Could not find a monitor sitting above the race screens.'; exit 1 }
$race = @($all | Where-Object { $_ -ne $dash } | Sort-Object { $_.Bounds.X })
$mid = $race[[int][Math]::Floor($race.Count / 2)]
$midIdx = [Array]::IndexOf($race, $mid)

# Lay the race screens out level and touching, in their current order, with the middle one's left edge at $mx.
$plan = [ordered]@{}
if ($Top) { $dx = 0; $dy = 0; $mx = [int](($dash.Bounds.Width - $mid.Bounds.Width) / 2); $ry = $dash.Bounds.Height; $main = $dash }
else { $mx = 0; $ry = 0; $main = $mid }
$x = $mx; for ($i = $midIdx; $i -ge 0; $i--) { if ($i -lt $midIdx) { $x -= $race[$i].Bounds.Width }; $plan[$race[$i].DeviceName] = @($x, $ry) }
$x = $mx + $mid.Bounds.Width; for ($i = $midIdx + 1; $i -lt $race.Count; $i++) { $plan[$race[$i].DeviceName] = @($x, $ry); $x += $race[$i].Bounds.Width }
if ($Top) { $plan[$dash.DeviceName] = @(0, 0) }
else { $plan[$dash.DeviceName] = @([int](($mid.Bounds.Width - $dash.Bounds.Width) / 2), -$dash.Bounds.Height) }

foreach ($s in $all) {
  $role = if ($s -eq $dash) { 'dashboard (top)' } elseif ($s -eq $mid) { 'middle race screen' } elseif ($s.Bounds.X -lt $mid.Bounds.X) { 'left race screen' } else { 'right race screen' }
  if ($s -eq $main) { $role += ', becomes MAIN' }
  "{0}  {1,-36} {2},{3} -> {4},{5}" -f $s.DeviceName, $role, $s.Bounds.X, $s.Bounds.Y, $plan[$s.DeviceName][0], $plan[$s.DeviceName][1]
}
if ($DryRun) { 'dry run - nothing changed'; exit 0 }

$codes = foreach ($dev in @($plan.Keys)) { [Disp2]::Stage($dev, $plan[$dev][0], $plan[$dev][1], $dev -eq $main.DeviceName) }
$final = [Disp2]::Apply()
"staged: $($codes -join ',')  applied: $final  (0 = success)"
if ($final -eq 0) { if ($Top) { 'Done. The top monitor is the main display again.' } else { 'Done. The middle race screen is now your main display. Sign-in and the taskbar will appear there.' } }
else { 'Windows refused the change. Use Settings > System > Display, click the middle screen and tick "Make this my main display".' }
