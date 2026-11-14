# review-laps-test.ps1 - offline (W4-4): REVIEW screen 2, the laps (dash\www\app\pages\review-laps.js + review-laps.css).
# The page runs in headless Chrome inside a fixture shell (tests\fixtures\review\laps\shell.html: the real shell's header and page box,
# the W3-1 ctx, a stand-in for data.js) with a pretend irdash behind fetch: /api/review from tests\fixtures\review\laps\review-*.json
# (the W4-1 contract), /api/review/traces as a hand-made PWB1 reply (make-pwb.js: two laps of a 4088 m Road Atlanta and its corner
# set, written byte for byte as dash\src\workbench.cs does) and /api/review/corners (corners.json). Chart and Map are W4-2's REAL
# app\lib\chart.js and map.js (the shell only records their calls); the map outline is dash\maps\t127-roadatlanta-full.json served
# for /trackmap. Nothing reaches the real irdash.
#   1. the five states (two laps, this lap only, no full lap, working, offline); the chips (counted bright, the best purple, the
#      reason on dim chips, YOUR BEST HERE); a chip press loads the two routes and the stack redraws; the readout column in 36 px
#   2. the corner table (rows, this / reference / difference coloured) and the four definitions once; a row press zooms the chart
#      to that corner and moves the map dot; the theoretical best with its date spread
#   3. the deck (onDeck and the "workbench" state part) moves the cursor and zooms; opts.corner zooms at mount; no timer, no POST
#   4. design-lint (the page's files are on its seat list)
# Pictures: tests\shots\rework\review-laps-<state>.png (look at every one).
#   powershell -ExecutionPolicy Bypass -File tests\review-laps-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'dash\www\app'
$fix = Join-Path $root 'tests\fixtures\review\laps'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'REVIEW: the laps test (W4-4)'
$pass = 0; $fail = 0
function Section($t) { Assert-RigFree -Where $t; $t }

