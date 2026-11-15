# rig-test.ps1 - offline (W5-1): the RIG page (dash\www\app\pages\rig.js + rig.css) in headless Chrome inside a fixture shell
# (tests\fixtures\rig\rig-shell.html: the shell's header and page box, the W3-1 page contract, a pretend irdash behind fetch, a stand-in
# for data.js whose state parts the test pushes). The /perf answers are tests\fixtures\rig\perf-*.json (PerfJson.Overview's keys).
# Nothing reaches the real irdash.
#   1. the ready line and the four rows: ready, one fault (deck down: the sentence + FIX), two faults (the first wins), iRacing closed or
#      open is not a fault, a session (FIX greyed "Not while driving"), not installed (grey), the Doctor running ("Checking the rig…"),
#      FIX asks /api/doctor/run?quiet=1 once
#   2. LAST RACE: the 12 Nov race (114 · 23.7 fps · lap 9, start/finish, the verdict exactly once), a smooth race (the slowest place),
#      "still being processed" in the numbers' place, /perf failing
#   3. QUIET PC absent / setup:false / on with four items; the nightly line present and absent
#   4. the AC: every control sends its command once (the deck's /api/do?c=ac*), a double press is one, the answer line; not connected
#   5. the switches: START-UP SOUND on/off and MIC NEXT through /api/do, read back, NEXT wraps round
#   6. offline (greyed, nothing asked, nothing pressed), MORE hosts v2/perf.html?embed=1, no timers, unmount leaves nothing
#   7. on every state: nothing under 24 px, nothing spills out of 1920 x 992, the only gold fill is FIX, the only gold words "Rig ready"
#   8. source: a page module, no setInterval, no own fetch, no colour literal
# Pictures: tests\shots\rework\rig-<state>.png, 1920 x 1080 (look at every one).
#   powershell -ExecutionPolicy Bypass -File tests\rig-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'dash\www\app'
$fix = Join-Path $root 'tests\fixtures\rig'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'RIG page test (W5-1)'
$pass = 0; $fail = 0
function Section($t) { Assert-RigFree -Where $t; $t }

