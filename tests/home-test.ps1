# home-test.ps1 - offline (W3-3): HOME on the top screen, dash\www\app\pages\home.js + home.css.
# The page runs in headless Chrome inside a fixture shell (tests\fixtures\home\shell.html: the W3-1 page contract in 30 lines),
# with a pretend irdash behind fetch, a stand-in for data.js and, until W3-2 lands, a stand-in clock (clock-stub.js, the same API).
# /official is made by irdash's own code (tests\official-unit.cs homefx: the server decides which rows are "his"); the library,
# /home and the state push are tests\fixtures\home\*.json. Nothing reaches the real irdash.
#   1. the states (rig off; rig on, idle; race within 30 min; session loaded; offline; kids; after a drive; after a practice; a rig
#      problem): one gold fill at most (none when the button cannot be pressed), no text under 24 px, the zones where PLAN 4.1 puts
#      them and not overlapping, never a banner from HOME (the shell owns them), his series only
#   2. countdown maths against a fixed clock: the 24 h boundary, the 30-minute ring, local time
#   3. the one button: RIG ON / DRIVE / START; the DRIVE-his-last-car flow's requests in order and its failure sentence
#   4. the after-drive card's ten minutes, the session's "loaded at", request rate idle <= 2/s, onList, unmount
#   5. source: no real-world block anywhere, no banner calls, no New York clock
# Pictures: tests\shots\rework\home-<state>.png (look at every one).
#   powershell -ExecutionPolicy Bypass -File tests\home-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'dash\www\app'
$fix = Join-Path $root 'tests\fixtures\home'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'HOME test (W3-3)'
$pass = 0; $fail = 0
function Section($t) { Assert-RigFree -Where $t; $t }

