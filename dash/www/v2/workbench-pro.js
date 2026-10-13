// Paddock Analysis Workbench - the PRO page (docs\PLAN-v3.md P3): what Cosworth's Pi Toolbox charges for, free and local.
//   X/Y SCATTER  any channel against any channel, both laps, an optional colour channel, a least-squares curve (order 1 to 3) with its equation and R2;
//                the points inside the zoom window are bright, the cursor point has a ring (one cursor and one zoom for the whole page, like every display).
//   HISTOGRAM    how much of the lap time a channel spends in each band, both laps; the part inside the zoom window is brighter.
//   MATHS        his own formulas over the channels (Speed * 3.6, abs(SteeringWheelAngle) ...), saved per car, shown as a trace row. The formula is worked out by
//                the server's small parser (dash\src\protools.cs, no eval anywhere) and comes back as a channel on the same 1 m grid; mistakes come back in plain words.
//   EXPORT       the open lap and its reference as a real .xlsx or a CSV, distance-aligned, units in the header (built by the server).
// The tab exists only when the server answers (no dead tab). The engine (workbench.js) reaches this file only through window.WBX.
(function () {
'use strict';
var X = window.WBX, WB = window.WB;
if (!X || !X.api || !WB) return;
var A = X.api, S = A.S, el = A.el, clamp = A.clamp, C = A.C, FONT = A.FONT, P = A.P;
var PRESETS = [
  { id: 'latg', label: 'LATERAL G v SPEED', x: 'kmh', y: 'latG', ay: true, order: 2 },
  { id: 'slip', label: 'REAR SLIP v THROTTLE', x: 'thrPct', y: 'slipRear', order: 2 },
  { id: 'long', label: 'LONG G v BRAKE', x: 'brkPct', y: 'longG', order: 2 }];
var HISTS = [['kmh', 'SPEED'], ['thrPct', 'THROTTLE'], ['brkPct', 'BRAKE'], ['latG', 'LATERAL G'], ['Gear', 'GEAR'], ['steerDeg', 'STEERING']];
var EXPORT_DEFAULT = ['kmh', 'thrPct', 'brkPct', 'steerDeg', 'Gear', 'RPM', 'latG', 'longG', 'beta', 'wfPct'];
var EXAMPLES = [['Speed km/h', 'Speed * 3.6', 'km/h'], ['Steering size', 'abs(SteeringWheelAngle)', 'rad'], ['Lateral g size', 'abs(latG)', 'g'], ['Pedals together', 'if(Brake > 0.05 && Throttle > 0.05, 1, 0)', '']];
var PS = { srv: false, list: [], ver: 0, xy: { x: 'kmh', y: 'latG', c: '', ax: false, ay: true, order: 2, laps: 'both' }, hist: { key: 'kmh' }, exp: { sel: null, ref: true, last: null, busy: 0 }, p: {}, cache: {}, msg: '' };

function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
function D() { return A.data(); }
function lsGet(k, d) { try { var v = JSON.parse(localStorage.getItem(k) || 'null'); return v == null ? d : v; } catch (e) { return d; } }
function lsSet(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { } }
function minus(s) { s = String(s); if (/^-0(\.0*)?$/.test(s)) s = s.slice(1); return s.replace('-', '−'); }       // never "−0"
function withUnit(name, unit) { return unit && name.toLowerCase().indexOf(unit.toLowerCase()) < 0 ? name + ' ' + unit : name; }
function sig(v, d) { if (!isFinite(v)) return '–'; if (v === 0) return '0'; var s = Number(v.toPrecision(d || 4)); return minus(String(s)); }
function nice(v, spanHint) { var d = spanHint >= 100 ? 0 : spanHint >= 10 ? 1 : spanHint >= 1 ? 2 : 3; return minus(v.toFixed(d)); }
function below(p) { return Math.ceil(p.el.getBoundingClientRect().bottom) + 14; }

// ---------- channel names: the file's own name for a raw one, a plain label for a derived one or a maths one ----------
function info(k) {
  var m = A.meta(k);
  if (!m) return { key: k, title: k, unit: '', label: k, formula: '' };
  return { key: k, title: m.derived ? m.label : (m.name || k), unit: m.unit || '', label: m.label || k, formula: m.formula || '', derived: !!m.derived };
}
function tag(k) { var i = info(k); return withUnit(i.title, i.unit); }
function has(k) { var d = D(); return !!(d && k && d.A.c[k] && d.A.ok[k] !== false); }
// load a channel the page does not have yet (any of the 288); a derived one the car cannot make is said in words
function ensure(keys) {
  var jobs = [];
  keys.forEach(function (k) {
    if (!k || has(k)) return;
    var i = info(k);
    if (i.derived) { jobs.push(Promise.reject(new Error(i.title + ': not in this file'))); return; }
    jobs.push(A.fetchChannel(k));
  });
  return Promise.all(jobs);
}

// ---------- the server: maths channels and export ----------
// &scratch=1 keeps the saved formulas in a separate test folder; &probase=<path> points the page elsewhere (tests: a server without the pro routes = no tab)
var BASE = P.get('probase') || '/analysis/pro/';
function proUrl(op, extra) {
  var enc = encodeURIComponent, q = ['id=' + enc(P.get('id') || ''), 'lap=' + enc(P.get('lap') || ''), 'ref=' + enc(P.get('ref') || 'pb')];
  if (P.get('scratch')) q.push('scratch=1');
  for (var k in extra) q.push(k + '=' + enc(extra[k]));
  return BASE + op + '?' + q.join('&');
}
function carUrl(op, extra) {
  var enc = encodeURIComponent, q = ['car=' + enc(D().head.car || '')];
  if (P.get('scratch')) q.push('scratch=1');
  for (var k in extra) q.push(k + '=' + enc(extra[k]));
  return BASE + op + '?' + q.join('&');
}
// one formula on the lap and the reference; the reply is the binary channel reply, so the arrays drop straight into the page's data
function evalFormula(f) {
  return A.fetchBuf(proUrl('maths', { name: f.name, expr: f.expr, unit: f.unit || '' })).then(function (buf) {
    var r = A.readReply(buf), ch = r.head.channels[0], d = D();
    d.A.c[ch.key] = r.arr['lap.' + ch.key]; d.A.ok[ch.key] = true;
    if (d.R && r.arr['ref.' + ch.key]) { d.R.c[ch.key] = r.arr['ref.' + ch.key]; d.R.ok[ch.key] = true; }
    f.key = ch.key; f.err = ''; f.note = r.head.note || ''; f.blank = r.head.blank || 0; d.rng = {};
    A.addCatalog({ key: f.key, name: f.key, label: f.name, unit: f.unit || '', formula: f.expr, derived: true });
    PS.ver++; PS.cache = {};
    return f;
  });
}
function dropFormula(f) {
  var d = D(); if (!f.key) return;
  delete d.A.c[f.key]; delete d.A.ok[f.key]; if (d.R) { delete d.R.c[f.key]; delete d.R.ok[f.key]; }
  A.dropCatalog(f.key); var i = S.extra.indexOf(f.key); if (i >= 0) S.extra.splice(i, 1);
  d.rng = {}; PS.ver++; PS.cache = {};
}
function formulaByName(n) { for (var i = 0; i < PS.list.length; i++) if (PS.list[i].name.toLowerCase() === String(n).toLowerCase()) return PS.list[i]; return null; }

// the saved formulas of this car; each is worked out on this lap (one that cannot be - this car's file lacks a channel - stays in the list, red, with the reason)
function loadPro() {
  if (!A.LIVE) return Promise.resolve();
  derivePro();
  return A.fetchJson(carUrl('formulas', {})).then(function (j) {
    if (!j || j.error) throw new Error('no server');
    PS.srv = true; PS.list = (j.formulas || []).map(function (f) { return { name: f.name, unit: f.unit || '', expr: f.expr, key: f.key, err: '', note: '', blank: 0 }; });
    return Promise.all(PS.list.map(function (f) { return evalFormula(f).catch(function (e) { f.err = String(e.message || e); }); }));
  }).catch(function () { PS.srv = false; }).then(function () {
    initState();
  });
}
// two means the file's own channels do not give: front and rear wheel slip (same as dash\src\protools.cs)
function derivePro() {
  var d = D(); if (!d) return;
  [d.A, d.R].forEach(function (L) {
    if (!L) return; var c = L.c;
    function mean(a, b) { var o = new Float32Array(L.n); for (var i = 0; i < L.n; i++) o[i] = (a[i] + b[i]) / 2; return o; }
    if (c.slipLR && c.slipRR && !c.slipRear) { c.slipRear = mean(c.slipLR, c.slipRR); L.ok.slipRear = true; }
    if (c.slipLF && c.slipRF && !c.slipFront) { c.slipFront = mean(c.slipLF, c.slipRF); L.ok.slipFront = true; }
  });
  A.addCatalog({ key: 'slipFront', name: 'slipFront', label: 'Front wheel slip', unit: '%', dec: 1, formula: '(slip LF + slip RF) ÷ 2', derived: true });
  A.addCatalog({ key: 'slipRear', name: 'slipRear', label: 'Rear wheel slip', unit: '%', dec: 1, formula: '(slip LR + slip RR) ÷ 2', derived: true });
}
function initState() {
  var s = lsGet('wbProXY', null);
  if (s && typeof s === 'object' && has(s.x) && has(s.y)) { PS.xy = { x: s.x, y: s.y, c: has(s.c) ? s.c : '', ax: !!s.ax, ay: !!s.ay, order: clamp(s.order | 0, 0, 3), laps: s.laps === 'lap' || s.laps === 'ref' ? s.laps : 'both' }; }
  else { var p = PRESETS[0]; PS.xy = { x: p.x, y: p.y, c: '', ax: !!p.ax, ay: !!p.ay, order: p.order, laps: 'both' }; if (!has(PS.xy.x) || !has(PS.xy.y)) { var ks = Object.keys(D().A.c).filter(has); PS.xy.x = has('Speed') ? 'Speed' : ks[0]; PS.xy.y = has('Throttle') ? 'Throttle' : ks[1] || ks[0]; PS.xy.ay = false; } }
  var h = lsGet('wbProHist', null); PS.hist.key = h && has(h) ? h : has('kmh') ? 'kmh' : PS.xy.x;
  var e = lsGet('wbProExp', null);
  PS.exp.sel = Array.isArray(e) ? e.filter(function (k) { return typeof k === 'string' && (k.charAt(0) === '@' ? !!formulaByName(k.slice(1)) : (has(k) || !!A.meta(k))); }) : null;
  if (!PS.exp.sel || !PS.exp.sel.length) PS.exp.sel = EXPORT_DEFAULT.filter(has).concat(PS.list.filter(function (f) { return !f.err; }).map(function (f) { return '@' + f.name; }));
}
function saveState() { lsSet('wbProXY', PS.xy); lsSet('wbProHist', PS.hist.key); lsSet('wbProExp', PS.exp.sel); }
function availPro() { var d = D(); return !!(A.LIVE && PS.srv && d && d.A.c.kmh); }

// ---------- numbers: ticks, the colour ramp, the least-squares polynomial ----------
function niceTicks(lo, hi, want) {
  var span = hi - lo; if (!(span > 0)) { span = Math.abs(lo) || 1; lo -= span / 2; hi += span / 2; span = hi - lo; }
  var raw = span / want, p = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10)), f = raw / p, st = (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * p;
  var t0 = Math.ceil(lo / st - 1e-9), out = [];
  for (var i = t0; i * st <= hi + st * 1e-9; i++) out.push(Math.abs(i * st) < st * 1e-9 ? 0 : i * st);
  return { step: st, ticks: out };
}
function tickText(v, st) { var dec = Math.max(0, -Math.floor(Math.log(st) / Math.LN10 + 1e-9)); return minus(v.toFixed(Math.min(6, dec))); }
var RAMP = [[90, 70, 220], [210, 80, 170], [250, 160, 60], [250, 235, 170]];
function ramp(u) { u = clamp(u, 0, 1); var f = u * 3, k = Math.min(2, Math.floor(f)), v = f - k; return 'rgb(' + RAMP[k].map(function (a, q) { return Math.round(a + (RAMP[k + 1][q] - a) * v); }).join(',') + ')'; }

// Least squares through (xs, ys): the normal equations on u = (x - mean) / sd (well conditioned), solved by Gauss with pivoting, then turned back into
// a polynomial in x (coef[0] + coef[1] x + coef[2] x^2 + ...). r2 = 1 - residual / total spread. null when there are too few points or x never changes.
function polyfit(xs, ys, order) {
  var n = xs.length, i, j, k;
  if (n < order + 2) return null;
  var xm = 0, ym = 0; for (i = 0; i < n; i++) { xm += xs[i]; ym += ys[i]; } xm /= n; ym /= n;
  var vx = 0; for (i = 0; i < n; i++) vx += (xs[i] - xm) * (xs[i] - xm);
  var sd = Math.sqrt(vx / n); if (!(sd > 0) || sd < 1e-12 * (Math.abs(xm) + 1e-12)) return null;
  var m = order + 1, Sx = new Array(2 * order + 1), T = new Array(m), M = [], u, up;
  for (k = 0; k <= 2 * order; k++) Sx[k] = 0; for (k = 0; k < m; k++) T[k] = 0;
  for (i = 0; i < n; i++) { u = (xs[i] - xm) / sd; up = 1; for (k = 0; k <= 2 * order; k++) { Sx[k] += up; if (k < m) T[k] += up * ys[i]; up *= u; } }
  for (j = 0; j < m; j++) { M.push([]); for (k = 0; k < m; k++) M[j].push(Sx[j + k]); M[j].push(T[j]); }
  for (j = 0; j < m; j++) {
    var piv = j; for (i = j + 1; i < m; i++) if (Math.abs(M[i][j]) > Math.abs(M[piv][j])) piv = i;
    if (Math.abs(M[piv][j]) < 1e-12) return null;
    var tmp = M[j]; M[j] = M[piv]; M[piv] = tmp;
    for (i = j + 1; i < m; i++) { var f = M[i][j] / M[j][j]; for (k = j; k <= m; k++) M[i][k] -= f * M[j][k]; }
  }
  var c = new Array(m); for (j = m - 1; j >= 0; j--) { var s = M[j][m]; for (k = j + 1; k < m; k++) s -= M[j][k] * c[k]; c[j] = s / M[j][j]; }
  var binom = function (a, b) { var r = 1; for (var q = 1; q <= b; q++) r = r * (a - b + q) / q; return r; }, a = new Array(m);
  for (j = 0; j < m; j++) { var t = 0; for (k = j; k < m; k++) t += c[k] * binom(k, j) * Math.pow(-xm, k - j) / Math.pow(sd, k); a[j] = t; }
  var ssr = 0, sst = 0; for (i = 0; i < n; i++) { u = (xs[i] - xm) / sd; var yh = 0; for (k = m - 1; k >= 0; k--) yh = yh * u + c[k]; ssr += (ys[i] - yh) * (ys[i] - yh); sst += (ys[i] - ym) * (ys[i] - ym); }
  return { coef: a, order: order, n: n, r2: sst > 0 ? 1 - ssr / sst : null, xm: xm, sd: sd, c: c };
}
function polyAt(f, x) { var u = (x - f.xm) / f.sd, y = 0; for (var k = f.c.length - 1; k >= 0; k--) y = y * u + f.c[k]; return y; }
function polyText(coef) {
  var s = '', sup = ['', '', '²', '³'];
  for (var j = coef.length - 1; j >= 0; j--) {
    var v = coef[j], txt = sig(Math.abs(v)), term = j === 0 ? txt : txt + ' x' + sup[j];
    if (s === '') s = (v < 0 ? '−' : '') + term; else s += (v < 0 ? ' − ' : ' + ') + term;
  }
  return 'y = ' + s;
}

// ---------- X/Y data ----------
function xyCompute() {
  var d = D(), xy = PS.xy, sig0 = [xy.x, xy.y, xy.c, xy.ax, xy.ay, xy.order, PS.ver].join('|');
  if (PS.cache.xy && PS.cache.xy.sig === sig0) return PS.cache.xy;
  function side(L) {
    if (!L || !L.c[xy.x] || !L.c[xy.y]) return null;
    var X0 = L.c[xy.x], Y0 = L.c[xy.y], Cc = xy.c && L.c[xy.c] ? L.c[xy.c] : null, n = d.n, xs = new Float64Array(n), ys = new Float64Array(n), cs = Cc ? new Float64Array(n) : null, cx = [], cy = [];
    for (var i = 0; i < n; i++) {
      var x = X0[i], y = Y0[i]; if (xy.ax) x = Math.abs(x); if (xy.ay) y = Math.abs(y);
      if (isFinite(x) && isFinite(y)) { xs[i] = x; ys[i] = y; cx.push(x); cy.push(y); } else { xs[i] = NaN; ys[i] = NaN; }
      if (cs) cs[i] = Cc[i];
    }
    return { x: xs, y: ys, c: cs, n: cx.length, fit: xy.order > 0 ? polyfit(cx, cy, xy.order) : null };
  }
  var o = { sig: sig0, lap: side(d.A), ref: d.R ? side(d.R) : null };
  var lo = [1e300, 1e300, 1e300], hi = [-1e300, -1e300, -1e300];
  [o.lap, o.ref].forEach(function (s) {
    if (!s) return;
    for (var i = 0; i < d.n; i++) {
      if (s.x[i] !== s.x[i]) continue;
      if (s.x[i] < lo[0]) lo[0] = s.x[i]; if (s.x[i] > hi[0]) hi[0] = s.x[i]; if (s.y[i] < lo[1]) lo[1] = s.y[i]; if (s.y[i] > hi[1]) hi[1] = s.y[i];
      if (s.c && isFinite(s.c[i])) { if (s.c[i] < lo[2]) lo[2] = s.c[i]; if (s.c[i] > hi[2]) hi[2] = s.c[i]; }
    }
  });
  o.lo = lo; o.hi = hi; o.ok = !!(o.lap && o.lap.n > 1 && lo[0] <= hi[0]);
  PS.cache.xy = o; return o;
}

// ---------- the X/Y display ----------
function Scatter(box) {
  A.Display.call(this, box, ''); this.kind = 'xy'; var self = this;
  this.ctl = el('div'); this.el.insertBefore(this.ctl, this.stage);
  this.eq = el('div', 'pr-eq'); this.el.appendChild(this.eq);
  this.stage.addEventListener('mousemove', function (e) {
    if (S.playing || !self.d || !self.d.ok) return;
    var p = self.local(e), best = -1, bd = 22 * 22, s = self.d.lap, i;
    for (i = 0; i < s.x.length; i++) { if (s.x[i] !== s.x[i]) continue; var dx = self.px(s.x[i]) - p[0], dy = self.py(s.y[i]) - p[1], q = dx * dx + dy * dy; if (q < bd) { bd = q; best = i; } }
    if (best >= 0) A.setCursor(best, true);
  });
  this.controls(); this.refreshPh(); this.oy = Math.round(this.stage.getBoundingClientRect().top - this.el.getBoundingClientRect().top);   // where the canvas starts inside the panel (the text boxes the overlap test uses)
}
Scatter.prototype = Object.create(A.Display.prototype);
Scatter.prototype.refreshPh = function () {
  var xy = PS.xy; this.ph.innerHTML = 'X/Y · <b>' + esc(tag(xy.y)) + (xy.ay ? ' (size)' : '') + '</b> against <b>' + esc(tag(xy.x)) + (xy.ax ? ' (size)' : '') + '</b>' + (xy.c ? ' · colour <b>' + esc(tag(xy.c)) + '</b>' : '');
};
function btn(txt, cls, fn, title) { var b = el('span', 'pr-btn ' + (cls || ''), txt); if (title) b.title = title; b.addEventListener('click', fn); return b; }
Scatter.prototype.controls = function () {
  var self = this, xy = PS.xy, row1 = el('div', 'pr-ctl'), row2 = el('div', 'pr-ctl');
  this.ctl.innerHTML = ''; this.ctl.appendChild(row1); this.ctl.appendChild(row2);
  row1.appendChild(el('span', 'pr-lab', 'PRESET'));
  PRESETS.forEach(function (p) { row1.appendChild(btn(p.label, 'sm' + (xy.x === p.x && xy.y === p.y && !!xy.ay === !!p.ay ? ' on' : ''), function () { self.apply({ x: p.x, y: p.y, ax: !!p.ax, ay: !!p.ay, order: p.order, c: '' }); })); });
  row1.appendChild(el('span', 'pr-lab', 'LAPS'));
  [['both', 'BOTH'], ['lap', 'LAP'], ['ref', 'REF']].forEach(function (q) { if (q[0] === 'ref' && !D().R) return; row1.appendChild(btn(q[1], 'sm' + (xy.laps === q[0] ? ' on' : ''), function () { PS.xy.laps = q[0]; saveState(); self.controls(); A.need.s = true; })); });
  function pick(which, title) { A.openPicker(function (e) { var o = {}; o[which] = e.key; self.apply(o); }, title); }
  row2.appendChild(el('span', 'pr-lab', 'X')); row2.appendChild(btn(info(xy.x).title, '', function () { pick('x', 'Pick the X channel'); }, tag(xy.x)));
  row2.appendChild(btn('|x|', 'sm' + (xy.ax ? ' on' : ''), function () { self.apply({ ax: !PS.xy.ax }); }, 'absolute x'));
  row2.appendChild(el('span', 'pr-lab', 'Y')); row2.appendChild(btn(info(xy.y).title, '', function () { pick('y', 'Pick the Y channel'); }, tag(xy.y)));
  row2.appendChild(btn('|y|', 'sm' + (xy.ay ? ' on' : ''), function () { self.apply({ ay: !PS.xy.ay }); }, 'absolute y'));
  row2.appendChild(el('span', 'pr-lab', 'COLOUR')); row2.appendChild(btn(xy.c ? info(xy.c).title : 'NONE', xy.c ? 'on' : 'off', function () { pick('c', 'Pick the colour channel'); }, xy.c ? tag(xy.c) : 'colour channel'));
  if (xy.c) row2.appendChild(btn('×', 'sm', function () { self.apply({ c: '' }); }, 'no colour channel'));
  row2.appendChild(el('span', 'pr-lab', 'CURVE'));
  [[0, 'OFF'], [1, '1'], [2, '2'], [3, '3']].forEach(function (q) { row2.appendChild(btn(q[1], 'sm' + (xy.order === q[0] ? ' on' : ''), function () { self.apply({ order: q[0] }); }, q[0] ? 'curve of order ' + q[0] : 'no curve')); });
};
Scatter.prototype.apply = function (o) {
  var self = this, next = {}, k; for (k in PS.xy) next[k] = PS.xy[k]; for (k in o) next[k] = o[k];
  PS.msg = ''; this.eq.innerHTML = '<div class="pr-note">Loading…</div>';
  return ensure([next.x, next.y, next.c]).then(function () { PS.xy = next; saveState(); self.controls(); self.refreshPh(); A.need.s = true; A.need.o = true; }, function (e) {
    PS.msg = String(e.message || e); self.showEq();
  });
};
// plot box inside the canvas, and the maps from data to pixels
Scatter.prototype.geom = function (d) {
  var W = this.box.w, H = this.box.h, L = 74, R = 22, T = 30, B = 38;
  var tx = niceTicks(d.lo[0] - (d.hi[0] - d.lo[0]) * 0.03, d.hi[0] + (d.hi[0] - d.lo[0]) * 0.03, 8), ty = niceTicks(d.lo[1] - (d.hi[1] - d.lo[1]) * 0.05, d.hi[1] + (d.hi[1] - d.lo[1]) * 0.05, 6);
  var x0 = Math.min(tx.ticks[0] === undefined ? d.lo[0] : tx.ticks[0], d.lo[0]), x1 = Math.max(tx.ticks.length ? tx.ticks[tx.ticks.length - 1] : d.hi[0], d.hi[0]);
  var y0 = Math.min(ty.ticks[0] === undefined ? d.lo[1] : ty.ticks[0], d.lo[1]), y1 = Math.max(ty.ticks.length ? ty.ticks[ty.ticks.length - 1] : d.hi[1], d.hi[1]);
  if (x1 - x0 < 1e-12) { x0 -= 0.5; x1 += 0.5; } if (y1 - y0 < 1e-12) { y0 -= 0.5; y1 += 0.5; }
  var g = { L: L, T: T, w: W - L - R, h: H - T - B, x0: x0, x1: x1, y0: y0, y1: y1, tx: tx, ty: ty };
  this.px = function (x) { return L + (x - x0) / (x1 - x0) * g.w; };
  this.py = function (y) { return T + g.h - (y - y0) / (y1 - y0) * g.h; };
  return g;
};
Scatter.prototype.drawStatic = function () {
  var g = this.cs, W = this.box.w, H = this.box.h, self = this, xy = PS.xy; this.clear(g); this.tbS = [];
  var d = this.d = xyCompute();
  if (!d.ok) { this.text(g, this.tbS, 'No values on this lap', 0, 40, 18, C.mute, 'left'); this.showEq(); return; }
  var G = this.G = this.geom(d), z0 = Math.floor(S.z0), z1 = Math.ceil(S.z1), zoomed = A.zoomed(), i;
  // grid and numbers
  g.lineWidth = 1; g.strokeStyle = '#17171a';
  G.tx.ticks.forEach(function (v) { var x = Math.round(self.px(v)) + 0.5; if (x < G.L - 1 || x > G.L + G.w + 1) return; g.beginPath(); g.moveTo(x, G.T); g.lineTo(x, G.T + G.h); g.stroke(); self.text(g, self.tbS, tickText(v, G.tx.step), x, H - 14, 14, C.dim, 'center'); });
  G.ty.ticks.forEach(function (v) { var y = Math.round(self.py(v)) + 0.5; if (y < G.T - 1 || y > G.T + G.h + 1) return; g.beginPath(); g.moveTo(G.L, y); g.lineTo(G.L + G.w, y); g.stroke(); self.text(g, self.tbS, tickText(v, G.ty.step), G.L - 8, y + 5, 14, C.dim, 'right'); });
  g.strokeStyle = C.line; g.strokeRect(G.L + 0.5, G.T + 0.5, G.w, G.h);
  if (G.y0 < 0 && G.y1 > 0) { g.strokeStyle = '#34343a'; var zy = Math.round(this.py(0)) + 0.5; g.beginPath(); g.moveTo(G.L, zy); g.lineTo(G.L + G.w, zy); g.stroke(); }
  if (G.x0 < 0 && G.x1 > 0) { g.strokeStyle = '#34343a'; var zx = Math.round(this.px(0)) + 0.5; g.beginPath(); g.moveTo(zx, G.T); g.lineTo(zx, G.T + G.h); g.stroke(); }
  this.text(g, this.tbS, tag(xy.x) + (xy.ax ? ' · size' : ''), G.L + G.w, H - 1, 15, C.mute, 'right');
  this.text(g, this.tbS, tag(xy.y) + (xy.ay ? ' · size' : ''), 0, 16, 15, C.mute, 'left');
  // points: the reference first (under), the lap on top; outside the zoom window they are dim
  var bins = 28, cr = d.hi[2] - d.lo[2];
  function dots(s, isRef) {
    if (!s) return;
    var batches = {};
    for (i = 0; i < s.x.length; i++) {
      var x = s.x[i]; if (x !== x) continue;
      var inZ = !zoomed || (i >= z0 && i <= z1), px = self.px(x), py = self.py(s.y[i]);
      var key = s.c && cr > 0 && isFinite(s.c[i]) ? Math.round((s.c[i] - d.lo[2]) / cr * (bins - 1)) : -1;
      var b = (inZ ? 'a' : 'd') + key; (batches[b] || (batches[b] = [])).push(px, py);
    }
    Object.keys(batches).forEach(function (b) {
      var out = b.charAt(0) === 'd', kk = parseInt(b.slice(1), 10), r = isRef ? 2 : 2.4, arr = batches[b];
      g.globalAlpha = out ? 0.16 : isRef ? (s.c ? 0.9 : 0.5) : 1;
      if (isRef) { g.strokeStyle = C.ref; g.lineWidth = 1; g.beginPath(); for (var q = 0; q < arr.length; q += 2) { g.moveTo(arr[q] + r, arr[q + 1]); g.arc(arr[q], arr[q + 1], r, 0, 6.2832); } if (s.c) g.stroke(); else { g.fillStyle = C.ref; g.fill(); } }
      else { g.fillStyle = kk >= 0 ? ramp(kk / (bins - 1)) : C.gold; g.beginPath(); for (var q2 = 0; q2 < arr.length; q2 += 2) { g.moveTo(arr[q2] + r, arr[q2 + 1]); g.arc(arr[q2], arr[q2 + 1], r, 0, 6.2832); } g.fill(); }
    });
    g.globalAlpha = 1;
  }
  if (xy.laps !== 'lap') dots(d.ref, true);
  if (xy.laps !== 'ref') dots(d.lap, false);
  // the curves
  function curve(s, col, dash) {
    if (!s || !s.fit) return; g.save(); g.beginPath(); g.rect(G.L, G.T, G.w, G.h); g.clip();
    var lo = Infinity, hi = -Infinity; for (var q = 0; q < s.x.length; q++) if (s.x[q] === s.x[q]) { if (s.x[q] < lo) lo = s.x[q]; if (s.x[q] > hi) hi = s.x[q]; }
    var path = function () { g.beginPath(); for (var k = 0; k <= 120; k++) { var xv = lo + (hi - lo) * k / 120, yv = polyAt(s.fit, xv); if (k) g.lineTo(self.px(xv), self.py(yv)); else g.moveTo(self.px(xv), self.py(yv)); } };
    g.lineJoin = 'round'; g.setLineDash([]); path(); g.strokeStyle = 'rgba(11,11,12,.85)'; g.lineWidth = 5; g.stroke();
    path(); g.strokeStyle = col; g.lineWidth = 2.4; g.setLineDash(dash || []); g.stroke(); g.setLineDash([]); g.restore();
  }
  if (xy.order > 0) { if (xy.laps !== 'ref') curve(d.lap, xy.c ? '#fff3c4' : C.gold, null); if (xy.laps !== 'lap') curve(d.ref, C.ref, [6, 5]); }
  // the colour key (top right of the plot)
  if (xy.c && cr > 0) {
    var kx = G.L + G.w - 190, ky = G.T + 10, kw = 170;
    g.fillStyle = 'rgba(11,11,12,.78)'; g.fillRect(kx - 10, ky - 8, kw + 20, 52);
    for (i = 0; i < kw; i++) { g.fillStyle = ramp(i / (kw - 1)); g.fillRect(kx + i, ky + 18, 1, 8); }
    this.text(g, this.tbS, tag(xy.c), kx + kw, ky + 6, 13, C.mute, 'right');
    this.text(g, this.tbS, nice(d.lo[2], cr), kx, ky + 41, 13, C.mute, 'left'); this.text(g, this.tbS, nice(d.hi[2], cr), kx + kw, ky + 41, 13, C.mute, 'right');
  }
  this.showEq();
};
// the equation lines under the picture (DOM text: easy to read, easy to copy)
Scatter.prototype.showEq = function () {
  var d = this.d || xyCompute(), xy = PS.xy, h = '';
  function line(cls, label, s) {
    if (!s) return '<div class="pr-note">' + label + ' · no values</div>';
    if (xy.order === 0) return '<div><span class="tg ' + cls + '">' + label + '</span><span class="sm">' + s.n + ' points</span></div>';
    if (!s.fit) return '<div><span class="tg ' + cls + '">' + label + '</span><span class="sm">' + s.n + ' points · ' + (s.n < xy.order + 2 ? 'too few for a curve' : 'x constant') + '</span></div>';
    return '<div><span class="tg ' + cls + '">' + label + '</span>' + polyText(s.fit.coef) + ' · <b>R² ' + (s.fit.r2 == null ? '–' : s.fit.r2.toFixed(3)) + '</b> <span class="sm">' + s.n + ' points</span></div>';
  }
  if (d && d.ok) {
    if (xy.laps !== 'ref') h += line('gold', 'LAP ' + D().head.lap.lap, d.lap);
    if (xy.laps !== 'lap' && d.ref) h += line('ref', 'REF ' + D().head.ref.lap, d.ref);
  }
  if (PS.msg) h += '<div class="pr-note err">' + esc(PS.msg) + '</div>';
  this.eq.innerHTML = h;
};
Scatter.prototype.drawOverlay = function () {
  var g = this.co, d = this.d, xy = PS.xy, G = this.G; this.clear(g); this.tbO = [];
  if (!d || !d.ok || !G) return;
  var ci = clamp(Math.round(S.cur), 0, D().n - 1), lines = [];
  function ring(s, i, col, r) { if (!s || s.x[i] !== s.x[i]) return null; var x = this_px(s.x[i]), y = this_py(s.y[i]); g.strokeStyle = col; g.lineWidth = 2.4; g.beginPath(); g.arc(x, y, r, 0, 6.2832); g.stroke(); g.fillStyle = 'rgba(11,11,12,.55)'; g.beginPath(); g.arc(x, y, r - 3, 0, 6.2832); g.fill(); return [x, y]; }
  var self = this, this_px = function (v) { return self.px(v); }, this_py = function (v) { return self.py(v); };
  if (xy.laps !== 'lap' && d.ref) { if (ring(d.ref, ci, C.ref, 7)) lines.push(['REF ', d.ref, C.ref]); }
  if (xy.laps !== 'ref') { if (ring(d.lap, ci, C.gold, 8)) lines.push(['LAP ', d.lap, C.gold]); }
  var dx = info(xy.x), dy = info(xy.y);
  lines.reverse().forEach(function (q, k) {
    var s = q[1], txt = q[0] + sig(s.x[ci], 4) + (dx.unit ? ' ' + dx.unit : '') + ' · ' + sig(s.y[ci], 3) + (dy.unit ? ' ' + dy.unit : '');
    g.font = '16px ' + FONT; var w = g.measureText(txt).width;
    g.fillStyle = 'rgba(11,11,12,.8)'; g.fillRect(G.L + 8, G.T + 8 + k * 24, w + 14, 22);
    self.text(g, self.tbO, txt, G.L + 15, G.T + 24 + k * 24, 16, q[2], 'left');
  });
};

// ---------- histogram ----------
function stepUp(w) { var p = Math.pow(10, Math.floor(Math.log(w) / Math.LN10 + 1e-9)), m = w / p; return p * (m < 1.5 ? 2 : m < 3.5 ? 5 : 10); }
function stepDown(w) { var p = Math.pow(10, Math.floor(Math.log(w) / Math.LN10 + 1e-9)), m = w / p; return p * (m < 1.5 ? 0.5 : m < 3.5 ? 1 : 2); }
function niceWidth(w) { var p = Math.pow(10, Math.floor(Math.log(w) / Math.LN10)), m = w / p; return p * (m < 1.5 ? 1 : m < 3.5 ? 2 : m < 7.5 ? 5 : 10); }
// time weights: the time each 1 m sample stands for (trapezoids), so a bar is a share of the lap TIME and the bars add up to 100 %
function timeWeights(t) { var n = t.length, w = new Float64Array(n), i; if (n < 2) return w; w[0] = (t[1] - t[0]) / 2; w[n - 1] = (t[n - 1] - t[n - 2]) / 2; for (i = 1; i < n - 1; i++) w[i] = (t[i + 1] - t[i - 1]) / 2; return w; }
function histCompute(key) {
  var d = D(), sg = key + '|' + PS.ver;
  if (PS.cache.hist && PS.cache.hist.sig === sg) return PS.cache.hist;
  var sides = [d.A, d.R], i, lo = Infinity, hi = -Infinity, all = [], integer = true;
  if (!d.A.c[key]) return null;
  sides.forEach(function (L) { if (!L || !L.c[key]) return; var a = L.c[key]; for (i = 0; i < d.n; i++) { var v = a[i]; if (!isFinite(v)) continue; all.push(v); if (v < lo) lo = v; if (v > hi) hi = v; if (integer && Math.abs(v - Math.round(v)) > 1e-6) integer = false; } });
  if (!all.length) return null;
  var w, e0, nb;
  if (integer && hi - lo <= 40) { w = 1; e0 = lo - 0.5; nb = Math.round(hi - lo) + 1; }       // gears, flags: one bar per whole number
  else {
    all.sort(function (a, b) { return a - b; });
    var N = all.length, q1 = all[Math.floor(N * 0.25)], q3 = all[Math.floor(N * 0.75)], iqr = q3 - q1;
    w = iqr > 0 ? 2 * iqr / Math.cbrt(N) : (hi - lo) / (1 + Math.log(N) / Math.LN2);      // Freedman-Diaconis, else Sturges
    if (!(w > 0)) w = 1;
    w = niceWidth(w);
    for (var guard = 0; guard < 12; guard++) {
      e0 = Math.floor(lo / w + 1e-9) * w; nb = Math.max(1, Math.ceil((hi - e0) / w - 1e-9));
      if (nb > 36) w = stepUp(w); else if (nb < 8 && hi > lo && nb * 2 <= 36) w = stepDown(w); else break;
    }
  }
  var o = { sig: sg, key: key, w: w, e0: e0, nb: nb, integer: integer, edges: [] };
  for (i = 0; i <= nb; i++) o.edges.push(e0 + i * w);
  function side(L) {
    if (!L || !L.c[key]) return null;
    var a = L.c[key], wt = timeWeights(L.t), bins = new Float64Array(nb), T = 0, sum = 0, mn = Infinity, mx = -Infinity;
    for (i = 0; i < d.n; i++) { var v = a[i]; if (!isFinite(v)) continue; var b = clamp(Math.floor((v - e0) / w + 1e-9), 0, nb - 1); bins[b] += wt[i]; T += wt[i]; sum += v * wt[i]; if (v < mn) mn = v; if (v > mx) mx = v; }
    var pct = new Float64Array(nb), top = 0; for (i = 0; i < nb; i++) { pct[i] = T > 0 ? bins[i] / T * 100 : 0; if (pct[i] > pct[top]) top = i; }
    return { pct: pct, T: T, mean: T > 0 ? sum / T : NaN, min: mn, max: mx, top: top, wt: wt, a: a };
  }
  o.lap = side(d.A); o.ref = side(d.R); PS.cache.hist = o; return o;
}
function HistView(box) {
  A.Display.call(this, box, ''); this.kind = 'hist'; var self = this;
  this.ctl = el('div'); this.el.insertBefore(this.ctl, this.stage);
  this.st = el('div', 'pr-eq h'); this.el.appendChild(this.st);
  this.stage.addEventListener('mousemove', function (e) {
    if (S.playing || !self.d || !self.G) return;
    var p = self.local(e), b = Math.floor((p[0] - self.G.L) / self.G.w * self.d.nb); if (b < 0 || b >= self.d.nb) return;
    // the cursor goes to the stretch of the lap in that bar that is nearest to where it is now
    var a = self.d.lap.a, lo = self.d.e0 + b * self.d.w, hi = lo + self.d.w;
    var best = -1, bd = 1e9; for (var j = 0; j < a.length; j++) if (a[j] >= lo && (a[j] < hi || (b === self.d.nb - 1 && a[j] <= hi))) { var dd = Math.abs(j - S.cur); if (dd < bd) { bd = dd; best = j; } }
    if (best >= 0) A.setCursor(best, true);
  });
  this.controls(); this.refreshPh(); this.oy = Math.round(this.stage.getBoundingClientRect().top - this.el.getBoundingClientRect().top);
}
HistView.prototype = Object.create(A.Display.prototype);
HistView.prototype.refreshPh = function () { this.ph.innerHTML = 'Histogram · <b>' + esc(tag(PS.hist.key)) + '</b>'; };
HistView.prototype.controls = function () {
  var self = this, row = el('div', 'pr-ctl'); this.ctl.innerHTML = ''; this.ctl.appendChild(row);
  HISTS.forEach(function (q) { if (!has(q[0])) return; row.appendChild(btn(q[1], 'sm' + (PS.hist.key === q[0] ? ' on' : ''), function () { self.set(q[0]); })); });
  var custom = !HISTS.some(function (q) { return q[0] === PS.hist.key; });
  row.appendChild(btn(custom ? info(PS.hist.key).title : 'ANY CHANNEL…', 'sm' + (custom ? ' on' : ''), function () { A.openPicker(function (e) { self.set(e.key); }, 'Pick the histogram channel'); }));
};
HistView.prototype.set = function (k) {
  var self = this; PS.msg = '';
  return ensure([k]).then(function () { PS.hist.key = k; saveState(); self.controls(); self.refreshPh(); A.need.s = true; A.need.o = true; self.st.innerHTML = ''; }, function (e) { self.st.innerHTML = '<div class="pr-note err">' + esc(String(e.message || e)) + '</div>'; });
};
HistView.prototype.drawStatic = function () {
  var g = this.cs, W = this.box.w, H = this.box.h, self = this, key = PS.hist.key; this.clear(g); this.tbS = [];
  var d = this.d = histCompute(key);
  if (!d) { this.text(g, this.tbS, 'No values on this lap', 0, 40, 18, C.mute, 'left'); this.st.innerHTML = ''; return; }
  var G = this.G = { L: 54, T: 8, w: W - 54 - 10, h: H - 8 - 44 }, i, k;
  var ymax = 0; for (k = 0; k < d.nb; k++) ymax = Math.max(ymax, d.lap.pct[k], d.ref ? d.ref.pct[k] : 0);
  var yt = niceTicks(0, ymax * 1.08, 4), top = yt.ticks[yt.ticks.length - 1] || ymax; if (top < ymax) top = ymax * 1.05;
  var bx = function (b) { return G.L + b / d.nb * G.w; }, by = function (v) { return G.T + G.h - v / top * G.h; };
  g.strokeStyle = '#17171a'; g.lineWidth = 1;
  yt.ticks.forEach(function (v) { var y = Math.round(by(v)) + 0.5; g.beginPath(); g.moveTo(G.L, y); g.lineTo(G.L + G.w, y); g.stroke(); self.text(g, self.tbS, tickText(v, yt.step) + ' %', G.L - 8, y + 5, 14, C.dim, 'right'); });
  g.strokeStyle = C.line; g.beginPath(); g.moveTo(G.L, G.T + G.h + 0.5); g.lineTo(G.L + G.w, G.T + G.h + 0.5); g.stroke();
  // the zoom window's part of the lap: the bars are the whole lap; the part inside the window is the bright part (a dim bar when zoomed)
  var zoomed = A.zoomed(), zin = null;
  if (zoomed) { zin = new Float64Array(d.nb); var z0 = Math.max(0, Math.floor(S.z0)), z1 = Math.min(d.lap.a.length - 1, Math.ceil(S.z1)); for (i = z0; i <= z1; i++) { var v = d.lap.a[i]; if (!isFinite(v)) continue; zin[clamp(Math.floor((v - d.e0) / d.w + 1e-9), 0, d.nb - 1)] += d.lap.wt[i] / d.lap.T * 100; } }
  for (k = 0; k < d.nb; k++) {
    var h0 = d.lap.pct[k]; if (h0 <= 0) continue;
    g.fillStyle = zoomed ? 'rgba(242,194,48,.28)' : 'rgba(242,194,48,.82)'; g.fillRect(bx(k) + 1, by(h0), Math.max(1, bx(k + 1) - bx(k) - 2), G.T + G.h - by(h0));
    if (zoomed && zin[k] > 0) { g.fillStyle = C.gold; g.fillRect(bx(k) + 1, by(zin[k]), Math.max(1, bx(k + 1) - bx(k) - 2), G.T + G.h - by(zin[k])); }
  }
  if (d.ref) { g.strokeStyle = C.ref; g.lineWidth = 1.5; g.beginPath(); for (k = 0; k < d.nb; k++) { var yy = by(d.ref.pct[k]); if (k) g.lineTo(bx(k), by(d.ref.pct[k - 1])); if (k) g.lineTo(bx(k), yy); else g.moveTo(bx(k), yy); g.lineTo(bx(k + 1), yy); } g.stroke(); }
  // numbers under the bars: the whole numbers for gears and flags, else the band edges (every few bars)
  var every = Math.max(1, Math.ceil(d.nb / 9)), unit = info(key).unit, st = d.w;
  for (k = 0; k <= d.nb; k++) {
    if (d.integer) { if (k === d.nb) continue; if (k % every) continue; this.text(g, this.tbS, minus(String(Math.round(d.e0 + 0.5 + k))), (bx(k) + bx(k + 1)) / 2, H - 22, 14, C.dim, 'center'); }
    else if (k % every === 0) this.text(g, this.tbS, tickText(d.edges[k], st), bx(k), H - 22, 14, C.dim, 'center');
  }
  this.text(g, this.tbS, tag(key), G.L + G.w, H - 4, 15, C.mute, 'right');
  this.text(g, this.tbS, 'bar width ' + (d.integer ? '1' : sig(d.w, 3)) + (unit ? ' ' + unit : '') + ' · ' + d.nb + ' bars', G.L, H - 4, 14, C.dim, 'left');
  // the facts under the picture
  function line(cls, label, s) {
    if (!s) return ''; var lo = d.e0 + s.top * d.w, hi = lo + d.w;
    return '<div><span class="tg ' + cls + '">' + label + '</span>lowest <b>' + sig(s.min, 4) + '</b> · average <b>' + sig(s.mean, 4) + '</b> · highest <b>' + sig(s.max, 4) + '</b>' + (unit ? ' ' + esc(unit) : '') + ' <span class="sm">· most time ' + (d.integer ? 'in ' + sig(lo + 0.5, 3) : 'between ' + sig(lo, 4) + ' and ' + sig(hi, 4)) + ' (' + s.pct[s.top].toFixed(1) + ' %)</span></div>';
  }
  this.st.innerHTML = line('gold', 'LAP ' + D().head.lap.lap, d.lap) + (d.ref ? line('ref', 'REF ' + D().head.ref.lap, d.ref) : '');
};
HistView.prototype.drawOverlay = function () {
  var g = this.co, d = this.d, G = this.G; this.clear(g); this.tbO = [];
  if (!d || !G) return;
  var ci = clamp(Math.round(S.cur), 0, D().n - 1), self = this;
  [[d.lap, C.gold, ci, 'LAP'], [d.ref, C.ref, ci, 'REF']].forEach(function (q, k) {
    var s = q[0]; if (!s) return; var v = s.a[q[2]]; if (!isFinite(v)) return;
    var b = clamp(Math.floor((v - d.e0) / d.w + 1e-9), 0, d.nb - 1), x0 = G.L + b / d.nb * G.w, x1 = G.L + (b + 1) / d.nb * G.w, x = G.L + clamp((v - d.e0) / (d.w * d.nb), 0, 1) * G.w;
    g.strokeStyle = q[1]; g.lineWidth = 2; g.beginPath(); g.moveTo(x0 + 1, G.T + G.h + 4); g.lineTo(x1 - 1, G.T + G.h + 4); g.stroke();
    g.beginPath(); g.moveTo(x, G.T + G.h + 2); g.lineTo(x, G.T + G.h - 10); g.stroke();
  });
};

// ---------- maths channels ----------
function MathsPanel(box) {
  A.Display.call(this, box, ''); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'maths';
  var self = this;
  this.ph.innerHTML = 'Maths channels';
  this.list = el('div', 'pr-mlist'); this.stage.appendChild(this.list);
  var form = el('div', 'pr-form'); this.stage.appendChild(form);
  this.nm = el('input', 'pr-in'); this.nm.placeholder = 'name'; this.nm.style.width = '150px';
  this.ex = el('input', 'pr-in'); this.ex.placeholder = 'formula'; this.ex.style.flex = '1';
  this.un = el('input', 'pr-in'); this.un.placeholder = 'unit'; this.un.style.width = '62px';
  [this.nm, this.ex, this.un].forEach(function (i) {
    i.spellcheck = false; i.autocomplete = 'off';
    i.addEventListener('keydown', function (e) { e.stopPropagation(); if (e.key === 'Enter') { self.add(); e.preventDefault(); } });
  });
  this.addB = el('span', 'pr-add', 'ADD'); this.addB.addEventListener('click', function () { self.add(); });
  var pick = btn('CHANNELS', 'sm', function () { A.openPicker(function (e) { var i = self.ex, s = i.selectionStart == null ? i.value.length : i.selectionStart, nm = e.derived ? e.key : e.name; i.value = i.value.slice(0, s) + nm + i.value.slice(i.selectionEnd == null ? s : i.selectionEnd); i.focus(); }, 'Put a channel name in the formula'); }, 'pick a channel name to put in the formula');
  form.appendChild(this.nm); form.appendChild(this.ex); form.appendChild(this.un); form.appendChild(this.addB); form.appendChild(pick);
  this.msg = el('div', 'pr-note'); this.stage.appendChild(this.msg);
  this.exs = el('div', 'pr-ex'); this.stage.appendChild(this.exs);
  this.help = el('div', 'pr-note help', 'abs sqrt min max sin cos if(c, a, b)'); this.stage.appendChild(this.help);
  this.renderList();
}
MathsPanel.prototype = Object.create(A.Display.prototype);
MathsPanel.prototype.say = function (s, cls) { this.msg.className = 'pr-note ' + (cls || ''); this.msg.innerHTML = s; };
MathsPanel.prototype.renderList = function () {
  var self = this; this.list.innerHTML = '';
  if (!PS.list.length) this.list.appendChild(el('div', 'pr-note', 'None'));
  PS.list.slice(0, 3).forEach(function (f) {
    var r = el('div', 'pr-mrow'); r.innerHTML = '<span class="n">' + esc(f.name) + '</span><span class="f' + (f.err ? ' bad' : '') + '">' + (f.err ? esc(f.err) : '= ' + esc(f.expr)) + '</span><span class="u">' + esc(f.unit) + '</span><span class="x" title="remove">×</span>';
    r.addEventListener('click', function (e) { if (e.target.className === 'x') { self.remove(f); return; } self.nm.value = f.name; self.ex.value = f.expr; self.un.value = f.unit; self.say('Editing <b>' + esc(f.name) + '</b> · ADD replaces it'); });
    self.list.appendChild(r);
  });
  if (PS.list.length > 3) this.list.appendChild(el('div', 'pr-note', '+ ' + (PS.list.length - 3) + ' more'));
  this.exs.innerHTML = '';
  EXAMPLES.forEach(function (q) { if (formulaByName(q[0])) return; self.exs.appendChild(btn(q[0], 'sm', function () { self.run(q[0], q[1], q[2]); }, q[0] + ' = ' + q[1])); });
};
MathsPanel.prototype.add = function () {
  var ex = this.ex.value.trim(), nm = this.nm.value.trim(), un = this.un.value.trim();
  if (!ex) { this.say('Formula needed', 'err'); return; }
  if (!nm) nm = ex.length > 28 ? ex.slice(0, 27) + '…' : ex;
  this.run(nm, ex, un);
};
MathsPanel.prototype.run = function (name, expr, unit) {
  var self = this; this.say('Calculating…');
  return WB.pro.addMaths(name, expr, unit).then(function (r) { if (!r.ok) { self.say(esc(r.error), 'err'); } });
};
MathsPanel.prototype.remove = function (f) { WB.pro.removeMaths(f.name); };

// ---------- export ----------
function exportNames() { return PS.exp.sel.slice(); }
function exportUrl(fmt) { return proUrl('export', { ch: exportNames().join(','), fmt: fmt, which: PS.exp.ref && D().R ? 'both' : 'lap' }); }
function saveBlob(b, name) { var u = URL.createObjectURL(b), a = document.createElement('a'); a.href = u; a.download = name; document.body.appendChild(a); a.click(); setTimeout(function () { URL.revokeObjectURL(u); a.remove(); }, 4000); }
// fetch first (a mistake comes back as words, never as a JSON page), then hand the file to the browser; dl=false only fetches (tests)
function exportNow(fmt, dl) {
  var url = exportUrl(fmt);
  return fetch(url, { cache: 'no-store' }).then(function (r) {
    if (r.status !== 200) return r.text().then(function (t) { var m = ''; try { m = JSON.parse(t).error; } catch (e) { m = t; } throw new Error(m || ('HTTP ' + r.status)); });
    var cd = r.headers.get('Content-Disposition') || '', m = /filename="([^"]+)"/.exec(cd), name = m ? m[1] : 'paddock.' + fmt;
    return r.blob().then(function (b) { PS.exp.last = { name: name, size: b.size, fmt: fmt, url: url }; if (dl !== false && !P.get('nodl')) saveBlob(b, name); return PS.exp.last; });
  });
}
function ExportPanel(box) {
  A.Display.call(this, box, ''); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'export';
  var self = this, d = D();
  this.ph.innerHTML = 'Export · lap' + (d.R ? ' and reference' : '') + ' · every metre';
  var row = el('div', 'pr-gorow'); this.stage.appendChild(row);
  this.xl = el('span', 'pr-go', 'EXCEL  .xlsx'); this.cv = el('span', 'pr-go sec', 'CSV');
  this.xl.addEventListener('click', function () { self.go('xlsx'); }); this.cv.addEventListener('click', function () { self.go('csv'); });
  row.appendChild(this.xl); row.appendChild(this.cv);
  if (d.R) row.appendChild(btn(PS.exp.ref ? 'WITH REFERENCE' : 'LAP ONLY', 'sm' + (PS.exp.ref ? ' on' : ''), function () { PS.exp.ref = !PS.exp.ref; self.render(); }));
  this.chips = el('div', 'pr-chips'); this.stage.appendChild(this.chips);
  this.note = el('div', 'pr-note'); this.stage.appendChild(this.note);
  this.render();
}
ExportPanel.prototype = Object.create(A.Display.prototype);
ExportPanel.prototype.render = function () {
  var self = this, d = D(); this.chips.innerHTML = '';
  PS.exp.sel.forEach(function (k) {
    var label = k.charAt(0) === '@' ? k.slice(1) : tag(k);
    self.chips.appendChild(btn(label, 'sm on', function () { PS.exp.sel.splice(PS.exp.sel.indexOf(k), 1); saveState(); self.render(); }));
  });
  this.chips.appendChild(btn('+ CHANNEL', 'sm', function () { A.openPicker(function (e) { var k = e.derived && e.key.indexOf('m_') === 0 ? '@' + e.label : e.key; if (PS.exp.sel.indexOf(k) < 0) PS.exp.sel.push(k); saveState(); self.render(); }, 'Add a channel to the export'); }));
  this.note.innerHTML = 'Lap <b>' + d.head.lap.lap + '</b> ' + A.fmt(d.head.lap.time) + (d.R && PS.exp.ref ? ' · reference lap <b>' + d.head.ref.lap + '</b> ' + A.fmt(d.head.ref.time) : '') + ' · ' + PS.exp.sel.length + ' channels';
};
ExportPanel.prototype.go = function (fmt) {
  var self = this, now = Date.now();
  if (now - PS.exp.busy < 700) return; PS.exp.busy = now;                     // a key can arrive 2-3 times
  this.note.className = 'pr-note'; this.note.innerHTML = 'Making the ' + (fmt === 'xlsx' ? 'Excel file' : 'CSV file') + '…';
  exportNow(fmt, true).then(function (r) { self.note.className = 'pr-note ok'; self.note.innerHTML = 'Saved <b>' + esc(r.name) + '</b> · ' + Math.round(r.size / 1024) + ' KB · Downloads'; },
    function (e) { self.note.className = 'pr-note err'; self.note.innerHTML = esc(String(e.message || e)); });
};

