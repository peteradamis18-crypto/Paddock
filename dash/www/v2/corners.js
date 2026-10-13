'use strict';
// Corner model in the browser (WS18, docs\corners.md). One place that knows the turns of the track, shared by every page:
//   Corners.load(track, config)   ask irdash (/corners) for the turns of a track; cached, never goes to the internet itself
//   Corners.get(track, config)    what load() has already brought, or null
//   Corners.at(pct, data)         which corner a lap fraction is in, and which one is next
//   Corners.draw(ctx, project, o) numbered gold discs at the apexes, small-caps names where there is room, start/finish,
//                                 sector ticks and the pit lane marks; project(pct) gives the canvas [x, y] of a lap fraction
// The numbers are lap order from the start/finish line (T1 ... Tn) and mean the same on every page. Names come from Lovely Track
// Data where it has them (CC BY-NC-SA 4.0, copy kept on this PC by irdash); where it has none, corners found in Peter's own laps.
// A track with neither is drawn without labels.

const CORNER_FONT = '"Bahnschrift SemiCondensed", "Bahnschrift", "Segoe UI", sans-serif';
const CORNER_COL = {
  gold: '#f2c230', ring: '#07090c', centre: '#0d1116', name: '#d9dde3', halo: '#07090c', sector: '#77828f', sf: '#ffffff', pit: '#b8c1cb', credit: '#4b5562',
};

