'use strict';
// HOME's frame of the top screen, 10 times a second: the flag (the one table shared with the light box and the edge glow),
// the switch between HOME and the race screen, and the "rig fixed" notice. W2-2 retired the old in-car grid and Drive v1 (and the
// garage view they made): HOME shows whenever he is not driving, the race screen (race.html, app/pages/race.js) while he is.

const UI = {
  lastDom: 0,

  init() {
    RaceSwitch.init();
    data.on('state', (st, ch) => { if (ch.health) this.health(st.health); });   // W0-5: irdash pushes it; no timer here
    document.addEventListener('visibilitychange', () => { this.lastDom = 0; });
    const loop = now => {
      try {
        if (!document.hidden && now - this.lastDom >= 100) {
          this.lastDom = now; this.slow();
          if (typeof Guest !== 'undefined') { try { Guest.frame(); } catch (e) { console.error(e); } }
        }
      } catch (e) { console.error(e); }
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  },

  live() { return L.connected && performance.now() - L.lastFrameAt < 3000; },

  /* ---------- watchdog notices ---------- */
  health(h) {
    if (!h) return;
    // Stream Deck reconnects are fixed silently (still in irdash.log); only other repairs get a notice
    const ev = (h.events || []).filter(e => !/stream deck/i.test(e.msg)), last = ev[ev.length - 1];
    const t = $('toast');
    if (!L.demo && last && Date.now() - new Date(last.t).getTime() < 10 * 60 * 1000) {
      setHTML(t, '<b>Rig fixed</b>' + esc(last.msg));
      t.hidden = false;
    } else t.hidden = true;
  },

  /* ---------- 10 Hz ---------- */
  slow() {
    try {
      const live = this.live();
      RaceSwitch.tick(performance.now());
      this.overlay(live);
      if (live) this.flags(L.v.SessionFlags >>> 0); else this.flagName = '';
    } catch (e) { console.error(e); }
  },

  // HOME covers the screen except while the race screen shows
  overlay(live) {
    setCls($('overlay'), RaceSwitch.on ? '' : 'show');
    if (!live) setText('ovTitle', Conn.status === 'noserver' ? 'Paddock program not running' : 'Waiting for iRacing');
  },

  flags(f) {
    const F = { yellowWaving: 0x100, oneToGreen: 0x200, debris: 0x40, caution: 0x4000, cautionWaving: 0x8000, dq: 0x20000 };
    const has = k => (f & F[k]) !== 0;
    // the light box (tools\df8-flags.js) decides with this same table, so Paddock and the lights always show the same flag
    // FLAG TABLE START - the same text is in tools\df8-flags.js
    const FLAG_MIN_MS = 3000;       // a 1 s blue is real: every flag shows at least this long
    const FLAG_ORDER = [['black', 0x30000], ['orange', 0x100000], ['warning', 0x80000], ['checkered', 0x1], ['red', 0x10], ['yellow', 0xC148], ['blue', 0x20], ['white', 0x2], ['green', 0x4]];
    // FLAG TABLE END
    const st = this.flagSt || (this.flagSt = { was: {}, until: {} }), now = Date.now();
    let flag = '';
    for (const [name, mask] of FLAG_ORDER) {
      const on = (f & mask) !== 0;
      if (on && !st.was[name]) st.until[name] = now + FLAG_MIN_MS;
      st.was[name] = on;
      if (!flag && (on || now < (st.until[name] || 0))) flag = name;
    }
    this.flagName = flag;           // the edge glow (flaglow.js) and the race screen's flash show this same flag
    if (flag === 'black') return has('dq') ? this.setFlag('black', 'Disqualified') : this.setFlag('black', 'Black flag', true);
    if (flag === 'orange') return this.setFlag('meatball', 'Repair');
    if (flag === 'warning') return this.setFlag('black', 'Warning');
    if (flag === 'checkered') return this.setFlag('checkered', 'Finish');
    if (flag === 'red') return this.setFlag('red', 'Red flag');
    if (flag === 'yellow') {
      if (has('caution') || has('cautionWaving')) return this.setFlag('yellow', 'Caution', has('cautionWaving'));
      return this.setFlag('yellow', has('debris') ? 'Debris' : 'Yellow', has('yellowWaving'));
    }
    if (flag === 'blue') return this.setFlag('blue', 'Blue flag', true);
    if (flag === 'white') return this.setFlag('white', 'Last lap');
    if (flag === 'green') return this.setFlag('green', 'Green');
    this.setFlag('', has('oneToGreen') ? 'One to green' : isRace() ? 'Grid' : 'Running');   // not green yet: the box is dark too
  },
  // the words for the flag (the grid that showed them is gone; tests\df8-flags-test.ps1 reads them)
  setFlag(cls, text, blink) { this.flagCls = cls; this.flagText = text; this.flagBlink = !!blink; },
};

// THE SWITCH (W2-2): the race screen covers HOME while irdash says he is driving AND irdash answers AND this page has a fresh frame
// AND it is not a replay; HOME comes back once any of those has failed for 5 s, so a tow or a reset does not flick it, and a hung sim,
// an irdash restart or a replay in the sim brings HOME (and its "Paddock program not running") back. While driving, the one stream
// carries only the race set; when irdash already says driving at the first frame, the stream goes straight from idle to that set.
// Friends mode keeps its own in-car view (guest.js). ?race=1 shows it whatever the rig says (tests, previews).
const RaceSwitch = {
  on: false, offSince: 0, forced: QS.has('race'), el: null,

  init() {
    data.on('connect', () => this.syncSet());
    this.el = $('raceHost');
    if (!this.el) return;
    // made here, after data.js has run, so the page inside borrows HOME's one connection instead of opening its own
    const f = document.createElement('iframe'); f.id = 'raceFrame'; f.src = 'race.html'; f.title = 'Race screen';
    this.el.appendChild(f);
  },

  guest() { const g = data.state && data.state.guest; return !!(g && g.active); },
  want() {
    if (this.forced) return true;
    return !this.guest() && !!(data.rig.driving && data.online && UI.live() && !L.v.IsReplayPlaying);
  },

  tick(now) {
    const want = this.want();
    if (want) this.offSince = 0;
    else if (this.on && !this.offSince) this.offSince = now;
    const on = want || (this.on && now - this.offSince < 5000);
    if (on !== this.on) {
      this.on = on;
      if (this.el) this.el.hidden = !on;
      document.body.classList.toggle('race-on', on);
    }
    this.syncSet();
  },
  // the stream's set: the race set while it shows, or as soon as irdash says driving (also asked at the first frame, data.js
  // 'connect', so a session that starts with him already driving opens one stream with the race set, not HOME's variables first)
  syncSet() {
    const race = this.on || (!this.guest() && data.online && !!data.rig.driving);
    if (!L.demo && (data.set === 'race') !== race) Conn.layout(race);
  },
};
window.UI = UI; window.RaceSwitch = RaceSwitch;      // the race screen inside the frame reads these (the flag, shown or not)

UI.init();
Conn.start();

// One calm line on the top screen while RESET CAR waits for the car to stop.
// The same bar sits over HOME, the race screen and the Friends drive view.
const TowWait = {
  init() {
    const el = document.createElement('div');
    el.id = 'towWait';
    el.hidden = true;
    el.textContent = 'Reset car · waiting for the car to stop';
    document.body.appendChild(el);
    data.on('state', (st, ch) => { if (ch.tow && st.tow) el.hidden = !st.tow.on; });     // W0-5: pushed by irdash
  },
};
TowWait.init();

// One line on the top screen while kids mode is on. The lock itself is irdeck; this only shows it.
const KidsMode = {
  init() {
    const el = document.createElement('div');
    el.id = 'kidsMode';
    el.hidden = true;
    el.textContent = 'KIDS MODE  -  keyboard and deck locked  -  to unlock press KIDS, then HOME';
    document.body.appendChild(el);
    data.on('state', (st, ch) => {                  // W0-5: pushed by irdash
      const r = st.kids; if (!ch.kids || !r) return;
      el.hidden = !r.on;
      if (r.on && r.text) el.textContent = r.text;
    });
  },
};
KidsMode.init();
