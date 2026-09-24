(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_admin_token';
  const $ = (id) => document.getElementById(id);

  const ui = {
    badge: $('ludoEmergencyBadge'),
    rooms: $('ludoEmergencyRooms'),
    players: $('ludoEmergencyPlayers'),
    staked: $('ludoEmergencyStaked'),
    queue: $('ludoEmergencyQueue'),
    reason: $('ludoEmergencyReason'),
    cancel: $('ludoEmergencyCancelAll'),
    message: $('ludoEmergencyMessage'),
    toast: $('toast')
  };

  if (!ui.cancel) return;

  let last = null;
  let busy = false;

  const money = (value) => Number(value || 0).toLocaleString('pt-MZ', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });

  function token() {
    return localStorage.getItem(TOKEN_KEY) || '';
  }

  async function rpc(name, args = {}) {
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
    const raw = await response.text();
    let payload = null;
    try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }
    if (!response.ok) throw new Error(payload?.message || payload?.error || payload?.hint || `Erro ${response.status}`);
    return payload;
  }

  function toast(message, type = '') {
    if (!ui.toast) return;
    ui.toast.textContent = message;
    ui.toast.className = `toast show ${type}`.trim();
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { ui.toast.className = 'toast'; }, 4500);
  }

  function render(data) {
    last = data || {};
    const rooms = Number(last.active_rooms || 0);
    const players = Number(last.active_players || 0);
    const staked = Number(last.staked_total || 0);
    const queue = Number(last.waiting_queue || 0);

    ui.rooms.textContent = String(rooms);
    ui.players.textContent = String(players);
    ui.staked.textContent = money(staked);
    ui.queue.textContent = String(queue);
    ui.cancel.disabled = busy || rooms === 0;

    if (rooms > 0) {
      ui.badge.textContent = `${rooms} ativa${rooms === 1 ? '' : 's'}`;
      ui.badge.className = 'badge danger';
    } else {
      ui.badge.textContent = 'Sem jogos ativos';
      ui.badge.className = 'badge success';
    }
  }

  async function refresh(silent = true) {
    const pToken = token();
    if (!pToken || busy) return;
    try {
      const data = await rpc('jl_admin_ludo_emergency_status', { p_token: pToken });
      render(data);
      if (!silent) ui.message.textContent = '';
    } catch (error) {
      if (!silent) ui.message.textContent = error.message;
    }
  }

  ui.cancel.addEventListener('click', async () => {
    if (busy) return;
    await refresh(true);
    const rooms = Number(last?.active_rooms || 0);
    if (!rooms) return render(last);

    const players = Number(last?.active_players || 0);
    const staked = Number(last?.staked_total || 0);
    const ok = window.confirm(
      `EMERGÊNCIA LUDO\n\nCancelar ${rooms} sala(s) ativa(s), retirar ${players} jogador(es) dessas partidas e devolver MZN ${money(staked)} já debitados?\n\nEsta ação encerra os jogos imediatamente.`
    );
    if (!ok) return;

    busy = true;
    ui.cancel.disabled = true;
    ui.message.textContent = 'A cancelar jogos e devolver apostas…';

    try {
      const result = await rpc('jl_admin_cancel_all_ludo', {
        p_token: token(),
        p_reason: (ui.reason.value || '').trim() || 'Cancelamento administrativo de emergência'
      });
      ui.message.textContent = `${result?.cancelled_rooms || 0} jogo(s) cancelado(s). Reembolso total: MZN ${money(result?.refunded_total || 0)}.`;
      toast(result?.message || 'Jogos do Ludo cancelados.', 'success');
    } catch (error) {
      ui.message.textContent = error.message;
      toast(error.message, 'error');
    } finally {
      busy = false;
      await refresh(true);
      render(last);
    }
  });

  $('refreshAdmin')?.addEventListener('click', () => refresh(false));
  setInterval(() => { if (document.visibilityState === 'visible') refresh(true); }, 15000);
  setTimeout(() => refresh(true), 300);
})();