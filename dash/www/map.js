'use strict';
// Track map. iRacing does not send GPS live (Lat/Lon only exist in the .ibt files it logs to disk), so
// irdash builds outlines from your own telemetry files, or downloads one from the SIMRacingApps library
// (Apache-2.0, keyed by lap percentage). Cars are placed on the outline from CarIdxLapDistPct.
// Until an outline exists, cars are shown on a straight lap bar instead.

const TrackMap = {
  N: 720,
  key: '', id: '', rawName: '', name: '', pts: null, pit: null, source: '', status: '', view: null, timer: null,

  setTrack(track) {
    if (track.key === this.key) return;
    this.key = track.key; this.id = track.id; this.rawName = track.rawName || '';
    this.name = track.name + (track.config ? ' - ' + track.config : '');
    this.pts = null; this.pit = null; this.source = ''; this.view = null;
    clearTimeout(this.timer);
    if (L.demo) { this.useDemo(); return; }
    this.status = 'Looking for a map';
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
    if (data && Array.isArray(data.pts) && data.pts.length >= 200) {
      const changed = !this.pts || data.source !== this.source || data.recorded !== this.recorded;
      if (changed) {
        this.pts = data.pts; this.pit = Array.isArray(data.pit) && data.pit.length >= 20 ? data.pit : null;
        this.source = data.source; this.recorded = data.recorded; this.view = null;
      }
      this.status = '';
    } else {
      this.status = 'Map appears after you drive about one clean lap here';
    }
    // keep checking: a fresh lap in your telemetry replaces a library map or the lap bar
    if (this.source !== 'ibt') this.timer = setTimeout(() => this.load(), this.pts ? 60000 : 15000);
  },

  useDemo() {
    const pts = [];
    for (let i = 0; i < this.N; i++) { const p = Demo.track.posAt(i / this.N); pts.push([p[0], p[1]]); }
    this.pts = pts; this.pit = null; this.source = 'demo'; this.status = ''; this.view = null;
  },

  label() {
    if (this.status) return this.status;
    const src = this.source === 'ibt' ? 'from your telemetry' : this.source === 'library' ? 'outline: SIMRacingApps (Apache 2.0)' : this.source;
    return this.name + (src ? '  ·  ' + src : '');
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
    const pad = 30, tw = x1 - x0 || 1, th = y1 - y0 || 1;
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

  draw(cv) {
    const dpr = window.devicePixelRatio || 1, w = cv.clientWidth, h = cv.clientHeight;
    if (!w || !h) return;
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); this.view = null; }
    const g = cv.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    g.lineJoin = 'round'; g.lineCap = 'round';
    let place;
    if (this.pts) {
      const vw = this.fit(w, h);
      const line = (pts, closed) => {
        g.beginPath();
        pts.forEach((p, i) => { const q = this.toScreen(p, vw); i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1]); });
        if (closed) g.closePath();
      };
      if (this.pit) { line(this.pit, false); g.setLineDash([6, 6]); g.strokeStyle = '#3a4553'; g.lineWidth = 3; g.stroke(); g.setLineDash([]); }
      line(this.pts, true); g.strokeStyle = '#1a212b'; g.lineWidth = 16; g.stroke();
      line(this.pts, true); g.strokeStyle = '#46525f'; g.lineWidth = 7; g.stroke();
      // sector marks and start/finish line
      S.sectors.forEach((sp, k) => {
        const a = this.toScreen(this.at(sp), vw), b = this.toScreen(this.at(sp + 0.002), vw);
        const dx = b[0] - a[0], dy = b[1] - a[1], m = Math.hypot(dx, dy) || 1, nx = -dy / m, ny = dx / m;
        const len = k === 0 ? 14 : 9;
        g.beginPath(); g.moveTo(a[0] - nx * len, a[1] - ny * len); g.lineTo(a[0] + nx * len, a[1] + ny * len);
        g.strokeStyle = k === 0 ? '#ffffff' : '#ffc400'; g.lineWidth = k === 0 ? 4 : 2.5; g.stroke();
      });
      place = pct => this.toScreen(this.at(pct), vw);
    } else {
      // no outline yet: a straight lap bar, start/finish on the left
      const x0 = 40, x1 = w - 40, y = h / 2, span = x1 - x0;
      g.beginPath(); g.moveTo(x0, y); g.lineTo(x1, y); g.strokeStyle = '#1a212b'; g.lineWidth = 16; g.stroke();
      g.beginPath(); g.moveTo(x0, y); g.lineTo(x1, y); g.strokeStyle = '#46525f'; g.lineWidth = 7; g.stroke();
      S.sectors.forEach((sp, k) => {
        const x = x0 + sp * span;
        g.beginPath(); g.moveTo(x, y - 16); g.lineTo(x, y + 16); g.strokeStyle = k === 0 ? '#fff' : '#ffc400'; g.lineWidth = k === 0 ? 4 : 2.5; g.stroke();
        g.fillStyle = '#7d8996'; g.font = '13px Bahnschrift, Segoe UI, sans-serif'; g.textAlign = 'center';
        g.fillText(k === 0 ? 'S/F' : 'S' + (k + 1), x, y + 34);
      });
      g.fillStyle = '#7d8996'; g.font = '16px Bahnschrift, Segoe UI, sans-serif'; g.textAlign = 'center';
      g.fillText(this.status || '', w / 2, y - 40);
      place = pct => [x0 + (((pct % 1) + 1) % 1) * span, y];
    }
    this.drawCars(g, place);
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
      const mine = c.d.idx === me, r = mine ? 15 : 11;
      g.globalAlpha = c.pit && !mine ? 0.35 : 1;
      g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2);
      g.fillStyle = mine ? '#ffc400' : (multi ? c.d.color : '#d9e0e7'); g.fill();
      g.lineWidth = mine ? 3 : 1.5; g.strokeStyle = mine ? '#ffffff' : '#05070a'; g.stroke();
      g.fillStyle = '#05070a'; g.font = (mine ? 'bold 15px ' : 'bold 12px ') + 'Bahnschrift, Segoe UI, sans-serif';
      g.fillText(c.pos > 0 ? String(c.pos) : (c.d.num || ''), x, y + 1);
    }
    g.globalAlpha = 1; g.textBaseline = 'alphabetic';
  },
};
