/* HOME (W3-3, docs/rework/PLAN.md 4.1): the top screen between sessions. A page module for the shell (W3-1):
     mount(el, ctx)  ctx = { data, Fmt, go, close, banner, kidsOn(), driving() };  unmount();  onState(state, changed)
   Copied from the Porsche watch face (time first, few complications, empty space on purpose), StartLight / iRacePlan
   (my series only, local time, one countdown) and Formula E's "quiet, then data as it heats up" (the gold ring).
   Zones: the clock (W3-2's Clock) in the middle; NOW / NEXT left (the session he is in, or his next races: /official);
   MY RACES right (his last three drives: /api/library) and LAST RACE; the RIG band at the bottom (the doctor's cached
   result and the apps, never a fresh check) with the one button: RIG ON, DRIVE (in the session, or his last car and track) or START.
   Nothing here polls: three answers at mount, then only when irdash says something changed (the state push, onList).
   The clock is local time. Never shown: the real-world TV schedule, developer text, phone pairing, statistics tiles. */
const DOT = ' · ';
const OFFLINE = 'Paddock is not running. Press HOME on the deck.';
const AFTER_MS = 10 * 60 * 1000;            // the "your race" card stays for ten minutes after the drive
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const num = x => typeof x === 'number' && isFinite(x);

let Clock = null;                          // W3-2's clock (app/lib/clock.js), loaded once
let seen = null;                           // the newest drive seen { id, at }: module state, so it outlives an unmount

