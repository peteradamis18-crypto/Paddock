'use strict';
// Frame rate on the live dashboard (F5 in docs\SPEC-next.md) and the Performance page host.
//  - a small calm number next to the track name while a session is live;
//  - one quiet amber line, only when the 10-second average is more than 15 % below your usual at this track (usual and the likely
//    cause come from irdash /perf/live, which knows your history and what else was busy); it clears itself when the rate recovers;
//  - the Performance page (perf.html) over the dashboard, opened by a Stream Deck key (GET /api/do?c=perf) or ?perf=1; never while you drive.
// Nothing is drawn on the race screens.
const PerfLive = {
  fpsEl: null, warnEl: null, ring: [], onSince: 0, normal: null, cause: '', polledAt: 0, polling: false, shownAt: 0, shown: false,

  CSS: '#fpsLive { margin-left: auto; flex: none; font-size: 14px; letter-spacing: .08em; color: var(--muted); white-space: nowrap; font-variant-numeric: tabular-nums; }' +
       '#fpsLive b { font-weight: 600; color: var(--text); margin-right: 5px; letter-spacing: 0; }' +
       '#perfWarn { font-size: 13px; letter-spacing: .03em; line-height: 1.3; color: var(--amber); opacity: .95; }' +
       '#perfWarn b { font-weight: 600; }' +
       'body.perfwarn .health { display: none; }' +
       '',

  init() {
    const st = document.createElement('style'); st.textContent = this.CSS; document.head.appendChild(st);
    const sub = document.querySelector('.mrow.sub'), meta = document.querySelector('.meta');
    if (sub) { const e = document.createElement('span'); e.id = 'fpsLive'; e.hidden = true; sub.appendChild(e); this.fpsEl = e; }
    if (meta) { const w = document.createElement('div'); w.id = 'perfWarn'; w.hidden = true; meta.appendChild(w); this.warnEl = w; }
    // a quiet "Performance" link beside "Sessions & laps" on the idle screen (made here so the idle markup is not touched)
    const sess = document.getElementById('idleSessions');
    if (sess && sess.parentNode && !document.getElementById('idlePerf')) {
      const a = document.createElement('span'); a.className = 'idle-link'; a.id = 'idlePerf'; a.tabIndex = 0; a.setAttribute('role', 'button'); a.innerHTML = 'Performance';
      a.addEventListener('click', () => this.openPage(true));
      a.addEventListener('keydown', e => { if (e.key === 'Enter') this.openPage(true); });
      sess.parentNode.insertBefore(a, sess.nextSibling);
    }
    setInterval(() => this.tick(), 500);
  },

  /* ---------- the number and the amber line ---------- */
  tick() {
    if (document.hidden) return;
    const v = L.v, fps = v.FrameRate;
    const live = UI.live() && !L.demo && isNum(fps) && fps > 1;
    if (this.fpsEl) {
      if (live) { setHTML(this.fpsEl, '<b>' + Math.round(fps) + '</b>fps'); this.fpsEl.hidden = false; }
      else this.fpsEl.hidden = true;
    }
    const now = performance.now();
    const driving = live && v.IsOnTrack && !v.IsReplayPlaying && !v.OnPitRoad;
    if (!driving) { this.ring = []; this.onSince = 0; this.normal = null; this.hideWarn(); return; }
    if (!this.onSince) this.onSince = now;
    this.ring.push({ t: now, v: fps });
    while (this.ring.length && now - this.ring[0].t > 10000) this.ring.shift();
    if (now - this.onSince < 20000 || this.ring.length < 16) return;      // the loading hitch after getting in, and a full 10 s of numbers
    if (now - this.polledAt > 4000) this.poll();
    if (!isNum(this.normal) || this.normal <= 0) { this.hideWarn(); return; }
    const avg = this.ring.reduce((a, s) => a + s.v, 0) / this.ring.length;
    const drop = (this.normal - avg) / this.normal;
    if (!this.shown && drop > 0.15) { this.shown = true; this.shownAt = now; }
    else if (this.shown && drop < 0.10 && now - this.shownAt > 8000) { this.hideWarn(); return; }
    if (this.shown && this.warnEl) {
      // two short lines in the place of the health dots (the strip has no spare height)
      setHTML(this.warnEl, '<b>Frame rate ' + Math.round(avg) + ', usually ' + Math.round(this.normal) + ' here</b>' + (this.cause ? '<br>Likely cause: ' + esc(this.cause) : ''));
      this.warnEl.hidden = false; document.body.classList.add('perfwarn');
    }
  },

  hideWarn() { this.shown = false; document.body.classList.remove('perfwarn'); if (this.warnEl && !this.warnEl.hidden) { this.warnEl.hidden = true; this.warnEl._h = ''; } },

  async poll() {
    if (document.hidden) return;
    if (this.polling) return;
    this.polling = true; this.polledAt = performance.now();
    try {
      const r = await (await fetch('/perf/live', { cache: 'no-store' })).json();
      this.normal = r.on && isNum(r.normal) ? r.normal : null;
      this.cause = r.on ? (r.cause || '') : '';
    } catch (e) { /* irdash restarting */ }
    this.polling = false;
  },

  /* ---------- the Performance page over the dashboard: pagehost.js opens, closes and follows irdash ---------- */
  driving() { return PageHost.driving(); },
  get host() { return PageHost.isOpen('perf') ? PageHost.el : null; },
  openPage(tell) { return PageHost.open('perf', tell); },
  closePage(tell) { if (PageHost.isOpen('perf')) PageHost.close(tell); },
};
PerfLive.init();
