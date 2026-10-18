'use strict';
// Performance page (F3 in docs\SPEC-next.md). Shown over the idle screen (?embed=1, an iframe, opened by a Stream Deck key or from
// the Sessions page) or on its own at /v2/perf.html. Data: /perf (last session, every session, the changes with "did it help?",
// Paddock's own cost) and /perf/checklist. core.js and map.js are loaded only for their helpers and the corner names (TrackInfo).
const PF = {
  EMBED: /[?&]embed=1/.test(location.search),
  GOLD: '#f2c230', INK: '#f4f1ea', MUTE: '#8d8a82', LOW: '#a9a59b', GRID: 'rgba(244,241,234,.07)', AMBER: '#e0a23a',
  FONT: 'Bahnschrift, "Segoe UI", sans-serif',
  d: null, check: null, sig: '', checkSig: '', track: null, car: null, field: null, pts: [], marks: [], hover: null, geo: null, corners: -1, sel: null, selData: null,
};

// New York time, 12-hour, same style as HOME (were en-GB 24-hour in the PC's own zone).
const pfNy = (ts, o) => new Date(ts).toLocaleDateString('en-US', Object.assign({}, o, { timeZone: 'America/New_York' }));
const pfDay = ts => pfNy(ts, { weekday: 'short' }) + ' ' + pfNy(ts, { day: 'numeric' }) + ' ' + pfNy(ts, { month: 'short' });
// Peter reads plain words: iRacing's raw setting names, "settled" and "Ask Claude" are the developer's words. (The wording is made in perf.cs;
// the next irdash build should say it there. Until then this rewrites it on the way to the screen.)
const pfPlain = s => String(s == null ? '' : s).replace(/DriverHands/g, 'Driver hands').replace(/SteeringWheel/g, 'Steering wheel').replace(/\(settled: /g, '(usual: ').replace(/the settled setup/gi, 'the usual setup').replace(/Ask Claude to put them back\./, 'They can be put back.').replace(/Ask Claude to check iRacing's graphics\./, 'It can be checked.');
const pfClock = ts => new Date(ts).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'America/New_York' });
const pfFieldClass = f => f <= 1.5 ? 0 : f <= 8 ? 1 : f <= 20 ? 2 : 3;
const pfFieldWord = c => ['Driving alone', 'A few cars', 'A normal grid', 'A big field'][c];
const pfTypeTxt = t => /offline testing/i.test(t || '') ? 'Test' : /open qualify/i.test(t || '') ? 'Qualify' : (t || '');
const pfSecs = s => s < 90 ? Math.round(s) + ' s' : s < 3600 ? Math.round(s / 60) + ' min' : Math.floor(s / 3600) + ' h ' + String(Math.round((s % 3600) / 60)).padStart(2, '0') + ' min';
const pfR = v => Math.round(v);

/* ---------------- loading ---------------- */
async function pfLoad() {
  try {
    const t = await (await fetch('/perf', { cache: 'no-store' })).text();
    const sig = t.length + ':' + t.slice(-80) + ':' + t.slice(0, 200);
    if (sig !== PF.sig) { PF.sig = sig; PF.d = JSON.parse(t); pfRender(); if (!PF.fileDone) { PF.fileDone = true; const f = QS.get('file'); if (f) pfSelect(f); } }   // perf.html?file=<name>.ibt opens that session's card
    else if (PF.d) { PF.d.status = JSON.parse(t).status; pfNote(); }
  } catch (e) { $('note').textContent = 'Not connected'; }
}

async function pfLoadCheck() {
  try {
    const t = await (await fetch('/perf/checklist', { cache: 'no-store' })).text();
    if (t !== PF.checkSig) { PF.checkSig = t; PF.check = JSON.parse(t); pfRenderCheck(); }
  } catch (e) { /* irdash restarting */ }
}

function pfNote() {
  const d = PF.d; if (!d) return;
  const s = d.status || {};
  let txt = '';
  if (s.state === 'running' || s.pending > 0) txt = 'Reading sessions: ' + (s.reports || 0) + ' / ' + (s.files || 0);
  else if (s.reports) txt = s.counted + ' sessions measured';
  setText('note', txt);
}

