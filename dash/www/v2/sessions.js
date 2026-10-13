'use strict';
// Sessions page and lap analysis (D1 + D2). Shown over the idle screen (?embed=1, an iframe) or opened on its own at
// /v2/sessions.html. Data: /sessions (every session + personal bests) and /ibt/laps, /ibt/lap (one session's laps and
// the traces of a lap, 1001 points each on an even grid of lap distance, so two laps line up point for point).
// core.js and map.js are loaded only for their helpers and the corner names (TrackInfo).

const EMBED = /[?&]embed=1/.test(location.search);
const GOLD = '#f2c230', CYAN = '#29d3f5', INK = '#f4f1ea', MUTE = '#8d8a82', GRID = 'rgba(244,241,234,.07)', SURFACE = '#060606';
const FONT = 'Bahnschrift, "Segoe UI", sans-serif';
const G = 1000;   // grid steps per lap

const SX = {
  d: null, car: '', track: '', short: false, sig: '',
  kmh: (() => { const p = store.get('irdash-sess-kmh'); return p !== null ? p !== false : store.get('irdash-units') !== false; })(),   // your choice here, else the units iRacing last reported
  file: '', info: null, traces: new Map(), ref: null, cmp: null, g: -1, hl: -1, corners: [], mapPts: null, pend: 0,
};

const $$ = sel => document.querySelector(sel);
const secsTxt = s => s < 90 ? Math.round(s) + ' s' : s < 3600 ? Math.round(s / 60) + ' min' : Math.floor(s / 3600) + ' h ' + String(Math.round((s % 3600) / 60)).padStart(2, '0');
const dayTxt = ts => new Date(ts).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
const clockTxt = ts => new Date(ts).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
const typeTxt = t => /offline testing/i.test(t || '') ? 'Test' : /open qualify/i.test(t || '') ? 'Qualify' : (t || '');
const isPb = (s, pbs) => s.best != null && pbs.has(s.car + '|' + s.track + '|' + s.config) && Math.abs(pbs.get(s.car + '|' + s.track + '|' + s.config) - s.best) < 0.0005;

/* ---------------- the list ---------------- */
async function loadSessions() {
  try {
    const r = await fetch('/sessions', { cache: 'no-store' });
    const t = await r.text();
    if (t.length + ':' + t.slice(-60) !== SX.sig) { SX.sig = t.length + ':' + t.slice(-60); SX.d = JSON.parse(t); renderList(); }
    else if (SX.d) { SX.d.upgrading = JSON.parse(t).upgrading; renderStatus(); }
  } catch (e) { $('status').textContent = 'Not connected'; }
}

function chipRow(el, label, items, cur, set) {
  el.textContent = '';
  const l = document.createElement('label'); l.textContent = label; el.appendChild(l);
  for (const [value, text, n] of items) {
    const b = document.createElement('button'); b.type = 'button'; b.className = 'chip' + (value === cur ? ' on' : '');
    b.textContent = text;
    if (n != null) { const i = document.createElement('i'); i.textContent = n; b.appendChild(i); }
    b.onclick = () => set(value);
    el.appendChild(b);
  }
}

function renderStatus() {
  const d = SX.d; if (!d) return;
  const bits = [];
  if (d.upgrading > 0) bits.push('Reading sessions: ' + d.upgrading + ' to go');
  else if (d.scanning) bits.push('Reading new sessions');
  setText('status', bits.join(' · '));
}

