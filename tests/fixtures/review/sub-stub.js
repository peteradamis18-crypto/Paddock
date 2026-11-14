// A stand-in for W4-4's review-laps.js and W4-6's review-progress.js (mount(el, ctx, opts) / unmount() / onDeck(cmd)), for
// tests\review-card-test.ps1 only: it records what the card screen handed it. window.__progH gives the progress band a height.
const name = new URL(import.meta.url).pathname.split('/').pop();
const log = window.__subLog = window.__subLog || [];
export function mount(el, ctx, opts) {
  log.push([name, 'mount', JSON.stringify(opts || {})]);
  if (window.__noProg && name === 'review-progress.js') throw new Error('no progress band in this picture');
  el.innerHTML = '<div class="sub-stub" style="height:' + (name === 'review-progress.js' ? (window.__progH || 0) : 600) + 'px;font-size:24px">' + name + '</div>';
}
export function unmount() { log.push([name, 'unmount']); }
export function onDeck(cmd) { log.push([name, 'deck', JSON.stringify(cmd)]); }
