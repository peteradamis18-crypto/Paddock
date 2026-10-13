// Paddock's own car pictures (card P4). iRacing keeps its car art packed (nothing to show from disk), so Paddock draws seven plain side-view
// silhouettes - GT3, GT4, prototype (LMP), GTP, open-wheel, stock car, touring / road car - and paints each one in the driver's REAL livery colours
// from iRacing's session text: DriverInfo CarDesignStr "pattern,colour1,colour2,colour3" (hex). colour1 = the body, colour2 = a flank stripe and the
// wing / splitter, colour3 = a thin accent line (and the helmet on open-wheel cars). The pattern number is not drawn (no invented art). A driver
// without a design (an old race log) gets his class colour as the body and no stripes. Facts from iRacing's data only; no pictures, no downloads.
// Used by the RACE tower (workbench-race.js), CAREER (workbench-career.js) and HOME (home.js). Plain ES5 so every page that loads it can use it.
(function (root) {
'use strict';
var CARS_DRAWN = false;   // PL-1: off. true = every page shows the drawn cars again (see the end of this file)
var VW = 200, VY = 12, VH = 50, uid = 0;      // the drawings live in 200 x 64; the picture shows y = 12 to 62 (nothing is drawn above 14 or below 61)

// ---------- which silhouette a car gets: CarPath first (iRacing's folder name), then the screen name, then the class name, else a road car ----------
// First match wins, so the narrow words come first (a GT4 is not a GT3, "gtp" is not "gt3", an LMP is not an open-wheel car).
var RULES = [
  ['gtp',     /gtp|lmdh|lmh|hypercar|499p|963|arx-?06|v-?series|m hybrid/],
  ['lmp',     /lmp|prototype|p217|ligier|oreca|js ?p3/],
  ['gt4',     /gt4/],
  ['gt3',     /gt3|gte|gtd|gt1|rsr|porsche.*cup|challenge|supergt|huracan|r8 ?lms|720s|amg evo|296|911 ?gt/],
  ['formula', /formula|f1\b|f3\b|f4\b|indy|ir-?18|ir-?04|dw12|fr-?20|fr-?35|superformula|sf-?\d|skip ?barber|ff-?1600|ray ?ff|usf|vee|mp4|fw31|lotus ?(49|79)|midget|sprint ?car|silver ?crown|pro ?mazda|kart/],
  ['stock',   /nascar|stock|truck|arca|late ?model|modified|legends|next ?gen|cup series|xfinity|silverado|camry|ss ?camaro|trucks/]
];
function norm(s) { return String(s == null ? '' : s).toLowerCase().replace(/[_\-]+/g, ' ').replace(/\s+/g, ' ').trim(); }
function typeOf(path, name, cls) {
  var keys = [norm(path), norm(name), norm(cls)], k, r;
  for (k = 0; k < keys.length; k++) {
    if (!keys[k]) continue;
    for (r = 0; r < RULES.length; r++) if (RULES[r][1].test(keys[k]) || RULES[r][1].test(keys[k].replace(/ /g, ''))) return RULES[r][0];
  }
  return 'road';
}
var NAMES = { gt3: 'GT3', gt4: 'GT4', lmp: 'Prototype', gtp: 'GTP', formula: 'Open-wheel', stock: 'Stock car', road: 'Touring car' };

// ---------- the livery ----------
function hex6(s) { var m = /^#?([0-9a-fA-F]{6})$/.exec(String(s == null ? '' : s).trim()); return m ? '#' + m[1].toLowerCase() : ''; }
// "17,391C83,111111,CCFF00" -> { pat: 17, c1: '#391c83', c2: '#111111', c3: '#ccff00', real: true }; no usable first colour -> the fallback (the class colour), no stripes
// iRacing writes "1,FF0000,00FF00,0000FF" (pure red / green / blue) for every driver who never picked a paint: that is its placeholder, not a livery, so it is
// treated like no design at all (the class colour, no stripes). Set UNSET_DEFAULT to '' to paint it literally.
var UNSET_DEFAULT = '#ff0000,#00ff00,#0000ff';
function parse(design, fallback) {
  var p = String(design || '').split(','), c1 = hex6(p[1]), c2 = hex6(p[2]), c3 = hex6(p[3]);
  if (!c1 || (UNSET_DEFAULT && [c1, c2, c3].join(',') === UNSET_DEFAULT)) return { pat: 0, c1: hex6(fallback) || '#d8d4ca', c2: '', c3: '', real: false };
  return { pat: parseInt(p[0], 10) || 0, c1: c1, c2: c2, c3: c3, real: true };
}
function lum(h) { var v = parseInt(h.slice(1), 16); return (0.299 * (v >> 16) + 0.587 * ((v >> 8) & 255) + 0.114 * (v & 255)) / 255; }

// ---------- the seven drawings (viewBox 200 x 64, nose to the right, ground at y = 60.5) ----------
// top = the outline from the rear bottom over the roof to the front bottom; the underside and the wheel arches are added from `wheels`
// [centre x, centre y, tyre radius, arch radius], the front wheel first, with the sill at y = sill. glass / back / front are extra shapes
// (back = behind the body, front = on it). band / line = the y range of the colour 2 stripe and the colour 3 line; probe = a point of pure colour 1.
var CAR = {
  gt3: {
    sill: 53, wheels: [[156, 47, 13.5, 16], [46, 47, 13.5, 16]],
    top: 'M 12 53 L 8 52 L 7 43 C 7 39.5 9 36.5 13 35.5 L 20 34 C 30 33 44 31.5 58 29.5 C 68 28 76 19.5 91 17 L 112 16 C 124 16.5 132 22.5 143 29 C 158 31 176 34 190 39.5 C 194 41 197 43.5 197 46.5 L 197 51 L 191 53',
    glass: 'M 69 28.2 C 76 22.5 83 19.8 92 18.8 L 110 18.2 C 120 18.4 126 22.5 133 27.8 Z',
    back: [['M 12.5 35 L 11.5 26 L 14 26 L 15.5 34 Z', 'dark'], ['M 2 24.5 L 25 22.5 L 25.5 26.5 L 3 28.5 Z', 'c2']],
    front: [['M 184 52.5 L 199 51 L 199 54 L 178 55.5 Z', 'dark'], ['M 187 41 L 194 43.4 L 193 45.2 L 186 42.8 Z', 'lamp']],
    band: [45, 50], line: [42.5, 44], probe: [100, 35.5], num: [100, 37]
  },
  gt4: {
    sill: 53, wheels: [[156, 47, 13.5, 16], [46, 47, 13.5, 16]],
    top: 'M 12 53 L 8 52 L 7 43 C 7 39.5 9 37 13 36 L 21 34.5 C 32 34 46 33 60 30.5 C 70 28.5 76 17.5 91 15 L 113 14 C 125 14.5 133 22 144 29.5 C 159 31.5 177 34.5 191 40 C 195 41.5 197 44 197 47 L 197 51 L 191 53',
    glass: 'M 69 29.6 C 76 21.5 83 17.8 92 16.6 L 111 15.8 C 121 16.2 128 21.8 135 28.6 Z',
    back: [['M 3 34 L 21 32.5 L 22 35 L 5 36.5 Z', 'c2']],
    front: [['M 184 52.5 L 199 51.5 L 199 54.2 L 179 55.5 Z', 'dark'], ['M 188 41.5 L 195 44 L 194 45.8 L 187 43.2 Z', 'lamp']],
    band: [45, 50], line: [42.5, 44], probe: [100, 36], num: [100, 37]
  },
  road: {
    sill: 52.5, wheels: [[153, 47.5, 12.5, 15], [45, 47.5, 12.5, 15]],
    top: 'M 11 52.5 L 8 46 C 7 42 8 39 11 37.5 L 20 36 C 32 35.5 44 35 54 34 C 61 33 67 18.5 82 15 L 112 14 C 123 14.5 131 25 141 31.5 C 156 32.5 175 34.5 189 40 C 193 41.5 195 44 195 47 L 195 51.5 L 188 52.5',
    glass: 'M 70 32.6 C 74 23.5 78 18.8 87 17.2 L 111 15.8 C 120 16.2 127 25 134 31.8 Z',
    back: [], front: [['M 186 41.6 L 193 44 L 192 45.8 L 185 43.4 Z', 'lamp']],
    band: [45.5, 50], line: [43.2, 44.6], probe: [100, 38.3], num: [98, 38.5]
  },
  stock: {
    sill: 53, wheels: [[154, 46.5, 13.5, 16], [50, 46.5, 13.5, 16]],
    top: 'M 12 53 L 6 52 L 5 39 C 5 37 7 36 10 35.5 L 44 33 L 66 31.5 L 83 22.5 L 118 21.5 L 139 30.5 L 183 33.5 C 191 34.5 197 37 197 43 L 197 51 L 190 53',
    glass: 'M 70 31 L 85 23.8 L 116 23 L 133 30.4 Z',
    back: [['M 3 30 L 22 29.5 L 22.5 33 L 4 34 Z', 'c2']],
    front: [['M 184 52.5 L 199 51.5 L 199 54.5 L 180 55.5 Z', 'dark'], ['M 189 37 L 196 39.2 L 196 41 L 188 39 Z', 'lamp']],
    band: [44, 49.5], line: [41.6, 43], probe: [100, 36.5], num: [102, 37]
  },
  lmp: {
    sill: 54, wheels: [[157, 47, 13, 15.5], [46, 46, 14.5, 17]],
    top: 'M 12 54 L 8 53 L 7 39 C 7 31 9 24.5 11 20.5 C 13 21.5 15 25 19 26.8 L 38 30.5 C 52 31.5 62 29.5 68 26 L 72 18 L 80 17 C 82 20 86 22 94 21.5 C 104 21.5 112 24 120 28 C 140 31.5 172 38 189 44.5 C 194 46 197 48 197 50.5 L 197 53 L 189 54',
    glass: 'M 90 25 C 94 22.3 100 22.1 106 22.5 C 112 23.5 116 25.7 119.5 27.8 Z',
    back: [['M 1 20 L 20 18.5 L 20.5 21.5 L 2 23 Z', 'c2']],
    front: [['M 186 53.5 L 199 52 L 199 55 L 180 56.5 Z', 'dark'], ['M 188 45 L 195 47 L 194 48.6 L 187 46.6 Z', 'lamp']],
    band: [46, 51.5], line: [43.4, 45], probe: [134, 37.5], num: [100, 41]
  },
  gtp: {
    sill: 54, wheels: [[157, 47, 13, 15.5], [46, 46, 14.5, 17]],
    top: 'M 12 54 L 8 53 L 7 39 L 8 28 C 9 24 10 22 11 20.5 C 13 21.5 15 24 18 25.8 L 40 30 C 52 32 62 28 72 22.5 C 80 17.5 94 15 106 16.5 C 118 18 124 23.5 132 28 C 150 31.5 172 37.5 189 44 C 194 45.5 197 47.5 197 50.5 L 197 53 L 189 54',
    glass: 'M 80 26 C 86 19.3 96 17.3 106 17.9 C 115 18.9 121 23.5 127 27.7 Z',
    back: [['M 1 21 L 20 19.5 L 20.5 22.5 L 2 24 Z', 'c2']],
    front: [['M 186 53.5 L 199 52 L 199 55 L 180 56.5 Z', 'dark'], ['M 188 44.5 L 195 46.5 L 194 48.1 L 187 46.1 Z', 'lamp']],
    band: [46, 51.5], line: [43.4, 45], probe: [134, 37.5], num: [100, 41]
  },
  formula: {
    sill: 0, wheels: [[162, 47, 13.5, 0], [40, 44, 15.5, 0]], open: true,
    top: 'M 19 44 L 27 36 C 38 30 50 24 60 21.5 L 70 20 C 76 22 82 28 90 31 L 108 31.5 C 114 31 118 32 124 35 C 144 39 170 45 188 49.5 L 192 49.5 L 192 52.5 L 150 53 L 70 53 L 28 51 Z',
    glass: '',
    back: [['M 1 18 L 22 16 L 23 20 L 2 22 Z', 'c2'], ['M 20 22 L 24 34 L 21 34 L 17 22 Z', 'dark']],
    front: [['M 96 31 C 100 22 112 22 120 33', 'halo'], ['M 176 52.5 L 199 50.5 L 199 54 L 172 56 Z', 'c2']],
    helmet: [104, 28, 5.2], band: [44, 50], line: [41, 42.4], probe: [92, 37], num: [94, 41]
  }
};

function half(r, dy) { return Math.sqrt(Math.max(0, r * r - dy * dy)); }
function bodyPath(t) {
  if (t.open) return t.top;
  var d = t.top;
  t.wheels.forEach(function (w) {                     // front wheel first: the sill runs from the front to the rear
    var h = half(w[3], t.sill - w[1]); d += ' L ' + (w[0] + h).toFixed(1) + ' ' + t.sill + ' A ' + w[3] + ' ' + w[3] + ' 0 1 0 ' + (w[0] - h).toFixed(1) + ' ' + t.sill;
  });
  return d + ' Z';
}
function archFill(t) {                                // the dark inside of each wheel arch = the cut-out, closed along the sill
  if (t.open) return '';
  return t.wheels.map(function (w) {
    var h = half(w[3], t.sill - w[1]);
    return 'M ' + (w[0] + h).toFixed(1) + ' ' + t.sill + ' A ' + w[3] + ' ' + w[3] + ' 0 1 0 ' + (w[0] - h).toFixed(1) + ' ' + t.sill + ' Z';
  }).join(' ');
}
function wheelSvg(w) {
  var x = w[0], y = w[1], r = w[2], q = (r * 0.64).toFixed(1);
  return '<circle cx="' + x + '" cy="' + y + '" r="' + r + '" fill="#0c0c0e"/><circle cx="' + x + '" cy="' + y + '" r="' + q + '" fill="#2c2d33" stroke="rgba(200,202,210,.6)" stroke-width=".9"/>' +
    '<circle cx="' + x + '" cy="' + y + '" r="' + (r * 0.2).toFixed(1) + '" fill="#0c0c0e"/>';
}

// the picture as an SVG string. o = { type | path, name, cls (to find the type), design (CarDesignStr), col (fallback body colour), w (px), num (draw it on the door), title }
function svg(o) {
  o = o || {};
  var type = o.type && CAR[o.type] ? o.type : typeOf(o.path, o.name, o.cls), t = CAR[type], L = parse(o.design, o.col), id = 'pc' + (++uid);
  var c1 = L.c1, c2 = L.real && L.c2 ? L.c2 : '', c3 = L.real && L.c3 ? L.c3 : '';
  var fill = { dark: '#16161a', lamp: 'rgba(244,241,234,.8)', c1: c1, c2: c2 || '#16161a', c3: c3 || '#16161a' };
  var w = o.w || 120, h = Math.round(w * VH / VW * 10) / 10, s = '';
  var bp = bodyPath(t);
  s += '<svg class="pcar" data-type="' + type + '" data-body="' + c1 + '" viewBox="0 ' + VY + ' ' + VW + ' ' + VH + '" width="' + w + '" height="' + h + '" role="img" aria-label="' + String(o.title || NAMES[type]).replace(/"/g, '') + '" xmlns="http://www.w3.org/2000/svg">';
  s += '<defs><clipPath id="' + id + '"><path d="' + bp + '"/></clipPath></defs>';
  t.back.forEach(function (b) { s += '<path d="' + b[0] + '" fill="' + fill[b[1]] + '"/>'; });
  if (archFill(t)) s += '<path d="' + archFill(t) + '" fill="#0a0a0c"/>';
  s += '<path d="' + bp + '" fill="' + c1 + '" stroke="rgba(255,255,255,.26)" stroke-width=".7" stroke-linejoin="round"/>';
  s += '<g clip-path="url(#' + id + ')">';
  if (c2) s += '<rect x="0" y="' + t.band[0] + '" width="200" height="' + (t.band[1] - t.band[0]) + '" fill="' + c2 + '"/>';
  if (c3) s += '<rect x="0" y="' + t.line[0] + '" width="200" height="' + (t.line[1] - t.line[0]) + '" fill="' + c3 + '"/>';
  s += '<rect x="0" y="' + (t.open ? 50 : t.sill - 3) + '" width="200" height="12" fill="rgba(0,0,0,.28)"/></g>';
  if (t.glass) s += '<path d="' + t.glass + '" fill="#0b0e13" stroke="rgba(255,255,255,.14)" stroke-width=".5"/>';
  t.front.forEach(function (f) {
    if (f[1] === 'halo') s += '<path d="' + f[0] + '" fill="none" stroke="#16161a" stroke-width="2.2" stroke-linecap="round"/>';
    else s += '<path d="' + f[0] + '" fill="' + fill[f[1]] + '"/>';
  });
  if (t.helmet) s += '<circle cx="' + t.helmet[0] + '" cy="' + t.helmet[1] + '" r="' + t.helmet[2] + '" fill="' + (c3 || '#d8d4ca') + '" stroke="rgba(0,0,0,.45)" stroke-width=".6"/>';
  t.wheels.forEach(function (wl) { s += wheelSvg(wl); });
  if (o.num != null && String(o.num) !== '') {
    var n = String(o.num).replace(/[<>&"]/g, ''), k = t.num, dk = lum(c1) > 0.55;
    s += '<circle cx="' + k[0] + '" cy="' + k[1] + '" r="6.4" fill="' + (dk ? '#101010' : '#f4f1ea') + '" opacity=".92"/><text x="' + k[0] + '" y="' + (k[1] + 3.6) + '" font-size="' + (n.length > 2 ? 7.5 : 9.5) + '" font-weight="700" text-anchor="middle" fill="' + (dk ? '#f4f1ea' : '#101010') + '" font-family="Segoe UI,Arial,sans-serif">' + n + '</text>';
  }
  return s + '</svg>';
}

// where the body colour can be read back from a picture on screen: the client position of the probe point (pure colour 1, no stripe, no glass)
function probe(el) {
  if (!el || !el.getBoundingClientRect) return null;
  var t = CAR[el.getAttribute('data-type')], r = el.getBoundingClientRect(); if (!t) return null;
  return { x: r.left + t.probe[0] / VW * r.width, y: r.top + (t.probe[1] - VY) / VH * r.height };
}

var api = { types: ['gt3', 'gt4', 'lmp', 'gtp', 'formula', 'stock', 'road'], names: NAMES, type: typeOf, parse: parse, svg: svg, probe: probe, VW: VW, VH: VH, VY: VY };
// PL-1 (2026-10-11): Peter turned the drawn silhouettes down ("they look ridiculous"). THE ONE SWITCH: with CARS_DRAWN = false window.PCars does not exist, and every
// page (RACE tower and header chips, CAREER race rows, HOME) falls back to its look from before P4: the plain number plate alone. The code stays here, dormant, for
// the day iRacing's own car pictures replace it; window.PCarsDormant is only there so tests\race-field-test.ps1 can keep checking the drawing code itself.
root.PCarsDormant = api;
if (CARS_DRAWN) root.PCars = api;
})(window);
