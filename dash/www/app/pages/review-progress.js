/* Progress inside REVIEW (W4-6, docs/rework/cards/W4-6.md, PLAN 4.4 "Progress"). A SECTION, not a page: W4-3's card screen mounts it
   under the plan line:   import * as Progress from './review-progress.js';  Progress.mount(el, ctx, opts);  ...  Progress.unmount();
     opts = { car: <car id for the query>, track: <track id for the query>, carName: 'GR86', trackName: 'Road Atlanta',
              corners: [5, 7, 12]  (the corner numbers of this review's cards: n, as in /api/review) }
   One request at mount (GET /api/review/progress?car&track) and again only when irdash says the review list changed
   (ctx.data.onList('review')); no timer. Three things in one band:
     1. the dots: the best lap and the average of the best five, one dot per session on one time axis, the latest one bright
     2. the corner trend: "Turn 5: lost 0.31 -> 0.22 -> 0.12 s over three sessions", green when it falls
     3. the iRating line from his own race log, labelled estimate, only with two or more races
   Nothing here is under 24 px, there is no gold fill; colours come from design.css through classes. */
const num = x => typeof x === 'number' && isFinite(x);
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const DAY = 86400000;
const W = 880, H = 190, PADL = 150, PADR = 36, PADT = 14, PADB = 44;   // the dots' drawing, in real pixels (no scaling)
const WORDS = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten'];

// ---------------------------------------------------------------- pure helpers (the test imports them)
// a date from ms or text; NaN when it is neither
const ms = d => (num(d) ? d : Date.parse(d));
// "6 Nov" (New York, as Fmt.when: his clock)
export function dayLabel(d) {
  const t = ms(d); if (!num(t)) return '';
  return new Date(t).toLocaleDateString('en-GB', { timeZone: 'America/New_York', day: 'numeric', month: 'short' });
}
// 93.832 -> 1:33.832 (Fmt when it is there)
const lap = s => (window.Fmt ? window.Fmt.lap(s) : String(s));
// Turn names: "T5" -> "Turn 5", "T10a" -> "Turn 10a", anything else as it is ("The Esses")
export function cornerName(c) {
  const l = String((c && c.label) || (c && c.n) || '');
  const m = /^T(\d+[a-z]?)$/i.exec(l);
  if (m) return 'Turn ' + m[1];
  return /^\d+$/.test(l) ? 'Turn ' + l : l;
}
// the sessions in date order, only those with a best lap
export function sessionsByDate(list) {
  return (Array.isArray(list) ? list : []).filter(s => s && num(ms(s.date)) && num(s.best) && s.best > 0)
    .map(s => ({ date: ms(s.date), best: s.best, avg5: num(s.avg5) && s.avg5 > 0 ? s.avg5 : null }))
    .sort((a, b) => a.date - b.date);
}
// one corner's story: the last five values with their dates in order; dir = 'gain' (falling), 'loss' (rising) or 'flat'
export function trend(c) {
  const lost = (c && Array.isArray(c.lost)) ? c.lost : [], dates = (c && Array.isArray(c.dates)) ? c.dates : [];
  const rows = lost.map((v, i) => ({ v: v, d: ms(dates[i]), i: i })).filter(r => num(r.v));
  if (rows.length && rows.every(r => num(r.d))) rows.sort((a, b) => a.d - b.d);
  const v = rows.slice(-5).map(r => r.v);
  const n = v.length;
  let dir = 'flat';
  if (n >= 2) { const a = Math.round(v[0] * 100), b = Math.round(v[n - 1] * 100); dir = b < a ? 'gain' : b > a ? 'loss' : 'flat'; }
  const arrow = ' → ';
  let text;
  if (n === 0) text = '';
  else if (n === 1) text = cornerName(c) + ': lost ' + v[0].toFixed(2) + ' s so far';
  else text = cornerName(c) + ': lost ' + v.map(x => x.toFixed(2)).join(arrow) + ' s over ' + (WORDS[n] || n) + ' sessions';
  return { n: n, values: v, dir: dir, text: text };
}
// the corners of this review that have a story, in the order of the review's cards
export function trendsFor(progress, corners) {
  const all = (progress && Array.isArray(progress.corners)) ? progress.corners : [];
  const want = Array.isArray(corners) ? corners : [];
  return want.map(n => {
    const key = (n && typeof n === 'object') ? n.n : n;
    return all.find(c => c && String(c.n) === String(key));
  }).filter(Boolean).map(trend).filter(t => t.n > 0);
}
// the iRating rows in date order; two or more races, or nothing
export function iratingRows(progress) {
  const r = (progress && Array.isArray(progress.irating)) ? progress.irating : [];
  const rows = r.filter(x => x && num(x.value) && num(ms(x.date))).map(x => ({ date: ms(x.date), value: x.value, estimate: x.estimate !== false })).sort((a, b) => a.date - b.date);
  return rows.length >= 2 ? rows : [];
}
const thousands = n => String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');

