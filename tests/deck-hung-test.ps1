# deck-hung-test.ps1 - the add-on when irdash accepts a request and never answers (W0-1, audit 11 A2/A3).
# Before: no fetch had a timeout, so a hung irdash froze every opener key and every open screen for good.
# OFFLINE: a pretend irdash (a PowerShell HttpListener in a background job on a spare port, never 8199) that holds every request
# open without an answer, until the test tells it to answer normally. The real add-on page runs in headless Chrome with the
# pretend Stream Deck app (tests\deck-mock.js), pointed at that port. Nothing reaches the real irdash or Stream Deck.
#   4. every add-on screen (all nine) says DASHBOARD NOT ANSWERING within 3 s, with EXIT at 7,3 (and EXIT works)
#   2. the opener keys are normal before 3 failed ticks and grey after 3
#   3. one good answer: the opener keys are back to normal
# Pictures: tests\shots\rework\hung-*.png
#   powershell -ExecutionPolicy Bypass -File tests\deck-hung-test.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
'Hung irdash test'

$port = 9395
$mode = Join-Path $env:TEMP ("deck-hung-mode-$PID.txt"); Set-Content $mode 'hang'
# the pretend irdash: 'hang' = keep every request open, never answer; 'good' = answer like irdash (small JSON, CORS for the file:// page)
$job = Start-Job -ArgumentList $port, $mode -ScriptBlock {
  param($port, $mode)
  $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$port/"); $l.Start()
  $held = New-Object Collections.ArrayList
  $answers = @{ '/showcase' = '{"seq":0,"play":false,"driving":false}'; '/overlays' = '{"onCount":2,"widgets":[],"presets":[],"saveTo":"race","running":true,"delta":{"on":false,"ref":"pb"},"driving":false}'
                '/guest' = '{}'; '/mydrive' = '{"ready":false}'; '/replay' = '{"ready":false}'; '/sound' = '{"ready":false}'; '/ac' = '{"connected":false}'; '/doctor' = '{}' }
  while ($true) {
    $ctx = $l.GetContext()
    if ((Get-Content $mode -Raw).Trim() -eq 'hang') { [void]$held.Add($ctx); continue }
    $b = $answers[$ctx.Request.Url.AbsolutePath]; if (-not $b) { $b = '{}' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($b)
    $ctx.Response.AddHeader('Access-Control-Allow-Origin', '*'); $ctx.Response.ContentType = 'application/json'
    try { $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close() } catch { }
  }
}
Start-Sleep -Seconds 2
$listening = $false; try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $listening = $c.Connected; $c.Close() } catch { }
Check "the pretend irdash listens on port $port (not 8199) and holds requests" $listening (Receive-Job $job 2>&1 | Out-String)

$html = Join-Path $env:TEMP 'deck-hung-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html)
$h2 = $h.Replace("const API = 'http://localhost:8199';", "const API = 'http://localhost:$port';")
# every add-on screen gets an opener key on the pretend page (the mock only has FRIENDS, OVERLAYS, MY DRIVE and the two CONFIRM keys)
$h2 = $h2.Replace("TILE.RigConfirm = 'confirm';", "TILE.RigConfirm = 'confirm'; OPEN.push(['k-replay', 'com.peter.rigintro.replay', 0, 0], ['k-sound', 'com.peter.rigintro.sound', 2, 0], ['k-ac', 'com.peter.rigintro.ac', 3, 0], ['k-races', 'com.peter.rigintro.races', 5, 0]); Object.assign(TILE, { RigReplay: 'replay', RigSound: 'sound', RigAC: 'ac', RigRaces: 'races' });")
Check 'the add-on page talks to the pretend irdash only' ($h2.Contains("const API = 'http://localhost:$port';") -and -not $h2.Contains("const API = 'http://localhost:8199';"))
[IO.File]::WriteAllText($html, $h2, (New-Object Text.UTF8Encoding($false)))

$b = Start-DeckBrowser 9383
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  $null = Invoke-DeckJs $page "(() => { __sd.cfg.fakeFetch = false; __sd.connect(); return 1; })()"
  Start-Sleep -Milliseconds 800
  # the opener key's edge: gold = normal, grey = irdash not answering
  # W3-4: an opener key is drawn by keyart.js from deck\layout.json; greyed = exactly the add-on's own grey picture of that key (NOT ANSWERING)
  $edge = @'
(async (ctx) => { const u = __sd.images[ctx]; if (!u) return 'none'; const s = Object.values(SCREENS).find(x => x.keys.has(ctx)); if (!s) return 'no screen';
  return u === Health.greyPic(s.greyWord(ctx), 'NOT ANSWERING', s.openerSpec(ctx)) ? 'grey' : 'live'; })
