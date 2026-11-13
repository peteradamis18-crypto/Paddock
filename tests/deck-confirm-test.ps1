# deck-confirm-test.ps1 - SHUT DOWN PC / SLEEP PC ask once (W0-1): the add-on's CONFIRM screen (deck-intro\plugin.html, class Confirm)
# in headless Chrome with a pretend Stream Deck app and a pretend irdash (tests\deck-harness.ps1, tests\deck-mock.js).
# OFFLINE: nothing reaches the running irdash, Stream Deck or Windows; every /api/do the add-on sends is only recorded.
#   1. SHUT DOWN PC opens RigConfirm: the question, one big gold YES, SHUT DOWN with the count 5 on it, red EXIT at 7,3
#   2. YES sends exactly one /api/do?c=shutdown; a doubled YES (two presses 60 ms apart, then more) still sends one
#   3. EXIT sends nothing and goes back to your own keys
#   4. nothing pressed: the count runs 5-4-3-2-1, after 6 s the screen is closed and nothing was sent
#   5. SLEEP PC opens the same screen saying YES, SLEEP and sends /api/do?c=sleep
# Pictures: tests\shots\rework\confirm-*.png
#   powershell -ExecutionPolicy Bypass -File tests\deck-confirm-test.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
'CONFIRM screen test'

$fx = @{ '/guest' = @{}; '/overlays' = @{ onCount = 0; widgets = @(); presets = @() }; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false }
  '/mydrive' = @{}; '/sound' = @{ ready = $false }; '/workbench/state' = @{ open = $false }; '/debrief/state' = @{ open = $false }; '/ac' = @{ connected = $false }
  '/api/rec/races' = @{ freeGb = 1; races = @() } }
$html = Join-Path $env:TEMP 'deck-confirm-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html)
$h2 = $h.Replace("return realFetch(url, opt);", "return Promise.resolve(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));")
Check 'the pretend Stream Deck app has the SHUT DOWN / SLEEP keys and RigConfirm, and cannot reach the real irdash' ($h2.Contains("'k-shutdown'") -and $h2.Contains('RigConfirm') -and -not $h2.Contains('return realFetch(url, opt);'))
[IO.File]::WriteAllText($html, $h2, (New-Object Text.UTF8Encoding($false)))

