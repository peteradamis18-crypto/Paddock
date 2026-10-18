// Paddock Analysis Workbench - the core engine (docs\DESIGN-workbench.md section 4, card W1).
// A page is a set of displays in fixed boxes on the 1920x1080 top screen. Every display shares ONE state S (cursor,
// zoom window, tile/overlay, reference offset, playback) and draws on two canvases: a static layer (traces, map colours,
// redrawn when the zoom or the data changes) and a thin overlay (cursor, values) that is the only thing redrawn while the
// cursor moves or playback runs - that is what keeps 60 fps with 20 traces x 2 laps. No libraries.
// Data: one binary reply from /analysis/channels (dash\src\workbench.cs). Tests load the same bytes from a file (?data=).
// Control: mouse, keyboard (Pi Toolbox keys) and window.WB.cmd(name, arg) - the deck reaches it through
// /api/do?c=wb-<name>, which the page polls at /workbench/cmd.
(function () {
'use strict';
var C = { gold: '#f2c230', ref: '#cfd8e3', gain: '#3ccf7e', loss: '#e5534b', mute: '#8b877d', dim: '#5d5a54', line: '#26262a', abs: '#ff9f43',
  purple: '#b46cff', ink: '#ece8df', band: '#131316', bandOn: 'rgba(242,194,48,.07)', rear: '#e8a94a', wf: '#9b87d6' };
var FONT = 'Bahnschrift, "Segoe UI", sans-serif';
var GRAV = 9.81, PH = 20;                                   // PH: the display title line above every canvas
var CHANS = ['Speed', 'Throttle', 'Brake', 'BrakeABSactive', 'SteeringWheelAngle', 'SteeringWheelPctTorque', 'Gear', 'RPM', 'LatAccel', 'LongAccel',
  'VelocityX', 'VelocityY', 'YawRate', 'Lat', 'Lon', 'LFspeed', 'RFspeed', 'LRspeed', 'RRspeed', 'dcBrakeBias',
  'LFrideHeight', 'RFrideHeight', 'LRrideHeight', 'RRrideHeight', 'LFshockDefl', 'RFshockDefl', 'LRshockDefl', 'RRshockDefl', 'LFshockVel', 'RFshockVel', 'LRshockVel', 'RRshockVel'];
// every page; a tab shows only when its data is there (avail), so there is never a dead tab (DESIGN-analysis 2.7)
var PAGES = [{ id: 'driver', name: 'DRIVER' }, { id: 'grip', name: 'GRIP & BALANCE' }, { id: 'braking', name: 'BRAKING' }, { id: 'tyres', name: 'TYRES & STINT' },
  { id: 'suspension', name: 'SUSPENSION' }, { id: 'splits', name: 'SPLITS' }];
var WHEELS = ['LF', 'RF', 'LR', 'RR'], WHEEL_NAME = { LF: 'FRONT LEFT', RF: 'FRONT RIGHT', LR: 'REAR LEFT', RR: 'REAR RIGHT' };

// speed in the units iRacing last reported to the dashboard (same rule as the Vault and Sessions pages). The channel key stays
// 'kmh' (saved layouts and maths channels name it); only its numbers and labels follow the unit.
var SPD_MPH = (function () { try { return JSON.parse(localStorage.getItem('irdash-units')) === false; } catch (e) { return false; } })();
var SPD_F = SPD_MPH ? 2.236936 : 3.6, SPD_U = SPD_MPH ? 'mph' : 'km/h', SPD_LO = SPD_MPH ? 40 : 60, SPD_HI = SPD_MPH ? 170 : 270;

// what each channel is called on screen, its unit and how many decimals (plain English, DESIGN-workbench 2.10)
var CAT = {
  kmh: { label: 'Speed ' + SPD_U, dec: 0 }, Gear: { label: 'Gear', dec: 0 }, RPM: { label: 'RPM', dec: 0 }, thrPct: { label: 'Throttle %', dec: 0 },
  brkPct: { label: 'Brake %', dec: 0 }, steerDeg: { label: 'Steering °', dec: 0 }, latG: { label: 'Lateral g', dec: 2 }, longG: { label: 'Long g', dec: 2 },
  beta: { label: 'Slip angle °', dec: 1 }, wfPct: { label: 'Wheel force %', dec: 0 }, gTot: { label: 'Total g', dec: 2 },
  slipLF: { label: 'Slip LF %', dec: 0 }, slipRF: { label: 'Slip RF %', dec: 0 }, slipLR: { label: 'Slip LR %', dec: 0 }, slipRR: { label: 'Slip RR %', dec: 0 },
  rideLF: { label: 'Ride height LF mm', dec: 1 }, rideRF: { label: 'Ride height RF mm', dec: 1 }, rideLR: { label: 'Ride height LR mm', dec: 1 }, rideRR: { label: 'Ride height RR mm', dec: 1 },
  rake: { label: 'Rake mm', dec: 1 }
};
var MULTI = ['#cfd8e3', '#3ccf7e', '#a77bff', '#f2c230', '#88888f'];

var P = new URLSearchParams(location.search);
var LIVE = !P.get('data');
var S = { cur: 0, refCur: null, z0: 0, z1: 1, tile: false, offsetM: 0, offsetS: 0, offsetMode: false, playing: false, speed: 1, reverse: false, page: P.get('page') || 'driver',
  axis: 'dist', mapColour: 'gap', zoomStack: [], driving: false, extra: [], stint: null, selectedLaps: (P.get('laps') || '').split(',').filter(Boolean) };   // extra: channels he added with the picker (they stay on every page that has a trace stack)
var D = null;                                               // data: A, R, n, L, step, corners, events, head, deep (C-34 engines), sess (session reply), dc (deep corners by number)
var displays = [], hooks = [], perf = { frames: 0, total: 0, max: 0, last: [] }, lastTs = 0, need = { s: false, o: false };
// A page that lives in its own file (workbench-video.js, card W5) registers here: add({ id, name, avail(), build() }); tick(ts, dt) runs every frame before
// drawing; drives() true = that file's clock (the video) moves the cursor, so the engine's own playback stands still; before/after run around buildPage and
// head after header(); keys[k] and cmds[name] extend the keyboard and WB.cmd; loads run with the other replies (they return promises).
var X = window.WBX = { pages: {}, ticks: [], before: [], after: [], head: [], keys: {}, cmds: {}, loads: [], pickActs: [], drives: function () { return false; },   // pickActs: extra buttons in the channel picker (workbench-pro.js: X/Y, HIST)
  add: function (p) { PAGES.push({ id: p.id, name: p.name }); X.pages[p.id] = p; } };

// ---------- small helpers ----------
function fmt(t) { if (t == null || !isFinite(t)) return '–'; var m = Math.floor(t / 60), s = t - m * 60; return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3); }
function num(x, d) { var s = x.toFixed(d); return s === (-0).toFixed(d) || /^-0\.?0*$/.test(s) ? Math.abs(x).toFixed(d) : s; }   // never "-0.0"
function sgn(x, d) { d = d == null ? 3 : d; var s = Math.abs(x).toFixed(d), zero = parseFloat(s) === 0; return (zero ? '±' : x > 0 ? '+' : '−') + s; }
function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
function el(tag, cls, html) { var e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; }
function at(arr, fi) { var i = Math.floor(fi); if (i < 0) return arr[0]; if (i >= arr.length - 1) return arr[arr.length - 1]; return arr[i] + (arr[i + 1] - arr[i]) * (fi - i); }
function dateWord(iso) { if (!iso) return ''; var d = new Date(iso); if (isNaN(d)) return ''; return d.getDate() + ' ' + ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'][d.getMonth()]; }
// index (fractional) where a rising array reaches v
function idxOf(arr, v) { var lo = 0, hi = arr.length - 1; if (v <= arr[0]) return 0; if (v >= arr[hi]) return hi; while (lo + 1 < hi) { var m = (lo + hi) >> 1; if (arr[m] <= v) lo = m; else hi = m; } var s = arr[hi] - arr[lo]; return lo + (s > 0 ? (v - arr[lo]) / s : 0); }
function gainColour(rate) { var a = Math.min(1, Math.abs(rate) / 0.04); if (a < 0.08) return '#4a4a50'; return rate < 0 ? 'rgba(60,207,126,' + (0.35 + 0.65 * a) + ')' : 'rgba(229,83,75,' + (0.35 + 0.65 * a) + ')'; }
function speedColour(kmh, lo, hi) { var u = clamp((kmh - lo) / (hi - lo), 0, 1), st = [[70, 40, 140], [200, 70, 120], [240, 150, 60], [245, 225, 170]], f = u * 3, k = Math.min(2, Math.floor(f)), v = f - k; return 'rgb(' + st[k].map(function (x, q) { return Math.round(x + (st[k + 1][q] - x) * v); }).join(',') + ')'; }

// ---------- data ----------
function readReply(buf) {
  var dv = new DataView(buf);
  if (String.fromCharCode(dv.getUint8(0), dv.getUint8(1), dv.getUint8(2), dv.getUint8(3)) !== 'PWB1') throw new Error('not a workbench reply');
  var hl = dv.getInt32(4, true), head = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 8, hl)));
  var pos = 8 + hl, arr = {};
  head.arrays.forEach(function (k) { arr[k] = new Float32Array(buf, pos, head.n); pos += head.n * 4; });
  return { head: head, arr: arr };
}
function parse(buf) {
  var rp = readReply(buf), head = rp.head, arr = rp.arr;
  var n = head.n, L = head.lengthM, step = L / head.metres;
  function lap(prefix, info) {
    var Lp = { n: n, info: info, t: arr[prefix + '.t'], c: {}, ok: {} };
    head.channels.forEach(function (ch) { Lp.c[ch.key] = arr[prefix + '.' + ch.key]; Lp.ok[ch.key] = !!ch.ok; });   // ok = the car's file has it (a missing one comes back as zeros)
    derive(Lp);
    return Lp;
  }
  var A = lap('lap', head.lap), R = head.ref ? lap('ref', head.ref) : null;
  var M = (head.multi || []).map(function (info, i) { return lap('m' + i, info); });
  var corners = head.corners.map(function (c) {
    var lab = c.official ? 'T' + c.official.toUpperCase() : (c.name || '').replace(/^The /, '') || 'T' + c.n;
    return { n: c.n, label: lab, name: c.name, d0: c.p0 * L, da: c.pa * L, d1: (c.p1 > c.p0 ? c.p1 : 1) * L, i0: 0, ia: 0, i1: 0 };
  });
  corners.forEach(function (c) { c.i0 = Math.round(c.d0 / step); c.ia = Math.round(c.da / step); c.i1 = Math.min(n - 1, Math.round(c.d1 / step)); });
  D = { head: head, A: A, R: R, M: M, n: n, L: L, step: step, corners: corners, events: events(A, corners, step), gap: null, cstat: [] };
  M.forEach(function (lap) { lap.gap = new Float32Array(n); for (var i = 0; i < n; i++) lap.gap[i] = A.t[i] - lap.t[i]; });
  if (R) { var g = new Float32Array(n); for (var i = 0; i < n; i++) g[i] = A.t[i] - R.t[i]; D.gap = g; }
  else if (M.length) D.gap = new Float32Array(n); // zero is the active lap's baseline for multi-lap gap overlays
  D.cstat = corners.map(function (c) { var a = cornerStats(A, c), r = R ? cornerStats(R, c) : null; return { c: c, a: a, r: r, dt: r ? a.time - r.time : 0 }; });
  D.worst = D.cstat.slice().sort(function (x, y) { return y.dt - x.dt; })[0] || null;
}

// derived channels (Cosworth's formulas where the workbook states them, docs\research\pi-toolbox-features.md 5.1)
function derive(Lp) {
  var c = Lp.c, n = Lp.n, i;
  function f(fn) { var o = new Float32Array(n); for (i = 0; i < n; i++) o[i] = fn(i); return o; }
  var has = function (k) { return !!c[k] && Lp.ok[k] !== false; };
  if (has('Speed')) c.kmh = f(function (i) { return c.Speed[i] * SPD_F; });
  if (has('Throttle')) c.thrPct = f(function (i) { return c.Throttle[i] * 100; });
  if (has('Brake')) c.brkPct = f(function (i) { return c.Brake[i] * 100; });
  if (has('SteeringWheelAngle')) c.steerDeg = f(function (i) { return c.SteeringWheelAngle[i] * 57.2958; });
  if (has('SteeringWheelPctTorque')) c.wfPct = f(function (i) { return c.SteeringWheelPctTorque[i] * 100; });
  if (has('LatAccel')) c.latG = f(function (i) { return c.LatAccel[i] / GRAV; });
  if (has('LongAccel')) c.longG = f(function (i) { return c.LongAccel[i] / GRAV; });
  if (c.latG && c.longG) c.gTot = f(function (i) { return Math.sqrt(c.latG[i] * c.latG[i] + c.longG[i] * c.longG[i]); });
  if (has('VelocityX') && has('VelocityY')) c.beta = f(function (i) { return Math.atan2(c.VelocityY[i], Math.max(1, c.VelocityX[i])) * 57.2958; });   // chassis slip angle
  ['LF', 'RF', 'LR', 'RR'].forEach(function (w) { if (has(w + 'speed') && has('Speed')) c['slip' + w] = f(function (i) { return c.Speed[i] > 8 ? (c[w + 'speed'][i] - c.Speed[i]) / c.Speed[i] * 100 : 0; }); });
  // Cosworth Lite pedal state: 0 coast, 1 part throttle, 2 throttle > 98 %, 3 part brake, 4 brake > 65 %
  if (has('Throttle') && has('Brake')) c.pedal = f(function (i) { var b = c.Brake[i], th = c.Throttle[i]; return b > 0.65 ? 4 : b > 0.02 ? 3 : th > 0.98 ? 2 : th > 0.02 ? 1 : 0; });
  // suspension (m and m/s from the file -> mm and mm/s); rake = rear ride height minus front, the usual definition
  WHEELS.forEach(function (w) {
    if (has(w + 'rideHeight')) c['ride' + w] = f(function (i) { return c[w + 'rideHeight'][i] * 1000; });
    if (has(w + 'shockDefl')) c['defl' + w] = f(function (i) { return c[w + 'shockDefl'][i] * 1000; });
    if (has(w + 'shockVel')) c['vel' + w] = f(function (i) { return c[w + 'shockVel'][i] * 1000; });
  });
  if (c.rideLF && c.rideRF && c.rideLR && c.rideRR) c.rake = f(function (i) { return (c.rideLR[i] + c.rideRR[i]) / 2 - (c.rideLF[i] + c.rideRF[i]) / 2; });
}

// events on a lap: ABS zones (pulses under 30 m apart are one zone), lock-ups (a wheel 8 % slower than the car under
// braking), rear slip (a rear wheel 8 % faster on throttle - the range traction control works in). No slide events: a
// GT3 runs 3-5 deg of slip angle in ordinary corners, so a threshold would invent incidents (lead review 2026-10-10).
function events(Lp, corners, step) {
  var c = Lp.c, n = Lp.n, ev = [];
  if (!c.BrakeABSactive || !c.slipLF) return ev;
  var name = function (d) { for (var k = 0; k < corners.length; k++) if (d >= corners[k].d0 - 30 && d <= corners[k].d1 + 30) return corners[k].label; return ''; };
  function runs(test, minM, gapM) {
    var out = [], s = -1, last = -1, gap = Math.round(gapM / step), min = Math.round(minM / step);
    for (var i = 0; i < n; i++) { if (test(i)) { if (s < 0) s = i; last = i; } else if (s >= 0 && i - last > gap) { if (last - s + 1 >= min) out.push([s, last]); s = -1; } }
    if (s >= 0 && last - s + 1 >= min) out.push([s, last]);
    return out;
  }
  var push = function (type, a, b, extra) { var e = { type: type, i: a, j: b, d: a * step, len: (b - a) * step, at: name(a * step), dur: Lp.t[b] - Lp.t[a] }; for (var k in extra) e[k] = extra[k]; ev.push(e); };
  runs(function (i) { return c.BrakeABSactive[i] > 0.5; }, 4, 30).forEach(function (r) { push('ABS', r[0], r[1], {}); });
  runs(function (i) { return c.Brake[i] > 0.1 && Math.min(c.slipLF[i], c.slipRF[i], c.slipLR[i], c.slipRR[i]) < -8; }, 3, 0).forEach(function (r) {
    var w = ['LF', 'RF', 'LR', 'RR'].reduce(function (m, k) { return c['slip' + k][r[0]] < c['slip' + m][r[0]] ? k : m; }, 'LF');
    push('LOCK', r[0], r[1], { wheel: w }); });
  runs(function (i) { return c.Throttle[i] > 0.5 && Math.max(c.slipLR[i], c.slipRR[i]) > 8; }, 3, 0).forEach(function (r) { push('SPIN', r[0], r[1], {}); });
  return ev.sort(function (a, b) { return a.i - b.i; });
}
function evText(e, compact) {
  if (e.type === 'ABS') return 'ABS working for ' + e.len.toFixed(0) + ' m (' + e.dur.toFixed(2) + ' s)';
  if (e.type === 'LOCK') return e.wheel + ' wheel 8 % slower than the car for ' + e.len.toFixed(0) + ' m';
  return compact ? 'rear wheels 8 % faster for ' + e.len.toFixed(0) + ' m' : 'rear wheels 8 % faster than the car for ' + e.len.toFixed(0) + ' m';
}
function plural(n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); }
function evColour(e) { return e.type === 'LOCK' ? C.loss : C.abs; }

function cornerStats(Lp, c) {
  var ch = Lp.c, vmin = 1e9, lat = 0, beta = 0, abs = 0, im = c.i0;
  for (var i = c.i0; i <= c.i1; i++) {
    if (ch.kmh[i] < vmin) { vmin = ch.kmh[i]; im = i; }
    if (ch.latG) lat = Math.max(lat, Math.abs(ch.latG[i]));
    if (ch.beta && Math.abs(ch.beta[i]) > Math.abs(beta)) beta = ch.beta[i];
    if (ch.BrakeABSactive && ch.BrakeABSactive[i] > 0.5) abs += D ? D.step : 1;
  }
  return { time: Lp.t[c.i1] - Lp.t[c.i0], vmin: vmin, lat: lat, beta: beta, abs: abs, im: im };
}
function share(Lp, key, vals) { var cnt = vals.map(function () { return 0; }), a = Lp.c[key]; if (!a) return cnt; for (var i = 0; i < Lp.n; i++) { var k = vals.indexOf(Math.round(a[i])); if (k >= 0) cnt[k]++; } return cnt.map(function (x) { return x / Lp.n * 100; }); }

