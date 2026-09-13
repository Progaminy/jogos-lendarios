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
    if (!response.ok) throw new Error(payload?.message || payload?.error || `Erro ${response.status}`);
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

  function setDefaultCloseTime() {
    const d = new Date(Date.now() + 30 * 60 * 1000);
    d.setSeconds(0, 0);
    const local = new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
    els.closeAt.value = local;
  }

  function renderRound() {
    const round = state.data?.round;
    const last = state.data?.last_result;
    clearInterval(state.countdownTimer);

    els.metricDraw.textContent = last?.drawn_number ?? '—';

    if (!round) {
      els.metricRound.textContent = last ? `#${last.round_no}` : '—';
      els.metricStatus.textContent = last ? 'Finalizada' : 'Sem rodada';
      els.metricCountdown.textContent = '—';
      els.openRound.disabled = false;
      els.closeRound.disabled = true;
      return;
    }

    const labels = { open: 'Aberta', closed: 'Encerrada' };
    els.metricRound.textContent = `#${round.round_no}`;
    els.metricStatus.textContent = labels[round.status] || round.status;
    els.openRound.disabled = true;
    els.closeRound.disabled = round.status !== 'open';

    const tick = () => {
      if (round.status !== 'open') {
        els.metricCountdown.textContent = 'Processando sorteio automático…';
        return;
      }
      const left = new Date(round.closes_at).getTime() - Date.now();
      if (left <= 0) {
        els.metricCountdown.textContent = '00:00:00';
        return;
      }
      const total = Math.floor(left / 1000);
      const days = Math.floor(total / 86400);
      const h = Math.floor((total % 86400) / 3600);
      const m = Math.floor((total % 3600) / 60);
      const s = total % 60;
      const clock = [h, m, s].map((v) => String(v).padStart(2, '0')).join(':');
      els.metricCountdown.textContent = days ? `${days}d ${clock}` : clock;
    };
    tick();
    state.countdownTimer = setInterval(tick, 1000);
  }

  function renderStats() {
    if (!state.data?.round) {
      els.numberStats.innerHTML = '<div class="empty">Abra uma rodada para acompanhar as apostas por número.</div>';
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
    if (!els.closeAt.value) return toast('Defina a data e hora do sorteio.', 'error');
    const closesAt = new Date(els.closeAt.value);
    if (Number.isNaN(closesAt.getTime())) return toast('Data e hora inválidas.', 'error');
    await runAction(
      'jl_admin_open_round',
      { p_closes_at: closesAt.toISOString() },
      'Jogo aberto. O sorteio será automático na hora definida.'
    );
  });

  els.closeRound.addEventListener('click', async () => {
    if (!window.confirm('Encerrar as apostas e executar o sorteio automático agora?')) return;
    await runAction('jl_admin_close_round', {}, 'Rodada encerrada e sorteada automaticamente.');
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

  setDefaultCloseTime();
  showApp(Boolean(state.token));
  if (state.token) refresh(true);
  state.timer = setInterval(() => { if (state.token) refresh(true); }, 10000);
})();