/* ---------------- everything ---------------- */
function pfRender() {
  pfNote();
  pfIdentity();
  pfRenderLast();
  pfRenderRun();
  pfRenderFilters();
  pfRenderHelp();
  pfDraw();
}

// P0-06: the headline number under the page name: the last session's average frame rate.
function pfIdentity() {
  const el = $('idNum'); if (!el) return;
  const l = PF.d && PF.d.last;
  setText('idNum', l && isNum(l.avg) ? pfR(l.avg) + ' fps' : (PF.d ? 'No session' : ''));
}

/* ---------------- the last-session card ---------------- */
function pfCorner(from, to) {
  const d = typeof TrackInfo !== 'undefined' ? TrackInfo.data : null;
  const pct = x => Math.round(x * 100);
  if (d && d.turns && d.turns.length >= 3) {
    const t = d.turns.slice().sort((a, b) => a.pct - b.pct);
    const inside = t.filter(x => x.pct >= from - 0.015 && x.pct <= to + 0.015);
    if (inside.length === 1) return inside[0].label;
    if (inside.length > 1) return inside[0].label + ' - ' + inside[inside.length - 1].label;
    const mid = (from + to) / 2; let best = t[0], bd = 9;
    for (const x of t) { const dd = Math.min(Math.abs(x.pct - mid), 1 - Math.abs(x.pct - mid)); if (dd < bd) { bd = dd; best = x; } }
    return 'Near ' + best.label;
  }
  return 'Lap ' + pct(from) + '–' + pct(to) + ' %';
}

function pfRenderLast() {
  const d = PF.d, el = $('last'), l = PF.selData || d.last;
  if (!l) {
    const s = d.status || {};
    el.innerHTML = '<div class="lbl"><span>Last session</span></div><div class="empty">' + (s.pending > 0 || s.state === 'running' || s.state === 'waiting' ?
      'Reading sessions: ' + (s.reports || 0) + ' / ' + (s.files || 0) :
      'No session measured yet') + '</div>';
    return;
  }
  if (l.key && typeof TrackInfo !== 'undefined') TrackInfo.setTrack({ key: l.key, name: l.track, config: l.config, rawName: l.trackName });
  const vs = isNum(l.usual) ? (() => { const df = l.avg - l.usual; return '<b class="' + (df >= 0.5 ? 'up' : df <= -0.5 ? 'down' : '') + '">' + (df >= 0 ? '+' : '−') + Math.abs(pfR(df)) + ' fps</b> vs usual ' + pfR(l.usual); })() :
    '';
  const facts = [
    '<span>Graphics card<b>' + l.gpu + ' %</b></span>', '<span>Processor<b>' + l.cpu + ' %</b></span>',
    '<span>Dips<b>' + pfR(l.dip) + ' % of time</b></span>',
    l.cars != null ? '<span>Cars on track<b>' + pfR(l.cars) + '</b></span>' : (l.field > 1 ? '<span>Cars in the session<b>' + pfR(l.field) + '</b></span>' : '<span>Driving<b>alone</b></span>'),
    '<span>Driving time<b>' + pfSecs(l.secs) + '</b></span>',
  ];
  if (l.net) facts.push('<span>Ping<b>' + pfR(l.net.ping) + ' ms</b></span>', '<span>Connection<b>' + pfR(l.net.quality * 100) + ' %</b></span>');
  let h = '<div class="lbl"><span>' + (PF.selData ? 'Session <button class="back" type="button" id="backBtn">Back to the latest &rsaquo;</button>' : 'Last session') + '</span><em>' + esc(pfDay(l.ts) + ', ' + pfClock(l.ts)) + (l.type ? ' · ' + esc(pfTypeTxt(l.type)) : '') + '</em></div>' +
    '<h1>' + esc(l.track) + (l.config ? ' <span style="color:#8d8a82;font-size:22px">' + esc(l.config) + '</span>' : '') + '<small>' + esc(l.car || '') + '</small></h1>' +
    '<div class="big"><div class="avg"><b>' + pfR(l.avg) + '</b><label>Average fps</label></div><div class="low"><b>' + pfR(l.low1) + '</b><label>1 % low fps</label></div>' +
    '<div class="worst"><b>' + pfR(l.worst) + '</b><label>Worst second</label></div></div>' +
    '<div class="verdict">' + esc(l.text) + '</div><div class="vs">' + vs + '</div><div class="facts">' + facts.join('') + '</div>';
  h += '<div class="sub2">Where it was slowest</div>';
  const places = (l.places || []).filter(p => p.avg < l.avg * 0.97);
  PF.corners = typeof TrackInfo !== 'undefined' ? TrackInfo.version : -1;
  if (!places.length) h += '<div class="none">No slow spots</div>';
  else {
    const mx = Math.max.apply(null, places.map(p => l.avg - p.avg));
    for (const p of places)
      h += '<div class="corner"><span class="nm">' + esc(pfCorner(p.from, p.to)) + '</span><span class="bar"><i style="width:' + Math.max(8, Math.round((l.avg - p.avg) / mx * 100)) + '%"></i></span>' +
           '<span class="v">' + pfR(p.avg) + '<small>low ' + pfR(p.min) + '</small></span></div>';
  }
  el.innerHTML = h;
  const bb = $('backBtn'); if (bb) bb.onclick = () => pfSelect(null);
}

