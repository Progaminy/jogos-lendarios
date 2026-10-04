(() => {
  'use strict';

  const ROOM_KEY = 'jl_dama_room_id';
  const state = {
    roomId: '',
    accessRoomId: '',
    accessEnabled: false,
    accessChecked: false,
    hint: null,
    hintSignature: '',
    inFlightSignature: '',
    controller: null,
    debounce: null,
    observer: null
  };

  function token() {
    return window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  }

  function roomId() {
    return localStorage.getItem(ROOM_KEY) || '';
  }

  async function rpc(name, args = {}) {
    if (window.JLApi?.rpc) return window.JLApi.rpc(name, args);
    const c = window.JL_CONFIG || {};
    if (!c.supabaseUrl || !c.supabaseKey) throw new Error('Configuração ausente.');
    const response = await fetch(`${c.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {
        apikey: c.supabaseKey,
        Authorization: `Bearer ${c.supabaseKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(args)
    });
    const raw = await response.text();
    let payload = null;
    try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }
    if (!response.ok) throw new Error(payload?.message || payload?.error || `Erro ${response.status}`);
    return payload;
  }

  function installStyles() {
    if (document.getElementById('jlDamaAnalysisStyle')) return;
    const style = document.createElement('style');
    style.id = 'jlDamaAnalysisStyle';
    style.textContent = `
      #damaBoard{position:relative}
      #damaBoard .dama-ai-origin{box-shadow:inset 0 0 0 4px #18a8ff,inset 0 0 18px rgba(24,168,255,.72)!important}
      #damaBoard .dama-ai-origin .dama-piece{outline:4px solid #18a8ff;outline-offset:2px;filter:drop-shadow(0 0 8px rgba(24,168,255,.95))}
      #damaBoard .dama-ai-target{box-shadow:inset 0 0 0 4px #5cff77,inset 0 0 20px rgba(92,255,119,.75)!important}
      #damaBoard .dama-ai-target::after{content:'';position:absolute;inset:28%;border-radius:50%;background:#5cff77;box-shadow:0 0 14px rgba(92,255,119,.95);z-index:5;pointer-events:none}
      #damaBoard .dama-ai-path{box-shadow:inset 0 0 0 2px rgba(92,255,119,.42)}
      #damaBoard .dama-ai-overlay{position:absolute;inset:0;width:100%;height:100%;z-index:7;pointer-events:none;overflow:visible}
      #damaBoard .dama-ai-overlay polyline{fill:none;stroke:#5cff77;stroke-width:4.5;stroke-linecap:round;stroke-linejoin:round;filter:drop-shadow(0 0 5px rgba(92,255,119,.95))}
      @media (max-width:640px){#damaBoard .dama-ai-overlay polyline{stroke-width:3.8}#damaBoard .dama-ai-origin{box-shadow:inset 0 0 0 3px #18a8ff,inset 0 0 14px rgba(24,168,255,.7)!important}#damaBoard .dama-ai-target{box-shadow:inset 0 0 0 3px #5cff77,inset 0 0 15px rgba(92,255,119,.72)!important}}
    `;
    document.head.appendChild(style);
  }

  function ownTurn() {
    const title = document.getElementById('damaTurnTitle');
    const board = document.getElementById('damaBoard');
    if (!title || !board || board.childElementCount < 64) return false;
    return /^Sua vez$/i.test(String(title.textContent || '').trim());
  }

  function boardSignature() {
    const board = document.getElementById('damaBoard');
    if (!board) return '';
    const parts = [];
    board.querySelectorAll('.dama-cell').forEach((cell) => {
      const piece = cell.querySelector('.dama-piece');
      if (!piece) return;
      parts.push([
        cell.dataset.row,
        cell.dataset.col,
        piece.dataset.pieceId || '',
        piece.classList.contains('red') ? 'r' : 'w',
        piece.querySelector('.dama-crown') ? 'k' : 'm'
      ].join(':'));
    });
    return parts.sort().join('|');
  }

  function clearVisual() {
    const board = document.getElementById('damaBoard');
    if (!board) return;
    board.querySelectorAll('.dama-ai-origin,.dama-ai-target,.dama-ai-path').forEach((el) => {
      el.classList.remove('dama-ai-origin', 'dama-ai-target', 'dama-ai-path');
    });
    board.querySelector('.dama-ai-overlay')?.remove();
  }

  function cellAt(point) {
    const board = document.getElementById('damaBoard');
    if (!board || !point) return null;
    return board.querySelector(`.dama-cell[data-row="${Number(point.row)}"][data-col="${Number(point.col)}"]`);
  }

  function drawHint(hint) {
    clearVisual();
    const board = document.getElementById('damaBoard');
    if (!board || !hint || !Array.isArray(hint.path) || hint.path.length < 2 || !ownTurn()) return;

    const cells = hint.path.map(cellAt);
    if (cells.some((cell) => !cell)) return;

    cells[0].classList.add('dama-ai-origin');
    cells[cells.length - 1].classList.add('dama-ai-target');
    for (let i = 1; i < cells.length - 1; i++) cells[i].classList.add('dama-ai-path');

    const boardRect = board.getBoundingClientRect();
    if (!boardRect.width || !boardRect.height) return;
    const points = cells.map((cell) => {
      const rect = cell.getBoundingClientRect();
      return `${rect.left - boardRect.left + rect.width / 2},${rect.top - boardRect.top + rect.height / 2}`;
    }).join(' ');

    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.classList.add('dama-ai-overlay');
    svg.setAttribute('viewBox', `0 0 ${boardRect.width} ${boardRect.height}`);
    svg.setAttribute('preserveAspectRatio', 'none');

    const defs = document.createElementNS(ns, 'defs');
    const marker = document.createElementNS(ns, 'marker');
    marker.setAttribute('id', 'jlDamaHintArrow');
    marker.setAttribute('viewBox', '0 0 10 10');
    marker.setAttribute('refX', '8');
    marker.setAttribute('refY', '5');
    marker.setAttribute('markerWidth', '5');
    marker.setAttribute('markerHeight', '5');
    marker.setAttribute('orient', 'auto-start-reverse');
    const arrow = document.createElementNS(ns, 'path');
    arrow.setAttribute('d', 'M 0 0 L 10 5 L 0 10 z');
    arrow.setAttribute('fill', '#5cff77');
    marker.appendChild(arrow);
    defs.appendChild(marker);
    svg.appendChild(defs);

    const line = document.createElementNS(ns, 'polyline');
    line.setAttribute('points', points);
    line.setAttribute('marker-end', 'url(#jlDamaHintArrow)');
    svg.appendChild(line);
    board.appendChild(svg);
  }

  async function checkAccess(currentRoom, currentToken) {
    if (state.accessChecked && state.accessRoomId === currentRoom) return state.accessEnabled;
    state.accessRoomId = currentRoom;
    state.accessChecked = true;
    state.accessEnabled = false;
    try {
      const result = await rpc('jl_dama_analysis_access', {
        p_token: currentToken,
        p_room: currentRoom
      });
      state.accessEnabled = Boolean(result?.enabled);
    } catch {
      state.accessEnabled = false;
    }
    return state.accessEnabled;
  }

  async function requestHint(signature, currentRoom, currentToken) {
    if (state.inFlightSignature === signature) return;
    state.controller?.abort();
    const controller = new AbortController();
    state.controller = controller;
    state.inFlightSignature = signature;

    const c = window.JL_CONFIG || {};
    try {
      const response = await fetch(`${c.supabaseUrl}/functions/v1/jogos-dama-engine`, {
        method: 'POST',
        headers: {
          apikey: c.supabaseKey,
          Authorization: `Bearer ${c.supabaseKey}`,
          'Content-Type': 'application/json',
          Accept: 'application/json'
        },
        body: JSON.stringify({ token: currentToken, room_id: currentRoom }),
        cache: 'no-store',
        signal: controller.signal
      });
      const raw = await response.text();
      let payload = null;
      try { payload = raw ? JSON.parse(raw) : null; } catch { payload = null; }

      if (response.status === 403) {
        state.accessEnabled = false;
        clearVisual();
        return;
      }
      if (response.status === 409) {
        clearVisual();
        return;
      }
      if (!response.ok || !payload?.hint) return;

      if (roomId() !== currentRoom || !ownTurn() || boardSignature() !== signature) return;
      state.hint = payload.hint;
      state.hintSignature = signature;
      drawHint(state.hint);
    } catch (error) {
      if (error?.name !== 'AbortError') clearVisual();
    } finally {
      if (state.controller === controller) state.controller = null;
      if (state.inFlightSignature === signature) state.inFlightSignature = '';
    }
  }

  async function analyzeIfNeeded() {
    const currentRoom = roomId();
    const currentToken = token();

    if (!currentRoom || !currentToken || !ownTurn()) {
      clearVisual();
      state.hint = null;
      state.hintSignature = '';
      return;
    }

    if (state.roomId !== currentRoom) {
      state.roomId = currentRoom;
      state.accessChecked = false;
      state.accessEnabled = false;
      state.hint = null;
      state.hintSignature = '';
    }

    const signature = boardSignature();
    if (!signature) return;

    if (state.hint && state.hintSignature === signature) {
      drawHint(state.hint);
      return;
    }

    if (!await checkAccess(currentRoom, currentToken)) {
      clearVisual();
      return;
    }

    await requestHint(signature, currentRoom, currentToken);
  }

  function schedule() {
    clearTimeout(state.debounce);
    state.debounce = setTimeout(analyzeIfNeeded, 120);
  }

  function boot() {
    installStyles();
    const board = document.getElementById('damaBoard');
    const title = document.getElementById('damaTurnTitle');
    if (!board || !title) return setTimeout(boot, 250);

    state.observer = new MutationObserver(schedule);
    state.observer.observe(board, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
    state.observer.observe(title, { childList: true, subtree: true, characterData: true });

    window.addEventListener('resize', () => {
      if (state.hint && state.hintSignature === boardSignature() && ownTurn()) drawHint(state.hint);
    }, { passive: true });
    document.addEventListener('visibilitychange', () => { if (!document.hidden) schedule(); });
    window.addEventListener('jl-player-session-changed', () => {
      state.accessChecked = false;
      state.accessEnabled = false;
      state.hint = null;
      state.hintSignature = '';
      clearVisual();
      schedule();
    });

    schedule();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();