// ---------- shared state ----------
// the reference index that goes with lap index i: shifted by the offset; on the time axis the same moment of the reference
function offsetSamples() { return D ? S.offsetM / D.step : 0; }
function shiftedValue(arr, i, shift) { var k = i - shift; return k < 0 || k > arr.length - 1 ? NaN : at(arr, k); }
function rIdx(i) { if (!D.R) return i; var k = (S.axis === 'time' ? idxOf(D.R.t, at(D.A.t, i)) : i) - offsetSamples(); return k < 0 || k > D.n - 1 ? NaN : k; }
function shiftedRefLap() {
  if (!D.R) return null;
  if (D.offsetRefCache && D.offsetRefCache.offset === S.offsetM) return D.offsetRefCache.lap;
  var out = { c: {}, t: new Float32Array(D.n), n: D.n }, shift = offsetSamples();
  Object.keys(D.R.c).forEach(function (name) { var src = D.R.c[name], dst = new Float32Array(D.n); for (var i = 0; i < D.n; i++) dst[i] = shiftedValue(src, i, shift); out.c[name] = dst; });
  for (var i = 0; i < D.n; i++) out.t[i] = shiftedValue(D.R.t, i, shift);
  D.offsetRefCache = { offset: S.offsetM, lap: out }; return out;
}
function refreshCornerStats() {
  var ref = shiftedRefLap();
  D.cstat = D.corners.map(function (c) { var a = cornerStats(D.A, c), r = ref ? cornerStats(ref, c) : null; return { c: c, a: a, r: r, dt: r ? a.time - r.time : 0 }; });
  D.worst = D.cstat.slice().sort(function (x, y) { return y.dt - x.dt; })[0] || null;
}
function gapAt(i) { if (!D.R) return D.gap ? D.gap[i] : 0; var k = rIdx(i); return isFinite(k) ? D.A.t[i] - at(D.R.t, k) : NaN; }
function zoomed() { return S.z1 - S.z0 < D.n - 1.5; }
function setCursor(i, keepWindow) {
  S.cur = clamp(i, 0, D.n - 1);
  if (!keepWindow && zoomed() && (S.cur < S.z0 || S.cur > S.z1)) { var w = S.z1 - S.z0; setZoom(S.cur - w / 2, S.cur + w / 2); }
  need.o = true;
}
function setZoom(a, b) {
  var w = Math.max(40, b - a); a = clamp(a, 0, D.n - 1 - w); b = a + w;
  if (b > D.n - 1) { b = D.n - 1; a = b - w; }
  if (Math.abs(a - S.z0) < 1e-6 && Math.abs(b - S.z1) < 1e-6) return;
  S.z0 = a; S.z1 = b; need.s = true; need.o = true;
  if (D.R) updateOffset();
}
function zoomAt(f) { var w = (S.z1 - S.z0) * f, c = clamp(S.cur, S.z0, S.z1), u = (c - S.z0) / (S.z1 - S.z0); if (f < 1) S.zoomStack.push([S.z0, S.z1]); setZoom(c - u * w, c + (1 - u) * w); }
function zoomCorner(c) { if (!c) return; S.zoomStack.push([S.z0, S.z1]); setZoom(c.i0 - 60 / D.step, c.i1 + 60 / D.step); setCursor(c.ia, true); }
function cornerAt(i) { for (var k = 0; k < D.corners.length; k++) { var c = D.corners[k]; if (i >= c.i0 - 20 && i <= c.i1 + 20) return c; } return null; }
function cornerNear(i) { var best = null, bd = 1e9; D.corners.forEach(function (c) { var d = Math.abs(c.ia - i); if (d < bd) { bd = d; best = c; } }); return best; }
function autoOffset() {
  // line the laps up at the braking point of the corner in view: the first brake rise after the window start, both laps
  if (!D.R || !D.A.c.Brake || !D.R.c.Brake) { S.autoResult = 'unavailable'; need.o = true; modeLine(); return false; }
  var a = Math.max(0, Math.floor(S.z0)), b = Math.min(D.n - 1, Math.ceil(S.z1)), apex = cornerAt(Math.round(S.cur)) || cornerNear(S.cur);
  if (apex) b = Math.min(b, apex.ia);
  var bA = -1, bR = -1, i;
  for (i = a + 1; i < b; i++) if (D.A.c.Brake[i] > 0.1 && D.A.c.Brake[i - 1] <= 0.1) { bA = i; break; }
  for (i = a + 1; i < b; i++) if (D.R.c.Brake[i] > 0.1 && D.R.c.Brake[i - 1] <= 0.1) { bR = i; break; }
  if (bA >= 0 && bR >= 0) {
    S.offsetM = (bA - bR) * D.step; D.offsetRefCache = null; D.rng = {};
    var speed = 0, n = 0; for (i = a; i <= Math.min(D.n - 1, Math.ceil(S.z1)); i++) if (D.A.c.Speed[i] > 0) { speed += D.A.c.Speed[i]; n++; }
    S.offsetS = n ? S.offsetM / (speed / n) : 0;
    S.autoResult = 'aligned'; refreshCornerStats(); need.s = true; need.o = true; modeLine(); return true;
  }
  S.autoResult = 'unavailable'; need.o = true; modeLine(); return false;
}
function updateOffset() {
  var speed = 0, n = 0, a = Math.max(0, Math.floor(S.z0)), b = Math.min(D.n - 1, Math.ceil(S.z1));
  for (var i = a; i <= b; i++) if (D.A.c.Speed[i] > 0) { speed += D.A.c.Speed[i]; n++; }
  S.offsetS = n ? S.offsetM / (speed / n) : 0;
  S.autoResult = '';
  D.offsetRefCache = null; D.rng = {};
  refreshCornerStats();
  need.s = true; need.o = true;
}

// ---------- display base: a titled panel with a static and an overlay canvas ----------
function Display(box, title) {
  this.box = box; this.tbS = []; this.tbO = []; this.oy = PH; this.kind = 'display';
  this.el = el('div', 'panel'); this.el.style.cssText = 'left:' + box.x + 'px;top:' + box.y + 'px;width:' + box.w + 'px';
  this.ph = el('div', 'ph', title); this.el.appendChild(this.ph);
  this.stage = el('div', 'stage'); this.stage.style.cssText = 'width:' + box.w + 'px;height:' + box.h + 'px'; this.el.appendChild(this.stage);
  this.cs = this.canvas(); this.co = this.canvas();
  document.getElementById('page').appendChild(this.el);
  displays.push(this);
}
Display.prototype.canvas = function () { var dpr = window.devicePixelRatio || 1, c = el('canvas', 'cv'); c.width = this.box.w * dpr; c.height = this.box.h * dpr; c.style.width = this.box.w + 'px'; c.style.height = this.box.h + 'px'; this.stage.appendChild(c); var g = c.getContext('2d'); g.scale(dpr, dpr); return g; };
Display.prototype.clear = function (g) { g.save(); g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, g.canvas.width, g.canvas.height); g.restore(); };
// canvas text that also records its box (page coordinates) so the test can prove nothing overlaps
Display.prototype.text = function (g, list, s, x, y, size, color, align) {
  g.font = size + 'px ' + FONT; g.fillStyle = color; g.textAlign = align || 'left'; g.textBaseline = 'alphabetic'; g.fillText(s, x, y);
  var w = g.measureText(s).width, bx = align === 'center' ? x - w / 2 : align === 'right' ? x - w : x;
  var b = { x: this.box.x + bx, y: this.box.y + this.oy + y - size * 0.78, w: w, h: size * 0.9, s: s }; list.push(b); return b;
};
Display.prototype.drawStatic = function () {}; Display.prototype.drawOverlay = function () {};
Display.prototype.local = function (ev) { var r = this.stage.getBoundingClientRect(); return [ev.clientX - r.left, ev.clientY - r.top]; };

// ---------- TRACE STACK: rows of channels against distance (or time), lap gold, reference cool white dotted ----------
function Traces(box, title, rows) {
  Display.call(this, box, title); this.rows = rows; this.top = 22; this.kind = 'traces';
  if (!title) { this.ph.style.display = 'none'; this.oy = 0; }
  // the label column is as wide as the longest row name, so a name never runs into its trace
  var g = this.cs, wmax = 60; g.font = '14px ' + FONT; rows.forEach(function (r) { wmax = Math.max(wmax, g.measureText(r.k).width + 10); });
  this.X0 = Math.round(wmax); this.W = box.w - this.X0;
  var self = this, drag = null;
  this.stage.addEventListener('mousemove', function (e) { var p = self.local(e); if (drag) { var di = self.idxAt(drag[0]) - self.idxAt(p[0]); setZoom(drag[1] + di, drag[2] + di); return; } if (p[0] >= self.X0 && !S.playing) setCursor(self.idxAt(p[0]), true); });
  this.stage.addEventListener('mousedown', function (e) { var p = self.local(e); if (p[0] >= self.X0 && zoomed()) drag = [p[0], S.z0, S.z1]; });
  window.addEventListener('mouseup', function () { drag = null; });
  this.stage.addEventListener('wheel', function (e) { e.preventDefault(); var p = self.local(e); if (p[0] < self.X0) return; setCursor(self.idxAt(p[0]), true); zoomAt(e.deltaY < 0 ? 0.8 : 1.25); }, { passive: false });
  this.stage.addEventListener('click', function (e) { var p = self.local(e); if (p[1] < self.top) { var c = cornerAt(self.idxAt(p[0])); if (c) zoomCorner(c); } else if (S.playing && p[0] >= self.X0) setCursor(self.idxAt(p[0]), true); });   // while playing the cursor does not follow the mouse: a click jumps there (the video too)
  this.stage.addEventListener('dblclick', function () { WB.cmd('zoom-reset'); });
}
Traces.prototype = Object.create(Display.prototype);
Traces.prototype.ax = function (fi) { return S.axis === 'time' ? at(D.A.t, fi) : fi; };
Traces.prototype.xOf = function (fi) { var a = this.ax(S.z0), b = this.ax(S.z1); return this.X0 + (this.ax(fi) - a) / (b - a) * this.W; };
Traces.prototype.idxAt = function (x) { var a = this.ax(S.z0), b = this.ax(S.z1), v = a + (x - this.X0) / this.W * (b - a); return clamp(S.axis === 'time' ? idxOf(D.A.t, v) : v, 0, D.n - 1); };
// one trace, decimated per pixel column (min/max per column), so any zoom level draws every sample's extent exactly once
Traces.prototype.plot = function (g, arr, yOf, shift, isRef, colour, width) {
  var i0 = Math.max(0, Math.floor(S.z0) - 1), i1 = Math.min(D.n - 1, Math.ceil(S.z1) + 1), tAxis = S.axis === 'time' && isRef;
  g.beginPath(); g.lineWidth = width; g.strokeStyle = colour; g.lineJoin = 'round';
  if (isRef) g.setLineDash([2, 3]); else g.setLineDash([]);
  var col = -1e9, mn = 0, mx = 0, first = 0, last = 0, started = false, n = arr.length;
  var a = this.ax(S.z0), b = this.ax(S.z1), X0 = this.X0, W = this.W;
  for (var i = i0; i <= i1; i++) {
    var k = i - shift; if (k < 0 || k > n - 1) continue;
    var v = at(arr, k); if (v !== v) continue;
    var xv = tAxis ? at(D.R.t, k) : i;
    var x = X0 + (xv - a) / (b - a) * W, px = Math.round(x), y = yOf(v);
    if (px !== col) {
      if (col > -1e9) { if (!started) { g.moveTo(col, first); started = true; } g.lineTo(col, mn); g.lineTo(col, mx); g.lineTo(col, last); }
      col = px; mn = y; mx = y; first = y;
    } else { if (y < mn) mn = y; if (y > mx) mx = y; }
    last = y;
  }
  if (col > -1e9) { if (!started) g.moveTo(col, first); g.lineTo(col, mn); g.lineTo(col, mx); g.lineTo(col, last); }
  g.stroke(); g.setLineDash([]);
};
Traces.prototype.drawStatic = function () {
  var g = this.cs, self = this, A = D.A, R = D.R; this.clear(g); this.tbS = [];
  var y = this.top, X0 = this.X0, w = this.box.w, total = 0;
  this.rows.forEach(function (r) { total += r.h + 16; });
  g.save(); g.beginPath(); g.rect(X0, 0, this.W + 1, this.box.h); g.clip();
  // corner bands with their names (a name is skipped when it would sit on the previous one)
  var lastRight = -1e9, worst = D.worst ? D.worst.c : null;
  D.corners.forEach(function (c) {
    var a = self.xOf(c.i0), b = self.xOf(c.i1); if (b < X0 || a > w) return;
    g.fillStyle = c === worst ? C.bandOn : C.band; g.fillRect(a, 16, Math.max(1, b - a), total);
    g.font = '14px ' + FONT; var tw = g.measureText(c.label).width, cx = (a + b) / 2;
    if (cx - tw / 2 > lastRight + 6 && cx - tw / 2 >= X0 && cx + tw / 2 < w) { self.text(g, self.tbS, c.label, cx, 12, 14, c === worst ? C.gold : C.mute, 'center'); lastRight = cx + tw / 2; }
  });
  g.restore();
  this.rows.forEach(function (r) {
    var tile = S.tile && R && r.ref !== false && r.kind !== 'gap';
    var h = tile ? (r.h - 6) / 2 : r.h;
    var Y = function (v, off) { return y + (off || 0) + h - (clamp(v, r.lo, r.hi) - r.lo) / (r.hi - r.lo) * h; };
    g.strokeStyle = C.line; g.lineWidth = 1; g.beginPath(); g.moveTo(X0, y + r.h + 0.5); g.lineTo(w, y + r.h + 0.5); g.stroke();
    self.text(g, self.tbS, r.k, 0, y + 13, 14, C.mute, 'left');
    g.save(); g.beginPath(); g.rect(X0, y - 1, self.W + 1, r.h + 2); g.clip();
    if (r.kind === 'gap' && D.gap) {
      var z = Y(0), i0 = Math.max(0, Math.floor(S.z0)), i1 = Math.min(D.n - 1, Math.ceil(S.z1));
      if (R) {
        var up = new Path2D(), dn = new Path2D(), upOn = false, dnOn = false;
        for (var i = i0; i <= i1; i++) { var x = self.xOf(i), gap = gapAt(i); if (!isFinite(gap)) { upOn = false; dnOn = false; continue; }
          if (gap >= 0) { if (!upOn) up.moveTo(x, z); up.lineTo(x, Y(gap)); upOn = true; } else { upOn = false; }
          if (gap <= 0) { if (!dnOn) dn.moveTo(x, z); dn.lineTo(x, Y(gap)); dnOn = true; } else { dnOn = false; }
        }
        g.fillStyle = 'rgba(229,83,75,.55)'; g.fill(up); g.fillStyle = 'rgba(60,207,126,.55)'; g.fill(dn);
      }
      g.strokeStyle = '#3a3a40'; g.beginPath(); g.moveTo(X0, z + 0.5); g.lineTo(w, z + 0.5); g.stroke();
      D.M.forEach(function (lap, mi) { self.plot(g, lap.gap, Y, 0, true, MULTI[mi], 1.3); });
    } else {
      if (r.kind === 'brakeabs' && A.c.BrakeABSactive) {
        g.fillStyle = 'rgba(255,159,67,.28)'; var on = -1, j0 = Math.max(0, Math.floor(S.z0)), j1 = Math.min(D.n - 1, Math.ceil(S.z1));
        for (var j = j0; j <= j1 + 1; j++) { var act = j <= j1 && A.c.BrakeABSactive[j] > 0.5; if (act && on < 0) on = j; if (!act && on >= 0) { var xa = self.xOf(on), xb = self.xOf(j); g.fillRect(xa, y, Math.max(1.4, xb - xa), tile ? h : r.h); on = -1; } }
      }
      var aArr = A.c[r.key], rArr = R && r.ref !== false ? R.c[r.key] : null;
      if (tile) {
        g.strokeStyle = C.line; g.beginPath(); g.moveTo(X0, y + h + 3.5); g.lineTo(w, y + h + 3.5); g.stroke();
        if (rArr) self.plot(g, rArr, function (v) { return Y(v, h + 6); }, offsetSamples(), true, C.ref, 1.2);
        D.M.forEach(function (lap, mi) { if (lap.c[r.key]) self.plot(g, lap.c[r.key], function (v) { return Y(v, h + 6); }, 0, true, MULTI[mi], 1.1); });
        if (aArr) self.plot(g, aArr, function (v) { return Y(v, 0); }, 0, false, r.col || C.gold, 1.6);
      } else {
        if (rArr) self.plot(g, rArr, Y, offsetSamples(), true, C.ref, 1.2);
        D.M.forEach(function (lap, mi) { if (lap.c[r.key]) self.plot(g, lap.c[r.key], Y, 0, true, MULTI[mi], 1.1); });
        if (aArr) self.plot(g, aArr, Y, 0, false, r.col || C.gold, 1.6);
      }
    }
    g.restore();
    y += r.h + 16;
  });
  // distance ticks every km (or seconds on the time axis)
  var axEnd = this.ax(S.z1), axStart = this.ax(S.z0);
  var stepTick = S.axis === 'time' ? (axEnd - axStart > 30 ? 10 : axEnd - axStart > 8 ? 2 : 1) : ((S.z1 - S.z0) * D.step > 2500 ? 1000 : (S.z1 - S.z0) * D.step > 600 ? 250 : 100);
  var unit = S.axis === 'time' ? 's' : stepTick >= 1000 ? 'km' : 'm';
  var v0 = Math.ceil((S.axis === 'time' ? axStart : axStart * D.step) / stepTick) * stepTick, vEnd = S.axis === 'time' ? axEnd : axEnd * D.step, k = 0, lastX = -1e9;
  for (var v = v0; v <= vEnd + 1e-6 && k < 60; v += stepTick, k++) {
    var fi = S.axis === 'time' ? idxOf(A.t, v) : v / D.step, xx = this.xOf(fi), lab = (unit === 'km' ? v / 1000 : v) + (k === 0 ? ' ' + unit : '');
    g.font = '14px ' + FONT; var tw = g.measureText(lab).width;
    if (xx - tw / 2 > lastX + 8 && xx + tw / 2 <= w) { this.text(g, this.tbS, lab, xx, y + 2, 14, C.dim, 'center'); lastX = xx + tw / 2; }
  }
  this.bottom = y - 12;
};
Traces.prototype.drawOverlay = function () {
  var g = this.co, self = this, A = D.A, R = D.R; this.clear(g); this.tbO = [];
  var x = this.xOf(S.cur), ri = R ? rIdx(S.cur) : 0, ci = Math.round(S.cur), cri = isFinite(ri) ? Math.round(ri) : -1;
  if (S.refCur != null) { var rx = this.xOf(S.refCur); g.strokeStyle = '#6b6b72'; g.setLineDash([4, 4]); g.beginPath(); g.moveTo(rx, 16); g.lineTo(rx, this.bottom); g.stroke(); g.setLineDash([]); }
  if (x >= this.X0 - 1 && x <= this.box.w + 1) { g.strokeStyle = C.gold; g.lineWidth = 1; g.beginPath(); g.moveTo(Math.round(x) + 0.5, 16); g.lineTo(Math.round(x) + 0.5, this.bottom); g.stroke(); }
  var y = this.top;
  this.rows.forEach(function (r) {
    var dec = r.d || 0;
    if (r.kind === 'gap' && D.gap) { var gv = gapAt(ci) - (S.refCur != null ? gapAt(Math.round(S.refCur)) : 0); self.text(g, self.tbO, isFinite(gv) ? sgn(gv, 2) : '–', 0, y + 36, 18, gv > 0 ? C.loss : C.gain, 'left'); }
    else {
      var aArr = A.c[r.key], rArr = R && r.ref !== false ? R.c[r.key] : null;
      if (aArr) { var av = aArr[ci]; if (S.refCur != null) av -= aArr[Math.round(S.refCur)]; self.text(g, self.tbO, S.refCur != null ? sgn(av, dec) : num(av, dec), 0, y + 36, 18, r.col || C.gold, 'left'); }
      if (rArr && cri >= 0 && cri < D.n && r.h >= 56) self.text(g, self.tbO, num(rArr[cri], dec), 0, y + 54, 15, C.ref, 'left');
    }
    if (D.M.length) {
      var active = r.kind === 'gap' ? D.gap : A.c[r.key];
      if (active) self.text(g, self.tbO, 'L' + A.info.lap + ' ' + fmt(A.info.time) + ' ' + num(active[ci], r.kind === 'gap' ? 2 : dec), self.X0 + 8, y + 15, 12, C.gold, 'left');
      D.M.forEach(function (lap, mi) { var ar = r.kind === 'gap' ? lap.gap : lap.c[r.key]; if (ar) self.text(g, self.tbO, 'L' + lap.info.lap + ' ' + fmt(lap.info.time) + ' ' + num(ar[ci], r.kind === 'gap' ? 2 : dec), self.X0 + 158 + mi * 150, y + 15, 12, MULTI[mi], 'left'); });
    }
    y += r.h + 16;
  });
};

