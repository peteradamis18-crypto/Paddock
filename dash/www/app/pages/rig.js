/* RIG (W5-1, docs/rework/PLAN.md 4.5): a car's single warning line, not a console. One screen in the shell:
     1. the ready line: "Rig ready" (gold) or ONE sentence for the first fault (Stream Deck, then Spotter, then Overlays) with FIX
        (the Doctor's own fix, /api/doctor/run?quiet=1); "Checking the rig…" while the Doctor runs (its part says running)
     2. four rows: iRacing (closed is never a fault), Stream Deck, Spotter, Overlays (the "health" part = /health's apps)
        and, small under them, last night's self-check (the "nightly" part, W5-4; nothing when it is absent)
     3. LAST RACE in three numbers from /perf: average fps, the worst second with its lap and place, the verdict sentence ONCE
     4. QUIET PC (the "quiet" part, W5-2), 5. the AC (the "ac" part, the deck's same /api/do?c=ac* presses),
     6. two switches: START-UP SOUND and MIC (the "settings" part, dash/src/rigpage.cs), 7. MORE: the old Performance page in the frame
   A page module for the shell (W3-1): mount(el, ctx), unmount(). Every part comes through ctx.data.on('state'); /perf is asked once at
   mount, again when irdash says its list changed (onList('perf')) and when Paddock is back. Nothing on a timer, nothing polled.
   Offline (data.online false): what is on screen greys and nothing is pressed or asked. */
import { hostFrame } from '../lib/host.js';

const DOT = ' · ';
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const num = x => typeof x === 'number' && isFinite(x);
// the deck's AC screen order (deck-intro/plugin.html ACMODES / ACFANS): one press = the next one
const MODES = [[2, 'cool', 'Cool'], [1, 'auto', 'Auto'], [3, 'dry', 'Dry'], [5, 'fan', 'Fan only'], [4, 'heat', 'Heat']];
const FANS = [[40, 'low', 'Low'], [60, 'medium', 'Medium'], [80, 'high', 'High'], [102, 'auto', 'Auto']];

// ---------------------------------------------------------------- pure helpers (the test imports them)
const app = (h, id) => ((h && h.apps) || []).find(a => a.id === id) || null;

// the four rows: { id, name, dot: ok|bad|off|amber, word }
export function rows(h) {
  const out = [];
  const ui = app(h, 'ui'), sim = app(h, 'sim');
  const ss = sim ? sim.state : '';
  out.push(ss === 'live' ? { id: 'iracing', name: 'iRacing', dot: 'ok', word: 'in a session' }
    : ss === 'starting' || ss === 'loading' ? { id: 'iracing', name: 'iRacing', dot: 'ok', word: 'starting' }
    : ss === 'stuck' ? { id: 'iracing', name: 'iRacing', dot: 'amber', word: 'stuck loading' }
    : ui && ui.state === 'ok' ? { id: 'iracing', name: 'iRacing', dot: 'ok', word: 'open' }
    : { id: 'iracing', name: 'iRacing', dot: 'off', word: h ? 'closed' : '—' });
  const one = (id, key, name, on, off) => {
    const a = app(h, key);
    if (!h) return { id, name, dot: 'off', word: '—' };
    if (!a) return { id, name, dot: 'off', word: 'not installed' };
    return a.state === 'ok' ? { id, name, dot: 'ok', word: on } : { id, name, dot: 'bad', word: off };
  };
  out.push(one('deck', 'deck', 'Stream Deck', 'running', 'not running'));
  out.push(one('spotter', 'cc', 'Spotter', 'running', 'off'));
  out.push(one('overlays', 'overlays', 'Overlays', 'running', 'off'));
  return out;
}