// tap a dot on the trend to see that session in the card (and what else was running then)
async function pfSelect(file) {
  if (!file || (PF.d.last && file === PF.d.last.file)) { PF.sel = null; PF.selData = null; pfRenderLast(); pfRenderRun(); pfDraw(); return; }
  try {
    const r = await (await fetch('/perf/session?file=' + encodeURIComponent(file), { cache: 'no-store' })).json();
    if (r && !r.error) { PF.sel = file; PF.selData = r; pfRenderLast(); pfRenderRun(); pfDraw(); }
  } catch (e) { /* irdash restarting */ }
}

/* ---------------- what else was running ---------------- */
function pfRenderRun() {
  const d = PF.d, l = PF.selData || d.last, el = $('paneRun');
  let h = '<h2><span>What else was running</span><em>% of one core</em></h2>';
  if (!l) { el.innerHTML = h + '<div class="none">No session measured yet</div>'; return; }
  const p = l.procs;
  if (!p) h += '<div class="none">Not recorded for this session</div>';
  else {
    const pc = v => v >= 100 ? (v / 100).toFixed(1) + ' cores' : pfR(v) + ' %';
    const row = (name, avg, dip, hot) => '<div class="run"><span class="nm' + (hot ? ' hot' : '') + '">' + esc(name) + '</span><span class="r">' + pc(avg) + '</span><span class="r ' + (hot ? 'hot' : 'gray') + '">' + (dip != null ? pc(dip) : '') + '</span></div>';
    h += '<div class="run th"><span>Program</span><span class="r">Average</span><span class="r">In dips</span></div>';
    h += row('iRacing sim', p.sim, null);
    h += row('Overlays (irdashies)', p.overlays, null);
    h += row('Paddock', p.paddock, null);
    h += row('CrewChief', p.crew, null);
    for (const o of p.others.slice(0, 5)) h += row(o.name, o.avg, o.dip, o.dip != null && o.dip >= 20 && o.dip - o.avg >= 5);
    if (!p.others.length) h += '<div class="none">No other programs</div>';
    h += '<div class="foot">' + p.samples + ' readings · ' + (p.dips ? p.dips + ' in dips' : 'no dips') + '</div>';
  }
  const o = d.own;
  if (o && o.drives > 0) h += '<div class="foot">Last ' + o.drives + (o.drives === 1 ? ' drive' : ' drives') + ': dashboard ' + pfR(o.program) + ' % · browser ' + pfR(o.browser) + ' % · overlays ' + pfR(o.overlays) + ' %' +
    (o.sampler && o.sampler.pctOfCore != null ? ' · sampler ' + o.sampler.pctOfCore.toFixed(3) + ' %' : '') + '</div>';
  el.innerHTML = h;
}