// ---------- MAP from Lat/Lon, coloured by gap (default), speed or any channel; dots for both laps ----------
function MapView(box, title) {
  Display.call(this, box, title); var self = this; this.kind = 'map';
  this.stage.addEventListener('mousemove', function (e) { if (S.playing) return; var p = self.local(e), k = self.nearest(p[0], p[1], 24); if (k >= 0) setCursor(k); });
  this.stage.addEventListener('click', function (e) { var p = self.local(e), c = self.cornerHit(p[0], p[1]); if (c) zoomCorner(c); });
  this.stage.addEventListener('wheel', function (e) { e.preventDefault(); zoomAt(e.deltaY < 0 ? 0.8 : 1.25); }, { passive: false });
}
MapView.prototype = Object.create(Display.prototype);
MapView.prototype.fit = function () {
  var A = D.A, n = D.n, lat0 = A.c.Lat[0], k = 111320, cl = Math.cos(lat0 * Math.PI / 180), pts = [], i;
  for (i = 0; i < n; i++) pts.push([(A.c.Lon[i] - A.c.Lon[0]) * k * cl, (A.c.Lat[i] - lat0) * k]);
  var best = null, w = this.box.w, h = this.box.h, pad = 26;
  for (var deg = 0; deg < 180; deg += 15) {
    var r = deg * Math.PI / 180, c = Math.cos(r), s = Math.sin(r), x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
    for (i = 0; i < n; i++) { var x = pts[i][0] * c - pts[i][1] * s, y = pts[i][0] * s + pts[i][1] * c; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    var sc = Math.min((w - 2 * pad) / (x1 - x0), (h - 2 * pad) / (y1 - y0));
    if (!best || sc > best.sc) best = { c: c, s: s, x0: x0, x1: x1, y0: y0, y1: y1, sc: sc };
  }
  var B = best, ox = (w - (B.x1 - B.x0) * B.sc) / 2, oy = (h - (B.y1 - B.y0) * B.sc) / 2;
  this.P = new Float32Array(n * 2);
  for (i = 0; i < n; i++) { var xx = pts[i][0] * B.c - pts[i][1] * B.s, yy = pts[i][0] * B.s + pts[i][1] * B.c; this.P[i * 2] = ox + (xx - B.x0) * B.sc; this.P[i * 2 + 1] = h - (oy + (yy - B.y0) * B.sc); }
};
MapView.prototype.pt = function (fi) { var i = clamp(Math.round(fi), 0, D.n - 1); return [this.P[i * 2], this.P[i * 2 + 1]]; };
MapView.prototype.nearest = function (x, y, r) { var best = -1, bd = r * r; for (var i = 0; i < D.n; i += 2) { var dx = this.P[i * 2] - x, dy = this.P[i * 2 + 1] - y, d = dx * dx + dy * dy; if (d < bd) { bd = d; best = i; } } return best; };
MapView.prototype.cornerHit = function (x, y) { for (var k = 0; k < D.corners.length; k++) { var p = this.pt(D.corners[k].ia); if ((p[0] - x) * (p[0] - x) + (p[1] - y) * (p[1] - y) < 144) return D.corners[k]; } return null; };
MapView.prototype.colour = function (i) {
  if (S.mapColour === 'gap' && D.gap) { var a = Math.max(0, i - 6), b = Math.min(D.n - 1, i + 6); return gainColour((D.gap[b] - D.gap[a]) / ((b - a) * D.step / 100)); }
  var key = S.mapColour === 'gap' || S.mapColour === 'speed' ? 'kmh' : S.mapColour, arr = D.A.c[key];
  if (!arr) return '#4a4a50';
  if (!this.range || this.range.key !== key) { var lo = 1e9, hi = -1e9; for (var k = 0; k < D.n; k++) { if (arr[k] < lo) lo = arr[k]; if (arr[k] > hi) hi = arr[k]; } this.range = { key: key, lo: lo, hi: hi }; }
  return speedColour(arr[i], this.range.lo, this.range.hi);
};
MapView.prototype.drawStatic = function () {
  if (!this.P) this.fit();
  var g = this.cs, self = this, n = D.n, i; this.clear(g); this.tbS = [];
  g.lineCap = 'round'; g.lineJoin = 'round';
  g.beginPath(); g.lineWidth = 13; g.strokeStyle = '#000'; for (i = 0; i < n; i += 3) { var p = this.pt(i); if (i) g.lineTo(p[0], p[1]); else g.moveTo(p[0], p[1]); } g.closePath(); g.stroke();
  var zoomedNow = zoomed();
  for (i = 0; i < n - 3; i += 3) {
    var a = this.pt(i), b = this.pt(i + 3), inZ = !zoomedNow || (i + 3 >= S.z0 && i <= S.z1);
    g.beginPath(); g.lineWidth = 6; g.globalAlpha = inZ ? 1 : 0.22; g.strokeStyle = this.colour(i); g.moveTo(a[0], a[1]); g.lineTo(b[0], b[1]); g.stroke();
  }
  g.globalAlpha = 1;
  D.events.forEach(function (e) { if (e.type === 'ABS') return; var p = self.pt(e.i); g.beginPath(); g.lineWidth = 2; g.strokeStyle = evColour(e); g.arc(p[0], p[1], 5, 0, 7); g.stroke(); });
  var worst = D.worst ? D.worst.c : null;
  D.corners.forEach(function (c) {
    var p = self.pt(c.ia), num = (c.label.replace(/^T/, '') || c.n).toString().substring(0, 3);
    g.beginPath(); g.fillStyle = '#000'; g.strokeStyle = c === worst ? C.gold : '#6b5a20'; g.lineWidth = 1.2; g.arc(p[0], p[1], 10, 0, 7); g.fill(); g.stroke();
    self.text(g, self.tbS, num, p[0], p[1] + 4, num.length > 2 ? 9 : 11, C.gold, 'center');
  });
  if (S.refCur != null) { var q = this.pt(S.refCur); g.beginPath(); g.lineWidth = 2; g.strokeStyle = '#8a8a92'; g.arc(q[0], q[1], 8, 0, 7); g.stroke(); }
};
MapView.prototype.drawOverlay = function () {
  var g = this.co; this.clear(g);
  if (D.R) { var ri = idxOf(D.R.t, at(D.A.t, S.cur)), q = this.pt(ri); g.beginPath(); g.fillStyle = C.ref; g.strokeStyle = '#000'; g.lineWidth = 1.5; g.arc(q[0], q[1], 5, 0, 7); g.fill(); g.stroke(); }
  var p = this.pt(S.cur); g.beginPath(); g.fillStyle = C.gold; g.strokeStyle = '#000'; g.lineWidth = 2; g.arc(p[0], p[1], 7, 0, 7); g.fill(); g.stroke();
};

// ---------- READOUTS: values at the cursor, lap / reference / difference (DOM, cheap to update) ----------
function Readouts(box, keys) {
  Display.call(this, box, 'At the cursor'); this.keys = keys; this.stage.style.height = 'auto'; this.cs.canvas.remove(); this.co.canvas.remove(); this.kind = 'readouts';
  var t = el('table', 'ro'), self = this; this.cells = [];
  keys.forEach(function (k) { var tr = el('tr'); tr.innerHTML = '<td class="n">' + CAT[k].label + '</td><td class="a"></td><td class="r"></td><td class="v"></td>'; t.appendChild(tr); self.cells.push(tr.children); });
  this.stage.appendChild(t);
  var h = this; hooks.push(function () { h.update(); });
}
Readouts.prototype = Object.create(Display.prototype);
Readouts.prototype.update = function () {
  var ci = Math.round(S.cur), ri = D.R && isFinite(rIdx(S.cur)) ? Math.round(rIdx(S.cur)) : -1, c = cornerAt(ci), self = this;
  var where = c ? c.label + (Math.abs(ci - c.ia) < 15 ? ' apex' : '') : (ci * D.step / 1000).toFixed(2) + ' km';
  this.ph.innerHTML = 'At the cursor · <b>' + where + '</b>' + (S.refCur != null ? ' · <span class="r">vs R cursor</span>' : S.axis === 'time' ? ' · same moment' : '');
  this.keys.forEach(function (k, j) {
    var a = D.A.c[k], r = D.R ? D.R.c[k] : null, dec = CAT[k].dec, cells = self.cells[j];
    if (!a) { cells[1].textContent = '–'; cells[2].textContent = ''; cells[3].textContent = ''; return; }
    var av = a[ci], diff = null;
    if (S.refCur != null) diff = av - a[Math.round(S.refCur)]; else if (r) diff = av - r[ri];
    cells[1].textContent = num(av, dec); cells[2].textContent = r ? num(r[ri], dec) : ''; cells[3].textContent = diff == null ? '' : sgn(diff, dec);
  });
};

// ---------- EVENTS LIST: jumpable; the row at the cursor is lit ----------
function EventList(box, rows) {
  this.compact = box.w < 800;                             // a narrow list: shorter words, smaller tags, no wrapping
  Display.call(this, box, 'Events on this lap');
  this.rowsMax = rows; this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'events';
  this.list = el('div'); this.stage.appendChild(this.list); this.keys = el('div', 'keys'); this.stage.appendChild(this.keys);
  if (this.compact) this.el.classList.add('compact');
  var ev = D.events, self = this, nAbs = ev.filter(function (e) { return e.type === 'ABS'; }).length, nLock = ev.filter(function (e) { return e.type === 'LOCK'; }).length, nSpin = ev.filter(function (e) { return e.type === 'SPIN'; }).length;
  this.keys.innerHTML = plural(ev.length, 'event') + ' this lap · <b>' + nAbs + '</b> ABS · <b>' + plural(nLock, 'lock-up') + '</b> · <b>' + nSpin + '</b> rear slip' +
    (!this.compact && D.A.c.wfPct ? ' · wheel force peak <b>' + Math.max.apply(null, Array.prototype.slice.call(D.A.c.wfPct)).toFixed(0) + ' %</b>' : '');
  if (!ev.length) this.list.appendChild(el('div', 'keys', 'No events'));
  this.first = -1; hooks.push(function () { self.update(); });
}
EventList.prototype = Object.create(Display.prototype);
EventList.prototype.update = function () {
  var ev = D.events, ci = Math.round(S.cur), k = -1, self = this;
  for (var i = 0; i < ev.length; i++) if (ci >= ev[i].i - 2 && ci <= ev[i].j + 2) { k = i; break; }
  var near = k; if (near < 0) { for (i = 0; i < ev.length; i++) if (ev[i].i > ci) { near = i; break; } if (near < 0) near = ev.length - 1; }
  var first = clamp(near - 1, 0, Math.max(0, ev.length - this.rowsMax));
  if (first !== this.first || k !== this.lit) {
    this.first = first; this.lit = k; this.list.innerHTML = '';
    ev.slice(first, first + this.rowsMax).forEach(function (e, j) {
      var row = el('div', 'ev' + (first + j === k ? ' on' : ''));
      row.innerHTML = '<span class="tag" style="color:' + evColour(e) + '">' + (e.type === 'SPIN' ? (self.compact ? 'SLIP' : 'REAR SLIP') : e.type) + '</span><span class="gold">' + (e.at || '–') + '</span><span>' + evText(e, self.compact) + '</span><span class="km">' + (e.d / 1000).toFixed(2) + ' km</span>';
      row.addEventListener('click', function () { WB.cmd('cursor', e.i); });
      if (X.jumpBtn) row.appendChild(X.jumpBtn({ t: D.A.t[e.i], short: self.compact }));       // SEE IN iRACING (workbench-share.js; shown only while the sim has this session open)
      self.list.appendChild(row);
    });
  }
};

// ---------- PEDALS: share of the lap in each pedal state (DRIVER page) ----------
function Pedals(box) {
  Display.call(this, box, 'Pedals · <span style="color:#3ccf7e">full</span> · <span style="color:#2b7d55">part</span> · coast · <span style="color:#a8443d">brake</span> · <span style="color:#e5534b">hard</span>');
  this.keys = el('div', 'keys'); this.el.appendChild(this.keys); this.kind = 'pedals';
}
Pedals.prototype = Object.create(Display.prototype);
Pedals.prototype.drawStatic = function () {
  var g = this.cs, self = this, w = this.box.w - 90; this.clear(g); this.tbS = [];
  var cols = [C.gain, '#2b7d55', C.dim, '#a8443d', C.loss], order = [2, 1, 0, 3, 4];
  var shA = share(D.A, 'pedal', order), shR = D.R ? share(shiftedRefLap(), 'pedal', order) : null;
  function bar(sh, y, colour) { var x = 0; sh.forEach(function (v, k) { g.fillStyle = cols[k]; g.fillRect(x, y, v / 100 * w, 18); x += v / 100 * w; }); self.text(g, self.tbS, sh[0].toFixed(0) + ' % full', self.box.w - 2, y + 14, 14, colour, 'right'); }
  bar(shA, 0, C.gold); if (shR) bar(shR, 28, C.ref);
  this.keys.innerHTML = 'coast ' + shA[2].toFixed(1) + ' %' + (shR ? ' vs ' + shR[2].toFixed(1) + ' %' : '') + ' · hard brake ' + shA[4].toFixed(1) + ' %' + (shR ? ' vs ' + shR[4].toFixed(1) + ' %' : '');
};

// ---------- G-G skidpad (GRIP page): both laps, 1/2/3 g rings, the cursor as a bigger dot ----------
function GG(box) { Display.call(this, box, 'Grip used · g-g skidpad · both laps'); this.keys = el('div', 'keys'); this.el.appendChild(this.keys); this.kind = 'gg'; }
GG.prototype = Object.create(Display.prototype);
GG.prototype.xy = function (Lp, i) { var c = this.box.w / 2, sc = c / 3.2; return [c + Lp.c.latG[i] * sc, c - Lp.c.longG[i] * sc]; };
GG.prototype.drawStatic = function () {
  var g = this.cs, self = this, Sz = this.box.w, c = Sz / 2, sc = c / 3.2, i; this.clear(g); this.tbS = [];
  g.strokeStyle = C.line; g.lineWidth = 1;
  [1, 2, 3].forEach(function (k) { g.beginPath(); g.arc(c, c, k * sc, 0, 7); g.stroke(); self.text(g, self.tbS, k + ' g', c + k * sc * 0.707 + 4, c - k * sc * 0.707 - 4, 14, C.dim, 'left'); });
  g.beginPath(); g.moveTo(0, c); g.lineTo(Sz, c); g.moveTo(c, 0); g.lineTo(c, Sz); g.stroke();
  var zoomedNow = zoomed();
  function dots(Lp, colour, r, alpha) { g.fillStyle = colour; for (i = 0; i < D.n; i += 2) { var p = self.xy(Lp, i); g.globalAlpha = zoomedNow && (i < S.z0 || i > S.z1) ? alpha * 0.25 : alpha; g.beginPath(); g.arc(p[0], p[1], r, 0, 7); g.fill(); } g.globalAlpha = 1; }
  var refLap = shiftedRefLap(); if (refLap) dots(refLap, C.ref, 1.3, 0.35);
  dots(D.A, C.gold, 1.5, 0.6);
  this.text(g, this.tbS, 'ACCELERATING', c, 14, 14, C.mute, 'center'); this.text(g, this.tbS, 'BRAKING', c, Sz - 6, 14, C.mute, 'center');
  var pct = function (Lp) { var v = Array.prototype.slice.call(Lp.c.gTot).sort(function (a, b) { return a - b; }); return v[Math.floor(v.length * 0.95)]; };
  var peak = 0; for (i = 0; i < D.n; i++) peak = Math.max(peak, Math.abs(D.A.c.latG[i]));
  this.keys.innerHTML = '95 % of the lap within <b>' + pct(D.A).toFixed(2) + ' g</b>' + (refLap ? ' (ref ' + pct(refLap).toFixed(2) + ')' : '') + ' · peak sideways <b>' + peak.toFixed(2) + ' g</b>';
};
GG.prototype.drawOverlay = function () {
  var g = this.co; this.clear(g); var ci = Math.round(S.cur);
  if (D.R && isFinite(rIdx(S.cur))) { var ri = Math.round(rIdx(S.cur)), q = this.xy(shiftedRefLap(), Math.round(S.cur)); g.beginPath(); g.fillStyle = C.ref; g.strokeStyle = '#000'; g.lineWidth = 1.5; g.arc(q[0], q[1], 5, 0, 7); g.fill(); g.stroke(); }
  var p = this.xy(D.A, ci); g.beginPath(); g.fillStyle = C.gold; g.strokeStyle = '#000'; g.lineWidth = 2; g.arc(p[0], p[1], 7, 0, 7); g.fill(); g.stroke();
};

// ---------- CORNER TABLE (GRIP page): sorted by time lost; a row click zooms every display to that corner ----------
function CornerTable(box) {
  Display.call(this, box, 'Corners · this lap <span class="r">reference</span> · sorted by time lost'); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'corners';
  var t = el('table', 'ct'), self = this; this.rows = [];
  t.innerHTML = '<tr><th>TURN</th><th>GAP s</th><th>MIN ' + SPD_U.toUpperCase() + '</th><th>PEAK LAT g</th><th>PEAK SLIP °</th><th>ABS</th></tr>';
  D.cstat.slice().sort(function (x, y) { return y.dt - x.dt; }).forEach(function (k) {
    var tr = el('tr'), r = k.r, sm = function (v) { return r ? '<small>' + v + '</small>' : ''; };
    tr.innerHTML = '<td class="gold">' + k.c.label + '</td><td class="' + (!r ? 'mute' : k.dt > 0.005 ? 'loss' : k.dt < -0.005 ? 'gain' : 'mute') + '">' + (r ? sgn(k.dt, 2) : '–') + '</td>' +
      '<td>' + k.a.vmin.toFixed(0) + sm(r ? r.vmin.toFixed(0) : '') + '</td><td>' + k.a.lat.toFixed(2) + sm(r ? r.lat.toFixed(2) : '') + '</td><td>' + Math.abs(k.a.beta).toFixed(1) + sm(r ? Math.abs(r.beta).toFixed(1) : '') + '</td>' +
      '<td>' + (k.a.abs ? k.a.abs.toFixed(0) + ' m' : '–') + sm(r ? (r.abs ? r.abs.toFixed(0) : '–') : '') + '</td>';
    tr.addEventListener('click', function () { zoomCorner(k.c); });
    t.appendChild(tr); self.rows.push([tr, k.c]);
  });
  this.stage.appendChild(t);
  hooks.push(function () { var c = cornerAt(Math.round(S.cur)); self.rows.forEach(function (r) { r[0].className = r[1] === c ? 'on' : ''; }); });
}
CornerTable.prototype = Object.create(Display.prototype);

// ---------- TIME IN GEAR (GRIP page) ----------
function Gears(box) { Display.call(this, box, 'Time in each gear · % of the lap · <b>this lap</b> <span class="r">reference</span>'); this.keys = el('div', 'keys'); this.el.appendChild(this.keys); this.kind = 'gears'; }
Gears.prototype = Object.create(Display.prototype);
Gears.prototype.drawStatic = function () {
  var g = this.cs, self = this, vals = [1, 2, 3, 4, 5, 6], shA = share(D.A, 'Gear', vals), shR = D.R ? share(shiftedRefLap(), 'Gear', vals) : null, h = this.box.h - 24; this.clear(g); this.tbS = [];
  shA.forEach(function (v, k) {
    var x = k * 70, ya = h - v * h / 50;
    g.fillStyle = C.gold; g.fillRect(x + 8, ya, 24, v * h / 50);
    if (shR) { g.fillStyle = C.ref; g.globalAlpha = 0.55; g.fillRect(x + 36, h - shR[k] * h / 50, 24, shR[k] * h / 50); g.globalAlpha = 1; }
    self.text(g, self.tbS, String(k + 1), x + 34, h + 18, 14, C.mute, 'center');
    if (v >= 1) self.text(g, self.tbS, v.toFixed(0), x + 20, ya - 4, 12, C.gold, 'center');
  });
  var absM = 0; if (D.A.c.BrakeABSactive) for (var i = 0; i < D.n; i++) if (D.A.c.BrakeABSactive[i] > 0.5) absM += D.step;
  var bb = D.A.c.dcBrakeBias ? D.A.c.dcBrakeBias[0] : null;
  this.keys.innerHTML = (bb != null ? 'brake bias ' + bb.toFixed(1) + ' % · ' : '') + 'ABS working ' + absM.toFixed(0) + ' m of the lap' + (D.A.c.wfPct ? ' · wheel force peak ' + Math.max.apply(null, Array.prototype.slice.call(D.A.c.wfPct)).toFixed(0) + ' %' : '');
};

// ====================================================================================================================
// C-41: BRAKING, TYRES & STINT, SUSPENSION, SPLITS and the channel picker, on the same engine (one state S, linked zoom, one cursor).
// Data: D.deep = /analysis/deep (the C-34 engines: per-corner braking, ABS, lock-ups, coast, stints, per-lap fuel and tyres, setting
// changes) and D.sess = /analysis/session?corners=1 (iRacing's sectors, best sectors, consistency, every lap's time through every
// corner). The page lays out what the engines measured; it recomputes nothing they own. A page is offered only when its data is
// there (avail), so there is never a dead tab.
// ====================================================================================================================
function dcOf(c) { return D.dc && D.dc[c.n] ? D.dc[c.n] : null; }
function brakeCorners() { return D.corners.filter(function (c) { var k = dcOf(c); return k && ((k.me && k.me.brake) || (k.ref && k.ref.brake)); }).sort(function (a, b) { return a.ia - b.ia; }); }
function avail(id) {
  var dp = D && D.deep, ss = D && D.sess, A = D && D.A;
  if (!D) return false;
  if (id === 'driver' || id === 'grip') return true;
  if (X.pages[id]) return !!X.pages[id].avail();
  if (id === 'braking') return !!(dp && A.c.brkPct && brakeCorners().length);
  if (id === 'tyres') return !!(dp && dp.stints && dp.stints.length);
  if (id === 'suspension') return WHEELS.every(function (w) { return A.c['ride' + w] && A.c['defl' + w] && A.c['vel' + w]; });
  if (id === 'splits') return !!(ss && ss.laps && ss.sectorAt && ss.sectorAt.length > 1 && ss.laps.some(function (l) { return l.valid && l.sectors; }));
  return false;
}
function pages() { return PAGES.filter(function (p) { return avail(p.id); }); }
function fx(v, d) { return v == null || !isFinite(v) ? '–' : v.toFixed(d); }
function pairCell(a, r, dec, withRef) { return fx(a, dec) + (withRef ? '<small>' + fx(r, dec) + '</small>' : ''); }
// a plain polyline of arr[i - shift] for i0..i1 (small windows: no decimation needed)
function polyline(g, arr, i0, i1, X, Y, shift) {
  g.beginPath(); var on = false;
  for (var i = i0; i <= i1; i++) { var k = i - (shift || 0); if (k < 0 || k > arr.length - 1) { on = false; continue; } var x = X(i), y = Y(at(arr, k)); if (!on) { g.moveTo(x, y); on = true; } else g.lineTo(x, y); }
  g.stroke();
}

// ---------- BRAKING: one row per braking zone, lap against the reference ----------
function BrakeTable(box) {
  Display.call(this, box, 'Braking by corner · this lap <span class="r">reference</span> ');
  this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'braketable';
  var t = el('table', 'ct'), self = this, hasRef = !!D.R; this.rows = [];
  t.innerHTML = '<tr><th>TURN</th><th>BRAKE PT m</th><th>VS REF</th><th>PEAK %</th><th>TO PEAK s</th><th>RELEASE s</th><th>TRAIL s</th><th>ABS %</th><th>ABS CUT %</th><th>LOCK-UPS</th><th>COAST s</th></tr>';
  brakeCorners().forEach(function (c) {
    var k = dcOf(c), a = k.me.brake, r = k.ref ? k.ref.brake : null, ab = k.me.abs, ar = k.ref ? k.ref.abs : null, wr = hasRef && !!k.ref, tr = el('tr');
    var vs = a && r ? a.startM - r.startM : null;
    var lk = k.me.lock, lr = k.ref ? k.ref.lock : null;
    var lockTxt = function (l) { return l && l.n ? l.n + ' ' + l.wheel : '–'; };
    tr.innerHTML = '<td class="gold">' + c.label + '</td>' +
      '<td>' + pairCell(a ? a.startM : null, r ? r.startM : null, 0, wr) + '</td>' +
      '<td class="mute">' + (vs == null ? '–' : Math.abs(vs) < 1 ? 'same' : Math.abs(vs).toFixed(0) + ' m ' + (vs > 0 ? 'later' : 'earlier')) + '</td>' +
      '<td>' + pairCell(a ? a.peakPct : null, r ? r.peakPct : null, 0, wr) + '</td>' +
      '<td>' + pairCell(a ? a.toPeakS : null, r ? r.toPeakS : null, 2, wr) + '</td>' +
      '<td>' + pairCell(a ? a.releaseS : null, r ? r.releaseS : null, 2, wr) + '</td>' +
      '<td>' + pairCell(a ? a.trailS : null, r ? r.trailS : null, 2, wr) + '</td>' +
      '<td>' + pairCell(ab ? ab.share * 100 : null, ar ? ar.share * 100 : null, 0, wr) + '</td>' +
      '<td>' + pairCell(ab ? ab.peakCutPct : null, ar ? ar.peakCutPct : null, 0, wr) + '</td>' +
      '<td class="' + (lk && lk.n ? 'loss' : '') + '">' + lockTxt(lk) + (wr ? '<small>' + lockTxt(lr) + '</small>' : '') + '</td>' +
      '<td>' + pairCell(a ? a.coastS : null, r ? r.coastS : null, 2, wr) + '</td>';
    tr.addEventListener('click', function () { zoomCorner(c); });
    t.appendChild(tr); self.rows.push([tr, c]);
  });
  this.stage.appendChild(t);
  hooks.push(function () { var c = cornerAt(Math.round(S.cur)); self.rows.forEach(function (r) { r[0].className = r[1] === c ? 'on' : ''; }); });
}
BrakeTable.prototype = Object.create(Display.prototype);

// brake (top) and steering (below) of every braking zone, both laps, ABS shaded: the "zoomed per corner" view
function BrakeCells(box) {
  Display.call(this, box, 'Brake and steering at every braking zone · <b>this lap</b> <span class="r">reference</span> · ABS shaded');
  this.kind = 'brakecells'; var self = this, list = brakeCorners(), k = list.length, gap = 12;
  var per = k <= 5 ? Math.max(1, k) : k <= 10 ? 5 : 6, rows = Math.max(1, Math.ceil(k / per)), cw = (box.w - gap * (per - 1)) / per, ch = (box.h - gap * (rows - 1)) / rows;
  this.cells = list.map(function (c, j) {
    var kd = dcOf(c), sA = kd.me.brake ? kd.me.brake.startM : 1e9, sR = kd.ref && kd.ref.brake ? kd.ref.brake.startM : 1e9, first = Math.min(sA, sR);
    var d0 = Math.max(0, first - 40), d1 = Math.min(D.L, Math.max(c.da, first + 60) + 50);
    return { c: c, kd: kd, x: (j % per) * (cw + gap), y: Math.floor(j / per) * (ch + gap), w: cw, h: ch, i0: Math.round(d0 / D.step), i1: Math.round(d1 / D.step) };
  });
  this.stage.addEventListener('click', function (e) {
    var p = self.local(e);
    for (var q = 0; q < self.cells.length; q++) { var z = self.cells[q]; if (p[0] >= z.x && p[0] <= z.x + z.w && p[1] >= z.y && p[1] <= z.y + z.h) { zoomCorner(z.c); return; } }
  });
}
BrakeCells.prototype = Object.create(Display.prototype);
BrakeCells.prototype.drawStatic = function () {
  var g = this.cs, self = this, A = D.A, R = D.R; this.clear(g); this.tbS = [];
  this.cells.forEach(function (q) {
    g.fillStyle = '#101012'; g.fillRect(q.x, q.y, q.w, q.h); g.strokeStyle = C.line; g.lineWidth = 1; g.strokeRect(q.x + 0.5, q.y + 0.5, q.w - 1, q.h - 1);
    var b = q.kd.me.brake;
    self.text(g, self.tbS, q.c.label, q.x + 10, q.y + 22, 16, C.gold, 'left');
    self.text(g, self.tbS, b ? Math.round(b.startM) + ' m · peak ' + Math.round(b.peakPct) + ' %' : 'no braking', q.x + q.w - 10, q.y + 22, 15, b ? C.ink : C.mute, 'right');
    var px = q.x + 10, pw = q.w - 20, top = q.y + 34, inner = q.h - 34 - 10, bh = Math.round((inner - 12) * 0.58), sy = top + bh + 12, sh = inner - 12 - bh;
    var X = function (i) { return px + (i - q.i0) / (q.i1 - q.i0) * pw; }, off = offsetSamples();
    var Yb = function (v) { return top + bh - clamp(v, 0, 100) / 100 * bh; };
    g.fillStyle = 'rgba(255,159,67,.28)'; var on = -1;
    if (A.c.BrakeABSactive) for (var j = q.i0; j <= q.i1 + 1; j++) { var act = j <= q.i1 && A.c.BrakeABSactive[j] > 0.5; if (act && on < 0) on = j; if (!act && on >= 0) { g.fillRect(X(on), top, Math.max(1.4, X(j) - X(on)), bh); on = -1; } }
    g.strokeStyle = C.line; g.beginPath(); g.moveTo(px, top + bh + 0.5); g.lineTo(px + pw, top + bh + 0.5); g.moveTo(px, sy + sh / 2 + 0.5); g.lineTo(px + pw, sy + sh / 2 + 0.5); g.stroke();
    var mx = 30, i;
    for (i = q.i0; i <= q.i1; i++) { mx = Math.max(mx, Math.abs(A.c.steerDeg[i]), R ? Math.abs(R.c.steerDeg[clamp(Math.round(i - off), 0, D.n - 1)]) : 0); }
    mx = Math.ceil(mx / 15) * 15;
    var Ys = function (v) { return sy + sh / 2 - clamp(v, -mx, mx) / mx * (sh / 2); };
    g.lineJoin = 'round';
    if (R) { g.setLineDash([2, 3]); g.lineWidth = 1.2; polyline(g, R.c.brkPct, q.i0, q.i1, X, Yb, off); polyline(g, R.c.steerDeg, q.i0, q.i1, X, Ys, off); g.setLineDash([]); }
    g.lineWidth = 1.7; g.strokeStyle = C.gold; polyline(g, A.c.brkPct, q.i0, q.i1, X, Yb, 0); polyline(g, A.c.steerDeg, q.i0, q.i1, X, Ys, 0);
    q.X = X;
  });
};
BrakeCells.prototype.drawOverlay = function () {
  var g = this.co, cur = cornerAt(Math.round(S.cur)); this.clear(g);
  this.cells.forEach(function (q) {
    if (q.c === cur) { g.strokeStyle = C.gold; g.lineWidth = 2; g.strokeRect(q.x + 1, q.y + 1, q.w - 2, q.h - 2); }
    if (S.cur >= q.i0 && S.cur <= q.i1 && q.X) { var x = Math.round(q.X(S.cur)) + 0.5; g.strokeStyle = C.gold; g.lineWidth = 1; g.beginPath(); g.moveTo(x, q.y + 30); g.lineTo(x, q.y + q.h - 6); g.stroke(); }
  });
};

// ---------- TYRES & STINT ----------
function currentStint() {
  var st = D.deep.stints, ln = D.head.lap.lap;
  if (S.stint != null && st[S.stint - 1]) return st[S.stint - 1];
  for (var k = 0; k < st.length; k++) if (ln >= st[k].lapFirst && ln <= st[k].lapLast) return st[k];
  return st[st.length - 1];
}
// the timed laps of a stint: lap time + clean flag from the session list, fuel and tyres from the deep reply
// L-1: a lap iRacing timed but did not count (an off-track in it) is still a real lap - its fuel, tyres and time are drawn - it just is never "the best" (counted: false)
function stintLaps(st) {
  var dl = {}, sv = {}, tm = {}; (D.deep.laps || []).forEach(function (l) { dl[l.lap] = l; });      // an older irdash has no per-lap rows: the lap times still show
  if (D.sess) D.sess.laps.forEach(function (l) { sv[l.n] = l.valid; tm[l.n] = l.timed != null ? l.timed : l.valid; });          // the Session Review's list: timed = iRacing gave the lap a time (out, in laps never), valid = it counted it
  return D.head.laps.filter(function (l) { return l.time != null && l.n >= st.lapFirst && l.n <= st.lapLast; }).map(function (l) {
    var d = dl[l.n] || {}, ok = tm[l.n] != null ? tm[l.n] : l.clean && !l.skip, cn = sv[l.n] != null ? sv[l.n] : ok;
    return { n: l.n, time: l.time, clean: ok, counted: cn, fuel: ok ? d.fuelUsed : null, fuelStart: d.fuelStart, tyre: ok ? d.tyre : null };
  });
}
function TyrePanel(box) {
  Display.call(this, box, ''); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'tyres';
  var st = currentStint(), dp = D.deep, self = this;
  this.ph.innerHTML = 'Tyres · stint <b>' + st.n + '</b> of ' + dp.stints.length + ' · laps ' + st.lapFirst + ' to ' + st.lapLast + (st.minutes != null ? ' · ' + st.minutes.toFixed(1) + ' min' : '') +
    (dp.stints.length > 1 ? dp.stints.map(function (s) { return '<span class="chip' + (s === st ? ' on' : '') + '" data-s="' + s.n + '">STINT ' + s.n + '</span>'; }).join('') : '');
  Array.prototype.forEach.call(this.ph.querySelectorAll('.chip'), function (c) { c.addEventListener('click', function () { S.stint = parseInt(c.getAttribute('data-s'), 10); buildPage(); }); });
  var grid = el('div', 'tgrid'), live = false;
  WHEELS.forEach(function (w) {
    var T = st.tyres ? st.tyres[w] : null; if (!T) return;
    var sf = T.surface || {}, cc = T.carcass || {}, ws = T.wear || {}, pr = T.pressure || {};
    if (cc.live || ws.live) live = true;
    var row = function (name, cls, cells) { return '<tr><td class="n">' + name + '</td>' + cells.map(function (v) { return '<td class="' + cls + '">' + v + '</td>'; }).join('') + '</tr>'; };
    var three = function (o, f) { return ['L', 'M', 'R'].map(function (s) { return f(o[s]); }); };
    var card = el('div', 'tc');
    card.innerHTML = '<div class="tch"><b class="gold">' + w + '</b> ' + WHEEL_NAME[w] + '<span class="tcp"><b>' + fx(pr.endKpa, 0) + '</b> kPa<small>start ' + fx(pr.startKpa, 0) + ' · cold ' + fx(pr.coldKpa, 0) + ' · peak ' + fx(pr.peakKpa, 0) + '</small></span></div>' +
      '<table class="tt"><tr><td class="n"></td><th>LEFT</th><th>MIDDLE</th><th>RIGHT</th></tr>' +
      row('SURFACE °C', 'a', three(sf, function (v) { return fx(v ? v.mean : null, 0); })) + row('SURFACE PEAK', 'r', three(sf, function (v) { return fx(v ? v.peak : null, 0); })) +
      // carcass and tread are as at the last pit stop, not live: the secondary grey, so they do not read like the numbers above
      row('CARCASS °C', 'v asat', three(cc, function (v) { return fx(v, 0); })) + row('TREAD LEFT %', 'v asat', three(ws, function (v) { return fx(v, 0); })) + '</table>';
    grid.appendChild(card);
  });
  this.stage.appendChild(grid);
  var sl = stintLaps(st), lastLap = st.statLap != null ? st.statLap : (sl.length ? sl[sl.length - 1].n : '–');
  this.stage.appendChild(el('div', 'tnote', 'Carcass and tread: as at the last pit stop'));
}
TyrePanel.prototype = Object.create(Display.prototype);

// lap times, fuel per lap and surface temperature by lap over the stint (a chart only with 5+ laps, DESIGN-analysis 2.6)
function StintChart(box, which) {
  var titles = { laps: 'Lap times over the stint · <b>this lap</b> ring · <span style="color:#b46cff">best</span> · <span class="r">reference</span> dotted', fuel: 'Fuel used per lap · litres', temps: 'Surface temperature by lap · °C · <b>front</b> <span class="r">rear</span> · left solid, right dashed' };
  Display.call(this, box, titles[which]); this.kind = 'stintchart'; this.which = which;
}
StintChart.prototype = Object.create(Display.prototype);
StintChart.prototype.drawStatic = function () {
  var g = this.cs, self = this, w = this.box.w, h = this.box.h, st = currentStint(), sl = stintLaps(st), which = this.which; this.clear(g); this.tbS = [];
  var pts = which === 'laps' ? sl.filter(function (l) { return l.clean; }) : which === 'fuel' ? sl.filter(function (l) { return l.fuel != null; }) : sl.filter(function (l) { return l.tyre; });
  var line = 0, note = function (s, col) { self.text(g, self.tbS, s, 0, 18 + line * 28, 18, col || C.ink, 'left'); line++; };
  if (pts.length < 5) {
    if (!pts.length) note('No data in this stint', C.mute);
    else { note(which === 'laps' ? 'Under 5 clean laps:' : which === 'fuel' ? 'Fuel, litres per lap:' : 'Surface °C, tyre mean:', C.mute);
      pts.slice(0, 5).forEach(function (l) { note('L' + l.n + '   ' + (which === 'laps' ? fmt(l.time) : which === 'fuel' ? l.fuel.toFixed(2) + ' l' : WHEELS.map(function (x) { return x + ' ' + fx((l.tyre[x].L + l.tyre[x].M + l.tyre[x].R) / 3, 0); }).join('   ')), l.n === D.head.lap.lap ? C.gold : C.ink); }); }
    return;
  }
  var X0 = 62, X1 = w - 74, Y0 = 8, Y1 = h - 28, n0 = pts[0].n, n1 = pts[pts.length - 1].n;
  var X = function (n) { return X0 + (n - n0) / Math.max(1, n1 - n0) * (X1 - X0); };
  // x labels: lap numbers (every other one when there are many)
  var every = pts.length > 18 ? 2 : 1;
  pts.forEach(function (l, k) { if (k % every === 0) self.text(g, self.tbS, 'L' + l.n, X(l.n), h - 6, 14, l.n === D.head.lap.lap ? C.gold : C.dim, 'center'); });
  g.strokeStyle = C.line; g.lineWidth = 1; g.beginPath(); g.moveTo(X0, Y1 + 0.5); g.lineTo(X1, Y1 + 0.5); g.stroke();
  if (which === 'laps') {
    var lo = Math.min.apply(null, pts.map(function (l) { return l.time; })), hi = Math.max.apply(null, pts.map(function (l) { return l.time; })), rt = D.head.ref ? D.head.ref.time : null;
    if (rt != null) { lo = Math.min(lo, rt); hi = Math.max(hi, rt); }
    lo = Math.floor((lo - 0.2) * 2) / 2; hi = Math.ceil((hi + 0.2) * 2) / 2;
    var Y = function (t) { return Y1 - (t - lo) / (hi - lo) * (Y1 - Y0 - 14); };
    var tickT = function (t) { var m = Math.floor(t / 60); return m + ':' + (t - m * 60 < 10 ? '0' : '') + (t - m * 60).toFixed(1); };
    [lo, (lo + hi) / 2, hi].forEach(function (t) { g.strokeStyle = '#17171a'; g.beginPath(); g.moveTo(X0, Math.round(Y(t)) + 0.5); g.lineTo(X1, Math.round(Y(t)) + 0.5); g.stroke(); self.text(g, self.tbS, tickT(t), 0, Y(t) + 5, 14, C.dim, 'left'); });
    if (rt != null) { g.setLineDash([2, 3]); g.strokeStyle = C.ref; g.lineWidth = 1.2; g.beginPath(); g.moveTo(X0, Y(rt)); g.lineTo(X1, Y(rt)); g.stroke(); g.setLineDash([]); self.text(g, self.tbS, 'REF', w - 2, Y(rt) + 5, 14, C.ref, 'right'); }
    g.strokeStyle = 'rgba(242,194,48,.45)'; g.lineWidth = 1; g.beginPath(); pts.forEach(function (l, k) { if (k) g.lineTo(X(l.n), Y(l.time)); else g.moveTo(X(l.n), Y(l.time)); }); g.stroke();
    var bt = Math.min.apply(null, pts.filter(function (l) { return l.counted; }).map(function (l) { return l.time; }));      // the best is a lap iRacing counted; a faster one it did not count is drawn grey
    pts.forEach(function (l) {
      var isBest = l.counted && l.time === bt, cur = l.n === D.head.lap.lap;
      g.beginPath(); g.fillStyle = isBest ? C.purple : l.counted ? C.gold : C.dim; g.arc(X(l.n), Y(l.time), isBest ? 6 : 4.5, 0, 7); g.fill();
      if (cur) { g.beginPath(); g.strokeStyle = C.gold; g.lineWidth = 2; g.arc(X(l.n), Y(l.time), 10, 0, 7); g.stroke(); }
      if (isBest) self.text(g, self.tbS, fmt(l.time), X(l.n), Y(l.time) - 14, 15, C.purple, 'center');
    });
  } else if (which === 'fuel') {
    var mx = Math.max.apply(null, pts.map(function (l) { return l.fuel; })) * 1.5, bwid = Math.min(40, (X1 - X0) / pts.length * 0.6), Yf = function (v) { return Y1 - v / mx * (Y1 - Y0 - 14); };
    var avg = pts.reduce(function (a, l) { return a + l.fuel; }, 0) / pts.length;
    pts.forEach(function (l) { g.fillStyle = l.n === D.head.lap.lap ? C.gold : 'rgba(242,194,48,.62)'; g.fillRect(X(l.n) - bwid / 2, Yf(l.fuel), bwid, Y1 - Yf(l.fuel)); if (bwid >= 26) self.text(g, self.tbS, l.fuel.toFixed(2), X(l.n), Yf(l.fuel) - 5, 14, C.mute, 'center'); });
    g.setLineDash([3, 4]); g.strokeStyle = C.ref; g.lineWidth = 1.2; g.beginPath(); g.moveTo(X0, Yf(avg)); g.lineTo(X1, Yf(avg)); g.stroke(); g.setLineDash([]);
    var last = pts[pts.length - 1], left = last.fuelStart != null ? last.fuelStart - last.fuel : null;
    self.text(g, self.tbS, 'average ' + avg.toFixed(2) + ' l per lap' + (left != null ? ' · ' + left.toFixed(1) + ' l left after lap ' + last.n + ' · ' + (left / avg).toFixed(1) + ' laps left' : ''), 0, 20, 16, C.ink, 'left');
  } else {
    var mean = function (t) { return (t.L + t.M + t.R) / 3; }, all = [];
    pts.forEach(function (l) { WHEELS.forEach(function (x) { all.push(mean(l.tyre[x])); }); });
    var tl = Math.floor(Math.min.apply(null, all) / 5) * 5, th = Math.ceil(Math.max.apply(null, all) / 5) * 5, Yt = function (v) { return Y1 - (v - tl) / (th - tl) * (Y1 - Y0 - 14); };
    [tl, (tl + th) / 2, th].forEach(function (v) { g.strokeStyle = '#17171a'; g.beginPath(); g.moveTo(X0, Math.round(Yt(v)) + 0.5); g.lineTo(X1, Math.round(Yt(v)) + 0.5); g.stroke(); self.text(g, self.tbS, v.toFixed(0), 0, Yt(v) + 5, 14, C.dim, 'left'); });
    var ends = [];
    WHEELS.forEach(function (x) {
      var front = x === 'LF' || x === 'RF', right = x === 'RF' || x === 'RR', col = front ? C.gold : C.ref;
      g.strokeStyle = col; g.lineWidth = 1.7; g.setLineDash(right ? [7, 4] : []); g.beginPath();
      pts.forEach(function (l, k) { var px = X(l.n), py = Yt(mean(l.tyre[x])); if (k) g.lineTo(px, py); else g.moveTo(px, py); }); g.stroke(); g.setLineDash([]);
      ends.push({ x: x, y: Yt(mean(pts[pts.length - 1].tyre[x])), v: mean(pts[pts.length - 1].tyre[x]), col: col });
    });
    ends.sort(function (a, b) { return a.y - b.y; });
    for (var k = 1; k < ends.length; k++) if (ends[k].y - ends[k - 1].y < 17) ends[k].y = ends[k - 1].y + 17;       // direct labels keep apart
    ends.forEach(function (e) { self.text(g, self.tbS, e.x + ' ' + e.v.toFixed(0), X1 + 8, e.y + 5, 14, e.col, 'left'); });
  }
};

// brake bias / traction control / ABS changes with the best lap times before and after (C-34 engine 8)
var SET_NAME = { dcBrakeBias: 'BRAKE BIAS', dcTractionControl: 'TRACTION CONTROL', dcABS: 'ABS' };
function setVal(ch, v) { return ch === 'dcBrakeBias' ? v.toFixed(2) + ' %' : 'setting ' + (Math.round(v) === v ? v.toFixed(0) : v.toFixed(1)); }
function SettingsList(box) {
  Display.call(this, box, 'Setting changes'); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'settings';
  var ch = D.deep.changes || [], list = el('div'), set = D.deep.settings || {};
  if (!ch.length) list.appendChild(el('div', 'sc', '<span class="mute">No changes</span>'));
  var maxRows = box.rows || 5;
  ch.slice(0, maxRows).forEach(function (c) {
    var res = c.delta == null ? '<span class="mute">too few clean laps</span>' : 'best of ' + c.before.length + ' laps before <b>' + fmt(c.bestBefore) + '</b> · after <b>' + fmt(c.bestAfter) + '</b> · <b class="' + (c.delta < 0 ? 'gain' : 'loss') + '">' + sgn(c.delta) + ' s</b>' + (c.pitBetween ? ' <span class="mute">· pit stop between</span>' : '');
    list.appendChild(el('div', 'sc', '<span class="tag">' + (SET_NAME[c.channel] || c.channel) + '</span><span class="gold">lap ' + (c.lap == null ? '–' : c.lap) + (c.atM != null ? ' · ' + (c.atM / 1000).toFixed(2) + ' km' : '') + '</span><span>' + setVal(c.channel, c.from) + ' → <b>' + setVal(c.channel, c.to) + '</b></span><span>' + res + '</span>'));
  });
  if (ch.length > maxRows) list.appendChild(el('div', 'keys', '+ ' + (ch.length - maxRows) + ' more'));
  this.stage.appendChild(list);
  this.stage.appendChild(el('div', 'keys', 'Start: brake bias <b>' + (set.dcBrakeBias != null ? set.dcBrakeBias.toFixed(2) + ' %' : '–') + '</b> · traction control <b>' + (set.dcTractionControl != null ? set.dcTractionControl : '–') + '</b> · ABS <b>' + (set.dcABS != null ? set.dcABS : '–') + '</b>'));
}
SettingsList.prototype = Object.create(Display.prototype);

// ---------- SUSPENSION: damper histograms per corner of the car, ride height / rake summary ----------
function histBins(key, kind) {
  var A = D.A.c[key], R = D.R ? shiftedRefLap().c[key] : null, lo = 1e9, hi = -1e9, i, arr, bw, nb;
  [A, R].forEach(function (a) { if (a) for (i = 0; i < D.n; i++) { if (a[i] < lo) lo = a[i]; if (a[i] > hi) hi = a[i]; } });
  if (kind === 'vel') { var m = Math.max(200, Math.ceil(Math.max(Math.abs(lo), Math.abs(hi)) / 100) * 100); lo = -m; hi = m; nb = 40; }
  else { bw = 2; lo = Math.floor(lo / bw) * bw; hi = Math.ceil(hi / bw) * bw; if (hi - lo < 20) hi = lo + 20; nb = Math.round((hi - lo) / bw); if (nb > 40) { nb = 40; } }
  bw = (hi - lo) / nb;
  var count = function (a) { var c = new Float32Array(nb); for (var k = 0; k < D.n; k++) { var b = Math.floor((a[k] - lo) / bw); c[clamp(b, 0, nb - 1)] += 100 / D.n; } return c; };
  return { lo: lo, hi: hi, nb: nb, bw: bw, a: count(A), r: R ? count(R) : null };
}
function Histo(box, w, kind) {
  Display.call(this, box, w + ' · ' + (kind === 'defl' ? 'damper position mm' : 'damper speed mm/s') + ' · % of the lap');
  this.kind = 'histo'; this.hk = kind; this.wheel = w; this.keys = el('div', 'keys'); this.el.appendChild(this.keys);
}
Histo.prototype = Object.create(Display.prototype);
Histo.prototype.drawStatic = function () {
  var g = this.cs, self = this, w = this.box.w, h = this.box.h, key = (this.hk === 'defl' ? 'defl' : 'vel') + this.wheel, H = this.H = histBins(key, this.hk), A = D.A.c[key], R = D.R ? shiftedRefLap().c[key] : null; this.clear(g); this.tbS = [];
  var X0 = 46, X1 = w - 6, Y0 = 6, Y1 = h - 26, ymax = 0, k;
  for (k = 0; k < H.nb; k++) ymax = Math.max(ymax, H.a[k], H.r ? H.r[k] : 0);
  ymax = Math.max(1, Math.ceil(ymax / 5) * 5);
  var bx = function (b) { return X0 + b / H.nb * (X1 - X0); }, by = function (v) { return Y1 - v / ymax * (Y1 - Y0); };
  g.strokeStyle = '#17171a'; g.lineWidth = 1; g.beginPath(); g.moveTo(X0, Math.round(by(ymax)) + 0.5); g.lineTo(X1, Math.round(by(ymax)) + 0.5); g.stroke();
  g.strokeStyle = C.line; g.beginPath(); g.moveTo(X0, Y1 + 0.5); g.lineTo(X1, Y1 + 0.5); g.stroke();
  g.fillStyle = 'rgba(242,194,48,.78)'; for (k = 0; k < H.nb; k++) if (H.a[k] > 0) g.fillRect(bx(k) + 0.5, by(H.a[k]), Math.max(1, bx(k + 1) - bx(k) - 1), Y1 - by(H.a[k]));
  if (H.r) { g.strokeStyle = C.ref; g.lineWidth = 1.4; g.setLineDash([]); g.beginPath(); for (k = 0; k < H.nb; k++) { var yy = by(H.r[k]); if (k) { g.lineTo(bx(k), by(H.r[k - 1])); g.lineTo(bx(k), yy); } else g.moveTo(bx(k), yy); g.lineTo(bx(k + 1), yy); } g.stroke(); }
  this.text(g, this.tbS, ymax.toFixed(0) + ' %', 0, Y0 + 13, 14, C.dim, 'left');
  var lab = function (v) { return (v < 0 ? '−' : '') + Math.abs(v).toFixed(0); };
  this.text(g, this.tbS, lab(H.lo), X0, h - 6, 14, C.dim, 'left'); this.text(g, this.tbS, lab(H.hi), X1, h - 6, 14, C.dim, 'right');
  if (this.hk === 'vel') { var z = bx(H.nb / 2); g.strokeStyle = '#3a3a40'; g.beginPath(); g.moveTo(z + 0.5, Y0); g.lineTo(z + 0.5, Y1); g.stroke(); this.text(g, this.tbS, '0', z, h - 6, 14, C.dim, 'center'); }
  var mm = function (a) { var lo = 1e9, hi = -1e9; for (var i = 0; i < D.n; i++) { if (a[i] < lo) lo = a[i]; if (a[i] > hi) hi = a[i]; } return [lo, hi]; }, ma = mm(A), mr = R ? mm(R) : null;
  this.keys.innerHTML = this.hk === 'defl' ? 'travel <b>' + ma[0].toFixed(0) + ' to ' + ma[1].toFixed(0) + ' mm</b>' + (mr ? ' · ref ' + mr[0].toFixed(0) + ' to ' + mr[1].toFixed(0) : '')
    : 'bump peak <b>' + ma[1].toFixed(0) + '</b> · rebound peak <b>' + lab(ma[0]) + '</b> mm/s' + (mr ? ' · ref ' + mr[1].toFixed(0) + ' / ' + lab(mr[0]) : '');
};
// The lowest ride height of one lap per wheel and where it happened, from the file's own 60 Hz records (C-41c): the engine sends them in
// /analysis/deep (laps[].lowRide for the lap, refLowRide for the reference). The 1 m grid misses a dip one record wide (lap 7, RF: raw -1.09 mm,
// grid 1.01 mm). null when the reply has no such field (an older irdash) or not all four wheels: the grid is used then, as before.
function rawLow(isRef) {
  var dp = D.deep, s = null, lap = D.head.lap.lap;
  if (!dp) return null;
  if (isRef) s = dp.refLowRide || null;
  else (dp.laps || []).forEach(function (l) { if (l.lap === lap && l.lowRide && (!s || l.clean)) s = l.lowRide; });
  return s && WHEELS.every(function (w) { return s[w] && isFinite(s[w].mm) && isFinite(s[w].atM); }) ? s : null;
}
// average and lowest ride height, rake, and the corner where each wheel's lowest ride height happened (a fact of the file; the
// channel's zero is not proven to be the floor, so nothing here claims floor contact and no threshold is applied)
function RideStrip(box) {
  Display.call(this, box, 'Ride height · average and lowest mm');
  this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'ridestrip';
  var A = D.A, R = D.R, aligned = R ? shiftedRefLap() : null, hasR = !!R, cell = function (key, f, dec) { var a = f(A.c[key]), r = aligned ? f(aligned.c[key]) : null; return pairCell(a, r, dec, hasR); };
  var avg = function (a) { var s = 0; for (var i = 0; i < D.n; i++) s += a[i]; return s / D.n; }, low = function (a) { var m = 1e9; for (var i = 0; i < D.n; i++) if (a[i] < m) m = a[i]; return m; };
  var raw = [rawLow(false), S.offsetM === 0 ? rawLow(true) : null];        // raw minima are lap-wide and only match at zero offset
  var lowMm = function (w) { var a = raw[0] ? raw[0][w].mm : low(A.c['ride' + w]), r = aligned ? (raw[1] ? raw[1][w].mm : low(aligned.c['ride' + w])) : null; return pairCell(a, r, 1, hasR); };
  // where the lowest value of the lap is: the corner it is in (its turn name), else the distance
  var lowAt = function (isRef, w) {
    var m, set = raw[isRef ? 1 : 0];
    if (set) m = set[w].atM;
    else { var a = (isRef ? aligned : A).c['ride' + w], at = 0; for (var i = 1; i < D.n; i++) if (a[i] < a[at]) at = i; m = at * D.step; }
    var c = cornerAt(Math.round(m / D.step)); return c ? c.label : (m / 1000).toFixed(2) + ' km';
  };
  var cols = WHEELS.concat(['rake']), t = el('table', 'ct rs');
  t.innerHTML = '<tr><th></th>' + WHEELS.map(function (w) { return '<th>' + w + '</th>'; }).join('') + '<th>RAKE</th></tr>' +
    '<tr><td class="n">AVERAGE mm</td>' + cols.map(function (w) { return '<td>' + cell(w === 'rake' ? 'rake' : 'ride' + w, avg, 1) + '</td>'; }).join('') + '</tr>' +
    '<tr><td class="n">LOWEST mm</td>' + WHEELS.map(function (w) { return '<td>' + lowMm(w) + '</td>'; }).join('') + '<td></td></tr>' +
    '<tr><td class="n">LOWEST AT</td>' + WHEELS.map(function (w) { return '<td>' + lowAt(false, w) + (R ? '<small>' + lowAt(true, w) + '</small>' : '') + '</td>'; }).join('') + '<td></td></tr>';
  this.stage.appendChild(t);
}
RideStrip.prototype = Object.create(Display.prototype);

// ---------- SPLITS: laps x iRacing sectors (purple / green / yellow), theoretical and rolling best, lap x corner heat map ----------
var EPS = 0.0005;
function splitData() {
  var ss = D.sess, ns = ss.sectorAt.length, rows = ss.laps.slice(), valid = rows.filter(function (l) { return l.valid && l.sectors && l.sectors.length === ns; });
  var bs = [], k;
  // the best sectors are joined only from counted laps with no off-track record at all (the server's bestSectors says so; the fallback does the same); none = no BEST row
  var pureL = valid.filter(function (l) { return !l.offTrack && l.skip !== 'off'; });
  for (k = 0; k < ns; k++) bs.push(ss.bestSectors ? ss.bestSectors[k] : ss.bestSectors === undefined && pureL.length ? Math.min.apply(null, pureL.map(function (l) { return l.sectors[k]; })) : NaN);
  var ever = ss.prev && ss.ever ? ss.ever : null;
  var turns = ss.turns || [], nt = turns.length, withT = valid.filter(function (l) { return l.cornerT && l.cornerT.length === nt; }), colMin = [], colSd = [];
  for (k = 0; k < nt; k++) {
    var v = withT.map(function (l) { return l.cornerT[k]; }), mean = v.reduce(function (a, b) { return a + b; }, 0) / (v.length || 1);
    colMin.push(v.length ? Math.min.apply(null, v) : null); colSd.push(v.length > 1 ? Math.sqrt(v.reduce(function (a, b) { return a + (b - mean) * (b - mean); }, 0) / v.length) : null);
  }
  var best = valid.length ? valid.reduce(function (a, l) { return l.time < a.time ? l : a; }, valid[0]) : null;
  // rolling best (Cosworth's "fastest rolling lap from any point"): 24 mini-sectors in a row, starting anywhere, over two consecutive valid laps
  var roll = null, byN = {}; valid.forEach(function (l) { if (l.mini && l.mini.length === 24) byN[l.n] = l; });
  valid.forEach(function (l) {
    var nx = byN[l.n + 1]; if (!byN[l.n] || !nx) return;
    for (var s = 1; s < 24; s++) { var t = 0, j; for (j = s; j < 24; j++) t += l.mini[j]; for (j = 0; j < s; j++) t += nx.mini[j]; if (!roll || t < roll.t) roll = { t: t, lap: l.n, s: s }; }
  });
  return { ns: ns, rows: rows, valid: valid, bs: bs, ever: ever, nt: nt, turns: turns, colMin: colMin, colSd: colSd, best: best, roll: roll, withT: withT };
}
function secClass(l, k, d) { return !l.valid ? 'sg' : (l.offTrack || l.skip === 'off') ? 'sy' : d.ever && l.sectors[k] <= Math.min(d.ever.sectors[k], d.bs[k]) + EPS ? 'sp' : l.sectors[k] <= d.bs[k] + EPS ? 'sn' : 'sy'; }
function heatColour(dt) { if (dt < 0.005) return 'rgba(60,207,126,.40)'; var a = Math.min(1, dt / 0.2); return 'rgba(229,83,75,' + (0.10 + 0.62 * a).toFixed(2) + ')'; }
function SplitsTable(box) {
  Display.call(this, box, 'Sectors and corners · <span class="purple">purple</span> best ever · <span class="gain">green</span> session best · <span style="color:#e8c547">yellow</span> slower'); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'splits';
  var d = this.d = splitData(), ss = D.sess, t = el('table', 'ct sp'), self = this, hasT = d.nt > 0 && d.withT.length > 0;
  // a long race: the latest 18 laps and the best lap
  var rows = d.rows.filter(function (l) { return l.time != null || l.flag; });
  if (rows.length > 20) { var keep = rows.slice(-19); if (d.best && keep.indexOf(d.best) < 0) keep.unshift(d.best); rows = keep.sort(function (a, b) { return a.n - b.n; }); }
  var cw = hasT ? Math.min(58, Math.floor(760 / d.nt)) : 0, head = '<tr><th>LAP</th><th class="tl">TIME</th>';
  for (var k = 0; k < d.ns; k++) head += '<th>S' + (k + 1) + '</th>';
  if (hasT) { head += '<th class="gapc"></th>'; d.turns.forEach(function (tn, i) { head += '<th class="hc" style="width:' + cw + 'px">' + (tn.official ? 'T' + tn.official : (tn.name || 'T' + tn.n).replace(/^The /, '')) + '</th>'; }); }
  t.innerHTML = head + '</tr>';
  rows.forEach(function (l) {
    var tr = el('tr', (d.best && l === d.best ? 'bestrow' : '') + (l.n === D.head.lap.lap ? ' on' : '')), h = '<td class="' + (l.valid ? '' : 'mute') + '">' + l.n + '</td><td class="tm ' + (l.valid ? '' : 'mute') + '">' + (l.time != null ? fmt(l.time) : '–') + (l.flag ? ' <i>' + l.flag + '</i>' : '') + '</td>';
    for (var k = 0; k < d.ns; k++) h += '<td class="' + (l.sectors && l.sectors.length === d.ns ? secClass(l, k, d) : 'sg') + '">' + (l.sectors && l.sectors.length === d.ns ? l.sectors[k].toFixed(3) : '') + '</td>';
    if (hasT) { h += '<td class="gapc"></td>'; for (var q = 0; q < d.nt; q++) { var ct = l.valid && l.cornerT && l.cornerT.length === d.nt ? l.cornerT[q] : null; h += ct == null || d.colMin[q] == null ? '<td class="hc"></td>' : '<td class="hc" style="background:' + heatColour(ct - d.colMin[q]) + '">' + (ct - d.colMin[q] < 0.005 ? 'best' : '+' + (ct - d.colMin[q]).toFixed(2)) + '</td>'; } }
    tr.innerHTML = h; if (l.valid && l.n !== D.head.lap.lap) tr.addEventListener('click', function () { openLap(l.n); }); t.appendChild(tr);
  });
  // best sectors joined = the theoretical lap; the corner columns show the best time through each corner and how much it varies
  // the BEST row: the best of every sector and the time those joined make (the theoretical lap); under the corners, the best time through each
  var optT = ss.optimal != null ? ss.optimal : null, fr = '<td class="lab">BEST</td><td class="tm">' + (optT != null ? fmt(optT) : '') + '</td>';
  var bestRow = { valid: true, sectors: d.bs };            // coloured by the same rule as the laps above: purple when it is also the best ever, else green
  for (k = 0; k < d.ns; k++) fr += '<td class="' + secClass(bestRow, k, d) + '">' + (isFinite(d.bs[k]) ? d.bs[k].toFixed(3) : '') + '</td>';      // no counted lap without an off-track record: nothing to join
  if (hasT) { fr += '<td class="gapc"></td>'; for (var q2 = 0; q2 < d.nt; q2++) fr += '<td class="hc mute">' + (d.colMin[q2] != null ? d.colMin[q2].toFixed(2) : '') + '</td>'; }
  var f1 = el('tr', 'foot'); f1.innerHTML = fr; t.appendChild(f1);
  if (hasT) {
    var sr = '<td class="lab" colspan="' + (2 + d.ns) + '">SPREAD ± s</td><td class="gapc"></td>';
    for (var q3 = 0; q3 < d.nt; q3++) sr += '<td class="hc">' + (d.colSd[q3] != null ? '±' + d.colSd[q3].toFixed(2) : '') + '</td>';
    var f2 = el('tr', 'foot'); f2.innerHTML = sr; t.appendChild(f2);
  }
  this.stage.appendChild(t);

}
SplitsTable.prototype = Object.create(Display.prototype);
function SplitNumbers(box, d) {
  Display.call(this, box, 'The numbers'); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'splitnums';
  var ss = D.sess, tile = function (lab, val, sub, cls) { return '<div class="nt"><div class="nl">' + lab + '</div><div class="nv ' + (cls || '') + '">' + val + '</div><div class="ns">' + sub + '</div></div>'; };
  var best = d.best, opt = ss.optimal, cons = ss.consistency, html = '';
  html += tile('BEST LAP', best ? fmt(best.time) : '–', best ? 'lap ' + best.n : '', 'gold');
  if (opt != null && best) html += tile('THEORETICAL BEST', fmt(opt), '<b class="gain">' + sgn(opt - best.time) + ' s</b>', 'purple');
  if (d.roll) html += tile('ROLLING BEST', fmt(d.roll.t), 'laps ' + d.roll.lap + ' to ' + (d.roll.lap + 1) + ' · from ' + (d.roll.s / 24 * D.L / 1000).toFixed(2) + ' km', '');
  if (cons) html += tile('BEST ' + cons.n + ' AVERAGE', fmt(cons.avg), 'spread <b>±' + cons.sd.toFixed(3) + ' s</b>', '');
  var nc = {}; ss.laps.forEach(function (l) { if (!l.valid) { var w = l.flag || '–'; nc[w] = (nc[w] || 0) + 1; } });     // the flag words on the rows above, counted
  html += tile('LAPS', d.valid.length + ' valid', (ss.laps.length - d.valid.length) + ' not counted' + (Object.keys(nc).length ? ': ' + Object.keys(nc).map(function (w) { return w + ' ' + nc[w]; }).join(' · ') : ''), '');
  var box2 = el('div', 'nts'); box2.innerHTML = html; this.stage.appendChild(box2);
}
SplitNumbers.prototype = Object.create(Display.prototype);

// ---------- trace rows he adds with the picker ----------
// The main trace stack of a page holds its own rows plus these; every row is squeezed (never below 44 px) so they all fit.
var STACKS = { driver: { h: 726, base: 7 }, braking: { h: 440, base: 3 }, suspension: { h: 346, base: 5 } };
function stackCap(page) { var s = STACKS[page]; return s ? Math.max(0, Math.floor((s.h - 30) / 60) - s.base) : 0; }   // how many extra rows fit at 44 px + 16 px spacing
function scaleRows(rows, boxH) {
  var n = rows.length, sum = 0; rows.forEach(function (r) { sum += r.h; });
  var avail = boxH - 30 - 16 * n, f = Math.min(1, avail / sum);
  var out = rows.map(function (r) { var o = {}; for (var q in r) o[q] = r[q]; if (f < 1) o.h = Math.max(44, Math.floor(r.h * f)); return o; });
  var tot = function () { return out.reduce(function (a, r) { return a + r.h; }, 0); };
  while (tot() > avail) { var big = out.reduce(function (m, r) { return r.h > m.h ? r : m; }, out[0]); if (big.h <= 44) break; big.h -= 2; }
  return out;
}
var DERIVED = [['latG', 'Lateral G', 'g', 2, 'LatAccel ÷ 9.81'], ['longG', 'Longitudinal G', 'g', 2, 'LongAccel ÷ 9.81'], ['gTot', 'G total', 'g', 2, '√(lateral² + long²)'], ['kmh', 'Speed', SPD_U, 0, 'Speed × ' + SPD_F.toFixed(SPD_MPH ? 3 : 1)],
  ['thrPct', 'Throttle', '%', 0, 'Throttle × 100'], ['brkPct', 'Brake', '%', 0, 'Brake × 100'], ['steerDeg', 'Steering angle', '°', 0, 'wheel angle, rad to °'],
  ['beta', 'Chassis slip angle', '°', 1, 'atan(VelocityY ÷ VelocityX)'], ['wfPct', 'Wheel force', '%', 0, 'wheel torque × 100'],
  ['slipLF', 'Wheel slip LF', '%', 1, 'wheel speed vs car speed'], ['slipRF', 'Wheel slip RF', '%', 1, 'wheel speed vs car speed'], ['slipLR', 'Wheel slip LR', '%', 1, 'wheel speed vs car speed'], ['slipRR', 'Wheel slip RR', '%', 1, 'wheel speed vs car speed'],
  ['rideLF', 'Ride height LF', 'mm', 1, 'RideHeight × 1000'], ['rideRF', 'Ride height RF', 'mm', 1, 'RideHeight × 1000'], ['rideLR', 'Ride height LR', 'mm', 1, 'RideHeight × 1000'], ['rideRR', 'Ride height RR', 'mm', 1, 'RideHeight × 1000'],
  ['rake', 'Rake', 'mm', 1, 'rear ride − front ride'],
  ['deflLF', 'Damper position LF', 'mm', 1, 'ShockDefl × 1000'], ['deflRF', 'Damper position RF', 'mm', 1, 'ShockDefl × 1000'], ['deflLR', 'Damper position LR', 'mm', 1, 'ShockDefl × 1000'], ['deflRR', 'Damper position RR', 'mm', 1, 'ShockDefl × 1000'],
  ['velLF', 'Damper speed LF', 'mm/s', 0, 'ShockVel × 1000'], ['velRF', 'Damper speed RF', 'mm/s', 0, 'ShockVel × 1000'], ['velLR', 'Damper speed LR', 'mm/s', 0, 'ShockVel × 1000'], ['velRR', 'Damper speed RR', 'mm/s', 0, 'ShockVel × 1000']];
var catList = null, xmeta = {};
function initials(s) { return s.split(/[^A-Za-z0-9]+/).filter(Boolean).map(function (w) { return w.charAt(0); }).join('').toLowerCase(); }
function catalog() {
  if (catList) return catList; catList = [];
  DERIVED.forEach(function (d) { if (D.A.c[d[0]]) catList.push({ key: d[0], name: d[0], label: d[1], unit: d[2], dec: d[3], formula: d[4], derived: true }); });
  (window.WB_CATALOG || []).forEach(function (r) { if (r[2] !== 1 || /^CarIdx/.test(r[0])) return; catList.push({ key: r[0], name: r[0], label: r[3] || r[0], unit: r[1], derived: false }); });
  catList.forEach(function (e) { e.ini = initials(e.label); e.low = e.label.toLowerCase(); e.lname = e.name.toLowerCase(); xmeta[e.key] = e; });
  return catList;
}
function escRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function score(e, q, qs) {
  var b = e.derived ? 5 : 0;
  if (e.ini === q) return 100 + b;
  if (e.ini.indexOf(q) === 0) return 90 - Math.min(20, e.ini.length - q.length) + b;
  if (e.low.indexOf(qs) === 0) return 80 + b;
  if (new RegExp('\\b' + escRe(qs)).test(e.low)) return 70 + b;
  if (e.low.indexOf(qs) >= 0) return 60;
  if (e.lname.indexOf(q) >= 0) return 50;
  return 0;
}
// initials first ('lg' = Lateral G), then words that start with the text, then anything that contains it
function searchChannels(text) {
  var qs = (text || '').toLowerCase().trim().replace(/\s+/g, ' '), q = qs.replace(/ /g, ''), list = catalog();
  if (!q) return list.filter(function (e) { return e.derived; }).slice(0, 10);
  return list.map(function (e) { return { e: e, s: score(e, q, qs) }; }).filter(function (x) { return x.s > 0; })
    .sort(function (a, b) { return b.s - a.s || (a.e.label < b.e.label ? -1 : 1); }).slice(0, 10).map(function (x) { return x.e; });
}
function extraRows() {
  var rng = D.rng || (D.rng = {}), ref = D.R ? shiftedRefLap() : null;
  return S.extra.filter(function (k) { return D.A.c[k]; }).map(function (k) {
    var e = xmeta[k] || { label: k, unit: '' }, lo = 1e9, hi = -1e9, i;
    if (!rng[k]) { [D.A.c[k], ref ? ref.c[k] : null].forEach(function (a) { if (a) for (i = 0; i < D.n; i++) { if (a[i] < lo) lo = a[i]; if (a[i] > hi) hi = a[i]; } }); rng[k] = [lo, hi]; }
    lo = rng[k][0]; hi = rng[k][1]; if (!(hi > lo)) hi = lo + 1;
    var span = hi - lo, pad = span * 0.08, d = e.dec != null ? e.dec : span >= 100 ? 0 : span >= 10 ? 1 : span >= 1 ? 2 : 3;
    var nm = e.label.toUpperCase(); if (nm.length > 18) nm = nm.slice(0, 17) + '…'; if (e.unit && nm.length + e.unit.length < 17) nm += ' ' + e.unit;
    return { k: nm, key: k, h: 70, lo: lo - pad, hi: hi + pad, d: d };
  });
}
function canExtra() { return stackCap(S.page) > 0; }
// the rows he added stay when he opens another lap (the page reloads): remembered in this browser, restored once the lap is in
function saveExtra() { try { localStorage.setItem('wbExtra', JSON.stringify(S.extra)); } catch (e) { } }
function restoreExtra() {
  var keys = []; try { keys = JSON.parse(localStorage.getItem('wbExtra') || '[]'); } catch (e) { }
  if (!Array.isArray(keys)) return Promise.resolve();
  catalog(); var chain = Promise.resolve();
  keys.slice(0, 4).forEach(function (k) {
    if (typeof k !== 'string' || !xmeta[k] || S.extra.indexOf(k) >= 0) return;
    chain = chain.then(function () { if (D.A.c[k]) { S.extra.push(k); return null; } return fetchExtra(k).then(function () { S.extra.push(k); }, function () { }); });
  });
  return chain.then(function () { if (S.extra.length) buildPage(); });
}
var picker = null;
function pickNote(s) { if (picker) picker.note.innerHTML = s || ''; }
function toggleChannel(e) {
  var i = S.extra.indexOf(e.key);
  if (i >= 0) { S.extra.splice(i, 1); saveExtra(); buildPage(); return Promise.resolve(true); }
  if (S.extra.length >= stackCap(S.page)) { pickNote('Page full'); return Promise.resolve(false); }
  if (D.A.c[e.key] && D.A.ok[e.key] !== false) { S.extra.push(e.key); saveExtra(); buildPage(); return Promise.resolve(true); }
  pickNote('Loading ' + e.label + '…');
  return fetchExtra(e.name).then(function () { S.extra.push(e.key); saveExtra(); buildPage(); return true; }, function (err) { pickNote(String(err.message || err)); return false; });
}
function fetchExtra(name) {
  var enc = encodeURIComponent, u = P.get('xdata') ? P.get('xdata').replace('{ch}', enc(name)) : '/analysis/channels?id=' + enc(P.get('id') || '') + '&lap=' + enc(P.get('lap') || '') + '&ref=' + enc(P.get('ref') || 'pb') + '&ch=' + enc(name);
  return fetchBuf(u).then(function (buf) {
    var r = readReply(buf), ch = r.head.channels[0];
    if (r.head.n !== D.n) throw new Error('Channel not loaded');
    if (!ch || !ch.ok) throw new Error('No "' + name + '" in this file');
    D.A.c[name] = r.arr['lap.' + name]; D.A.ok[name] = true;
    if (D.R && r.arr['ref.' + name]) { D.R.c[name] = r.arr['ref.' + name]; D.R.ok[name] = true; D.offsetRefCache = null; }
    D.rng = {};
  });
}
function buildPicker() {
  var box = el('div', 'picker'), inp = el('input'), list = el('div', 'pl'), note = el('div', 'pnote'), sel = 0, res = [];
  inp.type = 'text'; inp.placeholder = 'Search'; inp.spellcheck = false; inp.autocomplete = 'off';
  var pt = el('div', 'pt', ADDTXT), acts = el('div', 'pacts'), shut = el('button', 'pclose', 'Close');
  // a big way out that needs no keyboard (Peter 2026-10-15: the channel box could not be left)
  shut.type = 'button'; shut.addEventListener('mousedown', function (ev) { ev.preventDefault(); ev.stopPropagation(); closePicker(); });
  box.appendChild(shut); box.appendChild(pt); box.appendChild(inp); box.appendChild(list); box.appendChild(note); box.appendChild(acts);
  X.pickActs.forEach(function (a) { var b = el('span', 'pbtn', a.label + ' <i>' + a.hint + '</i>'); b.addEventListener('mousedown', function (ev) { ev.preventDefault(); if (res[sel]) { closePicker(); a.fn(res[sel]); } }); acts.appendChild(b); });
  document.body.appendChild(box);
  // a click anywhere outside the box closes it too
  document.addEventListener('mousedown', function (ev) { if (pickerOpen() && !box.contains(ev.target)) closePicker(); }, true);
  function render() {
    res = searchChannels(inp.value); if (sel >= res.length) sel = Math.max(0, res.length - 1); list.innerHTML = '';
    if (!res.length) list.appendChild(el('div', 'pr', '<span class="mute">No match</span>'));
    res.forEach(function (e, k) {
      var row = el('div', 'pr' + (k === sel ? ' on' : ''), '<span class="p1">' + e.label + '</span><span class="p2">' + (e.unit || '') + '</span><span class="p3">' + (e.formula || e.name) + '</span><span class="p4">' + (!picker.cb && S.extra.indexOf(e.key) >= 0 ? 'ON' : '') + '</span>');
      row.addEventListener('mousedown', function (ev) { ev.preventDefault(); sel = k; choose(e); });
      list.appendChild(row);
    });
  }
  function choose(e) { if (picker.cb) { var f = picker.cb; closePicker(); f(e); return; } toggleChannel(e).then(function (ok) { if (ok) closePicker(); else render(); }); }
  inp.addEventListener('input', function () { sel = 0; pickNote(''); render(); });
  inp.addEventListener('keydown', function (e) {
    e.stopPropagation();
    if (e.key === 'Escape') closePicker();
    else if (e.key === 'ArrowDown') { sel = Math.min(res.length - 1, sel + 1); render(); e.preventDefault(); }
    else if (e.key === 'ArrowUp') { sel = Math.max(0, sel - 1); render(); e.preventDefault(); }
    else if (e.key === 'Enter') { var act = !picker.cb ? (e.shiftKey ? X.pickActs[0] : e.ctrlKey ? X.pickActs[1] : null) : null; if (res[sel]) { if (act) { closePicker(); act.fn(res[sel]); } else choose(res[sel]); } e.preventDefault(); }
  });
  picker = { el: box, input: inp, render: render, note: note, choose: choose, pt: pt, acts: acts, cb: null };
}
// openPicker(cb, title): with a callback the picker just picks one channel and hands it over (workbench-pro.js: X, Y, colour, histogram); on any page then
var ADDTXT = 'Add a channel';
function openPicker(cb, title) {
  if (!D || (!cb && !canExtra())) return false;
  if (!picker) buildPicker();
  picker.cb = cb || null; picker.acts.style.display = cb || !X.pickActs.length ? 'none' : '';
  picker.pt.innerHTML = cb ? (title || 'Pick a channel') + ' · <b>Enter</b> picks · <b>Esc</b> closes' : ADDTXT;
  picker.el.className = 'picker on'; picker.input.value = ''; pickNote(''); picker.render(); picker.input.focus(); return true;
}
// a channel another file makes (a maths channel, a derived mean): searchable in every picker, and pickable as a trace row like the built-in derived ones
function addCatalog(e) {
  var list = catalog(); for (var i = list.length - 1; i >= 0; i--) if (list[i].key === e.key) list.splice(i, 1);
  e.name = e.name || e.key; e.ini = initials(e.label); e.low = e.label.toLowerCase(); e.lname = e.name.toLowerCase(); list.push(e); xmeta[e.key] = e;
}
function dropCatalog(key) { var list = catalog(); for (var i = list.length - 1; i >= 0; i--) if (list[i].key === key) list.splice(i, 1); delete xmeta[key]; }
function closePicker() { if (picker) { picker.el.className = 'picker'; picker.input.blur(); } }
function pickerOpen() { return !!picker && picker.el.className.indexOf('on') >= 0; }

// ---------- pages (presets, docs\DESIGN-workbench.md 3) ----------
function buildPage() {
  X.before.forEach(function (f) { f(); });                      // a video must leave the page before it is cleared
  document.getElementById('page').innerHTML = ''; displays = []; hooks = [];
  var R = D.R, mapTitle = function () { return 'Map · coloured by ' + (S.mapColour === 'gap' ? 'gap' : S.mapColour === 'speed' ? 'speed' : CAT[S.mapColour] ? CAT[S.mapColour].label : S.mapColour) + ' · ○ events'; };
  var xr = extraRows().slice(0, stackCap(S.page));              // rows he added (picker), as many as this page's stack can hold
  if (S.page === 'braking') {
    var bt = new BrakeTable({ x: 32, y: 126, w: 1060, h: 0 });
    new Traces({ x: 1124, y: 126, w: 764, h: 440 }, 'Brake · steering · speed · zoomed on the corner · both laps', scaleRows([
      { k: 'BRAKE % · ABS', key: 'brkPct', kind: 'brakeabs', h: 120, lo: 0, hi: 100 }, { k: 'STEERING °', key: 'steerDeg', h: 96, lo: -90, hi: 90 }, { k: 'SPEED ' + SPD_U.toUpperCase(), key: 'kmh', h: 96, lo: SPD_LO, hi: SPD_HI }].concat(xr), 440));
    var cy = Math.max(bt.el.getBoundingClientRect().bottom, 126 + 20 + 440) + 16;
    new BrakeCells({ x: 32, y: cy, w: 1856, h: 1056 - (cy + 20) });
  } else if (S.page === 'tyres') {
    var tp = new TyrePanel({ x: 32, y: 126, w: 928, h: 0 });
    new StintChart({ x: 992, y: 126, w: 896, h: 214 }, 'laps');
    new StintChart({ x: 992, y: 384, w: 896, h: 150 }, 'fuel');
    new StintChart({ x: 992, y: 578, w: 896, h: 214 }, 'temps');
    var sy = Math.max(tp.el.getBoundingClientRect().bottom, 578 + 20 + 214) + 26;
    new SettingsList({ x: 32, y: sy, w: 1856, h: 0, rows: Math.max(1, Math.min(5, Math.floor((1056 - sy - 20 - 44) / 40))) });
  } else if (S.page === 'suspension') {
    var A = D.A.c, R2 = D.R ? D.R.c : null, loK = 1e9, hiK = -1e9, i, all = [];
    for (i = 0; i < D.n; i += 2) WHEELS.forEach(function (w) { all.push(A['ride' + w][i]); if (R2) all.push(R2['ride' + w][i]); });
    for (i = 0; i < D.n; i++) { loK = Math.min(loK, A.rake[i], R2 ? R2.rake[i] : 1e9); hiK = Math.max(hiK, A.rake[i], R2 ? R2.rake[i] : -1e9); }
    all.sort(function (a, b) { return a - b; });
    var hiR = Math.max(40, Math.ceil(all[Math.floor(all.length * 0.995)] / 10) * 10);          // a kerb throws the ride height to 150 mm: the scale follows the lap, not the spike
    new Traces({ x: 32, y: 126, w: 1856, h: 346 }, 'Ride height and rake · mm · both laps', scaleRows(WHEELS.map(function (w) { return { k: 'RIDE ' + w + ' mm', key: 'ride' + w, h: 44, lo: 0, hi: hiR, d: 1 }; }).concat([{ k: 'RAKE mm', key: 'rake', h: 56, lo: Math.floor(loK / 5) * 5 - 5, hi: Math.ceil(hiK / 5) * 5 + 5, d: 1 }]), 346));
    WHEELS.forEach(function (w, k) {
      new Histo({ x: 32 + k * 468, y: 512, w: 452, h: 120 }, w, 'defl');
      new Histo({ x: 32 + k * 468, y: 700, w: 452, h: 120 }, w, 'vel');
    });
    new RideStrip({ x: 32, y: 888, w: 1856, h: 0 });
  } else if (S.page === 'splits') {
    var stb = new SplitsTable({ x: 32, y: 126, w: 1340, h: 0 });
    new SplitNumbers({ x: 1404, y: 126, w: 484, h: 0 }, stb.d);
  } else if (S.page === 'grip') {
    new GG({ x: 32, y: 126, w: 520, h: 520 });
    new Readouts({ x: 32, y: 724, w: 520, h: 0 }, ['kmh', 'Gear', 'thrPct', 'brkPct', 'steerDeg', 'latG', 'longG', 'beta']);
    new CornerTable({ x: 584, y: 126, w: 636, h: 0 });
    new EventList({ x: 584, y: 760, w: 636, h: 0 }, 5);
    new Traces({ x: 1252, y: 126, w: 636, h: 250 }, 'Slip angle °', [{ k: 'SLIP °', key: 'beta', h: 150, lo: -6, hi: 6, d: 1 }]);
    new Traces({ x: 1252, y: 404, w: 636, h: 330 }, 'Wheel slip % · below −8 locking · above +8 spinning', [
      { k: 'LF', key: 'slipLF', h: 52, lo: -20, hi: 20, ref: false }, { k: 'RF', key: 'slipRF', h: 52, lo: -20, hi: 20, ref: false },
      { k: 'LR', key: 'slipLR', h: 52, lo: -20, hi: 20, ref: false, col: C.rear }, { k: 'RR', key: 'slipRR', h: 52, lo: -20, hi: 20, ref: false, col: C.rear }]);
    new Gears({ x: 1252, y: 756, w: 636, h: 142 });
  } else if (X.pages[S.page]) {
    X.pages[S.page].build();
  } else {
    var map = new MapView({ x: 32, y: 126, w: 540, h: 330 }, mapTitle()); map.mapTitle = mapTitle;
    new Readouts({ x: 32, y: 478, w: 540, h: 0 }, ['kmh', 'Gear', 'RPM', 'thrPct', 'brkPct', 'steerDeg', 'latG', 'longG', 'beta', 'wfPct']);
    new Pedals({ x: 32, y: 884, w: 540, h: 48 });
    new Traces({ x: 600, y: 126, w: 1288, h: 726 }, '', scaleRows([
      { k: 'GAP s', kind: 'gap', h: 84, lo: -0.6, hi: 0.6 },
      { k: 'SPEED', key: 'kmh', h: 156, lo: SPD_LO, hi: SPD_HI },
      { k: 'THROTTLE %', key: 'thrPct', h: 62, lo: 0, hi: 100 },
      { k: 'BRAKE % · ABS', key: 'brkPct', kind: 'brakeabs', h: 76, lo: 0, hi: 100 },
      { k: 'STEERING °', key: 'steerDeg', h: 84, lo: -90, hi: 90 },
      { k: 'WHEEL FORCE %', key: 'wfPct', h: 54, lo: 0, hi: 100, ref: false, col: C.wf },
      { k: 'GEAR', key: 'Gear', h: 62, lo: 0.5, hi: 6.5 }].concat(xr), 726));
    new EventList({ x: 600, y: 866, w: 1288, h: 0 }, 4);
  }
  if (!R && !X.pages[S.page]) document.getElementById('page').appendChild(el('div', 'keys', 'No reference lap')).style.cssText = 'position:absolute;left:600px;top:106px';
  need.s = true; need.o = true;
  header();
  X.after.forEach(function (f) { f(); });
}

// Does a lap count, and what is the word on it? Once the session reply is in it is the Session Review's rule and its flag word (the same
// as SPLITS); before that, the lap store's own clean flag and skip word.
function sessLap(l) { var r = null; if (D.sess && D.sess.laps) D.sess.laps.forEach(function (x) { if (x.n === l.n) r = x; }); return r; }
function lapCounts(l) { var r = sessLap(l); return r ? !!r.valid : !!l.clean; }          // iRacing counted it (L-1): it can be "the best"
function lapOpen(l) { var r = sessLap(l); return r ? (r.timed != null ? !!r.timed : !!r.valid) : !!l.clean; }          // a real timed lap: can be opened and stepped to (counted or not)
function lapWord(l) { var r = sessLap(l); return r ? (r.flag || '') : (l.skip ? l.skip.toUpperCase() : ''); }
function header() {
  var h = D.head, A = h.lap, R = h.ref;
  var tabsEl = document.getElementById('tabs'), pgl = pages();
  // seven tabs plus the + CHANNEL and SMALL VIDEO chips would leave no room for the mode words (PLAY, ZOOM, OFFSET ...): the long names get the deck's short ones
  var many = pgl.length > 6, SHORT = { grip: 'GRIP', tyres: 'TYRES', suspension: 'SUSP.' };
  tabsEl.className = many ? 'tabs many' : 'tabs';
  tabsEl.innerHTML = pgl.map(function (p) { return '<span data-p="' + p.id + '" class="' + (S.page === p.id ? 'on' : '') + '">' + (many && SHORT[p.id] ? SHORT[p.id] : p.name) + '</span>'; }).join('');
  Array.prototype.forEach.call(document.querySelectorAll('#tabs span'), function (s) { s.addEventListener('click', function () { WB.cmd('page', s.getAttribute('data-p')); }); });
  var ac = document.getElementById('addch');                     // + CHANNEL only where the page has a trace stack with room (no dead button)
  if (ac) { ac.style.display = canExtra() ? '' : 'none'; if (!ac._on) { ac._on = true; ac.addEventListener('click', function () { openPicker(); }); } }
  var lp = document.getElementById('lapsbtn');
  if (!lp) { lp = el('div', 'addch', 'ADD LAPS'); lp.id = 'lapsbtn'; var top = document.querySelector('.top'); if (top && ac) top.insertBefore(lp, ac.nextSibling); }
  lp.style.display = h.laps && h.laps.some(function (l) { return l.clean && l.n !== A.lap; }) ? '' : 'none';
  if (!lp._on) { lp._on = true; lp.addEventListener('click', showLapPicker); }
  X.head.forEach(function (f) { f(); });
  var gap = R ? A.time - R.time : null;
  document.getElementById('vs').innerHTML = '<span><i class="sw"></i>LAP ' + A.lap + ' · ' + dateWord(A.date) + ' <b class="gold">' + fmt(A.time) + '</b></span>' +
    (R ? '<span><i class="sw r"></i>' + dateWord(R.date) + ' LAP ' + R.lap + ' <b class="ref">' + fmt(R.time) + '</b></span><span>GAP <b class="' + (gap < 0 ? 'gain' : 'loss') + '">' + sgn(gap) + '</b></span>' : D.M && D.M.length ? '<span class="mute">' + (D.M.length + 1) + ' LAPS</span>' : '<span class="mute">no reference yet</span>');
  var nav = document.getElementById('nav'); nav.innerHTML = '';
  // Every lap is shown the way SPLITS and the Session Review show it once the session reply is in: a lap that does not count is dim
  // and carries the same flag word (OUT, IN, PIT, OFF, INVALID). Before that reply (or without it) the lap store's own clean flag decides.
  var laps = h.laps.filter(function (l) { return l.time != null; }), tot = 0; laps.forEach(function (l) { tot += l.time; });
  var best = Math.min.apply(null, laps.filter(lapCounts).map(function (l) { return l.time; }));
  laps.forEach(function (l) {
    var d = el('div', (!lapCounts(l) ? 'out' : l.time === best ? 'pb' : '') + (l.n === A.lap ? ' on' : R && R.file === A.file && l.n === R.lap ? ' refl' : '')), fw = lapWord(l);
    d.setAttribute('data-lap', l.n);
    d.style.width = Math.max(40, l.time / tot * 1856 - 3) + 'px'; d.textContent = 'L' + l.n + '  ' + fmt(l.time) + (fw ? '  ' + fw : '');
    var mi = -1; (D.M || []).forEach(function (m, ix) { if (m.info.lap === l.n && m.info.file === A.file) mi = ix; });
    if (mi >= 0) { d.style.color = MULTI[mi]; d.style.borderColor = MULTI[mi]; }
    d.title = d.textContent;
    if (lapOpen(l) && l.n !== A.lap) d.addEventListener('click', function () { openLap(l.n); });
    nav.appendChild(d);
  });
  modeLine();
}
function showLapPicker() {
  var box = document.getElementById('lap-pick');
  if (!box) { box = el('div'); box.id = 'lap-pick'; box.style.cssText = 'display:none;position:absolute;z-index:22;left:32px;top:128px;width:520px;padding:12px;background:#121214;border:1px solid #5a4a14;grid-template-columns:repeat(3,1fr);gap:6px'; document.body.appendChild(box); }
  var open = box.style.display === 'grid'; box.innerHTML = ''; box.style.display = open ? 'none' : 'grid'; if (open) return;
  D.head.laps.filter(function (l) { return l.clean && l.time != null; }).forEach(function (l) {
    var key = (P.get('id') || '') + ':' + l.n, active = l.n === D.head.lap.lap, picked = S.selectedLaps.indexOf(key) >= 0;
    var item = el('div', '', 'L' + l.n + '  ' + fmt(l.time)); item.style.cssText = 'padding:9px;border:1px solid ' + (picked ? '#5a4a14' : '#26262a') + ';color:' + (active ? C.gold : picked ? C.gain : C.mute) + ';font-size:16px;cursor:pointer;white-space:nowrap';
    item.title = active ? 'OPEN LAP' : picked ? 'REMOVE LAP' : 'ADD LAP';
    if (!active) item.addEventListener('click', function () { var at = S.selectedLaps.indexOf(key); if (at >= 0) S.selectedLaps.splice(at, 1); else if (S.selectedLaps.length < 5) S.selectedLaps.push(key); else return; reloadSelectedLaps(); });
    box.appendChild(item);
  });
}
function reloadSelectedLaps() {
  if (!LIVE) return;
  var url = '/analysis/channels?id=' + encodeURIComponent(P.get('id') || '') + '&lap=' + encodeURIComponent(P.get('lap') || '') + '&ref=' + encodeURIComponent(P.get('ref') || 'pb') + '&ch=' + CHANS.join(',');
  if (S.selectedLaps.length) url += '&laps=' + encodeURIComponent(S.selectedLaps.join(','));
  fetchBuf(url).then(function (buf) { parse(buf); S.cur = clamp(S.cur, 0, D.n - 1); var box = document.getElementById('lap-pick'); if (box) box.style.display = 'none'; buildPage(); header(); }).catch(function (e) { var box = document.getElementById('lap-pick'); if (box) box.style.display = 'grid'; if (box) box.title = String(e.message || e); });
}
function modeLine() {
  var m = [];
  var c = D.head.conditions || {}, parts = [];
  if (c.airC != null) parts.push('Air ' + Number(c.airC).toFixed(0) + ' °C');
  if (c.trackC != null) parts.push('Track ' + Number(c.trackC).toFixed(0) + ' °C');
  if (c.windMs != null) parts.push('Wind ' + Number(c.windMs).toFixed(1) + ' m/s' + (c.windDirDeg != null ? ' ' + Math.round(Number(c.windDirDeg)) + '°' : ''));
  if (c.skies != null) parts.push('Skies ' + c.skies);
  if (c.wetness != null) parts.push('Wet ' + c.wetness);
  if (parts.length) m.push(parts.join(' · '));
  if (S.playing) m.push('PLAY <b>' + S.speed + '×</b>'); if (S.tile) m.push('TILE'); if (S.axis === 'time') m.push('TIME AXIS');
  if (D.R) m.push((S.offsetMode ? '<b>OFFSET MODE</b> · ' : '') + 'OFFSET <button class="offbtn" data-off="-1" aria-label="Offset minus one metre">−</button> <b>' + sgn(S.offsetM, 0) + ' m · ' + sgn(S.offsetS, 2) + ' s</b> <button class="offbtn" data-off="1" aria-label="Offset plus one metre">+</button>' + (S.autoResult === 'unavailable' ? ' · AUTO UNAVAILABLE' : ''));
  if (S.refCur != null) m.push('R CURSOR'); if (zoomed()) m.push('ZOOM <b>' + ((S.z1 - S.z0) * D.step / 1000).toFixed(2) + ' km</b>');
  document.getElementById('mode').innerHTML = m.join(' · ');
  Array.prototype.forEach.call(document.querySelectorAll('.offbtn'), function (b) { b.onclick = function () { WB.cmd('offset', b.getAttribute('data-off')); }; b.style.cssText = 'background:#121214;border:1px solid #5a4a14;color:#f2c230;font:inherit;font-size:16px;line-height:18px;width:28px;height:20px;padding:0;vertical-align:middle;cursor:pointer'; });
}
function openLap(n, ref) {
  if (!LIVE) return;                                     // a fixture is one lap; nothing to open
  var q = new URLSearchParams(location.search); q.set('lap', n); if (ref) q.set('ref', ref); q.set('page', S.page); location.search = q.toString();
}

// ---------- the frame loop: playback, then only what changed ----------
function frame(ts) {
  requestAnimationFrame(frame);
  if (!D) return;
  var dt = lastTs ? Math.min(0.1, (ts - lastTs) / 1000) : 0; lastTs = ts;
  if (S.playing && dt > 0 && !X.drives()) {                     // while a video is on screen it is the clock (workbench-video.js)
    var tNow = at(D.A.t, S.cur) + dt * S.speed * (S.reverse ? -1 : 1), ni = idxOf(D.A.t, clamp(tNow, at(D.A.t, 0), at(D.A.t, D.n - 1)));
    if (ni >= D.n - 1 || ni <= 0) { ni = ni >= D.n - 1 ? D.n - 1 : 0; S.playing = false; modeLine(); }
    S.cur = ni; need.o = true;
    if (zoomed() && (S.cur > S.z1 - (S.z1 - S.z0) * 0.02 || S.cur < S.z0)) { var w = S.z1 - S.z0; setZoom(S.cur - w * 0.2, S.cur + w * 0.8); }   // page the window on, not every frame
  }
  for (var xi = 0; xi < X.ticks.length; xi++) X.ticks[xi](ts, dt);
  if (!need.s && !need.o) return;
  var t0 = performance.now(), doS = need.s, doO = need.o; need.s = false; need.o = false;
  displays.forEach(function (d) { if (doS) d.drawStatic(); if (doS || doO) d.drawOverlay(); });
  hooks.forEach(function (h) { h(); });
  if (doS) modeLine(); else if (S.playing && (perf.frames & 15) === 0) modeLine();
  var ms = performance.now() - t0; perf.frames++; perf.total += ms; if (ms > perf.max) perf.max = ms; perf.last.push(ms); if (perf.last.length > 300) perf.last.shift();
}

// ---------- commands: keyboard, deck (/api/do?c=wb-<name>&a=<arg>) and tests all come through here ----------
var WB = window.WB = {
  state: S, data: function () { return D; },
  cmd: function (name, arg) {
    if (!D) return false;
    var a = arg == null ? '' : String(arg), i, c, k;
    switch (name) {
      case 'page': if (a) { S.page = pages().some(function (p) { return p.id === a; }) ? a : S.page; enterPage(); buildPage(); } break;
      case 'page-next': case 'page-prev': { var ids = pages().map(function (p) { return p.id; }); i = Math.max(0, ids.indexOf(S.page)); S.page = ids[(i + (name === 'page-next' ? 1 : ids.length - 1)) % ids.length]; enterPage(); buildPage(); break; }
      case 'lap-next': case 'lap-prev': { var cl = D.head.laps.filter(lapOpen).map(function (l) { return l.n; }); i = cl.indexOf(D.head.lap.lap); if (i < 0 || !cl.length) break; openLap(cl[(i + (name === 'lap-next' ? 1 : cl.length - 1)) % cl.length]); break; }
      case 'ref-cycle': { var opts = ['pb', 'session'].concat(D.head.laps.filter(function (l) { return l.clean && l.n !== D.head.lap.lap; }).map(function (l) { return D.head.lap.file + ':' + l.n; })); var cur = P.get('ref') || 'pb'; openLap(D.head.lap.lap, opts[(opts.indexOf(cur) + 1) % opts.length]); break; }
      case 'next-corner': case 'prev-corner': { var ci = Math.round(S.cur), list = D.corners.slice().sort(function (x, y) { return x.ia - y.ia; }); c = null;
        if (name === 'next-corner') { for (k = 0; k < list.length; k++) if (list[k].ia > ci + 2) { c = list[k]; break; } if (!c) c = list[0]; }
        else { for (k = list.length - 1; k >= 0; k--) if (list[k].ia < ci - 2) { c = list[k]; break; } if (!c) c = list[list.length - 1]; }
        if (!c) break; if (zoomed()) setZoom(c.i0 - 60 / D.step, c.i1 + 60 / D.step); setCursor(c.ia); break; }
      case 'next-event': case 'prev-event': { var ev = D.events, cj = Math.round(S.cur), e = null; if (!ev.length) break;
        if (name === 'next-event') { for (k = 0; k < ev.length; k++) if (ev[k].i > cj + 1) { e = ev[k]; break; } if (!e) e = ev[0]; } else { for (k = ev.length - 1; k >= 0; k--) if (ev[k].i < cj - 1) { e = ev[k]; break; } if (!e) e = ev[ev.length - 1]; }
        setCursor(e.i); break; }
      case 'play': S.playing = true; if (S.cur >= D.n - 2) S.cur = zoomed() ? S.z0 : 0; break;
      case 'pause': S.playing = false; break;
      case 'toggle-play': WB.cmd(S.playing ? 'pause' : 'play'); break;
      case 'speed': { var sp = [0.5, 1, 2, 4, 8]; S.speed = a ? (sp.indexOf(parseFloat(a)) >= 0 ? parseFloat(a) : S.speed) : sp[(sp.indexOf(S.speed) + 1) % sp.length]; break; }
      case 'reverse': S.reverse = a === '' ? !S.reverse : a === '1' || a === 'on' || a === 'true'; break;
      case 'zoom-in': zoomAt(0.5); break;
      case 'zoom-out': { var st = S.zoomStack.pop(); if (st) setZoom(st[0], st[1]); else zoomAt(2); break; }
      case 'zoom-reset': S.zoomStack = []; setZoom(0, D.n - 1); break;
      case 'zoom-corner': zoomCorner(cornerAt(Math.round(S.cur)) || cornerNear(S.cur)); break;
      case 'tile': S.tile = !S.tile; need.s = true; break;
      case 'offset': if (a === '' || a === 'toggle') S.offsetMode = !S.offsetMode; else if (a === '0' || a === 'reset') { S.offsetM = 0; S.offsetMode = false; } else S.offsetM += parseFloat(a) || 0; updateOffset(); break;
      case 'offset-auto': autoOffset(); break;
      case 'ref-cursor': S.refCur = S.refCur == null ? S.cur : null; need.s = true; break;
      case 'step': setCursor(S.cur + (parseFloat(a) || 1)); break;
      case 'cursor': setCursor(parseFloat(a) || 0); break;
      case 'axis': S.axis = a === 'time' || (a === '' && S.axis === 'dist') ? 'time' : 'dist'; need.s = true; break;
      case 'map-colour': S.mapColour = a || (S.mapColour === 'gap' ? 'speed' : 'gap'); displays.forEach(function (d) { if (d.mapTitle) d.ph.innerHTML = d.mapTitle(); }); need.s = true; break;
      default: if (X.cmds[name]) { X.cmds[name](a); break; } return false;
    }
    need.o = true; modeLine(); return true;
  },
  // for the tests: what the engine measured and where its text is
  perf: function () { var l = perf.last.slice().sort(function (a, b) { return a - b; }); return { frames: perf.frames, avgMs: perf.frames ? perf.total / perf.frames : 0, maxMs: perf.max, p95Ms: l.length ? l[Math.floor(l.length * 0.95)] : 0, recentAvgMs: l.length ? l.reduce(function (a, b) { return a + b; }, 0) / l.length : 0 }; },
  displays: function () { return displays; },
  bench: function (k, full) {
    // k synchronous frames: a cursor step each (overlay only), or with full=true a shifted zoom window (static + overlay);
    // the cursor and the window go back where they were
    var keep = [S.cur, S.z0, S.z1], t0 = performance.now(), i;
    if (full && !zoomed()) setZoom(0, (D.n - 1) / 2);
    for (i = 0; i < k; i++) {
      if (full) setZoom(S.z0 + 1, S.z1 + 1); else S.cur = (S.cur + 3) % (D.n - 1);
      displays.forEach(function (d) { if (full) d.drawStatic(); d.drawOverlay(); }); hooks.forEach(function (h) { h(); });
    }
    var ms = (performance.now() - t0) / k;
    S.cur = keep[0]; S.z0 = keep[1]; S.z1 = keep[2]; need.s = true; need.o = true;
    return ms;
  },
  textBoxes: function () { var out = []; displays.forEach(function (d) { out = out.concat(d.tbS, d.tbO); }); return out; },
  // every piece of text on the page (canvas and DOM) against every other: the pairs that overlap (should be none)
  overlaps: function () {
    var b = WB.textBoxes().concat(WB.domBoxes()), bad = [];
    for (var i = 0; i < b.length; i++) for (var j = i + 1; j < b.length; j++) {
      var p = b[i], q = b[j];
      if (p.x + 1 < q.x + q.w - 1 && q.x + 1 < p.x + p.w - 1 && p.y + 1 < q.y + q.h - 1 && q.y + 1 < p.y + p.h - 1) bad.push(p.s + ' | ' + q.s);
    }
    return { boxes: b.length, bad: bad };
  },
  domBoxes: function () {
    var out = [], all = document.body.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var e = all[i]; if (e.children.length || !e.textContent.trim() || e.tagName === 'SCRIPT' || e.tagName === 'STYLE' || e.tagName === 'CANVAS') continue;
      var r = e.getBoundingClientRect(); if (!r.width || !r.height) continue;
      var rg = document.createRange(); rg.selectNodeContents(e); var t = rg.getBoundingClientRect();
      var x0 = t.left, y0 = t.top, x1 = t.right, y1 = t.bottom;
      // text clipped by an overflow:hidden box (its own or an ancestor's) only counts where it is visible
      for (var p = e; p && p !== document.body; p = p.parentElement) {
        var cs = getComputedStyle(p); if (cs.overflow === 'hidden' || cs.overflowX === 'hidden') { var pr = p.getBoundingClientRect(); x0 = Math.max(x0, pr.left); y0 = Math.max(y0, pr.top); x1 = Math.min(x1, pr.right); y1 = Math.min(y1, pr.bottom); }
      }
      if (x1 > x0 && y1 > y0) out.push({ x: x0, y: y0, w: x1 - x0, h: y1 - y0, s: e.textContent.trim().substring(0, 40) });
    }
    return out;
  },
  pages: function () { return pages().map(function (p) { return p.id; }); },
  deck: function () { return deckState(); },
  search: function (t) { return searchChannels(t).map(function (e) { return e.label; }); },
  ready: false
};

