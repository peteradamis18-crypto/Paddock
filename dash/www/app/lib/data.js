/* data.js (W0-5): the page's ONE connection to irdash. Plain script for now (a module later).
   Before this, HOME asked 14 routes on their own timers (about 16 requests a second sitting idle, 11 while Peter drives).
   Now there is one stream (/stream?state=1) and irdash pushes "event: state" when something changes: kids, tow, keymsg, the page
   requests (nav), guest, mydrive, doctor, overlays, recorder, health, showcase, rig, version, the parsed session and the list numbers.
   Pages never poll; they subscribe:
     data.state                 the latest state object (data.state.now = irdash's clock in ms when it was sent, recvAt = ours)
     data.on('state', fn)       fn(state, changed): changed names the parts in this push (all of them on the first)
     data.on('frame', fn)       telemetry frames (only after data.telemetry(vars) and only while iRacing is connected)
     data.rig.driving / .online
     data.json(url, ttl)        cached GET for page data (one request per url within ttl ms, shared while one is in flight)
     data.fetch(url, opts)      the one helper for requests that change something: adds X-Paddock: 1 (W0-2)
     data.reloadOnVersion(wait) reload when the dashboard files change; wait() true = not now (asked again every 15 s)
     data.onList(name, fn)      fn() when the list "sessions" | "vault" | "races" | "perf" may have changed (instead of a timer)
   A page inside HOME's frame (Sessions, Vault, Performance, Analysis ...) uses HOME's connection, so the whole top screen has one.
   Telemetry: no variables are asked for until iRacing is connected (HOME idle asks for none), then the visible layout's list at 15 Hz.
     data.telemetry(['A', 'B'])  these variables;   data.telemetry('race')  irdash's named set (W2-1: the race screen's 24 channels)
     data.set                    the named set asked for now ('' = a variable list or nothing) */
