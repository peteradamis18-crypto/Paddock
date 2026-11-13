'use strict';
// A soft glow round the edge of the dashboard in the colour of the flag, while a session is live: yellow (caution or a
// local yellow), blue (let the car behind through), white (last lap), orange for repairs, green for as long as iRacing shows it,
// a slow chequered sweep at the finish, red for a red flag, a white frame for the black flag. Same flag as the panel.
// It only draws a thin edge over the outer margin, never takes clicks, and never shows anything else on the screen.
const FlagGlow = {
  el: null, cur: '',
  init() {
    const el = document.createElement('div'); el.id = 'flagGlow'; el.setAttribute('aria-hidden', 'true');
    document.body.appendChild(el); this.el = el;
    setInterval(() => this.tick(), 200);
  },

  tick() {
    let want = '';
    if (UI.live() && !L.v.IsReplayPlaying) {
      // the flag the panel worked out (ui.js flags), so the glow can't disagree with it or with the light box
      want = UI.flagName === 'warning' ? 'black' : (UI.flagName || '');
    }
    if (want === this.cur) return;
    this.cur = want;
    this.el.className = want ? 'on ' + want : '';
  },
};
FlagGlow.init();