document.addEventListener('keydown', function (e) {
  if (!D || e.ctrlKey || e.metaKey || e.altKey) return;
  var k = e.key, big = e.shiftKey ? 10 : 1, handled = true;
  switch (k) {
    case 'd': case 'D': WB.cmd('axis'); break;
    case 't': case 'T': WB.cmd('tile'); break;
    case 'z': case 'Z': WB.cmd('zoom-in'); break;
    case 'Backspace': WB.cmd('zoom-out'); break;
    case 'Escape': if (pickerOpen()) closePicker(); else WB.cmd('zoom-reset'); break;     // Esc closes the channel box first, wherever the focus is
    case 'r': case 'R': WB.cmd('ref-cursor'); break;
    case 'o': case 'O': WB.cmd('offset'); break;
    case 'a': case 'A': WB.cmd('offset-auto'); break;
    case 'm': case 'M': WB.cmd('map-colour'); break;
    case 's': WB.cmd('speed'); break; case 'S': WB.cmd('reverse'); break;
    case 'c': case 'C': WB.cmd('zoom-corner'); break;
    case ' ': WB.cmd('toggle-play'); break;
    case '[': WB.cmd('prev-corner'); break; case ']': WB.cmd('next-corner'); break;
    case ',': WB.cmd('prev-event'); break; case '.': WB.cmd('next-event'); break;
    case '+': case '=': WB.cmd('zoom-in'); break; case '-': case '_': WB.cmd('zoom-out'); break;
    case 'ArrowLeft': if (S.offsetMode) WB.cmd('offset', -big); else WB.cmd('step', -big); break;
    case 'ArrowRight': if (S.offsetMode) WB.cmd('offset', big); else WB.cmd('step', big); break;
    case 'ArrowUp': WB.cmd('page-prev'); break; case 'ArrowDown': WB.cmd('page-next'); break;
    case 'Home': WB.cmd('cursor', 0); break; case 'End': WB.cmd('cursor', D.n - 1); break;
    case '1': case '2': case '3': case '4': case '5': case '6': case '7': { var pl = pages(), pq = pl[parseInt(k, 10) - 1]; WB.cmd('page', pq ? pq.id : ''); break; }
    case '/': if (!openPicker()) handled = false; break;
    default: if (X.keys[k]) X.keys[k](); else handled = false;
  }
  if (handled) e.preventDefault();
});

