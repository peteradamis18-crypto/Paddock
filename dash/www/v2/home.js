'use strict';
// Paddock HOME v3 (docs\design\home-v3\spec.md): the top screen when no session runs. Three bands:
//  A  the one action (gold, the only gold fill), his car (iRacing's own picture, native size), is the rig ready (one word)
//  B  the next race he can enter | his last outing with REVIEW, and this week
//  C  what to watch this weekend, grouped by event, New York time
// ui.js shows and hides #overlay; this only draws while it is shown, so nothing here runs or polls while he drives.
// Every button is one irdash call the deck has too. Words: docs\COPY-RULES.md. Unknown is an em dash, never 0.
const DASH = '—', DOT = ' · ';
const Home = {
  home: null, career: null, health: null, rec: null, phoneInfo: null,
  busyUntil: 0, failUntil: 0, act: null, healthSeq: 0, tickTimer: 0, nextTimer: 0, phoneTimer: 0, clockTimer: 0,
  dry: false, sent: [],      // tests: dry = true records the /api/do calls instead of sending them

  init() {
    this.clock(); this.clockTimer = setInterval(() => this.clock(), 10000);
    this.tick(); this.tickTimer = setInterval(() => this.tick(), 60000);
    // W0-5: the rig's apps and the recorder are pushed by irdash (state parts "health", "recorder"); next() only draws
    data.on('state', (st, ch) => { if (ch.health || ch.recorder) { this.health = st.health || this.health; this.rec = st.recorder || null; this.next(); } });
    this.next(); this.nextTimer = setInterval(() => this.next(), 5000);
    this.phone(); this.phoneTimer = setInterval(() => this.phone(), 30000);
    const b = $('homeNext'); if (b) b.addEventListener('click', () => this.go(b.homeAct));
    HomeHost.init();
  },

  // W2-2: HOME also shows in the garage (the old grid is gone); it hides only while the race screen covers it
  shown() { const ov = $('overlay'); return !!(ov && ov.classList.contains('show')); },

  lap(t) { if (!(t > 0)) return DASH; const m = Math.floor(t / 60), s = t - m * 60; return (m ? m + ':' : '') + (m && s < 10 ? '0' : '') + s.toFixed(3); },
  short(car) { return String(car || '').replace(/^Chevrolet /, ''); },

  // one clock everywhere: New York, 12-hour; the zone named once, on the clock and the race start
  NY: 'America/New_York',
  nyDay(d) { const o = { timeZone: this.NY }; return d.toLocaleDateString('en-US', Object.assign({ weekday: 'short' }, o)) + ' ' + d.toLocaleDateString('en-US', Object.assign({ day: 'numeric' }, o)) + ' ' + d.toLocaleDateString('en-US', Object.assign({ month: 'short' }, o)); },
  nyTime(d) { return d.toLocaleTimeString('en-US', { timeZone: this.NY, hour: 'numeric', minute: '2-digit' }); },
  nyKey(d) { return d.toLocaleDateString('en-CA', { timeZone: this.NY }); },                    // 2026-10-18: sorts and compares as a New York calendar day
  // when a session starts: Today / Tomorrow / 'Sat 24 Oct' (a weekday alone reads as yesterday for a session a week away)
  nyWhen(d) { const k = this.nyKey(d), n = new Date(); return k === this.nyKey(n) ? 'Today' : k === this.nyKey(new Date(n.getTime() + 86400000)) ? 'Tomorrow' : this.nyDay(d); },
  nyDate(d, part) { return d.toLocaleDateString('en-US', { timeZone: this.NY, [part]: part === 'month' ? 'short' : 'numeric' }); },
  clock() { const d = new Date(); setText('idleDate', this.nyDay(d)); setText('idleClock', this.nyTime(d) + ' ET'); },

  async tick() {
    if (document.hidden || !this.shown()) return;
    try { this.home = await (await fetch('/home', { cache: 'no-store' })).json(); } catch (e) { return; }
    try { this.career = await (await fetch('/career', { cache: 'no-store' })).json(); } catch (e) { this.career = null; }
    this.draw();
  },

  draw() {
    const h = this.home; if (!h) return;
    this.drawDriver(h);
    this.drawRace(h);
    this.drawLast(h);
    this.drawReady();
    this.next();
  },

  // ---- band A: who he is (quiet) and his car: iRacing's own picture at its native 480 x 270, never stretched ----
  drawDriver(h) {
    const me = h.me || null, c = this.career || {};
    const lic = c.lic ? 'Licence ' + esc(c.lic) + (c.ir ? DOT + esc(c.ir) + ' iR' : '') : '';
    const path = me && me.path || '';
    let pic = '';
    if (path && window.PCarPic) {
      const known = PCarPic.known();
      if (known === null) { if (!this.picWait) { this.picWait = true; PCarPic.ready().then(() => { this.picWait = false; this.draw(); }); } }
      else if (known[PCarPic.key(path)]) pic = PCarPic.html({ path: path, w: 480, title: me.car || '' });
    }
    const car = $('homeCar');
    const pairing = !!(this.phoneInfo && this.phoneInfo.square);       // the pairing square borrows the car slot until a phone is paired
    if (pairing) { car.className = 'home-car none'; car.hidden = true; }
    else if (pic) { car.className = 'home-car'; car.hidden = false; car.innerHTML = pic; }
    else {
      // no picture for this car: clean type in its place, never a drawing or a stock photo
      car.className = 'home-car none'; car.hidden = false;
      car.innerHTML = me && me.name ? '<div class="big">' + (me.num ? '<i>' + esc(me.num) + '</i>' : '') + esc(me.name) + '</div>' + (lic ? '<div class="sub">' + lic + '</div>' : '') : '';
    }
    const showRow = me && me.name && (pic || pairing);
    setHTML('homeDriver', showRow ? (me.num ? '<span class="num">' + esc(me.num) + '</span>' : '') + '<span class="name">' + esc(me.name) + '</span>' + (lic ? '<span class="lic">' + lic + '</span>' : '') : '');
    if (window.PCarPic) PCarPic.refresh();
  },

  // ---- band A: is everything ready. One word, then only the rows that carry a value or a problem ----
  drawReady() {
    const el = $('idleRig'); if (!el || !this.health) return;
    const apps = {}, chips = [], bad = []; let worst = 'ok';
    ((this.health && this.health.apps) || []).forEach(a => {
      apps[a.id] = a.state;
      if (a.id === 'sim') return;                                       // off is normal between sessions; live shows in the head
      if (a.state === 'ok') chips.push('<i>' + esc(a.name) + '</i>');
      else { chips.push('<i class="off">' + esc(a.name) + ' off</i>'); bad.push(a.name + ' off'); if (worst === 'ok') worst = 'warn'; }
    });
    const rows = [];
    const r = this.rec;
    if (!r) rows.push(['Recording', DASH, 'mute']);
    else {
      const gb = r.freeGb != null ? Math.round(r.freeGb) + ' GB free' : '';
      const st = r.capture && r.capture.state || '';
      if (!r.enabled) rows.push(['Recording', 'Off in settings', 'mute']);
      else if (r.gaveUp || st === 'failed' || st === 'stalled') { rows.push(['Recording', 'Failed' + (gb ? DOT + gb : ''), 'fail']); bad.unshift('Recording failed'); worst = 'fail'; }
      else if (st === 'paused-disk' || (r.freeGb != null && r.minFreeGb != null && r.freeGb < r.minFreeGb)) { rows.push(['Recording', 'Disk low' + (gb ? DOT + gb : ''), 'warn']); bad.push('Disk low'); if (worst === 'ok') worst = 'warn'; }
      else if (st === 'recording') { const s = Math.round(r.capture.secs || 0), mute = r.capture.audio === 'failed'; rows.push(['Recording', 'On ' + Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0') + (mute ? DOT + 'no sound' : '') + (r.freeGb != null ? DOT + Math.round(r.freeGb) + ' GB' : ''), mute ? 'warn' : 'ok']); if (mute) { bad.push('Recording has no sound'); if (worst === 'ok') worst = 'warn'; } }
      else rows.push(['Recording', 'Ready' + (gb ? DOT + gb : ''), '']);
    }
    const p = this.phoneInfo;
    if (!p) rows.push(['Phone', DASH, 'mute']);
    else if (!p.allowed) rows.push(['Phone', 'run tools\\phone-allow.cmd', 'warn']);
    else if (!p.lan) rows.push(['Phone', 'no home network', 'mute']);
    else rows.push(['Phone', p.paired ? 'paired' : 'not paired', p.paired ? '' : 'mute']);
    // the Rig Doctor's one line, when something really needs him (rig.js keeps the last result)
    const doc = typeof Rig !== 'undefined' ? Rig.doc : null;     // const Rig is not window.Rig
    if (doc && doc.ask) { rows.push(['Rig', doc.ask, 'warn']); if (worst === 'ok') { worst = 'warn'; bad.push('Check the rig'); } }
    const live = apps.sim === 'live';
    let head = live ? 'Live' : 'Ready', hc = live ? 'live' : 'ok';
    if (worst !== 'ok' && !live) { head = bad[0] || 'Check the rig'; hc = worst; }
    if (worst === 'fail' && live) { head = bad[0]; hc = 'fail'; }
    setHTML(el, '<div class="head"><span class="dot ' + hc + '"></span><b class="' + (head.length > 9 ? 'w ' : '') + (hc === 'ok' || hc === 'live' ? '' : hc) + '">' + esc(head) + '</b></div>' +
      rows.map(x => '<div class="row"><span class="k">' + x[0] + '</span><span class="v ' + x[2] + '">' + esc(x[1]) + '</span></div>').join('') +
      '<div class="apps">' + chips.join('') + '</div>');
  },

  // ---- band B: the next race he can enter ----
  drawRace(h) {
    const el = $('homeRace'); if (!el) return;
    const r = h.nextRace;
    if (!r) { el.innerHTML = '<div class="lbl">Next race</div><div class="none">No race published</div>'; return; }
    const d = new Date(String(r.localStart || '').replace(' ', 'T'));
    const sec = Math.max(0, Number(r.countdownSeconds || 0));
    const eta = sec < 60 ? 'starting' : sec < 3600 ? 'in ' + Math.floor(sec / 60) + ' min' : 'in ' + Math.floor(sec / 3600) + ' h ' + String(Math.floor(sec % 3600 / 60)).padStart(2, '0');
    const own = (!r.ownedCar && !r.ownedTrack) ? '<small class="no">car and track not owned</small>' : !r.ownedCar ? '<small class="no">car not owned</small>' : !r.ownedTrack ? '<small class="no">track not owned</small>' : '<small>owned</small>';
    el.innerHTML = '<div class="lbl">Next race</div>' +
      '<div class="eta"><b>' + esc(eta) + '</b><span>' + (isNaN(d) ? '' : esc(this.nyTime(d)) + ' ET') + (r.cadence ? DOT + esc(r.cadence) : '') + '</span></div>' +
      '<div class="ser">' + esc(r.series || '') + '</div>' +
      '<div class="ct">' + esc(r.car || DASH) + DOT + esc(r.track || DASH) + own + '</div>';
  },

  // ---- band B: the last outing (with REVIEW) and this week ----
  drawLast(h) {
    const el = $('homeLast'); if (!el) return;
    const l = h.lastOuting || h.last, w = h.week || (this.career && this.career.week);
    let out;
    if (!l) out = '<div class="lbl">Last outing</div><div class="val"><b>' + DASH + '</b></div><div class="det mute">No drive recorded yet</div>';
    else {
      const when = String(l.date || '').slice(0, 10), wd = when ? new Date(when + 'T12:00:00') : null;
      const dt = l.ago || (wd && !isNaN(wd) ? this.nyDay(wd) : '');
      const bits = [l.track, l.type, l.laps ? l.laps + (l.laps === 1 ? ' lap' : ' laps') : ''].filter(Boolean).join(DOT);
      out = '<div class="lbl">Last outing' + (dt ? '<span class="sep">·</span>' + esc(dt) : '') + '</div>' +
        '<div class="val"><b>' + (l.best ? this.lap(l.best) + '<small>best lap</small>' : '<small class="nolap">No timed lap</small>') + '</b>' + (l.file ? '<button type="button" id="homeReview">Review</button>' : '') + '</div>' +
        '<div class="det">' + esc(bits) + '</div><div class="det2">' + esc(this.short(l.car)) + '</div>';
    }
    const n = x => (x == null || isNaN(x)) ? DASH : Math.round(x).toLocaleString('en-US');
    out += '<div class="wk" id="homeWeek"><span class="lbl">This week</span>' + (w
      ? '<b>' + Number(w.hours).toFixed(1) + '<small>h</small></b><b>' + n(w.laps) + '<small>laps</small></b><b>' + n(w.pbs) + '<small>PBs</small></b>' +
        '<span class="lw">last week ' + Number(w.lastHours || 0).toFixed(1) + ' h</span>'
      : '<b>' + DASH + '</b>') + '</div>';
    el.innerHTML = out;
    const rv = $('homeReview'); if (rv) rv.addEventListener('click', () => HomeHost.open('coach.html?id=' + encodeURIComponent(l.file), 'Review' + DOT + (l.track || '')));   // the coach first; all the data is one press away
  },

  // the same id irdeck and irdash give a recent drive (MY DRIVE: FNV-1a of the lower-case "car|track", prefixed r)
  fnv(kind, text) {
    let x = 2166136261; const s = String(text || '').toLowerCase();
    for (let i = 0; i < s.length; i++) { x ^= s.charCodeAt(i); x = Math.imul(x, 16777619) >>> 0; }
    return kind + ('00000000' + (x >>> 0).toString(16)).slice(-8);
  },

  // the one obvious button. It does exactly what it says: LAST DRIVE names the car and track of his last session and
  // starts that car at that track (MY DRIVE: choose it, check it is chosen, then start); with no last session it is START.
  next() {
    if (document.hidden || !this.shown() || !this.health) return;
    const apps = {}; ((this.health && this.health.apps) || []).forEach(a => apps[a.id] = a.state);
    const l = this.home && this.home.last, b = $('homeNext');
    let act;
    if (apps.ui && apps.ui !== 'ok') act = { key: 'rig-on', label: 'Rig on', sub: 'iRacing UI off' };
    else if (apps.sim === 'live') act = { key: 'go', label: 'Get in' };
    else if (l && l.car && l.track) act = { label: 'Last drive', car: l.car, track: l.track, sub: esc(this.short(l.car)) + '<br>' + esc(l.track) };
    else act = { key: 'test-drive-last', label: 'Start' };
    this.act = act;
    b.homeAct = act; // keep the command paired with the label shown on this button
    const busy = Date.now() < this.busyUntil, failed = !busy && Date.now() < this.failUntil;
    b.hidden = false; b.className = 'home-next' + (busy ? ' busy' : failed ? ' failed' : '');
    b.setAttribute('data-car', act.car || ''); b.setAttribute('data-track', act.track || '');
    const sub = busy ? '' : failed ? esc(this.failMsg || 'Could not start') : (act.sub || '');
    setHTML(b, '<div><b>' + (busy ? 'Starting' : esc(act.label)) + '</b>' + (sub ? '<span>' + sub + '</span>' : '') + '</div>' +
      '<svg viewBox="0 0 44 44" aria-hidden="true"><path d="M6 22h31M24 9l13 13-13 13"/></svg>');
    this.drawReady();
  },

  // one irdash call, the same ones the deck makes (dry run in tests: recorded, not sent)
  async send(c, a) {
    this.sent.push({ c: c, a: a || '' });
    if (this.dry) return true;
    try { await fetch('/api/do?c=' + encodeURIComponent(c) + (a ? '&a=' + encodeURIComponent(a) : ''), { cache: 'no-store' }); return true; } catch (e) { return false; }
  },

  async go(pressedAct) {
    const act = pressedAct || this.act;
    if (!act || Date.now() < this.busyUntil) return;
    this.busyUntil = Date.now() + 25000; this.next();
    if (!act.car) { await this.send('key', act.key); return; }
    // LAST DRIVE: choose that exact car and track, make sure MY DRIVE has them chosen, only then start
    const id = this.fnv('r', act.car + '|' + act.track);
    await this.send('mdpick', id);
    let chosen = this.dry;
    for (let i = 0; i < 24 && !chosen; i++) {
      await new Promise(r => setTimeout(r, 250));
      try { const m = await (await fetch('/mydrive', { cache: 'no-store' })).json(); chosen = !!(m.choice && m.choice.has && m.choice.car === act.car && m.choice.track === act.track); } catch (e) { }
    }
    if (!chosen) { this.busyUntil = 0; this.failMsg = "Couldn't pick that car and track. Pick it in MY DRIVE."; this.failUntil = Date.now() + 8000; this.next(); return; }
    // an old "failed" from a few seconds ago must not count as this press's result
    let stale = null;
    if (!this.dry) { try { const m0 = await (await fetch('/mydrive', { cache: 'no-store' })).json(); if (m0.phase === 'failed') stale = m0.msg || ''; } catch (e) { } }
    await this.send('mdstart', '');
    if (this.dry) return;
    // Peter cannot see the log: when START fails, MY DRIVE's own plain-words reason ("iRacing's list has no ...") goes on the button
    let ran = false;
    for (let i = 0; i < 300; i++) {
      await new Promise(r => setTimeout(r, 1000));
      let m; try { m = await (await fetch('/mydrive', { cache: 'no-store' })).json(); } catch (e) { continue; }
      if (m.driving || m.phase === 'joining' && !m.busy) break;
      if (m.busy === 'start' || m.phase === 'setup' || m.phase === 'loading' || m.phase === 'joining') ran = true;
      if (m.phase === 'failed' && m.msg && (ran || m.msg !== stale)) { this.busyUntil = 0; this.failMsg = m.msg; this.failUntil = Date.now() + 12000; this.next(); return; }
      if (ran && !m.busy && m.phase !== 'failed') break;   // finished without a failure
    }
  },

  // the phone: the pairing square only while no phone is paired (it borrows the car slot); otherwise one row in READY
  async phone() {
    if (document.hidden || !this.shown()) return;
    let p; try { p = await (await fetch('/phone/qr', { cache: 'no-store' })).json(); } catch (e) { return; }
    const lan = !!(p.rows && p.rows.length);
    this.phoneInfo = { allowed: !!p.allowed, lan: lan, paired: !!p.paired, square: !!(p.allowed && lan && !p.paired) };
    const el = $('homePhone');
    if (!this.phoneInfo.square) { el.hidden = true; setHTML(el, ''); }
    else {
      el.hidden = false;
      if (!el.querySelector('canvas')) setHTML(el, '<canvas width="240" height="240" aria-label="Pair phone"></canvas><div class="txt"></div>');
      const cv = el.querySelector('canvas'), n = p.size, quiet = 3, scale = Math.floor(240 / (n + quiet * 2)), px = scale * (n + quiet * 2);
      cv.width = px; cv.height = px;
      const g = cv.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, px, px); g.fillStyle = '#000';
      for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (p.rows[y][x] === '1') g.fillRect((x + quiet) * scale, (y + quiet) * scale, scale, scale);
      setHTML(el.querySelector('.txt'), '<div class="lbl">Pair phone</div><b>' + esc(String(p.code || '').replace(/^(\d{3})(\d{3})$/, '$1 $2')) + '</b><span>Scan with the phone camera</span>');
    }
    if (this.home) { this.drawDriver(this.home); this.drawReady(); }
  }
};

// a page over HOME (the Session Review) with a back bar. Never while he drives: it closes the moment the session is live.
const HomeHost = {
  el: null,
  init() {
    setInterval(() => { if (this.el && typeof UI !== 'undefined' && UI.live && UI.live()) this.close(); }, 1500);
    document.addEventListener('keydown', e => { if (e.key === 'Escape' && this.el) { e.preventDefault(); this.close(); } });   // Esc always gets him back to HOME
    window.addEventListener('message', e => { if (e.origin === location.origin && e.data && e.data.irdash === 'coach-close' && this.el) this.close(); });   // Esc inside the coach page
  },
  open(url, title) {
    if (this.el || (typeof UI !== 'undefined' && UI.live && UI.live())) return;
    if (typeof PageHost !== 'undefined') PageHost.closeOthers('home', true);   // one page at a time over the dashboard
    const host = $('homeHost'); host.hidden = false;
    host.innerHTML = '<div class="bar"><button type="button">&lsaquo; Home</button><span>' + esc(title || '') + '</span></div>';
    const f = document.createElement('iframe'); f.src = url; f.title = title || 'page';
    host.appendChild(f);
    host.querySelector('button').addEventListener('click', () => this.close());
    requestAnimationFrame(() => host.classList.add('on'));
    this.el = host;
  },
  close() {
    const host = this.el; this.el = null;
    if (!host) return;
    host.classList.remove('on');
    setTimeout(() => { host.innerHTML = ''; host.hidden = true; }, 500);
  }
};
Home.init();
