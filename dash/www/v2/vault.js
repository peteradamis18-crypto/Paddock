'use strict';
// Vault page: the laps, races and clips worth keeping (WS17, docs\vault.md). Shown over the idle screen (?embed=1, an iframe) or opened on its
// own at /v2/vault.html. Data: /vault/list (every moment), /vault/item, /vault/laps + /vault/lap (the same lap engine as the lap analysis, run on
// the Vault's own copy of the telemetry), /vault/clip (the video, with byte ranges), /vault/thumb (a picture made by irdash).
// Detail view: the labelled track map (corners.js), speed / throttle / brake / difference traces on ONE shared cursor, a corner table, and,
// for a clip, the video locked to that cursor through the telemetry's clock (LapDistPct <-> video time).

const EMBED = /[?&]embed=1/.test(location.search);
const GOLD = '#f2c230', CYAN = '#29d3f5', INK = '#f4f1ea', MUTE = '#8d8a82', GRID = 'rgba(244,241,234,.07)', SURFACE = '#060606';
const FONT = 'Bahnschrift, "Segoe UI", sans-serif';
const G = 1000;                                   // grid steps per lap (the lap engine's 0.1 % steps)

const $ = id => document.getElementById(id);
const isNum = x => typeof x === 'number' && Number.isFinite(x);
const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function setHTML(el, s) { if (typeof el === 'string') el = $(el); if (el && el._h !== s) { el._h = s; el.innerHTML = s; } }
function setText(el, s) { if (typeof el === 'string') el = $(el); s = s == null ? '' : String(s); if (el && el._t !== s) { el._t = s; el.textContent = s; } }
function fmtLap(t) { if (!isNum(t) || t <= 0) return '–:––.–––'; const m = Math.floor(t / 60), s = t - m * 60; return m > 0 ? m + ':' + (s < 10 ? '0' : '') + s.toFixed(3) : s.toFixed(3); }
function fmtDelta(d, digits) { if (!isNum(d)) return '–'; return (d >= 0 ? '+' : '−') + Math.abs(d).toFixed(digits == null ? 2 : digits); }
function fmtDur(sec) { sec = Math.max(0, Math.round(sec)); return Math.floor(sec / 60) + ':' + String(sec % 60).padStart(2, '0'); }
const store = { get(k) { try { const s = localStorage.getItem(k); return s ? JSON.parse(s) : null; } catch (e) { return null; } }, set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { } } };
const dayTxt = ts => new Date(ts).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
const dateTxt = ts => new Date(ts).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }) + ' ' + new Date(ts).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
const typeTxt = t => /offline testing/i.test(t || '') ? 'Test' : /open qualify/i.test(t || '') ? 'Qualify' : (t || '');

const V = {
  d: null, sig: '', f: { kind: '', car: '', track: '', tag: '', year: '', q: '' }, sort: store.get('vault-sort') || 'date',
  kmh: store.get('irdash-units') !== false,
  id: '', cur: null, laps: null, lap: 0, tr: new Map(), trace: null, ref: null, refInfo: null, cmpId: '', cmp: null,
  g: -1, pts: null, corners: null, discs: [], vid: null, videoId: '', ask: 0, stats: new Map(), seq: 0, showDelta: false, race: '',
  rec: false, rc: null, rcRef: null, vid2: null, lockOn: false,
};

/* ================= the grid ================= */
async function loadList() {
  try {
    const t = await (await fetch('/vault/list', { cache: 'no-store' })).text();
    const sig = t.length + ':' + t.slice(-80) + ':' + t.slice(0, 400);
    if (sig !== V.sig) {
      V.sig = sig; V.d = JSON.parse(t);
      if (V.d && V.d.enabled === false) {
        setText('status', 'Vault is switched off.');
        setText('totals', ''); setText('idNum', ''); setHTML('meter', ''); setHTML('setup', ''); setHTML('grid', '');
        return;
      }
      renderGrid();
    }
  } catch (e) { setText('status', 'Not connected'); }
}

function chipRow(el, label, items, cur, set) {
  el.textContent = '';
  if (items.length < 2 && !cur) { el.hidden = true; return; }
  el.hidden = false;
  const l = document.createElement('label'); l.textContent = label; el.appendChild(l);
  for (const [value, text, n] of items) {
    const b = document.createElement('button'); b.type = 'button'; b.className = 'chip' + (value === cur ? ' on' : '');
    b.textContent = text;
    if (n != null) { const i = document.createElement('i'); i.textContent = n; b.appendChild(i); }
    b.onclick = () => set(value === cur && value !== '' ? '' : value);
    el.appendChild(b);
  }
}

const bytesTxt = b => b >= 1073741824 ? (b / 1073741824).toFixed(1) + ' GB' : b >= 1048576 ? Math.round(b / 1048576) + ' MB' : Math.round(b / 1024) + ' KB';

function renderMeter() {
  const d = V.d; if (!d) return;
  const pc = d.budgetBytes > 0 ? Math.min(100, d.usedBytes / d.budgetBytes * 100) : 0;
  setHTML('meter', bytesTxt(d.usedBytes) + ' of ' + bytesTxt(d.budgetBytes) + '<i><u style="width:' + pc.toFixed(1) + '%"></u></i>');
}

function isKeeper(m) { return m.keeper; }

// No recorder yet: the page must not offer a clip filter or say "clip".
function vaultHasVideo(d) {
  if (!d) return false;
  if ((d.withVideo || 0) > 0 || (d.clips || 0) > 0) return true;
  return (d.moments || []).some(m => m.video);
}

// A lap and the video of that same session file + lap number are one card. The video shows as a badge.
function mergeCards(list) {
  const out = [], by = new Map();
  for (const m of list) {
    const k = (m.kind !== 'race' && m.lap > 0 && m.session) ? (m.session + '\n' + m.lap) : '';
    if (!k) { out.push(m); continue; }
    let g = by.get(k);
    if (!g) { g = { card: null, rest: [] }; by.set(k, g); out.push(g); }
    if (!g.card || (g.card.kind === 'clip' && m.kind !== 'clip')) {
      if (g.card) g.rest.push(g.card);
      g.card = m;
    } else g.rest.push(m);
  }
  const merged = [];
  for (const x of out) {
    if (x.kind) { merged.push(x); continue; }
    let vid = x.card.video ? x.card : null;
    for (const r of x.rest) if (!vid && r.video) vid = r;
    const wantKeeper = !!(x.card.keeper || x.rest.some(r => r.keeper));
    const need = (vid && vid !== x.card) || (wantKeeper && !x.card.keeper);
    if (!need) { merged.push(x.card); continue; }
    const card = {};
    for (const key in x.card) card[key] = x.card[key];
    if (vid && vid !== x.card) {
      card.video = vid.video; card.videoDur = vid.videoDur; card.videoFrom = vid.id;
      if (!card.thumb && vid.thumb) { card.thumb = true; card.thumbId = vid.id; }
    }
    if (wantKeeper) card.keeper = true;
    merged.push(card);
  }
  return merged;
}

