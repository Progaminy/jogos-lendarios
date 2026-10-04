(() => {
  'use strict';

  if (!String(location.pathname || '').toLowerCase().endsWith('/dama.html')) return;

  const ROOM_KEY = 'jl_dama_room_id';
  let busy = false;

  function token() {
    return window.JLSession?.getPlayerToken?.() || '';
  }

  function roomId() {
    return new URL(location.href).searchParams.get('room') || localStorage.getItem(ROOM_KEY) || '';
  }

  function toast(message, type = '') {
    const el = document.getElementById('damaToast');
    if (!el) return;
    el.textContent = String(message || '');
    el.className = `toast show ${type}`;
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { el.className = 'toast'; }, 2800);
  }

  function cleanDamaUrl() {
    const url = new URL(location.href);
    url.searchParams.delete('room');
    url.searchParams.delete('board_invite');
    const query = url.searchParams.toString();
    return `${url.pathname}${query ? `?${query}` : ''}${url.hash || ''}`;
  }

  function leaveRoomUi() {
    localStorage.removeItem(ROOM_KEY);
    document.body.classList.remove('dama-flow-open');
    location.replace(cleanDamaUrl());
  }

  function setBusy(value) {
    busy = Boolean(value);
    ['damaModalDecline', 'damaModalAccept', 'damaStakeCancel', 'damaStakeConfirm']
      .forEach((id) => {
        const button = document.getElementById(id);
        if (button) button.disabled = busy;
      });
    const amount = document.getElementById('damaStakeModalInput');
    if (amount) amount.disabled = busy;
  }

  async function rpc(name, args) {
    if (!window.JLApi?.rpc) throw new Error('Ligação ao jogo indisponível.');
    return window.JLApi.rpc(name, args);
  }

  async function respondToRules(accept) {
    const p_token = token();
    const p_room = roomId();
    if (!p_token || !p_room) throw new Error('Sala de Dama indisponível.');

    await rpc('jl_dama_accept_settings', {
      p_token,
      p_room,
      p_accept: Boolean(accept)
    });

    if (!accept) {
      leaveRoomUi();
      return;
    }

    location.reload();
  }

  async function confirmStake() {
    const p_token = token();
    const p_room = roomId();
    if (!p_token || !p_room) throw new Error('Sala de Dama indisponível.');

    const input = document.getElementById('damaStakeModalInput');
    if (input && !input.readOnly) {
      const requested = Number(input.value);
      const original = Number(input.dataset.originalValue || input.value);

      if (!Number.isInteger(requested) || requested < 10) {
        throw new Error('A aposta deve ser um valor inteiro de pelo menos 10 MZN.');
      }

      if (requested !== original) {
        await rpc('jl_dama_update_bet_before_stake', {
          p_token,
          p_room,
          p_bet_amount: requested
        });
        location.reload();
        return;
      }
    }

    await rpc('jl_dama_commit_stake', { p_token, p_room });
    location.reload();
  }

  async function leaveBeforeStart() {
    const p_token = token();
    const p_room = roomId();
    if (!p_token || !p_room) {
      leaveRoomUi();
      return;
    }

    await rpc('jl_dama_cancel', { p_token, p_room });
    leaveRoomUi();
  }

  function normalizeStakeExitLabel() {
    const button = document.getElementById('damaStakeCancel');
    if (button && button.textContent.trim() !== 'Sair') button.textContent = 'Sair';
  }

  document.addEventListener('click', async (event) => {
    const button = event.target.closest?.('#damaModalDecline,#damaModalAccept,#damaStakeCancel,#damaStakeConfirm');
    if (!button) return;

    // Estes botões pertencem ao modal visual. Impede o encadeamento antigo que
    // tentava clicar em controlos escondidos e falhava em alguns telemóveis.
    event.preventDefault();
    event.stopImmediatePropagation();
    if (busy) return;

    setBusy(true);
    try {
      if (button.id === 'damaModalDecline') {
        await respondToRules(false);
      } else if (button.id === 'damaModalAccept') {
        await respondToRules(true);
      } else if (button.id === 'damaStakeConfirm') {
        await confirmStake();
      } else if (button.id === 'damaStakeCancel') {
        await leaveBeforeStart();
      }
    } catch (error) {
      toast(error?.message || 'Não foi possível concluir a ação.', 'error');
      setBusy(false);
    }
  }, true);

  const observer = new MutationObserver(normalizeStakeExitLabel);
  observer.observe(document.documentElement, { subtree: true, childList: true });
  normalizeStakeExitLabel();
})();