// ---------- the page ----------
function build() {
  PS.p = {};
  var d = D(), xy = new Scatter({ x: 32, y: 126, w: 1056, h: 500 });
  PS.p.xy = xy;
  PS.p.hist = new HistView({ x: 1120, y: 126, w: 768, h: 300 });
  var y2 = below(PS.p.hist);
  PS.p.maths = new MathsPanel({ x: 1120, y: y2, w: 768, h: 0 });
  var y3 = below(PS.p.maths);
  PS.p.exp = new ExportPanel({ x: 1120, y: y3, w: 768, h: 0 });
  var ty = below(xy), ok = PS.list.filter(function (f) { return f.key && !f.err && d.A.c[f.key]; });
  if (ok.length) {
    var rows = ok.slice(0, 3).map(function (f) {
      var lo = 1e300, hi = -1e300, i; [d.A.c[f.key], d.R ? d.R.c[f.key] : null].forEach(function (a) { if (a) for (i = 0; i < d.n; i++) { var v = a[i]; if (v === v) { if (v < lo) lo = v; if (v > hi) hi = v; } } });
      if (!(hi > lo)) { lo -= 0.5; hi += 0.5; } var pad = (hi - lo) * 0.08, span = hi - lo, nm = f.name.toUpperCase(); if (nm.length > 18) nm = nm.slice(0, 17) + '…';
      return { k: withUnit(nm, f.unit && f.unit.toUpperCase()), key: f.key, h: 84, lo: lo - pad, hi: hi + pad, d: span >= 100 ? 0 : span >= 10 ? 1 : span >= 1 ? 2 : 3 };
    }), h = Math.max(120, 1052 - (ty + 20));
    PS.p.tr = new A.Traces({ x: 32, y: ty, w: 1056, h: h }, 'Maths channels · ' + ok.slice(0, 3).map(function (f) { return esc(f.name) + ' = ' + esc(f.expr); }).join(' · '), A.scaleRows(rows, h));
  } else {
    var hint = new A.Display({ x: 32, y: ty, w: 1056, h: 0 }, 'Maths channels'); hint.cs.canvas.remove(); hint.co.canvas.remove(); hint.stage.style.height = 'auto'; hint.kind = 'prohint';
    hint.stage.appendChild(el('div', 'pr-hint', 'None yet'));
    PS.p.hint = hint;
  }
  PS.p.xy.showEq();
}

