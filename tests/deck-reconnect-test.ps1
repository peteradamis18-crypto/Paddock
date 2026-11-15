# deck-reconnect-test.ps1 - the add-on finds a restarted irdash again with no opener key showing (W5-5).
# 2026-11-14: irdash restarted at 21:00 with the PC locked; the add-on had no opener key on screen, so its poll loop asked nothing,
# and irdash heard from it only at the unlock (21:06). Now a heartbeat (/deck/beat) goes out every 5 s while no key shows.
# OFFLINE: a pretend irdash (HttpListener in a background job on a spare port, never 8199) that can be 'down' (nothing listening:
# connection refused) and 'good'; it logs every request. The real add-on page runs hidden (its page timers slowed by Chrome) in
# headless Chrome with the pretend Stream Deck app (tests\deck-mock.js). The outage is 25 s here, not 3 minutes: the loop has no
# give-up counter, so its length does not matter (checked in the source section).
#   powershell -ExecutionPolicy Bypass -File tests\deck-reconnect-test.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
'Add-on reconnect test'

$port = 9396
$mode = Join-Path $env:TEMP ("deck-reco-mode-$PID.txt"); Set-Content $mode 'good'
$reqlog = Join-Path $env:TEMP ("deck-reco-req-$PID.txt"); Set-Content $reqlog ''
$job = Start-Job -ArgumentList $port, $mode, $reqlog -ScriptBlock {
  param($port, $mode, $reqlog)
  $l = $null
  while ($true) {
    $m = (Get-Content $mode -Raw).Trim()
    if ($m -eq 'down') { if ($l) { try { $l.Stop(); $l.Close() } catch { }; $l = $null }; Start-Sleep -Milliseconds 100; continue }
    if (-not $l) { $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$port/"); $l.Start() }
    $t = $l.GetContextAsync()
    while (-not $t.Wait(200)) { if ((Get-Content $mode -Raw).Trim() -eq 'down') { break } }
    if (-not $t.IsCompleted) { continue }
    $ctx = $t.Result
    $p = $ctx.Request.Url.AbsolutePath
    Add-Content $reqlog ("{0:o} {1}" -f [DateTime]::UtcNow, $p)
    $b = '{}'; if ($p -eq '/deck/summary') { $b = '{"showcase":{"play":false,"seq":0,"driving":false}}' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($b)
    $ctx.Response.AddHeader('Access-Control-Allow-Origin', '*'); $ctx.Response.ContentType = 'application/json'
    try { $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close() } catch { }
  }
}
function Hits($path, [datetime]$since) { @(Get-Content $reqlog | Where-Object { $_ -like "* $path" } | ForEach-Object { [datetime]::Parse(($_ -split ' ')[0]).ToUniversalTime() } | Where-Object { $_ -ge $since.ToUniversalTime() }) }
Start-Sleep -Seconds 2

$html = Join-Path $env:TEMP 'deck-reconnect-harness.html'
$null = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html).Replace("const API = 'http://localhost:8199';", "const API = 'http://localhost:$port';")
Check 'the add-on page talks to the pretend irdash only' ($h.Contains("const API = 'http://localhost:$port';") -and -not $h.Contains("const API = 'http://localhost:8199';"))
[IO.File]::WriteAllText($html, $h, (New-Object Text.UTF8Encoding($false)))
$url = 'file:///' + ($html -replace '\\', '/')

$b = Start-DeckBrowser 9384
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  $null = Invoke-DeckJs $page "(() => { __sd.cfg.fakeFetch = false; __sd.connect(); return 1; })()"
  Start-Sleep -Seconds 3

  Assert-RigFree -Where '1. keys gone'
  ''; '1. the deck goes to sleep (no opener key showing) while irdash answers'
  Check 'the page is hidden (its own timers are slowed)' ((Invoke-DeckJs $page '__sd.visibility()') -eq 'hidden')
  Check 'with the opener keys showing the add-on asks /deck/summary' ((Hits '/deck/summary' (Get-Date).AddSeconds(-20)).Count -ge 1)
  $null = Invoke-DeckJs $page '(() => { Object.values(SCREENS).forEach(s => s.keys.clear()); docKeys.clear(); return 1; })()'
  Check 'no opener key is showing now' ((Invoke-DeckJs $page 'openerShowing()') -eq $false)
  $t0 = Get-Date; Start-Sleep -Seconds 12
  $beats = (Hits '/deck/beat' $t0).Count
  Check "with no key showing a heartbeat still goes out ($beats in 12 s; 2 to 3 expected)" ($beats -ge 2 -and $beats -le 4)
  Check 'and nothing else is asked (no /deck/summary, no screen route)' ((Hits '/deck/summary' $t0).Count -eq 0 -and (Hits '/overlays' $t0).Count -eq 0)

  Assert-RigFree -Where '2. irdash gone'
  ''; '2. irdash goes away (restart) and comes back while no key shows'
  Set-Content $mode 'down'
  Start-Sleep -Seconds 25
  Check 'the add-on page is still alive during the outage' ((Invoke-DeckJs $page '1 + 1') -eq 2)
  $back = Get-Date; Set-Content $mode 'good'
  $first = $null
  for ($i = 0; $i -lt 100 -and -not $first; $i++) { Start-Sleep -Milliseconds 200; $x = Hits '/deck/beat' $back; if ($x.Count -gt 0) { $first = $x[0] } }
  $lag = if ($first) { [math]::Round(($first - $back.ToUniversalTime()).TotalSeconds, 1) } else { 99 }
  Check "the add-on's next request lands $lag s after irdash is back (limit 10 s), page hidden" ($lag -le 10)

  Assert-RigFree -Where '3. keys back'
  ''; '3. the deck wakes: a key appears and the add-on asks at once'
  $t1 = Get-Date
  $null = Invoke-DeckJs $page '(() => { __sd.show("main"); return 1; })()'
  $got = $null
  for ($i = 0; $i -lt 20 -and -not $got; $i++) { Start-Sleep -Milliseconds 100; $x = Hits '/deck/summary' $t1; if ($x.Count -gt 0) { $got = $x[0] } }
  $lag2 = if ($got) { [math]::Round(($got - $t1.ToUniversalTime()).TotalSeconds, 1) } else { 99 }
  Check "willAppear makes the first /deck/summary come within 2 s ($lag2 s)" ($lag2 -le 2)
}
finally {
  Stop-DeckBrowser $b
  Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
  Remove-Item $mode, $reqlog -Force -ErrorAction SilentlyContinue
}

