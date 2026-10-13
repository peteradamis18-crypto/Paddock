'use strict';
// Race extras in the standings header: strength of field and the iRating change you would get if the race ended now.
// irdash /race does the sums (your class only, from the session's iRatings) and says nothing outside rated races.
// The formula is the community one: see docs\data.md.
const RaceExtras = {
  el: null, last: '',

  init() { this.el = $('sofBox'); if (this.el) { this.tick(); setInterval(() => this.tick(), 2000); } },

  hide() { if (this.el && !this.el.hidden) { this.el.hidden = true; this.last = ''; } },

  async tick() {
    if (document.hidden) return;
    if (!UI.live() || !isRace() || L.demo) { this.hide(); return; }
    let r;
    try { r = await (await fetch('/race', { cache: 'no-store' })).json(); } catch (e) { return; }
    if (!r.on) { this.hide(); return; }
    const sof = Math.round(r.sof).toLocaleString('en-GB');
    let h = '<em>SoF</em>' + sof;
    if (isNum(r.delta)) {
      const d = Math.round(r.delta);
      h += '<span class="sep">·</span><em>iRating</em><span class="' + (d >= 0 ? 'up' : 'down') + '">' + (d >= 0 ? '+' : '−') + Math.abs(d) + '</span>';
    } else if (!r.official) h += '<span class="sep">·</span><em>unrated</em>';
    if (h !== this.last) { this.last = h; this.el.innerHTML = h; }
    this.el.title = 'SoF ' + sof + ' · ' + r.n + ' drivers · ' + (r.cls || 'class') +
      (isNum(r.delta) ? ' · iRating ' + (r.delta >= 0 ? '+' : '−') + Math.abs(Math.round(r.delta)) + ' at P' + r.pos : '');
    this.el.hidden = false;
  },
};
RaceExtras.init();
