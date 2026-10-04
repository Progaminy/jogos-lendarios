(() => {
  'use strict';

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
    return String(queryRoom || localStorage.getItem('jl_dama_room_id') || 'current');
  }

  function showEndMessage() {
    if (result.classList.contains('hidden')) return;

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
