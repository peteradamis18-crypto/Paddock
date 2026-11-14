'use strict';
// Paddock's player for TALK OVER IT (W1-6). irdash (commentary.cs) opens this page full-screen on the middle race screen with
// ?id=<race>. It plays the race's cut with the game sound and records the microphone from the same tick as video.play().
// Sync: the recorder's "start" event gives t0, the video's first "playing" gives t1 and currentTime c1; D = (t1 - t0) / 1000 - c1 is
// how many seconds of voice came before the video's first frame (the mix trims them; a negative D delays the voice).
// STOP (the key, Esc, the deck or the page through /api/talk/state, the video's end): the recorder stops and the voice goes to
// POST /api/talk/voice with D, secs, mic and silent; irdash then closes this window.
// Tests: ?codec=<type> is the type canPlayType must accept (the rig's cut is HEVC), ?src=<url> the video.
const Q = new URLSearchParams(location.search), ID = Q.get('id') || '';
const CODEC = Q.get('codec') || 'video/mp4; codecs="hvc1.1.6.L153.B0"';
const SRC = Q.get('src') || '/api/library/video?id=' + encodeURIComponent(ID) + '&cut=1';
const SILENT_DB = -50, SILENT_MS = 5000;
const $ = id => document.getElementById(id);
const send = (url, opts) => (window.data && data.fetch ? data.fetch : fetch)(url, Object.assign({ cache: 'no-store' }, opts || {}));
const mmss = s => { s = Math.max(0, Math.floor(s)); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60; return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (x < 10 ? '0' : '') + x; };

