'use strict';
// Drive v1: the in-car fourth screen, an "eye-line pit wall" (design: docs\design\drive-v1\spec.md and drive-v1.html).
// The screen hangs above the middle race screen, so the glance band (position, gap ahead, delta, laps left, fuel, REC)
// sits at the bottom; the complete map is upper left, a 7-row battle tower centred on Peter upper right.
// Everything is built from the frames already in this page: no network on the render path. The REC pill is tv.js
// Tower.recorder (irdash's one capture verdict). The old five-panel grid stays underneath for the garage and old tests.
const Drive = {
  shown: false, at: 0, mapSig: '', layer: null, layerKey: '', labels: [], gapHist: [], offLap: null, model: null,
  DASH: '—', DOT: ' · ',

  // in the car: a live frame with IsOnTrack. A frozen feed keeps the screen (greyed, with its age) for a minute.
  want() {
    if (QS.has('grid') || (L.demo && !QS.has('drive'))) return false;
    const v = L.v;
    if (!L.connected || !v || !v.IsOnTrack || v.IsReplayPlaying) return false;
    return performance.now() - L.lastFrameAt < 60000;
  },

  onFrame(v) {
    // off track anywhere in a lap: that lap gets no delta (iRacing keeps counting one)
    if (v.PlayerTrackSurface === 0) this.offLap = v.LapCompleted;
  },

  // 10 Hz from the dashboard loop; the work runs at 4 Hz
  tick(now) {
    const want = this.want();
    if (want !== this.shown) {
      this.shown = want; this.mapSig = '';
      document.body.classList.toggle('drive-on', want);
      const el = $('drive'); if (el) el.hidden = !want;
    }
    if (!want || now - this.at < 250) return;
    this.at = now;
    if (typeof Tower !== 'undefined') Tower.recorder();
    try {
      this.model = this.build();
      this.paint(this.model);
      if (!UI.live()) this.frame();          // the dashboard's canvas loop pauses on a frozen feed; grey the map here
    } catch (e) { console.error(e); }
  },

  /* ---------- formatting ---------- */
  lap(t) { if (!isNum(t) || t <= 0) return this.DASH; const m = Math.floor(t / 60), s = t - m * 60; return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3); },
  clock(s) { if (!isNum(s) || s < 0) return this.DASH; s = Math.floor(s); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60, p = n => (n < 10 ? '0' : '') + n; return h ? h + ':' + p(m) + ':' + p(x) : m + ':' + p(x); },
  signed(d, n) { return (d < 0 ? '−' : '+') + Math.abs(d).toFixed(n); },
  fuel(l) { return Units.metric ? l : l / 3.785412; },
  fuelUnit() { return Units.metric ? 'L' : 'gal'; },
  et() {
    try { return new Date().toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'America/New_York' }) + ' ET'; }
    catch (e) { return this.DASH; }
  },
  val(text, unit) { return esc(text) + (unit ? '<small>' + esc(unit) + '</small>' : ''); },

  // time between two cars of the field, from iRacing's F2 times; a lap or more apart says laps. Never from map distance.
  between(a, b) {
    const dd = Math.abs(a.dist - b.dist);
    if (dd >= 1 && isNum(a.dist) && isNum(b.dist)) { const n = Math.floor(dd); return { text: n + (n === 1 ? ' lap' : ' laps'), s: NaN }; }
    const ok = r => isNum(r.f2) && (r.f2 > 0 || r.pos === 1);
    if (!ok(a) || !ok(b)) return { text: this.DASH, s: NaN };
    const s = Math.abs(a.f2 - b.f2);
    return { text: s.toFixed(1), s };
  },

  // gap change per lap to the same car ahead: the oldest sample still a lap back, scaled to one lap
  trend(idx, gap, t, lapT) {
    const h = this.gapHist;
    if (!isNum(gap) || !isNum(t) || !(lapT > 0)) { h.length = 0; return NaN; }
    if (h.length && (h[h.length - 1].idx !== idx || t < h[h.length - 1].t)) h.length = 0;
    if (!h.length || t - h[h.length - 1].t >= 1) h.push({ t, idx, gap });
    while (h.length > 2 && t - h[1].t >= lapT) h.shift();
    const span = t - h[0].t;
    return span >= lapT * 0.85 ? (gap - h[0].gap) * lapT / span : NaN;
  },

  pitLimit() {
    const raw = String(((S.y || {}).WeekendInfo || {}).TrackPitSpeedLimit || ''), n = parseFloat(raw);
    if (!(n > 0)) return NaN;
    return /mph/i.test(raw) ? n * 0.44704 : n / 3.6;      // m/s
  },

  /* ---------- the view model: plain text per cell, built from the frames ---------- */
  build() {
    const v = L.v, D = this.DASH, DOT = this.DOT, race = isRace(), multi = S.multiClass;
    const age = performance.now() - L.lastFrameAt;
    const meIdx = isNum(v.PlayerCarIdx) ? v.PlayerCarIdx : S.me;
    const meD = S.drivers.get(meIdx) || {};
    const all = computeStandings(false);
    let field = multi ? all.filter(r => r.d.classId === meD.classId) : all.slice();
    if (race) field.sort((a, b) => ((multi ? a.cpos : a.pos) || 999) - ((multi ? b.cpos : b.pos) || 999) || a.d.idx - b.d.idx);
    else field.sort((a, b) => (a.best || 9e9) - (b.best || 9e9) || (a.pos || 999) - (b.pos || 999) || a.d.idx - b.d.idx);
    const k = field.findIndex(r => r.d.idx === meIdx), me = field[k] || null;
    const m = { stale: age >= 2000 ? Math.round(age / 1000) : 0, multi, race };

    m.sess = sessionType();
    m.track = (S.track.name || '') + (S.track.config ? DOT + S.track.config : '');
    m.clock = this.et();

    // position
    const nCars = racers().length;
    if (multi) {
      const cp = me && me.cpos > 0 ? me.cpos : 0;
      m.pos = { lbl: 'Class position', v: cp ? this.val('P' + cp, meD.cls || '') : D,
        s: race ? (me && me.pos > 0 ? 'P' + me.pos + ' overall' + DOT : '') + nCars + ' cars' : 'of ' + field.length + DOT + 'best lap' };
    } else {
      const p = me && me.pos > 0 ? me.pos : 0;
      m.pos = { lbl: 'Position', v: p ? this.val('P' + p) : D, s: 'of ' + field.length + (race ? '' : DOT + 'best lap') };
    }

    // gap ahead with trend (race), best lap (practice and qualifying)
    if (race) {
      const ahead = k > 0 ? field[k - 1] : null, behind = k >= 0 ? field[k + 1] : null;
      if (ahead && me) {
        const g = this.between(me, ahead), t = this.trend(ahead.d.idx, g.s, v.SessionTime, refLapTime(meIdx));
        const who = '#' + (ahead.d.num || '') + DOT;
        const words = !isNum(t) ? (ahead.d.name || '').split(/\s+/).pop() : t < -0.05 ? 'closing ' + Math.abs(t).toFixed(1) + ' a lap' : t > 0.05 ? 'losing ' + t.toFixed(1) + ' a lap' : 'steady';
        m.gap = { lbl: 'Gap ahead', v: isNum(g.s) ? this.val(g.text, 's') : esc(g.text), s: who + words, cls: isNum(t) && t < -0.05 ? 'gain' : '' };
      } else if (me && behind) {
        const g = this.between(me, behind); this.gapHist.length = 0;
        m.gap = { lbl: 'Gap behind', v: isNum(g.s) ? this.val(g.text, 's') : esc(g.text), s: 'leading', cls: '' };
      } else m.gap = { lbl: 'Gap ahead', v: D, s: '', cls: '' };
    } else {
      const best = v.LapBestLapTime > 0 ? v.LapBestLapTime : (me ? me.best : NaN);
      let top = 9e9; for (const r of field) if (r.best > 0 && r.best < top) top = r.best;
      const d = best > 0 && top < 9e9 ? best - top : NaN;
      m.gap = { lbl: 'Best lap', v: best > 0 ? esc(this.lap(best)) : D, s: !isNum(d) ? 'no timed lap yet' : d < 0.0005 ? 'fastest here' : this.signed(d, 3) + ' to fastest', cls: '' };
    }

    // delta to best, honest: only a clean, complete lap; pit lane swaps in speed against the limit
    if (v.OnPitRoad) {
      const lim = this.pitLimit(), sp = v.Speed, u = Units.speedUnit(), lo = !!(v.EngineWarnings & 0x10);
      const f = lim > 0 && isNum(sp) ? sp / lim : NaN;
      m.delta = { lbl: 'Pit lane', v: isNum(sp) ? this.val(String(Math.round(Units.speed(sp))), u) : D, vcls: '',
        bar: isNum(f) ? { mode: 'pit', f: clamp(f, 0, 1), over: f > 1.005 } : { mode: 'none' },
        s: (lim > 0 ? 'limit ' + Math.round(Units.speed(lim)) + ' ' + u : 'limit unknown') + DOT + (lo ? 'limiter on' : 'limiter off'), scls: lo ? '' : 'warn' };
    } else {
      let why = '';
      if (!(v.LapBestLapTime > 0)) why = 'no best lap yet';
      else if (L.lapDirty) why = ({ out: 'out lap', in: 'in lap', pit: 'pit lap', off: 'off track' })[whyOf(L.why)] || 'lap not clean';
      else if (this.offLap !== null && this.offLap === v.LapCompleted) why = 'off track';
      else if (!v.LapDeltaToBestLap_OK || !isNum(v.LapDeltaToBestLap)) why = 'no delta yet';
      if (why) m.delta = { lbl: 'Delta to best', v: D, vcls: '', bar: { mode: 'none' }, s: why === 'no best lap yet' ? why : why + DOT + 'no delta', scls: '' };
      else {
        const d = v.LapDeltaToBestLap;
        m.delta = { lbl: 'Delta to best', v: esc(this.signed(d, 2)), vcls: d < 0 ? 'gain' : '', bar: { mode: 'delta', d: clamp(d, -1, 1) }, s: '', scls: '' };
      }
    }

    // time or laps left
    const sess = currentSession(), total = sess ? num(sess.SessionLaps) : NaN;
    const timeOk = isNum(v.SessionTimeRemain) && v.SessionTimeRemain >= 0 && v.SessionTimeRemain < 7 * 86400;
    const lapNo = isNum(v.Lap) && v.Lap > 0 ? v.Lap : NaN;
    if (total > 0) {
      const left = isNum(v.SessionLapsRemainEx) && v.SessionLapsRemainEx >= 0 && v.SessionLapsRemainEx < 30000 ? v.SessionLapsRemainEx : total - (v.LapCompleted || 0);
      m.left = { lbl: 'Laps left', v: isNum(left) ? esc(String(Math.max(0, left))) : D, s: isNum(lapNo) ? 'lap ' + lapNo + ' of ' + total : '' };
    } else m.left = { lbl: 'Time left', v: timeOk ? esc(this.clock(v.SessionTimeRemain)) : D, s: isNum(lapNo) ? 'lap ' + lapNo : '' };

    // fuel in iRacing's own units
    const f = fuelModel(), fu = this.fuelUnit();
    if (f.per > 0 && isNum(f.level)) {
      let s, cls = '';
      if (race && isNum(f.add)) { if (f.add > 0.05) { s = '+' + this.fuel(f.add).toFixed(1) + ' ' + fu + ' to finish'; cls = 'warn'; } else s = 'enough to finish'; }
      else s = this.fuel(f.level).toFixed(1) + ' ' + fu + DOT + this.fuel(f.per).toFixed(Units.metric ? 1 : 2) + ' a lap';
      if (f.estimated) s = 'estimate' + DOT + s;
      m.fuel = { lbl: 'Fuel', v: this.val((f.level / f.per).toFixed(1), 'laps'), s, cls };
    } else m.fuel = { lbl: 'Fuel', v: D, s: 'after one clean lap', cls: '' };

    m.foot = 'Last <b>' + esc(this.lap(v.LapLastLapTime)) + '</b>' + DOT + 'Best <b>' + esc(this.lap(v.LapBestLapTime)) + '</b>';

    // battle tower: seven rows centred on Peter, own class in multiclass
    const a = Math.max(0, Math.min(k - 3, field.length - 7));
    m.tower = {
      title: (race ? 'Battle' : 'Best laps') + (multi && meD.cls ? DOT + meD.cls : ''), col: race ? 'Gap' : '',
      rows: field.slice(Math.max(0, a), Math.max(0, a) + 7).map((r, i) => {
        const mine = r.d.idx === meIdx, pit = r.pit || (mine && !!v.OnPitRoad);
        let pos, g;
        if (race) { pos = multi ? r.cpos : r.pos; g = mine ? (pit ? '' : this.lap(r.last)) : me ? this.between(r, me).text : D; }
        else { pos = r.best > 0 ? Math.max(0, a) + i + 1 : 0; g = this.lap(r.best); }
        return { idx: r.d.idx, pos: pos > 0 ? String(pos) : D, num: r.d.num || D, name: r.d.name || D, gap: g, me: mine, pit, color: multi ? r.d.color : '' };
      }),
    };
    return m;
  },

  /* ---------- paint the DOM (touches only what changed) ---------- */
  cell(id, c) {
    const el = $(id); if (!el) return;
    setText(el.querySelector('.lbl'), c.lbl);
    setHTML(el.querySelector('.v'), c.v);
    setCls(el.querySelector('.v'), 'v' + (c.vcls ? ' ' + c.vcls : ''));
    setText(el.querySelector('.s'), c.s);
    setCls(el.querySelector('.s'), 's' + (c.cls || c.scls ? ' ' + (c.cls || c.scls) : ''));
  },

  paint(m) {
    document.body.classList.toggle('drive-stale', m.stale > 0);
    setText('dSess', m.sess); setText('dTrack', m.track); setText('dClock', m.clock);
    const st = $('dStale'); st.hidden = !(m.stale > 0); setText(st, m.stale > 0 ? 'No data for ' + m.stale + ' s' : '');
    this.cell('cPos', m.pos); this.cell('cGap', m.gap); this.cell('cDelta', m.delta); this.cell('cLeft', m.left); this.cell('cFuel', m.fuel);
    const bar = $('cDelta').querySelector('.dbar'), fill = bar.querySelector('i'), b = m.delta.bar;
    let css = 'width:0';
    if (b.mode === 'delta') css = (b.d < 0 ? 'right:50%;' : 'left:50%;') + 'width:' + (Math.abs(b.d) * 50).toFixed(1) + '%;background:' + (b.d < 0 ? 'var(--gain)' : 'rgba(244,241,234,.55)');
    else if (b.mode === 'pit') css = 'left:0;width:' + (b.f * 100).toFixed(1) + '%;background:' + (b.over ? 'var(--amber)' : 'rgba(244,241,234,.55)');
    if (fill._css !== css) { fill._css = css; fill.style.cssText = css; }
    setCls(bar, 'dbar' + (b.mode === 'pit' ? ' pit' : b.mode === 'none' ? ' none' : ''));
    setHTML('dLaps', m.foot);
    setText('dTowerT', m.tower.title); setText('dTowerG', m.tower.col);
    setHTML('dRows', m.tower.rows.map(r =>
      '<div class="trow' + (r.me ? ' me' : '') + (r.pit ? ' pit' : '') + '" data-idx="' + r.idx + '"' + (r.color ? ' style="--class:' + esc(r.color) + '"' : '') + '><i class="cls"></i>' +
      '<span class="p">' + esc(r.pos) + '</span><span class="n">' + esc(r.num) + '</span>' +
      '<span class="nm">' + esc(r.name) + (r.pit ? '<span class="tag">PIT</span>' : '') + '</span><span class="g">' + esc(r.gap) + '</span></div>').join(''));
  },

  /* ---------- the map ---------- */
  // called by the dashboard's canvas loop (30 fps cap); redraws only when a car moved a visible amount
  frame() {
    if (!this.shown || (typeof Tv !== 'undefined' && Tv.on)) return;
    const v = L.v, stale = this.model ? this.model.stale > 0 : false;
    const sig = [TrackMap.key, TrackMap.source, TrackMap.pts ? TrackMap.pts.length : 0, TrackMap.status, TrackInfo.version, S.version, stale, v.PlayerCarIdx,
      (v.CarIdxLapDistPct || []).map(x => isNum(x) ? Math.round(x * 2000) : -1).join(',')].join('|');
    if (sig === this.mapSig) return;
    this.mapSig = sig;
    this.drawMap($('dMapCv'), this.mapCars(), { stale, multi: S.multiClass });
    setText('dMapNote', this.credit());
  },

  credit() {
    const raw = TrackInfo.raw, out = [];
    if (raw && raw.credit && raw.turns && raw.turns.length) out.push(String(raw.credit).replace(/^Corner names:\s*/i, 'Corner names: '));
    if (TrackMap.pts && TrackMap.source === 'library') out.push('outline SIMRacingApps');
    return out.join(this.DOT);
  },

  mapCars() {
    const v = L.v, pcts = v.CarIdxLapDistPct, out = [];
    if (!pcts) return out;
    const meIdx = isNum(v.PlayerCarIdx) ? v.PlayerCarIdx : S.me;
    for (const d of racers()) {
      const p = pcts[d.idx];
      if (!isNum(p) || p < 0 || arr('CarIdxTrackSurface', d.idx) === -1) continue;
      out.push({ idx: d.idx, num: d.num, pct: p, pit: !!arr('CarIdxOnPitRoad', d.idx), color: d.color, me: d.idx === meIdx });
    }
    return out;
  },

  fitCanvas(cv) {
    const w = cv.clientWidth || 1108, h = cv.clientHeight || 620, dpr = window.devicePixelRatio || 1;
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
    return { w, h, dpr };
  },

  // outline, start/finish and corner names drawn once into an offscreen layer; each frame copies it and draws the dots
  buildLayer(w, h, dpr) {
    if (!this.layer) this.layer = document.createElement('canvas');
    const c = this.layer; c.width = Math.round(w * dpr); c.height = Math.round(h * dpr);
    const g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, w, h);
    this.labels = [];
    const pts = TrackMap.pts, vw = this.view(w, h), sp = pct => TrackMap.toScreen(TrackMap.at(pct), vw);
    const line = () => { g.beginPath(); for (let i = 0; i <= pts.length; i++) { const q = TrackMap.toScreen(pts[i % pts.length], vw); i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1]); } };
    g.lineJoin = 'round'; g.lineCap = 'round';
    line(); g.strokeStyle = '#0b0d10'; g.lineWidth = 22; g.stroke();
    line(); g.strokeStyle = 'rgba(244,241,234,.42)'; g.lineWidth = 13; g.stroke();
    line(); g.strokeStyle = '#1b1f25'; g.lineWidth = 10; g.stroke();
    const a = sp(0), b = sp(0.002), dx = b[0] - a[0], dy = b[1] - a[1], l = Math.hypot(dx, dy) || 1, nx = -dy / l * 14, ny = dx / l * 14;
    g.beginPath(); g.moveTo(a[0] - nx, a[1] - ny); g.lineTo(a[0] + nx, a[1] + ny); g.strokeStyle = '#f4f1ea'; g.lineWidth = 4; g.stroke();
    // corners: small text on the outside of the bend, never a numbered disc (build plan 2.3)
    const turns = TrackInfo.raw && Array.isArray(TrackInfo.raw.turns) ? TrackInfo.raw.turns : [];
    const cen = TrackMap.toScreen([vw.cx, vw.cy], vw);
    g.font = '20px ' + MAP_FONT; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillStyle = '#8d8a82';
    for (const t of turns) {
      const pct = isNum(t.pctApex) ? t.pctApex : t.pct;
      if (!isNum(pct)) continue;
      const p0 = sp(pct - 0.006), p = sp(pct), p1 = sp(pct + 0.006);
      const tx = p1[0] - p0[0], ty = p1[1] - p0[1], tl = Math.hypot(tx, ty) || 1;
      let ox = -ty / tl, oy = tx / tl;
      const bend = (p[0] - p0[0]) * (p1[1] - p0[1]) - (p[1] - p0[1]) * (p1[0] - p0[0]);
      if (Math.abs(bend) < 1) { if ((p[0] - cen[0]) * ox + (p[1] - cen[1]) * oy < 0) { ox = -ox; oy = -oy; } }
      else if (bend < 0) { ox = -ox; oy = -oy; }
      const text = t.name ? String(t.name) : 'T' + t.n, tw = g.measureText(text).width;
      const x = p[0] + ox * (30 + tw * 0.35), y = p[1] + oy * 30;
      const box = { x: x - tw / 2 - 4, y: y - 13, w: tw + 8, h: 26 };
      if (this.labels.some(o => o.x < box.x + box.w && box.x < o.x + o.w && o.y < box.y + box.h && box.y < o.y + o.h)) continue;
      if (box.x < 0 || box.y < 0 || box.x + box.w > w || box.y + box.h > h - 30) continue;
      this.labels.push(box);
      g.fillText(text, x, y);
    }
  },

  view(w, h) {
    // the shared fit (TrackMap.fit) with a tighter pad: this map owns its whole box
    const pts = TrackMap.pts;
    if (this._vw && this._vw.w === w && this._vw.h === h && this._vw.pts === pts) return this._vw;
    let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    for (const p of pts) { if (p[0] < x0) x0 = p[0]; if (p[0] > x1) x1 = p[0]; if (p[1] < y0) y0 = p[1]; if (p[1] > y1) y1 = p[1]; }
    const pad = 44, tw = x1 - x0 || 1, th = y1 - y0 || 1;
    const sA = Math.min((w - 2 * pad) / tw, (h - 2 * pad) / th), sB = Math.min((w - 2 * pad) / th, (h - 2 * pad) / tw), rot = sB > sA * 1.08;
    this._vw = { w, h, s: rot ? sB : sA, rot, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2, pts };
    return this._vw;
  },

  drawMap(cv, cars, opt) {
    if (!cv) return;
    const { w, h, dpr } = this.fitCanvas(cv), g = cv.getContext('2d');
    g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, cv.width, cv.height); g.setTransform(dpr, 0, 0, dpr, 0, 0);
    const hasOutline = TrackMap.pts && TrackMap.pts.length >= 200;
    if (!hasOutline) {
      // no outline: say so in one line and draw no cars (a straight bar put them where they are not); the tower has the order
      g.fillStyle = '#8d8a82'; g.font = '26px ' + MAP_FONT; g.textAlign = 'center'; g.textBaseline = 'middle';
      g.fillText(TrackMap.status || 'Loading track map', w / 2, h / 2);
      return;
    }
    const lk = [w, h, dpr, TrackMap.key, TrackMap.source, TrackMap.pts.length, TrackInfo.version].join('|');
    if (lk !== this.layerKey || !this.layer) { this.buildLayer(w, h, dpr); this.layerKey = lk; }
    g.setTransform(1, 0, 0, 1, 0, 0); g.drawImage(this.layer, 0, 0); g.setTransform(dpr, 0, 0, dpr, 0, 0);
    const vw = this.view(w, h), sp = pct => TrackMap.toScreen(TrackMap.at(pct), vw);
    const dim = !!opt.stale, me = cars.find(c => c.me);
    const others = cars.filter(c => !c.me);
    for (const c of others) {
      const p = sp(c.pct);
      g.globalAlpha = c.pit ? 0.35 : 1;
      g.beginPath(); g.arc(p[0], p[1], 8, 0, Math.PI * 2);
      g.fillStyle = dim ? '#5d5a54' : opt.multi ? (c.color || '#c9ccd1') : '#c9ccd1'; g.fill();
      g.lineWidth = 2; g.strokeStyle = '#060606'; g.stroke();
    }
    g.globalAlpha = 1;
    this.mePt = null;
    if (!me) return;
    // the three cars ahead and three behind on track get their number, in a dark chip clear of corner names
    const rel = c => { let d = c.pct - me.pct; if (d > 0.5) d -= 1; if (d < -0.5) d += 1; return d; };
    const near = others.filter(c => rel(c) > 0).sort((a, b) => rel(a) - rel(b)).slice(0, 3)
      .concat(others.filter(c => rel(c) <= 0).sort((a, b) => rel(b) - rel(a)).slice(0, 3));
    const tags = [];
    g.font = '600 20px ' + MAP_FONT; g.textAlign = 'left'; g.textBaseline = 'middle';
    for (const c of near) {
      if (!c.num) continue;
      const p = sp(c.pct), tw = g.measureText(c.num).width + 12;
      const hit = (x, y) => this.labels.concat(tags).some(o => x < o.x + o.w && o.x < x + tw && y < o.y + o.h && o.y < y + 26);
      const spots = [[12, -32], [-12 - tw, -32], [12, 6], [-12 - tw, 6]];
      let bx = p[0] + 12, by = p[1] - 32;
      for (const q of spots) if (!hit(p[0] + q[0], p[1] + q[1])) { bx = p[0] + q[0]; by = p[1] + q[1]; break; }
      tags.push({ x: bx, y: by, w: tw, h: 26, idx: c.idx });
      g.fillStyle = 'rgba(6,6,6,.82)'; g.fillRect(bx, by, tw, 26);
      g.fillStyle = dim ? '#5d5a54' : '#f4f1ea'; g.fillText(c.num, bx + 6, by + 14);
    }
    this.tags = tags;
    // Peter last, on top: gold dot and ring
    const p = sp(me.pct), gold = dim ? '#5d5a54' : '#f2c230';
    this.mePt = [p[0] * dpr, p[1] * dpr];
    g.beginPath(); g.arc(p[0], p[1], 18, 0, Math.PI * 2); g.lineWidth = 2.5; g.strokeStyle = gold; g.stroke();
    g.beginPath(); g.arc(p[0], p[1], 11, 0, Math.PI * 2); g.fillStyle = gold; g.fill();
    g.lineWidth = 2; g.strokeStyle = '#060606'; g.stroke();
  },
};

window.Drive = Drive;
