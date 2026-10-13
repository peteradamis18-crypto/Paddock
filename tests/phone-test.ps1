# The iPhone app (P1): irdash's phone side (dash\src\phone.cs) and the app (dash\www\phone) in headless Chrome at iPhone size.
#   1. the gate: no token = 401 for anything but the app itself and /phone/pair; the test hooks and /phone/qr are 404 from "a phone"
#      (?asphone=1 makes irdash treat this PC as a phone, stricter only)
#   2. pairing: a one-time code from /phone/qr (test hook), wrong code 403, right code = token (+cookie), the code is used up,
#      token works as ?t=, header and cookie, revoke = 401 again; the real LAN address when Peter has allowed it
#   3. the QR code decodes back to the app URL (a decoder written here: format info, unmask, zigzag read, Reed-Solomon check, bytes)
#   4. /api/do?c=key: only deck keys (keys\keys.map), nothing else runs
#   5. the app at 393x852: every page drawn, every button is a deck command (build-deck.ps1 keys / plugin.html commands), tap targets
#      >= 44 px, no overlaps, no JS errors, dry-run presses record the exact /api/do call, x2 keys ask again, the pair screen on 401
#   6. driving mode (pretend session): START keys and PC keys gone, replay dim, HOME's main button is RESET CAR
#   7. (PH-2) the layout of every screen on an iPhone SE, 14, 15 and Pro Max, portrait, and landscape, with the notch / Dynamic Island / home
#      indicator insets: nothing covered by the bars, scrolled to the end the last thing is fully above the tab bar, nothing wider than the
#      screen, no clipped or overlapping text, every control 48 px, every control sends what it says, no JS errors, no banned words
#      (docs\COPY-RULES.md). The data comes from tests\phone-layout.js (long names, many laps, every state), not from the PC.
# Pictures: tests\shots\phone-*.png (live app), tests\shots\phone2-<screen>-<size>.png and phone2-sheet*.png (layout). Needs the deployed irdash.
#   -LayoutOnly   section 7 only: static files and fixtures, never touches the sim, the hook or the rig, so it may run while Peter races.
# Sections 1-6 never while Peter races (guard.ps1).
param([switch]$LayoutOnly, [string[]]$Size = @(), [string[]]$Screen = @())   # -Size 375x667,852x393 / -Screen setup,clip: only those (to look at one thing quickly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guard.ps1')
if (-not $LayoutOnly) { Assert-RigFree }
$root = Split-Path -Parent $PSScriptRoot
$api = 'http://localhost:8199'
$shots = Join-Path $PSScriptRoot 'shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$script:ok = 0; $script:fail = 0
function Check($name, $cond, $detail = '') { if ($cond) { $script:ok++; Write-Output "  ok    $name" } else { $script:fail++; Write-Output "  FAIL  $name $detail" } }
function Section($t) { if (-not $LayoutOnly) { Assert-RigFree -Where $t }; Write-Output ''; Write-Output $t }
function Assert-RigFreeIf { if (-not $LayoutOnly) { Assert-RigFree -Where 'layout' } }
# a request that reports the status code instead of throwing
function Http($u, $headers = @{}) {
  try { $r = Invoke-WebRequest -UseBasicParsing $u -Headers $headers -TimeoutSec 30; return @{ code = [int]$r.StatusCode; body = $r.Content; headers = $r.Headers } }
  catch { $resp = $_.Exception.Response; if ($resp) { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); return @{ code = [int]$resp.StatusCode; body = $sr.ReadToEnd(); headers = @{} } }; return @{ code = 0; body = $_.Exception.Message; headers = @{} } }
}
# a bare request with any Host header (Invoke-WebRequest will not set Host): the status code only
function RawStatus($path, $hostHeader, $extra = '') {
  $c = New-Object Net.Sockets.TcpClient('127.0.0.1', 8199); $s = $c.GetStream(); $s.ReadTimeout = 5000
  $b = [Text.Encoding]::ASCII.GetBytes("GET $path HTTP/1.1`r`nHost: $hostHeader`r`n$($extra)Connection: close`r`n`r`n"); $s.Write($b, 0, $b.Length)
  $sr = New-Object IO.StreamReader($s); $line = $sr.ReadLine(); $c.Close()
  if ($line -match '^HTTP/1\.1 (\d+)') { return [int]$Matches[1] }; return 0
}

