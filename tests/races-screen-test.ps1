# RACES screen test (2026-11-06): the deck add-on's RACES screen (deck-intro\plugin.html, class Races) in headless Chrome with a pretend
# Stream Deck app and a pretend irdash (tests\deck-harness.ps1). OFFLINE: nothing reaches the running irdash, a video or Stream Deck.
#   1. the RACES key opens RigRaces: the races newest first, one key each, kept ones gold, free disk space, EXIT
#   2. a race opens on a press: track, when, length, best lap, size; WATCH / YOUTUBE / KEEP send their command
#   3. DELETE asks first: the first press sends nothing and says PRESS AGAIN, the second (within 5 s) deletes
#   4. more than 24 races: pages; no races: one plain message
# Pictures: tests\shots\deck-races*.png
#   powershell -ExecutionPolicy Bypass -File tests\races-screen-test.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
'RACES screen test'

$now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
function Race($id, $track, $type, $agoMin, $min, $laps, $best, $mb, $saved) { @{ id = $id; track = $track; car = 'Porsche 718 Cayman GT4'; type = $type; startMs = $now - $agoMin * 60000; min = $min; laps = $laps; best = $best; mb = $mb; saved = $saved; exported = $false } }
$three = @((Race 'r-today' 'Road Atlanta' 'Race' 30 20 12 87.102 1175 $true), (Race 'r-quali' 'Road Atlanta' 'Qualify' 60 10 5 87.5 500 $false), (Race 'r-old' 'Road America' 'Race' 21000 19 8 132.4 1106 $false))
$fx = @{ '/guest' = @{}; '/overlays' = @{}; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false }
  '/mydrive' = @{}; '/sound' = @{ ready = $false }; '/deck/state' = @{}; '/workbench/state' = @{ open = $false }; '/debrief/state' = @{ open = $false }; '/ac' = @{ connected = $false }
  '/api/rec/races' = @{ freeGb = 298; races = $three } }
$html = Join-Path $env:TEMP 'races-screen-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html)
$h2 = $h.Replace("['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1]];", "['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1], ['k-races', 'com.peter.rigintro.races', 3, 3]];").Replace("RigMyDrive: 'mydrive',", "RigMyDrive: 'mydrive', RigRaces: 'races',").Replace("return realFetch(url, opt);", "return Promise.resolve(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));")
Check 'the pretend Stream Deck app got the RACES key and the RigRaces profile, and cannot reach the real irdash' ($h2.Contains("'com.peter.rigintro.races'") -and $h2.Contains('RigRaces') -and -not $h2.Contains('return realFetch(url, opt);'))
[IO.File]::WriteAllText($html, $h2, (New-Object Text.UTF8Encoding($false)))

