'use strict';
// Paddock ALL THE DATA (rawdata.html?id=<telemetry file>): every channel of ANY drive over TIME, from irdash /analysis/raw
// (dash\src\rawdata.cs). Peter 2026-10-18, a qualifying run with no full lap: "just show me the data". So this page needs no lap:
//  - the timeline strip: the whole drive, each lap as a block (full, out, in, pit, part) with iRacing's time; press one to zoom to it;
//  - the traces on ONE cursor: speed, throttle + brake, steering, gear, RPM; lap lines, pit lane and incidents marked on them;
//  - the map dot (from the car's GPS) and the values at the cursor, in mph;
//  - big buttons: zoom in / out, back / on, the whole drive. Drag pans, the wheel zooms, arrow keys too.
// The first reply is the whole drive at about 3000 points; a zoomed window is asked again, finer (up to the file's 60 a second).
// Never while he drives (irdash answers 503). Words: docs\COPY-RULES.md. Unknown is a dash, never 0.
(function () {
  const $ = id => document.getElementById(id);
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const DOT = ' · ', DASH = '–';
  const P = new URLSearchParams(location.search), ID = P.get('id') || '', DATA = P.get('data') || '';
  const C = { gold: '#f2c230', ink: '#f4f1ea', mute: '#8d8a82', dim: '#5d5a54', line: '#26262a', hair: 'rgba(244,241,234,.12)', green: '#3ccf7e', red: '#ff5a4d', amber: '#ffb21e', steel: '#7fa6c9', band: '#101012' };
  const FONT = 'Bahnschrift, "Segoe UI", sans-serif';
  const stage = $('stage');
  let O = null, Dt = null, V = { a: 0, b: 1 }, cur = 0, pend = 0, want = null, scale = 1;

  function fit() { scale = Math.min(innerWidth / 1920, innerHeight / 1080); stage.style.transform = 'scale(' + scale + ')'; stage.style.left = Math.max(0, (innerWidth - 1920 * scale) / 2) + 'px'; }
  addEventListener('resize', fit); fit();

  const mmss = s => { const m = Math.floor(s / 60), x = Math.round(s - m * 60); return m + ':' + (x < 10 ? '0' : '') + x; };
  const clock = s => { if (!(s >= 0)) return DASH; const m = Math.floor(s / 60), x = s - m * 60; return m + ':' + (x < 10 ? '0' : '') + x.toFixed(1); };
  const lapClock = t => { if (!(t > 0)) return DASH; const m = Math.floor(t / 60), s = t - m * 60; return (m ? m + ':' : '') + (m && s < 10 ? '0' : '') + s.toFixed(3); };
  const NY = { timeZone: 'America/New_York' };
  const dayTxt = iso => { const d = new Date(iso); if (isNaN(d)) return ''; return d.toLocaleDateString('en-US', Object.assign({ weekday: 'short', day: 'numeric', month: 'short' }, NY)) + ' ' + d.toLocaleTimeString('en-US', Object.assign({ hour: 'numeric', minute: '2-digit' }, NY)); };
  // the file's own date is the PC's local time; the page shows New York time (HOME and Sessions do the same)
  const localIso = s => { const m = /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)$/.exec(s || ''); return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]).toISOString() : ''; };
  const typeTxt = t => /offline testing/i.test(t || '') ? 'Test' : /open qualify|lone qualify/i.test(t || '') ? 'Qualify' : (t || '');
  const KIND = { full: 'LAP', off: 'LAP', out: 'OUT-LAP', in: 'IN-LAP', pit: 'PIT', partial: 'PART LAP' };
  const KCOL = { full: 'rgba(242,194,48,.30)', off: 'rgba(255,178,30,.26)', out: 'rgba(127,166,201,.30)', in: 'rgba(127,166,201,.30)', pit: 'rgba(141,138,130,.22)', partial: 'rgba(255,178,30,.30)' };

  // ---------- canvases (stage pixels; the stage itself is scaled to the screen) ----------
  function canvas(id, w, h) {
    const c = document.createElement('canvas'); c.id = id; const dpr = Math.max(1, (window.devicePixelRatio || 1) * scale);
    c.width = Math.round(w * dpr); c.height = Math.round(h * dpr); c.style.width = w + 'px'; c.style.height = h + 'px';
    const g = c.getContext('2d'); g.scale(dpr, dpr); c._g = g; c._w = w; c._h = h; return c;
  }
  const local = (c, e) => { const r = c.getBoundingClientRect(); return [(e.clientX - r.left) / scale, (e.clientY - r.top) / scale]; };

  // ---------- data ----------
  async function get(from, to, hz) {
    if (DATA) { const r = await fetch(DATA, { cache: 'no-store' }); return { code: r.status, j: await r.json() }; }
    let u = '/analysis/raw?id=' + encodeURIComponent(ID);
    if (from != null) u += '&from=' + from.toFixed(2) + '&to=' + to.toFixed(2);
    if (hz) u += '&hz=' + hz.toFixed(2);
    const r = await fetch(u, { cache: 'no-store' }); let j = null; try { j = await r.json(); } catch (e) { }
    return { code: r.status, j };
  }
  // the reply the window is drawn from: the finer one when it covers the window, else the whole drive
  const src = () => Dt && Dt.from <= V.a + 0.05 && Dt.to >= V.b - 0.05 ? Dt : O;
  function idx(d, t) { const a = d.t; let lo = 0, hi = a.length - 1; if (t <= a[0]) return 0; if (t >= a[hi]) return hi; while (lo + 1 < hi) { const m = (lo + hi) >> 1; if (a[m] <= t) lo = m; else hi = m; } return t - a[lo] <= a[hi] - t ? lo : hi; }
  function refine() {
    // a zoomed window is asked again, finer: about 2400 points across it (never more than the file's own rate)
    if (DATA || !O) return;
    const span = V.b - V.a; if (span >= O.total * 0.6) { Dt = null; return; }
    if (Dt && Dt.from <= V.a && Dt.to >= V.b && Dt.span <= span * 3) return;
    clearTimeout(pend);
    pend = setTimeout(async () => {
      const pad = span * 0.5, a = Math.max(0, V.a - pad), b = Math.min(O.total, V.b + pad), hz = Math.min(O.rate, Math.max(1, 2400 / span));
      const my = want = a + ':' + b;
      try { const r = await get(a, b, hz); if (want !== my || r.code !== 200 || !r.j || r.j.error) return; Dt = r.j; Dt.span = b - a; draw(); } catch (e) { }
    }, 140);
  }

  // ---------- the window ----------
  function setView(a, b) {
    const total = O.total, min = 2;
    let w = Math.max(min, Math.min(total, b - a)); a = Math.max(0, Math.min(total - w, a)); b = a + w;
    V.a = a; V.b = b; if (cur < a || cur > b) cur = (a + b) / 2;
    draw(); refine();
  }
  const zoom = (f, at) => { const c = at == null ? (cur >= V.a && cur <= V.b ? cur : (V.a + V.b) / 2) : at, u = (c - V.a) / (V.b - V.a), w = (V.b - V.a) * f; setView(c - u * w, c - u * w + w); };
  const pan = f => { const w = V.b - V.a; setView(V.a + w * f, V.b + w * f); };
  const whole = () => { const s = O.summary || {}; const a = s.from != null ? s.from : 0, b = s.to != null ? s.to : O.total; setView(Math.max(0, a - 2), Math.min(O.total, b + 2)); };

  // ---------- timeline strip ----------
  const TL = { x0: 0, w: 1792, h: 76 };
  const tx = t => TL.x0 + t / O.total * TL.w;
  function drawTimeline() {
    const c = $('tl'), g = c._g; g.clearRect(0, 0, c._w, c._h);
    g.fillStyle = C.band; g.fillRect(0, 18, TL.w, 40);
    // on-track stretches (between "carIn" / "carOut") as a dim base, then the laps, then pit lane, then events
    (O.laps || []).forEach(l => {
      const a = tx(l.from), b = tx(l.to), w = Math.max(2, b - a - 2);
      g.fillStyle = KCOL[l.kind] || KCOL.partial; g.fillRect(a + 1, 18, w, 40);
      const word = (KIND[l.kind] || 'PART LAP') + (l.kind === 'full' || l.kind === 'off' ? ' ' + l.lap : '') + (l.time ? '  ' + lapClock(l.time) : '');
      g.font = '16px ' + FONT; g.textBaseline = 'middle'; g.fillStyle = C.ink;
      const short = (KIND[l.kind] || 'PART').split(' ')[0] + (l.kind === 'full' || l.kind === 'off' ? ' ' + l.lap : '');
      const txt = g.measureText(word).width + 16 <= w ? word : g.measureText(short).width + 12 <= w ? short : '';
      if (txt) { g.textAlign = 'left'; g.fillText(txt, a + 9, 38); }
    });
    O.pits.forEach(p => { g.fillStyle = 'rgba(127,166,201,.55)'; g.fillRect(tx(p[0]), 54, Math.max(2, tx(p[1]) - tx(p[0])), 4); });
    (O.events || []).forEach(e => {
      if (e.k === 'inc') { const x = tx(e.t); g.fillStyle = C.red; g.beginPath(); g.moveTo(x - 6, 4); g.lineTo(x + 6, 4); g.lineTo(x, 15); g.fill(); }
      if (e.k === 'off') { const x = tx(e.t); g.fillStyle = C.amber; g.fillRect(x - 1, 6, 3, 10); }
    });
    // the window on view: a gold bracket
    const a = tx(V.a), b = tx(V.b);
    g.strokeStyle = C.gold; g.lineWidth = 2; g.strokeRect(Math.max(1, a), 15, Math.max(4, Math.min(TL.w - 1, b) - Math.max(1, a)), 46);
    const x = tx(cur); g.fillStyle = C.gold; g.fillRect(x - 1, 12, 2, 52);
    g.font = '15px ' + FONT; g.fillStyle = C.dim; g.textBaseline = 'alphabetic'; g.textAlign = 'left'; g.fillText('0:00', 0, 74); g.textAlign = 'right'; g.fillText(clock(O.total), TL.w, 74);
  }
  function timelineClick(e) {
    const [x] = local($('tl'), e), t = Math.max(0, Math.min(O.total, x / TL.w * O.total));
    const l = (O.laps || []).find(q => t >= q.from && t <= q.to);
    if (l) { const pad = Math.max(1, (l.to - l.from) * 0.03); setView(l.from - pad, l.to + pad); cur = t; draw(); return; }
    const w = V.b - V.a; setView(t - w / 2, t + w / 2); cur = t; draw();
  }

  // ---------- traces ----------
  const TR = { X0: 172, W: 1312 - 172, rows: [] };
  function rows() {
    const d = O, r = [];
    r.push({ k: 'SPEED', u: 'mph', key: 'spd', h: 196, lo: 0, hi: Math.max(60, Math.ceil(((d.summary && d.summary.topMph) || 160) / 20) * 20), col: C.gold, dec: 0 });
    r.push({ k: 'THROTTLE', k2: 'BRAKE', u: '%', key: 'thr', key2: 'brk', h: 124, lo: 0, hi: 1, col: C.green, col2: C.red, pct: true });
    if (d.steer) { let m = 0; d.steer.forEach(v => { if (v != null && Math.abs(v) > m) m = Math.abs(v); }); m = Math.max(90, Math.min(540, Math.ceil(m / 90) * 90)); r.push({ k: 'STEERING', u: '°', key: 'steer', h: 104, lo: -m, hi: m, col: C.ink, dec: 0, mid: true }); }
    if (d.gear) r.push({ k: 'GEAR', u: '', key: 'gear', h: 64, lo: -1.5, hi: 7.5, col: C.steel, dec: 0, step: true });
    if (d.rpm) { let m = 0; d.rpm.forEach(v => { if (v > m) m = v; }); r.push({ k: 'RPM', u: '', key: 'rpm', h: 84, lo: 0, hi: Math.max(1000, Math.ceil(m / 1000) * 1000), col: C.mute, dec: 0 }); }
    let y = 14; r.forEach(q => { q.y = y; y += q.h + 16; });
    TR.rows = r; TR.bottom = y - 16;
  }
  const xOf = t => TR.X0 + (t - V.a) / (V.b - V.a) * TR.W;
  const tOf = x => V.a + (x - TR.X0) / TR.W * (V.b - V.a);
  // one trace, min/max per pixel column, so any zoom draws every sample's extent once; a null (no value) breaks the line
  function plot(g, d, arr, Y, col, width) {
    if (!arr) return;
    const i0 = Math.max(0, idx(d, V.a) - 1), i1 = Math.min(d.t.length - 1, idx(d, V.b) + 1);
    g.beginPath(); g.strokeStyle = col; g.lineWidth = width; g.lineJoin = 'round';
    let col0 = -1e9, mn = 0, mx = 0, first = 0, last = 0, on = false;
    const flush = () => { if (col0 > -1e9) { if (!on) { g.moveTo(col0, first); on = true; } g.lineTo(col0, mn); g.lineTo(col0, mx); g.lineTo(col0, last); } };
    for (let i = i0; i <= i1; i++) {
      const v = arr[i];
      if (v == null || (i > 0 && d.t[i] - d.t[i - 1] > 1)) { flush(); col0 = -1e9; on = false; if (v == null) continue; }   // no value, or a hole in the records: the line breaks
      const px = Math.round(xOf(d.t[i])), y = Y(v);
      if (px !== col0) { flush(); col0 = px; mn = y; mx = y; first = y; } else { if (y < mn) mn = y; if (y > mx) mx = y; }
      last = y;
    }
    flush();
    g.stroke();
  }
  // a filled area down to `base` (the brake pedal): the highest value in each pixel column
  function area(g, d, arr, Y, col, base) {
    if (!arr) return;
    const i0 = Math.max(0, idx(d, V.a) - 1), i1 = Math.min(d.t.length - 1, idx(d, V.b) + 1);
    g.beginPath(); let cx = -1e9, top = 0, open = false;
    const close = () => { if (open) { g.lineTo(cx, top); g.lineTo(cx, base); g.closePath(); open = false; } };
    for (let i = i0; i <= i1; i++) {
      const v = arr[i];
      if (v == null || (i > 0 && d.t[i] - d.t[i - 1] > 1)) { close(); cx = -1e9; if (v == null) continue; }
      const px = Math.round(xOf(d.t[i])), y = Y(v);
      if (px !== cx) { if (open) g.lineTo(cx, top); else { g.moveTo(px, base); open = true; } cx = px; top = y; } else if (y < top) top = y;
    }
    close();
    g.save(); g.globalAlpha = 0.45; g.fillStyle = col; g.fill(); g.restore();
  }
  function drawTraces() {
    const c = $('tr'), g = c._g, d = src(); g.clearRect(0, 0, c._w, c._h);
    g.save(); g.beginPath(); g.rect(TR.X0, 0, TR.W + 1, c._h); g.clip();
    // pit lane: a soft band; lap lines: a hairline with the lap number; incidents and off-tracks: marks at the top
    const ev = O.events || [];
    O.pits.forEach(p => { const a = xOf(p[0]), b = xOf(p[1]); g.fillStyle = 'rgba(127,166,201,.08)'; g.fillRect(a, 0, Math.max(1, b - a), TR.bottom); });
    g.font = '15px ' + FONT; g.textBaseline = 'alphabetic';
    ev.forEach(e => {
      if (e.t < V.a || e.t > V.b) return;
      const x = Math.round(xOf(e.t)) + 0.5;
      if (e.k === 'line') { g.strokeStyle = 'rgba(244,241,234,.30)'; g.lineWidth = 1; g.beginPath(); g.moveTo(x, 0); g.lineTo(x, TR.bottom); g.stroke(); g.fillStyle = C.mute; g.textAlign = 'left'; g.fillText('LAP ' + e.lap + (e.time ? '  ' + lapClock(e.time) : ''), x + 6, 12); }
      if (e.k === 'pitIn' || e.k === 'pitOut') { g.fillStyle = C.steel; g.textAlign = 'left'; g.fillText(e.k === 'pitIn' ? 'PIT LANE' : 'TRACK', x + 6, TR.bottom - 6); }
      if (e.k === 'inc') { g.strokeStyle = C.red; g.lineWidth = 2; g.beginPath(); g.moveTo(x, 0); g.lineTo(x, TR.bottom); g.stroke(); g.fillStyle = C.red; g.textAlign = 'left'; g.fillText('+' + e.n + 'x', x + 6, 30); }
      if (e.k === 'off') { const b = xOf(e.t + (e.dur || 0)); g.fillStyle = 'rgba(255,178,30,.16)'; g.fillRect(x, 0, Math.max(2, b - x), TR.bottom); }
    });
    g.restore();
    TR.rows.forEach(r => {
      const Y = v => r.y + r.h - (Math.max(r.lo, Math.min(r.hi, v)) - r.lo) / (r.hi - r.lo) * r.h;
      g.strokeStyle = C.line; g.lineWidth = 1; g.beginPath(); g.moveTo(TR.X0, r.y + r.h + 0.5); g.lineTo(TR.X0 + TR.W, r.y + r.h + 0.5); g.stroke();
      if (r.mid) { g.strokeStyle = '#1c1c20'; g.beginPath(); g.moveTo(TR.X0, Y(0) + 0.5); g.lineTo(TR.X0 + TR.W, Y(0) + 0.5); g.stroke(); }
      g.font = '15px ' + FONT; g.fillStyle = C.mute; g.textAlign = 'left'; g.textBaseline = 'alphabetic';
      g.fillText(r.k + (r.u && !r.pct ? ' ' + r.u : ''), 0, r.y + 14);
      if (r.k2) { g.fillStyle = C.mute; g.fillText(r.k2, 0, r.y + 70); }
      g.save(); g.beginPath(); g.rect(TR.X0, r.y - 1, TR.W + 1, r.h + 2); g.clip();
      if (r.key2) { area(g, d, d[r.key2], Y, r.col2, Y(0)); plot(g, d, d[r.key2], Y, r.col2, 1.2); }
      plot(g, d, d[r.key], Y, r.col, r.key === 'spd' ? 2 : 1.5);
      g.restore();
    });
    // the time axis: whole seconds, every 1 / 5 / 10 / 30 / 60 s
    const span = V.b - V.a, steps = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]; let st = steps[steps.length - 1];
    for (const s of steps) if (span / s <= 12) { st = s; break; }
    g.font = '15px ' + FONT; g.fillStyle = C.dim; g.textAlign = 'center';
    for (let t = Math.ceil(V.a / st) * st; t <= V.b; t += st) { const x = xOf(t); if (x < TR.X0 + 20 || x > TR.X0 + TR.W - 20) continue; g.fillText(st >= 1 ? mmss(t) : clock(t), x, TR.bottom + 24); }
  }
  function drawCursor() {
    // the cursor line and the value at it, next to each trace name (big numbers, like the workbench)
    const c = $('tr'), g = c._o; if (!g) return; g.clearRect(0, 0, c._w, c._h);
    const d = src(), i = idx(d, cur), x = Math.round(xOf(cur)) + 0.5;
    if (x >= TR.X0 && x <= TR.X0 + TR.W) { g.strokeStyle = C.gold; g.lineWidth = 1; g.beginPath(); g.moveTo(x, 0); g.lineTo(x, TR.bottom); g.stroke(); }
    g.textBaseline = 'alphabetic'; g.textAlign = 'left';
    TR.rows.forEach(r => {
      const v = d[r.key] ? d[r.key][i] : null;
      g.font = '28px ' + FONT; g.fillStyle = r.col;
      g.fillText(val(r, v), 0, r.y + 46);
      if (r.key2) { const v2 = d[r.key2] ? d[r.key2][i] : null; g.fillStyle = r.col2; g.fillText(val(r, v2), 0, r.y + 102); }
    });
    readouts(d, i);
    drawMap(d, i);
    const tl = $('tl'); if (tl && O) drawTimeline();
  }
  const val = (r, v) => v == null ? DASH : r.pct ? Math.round(v * 100) + ' %' : r.step ? (v < -0.5 ? 'R' : v < 0.5 ? 'N' : String(Math.round(v))) : (r.dec ? v.toFixed(r.dec) : String(Math.round(v)));

  // ---------- map ----------
  let MP = null;
  function mapFit() {
    MP = null; const d = O; if (!d.lat || !d.lon) return;
    const pts = []; let lat0 = null;
    for (let i = 0; i < d.t.length; i++) { const la = d.lat[i], lo = d.lon[i]; if (!la || !lo || (d.on && d.on[i] === 0)) continue; if (lat0 == null) lat0 = la; pts.push([i, la, lo]); }
    if (pts.length < 20) return;
    const k = 111320, cl = Math.cos(lat0 * Math.PI / 180), lon0 = pts[0][2];
    let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
    const xy = pts.map(p => { const x = (p[2] - lon0) * k * cl, y = (p[1] - lat0) * 110540; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; return [p[0], x, y]; });
    const W = 448, H = 300, pad = 18, sc = Math.min((W - 2 * pad) / Math.max(1, x1 - x0), (H - 2 * pad) / Math.max(1, y1 - y0)), ox = (W - (x1 - x0) * sc) / 2, oy = (H - (y1 - y0) * sc) / 2;
    MP = { lat0, lon0, cl, k, sc, ox, oy, x0, y0, H, pts: xy.map(p => [p[0], ox + (p[1] - x0) * sc, H - (oy + (p[2] - y0) * sc)]) };
  }
  const mapXY = (la, lo) => [MP.ox + ((lo - MP.lon0) * MP.k * MP.cl - MP.x0) * MP.sc, MP.H - (MP.oy + ((la - MP.lat0) * 110540 - MP.y0) * MP.sc)];
  function drawMap(d, i) {
    const c = $('mp'), g = c._g; g.clearRect(0, 0, c._w, c._h);
    g.fillStyle = C.band; g.fillRect(0, 0, c._w, c._h);
    if (!MP) {
      // no GPS in the file: where on the lap, as a bar
      const p = d.pct ? d.pct[i] : null; g.font = '18px ' + FONT; g.fillStyle = C.mute; g.textAlign = 'left'; g.fillText('WHERE ON THE LAP', 20, 40);
      g.fillStyle = '#1c1c20'; g.fillRect(20, 140, 408, 10); if (p != null) { g.fillStyle = C.gold; g.beginPath(); g.arc(20 + p * 408, 145, 10, 0, 7); g.fill(); g.fillStyle = C.ink; g.fillText(Math.round(p * 100) + ' %', 20, 190); }
      return;
    }
    g.lineCap = 'round'; g.lineJoin = 'round';
    g.lineWidth = 6; g.strokeStyle = '#2a2a2e'; g.beginPath(); MP.pts.forEach((p, k) => { if (k && O.t[p[0]] - O.t[MP.pts[k - 1][0]] < 3) g.lineTo(p[1], p[2]); else g.moveTo(p[1], p[2]); }); g.stroke();
    // the window in gold
    g.lineWidth = 3; g.strokeStyle = 'rgba(242,194,48,.7)'; g.beginPath(); let on = false, lt = -1;
    MP.pts.forEach(p => { const t = O.t[p[0]]; if (t < V.a || t > V.b) { on = false; return; } if (on && t - lt < 3) g.lineTo(p[1], p[2]); else g.moveTo(p[1], p[2]); on = true; lt = t; });
    g.stroke();
    const la = d.lat ? d.lat[i] : null, lo = d.lon ? d.lon[i] : null;
    if (la && lo) { const q = mapXY(la, lo); g.beginPath(); g.fillStyle = C.gold; g.strokeStyle = '#000'; g.lineWidth = 2; g.arc(q[0], q[1], 8, 0, 7); g.fill(); g.stroke(); }
  }

  // ---------- values at the cursor ----------
  // which lap the moment belongs to, in words: an out-lap is lap 0 in the file, Peter calls it the out-lap
  function lapWord(t, n) { const l = (O.laps || []).find(q => t >= q.from && t <= q.to + 0.05); if (!l) return n == null ? DASH : 'Lap ' + n; return l.kind === 'out' ? 'Out-lap' : l.kind === 'in' ? 'In-lap' : l.kind === 'pit' ? 'Pit lap' : l.kind === 'partial' ? 'Part of lap ' + l.lap : 'Lap ' + l.lap; }
  function readouts(d, i) {
    const box = $('ro'); if (!box) return;
    const n = (a, f) => a && a[i] != null ? f(a[i]) : DASH;
    const lapNo = d.lap && d.lap[i] != null ? d.lap[i] : null, pct = d.pct && d.pct[i] != null ? d.pct[i] : null;
    const where = d.on && d.on[i] === 0 ? 'Not on track' : d.pit && d.pit[i] === 1 ? 'Pit lane' : 'On track';
    const wheels = ['lf', 'rf', 'lr', 'rr'].every(k => d[k]) ? '<small>front</small> ' + n(d.lf, Math.round) + ' ' + n(d.rf, Math.round) + ' <small>rear</small> ' + n(d.lr, Math.round) + ' ' + n(d.rr, Math.round) : DASH;
    const fuel = d.fuel && d.fuel[i] != null ? (d.fuel[i] / 3.785411784).toFixed(2) + '<small>gal</small>' : DASH;
    const rowsH = [
      ['Time', clock(d.t[i]) + '<small>into the drive</small>'],
      ['Lap', lapWord(d.t[i], lapNo) + (pct != null ? '<small>' + (pct * 100).toFixed(1) + ' % round</small>' : '')],
      ['Where', where],
      ['Cornering', n(d.latG, v => Math.abs(v).toFixed(2)) + '<small>g</small>'],
      ['Accel / brake', n(d.longG, v => (v < 0 ? '−' : '') + Math.abs(v).toFixed(2)) + '<small>g</small>'],
      ['Wheels mph', wheels],
      ['Fuel', fuel]];
    box.innerHTML = '<table>' + rowsH.map(r => '<tr><td class="n">' + r[0] + '</td><td class="v">' + r[1] + '</td></tr>').join('') + '</table>';
  }

  function draw() { if (!O) return; drawTraces(); drawCursor(); }

  // ---------- the page ----------
  function build() {
    const s = O.summary || {};
    const sub = [O.car, typeTxt(s.type), dayTxt(localIso(s.date)), s.onTrackSec ? clock(s.onTrackSec) + ' on track' : '', s.miles != null ? s.miles.toFixed(1) + ' mi' : ''].filter(Boolean).join(DOT);
    const laps = s.laps || {}, lw = [];
    if (laps.full) lw.push(laps.full + (laps.full === 1 ? ' full lap' : ' full laps')); if (laps.out) lw.push(laps.out + (laps.out === 1 ? ' out-lap' : ' out-laps')); if (laps.in) lw.push(laps.in + (laps.in === 1 ? ' in-lap' : ' in-laps')); if (laps.partial) lw.push(laps.partial + (laps.partial === 1 ? ' part lap' : ' part laps')); if (laps.pit) lw.push(laps.pit + ' through the pits');
    const sum1 = [lw.join(', ') || 'no lap', laps.best ? 'best <b>' + lapClock(laps.best) + '</b>' : ''].filter(Boolean).join(DOT);
    const sum2 = ['top <b>' + (s.topMph != null ? Math.round(s.topMph) + ' mph' : DASH) + '</b>', s.fuelUsedGal != null ? 'fuel <b>' + s.fuelUsedGal.toFixed(2) + ' gal</b>' : '', s.incidents != null ? '<b>' + s.incidents + '</b> ' + (s.incidents === 1 ? 'incident' : 'incidents') : '', s.offTracks ? '<b>' + s.offTracks + '</b> off track' : ''].filter(Boolean).join(DOT);
    stage.innerHTML = '<div class="head"><div class="where"><b>' + esc(O.track || DASH) + (O.config && !/^(full|full course|grand prix)$/i.test(O.config) ? ' <small style="font-size:28px;color:var(--mute)">' + esc(O.config) + '</small>' : '') + '</b><span>' + esc(sub) + '</span></div>' +
      '<div class="tag">All the data</div></div>' +
      '<div class="ro" id="ro"></div>' +
      '<div class="bar"><button class="btn" id="bOut" type="button">− Zoom out</button><button class="btn" id="bIn" type="button">+ Zoom in</button>' +
      '<button class="btn" id="bBack" type="button" aria-label="Back in time">◀</button><button class="btn" id="bOn" type="button" aria-label="On in time">▶</button>' +
      '<button class="btn wide" id="bAll" type="button">Whole drive</button><div class="sum">' + sum1 + '<br>' + sum2 + '</div></div>';
    const tl = canvas('tl', 1792, 76), tr = canvas('tr', 1312, 690), tro = canvas('tro', 1312, 690), mp = canvas('mp', 448, 300);
    tro.style.left = '64px'; tro.style.top = '246px'; tro.style.pointerEvents = 'none'; tr._o = tro._g;
    stage.appendChild(tl); stage.appendChild(tr); stage.appendChild(tro); stage.appendChild(mp);
    rows(); mapFit();
    $('bOut').onclick = () => zoom(2); $('bIn').onclick = () => zoom(0.5); $('bBack').onclick = () => pan(-0.5); $('bOn').onclick = () => pan(0.5); $('bAll').onclick = whole;
    tl.addEventListener('click', timelineClick);
    let drag = null;
    tr.addEventListener('mousedown', e => { const [x] = local(tr, e); if (x >= TR.X0) drag = { x, a: V.a, b: V.b, moved: false }; });
    addEventListener('mouseup', () => { drag = null; });
    tr.addEventListener('mousemove', e => {
      const [x] = local(tr, e);
      if (drag) { const dx = x - drag.x; if (Math.abs(dx) > 4) drag.moved = true; if (drag.moved) { const dt = dx / TR.W * (drag.a - drag.b); setView(drag.a + dt, drag.b + dt); return; } }
      if (x >= TR.X0) { cur = Math.max(V.a, Math.min(V.b, tOf(x))); drawCursor(); }
    });
    tr.addEventListener('wheel', e => { e.preventDefault(); const [x] = local(tr, e); zoom(e.deltaY < 0 ? 0.7 : 1.45, x >= TR.X0 ? tOf(x) : null); }, { passive: false });
    addEventListener('keydown', e => {
      if (e.key === 'ArrowLeft') pan(-0.25); else if (e.key === 'ArrowRight') pan(0.25); else if (e.key === '+' || e.key === '=' || e.key === 'ArrowUp') zoom(0.5); else if (e.key === '-' || e.key === 'ArrowDown') zoom(2); else if (e.key === 'Home') whole();
      else if (e.key === 'Escape' && parent !== window) parent.postMessage({ irdash: 'workbench-close' }, location.origin);
    });
  }

  // the pit-lane stretches, from the pit channel itself (a drive that starts in the pit box has no "pit lane" event at its start)
  function pitSpans(d) {
    const out = []; if (!d.pit) return out; let a = null;
    for (let i = 0; i < d.t.length; i++) {
      const p = d.pit[i] === 1 && !(d.on && d.on[i] === 0);
      if (p && a == null) a = d.t[i];
      if ((!p || i === d.t.length - 1 || d.t[i + 1] - d.t[i] > 1) && a != null) { out.push([a, d.t[i]]); a = null; }
    }
    return out;
  }

  function say(big, small) { stage.innerHTML = '<div class="msg"><b>' + esc(big) + '</b>' + (small ? '<span>' + esc(small) + '</span>' : '') + '</div>'; }

  async function load() {
    say('Reading the drive');
    if (!ID && !DATA) { say('No drive chosen'); return; }
    let r; try { r = await get(); } catch (e) { r = null; }
    if (!r || !r.j || r.code !== 200 || r.j.error) {
      const e = r && r.j && r.j.error;
      say(r && r.code === 503 ? 'Not while driving' : e || 'This drive could not be read', ID);
      return;
    }
    O = r.j; O.summary = O.summary || {};
    O.pits = pitSpans(O);
    build();
    // where to open: a lap asked for (another page's "show this lap"), a window asked for, else the whole drive
    const lapN = parseInt(P.get('lap'), 10), f = parseFloat(P.get('from')), t = parseFloat(P.get('to'));
    const l = isFinite(lapN) ? (O.laps || []).find(q => q.lap === lapN) : null;
    if (isFinite(f) && isFinite(t)) setView(f, t);
    else if (l) { const pad = Math.max(1, (l.to - l.from) * 0.03); setView(l.from - pad, l.to + pad); }
    else whole();
    cur = (V.a + V.b) / 2; draw();
    window.Raw.ready = true;
  }
  window.Raw = { ready: false, data: () => O, detail: () => Dt, view: () => ({ a: V.a, b: V.b, cur }), setView: (a, b) => setView(a, b), cursor: t => { cur = t; drawCursor(); }, zoom, pan, whole };
  load();
})();
