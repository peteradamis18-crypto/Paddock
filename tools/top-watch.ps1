# Quiet screenshots of the top (4th) monitor while Peter drives - no window, no focus, no clicks (Peter 2026-10-11: "you can test
# fourth screen, just leave race screen going"). Finds the monitor by POSITION (the one above the race screens).
#   top-watch.ps1 [-EverySec 120] [-MaxMin 180]   -> tests\shots\live-top-<HHmmss>.png, stops 5 min after the sim closes
param([int]$EverySec = 120, [int]$MaxMin = 180)
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
try { $me = Get-Process -Id $PID; $me.PriorityClass = 'BelowNormal'; $me.ProcessorAffinity = [IntPtr]0xC000 } catch { }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$top = [Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Y -lt 0 } | Select-Object -First 1
if (-not $top) { Write-Host 'no monitor above the race screens'; exit 1 }
$b = $top.Bounds; $end = (Get-Date).AddMinutes($MaxMin); $off = $null
while ((Get-Date) -lt $end) {
  $st = (& .\irdeck-cli.exe state | Out-String)
  if ($st -match 'sim=True') { $off = $null } elseif ($off -eq $null) { $off = Get-Date } elseif (((Get-Date) - $off).TotalMinutes -gt 5) { break }
  $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
  $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size); $g.Dispose()
  $bmp.Save((Join-Path $root ("tests\shots\live-top-" + (Get-Date -Format 'HHmmss') + ".png")), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  Start-Sleep $EverySec
}