# ---- headless Chrome (DevTools protocol), iPhone 15 size portrait ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 393, $h = 852, $port = 9378) {
  $prof = Join-Path $env:TEMP ('phone-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0; errors = New-Object System.Collections.Generic.List[string] }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Runtime.enable' @{}
  $metrics = @{ width = $w; height = $h; deviceScaleFactor = 2; mobile = $true }
  if ($w -gt $h) { $metrics.screenOrientation = @{ type = 'landscapePrimary'; angle = 90 } } else { $metrics.screenOrientation = @{ type = 'portraitPrimary'; angle = 0 } }
  $null = Cdp 'Emulation.setDeviceMetricsOverride' $metrics
  $null = Cdp 'Emulation.setUserAgentOverride' @{ userAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1' }
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
    if ($o.method -eq 'Runtime.exceptionThrown') { $c.errors.Add($o.params.exceptionDetails.exception.description) }
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Json($expr) { return (Cdp-Eval "JSON.stringify($expr)") | ConvertFrom-Json }
# the same for an expression that returns a promise (JSON.stringify of a promise is {})
function Cdp-JsonAsync($expr) { $s = Cdp-Eval "(async () => JSON.stringify(await ($expr)))()"; if ("$s" -like 'js error*') { throw "$expr -> $s" }; if ($null -eq $s) { return $null }; return ,($s | ConvertFrom-Json) }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
function Wait-Until($expr, $secs = 15) { $until = (Get-Date).AddSeconds($secs); while ((Get-Date) -lt $until) { $v = Cdp-Eval $expr; if ($v -eq $true -or $v -eq 'true') { return $true }; Start-Sleep -Milliseconds 300 }; return $false }
# tap targets and overlaps of every visible button on the page as drawn now (the page is 852 tall; buttons further down are scrolled to)
$targetsJs = @'
(() => { const bs = Array.from(document.querySelectorAll('#main button, #main a.btn, #dock button, #tabs button')).filter(b => b.offsetParent !== null && b.getBoundingClientRect().width > 0);
  const rc = document.getElementById('scroll').getBoundingClientRect();   // a row scrolled out of the scroll area is not under the dock, it is clipped
  const r = bs.map(b => { const x = b.getBoundingClientRect(), inMain = b.closest('#main') !== null, tp = inMain ? Math.max(x.top, rc.top) : x.top, bt = inMain ? Math.min(x.bottom, rc.bottom) : x.bottom; return { t: (b.textContent || '').trim().slice(0, 20), w: x.width, h: x.height, l: x.left, r: x.right, tp: tp, bt: bt, off: bt <= tp, tab: b.closest('#tabs') !== null }; });
  const small = r.filter(x => x.w < 47.5 || x.h < 47.5).map(x => x.t + ' ' + Math.round(x.w) + 'x' + Math.round(x.h));
  const bad = []; const m = r.filter(x => !x.tab && !x.off);
  for (let i = 0; i < m.length; i++) for (let j = i + 1; j < m.length; j++) { const a = m[i], b = m[j]; const ox = Math.min(a.r, b.r) - Math.max(a.l, b.l), oy = Math.min(a.bt, b.bt) - Math.max(a.tp, b.tp); if (ox > 2 && oy > 2) bad.push(a.t + ' x ' + b.t); }
  const sc = document.getElementById('scroll'), wide = document.documentElement.scrollWidth > window.innerWidth + 1 || (sc && sc.scrollWidth > sc.clientWidth + 1);
  return { n: r.length, small: small, overlaps: bad, wide: wide }; })()
'@

# ---- the QR decoder (ISO 18004 layout, byte mode, level M, versions 1-6): proves the writer in phone.cs makes a symbol a camera reads ----
function GfMul($x, $y) { $z = 0; for ($i = 7; $i -ge 0; $i--) { $z = ($z -shl 1) -bxor (($z -shr 7) * 0x11D); $z = $z -bxor ((($y -shr $i) -band 1) * $x) }; return $z -band 0xFF }
function RsDivisor($degree) { $res = New-Object int[] $degree; $res[$degree - 1] = 1; $rootv = 1; for ($i = 0; $i -lt $degree; $i++) { for ($j = 0; $j -lt $degree; $j++) { $nx = if ($j + 1 -lt $degree) { $res[$j + 1] } else { 0 }; $res[$j] = (GfMul $res[$j] $rootv) -bxor $nx }; $rootv = GfMul $rootv 2 }; return $res }
function RsRemainder($data, $div) { $res = New-Object int[] $div.Length; foreach ($b in $data) { $factor = $b -bxor $res[0]; for ($i = 0; $i -lt $res.Length - 1; $i++) { $res[$i] = $res[$i + 1] }; $res[$res.Length - 1] = 0; for ($i = 0; $i -lt $res.Length; $i++) { $res[$i] = $res[$i] -bxor (GfMul $div[$i] $factor) } }; return $res }
function Qr-Decode($rows) {
  $n = [int]$rows.Count; $ver = [int](($n - 17) / 4)
  if ($ver -lt 1 -or $ver -gt 6 -or ($n - 17) % 4 -ne 0) { return @{ err = "odd size $n" } }
  $EcPerBlock = @(0, 10, 16, 26, 18, 24, 16); $NumBlocks = @(0, 1, 1, 1, 2, 2, 4); $Raw = @(0, 26, 44, 70, 100, 134, 172)
  $M = New-Object 'bool[,]' $n, $n; $F = New-Object 'bool[,]' $n, $n     # M[y,x] dark; F[y,x] function module
  for ($y = 0; $y -lt $n; $y++) { for ($x = 0; $x -lt $n; $x++) { $M[$y, $x] = $rows[$y][$x] -eq '1' } }
  for ($i = 0; $i -lt $n; $i++) { $F[6, $i] = $true; $F[$i, 6] = $true }
  # (arithmetic inside [a, b] and @(a, b) needs its own brackets: the comma binds tighter than minus in PowerShell)
  $n4 = $n - 4
  foreach ($c in @(@(3, 3), @($n4, 3), @(3, $n4))) { for ($dy = -4; $dy -le 4; $dy++) { for ($dx = -4; $dx -le 4; $dx++) { $xx = $c[0] + $dx; $yy = $c[1] + $dy; if ($xx -ge 0 -and $yy -ge 0 -and $xx -lt $n -and $yy -lt $n) { $F[$yy, $xx] = $true } } } }
  if ($ver -ge 2) { $a = $n - 7; for ($dy = -2; $dy -le 2; $dy++) { for ($dx = -2; $dx -le 2; $dx++) { $yy = $a + $dy; $xx = $a + $dx; $F[$yy, $xx] = $true } } }
  for ($i = 0; $i -le 8; $i++) { $F[$i, 8] = $true; $F[8, $i] = $true }
  for ($i = 0; $i -lt 8; $i++) { $e1 = $n - 1 - $i; $F[8, $e1] = $true; $F[$e1, 8] = $true }
  # the three finders must be there (a 7x7 ring with the 3x3 heart)
  $finders = 0
  foreach ($c in @(@(3, 3), @($n4, 3), @(3, $n4))) { $good = $true; for ($dy = -3; $dy -le 3; $dy++) { for ($dx = -3; $dx -le 3; $dx++) { $d = [math]::Max([math]::Abs($dx), [math]::Abs($dy)); $want = $d -ne 2; $yy = $c[1] + $dy; $xx = $c[0] + $dx; if ($M[$yy, $xx] -ne $want) { $good = $false } } }; if ($good) { $finders++ } }
  # format info (first copy), then its BCH check
  $bits = 0
  for ($i = 0; $i -le 5; $i++) { if ($M[$i, 8]) { $bits = $bits -bor (1 -shl $i) } }
  if ($M[7, 8]) { $bits = $bits -bor (1 -shl 6) }; if ($M[8, 8]) { $bits = $bits -bor (1 -shl 7) }; if ($M[8, 7]) { $bits = $bits -bor (1 -shl 8) }
  for ($i = 9; $i -lt 15; $i++) { $fx = 14 - $i; if ($M[8, $fx]) { $bits = $bits -bor (1 -shl $i) } }
  $fmt = $bits -bxor 0x5412; $data = $fmt -shr 10; $rem = $data
  for ($i = 0; $i -lt 10; $i++) { $rem = ($rem -shl 1) -bxor (($rem -shr 9) * 0x537) }
  $bchOk = ((($data -shl 10) -bor $rem) -eq $fmt)
  $mask = $data -band 7; $ec = $data -shr 3
  # read the data modules, unmasked, in the zigzag order
  $raw = $Raw[$ver]; $bytes = New-Object int[] $raw; $bi = 0
  for ($right = $n - 1; $right -ge 1; $right -= 2) {
    if ($right -eq 6) { $right = 5 }
    for ($vert = 0; $vert -lt $n; $vert++) {
      for ($j = 0; $j -lt 2; $j++) {
        $x = $right - $j; $up = ((($right + 1) -band 2) -eq 0); $y = if ($up) { $n - 1 - $vert } else { $vert }
        if ($F[$y, $x] -or $bi -ge $raw * 8) { continue }
        $inv = switch ($mask) { 0 { ($x + $y) % 2 -eq 0 } 1 { $y % 2 -eq 0 } 2 { $x % 3 -eq 0 } 3 { ($x + $y) % 3 -eq 0 } 4 { ([math]::Floor($x / 3) + [math]::Floor($y / 2)) % 2 -eq 0 } 5 { ($x * $y % 2 + $x * $y % 3) -eq 0 } 6 { (($x * $y % 2 + $x * $y % 3) % 2) -eq 0 } default { ((($x + $y) % 2 + $x * $y % 3) % 2) -eq 0 } }
        $dark = $M[$y, $x]; if ($inv) { $dark = -not $dark }
        if ($dark) { $bytes[[math]::Floor($bi / 8)] = $bytes[[math]::Floor($bi / 8)] -bor (1 -shl (7 - ($bi % 8))) }
        $bi++
      }
    }
  }
  # de-interleave into blocks, check every block's Reed-Solomon remainder, join the data
  $nb = [int]$NumBlocks[$ver]; $ecc = [int]$EcPerBlock[$ver]; $numShort = [int]($nb - $raw % $nb); $shortLen = [int][math]::Floor($raw / $nb); $padAt = $shortLen - $ecc
  $blocks = @(); for ($j = 0; $j -lt $nb; $j++) { $blocks += , (New-Object int[] ($shortLen + 1)) }
  $k = 0
  for ($i = 0; $i -le $shortLen; $i++) { for ($j = 0; $j -lt $nb; $j++) { if ($i -ne $padAt -or $j -ge $numShort) { $blocks[$j][$i] = $bytes[$k]; $k++ } } }
  $div = RsDivisor $ecc; $rsOk = $true; $dataBytes = @()
  for ($j = 0; $j -lt $nb; $j++) {
    $dl = $shortLen - $ecc; if ($j -ge $numShort) { $dl++ }
    $dat = $blocks[$j][0..($dl - 1)]; $e = $blocks[$j][($shortLen + 1 - $ecc)..$shortLen]
    $r = RsRemainder $dat $div
    for ($i = 0; $i -lt $ecc; $i++) { if ($r[$i] -ne $e[$i]) { $rsOk = $false } }
    $dataBytes += $dat
  }
  # mode 0100, 8-bit count, the bytes
  $bs = New-Object Text.StringBuilder; foreach ($b in $dataBytes) { [void]$bs.Append([Convert]::ToString($b, 2).PadLeft(8, '0')) }; $s = $bs.ToString()
  $mode = [Convert]::ToInt32($s.Substring(0, 4), 2); $len = [Convert]::ToInt32($s.Substring(4, 8), 2)
  $out = New-Object byte[] $len; for ($i = 0; $i -lt $len; $i++) { $out[$i] = [Convert]::ToInt32($s.Substring(12 + $i * 8, 8), 2) }
  return @{ text = [Text.Encoding]::UTF8.GetString($out); mode = $mode; ec = $ec; mask = $mask; bch = $bchOk; rs = $rsOk; finders = $finders; ver = $ver }
}

$lock = Join-Path $root 'dash\deploy.lock'
$hook = Join-Path $root 'dash\test-hook.on'
# other builders' tests run at the same time and remove the hook file in their own cleanup: put it back before every use
function Hook-On { if (-not (Test-Path $hook)) { New-Item -ItemType File -Force $hook | Out-Null; Start-Sleep -Milliseconds 300 } }
$deck = Get-Content (Join-Path $root 'build-deck.ps1') -Raw
$plugin = Get-Content (Join-Path $root 'deck-intro\plugin.html') -Raw
$token = $null; $token2 = $null
if (-not $LayoutOnly) { Enter-TestLock 'the phone test' }   # before the try: a test that could not get the lock must not clean up another test's files
try {
  if (-not $LayoutOnly) {
  Section '1. the gate: a phone without a token'
  Check 'state needs a token (401)' ((Http "$api/phone/state?asphone=1").code -eq 401)
  Check 'a command needs a token (401), nothing runs' ((Http "$api/api/do?c=key&a=mute&asphone=1").code -eq 401)
  Check 'the app itself is open (so it can pair)' ((Http "$api/phone/?asphone=1").code -eq 200 -and (Http "$api/phone/app.js?asphone=1").code -eq 200 -and (Http "$api/phone/icon.png?asphone=1").code -eq 200)
  Check 'the test hook is never there for a phone (404)' ((Http "$api/api/test/frame?asphone=1&IsOnTrack=1").code -eq 404 -and (Http "$api/api/test/end?asphone=1").code -eq 404)
  Check 'the pairing code is never there for a phone (404)' ((Http "$api/phone/qr?asphone=1").code -eq 404)
  Check 'a wrong token is a 401' ((Http "$api/phone/state?asphone=1&t=000000000000000000000000000000000000000000000000").code -eq 401)
  Check 'a Host that is not this PC is refused (403)' ((RawStatus '/phone/state' 'evil.example:8199') -eq 403 -and (RawStatus '/phone/state' 'localhost:8199') -eq 200)
  Check 'from this PC without the flag everything still works' ((Http "$api/phone/state").code -eq 200)
  # the last irdash start must not have logged the Phone.Sync error (it ran before Phone.Init set the folders)
  $log = @(Get-Content (Join-Path $root 'dash\irdash.log') -ErrorAction SilentlyContinue)
  $lastStart = -1; for ($i = 0; $i -lt $log.Count; $i++) { if ($log[$i] -match 'irdash starting on port') { $lastStart = $i } }
  $phoneErr = @($log | Select-Object -Skip ([math]::Max(0, $lastStart + 1)) | Where-Object { $_ -match 'phone: Value cannot be null' })
  Check 'irdash logged no phone error since its last start' ($lastStart -ge 0 -and $phoneErr.Count -eq 0) "$($phoneErr.Count) line(s)"

  Section '2. pairing'
  Set-Content $lock 'phone-test' -Encoding ASCII
  New-Item -ItemType File -Force $hook | Out-Null
  # a code stays valid for 10 minutes and allows 3 pairings, and /phone/qr keeps handing out the same valid code, so a code left by an
  # earlier run may already have uses in it: spend those here (the devices are named Test*, the finally revokes them); then /phone/qr gives a fresh code
  $old = (Http "$api/phone/qr?test=1").body | ConvertFrom-Json
  for ($k = 0; $k -lt 4 -and $old.code; $k++) { if ((Http "$api/phone/pair?asphone=1&code=$($old.code)&name=Test%20prep").code -ne 200) { break } }
  $q = (Http "$api/phone/qr?test=1"); $qr = $q.body | ConvertFrom-Json
  Check 'a one-time code and the QR rows come from /phone/qr' ($q.code -eq 200 -and $qr.code -match '^\d{6}$' -and $qr.rows.Count -gt 20 -and $qr.text -like '*/phone/?pair=*') "allowed=$($qr.allowed) lan=$($qr.lan) code=$($qr.code)"
  Check 'wrong code is refused (403)' ((Http "$api/phone/pair?asphone=1&code=000000").code -eq 403)
  $p = Http "$api/phone/pair?asphone=1&code=$($qr.code)&name=Test%20iPhone"; $pj = $null; try { $pj = $p.body | ConvertFrom-Json } catch { }
  Check 'right code pairs: 200 with a token' ($p.code -eq 200 -and $pj.ok -and $pj.token -match '^[0-9a-f]{48}$') "$($p.code) $($p.body)"
  Check 'the token also comes as a cookie' ("$($p.headers['Set-Cookie'])" -like 'pt=*')
  $token = $pj.token
  # Safari and the iPhone Home Screen app keep separate storage: the same code pairs up to 3 devices, then it is spent
  Check 'the same code pairs a 2nd and 3rd time (Home Screen app)' ((Http "$api/phone/pair?asphone=1&code=$($qr.code)&name=Test%20Home").code -eq 200 -and (Http "$api/phone/pair?asphone=1&code=$($qr.code)&name=Test%20Home2").code -eq 200)
  Check 'a 4th pairing with the same code is refused' ((Http "$api/phone/pair?asphone=1&code=$($qr.code)").code -eq 403)
  Check 'token as ?t= works' ((Http "$api/phone/state?asphone=1&t=$token").code -eq 200)
  Check 'token as header works' ((Http "$api/phone/state?asphone=1" @{ 'X-Paddock-Token' = $token }).code -eq 200)
  Check 'token as cookie works' ((RawStatus '/phone/state?asphone=1' 'localhost:8199' "Cookie: other=1; pt=$token`r`n") -eq 200)
  Check 'a paired phone still never reaches the test hook' ((Http "$api/api/test/frame?asphone=1&t=$token&IsOnTrack=1").code -eq 404)
  $dev = (Http "$api/phone/devices?asphone=1&t=$token").body | ConvertFrom-Json
  $me = $dev.devices | Where-Object { $_.name -eq 'Test iPhone' } | Select-Object -Last 1
  Check 'the phone is listed by name' ($null -ne $me)
  # a second token for the browser part, then revoke the first
  Hook-On; $qr2 = (Http "$api/phone/qr?test=1").body | ConvertFrom-Json
  $p2 = (Http "$api/phone/pair?asphone=1&code=$($qr2.code)&name=Test%20browser").body | ConvertFrom-Json; $token2 = $p2.token
  Check 'a fresh code pairs a second phone' ($token2 -match '^[0-9a-f]{48}$')
  $rv = (Http "$api/phone/revoke?id=$($me.id)&asphone=1&t=$token").body | ConvertFrom-Json
  Check 'revoke removes it' ($rv.removed -eq 1)
  Check 'the revoked token is a 401 again' ((Http "$api/phone/state?asphone=1&t=$token").code -eq 401)
  Check 'the other phone still works' ((Http "$api/phone/state?asphone=1&t=$token2").code -eq 200)
  # the LAN listeners start on irdash's 30 s pass (phone.cs Sync), so right after a start they are not up yet: once Peter has
  # allowed the LAN, wait up to 75 s for them; still not up then is a FAIL, not a skip
  $lanWanted = Test-Path (Join-Path $root 'dash\phone-allowed.txt'); $lanIp = ''
  $lanUntil = (Get-Date).AddSeconds(75)
  while ($true) {
    $st = (Http "$api/phone/state").body | ConvertFrom-Json   # read only: phone.allowed, phone.lan, phone.ip
    if ($st.phone.lan -and $st.phone.ip) { $lanIp = [string]$st.phone.ip; break }
    if (-not $lanWanted -or (Get-Date) -ge $lanUntil) { break }
    Start-Sleep -Seconds 3
  }
  if ($lanWanted) { Check 'the LAN listens once Peter has allowed it (tools\phone-allow.cmd)' ($lanIp -ne '') "allowed=$($st.phone.allowed) lan=$($st.phone.lan)" }
  if ($lanIp) {
    $lan = "http://$($lanIp):8199"
    Check "the real LAN address ($lanIp) needs a token" ((Http "$lan/phone/state").code -eq 401)
    Check 'the real LAN address works with the token' ((Http "$lan/phone/state?t=$token2").code -eq 200)
    Check 'the real LAN address never has the test hook' ((Http "$lan/api/test/end?t=$token2").code -eq 404)
  } else { Write-Output "  note  LAN not allowed (tools\phone-allow.cmd not run): the LAN address itself is not tested" }

  Section '3. the QR code decodes back to the app URL'
  $d = Qr-Decode $qr.rows
  Check "format info valid (BCH), level M, mask $($d.mask)" ($d.bch -and $d.ec -eq 0) "bch=$($d.bch) ec=$($d.ec)"
  Check 'three finder patterns' ($d.finders -eq 3)
  Check "Reed-Solomon check words agree (version $($d.ver))" ($d.rs -eq $true)
  Check 'byte mode, decodes to the exact URL + code' ($d.mode -eq 4 -and $d.text -eq $qr.text) "'$($d.text)' vs '$($qr.text)'"
  Check 'the URL is this PC on port 8199 and the pairing code' ($qr.text -match '^http://[0-9.]+:8199/phone/\?pair=\d{6}$')

  Section '4. /api/do?c=key runs deck keys only (nothing is started here)'
  Check 'an unknown key is refused (400 no)' ((Http "$api/api/do?c=key&a=not-a-key").code -eq 400)
  Check 'a path is refused' ((Http "$api/api/do?c=key&a=..%5Cirdeck").code -eq 400)
  Check 'an empty key is refused' ((Http "$api/api/do?c=key").code -eq 400)
  $map = Get-Content (Join-Path $root 'keys\keys.map') | Where-Object { $_ -match '=' } | ForEach-Object { ($_ -split '=')[0].Trim() }
  $notInMap = @(@('rig-on', 'test-drive', 'smart', 'get-out', 'tow', 'fuel-finish', 'vol-up', 'mute') | Where-Object { $map -notcontains $_ })
  Check 'keys.map has the deck keys the app offers' ($notInMap.Count -eq 0) ($notInMap -join ', ')

  Section '5. the app at iPhone size (393x852)'
  Cdp-Open "$api/phone/"
  $up = Wait-Until "typeof PhoneApp !== 'undefined' && !!PhoneApp.st" 15
  Check 'the app loads and hears from the PC' $up
  $null = Cdp-Eval "PhoneApp.dry = true; PhoneApp.sent = []; true"
  # every command the app can send is one the deck has: a MAIN/MORE key in build-deck.ps1, or a screen command in plugin.html
  $acts = Cdp-Json "PhoneApp.allActions()"
  $missing = @()
  foreach ($a in $acts) {
    if ($a.c -eq 'key') { if ($deck -notmatch [regex]::Escape("(L '$($a.a)'")) { $missing += "key $($a.a)" } }
    else { if ($plugin -notmatch [regex]::Escape("'$($a.c)'")) { $missing += $a.c } }
  }
  Check "every one of the $($acts.Count) commands is a deck command" ($missing.Count -eq 0) ($missing -join ', ')
  $meta = Cdp-Json "({ vp: document.querySelector('meta[name=viewport]').content, cap: !!document.querySelector('meta[name=apple-mobile-web-app-capable]'), bar: document.querySelector('meta[name=apple-mobile-web-app-status-bar-style]').content, icon: !!document.querySelector('link[rel=apple-touch-icon]'), man: !!document.querySelector('link[rel=manifest]'), dark: document.querySelector('meta[name=color-scheme]').content })"
  Check 'home-screen app: viewport-fit, apple meta, icon, manifest, dark' ($meta.vp -like '*viewport-fit=cover*' -and $meta.cap -and $meta.bar -eq 'black-translucent' -and $meta.icon -and $meta.man -and $meta.dark -eq 'dark')
  $pages = @('home', 'drive', 'sound', 'setup', 'laps', 'clips')
  foreach ($pg in $pages) {
    $null = Cdp-Eval "PhoneApp.show('$pg'); true"
    Start-Sleep -Seconds 3
    $drawn = Wait-Until "document.getElementById('main').children.length > 0" 10
    $t = Cdp-Json $targetsJs
    Check "$pg page: drawn, $($t.n) buttons all >= 48 px" ($drawn -and $t.small.Count -eq 0) ($t.small -join ', ')
    Check "$pg page: no overlapping buttons, no sideways scroll" ($t.overlaps.Count -eq 0 -and -not $t.wide) ($t.overlaps -join '; ')
    $cmds = Cdp-Json "PhoneApp.visibleActions()"
    if ($pg -in @('drive', 'sound', 'setup')) { Check "$pg page: has commands" ($cmds.Count -gt 3) "$($cmds.Count)" }
    Cdp-Shot (Join-Path $shots "phone-$pg.png")
  }
  Check 'no JS errors across the pages' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')
  # a dry-run press records the exact deck call and sends nothing
  $null = Cdp-Eval "PhoneApp.show('drive'); true"; Start-Sleep -Seconds 2
  $null = Cdp-Eval "PhoneApp.sent = []; document.querySelector('#main [data-c=key][data-a=vol-up]').click(); true"
  Start-Sleep -Milliseconds 300
  $sent = Cdp-Json "PhoneApp.sent"
  Check 'VOL + sends /api/do?c=key&a=vol-up (the deck key)' (@($sent) -contains '/api/do?c=key&a=vol-up') ("$sent")
  # the x2 keys, timed inside the page: press, a bounce 300 ms later (ignored), the real second press at 1.2 s (goes through)
  $x2 = Cdp-Eval "(async () => { const sel = '#main [data-c=key][data-a=restart-race]', w = ms => new Promise(r => setTimeout(r, ms)); PhoneApp.sent = []; document.querySelector(sel).click(); const label = document.querySelector(sel + ' b').textContent; await w(300); document.querySelector(sel).click(); const afterBounce = PhoneApp.sent.length; await w(900); document.querySelector(sel).click(); await w(100); return { label, afterBounce, total: PhoneApp.sent.length, urls: PhoneApp.sent }; })()"
  Check 'an x2 key asks "Again?" and ignores a bounce inside 0.75 s' ($x2.label -eq 'Again?' -and $x2.afterBounce -eq 1) "'$($x2.label)' sent=$($x2.afterBounce)"
  Check 'the second press within 3 s goes through (the deck''s x2)' ($x2.total -eq 2 -and @($x2.urls | Where-Object { $_ -ne '/api/do?c=key&a=restart-race' }).Count -eq 0) "total=$($x2.total)"
  $null = Cdp-Eval "PhoneApp.show('setup'); true"
  $mdo = Wait-Until "PhoneApp.sent.indexOf('/api/do?c=mdopen') >= 0" 5
  Check 'SETUP tells the top screen (mdopen) like the deck' $mdo ("sent=" + (Cdp-Eval "JSON.stringify(PhoneApp.sent)") + " page=" + (Cdp-Eval "PhoneApp.page"))
  $null = Cdp-Eval "PhoneApp.show('sound'); true"; Start-Sleep -Seconds 3
  $sndN = Cdp-Json "PhoneApp.visibleActions().filter(a => a.c === 'sndvol').length"
  Check 'SOUND shows the levels with up / down' ($sndN -ge 4) "$sndN"
  # the pair screen: the app loaded "as a phone" with no token gets a 401 and asks to pair
  Cdp-Close
  Cdp-Open "$api/phone/?asphone=1"
  $pairShown = Wait-Until "!!document.getElementById('pairCode')" 15
  Check 'a phone without a token sees the pair screen' $pairShown
  $t = Cdp-Json $targetsJs
  Check 'pair screen: targets >= 48 px, no overlaps' ($t.small.Count -eq 0 -and $t.overlaps.Count -eq 0) ($t.small -join ', ')
  Cdp-Shot (Join-Path $shots 'phone-pair.png')
  $null = Cdp-Eval "document.getElementById('pairCode').value = '000000'; document.querySelector('[data-pair-go]').click(); true"
  $err = Wait-Until "!!document.querySelector('.pair .err')" 8
  Check 'a wrong code says so, plainly' $err
  Hook-On; $qr3 = (Http "$api/phone/qr?test=1").body | ConvertFrom-Json
  $null = Cdp-Eval "document.getElementById('pairCode').value = '$($qr3.code)'; document.querySelector('[data-pair-go]').click(); true"
  $paired = Wait-Until "PhoneApp.paired === true && !!PhoneApp.st" 12
  Check 'the right code pairs from the app and it comes alive' $paired
  $devId3 = Cdp-Eval "PhoneApp.devId || ''"
  Check 'the saved address carries the token for the home-screen app' ((Cdp-Eval "location.search.indexOf('t=') >= 0") -eq $true)
  Check 'no JS errors on the pair screen' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')

  Section '6. driving mode (pretend session): only what the deck allows'
  $null = Cdp-Eval "PhoneApp.dry = true; PhoneApp.sent = []; true"
  Hook-On
  $r = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?IsOnTrack=1&Speed=42&SessionNum=0&Lap=2&SessionTime=120&FuelLevel=30" -TimeoutSec 20
  $drv = Wait-Until "PhoneApp.st && PhoneApp.st.onTrack === true" 12
  Check 'the app sees him in the car' $drv
  $null = Cdp-Eval "PhoneApp.show('home'); true"; Start-Sleep -Seconds 2
  $big = Cdp-Json "({ a: document.querySelector('.big').dataset.a, pit: !!document.querySelector('#main [data-a=fuel-finish]') })"
  Check 'HOME in the car: the big button is RESET CAR, the pit row is there' ($big.a -eq 'tow' -and $big.pit) "$($big.a)"
  Cdp-Shot (Join-Path $shots 'phone-driving.png')
  $null = Cdp-Eval "PhoneApp.show('drive'); true"; Start-Sleep -Seconds 3
  $vis = Cdp-Json "PhoneApp.visibleActions()"
  $gone = @('rig-on', 'test-drive', 'smart', 'showcase', 'sleep', 'lock') | Where-Object { $n = $_; @($vis | Where-Object { $_.c -eq 'key' -and $_.a -eq $n }).Count -gt 0 }
  Check 'START and PC keys are gone while driving' ($gone.Count -eq 0) ($gone -join ', ')
  Check 'pit, chat and volume keys stay' (@($vis | Where-Object { $_.c -eq 'key' -and $_.a -in @('fuel-finish', 'say-sorry', 'vol-up', 'get-out', 'tow') }).Count -eq 5)
  $null = Cdp-Eval "PhoneApp.setSeg('drive', 'replay'); true"; Start-Sleep -Seconds 2
  $vis = Cdp-Json "PhoneApp.visibleActions()"
  $rp = @($vis | Where-Object { $_.c -like 'rp*' })
  Check 'replay keys are dim and disabled while driving' ($rp.Count -gt 0 -and @($rp | Where-Object { -not $_.disabled }).Count -eq 0) "$($rp.Count) keys"
  Check 'the server refuses RIG ON while driving (400)' ((Http "$api/api/do?c=key&a=rig-on").code -eq 400)
  Check 'the server refuses LAST DRIVE while driving (400)' ((Http "$api/api/do?c=key&a=test-drive-last").code -eq 400)
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 20
  $backOk = Wait-Until "PhoneApp.st && PhoneApp.st.onTrack === false" 12
  Check 'back out of the car, the app follows' $backOk
  Check 'no JS errors in driving mode' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')
  Cdp-Close
  }   # end of sections 1-6 (they need the rig; -LayoutOnly skips them)

  Section '7. layout: every screen on iPhone SE, 14, 15, Pro Max (portrait) and 15 landscape, with the notch and home-indicator insets'
  $layoutJs = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'phone-layout.js'), [Text.Encoding]::UTF8)
  # the copy rules (docs\COPY-RULES.md), the same table tests\copy-audit-test.ps1 uses
  $emoji = '[☀-☄☇-➿⭐⭕]|[\uD83C-\uD83E][\uDC00-\uDFFF]'
  $banned = [ordered]@{
    'addresses him'      = "(?i)\byou(?:r|rs|rself|'re|'ve|'ll|’re|’ve|’ll)?\b"
    'greeting'           = '(?i)\bgood (?:morning|afternoon|evening|night)\b|\bwelcome\b|\bready when\b|\bwhen you\b|\bhello\b'
    'filler word'        = '(?i)\b(?:just|simply|quietly|let''s|here''s|insights?|journey|stories|story|by itself|by themselves|automatically)\b'
    'exclamation'        = '[A-Za-z0-9\)\]]!(?:\s|$|["''<])'
    'dash aside'         = '—|[A-Za-z0-9\.\)] – [A-Za-z]|[a-z]{3,} - [A-Za-z]{3,}'
    'emoji'              = $emoji
    'how it is computed' = '(?i)outline from|from your own|sampled \d|explains \d|is the mean|mean over|worked out from|last time here|first time here|as of last'
    'hint or caption'    = '(?i)\b(?:tap to|press to|tip:|hint:|reading the|looking for|one moment|please)\b'
  }
  function Banned-Hits([string]$t) { $h = @(); foreach ($k in $banned.Keys) { if ([regex]::IsMatch($t, $banned[$k])) { $h += $k } }; return $h }
  # what each control must say for what it sends (the deck's own words); read from the page's own labels
  $keyWords = @{ 'rig-on' = '^rig on$'; 'test-drive' = '^test drive$'; 'smart' = '^get in$'; 'get-out' = '^get out$'; 'tow' = '^reset car$'; 'keep-lap' = '^keep lap$'; 'tv' = '^tv$'; 'reset-save' = '^mark spot$'; 'reset-run' = '^back to spot$';
    'restart-race' = '^restart$'; 'skip-session' = '^skip$'; 'quit-main' = '^quit$'; 'fuel-finish' = '^fuel$'; 'pit-tires' = '^tires$'; 'pit-clear' = '^clear$'; 'pit-fr' = '^repair$'; 'pit-ws' = '^wipe$'; 'seat-down' = '^seat down$'; 'seat-up' = '^seat up$';
    'say-sorry' = '^sorry$'; 'say-thanks' = '^thanks$'; 'say-gg' = '^good race$'; 'vol-down' = '^game .$'; 'vol-up' = '^game \+$'; 'mute' = '^mute pc$'; 'bb-f3' = '^relative$'; 'bb-f1' = '^timing$'; 'bb-f2' = '^standings$'; 'bb-f4' = '^fuel$';
    'bb-f5' = '^tires$'; 'bb-f8' = '^in-car$'; 'bb-f11' = '^weather$'; 'showcase' = '^showcase$'; 'sleep' = '^sleep pc$'; 'lock' = '^lock pc$' }
  $lt = [regex]::Unescape('‹'); $gt = [regex]::Unescape('›'); $minus = [regex]::Unescape('−')
  $cmdWords = @{ rpplay = '^play / pause$'; rpback10 = "^${minus}10 s$"; rprew = '^rewind$'; rpfast = '^forward$'; rpslow = '^slow motion$'; rplive = '^live$'; rplapprev = "^lap ${lt}$"; rplapnext = "^lap ${gt}$"; rpincprev = "^incident ${lt}$"; rpincnext = "^incident ${gt}$";
    rpmyinc = '^my last incident$'; rpphoto = '^photo$'; rpmycar = '^my car$'; rpahead = '^car ahead$'; rpbehind = '^car behind$'; rpleader = '^leader$'; rpcamnext = '^next camera$'; rphideui = '^hide menus$';
    deltaon = '^delta bar$'; deltaref = '^vs$'; sndmute = '^mute$'; mdstart = '^start$'; mdcancel = '^cancel$'; mdgetout = '^get out$'; mdtow = '^reset car$'; mddamage = '^damage$'; mdstar = '^favourite$'; mdclear = '^clear$'; mdfindlayout = '^layout$' }
  $sizes = @(
    @{ n = '375x667'; w = 375; h = 667; top = 20; bottom = 0; left = 0; right = 0; end = $true },        # iPhone SE: status bar only, no home indicator
    @{ n = '390x844'; w = 390; h = 844; top = 47; bottom = 34; left = 0; right = 0; end = $false },      # iPhone 14: notch
    @{ n = '393x852'; w = 393; h = 852; top = 59; bottom = 34; left = 0; right = 0; end = $false },      # iPhone 15: Dynamic Island
    @{ n = '430x932'; w = 430; h = 932; top = 59; bottom = 34; left = 0; right = 0; end = $false },      # Pro Max
    @{ n = '852x393'; w = 852; h = 393; top = 0; bottom = 21; left = 59; right = 59; end = $true }       # iPhone 15 landscape
  )
  $screens = @('home-idle', 'home-off', 'home-lost', 'home-session', 'home-driving', 'drive-keys', 'drive-replay', 'drive-replay-driving', 'drive-overlays', 'sound', 'setup', 'setup-driving', 'laps-sessions', 'laps-detail', 'laps-videos', 'clip', 'clip-done', 'pair')
  if ($Size.Count) { $sizes = @($sizes | Where-Object { $Size -contains $_.n }) }; if ($Screen.Count) { $screens = @($screens | Where-Object { $Screen -contains $_ }) }
  $errCount = @{}; $nStates = 0; $scrolled = 0; $minLast = 999; $bannedHits = @(); $jsErr = @(); $ctlBad = @(); $ctlN = 0; $ctlScreens = 0; $insetMode = @{}; $shotFiles = @{}
  foreach ($sz in $sizes) {
    Assert-RigFreeIf
    # the app as a phone with no token (?asphone=1): every request is answered by the fixture, nothing is read from the PC
    Cdp-Open "$api/phone/?asphone=1" $sz.w $sz.h (9400 + (Get-Random -Maximum 90))
    $null = Wait-Until "typeof PhoneApp !== 'undefined' && !!document.getElementById('main')" 15
    $null = Cdp 'Emulation.setSafeAreaInsetsOverride' @{ insets = @{ top = $sz.top; bottom = $sz.bottom; left = $sz.left; right = $sz.right } }
    $probe = Cdp-Eval "(() => { const d = document.createElement('div'); d.style.cssText = 'position:fixed;top:0;left:0;padding:env(safe-area-inset-top,0px) 0 env(safe-area-inset-bottom,0px) env(safe-area-inset-left,0px)'; document.body.appendChild(d); const c = getComputedStyle(d); const v = c.paddingTop + '/' + c.paddingBottom + '/' + c.paddingLeft; d.remove(); return v; })()"
    $want = "$($sz.top)px/$($sz.bottom)px/$($sz.left)px"
    if ($probe -eq $want) { $insetMode[$sz.n] = 'env()' }
    else {   # the browser did not take the override: set the custom properties the app reads
      $null = Cdp-Eval "(() => { const s = document.documentElement.style; s.setProperty('--sat', '$($sz.top)px'); s.setProperty('--sab', '$($sz.bottom)px'); s.setProperty('--sal', '$($sz.left)px'); s.setProperty('--sar', '$($sz.right)px'); return true; })()"
      $insetMode[$sz.n] = 'css variables'
    }
    $null = Cdp-Eval $layoutJs
    $ok7 = Cdp-Eval "typeof window.__setScreen === 'function'"
    if ($ok7 -ne $true) { Check "$($sz.n): the layout helpers load" $false "$ok7"; Cdp-Close; continue }
    foreach ($sc in $screens) {
      $null = Cdp-Eval "window.__setScreen('$sc').then(() => true)"
      $r = Cdp-JsonAsync "window.__check()"
      $nStates++
      if ($r.scrollable) { $scrolled++ }
      if ($r.lastGap -lt $minLast -and -not $r.pairing) { $minLast = $r.lastGap }
      foreach ($e in @($r.errs)) { $k = ($e -split ':')[0]; if (-not $errCount.ContainsKey($k)) { $errCount[$k] = New-Object System.Collections.Generic.List[string] }; $errCount[$k].Add("$($sz.n) $sc $e") }
      Check "$($sz.n) $sc`: $($r.vw)x$($r.vh), $($r.controls) controls, insets $($r.sat)/$($r.sab)/$($r.sal)/$($r.sar), $(if ($r.scrollable) { "scrolls $($r.scrollMax) px, last item $($r.lastGap) px above the bar" } else { 'fits without scrolling' })" (@($r.errs).Count -eq 0) ((@($r.errs) | Select-Object -First 4) -join ' | ')
      foreach ($t in @($r.texts)) { $h = Banned-Hits ([string]$t); if ($h.Count) { $bannedHits += "$($sz.n) $sc '$t' <- $($h -join ', ')" } }
      $f = Join-Path $shots "phone2-$sc-$($sz.n).png"; Cdp-Shot $f; $shotFiles["$sc|$($sz.n)"] = $f
      if ($sz.end) { $null = Cdp-Eval "window.__scrollEnd().then(() => true)"; Cdp-Shot (Join-Path $shots "phone2-$sc-$($sz.n)-end.png"); $null = Cdp-Eval "window.__scrollTop().then(() => true)" }
      # every control, once, on the 390 x 844 phone: it sends the exact deck call and says what it does
      if ($sz.n -eq '390x844' -and $sc -ne 'pair') {
        $ctl = @((Cdp-JsonAsync "window.__controls()") | ForEach-Object { $_ } | Where-Object { $_ })
        $ctlScreens++
        foreach ($c in $ctl) {
          $ctlN++
          if (-not $c.ok) { $ctlBad += "$sc $($c.c)/$($c.a): sent '$($c.got)'"; continue }
          $want = $null
          if ($c.c -eq 'key') { $want = $keyWords[$c.a]; if (-not $want) { $ctlBad += "$sc unknown key $($c.a)" } }
          elseif ($c.c -eq 'ovpreset' -or $c.c -eq 'sndpreset') { $want = '^' + [regex]::Escape($c.a) + '$' }
          elseif ($c.c -eq 'sndvol') { $want = if ($c.a -like '*:-10') { '^' + $minus + '$' } else { '^\+$' } }
          elseif ($cmdWords.ContainsKey($c.c)) { $want = $cmdWords[$c.c] }
          if ($want -and $c.label -notmatch $want) { $ctlBad += "$sc $($c.c)/$($c.a): the button says '$($c.label)'" }
          if ($c.x2 -and $c.after -ne 'Again?') { $ctlBad += "$sc $($c.a): a x2 key did not ask again" }
        }
      }
    }
    $jsErr += @($script:cdp.errors | ForEach-Object { "$($sz.n): $_" })
    Cdp-Close
  }
  Write-Output ''
  Write-Output "  summary over $nStates screen states ($($sizes.Count) sizes x $($screens.Count) screens); safe-area insets by $((($insetMode.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '))"
  foreach ($k in @('page scrolls sideways', 'page scrolls down', 'scroll area scrolls sideways', 'strip not at the top', 'tab bar not at the bottom', 'scroll area under the strip', 'scroll area under the dock / tab bar', 'dock under the tab bar', 'hidden dock still takes space', 'empty dock',
      'strip padding is less than the top inset', 'tab under the home indicator', 'tab outside the side insets', 'more than 5 tabs', 'first element above the scroll area', 'last element under the bar', 'last element cut off',
      'text off the screen', 'text inside the notch side', 'text clipped by its box', 'text wider than its box', 'word split across lines', 'text overlaps text', 'control under 48 px', 'control off the screen', 'controls overlap', 'box wider than the screen', 'box outside its parent')) {
    $n = if ($errCount.ContainsKey($k)) { $errCount[$k].Count } else { 0 }
    Check "never: $k" ($n -eq 0) (($errCount[$k] | Select-Object -First 3) -join ' | ')
  }
  Check "the end-of-scroll test ran on real scrolling ($scrolled of $nStates states scroll; the smallest gap above the bar is $minLast px)" ($scrolled -gt ($nStates / 3) -and $minLast -ge 0)
  Check 'no JS errors on any screen at any size' ($jsErr.Count -eq 0) ($jsErr -join ' | ')
  Check "no banned word on any screen (docs\COPY-RULES.md; $nStates states)" ($bannedHits.Count -eq 0) (($bannedHits | Select-Object -First 8) -join ' | ')
  Check "every one of $ctlN controls on $ctlScreens screens sends the exact deck call and says what it does" ($ctlBad.Count -eq 0 -and $ctlN -gt 100) "$(($ctlBad | Select-Object -First 8) -join ' | ') ($ctlN pressed)"
  # the CSS rules that make it iOS-proof: all four safe-area insets, dynamic viewport units (no plain 100vh), no page-level elastic scroll, one scroll area
  $css = [IO.File]::ReadAllText((Join-Path $root 'dash\www\phone\app.css'))
  $scrollers = @([regex]::Matches($css, '(?m)^([^{}\n]+)\{[^}]*overflow-y:\s*(?:auto|scroll)') | ForEach-Object { $_.Groups[1].Value.Trim() })
  $iosMiss = @(@('safe-area-inset-top', 'safe-area-inset-bottom', 'safe-area-inset-left', 'safe-area-inset-right', '100dvh', 'overscroll-behavior', '-webkit-overflow-scrolling: touch', 'position: fixed; inset: 0') | Where-Object { $css.IndexOf($_) -lt 0 })
  Check "CSS: all four safe-area insets, 100dvh, overscroll-behavior, touch scrolling, a fixed shell; no 100vh; ONE scroll area ($($scrollers -join ', '))" ($iosMiss.Count -eq 0 -and $css -notmatch '100vh' -and $scrollers.Count -eq 1 -and $scrollers[0] -eq '#scroll') ("missing: $($iosMiss -join ', ') scrollers: $($scrollers -join ', ')")
  # every string in the app's own files against the same words (the states that are not on screen right now)
  $srcBad = @(); $nStr = 0
  $strRx = New-Object Text.RegularExpressions.Regex("'((?:[^'\\\r\n]|\\.)*)'|""((?:[^""\\\r\n]|\\.)*)""", 'Singleline')
  foreach ($fn in 'app.js', 'index.html') {
    $txt = [IO.File]::ReadAllText((Join-Path $root "dash\www\phone\$fn")).Replace("`r`n", "`n")
    $txt = [regex]::Replace($txt, '(?s)/\*.*?\*/', { param($m) $m.Value -replace '[^\n]', ' ' }); $txt = [regex]::Replace($txt, '(?s)<!--.*?-->', ' ')
    $txt = [regex]::Replace($txt, '(?m)^\s*//.*$', ''); $txt = [regex]::Replace($txt, '(?<=\s)//\s.*$', '', 'Multiline')
    foreach ($m in $strRx.Matches($txt)) { $s = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }; if ($s.Length -lt 4 -or $s -notmatch '[A-Za-z]{3}') { continue }; $s = [regex]::Replace($s, '<[^>]*>', ' '); $nStr++; $h = Banned-Hits $s; if ($h.Count) { $srcBad += "$fn '$($s.Trim())' <- $($h -join ', ')" } }
  }
  Check "no banned word in the $nStr strings of app.js and index.html" ($srcBad.Count -eq 0) (($srcBad | Select-Object -First 6) -join ' | ')

  Section '7b. behaviour: going in and out of pages, what a redraw leaves alone (393x852)'
  Assert-RigFreeIf
  Cdp-Open "$api/phone/?asphone=1" 393 852 (9400 + (Get-Random -Maximum 90))
  $null = Wait-Until "typeof PhoneApp !== 'undefined' && !!document.getElementById('main')" 15
  $null = Cdp 'Emulation.setSafeAreaInsetsOverride' @{ insets = @{ top = 59; bottom = 34; left = 0; right = 0 } }
  $null = Cdp-Eval $layoutJs
  $fl = Cdp-JsonAsync "window.__flows()"
  $flowNames = [ordered]@{
    detailOpens = 'a session opens with a Back button and one history step'; detailTop = 'it opens at the top'; backList = 'Back returns to the list at the same scroll position'; swipeBack = 'the iPhone swipe-back closes it instead of leaving the app';
    tabAgain = 'the Laps tab pressed again returns to the list'; lastRow = 'HOME offers the last session'; lastOpens = 'it opens in Laps with Back = Home'; lastBack = 'Back returns to HOME';
    forgetArms = 'Forget asks first (Again?)'; forgetDoes = 'the second press forgets the phone'; searchKept = 'a redraw keeps the search box, its text and focus'; searchLocal = 'typing filters on the phone and sends nothing'; searchPicks = 'a tap on a result picks that drive';
    noRepaint = 'an unchanged poll replaces nothing'; fingerHolds = 'a changed poll waits while a finger is down, then draws'; scrollKept = 'the scroll position survives a redraw';
    driveSegs = 'DRIVE has Keys, Replay, Overlays'; replayShown = 'Replay shows its 18 keys'; overlaysShown = 'Overlays shows presets and widgets'; replayDim = 'Replay is dim and disabled while driving'; drivingKeys = 'START and PC keys are gone while driving';
    toastFits = 'a message shows inside the screen above the dock'; toastBad = 'an error message is red';
    shareAsks = 'MAKE SHARE VIDEO asks the PC and shows progress'; tabs = 'five tabs, each opens its page, one marked'; x2Arms = 'an x2 key arms: Again? and one call'; x2Disarms = 'it disarms after 3 s'
  }
  foreach ($k in $flowNames.Keys) { Check $flowNames[$k] ($fl.$k -eq $true) "got '$($fl.$k)'" }
  Check 'no JS errors in these flows' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')
  Cdp-Close

  Section '7c. pictures'
  Add-Type -AssemblyName System.Drawing
  function Make-Sheet($tag, $outName, $cols, $cw) {
    $files = @($screens | ForEach-Object { $shotFiles["$_|$tag"] } | Where-Object { $_ -and (Test-Path $_) })
    if (-not $files.Count) { return $null }
    $first = [Drawing.Image]::FromFile($files[0]); $ch = [int]($cw * $first.Height / $first.Width); $first.Dispose()
    $lab = 22; $rows = [math]::Ceiling($files.Count / $cols)
    $bmp = New-Object Drawing.Bitmap ($cols * ($cw + 8) + 8), ($rows * ($ch + $lab + 8) + 8)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::FromArgb(8, 8, 10)); $g.InterpolationMode = 'HighQualityBicubic'
    $font = New-Object Drawing.Font 'Segoe UI', 10; $br = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(212, 175, 55)); $i = 0
    foreach ($f in $files) {
      $img = [Drawing.Image]::FromFile($f); $x = 8 + ($i % $cols) * ($cw + 8); $y = 8 + [math]::Floor($i / $cols) * ($ch + $lab + 8)
      $g.DrawString(([IO.Path]::GetFileNameWithoutExtension($f) -replace '^phone2-', ''), $font, $br, $x, $y); $g.DrawImage($img, $x, $y + $lab, $cw, $ch); $img.Dispose(); $i++
    }
    $g.Dispose(); $out = Join-Path $shots $outName; $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); return $out
  }
  $s1 = Make-Sheet '390x844' 'phone2-sheet.png' 6 240
  Check 'contact sheet phone2-sheet.png (390x844, every screen)' ($s1 -and (Test-Path $s1))
  $null = Make-Sheet '375x667' 'phone2-sheet-se.png' 6 240
  $null = Make-Sheet '852x393' 'phone2-sheet-landscape.png' 4 400
  $null = Make-Sheet '430x932' 'phone2-sheet-promax.png' 6 240
  Check "$($shotFiles.Count) pictures written (tests\shots\phone2-<screen>-<size>.png)" ($shotFiles.Count -eq $screens.Count * $sizes.Count)

  Section '8. SETUP search: the fragment filters the drives /mydrive offers on the phone itself (1,000 fixture drives)'
  Assert-RigFreeIf
  Cdp-Open "$api/phone/?asphone=1" 393 852 (9400 + (Get-Random -Maximum 90))
  $null = Wait-Until "typeof PhoneApp !== 'undefined' && !!document.getElementById('main')" 15
  # 1,000 real pick rows plus a stale incomplete row; no PC, no iRacing UI, no request per keystroke
  $null = Cdp-Eval @'
