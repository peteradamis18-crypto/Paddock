'use strict';
// Friends mode on the top screen. irdash /guest says what the Stream Deck guest page has chosen.
//  - out of the car: a setup card (driver, car, track, wheel, racing line) with this car+track's leaderboard
//  - in the car: a simple guest view (lap times, the track map, pedals, leaderboard)
// Clean laps by the guest are sent to irdash, which keeps the leaderboard in guest\board.tsv.
const Guest = {
  g: { active: false }, el: null, mode: '', lastLaps: 0, sessKey: '',

  init() { this.poll(); setInterval(() => this.poll(), 1000); },

  async poll() {
    if (document.hidden) return;
    try { this.g = await (await fetch('/guest', { cache: 'no-store' })).json(); } catch (e) { return; }
    const ev = this.g.event;
    if (ev && ev.id !== this.lastEvent) { if (this.lastEvent !== undefined) this.celebrate(ev); this.lastEvent = ev.id; }
    if (!ev && this.lastEvent === undefined) this.lastEvent = null;
    this.render();
  },

  // NEW RECORD / PERSONAL BEST / tonight's podium, over everything for a few seconds
  celebrate(ev) {
    const h = esc, old = document.getElementById('gcele'); if (old) old.remove();
    const el = document.createElement('div'); el.id = 'gcele'; el.className = ev.kind;
    if (ev.kind === 'podium') {
      const top = ev.top || [], place = (p, i) => p ? '<div class="pod p' + (i + 1) + '"><em>' + (i + 1) + '</em><b>' + h(p.name) + '</b><span>' + fmtLap(p.time) + '</span><small>' + h(p.car) + ' · ' + h(p.track) + '</small><i></i></div>' : '<div class="pod"></div>';
      el.innerHTML = '<label>Podium</label><div class="pods">' + place(top[1], 1) + place(top[0], 0) + place(top[2], 2) + '</div>';
    } else {
      const title = ev.kind === 'record' ? 'New track record' : 'Personal best';
      const sub = ev.kind === 'record' ? (ev.beat ? 'Beat ' + h(ev.beat) + ' by ' + (+ev.by).toFixed(3) + ' s' : ev.by > 0 ? '−' + (+ev.by).toFixed(3) + ' s' : 'First entry')
                                       : '−' + (+ev.by).toFixed(3) + ' s';
      el.innerHTML = '<div class="sweep"></div><label>' + title + '</label><b>' + h(ev.name) + '</b><span>' + fmtLap(ev.time) + '</span><small>' + h(ev.car) + ' · ' + h(ev.track) + ' &nbsp;·&nbsp; ' + sub + '</small>';
    }
    document.body.appendChild(el);
    requestAnimationFrame(() => el.classList.add('on'));
    setTimeout(() => { el.classList.remove('on'); setTimeout(() => el.remove(), 800); }, ev.kind === 'podium' ? 25000 : 7000);
    el.addEventListener('click', () => el.remove());
  },

  driving() { return UI.live() && !!L.v.IsOnTrack; },

  render() {
    const g = this.g;
    const want = !g.active ? '' : g.draft != null ? 'type' : this.driving() ? 'drive' : 'setup';
    if (want === 'type' && this.mode === 'type' && this.lastDraft === g.draft + g.voiceDraft) return;   // keep the caret blinking smoothly
    this.lastDraft = g.draft + g.voiceDraft;
    if (want !== this.mode) {
      if (this.el) { this.el.remove(); this.el = null; }
      this.mode = want;
      if (!want) return;
      this.el = document.createElement('div');
      this.el.id = 'guest'; this.el.className = want;
      document.body.appendChild(this.el);
    }
    if (!want) return;
    const h = esc;
    const board = (g.times || []).slice(0, want === 'drive' ? 6 : 10).map((r, i) =>
      '<div class="gb-row' + (r.name === g.driver ? ' me' : '') + '"><span>' + (i + 1) + '</span><b>' + h(r.name) + '</b><em>' + fmtLap(r.time) + '</em></div>').join('')
      || '<div class="gb-empty">No laps yet</div>';
    const wheel = this.wheelWords(g);
    const aids = /abs|tc/i.test(g.car.aids || '') ? 'ABS + traction control' : 'No driver aids';
    if (want === 'type') {
      // a new driver typing their name on the Stream Deck keyboard
      this.el.innerHTML =
        '<div class="g-top"><span>Friends mode · <b>new driver</b></span><span>Type on the Stream Deck, then press <b>DONE</b></span></div>' +
        '<div class="g-type"><label>Name</label><b>' + h(g.draft) + '<i class="caret"></i></b>' +
          '<small>' + (g.draft ? (g.voiceDraft ? 'Spotter says this name' : 'Spotter says driver') : '') + '</small></div>';
      return;
    }
    if (want === 'setup') {
      this.el.innerHTML =
        '<div class="g-top"><span>Friends mode</span><span>Choose on the Stream Deck, then press <b>START</b></span></div>' +
        '<div class="g-who"><label>Driver</label><b>' + h(g.driver) + '</b>' +
          (g.driverId !== 'guest' ? '<small>' + (g.voiceDriver ? 'Spotter says ' + h(g.driver) : 'Spotter says driver') + '</small>' : '') + '</div>' +
        '<div class="g-pick">' +
          '<div><label>Car</label><b>' + h(g.car.full || g.car.name) + '</b><small>' + h(aids) + '</small></div>' +
          '<div><label>Track</label><b>' + h(g.track.full || g.track.name) + '</b></div>' +
          '<div><label>Wheel</label><b>' + wheel + '</b></div>' +
          '<div><label>Racing line</label><b>' + (g.line ? 'Shown' : 'Hidden') + '</b>' + (g.lineKey ? '' : '<small>key not set up yet</small>') + '</div>' +
        '</div>' +
        (g.board ? '<div class="g-board"><label>Leaderboard · ' + h(g.car.name) + ' at ' + h(g.track.name) + '</label>' + board + '</div>' : '') +
        '<div class="g-foot"><span>Car <b>No. 4</b></span><span>EXIT FRIENDS</span></div>';
    } else {
      // static parts; the timer, coach and pedals are refreshed every frame in loop()
      if (!this.el.dataset.built) {
        this.el.dataset.built = '1';
        this.el.innerHTML =
          '<div class="g-top"><span>Friends mode · <b class="gd-name"></b></span><span class="gd-car"></span></div>' +
          '<div class="gd-time"><label>Current lap</label><b class="gd-cur">–</b>' +
            '<div class="gd-refs"><div><label>Last</label><b class="gd-last">–</b></div><div><label>Best</label><b class="gd-best">–</b></div></div></div>' +
          '<div class="gd-clock"><label class="gd-clock-l">Session</label><b class="gd-clock-v">–</b></div>' +
          '<div class="gd-ffb"></div>' +
          '<div class="gd-map"><canvas class="gd-mapc"></canvas></div>' +
          '<div class="gd-pedals"><div><label>Brake</label><span class="gd-bar"><i class="gd-brk"></i></span></div>' +
            '<div><label>Throttle</label><span class="gd-bar"><i class="gd-thr"></i></span></div></div>' +
          '<div class="g-board"><label>Leaderboard</label><div class="gd-board"></div></div>';
      }
      this.el.querySelector('.gd-name').textContent = g.driver;
      this.el.querySelector('.gd-car').textContent = (g.car.name || '') + ' · ' + (g.track.name || '');
      this.el.querySelector('.gd-board').innerHTML = g.board ? board : '';
      this.el.querySelector('.gd-map').style.display = g.coach ? '' : 'none';
      this.el.querySelector('.gd-ffb').textContent = this.wheelLine(g);
    }
  },

  wheelWords(g) {
    const name = { light: 'Light', medium: 'Medium', full: 'Full' }[g.wheel] || 'Light';
    const n = g.wheel === 'full' ? g.wheelOwn : g.wheelFeel;
    if (g.wheel === 'full') return n != null ? name + ' · ' + Math.round(n) + ' Nm' : name;
    return n != null ? name + ' · ' + Math.round(n) + ' Nm feel' : name;
  },

  wheelLine(g) {
    const own = g.wheelOwn != null ? Math.round(g.wheelOwn) : null;
    const name = { light: 'Light', medium: 'Medium', full: 'Full' }[g.wheel] || 'Light';
    // The sim's max-force reading stays at your own wheel, so it is not the feel. Name only.
    if (g.wheel === 'full') return own != null ? 'Full · ' + own + ' Nm' : 'Full';
    return name;
  },

  fmtTenths(t) {
    if (!isNum(t) || t < 0) return '–';
    const m = Math.floor(t / 60), s = t - m * 60, body = s.toFixed(1);
    return m > 0 ? m + ':' + (s < 10 ? '0' : '') + body : body;
  },

  frame() {
    // send each new clean lap while friends mode is on
    if (L.sessKey !== this.sessKey) { this.sessKey = L.sessKey; this.lastLaps = L.laps.length; }
    if (L.laps.length < this.lastLaps) this.lastLaps = L.laps.length;
    while (this.lastLaps < L.laps.length) {
      const lap = L.laps[this.lastLaps++];
      if (this.g.active && lap.clean && isNum(lap.time) && lap.time > 0) fetch('/api/guest/lap?t=' + lap.time.toFixed(3)).then(() => this.poll()).catch(() => { });
    }
    if (this.mode !== 'drive' || !this.el || !this.el.dataset.built) return;
    // The outline starts loading when the session arrives. If that first try is still on its
    // 15 s retry, ask again so the map is up within a couple of seconds of getting in the car.
    if ((!TrackMap.pts || TrackMap.pts.length < 2) && TrackMap.key) {
      const now = Date.now();
      if (!this.mapAsk || now - this.mapAsk > 2000) {
        this.mapAsk = now;
        clearTimeout(TrackMap.timer);
        TrackMap.load();
      }
    }
    const v = L.v, q = s => this.el.querySelector(s);
    let cur = v.LapCurrentLapTime;
    let live = cur > 0;
    if (!live) {
      // outlaps often publish no current time; count session time until the first crossing
      const st = v.SessionTime, pct = v.LapDistPct, lap = v.Lap;
      if (this.outT0 == null || this.outLap !== lap || (isNum(pct) && isNum(this.outPct) && pct + 0.5 < this.outPct)) {
        this.outT0 = isNum(st) ? st : null;
        this.outLap = lap;
      }
      this.outPct = pct;
      if (isNum(st) && this.outT0 != null) { cur = Math.max(0, st - this.outT0); live = true; }
    } else { this.outT0 = null; this.outPct = v.LapDistPct; }
    const curEl = q('.gd-cur');
    curEl.textContent = live ? this.fmtTenths(cur) : '–';
    const last = v.LapLastLapTime, best = v.LapBestLapTime;
    q('.gd-last').textContent = last > 0 ? fmtLap(last) : '–';
    q('.gd-best').textContent = best > 0 ? fmtLap(best) : '–';
    const pb = last > 0 && best > 0 && Math.abs(last - best) < 0.001;
    q('.gd-last').className = 'gd-last' + (pb ? ' pb' : '');
    q('.gd-best').className = 'gd-best' + (pb ? ' pb' : '');
    // Same rule as the main timer: green only when the live delta says this point of the lap is ahead.
    // A raw current time is almost always shorter than the best lap, so that alone must not turn it green.
    const aheadOf = (ok, d) => v[ok] && isNum(v[d]) && v[d] < -0.005;
    const ahead = aheadOf('LapDeltaToBestLap_OK', 'LapDeltaToBestLap') || aheadOf('LapDeltaToSessionBestLap_OK', 'LapDeltaToSessionBestLap');
    curEl.className = 'gd-cur' + (ahead ? ' ahead' : '');
    const rem = v.SessionTimeRemain, unlimited = !isNum(rem) || rem >= 48 * 3600;
    q('.gd-clock-l').textContent = unlimited ? 'Session' : 'Time left';
    q('.gd-clock-v').textContent = unlimited ? fmtDur(v.SessionTime) : fmtDur(rem);
    q('.gd-brk').style.height = Math.round(clamp(v.Brake || 0, 0, 1) * 100) + '%';
    q('.gd-thr').style.height = Math.round(clamp(v.Throttle || 0, 0, 1) * 100) + '%';
    q('.gd-ffb').textContent = this.wheelLine(this.g);
    this.drawMap(v);
  },

  // local fit: TrackMap.fit() would overwrite the main map's view
  mapFit(pts, w, h) {
    let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    for (const p of pts) { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[0]); y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); }
    const pad = 36, tw = x1 - x0 || 1, th = y1 - y0 || 1;
    const sA = Math.min((w - 2 * pad) / tw, (h - 2 * pad) / th), sB = Math.min((w - 2 * pad) / th, (h - 2 * pad) / tw);
    const rot = sB > sA * 1.08;
    return { w, h, s: rot ? sB : sA, rot, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2 };
  },
  mapScr(p, vw) {
    let x = (p[0] - vw.cx) * vw.s, y = -(p[1] - vw.cy) * vw.s;
    if (vw.rot) { const t = x; x = -y; y = t; }
    return [vw.w / 2 + x, vw.h / 2 + y];
  },

  drawMap(v) {
    const cv = this.el.querySelector('.gd-mapc');
    if (!cv) return;
    const w = cv.clientWidth, h = cv.clientHeight;
    if (w < 20 || h < 20) { return; }
    const dpr = window.devicePixelRatio || 1;
    const pw = Math.round(w * dpr), ph = Math.round(h * dpr);
    if (cv.width !== pw || cv.height !== ph) { cv.width = pw; cv.height = ph; }
    const g = cv.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    g.lineJoin = 'round'; g.lineCap = 'round';
    const pts = TrackMap.pts;
    if (!this.trail) this.trail = [];
    if (!pts || pts.length < 2) { this.dot = null; return; }
    const vw = this.mapFit(pts, w, h);
    const scr = pts.map(p => this.mapScr(p, vw));
    const stroke = (arr, closed, color, width) => {
      g.beginPath();
      for (let i = 0; i < arr.length; i++) { const q = arr[i]; if (i) g.lineTo(q[0], q[1]); else g.moveTo(q[0], q[1]); }
      if (closed) g.closePath();
      g.strokeStyle = color; g.lineWidth = width; g.stroke();
    };
    stroke(scr, true, 'rgba(242,194,48,0.22)', 12);
    stroke(scr, true, '#f2c230', 2.5);
    const pct = v.LapDistPct;
    if (!isNum(pct)) { this.dot = null; return; }
    const at = p => this.mapScr(TrackMap.at(p), vw);
    const a = at(0), b = at(0.004);
    const dx = b[0] - a[0], dy = b[1] - a[1], m = Math.hypot(dx, dy) || 1, nx = -dy / m, ny = dx / m;
    g.beginPath();
    g.moveTo(a[0] - nx * 16, a[1] - ny * 16); g.lineTo(a[0] + nx * 16, a[1] + ny * 16);
    g.strokeStyle = '#f2c230'; g.lineWidth = 4; g.stroke();
    if (this.trailPct == null || pct + 0.5 < this.trailPct) this.trail = [];
    this.trailPct = pct;
    const here = at(((pct % 1) + 1) % 1);
    const prev = this.trail.length ? this.trail[this.trail.length - 1] : null;
    // a tow or a jumped sample would draw a chord across the map; start the trail again instead
    if (prev && Math.hypot(here[0] - prev[0], here[1] - prev[1]) > 90) this.trail = [];
    const prev2 = this.trail.length ? this.trail[this.trail.length - 1] : null;
    if (!prev2 || Math.hypot(here[0] - prev2[0], here[1] - prev2[1]) > 4) this.trail.push([here[0], here[1]]);
    if (this.trail.length > 400) this.trail.shift();
    if (this.trail.length >= 2) stroke(this.trail, false, 'rgba(242,194,48,0.35)', 3);
    g.beginPath(); g.arc(here[0], here[1], 8, 0, Math.PI * 2); g.fillStyle = '#f2c230'; g.fill();
    this.dot = { x: here[0], y: here[1] };
  },
};
Guest.init();
