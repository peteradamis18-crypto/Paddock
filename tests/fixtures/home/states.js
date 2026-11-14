// HOME's states for tests\home-test.ps1: each one changes a fresh copy of the fixtures (official, library, home, state, online),
// the pretend clock (window.__now) and what HOME remembers in sessionStorage (as the page would after a reload).
// /official is made by irdash's own code (official-unit homefx, 14 Nov 12:30 UTC): his series are the Porsche Cup (14:00) and the GR Cup
// (14:15); the Mazda Cup (13:10) is a car he has driven but not his series and must never show.
const seedMem = o => { try { sessionStorage.setItem('paddock.home', JSON.stringify(Object.assign({ seen: true, driving: false, driveEnd: 0, newestId: '', newestAt: 0, sessionOn: false, sessionSince: 0 }, o))); } catch (e) { } };
const nextT = fx => Date.parse(fx.official.next.t);
window.__setups = {
  'rig-off': fx => { fx.state.health.apps.find(a => a.id === 'ui').state = 'off'; },
  'rig-on-idle': fx => { },
  'race-soon': fx => { window.__now = nextT(fx) - 754000; },            // the Porsche Cup starts in 12:34: the ring
  'session-garage': fx => {                             // a GR Cup session loaded at 14:00, he is in the garage at 14:05: NOW and DRIVE
    window.__now = Date.parse('2026-11-14T14:05:00Z');
    fx.state.rig.sessionOn = true; fx.state.rig.simRunning = true;
    fx.state.health.apps.find(a => a.id === 'sim').state = 'live';
    fx.state.session = { ver: 3, WeekendInfo: { TrackName: 'roadatlanta full', TrackDisplayName: 'Road Atlanta', EventType: 'Race' },
      DriverInfo: { DriverCarIdx: '4', Drivers: [{ CarIdx: '0', UserName: 'Pace Car', CarScreenName: 'Safety Car' }, { CarIdx: '4', UserName: 'Peter', CarScreenName: 'Toyota GR86' }] } };
    seedMem({ sessionOn: true, sessionSince: Date.parse('2026-11-14T14:00:00Z') });
  },
  'offline': fx => { fx.online = false; },
  'kids': fx => { fx.state.kids = { on: true, text: 'KIDS MODE - keyboard and deck locked - to unlock press KIDS, then HOME' }; },
  'after-drive': fx => {                                // a race that ended five minutes ago and has just reached the library: P3 from P9
    seedMem({ newestId: fx.library.races[0].id, driveEnd: window.__now - 300000 });
    fx.library.races.unshift({ id: '20261114-1200-road-atlanta', track: 'Road Atlanta', config: 'Full Course', car: 'Toyota GR86', type: 'Race', isRace: true,
      startMs: window.__now - 1800000, sec: 1500, laps: 12, counted: 11, best: 93.512, bestLap: 8, mb: 1100, kept: true, start: 9, finish: 3, field: 19,
      thumb: false, state: { kind: 'none' }, markers: [] });
  },
  'after-practice': fx => {
    seedMem({ newestId: fx.library.races[0].id, driveEnd: window.__now - 300000 });
    fx.library.races.unshift({ id: '20261114-1200-practice', track: 'Road Atlanta', config: 'Full Course', car: 'Toyota GR86', type: 'Practice', isRace: false,
      startMs: window.__now - 1800000, sec: 1500, laps: 14, counted: 12, best: 93.8, bestLap: 8, mb: 900, kept: false, start: 0, finish: 0, field: 0,
      thumb: false, state: { kind: 'none' }, markers: [] });
  },
  'rig-problem': fx => {                                // the doctor found something a fix can mend: one sentence and FIX IT
    fx.state.health.apps.find(a => a.id === 'overlays').state = 'off';
    fx.state.doctor.items = fx.state.doctor.items.filter(i => i.id !== 'overlays_running');
    fx.state.doctor.items.push({ id: 'overlays_running', name: 'Overlays running', state: 'bad', detail: 'Overlays app not running: no overlays on the race screens', fix: 'Press OVERLAYS on the deck', done: '', ask: '' });
  }
};
