(() => {
  const out = { runs: 0, bad: [] }, cv = document.createElement('canvas'); cv.width = 768; cv.height = 384; const g = cv.getContext('2d');
  let cur = null;
  g.fillText = (t, x, y) => { const w = g.measureText(t).width; out.runs++; const l = x - w / 2, rr = x + w / 2, k = Math.floor(x / 96), kl = k * 96 + 3, kr = k * 96 + 93; if (l < kl || rr > kr) out.bad.push(cur + ': "' + t + '" ' + Math.round(l) + '..' + Math.round(rr) + ' not inside ' + kl + '..' + kr); };
  for (const r of Races.regions) {
    if (r.w < 2 || !r.paint) continue;          // every multi-key tile, the open view's 4 x 2 picture tile too (W1-6 review #13)
    cur = r.c + ',' + r.r + ' ' + r.text; g.textAlign = 'center'; r.paint(g, r.c * 96 + 3, r.r * 96 + 3, r.w * 96 - 6, r.h * 96 - 6, '#000', '#fff');
  }
  return out;
})()
