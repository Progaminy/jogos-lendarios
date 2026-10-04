(() => {
  'use strict';

  const TOKEN_KEY = 'jl_player_token';
  let stickyRoomId = '';
  let confirmTimer = 0;
  let scrollRoomId = '';

  function normalizedPath() {
    return String(window.location.pathname || '/')
      .replace(/\/+$/, '')
      .toLowerCase();
  }

  function isLudoPath() {
    const path = normalizedPath();
    return path.endsWith('/ludo') || path.endsWith('/ludo.html');
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
    scrollRoomId = '';
    delete document.documentElement.dataset.jlConfirmedActiveLudoRoom;
  }

  function forceRoomVisible(roomId = '') {
    if (!isLudoPath()) return false;
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

    if (scrollRoomId !== id) {
      scrollRoomId = id;
      requestAnimationFrame(() => {
        const currentRoom = document.getElementById('room');
        if (currentRoom && !currentRoom.classList.contains('hidden')) {
          currentRoom.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
      });
    }
    return true;
  }

  function syncConfirmedRoom() {
    if (!isLudoPath()) return;
    const stateRoomId = String(recoveryState()?.activeRoomId || '').trim();
    if (stateRoomId) rememberRoom(stateRoomId);
    if (stickyRoomId) forceRoomVisible(stickyRoomId);
  }

  async function confirmAuthoritativeRoom() {
    if (!isLudoPath()) return;
    const playerToken = token();
    if (!playerToken) {
      clearRememberedRoom();
      return;
    }
    const rpc = window.JLApi?.rpc;
    if (typeof rpc !== 'function') return;

    try {
      const status = await rpc('jl_ludo_my_status', { p_token: playerToken });
      const roomId = String(status?.active_room_id || '').trim();
      if (roomId) {
        rememberRoom(roomId);
        forceRoomVisible(roomId);
      } else {
        clearRememberedRoom();
      }
    } catch {
      // Em falha transitória, não apagar uma sala já confirmada.
      syncConfirmedRoom();
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

  function installActiveRoomVisibilityGuard() {
    if (!isLudoPath()) return;

    window.addEventListener('jl-ludo-active-room-recovery', event => {
      const roomId = String(event.detail?.activeRoomId || '').trim();
      if (roomId) {
        rememberRoom(roomId);
        forceRoomVisible(roomId);
      } else if (token()) {
        // Um evento vazio pode ser apenas uma corrida de sessão/UI.
        // Só libertamos a sala depois de confirmação autoritativa do servidor.
        scheduleAuthoritativeConfirm();
      } else {
        clearRememberedRoom();
      }
    });

    window.addEventListener('jl-player-session-changed', event => {
      if (event.detail?.authenticated) scheduleAuthoritativeConfirm(120);
      else if (!token()) clearRememberedRoom();
      else scheduleAuthoritativeConfirm();
    });

    window.addEventListener('pageshow', () => {
      repairLudoHeader();
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

  repairLudoHeader();
  installActiveRoomVisibilityGuard();
  document.addEventListener('DOMContentLoaded', () => {
    repairLudoHeader();
    syncConfirmedRoom();
    scheduleAuthoritativeConfirm(120);
  }, { once: true });
})();
