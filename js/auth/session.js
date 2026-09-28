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

  function migrateLegacyAdminToken() {
    let token = sessionStorage.getItem(ADMIN_KEY) || '';
    const legacy = localStorage.getItem(ADMIN_KEY) || '';
    if (!token && legacy) {
      token = legacy;
      sessionStorage.setItem(ADMIN_KEY, token);
    }
    if (legacy) localStorage.removeItem(ADMIN_KEY);
    return token;
  }

  function getAdminToken() {
    return migrateLegacyAdminToken();
  }

  function setAdminToken(value) {
    const token = String(value || '');
    localStorage.removeItem(ADMIN_KEY);
    if (token) sessionStorage.setItem(ADMIN_KEY, token);
    else sessionStorage.removeItem(ADMIN_KEY);
    window.dispatchEvent(new CustomEvent('jl-admin-session-changed', {
      detail: { authenticated: Boolean(token) }
    }));
    return token;
  }

  window.JLSession = Object.freeze({
    PLAYER_KEY,
    ADMIN_KEY,
    getPlayerToken,
    setPlayerToken,
    getAdminToken,
    setAdminToken
  });
})();