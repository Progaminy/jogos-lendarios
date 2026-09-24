(() => {
  'use strict';
  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  let timer = null;

  async function rpc(name, args = {}) {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token || !cfg.supabaseUrl || !cfg.supabaseKey) return null;
    const res = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {apikey:cfg.supabaseKey, Authorization:`Bearer ${cfg.supabaseKey}`, 'Content-Type':'application/json', Accept:'application/json'},
      body: JSON.stringify(args)
    });
    if (!res.ok) return null;
    try { return await res.json(); } catch { return null; }
  }

  function ensureStyle() {
    if (document.getElementById('ludoChallengeBadgeStyle')) return;
    const style = document.createElement('style');
    style.id = 'ludoChallengeBadgeStyle';
    style.textContent = `
      .game-nav a[href*="ludo"]{position:relative}
      .ludo-live-count{position:absolute;right:7px;top:5px;min-width:18px;height:18px;padding:0 5px;display:grid;place-items:center;border-radius:999px;background:#ef4c55;color:#fff;border:2px solid #0d1420;font-size:.61rem;font-weight:1000;line-height:1;box-shadow:0 4px 12px rgba(239,76,85,.38)}
      .ludo-live-dot{position:absolute;right:8px;top:7px;width:9px;height:9px;border-radius:50%;background:#4ed58a;box-shadow:0 0 0 4px rgba(78,213,138,.12)}
    `;
    document.head.appendChild(style);
  }

  function render(activeRoom, count) {
    const link = document.querySelector('.game-nav a[href*="ludo"]');
    if (!link) return;
    link.querySelector('.ludo-live-count,.ludo-live-dot')?.remove();
    if (activeRoom) {
      link.dataset.myRoom = '1';
      link.title = 'Você tem uma sala de Ludo ativa';
      const dot = document.createElement('span');
      dot.className = 'ludo-live-dot';
      link.appendChild(dot);
      return;
    }
    delete link.dataset.myRoom;
    if (count > 0) {
      link.title = `${count} desafio(s) de Ludo procurando jogadores`;
      const badge = document.createElement('span');
      badge.className = 'ludo-live-count';
      badge.textContent = count > 9 ? '9+' : String(count);
      link.appendChild(badge);
    }
  }

  async function refresh() {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token) return render(false, 0);
    const status = await rpc('jl_ludo_my_status', {p_token:token});
    if (!status) return;
    if (status.active_room_id) return render(true, 0);
    const rows = await rpc('jl_ludo_public_challenges', {p_token:token});
    render(false, Array.isArray(rows) ? rows.length : 0);
  }

  function init() {
    ensureStyle();
    refresh();
    clearInterval(timer);
    timer = setInterval(() => {
      if (document.visibilityState === 'visible') refresh();
    }, 15000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
  else init();
})();
