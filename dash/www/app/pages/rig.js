// RIG door (W3-1): a thin host for the old Performance page (v2/perf.html?embed=1) until wave 5 rebuilds RIG.
import { hostFrame } from '../lib/host.js';
let frame = null;
export default {
  name: 'rig', title: 'RIG',
  mount(el) { frame = hostFrame(el, '../v2/perf.html?embed=1', 'Rig'); },
  unmount() { frame = null; },
};
