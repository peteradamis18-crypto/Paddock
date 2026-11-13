// fake-data.js - a pretend app/lib/data.js (W0-5) for page tests that open a page from disk with irdash mocked.
// Load it before the page's scripts. The test hands state over the way irdash's push does:
//   __push({ health: {...}, recorder: {...} })     one push with those parts (the page's data.on('state') listeners run at once)
//   __watch(() => ({ nav: NAV['/nav'], ... }))    every 200 ms, push the parts whose words changed (a mock irdash's flags, pushed)
// data.fetch / data.json go through the page's own (mocked) fetch.
(function () {
  'use strict';
  var ls = [];
  function all() { var c = {}; for (var k in window.data.state) c[k] = true; return c; }
  window.data = {
    __paddock: true, state: {}, seq: 0, online: true, partAt: {},
    get rig() { var r = window.data.state.rig || {}; return { driving: !!r.driving, sessionOn: !!r.sessionOn, simRunning: !!r.simRunning, online: true }; },
    at: function (p) { return window.data.partAt[p] || 0; },
    on: function (n, f) { if (n === 'state') { ls.push(f); if (window.data.seq > 0) f(window.data.state, all()); } return function () { var i = ls.indexOf(f); if (i >= 0) ls.splice(i, 1); }; },
    json: function (u) { return fetch(u, { cache: 'no-store' }).then(function (r) { return r.json(); }); },
    fetch: function (u, o) { return fetch(u, o); },
    telemetry: function () { }, reloadOnVersion: function () { },
    onList: function (name, fn) { var seen = null; return window.data.on('state', function (st, ch) { if (!ch.lists || !st.lists) return; var v = st.lists[name]; if (seen === null) { seen = v; return; } if (v !== seen) { seen = v; fn(); } }); },
  };
  window.__push = function (m) {
    var ch = {};
    for (var k in m) { window.data.state[k] = m[k]; if (k !== 'now') { ch[k] = true; window.data.partAt[k] = Date.now(); } }
    window.data.seq++;
    ls.slice().forEach(function (f) { try { f(window.data.state, ch); } catch (e) { console.error(e); } });
  };
  window.__watch = function (get) {
    var last = {};
    function look() {
      var parts = get(), m = {}, any = false;
      for (var k in parts) { var s = JSON.stringify(parts[k]); if (s !== last[k]) { last[k] = s; m[k] = JSON.parse(s); any = true; } }
      if (any) window.__push(m);
    }
    setTimeout(look, 0); setInterval(look, 200);
  };
})();