// ---------- hooks for the engine and the tests ----------
X.add({ id: 'pro', name: 'PRO', avail: availPro, build: build });
X.loads.push(loadPro);
X.keys['p'] = X.keys['P'] = function () { if (WB.pages().indexOf('pro') >= 0) WB.cmd('page', 'pro'); };
// the channel picker's two extra buttons: send the highlighted channel to the X/Y display (as Y) or the histogram
function goPro() { if (WB.pages().indexOf('pro') >= 0) { WB.cmd('page', 'pro'); return true; } return false; }
X.pickActs.push({ label: 'X/Y', hint: 'Shift+Enter', fn: function (e) { if (!goPro()) return; if (PS.p.xy) PS.p.xy.apply({ y: e.key, ay: false }); } });
X.pickActs.push({ label: 'HIST', hint: 'Ctrl+Enter', fn: function (e) { if (!goPro()) return; if (PS.p.hist) PS.p.hist.set(e.key); } });

WB.pro = {
  state: PS, polyfit: polyfit, polyText: polyText,
  xy: function () {
    var d = xyCompute(), xy = PS.xy; if (!d.ok) return null;
    function pts(s) { if (!s) return null; var x = [], y = [], c = [], idx = []; for (var i = 0; i < s.x.length; i++) if (s.x[i] === s.x[i]) { x.push(s.x[i]); y.push(s.y[i]); idx.push(i); if (s.c) c.push(s.c[i]); } return { x: x, y: y, c: c, idx: idx, n: s.n, fit: s.fit ? { coef: s.fit.coef, r2: s.fit.r2, order: s.fit.order, n: s.fit.n } : null }; }
    var z0 = Math.floor(S.z0), z1 = Math.ceil(S.z1), inZ = 0, zoomed = A.zoomed(); for (var i = 0; i < d.lap.x.length; i++) if (d.lap.x[i] === d.lap.x[i] && (!zoomed || (i >= z0 && i <= z1))) inZ++;
    return { x: xy.x, y: xy.y, c: xy.c, ax: xy.ax, ay: xy.ay, order: xy.order, laps: xy.laps, lap: pts(d.lap), ref: pts(d.ref), bright: inZ, zoomed: zoomed, geom: PS.p.xy && PS.p.xy.G ? { x0: PS.p.xy.G.x0, x1: PS.p.xy.G.x1, y0: PS.p.xy.G.y0, y1: PS.p.xy.G.y1 } : null };
  },
  setXY: function (o) { return PS.p.xy ? PS.p.xy.apply(o).then(function () { return true; }) : Promise.resolve(false); },
  hist: function () {
    var h = histCompute(PS.hist.key); if (!h) return null;
    function sd(s) { if (!s) return null; var sum = 0; for (var i = 0; i < s.pct.length; i++) sum += s.pct[i]; return { pct: Array.prototype.slice.call(s.pct), sum: sum, mean: s.mean, min: s.min, max: s.max, top: s.top, T: s.T }; }
    return { key: h.key, w: h.w, e0: h.e0, nb: h.nb, integer: h.integer, edges: h.edges, lap: sd(h.lap), ref: sd(h.ref) };
  },
  setHist: function (k) { return PS.p.hist ? PS.p.hist.set(k).then(function () { return true; }) : Promise.resolve(false); },
  maths: function () { return PS.list.map(function (f) { return { name: f.name, expr: f.expr, unit: f.unit, key: f.key, err: f.err, note: f.note, blank: f.blank }; }); },
  // add (or replace) a formula: it is worked out first, saved only when it worked; the page is built again so the trace row shows
  addMaths: function (name, expr, unit) {
    name = String(name || '').trim(); expr = String(expr || '').trim(); unit = String(unit || '').trim();
    var f = { name: name, unit: unit, expr: expr, key: '', err: '', note: '', blank: 0 }, old = formulaByName(name);
    return evalFormula(f).then(function () {
      return A.fetchJson(carUrl('save', { name: name, unit: unit, expr: expr }));
    }).then(function (j) {
      if (old) { PS.list.splice(PS.list.indexOf(old), 1); if (old.key !== f.key) dropFormula(old); }
      PS.list.push(f); var k = '@' + name; if (PS.exp.sel.indexOf(k) < 0) PS.exp.sel.push(k); saveState();
      A.rebuild(); return { ok: true, key: f.key, note: f.note, blank: f.blank };
    }, function (e) { return { ok: false, error: String(e.message || e) }; });
  },
  removeMaths: function (name) {
    var f = formulaByName(name); if (!f) return Promise.resolve(false);
    return A.fetchJson(carUrl('delete', { name: f.name })).then(function () {
      PS.list.splice(PS.list.indexOf(f), 1); dropFormula(f); var i = PS.exp.sel.indexOf('@' + f.name); if (i >= 0) PS.exp.sel.splice(i, 1); saveState(); A.rebuild(); return true;
    }, function () { return false; });
  },
  exportUrl: exportUrl, exportNow: exportNow, exportSel: function () { return PS.exp.sel.slice(); },
  panels: function () { return Object.keys(PS.p).filter(function (k) { return PS.p[k]; }); }
};
})();

