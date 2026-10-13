'use strict';
// Startup intro. irdash says when to play it: once per Windows start (/showcase "play"), and again each time
// the SHOWCASE key bumps "seq". Never while driving. ?intro=1 forces it (for testing). Click or any key skips.
const Intro = {
  NUMBER: '4',          // Tommy Milner's Corvette Racing number
  FIRST: 'Peter',
  seq: null, running: false, timers: [],

  async init() {
    const force = /[?&]intro=1/.test(location.search);
    const s = await this.ask();
    if (s) this.seq = s.seq;
    if (force || (s && s.play)) this.play();
    setInterval(async () => {
      if (document.hidden) return;
      const t = await this.ask();
      if (!t) return;
      if (this.seq !== null && t.seq > this.seq && !t.driving) this.play();
      this.seq = t.seq;
    }, 3000);
  },

  async ask() {
    try { return await (await fetch('/showcase?who=page', { cache: 'no-store' })).json(); } catch (e) { return null; }
  },

  async play() {
    if (this.running) return;
    this.running = true;
    const [car, sys] = await Promise.all([
      fetch('/career', { cache: 'no-store' }).then(r => r.json()).catch(() => ({})),
      fetch('/systems', { cache: 'no-store' }).then(r => r.json()).catch(() => ({ items: [] }))]);
    const el = this.build(car, sys);
    document.body.appendChild(el);
    const at = (ms, f) => this.timers.push(setTimeout(f, ms));
    const add = c => () => el.classList.add(c);
    const end = () => this.finish(el);
    el.addEventListener('click', end); this.keyEnd = e => end(); window.addEventListener('keydown', this.keyEnd);
    requestAnimationFrame(() => el.classList.add('on'));
    at(400, add('s1'));
    at(1300, add('s2'));
    at(3300, () => { el.classList.add('s3'); el.querySelectorAll('[data-to]').forEach(n => this.count(n)); });
    at(5600, add('s4'));
    const rows = el.querySelectorAll('.row');
    rows.forEach((r, i) => at(5900 + i * 330, () => r.classList.add('in', r.dataset.ok === '1' ? 'ok' : 'bad')));
    const tReady = 5900 + rows.length * 330 + 500;
    at(tReady, add('s5'));
    at(tReady + 900, add('s6'));
    if (!/[?&]hold=1/.test(location.search)) at(tReady + 2600, end);   // hold=1 keeps the last frame (for previews)
  },

  finish(el) {
    if (!el.isConnected) return;
    this.timers.forEach(clearTimeout); this.timers = [];
    window.removeEventListener('keydown', this.keyEnd);
    el.classList.add('out');
    setTimeout(() => { el.remove(); this.running = false; }, 1200);
  },

  count(n) {
    const to = +n.dataset.to, dec = +(n.dataset.dec || 0), t0 = performance.now(), dur = 1400;
    const fmt = v => v.toLocaleString('en-GB', { minimumFractionDigits: dec, maximumFractionDigits: dec });
    const step = now => {
      const p = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - p, 3);
      n.firstChild.nodeValue = fmt(to * e);
      if (p < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  },

  build(c, s) {
    const e = (t, cls, html) => { const d = document.createElement(t); if (cls) d.className = cls; if (html != null) d.innerHTML = html; return d; };
    const h = v => String(v == null ? '' : v).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
    const now = new Date();
    const day = now.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' });
    const time = now.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    const root = e('div'); root.id = 'intro';
    root.append(e('div', 'rule t'), e('div', 'rule b'));
    root.append(e('div', 'corner tl wordmark', 'Paddock'));
    root.append(e('div', 'corner tr', h(day) + ' &nbsp; <b>' + h(time) + '</b>'));
    root.append(e('div', 'corner bl', 'Pre-race systems'));
    root.append(e('div', 'corner br', c.todayMin > 0 ? 'Today <b>' + h(Math.round(c.todayMin)) + ' min</b> in the seat' : ''));
    root.append(e('div', 'hair'));

    const drv = e('div', 'driver');
    drv.append(e('div', 'num', h(this.NUMBER)));
    const who = e('div', 'who');
    who.append(e('div', 'pre', 'Driver'), e('div', 'name', h(this.FIRST)));
    drv.append(who);
    root.append(drv);

    const creds = [];
    if (c.lic) creds.push('Licence <b>' + h(c.lic) + '</b>');
    if (c.ir > 0) creds.push('iRating <b>' + h(c.ir.toLocaleString('en-GB')) + '</b>');
    if (c.topCar) creds.push(h(c.topCar));
    root.append(e('div', 'creds', creds.join('<i>/</i>')));

    const car = e('div', 'career');
    const stat = (label, val, dec, unit) => car.append(e('div', 'stat',
      '<label>' + label + '</label><b data-to="' + (+val || 0) + '" data-dec="' + dec + '">0' + (unit ? '<small>' + unit + '</small>' : '') + '</b>'));
    stat('Seat time', c.hours, (c.hours || 0) < 100 ? 1 : 0, 'h');
    stat('Laps', c.laps, 0, '');
    stat('Distance', c.km, 0, 'km');
    stat('Races', c.races, 0, '');
    root.append(car);
    const most = [];
    if (c.topTrack) most.push('Home circuit &nbsp;<b>' + h(c.topTrack) + '</b>');
    root.append(e('div', 'most', most.join(' &nbsp;&nbsp;·&nbsp;&nbsp; ')));

    const sys = e('div', 'sys', '<h3>Systems check</h3>');
    (s.items || []).forEach(it => {
      const r = e('div', 'row', '<i class="st"></i><span>' + h(it.name) + '</span><span class="d">' + h(it.detail) + '</span>');
      r.dataset.ok = it.ok ? '1' : '0';
      sys.append(r);
    });
    root.append(sys);
    const allOk = (s.items || []).every(it => it.ok);
    root.append(e('div', 'ready', allOk ? 'Ready to race' : 'Ready · check items'));
    root.append(e('div', 'sweep'));
    return root;
  }
};
Intro.init();
