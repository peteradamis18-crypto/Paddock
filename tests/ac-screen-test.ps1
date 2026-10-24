# AC screen test (2026-10-23): the AC screen of the deck add-on (deck-intro\plugin.html, class Ac) in headless Chrome with a pretend
# Stream Deck app and a pretend irdash /ac (tests\deck-harness.ps1). OFFLINE: nothing reaches the running irdash, the AC or Stream Deck.
#   1. the AC key on MORE opens the RigAC profile and all 32 keys get a picture; the layout is the planned one
#   2. every key sends the right /api/do command (power, cooler/warmer, modes, fans, presets, auto-cool, its start temperature)
#   3. the states: off, sending, auto-cool paused, heat, not connected, irdash not answering
# Pictures: tests\shots\deck-ac*.png
#   powershell -ExecutionPolicy Bypass -File tests\ac-screen-test.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
'AC screen test'

$fx = @{ '/guest' = @{}; '/overlays' = @{}; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false }
  '/mydrive' = @{}; '/sound' = @{ ready = $false }; '/deck/state' = @{}; '/workbench/state' = @{ open = $false }; '/debrief/state' = @{ open = $false }
  '/ac' = @{ connected = $true; read = $true; on = $true; mode = 2; fan = 102; target_c = 22.5; target_f = 73; room_f = 77; auto = $true; paused = $false; on_above_f = 76; off_below_f = 72; busy = $false; age = 3 } }
$html = Join-Path $env:TEMP 'ac-screen-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html)
$h2 = $h.Replace("['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1]];", "['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1], ['k-ac', 'com.peter.rigintro.ac', 0, 3]];").Replace("RigMyDrive: 'mydrive',", "RigMyDrive: 'mydrive', RigAC: 'ac',").Replace("return realFetch(url, opt);", "return Promise.resolve(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));")
Check 'the pretend Stream Deck app got the AC key and the RigAC profile, and cannot reach the real irdash' ($h2.Contains("'com.peter.rigintro.ac'") -and $h2.Contains('RigAC') -and -not $h2.Contains('return realFetch(url, opt);'))
[IO.File]::WriteAllText($html, $h2, (New-Object Text.UTF8Encoding($false)))

