'use strict';
// Pre-session brief (D4). From the moment a session is loaded until you are in the car, the top screen shows what the
// history says about this car at this track: your best lap, when you last drove here, the fuel one lap takes, the weather,
// and the track. It fades away as you get in and does not come back for that session. It never shows while you drive:
// the first frame with you on track hides it, and it ignores clicks. Not shown in friends mode, replays, the debrief or Rig Doctor.
const Brief = {
  MAX_MS: 10 * 60000,        // a session that is only watched does not keep the screen for ever
  el: null, data: null, seen: {}, driven: {}, offSince: 0, fetchedAt: 0, map: null, drawn: '',

  init() { setInterval(() => this.tick(), 400); window.addEventListener('resize', () => { this.drawn = ''; }); },

  want() {
    const v = L.v;
    if (!UI.live()) { this.offSince = 0; return false; }
    if (v.IsOnTrack) { this.driven[L.sessKey] = true; this.offSince = 0; return false; }
    if (!this.offSince) this.offSince = Date.now();
    if (!this.seen[L.sessKey]) this.seen[L.sessKey] = Date.now();
    if (this.driven[L.sessKey] || S.me < 0 || !S.drivers.size) return false;
    if (Date.now() - this.offSince < 2500) return false;                 // a blink of IsOnTrack=0 (session change) is not "waiting to drive"
    if (Date.now() - this.seen[L.sessKey] > this.MAX_MS) return false;
    if (L.demo || v.IsReplayPlaying) return false;
    if (typeof Guest !== 'undefined' && Guest.g && Guest.g.active) return false;
    if (typeof Debrief !== 'undefined' && Debrief.el) return false;
    if (typeof Rig !== 'undefined' && Rig.el) return false;
    if (typeof SessionsHost !== 'undefined' && SessionsHost.el) return false;
    return true;
  },

  tick() {
    if (document.hidden) return;
    let want = false;
    try { want = this.want(); } catch (e) { console.error(e); }
    if (want && !this.el) this.show();
    else if (!want && this.el) this.hide();
    if (this.el) {
      if (Date.now() - this.fetchedAt > 20000) this.load();
      this.render();
    }
  },

  async load() {
    this.fetchedAt = Date.now();
    try { const d = await (await fetch('/brief', { cache: 'no-store' })).json(); if (d && d.ready) { this.data = d; this.drawn = ''; } } catch (e) { /* irdash restarting */ }
  },

  show() {
    const el = document.createElement('div'); el.id = 'brief'; el.setAttribute('aria-hidden', 'true');
    el.innerHTML = '<div class="bf-top"><span>Pre-session &nbsp;<b id="bfType"></b></span><span>Car <b>No. 4</b></span></div>' +
      '<div class="bf-head"><label>Track</label><div class="bf-track" id="bfTrack"></div><div class="bf-cfg" id="bfCfg"></div><div class="bf-car" id="bfCar"></div></div>' +
      '<div class="bf-cards" id="bfCards"></div>' +
      '<div class="bf-map"><canvas id="bfMap"></canvas></div><div class="bf-credit" id="bfCredit"></div>' +
      '<div class="bf-foot"><span id="bfWho"></span></div>';
    document.body.appendChild(el);
    this.el = el; this.map = el.querySelector('#bfMap'); this.drawn = ''; this.data = null;
    requestAnimationFrame(() => el.classList.add('on'));
    this.load();
  },

  hide() {
    const el = this.el; this.el = null;
    if (!el) return;
    el.classList.remove('on');
    setTimeout(() => el.remove(), 1100);
  },

  fuelTxt(l, d) { return isNum(l) ? (Units.metric ? l.toFixed(d) + '<small>L</small>' : (l / 3.785412).toFixed(d) + '<small>gal</small>') : '–'; },

  weather() {
    const v = L.v, wi = (S.y && S.y.WeekendInfo) || {}, bits = [];
    if (isNum(v.AirTemp)) bits.push('Air ' + Units.temp(v.AirTemp));
    if (isNum(v.TrackTempCrew)) bits.push('Track ' + Units.temp(v.TrackTempCrew));
    if (isNum(v.WindVel) && isNum(v.WindDir)) {
      const from = ((v.WindDir * 180 / Math.PI) % 360 + 360) % 360;
      bits.push('Wind ' + (Units.metric ? Math.round(v.WindVel * 3.6) + ' km/h' : Math.round(v.WindVel * 2.237) + ' mph') + ' from ' + COMPASS[Math.round(from / 45) % 8]);
    }
    const wet = v.TrackWetness, dry = !(wet >= 3) && !(v.Precipitation > 0.02);
    bits.push(wet >= 3 ? 'Track ' + String(WETNESS[wet] || 'wet').toLowerCase() : v.Precipitation > 0.02 ? 'Rain ' + Math.round(clamp(v.Precipitation, 0, 1) * 100) + '%' : 'Dry');
    return { main: wi.TrackSkies || (dry ? 'Dry' : 'Wet'), sub: bits.join(' · ') };
  },

  render() {
    const d = this.data, key = [L.sessKey, d ? d.pb && d.pb.time : '', d ? d.fuel : '', S.version, TrackMap.pts ? TrackMap.pts.length : 0, TrackInfo.version, Math.round((L.v.AirTemp || 0) * 2)].join('|');
    if (key === this.drawn) return;
    this.drawn = key;
    const e = esc, $b = id => this.el.querySelector('#' + id);
    $b('bfType').textContent = sessionType();
    $b('bfTrack').textContent = S.track.name || '';
    $b('bfCfg').textContent = S.track.config || '';
    const me = S.drivers.get(S.me) || {};
    $b('bfCar').innerHTML = e((d && d.car) || me.car || '') + (isNum(S.track.lengthKm) ? '<small>' + (Units.metric ? S.track.lengthKm.toFixed(2) + ' km' : (S.track.lengthKm * 0.621371).toFixed(2) + ' mi') + ' lap</small>' : '');
    $b('bfWho').textContent = me.name || '';
    const card = (label, big, sub, cls) => '<div class="bf-card"><label>' + label + '</label><b class="' + (cls || '') + '">' + big + '</b><span>' + sub + '</span></div>';
    let cards = '';
    if (!d) cards = card('Best here', '…', '') + card('Track time', '…', '') + card('Fuel per lap', '…', '') + card('Conditions', '…', '');
    else {
      const pb = d.pb;
      cards += card('Best here', pb ? fmtLap(pb.time) : '–', pb ? d.sessionsCar + (d.sessionsCar === 1 ? ' session' : ' sessions') +
        (d.pbAny ? '<br>Any car <i>' + fmtLap(d.pbAny.time) + '</i> · ' + e(d.pbAny.car) : '') : (d.lastHere ? 'Not in this car yet' : ''), pb ? 'gold' : '');
      cards += card('Track time', d.lastCar ? d.hoursCar + '<small>h</small>' : '–', d.lastCar ? d.sessionsCar + (d.sessionsCar === 1 ? ' session' : ' sessions') : '');
      if (isNum(d.fuel) && d.fuel > 0) {
        const laps = S.fuelMax > 0 ? Math.floor(S.fuelMax / d.fuel) : NaN;
        cards += card('Fuel per lap', this.fuelTxt(d.fuel, 2), (isNum(laps) ? 'Full tank ' + e(Units.fuel(S.fuelMax, 0)) + ' · <i>' + laps + ' laps</i><br>' : '') + d.fuelLaps + ' clean laps · ' + d.fuelFiles + (d.fuelFiles === 1 ? ' session' : ' sessions'));
      } else cards += card('Fuel per lap', '–', '');
    }
    const w = this.weather();
    cards += '<div class="bf-card"><label>Conditions</label><b class="w">' + e(w.main) + '</b><span>' + e(w.sub) + '</span></div>';
    $b('bfCards').innerHTML = cards;
    this.drawMap();
  },

  drawMap() {
    const cv = this.map, box = cv.parentNode, dpr = window.devicePixelRatio || 1, w = box.clientWidth, h = box.clientHeight;
    if (!w || !h) return;
    cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
    const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, w, h);
    const pts = TrackMap.pts, F = '"Bahnschrift SemiCondensed", Bahnschrift, "Segoe UI", sans-serif';
    this.el.querySelector('#bfCredit').textContent = pts ? [TrackMap.source === 'library' ? 'Outline: SIMRacingApps (Apache 2.0)' : '', TrackInfo.raw && TrackInfo.raw.credit].filter(Boolean).join(' · ') : '';
    if (!pts) { g.fillStyle = '#6f6c64'; g.font = '22px ' + F; g.textAlign = 'center'; g.fillText(TrackMap.status || 'No map yet', w / 2, h / 2); return; }
    let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
    for (const p of pts) { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[0]); y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); }
    const pad = 80, tw = x1 - x0 || 1, th = y1 - y0 || 1;
    const sA = Math.min((w - 2 * pad) / tw, (h - 2 * pad) / th), sB = Math.min((w - 2 * pad) / th, (h - 2 * pad) / tw), rot = sB > sA * 1.08, s = rot ? sB : sA;
    const sc = p => { let x = (p[0] - (x0 + x1) / 2) * s, y = -(p[1] - (y0 + y1) / 2) * s; if (rot) { const t = x; x = -y; y = t; } return [w / 2 + x, h / 2 + y]; };
    const scr = pts.map(sc), N = pts.length;
    g.lineJoin = 'round'; g.lineCap = 'round';
    const path = a => { g.beginPath(); a.forEach((q, i) => i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1])); };
    if (TrackMap.pit) { path(TrackMap.pit.map(sc)); g.setLineDash([6, 8]); g.strokeStyle = '#3a3832'; g.lineWidth = 3; g.stroke(); g.setLineDash([]); }
    path(scr); g.closePath(); g.strokeStyle = '#171715'; g.lineWidth = 30; g.stroke();
    path(scr); g.closePath(); g.strokeStyle = '#4a4740'; g.lineWidth = 11; g.stroke();
    // the line: a gold tick across the track
    const a = scr[0], b = scr[3], dx = b[0] - a[0], dy = b[1] - a[1], m = Math.hypot(dx, dy) || 1;
    g.beginPath(); g.moveTo(a[0] - dy / m * 20, a[1] + dx / m * 20); g.lineTo(a[0] + dy / m * 20, a[1] - dx / m * 20); g.strokeStyle = '#f2c230'; g.lineWidth = 5; g.stroke();
    // numbered corners, names and pit marks: the shared drawing (corners.js), the same on every page
    if (typeof Corners !== 'undefined' && TrackInfo.raw) Corners.draw(g, pct => sc(TrackMap.at(pct)), { data: TrackInfo.raw, w, h, ticks: false, credit: false });
  },
};
Brief.init();
