// HOME's states for tests\home-test.ps1: each one changes a fresh copy of the fixtures (official, library, home, state, online).
window.__setups = {
  'rig-off': fx => { fx.state.health.apps.find(a => a.id === 'ui').state = 'off'; },
  'rig-on-idle': fx => { },
  'race-soon': fx => {                                  // the GR Cup starts in 12:34: the ring and the large countdown
    const t = new Date(window.__now + 754000).toISOString().replace('.000Z', 'Z');
    fx.official.next.t = t; fx.official.days[0].rows.forEach(r => { if (r.id === fx.official.next.id) r.t = t; });
  },
  'session-garage': fx => {                             // a session is loaded, he is in the garage: NOW and DRIVE
    fx.state.rig.sessionOn = true; fx.state.rig.simRunning = true;
    fx.state.health.apps.find(a => a.id === 'sim').state = 'live';
    fx.state.session = { ver: 3, WeekendInfo: { TrackName: 'roadatlanta full', TrackDisplayName: 'Road Atlanta', EventType: 'Race' },
      DriverInfo: { DriverCarIdx: '4', Drivers: [{ CarIdx: '0', UserName: 'Pace Car', CarScreenName: 'Safety Car' }, { CarIdx: '4', UserName: 'Peter', CarScreenName: 'Toyota GR86' }] } };
  },
  'offline': fx => { fx.online = false; },
  'kids': fx => { fx.state.kids = { on: true, text: 'KIDS MODE - keyboard and deck locked - to unlock press KIDS, then HOME' }; },
  'after-drive': fx => {                                // a race that ended five minutes ago: P3 from P9
    fx.library.races.unshift({ id: '20261114-1130-road-atlanta', track: 'Road Atlanta', config: 'Full Course', car: 'Toyota GR86', type: 'Race', isRace: true,
      startMs: window.__now - 1800000, sec: 1500, laps: 12, counted: 11, best: 93.512, bestLap: 8, mb: 1100, kept: true, start: 9, finish: 3, field: 19,
      thumb: false, state: { kind: 'none' }, markers: [] });
  },
  'after-practice': fx => {
    fx.library.races.unshift({ id: '20261114-1130-practice', track: 'Road Atlanta', config: 'Full Course', car: 'Toyota GR86', type: 'Practice', isRace: false,
      startMs: window.__now - 1800000, sec: 1500, laps: 14, counted: 12, best: 93.8, bestLap: 8, mb: 900, kept: false, start: 0, finish: 0, field: 0,
      thumb: false, state: { kind: 'none' }, markers: [] });
  },
  'rig-problem': fx => {                                // the doctor found something only a fix can mend: one sentence and FIX IT
    fx.state.health.apps.find(a => a.id === 'overlays').state = 'off';
    fx.state.doctor.items.push({ id: 'overlays_running', name: 'Overlays running', state: 'bad', detail: 'Overlays app not running: no overlays on the race screens', fix: 'Press OVERLAYS on the deck', done: '', ask: '' });
    fx.state.doctor.items = fx.state.doctor.items.filter(i => !(i.id === 'overlays_running' && i.state === 'ok'));
  }
};
