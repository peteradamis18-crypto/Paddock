# AI LEVEL screen test (2026-10-23): the AI LEVEL screen of the deck add-on (deck-intro\plugin.html, class AiLevel) in headless Chrome with a
# pretend Stream Deck app and the REAL /ailevel answer (dash\src\ailevel.cs compiled and run for three saved choices). OFFLINE: nothing
# reaches the running irdash, iRacing or Stream Deck.
#   1. the AI LEVEL key opens the RigAiLevel profile, all 32 keys get a picture, every key is one cell
#   2. every key sends its command; the keys that only show a number send nothing; a doubled press is one step
#   3. the choice is lit: default (adaptive low), HIGH, a range 40 to 70; irdash not ready / not answering
# Pictures: tests\shots\deck-ailevel*.png
#   powershell -ExecutionPolicy Bypass -File tests\ailevel-screen-test.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
'AI LEVEL screen test'

# the real answers
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP ('ailevel-dump-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
& $csc /nologo /target:exe "/out:$tmp\dump.exe" /r:System.dll /r:System.Core.dll (Join-Path $root 'dash\src\ailevel.cs') (Join-Path $PSScriptRoot 'ailevel-dump.cs') | Out-Null
$ans = @{}
if (Test-Path "$tmp\dump.exe") { foreach ($l in (& "$tmp\dump.exe")) { $p = $l.Split("`t", 2); if ($p.Count -eq 2) { $ans[$p[0]] = $p[1] } } }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Check 'ailevel.cs gave the three real answers' ($ans.Count -eq 3)
if ($ans.Count -ne 3) { "$pass passed, $fail failed"; exit 1 }

$fx = @{ '/guest' = @{}; '/overlays' = @{}; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false }
  '/mydrive' = @{}; '/sound' = @{ ready = $false }; '/deck/state' = @{}; '/workbench/state' = @{ open = $false }; '/debrief/state' = @{ open = $false }
  '/ac' = @{ connected = $false } ; '/ailevel' = ($ans['DEFAULT'] | ConvertFrom-Json) }
$html = Join-Path $env:TEMP 'ailevel-screen-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html)
$h2 = $h.Replace("['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1]];", "['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1], ['k-ai', 'com.peter.rigintro.ailevel', 2, 0]];").Replace("RigMyDrive: 'mydrive',", "RigMyDrive: 'mydrive', RigAiLevel: 'ailevel',").Replace("return realFetch(url, opt);", "return Promise.resolve(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));")
Check 'the pretend Stream Deck app got the AI LEVEL key and the RigAiLevel profile, and cannot reach the real irdash' ($h2.Contains("'com.peter.rigintro.ailevel'") -and $h2.Contains('RigAiLevel') -and -not $h2.Contains('return realFetch(url, opt);'))
[IO.File]::WriteAllText($html, $h2, (New-Object Text.UTF8Encoding($false)))

