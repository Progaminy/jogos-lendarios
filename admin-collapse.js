(() => {
  'use strict';

  const STORAGE_KEY = 'jl_admin_collapsed_v1';

  function readState() {
    try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}'); }
    catch { return {}; }
  }

  function writeState(state) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); } catch {}
  }

  function directText(card, selector) {
    const el = card.querySelector(selector);
    return el?.textContent?.trim() || '';
  }

  function labelFor(card, index) {
    const eyebrow = directText(card, ':scope > .eyebrow');
    const h2 = directText(card, ':scope > h2');
    const headEyebrow = directText(card, ':scope > .section-head .eyebrow');
    const headH2 = directText(card, ':scope > .section-head h2');

    if (eyebrow && h2) return `${eyebrow} · ${h2}`;
    if (headEyebrow && headH2) return `${headEyebrow} · ${headH2}`;
    if (eyebrow) return eyebrow;
    if (h2) return h2;
    return `Secção ${index + 1}`;
  }

  function keyFor(card, index) {
    if (card.id) return card.id;
    const ids = Array.from(card.querySelectorAll('[id]')).slice(0, 3).map(el => el.id).join('|');
    return ids || `admin-card-${index}`;
  }

  function isMainGameCard(card) {
    return Boolean(
      card.querySelector('#numberMetricRound') ||
      card.querySelector('#pairMetricRound')
    );
  }

  function makeCollapsible(card, index, saved) {
    if (card.dataset.adminCollapsible === '1') return;
    card.dataset.adminCollapsible = '1';
    card.classList.add('admin-collapsible');

    const key = keyFor(card, index);
    const title = labelFor(card, index);
    const topLevel = isMainGameCard(card) ||
      card.querySelector('#depositRequests') ||
      card.querySelector('#withdrawRequests') ||
      card.querySelector('#playersList');

    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.className = 'admin-collapse-toggle';
    toggle.setAttribute('aria-expanded', 'true');
    toggle.innerHTML = `<span class="admin-collapse-icon">▾</span><span class="admin-collapse-label">${title}</span><span class="admin-collapse-hint">recolher</span>`;
    card.prepend(toggle);

    const defaultCollapsed = topLevel ? false : true;
    const collapsed = Object.prototype.hasOwnProperty.call(saved, key) ? Boolean(saved[key]) : defaultCollapsed;

    function apply(value, persist = true) {
      card.classList.toggle('admin-collapsed', value);
      toggle.setAttribute('aria-expanded', String(!value));
      const icon = toggle.querySelector('.admin-collapse-icon');
      const hint = toggle.querySelector('.admin-collapse-hint');
      if (icon) icon.textContent = value ? '▸' : '▾';
      if (hint) hint.textContent = value ? 'expandir' : 'recolher';
      if (persist) {
        saved[key] = value;
        writeState(saved);
      }
    }

    toggle.addEventListener('click', () => apply(!card.classList.contains('admin-collapsed')));
    apply(collapsed, false);
  }

  function init() {
    const root = document.getElementById('adminApp');
    if (!root) return;
    const saved = readState();

    const cards = [
      ...root.querySelectorAll(':scope > section.card.admin-card'),
      ...root.querySelectorAll('.admin-two > section.card.admin-card'),
      ...root.querySelectorAll(':scope > section.card.admin-card .card.admin-card')
    ];

    [...new Set(cards)].forEach((card, index) => makeCollapsible(card, index, saved));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();