/* The one-line "what that deck key just did" message. irdeck tells irdash (/api/keymsg), the page polls /keymsg every 400 ms and shows a
   NEW message for 4 seconds, bottom-centre, over HOME and over the in-car layouts. No sound. Stops polling while the page is hidden.
   A message older than 4 s (irdash says its age, so this page's clock is not trusted) is never shown, e.g. after a page reload. */
(function () {
  'use strict';
  var el = document.getElementById('keyMsg');
  if (!el) return;
  var SHOW_MS = 4000, POLL_MS = 400;
  var seen = -1, hideT = 0, timer = 0, busy = false;

  function show(m, ageMs) {
    var kind = m.kind === 'wait' || m.kind === 'no' ? m.kind : 'ok';
    el.textContent = String(m.text).slice(0, 80);           // text only, never markup
    el.className = kind;
    el.setAttribute('data-key', String(m.key || ''));
    void el.offsetWidth;                                    // restart the fade when one message replaces another
    el.className = kind + ' on';
    clearTimeout(hideT);
    hideT = setTimeout(function () { el.className = kind; }, Math.max(600, SHOW_MS - (ageMs || 0)));
  }

  function poll() {
    if (document.hidden || busy) return;
    busy = true;
    fetch('/keymsg', { cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; }).then(function (m) {
      busy = false;
      if (!m) return;
      var s = +m.seq || 0;
      if (s === seen) return;
      seen = s;
      if (!s || !m.text) return;
      var age = +m.ageMs || 0;
      if (age >= SHOW_MS) return;
      show(m, age);
    }).catch(function () { busy = false; });
  }

  function start() { if (!timer) { poll(); timer = setInterval(poll, POLL_MS); } }
  function stop() { if (timer) { clearInterval(timer); timer = 0; } }
  document.addEventListener('visibilitychange', function () { if (document.hidden) stop(); else start(); });
  if (!document.hidden) start();
  window.KeyMsg = { poll: poll, show: show, SHOW_MS: SHOW_MS };
})();
