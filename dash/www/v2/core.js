'use strict';
// Core data model: connection to irdash (or the demo), iRacing session info, and everything derived
// from the raw telemetry (laps, sectors, fuel, relative, standings). ui.js only reads from here.

/* ---------------- helpers ---------------- */
const $ = id => document.getElementById(id);
const isNum = x => typeof x === 'number' && Number.isFinite(x);
const num = x => { const n = parseFloat(x); return Number.isFinite(n) ? n : NaN; };
const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const QS = new URLSearchParams(location.search);
// write to the DOM only when something changed (keeps the 10 Hz refresh free of needless layout work)
function setText(el, s) { if (typeof el === 'string') el = $(el); s = s == null ? '' : String(s); if (el && el._t !== s) { el._t = s; el.textContent = s; } }
function setHTML(el, s) { if (typeof el === 'string') el = $(el); if (el && el._h !== s) { el._h = s; el.innerHTML = s; } }
function setCls(el, s) { if (typeof el === 'string') el = $(el); if (el && el._c !== s) { el._c = s; el.className = s; } }
const store = {
  get(k) { try { const s = localStorage.getItem(k); return s ? JSON.parse(s) : null; } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* storage full or blocked */ } },
};

function fmtLap(t) {
  if (!isNum(t) || t <= 0) return '–:––.–––';
  const m = Math.floor(t / 60), s = t - m * 60;
  return m > 0 ? m + ':' + (s < 10 ? '0' : '') + s.toFixed(3) : s.toFixed(3);
}
function fmtDelta(d, digits) {
  if (!isNum(d)) return '–';
  return (d >= 0 ? '+' : '−') + Math.abs(d).toFixed(digits == null ? 2 : digits);
}
function fmtDur(sec) {
  if (!isNum(sec) || sec < 0) return '–';
  sec = Math.floor(sec);
  const h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, s = sec % 60;
  const p = n => (n < 10 ? '0' : '') + n;
  return h > 0 ? h + ':' + p(m) + ':' + p(s) : m + ':' + p(s);
}
function hexColor(c, fallback) {
  if (!c) return fallback || '#9aa4ae';
  const h = String(c).replace(/^0x/i, '').replace('#', '');
  return /^[0-9a-f]{1,6}$/i.test(h) ? '#' + h.padStart(6, '0') : (fallback || '#9aa4ae');
}

const Units = {
  metric: store.get('irdash-units') !== false,    // last units iRacing reported (kept in this browser), until a frame says
  speed(ms) { return this.metric ? ms * 3.6 : ms * 2.236936; },
  speedUnit() { return this.metric ? 'km/h' : 'mph'; },
  fuel(l, d) { if (!isNum(l)) return '–'; return this.metric ? l.toFixed(d == null ? 1 : d) + ' L' : (l / 3.785412).toFixed(d == null ? 2 : d + 1) + ' gal'; },
  temp(c, d) { if (!isNum(c)) return '–'; return this.metric ? c.toFixed(d || 0) + '°' : (c * 9 / 5 + 32).toFixed(d || 0) + '°'; },
  press(kpa) { if (!isNum(kpa) || kpa <= 0) return '–'; return this.metric ? kpa.toFixed(0) + ' kPa' : (kpa * 0.1450377).toFixed(1) + ' psi'; },
};

/* ---------------- minimal YAML parser for iRacing session info ---------------- */
function parseYaml(text) {
  const lines = [];
  for (const raw of text.split(/\r?\n/)) {
    const t = raw.trim();
    if (!t || t === '---' || t === '...' || t.startsWith('#')) continue;
    lines.push({ ind: raw.length - raw.trimStart().length, s: t });
  }
  let i = 0;
  const scalar = v => {
    v = v.trim();
    if (v.length >= 2 && ((v[0] === '"' && v.endsWith('"')) || (v[0] === "'" && v.endsWith("'")))) return v.slice(1, -1);
    return v;
  };
  const isItem = l => l.s === '-' || l.s.startsWith('- ');
  function node() {
    if (i >= lines.length) return null;
    return isItem(lines[i]) ? list(lines[i].ind) : map(lines[i].ind);
  }
  function map(ind) {
    const obj = {};
    while (i < lines.length && lines[i].ind === ind && !isItem(lines[i])) {
      const s = lines[i].s, c = s.indexOf(':');
      i++;
      if (c < 0) continue;
      const k = s.slice(0, c).trim(), v = s.slice(c + 1).trim();
      if (v !== '') obj[k] = scalar(v);
      else if (i < lines.length && (lines[i].ind > ind || (lines[i].ind === ind && isItem(lines[i])))) obj[k] = node();
      else obj[k] = '';
    }
    return obj;
  }
  function list(ind) {
    const arr = [];
    while (i < lines.length && lines[i].ind === ind && isItem(lines[i])) {
      const rest = lines[i].s.slice(1).trimStart();
      if (rest === '') { i++; arr.push(node()); continue; }
      const itemInd = ind + (lines[i].s.length - rest.length);
      if (rest.indexOf(':') < 0) { arr.push(scalar(rest)); i++; continue; }
      lines[i] = { ind: itemInd, s: rest };   // first key of the item sits on the dash line
      arr.push(map(itemInd));
    }
    return arr;
  }
  const root = {};
  while (i < lines.length) {
    const before = i;
    Object.assign(root, map(lines[i].ind));
    if (i === before) i++;
  }
  return root;
}

