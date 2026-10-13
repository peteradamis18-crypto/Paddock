// Paddock Analysis Workbench - the CAREER page (card W6c, docs\DESIGN-workbench.md 2.4 "history across sessions: each corner's time and metrics over weeks;
// PB evolution; not one outing at a time" - the thing Pi Toolbox cannot do, it holds one outing at a time).
// The open lap's car + track + layout over EVERY session Paddock can find (iRacing's telemetry folder and the Vault's copies):
//   PERSONAL BEST   the best lap of every session, oldest to newest; gold = a session that set a new personal best, a purple ring = the personal best now
//   CONSISTENCY     every clean lap of every session (left to right = lap order inside the session), the average of the best 5 (gold bar) and its spread (band)
//   CORNERS         every corner x every session, coloured by how far that session's time was from the corner's best ever (purple = the best ever), BEST or MEDIAN
//                   of the clean laps; beside it a table: first session against the latest, best ever, what is left
//   THEORETICAL     the best iRacing sector ever, joined, against the personal best
//   TOTALS, RACES   sessions, laps, clean laps, time driven; the races from Paddock's own race log (only when there are any)
// Facts only. Lap times are iRacing's own figure to the 1/1000 and invalid laps never count (the server does that: dash\src\career.cs, GET /analysis/career).
// Fixed colours: his = gold, a reference = cool white, best ever = purple, time lost = red, time gained = green. A click on a session opens its best lap.
// The tab exists only when there are 2 or more sessions (no dead tab). The engine (workbench.js) reaches this file only through window.WBX.
(function () {
'use strict';
var X = window.WBX, WB = window.WB;
if (!X || !X.api || !WB) return;
var A = X.api, S = A.S, el = A.el, clamp = A.clamp, fmt = A.fmt, C = A.C, FONT = A.FONT;
var CS = { J: null, state: '', msg: '', done: 0, of: 0, hover: null, hrow: null, mode: 'best', opened: '', p: {}, cur: -1 };
var LW = 1264, PADL = 84, PADR = 24, MAXROWS = 15;       // the left column's width; the margins every chart and the grid share, so a session is one column on all three

function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
function t1(v) { var m = Math.floor(v / 60), s = Math.round((v - m * 60) * 10) / 10; if (s >= 60) { m++; s -= 60; } return m + ':' + (s < 10 ? '0' : '') + s.toFixed(1); }       // axis labels: 1:19.5
function dur(sec) { var h = Math.floor(sec / 3600), m = Math.round((sec - h * 3600) / 60); if (m === 60) { h++; m = 0; } return h > 0 ? h + 'h ' + m + 'm' : m + 'm'; }
function day(ms) { return A.dateWord(new Date(ms).toISOString()); }
function clock(ms) { var d = new Date(ms); return (d.getHours() < 10 ? '0' : '') + d.getHours() + ':' + (d.getMinutes() < 10 ? '0' : '') + d.getMinutes(); }
function niceStep(range, maxTicks) { var st = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 30, 60]; for (var i = 0; i < st.length; i++) if (range / st[i] <= maxTicks) return st[i]; return 120; }
function sgn3(d) { return Math.abs(d) < 0.0005 ? '±0.000' : (d > 0 ? '+' : '−') + Math.abs(d).toFixed(3); }
function cornerLabel(t) { return t.official ? 'T' + String(t.official).toUpperCase() : (t.name || '').replace(/^The /, '') || 'T' + t.n; }     // the same words the other pages use
function thousands(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ','); }

// ---------- the reply (one fetch, polled while the server is still reading the files) ----------
function get(url) {
  return new Promise(function (ok, bad) {
    var x = new XMLHttpRequest(); x.open('GET', url);
    x.onload = function () { var j = null; try { j = JSON.parse(x.responseText); } catch (e) { } ok({ code: x.status || 200, j: j }); };
    x.onerror = function () { bad(new Error('career: ' + url)); };
    x.send();
  });
}
function usable() {
  if (CS.J) return CS.J.sessions.length >= 2;
  return A.P.get('page') === 'career' && (CS.state === 'building' || CS.state === 'wait');      // asked for by name: the page itself says what it is waiting for
}
// the tab list (and the page, when it is the one on screen) follows what the server said
function changed() {
  if (!A.data()) return;
  if (S.page === 'career' && !usable()) { WB.cmd('page', 'driver'); return; }
  A.header();
  if (S.page === 'career' && CS.p.status) { if (CS.J) WB.cmd('page', 'career'); else CS.p.status.update(); }      // the waiting page fills in (or counts on) by itself
}
function loadCareer() {
  var P = A.P, url = P.get('careerdata'), id = P.get('id');
  if (!url && A.LIVE && id) url = '/analysis/career?id=' + encodeURIComponent(id);
  if (!url) return Promise.resolve();
  CS.url = url;
  return new Promise(function (resolve) {
    var first = true;
    function done() { if (first) { first = false; resolve(); } }
    function step() {
      get(url).then(function (o) {
        var j = o.j;
        if (o.code === 503) { CS.state = 'wait'; CS.msg = (j && j.error) || 'Not while driving'; changed(); done(); setTimeout(step, 15000); return; }
        if (o.code === 200 && j && j.building) { CS.state = 'building'; CS.done = j.done | 0; CS.of = j.of | 0; changed(); done(); setTimeout(step, 1000); return; }   // the tab waits for the data; the rest of the page opens meanwhile
        if (o.code === 200 && j && j.sessions) { CS.J = j; CS.state = 'ready'; CS.cur = whichSession(); changed(); done(); return; }
        CS.state = ''; done();                                  // 404 (no laps of this car and track) and the rest: no career, no tab
      }).catch(function () { CS.state = ''; done(); });
    }
    step();
  });
}
function whichSession() {
  var d = A.data(), f = d && d.head && d.head.lap ? d.head.lap.file : '', r = -1;
  if (CS.J && f) CS.J.sessions.forEach(function (s, i) { if (s.file === f) r = i; });
  return r;
}

