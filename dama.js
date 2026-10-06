(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const rpc = (name, args = {}) => window.JLApi.rpc(name, args);
  const ROOM_KEY = 'jl_dama_room_id';
  const BOARD_INVITE_ID = new URL(location.href).searchParams.get('board_invite') || '';
  const FREE_MODE = new URL(location.href).searchParams.get('mode') === 'free';
  const damaModeBadge=document.getElementById('damaModeBadge'); if(damaModeBadge){damaModeBadge.textContent=FREE_MODE?'FREE':'APOSTAS';damaModeBadge.classList.toggle('free',FREE_MODE);damaModeBadge.classList.toggle('bet',!FREE_MODE);}
  const els = Object.fromEntries([
    'damaToast','damaBalance','damaLoggedOut','damaLoginForm','damaLoginPhone','damaLoginPin',
    'damaLobby','damaLobbyBoard','refreshDamaLobby','damaCreateForm','damaBet','damaTime','damaColor','damaFirst','damaPublic',
    'damaPublicRooms','damaJoinCodeForm','damaJoinCode','damaRoom','damaRoomCode','damaRoomMeta',
    'damaCancel','damaOfferDraw','damaForfeit','damaPlayers','damaSettingsPanel','damaSettingsSummary',
    'damaGuestDecision','damaDeclineSettings','damaAcceptSettings','damaFunding','damaFund',
    'damaGame','damaTurnTitle','damaTurnDot','damaCaptureBadge','damaBoardStatus','damaTimer','damaDrawCounter','damaBoard','damaHint',
    'damaVoiceState','damaMic','damaMuteOpponent','damaRemoteAudio','damaHistory',
    'damaDrawOffer','damaDrawDecline','damaDrawAccept','damaResult','damaResultTitle','damaResultMoney',
    'damaRematchForm','damaRematchBet','damaRematchTime','damaRematchColor','damaRematchFirst',
    'damaRouteModal','damaRouteChoices','damaRouteClose',
    'damaConfirmModal','damaConfirmTitle','damaConfirmText','damaConfirmNo','damaConfirmYes'
  ].map((id) => [id, $(id)]));

  if (FREE_MODE && els.damaBet) {
    const betField = els.damaBet.closest('label');
    if (betField) betField.style.display = 'none';
  }

  const state = {
    token: window.JLSession?.getPlayerToken?.() || '',
    room: null,
    selectedPiece: null,
    previewRoute: null,
    busy: false,
    pollTimer: null,
    publicTimer: null,
    timeoutSent: false,
    localStream: null,
    peer: null,
    peerId: null,
    signalTimer: null,
    lastSignalId: 0,
    opponentMuted: false,
    makingOffer: false,
    ignoreOffer: false,
    polite: false,
    pendingIce: []
  };

  function showToast(message, type = '') {
    if (!els.damaToast) return;
    els.damaToast.textContent = String(message || '');
    els.damaToast.className = `toast show ${type}`;
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => { els.damaToast.className = 'toast'; }, 2600);
  }

  function money(v) {
    const n = Number(v || 0);
    return n.toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function escapeHtml(v) {
    return String(v ?? '').replace(/[&<>"']/g, (ch) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[ch]));
  }

  function roomData() { return state.room?.room || null; }
  function players() { return state.room?.players || []; }
  function me() { return state.room?.identity?.player_id || null; }
  function mine() { return players().find((p) => p.player_id === me()) || null; }
  function opponent() { return players().find((p) => p.player_id !== me()) || null; }
  function isHost() { return roomData()?.host_id === me(); }

  function firstName(p) {
    return String(p?.name || p?.code || 'Jogador').trim().split(/\s+/)[0] || 'Jogador';
  }

  function colorName(color) { return color === 'red' ? 'Vermelha' : 'Clara'; }
  function starterName(r) { return r.first_player_choice === 'host' ? 'Criador' : 'Adversário'; }

  async function withBusy(fn) {
    if (state.busy) return;
    state.busy = true;
    try { await fn(); } finally { state.busy = false; }
  }

  function saveRoom(id) {
    if (id) localStorage.setItem(ROOM_KEY, String(id));
    else localStorage.removeItem(ROOM_KEY);
  }

  function setRoom(data) {
    state.room = data || null;
    state.timeoutSent = false;
    state.selectedPiece = null;
    state.previewRoute = null;
    const id = data?.room?.id;
    if (id) saveRoom(id);
    render();
  }

  function setScreen(which) {
    els.damaLoggedOut.classList.toggle('hidden', which !== 'loggedout');
    els.damaLobby.classList.toggle('hidden', which !== 'lobby');
    els.damaRoom.classList.toggle('hidden', which !== 'room');
  }

  function renderLobbyBoard() {
    if (!els.damaLobbyBoard || els.damaLobbyBoard.childElementCount) return;

    const frag = document.createDocumentFragment();
    for (let row = 0; row < 8; row++) {
      for (let col = 0; col < 8; col++) {
        const cell = document.createElement('span');
        const dark = (row + col) % 2 === 1;
        cell.className = `dama-cell ${dark ? 'dark' : 'light'}`;

        if (dark && (row <= 2 || row >= 5)) {
          const piece = document.createElement('span');
          piece.className = `dama-piece ${row <= 2 ? 'red' : 'white'}`;
          cell.appendChild(piece);
        }

        frag.appendChild(cell);
      }
    }
    els.damaLobbyBoard.replaceChildren(frag);
  }

  function installChoiceGroups() {
    document.querySelectorAll('.dama-choice-row').forEach((group) => {
      group.addEventListener('click', (event) => {
        const button = event.target.closest('button[data-value]');
        if (!button) return;
        const kind = group.dataset.choice;
        const target = kind === 'time' ? els.damaTime : kind === 'color' ? els.damaColor : els.damaFirst;
        target.value = button.dataset.value;
        group.querySelectorAll('button[data-value]').forEach((b) => b.classList.toggle('active', b === button));
      });
    });
  }

  async function loadApp() {
    state.token = window.JLSession?.getPlayerToken?.() || '';
    if (!state.token) {
      setScreen('loggedout');
      return;
    }

    const queryRoom = new URL(location.href).searchParams.get('room');
    const remembered = queryRoom || localStorage.getItem(ROOM_KEY) || '';
    if (remembered) {
      try {
        const room = await rpc('jl_dama_room_state', { p_token: state.token, p_room: remembered });
        setRoom(room);
        startRoomPolling();
        return;
      } catch {
        saveRoom('');
      }
    }

    try {
      const status = await rpc('jl_dama_my_status', { p_token: state.token });
      els.damaBalance.textContent = `${money(status?.identity?.balance)} MZN`;
      if (status?.active_room_id) {
        const room = await rpc('jl_dama_room_state', { p_token: state.token, p_room: status.active_room_id });
        setRoom(room);
        startRoomPolling();
      } else {
        state.room = null;
        setScreen('lobby');
        await loadPublicRooms();
        startPublicPolling();
      }
    } catch (error) {
      showToast(error.message, 'error');
      setScreen('loggedout');
    }
  }

  async function refreshRoom(silent = true) {
    const r = roomData();
    if (!r?.id || !state.token) return;
    try {
      if (r.status === 'playing') {
        await rpc('jl_dama_process_timeout', { p_token: state.token, p_room: r.id });
      }
      const fresh = await rpc('jl_dama_room_state', { p_token: state.token, p_room: r.id });
      state.room = fresh;
      if (fresh?.room?.status !== 'playing') state.timeoutSent = false;
      render();
    } catch (error) {
      if (!silent) showToast(error.message, 'error');
      if (/não encontrada|inválida/i.test(error.message)) {
        stopRoomPolling();
        saveRoom('');
        state.room = null;
        await loadApp();
      }
    }
  }

  function startRoomPolling() {
    stopPublicPolling();
    if (state.pollTimer) return;
    state.pollTimer = setInterval(() => {
      if (!document.hidden) refreshRoom(true);
    }, 1500);
    startSignalPolling();
  }

  function stopRoomPolling() {
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = null;
    stopSignalPolling();
  }

  function startPublicPolling() {
    if (state.publicTimer) return;
    state.publicTimer = setInterval(() => {
      if (!document.hidden && !state.room) loadPublicRooms(true);
    }, 8000);
  }

  function stopPublicPolling() {
    if (state.publicTimer) clearInterval(state.publicTimer);
    state.publicTimer = null;
  }

  async function loadPublicRooms(silent = false) {
    if (!state.token) return;
    try {
      const rows0 = await rpc('jl_dama_public_rooms', { p_token: state.token });
      const rows = rows0.filter(r => FREE_MODE ? r.play_mode === 'free' : r.play_mode !== 'free');
      els.damaPublicRooms.innerHTML = rows.length ? rows.map((r) => `
        <div class="dama-room-item">
          <div>
            <strong>${escapeHtml(firstName({ name: r.host_name }))}</strong><br>
            <small>${money(r.bet_amount)} MZN · ${Number(r.turn_seconds) / 60} min · ${colorName(r.host_color)} · começa: ${r.first_player === 'host' ? 'criador' : 'adversário'}</small>
          </div>
          <button class="button secondary small" type="button" data-dama-join="${escapeHtml(r.code)}">Entrar</button>
        </div>
      `).join('') : '<div class="empty">Nenhuma partida pública agora.</div>';
    } catch (error) {
      if (!silent) showToast(error.message, 'error');
    }
  }

  function render() {
    const r = roomData();
    if (!r) return;

    setScreen('room');
    els.damaBalance.textContent = `${money(state.room.identity?.balance)} MZN`;
    els.damaRoomCode.textContent = r.code;
    els.damaRoomMeta.textContent = `${money(r.bet_amount)} MZN · ${r.turn_seconds / 60} min · 1 × 1`;

    const started = r.status === 'playing' && Boolean(r.started_at);
    const prestart = ['waiting','negotiating','funding','ready'].includes(r.status) || (r.status === 'playing' && !r.started_at);
    els.damaCancel.classList.toggle('hidden', !prestart);
    els.damaForfeit.classList.toggle('hidden', !started);
    els.damaOfferDraw.classList.toggle('hidden', !started);

    renderPlayers();
    renderSettings();
    renderGame();
    renderDrawOffer();
    renderResult();
    renderVoice();
    updateTimer();
  }

  function renderPlayers() {
    const r = roomData();
    const list = players();
    els.damaPlayers.innerHTML = [1, 2].map((seat) => {
      const p = list.find((x) => x.seat === seat);
      if (!p) return `<div class="dama-player"><div class="dama-player-info"><strong>Aguardando adversário…</strong><small>Vaga ${seat}</small></div></div>`;
      return `
        <div class="dama-player ${r.current_player_id === p.player_id ? 'current' : ''}">
          <span class="dama-player-piece ${p.color}"></span>
          <div class="dama-player-info">
            <strong>${escapeHtml(firstName(p))}${p.player_id === me() ? ' · você' : ''}</strong>
            <small>${colorName(p.color)} · ${p.stake_paid ? 'aposta ✓' : 'aposta…'}</small>
          </div>
        </div>
      `;
    }).join('');
  }

  function renderSettings() {
    const r = roomData();
    const my = mine();
    const host = players().find((p) => p.seat === 1);
    const guest = players().find((p) => p.seat === 2);

    els.damaSettingsSummary.innerHTML = [
      `Aposta: ${money(r.bet_amount)} MZN`,
      `Jogada: ${r.turn_seconds / 60} min`,
      `Criador: ${colorName(r.host_color)}`,
      `Começa: ${starterName(r)}`
    ].map((x) => `<span class="dama-setting-chip">${escapeHtml(x)}</span>`).join('');

    const guestNeedsDecision = r.status === 'negotiating' && my?.seat === 2 && !my.settings_accepted;
    els.damaGuestDecision.classList.toggle('hidden', !guestNeedsDecision);

    const needsFunding = r.status === 'funding' && my && !my.stake_paid;
    els.damaFunding.classList.toggle('hidden', !needsFunding);
    if (needsFunding) els.damaFund.textContent = `Confirmar ${money(r.bet_amount)} MZN`;

    if (r.status === 'waiting' && isHost()) {
      els.damaSettingsSummary.insertAdjacentHTML('beforeend', '<span class="dama-setting-chip">Aguardando adversário</span>');
    }
    if (r.status === 'negotiating' && isHost() && guest) {
      els.damaSettingsSummary.insertAdjacentHTML('beforeend', '<span class="dama-setting-chip">Aguardando aceitação</span>');
    }
    if (r.status === 'funding') {
      const paid = [host, guest].filter((p) => p?.stake_paid).length;
      els.damaSettingsSummary.insertAdjacentHTML('beforeend', `<span class="dama-setting-chip">Apostas: ${paid}/2</span>`);
    }
  }

  function renderGame() {
    const r = roomData();
    const show = ['ready','playing','finished'].includes(r.status) && (state.room.pieces || []).length > 0;
    els.damaGame.classList.toggle('hidden', !show);
    if (!show) return;

    const current = players().find((p) => p.player_id === r.current_player_id);
    const legal = state.room?.legal_moves || [];
    const myTurn = r.status !== 'finished' && r.current_player_id === me();
    const captureRequired = myTurn && legal.some((move) => move.is_capture || Number(move.capture_count || 0) > 0);
    const selected = Boolean(state.selectedPiece);

    els.damaTurnTitle.textContent = r.status === 'finished'
      ? 'Partida terminada'
      : current
        ? (myTurn ? 'Sua vez' : `Vez de ${firstName(current)}`)
        : 'Aguardando';

    els.damaTurnDot.className = `dama-turn-dot ${myTurn ? 'mine' : 'waiting'}`;
    els.damaCaptureBadge.classList.toggle('hidden', !captureRequired);

    if (r.status === 'ready') {
      els.damaBoardStatus.textContent = myTurn ? 'Pode começar quando quiser.' : `Aguardando ${firstName(current)}.`;
      els.damaHint.textContent = myTurn
        ? 'Antes da primeira jogada não há contagem de tempo. Toque numa peça marcada quando quiser começar.'
        : 'A primeira jogada ainda não foi feita. O relógio continua parado.';
    } else if (r.status === 'playing') {
      if (myTurn && captureRequired) {
        els.damaBoardStatus.textContent = selected ? 'Escolha o destino final.' : 'Captura obrigatória.';
        els.damaHint.textContent = selected
          ? 'Peça escolhida. Toque no destino final marcado.'
          : 'Captura obrigatória: toque numa peça marcada e depois no destino final.';
      } else if (myTurn) {
        els.damaBoardStatus.textContent = selected ? 'Escolha o destino final.' : 'Escolha uma peça marcada.';
        els.damaHint.textContent = selected
          ? 'Peça escolhida. Toque no destino final marcado.'
          : 'Toque numa peça destacada e depois no destino final.';
      } else {
        els.damaBoardStatus.textContent = `Aguardando ${firstName(current)}.`;
        els.damaHint.textContent = `Aguardando ${firstName(current)}.`;
      }
    } else {
      els.damaBoardStatus.textContent = 'Partida encerrada.';
      els.damaHint.textContent = 'Partida encerrada.';
    }

    renderBoard();
    renderHistory();

    const draw = state.room.draw || {};
    const p1 = players().find((p) => p.seat === 1);
    const p2 = players().find((p) => p.seat === 2);
    const q1 = Number(draw.quiet_light || 0);
    const q2 = Number(draw.quiet_dark || 0);
    const regLimit = Number(draw.regulation_limit || 0);
    const rg1 = Number(draw.regulation_light || 0);
    const rg2 = Number(draw.regulation_dark || 0);
    if (regLimit > 0) {
      els.damaDrawCounter.textContent =
        `Final regulamentar: ${firstName(p1)} ${Math.max(0, regLimit - rg1)} · ${firstName(p2)} ${Math.max(0, regLimit - rg2)} restantes`;
      els.damaDrawCounter.classList.remove('hidden');
    } else if (q1 > 0 || q2 > 0) {
      els.damaDrawCounter.textContent =
        `20 lances: ${firstName(p1)} ${Math.max(0, 20 - q1)} · ${firstName(p2)} ${Math.max(0, 20 - q2)} restantes`;
      els.damaDrawCounter.classList.remove('hidden');
    } else {
      els.damaDrawCounter.classList.add('hidden');
    }
  }

  function renderBoard() {
    const r = roomData();
    const my = mine();
    const rotate = my?.color === 'red';
    const piecesBySquare = new Map(
      (state.room.pieces || []).map((p) => [`${p.row}:${p.col}`, p])
    );
    const legal = state.room.legal_moves || [];
    const legalPieceIds = new Set(legal.map((m) => m.piece_id));
    const myTurn = r.current_player_id === me() && r.status !== 'finished';
    const captureRequired = myTurn && legal.some((move) => move.is_capture || Number(move.capture_count || 0) > 0);
    if (state.selectedPiece && !legalPieceIds.has(state.selectedPiece)) state.selectedPiece = null;

    // Se só existe uma peça legal, já a apresenta selecionada. O jogador continua
    // a confirmar a jogada tocando apenas no destino final.
    if (myTurn && !state.selectedPiece && legalPieceIds.size === 1) {
      state.selectedPiece = [...legalPieceIds][0];
    }

    const selectedRoutes = state.selectedPiece ? legal.filter((m) => m.piece_id === state.selectedPiece) : [];
    const targetKeys = new Set(selectedRoutes.map((m) => `${m.to_row}:${m.to_col}`));
    els.damaBoard.classList.toggle('is-my-turn', myTurn);
    els.damaBoard.classList.toggle('capture-turn', captureRequired);
    els.damaBoard.classList.toggle('has-selection', Boolean(state.selectedPiece));

    const lastPath = Array.isArray(r.last_move?.path) ? r.last_move.path : [];
    const lastKeys = new Set(lastPath.map((p) => `${p.row}:${p.col}`));
    const lastOrigin = lastPath[0] ? `${lastPath[0].row}:${lastPath[0].col}` : '';
    const lastEnd = lastPath.length ? `${lastPath[lastPath.length - 1].row}:${lastPath[lastPath.length - 1].col}` : '';
    const previewKeys = new Set((state.previewRoute?.path || []).map((p) => `${p.row}:${p.col}`));

    const frag = document.createDocumentFragment();
    for (let displayRow = 0; displayRow < 8; displayRow++) {
      for (let displayCol = 0; displayCol < 8; displayCol++) {
        const row = rotate ? 7 - displayRow : displayRow;
        const col = rotate ? 7 - displayCol : displayCol;
        const key = `${row}:${col}`;
        const cell = document.createElement('button');
        cell.type = 'button';
        cell.className = `dama-cell ${(row + col) % 2 ? 'dark' : 'light'}`;
        cell.dataset.row = String(row);
        cell.dataset.col = String(col);
        cell.tabIndex = -1;

        if (lastKeys.has(key)) cell.classList.add('last-path');
        if (key === lastOrigin) cell.classList.add('last-origin');
        if (key === lastEnd) cell.classList.add('last-destination');
        if (previewKeys.has(key)) cell.classList.add('route-preview');
        if (targetKeys.has(key)) {
          cell.classList.add('legal-target');
          cell.setAttribute('aria-label', 'Destino possível');
        }

        const piece = piecesBySquare.get(key);
        if (piece) {
          const owner = players().find((p) => p.player_id === piece.player_id);
          const token = document.createElement('span');
          token.className = `dama-piece ${owner?.color || 'white'}`;
          token.dataset.pieceId = piece.id;
          if (legalPieceIds.has(piece.id) && myTurn) {
            token.classList.add('legal');
            token.setAttribute('title', 'Peça disponível');
          }
          if (state.selectedPiece === piece.id) token.classList.add('selected');
          if (piece.is_king) {
            const crown = document.createElement('span');
            crown.className = 'dama-crown';
            crown.textContent = '♛';
            token.appendChild(crown);
          }
          cell.appendChild(token);
        }
        frag.appendChild(cell);
      }
    }
    els.damaBoard.replaceChildren(frag);
  }

  function selectPiece(pieceId) {
    const legal = state.room?.legal_moves || [];
    if (!legal.some((m) => m.piece_id === pieceId)) return;
    state.selectedPiece = pieceId;
    state.previewRoute = null;
    renderBoard();
  }

  function routesForDestination(row, col) {
    return (state.room?.legal_moves || []).filter((m) =>
      m.piece_id === state.selectedPiece && Number(m.to_row) === row && Number(m.to_col) === col
    );
  }

  function squareName(p) {
    return String.fromCharCode(97 + Number(p.col)) + String(Number(p.row) + 1);
  }

  function routeLabel(route) {
    const path = route.path || [];
    return path.map(squareName).join(route.is_capture ? ' : ' : ' - ');
  }

  function openRouteChooser(routes) {
    state.previewRoute = routes[0] || null;
    els.damaRouteChoices.innerHTML = routes.map((route, index) => {
      const path = route.path || [];
      const flow = path.map((point, pointIndex) => {
        const square = `<span class="dama-route-square">${escapeHtml(squareName(point))}</span>`;
        if (pointIndex === path.length - 1) return square;
        return square + `<span class="dama-route-arrow">${route.is_capture ? '×' : '→'}</span>`;
      }).join('');
      const captures = Number(route.capture_count || 0);
      return `
        <button class="dama-route-option" type="button"
          data-route-id="${escapeHtml(route.route_id)}" data-route-number="${index + 1}">
          <strong>Rota ${index + 1} · ${captures} captura${captures === 1 ? '' : 's'}</strong>
          <small>Destino final: ${escapeHtml(squareName(path[path.length - 1] || { row: route.to_row, col: route.to_col }))}</small>
          <span class="dama-route-flow">${flow}</span>
        </button>
      `;
    }).join('');
    els.damaRouteModal.classList.remove('hidden');
    renderBoard();
  }

  function closeRouteChooser() {
    els.damaRouteModal.classList.add('hidden');
    state.previewRoute = null;
    renderBoard();
  }

  async function playRoute(routeId) {
    const r = roomData();
    if (!r?.id) return;
    closeRouteChooser();
    await withBusy(async () => {
      try {
        const next = await rpc('jl_dama_move', {
          p_token: state.token,
          p_room: r.id,
          p_route_id: routeId
        });
        setRoom(next);
      } catch (error) {
        showToast(error.message, 'error');
        await refreshRoom(true);
      }
    });
  }

  function renderHistory() {
    const moves = (state.room?.events || []).filter((e) => e.event_type === 'piece_moved');
    els.damaHistory.innerHTML = moves.length ? moves.map((e, index) => {
      const p = players().find((x) => x.player_id === e.player_id);
      const path = e.payload?.path || [];
      const text = path.map(squareName).join(Number(e.payload?.capture_count || 0) ? ' : ' : ' - ');
      return `<div class="dama-history-row"><span>${index + 1}. ${escapeHtml(firstName(p))}</span><strong>${escapeHtml(text)}</strong></div>`;
    }).join('') : '<div class="empty">Ainda sem jogadas.</div>';
  }

  function updateTimer() {
    const r = roomData();
    if (!r || r.status !== 'playing' || !r.action_deadline) {
      els.damaTimer.textContent = r?.status === 'ready' ? 'Sem prazo' : '—';
      els.damaTimer.classList.remove('urgent');
      return;
    }
    const left = Math.max(0, Math.ceil((new Date(r.action_deadline).getTime() - Date.now()) / 1000));
    const min = Math.floor(left / 60);
    const sec = left % 60;
    els.damaTimer.textContent = `${String(min).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
    els.damaTimer.classList.toggle('urgent', left <= 20);
    if (left === 0 && !state.timeoutSent) {
      state.timeoutSent = true;
      refreshRoom(false);
    }
  }

  function renderDrawOffer() {
    const r = roomData();
    const pendingForMe = r?.status === 'playing' && r.draw_offer_by && r.draw_offer_by !== me();
    els.damaDrawOffer.classList.toggle('hidden', !pendingForMe);
  }

  function renderResult() {
    const r = roomData();
    const done = r?.status === 'finished';
    els.damaResult.classList.toggle('hidden', !done);
    if (!done) return;

    const winner = players().find((p) => p.player_id === r.winner_player_id);
    if (winner) {
      els.damaResultTitle.textContent = `${firstName(winner)} venceu`;
      const payout = (state.room.payouts || []).find((p) => p.player_id === winner.player_id);
      els.damaResultMoney.innerHTML = payout
        ? `<p>Bruto ${money(payout.gross)} MZN · casa ${money(payout.commission)} MZN · <strong>líquido ${money(payout.net)} MZN</strong></p>`
        : '';
    } else {
      els.damaResultTitle.textContent = 'Empate';
      els.damaResultMoney.innerHTML = '<p><strong>Sem comissão.</strong> As apostas foram devolvidas.</p>';
    }

    if (els.damaRematchBet.dataset.room !== r.id) {
      els.damaRematchBet.value = String(Math.trunc(Number(r.bet_amount) || 10));
      els.damaRematchTime.value = String(r.turn_seconds || 120);
      els.damaRematchColor.value = mine()?.color || 'white';
      els.damaRematchFirst.value = 'host';
      els.damaRematchBet.dataset.room = r.id;
    }
  }

  function askConfirm(text, title = 'Confirmar') {
    return new Promise((resolve) => {
      els.damaConfirmTitle.textContent = title;
      els.damaConfirmText.textContent = text;
      els.damaConfirmModal.classList.remove('hidden');
      const finish = (answer) => {
        els.damaConfirmModal.classList.add('hidden');
        els.damaConfirmYes.onclick = null;
        els.damaConfirmNo.onclick = null;
        resolve(answer);
      };
      els.damaConfirmYes.onclick = () => finish(true);
      els.damaConfirmNo.onclick = () => finish(false);
    });
  }

  // Voz 1×1. O microfone começa sempre desligado.
  function voiceAvailable() {
    const r = roomData();
    return Boolean(r && ['ready','playing'].includes(r.status) && opponent());
  }

  function renderVoice() {
    const available = voiceAvailable();
    els.damaMic.disabled = !available;
    els.damaMuteOpponent.disabled = !available;
    const on = Boolean(state.localStream?.getAudioTracks?.().some((t) => t.readyState === 'live'));
    els.damaVoiceState.textContent = available ? (on ? 'Ligado' : 'Desligado') : 'Indisponível';
    els.damaMic.textContent = on ? '🔇 Desligar microfone' : '🎙️ Ligar microfone';
    els.damaMic.setAttribute('aria-pressed', on ? 'true' : 'false');
    els.damaMuteOpponent.textContent = state.opponentMuted ? '🔇 Adversário silenciado' : '🔊 Ouvir adversário';
    els.damaMuteOpponent.setAttribute('aria-pressed', state.opponentMuted ? 'true' : 'false');
    if (available) startSignalPolling();
  }

  function ensurePeer(peerId, addTrack = false) {
    if (!peerId) return null;
    if (state.peer && state.peerId === peerId) {
      if (addTrack) attachLocalTrack();
      return state.peer;
    }
    closePeerOnly();
    const pc = new RTCPeerConnection({
      iceServers: [
        { urls: 'stun:stun.l.google.com:19302' },
        { urls: 'stun:stun1.l.google.com:19302' }
      ]
    });
    state.peer = pc;
    state.peerId = peerId;
    state.polite = String(me()) > String(peerId);
    state.pendingIce = [];

    pc.onicecandidate = (event) => {
      if (event.candidate) sendSignal('ice', event.candidate.toJSON());
    };
    pc.ontrack = (event) => {
      let audio = $('damaOpponentAudio');
      if (!audio) {
        audio = document.createElement('audio');
        audio.id = 'damaOpponentAudio';
        audio.autoplay = true;
        audio.playsInline = true;
        els.damaRemoteAudio.replaceChildren(audio);
      }
      audio.srcObject = event.streams[0];
      audio.muted = state.opponentMuted;
      audio.play().catch(() => { audio.controls = true; });
    };
    pc.onnegotiationneeded = async () => {
      try {
        state.makingOffer = true;
        await pc.setLocalDescription(await pc.createOffer());
        await sendSignal('offer', pc.localDescription);
      } catch (error) {
        console.warn('dama voice offer', error);
      } finally {
        state.makingOffer = false;
      }
    };
    if (addTrack) attachLocalTrack();
    return pc;
  }

  function attachLocalTrack() {
    if (!state.peer || !state.localStream) return;
    const track = state.localStream.getAudioTracks()[0];
    if (!track) return;
    const sender = state.peer.getSenders().find((s) => s.track?.kind === 'audio');
    if (sender) {
      if (sender.track !== track) sender.replaceTrack(track).catch(() => {});
    } else {
      state.peer.addTrack(track, state.localStream);
    }
  }

  async function sendSignal(type, payload) {
    const r = roomData();
    const other = opponent();
    if (!r?.id || !other) return;
    try {
      await rpc('jl_dama_signal_send', {
        p_token: state.token,
        p_room: r.id,
        p_to_player: other.player_id,
        p_signal_type: type,
        p_payload: payload
      });
    } catch (error) {
      console.warn('dama signal', error.message);
    }
  }

  async function pullSignals() {
    const r = roomData();
    if (!r?.id || !voiceAvailable()) return;
    try {
      const rows = await rpc('jl_dama_signal_pull', {
        p_token: state.token,
        p_room: r.id,
        p_after_id: state.lastSignalId
      });
      for (const signal of rows || []) {
        state.lastSignalId = Math.max(state.lastSignalId, Number(signal.id || 0));
        await handleSignal(signal);
      }
    } catch (error) {
      console.warn('dama signal pull', error.message);
    }
  }

  async function handleSignal(signal) {
    const pc = ensurePeer(signal.from_player_id, Boolean(state.localStream));
    if (!pc) return;
    try {
      if (signal.signal_type === 'offer') {
        const desc = new RTCSessionDescription(signal.payload);
        const collision = state.makingOffer || pc.signalingState !== 'stable';
        state.ignoreOffer = !state.polite && collision;
        if (state.ignoreOffer) return;
        if (collision && state.polite && pc.signalingState !== 'stable') {
          try { await pc.setLocalDescription({ type: 'rollback' }); } catch {}
        }
        await pc.setRemoteDescription(desc);
        while (state.pendingIce.length) {
          await pc.addIceCandidate(new RTCIceCandidate(state.pendingIce.shift()));
        }
        attachLocalTrack();
        await pc.setLocalDescription(await pc.createAnswer());
        await sendSignal('answer', pc.localDescription);
      } else if (signal.signal_type === 'answer') {
        if (pc.signalingState === 'have-local-offer') {
          await pc.setRemoteDescription(new RTCSessionDescription(signal.payload));
          while (state.pendingIce.length) {
            await pc.addIceCandidate(new RTCIceCandidate(state.pendingIce.shift()));
          }
        }
      } else if (signal.signal_type === 'ice') {
        if (!pc.remoteDescription) state.pendingIce.push(signal.payload);
        else await pc.addIceCandidate(new RTCIceCandidate(signal.payload));
      }
    } catch (error) {
      if (!state.ignoreOffer) console.warn('dama voice handle', error);
    }
  }

  function startSignalPolling() {
    if (state.signalTimer || !voiceAvailable()) return;
    state.signalTimer = setInterval(() => { if (!document.hidden) pullSignals(); }, 1000);
    pullSignals();
  }

  function stopSignalPolling() {
    if (state.signalTimer) clearInterval(state.signalTimer);
    state.signalTimer = null;
  }

  function closePeerOnly() {
    if (state.peer) state.peer.close();
    state.peer = null;
    state.peerId = null;
    state.pendingIce = [];
    els.damaRemoteAudio.replaceChildren();
  }

  function closeVoice() {
    stopSignalPolling();
    closePeerOnly();
    if (state.localStream) state.localStream.getTracks().forEach((t) => t.stop());
    state.localStream = null;
    state.lastSignalId = 0;
  }

  async function toggleMic() {
    if (!voiceAvailable()) return;
    try {
      if (state.localStream) {
        state.localStream.getTracks().forEach((t) => t.stop());
        state.localStream = null;
        if (state.peer) {
          for (const sender of state.peer.getSenders()) {
            if (sender.track?.kind === 'audio') sender.replaceTrack(null).catch(() => {});
          }
        }
        showToast('Microfone desligado.');
      } else {
        state.localStream = await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
          video: false
        });
        ensurePeer(opponent()?.player_id, true);
        showToast('Microfone ligado.', 'success');
      }
      renderVoice();
    } catch (error) {
      showToast(`Microfone: ${error.message}`, 'error');
    }
  }

  function toggleOpponentMute() {
    state.opponentMuted = !state.opponentMuted;
    const audio = $('damaOpponentAudio');
    if (audio) audio.muted = state.opponentMuted;
    renderVoice();
  }

  // Eventos
  els.damaLoginForm.addEventListener('submit', (event) => {
    event.preventDefault();
    withBusy(async () => {
      try {
        const res = await rpc('jl_login_player', {
          p_phone: els.damaLoginPhone.value.trim(),
          p_pin: els.damaLoginPin.value.trim()
        });
        window.JLSession.setPlayerToken(res.token);
        state.token = res.token;
        showToast('Sessão iniciada.', 'success');
        await loadApp();
      } catch (error) { showToast(error.message, 'error'); }
    });
  });

  els.damaCreateForm.addEventListener('submit', (event) => {
    event.preventDefault();
    withBusy(async () => {
      try {
        const args = {
          p_token: state.token,
          p_turn_seconds: Number(els.damaTime.value),
          p_host_color: els.damaColor.value,
          p_first_player: els.damaFirst.value
        };
        const room = FREE_MODE
          ? await rpc('jl_dama_create_free_room', {
              ...args,
              p_is_public: els.damaPublic.checked
            })
          : BOARD_INVITE_ID
            ? await rpc('jl_dama_create_from_board_invite', {
                ...args,
                p_bet_amount: Number(els.damaBet.value),
                p_board_invite: BOARD_INVITE_ID
              })
            : await rpc('jl_dama_create_room', {
                ...args,
                p_bet_amount: Number(els.damaBet.value),
                p_is_public: els.damaPublic.checked
              });
        setRoom(room);
        startRoomPolling();
        if (BOARD_INVITE_ID && room?.room?.id) {
          history.replaceState({}, '', './dama.html?room=' + encodeURIComponent(room.room.id));
        }
        showToast(BOARD_INVITE_ID ? 'Desafio de Dama criado.' : 'Partida criada.', 'success');
      } catch (error) { showToast(error.message, 'error'); }
    });
  });

  els.refreshDamaLobby.addEventListener('click', () => loadPublicRooms(false));

  els.damaPublicRooms.addEventListener('click', (event) => {
    const button = event.target.closest('[data-dama-join]');
    if (!button) return;
    withBusy(async () => {
      try {
        const room = await rpc('jl_dama_join_room', {
          p_token: state.token,
          p_code: button.dataset.damaJoin
        });
        setRoom(room);
        startRoomPolling();
      } catch (error) { showToast(error.message, 'error'); }
    });
  });

  els.damaJoinCodeForm.addEventListener('submit', (event) => {
    event.preventDefault();
    withBusy(async () => {
      try {
        const room = await rpc('jl_dama_join_room', {
          p_token: state.token,
          p_code: els.damaJoinCode.value.trim()
        });
        setRoom(room);
        startRoomPolling();
      } catch (error) { showToast(error.message, 'error'); }
    });
  });

  els.damaAcceptSettings.addEventListener('click', () => withBusy(async () => {
    try {
      setRoom(await rpc('jl_dama_accept_settings', {
        p_token: state.token, p_room: roomData().id, p_accept: true
      }));
      showToast('Definições aceites.', 'success');
    } catch (error) { showToast(error.message, 'error'); }
  }));

  els.damaDeclineSettings.addEventListener('click', () => withBusy(async () => {
    try {
      await rpc('jl_dama_accept_settings', {
        p_token: state.token, p_room: roomData().id, p_accept: false
      });
      stopRoomPolling();
      saveRoom('');
      state.room = null;
      await loadApp();
    } catch (error) { showToast(error.message, 'error'); }
  }));

  els.damaFund.addEventListener('click', () => withBusy(async () => {
    try {
      setRoom(await rpc('jl_dama_commit_stake', {
        p_token: state.token, p_room: roomData().id
      }));
      showToast('Aposta confirmada.', 'success');
    } catch (error) { showToast(error.message, 'error'); }
  }));

  els.damaBoard.addEventListener('click', (event) => {
    const piece = event.target.closest('.dama-piece');
    if (piece) {
      selectPiece(piece.dataset.pieceId);
      return;
    }
    const cell = event.target.closest('.dama-cell');
    if (!cell || !state.selectedPiece) return;
    const routes = routesForDestination(Number(cell.dataset.row), Number(cell.dataset.col));
    if (!routes.length) return;
    if (routes.length === 1) playRoute(routes[0].route_id);
    else openRouteChooser(routes);
  });

  els.damaRouteChoices.addEventListener('click', (event) => {
    const button = event.target.closest('[data-route-id]');
    if (!button) return;
    playRoute(button.dataset.routeId);
  });
  const previewChosenRoute = (event) => {
    const button = event.target.closest('[data-route-id]');
    if (!button) return;
    state.previewRoute = (state.room?.legal_moves || []).find((r) => r.route_id === button.dataset.routeId) || null;
    renderBoard();
  };
  els.damaRouteChoices.addEventListener('pointerover', previewChosenRoute);
  els.damaRouteChoices.addEventListener('pointerdown', previewChosenRoute);
  els.damaRouteClose.addEventListener('click', closeRouteChooser);

  els.damaCancel.addEventListener('click', async () => {
    if (!(await askConfirm('Cancelar esta partida? Antes da primeira jogada não há penalização.', 'Cancelar partida'))) return;
    withBusy(async () => {
      try {
        await rpc('jl_dama_cancel', { p_token: state.token, p_room: roomData().id });
        closeVoice();
        stopRoomPolling();
        saveRoom('');
        state.room = null;
        await loadApp();
        showToast('Partida cancelada.', 'success');
      } catch (error) { showToast(error.message, 'error'); }
    });
  });

  els.damaForfeit.addEventListener('click', async () => {
    if (!(await askConfirm('Tem certeza que deseja desistir? Desistir conta como derrota.', 'Desistir da partida'))) return;
    withBusy(async () => {
      try {
        setRoom(await rpc('jl_dama_forfeit', { p_token: state.token, p_room: roomData().id }));
      } catch (error) { showToast(error.message, 'error'); }
    });
  });

  els.damaOfferDraw.addEventListener('click', () => withBusy(async () => {
    try {
      setRoom(await rpc('jl_dama_offer_draw', { p_token: state.token, p_room: roomData().id }));
      showToast('Empate proposto.', 'success');
    } catch (error) { showToast(error.message, 'error'); }
  }));

  els.damaDrawAccept.addEventListener('click', () => withBusy(async () => {
    try {
      setRoom(await rpc('jl_dama_respond_draw', {
        p_token: state.token, p_room: roomData().id, p_accept: true
      }));
    } catch (error) { showToast(error.message, 'error'); }
  }));

  els.damaDrawDecline.addEventListener('click', () => withBusy(async () => {
    try {
      setRoom(await rpc('jl_dama_respond_draw', {
        p_token: state.token, p_room: roomData().id, p_accept: false
      }));
      showToast('Empate recusado. A partida continua.');
    } catch (error) { showToast(error.message, 'error'); }
  }));

  els.damaRematchForm.addEventListener('submit', (event) => {
    event.preventDefault();
    withBusy(async () => {
      try {
        const next = await rpc('jl_dama_rematch', {
          p_token: state.token,
          p_room: roomData().id,
          p_bet_amount: Number(els.damaRematchBet.value),
          p_turn_seconds: Number(els.damaRematchTime.value),
          p_host_color: els.damaRematchColor.value,
          p_first_player: els.damaRematchFirst.value,
          p_is_public: false
        });
        setRoom(next);
        showToast('Revanche proposta.', 'success');
      } catch (error) { showToast(error.message, 'error'); }
    });
  });

  els.damaMic.addEventListener('click', toggleMic);
  els.damaMuteOpponent.addEventListener('click', toggleOpponentMute);

  window.addEventListener('beforeunload', () => closeVoice());
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && state.room) refreshRoom(true);
  });

  renderLobbyBoard();
  installChoiceGroups();
  setInterval(updateTimer, 250);
  loadApp();
})();