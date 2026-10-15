'use strict';
// One manager for the pages shown over the dashboard (Sessions, Vault, Performance). It replaced three copies of the
// same open/close logic that each polled irdash and re-opened their page whenever the server flag still said so, which
// left a page that would not close (Peter 2026-10-15: "sessions wont close"; the log of 12 Oct shows open/close fights
// every 3-4 s). Rules now:
//  - one page at a time; opening another closes the first;
//  - irdash's page request is followed only when it is NEW (its seq changed), never because a flag is still set;
//  - a big CLOSE button drawn by this page sits above every page, so closing never depends on the page inside;
//  - Esc closes the page from anywhere, and a page's own close message closes it;
//  - never while he drives: a page open when he gets in the car closes, and nothing is requested then.
const PageHost = {
  PAGES: {
    sessions: { id: 'sessHost', src: 'sessions.html?embed=1', title: 'Sessions', nav: '/nav', open: '/api/nav?to=sessions', close: '/api/nav?to=home', z: 948 },
    vault: { id: 'vaultHost', src: 'vault.html?embed=1', title: 'Vault', nav: '/vault/nav', open: '/api/do?c=vkopen', close: '/api/do?c=vkclose', z: 947 },
    perf: { id: 'perfHost', src: 'perf.html?embed=1', title: 'Performance', nav: '/perf/nav', open: '/api/do?c=perf', close: '/api/do?c=perfclose', z: 946 },
  },
  cur: '', el: null, seen: {}, busy: false,

  init() {
    const st = document.createElement('style');
    st.textContent =
      '.pg-host { position: fixed; inset: 0; background: #060606; opacity: 0; transition: opacity .4s ease; }' +
      '.pg-host.on { opacity: 1; }' +
      '.pg-host iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; background: #060606; }' +
      '.pg-close { position: absolute; top: 14px; right: 20px; z-index: 2; height: 56px; min-width: 168px; padding: 0 28px; border: 1px solid #f2c230; border-radius: 6px;' +
      ' background: rgba(6, 6, 6, .92); color: #f2c230; font: 600 20px Bahnschrift, "Segoe UI", sans-serif; letter-spacing: .24em; text-transform: uppercase; cursor: pointer; }' +
      '.pg-close:hover, .pg-close:focus-visible { background: #f2c230; color: #0a0905; outline: none; }';
    document.head.appendChild(st);
    window.addEventListener('message', e => {
      if (e.origin !== location.origin || !e.data) return;
      const m = e.data.irdash;
      if (m === 'sessions-close' || m === 'vault-close' || m === 'perf-close') this.close(true);
    });
    document.addEventListener('keydown', e => { if (e.key === 'Escape' && this.cur) { e.preventDefault(); this.close(true); } }, true);
    this.poll(); setInterval(() => this.poll(), 1500);
    const q = location.search;
    if (/[?&]sessions=1/.test(q)) this.open('sessions', false);
    else if (/[?&]vault=1/.test(q)) this.open('vault', false);
    else if (/[?&]perf=1/.test(q)) this.open('perf', false);
  },

  driving() { return !!(window.UI && UI.live && UI.live() && window.L && L.v && L.v.IsOnTrack); },
  isOpen(name) { return this.cur === name; },
  send(url) { fetch(url, { cache: 'no-store' }).catch(() => { }); },

  open(name, tell) {
    const p = this.PAGES[name]; if (!p || this.driving()) return false;
    if (this.cur === name) return true;
    if (this.cur) this.close(true);
    const host = document.createElement('div'); host.id = p.id; host.className = 'pg-host'; host.style.zIndex = p.z;
    const f = document.createElement('iframe'); f.src = p.src; f.title = p.title;
    const b = document.createElement('button'); b.type = 'button'; b.className = 'pg-close'; b.textContent = 'Close';
    b.addEventListener('click', ev => { ev.stopPropagation(); this.close(true); });
    host.appendChild(f); host.appendChild(b); document.body.appendChild(host);
    requestAnimationFrame(() => host.classList.add('on'));
    this.cur = name; this.el = host;
    if (tell) this.send(p.open);
    return true;
  },

  close(tell) {
    const name = this.cur, el = this.el; if (!name) return;
    this.cur = ''; this.el = null;
    el.classList.remove('on'); el.id = '';                // the id goes at once, so "is it open?" is true to the moment
    setTimeout(() => el.remove(), 450);
    if (tell) this.send(this.PAGES[name].close);
  },

  // Follow irdash only on a NEW request (seq changed). The first answer after loading the page is taken as is, so a
  // page the Stream Deck asked for before this page loaded still opens.
  async poll() {
    if (document.hidden || this.busy) return;
    if (this.driving()) { if (this.cur) this.close(true); return; }      // no requests at all while he drives
    this.busy = true;
    try {
      for (const name of Object.keys(this.PAGES)) {
        let n; try { n = await (await fetch(this.PAGES[name].nav, { cache: 'no-store' })).json(); } catch (e) { continue; }
        if (!n || typeof n.seq !== 'number') continue;
        if (n.enabled === false) { if (this.cur === name) this.close(false); this.seen[name] = n.seq; continue; }
        const first = !(name in this.seen), changed = this.seen[name] !== n.seq;
        this.seen[name] = n.seq;
        if (!first && !changed) continue;
        if (n.to === name) { if (first ? !this.cur : true) this.open(name, false); }
        else if (this.cur === name && !first) this.close(false);
      }
    } finally { this.busy = false; }
  },
};
PageHost.init();