function renderGrid() {
  const d = V.d; if (!d) return;
  const ms = d.moments;
  renderMeter();
  const videoOn = vaultHasVideo(d);
  if (V.f.kind === 'clip' && !videoOn) V.f.kind = '';
  const kinds = [['', 'Everything'], ['keep', '★ Keepers'], ['recent', 'Recent']];
  if (videoOn) kinds.push(['clip', 'Clips']);
  const pass = (m, skip) => (skip === 'kind' || !V.f.kind || (V.f.kind === 'keep' ? m.keeper : V.f.kind === 'recent' ? !m.keeper : m.video)) &&
    (skip === 'car' || !V.f.car || m.car === V.f.car) && (skip === 'track' || !V.f.track || m.track === V.f.track) && (skip === 'tag' || !V.f.tag || m.tags.indexOf(V.f.tag) >= 0) &&
    (skip === 'year' || !V.f.year || String(new Date(m.ts).getFullYear()) === V.f.year) &&
    (skip === 'q' || !V.f.q || (m.car + ' ' + m.track + ' ' + m.config + ' ' + m.note + ' ' + m.tags.join(' ') + ' ' + m.sType).toLowerCase().indexOf(V.f.q.toLowerCase()) >= 0);
  const uniq = (key, skip, get) => { const c = new Map(); ms.filter(m => pass(m, skip)).forEach(m => { const v = get(m); if (v) c.set(v, (c.get(v) || 0) + 1); }); return Array.from(c.entries()).sort((a, b) => b[1] - a[1]); };
  chipRow($('fKind'), 'Show', kinds.map(([v, t]) => [v, t, v === '' ? null : ms.filter(m => (v === 'keep' ? m.keeper : v === 'recent' ? !m.keeper : m.video)).length]), V.f.kind, v => { V.f.kind = v; renderGrid(); });
  const cars = uniq('car', 'car', m => m.car), tracks = uniq('track', 'track', m => m.track), tags = uniq('tag', 'tag', m => null);
  chipRow($('fCar'), 'Car', [['', 'All cars']].concat(cars.map(([c, n]) => [c, c, n])), V.f.car, v => { V.f.car = v; renderGrid(); });
  chipRow($('fTrack'), 'Track', [['', 'All tracks']].concat(tracks.map(([c, n]) => [c, c, n])), V.f.track, v => { V.f.track = v; renderGrid(); });
  const tagCount = new Map(); ms.filter(m => pass(m, 'tag')).forEach(m => m.tags.forEach(t => tagCount.set(t, (tagCount.get(t) || 0) + 1)));
  chipRow($('fTag'), 'Tag', [['', 'Any']].concat(Array.from(tagCount.entries()).sort((a, b) => b[1] - a[1]).map(([t, n]) => [t, t, n])), V.f.tag, v => { V.f.tag = v; renderGrid(); });
  const yc = new Map(); ms.filter(m => pass(m, 'year')).forEach(m => { const y = String(new Date(m.ts).getFullYear()); yc.set(y, (yc.get(y) || 0) + 1); });
  chipRow($('fYear'), 'Year', [['', 'All']].concat(Array.from(yc.entries()).sort((a, b) => b[0] - a[0]).map(([y, n]) => [y, y, n])), V.f.year, v => { V.f.year = v; renderGrid(); });
  chipRow($('fSort'), 'Sort', [['date', 'Newest'], ['time', 'Fastest'], ['gap', 'Closest to PB']], V.sort, v => { V.sort = v || 'date'; store.set('vault-sort', V.sort); renderGrid(); });
  if ($('q').value !== V.f.q) $('q').value = V.f.q;

  const cmp = { date: (a, b) => b.ts - a.ts, time: (a, b) => (a.lapTime || 1e9) - (b.lapTime || 1e9), gap: (a, b) => (isNum(a.gap) ? Math.abs(a.gap) : 1e9) - (isNum(b.gap) ? Math.abs(b.gap) : 1e9) };
  const ordered = ms.slice().sort(cmp[V.sort] || cmp.date);
  const vis = mergeCards(ordered).filter(m => pass(m, ''));
  let tot = vis.length + (vis.length === 1 ? ' moment' : ' moments') + ' · ' + d.keepers + ' kept';
  if (videoOn) tot += ' · ' + d.withVideo + (d.withVideo === 1 ? ' video' : ' videos');
  setText('totals', tot);
  setText('idNum', bytesTxt(d.usedBytes || 0) + ' · ' + ms.length + (ms.length === 1 ? ' moment' : ' moments'));
  const bits = [];
  if (d.status === 'reading older sessions' || d.scanLeft > 0) bits.push('Reading sessions' + (d.scanLeft ? ': ' + d.scanLeft + ' to go' : ''));
  if (d.sandbox) bits.push('TEST VAULT');
  bits.push('Recent laps kept ' + d.recentDays + ' days');
  setText('status', bits.join(' · '));
  renderSetup(d);

  let h = '';
  for (const m of vis) {
    const race = m.kind === 'race';
    const title = esc(m.track || 'Unknown track') + (m.config ? '<small>' + esc(m.config) + '</small>' : '');
    const big = race ? (m.finished ? 'P' + m.pos + '<span style="font-size:16px;color:var(--mute)"> of ' + m.field + '</span>' : '–') : (m.kind === 'clip' && !(m.lapTime > 0) ? '<span style="font-size:22px">' + fmtDur(m.videoDur) + '</span>' : fmtLap(m.lapTime));
    let gap = '';
    if (!race && isNum(m.gap) && m.lapTime > 0) gap = Math.abs(m.gap) < 0.0005 ? '<span class="gap pb">PB</span>' : '<span class="gap">' + fmtDelta(m.gap, 3) + '</span>';
    else if (race && m.lapTime > 0) gap = '<span class="gap">' + fmtLap(m.lapTime) + '</span>';
    const tg = m.tags.map(t => '<span class="tag' + (['PB', 'WIN', 'PODIUM', 'BEST LAP', 'TOP 10', 'BEST RACE', 'BIG IR'].indexOf(t) >= 0 ? ' k' : '') + '">' + esc(t) + '</span>').join('');
    h += '<div class="card' + (m.keeper ? ' keeper' : '') + '" tabindex="0" data-id="' + esc(m.id) + '">' +
      '<div class="th">' + (m.thumb ? '<img loading="lazy" alt="" src="/vault/thumb?id=' + encodeURIComponent(m.thumbId || m.id) + '">' : '<div class="none">picture soon</div>') +
      (m.keeper ? '<span class="star" title="Kept for good">★</span>' : '') +
      (m.video ? '<span class="badge vid">▶ ' + fmtDur(m.videoDur) + '</span>' : race ? '<span class="badge">' + (m.official ? 'Official race' : 'Race') + '</span>' : m.lap ? '<span class="badge">Lap ' + m.lap + '</span>' : '') + '</div>' +
      '<div class="meta"><div class="t1">' + title + '</div><div class="t2">' + esc(m.car || '') + (m.sType ? ' · ' + esc(typeTxt(m.sType)) : '') + '</div>' +
      '<div class="tm"><b>' + big + '</b>' + gap + '<span class="when">' + esc(dayTxt(m.ts)) + '</span></div><div class="tags">' + tg + (m.note ? '<span class="tag">NOTE</span>' : '') + '</div></div></div>';
  }
  if (!vis.length) {
    h = '<div class="empty">' + (ms.length ? '<b>No match</b>' : d.scanLeft > 0 || d.status !== 'up to date' ? '<b>Reading sessions</b>' :
      '<b>No laps yet</b>') + '</div>';
  }
  setHTML('grid', h);
}

function renderSetup(d) {
  // Video is recorded by Paddock itself in a later step. Do not send Peter to the NVIDIA app.
  if (!d) return;
  setHTML('setup', '');
}