$tmp = Join-Path $env:TEMP ('rig-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item -Recurse $app "$tmp\app"
Copy-Item -Recurse (Join-Path $root 'dash\www\v2') "$tmp\v2"
# MORE's frame: the old Performance page asks the fixture's pretend irdash (its parent's fetch) for /perf
$ph = [IO.File]::ReadAllText("$tmp\v2\perf.html")
$ph = $ph.Replace('<head>', '<head><script>try { window.fetch = parent.__fetch || window.fetch; } catch (e) { }</script>')
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$tmp\v2\perf.html", $ph, $utf8)
$read = { param($n) [IO.File]::ReadAllText((Join-Path $fix $n), [Text.Encoding]::UTF8).Trim() }
$fx = (@('perf-12nov', 'perf-smooth', 'perf-processing') | ForEach-Object { "'$_': " + (& $read "$_.json") }) -join ",`n"
$shellSrc = & $read 'rig-shell.html'
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars', '--force-device-scale-factor=1')
function Page([string]$name, [string]$setup, [string]$run) {
  $h = $shellSrc.Replace('/*FX*/', $fx).Replace('/*SETUP*/', $setup).Replace('<!--RUN-->', $run)
  [IO.File]::WriteAllText("$tmp\app\$name.html", $h, $utf8)
  return 'file:///' + ("$tmp\app\$name.html" -replace '\\', '/')
}

$run = @'
<script>
window.__run = async () => {
  const out = [], ok = (what, cond, why) => out.push((cond ? 'ok ' : 'FAIL ') + what + (cond || why == null ? '' : ' -> ' + why));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const M = window.__M, FX = window.__fx;
  const q = s => document.querySelector('#page ' + s), qa = s => [...document.querySelectorAll('#page ' + s)];
  const txt = e => { e = typeof e === 'string' ? q(e) : e; return e ? e.textContent.replace(/\s+/g, ' ').trim() : ''; };
  const vis = e => !!e && !e.closest('[hidden]') && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const probe = document.createElement('div'); probe.style.background = 'var(--gold)'; document.body.appendChild(probe); const GOLD = getComputedStyle(probe).backgroundColor;
  probe.style.background = 'var(--loss)'; const RED = getComputedStyle(probe).backgroundColor; probe.style.background = 'var(--gain)'; const GREEN = getComputedStyle(probe).backgroundColor;
  probe.style.background = 'var(--ink)'; const INK = getComputedStyle(probe).backgroundColor; probe.remove();
  const inPage = () => [...document.querySelectorAll('#page *')].filter(vis);
  const ownText = e => [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
  const golds = () => inPage().filter(e => getComputedStyle(e).backgroundColor === GOLD);
  const goldWords = () => inPage().filter(e => ownText(e) && getComputedStyle(e).color === GOLD && !e.closest('.btn'));
  const small = () => inPage().filter(e => ownText(e) && parseFloat(getComputedStyle(e).fontSize) < 24).map(e => e.className + ' ' + getComputedStyle(e).fontSize);
  const PAGE = { l: 0, t: 88, r: 1920, b: 1080 };
  const spill = () => inPage().filter(e => { const r = e.getBoundingClientRect(); return r.width && (r.left < PAGE.l - 1 || r.right > PAGE.r + 1 || r.top < PAGE.t - 1 || r.bottom > PAGE.b + 1); }).map(e => e.className || e.tagName);
  const row = id => q('.rg-row[data-id="' + id + '"]');
  const rowWord = id => txt(row(id).querySelector('.wd')), rowDot = id => row(id).querySelector('.dot').className.replace('dot ', '');
  const doReq = () => window.__req.filter(u => u.indexOf('/api/') === 0);
  const use = async (state, perf, opts, extra) => {
    window.__unmount();
    window.__setup.perf = perf || 'perf-12nov'; window.__fail = false; window.data.online = true;
    window.__use(state); window.__req.length = 0; window.__go.length = 0; window.__timers.length = 0;
    if (extra) extra();
    window.__mount(opts || {}); await sleep(250);
  };
  const look = (st, wantFix) => {
    const g = golds();
    ok('7. ' + st + ': ' + (wantFix ? 'the only gold fill is FIX' : 'no gold fill'), wantFix ? g.length === 1 && g[0].matches('.fix') : g.length === 0, g.map(e => e.className).join(','));
    const gw = goldWords(); ok('7. ' + st + ': the only gold words are "Rig ready"', gw.every(e => txt(e) === 'Rig ready'), gw.map(e => txt(e)).join(','));
    const sm = small(); ok('7. ' + st + ': no text under 24 px', sm.length === 0, sm.join('; '));
    const sp = spill(); ok('7. ' + st + ': nothing spills out of the page area (1920 x 992 under the header)', sp.length === 0, sp.join(','));
  };

  ok('0. the page is the top screen\'s size (1920 x 1080; ' + innerWidth + ' x ' + innerHeight + ')', innerWidth === 1920 && innerHeight === 1080);
  // ---------------- 1. the ready line and the rows ----------------
  await use('ready');
  ok('1. ready: "Rig ready" in gold, no FIX', txt('.rg-ready .say') === 'Rig ready' && getComputedStyle(q('.rg-ready .say')).color === GOLD && q('.fix').hidden, txt('.rg-ready'));
  ok('1. ready: the four rows in order, each a name, a dot and a word', qa('.rg-row').map(r => r.dataset.id).join() === 'iracing,deck,spotter,overlays' && qa('.rg-row').every(r => r.querySelector('.nm') && r.querySelector('.dot') && r.querySelector('.wd')), qa('.rg-row').map(r => txt(r)).join(' | '));
  ok('1. ready: iRacing "closed" grey (not red), the other three "running" green', rowWord('iracing') === 'closed' && rowDot('iracing') === 'off' && getComputedStyle(row('iracing').querySelector('.dot')).backgroundColor !== RED &&
    ['deck', 'spotter', 'overlays'].every(id => rowWord(id) === 'running' && getComputedStyle(row(id).querySelector('.dot')).backgroundColor === GREEN), qa('.rg-row').map(r => txt(r)).join(' | '));
  ok('1. ready: no nightly line when the part is absent', q('.rg-night').hidden);
  look('ready', false);
  await use('deck-down');
  ok('1. one fault: "Stream Deck is not running" with FIX (gold, pressable)', txt('.rg-ready .say') === 'Stream Deck is not running' && !q('.fix').hidden && !q('.fix').disabled && txt('.fix') === 'Fix' && getComputedStyle(q('.fix')).backgroundColor === GOLD, txt('.rg-ready'));
  ok('1. one fault: the Stream Deck row says "not running" in red', rowWord('deck') === 'not running' && getComputedStyle(row('deck').querySelector('.dot')).backgroundColor === RED);
  look('one fault', true);
  q('.fix').click(); q('.fix').click(); await sleep(150);
  ok('1. FIX asks the Doctor once (/api/doctor/run?quiet=1), then the line says "Checking the rig…"', doReq().join() === '/api/doctor/run?quiet=1' && txt('.rg-ready .say') === 'Checking the rig…' && q('.fix').hidden, doReq().join(' ') + ' / ' + txt('.rg-ready'));
  await use('two-faults');
  ok('1. two faults (Spotter and Overlays off): the first one wins, one sentence', txt('.rg-ready .say') === 'The spotter is not running' && rowWord('spotter') === 'off' && rowWord('overlays') === 'off' && qa('.fix').length === 1, txt('.rg-ready'));
  await use('iracing-open');
  ok('1. iRacing open: "open" green and still "Rig ready"', rowWord('iracing') === 'open' && rowDot('iracing') === 'ok' && txt('.rg-ready .say') === 'Rig ready');
  await use('in-session');
  ok('1. in a session: iRacing "in a session"; the overlays fault shows, FIX greyed "Not while driving"', rowWord('iracing') === 'in a session' && txt('.rg-ready .say') === 'The overlays are not running' && q('.fix').disabled && txt('.fix') === 'Not while driving', txt('.rg-ready'));
  q('.fix').click(); await sleep(100);
  ok('1. in a session: pressing the greyed FIX asks nothing', doReq().length === 0, doReq().join(' '));
  await use('not-installed');
  ok('1. Spotter and Overlays not installed: grey "not installed", not a fault', rowWord('spotter') === 'not installed' && rowDot('spotter') === 'off' && rowWord('overlays') === 'not installed' && txt('.rg-ready .say') === 'Rig ready');
  await use('checking');
  ok('1. the Doctor running: "Checking the rig…", no FIX', txt('.rg-ready .say') === 'Checking the rig…' && q('.fix').hidden);
  // the line follows the push: deck back -> ready
  window.__push({ doctor: { running: false }, health: window.__states.ready.health }); await sleep(50);
  ok('1. a push with the deck back turns the line into "Rig ready"', txt('.rg-ready .say') === 'Rig ready');

  // ---------------- 2. LAST RACE ----------------
  await use('ready', 'perf-12nov');
  const all = txt('.rig');
  ok('2. 12 Nov: the average (114) and "Average fps"', txt('.rg-last .avg b') === '114' && /Average fps/.test(txt('.rg-last .avg')), txt('.rg-last'));
  ok('2. 12 Nov: the worst second "23.7 fps · lap 9, start/finish"', txt('.rg-last .worst b') === '23.7 fps' && txt('.rg-last .worst span') === 'Worst second · lap 9, start/finish', txt('.rg-last .worst'));
  ok('2. 12 Nov: the verdict in labels and numbers "FROZE 4 s · lap 9 · start/finish · 23.7 fps", no cause line (none recorded)', txt('.rg-last .verdict') === 'FROZE 4 s · lap 9 · start/finish · 23.7 fps' && !q('.rg-last .cause'), txt('.rg-last .verdict'));
  ok('2. 12 Nov: the verdict appears exactly once on the page (no second copy from the summary, no sentence)', (all.match(/FROZE/g) || []).length === 1 && !/thing to look at|the picture froze/.test(all), (all.match(/FROZE/g) || []).length);
  ok('2. 12 Nov: the track and day beside LAST RACE', /Last race\s*Road Atlanta · 12 Nov/i.test(txt('.rg-last .lbl')), txt('.rg-last .lbl'));
  ok('2. one request at mount: /perf', window.__req.join() === '/perf', window.__req.join(' '));
  window.__req.length = 0; window.__setup.perf = 'perf-smooth'; window.__emit('list:perf'); await sleep(150);
  ok('2. the perf list changed: /perf asked again and the smooth race shows (71.4 fps, the place unsaid without a freeze)', window.__req.join() === '/perf' && txt('.rg-last .worst b') === '71.4 fps' && txt('.rg-last .worst span') === 'Worst second' && txt('.rg-last .verdict') === 'SMOOTH · GPU 50 % · CPU 37 %', txt('.rg-last'));
  look('smooth race', false);
  await use('ready', 'perf-processing');
  ok('2. "still being processed": "LAST RACE · reading…" alone (no numbers, no older verdict, no sentence)', txt('.rg-last .where') === 'reading…' && q('.rg-last').children.length === 1 && !q('.rg-last .nums') && !/older verdict|processed/.test(txt('.rig')), txt('.rg-last'));
  await use('ready', 'fail');
  ok('2. /perf failing: one plain line', txt('.rg-last .line') === 'Could not read', txt('.rg-last'));

  // ---------------- 3. QUIET PC and the nightly line ----------------
  await use('ready');
  ok('3. quiet part absent: "Quiet PC · not set up" in grey, no button', txt('.rg-quiet .line') === 'Quiet PC · not set up' && q('.rg-quiet .line').classList.contains('off') && !q('.rg-quiet button'), txt('.rg-quiet'));
  await use('quiet-off');
  ok('3. quiet setup:false: "Quiet PC · not set up"', txt('.rg-quiet .line') === 'Quiet PC · not set up');
  await use('quiet-on');
  ok('3. quiet on: no sentence (the items say it), four items, each a green dot, "on" beside the label', !q('.rg-quiet .line') && qa('.rg-quiet .it').length === 4 &&
    qa('.rg-quiet .it .dot').every(d => getComputedStyle(d).backgroundColor === GREEN) && /on$/.test(txt('.rg-quiet .lbl')), txt('.rg-quiet'));
  ok('3. quiet on: the items read "Windows Update paused … Sim priority on"', qa('.rg-quiet .it').map(txt).join(' | ') === 'Windows Update paused | Search indexing paused | OneDrive paused | Sim priority on', qa('.rg-quiet .it').map(txt).join(' | '));
  ok('3. the nightly line under the rows: "Rig check 03:00: all good"', !q('.rg-night').hidden && txt('.rg-night') === 'Rig check 03:00: all good' && q('.rg-night').getBoundingClientRect().top >= q('.rg-rows').getBoundingClientRect().bottom - 1);
  look('quiet on', false);
  window.__push({ quiet: Object.assign({}, window.__states['quiet-on'].quiet, { items: [{ id: 'update', name: 'Windows Update', state: 'running' }] }), nightly: null }); await sleep(50);
  ok('3. quiet on but Windows Update running: an amber dot; the nightly part gone: no line', getComputedStyle(q('.rg-quiet .it .dot')).backgroundColor !== GREEN && q('.rg-quiet .it .dot').classList.contains('amber') && q('.rg-night').hidden);

  // ---------------- 4. the AC ----------------
  await use('ready');
  const acBtns = qa('.rg-ac button');
  ok('4. AC connected: power, − and +, auto-cool, mode, fan and the three presets (9 buttons); target 72°F and room 75°F', acBtns.length === 9 && txt('.rg-ac .temp b') === '72°F' && txt('.rg-ac .temp span') === 'room 75°F', acBtns.map(txt).join(' | ') + ' / ' + txt('.rg-ac .temp'));
  const want = ['/api/do?c=acpower', '/api/do?c=actemp&a=-1', '/api/do?c=actemp&a=%2B1', '/api/do?c=acauto', '/api/do?c=acmode&a=auto', '/api/do?c=acfan&a=low', '/api/do?c=acpreset&a=max', '/api/do?c=acpreset&a=comfort', '/api/do?c=acpreset&a=quiet'];
  for (let i = 0; i < 9; i++) { const b = qa('.rg-ac button')[i]; b.click(); b.click(); await sleep(80); }
  ok('4. every AC control sends its own command once, the deck\'s /api/do (a double press is one)', JSON.stringify(doReq()) === JSON.stringify(want), doReq().join(' '));
  ok('4. the answer on the page: "Sent to the AC"', /Sent to the AC/.test(txt('.rg-ac .lbl')), txt('.rg-ac .lbl'));
  window.__push({ ac: Object.assign({}, window.__states.ready.ac, { busy: true }) }); await sleep(50);
  ok('4. the AC part says busy: "Sending to the AC…"', /Sending to the AC…/.test(txt('.rg-ac .lbl')));
  window.__push({ ac: Object.assign({}, window.__states.ready.ac, { busy: false, mode: 1 }) }); await sleep(50);
  ok('4. then the AC\'s own state: "Auto · fan auto", MODE now goes to Dry', /Auto · fan auto/.test(txt('.rg-ac .lbl')) && q('.rg-ac button[data-c="acmode"]').dataset.a === 'dry', txt('.rg-ac'));
  await use('ac-off');
  ok('4. AC not connected: one grey line, no buttons', txt('.rg-ac .line') === 'AC not connected' && q('.rg-ac .line').classList.contains('off') && !q('.rg-ac button'), txt('.rg-ac'));
  look('AC not connected', false);

  // ---------------- 5. the switches ----------------
  await use('ready');
  const swOn = () => q('.rg-sw button[data-c="startupsound"][data-a="on"]'), swOff = () => q('.rg-sw button[data-c="startupsound"][data-a="off"]');
  ok('5. START-UP SOUND: ON filled (ink), OFF outlined', swOn().classList.contains('filled') && getComputedStyle(swOn()).backgroundColor === INK && !swOff().classList.contains('filled'));
  const micDot = () => !!q('.rg-sw .mic .dot.ok');
  ok('5. MIC: the default mic\'s name only, with a green dot for Windows\' default, NEXT beside it', txt('.rg-sw .mic') === 'Headset (Arctis 7P+)' && micDot() && !/default/i.test(txt('.rg-sw .mic')) && q('.rg-sw button[data-c="mic"]'), txt('.rg-sw .mic'));
  swOff().click(); await sleep(150);
  ok('5. OFF: /api/do?c=startupsound&a=off once; read back: OFF filled, "Start-up sound off"', doReq().join() === '/api/do?c=startupsound&a=off' && swOff().classList.contains('filled') && !swOn().classList.contains('filled') && txt('.rg-sw .answer') === 'Start-up sound off', doReq().join(' ') + ' / ' + txt('.rg-sw'));
  const next = async () => { q('.rg-sw button[data-c="mic"]').click(); await sleep(150); return txt('.rg-sw .mic') + (micDot() ? ' (dot)' : ''); };
  const m1 = await next(), m2 = await next(), m3 = await next();
  ok('5. MIC NEXT: Headset, then the Realtek mic, then round to Windows\' default', m1 === 'Headset (Arctis 7P+)' && m2 === 'Microphone (Realtek USB2.0 Audio)' && m3 === 'Headset (Arctis 7P+) (dot)', [m1, m2, m3].join(' | '));
  ok('5. each NEXT is one /api/do?c=mic&a=next', doReq().filter(u => u === '/api/do?c=mic&a=next').length === 3, doReq().join(' '));
  window.__push({ settings: Object.assign({}, window.__server.settings, { mic: 'Old USB mic' }) }); await sleep(50);
  ok('5. a chosen mic that is not plugged in says so', txt('.rg-sw .mic') === 'Old USB mic · not plugged in', txt('.rg-sw .mic'));

  // ---------------- 6. offline, MORE, timers, unmount ----------------
  window.__unmount(); window.__use('deck-down'); window.__req.length = 0; window.data.online = false; window.__mount({}); await sleep(200);
  ok('6. offline at mount: greyed, every button off, nothing asked', q('.rig').classList.contains('stale') && qa('button').every(b => b.disabled) && window.__req.length === 0, window.__req.join(' '));
  qa('button').forEach(b => b.click()); q('.fix').disabled = false; q('.fix').click(); await sleep(100);
  ok('6. offline: presses send nothing', window.__req.length === 0, window.__req.join(' '));
  window.data.online = true; window.__emit('online', true); await sleep(150);
  ok('6. Paddock back: no longer greyed, /perf asked', !q('.rig').classList.contains('stale') && window.__req.join() === '/perf' && !q('.more').disabled, window.__req.join(' '));
  window.data.online = false; window.__emit('online', false); await sleep(50);
  ok('6. offline after: what was on screen stays, greyed (the 12 Nov numbers still there)', q('.rig').classList.contains('stale') && txt('.rg-last .worst b') === '23.7 fps' && qa('.rig button').every(b => b.disabled));
  await use('ready');
  q('.more').click();
  ok('6. MORE: the shell is asked for RIG\'s screen "more"', JSON.stringify(window.__go) === '[["rig",{"screen":"more"}]]', JSON.stringify(window.__go));
  window.__unmount(); window.__mount({ screen: 'more' }); await sleep(100);
  const f = q('iframe.host');
  ok('6. MORE hosts the old Performance page in the shell\'s frame (v2/perf.html?embed=1)', !!f && f.getAttribute('src') === '../v2/perf.html?embed=1' && !!f.dataset.token, f ? f.getAttribute('src') : 'no frame');
  await use('ready'); await sleep(100);
  ok('6. no timers started by rig.js', window.__timers.length === 0, window.__timers.join(','));
  window.__unmount();
  const left = Object.keys(window.__ls).reduce((s, k) => s + window.__ls[k].length, 0);
  ok('6. unmount: no listener left (state, online, the perf list)', left === 0, JSON.stringify(Object.keys(window.__ls).map(k => k + ':' + window.__ls[k].length)));
  window.__req.length = 0; window.__emit('list:perf'); window.__emit('online', true); await sleep(150);
  ok('6. after unmount nothing is asked', window.__req.length === 0, window.__req.join(' '));

  // ---------------- the helpers ----------------
  ok('8. place: 0.986 = start/finish, 0.5 = 50 % round the lap', M.place(0.986) === 'start/finish' && M.place(0.5) === '50 % round the lap');
  ok('8. nextMode / nextFan follow the deck\'s order and wrap', M.nextMode(2) === 'auto' && M.nextMode(4) === 'cool' && M.nextFan(102) === 'low' && M.nextFan(80) === 'auto');
  ok('8. verdict: a named cause becomes its own short line "Likely: Coach Dave Delta"', (() => { const v = M.verdict({ worst: 23.7, freeze: { lap: 9, pct: 0.986, secs: 4 }, text: 'Lap 9, start/finish: the picture froze for 4 s (worst second 23.7 fps). Likely cause: Coach Dave Delta (3× its usual CPU).' }); return v.head === 'FROZE 4 s · lap 9 · start/finish · 23.7 fps' && v.cause === 'Likely: Coach Dave Delta'; })());
  ok('8. verdict: the processor the limit = "CPU LIMIT · CPU 91 %"; nothing known = no line', M.verdict({ verdict: 'cpu', gpu: 60, cpu: 91 }).head === 'CPU LIMIT · CPU 91 %' && M.verdict({ verdict: 'close' }) === null);
  ok('8. ready: deck down wins over spotter off', M.ready({ apps: [{ id: 'deck', state: 'down' }, { id: 'cc', state: 'off' }] }).text === 'Stream Deck is not running');
  out.push('DONE');
  const o = document.getElementById('out'); o.textContent = out.join('\n'); o.hidden = false;
};
</script>
'@

Section '1-7. the page'
$url = Page 't' '' $run
# headless Chrome's window has a 16 x 95 px frame: this window size gives the page the top screen's 1920 x 1080 (checked in 0.)
$null = Start-Process -FilePath $chrome -ArgumentList (($common -replace '^--window-size=.*', '--window-size=1936,1175') + @('--virtual-time-budget=60000', '--dump-dom', $url)) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt" -Wait
$dom = Get-Content "$tmp\out.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
$m = [regex]::Match([string]$dom, '(?s)<pre id="out"[^>]*>(.*?)</pre>')
$text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$lines = @($text -split [char]10 | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^(ok|FAIL) ' })
$lines | ForEach-Object { '  ' + $_ }
$pass += @($lines | Where-Object { $_ -match '^ok' }).Count; $fail += @($lines | Where-Object { $_ -match '^FAIL' }).Count
if ($text -notmatch 'DONE') { '  FAIL  the page test did not finish'; $fail++; Get-Content "$tmp\err.txt" -ErrorAction SilentlyContinue | Select-Object -Last 8 }

Section '8. source'
function Src($what, $cond) { if ($cond) { $script:pass++; "  ok    8. $what" } else { $script:fail++; "  FAIL  8. $what" } }
$js = [IO.File]::ReadAllText((Join-Path $app 'pages\rig.js'))
$cs = [IO.File]::ReadAllText((Join-Path $app 'pages\rig.css'))
$code = [regex]::Replace($js, '(?m)//.*$|(?s)/\*.*?\*/', '')
Src 'rig.js is a page module (export default with name, title, mount, unmount)' ($js -match "export default \{\s*name: 'rig', title: 'RIG'" -and $js -match 'mount\(el, ctx\)' -and $js -match 'unmount\(\)')
Src 'no timers in rig.js (setInterval, setTimeout), no EventSource, no own fetch: data.json / data.fetch only' ($code -notmatch 'setInterval|setTimeout|EventSource' -and $code -notmatch '(?<![.\w])fetch\(' -and $code -match 'data\.json\(' -and $code -match 'data\.fetch\(')
Src 'every state part through data.on(''state''): health, doctor, rig, quiet, nightly, ac, settings' ($code -match "d\.on\('state'" -and $code -match "\['health', 'doctor', 'rig', 'quiet', 'nightly', 'ac', 'settings'\]")
Src 'no colour literal in rig.js or rig.css' (($js + $cs) -notmatch '(?i)#[0-9a-f]{3,8}\b(?![\w-])\s*[;,)]|\brgba?\(|\bhsla?\(')
Src 'MORE uses the shell''s host frame (lib/host.js) on v2/perf.html?embed=1' ($js.Contains("from '../lib/host.js'") -and $js.Contains("'../v2/perf.html?embed=1'"))

# ---------------- one picture per state ----------------
Section 'pictures'
$shotsList = @(
  @('ready', "window.__setup = { state: 'ready', perf: 'perf-12nov', online: true, opts: {} };"),
  @('one-fault', "window.__setup = { state: 'deck-down', perf: 'perf-12nov', online: true, opts: {} };"),
  @('two-faults', "window.__setup = { state: 'two-faults', perf: 'perf-12nov', online: true, opts: {} };"),
  @('in-session', "window.__setup = { state: 'in-session', perf: 'perf-12nov', online: true, opts: {} };"),
  @('checking', "window.__setup = { state: 'checking', perf: 'perf-12nov', online: true, opts: {} };"),
  @('not-installed', "window.__setup = { state: 'not-installed', perf: 'perf-smooth', online: true, opts: {} };"),
  @('last-smooth', "window.__setup = { state: 'iracing-open', perf: 'perf-smooth', online: true, opts: {} };"),
  @('last-processing', "window.__setup = { state: 'ready', perf: 'perf-processing', online: true, opts: {} };"),
  @('quiet-on', "window.__setup = { state: 'quiet-on', perf: 'perf-12nov', online: true, opts: {} };"),
  @('quiet-off', "window.__setup = { state: 'quiet-off', perf: 'perf-12nov', online: true, opts: {} };"),
  @('ac-off', "window.__setup = { state: 'ac-off', perf: 'perf-12nov', online: true, opts: {} };"),
  @('offline', "window.__setup = { state: 'deck-down', perf: 'perf-12nov', online: false, opts: {} };"),
  @('offline-stale', "window.__setup = { state: 'ready', perf: 'perf-12nov', online: true, opts: {}, stale: true };"),
  @('more', "window.__setup = { state: 'ready', perf: 'perf-12nov', online: true, opts: { screen: 'more' } };"))
Add-Type -AssemblyName System.Drawing
foreach ($s in $shotsList) {
  $png = Join-Path $shots ('rig-' + $s[0] + '.png'); Remove-Item $png -ErrorAction SilentlyContinue
  $u = Page ('s-' + $s[0]) $s[1] ''
  $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=4000', "--screenshot=$png", $u)) -NoNewWindow -PassThru -Wait -RedirectStandardError "$tmp\err-$($s[0]).txt" -RedirectStandardOutput "$tmp\so-$($s[0]).txt"
  if (Test-Path $png) {
    $img = [Drawing.Image]::FromFile($png); $w = $img.Width; $h = $img.Height; $img.Dispose()
    if ($w -eq 1920 -and $h -eq 1080) { $pass++; "  ok    picture ($w x $h): $png" } else { $fail++; "  FAIL  picture $png is $w x $h, not 1920 x 1080" }
  } else { $fail++; "  FAIL  no picture for $($s[0])" }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
