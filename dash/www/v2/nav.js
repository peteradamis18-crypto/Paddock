'use strict';
// The sessions page over the dashboard. Opened by the "Sessions" link on the idle screen or by a Stream Deck key
// (GET /api/sessions/open: irdash /nav then says to=sessions). It is an iframe over this page, so the dashboard
// underneath keeps running and nothing opens or moves in Windows. Never while you drive: it closes the moment you are
// in the car, and irdash refuses to open it then.
const SessionsHost = {
  el: null, lockUntil: 0,

  init() {
    const link = $('idleSessions');
    if (link) { link.addEventListener('click', () => this.open(true)); link.addEventListener('keydown', e => { if (e.key === 'Enter') this.open(true); }); }
    window.addEventListener('message', e => { if (e.origin === location.origin && e.data && e.data.irdash === 'sessions-close') this.close(true); });
    this.poll(); setInterval(() => this.poll(), 1500);
    if (/[?&]sessions=1/.test(location.search)) this.open(false);
  },

  driving() { return UI.live() && !!(L.v && L.v.IsOnTrack); },

  open(tell) {
    if (this.el || this.driving()) return;
    const host = document.createElement('div'); host.id = 'sessHost';
    const f = document.createElement('iframe'); f.src = 'sessions.html?embed=1'; f.title = 'Sessions';
    host.appendChild(f); document.body.appendChild(host);
    requestAnimationFrame(() => host.classList.add('on'));
    this.el = host; this.lockUntil = Date.now() + 3000;
    if (tell) fetch('/api/nav?to=sessions', { cache: 'no-store' }).catch(() => { });
  },

  close(tell) {
    const el = this.el; this.el = null; this.lockUntil = Date.now() + 3000;
    if (!el) return;
    el.classList.remove('on'); setTimeout(() => el.remove(), 600);
    if (tell) fetch('/api/nav?to=home', { cache: 'no-store' }).catch(() => { });
  },

  async poll() {
    if (document.hidden) return;
    if (this.driving()) { if (this.el) this.close(true); return; }   // no requests at all while you drive
    let n;
    try { n = await (await fetch('/nav', { cache: 'no-store' })).json(); } catch (e) { return; }
    if (Date.now() < this.lockUntil) return;
    if (n.to === 'sessions' && !this.el) this.open(false);
    else if (n.to !== 'sessions' && this.el) this.close(false);
  },
};
SessionsHost.init();
