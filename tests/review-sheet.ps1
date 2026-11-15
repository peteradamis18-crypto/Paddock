# review-sheet.ps1 - the four states of the REVIEW door from the LIVE irdash (real data, Peter's own laps), pressed in headless Chrome
# (nothing on his screens), then one contact sheet for him: tests\shots\rework\review-contact-sheet.png (the four pictures, one label each).
#   powershell -ExecutionPolicy Bypass -File tests\review-sheet.ps1 [-SheetOnly]
# Known limit (2026-11-14): headless Chrome cannot decode the vault clips (video width 0 while playing), so the WATCH picture shows the
# player without a frame; the top screen's own Chrome plays them. Pictures taken the same way: tests\gold-sheet.ps1 (W0-7).
param([switch]$SheetOnly)     # -SheetOnly: redraw the sheet from the pictures already taken
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots\rework'
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('review-sheet-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9377
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--mute-audio', '--autoplay-policy=no-user-gesture-required', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Runtime.enable' @{}
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false }
  $null = Cdp 'Page.navigate' @{ url = $url }
}
function Cdp($method, $params) {
  $c = $script:cdp; $c.id++
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $c.id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
  $null = $c.ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf = New-Object byte[] 262144; $sb = New-Object Text.StringBuilder
    do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $c.ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage)
    $o = $sb.ToString() | ConvertFrom-Json
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Wait-Until($expr, $sec = 15) { $until = (Get-Date).AddSeconds($sec); while ((Get-Date) -lt $until) { $v = Cdp-Eval $expr; if ($v -eq $true -or $v -eq 'true') { return $true }; Start-Sleep -Milliseconds 250 }; return $false }
function Cdp-Close() { $c = $script:cdp; if (-not $c) { return }; try { $c.ws.Dispose() } catch { }; try { $c.proc.Kill() } catch { }; Start-Sleep -Milliseconds 500; Remove-Item $c.prof -Recurse -Force -ErrorAction SilentlyContinue; $script:cdp = $null }

$card = 'http://localhost:8199/app/?page=review&intro=0'
if (-not $SheetOnly) { try {
  Cdp-Open $card
  '1 card: ' + (Wait-Until "!!document.querySelector('#page .rv-bottom .more') && !!document.querySelector('#page canvas, #page svg')" 20)
  Start-Sleep -Seconds 3
  Cdp-Shot (Join-Path $shots 'review-sheet-1-card.png')
  # SHOW ME (the gold button; if the card found no corner to show, the first corner row)
  '2 press: ' + (Cdp-Eval "(() => { const b = document.querySelector('#page .rv-bottom .show') || document.querySelector('#page [data-n]'); if (!b) return 'no button'; b.click(); return b.className; })()")
  '2 laps: ' + (Wait-Until "/THIS LAP/i.test(document.getElementById('page').textContent) && !!document.querySelector('#page canvas')" 25)
  Start-Sleep -Seconds 4
  Cdp-Shot (Join-Path $shots 'review-sheet-2-laps.png')
  # back to the card, then WATCH on the corner that has a clip
  $null = Cdp 'Page.navigate' @{ url = $card }
  'card again: ' + (Wait-Until "!!document.querySelector('#page .rv-bottom .more')" 20)
  Start-Sleep -Seconds 2
  '3 press: ' + (Cdp-Eval "(() => { const b = document.querySelector('#page .cr-watch[data-clip], #page .watch[data-clip]'); if (!b) return 'no clip button'; b.click(); return b.dataset.what || b.className; })()")
  '3 watch: ' + (Wait-Until "!!document.querySelector('.w-acts') && !!document.querySelector('video')" 15)
  '3 playing: ' + (Wait-Until "(() => { const v = document.querySelector('video'); return !!v && v.readyState >= 2 && v.currentTime > 0.2; })()" 15)
  Start-Sleep -Seconds 2
  Cdp-Shot (Join-Path $shots 'review-sheet-3-watch.png')
  # back to the card, then MORE DATA
  $null = Cdp 'Page.navigate' @{ url = $card }
  'card again: ' + (Wait-Until "!!document.querySelector('#page .rv-bottom .more')" 20)
  Start-Sleep -Seconds 2
  '4 press: ' + (Cdp-Eval "(() => { const b = document.querySelector('#page .rv-bottom .more'); if (!b) return 'no button'; b.click(); return 'more'; })()")
  '4 more: ' + (Wait-Until "(() => { const f = document.querySelector('#page iframe'); try { return !!f && !!f.contentWindow.WB && !!f.contentWindow.WB.state && !!f.contentDocument.querySelector('canvas'); } catch (e) { return false; } })()" 30)
  Start-Sleep -Seconds 5
  Cdp-Shot (Join-Path $shots 'review-sheet-4-more.png')
} finally { Cdp-Close } }

Add-Type -AssemblyName System.Drawing
$sheet = New-Object Drawing.Bitmap 1920, 1240     # two rows of 526 px pictures, each with up to two label lines, under one title
$gr = [Drawing.Graphics]::FromImage($sheet)
$gr.Clear([Drawing.Color]::FromArgb(5, 5, 5)); $gr.InterpolationMode = 'HighQualityBicubic'; $gr.TextRenderingHint = 'AntiAliasGridFit'
$font = New-Object Drawing.Font('Bahnschrift', 18); $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(242, 238, 228))
$gold = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(201, 162, 75)); $big = New-Object Drawing.Font('Bahnschrift', 26)
$gr.DrawString('REVIEW  -  the four screens, live from your 13 Nov race', $big, $gold, 16, 10)
$items = @(
  @('review-sheet-1-card.png', '1  REVIEW: the card after every drive. Bottom bar: MORE DATA / SHOW ME / WATCH.'),
  @('review-sheet-2-laps.png', '2  SHOW ME: your lap against your best, corner by corner.'),
  @('review-sheet-3-watch.png', '3  WATCH: the in-car clip of that corner. No video in this picture: the picture-taker cannot play it; it played on the top screen today.'),
  @('review-sheet-4-more.png', '4  MORE DATA: the full workbench (DRIVER / BRAKING / SPLITS / RACE), Pi Toolbox and Delta at the foot.')
)
$i = 0
foreach ($it in $items) {
  $p = Join-Path $shots $it[0]; if (-not (Test-Path $p)) { "  missing $p"; $i++; continue }
  $img = [Drawing.Image]::FromFile($p)
  $x = 16 + ($i % 2) * 952; $y = 60 + [math]::Floor($i / 2) * 590
  $gr.DrawImage($img, $x, $y, 936, 526); $img.Dispose()
  $gr.DrawRectangle((New-Object Drawing.Pen ([Drawing.Color]::FromArgb(60, 60, 60))), $x, $y, 936, 526)
  $gr.DrawString($it[1], $font, $brush, (New-Object Drawing.RectangleF $x, ($y + 532), 936, 56))   # wraps inside its own column
  $i++
}
$gr.Dispose()
$out = Join-Path $shots 'review-contact-sheet.png'
$sheet.Save($out, [Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
"sheet $out"
