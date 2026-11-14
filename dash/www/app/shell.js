// THE SHELL (W3-1, docs/rework/PLAN.md 3, 4.1 and 5 "Web"): the top screen's one page. It owns
//   - the router: four doors (#/home, #/races, #/review, #/rig), exactly one page mounted at a time, CLOSE and Esc back to HOME
//     (Esc inside a page's frame too: the hosts forward it as postMessage({paddock:'esc'})), the deck's page requests (the "nav"
//     part of irdash's state push, seq rising) and /api/nav?to=<door> so irdash knows which page is up;
//   - the driving guard (W2-2's RaceSwitch, moved here from v2/ui.js): while irdash says he drives AND a fresh frame comes AND it
//     is not a replay, no page is mounted and the race screen covers everything; 5 s after any of that fails, HOME mounts;
//   - the one banner: offline, kids mode, tow wait, a key message (4 s), the page's own line, in that order; one at a time;
//   - the flag (app/lib/flags.js, the light box's table) and its edge glow; the start-up layer (W3-2 plays in #startup).
// Page modules: app/pages/<name>.js export default { name, title, mount(el, ctx), unmount(), onState(state, changed) }, with
// ctx = { data, Fmt, go, close, banner, kidsOn(), driving(), opts }. ctx.data is the one connection with the page's own
// subscriptions counted, so unmounting removes every one of them. Pages never poll.
// Timers here: none while nothing happens. One-shot only: the 5 s wait after driving, the stale-frame look (only while frames
// come), the key message's 4 s, the 3 s grace before "not running" at load, the date at midnight.
// Tests: ?page=<door> opens that door first, ?race=1 shows the race screen whatever the rig says, ?intro=0 never plays the start-up.
import { Flags } from './lib/flags.js';

const data = window.data;
const QS = new URLSearchParams(location.search);
const DOORS = ['home', 'races', 'review', 'rig'];
// what irdash's page requests say -> the door (old names from the deck keys still work)
const NAV_TO = { home: 'home', races: 'races', review: 'review', rig: 'rig', sessions: 'review', coach: 'review', vault: 'races', perf: 'rig' };
const NAV_PARTS = ['nav', 'vaultNav', 'perfNav'];
const STALE_MS = 3000, OFF_WAIT_MS = 5000, KEYMSG_MS = 4000, BOOT_GRACE_MS = 3000;
const OFFLINE_TEXT = 'Paddock is not running. Press HOME on the deck.';
const TOW_TEXT = 'Reset car · waiting for the car to stop';
const KIDS_TEXT = 'KIDS MODE  -  keyboard and deck locked  -  to unlock press KIDS, then HOME';
// out of the car the stream carries only what the shell reads (the flag, the replay gate); in the car, the race screen's set
const IDLE_VARS = ['SessionFlags', 'IsReplayPlaying', 'IsOnTrack', 'SessionNum'];
const $ = id => document.getElementById(id);
const bootAt = performance.now();

