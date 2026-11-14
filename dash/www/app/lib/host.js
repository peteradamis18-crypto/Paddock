// A thin page host (W3-1): one old v2 page in a frame filling the shell's page area, until its door is rebuilt (REVIEW wave 4,
// RIG wave 5). The shell draws CLOSE. Esc pressed inside the frame (or inside a frame in it, like Sessions' nested Analysis) never
// reaches the shell's document, so every document in here forwards an Esc that nobody used: postMessage({paddock:'esc', token}).
// "Used" = the page called preventDefault() (Sessions going back from a lap, Analysis resetting its zoom, the video player,
// the Vault): then Esc stays inside the page. The token is this frame's, so the shell can tell a late Esc from a page that has gone.
export function hostFrame(el, src, title) {
  const f = document.createElement('iframe');
  const token = 'h' + Math.random().toString(36).slice(2);
  f.className = 'host'; f.title = title; f.src = src; f.dataset.token = token;
  const shell = window;
  // bubble phase on the frame's window, looked at after every listener has run (a page's own window listener may come later)
  const onKey = e => { if (e.key === 'Escape') setTimeout(() => { if (!e.defaultPrevented && f.isConnected) shell.postMessage({ paddock: 'esc', token }, location.origin); }, 0); };
  // per DOCUMENT, not per window: the first page in a frame can reuse the window of its blank start document
  const hook = w => {
    try {
      const doc = w && w.document;
      if (!doc || !doc.documentElement || doc.__paddockEsc) return;
      doc.__paddockEsc = true;
      w.addEventListener('keydown', onKey);
      const frame = x => { x.addEventListener('load', () => hook(x.contentWindow)); hook(x.contentWindow); };
      doc.querySelectorAll('iframe').forEach(frame);
      new w.MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => {
        (n.tagName === 'IFRAME' ? [n] : n.querySelectorAll ? [...n.querySelectorAll('iframe')] : []).forEach(frame);
      }))).observe(doc.documentElement, { childList: true, subtree: true });
    } catch (e) { }                                 // another origin: nothing to hook
  };
  // at every load (the page inside can go to another page), and while the first one loads (Esc can come before its load event)
  f.addEventListener('load', () => hook(f.contentWindow));
  el.appendChild(f);
  let tries = 0;
  const early = () => {
    if (!f.isConnected || ++tries > 100) return;
    const d = f.contentDocument;
    if (d && d.URL !== 'about:blank') { hook(f.contentWindow); if (d.readyState === 'complete') return; }
    setTimeout(early, 100);
  };
  early();
  return f;
}