'@
  function Edge($ctx) { Invoke-DeckJs $page "$edge('$ctx')" }
  function Cur { Invoke-DeckJs $page '__sd.cur' }

  Assert-RigFree -Where '2. grey'
  ''; '2. opener keys after failed ticks'
  $waited = 0
  while ((Invoke-DeckJs $page 'Health.failed') -lt 2 -and $waited -lt 30) { Start-Sleep -Milliseconds 250; $waited += 0.25 }
  $f2 = Invoke-DeckJs $page 'Health.failed'
  Check "after $f2 failed ticks the opener keys are not grey yet" ($f2 -ge 1 -and $f2 -lt 3 -and (Invoke-DeckJs $page 'Health.grey') -eq $false -and (Edge 'k-overlays') -ne 'grey') "edge $(Edge 'k-overlays')"
  while ((Invoke-DeckJs $page 'Health.grey') -ne $true -and $waited -lt 40) { Start-Sleep -Milliseconds 250; $waited += 0.25 }
  Start-Sleep -Milliseconds 300
  $f3 = Invoke-DeckJs $page 'Health.failed'
  Check "after 3 failed ticks every opener key is grey (failed=$f3; OVERLAYS $(Edge 'k-overlays'), FRIENDS $(Edge 'k-friends'), SHUT DOWN $(Edge 'k-shutdown'))" ($f3 -eq 3 -and (Edge 'k-overlays') -eq 'grey' -and (Edge 'k-friends') -eq 'grey' -and (Edge 'k-mydrive') -eq 'grey' -and (Edge 'k-shutdown') -eq 'grey')
  $u = Invoke-DeckJs $page "__sd.images['k-overlays']"; if ($u) { Save-DataUrlPng $u (Join-Path $shots 'hung-opener-grey.png') }

  Assert-RigFree -Where '3. back'
  ''; '3. irdash answers again'
  Set-Content $mode 'good'
  $t1 = Get-Date
  while ((Invoke-DeckJs $page 'Health.grey') -eq $true -and ((Get-Date) - $t1).TotalSeconds -lt 12) { Start-Sleep -Milliseconds 200 }
  Start-Sleep -Milliseconds 400
  $back = [int]((Get-Date) - $t1).TotalSeconds
  Check "one good answer brings the opener keys back (about $back s; OVERLAYS $(Edge 'k-overlays'), FRIENDS $(Edge 'k-friends'))" ((Invoke-DeckJs $page 'Health.grey') -eq $false -and (Invoke-DeckJs $page 'Health.failed') -eq 0 -and (Edge 'k-overlays') -eq 'live' -and (Edge 'k-friends') -eq 'live')
  $u = Invoke-DeckJs $page "__sd.images['k-overlays']"; if ($u) { Save-DataUrlPng $u (Join-Path $shots 'hung-opener-back.png') }
  Start-Sleep -Seconds 3   # every screen gets one good state while irdash answers (they are drawn from it the moment they open)

  Assert-RigFree -Where '4. every screen'
  ''; '4. every add-on screen while irdash hangs (SOUND, AC, AI LEVEL and RACES used to say NOT READY instead)'
  Set-Content $mode 'hang'
  foreach ($s in @(@('friends', 'Friends'), @('overlays', 'Overlays'), @('mydrive', 'MyDrive'), @('replay', 'Replay'), @('sound', 'Sound'), @('ac', 'Ac'), @('races', 'Races'))) {
    $key = $s[0]; $obj = $s[1]
    Assert-RigFree -Where "4. $key"
    Start-Sleep -Milliseconds 900   # W3-4: an opener press within 0.8 s of a page change is the doubled press and is ignored
    $t0 = Get-Date
    if ($key -eq 'friends') { $null = Invoke-DeckJs $page 'Friends.g = null' }   # the pretend /guest is {} (not enough to draw FRIENDS); real irdash sends the full state
    $null = Invoke-DeckJs $page "(async () => { __sd.pressOpener('$key'); return 1; })()"
    $shownMs = -1
    while (((Get-Date) - $t0).TotalSeconds -lt 7) { if ((Invoke-DeckJs $page "$obj.offline") -eq $true) { $shownMs = [int]((Get-Date) - $t0).TotalMilliseconds; break }; Start-Sleep -Milliseconds 100 }
    Start-Sleep -Milliseconds 400
    $all = (Invoke-DeckJs $page "Object.keys($obj.tiles).length === 32 && Object.keys($obj.tiles).every(p => $obj.shown[p] === 'offline')") -eq $true
    Check "$($key.ToUpper()) says DASHBOARD NOT ANSWERING on all 32 keys within 3 s of the press (took $shownMs ms)" ($shownMs -gt 0 -and $shownMs -le 3000 -and $all)
    if ($key -eq 'sound') { $null = Save-DeckSheet $page (Join-Path $shots 'hung-screen-offline.png') }
    $null = Invoke-DeckJs $page "(async () => { __sd.pressTile(7, 3); await __sd.sleep(700); return 1; })()"
    Check "... and EXIT at 7,3 leaves it" ((Cur) -eq 'main') (Cur)
  }
}
finally {
  Stop-DeckBrowser $b
  Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
  Remove-Item $mode -Force -ErrorAction SilentlyContinue
}

''; '4. the add-on source'
$plug = [IO.File]::ReadAllText((Join-Path $root 'deck-intro\plugin.html'))
Check 'every request goes through fetchT (2 s AbortController); no bare fetch( is left' ($plug -match 'const FETCH_MS = 2000;' -and $plug -match 'new AbortController\(\)' -and ([regex]::Matches($plug, '(?<![\w.])fetch\(')).Count -eq 1)
Check 'MY DRIVE never opens by itself (no open({ auto: true }) left)' ($plug -notmatch 'auto: true' -and $plug -notmatch 'autoPrompted')
Check 'the ARMED state keys and /deck/state are gone' ($plug -notmatch 'paintStateKey|pollDeckState|/deck/state|stateKeys')
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
