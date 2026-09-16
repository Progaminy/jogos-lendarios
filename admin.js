(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_admin_token';
  const $ = (id) => document.getElementById(id);
  const state = { token: localStorage.getItem(TOKEN_KEY) || '', data: null, timer: null, countdownTimer: null };

  const els = {
    toast: $('toast'), adminLogin: $('adminLogin'), adminApp: $('adminApp'), adminLogout: $('adminLogout'),
    adminLoginForm: $('adminLoginForm'), adminCode: $('adminCode'), adminLoginMessage: $('adminLoginMessage'),
    metricRound: $('metricRound'), metricStatus: $('metricStatus'), metricCountdown: $('metricCountdown'), metricDraw: $('metricDraw'),
    closeAt: $('closeAt'), openRound: $('openRound'), closeRound: $('closeRound'), refreshAdmin: $('refreshAdmin'),
    scheduleStart: $('scheduleStart'), scheduleEnd: $('scheduleEnd'), scheduleInterval: $('scheduleInterval'),
    quick12: $('quick12'), quick24: $('quick24'), schedulePeriod: $('schedulePeriod'),
    singleDrawAt: $('singleDrawAt'), addDrawTime: $('addDrawTime'), clearSchedule: $('clearSchedule'), drawSchedule: $('drawSchedule'),
    numberStats: $('numberStats'), depositRequests: $('depositRequests'), withdrawRequests: $('withdrawRequests'),
    playersList: $('playersList'), recentBets: $('recentBets')
  };

  function money(value) {
    return Number(value || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  function dateTime(value) {
    return value ? new Date(value).toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' }) : '—';
  }
  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (c) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', "'":'&#39;', '"':'&quot;' }[c]));
  }
  function toast(message, type = '') {
    els.toast.textContent = message;
    els.toast.className = `toast show ${type}`.trim();
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { els.toast.className = 'toast'; }, 3400);
  }
  function loginMessage(message = '', type = '') {
    els.adminLoginMessage.textContent = message;
    els.adminLoginMessage.className = `form-message ${type}`.trim();
  }
  function toLocalInput(date) {
    return new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
  }
  function fromInput(input) {
    const value = new Date(input.value);
    return Number.isNaN(value.getTime()) ? null : value;
  }
  function clock(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const days = Math.floor(total / 86400);
    const h = Math.floor((total % 86400) / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const text = [h, m, s].map((v) => String(v).padStart(2, '0')).join(':');
    return days ? `${days}d ${text}` : text;
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
    let payload;
    try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }
    if (!response.ok) throw new Error(payload?.message || payload?.error || payload?.hint || `Erro ${response.status}`);
    return payload;
  }

  function saveToken(token) {
    state.token = token || '';
    if (state.token) localStorage.setItem(TOKEN_KEY, state.token);
    else localStorage.removeItem(TOKEN_KEY);
  }

  function showApp(show) {
    els.adminLogin.classList.toggle('hidden', show);
    els.adminApp.classList.toggle('hidden', !show);
    els.adminLogout.classList.toggle('hidden', !show);
  }

  function setDefaultTimes() {
    const manual = new Date(Date.now() + 30 * 60 * 1000);
    manual.setSeconds(0, 0);
    els.closeAt.value = toLocalInput(manual);
    els.singleDrawAt.value = toLocalInput(manual);

    const start = new Date();
    start.setMinutes(0, 0, 0);
    start.setHours(start.getHours() + 1);
    const end = new Date(start.getTime() + 12 * 60 * 60 * 1000);
    els.scheduleStart.value = toLocalInput(start);
    els.scheduleEnd.value = toLocalInput(end);
    els.scheduleInterval.value = '60';
  }

  function setScheduleWindow(hours) {
    let start = fromInput(els.scheduleStart);
    if (!start || start.getTime() <= Date.now() + 10000) {
      start = new Date();
      start.setMinutes(0, 0, 0);
      start.setHours(start.getHours() + 1);
      els.scheduleStart.value = toLocalInput(start);
    }
    const end = new Date(start.getTime() + hours * 60 * 60 * 1000);
    els.scheduleEnd.value = toLocalInput(end);
    if (!els.scheduleInterval.value) els.scheduleInterval.value = '60';
  }

  function renderRound() {
    const round = state.data?.round;
    const last = state.data?.last_result;
    const schedule = state.data?.draw_schedule || [];
    clearInterval(state.countdownTimer);

    els.metricDraw.textContent = last?.drawn_number ?? '—';

    if (!round) {
      els.metricRound.textContent = last ? `#${last.round_no}` : '—';
      els.metricStatus.textContent = schedule.length ? 'Aguardando programação' : (last ? 'Finalizada' : 'Sem rodada');
      els.metricCountdown.textContent = schedule.length ? dateTime(schedule[0].draw_at) : '—';
      els.openRound.disabled = schedule.length > 0;
      els.closeRound.disabled = true;
      return;
    }

    els.metricRound.textContent = `#${round.round_no}`;
    els.openRound.disabled = true;
    els.closeRound.disabled = false;

    const closeAt = new Date(round.closes_at).getTime();
    const drawAt = new Date(round.draw_at || round.closes_at).getTime();
    const tick = () => {
      const now = Date.now();
      if (now < closeAt && round.status === 'open') {
        els.metricStatus.textContent = 'Aberta';
        els.metricCountdown.textContent = `Bloqueio ${clock(closeAt - now)}`;
      } else if (now < drawAt) {
        els.metricStatus.textContent = 'Apostas bloqueadas';
        els.metricCountdown.textContent = `Sorteio ${clock(drawAt - now)}`;
      } else {
        els.metricStatus.textContent = 'Processando sorteio';
        els.metricCountdown.textContent = '00:00:00';
      }
    };
    tick();
    state.countdownTimer = setInterval(tick, 1000);
  }

  function renderSchedule() {
    const items = state.data?.draw_schedule || [];
    els.clearSchedule.disabled = !items.some((item) => item.status === 'pending');
    if (!items.length) {
      els.drawSchedule.innerHTML = '<div class="empty">Nenhum horário futuro programado.</div>';
      return;
    }

    els.drawSchedule.innerHTML = items.map((item) => {
      const active = item.status === 'active';
      const label = active ? 'RODADA ATIVA' : 'PROGRAMADO';
      const action = item.status === 'pending'
        ? `<button class="button danger small" data-cancel-draw="${item.id}">Cancelar</button>`
        : '<span class="badge success">Em execução</span>';
      return `<div class="request-row">
        <div><strong>${dateTime(item.draw_at)}</strong><br><small>${label}${active && item.round_id ? ' · rodada vinculada' : ''}</small></div>
        <strong>${active ? 'Agora' : 'Futuro'}</strong>
        <div class="row-actions">${action}</div>
      </div>`;
    }).join('');
  }

  function renderStats() {
    if (!state.data?.round) {
      els.numberStats.innerHTML = '<div class="empty">Abra ou programe uma rodada para acompanhar as apostas por número.</div>';
      return;
    }
    const stats = state.data?.number_stats || [];
    els.numberStats.innerHTML = stats.map((item) => `
      <div class="number-stat">
        <strong>${item.number}</strong>
        <span>${item.bets} aposta${Number(item.bets) === 1 ? '' : 's'}</span>
        <small>MZN ${money(item.total)}</small>
      </div>`).join('');
  }

  function renderRequests() {
    const deposits = state.data?.pending_deposits || [];
    els.depositRequests.innerHTML = deposits.length ? deposits.map((r) => `
      <div class="request-row">
        <div><strong>${escapeHtml(r.name)}</strong><br><small>+${escapeHtml(r.phone)} · ${dateTime(r.created_at)}${r.note ? ` · ${escapeHtml(r.note)}` : ''}</small></div>
        <strong>MZN ${money(r.amount)}</strong>
        <div class="row-actions">
          <button class="button success small" data-deposit="${r.id}" data-decision="approved">Aprovar</button>
          <button class="button danger small" data-deposit="${r.id}" data-decision="rejected">Rejeitar</button>
        </div>
      </div>`).join('') : '<div class="empty">Nenhum depósito pendente.</div>';

    const withdrawals = state.data?.pending_withdrawals || [];
    els.withdrawRequests.innerHTML = withdrawals.length ? withdrawals.map((r) => `
      <div class="request-row">
        <div><strong>${escapeHtml(r.name)}</strong><br><small>+${escapeHtml(r.phone)} · ${dateTime(r.created_at)}</small></div>
        <strong>MZN ${money(r.amount)}</strong>
        <div class="row-actions">
          <button class="button success small" data-withdraw="${r.id}" data-decision="approved">Autorizar</button>
          <button class="button danger small" data-withdraw="${r.id}" data-decision="rejected">Rejeitar</button>
        </div>
      </div>`).join('') : '<div class="empty">Nenhum saque pendente.</div>';
  }

  function renderPlayers() {
    const players = state.data?.players || [];
    els.playersList.innerHTML = players.length ? players.map((p) => `
      <div class="player-row">
        <div><strong>${escapeHtml(p.name)}</strong><br><small>+${escapeHtml(p.phone)} · criado ${dateTime(p.created_at)}${p.blocked ? ' · BLOQUEADO' : ''}</small></div>
        <strong>MZN ${money(p.balance)}</strong>
        <div class="row-actions">
          <button class="button ghost small" data-adjust="${p.id}" data-name="${escapeHtml(p.name)}">Ajustar saldo</button>
          <button class="button ${p.blocked ? 'success' : 'danger'} small" data-block="${p.id}" data-value="${p.blocked ? 'false' : 'true'}">${p.blocked ? 'Desbloquear' : 'Bloquear'}</button>
        </div>
      </div>`).join('') : '<div class="empty">Nenhum jogador cadastrado.</div>';
  }

  function renderRecentBets() {
    const bets = state.data?.recent_bets || [];
    els.recentBets.innerHTML = bets.length ? bets.map((b) => `
      <div class="request-row">
        <div><strong>${escapeHtml(b.name)}</strong><br><small>Rodada ${b.round_no} · número ${b.selected_number} · ${dateTime(b.created_at)}</small></div>
        <strong>MZN ${money(b.amount)}</strong>
        <div>${b.won === true ? '<span class="win">Vencedora</span>' : b.won === false ? '<span class="lose">Não premiada</span>' : '<span class="pending">Pendente</span>'}</div>
      </div>`).join('') : '<div class="empty">Ainda não há apostas.</div>';
  }

  function render() {
    renderRound();
    renderSchedule();
    renderStats();
    renderRequests();
    renderPlayers();
    renderRecentBets();
  }

  async function refresh(silent = false) {
    if (!state.token) return showApp(false);
    try {
      state.data = await rpc('jl_admin_dashboard', { p_token: state.token });
      showApp(true);
      render();
    } catch (error) {
      if (/sessão|session|administrativa/i.test(error.message)) {
        saveToken('');
        showApp(false);
        if (!silent) loginMessage('Sessão expirada. Entre novamente.', 'error');
      } else if (!silent) toast(error.message, 'error');
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

  els.adminLoginForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      loginMessage('Validando…');
      const result = await rpc('jl_admin_login', { p_code: els.adminCode.value });
      saveToken(result.token);
      els.adminCode.value = '';
      loginMessage('');
      await refresh(true);
      toast('Acesso administrativo autorizado.', 'success');
    } catch (error) {
      loginMessage(error.message, 'error');
    }
  });

  els.adminLogout.addEventListener('click', async () => {
    try { await rpc('jl_admin_logout', { p_token: state.token }); } catch {}
    saveToken('');
    state.data = null;
    showApp(false);
  });

  els.refreshAdmin.addEventListener('click', () => refresh());

  els.openRound.addEventListener('click', async () => {
    const drawAt = fromInput(els.closeAt);
    if (!drawAt) return toast('Defina uma data e hora válida para o sorteio.', 'error');
    await runAction(
      'jl_admin_open_round',
      { p_closes_at: drawAt.toISOString() },
      'Jogo aberto. As apostas serão bloqueadas 3 segundos antes do sorteio.'
    );
  });

  els.closeRound.addEventListener('click', async () => {
    if (!window.confirm('Encerrar as apostas e executar o sorteio agora?')) return;
    await runAction('jl_admin_close_round', {}, 'Rodada encerrada e sorteada.');
  });

  els.quick12.addEventListener('click', () => setScheduleWindow(12));
  els.quick24.addEventListener('click', () => setScheduleWindow(24));

  els.schedulePeriod.addEventListener('click', async () => {
    const start = fromInput(els.scheduleStart);
    const end = fromInput(els.scheduleEnd);
    const interval = Number(els.scheduleInterval.value);
    if (!start || !end) return toast('Informe o primeiro e o último horário.', 'error');
    if (!Number.isInteger(interval) || interval < 1 || interval > 1440) return toast('Intervalo inválido.', 'error');
    await runAction('jl_admin_schedule_draws', {
      p_start_at: start.toISOString(),
      p_end_at: end.toISOString(),
      p_interval_minutes: interval
    }, 'Programação criada.');
  });

  els.addDrawTime.addEventListener('click', async () => {
    const drawAt = fromInput(els.singleDrawAt);
    if (!drawAt) return toast('Informe um horário válido.', 'error');
    await runAction('jl_admin_add_draw_time', { p_draw_at: drawAt.toISOString() }, 'Horário adicionado.');
  });

  els.clearSchedule.addEventListener('click', async () => {
    if (!window.confirm('Cancelar todos os horários futuros ainda não ativados? A rodada atualmente ativa não será cancelada.')) return;
    await runAction('jl_admin_clear_draw_schedule', {}, 'Horários futuros cancelados.');
  });

  els.drawSchedule.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-cancel-draw]');
    if (!button) return;
    await runAction('jl_admin_cancel_draw_time', { p_schedule_id: button.dataset.cancelDraw }, 'Horário cancelado.');
  });

  els.depositRequests.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-deposit]');
    if (!button) return;
    await runAction('jl_admin_review_deposit', { p_request_id: button.dataset.deposit, p_decision: button.dataset.decision }, `Depósito ${button.dataset.decision === 'approved' ? 'aprovado' : 'rejeitado'}.`);
  });

  els.withdrawRequests.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-withdraw]');
    if (!button) return;
    await runAction('jl_admin_review_withdrawal', { p_request_id: button.dataset.withdraw, p_decision: button.dataset.decision }, `Saque ${button.dataset.decision === 'approved' ? 'autorizado' : 'rejeitado'}.`);
  });

  els.playersList.addEventListener('click', async (event) => {
    const adjust = event.target.closest('[data-adjust]');
    if (adjust) {
      const raw = window.prompt(`Ajuste de saldo para ${adjust.dataset.name}.\nUse valor positivo para adicionar e negativo para retirar:`);
      if (raw === null) return;
      const delta = Number(String(raw).replace(',', '.'));
      if (!Number.isFinite(delta) || delta === 0) return toast('Informe um ajuste válido.', 'error');
      const note = window.prompt('Motivo do ajuste (opcional):') || '';
      await runAction('jl_admin_adjust_balance', { p_player_id: adjust.dataset.adjust, p_delta: delta, p_note: note }, 'Saldo ajustado.');
      return;
    }
    const block = event.target.closest('[data-block]');
    if (block) {
      const blocked = block.dataset.value === 'true';
      await runAction('jl_admin_set_blocked', { p_player_id: block.dataset.block, p_blocked: blocked }, blocked ? 'Jogador bloqueado.' : 'Jogador desbloqueado.');
    }
  });

  setDefaultTimes();
  showApp(Boolean(state.token));
  if (state.token) refresh(true);
  state.timer = setInterval(() => { if (state.token) refresh(true); }, 5000);
})();
