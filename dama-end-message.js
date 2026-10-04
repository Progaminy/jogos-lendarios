(() => {
  'use strict';

  const ROOM_KEY = 'jl_dama_room_id';
  const result = document.getElementById('damaResult');
  const resultTitle = document.getElementById('damaResultTitle');
  const modal = document.getElementById('damaEndModal');
  const title = document.getElementById('damaEndTitle');
  const message = document.getElementById('damaEndMessage');
  const ok = document.getElementById('damaEndOk');

  if (!result || !modal || !title || !message || !ok) return;

  let shownRoom = '';

  function currentRoomKey() {
    const queryRoom = new URL(location.href).searchParams.get('room');
    return String(queryRoom || localStorage.getItem(ROOM_KEY) || 'current');
  }

  function cleanDamaUrl() {
    const url = new URL(location.href);
    url.searchParams.delete('room');
    url.searchParams.delete('board_invite');
    const query = url.searchParams.toString();
    return `${url.pathname}${query ? `?${query}` : ''}${url.hash || ''}`;
  }

  function leaveFinishedRoom() {
    if (result.classList.contains('hidden')) return;

    localStorage.removeItem(ROOM_KEY);
    modal.classList.add('hidden');
    document.body.classList.remove('modal-open');

    // Faz um carregamento limpo. Sem ?room=... a Dama deixa de reabrir a
    // partida já terminada e o jogador volta a ficar disponível para outros
    // pedidos/desafios.
    location.replace(cleanDamaUrl());
  }

  function ensureLeaveButton() {
    let button = document.getElementById('damaLeaveFinished');
    if (button) return button;

    button = document.createElement('button');
    button.id = 'damaLeaveFinished';
    button.type = 'button';
    button.className = 'button ghost wide';
    button.textContent = 'Sair';
    button.addEventListener('click', leaveFinishedRoom);
    result.appendChild(button);
    return button;
  }

  function ensureModalLeaveButton() {
    let button = document.getElementById('damaEndLeave');
    if (button) return button;

    button = document.createElement('button');
    button.id = 'damaEndLeave';
    button.type = 'button';
    button.className = 'button ghost wide';
    button.textContent = 'Sair';
    button.addEventListener('click', leaveFinishedRoom);
    ok.insertAdjacentElement('afterend', button);
    return button;
  }

  function showEndMessage() {
    if (result.classList.contains('hidden')) return;

    ensureLeaveButton();
    ensureModalLeaveButton();

    const roomKey = currentRoomKey();
    if (shownRoom === roomKey) return;
    shownRoom = roomKey;

    title.textContent = 'Fim do Jogo';
    message.textContent = String(resultTitle?.textContent || 'Partida terminada').trim();
    modal.classList.remove('hidden');
    document.body.classList.add('modal-open');

    try { ok.focus({ preventScroll: true }); } catch {}
  }

  function closeEndMessage() {
    modal.classList.add('hidden');
    document.body.classList.remove('modal-open');
    result.scrollIntoView?.({ behavior: 'smooth', block: 'start' });
  }

  const observer = new MutationObserver(showEndMessage);
  observer.observe(result, { attributes: true, attributeFilter: ['class'] });

  ok.addEventListener('click', closeEndMessage);

  window.addEventListener('pageshow', showEndMessage);
  queueMicrotask(showEndMessage);
})();