$b = Start-DeckBrowser 9373
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 3
  $null = Invoke-DeckJs $page "(() => { window.__apis = []; __sd.onApi = p => window.__apis.push(p); return 1; })()"
  function Apis { @(Invoke-DeckJs $page 'window.__apis') }
  function ClearApis { $null = Invoke-DeckJs $page 'window.__apis.length = 0' }
  function Press($c, $r, $wait = 400) { $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep($wait); return 1; })()" }
  function Fx($js, $wait = 2500) { $null = Invoke-DeckJs $page "(async () => { const m = __sd.fx['/api/rec/races']; $js; await __sd.sleep($wait); return 1; })()" }
  function Sheet($name) { $null = Invoke-DeckJs $page "(() => { const s=Races; if(s.live) for(const pos of Object.keys(s.tiles)) if(s.looks[pos]) __sd.images[s.tiles[pos]]=s.encode(pos); return 1; })()"; Start-Sleep -Milliseconds 1000; return Save-DeckSheet $page (Join-Path $shots "$name.png") }
  function Reg($c, $r) { Invoke-DeckJs $page "(() => { const r = Races.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return r ? { t: String(r.text), s: String(r.sub || ''), st: r.style, a: r.act, g: r.arg, w: r.w } : null; })()" }
  function Sent($re) { @(Apis | Where-Object { $_ -match 'api/do' -and $_ -match $re }).Count }
  function Cur { Invoke-DeckJs $page '__sd.cur' }

  Assert-RigFree -Where '1. list'
  '1. the list'
  $null = Invoke-DeckJs $page "__sd.measureOpen('races')"
  Start-Sleep -Milliseconds 1500
  Check 'RACES opens the RigRaces profile and all 32 keys get a picture' ((Cur) -eq 'RigRaces' -and (Sheet 'deck-races') -eq 32)
  $r = Reg 0 0; Check 'newest first: ROAD ATLANTA, TODAY, 20 MIN, gold because it is kept' ($r.t -eq 'Road Atlanta' -and $r.s -match '^TODAY \d\d:\d\d . 20 MIN$' -and $r.st -eq 'sel' -and $r.a -eq 'pick' -and $r.g -eq 'r-today') ($r | ConvertTo-Json -Compress)
  $r = Reg 1 0; Check 'races only: the qualifying is not in the list, the older race is next' ($r.g -eq 'r-old') ($r | ConvertTo-Json -Compress)
  $r = Reg 1 0; Check 'an older one shows its date' ($r.t -eq 'Road America' -and $r.s -match '^[A-Z]{3} \d{1,2} \d\d:\d\d . 19 MIN$') ($r | ConvertTo-Json -Compress)
  Check 'ALL SESSIONS, free disk space and EXIT on the bottom row; no page keys' ((Reg 2 3).t -eq 'ALL SESSIONS' -and (Reg 3 3).t -eq '298 GB' -and (Reg 7 3).a -eq 'exit' -and -not (Reg 0 3) -and -not (Reg 1 3))
  Press 2 3 500
  $r = Reg 1 0; Check 'ALL SESSIONS shows the qualifying too, marked QUALI, and the key turns into RACES ONLY' ($r.s -match '^QUALI . TODAY' -and $r.st -eq '' -and (Reg 2 3).t -eq 'RACES ONLY') ($r | ConvertTo-Json -Compress)
  $null = Sheet 'deck-races-all'
  Press 2 3 500
  Check 'every key is ONE key (text over two keys is cut by the bezels)' ((Invoke-DeckJs $page "Races.regions.every(x => (x.w === 1 && x.h === 1) || !x.act)") -eq $true)

  Assert-RigFree -Where '2. one race'
  ''; '2. one race'
  ClearApis; Press 0 0 500
  Check 'pressing a race opens it and sends nothing' ((Reg 0 0).t -eq 'Road Atlanta' -and (Reg 0 0).a -eq $null -and (Sent '.') -eq 0)
  Check 'its facts: TODAY, 20 MIN / 12 LAPS, best lap 1:27.102, 1.1 GB' ((Reg 1 0).t -match '^TODAY' -and (Reg 2 0).t -eq '20 MIN' -and (Reg 2 0).s -eq '12 LAPS' -and (Reg 3 0).t -eq '1:27.102' -and (Reg 4 0).t -eq '1.1 GB')
  Check 'SHARE ON YOUTUBE first, DELETE FROM PC next, WATCH third - plain words' ((Reg 0 1).t -eq 'SHARE' -and (Reg 0 1).s -eq 'ON YOUTUBE' -and (Reg 1 1).t -eq 'DELETE' -and (Reg 1 1).s -eq 'FROM PC' -and (Reg 2 1).t -eq 'WATCH')
  Check 'a race that is kept has no KEEP key (races are kept by themselves)' (-not (Reg 3 1))
  $null = Sheet 'deck-races-one'
  ClearApis; Press 2 1 700; Check 'WATCH -> racewatch with its id' ((Sent 'c=racewatch&a=r-today') -eq 1)
  Start-Sleep -Milliseconds 800
  ClearApis; Press 0 1 700; Check 'SHARE -> raceexport with its id, and the screen says what to do next' ((Sent 'c=raceexport&a=r-today') -eq 1 -and (Reg 4 1).t -match 'YOUTUBE IS OPEN')

  Assert-RigFree -Where '3. delete'
  ''; '3. DELETE asks first'
  Start-Sleep -Milliseconds 800
  ClearApis; Press 1 1 500
  Check 'the first DELETE sends nothing and asks: PRESS AGAIN' ((Sent '.') -eq 0 -and (Reg 1 1).t -eq 'PRESS AGAIN' -and (Reg 1 1).st -eq 'amber')
  $null = Sheet 'deck-races-delete-armed'
  Start-Sleep -Milliseconds 800
  ClearApis; Press 1 1 700
  Check 'the second DELETE within 5 s -> racedelete with its id, and back to the list' ((Sent 'c=racedelete&a=r-today') -eq 1 -and (Reg 0 0).a -eq 'pick')
  Press 1 0 400; Start-Sleep -Milliseconds 800; ClearApis; Press 1 1 400; Start-Sleep -Milliseconds 5600
  Check 'DELETE not pressed again within 5 s: it calms down and nothing was deleted' ((Reg 1 1).t -eq 'DELETE' -and (Sent 'racedelete') -eq 0)
  Start-Sleep -Milliseconds 800
  ClearApis; Press 3 1 700; Check 'KEEP on a race not kept -> recsave with its id' ((Sent 'c=recsave&a=r-old') -eq 1)
  Press 0 3 500; Check 'BACK returns to the list' ((Reg 0 0).a -eq 'pick')

  Assert-RigFree -Where '4. pages'
  ''; '4. pages and empty'
  Fx "m.races = Array.from({length: 30}, (_, i) => ({ id: 'p' + i, track: 'Track ' + i, car: 'Car', type: 'Race', startMs: Date.now() - i * 86400000, min: 20, laps: 10, best: 90, mb: 1000, saved: false, exported: false }))"
  Check '30 races: 24 on the first page, OLDER key' ((Reg 7 2).g -eq 'p23' -and (Reg 1 3).a -eq 'page' -and -not (Reg 0 3))
  Press 1 3 500
  Check 'OLDER shows the next 6 and a NEWER key' ((Reg 0 0).g -eq 'p24' -and (Reg 5 0).g -eq 'p29' -and (Reg 0 3).a -eq 'page')
  $null = Sheet 'deck-races-page2'
  Press 0 3 400
  Fx 'm.races = []'
  Check 'no races: one plain message, EXIT still there' ((Reg 0 0).t -eq 'NO RACES YET' -and (Reg 7 3).a -eq 'exit')
  Press 7 3 700
  Check 'EXIT returns to your own keys' ((Cur) -eq 'main')
}
finally { Stop-DeckBrowser $b }
''; '5. a race missing from Videos\Paddock is marked, never deleted (W0-2; dash\src\recorder.cs SyncExports, run for real in tests\recorder-safety-test.ps1)'
$rec = [IO.File]::ReadAllText((Join-Path $root 'dash\src\recorder.cs'))
$i5 = $rec.IndexOf('static void SyncExports()'); $sync = if ($i5 -ge 0) { $rec.Substring($i5, $rec.IndexOf('static RecSess FindDone', $i5) - $i5) } else { '' }
Check 'only races that were seen in Videos\Paddock before count (vault\exported.txt)' ($sync -match 'if \(there\) \{ seen\.Add\(s\.Id\); continue; \}' -and $sync -match 'if \(seen\.Contains\(s\.Id\)\) missing\.Add\(s\.Id\);')
Check 'a renamed, moved or briefly missing export never deletes the race (2026-11-13: it used to)' ($sync -notmatch 'Delete\(' -and $rec -notmatch 'LinkCount')
Check 'the check runs when the list is read and in the recorder''s housekeeping, at most every 15 s' ($sync -match 'now - lastExportSync < 15000' -and $rec -match 'try \{ SyncExports\(\); \} catch \(Exception ex\)' -and $rec -match 'RetainSessions\(\); \} catch \{ \} try \{ SyncExports\(\); \} catch \{ \}')
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
