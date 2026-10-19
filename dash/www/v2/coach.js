'use strict';
// Paddock Coach (coach.html?id=<telemetry file>): what to fix next, from irdash /analysis/coach (dash\src\coach.cs).
//  - one main card (the biggest repeated loss) and two smaller ones; each: corner, typical loss per lap, how often,
//    the measured facts (mph, metres), one instruction, the four phases (brake, entry, apex, exit) lit where time goes;
//  - WATCH plays HIS video of that corner: the typical lap and the best lap side by side, started together 3 s before the
//    corner, from the session's own recording (/api/rec/for gives the verified recording and where each lap starts);
//  - SHOW ME opens the Workbench at that corner against the same best lap; ALL LAPS AND DATA opens the Session Review.
// Never while he drives (the host closes). Words: docs\COPY-RULES.md. Unknown is a dash, never 0.
(function () {
  const $ = id => document.getElementById(id);
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const DOT = ' · ', DASH = '—';
  const P = new URLSearchParams(location.search); let ID = P.get('id') || '';
  const lap = t => { if (!(t > 0)) return DASH; const m = Math.floor(t / 60), s = t - m * 60; return (m ? m + ':' : '') + (m && s < 10 ? '0' : '') + s.toFixed(3); };
  const stage = $('stage');
  let C = null, R = null, RES = null;

  function fit() { const s = Math.min(innerWidth / 1920, innerHeight / 1080); stage.style.transform = 'scale(' + s + ')'; stage.style.left = Math.max(0, (innerWidth - 1920 * s) / 2) + 'px'; }
  addEventListener('resize', fit); fit();

  const PLAY = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M14 8l26 16-26 16z"/></svg>';
  const phases = f => {
    // only the phases whose facts are on the card light up (coach.cs shown[]), so a chip never claims what the card does not say
    const sh = f.shown || [], on = { brake: sh.indexOf('brake') >= 0, entry: sh.indexOf('entry') >= 0, apex: sh.indexOf('min') >= 0, exit: sh.indexOf('exit') >= 0 || sh.indexOf('pickup') >= 0 };
    return '<div class="chips">' + ['brake', 'entry', 'apex', 'exit'].map(k => '<i class="' + (on[k] ? 'on' : '') + '">' + k + '</i>').join('') + '</div>';
  };
  const offsetOf = n => { const l = R && R.laps && R.laps.find(x => x.n === n); return l && typeof l.offset === 'number' ? l.offset : null; };
  // can WATCH play this card? the reason in plain words when not
  function video(f) {
    if (!R || !R.ok || !R.id) return { ok: false, why: 'No video kept of this drive' };   // the recorder keeps only the last 8 unsaved sessions; KEEP VIDEO right after a drive saves one
    // a cue of null: a part-lap that does not start at the line has no place in the recording; no best: the best lap is from another drive
    const a = f.example && f.example.at != null ? offsetOf(f.example.lap) : null, b = f.best ? offsetOf(f.best.lap) : null;
    if (a == null && b == null) return { ok: false, why: f.best ? 'These laps are not in the recording' : 'This lap is not in the recording' };
    return { ok: true, a: a == null ? null : Math.max(0, a + f.example.at), b: b == null ? null : Math.max(0, b + f.best.at), src: '/api/rec/session-video?id=' + encodeURIComponent(R.id) };
  }

  // ---- what the drive held (coach.cs "summary", from rawdata.cs): shown whenever there is no habit to report, so the screen is never only a refusal ----
  const mmss = s => { if (!(s >= 0)) return DASH; const m = Math.floor(s / 60), x = Math.round(s - m * 60); return m + ':' + (x < 10 ? '0' : '') + x; };
  function tiles(n, big) {
    const s = C.summary; if (!s) return '';
    const L = s.laps || {}, rest = [];
    if (L.out) rest.push(L.out + (L.out === 1 ? ' out-lap' : ' out-laps')); if (L.in) rest.push(L.in + (L.in === 1 ? ' in-lap' : ' in-laps')); if (L.partial) rest.push(L.partial + (L.partial === 1 ? ' part lap' : ' part laps')); if (L.pit) rest.push(L.pit + ' through the pits');
    const all = [
      ['On track', mmss(s.onTrackSec), s.miles != null ? s.miles.toFixed(1) + ' miles' : ''],
      ['Full laps', String(L.full || 0), rest.join(', ') || (L.best ? 'best ' + lap(L.best) : '')],
      ['Top speed', s.topMph != null ? Math.round(s.topMph) + ' mph' : DASH, s.topAt != null ? 'at ' + mmss(s.topAt) + ' into the drive' : ''],
      ['Fuel used', s.fuelUsedGal != null ? s.fuelUsedGal.toFixed(2) + ' gal' : DASH, s.fuelUsedL != null ? s.fuelUsedL.toFixed(1) + ' litres' : ''],
      ['Pit lane', mmss(s.pitSec), 'time in the pit lane'],
      ['Incidents', s.incidents != null ? String(s.incidents) : DASH, s.offTracks != null ? s.offTracks + (s.offTracks === 1 ? ' time off track' : ' times off track') : ''],
      ['Most grip', s.maxLatG != null ? s.maxLatG.toFixed(2) + ' g' : DASH, s.maxBrakeG != null ? 'cornering · ' + s.maxBrakeG.toFixed(2) + ' g braking' : 'cornering'],
      ['Top RPM', s.maxRpm != null ? String(Math.round(s.maxRpm)) : DASH, '']];
    return '<div class="tiles' + (big ? ' big' : '') + '" style="--n:' + Math.min(n, big ? 4 : 6) + '">' + all.slice(0, n).map(t => '<div><span class="lbl">' + t[0] + '</span><b>' + esc(t[1]) + '</b><span class="sub">' + esc(t[2]) + '</span></div>').join('') + '</div>';
  }
  const rawUrl = () => 'rawdata.html?id=' + encodeURIComponent(C.file || ID) + (C.lap && C.lap.partial ? '&lap=' + C.lap.lap : '');
  const rawBtn = gold => '<button class="' + (gold ? 'go' : 'btn') + ' raw" id="cRawBig" type="button"><div><b>Show all the data</b><span>Every second of the drive: speed, pedals, steering, gear, the map</span></div></button>';
  // the corners of the one compared lap against the reference: + lost, − gained, a dash when under 0.05 s either way
  function cornerStrip() {
    const cs = C.corners || []; if (!cs.length) return '';
    return '<div class="cstrip"><span class="lbl">Every corner against the ' + (C.mode === 'two' ? 'quicker lap' : 'best lap ever') + '</span><div>' +
      cs.map(c => '<i class="' + (c.dTime >= 0.05 ? 'loss' : c.dTime <= -0.05 ? 'gain' : '') + '"><b>' + esc(c.label) + '</b>' + (c.dTime >= 0 ? '+' : '−') + Math.abs(c.dTime).toFixed(2) + '</i>').join('') + '</div></div>';
  }

  function draw() {
    const few = C.mode && C.mode !== 'habit';
    const refLine = !C.ref ? '' : C.mode === 'two' ? 'Compared with the quicker lap: <b>lap ' + C.ref.lap + DOT + lap(C.ref.time) + '</b><br>' :
      C.mode === 'pb' || C.mode === 'partial' ? 'Compared with the ' + (C.ref.kind === 'next best ever' ? 'next best lap ever' : 'best lap ever') + ': <b>' + lap(C.ref.time) + '</b>' + (C.ref.date ? DOT + esc(dayWord(C.ref.date)) : '') + '<br>' :
      'Compared with the best clean lap: <b>lap ' + C.ref.lap + DOT + lap(C.ref.time) + '</b><br>';
    const countLine = C.mode === 'partial' ? 'No full lap in this drive' : C.mode === 'pb' && !C.clean ? 'No clean lap in this drive' : C.mode === 'drive' ? (C.clean ? C.clean + (C.clean === 1 ? ' lap' : ' laps') + ' at race pace' : 'No lap at race pace') : C.clean + (C.clean === 1 ? ' lap' : ' laps') + ' at race pace compared';
    let h = '<div class="head"><div class="where"><b>' + esc(C.track || DASH) + (C.config && !/^(full|full course|grand prix)$/i.test(C.config) ? ' <small style="font-size:30px;color:var(--mute)">' + esc(C.config) + '</small>' : '') + '</b><span>' + esc([C.car, RES].filter(Boolean).join(DOT)) + '</span></div>' +
      '<div class="ref">' + refLine + countLine + '</div>' +
      (R && R.ok && R.id ? '<button class="btn" id="cKeep" type="button"' + (R.saved ? ' disabled' : '') + '>' + (R.saved ? 'Video kept' : 'Keep video') + '</button>' : '') +
      '<button class="btn" id="cAll" type="button">All laps</button><button class="btn" id="cRaw" type="button">All the data</button></div>';
    if (!C.ready || C.mode === 'drive') {
      // nothing to compare: what the drive held, and every channel of it one press away (never only a sentence)
      h += '<div class="drive"><b>' + esc(C.reason || 'Nothing to compare yet') + '</b>' + (C.hint ? '<span>' + esc(C.hint) + '</span>' : '') + '</div>' + tiles(8, true) + '<div class="rawwrap big">' + rawBtn(true) + '</div>';
      stage.innerHTML = h; wire(); return;
    }
    if (few) { drawFew(h); return; }
    const f = C.focus || [];
    if (!f.length) {
      h += '<div class="empty"><b>' + esc(C.reason) + '</b><span>Where time is lost changes from lap to lap: repeatable laps come first.</span></div>';
    } else {
      const a = f[0], v = video(a);
      h += '<div class="hr" style="top:184px"></div><section class="main">' +
        '<div class="who"><div class="lbl">Next to work on</div><div class="c">' + esc(a.label) + '</div><div class="nm">' + esc(a.name && a.name !== a.label ? a.name : '') + '</div>' +
        '<div class="loss">' + a.loss.toFixed(2) + ' s<small>a lap</small></div><div class="often">Lost in ' + a.lost + ' of ' + a.laps + ' laps' + DOT + esc(a.where || '') + '</div>' + phases(a) + '</div>' +
        '<div class="what"><div class="lbl">Measured against the best lap</div><ul class="facts">' + (a.facts.length ? a.facts.map(x => '<li>' + esc(x) + '</li>').join('') : '<li style="color:var(--mute)">No single input differs enough to name</li>') + '</ul><div class="say">' + esc(a.say) + '</div></div>' +
        '<div class="act"><button class="go" type="button" data-watch="0"' + (v.ok ? '' : ' disabled') + '><div><b>Watch</b><span>' + (v.ok ? 'Lap ' + a.example.lap + ' and best lap ' + a.best.lap : esc(v.why)) + '</span></div>' + PLAY + '</button>' +
        '<button class="btn" type="button" data-show="0">Show me in the data</button></div></section>';
      if (f.length > 1) {
        h += '<div class="hr" style="top:660px"></div><section class="more">' + f.slice(1).map((c, i) => {
          const vv = video(c);
          return '<div class="card"><div class="lbl">Then</div><div class="top"><span class="c">' + esc(c.label) + '</span><span class="loss">' + c.loss.toFixed(2) + ' s<small>a lap' + DOT + c.lost + ' of ' + c.laps + ' laps</small></span></div>' +
            '<div class="fact">' + esc(c.facts[0] || 'No single input differs enough to name') + '</div><div class="say2">' + esc(c.say) + '</div>' +
            '<div class="row"><button class="btn" type="button" data-watch="' + (i + 1) + '"' + (vv.ok ? '' : ' disabled title="' + esc(vv.why) + '"') + '>Watch</button><button class="btn" type="button" data-show="' + (i + 1) + '">Show me</button></div></div>';
        }).join('') + '</section>';
      }
    }
    const shaky = C.inconsistent || [];
    h += '<div class="foot"><span class="warn">' + (shaky.length ? 'One-off losses (mistakes, not habits): ' + esc(shaky.map(s => s.label + ' ' + s.worst.toFixed(2) + ' s in ' + s.lost + ' of ' + s.laps + ' laps').join(DOT)) : '') + '</span>' +
      '<span>' + (C.perLap > 0 ? 'Together about ' + C.perLap.toFixed(2) + ' s a lap' : '') + '</span></div>';
    h += '<div class="watch" id="cWatch"></div>';
    stage.innerHTML = h; wire();
  }

  // 2 laps, 1 lap, or a part-lap: one comparison, said plainly to be a hint. The main card when a corner lost time, then what the drive
  // held, every corner's difference, and ALL THE DATA (gold when WATCH has no video to play, so there is always one obvious press).
  function drawFew(h) {
    const f = C.focus || [], a = f[0], v = a ? video(a) : { ok: false };
    const what = C.mode === 'two' ? 'Lap ' + (C.lap ? C.lap.lap : '') + ' against lap ' + C.ref.lap : C.lap && C.lap.partial ? (C.lap.cover && C.lap.cover.skip === 'out' ? 'The out-lap' : 'Part of lap ' + C.lap.lap) : 'Lap ' + (C.lap ? C.lap.lap : '') + ' against the best ever';
    h += '<div class="hint">' + esc(C.hint || '') + '</div>';
    if (a) {
      h += '<section class="main few">' +
        '<div class="who"><div class="lbl">Biggest loss</div><div class="c">' + esc(a.label) + '</div><div class="nm">' + esc(a.name && a.name !== a.label ? a.name : '') + '</div>' +
        '<div class="loss">' + a.loss.toFixed(2) + ' s<small>in this corner</small></div><div class="often">' + esc(what) + DOT + esc(a.where || '') + '</div>' + phases(a) + '</div>' +
        '<div class="what"><div class="lbl">Measured against that lap</div><ul class="facts">' + (a.facts.length ? a.facts.map(x => '<li>' + esc(x) + '</li>').join('') : '<li style="color:var(--mute)">No single input differs enough to name</li>') + '</ul><div class="say">' + esc(a.say) + '</div></div>' +
        '<div class="act"><button class="go" type="button" data-watch="0"' + (v.ok ? '' : ' disabled') + '><div><b>Watch</b><span>' + (v.ok ? 'Lap ' + a.example.lap + (a.best ? ' and lap ' + a.best.lap : '') : esc(v.why)) + '</span></div>' + PLAY + '</button>' +
        '<button class="btn" type="button" data-show="0">Show me in the data</button></div></section>';
    } else h += '<div class="drive few"><b>' + esc(C.reason || 'No corner lost time') + '</b><span>' + esc(what) + '</span></div>';
    h += tiles(6, false) + cornerStrip() + '<div class="rawwrap">' + rawBtn(!v.ok) + '</div>';
    stage.innerHTML = h; wire();
  }
  const dayWord = iso => { const m = /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)/.exec(iso || ''); if (!m) return ''; const d = new Date(+m[1], +m[2] - 1, +m[3]); return d.toLocaleDateString('en-US', { weekday: 'short', day: 'numeric', month: 'short' }); };

  function wire() {
    const raw = () => openPage(rawUrl(), 'All the data');
    const rb = $('cRaw'); if (rb) rb.addEventListener('click', raw);
    const rbb = $('cRawBig'); if (rbb) rbb.addEventListener('click', raw);
    const keep = $('cKeep');
    if (keep) keep.addEventListener('click', async () => {
      // KEEP: this session's recording, by its own id (never the newest); the words say what really happened
      keep.disabled = true; keep.textContent = 'Keeping…';
      let st = ''; try { st = ((await (await fetch('/api/rec/save?id=' + encodeURIComponent(R.id), { cache: 'no-store' })).json()) || {}).state || ''; } catch (e) { }
      keep.textContent = st === 'SAVED' ? 'Video kept' : st === 'SAVING' ? 'Keeping when done' : st === 'SAVED FULL' ? 'Saved space full' : 'Could not keep';
      keep.disabled = st === 'SAVED' || st === 'SAVING';
    });
    const all = $('cAll'); if (all) all.addEventListener('click', () => openPage('sessionreview.html?id=' + encodeURIComponent(ID), 'All laps and data'));
    stage.querySelectorAll('[data-watch]').forEach(b => b.addEventListener('click', () => watch(C.focus[+b.dataset.watch])));
    stage.querySelectorAll('[data-show]').forEach(b => b.addEventListener('click', () => {
      // habits and 2 laps: against this session's best; 1 lap or a part-lap: against the best lap ever (the workbench's PB reference)
      const f = C.focus[+b.dataset.show], l = f.example ? f.example.lap : C.ref.lap, ref = C.mode === 'pb' || C.mode === 'partial' ? 'pb' : 'session';
      openPage('workbench.html?id=' + encodeURIComponent(C.file || ID) + '&lap=' + l + '&ref=' + ref + '&page=driver&corner=' + encodeURIComponent(f.n), f.label + DOT + 'lap ' + l + ' against the ' + (ref === 'pb' ? 'best lap ever' : 'best lap'));
    }));
  }

  // two videos of the same recording, each seeked to its lap's cue, played together for 10 s
  let stopT = 0;
  function watch(f) {
    const v = video(f), w = $('cWatch'); if (!v.ok || !w) return;
    const box = (at, title, sub) => at == null ? '<div class="v"><div class="none">Not in the recording</div><div class="cap"><b>' + title + '</b><span>' + sub + '</span></div></div>'
      : '<div class="v"><video muted playsinline preload="auto" src="' + v.src + '#t=' + at.toFixed(2) + '" data-at="' + at.toFixed(3) + '"></video><div class="cap"><b>' + title + '</b><span>' + sub + '</span></div></div>';
    w.innerHTML = '<div class="t"><b>' + esc(f.label) + '</b><span>' + f.loss.toFixed(2) + ' s a lap' + DOT + esc(f.facts[0] || '') + '</span></div>' +
      '<div class="vids">' + box(v.a, 'This lap', 'Lap ' + f.example.lap + DOT + lap(f.example.time)) + (f.best ? box(v.b, 'Best lap', 'Lap ' + f.best.lap + DOT + lap(C.ref.time)) : box(null, 'Best lap ever', 'From another drive' + DOT + lap(C.ref.time))) + '</div>' +
      '<div class="acts"><button class="go" type="button" id="cReplay">Replay</button><button class="btn" type="button" id="cClose">Close</button><div class="say">' + esc(f.say) + '</div></div>';
    w.classList.add('on');
    $('cReplay').addEventListener('click', play); $('cClose').addEventListener('click', closeWatch);
    play();
  }
  // Both start together once each is at its cue. A video that fails to load, or is already at the cue (no 'seeked'),
  // must not hold the other back: each counts once (seeked, error, or a 3 s timeout), and a newer press wins (gen).
  let gen = 0;
  function play() {
    const vids = [].slice.call(document.querySelectorAll('#cWatch video')); clearTimeout(stopT);
    const my = ++gen; let ready = 0;
    const start = () => { if (my !== gen) return; vids.forEach(y => { if (!y.error) y.play().catch(() => { }); }); stopT = setTimeout(() => { if (my === gen) vids.forEach(y => y.pause()); }, 10000); };
    vids.forEach(x => {
      x.pause();
      let counted = false; const go = () => { if (counted || my !== gen) return; counted = true; if (++ready === vids.length) start(); };
      x.addEventListener('seeked', go, { once: true }); x.addEventListener('error', go, { once: true }); setTimeout(go, 3000);
      const at = +x.dataset.at;
      if (x.readyState >= 1 && Math.abs(x.currentTime - at) < 0.01) go(); else x.currentTime = at;
    });
    if (!vids.length) return;
  }
  function closeWatch() { const w = $('cWatch'); if (!w) return; clearTimeout(stopT); w.querySelectorAll('video').forEach(x => { x.pause(); x.removeAttribute('src'); x.load(); }); w.classList.remove('on'); w.innerHTML = ''; }

  // a full page over the coach (Workbench or Session Review), with a back bar; Esc goes back
  function openPage(url, title) {
    if (document.querySelector('.host')) return;
    const host = document.createElement('div'); host.className = 'host';
    host.innerHTML = '<div class="bar"><button class="btn" type="button">‹ Coach</button><span>' + esc(title) + '</span></div><iframe title="' + esc(title) + '"></iframe>';
    host.querySelector('iframe').src = url; document.body.appendChild(host);
    const m = e => { if (e.origin === location.origin && e.data && e.data.irdash === 'workbench-close') close(); };
    const close = () => { removeEventListener('message', m); host.remove(); };
    host._close = close;
    host.querySelector('button').addEventListener('click', close);
    addEventListener('message', m);
  }
  addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    const host = document.querySelector('.host'); if (host) { if (host._close) host._close(); else host.remove(); return; }
    const w = $('cWatch'); if (w && w.classList.contains('on')) { closeWatch(); return; }
    if (parent !== window) parent.postMessage({ irdash: 'coach-close' }, location.origin);
  });

  async function load() {
    stage.innerHTML = '<div class="empty"><b>Reading the laps</b></div>';
    // id=last (the deck's DEBRIEF key): the session HOME shows as his last outing
    if (ID === 'last') { try { ID = ((await (await fetch('/home', { cache: 'no-store' })).json()).lastOuting || {}).file || ''; } catch (e) { ID = ''; } if (!ID) { stage.innerHTML = '<div class="empty"><b>No drive recorded yet</b></div>'; return; } }
    try { C = await (await fetch('/analysis/coach?id=' + encodeURIComponent(ID), { cache: 'no-store' })).json(); } catch (e) { C = null; }
    if (!C || C.error) { stage.innerHTML = '<div class="empty"><b>' + esc(C && C.error === 'Not while driving' ? 'Not while driving' : 'This session could not be read') + '</b><span>' + esc(ID) + '</span></div>'; return; }
    try { R = await (await fetch('/api/rec/for?id=' + encodeURIComponent(ID), { cache: 'no-store' })).json(); } catch (e) { R = null; }
    // a race: the result in one line (the after-session screen passes the race log id)
    if (P.get('race')) {
      try {
        const d = await (await fetch('/debrief?id=' + encodeURIComponent(P.get('race')), { cache: 'no-store' })).json(), r = d && d.result;
        if (r && r.finishPosition > 0) RES = 'Finished P' + r.finishPosition + (r.startPosition > 0 ? ' from P' + r.startPosition : '') + (r.classPosition > 0 && r.classPosition !== r.finishPosition ? DOT + 'P' + r.classPosition + ' in class' : '') + (r.totalLaps > 0 ? DOT + r.cleanLaps + ' of ' + r.totalLaps + ' laps clean' : '');
      } catch (e) { }
    }
    draw();
    if (P.get('watch') != null && C.focus && C.focus[+P.get('watch')]) watch(C.focus[+P.get('watch')]);   // tests and the deck: open WATCH straight away
  }
  window.Coach = { load, data: () => C, rec: () => R, video, watch, closeWatch };
  load();
})();
