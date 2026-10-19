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
// New York time, 12-hour, same style as HOME (these were en-GB 24-hour in the PC's own zone).
const NYZ = { timeZone: 'America/New_York' };
const nyPart = (ts, o) => new Date(ts).toLocaleDateString('en-US', Object.assign({}, o, NYZ));
const dayTxt = ts => nyPart(ts, { weekday: 'short' }) + ' ' + nyPart(ts, { day: 'numeric' }) + ' ' + nyPart(ts, { month: 'short' });
const clockTxt = ts => new Date(ts).toLocaleTimeString('en-US', Object.assign({ hour: 'numeric', minute: '2-digit' }, NYZ));
const dateTxt = ts => dayTxt(ts) + ' ' + nyPart(ts, { year: 'numeric' }) + ' ' + clockTxt(ts);
const dayKey = ts => nyPart(ts, { year: 'numeric', month: '2-digit', day: '2-digit' });
// "Today" / "Yesterday" for the newest two days, the date after that (the day header must be read at a glance)
const dayHead = ts => { const k = dayKey(ts), n = Date.now(); return k === dayKey(n) ? 'Today · ' + dayTxt(ts) : k === dayKey(n - 86400000) ? 'Yesterday · ' + dayTxt(ts) : dayTxt(ts) + (nyPart(ts, { year: 'numeric' }) !== nyPart(n, { year: 'numeric' }) ? ' ' + nyPart(ts, { year: 'numeric' }) : ''); };
const typeTxt = t => /offline testing/i.test(t || '') ? 'Test drive' : /open qualify|lone qualify/i.test(t || '') ? 'Qualifying' : (t || '');
const cfgTxt = c => /^full course$/i.test(c || '') ? '' : (c || '');

const V = {
  d: null, sig: '', f: { kind: '', car: '', track: '', tag: '', year: '', q: '' }, view: store.get('vault-view') || '', size: store.get('vault-size') || 'M',
  kmh: store.get('irdash-units') !== false,
  id: '', cur: null, laps: null, lap: 0, tr: new Map(), trace: null, ref: null, refInfo: null, cmpId: '', cmp: null,
  g: -1, pts: null, corners: null, discs: [], vid: null, videoId: '', ask: 0, stats: new Map(), seq: 0, showDelta: false, race: '',
  rec: false, rc: null, rcRef: null, vid2: null, lockOn: false, vis: [],
};
if (['S', 'M', 'L'].indexOf(V.size) < 0) V.size = 'M';
if (['', 'keep', 'race', 'best', 'clip'].indexOf(V.view) < 0) V.view = '';

/* ================= the grid ================= */
// 2026-10-18 Peter: "vault is a disaster ... hard to interpret". It was 50 identical track outlines under six rows of small chips.
// Now (docs\research\vault-references-2026-10.md): a real picture of each recorded lap with the length bottom-right (YouTube, every capture
// gallery), the lap time big and the result as a coloured word (purple fastest ever, green new PB: the timing-screen colours), grouped by
// day and then by session (F1 TV groups by event), a few big controls instead of chip rows, and S / M / L card sizes that are remembered.
async function loadList() {
  try {
    const t = await (await fetch('/vault/list', { cache: 'no-store' })).text();
    const sig = t.length + ':' + t.slice(-80) + ':' + t.slice(0, 600);
    if (sig !== V.sig) {
      V.sig = sig; V.d = JSON.parse(t);
      if (V.d && V.d.enabled === false) {
        setText('status', 'Vault is switched off.');
        setText('idNum', ''); setHTML('meter', ''); setHTML('setup', ''); setHTML('grid', '');
        return;
      }
      renderGrid();
    }
  } catch (e) { setText('status', 'Not connected'); }
}

const bytesTxt = b => b >= 1073741824 ? (b / 1073741824).toFixed(1) + ' GB' : b >= 1048576 ? Math.round(b / 1048576) + ' MB' : Math.round(b / 1024) + ' KB';

function renderMeter() {
  const d = V.d; if (!d) return;
  const pc = d.budgetBytes > 0 ? Math.min(100, d.usedBytes / d.budgetBytes * 100) : 0;
  setHTML('meter', bytesTxt(d.usedBytes) + ' of ' + bytesTxt(d.budgetBytes) + '<i><u style="width:' + pc.toFixed(1) + '%"></u></i>');
}

function isKeeper(m) { return m.keeper; }
const hasVid = m => !!(m.video || m.vid);
const isRace = m => m.kind === 'race';
const isBestLap = m => !isRace(m) && m.lapTime > 0 && (m.tags.indexOf('PB') >= 0 || m.tags.indexOf('BEST LAP') >= 0 || m.tags.indexOf('TOP 10') >= 0 || (isNum(m.gap) && Math.abs(m.gap) < 0.0005));

