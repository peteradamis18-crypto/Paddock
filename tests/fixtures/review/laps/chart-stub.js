// A stand-in for W4-2's app/lib/chart.js (the same API: docs/rework/cards/W4-2.md) for tests\review-laps-test.ps1 until it lands.
// It records every call (Chart.calls), draws the rows plainly on a canvas so the pictures show where the stack sits, and writes the
// readout column (both laps' values at the cursor) the way the real one must: always visible, no tooltip.
const css = n => getComputedStyle(document.documentElement).getPropertyValue('--' + n).trim();
const S = { el: null, o: null, cv: null, cur: 0, a: 0, b: 1, fn: null };
function val(arr, m, len) { if (!arr) return NaN; const i = Math.round(m / len * (arr.length - 1)); return arr[Math.max(0, Math.min(arr.length - 1, i))]; }
function draw() {
  if (!S.cv) return;
  const cv = S.cv, W = cv.width = S.el.clientWidth, H = cv.height = S.el.clientHeight, c = cv.getContext('2d'), o = S.o, len = o.x.len;
  c.clearRect(0, 0, W, H);
  const rows = o.rows, top = 28, rh = (H - top) / rows.length, X = m => (m - S.a) / (S.b - S.a) * W;
  c.font = '20px Bahnschrift'; c.textBaseline = 'top';
  (o.corners || []).forEach(k => { const x0 = X(k.p0 * len), x1 = X(k.p1 * len); if (x1 < 0 || x0 > W) return; c.fillStyle = css('panel'); c.fillRect(x0, top, x1 - x0, H - top); c.fillStyle = css('muted'); c.fillText(k.label, x0 + 4, 2); });
  rows.forEach((r, ri) => {
    const y0 = top + ri * rh;
    c.strokeStyle = css('line'); c.beginPath(); c.moveTo(0, y0); c.lineTo(W, y0); c.stroke();
    c.fillStyle = r.key === 'delta' ? css('gold') : css('muted'); c.fillText(r.label, 6, y0 + 4);
    let lo = Infinity, hi = -Infinity;
    r.series.forEach(s => { for (let i = 0; i < s.data.length; i += 4) { const v = s.data[i]; if (v < lo) lo = v; if (v > hi) hi = v; } });
    if (!(hi > lo)) { hi = lo + 1; }
    r.series.forEach(s => {
      c.strokeStyle = css(s.color) || css('ink'); c.lineWidth = s.color === 'ink' ? 1 : 2; c.beginPath();
      const i0 = Math.max(0, Math.floor(S.a / len * (s.data.length - 1))), i1 = Math.min(s.data.length - 1, Math.ceil(S.b / len * (s.data.length - 1)));
      const stepI = Math.max(1, Math.floor((i1 - i0) / W));
      for (let i = i0; i <= i1; i += stepI) { const x = X(i / (s.data.length - 1) * len), y = y0 + rh - 4 - (s.data[i] - lo) / (hi - lo) * (rh - 8); if (i === i0) c.moveTo(x, y); else c.lineTo(x, y); }
      c.stroke();
    });
  });
  c.strokeStyle = css('ink'); c.lineWidth = 1; c.beginPath(); c.moveTo(X(S.cur), top); c.lineTo(X(S.cur), H); c.stroke();
  readout();
}
function readout() {
  const ro = S.o.readout; if (!ro) return;
  const fmt = (r, v) => !isFinite(v) ? '–' : r.key === 'delta' ? (v >= 0 ? '+' : '−') + Math.abs(v).toFixed(3) : r.key === 'gear' ? String(Math.round(v)) : String(Math.round(v));
  ro.innerHTML = S.o.rows.map(r => '<div class="ro-row" data-key="' + r.key + '"><span class="ro-l">' + r.label + (r.unit ? ' ' + r.unit : '') + '</span> ' +
    (r.series.length ? r.series.map(s => '<span class="ro-v" data-c="' + s.color + '">' + fmt(r, val(s.data, S.cur, S.o.x.len)) + '</span>').join(' ') : '<span class="ro-v">' + (r.note || '–') + '</span>') + '</div>').join('');
}
export const Chart = {
  calls: [],
  mount(el, o) {
    Chart.calls.push(['mount', { rows: o.rows.map(r => r.key), len: o.x.len, corners: (o.corners || []).length, readout: o.readout, series: o.rows.map(r => r.series.map(s => s.color)) }]);
    S.el = el; S.o = o; S.a = 0; S.b = o.x.len; S.cur = 0;
    S.cv = document.createElement('canvas'); S.cv.style.cssText = 'position:absolute;inset:0;width:100%;height:100%'; el.appendChild(S.cv);
    el.addEventListener('wheel', e => { e.preventDefault(); const w = (S.b - S.a) * (e.deltaY < 0 ? 0.5 : 2); Chart.setRange(S.cur - w / 2, S.cur + w / 2); }, { passive: false });
    el.addEventListener('click', e => { const r = el.getBoundingClientRect(); Chart.setCursor(S.a + (e.clientX - r.left) / r.width * (S.b - S.a)); if (S.fn) S.fn(S.cur); });
    draw(); return Chart;
  },
  update(rows) { Chart.calls.push(['update', rows.map(r => r.key)]); S.o.rows = rows; draw(); },
  setCursor(m) { Chart.calls.push(['setCursor', m]); S.cur = m; draw(); },
  setRange(a, b) { Chart.calls.push(['setRange', a, b]); S.a = Math.max(0, a); S.b = Math.min(S.o.x.len, b); draw(); },
  zoomCorner(n) { Chart.calls.push(['zoomCorner', n]); const k = S.o.corners.find(c => c.n === n); if (k) { S.a = Math.max(0, k.p0 * S.o.x.len - 60); S.b = Math.min(S.o.x.len, k.p1 * S.o.x.len + 60); } draw(); },
  zoomLap() { Chart.calls.push(['zoomLap']); S.a = 0; S.b = S.o.x.len; draw(); },
  onCursor(fn) { Chart.calls.push(['onCursor']); S.fn = fn; },
  unmount() { Chart.calls.push(['unmount']); if (S.cv) S.cv.remove(); S.cv = null; },
  state() { return { cur: S.cur, a: S.a, b: S.b }; },
};
export default Chart;
