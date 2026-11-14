/* map.js (W4-2): the ONE track map of REVIEW, as a module. The drawing is v2/map.js's TrackMap (fit with a 90 degree turn when that
   makes it bigger, the layered road: dark casing, thin light edge, dark surface, the start/finish tick, the pit lane dashed), built
   once into an offscreen layer; here it takes its colours from design.css and adds what REVIEW needs on top.
     Map.mount(el, { key, id, size })  key like "t127-roadatlanta-full", id the track id; size = px (square) or { w, h }, else el's size.
                                       One fetch of /trackmap (irdash answers from Peter's telemetry, else iRacing's own drawing from
                                       data/iracing-maps by track id, else the library). No outline: one retry after 5 s, then the plain
                                       words "Map not available". No polling.
     Map.colour(gain)                  gain[] spread over the lap (index = lap fraction * length): + gains green, - losses red, 0 ink
     Map.marks([{ n, p }])             the numbered gold marks 1, 2, 3 at lap fractions p
     Map.cursor(p)                     the one cursor dot (the chart's cursor, as a lap fraction)
     Map.cars([{ p, me }])             positions for the race story (me in gold)
     Map.unmount()
   The v2 copy keeps the race pages' live behaviour (retries, cars from telemetry); this one is for still pictures of a lap. */

const RETRY_MS = 5000;
let st = null;

function tok(name) { return getComputedStyle(document.documentElement).getPropertyValue('--' + name).trim(); }
function fin(v) { return typeof v === 'number' && isFinite(v); }

function at(pct) {
  const P = st.pts, N = P.length, f = ((pct % 1) + 1) % 1 * N, i = Math.floor(f) % N, t = f - Math.floor(f);
  const a = P[i], b = P[(i + 1) % N];
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
}
function fit(w, h) {
  let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
  for (const p of st.pts) { if (p[0] < x0) x0 = p[0]; if (p[0] > x1) x1 = p[0]; if (p[1] < y0) y0 = p[1]; if (p[1] > y1) y1 = p[1]; }
  const pad = 46, tw = x1 - x0 || 1, th = y1 - y0 || 1;
  const sA = Math.min((w - 2 * pad) / tw, (h - 2 * pad) / th), sB = Math.min((w - 2 * pad) / th, (h - 2 * pad) / tw);
  const rot = sB > sA * 1.08;
  return { w, h, s: rot ? sB : sA, rot, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2 };
}
function toScreen(p) {
  const vw = st.view;
  let x = (p[0] - vw.cx) * vw.s, y = -(p[1] - vw.cy) * vw.s;
  if (vw.rot) { const t = x; x = -y; y = t; }
  return [vw.w / 2 + x, vw.h / 2 + y];
}
function where(p) { return toScreen(at(p)); }

function size() {
  const s = st.size;
  if (fin(s) && s > 0) return [s, s];                 // 0 or less (a page measured an element not laid out yet): use the element's size
  if (s && fin(s.w) && fin(s.h) && s.w > 0 && s.h > 0) return [s.w, s.h];
  return [st.el.clientWidth || 600, st.el.clientHeight || 600];
}
function sc() { return Math.max(0.7, Math.min(1.9, Math.min(st.w, st.h) / 440)); }
function line(g, pts, closed) { g.beginPath(); pts.forEach((q, i) => (i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1]))); if (closed) g.closePath(); }
function canvasFor(c) {
  const dpr = window.devicePixelRatio || 1;
  if (c.width !== Math.round(st.w * dpr) || c.height !== Math.round(st.h * dpr)) { c.width = Math.round(st.w * dpr); c.height = Math.round(st.h * dpr); }
  const g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, st.w, st.h);
  g.lineJoin = 'round'; g.lineCap = 'round';
  return g;
}

// the road, once (v2/map.js buildLayer, in design.css colours)
function buildOutline() {
  const g = canvasFor(st.layer), k = sc(), col = st.col;
  st.scr = st.pts.map(toScreen);
  if (st.pit) { line(g, st.pit.map(toScreen), false); g.setLineDash([5, 6]); g.strokeStyle = col.dim; g.lineWidth = 3 * k; g.stroke(); g.setLineDash([]); }
  line(g, st.scr, true); g.strokeStyle = col.bg; g.lineWidth = 24 * k; g.stroke();
  line(g, st.scr, true); g.globalAlpha = 0.8; g.strokeStyle = col.ink; g.lineWidth = 14 * k; g.stroke();
  g.globalAlpha = 1; line(g, st.scr, true); g.strokeStyle = col.panel; g.lineWidth = 11.4 * k; g.stroke();
  // start / finish: a short white bar across the road
  const a = where(0), b = where(0.002), dx = b[0] - a[0], dy = b[1] - a[1], m = Math.hypot(dx, dy) || 1, nx = -dy / m, ny = dx / m, len = 15 * k;
  g.beginPath(); g.moveTo(a[0] - nx * len, a[1] - ny * len); g.lineTo(a[0] + nx * len, a[1] + ny * len); g.strokeStyle = col.ink; g.lineWidth = 4 * k; g.stroke();
}