// No recorder yet: the page must not offer a video filter or say "video".
function vaultHasVideo(d) {
  if (!d) return false;
  if ((d.withVideo || 0) > 0 || (d.clips || 0) > 0 || (d.vids || 0) > 0) return true;
  return (d.moments || []).some(hasVid);
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
    // the tags of the other moment of this lap count too (a tag list that offered CLIP found no card before)
    const tags = x.card.tags.slice(); x.rest.forEach(r => (r.tags || []).forEach(t => { if (tags.indexOf(t) < 0) tags.push(t); }));
    const need = (vid && vid !== x.card) || (wantKeeper && !x.card.keeper) || tags.length !== x.card.tags.length;
    if (!need) { merged.push(x.card); continue; }
    const card = {};
    for (const key in x.card) card[key] = x.card[key];
    card.tags = tags;
    if (vid && vid !== x.card) {
      card.video = vid.video; card.videoDur = vid.videoDur; card.videoFrom = vid.id;
      if (!card.thumb && vid.thumb) { card.thumb = true; card.thumbId = vid.id; }
    }
    if (wantKeeper) card.keeper = true;
    merged.push(card);
  }
  return merged;
}

// the views: one press each, gold = the one on (as on the deck)
const VIEWS = [['', 'All'], ['keep', '★ Keepers'], ['race', 'Races'], ['best', 'Best laps'], ['clip', 'Videos']];
function inView(m, v) { return !v || (v === 'keep' ? m.keeper : v === 'race' ? isRace(m) : v === 'best' ? isBestLap(m) : v === 'clip' ? hasVid(m) : v === 'recent' ? !m.keeper : true); }

// a drop-down that opens a big list (no typing): [value, text, count]
function dropBtn(el, label, all, items, cur, set) {
  el.textContent = '';
  if (items.length < 2 && !cur) return;
  const b = document.createElement('button'); b.type = 'button'; b.className = 'drop' + (cur ? ' on' : ''); b.dataset.drop = label;
  const s = document.createElement('span'); s.textContent = cur || all; b.appendChild(s);
  b.onclick = e => { e.stopPropagation(); openPop(b, [['', all, null]].concat(items), cur, set); };
  el.appendChild(b);
}
function openPop(anchor, items, cur, set) {
  const pop = $('pop');
  if (!pop.hidden && pop._for === anchor) { closePop(); return; }
  pop.textContent = ''; pop._for = anchor;
  for (const [v, t, n] of items) {
    const b = document.createElement('button'); b.type = 'button'; b.className = v === cur ? 'on' : '';
    const s = document.createElement('span'); s.textContent = t; b.appendChild(s);
    if (n != null) { const i = document.createElement('i'); i.textContent = n; b.appendChild(i); }
    b.onclick = e => { e.stopPropagation(); closePop(); set(v); };
    pop.appendChild(b);
  }
  const host = $('viewGrid').getBoundingClientRect(), r = anchor.getBoundingClientRect();
  pop.style.left = Math.max(0, Math.min(r.left - host.left, host.width - 440)) + 'px'; pop.style.top = (r.bottom - host.top + 6) + 'px';
  pop.hidden = false;
  const first = pop.querySelector('button.on') || pop.querySelector('button'); if (first) first.focus();
}
function closePop() { const p = $('pop'); if (p && !p.hidden) { p.hidden = true; p._for = null; } }
document.addEventListener('click', e => { if (!$('pop').hidden && !$('pop').contains(e.target)) closePop(); });

function renderControls(ms, pass) {
  const cards = mergeCards(ms.slice().sort((a, b) => b.ts - a.ts));     // counts are cards, as shown
  const videoOn = vaultHasVideo(V.d);
  if (V.view === 'clip' && !videoOn) V.view = '';
  const k = $('fKind'); k.textContent = '';
  for (const [v, t] of VIEWS) {
    if (v === 'clip' && !videoOn) continue;
    const n = v ? cards.filter(m => inView(m, v)).length : null;
    if (v === 'race' && !n) continue;
    const b = document.createElement('button'); b.type = 'button'; b.className = 'tab' + (v === V.view ? ' on' : ''); b.dataset.view = v; b.setAttribute('role', 'tab');
    b.textContent = t; if (n != null) { const i = document.createElement('i'); i.textContent = n; b.appendChild(i); }
    b.onclick = () => { V.view = v; store.set('vault-view', v); $('gridScroll').scrollTop = 0; renderGrid(); };
    k.appendChild(b);
  }
  const uniq = (skip, get) => { const c = new Map(); cards.filter(m => pass(m, skip)).forEach(m => { const v = get(m); if (v) c.set(v, (c.get(v) || 0) + 1); }); return Array.from(c.entries()).sort((a, b) => b[1] - a[1]).map(([v, n]) => [v, v, n]); };
  dropBtn($('fCar'), 'car', 'All cars', uniq('car', m => m.car), V.f.car, v => { V.f.car = v; renderGrid(); });
  dropBtn($('fTrack'), 'track', 'All tracks', uniq('track', m => m.track), V.f.track, v => { V.f.track = v; renderGrid(); });
  // only the tags he can add himself (INCIDENT, OVERTAKE, CLEAN...): the automatic ones are the views and the coloured words
  const tc = new Map(); cards.filter(m => pass(m, 'tag')).forEach(m => m.tags.forEach(t => { if (AUTO.indexOf(t) < 0) tc.set(t, (tc.get(t) || 0) + 1); }));
  dropBtn($('fTag'), 'tag', 'Any tag', Array.from(tc.entries()).sort((a, b) => b[1] - a[1]).map(([t, n]) => [t, t, n]), V.f.tag, v => { V.f.tag = v; renderGrid(); });
  const yc = new Map(); cards.filter(m => pass(m, 'year')).forEach(m => { const y = nyPart(m.ts, { year: 'numeric' }); yc.set(y, (yc.get(y) || 0) + 1); });
  dropBtn($('fYear'), 'year', 'Every year', Array.from(yc.entries()).sort((a, b) => b[0] - a[0]).map(([y, n]) => [y, y, n]), V.f.year, v => { V.f.year = v; renderGrid(); });
  if ($('q').value !== V.f.q) $('q').value = V.f.q;
  const sz = $('fSize');
  if (!sz.firstChild) {
    sz.innerHTML = '<label>Size</label>' + ['S', 'M', 'L'].map(s => '<button class="sz" type="button" data-size="' + s + '" aria-label="' + ({ S: 'Small', M: 'Medium', L: 'Large' })[s] + ' cards">' + s + '</button>').join('');
    sz.querySelectorAll('.sz').forEach(b => b.onclick = () => setSize(b.dataset.size));
  }
  sz.querySelectorAll('.sz').forEach(b => b.classList.toggle('on', b.dataset.size === V.size));
}
function setSize(s) {
  if (['S', 'M', 'L'].indexOf(s) < 0) return;
  const changed = V.size !== s;
  V.size = s; store.set('vault-size', s);
  const g = $('grid'); g.classList.remove('s-S', 's-M', 's-L'); g.classList.add('s-' + s);
  $('fSize').querySelectorAll('.sz').forEach(b => b.classList.toggle('on', b.dataset.size === s));
  if (changed && V.d) renderGrid();                  // the session groups are laid out for the number of columns
}