$tmp = Join-Path $env:TEMP ('home-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item -Recurse $app "$tmp\app"
Copy-Item -Force (Join-Path $fix 'clock-stub.js') "$tmp\app\lib\clock.js"      # the real clock is W3-2's; the stand-in keeps the test fixed
$utf8 = New-Object Text.UTF8Encoding($false)
$read = { param($n) [IO.File]::ReadAllText((Join-Path $fix $n), [Text.Encoding]::UTF8).Trim() }

# /official from irdash's own code (official.cs + officialcore.cs through tests\official-unit.cs), as of Sat 14 Nov 12:30 UTC
Section '0. /official from the server code'
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$ou = Join-Path $tmp 'official-unit.exe'
$null = & "$fw\csc.exe" -nologo -nowarn:0649 -r:System.Web.Extensions.dll "-out:$ou" "$root\tests\official-unit.cs" "$root\dash\src\officialcore.cs" "$root\dash\src\official.cs" 2>&1
$ofJson = ''
if (Test-Path $ou) { New-Item -ItemType Directory -Force "$tmp\ofroot" | Out-Null; $ofJson = ((& $ou homefx "$tmp\ofroot" '2026-11-14T12:30:00Z') | Where-Object { $_ -like 'JSON *' } | Select-Object -First 1) -replace '^JSON ', '' }
if ($ofJson -match '"loaded":true') { $pass++; '  ok    0. /official made by official.cs for the fixture (his series flagged by the server)' } else { $fail++; '  FAIL  0. /official could not be made from the server code'; exit 1 }

$fx = 'official: ' + $ofJson + ', library: ' + (& $read 'library.json') + ', home: ' + (& $read 'home.json') + ', state: ' + (& $read 'state.json')
$shellSrc = & $read 'shell.html'
$statesJs = & $read 'states.js'
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars', '--force-device-scale-factor=1')
function Page([string]$name, [string]$state, [string]$run) {
  $setup = $statesJs + "`nwindow.__base = JSON.stringify(window.__fx);" + $(if ($state) { "`ntry { sessionStorage.clear(); } catch (e) { }`nwindow.__setups['$state'](window.__fx);" } else { '' })
  $h = $shellSrc.Replace('/*FX*/', $fx).Replace('/*SETUP*/', $setup).Replace('<!--RUN-->', $run)
  [IO.File]::WriteAllText("$tmp\app\$name.html", $h, $utf8)
  return 'file:///' + ("$tmp\app\$name.html" -replace '\\', '/')
}

# the id MY DRIVE gives a recent drive: FNV-1a of the lower-case "car|track", prefixed r (computed here, not by the page)
$x = [uint32]2166136261
foreach ($c in 'toyota gr86|road atlanta'.ToCharArray()) { $x = $x -bxor [uint32][int]$c; $x = [uint32](([uint64]$x * 16777619) % 4294967296) }
$rid = 'r' + $x.ToString('x8')

# ---------------- the behaviour test (one page; every state is a fresh mount, as the shell does it) ----------------
$run = @'
<script>
window.__run = async () => {
  const out = [], ok = (what, cond, why) => out.push((cond ? 'ok ' : 'FAIL ') + what + (cond || why == null ? '' : ' -> ' + why));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const M = window.__M, H = M.Home, F = window.Fmt, q = s => document.querySelector('#page ' + s), txt = s => { const e = q(s); return e ? e.textContent.replace(/\s+/g, ' ').trim() : ''; };
  const DOT = ' \u00b7 ';
  const vis = e => !!e && !e.closest('[hidden]') && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const probe = document.createElement('div'); probe.style.background = 'var(--gold)'; document.body.appendChild(probe); const GOLD = getComputedStyle(probe).backgroundColor; probe.remove();
  const golds = () => [...document.querySelectorAll('#page *')].filter(e => vis(e) && getComputedStyle(e).backgroundColor === GOLD);
  const small = () => [...document.querySelectorAll('#page *')].filter(e => vis(e) && [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) && parseFloat(getComputedStyle(e).fontSize) < 24)
    .map(e => e.className + ' ' + getComputedStyle(e).fontSize);
  const box = s => { const r = q(s).getBoundingClientRect(); return { l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom) }; };
  const meet = (a, b) => a.l < b.r && b.l < a.r && a.t < b.b && b.t < a.b;
  const spill = s => { const z = q(s).getBoundingClientRect(); return [...q(s).querySelectorAll('*')].filter(e => vis(e)).filter(e => { const r = e.getBoundingClientRect(); return r.left < z.left - 1 || r.right > z.right + 1 || r.top < z.top - 1 || r.bottom > z.bottom + 1; }).map(e => e.className || e.tagName); };
  const sends = () => window.__req.filter(u => u.indexOf('/api/do') === 0 || u === '/mydrive');
  const one = () => q('.rig .one');
  const lastSet = () => { const c = window.__clockCalls().filter(x => x[0] === 'set'); return c.length ? c[c.length - 1][1] : null; };
  const allRows = () => [window.__fx.official.next].concat(...window.__fx.official.days.map(d => d.rows));
  const hisOf = series => allRows().some(r => r.series === series && r.his);
  const shownSeries = () => [...document.querySelectorAll('#page .now .nx')].map(e => (allRows().find(r => String(Date.parse(r.t)) === e.dataset.t && (e.textContent.indexOf(r.series) >= 0 || (r.tiny && e.textContent.indexOf(r.tiny) >= 0))) || {}).series || '?');
  const mem = () => JSON.parse(sessionStorage.getItem('paddock.home') || '{}');
  const push = (parts) => window.__emit('state', window.data.state, parts || { rig: true });
  const use = async (name, extra) => {
    window.__unmount();
    window.__now = window.__now0; try { sessionStorage.clear(); } catch (e) { } M.Mem.reset();
    window.__fx = JSON.parse(window.__base); window.__setups[name](window.__fx); if (extra) extra(window.__fx);
    window.data.state = window.__fx.state; window.data.online = window.__fx.online !== false;
    window.__req.length = 0; window.__banners.length = 0; window.__go.length = 0; H.busyUntil = 0; H.failUntil = 0; H.fixAt = 0;
    window.__mount(); await sleep(400);
  };
  const clock = await import('./lib/clock.js'); window.__clockCalls = () => clock.Clock.calls;

  // ---------------- 1. the states ----------------
  for (const st of ['rig-off', 'rig-on-idle', 'race-soon', 'session-garage', 'offline', 'kids', 'after-drive', 'after-practice', 'rig-problem']) {
    await use(st);
    const g = golds(), pressable = !['offline', 'kids'].includes(st);
    ok('1. ' + st + ': ' + (pressable ? 'exactly one gold fill (the one button)' : 'no gold fill (the button cannot be pressed)'), pressable ? g.length === 1 && g[0] === one() : g.length === 0, g.map(e => e.className).join(','));
    const sm = small(); ok('1. ' + st + ': no text under 24 px', sm.length === 0, sm.join('; '));
    const Z = { now: box('.now'), dial: box('.dial'), mine: box('.mine'), rig: box('.rig') }, names = Object.keys(Z);
    const hits = []; for (let i = 0; i < 4; i++) for (let j = i + 1; j < 4; j++) if (meet(Z[names[i]], Z[names[j]])) hits.push(names[i] + '/' + names[j]);
    ok('1. ' + st + ': the four zones do not overlap', hits.length === 0, hits.join(','));
    const sp = ['.now', '.mine', '.rig'].map(s => spill(s)).flat(); ok('1. ' + st + ': nothing spills out of its zone', sp.length === 0, sp.join(','));
    ok('1. ' + st + ': HOME never calls ctx.banner (the shell owns the offline and kids banners)', window.__banners.length === 0, JSON.stringify(window.__banners));
    ok('1. ' + st + ': the Mazda Cup (a car he has driven, not his series) is never shown', !/Mazda/.test(txt('.now')));
    if (st === 'rig-on-idle') {
      ok('1. zones at PLAN 4.1: clock 600-1320 x 120-840, NOW 96-560, MY RACES 1360-1824, RIG 96-1824 x 900-1000', JSON.stringify(Z) === JSON.stringify({ now: { l: 96, t: 120, r: 560, b: 840 }, dial: { l: 600, t: 120, r: 1320, b: 840 }, mine: { l: 1360, t: 120, r: 1824, b: 840 }, rig: { l: 96, t: 900, r: 1824, b: 1000 } }), JSON.stringify(Z));
      const last = window.__fx.home.last;
      ok('1. rig on, idle: the button is DRIVE with his last car and track under it, pressable', /^Drive/.test(one().textContent) && one().textContent.indexOf(last.car) > 0 && one().textContent.indexOf(last.track) > 0 && !one().disabled, one().textContent);
      ok('1. rig on, idle: "Rig ready" in green with the four things it checked; green dot', /^Rig ready/.test(txt('.rig .line')) && ['iRacing', 'deck', 'spotter', 'overlays'].every(w => txt('.rig .line').indexOf(w) > 0) && q('.rig .dot').className === 'dot' && getComputedStyle(q('.rig .line .ok')).color !== getComputedStyle(q('.rig .line .w')).color, txt('.rig .line'));
      ok('1. a doctor warning (frame rate) does not nag on HOME; no FIX IT', !vis(q('.rig .fix')));
      ok('1. the clock is mounted at 720 px in the centre zone', window.__clockCalls().some(c => c[0] === 'mount' && c[1].size === 720) && q('.dial canvas') !== null);
      const nt = Date.parse(window.__fx.official.next.t);
      ok('1. NEXT RACE: the server\'s next race large, at its local start time; the readout is its countdown; no ring yet', txt('.now .nx.big .s') === window.__fx.official.next.series && txt('.now .nx.big .t') === M.localTime(nt) && lastSet() && lastSet().readout === M.countdown(nt, window.__now).readout && lastSet().readout !== null && lastSet().ring === null, txt('.now .nx.big') + ' / ' + JSON.stringify(lastSet()));
      const rows = [...document.querySelectorAll('#page .now .nx')], ts = rows.map(r => +r.dataset.t), ser = shownSeries();
      ok('1. NEXT RACE: at most 4 rows, in time order, every one a series irdash marks "his" (' + ser.join(', ') + ')', rows.length >= 2 && rows.length <= 4 && ts.every((t, i) => !i || ts[i - 1] <= t) && ser.every(hisOf), ser.join(', '));
      ok('1. the next one is 96 px, the others 36 px', getComputedStyle(q('.now .nx.big .t')).fontSize === '96px' && rows.filter(r => !r.classList.contains('big')).every(r => getComputedStyle(r.querySelector('.t')).fontSize === '36px'));
      const mr = [...document.querySelectorAll('#page .mine .mr')], lib = window.__fx.library.races;
      ok('1. MY RACES: his last three drives, newest first', mr.length === 3 && mr.map(r => r.dataset.id).join() === lib.slice(0, 3).map(r => r.id).join(), mr.map(r => r.dataset.id).join());
      ok('1. MY RACES: a race with a known finish shows it (' + M.place(lib[0]) + '), a practice says so with its laps, an unknown result says Race', mr[0].textContent.indexOf(M.place(lib[0])) > 0 && mr[1].textContent.indexOf(F.sessionName(lib[1].type)) > 0 && mr[1].textContent.indexOf(lib[1].laps + ' laps') > 0 && /Race$/.test(mr[2].textContent.trim()), mr.map(r => r.textContent).join(' | '));
      ok('1. MY RACES rows are 36 px (track) and 24 px (date and result)', getComputedStyle(mr[0].querySelector('.s')).fontSize === '36px' && getComputedStyle(mr[0].querySelector('.d')).fontSize === '24px');
      ok('1. LAST RACE is a 64 px button, not gold, and opens REVIEW', vis(q('.last')) && q('.last').offsetHeight === 64 && getComputedStyle(q('.last')).backgroundColor !== GOLD && (q('.last').click(), window.__go.join() === 'review'), q('.last').offsetHeight + ' ' + window.__go.join());
      ok('1. the one button is 240 x 96 or wider, gold', one().offsetHeight === 96 && one().offsetWidth >= 240 && getComputedStyle(one()).backgroundColor === GOLD, one().offsetWidth + 'x' + one().offsetHeight);
    }
    if (st === 'rig-off') ok('1. rig off: RIG ON, a red dot, and the line points at it', /^Rig on/.test(one().textContent) && /RIG ON/.test(txt('.rig .line')) && q('.rig .dot').className === 'dot bad', one().textContent + ' / ' + txt('.rig .line'));
    if (st === 'race-soon') {
      const nt = Date.parse(window.__fx.official.next.t), s = lastSet();
      ok('1. race within 30 min: the ring closes (754 s left = 0.581) and the centre readout counts', s && Math.abs(s.ring - (1 - 754 / 1800)) < 0.002 && s.readout === M.countdown(nt, window.__now).readout, JSON.stringify(s));
      ok('1. race within 30 min: the countdown shows once (centre); the left row keeps the start time', txt('.now .nx.big .t') === M.localTime(nt) && !/\bin \d|\d:\d\d:\d\d/.test(txt('.now')), txt('.now .nx.big .t'));
      window.__now += 4000; await sleep(1100);
      ok('1. a second later the readout moves with the clock', lastSet().readout === M.countdown(nt, window.__now).readout, JSON.stringify(lastSet()));
      window.__now += 760000; await sleep(1100);
      const up = allRows().filter(r => r.his && Date.parse(r.t) > window.__now).sort((a, b) => Date.parse(a.t) - Date.parse(b.t))[0];
      ok('1. once it has started its row fades and the next of his races takes over (row, readout)', q('.now .nx[data-t="' + nt + '"]').classList.contains('past') && txt('.now .nx.big .s') === up.series && lastSet().readout === M.countdown(Date.parse(up.t), window.__now).readout, txt('.now .nx.big') + ' ' + JSON.stringify(lastSet()));
    }
    if (st === 'session-garage') {
      ok('1. session loaded: NOW with the session type, the track and his car', txt('.now .lbl') === 'Now' && txt('.now .nx .t') === F.sessionName('Race') && /Road Atlanta/.test(txt('.now')) && /Toyota GR86/.test(txt('.now')), txt('.now'));
      ok('1. session loaded: the series only because one of his races (the GR Cup) starts at this track within the hour', /Toyota GR Cup/.test(txt('.now')), txt('.now'));
      ok('1. session loaded: "loaded at" the moment the session was loaded (14:00 UTC, local ' + M.localTime(Date.parse('2026-11-14T14:00:00Z')) + ')', txt('.now .since').indexOf(M.localTime(Date.parse('2026-11-14T14:00:00Z'))) > 0, txt('.now .since'));
      ok('1. session loaded: no NEXT GREEN FLAG and no ring on the clock', lastSet() && lastSet().readout === null && lastSet().ring === null, JSON.stringify(lastSet()));
      ok('1. session loaded: the button is DRIVE', /^Drive/.test(one().textContent) && !one().disabled, one().textContent);
      const was = txt('.now .since'); window.__now += 120000; push({ rig: true, session: true }); await sleep(100);
      ok('1. "loaded at" does not move with the next state push', txt('.now .since') === was, txt('.now .since'));
    }
    if (st === 'offline') {
      ok('1. offline: RIG ON, flat grey, not pressable, saying "Paddock is not running"', /^Rig on/.test(one().textContent) && one().disabled && one().classList.contains('off') && /Paddock is not running/.test(one().textContent) && getComputedStyle(one()).opacity === '1', one().textContent);
      window.__req.length = 0; one().click(); await sleep(50);
      ok('1. offline: pressing it sends nothing', sends().length === 0);
      window.data.online = true; window.__emit('online', true); await sleep(1000);
      one().style.transition = 'none';      // the press flash fades over 0.7 s; the end colour is what counts
      ok('1. back online: the gold button is back and pressable', !one().disabled && !one().classList.contains('off') && getComputedStyle(one()).backgroundColor === GOLD, one().className + ' ' + one().disabled + ' ' + getComputedStyle(one()).backgroundColor + ' vs ' + GOLD);
    }
    if (st === 'kids') {
      ok('1. kids mode: the button is grey, not pressable, says "Kids mode is on"', one().disabled && one().classList.contains('off') && /Kids mode is on/.test(one().textContent));
      window.__req.length = 0; one().click(); await sleep(50);
      ok('1. kids mode: pressing it sends nothing', sends().length === 0);
    }
    if (st === 'after-drive') {
      const a = window.__fx.library.races[0];
      ok('1. after a drive: "Your race: ' + M.place(a, true) + '" with REVIEW', vis(q('.after')) && txt('.after .s') === 'Your race: ' + M.place(a, true) && /review/i.test(txt('.after button')), txt('.after'));
      ok('1. after a drive: LAST RACE steps aside; MY RACES does not repeat the card\'s race (two rows, the older ones)', !vis(q('.last')) && [...document.querySelectorAll('#page .mine .mr')].map(r => r.dataset.id).join() === window.__fx.library.races.slice(1, 3).map(r => r.id).join());
      q('.after button').click();
      ok('1. REVIEW opens REVIEW', window.__go.join() === 'review', window.__go.join());
      ok('1. the card\'s start is kept in sessionStorage (the drive appeared now)', mem().newestId === a.id && mem().newestAt === window.__now, JSON.stringify(mem()));
      window.__unmount(); M.Mem.reset(); window.__mount(); await sleep(300);
      ok('1. a reload (unmount, mount from sessionStorage) keeps the card', vis(q('.after')));
      window.__now += 11 * 60000; await sleep(1100);
      ok('1. ten minutes later the card goes by itself', !vis(q('.after')) && vis(q('.last')));
    }
    if (st === 'after-practice') { const a = window.__fx.library.races[0]; ok('1. after a practice: "Your practice: 14 laps, best ' + F.lap(a.best) + '"', txt('.after .s') === 'Your practice: ' + a.laps + ' laps, best ' + F.lap(a.best), txt('.after .s')); }
    if (st === 'rig-problem') {
      ok('1. a rig problem: the doctor\'s sentence, a red dot and FIX IT (outlined, not gold)', txt('.rig .line') === window.data.state.doctor.items.find(i => i.state === 'bad').detail && q('.rig .dot').className === 'dot bad' && vis(q('.rig .fix')) && getComputedStyle(q('.rig .fix')).backgroundColor !== GOLD, txt('.rig .line'));
      window.__req.length = 0; q('.rig .fix').click(); await sleep(50); q('.rig .fix').click(); await sleep(50);
      ok('1. FIX IT asks the doctor once, the way that does not put the old list on screen (doctorcheck)', sends().join(' ') === '/api/do?c=doctorcheck', sends().join(' '));
      window.data.state.doctor.running = true; push({ doctor: true }); await sleep(50);
      ok('1. while the doctor runs: "Checking the rig", FIX IT shown but not pressable', /^Checking the rig/.test(txt('.rig .line')) && vis(q('.rig .fix')) && q('.rig .fix').disabled, txt('.rig .line'));
      window.data.state.doctor.running = false; window.data.state.doctor.items = window.data.state.doctor.items.filter(i => i.state !== 'bad');
      window.data.state.health.apps.find(a => a.id === 'overlays').state = 'ok'; window.data.state.doctor.ask = 'Overlays would not start: ask Claude'; push({ doctor: true, health: true }); await sleep(50);
      ok('1. something only he can do (the doctor\'s ask): the sentence, and no FIX IT', txt('.rig .line') === window.data.state.doctor.ask && !vis(q('.rig .fix')), txt('.rig .line'));
    }
  }

  // ---------------- 2. countdown maths ----------------
  const T0 = Date.parse('2026-11-14T12:00:00Z');
  ok('2. 24 h ahead exactly: the readout shows (NEXT GREEN FLAG 24:00:00), no ring', M.countdown(T0 + 86400000, T0).readout === 'NEXT GREEN FLAG 24:00:00' && M.countdown(T0 + 86400000, T0).ring === null, JSON.stringify(M.countdown(T0 + 86400000, T0)));
  ok('2. one second more than 24 h: nothing', M.countdown(T0 + 86401000, T0).readout === null);
  ok('2. 1:42:09 ahead: "NEXT GREEN FLAG 1:42:09"', M.countdown(T0 + 6129000, T0).readout === 'NEXT GREEN FLAG 1:42:09');
  ok('2. the ring: 30:01 null, 30:00 = 0, 15:00 = 0.5, 0:01 near 1', M.countdown(T0 + 1801000, T0).ring === null && M.countdown(T0 + 1800000, T0).ring === 0 && M.countdown(T0 + 900000, T0).ring === 0.5 && M.countdown(T0 + 1000, T0).ring > 0.999);
  ok('2. started or past: no readout, no ring', M.countdown(T0, T0).readout === null && M.countdown(T0 - 5000, T0).ring === null);
  ok('2. a part second rounds down (12:34.9 = 0:12:34)', M.countdown(T0 + 754900, T0).readout === 'NEXT GREEN FLAG 0:12:34');
  const d = new Date(T0 + 4500000);
  ok('2. local time: 13:15 UTC shows as this PC\'s own clock (' + M.localTime(T0 + 4500000) + ')', M.localTime(T0 + 4500000) === String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'));
  ok('2. local days: Today / Tomorrow / Yesterday / a date', M.localDay(T0, T0) === 'Today' && M.localDay(T0 + 86400000, T0) === 'Tomorrow' && M.localDay(T0 - 86400000, T0) === 'Yesterday' && /^[A-Z][a-z]{2} \d{1,2} [A-Z][a-z]{2}$/.test(M.localDay(T0 + 4 * 86400000, T0)), M.localDay(T0 + 4 * 86400000, T0));
  ok('2. place: P4 of 19, P3 from P9, unknown says nothing, no grid = P5 of 20', M.place({ finish: 4, field: 19, start: 7 }) === 'P4 of 19' && M.place({ finish: 3, start: 9, field: 19 }, true) === 'P3 from P9' && M.place({ finish: 0, start: 9 }) === '' && M.place({ finish: 5, start: 0, field: 20 }, true) === 'P5 of 20');
  ok('2. sameTrack as officialcore: Road Atlanta = Michelin Raceway Road Atlanta, not Road America', M.sameTrack('Road Atlanta - Full Course', 'Michelin Raceway Road Atlanta') && !M.sameTrack('Road America', 'Road Atlanta'));

  // ---------------- 3. the one button ----------------
  await use('rig-off'); window.__req.length = 0; one().click(); await sleep(50); one().click(); await sleep(50);
  ok('3. RIG ON sends key rig-on once (a second press while busy is ignored) and says what it is doing', sends().join(' ') === '/api/do?c=key&a=rig-on' && /Turning on/.test(one().textContent) && one().disabled, sends().join(' ') + ' / ' + one().textContent);
  await use('session-garage'); window.__req.length = 0; one().click(); await sleep(50);
  ok('3. DRIVE in a session sends key go (the deck\'s GO)', sends().join(' ') === '/api/do?c=key&a=go' && /Getting in/.test(one().textContent), sends().join(' '));
  await use('rig-on-idle', fx => { fx.home = { last: null }; });
  ok('3. rig on, no last drive: START (test drive the last one)', /^Start/.test(one().textContent), one().textContent);
  window.__req.length = 0; one().click(); await sleep(50);
  ok('3. START sends key test-drive-last', sends().join(' ') === '/api/do?c=key&a=test-drive-last', sends().join(' '));

  // DRIVE his last car: choose, check it is chosen, then start; MY DRIVE's own failure sentence lands on the button
  await use('rig-on-idle');
  let n = 0; const want = { choice: { has: true, car: 'Toyota GR86', track: 'Road Atlanta' } };
  window.__mydrive = () => { n++; return n === 1 ? { choice: { has: false } } : n === 2 ? want : n === 3 ? { choice: want.choice, phase: 'idle' } : n === 4 ? { choice: want.choice, busy: 'start', phase: 'setup' } : { choice: want.choice, phase: 'failed', msg: "iRacing's list has no Road Atlanta - Full Course" }; };
  window.__req.length = 0; one().click(); await sleep(100);
  ok('3. DRIVE (last car): while busy it says what it is doing and cannot be pressed twice', /Choosing car and track/.test(one().textContent) && one().disabled, one().textContent);
  await sleep(4000);
  const seq = sends().join(' ');
  ok('3. DRIVE (last car): the requests in order: mdpick (his car and track), MY DRIVE until chosen, one more look, mdstart, MY DRIVE until it answers', seq === '/api/do?c=mdpick&a=' + window.__rid + ' /mydrive /mydrive /mydrive /api/do?c=mdstart /mydrive /mydrive', seq);
  ok('3. DRIVE (last car): MY DRIVE\'s failure sentence is on the button', one().textContent.indexOf("iRacing's list has no Road Atlanta - Full Course") > 0 && !one().disabled, one().textContent);
  ok('3. the failure stays 12 s, then the button is DRIVE again', (await sleep(12500), /^Drive/.test(one().textContent) && one().textContent.indexOf('iRacing') < 0), one().textContent);
  await use('rig-on-idle'); window.__mydrive = () => ({ choice: { has: false } }); window.__req.length = 0; one().click(); await sleep(7000);
  ok('3. DRIVE (last car) when MY DRIVE never has it chosen: 24 looks, no mdstart, and the sentence that says what to do', sends().filter(u => u === '/mydrive').length === 24 && sends().indexOf('/api/do?c=mdstart') < 0 && /Couldn't pick that car and track\. Pick it in MY DRIVE\./.test(one().textContent), sends().length + ' / ' + one().textContent);
  window.__mydrive = () => ({ choice: { has: false }, phase: '' });

  // ---------------- 4. the card's ten minutes, the session edge, requests, clean-up ----------------
  await use('rig-on-idle');
  const newRace = r => Object.assign({}, window.__fx.library.races[0], { id: r, startMs: window.__now - 1800000, finish: 6, start: 0, field: 22 });
  window.data.state.rig.driving = true; push(); window.data.state.rig.driving = false; push();
  ok('4. the drive ending is remembered (driving -> not driving at ' + M.localTime(window.__now) + ')', mem().driveEnd === window.__now, JSON.stringify(mem()));
  window.__now += 15 * 60000; window.__fx.library.races.unshift(newRace('late-1')); window.__emit('list:races'); await sleep(200);
  ok('4. a race that reaches the library 15 minutes after the drive still gets its card ("P6 of 22": no grid known)', vis(q('.after')) && txt('.after .s') === 'Your race: P6 of 22', txt('.after'));
  window.__now += 9 * 60000; await sleep(1100);
  ok('4. its ten minutes run from when it appeared (still there 9 minutes later)', vis(q('.after')));
  window.__now += 2 * 60000; await sleep(1100);
  ok('4. and end 10 minutes after it appeared', !vis(q('.after')));
  window.__fx.library.races.unshift(newRace('late-2')); window.__emit('list:races'); await sleep(200);
  window.data.state.rig.driving = true; push(); await sleep(50);
  ok('4. a new drive starting puts the old card away', !vis(q('.after')) && mem().newestAt === 0, JSON.stringify(mem()));
  window.data.state.rig.driving = false; push();
  await use('rig-on-idle');
  window.data.state.rig.sessionOn = true; window.data.state.health.apps.find(a => a.id === 'sim').state = 'live';
  window.data.state.session = { WeekendInfo: { TrackDisplayName: 'Snetterton Circuit', EventType: 'Practice' }, DriverInfo: { DriverCarIdx: '2', Drivers: [{ CarIdx: '2', CarScreenName: 'BMW M4 GT4' }] } };
  push({ rig: true, session: true, health: true }); await sleep(50);
  const t1 = window.__now;
  ok('4. a session loading while HOME is up: NOW "loaded at" that moment, no series (none of his races there), no readout', txt('.now .since').indexOf(M.localTime(t1)) > 0 && !/Cup/.test(txt('.now')) && /Snetterton/.test(txt('.now')) && lastSet().readout === null, txt('.now') + ' ' + JSON.stringify(lastSet()));
  window.__now += 5 * 60000; push({ rig: true, session: true }); await sleep(50);
  ok('4. it stays "loaded at" the first moment', txt('.now .since').indexOf(M.localTime(t1)) > 0, txt('.now .since'));
  await use('rig-on-idle', fx => { fx.state.rig.sessionOn = true; fx.state.session = { WeekendInfo: { TrackDisplayName: 'Road Atlanta', EventType: 'Race' }, DriverInfo: {} }; });
  ok('4. a page opened in the middle of a session does not make up when it was loaded', txt('.now .lbl') === 'Now' && !q('.now .since'), txt('.now'));

  await use('rig-on-idle'); window.__unmount(); window.__req.length = 0; window.__mount(); await sleep(10000);
  const idle = window.__req.slice();
  ok('4. idle for 10 s: ' + idle.length + ' requests (' + (idle.length / 10).toFixed(1) + '/s, budget 2/s): /official, /api/library, /home once each', idle.length <= 20 && idle.slice().sort().join(' ') === '/api/library /home /official', idle.join(' '));
  ok('4. it never asks for the real-world calendar, the phone, the career or the TV pages', !idle.some(u => /realworld|phone|career|watch/.test(u)));
  window.__req.length = 0; window.__emit('list:races'); await sleep(100);
  ok('4. the races list changed (onList): /api/library once', window.__req.join(' ') === '/api/library', window.__req.join(' '));
  window.__req.length = 0; window.data.state.health.apps[0].state = 'down'; push({ health: true }); await sleep(50);
  ok('4. a state push redraws without asking anything (Stream Deck off: its name, "is off", FIX IT)', window.__req.length === 0 && /^Stream Deck is off/.test(txt('.rig .line')) && vis(q('.rig .fix')), txt('.rig .line'));
  window.__unmount();
  const left = Object.keys(window.__ls).filter(k => k !== 'state').reduce((s, k) => s + window.__ls[k].length, 0);
  ok('4. unmount: no listeners left (online, onList; one state watcher stays for the drive edge), the second timer stopped, the clock unmounted', left === 0 && (window.__ls.state || []).length <= 2 && H.tick === 0 && window.__clockCalls().slice(-1)[0][0] === 'unmount', left + ' ' + (window.__ls.state || []).length + ' ' + H.tick);
  window.__req.length = 0; await sleep(3000);
  ok('4. after unmount nothing runs (no requests in 3 s)', window.__req.length === 0);

  out.push('DONE');
  const o = document.getElementById('out'); o.textContent = out.join('\n'); o.hidden = false;
};
</script>
'@
$run = $run.Replace('window.__rid', "'$rid'")

Section '1-4. the page'
$url = Page 't' '' $run
$p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=240000', '--dump-dom', $url)) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt" -Wait
$dom = Get-Content "$tmp\out.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
$m = [regex]::Match([string]$dom, '(?s)<pre id="out"[^>]*>(.*?)</pre>')
$text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$lines = @($text -split [char]10 | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^(ok|FAIL) ' })
$lines | ForEach-Object { '  ' + $_ }
$pass += @($lines | Where-Object { $_ -match '^ok' }).Count; $fail += @($lines | Where-Object { $_ -match '^FAIL' }).Count
if ($text -notmatch 'DONE') { '  FAIL  the page test did not finish'; $fail++; Get-Content "$tmp\err.txt" -ErrorAction SilentlyContinue | Select-Object -Last 5 }

Section '5. source'
function Src($what, $cond) { if ($cond) { $script:pass++; "  ok    5. $what" } else { $script:fail++; "  FAIL  5. $what" } }
$js = [IO.File]::ReadAllText((Join-Path $app 'pages\home.js'))
$ir = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
$ov = [IO.File]::ReadAllText((Join-Path $root 'dash\src\overlays.cs'))
$v2 = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\home.js'))
Src 'home.js is a page module (export default with mount, unmount, onState)' ($js -match 'export default \{' -and $js -match 'mount\(el, ctx\)' -and $js -match 'unmount\(\)' -and $js -match 'onState\(state, changed\)')
Src 'home.js has no real-world block, no phone pairing, no New York clock, no statistics tiles' ($js -notmatch '(?i)realworld|/phone|America/New_York|/career' -and $js -notmatch "'starting'")
Src 'home.js never calls ctx.banner (the shell owns the offline and kids banners)' ($js -notmatch 'banner\(')
Src 'home.js trusts only the server''s "his" flag for his series (not "mine", the car-familiarity flag)' ($js -match 'r\.his' -and $js -notmatch 'r\.mine\b')
Src 'home.js has one timer (the second of the countdown), asks nothing on it and uses only data.json / onList / on / fetch' (([regex]::Matches($js, 'setInterval\(')).Count -eq 1 -and $js -notmatch 'EventSource')
Src 'FIX IT is doctorcheck: Doctor.Run(false), which does not put the old list on screen' ($js.Contains("'doctorcheck'") -and $ov.Contains('case "doctorcheck": Doctor.Run(false)'))
Src 'irdash no longer routes /realworld or starts the real-world fetch; the old HOME (v2) no longer asks for it' (-not $ir.Contains('path == "/realworld"') -and -not $ir.Contains('RealWorld.Init(') -and $v2 -notmatch 'realworld|drawWatch')
Src 'the one button keeps the old HOME''s commands: key rig-on / go / test-drive-last, mdpick, mdstart' ($js.Contains("'rig-on'") -and $js.Contains("'go'") -and $js.Contains("'test-drive-last'") -and $js.Contains("'mdpick'") -and $js.Contains("'mdstart'"))

# ---------------- one picture per state ----------------
Section 'pictures'
foreach ($s in 'rig-off', 'rig-on-idle', 'race-soon', 'session-garage', 'offline', 'kids', 'after-drive', 'after-practice', 'rig-problem') {
  $png = Join-Path $shots "home-$s.png"; Remove-Item $png -ErrorAction SilentlyContinue
  $u = Page "s-$s" $s ''
  $p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=3000', "--screenshot=$png", $u)) -NoNewWindow -PassThru -Wait -RedirectStandardError "$tmp\err-$s.txt" -RedirectStandardOutput "$tmp\so-$s.txt"
  if (Test-Path $png) { $pass++; "  ok    picture: $png" } else { $fail++; "  FAIL  no picture for $s" }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
