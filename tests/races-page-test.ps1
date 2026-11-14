# races-page-test.ps1 - offline: the RACES page on the top screen (W1-4; since W3-1 a page module of the shell: dash\www\app\pages\races.js + races.css).
# A copy of the shell (app\index.html?page=races) runs in headless Chrome with a pretend irdash: fetch answers /api/library from a fixture and the /api/do
# commands the way library.cs does, every request is recorded, and window.data is a stand-in whose rig state the test flips.
#   1. every state line (none, queued, sharing, shared private / public, failed, signin, offline), Kept, no clean lap
#   2. the tabs   3. select mode, the bar, SHIFT range, SELECT ALL SHARED, CANCEL, SHARE, DELETE + UNDO (one click each)
#   4. the open card: five keys, the timeline, COPY LINK only when shared, Esc   5. the storage line, EMPTY NOW, FREE UP SPACE
#   6. offline, driving, the sign-in banner, MAKE PUBLIC, the five titles   7. nothing on a timer (and no setInterval in the page)
# Pictures, one per state: tests\shots\rework\races-<state>.png (the thumbnails in them are a plain grey test picture).
# Nothing reaches the real irdash.
#   powershell -ExecutionPolicy Bypass -File tests\races-page-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$www = Join-Path $root 'dash\www\app'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'RACES page test (W1-4)'
$pass = 0; $fail = 0

