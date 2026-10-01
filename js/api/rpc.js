(() => {
  'use strict';

  const PLAYER_TOKEN_KEY = 'jl_player_token';

  function config() {
    const cfg = window.JL_CONFIG || {};
    if (!cfg.supabaseUrl || !cfg.supabaseKey) {
      throw new Error('Configuração do Supabase ausente.');
    }
    return cfg;
  }

  function isInvalidPlayerSession(message) {
    return /sess[aã]o.*(?:inv[aá]lida|expirada)/i.test(String(message || ''));
  }

  function currentPlayerToken() {
    return window.JLSession?.getPlayerToken?.() ||
      localStorage.getItem(PLAYER_TOKEN_KEY) ||
      '';
  }

  function invalidateRejectedPlayerSession(args, message) {
    const rejectedToken = typeof args?.p_token === 'string' ? args.p_token : '';
    if (!rejectedToken || !isInvalidPlayerSession(message)) return false;

    const activeToken = currentPlayerToken();

    // Never let a delayed response from an older request log out a newer login.
    if (!activeToken || activeToken !== rejectedToken) return false;

    if (window.JLSession?.setPlayerToken) {
      window.JLSession.setPlayerToken('');
    } else {
      localStorage.removeItem(PLAYER_TOKEN_KEY);
    }

    window.dispatchEvent(new CustomEvent('jl-player-session-invalidated', {
      detail: {
        message: String(message || ''),
        reason: 'replaced_or_expired'
      }
    }));
    return true;
  }

  async function rpc(name, args = {}, options = {}) {
    const cfg = config();
    const response = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {
        apikey: cfg.supabaseKey,
        Authorization: `Bearer ${cfg.supabaseKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(args),
      keepalive: Boolean(options.keepalive),
      signal: options.signal
    });

    const raw = await response.text();
    let payload = null;
    try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }

    if (!response.ok) {
      const message = payload?.message || payload?.error || payload?.hint || `Erro ${response.status}`;
      invalidateRejectedPlayerSession(args, message);
      throw new Error(message);
    }
    return payload;
  }

  window.JLApi = Object.freeze({ rpc });
})();
