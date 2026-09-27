(() => {
  'use strict';

  const PLAYER_KEY = 'jl_player_token';
  const ADMIN_KEY = 'jl_admin_token';

  function getPlayerToken() {
    return localStorage.getItem(PLAYER_KEY) || '';
  }

  function setPlayerToken(value) {
    const token = String(value || '');
    if (token) localStorage.setItem(PLAYER_KEY, token);
    else localStorage.removeItem(PLAYER_KEY);
    window.dispatchEvent(new CustomEvent('jl-player-session-changed', {
      detail: { authenticated: Boolean(token) }
    }));
    return token;
  }

  function getAdminToken() {
    return localStorage.getItem(ADMIN_KEY) || '';
  }

  window.JLSession = Object.freeze({
    PLAYER_KEY,
    ADMIN_KEY,
    getPlayerToken,
    setPlayerToken,
    getAdminToken
  });
})();