(() => {
  const cars = ['Chevrolet Corvette Z06 GT3.R', 'Ferrari 296 GT3', 'BMW M4 GT3', 'Porsche 911 GT3 R (992)', 'Mercedes-AMG GT3 2020 EVO', 'McLaren 720S GT3 EVO', 'Audi R8 LMS GT3', 'Lamborghini Huracan GT3 EVO2'];
  const tracks = ['Road Atlanta', 'Sebring International Raceway', 'Lime Rock Park', 'Circuit de Spa-Francorchamps', 'Nordschleife Industriefahrten', 'Watkins Glen International', 'Virginia International Raceway', 'Long Beach Street Circuit'];
  const list = [];
  for (let i = 0; i < 1000; i++) { const car = cars[i % cars.length], track = tracks[(i * 3) % tracks.length];
    list.push({ id: 'r' + ('00000000' + i.toString(16)).slice(-8), car: car, carShort: car, track: track, trackShort: track, ago: 'today', chosen: false }); }
  list[0] = { id: 'r00000000', car: 'Chevrolet Corvette Z06 GT3.R', carShort: 'CORVETTE GT3', track: 'Road Atlanta', trackShort: 'ROAD ATLANTA', ago: 'today', chosen: false };
  list.push({ id: 'rdeadbeef', car: 'Chevrolet Corvette Z06 GT3.R', carShort: 'CORVETTE GT3', track: '', trackShort: '', ago: 'today', chosen: false });
  window.__searchState = { list: list, chosen: null, rejectPick: false, starts: [] };
  window.__md = () => { const ch = window.__searchState.chosen;
    return { ready: true, open: true, session: false, driving: false, busy: '', phase: '', msg: '',
      choice: { has: !!ch, car: ch ? ch.car : '', carShort: ch ? ch.carShort : '', track: ch ? ch.track : '', trackShort: ch ? ch.trackShort : '', layout: ch ? ch.track : '', damage: 'off', fav: false },
      all: window.__searchState.list, recent: window.__searchState.list.slice(0, 7), favs: [], gain: null, results: null, current: null, draft: null }; };
  const st = { t: Date.now(), connected: false, onTrack: false, driving: false, replay: false, track: '', car: '', session: '', pos: 0, lap: 0, inc: 0, speed: 0, fuel: 0, best: 0, last: 0, pits: false, towWait: false, nav: { to: '', seq: 0, driving: false }, phone: { allowed: true, lan: true, paired: 1 }, health: { apps: [{ id: 'deck', name: 'Stream Deck', state: 'ok' }, { id: 'ui', name: 'iRacing UI', state: 'ok' }, { id: 'sim', name: 'Sim', state: 'off' }] } };
  PhoneApp.dbCheckedOffline = true; PhoneApp.db = null;   // D-05: an offline poll opens the session debrief by itself; this section tests SETUP
  PhoneApp.mock = url => { const p = url.split('?')[0];
    if (p === '/phone/state') return st;
    if (p === '/mydrive') return window.__md();
    if (p === '/api/do') { const id = decodeURIComponent((url.split('a=')[1] || '')).split('&')[0]; const hit = window.__searchState.list.find(x => x.id === id); if (url.indexOf('c=mdpick') >= 0) { if (window.__searchState.rejectPick || !hit || !hit.car || !hit.track) return null; window.__searchState.chosen = hit; } if (url.indexOf('c=mdstart') >= 0) { const c = window.__searchState.chosen; if (!c || !c.car || !c.track) return null; window.__searchState.starts.push({ car: c.car, track: c.track }); } return true; }
    return null; };
  return true;
})()
'@
  # 10 common fragments: the drive they name must come back first
  $null = Cdp-Eval "PhoneApp.md = window.__md(); PhoneApp.q = ''; true"
  $combos = Cdp-Json "[['atl','Road Atlanta'],['cor','Corvette Z06 GT3.R'],['seb','Sebring'],['lim','Lime Rock'],['spa','Spa-Francorchamps'],['nord','Nordschleife'],['wat','Watkins Glen'],['vir','Virginia'],['bmw','BMW M4 GT3'],['fer','Ferrari 296 GT3']].map(p => { const r = PhoneApp.filterCombos(p[0]); return { f: p[0], want: p[1], first: r.length ? (r[0].car + ' \u00b7 ' + r[0].track) : '', n: r.length }; })"
  $miss = @($combos | Where-Object { $_.n -lt 1 -or $_.first -notmatch [regex]::Escape($_.want) })
  Check "10 common fragments each name their drive first" ($miss.Count -eq 0) (($miss | ForEach-Object { "$($_.f)->$($_.first)" }) -join '; ')
  # 1,000 fixture drives filtered on the phone in one pass
  $perf = Cdp-Json "(function(){ const t0 = performance.now(); const r = PhoneApp.filterCombos('atl'); return { ms: performance.now() - t0, n: r.length, total: PhoneApp.comboList().length }; })()"
  Check "1,000 drives filter in <= 100 ms ($($perf.n) matches of $($perf.total))" ($perf.ms -le 100 -and $perf.total -eq 1000) "$([math]::Round($perf.ms,2)) ms"
  # the user journey selects the intended Corvette/Road Atlanta pair, then starts it: two action taps
  $atl = Cdp-JsonAsync @'
