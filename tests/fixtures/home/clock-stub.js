// A stand-in for W3-2's app/lib/clock.js with the same API (Clock.mount / set / unmount / now), used by tests\home-test.ps1
// until the real one lands. It draws a plain dial so the pictures read right, and records every call.
export const Clock = {
  calls: [], el: null, cv: null, opts: { ring: null, readout: null },
  now() { return window.__now; },
  mount(el, o) { this.calls.push(['mount', o]); this.el = el; this.opts = Object.assign({ ring: null, readout: null }, o || {});
    const cv = document.createElement('canvas'); cv.width = 720; cv.height = 720; el.appendChild(cv); this.cv = cv; this.draw(); },
  set(o) { this.calls.push(['set', o]); Object.assign(this.opts, o || {}); this.draw(); },
  unmount() { this.calls.push(['unmount']); if (this.cv) this.cv.remove(); this.cv = null; this.el = null; },
  draw() {
    if (!this.cv) return;
    const g = this.cv.getContext('2d'), cs = getComputedStyle(document.documentElement), tok = n => cs.getPropertyValue(n).trim();
    const c = 360, d = new Date(this.now()); g.clearRect(0, 0, 720, 720);
    g.strokeStyle = tok('--line'); g.lineWidth = 2; g.beginPath(); g.arc(c, c, 330, 0, Math.PI * 2); g.stroke();
    for (let i = 0; i < 12; i++) { const a = i * Math.PI / 6, l = i % 3 ? 22 : 44; g.strokeStyle = tok('--ink'); g.lineWidth = i % 3 ? 4 : 8;
      g.beginPath(); g.moveTo(c + Math.sin(a) * (310 - l), c - Math.cos(a) * (310 - l)); g.lineTo(c + Math.sin(a) * 310, c - Math.cos(a) * 310); g.stroke(); }
    const hand = (a, len, w, col) => { g.strokeStyle = col; g.lineWidth = w; g.lineCap = 'round'; g.beginPath(); g.moveTo(c - Math.sin(a) * 30, c + Math.cos(a) * 30); g.lineTo(c + Math.sin(a) * len, c - Math.cos(a) * len); g.stroke(); };
    const h = d.getHours() % 12, m = d.getMinutes(), s = d.getSeconds();
    hand((h + m / 60) * Math.PI / 6, 170, 12, tok('--ink')); hand((m + s / 60) * Math.PI / 30, 260, 8, tok('--ink')); hand(s * Math.PI / 30, 290, 3, tok('--gold'));
    g.fillStyle = tok('--gold'); g.beginPath(); g.arc(c, c, 9, 0, Math.PI * 2); g.fill();
    if (this.opts.ring != null) { g.strokeStyle = tok('--gold'); g.lineWidth = 6; g.beginPath(); g.arc(c, c, 346, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * this.opts.ring); g.stroke(); }
    if (this.opts.readout) { g.fillStyle = tok('--ink'); g.font = '56px ' + tok('--font'); g.textAlign = 'center'; g.fillText(this.opts.readout.replace('NEXT GREEN FLAG ', ''), c, 250);
      g.fillStyle = tok('--muted'); g.font = '600 24px ' + tok('--font'); g.fillText('NEXT GREEN FLAG', c, 190); }
  }
};
export default Clock;