document.addEventListener('click', e => {
  const c = e.target.closest && e.target.closest('.card[data-id]');
  if (c) location.hash = 'm=' + encodeURIComponent(c.dataset.id);
});
document.addEventListener('keydown', e => {
  if (e.target && (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT')) { if (e.key === 'Escape') e.target.blur(); return; }
  if (e.key === 'Escape') { if ($('wbHost')) closeRace(); else if (V.id) location.hash = ''; else closeMe(); return; }
  if (e.key === 'Enter' && document.activeElement && document.activeElement.dataset && document.activeElement.dataset.id && !V.id) document.activeElement.click();
});
// the page may sit in the Vault's own host or (after "Vault" on the Sessions page) in the Sessions host: tell both, whichever exists closes
function closeMe() { if (EMBED && window.parent !== window) { window.parent.postMessage({ irdash: 'vault-close' }, location.origin); window.parent.postMessage({ irdash: 'sessions-close' }, location.origin); } }

function toast(msg) {
  const t = $('toast'); t.textContent = msg; t.hidden = false; clearTimeout(toast.t); toast.t = setTimeout(() => { t.hidden = true; }, 4200);
}

/* ================= routing ================= */
function route() {
  const m = /^#m=([a-z0-9-]+)(?:&c=([a-z0-9-]+))?(?:&lap=(\d+))?$/.exec(location.hash);
  if (m) { if (m[1] !== V.id) openItem(m[1], m[2] || '', +m[3] || 0); else if ((m[2] || '') !== V.cmpId) setCompare(m[2] || ''); }
  else {
    V.id = ''; V.seq++; stopVideo(); teardownVid2();
    $('viewDetail').hidden = true; $('viewGrid').hidden = false; V.sig = ''; loadList();
  }
}

/* ================= one moment ================= */
const J = async url => { const r = await fetch(url, { cache: 'no-store' }); const t = await r.text(); let j = null; try { j = JSON.parse(t); } catch (e) { } return { ok: r.ok, j }; };

// Empty a box AND forget what setHTML/setText last put there. Emptying it with textContent alone left setHTML believing the old content was
// still on show, so opening the same lap twice in a row (identical page) skipped the redraw: no buttons, no lap column, no legend.
function wipe(id) { const el = $(id); if (!el) return; el.textContent = ''; el._h = null; el._t = null; }
function blank(id) { const cv = $(id); if (cv && cv.width) cv.getContext('2d').clearRect(0, 0, cv.width, cv.height); }

async function openItem(id, cmp, lap) {
  const seq = ++V.seq;
  // refInfo too: it names the comparison of the PREVIOUS lap page, and stayed on show until /vault/laps came back
  V.id = id; V.cur = null; V.laps = null; V.trace = null; V.ref = null; V.refInfo = null; V.cmp = null; V.cmpId = cmp; V.g = -1; V.pts = null; V.corners = null; V.discs = []; V.stats = new Map(); V.tr = new Map(); V.ask = 0; V.videoId = ''; V.showDelta = false; V.race = '';
  $('viewGrid').hidden = true; $('viewDetail').hidden = false;
  teardownVid2();
  setText('dTitle', 'Loading...'); wipe('dSub'); wipe('dActs'); wipe('cLeft'); wipe('cornerBox'); wipe('legend'); $('vidWrap').hidden = true; blank('plot'); blank('mapc');
  const r = await J('/vault/item?id=' + encodeURIComponent(id));
  if (seq !== V.seq) return;
  if (r.j && r.j.enabled === false) { setText('dTitle', 'Vault is switched off'); return; }
  if (!r.ok || !r.j || !r.j.m) { setText('dTitle', 'Not found'); setHTML('cLeft', '<div class="msg"><b>Not in the Vault</b></div>'); return; }
  V.cur = r.j; const m = r.j.m;
  setText('dTitle', (m.track || (m.video ? 'Video' : 'Moment')) + (m.config ? ' · ' + m.config : ''));
  renderHead();
  // the track outline and corners (kept on this PC by irdash)
  loadMap(m, seq);
  if (r.j.hasTelemetry) {
    const lr = await J('/vault/laps?id=' + encodeURIComponent(id));
    if (seq !== V.seq) return;
    if (lr.ok && lr.j) {
      V.laps = lr.j;
      const clean = lr.j.laps.filter(l => l.time > 15);
      V.lap = lap || (m.lap && lr.j.laps.some(l => l.n === m.lap) ? m.lap : (lr.j.best != null ? lr.j.best : (clean[0] || {}).n)) || 0;
      if (V.lap) { openWorkbench(id, V.lap); return; }
    }
    if (V.lap) checkRace(id, seq);                   // not awaited: the RACE button appears by itself when there is a race log
  }
  await prepareVideo(m, seq);
  if (seq !== V.seq) return;
  renderLeft();
  await pickReference();
  if (seq !== V.seq) return;
  await showTraces();
  if (seq !== V.seq) return;
  await setupCompareVideo(seq);
}

function openWorkbench(id, lap) {
  if ($('wbHost') || !lap) return;
  const host = document.createElement('div'); host.id = 'wbHost';
  host.innerHTML = '<div class="back" id="wbBack">Back to the Vault</div><iframe title="Paddock Analysis"></iframe>';
  host.querySelector('iframe').src = 'workbench.html?id=' + encodeURIComponent(id) + '&lap=' + encodeURIComponent(lap);
  document.body.appendChild(host);
  requestAnimationFrame(() => host.classList.add('on'));
  host.querySelector('#wbBack').addEventListener('click', closeRace);
}

function renderHead() {
  const m = V.cur.m;
  const race = m.kind === 'race';
  setHTML('dSub', esc([m.car, typeTxt(m.sType), dateTxt(m.ts)].filter(Boolean).join('  ·  ')) + (m.tags.length ? '  ·  ' + m.tags.map(t => '<b>' + esc(t) + '</b>').join(' ') : ''));
  const cw = V.cur.cosworth || {};
  const acts = [];
  // RACE: the whole field of this session (irdash logs every car in a race, W6). Only there when /analysis/race has a log for it.
  if (V.race === V.id) acts.push('<button class="btn gold" id="bRace" type="button">Race</button>');
  acts.push('<button class="btn' + (m.keeper ? ' on' : '') + '" id="bStar" type="button">★ ' + (m.pinned ? 'Kept' : m.keeper ? 'Kept (automatic)' : 'Keep') + '</button>');
  // No button for software that is not installed. A pretend flag (the test) sets installed without an exe.
  if (cw.installed) acts.push('<button class="btn" id="bCos" type="button"' + (V.cur.hasTelemetry ? '' : ' disabled') + '>Open in Cosworth</button>');
  acts.push('<button class="btn" id="bShare" type="button">Share</button>');
  acts.push('<button class="btn bad" id="bDel" type="button">Delete</button>');
  setHTML('dActs', acts.join(''));
  if ($('bRace')) $('bRace').onclick = openRace;
  $('bStar').onclick = () => edit('star=' + (m.pinned ? 0 : 1)).then(() => toast(m.pinned ? 'Back to automatic' : 'Kept for good'));
  if ($('bCos')) $('bCos').onclick = () => openFile('cosworth');
  $('bShare').onclick = () => openFile('share');
  $('bDel').onclick = () => { V.ask = 1; renderLeft(); };
}

// Does irdash hold a race log for this moment's session? 200 = yes, 404 = none, 503 = he is driving (then nothing is offered).
async function checkRace(id, seq) {
  let ok = false;
  try {
    const r = await fetch('/analysis/race?id=' + encodeURIComponent(id), { cache: 'no-store' });
    try { if (r.body && r.body.cancel) r.body.cancel(); } catch (e) { }
    ok = r.status === 200;
  } catch (e) { }
  if (!ok || seq !== V.seq || V.id !== id || !V.cur) return;
  V.race = id; renderHead();
}

// RACE: the analysis workbench on its RACE page, over the Vault (an iframe with a back bar, the same as ANALYSIS on the Session Review)
function openRace() {
  if ($('wbHost') || !V.lap) return;
  const host = document.createElement('div'); host.id = 'wbHost';
  host.innerHTML = '<div class="back" id="wbBack">‹ Back to the Vault</div><iframe title="Paddock Analysis"></iframe>';
  host.querySelector('iframe').src = 'workbench.html?id=' + encodeURIComponent(V.id) + '&lap=' + V.lap + '&page=race';
  document.body.appendChild(host);
  requestAnimationFrame(() => host.classList.add('on'));
  host.querySelector('#wbBack').addEventListener('click', closeRace);
}
function closeRace() { const h = $('wbHost'); if (!h) return; h.classList.remove('on'); h.id = 'wbHostGone'; setTimeout(() => h.remove(), 450); }

async function edit(q) {
  const r = await J('/vault/edit?id=' + encodeURIComponent(V.id) + '&' + q);
  if (r.ok && r.j && r.j.m) { V.cur = r.j; renderHead(); renderLeft(); V.sig = ''; }
  return r;
}

async function openFile(how) {
  const r = await J('/vault/open?id=' + encodeURIComponent(V.id) + '&how=' + how);
  if (!r.ok || !r.j) { toast((r.j && r.j.error) || 'Could not open'); return; }
  toast(r.j.action === 'cosworth' ? 'Opening in Cosworth' : how === 'cosworth' ? 'Pi Toolbox not installed · folder opened' : 'Folder opened');
}

function renderLeft() {
  const c = V.cur, m = c.m, race = m.kind === 'race';
  let h = '';
  if (race) h += '<div class="big">' + (m.finished ? 'P' + m.pos : 'Race') + '</div><div class="facts"><div>' + (m.finished ? 'of <b>' + m.field + '</b> cars' + (m.official ? ' · official' : ' · offline') : 'Not finished') + '</div>' +
    (isNum(m.irDelta) && m.irDelta !== 0 ? '<div>iRating <b class="' + (m.irDelta > 0 ? 'good' : 'bad') + '">' + fmtDelta(m.irDelta, 0) + '</b></div>' : '') + (m.lapTime > 0 ? '<div>Best lap <b>' + fmtLap(m.lapTime) + '</b></div>' : '') + '</div>';
  else {
    const gap = c.pb ? m.lapTime - c.pb : null;
    h += '<div class="big">' + (m.lapTime > 0 ? fmtLap(m.lapTime) : (m.video ? fmtDur(m.videoDur) : '–')) + '</div><div class="facts">' +
      (m.lap ? '<div>Lap <b>' + m.lap + '</b></div>' : '') + (isNum(gap) ? '<div class="gap">' + (Math.abs(gap) < 0.0005 ? '<b style="color:var(--gold)">Personal best</b>' : '<b class="' + (gap > 0 ? 'bad' : 'good') + '">' + fmtDelta(gap, 3) + '</b> to PB (' + fmtLap(c.pb) + ')') + '</div>' : '') +
      (m.pbBefore > 0 ? '<div>Beat <b>' + fmtLap(m.pbBefore) + '</b> by ' + (m.pbBefore - m.lapTime).toFixed(3) + ' s</div>' : '') + '</div>';
  }
  if (!c.hasTelemetry) h += '<div class="msg"><b>Telemetry file gone</b></div>';
  // laps of the session
  if (V.laps) {
    const laps = V.laps.laps.filter(l => l.time > 15), best = laps.filter(l => !l.pit).reduce((a, l) => Math.min(a, l.time), 1e9);
    h += '<h2>Laps<em>' + laps.length + ' full</em></h2><div class="scroll" id="lapScroll" style="flex:1;min-height:100px">';
    for (const l of laps) {
      const flags = [l.pit ? 'PIT' : '', l.off ? 'OFF' : '', l.inc ? l.inc + 'x' : ''].filter(Boolean).join(' ');
      h += '<div class="lap' + (l.n === V.lap ? ' cur' : '') + (l.pit ? ' dim' : '') + '" tabindex="0" data-lap="' + l.n + '"><span class="n">' + l.n + '</span><span>' + fmtLap(l.time) + '</span><span class="d">' + (l.time - best < 0.0005 && !l.pit ? 'best' : fmtDelta(l.time - best, 3)) + '</span><span class="fl">' + esc(flags) + '</span></div>';
    }
    h += '</div>';
  }
  // compare with another moment of the same car and track
  const others = (c.others || []).filter(o => !sameLap(o, m, V.lap || m.lap));
  if (others.length) {
    h += '<h2>Compare with</h2><select class="pick" id="cmpPick"><option value="">Best lap in the Vault</option>' +
      others.map(o => '<option value="' + esc(o.id) + '"' + (o.id === V.cmpId ? ' selected' : '') + '>' + fmtLap(o.lapTime) + ' · lap ' + o.lap + ' · ' + esc(dayTxt(o.ts)) + (o.tags.length ? ' · ' + esc(o.tags[0]) : '') + '</option>').join('') + '</select>';
  }
  h += '<h2>Notes</h2><textarea class="note" id="note" placeholder="Note" maxlength="400">' + esc(m.note) + '</textarea>';
  h += '<div style="display:flex;gap:8px;flex-wrap:wrap">' + ['INCIDENT', 'OVERTAKE', 'CLEAN'].map(t => '<button class="btn" data-tag="' + t + '" type="button" style="padding:4px 10px;font-size:12px' + (m.tags.indexOf(t) >= 0 ? ';background:var(--gold);color:#111' : '') + '">' + t + '</button>').join('') + '</div>';
  if (V.ask === 1) h += '<div class="ask"><div>Delete this ' + (m.kind === 'clip' ? 'video' : m.kind === 'race' ? 'race' : 'lap') + ' and its saved files?</div><div style="display:flex;gap:10px"><button class="btn" id="askNo" type="button">Keep it</button><button class="btn bad" id="askYes" type="button">Yes, delete</button></div></div>';
  if (V.ask === 2) h += '<div class="ask"><div><b>Cannot be undone</b></div><div style="display:flex;gap:10px"><button class="btn" id="askNo" type="button">Keep it</button><button class="btn bad" id="askYes2" type="button">Delete for good</button></div></div>';
  setHTML('cLeft', h);
  const lp = document.getElementById('lapScroll'); if (lp) { lp.querySelectorAll('.lap').forEach(el => { el.onclick = () => selectLap(+el.dataset.lap); }); const cur = lp.querySelector('.cur'); if (cur && cur.scrollIntoView) cur.scrollIntoView({ block: 'nearest' }); }
  const cp = $('cmpPick'); if (cp) cp.onchange = () => { location.hash = 'm=' + V.id + (cp.value ? '&c=' + cp.value : ''); };
  const nt = $('note'); if (nt) nt.onblur = () => { if (nt.value !== m.note) edit('note=' + encodeURIComponent(nt.value)); };
  document.querySelectorAll('[data-tag]').forEach(b => b.onclick = () => edit('tag=' + encodeURIComponent((m.tags.indexOf(b.dataset.tag) >= 0 ? '-' : '+') + b.dataset.tag)));
  const no = $('askNo'); if (no) no.onclick = () => { V.ask = 0; renderLeft(); };
  const y1 = $('askYes'); if (y1) y1.onclick = () => { V.ask = 2; renderLeft(); };
  const y2 = $('askYes2'); if (y2) y2.onclick = async () => {
    const r = await J('/vault/delete?id=' + encodeURIComponent(V.id) + '&confirm=yes');
    if (r.ok) { toast('Deleted'); location.hash = ''; } else toast((r.j && r.j.error) || 'Could not delete');
  };
}

async function selectLap(n) {
  if (n === V.lap) return;
  V.lap = n; V.g = -1; renderLeft(); await pickReference(); await showTraces();
}

/* ---------- traces ---------- */
function getTrace(id, lap) {
  const k = id + '|' + lap;
  if (!V.tr.has(k)) V.tr.set(k, J('/vault/lap?id=' + encodeURIComponent(id) + '&lap=' + lap).then(r => r.ok ? r.j : null).catch(() => null));
  return V.tr.get(k);
}

function listed(id) {
  if (!V.d || !V.d.moments) return null;
  for (let i = 0; i < V.d.moments.length; i++) if (V.d.moments[i].id === id) return V.d.moments[i];
  return null;
}
// The same session file and the same lap number is this lap, even when the Vault stored it twice (the lap and its video).
function sameLap(o, m, lap) {
  if (!o || !m) return false;
  const full = listed(o.id);
  const sess = o.session || (full && full.session) || '';
  const n = o.lap || (full && full.lap) || 0;
  if (o.id === m.id && n === lap) return true;
  return !!(sess && m.session && sess === m.session && n === lap);
}

// the lap to measure against: never this lap. Personal best if the Vault holds a different one, else the quickest other lap here.
async function pickReference() {
  const c = V.cur, m = c.m; V.ref = null; V.refInfo = null; V.cmp = null;
  const lap = V.lap || m.lap || 0;
  const pool = (c.others || []).filter(o => !sameLap(o, m, lap));
  if (V.cmpId) {
    const o = pool.find(x => x.id === V.cmpId);
    if (o) V.refInfo = { id: o.id, lap: o.lap, session: o.session || (listed(o.id) || {}).session || '', label: 'Compared · lap ' + o.lap + ' · ' + fmtLap(o.lapTime), time: o.lapTime };
  }
  if (!V.refInfo) {
    const pbm = c.pbId && c.pbId !== m.id ? pool.find(x => x.id === c.pbId) : null;
    const quicker = pool.find(x => x.lapTime < (m.lapTime || 1e9) - 0.0005);
    const best = pbm || quicker || pool[0];
    if (best) {
      const sess = best.session || (listed(best.id) || {}).session || '';
      V.refInfo = { id: best.id, lap: best.lap, session: sess, label: (pbm ? 'Best · ' : quicker ? 'Quicker · ' : 'Next best · ') + 'lap ' + best.lap + ' · ' + fmtLap(best.lapTime), time: best.lapTime };
    }
  }
  if (V.refInfo && sameLap({ id: V.refInfo.id, lap: V.refInfo.lap, session: V.refInfo.session }, m, lap)) V.refInfo = null;
  V.cmp = V.refInfo;
}

// The grid card opens the lap. The video may live on the other moment of that same lap (the old NVIDIA clip).
async function attachSiblingVideo(m, seq) {
  if (!V.d) await loadList();
  if (seq !== V.seq || !V.d || !m) return;
  const sib = (V.d.moments || []).find(o => o.id !== m.id && o.video && o.session && m.session && o.session === m.session && o.lap === (V.lap || m.lap));
  if (!sib) return;
  const ir = await J('/vault/item?id=' + encodeURIComponent(sib.id));
  if (seq !== V.seq || !ir.ok || !ir.j || !ir.j.sync) return;
  V.videoId = sib.id;
  V.cur.sync = ir.j.sync;
}

async function showTraces() {
  const seq = V.seq, id = V.id, lap = V.lap;
  if (!V.cur.hasTelemetry || !lap) { drawAll(); renderLegend(); renderCorners(); return; }
  const [a, b] = await Promise.all([getTrace(id, lap), V.refInfo ? getTrace(V.refInfo.id, V.refInfo.lap) : Promise.resolve(null)]);
  if (seq !== V.seq || lap !== V.lap) return;
  V.trace = a; V.ref = b;
  if (V.trace) V.trace.delta = V.ref ? V.trace.t.map((v, i) => v - V.ref.t[i]) : null;
  if (V.g < 0 && V.trace) V.g = 0;
  renderLegend(); renderCorners(); drawAll();
  loadStats(seq);
}

function renderLegend() {
  const a = V.trace, b = V.ref;
  setHTML('legend', a ? '<span><i></i>This lap · ' + (V.lap ? 'lap ' + V.lap : '') + ' · <b style="color:var(--ink)">' + fmtLap(a.time) + '</b></span>' + (b && V.refInfo ? '<span><i class="c"></i>' + esc(V.refInfo.label) + '</span>' : '<span>No other lap</span>') : (V.cur && !V.cur.hasTelemetry ? '<span>No telemetry</span>' : ''));
}

/* ---------- map and corners ---------- */
async function loadMap(m, seq) {
  const key = V.cur.mapKey;
  try {
    const r = await fetch('/trackmap?key=' + encodeURIComponent(key) + '&id=' + encodeURIComponent(m.trackId) + '&name=' + encodeURIComponent(m.trackName), { cache: 'no-store' });
    if (r.ok) { const j = await r.json(); if (seq === V.seq && Array.isArray(j.pts) && j.pts.length > 100) V.pts = j.pts; }
  } catch (e) { }
  try { const d = await Corners.load({ rawName: m.trackName, name: m.track, config: m.config, id: m.trackId, key }); if (seq === V.seq) V.corners = d; } catch (e) { }
  if (seq === V.seq) { renderCorners(); drawMap(); }
}

function turnRange(t) { return [Math.round(t.pct0 * G), Math.round(t.pct1 * G)]; }
function turnTime(tr, t) {
  const [a, b] = turnRange(t);
  return b >= a ? tr.t[b] - tr.t[a] : tr.t[G] - tr.t[a] + tr.t[b];
}

// the quickest time through each turn among the Vault's laps of this car and track (fetched a few at a time, the table fills in as they arrive)
async function loadStats(seq) {
  const c = V.cur; if (!c) return;
  const list = c.others || [];   // every saved lap of this car and track, so "Best in Vault" is the real best
  for (const o of list) {
    if (seq !== V.seq) return;
    if (!V.stats.has(o.id)) { const tr = await getTrace(o.id, o.lap); if (seq !== V.seq) return; V.stats.set(o.id, tr ? { tr, o } : null); renderCorners(); }
  }
}

function renderCorners() {
  const box = $('cornerBox'), d = V.corners;
  if (!V.cur) return;
  if (!d || !d.turns || !d.turns.length) { setHTML(box, '<div class="msg">' + (d && d.pending ? 'Finding corners' : 'No corner list yet') + '</div>'); return; }
  if (!V.trace) { setHTML(box, ''); return; }
  const a = V.trace;
  const lapN = V.lap || (V.cur.m && V.cur.m.lap) || 0;
  const pbMom = V.cur.pbId ? (listed(V.cur.pbId) || { id: V.cur.pbId, lap: V.cur.pbId === V.cur.m.id ? lapN : 0, session: V.cur.pbId === V.cur.m.id ? (V.cur.m.session || '') : '' }) : null;
  const pbOk = !!(pbMom && !sameLap(pbMom, V.cur.m, lapN) && V.stats.get(V.cur.pbId));
  const pbS = pbOk ? V.stats.get(V.cur.pbId) : (V.ref && V.refInfo && !sameLap(V.refInfo, V.cur.m, lapN) ? { tr: V.ref } : null);
  const vsPb = pbOk;
  let h = '<h2>Time in each turn<em>' + (pbS ? (vsPb ? 'vs PB' : 'vs ' + esc(V.refInfo ? V.refInfo.label : '')) : 'no other lap') + '</em></h2><div class="scroll"><div class="ct h"><span>Turn</span><span></span><span class="r">This lap</span><span class="r">' + (vsPb ? 'vs PB' : 'vs other') + '</span><span class="r">Best in Vault</span></div>';
  d.turns.forEach((t, i) => {
    const mine = turnTime(a, t);
    let best = mine, bestOf = '';
    const here = {};
    ((V.cur.others) || []).forEach(o => { here[o.id] = 1; });
    for (const s of V.stats.values()) { if (!s || !s.o || !here[s.o.id]) continue; const v = turnTime(s.tr, t); if (v > 0 && v < best - 1e-9) { best = v; bestOf = s.o.id; } }
    const vs = pbS ? mine - turnTime(pbS.tr, t) : null, gb = mine - best;
    const cls = x => !isNum(x) || Math.abs(x) < 0.005 ? 'flat' : x > 0 ? 'bad' : 'good';
    h += '<div class="ct" data-i="' + i + '"><span class="nm"><b>T' + t.n + '</b></span><span class="nm">' + esc(t.name || '') + '</span><span class="r">' + mine.toFixed(2) + '</span><span class="r ' + cls(vs) + '">' + (isNum(vs) ? (Math.abs(vs) < 0.005 ? '0.00' : fmtDelta(vs, 2)) : '–') + '</span><span class="r ' + cls(gb) + '">' + (gb < 0.005 ? best.toFixed(2) + ' ★' : best.toFixed(2) + ' <small>' + fmtDelta(gb, 2) + '</small>') + '</span></div>';
  });
  h += '</div>';
  setHTML(box, h);
  box.querySelectorAll('.ct[data-i]').forEach(el => el.onclick = () => { const t = d.turns[+el.dataset.i]; setCursor(Math.round(t.pctApex * G), true); });
}

/* ---------- drawing ---------- */
const PAN = [{ k: 'spd', h: 3.1 }, { k: 'thr', h: 1.3 }, { k: 'brk', h: 1.3 }];
function activePans() {
  const p = PAN.slice();
  if (V.showDelta) p.push({ k: 'dlt', h: 2.2 });
  return p;
}
function niceStep(raw) { const p = Math.pow(10, Math.floor(Math.log10(raw))), f = raw / p; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p; }
function geom(w, h) {
  const pans = activePans();
  const left = 74, right = 14, top = 26, bottom = 40, gap = 24;
  const tot = pans.reduce((a, p) => a + p.h, 0), avail = h - top - bottom - gap * (pans.length - 1);
  let y = top; const panels = {};
  for (const p of pans) { const ph = avail * p.h / tot; panels[p.k] = { y, ph }; y += ph + gap; }
  return { left, right, W: w - left - right, top, bottom, panels, pans };
}

function drawAll() { drawPlot(); drawMap(); }

function drawPlot() {
  const cv = $('plot'), box = $('plotBox'), A = V.trace, B = V.ref;
  V.showDelta = !!(A && B && A.delta);
  if (!cv || !box || !A) { if (cv) { const g = cv.getContext('2d'); g.clearRect(0, 0, cv.width, cv.height); } return; }
  const dpr = window.devicePixelRatio || 1, w = box.clientWidth, h = box.clientHeight;
  if (!w || !h) return;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
  const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, w, h);
  const P = geom(w, h), L = A.lengthM || 4000, xs = i => P.left + i / G * P.W;
  g.lineJoin = 'round'; g.lineCap = 'round'; g.textBaseline = 'middle';
  const text = (s, x, y, size, color, align) => { g.font = size + 'px ' + FONT; g.fillStyle = color || MUTE; g.textAlign = align || 'left'; g.fillText(s, x, y); };
  const last = P.pans[P.pans.length - 1];
  const bottomY = P.panels[last.k].y + P.panels[last.k].ph;
  // distance grid
  const step = V.kmh ? 500 : 402.336, uStep = V.kmh ? 0.5 : 0.25, unit = V.kmh ? 'km' : 'mi';
  for (let m = 0, k = 0; m <= L + 1; m += step, k++) {
    const x = P.left + m / L * P.W;
    g.strokeStyle = GRID; g.lineWidth = 1;
    for (const p of P.pans) { const q = P.panels[p.k]; g.beginPath(); g.moveTo(Math.round(x) + .5, q.y); g.lineTo(Math.round(x) + .5, q.y + q.ph); g.stroke(); }
    text((k * uStep).toFixed(V.kmh ? 1 : 2) + (k === 0 ? ' ' + unit : ''), x, bottomY + 14, 12, MUTE, k === 0 ? 'left' : 'center');
  }
  // corner numbers along the bottom
  const turns = V.corners && V.corners.turns ? V.corners.turns : [];
  for (const t of turns) { const x = xs(t.pctApex * G); text('T' + t.n, x, bottomY + 29, 11, '#8a6d1c', 'center'); }
  const lines = (arr, color, ymap, wd) => { g.beginPath(); for (let i = 0; i <= G; i++) { const x = xs(i), y = ymap(arr[i]); i ? g.lineTo(x, y) : g.moveTo(x, y); } g.strokeStyle = color; g.lineWidth = wd || 2; g.stroke(); };
  const panel = (k, title, lo, hi, ticks, fmt) => {
    const q = P.panels[k];
    text(title, P.left, q.y - 11, 11, MUTE);
    const ymap = v => q.y + q.ph - (v - lo) / (hi - lo) * q.ph;
    for (const t of ticks) { const y = Math.round(ymap(t)) + .5; g.strokeStyle = GRID; g.lineWidth = 1; g.beginPath(); g.moveTo(P.left, y); g.lineTo(P.left + P.W, y); g.stroke(); text(fmt(t), P.left - 9, y, 12, MUTE, 'right'); }
    return ymap;
  };
  const f = V.kmh ? 3.6 : 2.236936;
  let top = 0; for (let i = 0; i <= G; i++) top = Math.max(top, A.spd[i], B ? B.spd[i] : 0);
  const sStep = niceStep(top * f / 4), sMax = Math.ceil(top * f / sStep) * sStep;
  const yS = panel('spd', 'SPEED ' + (V.kmh ? 'KM/H' : 'MPH'), 0, sMax / f, Array.from({ length: Math.round(sMax / sStep) + 1 }, (_, i) => i * sStep / f), v => String(Math.round(v * f)));
  if (B) lines(B.spd, CYAN, yS); lines(A.spd, GOLD, yS);
  const pct = v => v + '%';
  const yT = panel('thr', 'THROTTLE', 0, 100, [0, 50, 100], pct); if (B) lines(B.thr, CYAN, yT); lines(A.thr, GOLD, yT);
  const yB = panel('brk', 'BRAKE', 0, 100, [0, 50, 100], pct); if (B) lines(B.brk, CYAN, yB); lines(A.brk, GOLD, yB);
  let yD = null;
  if (V.showDelta) {
    const q = P.panels.dlt;
    let mx = 0.1; for (let i = 0; i <= G; i++) mx = Math.max(mx, Math.abs(A.delta[i]));
    const dm = Math.ceil(mx * 10) / 10; yD = panel('dlt', 'TIME DIFFERENCE', -dm, dm, [-dm, 0, dm], v => (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(1));
    const y0 = yD(0), d = A.delta;
    const poly = () => { g.beginPath(); g.moveTo(xs(0), y0); for (let i = 0; i <= G; i++) g.lineTo(xs(i), yD(d[i])); g.lineTo(xs(G), y0); g.closePath(); };
    g.save(); g.beginPath(); g.rect(0, q.y, P.left + P.W + 2, y0 - q.y); g.clip(); poly(); g.fillStyle = 'rgba(255,90,77,.18)'; g.fill(); g.restore();
    g.save(); g.beginPath(); g.rect(0, y0, P.left + P.W + 2, q.y + q.ph - y0); g.clip(); poly(); g.fillStyle = 'rgba(47,224,122,.18)'; g.fill(); g.restore();
    lines(d, INK, yD);
    text('slower', P.left + P.W - 4, q.y + 10, 11, '#ff8a7d', 'right'); text('faster', P.left + P.W - 4, q.y + q.ph - 10, 11, '#4fe08c', 'right');
  }
  V.P = P; V.xs = xs; V.fn = { yS, yT, yB, yD };
  // the shared cursor
  if (V.g >= 0) {
    const i = clamp(V.g, 0, G), x = xs(i);
    g.strokeStyle = 'rgba(244,241,234,.5)'; g.lineWidth = 1; g.beginPath(); g.moveTo(Math.round(x) + .5, P.top - 4); g.lineTo(Math.round(x) + .5, bottomY); g.stroke();
    const dot = (xx, yy, c) => { g.beginPath(); g.arc(xx, yy, 6, 0, 7); g.fillStyle = SURFACE; g.fill(); g.beginPath(); g.arc(xx, yy, 4, 0, 7); g.fillStyle = c; g.fill(); };
    if (B) { dot(x, yS(B.spd[i]), CYAN); dot(x, yT(B.thr[i]), CYAN); dot(x, yB(B.brk[i]), CYAN); }
    dot(x, yS(A.spd[i]), GOLD); dot(x, yT(A.thr[i]), GOLD); dot(x, yB(A.brk[i]), GOLD);
    if (yD) dot(x, yD(A.delta[i]), INK);
  }
}

// the outline: casing, edge, tarmac, the lap in bronze-to-gold by speed, the corners, and a dot where the cursor is
function drawMap() {
  const cv = $('mapc'); if (!cv || !V.pts) return;
  const box = cv.parentNode, dpr = window.devicePixelRatio || 1, w = box.clientWidth, h = box.clientHeight;
  if (!w || !h) return;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
  const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, w, h);
  const pts = V.pts, N = pts.length;
  let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
  for (const p of pts) { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[0]); y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); }
  const pad = 40, tw = x1 - x0 || 1, th = y1 - y0 || 1;
  const sA = Math.min((w - 2 * pad) / tw, (h - 2 * pad) / th), sB = Math.min((w - 2 * pad) / th, (h - 2 * pad) / tw), rot = sB > sA * 1.08, s = rot ? sB : sA;
  const sc = p => { let x = (p[0] - (x0 + x1) / 2) * s, y = -(p[1] - (y0 + y1) / 2) * s; if (rot) { const t = x; x = -y; y = t; } return [w / 2 + x, h / 2 + y]; };
  const scr = pts.map(sc);
  const at = pct => { const f = ((pct % 1) + 1) % 1 * N, i = Math.floor(f) % N, t = f - Math.floor(f), a = scr[i], b = scr[(i + 1) % N]; return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]; };
  const k = Math.max(0.7, Math.min(1.5, Math.min(w, h) / 440));
  g.lineJoin = 'round'; g.lineCap = 'round';
  const loop = () => { g.beginPath(); scr.forEach((q, i) => i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1])); g.closePath(); };
  loop(); g.strokeStyle = '#07090c'; g.lineWidth = 22 * k; g.stroke();
  loop(); g.strokeStyle = '#d3d8de'; g.lineWidth = 13 * k; g.stroke();
  loop(); g.strokeStyle = '#232a32'; g.lineWidth = 10 * k; g.stroke();
  const A = V.trace;
  if (A) {
    let lo = 1e9, hi = -1e9; for (let i = 0; i <= G; i++) { lo = Math.min(lo, A.spd[i]); hi = Math.max(hi, A.spd[i]); }
    for (let i = 0; i < N; i++) {
      const v = A.spd[Math.min(G, Math.round((i + 0.5) / N * G))], t = clamp((v - lo) / Math.max(1, hi - lo), 0, 1), a = scr[i], b = scr[(i + 1) % N];
      g.beginPath(); g.moveTo(a[0], a[1]); g.lineTo(b[0], b[1]); g.strokeStyle = 'rgb(' + Math.round(110 + t * 145) + ',' + Math.round(66 + t * 164) + ',' + Math.round(14 + t * 126) + ')'; g.lineWidth = 5.5 * k; g.stroke();
    }
  }
  // start line
  const s0 = at(0), s1 = at(0.003), dx = s1[0] - s0[0], dy = s1[1] - s0[1], m = Math.hypot(dx, dy) || 1;
  g.beginPath(); g.moveTo(s0[0] - dy / m * 14 * k, s0[1] + dx / m * 14 * k); g.lineTo(s0[0] + dy / m * 14 * k, s0[1] - dx / m * 14 * k); g.strokeStyle = '#fff'; g.lineWidth = 3.5 * k; g.stroke();
  V.discs = [];
  if (V.corners && V.corners.turns && V.corners.turns.length && typeof Corners !== 'undefined') {
    const r = Corners.draw(g, at, { data: V.corners, w, h, ticks: false, credit: true, scale: 0.8 });
    V.discs = r.discs || [];
  }
  // where the cursor is
  if (A && V.g >= 0) {
    const p = at(clamp(V.g, 0, G) / G);
    g.beginPath(); g.arc(p[0], p[1], 15 * k, 0, 7); g.fillStyle = 'rgba(41,211,245,.22)'; g.fill();
    g.beginPath(); g.arc(p[0], p[1], 9 * k, 0, 7); g.fillStyle = '#fff'; g.fill(); g.lineWidth = 3.5 * k; g.strokeStyle = CYAN; g.stroke();
  }
  if (!V.corners || !V.corners.turns || !V.corners.turns.length) { g.font = '12px ' + FONT; g.fillStyle = MUTE; g.textAlign = 'left'; g.textBaseline = 'alphabetic'; g.fillText('No corner list', 8, h - 8); }
}

