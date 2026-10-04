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
    lastError: ''
  });
  window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__ = recoveryState;

  const TOKEN_KEY = 'jl_player_token';
  const MAX_API_READY_RETRIES = 25;
  const API_READY_RETRY_MS = 200;
  const MAX_STATUS_RETRIES = 4;
  const STATUS_RETRY_MS = 700;

  let recovering = false;
  let redirectedRoomId = '';
  let apiReadyRetries = 0;
  let statusRetries = 0;
  let retryTimer = 0;

  function token() {
    return window.JLSession?.getPlayerToken?.()
      || localStorage.getItem(TOKEN_KEY)
      || '';
  }

  function normalizedText(value) {
    return String(value || '')
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .toLowerCase();
  }

  function isActiveRoomMessage(message) {
    const text = normalizedText(message);
    return text.includes('sala')
      && text.includes('ativa')
      && text.includes('participa');
  }

  function emitState() {
    window.dispatchEvent(new CustomEvent('jl-ludo-active-room-recovery', {
      detail: {
        pending: Boolean(recoveryState.pending),
        resolved: Boolean(recoveryState.resolved),
        activeRoomId: String(recoveryState.activeRoomId || '')
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

  function roomUrl(roomId) {
    const url = new URL(window.location.href);
    url.pathname = url.pathname.replace(/[^/]*$/, 'ludo.html');
    url.searchParams.set('room', roomId);
    url.hash = 'room';
    return url;
  }

  function focusWhenRendered(roomId) {
    const current = new URL(window.location.href);
    if (current.searchParams.get('room') !== roomId) return false;

    const room = document.getElementById('room');
    if (!room) return true;

    const focus = () => {
      if (room.classList.contains('hidden')) return false;
      room.scrollIntoView({ behavior: 'smooth', block: 'start' });
      return true;
    };

    if (focus()) return true;

    const observer = new MutationObserver(() => {
      if (!focus()) return;
      observer.disconnect();
    });
    observer.observe(room, { attributes: true, attributeFilter: ['class'] });
    setTimeout(() => observer.disconnect(), 10000);
    return true;
  }

  function restoreRoomCountdown() {
    const room = document.getElementById('room');
    const bar = document.getElementById('deadlineBar');
    const label = document.getElementById('deadlineLabel');
    if (!room || !bar || !label) return;

    const sync = () => {
      if (room.classList.contains('hidden')) return;
      bar.classList.remove('hidden');
      bar.removeAttribute('aria-hidden');
    };

    new MutationObserver(sync).observe(room, {
      attributes: true,
      attributeFilter: ['class']
    });
    new MutationObserver(sync).observe(label, {
      childList: true,
      characterData: true,
      subtree: true
    });
    sync();
  }

  async function recoverActiveRoom(reason = 'startup') {
    if (recovering) return;

    const playerToken = token();
    if (!playerToken) {
      apiReadyRetries = 0;
      statusRetries = 0;
      markResolved('');
      return;
    }

    const rpc = window.JLApi?.rpc;
    if (typeof rpc !== 'function') {
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
      markResolved(roomId);

      if (!roomId) return;
      if (focusWhenRendered(roomId)) return;
      if (redirectedRoomId === roomId) return;

      redirectedRoomId = roomId;
      window.location.replace(roomUrl(roomId).toString());
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
    restoreRoomCountdown();

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

    void recoverActiveRoom('startup');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();