/* ---------------- variables we ask irdash for ---------------- */
const TIRE_VARS = [];
for (const c of ['LF', 'RF', 'LR', 'RR']) TIRE_VARS.push(c + 'tempCL', c + 'tempCM', c + 'tempCR', c + 'wearL', c + 'wearM', c + 'wearR', c + 'coldPressure');
const VARS = [
  'SessionTime', 'SessionNum', 'SessionUniqueID', 'SessionState', 'SessionFlags', 'SessionTimeRemain', 'SessionLapsRemainEx', 'SessionTimeOfDay',
  'PlayerCarIdx', 'PlayerCarPosition', 'PlayerCarClassPosition', 'PlayerCarMyIncidentCount', 'PlayerTrackSurface',
  'IsOnTrack', 'IsOnTrackCar', 'IsReplayPlaying', 'OnPitRoad', 'CamCarIdx', 'DisplayUnits', 'FrameRate',
  'Speed', 'RPM', 'Gear', 'Throttle', 'Brake', 'Clutch', 'SteeringWheelAngle', 'SteeringWheelAngleMax',
  'SteeringWheelMaxForceNm', 'SteeringWheelTorque', 'SteeringWheelPctTorque',
  'FuelLevel', 'FuelLevelPct', 'FuelUsePerHour',
  'Lap', 'LapCompleted', 'LapDistPct', 'LapCurrentLapTime', 'LapLastLapTime', 'LapBestLapTime',
  'LapDeltaToBestLap', 'LapDeltaToBestLap_OK', 'LapDeltaToSessionBestLap', 'LapDeltaToSessionBestLap_OK',
  'Lat', 'Lon', 'WaterTemp', 'OilTemp', 'OilPress', 'Voltage', 'EngineWarnings',
  'AirTemp', 'TrackTempCrew', 'TrackWetness', 'WindVel', 'WindDir', 'Precipitation', 'WeatherDeclaredWet', 'Skies', 'RelativeHumidity',
  'CarLeftRight', 'SessionLapsTotal',
  'dcBrakeBias', 'dcABS', 'dcTractionControl', 'dcTractionControl2',
  'CarIdxLapDistPct', 'CarIdxLap', 'CarIdxLapCompleted', 'CarIdxPosition', 'CarIdxClassPosition', 'CarIdxOnPitRoad',
  'CarIdxTrackSurface', 'CarIdxEstTime', 'CarIdxF2Time', 'CarIdxLastLapTime', 'CarIdxBestLapTime',
].concat(TIRE_VARS);

/* ---------------- session info (YAML) ---------------- */
const S = {
  version: 0, raw: '', y: null, me: -1, drivers: new Map(), multiClass: false, classCount: new Map(),
  track: { name: '', config: '', id: '', key: '', lengthKm: NaN }, sessions: [], sectors: [0], incLimit: '', fuelMax: NaN, sl: {},
};

