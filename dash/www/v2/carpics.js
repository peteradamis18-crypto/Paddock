// iRacing's OWN car pictures (CP-1). No drawing, no recolouring: the small picture iRacing's UI shows for each car, kept in paddock\cars by irdash
// (cars.cs, /cars/<key>.jpg). A car without a picture gets NOTHING (clean text). Used by the RACE tower and header chips, CAREER race rows and HOME.
//   PCarPic.html({ path: CarPath, w: width in px, title })  -> a small framed picture, or '' when there is none
//   PCarPic.ready  a promise that is done once the list of pictures on disk is read; the pages draw before that, so html() leaves an empty frame
//                  and refresh() fills the frames in (and removes the frames of cars that have no picture).
// The picture is a 16:9 studio shot (the car on a white floor, a blurred crowd of its livery behind). It is cut to the car (a 2.75 : 1 frame) and its
// frame is a small rounded tile with a hairline edge, like the tiles in iRacing's own UI, so the white studio floor reads as a picture and not as a
// stray white box on the black page. The pixels inside are iRacing's, untouched (no tint, no mask over the car).
(function (root) {
'use strict';
var ASPECT = 2.75;                         // frame width : height
var known = null, asked = {}, ready = null;
// the tests open the pages from files on disk (file://); ?carbase=http://localhost:8199 points the picture requests at the running irdash. Only this PC, nothing else.
var BASE = (function () { var m = /[?&]carbase=([^&]+)/.exec(String(root.location && root.location.search || '')), b = m ? decodeURIComponent(m[1]) : ''; return /^http:\/\/(localhost|127\.0\.0\.1):[0-9]{2,5}$/.test(b) ? b : ''; })();

function key(path) { return String(path == null ? '' : path).toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 80); }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

function style() {
  if (document.getElementById('cpicStyle')) return;
  var s = document.createElement('style'); s.id = 'cpicStyle';
  s.textContent =
    '.cpic{position:relative;display:inline-block;flex:none;vertical-align:middle;overflow:hidden;background:#0c0c0e;box-shadow:0 0 0 1px rgba(244,241,234,.16)}' +
    '.cpic img{position:absolute;left:-2.08%;top:-48.4%;width:104.17%;height:auto;display:block;max-width:none;user-select:none;-webkit-user-drag:none}';
  (document.head || document.documentElement).appendChild(s);
}

function load() {
  if (ready) return ready;
  ready = fetch(BASE + '/cars/manifest.json', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (j) {
    known = {}; (j.keys || []).forEach(function (k) { known[k] = 1; });
  }).catch(function () { known = {}; });
  return ready;
}
// a car with no picture on disk: ask irdash once (it fetches it from iRacing's image server when no session is on); the picture shows from the next draw on
function ask(path, k) {
  if (asked[k]) return; asked[k] = 1;
  try { fetch(BASE + '/cars/need?path=' + encodeURIComponent(path), { cache: 'no-store' }).catch(function () { }); } catch (e) { }
}

function frame(k, w, title, withImg, path) {
  var h = Math.round(w / ASPECT * 10) / 10, rad = Math.max(4, Math.min(8, Math.round(h * 0.2)));
  return '<div class="cpic" data-k="' + k + '" data-p="' + esc(path) + '" style="width:' + w + 'px;height:' + h + 'px;border-radius:' + rad + 'px"' + (title ? ' title="' + esc(title) + '"' : '') + '>' +
    (withImg ? '<img src="' + BASE + '/cars/' + k + '.jpg" alt="" draggable="false" onerror="var p=this.parentNode;if(p&&p.parentNode)p.parentNode.removeChild(p)">' : '') + '</div>';
}

function html(o) {
  o = o || {}; var k = key(o.path); if (!k) return '';
  style();
  if (known === null) { load().then(refresh); return frame(k, o.w || 64, o.title, false, o.path); }
  if (!known[k]) { ask(o.path, k); return ''; }
  return frame(k, o.w || 64, o.title, true, o.path);
}

// after the list is read: fill every empty frame that has a picture, drop the ones that have none
function refresh() {
  var list = document.querySelectorAll('.cpic[data-k]'), i, el, k;
  for (i = 0; i < list.length; i++) {
    el = list[i]; k = el.getAttribute('data-k');
    if (known && known[k]) { if (!el.querySelector('img')) { var im = document.createElement('img'); im.alt = ''; im.draggable = false; im.onerror = function () { var p = this.parentNode; if (p && p.parentNode) p.parentNode.removeChild(p); }; im.src = BASE + '/cars/' + k + '.jpg'; el.appendChild(im); } }
    else if (known && el.parentNode) { ask(el.getAttribute('data-p'), k); el.parentNode.removeChild(el); }
  }
}

// is there any point in leaving room for pictures? true while the list is not read yet, then only when one of these CarPaths has a picture
function any(paths) {
  if (known === null) return true;
  for (var i = 0; i < (paths || []).length; i++) { var k = key(paths[i]); if (k && known[k]) return true; }
  return false;
}

root.PCarPic = { html: html, key: key, refresh: refresh, any: any, ready: function () { return load(); }, known: function () { return known; }, ASPECT: ASPECT };
load();
})(window);