function renderList() {
  const d = SX.d; if (!d) return;
  const real = d.sessions.filter(s => !s.short), nShort = d.sessions.length - real.length;
  const pool = SX.short ? d.sessions : real;
  const count = (key, val) => pool.filter(s => s[key] === val).length;
  const uniq = key => Array.from(new Set(pool.map(s => s[key]).filter(Boolean))).sort((a, b) => count(key, b) - count(key, a));
  if (SX.car && !uniq('car').includes(SX.car)) SX.car = '';
  if (SX.track && !uniq('track').includes(SX.track)) SX.track = '';
  chipRow($('fCar'), 'Car', [['', 'All cars']].concat(uniq('car').map(c => [c, c, count('car', c)])), SX.car, v => { SX.car = v; renderList(); });
  chipRow($('fTrack'), 'Track', [['', 'All tracks']].concat(uniq('track').map(t => [t, t, count('track', t)])), SX.track, v => { SX.track = v; renderList(); });
  const more = $('fMore'); more.textContent = '';
  if (nShort) {
    const b = document.createElement('button'); b.type = 'button'; b.className = 'chip' + (SX.short ? ' on' : '');
    b.textContent = (SX.short ? 'Showing' : 'Show') + ' short runs'; const i = document.createElement('i'); i.textContent = nShort; b.appendChild(i);
    b.onclick = () => { SX.short = !SX.short; renderList(); };
    more.appendChild(b);
  }
  const vis = pool.filter(s => (!SX.car || s.car === SX.car) && (!SX.track || s.track === SX.track));
  const secs = vis.reduce((a, s) => a + s.secs, 0), laps = vis.reduce((a, s) => a + s.laps, 0);
  setText('totals', vis.length + (vis.length === 1 ? ' session' : ' sessions') + ' · ' + (secs / 3600).toFixed(1) + ' h · ' + laps + ' laps');
  renderStatus();

  const pbs = new Map(d.pbs.map(p => [p.car + '|' + p.track + '|' + p.config, p.best]));
  const keep = $('sessList').scrollTop;
  let h = '<div class="th"><span>When</span><span>Car</span><span>Track</span><span>Type</span><span class="r">Laps</span><span class="r">Best lap</span><span class="r">Seat time</span><span></span></div>';
  if (!vis.length) h += '<div class="empty">' + (d.sessions.length ? 'No match' : 'No sessions yet') + '</div>';
  for (const s of vis) {
    const pb = isPb(s, pbs);
    h += '<div class="row' + (s.short ? ' short' : '') + (s.gone ? ' gone' : '') + '" tabindex="0" data-file="' + esc(s.file) + '"' + (s.gone ? ' title="The telemetry file was deleted"' : '') + '>' +
      '<span class="when"><b>' + esc(dayTxt(s.ts)) + '</b>' + esc(clockTxt(s.ts)) + '</span>' +
      '<span class="c">' + esc(s.car || '–') + '</span>' +
      '<span class="t">' + esc(s.track || '–') + (s.config ? '<small>' + esc(s.config) + '</small>' : '') + '</span>' +
      '<span class="ty">' + esc(typeTxt(s.type)) + '</span><span class="r">' + s.laps + '</span>' +
      '<span class="best' + (pb ? ' pb' : '') + (s.best == null ? ' none' : '') + '">' + (s.best != null ? fmtLap(s.best) : '–') + '</span>' +
      '<span class="r">' + esc(secsTxt(s.secs)) + '</span><span class="go">' + (s.gone ? '' : '›') + '</span></div>';
  }
  setHTML('sessList', h);
  $('sessList').scrollTop = keep;

  const pvis = d.pbs.filter(p => (!SX.car || p.car === SX.car) && (!SX.track || p.track === SX.track));
  // the benchmark card follows the filters: one car and track at a time (newest first), arrows step through the others
  if (!pvis.some(p => benchKey(p) === SX.bk)) SX.bk = pvis.length ? benchKey(pvis.slice().sort((a, b) => b.ts - a.ts)[0]) : '';
  SX.bvis = pvis;
  let ph = '';
  for (const p of pvis)
    ph += '<div class="row' + (benchKey(p) === SX.bk ? ' on' : '') + '" tabindex="0" data-file="' + esc(p.file) + '" data-bk="' + esc(benchKey(p)) + '"><span class="a"><b>' + esc(p.track) + (p.config ? ' · ' + esc(p.config) : '') + '</b><span>' + esc(p.car) +
      '</span></span><span class="tm">' + fmtLap(p.best) + '<small>' + esc(dayTxt(p.ts)) + ' · ' + p.sessions + (p.sessions === 1 ? ' session' : ' sessions') + '</small></span></div>';
  if (!pvis.length) ph = '<div class="empty">' + (d.upgrading > 0 ? 'Reading lap times' : 'No timed laps') + '</div>';
  setHTML('pbList', ph);
  renderBench();
}

/* ---------------- the benchmark card (bench.js) ---------------- */
const SAMPLE_BENCH = /[?&]bench=sample/.test(location.search);
const benchKey = p => p.car + '|' + p.track + '|' + p.config;

