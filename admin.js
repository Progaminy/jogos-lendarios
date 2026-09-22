(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_admin_token';
  const $ = (id) => document.getElementById(id);

  const state = {
    token: localStorage.getItem(TOKEN_KEY) || '',
    data: null,
    refreshTimer: null,
    supportPlayerId: null,
    supportThread: null,
    countdowns: { number: null, pair: null }
  };

  const shared = {
    toast: $('toast'),
    adminLogin: $('adminLogin'),
    adminApp: $('adminApp'),
    adminLogout: $('adminLogout'),
    refreshAdmin: $('refreshAdmin'),
    adminLoginForm: $('adminLoginForm'),
    adminCode: $('adminCode'),
    adminLoginMessage: $('adminLoginMessage'),
    depositRequests: $('depositRequests'),
    withdrawRequests: $('withdrawRequests'),
    playersList: $('playersList'),
    supportThreads: $('supportThreads'),
    supportUnreadBadge: $('supportUnreadBadge'),
    supportConversation: $('supportConversation'),
    supportConversationTitle: $('supportConversationTitle'),
    supportConversationClose: $('supportConversationClose'),
    supportAdminMessages: $('supportAdminMessages'),
    supportReplyForm: $('supportReplyForm'),
    supportReplyInput: $('supportReplyInput')
  };

  const games = {
    number: {
      label: 'Número Lendário',
      metricRound: $('numberMetricRound'),
      metricStatus: $('numberMetricStatus'),
      metricCountdown: $('numberMetricCountdown'),
      metricResult: $('numberMetricResult'),
      minBet: $('numberMinBet'),
      maxBet: $('numberMaxBet'),
      multiplier: $('numberMultiplier'),
      lockSeconds: $('numberLockSeconds'),
      drawMode: $('numberDrawMode'),
      enabled: $('numberEnabled'),
      saveSettings: $('numberSaveSettings'),
      manualAt: $('numberManualAt'),
      openRound: $('numberOpenRound'),
      closeRound: $('numberCloseRound'),
      scheduleStart: $('numberScheduleStart'),
      scheduleEnd: $('numberScheduleEnd'),
      scheduleInterval: $('numberScheduleInterval'),
      schedulePeriod: $('numberSchedulePeriod'),
      singleAt: $('numberSingleAt'),
      addTime: $('numberAddTime'),
      clearSchedule: $('numberClearSchedule'),
      schedule: $('numberSchedule'),
      stats: $('numberStats'),
      recent: $('numberRecentBets')
    },
    pair: {
      label: 'Dupla Lendária',
      metricRound: $('pairMetricRound'),
      metricStatus: $('pairMetricStatus'),
      metricCountdown: $('pairMetricCountdown'),
      metricResult: $('pairMetricResult'),
      minBet: $('pairMinBet'),
      maxBet: $('pairMaxBet'),
      multiplier: $('pairMultiplier'),
      lockSeconds: $('pairLockSeconds'),
      drawMode: $('pairDrawMode'),
      enabled: $('pairEnabled'),
      saveSettings: $('pairSaveSettings'),
      manualAt: $('pairManualAt'),
      openRound: $('pairOpenRound'),
      closeRound: $('pairCloseRound'),
      scheduleStart: $('pairScheduleStart'),
      scheduleEnd: $('pairScheduleEnd'),
      scheduleInterval: $('pairScheduleInterval'),
      schedulePeriod: $('pairSchedulePeriod'),
      singleAt: $('pairSingleAt'),
      addTime: $('pairAddTime'),
      clearSchedule: $('pairClearSchedule'),
      schedule: $('pairSchedule'),
      stats: $('pairStats'),
      recent: $('pairRecentBets')
    }
  };

  function money(value) {
    return Number(value || 0).toLocaleString('pt-MZ', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    });
  }

  function dateTime(value) {
    return value
      ? new Date(value).toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' })
      : '—';
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[c]));
  }

  function clock(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const d = Math.floor(total / 86400);
    const h = Math.floor((total % 86400) / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const value = [h, m, s].map((v) => String(v).padStart(2, '0')).join(':');
    return d ? `${d}d ${value}` : value;
  }

  function toast(message, type = '') {
    shared.toast.textContent = message;
    shared.toast.className = `toast show ${type}`.trim();
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { shared.toast.className = 'toast'; }, 3800);
  }

  function loginMessage(message = '', type = '') {
    shared.adminLoginMessage.textContent = message;
    shared.adminLoginMessage.className = `form-message ${type}`.trim();
  }

  function toLocalInput(date) {
    return new Date(date.getTime() - date.getTimezoneOffset() * 60000)
      .toISOString()
      .slice(0, 16);
  }

  function fromInput(input) {
    const value = new Date(input.value);
    return Number.isNaN(value.getTime()) ? null : value;
  }

  async function rpc(name, args = {}) {
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
    let payload = null;
    try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }
    if (!response.ok) {
      throw new Error(payload?.message || payload?.error || payload?.hint || `Erro ${response.status}`);
    }
    return payload;
  }

  function saveToken(token) {
    state.token = token || '';
    if (state.token) localStorage.setItem(TOKEN_KEY, state.token);
    else localStorage.removeItem(TOKEN_KEY);
  }

  function showApp(show) {
    shared.adminLogin.classList.toggle('hidden', show);
    shared.adminApp.classList.toggle('hidden', !show);
    shared.adminLogout.classList.toggle('hidden', !show);
    shared.refreshAdmin.classList.toggle('hidden', !show);
  }

  function setDefaultTimes(type) {
    const ui = games[type];
    const manual = new Date(Date.now() + 30 * 60 * 1000);
    manual.setSeconds(0, 0);
    ui.manualAt.value = toLocalInput(manual);
    ui.singleAt.value = toLocalInput(manual);

    const start = new Date();
    start.setMinutes(0, 0, 0);
    start.setHours(start.getHours() + 1);
    ui.scheduleStart.value = toLocalInput(start);
    ui.scheduleEnd.value = toLocalInput(new Date(start.getTime() + 12 * 60 * 60 * 1000));
    ui.scheduleInterval.value = '60';
  }

  function gameData(type) {
    return state.data?.games?.[type] || {};
  }

  function renderSettings(type) {
    const ui = games[type];
    const settings = gameData(type).settings || {};
    ui.minBet.value = settings.min_bet ?? '';
    ui.maxBet.value = settings.max_bet ?? '';
    ui.multiplier.value = settings.multiplier ?? '';
    ui.lockSeconds.value = settings.lock_seconds ?? '';
    ui.drawMode.value = settings.draw_mode || 'house_min';
    ui.enabled.value = String(settings.enabled !== false);

    const active = Boolean(gameData(type).round);
    ui.saveSettings.disabled = active;
  }

  function renderMetrics(type) {
    const ui = games[type];
    const data = gameData(type);
    const round = data.round;
    const last = data.last_result;
    clearInterval(state.countdowns[type]);

    if (type === 'number') {
      ui.metricResult.textContent = last?.drawn_number ?? '—';
    } else {
      ui.metricResult.textContent =
        last?.pair_drawn_a != null && last?.pair_drawn_b != null
          ? `${last.pair_drawn_a} + ${last.pair_drawn_b}`
          : '—';
    }

    if (!round) {
      ui.metricRound.textContent = '—';
      ui.metricStatus.textContent = data.settings?.enabled === false ? 'Desativado' : 'Sem rodada';
      ui.metricCountdown.textContent = data.schedule?.length ? dateTime(data.schedule[0].draw_at) : '—';
      ui.openRound.disabled = data.settings?.enabled === false;
      ui.closeRound.disabled = true;
      return;
    }

    ui.metricRound.textContent = `#${round.round_no}`;
    ui.openRound.disabled = true;
    ui.closeRound.disabled = false;

    const closeAt = new Date(round.closes_at).getTime();
    const drawAt = new Date(round.draw_at).getTime();

    const tick = () => {
      const now = Date.now();
      if (round.status === 'open' && now < closeAt) {
        ui.metricStatus.textContent = 'Aberta';
        ui.metricCountdown.textContent = `Bloqueio em ${clock(closeAt - now)}`;
      } else if (now < drawAt) {
        ui.metricStatus.textContent = 'Bloqueada';
        ui.metricCountdown.textContent = `Sorteio em ${clock(drawAt - now)}`;
      } else {
        ui.metricStatus.textContent = 'Processando';
        ui.metricCountdown.textContent = '00:00:00';
      }
    };

    tick();
    state.countdowns[type] = setInterval(tick, 1000);
  }

  function renderSchedule(type) {
    const ui = games[type];
    const items = gameData(type).schedule || [];
    ui.clearSchedule.disabled = !items.some((item) => item.status === 'pending');

    if (!items.length) {
      ui.schedule.innerHTML = '<div class="empty">Nenhum horário futuro programado.</div>';
      return;
    }

    ui.schedule.innerHTML = items.map((item) => {
      const active = item.status === 'active';
      const action = item.status === 'pending'
        ? `<button class="button danger small" data-cancel-game="${type}" data-cancel-id="${item.id}">Cancelar</button>`
        : '<span class="badge success">Em execução</span>';

      return `<div class="request-row">
        <div>
          <strong>${dateTime(item.draw_at)}</strong><br>
          <small>${active ? 'RODADA ATIVA' : 'PROGRAMADO'}</small>
        </div>
        <strong>${active ? 'Agora' : 'Futuro'}</strong>
        <div class="row-actions">${action}</div>
      </div>`;
    }).join('');
  }

  function renderStats(type) {
    const ui = games[type];
    const data = gameData(type);
    const stats = data.stats || [];

    if (!data.round) {
      ui.stats.innerHTML = '<div class="empty">Sem rodada ativa.</div>';
      return;
    }

    ui.stats.innerHTML = stats.map((item) => {
      const label = type === 'number' ? item.number : `${item.number_a}+${item.number_b}`;
      return `<div class="number-stat">
        <strong>${label}</strong>
        <span>${item.bets} aposta${Number(item.bets) === 1 ? '' : 's'}</span>
        <small>MZN ${money(item.total)}</small>
      </div>`;
    }).join('');
  }

  function renderRecent(type) {
    const ui = games[type];
    const bets = gameData(type).recent_bets || [];

    if (!bets.length) {
      ui.recent.innerHTML = '<div class="empty">Ainda não há apostas.</div>';
      return;
    }

    ui.recent.innerHTML = bets.map((bet) => {
      const choice = type === 'number'
        ? `número ${bet.selected_number}`
        : `combinação ${bet.number_a}+${bet.number_b}`;

      const stateLabel = bet.won === true
        ? '<span class="win">Vencedora</span>'
        : bet.won === false
          ? '<span class="lose">Não premiada</span>'
          : '<span class="pending">Pendente</span>';

      return `<div class="request-row">
        <div>
          <strong>${escapeHtml(bet.name)}</strong><br>
          <small>Rodada ${bet.round_no} · ${choice} · ${dateTime(bet.created_at)}</small>
        </div>
        <strong>MZN ${money(bet.amount)}</strong>
        <div>${stateLabel}</div>
      </div>`;
    }).join('');
  }

  function renderSupportThreads() {
    const rows = state.data?.support_threads || [];
    const unread = rows.reduce((sum,r)=>sum+Number(r.unread_count||0),0);
    if (shared.supportUnreadBadge) {
      shared.supportUnreadBadge.textContent = `${unread} não lida${unread===1?'':'s'}`;
      shared.supportUnreadBadge.className = `badge ${unread?'danger':'muted'}`;
    }
    if (!shared.supportThreads) return;
    shared.supportThreads.innerHTML = rows.length ? rows.map(r=>`
      <button class="support-thread ${state.supportPlayerId===r.player_id?'active':''}" type="button" data-support-player="${r.player_id}">
        <div>
          <strong>${escapeHtml(r.name)}</strong>
          <small>+${escapeHtml(r.phone)} · ${dateTime(r.last_message_at)}</small>
          <div class="support-thread-preview">${r.last_sender==='admin'?'Admin: ':'Jogador: '}${escapeHtml(r.last_message||'')}</div>
        </div>
        ${Number(r.unread_count)>0?`<span class="support-unread">${Number(r.unread_count)}</span>`:''}
      </button>`).join('') : '<div class="empty">Nenhuma mensagem de cliente.</div>';
  }

  function renderSupportConversation() {
    const thread = state.supportThread;
    if (!thread || !state.supportPlayerId) {
      shared.supportConversation?.classList.add('hidden');
      return;
    }
    shared.supportConversation?.classList.remove('hidden');
    shared.supportConversationTitle.textContent = `${thread.player?.name||'Jogador'} · +${thread.player?.phone||''}`;
    const messages = thread.messages || [];
    shared.supportAdminMessages.innerHTML = messages.length ? messages.map(m=>`
      <div class="support-admin-msg ${m.sender==='admin'?'admin':'player'}">
        <strong>${m.sender==='admin'?'Admin':'Jogador'}</strong>
        <div>${escapeHtml(m.message)}</div>
        <small>${dateTime(m.created_at)}</small>
      </div>`).join('') : '<div class="empty">Sem mensagens.</div>';
    shared.supportAdminMessages.scrollTop = shared.supportAdminMessages.scrollHeight;
  }

  async function loadSupportThread(playerId, silent=false) {
    try {
      state.supportPlayerId = playerId;
      state.supportThread = await rpc('jl_admin_support_thread',{p_token:state.token,p_player_id:playerId});
      renderSupportThreads();
      renderSupportConversation();
      state.data.support_threads = await rpc('jl_admin_support_threads',{p_token:state.token});
      renderSupportThreads();
    } catch(error) {
      if(!silent) toast(error.message,'error');
    }
  }

  function renderShared() {
    const deposits = state.data?.pending_deposits || [];
    shared.depositRequests.innerHTML = deposits.length
      ? deposits.map((r) => `<div class="request-row">
          <div><strong>${escapeHtml(r.name)}</strong><br><small>+${escapeHtml(r.phone)} · ${dateTime(r.created_at)}${r.note ? ` · ${escapeHtml(r.note)}` : ''}</small></div>
          <strong>MZN ${money(r.amount)}</strong>
          <div class="row-actions">
            <button class="button success small" data-deposit="${r.id}" data-decision="approved">Aprovar</button>
            <button class="button danger small" data-deposit="${r.id}" data-decision="rejected">Rejeitar</button>
          </div>
        </div>`).join('')
      : '<div class="empty">Nenhum depósito pendente.</div>';

    const withdrawals = state.data?.pending_withdrawals || [];
    shared.withdrawRequests.innerHTML = withdrawals.length
      ? withdrawals.map((r) => `<div class="request-row">
          <div><strong>${escapeHtml(r.name)}</strong><br><small>+${escapeHtml(r.phone)} · ${dateTime(r.created_at)}</small><br><small>Sacável após bloqueios: MZN ${money(r.withdrawable_balance??0)} · Por jogar: MZN ${money(r.deposit_locked||0)}</small></div>
          <strong>MZN ${money(r.amount)}</strong>
          <div class="row-actions">
            <button class="button success small" data-withdraw="${r.id}" data-decision="approved">Autorizar</button>
            <button class="button danger small" data-withdraw="${r.id}" data-decision="rejected">Rejeitar</button>
          </div>
        </div>`).join('')
      : '<div class="empty">Nenhum saque pendente.</div>';

    const players = state.data?.players || [];
    shared.playersList.innerHTML = players.length
      ? players.map((p) => `<div class="player-row">
          <div><strong>${escapeHtml(p.name)}</strong><br><small>+${escapeHtml(p.phone)} · ${dateTime(p.created_at)}${p.blocked ? ' · BLOQUEADO' : ''}</small><br><small>Sacável: MZN ${money(p.withdrawable_balance??p.balance)} · Por jogar: MZN ${money(p.deposit_locked||0)}</small></div>
          <strong>MZN ${money(p.balance)}</strong>
          <div class="row-actions">
            <button class="button ghost small" data-adjust="${p.id}" data-name="${escapeHtml(p.name)}">Ajustar saldo</button>
            <button class="button ${p.blocked ? 'success' : 'danger'} small" data-block="${p.id}" data-value="${p.blocked ? 'false' : 'true'}">${p.blocked ? 'Desbloquear' : 'Bloquear'}</button>
          </div>
        </div>`).join('')
      : '<div class="empty">Nenhum jogador cadastrado.</div>';

    renderSupportThreads();
    renderSupportConversation();
  }

  function render() {
    for (const type of ['number', 'pair']) {
      renderSettings(type);
      renderMetrics(type);
      renderSchedule(type);
      renderStats(type);
      renderRecent(type);
    }
    renderShared();
  }

  async function refresh(silent = false) {
    if (!state.token) return showApp(false);
    try {
      state.data = await rpc('jl_admin_dashboard', { p_token: state.token });
      try { state.data.support_threads = await rpc('jl_admin_support_threads',{p_token:state.token}); }
      catch { state.data.support_threads = []; }
      if (state.supportPlayerId) {
        try { state.supportThread = await rpc('jl_admin_support_thread',{p_token:state.token,p_player_id:state.supportPlayerId}); }
        catch { state.supportThread = null; state.supportPlayerId = null; }
      }
      showApp(true);
      render();
    } catch (error) {
      if (/sessão|session|administrativa/i.test(error.message)) {
        saveToken('');
        showApp(false);
        if (!silent) loginMessage('Sessão expirada. Entre novamente.', 'error');
      } else if (!silent) {
        toast(error.message, 'error');
      }
    }
  }

  async function runAction(fn, args, success) {
    try {
      const result = await rpc(fn, { p_token: state.token, ...args });
      toast(result?.message || success || 'Operação concluída.', 'success');
      await refresh(true);
      return result;
    } catch (error) {
      toast(error.message, 'error');
      return null;
    }
  }

  function wireGame(type) {
    const ui = games[type];

    ui.saveSettings.addEventListener('click', async () => {
      const minBet = Number(ui.minBet.value);
      const maxBet = Number(ui.maxBet.value);
      if (!Number.isInteger(minBet) || !Number.isInteger(maxBet) || minBet < 10 || maxBet < minBet) {
        return toast('As apostas devem usar valores inteiros, com mínimo de 10 MZN e máximo igual ou superior ao mínimo.', 'error');
      }
      await runAction('jl_admin_update_game_settings', {
        p_game_type: type,
        p_min_bet: minBet,
        p_max_bet: maxBet,
        p_multiplier: Number(ui.multiplier.value),
        p_lock_seconds: Number(ui.lockSeconds.value),
        p_draw_mode: ui.drawMode.value,
        p_enabled: ui.enabled.value === 'true'
      }, `${ui.label}: regras guardadas.`);
    });

    ui.openRound.addEventListener('click', async () => {
      const drawAt = fromInput(ui.manualAt);
      if (!drawAt) return toast(`Defina uma hora válida para ${ui.label}.`, 'error');
      await runAction('jl_admin_open_game_round', {
        p_game_type: type,
        p_draw_at: drawAt.toISOString()
      }, `${ui.label}: rodada aberta.`);
    });

    ui.closeRound.addEventListener('click', async () => {
      if (!window.confirm(`Encerrar e sortear agora somente o ${ui.label}?`)) return;
      await runAction('jl_admin_close_game_round', {
        p_game_type: type
      }, `${ui.label}: rodada encerrada.`);
    });

    ui.schedulePeriod.addEventListener('click', async () => {
      const start = fromInput(ui.scheduleStart);
      const end = fromInput(ui.scheduleEnd);
      const interval = Number(ui.scheduleInterval.value);
      if (!start || !end) return toast(`Informe início e fim para ${ui.label}.`, 'error');
      if (!Number.isInteger(interval) || interval < 1 || interval > 1440) {
        return toast('Intervalo inválido.', 'error');
      }

      await runAction('jl_admin_schedule_game_draws', {
        p_game_type: type,
        p_start_at: start.toISOString(),
        p_end_at: end.toISOString(),
        p_interval_minutes: interval
      }, `${ui.label}: programação criada.`);
    });

    ui.addTime.addEventListener('click', async () => {
      const drawAt = fromInput(ui.singleAt);
      if (!drawAt) return toast('Informe um horário válido.', 'error');
      await runAction('jl_admin_add_game_draw_time', {
        p_game_type: type,
        p_draw_at: drawAt.toISOString()
      }, `${ui.label}: horário adicionado.`);
    });

    ui.clearSchedule.addEventListener('click', async () => {
      if (!window.confirm(`Cancelar apenas os horários futuros do ${ui.label}?`)) return;
      await runAction('jl_admin_clear_game_schedule', {
        p_game_type: type
      }, `${ui.label}: horários futuros cancelados.`);
    });

    ui.schedule.addEventListener('click', async (event) => {
      const button = event.target.closest('[data-cancel-id]');
      if (!button) return;
      await runAction('jl_admin_cancel_game_draw_time', {
        p_game_type: type,
        p_schedule_id: button.dataset.cancelId
      }, `${ui.label}: horário cancelado.`);
    });
  }

  shared.adminLoginForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      loginMessage('Validando…');
      const result = await rpc('jl_admin_login', { p_code: shared.adminCode.value });
      saveToken(result.token);
      shared.adminCode.value = '';
      loginMessage('');
      await refresh(true);
      toast('Acesso administrativo autorizado.', 'success');
    } catch (error) {
      loginMessage(error.message, 'error');
    }
  });

  shared.adminLogout.addEventListener('click', async () => {
    try { await rpc('jl_admin_logout', { p_token: state.token }); } catch {}
    saveToken('');
    state.data = null;
    showApp(false);
  });

  shared.refreshAdmin.addEventListener('click', () => refresh());

  shared.depositRequests.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-deposit]');
    if (!button) return;
    await runAction('jl_admin_review_deposit', {
      p_request_id: button.dataset.deposit,
      p_decision: button.dataset.decision
    }, 'Pedido de depósito atualizado.');
  });

  shared.withdrawRequests.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-withdraw]');
    if (!button) return;
    await runAction('jl_admin_review_withdrawal', {
      p_request_id: button.dataset.withdraw,
      p_decision: button.dataset.decision
    }, 'Pedido de saque atualizado.');
  });

  shared.playersList.addEventListener('click', async (event) => {
    const adjust = event.target.closest('[data-adjust]');
    if (adjust) {
      const raw = window.prompt(`Ajuste de saldo para ${adjust.dataset.name}.\nPositivo adiciona; negativo retira:`);
      if (raw === null) return;
      const delta = Number(String(raw).replace(',', '.'));
      if (!Number.isFinite(delta) || delta === 0) return toast('Ajuste inválido.', 'error');
      const note = window.prompt('Motivo do ajuste (opcional):') || '';
      await runAction('jl_admin_adjust_balance', {
        p_player_id: adjust.dataset.adjust,
        p_delta: delta,
        p_note: note
      }, 'Saldo ajustado.');
      return;
    }

    const block = event.target.closest('[data-block]');
    if (block) {
      const blocked = block.dataset.value === 'true';
      await runAction('jl_admin_set_blocked', {
        p_player_id: block.dataset.block,
        p_blocked: blocked
      }, blocked ? 'Jogador bloqueado.' : 'Jogador desbloqueado.');
    }
  });

  shared.supportThreads?.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-support-player]');
    if (!button) return;
    await loadSupportThread(button.dataset.supportPlayer);
  });

  shared.supportConversationClose?.addEventListener('click',()=>{
    state.supportPlayerId=null;
    state.supportThread=null;
    renderSupportThreads();
    renderSupportConversation();
  });

  shared.supportReplyForm?.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!state.supportPlayerId) return;
    const message = shared.supportReplyInput.value.trim();
    if (!message) return;
    try {
      await rpc('jl_admin_support_reply',{p_token:state.token,p_player_id:state.supportPlayerId,p_message:message});
      shared.supportReplyInput.value='';
      await loadSupportThread(state.supportPlayerId,true);
      toast('Resposta enviada ao jogador.','success');
    } catch(error) { toast(error.message,'error'); }
  });

  wireGame('number');
  wireGame('pair');
  setDefaultTimes('number');
  setDefaultTimes('pair');

  showApp(Boolean(state.token));
  if (state.token) refresh(true);
  state.refreshTimer = setInterval(() => {
    if (state.token) refresh(true);
  }, 5000);
})();