'use strict';
// Paddock on the iPhone. Five tabs, one fixed shell (index.html): status strip, ONE scroll area (#scroll), the page's main button (#dock), tab bar.
// Every rig action is the same irdash call the Stream Deck makes (/api/do, phone.cs for the MAIN/MORE keys: c=key&a=<key name> runs keys\<name>.exe),
// so the phone can never do what the deck cannot, and while he is in the car it offers only what the deck offers then.
// State is a 2 s poll of /phone/state while the page is visible. Pages are drawn in parts (part / setDock): a poll replaces a part only when its
// text changed and never while a finger is down, so the button under his thumb, the search box and the scroll position stay put.
// Pairing: a token from /phone/pair (scanned code from the top screen), kept in localStorage and a cookie, sent as X-Paddock-Token.
// Tests (tests\phone-test.ps1): PhoneApp.dry = true records commands instead of sending; PhoneApp.mock = function (url) answers every request
// from the test (undefined = go to the PC, null = 404); ?asphone=1 makes irdash treat this PC as a phone.
const PhoneApp = {
  tok: null, asPhone: false, dry: false, mock: null, sent: [], page: 'home', st: null, lost: false, snd: null, md: null, ov: null, rp: null,
  sessions: null, detail: null, clips: null, clip: null, busyUntil: 0, again: {}, timer: null, paired: false, pairErr: '', devId: '', autoId: '',
  lapSeg: 'sessions', driveSeg: 'keys', q: '', touchAt: 0, later: false, skelName: '', phones: null, phonesOpen: false, listY: 0, polling: false,
  db: null, wasConnected: false, dbWaitUntil: 0,

  // ---------- the deck's MAIN / MORE keys: group, key name (keys\keys.map), label, small line, tone, x2 ----------
  KEYS: [
    ['car', 'rig-on', 'Rig on', '', 'go'],
    ['car', 'test-drive', 'Test drive', '', 'go'],
    ['car', 'smart', 'Get in', '', 'go'],
    ['ses', 'get-out', 'Get out', ''],
    ['ses', 'tow', 'Reset car', ''],
    ['ses', 'keep-lap', 'Keep lap', ''],
    ['ses', 'tv', 'TV', ''],
    ['ses', 'reset-save', 'Mark spot', ''],
    ['ses', 'reset-run', 'Back to spot', ''],
    ['ses', 'restart-race', 'Restart', '', 'stop', 1],
    ['ses', 'skip-session', 'Skip', '', 'stop', 1],
    ['ses', 'quit-main', 'Quit', '', 'stop', 1],
    ['pit', 'fuel-finish', 'Fuel', 'to finish'],
    ['pit', 'pit-tires', 'Tires', ''],
    ['pit', 'pit-clear', 'Clear', ''],
    ['pit', 'pit-fr', 'Repair', ''],
    ['pit', 'pit-ws', 'Wipe', ''],
    ['pit', 'seat-down', 'Seat down', ''],
    ['pit', 'seat-up', 'Seat up', ''],
    ['talk', 'say-sorry', 'Sorry', ''],
    ['talk', 'say-thanks', 'Thanks', ''],
    ['talk', 'say-gg', 'Good race', ''],
    ['vol', 'vol-down', 'Game −', ''],
    ['vol', 'vol-up', 'Game +', ''],
    ['vol', 'mute', 'Mute PC', ''],
    ['box', 'bb-f3', 'Relative', 'F3'],
    ['box', 'bb-f1', 'Timing', 'F1'],
    ['box', 'bb-f2', 'Standings', 'F2'],
    ['box', 'bb-f4', 'Fuel', 'F4'],
    ['box', 'bb-f5', 'Tires', 'F5'],
    ['box', 'bb-f8', 'In-car', 'F8'],
    ['box', 'bb-f11', 'Weather', 'F11'],
    ['pc', 'showcase', 'Showcase', ''],
    ['pc', 'sleep', 'Sleep PC', '', 'stop', 1],
    ['pc', 'lock', 'Lock PC', '', 'stop', 1]
  ],
  GROUPS: { car: 'Start', ses: 'Session', pit: 'Pit', talk: 'Race chat', vol: 'Volume', box: 'Black box', pc: 'PC' },
  GROUP_ORDER: ['car', 'ses', 'pit', 'talk', 'vol', 'box', 'pc'],
  // the REPLAY deck screen (replay.cs), six keys a row of two lines; dim while he drives, as the deck does
  REPLAY: [
    ['Play', [['rpplay', 'Play / pause'], ['rpback10', '−10 s'], ['rprew', 'Rewind'], ['rpfast', 'Forward'], ['rpslow', 'Slow motion'], ['rplive', 'Live']]],
    ['Jump', [['rplapprev', 'Lap ‹'], ['rplapnext', 'Lap ›'], ['rpincprev', 'Incident ‹'], ['rpincnext', 'Incident ›'], ['rpmyinc', 'My last incident'], ['rpphoto', 'Photo']]],
    ['Camera', [['rpmycar', 'My car'], ['rpahead', 'Car ahead'], ['rpbehind', 'Car behind'], ['rpleader', 'Leader'], ['rpcamnext', 'Next camera'], ['rphideui', 'Hide menus']]]
  ],
  PRESETS: ['race', 'practice', 'quali', 'minimal', 'friends'],
  SND_PRESETS: [['race', 'Race'], ['cruise', 'Cruise'], ['night', 'Night']],
  ICON_NEXT: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9.5 5.5L16 12l-6.5 6.5"/></svg>',
  ICON_BACK: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14.5 5.5L8 12l6.5 6.5"/></svg>',

  // ---------- start ----------
  async init() {
    const q = new URLSearchParams(location.search), $ = id => document.getElementById(id);
    this.asPhone = q.get('asphone') === '1';
    try { this.tok = localStorage.getItem('pt'); } catch (e) { }
    if (q.get('t')) this.keep(q.get('t'));
    $('tabs').addEventListener('click', e => { const b = e.target.closest('[data-nav]'); if (b) this.tab(b.dataset.nav); });
    $('main').addEventListener('click', e => this.tap(e));
    $('dock').addEventListener('click', e => this.tap(e));
    $('main').addEventListener('input', e => { if (e.target.id === 'findText') { this.q = e.target.value; this.autoId = ''; this.renderFound(); } });
    // a touch handler on the page is what makes iOS show :active at all; the same handlers tell the app a finger is down (no repaint then)
    document.addEventListener('touchstart', () => { this.touchAt = Date.now(); }, { passive: true });
    const up = () => { this.touchAt = 0; if (this.later) { this.later = false; this.render(); } };
    document.addEventListener('touchend', up, { passive: true }); document.addEventListener('touchcancel', up, { passive: true });
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') this.poll(); });
    window.addEventListener('popstate', () => this.closeDetail());
    this.fitKeyboard();
    if (q.get('pair')) { await this.pair(q.get('pair')); }
    this.show(this.page);
    this.poll(); setInterval(() => this.poll(), 2000);
  },
  touching() { return this.touchAt > 0 && Date.now() - this.touchAt < 3000; },

  // the on-screen keyboard shrinks the visible area but not the page: the shell follows the visible area so the strip and the field stay in view
  fitKeyboard() {
    const vv = window.visualViewport, app = document.getElementById('app'); if (!vv || !app) return;
    const fit = () => {
      const kb = vv.scale < 1.02 && window.innerHeight - vv.height > 120;
      if (kb) { app.style.height = vv.height + 'px'; app.style.bottom = 'auto'; app.style.transform = 'translateY(' + vv.offsetTop + 'px)'; }
      else { app.style.height = ''; app.style.bottom = ''; app.style.transform = ''; }
    };
    vv.addEventListener('resize', fit); vv.addEventListener('scroll', fit);
  },

  keep(t) {
    this.tok = t;
    try { localStorage.setItem('pt', t); } catch (e) { }
    try { document.cookie = 'pt=' + t + '; path=/; max-age=31536000; SameSite=Lax'; } catch (e) { }
    // the home-screen app has its own storage, so the saved address carries the token (home Wi-Fi only, paired phones only)
    try { history.replaceState(null, '', '/phone/?t=' + t + (this.asPhone ? '&asphone=1' : '')); } catch (e) { }
  },

  async api(url) {
    const u = url + (this.asPhone ? (url.indexOf('?') >= 0 ? '&' : '?') + 'asphone=1' : '');
    if (this.mock) {
      const v = this.mock(url);
      if (v !== undefined) return { ok: v !== null, status: v === null ? 404 : 200, json: async () => v, blob: async () => new Blob(['x']) };
    }
    const h = {}; if (this.tok) h['X-Paddock-Token'] = this.tok;
    const r = await fetch(u, { cache: 'no-store', headers: h });
    if (r.status === 401) { this.needPair(); throw new Error('pair'); }
    return r;
  },
  async json(url) { return (await this.api(url)).json(); },

  needPair() { if (this.paired !== 'need') { this.paired = 'need'; this.skelName = ''; this.render(); } },

  async pair(code) {
    this.pairErr = '';
    try {
      const u = '/phone/pair?code=' + encodeURIComponent(code) + (this.asPhone ? '&asphone=1' : '');
      const r = await fetch(u, { cache: 'no-store' }), j = await r.json();
      if (!r.ok || !j.ok) { this.pairErr = j.why || 'Wrong code'; this.paired = 'need'; this.skelName = ''; this.render(); return false; }
      this.keep(j.token); this.devId = j.id; this.paired = true; this.skelName = ''; this.toast('Paired');
      this.render(); this.poll(); return true;
    } catch (e) { this.pairErr = 'PC not reachable. Join the home Wi-Fi.'; this.paired = 'need'; this.skelName = ''; this.render(); return false; }
  },

  // ---------- the 2 s heartbeat ----------
  async poll() {
    if (document.visibilityState !== 'visible' || this.polling) return;
    this.polling = true;
    try {
      try { this.st = await this.json('/phone/state'); this.lost = false; if (this.paired !== true) { this.paired = true; this.skelName = ''; this.render(); } }
      catch (e) { if (e.message !== 'pair') { this.st = null; this.lost = true; this.paintStrip(); if (this.page === 'home') this.renderHome(); } return; }
      this.paintStrip();
      // D-05: a session just ended (the PC was connected and now is not): show the debrief mirror within 60 s
      const conn = !!(this.st && this.st.connected);
      if (conn) {
        this.dbCheckedOffline = false;
        if (this.db) { this.db = null; if (this.page === 'laps') this.renderLaps(); }
      }
      if (!conn && !this.st.driving && ((this.wasConnected) || !this.dbCheckedOffline)) {
        this.dbCheckedOffline = true; this.startDebrief();
      }
      this.wasConnected = conn;
      const pg = this.page;
      if (pg === 'home') this.renderHome();
      else if (pg === 'drive') await this.drivePoll();
      else if (pg === 'sound') { try { const j = await this.json('/sound'); if (this.page === 'sound' && JSON.stringify(j) !== JSON.stringify(this.snd)) { this.snd = j; this.render(); } } catch (e) { } }
      else if (pg === 'setup') { try { const j = await this.json('/mydrive'); if (this.page === 'setup' && JSON.stringify(j) !== JSON.stringify(this.md)) { this.md = j; this.render(); } } catch (e) { } }
    } finally { this.polling = false; }
  },
  apps() { const a = {}; if (this.st && this.st.health) (this.st.health.apps || []).forEach(x => a[x.id] = x.state); return a; },

  // rig, sim, car: always on screen
  paintStrip() {
    const s = this.st, a = this.apps(), el = document.getElementById('strip');
    const c = (cls, t) => '<div class="c ' + cls + '"><i></i>' + t + '</div>';
    let h;
    if (!s) h = this.lost ? c('bad', 'PC not found') : c('', 'Connecting');
    else h = c(a.ui === 'ok' ? 'ok' : 'warn', a.ui === 'ok' ? 'Rig ready' : 'Rig off') +
      c(a.sim === 'live' ? 'ok' : a.sim === 'stuck' ? 'bad' : '', a.sim === 'live' ? 'Sim live' : a.sim === 'stuck' ? 'Sim stuck' : 'Sim off') +
      c(s.onTrack ? 'gold' : s.connected ? 'ok' : '', s.onTrack ? 'In car' : s.replay ? 'Replay' : s.connected ? 'Session' : 'No session');
    if (el._h !== h) { el._h = h; el.innerHTML = h; }
  },

  // ---------- commands ----------
  async send(c, a, el) {
    const url = '/api/do?c=' + encodeURIComponent(c) + (a != null && a !== '' ? '&a=' + encodeURIComponent(a) : '');
    this.sent.push(url);
    this.flash(el, true);
    if (this.dry) return true;
    try {
      const r = await this.api(url);
      if (!r.ok) { this.flash(el, false); this.toast(this.st && this.st.onTrack ? 'Not while driving' : 'Not now', true); }
      this.after(c);
      return r.ok;
    } catch (e) { if (e.message !== 'pair') { this.flash(el, false); this.toast('PC not reachable', true); } return false; }
  },
  // right after a press: the press shows at once (before the PC answers); a refusal flashes red
  flash(el, ok) { if (!el) return; el.classList.add(ok ? 'fl-ok' : 'fl-no'); setTimeout(() => el.classList.remove('fl-ok', 'fl-no'), 500); },
  after(c) {
    if (/^(ovpreset|ovtoggle|deltaon|deltaref)$/.test(c)) setTimeout(() => this.loadDeck(), 500);
    else if (/^(snd|md)/.test(c)) { this.polling = false; setTimeout(() => this.poll(), 450); }
  },
  toast(msg, bad) {
    const t = document.getElementById('toast'); t.textContent = msg; t.className = bad ? 'bad' : ''; t.hidden = false;
    clearTimeout(this.timer); this.timer = setTimeout(() => t.hidden = true, bad ? 2500 : 3000);
  },
  // the deck's x2: the first press arms it (irdeck beeps twice), the second within 3 s does it. Same two presses here.
  arm(b) {
    const lab = b.querySelector('.arm') || b.querySelector('b'); if (!lab) return;
    b.classList.add('again'); b._old = lab.textContent; lab.textContent = 'Again?';
    clearTimeout(b._t); b._t = setTimeout(() => this.disarm(b), 3000);
  },
  disarm(b) { clearTimeout(b._t); if (!b.classList.contains('again')) return; b.classList.remove('again'); const lab = b.querySelector('.arm') || b.querySelector('b'); if (lab && b._old != null) lab.textContent = b._old; },

  tab(p) {
    if (p !== this.page) { this.show(p); return; }
    if (this.detail || this.clip) { this.from = ''; this.back(); } else document.getElementById('scroll').scrollTop = 0;
  },

  tap(e) {
    const b = e.target.closest('button, a');
    if (!b || b.disabled) return;
    const d = b.dataset;
    if (d.seg) { this.setSeg(d.of, d.seg); return; }
    if (d.pick) { this.openDetail(d.pick); return; }
    if (d.clipId) { this.openClip(d.clipId); return; }
    if (d.back) { this.back(); return; }
    if (d.pairGo) { const inp = document.getElementById('pairCode'); this.pair((inp && inp.value || '').trim()); return; }
    if (d.share) { this.share(d.share, d.name); return; }
    if (d.recsave) { this.recSave(d.recsave, b); return; }
    if (d.db) { this.dbAct(d.db, d.dbid, b); return; }
    if (d.shareMake) { this.makeShare(d.shareMake); return; }
    if (d.shareSend) { this.shareSend(d.shareSend, d.name); return; }
    if (d.phones) { this.togglePhones(); return; }
    if (d.c === 'mdpick' && d.a) { this.pickDrive(d.a, b); return; }
    if (d.forget) {
      const k = 'forget|' + d.forget, t = Date.now(), prev = this.again[k] || 0;
      if (prev && t - prev < 750) return;
      if (!prev || t - prev > 3000) { this.again[k] = t; this.arm(b); return; }
      this.again[k] = 0; this.disarm(b);
      this.json('/phone/revoke?id=' + encodeURIComponent(d.forget)).then(() => { this.toast('Forgotten'); this.loadPhones(); });
      return;
    }
    if (d.find) { const inp = document.getElementById('findText'); const v = (inp && inp.value || '').trim(); if (v) this.send(d.find, v, b); return; }
    if (d.c == null) return;
    const c = d.c, a = d.a || '';
    if (d.x2) {
      const k = c + '|' + a, t = Date.now(), prev = this.again[k] || 0;
      if (prev && t - prev < 750) return;                       // a bounce of the same press
      if (prev && t - prev <= 3000) { this.again[k] = 0; this.disarm(b); this.send(c, a, b); return; }
      this.again[k] = t; this.send(c, a, b); this.arm(b);
      return;
    }
    if (d.busy) { this.busyUntil = Date.now() + 20000; }
    this.send(c, a, b);
    if (d.busy) this.renderHome();
  },

  // ---------- pages ----------
  show(p) {
    if (p === 'clips') { p = 'laps'; this.lapSeg = 'videos'; }       // the old name of the Videos part of Laps
    if (this.page === 'setup' && p !== 'setup') this.send('mdclose', '');
    this.page = p; this.detail = null; this.clip = null; this.from = ''; this.skelName = '';
    clearTimeout(this.shareTimer);
    document.querySelectorAll('#tabs button').forEach(b => { const on = b.dataset.nav === p; b.classList.toggle('on', on); if (on) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current'); });
    document.getElementById('scroll').scrollTop = 0;
    this.render();
    if (p === 'setup') { this.send('mdopen', ''); }   // the top screen shows the My Drive card, as it does for the deck
    if (p === 'sound' || p === 'setup' || p === 'drive') this.poll();
    if (p === 'home') { this.loadSessions(); }
    if (p === 'laps') { this.loadSessions(); if (this.lapSeg === 'videos') this.loadClips(); }
    if (p === 'drive') this.loadDeck();
  },
  setSeg(of, v) {
    if (of === 'drive') { this.driveSeg = v; this.skelName = ''; this.renderDrive(); this.loadDeck(); }
    else if (of === 'laps') { this.lapSeg = v; this.detail = null; this.clip = null; this.skelName = ''; this.render(); if (v === 'videos') this.loadClips(); }
    document.getElementById('scroll').scrollTop = 0;
  },

  render() {
    document.body.classList.toggle('pairing', this.paired === 'need');
    this.drawnOnTrack = undefined;
    if (this.paired === 'need') { this.skel('pair' + this.pairErr, this.pairHtml()); this.setDock(''); return; }
    switch (this.page) {
      case 'home': this.renderHome(); break;
      case 'drive': this.renderDrive(); break;
      case 'sound': this.renderSound(); break;
      case 'setup': this.renderSetup(); break;
      case 'laps': this.renderLaps(); break;
    }
  },

  // ---- drawing helpers ----
  // skel: the page's frame is made once per page (and again when the page changes); part: a piece of it is replaced only when its text changed
  skel(name, html) { if (this.skelName !== name) { this.skelName = name; document.getElementById('main').innerHTML = html; } },
  part(id, html) {
    const el = document.getElementById(id); if (!el || el._h === html) return;
    if (this.touching()) { this.later = true; return; }
    const sc = document.getElementById('scroll'), y = sc.scrollTop;
    el._h = html; el.innerHTML = html; if (sc.scrollTop !== y) sc.scrollTop = y;
  },
  setDock(html) {
    const d = document.getElementById('dock'); if (d._h === html) return;
    if (this.touching()) { this.later = true; return; }
    d._h = html; d.innerHTML = html; d.hidden = !html;
  },
  skeleton(heights) { return heights.map(h => '<div class="sk" style="height:' + h + 'px"></div>').join(''); },
  seg(of, items, cur) { return '<div class="seg" role="group">' + items.map(i => '<button type="button" data-seg="' + i[0] + '" data-of="' + of + '" data-local="1" class="' + (i[0] === cur ? 'on' : '') + '" aria-pressed="' + (i[0] === cur) + '">' + i[1] + '</button>').join('') + '</div>'; },
  // Back sits in the dock, under the thumb (swiping back and pressing the tab again do the same)
  backDock(label) { return '<button type="button" class="big two" data-back="1" data-local="1">' + this.ICON_BACK + '<b>' + label + '</b></button>'; },
  big(c, a, label, o) {
    o = o || {};
    return '<button type="button" class="big' + (o.cls ? ' ' + o.cls : '') + '" data-c="' + c + '"' + (a ? ' data-a="' + a + '"' : '') + (o.busy ? ' data-busy="1"' : '') + (o.off ? ' disabled' : '') + '><b>' + label + '</b>' + (o.next === false ? '' : this.ICON_NEXT) + '</button>';
  },

  pairHtml() {
    return '<div class="pair"><img class="q" src="icon.png" alt=""><h1>Pair this phone</h1><p>Scan the top screen code with Camera, or type the 6 digits.</p>' +
      '<input id="pairCode" inputmode="numeric" pattern="[0-9]*" maxlength="6" placeholder="000000" autocomplete="one-time-code" aria-label="Pairing code">' +
      '<button type="button" class="go" data-pair-go="1" data-local="1">Pair</button>' + (this.pairErr ? '<div class="err">' + this.esc(this.pairErr) + '</div>' : '') + '</div>';
  },

  // ---------- HOME: what the rig is doing, and the one button that fits the moment (the same choice the top screen makes) ----------
  renderHome() {
    if (this.page !== 'home' || this.paired === 'need') return;
    const s = this.st, apps = this.apps();
    this.skel('home', '<div id="hBody"></div>');
    if (!s) {
      this.part('hBody', this.lost ? '<div class="card"><span class="lbl">PC</span><b class="big2">Not found</b><div class="sub">Join the home Wi-Fi</div></div>' : this.skeleton([150, 120]));
      this.setDock(''); return;
    }
    const inCar = !!s.onTrack, sess = !!s.connected, e = x => this.esc(x);
    let act;
    if (inCar) act = ['tow', 'Reset car'];
    else if (sess) act = ['smart', 'Get in'];
    else if (apps.ui && apps.ui !== 'ok') act = ['rig-on', 'Rig on'];
    else act = ['test-drive', 'Test drive'];
    const busy = Date.now() < this.busyUntil;
    let h = '';
    if (sess) {
      h += '<div class="card"><span class="lbl">' + (inCar ? 'In car' : s.replay ? 'Replay' : 'Session') + '</span><b class="big2">' + e(s.track || 'iRacing') + '</b>' +
        '<div class="sub">' + [s.car, s.session, s.pits ? 'Pits' : '', s.towWait ? 'Reset waiting' : ''].filter(Boolean).map(e).join(' · ') + '</div>' +
        '<div class="stats"><div><b>' + (s.pos || '–') + '</b><span>Class pos</span></div><div><b>' + (s.lap || '–') + '</b><span>Lap</span></div><div><b>' + (s.inc == null ? '–' : s.inc) + '</b><span>Incidents</span></div><div><b>' + (s.best > 0 ? this.lap(s.best) : '–') + '</b><span>Best</span></div></div></div>';
    }
    if (inCar) {
      h += '<h2>Pit</h2><div class="grid three">' + this.keyTiles(['fuel-finish', 'pit-tires', 'pit-clear']) + '</div>';
      h += '<h2>Session</h2><div class="grid">' + this.keyTiles(['get-out', 'keep-lap']) + '</div>';
    }
    h += '<div class="card" style="margin-top:' + (inCar ? 24 : 0) + 'px"><span class="lbl">Rig</span><div class="sys">' + (s.health && s.health.apps || []).map(a => '<div class="' + e(a.state) + '"><i></i><b>' + e(a.name) + '</b><em>' + ({ ok: 'On', live: 'Live', off: 'Off', down: 'Down', stuck: 'Stuck' }[a.state] || e(a.state)) + '</em></div>').join('') + '</div></div>';
    const last = !inCar && this.sessions && this.sessions.filter(x => x.laps > 0)[0];
    if (last) h += '<h2>Last session</h2><button type="button" class="row' + (last.pb ? ' pb' : '') + '" data-pick="' + e(last.file) + '" data-local="1"><div><b>' + e(last.track) + '</b><span>' + e(last.car) + ' · ' + e(last.type) + ' · ' + this.when(last.ts) + '</span></div><em>' + (last.best ? this.lap(last.best) : '') + '</em></button>';
    const n = s.phone && s.phone.paired != null ? s.phone.paired : '';
    h += '<h2>Phones</h2><button type="button" class="row" data-phones="1" data-local="1"><div><b>Paired phones</b></div><em>' + (this.phonesOpen ? 'Hide' : n) + '</em></button>';
    if (this.phonesOpen) h += '<div class="list" style="margin-top:8px">' + (this.phones ? this.phones.map(x => '<button type="button" class="row" data-forget="' + e(x.id) + '" data-local="1"><div><b>' + e(x.name) + '</b><span>' + e(x.since) + ' · ' + e(String(x.seen).replace(/^\w+ now$/, 'now')) + '</span></div><em class="arm">Forget</em></button>').join('') : this.skeleton([64])) + '</div>';
    this.part('hBody', h);
    this.setDock(this.big('key', act[0], busy ? 'Starting' : act[1], { cls: busy ? 'busy' : '', busy: !inCar, next: !busy }));
  },
  async togglePhones() { this.phonesOpen = !this.phonesOpen; if (this.phonesOpen) { this.phones = null; this.renderHome(); await this.loadPhones(); } else this.renderHome(); },
  async loadPhones() { try { const d = await this.json('/phone/devices'); this.phones = d.devices || []; } catch (e) { this.phones = []; } if (this.page === 'home') this.renderHome(); },

  key(name) { return this.KEYS.find(k => k[1] === name); },
  keyTiles(names) { return names.map(n => this.tile(this.key(n))).join(''); },
  tile(k) {
    if (!k) return '';
    return '<button type="button" class="tile' + (k[4] ? ' ' + k[4] : '') + '" data-c="key" data-a="' + k[1] + '"' + (k[5] ? ' data-x2="1"' : '') + '><b>' + k[2] + '</b>' + (k[3] ? '<span>' + k[3] + '</span>' : '') + (k[5] ? '<i class="x">×2</i>' : '') + '</button>';
  },

  // ---------- DRIVE: the whole deck, grouped like the deck. What cannot be done now is not there (or dim, like the deck). ----------
  async loadDeck() {
    try { this.ov = await this.json('/overlays'); } catch (e) { }
    try { this.rp = await this.json('/replay'); } catch (e) { }
    if (this.page === 'drive') this.renderDrive();
  },
  async drivePoll() {
    const s = this.st || {};
    if (this.drawnOnTrack !== !!s.onTrack) { this.renderDrive(); return; }
    if (this.driveSeg === 'replay') { try { const j = await this.json('/replay'); if (this.page === 'drive' && JSON.stringify(j) !== JSON.stringify(this.rp)) { this.rp = j; this.renderDrive(); } } catch (e) { } }
    else if (this.driveSeg === 'overlays') { try { const j = await this.json('/overlays'); if (this.page === 'drive' && JSON.stringify(j) !== JSON.stringify(this.ov)) { this.ov = j; this.renderDrive(); } } catch (e) { } }
  },
  renderDrive() {
    if (this.page !== 'drive' || this.paired === 'need') return;
    const onTrack = !!(this.st || {}).onTrack;
    this.drawnOnTrack = onTrack;
    this.skel('drive', '<div id="dSeg"></div><div id="dBody"></div>');
    this.part('dSeg', this.seg('drive', [['keys', 'Keys'], ['replay', 'Replay'], ['overlays', 'Overlays']], this.driveSeg));
    this.part('dBody', this.driveSeg === 'replay' ? this.replayHtml(onTrack) : this.driveSeg === 'overlays' ? this.overlaysHtml() : this.keysHtml(onTrack));
    this.setDock('');
  },
  keysHtml(onTrack) {
    let h = '';
    for (const g of this.GROUP_ORDER) {
      if (onTrack && (g === 'car' || g === 'pc')) continue;
      h += '<h2>' + this.GROUPS[g] + '</h2><div class="grid' + (g === 'vol' ? ' three' : '') + '">' + this.KEYS.filter(k => k[0] === g).map(k => this.tile(k)).join('') + '</div>';
    }
    return h;
  },
  replayHtml(onTrack) {
    const r = this.rp;
    if (!r) return this.skeleton([64, 64, 64, 64]);
    if (!r.ready) return '<div class="empty">Replay not available</div>';
    const dim = !!(r.driving || onTrack);
    let h = dim ? '<div class="card"><b class="big2">Get out of the car first</b></div>' : '';
    this.REPLAY.forEach((grp, i) => {
      h += '<h2>' + grp[0] + (i === 0 && !dim && r.mode ? ' <small>' + this.esc(r.mode) + '</small>' : '') + '</h2><div class="grid three">' +
        grp[1].map(x => '<button type="button" class="tile mid' + (dim ? ' dim' : '') + '" data-c="' + x[0] + '"' + (dim ? ' disabled' : '') + '><b>' + x[1] + '</b></button>').join('') + '</div>';
    });
    return h;
  },
  overlaysHtml() {
    const o = this.ov;
    if (!o) return this.skeleton([64, 64, 64, 64]);
    if (!o.widgets) return '<div class="empty">Overlays not available</div>';
    const on = x => x ? 'On' : 'Off';
    let h = '<h2>Preset</h2><div class="grid three">' + this.PRESETS.map(p => '<button type="button" class="tile mid' + (o.preset === p ? ' on' : '') + '" data-c="ovpreset" data-a="' + p + '"><b>' + p + '</b></button>').join('') + '</div>';
    h += '<h2>Widgets</h2><div class="grid">' + o.widgets.map(w => '<button type="button" class="tile' + (w.on ? ' on' : '') + '" data-c="ovtoggle" data-a="' + this.esc(w.id) + '"><b>' + this.esc(w.name) + '</b><span>' + on(w.on) + '</span></button>').join('') +
      '<button type="button" class="tile' + (o.delta && o.delta.on ? ' on' : '') + '" data-c="deltaon"><b>Delta bar</b><span>' + on(o.delta && o.delta.on) + '</span></button>' +
      '<button type="button" class="tile" data-c="deltaref"><b>VS</b><span>' + this.esc(o.delta && o.delta.ref ? o.delta.ref : 'Next') + '</span></button></div>';
    return h;
  },

  // ---------- SOUND: the SOUND deck screen (sound.cs): each level up / down, mute, the three presets ----------
  renderSound() {
    this.skel('sound', '<div id="sBody"></div>');
    this.part('sBody', this.soundHtml()); this.setDock('');
  },
  soundHtml() {
    const s = this.snd;
    if (!s) return this.skeleton([64, 110, 110, 110, 110]);
    if (!s.ok) return '<div class="empty">Sound not available</div>';
    let h = '<h2>Presets</h2><div class="grid three">' + this.SND_PRESETS.map(p => '<button type="button" class="tile mid' + (s.preset === p[0] ? ' on' : '') + '" data-c="sndpreset" data-a="' + p[0] + '"><b>' + p[1] + '</b></button>').join('') + '</div>';
    h += '<h2>Levels</h2>';
    for (const it of s.items || []) {
      const live = it.live !== false, nm = this.esc(it.name), off = live ? '' : ' disabled';
      h += '<div class="snd' + (it.mute ? ' muted' : '') + '"><div class="nm"><b>' + nm + '</b><span>' + (live ? (it.mute ? 'Muted' : it.vol + ' %') : 'Not playing') + '</span></div>' +
        '<div class="ctl"><button type="button" data-c="sndvol" data-a="' + it.id + ':-10" aria-label="' + nm + ' down"' + off + '>−</button><div class="bar"><i style="width:' + (live ? it.vol : 0) + '%"></i></div>' +
        '<button type="button" data-c="sndvol" data-a="' + it.id + ':+10" aria-label="' + nm + ' up"' + off + '>+</button>' +
        '<button type="button" class="m' + (it.mute ? ' on' : '') + '" data-c="sndmute" data-a="' + it.id + '"' + off + '>Mute</button></div></div>';
    }
    return h;
  },

  // ---------- SETUP: the deck's MY DRIVE (mydrive.cs): recent drives, search a car or a track, damage, START ----------
  renderSetup() {
    const d = this.md;
    if (!d || !d.ready) { this.skel('setup-wait', '<div id="uBody"></div>'); this.part('uBody', this.skeleton([116, 64, 52, 64, 64, 64])); this.setDock(''); return; }
    const wasSearch = document.activeElement && document.activeElement.id === 'findText';
    const searchStart = document.getElementById('findText');
    const searchPos = searchStart ? searchStart.selectionStart : null;
    this.skel('setup', '<div id="uChoice"></div><div id="uOpts"></div><h2>Search</h2>' +
      '<input id="findText" class="field" type="text" maxlength="24" placeholder="Car or track" autocapitalize="characters" autocomplete="off" autocorrect="off" enterkeyhint="search" aria-label="Search" value="' + this.esc(this.q) + '">' +
      '<div id="uFound"></div><div id="uLists"></div>');
    const c = d.choice || {}, e = x => this.esc(x);
    let h = '<div class="card"><span class="lbl">' + (d.phase ? e(d.phase) : 'Drive') + '</span>';
    if (d.msg) h += '<b class="big2">' + e(d.msg) + '</b>';
    else if (c.has) h += '<b class="big2">' + e(c.car) + '</b><div class="sub">' + e(c.track) + (c.layout ? ' · ' + e(c.layout) : '') + '</div>';
    else h += '<b class="big2">Pick a drive</b>';
    if (d.busy) h += '<div class="sub">' + e(d.busy) + '</div>';
    this.part('uChoice', h + '</div>');
    this.part('uOpts', '<div class="opts"><button type="button" class="tile' + (c.damage === 'off' ? '' : ' on') + '" data-c="mddamage"><b>Damage</b><span>' + (c.damage === 'off' ? 'Off' : 'On') + '</span></button>' +
      '<button type="button" class="tile' + (c.fav ? ' on' : '') + '" data-c="mdstar"><b>Favourite</b><span>' + (c.fav ? 'Yes' : 'No') + '</span></button>' +
      '<button type="button" class="tile" data-c="mdclear"><b>Clear</b></button></div>');
    this.renderFound();
    this.renderLists();
    const searchNow = document.getElementById('findText');
    if (searchNow && wasSearch && searchNow !== searchStart) {
      searchNow.focus();
      if (searchPos != null) searchNow.setSelectionRange(searchPos, searchPos);
    }
    this.setDock(d.driving ? this.big('mdgetout', '', 'Get out', { cls: 'two', next: false }) + this.big('mdtow', '', 'Reset car', { cls: 'two', next: false })
      : d.busy ? this.big('mdcancel', '', 'Cancel', { cls: 'stop', next: false })
      : this.big('mdstart', '', 'Start', { off: !this.hasStartableChoice() }));
  },

  // the drives /mydrive offers to start (every one carries a car AND a track, so a picked row can always reach START): all, newest first, then recent, then favourites
  startable(r) { return !!r && /^[rfs][0-9a-f]{8}$/.test(r.id || '') && !!r.car && !!r.track; },
  comboList() {
    const d = this.md; if (!d) return [];
    const seen = {}, out = [];
    const add = r => { if (!this.startable(r) || seen[r.id]) return; seen[r.id] = 1; out.push(r); };
    (d.all || []).forEach(add); (d.recent || []).forEach(add); (d.favs || []).forEach(add);
    return out;
  },
  // START is valid only while the selected pair still has a live /mydrive pick row.
  hasStartableChoice() {
    const c = this.md && this.md.choice;
    if (!c || !c.has || !c.car || !c.track) return false;
    return this.comboList().some(r => r.car.toLowerCase() === c.car.toLowerCase() && r.track.toLowerCase() === c.track.toLowerCase());
  },
  // Show the picked pair at once; clear it again if the PC refuses the command.
  async pickDrive(id, el) {
    const row = this.comboList().find(r => r.id === id);
    if (!row) return false;
    if (!this.md.choice) this.md.choice = {};
    this.md.choice.has = true; this.md.choice.car = row.car; this.md.choice.track = row.track;
    this.md.choice.carShort = row.carShort || row.car; this.md.choice.trackShort = row.trackShort || row.track;
    this.md.choice.layout = row.layout || ''; row.chosen = true;
    this.renderSetup();
    const ok = await this.send('mdpick', id, el);
    if (!ok && this.md) {
      this.md.choice.has = false; this.md.choice.car = ''; this.md.choice.track = '';
      row.chosen = false; this.renderSetup();
    }
    return ok;
  },
  // case-insensitive fragment match on the phone: 0 = the name starts with it, 1 = it is in the name, 2 = its letters appear in order (atl finds Road Atlanta), -1 = no match
  matchRank(name, q) {
    const n = (name || '').toLowerCase(), f = (q || '').toLowerCase();
    if (!f) return -1;
    if (n.indexOf(f) === 0) return 0;
    if (n.indexOf(f) >= 0) return 1;
    let i = 0;
    for (let k = 0; k < n.length && i < f.length; k++) if (n.charAt(k) === f.charAt(i)) i++;
    return i === f.length ? 2 : -1;
  },
  // the matching drives, substring matches before loose ones, /mydrive's own order kept inside a rank; no request is made here
  filterCombos(q) {
    const list = this.comboList(), out = [];
    for (let i = 0; i < list.length; i++) {
      const r = list[i], rank = this.matchRank((r.car || '') + ' · ' + (r.track || ''), q);
      if (rank >= 0) out.push({ r: r, rank: rank, i: i });
    }
    out.sort((a, b) => a.rank - b.rank || a.i - b.i);
    return out.map(x => x.r);
  },
  // the result rows while a fragment is typed; a single match is picked for him, several wait for a tap
  renderFound() {
    const q = (this.q || '').trim(), e = x => this.esc(x);
    if (!q) { this.part('uFound', ''); return; }
    const rows = this.filterCombos(q);
    let h;
    if (rows.length) {
      h = '<div class="list found">' + rows.slice(0, 20).map(r => {
        const t = e(r.carShort || r.car) + ' · ' + e(r.trackShort || r.track), full = e(r.car) + ' · ' + e(r.track);
        return '<button type="button" class="row hit' + (r.chosen ? ' sel' : '') + '" data-c="mdpick" data-a="' + e(r.id) + '"><div><b>' + t + '</b>' + (full !== t ? '<span>' + full + '</span>' : '') + '</div><em>Pick</em></button>';
      }).join('') + '</div>';
    } else h = '<div class="nomatch">No drive matches</div>';
    this.part('uFound', h);
    if (rows.length === 1 && rows[0].id !== this.autoId && !rows[0].chosen) {
      this.autoId = rows[0].id;
      this.pickDrive(rows[0].id, null).then(ok => {
        if (!ok) {
          if (this.md) {
            if (!this.md.choice) this.md.choice = {};
            this.md.choice.has = false; this.md.choice.car = ''; this.md.choice.track = '';
          }
          this.renderSetup();
        }
      });
    }
  },
  renderLists() {
    const d = this.md, e = x => this.esc(x);
    const rows = l => (l || []).map(r => { const t = e(r.carShort || r.car) + ' · ' + e(r.trackShort || r.track), full = e(r.car) + ' · ' + e(r.track);
      return '<button type="button" class="row' + (r.chosen ? ' sel' : '') + '" data-c="mdpick" data-a="' + e(r.id) + '"><div><b>' + t + '</b>' + (full !== t ? '<span>' + full + '</span>' : '') + '</div><em>' + e(r.ago || '') + '</em></button>'; }).join('');
    const favs = (d.favs || []).filter(r => this.startable(r)), recent = (d.recent || []).filter(r => this.startable(r));
    let l = '';
    if (favs.length) l += '<h2>Favourites</h2><div class="list">' + rows(favs) + '</div>';
    if (recent.length) l += '<h2>Recent</h2><div class="list">' + rows(recent) + '</div>';
    if (d.gain && d.gain.pb) l += '<h2>Most to gain</h2><div class="card"><b class="big2">' + e(d.gain.carShort) + ' · ' + e(d.gain.trackShort) + '</b><div class="sub num">PB ' + this.lap(d.gain.pb) + ' · best sectors ' + this.lap(d.gain.theoretical) + ' · ' + d.gain.gap.toFixed(3) + ' s to find</div></div>';
    this.part('uLists', l);
  },

  // ---------- LAPS: Session Review, laps, best lap, race and career numbers, made readable on a phone; and the lap videos ----------
  async loadSessions() {
    if (!this.sessions || Date.now() - this.sessionsAt > 60000) {
      try { this.sessions = (await this.json('/sessions')).sessions || []; this.sessionsAt = Date.now(); } catch (e) { if (!this.sessions) this.sessions = []; this.sessionsAt = 0; }
    }
    if (this.page === 'laps' || this.page === 'home') this.render();
  },
  renderLaps() {
    if (this.detail) { this.skel('laps-detail', '<div id="lBody"></div>'); this.part('lBody', this.detailHtml()); this.setDock(this.backDock(this.from ? 'Home' : 'Sessions')); return; }
    if (this.clip) { this.skel('laps-clip', '<div id="lBody"></div>'); this.part('lBody', this.clipHtml()); this.setDock(this.backDock('Videos')); this.paintShare(); return; }
    if (this.db) { this.skel('laps-debrief', '<div id="lBody"></div>'); this.part('lBody', this.debriefHtml()); this.setDock(this.backDock('Sessions')); return; }
    this.skel('laps', '<div id="lSeg"></div><div id="lBody"></div>');
    this.part('lSeg', this.seg('laps', [['sessions', 'Sessions'], ['videos', 'Videos']], this.lapSeg));
    this.part('lBody', this.lapSeg === 'videos' ? this.clipsHtml() : this.sessionsHtml());
    this.setDock('');
  },

  // ---------- D-05: the debrief mirror. A session just ended: fetch /debrief for the newest session and draw the same
  // numbers the top screen shows (result or pace, corners, incidents) with the same four one-press buttons. It stays
  // up until he closes it or gets back on the PC; the load keeps trying for a minute while the new file is read ----------
  startDebrief() {
    if (this.db) return;
    this.detail = null; this.clip = null; this.from = '';
    this.db = { loading: true }; this.dbWaitUntil = Date.now() + 60000;
    this.enterLaps(); this.skelName = ''; this.render();
    this.loadDebrief();
  },
  async loadDebrief() {
    const d = this.db; if (!d) return;
    try {
      if (!this.sessions || Date.now() - this.sessionsAt > 8000) { this.sessions = (await this.json('/sessions')).sessions || []; this.sessionsAt = Date.now(); }
      const newest = (this.sessions || []).filter(s => s.laps > 0)[0];
      if (newest) {
        const j = await this.json('/debrief?id=' + encodeURIComponent(newest.file));
        if (j && j.ok) {
          d.data = j; d.file = newest.file; d.loading = false;
          try { const v = await this.json('/vault'); d.cw = !!(v && v.cosworth && v.cosworth.installed); } catch (e) { }
          if (this.db === d && this.page === 'laps') this.render();
          return;
        }
      }
    } catch (e) { if (e.message === 'pair') return; }
    if (this.db === d && Date.now() < this.dbWaitUntil) setTimeout(() => this.loadDebrief(), 3000);
    else if (this.db === d && !d.data) { d.loading = false; d.failed = true; if (this.page === 'laps') this.render(); }
  },
  dbRow(k, v, cls) { return '<div class="row static"><div><b>' + this.esc(k) + '</b></div><em class="' + (cls || '') + '">' + this.esc(v) + '</em></div>'; },
  debriefHtml() {
    const d = this.db; if (!d) return '';
    if (d.failed) return '';
    if (d.loading || !d.data) return this.skeleton([120, 260, 200]);
    const j = d.data, m = j.meta || {}, e = x => this.esc(x);
    let h = '<div class="card"><span class="lbl">' + e(String(m.type || 'Session').toUpperCase()) + '</span><b class="big2">' + e(m.trackName || m.track || '') + (m.config ? ' \u00b7 ' + e(m.config) : '') + '</b><div class="sub">' + e(this.when(m.startMs)) + '</div></div>';
    const sgn = (x, dd) => { const s = Math.abs(x).toFixed(dd == null ? 0 : dd); return (parseFloat(s) === 0 ? '' : x > 0 ? '+' : '\u2212') + s; };
    if (j.race && j.result) {
      const r = j.result, rows = [];
      if (r.finishPosition > 0) rows.push(['Finish', 'P' + r.finishPosition + (r.startPosition > 0 ? ' from P' + r.startPosition : '')]);
      if (r.classPosition > 0) rows.push(['Class', 'P' + r.classPosition]);
      if (typeof r.iratingChange === 'number') rows.push(['iRating', sgn(r.iratingChange, 0)]);
      if (typeof r.gapToWinner === 'number') rows.push(['Gap to winner', r.gapToWinner.toFixed(1) + ' s']);
      if (typeof r.incidents === 'number') rows.push(['Incidents', r.incidents + 'x']);
      if (typeof r.cleanLaps === 'number') rows.push(['Clean laps', r.cleanLaps + ' / ' + r.totalLaps]);
      if (rows.length) h += '<div class="card"><span class="lbl">Result</span><div class="list" style="margin-top:6px">' + rows.map(x => this.dbRow(x[0], x[1])).join('') + '</div></div>';
      const positions = (j.positionByLap || []).filter(x => x && x.lap > 0 && x.position > 0);
      if (positions.length) h += '<div class="card"><span class="lbl">Position by lap</span><div class="list" style="margin-top:6px">' + positions.map(x => this.dbRow('Lap ' + x.lap, 'P' + x.position)).join('') + '</div></div>';
    } else if (j.practice) {
      const p = j.practice, rows = [];
      if (typeof p.best === 'number') rows.push(['Best lap', this.lap(p.best)]);
      if (typeof p.pb === 'number') rows.push(['Personal best', this.lap(p.pb)]);
      if (typeof p.optimal === 'number') rows.push(['Optimal', this.lap(p.optimal)]);
      if (typeof p.median === 'number') rows.push(['Median', this.lap(p.median)]);
      if (typeof p.n === 'number') rows.push(['Laps', String(p.n)]);
      if (rows.length) h += '<div class="card"><span class="lbl">Pace</span><div class="list" style="margin-top:6px">' + rows.map(x => this.dbRow(x[0], x[1])).join('') + '</div></div>';
    }
    const p = j.pace;
    if (p) {
      const rows = [];
      if (typeof p.hisBest === 'number') rows.push(['His best', this.lap(p.hisBest)]);
      if (typeof p.classBest === 'number') rows.push(['Class best', this.lap(p.classBest)]);
      if (typeof p.hisMedian === 'number') rows.push(['His median', this.lap(p.hisMedian)]);
      if (typeof p.classMedian === 'number') rows.push(['Field median', this.lap(p.classMedian)]);
      if (typeof p.top5 === 'number') rows.push(['Top 5 %', this.lap(p.top5)]);
      if (rows.length) h += '<div class="card"><span class="lbl">Pace vs field</span><div class="list" style="margin-top:6px">' + rows.map(x => this.dbRow(x[0], x[1])).join('') + '</div></div>';
    }
    const cs = j.corners || [];
    if (cs.length) h += '<div class="card"><span class="lbl">Where the time went</span><div class="list" style="margin-top:6px">' + cs.map(c => this.dbRow(c.label || ('T' + c.n), (typeof c.loss === 'number' ? (c.loss > 0 ? '\u2212' : '+') + Math.abs(c.loss).toFixed(2) + ' s' : ''))).join('') + '</div></div>';
    const inc = (j.incidents || []).filter(r => r.lap > 0);
    if (inc.length) h += '<div class="card"><span class="lbl">Incidents</span><div class="list" style="margin-top:6px">' + inc.map(r => this.dbRow([r.lap ? 'Lap ' + r.lap : '', r.corner, r.type].filter(Boolean).join(' \u00b7 '), '')).join('') + '</div></div>';
    return h + this.debriefBar(j, d);
  },
  debriefBar(j, d) {
    const b = j.bar || {}, dd = b.deepDive || {}, id = j.id || d.file || '', e = x => this.esc(x);
    const canSave = !!b.recId, canShare = !!b.shareId, canCos = !!d.cw && !!dd.id, canDeep = !!dd.id && dd.cornerN > 0;
    const btn = (what, label, on) => on ? '<button type="button" class="btn" data-db="' + what + '" data-dbid="' + e(id) + '" data-local="1">' + label + '</button>' : '';
    const any = canSave || canShare || canCos || canDeep;
    if (!any) return '';
    return '<div class="card"><div class="row2">' + btn('save', b.saved ? 'SAVED' : 'SAVE', canSave) + btn('share', 'SHARE', canShare) + btn('cosworth', 'COSWORTH', canCos) + btn('deepdive', 'DEEP DIVE', canDeep) + '</div></div>';
  },
  async dbAct(what, id, el) {
    const c = { save: 'db-save', share: 'db-share', cosworth: 'db-cosworth', deepdive: 'db-deepdive' }[what];
    if (!c || !id) return;
    const url = '/api/do?c=' + c + '&a=' + encodeURIComponent(id);
    this.sent.push(url);
    this.flash(el, true);
    if (this.dry) return true;
    try {
      const r = await this.api(url);
      if (!r.ok) { this.flash(el, false); this.toast('Not now', true); return false; }
      this.toast({ save: 'Saved', share: 'Queued', cosworth: 'Opening', deepdive: 'On the top screen' }[what] || 'Done');
      return true;
    } catch (e) { if (e.message !== 'pair') { this.flash(el, false); this.toast('PC not reachable', true); } return false; }
  },
  sessionsHtml() {
    if (!this.sessions) return this.skeleton([68, 68, 68, 68, 68, 68]);
    const l = this.sessions.filter(s => s.laps > 0).slice(0, 25), e = x => this.esc(x);
    if (!l.length) return '<div class="empty">No sessions</div>';
    return '<div class="list">' + l.map(s => '<button type="button" class="row' + (s.pb ? ' pb' : '') + '" data-pick="' + e(s.file) + '" data-local="1"><div><b>' + e(s.track) + '</b><span>' + e(s.car) + ' · ' + e(s.type) + ' · ' + this.when(s.ts) + ' · ' + s.laps + ' laps</span></div><em>' + (s.best ? this.lap(s.best) : '') + '</em></button>').join('') + '</div>';
  },
  async openDetail(file) {
    const sc = document.getElementById('scroll');
    this.db = null;
    this.listY = this.detail || this.clip ? this.listY : sc.scrollTop;
    const d = this.detail = { file: file, loading: true };
    this.enterLaps();
    this.skelName = ''; this.render(); sc.scrollTop = 0;
    try { history.pushState({ d: 1 }, ''); } catch (e) { }
    try { d.s = await this.json('/analysis/session?id=' + encodeURIComponent(file)); } catch (e) { d.err = 'Not available'; }
    d.loading = false; if (this.detail === d) this.render();
    try { const r = await this.api('/analysis/race?id=' + encodeURIComponent(file)); if (r.ok) d.race = await r.json(); } catch (e) { }
    try { d.career = await this.json('/analysis/career?id=' + encodeURIComponent(file)); } catch (e) { }
    // the session's recording (S1): irdash names the verified one for this telemetry file (/api/rec/for); none = no button
    try {
      const rf = await this.json('/api/rec/for?id=' + encodeURIComponent(file));
      d.rec = rf && rf.ok && rf.id ? { id: rf.id, saved: !!rf.saved, state: rf.state, saveBlocked: rf.saveBlocked || '' } : null;
    } catch (e) { }
    if (this.detail === d) this.render();
  },
  // a session opened from HOME (Last session) moves to the Laps tab; Back returns to where it came from
  enterLaps() {
    if (this.page !== 'laps') this.from = this.page;
    if (this.page !== 'laps') { this.page = 'laps'; document.querySelectorAll('#tabs button').forEach(b => b.classList.toggle('on', b.dataset.nav === 'laps')); }
  },
  back() { if (this.db) { this.db = null; this.render(); return; } if (history.state && history.state.d) history.back(); else this.closeDetail(); },
  closeDetail() {
    if (!this.detail && !this.clip) return;
    this.detail = null; this.clip = null; clearTimeout(this.shareTimer); this.skelName = '';
    if (this.from) { const f = this.from; this.from = ''; this.show(f); return; }
    this.render();
    document.getElementById('scroll').scrollTop = this.listY || 0;
  },
  detailHtml() {
    const d = this.detail, s = d.s, e = x => this.esc(x);
    let h = '';
    if (d.loading) return h + this.skeleton([190, 300]);
    if (!s) return h + '<div class="empty">' + e(d.err || 'Nothing here') + '</div>';
    h += '<div class="card"><span class="lbl">' + e(s.type || 'Session') + '</span><b class="big2">' + e(s.track) + (s.config ? ' · ' + e(s.config) : '') + '</b><div class="sub">' + e(s.car) + ' · ' + this.when(s.startMs) + (s.carNumber ? ' · #' + e(s.carNumber) : '') + '</div>' +
      '<div class="stats"><div><b>' + (s.best ? this.lap(s.best.time) : '–') + '</b><span>Best</span></div><div><b>' + (s.validLaps || 0) + '</b><span>Valid laps</span></div><div><b>' + (s.consistency && s.consistency.sd != null ? s.consistency.sd.toFixed(2) + ' s' : '–') + '</b><span>Spread</span></div><div><b>' + (s.prev && s.prev.time ? this.lap(s.prev.time) : '–') + '</b><span>PB before</span></div></div></div>';
    const best = s.best ? s.best.time : 0;
    h += '<div class="card"><span class="lbl">Laps</span><div style="margin-top:6px">' + (s.laps || []).map(l => '<div class="lap' + (s.best && l.n === s.best.lap ? ' best' : '') + (l.valid === false ? ' bad' : '') + '"><span class="n">' + l.n + '</span><span class="t">' + this.lap(l.time) + (l.flag || l.valid === false ? '<i>' + e(l.flag || 'Invalid') + '</i>' : '') + '</span><span class="d">' + (best && l.valid !== false && l.time > best ? '+' + (l.time - best).toFixed(3) : '') + '</span></div>').join('') + '</div></div>';
    if (s.notes && s.notes.length) h += '<div class="card"><span class="lbl">Where time went</span><div class="where" style="margin-top:8px">' + s.notes.map(n => '<div><div class="a"><b>' + e(n.label) + '</b><em>' + (n.dTime != null ? (n.dTime > 0 ? '+' : '') + n.dTime.toFixed(3) + ' s' : '') + '</em></div><span>' + e(n.cause || n.fact || '') + '</span></div>').join('') + '</div></div>';
    if (d.rec) h += '<div class="card"><span class="lbl">Recording</span><button type="button" class="btn fill" style="width:100%"' + (d.rec.saved ? ' disabled' : '') + ' data-recsave="' + e(d.rec.id) + '" data-local="1">' + (d.rec.saved ? 'SAVED' : 'SAVE') + '</button></div>';
    if (d.race) h += this.raceHtml(d.race);
    if (d.career) h += this.careerHtml(d.career);
    return h;
  },
  raceHtml(r) {
    const sum = r.summary || r, order = sum.order || sum.final || sum.cars || [], e = x => this.esc(x);
    if (!order.length) return '';
    return '<div class="card"><span class="lbl">Race</span><div class="list order">' + order.slice(0, 12).map((c, i) => '<div class="row static' + (c.me ? ' me' : '') + '"><span class="p">' + (c.pos || i + 1) + '</span><div><b>' + e(c.name || c.driver || '') + '</b><span>' + [e(c.car || ''), c.best ? 'Best ' + this.lap(c.best) : '', c.gap != null && c.gap !== '' ? (typeof c.gap === 'number' ? '+' + c.gap.toFixed(1) + ' s' : e(c.gap)) : ''].filter(Boolean).join(' · ') + '</span></div></div>').join('') + '</div></div>';
  },
  careerHtml(c) {
    if (c.building) return '<div class="card"><span class="lbl">Career</span><b class="big2">Building ' + (c.done || 0) + ' of ' + (c.of || '?') + '</b></div>';
    const ses = c.sessions || [], pb = c.pb || {}, t = c.totals || {};
    const bests = ses.map(x => x.best && x.best.time ? x.best.time : x.best).filter(x => x > 0);
    const mn = Math.min.apply(null, bests), mx = Math.max.apply(null, bests);
    let h = '<div class="card"><span class="lbl">Career</span>' +
      '<div class="stats"><div><b>' + (pb.time ? this.lap(pb.time) : (bests.length ? this.lap(mn) : '–')) + '</b><span>PB</span></div><div><b>' + (t.sessions || ses.length) + '</b><span>Sessions</span></div><div><b>' + (t.laps || '–') + '</b><span>Laps</span></div><div><b>' + (t.seconds ? (t.seconds / 3600).toFixed(1) + ' h' : '–') + '</b><span>Driven</span></div></div>';
    if (bests.length > 1) h += '<div class="bars">' + bests.map(b => '<i class="' + (b === mn ? 'pb' : '') + '" style="height:' + Math.round(20 + 80 * (1 - (b - mn) / Math.max(0.001, mx - mn))) + '%"></i>').join('') + '</div>';
    return h + '</div>';
  },

  // VIDEOS: his lap videos from the Vault (/vault/video with Range, so the player seeks); save = the download, share = the iPhone share sheet
  async loadClips() {
    let list = [];
    try { const v = await this.json('/vault/list'); list = (v.moments || []).filter(m => m.video); } catch (e) { }
    // Paddock's own lap videos (recorder.cs) are not Vault moments: they come from the recorder's clip list
    try { const r = await this.json('/vault/recorder'); (r.clipList || []).forEach(c => list.push({ id: c.id, track: c.track, car: c.car, lap: c.lap, lapTime: c.lapTime, created: c.created, keeper: c.keep || c.pb, rec: true })); } catch (e) { }
    this.clips = list.sort((a, b) => (b.ts || b.created || 0) - (a.ts || a.created || 0));
    if (this.page === 'laps' && !this.clip && !this.detail) this.render();
  },
  clipsHtml() {
    if (!this.clips) return this.skeleton([260, 260]);
    if (!this.clips.length) return '<div class="empty">No lap videos</div>';
    return '<div class="clips">' + this.clips.map(m => '<button type="button" class="clip' + (m.rec ? ' nothumb' : '') + '" data-clip-id="' + this.esc(m.id) + '" data-local="1">' + (m.rec ? '' : '<span class="th" style="background-image:url(' + this.esc('/vault/thumb?id=' + encodeURIComponent(m.id)) + ')"></span>') + '<div class="cap"><b>' + this.esc(m.track || '') + (m.lapTime ? ' · ' + this.lap(m.lapTime) : '') + '</b><span>' + [this.esc(m.car || ''), m.lap ? 'Lap ' + m.lap : '', this.when(m.ts || m.created), m.keeper ? 'Kept' : ''].filter(Boolean).join(' · ') + '</span></div>' + (m.rec ? '<i class="pl"></i>' : '') + '</button>').join('') + '</div>';
  },
  openClip(id) {
    const sc = document.getElementById('scroll');
    this.db = null;
    this.listY = this.detail || this.clip ? this.listY : sc.scrollTop;
    this.clip = (this.clips || []).find(m => m.id === id) || { id: id };
    this.enterLaps();
    this.lapSeg = 'videos'; this.skelName = ''; this.render(); sc.scrollTop = 0;
    try { history.pushState({ d: 1 }, ''); } catch (e) { }
    this.shareStart(id);
  },
  clipHtml() {
    const m = this.clip, src = '/vault/video?id=' + encodeURIComponent(m.id), e = x => this.esc(x);
    const name = ('paddock-' + (m.track || 'lap') + '-' + (m.lapTime ? this.lap(m.lapTime) : m.id)).replace(/[^A-Za-z0-9.-]+/g, '-') + '.mp4';
    return '<div class="player"><video controls playsinline preload="metadata" src="' + e(src) + '"></video></div>' +
      '<div class="card"><b class="big2" style="margin-top:0">' + e(m.track || '') + (m.lapTime ? ' · ' + this.lap(m.lapTime) : '') + '</b><div class="sub">' + [e(m.car || ''), m.lap ? 'Lap ' + m.lap : '', this.when(m.ts || m.created)].filter(Boolean).join(' · ') + '</div></div>' +
      '<div id="shareBox" class="card"></div>' +
      '<div class="card"><span class="lbl">Original</span><div class="row2"><a class="btn" href="' + e(src) + '" download="' + e(name) + '" data-local="1">Save</a>' + (this.canShare() ? '<button type="button" class="btn" data-share="' + e(src) + '" data-name="' + e(name) + '" data-local="1">Share</button>' : '') + '</div></div>';
  },
  // the iPhone share sheet exists only on https (and the PC's own address); on plain http Save is the only way
  canShare() { return !!navigator.canShare; },

  // SHARE VIDEO (P2, dash\src\share.cs): the PC burns speed, gear, pedals, lap time, the gap and a map into a copy of the lap; made when he is out of the car.
  shareStart(id) { this.shareFor = id; this.shareSt = null; this.paintShare(); this.sharePoll(); },
  async sharePoll() {
    clearTimeout(this.shareTimer);
    const id = this.shareFor;
    if (!this.clip || this.clip.id !== id || this.page !== 'laps') return;
    try { this.shareSt = await this.json('/share/status?id=' + encodeURIComponent(id)); } catch (e) { if (e.message === 'pair') return; this.shareSt = { state: 'none' }; }
    this.paintShare();
    const s = this.shareSt && this.shareSt.state;
    this.shareTimer = setTimeout(() => this.sharePoll(), s === 'queued' || s === 'making' || s === 'waiting' ? 1500 : 6000);
  },
  paintShare() {
    const box = document.getElementById('shareBox'); if (!box) return;
    const st = this.shareSt || { state: 'none' }, id = this.shareFor, src = '/share/video?id=' + encodeURIComponent(id), e = x => this.esc(x);
    let h = '<span class="lbl">Share video</span>';
    if (st.state === 'done') {
      const nm = e(st.name || 'paddock-share.mp4');
      h += '<b class="h big2">Ready to share</b><div class="sub num">' + Math.round((st.size || 0) / 1048576) + ' MB</div>' +
        '<div class="row2"><a class="btn fill" href="' + e(src) + '" download="' + nm + '" data-local="1">Save</a>' + (this.canShare() ? '<button type="button" class="btn gold" data-share-send="' + e(src) + '" data-name="' + nm + '" data-local="1">Share</button>' : '') + '</div>';
    } else if (st.state === 'queued' || st.state === 'waiting' || st.state === 'making') {
      const pct = Math.max(0, Math.min(100, st.pct || 0));
      h += '<b class="h big2">' + (st.state === 'making' ? 'Making ' + pct + ' %' : st.state === 'waiting' ? 'Waiting' : 'In line') + '</b><div class="prog"><i style="width:' + pct + '%"></i></div>' + (st.reason ? '<div class="sub">' + e(st.reason) + '</div>' : '');
    } else {
      h += '<b class="h big2">' + (st.state === 'error' ? 'Failed' : 'Not made') + '</b>' + (st.state === 'error' && (st.reason || st.error) ? '<div class="sub">' + e(st.reason || st.error) + '</div>' : '') +
        '<button type="button" class="btn fill" style="width:100%;margin-top:12px" data-share-make="' + e(id) + '" data-local="1">' + (st.state === 'error' ? 'Try again' : 'Make share video') + '</button>';
    }
    if (box.dataset.h !== h) { box.dataset.h = h; box.innerHTML = h; }
  },
  // SAVE keeps this session's recording for good (S1, dash\src\recorder.cs). Words: SAVE, SAVED, SAVED FULL only.
  async recSave(id, el) {
    this.sent.push('/api/rec/save?id=' + id);
    try {
      const h = {}; if (this.tok) h['X-Paddock-Token'] = this.tok;
      const r = await fetch('/api/rec/save?id=' + encodeURIComponent(id) + (this.asPhone ? '&asphone=1' : ''), { method: 'POST', cache: 'no-store', headers: h });
      const x = await r.json(), st = x && x.state;
      if (el) { el.textContent = st === 'SAVED' ? 'SAVED' : st === 'SAVED FULL' ? 'SAVED FULL' : st === 'SAVE FAILED' ? 'SAVE FAILED' : 'SAVE'; if (st === 'SAVED') el.disabled = true; }
      if (this.detail && this.detail.rec && this.detail.rec.id === id) this.detail.rec.saved = st === 'SAVED';
    } catch (e) { if (e.message !== 'pair') this.toast('PC not reachable', true); }
  },
  async makeShare(id) {
    this.sent.push('/share/make?id=' + id);
    let j = null; try { j = await this.json('/share/make?id=' + encodeURIComponent(id)); } catch (e) { if (e.message === 'pair') return; }
    this.shareSt = j && j.state ? j : { state: 'error', reason: (j && j.error) || 'Could not start' };
    this.paintShare(); this.sharePoll();
  },
  async shareSend(src, name) {
    try {
      this.toast('Preparing');
      const b = await (await this.api(src)).blob();
      const f = new File([b], name, { type: 'video/mp4' });
      if (navigator.canShare && navigator.canShare({ files: [f] })) await navigator.share({ files: [f], title: 'Lap' });
      else { const a = document.createElement('a'); a.href = URL.createObjectURL(b); a.download = name; a.click(); this.toast('Saved to Files'); }
    } catch (e) { if (!/abort/i.test(String(e))) this.toast('Share failed', true); }
  },
  async share(src, name) {
    try {
      this.toast('Preparing');
      const b = await (await this.api(src)).blob();
      const f = new File([b], name, { type: 'video/mp4' });
      if (navigator.canShare && navigator.canShare({ files: [f] })) await navigator.share({ files: [f], title: 'Lap' });
      else { const a = document.createElement('a'); a.href = URL.createObjectURL(b); a.download = name; a.click(); this.toast('Saved to Files'); }
    } catch (e) { if (!/abort/i.test(String(e))) this.toast('Share failed', true); }
  },

  // ---------- helpers ----------
  esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); },
  lap(t) { t = Number(t); if (!(t > 0)) return '–'; const m = Math.floor(t / 60), s = t - m * 60; return (m ? m + ':' : '') + (m && s < 10 ? '0' : '') + s.toFixed(3); },
  when(ms) {
    if (!ms) return ''; const d = new Date(Number(ms));
    return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }) + ' ' + d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  },

  // for tests: every command the app can send, and the ones a tap could send on the page as drawn now
  allActions() {
    const out = this.KEYS.map(k => ({ c: 'key', a: k[1], label: k[2] }));
    this.REPLAY.forEach(g => g[1].forEach(x => out.push({ c: x[0], a: '', label: x[1] })));
    this.PRESETS.forEach(p => out.push({ c: 'ovpreset', a: p, label: p }));
    out.push({ c: 'ovtoggle', a: 'relative', label: 'overlay' }, { c: 'deltaon', a: '', label: 'Delta bar' }, { c: 'deltaref', a: '', label: 'VS' });
    this.SND_PRESETS.forEach(p => out.push({ c: 'sndpreset', a: p[0], label: p[1] }));
    out.push({ c: 'sndvol', a: 'sim:+10', label: '+' }, { c: 'sndvol', a: 'sim:-10', label: '-' }, { c: 'sndmute', a: 'sim', label: 'Mute' });
    ['mdopen', 'mdclose', 'mdpick', 'mdstar', 'mddamage', 'mdclear', 'mdstart', 'mdcancel', 'mdgetout', 'mdtow'].forEach(c => out.push({ c: c, a: '', label: c }));
    return out;
  },
  visibleActions() { return Array.from(document.querySelectorAll('#main [data-c], #dock [data-c]')).map(b => ({ c: b.dataset.c, a: b.dataset.a || '', disabled: b.disabled, dim: b.classList.contains('dim') })); }
};
PhoneApp.init();