function setSession(text) {
  if (!text || text === S.raw) return;
  let y;
  try { y = parseYaml(text); } catch (e) { console.warn('session yaml', e); return; }
  S.raw = text; S.y = y;
  const wi = y.WeekendInfo || {}, di = y.DriverInfo || {};
  const cfg = wi.TrackConfigName || '';
  S.track = {
    name: wi.TrackDisplayName || wi.TrackName || 'Track', config: cfg, id: String(wi.TrackID || ''), rawName: wi.TrackName || '',
    lengthKm: num(wi.TrackLength), city: wi.TrackCity || '', country: wi.TrackCountry || '',
    key: ('t' + (wi.TrackID || '0') + '-' + (wi.TrackName || cfg || 'track')).toLowerCase().replace(/[^a-z0-9_-]+/g, '-').slice(0, 80),
  };
  S.me = num(di.DriverCarIdx);
  S.drivers = new Map();
  S.classCount = new Map();
  for (const d of di.Drivers || []) {
    const idx = num(d.CarIdx);
    if (!isNum(idx)) continue;
    const drv = {
      idx, name: d.UserName || '', team: d.TeamName || '', num: d.CarNumber || '', car: d.CarScreenNameShort || d.CarScreenName || '',
      classId: num(d.CarClassID), cls: d.CarClassShortName || '', color: hexColor(d.CarClassColor, '#c9d1d9'),
      est: num(d.CarClassEstLapTime), ir: num(d.IRating), lic: d.LicString || '', licColor: hexColor(d.LicColor, '#888888'),
      pace: d.CarIsPaceCar === '1', spec: d.IsSpectator === '1',
    };
    S.drivers.set(idx, drv);
    if (!drv.pace && !drv.spec) S.classCount.set(drv.classId, (S.classCount.get(drv.classId) || 0) + 1);
  }
  S.multiClass = S.classCount.size > 1;
  S.sessions = (y.SessionInfo && y.SessionInfo.Sessions) || [];
  const secs = ((y.SplitTimeInfo || {}).Sectors || []).map(s => num(s.SectorStartPct)).filter(isNum).sort((a, b) => a - b);
  S.sectors = secs.length && secs[0] < 0.001 ? secs : [0].concat(secs);
  S.incLimit = (wi.WeekendOptions || {}).IncidentLimit || '';
  S.fuelMax = num(di.DriverCarFuelMaxLtr) * (num(di.DriverCarMaxFuelPct) || 1);
  S.sl = {
    first: num(di.DriverCarSLFirstRPM), shift: num(di.DriverCarSLShiftRPM), last: num(di.DriverCarSLLastRPM),
    blink: num(di.DriverCarSLBlinkRPM), red: num(di.DriverCarRedLine), idle: num(di.DriverCarIdleRPM),
  };
  S.version++;
  TrackMap.setTrack(S.track);
  TrackInfo.setTrack(S.track);
}

function currentSession() {
  const n = L.v.SessionNum;
  return S.sessions.find(s => num(s.SessionNum) === n) || S.sessions[S.sessions.length - 1] || null;
}
function sessionType() { const s = currentSession(); return s ? (s.SessionType || s.SessionName || 'Session') : 'Session'; }
function isRace() { return /race/i.test(sessionType()); }

/* ---------------- live state ---------------- */
const L = {
  v: {}, connected: false, demo: false, lastFrameAt: 0, sessKey: '',
  laps: [], pending: null, prevLC: null, lapStartFuel: null, lapDirty: true, prevFuel: null, why: newWhy(),
  sec: { idx: -1, start: 0, valid: false, dirty: false, cur: [], last: [], best: [] },
  prevPct: null, prevT: null,
  trace: [], traceMax: 330,
};

function resetLive() {
  L.laps = []; L.pending = null; L.prevLC = null; L.lapStartFuel = null; L.lapDirty = true; L.prevFuel = null; L.why = newWhy();
  L.sec = { idx: -1, start: 0, valid: false, dirty: false, cur: [], last: [], best: [] };
  L.prevPct = null; L.prevT = null;
}

function onFrame(v) {
  L.v = v; L.connected = true; L.lastFrameAt = performance.now();
  if (isNum(v.DisplayUnits)) { Units.metric = v.DisplayUnits === 1; if (Units.saved !== Units.metric) { Units.saved = Units.metric; store.set('irdash-units', Units.metric); } }
  const key = [v.SessionUniqueID, v.SessionNum, S.track.key].join('|');
  if (key !== L.sessKey) { resetLive(); L.sessKey = key; }
  trackLaps(v);
  trackSectors(v);
  pushTrace(v);
  TrackMap.feed(v);
  if (typeof Tv !== 'undefined') Tv.frame();
  if (typeof Drive !== 'undefined') Drive.onFrame(v);
  if (typeof Debrief !== 'undefined') Debrief.frame(v);   // debrief.js: stint summary when you get out
}

