# page-audit-test.ps1 - the top-screen pages as Peter sees them, against the running irdash (read-only GETs, no test hook, no
# clicks on his screens: headless Chrome with its own profile). Born from the 2026-10-18 page audit; each check is one real defect found by using
# the pages with his real data:
#   - opening a Vault lap/race (or any Workbench page) asked /vault/videoinfo and got a 404 every time when no clip exists
#   - Sessions / Vault / Performance showed 24-hour en-GB times in the PC's zone while HOME shows 12-hour New York
#   - Sessions cut "Full Course" to "Full Cou..." in every row
#   - Performance showed "DriverHands ... (settled: 1)" and "Ask Claude" to Peter; its chart started on a single dot
#   - the Workbench said "Skies 1 · Wet 1" and counted every ABS pulse as a lock-up ("32 lock-ups" on a clean lap)
#   - the Session Review printed PRATT MILLER MOTORSPORTS on a BMW; the Coach cut its last sentence off
#   powershell -ExecutionPolicy Bypass -File tests\page-audit-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$base = 'http://localhost:8199'
$pass = 0; $fail = 0
function Check($what, $ok, $more = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what $more" } }
function Section($n) { Assert-RigFree -Where $n; "`n== $n" }
try { $null = Invoke-RestMethod "$base/health" -TimeoutSec 5 } catch { '  FAIL  irdash is not answering on :8199'; exit 1 }
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.Net.WebSockets; using System.Text; using System.Threading; using System.IO;
public class Cdp {
  ClientWebSocket ws = new ClientWebSocket(); public List<string> Msgs = new List<string>(); int id = 0; public object Lock = new object();
  public void Connect(string url) { ws.ConnectAsync(new Uri(url), CancellationToken.None).Wait(); Thread th = new Thread(Loop); th.IsBackground = true; th.Start(); }
  void Loop() { byte[] buf = new byte[65536]; try { while (ws.State == WebSocketState.Open) { var ms = new MemoryStream(); WebSocketReceiveResult r;
    do { r = ws.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None).Result; ms.Write(buf, 0, r.Count); } while (!r.EndOfMessage);
    lock (Lock) { Msgs.Add(Encoding.UTF8.GetString(ms.ToArray())); } } } catch { } }
  public int Send(string method, string paramsJson) { id++; string m = "{\"id\":" + id + ",\"method\":\"" + method + "\"" + (!string.IsNullOrEmpty(paramsJson) ? ",\"params\":" + paramsJson : "") + "}";
    ws.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(m)), WebSocketMessageType.Text, true, CancellationToken.None).Wait(); return id; }
  public string WaitFor(int want, int ms) { DateTime end = DateTime.Now.AddMilliseconds(ms); string key = "\"id\":" + want + ",";
    while (DateTime.Now < end) { lock (Lock) { foreach (string s in Msgs) if (s.StartsWith("{" + key)) return s; } Thread.Sleep(30); } return null; }
  public List<string> Take() { lock (Lock) { var l = new List<string>(Msgs); Msgs.Clear(); return l; } }
  public void Close() { try { ws.Dispose(); } catch { } }
}
"@



