(() => {
  'use strict';

  function config() {
    const cfg = window.JL_CONFIG || {};
    if (!cfg.supabaseUrl || !cfg.supabaseKey) {
      throw new Error('Configuração do Supabase ausente.');
    }
    return cfg;
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
      keepalive: Boolean(options.keepalive)
    });

    const raw = await response.text();
    let payload = null;
    try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }

    if (!response.ok) {
      throw new Error(payload?.message || payload?.error || payload?.hint || `Erro ${response.status}`);
    }
    return payload;
  }

  window.JLApi = Object.freeze({ rpc });
})();