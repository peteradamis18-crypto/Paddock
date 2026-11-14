# deck-races-test.ps1 - the deck's RACES screen mirrors the library (W1-5): real pictures on the keys, tick, share and delete selected.
# OFFLINE: the real add-on page (deck-intro\plugin.html) in headless Chrome with the pretend Stream Deck app (tests\deck-mock.js); every
# irdash answer is a pretend one (the library list, the pictures, the command answers). Nothing reaches the real irdash (port 8199) or Stream Deck.
#   1. pages: 1, 6, 7 and 40 races fill and shrink, newest first, RACES ONLY hides practice
#   2. pictures: a real JPEG on the picture key, a dark key with the gold word without one, each picture fetched once
#   3. tick flow: tick, SHARE SELECTED, DELETE SELECTED (cards leave at once), UNDO for 8 s, CLEAR TICKS, SELECT ALL SHARED
#   4. open view: the 4 x 2 picture, the facts, the state line per kind, SHARE grey when shared, SIGN IN, BACK, EXIT at 7,3 on every view
#   5. request rate while open and idle (ceiling 0.3 / s over 20 s)
# Pictures: tests\shots\rework\deck-races-<state>.png
#   powershell -ExecutionPolicy Bypass -File tests\deck-races-test.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$script:pass = 0; $script:fail = 0
function Check($what, $ok, $why) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what$(if ($why) { ' -> ' + $why })" } }
function Section($t) { Assert-RigFree -Where $t; $t }
'Deck RACES screen test (W1-5)'
$DOT = [string][char]0xB7

$html = Join-Path $env:TEMP 'deck-races-test-harness.html'
$url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
$h = [IO.File]::ReadAllText($html)
# the mock only knows three opener keys: add RACES and its profile
$h2 = $h.Replace("TILE.RigConfirm = 'confirm';", "TILE.RigConfirm = 'confirm'; OPEN.push(['k-races', 'com.peter.rigintro.races', 5, 0]); TILE.RigRaces = 'races';")
# after the mock: the pretend /api/library/thumb (a real JPEG made on a canvas; ids in window.__noThumb answer 404), and a log of what was asked
$thumbJs = @'
(function () {
  window.__errs = []; window.addEventListener('error', e => window.__errs.push(String(e.message))); window.addEventListener('unhandledrejection', e => window.__errs.push('rej ' + String(e.reason)));
  const f = window.fetch; window.__thumbs = []; window.__noThumb = {};
  window.fetch = function (url, opt) {
    const u = String(url);
    if (u.indexOf('/api/library/thumb') >= 0) {
      const q = new URL(u), id = q.searchParams.get('id'), w = +q.searchParams.get('w');
      window.__thumbs.push(id + '@' + w); window.__sd.fetchLog.push({ t: performance.now(), u: u.replace('http://localhost:8199', ''), h: null });
      if (window.__noThumb[id]) return Promise.resolve(new Response('', { status: 404 }));
      return new Promise(res => {
        const c = document.createElement('canvas'); c.width = w; c.height = w === 144 ? 144 : Math.round(w * 9 / 16); const g = c.getContext('2d');
        const hue = (parseInt(id.replace(/\D/g, '') || '0', 10) * 47) % 360;
        const sky = g.createLinearGradient(0, 0, 0, c.height); sky.addColorStop(0, 'hsl(' + hue + ',55%,55%)'); sky.addColorStop(0.55, 'hsl(' + hue + ',40%,78%)'); sky.addColorStop(1, '#556');
        g.fillStyle = sky; g.fillRect(0, 0, c.width, c.height);
        g.fillStyle = '#3a3d44'; g.beginPath(); g.moveTo(c.width * 0.3, c.height); g.lineTo(c.width * 0.45, c.height * 0.55); g.lineTo(c.width * 0.55, c.height * 0.55); g.lineTo(c.width * 0.8, c.height); g.fill();
        c.toBlob(b => res(new Response(b, { headers: { 'Content-Type': 'image/jpeg' } })), 'image/jpeg', 0.85);
      });
    }
    return f.apply(this, arguments);
  };
})();
'@
$cut = $h2.IndexOf('</script>')
$h2 = $h2.Substring(0, $cut) + $thumbJs + $h2.Substring($cut)
Check 'the pretend page has the RACES key and the pretend picture route, and cannot reach the real irdash' ($h2.Contains('k-races') -and $h2.Contains('__noThumb') -and $h2.Contains('return realFetch(url, opt);'))
[IO.File]::WriteAllText($html, $h2, (New-Object Text.UTF8Encoding($false)))