$tmp = Join-Path $env:TEMP ('races-page-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force "$tmp\thumbs" | Out-Null

# a plain grey picture stands in for the race frames (a test picture, never shipped)
Add-Type -AssemblyName System.Drawing
$bmp = New-Object Drawing.Bitmap 600, 338
$g = [Drawing.Graphics]::FromImage($bmp)
$br = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle 0, 0, 600, 338), [Drawing.Color]::FromArgb(70, 72, 76), [Drawing.Color]::FromArgb(24, 25, 28), 60)
$g.FillRectangle($br, 0, 0, 600, 338); $g.Dispose()
$jpg = "$tmp\thumbs\grey.jpg"; $bmp.Save($jpg, [Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()

$now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds(); $h = 3600000; $d = 86400000
$mk = '[{"sec":0,"kind":"start","label":"Start"},{"sec":412.5,"kind":"incident","label":"Incident +2x"},{"sec":655,"kind":"pit","label":"Pit (lap 6)"},{"sec":780.1,"kind":"best","label":"Best lap 1:33.832 (lap 9)"},{"sec":1248,"kind":"finish","label":"Finish"}]'
function Race($id, $ms, $state, [switch]$kept, [switch]$thumb, $best = 93.832, $type = 'Race', $track = 'Road Atlanta', $car = 'Toyota GR86', $markers = '[]') {
  $isRace = if ($type -match 'race' -and $type -notmatch 'qual|prac') { 'true' } else { 'false' }
  '{"id":"' + $id + '","track":"' + $track + '","config":"Full Course","car":"' + $car + '","type":"' + $type + '","isRace":' + $isRace + ',"startMs":' + $ms +
  ',"sec":1268,"laps":10,"counted":7,"best":' + $best + ',"bestLap":9,"mb":1101,"kept":' + ($(if ($kept) { 'true' } else { 'false' })) + ',"thumb":' + ($(if ($thumb) { 'true' } else { 'false' })) +
  ',"state":' + $state + ',"markers":' + $markers + '}'
}
foreach ($id in 'r1', 'r3', 'r4', 'r5', 'r6', 'p1') { Copy-Item $jpg "$tmp\thumbs\$id.jpg" }
$races = @(
  (Race 'r1' ($now - $h) '{"kind":"none"}' -kept -thumb -markers $mk),
  (Race 'r2' ($now - $d - $h) '{"kind":"queued","pct":0}' -track 'Watkins Glen International'),
  (Race 'r3' ($now - 2 * $d) '{"kind":"sharing","pct":41}' -thumb -track 'Road America' -car 'Porsche 718 Cayman GT4 Clubsport MR'),
  (Race 'r4' ($now - 3 * $d) '{"kind":"shared","pct":100,"privacy":"private","url":"https://youtu.be/abc123"}' -thumb -markers $mk),
  (Race 'r5' ($now - 4 * $d) '{"kind":"shared","pct":100,"privacy":"public","url":"https://youtu.be/def456"}' -thumb -track 'Lime Rock Park'),
  (Race 'r6' ($now - 5 * $d) ('{"kind":"queued","pct":0,"error":"YouTube''s daily limit is reached. Trying again after 9 in the morning"}') -thumb),
  (Race 'r7' ($now - 6 * $d) '{"kind":"signin","error":"Sign in to YouTube again"}' -track 'Okayama'),
  (Race 'r8' ($now - 7 * $d) '{"kind":"offline","error":"No internet, waiting"}' -track 'Summit Point'),
  (Race 'r9' ($now - 8 * $d) '{"kind":"none"}' -best 0 -track 'Oulton Park'),
  (Race 'r10' ($now - 9 * $d) '{"kind":"failed","error":"YouTube turned the video down. Press SHARE to try again."}' -track 'Brands Hatch \"GP\" & Indy''s <b>'),
  (Race 'p1' ($now - 2 * $h) '{"kind":"none"}' -type 'Practice' -thumb),
  (Race 'p2' ($now - 3 * $h) '{"kind":"none"}' -type 'Lone Qualify'))
$titles = '["Toyota GR86 at Road Atlanta · 13 Nov 2026","Toyota GR86 at Road Atlanta · 13 Nov 2026","Road Atlanta in the Toyota GR86","Road Atlanta Toyota GR86 full race · 13 Nov 2026","Full race: Road Atlanta (Toyota GR86)"]'
$fixture = '{"storage":{"usedGb":412,"freeGb":280,"trashGb":14,"moreRaces":38,"lowSpace":false},"youtube":{"signedIn":false,"privacy":"private","template":1,"queue":2},"titles":' + $titles +
  ',"races":[' + ($races -join ',') + '],"trash":[]}'

# the pretend irdash and the stand-in for data.js (data.js steps aside when window.data is already a Paddock connection)
$stub = @"
<script>
window.__fx = $fixture;
window.__req = []; window.__rig = { online: true, driving: false }; window.__ls = {}; window.__trash = {};
window.data = { __paddock: true, state: {}, seq: -1, telemetry() {}, reloadOnVersion() {}, get rig() { return window.__rig; }, get online() { return window.__rig.online; },
  on(n, f) { (window.__ls[n] = window.__ls[n] || []).push(f); return () => {}; },
  onList(n, f) { (window.__ls['list:' + n] = window.__ls['list:' + n] || []).push(f); },
  fetch(u, o) { return window.fetch(u, o); }, json(u) { return window.fetch(u).then(r => r.json()); } };
window.__emit = n => (window.__ls[n] || []).forEach(f => f(window.data.state || {}, {}));
window.fetch = (url) => { url = String(url); window.__req.push(url);
  const j = (o, code) => Promise.resolve(new Response(typeof o === 'string' ? o : JSON.stringify(o), { status: code || 200 }));
  if (/^\/api\/library$/.test(url)) return j(JSON.parse(JSON.stringify(window.__fx)));
  const m = /^\/api\/do\?c=([a-z]+)(?:&a=(.*))?$/.exec(url); if (!m) return j('{}', 404);
  const c = m[1], a = decodeURIComponent(m[2] || ''), ids = a.split('|').filter(Boolean);
  if (c === 'racetrash') { const busy = ids.filter(id => (window.__inUse || []).includes(id)), go = ids.filter(id => !busy.includes(id));
    const gone = window.__fx.races.filter(r => go.includes(r.id)); window.__fx.races = window.__fx.races.filter(r => !go.includes(r.id)); window.__trash.b1 = gone;
    if (!gone.length) return j({ batch: '', count: 0, mb: 0, say: 'Not deleted: it is in use. Try again in a minute' }, 409);
    return j({ batch: 'b1', count: gone.length, mb: 2202, say: 'Deleted ' + gone.length + ' race' + (gone.length === 1 ? '' : 's') + (busy.length ? '. ' + busy.length + ' not deleted: it is in use. Try again in a minute' : '') }); }
  if (c === 'raceundo') { const back = window.__trash[a] || []; window.__fx.races = window.__fx.races.concat(back).sort((x, y) => y.startMs - x.startMs); delete window.__trash[a];
    return back.length ? j({ ok: true, count: back.length, say: back.length + ' races are back' }) : j({ ok: false, count: 0, say: 'Nothing to undo' }, 409); }
  if (c === 'raceshare') { const ans = window.__fx.youtube.signedIn ? j({ ok: true, count: ids.length, already: 0, signin: false, say: 'Sharing ' + ids.length + ' races' })
      : j({ ok: false, count: 0, already: 0, signin: true, say: 'Sign in to YouTube first' }, 409);
    return new Promise(res => setTimeout(() => res(ans), 300)); }      // a slow answer: a second click lands before it
  if (c === 'ytprivacy') return j({ ok: true, privacy: a, say: a === 'public' ? 'New uploads are public' : 'New uploads are private' });
  if (c === 'yttemplate') return j({ ok: true, template: +a, say: 'Titles will look like this from now on' });
  if (c === 'ytsignin') return j({ ok: true, say: 'Google sign-in opened in the browser' });
  if (c === 'raceempty') return j({ ok: true, count: 3, say: 'Emptying the trash: 14 GB' });
  if (c === 'racefree') return j({ ok: true, count: 6, gb: 7.2, say: 'Freed 7 GB: 6 shared races' });
  return j({ ok: true, say: 'ok' }); };
</script>
"@

# ---------------- the behaviour test ----------------
$run = @'
<pre id="out"></pre>
<script>
(async () => {
  const out = [], ok = (what, cond, why) => out.push((cond ? 'ok ' : 'FAIL ') + what + (cond || why == null ? '' : ' -> ' + why));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const $ = id => document.getElementById(id);
  const card = id => document.querySelector('.card[data-id="' + id + '"]');
  const cards = () => [...document.querySelectorAll('.card')].map(c => c.dataset.id);
  const facts = id => card(id).querySelector('.facts').textContent.replace(/\u00a0/g, ' ');
  const state = id => { const s = card(id) && card(id).querySelector('.state'); return s ? s.textContent : '(none)'; };
  const vis = el => !!el && !el.hidden && el.getClientRects().length > 0;
  const req = () => window.__req.slice();
  const cmds = () => window.__req.filter(u => u.indexOf('/api/do') === 0).map(u => decodeURIComponent(u));
  const click = (el, shift) => el.dispatchEvent(new MouseEvent('click', { bubbles: true, shiftKey: !!shift }));
  const tick = (id, shift) => click(card(id).querySelector('.tick'), shift);
  const toast = () => vis($('rcToast')) ? $('rcToast').textContent : '';
  const undoNote = () => vis($('undo')) ? $('undo').querySelector('span').textContent : '';
  const tabOn = () => [...document.querySelectorAll('.tab.on')].map(b => b.dataset.tab).join(',');
  await sleep(600);

  // 1. state lines
  const want = { r1: 'Not shared', r2: 'Waiting to share', r3: 'Sharing 41%', r4: 'On YouTube (private)', r5: 'On YouTube',
    r6: 'YouTube limit: trying again after 9', r7: 'Sign in to YouTube', r8: 'No internet, waiting', r9: 'Not shared', r10: 'YouTube turned the video down' };
  for (const id in want) ok('1. ' + id + ' says "' + want[id] + '"', state(id) === want[id], state(id));
  ok('1. the daily limit is gold (waiting), a failure red', card('r6').querySelector('.state').classList.contains('wait') && card('r10').querySelector('.state').classList.contains('bad'));
  ok('1. the state line is the 36 px token, date and facts 24', getComputedStyle(card('r1').querySelector('.state')).fontSize === '36px' && getComputedStyle(card('r1').querySelector('.when')).fontSize === '24px' && getComputedStyle(card('r1').querySelector('.facts')).fontSize === '24px', getComputedStyle(card('r1').querySelector('.state')).fontSize);
  ok('1. the state line stays on one line', cards().every(id => card(id).querySelector('.state').getBoundingClientRect().height < 50));
  ok('1. the sign-in line is one key', card('r7').querySelector('.state').tagName === 'BUTTON');
  window.__req.length = 0; click(card('r7').querySelector('.state')); await sleep(150);
  ok('1. pressing it sends ytsignin', cmds().join(' ') === '/api/do?c=ytsignin', cmds().join(' '));
  ok('1. a Kept race has the Kept tag, others not', !!card('r1').querySelector('.tag') && !card('r2').querySelector('.tag'));
  ok('1. best 0 says "no clean lap"', /no clean lap/.test(facts('r9')) && !/no clean lap/.test(facts('r1')));
  ok('1. the facts line: car, minutes, laps, best, size', facts('r1') === 'Toyota GR86 · 21 min · 10 laps · best 1:33.832 · 1.1 GB', facts('r1'));
  ok('1. the date: Today (gold) / Yesterday', /^Today, \d\d:\d\d$/.test(card('r1').querySelector('.when').textContent) && /^Yesterday, /.test(card('r2').querySelector('.when').textContent));
  ok('1. every card has one OPEN and one tick box', cards().every(id => card(id).querySelectorAll('[data-act="open"]').length === 1 && card(id).querySelectorAll('.tick').length === 1));
  ok('1. a picture when thumb is true, the track name when not', !!card('r1').querySelector('img.pic') && !card('r2').querySelector('img') && card('r2').classList.contains('nothumb'));
  ok('1. the picture is the thumbnail of that race', /r1\.jpg$/.test(card('r1').querySelector('img.pic').getAttribute('src')));
  ok('1. a track name with quotes, & and <b> shows as written (no markup)', card('r10').querySelector('.track').textContent === 'Brands Hatch "GP" & Indy\'s <b>' && !card('r10').querySelector('.track b'), card('r10').querySelector('.track').innerHTML);

  // 2. tabs
  ok('2. RACES shows the races only, newest first; its tab is the gold one', cards().join(',') === 'r1,r2,r3,r4,r5,r6,r7,r8,r9,r10' && tabOn() === 'races', cards().join(',') + ' / ' + tabOn());
  click(document.querySelector('.tab[data-tab="pq"]')); await sleep(50);
  ok('2. PRACTICE & QUALIFYING shows the other two, and only its tab is gold', cards().join(',') === 'p1,p2' && tabOn() === 'pq', cards().join(',') + ' / ' + tabOn());
  ok('2. a practice says what it is', /Practice/.test(card('p1').querySelector('.when').textContent));
  click(document.querySelector('.tab[data-tab="all"]')); await sleep(50);
  ok('2. ALL shows all 12, newest first; only ALL is gold', cards().length === 12 && cards()[0] === 'r1' && cards()[1] === 'p1' && tabOn() === 'all', cards().join(','));
  click(document.querySelector('.tab[data-tab="races"]')); await sleep(50);

  // 3. select mode
  ok('3. no bar before a tick', !vis($('bar')));
  window.__req.length = 0;
  tick('r1'); await sleep(50);
  ok('3. one tick: the bar shows, 120 px', vis($('bar')) && $('bar').offsetHeight === 120, $('bar').offsetHeight);
  ok('3. the bar says 1 race, Share to YouTube (1), Delete (1)', $('barCount').textContent === '1 race ticked' && $('barShare').textContent === 'Share to YouTube (1)' && $('barDelete').textContent === 'Delete (1)', $('bar').textContent);
  tick('r4', true); await sleep(50);
  ok('3. SHIFT-click ticks the range r1..r4', ['r1', 'r2', 'r3', 'r4'].every(id => card(id).classList.contains('on')) && !card('r5').classList.contains('on'));
  ok('3. the counts follow: "4 races ticked · 1 already on YouTube", Delete (4), Share (1)', $('barCount').textContent === '4 races ticked · 1 already on YouTube' && $('barDelete').textContent === 'Delete (4)' && $('barShare').textContent === 'Share to YouTube (1)', $('bar').textContent);
  click(document.querySelector('.tab[data-tab="pq"]')); await sleep(50);
  ok('3. a tab switch clears the ticks: no bar, nothing ticked anywhere', !vis($('bar')) && !document.querySelector('.card.on'));
  click(document.querySelector('.tab[data-tab="races"]')); await sleep(50);
  ok('3. back on RACES nothing is ticked either', !document.querySelector('.card.on') && !vis($('bar')));
  tick('r1'); click($('barCancel')); await sleep(50);
  ok('3. CANCEL clears the ticks and the bar', !vis($('bar')) && !document.querySelector('.card.on'));
  ok('3. SELECT ALL SHARED is there (two races are shared)', vis($('selShared')));
  click($('selShared')); await sleep(50);
  ok('3. SELECT ALL SHARED ticks exactly r4 and r5', [...document.querySelectorAll('.card.on')].map(c => c.dataset.id).join(',') === 'r4,r5');
  ok('3. nothing was sent while ticking', cmds().length === 0, cmds().join(' '));
  click($('barCancel')); await sleep(50);

  // share, not signed in: nothing is cut, the banner asks for the sign-in
  tick('r1'); tick('r9'); await sleep(50);
  window.__req.length = 0;
  click($('barShare')); click($('barShare')); await sleep(600);
  ok('3. two quick clicks on SHARE send one raceshare a=r1|r9', cmds().join(' ') === '/api/do?c=raceshare&a=r1|r9', cmds().join(' '));
  ok('3. not signed in: "Sign in to YouTube first", the cards stay Not shared, the banner shows', /Sign in to YouTube first/.test(toast()) && state('r1') === 'Not shared' && vis($('rcBanner')) && /Sign in once/.test($('rcBanner').textContent), toast() + ' | ' + state('r1') + ' | ' + vis($('rcBanner')) + ' | ' + $('rcBanner').textContent);
  click($('barCancel')); await sleep(50);
  window.__fx.youtube.signedIn = true; await Races.load();
  tick('r1'); tick('r9'); await sleep(50);
  window.__req.length = 0;
  click($('barShare')); await sleep(500);
  ok('3. signed in: SHARE sends raceshare a=r1|r9 once; both say Waiting to share; the ticks are gone', cmds().join(' ') === '/api/do?c=raceshare&a=r1|r9' && state('r1') === 'Waiting to share' && state('r9') === 'Waiting to share' && !vis($('bar')), cmds().join(' '));
  await Races.load();

  tick('r6'); tick('r7'); await sleep(50);
  ok('3. a race waiting for the daily limit is not counted for SHARE', $('barShare').textContent === 'Share to YouTube (0)' && $('barShare').disabled);
  window.__req.length = 0;
  click($('barDelete')); await sleep(10);
  ok('3. DELETE: the cards leave at once', !card('r6') && !card('r7'));
  await sleep(200);
  ok('3. DELETE sends racetrash a=r6|r7, once, nothing else but the list', cmds().join(' ') === '/api/do?c=racetrash&a=r6|r7', cmds().join(' '));
  ok('3. the note says "Deleted 2 races" with UNDO (no dangling dot)', undoNote() === 'Deleted 2 races' && !!$('undo').querySelector('[data-act="undo"]'), undoNote());
  ok('3. no "are you sure", no second press: the bar is gone', !vis($('bar')));
  window.__req.length = 0;
  click($('undo').querySelector('[data-act="undo"]')); await sleep(300);
  ok('3. UNDO sends raceundo a=b1', cmds()[0] === '/api/do?c=raceundo&a=b1', cmds().join(' '));
  ok('3. the cards come back', !!card('r6') && !!card('r7'), cards().join(','));

  // a partial refusal: one of the two is in use; it comes back on the next list, the other stays gone
  window.__inUse = ['r7'];
  tick('r6'); tick('r7'); click($('barDelete')); await sleep(400);
  ok('3. one in use: it is back on the page, the other is gone', !!card('r7') && !card('r6'), cards().join(','));
  ok('3. the note says what happened', undoNote() === 'Deleted 1 race. 1 not deleted: it is in use. Try again in a minute', undoNote());
  window.__inUse = [];
  click($('undo').querySelector('[data-act="undo"]')); await sleep(300);
  ok('3. UNDO brings r6 back', !!card('r6'));

  // an UNDO made on the deck: the next list brings the card back without a page UNDO
  tick('r8'); click($('barDelete')); await sleep(300);
  ok('3. (r8 deleted)', !card('r8'));
  window.__fx.races = window.__fx.races.concat(window.__trash.b1).sort((x, y) => y.startMs - x.startMs);
  (window.__ls['list:races'] || []).forEach(f => f()); await sleep(200);
  ok('3. an UNDO from the deck shows on the next list', !!card('r8'));
  Races.hideUndo();

  tick('r9'); click($('barDelete')); await sleep(200);
  const t0 = undoNote();
  click($('privBtn')); await sleep(200);
  ok('3. a later message does not replace the UNDO note', undoNote() === t0 && /New uploads/.test(toast()), undoNote() + ' / ' + toast());
  click($('privBtn')); await sleep(200);
  await sleep(8300);
  ok('3. the UNDO note stays 8 s, then goes', /Deleted 1 race/.test(t0) && undoNote() === '', t0 + ' / ' + undoNote());

  // 4. the open card
  window.__fx.youtube.signedIn = false; await Races.load();
  window.__req.length = 0;
  click(card('r1').querySelector('[data-act="open"]')); await sleep(80);
  const o = $('open');
  ok('4. OPEN shows the race over the grid', vis(o) && /Road Atlanta/.test(o.querySelector('.o-track').textContent));
  const keys = [...o.querySelectorAll('.o-keys .btn')].map(b => b.textContent);
  ok('4. five keys in one row: Watch, Share to YouTube, Talk over it, Review, Delete', keys.join('|') === 'Watch|Share to YouTube|Talk over it|Review|Delete', keys.join('|'));
  const kb = [...o.querySelectorAll('.o-keys .btn')], tops = kb.map(b => b.getBoundingClientRect().top);
  ok('4. the keys are 72 px high and on one row', kb.every(b => b.offsetHeight === 72) && tops.every(t => Math.abs(t - tops[0]) < 1), kb.map(b => b.offsetHeight).join(','));
  ok('4. TALK OVER IT is a live key (W1-6: commentary-test covers what it does)', !kb[2].disabled && kb[2].dataset.act === 'talk' && !/Comes with the commentary update/.test(o.textContent));
  const chips = [...o.querySelectorAll('.chip')].map(c => c.textContent);
  ok('4. the timeline has every marker with its label and time', chips.join('|') === '0:00 Start|6:53 Incident +2x|10:55 Pit (lap 6)|13:00 Best lap 1:33.832 (lap 9)|20:48 Finish', chips.join('|'));
  ok('4. one dot per marker on the rail', o.querySelectorAll('.rail .dot').length === 5);
  ok('4. not shared: no COPY LINK', !o.querySelector('[data-act="copy"]'));
  ok('4. not signed in: the sign-in banner is over the open card', vis($('rcBanner')) && $('rcBanner').classList.contains('over') && /Sign in to YouTube/.test($('rcBanner').textContent));
  click(o.querySelector('[data-act="watch"]')); await sleep(150);
  ok('4. WATCH sends racewatch for this race', cmds().join(' ') === '/api/do?c=racewatch&a=r1', cmds().join(' '));
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); await sleep(50);
  ok('4. Esc returns to the grid', !vis(o) && cards().length > 0);
  click(card('r4').querySelector('[data-act="open"]')); await sleep(80);
  ok('4. shared: the link and COPY LINK', !!o.querySelector('[data-act="copy"]') && $('linkField').value === 'https://youtu.be/abc123');
  ok('4. shared: "On YouTube" is a plain label where SHARE was (never twice)', !o.querySelector('[data-act="share"]') && o.querySelector('.o-keys .keylabel').textContent === 'On YouTube');
  click(o.querySelector('[data-act="close"]')); await sleep(50);
  click(card('r6').querySelector('[data-act="open"]')); await sleep(80);
  ok('4. the daily limit: the whole sentence on the open card, "Waiting to share" instead of SHARE', o.querySelector('.o-facts .state').textContent === "YouTube's daily limit is reached. Trying again after 9 in the morning" && o.querySelector('.o-keys .keylabel').textContent === 'Waiting to share' && !o.querySelector('[data-act="share"]'));
  click(o.querySelector('[data-act="close"]')); await sleep(50);
  click(card('r4').querySelector('[data-act="open"]')); await sleep(80);
  window.__req.length = 0;
  click(o.querySelector('[data-act="delete"]')); await sleep(300);
  ok('4. DELETE on the open card trashes that race and closes the card', cmds().join(' ') === '/api/do?c=racetrash&a=r4' && !vis(o) && !card('r4'), cmds().join(' '));
  click($('undo').querySelector('[data-act="undo"]')); await sleep(300);
  click(card('r1').querySelector('[data-act="open"]')); await sleep(80);
  click(o.querySelector('[data-act="close"]')); await sleep(50);
  ok('4. BACK TO ALL RACES closes it too', !vis(o));

  // 5. the storage line
  ok('5. the storage line', $('storeLine').textContent === '412 GB used · 280 GB free · about 38 more races', $('storeLine').textContent);
  ok('5. the bar is used / (used + free) = 60 %', $('storeFill').style.width === '60%' && vis($('storeBar')), $('storeFill').style.width);
  ok('5. 14 GB in trash · EMPTY NOW (trash >= 1 GB)', vis($('trashBit')) && /14 GB in trash/.test($('trashBit').textContent));
  window.__req.length = 0; click($('emptyNow')); await sleep(150);
  ok('5. EMPTY NOW sends raceempty', cmds().join(' ') === '/api/do?c=raceempty', cmds().join(' '));
  ok('5. no free-up key while there is space', !vis($('freeRow')));
  window.__fx.storage = { usedGb: 0, freeGb: 100, trashGb: 0.4, moreRaces: 1, lowSpace: false }; await Races.load();
  ok('5. under 1 GB in the trash: no EMPTY NOW; "about 1 more race"; nothing used: no bar', !vis($('trashBit')) && /about 1 more race$/.test($('storeLine').textContent) && !vis($('storeBar')), $('storeLine').textContent);
  window.__fx.storage = { usedGb: 800, freeGb: 90, trashGb: 0, moreRaces: 70, lowSpace: true, freeUp: { count: 6, gb: 7.2 } }; await Races.load();
  ok('5. low space: one gold key "Free up space: delete the 6 oldest shared races (7 GB)"', vis($('freeRow')) && $('freeRow').querySelector('.btn.gold').textContent === 'Free up space: delete the 6 oldest shared races (7 GB)', $('freeRow').textContent);
  window.__req.length = 0; click($('freeRow').querySelector('.btn')); await sleep(150);
  ok('5. it sends racefree', cmds().join(' ') === '/api/do?c=racefree', cmds().join(' '));
  window.__fx.storage.freeUp = { count: 0, gb: 0 }; await Races.load();
  ok('5. nothing shared to free: no key, says what to do', !$('freeRow').querySelector('.btn') && /Share some races, then FREE UP SPACE can delete the shared ones/.test($('freeRow').textContent));
  window.__fx.storage = { usedGb: 412, freeGb: 280, trashGb: 14, moreRaces: 38, lowSpace: false }; await Races.load();

  // 6. offline, driving, sign-in, settings
  const n6 = cards().length;
  window.__rig.online = false; window.__emit('online'); await sleep(50);
  ok('6. offline: one banner, the shell banner: "Paddock is not running. Press HOME on the deck."', vis($('banner')) && $('banner').textContent === 'Paddock is not running. Press HOME on the deck.' && !vis($('rcBanner')), $('banner').textContent);
  ok('6. offline: nothing else changes (the cards stay)', cards().length === n6 && n6 === 9 && vis($('grid')), n6);
  window.__rig.online = true; window.__emit('online'); await sleep(50);
  ok('6. back online: the banner goes', !vis($('banner')) && !vis($('rcBanner')));
  click($('privBtn')); await sleep(150);
  window.__rig.driving = true; window.__emit('state'); await sleep(50);
  const shown = [...document.querySelector('.rc').querySelectorAll('button')].filter(vis);
  ok('6. driving: "Back after your drive", not one key, no message', vis($('driving')) && $('driving').textContent === 'Back after your drive' && shown.length === 0 && !vis($('rcToast')) && !vis($('undo')), shown.map(b => b.textContent).join('|'));
  Races.toast('test'); await sleep(20);
  ok('6. driving: a message that arrives now is not shown', !vis($('rcToast')));
  window.__rig.driving = false; window.__emit('state'); await sleep(50);
  ok('6. after the drive the grid is back', vis($('grid')) && cards().length === 9);
  click($('privBtn')); await sleep(150);
  ok('6. not signed in, nothing ticked: no sign-in banner', !vis($('rcBanner')));
  tick('r1'); await sleep(50);
  ok('6. not signed in and a race ticked: the banner with SIGN IN TO YOUTUBE', vis($('rcBanner')) && $('rcBanner').querySelector('.btn').textContent === 'Sign in to YouTube');
  window.__req.length = 0; click($('rcBanner').querySelector('.btn')); await sleep(150);
  ok('6. the banner key sends ytsignin', cmds().join(' ') === '/api/do?c=ytsignin', cmds().join(' '));
  click($('barCancel')); await sleep(50);
  window.__fx.youtube.signedIn = true; await Races.load(); tick('r1'); await sleep(50);
  ok('6. signed in: no banner even with a tick', !vis($('rcBanner')));
  click($('barCancel')); await sleep(50);
  ok('6. settings say "Uploads are private · MAKE PUBLIC"', $('privWords').textContent === 'Uploads are private' && $('privBtn').textContent === 'Make public');
  window.__req.length = 0; click($('privBtn')); await sleep(150);
  ok('6. MAKE PUBLIC sends ytprivacy a=public, the words follow', cmds().join(' ') === '/api/do?c=ytprivacy&a=public' && $('privWords').textContent === 'Uploads are public' && $('privBtn').textContent === 'Make private', cmds().join(' '));
  click($('titlesBtn')); await sleep(50);
  const rows = [...document.querySelectorAll('#titles .pick-row span')].map(s => s.textContent);
  ok('6. the example titles from the latest race, each look once (1 and 2 read the same here)', rows.length === 4 && rows.join('|') === [...new Set(window.__fx.titles)].join('|'), rows.join('|'));
  ok('6. the one in use is marked', document.querySelector('#titles .pick-row.on').dataset.n === '1' && /In use/.test(document.querySelector('#titles .pick-row.on').textContent));
  ok('6. its back key says BACK TO ALL RACES', $('titles').querySelector('[data-act="close"]').textContent === 'Back to all races');
  window.__req.length = 0; click(document.querySelector('#titles .pick-row[data-n="3"]')); await sleep(150);
  ok('6. pressing the third sends yttemplate a=3 and closes the list', cmds().join(' ') === '/api/do?c=yttemplate&a=3' && !vis($('titles')), cmds().join(' '));
  click($('titlesBtn')); await sleep(50);
  ok('6. the third is now in use', document.querySelector('#titles .pick-row.on').dataset.n === '3');
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); await sleep(50);
  ok('6. Esc closes the list', !vis($('titles')));

  // 7. nothing on a timer
  await sleep(8500); window.__req.length = 0; await sleep(5000);
  ok('7. the open page sends nothing for 5 s', req().length === 0, req().join(' '));
  (window.__ls['list:races'] || []).forEach(f => f()); await sleep(100);
  ok('7. it loads the list again when irdash says it changed (data.onList)', req().join(' ') === '/api/library', req().join(' '));
  out.push('DONE');
  $('out').textContent = out.join('\n');
})();
</script>
'@

