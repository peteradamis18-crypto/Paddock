'use strict';
// The Vault page over the dashboard (WS17). Opened by a Stream Deck key (GET /api/do?c=vkopen), the quiet "Vault" link on the idle screen,
// the Sessions page, or ?vault=1. It is an iframe over this page, so nothing opens or moves in Windows. Never while you drive: it closes the
// moment you are in the car and irdash refuses to open it then. Nothing is drawn on the race screens.
const VaultLive = {
  off: true,

  init() {
    const st = document.createElement('style');
    st.textContent = '#dbVault { color: #C9A24B; letter-spacing: .22em; cursor: pointer; } #dbVault:hover { color: #f4f1ea; }';
    document.head.appendChild(st);
    const sess = document.getElementById('idleSessions');
    if (sess && sess.parentNode && !document.getElementById('idleVault')) {
      const a = document.createElement('span'); a.className = 'idle-link'; a.id = 'idleVault'; a.tabIndex = 0; a.setAttribute('role', 'button'); a.innerHTML = 'Vault';
      a.addEventListener('click', () => this.openPage(true));
      a.addEventListener('keydown', e => { if (e.key === 'Enter') this.openPage(true); });
      sess.parentNode.insertBefore(a, sess.nextSibling);
    }
    data.on('state', (st, ch) => { if (ch.vaultNav) this.nav(st.vaultNav); });     // W0-5: irdash pushes it
  },

  // opening, closing and following irdash: pagehost.js (one page at a time, CLOSE button, Esc, new requests only)
  driving() { return PageHost.driving(); },
  get host() { return PageHost.isOpen('vault') ? PageHost.el : null; },
  openPage(tell) { return PageHost.open('vault', tell); },
  closePage(tell) { if (PageHost.isOpen('vault')) PageHost.close(tell); },

  // only the on/off switch is read here (the Vault can be switched off in irdash.ini); pagehost.js follows the requests
  nav(n) {
    this.off = !!(n && n.enabled === false);
    const link = document.getElementById('idleVault'); if (link) link.hidden = this.off;
  },};
VaultLive.init();
