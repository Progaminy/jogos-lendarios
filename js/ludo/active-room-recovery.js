(() => {
  'use strict';

  if (window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__) return;
  window.__JL_LUDO_ACTIVE_ROOM_RECOVERY__ = true;

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  let recovering = false;
  let redirectedRoomId = '';

  function token() {
    return window.JLSession?.getPlayerToken?.()
      || localStorage.getItem(TOKEN_KEY)
      || '';
  }

  async function rpc(name, args = {}) {
    if (!cfg.supabaseUrl || !cfg.supabaseKey) throw new Error('Configuração do servidor indisponível.');
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
    let data = null;
    try { data = raw ? JSON.parse(raw) : null; } catch { data = raw; }
    if (!response.ok) throw new Error(data?.message || data?.hint || data?.error || `Erro ${response.status}`);
    return data;
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
      && (text.includes('ja participa') || text.includes('participa'));
  }

  function roomUrl(roomId) {
    const url = new URL(window.location.href);
    url.pathname = url.pathname.replace(/[^/]*$/, 'ludo.html');
    url.searchParams.set('room', roomId);
    url.hash = 'room';
    return url;
  }

  function focusExistingRoom(roomId) {
    const current = new URL(window.location.href);
    if (current.searchParams.get('room') !== roomId) return false;

    const focus = () => {
      const room = document.getElementById('room');
      if (!room) return false;
      room.classList.remove('hidden');
      room.scrollIntoView({ behavior: 'smooth', block: 'start' });
      return true;
    };

    if (focus()) return true;
    let attempts = 0;
    const timer = setInterval(() => {
      attempts += 1;
      if (focus() || attempts >= 20) clearInterval(timer);
    }, 150);
    return true;
  }

  async function recoverActiveRoom() {
    if (recovering) return;
    const playerToken = token();
    if (!playerToken) return;

    recovering = true;
    try {
      const status = await rpc('jl_ludo_my_status', { p_token: playerToken });
      const roomId = String(status?.active_room_id || '').trim();
      if (!roomId) return;

      if (focusExistingRoom(roomId)) return;
      if (redirectedRoomId === roomId) return;
      redirectedRoomId = roomId;
      window.location.replace(roomUrl(roomId).toString());
    } catch {
      // Mantém a mensagem original. A recuperação é auxiliar e não deve mascarar o erro real.
    } finally {
      recovering = false;
    }
  }

  function install() {
    const toast = document.getElementById('toast');
    if (!toast) return;

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

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, { once: true });
  else install();
})();
