'use strict';
// Session Review (card C-40): the timing screen of one session, on the top screen after every session
// (docs\DESIGN-analysis.md section 3A, look = docs\mockups\session-review.png). It replaces the old debrief summary.
// Data: GET /analysis/session (dash\src\sessionreview.cs - laps, iRacing's sectors, history, notes) and, for the map,
// GET /analysis/channels (the workbench's binary reply: Lat/Lon + the time of his lap and of the reference on one distance grid).
// Everything on screen comes from those two replies; nothing is estimated here except the colours:
//   purple = his best ever (this session or before), green = best of this session, yellow = slower, grey = out / in / off.
// Used by debrief.js (after a session) and by sessionreview.html (?id=<file name | vault id | last>, tests: ?data=&map=).
// D-03: the automatic after-session screen is debrief-v4.js now. This page keeps its data logic and its direct page;
// its auto-show after a session is off (debrief.js no longer puts it up by itself). It stays the DEEP DIVE target.
const SessionReview = (function () {
  const MY = { name: 'PETER', team: 'PRATT MILLER MOTORSPORTS', number: '4' };   // typed text (design 3A); the number comes from the session when it has one
  const GOLD = '#f2c230', GAIN = '#3ccf7e', LOSS = '#e5534b', MUTE = '#8b877d', DIM = '#5d5a54', INK = '#ece8df';
  const DAYS = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'], MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
  const EPS = 1e-6, MAXROWS = 19;
  const MAPW = 824, MAPH = 470;

  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const isN = x => typeof x === 'number' && isFinite(x);
  function fmt(t) { if (!isN(t)) return '–'; const m = Math.floor(t / 60), s = t - m * 60; return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3); }
  function fmtS(t) { if (!isN(t)) return '–'; if (t < 60) return t.toFixed(3); const m = Math.floor(t / 60), s = t - m * 60; return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3); }
  function sgn(x, d) { d = d == null ? 3 : d; const s = Math.abs(x).toFixed(d); return (parseFloat(s) === 0 ? '±' : x > 0 ? '+' : '−') + s; }
  function svg(tag, a, inner) { return '<' + tag + ' ' + Object.keys(a).map(k => k + '="' + a[k] + '"').join(' ') + (inner == null ? '/>' : '>' + inner + '</' + tag + '>'); }

  // ---------- what the screen shows, worked out from the lap list ----------
  // The server decides which laps are valid (full, no pits, timed AND counted by iRacing); the rest is arithmetic on its numbers.
  const pure = l => !l.offTrack && l.skip !== 'off';          // no off-track record at all (a lap from the live fallback model has neither field: pure)
  function derive(M) {
    const rows = (M.laps || []).slice();
    const ns = (M.sectorAt || []).length;
    const timed = rows.filter(l => isN(l.time));
    const valid = rows.filter(l => l.valid && isN(l.time));
    let best = null; valid.forEach(l => { if (!best || l.time < best.time) best = l; });
    // the best sectors (green / purple, the optimal row) are joined only from counted laps with no off-track record at all: sectors driven across the grass are no benchmark
    const secLaps = valid.filter(l => l.sectors && l.sectors.length === ns && pure(l));
    const bs = []; for (let k = 0; k < ns; k++) bs.push(secLaps.length ? Math.min.apply(null, secLaps.map(l => l.sectors[k])) : NaN);
    let optimal = ns > 0 && secLaps.length && bs.every(isN) ? bs.reduce((a, b) => a + b, 0) : null;
    if (optimal != null && best && optimal > best.time + 0.0005) optimal = null;          // the best lap had an off-track and is quicker than anything that can be joined: no optimal
    const miniLaps = valid.filter(l => l.mini && l.mini.length === 24 && pure(l));
    const sm = []; for (let i = 0; i < 24; i++) sm.push(miniLaps.length ? Math.min.apply(null, miniLaps.map(l => l.mini[i])) : NaN);
    const ever = M.prev && M.ever ? M.ever : null;          // history of this car and track from other sessions
    const newPb = !!(best && M.prev && best.time < M.prev.time - 0.0005);
    const ts = valid.map(l => l.time).sort((a, b) => a - b), n5 = Math.min(5, ts.length);
    let avg = 0, sd = 0;
    for (let i = 0; i < n5; i++) avg += ts[i];
    if (n5) avg /= n5;
    for (let i = 0; i < n5; i++) sd += (ts[i] - avg) * (ts[i] - avg);
    if (n5) sd = Math.sqrt(sd / n5);
    return { rows, ns, timed, valid, best, bs, optimal, sm, ever, newPb, cons: n5 ? { n: n5, avg, sd } : null, hasMini: rows.some(l => l.mini && l.mini.length === 24) };
  }
  // a counted lap with an off-track record is never purple or green: its sectors are not a benchmark (yellow)
  const secClass = (l, k, D) => !l.valid ? 'sg' : !pure(l) ? 'sy' : D.ever && l.sectors[k] <= Math.min(D.ever.sectors[k], D.bs[k]) + EPS ? 'sp' : l.sectors[k] <= D.bs[k] + EPS ? 'sn' : 'sy';
  const miniClass = (l, i, D) => !l.valid ? 'g' : !pure(l) ? 'y' : D.ever && l.mini[i] <= Math.min(D.ever.mini[i], D.sm[i]) + EPS ? 'p' : l.mini[i] <= D.sm[i] + EPS ? 'n' : 'y';

  // ---------- the map (binary reply of /analysis/channels, see workbench.cs) ----------
  function parseMap(buf) {
    const dv = new DataView(buf);
    if (buf.byteLength < 12 || String.fromCharCode(dv.getUint8(0), dv.getUint8(1), dv.getUint8(2), dv.getUint8(3)) !== 'PWB1') throw new Error('no map');
    const hl = dv.getInt32(4, true), head = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 8, hl)));
    let pos = 8 + hl; const arr = {};
    head.arrays.forEach(k => { arr[k] = new Float32Array(buf, pos, head.n); pos += head.n * 4; });
    if (!arr['lap.Lat'] || !arr['lap.Lon']) throw new Error('no position');
    const dec = 4, m = Math.ceil((head.n - 1) / dec) + 1, pick = a => { const o = []; for (let i = 0; i < m; i++) o.push(a[Math.min(head.n - 1, i * dec)]); return o; };
    return { dec, step: head.lengthM / head.metres, n: head.n, L: head.lengthM, lat: pick(arr['lap.Lat']), lon: pick(arr['lap.Lon']), t: pick(arr['lap.t']), rt: arr['ref.t'] ? pick(arr['ref.t']) : null,
      corners: (head.corners || []).map(c => ({ n: c.n, label: c.label, name: c.name, official: c.official, pa: c.pa })), credit: head.credit || '', lapNo: head.lap && head.lap.lap };
  }

  // fit the outline (metres) into the box and turn it in 15 degree steps so it fills the box best
  function fit(pts, w, h, pad) {
    let best = null;
    for (let deg = 0; deg < 180; deg += 15) {
      const r = deg * Math.PI / 180, c = Math.cos(r), s = Math.sin(r), q = pts.map(p => [p[0] * c - p[1] * s, p[0] * s + p[1] * c]);
      const xs = q.map(p => p[0]), ys = q.map(p => p[1]);
      const x0 = Math.min.apply(null, xs), x1 = Math.max.apply(null, xs), y0 = Math.min.apply(null, ys), y1 = Math.max.apply(null, ys);
      const sc = Math.min((w - 2 * pad) / (x1 - x0), (h - 2 * pad) / (y1 - y0));
      if (!best || sc > best.sc) best = { c, s, x0, x1, y0, y1, sc };
    }
    const B = best, ox = (w - (B.x1 - B.x0) * B.sc) / 2, oy = (h - (B.y1 - B.y0) * B.sc) / 2;
    return p => { const x = p[0] * B.c - p[1] * B.s, y = p[0] * B.s + p[1] * B.c; return [ox + (x - B.x0) * B.sc, h - (oy + (y - B.y0) * B.sc)]; };
  }
  const overlap = (a, b) => !(a[0] + a[2] < b[0] || b[0] + b[2] < a[0] || a[1] + a[3] < b[1] || b[1] + b[3] < a[1]);
  // a label next to a point, on the side away from the track's centre, clear of the other markers and of the track line itself
  function place(p, centre, taken, w, h, bw, path) {
    const dirs = [0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180].map(d => d * Math.PI / 180), base = Math.atan2(p[1] - centre[1], p[0] - centre[0]);
    // first choice: clear of markers AND of the track line; if there is no such place (a crowded corner) clear of the markers only
    for (const strict of [true, false]) for (const dist of [30, 44, 58]) for (const d of dirs) {
      const a = base + d, q = [p[0] + Math.cos(a) * dist, p[1] + Math.sin(a) * dist * 0.87];
      const box = [q[0] - (Math.cos(a) < -0.3 ? bw : Math.cos(a) > 0.3 ? 0 : bw / 2), q[1] - 12, bw, 24];
      if (box[0] < 0 || box[0] + box[2] > w || box[1] < 0 || box[1] + box[3] > h) continue;
      if (taken.some(t => overlap(box, t))) continue;
      if (strict && path && path.some(t => t[0] > box[0] - 10 && t[0] < box[0] + box[2] + 10 && t[1] > box[1] - 10 && t[1] < box[1] + box[3] + 10)) continue;
      taken.push(box); return { x: box[0], y: box[1] + 19 };
    }
    return { x: Math.min(w - bw, p[0] + 18), y: p[1] + 6 };
  }
  // colour of a gain / loss rate (seconds per 100 m): green gained, red lost, grey when tiny
  function gainColour(rate) { const a = Math.min(1, Math.abs(rate) / 0.04); if (a < 0.08) return '#4a4a50'; return rate < 0 ? 'rgba(60,207,126,' + (0.35 + 0.65 * a) + ')' : 'rgba(229,83,75,' + (0.35 + 0.65 * a) + ')'; }

  function mapSvg(mp, M, coloured) {
    const m = mp.lat.length, lat0 = mp.lat[0], lon0 = mp.lon[0], kx = Math.cos(lat0 * Math.PI / 180) * 111320;
    const xy = i => [(mp.lon[i] - lon0) * kx, (mp.lat[i] - lat0) * 110540];
    const pts = []; for (let i = 0; i < m; i++) pts.push(xy(i));
    const P = fit(pts, MAPW, MAPH, 36), PP = pts.map(P);
    let s = svg('polyline', { points: PP.map(p => p[0].toFixed(1) + ',' + p[1].toFixed(1)).join(' ') + ' ' + PP[0][0].toFixed(1) + ',' + PP[0][1].toFixed(1), fill: 'none', stroke: '#000', 'stroke-width': 16, 'stroke-linejoin': 'round' });
    const stepM = mp.step * mp.dec, W = 3;
    for (let j = 0; j < m - 1; j++) {
      let col = '#55555c';
      if (coloured && mp.rt) {
        const a = Math.max(0, j - W), b = Math.min(m - 1, j + 1 + W);
        const rate = ((mp.t[b] - mp.rt[b]) - (mp.t[a] - mp.rt[a])) / Math.max(1, (b - a) * stepM / 100);
        col = gainColour(rate);
      }
      s += svg('line', { x1: PP[j][0].toFixed(1), y1: PP[j][1].toFixed(1), x2: PP[j + 1][0].toFixed(1), y2: PP[j + 1][1].toFixed(1), stroke: col, 'stroke-width': 8, 'stroke-linecap': 'round' });
    }
    const dT = {}; (M.corners || []).forEach(c => { dT[c.n] = c.dTime; });
    const at = pa => { const f = Math.max(0, Math.min(1, pa)) * (m - 1), i = Math.floor(f), j = Math.min(m - 1, i + 1), u = f - i; return [PP[i][0] + (PP[j][0] - PP[i][0]) * u, PP[i][1] + (PP[j][1] - PP[i][1]) * u]; };
    const cs = (mp.corners || []).map(c => ({ c, p: at(c.pa), dt: dT[c.n] })).filter(k => k.p);
    // the three biggest differences get a coloured ring and their time (only when it is a real difference: 0.05 s, the C-30 line)
    const top = coloured ? cs.filter(k => isN(k.dt) && Math.abs(k.dt) >= 0.05).sort((a, b) => Math.abs(b.dt) - Math.abs(a.dt)).slice(0, 3) : [];
    const centre = [PP.reduce((a, p) => a + p[0], 0) / PP.length, PP.reduce((a, p) => a + p[1], 0) / PP.length];
    const taken = cs.map(k => [k.p[0] - 19, k.p[1] - 19, 38, 38]);          // a label keeps clear of every ring, its own too
    cs.forEach(k => {
      // a ring shows the corner's official number (10A); a named complex without one (The Esses) shows its initial, so no two rings read alike
      const on = top.indexOf(k) >= 0, lab = k.c.official ? String(k.c.official).toUpperCase() : k.c.name ? String(k.c.name).replace(/^the\s+/i, '').charAt(0).toUpperCase() : String(k.c.n);
      s += svg('circle', { cx: k.p[0].toFixed(1), cy: k.p[1].toFixed(1), r: on ? 15 : 12, fill: '#000', stroke: on ? (k.dt < 0 ? GAIN : LOSS) : '#8b6d1a', 'stroke-width': on ? 2 : 1.2 });
      s += svg('text', { x: k.p[0].toFixed(1), y: (k.p[1] + (lab.length > 2 ? 3.5 : 4.5)).toFixed(1), 'text-anchor': 'middle', 'font-size': lab.length > 2 ? 10 : on ? 13 : 11, fill: on ? INK : GOLD }, lab);
    });
    top.forEach(k => {
      const txt = sgn(k.dt, 2) + ' s', q = place(k.p, centre, taken, MAPW, MAPH, 76, PP);
      if (q) s += svg('text', { x: q.x.toFixed(1), y: q.y.toFixed(1), 'font-size': 20, fill: k.dt < 0 ? GAIN : LOSS }, txt);
    });
    const sf = PP[0], sq = place([sf[0], sf[1]], centre, taken, MAPW, MAPH, 40, PP);
    if (sq) s += svg('text', { x: sq.x.toFixed(1), y: sq.y.toFixed(1), 'font-size': 14, fill: MUTE, 'letter-spacing': '2' }, 'S/F');
    return s;
  }

  // ---------- the page ----------
  function dateWord(ms) { if (!ms) return ''; const d = new Date(ms); return isNaN(d) ? '' : DAYS[d.getDay()] + ' ' + d.getDate() + ' ' + MONTHS[d.getMonth()]; }

  function header(M, D, X) {
    const num = /^\d{1,3}$/.test(String(M.carNumber || '')) ? String(M.carNumber) : MY.number;
    const first = (M.driver || '').trim().split(/\s+/)[0];
    const name = first ? first.toUpperCase() : MY.name, team = (M.team || '').trim() ? M.team.toUpperCase() : MY.team;
    const km = M.lengthM ? (M.lengthM / 1000).toFixed(2) + ' km' : '';
    const sess = [(M.type || '').toUpperCase(), dateWord(M.startMs), D.rows.length ? D.rows.length + (D.rows.length === 1 ? ' LAP' : ' LAPS') : ''].filter(Boolean).join(' · ');
    let ex = '';
    if (X && X.race && X.pos0 && X.pos) ex = 'P' + X.pos0 + ' → P' + X.pos + (X.pos0 !== X.pos ? ' ' + (X.pos0 > X.pos ? '+' : '−') + Math.abs(X.pos0 - X.pos) : '');
    if (X && X.race && isN(X.inc)) ex += (ex ? ' · ' : '') + X.inc + (X.inc === 1 ? ' incident' : ' incidents');
    const pill = D.best ? (D.newPb ? '<span class="pill">NEW PERSONAL BEST&nbsp; ' + sgn(D.best.time - M.prev.time) + '</span>' : '<span class="pill sr-best">BEST ' + fmt(D.best.time) + '</span>') : '';
    return '<div class="hdr"><div class="plate' + (num.length > 2 ? ' l3' : '') + '">' + esc(num) + '</div>' +
      '<div class="sr-who"><b>' + esc(name) + '</b><span>' + esc(team) + '</span></div>' +
      '<div class="mid"><b>' + esc(M.car || '') + '</b><span>' + esc([M.track, M.config, km].filter(Boolean).join(' · ')) + '</span></div>' +
      '<div class="sess"><b>' + esc(sess) + '</b>' + (ex ? '<span class="ex">' + esc(ex) + '</span>' : '') + pill + '</div></div>';
  }

  // which rows to show: all of them up to MAXROWS, else the latest laps - and the best lap on top when it is older than those
  function windowRows(D) {
    const all = D.rows;
    if (all.length <= MAXROWS) return { list: all, note: '' };
    const bi = D.best ? all.indexOf(D.best) : -1, tailFrom = all.length - MAXROWS;
    if (bi >= 0 && bi < tailFrom) return { list: [all[bi]].concat(all.slice(all.length - (MAXROWS - 1))), note: 'best + last ' + (MAXROWS - 1) + ' of ' + all.length + ' laps' };
    return { list: all.slice(tailFrom), note: 'laps ' + all[tailFrom].n + '–' + all[all.length - 1].n + ' of ' + all.length };
  }

  function table(M, D, enough) {
    const w = windowRows(D), n = w.list.length, ns = D.ns;
    const rh = Math.max(30, Math.min(50, Math.floor(580 / Math.max(1, n))));
    const cols = ['64px', '150px'].concat(new Array(ns).fill('96px'));
    if (D.hasMini) cols.push('minmax(0,1fr)'); else if (!ns) cols.push('minmax(0,1fr)');
    cols.push('104px');
    let h = '<div class="sr-tbl" style="--cols:' + cols.join(' ') + ';--rh:' + rh + 'px;--ltf:' + (rh >= 44 ? 26 : 24) + 'px;--mh:' + Math.max(12, Math.min(22, rh - 14)) + 'px">';
    h += '<div class="sr-row h"><div>LAP</div><div>TIME</div>';
    for (let k = 0; k < ns; k++) h += '<div>S' + (k + 1) + '</div>';
    if (D.hasMini) h += '<div>24 MINI-SECTORS</div>'; else if (!ns) h += '<div></div>';
    h += '<div>GAP</div></div>';
    w.list.forEach(l => {
      const isBest = l === D.best;
      const lc = !l.valid ? 'sg' : isBest ? (D.newPb ? 'sp' : 'sn') : 'sy';
      h += '<div class="sr-row' + (isBest ? ' sr-best' : '') + (l.valid ? '' : ' grey') + '" data-lap="' + l.n + '"><div class="mute">' + l.n + '</div><div class="lt ' + lc + '">' + fmt(l.time) + '</div>';
      for (let k = 0; k < ns; k++) h += l.sectors && isN(l.sectors[k]) ? '<div class="' + secClass(l, k, D) + '">' + fmtS(l.sectors[k]) + '</div>' : '<div class="sg">–</div>';
      if (D.hasMini) {
        h += '<div class="ms">';
        for (let i = 0; i < 24; i++) h += '<i class="' + (l.mini && l.mini.length === 24 ? miniClass(l, i, D) : 'g') + '"></i>';
        h += '</div>';
      } else if (!ns) h += '<div></div>';
      h += '<div class="' + (l.valid ? 'mute' : 'sr-flag') + '">' + (l.valid ? (isBest ? '' : sgn(l.time - D.best.time)) : esc(l.flag || '')) + '</div></div>';
    });
    if (D.optimal != null && enough) {
      h += '<div class="sr-row opt"><div></div><div class="lt">' + fmt(D.optimal) + '</div><div class="ol" style="grid-column: span ' + (ns + (D.hasMini ? 1 : 0)) + '">Optimal</div><div class="mute">' + (D.best ? sgn(D.optimal - D.best.time) : '') + '</div></div>';
    }
    h += '</div>';
    if (w.note) h += '<div class="tnote">' + esc(w.note) + '</div>';
    return h;
  }

  function numbers(M, D, enough) {
    if (!D.best) return '';
    const tile = (lab, val, sub, cls) => '<div><span class="lab">' + lab + '</span><b' + (cls ? ' class="' + cls + '"' : '') + '>' + val + '</b><span class="sr-sub">' + sub + '</span></div>';
    const mins = Math.round((M.seconds || 0) / 60);
    const laps = tile('Laps', D.rows.length + ' <span class="u">· ' + D.valid.length + ' clean</span>', mins > 0 ? mins + ' min on track' : '&nbsp;');
    const bestSub = [D.newPb ? 'new PB, ' + sgn(D.best.time - M.prev.time) + ' s' : M.prev ? 'PB ' + fmt(M.prev.time) : '', 'lap ' + D.best.n].filter(Boolean).join(' · ');
    const best = tile('Best lap', fmt(D.best.time), bestSub, D.newPb ? 'purple' : 'sr-gold');
    if (!enough) return '<div class="nums" style="--nc:2">' + best + laps + '</div>';
    const opt = D.optimal != null ? tile('Optimal', fmt(D.optimal), sgn(D.optimal - D.best.time) + ' s') : '';
    const con = D.cons ? tile('Consistency', fmt(D.cons.avg), 'average of best ' + D.cons.n + ' · spread ±' + D.cons.sd.toFixed(2) + ' s') : '';
    return '<div class="nums" style="--nc:' + (2 + (opt ? 1 : 0) + (con ? 1 : 0)) + '">' + best + opt + con + laps + '</div>';
  }

  // lap-time chart (only with 5+ laps): a dot per lap, the previous PB as a purple rule, the optimal lap dotted
  function chart(M, D) {
    const rows = D.timed, W = 824, H = 140;
    if (rows.length < 5 || !D.best) return '';
    const lo = (D.optimal != null ? D.optimal : D.best.time) - 0.2, hi = D.best.time + 1.6;
    const x = k => 40 + k * (W - 70) / (rows.length - 1), y = t => 22 + (Math.min(hi, t) - lo) / (hi - lo) * (H - 46);
    let c = svg('text', { x: 0, y: 12, 'font-size': 14, fill: MUTE, 'letter-spacing': '3' }, 'LAP TIMES');
    if (M.prev && M.prev.time >= lo && M.prev.time <= hi) {
      c += svg('line', { x1: 30, x2: W, y1: y(M.prev.time).toFixed(1), y2: y(M.prev.time).toFixed(1), stroke: '#b46cff', 'stroke-width': 1, opacity: .6 });
      c += svg('text', { x: W, y: (y(M.prev.time) - 6).toFixed(1), 'text-anchor': 'end', 'font-size': 14, fill: '#b46cff' }, 'PREVIOUS PB ' + fmt(M.prev.time));
    }
    if (D.optimal != null) c += svg('line', { x1: 30, x2: W, y1: y(D.optimal).toFixed(1), y2: y(D.optimal).toFixed(1), stroke: MUTE, 'stroke-dasharray': '3 5', 'stroke-width': 1 });
    c += svg('polyline', { points: rows.map((l, k) => l.valid ? x(k).toFixed(1) + ',' + y(l.time).toFixed(1) : '').filter(Boolean).join(' '), fill: 'none', stroke: '#3a3a40', 'stroke-width': 1.5 });
    rows.forEach((l, k) => {
      const off = l.time > hi;
      c += svg('circle', { cx: x(k).toFixed(1), cy: y(l.time).toFixed(1), r: l === D.best ? 7 : 5, fill: !l.valid ? '#3a3a40' : l === D.best ? (D.newPb ? '#b46cff' : GOLD) : INK });
      if (rows.length <= 24 || k % 2 === 0) c += svg('text', { x: x(k).toFixed(1), y: H - 1, 'text-anchor': 'middle', 'font-size': 14, fill: DIM }, l.n + (off ? '▾' : ''));
    });
    return '<svg class="chart" viewBox="0 0 ' + W + ' ' + H + '" width="' + W + '" height="' + H + '">' + c + '</svg>';
  }

  function notesBlock(M, D, enough) {
    const what = M.ref && M.ref.kind === 'session' ? 'next best lap' : 'previous best';
    const shown = M.shown || M.best, lapNo = shown ? shown.lap : (D.best ? D.best.n : '');
    if (!D.best || !enough) return '';
    const notes = (M.notes || []).slice(0, 3);
    let h = '<div class="notes"><div class="lab nl">Lap ' + lapNo + ' against ' + what + '</div>';
    if (notes.length) notes.forEach(k => { h += '<div class="n"><b>' + esc(String(k.label).replace(/^The /i, '').toUpperCase()) + '</b><span class="' + (k.dTime < 0 ? 'gain' : 'loss') + '">' + sgn(k.dTime, 2) + ' s</span><span>' + esc(k.fact) + '</span></div>'; });
    else return '';
    return h + '</div>';
  }

  function mapLabel(M, D, coloured) {
    const shown = M.shown || M.best;
    if (!D.best) return '';
    if (!coloured || !M.ref) return '<div class="lab maplab">BEST LAP <span class="sr-gold">' + fmt(D.best.time) + '</span></div>';
    const lt = shown && shown.time != null ? shown.time : D.best.time;
    const what = M.ref.kind === 'session' ? 'NEXT BEST' : 'PREVIOUS BEST';
    return '<div class="lab maplab">' + (shown && shown.lap !== D.best.n ? 'LAP ' + shown.lap : 'BEST LAP') + ' <span class="sr-gold">' + fmt(lt) + '</span> VS ' + what + ' <span class="ref">' + fmt(M.ref.time) + '</span> · GREEN = GAINED · RED = LOST</div>';
  }

  // draws everything that depends on the data into `body` (the bar at the bottom lives outside it and is never touched)
  function render(body, M, mp, X) {
    const D = derive(M), enough = D.valid.length >= 3;
    const coloured = enough && !!(mp && mp.rt && M.ref);
    let h = header(M, D, X) + '<div class="sr-rule"></div>' + table(M, D, enough) + mapLabel(M, D, coloured);
    if (mp && D.best) { try { h += '<svg class="mapbox" viewBox="0 0 ' + MAPW + ' ' + MAPH + '" width="' + MAPW + '" height="' + MAPH + '">' + mapSvg(mp, M, coloured) + '</svg>'; } catch (e) { h += '<div class="mapmsg">No map</div>'; } }
    else if (D.best) h += '<div class="mapmsg">No map</div>';
    else h += '<div class="mapmsg">No complete lap yet</div>';
    if (mp && D.best && mp.credit) h += '<div class="credit">' + esc(mp.credit) + '</div>';
    h += numbers(M, D, enough) + (enough ? chart(M, D) : '') + notesBlock(M, D, enough);
    body.innerHTML = h;
    return D;
  }

  // ---------- loading ----------
  async function getJson(url) { const r = await fetch(url, { cache: 'no-store' }); let j = null; try { j = await r.json(); } catch (e) { } return { code: r.status, j }; }

  // The model for one session. spec: { id, lap } live, or { data, map } (urls) for tests. Throws { driving: true } while he is in the car.
  async function load(spec) {
    if (spec.model) return { M: spec.model, mp: spec.mapData || null };
    if (spec.demo) { const d = await (await fetch(spec.demo, { cache: 'no-store' })).json(); return { M: d.M, mp: d.mp }; }     // a saved real session: { M: the /analysis/session reply, mp: the map points }
    if (spec.data) {
      const M = await (await fetch(spec.data, { cache: 'no-store' })).json();
      let mp = null;
      if (spec.map) { try { mp = spec.map.endsWith('.json') ? await (await fetch(spec.map, { cache: 'no-store' })).json() : parseMap(await (await fetch(spec.map, { cache: 'no-store' })).arrayBuffer()); } catch (e) { mp = null; } }
      return { M, mp };
    }
    const q = encodeURIComponent(spec.id || 'last');
    const r = await getJson('/analysis/session?id=' + q + (spec.lap ? '&lap=' + spec.lap : ''));
    if (r.code === 503) throw { driving: true };
    if (r.code !== 200 || !r.j || r.j.error) throw { code: r.code, error: r.j && r.j.error };
    const M = r.j;
    let mp = null;
    const shown = M.shown || M.best;
    if (shown) {
      try {
        const rid = !spec.id || spec.id === 'last' ? M.file : spec.id;
        const url = '/analysis/channels?id=' + encodeURIComponent(rid) + '&lap=' + shown.lap + '&ref=' + encodeURIComponent(M.ref ? M.ref.spec : 'none:0') + '&ch=Lat,Lon';
        const rr = await fetch(url, { cache: 'no-store' });
        if (rr.status === 200) mp = parseMap(await rr.arrayBuffer());
      } catch (e) { mp = null; }
    }
    return { M, mp };
  }

  // when the file cannot be read: the laps he just drove, from what the dashboard saw live (no sectors, no map).
  // A lap the dashboard did not call clean is shown dimmed. It gets a word only when the dashboard itself gave the reason (a row's `why`:
  // out, in, pit or off); "not clean" alone does not say why, so no word is made up (it used to write OFF, or OUT on the first row, without proof).
  const WHY = { out: 'OUT', in: 'IN', pit: 'PIT', off: 'OFF' };
  const whyWord = l => { const k = String(l && l.why || '').toLowerCase(); return Object.prototype.hasOwnProperty.call(WHY, k) ? WHY[k] : ''; };
  function liveModel(r, base) {
    const rows = (r && r.rows) || ((r && r.times) || []).map((x, i) => ({ n: i + 1, time: x.t, clean: x.clean, why: x.why }));
    const M = Object.assign({ v: 1, file: '', car: r && r.car || '', track: r && r.track || '', config: '', lengthM: 0, type: r && r.type || '', startMs: r && r.startMs || Date.now(), seconds: (r && r.mins || 0) * 60,
      sectorAt: [], laps: rows.map(l => ({ n: l.n, time: l.time, official: true, valid: !!l.clean, flag: l.clean ? '' : whyWord(l), sectors: null, mini: null })), prev: null, ever: null, ref: null, notes: [], corners: [], live: true }, base || {});
    return M;
  }

  // ---------- mounting ----------
  function stageOf(root) { return root.querySelector('.sr-stage'); }
  function fitStage(root) {
    const st = stageOf(root); if (!st) return;
    const w = root.clientWidth || window.innerWidth, h = root.clientHeight || window.innerHeight, s = Math.min(w / 1920, h / 1080);
    st.style.transform = 'translate(' + ((w - 1920 * s) / 2).toFixed(1) + 'px,' + ((h - 1080 * s) / 2).toFixed(1) + 'px) scale(' + s.toFixed(5) + ')';
  }
  // The frame (bottom bar slot, ANALYSIS) is made at once; the data is painted into #srBody when it arrives.
  function frame(root, opts) {
    root.classList.add('sr');
    root.innerHTML = '<div class="sr-stage"><div id="srBody" style="position:absolute;left:0;top:0;width:1920px;height:1080px"></div>' +
      ''  +
      '<div class="foot"><div id="dbReviewSlot"></div><button type="button" class="btn" id="srSave" hidden>SAVE</button><button type="button" class="btn" id="srRace" hidden>RACE</button><button type="button" class="btn" id="srAnalysis" hidden>ANALYSIS</button><button type="button" class="btn" id="srCos" hidden>OPEN IN COSWORTH</button></div></div>';
    fitStage(root);
    if (!root._srResize) { root._srResize = () => fitStage(root); window.addEventListener('resize', root._srResize); }
    return root.querySelector('#srBody');
  }

  const SR = {
    parseMap, derive, load, liveModel, fmt, sgn, state: { last: null },

    // mount into `root`; opts: { id, lap, data, map, model, mapData, live (the debrief's summary), extras, hint, onReady }
    // resolves with { M, D, mp } or null when he is driving (nothing is shown then)
    async mount(root, opts) {
      opts = opts || {};
      const body = frame(root, opts);
      const X = opts.extras || null;
      let res = null, tries = 0;
      const live = opts.live || null, waits = [1500, 2500, 3500], gone = () => (opts.alive && !opts.alive()) || (!root.isConnected && !opts.detached);
      let stale = false, drives = 0;
      // the dashboard itself sees him in the car: then there is nothing to show
      const inCar = () => { try { return !!(UI.live() && L.v && L.v.IsOnTrack); } catch (x) { return false; } };
      for (;;) {
        try { res = await load(opts); }
        catch (e) {
          // 503 = irdash thinks he is driving. If this page already sees him out of the car, irdash may be a frame behind
          // (it was up to 2 s behind until IsDriving was made live, 2026-10-11): ask twice more instead of dropping the review.
          // A real 503 (he is driving, or a test says so) still ends with nothing on the screen after about a second.
          if (e && e.driving) {
            if (typeof UI !== 'undefined' && !inCar() && drives++ < 2) { await new Promise(ok => setTimeout(ok, 600)); if (gone()) return null; continue; }
            return null;
          }
          res = null;
        }
        if (gone()) return null;
        // The file may lag the dashboard by a few seconds right after the session: wait for it, then show what there is.
        // A file last written before he got in the car is an OLDER session (iRacing has not written this one): never show that as this session.
        stale = !!(res && live && !live.demo && isN(res.M.modMs) && isN(live.startMs) && res.M.modMs < live.startMs - 10000);
        const behind = stale || !!(res && live && !live.demo && live.laps > 1 && (res.M.laps || []).filter(l => isN(l.time)).length < live.laps - 1);
        const again = !opts.model && !opts.data && !opts.demo && (behind || (!res && tries < 1));
        if (again && tries < waits.length) { await new Promise(ok => setTimeout(ok, waits[tries++])); if (gone()) return null; continue; }
        break;
      }
      if (!res || stale) res = { M: liveModel(live, opts.base), mp: null };
      const D = render(body, res.M, res.mp, X);
      const btn = root.querySelector('#srAnalysis');
      btn.hidden = !D.best || !!res.M.live;
      btn.onclick = e => { e.stopPropagation(); e.preventDefault(); SR.openAnalysis(res.M, opts.id); };
      // RACE (W6b): next to ANALYSIS, only when irdash has a race log for this session (GET /analysis/race answers 200). No log, no button.
      const rb = root.querySelector('#srRace');
      rb.hidden = true;
      rb.onclick = e => { e.stopPropagation(); e.preventDefault(); SR.openAnalysis(res.M, opts.id, 'race'); };
      if (!btn.hidden) SR.hasRace(res.M, opts.id).then(ok => { if (ok && rb.isConnected) rb.hidden = false; });
      SR.wireCosworth(root, opts);
      SR.wireSave(root, res.M);
      SR.state.last = { M: res.M, D, mp: res.mp, root };
      if (opts.onReady) opts.onReady(res.M, D);
      return { M: res.M, D, mp: res.mp };
    },

    // W-18: OPEN IN COSWORTH, only when Pi Toolbox is installed (the flag is in /vault). The id names the session's file
    // (a Vault moment id, a telemetry file name or "last"); the debrief draws its own copy, so it passes opts.noCos.
    wireCosworth(root, opts) {
      const b = root.querySelector('#srCos'); if (!b) return;
      b.hidden = true;
      if (opts && opts.noCos) return;
      const cid = !opts || !opts.id || opts.id === 'last' ? 'last' : opts.id;
      fetch('/vault', { cache: 'no-store' }).then(r => r.json()).then(j => {
        if (!(j && j.cosworth && j.cosworth.installed) || !b.isConnected) return;
        b.hidden = false;
        b.onclick = e => {
          e.stopPropagation(); e.preventDefault();
          b.textContent = 'OPENING';
          fetch('/vault/open?how=cosworth&id=' + encodeURIComponent(cid), { cache: 'no-store' }).catch(() => { }).then(() => { b.textContent = 'OPEN IN COSWORTH'; });
        };
      }).catch(() => { });
    },

    // SAVE keeps this session's recording for good (S1). The recorder's session is matched to the review by its start-time window;
    // the button is hidden when there is no recording. Words: SAVE, SAVED, SAVED FULL only.
    wireSave(root, M) {
      const b = root.querySelector('#srSave'); if (!b) return;
      if (!M || !isN(M.startMs)) { b.hidden = true; return; }
      const start = M.startMs;
      const show = txt => { b.textContent = txt; b.hidden = false; b.disabled = txt !== 'SAVE'; };
      fetch('/api/rec/sessions', { cache: 'no-store' }).then(r => r.json()).then(j => {
        const ss = (j && j.sessions) || []; let hit = null;
        ss.forEach(s => { const d = isN(s.durationSec) ? s.durationSec : 0; if (start >= s.startMs - 5000 && start <= s.startMs + (d + 60) * 1000 && (!hit || s.startMs > hit.startMs)) hit = s; });
        if (!hit) { b.hidden = true; return; }
        if (M.live && hit.state !== 'finishing') { b.hidden = true; return; }
        show(hit.saved ? 'SAVED' : 'SAVE');
        if (hit.saved) return;
        b.onclick = e => {
          e.stopPropagation(); e.preventDefault();
          fetch('/api/rec/save?id=' + encodeURIComponent(hit.id), { method: 'POST', cache: 'no-store' }).then(r => r.json()).then(x => {
            const st = x && x.state;
            if (st === 'SAVED') show('SAVED'); else if (st === 'SAVING') show('SAVE'); else if (st === 'SAVED FULL') show('SAVED FULL');
          }).catch(() => { });
        };
      }).catch(() => { b.hidden = true; });
    },

    // does irdash hold a race log for this session? (dash\src\field.cs: 200 = yes; 404 = none; 503 = he is driving.) The body is not needed.
    async hasRace(M, id) {
      const rid = !id || id === 'last' ? M.file : id;
      if (!rid || M.live) return false;
      try {
        const r = await fetch('/analysis/race?id=' + encodeURIComponent(rid), { cache: 'no-store' });
        try { if (r.body && r.body.cancel) r.body.cancel(); } catch (e) { }
        return r.status === 200;
      } catch (e) { return false; }
    },

    // ANALYSIS: the workbench on this session's lap, over the dashboard (an iframe, like the Vault); BACK or closing in the car puts it away
    // page = 'race' opens it on the RACE page (the RACE button)
    openAnalysis(M, id, page) {
      if (document.getElementById('wbHost')) return;
      const lap = (M.shown || M.best || {}).lap;
      if (!lap) return;
      const rid = !id || id === 'last' ? M.file : id;
      const url = 'workbench.html?id=' + encodeURIComponent(rid) + '&lap=' + lap + (M.ref && M.ref.spec ? '&ref=' + encodeURIComponent(M.ref.spec) : '') + (page ? '&page=' + encodeURIComponent(page) : '');
      const host = document.createElement('div'); host.id = 'wbHost';
      host.innerHTML = '<div class="back" id="wbBack">‹ Back to session review</div><iframe title="Paddock Analysis"></iframe>';
      host.querySelector('iframe').src = url;
      document.body.appendChild(host);
      requestAnimationFrame(() => host.classList.add('on'));
      const close = () => { clearInterval(host._t); window.removeEventListener('message', host._m); host.classList.remove('on'); setTimeout(() => host.remove(), 450); };
      host.querySelector('#wbBack').addEventListener('click', e => { e.stopPropagation(); close(); });
      host._m = e => { if (e.origin === location.origin && e.data && e.data.irdash === 'workbench-close') close(); };
      window.addEventListener('message', host._m);
      host._t = setInterval(() => { try { if (UI.live() && L.v && L.v.IsOnTrack) close(); } catch (x) { } }, 1000);   // never over the car
      SR.state.workbenchUrl = url;
    },

    // test hooks: every piece of text on the stage against every other (should be none), and small helpers
    boxes(root) {
      const out = [], all = (root || document).querySelectorAll('.sr-stage *');
      for (let i = 0; i < all.length; i++) {
        const e = all[i]; if (e.children.length || !e.textContent.trim() || e.tagName === 'STYLE' || e.tagName === 'SCRIPT') continue;
        const rg = document.createRange(); rg.selectNodeContents(e); let t = rg.getBoundingClientRect();
        let x0 = t.left, y0 = t.top, x1 = t.right, y1 = t.bottom;
        for (let p = e; p && !p.classList.contains('sr-stage'); p = p.parentElement) {
          if (p instanceof SVGElement) continue;
          const cs = getComputedStyle(p);
          if (cs.overflow === 'hidden' || cs.overflowX === 'hidden') { const pr = p.getBoundingClientRect(); x0 = Math.max(x0, pr.left); y0 = Math.max(y0, pr.top); x1 = Math.min(x1, pr.right); y1 = Math.min(y1, pr.bottom); }
        }
        if (x1 > x0 && y1 > y0) out.push({ x: x0, y: y0, w: x1 - x0, h: y1 - y0, s: e.textContent.trim().substring(0, 40), fs: parseFloat(getComputedStyle(e).fontSize) });
      }
      return out;
    },
    overlaps(root) {
      const b = SR.boxes(root), bad = [];
      for (let i = 0; i < b.length; i++) for (let j = i + 1; j < b.length; j++) {
        const p = b[i], q = b[j];
        if (p.x + 1 < q.x + q.w - 1 && q.x + 1 < p.x + p.w - 1 && p.y + 1 < q.y + q.h - 1 && q.y + 1 < p.y + p.h - 1) bad.push(p.s + ' | ' + q.s);
      }
      return { boxes: b.length, bad };
    },

    // standalone page: ?id=<file | vault id | last> [&lap=n], or ?data=<model json>&map=<PWB1 file or map json> for tests. Extras: &race=1&pos0=&pos=&inc=
    page() {
      const P = new URLSearchParams(location.search), root = document.getElementById('sr');
      const X = P.get('race') ? { race: true, pos0: +P.get('pos0') || 0, pos: +P.get('pos') || 0, inc: P.get('inc') == null ? NaN : +P.get('inc') } : null;
      SR.ready = false;
      SR.mount(root, { id: P.get('id'), lap: +P.get('lap') || 0, data: P.get('data'), map: P.get('map'), extras: X }).then(r => { SR.ready = true; if (!r) root.innerHTML = ''; })
        .catch(e => { SR.error = String(e && e.message || e); SR.ready = true; });
    },
  };
  return SR;
})();