(async () => {
  const A = PhoneApp, w = ms => new Promise(r => setTimeout(r, ms));
  A.dry = false; A.paired = true; A.sent = []; A.q = ''; A.md = null; A.autoId = '';
  A.show('setup');
  for (let i = 0; i < 60 && !A.md; i++) await w(25);
  const inp = document.getElementById('findText');
  if (!inp) return { err: 'no search box' };
  const t0 = performance.now();
  inp.value = 'atl'; inp.dispatchEvent(new Event('input', { bubbles: true })); await w(40);
  const row = document.querySelector('#uFound .row');
  const first = row ? row.textContent.replace(/\s+/g, ' ').trim() : '';
  const nRows = document.querySelectorAll('#uFound .row').length;
  let taps = 0;
  const target = Array.from(document.querySelectorAll('#uFound .row')).find(b => b.textContent.indexOf('Corvette') >= 0 && b.textContent.indexOf('Road Atlanta') >= 0);
  if (target) { target.click(); taps++; await A.poll(); await w(40); }
  const selected = window.__searchState.chosen;
  const start = document.querySelector('#dock .big[data-c=mdstart]');
  const lit = !!start && !start.disabled;
  if (start && lit) { start.click(); taps++; }
  await w(30);
  return { first: first, n: nRows, taps: taps, lit: lit, car: selected && selected.car, track: selected && selected.track, starts: window.__searchState.starts.slice(), ms: Math.round(performance.now() - t0) };
})()
'@
  Check '"atl" shows Road Atlanta first' ($atl.first -match 'Road Atlanta') $atl.first
  Check 'Corvette + Road Atlanta takes two selection/action taps' ($atl.taps -eq 2 -and $atl.car -eq 'Chevrolet Corvette Z06 GT3.R' -and $atl.track -eq 'Road Atlanta') "$($atl.taps) taps; $($atl.car) / $($atl.track)"
  Check '"atl" reaches it in <= 1.5 s' ($atl.ms -le 1500) "$($atl.ms) ms"
  Check 'START is lit and reaches the production start command for the selected pair' ($atl.lit -eq $true -and $atl.starts.Count -eq 1 -and $atl.starts[0].car -eq 'Chevrolet Corvette Z06 GT3.R' -and $atl.starts[0].track -eq 'Road Atlanta') (ConvertTo-Json $atl.starts -Compress)
  # no result row can lack a valid live pick id or either member of its pair
  $rows = Cdp-Json "Array.from(document.querySelectorAll('#uFound .row')).map(b => ({ c: b.dataset.c, a: b.dataset.a }))"
  $badRow = @($rows | Where-Object { $_.c -ne 'mdpick' -or $_.a -notmatch '^[rfs][0-9a-f]{8}$' })
  Check "every result row is a startable drive ($($rows.Count) rows)" ($rows.Count -gt 0 -and $badRow.Count -eq 0) (($badRow | ForEach-Object { $_.c + '/' + $_.a }) -join ', ')
  $null = Cdp-Eval "PhoneApp.md = window.__md(); PhoneApp.q = 'cor'; PhoneApp.renderFound(); true"
  $stale = Cdp-Eval "Array.from(document.querySelectorAll('#uFound .row')).some(b => b.dataset.a === 'rdeadbeef')"
  Check 'incomplete stale /mydrive row is excluded from search results' ($stale -eq $false)
  Cdp-Shot (Join-Path $shots 'phone-setup-search.png')
  # a fragment with no drive is a plain no-match state, never a dead row
  $null = Cdp-Eval "PhoneApp.q = 'zzzzzz'; PhoneApp.renderFound(); true"
  $nm = Cdp-Eval "!!document.querySelector('#uFound .nomatch') && document.querySelectorAll('#uFound .row').length === 0"
  Check 'a fragment with no drive shows the no-match state, no dead row' ($nm -eq $true)
  # one match is picked for him (one mdpick, no tap); two matches wait for a tap
  $auto = Cdp-JsonAsync @'