// ---------- shared geometry: one column per session, the same x on both charts and the grid ----------
function lay() { var n = CS.J.sessions.length, W = LW - PADL - PADR; return { n: n, W: W, cw: W / n, X: function (i) { return PADL + (i + 0.5) * W / n; } }; }
function colAt(x) { var L = lay(), i = Math.floor((x - PADL) / L.cw); return i < 0 || i >= L.n ? null : i; }
function openSession(i, page, extra) {
  var s = CS.J.sessions[i]; if (!s) return;
  var q = new URLSearchParams(); q.set('id', s.file); q.set('lap', s.bestLap); q.set('page', page || 'driver'); if (extra) q.set('race', extra);
  CS.opened = 'workbench.html?' + q.toString();
  if (A.LIVE) location.href = CS.opened;
}
function dateLabels(d, g, L, y) {                               // a date under the first session of each day, never closer than 62 px
  var last = -1e9, lastLab = '';
  CS.J.sessions.forEach(function (s, i) { var lab = day(s.startMs), x = L.X(i); if (lab !== lastLab && x - last >= 62) { d.text(g, d.tbS, lab, x, y, 14, C.mute, 'center'); last = x; lastLab = lab; } });
}
function mouse(d) {
  d.stage.addEventListener('mousemove', function (e) { var p = d.local(e), i = colAt(p[0]); var r = d.rowAt ? d.rowAt(p[1]) : null; if (i !== CS.hover || r !== CS.hrow) { CS.hover = i; CS.hrow = r; A.need.o = true; } });
  d.stage.addEventListener('mouseleave', function () { CS.hover = null; CS.hrow = null; A.need.o = true; });
  d.stage.addEventListener('click', function (e) { var i = colAt(d.local(e)[0]); if (i != null) openSession(i); });
}
function bandCur(d, g, L, y0, h) {                              // the session the open lap belongs to
  if (CS.cur < 0) return;
  g.fillStyle = 'rgba(242,194,48,.07)'; g.fillRect(L.X(CS.cur) - L.cw / 2, y0, L.cw, h);
}
function tip(d, g, txt, col) {
  g.font = '15px ' + FONT; var w = g.measureText(txt).width + 16, bx = PADL + 8, by = 2;
  g.fillStyle = 'rgba(11,11,12,.94)'; g.fillRect(bx, by, w, 22); d.text(g, d.tbO, txt, bx + 8, by + 17, 15, col || C.gold, 'left');
}
function sessWord(s) { return day(s.startMs) + ' ' + clock(s.startMs); }

// ---------- chart 1: the personal best, session by session ----------
function PbChart(box) {
  A.Display.call(this, box, 'Personal best by session · <b>gold = new PB</b>');
  this.kind = 'careerpb'; this.pad = { t: 14, b: 32 }; mouse(this);
}
PbChart.prototype = Object.create(A.Display.prototype);
function median(v) { var a = v.slice().sort(function (x, y) { return x - y; }), n = a.length; return n % 2 ? a[(n - 1) / 2] : (a[n / 2 - 1] + a[n / 2]) / 2; }
// the scale follows the sessions that matter: one slow outing (a single lap, a bad day) must not squash the rest, so a session far above the
// others is drawn on the bottom edge as a ring with its time written next to it
PbChart.prototype.geom = function () {
  var ss = CS.J.sessions, lo = 1e9, hi = -1e9, H = this.box.h - this.pad.t - this.pad.b, t = this.pad.t, bests = ss.map(function (s) { return s.best; });
  bests.forEach(function (b) { lo = Math.min(lo, b); hi = Math.max(hi, b); });
  hi = Math.min(hi, lo + Math.max(1.5, 3 * (median(bests) - lo)));
  var pad = Math.max(0.15, (hi - lo) * 0.12), step = niceStep(hi - lo + 2 * pad, 6), a = Math.floor((lo - pad) / step + 1e-9) * step, b = Math.ceil((hi + pad) / step - 1e-9) * step;
  return { L: lay(), t: t, H: H, a: a, b: b, step: step, Y: function (v) { return v > b ? t + H - 6 : t + (v - a) / (b - a) * (H - 14); } };
};
PbChart.prototype.point = function (i) { var G = this.geom(), v = CS.J.sessions[i].best; return { x: G.L.X(i), y: G.Y(v), clip: v > G.b }; };
PbChart.prototype.drawStatic = function () {
  var g = this.cs, G = this.geom(), L = G.L, ss = CS.J.sessions, J = CS.J, self = this; this.clear(g); this.tbS = [];
  bandCur(this, g, L, G.t, G.H);
  g.lineWidth = 1; g.strokeStyle = C.line;
  for (var k = 0, v = G.a; v <= G.b + 1e-6; k++, v = G.a + k * G.step) { var y = Math.round(G.Y(v)) + 0.5; g.beginPath(); g.moveTo(PADL, y); g.lineTo(PADL + L.W, y); g.stroke(); this.text(g, this.tbS, t1(v), PADL - 10, y + 5, 14, C.mute, 'right'); }
  dateLabels(this, g, L, G.t + G.H + 22);
  // the running best: a gold step line
  g.strokeStyle = C.gold; g.lineWidth = 2.5; g.lineJoin = 'round'; g.beginPath();
  ss.forEach(function (s, i) { var x = L.X(i), y = G.Y(s.pbSoFar); if (i === 0) g.moveTo(x, y); else { g.lineTo(x, G.Y(ss[i - 1].pbSoFar)); g.lineTo(x, y); } });
  g.lineTo(PADL + L.W, G.Y(ss[ss.length - 1].pbSoFar)); g.stroke();
  // every session's best lap: cool white dots, gold where it set a new personal best; one far above the scale: a ring on the bottom edge with its time
  var lastLab = -1e9;
  ss.forEach(function (s, i) {
    var p = self.point(i);
    if (p.clip) {
      g.beginPath(); g.arc(p.x, p.y, 4.5, 0, 6.2832); g.lineWidth = 2; g.strokeStyle = C.ref; g.stroke();
      if (p.x - lastLab >= 66) { self.text(g, self.tbS, fmt(s.best), p.x + 9, p.y + 5, 14, C.mute, 'left'); lastLab = p.x; }
      return;
    }
    g.beginPath(); g.arc(p.x, p.y, s.newPb ? 6 : 4.5, 0, 6.2832); g.fillStyle = s.newPb ? C.gold : C.ref; g.fill(); g.lineWidth = 2; g.strokeStyle = '#0b0b0c'; g.stroke();
  });
  // the personal best now: a purple ring and its time above it
  var pb = J.pb, px = L.X(pb.i), py = G.Y(pb.time);
  g.strokeStyle = C.purple; g.lineWidth = 2.5; g.beginPath(); g.arc(px, py, 11, 0, 6.2832); g.stroke();
  g.font = '16px ' + FONT; var lab = 'PB ' + fmt(pb.time), w = g.measureText(lab).width, ax = clamp(px, PADL + w / 2, PADL + L.W - w / 2);
  this.text(g, this.tbS, lab, ax, py - 19, 16, C.purple, 'center');
};
PbChart.prototype.drawOverlay = function () {
  var g = this.co, G = this.geom(), L = G.L; this.clear(g); this.tbO = [];
  if (CS.hover == null) return;
  var s = CS.J.sessions[CS.hover], x = Math.round(L.X(CS.hover)) + 0.5;
  g.strokeStyle = 'rgba(242,194,48,.5)'; g.lineWidth = 1; g.beginPath(); g.moveTo(x, G.t); g.lineTo(x, G.t + G.H); g.stroke();
  g.strokeStyle = '#ece8df'; g.lineWidth = 2; g.beginPath(); g.arc(L.X(CS.hover), G.Y(s.best), 8, 0, 6.2832); g.stroke();
  tip(this, g, sessWord(s) + ' · BEST ' + fmt(s.best) + ' · LAP ' + s.bestLap + ' · ' + s.valid + ' CLEAN LAP' + (s.valid === 1 ? '' : 'S') + (s.newPb ? ' · NEW PB' : ''));
};

// ---------- chart 2: every clean lap of every session, the average of the best 5 and its spread ----------
function ConsChart(box) {
  A.Display.call(this, box, 'Consistency · <b>gold bar = best-5 average</b> · band = spread');
  this.kind = 'careercons'; this.pad = { t: 14, b: 32 }; mouse(this);
}
ConsChart.prototype = Object.create(A.Display.prototype);
ConsChart.prototype.geom = function () {
  var ss = CS.J.sessions, pb = CS.J.pb.time, H = this.box.h - this.pad.t - this.pad.b, t = this.pad.t;
  var top = pb + Math.max(1.5, 3 * (median(ss.map(function (s) { return s.avg5; })) - pb)), step = niceStep(top - pb + 0.2, 6), a = Math.floor((pb - 0.1) / step + 1e-9) * step, b = Math.ceil(top / step - 1e-9) * step;   // slower laps than this are counted, not drawn
  return { L: lay(), t: t, H: H, a: a, b: b, step: step, Y: function (v) { return t + (v - a) / (b - a) * H; } };
};
ConsChart.prototype.span = function (G, i) { var w = Math.min(G.L.cw * 0.8, 110), x = G.L.X(i); return [x - w / 2, x + w / 2]; };
// where lap j of session i is drawn (null when it is slower than the top of the scale)
ConsChart.prototype.point = function (i, j) {
  var G = this.geom(), s = CS.J.sessions[i], sp = this.span(G, i), m = s.lapT.length;
  if (s.lapT[j] > G.b) return null;
  return { x: sp[0] + (j + 0.5) / m * (sp[1] - sp[0]), y: G.Y(s.lapT[j]) };
};
ConsChart.prototype.hidden = function () { var G = this.geom(), n = 0; CS.J.sessions.forEach(function (s) { s.lapT.forEach(function (t) { if (t > G.b) n++; }); }); return n; };
ConsChart.prototype.drawStatic = function () {
  var g = this.cs, G = this.geom(), L = G.L, ss = CS.J.sessions, self = this; this.clear(g); this.tbS = [];
  bandCur(this, g, L, G.t, G.H);
  g.lineWidth = 1; g.strokeStyle = C.line;
  for (var k = 0, v = G.a; v <= G.b + 1e-6; k++, v = G.a + k * G.step) { var y = Math.round(G.Y(v)) + 0.5; g.beginPath(); g.moveTo(PADL, y); g.lineTo(PADL + L.W, y); g.stroke(); this.text(g, this.tbS, t1(v), PADL - 10, y + 5, 14, C.mute, 'right'); }
  dateLabels(this, g, L, G.t + G.H + 22);
  g.save(); g.beginPath(); g.rect(PADL, G.t - 2, L.W, G.H + 4); g.clip();
  // the spread band and the average of the best 5, joined from session to session
  ss.forEach(function (s, i) {
    var sp = self.span(G, i), y0 = G.Y(s.avg5 - s.sd5), y1 = G.Y(s.avg5 + s.sd5);
    g.fillStyle = 'rgba(242,194,48,.20)'; g.fillRect(sp[0], y0, sp[1] - sp[0], Math.max(3, y1 - y0));
  });
  g.strokeStyle = 'rgba(242,194,48,.55)'; g.lineWidth = 1.2; g.setLineDash([5, 4]); g.beginPath();
  ss.forEach(function (s, i) { var x = L.X(i), y = G.Y(s.avg5); if (i === 0) g.moveTo(x, y); else g.lineTo(x, y); }); g.stroke(); g.setLineDash([]);
  ss.forEach(function (s, i) { var sp = self.span(G, i), y = G.Y(s.avg5); g.strokeStyle = C.gold; g.lineWidth = 3; g.beginPath(); g.moveTo(sp[0], y); g.lineTo(sp[1], y); g.stroke(); });
  // every clean lap on top of the bar: a cool white dot; the session's best lap gold
  ss.forEach(function (s, i) {
    for (var j = 0; j < s.lapT.length; j++) {
      var p = self.point(i, j); if (!p) continue;
      g.beginPath(); g.arc(p.x, p.y, s.lapN[j] === s.bestLap ? 3.8 : 2.6, 0, 6.2832); g.fillStyle = s.lapN[j] === s.bestLap ? C.gold : 'rgba(207,216,227,.78)'; g.fill();
    }
  });
  g.restore();
  var hid = this.hidden();
  if (hid > 0) this.text(g, this.tbS, hid + ' slower lap' + (hid === 1 ? '' : 's') + ' above ' + t1(G.b) + ' not drawn', PADL + L.W, G.t + 12, 14, C.mute, 'right');
};
ConsChart.prototype.drawOverlay = function () {
  var g = this.co, G = this.geom(), L = G.L; this.clear(g); this.tbO = [];
  if (CS.hover == null) return;
  var s = CS.J.sessions[CS.hover], x = Math.round(L.X(CS.hover)) + 0.5;
  g.strokeStyle = 'rgba(242,194,48,.5)'; g.lineWidth = 1; g.beginPath(); g.moveTo(x, G.t); g.lineTo(x, G.t + G.H); g.stroke();
  tip(this, g, sessWord(s) + ' · BEST 5 AVERAGE ' + fmt(s.avg5) + ' · SPREAD ±' + s.sd5.toFixed(3) + ' · BEST ' + fmt(s.best) + ' · ' + s.valid + ' CLEAN LAP' + (s.valid === 1 ? '' : 'S'));
};

// ---------- the corner grid: every corner x every session ----------
function cornerRows() {
  var J = CS.J, nT = J.turns.length, rows = [], k;
  for (k = 0; k < nT; k++) if (J.sessions.some(function (s) { return s.c[k]; })) rows.push(k);
  if (rows.length > MAXROWS) {                                    // a long track: the corners whose times vary most
    var spread = {}; rows.forEach(function (q) { var lo = 1e9, hi = -1e9; J.sessions.forEach(function (s) { if (s.c[q]) { lo = Math.min(lo, s.c[q][0]); hi = Math.max(hi, s.c[q][0]); } }); spread[q] = hi - lo; });
    rows = rows.sort(function (a, b) { return spread[b] - spread[a]; }).slice(0, MAXROWS).sort(function (a, b) { return a - b; });
  }
  return rows;
}
function cval(s, k) { var c = s.c[k]; return c ? c[CS.mode === 'best' ? 0 : 1] : null; }
function cbest(k) { var b = 1e9; CS.J.sessions.forEach(function (s) { var v = cval(s, k); if (v != null && v < b) b = v; }); return b; }
function Grid(box) {
  A.Display.call(this, box, '');
  this.kind = 'careergrid'; this.rows = cornerRows(); this.rh = box.rh; this.top = 24; mouse(this);
  this.ph.innerHTML = 'Corner times by session · <b>purple = best ever</b> · red = slower <span class="chip on" data-m="best">BEST</span><span class="chip" data-m="med">MEDIAN</span>';
  var self = this;
  Array.prototype.forEach.call(this.ph.querySelectorAll('.chip'), function (c) { c.addEventListener('click', function (e) { e.stopPropagation(); setMode(c.getAttribute('data-m')); }); });
}
Grid.prototype = Object.create(A.Display.prototype);
Grid.prototype.rowAt = function (y) { var r = Math.floor((y - this.top) / this.rh); return r < 0 || r >= this.rows.length ? null : r; };
Grid.prototype.cell = function (i, r) { var L = lay(); return { x: L.X(i), y: this.top + r * this.rh + this.rh / 2, w: L.cw, h: this.rh }; };
Grid.prototype.colour = function (i, r) {                          // the colour a cell is drawn in (the test reads it back)
  var k = this.rows[r], v = cval(CS.J.sessions[i], k);
  if (v == null) return null;
  var gap = v - cbest(k);
  if (gap < 0.0005) return 'rgb(180,108,255)';
  return 'rgba(229,83,75,' + (0.18 + 0.72 * Math.min(1, gap / 0.4)).toFixed(3) + ')';
};
Grid.prototype.drawStatic = function () {
  var g = this.cs, L = lay(), self = this, J = CS.J; this.clear(g); this.tbS = [];
  bandCur(this, g, L, this.top - 4, this.rows.length * this.rh + 4);
  dateLabels(this, g, L, 16);
  var inset = L.cw > 8 ? 1 : 0, size = this.rh >= 24 ? 16 : 15;
  this.rows.forEach(function (k, r) {
    var lab = cornerLabel(J.turns[k]); g.font = size + 'px ' + FONT; while (lab.length > 3 && g.measureText(lab).width > PADL - 14) lab = lab.slice(0, -2) + '…';
    self.text(g, self.tbS, lab, PADL - 10, self.top + r * self.rh + self.rh / 2 + 5, size, C.mute, 'right');
    J.sessions.forEach(function (s, i) {
      var col = self.colour(i, r), x0 = L.X(i) - L.cw / 2, y0 = self.top + r * self.rh;
      g.fillStyle = col || '#151518'; g.fillRect(x0 + inset, y0 + 1, L.cw - 2 * inset, self.rh - 2);
    });
  });
};
Grid.prototype.drawOverlay = function () {
  var g = this.co, L = lay(), J = CS.J; this.clear(g); this.tbO = [];
  if (CS.hover == null) return;
  var x = L.X(CS.hover) - L.cw / 2;
  g.strokeStyle = 'rgba(242,194,48,.5)'; g.lineWidth = 1; g.strokeRect(Math.round(x) + 0.5, this.top - 3, Math.max(1, L.cw - 1), this.rows.length * this.rh + 3);
  if (CS.hrow == null) return;
  var r = CS.hrow, k = this.rows[r], s = J.sessions[CS.hover], c = s.c[k];
  g.strokeStyle = '#ece8df'; g.lineWidth = 2; g.strokeRect(Math.round(x) + 1, this.top + r * this.rh + 1, Math.max(1, L.cw - 2), this.rh - 2);
  var best = cbest(k), v = cval(s, k);
  tip(this, g, cornerLabel(J.turns[k]) + ' · ' + sessWord(s) + ' · ' + (c ? (CS.mode === 'best' ? 'BEST ' : 'MEDIAN ') + v.toFixed(3) + ' s (' + (v - best < 0.0005 ? 'BEST EVER' : sgn3(v - best) + ' FROM BEST') + ') · ' + c[2] + ' LAP' + (c[2] === 1 ? '' : 'S') : 'NO CLEAN LAP'));
};
function setMode(m) {
  CS.mode = m === 'med' ? 'med' : 'best';
  Array.prototype.forEach.call(document.querySelectorAll('.ph .chip'), function (c) { c.className = 'chip' + (c.getAttribute('data-m') === CS.mode ? ' on' : ''); });
  if (CS.p.trend) CS.p.trend.render();
  A.need.s = true; A.need.o = true;
}

// ---------- the tables ----------
function Tiles(box) {
  A.Display.call(this, box, ''); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.ph.style.display = 'none'; this.kind = 'careertiles';
  var J = CS.J, th = J.theoretical, pb = J.pb, h = '';
  h += '<div class="cr-tile"><div class="cr-l">PERSONAL BEST</div><div class="cr-v purple">' + fmt(pb.time) + '</div><div class="cr-s">LAP ' + pb.lap + ' · ' + day(pb.startMs) + '</div></div>';
  if (th) {
    h += '<div class="cr-tile"><div class="cr-l">THEORETICAL</div><div class="cr-v">' + fmt(th.time) + '</div></div>';
    h += '<div class="cr-tile"><div class="cr-l">PB GAP</div><div class="cr-v gold">' + th.gap.toFixed(3) + ' s</div></div>';
  }
  this.stage.innerHTML = '<div class="cr-tiles">' + h + '</div>';
}
Tiles.prototype = Object.create(A.Display.prototype);

