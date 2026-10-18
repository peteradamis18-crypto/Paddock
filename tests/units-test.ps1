# units-test.ps1 - the analysis workbench shows speed in the units iRacing last reported (mph or km/h), like the Vault and
# Sessions pages (2026-10-18: it was always km/h). Opens the served workbench in headless Chrome on a real Corvette file.
#   powershell -ExecutionPolicy Bypass -File tests\units-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot; $api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Section($title) { Assert-RigFree -Where $title; $title }
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('units-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9362
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
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$ibt = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'
if (-not (Test-Path (Join-Path $tel $ibt))) { "  (skipped: $ibt is not in the telemetry folder)"; exit 0 }
$url = "$api/v2/workbench.html?id=" + [uri]::EscapeDataString($ibt) + '&lap=7&page=grip'
function Look() { Cdp-Eval "JSON.stringify({ head: [].map.call(document.querySelectorAll('table.ct th'), function (t) { return t.textContent; }).join('|'), f: window.WBX && WBX.api.SPD && WBX.api.SPD.f, vmin: (function () { var r = document.querySelector('table.ct tr:nth-child(2) td:nth-child(3)'); return r ? parseFloat(r.firstChild.textContent) : null; })() })" | ConvertFrom-Json }
try {
  Section '1. iRacing set to imperial: mph'
  Cdp-Open "$api/v2/"; Start-Sleep -Seconds 2
  $null = Cdp-Eval "localStorage.setItem('irdash-units', 'false'); location.href = '$url'; 1"; Start-Sleep -Seconds 7
  $m = Look
  Check "the corner table says MIN MPH ($($m.head))" ($m.head -match 'MIN MPH')
  Check "speed is metres per second x 2.237 ($($m.f))" ([math]::Abs($m.f - 2.236936) -lt 0.0001)
  Section '2. iRacing set to metric: km/h, and the same corner reads 1.609 times higher'
  $null = Cdp-Eval "localStorage.setItem('irdash-units', 'true'); location.reload(); 1"; Start-Sleep -Seconds 7
  $k = Look
  Check "the corner table says MIN KM/H ($($k.head))" ($k.head -match 'MIN KM/H')
  Check "the slowest-corner minimum: $($m.vmin) mph = $($k.vmin) km/h" ($m.vmin -gt 20 -and [math]::Abs($k.vmin - $m.vmin * 1.609344) -le 1.5)
}
finally { Cdp-Close }
''
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }