/* REVIEW screen 2: THE LAPS (W4-4, docs/rework/PLAN.md 4.4 "Screen 2"). One trace page in place of three (Sessions' lap view,
   Session Review, the workbench's DRIVER page). Copied from the Delta / MoTeC / Garage 61 stack (evidence 02): the track map top-left
   with the cursor dot, two rows of lap chips (THIS LAP, REFERENCE), the traces on one distance axis (delta-T in gold first, then
   speed, throttle + brake, steering, gear), the readout column always showing both laps at the cursor (no mouse-only tooltips),
   the corner table under it with its four definitions once, and the theoretical best with its date spread.
   Hosted by REVIEW's card screen (W4-3): mount(el, ctx, opts) / unmount() / onDeck(cmd). opts = { id, corner, lap, ref }.
   Requests: /api/review once (data.json), then per lap pair /api/review/traces (PWB1, binary) and /api/review/corners. Nothing on a
   timer and nothing posted: the deck's REVIEW arrows arrive as the "workbench" state part (irdash keeps the last wb-* command and
   pushes it; the workbench page's old 300 ms poller is not copied) or through onDeck. A "working" review asks again on data.onList('review').
   Chart and Map are W4-2's app/lib/chart.js and map.js (loaded when first needed; without them the screen says so in one line). */
const DOT = ' · ';
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const num = x => typeof x === 'number' && isFinite(x);
const Fmt = () => window.Fmt;
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
// the server's own words first (/api/review/corners "defs"); these are the same words, for an answer without them
const DEFS = { brakeM: 'brake over 10 %', pickupM: 'throttle over 90 % after the apex', minSpeed: 'the slowest point', time: 'turn-in to exit' };
const NAMES = { brakeM: 'Brake point', minSpeed: 'Minimum speed', pickupM: 'Throttle-on', time: 'Time' };
// a lap the store did not count: the word on its chip (the store's own reason; an unknown reason is shown as given)
const WHY = { out: 'out lap', in: 'in lap', pit: 'pit', off: 'off track', incident: 'incident', invalid: 'not counted', partial: 'part lap', cut: 'part lap' };
export const whyWord = w => { const k = String(w || '').toLowerCase().trim(); return k ? (WHY[k] || k) : 'not counted'; };

// ---------------------------------------------------------------- pure helpers (the test imports them)
// "6 Nov" (local day), "6 Nov – 13 Nov" for a spread, one day once
export function dayWord(ms) { const d = new Date(ms); return isNaN(d.getTime()) ? '' : d.getDate() + ' ' + MON[d.getMonth()]; }
export function optimalLine(opt) {
  if (!opt || !num(opt.time)) return '';
  const from = Array.isArray(opt.from) ? opt.from : [];
  const laps = [...new Set(from.map(f => f.lap).filter(num))].sort((a, b) => a - b);
  const days = from.map(f => f.date).filter(num).sort((a, b) => a - b);
  let spread = '';
  if (days.length) { const a = dayWord(days[0]), b = dayWord(days[days.length - 1]); spread = ' (' + (a === b ? a : a + ' – ' + b) + ')'; }
  return 'Theoretical best ' + Fmt().lap(opt.time) + (laps.length ? ' from lap' + (laps.length > 1 ? 's ' : ' ') + laps.join(', ') : '') + spread;
}
// PWB1 (dash/src/workbench.cs): "PWB1", int32 header length, the JSON header (padded), then Float32 arrays in "arrays" order
export function readPwb(buf) {
  const dv = new DataView(buf);
  if (buf.byteLength < 8 || String.fromCharCode(dv.getUint8(0), dv.getUint8(1), dv.getUint8(2), dv.getUint8(3)) !== 'PWB1') throw new Error('not a traces reply');
  const hl = dv.getInt32(4, true), head = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 8, hl)));
  let pos = 8 + hl; const arr = {};
  (head.arrays || []).forEach(k => { arr[k] = new Float32Array(buf, pos, head.n); pos += head.n * 4; });
  return { head, arr };
}
// the speed unit: what W4-1 says for the session (Peter's iRacing setting), else mph (his DisplayUnits is imperial)
export function speedUnit(session, corners) {
  const u = String((corners && (corners.speedUnit || corners.units)) || (session && (session.speedUnit || session.units)) || '').toLowerCase();
  return /km|metric/.test(u) ? 'km/h' : 'mph';
}
const MS_TO = { mph: 2.2369363, 'km/h': 3.6 };
// the corner-table rows from the engine's one shape (dash/src/review.cs CornersRoute):
//   {state, units, defs, lap:{n, time, rows:[{n,label,detected,brakeM,minSpeed,pickupM,time}]}, ref:{n, file, rows:[same]} | null}
// n and label are the same across /api/review, /corners and /progress; the row's label is shown as given
export function cornerRows(j) {
  if (!j || !j.lap || !Array.isArray(j.lap.rows)) return [];
  const keys = ['brakeM', 'minSpeed', 'pickupM', 'time'], other = j.ref && Array.isArray(j.ref.rows) ? j.ref.rows : [];
  const pick = (o, k) => (o && num(o[k])) ? o[k] : null;
  return j.lap.rows.map(r => {
    const q = other.find(x => x.n === r.n), row = { n: r.n, label: r.label || ('T' + r.n), detected: !!r.detected, lap: {}, ref: {} };
    keys.forEach(k => { row.lap[k] = pick(r, k); row.ref[k] = pick(q, k); });
    return row;
  });
}
// the difference and whether it is a gain: a later brake point, a higher minimum, an earlier throttle and a shorter time are quicker
export const BETTER = { brakeM: +1, minSpeed: +1, pickupM: -1, time: -1 };
export function diff(k, a, b) {
  if (!num(a) || !num(b)) return { d: null, cls: '' };
  const d = a - b, eps = k === 'time' ? 0.0005 : 0.5;
  return { d, cls: Math.abs(d) < eps ? '' : (d * BETTER[k] > 0 ? 'gain' : 'loss') };
}

