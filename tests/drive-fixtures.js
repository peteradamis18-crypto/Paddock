// Drive v1 fixtures for tests\drive-v1-test.ps1: real session YAML and telemetry frames for each design state
// (docs\design\drive-v1\spec.md). Road Atlanta, Peter #64. Loaded into the page by the test, never by the dashboard.
const DriveFix = (() => {
  const NAMES = ['Marco Rossi', 'Jonas Keller', 'Sam Okafor', 'Lena Brandt', 'Tom Hughes', 'Ana Ruiz', 'Kai Tanaka', 'Ben Carter', 'Iris Novak', 'Luca Bianchi', 'Noah Dubois', 'Eva Lindqvist', 'Omar Haddad', 'Mia Schultz', 'Ravi Patel', 'Zoe Martin', 'Felix Wagner', 'Nina Kowalski', 'Hugo Laurent', 'Aiden Murphy', 'Sofia Greco', 'Jack Turner', 'Elena Petrova'];
  const NUMS = ['17', '3', '88', '21', '9', '55', '12', '71', '5', '44', '30', '2', '66', '19', '8', '27', '14', '91', '33', '6', '77', '40', '11'];
  const CLS = { GTP: { id: 4029, name: 'GTP', color: '0xff5888', est: 72 }, LMP2: { id: 2523, name: 'LMP2', color: '0x33ceff', est: 77.5 }, GT3: { id: 4083, name: 'GT3', color: '0xae6bff', est: 85.1 } };

  function arrays() { const a = {}; for (const k of ['CarIdxLapDistPct', 'CarIdxPosition', 'CarIdxClassPosition', 'CarIdxOnPitRoad', 'CarIdxTrackSurface', 'CarIdxF2Time', 'CarIdxLapCompleted', 'CarIdxLap', 'CarIdxBestLapTime', 'CarIdxLastLapTime', 'CarIdxEstTime']) a[k] = new Array(64).fill(k === 'CarIdxTrackSurface' ? -1 : k === 'CarIdxOnPitRoad' ? false : -1); return a; }

  function yaml(cars, type, laps, meIdx) {
    const y = ['---', 'WeekendInfo:', ' TrackName: roadatlanta full', ' TrackID: 127', ' TrackDisplayName: Road Atlanta', ' TrackConfigName: Full Course',
      ' TrackLength: 4.09 km', ' TrackPitSpeedLimit: 72.42 kph', ' WeekendOptions:', '  IncidentLimit: 17', 'SessionInfo:', ' Sessions:',
      ' - SessionNum: 0', '   SessionLaps: ' + laps, '   SessionTime: ' + (laps === 'unlimited' ? '3600.0000 sec' : 'unlimited'), '   SessionType: ' + type, '   SessionName: ' + type.toUpperCase(),
      'DriverInfo:', ' DriverCarIdx: ' + meIdx, ' DriverCarFuelMaxLtr: 104.000', ' DriverCarMaxFuelPct: 1.000', ' Drivers:'];
    for (const c of cars) y.push(' - CarIdx: ' + c.idx, '   UserName: ' + c.name, '   CarNumber: "' + c.num + '"', '   CarClassID: ' + c.cls.id, '   CarClassShortName: ' + c.cls.name,
      '   CarClassColor: ' + c.cls.color, '   CarClassEstLapTime: ' + c.cls.est, '   CarScreenNameShort: Car', '   IsSpectator: 0', '   CarIsPaceCar: 0');
    y.push('SplitTimeInfo:', ' Sectors:', ' - SectorNum: 0', '   SectorStartPct: 0.000000', '...');
    return y.join('\n');
  }

  function practiceCars() {
    const bests = [84.311, 84.522, 84.700, 84.902, 85.020, 85.144, 85.390, 85.611, 85.804, 86.112, 86.400, 86.902, 87.300, 87.811, 88.420, null, null, null];
    const pcts = [0.62, 0.08, 0.31, 0.50, 0.53, 0.47, 0.71, 0.92, 0.18, 0.40, 0.84, 0.26, 0.97, 0.66, 0.12, 0.76, 0.35, 0.02];
    const cars = []; let k = 0;
    for (let i = 0; i < 18; i++) {
      const me = i === 3;
      cars.push({ idx: i + 1, num: me ? '64' : NUMS[k], name: me ? 'Peter Adamis' : NAMES[k++], cls: CLS.GT3, me, best: bests[i], last: bests[i] ? bests[i] + 0.4 + (i % 3) * 0.21 : null,
        pct: pcts[i], pit: i >= 16, pos: bests[i] ? i + 1 : 0, cpos: bests[i] ? i + 1 : 0, f2: -1, lc: 11 });
    }
    return cars;
  }

  function raceCars() {
    const plan = [['GTP', 6], ['LMP2', 5], ['GT3', 12]], cars = [];
    let pos = 0, k = 0, gap = 0;
    for (const [cn, n] of plan) for (let j = 0; j < n; j++) {
      pos++;
      const me = cn === 'GT3' && j === 4;
      gap += cn === 'GT3' ? [0, 2.1, 1.6, 3.0, 1.4, 0.8, 4.2, 2.6, 0.6, 5.0, 3.3, 7.1][j] : 3.1 + j * 0.7;
      cars.push({ idx: pos, num: me ? '64' : NUMS[k % NUMS.length], name: me ? 'Peter Adamis' : NAMES[k++ % NAMES.length], cls: CLS[cn], me, pos, cpos: j + 1, f2: pos === 1 ? 0 : gap,
        best: cn === 'GT3' ? 84.902 + (j - 4) * 0.1 : CLS[cn].est - 0.4, last: CLS[cn].est + (j % 4) * 0.23, pit: false, lc: 8 });
    }
    const me = cars.find(c => c.me);
    for (const c of cars) c.pct = c.cls.name === 'GT3' ? ((0.52 + (me.f2 - c.f2) / 90.4) % 1 + 1) % 1 : ((c.pos * 0.137 + 0.21) % 1);
    return cars;
  }

  function frame(cars, extra) {
    const a = arrays(), me = cars.find(c => c.me);
    for (const c of cars) {
      a.CarIdxLapDistPct[c.idx] = c.pct; a.CarIdxPosition[c.idx] = c.pos; a.CarIdxClassPosition[c.idx] = c.cpos; a.CarIdxOnPitRoad[c.idx] = !!c.pit;
      a.CarIdxTrackSurface[c.idx] = c.pit ? 1 : 3; a.CarIdxF2Time[c.idx] = c.f2; a.CarIdxLapCompleted[c.idx] = c.lc; a.CarIdxLap[c.idx] = c.lc + 1;
      a.CarIdxBestLapTime[c.idx] = c.best || -1; a.CarIdxLastLapTime[c.idx] = c.last || -1; a.CarIdxEstTime[c.idx] = c.pct * 85;
    }
    return Object.assign(a, {
      SessionNum: 0, SessionUniqueID: 7, SessionState: 4, SessionFlags: 0x4, SessionTime: 1500, PlayerCarIdx: me.idx, PlayerCarPosition: me.pos, PlayerCarClassPosition: me.cpos,
      PlayerTrackSurface: 3, IsOnTrack: true, IsOnTrackCar: true, IsReplayPlaying: false, OnPitRoad: false, CamCarIdx: me.idx, DisplayUnits: 0,
      Speed: 52, Gear: 4, RPM: 6800, Throttle: 0.9, Brake: 0, Clutch: 1, FuelLevel: 9.6, FuelLevelPct: 0.09, Lap: me.lc + 1, LapCompleted: me.lc, LapDistPct: me.pct,
      LapCurrentLapTime: 40, LapLastLapTime: me.last || -1, LapBestLapTime: me.best || -1, LapDeltaToBestLap: 0.18, LapDeltaToBestLap_OK: true,
      SessionTimeRemain: 2530, SessionLapsRemainEx: 32767, EngineWarnings: 0,
    }, extra || {});
  }

  const recOn = { enabled: true, capture: { state: 'recording', secs: 2472 } };
  function cleanLaps(per) { return [7, 8, 9].map(n => ({ lap: n, fuel: per, clean: true, time: 85.2, why: '', sectors: [] })); }

  // state -> { yaml, frame, laps, dirty, why, staleMs, rec, gapHist, map }
  function state(name) {
    if (name === 'practice' || name === 'fresh') {
      const cars = practiceCars(), me = cars.find(c => c.me);
      if (name === 'fresh') { me.best = null; me.last = null; me.pos = 0; me.cpos = 0; }
      const f = frame(cars, { LapDeltaToBestLap: -0.27, FuelLevel: 11.8, SessionLapsRemainEx: 32767, Lap: 12, LapCompleted: 11 });
      if (name === 'fresh') Object.assign(f, { LapBestLapTime: -1, LapLastLapTime: -1, LapDeltaToBestLap_OK: false, Lap: 1, LapCompleted: 0 });
      return { yaml: yaml(cars, 'Practice', 'unlimited', me.idx), frame: f, laps: name === 'fresh' ? [] : cleanLaps(1.25), dirty: name === 'fresh', why: name === 'fresh' ? { joined: true } : {}, rec: { enabled: true, capture: { state: 'recording', secs: 1932 } } };
    }
    const cars = raceCars(), me = cars.find(c => c.me), ahead = cars.find(c => c.cls.name === 'GT3' && c.cpos === me.cpos - 1);
    const s = { yaml: yaml(cars, 'Race', '20', me.idx), laps: cleanLaps(1.24), dirty: false, why: {}, rec: recOn,
      gapHist: [{ t: 1500 - 85, idx: ahead.idx, gap: 1.4 + 0.31 }] };
    const extra = { LapDeltaToBestLap: 0.18, FuelLevel: 9.6, SessionLapsRemainEx: 12, Lap: 9, LapCompleted: 8, SessionTimeRemain: 4000 };
    if (name === 'pit') { me.pit = true; me.pct = 0.955; Object.assign(extra, { OnPitRoad: true, PlayerTrackSurface: 2, Speed: 19.3, EngineWarnings: 0x10, LapDistPct: 0.955 }); s.dirty = true; s.why = { tail: true }; }
    if (name === 'stale') s.staleMs = 9000;
    if (name === 'norec') s.rec = { enabled: true, capture: { state: 'failed' } };
    if (name === 'nooutline') s.map = 'none';
    s.frame = frame(cars, extra);
    return s;
  }
  return { state };
})();
