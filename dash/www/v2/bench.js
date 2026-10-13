'use strict';
// The benchmark card (WS13): "how good am I?" for one car + track. Your best lap at the top, each yardstick as a thin bar with
// its time, the gap and your pace as a percentage, the next goal, and your best lap over time. Every number says where it
// comes from and how many drivers it is based on. Used by the sessions page (sessions.js) and the debrief after a new
// personal best (debrief.js loads this file by itself). Data: GET /bench?car=&track=&config= (dash\src\bench.cs).
const BenchCard = (() => {
  const MINUS = '−';
  const e = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const lap = t => { const m = Math.floor(t / 60), s = t - m * 60; return m > 0 ? m + ':' + (s < 10 ? '0' : '') + s.toFixed(3) : s.toFixed(3); };
  const gap = d => (d >= 0 ? '+' : MINUS) + Math.abs(d).toFixed(2) + ' s';
  const day = ts => new Date(ts).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
  const host = u => { try { return new URL(u).host; } catch (x) { return ''; } };

  // one yardstick row: label, time, gap, pace, then the bar and the small print
  function row(y, pb, lo, hi, link) {
    const x = t => ((t - lo) / (hi - lo) * 100).toFixed(2);
    const a = Math.min(y.time, pb), b = Math.max(y.time, pb);
    const ahead = y.gap < 0;                                     // you are quicker than this yardstick
    const src = [y.detail, y.source].filter(Boolean).join(' · ');
    const from = y.url ? (link ? '<a href="' + e(y.url) + '" target="_blank" rel="noopener">' + e(host(y.url)) + '</a>' : '<span>' + e(host(y.url)) + '</span>') : '';
    return '<div class="bn-row" data-id="' + e(y.id) + '">' +
      '<div class="bn-l"><span class="bn-name">' + e(y.label) + '</span><span class="bn-t">' + lap(y.time) + '</span><span class="bn-g' + (ahead ? ' up' : '') + '">' + gap(y.gap) + '</span><span class="bn-p">' + y.pace.toFixed(1) + '%</span></div>' +
      '<div class="bn-bar"><i class="gp" style="left:' + x(a) + '%;width:' + (x(b) - x(a)).toFixed(2) + '%"></i><i class="ym" style="left:' + x(y.time) + '%"></i><i class="pm" style="left:' + x(pb) + '%"></i></div>' +
      '<div class="bn-s">' + e(src) + (from ? ' · ' + from : '') + '</div></div>';
  }

  // your personal best over time: one thin stepped line (a quicker lap is a smaller time, so improving climbs)
  function history(h) {
    if (!h || h.length < 2) return '';
    const t0 = h[0][0], t1 = h[h.length - 1][0], span = Math.max(1, t1 - t0);
    let lo = Infinity, hi = -Infinity; for (const p of h) { lo = Math.min(lo, p[2]); hi = Math.max(hi, p[2]); }
    const pad = Math.max(0.05, (hi - lo) * 0.15); lo -= pad; hi += pad;
    const X = t => ((t - t0) / span * 536 + 2).toFixed(1), Y = v => ((v - lo) / (hi - lo) * 54 + 3).toFixed(1);
    let d = '', prev = null;
    for (const p of h) {
      const x = X(p[0]), y = Y(p[2]);
      d += (prev === null ? 'M' + x + ' ' + y : ' L' + x + ' ' + prev + ' L' + x + ' ' + y); prev = y;
    }
    d += ' L538 ' + prev;
    const first = h[0], last = h[h.length - 1];
    return '<svg class="bn-svg" viewBox="0 0 540 60" preserveAspectRatio="none" role="img" aria-label="Best lap over time"><line x1="0" y1="59.5" x2="540" y2="59.5" class="ax"/>' +
      '<path d="' + d + '" class="ln"/></svg>' +
      '<div class="bn-ax"><span>' + day(first[0]) + ' · ' + lap(first[2]) + '</span><span>' + day(last[0]) + ' · ' + lap(last[2]) + '</span></div>';
  }

  // opts: { compact: bool (the debrief: 3 rows, no history), nav: {i, n} (sessions page), link: bool (source links), title: string }
  function html(d, opts) {
    opts = opts || {};
    if (!d || !d.pb) return '<div class="bn"><div class="bn-none">No timed lap for this car and track yet.</div></div>';
    const pb = d.pb.time;
    let ys = (d.yardsticks || []).slice();
    if (opts.compact && ys.length > 3) {                           // the three nearest to you
      ys.sort((a, b) => Math.abs(a.time - pb) - Math.abs(b.time - pb)); ys = ys.slice(0, 3); ys.sort((a, b) => a.time - b.time);
    }
    let lo = pb, hi = pb; for (const y of ys) { lo = Math.min(lo, y.time); hi = Math.max(hi, y.time); }
    const m = Math.max(0.02, (hi - lo) * 0.06); lo -= m; hi += m;
    const sub = [d.pb.live ? 'set this session' : (day(d.pb.ts) ? 'set ' + day(d.pb.ts) : ''), d.pb.sessions ? d.pb.sessions + (d.pb.sessions === 1 ? ' session' : ' sessions') + (d.pb.laps ? ' · ' + d.pb.laps + ' laps' : '') : ''].filter(Boolean).join(' · ');
    let h = '<div class="bn' + (opts.compact ? ' compact' : '') + '">';
    if (!opts.compact) {
      h += '<div class="bn-head"><label>Benchmark' + (d.sample ? ' · sample data' : '') + '</label>' +
        (opts.nav && opts.nav.n > 1 ? '<span class="bn-nav"><button type="button" data-step="-1" aria-label="Previous car and track">‹</button><i>' + (opts.nav.i + 1) + ' / ' + opts.nav.n + '</i><button type="button" data-step="1" aria-label="Next car and track">›</button></span>' : '') + '</div>';
      h += '<div class="bn-combo"><b>' + e(d.track) + (d.config ? ' <small>' + e(d.config) + '</small>' : '') + '</b><span>' + e(d.car) + '</span></div>';
      h += '<div class="bn-pb"><label>Best</label><b>' + lap(pb) + '</b><span>' + e(sub) + '</span></div>';
    } else {
      h += '<div class="bn-head"><label>' + e(opts.title || 'Benchmark') + (d.sample ? ' · sample data' : '') + '</label><span class="bn-sub">' + e(d.car) + ' · ' + e(d.track) + '</span></div>';
    }
    if (ys.length) {
      h += '<div class="bn-cols"><span>Yardstick</span><span>Time</span><span>Gap</span><span>Pace</span></div>';
      h += ys.map(y => row(y, pb, lo, hi, opts.link)).join('');
    }
    if (d.next) h += '<div class="bn-next"><label>Next goal</label><span>' + e(d.next.label) + ' <b>' + lap(d.next.time) + '</b></span><em>' + d.next.gap.toFixed(2) + ' s to find</em></div>';
    else if (d.ahead) h += '<div class="bn-next"><label>Next goal</label><span>Ahead of all</span></div>';
    if (!opts.compact || !ys.length) {
      const f = d.field || { n: 0, needed: 30, enough: false };
      if (!f.enough) h += '<div class="bn-field"><label>Other drivers</label><span>' + f.n + ' / ' + f.needed + '</span></div>';
    }
    if (!opts.compact) {
      const hist = history(d.history);
      if (hist) h += '<div class="bn-hist"><label>Best lap over time</label>' + hist + '</div>';
    }
    return h + '</div>';
  }

  return { html, lap, gap };
})();
