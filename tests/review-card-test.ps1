# review-card-test.ps1 - offline (W4-3): REVIEW screen 1, the card (dash\www\app\pages\review.js + review.css).
# The page runs in headless Chrome inside a fixture shell (tests\fixtures\review\card-shell.html: the shell's header and page box, the
# W3-1 page contract, a pretend irdash behind fetch, a stand-in for data.js). The /api/review answers are tests\fixtures\review\card-*.json
# (W4-1's contract, name for name). Until W4-2, W4-4 and W4-6 land, their modules are stand-ins (map-stub.js, sub-stub.js) with the
# same API. Nothing reaches the real irdash.
#   1. the states: practice with 8 clean laps, practice with 2 laps, a race, no full lap, working, offline (empty and greyed);
#      the four lines and the sample, the gold number the only gold words, SHOW ME the only gold fill, the plan line, the reference
#      line, the wording lint on every line, nothing under 24 px, the zones not overlapping or spilling
#   2. the race story: the position points, the pace line, three clips, WATCH plays the clip route, the clean-air card
#   3. SHOW ME and a card press -> ctx.go('review', {screen:'laps', corner}); WATCH greyed without a clip; Esc closes the clip, then
#      goes HOME; screens 2 and 3 by name; no timers; 2 requests at mount; unmount leaves nothing; opts.at / opts.id
#   4. source: a page module, no setInterval, no polling, no colours
# Pictures: tests\shots\rework\review-card-<state>.png (look at every one).
#   powershell -ExecutionPolicy Bypass -File tests\review-card-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'dash\www\app'
$fix = Join-Path $root 'tests\fixtures\review'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'REVIEW card test (W4-3)'
$pass = 0; $fail = 0
function Section($t) { Assert-RigFree -Where $t; $t }

