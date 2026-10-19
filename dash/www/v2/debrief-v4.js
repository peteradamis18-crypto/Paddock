'use strict';
// D-03 debrief screen (docs\cards\v4\D-03.md, wireframe docs\SPEC-v4.md 3a). The signature "straight after a session"
// top screen: his race result, his position lap by lap, his pace against the field and the three corners that cost the
// most time, with looping video pairs. Every value comes from GET /debrief (dash\src\debrief.cs, D-01/D-02); nothing is
// invented here and an unavailable value collapses under docs\COPY-RULES.md. This file replaces the old debrief.js
// auto-show trigger (that file stays for its demo and the Session Review hand-off). No controls on screen yet: the
// y=940-1080 action band is reserved until D-04 wires it, so D-03 ships no dead buttons.
//   Debrief4.onSessionEnd()  fetch /debrief?id=last and put the screen up (called on the live -> gone transition)
//   Debrief4.show(json)      render a /debrief reply (the test uses this with a real fixture)
//   Debrief4.boxes/overlaps  the text-box test hooks (tests\debrief-test.ps1)
const Debrief4 = (function () {
  const W = 1920, H = 1080;
  const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'], MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  const isN = x => typeof x === 'number' && isFinite(x);
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  function fmt(t) { if (!isN(t)) return '–'; const m = Math.floor(t / 60), s = t - m * 60; return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3); }
  function sec(t, d) { return isN(t) ? t.toFixed(d == null ? 1 : d) : ''; }
  function sgn(x, d) { d = d == null ? 0 : d; const s = Math.abs(x).toFixed(d); return (parseFloat(s) === 0 ? '' : x > 0 ? '+' : '−') + s; }
  function word(ms) { if (!ms) return ''; const dt = new Date(ms); if (isNaN(dt)) return ''; return DAYS[dt.getDay()] + ' ' + dt.getDate() + ' ' + MONTHS[dt.getMonth()]; }
  function clock(ms) { if (!ms) return ''; const dt = new Date(ms); if (isNaN(dt)) return ''; const h = dt.getHours(), m = dt.getMinutes(); return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m; }
  const SP = s => '<span>' + esc(s) + '</span>';

  // ---- header (0-110) ----
  function header(j) {
    const m = j.meta || {};
    const sess = [String(m.type || '').toUpperCase(), m.track, m.config].filter(Boolean).join(' · ');
    const laps = j.race && j.result ? j.result.totalLaps : (j.practice ? j.practice.n : 0);
    const cond = [word(m.startMs), clock(m.startMs), laps ? laps + (laps === 1 ? ' lap' : ' laps') : ''].filter(Boolean).join(' · ');
    return '<header class="db4-head" id="db4Head">' +
      (m.number || m.driver || m.team ? '<div class="db4-id">' + (m.number ? '<span class="db4-num">' + esc(m.number) + '</span>' : '') + (m.driver ? '<b>' + esc(m.driver) + '</b>' : '') + (m.team ? SP('· ' + m.team) : '') + '</div>' : '') +
      '<div class="db4-sess">' + esc(sess) + '</div>' +
      (cond ? '<div class="db4-cond">' + esc(cond) + '</div>' : '') +
      '</header>';
  }
  function row(k, v) { return '<div class="r-row">' + SP(k) + '<b> ' + esc(v) + '</b></div>'; }

  // ---- RESULT ----
  function resultCol(j) {
    const r = j.result || {};
    const out = [];
    if (isN(r.finishPosition) && r.finishPosition > 0) {
      let sub = '';
      if (isN(r.startPosition) && r.startPosition > 0) sub = ' · start P' + r.startPosition + (isN(r.positionsGained) && r.positionsGained !== 0 ? ' ' + sgn(r.positionsGained) : '');
      out.push('<div class="r-big">' + SP('P' + r.finishPosition) + '<span class="r-sub">' + esc(sub) + '</span></div>');
    }
    if (isN(r.iratingChange)) out.push(row('iRating', sgn(r.iratingChange)));
    if (isN(r.gapToWinner)) out.push(row('gap to winner', sec(r.gapToWinner) + ' s'));
    if (isN(r.incidents)) out.push(row('incidents', r.incidents + 'x'));
    if (isN(r.cleanLaps) && isN(r.totalLaps)) out.push(row('clean laps', r.cleanLaps + ' / ' + r.totalLaps));
    if (!out.length) return '';
    return '<section class="db4-col db4-result" id="db4Result"><h3 class="lab">RESULT</h3>' + out.join('') + '</section>';
  }

  // ---- POSITION BY LAP ----
  function posChart(pbl) {
    const pts = (pbl || []).filter(p => isN(p.position) && p.position > 0);
    if (pts.length < 5) return null;
    const CW = 544, CH = 214, pad = 34;
    const maxPos = Math.max.apply(null, pts.map(p => p.position));
    const lo = maxPos < 2 ? 2 : maxPos;
    const x = i => pad + (pts.length === 1 ? 0 : i * (CW - 2 * pad) / (pts.length - 1));
    const y = p => pad + (p - 1) / (lo - 1) * (CH - 2 * pad);
    let s = '';
    for (let p = 1; p <= lo; p += (p === 1 ? 4 : 5)) {
      s += '<line x1="' + pad + '" x2="' + (CW - pad) + '" y1="' + y(p).toFixed(1) + '" y2="' + y(p).toFixed(1) + '" stroke="#26262a" stroke-width="1"/>' +
        '<text x="2" y="' + (y(p) + 5).toFixed(1) + '" font-size="14" fill="#5d5a54">P' + p + '</text>';
    }
    s += '<polyline points="' + pts.map((p, i) => x(i).toFixed(1) + ',' + y(p.position).toFixed(1)).join(' ') + '" fill="none" stroke="#f2c230" stroke-width="3"/>';
    pts.forEach((p, i) => {
      if (p.pitStop) s += '<path d="M' + (x(i) - 6).toFixed(1) + ' ' + (y(p.position) + 12).toFixed(1) + ' L' + (x(i) + 6).toFixed(1) + ' ' + (y(p.position) + 12).toFixed(1) + ' L' + x(i).toFixed(1) + ' ' + (y(p.position) + 22).toFixed(1) + ' Z" fill="#8b877d"/>';
      if (isN(p.pass) && p.pass > 0) s += '<circle cx="' + x(i).toFixed(1) + '" cy="' + y(p.position).toFixed(1) + '" r="8" fill="none" stroke="#3ccf7e" stroke-width="2"/>';
      s += '<circle cx="' + x(i).toFixed(1) + '" cy="' + y(p.position).toFixed(1) + '" r="4" fill="#f2c230"/>';
    });
    return '<section class="db4-col db4-pos" id="db4Pos"><h3 class="lab">POSITION BY LAP</h3>' +
      '<svg class="db4-chart" viewBox="0 0 ' + CW + ' ' + CH + '" preserveAspectRatio="none">' + s + '</svg></section>';
  }

  // ---- PACE VS FIELD ----
  function pRow(k, v, cls) { return '<div class="p-row' + (cls ? ' ' + cls : '') + '"><span class="k">' + esc(k) + '</span><span class="v">' + esc(v) + '</span></div>'; }
  function paceCol(j) {
    const p = j.pace || {};
    const rows = [];
    if (isN(p.hisBest)) rows.push(pRow('his best', fmt(p.hisBest), 'best'));
    if (isN(p.classBest)) rows.push(pRow('class best', fmt(p.classBest)));
    if (isN(p.hisMedian)) rows.push(pRow('his median', fmt(p.hisMedian)));
    if (isN(p.classMedian)) rows.push(pRow('field median' + (isN(p.n) ? ' (n=' + p.n + ')' : ''), fmt(p.classMedian)));
    if (isN(p.top5)) rows.push(pRow('top 5 %', fmt(p.top5)));
    if (!rows.length) return '';
    return '<section class="db4-col db4-pace" id="db4Pace"><h3 class="lab">PACE VS FIELD</h3>' + rows.join('') + '</section>';
  }
  function practiceCol(j) {
    const p = j.practice || {};
    const rows = [];
    if (isN(p.best)) rows.push(pRow('best lap', fmt(p.best), 'best'));
    if (isN(p.pb)) rows.push(pRow('personal best', fmt(p.pb)));
    if (isN(p.optimal)) rows.push(pRow('optimal', fmt(p.optimal)));
    if (isN(p.median)) rows.push(pRow('median', fmt(p.median)));
    if (isN(p.n)) rows.push(pRow('laps', String(p.n)));
    if (!rows.length) return '';
    return '<section class="db4-col db4-pace" id="db4Pace"><h3 class="lab">PACE</h3>' + rows.join('') + '</section>';
  }

  // ---- WHERE THE TIME WENT (410-850): the three greatest losses, with looping video pairs ----
  function cornerCard(c) {
    return '<div class="db4-card">' +
      '<div class="c-head">' + SP(c.label || ('T' + c.n)) + '<span class="c-loss">−' + sec(c.loss, 2) + ' s</span></div>' +
      '</div>';
  }
  function cornersBand(j) {
    const cs = (j.corners || []).slice(0, 3);
    if (!cs.length) return '';
    return '<section class="db4-corners" id="db4Corners"><h3 class="lab">WHERE THE TIME WENT</h3>' +
      '<div class="db4-cards">' + cs.map(cornerCard).join('') + '</div></section>';
  }

  // ---- INCIDENTS (850-940): real recorder incidents, each with a one-press 30 s clip ----
  function incidentRow(r) {
    const bits = [];
    if (isN(r.lap) && r.lap > 0) bits.push('lap ' + r.lap);
    if (r.corner) bits.push(esc(r.corner));
    if (r.type) bits.push(esc(r.type));
    if (r.status === 'gap') bits.push('no video: recording gap');     // honest: the recording has a hole there
    const btn = r.videoId ? '<button class="db4-iplay" data-vid="' + esc(r.videoId) + '">\u25b6 30 s</button>' : '';
    return '<div class="i-row">' + SP(bits.join(' · ')) + btn + '</div>';
  }
  function incidentsBand(j) {
    const rows = (j.incidents || []).filter(r => (isN(r.lap) && r.lap > 0) || r.status === 'gap');
    if (!rows.length) return '';
    return '<section class="db4-inc" id="db4Incidents"><h3 class="lab">INCIDENTS</h3>' +
      '<div class="i-rows">' + rows.map(incidentRow).join('') + '</div></section>';
  }

  // ---- the one-press bar (940-1080): SAVE / SHARE / OPEN IN COSWORTH / DEEP DIVE ----
  function actionsBand(j) {
    const b = j.bar || {};
    const btns = [];
    if (b.recId) btns.push('<button class="db4-act" id="db4Save" data-id="' + esc(b.recId) + '"' + (b.saved ? ' data-saved="1"' : '') + '>' + (b.saved ? 'SAVED' : 'SAVE') + '</button>');
    if (b.shareId) btns.push('<button class="db4-act" id="db4Share" data-id="' + esc(b.shareId) + '">SHARE</button>');
    btns.push('<button class="db4-act" id="db4Cos" hidden>OPEN IN COSWORTH</button>');
    if (b.deepDive && b.deepDive.id && b.deepDive.cornerN > 0) btns.push('<button class="db4-act" id="db4Deep">DEEP DIVE</button>');
    return '<div class="db4-acts" id="db4Actions"><div class="db4-btns" id="db4Btns">' + btns.join('') + '</div></div>';
  }

  function stage(j) {
    let inner;
    if (j.race) inner = resultCol(j) + (posChart(j.positionByLap) || '') + paceCol(j);
    else inner = practiceCol(j);
    const st = document.createElement('div'); st.className = 'db4-stage';
    st.innerHTML = header(j) + '<div class="db4-cols" id="db4Cols">' + inner + '</div>' +
      cornersBand(j) + incidentsBand(j) + actionsBand(j);
    return st;
  }

  // ---- the one-press bar: SAVE, SHARE, OPEN IN COSWORTH, DEEP DIVE (D-04) ----
  function setState(btn, text) { if (btn) btn.textContent = text; }

  // SAVE: /api/rec/save?id=<session id>; the button only says SAVED when the reply says SAVED (a repeat press is a no-op)
  function save(recId) {
    const btn = document.getElementById('db4Save');
    const id = recId || (btn && btn.getAttribute('data-id'));
    if (!id) return Promise.resolve('NONE');
    setState(btn, 'SAVING');
    return fetch('/api/rec/save?id=' + encodeURIComponent(id), { cache: 'no-store' })
      .then(r => r.ok ? r.json() : null)
      .then(o => { const st = o && o.state === 'SAVED' ? 'SAVED' : 'SAVE'; setState(btn, st); return st; })
      .catch(() => { setState(btn, 'SAVE'); return 'SAVE'; });
  }

  function shareLabel(o) {
    if (!o) return 'SHARE';
    if (o.state === 'making') return 'MAKING ' + (o.pct || 0) + ' %';
    if (o.state === 'queued') return 'QUEUED';
    if (o.state === 'waiting') return 'WAITING';
    if (o.state === 'done') return 'READY';
    return 'SHARE';
  }
  // ref and stripe are optional on this route; send their explicit defaults.
  function share(shareId) {
    const btn = document.getElementById('db4Share');
    const id = shareId || (btn && btn.getAttribute('data-id'));
    if (!id) return Promise.resolve('NONE');
    setState(btn, 'SHARING');
    return fetch('/share/make?id=' + encodeURIComponent(id) + '&ref=&stripe=0', { cache: 'no-store' })
      .then(r => r.ok ? r.json() : null)
      .then(o => { const st = shareLabel(o); setState(btn, st); return o && o.state ? o.state : 'error'; })
      .catch(() => { setState(btn, 'SHARE'); return 'error'; });
  }

  // COSWORTH shows only when /vault/list says Pi Toolbox is installed
  function setCosworth(on) { const c = document.getElementById('db4Cos'); if (c) c.hidden = !on; }
  function applyVaultList(v) { setCosworth(!!(v && v.cosworth && v.cosworth.installed)); }

  function deepDiveUrl(j) {
    const dd = (j && j.bar && j.bar.deepDive) || {};
    if (!dd.id || !(dd.lap > 0) || !(dd.cornerN > 0)) return '';
    return 'workbench.html?id=' + encodeURIComponent(dd.id) + '&lap=' + dd.lap + '&page=driver&corner=' + encodeURIComponent(dd.cornerN);
  }
  // DEEP DIVE: pass the corner number so the Workbench opens at this corner's apex.
  function openDeepDive(root, j) {
    const url = deepDiveUrl(j); if (!url || document.getElementById('db4WbHost')) return;
    const host = document.createElement('div'); host.id = 'db4WbHost'; host.className = 'db4-wbhost';
    host.innerHTML = '<div class="db4-wbback" id="db4WbBack">\u2039 Back</div><iframe title="Paddock Analysis"></iframe>';
    host.querySelector('iframe').src = url;
    document.body.appendChild(host);
    requestAnimationFrame(() => host.classList.add('on'));
    host.querySelector('#db4WbBack').addEventListener('click', e => { e.stopPropagation(); host.remove(); });
  }

  // the incident clip player (one press on ▶ 30 s)
  function playIncident(vid) {
    if (!vid) return;
    let ov = document.getElementById('db4Player');
    if (!ov) {
      ov = document.createElement('div'); ov.id = 'db4Player'; ov.className = 'db4-player';
      ov.innerHTML = '<video playsinline controls autoplay></video>';
      ov.addEventListener('click', e => { e.stopPropagation(); if (e.target === ov) closePlayer(); });
      document.body.appendChild(ov);
      requestAnimationFrame(() => ov.classList.add('on'));
    }
    const v = ov.querySelector('video');
    // the clip has the game's sound: his own press on ▶ starts it, at the volume he left (same setting as the Vault player)
    if (!v._snd) {
      v._snd = true;
      try { const p = JSON.parse(localStorage.getItem('paddock.sound') || 'null'); if (p) { v.volume = Math.max(0, Math.min(1, +p.v || 0)); v.muted = !!p.m; } } catch (e) { }
      v.addEventListener('volumechange', () => { if (v._auto) { v._auto = false; return; } try { localStorage.setItem('paddock.sound', JSON.stringify({ v: v.volume, m: v.muted })); } catch (e) { } });
    }
    v.src = '/debrief/video?id=' + encodeURIComponent(vid);
    const pr = v.play(); if (pr && pr.catch) pr.catch(() => { if (v.muted) return; v._auto = true; v.muted = true; const p2 = v.play(); if (p2 && p2.catch) p2.catch(() => { }); });   // a browser that refuses sound still shows the picture (his setting is not changed)
  }
  function closePlayer() { const ov = document.getElementById('db4Player'); if (!ov) return; ov.classList.remove('on'); try { ov.querySelector('video').pause(); } catch (e) { } setTimeout(() => ov.remove(), 250); }

  function wireBar(root, j) {
    root.addEventListener('click', e => {
      const t = e.target;
      if (t.closest && t.closest('.db4-iplay')) { e.stopPropagation(); playIncident(t.getAttribute('data-vid')); return; }
      if (t.id === 'db4Save') { e.stopPropagation(); save(); return; }
      if (t.id === 'db4Share') { e.stopPropagation(); share(); return; }
      if (t.id === 'db4Cos') {
        e.stopPropagation();
        const dd = (j.bar && j.bar.deepDive) || {};
        if (t._busy) return;       // no double launch while Pi is opening
        if (dd.id) {
          t._busy = true; const was = t.textContent; t.textContent = 'OPENING';
          const say = (m) => { t.textContent = m; setTimeout(() => { t.textContent = was; t._busy = false; }, 4000); };
          fetch('/vault/open?how=cosworth&id=' + encodeURIComponent(dd.id), { cache: 'no-store' }).then(r => say(r.status === 409 ? 'NOT WHILE DRIVING' : r.status === 404 ? 'FILE IS GONE' : r.ok ? 'OPENING IN PI' : 'COULD NOT OPEN')).catch(() => say('COULD NOT OPEN'));
        }
        return;
      }
      if (t.id === 'db4Deep') { e.stopPropagation(); openDeepDive(root, j); return; }
    });
    if (document.getElementById('db4Cos')) fetch('/vault/list', { cache: 'no-store' }).then(r => r.ok ? r.json() : null).then(applyVaultList).catch(() => { });
  }

  // ---- mounting ----
  let el = null, timer = null, activeTimer = null, lastLive = false, busy = false, navSeq = -1;
  function active(open) {
    const j = window.__deb4Last;
    if (!j || !j.id) return;
    fetch('/debrief/active?id=' + encodeURIComponent(j.id) + '&open=' + (open ? '1' : '0'), { cache: 'no-store' }).catch(() => {});
  }
  function fit() {
    const st = el && el.querySelector('.db4-stage'); if (!st) return;
    const w = window.innerWidth, h = window.innerHeight, s = Math.min(w / W, h / H);
    st.style.transform = 'translate(' + ((w - W * s) / 2).toFixed(1) + 'px,' + ((h - H * s) / 2).toFixed(1) + 'px) scale(' + s.toFixed(5) + ')';
  }
  function show(j) {
    hide();
    if (typeof PageHost !== 'undefined') PageHost.closeOthers('db4', true);   // one page at a time over the dashboard
    window.__deb4Last = j;
    const root = document.createElement('div'); root.id = 'debrief4'; root.className = 'db4';
    root.appendChild(stage(j));
    root.addEventListener('click', e => { const t = e.target; if (t.closest && (t.closest('button') || t.closest('.db4-player'))) return; hide(); });
    document.body.appendChild(root);
    el = root;
    fit();
    root._db4r = () => fit(); window.addEventListener('resize', root._db4r);
    requestAnimationFrame(() => root.classList.add('on'));
    timer = setTimeout(hide, 15 * 60 * 1000);
    active(true); clearInterval(activeTimer); activeTimer = setInterval(() => { if (el) active(true); }, 5000);
    wireBar(root, j);
  }
  // After a session the Coach is the screen (coach.html: what to fix, his video, all the data one press away). The old
  // debrief stays the fallback when the reply names no telemetry file. Same lease and heartbeat, so the deck keys
  // (SAVE, SHARE, COSWORTH, DEEP DIVE) keep acting on this session.
  function coachId(j) { return (j && j.bar && j.bar.deepDive && j.bar.deepDive.id) || (j && j.meta && j.meta.file) || ''; }
  function showCoach(j) {
    const id = coachId(j); if (!id) { show(j); return; }
    hide();
    if (typeof PageHost !== 'undefined') PageHost.closeOthers('db4', true);   // one page at a time over the dashboard
    window.__deb4Last = j;
    const root = document.createElement('div'); root.id = 'debrief4'; root.className = 'db4 pg-host db4-coach'; root.style.zIndex = 949;
    const f = document.createElement('iframe'); f.src = 'coach.html?id=' + encodeURIComponent(id) + (j.race ? '&race=' + encodeURIComponent(j.id) : ''); f.title = 'Coach';
    const b = document.createElement('button'); b.type = 'button'; b.className = 'pg-close'; b.textContent = 'Close';
    b.addEventListener('click', e => { e.stopPropagation(); hide(); });
    root.appendChild(f); root.appendChild(b); document.body.appendChild(root);
    el = root;
    requestAnimationFrame(() => root.classList.add('on'));
    armKeeper(root);
    timer = setTimeout(hide, 15 * 60 * 1000);
    active(true); clearInterval(activeTimer); activeTimer = setInterval(() => { if (el) active(true); }, 5000);
  }
  // The calm 'laps saved' strip after a session (the keeper review: KEEP ALL by itself after 60 s, CHOOSE opens the Vault).
  // The old debrief carried it (debrief.js armReview); when the coach became the after-session screen nothing armed it any more,
  // so the server's 60 s keep-all never started and nobody could CHOOSE (found 2026-10-18 by review-test). The server owns the
  // timer (a wheel button does the same); this only starts it (?open=1) and shows it.
  let keepToken = null;
  function armKeeper(root) {
    if (typeof UI !== 'undefined' && UI.live && UI.live() && typeof L !== 'undefined' && L.v && L.v.IsOnTrack) return;   // never while he drives
    const token = {}; keepToken = token; let opened = false;
    const pull = async () => {
      if (keepToken !== token || el !== root) return;
      let r; try { r = await (await fetch('/vault/review' + (opened ? '' : '?open=1'), { cache: 'no-store' })).json(); } catch (e) { setTimeout(pull, 600); return; }
      opened = true;
      if (keepToken !== token || el !== root) return;
      let box = root.querySelector('#db4Keep');
      if (!r || r.enabled === false || r.driving || (!r.up && !r.kept && !r.pending)) { if (box) box.remove(); return; }
      if (!box) {
        box = document.createElement('div'); box.id = 'db4Keep';
        box.innerHTML = '<p><span class="line"></span><span class="sub"></span></p><button type="button" class="def" id="db4KeepAll">KEEP ALL</button><button type="button" id="db4Choose">CHOOSE</button>';
        box.querySelector('#db4KeepAll').addEventListener('click', e => { e.stopPropagation(); fetch('/api/do?c=vkkeepall', { cache: 'no-store' }).catch(() => { }); });
        box.querySelector('#db4Choose').addEventListener('click', e => {
          e.stopPropagation(); fetch('/api/do?c=vkchoose', { cache: 'no-store' }).catch(() => { });
          hide(); if (typeof VaultLive !== 'undefined' && VaultLive.openPage) VaultLive.openPage(true);     // const VaultLive is not window.VaultLive
        });
        root.appendChild(box);
      }
      const line = box.querySelector('.line'), sub = box.querySelector('.sub'), keep = box.querySelector('#db4KeepAll'), choose = box.querySelector('#db4Choose');
      box.setAttribute('data-default', String(r.defaultMs || 60000)); box.setAttribute('data-wait', String(r.waitMs || 60000));
      if (r.kept) { line.textContent = r.line || 'Kept'; sub.textContent = 'Kept'; keep.hidden = true; choose.hidden = true; }
      else {
        line.textContent = r.n > 0 ? r.line : 'Checking laps';
        const left = Math.max(0, Math.ceil((r.leftMs || 0) / 1000));
        sub.textContent = (r.pending && left === 0) ? 'Saving' : ('Keeping all in ' + left + ' s'); keep.hidden = false; choose.hidden = false;
      }
      if (!r.kept) setTimeout(pull, 400);
    };
    pull();
  }
  window.addEventListener('message', e => { if (e.origin === location.origin && e.data && e.data.irdash === 'coach-close' && el && el.classList.contains('db4-coach')) hide(); });
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && el && el.classList.contains('db4-coach')) hide(); });

  function hide() {
    clearTimeout(timer); timer = null;
    clearInterval(activeTimer); activeTimer = null; if (el) active(false);
    try { closePlayer(); const wb = document.getElementById('db4WbHost'); if (wb) wb.remove(); } catch (e) { }
    keepToken = null;
    const old = el; el = null;
    if (!old) return;
    if (old._db4r) window.removeEventListener('resize', old._db4r);
    old.classList.remove('on');
    setTimeout(() => old.remove(), 600);
  }
  function src() {
    try { const p = new URLSearchParams(location.search); if (p.get('debrief4')) return p.get('debrief4'); } catch (e) { }
    if (window.__debrief4Src) return window.__debrief4Src;
    return '/debrief?id=last';
  }
  // the code the trigger runs: fetch the reply and put the screen up. Returns true when the screen is up.
  function load(id) {
    if (busy) return Promise.resolve(false);
    busy = true;
    const url = id ? '/debrief?id=' + encodeURIComponent(id) : src();
    return fetch(url, { cache: 'no-store' }).then(r => r.ok ? r.json() : null).then(j => {
      busy = false;
      if (!j || j.error || j.ok !== true) return false;
      show(j);
      return true;
    }).catch(() => { busy = false; return false; });
  }

  // ---- test hooks: every visible text box and every pair that overlaps (should be none) ----
  function boxes(root) {
    const out = [], all = (root || document).querySelectorAll('.db4-stage *');
    for (let i = 0; i < all.length; i++) {
      const e = all[i];
      if (e.tagName === 'STYLE' || e.tagName === 'SCRIPT' || e.tagName === 'VIDEO') continue;
      if (e.children.length || !e.textContent.trim()) continue;                 // leaf text nodes only, like SessionReview
      const rg = document.createRange(); rg.selectNodeContents(e); const t = rg.getBoundingClientRect();
      if (t.width > 0 && t.height > 0) out.push({ x: t.left, y: t.top, w: t.width, h: t.height, s: e.textContent.trim().substring(0, 40) });
    }
    return out;
  }
  function overlaps(root) {
    const b = boxes(root), bad = [];
    for (let i = 0; i < b.length; i++) for (let j = i + 1; j < b.length; j++) {
      const p = b[i], q = b[j];
      if (p.x + 1 < q.x + q.w - 1 && q.x + 1 < p.x + p.w - 1 && p.y + 1 < q.y + q.h - 1 && q.y + 1 < p.y + p.h - 1) bad.push(p.s + ' | ' + q.s);
    }
    return { boxes: b.length, bad: bad };
  }
  function bands() {
    const r = {};
    ['db4Head', 'db4Cols', 'db4Corners', 'db4Incidents', 'db4Actions', 'db4Result', 'db4Pos', 'db4Pace'].forEach(id => {
      const e = document.getElementById(id); if (!e || e.hidden) return;
      const b = e.getBoundingClientRect();
      r[id] = { l: b.left, t: b.top, r: b.right, b: b.bottom, w: b.width, h: b.height };
    });
    return r;
  }

  // After leaving the car: the review of THAT session. While driving we remember iRacing's session identity and the
  // laps completed; afterwards "last" is asked every 4 s for up to 90 s (the telemetry file may still be finishing) and
  // a reply about any other session is thrown away. Getting back in the car cancels it. No lap completed is still a drive: the coach
  // then shows what it held and ALL THE DATA (Peter 2026-10-18: a qualifying run with no full lap showed nothing).
  let seen = null, wait = null;
  function remember() {
    try {
      const v = (typeof L !== 'undefined' && L.v) || {};
      if (isN(v.SessionUniqueID) && v.SessionUniqueID > 0) seen = { uid: v.SessionUniqueID, snum: v.SessionNum, laps: isN(v.LapCompleted) ? v.LapCompleted : null };
    } catch (e) { }
  }
  function matches(j, want) {
    if (!want || !isN(want.uid)) return true;                       // no live identity (old frames, tests): accept as before
    const s = j && j.session;
    return !!(s && s.uniqueId === want.uid && s.sessionNum === want.snum);
  }
  function awaitReview(want) {
    clearTimeout(wait && wait.t);
    const until = Date.now() + 90000;
    wait = { want, t: 0 };
    const tick = () => {
      if (!wait || wait.want !== want) return;
      let live = false; try { live = UI.live(); } catch (e) { }
      if (live || Date.now() > until) { wait = null; return; }
      fetch(src(), { cache: 'no-store' }).then(r => r.ok ? r.json() : null).then(j => {
        if (!wait || wait.want !== want) return;
        try { if (UI.live()) { wait = null; return; } } catch (e) { }
        if (j && j.ok === true && !j.error && matches(j, want)) { wait = null; showCoach(j); return; }   // the coach for the session that ended
        wait.t = setTimeout(tick, 4000);
      }).catch(() => { if (wait && wait.want === want) wait.t = setTimeout(tick, 4000); });
    };
    tick();
  }

  function init() {
    // The old debrief.js trigger is off (D-03): this file owns the after-session screen. The signal is the same one
    // core.js feeds every frame: the dashboard was live and now it is not.
    setInterval(() => {
      if (typeof Conn !== 'undefined' && Conn.status === 'noserver') { lastLive = false; return; }
      let live = false; try { live = UI.live(); } catch (e) { }
      if (live) { remember(); if (wait) { clearTimeout(wait.t); wait = null; } }
      if (lastLive && !live) {
        const want = seen; seen = null;
        awaitReview(want);
      }
      lastLive = live;
    }, 1000);
    // D-05: the deck's DEEP DIVE key asks irdash for it; while this screen is up, open the Workbench on the corner
    setInterval(() => { if (el) pollNav(); else navSeq = -1; }, 1200);
    try { if (new URLSearchParams(location.search).get('debrief4')) load(); } catch (e) { }
  }

  // D-05: irdash (/debrief/nav) says when the deck's DEEP DIVE key was pressed; open the Workbench once per request
  async function pollNav() {
    let n; try { n = await (await fetch('/debrief/nav', { cache: 'no-store' })).json(); } catch (e) { return; }
    if (n && n.go && n.seq !== navSeq) { navSeq = n.seq; openDeepDive(el, window.__deb4Last); }
  }

  return { show: show, showCoach: showCoach, hide: hide, load: load, onSessionEnd: load, init: init, matches: matches, awaitReview: awaitReview, waiting: function () { return !!wait; }, boxes: boxes, overlaps: overlaps, bands: bands, root: function () { return el; },
    // D-04: the one-press bar and the incident player (also the test hooks)
    save: save, share: share, setCosworth: setCosworth, applyVaultList: applyVaultList, deepDiveUrl: deepDiveUrl, openDeepDive: openDeepDive,
    playIncident: playIncident, closePlayer: closePlayer,
    playerSrc: function () { const v = document.querySelector('#db4Player video'); return v ? v.getAttribute('src') : ''; },
    incidents: function () { const rows = document.querySelectorAll('#db4Incidents .i-row'); return Array.prototype.map.call(rows, function (r) { return r.textContent.trim(); }); } };
})();
Debrief4.init();