(function () {
  'use strict';
  if (window.data && window.data.__paddock) return;

  // inside HOME's iframe: borrow the host's connection
  var host = null;
  try {
    var w = window;
    while (w !== w.parent) { w = w.parent; var d = w.data; if (d && d.__paddock) { host = d.root || d; break; } }
  } catch (e) { host = null; }
  window.data = host ? borrowed(host) : own();

  function jsonCache(fetchFn) {
    var cache = {};
    return function (url, ttl) {
      var c = cache[url], now = Date.now();
      if (c && (!c.done || now - c.at < (ttl || 0))) return c.p;
      var p = fetchFn(url, { cache: 'no-store' }).then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); });
      c = cache[url] = { at: now, p: p, done: false };
      p.then(function () { c.done = true; }, function () { c.done = true; c.at = 0; });
      return p;
    };
  }
  function paddockFetch(fetchFn) {
    return function (url, opts) {
      var o = {}, k; opts = opts || {};
      for (k in opts) o[k] = opts[k];
      if (!o.cache) o.cache = 'no-store';
      var h = {}; if (opts.headers) for (k in opts.headers) h[k] = opts.headers[k];
      h['X-Paddock'] = '1'; o.headers = h;
      return fetchFn(url, o);
    };
  }
  function versionWatcher(api) {
    return function (wait) {
      var seen = null;
      var check = function () {
        var v = api.state && api.state.version;
        if (v == null) return;
        if (seen === null) { seen = v; return; }
        if (v === seen) return;
        if (wait && wait()) return;           // not now (he is driving): looked at again in 15 s
        location.reload();
      };
      api.on('state', check);
      setInterval(check, 15000);
    };
  }

  // a page's list (Sessions, Vault, My Races, Performance) loads again when irdash says it may have changed (state part "lists")
  function listWatcher(api) {
    return function (name, fn) {
      var seen = null;
      return api.on('state', function (st, ch) {
        if (!ch.lists || !st.lists) return;
        var v = st.lists[name];
        if (seen === null) { seen = v; return; }
        if (v !== seen) { seen = v; fn(); }
      });
    };
  }

  function own() {
    var api = {
      __paddock: true, state: {}, seq: -1, online: false, connected: false,
      ls: { state: [], frame: [], status: [], online: [] },
      vars: null, set: '', hz: 15, es: null, mode: '', url: '', partAt: {},
      at: function (part) { return api.partAt[part] || 0; },      // when that part last arrived (this page's clock): a counter shown can run on from it
      on: function (name, fn) {
        var l = api.ls[name] || (api.ls[name] = []); l.push(fn);
        if (name === 'state' && api.seq >= 0) { try { fn(api.state, allParts()); } catch (e) { console.error(e); } }   // late subscribers get what is known
        return function () { var i = l.indexOf(fn); if (i >= 0) l.splice(i, 1); };
      },
      emit: function (name, a, b) { var l = (api.ls[name] || []).slice(); for (var i = 0; i < l.length; i++) { try { l[i](a, b); } catch (e) { console.error(e); } } },
      get rig() { var r = api.state.rig || {}; return { driving: !!r.driving, sessionOn: !!r.sessionOn, simRunning: !!r.simRunning, online: api.online }; },
      // the telemetry the visible layout needs; asked for only while iRacing is connected
      // a string is a named set irdash knows (/stream?set=race): the race screen asks for exactly its channels and no more
      telemetry: function (vars, hz) {
        if (typeof vars === 'string') { api.set = vars; api.vars = null; }
        else { api.set = ''; api.vars = vars && vars.length ? vars.slice() : null; }
        if (hz) api.hz = hz; if (api.connected) open('live');
      },
      json: jsonCache(function (u, o) { return fetch(u, o); }),
      fetch: paddockFetch(function (u, o) { return fetch(u, o); }),
    };
    api.reloadOnVersion = versionWatcher(api); api.onList = listWatcher(api);
    function allParts() { var c = {}; for (var k in api.state) c[k] = true; return c; }

    function open(mode) {
      if (location.protocol === 'file:') return;     // a page opened from disk (tests): nothing to connect to
      var url = '/stream?state=1&hz=' + api.hz + (mode !== 'live' ? '' : api.set ? '&set=' + api.set : api.vars ? '&vars=' + api.vars.join(',') : '');
      if (api.es && api.mode === mode && api.url === url) return;     // the same question: keep the one stream open
      if (api.es) { try { api.es.close(); } catch (e) { } }
      api.mode = mode; api.url = url;
      var es = api.es = new EventSource(url);
      es.onopen = function () { api.retryMs = 0; if (!api.online) { api.online = true; api.emit('online', true); } };
      es.onerror = function () {
        api.connected = false; if (api.online) { api.online = false; api.emit('online', false); }
        // the browser gives up for good on an answer that is not a stream (a 404, a 500 while irdash restarts): everything rides
        // this one connection, so open it again ourselves - 2 s, then longer, at most 30 s apart, never giving up
        if (es.readyState === 2 && api.es === es) {
          api.retryMs = Math.min(30000, (api.retryMs || 1000) * 2);
          var mode = api.mode;
          setTimeout(function () { if (api.es === es) { api.es = null; open(mode); } }, api.retryMs);
        }
      };
      es.addEventListener('state', function (e) {
        var m; try { m = JSON.parse(e.data); } catch (err) { return; }
        if (m.full) api.state = {};
        var changed = {};
        for (var k in m) { if (k === 'full') continue; api.state[k] = m[k]; if (k !== 'seq' && k !== 'now') { changed[k] = true; api.partAt[k] = Date.now(); } }
        api.state.recvAt = Date.now(); api.seq = m.seq;
        if (!api.online) { api.online = true; api.emit('online', true); }
        api.emit('state', api.state, m.full ? allParts() : changed);
      });
      es.addEventListener('status', function () { api.connected = false; api.emit('status', { connected: false }); });
      es.onmessage = function (e) {
        // the first frame of a session on the idle stream: ask again for the layout's variables
        if (api.mode !== 'live' && (api.vars || api.set)) { api.connected = true; open('live'); return; }
        api.connected = true;
        if (!api.ls.frame.length) return;
        var f; try { f = JSON.parse(e.data); } catch (err) { return; }
        api.emit('frame', f.v || {});
      };
    }
    open('idle');
    return api;
  }

  // a page inside HOME's frame: the host's state and events; this page's own subscriptions end with the page
  function borrowed(h) {
    var offs = [], dead = false;
    var api = {
      __paddock: true, __borrowed: true, root: h,
      get state() { return h.state; }, get seq() { return h.seq; }, get online() { return h.online; },
      get rig() { return h.rig; }, at: function (p) { return h.at(p); },
      on: function (name, fn) {
        var off = h.on(name, function (a, b) { if (!dead) fn(a, b); });
        offs.push(off); return off;
      },
      telemetry: function () { },                    // a page over HOME draws no live layout
      json: jsonCache(function (u, o) { return fetch(u, o); }),
      fetch: paddockFetch(function (u, o) { return fetch(u, o); }),
    };
    api.reloadOnVersion = versionWatcher(api); api.onList = listWatcher(api);
    window.addEventListener('pagehide', function () { dead = true; offs.forEach(function (f) { try { f(); } catch (e) { } }); offs = []; });
    return api;
  }
})();