$tmp = Join-Path $env:TEMP ('review-card-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item -Recurse $app "$tmp\app"
# the stand-ins: the map always (the test needs its call log); screen 2 and progress always; screen 3 left out (its "coming" line)
Copy-Item -Force (Join-Path $fix 'map-stub.js') "$tmp\app\lib\map.js"
Copy-Item -Force (Join-Path $fix 'sub-stub.js') "$tmp\app\pages\review-laps.js"
Copy-Item -Force (Join-Path $fix 'sub-stub.js') "$tmp\app\pages\review-progress.js"
Remove-Item "$tmp\app\pages\review-more.js" -ErrorAction SilentlyContinue
$utf8 = New-Object Text.UTF8Encoding($false)
$read = { param($n) [IO.File]::ReadAllText((Join-Path $fix $n), [Text.Encoding]::UTF8).Trim() }
$states = 'card-practice-8', 'card-practice-2', 'card-race', 'card-nolap', 'card-working'
$fx = ($states | ForEach-Object { "'$_': " + (& $read "$_.json") }) -join ",`n"
$shellSrc = & $read 'card-shell.html'
# the pictures (and section 5) draw with the real map (W4-2) when it is in the tree: Road Atlanta's outline as irdash sends it
$outlineFile = Join-Path $root 'dash\maps\t127-roadatlanta-full.json'
$fxP = $fx + $(if (Test-Path $outlineFile) { ",`n'outline': " + [IO.File]::ReadAllText($outlineFile).Trim() } else { '' })
$realMap = Test-Path (Join-Path $app 'lib\map.js')
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars', '--force-device-scale-factor=1')
function Page([string]$name, [string]$setup, [string]$run, [string]$dir = 'app', [string]$fxs = $fx) {
  $h = $shellSrc.Replace('/*FX*/', $fxs).Replace('/*SETUP*/', $setup).Replace('<!--RUN-->', $run)
  [IO.File]::WriteAllText("$tmp\$dir\$name.html", $h, $utf8)
  return 'file:///' + ("$tmp\$dir\$name.html" -replace '\\', '/')
}

# ---------------- the behaviour test (one page; every state is a fresh mount, as the shell does it) ----------------
$run = @'
<script>
window.__run = async () => {
  const out = [], ok = (what, cond, why) => out.push((cond ? 'ok ' : 'FAIL ') + what + (cond || why == null ? '' : ' -> ' + why));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const until = async (f, ms) => { for (let i = 0; i < (ms || 3000) / 50 && !f(); i++) await sleep(50); return f(); };
  const M = window.__M, F = window.Fmt, FX = window.__fx;
  const q = s => document.querySelector('#page ' + s), qa = s => [...document.querySelectorAll('#page ' + s)];
  const txt = e => (typeof e === 'string' ? q(e) : e) ? (typeof e === 'string' ? q(e) : e).textContent.replace(/\s+/g, ' ').trim() : '';
  const vis = e => !!e && !e.closest('[hidden]') && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const probe = document.createElement('div'); probe.style.background = 'var(--gold)'; document.body.appendChild(probe); const GOLD = getComputedStyle(probe).backgroundColor; probe.remove();
  const inPage = () => [...document.querySelectorAll('#page *')].filter(vis);
  const golds = () => inPage().filter(e => getComputedStyle(e).backgroundColor === GOLD);
  const ownText = e => [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
  const goldWords = () => inPage().filter(e => ownText(e) && getComputedStyle(e).color === GOLD && !e.closest('.btn'));
  const small = () => inPage().filter(e => ownText(e) && parseFloat(getComputedStyle(e).fontSize) < 24).map(e => e.className + ' ' + getComputedStyle(e).fontSize);
  const box = e => { const r = (typeof e === 'string' ? q(e) : e).getBoundingClientRect(); return { l: r.left, t: r.top, r: r.right, b: r.bottom }; };
  const meet = (a, b) => a.l < b.r - 1 && b.l < a.r - 1 && a.t < b.b - 1 && b.t < a.b - 1;
  const PAGE = { l: 0, t: 88, r: 1920, b: 1080 };
  const spill = () => inPage().filter(e => !e.closest('.rv-watch')).filter(e => { const r = e.getBoundingClientRect(); return r.width && (r.left < PAGE.l - 1 || r.right > PAGE.r + 1 || r.top < PAGE.t - 1 || r.bottom > PAGE.b + 1); }).map(e => e.className || e.tagName);
  // every line of words on the card screen, as Peter reads them
  const lines = () => ['.rv-top .trk', '.rv-top .sub', '.rv-top .res', '.c-name', '.c-what', '.c-try', '.c-sample', '.note', '.plan', '.ref', '.pace', '.cr', '.nolap .big', '.nolap .say', '.rv-line p']
    .flatMap(s => qa(s)).filter(vis).map(e => txt(e));
  const mapCalls = () => window.__mapCalls();
  const sub = () => window.__subLog || [];
  const use = async (fx, opts, extra) => {
    window.__unmount();
    window.__setup.fx = fx; window.__fail = false; window.__offline(false);
    window.__req.length = 0; window.__go.length = 0; window.__timers.length = 0; window.__mapStub.calls.length = 0; (window.__subLog || []).length = 0;
    if (extra) extra();
    window.__mount(opts || {}); await sleep(400);
  };
  const mapMod = await import('./lib/map.js'); window.__mapStub = mapMod.Map; window.__mapCalls = () => mapMod.Map.calls.map(c => c[0]);
  const checkLook = (st, wantGoldFill) => {
    const g = golds();
    ok('1. ' + st + ': ' + (wantGoldFill ? 'exactly one gold fill (' + wantGoldFill + ')' : 'no gold fill'), wantGoldFill ? g.length === 1 && g[0].matches(wantGoldFill) : g.length === 0, g.map(e => e.className).join(','));
    const gw = goldWords();
    ok('1. ' + st + ': the only gold words are the seconds on the cards', gw.every(e => e.classList.contains('lost')), gw.map(e => e.className + ':' + txt(e)).join(','));
    const sm = small(); ok('1. ' + st + ': no text under 24 px', sm.length === 0, sm.join('; '));
    const sp = spill(); ok('1. ' + st + ': nothing spills out of the page area (1920 x 992 under the header)', sp.length === 0, sp.join(','));
    const bad = lines().map(l => [l, M.lint(l)]).filter(x => x[1]);
    ok('1. ' + st + ': every line passes the wording lint (no %, no "mistake", 14 words at most)', bad.length === 0, bad.map(x => x[0] + ' [' + x[1] + ']').join(' | '));
    if (q('.rv-main')) {
      const z = [box('.rv-top'), box('.rv-map'), box('.rv-right')].concat(q('.rv-bottom') ? [box('.rv-bottom')] : []), hits = [];
      for (let i = 0; i < z.length; i++) for (let j = i + 1; j < z.length; j++) if (meet(z[i], z[j])) hits.push(i + '/' + j);
      ok('1. ' + st + ': the top line, the map, the right half and the bottom do not overlap', hits.length === 0, hits.join(','));
      const inner = qa('.rv-right *').filter(vis).filter(e => { const r = e.getBoundingClientRect(), R = box('.rv-right'); return r.top < R.t - 1 || r.bottom > R.b + 1; });
      ok('1. ' + st + ': everything on the right fits its half', inner.length === 0, inner.map(e => e.className).join(','));
    }
  };

  ok('0. the page is the top screen\'s size (1920 x 1080; ' + innerWidth + ' x ' + innerHeight + ')', innerWidth === 1920 && innerHeight === 1080);
  // ---------------- 1. the states ----------------
  // practice with 8 clean laps: three cards
  await use('card-practice-8');
  let j = FX['card-practice-8'];
  checkLook('practice, 8 clean laps', '.show');
  const cards = qa('.card');
  ok('1. practice: three cards, ranked 1 2 3, at the corners of the fixture', cards.length === 3 && cards.map(c => c.dataset.rank + ':' + c.dataset.n).join() === j.cards.map(c => c.rank + ':' + c.corner.n).join(), cards.map(c => c.dataset.rank + ':' + c.dataset.n).join());
  j.cards.forEach((c, i) => {
    const e = cards[i];
    ok('1. card ' + (i + 1) + ': the four lines (corner, what happened, the seconds, try this) and the sample',
      txt(e.querySelector('.c-name')) === 'Turn ' + c.corner.n && txt(e.querySelector('.c-what')) === c.happened && txt(e.querySelector('.lost')) === c.lost.toFixed(2) + ' s' &&
      txt(e.querySelector('.c-try')) === 'Try this: ' + c.tryThis && txt(e.querySelector('.c-sample')) === c.sample, txt(e));
    ok('1. card ' + (i + 1) + ': its number (' + txt(e.querySelector('.mk')) + ') is the map mark', txt(e.querySelector('.mk')) === String(c.rank));
  });
  ok('1. card 3 (a corner found by Paddock, not Lovely\'s list) says "detected"; the others do not', txt(cards[2].querySelector('.c-tag')) === 'detected' && !cards[0].querySelector('.c-tag'));
  ok('1. the seconds are big (56 px), gold', getComputedStyle(cards[0].querySelector('.lost')).fontSize === '56px' && getComputedStyle(cards[0].querySelector('.lost')).color === GOLD);
  ok('1. the plan line equals the fixture', txt('.plan') === j.plan, txt('.plan'));
  ok('1. the reference line: "Compared with: lap 9 of this session (1:33.832)"', txt('.ref') === 'Compared with: lap 9 of this session (1:33.832)', txt('.ref'));
  ok('1. the top line: track, config, car, Practice, the day', txt('.rv-top .trk') === 'Road Atlanta Full Course' && txt('.rv-top .sub') === 'Toyota GR86 · Practice · ' + M.day(j.session.date, true) && !q('.rv-top .res'), txt('.rv-top'));
  ok('1. the left half: the map mounted with its key and id, coloured by the gain (100 values), the three marks', window.__mapStub.calls[0][1].key === 't127-roadatlanta-full' && window.__mapStub.calls[0][1].id === 127 && window.__mapCalls().join() === 'mount,colour,marks' && window.__mapStub.calls[2][1] === '1@0.33 2@0.05 3@0.93', JSON.stringify(window.__mapStub.calls));
  ok('1. the plan and its buttons are a bottom bar: the shell\'s banner sits above it (body.page-bar)', document.body.classList.contains('page-bar'));
  ok('1. the map is the left half, the cards the right half', box('.rv-map').r <= 960 + 1 && box('.rv-right').l >= 960 - 1, JSON.stringify([box('.rv-map'), box('.rv-right')]));
  ok('1. SHOW ME and WATCH are 64 px buttons; WATCH (card 1 has a clip) is pressable, outlined', q('.show').offsetHeight >= 64 && q('.watch').offsetHeight >= 64 && !q('.watch').disabled && getComputedStyle(q('.watch')).backgroundColor !== GOLD);
  ok('1. two requests at mount: the review and the map\'s outline (' + window.__req.join(' ') + ')', window.__req.length === 2 && window.__req[0] === '/api/review?id=last' && /^\/trackmap\?key=t127-roadatlanta-full&id=127$/.test(window.__req[1]), window.__req.join(' '));
  ok('1. progress (W4-6) mounted in its band under the plan, told the car and the track by name (the engine matches the trend by name) and the three corners', (() => { const m = sub().find(x => x[0] === 'review-progress.js' && x[1] === 'mount'); if (!m) return false; const o = JSON.parse(m[2]); return o.carName === 'Toyota GR86' && o.trackName === 'Road Atlanta' && o.track === 'Road Atlanta' && o.corners.join() === '5,1,12' && box('.rv-progress').t >= box('.rv-bottom').b - 1; })(), JSON.stringify(sub()));
  // with a progress band of 160 px the three cards still fit
  await use('card-practice-8', {}, () => { window.__progH = 160; });
  ok('1. with a 160 px progress band the three cards still fit their half and nothing spills', spill().length === 0 && qa('.card').every(c => c.getBoundingClientRect().bottom <= box('.rv-right').b + 1) && box('.rv-progress').b <= 1080 + 1, JSON.stringify([box('.rv-right'), box('.rv-progress'), spill()]));
  window.__progH = 0;

  // practice with 2 laps: one card, numbers, no advice, the note
  await use('card-practice-2'); j = FX['card-practice-2'];
  checkLook('practice, 2 laps', '.show');
  ok('1. 2 laps: one card with its numbers and no "Try this"', qa('.card').length === 1 && !q('.c-try') && txt('.lost') === '0.42 s' && txt('.c-sample') === j.cards[0].sample, txt('.rv-right'));
  ok('1. 2 laps: the note is shown ("' + j.note + '")', txt('.note') === j.note, txt('.note'));
  ok('1. 2 laps: no plan line (none in the answer)', !q('.plan'));
  ok('1. 2 laps: "Compared with: your best here, ' + M.day(j.session.ref.date) + ' · track 31°, 42 L fuel"', txt('.ref') === 'Compared with: your best here, ' + M.day(j.session.ref.date) + ' · track 31°, 42 L fuel', txt('.ref'));

  // the race: the story instead of the cards
  await use('card-race'); j = FX['card-race'];
  checkLook('race', '.show');
  ok('1. race: the result "P4 from P7 · +41 iRating (estimate)" on the top line', txt('.rv-top .res') === 'P4 from P7 · +41 iRating (estimate)', txt('.rv-top .res'));
  ok('1. race: Race on the top line', /· Race ·/.test(txt('.rv-top .sub')), txt('.rv-top .sub'));
  ok('2. race story: one point per lap (' + j.race.positions.length + '), in the fixture\'s places, P1 side up', (() => { const p = qa('.pos .pt'); if (p.length !== j.race.positions.length) return false; if (p.map(x => +x.dataset.p).join() !== j.race.positions.join()) return false; const y7 = +p[0].getAttribute('cy'), y4 = +p[p.length - 1].getAttribute('cy'); return y4 < y7; })(), qa('.pos .pt').length);
  ok('2. race story: the start and the finish written beside the line (P7, P4), the first and last lap under their points', txt('.pos-wrap .p0') === 'P7' && txt('.pos-wrap .p1') === 'P4' && qa('.pos-x span').map(txt).join('|') === 'Lap 1|Lap 15' &&
    Math.abs((box(qa('.pos-x span')[1]).l + box(qa('.pos-x span')[1]).r) / 2 - (box(qa('.pos .pt').pop()).l + box(qa('.pos .pt').pop()).r) / 2) < 2, qa('.pos-x span').map(txt).join('|'));
  ok('2. race story: the pace line "Your average 1:34.1 · the field 1:34.8 · 19 cars"', txt('.pace') === 'Your average 1:34.1 · the field 1:34.8 · 19 cars', txt('.pace'));
  const crs = qa('.cr');
  ok('2. race story: the three costliest corners, each with a WATCH that has its clip', crs.length === 3 && crs.map(c => c.dataset.n).join() === '1,5,12' && crs.every((c, i) => { const b = c.querySelector('.cr-watch'); return b && !b.disabled && b.dataset.clip === j.race.corners[i].clip.id && +b.dataset.at === j.race.corners[i].clip.at; }) && txt(crs[0].querySelector('.cr-lost')) === '0.62 s', crs.map(txt).join(' | '));
  ok('2. race story: one corner card, marked "clean-air lap", no rank number', qa('.card').length === 1 && txt('.card .c-tag') === 'clean-air lap' && !vis(q('.card .mk')) && txt('.card .c-what') === j.race.cleanAir.happened, txt('.card'));
  window.__req.length = 0;
  crs[1].querySelector('.cr-watch').click(); await sleep(100);
  const vsrc = () => (M.Review.vid || {}).src || '', want = '/vault/video?id=' + encodeURIComponent(j.race.corners[1].clip.id) + '#t=' + j.race.corners[1].clip.at.toFixed(2);
  ok('2. WATCH on Turn 5 opens the one-lap clip (/vault/video) at its second in that clip (' + want + ')', !!q('.rv-watch') && vsrc() === want && txt('.rv-watch .w-cap') === 'Turn 5 · 0.41 s', vsrc());
  await until(() => q('.rv-watch .w-none'), 2000);
  ok('2. a clip that will not play (none here: file://) says "No video of this corner" in one line, REPLAY greyed', txt('.rv-watch .w-none') === 'No video of this corner' && !q('.rv-watch video') && q('.rv-watch .replay').disabled, txt('.rv-watch'));
  const wg = golds().filter(e => e.closest('.rv-watch')), wb = box('.rv-watch');
  ok('2. the clip covers the page (SHOW ME under it), REPLAY and CLOSE, nothing gold on it', vis(q('.rv-watch .replay')) && vis(q('.rv-watch .close')) && wg.length === 0 && wb.t <= 88 + 1 && wb.b >= 1080 - 1 && wb.l <= 1 && wb.r >= 1919 &&
    document.elementFromPoint((box('.show').l + box('.show').r) / 2, (box('.show').t + box('.show').b) / 2).closest('.rv-watch') !== null, JSON.stringify(wb));
  ok('2. the clip ends itself after 10 s on the video\'s own clock (no timer)', window.__timers.length === 0, window.__timers.join());
  const goN = window.__go.length;
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
  await sleep(50);
  ok('3. Esc with the clip open closes the clip and stays on REVIEW', !q('.rv-watch') && window.__go.length === goN, JSON.stringify(window.__go));
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
  ok('3. the next Esc goes HOME (the shell)', window.__go.length === goN + 1 && window.__go[goN][0] === 'home', JSON.stringify(window.__go));
  q('.watch').click(); await sleep(50);
  ok('2. race: the bottom WATCH plays the clean-air card\'s clip', !!q('.rv-watch') && vsrc() === '/vault/video?id=clip-20261113-202708-lap12#t=5.50', vsrc());
  q('.rv-watch .close').click(); await sleep(20);
  ok('2. CLOSE puts the clip away', !q('.rv-watch'));
  q('.show').click();
  ok('3. race: SHOW ME opens screen 2 at the clean-air corner (Turn 1)', JSON.stringify(window.__go.slice(-1)[0]) === JSON.stringify(['review', { screen: 'laps', corner: 1, id: j.session.id, at: j.session.id }]), JSON.stringify(window.__go.slice(-1)[0]));
  await use('card-race', {}, () => { window.__fx['card-race'] = JSON.parse(JSON.stringify(FX['card-race'])); window.__fx['card-race'].session.result.irating = null; });
  ok('1. race without the iRating change: "P4 of 19"', txt('.rv-top .res') === 'P4 of 19', txt('.rv-top .res'));
  await use('card-race', {}, () => { window.__fx['card-race'].session.result.irating = -12; });
  ok('1. race with a loss: "P4 from P7 · −12 iRating (estimate)"', txt('.rv-top .res') === 'P4 from P7 · −12 iRating (estimate)', txt('.rv-top .res'));
  window.__fx['card-race'].session.result.irating = 41;

  // no complete lap
  await use('card-nolap'); j = FX['card-nolap'];
  checkLook('no full lap', '.more');
  ok('1. no full lap: "No full lap yet" big, one sentence, MORE DATA; no cards, no SHOW ME, no WATCH, no plan', txt('.nolap .big') === 'No full lap yet' && vis(q('.nolap .say')) && vis(q('.more')) && !q('.card') && !q('.show') && !q('.watch') && !q('.plan'), txt('.rv-right'));
  ok('1. no full lap: the top line still says where and what (Test drive)', /Test drive/.test(txt('.rv-top .sub')), txt('.rv-top'));
  q('.more').click();
  ok('1. MORE DATA opens screen 3', JSON.stringify(window.__go.slice(-1)[0]) === JSON.stringify(['review', { screen: 'more', at: j.session.id, id: j.session.id }]), JSON.stringify(window.__go.slice(-1)[0]));
  ok('1. no full lap: the map shows the track, uncoloured, unmarked', window.__mapCalls().join() === 'mount', window.__mapCalls().join());

  // working: one line, asked again when irdash says the review list changed
  await use('card-working');
  checkLook('working', '');
  ok('1. working: one line, "Reading your laps…", nothing else', txt('.rv') === 'Reading your laps…' && qa('.rv *').filter(vis).length === 2, txt('.rv'));
  ok('1. working: one request (the review), no map yet', window.__req.join(' ') === '/api/review?id=last', window.__req.join(' '));
  await sleep(1500);
  ok('1. working: nothing asked again by itself (no timer)', window.__req.length === 1 && window.__timers.length === 0, window.__req.join(' ') + ' ' + window.__timers.join());
  window.__setup.fx = 'card-practice-8'; window.__req.length = 0; window.__emit('list:review'); await sleep(300);
  ok('1. the review list changes (onList "review"): asked once more, and the card is there', window.__req[0] === '/api/review?id=last' && qa('.card').length === 3, window.__req.join(' '));
  window.__req.length = 0; window.__emit('list:review'); await sleep(200);
  ok('1. a ready card is not asked again when the list changes', window.__req.length === 0, window.__req.join(' '));

  // offline: no answer yet -> one sentence; then the last answer greyed
  await use('card-practice-8', {}, () => { for (const k in M.Review.memo) delete M.Review.memo[k]; window.__offline(true); });
  ok('1. offline at mount, nothing seen yet: one sentence, no request (the shell\'s banner says why)', txt('.rv') === 'Your review shows here when Paddock is running.' && window.__req.length === 0 && window.__banners.length === 0, txt('.rv') + ' / ' + window.__req.join(' '));
  window.__offline(false); await sleep(300);
  ok('1. Paddock back: the review is asked for once and shown', qa('.card').length === 3 && window.__req.filter(u => u === '/api/review?id=last').length === 1, window.__req.join(' '));
  window.__unmount(); window.__fail = true; window.__offline(true); window.__req.length = 0; window.__mount({}); await sleep(300);
  ok('1. offline with a review seen before: it shows greyed, nothing pressable', qa('.card').length === 3 && q('.rv').classList.contains('stale') && parseFloat(getComputedStyle(q('.rv')).opacity) < 0.6 && qa('.rv button').every(b => b.disabled), q('.rv').className);
  q('.card').click();
  ok('1. offline: a card press does nothing', window.__go.length === 0, JSON.stringify(window.__go));
  window.__fail = false; window.__offline(false); await sleep(300);
  ok('1. back online: asked again, no longer grey, pressable', !q('.rv').classList.contains('stale') && !q('.show').disabled, q('.rv').className);
  await use('card-practice-8', {}, () => { window.__fail = true; });
  ok('1. the answer fails while online (irdash restarting): the last answer greyed', q('.rv').classList.contains('stale') && qa('.card').length === 3);
  await use('card-practice-8', {}, () => { for (const k in M.Review.memo) delete M.Review.memo[k]; window.__fail = true; });
  ok('1. the answer fails while online, nothing seen before: "This review could not be read."', txt('.rv') === 'This review could not be read.', txt('.rv'));
  window.__fail = false; window.__req.length = 0; window.__emit('list:review'); await sleep(300);
  ok('1. ... and the review list changing asks again', qa('.card').length === 3 && window.__req[0] === '/api/review?id=last', window.__req.join(' '));

  await use('card-practice-8'); window.__req.length = 0; window.__subLog.length = 0;
  window.__offline(true); await sleep(200);
  ok('1. online at mount, then Paddock goes: the card on screen greys, nothing pressable, nothing asked', q('.rv').classList.contains('stale') && qa('.card').length === 3 && qa('.rv button').every(b => b.disabled) && window.__req.filter(u => u.indexOf('/api/') === 0).length === 0 && !sub().some(x => x[0] === 'review-progress.js' && x[1] === 'mount'), q('.rv').className + ' ' + window.__req.join(' '));
  window.__offline(false); await sleep(300);
  ok('1. ... and back: asked again, no longer grey', !q('.rv').classList.contains('stale') && window.__req.indexOf('/api/review?id=last') >= 0, window.__req.join(' '));

  // MORE DATA on every state that has a session: left of SHOW ME, outlined (not gold), pressable, a press opens screen 3
  for (const st of ['card-practice-8', 'card-practice-2', 'card-race']) {
    await use(st); const jj = FX[st], mb = q('.acts .more'), sb = q('.acts .show');
    ok('3. ' + st + ': MORE DATA is on the bottom bar, left of SHOW ME, 64 px, outlined (not gold), 24 px type, still one gold fill', !!mb && vis(mb) && !!sb && box(mb).r <= box(sb).l && mb.offsetHeight >= 64 && getComputedStyle(mb).backgroundColor !== GOLD && parseFloat(getComputedStyle(mb).fontSize) >= 24 && golds().length === 1);
    ok('3. ' + st + ': the three buttons fit the bar, and the plan and reference lines stop before them', (() => { const a = box('.acts'), pb = box('.plan-box'); return a.r <= 1920 - 63 && pb.r <= a.l + 1 && box(mb).r <= box(q('.acts .watch')).l + 1; })());
    mb.click();
    const gm = window.__go.filter(g => g[0] === 'review' && g[1] && g[1].screen === 'more');
    ok('3. ' + st + ': MORE DATA calls ctx.go("review", {screen:"more", at and id = the session})', gm.length === 1 && gm[0][1].at === jj.session.id && gm[0][1].id === jj.session.id, JSON.stringify(window.__go));
  }
  await use('card-practice-8', {}, () => { window.__fail = true; });
  ok('3. the greyed (stale) card still shows MORE DATA, not pressable', !!q('.acts .more') && q('.acts .more').disabled && q('.rv').classList.contains('stale'));
  await use('card-working');
  ok('3. working: no MORE DATA', !q('.more'));

  // ---------------- 3. the presses ----------------
  await use('card-practice-8'); j = FX['card-practice-8'];
  q('.show').click();
  ok('3. SHOW ME: ctx.go(\'review\', {screen:\'laps\', corner:5}) (with the session, so the shell mounts screen 2)', JSON.stringify(window.__go.slice(-1)[0]) === JSON.stringify(['review', { screen: 'laps', corner: 5, id: j.session.id, at: j.session.id }]), JSON.stringify(window.__go));
  qa('.card')[1].click();
  ok('3. a press on card 2: screen 2 at its corner (Turn 1)', window.__go.slice(-1)[0][1].screen === 'laps' && window.__go.slice(-1)[0][1].corner === 1, JSON.stringify(window.__go.slice(-1)[0]));
  q('.watch').click(); await sleep(50);
  ok('3. WATCH: card 1\'s clip', !!q('.rv-watch') && (M.Review.vid || {}).src === '/vault/video?id=clip-20261112-092807-lap6#t=31.40', (M.Review.vid || {}).src);
  window.__unmount();
  ok('3. unmount stops the clip and takes it away', !document.querySelector('.rv-watch'));
  await use('card-practice-8', {}, () => { window.__fx['card-practice-8'] = JSON.parse(JSON.stringify(FX['card-practice-8'])); window.__fx['card-practice-8'].cards[0].clip = null; });
  ok('3. WATCH without a clip: greyed, "no clip", and a press does nothing', q('.watch').disabled && /no clip/.test(txt('.watch')) && (q('.watch').click(), !q('.rv-watch')), txt('.watch'));
  window.__fx['card-practice-8'].cards[0].clip = { id: 'clip-20261112-092807-lap6', at: 31.4 };
  ok('3. no timer started by the page in any of this', window.__timers.length === 0, window.__timers.join());

  // which drive
  await use('card-practice-8', { at: 1794493687000 });
  ok('3. RACES\' REVIEW (opts.at = the race start): /api/review?id=last&at=1794493687000', window.__req[0] === '/api/review?id=last&at=1794493687000', window.__req[0]);
  await use('card-practice-8', { id: 'a b.ibt' });
  ok('3. opts.id: /api/review?id=a%20b.ibt', window.__req[0] === '/api/review?id=a%20b.ibt', window.__req[0]);
  await use('card-practice-8', { at: 'x.ibt' });
  ok('3. SHOW ME\'s own at (a file id): /api/review?id=x.ibt', window.__req[0] === '/api/review?id=x.ibt', window.__req[0]);

  // screens 2 and 3 by name
  await use('card-practice-8', { screen: 'laps', corner: 5, id: 'x.ibt' }); await until(() => q('.rv-sub') && q('.rv-sub').children.length);
  const lm = sub().find(x => x[0] === 'review-laps.js' && x[1] === 'mount');
  ok('3. opts.screen laps: review-laps.js (W4-4) mounted with the same opts, nothing asked by this page', !!lm && JSON.parse(lm[2]).corner === 5 && JSON.parse(lm[2]).id === 'x.ibt' && window.__req.length === 0 && !q('.rv'), JSON.stringify(sub()) + ' ' + window.__req.join(' '));
  window.__emit('state', { workbench: { cmd: 'wb-next', seq: 3 } }, { workbench: true }); await sleep(20);
  ok('3. the deck\'s REVIEW arrows are screen 2\'s own business (it reads the workbench part itself): the card never calls its onDeck', !sub().some(x => x[1] === 'deck'), JSON.stringify(sub()));
  window.__unmount();
  ok('3. unmount unmounts screen 2', sub().some(x => x[0] === 'review-laps.js' && x[1] === 'unmount'));
  await use('card-practice-8', { screen: 'more' }); await until(() => q('.rv-sub') && q('.rv-sub').children.length);
  ok('3. opts.screen more before W4-5 lands: "Coming with the next update."', txt('.rv-sub') === 'Coming with the next update.' && window.__req.length === 0, txt('.rv-sub'));
  await use('card-practice-8', {}, () => { window.__noMap = true; });
  ok('3. the map cannot draw: "Map not available", the cards still there', txt('.rv-map') === 'Map not available' && qa('.card').length === 3, txt('.rv-map'));
  window.__noMap = false;

  // unmount leaves nothing
  await use('card-practice-8'); q('.watch').click(); await sleep(50); window.__unmount();
  const left = Object.keys(window.__ls).filter(k => k !== 'state').reduce((s, k) => s + window.__ls[k].length, 0);
  ok('3. unmount: no listener left (onList, online), the map unmounted, progress unmounted', left === 0 && window.__mapCalls().slice(-1)[0] === 'unmount' && sub().some(x => x[0] === 'review-progress.js' && x[1] === 'unmount'), left + ' ' + window.__mapCalls().join());
  const e = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }); document.dispatchEvent(e);
  ok('3. after unmount the page no longer takes Esc', !e.defaultPrevented);
  window.__req.length = 0; window.__emit('list:review'); window.__emit('online', true); await sleep(300);
  ok('3. after unmount nothing is asked', window.__req.length === 0, window.__req.join(' '));

  // ---------------- the helpers ----------------
  ok('4. lint: a percentage, "mistake", "you should", 15 words fail; the fixture lines pass', M.lint('Pace 96.5 %') && M.lint('A mistake at Turn 5') && M.lint('You should brake later') && M.lint('one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen') && !M.lint(FX['card-practice-8'].plan));
  ok('4. lap1: 94.1 = 1:34.1, 59.96 = 1:00.0', M.lap1(94.1) === '1:34.1' && M.lap1(59.96) === '1:00.0');
  ok('4. cornerName: T5 = Turn 5; a named one = Turn 10 · Esses; a free label stays', M.cornerName({ label: 'T5' }) === 'Turn 5' && M.cornerName({ label: 'T10', name: 'Esses' }) === 'Turn 10 · Esses' && M.cornerName({ label: 'Hairpin' }) === 'Hairpin');
  ok('4. resultLine: P4 of 19 / P4 from P7 · +41 iRating (estimate) / nothing without a finish', M.resultLine({ finish: 4, start: 7, field: 19, irating: null }) === 'P4 of 19' && M.resultLine({ finish: 4, start: 7, field: 19, irating: 41 }) === 'P4 from P7 · +41 iRating (estimate)' && M.resultLine({ finish: 0 }) === '');

  out.push('DONE');
  const o = document.getElementById('out'); o.textContent = out.join('\n'); o.hidden = false;
};
</script>
'@