/* ---------------- the trend ---------------- */
function pfRenderFilters() {
  const d = PF.d, el = $('filters');
  const all = d.sessions.filter(s => s.counts);
  // Why the count: starting on the last session's field size ("A few cars") left ONE dot and an empty chart when his last drive was a
  // test with 2 cars. Start on that field size only when it still gives a line to look at (5+ sessions); otherwise start on Any.
  if (PF.track === null && d.last) {
    PF.track = d.last.key; PF.car = d.last.car; PF.field = pfFieldClass(d.last.field);
    if (all.filter(s => s.key === PF.track && s.car === PF.car && pfFieldClass(s.field) === PF.field).length < 5) PF.field = -1;
  }
  if (PF.track === null) { PF.track = ''; PF.car = ''; PF.field = -1; }
  const chip = (txt, on, n, fn) => { const b = document.createElement('button'); b.type = 'button'; b.className = 'chip' + (on ? ' on' : ''); b.textContent = txt; if (n != null) { const i = document.createElement('i'); i.textContent = n; b.appendChild(i); } b.onclick = fn; return b; };
  const group = (label, items) => { const g = document.createElement('div'); g.className = 'fgroup'; const lb = document.createElement('label'); lb.textContent = label; g.appendChild(lb); items.forEach(i => g.appendChild(i)); return g; };
  el.textContent = '';
  const byTrack = new Map(); for (const s of all) { const e = byTrack.get(s.key) || { name: s.track + (s.config ? ' · ' + s.config : ''), n: 0 }; e.n++; byTrack.set(s.key, e); }
  const tracks = Array.from(byTrack.entries()).sort((a, b) => b[1].n - a[1].n);
  if (PF.track && !byTrack.has(PF.track)) PF.track = '';
  el.appendChild(group('Track', [chip('All', !PF.track, null, () => { PF.track = ''; PF.car = ''; pfRenderFilters(); pfDraw(); })].concat(tracks.slice(0, 6).map(([k, e]) => chip(e.name, PF.track === k, e.n, () => { PF.track = k; PF.car = ''; pfRenderFilters(); pfDraw(); })))));
  const pool = all.filter(s => !PF.track || s.key === PF.track);
  const byCar = new Map(); for (const s of pool) byCar.set(s.car, (byCar.get(s.car) || 0) + 1);
  if (PF.car && !byCar.has(PF.car)) PF.car = '';
  if (byCar.size > 1) el.appendChild(group('Car', [chip('All', !PF.car, null, () => { PF.car = ''; pfRenderFilters(); pfDraw(); })].concat(Array.from(byCar.entries()).sort((a, b) => b[1] - a[1]).slice(0, 5).map(([c, n]) => chip(c, PF.car === c, n, () => { PF.car = c; pfRenderFilters(); pfDraw(); })))));
  const fcs = new Map(); for (const s of pool.filter(s => !PF.car || s.car === PF.car)) { const c = pfFieldClass(s.field); fcs.set(c, (fcs.get(c) || 0) + 1); }
  if (PF.field >= 0 && !fcs.has(PF.field)) PF.field = -1;
  if (fcs.size > 1) el.appendChild(group('Cars on track', [chip('Any', PF.field < 0, null, () => { PF.field = -1; pfRenderFilters(); pfDraw(); })].concat(Array.from(fcs.keys()).sort().map(c => chip(pfFieldWord(c), PF.field === c, fcs.get(c), () => { PF.field = c; pfRenderFilters(); pfDraw(); })))));
}

function pfPoints() {
  return PF.d.sessions.filter(s => s.counts && (!PF.track || s.key === PF.track) && (!PF.car || s.car === PF.car) && (PF.field < 0 || pfFieldClass(s.field) === PF.field)).sort((a, b) => a.ts - b.ts);
}

