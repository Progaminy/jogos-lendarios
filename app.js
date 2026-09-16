(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const $ = (id) => document.getElementById(id);
  const state = {
    token: localStorage.getItem(TOKEN_KEY) || '',
    data: null,
    selectedNumber: null,
    pendingBet: null,
    countdownTimer: null,
    roundRefreshTimer: null,
    refreshTimer: null
  };

  const els = {
    toast: $('toast'), roundBadge: $('roundBadge'), accountButton: $('accountButton'),
    resultBanner: $('resultBanner'), resultTitle: $('resultTitle'), resultNumber: $('resultNumber'),
    roundStatus: $('roundStatus'), countdown: $('countdown'), numberGrid: $('numberGrid'),
    betForm: $('betForm'), betAmount: $('betAmount'), betButton: $('betButton'), selectionText: $('selectionText'),
    playerArea: $('playerArea'), playerName: $('playerName'), playerPhone: $('playerPhone'), balance: $('balance'),
    logoutButton: $('logoutButton'), refreshButton: $('refreshButton'), betHistory: $('betHistory'),
    depositForm: $('depositForm'), depositAmount: $('depositAmount'), depositNote: $('depositNote'), depositMessage: $('depositMessage'),
    withdrawForm: $('withdrawForm'), withdrawAmount: $('withdrawAmount'), withdrawMessage: $('withdrawMessage'),
    authModal: $('authModal'), closeAuth: $('closeAuth'), registerTab: $('registerTab'), loginTab: $('loginTab'),
    registerForm: $('registerForm'), loginForm: $('loginForm'), authMessage: $('authMessage'),
    registerName: $('registerName'), registerPhone: $('registerPhone'), registerPin: $('registerPin'), registerPinConfirm: $('registerPinConfirm'),
    loginPhone: $('loginPhone'), loginPin: $('loginPin')
  };

  function formatMoney(value) {
    return Number(value || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function formatDate(value) {
    if (!value) return '—';
    return new Date(value).toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' });
  }

  function formatCountdown(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const days = Math.floor(total / 86400);
    const hours = Math.floor((total % 86400) / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;
    const clock = [hours, minutes, seconds].map((v) => String(v).padStart(2, '0')).join(':');
    return days > 0 ? `${days}d ${clock}` : clock;
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (c) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', "'":'&#39;', '"':'&quot;' }[c]));
  }

  function showToast(message, type = '') {
    els.toast.textContent = message;
    els.toast.className = `toast show ${type}`.trim();
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => { els.toast.className = 'toast'; }, 3600);
  }

  function setMessage(el, message = '', type = '') {
    el.textContent = message;
    el.className = `form-message ${type}`.trim();
  }

  async function rpc(name, args = {}) {
    if (!cfg.supabaseUrl || !cfg.supabaseKey) throw new Error('Configuração do Supabase ausente.');
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
      const message = payload?.message || payload?.error || payload?.hint || `Erro ${response.status}`;
      throw new Error(message);
    }
    return payload;
  }

  function saveToken(token) {
    state.token = token || '';
    if (state.token) localStorage.setItem(TOKEN_KEY, state.token);
    else localStorage.removeItem(TOKEN_KEY);
  }

  function buildNumbers() {
    els.numberGrid.innerHTML = '';
    for (let n = 0; n <= 10; n += 1) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'number-button';
      button.textContent = String(n);
      button.dataset.number = String(n);
      button.setAttribute('aria-label', `Escolher número ${n}`);
      button.addEventListener('click', () => selectNumber(n));
      els.numberGrid.appendChild(button);
    }
  }

  function selectNumber(number) {
    state.selectedNumber = number;
    document.querySelectorAll('.number-button').forEach((button) => {
      button.classList.toggle('selected', Number(button.dataset.number) === number);
    });
    els.selectionText.textContent = `Número ${number} escolhido. Agora informe o valor e clique em Apostar.`;
    updateBetButton();
  }

  function currentRound() { return state.data?.current_round || null; }

  function updateBetButton() {
    const round = currentRound();
    const open = Boolean(round && round.status === 'open' && new Date(round.closes_at).getTime() > Date.now());
    els.betButton.disabled = !(open && state.selectedNumber !== null);
  }

  function renderRound() {
    const round = currentRound();
    clearInterval(state.countdownTimer);
    clearTimeout(state.roundRefreshTimer);

    if (!round) {
      els.roundBadge.textContent = 'Sem rodada ativa';
      els.roundBadge.className = 'badge muted';
      els.roundStatus.textContent = 'Apostas fechadas';
      els.countdown.textContent = '--:--:--';
      updateBetButton();
      return;
    }

    els.roundBadge.textContent = `Rodada ${round.round_no}`;
    const closeAt = new Date(round.closes_at).getTime();
    const drawAt = new Date(round.draw_at || round.closes_at).getTime();

    if (Number.isFinite(drawAt)) {
      const refreshDelay = Math.max(250, drawAt - Date.now() + 350);
      state.roundRefreshTimer = setTimeout(() => refresh(true), refreshDelay);
    }

    const tick = () => {
      const now = Date.now();
      if (round.status === 'open' && now < closeAt) {
        els.roundStatus.textContent = 'Apostas abertas';
        els.roundBadge.className = 'badge success';
        els.countdown.textContent = formatCountdown(closeAt - now);
      } else if (now < drawAt) {
        els.roundStatus.textContent = 'Apostas bloqueadas · sorteio em';
        els.roundBadge.className = 'badge danger';
        els.countdown.textContent = formatCountdown(drawAt - now);
      } else {
        els.roundStatus.textContent = 'Sorteando e publicando…';
        els.roundBadge.className = 'badge danger';
        els.countdown.textContent = '00:00:00';
      }
      updateBetButton();
    };

    tick();
    state.countdownTimer = setInterval(tick, 1000);
  }

  function renderResult() {
    const result = state.data?.last_result;
    if (!result) {
      els.resultBanner.classList.add('hidden');
      return;
    }
    els.resultTitle.textContent = `Rodada ${result.round_no} · publicado ${formatDate(result.published_at)}`;
    els.resultNumber.textContent = result.drawn_number;
    els.resultBanner.classList.remove('hidden');
  }

  function renderPlayer() {
    const player = state.data?.player;
    if (!state.token || !player) {
      els.playerArea.classList.add('hidden');
      els.accountButton.textContent = 'Entrar';
      return;
    }
    els.playerArea.classList.remove('hidden');
    els.playerName.textContent = player.name;
    els.playerPhone.textContent = `+${player.phone}`;
    els.balance.textContent = formatMoney(player.balance);
    els.accountButton.textContent = player.name.split(/\s+/)[0] || 'Minha conta';
    renderHistory();
  }

  function renderHistory() {
    const bets = state.data?.bets || [];
    if (!bets.length) {
      els.betHistory.innerHTML = '<div class="empty">Ainda não há apostas.</div>';
      return;
    }
    els.betHistory.innerHTML = bets.map((bet) => {
      let resultClass = 'pending';
      let resultLabel = 'Aguardando resultado';
      let resultValue = `MZN ${formatMoney(bet.amount)}`;
      if (bet.won === true) {
        resultClass = 'win'; resultLabel = `Ganhou MZN ${formatMoney(bet.payout)}`; resultValue = `Saiu ${bet.drawn_number}`;
      } else if (bet.won === false) {
        resultClass = 'lose'; resultLabel = 'Não premiada'; resultValue = `Saiu ${bet.drawn_number}`;
      }
      return `<div class="history-item">
        <div class="history-number">${bet.selected_number}</div>
        <div class="history-main"><strong>Rodada ${bet.round_no} · MZN ${formatMoney(bet.amount)}</strong><span>${formatDate(bet.created_at)}</span></div>
        <div class="history-result ${resultClass}"><strong>${escapeHtml(resultLabel)}</strong><span>${escapeHtml(resultValue)}</span></div>
      </div>`;
    }).join('');
  }

  function render() {
    renderRound();
    renderResult();
    renderPlayer();
  }

  async function refresh(silent = false) {
    try {
      state.data = state.token
        ? await rpc('jl_player_state', { p_token: state.token })
        : await rpc('jl_public_state');
      render();
    } catch (error) {
      if (state.token && /sessão|session/i.test(error.message)) {
        saveToken('');
        state.data = await rpc('jl_public_state');
        render();
      } else if (!silent) {
        showToast(error.message, 'error');
      }
    }
  }

  function openAuth(mode = 'register') {
    els.authModal.classList.remove('hidden');
    document.body.classList.add('modal-open');
    switchAuth(mode);
    setMessage(els.authMessage);
  }

  function closeAuth() {
    els.authModal.classList.add('hidden');
    document.body.classList.remove('modal-open');
  }

  function switchAuth(mode) {
    const register = mode === 'register';
    els.registerTab.classList.toggle('active', register);
    els.loginTab.classList.toggle('active', !register);
    els.registerForm.classList.toggle('hidden', !register);
    els.loginForm.classList.toggle('hidden', register);
    setMessage(els.authMessage);
  }

  async function placeBet(number, amount) {
    try {
      els.betButton.disabled = true;
      const result = await rpc('jl_place_bet', {
        p_token: state.token,
        p_selected_number: Number(number),
        p_amount: Number(amount)
      });
      showToast(`Aposta confirmada: número ${result.selected_number}, MZN ${formatMoney(result.amount)}.`, 'success');
      state.pendingBet = null;
      await refresh(true);
    } catch (error) {
      showToast(error.message, 'error');
      updateBetButton();
    }
  }

  els.betForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const amount = Number(els.betAmount.value);
    if (state.selectedNumber === null) return showToast('Escolha um número primeiro.', 'error');
    if (!Number.isFinite(amount) || amount < 1) return showToast('Informe um valor de aposta válido.', 'error');
    const round = currentRound();
    if (!round || round.status !== 'open' || new Date(round.closes_at).getTime() <= Date.now()) return showToast('As apostas estão bloqueadas ou fechadas.', 'error');

    if (!state.token) {
      state.pendingBet = { number: state.selectedNumber, amount };
      openAuth('register');
      return;
    }
    await placeBet(state.selectedNumber, amount);
  });

  els.registerForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const pin = els.registerPin.value.trim();
    if (pin !== els.registerPinConfirm.value.trim()) return setMessage(els.authMessage, 'Os PINs não coincidem.', 'error');
    try {
      setMessage(els.authMessage, 'Criando conta…');
      const result = await rpc('jl_register_player', {
        p_name: els.registerName.value.trim(),
        p_phone: els.registerPhone.value.trim(),
        p_pin: pin
      });
      saveToken(result.token);
      closeAuth();
      await refresh(true);
      showToast('Conta criada com sucesso.', 'success');
      if (state.pendingBet) await placeBet(state.pendingBet.number, state.pendingBet.amount);
    } catch (error) {
      setMessage(els.authMessage, error.message, 'error');
    }
  });

  els.loginForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      setMessage(els.authMessage, 'Entrando…');
      const result = await rpc('jl_login_player', {
        p_phone: els.loginPhone.value.trim(),
        p_pin: els.loginPin.value.trim()
      });
      saveToken(result.token);
      closeAuth();
      await refresh(true);
      showToast('Sessão iniciada.', 'success');
      if (state.pendingBet) await placeBet(state.pendingBet.number, state.pendingBet.amount);
    } catch (error) {
      setMessage(els.authMessage, error.message, 'error');
    }
  });

  els.depositForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      const result = await rpc('jl_request_deposit', {
        p_token: state.token,
        p_amount: Number(els.depositAmount.value),
        p_note: els.depositNote.value.trim()
      });
      setMessage(els.depositMessage, `${result.message} Confirmação: ${result.request_id.slice(0, 8).toUpperCase()}`, 'success');
      els.depositForm.reset();
      await refresh(true);
    } catch (error) {
      setMessage(els.depositMessage, error.message, 'error');
    }
  });

  els.withdrawForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      const result = await rpc('jl_request_withdrawal', {
        p_token: state.token,
        p_amount: Number(els.withdrawAmount.value)
      });
      setMessage(els.withdrawMessage, result.message, result.ok ? 'success' : 'error');
      els.withdrawForm.reset();
      await refresh(true);
    } catch (error) {
      setMessage(els.withdrawMessage, error.message, 'error');
    }
  });

  els.accountButton.addEventListener('click', () => {
    if (state.token && state.data?.player) els.playerArea.scrollIntoView({ behavior: 'smooth' });
    else openAuth('login');
  });
  els.logoutButton.addEventListener('click', async () => {
    try { if (state.token) await rpc('jl_logout_player', { p_token: state.token }); } catch {}
    saveToken('');
    state.data = null;
    await refresh(true);
    showToast('Sessão encerrada.');
  });
  els.refreshButton.addEventListener('click', () => refresh());
  els.closeAuth.addEventListener('click', closeAuth);
  els.registerTab.addEventListener('click', () => switchAuth('register'));
  els.loginTab.addEventListener('click', () => switchAuth('login'));
  els.authModal.addEventListener('click', (event) => { if (event.target === els.authModal) closeAuth(); });
  document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !els.authModal.classList.contains('hidden')) closeAuth(); });

  buildNumbers();
  refresh();
  state.refreshTimer = setInterval(() => refresh(true), 10000);
})();
