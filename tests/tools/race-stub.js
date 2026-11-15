// race-stub.js - the stand-in for data.js the race screen's offline tests load before the page (tests\race-page-test.ps1,
// tests\copy-lint-test.ps1): fixtures pushed as state parts, a pretend field of 19 cars as frames, and __look() for the checks.
// __FX__ = the fixtures; __OUTLINE__ = file URL of Road Atlanta's outline, the one thing the page may fetch (the map's /trackmap).
(function () {
  var ls = { state: [], frame: [], online: [], status: [] };
  window.__fx = __FX__;
  window.__req = [];
  window.fetch = function (u) {
    window.__req.push(String(u));
    if (/^\/trackmap\?/.test(String(u))) return new Promise(function (res) { var x = new XMLHttpRequest(); x.open('GET', '__OUTLINE__'); x.onload = function () { res(new Response(x.responseText, { status: 200, headers: { 'Content-Type': 'application/json' } })); }; x.onerror = function () { res(new Response('{}', { status: 404 })); }; x.send(); });
    return Promise.reject(new Error('no network in this test'));
  };
  window.data = { __paddock: true, state: {}, seq: 0, online: true, set: '',
    get rig() { var r = window.data.state.rig || {}; return { driving: !!r.driving, sessionOn: !!r.sessionOn, simRunning: !!r.simRunning, online: true }; },
    at: function () { return 0; },
    on: function (n, f) { (ls[n] = ls[n] || []).push(f); return function () { }; },
    telemetry: function (v) { window.data.set = typeof v === 'string' ? v : ''; },
    json: function (u) { return window.fetch(u); }, fetch: function (u) { return window.fetch(u); }, reloadOnVersion: function () { }, onList: function () { } };
  window.__push = function (m) { var ch = {}; for (var k in m) { window.data.state[k] = m[k]; ch[k] = true; } window.data.seq++; ls.state.forEach(function (f) { f(window.data.state, ch); }); };
  window.__frame = function (v) { ls.frame.forEach(function (f) { f(v); }); };
  // 19 cars (the 12 Nov field): car 2 is Peter (#3). order = CarIdx in running order (overall); multi: even CarIdx GT3, odd GT4 (session-multi.json)
  window.__order = function (mePos) { var o = []; for (var i = 0; i < 19; i++) if (i !== 2) o.push(i); o.splice(mePos - 1, 0, 2); return o; };
  window.__field = function (o) {
    var t = o.t || 0, order = o.order || __order(o.mePos || 4), v = {};
    ['CarIdxClassPosition', 'CarIdxPosition', 'CarIdxF2Time', 'CarIdxLap', 'CarIdxLapDistPct', 'CarIdxOnPitRoad', 'CarIdxEstTime', 'CarIdxClass'].forEach(function (k) {
      v[k] = []; for (var i = 0; i < 64; i++) v[k].push(k === 'CarIdxLap' || k === 'CarIdxLapDistPct' ? -1 : 0); });
    var cls = {};
    order.forEach(function (idx, k) {
      var c = o.multi && idx % 2 ? 'b' : 'a'; cls[c] = (cls[c] || 0) + 1;
      // the gaps wobble (o.wobble seconds, o.rate times faster than real) so the tenths change on almost every frame
      var f2 = k === 0 ? 0 : Math.max(0.05, k * 1.37 + (o.wobble || 0) * Math.sin(t * (o.rate || 1) * (0.7 + idx * 0.13)));
      if (o.f2 && idx in o.f2) f2 = o.f2[idx];          // a car's own gap to the leader (two cars swapping)
      v.CarIdxPosition[idx] = k + 1; v.CarIdxClassPosition[idx] = cls[c]; v.CarIdxF2Time[idx] = f2;
      var dist = 31.5 - f2 / 93.4; v.CarIdxLap[idx] = Math.floor(dist); v.CarIdxLapDistPct[idx] = dist - Math.floor(dist);
      v.CarIdxEstTime[idx] = (dist - Math.floor(dist)) * 93.4; v.CarIdxClass[idx] = c === 'a' ? 4083 : 4084;
      v.CarIdxOnPitRoad[idx] = (o.pit || []).indexOf(idx) >= 0 ? 1 : 0;
    });
    var lap = o.lap || 31;
    v.PlayerCarIdx = 2; v.IsOnTrack = 1; v.OnPitRoad = (o.pit || []).indexOf(2) >= 0 ? 1 : 0; v.Lap = lap; v.LapCompleted = o.lc != null ? o.lc : lap - 1;
    v.SessionFlags = 0; v.SessionTime = 3753 + t; v.FuelLevel = 22.4; v.LapLastLapTime = 93.832; v.LapBestLapTime = 93.412;
    v.LapDeltaToBestLap = -0.21; v.LapDeltaToBestLap_OK = 1; v.PlayerCarMyIncidentCount = 4; v.SessionLapsRemainEx = 21;
    v.SessionTimeRemain = o.timeRemain != null ? o.timeRemain : 604800; v.SessionNum = o.sessNum != null ? o.sessNum : 2; v.IsReplayPlaying = 0; v.DisplayUnits = 1; v.EngineWarnings = 0;
    return v;
  };
  window.__run = function (o) { clearInterval(window.__timer); var t0 = performance.now(); window.__o = o;
    var go = function () { window.__frame(window.__field(Object.assign({ t: (performance.now() - t0) / 1000 }, window.__o))); };
    go(); window.__timer = setInterval(go, 66); };
  window.__stop = function () { clearInterval(window.__timer); };
  window.__flag = '';
  document.addEventListener('DOMContentLoaded', function () { if (window.RacePage) window.RacePage.flagFrom = function () { return window.__flag; }; });
  // what the screen shows, for the checks
  window.__look = function () {
    var vis = function (el) { if (!el || el.hidden) return false; var r = el.getBoundingClientRect(); if (r.width < 1 || r.height < 1) return false; var cs = getComputedStyle(el); return cs.visibility !== 'hidden' && cs.display !== 'none' && +cs.opacity > 0.05; };
    var small = [], out = [], texts = [], km = [];
    var walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walk.nextNode()) {
      var n = walk.currentNode, el = n.parentElement; if (!n.nodeValue.trim() || !vis(el)) continue;
      var anc = el, ok = true; while (anc && anc !== document.body) { if (!vis(anc)) { ok = false; break; } anc = anc.parentElement; } if (!ok) continue;
      var fs = parseFloat(getComputedStyle(el).fontSize), r = el.getBoundingClientRect();
      if (fs < 24) small.push(n.nodeValue.trim() + ' ' + fs);
      if (r.left < 1380 && r.right > 540 && r.bottom > 1012 && r.top < 1070) km.push(n.nodeValue.trim());
      if (r.left < 0 || r.top < 0 || r.right > 1920.5 || r.bottom > 1080.5) out.push(n.nodeValue.trim());
      texts.push(n.nodeValue.trim());
    }
    var box = function (id) { var r = document.getElementById(id).getBoundingClientRect(); return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)].join(','); };
    var txt = function (id) { var e = document.getElementById(id); return e ? e.textContent.replace(/ /g, ' ').trim() : ''; };
    var rows = [].slice.call(document.querySelectorAll('#eRows .row')).filter(function (r) { return !r.hidden; }).map(function (r) {
      return { cls: r.className, p: r.children[0].textContent, n: r.children[1].textContent, nm: r.children[2].textContent, iv: r.children[3].textContent,
        pit: !r.children[4].hidden, h: Math.round(r.getBoundingClientRect().height), color: getComputedStyle(r.children[2]).color, fs: parseFloat(getComputedStyle(r.children[2]).fontSize),
        bg: getComputedStyle(r).backgroundColor }; });
    var root = getComputedStyle(document.documentElement);
    var tok = function (k) { var e = document.createElement('i'); e.style.color = 'var(' + k + ')'; document.body.appendChild(e); var c = getComputedStyle(e).color; e.remove(); return c; };
    return { small: small, out: out, km: km, texts: texts.join(' | '), raceCls: document.getElementById('race').className, stripCls: document.getElementById('zA').className,
      stripBg: getComputedStyle(document.getElementById('zA')).backgroundColor,
      boxes: { A: box('zA'), B: box('zB'), C: box('zC'), D: box('zD'), E: box('zE') },
      A: { pos: txt('aPos'), of: txt('aOf'), cls: txt('aCls'), mid: txt('aMid'), inc: txt('aInc'), incNear: document.getElementById('aInc').className.indexOf('near') >= 0, clock: txt('aClock') },
      B: { ahead: txt('bAhead'), behind: txt('bBehind'), one: vis(document.getElementById('bOne')) ? txt('bOne') : '', aheadCls: document.getElementById('bAhead').className, behindCls: document.getElementById('bBehind').className, bVis: vis(document.getElementById('zB')), aVis: vis(document.getElementById('bAhead')) },
      // C: the fuel line (its words; the colour of its last number, the spare), the map (status, cars given to it, the canvas drawn)
      C: (function () { var f = document.getElementById('cFuel'), sp = f.querySelectorAll('span'), last = sp[sp.length - 1], M = window.RacePage && window.RacePage.map;
        return { fuel: txt('cFuel'), cls: f.className, lastColor: last ? getComputedStyle(last).color : '', firstColor: sp[0] ? getComputedStyle(sp[0]).color : '',
          map: M ? M.status : 'none', cars: (window.RacePage.mapCars || []).length, me: (window.RacePage.mapCars || []).filter(function (c) { return c.me; }).length,
          lead: (window.RacePage.mapCars || []).filter(function (c) { return c.lead; }).length, canvas: !!document.querySelector('#cMap canvas') }; })(),
      D: { last: txt('dLast'), lastColor: getComputedStyle(document.getElementById('dLast')).color, best: txt('dBest'), bar: vis(document.getElementById('dBar')), num: txt('dNum'), numColor: getComputedStyle(document.getElementById('dNum')).color, vis: vis(document.getElementById('zD')), op: getComputedStyle(document.getElementById('zD')).opacity },
      rows: rows,
      tok: { gold: tok('--gold'), gain: tok('--gain'), loss: tok('--loss'), amber: tok('--amber'), ink: tok('--ink'), purple: tok('--purple'), cyan: tok('--cyan'), dim: tok('--dim'), muted: tok('--muted') },
      req: window.__req.filter(function (u) { return !/^\/trackmap\?/.test(u); }).length, mapReq: window.__req.filter(function (u) { return /^\/trackmap\?/.test(u); }).length, set: window.data.set };
  };
})();
