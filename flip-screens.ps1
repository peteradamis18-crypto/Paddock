# Rotates the three 2560x1440 race screens 180 degrees (same as NVIDIA Control Panel ->
# Rotate display -> Landscape (flipped)). The top 1920x1080 screen is never touched.
#   flip-screens.ps1 -Flip    race screens upside down (180), and close the NVIDIA overlay if running
#   flip-screens.ps1 -Undo    race screens back to normal (0)
# After flipping, a box on the top screen asks to keep it; no answer in 15 s puts them back.
param([switch]$Flip, [switch]$Undo)
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public class Rot {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; public short spec, drv, size, extra; public int fields;
    public int px, py, orient, fixedOut; public short color, duplex, yres, tt, collate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string form; public short lp; public int bpp, w, h, flags, hz;
    public int x1, x2, x3, x4, x5, x6, x7, x8; }
  [DllImport("user32.dll")] static extern bool EnumDisplaySettings(string d, int m, ref DEVMODE dm);
  [DllImport("user32.dll")] static extern int ChangeDisplaySettingsEx(string d, ref DEVMODE dm, IntPtr h, int f, IntPtr p);
  [DllImport("user32.dll")] static extern int ChangeDisplaySettingsEx(string d, IntPtr dm, IntPtr h, int f, IntPtr p);
  public static int Get(string d) { var m = new DEVMODE(); m.size = (short)Marshal.SizeOf(m); EnumDisplaySettings(d, -1, ref m); return m.orient; }
  public static bool IsRace(string d) { var m = new DEVMODE(); m.size = (short)Marshal.SizeOf(m); EnumDisplaySettings(d, -1, ref m); return m.w == 2560 && m.h == 1440; }
  // o < 0 leaves orientation alone. Position is always set: changing orientation without
  // DM_POSITION lets Windows re-arrange the screens in a row.
  public static int Set(string d, int o, int x, int y, bool primary) {
    var m = new DEVMODE(); m.size = (short)Marshal.SizeOf(m); EnumDisplaySettings(d, -1, ref m);
    m.fields = 0x20; m.px = x; m.py = y; // DM_POSITION
    if (o >= 0) { m.orient = o; m.fields |= 0x80; } // DM_DISPLAYORIENTATION; 180 keeps width/height
    return ChangeDisplaySettingsEx(d, ref m, IntPtr.Zero, 0x01 | 0x10000000 | (primary ? 0x10 : 0), IntPtr.Zero); } // update registry, apply later
  public static int Apply() { return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
$race = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { [Rot]::IsRace($_.DeviceName) } | ForEach-Object { $_.DeviceName })
if ($race.Count -eq 0) { 'No 2560x1440 race screens found.'; exit 1 }
if (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue) {
  [System.Windows.Forms.MessageBox]::Show('Close the iRacing sim first (leave the iRacing app open), then run this again.', 'Flip race screens') | Out-Null; exit 1 }
# NVIDIA overlay: close it if it is running (turn it off for good in NVIDIA App -> Settings -> Features)
if ($Flip) { Get-Process -Name 'NVIDIA Overlay' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
# Rig layout: top screen above, race screens in a row under it with the middle one centred
# (top at 0,0 -> race at -2880/-320/2240, y 1080). Left-to-right order is kept as it is now,
# and everything is shifted so the current main (primary) screen stays at 0,0.
$all = [System.Windows.Forms.Screen]::AllScreens
$order = @($all | Where-Object { $race -contains $_.DeviceName } | Sort-Object { $_.Bounds.X } | ForEach-Object { $_.DeviceName })
$topName = ($all | Where-Object { $race -notcontains $_.DeviceName } | Select-Object -First 1).DeviceName
$pos = @{}
if ($topName) { $pos[$topName] = @(0, 0) }
$x0 = if ($topName) { 960 - 1280 - 2560 * [math]::Floor($order.Count / 2) } else { 0 }
for ($i = 0; $i -lt $order.Count; $i++) { $pos[$order[$i]] = @(($x0 + 2560 * $i), $(if ($topName) { 1080 } else { 0 })) }
$prim = [System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
$dx = $pos[$prim][0]; $dy = $pos[$prim][1]
function SetAll($o) {
  foreach ($d in $pos.Keys) { [void][Rot]::Set($d, $(if ($race -contains $d) { $o } else { -1 }), ($pos[$d][0] - $dx), ($pos[$d][1] - $dy), ($d -eq $prim)) }
  [void][Rot]::Apply() }
$before = [Rot]::Get($race[0])
$target = if ($Undo) { 0 } else { 2 }
SetAll $target   # also repairs the layout when the orientation is already right
if ($Undo -or $before -eq $target) { 'Race screens ' + $(if ($target) { 'flipped' } else { 'normal' }) + ', layout set.'; exit 0 }

# keep / revert box on the top (unflipped) screen
$top = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $race -notcontains $_.DeviceName } | Select-Object -First 1
$f = New-Object System.Windows.Forms.Form
$f.Text = 'Flip race screens'; $f.Width = 520; $f.Height = 220; $f.TopMost = $true; $f.StartPosition = 'Manual'
$f.FormBorderStyle = 'FixedDialog'; $f.Font = New-Object System.Drawing.Font('Segoe UI', 14)
if ($top) { $f.Left = $top.Bounds.X + ($top.Bounds.Width - 520) / 2; $f.Top = $top.Bounds.Y + 300 }
$lbl = New-Object System.Windows.Forms.Label; $lbl.SetBounds(20, 15, 470, 60); $f.Controls.Add($lbl)
$keep = New-Object System.Windows.Forms.Button; $keep.Text = 'KEEP'; $keep.SetBounds(20, 90, 220, 70); $f.Controls.Add($keep)
$back = New-Object System.Windows.Forms.Button; $back.Text = 'PUT BACK'; $back.SetBounds(270, 90, 220, 70); $f.Controls.Add($back)
$script:left = 15; $script:kept = $false
$lbl.Text = "Race screens flipped. Keep them? Putting back in $script:left s"
$t = New-Object System.Windows.Forms.Timer; $t.Interval = 1000
$t.Add_Tick({ $script:left--; $lbl.Text = "Race screens flipped. Keep them? Putting back in $script:left s"; if ($script:left -le 0) { $f.Close() } })
$keep.Add_Click({ $script:kept = $true; $f.Close() }); $back.Add_Click({ $f.Close() })
$t.Start(); [void]$f.ShowDialog(); $t.Stop()
if (-not $script:kept) { SetAll $before; 'Put back.' } else { 'Kept. "UNDO flip screens" puts them back.' }
