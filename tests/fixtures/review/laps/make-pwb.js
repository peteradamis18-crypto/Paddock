// The hand-made traces answer for tests\review-laps-test.ps1: a PWB1 reply exactly as dash\src\workbench.cs writes it ("PWB1",
// int32 header length, the JSON header padded with spaces to a multiple of 4, then Float32 little-endian arrays in "arrays" order)
// for one lap and its reference on a 1 m grid of a 4088 m Road Atlanta, with its corner set. Speed is m/s (iRacing's own unit),
// throttle and brake 0..1, steering in radians, gear a whole number. Every lap is the same base lap plus a loss at T5 that grows
// with the lap's time, so the delta row has a real step there; the time array ends exactly on the lap time (as the server pins it).
(function () {
  const L = 4088, N = L + 1;
  // n, label, apex (fraction), how much slower than flat out (m/s), width (m), steering side
  const T = [[1, 'T1', 0.075, 22, 70, 1], [2, 'T2', 0.135, 10, 60, -1], [3, 'T3', 0.175, 14, 50, 1], [4, 'T4', 0.225, 8, 50, -1],
    [5, 'T5', 0.285, 24, 70, 1], [6, 'T6', 0.365, 20, 60, -1], [7, 'T7', 0.465, 32, 60, 1], [8, 'T8', 0.53, 6, 50, -1],
    [9, 'T9', 0.62, 4, 70, 1], [10, 'T10A', 0.835, 34, 50, 1], [11, 'T10B', 0.865, 18, 40, -1], [12, 'T12', 0.965, 16, 60, 1]];
  const corners = T.map(c => ({ n: c[0], label: c[1], name: '', official: c[1].substring(1).toLowerCase(), p0: +(c[2] - 0.02).toFixed(5), pa: c[2], p1: +(c[2] + 0.02).toFixed(5) }));
  corners[9].p1 = 0.85; corners[10].p0 = 0.85;
  const bump = x => Math.exp(-x * x);
  function lapArrays(lapTime, extra) {
    const v = new Float32Array(N), t = new Float32Array(N), thr = new Float32Array(N), brk = new Float32Array(N), st = new Float32Array(N), g = new Float32Array(N);
    for (let i = 0; i < N; i++) {
      let s = 62, w = 0;
      T.forEach(c => { const x = (i - c[2] * L) / c[4]; let d = c[3]; if (c[0] === 5) d += extra; s -= d * bump(x); w += c[5] * 0.22 * Math.min(1, c[3] / 20) * bump(x * 0.8); });
      v[i] = s; st[i] = w;
    }
    for (let i = 0; i < N; i++) {
      const dv = (v[Math.min(N - 1, i + 1)] - v[i]);
      brk[i] = Math.max(0, Math.min(1, -dv * 7));
      thr[i] = brk[i] > 0.03 ? 0 : v[i] > 61.5 ? 1 : Math.max(0.2, Math.min(1, 0.6 + dv * 12));
      g[i] = Math.max(2, Math.min(6, 1 + Math.floor(v[i] / 12)));
    }
    t[0] = 0; for (let i = 1; i < N; i++) t[i] = t[i - 1] + 2 / (v[i] + v[i - 1]);
    const k = lapTime / t[N - 1]; for (let i = 0; i < N; i++) t[i] *= k;
    return { t, Speed: v, Throttle: thr, Brake: brk, SteeringWheelAngle: st, Gear: g };
  }
  const chans = [{ key: 'Speed', name: 'Speed', unit: 'm/s' }, { key: 'Throttle', name: 'Throttle', unit: '%' }, { key: 'Brake', name: 'Brake', unit: '%' },
    { key: 'SteeringWheelAngle', name: 'Steering', unit: 'rad' }, { key: 'Gear', name: 'Gear', unit: '' }];
  // lap = { n, time }, ref = { n, time } or null; the loss at T5 is the lap's time over the best (93.832) as extra m/s at the apex
  window.__pwbLap = lapArrays;
  window.__pwb = function (lap, ref) {
    const info = l => ({ file: 'toyotagr86_roadatlanta full', lap: l.n, time: l.time, official: l.time, date: '', car: 'Toyota GR86', kind: 'session' });
    const head = { v: 1, n: N, metres: L, lengthM: L, step: 1, track: 'Michelin Raceway Road Atlanta', config: 'Full Course', car: 'Toyota GR86',
      lap: info(lap), partial: null, conditions: null, ref: ref ? info(ref) : null,
      channels: chans.map(c => Object.assign({ desc: '', ok: true }, c)), multi: [], arrays: [], laps: [], corners: corners, credit: '', sectorAt: [] };
    const parts = [['lap', lap]].concat(ref ? [['ref', ref]] : []);
    const data = [];
    parts.forEach(p => { const a = lapArrays(p[1].time, Math.max(0, (p[1].time - 93.832) * 9)); ['t'].concat(chans.map(c => c.key)).forEach(k => { head.arrays.push(p[0] + '.' + k); data.push(a[k]); }); });
    let hj = new TextEncoder().encode(JSON.stringify(head));
    const pad = (4 - hj.length % 4) % 4, total = 8 + hj.length + pad + data.length * N * 4;
    const buf = new ArrayBuffer(total), u8 = new Uint8Array(buf), dv = new DataView(buf);
    u8.set([80, 87, 66, 49], 0); dv.setInt32(4, hj.length + pad, true); u8.set(hj, 8); for (let i = 0; i < pad; i++) u8[8 + hj.length + i] = 32;
    let pos = 8 + hj.length + pad;
    data.forEach(a => { for (let i = 0; i < N; i++) { dv.setFloat32(pos, a[i], true); pos += 4; } });
    return buf;
  };
  window.__track = { L: L, corners: corners };
})();
