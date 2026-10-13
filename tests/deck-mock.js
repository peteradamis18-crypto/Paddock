// A pretend Stream Deck app for tests\deck-speed-test.ps1 and tests\mydrive-test.ps1.
// Injected before the add-on's own script, so deck-intro\plugin.html runs unchanged inside it: it replaces the
// WebSocket the add-on talks to the Stream Deck app with this one, and (when cfg.fakeFetch is on) answers the add-on's
// requests to irdash from window.__sd.fx so that tests are repeatable. Everything the add-on sends is recorded.
// The fake app's own timers run on a worker (the real app is another process: its clock is not slowed when the
// add-on's page is hidden). The add-on's page itself is real: if the test hides the tab, Chrome slows its
// setTimeout/setInterval exactly as it does in the Stream Deck app.
(function () {
  const M = window.__sd = {
    cfg: { switchMs: 150, apiMs: 15, getMs: 4, fakeFetch: true },   // switchMs = how long the Stream Deck app takes to show a profile (an assumption: it is measured, not known)
    events: [], logs: [], images: {}, imgLog: [], fetchLog: [], fx: {}, onApi: null, cur: null, prevProfile: 'main', ws: null,
    pngCalls: 0, pngMs: 0, switchSent: 0, firstAppearAt: 0,
  };
  const wk = new Worker(URL.createObjectURL(new Blob(['onmessage = e => setTimeout(() => postMessage(e.data.id), e.data.ms);'], { type: 'text/javascript' })));
  const cbs = new Map(); let nid = 1;
  wk.onmessage = e => { const f = cbs.get(e.data); if (f) { cbs.delete(e.data); f(); } };
  const later = (ms, f) => { const id = nid++; cbs.set(id, f); wk.postMessage({ id, ms }); };
  const sleepM = ms => new Promise(r => later(ms, r));
  M.later = later; M.sleep = sleepM;

  // PNG encodes done by the add-on
  const td = HTMLCanvasElement.prototype.toDataURL;
  HTMLCanvasElement.prototype.toDataURL = function () { const t = performance.now(); const r = td.apply(this, arguments); M.pngCalls++; M.pngMs += performance.now() - t; return r; };

  // the profiles: your own page (the three opener keys) and the one-page profiles made of 32 tiles
  const OPEN = [['k-friends', 'com.peter.rigintro.friends', 5, 1], ['k-overlays', 'com.peter.rigintro.overlays', 6, 1], ['k-mydrive', 'com.peter.rigintro.mydrive', 7, 1]];
  const TILE = { RigFriends: 'friends', RigOverlays: 'overlays', RigMyDrive: 'mydrive', RigIntro: 'intro' };
  function keysOf(profile) {
    if (profile === 'main') return OPEN.map(k => ({ ctx: k[0], action: k[1], col: k[2], row: k[3], settings: {} }));
    const a = [];
    for (let r = 0; r < 4; r++) for (let c = 0; c < 8; c++) a.push({ ctx: 'T-' + profile + '-' + c + '-' + r, action: 'com.peter.rigintro.tile', col: c, row: r, settings: { p: TILE[profile] } });
    return a;
  }
  const ev = (event, k) => ({ event, action: k.action, context: k.ctx, device: 'DEV', payload: { settings: k.settings, coordinates: { column: k.col, row: k.row }, state: 0, isInMultiAction: false } });
  function deliver(e) { if (M.ws && M.ws.onmessage) M.ws.onmessage({ data: JSON.stringify(e) }); }

  // the Stream Deck app switches profile: the old keys go, the new ones appear one by one (each its own message)
  M.show = function (profile) {
    if (M.cur) for (const k of keysOf(M.cur)) deliver(ev('willDisappear', k));
    M.cur = profile;
    keysOf(profile).forEach((k, i) => later(0, () => { if (i === 0) M.firstAppearAt = performance.now(); deliver(ev('willAppear', k)); }));
  };

  class MockWS {
    constructor() { this.readyState = 1; M.ws = this; later(5, () => this.onopen && this.onopen({})); }
    send(m) {
      const t = performance.now(), o = JSON.parse(m);
      M.events.push({ t, e: o.event, ctx: o.context, p: o.payload });
      if (o.event === 'logMessage') M.logs.push({ t, m: o.payload.message });
      else if (o.event === 'setImage') { M.images[o.context] = o.payload.image; M.imgLog.push({ t, ctx: o.context, url: o.payload.image }); }
      else if (o.event === 'switchToProfile') {
        const to = o.payload && o.payload.profile ? o.payload.profile : M.prevProfile;
        M.switchSent = t;
        later(M.cfg.switchMs, () => { M.prevProfile = M.cur; M.show(to); });
      }
    }
  }
  window.WebSocket = MockWS;

  // the add-on's requests to irdash
  const realFetch = window.fetch.bind(window);
  window.fetch = function (url, opt) {
    const u = String(url), path = u.replace('http://localhost:8199', '');
    M.fetchLog.push({ t: performance.now(), u: path });
    if (M.cfg.fakeFetch) {
      if (path.startsWith('/api/')) return new Promise(res => later(M.cfg.apiMs, () => { if (M.onApi) M.onApi(path); res(new Response('ok')); }));
      const fx = M.fx[path.split('?')[0]];
      if (fx !== undefined) return new Promise(res => later(M.cfg.getMs, () => res(new Response(JSON.stringify(typeof fx === 'function' ? fx() : fx), { headers: { 'Content-Type': 'application/json' } }))));
    }
    return realFetch(url, opt);
  };

  // ---- what the tests drive ----
  M.connect = function () {
    connectElgatoStreamDeckSocket(1234, 'uuid', 'registerPlugin', JSON.stringify({ devices: [{ id: 'DEV', type: 2 }] }));
    later(20, () => { M.cur = null; M.show('main'); });
  };
  // press an opener key on your own page
  M.pressOpener = function (which) { const k = keysOf('main').find(x => x.action.endsWith('.' + which)); deliver(ev('keyDown', k)); };
  // press a key of the profile that is showing
  M.pressTile = function (col, row) { const k = keysOf(M.cur).find(x => x.col === col && x.row === row); deliver(ev('keyDown', k)); };
  M.tileCtx = (col, row) => 'T-' + M.cur + '-' + col + '-' + row;

  // press the opener key and time everything up to the last of the 32 keys getting its picture
  M.measureOpen = async function (which, maxMs) {
    M.imgLog.length = 0; M.switchSent = 0; M.firstAppearAt = 0;
    const t0 = performance.now(); M.pressOpener(which);
    let first = 0, all = 0;
    while (performance.now() - t0 < (maxMs || 15000)) {
      await sleepM(4);
      const set = new Set(); let f = 0;
      for (const x of M.imgLog) if (x.ctx.startsWith('T-')) { set.add(x.ctx); if (!f) f = x.t; }
      if (f && !first) first = f;
      if (set.size >= 32) { all = performance.now(); break; }
    }
    return { switchSentMs: M.switchSent ? M.switchSent - t0 : -1, firstAppearMs: M.firstAppearAt ? M.firstAppearAt - t0 : -1, firstPictureMs: first ? first - t0 : -1, allPicturesMs: all ? all - t0 : -1, t0 };
  };

  // what a picture mostly looks like at its corner: white = the press flash, gold = chosen, dark = normal
  M.classify = function (url) {
    return new Promise(res => {
      const im = new Image();
      im.onload = () => { const c = document.createElement('canvas'); c.width = c.height = 96; const g = c.getContext('2d'); g.drawImage(im, 0, 0); const d = g.getImageData(8, 8, 1, 1).data; const [r, gr, b] = d;
        res(r > 240 && gr > 240 && b > 240 ? 'white' : r > 220 && gr > 170 && gr < 215 && b < 90 ? 'gold' : r < 50 && gr < 50 && b < 50 ? 'dark' : r + ',' + gr + ',' + b); };
      im.onerror = () => res('?');
      im.src = url;
    });
  };
  // the pictures one key got after time t0: [{ ms, look }]
  M.timeline = async function (ctx, t0) {
    const out = [];
    for (const x of M.imgLog) if (x.ctx === ctx && x.t >= t0) out.push({ ms: Math.round(x.t - t0), look: await M.classify(x.url) });
    return out;
  };
  M.fetchTimes = (prefix, since) => M.fetchLog.filter(f => f.u.startsWith(prefix) && f.t >= since).map(f => f.t);
  M.visibility = () => document.visibilityState;
  M.perfLines = () => M.logs.filter(l => /perf |speedtest/.test(l.m)).map(l => l.m);
})();