$src = [IO.File]::ReadAllText((Join-Path $www 'index.html'))
$base = '<base href="file:///' + ($www -replace '\\', '/') + '/">'
$utf8 = New-Object Text.UTF8Encoding($false)
$thumbs = 'file:///' + ("$tmp\thumbs\" -replace '\\', '/')
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars')
function Page([string]$name, [string]$head, [string]$body) {
  $h = $src.Replace('<head>', '<head>' + $base + $stub + $(if ($head) { '<script>' + $head + '</script>' } else { '' }))
  if ($body) { $h = $h.Replace('</body>', $body + '</body>') }
  [IO.File]::WriteAllText("$tmp\$name.html", $h, $utf8)
  return 'file:///' + ("$tmp\$name.html" -replace '\\', '/') + '?page=races&intro=0&thumbs=' + [uri]::EscapeDataString($thumbs)
}

Assert-RigFree -Where '1-7. page'
$url = Page 't' '' $run
$p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=120000', '--dump-dom', $url)) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt" -Wait
$dom = Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue
$m = [regex]::Match([string]$dom, '(?s)<pre id="out">(.*?)</pre>')
$text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$lines = @($text -split "`n" | Where-Object { $_ -match '^(ok|FAIL) ' })
$lines | ForEach-Object { '  ' + $_ }
$pass += @($lines | Where-Object { $_ -match '^ok' }).Count; $fail += @($lines | Where-Object { $_ -match '^FAIL' }).Count
if ($text -notmatch 'DONE') { '  FAIL  the page test did not finish'; $fail++ }

Assert-RigFree -Where '7. source'
$js = [IO.File]::ReadAllText((Join-Path $www 'pages\races.js'))
if ($js -notmatch 'setInterval' -and $js.Contains("data.onList('races'")) { $pass++; '  ok    7. races.js has no setInterval and reloads on data.onList(''races'')' } else { $fail++; '  FAIL  7. races.js polls or does not use data.onList' }
if ($js.Contains("ctx.go('review', { at: r.startMs || 0 })")) { $pass++; '  ok    4. REVIEW opens the REVIEW door with at=<startMs> (its host passes it to sessions.html; wave 4 reads it)' } else { $fail++; '  FAIL  4. REVIEW link' }

# ---------------- one picture per state ----------------
Assert-RigFree -Where 'pictures'
$signed = 'window.__fx.youtube.signedIn = true;'
$at = { param($js) "<script>setTimeout(async () => { const c = (s, sh) => document.querySelector(s).dispatchEvent(new MouseEvent('click', { bubbles: true, shiftKey: !!sh })); $js }, 600);</script>" }
$states = [ordered]@{
  'list'      = @($signed, '')
  'pq'        = @($signed, (& $at "c('.tab[data-tab=""pq""]');"))
  'empty'     = @('window.__fx.races = []; window.__fx.storage = { usedGb: 0, freeGb: 692, trashGb: 0, moreRaces: 576, lowSpace: false };', '')
  'select'    = @($signed, (& $at "c('.card[data-id=""r1""] .tick'); c('.card[data-id=""r3""] .tick', true);"))
  'signin'    = @('', (& $at "c('.card[data-id=""r1""] .tick');"))
  'open'      = @($signed, (& $at "c('.card[data-id=""r1""] [data-act=""open""]');"))
  'open-shared' = @($signed, (& $at "c('.card[data-id=""r4""] [data-act=""open""]');"))
  'deleted'   = @($signed, (& $at "c('.card[data-id=""r2""] .tick'); c('.card[data-id=""r3""] .tick'); c('#barDelete');"))
  'offline'   = @($signed, (& $at "window.__rig.online = false; window.__emit('online');"))
  'driving'   = @($signed, (& $at "window.__rig.driving = true; window.__emit('state');"))
  'lowspace'  = @($signed + ' window.__fx.storage = { usedGb: 812, freeGb: 96, trashGb: 0, moreRaces: 87, lowSpace: true, freeUp: { count: 6, gb: 7.2 } };', '')
  'lowspace-none' = @($signed + ' window.__fx.storage = { usedGb: 812, freeGb: 96, trashGb: 3, moreRaces: 87, lowSpace: true, freeUp: { count: 0, gb: 0 } };', '')
  'titles'    = @($signed, (& $at "c('#titlesBtn');"))
}
foreach ($s in $states.Keys) {
  $png = Join-Path $shots "races-$s.png"; Remove-Item $png -ErrorAction SilentlyContinue
  $u = Page "s-$s" $states[$s][0] $states[$s][1]
  $p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=2500', "--screenshot=$png", $u)) -NoNewWindow -PassThru -Wait -RedirectStandardError "$tmp\err-$s.txt" -RedirectStandardOutput "$tmp\so-$s.txt"
  if (Test-Path $png) { $pass++; "  ok    picture: $png" } else { $fail++; "  FAIL  no picture for $s" }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
