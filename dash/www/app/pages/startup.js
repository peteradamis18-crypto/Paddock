/* startup.js (W3-2, docs/rework/PLAN.md 4.1 "Start-up (7 s, any key skips)"): the F1 start, then the clock.
   Black. Five gold lights come on left to right, one a second, each with a soft low tone. A beat of silence with all
   five lit. Lights out (instantly, as at a real start); the dial fades up in HOME's clock box with the seconds hand
   already sweeping. Nothing explodes (evidence 07: "five identical lights, a silence, then darkness").
     Startup.play(el, { sound, quiet, skipOn, dial }) -> Promise<'done' | 'skipped'>
       el      the shell's #startup layer (shown for the play, hidden again after)
       quiet   23:00-07:00 local (isQuietHours()): no tones, and no AudioContext is even made
       dial    optional { ring, readout } so the start-up dial matches HOME's
     The Promise resolves at 7 s (or at once on a key / pointer). The layer then holds the full dial and fades away
     over 0.8 s, showing HOME underneath (HOME's dial is drawn in the same place, so only the side zones appear).
     Startup.init(el, { data, onStart, onEnd })  the triggers intro.js had: once per dashboard boot (irdash's
       /showcase?who=page says "play"), again when state.showcase.seq rises while he is not driving; never while
       driving; ?intro=1 forces it; ?hold=1 freezes it on the fifth light (for pictures).
   Tones are generated (Web Audio: a sine at 110 Hz, 30 ms attack, 400 ms decay, -18 dBFS): no sound file. */
import { Clock } from '../lib/clock.js';

const LIGHT_MS = 1000;        // one light a second
const OUT_MS = 6600;          // lights out: the fifth tone has died away by 5.4 s, then a beat of silence
const DONE_MS = 7000;         // the Promise resolves (the dial is well on its way up)
const FULL_MS = OUT_MS + 1200;  // the dial is fully up
const TONE = { hz: 110, attack: 0.03, decay: 0.4, peak: Math.pow(10, -18 / 20) };

export function isQuietHours(d) {
  const h = (d || Clock.now()).getHours();
  return h >= 23 || h < 7;
}

function css() {
  if (document.querySelector('link[data-paddock="startup"], link[href$="startup.css"]')) return;
  const l = document.createElement('link');
  l.rel = 'stylesheet'; l.href = new URL('../startup.css', import.meta.url).href; l.dataset.paddock = 'startup';
  document.head.appendChild(l);
}
css();      // at load, so the lights are styled from the first frame (the shell may also link it)

function tone(st) {
  try {
    if (!st.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      st.ctx = new AC();
    }
    const ctx = st.ctx;
    if (ctx.state === 'closed') return;
    if (ctx.state === 'suspended' && ctx.resume) ctx.resume().catch(function () { });
    const t = ctx.currentTime + 0.005;
    const o = ctx.createOscillator(), gn = ctx.createGain();
    o.type = 'sine'; o.frequency.value = TONE.hz;
    gn.gain.setValueAtTime(0, t);
    gn.gain.linearRampToValueAtTime(TONE.peak, t + TONE.attack);
    gn.gain.exponentialRampToValueAtTime(0.0001, t + TONE.attack + TONE.decay);
    o.connect(gn); gn.connect(ctx.destination);
    o.start(t); o.stop(t + TONE.attack + TONE.decay + 0.02);
  } catch (e) { /* no sound is never a reason to stop the start-up */ }
}

let running = null;

