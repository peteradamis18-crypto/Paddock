/* chart.js (W4-2): the ONE trace engine of REVIEW. The MoTeC / Delta stack: every row on one distance axis, the delta row first
   in gold (it tells Peter where to look), then speed, pedals, steering, gear; corner bands and names along the top; one cursor line
   across every row; a readout column that always shows the cursor's values in big type (no mouse-only tooltips, he reads from the seat).
     Chart.mount(el, { x: { len, unit: 'm' }, rows: [{ key, label, unit, kind: 'line'|'step', min?, max?, weight?,
                     series: [{ label, color: 'gold'|'ink'|'gain'|'loss'|..., data: Float32Array, alpha?, width? }] }],
                     corners: [{ n, label, p0, pa, p1 }], readout: el2 })      p0/pa/p1 are lap fractions (as /analysis/channels sends them)
     Chart.setCursor(m)  Chart.setRange(a, b)  Chart.zoomCorner(n)  Chart.zoomLap()  Chart.onCursor(fn)  Chart.update(rows)  Chart.unmount()
     Chart.fromPwb(arrayBuffer, { units: 'mph'|'km/h' }) -> rows (rows.x, rows.corners, rows.head ride along)
   The readout element sits beside el with the same top: its blocks are placed at the rows' heights so a value lines up with its trace.
   Drawing: the rows, bands and traces go into one offscreen layer, rebuilt only when the range, the data or the size changes; a
   cursor move copies that layer and draws one line. Nothing is drawn while the page is hidden (it catches up when shown).
   Colours come only from design.css tokens (read once at mount). Data is on the 1 m grid: sample i is at i * len / (n - 1) metres. */

const BAND_H = 56;      // corner names along the top (24 px text)
const AXIS_H = 40;      // distance labels along the bottom (24 px text)
const GAP = 12;         // between rows
const PAD_X = 8;
const MIN_SPAN = 40;    // metres: the closest zoom
const WEIGHT = { delta: 1.5, gear: 0.7 };

let st = null;          // the one mounted chart (REVIEW shows one stack at a time)

function tok(name) { return getComputedStyle(document.documentElement).getPropertyValue('--' + name).trim(); }
function colourOf(c) {
  const name = String(c || 'ink').replace(/^var\(--|\)$/g, '').replace(/^--/, '');
  return (st && st.col[name]) || (st.col[name] = tok(name)) || st.col.ink;
}
function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
function fin(v) { return typeof v === 'number' && isFinite(v); }

// a value at metres m (linear between samples; a step row holds its value)
function valueAt(data, m, kind) {
  if (!data || !data.length) return NaN;
  const f = m / st.step;
  if (kind === 'step') return data[clamp(Math.round(f), 0, data.length - 1)];
  const i = Math.floor(f);
  if (i < 0) return data[0];
  if (i >= data.length - 1) return data[data.length - 1];
  const a = data[i], b = data[i + 1];
  return a + (b - a) * (f - i);
}