const Corners = {
  cache: new Map(),
  cur: null,                 // the answer for the track asked about last

  // the request for a track: an object like S.track {rawName, name, config, id, key}, or the name as text plus a layout name
  query(track, config) {
    let t = '', c = config || '', id = '', key = '';
    if (track && typeof track === 'object') {
      t = track.rawName || track.name || ''; if (config == null) c = track.config || '';
      id = track.id || ''; key = track.key || '';
    } else t = String(track || '');
    const e = encodeURIComponent;
    return '/corners?track=' + e(t) + '&config=' + e(c) + (id ? '&id=' + e(id) : '') + (key ? '&key=' + e(key) : '');
  },

  load(track, config) {
    const q = this.query(track, config), hit = this.cache.get(q), now = Date.now();
    if (hit && now - hit.t < hit.ttl) return hit.p;
    const entry = { t: now, ttl: 10 * 60000, p: null };
    entry.p = this.fetchSet(q).then(d => {
      // nothing yet for this track: ask again soon (its corners may be found from your laps); a failed ask is retried quickly
      entry.ttl = !d ? 8000 : d.source === 'none' ? (d.pending ? 5000 : 45000) : 10 * 60000;
      if (d) this.cur = d;
      return d;
    });
    this.cache.set(q, entry);
    return entry.p;
  },

  get(track, config) {
    const hit = this.cache.get(this.query(track, config));
    return hit && hit.d ? hit.d : null;
  },

  async fetchSet(q) {
    try {
      const r = await fetch(q, { cache: 'no-store' });
      if (!r.ok) return null;
      const d = await r.json();
      if (!d || !Array.isArray(d.turns)) return null;
      for (const t of d.turns) { t.pct = t.pctApex; t.label = t.name || ('T' + t.n); }
      d.sectors = Array.isArray(d.sectors) ? d.sectors : [];
      const entry = this.cache.get(q); if (entry) entry.d = d;
      return d;
    } catch (e) { return null; }       // irdash restarting
  },

  inside(t, p) { return t.pct1 >= t.pct0 ? p >= t.pct0 && p <= t.pct1 : p >= t.pct0 || p <= t.pct1; },

  // {turn: the corner this lap fraction is in (or null), next: the next apex ahead, ahead: lap fraction to it, prev: the one just passed}
  at(pct, data) {
    const d = data || this.cur;
    if (!d || !d.turns || !d.turns.length || !isFinite(pct)) return null;
    const p = ((pct % 1) + 1) % 1;
    let turn = null, next = null, prev = null, ahead = 9, behind = 9;
    for (const t of d.turns) {
      if (!turn && this.inside(t, p)) turn = t;
      let a = t.pctApex - p; if (a < 0) a += 1;
      if (a < ahead) { ahead = a; next = t; }
      const b = 1 - a; if (a > 0 && b < behind) { behind = b; prev = t; }
    }
    return { turn, next, ahead, prev };
  },

  // Draws into ctx (CSS pixel units: set the device scale before calling). opts:
  //   data (default: the last answer), w/h (canvas size), scale, names (default true), ticks, pit, credit (false to leave out),
  //   sectors (lap fractions starting with 0, else Lovely's), avoid [{x,y,w,h}] (areas to keep clear)
  // Returns {discs: [{n, turn, x, y, r}], names: [{n, x, y, w, h}]} so a page can react to a hover.
  draw(ctx, project, opts) {
    opts = opts || {};
    const d = opts.data || this.cur;
    const out = { discs: [], names: [] };
    const cvs = ctx.canvas, w = opts.w || cvs.clientWidth || cvs.width, h = opts.h || cvs.clientHeight || cvs.height;
    if (!d || !w || !h) return out;
    const sc = opts.scale || Math.max(0.7, Math.min(1.9, Math.min(w, h) / 440)), r = Math.max(8, Math.round(10.5 * sc));
    const g = ctx;
    g.save();
    g.lineJoin = 'round'; g.lineCap = 'round';

    // the outline as screen points, to keep names off the road
    const NP = 480, scr = [];
    for (let i = 0; i < NP; i++) scr.push(project(i / NP));
    const tick = (pct, len, color, width) => {
      const a = project(pct), b = project(pct + 0.002), dx = b[0] - a[0], dy = b[1] - a[1], m = Math.hypot(dx, dy) || 1, nx = -dy / m, ny = dx / m;
      g.beginPath(); g.moveTo(a[0] - nx * len, a[1] - ny * len); g.lineTo(a[0] + nx * len, a[1] + ny * len);
      g.strokeStyle = color; g.lineWidth = width; g.stroke();
    };
    if (opts.ticks !== false) {
      const secs = opts.sectors && opts.sectors.length > 1 ? opts.sectors : d.sectors || [];
      secs.forEach((p, k) => { if (k) tick(p, 10 * sc, CORNER_COL.sector, Math.max(1.5, 2 * sc)); });
      tick(0, 15 * sc, CORNER_COL.sf, Math.max(3, 4 * sc));
    }

    const placed = (opts.avoid || []).slice();
    if (opts.credit !== false && d.credit) placed.push({ x: 0, y: h - 22, w: Math.min(w, 330), h: 22 });
    const hitsTrack = rc => {
      const m = 9 * sc;
      for (let i = 0; i < scr.length; i++) { const q = scr[i]; if (q[0] > rc.x - m && q[0] < rc.x + rc.w + m && q[1] > rc.y - m && q[1] < rc.y + rc.h + m) return true; }
      return false;
    };
    const clash = (rc, gap) => placed.some(o => rc.x < o.x + o.w + gap && rc.x + rc.w + gap > o.x && rc.y < o.y + o.h + gap && rc.y + rc.h + gap > o.y);
    const inside = rc => rc.x >= 2 && rc.y >= 2 && rc.x + rc.w <= w - 2 && rc.y + rc.h <= h - 4;
    // which way is "outside" the bend at a lap fraction, as a unit vector
    const outward = (pct, P) => {
      const A = project(pct - 0.012), B = project(pct + 0.012);
      let ox = P[0] - (A[0] + B[0]) / 2, oy = P[1] - (A[1] + B[1]) / 2, m = Math.hypot(ox, oy);
      if (m < 2) { const dx = B[0] - A[0], dy = B[1] - A[1], mm = Math.hypot(dx, dy) || 1; ox = -dy / mm; oy = dx / mm; if ((P[0] - w / 2) * ox + (P[1] - h / 2) * oy < 0) { ox = -ox; oy = -oy; } }
      else { ox /= m; oy /= m; }
      return [ox, oy];
    };
    // text of a given size that must not touch the road, a disc or another label; tries a few spots around P
    const putText = (P, ndir, text, font, fs, color, prio) => {
      g.font = font;
      const tw = g.measureText(text).width, th = fs;
      const dirs = [[ndir[0], ndir[1]], [-ndir[0], -ndir[1]], [ndir[1], -ndir[0]], [-ndir[1], ndir[0]]];
      for (const dist of [r + 7 * sc, r + 18 * sc, r + 32 * sc]) {
        for (const [dx, dy] of (prio ? dirs : dirs.slice(0, 2))) {
          const ext = Math.abs(dx) * tw / 2 + Math.abs(dy) * th / 2;
          const cx = P[0] + dx * (dist + ext), cy = P[1] + dy * (dist + ext);
          const rc = { x: cx - tw / 2, y: cy - th / 2, w: tw, h: th };
          if (!inside(rc) || clash(rc, 3) || hitsTrack(rc)) continue;
          placed.push(rc);
          g.textAlign = 'center'; g.textBaseline = 'middle';
          g.lineWidth = Math.max(3, 4 * sc); g.strokeStyle = CORNER_COL.halo; g.strokeText(text, cx, cy + 1);
          g.fillStyle = color; g.fillText(text, cx, cy + 1);
          return rc;
        }
      }
      return null;
    };
    const lspace = f => { if ('letterSpacing' in g) g.letterSpacing = f; };

    // pit lane entry and exit
    if (opts.pit !== false) {
      for (const [pct, text] of [[d.pitIn, 'PIT IN'], [d.pitOut, 'PIT OUT']]) {
        if (typeof pct !== 'number' || !isFinite(pct)) continue;
        const P = project(pct), pr = 5 * sc;
        g.beginPath(); g.arc(P[0], P[1], pr, 0, Math.PI * 2); g.fillStyle = CORNER_COL.ring; g.fill();
        g.lineWidth = Math.max(2, 2.5 * sc); g.strokeStyle = CORNER_COL.pit; g.stroke();
        placed.push({ x: P[0] - pr - 2, y: P[1] - pr - 2, w: 2 * pr + 4, h: 2 * pr + 4 });
        lspace('0.06em');
        putText(P, outward(pct, P), text, '600 ' + Math.round(12 * sc) + 'px ' + CORNER_FONT, Math.round(12 * sc), CORNER_COL.pit, true);
        lspace('0px');
      }
    }

    // the numbered discs: on the line at the apex; a disc that would cover another is slid sideways with a thin lead line
    const turns = d.turns || [];
    const fsNum = n => Math.round(r * (n > 9 ? 1.12 : 1.28));
    const discs = [];
    for (const t of turns) {
      const P = project(t.pctApex), A = project(t.pctApex - 0.004), B = project(t.pctApex + 0.004);
      let nx = -(B[1] - A[1]), ny = B[0] - A[0]; const m = Math.hypot(nx, ny) || 1; nx /= m; ny /= m;
      let cx = P[0], cy = P[1];
      for (const k of [0, 1, -1, 2, -2]) {
        const x = P[0] + nx * k * r * 1.9, y = P[1] + ny * k * r * 1.9;
        if (!discs.some(o => Math.hypot(o.x - x, o.y - y) < 2 * r + 1.5)) { cx = x; cy = y; break; }
      }
      discs.push({ n: t.n, turn: t, x: cx, y: cy, r, px: P[0], py: P[1] });
      placed.push({ x: cx - r - 2, y: cy - r - 2, w: 2 * r + 4, h: 2 * r + 4 });
    }
    // a gold ring round a dark centre with a gold number: unmistakable next to the cars (which are solid dots) and easy to read
    for (const o of discs) {
      if (Math.hypot(o.x - o.px, o.y - o.py) > 1) { g.beginPath(); g.moveTo(o.px, o.py); g.lineTo(o.x, o.y); g.strokeStyle = CORNER_COL.gold; g.lineWidth = 1.2; g.stroke(); }
      g.beginPath(); g.arc(o.x, o.y, r + 1.5, 0, Math.PI * 2); g.fillStyle = CORNER_COL.ring; g.fill();
      g.beginPath(); g.arc(o.x, o.y, r - 0.6 * sc, 0, Math.PI * 2); g.fillStyle = CORNER_COL.centre; g.fill();
      g.lineWidth = Math.max(1.6, 2 * sc); g.strokeStyle = CORNER_COL.gold; g.stroke();
      g.fillStyle = CORNER_COL.gold; g.font = '700 ' + fsNum(o.n) + 'px ' + CORNER_FONT; g.textAlign = 'center'; g.textBaseline = 'middle';
      g.fillText(String(o.n), o.x, o.y + 0.5);
      out.discs.push({ n: o.n, turn: o.turn, x: o.x, y: o.y, r });
    }

    // names, only where there is room
    if (opts.names !== false) {
      const fs = Math.round(11.5 * sc);
      lspace((0.08 * fs).toFixed(2) + 'px');
      let lastName = '';
      for (const o of discs) {
        const same = o.turn.name === lastName; lastName = o.turn.name;
        if (!o.turn.name || same) continue;
        const rc = putText([o.x, o.y], outward(o.turn.pctApex, [o.px, o.py]), o.turn.name.toUpperCase(), '600 ' + fs + 'px ' + CORNER_FONT, fs, CORNER_COL.name, true);
        if (rc) out.names.push({ n: o.n, x: rc.x, y: rc.y, w: rc.w, h: rc.h });
      }
      lspace('0px');
    }

    if (opts.credit !== false && d.credit) {
      g.textAlign = 'left'; g.textBaseline = 'alphabetic'; g.font = Math.round(11 * Math.max(1, sc * 0.9)) + 'px ' + CORNER_FONT; g.fillStyle = CORNER_COL.credit;
      g.fillText(d.credit, 4, h - 5);
    }
    g.restore();
    return out;
  },
};
