(() => {
  'use strict';

  if (!('serviceWorker' in navigator)) return;

  window.addEventListener('load', () => {
    navigator.serviceWorker
      .register('./sw.js?v=20260928-22', { scope: './' })
      .catch(() => {});
  }, { once: true });
})();
