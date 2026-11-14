'use strict';
// RACES on the top screen (W1-4, docs/rework/cards/W1-4.md). Cards with the race's picture and one state line; tick cards and the
// bar at the bottom shares or deletes them (no "are you sure": DELETE moves them to the trash and UNDO brings them back for 8 s);
// OPEN shows one race with WATCH / SHARE TO YOUTUBE / TALK OVER IT / REVIEW / DELETE and its moments on a timeline.
// irdash does the work (library.cs: racetrash, raceundo, raceempty, racefree, raceshare, ytsignin, ytprivacy, yttemplate;
// vault.cs: racewatch). The list is /api/library, loaded again only when irdash says it changed (data.onList: no timer).
// Tests: ?fixture=<url> reads the list from a file, ?dry=1 records every command in window.racesDone instead of sending it,
// ?thumbs=<url prefix> takes the pictures from <prefix><id>.jpg.
const Q = new URLSearchParams(location.search), DRY = Q.get('dry') === '1', FIXTURE = Q.get('fixture') || '', THUMBS = Q.get('thumbs') || '';
window.racesDone = [];
const $ = id => document.getElementById(id);
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
const mmss = s => { s = Math.max(0, Math.round(s || 0)); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60; return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (x < 10 ? '0' : '') + x; };
const TOAST_MS = 8000;

// the one state line of a card, from state.kind (the server's words for failed / offline / sign-in)
function stateLine(r) {
  const s = r.state || { kind: 'none' };
  switch (s.kind) {
    case 'queued': return { text: 'Waiting to share', cls: 'wait' };
    case 'sharing': return { text: 'Sharing ' + (s.pct | 0) + '%', cls: 'wait' };
    case 'shared': return s.privacy === 'public' ? { text: 'On YouTube', cls: 'done' } : { text: 'On YouTube (private)', cls: 'done' };
    case 'failed': return { text: s.error || 'Could not share it', cls: 'bad' };
    case 'signin': return { text: 'Sign in to YouTube', cls: 'key', act: 'signin' };
    case 'offline': return { text: 'No internet, waiting', cls: 'wait' };
  }
  return { text: 'Not shared', cls: 'none' };
}
const isShared = r => r.state && r.state.kind === 'shared';
const busySharing = r => r.state && /^(queued|sharing|offline|signin)$/.test(r.state.kind);

// "Toyota GR86 · 21 min · 10 laps · best 1:33.832 · 1.1 GB" (best 0 = no lap iRacing counted)
function facts(r) {
  const f = [];
  if (r.car) f.push(esc(r.car));
  if (r.sec > 0) f.push(Fmt.dur(r.sec));
  if (r.laps) f.push(plural(r.laps, 'lap'));
  f.push(r.best > 0 ? 'best ' + Fmt.lap(r.best) : 'no clean lap');
  f.push(Fmt.size((r.mb || 0) * 1048576));
  // a fact never breaks inside itself ("1.1 GB" on one line); the line wraps only between facts
  return f.map(x => x.replace(/ /g, '&nbsp;')).join(' · ');
}
const thumbUrl = r => THUMBS ? THUMBS + encodeURIComponent(r.id) + '.jpg' : '/api/library/thumb?id=' + encodeURIComponent(r.id) + '&w=600';

