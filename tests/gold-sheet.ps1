# gold-sheet.ps1 - offline: MY RACES in both golds (bright and soft) from the same fixture, plus one contact sheet for Peter.
# Pictures: tests\shots\rework\races-gold-bright.png, races-gold-soft.png, gold-contact-sheet.png (1920x1080, side by side, one label each).
#   powershell -ExecutionPolicy Bypass -File tests\gold-sheet.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$www = Join-Path $root 'dash\www\app'          # W3-1: RACES is a page of the shell (app\index.html?page=races)
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'gold sheet'
$now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$race = { param($id, $ms, $type, $track, $car, $best, $state) '{"id":"' + $id + '","track":"' + $track + '","config":"Full Course","car":"' + $car + '","type":"' + $type + '","isRace":' + $(if ($type -eq 'Race') { 'true' } else { 'false' }) + ',"startMs":' + $ms + ',"sec":1200,"laps":11,"counted":8,"best":' + $best + ',"bestLap":7,"mb":1101,"kept":false,"thumb":false,"state":' + $state + ',"markers":[]}' }
$fx = '{"storage":{"usedGb":412,"freeGb":283,"trashGb":0,"moreRaces":38,"lowSpace":false},"youtube":{"signedIn":true,"privacy":"private","template":1},"titles":[],"races":[' + ((& $race 'r1' ($now - 3600000) 'Race' 'Road Atlanta' 'Toyota GR86' 93.639 '{"kind":"shared","pct":100,"privacy":"private","url":"https://youtu.be/x"}'), (& $race 'p1' ($now - 7200000) 'Practice' 'Road Atlanta' 'Toyota GR86' 96.44 '{"kind":"none"}'), (& $race 'r2' ($now - 20 * 86400000) 'Race' 'Road America' 'Porsche 718 Cayman GT4' 138.485 '{"kind":"sharing","pct":41}') -join ',') + '],"trash":[]}'
$stub = "<style>*{transition:none !important}</style><script>window.data = { __paddock: true, state: {}, seq: -1, online: true, rig: { driving: false, online: true }, on() { return () => {}; }, onList() { return () => {}; }, telemetry() {}, reloadOnVersion() {}, fetch(u) { return window.fetch(u); }, json(u) { return window.fetch(u).then(r => r.json()); } }; window.fetch = () => Promise.resolve(new Response(JSON.stringify($fx)));</script>"
# show ALL (so the practice is there too) and tick one race (so the gold tick and the bar show)
$act = "<script>setTimeout(() => { document.querySelector('.tab[data-tab=all]').click(); document.querySelector('.card[data-id=p1] .tick').click(); }, 800);</script>"
$src = [IO.File]::ReadAllText((Join-Path $www 'index.html'))
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
  Start-Process -FilePath $chrome -ArgumentList ($common + @("--screenshot=$png", ('file:///' + ("$tmp\$g.html" -replace '\\', '/') + '?page=races&intro=0'))) -NoNewWindow -Wait
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
