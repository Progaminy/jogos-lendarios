(() => {
  'use strict';

  const FOCUSABLE = [
    'button:not([disabled])',
    'a[href]',
    'input:not([disabled]):not([type="hidden"])',
    'select:not([disabled])',
    'textarea:not([disabled])',
    '[tabindex]:not([tabindex="-1"])'
  ].join(',');

  const states = new WeakMap();

  function isOpen(dialog) {
    return Boolean(
      dialog &&
      dialog.matches('[role="dialog"][aria-modal="true"]') &&
      !dialog.classList.contains('hidden') &&
      dialog.getAttribute('aria-hidden') !== 'true'
    );
  }

  function focusables(dialog) {
    return [...dialog.querySelectorAll(FOCUSABLE)]
      .filter((el) => !el.hidden && el.getClientRects().length > 0);
  }

  function initialTarget(dialog) {
    return dialog.querySelector('[data-dialog-initial]:not([disabled])')
      || dialog.querySelector('[autofocus]:not([disabled])')
      || focusables(dialog)[0]
      || dialog;
  }

  function onOpen(dialog) {
    const previous = states.get(dialog) || {};
    if (previous.open) return;

    const opener = document.activeElement instanceof HTMLElement
      && document.activeElement !== document.body
      ? document.activeElement
      : null;

    states.set(dialog, { open: true, opener });

    if (!dialog.hasAttribute('tabindex')) dialog.setAttribute('tabindex', '-1');

    requestAnimationFrame(() => {
      if (!isOpen(dialog)) return;
      const target = initialTarget(dialog);
      target?.focus?.({ preventScroll: true });
    });
  }

  function onClose(dialog) {
    const previous = states.get(dialog);
    if (!previous?.open) return;

    states.set(dialog, { open: false, opener: previous.opener });

    const opener = previous.opener;
    requestAnimationFrame(() => {
      if (opener?.isConnected && typeof opener.focus === 'function') {
        opener.focus({ preventScroll: true });
      }
    });
  }

  function sync(dialog) {
    if (!dialog?.matches?.('[role="dialog"][aria-modal="true"]')) return;
    if (isOpen(dialog)) onOpen(dialog);
    else onClose(dialog);
  }

  function topDialog() {
    const open = [...document.querySelectorAll('[role="dialog"][aria-modal="true"]')]
      .filter(isOpen);
    return open[open.length - 1] || null;
  }

  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Tab') return;

    const dialog = topDialog();
    if (!dialog) return;

    const items = focusables(dialog);
    if (!items.length) {
      event.preventDefault();
      dialog.focus();
      return;
    }

    const first = items[0];
    const last = items[items.length - 1];
    const active = document.activeElement;

    if (event.shiftKey && (active === first || !dialog.contains(active))) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && (active === last || !dialog.contains(active))) {
      event.preventDefault();
      first.focus();
    }
  }, true);

  function observe(root = document.body) {
    if (!root) return;

    root.querySelectorAll?.('[role="dialog"][aria-modal="true"]').forEach(sync);

    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.type === 'attributes') {
          sync(mutation.target);
          continue;
        }

        for (const node of mutation.addedNodes) {
          if (!(node instanceof Element)) continue;
          if (node.matches?.('[role="dialog"][aria-modal="true"]')) sync(node);
          node.querySelectorAll?.('[role="dialog"][aria-modal="true"]').forEach(sync);
        }
      }
    });

    observer.observe(root, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['class', 'aria-hidden']
    });
  }

  function init() {
    observe(document.body);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }

  window.JLDialogA11y = Object.freeze({ sync });
})();