const Races = {
  data: null, failed: false, tab: 'races', ticks: new Set(), lastTick: '', hidden: new Set(), openId: '', picker: false,
  seenOnline: false, wasDriving: null, wasOffline: null, toastTimer: 0, signinWanted: false,

  init() {
    document.querySelectorAll('.tab').forEach(b => b.addEventListener('click', () => this.setTab(b.dataset.tab)));
    $('grid').addEventListener('click', e => this.gridClick(e));
    $('selShared').addEventListener('click', () => this.selectShared());
    $('barShare').addEventListener('click', () => this.share([...this.ticks]));
    $('barDelete').addEventListener('click', () => this.del([...this.ticks]));
    $('barCancel').addEventListener('click', () => this.clearTicks());
    $('emptyNow').addEventListener('click', () => this.emptyNow());
    $('privBtn').addEventListener('click', () => this.togglePrivacy());
    $('titlesBtn').addEventListener('click', () => this.showPicker(true));
    $('banner').addEventListener('click', e => { if (e.target.closest('[data-act="signin"]')) this.signIn(); });
    $('freeRow').addEventListener('click', e => { if (e.target.closest('[data-act="free"]')) this.freeUp(); });
    $('open').addEventListener('click', e => this.openClick(e));
    $('titles').addEventListener('click', e => this.pickerClick(e));
    $('toast').addEventListener('click', e => { const b = e.target.closest('[data-act="undo"]'); if (b) this.undo(b.dataset.batch); });
    document.addEventListener('keydown', e => {
      if (e.key !== 'Escape') return;
      if (this.picker) this.showPicker(false);
      else if (this.openId) this.openRace('');
      else if (this.ticks.size) this.clearTicks();
      else if (window.parent !== window) window.parent.postMessage({ irdash: 'races-close' }, location.origin);
    });
    if (typeof data !== 'undefined') {
      // W0-5: no timer. The list loads again when irdash says it changed; the rig's state (driving, online) comes on the push.
      data.onList('races', () => this.load());
      data.on('state', () => this.rigChanged());
      if (data.on) data.on('online', () => this.rigChanged());
    }
    this.rigChanged();
    this.load();
  },

  rig() { return typeof data !== 'undefined' && data.rig ? data.rig : { driving: false, online: true }; },
  rigChanged() {
    const r = this.rig();
    if (r.online) this.seenOnline = true;
    const driving = !!r.driving, offline = this.failed || (this.seenOnline && !r.online);
    if (driving === this.wasDriving && offline === this.wasOffline) return;
    this.wasDriving = driving; this.wasOffline = offline;
    this.draw();
  },

  async load() {
    try {
      const r = await fetch(FIXTURE || '/api/library', { cache: 'no-store' });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      this.data = await r.json(); this.failed = false;
    } catch (e) { this.failed = true; }
    this.wasOffline = null; this.rigChanged();
    this.draw();
  },

  // newest first (the server sends them so; sorted again so a card put back by UNDO lands in its place)
  races() { return ((this.data && this.data.races) || []).filter(r => !this.hidden.has(r.id)).sort((a, b) => (b.startMs || 0) - (a.startMs || 0)); },
  shown() {
    const all = this.races();
    return this.tab === 'all' ? all : this.tab === 'pq' ? all.filter(r => !r.isRace) : all.filter(r => r.isRace);
  },
  find(id) { return this.races().find(r => r.id === id); },
  youtube() { return (this.data && this.data.youtube) || { signedIn: false, privacy: 'private', template: 1 }; },

  setTab(t) {
    this.tab = t;
    document.querySelectorAll('.tab').forEach(b => b.classList.toggle('on', b.dataset.tab === t));
    this.draw();
  },

  // ---------------- drawing ----------------
  draw() {
    const driving = !!this.wasDriving;
    $('driving').hidden = !driving;
    document.querySelector('header.top').hidden = driving;
    $('grid').hidden = driving;
    if (driving) { $('banner').hidden = true; $('bar').hidden = true; $('open').hidden = true; $('titles').hidden = true; return; }
    this.drawHeader();
    this.drawGrid();
    this.drawBar();
    this.drawBanner();
    this.drawOpen();
    this.drawPicker();
  },

  drawHeader() {
    const d = this.data || {}, st = d.storage;
    if (st) {
      $('storeLine').textContent = (st.usedGb | 0) + ' GB used · ' + (st.freeGb | 0) + ' GB free · about ' + plural(st.moreRaces | 0, 'more race');
      const tot = (st.usedGb || 0) + (st.freeGb || 0);
      $('storeFill').style.width = (tot > 0 ? Math.min(100, Math.round(100 * (st.usedGb || 0) / tot)) : 0) + '%';
      $('store').classList.toggle('low', !!st.lowSpace);
      $('trashBit').hidden = !((st.trashGb || 0) >= 1);
      $('trashGb').textContent = (st.trashGb | 0) + ' GB';
    } else { $('storeLine').innerHTML = '&nbsp;'; $('trashBit').hidden = true; $('storeFill').style.width = '0'; }
    const fr = $('freeRow');
    if (st && st.lowSpace) {
      const fu = st.freeUp || { count: 0, gb: 0 };
      fr.innerHTML = fu.count > 0
        ? '<button type="button" class="btn gold" data-act="free">Free up space: delete the ' + (fu.count === 1 ? 'oldest shared race' : fu.count + ' oldest shared races') + ' (' + Math.max(1, Math.round(fu.gb)) + ' GB)</button>'
        : '<span class="muted">The disk is nearly full. Nothing shared yet to free.</span>';
      fr.hidden = false;
    } else fr.hidden = true;
    $('selShared').hidden = !this.shown().some(isShared);
    const yt = this.youtube(), pub = yt.privacy === 'public';
    $('privWords').textContent = pub ? 'Uploads are public' : 'Uploads are private';
    $('privBtn').textContent = pub ? 'Make private' : 'Make public';
  },

  drawGrid() {
    const g = $('grid'), show = this.shown();
    g.classList.toggle('selecting', this.ticks.size > 0);
    if (!this.data) { g.innerHTML = this.failed ? '' : ''; return; }
    if (!show.length) {
      g.innerHTML = '<div class="empty">' + (this.races().length === 0 || this.tab === 'races'
        ? (this.tab === 'pq' ? 'No practice or qualifying recorded.' : 'No races yet. Every race longer than 5 minutes lands here by itself.')
        : this.tab === 'pq' ? 'No practice or qualifying recorded.' : 'Nothing recorded yet.') + '</div>';
      return;
    }
    g.innerHTML = show.map(r => {
      const id = esc(r.id), on = this.ticks.has(r.id), s = stateLine(r);
      const kind = r.isRace ? '' : ' · ' + esc(Fmt.sessionName(r.type));
      return '<article class="card' + (on ? ' on' : '') + (r.thumb ? '' : ' nothumb') + '" data-id="' + id + '">' +
        (r.thumb ? '<img class="pic" alt="" loading="lazy" src="' + esc(thumbUrl(r)) + '" onerror="this.parentNode.classList.add(\'nothumb\');this.remove()">' : '') +
        '<div class="shade"></div>' +
        '<button type="button" class="tick" data-act="tick" aria-pressed="' + on + '" aria-label="Tick this race"><i></i></button>' +
        '<div class="when">' + esc(Fmt.whenRel(r.startMs)) + kind + '</div>' +
        (r.kept ? '<span class="tag">Kept</span>' : '') +
        '<div class="info">' +
        '<div class="track">' + esc(r.track) + '</div>' +
        '<div class="facts">' + facts(r) + '</div></div>' +
        '<div class="foot">' + (s.act ? '<button type="button" class="state key" data-act="signin">' + esc(s.text) + '</button>' : '<div class="state ' + s.cls + '">' + esc(s.text) + '</div>') +
        '<button type="button" class="btn gold open" data-act="open">Open</button></div>' +
        '</article>';
    }).join('');
  },

  drawBar() {
    const n = this.ticks.size, bar = $('bar');
    bar.hidden = n === 0 || !!this.openId;
    document.body.classList.toggle('selecting', n > 0);
    if (!n) return;
    $('barCount').textContent = plural(n, 'race') + ' ticked';
    const shareable = [...this.ticks].filter(id => { const r = this.find(id); return r && !isShared(r) && !busySharing(r); }).length;
    $('barShare').textContent = 'Share to YouTube (' + shareable + ')';
    $('barShare').disabled = shareable === 0;
    $('barDelete').textContent = 'Delete (' + n + ')';
  },

  // one banner: offline, or the sign-in that sharing needs (only once a race is ticked or opened)
  drawBanner() {
    const b = $('banner'), yt = this.youtube();
    if (this.wasOffline) { b.className = 'banner bad'; b.innerHTML = 'The dashboard is not answering. What you see may be out of date.'; b.hidden = false; return; }
    const wantShare = this.ticks.size > 0 || !!this.openId || this.signinWanted;
    if (this.data && !yt.signedIn && wantShare) {
      b.className = 'banner signin';
      b.innerHTML = '<span>YouTube is not signed in yet. Sign in once and the races you share go up by themselves.</span>' +
        '<button type="button" class="btn gold" data-act="signin">' + (yt.signingIn ? 'Sign-in is open in the browser' : 'Sign in to YouTube') + '</button>';
      b.hidden = false;
      // the open card sits over the page: the banner goes on top of it
      b.classList.toggle('over', !!this.openId);
      return;
    }
    b.hidden = true;
  },

  drawOpen() {
    const o = $('open'), r = this.openId ? this.find(this.openId) : null;
    if (!r) { o.hidden = true; if (this.openId) this.openId = ''; return; }
    const s = stateLine(r), shared = isShared(r), canShare = !shared && !busySharing(r);
    const total = r.sec > 0 ? r.sec : Math.max(1, ...(r.markers || []).map(m => m.sec));
    const marks = (r.markers || []).slice().sort((a, b) => a.sec - b.sec);
    const dots = marks.map(m => '<i class="dot k-' + esc(m.kind) + '" style="left:' + Math.max(0, Math.min(100, 100 * m.sec / total)).toFixed(2) + '%"></i>').join('');
    const chips = marks.map(m => '<li class="chip k-' + esc(m.kind) + '"><b>' + mmss(m.sec) + '</b> ' + esc(m.label) + '</li>').join('');
    const url = shared && r.state.url ? r.state.url : '';
    const kind = r.isRace ? '' : ' · ' + esc(Fmt.sessionName(r.type));
    o.innerHTML =
      '<div class="o-top"><button type="button" class="btn" data-act="close">Back to all races</button></div>' +
      '<div class="o-main">' +
        '<div class="o-pic' + (r.thumb ? '' : ' nothumb') + '">' + (r.thumb ? '<img alt="" src="' + esc(thumbUrl(r)) + '" onerror="this.parentNode.classList.add(\'nothumb\');this.remove()">' : '') + '<div class="ghost">' + esc(r.track) + '</div></div>' +
        '<div class="o-facts">' +
          '<div class="when">' + esc(Fmt.whenRel(r.startMs)) + kind + (r.kept ? '<span class="tag">Kept</span>' : '') + '</div>' +
          '<div class="o-track">' + esc(r.track) + '</div>' +
          (r.config ? '<div class="o-config">' + esc(r.config) + '</div>' : '') +
          '<div class="o-car">' + esc(r.car) + '</div>' +
          '<div class="o-line">' + Fmt.dur(r.sec) + ' · ' + plural(r.laps || 0, 'lap') + (r.counted ? ' · ' + r.counted + ' counted' : '') + '</div>' +
          '<div class="o-line">' + (r.best > 0 ? 'Best lap <b>' + Fmt.lap(r.best) + '</b>' + (r.bestLap ? ' (lap ' + r.bestLap + ')' : '') : 'No clean lap') + ' · ' + Fmt.size((r.mb || 0) * 1048576) + '</div>' +
          (s.act ? '<button type="button" class="state key" data-act="signin">' + esc(s.text) + '</button>' : '<div class="state ' + s.cls + '">' + esc(s.text) + '</div>') +
          (url ? '<div class="o-link"><input id="linkField" readonly value="' + esc(url) + '" aria-label="YouTube link"><button type="button" class="btn" data-act="copy">Copy link</button></div>' : '') +
        '</div>' +
      '</div>' +
      '<div class="o-keys">' +
        '<button type="button" class="btn" data-act="watch">Watch</button>' +
        '<button type="button" class="btn gold" data-act="share"' + (canShare ? '' : ' disabled') + '>Share to YouTube</button>' +
        '<div class="soon"><button type="button" class="btn" disabled>Talk over it</button><span>Comes with the commentary update</span></div>' +
        '<button type="button" class="btn" data-act="review">Review</button>' +
        '<button type="button" class="btn danger" data-act="delete">Delete</button>' +
      '</div>' +
      (marks.length ? '<div class="o-time"><div class="rail">' + dots + '</div><ul class="chips">' + chips + '</ul></div>' : '');
    o.hidden = false;
  },

  drawPicker() {
    const p = $('titles');
    if (!this.picker) { p.hidden = true; return; }
    const t = (this.data && this.data.titles) || [], cur = this.youtube().template || 1, curT = t[cur - 1] || '';
    // each look once: with no finishing place known, two templates read the same (2 falls back to 1)
    const rows = []; t.forEach((x, i) => { if (x && !rows.some(r => r.t === x)) rows.push({ n: i + 1, t: x }); });
    p.innerHTML = '<div class="o-top"><button type="button" class="btn" data-act="close">Back</button></div>' +
      '<h2>How your races are named on YouTube</h2><p class="muted">Press one. Every race you share gets a name like it.</p>' +
      '<ol class="pick">' + rows.map(x => '<li><button type="button" class="pick-row' + (x.t === curT ? ' on' : '') + '" data-n="' + x.n + '">' +
        '<span>' + esc(x.t) + '</span>' + (x.t === curT ? '<em>In use</em>' : '') + '</button></li>').join('') + '</ol>';
    p.hidden = false;
  },

  // ---------------- ticking ----------------
  gridClick(e) {
    const card = e.target.closest('.card'); if (!card) return;
    const id = card.dataset.id, b = e.target.closest('[data-act]'), act = b ? b.dataset.act : '';
    if (act === 'signin') return this.signIn();
    if (act === 'open') return this.openRace(id);
    if (act === 'tick' || this.ticks.size > 0) return this.tick(id, e.shiftKey);
    this.openRace(id);
  },
  tick(id, range) {
    const show = this.shown().map(r => r.id);
    if (range && this.lastTick && show.indexOf(this.lastTick) >= 0 && show.indexOf(id) >= 0) {
      const a = show.indexOf(this.lastTick), b = show.indexOf(id);
      for (let i = Math.min(a, b); i <= Math.max(a, b); i++) this.ticks.add(show[i]);
    } else if (this.ticks.has(id)) this.ticks.delete(id);
    else this.ticks.add(id);
    this.lastTick = id;
    this.draw();
  },
  selectShared() { this.ticks = new Set(this.shown().filter(isShared).map(r => r.id)); this.lastTick = ''; this.draw(); },
  clearTicks() { this.ticks.clear(); this.lastTick = ''; this.signinWanted = false; this.draw(); },

  openRace(id) { this.openId = id || ''; if (!id) this.signinWanted = false; this.draw(); },
  openClick(e) {
    const b = e.target.closest('[data-act]'); if (!b || b.disabled) return;
    const r = this.find(this.openId); if (!r) return;
    switch (b.dataset.act) {
      case 'close': return this.openRace('');
      case 'watch': return this.watch(r.id);
      case 'share': return this.share([r.id]);
      case 'review': return this.review(r);
      case 'delete': return this.del([r.id]);
      case 'signin': return this.signIn();
      case 'copy': return this.copy();
    }
  },
  showPicker(on) { this.picker = on; this.draw(); },
  pickerClick(e) {
    if (e.target.closest('[data-act="close"]')) return this.showPicker(false);
    const b = e.target.closest('.pick-row'); if (b) this.setTemplate(+b.dataset.n);
  },

  // ---------------- commands ----------------
  // every command goes through /api/do (data.fetch adds the X-Paddock header); the library answers JSON with "say", the session
  // guard answers 409 in plain text
  async cmd(c, a) {
    const url = '/api/do?c=' + c + (a != null && a !== '' ? '&a=' + encodeURIComponent(a) : '');
    if (DRY) {
      window.racesDone.push(url);
      const n = String(a || '').split('|').filter(Boolean).length;
      if (c === 'racetrash') return { ok: true, json: { batch: 'dry-' + window.racesDone.length, count: n, say: 'Deleted ' + plural(n, 'race') } };
      if (c === 'raceundo') return { ok: true, json: { ok: true, say: 'Back again' } };
      return { ok: true, json: { ok: true, say: '' } };
    }
    try {
      const f = typeof data !== 'undefined' && data.fetch ? data.fetch : fetch;
      const r = await f(url, { cache: 'no-store' }), t = await r.text();
      let j = null; try { j = JSON.parse(t); } catch (e) { j = { say: t.length < 200 ? t : '' }; }
      return { ok: r.ok, status: r.status, json: j || {} };
    } catch (e) { return { ok: false, status: 0, json: { say: 'The dashboard is not answering. Try again in a moment.' } }; }
  },

  async del(ids) {
    ids = ids.filter(id => this.find(id)); if (!ids.length) return;
    // the cards leave at once; the server's answer brings them back if it could not
    ids.forEach(id => this.hidden.add(id));
    this.ticks.clear(); this.openId = ''; this.draw();
    const r = await this.cmd('racetrash', ids.join('|'));
    if (r.ok && r.json.batch) {
      this.toast(esc(r.json.say || ('Deleted ' + plural(ids.length, 'race'))) + ' · <button type="button" class="undo" data-act="undo" data-batch="' + esc(r.json.batch) + '">Undo</button>', false, ids);
    } else {
      ids.forEach(id => this.hidden.delete(id)); this.draw();
      this.toast(esc(r.json.say || 'Could not delete that.'), true);
    }
  },
  async undo(batch) {
    const ids = this.toastIds || [];
    this.hideToast();
    const r = await this.cmd('raceundo', batch);
    if (r.ok) { ids.forEach(id => this.hidden.delete(id)); this.draw(); this.toast(esc(r.json.say || 'Back again')); if (!DRY) this.load(); }
    else this.toast(esc(r.json.say || 'Could not undo.'), true);
  },

  async share(ids) {
    ids = ids.filter(id => { const r = this.find(id); return r && !isShared(r) && !busySharing(r); });
    if (!ids.length) return this.toast('Already on YouTube');
    const r = await this.cmd('raceshare', ids.join('|'));
    if (r.ok) {
      // the card says "Waiting to share" at once; the next list from irdash carries the real state
      ids.forEach(id => { const x = this.find(id); if (x && (!x.state || x.state.kind === 'none' || x.state.kind === 'failed')) x.state = { kind: 'queued', pct: 0 }; });
      this.ticks.clear();
      if (r.json.signin) this.signinWanted = true;
      this.draw();
    }
    this.toast(esc(r.json.say || (r.ok ? 'Sharing ' + plural(ids.length, 'race') : 'Could not share that.')), !r.ok);
  },

  async watch(id) {
    const r = await this.cmd('racewatch', id);
    this.toast(r.ok ? 'Playing on the middle screen.' : r.status === 409 && r.json.say ? esc(r.json.say) : 'Could not play that one.', !r.ok);
  },

  // REVIEW: the Sessions page (the REVIEW door comes in wave 4; it cannot open one drive by its video yet)
  review() { location.href = 'sessions.html?embed=1'; },

  copy() {
    const f = $('linkField'); if (!f) return;
    const done = () => this.toast('Link copied');
    const pick = () => { f.focus(); f.select(); try { if (document.execCommand('copy')) return done(); } catch (e) { } this.toast('The link is selected: press Ctrl+C to copy it'); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(f.value).then(done, pick); else pick();
  },

  async signIn() {
    const r = await this.cmd('ytsignin');
    if (this.data && this.data.youtube && r.ok) this.data.youtube.signingIn = true;
    this.draw();
    this.toast(esc(r.json.say || (r.ok ? 'Google sign-in opened in the browser' : 'Could not open the sign-in.')), !r.ok);
  },
  async togglePrivacy() {
    const yt = this.youtube(), want = yt.privacy === 'public' ? 'private' : 'public';
    const r = await this.cmd('ytprivacy', want);
    if (r.ok && this.data) { this.data.youtube = Object.assign({}, yt, { privacy: want }); this.draw(); }
    this.toast(esc(r.json.say || (want === 'public' ? 'New uploads are public' : 'New uploads are private')), !r.ok);
  },
  async setTemplate(n) {
    const r = await this.cmd('yttemplate', String(n));
    if (r.ok && this.data) this.data.youtube = Object.assign({}, this.youtube(), { template: n });
    this.picker = false; this.draw();
    this.toast(esc(r.json.say || 'Titles will look like this from now on'), !r.ok);
  },
  async emptyNow() {
    const r = await this.cmd('raceempty');
    this.toast(esc(r.json.say || (r.ok ? 'Emptying the trash' : 'Could not empty the trash.')), !r.ok);
  },
  async freeUp() {
    const r = await this.cmd('racefree');
    this.toast(esc(r.json.say || (r.ok ? 'Space freed' : 'Nothing freed.')), !r.ok);
  },

  // ---------------- the toast (8 s) ----------------
  toast(html, bad, ids) {
    const t = $('toast');
    t.innerHTML = html; t.className = 'toast' + (bad ? ' bad' : ''); t.hidden = false;
    this.toastIds = ids || null;
    clearTimeout(this.toastTimer); this.toastTimer = setTimeout(() => this.hideToast(), TOAST_MS);
  },
  hideToast() { $('toast').hidden = true; this.toastIds = null; clearTimeout(this.toastTimer); },
};
Races.init();