$tmp = Join-Path $env:TEMP ('review-laps-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$read = { param($n) [IO.File]::ReadAllText((Join-Path $fix $n), [Text.Encoding]::UTF8).Trim() }
$fx = 'two: ' + (& $read 'review-two.json') + ', one: ' + (& $read 'review-one.json') + ', ever: ' + (& $read 'review-ever.json') +
  ', nolap: ' + (& $read 'review-nolap.json') + ', working: ' + (& $read 'review-working.json') + ', corners: ' + (& $read 'corners.json')
$shellSrc = & $read 'shell.html'
# one copy of the page with W4-2's REAL app\lib\chart.js and map.js (the shell only writes down their calls; the code still runs),
# so the page and the libraries are proved to agree. The map outline is Road Atlanta's own (dash\maps), served for /trackmap.
New-Item -ItemType Directory -Force "$tmp\site" | Out-Null
Copy-Item -Recurse $app "$tmp\site\app"
Copy-Item (Join-Path $fix 'make-pwb.js') "$tmp\site\app\make-pwb.js"
$outline = [IO.File]::ReadAllText((Join-Path $root 'dash\maps\t127-roadatlanta-full.json'), [Text.Encoding]::UTF8).Trim()
$shellSrc = $shellSrc.Replace('/*OUTLINE*/ null', $outline)
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars', '--force-device-scale-factor=1')
function Page([string]$dir, [string]$name, [string]$setup, [string]$run) {
  $h = $shellSrc.Replace('/*FX*/', $fx).Replace('/*SETUP*/', $setup).Replace('<!--RUN-->', $run)
  [IO.File]::WriteAllText("$dir\app\$name.html", $h, $utf8)
  return 'file:///' + ("$dir\app\$name.html" -replace '\\', '/')
}

# ---------------- the behaviour test (one page; every state is a fresh mount, as REVIEW's card screen does it) ----------------
$run = @'
<script>
window.__run = async () => {
  const out = [], show = () => { const o = document.getElementById('out'); o.textContent = out.join('\n'); o.hidden = false; };
  window.__show = show;     // the shell shows what ran so far if a check throws
  const ok = (what, cond, why) => { out.push((cond ? 'ok ' : 'FAIL ') + what + (cond || why == null ? '' : ' -> ' + why)); show(); };
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const at = async m => { P.cursor(m); for (let i = 0; i < 60 && txt('.chro-m') !== Math.round(m) + ' m'; i++) await sleep(50); };   // the real chart writes its readout on its next animation frame
  const M = window.__M, P = M.Laps, F = window.Fmt, C = window.__chart, Mp = window.__map;
  const q = s => document.querySelector('#page ' + s), qa = s => [...document.querySelectorAll('#page ' + s)];
  const txt = s => { const e = q(s); return e ? e.textContent.replace(/\s+/g, ' ').trim() : ''; };
  const vis = e => !!e && !e.closest('[hidden]') && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const tok = n => { const p = document.createElement('div'); p.style.color = 'var(--' + n + ')'; document.body.appendChild(p); const c = getComputedStyle(p).color; p.remove(); return c; };
  const small = () => qa('*').filter(e => vis(e) && [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) && parseFloat(getComputedStyle(e).fontSize) < 24).map(e => (e.className || e.tagName) + ' ' + getComputedStyle(e).fontSize);
  const box = s => { const r = q(s).getBoundingClientRect(); return { l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom) }; };
  const meet = (a, b) => a.l < b.r && b.l < a.r && a.t < b.b && b.t < a.b;
  const last = (log, name) => { for (let i = log.length - 1; i >= 0; i--) if (log[i][0] === name) return log[i]; return null; };
  const msgText = () => vis(q('.rl-msg')) ? qa('.rl-msg p').map(p => p.textContent).join(' ') : '';
  const use = async (state, opts, offline) => {
    window.__unmount(); window.__state = state; window.__opts = opts || {}; window.__offline = !!offline;
    window.__req.length = 0; C.calls.length = 0; Mp.calls.length = 0; window.__mount(); await sleep(500);
  };
  const tr = (lap, ref) => '/api/review/traces?id=' + encodeURIComponent(window.__fx[window.__state].session.id) + '&lap=' + lap + (ref ? '&ref=' + ref : '');
  const GOLD = tok('gold'), PURPLE = tok('purple'), GAIN = tok('gain'), LOSS = tok('loss'), INK = tok('ink');

  // ---------------- 1. the states ----------------
  await use('two');
  const S = window.__fx.two.session;
  ok('1. two laps: three requests at mount, in order (the review, the traces of lap 8 against lap 9, the corners)',
    window.__req.length === 3 && window.__req[0] === '/api/review?id=last' && window.__req.includes(tr(8, 9)) && window.__req.some(u => u.indexOf('/api/review/corners?') === 0 && /lap=8&ref=9/.test(u)), window.__req.join(' | '));
  const lapChips = qa('.rl-pick .row:nth-child(1) .chip'), refChips = qa('.rl-pick .row:nth-child(2) .chip');
  ok('1. THIS LAP: one chip per lap (10), with the lap and its time', lapChips.length === 10 && lapChips[8].textContent.indexOf('Lap 9') >= 0 && lapChips[8].textContent.indexOf(F.lap(93.832)) > 0, lapChips.map(c => c.textContent).join('|'));
  ok('1. counted laps are bright, the others dim with their reason (out lap, off track, in lap)',
    lapChips.filter(c => c.classList.contains('counted')).length === 7 && ['out lap', 'off track', 'in lap'].every((w, i) => lapChips[[0, 3, 9][i]].classList.contains('dim') && lapChips[[0, 3, 9][i]].textContent.indexOf(w) > 0) &&
    getComputedStyle(lapChips[0].querySelector('.c-t')).color !== getComputedStyle(lapChips[1].querySelector('.c-t')).color, lapChips.map(c => c.className + ':' + c.textContent).join('|'));
  ok('1. the best lap (9) is purple', getComputedStyle(lapChips[8].querySelector('.c-t')).color === PURPLE && lapChips.filter(c => c.classList.contains('best')).length === 1);
  ok('1. this lap = the newest counted lap that is not the reference (8); the reference = the session best (9); the same lap cannot be both',
    lapChips[7].classList.contains('on') && refChips[8].classList.contains('on') && refChips[7].disabled && refChips.length === 10, lapChips.findIndex(c => c.classList.contains('on')) + ' ' + refChips.findIndex(c => c.classList.contains('on')));
  const mnt = last(C.calls, 'mount');
  ok('1. the stack: one Chart with the rows delta, speed, throttle + brake, steering, gear on one 4088 m axis, the delta gold, the 12 corners',
    mnt && mnt[1].rows.join() === 'delta,speed,pedals,steer,gear' && mnt[1].len === 4088 && mnt[1].corners === 12 && mnt[1].series[0].join() === 'gold' && mnt[1].series[1].join() === 'gold,ink', JSON.stringify(mnt && mnt[1]) + ' calls=' + C.calls.map(c => c[0]).join() + ' chart="' + txt('.rl-chart') + '" msg=' + msgText() + ' errs=' + window.__errs.join(' // '));
  ok('1. the readout column is the page\'s .rl-readout, on the right of the stack, always visible, at 36 px (--t-read)',
    mnt && mnt[1].readout === q('.rl-readout') && vis(q('.rl-readout')) && box('.rl-readout').l > 1400 && getComputedStyle(q('.rl-readout')).fontSize === '36px', mnt && box('.rl-readout').l);
  await at(1165);
  const A = window.__pwbLap(94.020, (94.020 - 93.832) * 9), R = window.__pwbLap(93.832, 0);
  const sp = (a, i) => String(Math.round(a.Speed[i] * 2.2369363));
  const spRow = q('.rl-readout [data-key="speed"]'), vals = k => [...qa('.rl-readout [data-key="' + k + '"] .chro-v')].map(e => e.textContent);
  ok('1. at the cursor (1165 m, T5) the REAL readout column shows both laps\' speed in mph (' + sp(A, 1165) + ', ' + sp(R, 1165) + ') and the delta',
    spRow && spRow.textContent.indexOf('mph') > 0 && vals('speed').join() === sp(A, 1165) + ',' + sp(R, 1165) &&
    /^[+−]\d\.\d{3}$/.test(vals('delta')[0]), spRow && spRow.textContent + ' ' + vals('speed').join() + ' m=' + txt('.chro-m') + ' cur=' + P.cursorM + ' errs=' + window.__errs.join('//'));
  const pi = i => String(Math.round(Math.min(100, Math.max(0, i))));
  ok('1. the pedals row reads two values a line in the key\'s columns: [throttle this lap, throttle reference, brake this lap, brake reference] (4 values, 2 columns; colours gain, ink, loss, ink)',
    vals('pedals').length === 4 && qa('.rl-readout [data-key="pedals"] .chro-v').map(e => e.style.color).join() === ['gain', 'ink', 'loss', 'ink'].map(n => 'var(--' + n + ')').join() && qa('.rl-readout [data-key="pedals"] .chro-vals').length === 1 &&
    window.__chart.calls.filter(c => c[0] === 'mount').pop()[1].series[2].join() === 'gain,ink,loss,ink', vals('pedals').join() + ' ' + JSON.stringify(window.__chart.calls.filter(c => c[0] === 'mount').pop()[1].series[2]));
  await at(2500);
  const pv = vals('pedals'), pa = Math.round(A.Throttle[2500] * (A.Throttle[2500] <= 1.001 ? 100 : 1)), pb = Math.round(R.Throttle[2500] * (R.Throttle[2500] <= 1.001 ? 100 : 1));
  ok('1. pedals at 2500 m: column 1 is this lap, column 2 the reference (throttle ' + pa + ' / ' + pb + ')', pv[0] === String(pa) && pv[1] === String(pb), pv.join());
  ok('1. the key under the readout names the two columns "lap 8" and "lap 9" (the library\'s own key)', qa('.rl-readout .chro-k').map(e => e.textContent).join() === 'lap 8,lap 9', qa('.rl-readout .chro-k').map(e => e.textContent).join());
  { const rr = e => e.getBoundingClientRect(), hit = (a, b) => a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1;
    const key = q('.rl-readout .chro-key'), rowsEl = qa('.rl-readout .chro-row'), ro = rr(q('.rl-readout'));
    ok('1. the "lap 8 / lap 9" key overlaps no row of the readout (gear included) and stays inside the readout column',
      !!key && rowsEl.length === 5 && rowsEl.every(e => !hit(rr(key), rr(e))) && rr(key).top >= ro.top - 1 && rr(key).bottom <= ro.bottom + 1 && rr(key).right <= ro.right + 1,
      key && JSON.stringify(rr(key)) + ' rows ' + rowsEl.map(e => Math.round(rr(e).top) + '-' + Math.round(rr(e).bottom)).join(',')); }
  { const lab = qa('.rl-readout .chro-l'), pl = q('.rl-readout [data-key="pedals"] .chro-l'), pr = q('.rl-readout [data-key="pedals"]');
    ok('1. the pedals name is shown whole ("THROTTLE + BRAKE", wrapped if it must), not cut to "THROTTLE ..."; no row name is clipped; names are 24 px or more',
      pl && /THROTTLE \+ BRAKE/i.test(pl.textContent.replace(/\s+/g, ' ')) && lab.every(e => e.scrollWidth <= e.clientWidth + 1 && e.scrollHeight <= e.clientHeight + 1) && pl.getBoundingClientRect().bottom <= pr.getBoundingClientRect().bottom + 1 &&
      lab.every(e => parseFloat(getComputedStyle(e).fontSize) >= 24), lab.map(e => e.textContent + ':' + e.scrollWidth + '/' + e.clientWidth + ',' + e.scrollHeight + '/' + e.clientHeight).join(' | ')); }
  let neg = 0; for (let i = 0; i < 4088; i++) if (A.SteeringWheelAngle[i] < A.SteeringWheelAngle[neg]) neg = i;
  await at(neg);
  ok('1. steering is passed as "deg": the library prints a true minus sign and whole degrees (at ' + neg + ' m, ' + Math.round(A.SteeringWheelAngle[neg] * 57.29578) + ' deg, never a hyphen)',
    A.SteeringWheelAngle[neg] < -0.05 && /^−\d+$/.test(vals('steer')[0]) && vals('steer').every(v => /^[−]?\d+$/.test(v)) && txt('.rl-readout [data-key="steer"]').indexOf('deg') >= 0, vals('steer').join() + ' ' + txt('.rl-readout [data-key="steer"]'));
  await at(1165);
  ok('1. the line above the stack: "Lap 8 1:34.020 against lap 9 1:33.832 · +0.188 s" with the difference red',
    txt('.rl-vs') === 'Lap 8 ' + F.lap(94.02) + ' against lap 9 ' + F.lap(93.832) + ' · +0.188 s' && getComputedStyle(q('.rl-vs b')).color === LOSS, txt('.rl-vs'));
  ok('1. theoretical best with its laps and the date spread: "Theoretical best 1:33.412 from laps 3, 7, 9 (6 Nov – 13 Nov)"',
    txt('.rl-opt') === 'Theoretical best ' + F.lap(93.412) + ' from laps 3, 7, 9 (6 Nov – 13 Nov)', txt('.rl-opt'));
  ok('1. the map: mounted once with the review\'s key and id, coloured by this lap against the reference (100 parts)',
    Mp.calls.filter(c => c[0] === 'mount').length === 1 && last(Mp.calls, 'mount')[1].key === 'roadatlanta-full' && last(Mp.calls, 'mount')[1].id === 127 && last(Mp.calls, 'colour')[1] === 100);
  const g = P.gain(); const t5 = g.slice(26, 31).reduce((a, b) => a + b, 0);
  ok('1. the map colour: the lap loses time at T5 (the parts 26-30 sum ' + t5.toFixed(3) + ' s < 0); the whole lap sums to ref - lap (' + (93.832 - 94.02).toFixed(3) + ')',
    t5 < -0.05 && Math.abs(g.reduce((a, b) => a + b, 0) - (93.832 - 94.02)) < 0.002, t5 + ' ' + g.reduce((a, b) => a + b, 0));
  let sm = small(); ok('1. two laps: no text under 24 px', sm.length === 0, sm.join('; '));
  const Z = { map: box('.rl-map'), top: box('.rl-top'), stack: box('.rl-stack'), corners: box('.rl-corners') }, zn = Object.keys(Z), hits = [];
  for (let i = 0; i < zn.length; i++) for (let j = i + 1; j < zn.length; j++) if (meet(Z[zn[i]], Z[zn[j]])) hits.push(zn[i] + '/' + zn[j]);
  ok('1. the map is top-left, the zones do not overlap and all sit under the header inside 1920 x 1080',
    hits.length === 0 && Z.map.l === 48 && Z.map.t >= 88 && Z.map.l < Z.top.l && Object.values(Z).every(z => z.l >= 0 && z.r <= 1920 && z.b <= 1080), JSON.stringify(Z) + ' ' + hits.join());
  const chipsRight = Math.max(...qa('.chip').map(c => c.getBoundingClientRect().right));
  ok('1. the chips stay inside the screen (ten laps fit)', chipsRight <= 1872 && qa('.rl-pick .row:nth-child(1) .chip').every(vis), chipsRight);
  // a chip press
  window.__req.length = 0; const nm = C.calls.length;
  lapChips[6].click(); await sleep(300);
  ok('1. pressing THIS LAP 7 asks for lap 7 against 9 (traces + corners, nothing else) and the stack redraws with it',
    window.__req.length === 2 && window.__req.includes(tr(7, 9)) && /lap=7&ref=9/.test(window.__req.find(u => u.indexOf('/corners') > 0) || '') && C.calls.slice(nm).some(c => c[0] === 'update' || c[0] === 'mount') && txt('.rl-vs').indexOf('Lap 7') === 0, window.__req.join(' | '));
  ok('1. lap 7 is now the chosen chip; REFERENCE 7 is greyed', q('.rl-pick .row:nth-child(1) .chip:nth-child(7)').classList.contains('on') && q('.rl-pick .row:nth-child(2) .chip:nth-child(7)').disabled);
  window.__req.length = 0; q('.rl-pick .row:nth-child(2) .chip:nth-child(3)').click(); await sleep(300);
  ok('1. pressing REFERENCE 3 asks for lap 7 against 3', window.__req.includes(tr(7, 3)) && txt('.rl-vs').indexOf('against lap 3') > 0, window.__req.join(' | '));
  window.__req.length = 0; q('.rl-pick .row:nth-child(1) .chip:nth-child(3)').click(); await sleep(300);
  ok('1. pressing THIS LAP 3 while 3 is the reference drops the reference (no lap against itself)', window.__req.includes(tr(3, null)) && vis(q('.rl-noref')), window.__req.join(' | '));

  // a lap pair the engine has not built: 202 {"state":"working"} on traces and corners (dash/src/review.cs), then onList('review')
  await use('two');
  window.__pairWorking = true; window.__req.length = 0; C.calls.length = 0;
  q('.rl-pick .row:nth-child(1) .chip:nth-child(6)').click(); await sleep(300);
  ok('1. a 202 "working" answer is not an error: one line "Reading your laps…" where the stack is, no chart, no "would not load", no spinner',
    txt('.rl-chart') === 'Reading your laps…' && qa('.rl-chart canvas').length === 0 && qa('.rl-readout *').length === 0 && last(C.calls, 'unmount') !== null && !/would not load/.test(document.getElementById('page').textContent) && qa('.rl-chart svg, .rl-chart .spin').length === 0 && window.__req.length === 2,
    txt('.rl-chart') + ' | ' + window.__req.join(' | '));
  sm = small(); ok('1. the working line is 24 px or more', sm.length === 0, sm.join('; '));
  window.__req.length = 0; await sleep(2000);
  ok('1. nothing asks again while it waits (2 s: no interval, no polling)', window.__req.length === 0, window.__req.join(' | '));
  window.__pairWorking = false; window.__emit('list:review'); await sleep(400);
  ok('1. when irdash says the review list changed it asks again for that pair (traces + corners) and the stack draws with both laps',
    window.__req.length === 2 && window.__req.includes(tr(6, 9)) && qa('.rl-chart canvas').length === 1 && txt('.rl-chart').indexOf('Reading') < 0 && vals('speed').length === 2 && txt('.rl-vs').indexOf('Lap 6') === 0, window.__req.join(' | ') + ' ' + vals('speed').join());
  window.__req.length = 0; window.__emit('list:review'); await sleep(200);
  ok('1. a list change with nothing waiting asks for nothing', window.__req.length === 0, window.__req.join(' | '));
  // the one fallback: no event, one more ask after 10 s, and that ask does not arm another
  window.__pairWorking = true; window.__req.length = 0;
  q('.rl-pick .row:nth-child(1) .chip:nth-child(5)').click(); await sleep(300);
  window.__req.length = 0; window.__pairWorking = false; await sleep(10600);
  ok('1. fallback: with no event, one single re-ask after 10 s, and the stack draws', window.__req.length === 2 && window.__req.includes(tr(5, 9)) && qa('.rl-chart canvas').length === 1, window.__req.join(' | '));
  window.__pairWorking = true; q('.rl-pick .row:nth-child(1) .chip:nth-child(4)').click(); await sleep(300);
  window.__req.length = 0; await sleep(10600);
  const fb = window.__req.length; window.__req.length = 0; await sleep(10600);
  ok('1. fallback: a re-ask that is told "working" again waits for the event; it does not ask a third time', fb === 2 && window.__req.length === 0 && txt('.rl-chart') === 'Reading your laps…', fb + ' then ' + window.__req.join(' | '));
  window.__pairWorking = false; window.__emit('list:review'); await sleep(400);
  ok('1. ... and the event still redraws it', qa('.rl-chart canvas').length === 1);
  window.__pairWorking = true; q('.rl-pick .row:nth-child(1) .chip:nth-child(7)').click(); await sleep(300);
  window.__unmount(); window.__req.length = 0; window.__pairWorking = false; window.__emit('list:review'); await sleep(10600);
  ok('1. unmounted while waiting: the event and the fallback timer do nothing', window.__req.length === 0 && Object.keys(window.__ls).every(k => window.__ls[k].length === 0), window.__req.join(' | '));
  window.__pairWorking = false;

  await use('one');
  ok('1. this lap only: lap 2 with no reference (traces asked without ref)', window.__req.includes(tr(2, null)) && !window.__req.some(u => /ref=/.test(u)), window.__req.join(' | '));
  const m1 = last(C.calls, 'mount');
  ok('1. this lap only: the delta row is empty and says "no reference lap"; the other rows have this lap alone',
    m1 && m1[1].series[0].length === 0 && m1[1].series[1].join() === 'gold' && vis(q('.rl-noref')) && txt('.rl-noref') === 'Delta: no reference lap' && txt('.rl-vs') === 'Lap 2 ' + F.lap(94.611) + ' · no reference lap' &&
    vals('delta').length === 0 && vals('speed').length === 1, JSON.stringify(m1 && m1[1].series) + ' ' + txt('.rl-vs'));
  ok('1. this lap only: the out lap is dim ("out lap"), lap 2 bright; no theoretical best without one', qa('.rl-pick .row:nth-child(1) .chip')[0].textContent.indexOf('out lap') > 0 && txt('.rl-opt') === '');
  { const d0 = qa('.rl-pick .chip.dim')[0], cs = getComputedStyle(d0);
    ok('1. a dim chip has no edge (only the chosen chip is outlined, in gold)', cs.borderTopColor === 'rgba(0, 0, 0, 0)' && qa('.chip.on').every(c => getComputedStyle(c).borderTopColor === GOLD),
      cs.borderTopColor + ' hover=' + d0.matches(':hover') + ' focus=' + d0.matches(':focus') + ' cls=' + d0.className); }
  ok('1. this lap only: the corner table has one column per measure (no reference, no difference)', qa('.rl-tbl tbody tr:first-child td').length === 5 && qa('.rl-tbl thead tr:nth-child(2) th').length === 4);
  sm = small(); ok('1. this lap only: no text under 24 px', sm.length === 0, sm.join('; '));

  await use('ever');
  const er = qa('.rl-pick .row:nth-child(2) .chip'), ev = er[er.length - 1];
  ok('1. under 3 clean laps: REFERENCE ends with YOUR BEST HERE (1:33.832), chosen, and the traces ask for ref=ever',
    ev.classList.contains('ever') && /Your best here/i.test(ev.textContent) && ev.textContent.indexOf(F.lap(93.832)) > 0 && ev.classList.contains('on') && window.__req.includes(tr(3, 'ever')), ev.textContent + ' ' + window.__req.join(' | '));
  ok('1. under 3 clean laps: "against your best here (6 Nov)"; speeds in km/h (Peter\'s setting from the session)',
    txt('.rl-vs').indexOf('against your best here (6 Nov) ' + F.lap(93.832)) > 0 && /km\/h/.test(txt('.rl-readout [data-key="speed"]')) && /km\/h/.test(txt('.rl-tbl thead')), txt('.rl-vs') + ' / ' + txt('.rl-readout [data-key="speed"]'));

  await use('nolap');
  ok('1. no complete lap: "No full lap yet" and what to do; no chips; no traces asked', msgText() === 'No full lap yet Drive one full lap and the traces show here.' && qa('.chip').length === 0 && window.__req.length === 1, msgText() + ' ' + window.__req.join(' | '));
  sm = small(); ok('1. no complete lap: no text under 24 px', sm.length === 0, sm.join('; '));

  await use('working');
  ok('1. working: one line "Reading your laps…", nothing else asked', msgText() === 'Reading your laps…' && window.__req.length === 1 && qa('.chip').length === 0, msgText());
  window.__state = 'two'; window.__req.length = 0; window.__emit('list:review'); await sleep(400);
  ok('1. working: when irdash says the review list changed, it asks again and the laps show', window.__req[0] === '/api/review?id=last' && qa('.chip').length === 20 && !vis(q('.rl-msg')), window.__req.join(' | '));

  await use('two', {}, true);
  ok('1. offline: one sentence (the shell banner says what to press); no chips', msgText() === 'Your laps show here when Paddock is back.' && qa('.chip').length === 0, msgText());
  sm = small(); ok('1. offline: no text under 24 px', sm.length === 0, sm.join('; '));
  window.__offline = false; window.__req.length = 0; window.__emit('online', true); await sleep(400);
  ok('1. offline: back online it loads by itself', qa('.chip').length === 20 && window.__req.length === 3, window.__req.join(' | '));

  // ---------------- 2. the corner table ----------------
  await use('two');
  const rows = qa('.rl-tbl tbody tr');
  ok('2. one row per corner (12), each with the corner and three columns (this, reference, difference) per measure',
    rows.length === 12 && rows.every(r => r.querySelectorAll('td').length === 13) && rows[4].querySelector('.cn').textContent === 'T5', rows.length + ' ' + (rows[0] && rows[0].querySelectorAll('td').length));
  ok('2. the headings: Brake point (m), Minimum speed (mph), Throttle-on (m), Time', qa('.rl-tbl th.grp').map(e => e.textContent).join('|') === 'Brake point (m)|Minimum speed (mph)|Throttle-on (m)|Time', qa('.rl-tbl th.grp').map(e => e.textContent).join('|'));
  const t5c = [...rows[4].querySelectorAll('td')].map(td => td.textContent);
  ok('2. T5: brake 1044 vs 1058 (−14 m, red: earlier), minimum 67 vs 70 (−3, red), throttle-on 1190 vs 1178 (+12 m, red: later), time 4.918 vs 4.608 (+0.310, red)',
    t5c.slice(1).join('|') === '1044|1058|−14 m|67|70|−3|1190|1178|+12 m|4.918|4.608|+0.310' && [...rows[4].querySelectorAll('td.d')].every(td => getComputedStyle(td).color === LOSS), t5c.join('|'));
  const t6d = [...rows[5].querySelectorAll('td.d')];
  ok('2. T6 is quicker: its time difference (−0.013) is green; a corner with no braking shows the dash', getComputedStyle(t6d[3]).color === GAIN && t6d[3].textContent === '−0.013' && rows[1].querySelectorAll('td')[1].textContent === F.none, t6d.map(t => t.textContent).join('|'));
  ok('2. a corner not on Lovely\'s list says "detected"', rows[7].querySelector('.det') && rows[7].querySelector('.det').textContent === 'detected' && !rows[4].querySelector('.det'));
  const page = document.getElementById('page').textContent, defs = ['Brake point = brake over 10 %', 'Throttle-on = throttle over 90 % after the apex', 'Minimum speed = the slowest point', 'Time = turn-in to exit'];
  const cnt = s => page.split(s).length - 1;
  ok('2. the four definitions, each exactly once, under the table', defs.every(d => cnt(d) === 1) && box('.rl-defs').t >= box('.rl-tblbox').b - 1, defs.map(cnt).join(','));
  ok('2. at least four corner rows show without scrolling', rows.filter(r => { const b = r.getBoundingClientRect(), z = q('.rl-tblbox').getBoundingClientRect(); return b.top >= z.top - 1 && b.bottom <= z.bottom + 1; }).length >= 4, rows.map(r => Math.round(r.getBoundingClientRect().top) + '-' + Math.round(r.getBoundingClientRect().bottom)).slice(0, 6).join(',') + ' win ' + innerWidth + 'x' + innerHeight + ' box ' + JSON.stringify(q('.rl-tblbox').getBoundingClientRect()));
  C.calls.length = 0; Mp.calls.length = 0;
  rows[6].click(); await sleep(100);
  const T = window.__track.corners[6];
  ok('2. a press on T7 zooms the chart to it, puts the cursor on its apex and the map dot there; the row is lit',
    last(C.calls, 'zoomCorner') && last(C.calls, 'zoomCorner')[1] === 7 && Math.abs(last(C.calls, 'setCursor')[1] - T.pa * 4088) < 0.01 && Math.abs(last(Mp.calls, 'cursor')[1] - T.pa) < 1e-6 && rows[6].classList.contains('on') && qa('.rl-tbl tr.on').length === 1,
    JSON.stringify(C.calls) + ' ' + JSON.stringify(Mp.calls));
  sm = small(); ok('2. the table has no text under 24 px', sm.length === 0, sm.join('; '));

  // ---------------- 3. the deck, opts.corner, no timer ----------------
  C.calls.length = 0;
  ok('3. onDeck("wb-next-corner") from T7 goes to T8', M.onDeck('wb-next-corner') === true && last(C.calls, 'zoomCorner')[1] === 8 && q('.rl-tbl tr.on').dataset.n === '8');
  ok('3. onDeck("prev-corner") goes back to T7', M.onDeck('prev-corner') === true && last(C.calls, 'zoomCorner')[1] === 7);
  const c0 = P.cursorM; M.onDeck('wb-step', '50');
  ok('3. onDeck("wb-step", 50) moves the cursor 50 m and the map dot with it', Math.abs(last(C.calls, 'setCursor')[1] - (c0 + 50)) < 0.01 && Math.abs(last(Mp.calls, 'cursor')[1] - (c0 + 50) / 4088) < 1e-6);
  M.onDeck('zoom-reset');
  ok('3. onDeck("zoom-reset") shows the whole lap', last(C.calls, 'zoomLap') !== null && P.range === null);
  M.onDeck('zoom-in');
  const zr = last(C.calls, 'setRange');
  ok('3. onDeck("zoom-in") halves the view around the cursor', zr && Math.abs((zr[2] - zr[1]) - 2044) < 1 && zr[1] <= P.cursorM && zr[2] >= P.cursorM, JSON.stringify(zr));
  window.__req.length = 0; M.onDeck('lap-prev'); await sleep(300);
  ok('3. onDeck("lap-prev") picks the lap before (7) and loads it', window.__req.includes(tr(7, 9)), window.__req.join(' | '));
  // the "workbench" state part: a new seq runs once, the same seq again does nothing
  C.calls.length = 0;
  const wb = { cmd: 'next-corner', arg: '', seq: 41, driving: false };
  window.data.state.workbench = wb; window.__emit('state', window.data.state, { workbench: true });
  const z1 = C.calls.filter(c => c[0] === 'zoomCorner').length;
  window.__emit('state', window.data.state, { workbench: true, rig: true });
  ok('3. the deck\'s command pushed as the "workbench" part (seq 41) runs once; the same seq again does nothing', z1 === 1 && C.calls.filter(c => c[0] === 'zoomCorner').length === 1, z1);
  window.data.state.workbench = { cmd: 'zoom-reset', arg: '', seq: 42, driving: false }; window.__emit('state', window.data.state, { workbench: true });
  ok('3. the next seq (42, zoom-reset) runs', last(C.calls, 'zoomLap') !== null);
  window.data.state.workbench = { cmd: 'next-corner', arg: '', seq: 40, driving: false };
  await use('two', { corner: 5 });
  ok('3. opts.corner = 5 (SHOW ME on the card): the chart zooms to T5 at mount with the cursor and the map dot on its apex; T5 lit',
    last(C.calls, 'zoomCorner') && last(C.calls, 'zoomCorner')[1] === 5 && Math.abs(last(Mp.calls, 'cursor')[1] - 0.285) < 1e-6 && q('.rl-tbl tr.on').dataset.n === '5', JSON.stringify(C.calls.filter(c => c[0] !== 'setCursor')));
  ok('3. a command already waiting when the page opens (seq 40) is not replayed', C.calls.filter(c => c[0] === 'zoomCorner').length === 1);
  window.__req.length = 0; await sleep(3000);
  ok('3. nothing asked while the page sits (3 s), no POST, no data.fetch', window.__req.length === 0 && !window.__posts, window.__req.join(' | '));
  window.__unmount();
  const left = Object.keys(window.__ls).reduce((s, k) => s + window.__ls[k].length, 0);
  ok('3. unmount: no listeners left, the chart and the map unmounted, the page empty', left === 0 && last(C.calls, 'unmount') && last(Mp.calls, 'unmount') && document.getElementById('page').children.length === 0, left);
  // pure helpers
  { const cr = M.cornerRows({ lap: { n: 9, time: 93.8, rows: [{ n: 1, label: 'The Esses', detected: true, brakeM: 5, minSpeed: 60, pickupM: 9, time: 2 }] }, ref: { n: 8, rows: [{ n: 1, label: 'The Esses', brakeM: 6, minSpeed: 61, pickupM: 8, time: 3 }] } });
  ok('3. cornerRows reads the one engine shape (lap.rows / ref.rows, flat rows; a null ref gives dashes; the label is the name as given)', cr.length === 1 && cr[0].label === 'The Esses' && cr[0].lap.brakeM === 5 && cr[0].ref.time === 3 && M.cornerRows({ lap: { rows: [{ n: 1, time: 2 }] }, ref: null })[0].ref.time === null && M.cornerRows({ state: 'working' }).length === 0); }
  ok('3. speedUnit switches on exactly what review.cs writes: review "units" imperial / metric, corners "units" mph / km/h (nothing else, default mph)',
    M.speedUnit({ units: 'metric' }) === 'km/h' && M.speedUnit({ units: 'imperial' }) === 'mph' && M.speedUnit({ units: 'imperial' }, { units: 'km/h' }) === 'km/h' && M.speedUnit({ units: 'metric' }, { units: 'mph' }) === 'mph' && M.speedUnit({ session: { speedUnit: 'km/h' } }) === 'mph' && M.speedUnit(null) === 'mph');
  ok('3. optimalLine: one day once, one lap singular', M.optimalLine({ time: 93.4, from: [{ lap: 9, date: Date.parse('2026-11-13T15:00:00Z') }] }) === 'Theoretical best ' + F.lap(93.4) + ' from lap 9 (13 Nov)', M.optimalLine({ time: 93.4, from: [{ lap: 9, date: Date.parse('2026-11-13T15:00:00Z') }] }));

  out.push('DONE');
  const o = document.getElementById('out'); o.textContent = out.join('\n'); o.hidden = false;
};
</script>
'@