function pfDraw() {
  if (!PF.d) return;
  const cv = $('plot'), box = $('plotBox');
  const dpr = window.devicePixelRatio || 1, w = box.clientWidth, h = box.clientHeight;
  if (!w || !h) return;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
  const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, w, h);
  const pts = PF.pts = pfPoints(), n = pts.length;
  const lines = [], first = pts[0], lastP = pts[n - 1];
  setText('trendNote', n ? n + (n === 1 ? ' session' : ' sessions') + (PF.track && first ? ' · ' + first.track : '') : '');
  $('legend').innerHTML = '<span><i class="a"></i>Average</span><span><i class="l"></i>1 % low</span><span><i class="m"></i>Change</span>';
  g.font = '15px ' + PF.FONT; g.textBaseline = 'middle';
  if (n < 2) {
    g.fillStyle = PF.MUTE; g.textAlign = 'left';
    const msg = n === 0 ? 'No sessions' : '1 session · ' + pfR(first.avg) + ' fps average';
    g.fillText(msg, 6, h / 2);
    PF.geo = null; return;
  }
  const L0 = 52, R0 = 18, T0 = 34, B0 = 34, W = w - L0 - R0, H = h - T0 - B0;
  let lo = Infinity, hi = -Infinity;
  for (const s of pts) { lo = Math.min(lo, s.low1, s.avg); hi = Math.max(hi, s.avg, s.low1); }
  const span = Math.max(hi - lo, 8), pad = span * 0.18; lo = Math.max(0, lo - pad); hi = hi + pad;
  const stepRaw = (hi - lo) / 5, p10 = Math.pow(10, Math.floor(Math.log10(stepRaw))), fr = stepRaw / p10, step = (fr <= 1 ? 1 : fr <= 2 ? 2 : fr <= 5 ? 5 : 10) * p10;
  lo = Math.floor(lo / step) * step; hi = Math.ceil(hi / step) * step;
  const X = i => L0 + (i + 0.5) * W / n, Y = v => T0 + H - (v - lo) / (hi - lo) * H;
  // grid and y labels
  g.strokeStyle = PF.GRID; g.lineWidth = 1; g.fillStyle = PF.MUTE; g.textAlign = 'right';
  for (let v = lo; v <= hi + 1e-6; v += step) { const y = Math.round(Y(v)) + .5; g.beginPath(); g.moveTo(L0, y); g.lineTo(w - R0, y); g.stroke(); g.fillText(String(Math.round(v)), L0 - 10, y); }
  g.textAlign = 'left'; g.fillText('fps', 4, T0 - 18);
  // x labels: the first session of each new day
  g.textAlign = 'center'; let lastLabelX = -999, prevDay = '';
  pts.forEach((s, i) => { const day = new Date(s.ts).toDateString(); if (day !== prevDay) { prevDay = day; const x = X(i); if (x - lastLabelX > 74) { g.fillStyle = PF.MUTE; g.fillText(new Date(s.ts).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }), x, h - 12); lastLabelX = x; } } });
  // change markers: between the sessions either side of them
  PF.marks = [];
  const eps = PF.d.changes.slice().sort((a, b) => a.ts - b.ts); let row = 0;
  for (const ep of eps) {
    let k = 0; while (k < n && pts[k].ts < ep.ts) k++;
    if (k === 0) continue;                                              // before everything shown
    const x = k >= n ? X(n - 1) + W / n / 2 : (X(k - 1) + X(k)) / 2;
    PF.marks.push({ x, ep });
    g.strokeStyle = 'rgba(242,194,48,.55)'; g.lineWidth = 1.5; g.setLineDash([4, 4]); g.beginPath(); g.moveTo(Math.round(x) + .5, T0 - 8); g.lineTo(Math.round(x) + .5, T0 + H); g.stroke(); g.setLineDash([]);
    const kind = ep.kinds[0], lab = ({ graphics: 'Graphics', overlays: 'Overlays', iracing: 'iRacing update', driver: 'Driver', windows: 'Windows', priority: 'Priority', 'delta bar': 'Delta bar', paddock: 'Paddock' }[kind] || 'Change') + (ep.items.length > 1 && ep.kinds.length === 1 ? ' ×' + ep.items.length : '');
    g.fillStyle = 'rgba(242,194,48,.85)'; g.font = '13px ' + PF.FONT; g.textAlign = x > w - 120 ? 'right' : 'left'; g.fillText(lab, x + (x > w - 120 ? -5 : 5), T0 - 18 + (row++ % 2) * 15); g.font = '15px ' + PF.FONT;
  }
  // the two lines
  const draw = (key, color, wd, r) => {
    g.strokeStyle = color; g.lineWidth = wd; g.lineJoin = 'round'; g.beginPath();
    pts.forEach((s, i) => { const x = X(i), y = Y(s[key]); if (i) g.lineTo(x, y); else g.moveTo(x, y); }); g.stroke();
    g.fillStyle = color; pts.forEach((s, i) => { g.beginPath(); g.arc(X(i), Y(s[key]), r, 0, Math.PI * 2); g.fill(); });
  };
  draw('low1', PF.LOW, 2, 3); draw('avg', PF.GOLD, 3, 4);
  PF.geo = { X, Y, L0, T0, W, H, n };
  const si = PF.sel ? pts.findIndex(s => s.file === PF.sel) : -1;
  if (si >= 0) { g.strokeStyle = PF.INK; g.lineWidth = 2; g.beginPath(); g.arc(X(si), Y(pts[si].avg), 8, 0, Math.PI * 2); g.stroke(); }
  if (PF.hover) {
    const hv = PF.hover;
    if (hv.i != null) { const x = X(hv.i); g.strokeStyle = 'rgba(244,241,234,.35)'; g.lineWidth = 1; g.beginPath(); g.moveTo(Math.round(x) + .5, T0); g.lineTo(Math.round(x) + .5, T0 + H); g.stroke(); g.fillStyle = PF.INK; g.beginPath(); g.arc(x, Y(pts[hv.i].avg), 6, 0, Math.PI * 2); g.fill(); }
  }
}

