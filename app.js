(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const $ = (id) => document.getElementById(id);

  const state = {
    token: localStorage.getItem(TOKEN_KEY) || '',
    data: null,
    selectedNumber: null,
    selectedPair: [],
    pendingBet: null,
    refreshTimer: null,
    timers: {
      number: { countdown: null, refresh: null },
      pair: { countdown: null, refresh: null }
    }
  };

  const els = {
    toast: $('toast'), accountButton: $('accountButton'),
    numberRoundBadge: $('numberRoundBadge'), pairRoundBadge: $('pairRoundBadge'),
    numberResultBanner: $('numberResultBanner'), numberResultTitle: $('numberResultTitle'), numberResultNumber: $('numberResultNumber'),
    pairResultBanner: $('pairResultBanner'), pairResultTitle: $('pairResultTitle'), pairResultA: $('pairResultA'), pairResultB: $('pairResultB'),
    numberRoundStatus: $('numberRoundStatus'), numberCountdown: $('numberCountdown'), numberRuleText: $('numberRuleText'), numberPrizeText: $('numberPrizeText'),
    numberGrid: $('numberGrid'), betForm: $('betForm'), betAmount: $('betAmount'), betButton: $('betButton'), selectionText: $('selectionText'),
    pairRoundStatus: $('pairRoundStatus'), pairCountdown: $('pairCountdown'), pairRuleText: $('pairRuleText'), pairPrizeText: $('pairPrizeText'),
    pairNumberGrid: $('pairNumberGrid'), pairBetForm: $('pairBetForm'), pairBetAmount: $('pairBetAmount'), pairBetButton: $('pairBetButton'), pairSelectionText: $('pairSelectionText'),
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
    return value ? new Date(value).toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' }) : '—';
  }

  function formatCountdown(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const days = Math.floor(total / 86400);
    const h = Math.floor((total % 86400) / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const clock = [h, m, s].map((v) => String(v).padStart(2, '0')).join(':');
    return days ? `${days}d ${clock}` : clock;
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (c) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', "'":'&#39;', '"':'&quot;' }[c]));
  }

  function showToast(message, type = '') {
    if (!els.toast) return;
    els.toast.textContent = message;
    els.toast.className = `toast show ${type}`.trim();
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => { els.toast.className = 'toast'; }, 3800);
  }

  function setMessage(el, message = '', type = '') {
    if (!el) return;
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
    if (!response.ok) throw new Error(payload?.message || payload?.error || payload?.hint || `Erro ${response.status}`);
    return payload;
  }

  function saveToken(token) {
    state.token = token || '';
    if (state.token) localStorage.setItem(TOKEN_KEY, state.token);
    else localStorage.removeItem(TOKEN_KEY);
  }

  const game = (type) => state.data?.games?.[type] || null;
  const gameSettings = (type) => game(type)?.settings || {};
  const gameRound = (type) => game(type)?.current_round || null;

  function gameIsOpen(type) {
    const g = game(type);
    const round = g?.current_round;
    return Boolean(g?.settings?.enabled && round && round.status === 'open' && new Date(round.closes_at).getTime() > Date.now());
  }

  function modeDescription(settings) {
    if (settings?.draw_mode === 'house_safe_random') {
      return 'Sorteio aleatório apenas entre resultados financeiramente seguros para a rodada.';
    }
    return 'Sorteio entre os resultados com menor exposição financeira; em empate, a escolha é aleatória.';
  }

  function buildNumbers() {
    els.numberGrid.innerHTML = '';
    for (let n = 0; n <= 10; n += 1) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'number-button';
      button.textContent = String(n);
      button.dataset.number = String(n);
      button.addEventListener('click', () => {
        state.selectedNumber = n;
        document.querySelectorAll('#numberGrid .number-button').forEach((item) => {
          item.classList.toggle('selected', Number(item.dataset.number) === n);
        });
        els.selectionText.textContent = `Número ${n} escolhido.`;
        updateBetButtons();
      });
      els.numberGrid.appendChild(button);
    }
  }

  function buildPairNumbers() {
    els.pairNumberGrid.innerHTML = '';
    for (let n = 0; n <= 10; n += 1) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'number-button';
      button.textContent = String(n);
      button.dataset.pairNumber = String(n);
      button.addEventListener('click', () => {
        const index = state.selectedPair.indexOf(n);
        if (index >= 0) {
          state.selectedPair.splice(index, 1);
        } else if (state.selectedPair.length < 2) {
          state.selectedPair.push(n);
        } else {
          showToast('Escolha apenas dois números na Dupla Lendária.', 'error');
          return;
        }

        state.selectedPair.sort((a, b) => a - b);
        document.querySelectorAll('#pairNumberGrid .number-button').forEach((item) => {
          item.classList.toggle('selected', state.selectedPair.includes(Number(item.dataset.pairNumber)));
        });

        if (!state.selectedPair.length) els.pairSelectionText.textContent = 'Escolha dois números diferentes de 0 a 10.';
        else if (state.selectedPair.length === 1) els.pairSelectionText.textContent = `Escolhido ${state.selectedPair[0]}. Falta o segundo número.`;
        else els.pairSelectionText.textContent = `Combinação ${state.selectedPair[0]} + ${state.selectedPair[1]}. A ordem não importa.`;
        updateBetButtons();
      });
      els.pairNumberGrid.appendChild(button);
    }
  }

  function applySettings() {
    const numberSettings = gameSettings('number');
    const pairSettings = gameSettings('pair');

    if (numberSettings.min_bet != null) {
      els.betAmount.min = numberSettings.min_bet;
      els.betAmount.max = numberSettings.max_bet;
      if (Number(els.betAmount.value) < Number(numberSettings.min_bet) || Number(els.betAmount.value) > Number(numberSettings.max_bet)) {
        els.betAmount.value = numberSettings.min_bet;
      }
      els.numberPrizeText.textContent = `${Number(numberSettings.multiplier)}×`;
      els.numberRuleText.textContent = `${modeDescription(numberSettings)} Aposta: ${numberSettings.min_bet}–${numberSettings.max_bet} MZN.`;
    }

    if (pairSettings.min_bet != null) {
      els.pairBetAmount.min = pairSettings.min_bet;
      els.pairBetAmount.max = pairSettings.max_bet;
      if (Number(els.pairBetAmount.value) < Number(pairSettings.min_bet) || Number(els.pairBetAmount.value) > Number(pairSettings.max_bet)) {
        els.pairBetAmount.value = pairSettings.min_bet;
      }
      els.pairPrizeText.textContent = `${Number(pairSettings.multiplier)}×`;
      els.pairRuleText.textContent = `${modeDescription(pairSettings)} Aposta: ${pairSettings.min_bet}–${pairSettings.max_bet} MZN.`;
    }
  }

  function updateBetButtons() {
    els.betButton.disabled = !(gameIsOpen('number') && state.selectedNumber !== null);
    els.pairBetButton.disabled = !(gameIsOpen('pair') && state.selectedPair.length === 2);
  }

  function renderGameRound(type) {
    const round = gameRound(type);
    const timer = state.timers[type];
    clearInterval(timer.countdown);
    clearTimeout(timer.refresh);

    const isNumber = type === 'number';
    const badge = isNumber ? els.numberRoundBadge : els.pairRoundBadge;
    const status = isNumber ? els.numberRoundStatus : els.pairRoundStatus;
    const countdown = isNumber ? els.numberCountdown : els.pairCountdown;
    const label = isNumber ? 'Número' : 'Dupla';
    const settings = gameSettings(type);

    if (!settings.enabled) {
      badge.textContent = `${label}: desativado`;
      badge.className = 'badge danger';
      status.textContent = 'Jogo desativado';
      countdown.textContent = '--:--:--';
      updateBetButtons();
      return;
    }

    if (!round) {
      badge.textContent = `${label}: sem rodada`;
      badge.className = 'badge muted';
      status.textContent = 'Apostas fechadas';
      countdown.textContent = '--:--:--';
      updateBetButtons();
      return;
    }

    badge.textContent = `${label} · rodada ${round.round_no}`;
    const closeAt = new Date(round.closes_at).getTime();
    const drawAt = new Date(round.draw_at).getTime();
    if (Number.isFinite(drawAt)) timer.refresh = setTimeout(() => refresh(true), Math.max(250, drawAt - Date.now() + 500));

    const tick = () => {
      const now = Date.now();
      if (round.status === 'open' && now < closeAt) {
        badge.className = 'badge success';
        status.textContent = 'Apostas abertas';
        countdown.textContent = formatCountdown(closeAt - now);
      } else if (now < drawAt) {
        badge.className = 'badge danger';
        status.textContent = 'Apostas bloqueadas · sorteio em';
        countdown.textContent = formatCountdown(drawAt - now);
      } else {
        badge.className = 'badge danger';
        status.textContent = 'Processando resultado…';
        countdown.textContent = '00:00:00';
      }
      updateBetButtons();
    };
    tick();
    timer.countdown = setInterval(tick, 1000);
  }

  function renderResults() {
    const nr = game('number')?.last_result;
    if (nr?.drawn_number != null) {
      els.numberResultTitle.textContent = `Rodada ${nr.round_no} · ${formatDate(nr.published_at)}`;
      els.numberResultNumber.textContent = nr.drawn_number;
      els.numberResultBanner.classList.remove('hidden');
    } else els.numberResultBanner.classList.add('hidden');

    const pr = game('pair')?.last_result;
    if (pr?.pair_drawn_a != null && pr?.pair_drawn_b != null) {
      els.pairResultTitle.textContent = `Rodada ${pr.round_no} · ${formatDate(pr.published_at)}`;
      els.pairResultA.textContent = pr.pair_drawn_a;
      els.pairResultB.textContent = pr.pair_drawn_b;
      els.pairResultBanner.classList.remove('hidden');
    } else els.pairResultBanner.classList.add('hidden');
  }

  function renderHistory() {
    const singles = (state.data?.bets || []).map((bet) => ({ ...bet, game_type: 'number' }));
    const pairs = (state.data?.pair_bets || []).map((bet) => ({ ...bet, game_type: 'pair' }));
    const bets = [...singles, ...pairs].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    if (!bets.length) {
      els.betHistory.innerHTML = '<div class="empty">Ainda não há apostas.</div>';
      return;
    }

    els.betHistory.innerHTML = bets.map((bet) => {
      const pair = bet.game_type === 'pair';
      const choice = pair ? `${bet.number_a}+${bet.number_b}` : String(bet.selected_number);
      const gameName = pair ? 'Dupla Lendária' : 'Número Lendário';
      let resultClass = 'pending';
      let resultLabel = 'Aguardando resultado';
      let resultValue = `MZN ${formatMoney(bet.amount)}`;
      if (bet.won === true) {
        resultClass = 'win';
        resultLabel = `Ganhou MZN ${formatMoney(bet.payout)}`;
        resultValue = pair ? `Saiu ${bet.pair_drawn_a}+${bet.pair_drawn_b}` : `Saiu ${bet.drawn_number}`;
      } else if (bet.won === false) {
        resultClass = 'lose';
        resultLabel = 'Não premiada';
        resultValue = pair ? `Saiu ${bet.pair_drawn_a}+${bet.pair_drawn_b}` : `Saiu ${bet.drawn_number}`;
      }
      return `<div class="history-item">
        <div class="history-number">${escapeHtml(choice)}</div>
        <div class="history-main"><strong>${gameName} · Rodada ${bet.round_no} · MZN ${formatMoney(bet.amount)}</strong><span>${formatDate(bet.created_at)}</span></div>
        <div class="history-result ${resultClass}"><strong>${escapeHtml(resultLabel)}</strong><span>${escapeHtml(resultValue)}</span></div>
      </div>`;
    }).join('');
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

  function render() {
    applySettings();
    renderGameRound('number');
    renderGameRound('pair');
    renderResults();
    renderPlayer();
    updateBetButtons();
  }

  async function refresh(silent = false) {
    try {
      state.data = state.token ? await rpc('jl_player_state', { p_token: state.token }) : await rpc('jl_public_state');
      render();
    } catch (error) {
      if (state.token && /sessão|session/i.test(error.message)) {
        saveToken('');
        state.data = await rpc('jl_public_state');
        render();
      } else if (!silent) showToast(error.message, 'error');
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

  async function placeNumberBet(number, amount) {
    try {
      els.betButton.disabled = true;
      const result = await rpc('jl_place_bet', { p_token: state.token, p_selected_number: Number(number), p_amount: Number(amount) });
      state.pendingBet = null;
      showToast(`Número Lendário: aposta ${result.selected_number} confirmada.`, 'success');
      await refresh(true);
    } catch (error) {
      showToast(error.message, 'error');
      updateBetButtons();
    }
  }

  async function placePairBet(numbers, amount) {
    try {
      els.pairBetButton.disabled = true;
      const [a, b] = [...numbers].sort((x, y) => x - y);
      const result = await rpc('jl_place_pair_bet', { p_token: state.token, p_number_a: a, p_number_b: b, p_amount: Number(amount) });
      state.pendingBet = null;
      showToast(`Dupla Lendária: ${result.number_a}+${result.number_b} confirmada.`, 'success');
      await refresh(true);
    } catch (error) {
      showToast(error.message, 'error');
      updateBetButtons();
    }
  }

  async function continuePendingBet() {
    if (!state.pendingBet) return;
    const pending = state.pendingBet;
    if (pending.type === 'pair') await placePairBet(pending.numbers, pending.amount);
    else await placeNumberBet(pending.number, pending.amount);
  }

  els.betForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const settings = gameSettings('number');
    const amount = Number(els.betAmount.value);
    if (state.selectedNumber === null) return showToast('Escolha um número primeiro.', 'error');
    if (!Number.isFinite(amount) || amount < Number(settings.min_bet) || amount > Number(settings.max_bet)) return showToast(`A aposta deve ser entre ${settings.min_bet} e ${settings.max_bet} MZN.`, 'error');
    if (!gameIsOpen('number')) return showToast('Número Lendário está sem apostas abertas.', 'error');
    if (!state.token) {
      state.pendingBet = { type: 'number', number: state.selectedNumber, amount };
      openAuth('register');
      return;
    }
    await placeNumberBet(state.selectedNumber, amount);
  });

  els.pairBetForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const settings = gameSettings('pair');
    const amount = Number(els.pairBetAmount.value);
    if (state.selectedPair.length !== 2) return showToast('Escolha dois números para a Dupla Lendária.', 'error');
    if (!Number.isFinite(amount) || amount < Number(settings.min_bet) || amount > Number(settings.max_bet)) return showToast(`A aposta deve ser entre ${settings.min_bet} e ${settings.max_bet} MZN.`, 'error');
    if (!gameIsOpen('pair')) return showToast('Dupla Lendária está sem apostas abertas.', 'error');
    if (!state.token) {
      state.pendingBet = { type: 'pair', numbers: [...state.selectedPair], amount };
      openAuth('register');
      return;
    }
    await placePairBet(state.selectedPair, amount);
  });

  els.registerForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const pin = els.registerPin.value.trim();
    if (pin !== els.registerPinConfirm.value.trim()) return setMessage(els.authMessage, 'Os PINs não coincidem.', 'error');
    try {
      setMessage(els.authMessage, 'Criando conta…');
      const result = await rpc('jl_register_player', { p_name: els.registerName.value.trim(), p_phone: els.registerPhone.value.trim(), p_pin: pin });
      saveToken(result.token);
      closeAuth();
      await refresh(true);
      showToast('Conta criada com sucesso.', 'success');
      await continuePendingBet();
    } catch (error) { setMessage(els.authMessage, error.message, 'error'); }
  });

  els.loginForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      setMessage(els.authMessage, 'Entrando…');
      const result = await rpc('jl_login_player', { p_phone: els.loginPhone.value.trim(), p_pin: els.loginPin.value.trim() });
      saveToken(result.token);
      closeAuth();
      await refresh(true);
      showToast('Sessão iniciada.', 'success');
      await continuePendingBet();
    } catch (error) { setMessage(els.authMessage, error.message, 'error'); }
  });

  els.depositForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      const result = await rpc('jl_request_deposit', { p_token: state.token, p_amount: Number(els.depositAmount.value), p_note: els.depositNote.value.trim() });
      setMessage(els.depositMessage, `${result.message} Confirmação: ${result.request_id.slice(0, 8).toUpperCase()}`, 'success');
      els.depositForm.reset();
      await refresh(true);
    } catch (error) { setMessage(els.depositMessage, error.message, 'error'); }
  });

  els.withdrawForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      const result = await rpc('jl_request_withdrawal', { p_token: state.token, p_amount: Number(els.withdrawAmount.value) });
      setMessage(els.withdrawMessage, result.message, result.ok ? 'success' : 'error');
      els.withdrawForm.reset();
      await refresh(true);
    } catch (error) { setMessage(els.withdrawMessage, error.message, 'error'); }
  });

  els.accountButton.addEventListener('click', () => {
    if (state.token && state.data?.player) els.playerArea.scrollIntoView({ behavior: 'smooth' });
    else openAuth('login');
  });

  els.logoutButton.addEventListener('click', async () => {
    try { if (state.token) await rpc('jl_logout_player', { p_token: state.token }); } catch {}
    saveToken('');
    state.data = null;
    state.pendingBet = null;
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
  buildPairNumbers();
  refresh();
  state.refreshTimer = setInterval(() => refresh(true), 10000);
})();
