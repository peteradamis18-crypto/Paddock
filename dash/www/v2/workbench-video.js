// Paddock Analysis Workbench - the VIDEO page and the small picture-in-picture (card W5, docs\DESIGN-workbench.md sections 3 and 4).
// His own lap, filmed by Paddock's recorder (dash\src\recorder.cs, docs\vault.md "Video"), kept in step with every display by ONE rule:
//     video time = the clip's lapStartOffset + the lap's time at the cursor      (the lap's time channel is the engine's D.A.t)
// Paused: the cursor (mouse, click, corner / event jump, deck) seeks the video. Playing (space, deck PLAY, 0.5 / 1 / 2 / 4x): the VIDEO is the clock and the
// cursor is read back from it every frame (requestVideoFrameCallback = the picture that is really on screen, else video.currentTime), so the two cannot drift.
// With the reference lap's clip too, both are shown side by side and kept together by distance (the reference is trimmed to its own place each frame).
// A tab exists only when the lap HAS a clip that plays (never a dead tab); the engine (workbench.js) reaches this file only through window.WBX.
(function () {
'use strict';
var X = window.WBX, WB = window.WB;
if (!X || !X.api || !WB) return;
var A = X.api, S = A.S, el = A.el, clamp = A.clamp, at = A.at, idxOf = A.idxOf, fmt = A.fmt, sgn = A.sgn, num = A.num;
var VID = { lap: null, ref: null, pip: false, wait: 0, wanted: false, force: -1, spot: -1, cover: [] };
var holder = el('div', 'vhold'); document.body.appendChild(holder);        // where a clip waits while no page shows it (loading, other pages)
var pipEl = null, clockCv = null;

// ---------- one clip: the <video>, its sidecar (lapStartOffset ...) and the sync rules ----------
function Clip(role, info) {
  this.role = role; this.info = info; this.off = +info.lapStartOffset || 0;
  this.ok = false; this.sane = false; this.blocked = false; this.shown = false; this.running = false; this.watching = false;
  this.lastSeek = NaN; this.fed = NaN; this.rvAt = 0; this.media = NaN; this.onok = null;
  var self = this, v = this.el = document.createElement('video');
  // only the header of the file is read until a page shows the clip (a lap's clip is 100 - 200 MB; most visits never look at it)
  v.muted = true; v.defaultMuted = true; v.preload = 'metadata'; v.playsInline = true; v.className = 'wbvid'; v.setAttribute('disablepictureinpicture', '');
  v.addEventListener('loadedmetadata', function () { if (!self.ok && v.duration > 0 && isFinite(v.duration) && v.videoWidth > 0) { self.ok = true; if (self.onok) self.onok(); } });
  v.addEventListener('error', function () { self.ok = false; });
  v.addEventListener('click', function () { WB.cmd('toggle-play'); });     // a click on the picture = play / pause
  holder.appendChild(v);
  v.src = '/vault/video?id=' + encodeURIComponent(info.id);
}
// resolves (true / false) when the clip's header is read (length, picture size), or after ms: a slow clip must not hold the other tabs back (it joins later through onok)
Clip.prototype.ready = function (ms) {
  var self = this;
  return new Promise(function (done) {
    if (self.ok) return done(true);
    var t = setTimeout(function () { self.onok = null; done(false); }, ms);
    self.onok = function () { clearTimeout(t); self.onok = null; done(true); };
    self.el.addEventListener('error', function () { clearTimeout(t); done(false); });
  });
};
// the video time that goes with lap index fi (fractional). The reference's clip uses the reference's own time at the same place (the page's rIdx: offset, time axis)
Clip.prototype.timeAt = function (fi) {
  var D = A.data();
  if (this.role === 'ref') return this.off + at(D.R.t, clamp(A.rIdx(fi), 0, D.n - 1));
  return this.off + at(D.A.t, fi);
};
// -1 before the first picture, +1 after the last, 0 inside the clip
Clip.prototype.rangeOf = function (v) { var d = this.el.duration, vs = +this.info.videoStart || 0; return v < vs - 0.02 ? -1 : v > d + 0.02 ? 1 : 0; };
Clip.prototype.rvOn = function () { return this.watching && this.rvAt > 0 && performance.now() - this.rvAt < 120; };
Clip.prototype.mount = function (parent) {
  this.el.preload = 'auto';                                         // now it is looked at: let it buffer
  parent.appendChild(this.el); this.shown = true; this.running = false; this.lastSeek = NaN; this.fed = NaN; this.watch();
};
Clip.prototype.unmount = function () { this.shown = false; this.running = false; this.lastSeek = NaN; try { this.el.pause(); } catch (x) { } holder.appendChild(this.el); };
// paused: show the picture for video time v (the nearest one when v is outside the clip). One seek at a time; the next frame asks again with the newest cursor.
Clip.prototype.seek = function (v) {
  var e = this.el, d = e.duration; if (!(d > 0)) return;
  var tgt = clamp(v, 0, d);
  if (tgt === this.lastSeek) return;
  if (Math.abs(tgt - e.currentTime) < 0.0005) { this.lastSeek = tgt; return; }
  this.lastSeek = tgt; try { e.currentTime = tgt; } catch (x) { }
};
Clip.prototype.start = function () {
  var e = this.el, self = this, v = this.timeAt(S.cur);
  this.running = true; this.fed = S.cur; this.lastSeek = NaN; this.blocked = false;
  if (Math.abs(e.currentTime - v) > 0.01) { this.lastSeek = clamp(v, 0, e.duration); try { e.currentTime = this.lastSeek; } catch (x) { } }
  e.playbackRate = S.speed;
  var p = e.play(); if (p && p.catch) p.catch(function () { self.blocked = true; self.running = false; });
};
Clip.prototype.stop = function () { this.running = false; this.lastSeek = NaN; try { this.el.pause(); } catch (x) { } };
// the picture that is really on screen: requestVideoFrameCallback runs just before the page is drawn, so the cursor and the frame always agree
Clip.prototype.watch = function () {
  var e = this.el, self = this;
  if (!e.requestVideoFrameCallback || this.watching) return;
  this.watching = true;
  var cb = function (now, md) {
    self.rvAt = performance.now(); self.media = md.mediaTime;
    if (self.role === 'lap' && self.running && drives() && Math.abs(S.cur - self.fed) < 1e-9) follow(self, md.mediaTime);
    if (self.shown) e.requestVideoFrameCallback(cb); else self.watching = false;
  };
  e.requestVideoFrameCallback(cb);
};

// ---------- the clock: while the video plays, the cursor is read back from it ----------
function drives() { var L = VID.lap; return !!(S.playing && !S.reverse && L && L.shown && L.ok && !L.blocked); }
function reverseSeek(C) {
  var now = performance.now();
  if (!C || now - (C.reverseAt || 0) < 100) return;
  C.reverseAt = now; C.seek(C.timeAt(S.cur));
}
function follow(L, v) {
  var D = A.data(), fi = idxOf(D.A.t, v - L.off);                   // before the line the cursor waits at the line; after the lap it stops at the finish
  S.cur = fi; L.fed = fi; A.need.o = true;
  if (A.zoomed() && (S.cur > S.z1 - (S.z1 - S.z0) * 0.02 || S.cur < S.z0)) { var w = S.z1 - S.z0; A.setZoom(S.cur - w * 0.2, S.cur + w * 0.8); }   // page the window on, like the engine
  if (fi >= D.n - 1 || L.el.ended) { S.playing = false; A.modeLine(); }
}
// the reference's clip: same speed, trimmed every frame to the place the lap's cursor is at (distance, or the same moment on the time axis)
function slave(R, master) {
  var e = R.el, v = R.timeAt(S.cur), d = e.duration;
  if (!master || v < 0 || v >= d - 0.05) { if (R.running) R.stop(); if (S.playing && S.reverse) reverseSeek(R); else R.seek(v); return; }
  if (!R.running) { R.running = true; R.lastSeek = NaN; if (Math.abs(e.currentTime - v) > 0.01) { try { e.currentTime = clamp(v, 0, d); } catch (x) { } } e.playbackRate = S.speed; var p = e.play(); if (p && p.catch) p.catch(function () { R.running = false; }); return; }
  var err = v - e.currentTime;
  if (Math.abs(err) > 0.25) { try { e.currentTime = clamp(v, 0, d); } catch (x) { } }
  else e.playbackRate = clamp(S.speed * (1 + err * 4), S.speed * 0.5, S.speed * 2);
}
function tick() {
  var D = A.data(), L = VID.lap; if (!D || !L) return;
  if (VID.wait > 0 && --VID.wait === 0) pipPlace();
  if (!S.playing) L.blocked = false;                                // an autoplay refusal is tried again at the next PLAY
  if (!L.shown) return;
  var master = drives();
  if (master) {
    if (!L.running) {
      if (L.timeAt(S.cur) >= L.el.duration - 0.05) { S.playing = false; A.modeLine(); return; }      // already at the end of the video: nothing to play
      L.start();
    }
    if (L.el.playbackRate !== S.speed) L.el.playbackRate = S.speed;
    if (!(Math.abs(S.cur - L.fed) < 1e-9)) { L.lastSeek = clamp(L.timeAt(S.cur), 0, L.el.duration); try { L.el.currentTime = L.lastSeek; } catch (x) { } L.fed = S.cur; }   // a click or a jump while playing: the video goes there and plays on
    else if (!L.rvOn()) follow(L, L.el.currentTime);
  } else {
    if (L.running) L.stop();
    if (S.playing && S.reverse) reverseSeek(L); else L.seek(L.timeAt(S.cur));
  }
  if (VID.ref && VID.ref.shown && VID.ref.ok) slave(VID.ref, master);
}

// ---------- displays ----------
function VideoView(box, title, clip) {
  A.Display.call(this, box, title); this.kind = 'video'; this.clip = clip; this.title0 = title; this.last = null;
  this.cs.canvas.remove(); this.co.canvas.remove(); this.stage.className = 'stage vstage';
  clip.mount(this.stage);
  var self = this; A.hook(function () { self.update(); });
}
VideoView.prototype = Object.create(A.Display.prototype);
VideoView.prototype.update = function () {
  var rg = this.clip.rangeOf(this.clip.timeAt(S.cur));
  if (rg === this.last) return; this.last = rg;
  this.ph.innerHTML = this.title0 + (rg < 0 ? ' · <span class="warn">before the video</span>' : rg > 0 ? ' · <span class="warn">after the video</span>' : '');
};

// the six numbers a driver reads at the cursor, big (the video is the thing he looks at)
var TILES = [['SPEED ' + A.SPD.u.toUpperCase(), 'kmh', 0], ['GEAR', 'Gear', 0], ['THROTTLE %', 'thrPct', 0], ['BRAKE %', 'brkPct', 0], ['STEERING °', 'steerDeg', 0], ['GAP s', 'gap', 3]];
function gearTxt(g) { g = Math.round(g); return g < 0 ? 'R' : g === 0 ? 'N' : String(g); }
function VidTiles(box, strip) {
  A.Display.call(this, box, 'At the cursor'); this.kind = 'vtiles'; this.cs.canvas.remove(); this.co.canvas.remove();
  this.stage.className = 'stage vtiles ' + (strip ? 'strip' : 'grid');
  var self = this; this.cells = TILES.map(function (t) {
    var d = el('div', 'vt'); d.innerHTML = '<div class="vl">' + t[0] + '</div><div class="vv"></div><div class="vr"></div>'; self.stage.appendChild(d);
    return { v: d.children[1], r: d.children[2], key: t[1], dec: t[2], a: '', b: '', c: '' };
  });
  A.hook(function () { self.update(); });
}
VidTiles.prototype = Object.create(A.Display.prototype);
VidTiles.prototype.update = function () {
  var D = A.data(), ci = Math.round(S.cur), ri = D.R ? clamp(Math.round(A.rIdx(S.cur)), 0, D.n - 1) : 0;
  this.cells.forEach(function (t) {
    var val = '–', ref = '', col = 'vv';
    if (t.key === 'gap') {
      if (D.gap) {
        var g = D.gap[ci] - (S.refCur != null ? D.gap[Math.round(S.refCur)] : 0), zero = Math.abs(g) < 0.0005;
        val = sgn(g, 3); col = zero ? 'vv' : 'vv ' + (g > 0 ? 'loss' : 'gain'); ref = zero ? 'level' : g > 0 ? 'behind' : 'ahead';
      } else ref = 'no reference';
    } else {
      var a = D.A.c[t.key], r = D.R ? D.R.c[t.key] : null;
      if (a) {
        var show = function (x) { return t.key === 'Gear' ? gearTxt(x) : num(x, t.dec); };
        val = show(a[ci]);
        if (r) ref = 'ref ' + show(r[ri]) + (t.key === 'Gear' ? '' : ' · ' + sgn(a[ci] - r[ri], t.dec));      // the reference's value, and how far this lap is from it
      }
    }
    if (val !== t.a) { t.v.textContent = val; t.a = val; }
    if (col !== t.c) { t.v.className = col; t.c = col; }
    if (ref !== t.b) { t.r.textContent = ref; t.b = ref; }
  });
};

function fit(mw, mh, asp) { var w = mw, h = Math.round(w / asp); if (h > mh) { h = mh; w = Math.round(h * asp); } return { w: w, h: h }; }
function build() {
  var D = A.data(), H = D.head, L = VID.lap, R2 = VID.ref && VID.ref.ok && VID.ref.sane && D.R ? VID.ref : null;
  var asp = (L.el.videoWidth / L.el.videoHeight) || 16 / 9;
  var mt = function () { return 'Map · coloured by ' + (S.mapColour === 'gap' ? 'gap' : S.mapColour === 'speed' ? 'speed' : A.CAT[S.mapColour] ? A.CAT[S.mapColour].label : S.mapColour); };
  var lapTitle = 'Video · <b>this lap</b> · lap ' + H.lap.lap + ' · ' + fmt(H.lap.time);
  if (!R2) {                                   // one clip: the picture large, the map and the numbers beside it, the traces under it
    var f = fit(1056, 594, asp);
    new VideoView({ x: 32, y: 126, w: f.w, h: f.h }, lapTitle, L);
    var map = new A.MapView({ x: 1120, y: 126, w: 768, h: 300 }, mt()); map.mapTitle = mt;
    new VidTiles({ x: 1120, y: 462, w: 768, h: 258 }, false);
    new A.Traces({ x: 32, y: 762, w: 1856, h: 294 }, '', A.scaleRows([
      { k: 'SPEED', key: 'kmh', h: 70, lo: A.SPD.lo, hi: A.SPD.hi }, { k: 'THROTTLE %', key: 'thrPct', h: 50, lo: 0, hi: 100 },
      { k: 'BRAKE % · ABS', key: 'brkPct', kind: 'brakeabs', h: 50, lo: 0, hi: 100 }, { k: 'STEERING °', key: 'steerDeg', h: 50, lo: -90, hi: 90 }], 294));
  } else {                                     // two-up: this lap and the reference side by side (kept together by distance), the numbers in a strip, the gap row too
    var g = fit(672, 378, asp);
    new VideoView({ x: 32, y: 126, w: g.w, h: g.h }, lapTitle, L);
    new VideoView({ x: 720, y: 126, w: g.w, h: g.h }, 'Video · <span class="r">reference</span> · lap ' + H.ref.lap + ' · ' + A.dateWord(H.ref.date) + ' · ' + fmt(H.ref.time), R2);
    var map2 = new A.MapView({ x: 1424, y: 126, w: 464, h: 378 }, mt()); map2.mapTitle = mt;
    new VidTiles({ x: 32, y: 540, w: 1856, h: 100 }, true);
    new A.Traces({ x: 32, y: 676, w: 1856, h: 380 }, '', A.scaleRows([
      { k: 'GAP s', kind: 'gap', h: 56, lo: -0.6, hi: 0.6 }, { k: 'SPEED', key: 'kmh', h: 70, lo: A.SPD.lo, hi: A.SPD.hi }, { k: 'THROTTLE %', key: 'thrPct', h: 50, lo: 0, hi: 100 },
      { k: 'BRAKE % · ABS', key: 'brkPct', kind: 'brakeabs', h: 50, lo: 0, hi: 100 }, { k: 'STEERING °', key: 'steerDeg', h: 50, lo: -90, hi: 90 }], 380));
  }
}

// ---------- the small video on the other pages (key V, the SMALL VIDEO chip) ----------
function usable() { return !!(VID.lap && VID.lap.ok && VID.lap.sane); }
function pipBox() { if (!pipEl) { pipEl = el('div', 'pip'); document.body.appendChild(pipEl); } return pipEl; }
function pipWanted() { return usable() && VID.pip && S.page !== 'video'; }
function pipShow() {                                               // after every page build
  var L = VID.lap, b = pipBox();
  if (!pipWanted()) { if (L && L.shown && L.el.parentNode === b) L.unmount(); b.className = 'pip'; return; }
  var asp = (L.el.videoWidth / L.el.videoHeight) || 16 / 9, w = 384, h = Math.round(w / asp);
  b.style.width = w + 'px'; b.style.height = h + 'px'; b.className = 'pip wait';   // hidden until the page has drawn and a spot is chosen
  L.mount(b); VID.wait = 3;
}
// the corner that covers the least text on this page (bottom right first)
function pipPlace() {
  var b = pipBox(), w = b.offsetWidth, h = b.offsetHeight; if (!pipWanted()) return;
  var boxes = WB.textBoxes().concat(WB.domBoxes()), spots = [[1888 - w, 1056 - h], [32, 1056 - h], [1888 - w, 126], [32, 126]], best = 0, bestA = 1e12, cover = [];
  spots.forEach(function (s, k) {
    var area = 0, n = 0; boxes.forEach(function (t) { var ox = Math.min(s[0] + w, t.x + t.w) - Math.max(s[0], t.x), oy = Math.min(s[1] + h, t.y + t.h) - Math.max(s[1], t.y); if (ox > 0 && oy > 0) { area += ox * oy; n++; } });
    cover.push(n);
    if (area < bestA - 1) { bestA = area; best = k; }
  });
  if (VID.force >= 0) best = VID.force;                              // Shift+V moved it by hand: it stays there until V puts it away
  b.style.left = spots[best][0] + 'px'; b.style.top = spots[best][1] + 'px'; b.className = 'pip on'; VID.spot = best; VID.cover = cover;
}
function headChip() {
  var b = document.getElementById('pipbtn'); if (!b) return;
  b.style.display = usable() && S.page !== 'video' ? '' : 'none'; b.className = 'addch' + (VID.pip ? ' on' : '');
  if (!b._on) { b._on = true; b.addEventListener('click', function () { WB.cmd('video-pip'); }); }
}

// ---------- finding the clip ----------
// the server finds a lap's clip by the Vault's lap id, or by "<telemetry file>.ibt:<lap>" (dash\src\recorder.cs ClipFor)
// Why the clip count first: with no recorder clip at all /vault/videoinfo can only answer 404 (a red console line on every open).
var recSeen = { at: 0, any: true };
function recAnyClips() {
  if (Date.now() - recSeen.at < 10000) return Promise.resolve(recSeen.any);
  return A.fetchJson('/vault/recorder').then(function (j) { return !(j && typeof j.clips === 'number' && j.clips === 0); }, function () { return true; })
    .then(function (any) { recSeen = { at: Date.now(), any: any }; return any; });
}
function clipFor(key, role, lapNo, lapTime) {
  if (!key) return Promise.resolve(null);
  return recAnyClips().then(function (any) { if (!any) return null; return clipInfo(key, role, lapNo, lapTime); });
}
function clipInfo(key, role, lapNo, lapTime) {
  return A.fetchJson('/vault/videoinfo?id=' + encodeURIComponent(key)).then(function (info) {
    if (!info || !info.id || info.error) return null;
    var len = (+info.lapEndOffset) - (+info.lapStartOffset);
    var c = new Clip(role, info);
    c.sane = info.lap === lapNo && (info.truncated === true || Math.abs(len - lapTime) < 0.5);   // another lap's clip, or a wrong one, is never shown
    if (!c.sane) return null;
    return c.ready(3000).then(function () { return c; });
  }).catch(function () { return null; });
}
function wantPage() { if (A.P.get('page') === 'video' && S.page !== 'video' && !VID.wanted && usable()) { VID.wanted = true; WB.cmd('page', 'video'); } }
function loadVideo() {
  if (!A.LIVE) return Promise.resolve();
  var D = A.data(), H = D.head, id = A.P.get('id') || '';
  var lapKey = /\.ibt$/i.test(id) ? id + ':' + H.lap.lap : id;       // a Vault lap id names its own lap
  var refKey = H.ref && H.ref.file ? H.ref.file + ':' + H.ref.lap : '';
  return Promise.all([clipFor(lapKey, 'lap', H.lap.lap, H.lap.time), refKey ? clipFor(refKey, 'ref', H.ref.lap, H.ref.time) : Promise.resolve(null)]).then(function (r) {
    if (!r[0]) return;
    VID.lap = r[0]; VID.ref = r[1];
    // a clip that was slow to open joins the page when it is ready (the tab appears, or the second picture is added)
    if (!VID.lap.ok) VID.lap.onok = function () { A.header(); wantPage(); };
    if (VID.ref && !VID.ref.ok) VID.ref.onok = function () { if (S.page === 'video') WB.cmd('page', 'video'); };
  });
}

X.add({ id: 'video', name: 'VIDEO', avail: usable, build: build });
X.before.push(function () { [VID.lap, VID.ref].forEach(function (c) { if (c && c.shown) c.unmount(); }); });
X.after.push(pipShow);
X.head.push(headChip);
X.ticks.push(tick);
X.drives = drives;
X.loads.push(loadVideo);
X.keys.v = function () { WB.cmd('video-pip'); };
X.keys.V = function () { WB.cmd('video-pip-corner'); };             // Shift+V: the next corner (the automatic choice covers the least text, but it is his page)
X.cmds['video-pip'] = function (a) {                              // '' toggles, 1 / on, 0 / off
  if (!usable() || S.page === 'video') return;                    // the VIDEO page has the big picture already
  VID.pip = a === '' || a === 'toggle' ? !VID.pip : (a === '1' || a === 'on');
  if (!VID.pip) VID.force = -1;
  pipShow(); headChip();
};
X.cmds['video-pip-corner'] = function () {
  if (!usable() || S.page === 'video') return;
  VID.force = VID.pip && VID.spot >= 0 ? (VID.spot + 1) % 4 : VID.force; VID.pip = true;
  pipShow(); headChip();
};

// ---------- for the tests: what the video is doing, and the clock burned into its picture (the test clips carry a 32-block binary clock in the top-left) ----------
WB.video = function () {
  var L = VID.lap, R = VID.ref, D = A.data(), b = pipEl ? pipEl.getBoundingClientRect() : null;
  function one(c) {
    if (!c) return null;
    var tg = D && (c.role !== 'ref' || D.R) ? c.timeAt(S.cur) : null;
    return { id: c.info.id, ok: c.ok, sane: c.sane, shown: c.shown, running: c.running, blocked: c.blocked, time: c.el.currentTime, target: tg, off: c.off, end: +c.info.lapEndOffset, dur: c.el.duration,
      paused: c.el.paused, seeking: c.el.seeking, rate: c.el.playbackRate, range: tg == null ? 0 : c.rangeOf(tg), w: c.el.videoWidth, h: c.el.videoHeight, rvfc: !!c.el.requestVideoFrameCallback, rvOn: c.rvOn(), media: c.media };
  }
  return { lap: one(L), ref: one(R), pip: VID.pip, pipOn: !!(pipEl && /\bon\b/.test(pipEl.className)), pipRect: b && b.width ? { x: b.left, y: b.top, w: b.width, h: b.height } : null, spot: VID.spot, cover: VID.cover, forced: VID.force,
    cur: S.cur, curT: D ? at(D.A.t, S.cur) : null, page: S.page, drives: drives() };
};
WB.videoClock = function (role) {
  var c = role === 'ref' ? VID.ref : VID.lap; if (!c || !c.ok || c.el.readyState < 2 || !c.el.videoWidth) return null;
  clockCv = clockCv || document.createElement('canvas'); clockCv.width = c.el.videoWidth; clockCv.height = c.el.videoHeight;
  var g = clockCv.getContext('2d'); g.drawImage(c.el, 0, 0); var px = g.getImageData(0, 16, 640, 1).data, ms = 0;
  for (var i = 0; i < 32; i++) if (px[(i * 20 + 10) * 4] > 128) ms += Math.pow(2, i);
  return ms;
};
})();