// the gain colours along the road: + green, - red, 0 ink; stronger the bigger the number (four steps, so a few strokes do it)
function buildColour() {
  const g = canvasFor(st.paint);
  const gain = st.gain;
  if (!gain || !gain.length) return;
  let max = 0;
  for (let i = 0; i < gain.length; i++) if (fin(gain[i]) && Math.abs(gain[i]) > max) max = Math.abs(gain[i]);
  const N = st.scr.length, k = sc();
  const pick = i => {
    const v = gain[Math.min(gain.length - 1, Math.floor(i / N * gain.length))];
    if (!fin(v) || max === 0 || Math.abs(v) < max * 0.05) return 'z';
    return (v > 0 ? 'g' : 'l') + Math.min(3, Math.floor(Math.abs(v) / max * 4));
  };
  const style = { z: [st.col.ink, 0.35] };
  for (let q = 0; q < 4; q++) { style['g' + q] = [st.col.gain, 0.45 + 0.55 * q / 3]; style['l' + q] = [st.col.loss, 0.45 + 0.55 * q / 3]; }
  g.lineWidth = 7.5 * k;
  let i = 0;
  while (i < N) {
    const s = pick(i); let j = i;
    while (j + 1 < N && pick(j + 1) === s) j++;
    g.beginPath(); g.moveTo(st.scr[i][0], st.scr[i][1]);
    for (let q = i + 1; q <= j + 1; q++) { const P = st.scr[q % N]; g.lineTo(P[0], P[1]); }
    g.strokeStyle = style[s][0]; g.globalAlpha = style[s][1]; g.stroke();
    i = j + 1;
  }
  g.globalAlpha = 1;
}

function draw() {
  if (!st) return;
  st.raf = 0;
  if (document.hidden) { st.waiting = true; return; }
  st.waiting = false;
  const dpr = window.devicePixelRatio || 1, cv = st.cv;
  if (cv.width !== Math.round(st.w * dpr) || cv.height !== Math.round(st.h * dpr)) { cv.width = Math.round(st.w * dpr); cv.height = Math.round(st.h * dpr); }
  const g = cv.getContext('2d');
  g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, cv.width, cv.height);
  if (!st.pts) return;
  if (st.layerDirty) { buildOutline(); st.layerDirty = false; st.paintDirty = true; }
  if (st.paintDirty) { buildColour(); st.paintDirty = false; }
  g.drawImage(st.layer, 0, 0); g.drawImage(st.paint, 0, 0);
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  const col = st.col, k = sc();
  // cars: the field small and quiet, Peter in gold on top
  const cars = st.carList.slice().sort((a, b) => (!!a.me) - (!!b.me));
  for (const c of cars) {
    if (!fin(c.p)) continue;
    const [x, y] = where(c.p), r = (c.me ? 13 : 9) * Math.max(1, k * 0.8);
    g.beginPath(); g.arc(x, y, r + 3, 0, Math.PI * 2); g.fillStyle = col.bg; g.fill();
    g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fillStyle = c.me ? col.gold : col.muted; g.fill();
  }
  // the numbered marks: a gold ring round a dark centre, the number in gold, big enough from the seat
  const R = Math.round(20 * Math.max(1, k * 0.85));
  for (const m of st.markList) {
    if (!fin(m.p)) continue;
    const [x, y] = where(m.p);
    g.beginPath(); g.arc(x, y, R + 3, 0, Math.PI * 2); g.fillStyle = col.bg; g.fill();
    g.beginPath(); g.arc(x, y, R, 0, Math.PI * 2); g.fillStyle = col.panel; g.fill();
    g.lineWidth = 3.5; g.strokeStyle = col.gold; g.stroke();
    g.fillStyle = col.gold; g.font = '700 ' + Math.max(26, Math.round(R * 1.3)) + 'px ' + col.font; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText(String(m.n), x, y + 1);
  }
  // the cursor: one ink dot with a dark ring, the same place as the chart's line
  if (fin(st.cur)) {
    const [x, y] = where(st.cur), r = 9 * Math.max(1, k * 0.8);
    g.beginPath(); g.arc(x, y, r + 4, 0, Math.PI * 2); g.fillStyle = col.bg; g.fill();
    g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fillStyle = col.ink; g.fill();
  }
  st.frames++;
}
function schedule() { if (st && !st.raf) st.raf = requestAnimationFrame(draw); }
function onVisible() { if (st && st.waiting && !document.hidden) schedule(); }