// WHY a lap is not clean (the reasons behind lapDirty), kept only so the post-session review can say OUT / IN / PIT / OFF
// when the session file cannot be read (debrief.js -> sessionreview.js). Pit road is placed like dash\src\analysis.cs does it:
// in the first fifth of the lap = out lap, in the last fifth = in lap, in between or both ends = pit.
function newWhy() { return { head: false, mid: false, tail: false, fuel: false, joined: false, away: false }; }
function whyOf(w) {
  if (w.mid || (w.head && w.tail)) return 'pit';
  if (w.head) return 'out';
  if (w.tail) return 'in';
  if (w.fuel) return 'pit';
  if (w.joined) return 'out';
  if (w.away) return 'off';
  return '';                                   // dirty for a reason we did not see: no word is made up
}

function trackLaps(v) {
  const lc = v.LapCompleted, fuel = v.FuelLevel;
  if (!isNum(lc) || !isNum(fuel)) return;
  const w = L.why || (L.why = newWhy()), rolls = L.prevLC !== null && lc === L.prevLC + 1;
  if (L.prevFuel != null && fuel > L.prevFuel + 0.2) { L.lapDirty = true; w.fuel = true; }            // refuelled
  if (v.OnPitRoad || !v.IsOnTrack) L.lapDirty = true;
  // on the frame the line is crossed the percentage has already wrapped to the new lap: pit road there is the END of the old lap
  if (v.OnPitRoad) { const p = v.LapDistPct; if (rolls) w.tail = true; else if (isNum(p) && p >= 0) { if (p < 0.2) w.head = true; else if (p >= 0.8) w.tail = true; else w.mid = true; } }
  else if (!v.IsOnTrack) w.away = true;
  if (L.prevLC === null) { L.prevLC = lc; L.lapStartFuel = fuel; L.lapDirty = true; w.joined = true; }
  else if (rolls) {
    const used = L.lapStartFuel - fuel;
    L.pending = { lap: lc, fuel: !L.lapDirty && used > 0.01 ? used : null, clean: !L.lapDirty, at: v.SessionTime, why: L.lapDirty ? whyOf(w) : '' };
    L.lapStartFuel = fuel; L.lapDirty = !!v.OnPitRoad; L.prevLC = lc;
    L.why = newWhy(); if (v.OnPitRoad) L.why.head = true;                // a lap that starts on pit road is an out lap
  } else if (lc !== L.prevLC) { L.prevLC = lc; L.lapStartFuel = fuel; L.lapDirty = true; L.why = newWhy(); }
  // iRacing publishes the official last-lap time a moment after the line; wait for it.
  if (L.pending && v.SessionTime - L.pending.at > 1.5) {
    const p = L.pending; L.pending = null;
    const own = L.sec.last.reduce((a, s) => (a != null && s && isNum(s.t) ? a + s.t : null), 0);
    p.time = v.LapLastLapTime > 0 ? v.LapLastLapTime : (own > 0 && L.sec.last.length === S.sectors.length ? own : null);
    p.sectors = L.sec.last.slice();
    L.laps.push(p);
    if (L.laps.length > 60) L.laps.shift();
  }
  L.prevFuel = fuel;
}

function sectorIndex(p) {
  let k = 0;
  for (let i = 0; i < S.sectors.length; i++) if (p >= S.sectors[i]) k = i;
  return k;
}

