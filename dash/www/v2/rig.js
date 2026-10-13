'use strict';
// Rig Doctor on the top screen, the one-line rig check on the idle screen, and a small notice when the Stream Deck
// changes the overlays. irdash /doctor and /overlays say what to show; nothing here is clickable.
//  - RIG DOCTOR key (deck OVERLAYS screen, or irdeck doctor): /doctor says show=true for a minute -> the list appears
//  - the idle screen's footer line is always the last result and the last start/load times
//  - never while you are driving (irdash sends show=false then, and the list hides itself too)
const Rig = {
  el: null, seq: -1, shownAt: 0, ovAt: undefined, toastTimer: 0,

  init() {
    this.poll(); setInterval(() => this.poll(), 1500);
    this.ovPoll(); setInterval(() => this.ovPoll(), 1500);
  },

  driving() { return UI.live() && !!(L.v && L.v.IsOnTrack); },

  async poll() {
    if (document.hidden) return;
    // nothing here is needed while you drive: no requests, and the list goes away
    if (this.driving()) { if (this.el) { this.el.remove(); this.el = null; } return; }
    let d;
    try { d = await (await fetch('/doctor', { cache: 'no-store' })).json(); } catch (e) { return; }
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

  // the idle screen's line above the footer: "All good", or one short line when something really needs you. The doctor
  // fixes most things itself; the rest stays in the list (RIG DOCTOR key) and does not nag here. Then the timings.
  idle(d) {
    const el = $('idleRig'); if (!el) return;
    const ask = d.ask || '';
    const cls = ask ? 'bad' : d.ranAt ? 'ok' : '';
    let h = '<span class="rg-dot ' + cls + '"></span><b>Rig check</b> ' + (ask ? '<em>' + esc(ask) + '</em>' : d.ranAt ? 'All good' : 'checking…');
    if (d.timings) h += '<small>' + esc(d.timings) + '</small>';
    setHTML(el, h);
  },
  render(d) {
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
  async ovPoll() {
    if (document.hidden) return;
    if (this.driving() && Date.now() - (this.ovLast || 0) < 6000) return;   // a slower look while driving: only the notice that a change waits for the car to stop
    this.ovLast = Date.now();
    let o;
    try { o = await (await fetch('/overlays', { cache: 'no-store' })).json(); } catch (e) { return; }
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