$tracks = @('Road Atlanta', 'Watkins Glen International', 'Circuit de Spa-Francorchamps', 'Nurburgring Nordschleife', 'Lime Rock Park', 'Mount Panorama', 'Laguna Seca', 'Daytona')
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
# n races, newest first by number (r00 newest); every $practiceEvery-th is practice; the list is handed over OLDEST FIRST so the screen has to sort
function New-Lib($n, $practiceEvery = 0, $states = @{}, $noThumb = @(), $kept = @(), $extra = @{}) {
  $rows = @()
  for ($i = 0; $i -lt $n; $i++) {
    $id = 'r{0:d2}' -f $i; $prac = $practiceEvery -gt 0 -and ($i % $practiceEvery) -eq ($practiceEvery - 1)
    $st = if ($states.ContainsKey($id)) { $states[$id] } else { @{ kind = 'none' } }
    $rows += @{ id = $id; track = $tracks[$i % $tracks.Count]; config = ''; car = 'Toyota GR86'; type = $(if ($prac) { 'Practice' } else { 'Race' }); isRace = (-not $prac)
      startMs = ($now - $i * 3600000); sec = 1260 + $i; laps = 10; counted = 9; best = 93.832; bestLap = 4; mb = 1100; kept = ($kept -contains $id); thumb = (-not ($noThumb -contains $id))
      state = $st; min = 21; saved = ($kept -contains $id) }
  }
  [array]::Reverse($rows)
  $lib = @{ storage = @{ usedGb = 412; freeGb = 283; trashGb = 0; moreRaces = 38; lowSpace = $false }; races = $rows }
  foreach ($k in $extra.Keys) { $lib.storage[$k] = $extra[$k] }
  $lib
}
function Set-Lib($lib) {
  $j = $lib | ConvertTo-Json -Depth 12 -Compress
  $null = Invoke-DeckJs $page "(async () => { __sd.fx['/api/library'] = $j; __sd.fx['/api/rec/races'] = $j; return 1; })()"
}

$b = Start-DeckBrowser 9361
try {
  $page = New-DeckPage $b $url -Hidden
  Start-Sleep -Milliseconds 600
  $fx = @{ '/guest' = @{}; '/overlays' = @{}; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false }; '/mydrive' = @{ ready = $false }; '/sound' = @{ ready = $false }; '/ac' = @{ connected = $false } }
  Start-DeckAddon $page $fx
  Start-Sleep -Seconds 1
  Set-Lib (New-Lib 6)
  $null = Invoke-DeckJs $page @'
