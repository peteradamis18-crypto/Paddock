'use strict';
// MY RACES on the top screen. One row per whole-race video: WATCH (Windows' player), SHARE ON YOUTUBE (the race goes
// into Videos\Paddock, Explorer shows it, YouTube's upload page opens), DELETE FROM PC (two clicks within 5 s).
// irdash does the work (vault.cs: racewatch / raceexport / recsave, /api/rec/delete); this page only asks.
// Tests: ?fixture=<url> reads the list from a file and ?dry=1 records the actions in window.racesDone instead of sending.
const Q = new URLSearchParams(location.search), DRY = Q.get('dry') === '1', FIXTURE = Q.get('fixture') || '';
window.racesDone = [];
const $ = id => document.getElementById(id);
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const DAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const isRace = x => /race/i.test(x.type || '') && !/qual|prac/i.test(x.type || '');
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function when(ms) {
  const d = new Date(ms), now = new Date(), y = new Date(now); y.setDate(now.getDate() - 1);
  const same = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  const hm = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  return (same(d, now) ? 'Today' : same(d, y) ? 'Yesterday' : DAY[d.getDay()] + ' ' + d.getDate() + ' ' + MON[d.getMonth()]) + ' · ' + hm;
}
function lap(t) { if (!(t > 0)) return ''; const m = Math.floor(t / 60), s = t - m * 60; return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3); }
function size(mb) { return mb >= 1000 ? (mb / 1024).toFixed(1) + ' GB' : Math.max(1, Math.round(mb)) + ' MB'; }
function kind(t) { return isRace({ type: t }) ? '' : /qual/i.test(t || '') ? 'Qualifying' : /prac|warm/i.test(t || '') ? 'Practice' : (t || 'Session'); }