/* ---------- the shared cursor ---------- */
function setCursor(g, seek) {
  V.g = clamp(Math.round(g), 0, G);
  if (seek && V.vid && V.sync) {
    const raw = videoRawAt(V.g), t = videoTimeAt(V.g);
    if (t != null) V.vid.currentTime = t;
    seekCompare(V.g);                       // the reference clip shows the same place on the track
    if (raw != null && (raw < 0 || raw > V.sync.dur)) toast('Outside the video');
  }
  drawAll();
  readout();
}

function pointer(e, press) {
  const box = $('plotBox'), r = box.getBoundingClientRect();
  if (!V.P || !V.trace) return;
  const mx = e.clientX - r.left;
  if (mx < V.P.left - 2 || mx > V.P.left + V.P.W + 2) { if (!press) leave(); return; }
  const playing = V.vid && !V.vid.paused && !V.vid.ended;
  const i = clamp(Math.round((mx - V.P.left) / V.P.W * G), 0, G);
  if (press) { setCursor(i, true); return; }
  if (playing) return;
  V.g = i; drawAll(); readout(e);
}
function leave() { $('tip').hidden = true; }

function readout(e) {
  const A = V.trace, B = V.ref, i = V.g, tip = $('tip'), box = $('plotBox');
  if (!A || i < 0 || !e) { if (!e) tip.hidden = true; return; }
  const f = V.kmh ? 3.6 : 2.236936, dist = (i / G * (A.lengthM || 0)) / (V.kmh ? 1000 : 1609.344);
  const near = V.corners && V.corners.turns ? (typeof Corners !== 'undefined' ? Corners.at(i / G, V.corners) : null) : null;
  let h = '<div class="at">' + dist.toFixed(V.kmh ? 2 : 3) + (V.kmh ? ' km' : ' mi') + (near && near.turn ? ' · T' + near.turn.n + (near.turn.name ? ' ' + esc(near.turn.name) : '') : '') + '</div>';
  h += '<div><b style="color:var(--gold)">' + Math.round(A.spd[i] * f) + '</b> ' + (V.kmh ? 'km/h' : 'mph') + ' · T ' + Math.round(A.thr[i]) + '% · B ' + Math.round(A.brk[i]) + '%</div>';
  if (B) h += '<div><b style="color:var(--cmp)">' + Math.round(B.spd[i] * f) + '</b> ' + (V.kmh ? 'km/h' : 'mph') + ' · T ' + Math.round(B.thr[i]) + '% · B ' + Math.round(B.brk[i]) + '%</div><div>Difference <b>' + fmtDelta(A.delta[i], 3) + ' s</b></div>';
  setHTML(tip, h); tip.hidden = false;
  const tw = tip.offsetWidth, th = tip.offsetHeight, x = V.xs(i), r = box.getBoundingClientRect();
  tip.style.left = Math.round(x + 18 + tw > box.clientWidth ? x - 18 - tw : x + 18) + 'px';
  tip.style.top = clamp(Math.round(e.clientY - r.top - th / 2), 4, Math.max(4, box.clientHeight - th - 4)) + 'px';
}

