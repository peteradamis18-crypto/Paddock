# request-rate-test.ps1 - offline (W0-5): how many requests a second the top screen and the deck add-on make, measured on the W0-8 pretend
# irdash (/__stats counts every request; ports 8299 and 8297, never 8199) with the real pages in headless Chrome, 30 s each:
#   1. HOME idle (sim off)                        ceiling 2 / s
#   2. HOME with rig.driving true and live frames ceiling 1 / s besides the stream (and the stream asks for the race set at 15 Hz)
#   3. Analysis open over HOME                    ceiling 2 / s (and it uses HOME's one stream)
#   4. the deck add-on idle on MAIN               ceiling 0.3 / s
#   5. a state push reaches the page within 300 ms (pretend /__push -> the page's data.on('state') -> /__ack, both on the pretend's clock)
# Before W0-5 (audit 10 and 11): HOME idle about 15.7 / s, driving 11.4 / s, Analysis 19-20 / s, the add-on 2.9 / s.
#   powershell -ExecutionPolicy Bypass -File tests\request-rate-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tests\tools'
. (Join-Path $tools 'cdp-lib.ps1')
. (Join-Path $PSScriptRoot 'deck-harness.ps1')
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
function Section($t) { Assert-RigFree -Where $t; $t }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$tmp = Join-Path $env:TEMP ('request-rate-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$fx = Join-Path $tmp 'fixtures'; Copy-Item -Recurse (Join-Path $root 'tests\fixtures\irdash') $fx
$www = Join-Path $root 'dash\www'
$exe = Join-Path $tools 'bin\pretend-irdash.exe'
$race = Join-Path $root 'tests\fixtures\race-12nov.ibt'
$SECS = 30
$rates = [ordered]@{}

function Get-Json($url) { try { return Invoke-RestMethod -Uri $url -TimeoutSec 5 } catch { return $null } }
function Start-Pretend($port, $extra) {
  $a = @("$port", '--fixtures', "`"$fx`"", '--www', "`"$www`"") + $extra
  $p = Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden -PassThru
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  for ($i = 0; $i -lt 40; $i++) { if (Get-Json "http://localhost:$($port + 1)/__stats") { return $p }; Start-Sleep -Milliseconds 150 }
  throw "the pretend irdash did not start on $port"
}
# requests per second over $SECS seconds (the stream itself not counted: it is one open connection), and which routes
function Measure-Rate($port) {
  $null = Get-Json "http://localhost:$($port + 1)/__reset"
  $f0 = (Get-Json "http://localhost:$($port + 1)/__stats").frames
  Start-Sleep -Seconds $SECS
  $s = Get-Json "http://localhost:$($port + 1)/__stats"
  $n = 0; $by = @()
  foreach ($p in $s.routes.PSObject.Properties) { if ($p.Name -eq '/stream') { continue }; $n += $p.Value.count; $by += "$($p.Name) x$($p.Value.count)" }
  # a stream that reconnects is a request each time (the open stream itself is not): every /stream opened in the window counts
  $opens = $(if ($s.routes.'/stream') { $s.routes.'/stream'.count } else { 0 }); $n += $opens
  [pscustomobject]@{ rate = [math]::Round($n / $SECS, 2); n = $n; routes = ($by -join ', '); streams = $s.streams; streamOpens = $opens; frames = $s.frames - $f0 }
}

'W0-5 request rates (pretend irdash, headless Chrome, ' + $SECS + ' s each)'
# the pretend irdash with the W0-5 routes (built by its own script when its source is newer)
& (Join-Path $tools 'pretend-irdash.ps1') -Port 8299 -Stop | Out-Null
$null = & (Join-Path $tools 'pretend-irdash.ps1') -Port 8299; & (Join-Path $tools 'pretend-irdash.ps1') -Port 8299 -Stop | Out-Null
ok 'the pretend irdash (tests\tools\pretend-irdash.exe, W0-5 routes) is built' (Test-Path $exe)
$pret = $null
try {
  # ------------------------------------------------------------------ 1. HOME idle
  Section '1. HOME idle (sim off)'
  $pret = Start-Pretend 8299 @()
  Cdp-Open 'http://localhost:8299/v2/index.html'
  ok 'HOME is up and has the state from the stream (data.online, a seq)' (Wait-Until 'typeof data !== "undefined" && data.online && data.seq >= 1 && !!document.getElementById("homeNext")' 12)
  Start-Sleep -Seconds 6           # the page's own load (fixtures, pictures) is not the idle rate
  $m = Measure-Rate 8299
  $rates['HOME idle'] = $m.rate
  "  info HOME idle: $($m.n) requests in $SECS s = $($m.rate) / s ($($m.routes)); $($m.streams) stream open"
  ok "the stream stayed open for the 30 s ($($m.streamOpens) reconnects; each would count as a request)" ($m.streamOpens -eq 0)
  ok "HOME idle: $($m.rate) requests / s (ceiling 2; before W0-5 about 15.7)" ($m.rate -le 2)
  ok 'HOME idle keeps one stream open and asks no telemetry variables' ($m.streams -eq 1 -and (Cdp-Eval 'data.mode') -eq 'idle')
  Cdp-Shot (Join-Path $shots 'home-idle-rate.png')

  # ------------------------------------------------------------------ 5. a push reaches the page
  Section '5. a state push reaches the page within 300 ms'
  $null = Cdp-Eval "(() => { data.on('state', (st, ch) => { if (ch.keymsg) fetch('/__ack?seq=' + st.seq + '&note=' + encodeURIComponent(st.keymsg.text)); }); return 1; })()"
  $worst = 0; $got = 0
  for ($i = 1; $i -le 5; $i++) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $text = "push $i"
    $json = '{"seq":' + (1000 + $i) + ',"key":"w05","text":"' + $text + '","kind":"ok","at":' + $now + '}'
    $p = Get-Json ("http://localhost:8300/__push?part=keymsg&json=" + [uri]::EscapeDataString($json))
    $ack = $null
    for ($k = 0; $k -lt 20 -and -not $ack; $k++) { Start-Sleep -Milliseconds 100; $ack = @(Get-Json 'http://localhost:8300/__acks') | ForEach-Object { $_ } | Where-Object { $_.note -eq $text } | Select-Object -First 1 }
    if ($ack -and $p) { $got++; $worst = [math]::Max($worst, $ack.at - $p.at) }
    Start-Sleep -Milliseconds 300
  }
  $shown = Cdp-Eval '(() => { const e = document.getElementById("keyMsg"); return e && e.textContent + "|" + e.className; })()'
  "  info 5 pushes: the page had each one $worst ms (worst) after the push, on the pretend's clock; the message line shows '$shown'"
  ok "every push reached the page, the slowest in $worst ms (ceiling 300)" ($got -eq 5 -and $worst -le 300) "$got of 5"
  ok 'the pushed key message is on the top screen' ($shown -like 'push 5|*on*')
  $null = Get-Json ('http://localhost:8300/__push?part=kids&json=' + [uri]::EscapeDataString('{"on":true,"text":"KIDS MODE  -  test"}'))
  ok 'a pushed kids lock shows its banner (no /api/kids request)' (Wait-Until '!document.getElementById("kidsMode").hidden' 3)
  $null = Get-Json ('http://localhost:8300/__push?part=kids&json=' + [uri]::EscapeDataString('{"on":false,"text":""}'))

  # ------------------------------------------------------------------ 6. the stream comes back by itself
  Section '6. the stream comes back after irdash answers it with an error (the browser gives up on its own then)'
  $null = Get-Json 'http://localhost:8300/__fault?mode=down'
  Start-Sleep -Milliseconds 800
  $null = Get-Json 'http://localhost:8300/__fault?mode=500&route=/stream'
  $null = Get-Json 'http://localhost:8300/__fault?mode=ok&route=/none'          # the listener is back; /stream answers 500
  $gaveUp = Wait-Until 'data.es && data.es.readyState === 2 || data.retryMs > 0' 15
  ok 'the stream got a 500: the browser closed it for good (readyState 2), data.js has a retry waiting' $gaveUp
  $null = Get-Json 'http://localhost:8300/__fault?mode=ok'                     # /stream answers again
  $t0 = Get-Date
  $back = Wait-Until 'data.online && data.es && data.es.readyState === 1' 40
  $took = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  ok "data.js opened it again by itself ($took s after irdash answered again)" $back
  $null = Get-Json ('http://localhost:8300/__push?part=keymsg&json=' + [uri]::EscapeDataString('{"seq":2001,"key":"w05","text":"after the gap","kind":"ok","at":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '}'))
  ok 'and pushes reach the page again' (Wait-Until '(document.getElementById("keyMsg").textContent || "") === "after the gap"' 5)
  # ------------------------------------------------------------------ 3. Analysis open over HOME
  Section '3. Analysis open over HOME'
  $vaultIbt = 'C:\Users\peter\iRacingDeck\vault\telemetry\chevrolet-corvette-z06-gt3-r\road-atlanta-full-course\2026-10-10 00-13-18.ibt'
  $id = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'
  $bin = Join-Path $fx 'analysis_channels.bin'
  if (Test-Path -LiteralPath $vaultIbt) {
    # the page's channel reply, made by irdash's own engine (dash\build.ps1 -NoDeploy, irdash.exe --analysis --channels) from a COPY of an old Vault file
    $work = Join-Path $tmp 'work'; New-Item -ItemType Directory -Force $work | Out-Null
    Copy-Item -LiteralPath $vaultIbt -Destination (Join-Path $work $id)
    $build = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy | Out-String
    $bm = [regex]::Match($build, 'built in (.+?) \(not deployed\)')
    $chp = ([regex]::Match((Get-Content (Join-Path $root 'dash\www\v2\workbench.js') -Raw), 'var CHANS = \[(.*?)\];', 'Singleline').Groups[1].Value -replace "[\s']", '')
    if ($bm.Success) {
      $psi = New-Object Diagnostics.ProcessStartInfo (Join-Path $bm.Groups[1].Value.Trim() 'irdash.exe')
      $psi.Arguments = "--analysis --channels --root `"$root`" --dir `"$work`" --id `"$id`" --lap 7 --ref `"pb`" --ch `"$chp`" --out `"$bin`""
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $pr = [Diagnostics.Process]::Start($psi); try { $pr.PriorityClass = 'BelowNormal' } catch { }; $null = $pr.WaitForExit(240000)
    }
  }
  if (Test-Path $bin) {
    $null = Cdp-Eval "(() => { PageHost.open('sessions', false); return 1; })()"
    Start-Sleep -Seconds 2
    $null = Cdp-Eval ("(() => { document.querySelector('#sessHost iframe').src = 'workbench.html?id=" + [uri]::EscapeDataString($id) + "&lap=7'; return 1; })()")
    $wb = Wait-Until '(() => { try { const w = document.querySelector("#sessHost iframe").contentWindow; return !!(w.WB && w.WB.ready); } catch (e) { return false; } })()' 30
    ok 'Analysis (workbench.html) is open over HOME with its lap drawn' $wb
    ok 'Analysis uses HOME''s connection (data is borrowed: one stream for the whole screen)' ((Cdp-Eval '(() => { const w = document.querySelector("#sessHost iframe").contentWindow; return !!(w.data && w.data.__borrowed); })()') -eq $true)
    Start-Sleep -Seconds 6
    $m = Measure-Rate 8299
    $rates['Analysis open'] = $m.rate
    "  info Analysis open: $($m.n) requests in $SECS s = $($m.rate) / s ($($m.routes)); $($m.streams) stream open"
    ok "the stream stayed open for the 30 s ($($m.streamOpens) reconnects; each would count as a request)" ($m.streamOpens -eq 0)
  ok "Analysis open: $($m.rate) requests / s (ceiling 2; before W0-5 about 19-20)" ($m.rate -le 2)
    ok 'still one stream for HOME and Analysis together' ($m.streams -eq 1)
    # a deck command reaches the page through the push (not a 300 ms poll)
    $seq0 = Cdp-Eval '(() => { const w = document.querySelector("#sessHost iframe").contentWindow; return w.WB && w.WB.state ? 1 : 1; })()'
    $null = Get-Json ('http://localhost:8300/__push?part=workbench&json=' + [uri]::EscapeDataString('{"cmd":"page","arg":"braking","seq":7,"driving":false}'))
    Start-Sleep -Milliseconds 200
    $null = Get-Json ('http://localhost:8300/__push?part=workbench&json=' + [uri]::EscapeDataString('{"cmd":"page","arg":"driver","seq":8,"driving":false}'))
    $pg = $null; for ($k = 0; $k -lt 10; $k++) { Start-Sleep -Milliseconds 200; $pg = Cdp-Eval '(() => { const w = document.querySelector("#sessHost iframe").contentWindow; return w.document.querySelector(".tab.on, .tabs .on") ? w.document.querySelector(".tab.on, .tabs .on").textContent : (w.WB && w.WB.page ? w.WB.page : ""); })()' }
    "  info after a pushed deck command the Analysis page shows: '$pg'"
    Cdp-Shot (Join-Path $shots 'analysis-over-home-rate.png')
  } else { '  skip the Analysis page needs a channel reply made from an old Vault file (vault\telemetry\...\2026-10-10 00-13-18.ibt): not on this PC' }
  Cdp-Close
  Stop-Process -Id $pret.Id -Force -ErrorAction SilentlyContinue; $pret = $null

  # ------------------------------------------------------------------ 2. HOME while he drives
  Section '2. HOME while driving (live frames, rig.driving)'
  if (Test-Path $race) {
    $pret = Start-Pretend 8297 @('--ibt', "`"$race`"", '--speed', '1', '--loop')
    $null = Get-Json ('http://localhost:8298/__push?part=rig&json=' + [uri]::EscapeDataString('{"driving":true,"sessionOn":true,"simRunning":true,"online":true}'))
    Cdp-Open 'http://localhost:8297/v2/index.html'
    ok 'the in-car layout is live (frames on the stream, the session from the state)' (Wait-Until 'typeof UI !== "undefined" && UI.live() && S.drivers.size > 1 && data.rig.driving' 15)
    # W2-2: in the car the race screen shows and the stream carries its named set (set=race, 24 channels)
    ok 'the stream asks for the race screen''s set at 15 Hz (data.mode live, set=race)' (Wait-Until '(data.mode + "|" + data.hz + "|" + data.set) === "live|15|race" && /[?&]set=race/.test(data.url)' 8) (Cdp-Eval 'data.mode + "|" + data.hz + "|" + data.set')
    Start-Sleep -Seconds 6
    $m = Measure-Rate 8297
    $rates['HOME driving'] = $m.rate
    $fps = [math]::Round($m.frames / $SECS / [math]::Max(1, $m.streams), 1)
    "  info driving: $($m.n) requests in $SECS s = $($m.rate) / s besides the stream ($($m.routes)); $($m.streams) stream, $fps frames / s"
    ok "the stream stayed open for the 30 s ($($m.streamOpens) reconnects; each would count as a request)" ($m.streamOpens -eq 0)
  ok "HOME driving: $($m.rate) requests / s besides the stream (ceiling 1; before W0-5 about 11.4)" ($m.rate -le 1)
    ok "the stream sends about 15 frames a second, not 30 ($fps)" ($fps -ge 10 -and $fps -le 17)
    Cdp-Shot (Join-Path $shots 'incar-driving-rate.png')
    Cdp-Close
    Stop-Process -Id $pret.Id -Force -ErrorAction SilentlyContinue; $pret = $null
  } else { '  skip tests\fixtures\race-12nov.ibt is not here (tests\tools-test.ps1 builds it): no driving measurement' }

  # ------------------------------------------------------------------ 4. the deck add-on idle on MAIN
  Section '4. the deck add-on idle on MAIN'
  $plugin = Join-Path $root 'deck-intro\plugin.html'
  $usesSummary = (Get-Content $plugin -Raw).Contains('/deck/summary')
  $pret = Start-Pretend 8299 @()
  $html = Join-Path $tmp 'deck-rate-harness.html'
  $url = Build-DeckHarness $plugin $html
  $h = [IO.File]::ReadAllText($html).Replace("const API = 'http://localhost:8199';", "const API = 'http://localhost:8299';")
  [IO.File]::WriteAllText($html, $h, (New-Object Text.UTF8Encoding($false)))
  ok 'the add-on page talks to the pretend irdash only' ($h.Contains("const API = 'http://localhost:8299';") -and -not $h.Contains("const API = 'http://localhost:8199';"))
  $bro = Start-DeckBrowser 9384
  try {
    $page = New-DeckPage $bro $url -Hidden
    Start-Sleep -Milliseconds 600
    $null = Invoke-DeckJs $page "(() => { __sd.cfg.fakeFetch = false; __sd.connect(); return 1; })()"
    Start-Sleep -Seconds 6
    $m = Measure-Rate 8299
    $rates['deck idle'] = $m.rate
    "  info the add-on on MAIN: $($m.n) requests in $SECS s = $($m.rate) / s ($($m.routes))"
    if ($usesSummary) {
      ok "the add-on idle on MAIN: $($m.rate) requests / s (ceiling 0.3; before W0-5 about 2.9)" ($m.rate -le 0.3)
      ok 'it asks only /deck/summary (no /mydrive, /guest, /overlays ... each pass)' ($m.routes -notmatch '/mydrive|/guest|/overlays|/replay|/api/rec/races|/showcase')
      $img = Invoke-DeckJs $page "Object.keys(__sd.images).filter(k => k.startsWith('k-')).length"
      ok "the opener keys are painted from the summary ($img keys)" ($img -ge 3)
      $u = Invoke-DeckJs $page "__sd.images['k-overlays']"; if ($u) { Save-DataUrlPng $u (Join-Path $shots 'deck-summary-overlays-key.png') }
    } else { "  skip the add-on in this tree still polls its six routes ($($m.rate) / s): the /deck/summary add-on is the last commit of the W0-5 branch" }
  } finally { Stop-DeckBrowser $bro }
} finally {
  Cdp-Close
  if ($pret) { Stop-Process -Id $pret.Id -Force -ErrorAction SilentlyContinue }
  Get-Process pretend-irdash -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
''
'measured: ' + (($rates.Keys | ForEach-Object { "$_ $($rates[$_]) / s" }) -join ', ')
"request-rate-test: $($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
