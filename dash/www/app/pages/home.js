/* HOME (W3-3, docs/rework/PLAN.md 4.1): the top screen between sessions. A page module for the shell (W3-1):
     mount(el, ctx)  ctx = { data, Fmt, go, close, banner, kidsOn(), driving() };  unmount();  onState(state, changed)
   Copied from the Porsche watch face (time first, few complications, empty space on purpose), StartLight / iRacePlan
   (my series only, local time, one countdown) and Formula E's "quiet, then data as it heats up" (the gold ring).
   Zones: the clock (W3-2's Clock) in the middle; NOW / NEXT left (the session he is in, or his next races: /official, only
   rows irdash marks "his"); MY RACES right (his last three drives: /api/library) and LAST RACE; the RIG band at the bottom
   (the doctor's cached result and the apps, never a fresh check from the page) with the one button: RIG ON, DRIVE (in the
   session, or his last car and track) or START.
   Nothing here polls: three answers at mount, then only when irdash says something changed (the state push, onList).
   The offline and kids banners are the shell's (W3-1); HOME only greys its button then.
   The clock is local time. Never shown: the real-world TV schedule, developer text, phone pairing, statistics tiles. */
const DOT = ' · ';
const AFTER_MS = 10 * 60 * 1000;            // the "your race" card stays for ten minutes
const MEM_KEY = 'paddock.home';
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const num = x => typeof x === 'number' && isFinite(x);

let Clock = null;                          // W3-2's clock (app/lib/clock.js), loaded once

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
// the same track? the words that name the place, as officialcore.cs SameTrack ("Road Atlanta" / "Michelin Raceway Road Atlanta")
const FILLER = new Set('circuit circuito raceway racing race international speedway motorsport motorsports motor park the at of de du des la le and road course full grand prix gp track national ring autodromo autodrome oval layout config short long north south east west club'.split(' '));
const placeWords = s => new Set(String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().split(/[^a-z0-9]+/).filter(w => w.length >= 4 && !FILLER.has(w)));
export function sameTrack(a, b) { const B = placeWords(b); for (const w of placeWords(a)) if (B.has(w)) return true; return false; }

// ---------------------------------------------------------------- what HOME remembers across mounts and a page reload
// (sessionStorage: the 10 minutes of the after-drive card, when the session began; a page reload in those minutes keeps them)
//   driving / driveEnd: the last driving -> not driving edge;  newestId / newestAt: the newest drive in the library and when it
//   first appeared (0 = it was already there);  sessionOn / sessionSince: when the session he is in was loaded (0 = not seen)
const mem = { seen: false, driving: false, driveEnd: 0, newestId: '', newestAt: 0, sessionOn: false, sessionSince: 0 };
function memLoad() { try { const s = JSON.parse(sessionStorage.getItem(MEM_KEY) || 'null'); if (s) Object.assign(mem, s); } catch (e) { } }
function memSave() { try { sessionStorage.setItem(MEM_KEY, JSON.stringify(mem)); } catch (e) { } }
let watching = null;
// one listener for the life of the page (the shell unmounts HOME while he drives, and HOME must still see the drive end)
function watch(data) {
  if (watching === data) return; watching = data;
  data.on('state', observe);
}
// the edges, from any state push (idempotent: the page's onState calls it too, so it never draws with an old answer)
function observe(st) {
  if (!st || !st.rig) return;
  const r = st.rig, now = H.now();
  // the first look of this page: how things are is not an edge (a page opened mid-session does not know when it began)
  if (!mem.seen) { mem.seen = true; mem.driving = !!r.driving; mem.sessionOn = !!r.sessionOn; memSave(); return; }
  let changed = false;
  if (!!r.driving !== mem.driving) {
    mem.driving = !!r.driving; changed = true;
    if (mem.driving) mem.newestAt = 0;                  // a new drive: the card about the last one is over
    else mem.driveEnd = now;
  }
  if (!!r.sessionOn !== mem.sessionOn) { mem.sessionOn = !!r.sessionOn; mem.sessionSince = mem.sessionOn ? now : 0; changed = true; }
  if (changed) memSave();
}