// ---------------------------------------------------------------- the dots (SVG, real pixels)
function dotsSvg(sessions) {
  const t0 = sessions[0].date, t1 = sessions[sessions.length - 1].date, span = Math.max(t1 - t0, DAY);
  const all = []; sessions.forEach(s => { all.push(s.best); if (s.avg5 != null) all.push(s.avg5); });
  let lo = Math.min.apply(null, all), hi = Math.max.apply(null, all); if (hi - lo < 0.4) { lo -= 0.2; hi += 0.2; }
  const pad = (hi - lo) * 0.12; lo -= pad; hi += pad;
  const iw = W - PADL - PADR, ih = H - PADT - PADB;
  const X = d => PADL + (sessions.length === 1 ? iw / 2 : (d - t0) / span * iw), Y = v => PADT + (v - lo) / (hi - lo) * ih;   // faster = higher
  let s = '<svg class="dots" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="Best lap and average of the best five, by session">';
  // two guide lines with the lap times at the left: the fastest and the slowest shown
  [lo + pad, hi - pad].forEach(v => {
    s += '<line class="grid" x1="' + PADL + '" x2="' + (W - PADR) + '" y1="' + Y(v).toFixed(1) + '" y2="' + Y(v).toFixed(1) + '"/>' +
      '<text class="ylab" x="' + (PADL - 16) + '" y="' + (Y(v) + 8).toFixed(1) + '" text-anchor="end">' + esc(lap(v)) + '</text>';
  });
  // the dates under the axis: the first, the last and any that keep 120 px from the one before
  let lastX = -1e9;
  sessions.forEach((q, i) => {
    const x = X(q.date), edge = i === 0 || i === sessions.length - 1;
    if (i > 0 && x - lastX < 120) return;
    if (!edge && W - PADR - x < 120) return;
    lastX = x;
    s += '<text class="xlab" x="' + x.toFixed(1) + '" y="' + (H - 10) + '" text-anchor="middle">' + esc(dayLabel(q.date)) + '</text>';
  });
  // the average of the best five (a thin line joins its dots), then the best lap
  const a5 = sessions.filter(q => q.avg5 != null);
  if (a5.length > 1) s += '<polyline class="join avg" points="' + a5.map(q => X(q.date).toFixed(1) + ',' + Y(q.avg5).toFixed(1)).join(' ') + '"/>';
  if (sessions.length > 1) s += '<polyline class="join best" points="' + sessions.map(q => X(q.date).toFixed(1) + ',' + Y(q.best).toFixed(1)).join(' ') + '"/>';
  sessions.forEach((q, i) => {
    const latest = i === sessions.length - 1;
    if (q.avg5 != null) s += '<circle class="dot avg' + (latest ? ' latest' : '') + '" data-d="' + q.date + '" cx="' + X(q.date).toFixed(1) + '" cy="' + Y(q.avg5).toFixed(1) + '" r="' + (latest ? 10 : 7) + '"/>';
    s += '<circle class="dot best' + (latest ? ' latest' : '') + '" data-d="' + q.date + '" cx="' + X(q.date).toFixed(1) + '" cy="' + Y(q.best).toFixed(1) + '" r="' + (latest ? 12 : 8) + '"/>';
  });
  return s + '</svg>';
}

// ---------------------------------------------------------------- the iRating line (a small line, the last value and the change)
function iratingHtml(rows) {
  const w = 200, h = 56, vs = rows.map(r => r.value), lo = Math.min.apply(null, vs), hi = Math.max.apply(null, vs), span = Math.max(hi - lo, 1);
  const t0 = rows[0].date, tt = Math.max(rows[rows.length - 1].date - t0, 1);
  const pts = rows.map(r => [((r.date - t0) / tt * (w - 24) + 12).toFixed(1), (h - 12 - (r.value - lo) / span * (h - 24)).toFixed(1)]);
  const last = rows[rows.length - 1], first = rows[0], diff = Math.round(last.value - first.value);
  const est = rows.some(r => r.estimate);
  const dir = diff > 0 ? 'gain' : diff < 0 ? 'loss' : 'flat';
  return '<div class="irating"><div class="irtext"><span class="k">iRating' + (est ? ' (estimate)' : '') + '</span> <span class="v">' + thousands(last.value) + '</span> ' +
    '<span class="chg ' + dir + '">' + (diff > 0 ? '+' : diff < 0 ? '−' : '') + Math.abs(diff) + '</span> <span class="k">over ' + (WORDS[rows.length] || rows.length) + ' races</span></div>' +
    '<svg class="irline" width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '" role="img" aria-label="iRating by race">' +
    '<polyline class="join ir ' + dir + '" points="' + pts.map(p => p.join(',')).join(' ') + '"/>' +
    pts.map((p, i) => '<circle class="dot ir' + (i === pts.length - 1 ? ' latest' : '') + '" cx="' + p[0] + '" cy="' + p[1] + '" r="' + (i === pts.length - 1 ? 8 : 5) + '"/>').join('') + '</svg></div>';
}

