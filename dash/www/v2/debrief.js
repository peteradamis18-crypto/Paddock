'use strict';
// Post-session debrief. Collects a stint while you drive (from the frames core.js already receives) and,
// when you get out of the car or leave the session, puts the SESSION REVIEW on the top screen (sessionreview.js, card C-40:
// timing table with iRacing's sectors, map of where the time went, optimal lap, consistency, data notes, the laps-saved bar).
// This file decides WHEN: it watches the stint, keeps the race extras (position, incidents) and runs the laps-saved bar.
// The review stays up until you get back in the car, until clicked, or 15 minutes. ?debrief=demo shows a sample.
const Debrief = {
  SHOW_MS: 15 * 60 * 1000,
  st: null,                // current stint
  el: null, timer: null,

  frame(v) {
    if (L.demo || v.IsReplayPlaying) return;
    const on = !!v.IsOnTrack;
    if (on && this.el) this.hide();
    if (this.st && this.st.sessKey !== L.sessKey) this.st = null;     // practice -> race etc.: lap list was reset
    if (on && !this.st) this.start(v);
    if (!this.st) return;
    if (on) this.track(v);
    // D-03: the after-session screen is debrief-v4.js now. This file keeps tracking the stint (its demo and the
    // Session Review hand-off still use summarise/show) but it no longer puts a summary up by itself.
  },

  start(v) {
    this.st = {
      onTrack: true, t0: v.SessionTime, wall0: Date.now(), sessKey: L.sessKey, type: sessionType(), race: isRace(),
      track: S.track.name + (S.track.config ? ' · ' + S.track.config : ''), car: (S.drivers.get(S.me) || {}).car || '',
      inc0: v.PlayerCarMyIncidentCount, inc: v.PlayerCarMyIncidentCount, pos0: null, pos: null,
    };
  },

  // the race extras: where he started and where he is, and the incidents since he got in
  track(v) {
    const s = this.st;
    if (isNum(v.PlayerCarMyIncidentCount)) s.inc = v.PlayerCarMyIncidentCount;
    const cp = v.PlayerCarClassPosition > 0 ? v.PlayerCarClassPosition : (v.PlayerCarPosition > 0 ? v.PlayerCarPosition : null);
    if (cp) { if (s.pos0 == null) s.pos0 = cp; s.pos = cp; }
  },

  end(why) {
    const s = this.st; this.st = null;
    if (!s) return;
    const laps = L.laps.filter(l => l.at >= s.t0 && isNum(l.time) && l.time > 0);
    // no full lap is still a drive (Peter 2026-10-18 "just show me the data"): the review shows what there is, and ALL THE DATA
    // The saved-laps panel is part of this review: when the session ends, or when he gets out after a race.
    // Getting out of practice is the plain review. Never a separate window, and never while he is still driving.
    const review = why === 'session ended' || (why === 'out of the car' && s.race);
    this.show(this.summarise(s, laps), review);
  },

  // called by the 1 s check when the session disappears. If he already got out, the review may be up
  // without the saved-laps strip (practice). A session end still adds it. Getting back in the car hides it.
  // If he closed the review before leaving the session, the same review comes back with the strip: the laps are only
  // known to be saved once the session is over, and the strip is the one thing he needs then.
  last: null,              // the summary he last saw: { r, at, armed }
  lost() {
    if (this.st) { this.end('session ended'); return; }
    if (this.el) {
      if (!this.el.querySelector('#dbReview')) this.armReview(this.el);
      if (this.last) this.last.armed = true;
      return;
    }
    const l = this.last;
    if (l && !l.armed && !l.r.demo && Date.now() - l.at < 20 * 60 * 1000) this.show(l.r, true);
  },

  // What the dashboard itself saw: the race extras, and the laps as the review's fallback when the session file cannot be read.
  summarise(s, laps) {
    const clean = laps.filter(l => l.clean);
    const pool = clean.length ? clean : laps;
    const best = pool.length ? Math.min.apply(null, pool.map(l => l.time)) : null;
    return {
      type: s.type, race: s.race, track: s.track, car: s.car, laps: laps.length, cleanLaps: clean.length, startMs: s.wall0, best,
      rows: laps.map(l => ({ n: l.lap, time: l.time, clean: !!l.clean, why: l.why || '' })),      // why: out / in / pit / off from core.js trackLaps, '' = no reason seen
      inc: isNum(s.inc) && isNum(s.inc0) ? s.inc - s.inc0 : NaN, pos0: s.pos0, pos: s.pos,
      mins: Math.round((Date.now() - s.wall0) / 60000),
    };
  },

  // The review draws itself when its data is there (a second or so): invisible and click-proof until then, and never while he drives.
  show(r, review) {
    this.hide();
    const el = document.createElement('div');
    el.id = 'debrief';
    el.addEventListener('click', () => this.hide());
    document.body.appendChild(el);
    this.el = el;
    this.last = { r, at: Date.now(), armed: !!review };
    this.timer = setTimeout(() => this.hide(), this.SHOW_MS);
    SessionReview.mount(el, {
      id: r.demo ? null : 'last', demo: r.demo ? 'sr-demo.json' : null, live: r, hint: true, alive: () => this.el === el,
      model: r.offline ? SessionReview.liveModel(r) : null,             // offline: do not ask irdash, use the laps the dashboard saw (tests, and a session with no file)
      extras: { race: !!r.race, pos0: r.pos0, pos: r.pos, inc: r.inc },
      noCos: true,                                                      // W-18: the debrief draws its own OPEN IN COSWORTH, so the review footer hides its copy
    }).then(res => {
      if (this.el !== el) return;
      if (!res) { this.hide(); return; }                                // he got back in the car while it loaded
      this.armCosworth(el);
      requestAnimationFrame(() => el.classList.add('on'));
    }).catch(() => { if (this.el === el) this.hide(); });
    if (review) this.armReview(el);
  },

  // W-18: OPEN IN COSWORTH on the debrief, only when Pi Toolbox is installed. It opens the session that just ended
  // (id "last"); the Session Review footer hides its own copy here (noCos), so the debrief shows exactly one.
  armCosworth(el) {
    fetch('/vault', { cache: 'no-store' }).then(r => r.json()).then(j => {
      if (!(j && j.cosworth && j.cosworth.installed) || this.el !== el) return;
      const slot = el.querySelector('#dbReviewSlot') || el;
      const b = document.createElement('button');
      b.type = 'button'; b.id = 'dbCos'; b.textContent = 'OPEN IN COSWORTH';
      b.addEventListener('click', e => {
        e.stopPropagation(); e.preventDefault();
        if (b._busy) return;
        b._busy = true; b.textContent = 'OPENING';
        const say = (t, ms) => { b.textContent = t; setTimeout(() => { b.textContent = 'OPEN IN COSWORTH'; b._busy = false; }, ms); };
        fetch('/vault/open?how=cosworth&id=last', { cache: 'no-store' }).then(r => r.json().catch(() => ({})).then(j => {
          if (r.status === 409) say('NOT WHILE DRIVING', 4000);
          else if (r.status === 404) say('FILE IS GONE', 4000);
          else if (!r.ok) say('COULD NOT OPEN', 4000);
          else if (j && j.action === 'folder') say('PI NOT FOUND', 4000);
          else say(j && j.action === 'busy' ? 'ALREADY OPENING' : 'OPENING IN PI', 4000);
        })).catch(() => say('COULD NOT OPEN', 4000));
      });
      slot.appendChild(b);
    }).catch(() => { });
  },

  // The calm "laps saved" strip at the bottom of the review. KEEP ALL is the default after 60 s (the server does it, so a
  // wheel button does the same thing). CHOOSE opens the Vault on this screen. Clicks here do not close the review.
  revToken: null,
  armReview(el) {
    if (UI.live() && L.v && L.v.IsOnTrack) return;          // the last frame of a dead session can still say on track
    const token = {};
    this.revToken = token;
    let opened = false;
    const pull = async () => {
      if (this.revToken !== token || this.el !== el) return;
      let r;
      try { r = await (await fetch('/vault/review' + (opened ? '' : '?open=1'), { cache: 'no-store' })).json(); }
      catch (e) { setTimeout(pull, 600); return; }
      opened = true;
      if (this.revToken !== token || this.el !== el) return;
      if (!r || r.enabled === false || r.driving || (!r.up && !r.kept && !r.pending)) { this.clearReview(el); return; }
      this.paintReview(el, r);
      if (!r.kept) setTimeout(pull, 400);
    };
    pull();
  },
  clearReview(el) {
    const box = el.querySelector('#dbReview');
    if (box) box.remove();
    el.classList.remove('has-review');
  },
  paintReview(el, r) {
    let box = el.querySelector('#dbReview');
    if (!box) {
      box = document.createElement('div');
      box.id = 'dbReview';
      box.addEventListener('click', e => e.stopPropagation());
      box.innerHTML = '<p><span class="db-rev-line"></span><span class="db-rev-sub"></span></p>' +
        '<button type="button" class="def" id="dbKeepAll">KEEP ALL</button><button type="button" id="dbChoose">CHOOSE</button>';
      box.querySelector('#dbKeepAll').addEventListener('click', e => {
        e.stopPropagation(); e.preventDefault();
        fetch('/api/do?c=vkkeepall', { cache: 'no-store' }).catch(() => { });
      });
      box.querySelector('#dbChoose').addEventListener('click', e => {
        e.stopPropagation(); e.preventDefault();
        fetch('/api/do?c=vkchoose', { cache: 'no-store' }).catch(() => { });
        if (typeof VaultLive !== 'undefined' && VaultLive.openPage) VaultLive.openPage(false);     // const VaultLive is not window.VaultLive
        if (this.el) this.el.style.zIndex = '1';             // the Vault sits under the review; let it through
        this.hide();
      });
      const host = el.querySelector('#dbReviewSlot') || el;
      host.appendChild(box);
      el.classList.add('has-review');
    }
    box.setAttribute('data-default', String(r.defaultMs || 60000));
    box.setAttribute('data-wait', String(r.waitMs || 60000));
    const line = box.querySelector('.db-rev-line'), sub = box.querySelector('.db-rev-sub');
    const keep = box.querySelector('#dbKeepAll'), choose = box.querySelector('#dbChoose');
    if (r.kept) {
      line.textContent = r.line || 'Kept';
      sub.textContent = 'Kept';
      keep.hidden = true; choose.hidden = true;
    } else {
      line.textContent = r.n > 0 ? r.line : 'Checking laps';
      const left = Math.max(0, Math.ceil((r.leftMs || 0) / 1000));
      sub.textContent = (r.pending && left === 0) ? 'Saving' : ('Keeping all in ' + left + ' s');
      keep.hidden = false; choose.hidden = false;
    }
  },

  hide() {
    this.revToken = null;
    clearTimeout(this.timer);
    const el = this.el; this.el = null;
    if (!el) return;
    if (el._srResize) window.removeEventListener('resize', el._srResize);
    el.classList.remove('on');
    setTimeout(() => el.remove(), 700);
  },

  init() {
    // D-03: the automatic after-session trigger moved to debrief-v4.js. This file stays loaded for the Session Review
    // hand-off (DEEP DIVE) and for the ?debrief=demo sample, so screens/tests that open the review directly still work.
    if (/[?&]debrief=demo/.test(location.search)) this.show({
      demo: true, type: 'Race', race: true, track: 'Road Atlanta', car: 'Corvette Z06 GT3.R', laps: 11, cleanLaps: 7, inc: 2, pos0: 9, pos: 5, mins: 17,
      rows: [88.1, 85.2, 84.9, 84.6, 85.8, 84.312, 84.7, 86.9, 84.5, 84.6, 84.4].map((t, i) => ({ n: i + 1, time: t, clean: i !== 0 && i !== 7 })),
    });
  },
};
Debrief.init();
