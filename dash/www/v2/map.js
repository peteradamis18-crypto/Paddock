'use strict';
// Track map. iRacing does not send GPS live (Lat/Lon only exist in the .ibt files it logs to disk), so
// irdash builds outlines from your own telemetry files, or downloads one from the SIMRacingApps library
// (Apache-2.0, keyed by lap percentage). Cars are placed on the outline from CarIdxLapDistPct.
// Until an outline exists, cars are shown on a straight lap bar instead.
// The outline, sector ticks and corner names are drawn once into an offscreen layer; each animation
// frame only copies that layer and draws the cars.

const MAP_FONT = '"Bahnschrift SemiCondensed", "Bahnschrift", "Segoe UI", sans-serif';
const MAP_COL = {
  shoulder: '#07090c', edge: '#d3d8de', tarmac: '#232a32', pit: '#2b333d', sector: '#77828f', sf: '#ffffff', label: '#8f9aa7',
  halo: '#07090c', pitMark: '#b8c1cb', credit: '#4b5562', car: '#c7cfd8', carRing: '#05070a', me: '#29d3f5',
  gps: '#d4af37',
};

// corners.js (the corner model) is loaded here when the page did not include it itself, so every page that has the map has the corners
const cornersReady = typeof Corners !== 'undefined' ? Promise.resolve() : new Promise(res => {
  const s = document.createElement('script'); s.src = 'corners.js'; s.onload = () => res(); s.onerror = () => res(); document.head.appendChild(s);
});