const AUTO = ['PB', 'WIN', 'PODIUM', 'BEST LAP', 'TOP 10', 'BEST RACE', 'BIG IR'];
// the result as plain coloured words: purple = the fastest you have ever been here, green = it was a new personal best that day,
// gold = a win / podium / one of your three quickest ever. Never more than three, the strongest first.
function resultChips(m) {
  const c = [];
  if (isRace(m)) {
    if (m.tags.indexOf('WIN') >= 0) c.push(['win', 'Win']);
    else if (m.tags.indexOf('PODIUM') >= 0) c.push(['win', 'Podium']);
    if (m.tags.indexOf('BEST RACE') >= 0) c.push(['gold', 'Best finish']);
    if (isNum(m.irDelta) && Math.abs(m.irDelta) >= 1) c.push([m.irDelta > 0 ? 'up' : 'down', fmtDelta(m.irDelta, 0) + ' iRating']);
    if (!m.official && m.finished) c.push(['', 'AI race']);
  } else if (m.lapTime > 0) {
    if (isNum(m.gap) && Math.abs(m.gap) < 0.0005) c.push(['fast', 'Fastest ever']);
    else if (m.tags.indexOf('PB') >= 0) c.push(['newpb', 'New PB']);
    if (m.tags.indexOf('BEST LAP') >= 0 && !(isNum(m.gap) && Math.abs(m.gap) < 0.0005)) c.push(['gold', 'Top 3 ever']);
    else if (m.tags.indexOf('TOP 10') >= 0 && m.tags.indexOf('BEST LAP') < 0) c.push(['', 'Top 10 %']);
  }
  m.tags.forEach(t => { if (AUTO.indexOf(t) < 0) c.push([t === 'INCIDENT' ? 'down' : '', t.toLowerCase().replace(/^./, x => x.toUpperCase())]); });
  return c.slice(0, 3);
}
function resultClass(m) {
  if (isRace(m)) return m.tags.indexOf('WIN') >= 0 ? 'r-win' : m.tags.indexOf('PODIUM') >= 0 ? 'r-pod' : '';
  if (isNum(m.gap) && Math.abs(m.gap) < 0.0005 && m.lapTime > 0) return 'r-fast';
  return m.tags.indexOf('PB') >= 0 ? 'r-pb' : '';
}

