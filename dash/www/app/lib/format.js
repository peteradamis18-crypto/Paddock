'use strict';
// One way to write a lap, a gap, a length of time, a date, a session name and a file size, so every page agrees.
// Plain script: window.Fmt (also module.exports; easy to wrap as an ES module later). Pure functions, no DOM.
(function (root) {
  const none = '–';                       // the one "no value" mark (en dash)
  const num = x => (typeof x === 'number' && isFinite(x));
  const pad2 = n => (n < 10 ? '0' : '') + n;

  // 93.832 -> 1:33.832; no lap -> none
  function lap(s) {
    if (!num(s) || s <= 0) return none;
    let m = Math.floor(s / 60), r = Math.round((s - m * 60) * 1000) / 1000;
    if (r >= 60) { m += 1; r = 0; }
    return m + ':' + (r < 10 ? '0' : '') + r.toFixed(3);
  }
  // +0.123, or -0.123 with the real minus sign (U+2212); zero is plain 0.000
  function delta(s) {
    if (!num(s)) return none;
    const a = Math.round(Math.abs(s) * 1000) / 1000;
    if (a === 0) return '0.000';
    return (s < 0 ? '−' : '+') + (a >= 60 ? lap(a) : a.toFixed(3));
  }
  // 720 -> 12 min, 3720 -> 1 h 02, 45 -> 45 s
  function dur(s) {
    if (!num(s) || s < 0) return none;
    if (s < 60) return Math.round(s) + ' s';
    const mins = Math.round(s / 60);
    return mins < 60 ? mins + ' min' : Math.floor(mins / 60) + ' h ' + pad2(mins % 60);
  }
  // Peter's clock is New York: Wed 12 Nov, 09:28
  const TZ = 'America/New_York';
  function parts(v) {
    const d = new Date(v);
    if (isNaN(d.getTime())) return null;
    const o = {};
    new Intl.DateTimeFormat('en-GB', { timeZone: TZ, weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
      .formatToParts(d).forEach(p => { o[p.type] = p.value; });
    return o;
  }
  function when(v) {
    const p = parts(v);
    return p ? p.weekday + ' ' + p.day + ' ' + p.month + ', ' + p.hour + ':' + p.minute : none;
  }
  // Today, 09:28 / Yesterday, 09:28 / Wed 12 Nov, 09:28 (nowV is only for tests)
  function whenRel(v, nowV) {
    const p = parts(v);
    if (!p) return none;
    const now = nowV == null ? Date.now() : new Date(nowV).getTime();
    const n = parts(now), y = parts(now - 86400000), key = q => q.day + q.month + q.year;
    const t = p.hour + ':' + p.minute;
    return key(p) === key(n) ? 'Today, ' + t : key(p) === key(y) ? 'Yesterday, ' + t : when(v);
  }
  // order matters: "AI race" before "race"
  function sessionName(type) {
    const t = String(type == null ? '' : type);
    if (/\bai\b/i.test(t)) return 'AI race';
    if (/test/i.test(t)) return 'Test drive';
    if (/qual/i.test(t)) return 'Qualifying';
    if (/prac|warm/i.test(t)) return 'Practice';
    if (/race/i.test(t)) return 'Race';
    return t || 'Session';
  }
  // 1.3 GB / 536 MB
  function size(bytes) {
    if (!num(bytes) || bytes < 0) return none;
    if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + ' GB';
    if (bytes >= 1048576) return Math.round(bytes / 1048576) + ' MB';
    return Math.max(1, Math.round(bytes / 1024)) + ' KB';
  }
  const api = { none: none, lap: lap, delta: delta, dur: dur, when: when, whenRel: whenRel, sessionName: sessionName, size: size };
  root.Fmt = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
