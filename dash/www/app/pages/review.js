// REVIEW door (W3-1): a thin host for the old Sessions page (v2/sessions.html?embed=1, the latest drive on top) until wave 4
// rebuilds REVIEW. RACES' REVIEW key passes the race's start (opts.at), which wave 4 opens directly.
import { hostFrame } from '../lib/host.js';
let frame = null;
export default {
  name: 'review', title: 'REVIEW',
  mount(el, ctx) {
    const at = ctx && ctx.opts && ctx.opts.at;
    frame = hostFrame(el, '../v2/sessions.html?embed=1' + (at ? '&at=' + encodeURIComponent(at) : ''), 'Review');
  },
  unmount() { frame = null; },          // the shell empties the page area: the frame and its subscriptions end with it
};
