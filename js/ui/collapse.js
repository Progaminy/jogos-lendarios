(() => {
  'use strict';

  function injectStyle() {
    if (document.getElementById('jlCollapseStyle')) return;
    const style = document.createElement('style');
    style.id = 'jlCollapseStyle';
    style.textContent = [
      '.jl-collapsible{min-width:0}',
      '.jl-collapse-body[hidden]{display:none!important}',
      '.jl-collapse-toggle{flex:0 0 auto;min-width:88px}',
      '.jl-collapse-toggle.jl-symbol-toggle{min-width:38px;width:38px;height:34px;padding:0;font-size:1.15rem;line-height:1}',
      '.jl-collapse-actions{display:flex;align-items:center;justify-content:flex-end;gap:8px;flex-wrap:wrap}',
      '.jl-collapsible.is-collapsed{box-shadow:0 10px 28px rgba(0,0,0,.18)}',
      '.jl-collapsible.is-collapsed>.section-head,.jl-collapsible.is-collapsed>.jl-social-head{margin-bottom:0}',
      '@media(max-width:600px){.jl-collapse-toggle{min-width:82px;padding:7px 10px}.jl-collapse-toggle.jl-symbol-toggle{min-width:38px;width:38px;height:34px;padding:0}.jl-collapse-actions{width:100%;justify-content:space-between}.jl-collapsible>.section-head,.jl-collapsible>.jl-social-head{align-items:flex-start;flex-wrap:wrap}}'
    ].join('');
    document.head.appendChild(style);
  }

  function mount(panel) {
    if (!panel || panel.dataset.collapseReady === '1') return;
    const toggle = panel.querySelector('.jl-collapse-toggle');
    const body = panel.querySelector('.jl-collapse-body');
    if (!toggle || !body) return;

    panel.dataset.collapseReady = '1';

    const setCollapsed = (collapsed) => {
      body.hidden = collapsed;
      panel.classList.toggle('is-collapsed', collapsed);
      toggle.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
      const symbolOnly = toggle.classList.contains('jl-symbol-toggle');
      toggle.textContent = symbolOnly ? (collapsed ? '⌄' : '⌃') : (collapsed ? 'Expandir' : 'Recolher');
      toggle.setAttribute('aria-label', collapsed ? 'Expandir' : 'Recolher');
    };

    toggle.addEventListener('click', () => setCollapsed(!body.hidden));
    setCollapsed(panel.dataset.collapseDefault !== 'open');
  }

  function scan(root) {
    if (!root) return;
    if (root.matches && root.matches('.jl-collapsible')) mount(root);
    if (root.querySelectorAll) root.querySelectorAll('.jl-collapsible').forEach(mount);
  }

  function init() {
    injectStyle();
    scan(document);
    const observer = new MutationObserver((mutations) => {
      mutations.forEach((mutation) => mutation.addedNodes.forEach((node) => {
        if (node && node.nodeType === 1) scan(node);
      }));
    });
    observer.observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();