const Races = {
  data: null, all: false, armed: '', armTimer: 0, busy: '',

  init() {
    $('tabRaces').addEventListener('click', () => this.setAll(false));
    $('tabAll').addEventListener('click', () => this.setAll(true));
    $('list').addEventListener('click', e => { const b = e.target.closest('button[data-act]'); if (b) this.act(b.dataset.act, b.dataset.id, b); });
    document.addEventListener('keydown', e => {
      if (e.key === 'Escape' && window.parent !== window) window.parent.postMessage({ irdash: 'races-close' }, location.origin);
    });
    this.load(); setInterval(() => { if (!this.busy && !this.armed) this.load(); }, 10000);
  },

  setAll(on) { this.all = on; $('tabRaces').classList.toggle('on', !on); $('tabAll').classList.toggle('on', on); this.draw(); },

  async load() {
    try {
      const r = await fetch(FIXTURE || '/api/rec/races', { cache: 'no-store' });
      this.data = await r.json();
    } catch (e) { this.data = null; }
    this.draw();
  },

  draw() {
    const d = this.data, list = $('list');
    if (!d) { $('sub').textContent = 'The dashboard is not answering. Try again in a moment.'; list.innerHTML = ''; return; }
    const all = d.races || [], races = all.filter(isRace), show = this.all ? all : races;
    $('sub').innerHTML = '<b>' + races.length + '</b> ' + (races.length === 1 ? 'race' : 'races') + ' on this PC · <b>' + (d.freeGb | 0) + ' GB</b> free · also in Videos\\Paddock';
    if (!show.length) {
      list.innerHTML = '<div class="empty">' + (this.all ? 'Nothing recorded yet.' : 'No races yet. Every race longer than 5 minutes lands here by itself.') + '</div>';
      return;
    }
    list.innerHTML = show.map(r => {
      const k = kind(r.type), facts = [esc(r.car)];
      if (r.min) facts.push(r.min + ' min');
      if (r.laps) facts.push(r.laps + (r.laps === 1 ? ' lap' : ' laps'));
      if (r.best > 0) facts.push('best <b>' + lap(r.best) + '</b>');
      facts.push(size(r.mb || 0));
      const armed = this.armed === r.id, id = esc(r.id);
      return '<div class="race" data-id="' + id + '">' +
        '<div class="info"><div class="when">' + esc(when(r.startMs)) + (k ? ' · ' + esc(k) : '') + '</div>' +
        '<div class="track">' + esc(r.track) + (r.saved ? '<span class="tag">Kept</span>' : '') + '</div>' +
        '<div class="facts">' + facts.join(' · ') + '</div></div>' +
        '<div class="acts">' +
        (r.saved ? '' : '<button type="button" class="act keep" data-act="keep" data-id="' + id + '">Keep</button>') +
        '<button type="button" class="act watch" data-act="watch" data-id="' + id + '">Watch</button>' +
        '<button type="button" class="act share" data-act="share" data-id="' + id + '">Share on YouTube</button>' +
        '<button type="button" class="act del' + (armed ? ' armed' : '') + '" data-act="del" data-id="' + id + '">' + (armed ? 'Click again to delete' : 'Delete from PC') + '</button>' +
        '</div></div>';
    }).join('');
  },

  say(text, bad) {
    const m = $('msg'); m.textContent = text; m.className = bad ? 'bad' : ''; m.hidden = false;
    clearTimeout(this.sayTimer); this.sayTimer = setTimeout(() => { m.hidden = true; }, bad ? 9000 : 15000);
  },

  async send(url) {
    if (DRY) { window.racesDone.push(url); return url.indexOf('/api/rec/delete') === 0 ? { state: 'DELETED' } : 'ok'; }
    const r = await fetch(url, { cache: 'no-store' });
    return url.indexOf('/api/rec/delete') === 0 ? r.json() : (r.ok ? 'ok' : 'no');
  },

  async act(what, id, btn) {
    if (!id || this.busy) return;
    const race = ((this.data && this.data.races) || []).find(r => r.id === id); if (!race) return;
    if (what === 'del' && this.armed !== id) {
      this.armed = id; clearTimeout(this.armTimer);
      this.armTimer = setTimeout(() => { this.armed = ''; this.draw(); }, 5000);
      this.draw(); return;
    }
    this.armed = ''; clearTimeout(this.armTimer);
    this.busy = id; if (btn) btn.disabled = true;
    const a = encodeURIComponent(id);
    try {
      if (what === 'del') {
        const r = await this.send('/api/rec/delete?id=' + a + '&confirm=yes'), st = r && r.state;
        if (st === 'DELETED') { this.data.races = this.data.races.filter(x => x.id !== id); this.data.freeGb = (this.data.freeGb | 0) + Math.round((race.mb || 0) / 1024); this.say('Deleted. ' + size(race.mb || 0) + ' is free again.'); }
        else this.say(st === 'RECORDING' || st === 'IN USE' || st === 'BUSY' ? 'That one is still being written. Try again in a minute.' : 'Could not delete that one.', true);
      } else if (what === 'share') {
        const ok = await this.send('/api/do?c=raceexport&a=' + a);
        if (ok === 'ok') { race.exported = true; this.say('YouTube is open, with the folder holding this race next to it. Drag the race file onto the YouTube page.'); }
        else this.say('Could not open it for YouTube. Get out of the car first, then try again.', true);
      } else if (what === 'watch') {
        const ok = await this.send('/api/do?c=racewatch&a=' + a);
        if (ok === 'ok') this.say('Playing on the middle screen.'); else this.say('Could not play that one.', true);
      } else if (what === 'keep') {
        const ok = await this.send('/api/do?c=recsave&a=' + a);
        if (ok === 'ok') { race.saved = true; this.say('Kept for good.'); } else this.say('Could not keep that one.', true);
      }
    } catch (e) { this.say('The dashboard is not answering. Try again in a moment.', true); }
    this.busy = '';
    this.draw();
  },
};
Races.init();
