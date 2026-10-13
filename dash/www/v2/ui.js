'use strict';
// Rendering. Text panels refresh 10x a second (and only touch the DOM when a value changed);
// the map, input trace, gauges and car-alongside bars every animation frame.

const WETNESS = ['–', 'Dry', 'Mostly dry', 'Damp', 'Light wet', 'Wet', 'Very wet', 'Flooded'];
const COMPASS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];

const UI = {
  standMode: (() => { try { return localStorage.getItem('irdash-stand') || 'all'; } catch (e) { return 'all'; } })(),
  size: {},          // element sizes from ResizeObserver, so nothing reads layout inside the loops
  clr: -1,
  lastDom: 0, lastCanvas: 0, lastMap: '', lastTrace: '',

  init() {
    const bar = $('rpmbar');
    for (let i = 0; i < 16; i++) bar.appendChild(document.createElement('i'));
    $('standMode').onclick = () => {
      this.standMode = this.standMode === 'all' ? 'class' : 'all';
      try { localStorage.setItem('irdash-stand', this.standMode); } catch (e) { }
      this.slow();
    };
    const watch = ['mapBox', 'traceBox', 'standings', 'relative', 'lapList'];
    const read = el => { this.size[el.id] = { w: el.clientWidth, h: el.clientHeight }; };
    watch.forEach(id => read($(id)));
    if (window.ResizeObserver) {
      const ro = new ResizeObserver(entries => { for (const e of entries) read(e.target); });
      watch.forEach(id => ro.observe($(id)));
    } else window.addEventListener('resize', () => watch.forEach(id => read($(id))));
    this.health(); this.healthAt = performance.now();
    document.addEventListener('visibilitychange', () => { this.lastDom = 0; this.lastCanvas = 0; this.lastMap = ''; this.lastTrace = ''; });
    const loop = now => {
      try {
        if (!document.hidden) {
          if (now - this.lastDom >= 100) {
            this.lastDom = now; this.slow(); this.fast();
            if (typeof Guest !== 'undefined') { try { Guest.frame(); } catch (e) { console.error(e); } }
            if (typeof Tv !== 'undefined' && Tv.on) Tower.tick();
          }
          if (now - this.lastCanvas >= 33) { this.lastCanvas = now; this.canvases(now); }
          if (typeof Tv !== 'undefined' && now - Tv.pollAt >= 700) { Tv.pollAt = now; Tv.poll(); }
          if (now - this.healthAt >= 3000) { this.healthAt = now; this.health(); }
        }
      } catch (e) { console.error(e); }
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  },

  live() { return L.connected && performance.now() - L.lastFrameAt < 3000; },
  sz(id) { return this.size[id] || { w: 0, h: 0 }; },

  /* ---------- rig health strip and watchdog notices ---------- */
  async health() {
    let h;
    try { h = await (await fetch('/health', { cache: 'no-store' })).json(); } catch (e) { return; }
    const cls = s => (s === 'ok' || s === 'live') ? 'ok' : (s === 'loading' || s === 'starting') ? 'warn' : (s === 'stuck' || s === 'down') ? 'bad' : '';
    const word = { ok: 'running', live: 'in session', loading: 'loading', starting: 'starting', stuck: 'stuck', down: 'not running', off: 'off' };
    setHTML('health', (h.apps || []).map(a =>
      '<span class="hd ' + cls(a.state) + '" title="' + esc(a.name + ': ' + (word[a.state] || a.state)) + '"><i></i>' + esc(a.name) + '</span>').join(''));
    // Stream Deck reconnects are fixed silently (still in irdash.log); only other repairs get a notice
    const ev = (h.events || []).filter(e => !/stream deck/i.test(e.msg)), last = ev[ev.length - 1];
    const t = $('toast');
    if (!L.demo && last && Date.now() - new Date(last.t).getTime() < 10 * 60 * 1000) {
      setHTML(t, '<b>Rig fixed</b>' + esc(last.msg));
      t.hidden = false;
    } else t.hidden = true;
  },

  /* ---------- 10 Hz ---------- */
  slow() {
    try {
      const live = this.live();
      this.overlay(live);
      setText('clock', new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }));
      if (!live) { this.stripOffline(); return; }
      const f = fuelModel();
      this.strip(f);
      this.standings();
      this.relative();
      this.timing();
      this.fuel(f);
      this.car();
      this.wind();
    } catch (e) { console.error(e); }
  },

  overlay(live) {
    const ov = $('overlay');
    setCls(ov, live ? '' : 'show');
    if (!live) {
      const st = Conn.status;
      setText('ovTitle', st === 'noserver' ? 'Paddock program not running' : 'Waiting for iRacing');
      setText('ovText', '');
    }
    const c = $('conn');
    setCls(c, 'conn' + (L.demo ? ' demo' : live ? ' ok' : ''));
    c.title = L.demo ? 'demo data' : live ? 'live from iRacing' : Conn.status;
  },

  stripOffline() {
    this.setFlag('', 'Offline');
    for (const id of ['sessRemain', 'hPos', 'hLap', 'hInc', 'hFuel', 'hWet']) setText(id, '–');
    for (const id of ['hPosOf', 'hLapOf', 'hIncLim']) setText(id, '');
    for (const id of ['hCls', 'sessSub', 'hLapSub', 'hIncSub', 'hWx']) setText(id, ' ');
    setHTML('hFuelSub', '&nbsp;');
    setCls('incBox', 'cell'); setCls('fuelBox', 'cell'); setCls('wxBox', 'cell');
    this.setClr(0);
  },

  /* ---------- race state strip ---------- */
  strip(f) {
    const v = L.v;
    setText('trackName', S.track.name || '–');
    setText('trackSub', [S.track.config, isNum(S.track.lengthKm) ? S.track.lengthKm.toFixed(2) + ' km' : ''].filter(Boolean).join('  ·  '));
    const sess = currentSession(), race = isRace();
    setText('sessType', sessionType());
    const lapsTotal = sess ? num(sess.SessionLaps) : NaN;
    const timeOk = isNum(v.SessionTimeRemain) && v.SessionTimeRemain >= 0 && v.SessionTimeRemain < 7 * 86400;
    if (isNum(lapsTotal) && lapsTotal > 0) {
      const left = isNum(v.SessionLapsRemainEx) && v.SessionLapsRemainEx < 30000 ? v.SessionLapsRemainEx : lapsTotal - (v.LapCompleted || 0);
      setText('sessRemain', isNum(left) ? Math.max(0, left) : '–');
      setText('sessSub', timeOk ? 'laps to go  ·  ' + fmtDur(v.SessionTimeRemain) : 'laps to go');
    } else {
      setText('sessRemain', timeOk ? fmtDur(v.SessionTimeRemain) : '–');
      setText('sessSub', timeOk ? 'time remaining' : ' ');
    }
    setCls('sessRemain', $('sessRemain').textContent.length > 5 ? 'long' : '');
    // position
    const total = racers().length;
    setText('hPos', v.PlayerCarPosition > 0 ? 'P' + v.PlayerCarPosition : '–');
    setText('hPosOf', v.PlayerCarPosition > 0 && total ? '/' + total : '');
    const myCls = S.drivers.get(v.PlayerCarIdx) || {};
    setText('hCls', S.multiClass && v.PlayerCarClassPosition > 0
      ? (myCls.cls || 'Class') + '  P' + v.PlayerCarClassPosition + ' / ' + (S.classCount.get(myCls.classId) || '–') : (race ? 'overall' : ' '));
    // lap
    setText('hLap', isNum(v.Lap) && v.Lap > 0 ? v.Lap : '–');
    setText('hLapOf', isNum(lapsTotal) && lapsTotal > 0 ? '/' + lapsTotal : '');
    setCls($('hLap').parentNode, String(v.Lap).length + (lapsTotal > 0 ? String(lapsTotal).length : 0) > 4 ? 'long' : '');
    setCls($('hPos').parentNode, v.PlayerCarPosition >= 10 && total >= 100 ? 'long' : '');
    setText('hLapSub', race && isNum(f.left) && !(lapsTotal > 0) ? '≈ ' + f.left.toFixed(1) + ' to go' : ' ');
    // incidents: grows louder as the limit gets close
    const inc = v.PlayerCarMyIncidentCount, lim = num(S.incLimit);
    setText('hInc', isNum(inc) ? inc + 'x' : '–');
    setText('hIncLim', isNum(inc) && lim > 0 ? '/' + lim : '');
    let ic = 'cell';
    if (isNum(inc) && lim > 0) {
      const left = lim - inc, r = inc / lim;
      setText('hIncSub', left > 0 ? left + (left === 1 ? ' left to limit' : ' left to limit') : 'limit reached');
      if (r >= 0.8 || left <= 2) ic += ' bad pulse'; else if (r >= 0.6) ic += ' warn';
    } else setText('hIncSub', isNum(inc) ? 'no limit' : ' ');
    setCls('incBox', ic);
    // fuel
    setText('hFuel', isNum(f.lapsOfFuel) ? f.lapsOfFuel.toFixed(1) : '–');
    let fc = 'cell', fs = ' ';
    if (isNum(f.add)) {
      if (f.add <= 0.05) fs = '<span class="ok">Enough to finish</span>';
      else { fs = '<span class="warn">+' + esc(Units.fuel(f.add)) + ' to finish' + (f.stops > 1 ? ' · ' + f.stops + ' stops' : '') + '</span>'; fc += ' warn'; }
    } else if (!(f.per > 0)) fs = 'measuring…';
    else fs = esc(Units.fuel(f.per, 2)) + ' per lap';
    if (isNum(f.lapsOfFuel) && f.lapsOfFuel < 2 && !(f.add <= 0.05)) fc = 'cell bad';
    setHTML('hFuelSub', fs);
    setCls('fuelBox', fc);
    // weather
    const wet = v.TrackWetness;
    setText('hWet', isNum(wet) && wet >= 1 && wet <= 7 ? WETNESS[wet] : '–');
    setCls('wxBox', 'cell' + (wet >= 3 ? ' warn' : ''));
    const wx = [];
    if (isNum(v.Precipitation)) wx.push('Rain ' + Math.round(clamp(v.Precipitation, 0, 1) * 100) + '%');
    if (isNum(v.AirTemp) || isNum(v.TrackTempCrew)) wx.push('Air ' + Units.temp(v.AirTemp) + ' · Trk ' + Units.temp(v.TrackTempCrew));
    setText('hWx', wx.join('  ·  ') || ' ');
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
    setCls('flag', 'flag ' + cls + (blink ? ' blink' : ''));
    setText('flagTxt', text);
  },

  lic(d) {
    if (!d.lic) return '';
    return '<span class="lic" style="background:' + d.licColor + '">' + esc(d.lic.split(' ')[0]) + '</span>' +
      (d.ir > 0 ? (d.ir / 1000).toFixed(1) + 'k' : '');
  },

  /* ---------- standings ---------- */
  standings() {
    const onlyClass = this.standMode === 'class' && S.multiClass;
    $('standMode').style.display = S.multiClass ? '' : 'none';
    setText('standMode', onlyClass ? 'My class' : 'All classes');
    const rows = computeStandings(onlyClass);
    setText('standSub', rows.length + ' cars');
    const max = Math.max(5, Math.floor((this.sz('standings').h - 20) / 32));
    let shown = rows;
    if (rows.length > max) {
      const k = Math.max(0, rows.findIndex(r => r.me));
      const top = 3;
      if (k < max - 2) shown = rows.slice(0, max);
      else {
        const rest = max - top - 1, start = Math.min(rows.length - rest, Math.max(top, k - Math.floor(rest / 2)));
        shown = rows.slice(0, top).concat([null], rows.slice(start, start + rest));
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
        '<span class="gap">' + esc(r.gap == null ? '–' : r.gap) + '</span></div>';
    }
    setHTML('standings', h);
  },

  /* ---------- relative ---------- */
  relative() {
    const hgt = this.sz('relative').h;
    const per = Math.max(2, Math.floor(((hgt - 6) / 50 - 1) / 2));
    const rel = computeRelative(per, per);
    if (!rel) { setHTML('relative', '<div class="rrow empty"><span></span><span></span><span></span><span class="nm" style="color:var(--muted)">No car on track</span></div>'); return; }
    const row = r => {
      if (!r) return '<div class="rrow empty"></div>';
      const cls = 'rrow' + (r.me ? ' me' : '') + (r.pit ? ' pit' : '') + (r.lapDiff > 0 ? ' ahead-lap' : r.lapDiff < 0 ? ' behind-lap' : '') +
        (!r.me && Math.abs(r.gap) < 1 ? ' close' : '');
      const a = Math.abs(r.gap);
      const gap = r.me || !isNum(r.gap) ? '' : (r.gap >= 0 ? '+' : '−') + (a >= 100 ? a.toFixed(0) : a.toFixed(1));
      return '<div class="' + cls + '"><span class="pos">' + (r.pos > 0 ? 'P' + r.pos : '') + '</span>' +
        '<span class="cbar" style="background:' + r.d.color + '"></span><span class="num">#' + esc(r.d.num) + '</span>' +
        '<span class="nm">' + esc(r.d.name) + '</span><span class="ir">' + this.lic(r.d) + '</span><span class="gap">' + gap + '</span></div>';
    };
    const pad = (a, n, front) => { const x = a.slice(); while (x.length < n) front ? x.unshift(null) : x.push(null); return x; };
    setHTML('relative', pad(rel.ahead, per, true).map(row).join('') + row(rel.me) + pad(rel.behind, per, false).map(row).join(''));
    setText('relSub', focusIdx() !== L.v.PlayerCarIdx ? 'watching #' + ((S.drivers.get(focusIdx()) || {}).num || '') : '');
  },

  // CarLeftRight: 0 off, 1 clear, 2 car left, 3 car right, 4 left and right, 5 two left, 6 two right
  setClr(c) {
    if (c === this.clr) return;
    this.clr = c;
    const l = c === 2 || c === 4 || c === 5, r = c === 3 || c === 4 || c === 6;
    setCls('clrL', 'clr l' + (l ? ' on' : '') + (c === 5 ? ' two' : ''));
    setCls('clrR', 'clr r' + (r ? ' on' : '') + (c === 6 ? ' two' : ''));
  },

  /* ---------- timing ---------- */
  timing() {
    const v = L.v;
    setText('tCur', v.LapCurrentLapTime > 0 ? fmtLap(v.LapCurrentLapTime) : '–');
    setText('tLast', fmtLap(v.LapLastLapTime));
    setText('tBest', fmtLap(v.LapBestLapTime));
    const n = S.sectors.length, best = L.sec.best;
    let opt = 0;
    for (let k = 0; k < n; k++) opt = isNum(best[k]) ? opt + best[k] : NaN;
    setText('tOpt', fmtLap(opt));
    const myCls = (S.drivers.get(v.PlayerCarIdx) || {}).classId;
    let sb = NaN;
    for (const d of racers()) {
      if (d.classId !== myCls) continue;
      const b = arr('CarIdxBestLapTime', d.idx);
      if (b > 0 && (!isNum(sb) || b < sb)) sb = b;
    }
    setText('tSess', fmtLap(sb));
    setCls('tBest', v.LapBestLapTime > 0 && isNum(sb) && v.LapBestLapTime <= sb + 1e-3 ? 'pb' : '');
    const sec = L.sec, box = $('sectors');
    if (box._n !== n) { box._n = n; box.style.gridTemplateColumns = 'repeat(' + n + ', minmax(0, 1fr))'; }
    let h = '';
    for (let k = 0; k < n; k++) {
      const c = sec.cur[k], old = sec.last[k], b = best[k];
      let cls = 'sec', main = '–', sub = isNum(b) ? 'best ' + b.toFixed(3) : ' ';
      if (c) { main = c.t.toFixed(3); cls += c.pb ? ' pb' : ' slow'; if (isNum(b) && !c.pb) sub = fmtDelta(c.t - b, 3) + ' to best'; }
      else if (k === sec.idx && sec.valid) { main = Math.max(0, v.SessionTime - sec.start).toFixed(1); cls += ' live'; }
      else if (old) { main = old.t.toFixed(3); cls += ' old'; }
      h += '<div class="' + cls + '"><label>Sector ' + (k + 1) + '</label><b>' + main + '</b><small>' + sub + '</small></div>';
    }
    setHTML(box, h);
    const bestLap = L.laps.reduce((m, l) => (l.time > 0 && l.clean && (!isNum(m) || l.time < m) ? l.time : m), NaN);
    const room = Math.max(0, Math.floor((this.sz('lapList').h - 18) / 28));
    let lh = '<div class="lrow hd"><span>Lap</span><span>Time</span><span>Δ best</span><span>Fuel</span></div>';
    for (const l of L.laps.slice(-room).reverse()) {
      const isBest = l.time > 0 && l.time === bestLap;
      lh += '<div class="lrow"><span>' + l.lap + '</span><span class="' + (isBest ? 'best' : l.clean ? '' : 'dirty') + '">' + fmtLap(l.time) + '</span>' +
        '<span>' + (l.time > 0 && isNum(bestLap) ? (isBest ? '–' : fmtDelta(l.time - bestLap, 2)) : '–') + '</span>' +
        '<span>' + (l.fuel > 0 ? Units.fuel(l.fuel, 2) : (l.clean ? '–' : 'pit')) + '</span></div>';
    }

    setHTML('lapList', lh);
  },

  fuel(f) {
    setText('fuelLvl', Units.fuel(f.level) + (S.fuelMax > 0 && isNum(f.level) ? '  ·  ' + Math.round(100 * f.level / S.fuelMax) + '%' : ''));
    const pct = S.fuelMax > 0 ? f.level / S.fuelMax : f.pct;
    const fill = $('fuelFill'), w = (clamp(isNum(pct) ? pct : 0, 0, 1) * 100).toFixed(1) + '%';
    if (fill._w !== w) { fill._w = w; fill.style.width = w; }
    setCls(fill, f.lapsOfFuel < 2 ? 'low' : '');
    setText('fPer', f.per > 0 ? Units.fuel(f.per, 2) + (f.estimated ? '*' : '') : '–');
    setText('fLeft', isNum(f.left) ? f.left.toFixed(1) : '–');
    if (isNum(f.add)) {
      setText('fAdd', f.add <= 0.05 ? 'Enough' : '+' + Units.fuel(f.add) + (f.stops > 1 ? ' (' + f.stops + ')' : ''));
      setCls('fAdd', f.add <= 0.05 ? 'ok' : 'short');
    } else { setText('fAdd', '–'); setCls('fAdd', ''); }
    // pit window replaces the label when a stop is needed: "Pit L12–L18", or "Box now" once it is open
    let lbl = 'Add to finish';
    if (isNum(f.winOpen) && isNum(f.winClose)) {
      const lap = L.v.Lap;
      lbl = lap >= f.winOpen ? (lap >= f.winClose ? 'Box this lap' : 'Pit window open to L' + f.winClose) : 'Pit window L' + f.winOpen + '–L' + f.winClose;
    }
    setText('fAddLbl', lbl);
  },

  car() {
    const v = L.v;
    let h = '';
    for (const c of ['LF', 'RF', 'LR', 'RR']) {
      const temps = [v[c + 'tempCL'], v[c + 'tempCM'], v[c + 'tempCR']];
      if (c[0] === 'R') temps.reverse();   // keep the outside edge on the outside
      const wear = Math.min(v[c + 'wearL'], v[c + 'wearM'], v[c + 'wearR']);
      h += '<div class="tire"><div class="tt">' + temps.map(x => '<i style="background:' + this.tempColor(x) + '">' + (isNum(x) ? Units.temp(x).replace('°', '') : '–') + '</i>').join('') + '</div>' +
        '<div class="tw"><span>' + c + '</span><span>' + (isNum(wear) ? Math.round(wear * 100) + '%' : '–') + '</span><span>' + Units.press(v[c + 'coldPressure']) + '</span></div></div>';
    }
    setHTML('tires', h);
    $('tires').title = 'Values from the last pit stop';
    const w = v.EngineWarnings >>> 0;
    const row = (k, val, warn) => '<div><label>' + k + '</label><span class="' + (warn ? 'warn' : '') + '">' + val + '</span></div>';
    setHTML('carKv',
      row('Brake bias', isNum(v.dcBrakeBias) && v.dcBrakeBias > 0 ? v.dcBrakeBias.toFixed(1) + '%' : '–') +
      row('ABS', isNum(v.dcABS) ? v.dcABS : '–') +
      row('TC', isNum(v.dcTractionControl) ? v.dcTractionControl + (isNum(v.dcTractionControl2) ? ' / ' + v.dcTractionControl2 : '') : '–') +
      row('Water', Units.temp(v.WaterTemp), w & 0x01) +
      row('Oil', Units.temp(v.OilTemp), w & 0x40) +
      row('Oil press', isNum(v.OilPress) ? v.OilPress.toFixed(1) + ' bar' : '–', w & 0x04) +
      row('Voltage', isNum(v.Voltage) ? v.Voltage.toFixed(1) + ' V' : '–') +
      row('Humidity', isNum(v.RelativeHumidity) ? Math.round(v.RelativeHumidity * 100) + '%' : '–'));
    $('limiter').classList.toggle('on', (w & 0x10) !== 0);
    const warns = [];
    if (w & 0x08) warns.push('engine stalled');
    if (w & 0x02) warns.push('fuel pressure');
    setText('engWarn', warns.join(' · '));
    $('engWarn').style.color = warns.length ? 'var(--red)' : '';
  },

  // wind arrow on the map points the way the wind blows, relative to the map's north
  wind() {
    const v = L.v;
    if (!isNum(v.WindVel) || !isNum(v.WindDir)) { setText('windTxt', '–'); return; }
    const spd = Units.metric ? Math.round(v.WindVel * 3.6) + ' km/h' : Math.round(v.WindVel * 2.237) + ' mph';
    const fromDeg = ((v.WindDir * 180 / Math.PI) % 360 + 360) % 360;
    setText('windTxt', spd + ' from ' + COMPASS[Math.round(fromDeg / 45) % 8]);
    const rot = Math.round(TrackMap.northDeg() + fromDeg + 180);
    const a = $('windArrow');
    if (a._r !== rot) { a._r = rot; a.setAttribute('transform', 'rotate(' + rot + ')'); }
  },

  tempColor(c) {
    if (!isNum(c) || c <= 0) return '#26303c';
    if (c < 60) return '#4d8eff';
    if (c < 75) return '#86c8ff';
    if (c < 95) return '#2fe07a';
    if (c < 105) return '#ffb21e';
    return '#ff3d3d';
  },

  /* ---------- every frame ---------- */
  fast() {
    if (!this.live()) return;
    const v = L.v;
    this.setClr(isNum(v.CarLeftRight) ? v.CarLeftRight : 0);
    setText('gear', v.Gear === -1 ? 'R' : v.Gear === 0 ? 'N' : (isNum(v.Gear) ? v.Gear : '–'));
    setText('speed', isNum(v.Speed) ? Math.round(Units.speed(v.Speed)) : '–');
    setText('speedUnit', Units.speedUnit());
    setText('rpm', isNum(v.RPM) ? Math.round(v.RPM) : '–');
    this.rpmLights(v.RPM);
    const ped = (id, x) => { const el = $(id), s = 'scaleY(' + clamp(isNum(x) ? x : 0, 0, 1).toFixed(3) + ')'; if (el._s !== s) { el._s = s; el.style.transform = s; } };
    ped('barThr', v.Throttle); ped('barBrk', v.Brake); ped('barClu', isNum(v.Clutch) ? 1 - v.Clutch : 0);
    const deg = isNum(v.SteeringWheelAngle) ? v.SteeringWheelAngle * 180 / Math.PI : 0;
    const wr = 'rotate(' + (-deg).toFixed(1) + 'deg)', wh = $('wheel');
    if (wh._s !== wr) { wh._s = wr; wh.style.transform = wr; }
    setText('steerDeg', Math.round(-deg) + '°');
    this.delta(v);
  },

  // Canvas work is deliberately capped and skipped unless its visible inputs changed.
  canvases(now) {
    if (!this.live()) return;
    if (typeof Tv !== 'undefined' && Tv.on) {
      const dt = this.lastTv ? Math.min(0.1, (now - this.lastTv) / 1000) : 0;
      this.lastTv = now;
      Tv.renderFrame(dt);
      return;
    }
    if (!document.body.classList.contains('tv-on')) {
      const v = L.v, m = this.sz('mapBox');
      const gps = TrackMap.gps;
      const sig = [m.w, m.h, S.version, TrackInfo.version, TrackMap.key, TrackMap.source, TrackMap.recorded, TrackMap.status,
        TrackMap.pts ? TrackMap.pts.length : 0, TrackMap.pit ? TrackMap.pit.length : 0, gps ? gps.file + ':' + gps.n + ':' + gps.meanErrorM : '',
        v.PlayerCarIdx, (v.CarIdxLapDistPct || []).map(x => isNum(x) ? Math.round(x * 1000) : -1).join(',')].join('|');
      if (sig !== this.lastMap) {
        this.lastMap = sig;
        TrackMap.draw($('map'), m.w, m.h);
        setText('mapStatus', TrackMap.name ? TrackMap.name + (TrackMap.label() ? '  ·  ' + TrackMap.label() : '') : TrackMap.label());
      }
    }
    const tr = L.trace, tail = tr.length ? tr[tr.length - 1] : null;
    const sig = tr.length + ':' + (tail ? [tail.thr, tail.brk, tail.clu, tail.st].join(',') : '');
    if (sig !== this.lastTrace) { this.lastTrace = sig; this.trace(); }
  },

  rpmLights(rpm) {
    const sl = S.sl, bar = $('rpmbar'), cells = bar.children, n = cells.length;
    const lo = sl.first > 0 ? sl.first * 0.9 : (sl.red > 0 ? sl.red * 0.6 : 5000);
    const hi = sl.last > 0 ? sl.last : (sl.shift > 0 ? sl.shift : (sl.red > 0 ? sl.red * 0.97 : 8000));
    const lit = isNum(rpm) ? Math.round(clamp((rpm - lo) / (hi - lo), 0, 1) * n) : 0;
    if (bar._lit !== lit) {
      bar._lit = lit;
      for (let i = 0; i < n; i++) cells[i].className = i < lit ? (i < n * 0.55 ? 'g' : i < n * 0.85 ? 'y' : 'r') : '';
    }
    const blink = sl.blink > 0 ? sl.blink : hi * 1.02;
    const reduce = this.reduceMotion;
    const fl = rpm >= blink && (reduce || Math.floor(performance.now() / 90) % 2 === 0);
    if (bar._fl !== fl) { bar._fl = fl; bar.classList.toggle('flash', fl); }
  },
  reduceMotion: !!(window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches),

  delta(v) {
    const ok = v.LapDeltaToBestLap_OK && isNum(v.LapDeltaToBestLap);
    const d = ok ? v.LapDeltaToBestLap : NaN;
    setText('tDelta', ok ? fmtDelta(d, 2) : '–');
    setCls('tDelta', ok ? (d < 0 ? 'neg' : 'pos') : '');
    const bar = $('deltaBar'), x = ok ? clamp(d / 2, -1, 1) : 0;
    const s = 'scaleX(' + x.toFixed(3) + ')', c = x < 0 ? 'var(--green)' : 'var(--red)';
    if (bar._s !== s) { bar._s = s; bar.style.transform = s; }
    if (bar._c !== c) { bar._c = c; bar.style.background = c; }
  },

  trace() {
    const cv = $('trace'), dpr = window.devicePixelRatio || 1, sz = this.sz('traceBox'), w = sz.w, h = sz.h;
    if (!w || !h) return;
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
    const g = cv.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    g.strokeStyle = '#12171e'; g.lineWidth = 1;
    for (let k = 1; k < 4; k++) { g.beginPath(); g.moveTo(0, Math.round(h * k / 4) + 0.5); g.lineTo(w, Math.round(h * k / 4) + 0.5); g.stroke(); }
    const tr = L.trace, n = L.traceMax;
    if (tr.length < 2) return;
    const x = i => w - (tr.length - 1 - i) * (w / (n - 1));
    const pad = 3, y = val => pad + (1 - val) * (h - 2 * pad);
    const line = (key, color, width, fill) => {
      g.beginPath();
      for (let i = 0; i < tr.length; i++) (i ? g.lineTo(x(i), y(tr[i][key])) : g.moveTo(x(i), y(tr[i][key])));
      if (fill) { g.lineTo(x(tr.length - 1), h); g.lineTo(x(0), h); g.closePath(); g.fillStyle = fill; g.fill(); }
      else { g.strokeStyle = color; g.lineWidth = width; g.stroke(); }
    };
    g.beginPath();
    for (let i = 0; i < tr.length; i++) { const yy = h / 2 - tr[i].st * (h / 2 - pad); i ? g.lineTo(x(i), yy) : g.moveTo(x(i), yy); }
    g.strokeStyle = 'rgba(200,210,220,.25)'; g.lineWidth = 1.5; g.stroke();
    line('thr', null, 0, 'rgba(47,224,122,.10)');
    line('brk', null, 0, 'rgba(255,61,61,.12)');
    line('clu', '#4d8eff', 1.5);
    line('thr', '#2fe07a', 2.5);
    line('brk', '#ff3d3d', 2.5);
  },
};

UI.init();
Conn.start();

// One calm line on the top screen while RESET CAR waits for the car to stop.
// The same bar sits over the normal dashboard and the Friends drive view. It is not drawn on the race screens.
const TowWait = {
  init() {
    const el = document.createElement('div');
    el.id = 'towWait';
    el.hidden = true;
    el.textContent = 'Reset car · waiting for the car to stop';
    document.body.appendChild(el);
    const tick = async () => {
      if (document.hidden) return;
      try {
        const r = await (await fetch('/api/tow-wait', { cache: 'no-store' })).json();
        el.hidden = !r.on;
      } catch (e) { /* dashboard restarting */ }
    };
    tick();
    setInterval(tick, 500);
  },
};
TowWait.init();