''; '4. the add-on source'
$plug = [IO.File]::ReadAllText((Join-Path $root 'deck-intro\plugin.html'))
Check 'the loop is a for(;;) on the worker timer: no counter that gives up, no setInterval' ($plug -match 'async function pollLoop\(\) \{[\s\S]{0,200}for \(;;\)' -and $plug -notmatch 'setInterval\(' -and $plug -notmatch 'giveUp|gaveUp|stopPolling')
Check 'the five Stream Deck events set askNow' ($plug -match "\['willAppear', 'keyDown', 'applicationDidLaunch', 'systemDidWakeUp', 'deviceDidConnect'\]\.indexOf\(e\.event\) >= 0\) askNow = true")
$dash = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
Check 'irdash has /deck/beat and Showcase.Beat marks the add-on alive' ($dash -match 'path == "/deck/beat"' -and $dash -match 'public static void Beat\(\) \{ lock \(gate\) \{ deckPollAt = DateTime.Now')
$doc = [IO.File]::ReadAllText((Join-Path $root 'dash\src\doctor.cs'))
Check 'the Stream Deck fix is tried at most once an hour (GapMin = 60 and the check in ApplyFixes)' ($doc -match 'fixes\["streamdeck"\][^\n]*GapMin = 60' -and $doc -match 'fx\.GapMin > 0 && t\.N > 0 && \(DateTime\.Now - t\.Last\)\.TotalMinutes < fx\.GapMin' -and $doc -match '!can \|\| spent \|\| hourly')
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
