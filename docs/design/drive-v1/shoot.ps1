# Renders drive-v1.html in every state to drive-v1-<state>.png at exactly 1920x1080 (headless Chrome, own static file only).
# New headless loses ~70 px of the window to chrome, so render taller and crop the top 1920x1080.
Add-Type -AssemblyName System.Drawing
$chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$file = (Join-Path $dir 'drive-v1.html') -replace '\\', '/'
$states = if ($args.Count) { $args } else { @('practice', 'race', 'pit', 'stale', 'norec') }
foreach ($s in $states) {
  $raw = Join-Path $env:TEMP ("drive-v1-raw-$s.png")
  $out = Join-Path $dir ("drive-v1-$s.png")
  & $chrome --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1920,1200 --virtual-time-budget=2000 "--screenshot=$raw" --allow-file-access-from-files "file:///$file`?state=$s" 2>$null | Out-Null
  $src = [System.Drawing.Image]::FromFile($raw)
  $bmp = New-Object System.Drawing.Bitmap 1920, 1080
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, 1920, 1080), (New-Object System.Drawing.Rectangle 0, 0, 1920, 1080), [System.Drawing.GraphicsUnit]::Pixel)
  $g.Dispose(); $src.Dispose()
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  Remove-Item $raw -Force
  Write-Output ("{0}: {1}" -f $s, (Test-Path $out))
}

