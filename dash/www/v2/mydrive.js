'use strict';
// My Drive on the top screen. irdash /mydrive says what the Stream Deck MY DRIVE screen has chosen.
//  - while that screen is open (and you are not in the car): a card with the chosen car and track, the name being
//    typed, the search results, and START progress
//  - when START has put you in the car: a few seconds at the top: "START -> in the car 41 s"
// Nothing here is clickable; the Stream Deck does it all.
const MyDrive = {
  el: null, seen: undefined, busyAt: 0, toastTimer: 0, last: '',

  init() { this.poll(); setInterval(() => this.poll(), 1200); },

  driving() { return UI.live() && !!(L.v && L.v.IsOnTrack); },

  async poll() {
    if (document.hidden) return;
    let m;
    try { m = await (await fetch('/mydrive', { cache: 'no-store' })).json(); } catch (e) { return; }
    if (!m || !m.ready) return;
    this.news(m);
    if (m.open && !this.driving()) this.show(m); else this.hide();
  },

  // "START -> in the car 41 s": once per start, not for one that happened before this page opened
  news(m) {
    const seq = m.last ? m.last.seq : 0;
    if (this.seen === undefined) { this.seen = seq; return; }
    if (seq > this.seen && m.last.age < 60) {
      let t = $('mdToast');
      if (!t) { t = document.createElement('div'); t.id = 'mdToast'; t.setAttribute('role', 'status'); document.body.appendChild(t); }
      setHTML(t, '<b>My Drive</b>START → in the car <em>' + esc(String(m.last.secs)) + ' s</em><small>' + esc(m.last.car) + ' · ' + esc(m.last.track) + '</small>');
      requestAnimationFrame(() => t.classList.add('on'));
      clearTimeout(this.toastTimer); this.toastTimer = setTimeout(() => t.classList.remove('on'), 9000);
    }
    this.seen = seq;
  },

  hide() {
    if (!this.el) return;
    const el = this.el; this.el = null; el.classList.remove('on'); setTimeout(() => el.remove(), 600);
  },

  show(m) {
    if (!this.el) {
      this.el = document.createElement('div'); this.el.id = 'mydrive'; document.body.appendChild(this.el);
      requestAnimationFrame(() => this.el && this.el.classList.add('on'));
    }
    const h = esc, c = m.choice, res = m.results;
    if (m.busy === 'start') { if (!this.busyAt) this.busyAt = Date.now(); } else this.busyAt = 0;
    let main;
    if (m.draft) {
      // typing a search on the deck keyboard
      main = '<div class="md-type"><label>Search the ' + h(m.draft.kind) + ' list</label><b>' + h(m.draft.text) + '<i class="caret"></i></b><small>Type on the Stream Deck, then press <b>DONE</b></small></div>';
    } else if (m.busy === 'find') {
      main = '<div class="md-busy"><label>iRacing</label><b>Searching</b></div>';
    } else if (m.busy === 'start' || m.phase === 'failed') {
      const secs = this.busyAt ? Math.round((Date.now() - this.busyAt) / 1000) : 0;
      main = '<div class="md-busy' + (m.phase === 'failed' ? ' bad' : '') + '"><label>' + (m.phase === 'failed' ? 'Could not start' : 'Starting') + '</label><b>' + h(m.msg || '…') + '</b>' +
             (m.phase === 'failed' ? '<small>Press START to retry</small>' : '<small>' + secs + ' s</small>') + '</div>';
    } else if (res) {
      const rows = (res.items || []).map((it, i) => '<div class="md-res"><span>' + (i + 1) + '</span><b>' + h(it.name) + '</b></div>').join('');
      main = '<div class="md-results"><label>' + h(res.kind) + (res.kind === 'layout' ? 's' : ' · ' + h(res.q)) + '</label>' +
             (rows || '<div class="md-empty">' + h(res.msg || 'Nothing found') + '</div>') + '</div>';
    } else {
      main = '<div class="md-pick"><div><label>Car</label><b>' + h(c.has ? c.car : '–') + '</b></div>' +
             '<div><label>Track</label><b>' + h(c.has ? c.track : '–') + '</b>' + (c.layout ? '<small>' + h(c.layout) + '</small>' : '') + '</div>' +
             '<div class="md-small"><div><label>Session</label><b>Test drive</b></div><div><label>Car damage</label><b>' + (c.damage === 'off' ? 'Off' : 'On') + '</b></div>' +
             '<div><label>Favourite</label><b>' + (c.fav ? '★ Saved' : '–') + '</b></div></div></div>';
    }
    const last = m.last ? '<div class="md-last"><label>Last start → in the car</label><b>' + h(String(m.last.secs)) + ' s</b></div>' : '';
    this.sig = main + last;
    if (this.html !== this.sig) { this.html = this.sig; setHTML(this.el, '<div class="g-top"><span>My Drive</span><span>Choose on the Stream Deck, then press <b>START</b></span></div>' + main + last + '<div class="g-foot"><span>Car <b>No. 4</b></span><span>EXIT MY DRIVE</span></div>'); }
    else if (m.busy === 'start') { const b = this.el.querySelector('.md-busy small'); if (b) b.textContent = Math.round((Date.now() - this.busyAt) / 1000) + ' s'; }
  },
};
MyDrive.init();
