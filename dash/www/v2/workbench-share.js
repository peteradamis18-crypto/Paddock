// Paddock Analysis Workbench - SHARE and SEE IN iRACING (P2, dash\src\share.cs and dash\src\replayjump.cs).
//   MAKE SHARE VIDEO (the chip in the header of the VIDEO page): asks the PC to burn the data overlay into a copy of this lap's video, shows the progress,
//     and when it is done the same chip opens the folder with the file selected (this PC only; the phone saves / shares it from its own clip screen).
//   SEE IN iRACING (a small button on every event row and every pass): takes iRacing's own replay to that moment, 3 s before it. The buttons exist only
//     while the sim has THIS session open and he is out of the car (the page asks every few seconds; otherwise they stay hidden: no dead buttons).
// Everything goes through window.WBX (workbench.js); the files it needs from the server are /share/status, /share/make, /share/open and /share/jump.
(function () {
'use strict';
var X = window.WBX, WB = window.WB;
if (!X || !X.api || !WB) return;
var A = X.api, S = A.S;
var SH = { st: null, jump: null, jumpAt: 0, last: null };
function enc(s) { return encodeURIComponent(s); }
function getJson(u) { return fetch(u, { cache: 'no-store' }).then(function (r) { return r.text().then(function (t) { var j = null; try { j = JSON.parse(t); } catch (e) { } return j || { error: 'no answer' }; }); }); }

// ---------- the SHARE chip ----------
function lapKey() {
  var D = A.data(); if (!D || !D.head) return '';
  var id = A.P.get('id') || '';
  return /\.ibt$/i.test(id) ? id + ':' + D.head.lap.lap : id;       // the same names the VIDEO page uses for the clip
}
function chip() {
  var b = document.getElementById('sharebtn'); if (!b) return;
  var show = A.LIVE && S.page === 'video';
  b.style.display = show ? '' : 'none';
  if (!show) return;
  var st = SH.st || { state: 'none' }, txt = 'MAKE SHARE VIDEO', cls = 'addch', tip = '';
  if (st.state === 'queued' || st.state === 'waiting') { txt = st.state === 'waiting' ? 'WAITING' : 'IN LINE'; tip = st.reason || ''; }
  else if (st.state === 'making') { txt = 'MAKING ' + Math.round(st.pct || 0) + ' %'; cls += ' on'; tip = st.reason || ''; }
  else if (st.state === 'done') { txt = 'SHOW SHARE VIDEO'; tip = ''; }
  else if (st.state === 'error') { txt = 'TRY AGAIN'; tip = st.reason || st.error || ''; }
  if (b.textContent !== txt) b.textContent = txt;
  b.className = cls; b.title = tip;
  if (!b._on) { b._on = true; b.addEventListener('click', click); }
}
function click() {
  var k = lapKey(), st = SH.st || { state: 'none' }; if (!k) return;
  if (st.state === 'done') { getJson('/share/open?id=' + enc(k)).then(function (j) { if (j && j.error) { SH.st = { state: 'error', reason: j.error }; chip(); } }); return; }
  if (st.state === 'none' || st.state === 'error') getJson('/share/make?id=' + enc(k)).then(function (j) { SH.st = j && j.state ? j : { state: 'error', reason: (j && j.error) || 'Could not start' }; chip(); });
}
function poll() {
  if (!A.LIVE || S.page !== 'video') return;
  var k = lapKey(); if (!k) return;
  getJson('/share/status?id=' + enc(k)).then(function (j) { if (j && j.state) { SH.st = j; chip(); } });
}
setInterval(poll, 1500);
X.after.push(function () { chip(); if (S.page === 'video') poll(); });
X.head.push(chip);

// ---------- SEE IN iRACING ----------
function probeJump() {
  if (!A.LIVE) return;
  var D = A.data(), id = A.P.get('id') || ''; if (!D || !D.head || !id) return;
  SH.jumpAt = Date.now();
  getJson('/share/jump?id=' + enc(id) + '&lap=' + D.head.lap.lap + '&t=1&dry=1').then(function (j) {
    SH.jump = j; document.body.classList.toggle('canjump', !!(j && j.ok));
  });
}
setInterval(probeJump, 5000);
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
WB.share = function () { return { st: SH.st, jump: SH.jump, last: SH.last, canjump: document.body.classList.contains('canjump'), chip: (function () { var b = document.getElementById('sharebtn'); return b ? { text: b.textContent, shown: b.style.display !== 'none', title: b.title } : null; })() }; };
})();