// what the page tells the deck about itself (rides on the poll below; irdash keeps it for /workbench/state: dash\src\deckfeed.cs).
// A failure here must never stop the deck's commands from arriving, so it falls back to a report irdash ignores.
function deckState() {
  try { return deckReport(); } catch (e) { return 'x=1'; }
}
function deckReport() {
  var h = D.head, R = h.ref, q = [['pg', S.page], ['pgs', pages().map(function (p) { return p.id; }).join(',')], ['pl', S.playing ? 1 : 0], ['sp', S.speed], ['tl', S.tile ? 1 : 0],
    ['ax', S.axis], ['mc', S.mapColour], ['om', S.offsetMode ? 1 : 0], ['of', Math.round(S.offsetM == null ? (S.offset || 0) : S.offsetM)], ['z', zoomed() ? 1 : 0], ['id', P.get('id') || ''], ['lap', h.lap.lap],
    ['ref', P.get('ref') || 'pb'], ['nl', h.laps.filter(lapCounts).length], ['ne', D.events.length], ['nc', D.corners.length], ['lt', h.lap.time],
    ['rt', R ? R.time : ''], ['rl', R ? R.lap : ''], ['car', h.car || ''], ['trk', h.track || '']];
  return q.map(function (x) { return x[0] + '=' + encodeURIComponent(x[1]); }).join('&');
}
// the deck: irdash keeps the last wb-* command; run it once per new seq (the first poll only learns the seq)
function pollDeck() {
  var last = null;
  setInterval(function () {
    fetch('/workbench/cmd?' + deckState(), { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (j) {
      if (j.driving && S.playing) { S.playing = false; modeLine(); }      // never busy while he drives
      if (last !== null && j.seq !== last && j.cmd) WB.cmd(j.cmd, j.arg);
      last = j.seq;
    }).catch(function () {});
  }, 300);
}

function empty(msg) { document.getElementById('page').appendChild(el('div', 'empty', msg)); }

// fetch() refuses file: URLs, so a fixture on disk (the headless test) comes through XHR with --allow-file-access-from-files
function fetchBuf(url) {
  if (url.indexOf('file:') === 0) return new Promise(function (ok, bad) { var x = new XMLHttpRequest(); x.open('GET', url); x.responseType = 'arraybuffer'; x.onload = function () { ok(x.response); }; x.onerror = function () { bad(new Error('could not read ' + url)); }; x.send(); });
  return fetch(url, { cache: 'no-store' }).then(function (r) {
    if (r.status !== 200) return r.text().then(function (t) { var m = ''; try { m = JSON.parse(t).error; } catch (e) { m = t; } throw new Error(m || ('HTTP ' + r.status)); });
    return r.arrayBuffer();
  });
}
function fetchJson(url) { return fetchBuf(url).then(function (b) { return JSON.parse(new TextDecoder().decode(new Uint8Array(b))); }); }

// a page that needs the corner engines or the session reply: open on it (zoomed on a corner for BRAKING) once its data is there
function enterPage() {
  if (S.page !== 'braking' || zoomed()) return;
  // zoom on the braking zone at the cursor, or the nearest corner that has one (the cost-most corner may be flat out)
  var bc = brakeCorners().filter(function (c) { return dcOf(c).me.brake; }), at = cornerAt(Math.round(S.cur)), pick = bc.indexOf(at) >= 0 ? at : null;
  if (!pick) bc.forEach(function (c) { if (!pick || Math.abs(c.ia - S.cur) < Math.abs(pick.ia - S.cur)) pick = c; });
  zoomCorner(pick || at || cornerNear(S.cur));
}
// The deep-dive engines (/analysis/deep) and the session reply (/analysis/session) arrive after the lap itself, so DRIVER opens in under a
// second; BRAKING, TYRES & STINT and SPLITS get their tabs when their data is in (a failed or refused reply = no tab).
function loadExtras() {
  var enc = encodeURIComponent, id = P.get('id'), lap = P.get('lap'), ref = P.get('ref') || 'pb', du = P.get('deep'), su = P.get('session');
  if (!du && LIVE && id) du = '/analysis/deep?id=' + enc(id) + '&lap=' + enc(lap) + '&ref=' + enc(ref);
  if (!su && LIVE && id) su = '/analysis/session?id=' + enc(id) + '&lap=' + enc(lap) + '&corners=1';
  function one(url, set) { if (!url) return Promise.resolve(); return fetchJson(url).then(function (j) { if (j && !j.error) set(j); }).catch(function () {}); }
  return Promise.all([
    one(du, function (j) { D.deep = j; D.dc = {}; (j.corners || []).forEach(function (c) { D.dc[c.n] = c; }); }),
    one(su, function (j) { D.sess = j; })
  ].concat(X.loads.map(function (f) { return f(); }))).then(function () {
    var want = P.get('page');
    if (want && S.page !== want && avail(want)) { S.page = want; enterPage(); buildPage(); }
    else if (S.page === 'suspension') buildPage();       // opened before the deep reply: LOWEST mm / LOWEST AT use its raw minimums (builds the header too)
    else header();
    return restoreExtra();
  }).then(function () { WB.extras = true; });
}
function load() {
  var url = P.get('data');
  if (!url) {
    var id = P.get('id'), lap = P.get('lap');
    if (!id || !lap) { empty('No lap selected'); return; }
    url = '/analysis/channels?id=' + encodeURIComponent(id) + '&lap=' + encodeURIComponent(lap) + '&ref=' + encodeURIComponent(P.get('ref') || 'pb') + '&ch=' + CHANS.join(',') + (S.selectedLaps.length ? '&laps=' + encodeURIComponent(S.selectedLaps.join(',')) : '');
  }
  fetchBuf(url).then(function (buf) {
    parse(buf);
    S.z0 = 0; S.z1 = D.n - 1;
    var requestedCorner = parseInt(P.get('corner'), 10), requested = null;
    if (requestedCorner > 0) requested = D.corners.filter(function (c) { return c.n === requestedCorner; })[0] || null;
    S.cur = requested ? requested.ia : (D.worst ? D.worst.c.ia : 0); // DEEP DIVE may name a specific corner
    if (!avail(S.page)) S.page = 'driver';                    // a page whose data is not in yet (BRAKING ...) opens when it arrives
    buildPage();
    WB.ready = true;
    if (LIVE) pollDeck();
    loadExtras();
  }).catch(function (e) { empty(String(e.message || e)); WB.error = String(e.message || e); });
}
// what workbench-video.js (and any later page file) may use; loaded right after this file, before the first reply arrives
X.api = { S: S, C: C, FONT: FONT, P: P, LIVE: LIVE, need: need, el: el, clamp: clamp, at: at, idxOf: idxOf, fmt: fmt, sgn: sgn, num: num, dateWord: dateWord, CAT: CAT, SPD: { u: SPD_U, lo: SPD_LO, hi: SPD_HI, f: SPD_F },
  data: function () { return D; }, hook: function (f) { hooks.push(f); }, rIdx: rIdx, setCursor: setCursor, setZoom: setZoom, zoomed: zoomed, scaleRows: scaleRows, modeLine: modeLine,
  header: header, fetchJson: fetchJson, Display: Display, Traces: Traces, MapView: MapView,
  // for workbench-pro.js: the channel list and picker, loading any channel, the binary reply reader, a page rebuild
  catalog: catalog, search: searchChannels, meta: function (k) { catalog(); return xmeta[k] || null; }, fetchChannel: fetchExtra, openPicker: openPicker, closePicker: closePicker,
  addCatalog: addCatalog, dropCatalog: dropCatalog, readReply: readReply, fetchBuf: fetchBuf, rebuild: function () { buildPage(); } };
// W-18: OPEN IN COSWORTH on the top bar, only when Pi Toolbox is installed (the flag comes from /vault). One press opens the
// lap's telemetry file in Pi (irdash opens Pi's workbook first when Pi is cold, then forwards this file into it).
function addCosworth() {
  var id = P.get('id'); if (!id) return;
  var top = document.querySelector('.top'); if (!top) return;
  fetch('/vault', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (j) {
    if (!(j && j.cosworth && j.cosworth.installed) || !top.isConnected) return;
    var b = el('div', 'addch', 'OPEN IN COSWORTH'); b.id = 'cwbtn'; b.title = 'Open this lap in Cosworth Pi Toolbox';
    b.addEventListener('click', function () {
      b.textContent = 'OPENING';
      fetch('/vault/open?how=cosworth&id=' + encodeURIComponent(id), { cache: 'no-store' }).catch(function () { }).then(function () { b.textContent = 'OPEN IN COSWORTH'; });
    });
    var ref = document.getElementById('sharebtn') || document.getElementById('pipbtn') || document.getElementById('addch');
    if (ref && ref.parentNode) ref.parentNode.insertBefore(b, ref); else top.appendChild(b);
  }).catch(function () { });
}
addCosworth();
requestAnimationFrame(frame);
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', load); else load();      // after workbench-video.js has registered
})();
