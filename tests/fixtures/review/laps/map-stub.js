// A stand-in for W4-2's app/lib/map.js (the same API: docs/rework/cards/W4-2.md) for tests\review-laps-test.ps1 until it lands.
// It records every call (Map.calls) and draws a plain loop, coloured per lap percent, with the one cursor dot.
const css = n => getComputedStyle(document.documentElement).getPropertyValue('--' + n).trim();
const S = { cv: null, gain: null, p: 0 };
function pt(p, W, H) { const a = p * Math.PI * 2 - Math.PI / 2, r = 0.38 + 0.06 * Math.sin(a * 3); return [W / 2 + Math.cos(a) * W * r, H / 2 + Math.sin(a) * H * r * 0.9]; }
function draw() {
  if (!S.cv) return;
  const cv = S.cv, W = cv.width = cv.parentNode.clientWidth, H = cv.height = cv.parentNode.clientHeight, c = cv.getContext('2d');
  c.clearRect(0, 0, W, H); c.lineWidth = 6; c.lineCap = 'round';
  for (let k = 0; k < 100; k++) {
    const g = S.gain ? S.gain[k] : 0; c.strokeStyle = g > 0.004 ? css('gain') : g < -0.004 ? css('loss') : css('ink');
    const a = pt(k / 100, W, H), b = pt((k + 1) / 100, W, H); c.beginPath(); c.moveTo(a[0], a[1]); c.lineTo(b[0], b[1]); c.stroke();
  }
  const d = pt(S.p, W, H); c.fillStyle = css('gold'); c.beginPath(); c.arc(d[0], d[1], 10, 0, Math.PI * 2); c.fill();
}
export const Map = {
  calls: [],
  mount(el, o) { Map.calls.push(['mount', o]); S.cv = document.createElement('canvas'); S.cv.style.cssText = 'position:absolute;inset:0;width:100%;height:100%'; el.appendChild(S.cv); draw(); return Map; },
  colour(g) { Map.calls.push(['colour', g.length]); S.gain = g; draw(); },
  marks(m) { Map.calls.push(['marks', m]); },
  cursor(p) { Map.calls.push(['cursor', p]); S.p = p; draw(); },
  cars(c) { Map.calls.push(['cars', c]); },
  unmount() { Map.calls.push(['unmount']); if (S.cv) S.cv.remove(); S.cv = null; },
};
export default Map;