// ---------------------------------------------------------------- the section
let host = null, tok = 0, offs = [], ctxRef = null, optsRef = null;

function head(opts) {
  const track = (opts && opts.trackName) || 'this track', car = (opts && opts.carName) || 'this car';
  return '<h2 class="rp-title">Progress at ' + esc(track) + ' in the ' + esc(car) + '</h2>';
}
function draw(p, opts) {
  if (!host) return;
  const sessions = sessionsByDate(p && p.sessions);
  let h = head(opts);
  if (sessions.length === 0) {
    h += '<p class="rp-empty">Nothing here yet: your first session will show up after you drive.</p>';
  } else if (sessions.length === 1) {
    h += '<p class="rp-empty">Your first session here: come back after the next one.</p>' +
      '<p class="rp-first">Best lap so far <span class="v">' + esc(lap(sessions[0].best)) + '</span></p>';
  } else {
    const first = sessions[0], last = sessions[sessions.length - 1], diff = last.best - first.best;
    h += '<div class="rp-grid"><div class="rp-dots">' + dotsSvg(sessions) +
      '<p class="rp-key"><span class="sw best"></span>Best lap <span class="sw avg"></span>Average of your best 5</p></div>';
    const tr = trendsFor(p, opts && opts.corners);
    h += '<div class="rp-side">' +
      '<p class="rp-sum">Best lap ' + esc(lap(last.best)) + ' <span class="chg ' + (diff < -0.0005 ? 'gain' : diff > 0.0005 ? 'loss' : 'flat') + '">' +
      esc(diff < -0.0005 ? '−' + Math.abs(diff).toFixed(3) : diff > 0.0005 ? '+' + diff.toFixed(3) : '0.000') + ' s</span> since ' + esc(dayLabel(first.date)) + '</p><div class="rp-trend">';
    if (tr.some(t => t.n >= 2)) h += tr.map(t => '<p class="trend ' + t.dir + '">' + esc(t.text) + '</p>').join('');
    else if (tr.length) h += tr.map(t => '<p class="trend flat">' + esc(t.text) + '</p>').join('') + '<p class="rp-empty">The trend shows after the next session.</p>';
    else h += '<p class="rp-empty">No corner trend yet: it shows after a session or two more here.</p>';
    h += '</div>';
    const ir = iratingRows(p);
    if (ir.length) h += iratingHtml(ir);
    h += '</div></div>';
  }
  host.innerHTML = '<section class="rprog" aria-label="Progress">' + h + '</section>';
}
function failed(opts) {
  if (!host) return;
  host.innerHTML = '<section class="rprog" aria-label="Progress">' + head(opts) + '<p class="rp-empty">Progress is not available right now.</p></section>';
}
function load() {
  const my = ++tok, opts = optsRef || {};
  const q = '/api/review/progress?car=' + encodeURIComponent(opts.car == null ? '' : opts.car) + '&track=' + encodeURIComponent(opts.track == null ? '' : opts.track);
  let pr; try { pr = ctxRef.data.json(q, 0); } catch (e) { failed(opts); return; }
  Promise.resolve(pr).then(p => { if (my === tok) draw(p, opts); }, () => { if (my === tok) failed(opts); });
}

export function mount(el, ctx, opts) {
  unmount();
  host = el; ctxRef = ctx; optsRef = opts || {};
  if (!document.querySelector('link[data-page="review-progress"]')) {
    const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = new URL('./review-progress.css', import.meta.url).href; l.dataset.page = 'review-progress';
    document.head.appendChild(l);
  }
  host.innerHTML = '<section class="rprog" aria-label="Progress">' + head(optsRef) + '<p class="rp-empty">Reading your sessions…</p></section>';
  if (ctx.data && ctx.data.onList) offs.push(ctx.data.onList('review', () => load()));
  load();
}
export function unmount() {
  tok++;
  offs.forEach(f => { try { f(); } catch (e) { } }); offs = [];
  if (host) host.innerHTML = '';
  host = null; ctxRef = null; optsRef = null;
}
export default { name: 'review-progress', mount, unmount };