function play(el, opts) {
  opts = opts || {};
  if (running) return running.promise;
  const sound = opts.sound !== false && !(opts.quiet == null ? isQuietHours() : opts.quiet);
  const hold = opts.hold != null ? !!opts.hold : /[?&]hold=1/.test(location.search);
  const skipOn = opts.skipOn || ['keydown', 'pointerdown'];
  const st = { ctx: null, timers: [], clock: null, result: null, t0: performance.now() };

  el.innerHTML = '';
  el.hidden = false;
  el.classList.add('startup');
  el.classList.remove('gone', 'out', 'dial-up', 'skip', 'held');
  const row = document.createElement('div'); row.className = 'lights';
  const lights = [];
  for (let i = 0; i < 5; i++) { const d = document.createElement('i'); d.className = 'light'; row.appendChild(d); lights.push(d); }
  const dial = document.createElement('div'); dial.className = 'dial';
  el.append(row, dial);

  let resolve;
  const promise = new Promise(function (r) { resolve = r; });
  running = { promise: promise, st: st, el: el, cancel: null };
  const at = function (ms, f) { st.timers.push(setTimeout(f, Math.max(0, ms - (performance.now() - st.t0)))); };
  const stopTimers = function () { st.timers.forEach(clearTimeout); st.timers = []; };

  function dialUp(now) {
    el.classList.add('out');
    if (!st.clock) st.clock = Clock.mount(dial, Object.assign({ size: 720 }, opts.dial || {}));
    if (now) el.classList.add('skip');
    // the next frame, so the 1.2 s fade runs from 0 (a skip shows it at once)
    requestAnimationFrame(function () { el.classList.add('dial-up'); });
  }
  function finish(how) {
    if (st.result) return;
    st.result = how;
    stopTimers();
    skipOn.forEach(function (n) { window.removeEventListener(n, onSkip, true); });
    if (how === 'skipped') { el.classList.add('skip'); dialUp(true); }
    resolve(how);
    // hold the full dial, then fade the layer away over HOME (whose dial sits in the same place)
    const left = how === 'skipped' ? 600 : Math.max(0, FULL_MS - (performance.now() - st.t0));
    setTimeout(function () {
      if (st.cancelled) return;
      el.classList.add('gone');
      setTimeout(function () {
        if (st.cancelled) return;
        if (st.clock) st.clock.unmount();
        if (st.ctx && st.ctx.close && st.ctx.state !== 'closed') { try { st.ctx.close().catch(function () { }); } catch (e) { } }
        el.innerHTML = ''; el.hidden = true;
        el.classList.remove('gone', 'out', 'dial-up', 'skip', 'held');
        if (running && running.st === st) running = null;
      }, 850);
    }, left);
  }
  function onSkip() { finish('skipped'); }
  skipOn.forEach(function (n) { window.addEventListener(n, onSkip, true); });
  // W3-1: he got in the car (or the shell must clear the screen): everything stops at once, the tones too
  running.cancel = function () {
    st.cancelled = true;
    stopTimers();
    skipOn.forEach(function (n) { window.removeEventListener(n, onSkip, true); });
    if (st.clock) { try { st.clock.unmount(); } catch (e) { } st.clock = null; }
    if (st.ctx && st.ctx.close && st.ctx.state !== 'closed') { try { st.ctx.close().catch(function () { }); } catch (e) { } }
    el.innerHTML = ''; el.hidden = true;
    el.classList.remove('gone', 'out', 'dial-up', 'skip', 'held');
    if (!st.result) { st.result = 'stopped'; resolve('stopped'); }
    if (running && running.st === st) running = null;
  };

  for (let i = 0; i < 5; i++) {
    at((i + 1) * LIGHT_MS, function () {
      lights[i].classList.add('on');
      if (sound) tone(st);
      if (i === 4 && hold) { stopTimers(); el.classList.add('held'); }
    });
  }
  if (!hold) {
    at(OUT_MS, function () { dialUp(false); });
    at(DONE_MS, function () { finish('done'); });
  }
  return promise;
}

// The triggers (moved from v2/intro.js): once per boot, the SHOWCASE key's seq, ?intro=1. Never while he is driving.
async function init(el, o) {
  o = o || {};
  const data = o.data || window.data;
  const force = /[?&]intro=1/.test(location.search);
  // W3-1: a guest in the car, or o.blocked() (the shell's race screen / a fresh frame on track) count as driving too
  const driving = function (st) {
    const r = (data && data.rig) || {};
    return !!r.driving || !!(st && st.showcase && st.showcase.driving) || !!(st && st.guest && st.guest.active) || !!(o.blocked && o.blocked());
  };
  // a window opened mid-race (KeepDash, a deploy) must know he is driving before it decides: wait for irdash's first state
  if (data && data.on && typeof data.seq === 'number' && data.seq < 0) {     // data.js says -1 until its first state
    await new Promise(function (res) {
      let off = null; const t = setTimeout(function () { if (off) off(); res(); }, 5000);
      off = data.on('state', function () { clearTimeout(t); setTimeout(function () { if (off) off(); }, 0); res(); });
    });
  }
  const go = function () {
    if (o.onStart) o.onStart();
    const p = play(el, { sound: true, quiet: isQuietHours(), skipOn: ['keydown', 'pointerdown'] });
    if (o.onEnd) p.then(o.onEnd);
    return p;
  };
  let seq = null;
  let s = null;
  try { s = await (await fetch('/showcase?who=page', { cache: 'no-store' })).json(); } catch (e) { s = null; }
  if (s && s.seq != null) seq = s.seq;
  if (force || (s && s.play && !driving(data && data.state))) go();
  if (data && data.on) {
    data.on('state', function (st, ch) {
      const t = st.showcase; if (!ch.showcase || !t) return;
      if (seq !== null && t.seq > seq && !driving(st)) go();
      seq = t.seq;
    });
  }
}

// W3-1: stop at once (lights, dial, tones); the play's Promise resolves 'stopped'
function stop() { if (running && running.cancel) running.cancel(); }

export const Startup = {
  play: play,
  init: init,
  stop: stop,
  isQuietHours: isQuietHours,
  get running() { return !!running; },
  TIMES: { light: LIGHT_MS, out: OUT_MS, done: DONE_MS, full: FULL_MS }
};
export default Startup;