function cardHTML(m, when) {
  const race = isRace(m);
  const fast = !race && isNum(m.gap) && Math.abs(m.gap) < 0.0005 && m.lapTime > 0;
  let big, gap = '';
  if (race) big = m.finished ? 'P' + m.pos + '<small>of ' + m.field + '</small>' : 'Did not finish';
  else if (m.kind === 'clip' && !(m.lapTime > 0)) big = fmtDur(m.videoDur);
  else big = fmtLap(m.lapTime);
  if (!race && isNum(m.gap) && m.lapTime > 0) gap = fast ? '<span class="gap fast">best lap</span>' : '<span class="gap">' + fmtDelta(m.gap, 3) + ' to best</span>';
  else if (race && m.lapTime > 0) gap = '<span class="gap">best ' + fmtLap(m.lapTime) + '</span>';
  // the picture: a real frame of the recording when there is one (irdash makes it in the background), else the map with this lap's line
  const pic = m.frame ? '<img loading="lazy" alt="" src="/vault/frame?id=' + encodeURIComponent(m.id) + '" data-map="' + (m.thumb ? encodeURIComponent(m.thumbId || m.id) : '') + '">'
    : m.thumb ? '<img class="map" loading="lazy" alt="" src="/vault/thumb?id=' + encodeURIComponent(m.thumbId || m.id) + '">' : '<div class="none">No picture yet</div>';
  const chips = resultChips(m).map(([k, t]) => '<span class="chip ' + k + '">' + esc(t) + '</span>').join('');
  const dur = m.vid ? m.vidDur : m.video ? m.videoDur : 0;
  const what = race ? (typeTxt(m.sType) || 'Race') : m.kind === 'clip' && !m.lap ? 'Video' : 'Lap ' + m.lap;
  return '<div class="card ' + resultClass(m) + (m.keeper ? ' keeper' : '') + (m.frame ? ' framed' : '') + '" tabindex="0" data-id="' + esc(m.id) + '">' +
    '<div class="th">' + pic + (chips ? '<div class="chips">' + chips + '</div>' : '') +
    (m.keeper ? '<span class="star" title="Kept for good">★</span>' : '') +
    (hasVid(m) ? '<span class="badge vid">▶ ' + fmtDur(dur) + '</span>' : '') + '</div>' +
    '<div class="meta"><div class="tm"><b>' + big + '</b>' + gap + '</div>' +
    '<div class="t1">' + esc(m.track || 'Unknown track') + (cfgTxt(m.config) ? ' · ' + esc(m.config) : '') + '</div>' +
    '<div class="t2"><span>' + esc(what) + ' · ' + esc(m.car || '') + '</span><span class="when">' + esc(when) + '</span></div></div></div>';
}

function renderGrid() {
  const d = V.d; if (!d) return;
  const ms = d.moments || [];
  renderMeter();
  const pass = (m, skip) => (skip === 'kind' || inView(m, V.view)) &&
    (skip === 'car' || !V.f.car || m.car === V.f.car) && (skip === 'track' || !V.f.track || m.track === V.f.track) && (skip === 'tag' || !V.f.tag || m.tags.indexOf(V.f.tag) >= 0) &&
    (skip === 'year' || !V.f.year || nyPart(m.ts, { year: 'numeric' }) === V.f.year) &&
    (skip === 'q' || !V.f.q || (m.car + ' ' + m.track + ' ' + m.config + ' ' + m.note + ' ' + m.tags.join(' ') + ' ' + m.sType + ' ' + typeTxt(m.sType)).toLowerCase().indexOf(V.f.q.toLowerCase()) >= 0);
  renderControls(ms, pass);
  const ordered = ms.slice().sort((a, b) => b.ts - a.ts);
  const vis = mergeCards(ordered).filter(m => pass(m, ''));
  V.vis = vis;
  setText('idNum', bytesTxt(d.usedBytes || 0) + ' · ' + ms.length + (ms.length === 1 ? ' moment' : ' moments'));
  const bits = [vis.length + (vis.length === 1 ? ' moment' : ' moments') + ' · ' + d.keepers + ' kept for good'];
  if (d.status === 'reading older sessions' || d.scanLeft > 0) bits.push('Reading sessions' + (d.scanLeft ? ': ' + d.scanLeft + ' to go' : ''));
  if (d.sandbox) bits.push('TEST VAULT');
  bits.push('other laps stay ' + d.recentDays + ' days');
  setText('totals', bits.join(' · '));
  renderSetup(d);
  const g = $('grid'); if (!g.classList.contains('s-' + V.size)) setSize(V.size);

  let h = '';
  if (V.view === 'best') {
    // best laps: one group per car and track, quickest first (Garage 61 groups laps by car; a PB only means something per car + track)
    const groups = new Map();
    for (const m of vis) { const k = m.car + '\n' + m.track + '\n' + m.config; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(m); }
    const gl = Array.from(groups.values()).sort((a, b) => Math.max.apply(null, b.map(x => x.ts)) - Math.max.apply(null, a.map(x => x.ts)));
    for (const l of gl) {
      l.sort((a, b) => (a.lapTime || 1e9) - (b.lapTime || 1e9));
      const m0 = l[0];
      h += '<div class="day">' + esc(m0.track) + (cfgTxt(m0.config) ? ' · ' + esc(m0.config) : '') + '<em>' + esc(m0.car) + ' · best ' + fmtLap(m0.pb || m0.lapTime) + ' · ' + l.length + (l.length === 1 ? ' lap' : ' laps') + '</em></div>';
      h += '<div class="cards">' + l.map(m => cardHTML(m, dayTxt(m.ts))).join('') + '</div>';
    }
  } else {
    // everything else: by day (sticky header), then by session, newest first; in a session the race comes first, then its laps quickest first
    // A session is a framed group with its own header; groups flow side by side in the day's grid, so a day of three short sessions is one row, not three.
    const cols = { S: 5, M: 4, L: 3 }[V.size] || 4;
    let day = '', sess = null, open = false;
    const flush = () => {
      if (!sess) return;
      const s = sess, m0 = s.items[0];
      s.items.sort((a, b) => (isRace(b) ? 1 : 0) - (isRace(a) ? 1 : 0) || (a.lapTime || 1e9) - (b.lapTime || 1e9));
      const n = s.items.length, span = Math.min(n, cols);
      h += '<div class="sgrp" style="grid-column:span ' + span + '"><div class="sess"><b>' + esc(m0.track) + (cfgTxt(m0.config) ? ' · ' + esc(m0.config) : '') + '</b>' +
        '<span class="ty">' + esc(typeTxt(m0.sType) || 'Session') + '</span><em>' + esc(clockTxt(s.ts)) + '</em></div>' +
        '<div class="cards" style="--cols:' + span + '">' + s.items.map(m => cardHTML(m, clockTxt(m.ts))).join('') + '</div></div>';
      sess = null;
    };
    const dayCount = new Map(); vis.forEach(m => { const k = dayKey(m.ts); dayCount.set(k, (dayCount.get(k) || 0) + 1); });
    for (const m of vis) {
      const dk = dayKey(m.ts), sk = (m.session || '') + '|' + (m.session ? '' : m.ts);
      if (dk !== day) {
        flush(); if (open) h += '</div>';
        day = dk; const n = dayCount.get(dk);
        h += '<div class="day">' + esc(dayHead(m.ts)) + '<em>' + n + (n === 1 ? ' moment' : ' moments') + '</em></div><div class="dgrid" style="--cols:' + cols + '">'; open = true;
      }
      if (!sess || sess.key !== sk) { flush(); sess = { key: sk, ts: m.ts, items: [] }; }
      sess.items.push(m);
    }
    flush(); if (open) h += '</div>';
  }
  if (!vis.length) {
    h = '<div class="empty">' + (ms.length ? '<b>Nothing here</b><br>' + (V.f.car || V.f.track || V.f.tag || V.f.year || V.f.q ? 'Try All cars / All tracks.' : 'Choose All.') : d.scanLeft > 0 || d.status !== 'up to date' ? '<b>Reading sessions</b>' :
      '<b>No laps yet</b>') + '</div>';
  }
  setHTML('grid', h);
  // a frame that cannot load (made on another PC, deleted) falls back to the map picture
  g.querySelectorAll('img[data-map]').forEach(im => { im.onerror = () => { const k = im.dataset.map; im.onerror = null; if (k) { im.className = 'map'; im.src = '/vault/thumb?id=' + k; } else im.remove(); }; });
}

