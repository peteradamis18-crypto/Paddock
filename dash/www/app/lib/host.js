// A thin page host (W3-1): one old v2 page in a frame filling the shell's page area, until its door is rebuilt (REVIEW wave 4,
// RIG wave 5). The shell draws CLOSE. Esc pressed inside the frame (or inside a frame in it, like Sessions' nested Analysis) never
// reaches the shell's document, so every document in here forwards it: postMessage({paddock:'esc'}) to the shell.
export function hostFrame(el, src, title) {
  const f = document.createElement('iframe');
  f.className = 'host'; f.title = title; f.src = src;
  const shell = window;
  const onKey = e => { if (e.key === 'Escape') shell.postMessage({ paddock: 'esc' }, location.origin); };
  // per DOCUMENT, not per window: the first page in a frame can reuse the window of its blank start document
  const hook = w => {
    try {
      const doc = w && w.document;
      if (!doc || !doc.documentElement || doc.__paddockEsc) return;
      doc.__paddockEsc = true;
      doc.addEventListener('keydown', onKey);
      const frame = x => { x.addEventListener('load', () => hook(x.contentWindow)); hook(x.contentWindow); };
      doc.querySelectorAll('iframe').forEach(frame);
      new w.MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => {
        (n.tagName === 'IFRAME' ? [n] : n.querySelectorAll ? [...n.querySelectorAll('iframe')] : []).forEach(frame);
      }))).observe(doc.documentElement, { childList: true, subtree: true });
    } catch (e) { }                                 // another origin: nothing to hook
  };
  // as soon as the page inside has its document (and again at every load: it can go to another page)
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
