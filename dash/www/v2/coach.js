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
  const P = new URLSearchParams(location.search), ID = P.get('id') || '';
  const lap = t => { if (!(t > 0)) return DASH; const m = Math.floor(t / 60), s = t - m * 60; return (m ? m + ':' : '') + (m && s < 10 ? '0' : '') + s.toFixed(3); };
  const stage = $('stage');
  let C = null, R = null;

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
    if (!R || !R.ok || !R.id) return { ok: false, why: 'No video of this session' };
    const a = f.example ? offsetOf(f.example.lap) : null, b = f.best ? offsetOf(f.best.lap) : null;
    if (a == null && b == null) return { ok: false, why: 'These laps are not in the recording' };
    return { ok: true, a: a == null ? null : a + f.example.at, b: b == null ? null : b + f.best.at, src: '/api/rec/session-video?id=' + encodeURIComponent(R.id) };
  }

  function draw() {
    const where = [C.car, C.ref ? 'session best ' + lap(C.ref.time) : ''].filter(Boolean);
    let h = '<div class="head"><div class="where"><b>' + esc(C.track || DASH) + (C.config && !/^(full|full course|grand prix)$/i.test(C.config) ? ' <small style="font-size:30px;color:var(--mute)">' + esc(C.config) + '</small>' : '') + '</b><span>' + esc(C.car || '') + '</span></div>' +
      '<div class="ref">' + (C.ref ? 'Compared with the best clean lap: <b>lap ' + C.ref.lap + DOT + lap(C.ref.time) + '</b><br>' : '') + C.clean + ' clean laps</div>' +
      '<button class="btn" id="cAll" type="button">All laps and data</button></div>';
    if (!C.ready) {
      h += '<div class="empty"><b>' + esc(C.reason || 'Nothing to compare yet') + '</b><span>The coach needs three clean laps of one session: no off-tracks, no pit laps.</span></div>';
      stage.innerHTML = h; wire(); return;
    }
    const f = C.focus || [];
    if (!f.length) {
      h += '<div class="empty"><b>' + esc(C.reason) + '</b><span>The time differences between laps change from lap to lap.</span></div>';
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

  function wire() {
    const all = $('cAll'); if (all) all.addEventListener('click', () => openPage('sessionreview.html?id=' + encodeURIComponent(ID), 'All laps and data'));
    stage.querySelectorAll('[data-watch]').forEach(b => b.addEventListener('click', () => watch(C.focus[+b.dataset.watch])));
    stage.querySelectorAll('[data-show]').forEach(b => b.addEventListener('click', () => {
      const f = C.focus[+b.dataset.show], l = f.example ? f.example.lap : C.ref.lap;
      openPage('workbench.html?id=' + encodeURIComponent(C.file || ID) + '&lap=' + l + '&ref=session&page=driver&corner=' + encodeURIComponent(f.n), f.label + DOT + 'lap ' + l + ' against the best lap');
    }));
  }

  // two videos of the same recording, each seeked to its lap's cue, played together for 10 s
  let stopT = 0;
  function watch(f) {
    const v = video(f), w = $('cWatch'); if (!v.ok || !w) return;
    const box = (at, title, sub) => at == null ? '<div class="v"><div class="none">Not in the recording</div><div class="cap"><b>' + title + '</b><span>' + sub + '</span></div></div>'
      : '<div class="v"><video muted playsinline preload="auto" src="' + v.src + '#t=' + at.toFixed(2) + '" data-at="' + at.toFixed(3) + '"></video><div class="cap"><b>' + title + '</b><span>' + sub + '</span></div></div>';
    w.innerHTML = '<div class="t"><b>' + esc(f.label) + '</b><span>' + f.loss.toFixed(2) + ' s a lap' + DOT + esc(f.facts[0] || '') + '</span></div>' +
      '<div class="vids">' + box(v.a, 'This lap', 'Lap ' + f.example.lap + DOT + lap(f.example.time)) + box(v.b, 'Best lap', 'Lap ' + f.best.lap + DOT + lap(C.ref.time)) + '</div>' +
      '<div class="acts"><button class="go" type="button" id="cReplay">Replay</button><button class="btn" type="button" id="cClose">Close</button><div class="say">' + esc(f.say) + '</div></div>';
    w.classList.add('on');
    $('cReplay').addEventListener('click', play); $('cClose').addEventListener('click', closeWatch);
    play();
  }
  function play() {
    const vids = [].slice.call(document.querySelectorAll('#cWatch video')); clearTimeout(stopT);
    let ready = 0;
    vids.forEach(x => { x.pause(); const go = () => { if (++ready === vids.length) { vids.forEach(y => y.play().catch(() => { })); stopT = setTimeout(() => vids.forEach(y => y.pause()), 10000); } };
      x.addEventListener('seeked', go, { once: true }); x.currentTime = +x.dataset.at; });
  }
  function closeWatch() { const w = $('cWatch'); if (!w) return; clearTimeout(stopT); w.querySelectorAll('video').forEach(x => { x.pause(); x.removeAttribute('src'); x.load(); }); w.classList.remove('on'); w.innerHTML = ''; }

  // a full page over the coach (Workbench or Session Review), with a back bar; Esc goes back
  function openPage(url, title) {
    if (document.querySelector('.host')) return;
    const host = document.createElement('div'); host.className = 'host';
    host.innerHTML = '<div class="bar"><button class="btn" type="button">‹ Coach</button><span>' + esc(title) + '</span></div><iframe title="' + esc(title) + '"></iframe>';
    host.querySelector('iframe').src = url; document.body.appendChild(host);
    host.querySelector('button').addEventListener('click', () => host.remove());
    addEventListener('message', function m(e) { if (e.origin === location.origin && e.data && e.data.irdash === 'workbench-close') { host.remove(); removeEventListener('message', m); } });
  }
  addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    const host = document.querySelector('.host'); if (host) { host.remove(); return; }
    const w = $('cWatch'); if (w && w.classList.contains('on')) { closeWatch(); return; }
    if (parent !== window) parent.postMessage({ irdash: 'coach-close' }, location.origin);
  });

  async function load() {
    stage.innerHTML = '<div class="empty"><b>Reading the laps</b></div>';
    try { C = await (await fetch('/analysis/coach?id=' + encodeURIComponent(ID), { cache: 'no-store' })).json(); } catch (e) { C = null; }
    if (!C || C.error) { stage.innerHTML = '<div class="empty"><b>' + esc(C && C.error === 'Not while driving' ? 'Not while driving' : 'This session could not be read') + '</b><span>' + esc(ID) + '</span></div>'; return; }
    try { R = await (await fetch('/api/rec/for?id=' + encodeURIComponent(ID), { cache: 'no-store' })).json(); } catch (e) { R = null; }
    draw();
    if (P.get('watch') != null && C.focus && C.focus[+P.get('watch')]) watch(C.focus[+P.get('watch')]);   // tests and the deck: open WATCH straight away
  }
  window.Coach = { load, data: () => C, rec: () => R, video, watch, closeWatch };
  load();
})();
