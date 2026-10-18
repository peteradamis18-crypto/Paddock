# reload-test.ps1 - the dashboard picks up new files by itself after a session, and never while he drives.
# 2026-10-18: the last frame of a session (or of a test's pretend race) left IsOnTrack set, so the top screen kept an old
# version - and an old page stuck on it - until his next drive. Opens the served page in headless Chrome; no test hook.
# It touches dash\www\v2\core.js's time stamp, so the real top screen reloads too (harmless: only when the rig is free).
#   powershell -ExecutionPolicy Bypass -File tests\reload-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot; $api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Section($title) { Assert-RigFree -Where $title; $title }
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('reload-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9361
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0 }
  $null = Cdp 'Page.enable' @{}
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
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue
}
$core = Join-Path $root 'dash\www\v2\core.js'
function Touch() { (Get-Item $core).LastWriteTimeUtc = [DateTime]::UtcNow }

try {
  Section '1. while he drives (fresh frames, on track) a new version waits'
  Cdp-Open "$api/v2/"; Start-Sleep -Seconds 5
  # stand in for live frames: on track, a frame every 0.5 s
  $null = Cdp-Eval "window.__mark = 1; window.__feed = setInterval(() => { L.v = Object.assign({}, L.v, { IsOnTrack: 1, IsReplayPlaying: 0 }); L.connected = true; L.lastFrameAt = performance.now(); }, 500); 1"
  Start-Sleep -Seconds 1; Touch; Start-Sleep -Seconds 17
  Check 'the page kept the old version while driving' ((Cdp-Eval "window.__mark === 1") -eq $true)

  Section '2. after the session (the last frame still says on track, but it is old) the new version loads'
  $null = Cdp-Eval "clearInterval(window.__feed); 1"
  Start-Sleep -Seconds 17
  Check 'the page reloaded itself once the frames stopped' ((Cdp-Eval "typeof window.__mark === 'undefined'") -eq $true)
}
finally { Cdp-Close }
''
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
