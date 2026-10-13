'use strict';
// Demo race: a fake multi-class field on a made-up circuit, producing the same variables and
// session YAML that iRacing does. Open the dashboard with ?demo=1 (add &speed=8 to fast-forward).

const Demo = {
  start() {
    const speed = clamp(num(QS.get('speed')) || 1, 0.25, 20);
    const T = this.track = this.buildTrack();
    const lat0 = 50.4372, lon0 = 5.9714, kx = 111320 * Math.cos(lat0 * Math.PI / 180), ky = 110540;
    const names = ['A. Moreau', 'J. Lindqvist', 'K. Tanaka', 'M. Rossi', 'You', 'L. Okafor', 'D. Novak', 'S. Petrov', 'R. Alvarez',
      'T. Becker', 'C. Dubois', 'E. Walsh', 'H. Kim', 'P. Silva', 'N. Haddad', 'G. Ferrari', 'I. Kowalski', 'B. Nguyen', 'O. Svensson', 'F. Murphy', 'W. Chen'];
    const meIdx = 5;
    const cars = [];
    // idx 0 is the pace car (filtered out like in iRacing)
    for (let i = 1; i <= names.length; i++) {
      const gt3 = i <= 13;
      const f = (gt3 ? 1.0 : 0.925) + (i === meIdx ? 0.004 : (Math.sin(i * 12.9898) * 0.5) * 0.03);
      cars.push({ idx: i, name: names[i - 1], gt3, f, dist: 4.6 - i * 0.012 - (gt3 ? 0 : 0.05), lapStart: 0, last: -1, best: -1, lapsDone: 4 });
    }
    const classLap = { gt3: T.lapTime, gt4: T.lapTime / 0.925 };
    const yaml = this.yaml(T, cars, meIdx, classLap);
    setSession(yaml);

    const me = cars.find(c => c.idx === meIdx);
    let t = 1200, fuel = 58.4, last = -1, best = -1, prevLap = -1, inc = 2;
    let lapStartT = t - T.timeFrac(me.dist % 1) * T.lapTime / me.f;
    const sessLen = 2700, startT = 0;
    const tick = () => {
      const dt = 1 / 30 * speed;
      t += dt;
      for (const c of cars) {
        const pct = c.dist % 1;
        const wob = c.idx === meIdx ? 1 + 0.006 * Math.sin(t / 47) : 1 + 0.004 * Math.sin(t / 31 + c.idx);
        c.v = T.speedAt(pct) * c.f * wob;
        const inPit = c.idx === 16 && Math.floor(c.dist) % 6 === 0 && (pct > 0.96 || pct < 0.05);
        c.pit = inPit;
        const before = Math.floor(c.dist);
        c.dist += (inPit ? Math.min(c.v, 22) : c.v) * dt / T.len;
        if (Math.floor(c.dist) > before) {
          if (c.lapStart) { c.last = t - c.lapStart; if (c.best < 0 || c.last < c.best) c.best = c.last; }
          c.lapStart = t;
        }
      }
      const order = cars.slice().sort((a, b) => b.dist - a.dist);
      const lead = { gt3: null, gt4: null }, cpos = { gt3: 0, gt4: 0 };
      order.forEach((c, k) => {
        c.pos = k + 1; const cl = c.gt3 ? 'gt3' : 'gt4'; c.cpos = ++cpos[cl];
        if (!lead[cl]) lead[cl] = c;
      });
      const N = 64, mk = (fill) => new Array(N).fill(fill);
      const pctA = mk(-1), lapA = mk(-1), lcA = mk(-1), posA = mk(0), cposA = mk(0), pitA = mk(0), surfA = mk(-1), estA = mk(0), f2A = mk(-1), lastA = mk(-1), bestA = mk(-1);
      for (const c of cars) {
        const p = c.dist % 1, i = c.idx, lt = c.gt3 ? classLap.gt3 : classLap.gt4;
        pctA[i] = p; lapA[i] = Math.floor(c.dist) + 1; lcA[i] = Math.floor(c.dist); posA[i] = c.pos; cposA[i] = c.cpos;
        pitA[i] = c.pit ? 1 : 0; surfA[i] = c.pit ? 2 : 3; estA[i] = T.timeFrac(p) * lt;
        f2A[i] = (order[0].dist - c.dist) * lt; lastA[i] = c.last; bestA[i] = c.best;
      }
      // player car
      const pct = me.dist % 1, lap = Math.floor(me.dist);
      if (prevLap >= 0 && lap > prevLap) { last = t - lapStartT; if (best < 0 || last < best) best = last; lapStartT = t; }
      prevLap = lap;
      const v = me.v, a = T.accelAt(pct) * me.f;
      let thr, brk;
      if (a < -2) { brk = clamp(-a / 13, 0.15, 1); thr = 0; }
      else if (a > 0.4 || v > 74) { thr = 1; brk = 0; }
      else { thr = 0.55 + 0.3 * Math.abs(Math.sin(t * 2)); brk = 0; }
      fuel = Math.max(0, fuel - thr * 0.0315 * dt);
      const gears = [0, 17, 27, 37, 47, 57, 66];
      let gear = 1; for (let k = 1; k < gears.length; k++) if (v > gears[k]) gear = k + 1;
      gear = Math.min(gear, 6);
      const lo = gears[gear - 1], hi = gears[gear] || 80;
      const rpm = clamp(4300 + (v - lo) / (hi - lo) * 4100, 3000, 8450);
      const pos = T.posAt(pct);
      const curLap = t - lapStartT;
      const delta = best > 0 ? curLap - best * T.timeFrac(pct) : 0;
      const tire = (base) => base + 6 * Math.sin(t / 60);
      const val = {
        SessionTime: t, SessionNum: 0, SessionUniqueID: 1, SessionState: 4, SessionFlags: 0x4 | (Math.floor(t / 40) % 9 === 0 ? 0x20 : 0),
        SessionTimeRemain: Math.max(0, sessLen - (t - startT)), SessionLapsRemainEx: 32767, SessionTimeOfDay: 50400 + t,
        PlayerCarIdx: meIdx, PlayerCarPosition: me.pos, PlayerCarClassPosition: me.cpos, PlayerCarMyIncidentCount: inc, PlayerTrackSurface: 3,
        IsOnTrack: 1, IsOnTrackCar: 1, IsReplayPlaying: 0, OnPitRoad: 0, CamCarIdx: meIdx, DisplayUnits: 1,
        Speed: v, RPM: rpm, Gear: gear, Throttle: thr, Brake: brk, Clutch: 1, SteeringWheelAngle: clamp(T.curvAt(pct) * 2.7 * 14, -4, 4),
        SteeringWheelAngleMax: 9.42,
        FuelLevel: fuel, FuelLevelPct: fuel / 120, FuelUsePerHour: thr * 0.0315 * 3600 * 0.75,
        Lap: lap + 1, LapCompleted: lap, LapDistPct: pct, LapCurrentLapTime: curLap, LapLastLapTime: last, LapBestLapTime: best,
        LapDeltaToBestLap: delta, LapDeltaToBestLap_OK: best > 0 ? 1 : 0,
        Lat: lat0 + pos[1] / ky, Lon: lon0 + pos[0] / kx,
        WaterTemp: 88 + 3 * thr, OilTemp: 101, OilPress: 4.8, Voltage: 13.9, EngineWarnings: 0,
        AirTemp: 21.5, TrackTempCrew: 33.2, TrackWetness: 1, WindVel: 3.1, WindDir: 1.2,
        dcBrakeBias: 54.5, dcABS: 4, dcTractionControl: 3, dcTractionControl2: 2,
        CarIdxLapDistPct: pctA, CarIdxLap: lapA, CarIdxLapCompleted: lcA, CarIdxPosition: posA, CarIdxClassPosition: cposA,
        CarIdxOnPitRoad: pitA, CarIdxTrackSurface: surfA, CarIdxEstTime: estA, CarIdxF2Time: f2A, CarIdxLastLapTime: lastA, CarIdxBestLapTime: bestA,
      };
      [['LF', 0], ['RF', 4], ['LR', -3], ['RR', 1]].forEach(([c, o]) => {
        val[c + 'tempCL'] = tire(82 + o); val[c + 'tempCM'] = tire(86 + o); val[c + 'tempCR'] = tire(90 + o);
        val[c + 'wearL'] = 0.93 - o * 0.004; val[c + 'wearM'] = 0.91; val[c + 'wearR'] = 0.94; val[c + 'coldPressure'] = 165 + o;
      });
      onFrame(val);
    };
    setInterval(tick, 1000 / 30);
  },

  // A closed circuit built from a few harmonics, resampled by distance, with a speed profile from curvature.
  buildTrack() {
    const M = 2400, raw = [];
    for (let k = 0; k < M; k++) {
      const th = k / M * Math.PI * 2;
      const r = 1 + 0.22 * Math.sin(2 * th + 0.6) + 0.14 * Math.sin(3 * th + 1.9) + 0.07 * Math.sin(5 * th + 0.3);
      raw.push([Math.cos(th) * r * 1150, Math.sin(th) * r * 760]);
    }
    const cum = [0];
    for (let k = 1; k <= M; k++) { const a = raw[k - 1], b = raw[k % M]; cum.push(cum[k - 1] + Math.hypot(b[0] - a[0], b[1] - a[1])); }
    const len = cum[M];
    const P = 2000, pts = [];
    for (let j = 0, k = 0; j < P; j++) {
      const d = j / P * len;
      while (cum[k + 1] < d) k++;
      const t = (d - cum[k]) / (cum[k + 1] - cum[k]), a = raw[k], b = raw[(k + 1) % M];
      pts.push([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]);
    }
    const ds = len / P, curv = [], vmax = [];
    for (let j = 0; j < P; j++) {
      const a = pts[(j - 3 + P) % P], b = pts[j], c = pts[(j + 3) % P];
      const h1 = Math.atan2(b[1] - a[1], b[0] - a[0]), h2 = Math.atan2(c[1] - b[1], c[0] - b[0]);
      let dh = h2 - h1; while (dh > Math.PI) dh -= 2 * Math.PI; while (dh < -Math.PI) dh += 2 * Math.PI;
      const k = dh / (3 * ds); curv.push(k);
      vmax.push(Math.min(76, Math.sqrt(24 / Math.max(Math.abs(k), 1e-5))));
    }
    const v = vmax.slice();
    for (let pass = 0; pass < 3; pass++) {
      for (let j = 1; j < 2 * P; j++) { const i = j % P, p = (j - 1) % P; v[i] = Math.min(v[i], Math.sqrt(v[p] * v[p] + 2 * 6.5 * ds)); }
      for (let j = 2 * P - 2; j >= 0; j--) { const i = j % P, n = (j + 1) % P; v[i] = Math.min(v[i], Math.sqrt(v[n] * v[n] + 2 * 15 * ds)); }
    }
    const tcum = [0];
    for (let j = 0; j < P; j++) tcum.push(tcum[j] + ds / v[j]);
    const lapTime = tcum[P];
    const idx = p => ((p % 1) + 1) % 1 * P;
    const lerp = (A, p) => { const f = idx(p), i = Math.floor(f) % P, t = f - Math.floor(f); return A[i] + (A[(i + 1) % P] - A[i]) * t; };
    return {
      len, lapTime,
      speedAt: p => lerp(v, p),
      curvAt: p => lerp(curv, p),
      accelAt: p => { const i = Math.floor(idx(p)) % P, n = (i + 4) % P; return (v[n] * v[n] - v[i] * v[i]) / (2 * 4 * ds); },
      timeFrac: p => { const f = idx(p), i = Math.floor(f); return (tcum[i] + (tcum[Math.min(i + 1, P)] - tcum[i]) * (f - i)) / lapTime; },
      posAt: p => { const f = idx(p), i = Math.floor(f) % P, t = f - Math.floor(f), a = pts[i], b = pts[(i + 1) % P]; return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]; },
    };
  },

  yaml(T, cars, meIdx, classLap) {
    const L = [];
    L.push('---', 'WeekendInfo:', ' TrackName: demo raceway', ' TrackID: 9999', ' TrackLength: ' + (T.len / 1000).toFixed(2) + ' km',
      ' TrackDisplayName: Demo Raceway', ' TrackConfigName: Grand Prix', ' TrackCity: Nowhere', ' TrackCountry: Demo',
      ' WeekendOptions:', '  NumStarters: ' + cars.length, '  IncidentLimit: 17',
      'SessionInfo:', ' Sessions:', ' - SessionNum: 0', '   SessionLaps: unlimited', '   SessionTime: 2700.0000 sec',
      '   SessionType: Race', '   SessionName: RACE', '   ResultsPositions:', '   ResultsFastestLap:', '   - CarIdx: 255', '     FastestLap: 0', '     FastestTime: -1.0000',
      'DriverInfo:', ' DriverCarIdx: ' + meIdx, ' DriverCarFuelMaxLtr: 120.000', ' DriverCarMaxFuelPct: 1.000',
      ' DriverCarSLFirstRPM: 6800.000', ' DriverCarSLShiftRPM: 7900.000', ' DriverCarSLLastRPM: 8200.000', ' DriverCarSLBlinkRPM: 8350.000',
      ' DriverCarRedLine: 8500.000', ' DriverCarIdleRPM: 1500.000', ' Drivers:',
      ' - CarIdx: 0', '   UserName: Pace Car', '   CarNumber: "0"', '   CarIsPaceCar: 1', '   IsSpectator: 0', '   CarClassID: 11',
      '   CarClassShortName: ', '   CarClassColor: 0xffffff', '   IRating: 0', '   LicString: R 0.00');
    const lic = ['A 3.45', 'B 2.81', 'A 4.02', 'C 3.10', 'B 3.66', 'A 2.95', 'B 1.92', 'A 4.51'];
    const licColors = { A: '0x0153db', B: '0x00c702', C: '0xfeec04' };
    cars.forEach((c, k) => {
      const l = lic[k % lic.length];
      L.push(' - CarIdx: ' + c.idx, '   UserName: ' + c.name, '   CarNumber: "' + (c.idx * 7 % 97 + 2) + '"',
        '   CarScreenNameShort: ' + (c.gt3 ? 'GT3 Evo' : 'GT4 Clubsport'), '   CarClassID: ' + (c.gt3 ? 4074 : 4084),
        '   CarClassShortName: ' + (c.gt3 ? 'GT3' : 'GT4'), '   CarClassColor: ' + (c.gt3 ? '0xffda59' : '0x33ceff'),
        '   CarClassEstLapTime: ' + (c.gt3 ? classLap.gt3 : classLap.gt4).toFixed(4),
        '   IRating: ' + (1400 + Math.round(Math.abs(Math.sin(c.idx * 3.3)) * 3400)), '   LicString: ' + l, '   LicColor: ' + licColors[l[0]],
        '   CarIsPaceCar: 0', '   IsSpectator: 0');
    });
    L.push('SplitTimeInfo:', ' Sectors:', ' - SectorNum: 0', '   SectorStartPct: 0.000000', ' - SectorNum: 1', '   SectorStartPct: 0.320000',
      ' - SectorNum: 2', '   SectorStartPct: 0.680000', '...');
    return L.join('\n');
  },
};