function trackSectors(v) {
  const pct = v.LapDistPct, t = v.SessionTime, sec = L.sec, n = S.sectors.length;
  if (!isNum(pct) || pct < 0 || !isNum(t) || !v.IsOnTrack) { L.prevPct = null; sec.valid = false; return; }
  if (v.OnPitRoad || v.PlayerTrackSurface === 0) sec.dirty = true;     // pit lane or off track: not a PB sector
  const close = (k, dt) => {
    if (!sec.valid || !(dt > 0.5)) return;
    const pb = !sec.dirty && (sec.best[k] == null || dt < sec.best[k]);
    if (pb) sec.best[k] = dt;
    sec.cur[k] = { t: dt, pb, dirty: sec.dirty };
  };
  const cross = (p0, p1, b) => L.prevT + (t - L.prevT) * clamp((b - p0) / (p1 - p0 || 1e-9), 0, 1);
  if (L.prevPct == null) {
    sec.idx = sectorIndex(pct); sec.valid = false;
  } else if (L.prevPct > 0.85 && pct < 0.15) {               // crossed the start/finish line
    const tc = cross(L.prevPct, pct + 1, 1);
    if (sec.idx === n - 1) close(n - 1, tc - sec.start);
    sec.last = sec.cur.slice(); sec.cur = []; sec.idx = 0; sec.start = tc; sec.valid = true; sec.dirty = !!v.OnPitRoad;
  } else if (Math.abs(pct - L.prevPct) > 0.03 || t < L.prevT) {  // tow, reset or replay jump
    sec.idx = sectorIndex(pct); sec.valid = false;
  } else {
    const k = sectorIndex(pct);
    if (k === sec.idx + 1) {
      const tc = cross(L.prevPct, pct, S.sectors[k]);
      close(sec.idx, tc - sec.start);
      sec.idx = k; sec.start = tc; sec.valid = true; sec.dirty = !!v.OnPitRoad || v.PlayerTrackSurface === 0;
    } else if (k !== sec.idx) { sec.idx = k; sec.valid = false; }
  }
  L.prevPct = pct; L.prevT = t;
}

function pushTrace(v) {
  if (!isNum(v.Throttle)) return;
  const steerMax = v.SteeringWheelAngleMax > 0 ? v.SteeringWheelAngleMax : 7.85;
  L.trace.push({
    thr: clamp(v.Throttle, 0, 1), brk: clamp(v.Brake || 0, 0, 1),
    clu: isNum(v.Clutch) ? clamp(1 - v.Clutch, 0, 1) : 0,
    st: clamp((v.SteeringWheelAngle || 0) / (steerMax / 2), -1, 1),
  });
  if (L.trace.length > L.traceMax) L.trace.splice(0, L.trace.length - L.traceMax);
}

/* ---------------- derived numbers ---------------- */
function focusIdx() {
  const v = L.v;
  if (v.IsOnTrack || !isNum(v.CamCarIdx) || v.CamCarIdx < 0) return isNum(v.PlayerCarIdx) ? v.PlayerCarIdx : S.me;
  return v.CamCarIdx;
}
function arr(name, i) { const a = L.v[name]; return a && i < a.length ? a[i] : undefined; }

function refLapTime(idx) {
  const d = S.drivers.get(idx);
  const best = arr('CarIdxBestLapTime', idx);
  if (best > 0) return best;
  if (L.v.LapBestLapTime > 0 && idx === L.v.PlayerCarIdx) return L.v.LapBestLapTime;
  if (d && d.est > 0) return d.est;
  return 120;
}

function racers() {
  const out = [];
  for (const d of S.drivers.values()) if (!d.pace && !d.spec) out.push(d);
  return out;
}

// Cars around the focus car on track, with time gaps (positive = ahead).
function computeRelative(nAhead, nBehind) {
  const me = focusIdx(), v = L.v;
  const pctMe = arr('CarIdxLapDistPct', me);
  if (!isNum(pctMe) || pctMe < 0) return null;
  const estMe = arr('CarIdxEstTime', me) || 0;
  const lapT = (S.drivers.get(me) || {}).est > 0 ? S.drivers.get(me).est : refLapTime(me);
  const distMe = (arr('CarIdxLapCompleted', me) || 0) + pctMe;
  const race = isRace();
  const rows = [];
  for (const d of racers()) {
    const i = d.idx;
    const pct = arr('CarIdxLapDistPct', i);
    if (!isNum(pct) || pct < 0 || arr('CarIdxTrackSurface', i) === -1) continue;
    let dp = pct - pctMe, gap = (arr('CarIdxEstTime', i) || 0) - estMe;
    if (dp > 0.5) { dp -= 1; gap -= lapT; } else if (dp < -0.5) { dp += 1; gap += lapT; }
    if (!isNum(gap)) gap = dp * lapT;
    const dist = (arr('CarIdxLapCompleted', i) || 0) + pct;
    const lapDiff = race && i !== me ? Math.round(dist - distMe - dp) : 0;
    rows.push({ d, gap: i === me ? 0 : gap, me: i === me, lapDiff, pit: !!arr('CarIdxOnPitRoad', i),
      pos: race || arr('CarIdxPosition', i) > 0 ? (S.multiClass ? arr('CarIdxClassPosition', i) : arr('CarIdxPosition', i)) : 0 });
  }
  rows.sort((a, b) => b.gap - a.gap);
  const k = rows.findIndex(r => r.me);
  if (k < 0) return null;
  const ahead = rows.slice(Math.max(0, k - nAhead), k), behind = rows.slice(k + 1, k + 1 + nBehind);
  return { ahead, me: rows[k], behind };
}

