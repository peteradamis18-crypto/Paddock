// Paddock Analysis Workbench - SEE IN iRACING (P2, dash\src\replayjump.cs): a small button on every event row and every pass takes iRacing's own replay to that
// moment, 3 s before it. The buttons exist only while the sim has THIS session open and he is out of the car (the page asks every few seconds; otherwise they
// stay hidden: no dead buttons). (MAKE SHARE VIDEO went with the VIDEO page in W4-5.) Everything goes through window.WBX (workbench.js).
(function () {
'use strict';
var X = window.WBX, WB = window.WB;
if (!X || !X.api || !WB) return;
var A = X.api, S = A.S;
var SH = { jump: null, jumpAt: 0, last: null };
function enc(s) { return encodeURIComponent(s); }
function getJson(u) { return fetch(u, { cache: 'no-store' }).then(function (r) { return r.text().then(function (t) { var j = null; try { j = JSON.parse(t); } catch (e) { } return j || { error: 'no answer' }; }); }); }

// ---------- SEE IN iRACING ----------
function probeJump() {
  if (!A.LIVE) return;
  var D = A.data(), id = A.P.get('id') || ''; if (!D || !D.head || !id) return;
  SH.jumpAt = Date.now();
  getJson('/share/jump?id=' + enc(id) + '&lap=' + D.head.lap.lap + '&t=1&dry=1').then(function (j) {
    SH.jump = j; document.body.classList.toggle('canjump', !!(j && j.ok));
  });
}
// asked again each time a page is drawn (no timer: nothing here polls irdash)
X.after.push(function () { if (Date.now() - SH.jumpAt > 3000) probeJump(); });
// o: { t: seconds into this lap } or { st: session time }, car: 'me' | CarIdx, short: the narrow words
X.jumpBtn = function (o) {
  var b = document.createElement('span'); b.className = 'sj'; b.textContent = o.short ? 'iRACING' : 'SEE IN iRACING';
  b.addEventListener('click', function (e) {
    e.stopPropagation();
    var D = A.data(), id = A.P.get('id') || '';
    var u = '/share/jump?id=' + enc(id) + '&lap=' + D.head.lap.lap + (o.st != null ? '&st=' + o.st : '&t=' + o.t) + (o.car != null ? '&car=' + o.car : '');
    getJson(u).then(function (j) {
      var was = o.short ? 'iRACING' : 'SEE IN iRACING';
      b.textContent = j && j.ok && j.sent ? 'SENT' : (j && (j.why || j.error)) || 'NOT NOW';
      SH.last = j; setTimeout(function () { b.textContent = was; }, j && j.ok ? 1200 : 3500);
    });
  });
  return b;
};

// for the tests
WB.share = function () { return { jump: SH.jump, last: SH.last, canjump: document.body.classList.contains('canjump') }; };
})();
