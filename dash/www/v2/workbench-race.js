// Paddock Analysis Workbench - the RACE page (card W6, docs\DESIGN-workbench.md sections 2.5 and 3 "RACE").
// .ibt files only hold Peter's own car, so Paddock logs every car itself while a session with other cars runs (dash\src\field.cs). This page shows that log:
//   the final timing tower (position, number plate in the car's class colour, driver, car, team, laps, total / gap, gap to the car ahead, best lap, pits, incidents),
//   the race trace (seconds behind the class leader at the end of every lap, every car thin grey, Peter gold, the car ahead / behind and any car he clicks in white),
//   the position by lap, a table of Peter against the car ahead and the leader (time through every corner, median of the clean laps, + = Peter faster),
//   and the on-track passes of his race (lap, corner, who).
// All numbers come from /analysis/race (the server works them out; this file only lays them out). A tab exists only when the session has field data (no dead tab).
// Facts only, fixed colours (gold = Peter, cool white = the others he looks at, green = Peter gained, red = Peter lost), and the precision is stated on the page.
// The engine (workbench.js) reaches this file only through window.WBX.
(function () {
'use strict';
var X = window.WBX, WB = window.WB;
if (!X || !X.api || !WB) return;
var A = X.api, S = A.S, el = A.el, clamp = A.clamp, fmt = A.fmt, C = A.C, FONT = A.FONT;
var RS = { R: null, sm: null, by: {}, tw: {}, cm: {}, me: null, sel: null, hover: null, multi: false, p: {} };
var TOWER_PICS = true;                          // CP-1: iRacing's car picture beside each number plate. false = plates only (the header chips keep theirs)
var CAP = 24;                                   // rows the tower shows (more cars: the top ten and the cars around Peter)

function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
function tfmt(t) { if (t == null || !isFinite(t)) return '–'; if (t >= 3600) { var h = Math.floor(t / 3600), r = t - h * 3600, m = Math.floor(r / 60), s = r - m * 60; return h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s.toFixed(3); } return fmt(t); }
function plus(t) { if (t == null || !isFinite(t)) return '–'; if (t >= 60) { var m = Math.floor(t / 60), s = t - m * 60; return '+' + m + ':' + (s < 10 ? '0' : '') + s.toFixed(3); } return '+' + t.toFixed(3); }
function lapsWord(n) { return '+' + n + ' LAP' + (n === 1 ? '' : 'S'); }
function lum(hex) { var m = /^#([0-9a-f]{6})$/i.exec(hex || ''); if (!m) return 0.8; var v = parseInt(m[1], 16); return (0.299 * (v >> 16) + 0.587 * ((v >> 8) & 255) + 0.114 * (v & 255)) / 255; }
function plateHtml(c) { var col = c.col || '#d8d4ca'; return '<span class="plate" style="background:' + col + ';color:' + (lum(col) > 0.55 ? '#101010' : '#f4f1ea') + '">' + esc(c.num) + '</span>'; }
// P4: the car in the driver's own livery (cars.js; the log's CarPath + CarDesignStr, the class colour when an old log has no design)
// CP-1: iRacing's own picture of the car (carpics.js), nothing drawn; a car without a picture shows nothing
function carHtml(c, w) { return window.PCarPic && c ? PCarPic.html({ path: c.path, w: w, title: (c.car || '') + ' #' + (c.num || '') }) : ''; }
// the header chips: the winner (the leader while it runs, the quickest in a session that is not a race) and Peter, each with his car and place
function heroHtml() {
  var s = RS.sm, tw = s.tower || [], h = '', k, t0 = tw[0], me = null;
  if (!window.PCarPic || !t0) return '';
  for (k = 0; k < tw.length; k++) if (tw[k].i === RS.me) me = tw[k];
  var wc = RS.by[t0.i], word = !s.race ? 'QUICKEST' : RS.R.complete ? 'WINNER' : 'LEADER';
  if (wc) h += '<span class="rpc" data-i="' + t0.i + '"><span class="w">' + word + '</span>' + carHtml(wc, 54) + '<b class="ink">#' + esc(wc.num) + '</b> ' + esc(lastName(wc)) + '</span>';
  var mc = me ? RS.by[me.i] : null;
  if (mc && me.i !== t0.i) h += '<span class="rpc me" data-i="' + me.i + '"><span class="w">PETER</span>' + carHtml(mc, 54) + '<b>P' + me.pos + '</b></span>';
  else if (mc) h += '<span class="rpc me" data-i="' + me.i + '"><span class="w">PETER</span><b>P1</b></span>';
  return h ? '<span class="rph">' + h + '</span>' : '';
}
function who(i) { var c = RS.by[i]; return c ? '#' + esc(c.num) + ' ' + esc(c.name) : '#' + i; }
function who0(i) { var c = RS.by[i]; return c ? '#' + c.num + ' ' + c.name : '#' + i; }
function lastName(c) { var p = String(c.name || '').trim().split(/\s+/); return p.length > 1 ? p.slice(1).join(' ') : c.name; }
function stage() { var s = RS.sm; return s.race ? (RS.R.complete ? 'FINAL' : 'LIVE') : 'FIELD'; }

// ---------- the reply ----------
function prep(j) {
  RS.R = j; RS.sm = j.summary; RS.by = {}; RS.tw = {}; RS.cm = {}; RS.me = j.me; RS.sel = null; RS.hover = null;
  (j.cars || []).forEach(function (c) { RS.by[c.i] = c; });
  (RS.sm.tower || []).forEach(function (t) { RS.tw[t.i] = t; });
  (RS.sm.cm || []).forEach(function (m) { RS.cm[m.i] = m; });
  RS.multi = (RS.sm.classes || []).length > 1;
}
function usable() { var s = RS.sm; return !!(s && s.tower && s.tower.length >= 2 && s.tower.some(function (t) { return t.laps > 0; })); }
function loadRace() {
  var P = A.P, url = P.get('racedata'), id = P.get('race') || P.get('id');
  if (!url && A.LIVE && id) url = '/analysis/race?id=' + encodeURIComponent(id);
  if (!url) return Promise.resolve();
  return A.fetchJson(url).then(function (j) { if (j && !j.error && j.summary) prep(j); }).catch(function () { });      // no log for this session (404) = no tab
}
// who is shown in the charts and the compare table with a white line: Peter's neighbours at the end, and a car he clicked
function roles() {
  var r = {}, s = RS.sm; if (s.behind != null) r[s.behind] = 'behind'; if (s.ahead != null) r[s.ahead] = 'ahead'; if (RS.sel != null) r[RS.sel] = 'sel'; if (RS.me != null) r[RS.me] = 'me';
  return r;
}
function select(i) { if (i === RS.me) return; RS.sel = RS.sel === i ? null : i; refresh(); }
function refresh() {
  if (RS.p.tower) RS.p.tower.mark(); if (RS.p.cmp) RS.p.cmp.render(); if (RS.p.pass) RS.p.pass.mark();
  A.need.s = true; A.need.o = true;
}

// ---------- the final timing tower ----------
function visibleRows() {
  var tw = RS.sm.tower, n = tw.length, k;
  if (n <= CAP) { var all = []; for (k = 0; k < n; k++) all.push(k); return all; }
  var keep = {}, mi = -1; for (k = 0; k < n; k++) if (tw[k].i === RS.me) mi = k;
  for (k = 0; k < 8; k++) keep[k] = 1;
  if (mi >= 0) for (k = Math.max(0, mi - 5); k <= Math.min(n - 1, mi + 5); k++) keep[k] = 1;
  var idx = function () { var o = []; for (var q in keep) o.push(+q); return o.sort(function (a, b) { return a - b; }); };
  var size = function () { var o = idx(), s = o.length; for (var q = 1; q < o.length; q++) if (o[q] > o[q - 1] + 1) s++; if (o[o.length - 1] < n - 1) s++; return s; };    // rows and the "more cars" rows between them
  var next = 8; while (size() < CAP - 1 && next < n) { keep[next++] = 1; }
  return idx();
}function Tower(box) {
  A.Display.call(this, box, '');
  this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'racetower';
  var s = RS.sm, R = RS.R, self = this;
  var hero = heroHtml();
  this.ph.innerHTML = '<span class="rpt">' + (s.race ? 'Timing tower · ' : 'Best laps · ') + '<b>' + stage() + '</b> · ' + esc(R.sessName || R.sessType) + ' · ' + esc(R.track) + (s.race && s.maxLap ? ' · ' + s.maxLap + ' laps' : '') + '</span>' + hero;
  if (hero) this.ph.className += ' rph2';
  var tw = s.tower, team = tw.some(function (t) { var c = RS.by[t.i]; return c && c.team && c.team !== c.name; }), inc = tw.some(function (t) { return t.inc > 0; });
  var cols = [{ k: 'pos', h: 'P', w: 40 }];
  if (RS.multi) cols.push({ k: 'cls', h: 'CLS', w: 48 });
  var pics = TOWER_PICS && !!window.PCarPic && PCarPic.any(tw.map(function (t) { var c = RS.by[t.i]; return c && c.path; }));      // CP-1: room for the pictures only when some car has one
  cols.push({ k: 'no', h: 'NO', w: pics ? 132 : 66, l: 1 },{ k: 'name', h: 'DRIVER', f: 1.15, l: 1 }, { k: 'car', h: 'CAR', f: 1.0, l: 1 });
  if (team) cols.push({ k: 'team', h: 'TEAM', f: 0.85, l: 1 });
  cols.push({ k: 'laps', h: 'LAPS', w: 54 }, { k: 'gap', h: s.race ? 'TOTAL / GAP' : 'BEST / GAP', w: 124 }, { k: 'ahead', h: 'AHEAD', w: 94 }, { k: 'best', h: 'BEST LAP', w: 102 }, { k: 'pits', h: 'PITS', w: 104 });
  if (inc) cols.push({ k: 'inc', h: 'INC', w: 46 });
  var fixed = 0, flex = 0; cols.forEach(function (c) { if (c.w) fixed += c.w; else flex += c.f; });
  cols.forEach(function (c) { if (!c.w) c.w = Math.floor((box.w - fixed) * c.f / flex); });
  this.cols = cols;
  var vis = visibleRows(), gaps = 0; vis.forEach(function (k, q) { if (q > 0 && k > vis[q - 1] + 1) gaps++; }); if (vis[vis.length - 1] < tw.length - 1) gaps++;
  var rh = clamp(Math.floor(674 / (vis.length + gaps)), 26, 34);
  var t = el('table', 'rt'); t.style.fontSize = rh < 30 ? '17px' : '18px';
  var h = '<colgroup>' + cols.map(function (c) { return '<col style="width:' + c.w + 'px">'; }).join('') + '</colgroup><thead><tr>' + cols.map(function (c) { return '<th' + (c.l ? ' class="l"' : '') + '>' + c.h + '</th>'; }).join('') + '</tr></thead><tbody>';
  var prev = -1;
  vis.forEach(function (k) {
    if (prev >= 0 && k > prev + 1) h += '<tr class="skip" style="height:' + rh + 'px"><td colspan="' + cols.length + '">' + (k - prev - 1) + ' more cars</td></tr>';
    prev = k;
    var r = tw[k], c = RS.by[r.i] || {}, cells = '';
    cols.forEach(function (cc) { cells += '<td class="' + (cc.l ? 'l ' : '') + cc.k + '">' + self.cell(cc.k, r, c) + '</td>'; });
    h += '<tr data-i="' + r.i + '" style="height:' + rh + 'px">' + cells + '</tr>';
  });
  if (prev >= 0 && prev < tw.length - 1) h += '<tr class="skip" style="height:' + rh + 'px"><td colspan="' + cols.length + '">' + (tw.length - 1 - prev) + ' more cars</td></tr>';
  t.innerHTML = h + '</tbody>';
  this.stage.appendChild(t); this.table = t; this.rh = rh;
  Array.prototype.forEach.call(t.querySelectorAll('tbody tr[data-i]'), function (tr) { tr.addEventListener('click', function () { select(+tr.getAttribute('data-i')); }); });
  this.mark();
}
Tower.prototype = Object.create(A.Display.prototype);
Tower.prototype.cell = function (k, r, c) {
  var s = RS.sm;
  switch (k) {
    case 'pos': return r.pos;
    case 'cls': return r.cpos;
    case 'no': return plateHtml(c) + (TOWER_PICS ? carHtml(c, 64) : '');
    case 'name': return esc(c.name);
    case 'car': return esc(c.car);
    case 'team': return esc(c.team && c.team !== c.name ? c.team : '');
    case 'laps': return r.laps;
    case 'gap':
      if (!s.race) return r.cpos === 1 ? (r.best != null ? fmt(r.best) : '–') : (r.gap != null ? plus(r.gap) : '–');
      if (r.out) return '<span class="mute">OUT</span>' + (r.gapLaps > 0 ? '' : '');
      if (r.cpos === 1) return r.total != null ? tfmt(r.total) : '–';
      return r.gapLaps > 0 ? lapsWord(r.gapLaps) : plus(r.gap);
    case 'ahead':
      if (r.cpos === 1) return '<span class="mute">–</span>';
      return r.aheadLaps > 0 ? lapsWord(r.aheadLaps) : plus(r.ahead);
    case 'best': return r.best != null ? '<span class="' + (r.fastest ? 'gain' : '') + '">' + fmt(r.best) + '</span>' : '–';
    case 'pits': return r.pits > 0 ? r.pits + ' · ' + (r.pitLane != null ? r.pitLane.toFixed(1) : '–') + ' s' : '<span class="mute">–</span>';
    case 'inc': return r.inc > 0 ? r.inc : '<span class="mute">0</span>';
  }
  return '';
};
Tower.prototype.mark = function () {
  var ro = roles(); Array.prototype.forEach.call(this.table.querySelectorAll('tbody tr[data-i]'), function (tr) { var i = +tr.getAttribute('data-i'), r = ro[i]; tr.className = r === 'me' ? 'me' : r === 'sel' ? 'sel' : r === 'ahead' || r === 'behind' ? 'near' : ''; });
};

// ---------- the race trace and the position chart ----------
function nice(v) { var st = [5, 10, 20, 30, 40, 60, 90, 120, 180, 240, 300, 600, 900, 1200, 1800]; for (var i = 0; i < st.length; i++) if (v <= st[i]) return st[i]; return Math.ceil(v / 600) * 600; }
function Chart(box, k) {
  A.Display.call(this, box, k === 'trace' ? 'Race trace · seconds behind the leader at the end of each lap' : 'Position at the end of each lap');
  this.kind = 'race' + k; this.k = k; this.pad = { l: 54, r: 104, t: 10, b: 28 };
  var self = this;
  this.stage.addEventListener('mousemove', function (e) { var p = self.local(e), lap = self.lapAt(p[0]); if (lap !== RS.hover) { RS.hover = lap; A.need.o = true; } });
  this.stage.addEventListener('mouseleave', function () { RS.hover = null; A.need.o = true; });
}
Chart.prototype = Object.create(A.Display.prototype);
Chart.prototype.geom = function () {
  var s = RS.sm, p = this.pad, n = Math.max(2, s.maxLap), W = this.box.w - p.l - p.r, H = this.box.h - p.t - p.b, top = p.t, g = { n: n, W: W, H: H, l: p.l, t: top };
  g.X = function (lap) { return p.l + (lap - 1) / (n - 1) * W; };
  if (this.k === 'trace') {
    var best = 0; s.trace.forEach(function (r) { var t = RS.tw[r.i]; if (t && t.laps === s.maxLap) r.g.forEach(function (v) { if (v != null && v > best) best = v; }); });
    var raw = Math.max(4, best * 1.06), step = [1, 2, 5, 10, 15, 20, 30, 60, 120, 300].filter(function (q) { return raw / q <= 6; })[0] || 600;
    g.ymax = Math.ceil(raw / step) * step; g.step = step;
    g.Y = function (v) { return top + v / g.ymax * H; };
  } else {
    var cars = Math.max(2, s.trace.length); g.cars = cars; g.step = cars <= 12 ? 1 : cars <= 24 ? 2 : 5;
    g.Y = function (pos) { return top + (pos - 1) / (cars - 1) * H; };
  }
  return g;
};
Chart.prototype.lapAt = function (x) { var g = this.geom(), s = RS.sm; if (x < g.l - 12 || x > g.l + g.W + 12) return null; return clamp(Math.round(1 + (x - g.l) / g.W * (g.n - 1)), 1, s.maxLap); };
Chart.prototype.value = function (r, lap) { return this.k === 'trace' ? r.g[lap - 1] : r.p[lap - 1]; };
// where a car's point on a lap is (canvas pixels) - the test reads the colour there
Chart.prototype.point = function (idx, lap) {
  var g = this.geom(), r = RS.sm.trace.filter(function (q) { return q.i === idx; })[0]; if (!r) return null;
  var v = this.value(r, lap); if (v == null) return null; return { x: g.X(lap), y: g.Y(v) };
};
Chart.prototype.drawStatic = function () {
  var g = this.cs, s = RS.sm, G = this.geom(), self = this, ro = roles(), n = s.maxLap, p = this.pad; this.clear(g); this.tbS = [];
  g.lineWidth = 1; g.strokeStyle = C.line; g.fillStyle = C.mute;
  // grid and the numbers on the left
  if (this.k === 'trace') for (var v = 0; v <= G.ymax + 1e-9; v += G.step) { var y = Math.round(G.Y(v)) + 0.5; g.beginPath(); g.moveTo(G.l, y); g.lineTo(G.l + G.W, y); g.stroke(); this.text(g, this.tbS, String(v), G.l - 8, y + 5, 14, C.mute, 'right'); }
  else for (var q = 1; q <= G.cars; q++) if (G.cars <= 8 || q === 1 || q % 5 === 0 || (q === G.cars && G.cars % 5 > 2)) { var y2 = Math.round(G.Y(q)) + 0.5; g.beginPath(); g.moveTo(G.l, y2); g.lineTo(G.l + G.W, y2); g.stroke(); this.text(g, this.tbS, 'P' + q, G.l - 8, y2 + 5, 14, C.mute, 'right'); }
  var stride = Math.max(1, Math.ceil(n / 14));
  for (var lap = 1; lap <= n; lap++) { var x = Math.round(G.X(lap)) + 0.5; g.strokeStyle = '#17171a'; g.beginPath(); g.moveTo(x, G.t); g.lineTo(x, G.t + G.H); g.stroke(); if ((lap - 1) % stride === 0 || lap === n) this.text(g, this.tbS, String(lap), x, G.t + G.H + 20, 14, C.mute, 'center'); }
  // the lines: everyone in thin grey, then the cars he looks at, Peter last
  g.save(); g.beginPath(); g.rect(G.l - 1, G.t - 2, G.W + 2, G.H + 4); g.clip(); g.lineJoin = 'round';
  var order = s.trace.slice().sort(function (a, b) { var w = { me: 3, sel: 2, ahead: 1, behind: 1 }; return (w[ro[a.i]] || 0) - (w[ro[b.i]] || 0); });
  var ends = [];
  order.forEach(function (r) {
    var role = ro[r.i]; g.setLineDash(role === 'ahead' ? [2, 3] : role === 'behind' ? [8, 4] : []);
    g.lineWidth = role === 'me' ? 2.8 : role ? 1.8 : 1.2; g.strokeStyle = role === 'me' ? C.gold : role ? C.ref : '#6a6a72';
    g.beginPath(); var on = false, lastX = 0, lastY = 0, lastLap = 0;
    for (var l2 = 1; l2 <= n; l2++) { var val = self.value(r, l2); if (val == null) { on = false; continue; } var px = G.X(l2), py = G.Y(val); if (!on) { g.moveTo(px, py); on = true; } else g.lineTo(px, py); lastX = px; lastY = py; lastLap = l2; }
    g.stroke(); g.setLineDash([]);
    if (role && lastLap) ends.push({ r: r, role: role, x: lastX, y: lastY, lap: lastLap });
  });
  if (this.k === 'trace') {                                         // a ring on every lap Peter drove into the pits
    var me = s.trace.filter(function (r) { return r.i === RS.me; })[0];
    if (me) { g.strokeStyle = C.gold; g.lineWidth = 2; [].concat(me.pit || []).forEach(function (lap) { var val = me.g[lap - 1]; if (val == null) return; g.beginPath(); g.arc(G.X(lap), G.Y(val), 6, 0, 6.2832); g.stroke(); }); }
  }
  g.restore();
  // who is who, at the end of the lines (never on top of each other)
  var lab = ends.map(function (e) {
    var c = RS.by[e.r.i], word = e.role === 'me' ? '' : e.role === 'ahead' ? ' AHEAD' : e.role === 'behind' ? ' BEHIND' : '', yy = clamp(e.y, G.t + 6, G.t + G.H);
    return { y: yy, text: '#' + (c ? c.num : e.r.i) + word, col: e.role === 'me' ? C.gold : C.ref, x: e.x };
  }).sort(function (a, b) { return a.y - b.y; });
  for (var i = 1; i < lab.length; i++) if (lab[i].y - lab[i - 1].y < 17) lab[i].y = lab[i - 1].y + 17;
  for (var i2 = lab.length - 2; i2 >= 0; i2--) if (lab[i2].y > G.t + G.H) lab[i2].y = G.t + G.H;
  lab.forEach(function (L) { self.text(g, self.tbS, L.text, Math.min(L.x, G.l + G.W) + 8, L.y + 5, 14, L.col, 'left'); });
};
Chart.prototype.drawOverlay = function () {
  var g = this.co, G = this.geom(), s = RS.sm; this.clear(g); this.tbO = [];
  if (RS.hover == null) return;
  var lap = RS.hover, x = Math.round(G.X(lap)) + 0.5; g.strokeStyle = 'rgba(242,194,48,.55)'; g.lineWidth = 1; g.beginPath(); g.moveTo(x, G.t); g.lineTo(x, G.t + G.H); g.stroke();
  var me = s.trace.filter(function (r) { return r.i === RS.me; })[0], v = me ? this.value(me, lap) : null;
  var txt = 'LAP ' + lap + (v == null ? '' : this.k === 'trace' ? ' · ' + (v === 0 ? 'LEADING' : '+' + v.toFixed(3) + ' s') : ' · P' + v);
  g.font = '15px ' + FONT; var w = g.measureText(txt).width + 16, bx = G.l + 10, by = G.t + 4;
  g.fillStyle = 'rgba(11,11,12,.92)'; g.fillRect(bx, by, w, 22); this.text(g, this.tbO, txt, bx + 8, by + 17, 15, C.gold, 'left');
  if (me && v != null) { g.fillStyle = C.gold; g.beginPath(); g.arc(G.X(lap), G.Y(v), 4.5, 0, 6.2832); g.fill(); }
};

// ---------- Peter against the car ahead and the leader ----------
function Compare(box) {
  A.Display.call(this, box, '');
  this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'racecompare';
  this.ph.innerHTML = 'Peter vs the car ahead and the leader · seconds per corner · <b>+ Peter faster</b> · <span class="r">median of clean laps</span>';
  this.body = el('div'); this.stage.appendChild(this.body); this.render();
}
Compare.prototype = Object.create(A.Display.prototype);
Compare.prototype.render = function () {
  var s = RS.sm, R = RS.R, me = RS.me, cm = RS.cm[me], cs = R.corners || [], b = this.body;
  if (me == null || !RS.tw[me]) { b.innerHTML = '<div class="tnote">Peter is not in this field.</div>'; return; }
  if (!cm) { b.innerHTML = '<div class="tnote">Needs 3 clean laps</div>'; return; }
  var targets = [];
  var add = function (i, role) { if (i == null || i === me) return; for (var q = 0; q < targets.length; q++) if (targets[q].i === i) return; targets.push({ i: i, role: role }); };
  add(s.ahead, 'ahead'); add(s.leader, 'leader'); if (s.ahead == null) add(s.behind, 'behind'); add(RS.sel, 'chosen');
  var nc = cs.length, lw = 360, tw = 300, cw = nc ? Math.floor((this.box.w - lw - tw) / nc) : 0;
  var h = '<table class="rc"><colgroup><col style="width:' + lw + 'px">' + cs.map(function () { return '<col style="width:' + cw + 'px">'; }).join('') + '<col style="width:100px"><col style="width:100px"><col style="width:100px"></colgroup><thead><tr><th class="l">LAPS USED</th>' +
    cs.map(function (c) { return '<th>' + esc(c.lab) + '</th>'; }).join('') + '<th>BEST</th><th>LAP</th><th>REST</th></tr></thead><tbody>';
  var mine = cm.c || [], myBest = RS.tw[me].best;
  h += '<tr class="me"><td class="l">' + plateHtml(RS.by[me]) + ' <span class="nm">PETER · ' + cm.n + ' laps</span></td>' + cs.map(function (c, k) { return '<td>' + (mine[k] != null ? mine[k].toFixed(3) : '–') + '</td>'; }).join('') + '<td>' + (myBest != null ? fmt(myBest) : '–') + '</td><td>' + fmt(cm.lap) + '</td><td class="mute">–</td></tr>';
  targets.forEach(function (t) {
    var o = RS.cm[t.i], c = RS.by[t.i], rowCls = t.role === 'chosen' ? ' class="sel"' : '', word = t.role === 'ahead' ? 'AHEAD' : t.role === 'behind' ? 'BEHIND' : t.role === 'leader' ? 'LEADER' : 'CHOSEN';
    var lab = '<td class="l">' + plateHtml(c) + ' <span class="nm">' + esc(lastName(c)) + '</span> <span class="wd">' + word + (o ? ' · ' + o.n + ' laps' : '') + '</span></td>';
    if (!o) { h += '<tr' + rowCls + '>' + lab + '<td colspan="' + (nc + 3) + '" class="mute l">not enough clean laps</td></tr>'; return; }
    var sum = 0, all = true, cells = cs.map(function (cn, k) {
      if (o.c[k] == null || mine[k] == null) { all = false; return '<td class="mute">–</td>'; }
      var d = o.c[k] - mine[k]; sum += d; return '<td class="' + dcls(d) + '">' + dtxt(d) + '</td>';
    }).join('');
    var ld = o.lap - cm.lap, rest = all ? ld - sum : null, ob = RS.tw[t.i].best, bd = ob != null && myBest != null ? ob - myBest : null;
    h += '<tr' + rowCls + '>' + lab + cells + '<td class="' + (bd == null ? 'mute' : dcls(bd)) + '">' + (bd == null ? '–' : dtxt(bd)) + '</td><td class="' + dcls(ld) + '">' + dtxt(ld) + '</td><td class="' + (rest == null ? 'mute' : dcls(rest)) + '">' + (rest == null ? '–' : dtxt(rest)) + '</td></tr>';
  });
  h += '</tbody></table><div class="tnote">REST = straights · under 0.02 s grey</div>';
  b.innerHTML = h;
};
function dcls(d) { return Math.abs(d) < 0.02 ? 'mute' : d > 0 ? 'gain' : 'loss'; }       // inside the +-0.02 s the data is good to, a difference is grey: no claim
function dtxt(d) { return Math.abs(d) < 0.005 ? '±0.00' : (d > 0 ? '+' : '−') + Math.abs(d).toFixed(Math.abs(d) >= 10 ? 1 : 2); }

// ---------- passes on track ----------
function Passes(box) {
  A.Display.call(this, box, ''); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'racepasses';
  var s = RS.sm, R = RS.R, me = RS.me, mine = [], other = 0; this.rows = [];
  (s.passes || []).forEach(function (p) { if (p.by === me || p.over === me) mine.push(p); else other++; });
  var t0 = R.greenT != null ? R.greenT : R.t0;
  this.ph.innerHTML = 'Passes on track · <b>Peter ' + mine.filter(function (p) { return p.by === me; }).length + ' made, ' + mine.filter(function (p) { return p.over === me; }).length + ' lost</b>' + (other ? ' · ' + other + ' between other cars' : '');
  var h = '';
  mine.slice(0, 5).forEach(function (p) {
    var made = p.by === me, oth = made ? p.over : p.by, t = Math.max(0, p.t - t0), mm = Math.floor(t / 60), ss = Math.floor(t - mm * 60);
    h += '<div class="pz" data-i="' + oth + '"><span class="lp">LAP ' + p.lap + '</span><span class="wh">' + esc(p.where) + '</span><span class="tag ' + (made ? 'gain' : 'loss') + '">' + (made ? 'PASSED' : 'PASSED BY') + '</span><span class="who">' + who(oth) + '</span><span class="at">' + mm + ':' + (ss < 10 ? '0' : '') + ss + '</span></div>';
  });
  if (!mine.length) h = '<div class="tnote">' + (s.race ? 'No passes' : 'No passes') + '</div>';
  else if (mine.length > 5) h += '<div class="tnote">+ ' + (mine.length - 5) + ' more</div>';
  this.stage.innerHTML = h; var self = this;
  Array.prototype.forEach.call(this.stage.querySelectorAll('.pz'), function (d, i) {
    d.addEventListener('click', function () { select(+d.getAttribute('data-i')); });
    var p = mine[i];       // SEE IN iRACING (workbench-share.js): the replay, 3 s before the pass, on his car (he passed) or on the car that passed him
    if (p && X.jumpBtn) d.appendChild(X.jumpBtn({ st: p.t, car: p.by === me ? 'me' : p.by, short: true }));
  });
  this.mark();
}
Passes.prototype = Object.create(A.Display.prototype);
Passes.prototype.mark = function () { Array.prototype.forEach.call(this.stage.querySelectorAll('.pz'), function (d) { d.className = 'pz' + (+d.getAttribute('data-i') === RS.sel ? ' sel' : ''); }); };

// a session that is not a race: the rest of the page says so instead of drawing a race
function Note(box) {
  A.Display.call(this, box, ''); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'racenote';
  this.ph.innerHTML = esc(RS.R.sessName || RS.R.sessType) + '';
  this.stage.innerHTML = '<div class="tnote">Not a race</div>';
}
Note.prototype = Object.create(A.Display.prototype);

function build() {
  var s = RS.sm; RS.p = {};
  RS.p.tower = new Tower({ x: 32, y: 126, w: 1136, h: 0 });
  if (s.race) {
    RS.p.trace = new Chart({ x: 1200, y: 126, w: 688, h: 250 }, 'trace');
    RS.p.pos = new Chart({ x: 1200, y: 420, w: 688, h: 200 }, 'pos');
    RS.p.pass = new Passes({ x: 1200, y: 664, w: 688, h: 0 });
  } else RS.p.note = new Note({ x: 1200, y: 126, w: 688, h: 0 });
  RS.p.cmp = new Compare({ x: 32, y: 864, w: 1856, h: 0 });
}

// ---------- hooks for the engine and the test ----------
X.add({ id: 'race', name: 'RACE', avail: usable, build: build });
X.loads.push(loadRace);
X.keys['8'] = function () { var pl = WB.pages(); if (pl[7]) WB.cmd('page', pl[7]); };
// CP-1: what the test needs to know about a car picture on the page: where it is, how big, and whether the browser really loaded the file
function picInfo(f) {
  if (!f) return null;
  var im = f.querySelector('img'), r = f.getBoundingClientRect();
  return { key: f.getAttribute('data-k'), l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height, img: !!im, nat: im ? im.naturalWidth : 0, src: im ? im.getAttribute('src') : '', done: im ? im.complete : false };
}
WB.race = function () {
  var s = RS.sm; if (!s) return null;
  var rows = Array.prototype.map.call(document.querySelectorAll('table.rt tbody tr'), function (tr) {
    var pl = tr.querySelector('.plate'), cells = Array.prototype.map.call(tr.children, function (c) { return c.textContent.replace(/\s+/g, ' ').trim(); });
    var sv = tr.querySelector('svg.pcar'), car = sv && window.PCars ? { type: sv.getAttribute('data-type'), body: sv.getAttribute('data-body'), probe: PCars.probe(sv), w: sv.getBoundingClientRect().width, h: sv.getBoundingClientRect().height } : null;
    return { i: tr.getAttribute('data-i') == null ? -1 : +tr.getAttribute('data-i'), cls: tr.className, cells: cells, plate: pl ? getComputedStyle(pl).backgroundColor : '', plateText: pl ? pl.textContent : '', h: tr.getBoundingClientRect().height, car: car, pic: picInfo(tr.querySelector('.cpic')), plateR: pl ? pl.getBoundingClientRect() : null, cellR: tr.querySelector('td.no') ? tr.querySelector('td.no').getBoundingClientRect() : null };
  });
  var cmp = Array.prototype.map.call(document.querySelectorAll('table.rc tbody tr'), function (tr) { return { cls: tr.className, cells: Array.prototype.map.call(tr.children, function (c) { return { t: c.textContent.replace(/\s+/g, ' ').trim(), c: c.className }; }) }; });
  var heads = Array.prototype.map.call(document.querySelectorAll('table.rc thead th'), function (c) { return c.textContent; });
  var passes = Array.prototype.map.call(document.querySelectorAll('.pz'), function (d) { return { i: +d.getAttribute('data-i'), t: Array.prototype.map.call(d.children, function (c) { return c.textContent; }).join(' '), cls: d.className }; });
  var tp = document.querySelector('.panel .rt') ? document.querySelector('table.rt').getBoundingClientRect() : null;
  var hero = Array.prototype.map.call(document.querySelectorAll('.rph .rpc'), function (e) { var sv = e.querySelector('svg.pcar'), r = e.getBoundingClientRect(); return { i: +e.getAttribute('data-i'), me: e.className.indexOf('me') >= 0, text: e.textContent.replace(/\s+/g, ' ').trim(), body: sv ? sv.getAttribute('data-body') : '', probe: sv && window.PCars ? PCars.probe(sv) : null, r: r.right, l: r.left, pic: picInfo(e.querySelector('.cpic')), t: r.top, b: r.bottom };
  });
  return { hero: hero, me: RS.me, sel: RS.sel, race: s.race, maxLap: s.maxLap, rows: rows, cmp: cmp, heads: heads, passes: passes, multi: RS.multi, tower: tp ? { x: tp.left, y: tp.top, w: tp.width, h: tp.height } : null, ahead: s.ahead, behind: s.behind, leader: s.leader };
};
WB.raceSelect = function (i) { select(i); };
// tests: replace the log with another reply (a bigger field) and draw the page again
WB.raceLoad = function (j) { prep(j); WB.cmd('page', 'driver'); WB.cmd('page', 'race'); return !!RS.sm; };
WB.raceHover = function (lap) { RS.hover = lap; A.need.o = true; };
// the colour of a canvas pixel of a chart ('trace' | 'pos') where a car's point on a lap is, and the point itself
WB.racePoint = function (which, idx, lap) {
  var ch = RS.p[which]; if (!ch) return null; var pt = ch.point(idx, lap); if (!pt) return null;
  var dpr = window.devicePixelRatio || 1, d = ch.cs.getImageData(Math.round(pt.x * dpr) - 1, Math.round(pt.y * dpr) - 1, 3, 3).data, best = [0, 0, 0, 0];
  var bl = -1; for (var k = 0; k < d.length; k += 4) { var lm = (d[k] + d[k + 1] + d[k + 2]) * d[k + 3]; if (lm > bl) { bl = lm; best = [d[k], d[k + 1], d[k + 2], d[k + 3]]; } }
  return { x: pt.x, y: pt.y, rgba: best };
};
WB.raceLines = function (which) { var ch = RS.p[which]; return ch ? { n: RS.sm.trace.length, geom: (function (g) { return { n: g.n, ymax: g.ymax, step: g.step, l: g.l, t: g.t, W: g.W, H: g.H, cars: g.cars }; })(ch.geom()) } : null; };
})();
