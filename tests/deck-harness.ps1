# Shared by tests\deck-speed-test.ps1 and tests\mydrive-test.ps1 (dot-source it).
# Runs the real add-on page (deck-intro\plugin.html) inside headless Chrome with a pretend Stream Deck app around it
# (tests\deck-mock.js) and talks to the page over the DevTools protocol. The page can be put in a background tab, where
# Chrome slows its timers the way the Stream Deck app does for the add-on's hidden page.

$script:cdpId = 0
$script:HarnessDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Start-DeckBrowser([int]$Port = 9351) {
  $chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
  if (-not (Test-Path $chrome)) { throw 'Chrome is not installed' }
  $prof = Join-Path $env:TEMP ('deck-harness-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", '--allow-file-access-from-files', "--remote-debugging-port=$Port", 'about:blank') -PassThru -WindowStyle Hidden
  $ver = $null
  for ($i = 0; $i -lt 60 -and -not $ver; $i++) { Start-Sleep -Milliseconds 200; try { $ver = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" } catch { } }
  if (-not $ver) { try { $p | Stop-Process -Force } catch { }; throw 'Chrome did not start' }
  $bws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $bws.ConnectAsync([Uri]$ver.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  [pscustomobject]@{ Proc = $p; Prof = $prof; Port = $Port; Bws = $bws }
}

function Stop-DeckBrowser($b) {
  try { $b.Bws.Dispose() } catch { }
  try { $b.Proc | Stop-Process -Force } catch { }
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($b.Prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300
  try { Remove-Item -LiteralPath $b.Prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

function Invoke-Cdp($ws, [string]$method, $params = @{}) {
  $script:cdpId++
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $script:cdpId; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress))
  $null = $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf = New-Object byte[] 262144; $ms = New-Object IO.MemoryStream
    do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); $ms.Write($buf, 0, $r.Result.Count) } while (-not $r.Result.EndOfMessage)
    $o = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
    if ($o.id -eq $script:cdpId) { return $o }
  }
}

# Opens a page. -Hidden puts another tab in front, so this one is a background tab (timers slowed by Chrome).
function New-DeckPage($b, [string]$Url, [switch]$Hidden) {
  $t = Invoke-Cdp $b.Bws 'Target.createTarget' @{ url = $Url }
  $id = $t.result.targetId
  if ($Hidden) { $o = Invoke-Cdp $b.Bws 'Target.createTarget' @{ url = 'about:blank' }; $null = Invoke-Cdp $b.Bws 'Target.activateTarget' @{ targetId = $o.result.targetId } }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) {
    foreach ($x in @(Invoke-RestMethod "http://127.0.0.1:$($b.Port)/json")) { foreach ($y in @($x)) { if ($y.id -eq $id) { $page = $y } } }   # (Windows PowerShell hands the JSON array over as one object)
    if (-not $page) { Start-Sleep -Milliseconds 100 }
  }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  [pscustomobject]@{ Ws = $ws; Id = $id }
}

# Runs JavaScript in the page (waits for a promise) and returns its value (objects come back as objects).
function Invoke-DeckJs($page, [string]$Expr) {
  $res = Invoke-Cdp $page.Ws 'Runtime.evaluate' @{ expression = "(async () => { const v = await ($Expr); return JSON.stringify(v === undefined ? null : v); })()"; awaitPromise = $true; returnByValue = $true }
  if ($res.result.exceptionDetails) { throw ('page error: ' + $res.result.exceptionDetails.exception.description + ' ' + $res.result.exceptionDetails.text) }
  $v = $res.result.result.value
  if ($null -eq $v) { return $null }
  return ($v | ConvertFrom-Json)
}

# plugin.html + the pretend Stream Deck app, as one page the browser can open
function Build-DeckHarness([string]$PluginPath, [string]$OutPath) {
  $mock = [IO.File]::ReadAllText((Join-Path $script:HarnessDir 'deck-mock.js'))
  $html = [IO.File]::ReadAllText($PluginPath)
  $html = $html.Replace('<body>', "<body>`n<script>`n" + $mock + "`n</script>")
  [IO.File]::WriteAllText($OutPath, $html, (New-Object Text.UTF8Encoding($false)))
  'file:///' + ($OutPath -replace '\\', '/')
}

# Start the add-on in the pretend app and wait until it has had time to ask irdash for its first state.
function Start-DeckAddon($page, $fixtures, [int]$SwitchMs = 150, [int]$ApiMs = 15) {
  $fx = $fixtures | ConvertTo-Json -Depth 20 -Compress
  $null = Invoke-DeckJs $page "(() => { __sd.cfg.switchMs = $SwitchMs; __sd.cfg.apiMs = $ApiMs; __sd.fx = $fx; __sd.connect(); return 1; })()"
}

function Save-DataUrlPng([string]$DataUrl, [string]$Path) {
  [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($DataUrl.Substring($DataUrl.IndexOf(',') + 1)))
}

# Draws the keys of the profile that is showing as the deck looks (a 8 x 4 contact sheet) and saves it as a PNG.
function Save-DeckSheet($page, [string]$Path) {
  $r = Invoke-DeckJs $page @'
(async () => {
  const cv = document.createElement('canvas'); cv.width = 1212; cv.height = 612; const g = cv.getContext('2d'); g.fillStyle = '#333'; g.fillRect(0, 0, cv.width, cv.height); let n = 0;
  for (let r = 0; r < 4; r++) for (let c = 0; c < 8; c++) {
    const u = __sd.images[__sd.tileCtx(c, r)]; if (!u) continue; n++;
    await new Promise(res => { const im = new Image(); im.onload = () => { g.drawImage(im, c * 150 + 6, r * 150 + 6, 138, 138); res(); }; im.src = u; });
  }
  return { n, png: cv.toDataURL('image/png') };
})()
'@
  Save-DataUrlPng $r.png $Path
  return $r.n
}
