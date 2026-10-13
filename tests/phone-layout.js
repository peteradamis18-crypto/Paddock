// Fixtures and measuring code for tests\phone-test.ps1 (section 7, the iPhone app's layout). Evaluated inside the app's page in headless Chrome.
// PhoneApp.mock answers every request from the tables below, so a screen can be drawn with long names, many laps and every state without the PC.
// window.__setScreen(name) draws one screen; window.__check() measures it; window.__controls() presses every control in dry-run.
(function () {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const NOW = Date.now(), DAY = 86400000;
  let mode = 'idle', shareMode = 'none';
  const apps = (ui, sim) => [{ id: 'deck', name: 'Stream Deck', state: 'ok' }, { id: 'ui', name: 'iRacing UI', state: ui }, { id: 'sim', name: 'Sim', state: sim },
    { id: 'cc', name: 'CrewChief', state: 'ok' }, { id: 'overlays', name: 'Overlays', state: 'down' }];
  const base = { t: NOW, connected: false, onTrack: false, driving: false, replay: false, track: '', car: '', session: '', pos: 0, lap: 0, inc: 0, speed: 0, fuel: 0, best: 0, last: 0, pits: false, towWait: false, nav: { to: '', seq: 0, driving: false }, phone: { allowed: true, lan: true, paired: 3 } };
  const states = {
    idle: Object.assign({}, base, { health: { apps: apps('ok', 'off'), events: [] } }),
    off: Object.assign({}, base, { health: { apps: apps('off', 'off'), events: [] } }),
    session: Object.assign({}, base, { connected: true, track: 'Nordschleife Industriefahrten', car: 'Mercedes-AMG GT3 2020 EVO', session: 'Open Qualify', pos: 12, lap: 7, inc: 3, best: 497.123, pits: true, health: { apps: apps('ok', 'live'), events: [] } }),
    driving: Object.assign({}, base, { connected: true, onTrack: true, driving: true, track: 'Circuit de Spa-Francorchamps', car: 'Chevrolet Corvette Z06 GT3.R', session: 'Race', pos: 3, lap: 12, inc: 4, best: 135.549, towWait: true, health: { apps: apps('ok', 'live'), events: [] } })
  };
  states.lost = states.idle;
  const tracks = ['Road Atlanta', 'Nordschleife Industriefahrten', 'Virginia International Raceway', 'Sebring International Raceway', 'Lime Rock Park', 'Circuit de Spa-Francorchamps'];
  const cars = ['Chevrolet Corvette Z06 GT3.R', 'Ferrari 296 GT3', 'BMW M4 G82 GT4 EVO', 'Porsche 911 GT3 R (992)', 'Mercedes-AMG GT3 2020 EVO'];
  const sessions = []; for (let i = 0; i < 26; i++) sessions.push({ file: 's' + i + '.ibt', track: tracks[i % tracks.length], car: cars[i % cars.length], type: ['Practice', 'Open Qualify', 'Race', 'Test Drive'][i % 4], ts: NOW - i * 5 * 3600000, laps: 3 + i, best: 79.549 + i * 0.37 + (i % 3 === 0 ? 60 : 0), pb: i % 5 === 0 });
  const laps = []; for (let i = 1; i <= 24; i++) laps.push({ n: i, time: i === 9 ? 79.549 : 80.3 + (i * 0.173 % 3), valid: i !== 14 && i !== 15, flag: i === 15 ? 'Pit' : '' });
  const detail = { type: 'Open Qualify', track: 'Nordschleife Industriefahrten', config: 'Nordschleife with Tourist loop and long names', car: 'Mercedes-AMG GT3 2020 EVO', startMs: NOW - 5 * 3600000, carNumber: '88', best: { time: 79.549, lap: 9 }, validLaps: 22, consistency: { sd: 0.612 }, prev: { time: 80.114 }, laps: laps,
    notes: [{ label: 'Turn 1 braking', dTime: 0.184, cause: 'Brake released 12 m earlier than the best lap, throttle 0.3 s later' }, { label: 'Corner exit speed, turn 5 and turn 6 combined', dTime: 0.091, cause: 'Minimum speed 4 km/h lower' }, { label: 'Straight', dTime: -0.021, cause: '' }] };
  const order = []; for (let i = 0; i < 14; i++) order.push({ pos: i + 1, name: i === 2 ? 'Peter Example-Surname' : 'Driver Name ' + (i + 1), car: cars[i % cars.length], best: 79.5 + i * 0.21, gap: i === 0 ? '' : i * 1.8, me: i === 2 });
  const bests = []; for (let i = 0; i < 14; i++) bests.push({ best: { time: 82 - i * 0.2 + (i % 4) * 0.3 } });
  const clipList = []; for (let i = 0; i < 9; i++) clipList.push({ id: 'clip' + i, track: tracks[i % tracks.length], car: cars[i % cars.length], lap: 3 + i, lapTime: 79.549 + i * 0.4, created: NOW - i * 7200000, keep: i % 3 === 0 });
  const recent = []; for (let i = 0; i < 8; i++) recent.push({ id: 'r' + ('00000000' + i.toString(16)).slice(-8), car: cars[i % cars.length], carShort: ['CORVETTE GT3', '296 GT3', 'BMW GT4', '911 GT3 R', 'AMG GT3'][i % 5], track: tracks[i % tracks.length], trackShort: ['ROAD ATLANTA', 'Nordschleife Industriefahrten', 'Virginia', 'Sebring', 'LIME ROCK', 'SPA'][i % 6], ago: i < 2 ? 'today' : 'yesterday', chosen: i === 0 });
  const mydrive = () => ({ ready: true, open: true, session: false, driving: mode === 'driving', busy: '', phase: '', msg: '', choice: { has: true, car: 'Chevrolet Corvette Z06 GT3.R', carShort: 'CORVETTE GT3', track: 'Nordschleife Industriefahrten', trackShort: 'Nordschleife', layout: 'Nordschleife Industriefahrten', damage: 'off', fav: false },
    recent: recent, favs: recent.slice(2, 4), results: [{ id: 'f1', name: 'Porsche 911 GT3 R (992)' }, { id: 'f2', name: 'Porsche 911 GT3 Cup (992.2) long name for wrapping' }, { id: 'f3', name: 'Porsche 963 GTP' }], gain: { pb: 79.549, theoretical: 79.211, gap: 0.338, carShort: 'CORVETTE GT3', trackShort: 'ROAD ATLANTA' } });
  const sound = () => ({ ok: true, preset: 'race', items: [{ id: 'sim', name: 'GAME', live: true, vol: 70, mute: false }, { id: 'spotter', name: 'SPOTTER', live: true, vol: 100, mute: false }, { id: 'music', name: 'MUSIC', live: false, vol: 0, mute: false },
    { id: 'speakers', name: 'SPEAKERS', live: true, vol: 12, mute: false }, { id: 'buttkicker', name: 'BUTTKICKER', live: true, vol: 100, mute: true }, { id: 'discord', name: 'DISCORD AND VOICE CHAT', live: true, vol: 45, mute: false }] });
  const overlays = () => ({ preset: 'race', widgets: [{ id: 'relative', name: 'Relative', on: true }, { id: 'standings', name: 'Standings', on: true }, { id: 'fuel', name: 'Fuel calculator', on: false }, { id: 'weather', name: 'Weather', on: false }, { id: 'inputs', name: 'Input trace', on: true }, { id: 'map', name: 'Track map', on: false }], delta: { on: true, ref: 'Session best' } });
  const mockLog = []; window.__mockLog = mockLog;
  function mockFn(url) {
    const p = url.split('?')[0];
    mockLog.push(url);
    switch (p) {
      case '/phone/state': if (mode === 'pair') { PhoneApp.needPair(); throw new Error('pair'); } if (mode === 'lost') throw new Error('net'); return states[mode] || states.idle;
      case '/sound': return sound();
      case '/mydrive': return mydrive();
      case '/overlays': return overlays();
      case '/replay': return { ready: true, driving: mode === 'driving', mode: 'Live' };
      case '/sessions': return { sessions: sessions };
      case '/analysis/session': return detail;
      case '/analysis/race': return { summary: { order: order } };
      case '/analysis/career': return { sessions: bests, pb: { time: 79.549 }, totals: { sessions: 14, laps: 212, seconds: 41000 } };
      case '/vault/list': return { moments: [] };
      case '/vault/recorder': return { clipList: clipList };
      case '/share/status': return shareMode === 'done' ? { state: 'done', size: 89000000, name: 'paddock-lap-79.549-share.mp4' } : shareMode === 'making' ? { state: 'making', pct: 41 } : shareMode === 'error' ? { state: 'error', reason: 'Not while driving' } : { state: 'none' };
      case '/share/make': shareMode = 'making'; return { state: 'queued' };
      case '/phone/devices': return { devices: [{ id: 'd1', name: 'Peter iPhone 15 Pro Max', since: '09 Oct', seen: 'now' }, { id: 'd2', name: 'iPad', since: '10 Oct', seen: '3 h ago' }, { id: 'd3', name: 'Browser', since: '11 Oct', seen: '1 d ago' }] };
      case '/phone/revoke': return { removed: 1 };
    }
    return null;
  }

  async function ready(ms) { await sleep(ms || 450); const A = PhoneApp; for (let i = 0; i < 30 && A.polling; i++) await sleep(50); }
  window.__setScreen = async function (name) {
    const A = PhoneApp;
    A.dry = true; A.sent = []; A.mock = mockFn; shareMode = 'none'; mockLog.length = 0;
    A.detail = null; A.clip = null; A.from = ''; A.phonesOpen = false; A.q = ''; A.touchAt = 0; A.busyUntil = 0; A.again = {}; A.sessions = null; A.sessionsAt = 0; A.clips = null; A.db = null; A.wasConnected = false;
    A.dbCheckedOffline = true;   // D-05: the first offline poll opens the session debrief by itself; a fixture screen must stay where it was put
    document.getElementById('toast').hidden = true;
    if (name === 'pair') { mode = 'pair'; A.paired = 'need'; A.pairErr = 'Wrong code'; A.skelName = ''; A.render(); await ready(200); return name; }
    A.paired = true;
    const home = { 'home-idle': 'idle', 'home-session': 'session', 'home-driving': 'driving', 'home-off': 'off', 'home-lost': 'lost' };
    mode = home[name] || (name === 'drive-keys-driving' ? 'driving' : name === 'setup-driving' ? 'driving' : 'idle');
    A.st = null; A.lost = false; A.polling = false; A.snd = null; A.md = null; A.ov = null; A.rp = null;
    await A.poll();
    if (home[name]) {
      if (name === 'home-session') { A.phonesOpen = true; A.phones = null; }
      A.show('home'); if (A.phonesOpen) await A.loadPhones(); await ready();
      if (name === 'home-lost') { A.polling = false; await A.poll(); }
    } else if (name.indexOf('drive-keys') === 0) { A.driveSeg = 'keys'; A.show('drive'); await ready(); }
    else if (name === 'drive-replay') { A.driveSeg = 'replay'; A.show('drive'); await ready(); }
    else if (name === 'drive-replay-driving') { mode = 'driving'; A.st = null; A.polling = false; await A.poll(); A.driveSeg = 'replay'; A.show('drive'); await ready(); }
    else if (name === 'drive-overlays') { A.driveSeg = 'overlays'; A.show('drive'); await ready(); }
    else if (name === 'sound') { A.show('sound'); await ready(900); }
    else if (name === 'setup' || name === 'setup-driving') { A.q = 'porsche'; A.show('setup'); await ready(900); }
    else if (name === 'laps-sessions') { A.lapSeg = 'sessions'; A.show('laps'); await ready(900); }
    else if (name === 'laps-detail') { A.lapSeg = 'sessions'; A.show('laps'); await ready(700); await A.openDetail('s2.ibt'); await ready(900); }
    else if (name === 'laps-videos') { A.lapSeg = 'videos'; A.show('laps'); await ready(900); }
    else if (name === 'clip' || name === 'clip-done' || name === 'clip-making') {
      A.lapSeg = 'videos'; A.show('laps'); await ready(900); shareMode = name === 'clip-done' ? 'done' : name === 'clip-making' ? 'making' : 'none';
      A.openClip('clip1'); await ready(900);
    }
    return name;
  };
  window.__scrollEnd = async function () { const sc = document.getElementById('scroll'); sc.scrollTop = 1e7; await sleep(150); return sc.scrollTop; };
  window.__scrollTop = async function () { document.getElementById('scroll').scrollTop = 0; await sleep(120); return 0; };

  const R = e => e.getBoundingClientRect();
  const shown = e => { for (let p = e; p && p !== document.documentElement; p = p.parentElement) { const cs = getComputedStyle(p); if (cs.display === 'none' || cs.visibility === 'hidden') return false; if (p.hidden) return false; } const r = R(e); return r.width > 0 && r.height > 0; };
  const label = e => ((e.textContent || '').replace(/\s+/g, ' ').trim() || e.getAttribute('aria-label') || e.id || e.tagName).slice(0, 28);
  const textRects = () => {
    const out = [], w = document.createTreeWalker(document.getElementById('app'), NodeFilter.SHOW_TEXT); let n;
    while ((n = w.nextNode())) {
      const t = n.nodeValue.replace(/\s+/g, ' ').trim(), p = n.parentElement;
      if (!t || !p || /^(SCRIPT|STYLE)$/.test(p.tagName) || !shown(p) || p.closest('video')) continue;
      const rg = document.createRange(); rg.selectNodeContents(n);
      const rs = Array.from(rg.getClientRects()).filter(r => r.width > 0 && r.height > 0);
      if (rs.length) out.push({ n: n, p: p, t: t, rs: rs });
    }
    return out;
  };
  // the nearest ancestor that is a box of its own (not inline): the text must lie inside it
  const boxOf = p => { for (let e = p; e && e.id !== 'app'; e = e.parentElement) { const d = getComputedStyle(e).display; if (d !== 'inline' && d !== 'contents') return e; } return p; };

  window.__check = async function () {
    const vw = innerWidth, vh = innerHeight, sc = document.getElementById('scroll'), strip = document.getElementById('strip'), tabs = document.getElementById('tabs'), dock = document.getElementById('dock'), main = document.getElementById('main');
    const cs = getComputedStyle(document.documentElement), px = v => parseFloat(cs.getPropertyValue(v)) || 0;
    const sat = px('--sat'), sab = px('--sab'), sal = px('--sal'), sar = px('--sar');
    const pairing = document.body.classList.contains('pairing');
    const res = { vw: vw, vh: vh, sat: sat, sab: sab, sal: sal, sar: sar, pairing: pairing, errs: [], texts: [], controls: 0 };
    const err = (k, d) => res.errs.push(k + ': ' + d);
    await window.__scrollTop();
    // 1. nothing scrolls but #scroll
    const se = document.scrollingElement;
    if (se.scrollWidth > vw) err('page scrolls sideways', se.scrollWidth + ' > ' + vw);
    if (se.scrollHeight > vh + 1) err('page scrolls down', se.scrollHeight + ' > ' + vh);
    if (sc.scrollWidth > sc.clientWidth + 1) err('scroll area scrolls sideways', sc.scrollWidth + ' > ' + sc.clientWidth);
    // 2. the shell: strip on top, tab bar at the bottom, the scroll area exactly between them, nothing laid over it
    const rs = R(strip), rt = R(tabs), rc = R(sc), rd = R(dock), dockOn = !dock.hidden && rd.height > 0;
    if (!pairing) {
      if (Math.abs(rs.top) > 0.5) err('strip not at the top', rs.top);
      if (Math.abs(rt.bottom - vh) > 0.5) err('tab bar not at the bottom', rt.bottom + ' vs ' + vh);
      if (rc.top < rs.bottom - 0.5) err('scroll area under the strip', rc.top + ' < ' + rs.bottom);
      const below = dockOn ? rd.top : rt.top;
      if (rc.bottom > below + 0.5) err('scroll area under the dock / tab bar', rc.bottom + ' > ' + below);
      if (dockOn && rd.bottom > rt.top + 0.5) err('dock under the tab bar', rd.bottom + ' > ' + rt.top);
      if (parseFloat(getComputedStyle(strip).paddingTop) < sat - 0.5) err('strip padding is less than the top inset', getComputedStyle(strip).paddingTop + ' vs ' + sat);
      Array.from(tabs.querySelectorAll('button')).forEach(b => { const r = R(b); if (r.bottom > vh - sab + 0.5) err('tab under the home indicator', label(b) + ' ' + r.bottom + ' > ' + (vh - sab)); if (r.left < sal - 0.5 || r.right > vw - sar + 0.5) err('tab outside the side insets', label(b)); });
      if (tabs.querySelectorAll('button').length > 5) err('more than 5 tabs', tabs.querySelectorAll('button').length);
    }
    if (dock.hidden && rd.height > 0) err('hidden dock still takes space', Math.round(rd.height) + ' px');
    if (!pairing && dock.hidden === false && dock.children.length === 0) err('empty dock', 'visible with nothing in it');
    // 3. text: inside its box, inside the screen, inside the side insets, not on top of other text
    const trs = textRects(); const lines = [];
    trs.forEach(x => {
      res.texts.push(x.t);
      const bx = boxOf(x.p), rb = R(bx);
      x.rs.forEach(r => {
        if (r.left < -0.5 || r.right > vw + 0.5) err('text off the screen', x.t.slice(0, 30) + ' ' + Math.round(r.left) + '..' + Math.round(r.right));
        else if (r.left < sal - 0.5 || r.right > vw - sar + 0.5) err('text inside the notch side', x.t.slice(0, 30) + ' ' + Math.round(r.left) + '..' + Math.round(r.right));
        const vt = r.height * 0.25 + 1;   // a glyph box is taller than its line (line-height 1.15): only more than a quarter line out counts as clipped
        if (r.left < rb.left - 1 || r.right > rb.right + 1 || r.top < rb.top - vt || r.bottom > rb.bottom + vt) err('text clipped by its box', x.t.slice(0, 30) + ' text ' + Math.round(r.left) + ',' + Math.round(r.top) + ',' + Math.round(r.right) + ',' + Math.round(r.bottom) + ' box ' + Math.round(rb.left) + ',' + Math.round(rb.top) + ',' + Math.round(rb.right) + ',' + Math.round(rb.bottom));
        let vr = r; if (main.contains(x.p)) { const L = Math.max(r.left, rc.left), T = Math.max(r.top, rc.top), Rr = Math.min(r.right, rc.right), B = Math.min(r.bottom, rc.bottom); vr = (Rr > L && B > T) ? { left: L, top: T, right: Rr, bottom: B } : null; }
        if (vr) lines.push({ p: x.p, t: x.t, r: vr });
      });
      // a word of 5+ letters must not be broken across two lines
      const rx = /[A-Za-z0-9.,:−·']{5,}/g; let wm;
      while ((wm = rx.exec(x.n.nodeValue))) { const wr = document.createRange(); wr.setStart(x.n, wm.index); wr.setEnd(x.n, wm.index + wm[0].length); const tops = new Set(Array.from(wr.getClientRects()).filter(q => q.width > 0).map(q => Math.round(q.top))); if (tops.size > 1) err('word split across lines', wm[0]); }
      if (bx.scrollWidth > bx.clientWidth + 1 && getComputedStyle(bx).display !== 'inline' && bx.clientWidth > 0) err('text wider than its box', x.t.slice(0, 30) + ' ' + bx.scrollWidth + ' > ' + bx.clientWidth);
    });
    let ov = 0;
    for (let i = 0; i < lines.length && ov < 6; i++) for (let j = i + 1; j < lines.length && ov < 6; j++) {
      const a = lines[i], b = lines[j]; if (a.p === b.p) continue;
      const ix = Math.min(a.r.right, b.r.right) - Math.max(a.r.left, b.r.left), iy = Math.min(a.r.bottom, b.r.bottom) - Math.max(a.r.top, b.r.top);
      if (ix > 2 && iy > 2) { ov++; err('text overlaps text', a.t.slice(0, 20) + ' x ' + b.t.slice(0, 20)); }
    }
    // 4. every control: 48 px, on screen sideways, no two overlap
    const ctl = Array.from(document.querySelectorAll('#app button, #app a.btn, #app input')).filter(e => shown(e));
    res.controls = ctl.length;
    ctl.forEach(e => { const r = R(e); if (r.width < 47.5 || r.height < 47.5) err('control under 48 px', label(e) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height)); if (r.left < -0.5 || r.right > vw + 0.5) err('control off the screen', label(e)); });
    const m = ctl.filter(e => main.contains(e));
    for (let i = 0; i < m.length; i++) for (let j = i + 1; j < m.length; j++) { const a = R(m[i]), b = R(m[j]); if (Math.min(a.right, b.right) - Math.max(a.left, b.left) > 2 && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 2) err('controls overlap', label(m[i]) + ' x ' + label(m[j])); }
    // 5. every box inside the screen sideways
    Array.from(document.querySelectorAll('#app *')).filter(e => !e.closest('video') && !e.closest('svg') && shown(e)).forEach(e => { const r = R(e); if (r.right > vw + 0.5 || r.left < -0.5) err('box wider than the screen', e.tagName + '.' + (e.className || '') + ' ' + label(e) + ' ' + Math.round(r.left) + '..' + Math.round(r.right)); });
    // 5b. no box sticks out of the box it sits in (a four-column grid whose last cell pokes through the card's edge)
    Array.from(main.querySelectorAll('*')).filter(e => !e.closest('svg') && !e.closest('video') && shown(e)).forEach(e => {
      const p = e.parentElement; if (!p || p === main || getComputedStyle(p).display === 'inline' || getComputedStyle(e).position === 'absolute') return;
      const rp = R(p), re = R(e); if (re.right > rp.right + 1.5 || re.left < rp.left - 1.5) err('box outside its parent', e.tagName + '.' + (e.className || '') + ' ' + label(e) + ' ' + Math.round(re.left) + '..' + Math.round(re.right) + ' in ' + Math.round(rp.left) + '..' + Math.round(rp.right));
    });
    // 6. the top: the first thing is below the strip; the bottom: scrolled to the end, the last thing is fully above the dock / tab bar
    const kids = Array.from(main.querySelectorAll('*')).filter(e => shown(e) && !e.closest('svg'));
    const first = kids.length ? Math.min.apply(null, kids.map(e => R(e).top)) : rc.top;
    if (first < rc.top - 0.5) err('first element above the scroll area', first + ' < ' + rc.top);
    res.firstGap = Math.round(first - rs.bottom);
    const endY = await window.__scrollEnd();
    res.scrollable = endY > 0; res.scrollMax = Math.round(endY);
    const rc2 = R(sc), kids2 = Array.from(main.querySelectorAll('*')).filter(e => shown(e) && !e.closest('svg'));
    const last = kids2.length ? Math.max.apply(null, kids2.map(e => R(e).bottom)) : rc2.top;
    const limit = pairing ? vh : (dockOn ? R(dock).top : R(tabs).top);
    res.lastGap = Math.round((limit - last) * 10) / 10;
    if (last > limit + 0.5) err('last element under the bar', Math.round(last) + ' > ' + Math.round(limit));
    if (last > rc2.bottom + 0.5) err('last element cut off', Math.round(last) + ' > ' + Math.round(rc2.bottom));
    await window.__scrollTop();
    return res;
  };

  // press every enabled control once in dry-run: the exact deck call must be recorded (and nothing else).
  // The list is captured as keys, not as nodes: a control can redraw mid-run (a poll, or picking a drive),
  // so each one is looked up again by its command just before it is pressed.
  window.__controls = async function () {
    const A = PhoneApp, out = [];
    const list = () => Array.from(document.querySelectorAll('#main [data-c], #dock [data-c]')).filter(e => !e.disabled);
    const keyOf = e => (e.dataset.c || '') + '|' + (e.dataset.a || '');
    const keys = list().map(keyOf), seen = {};
    for (const key of keys) {
      const occ = seen[key] || 0; seen[key] = occ + 1;
      const same = list().filter(e => keyOf(e) === key);
      const el = same[occ] || same[0];
      if (!el) continue;
      A.sent = []; A.again = {};
      const c = el.dataset.c, a = el.dataset.a || '', lab = ((el.querySelector('b') || el).textContent || '').trim();
      el.click(); await sleep(25);
      const exp = '/api/do?c=' + encodeURIComponent(c) + (a ? '&a=' + encodeURIComponent(a) : '');
      out.push({ c: c, a: a, label: lab, x2: !!el.dataset.x2, after: ((el.querySelector('b') || el).textContent || '').trim(), n: A.sent.length, ok: A.sent.length === 1 && A.sent[0] === exp, got: A.sent.join(' ') });
    }
    return out;
  };
  // behaviour that a layout check cannot see: going in and out of a page, what a redraw must leave alone
  window.__flows = async function () {
    const A = PhoneApp, r = {}, $ = s => document.querySelector(s), $$ = s => Array.from(document.querySelectorAll(s)), sc = document.getElementById('scroll');
    try {
    // laps: open a session, Back (button), the swipe-back (history), and the Laps tab pressed again
    await window.__setScreen('laps-sessions'); sc.scrollTop = 240; await sleep(120); const y0 = sc.scrollTop;
    const sessionPicks = $$('#main [data-pick]');
    if (!sessionPicks.length) { r.detailOpens = false; return r; }
    sessionPicks[Math.min(4, sessionPicks.length - 1)].click(); await sleep(900);
    r.detailOpens = !!A.detail && !!$('[data-back]') && !!$('.lap') && !!(history.state && history.state.d);
    r.detailTop = sc.scrollTop === 0;
    const firstBack = $('[data-back]'); if (!firstBack) { r.missingBack = true; return r; } firstBack.click(); await sleep(500);
    r.backList = !A.detail && !!$('#main [data-pick]') && Math.abs(sc.scrollTop - y0) <= 2;
    const backPicks = $$('#main [data-pick]');
    if (backPicks.length) backPicks[Math.min(1, backPicks.length - 1)].click(); await sleep(700); history.back(); await sleep(500);
    r.swipeBack = !A.detail && !!$('#main [data-pick]');
    const tabPicks = $$('#main [data-pick]');
    if (tabPicks.length) tabPicks[Math.min(1, tabPicks.length - 1)].click(); await sleep(700); $('[data-nav=laps]').click(); await sleep(400);
    r.tabAgain = !A.detail && !!$('#main [data-pick]');
    // home: Last session opens the session, Back returns to Home (not to the Laps list)
    await window.__setScreen('home-idle'); await sleep(500);
    const last = $('#main .row[data-pick]'); r.lastRow = !!last;
    if (last) { last.click(); await sleep(700); const homeBack = $('[data-back]'); r.lastOpens = A.page === 'laps' && !!A.detail && homeBack && homeBack.textContent.trim() === 'Home'; if (homeBack) { homeBack.click(); await sleep(500); r.lastBack = A.page === 'home' && !A.detail; } }
    // phones: Forget asks again first, the second press does it
    await window.__setScreen('home-session'); await sleep(300);
    const fg = $('[data-forget]'); if (!fg) { r.missingForget = true; return r; } mockLog.length = 0; fg.click(); await sleep(80);
    r.forgetArms = fg.classList.contains('again') && fg.querySelector('em').textContent.trim() === 'Again?' && !mockLog.some(u => u.indexOf('/phone/revoke') === 0);
    await sleep(800); fg.click(); await sleep(200);
    r.forgetDoes = mockLog.some(u => u.indexOf('/phone/revoke?id=d1') === 0);
    // setup: the fragment filters on the phone itself - a redraw keeps the box, its text and focus, typing sends nothing, a tap picks
    await window.__setScreen('setup'); await sleep(300);
    const inp = $('#findText'); inp.focus(); A.sent = []; inp.value = 'cor'; inp.dispatchEvent(new Event('input', { bubbles: true })); A.render(); await sleep(80);
    r.searchKept = $('#findText') === inp && document.activeElement === inp && inp.value === 'cor' && $$('#uFound .row').length > 0;
    r.searchLocal = A.sent.length === 0;
    const row = $('#uFound .row'); A.sent = []; if (row) row.click(); await sleep(50);
    r.searchPicks = A.sent.length === 1 && A.sent[0].indexOf('/api/do?c=mdpick&a=') === 0;
    // an unchanged poll replaces nothing; a changed one waits while a finger is down
    await window.__setScreen('home-driving'); await sleep(300);
    const dockBtn = $('#dock .big'), tile = $('#hBody .tile'); await A.poll(); await sleep(100);
    r.noRepaint = $('#dock .big') === dockBtn && $('#hBody .tile') === tile;
    await window.__setScreen('sound'); await sleep(300);
    const before = $('.snd .nm span').textContent; const alt = JSON.parse(JSON.stringify(A.snd)); alt.items[0].vol = 30; A.snd = alt;
    A.touchAt = Date.now(); A.render(); await sleep(60); const heldBack = $('.snd .nm span').textContent === before;
    document.dispatchEvent(new Event('touchend')); await sleep(60);
    r.fingerHolds = heldBack && $('.snd .nm span').textContent === '30 %';
    // the scroll position survives a redraw
    await window.__setScreen('setup'); await sleep(300); sc.scrollTop = 200; await sleep(80); const y1 = sc.scrollTop;
    A.md.recent = A.md.recent.slice(1); await A.poll(); await sleep(100); r.scrollKept = Math.abs(sc.scrollTop - y1) <= 2 && y1 > 0;
    // drive: the three parts, replay dim while driving
    await window.__setScreen('drive-keys'); r.driveSegs = $$('.seg button').length === 3;
    $('[data-seg=replay]').click(); await sleep(400); r.replayShown = $$('#main [data-c^=rp]').length === 18 && $$('#main [data-c^=rp]').every(b => !b.disabled);
    $('[data-seg=overlays]').click(); await sleep(400); r.overlaysShown = $$('#main [data-c=ovpreset]').length === 5 && $$('#main [data-c=ovtoggle]').length >= 4;
    await window.__setScreen('drive-replay-driving'); r.replayDim = $$('#main [data-c^=rp]').length === 18 && $$('#main [data-c^=rp]').every(b => b.disabled) && /Get out of the car first/.test($('#main').textContent);
    await window.__setScreen('drive-keys-driving'); r.drivingKeys = !$('#main [data-a=rig-on]') && !$('#main [data-a=lock]') && !!$('#main [data-a=tow]');
    // clip: the share button asks the PC, the card follows its answer
    await window.__setScreen('clip'); const mk = $('#shareBox [data-share-make]'); mockLog.length = 0; mk.click(); await sleep(400);
    r.shareAsks = mockLog.some(u => u.indexOf('/share/make?id=clip1') === 0) && /In line|Making/.test($('#shareBox').textContent);
    // a message appears above the dock and the tab bar, inside the screen, and goes away
    await window.__setScreen('setup'); await sleep(300); A.toast('Saved to Files'); await sleep(60);
    const tr = $('#toast').getBoundingClientRect(), sr = sc.getBoundingClientRect();
    r.toastFits = tr.height > 0 && tr.left >= 0 && tr.right <= innerWidth && tr.bottom <= sr.bottom + 0.5 && tr.top >= sr.top;
    A.toast('Not now', true); await sleep(60); r.toastBad = $('#toast').classList.contains('bad') && !$('#toast').hidden;
    // the tabs: five, each opens its page, the pressed one is marked
    const names = []; for (const n of ['home', 'drive', 'sound', 'setup', 'laps']) { $('[data-nav=' + n + ']').click(); await sleep(250); names.push(A.page === n && $('[data-nav=' + n + ']').classList.contains('on') && $$('#tabs .on').length === 1); }
    r.tabs = names.every(x => x) && $$('#tabs button').length === 5;
    // an x2 key arms, shows Again?, the bar runs, the second press sends, and it disarms after 3 s
    await window.__setScreen('drive-keys'); const q = $('[data-a=quit-main]'); A.sent = []; q.click(); await sleep(60);
    r.x2Arms = q.classList.contains('again') && q.querySelector('b').textContent === 'Again?' && A.sent.length === 1;
    await sleep(3200); r.x2Disarms = !q.classList.contains('again') && q.querySelector('b').textContent === 'Quit';
    return r;
    } catch (e) { r.error = e && e.stack ? e.stack : String(e); return r; }
  };
  window.__mock = { fn: mockFn, setMode: m => { mode = m; }, setShare: s => { shareMode = s; }, log: mockLog, sessions: sessions };
})();