// the ready line: { kind: ready|fault|checking|wait, text }; the first fault wins (Stream Deck, Spotter, Overlays)
export function ready(h, doctor) {
  if (doctor && doctor.running) return { kind: 'checking', text: 'Checking the rig…' };
  if (!h || !h.apps) return { kind: 'wait', text: 'Looking at the rig…' };
  const words = { deck: 'Stream Deck is not running', spotter: 'The spotter is not running', overlays: 'The overlays are not running' };
  const bad = rows(h).find(r => r.dot === 'bad' && words[r.id]);
  return bad ? { kind: 'fault', text: words[bad.id], id: bad.id } : { kind: 'ready', text: 'Rig ready' };
}

// where on the lap a fraction is, in the black box's words (blackbox.cs Place, without the corner list)
export function place(pct) {
  if (!num(pct) || pct < 0) return '';
  if (pct >= 0.97 || pct <= 0.03) return 'start/finish';
  return Math.round(pct * 100) + ' % round the lap';
}
function span(p) {
  if (!p || !num(p.from) || !num(p.to)) return '';
  if (p.from >= 0.97 || p.to <= 0.03) return 'start/finish';
  return Math.round(p.from * 100) + '–' + Math.round(p.to * 100) + ' % round the lap';
}
// the worst second: { fps: '23.7 fps', where: 'lap 9, start/finish' } (the freeze's lap and place, else the slowest place)
export function worst(l) {
  if (!l || !num(l.worst)) return null;
  const fps = l.worst.toFixed(1) + ' fps';
  const f = l.freeze;
  if (f && num(f.lap)) { const p = place(f.pct); return { fps, where: 'lap ' + Math.round(f.lap) + (p ? ', ' + p : '') }; }
  const slow = (l.places || []).filter(p => num(p.min)).sort((a, b) => a.min - b.min)[0];
  return { fps, where: slow ? span(slow) : '' };
}
// LAST RACE: { kind: wait|none|processing|race, ... }
export function lastRace(perf) {
  if (!perf) return { kind: 'wait' };
  if (perf.summary && /still being processed/i.test(perf.summary)) return { kind: 'processing', text: perf.summary };
  const l = perf.last;
  if (!l || !num(l.avg)) return { kind: 'none', text: perf.summary || 'Your first race shows here.' };
  const d = num(l.ts) ? new Date(l.ts).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }) : '';
  return { kind: 'race', where: [l.track, d].filter(Boolean).join(DOT), avg: Math.round(l.avg), worst: worst(l), text: l.text || '' };
}

// QUIET PC: null when not set up (absent or setup:false); else { on, say, items: [{ id, name, dot, word }] }
export function quiet(q) {
  if (!q || !q.setup) return null;
  const words = { paused: 'paused', running: 'running', off: 'off', on: 'on', unknown: 'not known' };
  return {
    on: !!q.on, say: q.say || '',
    items: (q.items || []).map(i => {
      const quietNow = i.state === 'paused' || (i.id === 'simprio' && i.state === 'on');
      return { id: i.id, name: i.name || i.id, word: words[i.state] || 'not known', dot: quietNow ? 'ok' : q.on && i.state === 'running' ? 'amber' : 'off' };
    }),
  };
}

// the mic as it reads on the switch
export function micText(s) {
  if (!s) return '—';
  const mics = s.mics || [];
  if (!s.mic) { const d = mics.find(m => m.default); return "Windows' default" + (d ? DOT + d.name : ''); }
  return mics.some(m => String(m.name).toLowerCase() === String(s.mic).toLowerCase()) ? s.mic : s.mic + DOT + 'not plugged in';
}
export const nextMode = m => { const i = MODES.findIndex(x => x[0] === m); return MODES[(i + 1) % MODES.length][1]; };
export const nextFan = f => { const i = FANS.findIndex(x => x[0] === f); return FANS[(i + 1) % FANS.length][1]; };
const modeWord = m => (MODES.find(x => x[0] === m) || [0, '', '—'])[2];
const fanWord = f => (FANS.find(x => x[0] === f) || [0, '', '—'])[2];

