(() => {
  'use strict';

  const TOKEN_KEY = 'jl_player_token';
  let stickyRoomId = '';
  let confirmTimer = 0;
  let leaveRoomPending = false;
  let leaveRoomConfirmTimer = 0;

  function normalizedPath() {
    return String(window.location.pathname || '/')
      .replace(/\/+$/, '')
      .toLowerCase();
  }

  function hasLudoDom() {
    return Boolean(
      document.getElementById('ludoLobbyBoard') &&
      document.getElementById('room') &&
      document.getElementById('createRoomForm')
    );
  }

  function isLudoPath() {
    const path = normalizedPath();
    return path.endsWith('/ludo') || path.endsWith('/ludo.html') || hasLudoDom();
  }

  function token() {
    try {
      return window.JLSession?.getPlayerToken?.()
        || localStorage.getItem(TOKEN_KEY)
        || '';
    } catch {
      return '';
    }
  }

  function recoveryState() {
    const value = window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__;
    return value && typeof value === 'object' ? value : null;
  }

  function rememberRoom(roomId) {
    const id = String(roomId || '').trim();
    if (!id) return false;
    stickyRoomId = id;
    document.documentElement.dataset.jlConfirmedActiveLudoRoom = id;
    return true;
  }

  function clearRememberedRoom() {
    stickyRoomId = '';
    delete document.documentElement.dataset.jlConfirmedActiveLudoRoom;
  }

  function clearLegacyActiveRoomState() {
    const recovery = recoveryState();
    if (recovery) {
      recovery.activeRoomId = '';
      recovery.pending = false;
      recovery.resolved = true;
      recovery.rescueActive = false;
    }

    const authority = window.__JL_LUDO_ROOM_AUTHORITY_V1__;
    if (authority && typeof authority === 'object') {
      authority.snapshot = null;
      authority.activeRoomId = '';
    }
  }

  function installBoardLayoutStyle() {
    if (document.getElementById('jl-ludo-board-first-style')) return;
    const style = document.createElement('style');
    style.id = 'jl-ludo-board-first-style';
    style.textContent = `
      #room > #gamePanel.game-grid:not(.hidden) {
        display: grid !important;
        grid-template-columns: minmax(0, 1fr) !important;
        gap: 12px !important;
        margin-top: 0 !important;
      }

      #gamePanel > .board-panel {
        width: 100% !important;
        min-width: 0 !important;
      }

      #gamePanel > .side-column {
        width: 100% !important;
        min-width: 0 !important;
      }

      #gamePanel .dice-tools {
        display: flex !important;
        align-items: center !important;
        justify-content: flex-end !important;
        flex-wrap: wrap !important;
        gap: 6px !important;
      }

      #muteOpponent.quick-listen,
      #pinLudo.quick-pin {
        width: auto !important;
        min-width: 0 !important;
        margin: 0 !important;
        white-space: nowrap !important;
      }

      #muteOpponent.quick-listen {
        font-size: 0 !important;
      }

      #muteOpponent.quick-listen::after {
        content: '🔊 Ouvir';
        font-size: .82rem;
      }

      #muteOpponent.quick-listen[aria-pressed='true']::after {
        content: '🔇 Mudo';
      }

      #turnTitle .turn-player-name {
        font-size: 1.14em !important;
        font-weight: 850 !important;
      }

      html body.ludo-pinned {
        overflow: hidden !important;
      }

      html body.ludo-pinned #room {
        content-visibility: visible !important;
        contain: none !important;
        overflow: visible !important;
      }

      html body.ludo-pinned #gamePanel > .board-panel {
        position: fixed !important;
        top: calc(var(--ludo-sticky-top, 64px) + 4px) !important;
        left: 50% !important;
        right: auto !important;
        bottom: auto !important;
        transform: translateX(-50%) !important;
        z-index: 80 !important;
        width: min(calc(100vw - 16px), 1120px) !important;
        max-width: 1120px !important;
        max-height: calc(100dvh - var(--ludo-sticky-top, 64px) - 8px) !important;
        overflow: auto !important;
        overscroll-behavior: contain !important;
      }

      html body.jl-ludo-leaving #room {
        display: none !important;
      }

      html body.jl-ludo-leaving #lobby {
        display: grid !important;
      }

      html body.jl-ludo-leaving #boardLobby {
        display: block !important;
      }

      @media (max-width: 600px) {
        #gamePanel .dice-tools {
          justify-content: flex-start !important;
        }

        html body.ludo-pinned #gamePanel > .board-panel {
          top: calc(var(--ludo-sticky-top, 56px) + 3px) !important;
          width: calc(100vw - 8px) !important;
          max-height: calc(100dvh - var(--ludo-sticky-top, 56px) - 6px) !important;
          padding: 8px !important;
        }
      }
    `;
    document.head.appendChild(style);
  }

  function installBoardFirstLayout() {
    if (!isLudoPath()) return;
    const room = document.getElementById('room');
    const gamePanel = document.getElementById('gamePanel');
    if (room && gamePanel && room.firstElementChild !== gamePanel) {
      room.insertBefore(gamePanel, room.firstElementChild);
    }

    const tools = document.querySelector('#gamePanel .dice-tools');
    const listen = document.getElementById('muteOpponent');
    const pin = document.getElementById('pinLudo');

    if (tools && listen && listen.parentElement !== tools) {
      listen.classList.remove('wide');
      listen.classList.add('sound-toggle', 'quick-listen');
      listen.setAttribute('aria-label', 'Ouvir ou silenciar adversário');
      tools.appendChild(listen);
    }

    if (tools && pin && pin.parentElement !== tools) {
      pin.classList.add('sound-toggle', 'quick-pin');
      tools.appendChild(pin);
    }
  }

  function installSinglePinControl() {
    const current = document.getElementById('pinLudo');
    if (!current || current.dataset.jlSinglePin === '1') return;

    const fresh = current.cloneNode(true);
    fresh.dataset.jlSinglePin = '1';
    fresh.classList.add('sound-toggle', 'quick-pin');
    fresh.setAttribute('aria-pressed', 'false');
    fresh.textContent = '📌 Fixar';
    current.replaceWith(fresh);

    fresh.addEventListener('click', () => {
      const pinned = document.body.classList.toggle('ludo-pinned');
      fresh.setAttribute('aria-pressed', pinned ? 'true' : 'false');
      fresh.textContent = pinned ? '↩ Desfixar' : '📌 Fixar';
    });
  }

  function resetPinState() {
    document.body.classList.remove('ludo-pinned');
    const pin = document.getElementById('pinLudo');
    if (!pin) return;
    pin.setAttribute('aria-pressed', 'false');
    pin.textContent = '📌 Fixar';
  }

  function showLobbyAfterLeave() {
    clearRememberedRoom();
    clearLegacyActiveRoomState();
    resetPinState();
    document.body.classList.add('jl-ludo-leaving');

    const room = document.getElementById('room');
    if (room) {
      room.classList.add('hidden');
      room.hidden = true;
      room.setAttribute('aria-hidden', 'true');
    }

    document.getElementById('lobby')?.classList.remove('hidden');
    document.getElementById('boardLobby')?.classList.remove('hidden');
    document.getElementById('loggedOut')?.classList.add('hidden');
    document.getElementById('notificationCenter')?.classList.remove('hidden');
    document.getElementById('ludoStatusStrip')?.classList.remove('hidden');

    try {
      const url = new URL(window.location.href);
      url.searchParams.delete('room');
      if (url.hash === '#room' || url.hash === '#ludoBoard') url.hash = '';
      window.history.replaceState(window.history.state, '', url.toString());
    } catch {}
  }

  function finishLeaveTransition({ restoreRoomId = '' } = {}) {
    leaveRoomPending = false;
    clearTimeout(leaveRoomConfirmTimer);
    leaveRoomConfirmTimer = 0;
    document.body.classList.remove('jl-ludo-leaving');

    const id = String(restoreRoomId || '').trim();
    if (id) {
      rememberRoom(id);
      forceRoomVisible(id);
      return;
    }

    clearRememberedRoom();
    clearLegacyActiveRoomState();
    const room = document.getElementById('room');
    if (room) {
      room.classList.add('hidden');
      room.hidden = true;
      room.setAttribute('aria-hidden', 'true');
    }
    document.getElementById('lobby')?.classList.remove('hidden');
    document.getElementById('boardLobby')?.classList.remove('hidden');
  }

  async function confirmLeaveResult() {
    if (!leaveRoomPending) return;
    const playerToken = token();
    const rpc = window.JLApi?.rpc;
    if (!playerToken || typeof rpc !== 'function') {
      leaveRoomConfirmTimer = window.setTimeout(() => void confirmLeaveResult(), 250);
      return;
    }

    try {
      const status = await rpc('jl_ludo_my_status', { p_token: playerToken });
      const roomId = String(status?.active_room_id || '').trim();
      if (roomId) finishLeaveTransition({ restoreRoomId: roomId });
      else finishLeaveTransition();
    } catch {
      leaveRoomConfirmTimer = window.setTimeout(() => void confirmLeaveResult(), 350);
    }
  }

  function armLeaveRoomTransition() {
    if (leaveRoomPending) return;
    leaveRoomPending = true;
    showLobbyAfterLeave();
    clearTimeout(leaveRoomConfirmTimer);
    leaveRoomConfirmTimer = window.setTimeout(() => void confirmLeaveResult(), 220);
  }

  function installLeaveRoomGuard() {
    if (!isLudoPath()) return;
    document.addEventListener('click', event => {
      if (!event.target?.closest?.('#leaveRoom')) return;
      armLeaveRoomTransition();
    }, true);
  }

  function forceRoomVisible(roomId = '') {
    if (!isLudoPath() || leaveRoomPending) return false;
    const id = String(roomId || stickyRoomId || recoveryState()?.activeRoomId || '').trim();
    if (!id) return false;
    rememberRoom(id);

    const room = document.getElementById('room');
    if (!room) return false;

    room.hidden = false;
    room.removeAttribute('hidden');
    room.removeAttribute('aria-hidden');
    room.style.removeProperty('display');
    room.classList.remove('hidden');

    document.getElementById('lobby')?.classList.add('hidden');
    document.getElementById('boardLobby')?.classList.add('hidden');
    document.getElementById('loggedOut')?.classList.add('hidden');
    document.getElementById('ludoStatusStrip')?.classList.remove('hidden');
    document.getElementById('notificationCenter')?.classList.remove('hidden');
    return true;
  }

  function syncConfirmedRoom() {
    if (!isLudoPath() || leaveRoomPending) return;
    const stateRoomId = String(recoveryState()?.activeRoomId || '').trim();
    if (stateRoomId) rememberRoom(stateRoomId);
    if (stickyRoomId) forceRoomVisible(stickyRoomId);
  }

  async function confirmAuthoritativeRoom() {
    if (!isLudoPath()) return;
    const playerToken = token();
    if (!playerToken) {
      if (leaveRoomPending) finishLeaveTransition();
      else clearRememberedRoom();
      return;
    }
    const rpc = window.JLApi?.rpc;
    if (typeof rpc !== 'function') return;

    try {
      const status = await rpc('jl_ludo_my_status', { p_token: playerToken });
      const roomId = String(status?.active_room_id || '').trim();
      if (leaveRoomPending) {
        finishLeaveTransition({ restoreRoomId: roomId });
        return;
      }
      if (roomId) {
        rememberRoom(roomId);
        forceRoomVisible(roomId);
      } else {
        clearRememberedRoom();
        clearLegacyActiveRoomState();
      }
    } catch {
      if (!leaveRoomPending) syncConfirmedRoom();
    }
  }

  function scheduleAuthoritativeConfirm(delay = 450) {
    clearTimeout(confirmTimer);
    confirmTimer = window.setTimeout(() => {
      confirmTimer = 0;
      void confirmAuthoritativeRoom();
    }, delay);
  }

  function repairLudoHeader() {
    if (!isLudoPath()) return;

    const currentRefresh = document.getElementById('refreshLobby');
    const genericRefresh = document.getElementById('jlHeaderRefresh');
    if (!currentRefresh && genericRefresh) genericRefresh.id = 'refreshLobby';

    document.querySelectorAll('.game-nav [data-jl-nav]').forEach(link => {
      link.classList.toggle('active', link.dataset.jlNav === 'tabuleiro');
    });
  }

  function installRoomTracking() {
    if (!isLudoPath()) return;
    window.addEventListener('jl-ludo-authoritative-room', event => {
      if (leaveRoomPending) return;
      const roomId = String(event.detail?.roomId || event.detail?.snapshot?.room?.id || '').trim();
      if (roomId) {
        rememberRoom(roomId);
        forceRoomVisible(roomId);
      }
    });
  }

  function installActiveRoomVisibilityGuard() {
    if (!isLudoPath()) return;

    window.addEventListener('jl-ludo-active-room-recovery', event => {
      if (leaveRoomPending) return;
      const roomId = String(event.detail?.activeRoomId || '').trim();
      if (roomId) {
        rememberRoom(roomId);
        forceRoomVisible(roomId);
      } else if (token()) {
        scheduleAuthoritativeConfirm();
      } else {
        clearRememberedRoom();
      }
    });

    window.addEventListener('jl-player-session-changed', event => {
      if (event.detail?.authenticated) scheduleAuthoritativeConfirm(120);
      else if (!token()) {
        if (leaveRoomPending) finishLeaveTransition();
        else clearRememberedRoom();
      } else scheduleAuthoritativeConfirm();
    });

    window.addEventListener('pageshow', () => {
      repairLudoHeader();
      installBoardFirstLayout();
      syncConfirmedRoom();
      scheduleAuthoritativeConfirm(120);
    });

    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState !== 'visible') return;
      syncConfirmedRoom();
      scheduleAuthoritativeConfirm(150);
    });

    window.setInterval(syncConfirmedRoom, 350);
    scheduleAuthoritativeConfirm(250);
  }

  installBoardLayoutStyle();
  installBoardFirstLayout();
  repairLudoHeader();
  installLeaveRoomGuard();
  installRoomTracking();
  installActiveRoomVisibilityGuard();

  document.addEventListener('DOMContentLoaded', () => {
    installBoardLayoutStyle();
    installBoardFirstLayout();
    installSinglePinControl();
    repairLudoHeader();
    syncConfirmedRoom();
    scheduleAuthoritativeConfirm(120);
  }, { once: true });
})();
