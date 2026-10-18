// Live TV view (C-22). A broadcast picture of this race, drawn from telemetry.
// Canvas 2D, not WebGL: the tests launch Chrome with --disable-gpu, which has no WebGL.
// The track is flat. Every vertex uses Y = 0 (Tv.groundY). Invented hills are not allowed.
const Tv = {
  on: false,
  running: false,
  frames: 0,
  lastRenderAt: -1000,
  groundY: 0,
  air: 0,
  haveCam: false,
  eyeGap: 0,
  cutGap: 0,
  cutAt: 0,
  fov: 0.9,
  eye: { x: 0, y: 40, z: 0 },
  look: { x: 0, y: 0, z: 0 },
  shot: null,
  battle: null,
  shown: {},
  dots: [],
  field: [],
  shots: [
    { name: 'HELICOPTER', secs: 8 },
    { name: 'CHASE', secs: 10 },
    { name: 'BATTLE', secs: 12 },
    { name: 'LEADER', secs: 9 },
    { name: 'TRACK', secs: 14 },
  ],

  init() {
    this.pollAt = 0;
    this.poll();
  },

  poll() {
    // A slow reply must not undo a newer one (the test toggles while a poll is in flight).
    const n = (this._poll = (this._poll || 0) + 1);
    fetch('/tv', { cache: 'no-store' }).then(r => r.json()).then(d => {
      if (n !== this._poll) return;
      if (d && typeof d.on === 'boolean') this.set(d.on);
    }).catch(() => {});
  },

  // Same value must not reset the director. Turning on starts the shot list again.
  set(on) {
    on = !!on;
    if (on === this.on) return;
    this.on = on;
    // Drive v1: the camera takes the map slot only (drive.css body.tv-on); the band and the tower stay
    document.body.classList.toggle('tv-on', on);
    if (!on) {
      this.running = false;
      return;
    }
    this.haveCam = false;
    this.air = 0;
    this.shown = {};
    this.battle = null;
    this.shot = null;
    this.cutGap = 0;
    this.eyeGap = 0;
    this.running = this.driving();
  },

  // A live frame with the car on track. The shared renderer checks this too after disconnects.
  driving() {
    return !!(L.v && L.v.IsOnTrack && typeof UI !== 'undefined' && UI.live());
  },

  frame() {
    this.running = !!(this.on && this.driving());
  },

  // The dashboard's shared animation scheduler calls this at no more than 30 fps.
  renderFrame(dt, now) {
    if (!this.on || !this.driving()) { this.running = false; return; }
    now = typeof now === 'number' && isFinite(now) ? now : performance.now();
    if (now - this.lastRenderAt < 34) return;
    this.lastRenderAt = now;
    this.running = true; this.frames++;
    if (dt > 0) this.air += dt * 1000;
    try { this.draw(dt); } catch (e) { console.error(e); }
  },

  meIdx() {
    return typeof focusIdx === 'function' ? focusIdx() : S.me;
  },

  pose(pct) {
    const p = TrackMap.at(pct), q = TrackMap.at(pct + 0.0015);
    let fx = q[0] - p[0], fz = q[1] - p[1];
    const len = Math.hypot(fx, fz) || 1;
    return { x: p[0], y: this.groundY, z: p[1], fx: fx / len, fz: fz / len };
  },

  lerpPct(a, b, k) {
    let d = b - a;
    if (d > 0.5) d -= 1;
    if (d < -0.5) d += 1;
    let n = a + d * k;
    return ((n % 1) + 1) % 1;
  },

  posOf(d) {
    const p = S.multiClass ? arr('CarIdxClassPosition', d.idx) : arr('CarIdxPosition', d.idx);
    return p > 0 ? p : 0;
  },

  cars(k) {
    const out = [];
    const list = racers();
    const me = this.meIdx();
    for (let i = 0; i < list.length; i++) {
      const d = list[i];
      const pct = arr('CarIdxLapDistPct', d.idx);
      if (!isNum(pct) || pct < 0) continue;
      if (arr('CarIdxTrackSurface', d.idx) === -1) continue;
      let shown = this.shown[d.idx];
      if (!isNum(shown)) shown = pct;
      else shown = this.lerpPct(shown, pct, k);
      this.shown[d.idx] = shown;
      const w = this.pose(shown);
      const mine = d.idx === me;
      out.push({
        idx: d.idx, d: d, pct: shown, x: w.x, y: this.groundY, z: w.z, fx: w.fx, fz: w.fz,
        me: mine, pit: !!arr('CarIdxOnPitRoad', d.idx),
        color: mine ? '#f2c230' : (d.color || '#c7cfd8'),
        pos: this.posOf(d),
      });
    }
    return out;
  },

  byIdx(cars, idx) {
    for (let i = 0; i < cars.length; i++) if (cars[i].idx === idx) return cars[i];
    return null;
  },

  pickBattle(cars) {
    let bestA = null, bestB = null, best = 1, myD = 1, myB = null;
    const me = this.meIdx();
    for (let i = 0; i < cars.length; i++) {
      for (let j = i + 1; j < cars.length; j++) {
        let d = Math.abs(cars[i].pct - cars[j].pct);
        if (d > 0.5) d = 1 - d;
        if (d < best) { best = d; bestA = cars[i]; bestB = cars[j]; }
        if ((cars[i].idx === me || cars[j].idx === me) && d < myD) {
          myD = d;
          myB = cars[i].idx === me ? cars[j] : cars[i];
        }
      }
    }
    if (myB && (myD <= best * 1.35 + 1e-9 || myD < 0.035)) return [me, myB.idx];
    if (!bestA) return null;
    return [bestA.idx, bestB.idx];
  },

  leader(cars) {
    const me = this.byIdx(cars, this.meIdx());
    const cls = me ? me.d.classId : null;
    let best = null;
    for (let i = 0; i < cars.length; i++) {
      const c = cars[i];
      if (S.multiClass && c.d.classId !== cls) continue;
      if (!(c.pos > 0)) continue;
      if (!best || c.pos < best.pos) best = c;
    }
    return best || me || cars[0] || null;
  },

  trackCam(w, h) {
    const key = (TrackMap.key || '') + ':' + TrackMap.pts.length + ':' + Math.round(w) + 'x' + Math.round(h);
    if (this._tcam && this._tcam.key === key) return this._tcam;
    const pts = TrackMap.pts;
    let x0 = 1e15, x1 = -1e15, z0 = 1e15, z1 = -1e15;
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i];
      if (p[0] < x0) x0 = p[0]; if (p[0] > x1) x1 = p[0];
      if (p[1] < z0) z0 = p[1]; if (p[1] > z1) z1 = p[1];
    }
    const cx = (x0 + x1) / 2, cz = (z0 + z1) / 2;
    const spanX = Math.max(20, x1 - x0), spanZ = Math.max(20, z1 - z0);
    const radius = 0.5 * Math.hypot(spanX, spanZ);
    const fovY = 0.66;
    const aspect = Math.max(0.4, w / Math.max(1, h));
    const fovX = 2 * Math.atan(Math.tan(fovY / 2) * aspect);
    const dist = (radius / Math.sin(Math.min(fovX, fovY) / 2)) * 1.28;
    this._tcam = {
      key: key, fov: fovY,
      eye: { x: cx + dist * 0.22, y: dist * 0.62, z: cz + dist * 0.42 },
      look: { x: cx, y: this.groundY, z: cz },
    };
    return this._tcam;
  },

  chaseOf(car, back, up, ahead, fov) {
    return {
      fov: fov,
      eye: { x: car.x - car.fx * back, y: up, z: car.z - car.fz * back },
      look: { x: car.x + car.fx * ahead, y: this.groundY, z: car.z + car.fz * ahead },
    };
  },

  aim(name, cars, w, h) {
    const me = this.byIdx(cars, this.meIdx()) || cars[0];
    if (!me) return { fov: 0.9, eye: { x: 0, y: 40, z: 40 }, look: { x: 0, y: 0, z: 0 } };
    if (name === 'TRACK') return this.trackCam(w, h);
    if (name === 'CHASE') return this.chaseOf(me, 14, 4.6, 12, 0.85);
    if (name === 'LEADER') {
      const lead = this.leader(cars) || me;
      return this.chaseOf(lead, 16, 5.2, 14, 0.82);
    }
    if (name === 'BATTLE') {
      const pair = this.battle;
      const a = pair ? this.byIdx(cars, pair[0]) : null;
      const b = pair ? this.byIdx(cars, pair[1]) : null;
      if (a && b) {
        const mx = (a.x + b.x) / 2, mz = (a.z + b.z) / 2;
        let dx = b.x - a.x, dz = b.z - a.z;
        const len = Math.hypot(dx, dz) || 1;
        const sx = dz / len, sz = -dx / len;
        return {
          fov: 0.74,
          eye: { x: mx + sx * 36, y: 16, z: mz + sz * 36 },
          look: { x: mx, y: this.groundY, z: mz },
        };
      }
    }
    const ang = this.air / 1000 * 0.18;
    const bx = -me.fx * Math.cos(ang) + me.fz * Math.sin(ang);
    const bz = -me.fz * Math.cos(ang) - me.fx * Math.sin(ang);
    return {
      fov: 0.95,
      eye: { x: me.x + bx * 54, y: 34, z: me.z + bz * 54 },
      look: { x: me.x + me.fx * 16, y: this.groundY, z: me.z + me.fz * 16 },
    };
  },

  direct(dt, cars, w, h) {
    let cycle = 0;
    for (let i = 0; i < this.shots.length; i++) cycle += this.shots[i].secs * 1000;
    let t = cycle > 0 ? (this.air % cycle) : 0;
    let shot = this.shots[0];
    for (let i = 0; i < this.shots.length; i++) {
      const ms = this.shots[i].secs * 1000;
      if (t < ms) { shot = this.shots[i]; break; }
      t -= ms;
    }
    const changed = !this.shot || this.shot.name !== shot.name;
    if (changed) {
      if (shot.name === 'BATTLE') this.battle = this.pickBattle(cars);
      else this.battle = null;
      this.cutAt = this.air;
    }
    const cam = this.aim(shot.name, cars, w, h);
    this.eyeGap = this.haveCam ? this.dist(this.eye, cam.eye) : 0;
    if (changed && this.haveCam) this.cutGap = this.eyeGap;
    if (changed) this.shot = shot;
    const since = (this.air - this.cutAt) / 1000;
    const tau = since < 1.15 ? 0.42 : 0.10;
    if (!this.haveCam || dt <= 0) {
      this.eye = { x: cam.eye.x, y: cam.eye.y, z: cam.eye.z };
      this.look = { x: cam.look.x, y: cam.look.y, z: cam.look.z };
      this.fov = cam.fov;
      this.haveCam = true;
    } else {
      const k = 1 - Math.exp(-dt / tau);
      this.eye = this.mix(this.eye, cam.eye, k);
      this.look = this.mix(this.look, cam.look, k);
      this.fov = this.fov + (cam.fov - this.fov) * k;
    }
  },

  mix(a, b, k) {
    return { x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, z: a.z + (b.z - a.z) * k };
  },

  dist(a, b) {
    return Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
  },

  // right = (fz, 0, -fx), which is world-up crossed with forward. Screen Y grows downward,
  // so a point above the look target (positive camera-up) gets a smaller screen Y.
  project(eye, look, fov, w, h, p) {
    let fx = look.x - eye.x, fy = look.y - eye.y, fz = look.z - eye.z;
    const fl = Math.hypot(fx, fy, fz) || 1;
    fx /= fl; fy /= fl; fz /= fl;
    let rx = fz, ry = 0, rz = -fx;
    const rl = Math.hypot(rx, rz) || 1;
    rx /= rl; rz /= rl;
    let ux = fy * rz, uy = fz * rx - fx * rz, uz = -fy * rx;
    const ul = Math.hypot(ux, uy, uz) || 1;
    ux /= ul; uy /= ul; uz /= ul;
    const vx = p.x - eye.x, vy = p.y - eye.y, vz = p.z - eye.z;
    const cz = vx * fx + vy * fy + vz * fz;
    if (cz < 0.8) return null;
    const cx = vx * rx + vy * ry + vz * rz;
    const cy = vx * ux + vy * uy + vz * uz;
    const focal = (h / 2) / Math.tan(fov / 2);
    return { x: w / 2 + (cx / cz) * focal, y: h / 2 - (cy / cz) * focal, z: cz };
  },

  // the camera fills Drive's map slot (#dMap, 1108 x 620); its CSS sizes it, the canvas only matches the pixels
  place() {
    const box = $('dMap'), hero = $('tvHero');
    if (!box || !hero) return false;
    const w = box.clientWidth, h = box.clientHeight;
    this.fitCanvas(hero, w, h);
    this.heroW = w; this.heroH = h;
    return w > 20 && h > 20;
  },

  fitCanvas(cv, w, h) {
    const dpr = window.devicePixelRatio || 1;
    const W = Math.max(1, Math.round(w * dpr)), H = Math.max(1, Math.round(h * dpr));
    if (cv.width !== W || cv.height !== H) { cv.width = W; cv.height = H; }
    cv._dpr = dpr;
  },

  road() {
    if (!TrackMap.pts || TrackMap.pts.length < 50) return null;
    const key = (TrackMap.key || '') + ':' + TrackMap.pts.length + ':' + (TrackMap.pit ? TrackMap.pit.length : 0);
    if (this._road && this._road.key === key) return this._road;
    const N = 180;
    const c = new Array(N), al = new Array(N), ar = new Array(N), el = new Array(N), er = new Array(N);
    for (let i = 0; i < N; i++) {
      const p = this.pose(i / N);
      const rx = p.fz, rz = -p.fx;
      c[i] = p;
      al[i] = { x: p.x - rx * 5.4, y: 0, z: p.z - rz * 5.4 };
      ar[i] = { x: p.x + rx * 5.4, y: 0, z: p.z + rz * 5.4 };
      el[i] = { x: p.x - rx * 7.2, y: 0, z: p.z - rz * 7.2 };
      er[i] = { x: p.x + rx * 7.2, y: 0, z: p.z + rz * 7.2 };
    }
    this._road = { key: key, N: N, c: c, al: al, ar: ar, el: el, er: er };
    return this._road;
  },

  fillQuad(ctx, project, a, b, c, d, color) {
    const A = project(a), B = project(b), C = project(c), D = project(d);
    if (!A || !B || !C || !D) return;
    ctx.beginPath();
    ctx.moveTo(A.x, A.y); ctx.lineTo(B.x, B.y); ctx.lineTo(C.x, C.y); ctx.lineTo(D.x, D.y);
    ctx.closePath();
    ctx.fillStyle = color;
    ctx.fill();
  },

  drawRoad(ctx, project) {
    const road = this.road();
    if (!road) return;
    const N = road.N;
    const center = new Array(N);
    let widthSum = 0, widthN = 0;
    let minx = 1e15, maxx = -1e15, miny = 1e15, maxy = -1e15;
    for (let i = 0; i < N; i++) {
      const p = project(road.c[i]);
      center[i] = p;
      if (p) {
        if (p.x < minx) minx = p.x; if (p.x > maxx) maxx = p.x;
        if (p.y < miny) miny = p.y; if (p.y > maxy) maxy = p.y;
      }
      if (i % 8 === 0) {
        const edge = project(road.er[i]);
        if (p && edge) { widthSum += Math.hypot(edge.x - p.x, edge.y - p.y); widthN++; }
      }
    }
    // A whole-track camera sits about a kilometre up, so an 11 m road is one pixel and
    // only the corner numbers show. Stroke the real outline in screen pixels then.
    // Close cameras (the ribbon is several pixels wide) keep the true-width road.
    if (widthN > 0 && widthSum / widthN < 4) {
      const span = Math.max(1, Math.min(maxx - minx, maxy - miny));
      const sc = Math.max(0.7, Math.min(1.2, span / 200));
      const stroke = (color, width) => {
        ctx.beginPath();
        let started = false;
        for (let i = 0; i < N; i++) {
          const q = center[i];
          if (!q) { started = false; continue; }
          if (!started) { ctx.moveTo(q.x, q.y); started = true; }
          else ctx.lineTo(q.x, q.y);
        }
        ctx.closePath();
        ctx.strokeStyle = color;
        ctx.lineJoin = 'round';
        ctx.lineCap = 'round';
        ctx.lineWidth = width;
        ctx.stroke();
      };
      stroke('#07090c', 22 * sc);
      stroke('#d3d8de', 13 * sc);
      stroke('#232a32', 9 * sc);
      const a = center[0], b = center[2];
      if (a && b) {
        const dx = b.x - a.x, dy = b.y - a.y, len = Math.hypot(dx, dy) || 1;
        const nx = -dy / len * 11 * sc, ny = dx / len * 11 * sc;
        ctx.beginPath();
        ctx.moveTo(a.x - nx, a.y - ny);
        ctx.lineTo(a.x + nx, a.y + ny);
        ctx.strokeStyle = '#f4f1ea';
        ctx.lineWidth = Math.max(2, 3 * sc);
        ctx.stroke();
      }
    } else {
      const depth = new Array(N);
      let far = 1;
      for (let i = 0; i < N; i++) {
        depth[i] = center[i] ? center[i].z : 0;
        if (depth[i] > far) far = depth[i];
      }
      const order = [];
      for (let i = 0; i < N; i++) order.push(i);
      order.sort((a, b) => depth[b] - depth[a]);
      for (let n = 0; n < N; n++) {
        const i = order[n], j = (i + 1) % N;
        const t = Math.max(0, Math.min(1, depth[i] / far));
        const edge = t > 0.72 ? '#12161c' : '#1c222b';
        const asphalt = t > 0.72 ? '#232830' : '#2e353f';
        this.fillQuad(ctx, project, road.el[i], road.er[i], road.er[j], road.el[j], edge);
        this.fillQuad(ctx, project, road.al[i], road.ar[i], road.ar[j], road.al[j], asphalt);
      }
      this.fillQuad(ctx, project, road.el[0], road.er[0], road.er[1], road.el[1], '#f4f1ea');
    }
    const pit = TrackMap.pit;
    if (pit && pit.length > 1) {
      ctx.beginPath();
      let started = false;
      for (let i = 0; i < pit.length; i++) {
        const p = project({ x: pit[i][0], y: 0, z: pit[i][1] });
        if (!p) { started = false; continue; }
        if (!started) { ctx.moveTo(p.x, p.y); started = true; }
        else ctx.lineTo(p.x, p.y);
      }
      ctx.strokeStyle = '#4a5563';
      ctx.lineWidth = 2;
      ctx.stroke();
    }
  },

  drawCorners(ctx, project, w, h) {
    if (typeof Corners === 'undefined') return;
    const data = typeof TrackInfo !== 'undefined' && TrackInfo.raw ? TrackInfo.raw : NO_CORNERS;
    // Corners.draw owns the shared ticks, pit marks and labels; hide points behind this camera.
    const screen = pct => {
      const w = this.pose(pct), p = project({ x: w.x, y: 0, z: w.z });
      return p ? [p.x, p.y] : [-1000000, -1000000];
    };
    Corners.draw(ctx, screen, { data: data, w: w, h: h, names: false, ticks: true, pit: true, credit: true });
  },

  drawCars(ctx, project, cars, tags, w, h) {
    const drawn = [];
    const order = cars.slice().sort((a, b) => {
      const pa = project(a), pb = project(b);
      return (pb ? pb.z : 0) - (pa ? pa.z : 0);
    });
    for (let i = 0; i < order.length; i++) {
      const c = order[i];
      const rx = c.fz, rz = -c.fx;
      const nose = { x: c.x + c.fx * 2.3, y: 0, z: c.z + c.fz * 2.3 };
      const l = { x: c.x - c.fx * 1.6 - rx * 1.25, y: 0, z: c.z - c.fz * 1.6 - rz * 1.25 };
      const r = { x: c.x - c.fx * 1.6 + rx * 1.25, y: 0, z: c.z - c.fz * 1.6 + rz * 1.25 };
      const N = project(nose), L = project(l), R = project(r), P = project(c);
      if (!P) continue;
      drawn.push({ idx: c.idx, x: P.x, y: P.y, z: P.z, c: c });
      const len = (N && L) ? Math.hypot(N.x - (L.x + (R ? R.x : L.x)) / 2, N.y - (L.y + (R ? R.y : L.y)) / 2) : 0;
      ctx.globalAlpha = c.pit && !c.me ? 0.4 : 1;
      if (!N || !L || !R || len < 8) {
        ctx.beginPath();
        ctx.arc(P.x, P.y, 4, 0, Math.PI * 2);
        ctx.fillStyle = c.color;
        ctx.fill();
      } else {
        ctx.beginPath();
        ctx.moveTo(N.x, N.y); ctx.lineTo(R.x, R.y); ctx.lineTo(L.x, L.y);
        ctx.closePath();
        ctx.fillStyle = c.color;
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    }
    if (tags) this.drawTags(ctx, drawn, w, h);
    return drawn.map(d => ({ idx: d.idx, x: d.x, y: d.y }));
  },

  tagName(n) {
    n = (n || '').trim();
    if (n.length <= 18) return n;
    const p = n.split(/\s+/);
    return p[p.length - 1] || n;
  },

  gapOf(me, c) {
    const lapT = refLapTime(me.idx);
    let dp = c.pct - me.pct;
    if (dp > 0.5) dp -= 1;
    else if (dp < -0.5) dp += 1;
    return dp * lapT;
  },

  gapText(g) {
    const a = Math.abs(g);
    if (a < 0.05) return '0.0';
    const t = a >= 10 ? a.toFixed(0) : a.toFixed(1);
    return (g > 0 ? '+' : '-') + t;
  },

  drawTags(ctx, drawn, w, h) {
    const me = this.byIdx(drawn.map(d => d.c), this.meIdx());
    const near = drawn.slice().sort((a, b) => a.z - b.z);
    const show = [];
    // His name stays on screen even when seven other cars are closer to the camera.
    if (me) for (let i = 0; i < near.length; i++) if (near[i].c === me) { show.push(near[i]); break; }
    for (let i = 0; i < near.length && show.length < 7; i++) {
      if (me && near[i].c === me) continue;
      show.push(near[i]);
    }
    ctx.textAlign = 'center';
    ctx.textBaseline = 'bottom';
    ctx.font = '600 20px Bahnschrift, "Segoe UI", sans-serif';
    for (let i = 0; i < show.length; i++) {
      const d = show[i];
      if (d.x < 8 || d.x > w - 8 || d.y < 16 || d.y > h - 8) continue;
      let text = this.tagName(d.c.d.name);
      if (me && d.c.idx !== me.idx) text += '  ' + this.gapText(this.gapOf(me, d.c));
      ctx.fillStyle = 'rgba(6,7,9,.72)';
      const tw = ctx.measureText(text).width;
      ctx.fillRect(d.x - tw / 2 - 6, d.y - 38, tw + 12, 26);
      ctx.fillStyle = d.c.me ? '#f2c230' : '#f4f1ea';
      ctx.fillText(text, d.x, d.y - 15);
    }
  },

  paint(ctx, w, h, eye, look, fov, opt) {
    const dpr = ctx.canvas._dpr || 1;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const sky = ctx.createLinearGradient(0, 0, 0, h);
    sky.addColorStop(0, '#12161d');
    sky.addColorStop(0.55, '#0c0e13');
    sky.addColorStop(1, '#07080b');
    ctx.fillStyle = sky;
    ctx.fillRect(0, 0, w, h);
    const project = (p) => this.project(eye, look, fov, opt.viewW || w, opt.viewH || h, p);
    if (opt.clip) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(0, 0, opt.viewW, h);
      ctx.clip();
    }
    this.drawRoad(ctx, project);
    if (opt.corners) this.drawCorners(ctx, project, opt.viewW || w, opt.viewH || h);
    const dots = this.drawCars(ctx, project, opt.cars, !!opt.tags, opt.viewW || w, h);
    if (opt.clip) ctx.restore();
    ctx.fillStyle = '#f2c230';
    ctx.fillRect(0, 0, w, 2);
    return dots;
  },

  draw(dt) {
    if (!this.place()) return;
    const hero = $('tvHero').getContext('2d');
    // no outline yet: the same one status line as the map, no invented car positions
    if (!TrackMap.pts || TrackMap.pts.length < 50) { this.drawFieldMap(hero, Tower.data, this.heroW, this.heroH); return; }
    const k = dt > 0 ? (1 - Math.exp(-dt / 0.08)) : 1;
    let cars;
    try { cars = this.cars(k); } catch (e) { return; }
    if (!cars.length) return;
    this.direct(dt, cars, this.heroW, this.heroH);
    // corner names stay off the camera: Corners.draw paints numbered discs, which Drive's map rules do not allow
    this.dots = this.paint(hero, this.heroW, this.heroH, this.eye, this.look, this.fov, {
      cars: cars, tags: true, corners: false, viewW: this.heroW, viewH: this.heroH,
    });
  },

  // The TV map uses the same sampled response as the tower, and the shared GPS-map fit.
  drawFieldMap(ctx, data, w, h) {
    const dpr = window.devicePixelRatio || 1;
    const cv = ctx.canvas;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, cv.width, cv.height);
    ctx.fillStyle = '#07080b'; ctx.fillRect(0, 0, cv.width, cv.height);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const hasOutline = TrackMap.pts && TrackMap.pts.length >= 200 &&
      (TrackMap.source === 'gps' || TrackMap.source === 'ibt' || TrackMap.source === 'library');
    if (hasOutline) {
      if (!TrackMap.layer || TrackMap.layer.width !== Math.round(w * dpr) || TrackMap.layer.height !== Math.round(h * dpr) || TrackMap.layerKey !== 'tv:' + w + ':' + h + ':' + TrackMap.source) {
        TrackMap.buildLayer(w, h, dpr);
        TrackMap.layerKey = 'tv:' + w + ':' + h + ':' + TrackMap.source;
      }
      ctx.drawImage(TrackMap.layer, 0, 0, cv.width, cv.height, 0, 0, w, h);
    } else {
      // no outline yet: say so, and draw no cars - a straight bar put them where they are not; the tower has the order
      ctx.fillStyle = '#8f9aa7'; ctx.font = '26px Bahnschrift, "Segoe UI", sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText(TrackMap.status || 'Loading track map', w / 2, h / 2);
      return;
    }
    if (!data || !Array.isArray(data.cars)) return;
    const place = c => TrackMap.toScreen(TrackMap.at(c.pct), TrackMap.fit(w, h));
    const battles = Array.isArray(data.battles) ? data.battles : [];
    for (const c of data.cars) {
      if (!c || typeof c.pct !== 'number' || !isFinite(c.pct) || c.pct < 0 || c.pct > 1) continue;
      if (typeof c.idx !== 'number' || !isFinite(c.idx)) continue;
      const p = place(c), mine = c.idx === data.playerIdx;
      const color = mine ? '#f2c230' : (/^[0-9a-f]{6}$/i.test(c.classColor || '') ? '#' + c.classColor : '#c7cfd8');
      const leader = c.pos === 1;
      const battle = battles.some(b => b && (b.a === c.idx || b.b === c.idx));
      ctx.beginPath(); ctx.arc(p[0], p[1], mine ? 7 : 5, 0, Math.PI * 2);
      ctx.fillStyle = color; ctx.fill();
      if (mine || leader || battle) {
        ctx.beginPath(); ctx.arc(p[0], p[1], mine ? 10 : 8, 0, Math.PI * 2);
        ctx.lineWidth = mine ? 2 : 1.5; ctx.strokeStyle = mine ? '#f2c230' : (battle ? '#f4f1ea' : '#c7cfd8'); ctx.stroke();
      }
      if (mine && c.num) { ctx.fillStyle = '#f2c230'; ctx.font = '600 20px Bahnschrift, "Segoe UI", sans-serif'; ctx.textAlign = 'left'; ctx.textBaseline = 'middle'; ctx.fillText('#' + c.num, p[0] + 14, p[1]); }
    }
  },
};