/* ---------------- the router ---------------- */
const Shell = {
  cur: '', page: null, scope: null, mods: {}, pageBanner: null, openedBy: '', seen: {}, navTo: {},
  told: [], msgs: [], seenOnline: false,

  // go(name, opts): unmount the current page, then mount that one. opts.from: 'press' (a door, CLOSE, Esc: irdash is told),
  // 'nav' (irdash asked: nothing to tell), 'drive' or 'boot'. Refused while the race screen is up.
  go(name, opts) {
    opts = opts || {};
    if (!DOORS.includes(name)) name = 'home';
    if (Race.on) return false;
    if (name === this.cur && !opts.at) return true;
    const from = this.cur;
    this.unmount();
    this.cur = name;
    this.openedBy = opts.from === 'nav' ? opts.part || 'nav' : opts.from || '';
    document.body.classList.toggle('at-home', name === 'home');
    document.querySelectorAll('.door').forEach(b => { const on = b.dataset.door === name; b.classList.toggle('on', on); b.setAttribute('aria-current', on ? 'page' : 'false'); });
    if (location.hash !== '#/' + name) { try { history.replaceState(null, '', '#/' + name); } catch (e) { location.hash = '#/' + name; } }
    if (opts.from === 'press') {
      this.tell('/api/nav?to=' + name);
      // the old Vault and Performance requests have their own flags in irdash: close them too when their page goes
      if (from && from !== name) {
        if (this.navTo.vaultNav && NAV_TO[this.navTo.vaultNav] === from) this.tell('/api/do?c=vkclose');
        if (this.navTo.perfNav && NAV_TO[this.navTo.perfNav] === from) this.tell('/api/do?c=perfclose');
      }
    }
    this.mount(name, opts);
    return true;
  },
  close() { return this.go('home', { from: 'press' }); },

  async mount(name, opts) {
    const scope = this.scope = { live: true, offs: [] };
    const el = $('page');
    let mod;
    try { mod = await this.load(name); }
    catch (e) { console.error(e); if (scope.live) this.message(el, name.toUpperCase() + ' could not open. Press HOME.'); return; }
    if (!scope.live) return;                       // another page was asked for meanwhile
    const ctx = {
      data: this.scoped(scope), Fmt: window.Fmt, opts: opts || {},
      go: (n, o) => this.go(n, Object.assign({ from: 'press' }, o || {})),
      close: () => this.close(),
      banner: t => { if (!scope.live) return; this.pageBanner = t ? String(t) : null; Banner.draw(); },
      kidsOn: () => Banner.kidsOn(),
      driving: () => Race.on,
    };
    try {
      mod.mount(el, ctx); this.page = mod;
      if (mod.onState && data.seq >= 0 && data.state) { const all = {}; for (const k in data.state) all[k] = true; mod.onState(data.state, all); }
    } catch (e) { console.error(e); this.message(el, name.toUpperCase() + ' could not open. Press HOME.'); }
  },
  // one failed page never stops the shell: each page is its own module, loaded when first asked for
  load(name) {
    if (!this.mods[name]) this.mods[name] = import('./pages/' + name + '.js').then(m => m.default, e => { delete this.mods[name]; throw e; });
    return this.mods[name];
  },
  message(el, text) { el.replaceChildren(); const d = document.createElement('div'); d.className = 'shell-msg'; d.textContent = text; el.appendChild(d); },

  unmount() {
    const p = this.page, s = this.scope;
    this.page = null; this.scope = null;
    if (s) s.live = false;
    if (p && p.unmount) { try { p.unmount(); } catch (e) { console.error(e); } }
    if (s) s.offs.forEach(off => { try { off(); } catch (e) { } });
    this.pageBanner = null; Banner.draw();
    $('page').replaceChildren();
    this.cur = '';
  },

  // the page's view of the one connection: every subscription it makes is ended when it unmounts
  scoped(scope) {
    const d = Object.create(data);
    const keep = off => { if (typeof off === 'function') scope.offs.push(off); return off; };
    d.on = (n, f) => keep(data.on(n, f));
    d.onList = (n, f) => keep(data.onList ? data.onList(n, f) : null);
    d.telemetry = () => { };                       // the stream is the shell's
    return d;
  },

  tell(url) {
    this.told.push(url); if (this.told.length > 40) this.told.shift();
    if (url.indexOf('/api/nav') === 0) this.toldAt = performance.now();
    try { const p = data.fetch(url); if (p && p.catch) p.catch(() => { }); } catch (e) { } },

  // the deck's page requests: followed only when NEW (seq changed); the first one after load is taken as it is (a key pressed
  // before this page loaded still opens its page)
  follow(st, ch) {
    for (const part of NAV_PARTS) {
      if (!ch[part]) continue;
      const n = st[part]; if (!n || typeof n.seq !== 'number') continue;
      const first = !(part in this.seen), changed = this.seen[part] !== n.seq;
      this.seen[part] = n.seq; this.navTo[part] = n.to || '';
      if (n.enabled === false || (!first && !changed) || Race.on) continue;
      // the echo of a door pressed here (irdash now says what we told it): two quick presses must not bounce back to the first
      if (part === 'nav' && performance.now() - (this.toldAt || -1e9) < 3000) continue;
      const to = n.to ? NAV_TO[n.to] || '' : '';
      if (to) { if (!first || this.cur === 'home') { this.go(to, { from: 'nav', part }); this.openedBy = part; } }
      else if (!first && this.openedBy === part && this.cur !== 'home') this.go('home', { from: 'nav' });
    }
  },

  init() {
    Race.init();                                   // first: a state that is already known runs the switch at once
    document.querySelectorAll('.door').forEach(b => b.addEventListener('click', () => this.go(b.dataset.door, { from: 'press' })));
    $('shellClose').addEventListener('click', () => this.close());
    // Esc goes HOME; a page that used Esc itself (closing its own open card) stops it first
    window.addEventListener('keydown', e => { if (e.key === 'Escape' && !e.defaultPrevented && this.cur && this.cur !== 'home' && !Race.on) this.close(); });
    window.addEventListener('message', e => {
      if (e.origin !== location.origin || !e.data) return;
      const m = e.data; this.msgs.push(m.paddock || m.irdash || ''); if (this.msgs.length > 40) this.msgs.shift();
      if (m.paddock === 'esc' || /^(sessions|races|vault|perf|coach)-close$/.test(m.irdash || '')) { if (this.cur && this.cur !== 'home') this.close(); }
    });
    window.addEventListener('hashchange', () => { const n = (/^#\/([a-z]+)/.exec(location.hash) || [])[1]; if (n && n !== this.cur) this.go(n, { from: 'press' }); });
    data.on('state', (st, ch) => {
      this.follow(st, ch);
      Banner.state(st, ch);
      Race.look();
      if (this.page && this.page.onState) { try { this.page.onState(st, ch); } catch (e) { console.error(e); } }
      Startup.state(st, ch);
    });
    data.on('online', () => { if (data.online) this.seenOnline = true; Banner.draw(); Race.look(); });
    data.on('frame', v => Race.frame(v));
    data.on('connect', () => Race.syncSet());
    if (data.online) this.seenOnline = true;
    if (data.reloadOnVersion) data.reloadOnVersion(() => Race.on || Race.inCar());   // never reload while he is in the car
    Dates.draw();
    setTimeout(() => Banner.draw(), BOOT_GRACE_MS + 50);
    const first = QS.get('page') || (/^#\/([a-z]+)/.exec(location.hash) || [])[1] || 'home';
    if (!Race.on) this.go(first, { from: 'boot' });
    Startup.boot();
  },
};

/* ---------------- the race screen (W2-2's switch, moved from v2/ui.js RaceSwitch) ---------------- */
const Race = {
  on: false, forced: QS.has('race'), offSince: 0, v: null, frameAt: 0, timer: 0, set: '', el: null,

  init() {
    this.el = $('raceHost');
    // made after data.js has run, so the race page inside borrows this page's one connection
    const f = document.createElement('iframe'); f.id = 'raceFrame'; f.src = '../v2/race.html'; f.title = 'Race screen';
    this.el.appendChild(f);
    this.syncSet();
    this.look();
  },
  guest() { const g = data.state && data.state.guest; return !!(g && g.active); },
  fresh(now) { return !!this.v && (now || performance.now()) - this.frameAt < STALE_MS; },
  // a fresh frame with the car on track (the version reload waits for this too)
  inCar() { return this.fresh() && !!this.v.IsOnTrack && !this.v.IsReplayPlaying; },
  want(now) {
    if (this.forced) return true;
    // Friends mode keeps its own drive view (the old guest.js); the shell does not cover it
    return !this.guest() && !!(data.rig && data.rig.driving) && !!data.online && this.fresh(now) && !this.v.IsReplayPlaying;
  },

  frame(v) {
    this.v = v || {}; this.frameAt = performance.now();
    Flags.flags(this.v.SessionFlags >>> 0);
    this.look();
  },

  // look again at everything the switch depends on; arms one timer for the next moment the answer can change by itself
  look() {
    const now = performance.now(), want = this.want(now);
    clearTimeout(this.timer); this.timer = 0;
    if (want) this.offSince = 0;
    else if (this.on && !this.offSince) this.offSince = now;
    const on = want || (this.on && now - this.offSince < OFF_WAIT_MS);
    const fresh = this.fresh(now);
    if (!fresh) Flags.clear();
    if (on !== this.on) {
      this.on = on;
      if (on) this.show(); else this.hide();
    }
    Glow.draw(fresh && !this.v.IsReplayPlaying);
    let next = 0;
    if (fresh) next = STALE_MS - (now - this.frameAt) + 20;
    if (on && !want) { const w = OFF_WAIT_MS - (now - this.offSince) + 20; next = next > 0 ? Math.min(next, w) : w; }
    if (next > 0 && !this.forced) this.timer = setTimeout(() => this.look(), next);
    this.syncSet();
  },
  show() {
    Shell.unmount();
    document.querySelectorAll('.door').forEach(b => b.classList.remove('on'));
    document.body.classList.add('race-on');
    this.el.hidden = false;
    Startup.stop();
  },
  hide() {
    this.el.hidden = true;
    document.body.classList.remove('race-on');
    Shell.go('home', { from: 'drive' });          // the after-drive card is HOME's (W3-3)
  },
  // the stream's set: the race set while it shows or as soon as irdash says driving (also at the first frame, data.js 'connect')
  syncSet() {
    const race = this.on || (!this.guest() && !!data.online && !!(data.rig && data.rig.driving));
    const want = race ? 'race' : 'idle';
    if (want === this.set || !data.telemetry) return;
    this.set = want;
    if (race) data.telemetry('race', 15); else data.telemetry(IDLE_VARS, 15);
  },
};

/* ---------------- the flag glow (was v2/flaglow.js; same flag as the panel and the light box) ---------------- */
const Glow = {
  cur: '',
  draw(live) {
    const f = live ? (Flags.flagName === 'warning' ? 'black' : Flags.flagName || '') : '';
    if (f === this.cur) return;
    this.cur = f; $('flagGlow').className = f ? 'on ' + f : '';
  },
};
// the session type for "Grid" / "Running" before the green: the race part's, else the session list's entry for this SessionNum
Flags.setRace(() => {
  const r = data.state && data.state.race, t = (r && r.type) || sessType();
  return !t || /race/i.test(t);
});
function sessType() {
  const s = data.state && data.state.session, v = Race.v, list = s && s.SessionInfo && s.SessionInfo.Sessions;
  if (!list || !v) return '';
  for (const x of list) if (parseInt(x.SessionNum, 10) === v.SessionNum) return x.SessionType || x.SessionName || '';
  return '';
}

/* ---------------- the one banner ---------------- */
const Banner = {
  kids: null, tow: null, key: null, keySeen: -1, keyTimer: 0, shown: '',
  kidsOn() { return !!(this.kids && this.kids.on); },
  offline() { return !data.online && (Shell.seenOnline || performance.now() - bootAt >= BOOT_GRACE_MS); },
  state(st, ch) {
    if (ch.kids) this.kids = st.kids || null;
    if (ch.tow) this.tow = st.tow || null;
    if (ch.keymsg) this.takeKey(st.keymsg, st.now);
    if (ch.kids || ch.tow || ch.keymsg) this.draw();
  },
  // a NEW key message shows for 4 s; one older than that (irdash says its age; this page's clock is not trusted) never shows
  takeKey(m, now) {
    if (!m) return;
    const s = +m.seq || 0;
    if (s === this.keySeen) return;
    this.keySeen = s;
    if (!s || !m.text) return;
    const age = m.ageMs != null ? +m.ageMs : (+now && +m.at ? Math.max(0, +now - +m.at) : 0);
    if (age >= KEYMSG_MS) return;
    this.key = { text: String(m.text).slice(0, 80), kind: m.kind === 'wait' || m.kind === 'no' ? m.kind : 'ok' };
    clearTimeout(this.keyTimer);
    this.keyTimer = setTimeout(() => { this.key = null; this.draw(); }, Math.max(600, KEYMSG_MS - age));
  },
  draw() {
    let kind = '', text = '';
    if (this.offline()) { kind = 'offline'; text = OFFLINE_TEXT; }
    else if (this.kidsOn()) { kind = 'kids'; text = this.kids.text || KIDS_TEXT; }
    else if (this.tow && this.tow.on) { kind = 'tow'; text = TOW_TEXT; }
    else if (this.key) { kind = this.key.kind === 'ok' ? 'key' : 'key-' + this.key.kind; text = this.key.text; }
    else if (Shell.pageBanner) { kind = 'page'; text = Shell.pageBanner; }
    const el = $('banner'), sig = kind + '|' + text;
    if (sig === this.shown) return;
    this.shown = sig;
    el.textContent = text; el.className = 'banner shell-banner' + (kind ? ' ' + kind : ''); el.dataset.kind = kind; el.hidden = !text;
  },
};

/* ---------------- the date in the header: local, "Fri 14 Nov"; looked at again just after midnight ---------------- */
const Dates = {
  draw() {
    const d = new Date();
    $('shellDate').textContent = d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
    const next = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 0, 0, 5);
    setTimeout(() => this.draw(), Math.max(1000, next - d));
  },
};

/* ---------------- the start-up (W3-2 builds app/pages/startup.js; the shell only shows and hides its layer) ---------------- */
const Startup = {
  playing: false, seq: null, mod: null,
  quiet() { const h = new Date().getHours(); return h >= 23 || h < 7; },
  async play() {
    if (this.playing || Race.on || QS.get('intro') === '0') return;
    let m;
    try { m = this.mod || (this.mod = await import('./pages/startup.js')); } catch (e) { this.mod = null; return; }   // not built yet: no start-up
    const S = m.Startup || m.default || m;
    if (!S || typeof S.play !== 'function' || Race.on) return;
    const el = $('startup');
    this.playing = true; el.hidden = false;
    try { await S.play(el, { sound: true, quiet: typeof m.isQuietHours === 'function' ? m.isQuietHours() : this.quiet(), skipOn: ['keydown', 'pointerdown'] }); }
    catch (e) { console.error(e); }
    this.playing = false; el.hidden = true; el.replaceChildren();
  },
  // once per dashboard boot (a reload after a file change does not play it again), ?intro=1 always
  boot() {
    let played = false;
    try { played = sessionStorage.getItem('paddock-startup') === '1'; sessionStorage.setItem('paddock-startup', '1'); } catch (e) { }
    if (QS.get('intro') === '1' || !played) this.play();
  },
  // the deck's showcase key: irdash raises showcase.seq; never while he drives
  state(st, ch) {
    if (!ch.showcase || !st.showcase) return;
    const s = st.showcase.seq;
    if (this.seq !== null && s !== this.seq && !Race.on && !st.showcase.driving) this.play();
    this.seq = s;
  },
  stop() { const el = $('startup'); el.hidden = true; },
};

// the race page in its frame reads these (shown or not, the flag and its words), as it read v2/ui.js before
window.RaceSwitch = { get on() { return Race.on; } };
window.UI = { get flagName() { return Flags.flagName; }, get flagText() { return Flags.flagText; }, live: () => Race.fresh() };
window.Shell = Shell; window.ShellRace = Race; window.ShellBanner = Banner; window.Flags = Flags;
Shell.init();