// ---------------------------------------------------------------- the page
const H = {
  el: null, ctx: null, offs: [], tick: 0, wake: 0, st: {}, online: true,
  off: null, lib: null, home: null,          // /official, /api/library, /home
  act: null, busyUntil: 0, failUntil: 0, failMsg: '', busyWord: '', dry: false, sent: [],
  shownReadout: undefined, shownRing: undefined, offAsked: 0, fixAt: 0,

  now() { if (Clock && Clock.now) { const v = Clock.now(); return v instanceof Date ? v.getTime() : +v; } return Date.now(); },
  $(c) { return H.el ? H.el.querySelector(c) : null; },
  rig() { return (H.ctx && H.ctx.data.rig) || {}; },

  mount(el, ctx) {
    H.el = el; H.ctx = ctx; H.offs = []; H.shownReadout = undefined; H.shownRing = undefined;
    memLoad(); watch(ctx.data); observe(ctx.data.state);
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
    H.el = null;
  },

  onState(st, ch) {
    H.st = st || {}; observe(H.st);
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

  // ---- NOW / NEXT: his series only ("his" is irdash's flag: favourites and the series of his own races) ----
  races() {
    const o = H.off, rows = [], key = {};
    if (!o || !o.loaded) return rows;
    const add = r => { if (!r || !r.t) return; const k = r.series + '|' + r.t; if (key[k]) return; key[k] = 1; rows.push(r); };
    add(o.next);
    if (o.nextMine) (o.days || []).forEach(d => (d.rows || []).forEach(r => { if (r.his) add(r); }));
    rows.sort((a, b) => Date.parse(a.t) - Date.parse(b.t));
    return rows.slice(0, 4);
  },
  upcoming() { const now = H.now(); return H.races().find(r => Date.parse(r.t) > now) || null; },

  // the series of the session he is in: only when one of his races starts at this track within an hour of the session (no guessing)
  sessionSeries(track) {
    const at = mem.sessionSince || H.now(), o = H.off;
    if (!o || !o.loaded || !track) return '';
    const all = [o.next].concat(...(o.days || []).map(d => d.rows || [])).filter(r => r && (r.his || (r === o.next && o.nextMine)));
    const hit = all.find(r => Math.abs(Date.parse(r.t) - at) <= 3600000 && sameTrack(r.track + ' ' + (r.layout || ''), track));
    return hit ? hit.series : '';
  },
  drawNow() {
    const z = H.$('.now'); if (!z) return;
    const lbl = z.querySelector('.lbl'), box = z.querySelector('.rows'), s = H.st.session;
    if (H.rig().sessionOn && s && s.WeekendInfo) {
      lbl.textContent = 'Now';
      const wi = s.WeekendInfo, di = s.DriverInfo || {}, me = (di.Drivers || []).find(x => String(x.CarIdx) === String(di.DriverCarIdx)) || {};
      const track = wi.TrackDisplayName || wi.TrackName || '', series = H.sessionSeries(track);
      box.innerHTML = '<div class="nx big"><div class="t">' + esc(H.ctx.Fmt.sessionName(wi.EventType || '')) + '</div>' +
        (series ? '<div class="s">' + esc(series) + '</div>' : '') + '<div class="s">' + esc(track) + '</div>' +
        '<div class="d">' + esc(me.CarScreenName || '') + '</div>' +
        (mem.sessionSince ? '<div class="d since">Loaded at ' + esc(localTime(mem.sessionSince)) + '</div>' : '') + '</div>';
      return;
    }
    const rows = H.races(), now = H.now(), up = H.upcoming();
    lbl.textContent = H.off && H.off.next && !H.off.nextMine ? 'Next race you can join' : 'Next race';
    if (!rows.length) { box.innerHTML = '<div class="none">' + (H.off && H.off.loaded ? 'No race of your series this week' : 'No race schedule yet') + '</div>'; return; }
    box.innerHTML = rows.map(r => {
      const t = Date.parse(r.t), big = r === up, past = t <= now;
      return '<div class="nx' + (big ? ' big' : '') + (past ? ' past' : '') + '" data-t="' + t + '">' +
        (big ? '<div class="when">' + esc(localDay(t, now)) + (r.est ? DOT + 'time estimated' : '') + '</div>' : '') +
        '<div class="t">' + esc(localTime(t)) + (big ? '' : DOT + esc(r.tiny || r.series)) + '</div>' +
        (big ? '<div class="s">' + esc(r.series) + '</div>' : '') +
        // a smaller row on another day says which day ("Tomorrow · Road Atlanta"): a bare 19:15 would read as today
        '<div class="d">' + (!big && localDay(t, now) !== 'Today' ? esc(localDay(t, now)) + DOT : '') + esc(r.trackShort || r.track) + (big && r.carShort ? DOT + esc(r.carShort) : '') + '</div></div>';
    }).join('');
  },

  // ---- MY RACES and the after-drive card ----
  // the card's ten minutes start at the later of "he stopped driving" and "the drive first appeared in the library"
  noteNewest() {
    const r = H.lib && H.lib.races && H.lib.races[0]; if (!r || r.id === mem.newestId) return;
    mem.newestAt = mem.newestId ? H.now() : 0;          // the first look ever: what is there is old news
    mem.newestId = r.id; memSave();
  },
  afterDrive() {
    const r = H.lib && H.lib.races && H.lib.races[0];
    if (!r || r.id !== mem.newestId || !mem.newestAt || H.ctx.driving() || H.rig().driving) return null;
    return H.now() - Math.max(mem.driveEnd, mem.newestAt) < AFTER_MS ? r : null;
  },
  drawMine() {
    const z = H.$('.mine'); if (!z) return;
    const F = H.ctx.Fmt, races = (H.lib && H.lib.races) || [], box = z.querySelector('.rows'), card = z.querySelector('.after'), now = H.now();
    const a = H.afterDrive();
    if (a) {
      const p = place(a, true), laps = (a.laps || 0) + ' laps' + (a.best > 0 ? ', best ' + F.lap(a.best) : '');
      const say = a.isRace ? 'Your race: ' + (p || laps) : 'Your ' + F.sessionName(a.type).toLowerCase() + ': ' + laps;
      card.innerHTML = '<div class="s">' + esc(say) + '</div><button type="button" class="btn">Review</button>';
      card.hidden = false;
    } else { card.hidden = true; card.innerHTML = ''; }
    const list = a ? races.slice(1, 3) : races.slice(0, 3);       // the card is the newest drive: not twice
    if (!races.length) box.innerHTML = '<div class="none">No drives recorded yet</div>';
    else box.innerHTML = list.map(r => {
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
    if (!H.online) { dot.className = 'dot off'; fix.hidden = true; line.innerHTML = '<span class="w">Not connected to Paddock</span>'; return; }
    if (doc && doc.running) { dot.className = 'dot off'; line.innerHTML = '<span class="w">Checking the rig…</span>'; fix.hidden = false; fix.disabled = true; return; }
    if (apps.ui && apps.ui.state !== 'ok') { say = 'The rig is off. Press RIG ON.'; bad = true; }
    else if (doc && doc.ask) { say = esc(doc.ask); bad = true; }          // only he can do this one: the sentence, no FIX IT
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
    fix.hidden = !canFix; fix.disabled = H.ctx.kidsOn() || !!H.rig().sessionOn || Date.now() - H.fixAt < 5000;
  },
  // FIX IT: the doctor checks again and makes the fixes it safely can (it never acts while a session is on); it says
  // "Checking the rig" on its own push while it runs
  async fix() {
    const b = H.$('.fix'); if (!b || b.disabled) return;
    H.fixAt = Date.now(); b.disabled = true;
    await H.send('doctorcheck', '');
    setTimeout(() => { if (H.el) H.drawRig(); }, 5000);
  },

  // ---- the one button. Carried over from v2/home.js next()/go() unchanged in behaviour: RIG ON when the iRacing UI is off; DRIVE
  // (the deck's GO) once a session is loaded; else DRIVE his last car and track (through MY DRIVE: choose, check, start);
  // else START (test drive the last one). Its plain-words failure goes on the button. ----
  short(car) { return String(car || '').replace(/^Chevrolet /, ''); },
  pick() {
    const apps = H.apps(), rig = H.rig(), l = H.home && H.home.last;
    if (!H.online) return { key: 'rig-on', label: 'Rig on', off: 'Paddock is not running' };
    if (!H.st.health) return null;
    let act;
    if (apps.ui && apps.ui.state !== 'ok') act = { key: 'rig-on', label: 'Rig on', busy: 'Turning on' };
    else if ((apps.sim && apps.sim.state === 'live') || rig.sessionOn) act = { key: 'go', label: 'Drive', busy: 'Getting in' };
    // the old HOME said "Last drive"; the deck's key for it is DRIVE (PLAN 4.6), and LAST RACE (REVIEW) sits on this screen too
    else if (l && l.car && l.track) act = { label: 'Drive', car: l.car, track: l.track, sub: H.short(l.car) + DOT + l.track, busy: 'Choosing car and track' };
    else act = { key: 'test-drive-last', label: 'Start', busy: 'Loading the session' };
    if (H.ctx.kidsOn()) act.off = 'Kids mode is on';
    return act;
  },
  drawButton() {
    const b = H.$('.one'); if (!b) return;
    const act = H.pick(); H.act = act;
    if (!act) { b.hidden = true; return; }
    b.homeAct = act;
    const now = Date.now(), busy = now < H.busyUntil, failed = !busy && now < H.failUntil;
    // offline or kids mode: flat grey, saying why, so it never looks half pressable
    b.hidden = false; b.className = 'btn gold one' + (act.off ? ' off' : busy ? ' busy' : failed ? ' failed' : '');
    b.disabled = !!act.off || busy;
    b.setAttribute('data-car', act.car || ''); b.setAttribute('data-track', act.track || '');
    const sub = act.off ? act.off : busy ? '' : failed ? (H.failMsg || 'Could not get going') : (act.sub || '');
    b.innerHTML = esc(busy && !act.off ? (H.busyWord || act.busy || '') : act.label) + (sub ? '<span>' + esc(sub) + '</span>' : '');
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
    // DRIVE his last car and track: choose that exact car and track, make sure MY DRIVE has them chosen, only then start
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
    H.drawNow(); H.drawMine(); H.drawRig(); H.drawButton(); H.second();
  },
  // once a second: the clock's readout and ring (none while a session is loaded), rows that have just passed, the end of the card
  second() {
    if (!H.el) return;
    const now = H.now(), up = H.upcoming(), cd = H.rig().sessionOn ? countdown(NaN, now) : countdown(up ? Date.parse(up.t) : NaN, now);
    const ring = cd.ring == null ? null : Math.round(cd.ring * 1000) / 1000;
    if (Clock && Clock.set && (cd.readout !== H.shownReadout || ring !== H.shownRing)) { H.shownReadout = cd.readout; H.shownRing = ring; Clock.set({ ring: ring, readout: cd.readout }); }
    const box = H.$('.now .rows');
    if (box && box.querySelector('[data-t]')) {
      const big = box.querySelector('.nx.big'), want = up ? String(Date.parse(up.t)) : '';
      const stale = (big ? big.dataset.t : '') !== want || [...box.querySelectorAll('.nx')].some(x => !x.classList.contains('past') && +x.dataset.t <= now);
      if (stale) H.drawNow();
    }
    // the shown race has started and nothing else is known: ask /official again (its 60 s cache keeps this to one a minute at most)
    if (H.off && H.off.loaded && !up && H.races().length && now - H.offAsked > 60000) H.loadOfficial();
    const card = H.$('.after');
    if (card && !card.hidden && !H.afterDrive()) H.drawMine();
  }
};

export const Home = H;          // tests reach the button logic and the clock through this
export const Mem = { get: () => Object.assign({}, mem), load: memLoad,       // tests: reset = a fresh page (a reload starts from sessionStorage)
  reset: () => Object.assign(mem, { seen: false, driving: false, driveEnd: 0, newestId: '', newestAt: 0, sessionOn: false, sessionSince: 0 }) };
export default {
  name: 'home', title: 'HOME',
  mount(el, ctx) { H.mount(el, ctx); },
  unmount() { H.unmount(); },
  onState(state, changed) { H.onState(state, changed); }
};
