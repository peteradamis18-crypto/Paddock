/* The one-line "what that deck key just did" message. irdeck tells irdash (/api/keymsg), irdash pushes it to the page (app/lib/data.js,
   W0-5; it used to be polled every 400 ms) and the page shows a NEW message for 4 seconds, bottom-centre, over HOME and over the in-car layouts. No sound.
   A message older than 4 s (irdash says its age, so this page's clock is not trusted) is never shown, e.g. after a page reload. */
(function () {
  'use strict';
  var el = document.getElementById('keyMsg');
  if (!el) return;
  var SHOW_MS = 4000;
  var seen = -1, hideT = 0;

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

  // W0-5: irdash pushes the message the moment irdeck sends it (state part "keymsg"); the age is irdash's own clock: now - at
  function take(m, now) {
    if (!m) return;
    var s = +m.seq || 0;
    if (s === seen) return;
    seen = s;
    if (!s || !m.text) return;
    var age = m.ageMs != null ? +m.ageMs : (+now && +m.at ? Math.max(0, +now - +m.at) : 0);
    if (age >= SHOW_MS) return;
    show(m, age);
  }
  data.on('state', function (st, ch) { if (ch.keymsg) take(st.keymsg, st.now); });
  window.KeyMsg = { take: take, show: show, SHOW_MS: SHOW_MS };
})();
