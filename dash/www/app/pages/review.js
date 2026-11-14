/* REVIEW (W4-3, docs/rework/PLAN.md 4.4 "Screen 1: the card"): what to change next time, on one screen, after every drive.
   A page module for the shell (W3-1):  mount(el, ctx)  ctx = { data, Fmt, go, close, banner, kidsOn(), driving(), opts };  unmount();  onState
   Copied from Coach Dave Delta's screen shape (the map is the hero, a few insights you can press), LapBrain's four-line card (where,
   what happened, the seconds, one thing to try; evidence 12) and the engineering debrief's one next-session plan.
   Screens (ctx.opts.screen): 'card' (this file, the default), 'laps' (W4-4, review-laps.js) and 'more' (W4-5, review-more.js), handed over
   by name; until those exist the screen says "Coming with the next update". Progress (W4-6, review-progress.js) is a band under the plan.
   Which drive: ctx.opts.id (a telemetry file id), else ctx.opts.at (a string = an id; a number = RACES' race start in ms, sent along as
   &at= for /api/review to pick), else "last" (HOME's after-drive card and the deck's REVIEW key).
   Requests: one data.json('/api/review?id=…') at mount, the map's one outline fetch, the clip only when WATCH is pressed. Nothing on a
   timer: a review still being built ("working") is asked for again when irdash says the review list changed (data.onList('review')),
   and an answer that failed is asked for again when Paddock is back (data.on('online')).
   Every word on the card comes from the review engine (dash/src/review.cs, Review.Lint keeps it honest); this page only lays it out. */
const DOT = ' · ';
const SUB = { laps: './review-laps.js', more: './review-more.js' };
const CLIP_SECONDS = 10;                    // WATCH plays this much of the corner, then holds the picture
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const num = x => typeof x === 'number' && isFinite(x);
const memo = {};                            // the last ready answer per drive: shown greyed while Paddock is not running

// ---------------------------------------------------------------- pure helpers (the test imports them)
// "T5" -> "Turn 5"; a name from the corner list follows ("Turn 5 · Tower Hairpin")
export function cornerName(c) {
  if (!c) return '';
  const m = /^T(\d+)$/i.exec(String(c.label || '').trim());
  const base = m ? 'Turn ' + m[1] : String(c.label || (c.n ? 'Turn ' + c.n : ''));
  return base + (c.name ? DOT + c.name : '');
}
// 0.31 -> "0.31 s"
export function secs(x) { return num(x) ? Math.abs(x).toFixed(2) + ' s' : ''; }
// a race pace to the tenth, as people say it: 94.1 -> "1:34.1"
export function lap1(s) {
  if (!num(s) || s <= 0) return '';
  let m = Math.floor(s / 60), r = Math.round((s - m * 60) * 10) / 10;
  if (r >= 60) { m += 1; r = 0; }
  return m + ':' + (r < 10 ? '0' : '') + r.toFixed(1);
}
// local day, as the shell's header writes it: "Thu 13 Nov" (long) or "6 Nov" (short)
export function day(ms, long) {
  if (!num(ms)) return '';
  const d = new Date(ms);
  return long ? d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' }).replace(',', '')
    : d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
}
// the top line's result: "P4 from P7 · +41 iRating (estimate)" when the iRating change is known, else "P4 of 19"
export function resultLine(r) {
  if (!r || !(r.finish > 0)) return '';
  if (num(r.irating)) {
    const ir = Math.round(r.irating);
    return 'P' + r.finish + (r.start > 0 ? ' from P' + r.start : r.field > 0 ? ' of ' + r.field : '') + DOT + (ir < 0 ? '−' + -ir : '+' + ir) + ' iRating (estimate)';
  }
  return 'P' + r.finish + (r.field > 0 ? ' of ' + r.field : r.start > 0 ? ' from P' + r.start : '');
}
// which lap the card is measured against, in his words (the card always says which: PLAN 4.4 "Reference lap")
export function refLine(ref, F) {
  if (!ref) return '';
  if (ref.kind === 'ever') return 'Compared with: your best here' + (num(ref.date) ? ', ' + day(ref.date) : '') + (ref.conditions ? DOT + ref.conditions : '');
  return 'Compared with: lap ' + ref.lap + ' of this session' + (num(ref.time) ? ' (' + F.lap(ref.time) + ')' : '');
}
// "Your average 1:34.1 · the field 1:34.8 · 19 cars"
export function paceLine(p) {
  if (!p || !num(p.mine)) return '';
  return 'Your average ' + lap1(p.mine) + (num(p.field) ? DOT + 'the field ' + lap1(p.field) : '') + (p.cars > 0 ? DOT + p.cars + ' cars' : '');
}
// the drive this page asks for (see the header)
export function reviewUrl(o) {
  o = o || {};
  if (o.id) return '/api/review?id=' + encodeURIComponent(o.id);
  if (typeof o.at === 'string' && o.at && !/^\d+$/.test(o.at)) return '/api/review?id=' + encodeURIComponent(o.at);
  if (o.at && +o.at > 0) return '/api/review?id=last&at=' + Math.round(+o.at);
  return '/api/review?id=last';
}
// the card's never-say list, as Review.Lint on the server (PLAN 4.4 "Card wording"): the first rule broken, or null
export function lint(text) {
  const t = String(text || '').trim();
  if (!t) return null;
  if (/%/.test(t)) return 'a percentage';
  if (/\b(mistakes?|errors?|bad|wasted?)\b/i.test(t)) return 'scolding';
  if (/\byou should\b/i.test(t)) return '"you should"';
  if (t.split(/\s+/).length > 14) return 'over 14 words';
  return null;
}