// Leaderboard rows sorted by position.
function computeStandings(onlyMyClass) {
  const v = L.v, me = focusIdx(), race = isRace();
  const myClass = (S.drivers.get(me) || {}).classId;
  const sess = currentSession();
  const results = new Map();
  for (const r of (sess && Array.isArray(sess.ResultsPositions) ? sess.ResultsPositions : [])) results.set(num(r.CarIdx), r);
  const live = (v.CarIdxPosition || []).some(p => p > 0);
  let rows = racers().map(d => {
    const i = d.idx, r = results.get(i);
    const pos = live ? arr('CarIdxPosition', i) : (r ? num(r.Position) : 0);
    const cpos = live ? arr('CarIdxClassPosition', i) : (r ? num(r.ClassPosition) + 1 : 0);
    const best = arr('CarIdxBestLapTime', i) > 0 ? arr('CarIdxBestLapTime', i) : (r ? num(r.FastestTime) : NaN);
    const last = arr('CarIdxLastLapTime', i) > 0 ? arr('CarIdxLastLapTime', i) : (r ? num(r.LastTime) : NaN);
    const pct = arr('CarIdxLapDistPct', i);
    return {
      d, pos: pos || 0, cpos: cpos || 0, best: best > 0 ? best : NaN, last: last > 0 ? last : NaN,
      f2: arr('CarIdxF2Time', i), dist: (arr('CarIdxLapCompleted', i) || 0) + (pct > 0 ? pct : 0),
      pit: !!arr('CarIdxOnPitRoad', i), out: !isNum(pct) || pct < 0 || arr('CarIdxTrackSurface', i) === -1, me: i === me,
    };
  });
  // iRacing leaves positions at zero until the first lap is complete. Derive the
  // running order from completed laps and lap fraction during that formation phase.
  if (race && !live) {
    const ordered = rows.slice().sort((a, b) => b.dist - a.dist || (a.best || 9e9) - (b.best || 9e9) || a.d.idx - b.d.idx);
    const overall = new Map(), classes = new Map();
    ordered.forEach((r, i) => {
      overall.set(r.d.idx, i + 1);
      const c = r.d.classId;
      classes.set(c, (classes.get(c) || 0) + 1);
      r.pos = i + 1; r.cpos = classes.get(c);
    });
  }
  if (onlyMyClass) rows = rows.filter(r => r.d.classId === myClass);
  const key = r => (onlyMyClass || !S.multiClass ? (r.cpos || r.pos) : r.pos);
  rows.sort((a, b) => {
    const pa = key(a) || 999, pb = key(b) || 999;
    if (pa !== pb) return pa - pb;
    return (a.best || 9e9) - (b.best || 9e9);
  });
  // gaps: per class, to that class's leader
  const leaders = new Map(), prevInClass = new Map(), fastest = new Map();
  for (const r of rows) {
    const c = r.d.classId;
    if (isNum(r.best) && (!fastest.has(c) || r.best < fastest.get(c))) fastest.set(c, r.best);
  }
  for (const r of rows) {
    const c = r.d.classId, lead = leaders.get(c);
    if (!lead) { leaders.set(c, r); r.gap = race ? (r.pos === 1 ? 'Leader' : '–') : (isNum(r.best) ? fmtLap(r.best) : '–'); r.gapNum = 0; }
    else if (race) {
      const lapsDown = Math.floor(lead.dist - r.dist + 0.0001);
      if (lapsDown >= 1 && !(r.f2 > 0 && r.f2 < refLapTime(r.d.idx) * 0.95)) r.gap = '+' + lapsDown + 'L';
      else if (isNum(r.f2) && isNum(lead.f2) && r.f2 - lead.f2 > 0) r.gap = '+' + (r.f2 - lead.f2).toFixed(1);
      else r.gap = '–';
    } else {
      r.gap = isNum(r.best) && isNum(lead.best) ? fmtDelta(r.best - lead.best, 3) : (isNum(r.best) ? fmtDelta(r.best - (fastest.get(c) || r.best), 3) : '–');
    }
    r.classBest = isNum(r.best) && r.best === fastest.get(c);
    prevInClass.set(c, r);
  }
  return rows;
}

