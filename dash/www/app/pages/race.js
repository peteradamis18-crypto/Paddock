/* THE RACE SCREEN (W2-2, docs/rework/PLAN.md 4.2): the one in-car layout of the top screen (v2/race.html).
   Copied from: irdashies Standings (one list, your row highlighted), F1 live timing (interval first, gap to the leader under
   caution, purple only for a best, no flashing), the pit board (position, laps left, gap ahead and behind, one instruction),
   SDK Live Timing's "you will rejoin here" ghost row and mgyr's pit-window colours.
   Where the numbers come from (nothing is asked for besides the one stream):
     - the stream's race set (data.telemetry('race'), 15 Hz): the order (CarIdxClassPosition), gaps and intervals (CarIdxF2Time,
       CarIdxEstTime, CarIdxLap, CarIdxLapDistPct), who is on pit road (CarIdxOnPitRoad), his lap counter, lap times, the time left;
     - irdash's state push: the "race" part (W2-1: position, laps, incidents, flags, fuel and the pit window, the lap, the units;
       null unless he is driving) and the "session" part (names, numbers, classes and session types, parsed once in irdash).
   F1's no-flicker rule: the screen is drawn 4 times a second at most, and a gap or interval is written only when its tenth changes.
   The flag itself is HOME's (ui.js flags, the same table as the light box and the edge glow); here it is only a 2 s flash.
   W2-5 (Peter, 14 Nov, after his first real race on it: "no map during race, i need one back; missing leaderboard and split time easily
   viewable; fuel is way too much text; need to remove sentences"): C is the track map (lib/map.js) with every car on it from the stream's
   CarIdxLapDistPct and ONE line of fuel numbers; D is the split (iRacing's LapDeltaToBestLap) as the big number. Numbers and single
   words only: no text on this page has more than 3 words except a driver's name (tests\copy-lint-test.ps1). */
