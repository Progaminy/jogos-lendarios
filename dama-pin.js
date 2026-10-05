(() => {
  'use strict';

  if (!String(location.pathname || '').toLowerCase().endsWith('/dama.html')) return;

  const STORAGE_KEY = 'jl_pin_dama';
  const ROOM_KEY = 'jl_dama_room_id';
  const buttonId = 'pinDama';
  let directionTimer = 0;
  let directionUntil = 0;
  let lastDirectionKind = '';

  function readPinned() {
    try { return sessionStorage.getItem(STORAGE_KEY) === '1'; } catch { return false; }
  }

  function writePinned(value) {
    try { sessionStorage.setItem(STORAGE_KEY, value ? '1' : '0'); } catch {}
  }

  function roomId() {
    try { return localStorage.getItem(ROOM_KEY) || ''; } catch { return ''; }
  }

  function visible(element) {
    return Boolean(
      element &&
      !element.hidden &&
      !element.classList.contains('hidden') &&
      element.getClientRects().length
    );
  }

  function boardDestination() {
    const room = document.getElementById('damaRoom');
    if (!visible(room)) return null;

    const game = document.getElementById('damaGame');
    const board = document.getElementById('damaBoard');
    if (visible(game) && board) {
      return {
        kind: 'game',
        hash: 'damaBoard',
        target: document.querySelector('#damaGame .dama-board-panel') || board,
        board
      };
    }

    const previewBoard = document.getElementById('damaRoomPreviewBoard');
    if (previewBoard) {
      return {
        kind: 'preview',
        hash: 'damaRoomPreviewBoard',
        target: document.getElementById('damaRoomPreview') || previewBoard,
        board: previewBoard
      };
    }

    return {
      kind: 'room',
      hash: 'damaRoom',
      target: room,
      board: room
    };
  }

  function scrollToBoard(behavior = 'auto', force = false) {
    const destination = boardDestination();
    if (!destination?.target) return false;

    const target = destination.target;
    const topbar = document.querySelector('.topbar')?.getBoundingClientRect().height || 0;
    target.style.scrollMarginTop = `${Math.ceil(topbar + 8)}px`;

    try {
      const url = new URL(window.location.href);
      const id = roomId();
      if (id) url.searchParams.set('room', id);
      url.hash = destination.hash;
      window.history.replaceState(window.history.state, '', url.toString());
    } catch {
      window.location.hash = destination.hash;
    }

    const rect = target.getBoundingClientRect();
    const expectedTop = topbar + 8;
    if (force || Math.abs(rect.top - expectedTop) > 18) {
      target.scrollIntoView({ behavior, block: 'start' });
    }

    lastDirectionKind = destination.kind;
    return true;
  }

  function armBoardDirection(duration = 2400) {
    directionUntil = Math.max(directionUntil, Date.now() + duration);
    clearTimeout(directionTimer);

    const tick = () => {
      const destination = boardDestination();
      if (destination) {
        const changed = destination.kind !== lastDirectionKind;
        scrollToBoard(changed ? 'smooth' : 'auto', changed);
      }
      if (Date.now() < directionUntil) {
        directionTimer = window.setTimeout(tick, 120);
      } else {
        directionTimer = 0;
      }
    };

    directionTimer = window.setTimeout(tick, 0);
  }

  function applyPinned(value, shouldScroll = false) {
    const pinned = Boolean(value);
    document.body.classList.toggle('dama-pinned', pinned);

    const button = document.getElementById(buttonId);
    if (button) {
      button.setAttribute('aria-pressed', pinned ? 'true' : 'false');
      button.textContent = pinned ? '↩ Voltar ao site' : '📌 Fixar Dama';
      button.title = pinned ? 'Voltar à página completa' : 'Fixar a Dama na tela';
    }

    if (pinned && shouldScroll) {
      armBoardDirection(1800);
    }
  }

  function installDirectionTriggers() {
    document.addEventListener('submit', (event) => {
      if (!['damaCreateForm', 'damaJoinCodeForm'].includes(event.target?.id)) return;
      lastDirectionKind = '';
      armBoardDirection(3200);
    }, true);

    document.addEventListener('click', (event) => {
      if (!event.target?.closest?.('[data-dama-join]')) return;
      lastDirectionKind = '';
      armBoardDirection(3200);
    }, true);

    const room = document.getElementById('damaRoom');
    const game = document.getElementById('damaGame');
    if (room || game) {
      const observer = new MutationObserver(() => {
        if (visible(game)) {
          if (lastDirectionKind !== 'game') armBoardDirection(1800);
          return;
        }
        if (visible(room) && lastDirectionKind === '') armBoardDirection(1800);
      });
      if (room) observer.observe(room, { attributes: true, attributeFilter: ['class', 'hidden'] });
      if (game) observer.observe(game, { attributes: true, attributeFilter: ['class', 'hidden'] });
    }
  }

  function install() {
    const actions = document.querySelector('.dama-room-actions');
    if (!actions) return false;

    let button = document.getElementById(buttonId);
    if (!button) {
      button = document.createElement('button');
      button.id = buttonId;
      button.className = 'button ghost small dama-pin-button';
      button.type = 'button';
      button.setAttribute('aria-pressed', 'false');
      button.textContent = '📌 Fixar Dama';
      actions.prepend(button);

      button.addEventListener('click', () => {
        const next = !document.body.classList.contains('dama-pinned');
        writePinned(next);
        applyPinned(next, next);
      });
    }

    installDirectionTriggers();
    applyPinned(readPinned(), false);

    if (visible(document.getElementById('damaRoom'))) {
      lastDirectionKind = '';
      armBoardDirection(1400);
    }
    return true;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();