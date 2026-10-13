# Swaps the LEFT and RIGHT race monitors in the Windows layout (iRacing's left/right views follow).
# Works by position, not monitor number, because Windows renumbers monitors after reboots.
# Running it again swaps them back. The monitor above the rig (the dashboard) is never touched.
#   swap-screens.ps1           swap
#   swap-screens.ps1 -DryRun   only show what would happen
param([switch]$DryRun, [switch]$Undo)   # -Undo is the same as running it again

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Disp {
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
  public static DEVMODE Get(string dev) { var d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); EnumDisplaySettings(dev, -1, ref d); return d; }
  public static int Stage(string dev, int x, int y) {
    var d = Get(dev); d.dmFields = 0x20; d.dmPositionX = x; d.dmPositionY = y;
    return ChangeDisplaySettingsEx(dev, ref d, IntPtr.Zero, 0x10000001, IntPtr.Zero);   // CDS_UPDATEREGISTRY | CDS_NORESET
  }
  public static int Apply() { return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
Add-Type -AssemblyName System.Windows.Forms

$all = [System.Windows.Forms.Screen]::AllScreens
$top = $all | Sort-Object { $_.Bounds.Y } | Select-Object -First 1
$aboveAll = -not ($all | Where-Object { $_ -ne $top -and $_.Bounds.Y -lt $top.Bounds.Bottom })
$race = @($all | Where-Object { -not ($aboveAll -and $_ -eq $top) } | Sort-Object { $_.Bounds.X })
if ($race.Count -lt 2) { 'Need at least two race monitors side by side.'; exit 1 }
$left = $race[0]; $right = $race[$race.Count - 1]

foreach ($s in $all) {
  $role = if ($aboveAll -and $s -eq $top) { 'dashboard (untouched)' } elseif ($s -eq $left) { 'left race screen -> moves to the right' } elseif ($s -eq $right) { 'right race screen -> moves to the left' } else { 'centre (untouched)' }
  "{0}  {1}x{2} at {3},{4}  {5}" -f $s.DeviceName, $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y, $role
}
if ($DryRun) { 'dry run - nothing changed'; exit 0 }

# The right screen takes the left spot; the left screen goes after the last screen's right edge minus its own width.
$newRightX = $right.Bounds.Right - $left.Bounds.Width
$codes = @([Disp]::Stage($right.DeviceName, $left.Bounds.X, $left.Bounds.Y), [Disp]::Stage($left.DeviceName, $newRightX, $right.Bounds.Y))
$final = [Disp]::Apply()
"staged: $($codes -join ',')  applied: $final  (0 = success)"
if ($final -eq 0) { 'Done. Left and right race screens are swapped. irdash re-stretches iRacing in a couple of seconds.' }
else { 'Windows refused the change. Use Settings > System > Display and drag the boxes instead.' }