(function () {
  'use strict';
  var F = window.Fmt, NONE = F.none, MINUS = '−';
  var $ = function (id) { return document.getElementById(id); };
  var num = function (x) { return typeof x === 'number' && isFinite(x); };
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };
  var TICK = 260;                 // a little over 250 ms: never 5 draws inside one second
  var FLASH_MS = 2000, STALE_MS = 3000, GAL = 3.785412;
  var HGT = { car: 80, me: 104, ghost: 80, cut: 32, head: 56, lapr: 80, thead: 56, empty: 80 }, ROOM = 916;

  var R = window.RacePage = {
    v: null, frameAt: 0, sessRef: null, drivers: {}, multi: false, classCount: {}, sessKey: null,
    laps: [], lc: null, lapWait: null, lapDirty: false, hist: [], trendA: null, trendB: null,
    flagSeen: false, flagWas: '', flashName: '', flashUntil: 0, wasShown: false,
    flagFrom: null, shownFrom: null,     // tests: where the flag and "shown" come from when the page runs on its own
    slots: [], drawn: 0,
    map: null, mapKey: '', mapCars: [],  // lib/map.js (an ES module, loaded once at start); the track it shows; the cars last given to it

    shown: function () {
      if (R.shownFrom) return !!R.shownFrom();
      try { if (window.parent !== window && window.parent.RaceSwitch) return !!window.parent.RaceSwitch.on; } catch (e) { }
      return true;
    },

    init: function () {
      var box = $('eRows');
      for (var i = 0; i < 12; i++) {
        var el = document.createElement('div'); el.className = 'row'; el.hidden = true;
        el.innerHTML = '<span class="p"></span><span class="n"></span><span class="nm"></span><span class="iv"></span><span class="chip" hidden>PIT</span>';
        box.appendChild(el);
        R.slots.push({ el: el, p: el.children[0], n: el.children[1], nm: el.children[2], iv: el.children[3], chip: el.children[4], car: -1 });
      }
      data.on('frame', function (v) { R.frame(v); });
      data.telemetry('race', 15);         // its own connection asks for the race set; inside HOME, HOME asks (ui.js RaceSwitch)
      // the map: REVIEW's module (one /trackmap fetch per track, no polling); without it the zone keeps only the fuel line
      try { import('../lib/map.js').then(function (m) { R.map = m.Map || m.default || null; }, function () { R.map = null; }); } catch (e) { R.map = null; }
      setInterval(R.tick, TICK);
      R.tick();
    },

    tick: function () {
      if (document.hidden) return;
      var sh = R.shown();
      if (sh && !R.wasShown) R.flagSeen = false;          // coming up: a flag already out is not new
      R.wasShown = sh;
      if (!sh) return;
      try { R.draw(performance.now()); } catch (e) { console.error(e); }
    },

    /* ---------------- frames: only what has to be seen at 15 Hz is kept here; drawing waits for the tick ---------------- */
    frame: function (v) {
      R.v = v; R.frameAt = performance.now();
      // a new session (SessionNum) or a new session file: this session's laps and gap history start again
      var s = data.state && data.state.session, key = v.SessionNum + '|' + (s ? s.ver : '');
      if (key !== R.sessKey) { R.sessKey = key; R.laps = []; R.lapWait = null; R.lc = null; R.hist = []; R.trendA = R.trendB = null; }
      var lc = v.LapCompleted;
      if (!num(lc)) return;
      if (v.OnPitRoad) R.lapDirty = true;
      if (R.lc === null || lc < R.lc) { R.lc = lc; R.lapDirty = true; R.hist = []; return; }
      if (lc > R.lc) {
        // iRacing writes the last lap's time a moment after the line: wait for it to change (at most 3 s)
        R.lapWait = { n: lc, was: v.LapLastLapTime, at: R.frameAt, dirty: R.lapDirty };
        R.lc = lc; R.lapDirty = !!v.OnPitRoad;
        R.sampleGaps();
      }
      var w = R.lapWait;
      if (w && (v.LapLastLapTime !== w.was || R.frameAt - w.at > 3000)) {
        R.lapWait = null;
        R.laps.push({ n: w.n, t: v.LapLastLapTime > 0 ? v.LapLastLapTime : null, dirty: w.dirty });
        if (R.laps.length > 60) R.laps.shift();
      }
    },

    /* ---------------- the session part: names, numbers, classes by CarIdx ---------------- */
    session: function () {
      var s = data.state && data.state.session;
      if (s === R.sessRef) return;
      R.sessRef = s; R.drivers = {}; R.classCount = {};
      var list = (s && s.DriverInfo && s.DriverInfo.Drivers) || [];
      for (var i = 0; i < list.length; i++) {
        var d = list[i], idx = parseInt(d.CarIdx, 10);
        if (!(idx >= 0)) continue;
        var drv = { idx: idx, num: d.CarNumber || '', name: shortName(d.UserName), cls: String(d.CarClassID || ''), clsName: d.CarClassShortName || '',
          color: classColor(d.CarClassColor), pace: d.CarIsPaceCar === '1', spec: d.IsSpectator === '1' };
        drv.dark = isDark(drv.color);
        R.drivers[idx] = drv;
        if (!drv.pace && !drv.spec) R.classCount[drv.cls] = (R.classCount[drv.cls] || 0) + 1;
      }
      R.multi = Object.keys(R.classCount).length > 1;
    },

    meIdx: function () {
      var r = R.race(), v = R.v;
      if (r && r.me && num(r.me.idx)) return r.me.idx;
      if (v && num(v.PlayerCarIdx)) return v.PlayerCarIdx;
      var s = R.sessRef; return s && s.DriverInfo ? parseInt(s.DriverInfo.DriverCarIdx, 10) : -1;
    },

    // his class in running order: the stream's CarIdxClassPosition (laps and lap fraction before iRacing gives positions)
    field: function () {
      var v = R.v || {}, me = R.meIdx(), mine = (R.drivers[me] || {}).cls;
      var cp = v.CarIdxClassPosition || [], f2 = v.CarIdxF2Time || [], lap = v.CarIdxLap || [], pct = v.CarIdxLapDistPct || [],
        pit = v.CarIdxOnPitRoad || [], est = v.CarIdxEstTime || [], rows = [];
      for (var k in R.drivers) {
        var d = R.drivers[k], i = d.idx;
        if (d.pace || d.spec || (R.multi && d.cls !== mine)) continue;
        var pos = cp[i] > 0 ? cp[i] : 0, p = num(pct[i]) ? pct[i] : -1;
        if (!pos && p < 0 && i !== me) continue;          // not in the car
        rows.push({ d: d, idx: i, pos: pos, f2: f2[i], est: est[i], dist: (lap[i] > 0 ? lap[i] : 0) + Math.max(0, p), pit: !!pit[i], me: i === me });
      }
      var any = rows.some(function (r) { return r.pos > 0; });
      rows.sort(any ? function (a, b) { return (a.pos || 999) - (b.pos || 999) || a.idx - b.idx; }
        : function (a, b) { return b.dist - a.dist || a.idx - b.idx; });
      return rows;
    },

    // time between a car and the one in front of it (iRacing's F2 times; early in a race, the estimated times on track)
    between: function (a, b) {
      if (!a || !b) return null;
      var dd = a.dist - b.dist;
      if (dd >= 1) return { laps: Math.floor(dd) };
      if (num(a.f2) && num(b.f2) && b.f2 > 0 && (a.f2 > 0 || a.pos === 1) && b.f2 >= a.f2) return { s: b.f2 - a.f2 };
      var li = R.lapInfo(R.race()), lapT = li && li.best > 0 ? li.best : 0;
      if (num(a.est) && num(b.est) && a.est > 0 && b.est > 0) { var g = a.est - b.est; if (g < 0 && lapT) g += lapT; if (g >= 0) return { s: g }; }
      return null;
    },

    race: function () { return data.state ? data.state.race || null : null; },
    // the race part: lapNum = the lap number, lap = the lap times (W2-1); before it arrives, the stream's own Lap
    lapInfo: function (r) { return r && r.lap && typeof r.lap === 'object' ? r.lap : null; },
    lapNo: function (r) { if (r && num(r.lapNum)) return r.lapNum; var v = R.v; return v && num(v.Lap) ? v.Lap : null; },
    // the session type: the race part's, else the session part's entry for the stream's SessionNum
    sessType: function (r) {
      if (r && r.type) return r.type;
      var s = R.sessRef, v = R.v, list = s && s.SessionInfo && s.SessionInfo.Sessions;
      if (!list || !v || !num(v.SessionNum)) return '';
      for (var i = 0; i < list.length; i++) if (parseInt(list[i].SessionNum, 10) === v.SessionNum) return list[i].SessionType || list[i].SessionName || '';
      return '';
    },
    isRace: function (r) { var t = R.sessType(r); if (!t) return true; var n = F.sessionName(t); return n === 'Race' || n === 'AI race'; },
    // the time left: the stream's SessionTimeRemain (fresh), else the race part's; an unlimited session says none
    timeLeft: function (r, fresh) {
      var ok = function (t) { return num(t) && t >= 0 && t < 7 * 86400; }, v = R.v;   // iRacing says 604800 (a week) for "unlimited"
      if (fresh && v && ok(v.SessionTimeRemain)) return v.SessionTimeRemain;
      return r && ok(r.timeLeft) ? r.timeLeft : null;
    },

    // at the line, once a lap: the gaps ahead and behind; the arrow says how much per lap over up to the last 3 laps
    sampleGaps: function () {
      var rows = R.field(), k = rows.findIndex(function (r) { return r.me; }); if (k < 0) return;
      var a = R.between(rows[k - 1], rows[k]), b = R.between(rows[k], rows[k + 1]);
      R.hist.push({ ahead: rows[k - 1] ? rows[k - 1].idx : -1, aS: a && num(a.s) ? a.s : null, behind: rows[k + 1] ? rows[k + 1].idx : -1, bS: b && num(b.s) ? b.s : null });
      if (R.hist.length > 4) R.hist.shift();
      R.trendA = R.trend('a'); R.trendB = R.trend('b');
    },
    trend: function (side) {
      var h = R.hist, last = h[h.length - 1], idx = side === 'a' ? last.ahead : last.behind, now = side === 'a' ? last.aS : last.bS, first = null;
      if (now === null || idx < 0) return null;
      for (var i = h.length - 2; i >= 0 && h.length - 1 - i <= 3; i--) {
        var e = h[i], s = side === 'a' ? e.aS : e.bS;
        if ((side === 'a' ? e.ahead : e.behind) !== idx || s === null) break;
        first = { s: s, laps: h.length - 1 - i };
      }
      return first ? { idx: idx, perLap: (now - first.s) / first.laps } : null;
    },

    flag: function () {
      if (R.flagFrom) return R.flagFrom() || '';
      try { if (window.parent !== window && window.parent.UI) return window.parent.UI.flagName || ''; } catch (e) { }
      return '';
    },

    /* ---------------- drawing, 4 times a second ---------------- */
    draw: function (now) {
      R.session(); R.drawn++;
      var r = R.race(), v = R.v, root = $('race');
      var fresh = !!v && now - R.frameAt < STALE_MS, any = !!v || !!r;
      var pit = !!(r && r.pit && r.pit.onRoad) || !!(fresh && v.OnPitRoad);
      var caution = !!(r && r.flags && r.flags.caution);
      var race = R.isRace(r);
      put(root, 'race' + (any ? '' : ' nodata') + (v && !fresh ? ' stale' : '') + (pit ? ' pit' : '') + (caution && !pit ? ' caution' : '') + (race ? '' : ' practice'), 'className');
      var rows = any ? R.field() : [], k = rows.findIndex(function (x) { return x.me; });
      R.drawA(r, v, rows, now, fresh, caution, race, any);
      R.drawB(r, rows, k, caution, race, pit);
      R.drawC(r, pit, caution, race);
      R.drawMap(rows);
      R.drawD(r, v, fresh);
      R.drawE(r, rows, k, caution, race, pit);
    },

    drawA: function (r, v, rows, now, fresh, caution, race, any) {
      // irdash's numbers; before the race part arrives, the stream's own position and the session's entry list
      var cpos = v && v.CarIdxPosition ? v.CarIdxPosition[R.meIdx()] : 0;
      var pos = r && r.pos > 0 ? r.pos : cpos > 0 ? cpos : 0, of = r && r.of > 0 ? r.of : R.entries();
      put($('aPos'), pos ? 'P' + pos : NONE);
      put($('aOf'), pos && of ? 'of ' + of : '');
      put($('aCls'), R.multi && r && r.classPos > 0 ? 'Class P' + r.classPos + (r.classOf > 0 ? '/' + r.classOf : '') : '');
      // short readouts, each its own span: "Lap 31/52" (a lap race says its count), "Lap 12 · 22:10 left" (timed), "Practice · 20:14 left"
      var parts = [];
      if (r || fresh) {
        var ln = R.lapNo(r), laps = r && num(r.laps) && r.laps > 0 ? r.laps : 0, tl = R.timeLeft(r, fresh);
        if (race) { if (num(ln) && ln > 0) parts.push('Lap ' + ln + (laps ? '/' + laps : '')); }
        else parts.push(F.sessionName(R.sessType(r)));
        if (!(race && laps) && tl !== null) parts.push(clock(tl) + ' left');
      }
      var mid = parts.map(function (p) { return '<span>' + esc(p) + '</span>'; }).join(' · ');
      // a new flag: the strip takes its colour and its name for 2 s (the light box and the edge glow carry it after that)
      var f = R.flag();
      if (!R.flagSeen) { R.flagSeen = true; R.flagWas = f; }      // a flag already out when the screen comes up is not new
      if (f && f !== R.flagWas) { R.flashName = f; R.flashUntil = now + FLASH_MS; }
      R.flagWas = f;
      var flash = now < R.flashUntil;
      put($('zA'), 'zone strip' + (flash ? ' flash f-' + R.flashName : ''), 'className');
      var midEl = $('aMid');
      if (flash) put(midEl, '<span class="word">' + esc(R.flagWords(R.flashName)) + '</span>', 'innerHTML');
      else if (!any) put(midEl, 'Waiting', 'innerHTML');
      else if (caution) put(midEl, '<span class="word">Caution</span>' + (mid ? ' · ' + mid : ''), 'innerHTML');
      else put(midEl, mid || NONE, 'innerHTML');
      var inc = r && r.inc, n = inc && num(inc.n) ? inc.n : (fresh && num(v.PlayerCarMyIncidentCount) ? v.PlayerCarMyIncidentCount : null);
      var lim = inc && inc.limit > 0 ? inc.limit : 0;
      put($('aIncN'), n === null ? NONE : n + 'x' + (lim ? ' / ' + lim : ''));
      put($('aInc'), 'a-inc' + (n !== null && lim && lim - n <= 3 ? ' near' : ''), 'className');
      put($('aClock'), v && !fresh ? 'No data ' + Math.round((now - R.frameAt) / 1000) + 's' : r && num(r.clock) ? clock(r.clock) : NONE);
    },
    // the flag's name, two words at most (HOME's longer flag text stays on HOME: no sentences here)
    flagWords: function (name) {
      return { black: 'Black flag', orange: 'Repair', warning: 'Warning', checkered: 'Finish', red: 'Red flag', yellow: 'Yellow', blue: 'Blue flag', white: 'Last lap', green: 'Green' }[name] || name;
    },
    // cars in the session (not the pace car, not spectators)
    entries: function () { var n = 0; for (var k in R.classCount) n += R.classCount[k]; return n; },

    drawB: function (r, rows, k, caution, race, pit) {
      var one = caution || !race || pit, box = $('zB');
      put(box, 'zone gaps' + (one ? ' one' : ''), 'className');
      $('bOne').hidden = !one;
      put($('bOneN'), '', 'className');
      if (pit) {
        // on pit road: the limiter (irdash reads it from EngineWarnings), green when on, red when off
        var lim = r && r.pit ? r.pit.limiter : null;
        put($('bOneL'), 'Pit road');
        putN($('bOneN'), lim === true ? 'Limiter on' : lim === false ? 'Limiter off' : 'Pit', true);
        put($('bOneN'), lim === true ? 'on' : lim === false ? 'off' : '', 'className');
        put($('bOneS'), ' ');
        return;
      }
      if (!race) {
        // practice and qualifying: his best lap (no optimal until there is a source for it, wave 4)
        var lp = R.lapInfo(r);
        put($('bOneL'), 'Best');
        putN($('bOneN'), lp && lp.best > 0 ? F.lap(lp.best) : NONE);
        put($('bOneS'), ' ');
        return;
      }
      if (caution) {
        put($('bOneL'), 'To leader');
        var lead = rows[0], me = rows[k];
        if (me && k === 0 && me.pos === 1) { putN($('bOneN'), 'Leading'); put($('bOneS'), ' '); }
        else { putN($('bOneN'), gapText(R.between(lead, me), '+')); put($('bOneS'), lead ? '#' + lead.d.num + ' ' + lead.d.name : ' '); }
        return;
      }
      R.gapCell($('bAhead'), R.trendA, k > 0 ? rows[k - 1] : null, k >= 0 ? R.between(rows[k - 1], rows[k]) : null, MINUS, k === 0 && rows[k].pos === 1, true);
      R.gapCell($('bBehind'), R.trendB, k >= 0 ? rows[k + 1] : null, k >= 0 ? R.between(rows[k], rows[k + 1]) : null, '+', false, false);
    },
    gapCell: function (el, tr, car, g, sign, leading, ahead) {
      var n = el.querySelector('.g-n'), t = el.querySelector('.g-t'), who = el.querySelector('.g-who');
      if (leading) { put(el, 'gap lead', 'className'); putN(n, 'Leading', true); put(t, ''); put(who, ' '); el._car = -1; return; }
      var changed = (car ? car.idx : -1) !== el._car; el._car = car ? car.idx : -1;
      putN(n, gapText(g, sign), changed);
      put(who, car ? '<b>#' + esc(car.d.num) + '</b>' + esc(car.d.name) : ' ', 'innerHTML');
      var cls = 'gap';
      if (car && tr && tr.idx === car.idx && Math.abs(tr.perLap) >= 0.05) {
        var closing = tr.perLap < 0;          // the gap is shrinking
        cls += ahead ? (closing ? ' good' : ' bad') : (closing ? ' bad' : ' good');
        put(t, (closing ? '▼ ' : '▲ ') + Math.abs(tr.perLap).toFixed(1) + '/lap');
      } else put(t, '');
      put(el, cls, 'className');
    },

    // C's one fuel line (W2-5, Peter: "fuel is way too much text"): numbers only, in one of these shapes
    //   FUEL 12.3 L · 8.1 LAPS · +1.8   a race: in the tank, laps of fuel, spare laps (green enough, amber within a lap, red short)
    //   FUEL 52.4 L · 22.7 LAPS          practice and qualifying (nothing to finish)
    //   FUEL 2/3 LAPS                    measuring (3 clean laps first; caution, pit and incident laps do not count)
    //   PIT NOW · 24 L · HAVE 22 L       under caution when he is short: what still has to go in, what is in
    //   PIT · 22.4 L                     on pit road
    // litres as iRacing gives them; GAL when his iRacing is set to imperial
    drawC: function (r, pit, caution, race) {
      var f = r && r.fuel, gal = !!(r && r.units === 'imperial'), line = $('cFuel'), cls = 'c-fuel';
      var vol = function (l, d) { return num(l) ? (gal ? l / GAL : l).toFixed(d == null ? 1 : d) + (gal ? ' GAL' : ' L') : NONE; };
      var S = function (c, t) { return '<span' + (c ? ' class="' + c + '"' : '') + '>' + esc(t) + '</span>'; };
      var h;
      if (!f) h = S('k', 'FUEL');
      else if (pit) h = S('k', 'PIT') + ' · ' + S('', vol(f.level));
      else if (f.state === 'measuring') h = S('k', 'FUEL') + ' ' + S('', (num(f.measured) ? f.measured : 0) + '/3 LAPS');
      else if (race && caution && num(f.toEnd) && f.toEnd > 0) h = S('k now', 'PIT NOW') + ' · ' + S('short', vol(f.toEnd, 0)) + ' · ' + S('', 'HAVE ' + vol(f.level, 0));
      else {
        h = S('k', 'FUEL') + ' ' + S('', vol(f.level)) + (num(f.lapsOfFuel) ? ' · ' + S('', f.lapsOfFuel.toFixed(1) + ' LAPS') : '');
        if (race && num(f.spare)) h += ' · ' + S(f.state === 'short' ? 'short' : f.state === 'save' ? 'save' : 'ok', (f.spare < 0 ? MINUS : '+') + Math.abs(f.spare).toFixed(1));
        if (f.stale) cls += ' restale';
      }
      put(line, h, 'innerHTML');
      put(line, cls, 'className');
    },

    // C's map: every car in the world where the stream's CarIdxLapDistPct puts it (his in gold and larger, his class leader ringed), in
    // its class colour; the track from the session part (one /trackmap fetch per track, lib/map.js). Drawn with the rest, 4 times a second.
    drawMap: function (rows) {
      var M = R.map, s = R.sessRef, wi = s && s.WeekendInfo;
      if (!M || !wi) return;
      var key = ('t' + (wi.TrackID || '0') + '-' + (wi.TrackName || 'track')).toLowerCase().replace(/[^a-z0-9_-]+/g, '-').slice(0, 80);
      if (key !== R.mapKey) { R.mapKey = key; M.mount($('cMap'), { key: key, id: String(wi.TrackID || ''), size: { w: 908, h: 290 }, pad: 20 }); }
      var v = R.v, pct = (v && v.CarIdxLapDistPct) || [], me = R.meIdx(), lead = rows.length && rows[0].pos === 1 ? rows[0].idx : -1, list = [];
      for (var i in R.drivers) {
        var d = R.drivers[i], p = pct[d.idx];
        if (d.pace || d.spec || !(num(p) && p >= 0)) continue;
        list.push({ p: p, me: d.idx === me, lead: d.idx === lead, color: d.color.charAt(0) === '#' ? d.color : '' });
      }
      R.mapCars = list;
      M.cars(list);
    },

    // the split: iRacing's LapDeltaToBestLap, from the stream (15 a second) when it is fresh, else the race part's copy
    drawD: function (r, v, fresh) {
      var lp = R.lapInfo(r);
      put($('dLast'), lp && lp.last > 0 ? F.lap(lp.last) : NONE);
      put($('dLast'), lp && lp.lastIsBest && lp.last > 0 ? 'best' : '', 'className');
      put($('dBest'), lp && lp.best > 0 ? F.lap(lp.best) : NONE);
      var live = fresh && v && 'LapDeltaToBestLap_OK' in v && num(v.LapDeltaToBestLap);
      var ok = live ? !!v.LapDeltaToBestLap_OK : !!(lp && lp.deltaOk && num(lp.delta)), d = ok ? (live ? v.LapDeltaToBestLap : lp.delta) : 0, bar = $('dBar');
      put(bar, 'd-bar' + (ok ? (d < 0 ? ' ahead' : '') : ' off'), 'className');
      var s = 'scaleX(' + Math.min(1, Math.abs(d) / 2).toFixed(3) + ')', fill = $('dFill');
      if (fill._s !== s) { fill._s = s; fill.style.transform = s; }
      put($('dNum'), ok ? (d < 0 ? MINUS : '+') + Math.abs(d).toFixed(2) : NONE);
      put($('dDelta'), 'd-delta' + (ok ? (d < 0 ? ' ahead' : ' behind') : ''), 'className');
    },

    drawE: function (r, rows, k, caution, race, pit) {
      var items = [], ghost = null;
      if (!race) items = R.lapItems(r);
      else if (!rows.length) items = [{ kind: 'empty' }];
      else {
        if (R.multi) { var me = rows[k] || rows[0]; items.push({ kind: 'head', text: (me.d.clsName || 'Class') + ' · ' + rows.length + ' cars', color: me.d.color }); }
        // on pit road: where he would come out, once irdash has measured this track's pit loss (W2-3); the window centres on it
        var rj = r && r.pit && r.pit.onRoad ? r.pit.rejoin : null, focus = k, at = -1;
        if (rj && typeof rj === 'object') rj = rj.pos;
        if (pit && num(rj) && rj > 0) {
          at = rows.length;
          for (var q = 0; q < rows.length; q++) if (!rows[q].me && rows[q].pos >= rj) { at = q; break; }
          focus = Math.min(at, rows.length - 1);
          ghost = { kind: 'ghost', pos: rj };
        }
        var show = R.window(rows, focus, ghost ? 9 : 10);
        for (var i = 0; i < show.length; i++) {
          var x = show[i];
          if (x === null) { items.push({ kind: 'cut' }); continue; }
          var j = rows.indexOf(x), iv;
          if (ghost && j === at) { items.push(ghost); ghost = null; }
          if (j === 0) iv = x.pos === 1 ? { word: 'Leader' } : { text: NONE };
          else if (caution) iv = { text: gapText(R.between(rows[0], x), '+') };
          else iv = { text: gapText(R.between(rows[j - 1], x), '+') };
          items.push({ kind: x.me ? 'me' : 'car', r: x, iv: iv });
        }
        if (ghost) items.push(ghost);              // he comes out behind everyone shown
      }
      // never more than the zone holds: rows go from the bottom, the ghost row never
      var keep = [], total = 0;
      items.forEach(function (it) { if (it.kind === 'ghost') total += HGT.ghost; });
      for (var z = 0; z < items.length; z++) {
        if (items[z].kind === 'ghost') { keep.push(items[z]); continue; }
        total += HGT[items[z].kind]; if (total > ROOM) break; keep.push(items[z]);
      }
      for (var s = 0; s < R.slots.length; s++) R.slot(R.slots[s], keep[s]);
    },

    // the class leader pinned, then the cars round the focus (him; on pit road, where he rejoins): 4 ahead, 4 behind
    window: function (rows, f, cars) {
      var n = rows.length;
      if (n <= cars || f < 0) return rows.slice(0, cars);
      var start = Math.max(1, Math.min(n - (cars - 1), f - 4));
      if (start <= 2 && f < cars) return rows.slice(0, cars);      // a cut that would hide one car only: show the top in one piece
      var out = [rows[0]];
      if (start > 1) out.push(null);
      return out.concat(rows.slice(start, start + cars - 1));
    },

    // practice and qualifying: this session's laps, newest first, with the gap to his best
    lapItems: function (r) {
      var li = R.lapInfo(r), best = li && li.best > 0 ? li.best : null, laps = R.laps.slice(-9).reverse();
      if (!laps.length) return [{ kind: 'thead' }, { kind: 'empty', text: 'No laps yet' }];
      var out = [{ kind: 'thead' }];
      laps.forEach(function (l) {
        var isBest = best && l.t > 0 && Math.abs(l.t - best) < 0.0005;
        out.push({ kind: 'lapr', lap: l, best: isBest, d: l.t > 0 && best ? (isBest ? '' : '+' + (l.t - best).toFixed(3)) : NONE });
      });
      return out;
    },

    // one row of zone E: what each kind of row says in its four cells
    slot: function (s, it) {
      if (!it) { s.el.hidden = true; s.car = -1; return; }
      s.el.hidden = false;
      var o = { cls: 'row', p: '', n: '', nCls: 'n', band: 'transparent', nm: '', nmCls: 'nm', iv: '', ivCls: 'iv', gap: false, pit: false, rowBand: '', car: -1 };
      if (it.kind === 'car' || it.kind === 'me') {
        var x = it.r;
        o.cls += (it.kind === 'me' ? ' me' : '') + (x.pit ? ' pit' : '');
        o.p = x.pos > 0 ? String(x.pos) : NONE; o.n = '#' + x.d.num; o.nCls = 'n' + (x.d.dark ? ' lightink' : ''); o.band = x.d.color; o.nm = x.d.name;
        if (it.iv.word) { o.iv = it.iv.word; o.ivCls = 'iv word'; } else { o.iv = it.iv.text; o.gap = true; }
        o.pit = x.pit; o.car = x.idx;
      } else if (it.kind === 'ghost') { o.cls += ' ghost'; o.nm = 'Rejoin P' + it.pos; }
      else if (it.kind === 'head') { o.cls += ' head'; o.p = it.text; o.rowBand = it.color; }
      else if (it.kind === 'cut') { o.cls += ' cut'; o.p = '···'; }
      else if (it.kind === 'thead') { o.cls += ' lapr thead'; o.p = 'Lap'; o.n = 'Time'; o.nCls = 't'; o.nm = 'To best'; o.nmCls = 'nm d'; }
      else if (it.kind === 'lapr') {
        o.cls += ' lapr' + (it.best ? ' best' : '') + (it.lap.dirty ? ' dirty' : '');
        o.p = 'Lap ' + it.lap.n; o.n = it.lap.t > 0 ? F.lap(it.lap.t) : NONE; o.nCls = 't'; o.nm = it.best ? 'Best' : it.d; o.nmCls = 'nm d';
      } else { o.cls += ' empty-row'; o.nm = it.text || NONE; }
      // a different car in this row: its interval goes in now, with the rest of the row (the 250 ms hold is for one car's own gap)
      var moved = o.car !== s.car; s.car = o.car;
      put(s.el, o.cls, 'className');
      if (s.el._band !== o.rowBand) { s.el._band = o.rowBand; if (o.rowBand) s.el.style.setProperty('--cls', o.rowBand); else s.el.style.removeProperty('--cls'); }
      put(s.p, o.p); put(s.n, o.n); put(s.n, o.nCls, 'className'); put(s.nm, o.nm); put(s.nm, o.nmCls, 'className'); put(s.iv, o.ivCls, 'className');
      if (s.n._band !== o.band) { s.n._band = o.band; s.n.style.setProperty('--cls', o.band); }
      if (o.gap) putN(s.iv, o.iv, moved); else put(s.iv, o.iv);
      s.chip.hidden = !o.pit;
    },
  };

  /* ---------------- small helpers ---------------- */
  // write to the page only when it changed
  function put(el, s, prop) { if (!el) return; prop = prop || 'textContent'; var k = '_' + prop; if (el[k] !== s) { el[k] = s; el[prop] = s; } }
  // a gap or interval: written only when its text (to the tenth) changed, and never twice inside 250 ms for the same car
  function putN(el, s, now) {
    if (!el || el._textContent === s) return;
    var t = performance.now(); if (!now && el._nAt && t - el._nAt < 250) return;
    el._nAt = t; el._textContent = s; el.textContent = s;
  }
  function gapText(g, sign) {
    if (!g) return NONE;
    if (g.laps) return sign + g.laps + (g.laps === 1 ? ' lap' : ' laps');
    return num(g.s) ? sign + g.s.toFixed(1) : NONE;
  }
  function clock(s) {
    if (!num(s) || s < 0) return NONE;
    s = Math.floor(s); var h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60, p = function (n) { return (n < 10 ? '0' : '') + n; };
    return h ? h + ':' + p(m) + ':' + p(x) : m + ':' + p(x);
  }
  // iRacing's surname is enough at a glance ("Peter Adamis" -> Adamis); iRacing adds digits to a duplicate name ("Santos11" -> Santos),
  // the same rule as irdash's Session.ShortName
  function shortName(n) { var w = String(n || '').trim().split(/\s+/); var s = (w[w.length - 1] || '').replace(/\d+$/, '') || w[w.length - 1] || ''; return s.length > 14 ? s.slice(0, 13) + '.' : s; }
  // iRacing writes 0xffda59; dark class colours get light numbers
  function classColor(c) {
    var h = String(c || '').replace(/^0x/i, '').replace(/^#/, '');
    if (!/^[0-9a-f]{1,6}$/i.test(h)) return 'var(--dim)';
    h = ('000000' + h).slice(-6); return '#' + h;
  }
  var darkCache = {};
  function isDark(col) {
    if (col in darkCache) return darkCache[col];
    var m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(col), y = 1;
    if (m) y = (0.2126 * parseInt(m[1], 16) + 0.7152 * parseInt(m[2], 16) + 0.0722 * parseInt(m[3], 16)) / 255;
    return (darkCache[col] = y < 0.45);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', R.init); else R.init();
})();
