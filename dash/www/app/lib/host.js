// A thin page host (W3-1): one old v2 page in a frame filling the shell's page area, until its door is rebuilt (REVIEW wave 4,
// RIG wave 5). The shell draws CLOSE. Esc pressed inside the frame (or inside a frame in it, like Sessions' nested Analysis) never
// reaches the shell's document, so every frame in here forwards it: postMessage({paddock:'esc'}) to the shell.
export function hostFrame(el, src, title) {
  const f = document.createElement('iframe');
  f.className = 'host'; f.title = title; f.src = src;
  const shell = window;
  const onKey = e => { if (e.key === 'Escape') shell.postMessage({ paddock: 'esc' }, location.origin); };
  const hook = w => {
    try {
      if (!w || w.__paddockEsc) return;
      w.__paddockEsc = true;
      w.addEventListener('keydown', onKey);
      const watch = doc => {
        doc.querySelectorAll('iframe').forEach(x => { x.addEventListener('load', () => hook(x.contentWindow)); hook(x.contentWindow); });
        new w.MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => {
          const list = n.tagName === 'IFRAME' ? [n] : n.querySelectorAll ? [...n.querySelectorAll('iframe')] : [];
          list.forEach(x => x.addEventListener('load', () => hook(x.contentWindow)));
        }))).observe(doc.documentElement, { childList: true, subtree: true });
      };
      if (w.document && w.document.documentElement) watch(w.document);
    } catch (e) { }                                 // another origin: nothing to hook
  };
  // every load (the page inside can go to another page): hook the new document
  f.addEventListener('load', () => hook(f.contentWindow));
  el.appendChild(f);
  return f;
}