function Theo(box) {
  A.Display.call(this, box, 'Theoretical best'); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'careertheo';
  var J = CS.J, th = J.theoretical, pb = J.pb, sessions = J.sessions;
  var h = '<table class="cth"><colgroup><col style="width:84px"><col style="width:132px"><col style="width:132px"><col></colgroup><thead><tr><th class="l">SECTOR</th><th>PB LAP</th><th>BEST EVER</th><th class="l">FROM</th></tr></thead><tbody>';
  th.sectors.forEach(function (s, k) {
    var mine = pb.sectors[k], same = Math.abs(mine - s.time) < 0.0006, src = sessions[s.i];
    h += '<tr><td class="l n">S' + (k + 1) + '</td><td>' + mine.toFixed(3) + '</td><td class="' + (same ? 'purple' : 'gold') + '">' + s.time.toFixed(3) + '</td><td class="l mute">' + (src ? day(src.startMs) + ' · LAP ' + s.lap : '') + '</td></tr>';
  });
  h += '<tr class="foot"><td class="l n">LAP</td><td>' + fmt(pb.time) + '</td><td class="gold">' + fmt(th.time) + '</td><td class="l mute">' + th.gap.toFixed(3) + ' s</td></tr></tbody></table>';
  this.stage.innerHTML = h;
}
Theo.prototype = Object.create(A.Display.prototype);

function Totals(box) {
  A.Display.call(this, box, 'Totals'); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'careertotals';
  var J = CS.J, t = J.totals;
  var cell = function (n, l) { return '<div class="cr-tc"><div class="cr-tv">' + n + '</div><div class="cr-l">' + l + '</div></div>'; };
  var h = '<div class="cr-tot">' + cell(t.sessions, 'SESSIONS') + cell(thousands(t.laps), 'LAPS') + cell(thousands(t.valid), 'CLEAN LAPS') + cell(dur(t.seconds), 'DRIVEN') + '</div>';
  h += '<div class="cr-line">FIRST ' + day(t.firstMs) + ' · LATEST ' + day(t.lastMs) + '</div><div class="cr-line" id="crtrend"></div>';
  if (t.uncounted > 0) h += '<div class="cr-line">' + t.uncounted + ' LAP' + (t.uncounted === 1 ? '' : 'S') + ' NOT COUNTED BY IRACING</div>';      // its own best lap of the session stayed slower than their time
  this.stage.innerHTML = h;
}
Totals.prototype = Object.create(A.Display.prototype);

// every corner: the first session against the latest, the best ever, what is left (BEST or MEDIAN, like the grid)
function Trend(box) {
  A.Display.call(this, box, ''); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'careertrend';
  this.rows = cornerRows(); this.rh = box.rh; this.body = el('div'); this.stage.appendChild(this.body); this.render();
}
Trend.prototype = Object.create(A.Display.prototype);
// EARLY = the best of the first sessions that have a time through the corner, RECENT = the best of the latest ones (up to 3 each, never the same session twice):
// one short outing cannot make a corner look better or worse. CHANGE under 0.02 s is "same". LEFT = RECENT against the best ever.
function trendOf(k) {
  var vals = [], ss = CS.J.sessions, ever = 1e9, ei = -1;
  ss.forEach(function (s, i) { var v = cval(s, k); if (v == null) return; vals.push(v); if (v < ever) { ever = v; ei = i; } });
  var m = vals.length, g = clamp(Math.floor(m / 2), 1, 3), r = { m: m, g: g, ever: ever < 1e9 ? ever : null, everAt: ei, early: null, recent: null, change: null, left: null };
  if (m >= 2) { r.early = Math.min.apply(null, vals.slice(0, g)); r.recent = Math.min.apply(null, vals.slice(m - g)); r.change = r.recent - r.early; r.left = r.recent - ever; }
  else if (m === 1) { r.left = 0; }
  return r;
}
Trend.prototype.render = function () {
  var J = CS.J, ss = J.sessions, self = this, up = 0, down = 0, same = 0;
  this.ph.innerHTML = 'Corners · ' + (CS.mode === 'best' ? 'best' : 'median') + ' · early vs recent';
  var h = '<table class="cc"><colgroup><col style="width:84px"><col style="width:78px"><col style="width:80px"><col style="width:88px"><col style="width:128px"><col></colgroup><thead><tr><th class="l">CORNER</th><th>EARLY</th><th>RECENT</th><th>CHANGE</th><th>BEST EVER</th><th>TO BEST</th></tr></thead><tbody>';
  this.rows.forEach(function (k) {
    var r = trendOf(k), ch = r.change, cc = ch == null ? 'mute' : ch <= -0.02 ? 'gain' : ch >= 0.02 ? 'loss' : 'mute';
    if (ch != null) { if (ch <= -0.02) up++; else if (ch >= 0.02) down++; else same++; }
    h += '<tr><td class="l n">' + esc(cornerLabel(J.turns[k])) + '</td><td>' + (r.early != null ? r.early.toFixed(3) : '–') + '</td><td>' + (r.recent != null ? r.recent.toFixed(3) : '–') + '</td><td class="' + cc + '">' + (ch == null ? '–' : sgn3(ch)) + '</td>' +
      '<td>' + (r.ever != null ? r.ever.toFixed(3) + '<small>' + day(ss[r.everAt].startMs) + '</small>' : '–') + '</td><td class="' + (r.left != null && r.left < 0.0005 ? 'purple' : '') + '">' + (r.left == null ? '–' : r.left < 0.0005 ? 'AT BEST' : '+' + r.left.toFixed(3)) + '</td></tr>';
  });
  var g = clamp(Math.floor(ss.length / 2), 1, 3);
  this.body.innerHTML = h + '</tbody></table>';
  Array.prototype.forEach.call(this.body.querySelectorAll('tbody tr'), function (tr) { tr.style.height = self.rh + 'px'; });
  CS.trend = { up: up, down: down, same: same };
  var t = document.getElementById('crtrend');
  if (t) t.innerHTML = 'EARLY TO RECENT · <b class="gain">' + up + ' FASTER</b> · <b class="loss">' + down + ' SLOWER</b> · ' + same + ' SAME';
};

