/* clock.js (W3-2, docs/rework/PLAN.md 4.1): the one analog dial, used by HOME (centre zone) and the start-up.
   Copied from a watch face, not a widget (evidence 07: "time first, few complications, empty space on purpose"):
   warm-white baton indices (the quarters longer), a fine minute track, no numerals, no brand; hour and minute hands
   in --ink, a gold seconds hand with a counterweight that sweeps smoothly; one readout under 12; a thin gold ring
   that closes clockwise from 12 (HOME: the last 30 minutes before a start, the Formula E escalation).
     Clock.mount(el, { size: 720, ring: 0..1|null, readout: string|null }) -> handle { set, unmount }
     Clock.set({ ring, readout })   Clock.unmount()     act on the dial mounted last (HOME's)
     Clock.now = () => new Date()   replaceable: tests pass a fixed time; local time always
   Cost: the face (track, indices, readout) is drawn once into a cache; a frame is one copy + the ring + three hands.
   Frames run on requestAnimationFrame only while the page is visible, and stop when it is hidden.
   Colours come from design.css through getComputedStyle (no colour is written in this file). */

const TAU = Math.PI * 2;
let current = null;                     // the handle Clock.set / Clock.unmount act on

function tokens(el) {
  const cs = getComputedStyle(el);
  const v = (k) => cs.getPropertyValue(k).trim();
  return { bg: v('--bg'), panel: v('--panel'), line: v('--line'), ink: v('--ink'), muted: v('--muted'), dim: v('--dim'),
    gold: v('--gold'), goldDim: v('--gold-dim'), font: v('--font') || 'sans-serif',
    title: parseFloat(v('--t-title')) || 56, body: parseFloat(v('--t-body')) || 24, track: v('--track') };
}

// a dauphine hand (the dress-watch hand): a long faceted leaf to a point, widest near the centre, with a short tail.
// Two facets, the right one a shade darker, so the hand reads as a polished ridge rather than a flat stick.
function dauphine(g, T, len, w, tail) {
  const wide = -len * 0.1, base = w * 0.2;
  g.fillStyle = T.ink;
  g.beginPath(); g.moveTo(0, -len); g.lineTo(-w / 2, wide); g.lineTo(-base, tail); g.lineTo(0, tail); g.closePath(); g.fill();
  g.beginPath(); g.moveTo(0, -len); g.lineTo(w / 2, wide); g.lineTo(base, tail); g.lineTo(0, tail); g.closePath(); g.fill();
  g.globalAlpha = 0.24; g.fillStyle = T.bg;
  g.beginPath(); g.moveTo(0, -len); g.lineTo(w / 2, wide); g.lineTo(base, tail); g.lineTo(0, tail); g.closePath(); g.fill();
  g.globalAlpha = 1;
}
function pill(g, x, y, w, h) {
  const r = w / 2;
  g.beginPath(); g.moveTo(x, y + r); g.arc(x + r, y + r, r, Math.PI, 0); g.lineTo(x + w, y + h - r); g.arc(x + r, y + h - r, r, 0, Math.PI); g.closePath(); g.fill();
}

