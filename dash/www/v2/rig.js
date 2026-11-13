'use strict';
// Rig Doctor on the top screen, the one-line rig check on the idle screen, and a small notice when the Stream Deck
// changes the overlays. irdash /doctor and /overlays say what to show; nothing here is clickable.
//  - RIG DOCTOR key (deck OVERLAYS screen, or irdeck doctor): /doctor says show=true for a minute -> the list appears
//  - the idle screen's footer line is always the last result and the last start/load times
//  - never while you are driving (irdash sends show=false then, and the list hides itself too)
const Rig = {
  el: null, seq: -1, shownAt: 0, ovAt: undefined, toastTimer: 0,

  // W0-5: irdash pushes /doctor and /overlays (state parts "doctor", "overlays"); the list shown counts its "checked N s ago" here
  init() {
    data.on('state', (st, ch) => {
      if (ch.doctor && st.doctor) { this.d = st.doctor; this.dAt = Date.now(); this.poll(); }
      if (ch.overlays && st.overlays) this.ovPoll(st.overlays);
    });
    setInterval(() => { if (this.el || this.driving()) this.poll(); }, 1500);
  },

  driving() { return UI.live() && !!(L.v && L.v.IsOnTrack); },

  poll() {
    // nothing here is needed while you drive: the list goes away
    if (this.driving()) { if (this.el) { this.el.remove(); this.el = null; } return; }
    if (!this.d) return;
    const d = Object.assign({}, this.d);
    if (d.age != null) d.age += Math.round((Date.now() - this.dAt) / 1000);
    this.idle(d);
    if (d.show && !this.driving()) {
      if (!this.el) {
        this.el = document.createElement('div'); this.el.id = 'doctor'; document.body.appendChild(this.el);
        requestAnimationFrame(() => this.el && this.el.classList.add('on'));
      }
      this.render(d);
    } else if (this.el) {
      const el = this.el; this.el = null; el.classList.remove('on'); setTimeout(() => el.remove(), 700);
    }
  },

  // HOME's READY panel (home.js drawReady) shows the doctor's one line when something really needs him; the doctor
  // fixes most things itself and the rest stays in the list (RIG DOCTOR key).
  idle(d) {
    this.doc = d;
    if (typeof Home !== 'undefined' && Home.drawReady) Home.drawReady();     // const Home is not window.Home
  },  render(d) {
    const rows = (d.items || []).map(i =>
      '<div class="dr-row ' + esc(i.state) + '"><i></i><div><b>' + esc(i.name) + '</b><span>' + esc(i.detail) + (i.done ? ' &nbsp;·&nbsp; fixed: ' + esc(i.done) : '') + '</span>' +
      (i.fix ? '<em>' + esc(i.fix) + '</em>' : '') + '</div></div>').join('');
    const when = d.running ? 'checking…' : d.age != null ? 'checked ' + d.age + ' s ago' : '';
    const cls = d.bad > 0 ? 'bad' : d.warn > 0 ? 'warn' : 'ok';
    setHTML(this.el,
      '<div class="dr-top"><span>Paddock<em class="dr-sub">Rig Doctor</em></span><span>' + esc(when) + '</span></div>' +
      '<div class="dr-head ' + cls + '"><i></i><b>' + esc(d.headline || '') + '</b></div>' +
      '<div class="dr-list">' + rows + '</div>' +
      '<div class="dr-foot"><span>' + esc(d.timings || '') + '</span></div>');
  },

  // "FUEL switched on", "RACE overlays (6 on)", "waiting for the car to stop" - a few seconds at the top
  ovPoll(o) {
    if (!o) return;
    if (this.ovAt === undefined) { this.ovAt = o.msgAt || ''; return; }       // not for what happened before this page opened
    let text = '';
    if (o.waiting) text = 'Waiting for the car to stop';
    else if (o.pending || o.busy) text = o.msg || 'Updating overlays';
    else if (o.msgAt && o.msgAt !== this.ovAt && o.msg) text = o.msg + (o.restartSecs != null && /updated/i.test(o.msg) ? ' · ' + o.restartSecs + ' s' : '');
    if (o.msgAt) this.ovAt = o.msgAt;
    if (!text) return;
    let t = $('ovlToast');
    if (!t) { t = document.createElement('div'); t.id = 'ovlToast'; t.setAttribute('role', 'status'); document.body.appendChild(t); }
    setHTML(t, '<b>Overlays</b>' + esc(text)); t.classList.add('on');
    clearTimeout(this.toastTimer); this.toastTimer = setTimeout(() => t.classList.remove('on'), 5000);
  },
};
Rig.init();