// ---------------------------------------------------------------- the page
const P = {
  el: null, ctx: null, opts: {}, offs: [], live: false, token: 0,
  rv: null, err: false, sel: { lap: null, ref: null }, tr: null, rows: [], unit: 'mph', defs: DEFS,
  chart: null, map: null, C: null, M: null, cursorM: 0, range: null, active: null, deckSeq: null, libs: null,
  $(s) { return P.el ? P.el.querySelector(s) : null; },

  mount(el, ctx, opts) {
    P.unmount();
    P.el = el; P.ctx = ctx; P.opts = Object.assign({}, (ctx && ctx.opts) || {}, opts || {}); P.live = true; P.offs = [];
    P.rv = null; P.err = false; P.tr = null; P.rows = []; P.cursorM = 0; P.range = null; P.active = null; P.deckSeq = null;
    P.sel = { lap: null, ref: null }; P.zoomedAtMount = false; P.pending = false; P.retryT = 0; P.fallbackUsed = false;
    if (!document.querySelector('link[data-page="review-laps"]')) {
      const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = new URL('./review-laps.css', import.meta.url).href; l.dataset.page = 'review-laps';
      document.head.appendChild(l);
    }
    el.innerHTML =
      '<div class="rl">' +
      '<section class="rl-map" aria-label="Track map"></section>' +
      '<section class="rl-top"><div class="rl-pick" aria-label="Laps"></div><div class="rl-sum"><span class="rl-vs"></span><span class="rl-opt"></span></div></section>' +
      '<section class="rl-stack" aria-label="Traces"><div class="rl-chart"></div><div class="rl-readout" aria-live="off"></div><p class="rl-noref" hidden>Delta: no reference lap</p></section>' +
      '<section class="rl-corners" aria-label="Corners"><div class="rl-tblbox"><table class="tbl rl-tbl"></table></div><p class="rl-defs"></p></section>' +
      '<div class="rl-msg" hidden></div>' +
      '</div>';
    P.$('.rl-pick').addEventListener('click', e => { const b = e.target.closest('button[data-lap]'); if (b && !b.disabled) P.pick(b.dataset.row, b.dataset.lap); });
    P.$('.rl-tbl').addEventListener('click', e => { const r = e.target.closest('tr[data-n]'); if (r) P.toCorner(+r.dataset.n); });
    const d = ctx.data;
    const on = off => { if (typeof off === 'function') P.offs.push(off); };
    on(d.on('state', (st, ch) => { if (ch && ch.workbench) P.deck(st.workbench); }));
    if (d.state && d.state.workbench) P.deckSeq = d.state.workbench.seq;     // the first look only learns the seq: an old command is not replayed
    on(d.onList && d.onList('review', () => { if (P.rv && P.rv.state === 'working') P.load(0); else if (P.pending && P.sel.lap != null) P.loadPair(); }));
    on(d.on('online', v => { if (v && P.err) P.load(0); }));
    P.load(60000);
  },
  unmount() {
    P.live = false; P.token++; P.pending = false; clearTimeout(P.retryT); P.retryT = 0;
    P.offs.forEach(f => { try { f(); } catch (e) { } }); P.offs = [];
    try { if (P.C && P.C.unmount) P.C.unmount(); } catch (e) { }
    try { if (P.M && P.M.unmount) P.M.unmount(); } catch (e) { }
    P.chart = P.map = P.C = P.M = null;
    if (P.el) P.el.replaceChildren();
    P.el = null;
  },

  id() { return P.opts.id || P.opts.at || 'last'; },
  // W4-2's libraries, once; a missing one is null (the screen says so where it would be)
  libsLoad() {
    if (!P.libs) {
      const get = (f, name) => import(new URL('../lib/' + f, import.meta.url).href).then(m => m[name] || m.default || m, () => null);
      P.libs = Promise.all([get('chart.js', 'Chart'), get('map.js', 'Map')]).then(a => ({ Chart: a[0], Map: a[1] }));
    }
    return P.libs;
  },

  async load(ttl) {
    const t = ++P.token;
    let rv = null;
    try { rv = await P.ctx.data.json('/api/review?id=' + encodeURIComponent(P.id()), ttl); }
    catch (e) { if (t !== P.token || !P.live) return; P.err = true; P.draw(); return; }
    if (t !== P.token || !P.live) return;
    P.err = false; P.rv = rv || {};
    P.draw();
    if (P.rv.state === 'ready' && P.laps().length) {
      const s = P.choose();
      P.sel = s; P.drawPick(); await P.loadPair();
    }
  },
  session() { return (P.rv && P.rv.session) || {}; },
  laps() { return (P.rv && Array.isArray(P.rv.laps)) ? P.rv.laps : []; },
  refInfo() { return P.session().ref || null; },
  // THIS LAP: the lap asked for, else the newest counted lap that is not the reference, else the best. REFERENCE: the review's
  // own (this session's best counted lap, or "your best here" when ref.kind is "ever"), never the lap itself
  choose() {
    const laps = P.laps(), ref = P.refInfo(), want = +P.opts.lap;
    let refSel = null;
    if (P.opts.ref) refSel = String(P.opts.ref);
    else if (ref && ref.kind === 'ever') refSel = 'ever';
    else if (ref && num(ref.lap)) refSel = String(ref.lap);
    let lap = laps.find(l => l.n === want) || null;
    if (!lap) { const c = laps.filter(l => l.counted && String(l.n) !== refSel); lap = c.length ? c[c.length - 1] : null; }
    if (!lap) { const b = P.session().best; lap = (b && laps.find(l => l.n === b.lap)) || laps.filter(l => l.counted).pop() || laps[laps.length - 1]; }
    if (refSel === String(lap.n)) refSel = null;
    return { lap: lap.n, ref: refSel };
  },
  pick(row, v) {
    if (row === 'lap') { P.sel.lap = +v; if (P.sel.ref === String(v)) P.sel.ref = null; }
    else P.sel.ref = v === 'none' ? null : String(v);
    P.fallbackUsed = false;
    P.drawPick(); P.loadPair();
  },
  async loadPair() {
    const t = ++P.token, id = P.session().id || P.id(), s = P.sel;
    const q = 'id=' + encodeURIComponent(id) + '&lap=' + s.lap + (s.ref ? '&ref=' + encodeURIComponent(s.ref) : '');
    clearTimeout(P.retryT); P.retryT = 0;
    P.busy(true);
    let buf = null, cj = null, libs = null, working = false;
    try {
      [buf, cj, libs] = await Promise.all([
        // the engine answers 202 {"state":"working"} for a lap pair it has not built yet: not an error, ask again when it says so
        fetch('/api/review/traces?' + q, { cache: 'no-store' }).then(r => { if (r.status === 202) { working = true; return null; } if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); }),
        P.ctx.data.json('/api/review/corners?' + q, P.pending ? 0 : 60000).catch(() => null),   // 0 after a "working" answer: data.json would hand the same 202 back
        P.libsLoad()]);
    } catch (e) { if (t !== P.token || !P.live) return; P.busy(false); P.pending = false; P.tr = null; P.msgStack('The traces would not load. Press the lap again.'); return; }
    if (t !== P.token || !P.live) return;
    if (working || (cj && cj.state === 'working')) {
      P.busy(false); P.pending = true; P.tr = null; P.msgStack('Reading your laps…');
      // the engine bumps the review list when the job ends (onList in mount); one fallback ask after 10 s in case that event was missed
      // once per press: the ask that fallback makes does not arm another (no polling chain)
      if (!P.fallbackUsed) P.retryT = setTimeout(() => { P.retryT = 0; P.fallbackUsed = true; if (P.live && P.pending && t === P.token) P.loadPair(); }, 10000);
      return;
    }
    P.pending = false;
    P.busy(false);
    try { P.tr = P.traces(readPwb(buf), s); } catch (e) { P.tr = null; P.msgStack('The traces would not load. Press the lap again.'); return; }
    P.unit = speedUnit(P.session(), cj);
    P.rows = cornerRows(cj);
    P.defs = Object.assign({}, DEFS, (cj && cj.defs) || {});
    P.drawStack(libs); P.drawMap(libs); P.drawTable(); P.drawSum();
    // SHOW ME from the card: that corner, once
    if (!P.zoomedAtMount && num(+P.opts.corner) && P.opts.corner !== '' && P.opts.corner != null) { P.zoomedAtMount = true; P.toCorner(+P.opts.corner); }
    else P.cursor(P.cursorM);
  },

  // the two laps on the 1 m grid, and the rows of the stack in W4-2's shape
  traces(pwb, s) {
    const h = pwb.head, a = pwb.arr, n = h.n, L = h.lengthM || h.metres || n - 1, step = L / Math.max(1, n - 1);
    const chans = h.channels || [];
    const key = rx => { const c = chans.find(c => rx.test(c.key)); return c ? c : null; };
    const cS = key(/^speed$/i), cT = key(/^throttle$/i), cB = key(/^brake$/i), cW = key(/^steer/i), cG = key(/^gear/i);
    const has = p => !!a[p + '.t'];
    const lap = p => {
      if (!has(p)) return null;
      const o = { t: a[p + '.t'] };
      o.speed = cS ? a[p + '.' + cS.key] : null; o.thr = cT ? a[p + '.' + cT.key] : null; o.brk = cB ? a[p + '.' + cB.key] : null;
      o.steer = cW ? a[p + '.' + cW.key] : null; o.gear = cG ? a[p + '.' + cG.key] : null;
      return o;
    };
    const A = lap('lap'), R = s.ref ? lap('ref') : null;
    const sp = String(cS && cS.unit || 'm/s').toLowerCase(), unit = speedUnit(P.session());
    const toU = v => sp === 'm/s' ? v * MS_TO[unit] : (sp === unit ? v : sp === 'km/h' ? v / 3.6 * MS_TO[unit] : v / 2.2369363 * MS_TO[unit]);
    const map = (arr, f) => { if (!arr) return null; const o = new Float32Array(arr.length); for (let i = 0; i < arr.length; i++) o[i] = f(arr[i]); return o; };
    const pct = v => v <= 1.001 ? v * 100 : v, deg = v => v * 57.29578;
    const steerDeg = cW && /deg/i.test(cW.unit || '') ? (v => v) : deg;
    const lbl = { lap: 'lap ' + s.lap, ref: s.ref === 'ever' ? 'your best here' : 'lap ' + s.ref };
    const two = f => [{ label: lbl.lap, color: 'gold', data: f(A) }].concat(R ? [{ label: lbl.ref, color: 'ink', data: f(R) }] : []);
    let delta = null;
    if (R) { delta = new Float32Array(n); for (let i = 0; i < n; i++) delta[i] = A.t[i] - R.t[i]; }
    const rows = [
      { key: 'delta', label: 'DELTA', unit: 's', kind: 'line', series: delta ? [{ label: 'lap ' + s.lap + ' against ' + lbl.ref, color: 'gold', data: delta }] : [], note: delta ? '' : 'no reference lap' },
      { key: 'speed', label: 'SPEED', unit: unit, series: two(l => map(l.speed, toU)) },
      // the library's pedals row: two values a line, this lap then the reference: [throttle, throttle ref, brake, brake ref]
      { key: 'pedals', label: 'THROTTLE + BRAKE', unit: '%', series: [{ label: 'throttle ' + lbl.lap, color: 'gain', data: map(A.thr, pct) }]
        .concat(R ? [{ label: 'throttle ' + lbl.ref, color: 'ink', data: map(R.thr, pct) }] : [])
        .concat([{ label: 'brake ' + lbl.lap, color: 'loss', data: map(A.brk, pct) }])
        .concat(R ? [{ label: 'brake ' + lbl.ref, color: 'ink', data: map(R.brk, pct) }] : []) },
      { key: 'steer', label: 'STEERING', unit: 'deg', series: two(l => map(l.steer, steerDeg)) },
      { key: 'gear', label: 'GEAR', unit: '', kind: 'step', series: two(l => l.gear) },
    ].map(r => { r.series = r.series.filter(x => x.data); return r; });
    const corners = (h.corners || []).map(c => ({ n: c.n, label: c.label || (c.official ? 'T' + String(c.official).toUpperCase() : 'T' + c.n), name: c.name || '',
      p0: c.p0, pa: c.pa, p1: c.p1 > c.p0 ? c.p1 : 1, m0: c.p0 * L, ma: c.pa * L, m1: (c.p1 > c.p0 ? c.p1 : 1) * L }));
    return { L, n, step, A, R, rows, corners, delta, head: h };
  },

  // ---------------------------------------------------------------- the cursor, zoom and the deck
  corner(n) { return P.tr ? P.tr.corners.find(c => c.n === n) || null : null; },
  cornerAt(m) { if (!P.tr) return null; const c = P.tr.corners; return c.find(x => m >= x.m0 && m <= x.m1) || null; },
  // the chart's cursor moved (its drag, its wheel, our deck): the map dot and the table follow
  follow(m) {
    if (!P.tr) return;
    P.cursorM = Math.max(0, Math.min(P.tr.L, m));
    try { if (P.M && P.M.cursor) P.M.cursor(P.cursorM / P.tr.L); } catch (e) { }
    const c = P.cornerAt(P.cursorM); P.mark(c ? c.n : null);
  },
  cursor(m) { if (!P.tr) return; P.cursorM = Math.max(0, Math.min(P.tr.L, m)); try { if (P.C && P.C.setCursor) P.C.setCursor(P.cursorM); } catch (e) { } P.follow(P.cursorM); },
  toCorner(n) {
    const c = P.corner(n); if (!c) return;
    P.range = [Math.max(0, c.m0 - 60), Math.min(P.tr.L, c.m1 + 60)];
    try { if (P.C && P.C.zoomCorner) P.C.zoomCorner(n); else if (P.C && P.C.setRange) P.C.setRange(P.range[0], P.range[1]); } catch (e) { }
    P.cursor(c.ma);
    const r = P.$('.rl-tbl tr[data-n="' + n + '"]'); if (r && r.scrollIntoView) r.scrollIntoView({ block: 'nearest' });
  },
  wholeLap() { if (!P.tr) return; P.range = null; try { if (P.C && P.C.zoomLap) P.C.zoomLap(); else if (P.C && P.C.setRange) P.C.setRange(0, P.tr.L); } catch (e) { } },
  zoomBy(f) {
    if (!P.tr) return;
    const L = P.tr.L, cur = P.range || [0, L], w = Math.min(L, Math.max(40, (cur[1] - cur[0]) * f));
    if (w >= L - 1) return P.wholeLap();
    let a = P.cursorM - w / 2; a = Math.max(0, Math.min(L - w, a));
    P.range = [a, a + w];
    try { if (P.C && P.C.setRange) P.C.setRange(a, a + w); } catch (e) { }
  },
  // the deck's REVIEW keys (the wb-* commands irdash already allows: dash/src/workbench.cs Workbench.Allowed)
  onDeck(cmd, arg) {
    if (cmd && typeof cmd === 'object') return P.deck(cmd);
    const name = String(cmd || '').replace(/^wb-/, ''), a = arg == null ? '' : String(arg);
    if (!P.tr && !/^lap-|^ref-/.test(name)) return false;
    const list = P.tr ? P.tr.corners.slice().sort((x, y) => x.ma - y.ma) : [];
    switch (name) {
      case 'next-corner': { if (!list.length) return false; const c = list.find(x => x.ma > P.cursorM + 2) || list[0]; P.toCorner(c.n); return true; }
      case 'prev-corner': { if (!list.length) return false; const c = list.slice().reverse().find(x => x.ma < P.cursorM - 2) || list[list.length - 1]; P.toCorner(c.n); return true; }
      case 'zoom-corner': { const c = P.cornerAt(P.cursorM) || list.slice().sort((x, y) => Math.abs(x.ma - P.cursorM) - Math.abs(y.ma - P.cursorM))[0]; if (c) P.toCorner(c.n); return !!c; }
      case 'zoom-reset': P.wholeLap(); return true;
      case 'zoom-in': P.zoomBy(0.5); return true;
      case 'zoom-out': P.zoomBy(2); return true;
      case 'step': { const d = parseFloat(a); P.cursor(P.cursorM + (num(d) && d ? d : 25)); return true; }
      case 'cursor': { const d = parseFloat(a); P.cursor(num(d) ? d : 0); return true; }
      case 'lap-next': case 'lap-prev': {
        const laps = P.laps(); if (!laps.length) return false;
        const i = laps.findIndex(l => l.n === P.sel.lap), j = (i + (name === 'lap-next' ? 1 : laps.length - 1)) % laps.length;
        P.pick('lap', laps[j].n); return true;
      }
      case 'ref-cycle': {
        const opts = P.refChoices().filter(o => !o.off).map(o => o.v); if (!opts.length) return false;
        const i = opts.indexOf(P.sel.ref == null ? 'none' : P.sel.ref); P.pick('ref', opts[(i + 1) % opts.length]); return true;
      }
    }
    return false;
  },
  // the "workbench" state part: { cmd, arg, seq, driving }; one run per new seq (the first look only learns it)
  deck(w) {
    if (!w) return false;
    const fresh = P.deckSeq !== null && w.seq !== P.deckSeq;
    P.deckSeq = w.seq;
    return fresh && w.cmd ? P.onDeck(w.cmd, w.arg) : false;
  },

  // ---------------------------------------------------------------- drawing
  busy(on) { const s = P.$('.rl-stack'); if (s) s.classList.toggle('busy', !!on); },
  msg(text, sub) {
    const m = P.$('.rl-msg'); if (!m) return;
    m.hidden = !text; m.innerHTML = text ? '<p class="rl-say">' + esc(text) + '</p>' + (sub ? '<p class="rl-sub">' + esc(sub) + '</p>' : '') : '';
    P.$('.rl').classList.toggle('only-msg', !!text);
  },
  msgStack(text) {
    const c = P.$('.rl-chart');
    // the word replaces the chart: let the library go first, or a later update() would draw on a canvas that is no longer there
    try { if (P.C && P.C.unmount) P.C.unmount(); } catch (e) { } P.C = null; P.chart = null; P.chartFor = null;
    const ro = P.$('.rl-readout'); if (ro) ro.replaceChildren();
    if (c) { c.replaceChildren(); const p = document.createElement('p'); p.className = 'rl-chartmsg'; p.textContent = text; c.appendChild(p); } },
  draw() {
    if (!P.el) return;
    const rv = P.rv, root = P.$('.rl');
    root.classList.toggle('stale', !!P.err && !!rv);
    if (P.err && !rv) return P.msg('Your laps show here when Paddock is back.');   // the shell's banner says what to press
    if (P.err) return;                                // offline with a review on screen: it stays, greyed
    if (!rv || rv.state === 'working') return P.msg(rv && rv.say ? rv.say : 'Reading your laps…');
    if (!P.laps().length) return P.msg(rv.note || 'No full lap yet', 'Drive one full lap and the traces show here.');
    P.msg(null);
    P.drawPick(); P.drawSum();
  },
  refChoices() {
    const ref = P.refInfo(), out = P.laps().map(l => ({ v: String(l.n), l, off: l.n === P.sel.lap }));
    if (ref && ref.kind === 'ever') out.push({ v: 'ever', ever: true, l: { n: 0, time: ref.time, counted: true } });
    return out;
  },
  drawPick() {
    const box = P.$('.rl-pick'); if (!box) return;
    const best = P.session().best, bestN = best ? best.lap : null, F = Fmt();
    const chip = (row, v, l, on, off, ever) => {
      const cls = ['chip', l.counted ? 'counted' : 'dim', l.n === bestN && l.counted ? 'best' : '', on ? 'on' : '', ever ? 'ever' : ''].filter(Boolean).join(' ');
      const top = ever ? 'Your best here' : 'Lap ' + l.n;
      const bot = ever ? F.lap(l.time) : l.counted ? F.lap(l.time) : whyWord(l.why);
      return '<button type="button" class="' + cls + '" data-row="' + row + '" data-lap="' + esc(v) + '"' + (off ? ' disabled' : '') + ' aria-pressed="' + (on ? 'true' : 'false') + '">' +
        '<span class="c-n">' + esc(top) + '</span><span class="c-t">' + esc(bot) + '</span></button>';
    };
    const lapRow = P.laps().map(l => chip('lap', String(l.n), l, l.n === P.sel.lap, false, false)).join('');
    const refRow = P.refChoices().map(o => chip('ref', o.v, o.l, P.sel.ref === o.v, o.off, o.ever)).join('');
    box.innerHTML = '<div class="row"><span class="lbl">This lap</span><div class="chips">' + lapRow + '</div></div>' +
      '<div class="row"><span class="lbl">Reference</span><div class="chips">' + refRow + '</div></div>';
    box.querySelectorAll('.chip.on').forEach(b => { if (b.scrollIntoView) b.scrollIntoView({ block: 'nearest', inline: 'nearest' }); });
  },
  // "Lap 7 1:34.210 against lap 9 1:33.832 · +0.378 s" and the theoretical best
  drawSum() {
    const vs = P.$('.rl-vs'), op = P.$('.rl-opt'); if (!vs) return;
    const F = Fmt(), laps = P.laps(), a = laps.find(l => l.n === P.sel.lap), ref = P.refInfo();
    const r = P.sel.ref === 'ever' ? { n: 0, time: ref && ref.time, ever: true } : laps.find(l => String(l.n) === P.sel.ref);
    let h = '';
    if (a) {
      h = esc('Lap ' + a.n + ' ' + F.lap(a.time));
      if (r) {
        h += esc(' against ' + (r.ever ? 'your best here' + (ref && num(ref.date) ? ' (' + dayWord(ref.date) + ')' : '') : 'lap ' + r.n) + ' ' + F.lap(r.time));
        if (num(a.time) && num(r.time)) { const d = a.time - r.time; h += esc(DOT) + '<b class="' + (d > 0.0005 ? 'loss' : d < -0.0005 ? 'gain' : '') + '">' + esc(F.delta(d)) + ' s</b>'; }
      } else h += esc(DOT + 'no reference lap');
    }
    vs.innerHTML = h;
    op.textContent = optimalLine(P.rv && P.rv.optimal);
  },
  drawStack(libs) {
    const box = P.$('.rl-chart'), ro = P.$('.rl-readout'), noref = P.$('.rl-noref'); if (!box || !P.tr) return;
    noref.hidden = !!P.tr.R;
    const Chart = libs && libs.Chart;
    if (!Chart || !Chart.mount) { P.msgStack('The traces come with the next update.'); return; }
    const opts = { x: { len: P.tr.L, unit: 'm' }, rows: P.tr.rows, corners: P.tr.corners, readout: ro };
    try {
      if (P.C && P.C.update && P.chartFor === P.tr.corners.length) P.C.update(P.tr.rows);
      else {
        if (P.C && P.C.unmount) P.C.unmount();
        box.replaceChildren(); ro.replaceChildren();
        P.chart = Chart.mount(box, opts);
        P.C = P.chart && typeof P.chart.setCursor === 'function' ? P.chart : Chart;
        P.chartFor = P.tr.corners.length;
        if (P.C.onCursor) P.C.onCursor(m => P.follow(m));
      }
      if (P.range && P.C.setRange) P.C.setRange(P.range[0], P.range[1]);
    } catch (e) { console.error(e); P.C = null; P.msgStack('The traces could not be drawn.'); }
  },
  drawMap(libs) {
    const box = P.$('.rl-map'); if (!box || !P.tr) return;
    const Map = libs && libs.Map, mp = (P.rv && P.rv.map) || {};
    if (!Map || !Map.mount) { if (!box.firstChild) { const p = document.createElement('p'); p.className = 'rl-chartmsg'; p.textContent = 'Map not available'; box.appendChild(p); } return; }
    try {
      if (!P.M) {
        box.replaceChildren();
        P.map = Map.mount(box, { key: mp.key || '', id: mp.id, size: Math.min(box.clientWidth, box.clientHeight) || 300 });
        P.M = P.map && typeof P.map.cursor === 'function' ? P.map : Map;
      }
      if (P.M.colour) P.M.colour(P.gain());
    } catch (e) { console.error(e); }
  },
  // where this lap gained (+) or lost (−) against the reference, per 1 % of the lap (Map.colour's array); flat without a reference
  gain() {
    const tr = P.tr, g = new Array(100).fill(0);
    if (!tr || !tr.delta) return g;
    for (let k = 0; k < 100; k++) {
      const i0 = Math.round(k / 100 * (tr.n - 1)), i1 = Math.round((k + 1) / 100 * (tr.n - 1));
      g[k] = -(tr.delta[i1] - tr.delta[i0]);
    }
    return g;
  },
  drawTable() {
    const t = P.$('.rl-tbl'), defs = P.$('.rl-defs'); if (!t) return;
    const hasRef = !!P.sel.ref, u = P.unit;
    const fd = (k, d) => { if (!num(d)) return ''; if (k === 'time') return Fmt().delta(d); const r = Math.round(d); return (r > 0 ? '+' : r < 0 ? '−' : '') + Math.abs(r) + (k === 'minSpeed' ? '' : ' m'); };
    const keys = ['brakeM', 'minSpeed', 'pickupM', 'time'];
    const head1 = '<tr><th rowspan="2">Corner</th>' + keys.map(k => '<th colspan="' + (hasRef ? 3 : 1) + '" class="grp">' + esc(NAMES[k]) + (k === 'minSpeed' ? ' (' + esc(u) + ')' : k === 'time' ? '' : ' (m)') + '</th>').join('') + '</tr>';
    const head2 = '<tr>' + keys.map(() => hasRef ? '<th class="num">This</th><th class="num">Ref</th><th class="num">±</th>' : '<th class="num">This</th>').join('') + '</tr>';
    const body = P.rows.map(r => '<tr data-n="' + r.n + '"><td class="cn">' + esc(r.label) + (r.detected ? ' <span class="det">detected</span>' : '') + '</td>' +
      keys.map(k => {
        const a = r.lap[k], b = r.ref[k], df = diff(k, a, b), plain = k === 'time' ? v => num(v) ? v.toFixed(3) : Fmt().none : v => num(v) ? String(Math.round(v)) : Fmt().none;
        return '<td class="num">' + plain(a) + '</td>' + (hasRef ? '<td class="num ref">' + plain(b) + '</td><td class="num d ' + df.cls + '">' + fd(k, df.d) + '</td>' : '');
      }).join('') + '</tr>').join('');
    t.innerHTML = '<thead>' + head1 + head2 + '</thead><tbody>' + (body || '<tr><td colspan="13" class="none">No corners for this track yet</td></tr>') + '</tbody>';
    defs.innerHTML = keys.map(k => '<span><b>' + esc(NAMES[k]) + '</b> = ' + esc(P.defs[k] || DEFS[k]) + '</span>').join('');
    P.mark(P.active);
  },
  mark(n) {
    P.active = n;
    if (!P.el) return;
    P.el.querySelectorAll('.rl-tbl tr.on').forEach(r => r.classList.remove('on'));
    if (n != null) { const r = P.$('.rl-tbl tr[data-n="' + n + '"]'); if (r) r.classList.add('on'); }
  },
};

export const Laps = P;              // the test reaches the state through this
export function mount(el, ctx, opts) { P.mount(el, ctx, opts); }
export function unmount() { P.unmount(); }
export function onDeck(cmd, arg) { return P.onDeck(cmd, arg); }
export default { name: 'review-laps', title: 'REVIEW', mount, unmount, onDeck };
