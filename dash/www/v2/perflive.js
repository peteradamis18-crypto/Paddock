'use strict';
// The Performance page (perf.html) over HOME: the quiet "Performance" link on HOME, and the page opened by a Stream Deck key
// (GET /api/do?c=perf) or ?perf=1; never while you drive (pagehost.js opens, closes and follows irdash).
// W2-2 retired the live half on purpose (the small fps number and the amber frame-rate line lived in the old in-car grid's header):
// the race screen does not carry them, and the black box and the RIG door tell the frame rate after the drive.
const PerfLive = {
  init() {
    // a quiet "Performance" link beside "Sessions & laps" on the idle screen (made here so the idle markup is not touched)
    const sess = document.getElementById('idleSessions');
    if (sess && sess.parentNode && !document.getElementById('idlePerf')) {
      const a = document.createElement('span'); a.className = 'idle-link'; a.id = 'idlePerf'; a.tabIndex = 0; a.setAttribute('role', 'button'); a.innerHTML = 'Performance';
      a.addEventListener('click', () => this.openPage(true));
      a.addEventListener('keydown', e => { if (e.key === 'Enter') this.openPage(true); });
      sess.parentNode.insertBefore(a, sess.nextSibling);
    }
  },

  driving() { return PageHost.driving(); },
  get host() { return PageHost.isOpen('perf') ? PageHost.el : null; },
  openPage(tell) { return PageHost.open('perf', tell); },
  closePage(tell) { if (PageHost.isOpen('perf')) PageHost.close(tell); },
};
PerfLive.init();