(async () => {
  const A = PhoneApp, w = ms => new Promise(r => setTimeout(r, ms));
  window.__searchState.list = [
    { id: 'r11111111', car: 'Porsche 963 GTP', carShort: '963 GTP', track: 'Daytona International Speedway', trackShort: 'Daytona', ago: 'today', chosen: false },
    { id: 'r22222222', car: 'BMW M4 GT3', carShort: 'BMW GT3', track: 'Lime Rock Park', trackShort: 'LIME ROCK', ago: 'today', chosen: false }];
  window.__searchState.chosen = null;
  A.md = window.__md(); A.q = ''; A.autoId = ''; A.sent = []; A.dry = true;
  A.q = 'daytona'; A.renderFound(); await w(20);
  return { rows: document.querySelectorAll('#uFound .row').length, sent: A.sent.slice() };
})()
'@
  Check 'a single match is picked for him, no tap (one mdpick)' ($auto.rows -eq 1 -and @($auto.sent | Where-Object { $_ -eq '/api/do?c=mdpick&a=r11111111' }).Count -eq 1) ("rows=$($auto.rows) sent=$(@($auto.sent) -join ',')")
  $reject = Cdp-JsonAsync @'
(async () => {
  const A = PhoneApp, w = ms => new Promise(r => setTimeout(r, ms));
  window.__searchState.list = [{ id: 'r33333333', car: 'Porsche 963 GTP', carShort: '963 GTP', track: 'Daytona International Speedway', trackShort: 'Daytona', ago: 'today', chosen: false }];
  window.__searchState.chosen = null; window.__searchState.rejectPick = true;
  A.md = window.__md(); A.md.choice = { has: true, car: 'Old car', track: 'Old track', carShort: 'Old', trackShort: 'Old', layout: '', damage: 'off', fav: false };
  A.q = 'daytona'; A.autoId = ''; A.dry = false; A.sent = [];
  A.renderSetup(); await w(80);
  const start = document.querySelector('#dock .big[data-c=mdstart]');
  return { has: A.md.choice.has, car: A.md.choice.car, track: A.md.choice.track, disabled: !!start && start.disabled };
})()
'@
  Check 'a rejected unique auto-pick clears the old choice and keeps START disabled' (-not $reject.has -and -not $reject.car -and -not $reject.track -and $reject.disabled) (ConvertTo-Json $reject -Compress)
  $null = Cdp-Eval 'window.__searchState.rejectPick = false'
  $amb = Cdp-JsonAsync @'