// /tv/data is irdash's frozen snapshot (director label, the no-outline status map). Drive v1 builds its own 7-row battle
// tower from the frames in the page; this object keeps the snapshot and the truthful REC pill.
const Tower = {
  data: null,
  timer: 0,
  busy: false,
  recAt: 0,
  recBusy: false,

  start() { this.lastTick = 0; },
  tick() {
    if (!Tv.on) { this.data = null; return; }
    this.recorder();
    if (this.busy) return;
    this.busy = true;
    fetch('/tv/data', { cache: 'no-store' }).then(r => r.json()).then(d => {
      this.data = d;
      const label = $('tvCam'); if (label && d && d.director) label.textContent = d.director;
    }).catch(() => { this.data = null; const label = $('tvCam'); if (label) label.textContent = 'LEADER'; }).then(() => { this.busy = false; });
  },
  recorder() {
    const now = Date.now(); if (this.recBusy || now - this.recAt < 2000) return;
    this.recBusy = true; this.recAt = now;
    fetch('/vault/recorder', { cache: 'no-store' }).then(r => r.json()).then(d => this.showRec(d))
      .catch(() => this.showRec(null)).then(() => { this.recBusy = false; });
  },
  // irdash's one verdict (recorder.cs CaptureJson): REC only while video is really landing on disk. null = irdash did not answer.
  showRec(d) {
    const el = $('dRec'); if (!el) return;
    const c = d && d.capture, st = c && c.state;
    const mmss = s => { s = Math.max(0, Math.round(s || 0)); const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60; return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(x).padStart(2, '0'); };
    const words = { recording: 'REC ' + mmss(c && c.secs), starting: 'REC STARTING', 'paused-disk': 'REC PAUSED: DISK FULL', stalled: 'NOT RECORDING', failed: 'NOT RECORDING' };
    const text = d ? words[st] || '' : 'RECORDING UNKNOWN';
    el.hidden = !text;
    el.querySelector('span').textContent = text;
    el.className = !text ? '' : !d ? 'warn' : st === 'recording' ? '' : st === 'stalled' || st === 'failed' ? 'bad' : 'warn';
  },
  fmtTime(n) {
    if (typeof n !== 'number' || !isFinite(n) || n <= 0) return '–';
    const m = Math.floor(n / 60), s = (n - m * 60).toFixed(1);
    return m + ':' + (s < 10 ? '0' : '') + s;
  },
};

window.Tv = Tv;
window.Tower = Tower;
Tv.init();