function pfHover(e) {
  const box = $('plotBox'), tip = $('tip'), geo = PF.geo;
  if (!geo) { tip.hidden = true; return; }
  const r = box.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
  let best = null, bd = 12;
  for (const m of PF.marks) { const dd = Math.abs(m.x - mx); if (dd < bd) { bd = dd; best = m; } }
  let h = '';
  if (best && my < geo.T0 + geo.H) {
    PF.hover = null;
    const ep = best.ep; h = '<div class="at">' + esc(pfDay(ep.ts) + ', ' + pfClock(ep.ts)) + '</div><div class="chg"><b>' + esc(pfPlain(ep.title)) + '</b><br>' + esc(pfPlain(ep.detail)) + '</div>';
  } else {
    const i = Math.max(0, Math.min(geo.n - 1, Math.floor((mx - geo.L0) / geo.W * geo.n)));
    if (mx < geo.L0 - 4 || mx > geo.L0 + geo.W + 4) { PF.hover = null; tip.hidden = true; pfDraw(); return; }
    PF.hover = { i }; const s = PF.pts[i];
    h = '<div class="at">' + esc(pfDay(s.ts) + ', ' + pfClock(s.ts)) + (s.type ? ' · ' + esc(pfTypeTxt(s.type)) : '') + '</div>' +
      '<div class="ln"><span>Average</span><b>' + pfR(s.avg) + ' fps</b></div><div class="ln"><span>1 % low</span><b>' + pfR(s.low1) + ' fps</b></div><div class="ln"><span>Worst second</span><b>' + pfR(s.worst) + ' fps</b></div>' +
      '<div class="ln"><span>Cars</span><b>' + (s.cars != null ? pfR(s.cars) : pfR(s.field)) + '</b></div><div class="ln"><span>Driving</span><b>' + pfSecs(s.secs) + '</b></div>';
  }
  tip.innerHTML = h; tip.hidden = false;
  const tw = tip.offsetWidth, th = tip.offsetHeight;
  tip.style.left = Math.max(4, Math.min(box.clientWidth - tw - 4, mx + 16 + tw > box.clientWidth ? mx - tw - 16 : mx + 16)) + 'px';
  tip.style.top = Math.max(4, Math.min(box.clientHeight - th - 4, my - th / 2)) + 'px';
  pfDraw();
}