// ---------------------------------------------------------------- pure helpers (tests import them)
const pad = n => (n < 10 ? '0' : '') + n;
// the next race's countdown: readout within 24 h, the gold ring over the last 30 minutes (0 at 30 min, 1 at the start)
export function countdown(startMs, nowMs) {
  if (!num(startMs) || !num(nowMs)) return { secs: null, readout: null, ring: null };
  const secs = Math.floor((startMs - nowMs) / 1000);
  if (secs <= 0 || secs > 86400) return { secs: secs, readout: null, ring: null };
  const h = Math.floor(secs / 3600), m = Math.floor(secs % 3600 / 60), s = secs % 60;
  return { secs: secs, readout: 'NEXT GREEN FLAG ' + h + ':' + pad(m) + ':' + pad(s), ring: secs <= 1800 ? 1 - secs / 1800 : null };
}
// local wall time and day: 18:15 / Today, Tomorrow, Sat 15 Nov (the old HOME showed New York time; PLAN: local)
export function localTime(ms) { const d = new Date(ms); return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
export function localDay(ms, nowMs) {
  const d = new Date(ms), n = new Date(nowMs), key = x => x.getFullYear() + '-' + x.getMonth() + '-' + x.getDate();
  if (key(d) === key(n)) return 'Today';
  const t = new Date(n); t.setDate(t.getDate() + 1); if (key(d) === key(t)) return 'Tomorrow';
  const y = new Date(n); y.setDate(y.getDate() - 1); if (key(d) === key(y)) return 'Yesterday';
  return d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' }).replace(',', '');
}
// "P4 of 19" (MY RACES) or "P3 from P9" (the after-drive card, from = true); 0 = not known: say nothing about the place
export function place(r, from) {
  if (!r || !(r.finish > 0)) return '';
  const of = r.field > 0 ? ' of ' + r.field : '';
  return 'P' + r.finish + (from && r.start > 0 ? ' from P' + r.start : of);
}

// ---------------------------------------------------------------- the page
const H = {
  el: null, ctx: null, offs: [], tick: 0, wake: 0, st: {}, online: true,
  off: null, lib: null, home: null,          // /official, /api/library, /home
  act: null, busyUntil: 0, failUntil: 0, failMsg: '', busyWord: '', dry: false, sent: [],
  shownReadout: undefined, shownRing: undefined, bannerText: undefined, offAsked: 0,

  now() { if (Clock && Clock.now) { const v = Clock.now(); return v instanceof Date ? v.getTime() : +v; } return Date.now(); },
  $(c) { return H.el ? H.el.querySelector(c) : null; },

  mount(el, ctx) {
    H.el = el; H.ctx = ctx; H.offs = []; H.shownReadout = undefined; H.shownRing = undefined; H.bannerText = undefined;
    if (!document.querySelector('link[data-page="home"]')) {
      const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = new URL('./home.css', import.meta.url).href; l.dataset.page = 'home';
      document.head.appendChild(l);
    }
    el.innerHTML =
      '<div class="home">' +
      '<section class="zone now" aria-label="Next race"><h2 class="lbl">Next race</h2><div class="rows"></div></section>' +
      '<section class="zone dial" aria-label="Clock"></section>' +
      '<section class="zone mine" aria-label="My races"><h2 class="lbl">My races</h2><div class="after" hidden></div><div class="rows"></div>' +
      '<button type="button" class="btn last" hidden>Last race</button></section>' +
      '<section class="zone rig" aria-label="Rig"><span class="dot"></span><p class="line"></p>' +
      '<button type="button" class="btn fix" hidden>Fix it</button><button type="button" class="btn gold one" hidden></button></section>' +
      '</div>';
    H.$('.last').addEventListener('click', () => ctx.go('review'));
    H.$('.fix').addEventListener('click', () => H.fix());
    H.$('.one').addEventListener('click', () => H.go(H.$('.one').homeAct));
    H.$('.after').addEventListener('click', e => { if (e.target.closest('button')) ctx.go('review'); });
    const d = ctx.data;
    H.st = d.state || {}; H.online = d.online !== false;
    H.offs.push(d.on('online', on => { H.online = !!on; H.draw(); }));
    H.offs.push(d.onList('races', () => H.loadLib()));
    H.offs.push(d.onList('sessions', () => H.loadHome()));
    H.loadClock();
    H.loadOfficial(); H.loadLib(); H.loadHome();
    H.tick = setInterval(H.second, 1000);      // the countdown and the fade; it asks irdash nothing
    H.draw();
  },

  unmount() {
    clearInterval(H.tick); clearTimeout(H.wake); H.tick = 0;
    H.offs.forEach(f => { try { if (typeof f === 'function') f(); } catch (e) { } }); H.offs = [];
    if (Clock && Clock.unmount) { try { Clock.unmount(); } catch (e) { } }
    if (H.ctx && H.bannerText) H.ctx.banner(null);
    H.el = null;
  },

  onState(st, ch) {
    H.st = st || {};
    if (!ch || ch.health || ch.doctor || ch.rig || ch.kids || ch.session || ch.mydrive) H.draw();
  },

  // ---- the three answers; each asked once and again only when irdash says it changed ----
  async loadClock() {
    try { const m = await import('../lib/clock.js'); Clock = m.Clock || m.default || window.Clock || null; }
    catch (e) { Clock = window.Clock || null; }
    if (!H.el || !Clock || !Clock.mount) return;
    Clock.mount(H.$('.dial'), { size: 720, ring: null, readout: null });
    H.shownReadout = null; H.shownRing = null;
    H.draw();          // Clock.now is the clock from here on (tests fix it)
  },
  async loadOfficial() {
    H.offAsked = H.now();
    try { H.off = await H.ctx.data.json('/official', 60000); } catch (e) { }
    if (H.el) H.draw();
  },
  async loadLib() { try { H.lib = await H.ctx.data.json('/api/library', 0); } catch (e) { } if (H.el) { H.noteNewest(); H.draw(); } },
  async loadHome() { try { H.home = await H.ctx.data.json('/home', 30000); } catch (e) { } if (H.el) H.draw(); },

  // ---- NOW / NEXT ----
  races() {
    const o = H.off, rows = [], key = {};
    if (!o || !o.loaded) return rows;
    const add = r => { if (!r || !r.t) return; const k = r.series + '|' + r.t; if (key[k]) return; key[k] = 1; rows.push(r); };
    add(o.next);
    // more starts of his series (the same rows the OFFICIAL screen has); without a series of his, only the one
    if (o.nextMine) (o.days || []).forEach(d => (d.rows || []).forEach(r => { if (r.mine) add(r); }));
    rows.sort((a, b) => Date.parse(a.t) - Date.parse(b.t));
    return rows.slice(0, 4);
  },
  upcoming() { const now = H.now(); return H.races().find(r => Date.parse(r.t) > now) || null; },

  drawNow() {
    const z = H.$('.now'); if (!z) return;
    const lbl = z.querySelector('.lbl'), box = z.querySelector('.rows'), rig = (H.ctx.data.rig || {}), s = H.st.session;
    if (rig.sessionOn && s && s.WeekendInfo) {
      lbl.textContent = 'Now';
      const wi = s.WeekendInfo, di = s.DriverInfo || {}, me = (di.Drivers || []).find(x => String(x.CarIdx) === String(di.DriverCarIdx)) || {};
      const track = wi.TrackDisplayName || wi.TrackName || '', next = H.off && H.off.next;
      const series = next && track && String(next.track || '').toLowerCase().indexOf(String(track).toLowerCase().split(' ')[0]) === 0 ? next.series : '';
      box.innerHTML = '<div class="nx big"><div class="t">' + esc(H.ctx.Fmt.sessionName(wi.EventType || '')) + '</div>' +
        (series ? '<div class="s">' + esc(series) + '</div>' : '') + '<div class="s">' + esc(track) + '</div>' +
        '<div class="d">' + esc(me.CarScreenName || '') + '</div><div class="d">In the session since ' + esc(H.sinceText()) + '</div></div>';
      return;
    }
    const rows = H.races(), now = H.now(), up = H.upcoming();
    lbl.textContent = H.off && H.off.next && !H.off.nextMine ? 'Next race you can join' : 'Next race';
    if (!rows.length) { box.innerHTML = '<div class="none">' + (H.off && H.off.loaded ? 'No race of your series this week' : 'No race schedule yet') + '</div>'; return; }
    box.innerHTML = rows.map(r => {
      const t = Date.parse(r.t), big = r === up, past = t <= now, cd = countdown(t, now);
      const time = big && cd.ring != null ? 'in ' + Math.floor(cd.secs / 60) + ':' + pad(cd.secs % 60) : localTime(t);
      return '<div class="nx' + (big ? ' big' : '') + (past ? ' past' : '') + '" data-t="' + t + '">' +
        (big ? '<div class="when">' + esc(localDay(t, now)) + (r.est ? DOT + 'time estimated' : '') + '</div>' : '') +
        '<div class="t' + (big && cd.ring != null ? ' soon' : '') + '">' + esc(time) + (big ? '' : DOT + esc(r.tiny || r.series)) + '</div>' +
        (big ? '<div class="s">' + esc(r.series) + '</div>' : '') +
        '<div class="d">' + esc(r.trackShort || r.track) + (big && r.carShort ? DOT + esc(r.carShort) : '') + '</div></div>';
    }).join('');
  },
  sinceText() { const a = H.ctx.data.at ? H.ctx.data.at('session') : 0; return localTime(a || H.now()); },

  // ---- MY RACES and the after-drive card ----
  noteNewest() {
    const r = H.lib && H.lib.races && H.lib.races[0]; if (!r) return;
    const end = (r.startMs || 0) + (r.sec || 0) * 1000;
    if (!seen) seen = { id: r.id, at: end };                         // the first look: an old drive is not news
    else if (seen.id !== r.id) seen = { id: r.id, at: Math.max(end, H.now()) };   // a new drive arrived while HOME was up
  },
  afterDrive() {
    const r = H.lib && H.lib.races && H.lib.races[0];
    if (!r || !seen || seen.id !== r.id || H.ctx.driving()) return null;
    const end = (r.startMs || 0) + (r.sec || 0) * 1000, from = Math.max(end, seen.at);
    return H.now() - from < AFTER_MS ? r : null;
  },
  drawMine() {
    const z = H.$('.mine'); if (!z) return;
    const F = H.ctx.Fmt, races = (H.lib && H.lib.races) || [], box = z.querySelector('.rows'), card = z.querySelector('.after'), now = H.now();
    const a = H.afterDrive();
    if (a) {
      const p = place(a, true);
      const say = a.isRace ? 'Your race: ' + (p || ((a.laps || 0) + ' laps' + (a.best > 0 ? ', best ' + F.lap(a.best) : '')))
        : 'Your ' + F.sessionName(a.type).toLowerCase() + ': ' + (a.laps || 0) + ' laps' + (a.best > 0 ? ', best ' + F.lap(a.best) : '');
      card.innerHTML = '<div class="s">' + esc(say) + '</div><button type="button" class="btn">Review</button>';
      card.hidden = false;
    } else { card.hidden = true; card.innerHTML = ''; }
    if (!races.length) box.innerHTML = '<div class="none">No drives recorded yet</div>';
    else box.innerHTML = races.slice(0, a ? 2 : 3).map(r => {
      const p = place(r), what = r.isRace ? (p || 'Race') : F.sessionName(r.type) + DOT + (r.laps || 0) + ' laps';
      return '<div class="mr" data-id="' + esc(r.id) + '"><div class="s">' + esc(r.track) + '</div><div class="d">' + esc(localDay(r.startMs, now)) + DOT + '<span class="res">' + esc(what) + '</span></div></div>';
    }).join('');
    H.$('.last').hidden = !races.length || !!a;
  },

  // ---- the RIG band: one line from the doctor's cached result and the apps ----
  apps() { const m = {}; ((H.st.health && H.st.health.apps) || []).forEach(x => { m[x.id] = x; }); return m; },
  drawRig() {
    const z = H.$('.rig'); if (!z) return;
    const dot = z.querySelector('.dot'), line = z.querySelector('.line'), fix = z.querySelector('.fix');
    const apps = H.apps(), doc = H.st.doctor || null;
    let say = null, bad = false, canFix = false;
    if (!H.online) { say = '<span class="w">Not connected to Paddock</span>'; dot.className = 'dot off'; fix.hidden = true; line.innerHTML = say; return; }
    if (apps.ui && apps.ui.state !== 'ok') { say = 'The rig is off. Press RIG ON.'; bad = true; }
    else if (doc && doc.ask) { say = esc(doc.ask); bad = true; canFix = true; }
    else {
      const worst = doc && (doc.items || []).find(i => i.state && i.state !== 'ok' && i.state !== 'warn');
      const offApp = ['deck', 'cc', 'overlays'].map(k => apps[k]).find(x => x && x.state !== 'ok');
      if (worst) { say = esc(worst.detail || worst.name); bad = true; canFix = true; }
      else if (offApp) { say = esc(offApp.name) + ' is off.'; bad = true; canFix = true; }
    }
    if (!say) {
      const words = [['ui', 'iRacing'], ['deck', 'deck'], ['cc', 'spotter'], ['overlays', 'overlays']].filter(w => apps[w[0]]).map(w => w[1]);
      say = '<span class="ok">Rig ready</span>' + (words.length ? '<span class="w">' + DOT + words.join(DOT) + '</span>' : '');
    }
    dot.className = 'dot' + (bad ? ' bad' : '');
    line.innerHTML = say;
    fix.hidden = !canFix; fix.disabled = H.ctx.kidsOn() || !!(H.ctx.data.rig || {}).sessionOn;
  },
  // FIX IT: the doctor runs again and makes the fixes it safely can (it never acts while a session is on)
  async fix() { const b = H.$('.fix'); if (!b || b.disabled) return; b.disabled = true; await H.send('doctor', ''); setTimeout(() => { if (H.el) H.drawRig(); }, 4000); },

  // ---- the one button. Carried over from v2/home.js next()/go() unchanged in behaviour: RIG ON when the iRacing UI is off; DRIVE
  // (the deck's GO) once a session is loaded; else LAST DRIVE (that exact car and track through MY DRIVE: choose, check, start);
  // else START (test drive the last one). Its plain-words failure goes on the button. ----
  short(car) { return String(car || '').replace(/^Chevrolet /, ''); },
  pick() {
    const apps = H.apps(), rig = H.ctx.data.rig || {}, l = H.home && H.home.last;
    if (!H.online) return { key: 'rig-on', label: 'Rig on', off: true };
    if (!H.st.health) return null;
    if (apps.ui && apps.ui.state !== 'ok') return { key: 'rig-on', label: 'Rig on', busy: 'Turning on' };
    if ((apps.sim && apps.sim.state === 'live') || rig.sessionOn) return { key: 'go', label: 'Drive', busy: 'Getting in' };
    // the old HOME said "Last drive"; the deck's key for it is DRIVE (PLAN 4.6), and LAST RACE (REVIEW) sits on this screen too
    if (l && l.car && l.track) return { label: 'Drive', car: l.car, track: l.track, sub: H.short(l.car) + DOT + l.track, busy: 'Choosing car and track' };
    return { key: 'test-drive-last', label: 'Start', busy: 'Loading the session' };
  },
  drawButton() {
    const b = H.$('.one'); if (!b) return;
    const act = H.pick(); H.act = act;
    if (!act) { b.hidden = true; return; }
    b.homeAct = act;
    const now = Date.now(), busy = now < H.busyUntil, failed = !busy && now < H.failUntil;
    b.hidden = false; b.className = 'btn gold one' + (busy ? ' busy' : failed ? ' failed' : '');
    b.disabled = !!act.off || H.ctx.kidsOn() || busy;
    b.setAttribute('data-car', act.car || ''); b.setAttribute('data-track', act.track || '');
    const sub = busy ? '' : failed ? (H.failMsg || 'Could not get going') : (act.sub || '');
    b.innerHTML = esc(busy ? (H.busyWord || act.busy || '') : act.label) + (sub ? '<span>' + esc(sub) + '</span>' : '');
    // the label changes back by itself when the busy or failed time is over (no timer while nothing happens)
    clearTimeout(H.wake);
    const until = busy ? H.busyUntil : failed ? H.failUntil : 0;
    if (until) H.wake = setTimeout(() => { if (H.el) H.drawButton(); }, until - now + 20);
  },

  // one irdash call, the same ones the deck makes (tests: dry = recorded, not sent)
  async send(c, a) {
    H.sent.push({ c: c, a: a || '' });
    if (H.dry) return true;
    try { await H.ctx.data.fetch('/api/do?c=' + encodeURIComponent(c) + (a ? '&a=' + encodeURIComponent(a) : '')); return true; } catch (e) { return false; }
  },
  // the same id irdeck and irdash give a recent drive (MY DRIVE: FNV-1a of the lower-case "car|track", prefixed r)
  fnv(kind, text) {
    let x = 2166136261; const s = String(text || '').toLowerCase();
    for (let i = 0; i < s.length; i++) { x ^= s.charCodeAt(i); x = Math.imul(x, 16777619) >>> 0; }
    return kind + ('00000000' + (x >>> 0).toString(16)).slice(-8);
  },
  async mydrive() { return (await fetch('/mydrive', { cache: 'no-store' })).json(); },
  busy(word) { H.busyWord = word; H.drawButton(); },
  fail(msg, ms) { H.busyUntil = 0; H.failMsg = msg; H.failUntil = Date.now() + ms; H.drawButton(); },

  async go(pressedAct) {
    const act = pressedAct || H.act;
    if (!act || act.off || H.ctx.kidsOn() || Date.now() < H.busyUntil) return;
    H.busyUntil = Date.now() + 25000; H.busy(act.busy);
    if (!act.car) { await H.send('key', act.key); return; }
    // LAST DRIVE: choose that exact car and track, make sure MY DRIVE has them chosen, only then start
    const id = H.fnv('r', act.car + '|' + act.track);
    await H.send('mdpick', id);
    let chosen = H.dry;
    for (let i = 0; i < 24 && !chosen; i++) {
      await new Promise(r => setTimeout(r, 250));
      try { const m = await H.mydrive(); chosen = !!(m.choice && m.choice.has && m.choice.car === act.car && m.choice.track === act.track); } catch (e) { }
    }
    if (!chosen) { H.fail("Couldn't pick that car and track. Pick it in MY DRIVE.", 8000); return; }
    // an old "failed" from a few seconds ago must not count as this press's result
    let stale = null;
    if (!H.dry) { try { const m0 = await H.mydrive(); if (m0.phase === 'failed') stale = m0.msg || ''; } catch (e) { } }
    H.busy('Loading the session');
    await H.send('mdstart', '');
    if (H.dry) return;
    // Peter cannot see the log: when START fails, MY DRIVE's own plain-words reason ("iRacing's list has no ...") goes on the button
    let ran = false;
    for (let i = 0; i < 300; i++) {
      await new Promise(r => setTimeout(r, 1000));
      let m; try { m = await H.mydrive(); } catch (e) { continue; }
      if (m.driving || m.phase === 'joining' && !m.busy) break;
      if (m.busy === 'start' || m.phase === 'setup' || m.phase === 'loading' || m.phase === 'joining') ran = true;
      if (m.phase === 'failed' && m.msg && (ran || m.msg !== stale)) { H.fail(m.msg, 12000); return; }
      if (ran && !m.busy && m.phase !== 'failed') break;   // finished without a failure
    }
  },

  // ---- drawing ----
  draw() {
    if (!H.el) return;
    const kids = H.ctx.kidsOn(), k = H.st.kids;
    const text = !H.online ? OFFLINE : kids ? ((k && k.text) || 'Kids mode is on') : null;
    if (text !== H.bannerText) { H.bannerText = text; H.ctx.banner(text); }
    H.drawNow(); H.drawMine(); H.drawRig(); H.drawButton(); H.second();
  },
  // once a second: the clock's readout and ring, the "in 12:34" row, rows that have just passed, the end of the after-drive card
  second() {
    if (!H.el) return;
    const now = H.now(), up = H.upcoming(), cd = countdown(up ? Date.parse(up.t) : NaN, now);
    const ring = cd.ring == null ? null : Math.round(cd.ring * 1000) / 1000;
    if (Clock && Clock.set && (cd.readout !== H.shownReadout || ring !== H.shownRing)) { H.shownReadout = cd.readout; H.shownRing = ring; Clock.set({ ring: ring, readout: cd.readout }); }
    const box = H.$('.now .rows');
    if (box && box.querySelector('[data-t]')) {
      const big = box.querySelector('.nx.big'), want = up ? String(Date.parse(up.t)) : '';
      const stale = (big ? big.dataset.t : '') !== want || [...box.querySelectorAll('.nx')].some(x => !x.classList.contains('past') && +x.dataset.t <= now);
      if (stale || (cd.ring != null)) H.drawNow();
    }
    // the shown race has started and nothing else is known: ask /official again (its 60 s cache keeps this to one a minute at most)
    if (H.off && H.off.loaded && !up && H.races().length && now - H.offAsked > 60000) H.loadOfficial();
    const card = H.$('.after');
    if (card && !card.hidden && !H.afterDrive()) H.drawMine();
  }
};

export const Home = H;          // tests reach the button logic and the clock through this
export default {
  name: 'home', title: 'HOME',
  mount(el, ctx) { H.mount(el, ctx); },
  unmount() { H.unmount(); },
  onState(state, changed) { H.onState(state, changed); }
};
