'use strict';
// Paddock HOME (DS-1 rebuild): the top screen when no session runs. One picture, his name and number and car, one gold button, one quiet row of facts.
// ui.js shows and hides #overlay; this only draws while it is shown, so nothing here runs or polls while he drives. Every button is one irdash call the deck has too.
// Words: docs\COPY-RULES.md (labels and numbers only).
const Home = {
  home: null, career: null, health: null, realworld: null, busyUntil: 0, failUntil: 0, act: null, healthSeq: 0, tickTimer: 0, nextTimer: 0, phoneTimer: 0,
  dry: false, sent: [],      // tests: dry = true records the /api/do calls instead of sending them

  init() {
    this.ensureScheduleNodes();
    this.tick(); this.tickTimer = setInterval(() => this.tick(), 60000);
    this.next(); this.nextTimer = setInterval(() => this.next(), 5000);
    this.phone(); this.phoneTimer = setInterval(() => this.phone(), 30000);
    const b = $('homeNext'); if (b) b.addEventListener('click', () => this.go(b.homeAct));
    HomeHost.init();
  },

  ensureScheduleNodes() {
    const root = $('overlay'); if (!root || $('homeRace')) return;
    const race = document.createElement('section'); race.id = 'homeRace'; race.className = 'home-race'; root.appendChild(race);
    const weekend = document.createElement('section'); weekend.id = 'homeWeekend'; weekend.className = 'home-weekend'; root.appendChild(weekend);
  },

  shown() { const ov = $('overlay'); return !!(ov && ov.classList.contains('show')) && !(window.UI && UI.live && UI.live()); },

  lap(t) { if (!(t > 0)) return 'â€“'; const m = Math.floor(t / 60), s = t - m * 60; return (m ? m + ':' : '') + (m && s < 10 ? '0' : '') + s.toFixed(3); },
  short(car) { return String(car || '').replace(/^Chevrolet /, ''); },

  async tick() {
    if (document.hidden) return;
    if (!this.shown()) return;
    try { this.home = await (await fetch('/home', { cache: 'no-store' })).json(); } catch (e) { return; }
    try { this.career = await (await fetch('/career', { cache: 'no-store' })).json(); } catch (e) { this.career = null; }
    try { this.realworld = await (await fetch('/realworld', { cache: 'no-store' })).json(); } catch (e) { this.realworld = null; }
    this.draw();
  },

  // where the car stands in the picture, as two boxes: the cabin (from where the picture is opaque enough to be "the car") and the nose, which is lower;
  // the test checks that no text, button or square sits inside them
  carRegion() {
    const r = $('heroImg').getBoundingClientRect(), X = u => r.left + r.width * u, Y = v => r.top + r.height * v;
    return [{ left: X(0.36), right: X(0.70), top: Y(0.34), bottom: Y(0.87) }, { left: X(0.70), right: X(0.86), top: Y(0.50), bottom: Y(0.87) }];
  },

  draw() {
    this.ensureScheduleNodes();
    const h = this.home, c = this.career || {};
    if (!h) return;
    const name = (h.me && h.me.name) || '';
    // the car of his last real session (PL-1) and iRacing's own picture of it (CP-1); no picture for it = text only
    const me = h.me || null;
    // no studio tile here: the hero photo already shows the car, and a bright white tile pulls the eye off the name (lead review)
    let pic = '';
    const path = me && me.path || '';
    if (path && window.PCarPic) {
      const known = PCarPic.known();
      if (known === null) { if (!this.picWait) { this.picWait = true; PCarPic.ready().then(() => { this.picWait = false; this.draw(); }); } }
      // HOME's identity row shares the 920 px column with adjacent cards; 480 px creates a 175 px tile over them.
      else if (known[PCarPic.key(path)]) pic = PCarPic.html({ path: path, w: 144, title: me.car || '' });
    }
    // The driver identity is one YAML row. If it cannot be read, do not fill its gaps from a career aggregate.
    const num = me && me.num || '';
    const car = me && me.car ? this.short(me.car) : '';
    const lic = me ? [c.lic ? 'Licence <i>' + esc(c.lic) + '</i>' : '', c.ir ? '<i>' + esc(c.ir) + '</i> iR' : ''].filter(Boolean).join(' &nbsp;\u00b7&nbsp; ') : '';
    setHTML('homeDriver',
      '<div class="idrow">' + (num ? '<span class="num' + (num.length > 2 ? ' wide' : '') + '">' + esc(num) + '</span><span class="rule"></span>' : '') +
      '<div class="who"><b>' + esc(name) + '</b></div></div>' +
      (car || pic || (me && me.team) ? '<div class="idcar">' + (pic ? '<div class="mycar">' + pic + '</div>' : '') + '<div class="car"><b>' + esc(car) + '</b>' + (me && me.team ? '<span>' + esc(me.team) + '</span>' : '') + (lic ? '<span>' + lic + '</span>' : '') + '</div></div>' : ''));
    if (window.PCarPic) PCarPic.refresh();

    // personal bests: at most three, one per track, newest tracks first
    const pbs = (h.pbs || []).slice(0, 3);
    setHTML('homePbs', pbs.length ? '<label>Personal bests</label><div class="pbs">' + pbs.map(p => {
      const cfg = p.config && !/^(full|full course|grand prix)$/i.test(p.config) && p.track.toLowerCase().indexOf(p.config.toLowerCase()) < 0 ? '<small>' + esc(p.config) + '</small>' : '';
      return '<div class="pb"><span class="tk">' + esc(p.track) + cfg + '</span><b class="t">' + this.lap(p.best) + '</b><span class="cap">' + esc(this.short(p.car)) + '</span></div>';
    }).join('') + '</div>' : '');
    $('homePbs').hidden = !pbs.length;
    $('homePbs').style.setProperty('--n', Math.max(1, pbs.length));

    const n = x => (x == null || isNaN(x)) ? 'â€“' : Math.round(x).toLocaleString('en-GB');
    setHTML('homeCareer', '<label><span>Career</span>' + (c.since ? '<span class="dim">Since ' + esc(c.since) + '</span>' : '') + '</label>' +
      '<div class="cv">' +
      '<div class="w"><b>' + (c.hours != null ? Number(c.hours).toFixed(1) : 'â€“') + '</b><span class="cap">Hours</span></div>' +
      '<div class="w"><b>' + n(c.laps) + '</b><span class="cap">Laps</span></div>' +
      '<div class="w"><b>' + n(c.km) + '</b><span class="cap">Km</span></div>' +
      '<div class="w"><b>' + n(c.races) + '</b><span class="cap">Races</span></div></div>');

    this.drawSchedules(h);

    // THIS WEEK (P0-04): the same numbers /career serves (data.cs week; short runs already left out), Monday 00:00 local
    const w = h.week || c.week;
    const wk = $('homeWeek');
    if (wk) {
      wk.hidden = !w;
      if (w) setHTML(wk, '<label><span>This week</span>' + (w.from ? '<span class="dim">Since ' + esc(w.from) + '</span>' : '') + '</label>' +
        '<div class="cv">' +
        '<div class="w"><b>' + Number(w.hours).toFixed(1) + '</b><span class="cap">Hours</span></div>' +
        '<div class="w"><b>' + n(w.laps) + '</b><span class="cap">Laps</span></div>' +
        '<div class="w"><b>' + n(w.pbs) + '</b><span class="cap">PBs</span></div></div>' +
        '<div class="sub">Last week ' + Number(w.lastHours || 0).toFixed(1) + ' h \u00b7 ' + n(w.lastLaps || 0) + ' laps</div>');
    }

    // LAST OUTING (P0-04): the last real drive (short runs already left out), from /home lastOuting
    const l = h.lastOuting || h.last;
    if (!l) setHTML('homeLast', '');
    else {
      const when = (l.date || '').slice(0, 10), wd = when ? new Date(when + 'T12:00:00') : null;
      const dt = wd && !isNaN(wd) ? wd.getDate() + ' ' + wd.toLocaleDateString('en-GB', { month: 'short' }) : '';
      const bits = [this.short(l.car), l.type ? l.type : '', l.finish ? l.finish : '', l.incidents != null ? l.incidents + 'x inc' : ''].filter(Boolean);
      setHTML('homeLast', '<label><span>Last outing</span>' + (dt ? '<span class="dim">' + esc(dt) + '</span>' : '') + '</label>' +
        '<div class="lv"><span class="tk">' + esc(l.track) + '</span>' +
        '<b class="t">' + (l.best ? this.lap(l.best) : (l.laps ? l.laps + '<small>' + (l.laps === 1 ? 'lap' : 'laps') + '</small>' : 'â€“')) + '</b>' +
        '<span class="cap">' + bits.join(' &nbsp;\u00b7&nbsp; ') + '</span>' +
        (l.file ? '<button class="review" type="button" id="homeReview">Review</button>' : '') + '</div>');
      const r = $('homeReview'); if (r) r.addEventListener('click', () => HomeHost.open('sessionreview.html?id=' + encodeURIComponent(l.file), 'Session review'));
    }

    // the flag lives on the hero itself: ui.js rewrites #overlay's class list at 10 Hz
    const img = $('heroImg'), hero = $('homeHero');
    if (h.hero && h.hero.src) {
      if (img.getAttribute('src') !== h.hero.src) { img.onload = () => hero.classList.add('on'); img.src = h.hero.src; }
      setText('heroCredit', h.hero.kind === 'standin' ? h.hero.credit : '');
    } else { hero.classList.remove('on'); setText('heroCredit', ''); }
    this.next();
  },

  drawSchedules(h) {
    const race = $('homeRace'), weekend = $('homeWeekend'); if (!race || !weekend) return;
    const r = h.nextRace;
    if (!r) race.innerHTML = '<label>Next race</label><div class="home-race-none">Schedule not published</div>';
    else {
      const d = new Date(String(r.localStart || '').replace(' ', 'T'));
      const abs = isNaN(d) ? '' : d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' }) + ' \u00b7 ' + d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
      const sec = Math.max(0, Number(r.countdownSeconds || 0));
      const eta = sec >= 3600 ? Math.floor(sec / 3600) + ' h ' + String(Math.floor(sec % 3600 / 60)).padStart(2, '0') : Math.floor(sec / 60) + ' min';
      const pb = r.pb && Number(r.pb.time) > 0 ? '<div class="home-race-stat"><span>PB</span><b>' + this.lap(r.pb.time) + '</b></div>' : '';
      const median = r.fieldMedian && Number(r.fieldMedian) > 0 ? '<div class="home-race-stat"><span>Field median \u00b7 n=' + esc(r.fieldN) + '</span><b>' + this.lap(r.fieldMedian) + '</b></div>' : '';
      race.innerHTML = '<label>Next race</label><h2>' + esc(r.series || '') + '</h2><p>' + esc(r.car || '') + ' \u00b7 ' + (r.ownedCar ? 'Owned' : 'Not owned') + '</p><p>' + esc(r.track || '') + ' \u00b7 ' + (r.ownedTrack ? 'Owned' : 'Not owned') + '</p><div class="home-race-time">' + esc(abs) + '</div><div class="home-race-count">in ' + esc(eta) + '</div><div class="home-race-cadence">' + esc(r.cadence || '') + '</div>' + pb + median;
    }
    const source = this.realworld && this.realworld.events || [];
    const events = source.filter(e => e.session && e.session.toLowerCase() !== 'event').slice(0, 6);
    const domains = [];
    const rows = events.map(e => {
      let when = 'TBC';
      if (!e.tbc && e.localStart) { const ms = Date.parse(e.localStart); if (!isNaN(ms)) { const dt = new Date(ms); when = dt.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' }) + ' ' + dt.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }); } }
      else if (e.eventDate) { const dt = new Date(e.eventDate + 'T12:00:00'); if (!isNaN(dt)) when = dt.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' }) + ' TBC'; }
      try { const d = new URL(e.source).hostname.replace(/^www\./, ''); if (d && domains.indexOf(d) < 0) domains.push(d); } catch (x) { }
      return '<div class="home-event"><span>' + esc(e.series) + ' \u00b7 ' + esc(e.session) + ' \u00b7 ' + esc(when) + '</span></div>';
    }).join('');
    weekend.innerHTML = '<label>This weekend \u00b7 real world</label>' + (rows || '<div class="home-race-none">No published events</div>') + (domains.length ? '<small class="home-event-source">' + esc(domains.join(' \u00b7 ')) + '</small>' : '');
  },

  // the same id irdeck and irdash give a recent drive (MY DRIVE: FNV-1a of the lower-case "car|track", prefixed r)
  fnv(kind, text) {
    let x = 2166136261; const s = String(text || '').toLowerCase();
    for (let i = 0; i < s.length; i++) { x ^= s.charCodeAt(i); x = Math.imul(x, 16777619) >>> 0; }
    return kind + ('00000000' + (x >>> 0).toString(16)).slice(-8);
  },

  // the one obvious button. It does exactly what it says: LAST DRIVE names the car and track of his last session and
  // starts that car at that track (MY DRIVE: choose it, check it is chosen, then start); with no last session it is START.
  async next() {
    if (document.hidden) return;
    if (!this.shown()) return;
    const seq = ++this.healthSeq;
    try { this.health = await (await fetch('/health', { cache: 'no-store' })).json(); } catch (e) { if (!this.health) return; }
    if (seq !== this.healthSeq) return;
    const apps = {}; ((this.health && this.health.apps) || []).forEach(a => apps[a.id] = a.state);
    const l = this.home && this.home.last, b = $('homeNext');
    let act;
    if (apps.ui && apps.ui !== 'ok') act = { key: 'rig-on', label: 'Rig on' };
    else if (apps.sim === 'live') act = { key: 'go', label: 'Get in' };
    else if (l && l.car && l.track) act = { label: 'Last drive', car: l.car, track: l.track, sub: esc(this.short(l.car)) + ' \u00b7 ' + esc(l.track) };
    else act = { key: 'test-drive-last', label: 'Start' };
    this.act = act;
    b.homeAct = act; // keep the command paired with the label shown on this button
    const busy = Date.now() < this.busyUntil, failed = !busy && Date.now() < this.failUntil;
    b.hidden = false; b.className = 'home-next' + (busy ? ' busy' : '');
    b.setAttribute('data-car', act.car || ''); b.setAttribute('data-track', act.track || '');
    const sub = busy ? '' : failed ? 'Car not chosen' : (act.sub || '');
    setHTML(b, '<div><b>' + (busy ? 'Starting' : esc(act.label)) + '</b>' + (sub ? '<span>' + sub + '</span>' : '') + '</div>' +
      '<svg viewBox="0 0 28 28" aria-hidden="true"><path d="M4 14h19M15 6l8 8-8 8"/></svg>');
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
    if (!chosen) { this.busyUntil = 0; this.failUntil = Date.now() + 6000; this.next(); return; }
    await this.send('mdstart', '');
  },

  // the phone: a pairing square only while no phone is paired; otherwise one status word at the foot
  async phone() {
    if (document.hidden) return;
    if (!this.shown()) return;
    let p; try { p = await (await fetch('/phone/qr', { cache: 'no-store' })).json(); } catch (e) { return; }
    const el = $('homePhone'), note = $('homePhoneNote');
    let state = '', cls = '';
    if (!p.allowed) { state = 'Phone: run tools\\phone-allow.cmd'; cls = 'ask'; }
    else if (!p.rows || !p.rows.length) state = 'Phone: no home network';
    else if (p.paired) state = 'Phone paired';
    if (note) { setText(note, state); note.className = 'foot-phone' + (cls ? ' ' + cls : ''); note.hidden = !state; }
    if (!p.allowed || !p.rows || !p.rows.length || p.paired) { el.hidden = true; setHTML(el, ''); return; }
    el.hidden = false;
    if (!el.querySelector('canvas')) setHTML(el, '<div class="txt"></div><canvas width="140" height="140" aria-label="Pair phone"></canvas>');
    const cv = el.querySelector('canvas'), n = p.size, quiet = 3, scale = Math.floor(140 / (n + quiet * 2)), px = scale * (n + quiet * 2);
    cv.width = px; cv.height = px;
    const g = cv.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, px, px); g.fillStyle = '#000';
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (p.rows[y][x] === '1') g.fillRect((x + quiet) * scale, (y + quiet) * scale, scale, scale);
    setHTML(el.querySelector('.txt'), '<label>Pair phone</label><b>' + esc(String(p.code || '').replace(/^(\d{3})(\d{3})$/, '$1 $2')) + '</b>');
  }
};

// a page over HOME (the Session Review) with a back bar. Never while he drives: it closes the moment the session is live.
const HomeHost = {
  el: null,
  init() { setInterval(() => { if (this.el && window.UI && UI.live && UI.live()) this.close(); }, 1500); },
  open(url, title) {
    if (this.el || (window.UI && UI.live && UI.live())) return;
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

