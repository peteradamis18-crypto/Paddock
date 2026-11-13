# gold-sheet.ps1 - offline: MY RACES in both golds (bright and soft) from the same fixture, plus one contact sheet for Peter.
# Pictures: tests\shots\rework\races-gold-bright.png, races-gold-soft.png, gold-contact-sheet.png (1920x1080, side by side, one label each).
#   powershell -ExecutionPolicy Bypass -File tests\gold-sheet.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$www = Join-Path $root 'dash\www\v2'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'gold sheet'
$now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$fx = "{`"freeGb`":283,`"races`":[{`"id`":`"r1`",`"track`":`"Road Atlanta`",`"car`":`"Toyota GR86`",`"type`":`"Race`",`"startMs`":$($now - 3600000),`"min`":20,`"laps`":11,`"best`":93.639,`"mb`":1101,`"saved`":true},{`"id`":`"p1`",`"track`":`"Road Atlanta`",`"car`":`"Toyota GR86`",`"type`":`"Practice`",`"startMs`":$($now - 7200000),`"min`":9,`"laps`":4,`"best`":96.44,`"mb`":536,`"saved`":false},{`"id`":`"r2`",`"track`":`"Road America`",`"car`":`"Porsche 718 Cayman GT4`",`"type`":`"Race`",`"startMs`":$($now - 20 * 86400000),`"min`":19,`"laps`":8,`"best`":138.485,`"mb`":1130,`"saved`":true}]}"
$stub = "<style>*{transition:none !important}</style><script>window.fetch = () => Promise.resolve(new Response(JSON.stringify($fx)));</script>"
# show the practice tab too (so KEEP is visible) and arm one DELETE (so the red state is visible)
$act = "<script>setTimeout(() => { document.getElementById('tabAll').click(); document.querySelector('button[data-act=del][data-id=p1]').click(); }, 500);</script>"
$src = [IO.File]::ReadAllText((Join-Path $www 'races.html'))
$base = '<base href="file:///' + ($www -replace '\\', '/') + '/">'
$tmp = Join-Path $env:TEMP ('gold-sheet-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars', '--virtual-time-budget=3000')
foreach ($g in 'bright', 'soft') {
  Assert-RigFree -Where "gold $g"
  $h = $src.Replace('<head>', '<head>' + $base + $stub).Replace('<html lang="en">', $(if ($g -eq 'bright') { '<html lang="en" data-gold="bright">' } else { '<html lang="en">' })).Replace('</body>', $act + '</body>')
  [IO.File]::WriteAllText("$tmp\$g.html", $h, $utf8)
  $png = Join-Path $shots "races-gold-$g.png"; Remove-Item $png -ErrorAction SilentlyContinue
  Start-Process -FilePath $chrome -ArgumentList ($common + @("--screenshot=$png", ('file:///' + ("$tmp\$g.html" -replace '\\', '/')))) -NoNewWindow -Wait
  if (Test-Path $png) { "  ok    $png" } else { '  FAIL  no picture for ' + $g; exit 1 }
}
Add-Type -AssemblyName System.Drawing
$sheet = New-Object Drawing.Bitmap 1920, 1080
$gr = [Drawing.Graphics]::FromImage($sheet)
$gr.Clear([Drawing.Color]::FromArgb(5, 5, 5)); $gr.InterpolationMode = 'HighQualityBicubic'; $gr.TextRenderingHint = 'AntiAliasGridFit'
$font = New-Object Drawing.Font('Bahnschrift', 26); $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(242, 238, 228))
$labels = @{ bright = 'A  Bright gold #F2C230 (before)'; soft = 'B  Broadcast gold #C9A24B (chosen 2026-11-13)' }
$x = 0
foreach ($g in 'bright', 'soft') {
  $img = [Drawing.Image]::FromFile((Join-Path $shots "races-gold-$g.png"))
  # 940 wide, 529 high: two across, each under a one-line label; a thin gap between them
  $gr.DrawImage($img, 10 + $x * 960, 200, 940, 529); $img.Dispose()
  $gr.DrawString($labels[$g], $font, $brush, 10 + $x * 960, 750)
  $x++
}
$gr.Dispose()
$out = Join-Path $shots 'gold-contact-sheet.png'
$sheet.Save($out, [Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
"  ok    $out"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