// ---------------------------------------------------------------- the page
const R = {
  el: null, ctx: null, offs: [], url: '', j: null, stale: false, gen: 0, screen: 'card',
  map: null, mapMod: null, sub: null, prog: null, vid: null, keyOff: null,

  $(c) { return R.el ? R.el.querySelector(c) : null; },

  mount(el, ctx) {
    R.el = el; R.ctx = ctx; R.offs = []; R.j = null; R.stale = false; R.sub = null; R.prog = null; R.map = null; R.mapMod = null;
    const o = ctx.opts || {};
    if (!document.querySelector('link[data-page="review"]')) {
      const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = new URL('./review.css', import.meta.url).href; l.dataset.page = 'review';
      document.head.appendChild(l);
    }
    // Esc closes an open clip first (capture: before the shell's own Esc, which then sees it used)
    const key = e => { if (e.key === 'Escape' && R.vid) { e.preventDefault(); R.closeWatch(); } };
    document.addEventListener('keydown', key, true); R.keyOff = () => document.removeEventListener('keydown', key, true);
    R.screen = SUB[o.screen] ? o.screen : 'card';
    if (R.screen !== 'card') { R.mountSub(R.screen, o); return; }
    R.url = reviewUrl(o);
    el.innerHTML = '<div class="rv"></div>';
    const d = ctx.data;
    R.offs.push(d.onList('review', () => { if (!R.j || R.j.state !== 'ready') R.load(); }));
    R.offs.push(d.on('online', on => { if (on && (R.stale || !R.j)) R.load(); else if (!on) { R.stale = true; R.draw(); } }));     // off: what is on screen greys, nothing more is asked
    if (d.online === false) { R.stale = true; R.draw(); }     // nothing to ask: the answer comes when Paddock is back
    else R.load();
  },

  unmount() {
    R.gen++;
    R.closeWatch();
    R.offs.forEach(f => { try { if (typeof f === 'function') f(); } catch (e) { } }); R.offs = [];
    if (R.keyOff) { R.keyOff(); R.keyOff = null; }
    R.dropMap();
    for (const m of [R.sub, R.prog]) if (m && m.unmount) { try { m.unmount(); } catch (e) { console.error(e); } }
    R.sub = null; R.prog = null; R.el = null; R.ctx = null;
    document.body.classList.remove('page-bar');
  },

  // screens 2 and 3 get the state pushes (they read the deck's REVIEW arrows from the "workbench" part themselves: one path only)
  onState(st, ch) {
    const s = R.sub; if (!s || !st) return;
    if (s.onState) { try { s.onState(st, ch); } catch (e) { console.error(e); } }
  },

  async load() {
    const gen = ++R.gen, url = R.url;
    let j = null;
    try { j = await R.ctx.data.json(url, 0); } catch (e) { j = null; }
    if (gen !== R.gen || !R.el) return;
    if (!j) { R.stale = true; R.draw(); return; }
    R.stale = false; R.j = j;
    if (j.state === 'ready') memo[url] = j;
    R.draw();
  },

  // ---- what shows: offline (the last answer greyed, or one sentence), working (one line), the card, the race story, no full lap ----
  draw() {
    const box = R.$('.rv'); if (!box) return;
    const j = R.stale ? memo[R.url] || null : R.j;
    R.closeWatch(); R.dropMap();
    document.body.classList.remove('page-bar');
    box.classList.toggle('stale', R.stale && !!j);
    // nothing seen before: Paddock off (the shell's banner says so) or Paddock on but the answer failed (asked again on the list's change)
    if (!j) { box.innerHTML = !R.stale ? '' : R.line(R.ctx.data.online === false ? 'Your review shows here when Paddock is running.' : 'This review could not be read.'); return; }
    if (j.state === 'working') { box.innerHTML = R.line(j.say || 'Reading your laps…'); return; }
    if (j.state !== 'ready' || !j.session) { box.innerHTML = R.line(j.say || 'This drive could not be read.'); return; }
    const s = j.session, race = j.race || null, F = R.ctx.Fmt;
    const cards = (j.cards || []).slice().sort((a, b) => (a.rank || 0) - (b.rank || 0)).slice(0, 3);
    const noLap = !(j.laps && j.laps.length) && !cards.length && !race;
    const main = race && race.cleanAir ? race.cleanAir : cards[0] || null;
    const watchClip = main ? main.clip || null : race && race.corners && race.corners[0] ? race.corners[0].clip || null : null;
    const showN = main ? main.corner.n : race && race.corners && race.corners[0] ? race.corners[0].n : null;
    const res = race || /race/i.test(s.type || '') ? resultLine(s.result) : '';
    box.innerHTML =
      '<header class="rv-top"><div class="what"><span class="trk">' + esc(s.track) + (s.config ? ' <span class="cfg">' + esc(s.config) + '</span>' : '') + '</span>' +
      '<span class="sub">' + esc([s.car, F.sessionName(s.type), day(s.date, true)].filter(Boolean).join(DOT)) + '</span></div>' +
      (res ? '<div class="res">' + esc(res) + '</div>' : '') + '</header>' +
      '<div class="rv-main"><section class="rv-map" aria-label="Track map"><div class="map-host"></div></section>' +
      '<section class="rv-right">' + (noLap ? R.noLap(j) : race ? R.story(race) : R.cardsHtml(cards, j.note)) + '</section></div>' +
      (noLap ? '' :
        '<footer class="rv-bottom"><div class="plan-box">' + (j.plan ? '<p class="plan">' + esc(j.plan) + '</p>' : '') +
        '<p class="ref">' + esc(refLine(s.ref, F)) + '</p></div><div class="acts">' +
        '<button type="button" class="btn more">More data</button>' +
        (showN != null ? '<button type="button" class="btn gold show" data-n="' + esc(showN) + '">Show me</button>' : '') +
        R.watchBtn('watch', watchClip, main ? cornerName(main.corner) + DOT + secs(main.lost) : '') + '</div></footer>') +
      '<section class="rv-progress" hidden></section>';
    // presses: SHOW ME, a card (that corner on screen 2), WATCH, a race corner's WATCH, MORE DATA
    box.querySelectorAll('[data-n]').forEach(b => b.addEventListener('click', e => { if (!e.target.closest('.cr-watch')) R.showMe(+b.dataset.n); }));
    box.querySelectorAll('.watch, .cr-watch').forEach(b => b.addEventListener('click', e => { e.stopPropagation(); R.watch(b); }));
    const more = R.$('.more'); if (more) more.addEventListener('click', () => R.ctx.go('review', { screen: 'more', at: s.id, id: s.id }));
    document.body.classList.toggle('page-bar', !!R.$('.rv-bottom'));    // the shell's banner then sits above the plan and its buttons
    if (R.stale) box.querySelectorAll('button').forEach(b => { b.disabled = true; });   // the last answer, greyed: nothing to press until Paddock is back
    R.mountMap(j.map, race);
    if (!race && !noLap && !R.stale) R.mountProgress(j, cards);
  },
  line(t) { return '<div class="rv-line"><p>' + esc(t) + '</p></div>'; },
  watchBtn(cls, clip, what) {
    if (!clip) return '<button type="button" class="btn ' + cls + '" disabled>Watch<span class="no">no clip</span></button>';
    return '<button type="button" class="btn ' + cls + '" data-clip="' + esc(clip.id) + '" data-at="' + (+clip.at || 0) + '" data-what="' + esc(what) + '">Watch</button>';
  },
  card(c, tag) {
    return '<article class="card" data-n="' + esc(c.corner.n) + '" data-rank="' + esc(c.rank || '') + '">' +
      '<div class="c-text"><div class="c-head"><span class="mk">' + esc(c.rank || '') + '</span><span class="c-name">' + esc(cornerName(c.corner)) + '</span>' +
      (tag ? '<span class="c-tag">' + esc(tag) + '</span>' : c.corner.detected ? '<span class="c-tag">detected</span>' : '') + '</div>' +
      '<p class="c-what">' + esc(c.happened) + '</p>' +
      (c.tryThis ? '<p class="c-try"><span class="try">Try this:</span> ' + esc(c.tryThis) + '</p>' : '') + '</div>' +
      '<div class="c-num"><span class="lost">' + esc(secs(c.lost)) + '</span><span class="c-sample">' + esc(c.sample || '') + '</span></div></article>';
  },
  cardsHtml(cards, note) {
    return (note ? '<p class="note">' + esc(note) + '</p>' : '') +
      (cards.length ? '<div class="cards">' + cards.map(c => R.card(c)).join('') + '</div>' : note ? '' : '<p class="note">No corner lost time against that lap.</p>');
  },
  noLap(j) {
    return '<div class="nolap"><p class="big">' + esc(j.note || 'No full lap yet') + '</p>' +
      '<p class="say">Drive one full lap and your corners show here.</p>' +
      '<button type="button" class="btn gold more">More data</button></div>';
  },
  // the race story (PLAN 4.4): position by lap, pace against the field, the three costliest corners with their clips, one clean-air card
  story(r) {
    const pos = (r.positions || []).filter(p => p > 0);
    const corners = (r.corners || []).slice(0, 3);
    return '<div class="story">' +
      (pos.length ? '<div class="st-pos"><span class="lbl">Position by lap</span>' + R.posChart(pos) + '</div>' : '') +
      (paceLine(r.pace) ? '<p class="pace">' + esc(paceLine(r.pace)) + '</p>' : '') +
      (corners.length ? '<div class="costly"><span class="lbl">Where the race lost time</span>' + corners.map((c, i) =>
        '<div class="cr" data-n="' + esc(c.n) + '"><span class="mk">' + (i + 1) + '</span><span class="c-name">' + esc(cornerName(c)) + '</span>' +
        '<span class="cr-lost">' + esc(secs(c.lost)) + '</span>' + R.watchBtn('cr-watch', c.clip, cornerName(c) + DOT + secs(c.lost)) + '</div>').join('') + '</div>' : '') +
      (r.cleanAir ? '<div class="cards">' + R.card(Object.assign({}, r.cleanAir, { rank: '' }), 'clean-air lap') + '</div>' : '') +
      '</div>';
  },
  // plain SVG, no library: P1 at the top, one point per lap, the first and last place written beside the line
  posChart(pos) {
    const W = 872, H = 150, padL = 72, padR = 72, padT = 16, padB = 16;
    const lo = Math.min.apply(null, pos), hi = Math.max.apply(null, pos), span = Math.max(1, hi - lo);
    const x = i => pos.length === 1 ? (padL + W - padR) / 2 : padL + i * (W - padL - padR) / (pos.length - 1);
    const y = p => padT + (p - lo) / span * (H - padT - padB);
    const pts = pos.map((p, i) => x(i).toFixed(1) + ',' + y(p).toFixed(1)).join(' ');
    return '<div class="pos-wrap"><svg class="pos" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '" aria-label="Position by lap">' +
      '<polyline class="ln" points="' + pts + '"/>' + pos.map((p, i) => '<circle class="pt" data-lap="' + (i + 1) + '" data-p="' + p + '" cx="' + x(i).toFixed(1) + '" cy="' + y(p).toFixed(1) + '" r="6"/>').join('') +
      '</svg><span class="p0" style="top:' + (y(pos[0]) - 16).toFixed(0) + 'px">P' + pos[0] + '</span>' +
      '<span class="p1" style="top:' + (y(pos[pos.length - 1]) - 16).toFixed(0) + 'px">P' + pos[pos.length - 1] + '</span></div>' +
      '<div class="pos-x"><span style="left:' + x(0).toFixed(0) + 'px">Lap 1</span>' +
      (pos.length > 1 ? '<span style="left:' + x(pos.length - 1).toFixed(0) + 'px">Lap ' + pos.length + '</span>' : '') + '</div>';
  },

  showMe(n) {
    const s = R.j && R.j.session; if (!s || R.stale) return;
    R.ctx.go('review', { screen: 'laps', corner: n, id: s.id, at: s.id });      // at: the session, so screen 2 opens this drive
  },

  // ---- the map (W4-2's lib/map.js): coloured by where time went, the corners of the cards marked 1, 2, 3 ----
  async mountMap(m, race) {
    const host = R.$('.map-host'); if (!host || !m) { if (host) host.innerHTML = '<p class="no-map">Map not available</p>'; return; }
    const gen = R.gen;
    let M = null;
    try { const mod = await import('../lib/map.js'); M = mod.Map || mod.TrackMap || mod.default || null; } catch (e) { M = null; }
    if (gen !== R.gen || !R.el || R.$('.map-host') !== host) return;
    if (!M || !M.mount) { host.innerHTML = '<p class="no-map">Map not available</p>'; return; }
    try {
      const r = host.getBoundingClientRect();
      let inst = M.mount(host, { key: m.key, id: m.id, size: Math.floor(Math.min(r.width, r.height)) });
      if (inst && typeof inst.then === 'function') inst = await inst;
      const api = inst && typeof inst.colour === 'function' ? inst : M;
      R.map = api; R.mapMod = M;
      if (m.gain && m.gain.length && api.colour) api.colour(m.gain);
      if (m.marks && m.marks.length && api.marks) api.marks(m.marks);
    } catch (e) { console.error(e); host.innerHTML = '<p class="no-map">Map not available</p>'; R.map = null; }
  },
  dropMap() {
    const a = R.map, M = R.mapMod; R.map = null; R.mapMod = null;
    try { if (a && a.unmount) a.unmount(); else if (M && M.unmount) M.unmount(); } catch (e) { console.error(e); }
  },

  // ---- progress (W4-6): a band under the plan line, for this car and track; nothing when the module is not there yet ----
  async mountProgress(j, cards) {
    const gen = R.gen;
    let P = null;
    try { const mod = await import('./review-progress.js'); P = mod.default && mod.default.mount ? mod.default : mod; } catch (e) { P = null; }
    const band = R.$('.rv-progress');
    if (gen !== R.gen || !band || !P || !P.mount) return;
    try {
      band.hidden = false; R.$('.rv').classList.add('has-prog');      // the cards close up so all three still fit above the plan
      const s = j.session, ids = { car: s.carId != null ? s.carId : s.car, track: s.track };
      // the engine matches the corner trend and the iRating line by the track's NAME (review.cs Progress)
      P.mount(band, R.ctx, { id: s.id, car: ids.car, track: ids.track, carName: s.car, trackName: s.track, config: s.config, corners: cards.map(c => c.corner.n) });
      R.prog = P;
    } catch (e) { console.error(e); band.hidden = true; R.$('.rv').classList.remove('has-prog'); }
  },

  // ---- screens 2 and 3: their own modules, by name ----
  async mountSub(screen, o) {
    const el = R.el;
    el.innerHTML = '<div class="rv-sub"></div>';
    const host = el.querySelector('.rv-sub'), gen = R.gen;
    let mod = null;
    try { const m = await import(SUB[screen]); mod = m.default && m.default.mount ? m.default : m.mount ? m : null; } catch (e) { mod = null; }
    if (gen !== R.gen || R.el !== el) return;
    if (!mod) { host.innerHTML = R.line('Coming with the next update.'); return; }
    try { mod.mount(host, R.ctx, o); R.sub = mod; }
    catch (e) { console.error(e); host.innerHTML = R.line('This screen could not open. Press REVIEW.'); }
  },

  // ---- WATCH: his own video of that corner, 10 s from the corner. clip.id is the recorder's one-lap clip (served by /vault/video),
  //      clip.at counts from the start of that clip; a clip that will not play says so in one line ----
  watch(b) {
    if (!b || b.disabled || !b.dataset.clip || !R.el) return;
    R.closeWatch();
    const at = +b.dataset.at || 0, src = '/vault/video?id=' + encodeURIComponent(b.dataset.clip) + '#t=' + at.toFixed(2);
    const w = document.createElement('div'); w.className = 'rv-watch';
    w.innerHTML = '<div class="w-cap">' + esc(b.dataset.what || '') + '</div><video muted playsinline preload="auto"></video>' +
      '<div class="w-acts"><button type="button" class="btn replay">Replay</button><button type="button" class="btn close">Close</button></div>';
    R.el.querySelector('.rv').appendChild(w);
    const v = w.querySelector('video');
    const play = () => { try { v.currentTime = at; } catch (e) { } const p = v.play(); if (p && p.catch) p.catch(() => { }); };
    // the clip ends by itself after CLIP_SECONDS (the video's own clock, no timer)
    v.addEventListener('timeupdate', () => { if (v.currentTime >= at + CLIP_SECONDS) v.pause(); });
    v.addEventListener('loadedmetadata', play, { once: true });
    v.addEventListener('error', () => { const n = document.createElement('p'); n.className = 'w-none'; n.textContent = 'No video of this corner'; v.replaceWith(n); w.querySelector('.replay').disabled = true; }, { once: true });
    w.querySelector('.replay').addEventListener('click', play);
    w.querySelector('.close').addEventListener('click', () => R.closeWatch());
    v.src = src;
    R.vid = { w, v, src };
  },
  closeWatch() {
    const x = R.vid; R.vid = null; if (!x) return;
    try { x.v.pause(); x.v.removeAttribute('src'); x.v.load(); } catch (e) { }
    x.w.remove();
  },
};

export default {
  name: 'review', title: 'REVIEW',
  mount(el, ctx) { R.mount(el, ctx); },
  unmount() { R.unmount(); },
  onState(state, changed) { R.onState(state, changed); },
};
R.memo = memo;
export const Review = R;                   // the test looks inside
