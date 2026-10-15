'use strict';
// The sessions page over the dashboard. Opened by the "Sessions" link on the idle screen or by a Stream Deck key
// (GET /api/sessions/open: irdash /nav then says to=sessions). Opening, closing and following irdash is done by
// pagehost.js (one page at a time, a CLOSE button, Esc, new requests only); this keeps the old names working.
const SessionsHost = {
  get el() { return PageHost.isOpen('sessions') ? PageHost.el : null; },
  init() {
    const link = $('idleSessions');
    if (link) { link.addEventListener('click', () => this.open(true)); link.addEventListener('keydown', e => { if (e.key === 'Enter') this.open(true); }); }
  },
  driving() { return PageHost.driving(); },
  open(tell) { return PageHost.open('sessions', tell); },
  close(tell) { if (PageHost.isOpen('sessions')) PageHost.close(tell); },
};
SessionsHost.init();
