// keyart.js (W3-4): the ONE drawing of a Stream Deck key, shared by deck\render.html (the static key pictures build-deck.ps1
// packages) and deck-intro\plugin.html (the add-on's opener keys and its live screens). Before this there were six copied colour
// tables in the add-on and a different renderer (System.Drawing) for the deck pages, so the preview never looked like the deck.
// The key language (docs\rework\PLAN.md 4.6, Elgato's own guidance): a black key, one glyph at about 60 % of the key height,
// one label of at most 8 characters a line (2 lines at most) at 20 px or more on the 96 px key, the colour says the job:
//   gold  = the one thing he most likely wants now    green = starts something    red = ends something
//   grey  = settings                                   white = a plain key (black, white glyph)
// Plain script (no module): it sets the global KEYART. Every colour of the deck lives here; plugin.html has no hex colour of its own.
'use strict';
var KEYART = (function () {
  var FONT = 'Bahnschrift, "Segoe UI", sans-serif';

  // the colour tokens (C) - nothing else in the deck code names a colour
  var C = {
    black: '#000000', key: '#0b0b0b', tile: '#1b1b1b', dark: '#101010', grey: '#2a2a2a', edge: '#3a3a3a', sheet: '#262626',
    ink: '#f4f1ea', white: '#ffffff', muted: '#8d8a82', soft: '#a8a59d', faint: '#6d6a63', fainter: '#55524c', stone: '#8a867d',
    card: '#141414', goldTick: '#2a2208',
    gold: '#c9a24b', goldDeep: '#8a6d17', goldDark: '#3a2f08', goldDarker: '#1e1904', goldInk: '#111111',
    green: '#1fbf5f', greenBright: '#4be38a', greenInk: '#03140a', greenNight: '#04150a', greenDot: '#2fe07a',
    red: '#c62f2f', redText: '#e0493f', redSoft: '#ff6b6b', redDot: '#ff4d4d',
    amber: '#d98b2b', amberInk: '#140b00', amberDot: '#ffb21e'
  };

  // ONE table of looks for the add-on's screen keys: style name -> [fill, text]. (Was FCOLORS, OCOLORS, MCOLORS, RCOLORS, ACOLORS, SNDCOLORS.)
  var STYLE = {
    sel: [C.gold, C.goldInk], go: [C.green, C.greenInk], stop: [C.red, C.white], amber: [C.amber, C.amberInk],
    gold: [C.goldDeep, C.white], grey: [C.grey, C.ink], banner: [C.key, C.gold], label: [C.black, C.muted],
    on: [C.tile, C.gold], off: [C.tile, C.faint], dim: [C.dark, C.fainter], stepOn: [C.goldDark, C.gold], stepOn2: [C.goldDarker, C.gold],
    goBright: [C.greenBright, C.greenInk], strip: [C.key, C.ink], watch: [C.goldDark, C.gold], card: [C.key, C.ink], hint: [C.dark, C.muted],
    '': [C.tile, C.ink]
  };

  // a deck key's role -> [fill, glyph and label]
  var ROLE = {
    gold: [C.gold, C.goldInk], green: [C.green, C.greenInk], red: [C.red, C.white], grey: [C.grey, C.ink], white: [C.key, C.ink],
    dead: [C.key, C.fainter]   // an opener key while irdash is not answering (Health)
  };
  var DOT = { ok: C.greenDot, warn: C.amberDot, bad: C.redDot, none: C.fainter };

  // ---------------- the glyphs: drawn in a 100 x 100 box around (0, 0), stroke 9 ----------------
  function P(g, pts, close) { g.beginPath(); g.moveTo(pts[0], pts[1]); for (var i = 2; i < pts.length; i += 2) g.lineTo(pts[i], pts[i + 1]); if (close) g.closePath(); }
  function S(g) { g.stroke(); }
  function F(g) { g.fill(); }
  function circle(g, x, y, r) { g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); }
  function speaker(g) { P(g, [-40, -14, -22, -14, 0, -34, 0, 34, -22, 14, -40, 14], true); F(g); }
  var GLYPHS = {
    home: function (g) { P(g, [-40, -2, 0, -38, 40, -2]); S(g); P(g, [-28, -12, -28, 36, 28, 36, 28, -12]); S(g); },
    play: function (g) { P(g, [-24, -36, -24, 36, 36, 0], true); F(g); },
    chip: function (g) { g.strokeRect(-26, -26, 52, 52); for (var i = -14; i <= 14; i += 14) { P(g, [i, -26, i, -40]); S(g); P(g, [i, 26, i, 40]); S(g); P(g, [-26, i, -40, i]); S(g); P(g, [26, i, 40, i]); S(g); } g.fillRect(-10, -10, 20, 20); },
    globe: function (g) { circle(g, 0, 0, 38); S(g); g.beginPath(); g.ellipse(0, 0, 16, 38, 0, 0, Math.PI * 2); S(g); P(g, [-38, 0, 38, 0]); S(g); },
    people: function (g) { circle(g, -16, -14, 13); S(g); circle(g, 18, -14, 13); S(g); g.beginPath(); g.arc(-16, 34, 24, Math.PI, 0); S(g); g.beginPath(); g.arc(18, 34, 24, Math.PI, 0); S(g); },
    lock: function (g) { g.beginPath(); g.arc(0, -10, 18, Math.PI, 0); S(g); P(g, [-18, -10, -18, 0]); S(g); P(g, [18, -10, 18, 0]); S(g); g.fillRect(-30, 0, 60, 40); },
    snow: function (g) { for (var a = 0; a < 3; a++) { var t = a * Math.PI / 3, c = Math.cos(t) * 40, s = Math.sin(t) * 40; P(g, [-c, -s, c, s]); S(g); } circle(g, 0, 0, 7); F(g); },
    more: function (g) { P(g, [-30, -30, 0, 0, -30, 30]); S(g); P(g, [6, -30, 36, 0, 6, 30]); S(g); },
    left: function (g) { P(g, [20, -34, -18, 0, 20, 34]); S(g); },
    exit: function (g) { P(g, [-6, -36, -36, -36, -36, 36, -6, 36]); S(g); P(g, [-14, 0, 30, 0]); S(g); P(g, [16, -16, 34, 0, 16, 16]); S(g); },
    restart: function (g) { g.beginPath(); g.arc(0, 4, 32, -Math.PI * 0.35, Math.PI * 1.45); S(g); P(g, [4, -44, 26, -28, 4, -14], true); F(g); },
    flag: function (g) { P(g, [-34, 40, -34, -40]); S(g); for (var r = 0; r < 3; r++) for (var q = 0; q < 4; q++) if ((r + q) % 2 === 0) g.fillRect(-30 + q * 16, -38 + r * 16, 16, 16); g.strokeRect(-30, -38, 64, 48); },
    pause: function (g) { g.fillRect(-26, -34, 18, 68); g.fillRect(8, -34, 18, 68); },
    pin: function (g) { g.beginPath(); g.arc(0, -10, 24, Math.PI * 0.8, Math.PI * 2.2); g.lineTo(0, 40); g.closePath(); S(g); circle(g, 0, -10, 8); F(g); },
    back: function (g) { g.beginPath(); g.arc(4, 4, 26, -Math.PI / 2, Math.PI / 2); S(g); P(g, [4, -22, -30, -22]); S(g); P(g, [-16, -38, -32, -22, -16, -6]); S(g); P(g, [4, 30, -10, 30]); S(g); },
    pump: function (g) { g.strokeRect(-32, -36, 40, 74); g.fillRect(-24, -26, 24, 18); P(g, [8, -20, 24, -20, 24, 18, 34, 18, 34, -10]); S(g); },
    tire: function (g) { circle(g, 0, 0, 38); S(g); circle(g, 0, 0, 16); S(g); },
    wrench: function (g, fg, bg) { g.lineWidth = 16; P(g, [-30, 30, 4, -4]); S(g); circle(g, 14, -14, 24); F(g); g.save(); g.translate(14, -14); g.rotate(-Math.PI / 4); g.fillStyle = bg; g.fillRect(-9, -30, 18, 24); g.restore(); },
    garage: function (g) { P(g, [-40, -8, 0, -38, 40, -8]); S(g); P(g, [-30, -14, -30, 38]); S(g); P(g, [30, -14, 30, 38]); S(g); P(g, [-18, 2, 18, 2]); S(g); P(g, [-18, 18, 18, 18]); S(g); P(g, [-18, 34, 18, 34]); S(g); },
    clear: function (g) { circle(g, 0, 0, 36); S(g); P(g, [-25, 25, 25, -25]); S(g); },
    watch: function (g) { circle(g, 0, 6, 32); S(g); P(g, [0, -38, 0, -26]); S(g); P(g, [-10, -40, 10, -40]); S(g); P(g, [0, 6, 14, -8]); S(g); },
    replay: function (g) { P(g, [36, -30, 36, 30, 4, 0], true); F(g); P(g, [4, -30, 4, 30, -28, 0], true); F(g); g.fillRect(-38, -30, 9, 60); },
    voldown: function (g) { speaker(g); P(g, [14, 0, 40, 0]); S(g); },
    volup: function (g) { speaker(g); P(g, [14, 0, 40, 0]); S(g); P(g, [27, -13, 27, 13]); S(g); },
    headset: function (g) { g.beginPath(); g.arc(0, 6, 32, Math.PI, 0); S(g); g.fillRect(-40, 4, 16, 30); g.fillRect(24, 4, 16, 30); },
    sliders: function (g) { var xs = [-26, 0, 26], ys = [10, -16, 4]; for (var i = 0; i < 3; i++) { P(g, [xs[i], -38, xs[i], 38]); S(g); g.fillRect(xs[i] - 11, ys[i] - 7, 22, 14); } },
    eye: function (g) { g.beginPath(); g.moveTo(-42, 0); g.quadraticCurveTo(0, -40, 42, 0); g.quadraticCurveTo(0, 40, -42, 0); g.closePath(); S(g); circle(g, 0, 0, 12); F(g); },
    film: function (g) { g.strokeRect(-36, -28, 72, 56); for (var x = -28; x <= 24; x += 13) { g.fillRect(x, -24, 6, 7); g.fillRect(x, 17, 6, 7); } P(g, [-6, -10, -6, 10, 12, 0], true); F(g); },
    chart: function (g) { P(g, [-38, -38, -38, 38, 38, 38]); S(g); g.fillRect(-26, 6, 12, 24); g.fillRect(-6, -14, 12, 44); g.fillRect(14, -30, 12, 60); },
    gauge: function (g) { g.beginPath(); g.arc(0, 14, 38, Math.PI, 0); S(g); P(g, [0, 14, 22, -10]); S(g); circle(g, 0, 14, 7); F(g); },
    chat: function (g) { g.strokeRect(-38, -30, 76, 48); P(g, [-14, 18, -26, 38, 4, 18], true); F(g); for (var dx = -18; dx <= 18; dx += 18) { circle(g, dx, -6, 5); F(g); } },
    down: function (g) { P(g, [0, 38, -30, 0, 30, 0], true); F(g); P(g, [0, 0, 0, -38]); S(g); },
    up: function (g) { P(g, [0, -38, -30, 0, 30, 0], true); F(g); P(g, [0, 0, 0, 38]); S(g); },
    menu: function (g) { P(g, [-34, -26, 34, -26]); S(g); P(g, [-34, 0, 34, 0]); S(g); P(g, [-34, 26, 34, 26]); S(g); },
    power: function (g) { g.beginPath(); g.arc(0, 4, 32, -Math.PI * 0.3, Math.PI * 1.3); S(g); P(g, [0, -40, 0, -6]); S(g); },
    moon: function (g, fg, bg) { circle(g, 0, 0, 34); F(g); g.fillStyle = bg; circle(g, 18, -14, 30); F(g); g.fillStyle = fg; }
  };
  function glyphNames() { return Object.keys(GLYPHS); }
  function drawGlyph(g, name, cx, cy, size, fg, bg) {
    var f = GLYPHS[name]; if (!f) return false;
    g.save(); g.translate(cx, cy); g.scale(size / 100, size / 100);
    g.strokeStyle = fg; g.fillStyle = fg; g.lineWidth = 9; g.lineCap = 'round'; g.lineJoin = 'round';
    f(g, fg, bg); g.restore(); return true;
  }

  // the font, condensed when the browser can (Bahnschrift has a width axis)
  function font(g, weight, px) { g.font = weight + ' ' + px + 'px ' + FONT; try { g.fontStretch = 'condensed'; } catch (e) { } }

  // ---------------- one deck key: spec = { label: [line1, line2?], glyph, role, dot, note, noteColor, pressed, inset } ----------------
  // x, y, s: where and how big (144 for a deck picture, 96 for a key of an add-on screen). Returns what it drew (the label size, for the test).
  function drawKey(g, x, y, s, spec) {
    var k = s / 144, inset = (spec.inset || 0), role = ROLE[spec.role] || ROLE.white;
    var bg = role[0], fg = role[1];
    if (spec.pressed) { bg = C.white; fg = C.black; }
    g.save();
    g.fillStyle = C.black; g.fillRect(x, y, s, s);
    g.fillStyle = bg; g.fillRect(x + inset, y + inset, s - 2 * inset, s - 2 * inset);
    var lines = (spec.label || []).filter(function (l) { return l; }).slice(0, 2), note = spec.note ? String(spec.note) : '';
    var n = lines.length + (note ? 1 : 0), pad = 10 * k, gap = 5 * k;
    var px = 30 * k, lh = px * 1.06, notePx = 20 * k;        // 30 px on the 144 px picture = 20 px on the 96 px key
    var textH = lines.length * lh + (note ? notePx * 1.1 : 0);
    var gh = n === 0 ? 0.6 * s : s - 2 * pad - gap - textH;        // one line: the glyph is 60 % of the key
    var drew = { labelPx: [], fits: true, glyph: false };
    if (spec.glyph) drew.glyph = drawGlyph(g, spec.glyph, x + s / 2, y + (n === 0 ? s / 2 : pad + gh / 2), gh * 0.92, fg, bg);
    g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillStyle = fg;
    var ty = n === 0 ? 0 : (spec.glyph ? y + pad + gh + gap : y + (s - textH) / 2);
    var maxW = s - 2 * inset - 12 * k;
    for (var i = 0; i < lines.length; i++) {
      var t = String(lines[i]).toUpperCase();
      font(g, '600', px); if (g.measureText(t).width > maxW) drew.fits = false;   // never smaller than 20 px on the key: layout.json keeps labels to 8 characters
      g.fillText(t, x + s / 2, ty + lh / 2, maxW); ty += lh; drew.labelPx.push(Math.round(px * 96 / s * 10) / 10);
    }
    if (note) {
      font(g, '400', notePx); g.fillStyle = spec.noteColor ? (C[spec.noteColor] || spec.noteColor) : (fg === C.ink ? C.gold : fg);
      g.fillText(note.toUpperCase(), x + s / 2, ty + notePx * 0.55, maxW);
    }
    if (spec.dot) { g.fillStyle = DOT[spec.dot] || DOT.none; circle(g, x + s - 20 * k, y + 20 * k, 10 * k); g.fill(); }
    g.restore();
    return drew;
  }
  // a key as a PNG data URL (canvas made here)
  function keyPng(spec, s) {
    var c = document.createElement('canvas'); c.width = c.height = s || 144;
    drawKey(c.getContext('2d'), 0, 0, s || 144, spec);
    return c.toDataURL('image/png');
  }

  // ---------------- a tile of an add-on screen (a region of one or more keys; was Screen.drawCanvas) ----------------
  function textLines(x, text, maxW) {
    var words = text.split(' '), out = [], cur = '';
    for (var i = 0; i < words.length; i++) { var w = words[i], t = cur ? cur + ' ' + w : w; if (cur && x.measureText(t).width > maxW) { out.push(cur); cur = w; } else cur = t; }
    if (cur) out.push(cur);
    return out.length ? out : [''];
  }
  // Words on a tile of several keys: the picture of each key is cut out of one sheet and the bezel hides the gap between keys, so a word
  // drawn across a gap loses letters ("NA|ME"). The text is split into short runs, one run per key, each centred in its own key (W1-5).
  function splitRuns(text, n, maxc) {
    var words = String(text == null ? '' : text).replace(/\s*·\s*/g, ' ').trim().split(/\s+/).filter(Boolean);
    if (!words.length) return [];
    for (var m = maxc || 9; ; m++) {
      var out = [], cur = '';
      for (var i = 0; i < words.length; i++) { var w = words[i]; if (cur && (cur + ' ' + w).length > m) { out.push(cur); cur = w; } else cur = cur ? cur + ' ' + w : w; }
      out.push(cur);
      if (out.length <= n || m > 40) { out.length = Math.min(out.length, n); return out; }
    }
  }
  // a paint hook for a tile w x h keys (pitch = one key with its gap): parts = { main: [one run per key], sub: [...] }, centred as a group
  function span(parts, w, h, size, pitch) {
    return function (g, px, py, pw, ph, bg, fg) {
      var cell = pitch - 6, rowMain = h < 3 ? 0 : 1;
      var row = function (arr, rw, weight, sz, alpha, dy) {
        var off = Math.floor((w - arr.length) / 2);
        g.globalAlpha = alpha; g.fillStyle = fg; g.textAlign = 'center'; g.textBaseline = 'middle';
        arr.forEach(function (t, i) {
          var s = sz; do { g.font = weight + ' ' + s + 'px ' + FONT; s--; } while (g.measureText(t).width > cell - 12 && s > 10);
          g.fillText(t, px + (off + i) * pitch + cell / 2, py + rw * pitch + cell / 2 + dy);
        });
        g.globalAlpha = 1;
      };
      var sub = parts.sub || [];
      if (h === 1) { row(parts.main, 0, '600', Math.min(size || 24, 24), 1, sub.length ? -11 : 0); if (sub.length) row(sub, 0, '400', 14, .85, 15); }
      else { row(parts.main, rowMain, '600', Math.min(size || 28, 28), 1, 0); if (sub.length) row(sub, rowMain + 1, '400', 18, .85, 0); }
    };
  }

  // r = { c, r, w, h, text, sub, style, wrap, single, size, strip, paint, key }; px..ph = its rectangle on the screen's canvas
  function drawRegion(x, r, px, py, pw, ph, pressed) {
    var col = STYLE[r.style] || STYLE[''], bg = col[0], fg = col[1];
    if (pressed) { bg = C.white; fg = C.black; }
    x.fillStyle = bg; x.fillRect(px, py, pw, ph);
    if (r.style === 'label') { x.fillStyle = C.gold; x.fillRect(px, py + ph - 4, pw, 2); }
    if (r.strip) { x.fillStyle = r.strip; x.fillRect(px, py, 6, ph); }
    if (r.paint) { r.paint(x, px, py, pw, ph, bg, fg); return; }                   // the screen draws this one itself
    if (r.w > 1) {
      // several keys wide: one run of words per key, never across a gap (W3-4: every screen, not only RACES)
      var mt = String(r.text == null ? '' : r.text).toUpperCase(), st = r.sub ? String(r.sub) : '';
      span({ main: splitRuns(mt, r.w), sub: splitRuns(st, r.w, 6) }, r.w, r.h, r.size, (pw + 6) / r.w)(x, px, py, pw, ph, bg, fg);
      return;
    }
    x.fillStyle = fg; x.textAlign = 'center'; x.textBaseline = 'middle';
    var big = r.w * r.h > 1, cx = px + pw / 2, cy = py + ph / 2, main = String(r.text == null ? '' : r.text).toUpperCase(), sub = r.sub ? String(r.sub) : '';
    var lh, sh, y, i, lines, subLines;
    if (r.wrap) {
      // text over up to r.wrap lines (long car and track names), the small line under it
      var size = r.size || (big ? 22 : 17);
      for (;;) { x.font = '600 ' + size + 'px ' + FONT; lines = r.single ? [main] : textLines(x, main, pw - 12); if ((lines.length <= r.wrap && lines.every(function (l) { return x.measureText(l).width <= pw - 8; })) || size <= 9) break; size--; }
      var subSize = big ? 15 : 12; subLines = [];
      if (sub) for (;;) { x.font = '400 ' + subSize + 'px ' + FONT; subLines = r.single ? [sub] : textLines(x, sub, pw - 8); if ((subLines.length <= 2 && subLines.every(function (l) { return x.measureText(l).width <= pw - 6; })) || subSize <= 9) break; subSize--; }
      lh = size * 1.12; sh = subSize * 1.15;
      var total = lines.length * lh + (sub ? 4 + subLines.length * sh : 0);
      y = cy - total / 2 + lh / 2;
      x.font = '600 ' + size + 'px ' + FONT;
      for (i = 0; i < lines.length; i++) { x.fillText(lines[i], cx, y, pw - 8); y += lh; }
      if (sub) { x.globalAlpha = .85; x.font = '400 ' + subSize + 'px ' + FONT; y += 4 - lh / 2 + sh / 2; for (i = 0; i < subLines.length; i++) { x.fillText(subLines[i], cx, y, pw - 6); y += sh; } x.globalAlpha = 1; }
    } else {
      var fit = function (text, sz, weight, maxW) { var s2 = sz; do { x.font = weight + ' ' + s2 + 'px ' + FONT; s2--; } while (x.measureText(text).width > maxW && s2 > 9); };
      fit(main, r.size || (big ? 30 : 19), '600', pw - 10);
      x.fillText(main, cx, sub ? cy - (big ? 14 : 10) : cy);
      if (sub) { x.globalAlpha = .85; fit(sub, big ? 15 : 12, '400', pw - 8); x.fillText(sub, cx, cy + (big ? 20 : 14)); x.globalAlpha = 1; }
    }
  }

  // ---------------- the layout contract (deck\layout.json, loaded as window.DECK_LAYOUT by layout.js) ----------------
  // the deck key that opens an add-on screen: its spec, found by the screen's name (and its "what" for CONFIRM)
  function openerSpec(layout, name, what) {
    if (!layout || !layout.pages) return null;
    for (var p in layout.pages) {
      var ks = layout.pages[p];
      for (var i = 0; i < ks.length; i++) {
        var a = ks[i].action || {};
        if ((a.screen === name || a.plugin === name) && (!what || !a.what || a.what === what)) return { label: ks[i].label, glyph: ks[i].glyph, role: ks[i].role };
      }
    }
    return null;
  }
  function exitAt(layout) { var e = layout && layout.exitAt; return e && e.length === 2 ? [e[0], e[1]] : [7, 3]; }
  // the EXIT key of every add-on screen: same place, same red, same word (one spec, so render.html draws it byte for byte the same)
  var EXIT = { label: ['EXIT'], glyph: 'exit', role: 'red', inset: 3 };

  return { FONT: FONT, C: C, STYLE: STYLE, ROLE: ROLE, DOT: DOT, GLYPHS: GLYPHS, glyphNames: glyphNames, drawGlyph: drawGlyph, drawKey: drawKey, keyPng: keyPng,
           drawRegion: drawRegion, textLines: textLines, splitRuns: splitRuns, span: span, openerSpec: openerSpec, exitAt: exitAt, EXIT: EXIT };
})();
