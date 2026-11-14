// HOME placeholder (W3-1): the shell runs on its own until W3-3's HOME replaces this file (merge order: W3-1 first).
let root = null;
export default {
  name: 'home', title: 'HOME',
  mount(el) {
    root = document.createElement('div');
    root.className = 'shell-msg';
    root.innerHTML = '<span class="t-title">HOME is being rebuilt</span>';
    el.appendChild(root);
  },
  unmount() { root = null; },
};
