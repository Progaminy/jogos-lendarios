(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const rpc = (name, args = {}) => window.JLApi.rpc(name, args);
  const TOKEN_KEY = 'jl_player_token';
  const BOARD_INVITE_ID = new URL(location.href).searchParams.get('board_invite') || '';

  const PATH = [[6,1],[6,2],[6,3],[6,4],[6,5],[5,6],[4,6],[3,6],[2,6],[1,6],[0,6],[0,7],[0,8],[1,8],[2,8],[3,8],[4,8],[5,8],[6,9],[6,10],[6,11],[6,12],[6,13],[6,14],[7,14],[8,14],[8,13],[8,12],[8,11],[8,10],[8,9],[9,8],[10,8],[11,8],[12,8],[13,8],[14,8],[14,7],[14,6],[13,6],[12,6],[11,6],[10,6],[9,6],[8,5],[8,4],[8,3],[8,2],[8,1],[8,0],[7,0],[6,0]];
  const START = { red:0, green:13, yellow:26, blue:39 };
  const HOME = {
    red:[[7,1],[7,2],[7,3],[7,4],[7,5]],
    green:[[1,7],[2,7],[3,7],[4,7],[5,7]],
    yellow:[[7,13],[7,12],[7,11],[7,10],[7,9]],
    blue:[[13,7],[12,7],[11,7],[10,7],[9,7]]
  };
  const BASE = {
    red:[[1,1],[1,4],[4,1],[4,4]],
    green:[[1,10],[1,13],[4,10],[4,13]],
    yellow:[[10,10],[10,13],[13,10],[13,13]],
    blue:[[10,1],[10,4],[13,1],[13,4]]
  };
  const FINISH = { red:[7,6], green:[6,7], yellow:[7,8], blue:[8,7] };
  const SAFE = new Set([0,8,13,21,26,34,39,47]);
  const COLORS = new Set(['red','green','yellow','blue']);
  const PIPS = {1:[5],2:[1,9],3:[1,5,9],4:[1,3,7,9],5:[1,3,5,7,9],6:[1,3,4,6,7,9]};

  const state = {
    token: '',
    status: null,
    room: null,
    loading: true,
    syncing: false,
    pendingRefresh: false,
    busy: false,
    error: '',
    recoveringRoomId: '',
    pollTimer: 0,
    clockTimer: 0,
    deadlineSyncKey: '',
    rulesDirty: false,
    rulesVersion: null,
    waitingRoomId: '',
    waitingLoadedAt: 0,
    waitingPlayers: [],
    rematchRoomId: '',
    preferredColor: localStorage.getItem('jl_ludo_preferred_color') || 'red',
    preferredPawnStyle: localStorage.getItem('jl_ludo_preferred_pawn_style') || 'current'
  };

  function getToken() {
    return window.JLSession?.getPlayerToken?.() || localStorage.getItem(TOKEN_KEY) || '';
  }

  function setToken(value) {
    const token = String(value || '');
    if (window.JLSession?.setPlayerToken) window.JLSession.setPlayerToken(token);
    else if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
    state.token = token;
  }

  function esc(value) {
    return String(value ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }

  function money(value) {
    return Number(value || 0).toLocaleString('pt-MZ', { minimumFractionDigits:2, maximumFractionDigits:2 });
  }

  function showToast(message, type = '') {
    const toast = $('toast');
    if (!toast) return;
    toast.textContent = String(message || '');
    toast.className = `toast show ${type}`.trim();
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => { toast.className = 'toast'; }, 3500);
  }

  function setAuthMessage(message = '', type = '') {
    const el = $('authMessage');
    if (!el) return;
    el.textContent = message;
    el.style.color = type === 'error' ? '#ff8994' : type === 'success' ? '#8df1bb' : '';
  }

  function roomData() { return state.room?.room || null; }
  function roomPlayers() { return Array.isArray(state.room?.players) ? state.room.players : []; }
  function me() { return state.room?.identity?.player_id || state.status?.identity?.player_id || null; }
  function myRoomPlayer() { return roomPlayers().find((player) => String(player.player_id) === String(me())) || null; }
  function rules() { return roomData()?.rules && typeof roomData().rules === 'object' ? roomData().rules : {}; }
  function isHost() { const r = roomData(); return Boolean(r && String(r.host_id) === String(me())); }

  function wholeStake(value, label = 'A aposta') {
    const amount = Number(value);
    if (!Number.isInteger(amount) || amount < 10) {
      showToast(`${label} deve ser um valor inteiro a partir de 10 MZN.`, 'error');
      return null;
    }
    return amount;
  }

  function redirectToDeposit(amount, context) {
    const balance = Number(state.status?.identity?.balance);
    const missing = Number.isFinite(balance) && Number.isFinite(amount) ? Math.max(0, Math.ceil(amount - balance)) : null;
    const message = missing && missing > 0
      ? `Saldo insuficiente para ${context}. Faltam ${money(missing)} MZN.`
      : `Saldo insuficiente para ${context}.`;
    showToast(`${message} Abrindo depósito…`, 'error');
    const url = missing && missing > 0
      ? `./index.html?deposit_needed=${encodeURIComponent(missing)}&from=ludo#depositPanel`
      : './index.html?open=deposit&from=ludo#depositPanel';
    setTimeout(() => { location.href = url; }, 450);
  }

  function ensureFunds(amount, context) {
    const identity = state.status?.identity;
    const balance = Number(identity?.balance);
    if (identity?.balance_confirmed === true && Number.isFinite(balance) && balance < amount) {
      redirectToDeposit(amount, context);
      return false;
    }
    return true;
  }

  function handleMoneyError(error, amount, context) {
    const message = String(error?.message || error || 'Erro');
    if (/saldo|fundos|insuficiente|balance/i.test(message)) {
      redirectToDeposit(amount, context);
      return true;
    }
    return false;
  }

  async function withBusy(fn) {
    if (state.busy) return;
    state.busy = true;
    renderBusyState();
    try { await fn(); }
    finally {
      state.busy = false;
      renderBusyState();
    }
  }

  function renderBusyState() {
    document.querySelectorAll('[data-action-button]').forEach((el) => { el.disabled = state.busy; });
    const dice = $('rollDice');
    if (dice && state.busy) dice.disabled = true;
  }

  function scheduleNextSync(delay = null) {
    clearTimeout(state.pollTimer);
    if (!state.token) return;
    const ms = delay ?? (document.visibilityState === 'visible' ? (state.room ? 3000 : 7000) : 12000);
    state.pollTimer = setTimeout(() => requestSync('poll'), ms);
  }

  async function requestSync(reason = 'manual') {
    if (state.syncing) {
      state.pendingRefresh = true;
      return;
    }
    state.syncing = true;
    try {
      do {
        state.pendingRefresh = false;
        await performSync(reason);
      } while (state.pendingRefresh);
    } finally {
      state.syncing = false;
      scheduleNextSync();
    }
  }

  async function performSync(reason) {
    const token = getToken();
    state.token = token;
    if (!token) {
      state.status = null;
      state.room = null;
      state.recoveringRoomId = '';
      state.error = '';
      state.loading = false;
      render();
      return;
    }

    const previousRoom = state.room;
    try {
      const status = await rpc('jl_ludo_my_status', { p_token: token });
      let snapshot = null;
      const activeRoomId = String(status?.active_room_id || '').trim();

      if (activeRoomId) {
        state.recoveringRoomId = activeRoomId;
        snapshot = await rpc('jl_ludo_room_state_light', { p_token: token, p_room: activeRoomId });
        if (!snapshot?.room?.id) throw new Error('O servidor não devolveu o estado da sala ativa.');

        const deadline = snapshot.room.action_deadline ? Date.parse(snapshot.room.action_deadline) : NaN;
        if (Number.isFinite(deadline) && deadline <= Date.now() && snapshot.room.status !== 'finished' && snapshot.room.status !== 'negotiating') {
          try {
            const timed = await rpc('jl_ludo_process_timeouts', { p_token: token, p_room: activeRoomId });
            if (timed?.room?.id) snapshot = timed;
            else snapshot = await rpc('jl_ludo_room_state_light', { p_token: token, p_room: activeRoomId });
          } catch {}
        }
      } else {
        state.recoveringRoomId = '';
        if (!Array.isArray(status?.public_challenges)) {
          try { status.public_challenges = await rpc('jl_ludo_public_challenges', { p_token: token }); }
          catch { status.public_challenges = state.status?.public_challenges || []; }
        }
      }

      state.status = status;
      state.room = snapshot;
      state.error = '';
      state.loading = false;
      if (!snapshot && previousRoom) {
        state.rulesDirty = false;
        state.rulesVersion = null;
        state.waitingRoomId = '';
        state.waitingPlayers = [];
      }
      render();
    } catch (error) {
      state.error = String(error?.message || error || 'Erro ao atualizar o Ludo.');
      state.loading = false;
      if (previousRoom?.room?.id && (!state.recoveringRoomId || String(previousRoom.room.id) === state.recoveringRoomId)) {
        state.room = previousRoom;
      }
      render();
      if (state.recoveringRoomId && !state.room) scheduleNextSync(1200);
      if (reason !== 'poll') showToast(state.error, 'error');
    }
  }

  function render() {
    const authed = Boolean(state.token && state.status?.identity);
    const hasRoom = Boolean(state.room?.room?.id);
    const boot = $('bootPanel');
    const loggedOut = $('loggedOut');
    const lobby = $('lobby');
    const room = $('room');
    const strip = $('statusStrip');

    if (state.loading || (state.recoveringRoomId && !hasRoom && state.error)) {
      boot.classList.remove('hidden');
      $('bootMessage').textContent = state.error
        ? `A recuperar a sala ${state.recoveringRoomId}. ${state.error}`
        : 'A confirmar sessão e partida ativa.';
    } else {
      boot.classList.add('hidden');
    }

    loggedOut.classList.toggle('hidden', state.loading || authed);
    lobby.classList.toggle('hidden', !authed || hasRoom || Boolean(state.recoveringRoomId && !hasRoom));
    room.classList.toggle('hidden', !authed || !hasRoom);
    strip.classList.toggle('hidden', !authed);

    renderAccount();
    if (authed) renderStatusStrip();
    if (authed && !hasRoom && !state.recoveringRoomId) renderLobby();
    if (hasRoom) renderRoom();
  }

  function renderAccount() {
    const identity = state.status?.identity;
    const button = $('accountButton');
    const logout = $('logoutButton');
    if (!state.token || !identity) {
      button.textContent = 'Entrar';
      logout.classList.add('hidden');
      return;
    }
    button.textContent = identity.name || identity.code || 'Conta';
    logout.classList.remove('hidden');
  }

  function renderStatusStrip() {
    const identity = state.status?.identity || {};
    $('onlineCount').textContent = String(Math.max(0, Number(state.status?.online_count || 0)));
    $('balanceText').textContent = identity.balance_confirmed === true && Number.isFinite(Number(identity.balance)) ? money(identity.balance) : '—';
    const invites = Array.isArray(state.status?.invites) ? state.status.invites : [];
    const challenges = Array.isArray(state.status?.public_challenges) ? state.status.public_challenges : [];
    $('directInviteCount').textContent = String(invites.length);
    $('publicChallengeCount').textContent = String(challenges.length);
  }

  function renderLobby() {
    const identity = state.status?.identity || {};
    $('playerIdentity').textContent = `${identity.name || 'Jogador'} · ${identity.code || ''}`.trim();

    const queue = state.status?.queue;
    $('queueStatus').classList.toggle('hidden', !queue);
    if (queue) {
      $('queueStatus').innerHTML = `Em espera: <strong>${Number(queue.player_count || 0)} jogadores</strong> · ${esc(queue.mode || 'solo')} · <strong>${money(queue.bet_amount)} MZN</strong>`;
      $('queueButton').textContent = 'Sair da espera';
      $('queueButton').dataset.queued = '1';
    } else {
      $('queueButton').textContent = 'Quero jogar';
      delete $('queueButton').dataset.queued;
    }

    renderInvites();
  }

  function renderInvites() {
    const invites = Array.isArray(state.status?.invites) ? state.status.invites : [];
    const challenges = Array.isArray(state.status?.public_challenges) ? state.status.public_challenges : [];

    $('inviteList').innerHTML = invites.length ? invites.map((invite) => `
      <div class="list-item">
        <div><strong>${esc(invite.host || invite.host_code || 'Jogador')}</strong><small>${esc(invite.room_code || '')} · ${Number(invite.player_count || 0)} jogadores · ${money(invite.bet_amount)} MZN</small></div>
        <div class="list-actions">
          <button class="button success small" type="button" data-invite-accept="${esc(invite.id)}" data-bet="${Number(invite.bet_amount || 0)}">Aceitar</button>
          <button class="button danger small" type="button" data-invite-decline="${esc(invite.id)}">Recusar</button>
        </div>
      </div>`).join('') : '<div class="empty">Nenhum convite.</div>';

    $('publicChallengeList').innerHTML = challenges.length ? challenges.map((challenge) => `
      <div class="list-item">
        <div><strong>${esc(challenge.host_name || challenge.host_code || 'Jogador')}</strong><small>${esc(challenge.code || '')} · ${Number(challenge.joined_count || 0)}/${Number(challenge.player_count || 0)} · ${money(challenge.bet_amount)} MZN</small></div>
        <button class="button secondary small" type="button" data-public-accept="${esc(challenge.code)}" data-bet="${Number(challenge.bet_amount || 0)}">Entrar</button>
      </div>`).join('') : '<div class="empty">Nenhum desafio público.</div>';
  }

  function renderRoom() {
    const r = roomData();
    if (!r) return;

    $('roomCode').textContent = r.code || 'SALA';
    $('roomMeta').textContent = `${Number(r.player_count || 0)} jogadores · ${r.mode === 'partners' ? 'Parceiros 2 × 2' : 'Cada um por si'} · ${money(r.bet_amount)} MZN por jogador · ${r.is_public ? 'Pública' : 'Privada'}`;
    $('roomPot').textContent = `${money(r.pot || Number(r.bet_amount || 0) * Number(r.player_count || 0))} MZN`;

    const playingStarted = r.status === 'playing' && Boolean(r.started_at);
    $('leaveRoom').classList.toggle('hidden', playingStarted && r.status !== 'finished');
    $('forfeitRoom').classList.toggle('hidden', !playingStarted || r.status === 'finished');

    renderDeadline();
    renderPlayers();
    renderInvitePanel();
    renderRules();
    renderFunding();
    renderGame();
    renderReentry();
    renderChat();
    renderResult();
  }

  function renderPlayers() {
    const r = roomData();
    const players = roomPlayers();
    const count = Math.max(2, Number(r?.player_count || 2));
    $('playersPanel').innerHTML = Array.from({length:count}, (_, index) => {
      const seat = index + 1;
      const player = players.find((x) => Number(x.seat) === seat);
      if (!player) return `<article class="player-card"><small>Vaga ${seat}</small><h3>Aguardando…</h3></article>`;
      const current = String(r.current_player_id || '') === String(player.player_id);
      const accepted = Number(player.accepted_rules_version) === Number(r.rules_version);
      return `<article class="player-card ${esc(player.color || '')} ${current ? 'current' : ''}">
        <small>${player.team ? `Equipa ${esc(player.team)} · ` : ''}posição ${seat}</small>
        <h3>${esc(player.name || player.code || 'Jogador')}</h3>
        <small>${esc(player.code || '')}</small>
        <div class="player-flags">
          <span class="flag ${accepted ? 'ok' : 'wait'}">${accepted ? '✓ regras' : 'regras…'}</span>
          <span class="flag ${player.stake_paid ? 'ok' : 'wait'}">${player.stake_paid ? '✓ aposta' : 'aposta…'}</span>
          <span class="flag">${esc(player.status || 'active')}</span>
        </div>
      </article>`;
    }).join('');
  }

  function deadlineLabel(r) {
    if (r.status === 'waiting') return 'Aguardando completar a sala';
    if (r.status === 'negotiating') return 'Aceitação das regras · sem prazo';
    if (r.status === 'funding') return 'Tempo para confirmar a aposta';
    if (r.status === 'playing' && !r.started_at) return 'Aguardando primeiro dado';
    if (r.status === 'playing') return 'Tempo da jogada';
    if (r.status === 'finished') return 'Partida terminada';
    return String(r.status || 'Sala ativa');
  }

  function renderDeadline() {
    const r = roomData();
    $('deadlineLabel').textContent = deadlineLabel(r);
    updateClock();
  }

  function updateClock() {
    const r = roomData();
    if (!r) return;
    const bar = $('deadlineBar');
    const clock = $('deadlineClock');
    const turnTimer = $('turnTimer');
    const deadline = r.action_deadline ? Date.parse(r.action_deadline) : NaN;

    if (r.status === 'negotiating' || !Number.isFinite(deadline)) {
      clock.textContent = r.status === 'negotiating' ? 'Sem prazo' : '—';
      if (turnTimer) turnTimer.textContent = '--:--';
      bar.classList.remove('urgent');
      return;
    }

    const seconds = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
    const value = `${String(Math.floor(seconds / 60)).padStart(2,'0')}:${String(seconds % 60).padStart(2,'0')}`;
    clock.textContent = value;
    if (turnTimer && r.status === 'playing') turnTimer.textContent = value;
    bar.classList.toggle('urgent', seconds <= 10);

    if (seconds === 0) {
      const key = `${r.id}:${r.action_deadline}`;
      if (state.deadlineSyncKey !== key) {
        state.deadlineSyncKey = key;
        setTimeout(() => requestSync('deadline'), 150);
      }
    }
  }

  function renderInvitePanel() {
    const r = roomData();
    const canInvite = isHost() && ['waiting','negotiating'].includes(r.status);
    $('invitePanel').classList.toggle('hidden', !canInvite);
    if (!canInvite) return;
    const now = Date.now();
    if (state.waitingRoomId !== r.id || now - state.waitingLoadedAt > 8000) loadWaitingPlayers(false);
    else renderWaitingPlayers();
  }

  async function loadWaitingPlayers(force = true) {
    const r = roomData();
    if (!r || !isHost() || !['waiting','negotiating'].includes(r.status)) return;
    if (!force && state.waitingRoomId === r.id && Date.now() - state.waitingLoadedAt < 8000) return;
    try {
      const rows = await rpc('jl_ludo_waiting_players', { p_token:state.token, p_room:r.id });
      if (roomData()?.id !== r.id) return;
      state.waitingRoomId = r.id;
      state.waitingLoadedAt = Date.now();
      state.waitingPlayers = Array.isArray(rows) ? rows : [];
      renderWaitingPlayers();
    } catch (error) {
      if (force) showToast(error.message, 'error');
    }
  }

  function renderWaitingPlayers() {
    $('waitingPlayers').innerHTML = state.waitingPlayers.length ? state.waitingPlayers.map((player) => `
      <div class="list-item"><div><strong>${esc(player.name || 'Jogador')}</strong><small>${esc(player.code || '')}</small></div><button class="button ghost small" type="button" data-invite-player="${esc(player.player_id)}">Convidar</button></div>`).join('') : '<div class="empty">Nenhum jogador compatível agora.</div>';
  }

  function boolText(value, yes, no) { return value ? yes : no; }

  function renderRules() {
    const r = roomData();
    const x = rules();
    const rows = [
      `Tempo por jogada: ${Number(x.turn_seconds || x.move_seconds || 30)}s`,
      `Peões por jogador: ${Number(r.pawn_count || x.pawn_count || 4)}`,
      'Saída da base: somente com 6',
      boolText(Boolean(x.capture_required), 'Captura obrigatória', 'Captura não obrigatória'),
      boolText(Boolean(x.reentry_allowed), `Reentrada: ${money(x.reentry_amount || 0)} MZN`, 'Sem reentrada'),
      boolText(Boolean(x.six_extra_turn), '6 dá nova jogada', '6 não dá nova jogada'),
      boolText(Boolean(x.capture_extra_turn), 'Captura dá nova jogada', 'Captura não dá nova jogada'),
      boolText(Boolean(x.exact_finish), 'Chegada exata', 'Conclusão sem chegada exata'),
      'Timeout: passa a vez; jogador permanece na partida',
      'Casas seguras sempre ativas'
    ];
    if (r.mode === 'partners') rows.push(boolText(Boolean(x.partner_capture), 'Parceiros podem capturar-se', 'Parceiros não podem capturar-se'));
    $('rulesSummary').innerHTML = rows.map((row) => `<div class="rule-chip">${esc(row)}</div>`).join('');
    $('rulesVersion').textContent = `v${Number(r.rules_version || 1)}`;

    const pregame = ['waiting','negotiating'].includes(r.status);
    $('rulesForm').classList.toggle('hidden', !pregame);
    $('partnerCaptureRow').classList.toggle('hidden', r.mode !== 'partners');

    const version = Number(r.rules_version || 1);
    if (state.rulesVersion !== version) {
      state.rulesVersion = version;
      state.rulesDirty = false;
    }
    if (pregame && !state.rulesDirty) fillRulesForm(x);

    const mine = myRoomPlayer();
    const needsDecision = pregame && mine && Number(mine.accepted_rules_version) !== version;
    $('rulesDecision').classList.toggle('hidden', !needsDecision);
  }

  function fillRulesForm(x) {
    const form = $('rulesForm');
    if (!form) return;
    const defaults = {
      turn_seconds:Number(x.turn_seconds || x.move_seconds || 30),
      reentry_amount:Number(x.reentry_amount || 0),
      capture_required:Boolean(x.capture_required),
      reentry_allowed:Boolean(x.reentry_allowed),
      six_extra_turn:Boolean(x.six_extra_turn),
      capture_extra_turn:Boolean(x.capture_extra_turn),
      three_sixes_penalty:Boolean(x.three_sixes_penalty),
      exact_finish:x.exact_finish !== false,
      chat_enabled:x.chat_enabled !== false,
      partner_capture:Boolean(x.partner_capture)
    };
    for (const [name, value] of Object.entries(defaults)) {
      const el = form.elements[name];
      if (!el) continue;
      if (el.type === 'checkbox') el.checked = Boolean(value);
      else el.value = String(value);
    }
  }

  function readRulesForm() {
    const current = {...rules()};
    const form = $('rulesForm');
    const numberNames = new Set(['turn_seconds','reentry_amount']);
    for (const el of form.elements) {
      if (!el.name) continue;
      current[el.name] = el.type === 'checkbox' ? el.checked : numberNames.has(el.name) ? Number(el.value) : el.value;
    }
    current.move_seconds = Number(current.turn_seconds || 30);
    current.pawn_count = Number(roomData()?.pawn_count || current.pawn_count || 4);
    current.safe_cells = true;
    return current;
  }

  function renderFunding() {
    const r = roomData();
    const mine = myRoomPlayer();
    const show = r.status === 'funding';
    $('fundingPanel').classList.toggle('hidden', !show);
    if (!show) return;
    const paid = roomPlayers().filter((player) => player.stake_paid).length;
    $('fundingText').textContent = `${paid}/${Number(r.player_count || 0)} jogadores confirmaram ${money(r.bet_amount)} MZN.`;
    $('fundButton').disabled = Boolean(mine?.stake_paid) || state.busy;
    $('fundButton').textContent = mine?.stake_paid ? 'Aposta confirmada' : `Confirmar ${money(r.bet_amount)} MZN`;
    if (!$('stakeProposalAmount').value) $('stakeProposalAmount').value = String(Math.max(10, Number(r.bet_amount || 10)));
  }

  function tokenCoord(color, step, tokenNo) {
    if (!COLORS.has(color)) return null;
    const n = Number(step);
    if (n === -1) return BASE[color]?.[Number(tokenNo) - 1] || null;
    if (n >= 0 && n <= 50) return PATH[(START[color] + n) % 52];
    if (n >= 51 && n <= 55) return HOME[color]?.[n - 51] || null;
    if (n >= 56) return FINISH[color] || [7,7];
    return null;
  }

  function cellKey(row, col) { return `${row}:${col}`; }

  function renderBoard() {
    const board = $('ludoBoard');
    const snapshot = state.room;
    if (!board || !snapshot?.room) return;
    const pathMap = new Map(PATH.map((coord, index) => [cellKey(coord[0], coord[1]), index]));
    const homeMap = new Map();
    for (const color of COLORS) for (const coord of HOME[color]) homeMap.set(cellKey(coord[0], coord[1]), color);
    for (const color of COLORS) homeMap.set(cellKey(FINISH[color][0], FINISH[color][1]), color);

    board.replaceChildren();
    const cells = new Map();
    for (let row = 0; row < 15; row += 1) {
      for (let col = 0; col < 15; col += 1) {
        const cell = document.createElement('div');
        cell.className = 'cell';
        cell.dataset.row = String(row);
        cell.dataset.col = String(col);
        if (row <= 5 && col <= 5) cell.classList.add('base-red');
        else if (row <= 5 && col >= 9) cell.classList.add('base-green');
        else if (row >= 9 && col >= 9) cell.classList.add('base-yellow');
        else if (row >= 9 && col <= 5) cell.classList.add('base-blue');
        const key = cellKey(row, col);
        if (pathMap.has(key)) {
          cell.classList.add('path');
          if (SAFE.has(pathMap.get(key))) cell.classList.add('safe');
        }
        if (homeMap.has(key)) cell.classList.add(`home-${homeMap.get(key)}`);
        if (row === 7 && col === 7) cell.classList.add('center');
        cells.set(key, cell);
        board.appendChild(cell);
      }
    }

    const legal = new Set((snapshot.legal_moves || []).map((move) => Number(move.token_no)));
    const myId = String(me() || '');
    const counts = new Map();
    for (const token of snapshot.tokens || []) {
      const player = roomPlayers().find((p) => String(p.player_id) === String(token.player_id));
      if (!player) continue;
      const coord = tokenCoord(player.color, Number(token.steps), Number(token.token_no));
      if (!coord) continue;
      const cell = cells.get(cellKey(coord[0], coord[1]));
      if (!cell) continue;
      const own = String(token.player_id) === myId;
      const movable = own && legal.has(Number(token.token_no)) && roomData()?.status === 'playing';
      const piece = document.createElement('button');
      piece.type = 'button';
      piece.className = `piece ${player.color || ''}${own ? ' mine' : ''}${movable ? ' legal' : ''}`;
      piece.dataset.playerId = String(token.player_id);
      piece.dataset.tokenNo = String(token.token_no);
      piece.textContent = String(token.token_no);
      piece.disabled = !movable;
      piece.setAttribute('aria-label', `${player.name || player.code || 'Jogador'}, peão ${token.token_no}${movable ? ', movimento disponível' : ''}`);
      cell.appendChild(piece);
      const key = cellKey(coord[0], coord[1]);
      counts.set(key, (counts.get(key) || 0) + 1);
    }
    for (const [key, count] of counts) if (count > 1) cells.get(key)?.classList.add('multi');
  }

  function diceValue() {
    const raw = roomData()?.dice_result;
    if (Array.isArray(raw)) {
      const n = Number(raw[0]);
      return Number.isInteger(n) && n >= 1 && n <= 6 ? n : null;
    }
    if (typeof raw === 'number') return Number.isInteger(raw) && raw >= 1 && raw <= 6 ? raw : null;
    if (typeof raw === 'string') {
      const direct = Number(raw);
      if (Number.isInteger(direct) && direct >= 1 && direct <= 6) return direct;
      try {
        const parsed = JSON.parse(raw);
        const n = Number(Array.isArray(parsed) ? parsed[0] : parsed);
        return Number.isInteger(n) && n >= 1 && n <= 6 ? n : null;
      } catch {}
    }
    return null;
  }

  function renderDice(value) {
    const dice = $('rollDice');
    dice.replaceChildren();
    if (!Number.isInteger(value) || value < 1 || value > 6) {
      const q = document.createElement('span'); q.textContent = '?'; dice.appendChild(q); return;
    }
    const grid = document.createElement('span');
    grid.className = 'dice-pips';
    const active = new Set(PIPS[value]);
    for (let i = 1; i <= 9; i += 1) {
      const pip = document.createElement('span');
      pip.className = `pip${active.has(i) ? ' on' : ''}`;
      grid.appendChild(pip);
    }
    dice.appendChild(grid);
  }

  function renderGame() {
    const r = roomData();
    const show = ['playing','finished'].includes(r.status);
    $('gamePanel').classList.toggle('hidden', !show);
    if (!show) return;

    const current = roomPlayers().find((player) => String(player.player_id) === String(r.current_player_id));
    const mine = String(r.current_player_id || '') === String(me() || '');
    $('turnTitle').textContent = r.status === 'finished' ? 'Partida terminada' : current ? `Vez de ${current.name || current.code}` : 'Aguardando turno';

    const phase = String(r.turn_phase || '').toLowerCase();
    const legalMoves = Array.isArray(state.room?.legal_moves) ? state.room.legal_moves : [];
    const canRoll = !state.busy && r.status === 'playing' && mine && (phase === 'roll' || (!phase && !r.dice_result));
    $('rollDice').disabled = !canRoll;
    renderDice(diceValue());

    if (r.status === 'finished') $('moveHint').textContent = 'Partida concluída.';
    else if (mine && canRoll) $('moveHint').textContent = 'Sua vez. Toque no dado.';
    else if (mine && legalMoves.length) $('moveHint').textContent = legalMoves.length === 1 ? 'Escolha o peão destacado.' : `Escolha um dos ${legalMoves.length} peões destacados.`;
    else if (mine) $('moveHint').textContent = 'Aguardando o servidor concluir sua jogada.';
    else $('moveHint').textContent = current ? `Aguardando ${current.name || current.code}.` : 'Aguardando.';

    $('diceHelp').textContent = canRoll ? 'Toque para lançar.' : mine ? 'Aguardando movimento.' : 'Aguardando sua vez.';
    renderBoard();
  }

  function renderReentry() {
    const mine = myRoomPlayer();
    const show = mine?.status === 'reentry';
    $('reentryPanel').classList.toggle('hidden', !show);
    if (!show) return;
    $('reentryText').textContent = `Reentrada: ${money(rules().reentry_amount || 0)} MZN.`;
  }

  function renderChat() {
    const messages = Array.isArray(state.room?.chat) ? state.room.chat : [];
    const enabled = Boolean(rules().chat_enabled) && Array.isArray(state.room?.chat);
    $('chatPanel').classList.toggle('hidden', !enabled);
    if (!enabled) return;
    $('chatMessages').innerHTML = messages.length ? messages.map((message) => `<div class="chat-msg"><strong>${esc(message.code || '')}</strong>${esc(message.message || '')}</div>`).join('') : '<div class="empty">Sem mensagens.</div>';
  }

  function renderResult() {
    const r = roomData();
    const show = r.status === 'finished';
    $('resultPanel').classList.toggle('hidden', !show);
    if (!show) return;
    let winner = 'Vencedor';
    if (r.mode === 'partners' && r.winner_team) winner = `Equipa ${r.winner_team}`;
    else {
      const player = roomPlayers().find((p) => String(p.player_id) === String(r.winner_player_id));
      if (player) winner = player.name || player.code || winner;
    }
    $('resultTitle').textContent = `${winner} venceu`;
    const payouts = Array.isArray(state.room?.payouts) ? state.room.payouts : [];
    $('resultPayouts').innerHTML = payouts.length ? `<div class="payout-grid">${payouts.map((payout) => {
      const player = roomPlayers().find((p) => String(p.player_id) === String(payout.player_id));
      return `<div class="payout-card"><strong>${esc(player?.name || player?.code || 'Jogador')}</strong><br>Bruto ${money(payout.gross)} MZN<br>Casa ${money(payout.commission)} MZN<br><strong>Líquido ${money(payout.net)} MZN</strong></div>`;
    }).join('')}</div>` : `<p class="muted">Pote da partida: ${money(r.pot || Number(r.bet_amount || 0) * Number(r.player_count || 0))} MZN.</p>`;

    if (state.rematchRoomId !== String(r.id)) {
      state.rematchRoomId = String(r.id);
      $('rematchBet').value = String(Math.max(10, Math.trunc(Number(r.bet_amount || 10))));
      $('rematchTurn').value = String(Number(r.rules?.turn_seconds || 30));
      $('rematchMode').value = r.mode || 'solo';
      $('rematchPawns').value = String(Number(r.pawn_count || r.rules?.pawn_count || 4));
      $('rematchDice').value = String(Number(r.rules?.dice_count || 1));
      $('rematchColor').value = COLORS.has(state.preferredColor) ? state.preferredColor : 'red';
    }
  }

  async function applyPreferences(snapshot) {
    if (!snapshot?.room?.id) return snapshot;
    const r = snapshot.room;
    if (!['waiting','negotiating'].includes(r.status)) return snapshot;
    const own = (snapshot.players || []).find((player) => String(player.player_id) === String(snapshot.identity?.player_id));
    let next = snapshot;
    if (COLORS.has(state.preferredColor) && own?.color !== state.preferredColor) {
      try { next = await rpc('jl_ludo_choose_color', { p_token:state.token, p_room:r.id, p_color:state.preferredColor }); }
      catch {}
    }
    const mine = (next?.players || []).find((player) => String(player.player_id) === String(next?.identity?.player_id));
    if (state.preferredPawnStyle && (mine?.pawn_style || 'current') !== state.preferredPawnStyle) {
      try { next = await rpc('jl_ludo_choose_pawn_style', { p_token:state.token, p_room:r.id, p_pawn_style:state.preferredPawnStyle }); }
      catch {}
    }
    return next;
  }

  function switchAuth(mode) {
    const login = mode !== 'register';
    $('loginTab').classList.toggle('active', login);
    $('registerTab').classList.toggle('active', !login);
    $('loginForm').classList.toggle('hidden', !login);
    $('registerForm').classList.toggle('hidden', login);
    $('authTitle').textContent = login ? 'Entrar' : 'Criar conta';
    setAuthMessage('');
  }

  function openAuth(mode = 'login') {
    switchAuth(mode);
    $('authModal').classList.remove('hidden');
    document.body.style.overflow = 'hidden';
  }

  function closeAuth() {
    $('authModal').classList.add('hidden');
    document.body.style.overflow = '';
    setAuthMessage('');
  }

  function wireEvents() {
    $('refreshButton').addEventListener('click', () => requestSync('manual'));
    $('refreshLobby').addEventListener('click', () => requestSync('manual'));
    $('accountButton').addEventListener('click', () => state.token ? (location.href = './index.html#playerArea') : openAuth('login'));
    $('logoutButton').addEventListener('click', () => withBusy(async () => {
      try { if (state.token) await rpc('jl_logout_player', { p_token:state.token }); } catch {}
      setToken('');
      state.status = null;
      state.room = null;
      state.recoveringRoomId = '';
      render();
      showToast('Sessão encerrada.');
    }));

    document.querySelectorAll('[data-open-auth]').forEach((button) => button.addEventListener('click', () => openAuth(button.dataset.openAuth)));
    $('closeAuth').addEventListener('click', closeAuth);
    $('authModal').addEventListener('click', (event) => { if (event.target === $('authModal')) closeAuth(); });
    $('loginTab').addEventListener('click', () => switchAuth('login'));
    $('registerTab').addEventListener('click', () => switchAuth('register'));

    $('loginForm').addEventListener('submit', (event) => {
      event.preventDefault();
      withBusy(async () => {
        try {
          setAuthMessage('Entrando…');
          const result = await rpc('jl_login_player', { p_phone:$('loginPhone').value.trim(), p_pin:$('loginPin').value.trim() });
          setToken(result.token);
          state.loading = true;
          closeAuth();
          await requestSync('login');
          showToast('Sessão iniciada.', 'success');
        } catch (error) { setAuthMessage(error.message, 'error'); }
      });
    });

    $('registerForm').addEventListener('submit', (event) => {
      event.preventDefault();
      if ($('registerPin').value !== $('registerPinConfirm').value) return setAuthMessage('Os PINs não coincidem.', 'error');
      withBusy(async () => {
        try {
          setAuthMessage('Criando conta…');
          const result = await rpc('jl_register_player', {
            p_name:$('registerName').value.trim(),
            p_phone:$('registerPhone').value.trim(),
            p_pin:$('registerPin').value.trim(),
            p_invite_code:$('registerInviteCode').value.trim() || null
          });
          setToken(result.token);
          state.loading = true;
          closeAuth();
          await requestSync('register');
          showToast('Conta criada.', 'success');
        } catch (error) { setAuthMessage(error.message, 'error'); }
      });
    });

    $('colorPicker').addEventListener('click', (event) => {
      const button = event.target.closest('[data-color]');
      if (!button) return;
      const color = String(button.dataset.color || 'red');
      if (!COLORS.has(color)) return;
      state.preferredColor = color;
      localStorage.setItem('jl_ludo_preferred_color', color);
      $('createColor').value = color;
      document.querySelectorAll('[data-color]').forEach((el) => {
        const active = el === button;
        el.classList.toggle('active', active);
        el.setAttribute('aria-pressed', active ? 'true' : 'false');
      });
    });

    $('createPawnStyle').addEventListener('change', () => {
      state.preferredPawnStyle = $('createPawnStyle').value;
      localStorage.setItem('jl_ludo_preferred_pawn_style', state.preferredPawnStyle);
    });
    $('createMode').addEventListener('change', () => { if ($('createMode').value === 'partners') $('createPlayers').value = '4'; });
    $('queueMode').addEventListener('change', () => { if ($('queueMode').value === 'partners') $('queuePlayers').value = '4'; });

    $('createRoomForm').addEventListener('submit', (event) => {
      event.preventDefault();
      const amount = wholeStake($('createBet').value);
      if (amount === null || !ensureFunds(amount, 'criar esta sala')) return;
      withBusy(async () => {
        try {
          const turn = Number($('createTurnSeconds').value || 30);
          const roomRules = { turn_seconds:turn, move_seconds:turn, pawn_count:Number($('createPawnCount').value || 4) };
          const created = BOARD_INVITE_ID
            ? await rpc('jl_ludo_create_from_board_invite', { p_token:state.token, p_board_invite:BOARD_INVITE_ID, p_bet_amount:amount, p_rules:roomRules })
            : await rpc('jl_ludo_create_room', { p_token:state.token, p_player_count:Number($('createPlayers').value), p_bet_amount:amount, p_mode:$('createMode').value, p_is_public:$('createPublic').checked, p_rules:roomRules });
          state.room = await applyPreferences(created);
          await requestSync('create-room');
          showToast('Sala criada.', 'success');
        } catch (error) {
          if (!handleMoneyError(error, amount, 'criar esta sala')) showToast(error.message, 'error');
        }
      });
    });

    $('joinCodeForm').addEventListener('submit', (event) => {
      event.preventDefault();
      const code = $('joinCode').value.trim();
      if (!code) return;
      withBusy(async () => {
        try {
          const joined = await rpc('jl_ludo_join_public_room', { p_token:state.token, p_code:code });
          state.room = await applyPreferences(joined);
          await requestSync('join-code');
          showToast('Entrou na sala.', 'success');
        } catch (error) { showToast(error.message, 'error'); }
      });
    });

    $('queueForm').addEventListener('submit', (event) => {
      event.preventDefault();
      withBusy(async () => {
        try {
          if ($('queueButton').dataset.queued) await rpc('jl_ludo_leave_queue', { p_token:state.token });
          else {
            const amount = wholeStake($('queueBet').value);
            if (amount === null || !ensureFunds(amount, 'entrar na fila')) return;
            await rpc('jl_ludo_enter_queue', { p_token:state.token, p_bet_amount:amount, p_player_count:Number($('queuePlayers').value), p_mode:$('queueMode').value });
          }
          await requestSync('queue');
        } catch (error) { showToast(error.message, 'error'); }
      });
    });

    $('inviteList').addEventListener('click', (event) => {
      const accept = event.target.closest('[data-invite-accept]');
      const decline = event.target.closest('[data-invite-decline]');
      if (!accept && !decline) return;
      withBusy(async () => {
        const button = accept || decline;
        const amount = Number(accept?.dataset.bet || 0);
        if (accept && amount > 0 && !ensureFunds(amount, 'aceitar este convite')) return;
        try {
          const joined = await rpc('jl_ludo_accept_invite', { p_token:state.token, p_invitation:button.dataset[accept ? 'inviteAccept' : 'inviteDecline'], p_accept:Boolean(accept) });
          if (accept && joined?.room) state.room = await applyPreferences(joined);
          await requestSync('invite');
        } catch (error) {
          if (!handleMoneyError(error, amount, 'aceitar este convite')) showToast(error.message, 'error');
        }
      });
    });

    $('publicChallengeList').addEventListener('click', (event) => {
      const button = event.target.closest('[data-public-accept]');
      if (!button) return;
      const amount = Number(button.dataset.bet || 0);
      if (amount > 0 && !ensureFunds(amount, 'entrar neste desafio')) return;
      withBusy(async () => {
        try {
          const joined = await rpc('jl_ludo_accept_public_challenge', { p_token:state.token, p_code:button.dataset.publicAccept });
          state.room = await applyPreferences(joined);
          await requestSync('public-challenge');
        } catch (error) {
          if (!handleMoneyError(error, amount, 'entrar neste desafio')) showToast(error.message, 'error');
        }
      });
    });

    $('directInviteShortcut').addEventListener('click', () => $('notificationsPanel')?.scrollIntoView({behavior:'smooth',block:'start'}));
    $('publicChallengeShortcut').addEventListener('click', () => $('notificationsPanel')?.scrollIntoView({behavior:'smooth',block:'start'}));

    $('copyRoomCode').addEventListener('click', async () => {
      const code = roomData()?.code || '';
      try { await navigator.clipboard.writeText(code); showToast('Código copiado.', 'success'); }
      catch { showToast(code); }
    });

    $('leaveRoom').addEventListener('click', () => withBusy(async () => {
      try {
        await rpc('jl_ludo_cancel_or_leave', { p_token:state.token, p_room:roomData().id });
        state.room = null;
        state.recoveringRoomId = '';
        await requestSync('leave-room');
        showToast('Saiu da sala.');
      } catch (error) { showToast(error.message, 'error'); }
    }));

    $('forfeitRoom').addEventListener('click', () => {
      if (!confirm('Desistir desta partida? Esta ação não pode ser anulada.')) return;
      withBusy(async () => {
        try {
          await rpc('jl_ludo_forfeit', { p_token:state.token, p_room:roomData().id });
          await requestSync('forfeit');
          showToast('Você desistiu da partida.');
        } catch (error) { showToast(error.message, 'error'); }
      });
    });

    $('refreshWaiting').addEventListener('click', () => loadWaitingPlayers(true));
    $('searchPlayerForm').addEventListener('submit', (event) => {
      event.preventDefault();
      withBusy(async () => {
        try {
          const rows = await rpc('jl_ludo_find_players', { p_token:state.token, p_query:$('searchPlayer').value.trim() });
          $('playerSearchResults').innerHTML = Array.isArray(rows) && rows.length ? rows.map((player) => `<div class="list-item"><div><strong>${esc(player.name || 'Jogador')}</strong><small>${esc(player.code || '')}</small></div><button class="button ghost small" type="button" data-invite-player="${esc(player.player_id)}">Convidar</button></div>`).join('') : '<div class="empty">Nenhum jogador encontrado.</div>';
        } catch (error) { showToast(error.message, 'error'); }
      });
    });

    document.addEventListener('click', (event) => {
      const invite = event.target.closest('[data-invite-player]');
      if (!invite) return;
      withBusy(async () => {
        try {
          await rpc('jl_ludo_invite', { p_token:state.token, p_room:roomData().id, p_target_player:invite.dataset.invitePlayer });
          showToast('Convite enviado.', 'success');
        } catch (error) { showToast(error.message, 'error'); }
      });
    });

    $('rulesForm').addEventListener('input', () => { state.rulesDirty = true; });
    $('rulesForm').addEventListener('change', () => { state.rulesDirty = true; });
    $('rulesForm').addEventListener('submit', (event) => {
      event.preventDefault();
      withBusy(async () => {
        try {
          state.room = await rpc('jl_ludo_update_rules', { p_token:state.token, p_room:roomData().id, p_rules:readRulesForm() });
          state.rulesDirty = false;
          await requestSync('rules-update');
          showToast('Nova versão das regras proposta.', 'success');
        } catch (error) { showToast(error.message, 'error'); }
      });
    });

    $('acceptRules').addEventListener('click', () => withBusy(async () => {
      try {
        state.room = await rpc('jl_ludo_accept_rules', { p_token:state.token, p_room:roomData().id, p_accept:true });
        await requestSync('accept-rules');
        showToast('Regras aceites.', 'success');
      } catch (error) { showToast(error.message, 'error'); }
    }));

    $('declineRules').addEventListener('click', () => withBusy(async () => {
      try {
        state.room = await rpc('jl_ludo_accept_rules', { p_token:state.token, p_room:roomData().id, p_accept:false });
        await requestSync('decline-rules');
        showToast('Regras recusadas.');
      } catch (error) { showToast(error.message, 'error'); }
    }));

    $('fundButton').addEventListener('click', () => {
      const amount = Number(roomData()?.bet_amount || 0);
      if (!ensureFunds(amount, 'confirmar esta aposta')) return;
      withBusy(async () => {
        try {
          state.room = await rpc('jl_ludo_commit_stake', { p_token:state.token, p_room:roomData().id });
          await requestSync('fund');
          showToast('Aposta confirmada.', 'success');
        } catch (error) {
          if (!handleMoneyError(error, amount, 'confirmar esta aposta')) showToast(error.message, 'error');
        }
      });
    });

    $('stakeProposalSend').addEventListener('click', () => {
      const amount = wholeStake($('stakeProposalAmount').value, 'O novo valor');
      if (amount === null) return;
      withBusy(async () => {
        try {
          state.room = await rpc('jl_ludo_propose_bet', { p_token:state.token, p_room:roomData().id, p_bet_amount:amount });
          await requestSync('bet-proposal');
          showToast(`Novo valor proposto: ${money(amount)} MZN.`, 'success');
        } catch (error) { showToast(error.message, 'error'); }
      });
    });

    $('rollDice').addEventListener('click', () => withBusy(async () => {
      const r = roomData();
      if (!r || r.status !== 'playing' || String(r.current_player_id) !== String(me())) return;
      const dice = $('rollDice');
      dice.classList.add('rolling');
      dice.disabled = true;
      try {
        const result = await rpc('jl_ludo_roll', { p_token:state.token, p_room:r.id });
        if (result?.room) state.room = result;
        renderRoom();
        state.pendingRefresh = true;
      } catch (error) { showToast(error.message, 'error'); }
      finally { setTimeout(() => dice.classList.remove('rolling'), 250); }
    }));

    $('ludoBoard').addEventListener('click', (event) => {
      const piece = event.target.closest('.piece.legal');
      if (!piece) return;
      const tokenNo = Number(piece.dataset.tokenNo);
      if (!Number.isInteger(tokenNo)) return;
      withBusy(async () => {
        try {
          const result = await rpc('jl_ludo_move', { p_token:state.token, p_room:roomData().id, p_token_no:tokenNo });
          if (result?.room) state.room = result;
          renderRoom();
          state.pendingRefresh = true;
        } catch (error) { showToast(error.message, 'error'); }
      });
    });

    $('reenterButton').addEventListener('click', () => {
      const amount = Number(rules().reentry_amount || 0);
      if (!ensureFunds(amount, 'pagar a reentrada')) return;
      withBusy(async () => {
        try {
          state.room = await rpc('jl_ludo_reenter', { p_token:state.token, p_room:roomData().id });
          await requestSync('reentry');
          showToast('Reentrada confirmada.', 'success');
        } catch (error) {
          if (!handleMoneyError(error, amount, 'pagar a reentrada')) showToast(error.message, 'error');
        }
      });
    });

    $('chatForm').addEventListener('submit', (event) => {
      event.preventDefault();
      const message = $('chatInput').value.trim();
      if (!message) return;
      withBusy(async () => {
        try {
          await rpc('jl_ludo_send_chat', { p_token:state.token, p_room:roomData().id, p_message:message });
          $('chatInput').value = '';
          await requestSync('chat');
        } catch (error) { showToast(error.message, 'error'); }
      });
    });

    $('rematchButton').addEventListener('click', () => {
      const amount = wholeStake($('rematchBet').value, 'A nova aposta');
      if (amount === null || !ensureFunds(amount, 'criar a revanche')) return;
      withBusy(async () => {
        try {
          const turn = Number($('rematchTurn').value || 30);
          state.preferredColor = $('rematchColor').value;
          localStorage.setItem('jl_ludo_preferred_color', state.preferredColor);
          const next = await rpc('jl_ludo_rematch_v2', {
            p_token:state.token,
            p_room:roomData().id,
            p_bet_amount:amount,
            p_mode:$('rematchMode').value,
            p_rules:{ turn_seconds:turn, move_seconds:turn, pawn_count:Number($('rematchPawns').value || 4), dice_count:Number($('rematchDice').value || 1) }
          });
          state.room = await applyPreferences(next);
          await requestSync('rematch');
          showToast('Revanche criada.', 'success');
        } catch (error) {
          if (!handleMoneyError(error, amount, 'criar a revanche')) showToast(error.message, 'error');
        }
      });
    });

    window.addEventListener('jl-player-session-changed', (event) => {
      state.token = getToken();
      if (!event.detail?.authenticated) {
        state.status = null;
        state.room = null;
        state.recoveringRoomId = '';
        render();
      } else requestSync('session-change');
    });
    window.addEventListener('pageshow', () => requestSync('pageshow'));
    window.addEventListener('focus', () => requestSync('focus'));
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') requestSync('visible'); });
  }

  function initializeClock() {
    clearInterval(state.clockTimer);
    state.clockTimer = setInterval(() => { if (state.room?.room) updateClock(); }, 250);
  }

  async function boot() {
    wireEvents();
    initializeClock();
    state.token = getToken();
    if (BOARD_INVITE_ID) {
      $('createPlayers').value = '2';
      $('createPlayers').disabled = true;
    }
    if (COLORS.has(state.preferredColor)) {
      $('createColor').value = state.preferredColor;
      document.querySelectorAll('[data-color]').forEach((el) => {
        const active = el.dataset.color === state.preferredColor;
        el.classList.toggle('active', active);
        el.setAttribute('aria-pressed', active ? 'true' : 'false');
      });
    }
    $('createPawnStyle').value = state.preferredPawnStyle || 'current';
    await requestSync('startup');
  }

  boot().catch((error) => {
    state.loading = false;
    state.error = String(error?.message || error || 'Falha ao abrir Ludo.');
    $('bootMessage').textContent = state.error;
    showToast(state.error, 'error');
  });
})();
