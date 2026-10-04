(() => {
  'use strict';

  function normalizedPath() {
    return String(window.location.pathname || '/')
      .replace(/\/+$/, '')
      .toLowerCase();
  }

  function isLudoPath() {
    const path = normalizedPath();
    return path.endsWith('/ludo') || path.endsWith('/ludo.html');
  }

  function repairLudoHeader() {
    if (!isLudoPath()) return;

    const currentRefresh = document.getElementById('refreshLobby');
    const genericRefresh = document.getElementById('jlHeaderRefresh');
    if (!currentRefresh && genericRefresh) genericRefresh.id = 'refreshLobby';

    document.querySelectorAll('.game-nav [data-jl-nav]').forEach(link => {
      link.classList.toggle('active', link.dataset.jlNav === 'tabuleiro');
    });
  }

  repairLudoHeader();
  document.addEventListener('DOMContentLoaded', repairLudoHeader, { once: true });
  window.addEventListener('pageshow', repairLudoHeader);
})();