function mount(el, opts) {
  opts = opts || {};
  const S = opts.size || 720;
  const dpr = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
  const cv = document.createElement('canvas');
  cv.className = 'clock-dial';
  cv.width = Math.round(S * dpr); cv.height = Math.round(S * dpr);
  cv.style.width = S + 'px'; cv.style.height = S + 'px'; cv.style.display = 'block';
  cv.setAttribute('role', 'img');
  el.appendChild(cv);
  const g = cv.getContext('2d');
  const cache = document.createElement('canvas');
  cache.width = cv.width; cache.height = cv.height;
  const T = tokens(el);

  // geometry, as fractions of the size so HOME and the start-up share one drawing at any size
  const k = S / 720, c = S / 2;
  const G = { ringR: 352 * k, ringW: 5 * k, bezelR: 338 * k, trackO: 328 * k, trackI: 316 * k,
    idxO: 328 * k, idxI: 278 * k, qI: 246 * k, idxW: 9 * k, qW: 13 * k };

  const h = { el: el, cv: cv, ring: null, readout: null, raf: 0, frames: 0, cost: 0, dead: false };

  function drawFace() {
    const f = cache.getContext('2d');
    f.setTransform(dpr, 0, 0, dpr, 0, 0);
    f.clearRect(0, 0, S, S);
    // the dial: a near-black disc that falls off to the page black at the bezel (depth without a picture)
    const grad = f.createRadialGradient(c, c * 0.86, 0, c, c, G.bezelR);
    grad.addColorStop(0, T.panel); grad.addColorStop(1, T.bg);
    f.fillStyle = grad;
    f.beginPath(); f.arc(c, c, G.bezelR, 0, TAU); f.fill();
    f.strokeStyle = T.line; f.lineWidth = 2 * k;
    f.beginPath(); f.arc(c, c, G.bezelR, 0, TAU); f.stroke();
    f.save(); f.translate(c, c);
    // the minute track: 60 fine marks, quiet so the hours read first
    f.fillStyle = T.dim;
    for (let i = 0; i < 60; i++) {
      if (i % 5 === 0) continue;
      f.save(); f.rotate(i * TAU / 60);
      f.fillRect(-1.25 * k, -G.trackO, 2.5 * k, G.trackO - G.trackI);
      f.restore();
    }
    // the hour indices: applied batons, the quarters longer and wider; 12 is a pair so the dial has a top
    f.fillStyle = T.ink;
    for (let i = 0; i < 12; i++) {
      const q = i % 3 === 0, w = q ? G.qW : G.idxW, inner = q ? G.qI : G.idxI;
      f.save(); f.rotate(i * TAU / 12);
      if (i === 0) {
        const gap = 7 * k;
        f.fillRect(-gap / 2 - w, -G.idxO, w, G.idxO - inner);
        f.fillRect(gap / 2, -G.idxO, w, G.idxO - inner);
      } else {
        f.fillRect(-w / 2, -G.idxO, w, G.idxO - inner);
      }
      f.restore();
    }
    // the one readout under 12: a quiet caps label over the value ("NEXT GREEN FLAG" / "1:42:09"), else one line
    if (h.readout) {
      const txt = String(h.readout).trim();
      const m = /^(.*\S)\s+(\S*\d\S*)$/.exec(txt);
      const label = m ? m[1] : '', value = m ? m[2] : txt;
      f.textAlign = 'center'; f.textBaseline = 'alphabetic';
      const vy = -G.qI + 150 * k;
      let vs = T.title * k;
      f.font = '400 ' + vs + 'px ' + T.font;
      while (f.measureText(value).width > 420 * k && vs > T.body * k) { vs -= 2; f.font = '400 ' + vs + 'px ' + T.font; }
      f.fillStyle = T.ink;
      f.fillText(value, 0, vy);
      if (label) {
        const ls = T.body * k;
        f.font = '600 ' + ls + 'px ' + T.font;
        if ('letterSpacing' in f) f.letterSpacing = (0.08 * ls).toFixed(1) + 'px';
        f.fillStyle = T.muted;
        f.fillText(label.toUpperCase(), 0, vy - vs - 10 * k);
        if ('letterSpacing' in f) f.letterSpacing = '0px';
      }
    }
    f.restore();
  }

  function draw() {
    const t0 = performance.now();
    const now = Clock.now();
    const ms = now.getMilliseconds(), s = now.getSeconds() + ms / 1000, m = now.getMinutes() + s / 60, hr = (now.getHours() % 12) + m / 60;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, S, S);
    g.drawImage(cache, 0, 0, S, S);
    // the ring: a faint track and the gold arc closing clockwise from 12
    if (h.ring != null) {
      const p = Math.max(0, Math.min(1, +h.ring || 0));
      g.lineWidth = G.ringW; g.lineCap = 'butt';
      g.strokeStyle = T.line;
      g.beginPath(); g.arc(c, c, G.ringR, 0, TAU); g.stroke();
      if (p > 0) {
        g.strokeStyle = T.gold;
        g.beginPath(); g.arc(c, c, G.ringR, -Math.PI / 2, -Math.PI / 2 + p * TAU); g.stroke();
      }
    }
    g.save(); g.translate(c, c);
    // hour, then minute: warm white batons; a dark pinion under the seconds hand
    g.save(); g.rotate(hr * TAU / 12); dauphine(g, T, 200 * k, 30 * k, 26 * k); g.restore();
    g.save(); g.rotate(m * TAU / 60); dauphine(g, T, 312 * k, 22 * k, 30 * k); g.restore();
    g.fillStyle = T.ink;
    g.beginPath(); g.arc(0, 0, 17 * k, 0, TAU); g.fill();
    // seconds: a fine gold needle to the minute track and a long tail ending in a counterweight (the watchmaker's balance)
    g.save(); g.rotate(s * TAU / 60);
    g.fillStyle = T.gold;
    g.fillRect(-2 * k, -318 * k, 4 * k, 318 * k + 60 * k);
    pill(g, -6 * k, 54 * k, 12 * k, 40 * k);
    g.restore();
    g.fillStyle = T.gold;
    g.beginPath(); g.arc(0, 0, 10 * k, 0, TAU); g.fill();
    g.fillStyle = T.bg;
    g.beginPath(); g.arc(0, 0, 3 * k, 0, TAU); g.fill();
    g.restore();
    h.frames++;
    h.cost += performance.now() - t0;
  }

  function loop() { h.raf = 0; if (h.dead || document.hidden) return; draw(); h.raf = requestAnimationFrame(loop); }
  function wake() {
    if (h.dead) return;
    if (document.hidden) { if (h.raf) { cancelAnimationFrame(h.raf); h.raf = 0; } return; }
    if (!h.raf) h.raf = requestAnimationFrame(loop);
  }
  h.wake = wake;
  h.draw = draw;            // tests: one frame on demand (the cost check)
  h.set = function (o) {
    o = o || {};
    let face = false;
    if ('ring' in o) h.ring = o.ring == null ? null : +o.ring;
    if ('readout' in o) { const r = o.readout == null || o.readout === '' ? null : String(o.readout); if (r !== h.readout) { h.readout = r; face = true; } }
    if (face) drawFace();
    cv.setAttribute('aria-label', h.readout ? 'Clock. ' + h.readout : 'Clock');
    if (!document.hidden) draw();
  };
  h.unmount = function () {
    if (h.dead) return;
    h.dead = true;
    if (h.raf) cancelAnimationFrame(h.raf);
    document.removeEventListener('visibilitychange', wake);
    cv.remove();
    if (current === h) current = null;
  };

  document.addEventListener('visibilitychange', wake);
  drawFace();
  h.set({ ring: opts.ring == null ? null : opts.ring, readout: opts.readout == null ? null : opts.readout });
  wake();
  current = h;
  return h;
}

export const Clock = {
  now: function () { return new Date(); },
  mount: mount,
  set: function (o) { if (current) current.set(o); },
  unmount: function () { if (current) current.unmount(); },
  get current() { return current; }
};
export default Clock;
