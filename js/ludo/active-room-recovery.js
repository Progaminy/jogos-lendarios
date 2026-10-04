(() => {
  'use strict';

  if (window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__) return;
  window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__ = true;

  const TOKEN_KEY = 'jl_player_token';
  let recovering = false;
  let redirectedRoomId = '';

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
      // renderDeadline atualiza o rótulo/relógio, mas a barra vinha presa em .hidden.
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

  async function recoverActiveRoom() {
    if (recovering) return;
    const playerToken = token();
    const rpc = window.JLApi?.rpc;
    if (!playerToken || typeof rpc !== 'function') return;

    recovering = true;
    try {
      const status = await rpc('jl_ludo_my_status', { p_token: playerToken });
      const roomId = String(status?.active_room_id || '').trim();
      if (!roomId) return;

      if (focusWhenRendered(roomId)) return;
      if (redirectedRoomId === roomId) return;

      redirectedRoomId = roomId;
      window.location.replace(roomUrl(roomId).toString());
    } catch {
      // O fluxo principal do Ludo continua responsável por mostrar erros.
    } finally {
      recovering = false;
    }
  }

  function install() {
    restoreRoomCountdown();

    const toast = document.getElementById('toast');
    if (toast) {
      const inspectToast = () => {
        if (isActiveRoomMessage(toast.textContent)) void recoverActiveRoom();
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

    // Se já existe uma sala, abre essa sala em vez de deixar o jogador preso no lobby.
    void recoverActiveRoom();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();
