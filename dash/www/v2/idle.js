'use strict';
// The garage screen between sessions: the clock, this week's numbers and the last outing. ui.js shows and hides #overlay; this only fills it in.
const Idle = {
  init() {
    this.clock(); setInterval(() => this.clock(), 1000);
    this.last(); setInterval(() => this.last(), 60000);
  },

  clock() {
    if (document.hidden) return;
    const d = new Date();
    // one clock everywhere: New York, 12-hour (home.js draws the same)
    if (typeof Home !== 'undefined' && Home.clock) { Home.clock(); return; }
    setText('idleClock', d.toLocaleTimeString('en-US', { timeZone: 'America/New_York', hour: 'numeric', minute: '2-digit' }) + ' ET');
  },

  async last() {
    if (document.hidden) return;
    let c;
    try { c = await (await fetch('/career', { cache: 'no-store' })).json(); } catch (e) { return; }
    this.week(c.week);
    if (!c.lastTrack) return;
    const when = c.lastAgo || '';
    setHTML('idleLast', 'Last outing &nbsp;<b>' + esc(c.lastTrack) + '</b>' + (c.lastCar ? ' &nbsp;·&nbsp; ' + esc(c.lastCar) : '') + (when ? ' &nbsp;·&nbsp; ' + esc(when) : ''));
  },

  // this week so far (since Monday), small and quiet: hours in the seat, laps, personal bests
  week(w) {
    const el = $('idleWeek');
    if (!el || !w) return;
    const hrs = x => x < 1 ? Math.round(x * 60) + '<small>min</small>' : x.toFixed(1) + '<small>h</small>';
    let h = '<label>This week</label>';
    if (!(w.sessions > 0)) {
      h += '<div class="none">No laps yet' + (w.lastHours > 0 ? '<em>last week ' + esc(hrs(w.lastHours).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim() + ' · ' + w.lastLaps + ' laps</em>' : '') + '</div>';
    } else {
      h += '<div class="w"><b>' + hrs(w.hours) + '</b><span>in the seat</span>' + (w.lastHours > 0 ? '<em>last week ' + esc(hrs(w.lastHours).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim()) + '</em>' : '') + '</div>' +
        '<div class="w"><b>' + w.laps + '</b><span>laps</span>' + (w.lastLaps > 0 ? '<em>last week ' + w.lastLaps + '</em>' : '') + '</div>' +
        '<div class="w' + (w.pbs > 0 ? ' pb' : '') + '"><b>' + w.pbs + '</b><span>personal ' + (w.pbs === 1 ? 'best' : 'bests') + '</span>' + (w.fresh > 0 ? '<em>+' + w.fresh + ' new ' + (w.fresh === 1 ? 'combination' : 'combinations') + '</em>' : '') + '</div>';
    }
    setHTML(el, h);
  }
};
Idle.init();
