// DS-1 mock: stands in for core.js and for irdash (fetch answers from the real data captured in home-data.js). Not shipped.
const $ = id => document.getElementById(id);
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function setText(el, s) { if (typeof el === 'string') el = $(el); s = s == null ? '' : String(s); if (el && el._t !== s) { el._t = s; el.textContent = s; } }
function setHTML(el, s) { if (typeof el === 'string') el = $(el); if (el && el._h !== s) { el._h = s; el.innerHTML = s; } }
(function () {
  const state = new URLSearchParams(location.search).get('state') || '';
  const M = JSON.parse(JSON.stringify(window.MOCK));
  M.home.hero.src = '../../paddock/home/corvette-z06-gt3r-le-mans.jpg';
  if (state === 'nopb') { M.home.pbs = []; M.home.pbCount = 0; }
  if (state === 'phone') { M.phone = M.phone || {}; M['phone/qr'].paired = 0; }
  if (state === 'long') { M.home.pbs[1].track = 'Autodromo Nazionale Monza Grand Prix Circuit'; M.home.last.track = 'Circuit des 24 Heures du Mans Bugatti Circuit'; }
  M.health.apps.forEach(a => { if (a.id === 'sim') a.state = 'off'; });   // the real health may be a pretend session of another test
  if (state === 'starting') { M.health.apps.forEach(a => { if (a.id === 'ui') a.state = 'off'; }); }
  const data = { '/home': M.home, '/career': M.career, '/health': M.health, '/phone/qr': M['phone/qr'], '/mydrive': M.mydrive };
  const real = window.fetch;
  window.fetch = function (url, o) {
    const u = String(url).split('?')[0];
    if (data[u]) return Promise.resolve({ ok: true, json: () => Promise.resolve(data[u]) });
    return real.call(window, url, o);
  };
})();