/* ================= the video ================= */
// video time of a point on the current lap = (where the line is in the video) + (elapsed time at that point) + the nudge
function lapSync(n) { return V.sync && V.sync.laps.find(l => l.n === n); }
function videoRawAt(g) {
  const ls = lapSync(V.lap); if (!ls || !V.trace) return null;
  return ls.v0 + V.trace.t[clamp(g, 0, G)] + V.sync.nudge;
}
function videoTimeAt(g) { const t = videoRawAt(g); return t == null ? null : clamp(t, 0, V.sync.dur || 1e9); }
// the inverse: the grid index a video time is at (the same telemetry timeline). Used to read the clock back from the picture.
function videoToGrid(v) {
  const ls = lapSync(V.lap); if (!ls || !V.trace) return -1;
  const target = v - V.sync.nudge - ls.v0, A = V.trace;
  if (target <= 0) return 0; if (target >= A.t[G]) return G;
  let lo = 0, hi = G; while (lo < hi) { const m = (lo + hi) >> 1; if (A.t[m] < target) lo = m + 1; else hi = m; }
  return lo;
}

// ---- Paddock's own recorder clip (P0-10): a lap names its clip through /vault/videoinfo, played from /vault/video (Range). ----
// The sidecar's lapStartOffset / lapEndOffset are seconds on the clip's own clock, exactly as workbench-video.js uses them:
// video time at lap time t = lapStartOffset + t. One clip covers one lap, so the shape matches the old sync object.
async function recInfo(id) {
  if (!id) return null;
  const r = await J('/vault/videoinfo?id=' + encodeURIComponent(id));
  if (!r.ok || !r.j || !r.j.id || r.j.error) return null;
  return r.j;
}
function recSync(ri, m) {
  return { clipStartMs: +ri.clipStartMs || 0, dur: +ri.duration || 0, nudge: (m && m.nudge) || 0,
    laps: [{ n: +ri.lap || V.lap || 0, time: +ri.lapTime || 0, v0: +ri.lapStartOffset || 0, v1: +ri.lapEndOffset || 0 }] };
}
// Pick the clip for this lap: the recorder's own first, then the old NVIDIA clip on this moment or its sibling.
async function prepareVideo(m, seq) {
  const c = V.cur; if (!c) return;
  V.rec = false; V.rc = null; V.rcRef = null; V.videoId = ''; V.sync = null; V.vid = $('vid');
  const ri = await recInfo(V.id);
  if (seq !== V.seq) return;
  if (ri && ri.id) {
    V.rec = true; V.rc = ri; V.videoId = ri.id; c.sync = recSync(ri, m);
    if (+ri.lap > 0 && +ri.lap !== V.lap && V.laps && V.laps.laps.some(l => l.n === +ri.lap)) V.lap = +ri.lap;
  } else if (!c.sync) {
    await attachSiblingVideo(m, seq);
  }
  if (seq !== V.seq) return;
  setupVideo(m);
}