(async () => {
  const A = PhoneApp, w = ms => new Promise(r => setTimeout(r, ms));
  window.__searchState.list = [
    { id: 'r11111111', car: 'Porsche 963 GTP', carShort: '963 GTP', track: 'Daytona International Speedway', trackShort: 'Daytona', ago: 'today', chosen: false },
    { id: 'r22222222', car: 'BMW M4 GT3', carShort: 'BMW GT3', track: 'Lime Rock Park', trackShort: 'LIME ROCK', ago: 'today', chosen: false }];
  window.__searchState.chosen = null;
  A.md = window.__md(); A.q = ''; A.autoId = ''; A.sent = []; A.dry = true;
  A.q = 'g'; A.renderFound(); await w(20);
  return { rows: document.querySelectorAll('#uFound .row').length, sent: A.sent.slice() };
})()
'@
  Check 'several matches wait for a tap (no mdpick sent)' ($amb.rows -ge 2 -and @($amb.sent).Count -eq 0) ("rows=$($amb.rows) sent=$(@($amb.sent) -join ',')")
  Check 'no JS errors in the search section' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')
  Cdp-Close

  Section '9. the debrief mirror (D-05): a just-ended session shows the same debrief within 60 s, with the same four buttons'
  Assert-RigFreeIf
  Cdp-Open "$api/phone/?asphone=1" 393 852 (9400 + (Get-Random -Maximum 90))
  $null = Wait-Until "typeof PhoneApp !== 'undefined' && !!(PhoneApp || {}).show" 15
  $null = Cdp-Eval @'
