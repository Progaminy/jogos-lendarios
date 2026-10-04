(() => {
  'use strict';

  const existing = window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__;
  if (existing && typeof existing === 'object' && existing.installed) return;

  const recoveryState = existing && typeof existing === 'object' ? existing : {};
  Object.assign(recoveryState, {
    installed: true,
    pending: true,
    resolved: false,
    activeRoomId: '',
    lastError: '',
    rescueActive: false
  });
  window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__ = recoveryState;

  const TOKEN_KEY = 'jl_player_token';
  const MAX_API_READY_RETRIES = 25;
  const API_READY_RETRY_MS = 200;
  const MAX_STATUS_RETRIES = 4;
  const STATUS_RETRY_MS = 700;

  let recovering = false;
  let apiReadyRetries = 0;
  let statusRetries = 0;
  let retryTimer = 0;
  let rescueSnapshot = null;
  let countdownTimer = 0;

  function token() {
    return window.JLSession?.getPlayerToken?.()
      || localStorage.getItem(TOKEN_KEY)
      || '';
  }

  function rpc(name, args) {
    const fn = window.JLApi?.rpc;
    if (typeof fn !== 'function') throw new Error('api-not-ready');
    return fn(name, args);
  }

  function normalizedText(value) {
    return String(value || '')
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .toLowerCase();
  }

  function isActiveRoomMessage(message) {
    const text = normalizedText(message);
    return text.includes('sala') && text.includes('ativa') && text.includes('participa');
  }

  function money(value) {
    return Number(value || 0).toLocaleString('pt-MZ', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    });
  }

  function showToast(message, type = '') {
    const toast = document.getElementById('toast');
    if (!toast) return;
    toast.textContent = String(message || '');
    toast.className = `toast show ${type}`.trim();
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => { toast.className = 'toast'; }, 3200);
  }

  function emitState() {
    window.dispatchEvent(new CustomEvent('jl-ludo-active-room-recovery', {
      detail: {
        pending: Boolean(recoveryState.pending),
        resolved: Boolean(recoveryState.resolved),
        activeRoomId: String(recoveryState.activeRoomId || ''),
        rescueActive: Boolean(recoveryState.rescueActive)
      }
    }));
  }

  function markPending(error = '') {
    recoveryState.pending = true;
    recoveryState.resolved = false;
    if (error) recoveryState.lastError = String(error);
    emitState();
  }

  function markResolved(roomId = '') {
    recoveryState.pending = false;
    recoveryState.resolved = true;
    recoveryState.activeRoomId = String(roomId || '').trim();
    recoveryState.lastError = '';
    emitState();
  }

  function scheduleRecovery(delay, reason) {
    if (retryTimer) clearTimeout(retryTimer);
    retryTimer = window.setTimeout(() => {
      retryTimer = 0;
      void recoverActiveRoom(reason);
    }, delay);
  }

  function setText(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = String(value ?? '');
  }

  function roomIsStarted(room) {
    return room?.status === 'playing' && Boolean(room?.started_at);
  }

  function roomCanInvite(snapshot) {
    const room = snapshot?.room;
    const me = snapshot?.identity?.player_id;
    return Boolean(room && me && room.host_id === me && ['waiting', 'negotiating'].includes(room.status));
  }

  function renderRescuePlayers(snapshot) {
    const panel = document.getElementById('playersPanel');
    const room = snapshot?.room;
    if (!panel || !room) return;
    const players = Array.isArray(snapshot.players) ? snapshot.players : [];
    panel.replaceChildren();

    for (let seat = 1; seat <= Number(room.player_count || 0); seat += 1) {
      const player = players.find(item => Number(item.seat) === seat);
      const card = document.createElement('div');
      card.className = `player-card ${player?.color || ''}`.trim();

      const small = document.createElement('small');
      if (!player) {
        small.textContent = `Vaga ${seat}`;
        const h3 = document.createElement('h3');
        h3.textContent = 'Aguardando jogador…';
        card.append(small, h3);
      } else {
        small.textContent = `${player.team ? `Equipa ${player.team} · ` : ''}posição ${seat}`;
        const h3 = document.createElement('h3');
        h3.textContent = player.name || player.code || 'Jogador';
        const code = document.createElement('small');
        code.textContent = player.code || '';
        const flags = document.createElement('div');
        flags.className = 'player-flags';
        const rules = document.createElement('span');
        rules.className = `flag ${player.accepted_rules_version === room.rules_version ? 'ok' : 'wait'}`;
        rules.textContent = player.accepted_rules_version === room.rules_version ? '✓ regras' : 'regras…';
        const stake = document.createElement('span');
        stake.className = `flag ${player.stake_paid ? 'ok' : 'wait'}`;
        stake.textContent = player.stake_paid ? '✓ aposta' : 'aposta…';
        flags.append(rules, stake);
        card.append(small, h3, code, flags);
      }
      panel.appendChild(card);
    }
  }

  function updateRescueClock(snapshot) {
    const room = snapshot?.room;
    const bar = document.getElementById('deadlineBar');
    const label = document.getElementById('deadlineLabel');
    const clock = document.getElementById('deadlineClock');
    if (!room || !bar || !label || !clock) return;

    let text = room.status;
    if (room.status === 'negotiating') text = 'Aceitação das regras · sem prazo';
    else if (room.status === 'funding') text = 'Tempo para confirmar a aposta';
    else if (room.status === 'playing' && !room.started_at) text = 'Aguardando primeiro dado · sem prazo';
    else if (room.status === 'playing') text = 'Tempo da jogada';
    else if (room.status === 'waiting') text = 'Aguardando completar a sala';
    else if (room.status === 'finished') text = 'Partida terminada';

    label.textContent = text;
    bar.classList.remove('hidden');
    bar.removeAttribute('aria-hidden');

    const tick = () => {
      const deadline = room.action_deadline ? new Date(room.action_deadline).getTime() : 0;
      if (!deadline || !Number.isFinite(deadline)) {
        clock.textContent = '--:--';
        return;
      }
      const seconds = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
      const mm = String(Math.floor(seconds / 60)).padStart(2, '0');
      const ss = String(seconds % 60).padStart(2, '0');
      clock.textContent = `${mm}:${ss}`;
    };

    clearInterval(countdownTimer);
    tick();
    countdownTimer = window.setInterval(tick, 500);
  }

  function forceRoomVisible(snapshot) {
    const roomData = snapshot?.room;
    const room = document.getElementById('room');
    if (!roomData || !room) return false;

    rescueSnapshot = snapshot;
    recoveryState.rescueActive = true;
    recoveryState.activeRoomId = String(roomData.id || recoveryState.activeRoomId || '');

    document.getElementById('lobby')?.classList.add('hidden');
    document.getElementById('boardLobby')?.classList.add('hidden');
    document.getElementById('loggedOut')?.classList.add('hidden');
    document.getElementById('ludoStatusStrip')?.classList.remove('hidden');
    document.getElementById('notificationCenter')?.classList.remove('hidden');
    room.classList.remove('hidden');

    setText('roomCode', roomData.code || 'SALA');
    setText(
      'roomMeta',
      `${roomData.player_count || 0} jogadores · ${roomData.mode === 'partners' ? 'Parceiros 2 × 2' : 'Cada um por si'} · ${money(roomData.bet_amount)} MZN por jogador · ${roomData.is_public ? 'Pública' : 'Privada'}`
    );
    setText('roomPot', `${money(roomData.pot)} MZN`);
    setText('rulesVersion', `v${roomData.rules_version || 1}`);

    const started = roomIsStarted(roomData);
    document.getElementById('leaveRoom')?.classList.toggle('hidden', started);
    document.getElementById('forfeitRoom')?.classList.toggle('hidden', !started);

    const invitePanel = document.querySelector('.invite-panel');
    invitePanel?.classList.toggle('hidden', !roomCanInvite(snapshot));

    renderRescuePlayers(snapshot);
    updateRescueClock(snapshot);

    requestAnimationFrame(() => {
      if (!room.classList.contains('hidden')) room.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
    emitState();
    return true;
  }

  function releaseRescue() {
    rescueSnapshot = null;
    recoveryState.rescueActive = false;
    clearInterval(countdownTimer);
    countdownTimer = 0;
    emitState();
  }

  async function loadRoomSnapshot(roomId, playerToken) {
    try {
      return await rpc('jl_ludo_room_state_light', { p_token: playerToken, p_room: roomId });
    } catch (lightError) {
      try {
        return await rpc('jl_ludo_room_state', { p_token: playerToken, p_room: roomId });
      } catch {
        throw lightError;
      }
    }
  }

  function renderFoundPlayers(rows) {
    const target = document.getElementById('playerSearchResults');
    if (!target) return;
    target.replaceChildren();
    const list = Array.isArray(rows) ? rows : [];
    if (!list.length) {
      const empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = 'Nenhum jogador encontrado.';
      target.appendChild(empty);
      return;
    }
    for (const player of list) {
      const row = document.createElement('div');
      row.className = 'mini-item';
      const info = document.createElement('div');
      const strong = document.createElement('strong');
      strong.textContent = player.name || 'Jogador';
      const small = document.createElement('small');
      small.textContent = `${player.code || ''}${player.waiting ? ' · à espera' : ''}`;
      info.append(strong, document.createElement('br'), small);
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'button ghost small';
      button.dataset.invitePlayer = player.player_id;
      button.textContent = 'Convidar';
      row.append(info, button);
      target.appendChild(row);
    }
  }

  async function loadWaiting() {
    if (!recoveryState.rescueActive || !roomCanInvite(rescueSnapshot)) return;
    const target = document.getElementById('waitingPlayers');
    if (!target) return;
    try {
      const rows = await rpc('jl_ludo_waiting_players', {
        p_token: token(),
        p_room: rescueSnapshot.room.id
      });
      target.replaceChildren();
      const list = Array.isArray(rows) ? rows : [];
      if (!list.length) {
        const empty = document.createElement('div');
        empty.className = 'empty';
        empty.textContent = 'Nenhum compatível agora.';
        target.appendChild(empty);
        return;
      }
      renderWaitingRows(list, target);
    } catch (error) {
      showToast(error?.message || 'Não foi possível atualizar jogadores à espera.', 'error');
    }
  }

  function renderWaitingRows(rows, target) {
    for (const player of rows) {
      const row = document.createElement('div');
      row.className = 'mini-item';
      const info = document.createElement('div');
      const strong = document.createElement('strong');
      strong.textContent = player.name || 'Jogador';
      const small = document.createElement('small');
      small.textContent = player.code || '';
      info.append(strong, document.createElement('br'), small);
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'button ghost small';
      button.dataset.invitePlayer = player.player_id;
      button.textContent = 'Convidar';
      row.append(info, button);
      target.appendChild(row);
    }
  }

  function installRescueActions() {
    if (document.documentElement.dataset.jlLudoRescueActions === '1') return;
    document.documentElement.dataset.jlLudoRescueActions = '1';

    document.addEventListener('submit', event => {
      if (!recoveryState.rescueActive || event.target?.id !== 'searchPlayerForm') return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const query = document.getElementById('searchPlayer')?.value?.trim() || '';
      void (async () => {
        try {
          const rows = await rpc('jl_ludo_find_players', { p_token: token(), p_query: query });
          renderFoundPlayers(rows);
        } catch (error) {
          showToast(error?.message || 'Não foi possível buscar jogadores.', 'error');
        }
      })();
    }, true);

    document.addEventListener('click', event => {
      if (!recoveryState.rescueActive || !rescueSnapshot?.room?.id) return;

      const invite = event.target.closest?.('[data-invite-player]');
      if (invite) {
        event.preventDefault();
        event.stopImmediatePropagation();
        void (async () => {
          try {
            await rpc('jl_ludo_invite', {
              p_token: token(),
              p_room: rescueSnapshot.room.id,
              p_target_player: invite.dataset.invitePlayer
            });
            showToast('Convite enviado por 60 segundos.', 'success');
          } catch (error) {
            showToast(error?.message || 'Não foi possível enviar o convite.', 'error');
          }
        })();
        return;
      }

      if (event.target.closest?.('#refreshWaiting')) {
        event.preventDefault();
        event.stopImmediatePropagation();
        void loadWaiting();
        return;
      }

      if (event.target.closest?.('#copyRoomCode')) {
        event.preventDefault();
        event.stopImmediatePropagation();
        const code = rescueSnapshot.room.code || '';
        navigator.clipboard?.writeText?.(code)
          .then(() => showToast('Código copiado.', 'success'))
          .catch(() => showToast(code));
        return;
      }

      if (event.target.closest?.('#leaveRoom')) {
        event.preventDefault();
        event.stopImmediatePropagation();
        void (async () => {
          try {
            await rpc('jl_ludo_cancel_or_leave', { p_token: token(), p_room: rescueSnapshot.room.id });
            releaseRescue();
            markResolved('');
            document.getElementById('room')?.classList.add('hidden');
            document.getElementById('boardLobby')?.classList.remove('hidden');
            document.getElementById('lobby')?.classList.remove('hidden');
            showToast('Saiu da sala.');
          } catch (error) {
            showToast(error?.message || 'Não foi possível sair da sala.', 'error');
          }
        })();
        return;
      }

      if (event.target.closest?.('#forfeitRoom')) {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (!window.confirm('Desistir desta partida? Esta ação não pode ser anulada.')) return;
        void (async () => {
          try {
            await rpc('jl_ludo_forfeit', { p_token: token(), p_room: rescueSnapshot.room.id });
            releaseRescue();
            markResolved('');
            void recoverActiveRoom('after-forfeit');
          } catch (error) {
            showToast(error?.message || 'Não foi possível desistir.', 'error');
          }
        })();
      }
    }, true);
  }

  function installVisibilityGuard() {
    const room = document.getElementById('room');
    if (!room) return;
    new MutationObserver(() => {
      if (!recoveryState.rescueActive || !rescueSnapshot?.room) return;
      if (room.classList.contains('hidden')) queueMicrotask(() => forceRoomVisible(rescueSnapshot));
    }).observe(room, { attributes: true, attributeFilter: ['class'] });
  }

  async function recoverActiveRoom(reason = 'startup') {
    if (recovering) return;

    const playerToken = token();
    if (!playerToken) {
      apiReadyRetries = 0;
      statusRetries = 0;
      releaseRescue();
      markResolved('');
      return;
    }

    if (typeof window.JLApi?.rpc !== 'function') {
      markPending('api-not-ready');
      if (apiReadyRetries < MAX_API_READY_RETRIES) {
        apiReadyRetries += 1;
        scheduleRecovery(API_READY_RETRY_MS, 'api-ready-retry');
      }
      return;
    }

    apiReadyRetries = 0;
    recovering = true;
    markPending();

    try {
      const status = await rpc('jl_ludo_my_status', { p_token: playerToken });
      const roomId = String(status?.active_room_id || '').trim();
      statusRetries = 0;

      if (!roomId) {
        releaseRescue();
        markResolved('');
        return;
      }

      recoveryState.activeRoomId = roomId;
      const snapshot = await loadRoomSnapshot(roomId, playerToken);
      markResolved(roomId);
      forceRoomVisible(snapshot);
      if (roomCanInvite(snapshot)) void loadWaiting();
    } catch (error) {
      markPending(error?.message || reason || 'status-failed');
      if (statusRetries < MAX_STATUS_RETRIES) {
        statusRetries += 1;
        scheduleRecovery(STATUS_RETRY_MS * statusRetries, 'status-retry');
      }
    } finally {
      recovering = false;
    }
  }

  function install() {
    installRescueActions();
    installVisibilityGuard();

    const toast = document.getElementById('toast');
    if (toast) {
      const inspectToast = () => {
        if (isActiveRoomMessage(toast.textContent)) {
          statusRetries = 0;
          void recoverActiveRoom('active-room-toast');
        }
      };
      new MutationObserver(inspectToast).observe(toast, {
        childList: true,
        characterData: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['class']
      });
      inspectToast();
    }

    window.addEventListener('jl-player-session-changed', event => {
      if (event.detail?.authenticated) {
        apiReadyRetries = 0;
        statusRetries = 0;
        markPending();
        void recoverActiveRoom('session-authenticated');
      } else {
        releaseRescue();
        markResolved('');
      }
    });

    window.addEventListener('pageshow', () => {
      if (!token()) return;
      apiReadyRetries = 0;
      statusRetries = 0;
      markPending();
      void recoverActiveRoom('pageshow');
    });

    window.setInterval(() => {
      if (token()) void recoverActiveRoom('periodic-rescue');
    }, 5000);

    void recoverActiveRoom('startup');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();