function fuelModel() {
  const v = L.v, level = v.FuelLevel;
  const done = L.laps.filter(l => l.fuel > 0).slice(-5).map(l => l.fuel);
  let per = NaN, estimated = false;
  if (done.length) per = done.reduce((a, b) => a + b, 0) / done.length;
  else if (!L.lapDirty && isNum(L.lapStartFuel) && v.LapDistPct > 0.25) { per = (L.lapStartFuel - level) / v.LapDistPct; estimated = true; }
  const lapT = refLapTime(v.PlayerCarIdx);
  const pct = v.LapDistPct > 0 ? v.LapDistPct : 0;
  let left = NaN;                                        // laps (fractional) still to drive, including this one
  const remainEx = v.SessionLapsRemainEx;
  if (isRace() && isNum(remainEx) && remainEx > 0 && remainEx < 30000) left = remainEx - pct;
  else if (isRace() && isNum(v.SessionTimeRemain) && v.SessionTimeRemain > 0 && v.SessionTimeRemain < 7 * 86400) {
    // timed race: the race ends the first time you cross the line after the clock hits zero
    left = Math.max(Math.ceil(v.SessionTimeRemain / lapT + pct) - pct, 1 - pct);
  }
  const lapsOfFuel = per > 0 ? level / per : NaN;
  const need = per > 0 && isNum(left) ? left * per : NaN;
  const add = isNum(need) ? Math.max(0, need - level + per * 0.5) : NaN;    // half a lap of margin
  const stops = isNum(add) && S.fuelMax > 0 && add > 0 ? Math.ceil(add / S.fuelMax) : 0;
  // pit window for the next stop: open once the rest of the race fits in the tanks you still have to fill
  // (stops x a full tank), close when this tank runs dry. Laps are counted as iRacing shows them (current lap).
  let winOpen = NaN, winClose = NaN;
  if (stops > 0 && per > 0 && S.fuelMax > 0 && isNum(left) && isNum(v.Lap)) {
    const tankLaps = (S.fuelMax - per * 0.5) / per;        // a full tank, keeping the same half-lap margin
    const openIn = Math.max(0, left - stops * tankLaps);   // laps from now before stopping makes sense
    winOpen = v.Lap + Math.ceil(openIn);
    winClose = v.Lap + Math.max(0, Math.floor(lapsOfFuel - 0.5));
    if (winClose < winOpen) winClose = winOpen;            // short on fuel either way: box as soon as possible
  }
  return { level, pct: v.FuelLevelPct, per, estimated, laps: done.length, lapsOfFuel, left, need, add, stops, winOpen, winClose };
}

/* ---------------- connection ---------------- */
const Conn = {
  status: 'connecting',
  start() {
    if (QS.has('demo')) { L.demo = true; Demo.start(); this.status = 'demo'; return; }
    const url = '/stream?hz=' + (QS.get('hz') || 30) + '&vars=' + VARS.join(',');
    const es = new EventSource(url);
    es.onmessage = e => { try { onFrame(JSON.parse(e.data).v); this.status = 'live'; } catch (err) { console.warn(err); } };
    es.addEventListener('session', e => { try { setSession(JSON.parse(e.data)); } catch (err) { console.warn(err); } });
    es.addEventListener('status', e => { L.connected = false; this.status = 'nosim'; });
    es.onerror = () => { L.connected = false; this.status = 'noserver'; };
    // reload the page when the dashboard is updated - but never while you are driving: the new version waits until
    // you are out of the car, so helpers can keep working on the files during a race without a flicker on this screen
    let version = null;
    const check = async () => {
      if (document.hidden) return;
      try {
        const v = await (await fetch('/version', { cache: 'no-store' })).text();
        if (version && v !== version) {
          // keep the old version while he drives; ask again in 15 s. Only a FRESH frame counts: the last frame of a session
          // (or of a test's pretend race) keeps IsOnTrack set forever and blocked every update until the next drive.
          const fresh = L.connected && performance.now() - (L.lastFrameAt || 0) < 3000;
          if (fresh && L.v && L.v.IsOnTrack && !L.v.IsReplayPlaying) return;
          location.reload();
        }
        version = v;
      } catch (e) { /* irdash restarting */ }
    };
    check();
    setInterval(check, 15000);
  },
};
