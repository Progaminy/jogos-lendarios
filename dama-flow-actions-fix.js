(() => {
  'use strict';

  const ROOM_KEY = 'jl_dama_room_id';
  let busy = false;
  let leaving = false;

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

  function freezeLeavingUi() {
    if (!leaving) return;
    const modal = document.getElementById('damaStakeModal');
    if (modal) {
      modal.classList.add('hidden');
      modal.setAttribute('aria-hidden', 'true');
    }
    document.body.classList.remove('dama-flow-open');
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
    if (leaving) return;
    leaving = true;
    freezeLeavingUi();

    const p_token = token();
    const p_room = roomId();
    if (!p_token || !p_room) {
      leaveRoomUi();
      return;
    }

    try {
      await rpc('jl_dama_cancel', { p_token, p_room });
      leaveRoomUi();
    } catch (error) {
      leaving = false;
      const modal = document.getElementById('damaStakeModal');
      if (modal) modal.removeAttribute('aria-hidden');
      throw error;
    }
  }

  function normalizeStakeExit() {
    const button = document.getElementById('damaStakeCancel');
    if (button) {
      if (button.textContent.trim() !== 'Sair') button.textContent = 'Sair';
      button.setAttribute('aria-label', 'Sair desta partida');
    }
    freezeLeavingUi();
  }

  document.addEventListener('click', async (event) => {
    const target = event.target instanceof Element ? event.target : null;
    const button = target?.closest?.('#damaModalDecline,#damaModalAccept,#damaStakeCancel,#damaStakeConfirm');
    if (!button) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    if (busy || leaving) return;

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
      normalizeStakeExit();
    }
  }, true);

  const observer = new MutationObserver(normalizeStakeExit);
  observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
  normalizeStakeExit();
})();