function renderSetup(d) {
  // Video is recorded by Paddock itself. Do not send Peter to the NVIDIA app.
  if (!d) return;
  setHTML('setup', '');
}

// arrows move between cards (by the grid's own columns), Enter opens one
function moveCard(key) {
  const cards = Array.from(document.querySelectorAll('#grid .card'));
  if (!cards.length) return false;
  let i = cards.indexOf(document.activeElement);
  if (i < 0) { cards[0].focus(); return true; }
  const r0 = cards[i].getBoundingClientRect();
  let j = -1;
  if (key === 'ArrowRight') j = Math.min(cards.length - 1, i + 1);
  else if (key === 'ArrowLeft') j = Math.max(0, i - 1);
  else {
    // the nearest card straight below / above (rows are split by the session headers, so look at the boxes, not the index)
    let bd = 1e9;
    cards.forEach((c, k) => { const r = c.getBoundingClientRect(); const dy = key === 'ArrowDown' ? r.top - r0.bottom : r0.top - r.bottom; if (dy < -2) return; const dd = dy * 4 + Math.abs(r.left - r0.left); if (dd < bd) { bd = dd; j = k; } });
  }
  if (j >= 0) { cards[j].focus(); cards[j].scrollIntoView({ block: 'nearest' }); }
  return true;
}