const TrackMap = {
  N: 720,
  key: '', id: '', rawName: '', name: '', pts: null, pit: null, source: '', status: '', view: null, timer: null,
  layer: null, layerKey: '', gps: null, gpsOverlay: false,

  setTrack(track) {
    if (track.key === this.key) return;
    this.key = track.key; this.id = track.id; this.rawName = track.rawName || '';
    this.name = track.name + (track.config ? ' · ' + track.config : '');
    this.pts = null; this.pit = null; this.source = ''; this.view = null; this.layerKey = '';
    this.gps = null; this.gpsOverlay = false;
    clearTimeout(this.timer);
    if (L.demo && !QS.has('track')) { this.useDemo(); return; }
    this.status = 'No map yet';
    this.load();
  },

  async load() {
    const key = this.key;
    let data = null;
    try {
      const r = await fetch('/trackmap?key=' + encodeURIComponent(key) + '&id=' + encodeURIComponent(this.id) +
        '&name=' + encodeURIComponent(this.rawName), { cache: 'no-store' });
      if (r.ok) data = await r.json();
    } catch (e) { /* irdash restarting */ }
    if (key !== this.key) return;
    // a measured GPS line from Peter's own telemetry (irdash builds it from his .ibt files); Alt is metadata only
    const g = data && data.gps && Array.isArray(data.gps.pts) && data.gps.pts.length >= 100 ? data.gps : null;
    const disp = data && Array.isArray(data.pts) && data.pts.length >= 200 ? data.pts : (g ? g.pts : null);
    if (disp && disp.length >= 200) {
      const src = (data && Array.isArray(data.pts) && data.pts.length >= 200) ? data.source : 'gps';
      const gsig = g ? g.file + ':' + g.n : '';
      const osig = this.gps ? this.gps.file + ':' + this.gps.n : '';
      const changed = !this.pts || src !== this.source || (data && data.recorded) !== this.recorded || gsig !== osig;
      if (changed) {
        this.pts = disp; this.pit = Array.isArray(data.pit) && data.pit.length >= 20 ? data.pit : null;
        this.source = src; this.recorded = data ? data.recorded : ''; this.view = null; this.layerKey = '';
        this.gps = g; this.gpsOverlay = !!(g && this.pts !== g.pts);
      }
      this.status = '';
    } else {
      this.status = 'No map yet'; this.gps = null; this.gpsOverlay = false;
    }
    // keep checking: a fresh lap in your telemetry replaces a library map or the lap bar
    if (this.source !== 'ibt' && this.source !== 'gps') this.timer = setTimeout(() => this.load(), this.pts ? 60000 : 15000);
  },

  useDemo() {
    const pts = [];
    for (let i = 0; i < this.N; i++) { const p = Demo.track.posAt(i / this.N); pts.push([p[0], p[1]]); }
    this.pts = pts; this.pit = null; this.source = 'demo'; this.status = ''; this.view = null; this.layerKey = '';
    this.gps = null; this.gpsOverlay = false;
  },

  label() {
    if (this.status) return this.status;
    return this.source === 'ibt' || this.source === 'gps' ? '' : this.source === 'library' ? 'outline: SIMRacingApps (Apache 2.0)' :
      this.source === 'demo' ? 'demo' : '';
  },

  feed() { /* outlines come from irdash now; nothing to record live */ },

  // position on the outline for a lap fraction, in track metres
  at(pct) {
    const N = this.pts.length, f = ((pct % 1) + 1) % 1 * N, i = Math.floor(f) % N, t = f - Math.floor(f);
    const a = this.pts[i], b = this.pts[(i + 1) % N];
    return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
  },

  // fit the outline into the canvas, rotating 90° if that makes it bigger
  fit(w, h) {
    if (this.view && this.view.w === w && this.view.h === h) return this.view;
    let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    for (const p of this.pts) { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[0]); y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); }
    const pad = 46, tw = x1 - x0 || 1, th = y1 - y0 || 1;
    const sA = Math.min((w - 2 * pad) / tw, (h - 2 * pad) / th), sB = Math.min((w - 2 * pad) / th, (h - 2 * pad) / tw);
    const rot = sB > sA * 1.08;
    this.view = { w, h, s: rot ? sB : sA, rot, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2 };
    return this.view;
  },
  toScreen(p, vw) {
    let x = (p[0] - vw.cx) * vw.s, y = -(p[1] - vw.cy) * vw.s;
    if (vw.rot) { const t = x; x = -y; y = t; }
    return [vw.w / 2 + x, vw.h / 2 + y];
  },
  // clockwise screen angle (deg) of track north; outlines are x = east, y = north
  northDeg() { return this.pts && this.view && this.view.rot ? 90 : 0; },

  draw(cv, w, h) {
    if (!w || !h) return;
    const dpr = window.devicePixelRatio || 1;
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); this.view = null; this.layerKey = ''; }
    const lk = [w, h, dpr, this.key, this.source, this.recorded, !!this.pts, this.status, S.version, TrackInfo.version, this.gpsOverlay ? this.gps.n + ':' + this.gps.meanErrorM : ''].join('|');
    if (lk !== this.layerKey) { this.buildLayer(w, h, dpr); this.layerKey = lk; }
    const g = cv.getContext('2d');
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, cv.width, cv.height);
    g.drawImage(this.layer, 0, 0);
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    let place;
    if (this.pts) { const vw = this.fit(w, h); place = pct => this.toScreen(this.at(pct), vw); }
    else { const x0 = 40, span = w - 80, y = h / 2; place = pct => [x0 + (((pct % 1) + 1) % 1) * span, y]; }
    this.drawCars(g, place);
  },

  buildLayer(w, h, dpr) {
    if (!this.layer) this.layer = document.createElement('canvas');
    const c = this.layer;
    c.width = Math.round(w * dpr); c.height = Math.round(h * dpr);
    const g = c.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    g.lineJoin = 'round'; g.lineCap = 'round';
    const tick = (a, b, len, color, width) => {
      const dx = b[0] - a[0], dy = b[1] - a[1], m = Math.hypot(dx, dy) || 1, nx = -dy / m, ny = dx / m;
      g.beginPath(); g.moveTo(a[0] - nx * len, a[1] - ny * len); g.lineTo(a[0] + nx * len, a[1] + ny * len);
      g.strokeStyle = color; g.lineWidth = width; g.stroke();
    };
    if (this.pts) {
      const vw = this.fit(w, h);
      const scr = this.pts.map(p => this.toScreen(p, vw));
      const line = (pts, closed) => {
        g.beginPath();
        pts.forEach((q, i) => (i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1])));
        if (closed) g.closePath();
      };
      // the road: a dark casing, a thin white edge, the dark surface (scaled so a small card still reads)
      const sc = Math.max(0.7, Math.min(1.9, Math.min(w, h) / 440));
      if (this.pit) { line(this.pit.map(p => this.toScreen(p, vw)), false); g.setLineDash([5, 6]); g.strokeStyle = MAP_COL.pit; g.lineWidth = 3 * sc; g.stroke(); g.setLineDash([]); }
      line(scr, true); g.strokeStyle = MAP_COL.shoulder; g.lineWidth = 24 * sc; g.stroke();
      line(scr, true); g.strokeStyle = MAP_COL.edge; g.lineWidth = 14 * sc; g.stroke();
      line(scr, true); g.strokeStyle = MAP_COL.tarmac; g.lineWidth = 11.4 * sc; g.stroke();
      // the measured line Peter drove (his telemetry): a thin gold hairline over the road. Alt never moves it.
      if (this.gps && this.gpsOverlay) {
        line(this.gps.pts.map(p => this.toScreen(p, vw)), true);
        g.globalAlpha = 0.7; g.strokeStyle = MAP_COL.gps; g.lineWidth = 1.8 * sc; g.stroke(); g.globalAlpha = 1;
      }
      const sp = pct => this.toScreen(this.at(pct), vw);
      const secs = S.sectors.length > 1 ? S.sectors : (TrackInfo.data && TrackInfo.data.sectors) || S.sectors;
      secs.forEach((p, k) => { if (k) tick(sp(p), sp(p + 0.002), 10 * sc, MAP_COL.sector, 2 * sc); });
      tick(sp(0), sp(0.002), 15 * sc, MAP_COL.sf, 4 * sc);
      this.drawTrackInfo(g, w, h, sp);
    } else {
      const x0 = 40, x1 = w - 40, y = h / 2, span = x1 - x0;
      g.beginPath(); g.moveTo(x0, y); g.lineTo(x1, y); g.strokeStyle = MAP_COL.shoulder; g.lineWidth = 20; g.stroke();
      g.beginPath(); g.moveTo(x0, y); g.lineTo(x1, y); g.strokeStyle = MAP_COL.tarmac; g.lineWidth = 8; g.stroke();
      g.font = '14px ' + MAP_FONT; g.textAlign = 'center';
      S.sectors.forEach((p, k) => {
        const x = x0 + p * span;
        g.beginPath(); g.moveTo(x, y - 15); g.lineTo(x, y + 15); g.strokeStyle = k ? MAP_COL.sector : MAP_COL.sf; g.lineWidth = k ? 2 : 4; g.stroke();
        g.fillStyle = MAP_COL.label; g.fillText(k === 0 ? 'S/F' : 'S' + (k + 1), x, y + 36);
      });
      g.fillStyle = MAP_COL.label; g.font = '17px ' + MAP_FONT;
      g.fillText(this.status || '', w / 2, y - 42);
    }
  },

  // numbered corner discs, names, pit lane marks and the credit line: one shared drawing (corners.js), the same on every page
  drawTrackInfo(g, w, h, sp) {
    if (typeof Corners === 'undefined') return;
    this.corners = Corners.draw(g, sp, { data: TrackInfo.raw || NO_CORNERS, w, h, ticks: false, avoid: [{ x: w - 210, y: h - 50, w: 210, h: 50 }] });   // clear of the wind readout
  },
  drawCars(g, place) {
    const v = L.v, pcts = v.CarIdxLapDistPct;
    if (!pcts || !S.drivers.size) return;
    const me = focusIdx(), multi = S.multiClass;
    const list = [];
    for (const d of racers()) {
      const p = pcts[d.idx];
      if (!isNum(p) || p < 0 || arr('CarIdxTrackSurface', d.idx) === -1) continue;
      list.push({ d, p, pit: !!arr('CarIdxOnPitRoad', d.idx), pos: (multi ? arr('CarIdxClassPosition', d.idx) : arr('CarIdxPosition', d.idx)) || 0 });
    }
    list.sort((a, b) => (a.d.idx === me) - (b.d.idx === me) || b.pos - a.pos);
    g.textAlign = 'center'; g.textBaseline = 'middle';
    for (const c of list) {
      const [x, y] = place(c.p);
      const mine = c.d.idx === me, r = mine ? 16 : 11.5;
      g.globalAlpha = c.pit && !mine ? 0.35 : 1;
      if (mine) { g.beginPath(); g.arc(x, y, r + 9, 0, Math.PI * 2); g.fillStyle = 'rgba(41,211,245,.20)'; g.fill(); }
      g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2);
      g.fillStyle = mine ? '#ffffff' : (multi ? c.d.color : MAP_COL.car); g.fill();
      g.lineWidth = mine ? 4.5 : 2; g.strokeStyle = mine ? MAP_COL.me : MAP_COL.carRing; g.stroke();
      g.fillStyle = '#05070a'; g.font = (mine ? '700 17px ' : '700 13px ') + MAP_FONT;
      g.fillText(c.pos > 0 ? String(c.pos) : (c.d.num || ''), x, y + 1);
    }
    g.globalAlpha = 1; g.textBaseline = 'alphabetic';
  },
};