function Races(box) {
  A.Display.call(this, box, ''); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.kind = 'careerraces';
  var J = CS.J, rows = box.rows || 3, rs = J.races.slice(-rows).reverse(), won = J.races.filter(function (r) { return r.cpos === 1; }).length, h = '';
  this.ph.innerHTML = 'Races · ' + J.races.length + ' logged · <b>' + won + ' won</b>';
  var CP = window.PCarPic;
  rs.forEach(function (r) {
    var res = r.cpos === 1 ? 'WON' : 'P' + r.cpos + ' OF ' + r.classCars + (r.multiClass ? ' IN CLASS' : '');
    var gap = r.cpos === 1 ? (r.winTotal != null ? fmt(r.winTotal) : '') : r.gapLaps > 0 ? '+' + r.gapLaps + ' LAP' + (r.gapLaps === 1 ? '' : 'S') : r.gap != null ? '+' + r.gap.toFixed(3) + ' s' : '';
    // P4: his car in the livery that race was run in (the last child, shown first by CSS order, so the text cells keep their places)
    // CP-1: iRacing's own picture of that car (carpics.js). Every row keeps the picture column when ANY row has a picture, so the text stays in line; a car without one is blank.
    var pic = CP && CP.any(rs.map(function (x) { return x.cpath; })) ? '<span class="crcar">' + CP.html({ path: r.cpath, w: 64, title: (J.car || '') + (r.num ? ' #' + r.num : '') }) + '</span>' : '';
    h += '<div class="cr-race' + (pic ? ' pic' : '') + (r.session >= 0 ? ' go' : '') + '" data-id="' + esc(r.id) + '" data-s="' + r.session + '"><span class="d">' + day(r.startMs) + '</span><span class="p' + (r.cpos === 1 ? ' gold' : '') + '">' + res + '</span><span class="g">' + gap + '</span><span class="f">' + r.field + ' CARS · ' + r.laps + ' LAPS</span>' + pic + '</div>';
  });
  if (J.races.length > rows) h += '<div class="tnote" style="margin-top:4px">+ ' + (J.races.length - rows) + ' earlier</div>';
  this.stage.innerHTML = h;
  // CP-1: drawn before the list of pictures was read and none of these cars has one: take the empty picture column away again
  if (CP) { var stg = this.stage; CP.ready().then(function () { if (!stg.querySelector('.cpic')) Array.prototype.forEach.call(stg.querySelectorAll('.cr-race'), function (d) { d.classList.remove('pic'); var c = d.querySelector('.crcar'); if (c && c.parentNode) c.parentNode.removeChild(c); }); }); }
  Array.prototype.forEach.call(this.stage.querySelectorAll('.cr-race.go'), function (d) { d.addEventListener('click', function () { openSession(+d.getAttribute('data-s'), 'race', d.getAttribute('data-id')); }); });
}
Races.prototype = Object.create(A.Display.prototype);

// the page itself while the server is still reading the files, or while he is driving
function Status(box) {
  A.Display.call(this, box, ''); this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.style.height = 'auto'; this.ph.style.display = 'none'; this.kind = 'careerstatus';
  this.body = el('div', 'empty'); this.body.style.cssText = 'position:static'; this.stage.appendChild(this.body); this.update();
}
Status.prototype = Object.create(A.Display.prototype);
Status.prototype.update = function () {
  if (CS.state === 'wait') this.body.innerHTML = esc(CS.msg || 'Not while driving');
  else this.body.innerHTML = 'Reading sessions · ' + CS.done + ' / ' + CS.of;
};

