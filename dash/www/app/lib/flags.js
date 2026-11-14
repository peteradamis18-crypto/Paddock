// The flag on the top screen (W3-1: moved here from v2/ui.js UI.flags, unchanged). The light box (tools\df8-flags.js) decides
// with this same table, so Paddock, the edge glow and the lights always show the same flag (CLAUDE.md, Peter 2026-11-02).
// tests\df8-flags-test.ps1 reads the table and the flags(f) body below: keep both shapes as they are.
// The shell feeds it SessionFlags from every fresh frame; isRace comes from the shell (the race part's session type).
let raceFn = () => true;
function isRace() { try { return !!raceFn(); } catch (e) { return true; } }

export const Flags = {
  flagName: '', flagCls: '', flagText: '', flagBlink: false, flagSt: null,
  setRace(fn) { raceFn = fn; },

  flags(f) {
    const F = { yellowWaving: 0x100, oneToGreen: 0x200, debris: 0x40, caution: 0x4000, cautionWaving: 0x8000, dq: 0x20000 };
    const has = k => (f & F[k]) !== 0;
    // the light box (tools\df8-flags.js) decides with this same table, so Paddock and the lights always show the same flag
    // FLAG TABLE START - the same text is in tools\df8-flags.js
    const FLAG_MIN_MS = 3000;       // a 1 s blue is real: every flag shows at least this long
    const FLAG_ORDER = [['black', 0x30000], ['orange', 0x100000], ['warning', 0x80000], ['checkered', 0x1], ['red', 0x10], ['yellow', 0xC148], ['blue', 0x20], ['white', 0x2], ['green', 0x4]];
    // FLAG TABLE END
    const st = this.flagSt || (this.flagSt = { was: {}, until: {} }), now = Date.now();
    let flag = '';
    for (const [name, mask] of FLAG_ORDER) {
      const on = (f & mask) !== 0;
      if (on && !st.was[name]) st.until[name] = now + FLAG_MIN_MS;
      st.was[name] = on;
      if (!flag && (on || now < (st.until[name] || 0))) flag = name;
    }
    this.flagName = flag;           // the edge glow and the race screen's flash show this same flag
    if (flag === 'black') return has('dq') ? this.setFlag('black', 'Disqualified') : this.setFlag('black', 'Black flag', true);
    if (flag === 'orange') return this.setFlag('meatball', 'Repair');
    if (flag === 'warning') return this.setFlag('black', 'Warning');
    if (flag === 'checkered') return this.setFlag('checkered', 'Finish');
    if (flag === 'red') return this.setFlag('red', 'Red flag');
    if (flag === 'yellow') {
      if (has('caution') || has('cautionWaving')) return this.setFlag('yellow', 'Caution', has('cautionWaving'));
      return this.setFlag('yellow', has('debris') ? 'Debris' : 'Yellow', has('yellowWaving'));
    }
    if (flag === 'blue') return this.setFlag('blue', 'Blue flag', true);
    if (flag === 'white') return this.setFlag('white', 'Last lap');
    if (flag === 'green') return this.setFlag('green', 'Green');
    this.setFlag('', has('oneToGreen') ? 'One to green' : isRace() ? 'Grid' : 'Running');   // not green yet: the box is dark too
  },
  setFlag(cls, text, blink) { this.flagCls = cls; this.flagText = text; this.flagBlink = !!blink; },
  // no live session: no flag (the glow goes dark, the race screen's flash has nothing new)
  clear() { this.flagName = ''; },
};
