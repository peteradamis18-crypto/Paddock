// REVIEW screen 3, MORE DATA (W4-5; PLAN 4.4): the one workbench (v2/workbench.html) inside the REVIEW door, in the shell's host frame.
// Tabs: DRIVER (the stack, every channel through + CHANNEL), BRAKING, SPLITS and RACE. The links at its foot: OPEN IN PI TOOLBOX (only when Pi is
// installed), OPEN DELTA (only when Delta is) and EXPORT CSV. Everything inside the frame is workbench.js; nothing there polls irdash.
// This module is not a door of its own: the REVIEW page (review.js, W4-3) imports it for ctx.opts.screen === 'more' and calls
//   mount(el, ctx, opts)   opts = { id, lap, ref, page, corner }  (id = the telemetry file name or a Vault lap id)
//   unmount()
//   onDeck(cmd)            cmd = { seq, cmd, arg } (irdash's "workbench" state part) or a plain command name; the module also follows that
//                          state part itself (ctx.data.on), so the page need not forward it. A seq is run once.
// Esc: the workbench resets its zoom only when zoomed; otherwise it leaves Esc alone, lib/host.js forwards it and the shell goes HOME.
import { hostFrame } from '../lib/host.js';

let frame = null, lastSeq = null, drivingNow = null, live = false;

function url(o) {
  const q = new URLSearchParams();
  ['id', 'lap', 'ref', 'page', 'corner'].forEach(k => { if (o[k] != null && o[k] !== '') q.set(k, String(o[k])); });
  return '../v2/workbench.html?' + q.toString();
}

function run(name, arg) {
  const w = frame && frame.contentWindow;
  try { if (w && w.WB && w.WB.state) return w.WB.cmd(String(name), arg == null ? '' : String(arg)); } catch (e) { }     // not loaded yet: the press is dropped
  return false;
}

// a command from the deck: { seq, cmd, arg } once per new seq (the first one seen only learns the seq), or just a name
export function onDeck(c) {
  if (!live || !c) return false;
  if (typeof c === 'string') return !(drivingNow && drivingNow()) && run(c, '');
  if (!c.cmd) return false;
  if (typeof c.seq === 'number') { if (c.seq === lastSeq) return false; const first = lastSeq === null; lastSeq = c.seq; if (first) return false; }
  if (drivingNow && drivingNow()) return false;
  return run(c.cmd, c.arg);
}

export function mount(el, ctx, opts) {
  opts = Object.assign({}, (ctx && ctx.opts) || {}, opts || {});
  live = true; lastSeq = null; drivingNow = ctx && ctx.driving ? ctx.driving : null;
  if (!document.querySelector('link[data-page="review-more"]')) {
    const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = new URL('review-more.css', import.meta.url).href; l.dataset.page = 'review-more';
    document.head.appendChild(l);
  }
  if (!opts.id || !opts.lap) {                       // nothing to open: say so in words, no dead frame
    const d = document.createElement('div'); d.className = 'rm-empty';
    d.textContent = 'No lap is open. Pick a lap on the REVIEW screen, then press MORE DATA.';
    el.appendChild(d); return;
  }
  frame = hostFrame(el, url(opts), 'More data');
  frame.classList.add('rm-frame');
  const st = ctx && ctx.data && ctx.data.state;
  if (st && st.workbench && typeof st.workbench.seq === 'number') lastSeq = st.workbench.seq;          // a command from before this page opened is not run
  if (ctx && ctx.data && ctx.data.on) ctx.data.on('state', (s, ch) => { if (ch && ch.workbench && s && s.workbench) onDeck(s.workbench); });
}

export function unmount() { live = false; frame = null; lastSeq = null; drivingNow = null; }

export default { name: 'review-more', title: 'MORE DATA', mount, unmount, onDeck };