function stopVideo() { if (V.vid) { try { V.vid.pause(); V.vid.removeAttribute('src'); V.vid.removeAttribute('controls'); V.vid.load(); } catch (e) { } } V.vid = null; V.videoId = ''; V.sync = null; V.rec = false; V.rc = null; V.rcRef = null; cancelAnimationFrame(V.raf); }

function setupVideo(m) {
  const c = V.cur;
  V.sync = c.sync; V.vid = $('vid');
  if (!c.sync) { $('vidWrap').hidden = true; if (V.vid) V.vid.removeAttribute('controls'); return; }
  $('vidWrap').hidden = false;
  V.vid.controls = true;
  if (!V.videoId) V.videoId = m.id;
  V.vid.src = (V.rec ? '/vault/video?id=' : '/vault/clip?id=') + encodeURIComponent(V.videoId);
  V.vid.onseeked = () => follow(true);
  V.vid.onplay = () => { alignOnPlay(V.vid); loop(); };
  V.vid.ontimeupdate = () => { if (V.vid.paused) follow(true); };
  renderSync();
  const first = c.sync.laps.find(l => l.n === V.lap) || c.sync.laps[0];
  if (first && first.n !== V.lap) { V.lap = first.n; }
}

function renderSync() {
  const s = V.sync; if (!s) return;
  const n = s.nudge;
  setHTML('sync', 'SYNC <button class="btn" data-n="-0.5" type="button">−0.5</button><button class="btn" data-n="-0.1" type="button">−0.1</button><b>' + (n > 0 ? '+' : '') + n.toFixed(1) + ' s</b><button class="btn" data-n="0.1" type="button">+0.1</button><button class="btn" data-n="0.5" type="button">+0.5</button>');
  document.querySelectorAll('#sync [data-n]').forEach(b => b.onclick = async () => {
    const nv = Math.max(-3, Math.min(3, Math.round((s.nudge + parseFloat(b.dataset.n)) * 10) / 10));
    const keep = V.vid ? V.vid.currentTime : 0;
    s.nudge = nv; renderSync(); follow(true);
    const nid = V.videoId || V.id;
    const r = await J('/vault/edit?id=' + encodeURIComponent(nid) + '&nudge=' + nv);
    if (r.ok && r.j && r.j.m && nid === V.id) { V.cur = r.j; }
    void keep;
  });
}

