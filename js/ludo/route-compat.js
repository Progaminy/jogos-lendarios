(() => {
  'use strict';

  const TOKEN_KEY = 'jl_player_token';
  let stickyRoomId = '';
  let confirmTimer = 0;
  let scrollRoomId = '';
  let createBoardFocusPending = false;
  let createBoardFocusTimer = 0;
  let createBoardFocusDeadline = 0;
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
    scrollRoomId = '';
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
      authority.scrolledRoomId = '';
    }
  }

  function showLobbyAfterLeave() {
    clearRememberedRoom();
    clearLegacyActiveRoomState();
    document.body.classList.remove('ludo-pinned');
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
      if (roomId) {
        finishLeaveTransition({ restoreRoomId: roomId });
      } else {
        finishLeaveTransition();
      }
    } catch {
      leaveRoomConfirmTimer = window.setTimeout(() => void confirmLeaveResult(), 350);
    }
  }

  function armLeaveRoomTransition() {
    if (leaveRoomPending) return;
    leaveRoomPending = true;
    createBoardFocusPending = false;
    clearTimeout(createBoardFocusTimer);
    createBoardFocusTimer = 0;
    createBoardFocusDeadline = 0;
    showLobbyAfterLeave();
    clearTimeout(leaveRoomConfirmTimer);
    leaveRoomConfirmTimer = window.setTimeout(() => void confirmLeaveResult(), 220);
  }

  function installPinnedBoardFix() {
    if (document.getElementById('jl-ludo-pin-fix')) return;
    const style = document.createElement('style');
    style.id = 'jl-ludo-pin-fix';
    style.textContent = `
      html body.ludo-pinned #room {
        content-visibility: visible !important;
        contain: none !important;
        overflow: visible !important;
      }

      html body.ludo-pinned #gamePanel {
        overflow: visible !important;
      }

      html body.ludo-pinned #gamePanel > .board-panel {
        position: sticky !important;
        top: calc(var(--ludo-sticky-top, 64px) + 6px) !important;
        right: auto !important;
        bottom: auto !important;
        left: auto !important;
        inset: auto !important;
        z-index: 35 !important;
        transform: none !important;
        width: 100% !important;
        max-width: none !important;
        max-height: calc(100dvh - var(--ludo-sticky-top, 64px) - 12px) !important;
        overflow: auto !important;
        overscroll-behavior: contain;
      }

      html body.ludo-pinned #ludoBoard {
        position: relative !important;
        z-index: 1 !important;
        scroll-margin-top: 4px !important;
      }

      html body.ludo-pinned .pin-ludo-button {
        position: sticky;
        bottom: 8px;
        z-index: 4;
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
        html body.ludo-pinned #gamePanel > .board-panel {
          top: calc(var(--ludo-sticky-top, 56px) + 4px) !important;
          max-height: calc(100dvh - var(--ludo-sticky-top, 56px) - 8px) !important;
          padding: 10px !important;
        }
      }
    `;
    document.head.appendChild(style);
  }

  function boardFocusTarget() {
    return document.querySelector('#gamePanel .board-panel')
      || document.getElementById('ludoBoard')
      || document.getElementById('gamePanel');
  }

  function elementDocumentTop(element) {
    let top = 0;
    let current = element;
    while (current) {
      top += Number(current.offsetTop) || 0;
      current = current.offsetParent;
    }
    return top;
  }

  function directPinnedBoardIntoView(button = null) {
    if (!document.body.classList.contains('ludo-pinned')) return false;
    const gamePanel = document.getElementById('gamePanel');
    const panel = document.querySelector('#gamePanel > .board-panel');
    const board = document.getElementById('ludoBoard');
    if (!panel || !gamePanel || gamePanel.classList.contains('hidden') || !board) return false;

    button?.blur?.();

    try {
      const url = new URL(window.location.href);
      if (stickyRoomId) url.searchParams.set('room', stickyRoomId);
      url.hash = 'ludoBoard';
      window.history.replaceState(window.history.state, '', url.toString());
    } catch {
      window.location.hash = 'ludoBoard';
    }

    const moveToBoard = (behavior = 'auto') => {
      if (!document.body.classList.contains('ludo-pinned')) return;
      const topbarHeight = document.querySelector('.topbar')?.getBoundingClientRect().height || 0;
      const destination = Math.max(0, elementDocumentTop(panel) - topbarHeight - 6);

      panel.scrollTop = 0;
      window.scrollTo({ top: destination, behavior });

      requestAnimationFrame(() => {
        if (!document.body.classList.contains('ludo-pinned')) return;
        const boardInsidePanel = Math.max(0, Number(board.offsetTop) - 4);
        panel.scrollTo({ top: boardInsidePanel, behavior: 'auto' });
      });
    };

    requestAnimationFrame(() => requestAnimationFrame(() => moveToBoard('auto')));
    window.setTimeout(() => moveToBoard('smooth'), 120);
    window.setTimeout(() => moveToBoard('auto'), 320);
    return true;
  }

  function installPinButtonRedirect() {
    if (!isLudoPath()) return;
    document.addEventListener('click', event => {
      const button = event.target?.closest?.('#pinLudo');
      if (!button) return;
      window.setTimeout(() => {
        if (document.body.classList.contains('ludo-pinned')) {
          directPinnedBoardIntoView(button);
        }
      }, 0);
    });
  }

  function installLeaveRoomGuard() {
    if (!isLudoPath()) return;
    document.addEventListener('click', event => {
      if (!event.target?.closest?.('#leaveRoom')) return;
      armLeaveRoomTransition();
    }, true);
  }

  function focusCreatedRoomBoard() {
    if (!createBoardFocusPending || leaveRoomPending) return false;

    const room = document.getElementById('room');
    const gamePanel = document.getElementById('gamePanel');
    const board = document.getElementById('ludoBoard');
    const target = boardFocusTarget();
    const roomVisible = Boolean(room && !room.classList.contains('hidden') && !room.hidden);
    const boardReady = Boolean(
      target &&
      gamePanel &&
      !gamePanel.classList.contains('hidden') &&
      board &&
      board.childElementCount > 0
    );

    if (!roomVisible || !boardReady) return false;

    createBoardFocusPending = false;
    clearTimeout(createBoardFocusTimer);
    createBoardFocusTimer = 0;
    createBoardFocusDeadline = 0;
    if (stickyRoomId) scrollRoomId = stickyRoomId;

    try {
      const url = new URL(window.location.href);
      if (stickyRoomId) url.searchParams.set('room', stickyRoomId);
      url.hash = 'ludoBoard';
      window.history.replaceState(window.history.state, '', url.toString());
    } catch {
      window.location.hash = 'ludoBoard';
    }

    target.style.scrollMarginTop = 'calc(var(--ludo-sticky-top, 64px) + 10px)';
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      });
    });
    return true;
  }

  function armCreateBoardFocus() {
    if (leaveRoomPending) return;
    createBoardFocusPending = true;
    createBoardFocusDeadline = Date.now() + 12000;
    clearTimeout(createBoardFocusTimer);

    const tick = () => {
      if (!createBoardFocusPending) return;
      if (focusCreatedRoomBoard()) return;
      if (Date.now() >= createBoardFocusDeadline) {
        createBoardFocusPending = false;
        createBoardFocusTimer = 0;
        createBoardFocusDeadline = 0;
        return;
      }
      createBoardFocusTimer = window.setTimeout(tick, 80);
    };

    createBoardFocusTimer = window.setTimeout(tick, 0);
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

    if (createBoardFocusPending) {
      focusCreatedRoomBoard();
    } else if (scrollRoomId !== id) {
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
    if (!isLudoPath() || leaveRoomPending) return;
    const stateRoomId = String(recoveryState()?.activeRoomId || '').trim();
    if (stateRoomId) rememberRoom(stateRoomId);
    if (stickyRoomId) forceRoomVisible(stickyRoomId);
    if (createBoardFocusPending) focusCreatedRoomBoard();
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
        focusCreatedRoomBoard();
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

  function installCreateRoomBoardRedirect() {
    if (!isLudoPath()) return;
    document.addEventListener('submit', event => {
      if (event.target?.id !== 'createRoomForm') return;
      armCreateBoardFocus();
    }, true);

    window.addEventListener('jl-ludo-authoritative-room', event => {
      if (leaveRoomPending) return;
      const roomId = String(event.detail?.roomId || event.detail?.snapshot?.room?.id || '').trim();
      if (roomId) {
        rememberRoom(roomId);
        forceRoomVisible(roomId);
      }
      focusCreatedRoomBoard();
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

  installPinnedBoardFix();
  repairLudoHeader();
  installPinButtonRedirect();
  installLeaveRoomGuard();
  installCreateRoomBoardRedirect();
  installActiveRoomVisibilityGuard();
  document.addEventListener('DOMContentLoaded', () => {
    installPinnedBoardFix();
    repairLudoHeader();
    syncConfirmedRoom();
    scheduleAuthoritativeConfirm(120);
  }, { once: true });
})();