(() => {
  const race = { ok: true, race: true, id: 's20261012-120000-1',
    meta: { track: 'Road Atlanta', config: 'Full Course', type: 'Race', startMs: 1674300000000 },
    result: { finishPosition: 3, startPosition: 7, classPosition: 3, iratingChange: 12, gapToWinner: 4.2, incidents: 2, cleanLaps: 8, totalLaps: 10 },
    positionByLap: [{ lap: 1, position: 7 }, { lap: 2, position: 6 }, { lap: 3, position: 5 }, { lap: 4, position: 4 }, { lap: 5, position: 3 }],
    pace: { hisBest: 83.328, classBest: 82.289, hisMedian: 84.275, classMedian: 85.949, top5: 82.700, n: 20 },
    corners: [{ n: 10, label: 'T10a', loss: 0.42 }, { n: 3, label: 'T3', loss: 0.21 }],
    incidents: [{ lap: 8, corner: 'T10a', type: '2x' }],
    bar: { recId: '20261012-120000-roadatlanta', saved: false, shareId: 'x.ibt:8', deepDive: { id: 'x.ibt', lap: 8, corner: 'T10a', cornerN: 10 } } };
  const sessions = { sessions: [{ file: 'x.ibt', track: 'Road Atlanta', car: 'Chevrolet Corvette Z06 GT3.R', type: 'Race', laps: 10, best: 83.328, ts: 1674300000000 }] };
  // The phone opens after the session ended, so it has no connected-to-disconnected edge to observe.
  window.__dbConnected = false;
  window.__dbSessionReads = 0;
  PhoneApp.mock = url => {
    const p = url.split('?')[0];
    if (p === '/phone/state') return { t: Date.now(), connected: !!window.__dbConnected, onTrack: false, driving: false, replay: false, track: '', car: '', session: '', pos: 0, lap: 0, inc: 0, speed: 0, fuel: 0, best: 0, last: 0, pits: false, towWait: false, nav: { to: '', seq: 0, driving: false }, phone: { allowed: true, lan: true, paired: 1 }, health: { apps: [] } };
    if (p === '/sessions') { window.__dbSessionReads++; return window.__dbSessionReads < 2 ? { sessions: [] } : sessions; }
    if (p === '/debrief') return race;
    if (p === '/vault') return { cosworth: { installed: true } };
    if (p === '/api/do') return true;
    return null;
  };
  PhoneApp.paired = true; PhoneApp.dry = true; PhoneApp.sent = []; PhoneApp.db = null; PhoneApp.wasConnected = false; PhoneApp.dbCheckedOffline = false; PhoneApp.st = null; PhoneApp.page = 'home'; PhoneApp.skelName = '';
  return true;
})()
'@
  $sw9 = [Diagnostics.Stopwatch]::StartNew()
  $null = Cdp-Eval "(async () => { await PhoneApp.poll(); return 1; })()"
  $shown = Wait-Until "PhoneApp.db && PhoneApp.db.data && PhoneApp.db.data.ok === true" 60
  $secs9 = $sw9.Elapsed.TotalSeconds
  Check "opening the phone after the session ended discovers and retries the newest session within 60 s ($([math]::Round($secs9,1)) s; $((Cdp-Eval 'window.__dbSessionReads')) session reads)" ($shown -and $secs9 -le 60 -and (Cdp-Eval 'window.__dbSessionReads') -ge 2 -and -not (Cdp-Eval 'PhoneApp.wasConnected'))
  Check 'it opens in the LAPS tab' ((Cdp-Eval 'PhoneApp.page') -eq 'laps')
  $null = Cdp-Eval "PhoneApp.render(); true"
  Start-Sleep -Milliseconds 300
  $txt = [string](Cdp-Eval "document.getElementById('main').innerText")
  Check 'the same result, pace, position-by-lap, corner and incident numbers as the top screen are on the phone' ($txt -match 'P3' -and $txt -match '1:23\.328' -and $txt -match 'Position by lap' -and $txt -match 'Lap 1\s+P7' -and $txt -match 'Lap 2\s+P6' -and $txt -match 'Lap 5\s+P3' -and $txt -match 'T10a' -and $txt -match 'Lap 8' -and $txt -match '2x')
  Check 'the phone omits redundant Actions and unhelpful No debrief copy' ($txt -notmatch 'Actions|No debrief')
  $btns = Cdp-Json "Array.from(document.querySelectorAll('#main [data-db]')).map(b => ({ db: b.dataset.db, id: b.dataset.dbid, label: b.textContent.trim() }))"
  Check 'the four one-press buttons are there (SAVE, SHARE, COSWORTH, DEEP DIVE)' ($btns.Count -eq 4 -and (($btns | ForEach-Object { $_.db }) -join ',') -eq 'save,share,cosworth,deepdive' -and (($btns | ForEach-Object { $_.label }) -join ',') -eq 'SAVE,SHARE,COSWORTH,DEEP DIVE')
  $sent9 = [string](Cdp-Eval "(async () => { PhoneApp.sent = []; const b = document.querySelector('#main [data-db=save]'); await PhoneApp.dbAct('save', b.dataset.dbid, b); await PhoneApp.dbAct('deepdive', b.dataset.dbid, b); return (PhoneApp.sent || []).join('|'); })()")
  Check 'SAVE and DEEP DIVE send the deck commands with the debrief id' ($sent9 -match 'db-save&a=s20261012-120000-1' -and $sent9 -match 'db-deepdive&a=s20261012-120000-1') $sent9
  Cdp-Shot (Join-Path $shots 'phone-debrief.png')
  Check 'no JS errors in the debrief mirror' ($script:cdp.errors.Count -eq 0) ($script:cdp.errors -join ' | ')
  Cdp-Close
}
catch { Write-Output "  FAIL  $($_.Exception.Message) $($_.ScriptStackTrace)"; $script:fail++ }
finally {
  if (-not $LayoutOnly) {
    try { Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8 | Out-Null } catch { }
    # forget the test phones (never leave a token behind): the two named Test*, and the one the app paired in the browser
    try {
      $d = (Http "$api/phone/devices").body | ConvertFrom-Json
      foreach ($x in $d.devices) { if ($x.name -like 'Test*' -or ($devId3 -and $x.id -eq $devId3)) { $null = Http "$api/phone/revoke?id=$($x.id)" } }
    } catch { }
    Remove-Item $hook -Force -ErrorAction SilentlyContinue
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
  }
  Cdp-Close
  Exit-TestLock
}
Write-Output ''
Write-Output "$($script:ok) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