/* ---------------- corners: numbers, names, pit lane (the corner model, corners.js) ----------------
   Kept under its old name because the debrief, brief, guest and sessions pages read TrackInfo.data / .version.
   data.turns = [{ pct (apex), label ("T5" or a real name), n, name, pct0, pct1, source }], plus pitIn, pitOut, sectors, credit.
   irdash serves the turns (its own copy of Lovely Track Data first; corners found in your laps where Lovely has none),
   so this works with the internet off. A track with no corners yet is asked again now and then. */
const NO_CORNERS = { turns: [], sectors: [], credit: '', pitIn: null, pitOut: null };

const TrackInfo = {
  CREDIT: 'Corner names: Lovely Track Data \u00b7 CC BY-NC-SA 4.0',
  key: '', data: null, raw: null, version: 0, timer: null,

  setTrack(track) {
    if (track.key === this.key) return;
    this.key = track.key; this.data = null; this.raw = null; this.version++;
    clearTimeout(this.timer);
    if (L.demo && !QS.has('track')) { this.useDemo(Demo.trackInfo(), 'Demo corner names (synthetic)'); return; }
    this.load(track).catch(e => console.warn('track info', e));
  },

  async load(track) {
    const key = this.key;
    await cornersReady;
    if (typeof Corners === 'undefined' || key !== this.key) return;
    const d = await Corners.load(track);
    if (key !== this.key) return;
    if (d) this.adopt(d);
    // no corners yet (a track never driven, or still being worked out from your laps): look again later
    if (!d || d.source === 'none') this.timer = setTimeout(() => { if (key === this.key) this.load(track).catch(() => {}); }, d && d.pending ? 6000 : 60000);
  },

  adopt(d) {
    const turns = d.turns.map(t => ({ pct: t.pctApex, label: t.name || 'T' + t.n, n: t.n, name: t.name, pct0: t.pct0, pct1: t.pct1, source: t.source }));
    const same = this.raw && this.raw.source === d.source && this.raw.updated === d.updated && this.raw.turns.length === d.turns.length && this.raw.pitIn === d.pitIn && this.raw.pitOut === d.pitOut;
    this.raw = d;
    this.data = turns.length || isNum(d.pitIn) || isNum(d.pitOut) ? { turns, pitIn: isNum(d.pitIn) ? d.pitIn : NaN, pitOut: isNum(d.pitOut) ? d.pitOut : NaN, sectors: d.sectors, credit: d.credit, source: d.source } : null;
    if (!same) this.version++;
  },

  // the demo circuit's corners come in Lovely's file format
  useDemo(d, credit) {
    const src = Array.isArray(d.turn) ? d.turn : [], turns = [];
    src.slice().sort((a, b) => a.apex - b.apex).forEach((t, i) => {
      const plain = /^(turn\s*)?\d+[a-z]?$/i.test(String(t.name).trim());
      turns.push({ n: i + 1, name: plain ? '' : String(t.name).trim(), official: '', pct0: t.start, pctApex: t.apex, pct1: t.end, source: 'demo', pct: t.apex, label: plain ? 'T' + (i + 1) : String(t.name).trim() });
    });
    this.raw = { source: 'demo', turns, pitIn: num(d.pitentry), pitOut: num(d.pitexit), sectors: [], credit };
    this.data = { turns: turns.map(t => ({ pct: t.pctApex, label: t.label, n: t.n, name: t.name, pct0: t.pct0, pct1: t.pct1, source: 'demo' })), pitIn: this.raw.pitIn, pitOut: this.raw.pitOut, sectors: [], credit, source: 'demo' };
    this.version++;
  },
};