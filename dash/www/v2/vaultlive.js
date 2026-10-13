'use strict';
// The Vault page over the dashboard (WS17). Opened by a Stream Deck key (GET /api/do?c=vkopen), the quiet "Vault" link on the idle screen,
// the Sessions page, or ?vault=1. It is an iframe over this page, so nothing opens or moves in Windows. Never while you drive: it closes the
// moment you are in the car and irdash refuses to open it then. Nothing is drawn on the race screens.
const VaultLive = {
  host: null, lockUntil: 0, off: true,

  init() {
    const st = document.createElement('style');
    st.textContent = '#vaultHost { position: fixed; inset: 0; z-index: 947; background: #060606; opacity: 0; transition: opacity .5s ease; }' +
      '#vaultHost.on { opacity: 1; } #vaultHost iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; background: #060606; }' +
      '#dbVault { color: #f2c230; letter-spacing: .22em; cursor: pointer; } #dbVault:hover { color: #f4f1ea; }';
    document.head.appendChild(st);
    const sess = document.getElementById('idleSessions');
    if (sess && sess.parentNode && !document.getElementById('idleVault')) {
      const a = document.createElement('span'); a.className = 'idle-link'; a.id = 'idleVault'; a.tabIndex = 0; a.setAttribute('role', 'button'); a.innerHTML = 'Vault';
      a.addEventListener('click', () => this.openPage(true));
      a.addEventListener('keydown', e => { if (e.key === 'Enter') this.openPage(true); });
      sess.parentNode.insertBefore(a, sess.nextSibling);
    }
    window.addEventListener('message', e => { if (e.origin === location.origin && e.data && e.data.irdash === 'vault-close') this.closePage(true); });
    this.pollNav(); setInterval(() => this.pollNav(), 1500);
    setInterval(() => this.linkDebrief(), 700);
    if (/[?&]vault=1/.test(location.search)) this.openPage(false);
  },

  // After a new personal best the debrief already shows the benchmark card. Add one link into the Vault. Not while the Vault is switched off.
  linkDebrief() {
    const gone = document.getElementById('dbVault');
    if (this.off) { if (gone) gone.remove(); return; }
    const el = document.getElementById('debrief');
    if (!el || !el.querySelector('.db-bench') || document.getElementById('dbVault')) return;
    const foot = el.querySelector('.db-foot');
    if (!foot) return;
    const a = document.createElement('span');
    a.id = 'dbVault'; a.tabIndex = 0; a.setAttribute('role', 'button'); a.textContent = 'In the Vault';
    const open = e => { e.stopPropagation(); e.preventDefault(); if (window.Debrief && Debrief.hide) Debrief.hide(); this.openPage(true); };
    a.addEventListener('click', open);
    a.addEventListener('keydown', e => { if (e.key === 'Enter') open(e); });
    foot.appendChild(a);
  },

  driving() { return UI.live() && !!(L.v && L.v.IsOnTrack); },

  openPage(tell) {
    if (this.host || this.driving()) return;
    const host = document.createElement('div'); host.id = 'vaultHost';
    const f = document.createElement('iframe'); f.src = 'vault.html?embed=1'; f.title = 'Vault';
    host.appendChild(f); document.body.appendChild(host);
    requestAnimationFrame(() => host.classList.add('on'));
    this.host = host; this.lockUntil = Date.now() + 3000;
    if (tell) fetch('/api/do?c=vkopen', { cache: 'no-store' }).catch(() => { });
  },

  closePage(tell) {
    const el = this.host; this.host = null; this.lockUntil = Date.now() + 3000;
    if (!el) return;
    el.classList.remove('on'); setTimeout(() => el.remove(), 600);
    if (tell) fetch('/api/do?c=vkclose', { cache: 'no-store' }).catch(() => { });
  },

  async pollNav() {
    if (document.hidden) return;
    if (this.driving()) { if (this.host) this.closePage(true); return; }      // no requests at all while you drive
    let n;
    try { n = await (await fetch('/vault/nav', { cache: 'no-store' })).json(); } catch (e) { return; }
    if (n && n.enabled === false) {
      this.off = true;
      const link = document.getElementById('idleVault'); if (link) link.hidden = true;
      if (this.host) this.closePage(false);
      return;
    }
    this.off = false;
    if (Date.now() < this.lockUntil) return;
    if (n.to === 'vault' && !this.host) this.openPage(false);
    else if (n.to !== 'vault' && this.host) this.closePage(false);
  },
};
VaultLive.init();
