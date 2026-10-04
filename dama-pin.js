(() => {
  'use strict';

  if (!String(location.pathname || '').toLowerCase().endsWith('/dama.html')) return;

  const STORAGE_KEY = 'jl_pin_dama';
  const buttonId = 'pinDama';

  function readPinned() {
    try { return sessionStorage.getItem(STORAGE_KEY) === '1'; } catch { return false; }
  }

  function writePinned(value) {
    try { sessionStorage.setItem(STORAGE_KEY, value ? '1' : '0'); } catch {}
  }

  function applyPinned(value, shouldScroll = false) {
    const pinned = Boolean(value);
    document.body.classList.toggle('dama-pinned', pinned);

    const button = document.getElementById(buttonId);
    if (button) {
      button.setAttribute('aria-pressed', pinned ? 'true' : 'false');
      button.textContent = pinned ? '↩ Voltar ao site' : '📌 Fixar Dama';
      button.title = pinned ? 'Voltar à página completa' : 'Fixar a Dama na tela';
    }

    if (pinned && shouldScroll) {
      requestAnimationFrame(() => {
        const target = document.getElementById('damaRoom') || document.querySelector('.dama-room-head');
        target?.scrollIntoView?.({ behavior: 'smooth', block: 'start' });
      });
    }
  }

  function install() {
    const actions = document.querySelector('.dama-room-actions');
    if (!actions) return false;

    let button = document.getElementById(buttonId);
    if (!button) {
      button = document.createElement('button');
      button.id = buttonId;
      button.className = 'button ghost small dama-pin-button';
      button.type = 'button';
      button.setAttribute('aria-pressed', 'false');
      button.textContent = '📌 Fixar Dama';
      actions.prepend(button);

      button.addEventListener('click', () => {
        const next = !document.body.classList.contains('dama-pinned');
        writePinned(next);
        applyPinned(next, next);
      });
    }

    applyPinned(readPinned(), false);
    return true;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();