const P = {
  stream: null, rec: null, chunks: [], t0: 0, t1: 0, c1: 0, mic: '', silent: false, quietSince: 0, talking: false, stopping: false,
  timers: [], ctx: null,
  // for the test (and the lead's live check): what was measured and sent
  out: { started: false, D: null, secs: 0, size: 0, posted: 0, mic: '', silent: false },

  say(main, sub, cls) {
    $('msgMain').textContent = main; $('msgSub').textContent = sub || '';
    $('msg').className = 'msg' + (cls ? ' ' + cls : ''); $('msg').hidden = false;
  },
  ev(name, extra) { return send('/api/talk/event?id=' + encodeURIComponent(ID) + '&ev=' + name + (extra || ''), { method: 'POST' }).catch(() => null); },

  async go() {
    const v = $('v');
    if (!ID) return this.say('No race was given to play');
    // the rig's cuts are HEVC: Chrome with the RTX 4080 plays them; a PC that cannot says so instead of showing black
    if (!v.canPlayType(CODEC)) { this.say("This PC cannot play the video in Paddock's player", 'Watch it with WATCH instead.', 'bad'); this.ev('cannotplay'); return; }
    try {
      // irdash starts the browser with --use-fake-ui-for-media-stream: no prompt, Windows' default recording device
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: true } });
    } catch (e) { this.stream = null; }
    const track = this.stream && this.stream.getAudioTracks()[0];
    if (!track) { this.say('No microphone found. Plug in the headset and press again.', '', 'bad'); this.ev('nomic'); return; }
    this.mic = track.label || 'Microphone';
    v.src = SRC;
    // both start only when the video can play at once, so D is a small number
    const ready = await new Promise(res => {
      if (v.readyState >= 3) return res(true);
      const t = setTimeout(() => res(false), 30000);
      v.addEventListener('canplay', () => { clearTimeout(t); res(true); }, { once: true });
      v.addEventListener('error', () => { clearTimeout(t); res(false); }, { once: true });
    });
    if (!ready) { this.say("This PC cannot play the video in Paddock's player", 'Watch it with WATCH instead.', 'bad'); this.ev('cannotplay'); this.end(); return; }
    let mime = 'audio/webm;codecs=opus'; if (!window.MediaRecorder || !MediaRecorder.isTypeSupported(mime)) mime = '';
    this.rec = mime ? new MediaRecorder(this.stream, { mimeType: mime }) : new MediaRecorder(this.stream);
    this.rec.ondataavailable = e => { if (e.data && e.data.size) this.chunks.push(e.data); };
    this.rec.onstart = () => { this.t0 = performance.now(); };
    v.addEventListener('playing', () => { if (!this.t1) { this.t1 = performance.now(); this.c1 = v.currentTime; } });
    v.addEventListener('ended', () => this.stop('ended'));
    // no pausing and no seeking while he talks (v1): the recording and the picture stay one timeline
    v.addEventListener('pause', () => { if (this.talking && !this.stopping && !v.ended) v.play().catch(() => { }); });
    // the same tick: the recorder and the video
    this.rec.start(1000);
    v.play().catch(() => { });
    this.talking = true;
    $('msg').hidden = true; $('bar').hidden = false; $('micName').textContent = this.mic;
    this.out.started = true; this.out.mic = this.mic;
    this.ev('started', '&mic=' + encodeURIComponent(this.mic));
    this.meter();
    this.timers.push(setInterval(() => this.clock(), 250));
    this.timers.push(setInterval(() => this.ask(), 1000));
  },

  clock() { if (this.t0) $('clock').textContent = 'Talking ' + mmss((performance.now() - this.t0) / 1000); },

  // the level: RMS of the microphone; under -50 dB for 5 s = "silent" (shown here and on the deck; the recording goes on)
  meter() {
    try {
      const AC = window.AudioContext || window.webkitAudioContext; this.ctx = new AC();
      const src = this.ctx.createMediaStreamSource(this.stream), an = this.ctx.createAnalyser(); an.fftSize = 2048; src.connect(an);
      const buf = new Float32Array(an.fftSize);
      this.timers.push(setInterval(() => {
        an.getFloatTimeDomainData(buf);
        let s = 0; for (let i = 0; i < buf.length; i++) s += buf[i] * buf[i];
        const db = 20 * Math.log10(Math.sqrt(s / buf.length) || 1e-9);
        $('level').style.width = Math.max(0, Math.min(100, (db + 60) * 100 / 60)).toFixed(0) + '%';
        const now = performance.now();
        if (db < SILENT_DB) { if (!this.quietSince) this.quietSince = now; } else this.quietSince = 0;
        const silent = !!this.quietSince && now - this.quietSince >= SILENT_MS;
        if (silent !== this.silent) {
          this.silent = silent; this.out.silent = this.out.silent || silent;
          $('warn').hidden = !silent; $('meter').classList.toggle('silent', silent);
          this.ev(silent ? 'silent' : 'loud');
        }
      }, 100));
    } catch (e) { }
  },

  // STOP pressed on the deck or the page: irdash says so here (asked once a second, only while talking)
  async ask() {
    if (!this.talking || this.stopping) return;
    try { const r = await fetch('/api/talk/state?id=' + encodeURIComponent(ID), { cache: 'no-store' }); const j = await r.json(); if (j.stop) this.stop('irdash'); } catch (e) { }
  },

  async stop(why) {
    if (!this.talking || this.stopping) return;
    this.stopping = true; this.talking = false;
    this.timers.forEach(t => clearInterval(t)); this.timers = [];
    const v = $('v'); try { v.pause(); } catch (e) { }
    $('bar').hidden = true; $('warn').hidden = true;
    this.say('Saving what you said…');
    await new Promise(res => { if (this.rec.state === 'inactive') return res(); this.rec.onstop = res; try { this.rec.stop(); } catch (e) { res(); } });
    const secs = this.t0 ? (performance.now() - this.t0) / 1000 : 0;
    const D = this.t1 && this.t0 ? (this.t1 - this.t0) / 1000 - this.c1 : 0;
    const blob = new Blob(this.chunks, { type: 'audio/webm' });
    this.end();
    Object.assign(this.out, { D, secs, size: blob.size });
    const url = '/api/talk/voice?id=' + encodeURIComponent(ID) + '&D=' + D.toFixed(3) + '&secs=' + secs.toFixed(1) + '&mic=' + encodeURIComponent(this.mic) + '&silent=' + (this.out.silent ? 1 : 0);
    let ok = false;
    for (let i = 0; i < 3 && !this.out.posted; i++) {      // a dropped connection is tried again; an answer is final
      try { const r = await send(url, { method: 'POST', body: blob, headers: { 'Content-Type': 'audio/webm' } }); this.out.posted = r.status; ok = r.ok; } catch (e) { await new Promise(r => setTimeout(r, 700)); }
    }
    if (ok) this.say('Mixing… you can close this', 'Your commentary is ready on the RACES page in a few seconds.', 'done');
    else this.say('What you said could not be saved', 'Press TALK OVER IT again.', 'bad');
  },

  end() {
    try { if (this.stream) this.stream.getTracks().forEach(t => t.stop()); } catch (e) { }
    try { if (this.ctx) this.ctx.close(); } catch (e) { }
  },
};
window.player = P;

document.addEventListener('keydown', e => {
  if (e.key === 'Escape') { e.preventDefault(); P.stop('esc'); return; }
  if (P.talking && (e.key === ' ' || e.key.indexOf('Arrow') === 0 || e.key === 'k' || e.key === 'j' || e.key === 'l')) e.preventDefault();   // no pause, no seek
});
$('stop').addEventListener('click', () => P.stop('key'));
$('v').addEventListener('contextmenu', e => e.preventDefault());
P.go();