$b = Start-DeckBrowser 9371
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 3
  $null = Invoke-DeckJs $page "(() => { window.__apis = []; __sd.onApi = p => window.__apis.push(p); return 1; })()"
  function Apis { @(Invoke-DeckJs $page 'window.__apis') }
  function ClearApis { $null = Invoke-DeckJs $page 'window.__apis.length = 0' }
  function Press($c, $r, $wait = 400) { $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep($wait); return 1; })()" }
  function Fx($js, $wait = 1500) { $null = Invoke-DeckJs $page "(async () => { const m = __sd.fx['/ac']; $js; await __sd.sleep($wait); return 1; })()" }
  function Sheet($name) { $null = Invoke-DeckJs $page "(() => { const s=Ac; if(s.live) for(const pos of Object.keys(s.tiles)) if(s.looks[pos]) __sd.images[s.tiles[pos]]=s.encode(pos); return 1; })()"; Start-Sleep -Milliseconds 1000; return Save-DeckSheet $page (Join-Path $shots "$name.png") }
  function Reg($c, $r) { Invoke-DeckJs $page "(() => { const r = Ac.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return r ? { t: r.text, s: r.sub, st: r.style, a: r.act, g: r.arg, w: r.w } : null; })()" }
  function Req($c, $r, $re, $what) { ClearApis; Press $c $r 700; $a = @(Apis); $n = @($a | Where-Object { $_ -match $re }).Count; Check "$what -> $re" ($n -ge 1) ('requests: ' + ($a -join ' ')) }
  function Cur { Invoke-DeckJs $page '__sd.cur' }

  Assert-RigFree -Where '1. open'
  '1. the AC key opens the AC screen'
  $m = Invoke-DeckJs $page "__sd.measureOpen('ac')"
  Start-Sleep -Milliseconds 1200
  Check 'AC opens: it asked for the RigAC profile and all 32 keys have a picture' ((Cur) -eq 'RigAC' -and (Sheet 'deck-ac') -eq 32)
  $r = Reg 0 0; Check 'POWER: AC ON, green, toggles power' ($r.t -eq 'AC ON' -and $r.st -eq 'go' -and $r.a -eq 'acpower' -and $r.w -eq 1)
  $r = Reg 1 0; Check 'the ROOM key shows nothing to press' (-not $r.a)
  Check 'every region is ONE key (text across two keys is cut by the bezels)' ((Invoke-DeckJs $page "Ac.regions.every(x => x.w === 1 && x.h === 1)") -eq $true)
  $r = Reg 3 0; Check 'COOLER - / 73 F TARGET / + WARMER on the top row' ((Reg 2 0).a -eq 'actemp' -and $r.t -match '^73.F$' -and $r.s -eq 'TARGET' -and (Reg 4 0).a -eq 'actemp')
  Check 'presets MAX COOL / COMFORT / QUIET top right' ((Reg 5 0).t -eq 'MAX COOL' -and (Reg 6 0).t -eq 'COMFORT' -and (Reg 7 0).t -eq 'QUIET')
  Check 'modes COOL AUTO DRY FAN ONLY HEAT on row 2, COOL lit' ((Reg 0 1).t -eq 'COOL' -and (Reg 0 1).st -eq 'sel' -and (Reg 1 1).st -eq '' -and (Reg 3 1).t -eq 'FAN ONLY' -and (Reg 4 1).t -eq 'HEAT')
  Check 'fans LOW MEDIUM HIGH AUTO on row 3, AUTO lit' ((Reg 3 2).st -eq 'sel' -and (Reg 0 2).st -eq '' -and (Reg 0 2).t -eq 'LOW')
  $r = Reg 0 3; Check 'AUTO-COOL ON (gold) says when it stops' ($r.t -eq 'AUTO-COOL ON' -and $r.st -eq 'sel' -and $r.s -match '72.F')
  Check 'auto-cool start: - / 76 F / +' ((Reg 1 3).a -eq 'acstart' -and (Reg 2 3).t -match '^76.F$' -and (Reg 3 3).a -eq 'acstart')  Check 'EXIT bottom right' ((Reg 7 3).a -eq 'exit')

  Assert-RigFree -Where '2. presses'
  ''; '2. every key sends its command'
  Req 0 0 'c=acpower' 'POWER'
  Req 2 0 'c=actemp&a=-1' 'COOLER'
  Req 4 0 'c=actemp&a=%2B1' 'WARMER'
  Req 5 0 'c=acpreset&a=max' 'MAX COOL'
  Req 6 0 'c=acpreset&a=comfort' 'COMFORT'
  Req 7 0 'c=acpreset&a=quiet' 'QUIET'
  Req 0 1 'c=acmode&a=cool' 'COOL mode'
  Req 1 1 'c=acmode&a=auto' 'AUTO mode'
  Req 2 1 'c=acmode&a=dry' 'DRY mode'
  Req 3 1 'c=acmode&a=fan' 'FAN ONLY mode'
  Req 4 1 'c=acmode&a=heat' 'HEAT mode'
  Req 0 2 'c=acfan&a=low' 'fan LOW'
  Req 1 2 'c=acfan&a=medium' 'fan MEDIUM'
  Req 2 2 'c=acfan&a=high' 'fan HIGH'
  Req 3 2 'c=acfan&a=auto' 'fan AUTO'
  Req 0 3 'c=acauto' 'AUTO-COOL'
  Req 1 3 'c=acstart&a=-1' 'auto-cool start -'
  Req 3 3 'c=acstart&a=%2B1' 'auto-cool start +'  Start-Sleep -Milliseconds 800
  foreach ($k in @(@(1, 0, 'ROOM'), @(3, 0, 'TARGET'), @(2, 3, 'STARTS AT'))) { ClearApis; Press $k[0] $k[1] 400; $sent = @(Apis | Where-Object { $_ -match 'api/do' }); Check "$($k[2]) sends nothing" ($sent.Count -eq 0) ($sent -join ' ') }
  ClearApis; Press 2 0 50; Press 2 0 400; Check 'a doubled press (Stream Deck sends one press 2-3 times) is one step' (@(Apis | Where-Object { $_ -match 'actemp' }).Count -eq 1)

  Assert-RigFree -Where '3. states'
  ''; '3. the states'
  Fx 'm.on = false'
  Check 'off: AC OFF, grey; no mode or fan is lit' ((Reg 0 0).t -eq 'AC OFF' -and (Reg 0 0).st -eq 'grey' -and (Reg 0 1).st -eq '' -and (Reg 3 2).st -eq '')
  $null = Sheet 'deck-ac-off'
  Fx 'm.on = true; m.busy = true'
  $null = Sheet 'deck-ac-sending'
  Check 'sending: the banner says so (its picture changes with busy)' ((Invoke-DeckJs $page "Ac.regions.find(x => x.c === 1 && x.r === 0).extra") -match 'true\]$')
  Fx 'm.busy = false; m.paused = true'
  Check 'paused after a manual OFF: auto-cool says so, amber' ((Reg 0 3).s -match 'PAUSED' -and (Reg 0 3).st -eq 'amber')
  Fx 'm.paused = false; m.auto = false'
  Check 'auto-cool off: grey, and its start keys are dim' ((Reg 0 3).t -eq 'AUTO-COOL OFF' -and (Reg 0 3).st -eq 'grey' -and (Reg 1 3).st -eq 'dim')
  Fx 'm.auto = true; m.mode = 4'
  Check 'heating: HEAT is lit amber' ((Reg 4 1).st -eq 'amber' -and (Reg 0 1).st -eq '')
  $null = Sheet 'deck-ac-heat'
  Fx 'm.mode = 2; m.connected = false'
  Check 'not connected: one message and EXIT' ((Reg 0 0).t -eq 'AC NOT CONNECTED' -and (Reg 7 3).a -eq 'exit')
  $null = Sheet 'deck-ac-notconnected'
  Fx 'm.connected = true'
  Press 7 3 700
  Check 'EXIT returns to your own keys' ((Cur) -eq 'main')
}
finally { Stop-DeckBrowser $b }
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