function build() {
  CS.p = {};
  if (!CS.J) { CS.p.status = new Status({ x: 32, y: 126, w: 1856, h: 0 }); return; }
  var J = CS.J, nr = cornerRows().length, rh = clamp(Math.floor(290 / Math.max(1, nr)), 20, 24), gh = 24 + nr * rh + 6;
  CS.p.pb = new PbChart({ x: 32, y: 126, w: LW, h: 232 });
  CS.p.cons = new ConsChart({ x: 32, y: 394, w: LW, h: 232 });
  CS.p.grid = new Grid({ x: 32, y: 668, w: LW, h: gh, rh: rh });
  // the right column stacks from the top, each panel under the one before (measured, so a longer table or an extra line never overlaps); the corner table has the bottom
  var below = function (p) { return Math.ceil(p.el.getBoundingClientRect().bottom) + 14; };
  CS.p.tiles = new Tiles({ x: 1328, y: 126, w: 560, h: 0 });
  var y = below(CS.p.tiles);
  if (J.theoretical) { CS.p.theo = new Theo({ x: 1328, y: y, w: 560, h: 0 }); y = below(CS.p.theo); }
  CS.p.totals = new Totals({ x: 1328, y: y, w: 560, h: 0 });
  if (J.races && J.races.length) {                                // under the totals, above the corner table: as many rows as fit
    var ry = below(CS.p.totals), rows = J.races.length > 1 ? clamp(Math.floor((660 - ry - 20 - 28) / 28), 1, 3) : 1;
    CS.p.races = new Races({ x: 1328, y: ry, w: 560, h: 0, rows: rows });
  }
  CS.p.trend = new Trend({ x: 1328, y: 668, w: 560, h: 0, rh: rh });
  Array.prototype.forEach.call(CS.p.trend.stage.querySelectorAll('tbody tr'), function (tr) { tr.style.height = rh + 'px'; });
  setMode(CS.mode);
}

// ---------- hooks for the engine and the test ----------
X.add({ id: 'career', name: 'CAREER', avail: usable, build: build });
X.loads.push(loadCareer);
// with CAREER there can be 8 or 9 tabs (DRIVER ... SPLITS, VIDEO, RACE, CAREER): the tab row gets tighter so the header keeps its room for the mode words
X.head.push(function () { var t = document.getElementById('tabs'); if (t && t.children.length >= 8 && t.className.indexOf('tight') < 0) t.className += ' tight'; });
X.keys['9'] = function () { var pl = WB.pages(), k = pl.indexOf('career'); if (k >= 0) WB.cmd('page', 'career'); };
X.keys['b'] = X.keys['B'] = function () { if (S.page === 'career' && CS.J) setMode(CS.mode === 'best' ? 'med' : 'best'); };
WB.career = function () {
  if (!CS.J) return { state: CS.state, msg: CS.msg, done: CS.done, of: CS.of, text: (document.querySelector('.cr-status, .empty') || {}).textContent || '' };
  function rows(sel) { return Array.prototype.map.call(document.querySelectorAll(sel), function (tr) { return Array.prototype.map.call(tr.children, function (c) { return c.textContent.replace(/\s+/g, ' ').trim(); }); }); }
  var ds = WB.displays().filter(function (d) { return /^career/.test(d.kind); });
  return {
    state: CS.state, mode: CS.mode, n: CS.J.sessions.length, hover: CS.hover, opened: CS.opened, cur: CS.cur, trend: CS.trend,
    tiles: Array.prototype.map.call(document.querySelectorAll('.cr-tile'), function (t) { return t.textContent.replace(/\s+/g, ' ').trim(); }),
    theo: rows('table.cth tbody tr'), corners: rows('table.cc tbody tr'), totals: Array.prototype.map.call(document.querySelectorAll('.cr-tc, .cr-line'), function (t) { return t.textContent.replace(/\s+/g, ' ').trim(); }),
    races: Array.prototype.map.call(document.querySelectorAll('.cr-race'), function (t) { return Array.prototype.map.call(t.children, function (c) { return c.textContent.trim(); }); }),
    titles: ds.map(function (d) { return { kind: d.kind, text: d.ph.textContent, clipped: d.ph.scrollWidth > d.ph.clientWidth + 1 }; })
  };
};
// where things are drawn (page pixels), so the test can read the pixels there: kind pb | cons | grid, session i, lap or row j
WB.careerPoint = function (kind, i, j) {
  var d = WB.displays().filter(function (q) { return q.kind === 'career' + kind; })[0]; if (!d) return null;
  var p = kind === 'pb' ? d.point(i) : kind === 'cons' ? d.point(i, j) : d.cell(i, j);
  if (!p) return null;
  var r = d.stage.getBoundingClientRect();
  return { x: p.x, y: p.y, px: r.left + p.x, py: r.top + p.y, w: p.w, h: p.h };
};
WB.careerColour = function (kind, i, j) {
  var d = WB.displays().filter(function (q) { return q.kind === 'career' + kind; })[0], p = WB.careerPoint(kind, i, j); if (!d || !p) return null;
  var r = window.devicePixelRatio || 1, v = d.cs.getImageData(Math.round(p.x * r), Math.round(p.y * r), 1, 1).data;
  return [v[0], v[1], v[2], v[3]];
};
WB.careerHover = function (i, r) { CS.hover = i; CS.hrow = r == null ? null : r; A.need.o = true; };
WB.careerClick = function (i) { openSession(i); return CS.opened; };
})();
