# rig-sheet.ps1 - RIG as Peter sees it: one picture of the LIVE RIG page (headless Chrome on the running irdash, nothing on his screens)
# plus three states from tests\rig-test.ps1's pictures (ready, one fault, quiet PC on), on one contact sheet:
#   tests\shots\rework\rig-contact-sheet.png.    powershell -ExecutionPolicy Bypass -File tests\rig-sheet.ps1 [-SheetOnly]
# The same picture-taker as tests\review-sheet.ps1 (W4-7).
param([switch]$SheetOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\guard.ps1')
Assert-RigFree
$shots = Join-Path $root 'tests\shots\rework'
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
# the live page keeps a stream open, so Chrome's plain --screenshot never "finishes loading": drive it over the DevTools protocol instead
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('rig-sheet-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9379
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', '--mute-audio', 'about:blank') -PassThru -WindowStyle Hidden
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}; $null = Cdp 'Runtime.enable' @{}
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
if (-not $SheetOnly) {
  try {
    Cdp-Open 'http://localhost:8199/app/?page=rig&intro=0'
    'rig page: ' + (Wait-Until "(() => { const t = (document.getElementById('page') || {}).textContent || ''; return /Rig ready|Stream Deck|Spotter/.test(t) && /LAST RACE|last race/i.test(t); })()" 20)
    Start-Sleep -Seconds 4
    Cdp-Shot (Join-Path $shots 'rig-live.png')
    'live picture taken'
  } finally { Cdp-Close }
}
Add-Type -AssemblyName System.Drawing
$sheet = New-Object Drawing.Bitmap 1920, 1240
$gr = [Drawing.Graphics]::FromImage($sheet)
$gr.Clear([Drawing.Color]::FromArgb(5, 5, 5)); $gr.InterpolationMode = 'HighQualityBicubic'; $gr.TextRenderingHint = 'AntiAliasGridFit'
$font = New-Object Drawing.Font('Bahnschrift', 18); $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(242, 238, 228))
$gold = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(201, 162, 75)); $big = New-Object Drawing.Font('Bahnschrift', 26)
$gr.DrawString('RIG  -  live tonight, and three of its states', $big, $gold, 16, 10)
$items = @(
  @('rig-live.png', '1  RIG now, live from your rig: the ready line, the four rows, your last race, Quiet PC, AC, the two switches, MORE.'),
  @('rig-ready.png', '2  Everything running: "Rig ready".'),
  @('rig-one-fault.png', '3  One thing wrong: the sentence and one FIX button.'),
  @('rig-quiet-on.png', '4  Quiet PC on during a session (after your one click to set it up).')
)
$i = 0
foreach ($it in $items) {
  $p = Join-Path $shots $it[0]; if (-not (Test-Path $p)) { "  missing $p"; $i++; continue }
  $img = [Drawing.Image]::FromFile($p)
  $x = 16 + ($i % 2) * 952; $y = 60 + [math]::Floor($i / 2) * 590
  $gr.DrawImage($img, $x, $y, 936, 526); $img.Dispose()
  $gr.DrawRectangle((New-Object Drawing.Pen ([Drawing.Color]::FromArgb(60, 60, 60))), $x, $y, 936, 526)
  $gr.DrawString($it[1], $font, $brush, (New-Object Drawing.RectangleF $x, ($y + 532), 936, 56))
  $i++
}
$gr.Dispose()
$out = Join-Path $shots 'rig-contact-sheet.png'
$sheet.Save($out, [Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
"sheet $out"