// the cursor follows the video: find the lap the video time is in, then the point inside it
function follow(force) {
  if (!V.vid || !V.sync) return;
  const t = V.vid.currentTime - V.sync.nudge;
  let ls = lapSync(V.lap);
  if (!ls || t < ls.v0 || t > ls.v1) {
    const next = V.sync.laps.find(l => t >= l.v0 && t <= l.v1);
    if (next && next.n !== V.lap) { V.lap = next.n; const keepT = V.vid.currentTime; renderLeft(); pickReference().then(showTraces).then(() => { follow(true); void keepT; }); return; }
    if (!ls) return;
  }
  const A = V.trace; if (!A) return;
  const target = t - ls.v0;
  let lo = 0, hi = G;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (A.t[mid] < target) lo = mid + 1; else hi = mid; }
  const g = target <= 0 ? 0 : target >= A.t[G] ? G : lo;
  if (force || g !== V.g) { V.g = g; drawAll(); }
}

function loop() {
  cancelAnimationFrame(V.raf);
  const step = () => {
    if (!V.vid) return;
    if (V.vid2 && V.rcRef) lockLive();
    const alive = !V.vid.ended && (!V.vid.paused || (V.vid2 && !V.vid2.paused));
    if (!alive) return;
    if (!V.vid.paused) follow(false);
    V.raf = requestAnimationFrame(step);
  };
  V.raf = requestAnimationFrame(step);
}

