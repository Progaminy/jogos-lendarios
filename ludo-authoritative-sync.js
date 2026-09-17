(() => {
  'use strict';
  if (window.__JL_LUDO_AUTHORITATIVE_SYNC__) return;
  window.__JL_LUDO_AUTHORITATIVE_SYNC__ = true;

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  let timer = null;
  let busy = false;

  const $ = (sel) => document.querySelector(sel);

  async function rpc(name, args = {}) {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token || !cfg.supabaseUrl || !cfg.supabaseKey) return null;
    const response = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {
        apikey: cfg.supabaseKey,
        Authorization: `Bearer ${cfg.supabaseKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(args)
    });
    if (!response.ok) return null;
    try { return await response.json(); } catch (_) { return null; }
  }

  function textFor(st) {
    const r = st.room;
    const players = (st.players || []).filter(p => p.status !== 'left');
    const total = Number(r.player_count || 0);
    const joined = players.length;
    const accepted = players.filter(p => p.accepted_rules_version === r.rules_version).length;
    const paid = players.filter(p => p.stake_paid).length;

    if (r.status === 'waiting') return `Aguardando jogadores · ${joined}/${total}`;
    if (r.status === 'negotiating') {
      const grace = r.negotiation_grace_used ? ' · tolerância final de 30 s' : '';
      return `Regras · ${accepted}/${total} confirmaram${grace}`;
    }
    if (r.status === 'funding') return `Apostas · ${paid}/${total} confirmadas`;
    if (r.status === 'playing') return r.turn_phase === 'roll' ? 'Partida ativa · aguardando lançamento do dado' : 'Partida ativa · movimento em andamento';
    if (r.status === 'finished') return 'Partida terminada';
    return 'Sala atualizando';
  }

  function apply(st) {
    if (!st?.room) return;
    const text = textFor(st);
    const wait = $('.ludo-wait-label');
    if (wait && st.room.status !== 'playing' && st.room.status !== 'finished') wait.textContent = text;
    if (st.room.status === 'playing' || st.room.status === 'finished') wait?.remove();

    const quick = $('#ludoQuickText');
    if (quick) quick.textContent = text;

    const roomStatus = $('#rfRoomStatus');
    if (roomStatus && st.room.status === 'negotiating' && st.room.negotiation_grace_used) roomStatus.textContent = 'TOLERÂNCIA FINAL · 30 S';

    const joined = (st.players || []).filter(p => p.status !== 'left').length;
    const total = Number(st.room.player_count || 0);
    const title = $('#ludoQuickTitle');
    if (title) title.textContent = `${st.room.code || 'Minha sala'} · ${joined}/${total}`;

    document.body.dataset.ludoRoomStatus = st.room.status || '';
    document.body.dataset.ludoRoomVersion = String(st.room.rules_version || 0);
  }

  async function sync() {
    if (busy) return;
    busy = true;
    try {
      const token = localStorage.getItem(TOKEN_KEY);
      if (!token) return;
      const status = await rpc('jl_ludo_my_status', { p_token: token });
      if (!status?.active_room_id) return;
      const st = await rpc('jl_ludo_sync_room', { p_token: token, p_room: status.active_room_id });
      apply(st);
    } finally {
      busy = false;
    }
  }

  function start() {
    sync();
    clearInterval(timer);
    timer = setInterval(sync, 1000);
    window.addEventListener('focus', sync);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) sync(); });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