function fmt(row, v) {
  if (!fin(v)) return '–';
  if (row.fmt) return row.fmt(v);
  const u = row.unit || '';
  if (row.key === 'gear' || row.kind === 'step') return v < -0.5 ? 'R' : Math.round(v) === 0 ? 'N' : String(Math.round(v));
  if (u === 's') return (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(3);
  if (u === 'deg') return (v < 0 ? '−' : '') + Math.abs(Math.round(v));
  return String(Math.round(v));
}

// ---------- layout ----------
// readout lines: two values a line (this lap, reference); a row is never shorter than its values side by side with its name
const VAL_H = 42, LAB_H = 30;
function valLines(r) { return Math.ceil(Math.max(1, r.series.length) / 2); }
function layout() {
  const w = st.cv.clientWidth, h = st.cv.clientHeight;
  st.w = w; st.h = h;
  st.x0 = PAD_X; st.x1 = Math.max(PAD_X + 10, w - PAD_X);
  const top = BAND_H, bottom = h - AXIS_H, n = st.rows.length;
  const avail = Math.max(10, bottom - top - GAP * Math.max(0, n - 1));
  const ws = st.rows.map(r => r.weight || WEIGHT[r.key] || 1), hs = ws.map(() => 0), fixed = ws.map(() => false);
  for (let pass = 0; pass <= n; pass++) {
    let free = avail, wsum = 0, changed = false;
    st.rows.forEach((r, i) => { if (fixed[i]) free -= hs[i]; else wsum += ws[i]; });
    st.rows.forEach((r, i) => {
      if (fixed[i]) return;
      hs[i] = Math.max(0, free) * ws[i] / (wsum || 1);
      const need = valLines(r) * VAL_H + 4;
      if (hs[i] < need) { hs[i] = need; fixed[i] = true; changed = true; }
    });
    if (!changed) break;
  }
  let y = top;
  st.box = st.rows.map((r, i) => { const b = { key: r.key, y0: y, y1: y + hs[i], tall: hs[i] >= LAB_H + valLines(r) * VAL_H }; y += hs[i] + GAP; return b; });
  placeReadout();
}

// y range of a row over the whole lap (so zooming never rescales a row under his eyes)
function yRange(r) {
  if (fin(r.min) && fin(r.max)) return [r.min, r.max];
  let lo = Infinity, hi = -Infinity;
  for (const s of r.series) { const d = s.data; if (!d) continue; for (let i = 0; i < d.length; i++) { const v = d[i]; if (v < lo) lo = v; if (v > hi) hi = v; } }
  if (!fin(lo)) { lo = 0; hi = 1; }
  if (r.key === 'delta') { const m = Math.max(Math.abs(lo), Math.abs(hi), 0.05); lo = -m; hi = m; }
  if (r.kind === 'step') { lo -= 0.5; hi += 0.5; }
  if (fin(r.min)) lo = r.min; if (fin(r.max)) hi = r.max;
  const pad = (hi - lo) * 0.08 || 1;
  return [lo - (fin(r.min) ? 0 : pad), hi + (fin(r.max) ? 0 : pad)];
}

function xOf(m) { return st.x0 + (m - st.a) / (st.b - st.a) * (st.x1 - st.x0); }
function mOf(x) { return st.a + (x - st.x0) / (st.x1 - st.x0) * (st.b - st.a); }

// ---------- the static layer: rows, bands, grid, traces ----------
function renderLayer() {
  const t0 = performance.now();
  const dpr = window.devicePixelRatio || 1, w = st.w, h = st.h;
  const L = st.layer;
  if (L.width !== Math.round(w * dpr) || L.height !== Math.round(h * dpr)) { L.width = Math.round(w * dpr); L.height = Math.round(h * dpr); }
  const g = L.getContext('2d');
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.globalAlpha = 1; g.fillStyle = st.col.bg; g.fillRect(0, 0, w, h);
  const top = BAND_H, bottom = h - AXIS_H, font = st.col.font;

  // corner bands across every row, the corner's name at its apex along the top
  g.font = '600 24px ' + font; g.textAlign = 'center'; g.textBaseline = 'middle';
  let lastRight = -1e9;
  for (const c of st.corners) {
    const d0 = c.p0 * st.len, d1 = (c.p1 > c.p0 ? c.p1 : 1) * st.len, da = c.pa * st.len;
    if (d1 < st.a || d0 > st.b) continue;
    const xa = xOf(d0), xb = xOf(d1);
    g.globalAlpha = 0.06; g.fillStyle = st.col.ink; g.fillRect(xa, top, Math.max(1, xb - xa), bottom - top);
    g.globalAlpha = 0.5; g.fillStyle = st.col.ink; g.fillRect(xOf(da) - 0.5, top - 8, 1, 8);
    const text = c.label || ('T' + c.n), tw = g.measureText(text).width, xc = clamp(xOf(da), st.x0 + tw / 2, st.x1 - tw / 2);
    if (xc - tw / 2 > lastRight + 10) { g.globalAlpha = 1; g.fillStyle = st.col.muted; g.fillText(text, xc, top / 2); lastRight = xc + tw / 2; }
  }

  // distance grid: a round step at least 160 px apart
  const span = st.b - st.a, steps = [10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000];
  let stepM = steps[steps.length - 1];
  for (const s of steps) if (s / span * (st.x1 - st.x0) >= 160) { stepM = s; break; }
  g.textBaseline = 'middle'; g.font = '24px ' + font;
  for (let m = Math.ceil(st.a / stepM) * stepM; m <= st.b; m += stepM) {
    const x = Math.round(xOf(m)) + 0.5;
    g.globalAlpha = 1; g.strokeStyle = st.col.line; g.lineWidth = 1;
    g.beginPath(); g.moveTo(x, top); g.lineTo(x, bottom); g.stroke();
    g.fillStyle = st.col.dim; g.textAlign = x < st.x0 + 60 ? 'left' : x > st.x1 - 60 ? 'right' : 'center';
    g.fillText(m + ' m', x, bottom + AXIS_H / 2 + 2);
  }

  const i0 = Math.max(0, Math.floor(st.a / st.step) - 1), i1 = Math.min(st.n - 1, Math.ceil(st.b / st.step) + 1);
  st.rows.forEach((r, k) => {
    const b = st.box[k], yr = st.yr[k], yOf = v => b.y1 - (v - yr[0]) / (yr[1] - yr[0]) * (b.y1 - b.y0);
    g.save(); g.beginPath(); g.rect(st.x0, b.y0, st.x1 - st.x0, b.y1 - b.y0); g.clip();
    // the row's floor, and zero where zero means something (delta, steering)
    g.globalAlpha = 1; g.fillStyle = st.col.line; g.fillRect(st.x0, Math.round(b.y1) - 1, st.x1 - st.x0, 1);
    if (yr[0] < 0 && yr[1] > 0) { g.fillStyle = st.col.dim; g.fillRect(st.x0, Math.round(yOf(0)), st.x1 - st.x0, 1); }
    if (r.key === 'delta' && r.series[0]) { columns(r.series[0].data, r.kind); shadeDelta(g, yOf); }
    r.series.forEach((s, j) => {
      if (!s.data) return;
      g.globalAlpha = s.alpha != null ? s.alpha : 1;
      const col = colourOf(s.color || (j ? 'ink' : 'gold')), wid = s.width || (r.key === 'delta' ? 4 : j % 2 ? 2.2 : 2.8);
      if (r.kind === 'step') { g.strokeStyle = col; g.lineWidth = wid; g.lineJoin = 'miter'; g.beginPath(); pathStep(g, s.data, i0, i1, yOf); g.stroke(); return; }
      columns(s.data, r.kind);
      g.fillStyle = col; ribbon(g, yOf, wid / 2); g.fill();
    });
    g.restore();
  });
  g.globalAlpha = 1;
  st.layerDirty = false; st.layers++;
  st.layerMs = performance.now() - t0;
}

// A trace is drawn as a ribbon, one filled shape per lap: for every pixel column the lowest and highest value the lap takes in it
// (interpolated at the column's two edges plus every sample between), widened by half the line width. Exact peaks at any zoom, and
// one fill instead of thousands of stroked joins: a stroked 4000-point lap with sensor noise cost 9 ms a frame here, the ribbon a
// fraction of that. A NaN (a part lap that was not driven there) leaves a gap.
function columns(d, kind) {
  const W = Math.max(1, Math.ceil(st.x1 - st.x0));
  if (!st.cLo || st.cLo.length < W) { st.cLo = new Float32Array(W); st.cHi = new Float32Array(W); }
  const lo = st.cLo, hi = st.cHi, mpp = (st.b - st.a) / (st.x1 - st.x0), n = d.length;
  const at = f => { if (f <= 0) return d[0]; if (f >= n - 1) return d[n - 1]; const i = Math.floor(f), a = d[i]; return a + (d[i + 1] - a) * (f - i); };
  let fA = st.a / st.step, vA = at(fA);
  for (let c = 0; c < W; c++) {
    const fB = (st.a + (c + 1) * mpp) / st.step, vB = at(fB);
    let l = vA < vB ? vA : vB, h = vA < vB ? vB : vA;
    for (let i = Math.max(0, Math.ceil(fA)), e = Math.min(n - 1, Math.floor(fB)); i <= e; i++) { const v = d[i]; if (v < l) l = v; else if (v > h) h = v; else if (v !== v) l = NaN; }
    if (vA !== vA || vB !== vB) l = NaN;
    lo[c] = l; hi[c] = h; fA = fB; vA = vB;
  }
  st.cW = W;
}
function ribbon(g, yOf, half) {
  const lo = st.cLo, hi = st.cHi, W = st.cW, x0 = st.x0;
  g.beginPath();
  let c = 0;
  while (c < W) {
    while (c < W && lo[c] !== lo[c]) c++;
    if (c >= W) break;
    let e = c; while (e + 1 < W && lo[e + 1] === lo[e + 1]) e++;
    g.moveTo(x0 + c, yOf(hi[c]) - half);
    for (let k = c; k <= e; k++) g.lineTo(x0 + k + 0.5, yOf(hi[k]) - half);
    g.lineTo(x0 + e + 1, yOf(hi[e]) - half); g.lineTo(x0 + e + 1, yOf(lo[e]) + half);
    for (let k = e; k >= c; k--) g.lineTo(x0 + k + 0.5, yOf(lo[k]) + half);
    g.lineTo(x0 + c, yOf(lo[c]) + half); g.closePath();
    c = e + 1;
  }
}

function pathStep(g, d, i0, i1, yOf) {
  let prev = NaN, pen = false;
  for (let i = i0; i <= i1; i++) {
    const v = d[i]; if (!fin(v)) { pen = false; prev = NaN; continue; }
    if (v === prev && i !== i1) continue;
    const x = xOf(i * st.step), y = yOf(v);
    if (!pen) { g.moveTo(x, y); pen = true; } else { g.lineTo(x, yOf(prev)); g.lineTo(x, y); }
    prev = v;
  }
}
// where this lap is behind (delta above zero) the band down to zero is loss red, where it is ahead gain green (from columns())
function shadeDelta(g, yOf) {
  const lo = st.cLo, hi = st.cHi, W = st.cW, x0 = st.x0, z = yOf(0);
  g.globalAlpha = 0.28;
  for (const [loss, col] of [[true, st.col.loss], [false, st.col.gain]]) {
    g.beginPath(); g.moveTo(x0, z);
    for (let c = 0; c < W; c++) {
      const v = (lo[c] + hi[c]) / 2, y = v === v ? yOf(v) : z;
      g.lineTo(x0 + c + 0.5, loss ? Math.min(y, z) : Math.max(y, z));
    }
    g.lineTo(x0 + W, z); g.closePath();
    g.fillStyle = col; g.fill();
  }
  g.globalAlpha = 1;
}

// ---------- each frame: the layer plus the cursor ----------
function compose() {
  const t0 = performance.now();
  const dpr = window.devicePixelRatio || 1, cv = st.cv;
  if (cv.width !== Math.round(st.w * dpr) || cv.height !== Math.round(st.h * dpr)) { cv.width = Math.round(st.w * dpr); cv.height = Math.round(st.h * dpr); }
  const g = cv.getContext('2d');
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.drawImage(st.layer, 0, 0);
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  if (st.cursor >= st.a && st.cursor <= st.b) {
    const x = Math.round(xOf(st.cursor)) + 0.5;
    g.globalAlpha = 1; g.strokeStyle = st.col.ink; g.lineWidth = 2;
    g.beginPath(); g.moveTo(x, BAND_H - 10); g.lineTo(x, st.h - AXIS_H); g.stroke();
    st.rows.forEach((r, k) => {
      const b = st.box[k], yr = st.yr[k];
      r.series.forEach((s, j) => {
        const v = valueAt(s.data, st.cursor, r.kind); if (!fin(v)) return;
        const y = clamp(b.y1 - (v - yr[0]) / (yr[1] - yr[0]) * (b.y1 - b.y0), b.y0, b.y1);
        g.beginPath(); g.arc(x, y, 5, 0, Math.PI * 2);
        g.globalAlpha = 1; g.fillStyle = colourOf(s.color || (j ? 'ink' : 'gold')); g.fill();
        g.lineWidth = 2; g.strokeStyle = st.col.bg; g.stroke();
      });
    });
  }
  st.dirty = false; st.frames++;
  st.frameMs = performance.now() - t0;
  writeReadout();
}

// ---------- the readout column ----------
const CSS = '.chro{position:relative;font-family:var(--font);font-variant-numeric:tabular-nums}' +
  '.chro-top,.chro-row,.chro-key{position:absolute;left:0;right:0;display:flex;overflow:hidden}' +
  '.chro-top{top:0;align-items:center;column-gap:20px}.chro-m{font-size:var(--t-read);color:var(--ink)}' +
  '.chro-c{font-size:var(--t-body);color:var(--muted);letter-spacing:var(--track)}' +
  '.chro-row{flex-direction:column;justify-content:center}' +
  '.chro-row.flat{flex-direction:row;align-items:center;justify-content:space-between;column-gap:16px}' +
  '.chro-l{font-size:var(--t-body);color:var(--muted);letter-spacing:var(--track);text-transform:uppercase;font-weight:600;line-height:1.2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}' +
  '.chro-l i{font-style:normal;text-transform:none;letter-spacing:0;font-weight:400;color:var(--dim);margin-left:8px}' +
  '.chro-vals{display:grid;grid-template-columns:repeat(2,2.8em);column-gap:20px;justify-content:end;font-size:var(--t-read);flex:none}' +
  '.chro-v{font-size:var(--t-read);line-height:1.15;text-align:right;white-space:nowrap}.chro-v.wide{grid-column:span 2}' +
  '.chro-key{bottom:0;align-items:center;justify-content:flex-end}' +
  '.chro-k{font-size:var(--t-body);text-align:right;letter-spacing:var(--track);text-transform:uppercase;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}';
function tokName(c) { return String(c || 'ink').replace(/^var\(--|\)$/g, '').replace(/^--/, ''); }
function placeReadout() {
  const ro = st.readout; if (!ro) return;
  if (!st.roBuilt) {
    if (!document.getElementById('chro-css')) { const s = document.createElement('style'); s.id = 'chro-css'; s.textContent = CSS; document.head.appendChild(s); }
    const mk = (tag, cls, text) => { const e = document.createElement(tag); e.className = cls; if (text != null) e.textContent = text; return e; };
    ro.classList.add('chro'); ro.textContent = '';
    st.ro = { top: mk('div', 'chro-top'), m: mk('span', 'chro-m'), c: mk('span', 'chro-c'), rows: [], key: null };
    st.ro.top.append(st.ro.m, st.ro.c); ro.appendChild(st.ro.top);
    st.rows.forEach(r => {
      const d = mk('div', 'chro-row'); d.dataset.key = r.key;
      const l = mk('span', 'chro-l', r.label || r.key.toUpperCase());
      if (r.unit) l.appendChild(mk('i', '', r.unit));
      const box = mk('div', 'chro-vals');
      const vals = r.series.map((s, j) => {
        const v = mk('span', 'chro-v' + (r.series.length === 1 ? ' wide' : '')); v.dataset.series = String(j);
        v.style.color = 'var(--' + tokName(s.color || (j ? 'ink' : 'gold')) + ')';
        if (s.alpha != null && s.alpha < 1) v.style.opacity = String(Math.max(0.6, s.alpha));
        box.appendChild(v); return v;
      });
      d.append(l, box); ro.appendChild(d); st.ro.rows.push({ el: d, vals });
    });
    // which column is which lap, once, under the values (from the first row that has both laps)
    const pair = st.rows.find(r => r.key !== 'delta' && r.series.length === 2);
    if (pair) {
      const key = mk('div', 'chro-key'), box = mk('div', 'chro-vals');
      pair.series.forEach((s, j) => { const k = mk('span', 'chro-k', s.label || ''); k.style.color = 'var(--' + tokName(s.color || (j ? 'ink' : 'gold')) + ')'; box.appendChild(k); });
      key.appendChild(box); ro.appendChild(key); st.ro.key = key;
    }
    st.roBuilt = true;
  }
  ro.style.height = st.h + 'px';
  st.ro.top.style.height = BAND_H + 'px';
  if (st.ro.key) st.ro.key.style.height = AXIS_H + 'px';
  st.box.forEach((b, k) => {
    const e = st.ro.rows[k].el; e.style.top = b.y0 + 'px'; e.style.height = (b.y1 - b.y0) + 'px';
    e.classList.toggle('flat', !b.tall);     // too short for the name over the values: the name goes beside them
  });
}
function writeReadout() {
  if (!st.ro) return;
  const m = st.cursor;
  st.ro.m.textContent = Math.round(m) + ' m';
  const c = cornerAt(m);
  st.ro.c.textContent = c ? (c.label || 'T' + c.n) : '';
  st.rows.forEach((r, k) => r.series.forEach((s, j) => { st.ro.rows[k].vals[j].textContent = fmt(r, valueAt(s.data, m, r.kind)); }));
}
function cornerAt(m) {
  const p = m / st.len;
  for (const c of st.corners) { const p1 = c.p1 > c.p0 ? c.p1 : 1; if (p >= c.p0 && p <= p1) return c; }
  return null;
}

// ---------- scheduling: draw on change only, never while hidden ----------
function shown() { return !document.hidden && st.cv.isConnected && st.cv.clientWidth > 0 && st.cv.clientHeight > 0; }
function schedule() {
  if (!st || st.raf) return;
  st.raf = requestAnimationFrame(() => { if (st) { st.raf = 0; flush(); } });
}
function flush() {
  if (!st) return;
  if (!shown()) { st.waiting = true; return; }
  st.waiting = false;
  if (st.cv.clientWidth !== st.w || st.cv.clientHeight !== st.h) { layout(); st.layerDirty = true; }
  if (st.layerDirty) { renderLayer(); st.dirty = true; }
  if (st.dirty) compose();
}
function onVisible() { if (st && st.waiting && !document.hidden) schedule(); }

function setCursorM(m, quiet) {
  if (!st || !fin(m)) return;
  m = clamp(m, 0, st.len);
  if (m === st.cursor) return;
  st.cursor = m; st.dirty = true; schedule();
  if (!quiet) st.listeners.forEach(fn => { try { fn(m); } catch (e) { console.warn('chart cursor', e); } });
}
function setRangeM(a, b) {
  if (!st || !fin(a) || !fin(b)) return;
  if (b < a) { const t = a; a = b; b = t; }
  let span = Math.max(MIN_SPAN, Math.min(st.len, b - a));
  const mid = (a + b) / 2;
  a = clamp(mid - span / 2, 0, st.len - span); b = a + span;
  if (a === st.a && b === st.b) return;
  st.a = a; st.b = b; st.layerDirty = true; schedule();
}

function prep(rows) {
  return rows.map(r => Object.assign({ series: [] }, r, { series: (r.series || []).filter(s => s && s.data) }));
}

export const Chart = {
  mount(el, o) {
    if (st) Chart.unmount();
    o = o || {};
    const rows = prep(o.rows || []);
    const n0 = rows.reduce((m, r) => Math.max(m, ...r.series.map(s => s.data.length)), 0) || 2;
    const len = (o.x && o.x.len) || n0 - 1;
    const cv = document.createElement('canvas');
    cv.style.display = 'block'; cv.style.width = '100%'; cv.style.height = '100%'; cv.style.touchAction = 'none';
    el.appendChild(cv);
    st = {
      el, cv, layer: document.createElement('canvas'), readout: o.readout || null, rows, corners: (o.corners || []).slice().sort((a, b) => a.pa - b.pa),
      len, n: n0, step: len / Math.max(1, n0 - 1), a: 0, b: len, cursor: 0, listeners: [], col: {}, raf: 0,
      layerDirty: true, dirty: true, frames: 0, layers: 0, frameMs: 0, layerMs: 0, w: 0, h: 0, box: [], roBuilt: false,
    };
    for (const k of ['bg', 'ink', 'muted', 'dim', 'line', 'gold', 'gain', 'loss', 'panel']) st.col[k] = tok(k);
    st.col.font = tok('font') || 'sans-serif';
    st.yr = rows.map(yRange);
    // drag moves the cursor; the wheel zooms around it (the deck's arrows arrive through the page as zoomCorner/zoomLap/setCursor)
    const atX = e => { const r = cv.getBoundingClientRect(); return mOf(clamp(e.clientX - r.left, st.x0, st.x1)); };
    st.down = false;
    st.h_down = e => { st.down = true; try { cv.setPointerCapture(e.pointerId); } catch (x) { } setCursorM(atX(e)); };
    st.h_move = e => { if (st.down) setCursorM(atX(e)); };
    st.h_up = () => { st.down = false; };
    st.h_wheel = e => {
      e.preventDefault();
      const f = e.deltaY > 0 ? 1.25 : 0.8, m = clamp(st.cursor, st.a, st.b);
      setRangeM(m - (m - st.a) * f, m + (st.b - m) * f);
    };
    cv.addEventListener('pointerdown', st.h_down); cv.addEventListener('pointermove', st.h_move);
    cv.addEventListener('pointerup', st.h_up); cv.addEventListener('pointercancel', st.h_up);
    cv.addEventListener('wheel', st.h_wheel, { passive: false });
    document.addEventListener('visibilitychange', onVisible);
    if (typeof ResizeObserver !== 'undefined') { st.ro_obs = new ResizeObserver(() => { if (st) { st.layerDirty = true; schedule(); } }); st.ro_obs.observe(el); }
    layout();
    flush();
    return Chart;
  },
  setCursor(m) { setCursorM(m, false); },
  setRange(a, b) { setRangeM(a, b); },
  zoomCorner(n) {
    if (!st) return;
    const c = st.corners.find(t => t.n === n); if (!c) return;
    const d0 = c.p0 * st.len, d1 = (c.p1 > c.p0 ? c.p1 : 1) * st.len;
    setRangeM(d0 - 60, d1 + 60); setCursorM(c.pa * st.len, false);
  },
  zoomLap() { if (st) setRangeM(0, st.len); },
  onCursor(fn) { if (st && typeof fn === 'function') st.listeners.push(fn); },
  // new data, the same layout (another lap pair): row keys keep their places
  update(rows) {
    if (!st) return;
    const fresh = prep(rows || []);
    st.rows = st.rows.map(r => { const f = fresh.find(x => x.key === r.key); return f ? Object.assign({}, r, { series: f.series }) : r; });
    st.rows.forEach((r, k) => { const vals = st.ro && st.ro.rows[k] && st.ro.rows[k].vals; if (vals && vals.length !== r.series.length) st.roBuilt = false; });
    st.yr = st.rows.map(yRange);
    if (!st.roBuilt && st.readout) placeReadout();
    st.layerDirty = true; schedule();
  },
  unmount() {
    if (!st) return;
    if (st.raf) cancelAnimationFrame(st.raf);
    document.removeEventListener('visibilitychange', onVisible);
    if (st.ro_obs) st.ro_obs.disconnect();
    st.cv.remove();
    if (st.readout) { st.readout.textContent = ''; st.readout.classList.remove('chro'); }
    st = null;
  },
  // draw now if anything changed (tests, and a page that must show the new state before a screenshot)
  flush() { flush(); },
  // where things are, for a page that lines things up with the stack (and for tests)
  xOf(m) { return st ? xOf(m) : NaN; },
  rowsBox() { return st ? st.box.map(b => ({ key: b.key, y0: b.y0, y1: b.y1 })) : []; },
  get range() { return st ? [st.a, st.b] : null; },
  get cursor() { return st ? st.cursor : NaN; },
  get stats() { return st ? { frames: st.frames, layers: st.layers, frameMs: st.frameMs, layerMs: st.layerMs } : null; },

  // The PWB1 reply of /analysis/channels (and /api/review/traces): "PWB1", int32 header length (padding included), the JSON header,
  // then Float32 little-endian arrays of n samples in the header's "arrays" order (lap.t, lap.<ch>..., ref.t, ref.<ch>...).
  fromPwb(buf, o) {
    o = o || {};
    const dv = new DataView(buf);
    if (String.fromCharCode(dv.getUint8(0), dv.getUint8(1), dv.getUint8(2), dv.getUint8(3)) !== 'PWB1') throw new Error('not a PWB1 reply');
    const hl = dv.getInt32(4, true), head = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 8, hl)));
    const arr = {}; let pos = 8 + hl;
    for (const k of head.arrays) { arr[k] = new Float32Array(buf, pos, head.n); pos += head.n * 4; }
    const mph = (o.units || 'mph') !== 'km/h', n = head.n;
    const map = (src, f) => { if (!src) return null; const d = new Float32Array(n); for (let i = 0; i < n; i++) d[i] = src[i] * f; return d; };
    const ok = k => head.channels.some(c => c.key === k && c.ok !== false);
    const has = head.ref != null, A = k => arr['lap.' + k], R = k => (has ? arr['ref.' + k] : null);
    const lapLabel = (info, word) => word + (info && info.n != null ? ' ' + info.n : '');
    const two = (k, f, extra) => {
      const s = [{ label: lapLabel(head.lap, 'Lap'), color: 'gold', data: map(A(k), f) }];
      if (has) s.push({ label: lapLabel(head.ref, 'Lap'), color: 'ink', data: map(R(k), f) });
      return s.map(x => Object.assign(x, extra || {}));
    };
    const rows = [];
    if (has && arr['lap.t'] && arr['ref.t']) {
      const d = new Float32Array(n), a = arr['lap.t'], r = arr['ref.t'];
      for (let i = 0; i < n; i++) d[i] = a[i] - r[i];
      rows.push({ key: 'delta', label: 'DELTA', unit: 's', kind: 'line', series: [{ label: 'this lap', color: 'gold', data: d }] });
    }
    if (ok('Speed')) rows.push({ key: 'speed', label: 'SPEED', unit: mph ? 'mph' : 'km/h', kind: 'line', series: two('Speed', mph ? 2.236936 : 3.6) });
    if (ok('Throttle') || ok('Brake')) {
      const s = [];
      if (ok('Throttle')) { s.push({ label: 'throttle', color: 'gain', data: map(A('Throttle'), 100) }); if (has) s.push({ label: 'throttle, reference', color: 'gain', alpha: 0.5, data: map(R('Throttle'), 100) }); }
      if (ok('Brake')) { s.push({ label: 'brake', color: 'loss', data: map(A('Brake'), 100) }); if (has) s.push({ label: 'brake, reference', color: 'loss', alpha: 0.5, data: map(R('Brake'), 100) }); }
      rows.push({ key: 'pedals', label: 'PEDALS', unit: '%', kind: 'line', min: 0, max: 100, series: s });
    }
    if (ok('SteeringWheelAngle')) rows.push({ key: 'steer', label: 'STEERING', unit: 'deg', kind: 'line', series: two('SteeringWheelAngle', 57.29578) });
    if (ok('Gear')) rows.push({ key: 'gear', label: 'GEAR', unit: '', kind: 'step', series: two('Gear', 1) });
    if (ok('RPM')) rows.push({ key: 'rpm', label: 'RPM', unit: 'rpm', kind: 'line', series: two('RPM', 1) });
    rows.x = { len: head.lengthM, unit: 'm' };
    rows.corners = (head.corners || []).map(c => ({ n: c.n, label: c.official ? 'T' + String(c.official).toUpperCase() : c.label || 'T' + c.n, p0: c.p0, pa: c.pa, p1: c.p1 }));
    rows.head = head;
    return rows;
  },
};
export default Chart;