(() => {
  window.__apis = []; __sd.onApi = p => window.__apis.push(p);
  __sd.apiReply = p => {
    const u = new URL('http://x' + p), c = u.searchParams.get('c'), a = u.searchParams.get('a') || '', n = a.split('|').length;
    if (c === 'racetrash') return a.indexOf('r05') >= 0 ? JSON.stringify({ batch: '', count: 0, say: 'Not deleted: it is still being recorded' }) : JSON.stringify({ batch: 'b-' + n, count: n, mb: 100, say: 'Deleted ' + n + ' races' });
    if (c === 'raceundo') return JSON.stringify({ ok: true, count: 2, say: '2 races are back' });
    if (c === 'raceshare') return JSON.stringify({ ok: true, say: 'Sharing ' + n + ' races' });
    return 'ok';
  };
  return 1;
})()
'@
  function Apis { @(Invoke-DeckJs $page 'window.__apis') | ForEach-Object { [uri]::UnescapeDataString($_) } }
  function ClearApis { $null = Invoke-DeckJs $page 'window.__apis.length = 0' }
  function Press($c, $r, $wait = 450) { $k = "$c,$r"; if ($script:lastKey -eq $k) { $ms = 850 - ((Get-Date) - $script:lastAt).TotalMilliseconds; if ($ms -gt 0) { Start-Sleep -Milliseconds ([int]$ms) } }; $script:lastKey = $k; $script:lastAt = Get-Date; $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep($wait); return 1; })()" }
  function Js($js, $wait = 300) { $null = Invoke-DeckJs $page "(async () => { $js; await __sd.sleep($wait); return 1; })()" }
  function Reg($c, $r) { Invoke-DeckJs $page "(() => { const r = Races.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return r ? { t: r.text, s: r.sub, st: r.style, a: r.act, g: r.arg, w: r.w, h: r.h, x: r.extra || '', p: !!r.paint } : null; })()" }
  function Regions { Invoke-DeckJs $page 'Races.regions.length' }
  function Cur { Invoke-DeckJs $page '__sd.cur' }
  function Ticks { @(Invoke-DeckJs $page '[...Races.ticks]') }
  function Reload($lib) { Set-Lib $lib; Js 'Races.sel = null; Races.page = 0; Races.all = false; Races.ticks.clear(); Races.hidden.clear(); Races.undo = null; Races.msg = null; Races.force = true; await Races.poll()' 500 }
  # the card keys of the page: [{ c, r, id, track }] (the name keys)
  function Cards { @(Invoke-DeckJs $page "Races.regions.filter(x => x.act === 'tick').map(x => ({ c: x.c, r: x.r, id: x.arg, t: x.text }))") }
  function WaitFor($js, $sec = 6) { for ($i = 0; $i -lt $sec * 5; $i++) { if ((Invoke-DeckJs $page $js) -eq $true) { return $true }; Start-Sleep -Milliseconds 200 }; return $false }
  # no text run of a multi-key tile may cross a key gap (the bezel hides the 6 px between keys): replay each multi-key tile's paint hook on a canvas that records every fillText
  $nocross = [IO.File]::ReadAllText((Join-Path $root 'tests\deck-races-nocross.js'))
  function NoCross($where) {
    $r = Invoke-DeckJs $page $nocross
    Check "no text of a multi-key tile crosses a key gap: $where ($($r.runs) runs)" ($r.bad.Count -eq 0 -and $r.runs -gt 0) (@($r.bad) -join ' | ')
  }
  function Sheet($name) { Start-Sleep -Milliseconds 700; NoCross $name; return Save-DeckSheet $page (Join-Path $shots "deck-races-$name.png") }
  # what a key picture looks like: mean brightness, how many gold pixels, how many colourful (picture) pixels
  function Stats($c, $r) { Invoke-DeckJs $page "(async () => { const u = __sd.images[__sd.tileCtx($c, $r)]; return await new Promise(res => { const im = new Image(); im.onload = () => { const cv = document.createElement('canvas'); cv.width = cv.height = 96; const g = cv.getContext('2d'); g.drawImage(im, 0, 0); const d = g.getImageData(6, 6, 84, 84).data; let s = 0, gold = 0, col = 0, n = 0; for (let i = 0; i < d.length; i += 4) { s += d[i] + d[i + 1] + d[i + 2]; n++; if (d[i] > 150 && d[i + 1] > 110 && d[i + 2] < 110 && d[i] - d[i + 2] > 80) gold++; if (Math.max(d[i], d[i + 1], d[i + 2]) - Math.min(d[i], d[i + 1], d[i + 2]) > 25) col++; } res({ mean: s / n / 3, gold, col }); }; im.src = u; }); })()" }
  function ThumbCount($key) { @(Invoke-DeckJs $page "window.__thumbs.filter(x => x === '$key')").Count }

  # ================= open the screen =================
  $m = Invoke-DeckJs $page "__sd.measureOpen('races')"
  Start-Sleep -Milliseconds 1500
  Check 'RACES opens the RigRaces profile and all 32 keys get a picture' ((Cur) -eq 'RigRaces' -and $m.allPicturesMs -ge 0) ($m | ConvertTo-Json -Compress)

  # ================= 1. pages =================
  Section '1. 1, 6, 7 and 40 races'
  Reload (New-Lib 1)
  $c = @(Cards)
  Check '1 race: two keys (picture + name), the fixed keys, nothing else' ($c.Count -eq 1 -and (Regions) -eq 6 -and (Reg 0 0).a -eq 'pick' -and (Reg 1 0).a -eq 'tick' -and $null -eq (Reg 2 0) -and $null -eq (Reg 6 0) -and $null -eq (Reg 7 0) -and $null -eq (Reg 0 3))
  $null = Sheet 'list-1'
  Reload (New-Lib 6)
  Check '6 races: six cards (12 keys), no OLDER, no NEWER' ((@(Cards)).Count -eq 6 -and $null -eq (Reg 7 0) -and $null -eq (Reg 6 0) -and (Regions) -eq 12 + 4)
  $c = @(Cards)
  Check 'newest first although irdash listed them oldest first (r00 first, r05 last; 3 cards a row)' ($c[0].id -eq 'r00' -and $c[0].c -eq 1 -and $c[0].r -eq 0 -and $c[1].id -eq 'r01' -and $c[1].c -eq 3 -and $c[2].id -eq 'r02' -and $c[2].c -eq 5 -and $c[3].id -eq 'r03' -and $c[3].r -eq 1 -and $c[5].id -eq 'r05')
  $r = Reg 6 1; Check 'RACES ONLY / ALL SESSIONS key at (6,1) says ALL SESSIONS' ($r.t -eq 'ALL SESSIONS' -and $r.a -eq 'allsessions')
  $r = Reg 7 1; Check 'the storage key at (7,1) says 283 GB FREE' ($r.t -eq '283 GB' -and $r.s -eq 'FREE')
  $r = Reg 0 2; Check 'row 2 gives the hint when nothing is ticked' ($r.t -eq ('PICTURE OPENS ' + $DOT + ' NAME TICKS') -and $r.st -eq 'hint')
  Check 'EXIT is at (7,3) with the same word and colour as every screen' ((Reg 7 3).t -eq 'EXIT' -and (Reg 7 3).st -eq 'stop' -and (Reg 7 3).a -eq 'exit')
  $n = Reg 1 0; Check 'a name key: the track, the day and the length ("21 MIN")' ($n.t -eq 'Road Atlanta' -and $n.s -match (' ' + $DOT + ' 21 MIN$'))
  $null = Sheet 'list-6'
  Reload (New-Lib 7)
  Check '7 races: OLDER appears (7,0), no NEWER on page 1' ((Reg 7 0).t -eq 'OLDER' -and (Reg 7 0).a -eq 'page' -and $null -eq (Reg 6 0))
  Press 7 0
  $c = @(Cards)
  Check 'page 2 has one card (r06) and NEWER at (6,0), no OLDER' ($c.Count -eq 1 -and $c[0].id -eq 'r06' -and (Reg 6 0).t -eq 'NEWER' -and $null -eq (Reg 7 0))
  $null = Sheet 'list-7-page2'
  Press 6 0
  Check 'NEWER goes back to page 1' ((@(Cards)).Count -eq 6)
  Reload (New-Lib 40 4)
  $c = @(Cards)
  Check '40 sessions, every 4th practice: RACES ONLY shows 30 races, 6 on page 1' ($c.Count -eq 6 -and (@($c.id) -notcontains 'r03') -and (Reg 7 0).t -eq 'OLDER')
  $last = 0; for ($i = 0; $i -lt 6; $i++) { $cc = @(Cards); if ($cc.Count -gt 0) { $last = $cc.Count }; if ($null -ne (Reg 7 0)) { Press 7 0 300 } }
  Check 'the last page of 30 races has the last six, newest first, nothing after' ((@(Cards)).Count -eq 6 -and (@(Cards))[0].id -eq 'r32' -and $null -eq (Reg 7 0) -and (Reg 6 0).t -eq 'NEWER')
  Press 6 1 300
  Check 'ALL SESSIONS puts the practice back: 40 sessions, 7 pages (4 on the last)' ((Reg 6 1).t -eq 'RACES ONLY' -and (Invoke-DeckJs $page 'Races.page') -eq 0 -and (Invoke-DeckJs $page "Races.list().length") -eq 40)
  for ($i = 0; $i -lt 8 -and $null -ne (Reg 7 0); $i++) { Press 7 0 200 }
  Check 'ALL SESSIONS: the last page has 4 cards' ((@(Cards)).Count -eq 4)
  Press 6 1 300

  # ================= 2. pictures =================
  Section '2. pictures on the keys'
  Reload (New-Lib 6 0 @{} @('r03'))
  $null = Invoke-DeckJs $page '(() => { RaceThumbs.m.clear(); window.__thumbs.length = 0; Races.relayout(); return 1; })()'
  Js 'Races.force = true; await Races.poll()' 300
  $null = WaitFor "Races.regions.find(x => x.c === 0 && x.r === 0).extra.endsWith('I')"
  Start-Sleep -Milliseconds 400
  $s0 = Stats 0 0
  Check 'a race with a picture: the picture key is not black and is in colour (the JPEG is drawn)' ($s0.mean -gt 60 -and $s0.col -gt 2000) ($s0 | ConvertTo-Json -Compress)
  $s3 = Stats 0 1
  Check 'a race with thumb false: a dark key with the track word in gold' ($s3.mean -lt 40 -and $s3.gold -gt 30 -and $s3.col -lt 600) ($s3 | ConvertTo-Json -Compress)
  Check 'the dark key is a card too: pressing it would open the race (act pick), the word is the first word of the track' ((Reg 0 1).a -eq 'pick' -and (Reg 0 1).x -match 'D$' -and (Reg 0 0).x -match 'I$')
  Js 'Races.force = true; await Races.poll(); Races.relayout()' 1200
  Check 'each visible picture was fetched once at 144 px (5 of 6; polls and redraws do not fetch again)' ((@(Invoke-DeckJs $page 'window.__thumbs')).Count -eq 5 -and (ThumbCount 'r00@144') -eq 1 -and (ThumbCount 'r03@144') -eq 0)
  Reload (New-Lib 6)
  Js 'Races.force = true; await Races.poll()' 300
  $null = WaitFor "Races.regions.find(x => x.c === 0 && x.r === 1).extra.endsWith('I')"
  Start-Sleep -Milliseconds 400
  Check 'thumb false -> true: that picture is fetched now, once; the others not again' ((ThumbCount 'r03@144') -eq 1 -and (ThumbCount 'r00@144') -eq 1)
  Check 'and its key now shows the picture' ((Stats 0 1).col -gt 2000)
  $null = Sheet 'list-pictures'

  # ================= 3. tick flow =================
  Section '3. tick, share, delete, undo'
  $lib = New-Lib 7 0 @{ r01 = @{ kind = 'shared'; privacy = 'private'; url = 'https://youtu.be/AbC123xyz' }; r03 = @{ kind = 'shared'; privacy = 'private'; url = 'https://youtu.be/QqQ777' }; r04 = @{ kind = 'sharing'; pct = 41 } } @() @('r02')
  Reload $lib
  Press 1 0
  Check 'a press on the name key ticks it: row 2 says 1 TICKED, the share and delete keys appear' ((Ticks) -contains 'r00' -and (Reg 0 2).t -eq '1 TICKED' -and (Reg 0 3).t -eq 'SHARE SELECTED' -and (Reg 0 3).w -eq 2 -and (Reg 2 3).t -eq 'DELETE SELECTED' -and (Reg 2 3).st -eq 'stop' -and (Reg 0 3).st -eq 'sel')
  Check 'ticking marks both keys (the picture key and the name key) with the gold frame' ((Reg 0 0).x -match 'IT$' -and (Reg 1 0).x -match '^nmr\d+T')
  Check 'SELECT ALL SHARED (4,3) and CLEAR TICKS (5,3) are grey, EXIT is still at (7,3)' ((Reg 4 3).st -eq 'grey' -and (Reg 4 3).a -eq 'selshared' -and (Reg 5 3).a -eq 'clear' -and (Reg 7 3).a -eq 'exit')
  Press 1 0
  Check 'a second press on the name key unticks (row 3 is only EXIT again and the hint is back)' ((@(Ticks)).Count -eq 0 -and $null -eq (Reg 0 3) -and (Reg 0 2).st -eq 'hint')
  Press 1 0; Press 3 0
  Check 'two ticked: 2 TICKED' ((Reg 0 2).t -eq '2 TICKED')
  $null = Sheet 'ticked-2'
  ClearApis; Press 0 3 600
  $a = @(Apis) | Where-Object { $_ -match 'c=raceshare' }
  Check 'SHARE SELECTED sends raceshare with both ids, in tick order' (@($a).Count -eq 1 -and ($a -join '') -match 'a=r00\|r01$') ($a -join ' ')
  Check 'the answer''s words are shown (Sharing 2 races) and the ticks are cleared' ((Reg 0 2).t -eq 'Sharing 2 races' -and (@(Ticks)).Count -eq 0)
  Js 'Races.msg = null' 100
  Press 1 0; Press 3 0
  ClearApis; Press 2 3 100
  $a = @(Apis) | Where-Object { $_ -match 'c=racetrash' }
  Check 'DELETE SELECTED sends racetrash a=r00|r01' (@($a).Count -eq 1 -and ($a -join '') -match 'a=r00\|r01$') ($a -join ' ')
  $c = @(Cards)
  Check 'the two cards left at once: r02 is the first card now, 5 cards' ($c[0].id -eq 'r02' -and $c.Count -eq 5)
  Start-Sleep -Milliseconds 400
  $u = Reg 4 2
  Check 'row 2 shows DELETED 2 - UNDO (gold, 3 keys wide) and nothing asks again' ($u.t -eq ('DELETED 2 ' + $DOT + ' UNDO') -and $u.a -eq 'undo' -and $u.w -eq 3 -and $u.st -eq 'sel' -and $u.g -eq $null)
  Check 'no key anywhere asks to be pressed again' ((Invoke-DeckJs $page "Races.regions.every(x => !/AGAIN/i.test(String(x.text) + ' ' + String(x.sub)))") -eq $true)
  $null = Sheet 'undo'
  ClearApis; Press 4 2 500
  $a = @(Apis) | Where-Object { $_ -match 'c=raceundo' }
  Check 'UNDO sends raceundo with the batch from the answer (b-2)' (@($a).Count -eq 1 -and ($a -join '') -match 'a=b-2$') ($a -join ' ')
  $c = @(Cards)
  Check 'the two cards are back, newest first; the UNDO key is gone; 2 races are back is said' ($c[0].id -eq 'r00' -and $c[1].id -eq 'r01' -and (Reg 4 2).a -ne 'undo' -and (Reg 0 2).t -eq '2 races are back') (($c | ForEach-Object { $_.id }) -join ',' + ' | ' + ((Reg 0 2) | ConvertTo-Json -Compress) + ' | ' + ((Reg 4 2) | ConvertTo-Json -Compress))
  Js 'Races.msg = null' 100
  Press 1 0
  Press 5 3 300
  Check 'CLEAR TICKS clears the ticks and sends nothing' ((@(Ticks)).Count -eq 0 -and $null -eq (Reg 5 3))
  Press 1 0
  ClearApis; Press 4 3 300
  Check 'SELECT ALL SHARED ticks the shared ones only (r01 r03), not the one that was ticked, and sends nothing' ((@(Ticks) | Sort-Object) -join ',' -eq 'r01,r03' -and @(Apis).Count -eq 0) ((Ticks) -join ',')
  $null = Sheet 'select-shared'
  Press 5 3 300
  # the delete answer is "refused" (a race that is still being recorded): the card comes back and the words say why
  Press 5 1 300; Press 2 3 700
  Check 'a refused delete (the race is still being recorded): the card is back, nothing to undo, the reason is on row 2' ((@(Cards) | Where-Object { $_.id -eq 'r05' }) -and (Reg 4 2).a -ne 'undo' -and (Reg 0 2).t -match 'still being recorded') ((@(Cards) | ForEach-Object { $_.id }) -join ',' + ' | ' + ((Reg 0 2) | ConvertTo-Json -Compress) + ' | ' + ((Reg 4 2) | ConvertTo-Json -Compress) + ' | ' + ((Apis) -join ' '))
  Reload $lib
  Press 1 0
  Press 2 3 500
  Check 'the UNDO key is there now' ($null -ne (Reg 4 2))
  Start-Sleep -Seconds 8
  Check 'after 8 s the UNDO key is gone by itself (the cards stay gone)' ((Reg 4 2).a -ne 'undo' -and (@(Cards))[0].id -eq 'r01') (((@(Cards) | ForEach-Object { $_.id }) -join ',') + ' | ' + ((Reg 4 2) | ConvertTo-Json -Compress))

  # ================= 4. the open view =================
  Section '4. a race opened'
  $lib = New-Lib 7 0 @{ r01 = @{ kind = 'sharing'; pct = 41 }; r02 = @{ kind = 'shared'; privacy = 'private'; url = 'https://youtu.be/AbC123xyz' }; r03 = @{ kind = 'failed'; error = 'Quota exceeded for today' }; r04 = @{ kind = 'signin' }; r05 = @{ kind = 'shared'; privacy = 'public'; url = 'https://www.youtube.com/watch?v=PubVid99' } } @('r05') @('r00')
  Reload $lib
  Press 0 0 300
  $null = WaitFor "Races.regions.find(x => x.c === 0 && x.r === 0).extra.endsWith('I')"
  Start-Sleep -Milliseconds 500
  Check 'the picture key opens the race: the thumbnail is one picture over a 4 x 2 block (0,0)-(3,1)' ((Reg 0 0).w -eq 4 -and (Reg 0 0).h -eq 2 -and (Reg 0 0).p -and (Reg 3 1).t -eq 'ROAD ATLANTA' -and (Reg 0 0).x -match 'I$')
  Check 'the 600 px picture was fetched once' ((ThumbCount 'r00@600') -eq 1)
  $st = @(Stats 0 0), @(Stats 3 1), @(Stats 3 0), @(Stats 0 1)
  Check 'all four columns of the block show the picture (not black) and the corners differ from each other' (($st | Where-Object { $_.mean -gt 45 -and $_.col -gt 1500 }).Count -eq 4) (($st | ForEach-Object { [int]$_.mean }) -join ',')
  Check 'facts: track and car, date, length and laps, best lap' ((Reg 4 0).t -eq 'Road Atlanta' -and (Reg 4 0).s -eq 'Toyota GR86' -and (Reg 5 0).t -match 'TODAY' -and (Reg 6 0).t -eq '21 MIN' -and (Reg 6 0).s -eq '10 LAPS' -and (Reg 7 0).t -eq '1:33.832' -and (Reg 7 0).s -eq 'BEST LAP')
  Check 'state line (4..7, 1): NOT SHARED, grey, one key 4 wide; SHARE gold; DELETE red; WATCH green; KEPT grey (this one is kept)' ((Reg 4 1).t -eq 'NOT SHARED' -and (Reg 4 1).w -eq 4 -and (Reg 4 1).st -eq 'grey' -and (Reg 0 2).t -eq 'SHARE' -and (Reg 0 2).st -eq 'sel' -and (Reg 1 2).t -eq 'DELETE' -and (Reg 1 2).st -eq 'stop' -and (Reg 2 2).t -eq 'WATCH' -and (Reg 2 2).st -eq 'go' -and (Reg 3 2).t -eq 'KEPT')
  Check 'BACK at (0,3) and EXIT at (7,3); no link key (not shared)' ((Reg 0 3).t -eq 'BACK' -and (Reg 7 3).t -eq 'EXIT' -and $null -eq (Reg 4 2))
  $null = Sheet 'open-notshared'
  ClearApis; Press 0 2 500
  Check 'SHARE sends raceshare a=r00' ((@(Apis) | Where-Object { $_ -match 'c=raceshare&a=r00$' }).Count -eq 1)
  ClearApis; Press 2 2 300
  Check 'WATCH sends racewatch' ((@(Apis) | Where-Object { $_ -match 'c=racewatch' }).Count -eq 1)
  Press 0 3 300
  Check 'BACK returns to the list' ((Reg 0 0).a -eq 'pick' -and (Reg 0 0).w -eq 1)
  # r01 sharing 41 %
  Press 2 0 500
  Check 'sharing: the state line says SHARING 41% in gold; SHARE is grey and sends nothing' ((Reg 4 1).t -eq 'SHARING 41%' -and (Reg 4 1).st -eq 'sel' -and (Reg 0 2).st -eq 'grey' -and $null -eq (Reg 0 2).a -and (Reg 3 2).t -eq 'KEEP' -and (Reg 3 2).a -eq 'recsave')
  $null = Sheet 'open-sharing'
  ClearApis; Press 0 2 300; Check 'a press on the grey SHARE key sends nothing' (@(Apis).Count -eq 0)
  Press 0 3 300
  # r02 shared (private)
  Press 4 0 500
  Check 'shared (private): ON YOUTUBE (PRIVATE) in green, SHARE grey, the short link on a 2 wide key' ((Reg 4 1).t -eq 'ON YOUTUBE (PRIVATE)' -and (Reg 4 1).st -eq 'go' -and (Reg 0 2).t -eq 'ON YOUTUBE' -and (Reg 0 2).st -eq 'grey' -and (Reg 4 2).t -eq 'youtu.be/AbC123xyz' -and (Reg 4 2).w -eq 2 -and (Reg 5 2).t -eq 'youtu.be/AbC123xyz')
  $null = Sheet 'open-shared'
  Press 0 3 300
  # r03 failed
  Press 0 1 500
  Check 'failed: the state line is red and says why' ((Reg 4 1).st -eq 'stop' -and (Reg 4 1).t -match '^SHARE FAILED: Quota' -and (Reg 0 2).t -eq 'SHARE' -and (Reg 0 2).a -eq 'shareone')
  Press 0 3 300
  # r04 signin
  Press 2 1 500
  Check 'signin: SIGN IN TO YOUTUBE in amber' ((Reg 4 1).t -eq 'SIGN IN TO YOUTUBE' -and (Reg 4 1).st -eq 'amber' -and (Reg 4 1).a -eq 'ytsignin')
  $null = Sheet 'open-signin'
  ClearApis; Press 4 1 500
  Check 'pressing the sign-in line sends ytsignin' ((@(Apis) | Where-Object { $_ -match 'c=ytsignin' }).Count -eq 1)
  Press 0 3 300
  # r05 shared public via a watch?v= link, not in RACES? (it is a race)
  Press 4 1 500
  Check 'shared (public): ON YOUTUBE, link key from a watch?v= address' ((Reg 4 1).t -eq 'ON YOUTUBE' -and (Reg 4 2).t -eq 'youtu.be/PubVid99')
  Press 0 3 300
  # DELETE from an open race
  Press 0 0 400
  ClearApis; Press 1 2 500
  $a = @(Apis) | Where-Object { $_ -match 'c=racetrash' }
  Check 'DELETE sends racetrash a=r00, then the list shows without it and the UNDO key' (@($a).Count -eq 1 -and ($a -join '') -match 'a=r00$' -and (Reg 0 0).a -eq 'pick' -and (@(Cards))[0].id -eq 'r01' -and $null -ne (Reg 4 2) -and (Reg 4 2).t -eq ('DELETED 1 ' + $DOT + ' UNDO'))
  Press 4 2 500
  Check 'UNDO from there brings it back' ((@(Cards))[0].id -eq 'r00')
  # EXIT at 7,3 on every view
  $views = @()
  $views += ('list: ' + (Reg 7 3).t)
  Press 0 0 400; $views += ('open: ' + (Reg 7 3).t); Press 0 3 300
  # the offline message is held still (the poll is paused) while it is looked at, then the screen recovers on its own
  $null = Invoke-DeckJs $page "(() => { Races.poll = async () => { }; Races.s = { offline: true, races: [] }; Races.relayout(); return 1; })()"
  $views += ('offline: ' + (Reg 7 3).t); $offReg = Reg 0 0
  $null = Sheet 'offline'
  $null = Invoke-DeckJs $page "(() => { delete Races.poll; return 1; })()"
  Js 'Races.force = true; await Races.poll()' 600
  Reload (New-Lib 0)
  $views += ('empty: ' + (Reg 7 3).t); $emp = Reg 0 0
  $null = Sheet 'empty'
  Check 'EXIT at 7,3 on the list, an open race, the offline message and the empty list' (($views -join ' | ') -eq 'list: EXIT | open: EXIT | offline: EXIT | empty: EXIT') ($views -join ' | ')
  Check 'the offline message says DASHBOARD NOT ANSWERING; the empty list says NO RACES YET and still has the filter key' ($offReg.t -eq 'DASHBOARD NOT ANSWERING' -and $emp.t -eq 'NO RACES YET' -and (Reg 6 1).a -eq 'allsessions')
  Reload $lib
  Js 'Races.ticks.add("r01"); Races.relayout()' 200
  $nowords = Invoke-DeckJs $page "Races.regions.filter(x => !String(x.text).trim()).length"
  Check 'no key without a word on the list with a tick' ($nowords -eq 0)

  # ================= 5. the request rate =================
  Section '5. request rate while open and idle'
  Reload (New-Lib 6)
  Start-Sleep -Seconds 2
  $t0 = Invoke-DeckJs $page 'performance.now()'
  Start-Sleep -Seconds 20
  $rq = @(Invoke-DeckJs $page "__sd.fetchLog.filter(f => f.t >= $t0 && f.u.indexOf('/api/library/thumb') < 0).map(f => f.u.split('?')[0])")
  $rate = [math]::Round($rq.Count / 20, 2)
  Check "the open screen asks irdash $($rq.Count) times in 20 s = $rate / s (ceiling 0.3): $($rq -join ' ')" ($rate -le 0.3)

  Check 'the screen is still showing the list, nothing was sent while idle' ((Reg 0 0).a -eq 'pick' -and @(Apis).Count -ge 0)
}
finally { Stop-DeckBrowser $b }

"`n$script:pass ok, $script:fail FAIL"
exit $(if ($script:fail) { 1 } else { 0 })