/* ---------------- before and after ---------------- */
function pfRenderHelp() {
  const d = PF.d, el = $('helpList');
  if (!d.changes.length) { el.innerHTML = '<div class="none">No changes yet</div>'; return; }
  let h = '';
  for (const ep of d.changes) {
    const r = ep.result, cls = r.state === 'ok' ? r.verdict : 'few';
    h += '<div class="ep"><div class="h"><b>' + esc(pfPlain(ep.title)) + '</b><span>' + esc(pfDay(ep.ts)) + ', ' + esc(pfClock(ep.ts)) + '</span></div>' +
      (ep.detail ? '<div class="d">' + esc(pfPlain(ep.detail)) + '</div>' : '') +
      '<div class="r ' + cls + '">' + (r.state === 'ok' ? '' : r.state === 'few' ? '' : '') + esc(r.text || 'Not enough sessions yet.') + '</div>' +
      (r.where && r.state === 'ok' ? '<div class="w">' + esc(r.where) + ' · ' + r.before.n + ' sessions before, ' + r.after.n + ' after</div>' : '') + '</div>';
  }
  el.innerHTML = h;
}

/* ---------------- the checklist ---------------- */
function pfRenderCheck() {
  const c = PF.check, el = $('checkList'); if (!c) return;
  let h = '';
  const order = { look: 0, ok: 1, info: 2 };
  const items = c.items.slice().sort((a, b) => order[a.state] - order[b.state]);
  for (const it of items) {
    h += '<div class="it ' + esc(it.state) + '"><i class="dot"></i><div><div class="t">' + esc(it.title) + (it.auto ? '<em>Auto</em>' : '') + '</div>' +
      '<div class="e">' + esc(pfPlain(it.evidence)) + '</div>' + (it.say ? '<div class="s">' + esc(pfPlain(it.say)) + '</div>' : '') +
      (it.tool ? '<button class="tool" type="button" data-tool="' + esc(it.tool) + '">Show ' + esc(it.tool) + '</button> <button class="tool" type="button" data-tool="' + esc(it.undo) + '">Show undo</button>' : '') + '</div></div>';
  }
  el.innerHTML = h || '<div class="none">Nothing to check yet.</div>';
}

/* ---------------- buttons ---------------- */
function pfClose() {
  if (PF.EMBED && window.parent !== window) { window.parent.postMessage({ irdash: 'perf-close' }, location.origin); window.parent.postMessage({ irdash: 'sessions-close' }, location.origin); }
}

document.addEventListener('click', e => {
  const t = e.target.closest && e.target.closest('.tool');
  if (t && t.dataset.tool) { fetch('/api/do?c=perfshow&a=' + encodeURIComponent(t.dataset.tool), { cache: 'no-store' }).catch(() => { }); }
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') pfClose(); });
$('closeBtn').hidden = true;   // pagehost draws the one CLOSE above every page
$('closeBtn').onclick = pfClose;
$('sessBtn').onclick = () => { location.href = 'sessions.html' + (PF.EMBED ? '?embed=1' : ''); };
$('plotBox').addEventListener('mousemove', pfHover);
$('plotBox').addEventListener('mouseleave', () => { PF.hover = null; $('tip').hidden = true; pfDraw(); });
$('plotBox').addEventListener('click', e => {
  const geo = PF.geo; if (!geo) return;
  const r = $('plotBox').getBoundingClientRect(), mx = e.clientX - r.left;
  if (mx < geo.L0 - 4 || mx > geo.L0 + geo.W + 4) return;
  const i = Math.max(0, Math.min(geo.n - 1, Math.floor((mx - geo.L0) / geo.W * geo.n)));
  if (PF.pts[i]) pfSelect(PF.pts[i].file);
});
window.addEventListener('resize', () => pfDraw());

// corner names come from the internet late: show them as soon as they arrive
setInterval(() => { if (PF.d && PF.d.last && typeof TrackInfo !== 'undefined' && TrackInfo.version !== PF.corners) pfRenderLast(); }, 800);

pfLoad(); pfLoadCheck();
setInterval(pfLoad, 8000);
setInterval(pfLoadCheck, 20000);