document.addEventListener('click', e => {
  const c = e.target.closest && e.target.closest('.card[data-id]');
  if (c) location.hash = 'm=' + encodeURIComponent(c.dataset.id);
});
document.addEventListener('keydown', e => {
  const tg = e.target && e.target.tagName;
  if (tg === 'TEXTAREA' || (tg === 'INPUT' && e.target.type !== 'range')) { if (e.key === 'Escape') e.target.blur(); return; }
  if (e.key === 'Escape') {
    if (!$('pop').hidden) { closePop(); return; }
    if ($('wbHost')) closeRace(); else if (V.id && theaterOn()) setTheater(false); else if (V.id) location.hash = ''; else closeMe();
    return;
  }
  if (V.id && !$('wbHost') && V.vid && V.sync) {
    // the player: Space play / pause, arrows 5 s, F full screen, E (or T) expand, M sound
    const k = e.key.toLowerCase();
    if (k === ' ' || k === 'k') { e.preventDefault(); togglePlay(); return; }
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { e.preventDefault(); skip(e.key === 'ArrowLeft' ? -5 : 5); return; }
    if (k === 'f') { toggleFull(); return; }
    if (k === 'e' || k === 't') { setTheater(!theaterOn()); return; }
    if (k === 'm') { V.vid.muted = !V.vid.muted; return; }
  }
  if (!V.id && /^Arrow/.test(e.key) && $('pop').hidden) { if (moveCard(e.key)) e.preventDefault(); return; }
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
    V.id = ''; V.seq++; stopVideo(); teardownVid2(); setTheater(false); closeRace(true);
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
  closeRace(true);                                   // the previous moment's workbench must not stay over this one
  // refInfo too: it names the comparison of the PREVIOUS lap page, and stayed on show until /vault/laps came back
  V.id = id; V.cur = null; V.laps = null; V.trace = null; V.ref = null; V.refInfo = null; V.cmp = null; V.cmpId = cmp; V.g = -1; V.pts = null; V.corners = null; V.discs = []; V.stats = new Map(); V.tr = new Map(); V.ask = 0; V.videoId = ''; V.showDelta = false; V.race = '';
  $('viewGrid').hidden = true; $('viewDetail').hidden = false;
  teardownVid2(); closePop();
  setText('dTitle', 'Loading...'); wipe('dSub'); wipe('dActs'); wipe('cLeft'); wipe('cMore'); wipe('cornerBox'); wipe('legend'); $('vidWrap').hidden = true; blank('plot'); blank('mapc');
  const r = await J('/vault/item?id=' + encodeURIComponent(id));
  if (seq !== V.seq) return;
  if (r.j && r.j.enabled === false) { setText('dTitle', 'Vault is switched off'); return; }
  if (!r.ok || !r.j || !r.j.m) { setText('dTitle', 'Not found'); setHTML('cLeft', '<div class="msg"><b>Not in the Vault</b></div>'); return; }
  V.cur = r.j; const m = r.j.m;
  setText('dTitle', (m.track || (m.video ? 'Video' : 'Moment')) + (cfgTxt(m.config) ? ' · ' + m.config : '') + (m.lapTime > 0 && m.kind !== 'race' ? '  ·  ' + fmtLap(m.lapTime) : m.kind === 'race' && m.finished ? '  ·  P' + m.pos + ' of ' + m.field : ''));
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
      if (V.lap && !m.video) {
        // A race opens its RACE page (the whole field) when irdash logged it, else the analysis of its best lap.
        if (m.kind === 'race') { const ok = await checkRace(id, seq); if (seq !== V.seq) return; if (ok) openRace(true); else openWorkbench(id, V.lap); return; }
        checkRace(id, seq);                          // not awaited: the RACE button appears by itself when there is a race log
        // A lap that was recorded plays on the Vault's own player: the video big, the traces under it on one cursor, the SYNC nudge.
        // A lap without video opens the analysis workbench.
        // the list already says which laps have a clip (an older irdash does not: then ask), so a lap without one makes no 404 request
        const lm = listed(id), knows = !!(V.d && V.d.frames != null && lm);
        const ri = knows && !lm.vid ? null : await recInfo(id);
        if (seq !== V.seq) return;
        if (!ri) { openWorkbench(id, V.lap); return; }
      } else if (V.lap) checkRace(id, seq);
    }
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

// Opened straight from a card: BACK goes back to the cards (it used to uncover a half-built detail page with no laps and no traces).
function openWorkbench(id, lap) {
  if ($('wbHost') || !lap) return;
  const host = document.createElement('div'); host.id = 'wbHost'; host.dataset.grid = '1';
  host.innerHTML = '<div class="back" id="wbBack">‹ Back to the Vault</div><iframe title="Paddock Analysis"></iframe>';
  host.querySelector('iframe').src = 'workbench.html?id=' + encodeURIComponent(id) + '&lap=' + encodeURIComponent(lap);
  document.body.appendChild(host);
  requestAnimationFrame(() => host.classList.add('on'));
  host.querySelector('#wbBack').addEventListener('click', () => closeRace());
}

function renderHead() {
  const m = V.cur.m;
  const race = m.kind === 'race';
  // the result words are in the side column (big); here only what, where and when
  setHTML('dSub', esc([m.car, (m.lap && m.kind !== 'race' ? 'Lap ' + m.lap + ' · ' : '') + typeTxt(m.sType), dayTxt(m.ts) + ' · ' + clockTxt(m.ts)].filter(Boolean).join('  ·  ')));
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
  if ($('bRace')) $('bRace').onclick = () => openRace(false);
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
  if (!ok || seq !== V.seq || V.id !== id || !V.cur) return false;
  V.race = id; renderHead();
  return true;
}

// RACE: the analysis workbench on its RACE page, over the Vault (an iframe with a back bar, the same as ANALYSIS on the Session Review)
function openRace(fromGrid) {
  if (!V.lap) return;
  closeRace(true);                                   // a lap's workbench may already be up: the race page replaces it
  const host = document.createElement('div'); host.id = 'wbHost'; if (fromGrid === true) host.dataset.grid = '1';
  host.innerHTML = '<div class="back" id="wbBack">‹ Back to the Vault</div><iframe title="Paddock Analysis"></iframe>';
  host.querySelector('iframe').src = 'workbench.html?id=' + encodeURIComponent(V.id) + '&lap=' + V.lap + '&page=race';
  document.body.appendChild(host);
  requestAnimationFrame(() => host.classList.add('on'));
  host.querySelector('#wbBack').addEventListener('click', () => closeRace());
}
// quiet = only take the page away (a new moment opens, the grid comes back); otherwise a page opened from a card goes back to the cards
function closeRace(quiet) {
  const h = $('wbHost'); if (!h) return;
  h.classList.remove('on'); h.id = 'wbHostGone'; setTimeout(() => h.remove(), 450);
  if (quiet !== true && h.dataset.grid) location.hash = '';
}

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
  // DELETE asks twice, at the top of the side column where the answer is in view
  if (V.ask === 1) h += '<div class="ask"><div>Delete this ' + (m.kind === 'clip' ? 'video' : m.kind === 'race' ? 'race' : 'lap') + ' and its saved files?</div><div style="display:flex;gap:10px"><button class="btn" id="askNo" type="button">Keep it</button><button class="btn bad" id="askYes" type="button">Yes, delete</button></div></div>';
  if (V.ask === 2) h += '<div class="ask"><div><b>Cannot be undone</b></div><div style="display:flex;gap:10px"><button class="btn" id="askNo" type="button">Keep it</button><button class="btn bad" id="askYes2" type="button">Delete for good</button></div></div>';
  if (race) h += '<div class="big">' + (m.finished ? 'P' + m.pos : 'Race') + '</div><div class="facts"><div>' + (m.finished ? 'of <b>' + m.field + '</b> cars' + (m.official ? ' · official' : ' · offline') : 'Not finished') + '</div>' +
    (isNum(m.irDelta) && m.irDelta !== 0 ? '<div>iRating <b class="' + (m.irDelta > 0 ? 'good' : 'bad') + '">' + fmtDelta(m.irDelta, 0) + '</b></div>' : '') + (m.lapTime > 0 ? '<div>Best lap <b>' + fmtLap(m.lapTime) + '</b></div>' : '') + '</div>';
  else {
    const gap = c.pb ? m.lapTime - c.pb : null;
    h += '<div class="big"' + (isNum(gap) && Math.abs(gap) < 0.0005 ? ' style="color:var(--purple)"' : '') + '>' + (m.lapTime > 0 ? fmtLap(m.lapTime) : (m.video ? fmtDur(m.videoDur) : '–')) + '</div><div class="facts">' +
      (m.lap ? '<div>Lap <b>' + m.lap + '</b></div>' : '') + (isNum(gap) ? '<div class="gap">' + (Math.abs(gap) < 0.0005 ? '<b style="color:var(--purple)">Fastest ever here</b>' : '<b class="' + (gap > 0 ? 'bad' : 'good') + '">' + fmtDelta(gap, 3) + '</b> to best (' + fmtLap(c.pb) + ')') + '</div>' : '') +
      (m.pbBefore > 0 ? '<div>Beat <b>' + fmtLap(m.pbBefore) + '</b> by ' + (m.pbBefore - m.lapTime).toFixed(3) + ' s</div>' : '') + '</div>';
  }
  if (!c.hasTelemetry) h += '<div class="msg"><b>Telemetry file gone</b></div>';
  setHTML('cLeft', h);
  h = '';
  // laps of the session
  if (V.laps) {
    const laps = V.laps.laps.filter(l => l.time > 15), best = laps.filter(l => !l.pit).reduce((a, l) => Math.min(a, l.time), 1e9);
    h += '<h2>Laps<em>' + laps.length + ' full</em></h2><div class="scroll" id="lapScroll">';
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
  h += '<div class="tagrow">' + ['INCIDENT', 'OVERTAKE', 'CLEAN'].map(t => '<button class="btn' + (m.tags.indexOf(t) >= 0 ? ' on' : '') + '" data-tag="' + t + '" type="button">' + t + '</button>').join('') + '</div>';
  setHTML('cMore', h);
  if (V.ask && $('cSide')) $('cSide').scrollTop = 0;
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
// Why the check: with no recorder clip at all /vault/videoinfo can only answer 404, and that red line showed in the console on
// every lap and race card. Ask the server for the clip count first (kept 10 s) and do not ask for a clip that cannot exist.
let recSeen = { at: 0, any: true };
async function recAnyClips() {
  if (Date.now() - recSeen.at < 10000) return recSeen.any;
  const r = await J('/vault/recorder');
  recSeen = { at: Date.now(), any: !(r.ok && r.j && typeof r.j.clips === 'number' && r.j.clips === 0) };
  return recSeen.any;
}
async function recInfo(id) {
  if (!id) return null;
  if (!(await recAnyClips())) return null;
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

// The recordings carry the game's sound (dash\src\recaudio.cs). His volume / mute stays as he left it, on this screen, across laps and visits.
// Nothing plays by itself: sound only follows his own press on Play.
function soundPrefs(v) {
  if (!v || v._snd) return; v._snd = true;
  try { const p = JSON.parse(localStorage.getItem('paddock.sound') || 'null'); if (p) { v.volume = Math.max(0, Math.min(1, +p.v || 0)); v.muted = !!p.m; } } catch (e) { }
  v.addEventListener('volumechange', () => { try { localStorage.setItem('paddock.sound', JSON.stringify({ v: v.volume, m: v.muted })); } catch (e) { } });
}

function stopVideo() { if (V.vid) { try { V.vid.pause(); V.vid.removeAttribute('src'); V.vid.removeAttribute('controls'); V.vid.load(); } catch (e) { } } V.vid = null; V.videoId = ''; V.sync = null; V.rec = false; V.rc = null; V.rcRef = null; cancelAnimationFrame(V.raf); }

function setupVideo(m) {
  const c = V.cur;
  V.sync = c.sync; V.vid = $('vid');
  if (!c.sync) { $('vidWrap').hidden = true; if (V.vid) V.vid.removeAttribute('controls'); return; }
  $('vidWrap').hidden = false;
  V.vid.controls = true;
  soundPrefs(V.vid);
  if (!V.videoId) V.videoId = m.id;
  V.vid.src = (V.rec ? '/vault/video?id=' : '/vault/clip?id=') + encodeURIComponent(V.videoId);
  V.vid.onseeked = () => follow(true);
  V.vid.onplay = () => { alignOnPlay(V.vid); loop(); paintPlayer(); };
  V.vid.onpause = paintPlayer;
  V.vid.ontimeupdate = () => { if (V.vid.paused) follow(true); paintPlayer(); };
  applyVolume(V.vid);
  renderSync();
  paintPlayer();
  const first = c.sync.laps.find(l => l.n === V.lap) || c.sync.laps[0];
  if (first && first.n !== V.lap) { V.lap = first.n; }
}

/* ---------- the player's own controls: big buttons, sound that is remembered, EXPAND and FULL SCREEN ---------- */
// Volume and mute are kept in this browser (localStorage, wrapped: a private window has none) and set on every clip.
function applyVolume(v) {
  if (!v) return;
  const s = store.get('vault-vol') || {};
  v.volume = isNum(s.v) ? clamp(s.v, 0, 1) : 0.8;
  v.muted = !!s.m;
  v.onvolumechange = () => { store.set('vault-vol', { v: v.volume, m: v.muted }); paintPlayer(); };
}
function togglePlay() { const v = V.vid; if (!v) return; if (v.paused || v.ended) { const p = v.play(); if (p && p.catch) p.catch(() => { }); } else v.pause(); }
function skip(s) { const v = V.vid; if (!v) return; v.currentTime = clamp(v.currentTime + s, 0, v.duration || 1e9); }
function theaterOn() { return $('viewDetail').classList.contains('theater'); }
function setTheater(on) {
  const d = $('viewDetail'); if (!d) return;
  d.classList.toggle('theater', !!on);
  paintPlayer(); requestAnimationFrame(drawAll);
}
function fullEl() { return document.fullscreenElement || document.webkitFullscreenElement || null; }
function toggleFull() {
  const box = $('vidBox');
  try {
    if (fullEl()) (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    else if (box.requestFullscreen) { const p = box.requestFullscreen(); if (p && p.catch) p.catch(() => toast('Full screen is not allowed here')); }
    else if (box.webkitRequestFullscreen) box.webkitRequestFullscreen();
  } catch (e) { toast('Full screen is not allowed here'); }
}
document.addEventListener('fullscreenchange', () => paintPlayer());
function paintPlayer() {
  const v = V.vid; if (!v || !$('pPlay')) return;
  setText('pPlay', v.paused || v.ended ? '▶ Play' : 'Pause');
  setText('pMute', v.muted || v.volume === 0 ? 'Muted' : 'Sound on');
  $('pMute').classList.toggle('on', v.muted || v.volume === 0);
  const vol = $('pVol'); if (document.activeElement !== vol) vol.value = v.muted ? 0 : v.volume;
  setText('pTime', fmtDur(v.currentTime || 0) + ' / ' + fmtDur(isNum(v.duration) ? v.duration : 0));
  setText('pExpand', theaterOn() ? 'Smaller' : 'Expand'); $('pExpand').classList.toggle('on', theaterOn());
  setText('pFull', fullEl() ? 'Exit full screen' : 'Full screen');
}
function wirePlayer() {
  $('pPlay').onclick = togglePlay;
  $('pBack').onclick = () => skip(-5);
  $('pFwd').onclick = () => skip(5);
  $('pMute').onclick = () => { const v = V.vid; if (!v) return; if (v.muted || v.volume === 0) { v.muted = false; if (v.volume === 0) v.volume = 0.8; } else v.muted = true; };
  $('pVol').oninput = e => { const v = V.vid; if (!v) return; v.volume = +e.target.value; v.muted = +e.target.value === 0; };
  $('pExpand').onclick = () => setTheater(!theaterOn());
  $('pFull').onclick = toggleFull;
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
  $('vids').appendChild(box);
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
  wirePlayer();
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
  $('gridScroll').addEventListener('scroll', closePop, { passive: true });
  window.addEventListener('hashchange', route);
  loadList().then(route);
  setInterval(() => { if (!V.id) loadList(); }, 15000);
  if (!EMBED) {
    let version = null;
    setInterval(async () => { try { const v = await (await fetch('/version', { cache: 'no-store' })).text(); if (version && v !== version) location.reload(); version = v; } catch (e) { } }, 15000);
  }
}
init();
