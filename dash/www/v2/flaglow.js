'use strict';
// A soft glow round the edge of the dashboard in the colour of the flag, while a session is live: yellow (caution or a
// local yellow), blue (let the car behind through), white (last lap), green for a few seconds when the race starts,
// a slow chequered sweep at the finish, red for a red flag, a white frame for the black flag. Read from SessionFlags.
// It only draws a thin edge over the outer margin, never takes clicks, and never shows anything else on the screen.
const FlagGlow = {
  el: null, cur: '', prevGreen: undefined, greenUntil: 0,
  BITS: { checkered: 0x1, white: 0x2, green: 0x4, yellow: 0x8, red: 0x10, blue: 0x20, debris: 0x40, yellowWaving: 0x100, oneToGreen: 0x200, greenHeld: 0x400,
          caution: 0x4000, cautionWaving: 0x8000, black: 0x10000, dq: 0x20000, furled: 0x80000 },

  init() {
    const el = document.createElement('div'); el.id = 'flagGlow'; el.setAttribute('aria-hidden', 'true');
    document.body.appendChild(el); this.el = el;
    setInterval(() => this.tick(), 200);
  },

  // what the flags say, most important first
  which(f) {
    const B = this.BITS, has = k => (f & B[k]) !== 0;
    if (has('black') || has('dq') || has('furled')) return 'black';
    if (has('red')) return 'red';
    if (has('checkered')) return 'checkered';
    if (has('yellow') || has('yellowWaving') || has('caution') || has('cautionWaving') || has('debris')) return 'yellow';
    if (has('blue')) return 'blue';
    if (has('white')) return 'white';
    return '';
  },

  tick() {
    let want = '';
    if (UI.live() && !L.v.IsReplayPlaying) {
      const f = (L.v.SessionFlags >>> 0) || 0, green = (f & (this.BITS.green | this.BITS.greenHeld)) !== 0;
      want = this.which(f);
      // green: only for a few seconds after it is shown, and not for a page that has just loaded into a running race
      if (this.prevGreen === false && green) this.greenUntil = Date.now() + 8000;
      this.prevGreen = green;
      if (!want && Date.now() < this.greenUntil) want = 'green';
    } else { this.prevGreen = undefined; this.greenUntil = 0; }
    if (want === this.cur) return;
    this.cur = want;
    this.el.className = want ? 'on ' + want : '';
  },
};
FlagGlow.init();