function say(text) { st.word.textContent = text; st.word.hidden = !text; }

async function load(key) {
  let data = null;
  try {
    const r = await fetch('/trackmap?key=' + encodeURIComponent(st.key) + '&id=' + encodeURIComponent(st.id), { cache: 'no-store' });
    if (r.status === 200) data = await r.json();
  } catch (e) { data = null; }           // irdash restarting: the one retry covers it
  if (!st || st.token !== key) return;
  const g = data && data.gps && Array.isArray(data.gps.pts) && data.gps.pts.length >= 100 ? data.gps : null;
  const pts = data && Array.isArray(data.pts) && data.pts.length >= 200 ? data.pts : g ? g.pts : null;
  if (pts) {
    st.pts = pts; st.pit = Array.isArray(data.pit) && data.pit.length >= 20 ? data.pit : null;
    st.source = data.pts === pts ? data.source || '' : 'gps';
    st.view = fit(st.w, st.h); st.layerDirty = true; st.status = 'ready'; say(''); schedule();
    return;
  }
  st.tries++;
  if (st.tries < 2) { st.status = 'retrying'; st.timer = setTimeout(() => load(key), RETRY_MS); return; }
  st.status = 'missing'; say('Map not available');
}

const TrackMapView = {
  mount(el, o) {
    if (st) TrackMapView.unmount();
    o = o || {};
    const cv = document.createElement('canvas');
    cv.style.display = 'block';
    const word = document.createElement('div');
    word.className = 'map-word'; word.hidden = true;
    word.style.cssText = 'position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:var(--t-body);color:var(--muted)';
    if (getComputedStyle(el).position === 'static') el.style.position = 'relative';
    el.append(cv, word);
    st = { el, cv, word, key: o.key || '', id: o.id != null ? String(o.id) : '', size: o.size, pts: null, pit: null, source: '', view: null,
      layer: document.createElement('canvas'), paint: document.createElement('canvas'), layerDirty: true, paintDirty: true,
      gain: null, markList: [], carList: [], cur: NaN, raf: 0, timer: 0, tries: 0, status: 'loading', frames: 0, token: {}, col: {} };
    for (const k of ['bg', 'panel', 'ink', 'muted', 'dim', 'gold', 'gain', 'loss']) st.col[k] = tok(k);
    st.col.font = tok('font') || 'sans-serif';
    [st.w, st.h] = size();
    cv.style.width = st.w + 'px'; cv.style.height = st.h + 'px';
    cv.width = Math.round(st.w * (window.devicePixelRatio || 1)); cv.height = Math.round(st.h * (window.devicePixelRatio || 1));
    document.addEventListener('visibilitychange', onVisible);
    load(st.token);
    return TrackMapView;
  },
  colour(gain) { if (!st) return; st.gain = gain ? Array.from(gain) : null; st.paintDirty = true; schedule(); },
  marks(list) { if (!st) return; st.markList = (list || []).filter(m => m && fin(m.p)); schedule(); },
  cursor(p) { if (!st || p === st.cur) return; st.cur = p; schedule(); },
  cars(list) { if (!st) return; st.carList = (list || []).filter(c => c && fin(c.p)); schedule(); },
  unmount() {
    if (!st) return;
    clearTimeout(st.timer); if (st.raf) cancelAnimationFrame(st.raf);
    document.removeEventListener('visibilitychange', onVisible);
    st.cv.remove(); st.word.remove();
    st = null;
  },
  // for a page that lines things up with the map (and for tests): canvas [x, y] of a lap fraction, null until the outline is in
  where(p) { return st && st.pts ? where(p) : null; },
  get status() { return st ? st.status : ''; },
  get frames() { return st ? st.frames : 0; },
};
export { TrackMapView as Map };
export default TrackMapView;