Section '1-3. the page'
$url = Page 't' '' $run
# headless Chrome's window has a 16 x 95 px frame: this window size gives the page the top screen's 1920 x 1080 (checked in 0.)
$p = Start-Process -FilePath $chrome -ArgumentList (($common -replace '^--window-size=.*', '--window-size=1936,1175') + @('--virtual-time-budget=120000', '--dump-dom', $url)) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt" -Wait
$dom = Get-Content "$tmp\out.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
$m = [regex]::Match([string]$dom, '(?s)<pre id="out"[^>]*>(.*?)</pre>')
$text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$lines = @($text -split [char]10 | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^(ok|FAIL) ' })
$lines | ForEach-Object { '  ' + $_ }
$pass += @($lines | Where-Object { $_ -match '^ok' }).Count; $fail += @($lines | Where-Object { $_ -match '^FAIL' }).Count
if ($text -notmatch 'DONE') { '  FAIL  the page test did not finish'; $fail++; Get-Content "$tmp\err.txt" -ErrorAction SilentlyContinue | Select-Object -Last 8 }

Section '4. source'
function Src($what, $cond) { if ($cond) { $script:pass++; "  ok    4. $what" } else { $script:fail++; "  FAIL  4. $what" } }
$js = [IO.File]::ReadAllText((Join-Path $app 'pages\review.js'))
$cs = [IO.File]::ReadAllText((Join-Path $app 'pages\review.css'))
$code = [regex]::Replace($js, '(?m)//.*$|(?s)/\*.*?\*/', '')
Src 'review.js is a page module (export default with name, title, mount, unmount, onState)' ($js -match "export default \{\s*name: 'review', title: 'REVIEW'" -and $js -match 'mount\(el, ctx\)' -and $js -match 'unmount\(\)' -and $js -match 'onState\(state, changed\)')
Src 'no timers in review.js (setInterval, setTimeout), no EventSource, no own fetch: data.json only' ($code -notmatch 'setInterval|setTimeout|EventSource' -and $code -notmatch '(?<![.\w])fetch\(' -and $code -match 'data\.json\(')
Src 'no banner calls (the shell owns the offline banner)' ($code -notmatch 'banner\(')
Src 'no colour literal in review.js or review.css' (($js + $cs) -notmatch '(?i)#[0-9a-f]{3,8}\b(?![\w-])\s*[;,)]|\brgba?\(|\bhsla?\(')
Src 'the screens by name: review-laps.js, review-more.js, review-progress.js; the map from lib/map.js' ($js.Contains("'./review-laps.js'") -and $js.Contains("'./review-more.js'") -and $js.Contains("'./review-progress.js'") -and $js.Contains("'../lib/map.js'"))
Src 'WATCH uses the recorder''s one-lap clip route (/vault/video), not the whole-session one' ($js.Contains("'/vault/video?id='") -and -not $js.Contains('/api/rec/session-video?id='))

# ---------------- 5. with the real W4-4 and W4-6 modules (when they are in the tree): the hand-over and the progress band's fit ----------------
Section '5. the real screen 2 and progress band'
$realLaps = Test-Path (Join-Path $app 'pages\review-laps.js'); $realProg = Test-Path (Join-Path $app 'pages\review-progress.js')
if ($realLaps -and $realProg) {
  Copy-Item -Recurse $app "$tmp\app2"
  if (-not (Test-Path "$tmp\app2\lib\map.js")) { Copy-Item -Force (Join-Path $fix 'map-stub.js') "$tmp\app2\lib\map.js" }   # the real W4-2 map when it is in the tree
  $fx2 = $fxP + ",`n'progress': " + (& $read 'progress-four.json')
  function Page2([string]$name, [string]$setup, [string]$run) {
    $h = $shellSrc.Replace('/*FX*/', $fx2).Replace('/*SETUP*/', $setup).Replace('<!--RUN-->', $run)
    [IO.File]::WriteAllText("$tmp\app2\$name.html", $h, $utf8)
    return 'file:///' + ("$tmp\app2\$name.html" -replace '\\', '/')
  }
  $run2 = @'
<script>
window.__run = async () => {
  const out = [], ok = (what, cond, why) => out.push((cond ? 'ok ' : 'FAIL ') + what + (cond || why == null ? '' : ' -> ' + why));
  const sleep = ms => new Promise(r => setTimeout(r, ms)), q = s => document.querySelector('#page ' + s);
  for (let i = 0; i < 60 && !(q('.rv-progress') && q('.rv-progress').textContent.trim()); i++) await sleep(50);
  const band = q('.rv-progress'), R = q('.rv-right').getBoundingClientRect(), B = band.getBoundingClientRect();
  ok('5. the real progress band (W4-6) mounts under the plan and shows its section', !band.hidden && band.textContent.trim().length > 0 && B.top >= q('.rv-bottom').getBoundingClientRect().bottom - 1, band.textContent.slice(0, 80));
  ok('5. with it, the three cards still fit their half and the band ends on screen (band ' + Math.round(B.height) + ' px)', [...document.querySelectorAll('#page .card')].every(c => c.getBoundingClientRect().bottom <= R.bottom + 1 && c.getBoundingClientRect().top >= R.top - 1) && B.bottom <= 1080 + 1, JSON.stringify({ R: [R.top, R.bottom], B: [B.top, B.bottom] }));
  ok('5. it asked /api/review/progress with the track\'s name (the engine matches by name)', window.__req.some(u => /^\/api\/review\/progress\?car=Toyota%20GR86&track=Road%20Atlanta$/.test(u)), window.__req.join(' '));
  window.__unmount(); window.__mount({ screen: 'laps', corner: 5, id: 'x.ibt', at: 'x.ibt' });
  const pg = document.getElementById('page'); for (let i = 0; i < 100 && !/THIS LAP/i.test(pg.textContent); i++) await sleep(50);
  ok('5. SHOW ME\'s screen: the real review-laps.js (W4-4) takes over inside REVIEW (its lap chips)', !q('.rv') && /THIS LAP/i.test(pg.textContent) && !/Coming with the next update/.test(pg.textContent), pg.textContent.slice(0, 120));
  window.__unmount();
  out.push('DONE'); const o = document.getElementById('out'); o.textContent = out.join('\n'); o.hidden = false;
};
</script>
'@
  $u2 = Page2 't2' '' $run2
  $null = Start-Process -FilePath $chrome -ArgumentList (($common -replace '^--window-size=.*', '--window-size=1936,1175') + @('--virtual-time-budget=30000', '--dump-dom', $u2)) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out2.txt" -RedirectStandardError "$tmp\err2.txt" -Wait
  $m2 = [regex]::Match([string](Get-Content "$tmp\out2.txt" -Raw -Encoding UTF8), '(?s)<pre id="out"[^>]*>(.*?)</pre>')
  $t2 = [Net.WebUtility]::HtmlDecode($m2.Groups[1].Value)
  $l2 = @($t2 -split [char]10 | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^(ok|FAIL) ' }); $l2 | ForEach-Object { '  ' + $_ }
  $pass += @($l2 | Where-Object { $_ -match '^ok' }).Count; $fail += @($l2 | Where-Object { $_ -match '^FAIL' }).Count
  if ($t2 -notmatch 'DONE') { '  FAIL  the real-module test did not finish'; $fail++ }
  foreach ($s in @(@('practice-8-progress', "window.__setup = { fx: 'card-practice-8', online: true, opts: {} };"), @('show-me-laps', "window.__setup = { fx: 'card-practice-8', online: true, opts: { screen: 'laps', corner: 5, id: 'x.ibt', at: 'x.ibt' } };"))) {
    $png = Join-Path $shots ('review-card-' + $s[0] + '.png'); Remove-Item $png -ErrorAction SilentlyContinue
    $u = Page2 ('s-' + $s[0]) $s[1] ''
    $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=4000', "--screenshot=$png", $u)) -NoNewWindow -PassThru -Wait -RedirectStandardError "$tmp\err2-$($s[0]).txt" -RedirectStandardOutput "$tmp\so2-$($s[0]).txt"
    if (Test-Path $png) { $pass++; "  ok    picture: $png" } else { $fail++; "  FAIL  no picture for $($s[0])" }
  }
} else { '  (W4-4 / W4-6 not in this tree: section 5 skipped)' }

# ---------------- one picture per state ----------------
Section 'pictures'
# the pictures: the stand-ins for screen 2 and progress (progress kept out), the real map when W4-2 is in the tree
Copy-Item -Recurse "$tmp\app" "$tmp\appP"
if ($realMap) { Copy-Item -Force (Join-Path $app 'lib\map.js') "$tmp\appP\lib\map.js" }
$shotsList = @(
  @('practice-8', "window.__setup = { fx: 'card-practice-8', online: true, opts: {} };"),
  @('practice-2', "window.__setup = { fx: 'card-practice-2', online: true, opts: {} };"),
  @('race', "window.__setup = { fx: 'card-race', online: true, opts: {} };"),
  @('race-watch', "window.__setup = { fx: 'card-race', online: true, opts: {}, watch: '.cr-watch' };"),
  @('nolap', "window.__setup = { fx: 'card-nolap', online: true, opts: {} };"),
  @('working', "window.__setup = { fx: 'card-working', online: true, opts: {} };"),
  @('offline', "window.__setup = { fx: 'card-practice-8', online: false, opts: {} };"),
  @('offline-stale', "window.__setup = { fx: 'card-practice-8', online: true, opts: {}, stale: true };"),
  @('no-clip', "window.__setup = { fx: 'card-practice-8', online: true, opts: {} }; window.__fx['card-practice-8'].cards[0].clip = null;"))
foreach ($s in $shotsList) {
  $png = Join-Path $shots ('review-card-' + $s[0] + '.png'); Remove-Item $png -ErrorAction SilentlyContinue
  $u = Page ('s-' + $s[0]) ($s[1] + ' window.__noProg = true;') '' 'appP' $fxP
  $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=3000', "--screenshot=$png", $u)) -NoNewWindow -PassThru -Wait -RedirectStandardError "$tmp\err-$($s[0]).txt" -RedirectStandardOutput "$tmp\so-$($s[0]).txt"
  if (Test-Path $png) { $pass++; "  ok    picture: $png" } else { $fail++; "  FAIL  no picture for $($s[0])" }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
