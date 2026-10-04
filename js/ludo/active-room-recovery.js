(() => {
  'use strict';

  const KEY = '__JL_LUDO_ACTIVE_ROOM_RECOVERY__';
  const TOKEN_KEY = 'jl_player_token';
  const existing = window[KEY];
  if (existing && typeof existing === 'object' && existing.installed) return;

  const state = existing && typeof existing === 'object' ? existing : {};
  Object.assign(state, {
    installed: true,
    pending: false,
    resolved: true,
    activeRoomId: '',
    lastError: '',
    rescueActive: false,
    passive: true
  });
  window[KEY] = state;

  let running = false;
  let retryTimer = 0;
  let periodicTimer = 0;

  function token() {
    try {
      return window.JLSession?.getPlayerToken?.() || localStorage.getItem(TOKEN_KEY) || '';
    } catch {
      return '';
    }
  }

  function emit() {
    window.dispatchEvent(new CustomEvent('jl-ludo-active-room-recovery', {
      detail: {
        pending: Boolean(state.pending),
        resolved: Boolean(state.resolved),
        activeRoomId: String(state.activeRoomId || ''),
        rescueActive: false,
        passive: true
      }
    }));
  }

  function resolve(roomId = '') {
    state.pending = false;
    state.resolved = true;
    state.activeRoomId = String(roomId || '').trim();
    state.lastError = '';
    state.rescueActive = false;
    emit();
  }

  async function refresh(reason = 'refresh') {
    if (running) return;
    const playerToken = token();
    if (!playerToken) {
      resolve('');
      return;
    }

    const rpc = window.JLApi?.rpc;
    if (typeof rpc !== 'function') {
      state.pending = true;
      state.resolved = false;
      state.lastError = 'api-not-ready';
      emit();
      clearTimeout(retryTimer);
      retryTimer = window.setTimeout(() => void refresh('api-retry'), 250);
      return;
    }

    running = true;
    state.pending = true;
    state.resolved = false;
    emit();
    try {
      const status = await rpc('jl_ludo_my_status', { p_token: playerToken });
      resolve(status?.active_room_id || '');
    } catch (error) {
      state.pending = false;
      state.resolved = true;
      state.lastError = String(error?.message || reason || 'status-failed');
      state.rescueActive = false;
      emit();
    } finally {
      running = false;
    }
  }

  function install() {
    // Compatibility only: this module no longer renders or mutates the room DOM.
    // room-authority-v1.js and ludo.js are the only UI owners.
    void refresh('startup');
    clearInterval(periodicTimer);
    periodicTimer = window.setInterval(() => void refresh('periodic'), 5000);

    window.addEventListener('pageshow', () => void refresh('pageshow'));
    window.addEventListener('focus', () => void refresh('focus'));
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') void refresh('visible');
    });
    window.addEventListener('jl-player-session-changed', event => {
      if (event.detail?.authenticated) void refresh('session');
      else resolve('');
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();
