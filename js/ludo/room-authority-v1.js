(() => {
  'use strict';

  const TOKEN_KEY = 'jl_player_token';
  const AUTHORITY_KEY = '__JL_LUDO_ROOM_AUTHORITY_V1__';
  if (window[AUTHORITY_KEY]?.installed) return;

  const authority = {
    installed: true,
    runtimeState: null,
    snapshot: null,
    activeRoomId: '',
    running: false,
    enforceTimer: 0,
    refreshTimer: 0,
    scrolledRoomId: ''
  };
  window[AUTHORITY_KEY] = authority;

  function token() {
    try {
      return window.JLSession?.getPlayerToken?.() || localStorage.getItem(TOKEN_KEY) || '';
    } catch {
      return '';
    }
  }

  function rpc(name, args) {
    const fn = window.JLApi?.rpc;
    if (typeof fn !== 'function') throw new Error('API do Ludo ainda não está pronta.');
    return fn(name, args);
  }

  function captureRuntimeState() {
    const api = window.JLLudoState;
    if (!api || typeof api.create !== 'function' || api.__jlAuthorityWrapped) return;
    const originalCreate = api.create.bind(api);
    const wrapped = Object.freeze({
      __jlAuthorityWrapped: true,
      create() {
        const state = originalCreate();
        authority.runtimeState = state;
        window.__JL_LUDO_RUNTIME_STATE__ = state;
        return state;
      }
    });
    window.JLLudoState = wrapped;
  }

  captureRuntimeState();

  function money(value) {
    return Number(value || 0).toLocaleString('pt-MZ', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    });
  }

  function setText(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = String(value ?? '');
  }

  function roomCanInvite(snapshot) {
    const room = snapshot?.room;
    const me = snapshot?.identity?.player_id;
    return Boolean(room && me && room.host_id === me && ['waiting', 'negotiating'].includes(room.status));
  }

  function started(room) {
    return room?.status === 'playing' && Boolean(room?.started_at);
  }

  function renderPlayers(snapshot) {
    const target = document.getElementById('playersPanel');
    const room = snapshot?.room;
    if (!target || !room) return;
    const players = Array.isArray(snapshot.players) ? snapshot.players : [];
    target.replaceChildren();
    const count = Math.max(2, Number(room.player_count) || 2);

    for (let seat = 1; seat <= count; seat += 1) {
      const player = players.find(item => Number(item.seat) === seat);
      const card = document.createElement('div');
      card.className = `player-card ${player?.color || ''}`.trim();
      const small = document.createElement('small');
      small.textContent = player ? `posição ${seat}` : `Vaga ${seat}`;
      const title = document.createElement('h3');
      title.textContent = player?.name || 'Aguardando jogador…';
      card.append(small, title);
      if (player) {
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
        card.append(code, flags);
      }
      target.appendChild(card);
    }
  }

  function renderDeadline(snapshot) {
    const room = snapshot?.room;
    const bar = document.getElementById('deadlineBar');
    if (!room || !bar) return;
    let label = 'Sala ativa';
    if (room.status === 'waiting') label = 'Aguardando completar a sala';
    if (room.status === 'negotiating') label = 'Aceitação das regras · sem prazo';
    if (room.status === 'funding') label = 'Confirmar aposta';
    if (room.status === 'playing') label = 'Tempo da jogada';
    setText('deadlineLabel', label);
    bar.classList.remove('hidden');
    bar.removeAttribute('aria-hidden');

    const deadline = room.action_deadline ? Date.parse(room.action_deadline) : NaN;
    if (!Number.isFinite(deadline)) {
      setText('deadlineClock', '--:--');
      return;
    }
    const seconds = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
    setText('deadlineClock', `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`);
  }

  function enforceRoom(snapshot = authority.snapshot) {
    const roomData = snapshot?.room;
    const room = document.getElementById('room');
    if (!roomData || !room) return false;

    authority.snapshot = snapshot;
    authority.activeRoomId = String(roomData.id || '');

    document.getElementById('lobby')?.classList.add('hidden');
    document.getElementById('boardLobby')?.classList.add('hidden');
    document.getElementById('loggedOut')?.classList.add('hidden');
    document.getElementById('notificationCenter')?.classList.remove('hidden');
    document.getElementById('ludoStatusStrip')?.classList.remove('hidden');
    room.hidden = false;
    room.removeAttribute('hidden');
    room.removeAttribute('aria-hidden');
    room.style.removeProperty('display');
    room.classList.remove('hidden');

    setText('roomCode', roomData.code || 'SALA');
    setText('roomMeta', `${roomData.player_count || 0} jogadores · ${roomData.mode === 'partners' ? 'Parceiros 2 × 2' : 'Cada um por si'} · ${money(roomData.bet_amount)} MZN por jogador · ${roomData.is_public ? 'Pública' : 'Privada'}`);
    setText('roomPot', `${money(roomData.pot)} MZN`);
    setText('rulesVersion', `v${roomData.rules_version || 1}`);

    document.getElementById('leaveRoom')?.classList.toggle('hidden', started(roomData));
    document.getElementById('forfeitRoom')?.classList.toggle('hidden', !started(roomData));
    document.querySelector('.invite-panel')?.classList.toggle('hidden', !roomCanInvite(snapshot));

    renderPlayers(snapshot);
    renderDeadline(snapshot);

    const state = authority.runtimeState || window.__JL_LUDO_RUNTIME_STATE__;
    if (state) {
      state.token = token();
      state.room = snapshot;
      if (state.status) state.status.active_room_id = roomData.id;
    }

    if (authority.scrolledRoomId !== authority.activeRoomId) {
      authority.scrolledRoomId = authority.activeRoomId;
      requestAnimationFrame(() => room.scrollIntoView({ behavior: 'smooth', block: 'start' }));
    }
    return true;
  }

  function showLobby(status = null) {
    authority.snapshot = null;
    authority.activeRoomId = '';
    authority.scrolledRoomId = '';
    const state = authority.runtimeState || window.__JL_LUDO_RUNTIME_STATE__;
    if (state) {
      state.token = token();
      state.room = null;
      if (status) state.status = status;
    }
    document.getElementById('room')?.classList.add('hidden');
    document.getElementById('lobby')?.classList.remove('hidden');
    document.getElementById('boardLobby')?.classList.remove('hidden');
    document.getElementById('loggedOut')?.classList.add('hidden');
    document.getElementById('notificationCenter')?.classList.remove('hidden');
    document.getElementById('ludoStatusStrip')?.classList.remove('hidden');
  }

  async function refreshAuthority(reason = 'refresh') {
    if (authority.running) return;
    const playerToken = token();
    if (!playerToken) return;
    if (typeof window.JLApi?.rpc !== 'function') {
      setTimeout(() => void refreshAuthority('api-retry'), 250);
      return;
    }

    authority.running = true;
    try {
      const status = await rpc('jl_ludo_my_status', { p_token: playerToken });
      const state = authority.runtimeState || window.__JL_LUDO_RUNTIME_STATE__;
      if (state) {
        state.token = playerToken;
        state.status = status;
      }
      const roomId = String(status?.active_room_id || '').trim();
      if (!roomId) {
        showLobby(status);
        return;
      }
      const snapshot = await rpc('jl_ludo_room_state_light', { p_token: playerToken, p_room: roomId });
      authority.snapshot = snapshot;
      authority.activeRoomId = roomId;
      if (state) state.room = snapshot;
      enforceRoom(snapshot);
      window.dispatchEvent(new CustomEvent('jl-ludo-authoritative-room', { detail: { roomId, snapshot, reason } }));
      window.JLLudoSync?.kick?.('ludo-state');
    } catch (error) {
      console.warn('ludo room authority', reason, error?.message || error);
      if (authority.snapshot?.room) enforceRoom(authority.snapshot);
    } finally {
      authority.running = false;
    }
  }

  function installDomGuard() {
    const root = document.querySelector('main.shell') || document.body;
    if (!root) return;
    new MutationObserver(() => {
      if (!authority.snapshot?.room) return;
      const room = document.getElementById('room');
      const board = document.getElementById('boardLobby');
      const lobby = document.getElementById('lobby');
      if (room?.classList.contains('hidden') || !board?.classList.contains('hidden') || !lobby?.classList.contains('hidden')) {
        queueMicrotask(() => enforceRoom(authority.snapshot));
      }
    }).observe(root, { attributes: true, subtree: true, attributeFilter: ['class', 'hidden', 'style'] });
  }

  function install() {
    captureRuntimeState();
    installDomGuard();
    void refreshAuthority('startup');
    clearInterval(authority.enforceTimer);
    authority.enforceTimer = window.setInterval(() => {
      if (authority.snapshot?.room) enforceRoom(authority.snapshot);
    }, 500);
    clearInterval(authority.refreshTimer);
    authority.refreshTimer = window.setInterval(() => void refreshAuthority('periodic'), 5000);

    window.addEventListener('pageshow', () => void refreshAuthority('pageshow'));
    window.addEventListener('focus', () => void refreshAuthority('focus'));
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') void refreshAuthority('visible');
    });
    window.addEventListener('jl-player-session-changed', event => {
      if (event.detail?.authenticated) void refreshAuthority('session');
      else {
        authority.snapshot = null;
        authority.activeRoomId = '';
      }
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, { once: true });
  else install();
})();