$b = Start-DeckBrowser 9381
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 3
  $null = Invoke-DeckJs $page "(() => { window.__apis = []; __sd.onApi = p => window.__apis.push(p); return 1; })()"
  function Apis { @(Invoke-DeckJs $page 'window.__apis') }
  function ClearApis { $null = Invoke-DeckJs $page 'window.__apis.length = 0' }
  function Sent($re) { @(Apis | Where-Object { $_ -match '^/api/do' -and $_ -match $re }).Count }
  function Cur { Invoke-DeckJs $page '__sd.cur' }
  function Open($which) { $null = Invoke-DeckJs $page "(async () => { __sd.pressOpener('$which'); await __sd.sleep(700); return 1; })()" }
  function Press($c, $r, $wait = 300) { $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep($wait); return 1; })()" }
  function Reg($c, $r) { Invoke-DeckJs $page "(() => { const r = Confirm.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return r ? { t: String(r.text), s: String(r.sub || ''), st: r.style, a: r.act, w: r.w, h: r.h } : null; })()" }
  function Sheet($name) { $null = Invoke-DeckJs $page "(() => { const s=Confirm; if(s.live) for(const pos of Object.keys(s.tiles)) if(s.looks[pos]) __sd.images[s.tiles[pos]]=s.encode(pos); return 1; })()"; Start-Sleep -Milliseconds 600; return Save-DeckSheet $page (Join-Path $shots "$name.png") }

  Assert-RigFree -Where '1. open'
  '1. SHUT DOWN PC opens the question'
  Check 'the SHUT DOWN PC opener key got its own picture (red SHUT DOWN / PC)' ([bool](Invoke-DeckJs $page "__sd.images['k-shutdown']"))
  ClearApis; Open 'shutdown'
  Check 'it switches the deck to RigConfirm and all 32 keys get a picture' ((Cur) -eq 'RigConfirm' -and (Sheet 'confirm-shutdown-open') -eq 32)
  $y = Reg 3 2
  Check "one big gold YES, SHUT DOWN across the middle rows (3 x 2 keys) with the count on it ('$($y.s)')" ($y.t -eq 'YES, SHUT DOWN' -and $y.st -eq 'sel' -and $y.a -eq 'yes' -and $y.w -eq 3 -and $y.h -eq 2 -and $y.s -match '^[45]$') ($y | ConvertTo-Json -Compress)
  Check 'the question across the top row says what it does in plain words' ((Reg 0 0).t -eq 'TURN THE PC OFF?' -and (Reg 0 0).s -match 'within 5 seconds')
  Check 'red EXIT at 7,3' ((Reg 7 3).a -eq 'exit' -and (Reg 7 3).st -eq 'stop' -and (Reg 7 3).t -eq 'EXIT')
  Check 'opening it sent nothing' ((Sent '.') -eq 0)

  Assert-RigFree -Where '2. YES'
  ''; '2. YES sends one shutdown, also when doubled'
  $null = Invoke-DeckJs $page "(async () => { __sd.pressTile(3, 1); await __sd.sleep(60); __sd.pressTile(4, 2); await __sd.sleep(900); __sd.pressTile(2, 1); await __sd.sleep(400); return 1; })()"
  $n = Sent '^/api/do\?c=shutdown$'
  Check "YES pressed three times (60 ms and 1 s apart): exactly one /api/do?c=shutdown (got $n), nothing else" ($n -eq 1 -and (Sent '.') -eq 1) ((Apis) -join ', ')
  Check 'the screen says SHUTTING DOWN and has no YES any more' ((Reg 3 1).t -eq 'SHUTTING DOWN' -and -not (Reg 3 1).a)
  $null = Sheet 'confirm-shutdown-sent'
  Start-Sleep -Milliseconds 2800
  Check 'it goes back to your own keys by itself afterwards' ((Cur) -eq 'main')

  Assert-RigFree -Where '3. EXIT'
  ''; '3. EXIT'
  ClearApis; Open 'shutdown'; Press 7 3 600
  Check 'EXIT sends nothing and goes back to your own keys' ((Sent '.') -eq 0 -and (Cur) -eq 'main')

  Assert-RigFree -Where '4. timeout'
  ''; '4. nothing pressed'
  ClearApis; Open 'shutdown'
  $counts = @(); $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt 6.2) { $r = Reg 3 1; if ($r -and $r.s -and ($counts.Count -eq 0 -or $counts[-1] -ne $r.s)) { $counts += $r.s }; if ($r -and $r.s -eq '2' -and -not (Test-Path (Join-Path $shots 'confirm-shutdown-count2.png'))) { $null = Sheet 'confirm-shutdown-count2' }; Start-Sleep -Milliseconds 150 }
  Check "the count on YES runs down ($($counts -join '-'))" (($counts -join '-') -match '4-3-2-1$')
  Check 'after 6 s the screen is closed and nothing was sent' ((Cur) -eq 'main' -and (Sent '.') -eq 0) ((Apis) -join ', ')
  Check 'the confirm screen holds no YES any more (a late press could not send)' ((Invoke-DeckJs $page '!Confirm.live && Confirm.until === 0 && !Confirm.sentAt') -eq $true)

  Assert-RigFree -Where '5. sleep'
  ''; '5. SLEEP PC'
  ClearApis; Open 'sleep'
  Check 'SLEEP PC opens the same screen saying YES, SLEEP' ((Cur) -eq 'RigConfirm' -and (Reg 3 1).t -eq 'YES, SLEEP' -and (Reg 0 0).t -eq 'PUT THE PC TO SLEEP?')
  $null = Sheet 'confirm-sleep-open'
  Press 3 1 500
  Check 'YES sends exactly one /api/do?c=sleep' ((Sent '^/api/do\?c=sleep$') -eq 1 -and (Sent '.') -eq 1) ((Apis) -join ', ')
  Start-Sleep -Milliseconds 2800
}
finally { Stop-DeckBrowser $b }

''; '6. the other side'
$dash = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs')); $ir = [IO.File]::ReadAllText((Join-Path $root 'src\irdeck.cs'))
Check 'irdash /api/do: shutdown -> irdeck "power off", sleep -> irdeck "power sleep" (after the repeat guard)' ($dash -match 'if \(dc == "shutdown" \|\| dc == "sleep"\) \{ bool pk = StartIrdeck\(dc == "shutdown" \? "power off" : "power sleep"\)' -and $dash.IndexOf('DeckDo.Allow(dc') -lt $dash.IndexOf('dc == "shutdown" || dc == "sleep"'))
Check 'irdeck keeps power off / sleep; kids mode still blocks them (they no longer come through a key exe)' ($ir -match 'case "power": return CmdPower' -and $ir -match 'KidsLocked\(\)\) \{ Log\("power " \+ c \+ ": kids mode is on')
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
