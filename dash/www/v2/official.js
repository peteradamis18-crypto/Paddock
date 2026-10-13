'use strict';
// "Race weekend" on the garage (idle) screen: the official races Peter can enter with the cars and tracks he owns,
// today, Saturday and Sunday, his favourites first, and a countdown for the top favourite in the header.
// The data is irdash's /official (official.cs); this file only draws it. Calm: small caps, gold only for favourites.
// Times in the answer are UTC; they are shown in the PC's own time. "est" = worked out from the series' repeat pattern.
const Official = {
  data: null, got: 0, base: 0, t0: 0,           // got: when the answer arrived (ms); base: the answer's own "now"
  override: new URLSearchParams(location.search).get('onow') || '',     // ?onow=2026-10-09T18:30:00Z pretends it is that time (pictures, tests)

  init() {
    if (!document.getElementById('idleOfficial')) return;
    const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = 'official.css'; document.head.appendChild(l);
    // of-room (narrower greeting, so it does not run under this panel) is added only once a schedule is actually shown
    // the countdown for the top favourite lives in the idle header, between the Sessions link and the date
    const top = document.querySelector('#overlay .idle-top');
    if (top && !document.getElementById('idleNext')) {
      const s = document.createElement('span'); s.id = 'idleNext'; s.className = 'idle-next';
      top.insertBefore(s, document.getElementById('idleDate'));
    }
    this.load(); setInterval(() => this.load(), 60000);
    setInterval(() => this.tick(), 15000);
  },

  shown() { const o = document.getElementById('overlay'); return !!o && o.classList.contains('show'); },

  async load() {
    if (document.hidden) return;
    if (!this.override && !this.shown()) return;               // nobody is looking while a session is on
    try {
      const r = await fetch('/official' + (this.override ? '?now=' + encodeURIComponent(this.override) : ''), { cache: 'no-store' });
      this.data = await r.json();
    } catch (e) { return; }
    if (this.data && this.data.enabled === false) {
      this.data = null;
      const off = document.getElementById('idleOfficial');
      if (off) { off.textContent = ''; delete off.dataset.h; off.style.display = 'none'; }
      const nx = document.getElementById('idleNext'); if (nx) nx.textContent = '';
      const midOff = document.querySelector('#overlay .idle-mid'); if (midOff) midOff.classList.remove('of-room');
      return;
    }
    const elOn = document.getElementById('idleOfficial'); if (elOn) elOn.style.display = '';
    const mid = document.querySelector('#overlay .idle-mid'); if (mid) mid.classList.add('of-room');   // ui.js rewrites #overlay's classes, so this stays on the greeting block
    this.got = Date.now();
    this.base = this.data && this.data.now ? Date.parse(this.data.now) : Date.now();
    this.draw();
  },

  now() { return this.base + (Date.now() - this.got); },

  hm(ms) { return new Date(ms).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }); },
  esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); },

  // "in 12 min", "in 1 h 05", or the clock time when it is further off
  until(t) {
    const m = Math.round((Date.parse(t) - this.now()) / 60000);
    if (m <= 0) return 'now';
    if (m < 60) return 'in ' + m + ' min';
    if (m < 180) return 'in ' + Math.floor(m / 60) + ' h ' + String(m % 60).padStart(2, '0');
    return '';
  },

  tick() { if (!document.hidden && this.data) { this.header(); this.draw(true); } },

  header() {
    const el = document.getElementById('idleNext');
    if (!el) return;
    const n = this.data && this.data.next;
    if (!n) { el.innerHTML = ''; return; }
    const ms = Date.parse(n.t), day = new Date(ms).toDateString() === new Date(this.now()).toDateString() ? '' : new Date(ms).toLocaleDateString('en-GB', { weekday: 'short' }) + ' ';
    const w = this.until(n.t);
    el.innerHTML = 'Next favourite &nbsp;<b>' + this.esc(n.series) + '</b> &nbsp;<i>' + (w || day + this.hm(ms)) + (n.est ? ' est' : '') + '</i>';
  },

  // how many rows each day gets: the weekend is the main view from Friday evening (13 lines fit; a special event takes one)
  budget(d) {
    const keys = d.days.map(x => x.key), weekend = d.view === 'weekend', out = {};
    if (keys.length === 1) out[keys[0]] = 12;
    else if (keys.length === 2) { out[keys[0]] = 5; out[keys[1]] = 5; }                                  // Saturday: today + Sunday
    else if (weekend) { out.today = 2; out.saturday = 4; out.sunday = 3; }                               // Friday evening
    else { out.today = 4; out.saturday = 3; out.sunday = 2; }
    if (d.events && d.events.length) { const last = keys[keys.length - 1]; out[last] = Math.max(1, out[last] - 1); }
    return out;
  },
  row(r, dayKey) {
    const ms = Date.parse(r.t), soon = dayKey === 'today' ? this.until(r.t) : '';
    const sub = [r.car ? r.carShort || r.car : '', r.trackShort + (r.layout ? ' · ' + r.layout : ''), r.len].filter(Boolean).join(' · ');
    return '<div class="of-row' + (r.fav ? ' fav' : '') + '"><div class="of-t"><b>' + this.hm(ms) + '</b><small>' + (soon || (r.est ? 'est' : '')) + '</small></div>' +
      '<div class="of-b"><span class="of-s">' + this.esc(r.series) + '</span><span class="of-d">' + this.esc(sub) + '</span></div>' +
      '<div class="of-r"><i class="lic ' + this.esc(r.lic) + '" title="' + this.esc(r.licName) + '">' + this.esc(r.lic) + '</i><em>' + this.esc(r.every || '') + '</em></div></div>';
  },
  draw(quiet) {
    const el = document.getElementById('idleOfficial'), d = this.data;
    if (!el || !d) return;
    this.header();
    let h = '<label>Race weekend</label>';
    if (!d.loaded) {
      h += '<div class="of-none">' + this.esc(d.msg || 'No schedule yet') + '</div>';
    } else if (d.season && d.season.over) {
      h += '<div class="of-none">Season over</div>';
    } else {
      const bud = this.budget(d);
      let any = false;
      for (const day of d.days) {
        const n = bud[day.key] || 0;
        if (!n) continue;
        const rows = day.rows.slice(0, n);
        h += '<section><h3>' + this.esc(day.label) + '<small>' + this.esc(day.date) + '</small></h3>';
        if (!rows.length) h += '<div class="of-none sm">None' + (day.key === 'today' ? ' left today' : '') + '</div>';
        else { any = true; for (const r of rows) h += this.row(r, day.key); }
        if (day.total > rows.length && rows.length) h += '<div class="of-more">+ ' + (day.total - rows.length) + ' more series</div>';
        h += '</section>';
      }
      if (!any && !d.days.length) h += '<div class="of-none">No races</div>';
      if (d.events && d.events.length) {
        const e = d.events[0];
        h += '<div class="of-ev"><b>Special event</b> ' + this.esc(e.name) + ' · ' + this.esc(e.when) + (e.car ? ' · ' + this.esc(e.car) : '') + '</div>';
      }
      const age = (this.now() - Date.parse(d.asOfUtc || d.now)) / 60000;
      h += '<div class="of-foot">est = estimated' + (age > 60 && !d.fake ? ' · updated ' + this.hm(Date.parse(d.asOfUtc)) : '') + '</div>';
    }
    // redraw only when the picture changed (a countdown tick should not flicker the panel)
    if (quiet && el.dataset.h === h) return;
    el.dataset.h = h; el.innerHTML = h;
  }
};
Official.init();