// ---------------------------------------------------------------- the page
const R = {
  el: null, ctx: null, offs: [], frame: null, st: {}, perf: null, perfFailed: false, gen: 0, stale: false,
  answer: { ac: '', sw: '' }, inFlight: {},

  $(c) { return R.el ? R.el.querySelector(c) : null; },

  mount(el, ctx) {
    R.el = el; R.ctx = ctx; R.offs = []; R.st = {}; R.perf = null; R.perfFailed = false; R.answer = { ac: '', sw: '' }; R.inFlight = {};
    if ((ctx.opts || {}).screen === 'more') { R.frame = hostFrame(el, '../v2/perf.html?embed=1', 'Performance'); return; }
    if (!document.querySelector('link[data-page="rig"]')) {
      const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = new URL('./rig.css', import.meta.url).href; l.dataset.page = 'rig';
      document.head.appendChild(l);
    }
    el.innerHTML = '<div class="rig">' +
      '<section class="rg-ready"><p class="say"></p><button type="button" class="btn gold fix" hidden>Fix</button></section>' +
      '<section class="rg-rows"></section><p class="rg-night" hidden></p>' +
      '<div class="rg-main"><div class="rg-left"><section class="rg-last"></section>' +
      '<div class="rg-foot"><button type="button" class="btn more">More</button></div></div>' +
      '<div class="rg-right"><section class="rg-quiet"></section><section class="rg-ac"></section><section class="rg-sw"></section></div></div></div>';
    R.$('.fix').addEventListener('click', () => R.fix());
    R.$('.more').addEventListener('click', () => { if (!R.stale) R.ctx.go('rig', { screen: 'more' }); });
    // one listener for every press inside the AC and the switches: each button names its command
    R.$('.rg-right').addEventListener('click', e => { const b = e.target.closest('button[data-c]'); if (b) R.press(b); });
    const d = ctx.data;
    R.stale = d.online === false;
    R.offs.push(d.on('state', (st, ch) => R.take(st, ch)));
    R.offs.push(d.on('online', on => { R.stale = !on; if (on && (!R.perf || R.perfFailed)) R.loadPerf(); R.drawAll(); }));
    R.offs.push(d.onList('perf', () => R.loadPerf()));
    if (!R.stale) R.loadPerf();
    R.drawAll();
  },

  unmount() {
    R.gen++;
    R.offs.forEach(f => { try { if (typeof f === 'function') f(); } catch (e) { } }); R.offs = [];
    R.el = null; R.ctx = null; R.frame = null;
  },

  take(st, ch) {
    if (!R.el || !st) return;
    let any = false;
    for (const k of ['health', 'doctor', 'rig', 'quiet', 'nightly', 'ac', 'settings']) if (!ch || ch[k]) { R.st[k] = st[k]; any = true; }
    if (ch && ch.ac && st.ac && st.ac.busy) R.answer.ac = '';      // the AC has the press: from now on its own state says what it does
    if (any) R.drawAll();
  },

  async loadPerf() {
    const gen = ++R.gen;
    let j = null;
    try { j = await R.ctx.data.json('/perf', 0); } catch (e) { j = null; }
    if (gen !== R.gen || !R.el) return;
    if (j) { R.perf = j; R.perfFailed = false; } else R.perfFailed = true;
    R.drawLast();
  },

  drawAll() {
    if (!R.$('.rig')) return;
    R.$('.rig').classList.toggle('stale', R.stale);
    R.drawReady(); R.drawRows(); R.drawLast(); R.drawQuiet(); R.drawAc(); R.drawSw();
    R.el.querySelectorAll('.rig button').forEach(b => { if (R.stale) b.disabled = true; });
    R.$('.more').disabled = R.stale;
  },

  drawReady() {
    const r = ready(R.st.health, R.st.doctor), box = R.$('.rg-ready'), b = R.$('.fix'), rig = R.st.rig || {};
    box.className = 'rg-ready ' + r.kind; box.dataset.fault = r.id || '';
    R.$('.rg-ready .say').textContent = r.text;
    b.hidden = r.kind !== 'fault';
    const why = rig.driving || rig.sessionOn ? 'Not while driving' : '';      // the Doctor refuses for the whole session (doctor.cs Run)
    b.textContent = why || 'Fix';
    b.disabled = !!why || R.stale || !!R.inFlight.fix;
  },

  drawRows() {
    R.$('.rg-rows').innerHTML = rows(R.st.health).map(r =>
      '<div class="rg-row" data-id="' + r.id + '"><span class="nm">' + esc(r.name) + '</span><span class="st"><i class="dot ' + r.dot + '"></i><span class="wd ' + r.dot + '">' + esc(r.word) + '</span></span></div>').join('');
    const n = R.st.nightly, p = R.$('.rg-night');
    p.hidden = !(n && n.text); p.textContent = n && n.text ? n.text : ''; p.classList.toggle('bad', !!(n && n.ok === false));
  },

  drawLast() {
    const box = R.$('.rg-last'); if (!box) return;
    const v = lastRace(R.perf);
    let h = '<p class="lbl">Last race' + (v.where ? '<span class="where">' + esc(v.where) + '</span>' : '') + '</p>';
    if (v.kind === 'wait') h += '<p class="line">' + (R.stale ? 'The last race shows here when Paddock is running.' : R.perfFailed ? 'The last race could not be read.' : 'Reading the last race…') + '</p>';
    else if (v.kind !== 'race') h += '<p class="line">' + esc(v.text) + '</p>';
    else {
      h += '<div class="nums"><div class="n avg"><b>' + v.avg + '</b><span>Average fps</span></div>' +
        (v.worst ? '<div class="n worst"><b>' + esc(v.worst.fps) + '</b><span>Worst second' + (v.worst.where ? DOT + esc(v.worst.where) : '') + '</span></div>' : '') + '</div>' +
        (v.text ? '<p class="verdict">' + esc(v.text) + '</p>' : '');
    }
    box.innerHTML = h;
  },

  drawQuiet() {
    const v = quiet(R.st.quiet), box = R.$('.rg-quiet');
    if (!v) { box.innerHTML = '<p class="line off">Quiet PC' + DOT + 'not set up</p>'; return; }      // no button: the setup is a one-click file (rule 5)
    box.innerHTML = '<p class="lbl">Quiet PC<span class="where ' + (v.on ? 'on' : '') + '">' + (v.on ? 'on' : 'off') + '</span></p>' +
      (v.say ? '<p class="line">' + esc(v.say) + '</p>' : '') +
      '<div class="items">' + v.items.map(i => '<span class="it" data-id="' + esc(i.id) + '"><i class="dot ' + i.dot + '"></i>' + esc(i.name) + ' <em>' + esc(i.word) + '</em></span>').join('') + '</div>';
  },

  drawAc() {
    const a = R.st.ac, box = R.$('.rg-ac');
    if (!a || !a.connected) { box.innerHTML = '<p class="line off">AC not connected</p>'; return; }
    if (!a.read) { box.innerHTML = '<p class="lbl">AC</p><p class="line">Reading the AC…</p>'; return; }
    const b = (c, arg, label, cls) => '<button type="button" class="btn' + (cls ? ' ' + cls : '') + '" data-c="' + c + '"' + (arg ? ' data-a="' + arg + '"' : '') + '>' + esc(label) + '</button>';
    const status = a.busy ? 'Sending to the AC…' : R.answer.ac || (a.on ? modeWord(a.mode) + DOT + 'fan ' + fanWord(a.fan).toLowerCase() : 'The AC is off');
    box.innerHTML = '<p class="lbl">AC<span class="where">' + esc(status) + '</span></p>' +
      '<div class="ac-row">' + b('acpower', '', a.on ? 'AC on' : 'AC off', a.on ? 'filled' : '') + b('actemp', '-1', '−', 'pm') +
      '<div class="temp"><b>' + (num(a.target_f) ? a.target_f + '°F' : '—') + '</b><span>room ' + (num(a.room_f) ? a.room_f + '°F' : '—') + '</span></div>' +
      b('actemp', '+1', '+', 'pm') + b('acauto', '', a.auto ? 'Auto-cool on' : 'Auto-cool off', a.auto ? 'filled' : '') + '</div>' +
      '<div class="ac-row">' + b('acmode', nextMode(a.mode), 'Mode' + DOT + modeWord(a.mode)) + b('acfan', nextFan(a.fan), 'Fan' + DOT + fanWord(a.fan)) +
      b('acpreset', 'max', 'Max cool') + b('acpreset', 'comfort', 'Comfort') + b('acpreset', 'quiet', 'Quiet') + '</div>';
  },

  drawSw() {
    const s = R.st.settings, box = R.$('.rg-sw'), snd = s ? s.startupSound !== false : null;
    const sw = (c, a, label, on) => '<button type="button" class="btn sw' + (on ? ' filled' : '') + '" data-c="' + c + '" data-a="' + a + '" aria-pressed="' + (on ? 'true' : 'false') + '">' + label + '</button>';
    box.innerHTML = '<div class="sw-row"><span class="nm">Start-up sound</span>' + sw('startupsound', 'on', 'On', snd === true) + sw('startupsound', 'off', 'Off', snd === false) + '</div>' +
      '<div class="sw-row"><span class="nm">Mic</span><span class="mic">' + esc(micText(s)) + '</span>' +
      '<button type="button" class="btn" data-c="mic" data-a="next">Next</button></div>' +
      (R.answer.sw ? '<p class="line answer">' + esc(R.answer.sw) + '</p>' : '');
    if (!s) box.querySelectorAll('button').forEach(b => { b.disabled = true; });
  },

  // ---- presses: one request each, the same /api/do the deck sends; a second press while the first is on its way is the same press ----
  fix() {
    if (R.stale || R.inFlight.fix) return;
    const rig = R.st.rig || {}; if (rig.driving || rig.sessionOn) return;
    R.inFlight.fix = true; R.drawReady();
    Promise.resolve(R.ctx.data.fetch('/api/doctor/run?quiet=1')).catch(() => null).then(() => { R.inFlight.fix = false; if (R.el) R.drawReady(); });
  },
  press(b) {
    if (R.stale || b.disabled) return;
    const c = b.dataset.c, a = b.dataset.a || '', key = c + '|' + a;
    if (R.inFlight[key]) return;
    R.inFlight[key] = true;
    const ac = /^ac/.test(c);
    const url = '/api/do?c=' + encodeURIComponent(c) + (a ? '&a=' + encodeURIComponent(a) : '');
    Promise.resolve(R.ctx.data.fetch(url)).then(async r => {
      let j = null, t = '';
      try { t = await r.text(); j = JSON.parse(t); } catch (e) { j = null; }
      if (ac) R.answer.ac = r.ok ? 'Sent to the AC' : r.status === 409 && t ? t : 'The AC did not take that';
      else {
        if (j && j.mics) R.st.settings = { startupSound: j.startupSound, mic: j.mic, mics: j.mics };      // the answer carries the settings as they are now
        R.answer.sw = j && j.say ? j.say : r.ok ? '' : 'Not done';
      }
    }, () => { if (ac) R.answer.ac = 'Paddock did not answer'; else R.answer.sw = 'Paddock did not answer'; })
      .then(() => { delete R.inFlight[key]; if (R.el) { R.drawAc(); R.drawSw(); } });
  },
};

export default {
  name: 'rig', title: 'RIG',
  mount(el, ctx) { R.mount(el, ctx); },
  unmount() { R.unmount(); },
};
export const Rig = R;                    // the test looks inside