$port = 9400 + (Get-Random -Maximum 300)
$prof = Join-Path $env:TEMP ('pat-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$proc = Start-Process $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', '--mute-audio', "--user-data-dir=$prof", "--remote-debugging-port=$port", '--window-size=1920,1200', 'about:blank') -PassThru -WindowStyle Hidden
Start-Sleep 3
# open one page, wait, run a script in it; returns @{ val; bad } where bad = every response >= 400 the page caused
function Page($url, $ms, $js) {
  $tab = (Invoke-RestMethod "http://localhost:$port/json") | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
  $c = New-Object Cdp; $c.Connect($tab.webSocketDebuggerUrl)
  foreach ($d in 'Runtime.enable', 'Network.enable', 'Page.enable') { $null = $c.Send($d, $null) }
  $null = $c.Send('Emulation.setDeviceMetricsOverride', '{"width":1920,"height":1080,"deviceScaleFactor":1,"mobile":false}')
  $null = $c.Send('Page.navigate', (@{ url = 'about:blank' } | ConvertTo-Json -Compress)); Start-Sleep -Milliseconds 400
  $null = $c.Take()
  $null = $c.Send('Page.navigate', (@{ url = $url } | ConvertTo-Json -Compress))
  Start-Sleep -Milliseconds $ms
  $i = $c.Send('Runtime.evaluate', (@{ expression = $js; returnByValue = $true } | ConvertTo-Json -Compress)); $r = $c.WaitFor($i, 10000)
  $val = $null; if ($r) { $val = ($r | ConvertFrom-Json).result.result.value }
  $bad = @(); foreach ($m in $c.Take()) { if ($m.StartsWith('{"id"')) { continue }; $e = $m | ConvertFrom-Json; if ($e.method -eq 'Network.responseReceived' -and $e.params.response.status -ge 400) { $bad += ('' + $e.params.response.status + ' ' + $e.params.response.url) } }
  $c.Close()
  return @{ val = $val; bad = $bad }
}
try {
  $rec = Invoke-RestMethod "$base/vault/recorder"
  $list = Invoke-RestMethod "$base/vault/list"; $ses = (Invoke-RestMethod "$base/sessions").sessions
  $z4 = $ses | Where-Object { $_.car -eq 'BMW Z4 GT3' -and $_.laps -ge 5 -and -not $_.gone } | Select-Object -First 1
  $enc = if ($z4) { [uri]::EscapeDataString($z4.file) } else { '' }

  Section '1. no request that cannot succeed (videoinfo with no clip)'
  $lap = $list.moments | Where-Object { $_.kind -eq 'lap' } | Select-Object -First 1
  if ($rec.clips -eq 0 -and $lap) {
    $r = Page "$base/v2/vault.html?embed=1#m=$($lap.id)" 7000 'document.body.innerText.length'
    Check 'opening a Vault lap with no recorder clip makes no /vault/videoinfo request' (-not ($r.bad -match 'videoinfo')) ($r.bad -join '; ')
  } else { '  skip  the recorder has clips, or there is no lap in the Vault' }
  if ($rec.clips -eq 0 -and $z4) {
    $r = Page "$base/v2/workbench.html?id=$enc&lap=4&page=driver" 9000 'document.body.innerText.length'
    Check 'opening the Workbench with no recorder clip makes no /vault/videoinfo request' (-not ($r.bad -match 'videoinfo')) ($r.bad -join '; ')
    Check 'the Workbench page itself loads without any 4xx/5xx' ($r.bad.Count -eq 0) ($r.bad -join '; ')
  }

  Section '2. Sessions: New York 12-hour times, no cut-off Full Course'
  $r = Page "$base/v2/sessions.html?embed=1" 7000 'JSON.stringify({when:[].map.call(document.querySelectorAll("#sessList .row .when"),function(e){return e.textContent}).slice(0,8),tr:[].map.call(document.querySelectorAll("#sessList .row .t"),function(e){return e.textContent}).slice(0,40),pbsub:[].map.call(document.querySelectorAll("#pbList .row .tm small"),function(e){return [e.textContent,e.getBoundingClientRect().height]}).slice(0,6)})'
  $o = $r.val | ConvertFrom-Json
  Check 'every session time reads like 5:24 PM' (@($o.when | Where-Object { $_ -match '\d{1,2}:\d{2}\s?(AM|PM)$' }).Count -eq @($o.when).Count -and @($o.when).Count -gt 0) ($o.when -join ' | ')
  Check 'the track column never shows a cut "Full Cou..."' (-not (@($o.tr) -match 'Full Cou')) ''
  Check 'the personal-best date line fits on one line' (@($o.pbsub | Where-Object { $_[1] -gt 24 }).Count -eq 0) ''

  Section '3. Vault and Performance: same time style, plain words, a chart with a line'
  $r = Page "$base/v2/vault.html?embed=1#m=$($lap.id)" 7000 'document.getElementById("dSub").textContent'
  Check 'the Vault card date ends in AM or PM (New York)' ($r.val -match '\d{1,2}:\d{2}\s?(AM|PM)') $r.val
  $r = Page "$base/v2/perf.html?embed=1" 8000 'document.body.innerText'
  Check 'Performance shows no DriverHands / SteeringWheel / settled / Ask Claude' (-not ($r.val -match 'DriverHands|SteeringWheel|settled|Ask Claude')) ''
  Check 'Performance times are 12-hour' ($r.val -match 'Last session[\s\S]{0,60}\d{1,2}:\d{2}\s?(AM|PM)')
  $pf = Invoke-RestMethod "$base/perf"
  if ($pf.last) {
    $same = @($pf.sessions | Where-Object { $_.counts -and $_.key -eq $pf.last.key -and $_.car -eq $pf.last.car }).Count
    if ($same -ge 5) { Check 'the Performance chart does not start on a single session' (-not ($r.val -match '(?m)^1 session\s*·')) '' } else { '  skip  fewer than 5 sessions of the last car and track' }
  }

  if ($z4) {
    Section '4. Workbench: words not codes, ABS is not a lock-up'
    $r = Page "$base/v2/workbench.html?id=$enc&lap=4&page=driver" 9000 'JSON.stringify({mode:document.getElementById("mode").textContent,all:document.body.innerText})'
    $o = $r.val | ConvertFrom-Json
    Check 'the conditions line says Dry / Clear words, not "Skies 1 · Wet 1"' ($o.mode -match '(Clear|cloudy|Overcast)' -and $o.mode -match '(Dry|wet|Soaked)' -and -not ($o.mode -match 'Skies \d|Wet \d')) $o.mode
    $n = [regex]::Match($o.all, '(\d+) lock-ups?'); $abs = [regex]::Match($o.all, '(\d+) ABS')
    Check 'a clean ABS-car lap does not report ABS pulses as lock-ups' (-not $n.Success -or -not $abs.Success -or [int]$n.Groups[1].Value -lt [int]$abs.Groups[1].Value * 2) ($n.Value + ' / ' + $abs.Value)

    Section '5. Session Review and Coach'
    $r = Page "$base/v2/sessionreview.html?id=$enc" 8000 'document.body.innerText'
    Check 'the Session Review shows no made-up team (BMW is not Pratt Miller)' (-not ($r.val -match 'PRATT MILLER')) ''
    $r = Page "$base/v2/coach.html?id=$enc" 9000 'JSON.stringify([].map.call(document.querySelectorAll(".card .say2"),function(e){return {s:e.scrollHeight,c:e.clientHeight,w:e.scrollWidth,cw:e.clientWidth}}))'
    $o = @($r.val | ConvertFrom-Json | ForEach-Object { $_ })
    Check 'the Coach sentences under THEN are not cut off' (@($o | Where-Object { $_.s -gt $_.c + 1 -or $_.w -gt $_.cw + 1 }).Count -eq 0) $r.val
  }
}
finally {
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($prof) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep 1; Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$pass passed, $fail failed"
if ($fail) { exit 1 }