async function renderBench() {
  const box = $('benchBox'); if (!box) return;
  const list = SX.bvis || [], p = list.find(x => benchKey(x) === SX.bk);
  if (!p && !SAMPLE_BENCH) { SX.bc = null; setHTML(box, ''); return; }
  const key = SAMPLE_BENCH ? 'sample' : SX.bk, tag = key + '#' + SX.sig;
  let d = SX.bc && SX.bc.tag === tag ? SX.bc.data : null;
  if (!d) {
    try {
      const url = SAMPLE_BENCH ? '/bench?sample=1' : '/bench?car=' + encodeURIComponent(p.car) + '&track=' + encodeURIComponent(p.track) + '&config=' + encodeURIComponent(p.config || '');
      d = await (await fetch(url, { cache: 'no-store' })).json();
    } catch (e) { return; }
    if (key !== (SAMPLE_BENCH ? 'sample' : SX.bk)) return;           // you moved on while it loaded
    SX.bc = { tag, data: d };
  }
  const i = Math.max(0, list.indexOf(p));
  setHTML(box, BenchCard.html(d, { nav: { i, n: list.length }, link: !EMBED }));
  box.querySelectorAll('[data-step]').forEach(b => b.onclick = () => stepBench(+b.dataset.step));
}

function stepBench(dir) {
  const list = SX.bvis || []; if (list.length < 2) return;
  const i = list.findIndex(x => benchKey(x) === SX.bk), n = list.length;
  SX.bk = benchKey(list[(i + dir + n) % n]);
  document.querySelectorAll('#pbList .row').forEach(r => r.classList.toggle('on', r.dataset.bk === SX.bk));
  renderBench();
}

document.addEventListener('click', e => {
  const row = e.target.closest && e.target.closest('.row[data-file]');
  if (row && !row.classList.contains('gone')) location.hash = 'a=' + encodeURIComponent(row.dataset.file);
});
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') { if (SX.file) location.hash = ''; else closeMe(); return; }
  if (e.key === 'Enter' && document.activeElement && document.activeElement.dataset && document.activeElement.dataset.file) document.activeElement.click();
});

function closeMe() {
  if (EMBED && window.parent !== window) window.parent.postMessage({ irdash: 'sessions-close' }, location.origin);
}

/* ---------------- one session: laps ---------------- */
function route() {
  const m = /^#a=(.+)$/.exec(location.hash);
  if (m) { const f = decodeURIComponent(m[1]); if (f !== SX.file) openAnalysis(f); }
  else { SX.file = ''; $('topTitle').textContent = 'Sessions'; }
}

async function openAnalysis(file) {
  // A session row opens its best lap on the shared Workbench.
  try {
    const r = await fetch('/ibt/laps?file=' + encodeURIComponent(file), { cache: 'no-store' });
    const info = await r.json();
    if (!r.ok || !info || !info.best) return;
    const host = document.createElement('div'); host.id = 'wbHost';
    host.style.cssText = 'position:fixed;inset:0;z-index:10000;background:#09090a;color:#ece8df';
    host.innerHTML = '<button type="button" style="position:absolute;z-index:2;left:20px;top:14px;padding:12px 24px;background:#171719;border:1px solid #51451c;color:#ece8df;font:16px Bahnschrift,Segoe UI,sans-serif" id="wbBack">Back to Sessions</button><iframe title="Paddock Analysis" style="position:absolute;inset:0;width:100%;height:100%;border:0"></iframe>';
    host.querySelector('iframe').src = 'workbench.html?id=' + encodeURIComponent(file) + '&lap=' + encodeURIComponent(info.best);
    SX.file = file;
    document.body.appendChild(host);
    host.querySelector('#wbBack').addEventListener('click', () => { host.remove(); location.hash = ''; });
  } catch (e) { setText('status', 'Not connected'); }
}
/* ---------------- start ---------------- */
function init() {
  if (!EMBED) $('closeBtn').hidden = true; else $('closeBtn').onclick = closeMe;
  $('perfBtn').onclick = () => { location.href = 'perf.html' + (EMBED ? '?embed=1' : ''); };
  $('vaultBtn').onclick = () => { location.href = 'vault.html' + (EMBED ? '?embed=1' : ''); };
  $('backBtn').onclick = () => { location.hash = ''; };
  window.addEventListener('hashchange', route);
  $('viewList').hidden = false;
  loadSessions().then(route);
  setInterval(() => { if (!SX.file) loadSessions(); }, 20000);
  if (!EMBED) {
    let version = null;
    setInterval(async () => { try { const v = await (await fetch('/version', { cache: 'no-store' })).text(); if (version && v !== version) location.reload(); version = v; } catch (e) { } }, 15000);
  }
}
init();