Section '1-3. the page'
$url = Page "$tmp\site" 't' '' $run
$p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=300000', '--dump-dom', $url)) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt" -Wait
$dom = Get-Content "$tmp\out.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
$m = [regex]::Match([string]$dom, '(?s)<pre id="out"[^>]*>(.*?)</pre>')
$text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$lines = @($text -split [char]10 | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^(ok|FAIL) ' })
$lines | ForEach-Object { '  ' + $_ }
$pass += @($lines | Where-Object { $_ -match '^ok' }).Count; $fail += @($lines | Where-Object { $_ -match '^FAIL' }).Count
if ($text -notmatch 'DONE') { '  FAIL  the page test did not finish'; $fail++; Get-Content "$tmp\err.txt" -ErrorAction SilentlyContinue | Select-Object -Last 8; ($text -split "`n" | Select-Object -Last 6) }

Section '3. source'
function Src($what, $cond) { if ($cond) { $script:pass++; "  ok    3. $what" } else { $script:fail++; "  FAIL  3. $what" } }
$js = [IO.File]::ReadAllText((Join-Path $app 'pages\review-laps.js'))
Src 'review-laps.js exports mount(el, ctx, opts), unmount() and onDeck(cmd) by name (REVIEW''s card screen imports them)' ($js -match 'export function mount\(el, ctx, opts\)' -and $js -match 'export function unmount\(\)' -and $js -match 'export function onDeck\(cmd')
Src 'no poller, no POST: no setInterval, exactly one setTimeout (the single 10 s fallback re-ask), no /workbench/cmd, no data.fetch, no method' ($js -notmatch 'setInterval|/workbench/cmd|data\.fetch|method:' -and [regex]::Matches($js, 'setTimeout\(').Count -eq 1)
Src 'no typing anywhere: no input, textarea, select or contenteditable' ($js -notmatch '<input|<textarea|<select|contenteditable')
Src 'no mouse-only tooltips: no title= or :hover-only text' ($js -notmatch 'title=' )

Section '4. design-lint'
$lint = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'design-lint-test.ps1') 2>&1 | Out-String
$mine = @($lint -split "`r?`n" | Where-Object { $_ -match 'review-laps' -and $_ -match 'FAIL' })
$seatListed = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'design-lint-test.ps1')) -match 'review-laps\.css'
if ($mine.Count -eq 0 -and $seatListed -and $lint -match 'passed') { $pass++; '  ok    4. design-lint: review-laps.js / .css are on the seat list and break no rule' } else { $fail++; '  FAIL  4. design-lint: ' + ($mine -join ' / ') + $(if (-not $seatListed) { ' (not on the seat list)' }) }

# ---------------- one picture per state ----------------
Section 'pictures'
$states = [ordered]@{ 'two-laps' = "window.__state = 'two';"; 'this-lap-only' = "window.__state = 'one';"; 'no-full-lap' = "window.__state = 'nolap';";
  'working' = "window.__state = 'working';"; 'offline' = "window.__state = 'two'; window.__offline = true;"; 'show-me-t5' = "window.__state = 'two'; window.__opts = { corner: 5 };";
  'best-here' = "window.__state = 'ever';" }
foreach ($s in $states.Keys) {
  $png = Join-Path $shots "review-laps-$s.png"; Remove-Item $png -ErrorAction SilentlyContinue
  $u = Page "$tmp\site" "s-$s" $states[$s] ''
  $p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=4000', "--screenshot=$png", $u)) -NoNewWindow -PassThru -Wait -RedirectStandardError "$tmp\err-$s.txt" -RedirectStandardOutput "$tmp\so-$s.txt"
  if (Test-Path $png) { $pass++; "  ok    picture: $png" } else { $fail++; "  FAIL  no picture for $s" }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