/* ================= two recorder clips locked by track position (P0-10) ================= */
// A second lap of the same car+track, never this lap's own session file. When both laps have a recorder clip the
// reference is shown beside this lap, and both are kept at the same LapDistPct: the clip that is ahead in position
// waits (pauses) until the other catches up. The telemetry grid index IS the lap distance (0..1000 = 0..100 %).
function lockSide(t, off, dur, nudge) { return { t: t, off: +off || 0, dur: +dur || 0, nudge: +nudge || 0, v: +off || 0, paused: false }; }
function lockGrid(side, v) {
  const s = v - side.nudge - side.off, t = side.t;
  if (!t || !t.length) return 0;
  if (s <= 0) return 0; if (s >= t[G]) return G;
  let lo = 0, hi = G; while (lo < hi) { const m = (lo + hi) >> 1; if (t[m] < s) lo = m + 1; else hi = m; }
  const i = Math.max(1, lo), a = t[i - 1], b = t[i], f = b > a ? (s - a) / (b - a) : 0;
  return (i - 1) + f;
}
// the shorter way round the lap: the start/finish line must not look like a 100 % jump
function lockWrap(d) { if (d > G / 2) d -= G; else if (d < -G / 2) d += G; return d; }
// one step of dt seconds: advance both, then pause the one ahead when it leads by more than 0.2 % of a lap (2 grid),
// and let both play again once they are within 0.1 % (1 grid). Hysteresis, so they do not flicker.
function lockStep(A, B, dt) {
  if (!A.paused) A.v += dt;
  if (!B.paused) B.v += dt;
  const pa = lockGrid(A, A.v), pb = lockGrid(B, B.v), d = lockWrap(pa - pb);
  if (Math.abs(d) > 2) { if (d > 0) A.paused = true; else B.paused = true; }
  else if (Math.abs(d) < 1) { A.paused = false; B.paused = false; }
  return { pa: pa, pb: pb, d: d };
}
// for the test (P0-10 gate): run the lock and report, per corner, how close to the same position the two clips get.
function lockRun(A, B, dt, secs, corners) {
  const a = lockSide(A.t, A.off, A.dur, A.nudge), b = lockSide(B.t, B.off, B.dur, B.nudge);
  const cs = (corners || []).map(function (c) { return +c; });
  const del = cs.map(function () { return 1e9; });
  let maxd = 0;
  const n = Math.max(1, Math.round(secs / dt));
  for (let k = 0; k < n; k++) {
    const r = lockStep(a, b, dt); if (Math.abs(r.d) > maxd) maxd = Math.abs(r.d);
    for (let j = 0; j < cs.length; j++) { const c2 = Math.abs(r.pa - cs[j]); if (c2 <= 10) del[j] = Math.min(del[j], Math.abs(r.d)); }
  }
  const lap = a.t ? a.t[G] : 0;
  return { maxDelta: maxd, lap: lap, corners: cs.map(function (c, j) { return { g: c, delta: del[j], secs: del[j] / G * lap }; }) };
}
function refSide() { if (!V.rcRef || !V.ref) return null; return lockSide(V.ref.t, V.rcRef.lapStartOffset, V.rcRef.duration, V.cur && V.cur.m ? V.cur.m.nudge : 0); }
function seekCompare(g) {
  if (!V.vid2 || !V.rcRef || !V.ref) return;
  const t = V.rcRef.lapStartOffset + V.ref.t[clamp(g, 0, G)] + ((V.cur && V.cur.m ? V.cur.m.nudge : 0) || 0);
  V.vid2.currentTime = clamp(t, 0, V.vid2.duration || 1e9);
}
// Starting either clip makes its current track position the shared starting point.
function alignOnPlay(source) {
  if (!V.vid2 || !V.rcRef || !V.ref || !V.vid || !V.trace) return;
  let g;
  if (source === V.vid2) {
    const b = refSide(); if (!b) return;
    g = Math.round(lockGrid(b, V.vid2.currentTime));
    V.g = clamp(g, 0, G);
    V.vid.currentTime = videoTimeAt(V.g);
  } else {
    g = videoToGrid(V.vid.currentTime);
    V.g = clamp(g, 0, G);
    seekCompare(V.g);
  }
  drawAll();
}
// keep the two live clips at the same place: pause the clip that is ahead, resume both once they are level
function lockLive() {
  const b = refSide(), ls = lapSync(V.lap);
  if (!b || !V.vid2 || !ls || !V.trace) return;
  const A = lockSide(V.trace.t, ls.v0, V.sync.dur, V.sync.nudge);
  const pa = lockGrid(A, V.vid.currentTime), pb = lockGrid(b, V.vid2.currentTime), d = lockWrap(pa - pb);
  if (Math.abs(d) > 2) { if (d > 0) { if (!V.vid2.paused) V.vid.pause(); } else { if (!V.vid.paused) V.vid2.pause(); } }
  else if (Math.abs(d) < 1) {
    if (V.vid.paused && !V.vid.ended) { const p = V.vid.play(); if (p && p.catch) p.catch(function () { }); }
    if (V.vid2.paused && !V.vid2.ended) { const p = V.vid2.play(); if (p && p.catch) p.catch(function () { }); }
  }
}
function teardownVid2() {
  if (V.vid2) { try { V.vid2.pause(); V.vid2.removeAttribute('src'); V.vid2.load(); } catch (e) { } }
  const b = $('vid2Box'); if (b) b.remove();
  V.vid2 = null; V.rcRef = null; V.lockOn = false;
}
function buildVid2(ri) {
  const box = document.createElement('div'); box.id = 'vid2Box';
  const v = document.createElement('video'); v.id = 'vid2'; v.controls = true; v.muted = true; v.playsInline = true; v.preload = 'metadata';
  v.src = '/vault/video?id=' + encodeURIComponent(ri.id);
  v.addEventListener('play', function () { alignOnPlay(v); loop(); });
  box.appendChild(v);
  const lab = document.createElement('div'); lab.className = 'vlab';
  lab.textContent = 'Reference · lap ' + (V.refInfo ? V.refInfo.lap : ri.lap) + ' · ' + fmtLap(ri.lapTime);
  box.appendChild(lab);
  $('vidWrap').appendChild(box);
  V.vid2 = v; V.lockOn = true;
}
// Load the reference lap's recorder clip and show it beside this lap. Only when both have one; never this lap itself.
async function setupCompareVideo(seq) {
  teardownVid2();
  if (!V.rec || !V.refInfo || !V.vid || !V.rc) return;
  if (sameLap(V.refInfo, V.cur.m, V.lap)) return;
  const ri = await recInfo(V.refInfo.id);
  if (seq !== V.seq || !ri || !ri.id) return;
  if (!V.ref) { try { V.ref = await getTrace(V.refInfo.id, V.refInfo.lap); } catch (e) { } if (seq !== V.seq) return; }
  if (!V.ref) return;
  V.rcRef = ri;
  buildVid2(ri);
}

async function setCompare(c) { V.cmpId = c; renderLeft(); await pickReference(); await showTraces(); if (V.id) await setupCompareVideo(V.seq); }

/* ================= start ================= */
// for the tests (P0-10): the position lock, the recorder clip mapping and the self-compare rule
V.recInfo = recInfo;
V.videoToGrid = videoToGrid;
V.lockRun = lockRun;
V.lockGrid = lockGrid;
V.alignOnPlay = alignOnPlay;
V.sameLap = sameLap;
function init() {
  const v0 = $('vid'); if (v0) v0.removeAttribute('controls');
  $('closeBtn').hidden = true;   // standalone: nothing to close; embedded: pagehost draws the one CLOSE above every page
  $('closeBtn').onclick = closeMe;
  $('sessBtn').onclick = () => { location.href = 'sessions.html' + (EMBED ? '?embed=1' : ''); };
  $('backBtn').onclick = () => { location.hash = ''; };
  $('q').oninput = e => { V.f.q = e.target.value; renderGrid(); };
  const pl = $('plot');
  pl.addEventListener('pointermove', e => pointer(e, false)); pl.addEventListener('pointerleave', leave); pl.addEventListener('pointerdown', e => pointer(e, true));
  const mc = $('mapc');
  mc.addEventListener('click', e => {
    const r = mc.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
    let best = null, bd = 1e9;
    for (const d of V.discs) { const dd = Math.hypot(d.x - x, d.y - y); if (dd < bd) { bd = dd; best = d; } }
    if (best && bd < best.r * 2.2) setCursor(Math.round(best.turn.pctApex * G), true);
  });
  const ro = window.ResizeObserver ? new ResizeObserver(() => drawAll()) : null;
  if (ro) { ro.observe($('plotBox')); ro.observe($('mapBox')); } else window.addEventListener('resize', drawAll);
  window.addEventListener('hashchange', route);
  loadList().then(route);
  setInterval(() => { if (!V.id) loadList(); }, 15000);
  if (!EMBED) {
    let version = null;
    setInterval(async () => { try { const v = await (await fetch('/version', { cache: 'no-store' })).text(); if (version && v !== version) location.reload(); version = v; } catch (e) { } }, 15000);
  }
}
init();
