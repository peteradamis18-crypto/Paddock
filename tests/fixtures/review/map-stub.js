// A stand-in for W4-2's app/lib/map.js (the same API: mount / colour / marks / cursor / cars / unmount) until it lands, for
// tests\review-card-test.ps1 only. It records every call, asks for the outline once (as the real one does: the request budget),
// and draws a plain made-up loop (NOT Road Atlanta) coloured by the gain and the numbered marks, so the pictures show where things go.
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const pt = (p, R, cx, cy) => { const a = p * Math.PI * 2 - Math.PI / 2, r = R * (1 + 0.22 * Math.sin(2 * a) + 0.12 * Math.cos(3 * a)); return [cx + r * Math.cos(a), cy + r * Math.sin(a)]; };
export const Map = {
  calls: [], el: null, cv: null, gain: null, mk: [],
  mount(el, o) {
    this.calls.push(['mount', o]);
    if (window.__noMap) throw new Error('no map here');
    fetch('/trackmap?key=' + encodeURIComponent(o.key) + '&id=' + encodeURIComponent(o.id)).catch(() => { });
    this.el = el; this.gain = null; this.mk = [];
    const s = Math.max(200, o.size || 600), cv = this.cv = document.createElement('canvas');
    cv.width = s; cv.height = s; cv.className = 'map-stub'; el.appendChild(cv);
    this.draw();
  },
  colour(g) { this.calls.push(['colour', g.length]); this.gain = g; this.draw(); },
  marks(m) { this.calls.push(['marks', m.map(x => x.n + '@' + x.p).join(' ')]); this.mk = m; this.draw(); },
  cursor(p) { this.calls.push(['cursor', p]); },
  cars(c) { this.calls.push(['cars', c.length]); },
  unmount() { this.calls.push(['unmount']); if (this.cv) this.cv.remove(); this.cv = null; this.el = null; },
  draw() {
    const cv = this.cv; if (!cv) return;
    const g = cv.getContext('2d'), s = cv.width, R = s * 0.36, c = s / 2, N = 200;
    g.clearRect(0, 0, s, s); g.lineCap = 'round';
    g.lineWidth = 22; g.strokeStyle = css('--panel'); g.beginPath();
    for (let i = 0; i <= N; i++) { const q = pt(i / N, R, c, c); i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1]); } g.stroke();
    g.lineWidth = 8;
    for (let i = 0; i < N; i++) {
      const p = i / N, v = this.gain && this.gain.length ? this.gain[Math.floor(p * this.gain.length)] : 0;
      g.strokeStyle = v > 0.004 ? css('--gain') : v < -0.004 ? css('--loss') : css('--dim');
      const a = pt(p, R, c, c), b = pt((i + 1) / N, R, c, c);
      g.beginPath(); g.moveTo(a[0], a[1]); g.lineTo(b[0], b[1]); g.stroke();
    }
    g.font = '600 24px Bahnschrift, Segoe UI, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
    for (const m of this.mk) {
      const q = pt(m.p, R, c, c), o = pt(m.p, R * 1.2, c, c);
      g.fillStyle = css('--bg'); g.strokeStyle = css('--ink'); g.lineWidth = 3;
      g.beginPath(); g.arc(o[0], o[1], 22, 0, Math.PI * 2); g.fill(); g.stroke();
      g.fillStyle = css('--ink'); g.fillText(String(m.n), o[0], o[1] + 1);
      g.beginPath(); g.moveTo(q[0], q[1]); g.stroke();
    }
  },
};
export default Map;
