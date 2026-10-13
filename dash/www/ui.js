'use strict';
// Rendering. Tables refresh 10x a second; the map, input trace and gauges every animation frame.

const UI = {
  standMode: (() => { try { return localStorage.getItem('irdash-stand') || 'all'; } catch (e) { return 'all'; } })(),

  init() {
    const bar = $('rpmbar');
    for (let i = 0; i < 16; i++) bar.appendChild(document.createElement('i'));
    $('standMode').onclick = () => {
      this.standMode = this.standMode === 'all' ? 'class' : 'all';
      try { localStorage.setItem('irdash-stand', this.standMode); } catch (e) { }
      this.slow();
    };
    setInterval(() => this.slow(), 100);
    if (!L.demo) { this.health(); setInterval(() => this.health(), 3000); }
    const loop = () => { try { this.fast(); } catch (e) { console.error(e); } requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
  },

  live() { return L.connected && performance.now() - L.lastFrameAt < 3000; },

  /* ---------- rig health strip and watchdog notices ---------- */
  async health() {
    let h;
    try { h = await (await fetch('/health', { cache: 'no-store' })).json(); } catch (e) { return; }
    const cls = s => (s === 'ok' || s === 'live') ? 'ok' : (s === 'loading' || s === 'starting') ? 'warn' : (s === 'stuck' || s === 'down') ? 'bad' : '';
    const word = { ok: 'running', live: 'in session', loading: 'loading', starting: 'starting', stuck: 'stuck', down: 'not running', off: 'off' };
    $('health').innerHTML = (h.apps || []).map(a =>
      '<span class="hd ' + cls(a.state) + '" title="' + esc(a.name + ': ' + (word[a.state] || a.state)) + '"><i></i>' + esc(a.name) + '</span>').join('');
    const last = (h.events || [])[h.events.length - 1];
    const t = $('toast');
    if (last && Date.now() - new Date(last.t).getTime() < 10 * 60 * 1000) {
      t.innerHTML = '<b>Rig fixed itself</b>' + esc(last.msg);
      t.hidden = false;
    } else t.hidden = true;
  },

  /* ---------- 10 Hz ---------- */
  slow() {
    try {
      const live = this.live();
      this.overlay(live);
      this.header(live);
      if (!live) return;
      this.standings();
      this.relative();
      this.timing();
      this.fuel();
      this.car();
    } catch (e) { console.error(e); }
  },

  overlay(live) {
    const ov = $('overlay');
    ov.classList.toggle('show', !live);
    if (!live) {
      const st = Conn.status;
      $('ovTitle').textContent = st === 'noserver' ? 'irdash is not running' : 'Waiting for iRacing';
      $('ovText').textContent = st === 'noserver'
        ? 'Start irdash.exe from the iRacingDeck\\dash folder. This page reconnects by itself.'
        : 'Start a session and the dashboard comes alive on its own.';
    }
    const c = $('conn');
    c.className = 'conn' + (L.demo ? ' demo' : live ? ' ok' : '');
    c.title = L.demo ? 'demo data' : live ? 'live from iRacing' : Conn.status;
  },

  header(live) {
    const now = new Date();
    $('clock').textContent = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    if (!live) { this.setFlag('', 'Offline'); return; }
    const v = L.v;
    $('trackName').textContent = S.track.name || '–';
    $('trackSub').textContent = [S.track.config, isNum(S.track.lengthKm) ? S.track.lengthKm.toFixed(2) + ' km' : '', v.TrackWetness > 1 ? 'wet' : '']
      .filter(Boolean).join('  ·  ');
    const sess = currentSession();
    $('sessType').textContent = sessionType();
    const lapsTotal = sess ? num(sess.SessionLaps) : NaN;
    let remain = '–';
    if (isNum(lapsTotal) && lapsTotal > 0) remain = 'Lap ' + Math.max(1, Math.min(lapsTotal, v.Lap || 1)) + ' / ' + lapsTotal;
    else if (isNum(v.SessionTimeRemain) && v.SessionTimeRemain >= 0 && v.SessionTimeRemain < 7 * 86400) remain = fmtDur(v.SessionTimeRemain);
    $('sessRemain').textContent = remain;
    const total = racers().length;
    $('hPos').textContent = v.PlayerCarPosition > 0 ? 'P' + v.PlayerCarPosition + ' / ' + total : '–';
    $('hClsBox').style.display = S.multiClass ? '' : 'none';
    const myCls = (S.drivers.get(v.PlayerCarIdx) || {}).classId;
    $('hCls').textContent = v.PlayerCarClassPosition > 0 ? 'P' + v.PlayerCarClassPosition + ' / ' + (S.classCount.get(myCls) || '–') : '–';
    $('hLap').textContent = isNum(v.Lap) && v.Lap > 0 ? v.Lap : '–';
    const lim = num(S.incLimit);
    $('hInc').textContent = isNum(v.PlayerCarMyIncidentCount) ? v.PlayerCarMyIncidentCount + 'x' + (isNum(lim) ? ' / ' + lim : '') : '–';
    $('hInc').style.color = isNum(lim) && v.PlayerCarMyIncidentCount >= lim * 0.75 ? 'var(--red)' : '';
    $('hTemp').textContent = Units.temp(v.AirTemp) + ' / ' + Units.temp(v.TrackTempCrew);
    this.flags(v.SessionFlags >>> 0);
  },

  flags(f) {
    const F = { checkered: 0x1, white: 0x2, green: 0x4, yellow: 0x8, red: 0x10, blue: 0x20, debris: 0x40, crossed: 0x80,
      yellowWaving: 0x100, oneToGreen: 0x200, greenHeld: 0x400, tenToGo: 0x800, fiveToGo: 0x1000, caution: 0x4000, cautionWaving: 0x8000,
      black: 0x10000, dq: 0x20000, furled: 0x80000, repair: 0x100000 };
    const has = k => (f & F[k]) !== 0;
    if (has('dq')) return this.setFlag('black', 'Disqualified');
    if (has('black')) return this.setFlag('black', 'Black flag', true);
    if (has('repair')) return this.setFlag('meatball', 'Repair');
    if (has('furled')) return this.setFlag('black', 'Warning');
    if (has('checkered')) return this.setFlag('checkered', 'Finish');
    if (has('red')) return this.setFlag('red', 'Red flag');
    if (has('caution') || has('cautionWaving')) return this.setFlag('yellow', 'Caution', has('cautionWaving'));
    if (has('yellow') || has('yellowWaving') || has('debris')) return this.setFlag('yellow', has('debris') ? 'Debris' : 'Yellow', has('yellowWaving'));
    if (has('blue')) return this.setFlag('blue', 'Blue flag', true);
    if (has('white')) return this.setFlag('white', 'Last lap');
    if (has('oneToGreen')) return this.setFlag('green', 'One to green');
    if (has('green') || has('greenHeld')) return this.setFlag('green', 'Green');
    this.setFlag('', isRace() ? 'Grid' : 'Running');
  },
  setFlag(cls, text, blink) {
    const el = $('flag');
    el.className = 'flag ' + cls + (blink ? ' blink' : '');
    el.textContent = text;
  },

  lic(d) {
    if (!d.lic) return '';
    return '<span class="lic" style="background:' + d.licColor + '">' + esc(d.lic.split(' ')[0]) + '</span>' +
      (d.ir > 0 ? (d.ir / 1000).toFixed(1) + 'k' : '');
  },

  standings() {
    const onlyClass = this.standMode === 'class' && S.multiClass;
    $('standMode').style.display = S.multiClass ? '' : 'none';
    $('standMode').textContent = onlyClass ? 'My class' : 'All classes';
    let rows = computeStandings(onlyClass);
    $('standSub').textContent = rows.length + ' cars';
    const box = $('standings');
    const max = Math.max(5, Math.floor((box.clientHeight - 26) / 32));
    let shown = rows, cut = -1;
    if (rows.length > max) {
      const k = Math.max(0, rows.findIndex(r => r.me));
      const top = 3;
      if (k < max - 2) shown = rows.slice(0, max);
      else {
        const rest = max - top - 1, start = Math.min(rows.length - rest, Math.max(top, k - Math.floor(rest / 2)));
        shown = rows.slice(0, top).concat([null], rows.slice(start, start + rest));
        cut = top;
      }
    }
    const race = isRace();
    let h = '<div class="srow hd"><span class="pos">Pos</span><span></span><span>#</span><span>Driver</span><span class="ir">Lic</span>' +
      '<span class="t">Last</span><span class="t">Best</span><span class="gap">' + (race ? 'Gap' : 'Δ Best') + '</span></div>';
    for (const r of shown) {
      if (!r) { h += '<div class="srow gapline"></div>'; continue; }
      const p = S.multiClass && !onlyClass ? (r.pos || '–') : (r.cpos || r.pos || '–');
      const cls = 'srow' + (r.me ? ' me' : '') + (r.pit ? ' pit' : '') + (r.out ? ' out' : '');
      h += '<div class="' + cls + '"><span class="pos">' + p + '</span><span class="cbar" style="background:' + r.d.color + '"></span>' +
        '<span class="num">#' + esc(r.d.num) + '</span><span class="nm">' + esc(r.d.name) + '</span><span class="ir">' + this.lic(r.d) + '</span>' +
        '<span class="t">' + (isNum(r.last) ? fmtLap(r.last) : '–') + '</span>' +
        '<span class="t' + (r.classBest ? ' fast' : '') + '">' + (isNum(r.best) ? fmtLap(r.best) : '–') + '</span>' +
        '<span class="gap">' + esc(r.gap) + '</span></div>';
    }
    box.innerHTML = h;
  },

  relative() {
    const box = $('relative');
    const per = Math.max(2, Math.floor((box.clientHeight / 39 - 1) / 2));
    const rel = computeRelative(per, per);
    if (!rel) { box.innerHTML = '<div class="rrow empty"><span></span><span></span><span></span><span class="nm" style="color:var(--muted)">No car on track</span></div>'; return; }
    const row = r => {
      if (!r) return '<div class="rrow empty"></div>';
      const cls = 'rrow' + (r.me ? ' me' : '') + (r.pit ? ' pit' : '') + (r.lapDiff > 0 ? ' ahead-lap' : r.lapDiff < 0 ? ' behind-lap' : '') +
        (!r.me && Math.abs(r.gap) < 1 ? ' close' : '');
      const gap = r.me ? '' : (r.gap >= 0 ? '+' : '−') + Math.abs(r.gap).toFixed(1);
      return '<div class="' + cls + '"><span class="pos">' + (r.pos > 0 ? 'P' + r.pos : '') + '</span>' +
        '<span class="cbar" style="background:' + r.d.color + '"></span><span class="num">#' + esc(r.d.num) + '</span>' +
        '<span class="nm">' + esc(r.d.name) + '</span><span class="ir">' + this.lic(r.d) + '</span><span class="gap">' + gap + '</span></div>';
    };
    const pad = (a, n, front) => { const x = a.slice(); while (x.length < n) front ? x.unshift(null) : x.push(null); return x; };
    box.innerHTML = pad(rel.ahead, per, true).map(row).join('') + row(rel.me) + pad(rel.behind, per, false).map(row).join('');
    $('relSub').textContent = focusIdx() !== L.v.PlayerCarIdx ? 'watching #' + ((S.drivers.get(focusIdx()) || {}).num || '') : '';
  },

  timing() {
    const v = L.v;
    $('tCur').textContent = v.LapCurrentLapTime > 0 ? fmtLap(v.LapCurrentLapTime) : '–';
    $('tLast').textContent = fmtLap(v.LapLastLapTime);
    $('tBest').textContent = fmtLap(v.LapBestLapTime);
    const n = S.sectors.length, best = L.sec.best;
    let opt = 0;
    for (let k = 0; k < n; k++) opt = isNum(best[k]) ? opt + best[k] : NaN;
    $('tOpt').textContent = fmtLap(opt);
    // fastest lap in my class this session
    const myCls = (S.drivers.get(v.PlayerCarIdx) || {}).classId;
    let sb = NaN;
    for (const d of racers()) {
      if (d.classId !== myCls) continue;
      const b = arr('CarIdxBestLapTime', d.idx);
      if (b > 0 && (!isNum(sb) || b < sb)) sb = b;
    }
    $('tSess').textContent = fmtLap(sb);
    $('tBest').className = v.LapBestLapTime > 0 && isNum(sb) && v.LapBestLapTime <= sb + 1e-3 ? 'pb' : '';
    // sectors
    const sec = L.sec, box = $('sectors');
    box.style.gridTemplateColumns = 'repeat(' + n + ', 1fr)';
    let h = '';
    for (let k = 0; k < n; k++) {
      const c = sec.cur[k], old = sec.last[k], b = best[k];
      let cls = 'sec', main = '–', sub = isNum(b) ? 'best ' + b.toFixed(3) : '';
      if (c) { main = c.t.toFixed(3); cls += c.pb ? ' pb' : ' slow'; if (isNum(b) && !c.pb) sub = fmtDelta(c.t - b, 3) + ' to best'; }
      else if (k === sec.idx && sec.valid) { main = Math.max(0, v.SessionTime - sec.start).toFixed(1); cls += ' live'; }
      else if (old) { main = old.t.toFixed(3); cls += ' old'; }
      h += '<div class="' + cls + '"><label>Sector ' + (k + 1) + '</label><b>' + main + '</b><small>' + sub + '</small></div>';
    }
    box.innerHTML = h;
    // recent laps
    const bestLap = L.laps.reduce((m, l) => (l.time > 0 && l.clean && (!isNum(m) || l.time < m) ? l.time : m), NaN);
    const room = Math.max(1, Math.floor(($('lapList').clientHeight - 20) / 25));
    let lh = '<div class="lrow hd"><span>Lap</span><span>Time</span><span>Δ best</span><span>Fuel</span></div>';
    for (const l of L.laps.slice(-room).reverse()) {
      const isBest = l.time > 0 && l.time === bestLap;
      lh += '<div class="lrow"><span>' + l.lap + '</span><span class="' + (isBest ? 'best' : l.clean ? '' : 'dirty') + '">' + fmtLap(l.time) + '</span>' +
        '<span>' + (l.time > 0 && isNum(bestLap) ? (isBest ? '–' : fmtDelta(l.time - bestLap, 2)) : '') + '</span>' +
        '<span>' + (l.fuel > 0 ? Units.fuel(l.fuel, 2) : (l.clean ? '–' : 'pit')) + '</span></div>';
    }
    if (!L.laps.length) lh += '<div class="lrow"><span></span><span class="dirty">Laps appear here as you complete them</span><span></span><span></span></div>';
    $('lapList').innerHTML = lh;
  },

  fuel() {
    const f = fuelModel();
    $('fuelLvl').textContent = Units.fuel(f.level) + (S.fuelMax > 0 ? '  ·  ' + Math.round(100 * f.level / S.fuelMax) + '%' : '');
    const pct = S.fuelMax > 0 ? f.level / S.fuelMax : f.pct;
    const fill = $('fuelFill');
    fill.style.width = (clamp(pct || 0, 0, 1) * 100) + '%';
    fill.className = f.lapsOfFuel < 2 ? 'low' : '';
    $('fPer').textContent = f.per > 0 ? Units.fuel(f.per, 2) + (f.estimated ? '*' : '') : '–';
    $('fPer').title = f.estimated ? 'estimate from the current lap' : 'average of the last ' + f.laps + ' clean laps';
    $('fLaps').textContent = isNum(f.lapsOfFuel) ? f.lapsOfFuel.toFixed(1) : '–';
    $('fLeft').textContent = isNum(f.left) ? f.left.toFixed(1) : '–';
    const add = $('fAdd');
    if (isNum(f.add)) {
      add.textContent = f.add <= 0.05 ? 'Enough' : Units.fuel(f.add) + (f.stops > 1 ? ' (' + f.stops + ' stops)' : '');
      add.className = f.add <= 0.05 ? 'ok' : 'short';
    } else { add.textContent = '–'; add.className = ''; }
    const lapsShort = isNum(f.lapsOfFuel) && isNum(f.left) && f.lapsOfFuel < f.left;
    $('fLaps').className = isNum(f.lapsOfFuel) ? (lapsShort ? 'short' : 'ok') : '';
  },

  car() {
    const v = L.v;
    // tyres: iRacing only updates these when the car is in the pits
    const t = $('tires');
    let h = '';
    for (const c of ['LF', 'RF', 'LR', 'RR']) {
      const temps = [v[c + 'tempCL'], v[c + 'tempCM'], v[c + 'tempCR']];
      if (c[1] === 'F' && c[0] === 'R' || c === 'RR') temps.reverse();   // keep the outside edge on the outside
      const wear = Math.min(v[c + 'wearL'], v[c + 'wearM'], v[c + 'wearR']);
      h += '<div class="tire"><div class="tt">' + temps.map(x => '<i style="background:' + this.tempColor(x) + '">' + (isNum(x) ? Units.temp(x).replace('°', '') : '–') + '</i>').join('') + '</div>' +
        '<div class="tw"><span>' + c + '</span><span>' + (isNum(wear) ? Math.round(wear * 100) + '%' : '') + '</span><span>' + Units.press(v[c + 'coldPressure']) + '</span></div></div>';
    }
    t.innerHTML = h;
    t.title = 'Tyre temps, wear and cold pressure as of your last pit visit (iRacing does not stream them live)';
    const w = v.EngineWarnings >>> 0;
    const row = (k, val, warn) => '<div><label>' + k + '</label><span class="' + (warn ? 'warn' : '') + '">' + val + '</span></div>';
    $('carKv').innerHTML =
      row('Brake bias', isNum(v.dcBrakeBias) && v.dcBrakeBias > 0 ? v.dcBrakeBias.toFixed(1) + '%' : '–') +
      row('ABS', isNum(v.dcABS) ? v.dcABS : '–') +
      row('TC', isNum(v.dcTractionControl) ? v.dcTractionControl + (isNum(v.dcTractionControl2) ? ' / ' + v.dcTractionControl2 : '') : '–') +
      row('Water', Units.temp(v.WaterTemp), w & 0x01) +
      row('Oil', Units.temp(v.OilTemp), w & 0x40) +
      row('Oil press', isNum(v.OilPress) ? v.OilPress.toFixed(1) + ' bar' : '–', w & 0x04) +
      row('Voltage', isNum(v.Voltage) ? v.Voltage.toFixed(1) + ' V' : '–') +
      row('Wind', isNum(v.WindVel) ? (Units.metric ? (v.WindVel * 3.6).toFixed(0) + ' km/h' : (v.WindVel * 2.237).toFixed(0) + ' mph') : '–');
    $('limiter').classList.toggle('on', (w & 0x10) !== 0);
    const warns = [];
    if (w & 0x08) warns.push('engine stalled');
    if (w & 0x02) warns.push('fuel pressure');
    $('engWarn').textContent = warns.join(' · ');
    $('engWarn').style.color = warns.length ? 'var(--red)' : '';
  },

  tempColor(c) {
    if (!isNum(c) || c <= 0) return '#26303c';
    if (c < 60) return '#4aa8ff';
    if (c < 75) return '#7fd3ff';
    if (c < 95) return '#22d07a';
    if (c < 105) return '#ffd23f';
    return '#ff4d4d';
  },

  /* ---------- every frame ---------- */
  fast() {
    TrackMap.draw($('map'));
    $('mapStatus').textContent = TrackMap.label();
    if (!this.live()) return;
    const v = L.v;
    $('gear').textContent = v.Gear === -1 ? 'R' : v.Gear === 0 ? 'N' : (isNum(v.Gear) ? v.Gear : '–');
    $('speed').textContent = isNum(v.Speed) ? Math.round(Units.speed(v.Speed)) : '–';
    $('speedUnit').textContent = Units.speedUnit();
    $('rpm').textContent = isNum(v.RPM) ? Math.round(v.RPM) : '–';
    this.rpmLights(v.RPM);
    $('barThr').style.height = (clamp(v.Throttle || 0, 0, 1) * 100) + '%';
    $('barBrk').style.height = (clamp(v.Brake || 0, 0, 1) * 100) + '%';
    $('barClu').style.height = (isNum(v.Clutch) ? clamp(1 - v.Clutch, 0, 1) * 100 : 0) + '%';
    const deg = (v.SteeringWheelAngle || 0) * 180 / Math.PI;
    $('wheel').style.transform = 'rotate(' + (-deg) + 'deg)';
    $('steerDeg').textContent = Math.round(-deg) + '°';
    this.delta(v);
    this.trace();
  },

  rpmLights(rpm) {
    const sl = S.sl, bar = $('rpmbar'), cells = bar.children, n = cells.length;
    const lo = sl.first > 0 ? sl.first * 0.9 : (sl.red > 0 ? sl.red * 0.6 : 5000);
    const hi = sl.last > 0 ? sl.last : (sl.shift > 0 ? sl.shift : (sl.red > 0 ? sl.red * 0.97 : 8000));
    const lit = isNum(rpm) ? Math.round(clamp((rpm - lo) / (hi - lo), 0, 1) * n) : 0;
    for (let i = 0; i < n; i++) cells[i].className = i < lit ? (i < n * 0.55 ? 'g' : i < n * 0.85 ? 'y' : 'r') : '';
    const blink = sl.blink > 0 ? sl.blink : hi * 1.02;
    bar.classList.toggle('flash', rpm >= blink && Math.floor(performance.now() / 90) % 2 === 0);
  },

  delta(v) {
    const ok = v.LapDeltaToBestLap_OK && isNum(v.LapDeltaToBestLap);
    const d = ok ? v.LapDeltaToBestLap : NaN, el = $('tDelta');
    el.textContent = ok ? fmtDelta(d, 2) : '–';
    el.className = ok ? (d < 0 ? 'neg' : 'pos') : '';
    const bar = $('deltaBar'), x = ok ? clamp(d / 2, -1, 1) : 0;
    bar.style.left = (x < 0 ? 50 + x * 50 : 50) + '%';
    bar.style.width = Math.abs(x) * 50 + '%';
    bar.style.background = x < 0 ? 'var(--green)' : 'var(--red)';
  },

  trace() {
    const cv = $('trace'), dpr = window.devicePixelRatio || 1, w = cv.clientWidth, h = cv.clientHeight;
    if (!w || !h) return;
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
    const g = cv.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    g.strokeStyle = '#151c25'; g.lineWidth = 1;
    for (let k = 1; k < 4; k++) { g.beginPath(); g.moveTo(0, h * k / 4 + 0.5); g.lineTo(w, h * k / 4 + 0.5); g.stroke(); }
    const tr = L.trace, n = L.traceMax;
    if (tr.length < 2) return;
    const x = i => w - (tr.length - 1 - i) * (w / (n - 1));
    const pad = 3, y = val => pad + (1 - val) * (h - 2 * pad);
    const line = (key, color, width, fill) => {
      g.beginPath();
      tr.forEach((s, i) => (i ? g.lineTo(x(i), y(s[key])) : g.moveTo(x(i), y(s[key]))));
      if (fill) { g.lineTo(x(tr.length - 1), h); g.lineTo(x(0), h); g.closePath(); g.fillStyle = fill; g.fill(); }
      else { g.strokeStyle = color; g.lineWidth = width; g.stroke(); }
    };
    // steering as a faint centred line
    g.beginPath();
    tr.forEach((s, i) => { const yy = h / 2 - s.st * (h / 2 - pad); i ? g.lineTo(x(i), yy) : g.moveTo(x(i), yy); });
    g.strokeStyle = 'rgba(200,210,220,.28)'; g.lineWidth = 1.5; g.stroke();
    line('thr', null, 0, 'rgba(34,208,122,.12)');
    line('brk', null, 0, 'rgba(255,77,77,.14)');
    line('clu', '#49a6ff', 1.5);
    line('thr', '#22d07a', 2.5);
    line('brk', '#ff4d4d', 2.5);
  },
};

UI.init();
Conn.start();
