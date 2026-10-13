'use strict';
// Paddock HOME (DS-1 rebuild): the top screen when no session runs. One picture, his name and number and car, one gold button, one quiet row of facts.
// ui.js shows and hides #overlay; this only draws while it is shown, so nothing here runs or polls while he drives. Every button is one irdash call the deck has too.
// Words: docs\COPY-RULES.md (labels and numbers only).
const Home = {
  home: null, career: null, health: null, busyUntil: 0, failUntil: 0, act: null,
  dry: false, sent: [],      // tests: dry = true records the /api/do calls instead of sending them

  init() {
    this.tick(); setInterval(() => this.tick(), 60000);
    this.next(); setInterval(() => this.next(), 5000);
    this.phone(); setInterval(() => this.phone(), 30000);
    const b = $('homeNext'); if (b) b.addEventListener('click', () => this.go());
    HomeHost.init();
  },

  shown() { const ov = $('overlay'); return !!(ov && ov.classList.contains('show')) && !(window.UI && UI.live && UI.live()); },

  lap(t) { if (!(t > 0)) return '–'; const m = Math.floor(t / 60), s = t - m * 60; return (m ? m + ':' : '') + (m && s < 10 ? '0' : '') + s.toFixed(3); },
  short(car) { return String(car || '').replace(/^Chevrolet /, ''); },

  async tick() {
    if (!this.shown()) return;
    try { this.home = await (await fetch('/home', { cache: 'no-store' })).json(); } catch (e) { return; }
    try { this.career = await (await fetch('/career', { cache: 'no-store' })).json(); } catch (e) { this.career = null; }
    this.draw();
  },

  // where the car stands in the picture, as two boxes: the cabin (from where the picture is opaque enough to be "the car") and the nose, which is lower;
  // the test checks that no text, button or square sits inside them
  carRegion() {
    const r = $('heroImg').getBoundingClientRect(), X = u => r.left + r.width * u, Y = v => r.top + r.height * v;
    return [{ left: X(0.36), right: X(0.70), top: Y(0.34), bottom: Y(0.87) }, { left: X(0.70), right: X(0.86), top: Y(0.50), bottom: Y(0.87) }];
  },

  draw() {
    const h = this.home, c = this.career || {};
    if (!h) return;
    const name = h.name || c.name || 'Peter Adamis';
    // the car of his last real session (PL-1) and iRacing's own picture of it (CP-1); no picture for it = text only
    const me = h.me || null;
    const pic = me && me.path && window.PCarPic ? PCarPic.html({ path: me.path, w: 264, title: me.car || '' }) : '';
    const num = (me && me.num) || h.num || '';
    const car = this.short((me && me.car) || h.car || c.topCar || '');
    const lic = [c.lic ? 'Licence <i>' + esc(c.lic) + '</i>' : '', c.ir ? '<i>' + esc(c.ir) + '</i> iR' : ''].filter(Boolean).join(' &nbsp;·&nbsp; ');
    setHTML('homeDriver',
      '<div class="idrow">' + (num ? '<span class="num' + (num.length > 2 ? ' wide' : '') + '">' + esc(num) + '</span><span class="rule"></span>' : '') +
      '<div class="who"><b>' + esc(name) + '</b></div></div>' +
      (car || pic ? '<div class="idcar">' + (pic ? '<div class="mycar">' + pic + '</div>' : '') + '<div class="car"><b>' + esc(car) + '</b>' + (lic ? '<span>' + lic + '</span>' : '') + '</div></div>' : ''));

    // personal bests: at most three, one per track, newest tracks first
    const pbs = (h.pbs || []).slice(0, 3);
    setHTML('homePbs', pbs.length ? '<label>Personal bests</label><div class="pbs">' + pbs.map(p => {
      const cfg = p.config && !/^(full|full course|grand prix)$/i.test(p.config) && p.track.toLowerCase().indexOf(p.config.toLowerCase()) < 0 ? '<small>' + esc(p.config) + '</small>' : '';
      return '<div class="pb"><span class="tk">' + esc(p.track) + cfg + '</span><b class="t">' + this.lap(p.best) + '</b><span class="cap">' + esc(this.short(p.car)) + '</span></div>';
    }).join('') + '</div>' : '');
    $('homePbs').hidden = !pbs.length;
    $('homePbs').style.gridColumn = 'span ' + Math.max(1, pbs.length * 2);   // 2 columns of the grid per personal best
    $('homePbs').style.setProperty('--n', Math.max(1, pbs.length));

    const n = x => (x == null || isNaN(x)) ? '–' : Math.round(x).toLocaleString('en-GB');
    setHTML('homeCareer', '<label><span>Career</span>' + (c.since ? '<span class="dim">Since ' + esc(c.since) + '</span>' : '') + '</label>' +
      '<div class="cv">' +
      '<div class="w"><b>' + (c.hours != null ? Number(c.hours).toFixed(1) : '–') + '</b><span class="cap">Hours</span></div>' +
      '<div class="w"><b>' + n(c.laps) + '</b><span class="cap">Laps</span></div>' +
      '<div class="w"><b>' + n(c.km) + '</b><span class="cap">Km</span></div>' +
      '<div class="w"><b>' + n(c.races) + '</b><span class="cap">Races</span></div></div>');

    const l = h.last;
    if (!l) setHTML('homeLast', '');
    else {
      const when = (l.date || '').slice(0, 10), wd = when ? new Date(when + 'T12:00:00') : null;
      const dt = wd && !isNaN(wd) ? wd.getDate() + ' ' + wd.toLocaleDateString('en-GB', { month: 'short' }) : '';
      setHTML('homeLast', '<label><span>Last session</span>' + (dt ? '<span class="dim">' + esc(dt) + '</span>' : '') + '</label>' +
        '<div class="lv"><span class="tk">' + esc(l.track) + '</span>' +
        '<b class="t">' + (l.laps ? l.laps + '<small>' + (l.laps === 1 ? 'lap' : 'laps') + '</small>' : '–') + '</b>' +
        '<span class="cap">' + [l.type ? esc(l.type) : '', l.best ? 'Best ' + this.lap(l.best) : ''].filter(Boolean).join(' &nbsp;·&nbsp; ') + '</span>' +
        (l.laps ? '<button class="review" type="button" id="homeReview">Review</button>' : '') + '</div>');
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

  // the same id irdeck and irdash give a recent drive (MY DRIVE: FNV-1a of the lower-case "car|track", prefixed r)
  fnv(kind, text) {
    let x = 2166136261; const s = String(text || '').toLowerCase();
    for (let i = 0; i < s.length; i++) { x ^= s.charCodeAt(i); x = Math.imul(x, 16777619) >>> 0; }
    return kind + ('00000000' + (x >>> 0).toString(16)).slice(-8);
  },

  // the one obvious button. It does exactly what it says: LAST DRIVE names the car and track of his last session and
  // starts that car at that track (MY DRIVE: choose it, check it is chosen, then start); with no last session it is START.
  async next() {
    if (!this.shown()) return;
    try { this.health = await (await fetch('/health', { cache: 'no-store' })).json(); } catch (e) { if (!this.health) return; }
    const apps = {}; ((this.health && this.health.apps) || []).forEach(a => apps[a.id] = a.state);
    const l = this.home && this.home.last, b = $('homeNext');
    let act;
    if (apps.ui && apps.ui !== 'ok') act = { key: 'rig-on', label: 'Rig on' };
    else if (apps.sim === 'live') act = { key: 'go', label: 'Get in' };
    else if (l && l.car && l.track) act = { label: 'Last drive', car: l.car, track: l.track, sub: esc(this.short(l.car)) + ' · ' + esc(l.track) };
    else act = { key: 'test-drive-last', label: 'Start' };
    this.act = act;
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

  async go() {
    const act = this.act;
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