$b = Start-DeckBrowser 9372
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 3
  $null = Invoke-DeckJs $page "(() => { window.__apis = []; __sd.onApi = p => window.__apis.push(p); return 1; })()"
  function Apis { @(Invoke-DeckJs $page 'window.__apis') }
  function ClearApis { $null = Invoke-DeckJs $page 'window.__apis.length = 0' }
  function Press($c, $r, $wait = 400) { $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep($wait); return 1; })()" }
  function SetAns($json, $wait = 1500) { $js = $json.Replace('\', '\\').Replace("'", "\'"); $null = Invoke-DeckJs $page "(async () => { __sd.fx['/ailevel'] = JSON.parse('$js'); await __sd.sleep($wait); return 1; })()" }
  function Sheet($name) { $null = Invoke-DeckJs $page "(() => { const s=AiLevel; if(s.live) for(const pos of Object.keys(s.tiles)) if(s.looks[pos]) __sd.images[s.tiles[pos]]=s.encode(pos); return 1; })()"; Start-Sleep -Milliseconds 1000; return Save-DeckSheet $page (Join-Path $shots "$name.png") }
  function Reg($c, $r) { Invoke-DeckJs $page "(() => { const r = AiLevel.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return r ? { t: r.text, s: r.sub, st: r.style, a: r.act, g: r.arg, w: r.w } : null; })()" }
  function Req($c, $r, $re, $what) { ClearApis; Press $c $r 700; $a = @(Apis); $n = @($a | Where-Object { $_ -match $re }).Count; Check "$what -> $re" ($n -ge 1) ('requests: ' + ($a -join ' ')) }
  function Cur { Invoke-DeckJs $page '__sd.cur' }

  Assert-RigFree -Where '1. open'
  '1. the AI LEVEL key opens the screen'
  $m = Invoke-DeckJs $page "__sd.measureOpen('ailevel')"
  Start-Sleep -Milliseconds 1200
  Check 'AI LEVEL opens: it asked for the RigAiLevel profile and all 32 keys have a picture' ((Cur) -eq 'RigAiLevel' -and (Sheet 'deck-ailevel') -eq 32)
  Check 'every region is ONE key (text across two keys is cut by the bezels)' ((Invoke-DeckJs $page "AiLevel.regions.every(x => x.w === 1 && x.h === 1)") -eq $true)
  Check 'the default is iRacing''s own: ADAPTIVE lit, LOW lit, MEDIUM and HIGH not' ((Reg 0 1).st -eq 'sel' -and (Reg 1 1).st -eq 'sel' -and (Reg 2 1).st -eq '' -and (Reg 3 1).st -eq '' -and (Reg 0 2).st -eq 'label')
  Check 'the banner says what the next race gets (ADAPTIVE / LOW)' ((Reg 1 0).t -eq 'ADAPTIVE' -and (Reg 1 0).s -eq 'LOW')
  Check 'EXIT bottom right, START bottom left' ((Reg 7 3).a -eq 'exit' -and (Reg 0 3).g -eq 'start')

  Assert-RigFree -Where '2. presses'
  ''; '2. every key sends its command'
  Req 0 1 'c=ailevel&a=adaptive' 'ADAPTIVE'
  Req 1 1 'c=ailevel&a=low' 'LOW'
  Req 2 1 'c=ailevel&a=medium' 'MEDIUM'
  Req 3 1 'c=ailevel&a=high' 'HIGH'
  Req 0 2 'c=ailevel&a=range' 'RANGE'
  Req 1 2 'c=ailevel&a=min-' 'MIN lower'
  Req 3 2 'c=ailevel&a=min%2B' 'MIN higher'
  Req 4 2 'c=ailevel&a=max-' 'MAX lower'
  Req 6 2 'c=ailevel&a=max%2B' 'MAX higher'
  Req 0 3 'c=ailevel&a=start' 'START'
  Start-Sleep -Milliseconds 800
  foreach ($k in @(@(0, 0, 'the AI LEVEL label'), @(1, 0, 'the banner'), @(2, 2, 'the MIN number'), @(5, 2, 'the MAX number'))) { ClearApis; Press $k[0] $k[1] 400; $sent = @(Apis | Where-Object { $_ -match 'api/do' }); Check "$($k[2]) sends nothing" ($sent.Count -eq 0) ($sent -join ' ') }
  ClearApis; Press 3 1 50; Press 3 1 400; Check 'a doubled press (Stream Deck sends one press 2-3 times) is one step' (@(Apis | Where-Object { $_ -match 'a=high' }).Count -eq 1)

  Assert-RigFree -Where '3. states'
  ''; '3. the states'
  SetAns $ans['HIGH']
  Check 'HIGH chosen: HIGH is lit, LOW is not, the banner says HIGH' ((Reg 3 1).st -eq 'sel' -and (Reg 1 1).st -eq '' -and (Reg 1 0).s -eq 'HIGH')
  $null = Sheet 'deck-ailevel-high'
  SetAns $ans['RANGE']
  Check 'a range 40 to 70: RANGE is lit, ADAPTIVE is not, the numbers are 40 and 70' ((Reg 0 2).st -eq 'sel' -and (Reg 0 1).st -eq 'label' -and (Reg 2 2).t -eq '40' -and (Reg 5 2).t -eq '70' -and (Reg 2 2).st -eq 'on' -and (Reg 1 0).t -eq 'RANGE' -and (Reg 1 0).s -eq '40 - 70')
  $null = Sheet 'deck-ailevel-range'
  SetAns '{"ready":false}'
  Check 'not ready: one message and EXIT' ((Reg 0 0).t -eq 'AI LEVEL NOT READY' -and (Reg 7 3).a -eq 'exit')
  $null = Sheet 'deck-ailevel-notready'
  SetAns $ans['DEFAULT']
  Press 7 3 700
  Check 'EXIT returns to your own keys' ((Cur) -eq 'main')
}
finally { Stop-DeckBrowser $b }
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
