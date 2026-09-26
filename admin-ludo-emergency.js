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
    refresh: $('ludoEmergencyRefresh'),
    list: $('ludoEmergencyRoomList'),
    message: $('ludoEmergencyMessage'),
    toast: $('toast')
  };

  if (!ui.cancel) return;

  let last = null;
  let activeRooms = [];
  let busy = false;

  const money = (value) => Number(value || 0).toLocaleString('pt-MZ', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });

  const dateTime = (value) => value
    ? new Date(value).toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' })
    : '—';

  const escapeHtml = (value) => String(value ?? '').replace(/[&<>'"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  }[c]));

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

  function reset() {
    last = null;
    activeRooms = [];
    if (ui.rooms) ui.rooms.textContent = '—';
    if (ui.players) ui.players.textContent = '—';
    if (ui.staked) ui.staked.textContent = '—';
    if (ui.queue) ui.queue.textContent = '—';
    if (ui.badge) {
      ui.badge.textContent = 'Aguardando login';
      ui.badge.className = 'badge muted';
    }
    ui.cancel.disabled = true;
    if (ui.list) ui.list.innerHTML = '<div class="empty">Entre no admin para ver os jogos ativos.</div>';
  }

  function renderRooms(rows = []) {
    activeRooms = Array.isArray(rows) ? rows : [];
    if (!ui.list) return;
    if (!activeRooms.length) {
      ui.list.innerHTML = '<div class="empty">Nenhuma partida de Ludo ativa.</div>';
      return;
    }

    ui.list.innerHTML = activeRooms.map((room) => `
      <div class="request-row">
        <div>
          <strong>${escapeHtml(room.code || 'Sala')}</strong><br>
          <small>${escapeHtml(room.status || '—')} · ${Number(room.active_players || 0)}/${Number(room.player_count || 0)} jogadores · ${escapeHtml(room.mode || '—')} · criada ${dateTime(room.created_at)}</small>
        </div>
        <div>
          <strong>MZN ${money(room.staked_total || 0)}</strong><br>
          <small>Aposta: MZN ${money(room.bet_amount || 0)}</small>
        </div>
        <div class="row-actions">
          <button class="button danger small" type="button" data-cancel-ludo-room="${escapeHtml(room.id)}" data-room-code="${escapeHtml(room.code || '')}" ${busy ? 'disabled' : ''}>Cancelar este jogo</button>
        </div>
      </div>
    `).join('');
  }

  function render(data, rows = activeRooms) {
    last = data || {};
    const rooms = Number(last.active_rooms || 0);
    const players = Number(last.active_players || 0);
    const staked = Number(last.staked_total || 0);
    const queue = Number(last.waiting_queue || 0);

    ui.rooms.textContent = String(rooms);
    ui.players.textContent = String(players);
    ui.staked.textContent = money(staked);
    ui.queue.textContent = String(queue);
    // O botão de emergência continua utilizável sempre que há sessão admin.
    // O próprio backend é autoritativo e responde corretamente mesmo com 0 salas.
    ui.cancel.disabled = busy || !token();
    if (ui.refresh) ui.refresh.disabled = busy;

    if (rooms > 0) {
      ui.badge.textContent = `${rooms} ativa${rooms === 1 ? '' : 's'}`;
      ui.badge.className = 'badge danger';
    } else {
      ui.badge.textContent = 'Sem jogos ativos';
      ui.badge.className = 'badge success';
    }
    renderRooms(rows);
  }

  async function refresh(silent = true) {
    const pToken = token();
    if (!pToken || busy) {
      if (!pToken) reset();
      return;
    }
    let statusData = null;
    let roomRows = null;
    let statusError = null;
    let roomsError = null;

    try {
      statusData = await rpc('jl_admin_ludo_emergency_status', { p_token: pToken });
    } catch (error) {
      statusError = error;
    }

    try {
      roomRows = await rpc('jl_admin_ludo_active_rooms', { p_token: pToken });
    } catch (error) {
      roomsError = error;
    }

    if (!statusData && !roomRows) {
      const error = statusError || roomsError || new Error('Não foi possível atualizar o Ludo.');
      ui.cancel.disabled = false;
      if (!silent) {
        ui.message.textContent = error.message;
        toast(error.message, 'error');
      }
      return;
    }

    if (!statusData) {
      const safeRows = Array.isArray(roomRows) ? roomRows : [];
      statusData = {
        active_rooms: safeRows.length,
        active_players: safeRows.reduce((sum, room) => sum + Number(room.active_players || 0), 0),
        staked_total: safeRows.reduce((sum, room) => sum + Number(room.staked_total || 0), 0),
        waiting_queue: Number(last?.waiting_queue || 0)
      };
    }

    render(statusData, Array.isArray(roomRows) ? roomRows : activeRooms);

    if (roomsError && ui.list) {
      ui.list.innerHTML = '<div class="empty">Não foi possível atualizar a lista individual. O cancelamento geral continua disponível.</div>';
    }

    if (!silent) {
      const partial = statusError || roomsError;
      ui.message.textContent = partial ? `Atualização parcial: ${partial.message}` : '';
    }
  }

  ui.cancel.addEventListener('click', async () => {
    if (busy) return;
    await refresh(true);
    const rooms = Number(last?.active_rooms || 0);
    const players = Number(last?.active_players || 0);
    const staked = Number(last?.staked_total || 0);
    const ok = window.confirm(
      rooms > 0
        ? `EMERGÊNCIA LUDO\n\nCancelar ${rooms} sala(s) ativa(s), retirar ${players} jogador(es) dessas partidas e devolver MZN ${money(staked)} já debitados?\n\nEsta ação encerra os jogos imediatamente.`
        : 'EMERGÊNCIA LUDO\n\nExecutar o cancelamento geral agora? O servidor verificará novamente todas as salas e encerrará qualquer partida que ainda esteja ativa.'
    );
    if (!ok) return;

    busy = true;
    render(last, activeRooms);
    ui.message.textContent = 'A cancelar todos os jogos e devolver apostas…';

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
    }
  });

  ui.list?.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-cancel-ludo-room]');
    if (!button || busy) return;

    const roomId = button.dataset.cancelLudoRoom;
    const roomCode = button.dataset.roomCode || 'esta sala';
    const room = activeRooms.find((item) => String(item.id) === String(roomId));
    const staked = Number(room?.staked_total || 0);
    const ok = window.confirm(
      `Cancelar apenas ${roomCode}?\n\nJogadores: ${Number(room?.active_players || 0)}\nValor a devolver: MZN ${money(staked)}\n\nAs outras partidas continuam normalmente.`
    );
    if (!ok) return;

    busy = true;
    render(last, activeRooms);
    ui.message.textContent = `A cancelar ${roomCode}…`;

    try {
      const result = await rpc('jl_admin_cancel_ludo_room', {
        p_token: token(),
        p_room: roomId,
        p_reason: (ui.reason.value || '').trim() || 'Cancelamento administrativo de partida'
      });
      ui.message.textContent = `${result?.room_code || roomCode} cancelada. Reembolso: MZN ${money(result?.refunded_total || 0)}.`;
      toast(result?.message || 'Partida cancelada.', 'success');
    } catch (error) {
      ui.message.textContent = error.message;
      toast(error.message, 'error');
    } finally {
      busy = false;
      await refresh(true);
    }
  });

  ui.refresh?.addEventListener('click', () => refresh(false));
  $('refreshAdmin')?.addEventListener('click', () => refresh(false));

  window.addEventListener('jl-admin-session-changed', (event) => {
    if (event.detail?.authenticated) {
      setTimeout(() => refresh(false), 0);
    } else {
      reset();
    }
  });

  window.addEventListener('storage', (event) => {
    if (event.key !== TOKEN_KEY) return;
    if (event.newValue) refresh(false);
    else reset();
  });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && token()) refresh(true);
  });

  setInterval(() => {
    if (document.visibilityState === 'visible' && token()) refresh(true);
  }, 15000);

  if (token()) setTimeout(() => refresh(true), 150);
  else reset();
})();