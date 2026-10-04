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
    if (!api || typeof api.create !== 'function') return null;
    const state = api.create();
    authority.runtimeState = state;
    window.__JL_LUDO_RUNTIME_STATE__ = state;
    return state;
  }

  function installLayoutStability() {
    if (document.getElementById('jl-ludo-player-layout-stability')) return;
    const style = document.createElement('style');
    style.id = 'jl-ludo-player-layout-stability';
    style.textContent = `
      @media (max-width: 600px) {
        #playersPanel .player-card { min-height: 118px; }
        #playersPanel .player-flags {
          min-height: 38px;
          align-content: flex-start;
        }
      }
    `;
    document.head.appendChild(style);
  }

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

  function ensureRoomVisible(roomId = authority.activeRoomId) {
    const id = String(roomId || '').trim();
    if (!id) return false;
    const room = document.getElementById('room');
    if (!room) return false;

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
    return true;
  }

  function renderFallbackPlayersOnce(snapshot) {
    const target = document.getElementById('playersPanel');
    const room = snapshot?.room;
    if (!target || !room || target.childElementCount > 0) return false;

    const players = Array.isArray(snapshot.players) ? snapshot.players : [];
    const count = Math.max(2, Number(room.player_count) || 2);
    const fragment = document.createDocumentFragment();

    for (let seat = 1; seat <= count; seat += 1) {
      const player = players.find(item => Number(item.seat) === seat);
      const card = document.createElement('div');
      const current = Boolean(player && room.current_player_id === player.player_id);
      card.className = `player-card ${player?.color || ''} ${current ? 'current' : ''}`.trim();

      if (!player) {
        const small = document.createElement('small');
        small.textContent = `Vaga ${seat}`;
        const title = document.createElement('h3');
        title.textContent = 'Aguardando jogador…';
        card.append(small, title);
        fragment.appendChild(card);
        continue;
      }

      const dot = document.createElement('span');
      dot.className = 'color-dot';
      const position = document.createElement('small');
      position.textContent = `${player.team ? `Equipa ${player.team} · ` : ''}posição ${player.seat || seat}`;
      const title = document.createElement('h3');
      title.textContent = player.name || player.code || 'Jogador';
      const code = document.createElement('small');
      code.textContent = player.code || '';
      const flags = document.createElement('div');
      flags.className = 'player-flags';

      const accepted = player.accepted_rules_version === room.rules_version;
      const rules = document.createElement('span');
      rules.className = `flag ${accepted ? 'ok' : 'wait'}`;
      rules.textContent = accepted ? '✓ regras' : 'regras…';

      const stake = document.createElement('span');
      stake.className = `flag ${player.stake_paid ? 'ok' : 'wait'}`;
      stake.textContent = player.stake_paid ? '✓ aposta' : 'aposta…';

      const status = document.createElement('span');
      status.className = 'flag';
      status.textContent = player.status || 'active';

      flags.append(rules, stake, status);
      if (player.timeout_strikes) {
        const strikes = document.createElement('span');
        strikes.className = 'flag wait';
        strikes.textContent = `${player.timeout_strikes} atraso(s)`;
        flags.appendChild(strikes);
      }

      card.append(dot, position, title, code, flags);
      fragment.appendChild(card);
    }

    target.replaceChildren(fragment);
    return true;
  }

  function updateRecoveryMetadata(snapshot) {
    const roomData = snapshot?.room;
    if (!roomData) return;

    setText('roomCode', roomData.code || 'SALA');
    setText(
      'roomMeta',
      `${roomData.player_count || 0} jogadores · ${roomData.mode === 'partners' ? 'Parceiros 2 × 2' : 'Cada um por si'} · ${money(roomData.bet_amount)} MZN por jogador · ${roomData.is_public ? 'Pública' : 'Privada'}`
    );
    setText('roomPot', `${money(roomData.pot)} MZN`);
    setText('rulesVersion', `v${roomData.rules_version || 1}`);

    document.getElementById('leaveRoom')?.classList.toggle('hidden', started(roomData));
    document.getElementById('forfeitRoom')?.classList.toggle('hidden', !started(roomData));
    document.querySelector('.invite-panel')?.classList.toggle('hidden', !roomCanInvite(snapshot));
  }

  function applySnapshot(snapshot = authority.snapshot) {
    const roomData = snapshot?.room;
    if (!roomData) return false;

    authority.snapshot = snapshot;
    authority.activeRoomId = String(roomData.id || authority.activeRoomId || '');
    ensureRoomVisible(authority.activeRoomId);

    const state = authority.runtimeState || captureRuntimeState();
    if (state) {
      state.token = token();
      state.room = snapshot;
      if (!state.status) state.status = {};
      state.status.active_room_id = roomData.id;
    }

    updateRecoveryMetadata(snapshot);
    renderFallbackPlayersOnce(snapshot);

    if (authority.scrolledRoomId !== authority.activeRoomId) {
      authority.scrolledRoomId = authority.activeRoomId;
      requestAnimationFrame(() => {
        const room = document.getElementById('room');
        if (room && !room.classList.contains('hidden')) {
          room.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
      });
    }
    return true;
  }

  function showLobby(status = null) {
    authority.snapshot = null;
    authority.activeRoomId = '';
    authority.scrolledRoomId = '';

    const state = authority.runtimeState || captureRuntimeState();
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
    if (!playerToken) {
      showLobby();
      return;
    }

    if (typeof window.JLApi?.rpc !== 'function') {
      window.setTimeout(() => void refreshAuthority('api-retry'), 250);
      return;
    }

    authority.running = true;
    try {
      const status = await rpc('jl_ludo_my_status', { p_token: playerToken });
      const state = authority.runtimeState || captureRuntimeState();
      if (state) {
        state.token = playerToken;
        state.status = status;
      }

      const roomId = String(status?.active_room_id || '').trim();
      if (!roomId) {
        showLobby(status);
        return;
      }

      authority.activeRoomId = roomId;
      ensureRoomVisible(roomId);

      const snapshot = await rpc('jl_ludo_room_state_light', { p_token: playerToken, p_room: roomId });
      authority.snapshot = snapshot;
      if (state) state.room = snapshot;
      applySnapshot(snapshot);

      window.dispatchEvent(new CustomEvent('jl-ludo-authoritative-room', {
        detail: { roomId, snapshot, reason }
      }));
      window.JLLudoSync?.kick?.('ludo-state');
    } catch (error) {
      console.warn('ludo room authority', reason, error?.message || error);
      if (authority.activeRoomId) ensureRoomVisible(authority.activeRoomId);
    } finally {
      authority.running = false;
    }
  }

  function installDomGuard() {
    const root = document.querySelector('main.shell') || document.body;
    if (!root) return;

    new MutationObserver(() => {
      if (!authority.activeRoomId) return;
      const room = document.getElementById('room');
      const board = document.getElementById('boardLobby');
      const lobby = document.getElementById('lobby');
      const wrongVisibility =
        room?.classList.contains('hidden') ||
        !board?.classList.contains('hidden') ||
        !lobby?.classList.contains('hidden');
      if (wrongVisibility) queueMicrotask(() => ensureRoomVisible(authority.activeRoomId));
    }).observe(root, {
      attributes: true,
      subtree: true,
      attributeFilter: ['class', 'hidden', 'style']
    });
  }

  function install() {
    installLayoutStability();
    captureRuntimeState();
    installDomGuard();
    void refreshAuthority('startup');

    clearInterval(authority.refreshTimer);
    authority.refreshTimer = window.setInterval(() => void refreshAuthority('periodic'), 5000);

    window.addEventListener('pageshow', () => void refreshAuthority('pageshow'));
    window.addEventListener('focus', () => void refreshAuthority('focus'));
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') void refreshAuthority('visible');
    });
    window.addEventListener('jl-player-session-changed', event => {
      if (event.detail?.authenticated) void refreshAuthority('session');
      else showLobby();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();
