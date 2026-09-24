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
    depositRedirectHandled: false,
    refreshTimer: null,
    timers: {
      number: { countdown: null, refresh: null },
      pair: { countdown: null, refresh: null }
    }
  };

  const els = {
    toast: $('toast'), accountButton: $('accountButton'),
    accountMenu: $('accountMenu'), accountMenuPlayer: $('accountMenuPlayer'), accountMenuBalance: $('accountMenuBalance'), accountMenuBonus: $('accountMenuBonus'),
    accountMenuDeposit: $('accountMenuDeposit'), accountMenuWithdraw: $('accountMenuWithdraw'), accountMenuLogout: $('accountMenuLogout'),
    numberRoundBadge: $('numberRoundBadge'), pairRoundBadge: $('pairRoundBadge'),
    numberResultBanner: $('numberResultBanner'), numberResultTitle: $('numberResultTitle'), numberResultNumber: $('numberResultNumber'),
    pairResultBanner: $('pairResultBanner'), pairResultTitle: $('pairResultTitle'), pairResultA: $('pairResultA'), pairResultB: $('pairResultB'),
    numberRoundStatus: $('numberRoundStatus'), numberCountdown: $('numberCountdown'), numberRuleText: $('numberRuleText'), numberPrizeText: $('numberPrizeText'),
    numberGrid: $('numberGrid'), betForm: $('betForm'), betAmount: $('betAmount'), betButton: $('betButton'), selectionText: $('selectionText'),
    pairRoundStatus: $('pairRoundStatus'), pairCountdown: $('pairCountdown'), pairRuleText: $('pairRuleText'), pairPrizeText: $('pairPrizeText'),
    pairNumberGrid: $('pairNumberGrid'), pairBetForm: $('pairBetForm'), pairBetAmount: $('pairBetAmount'), pairBetButton: $('pairBetButton'), pairSelectionText: $('pairSelectionText'),
    playerArea: $('playerArea'), playerName: $('playerName'), playerPhone: $('playerPhone'), balance: $('balance'), bonusBalance: $('bonusBalance'), bonusBreakdown: $('bonusBreakdown'),
    logoutButton: $('logoutButton'), refreshButton: $('refreshButton'), betHistory: $('betHistory'),
    depositForm: $('depositForm'), depositAmount: $('depositAmount'), depositNote: $('depositNote'), depositMessage: $('depositMessage'),
    withdrawForm: $('withdrawForm'), withdrawAmount: $('withdrawAmount'), withdrawMessage: $('withdrawMessage'), withdrawableBalance: $('withdrawableBalance'), depositLockedBalance: $('depositLockedBalance'),
    authModal: $('authModal'), closeAuth: $('closeAuth'), registerTab: $('registerTab'), loginTab: $('loginTab'),
    registerForm: $('registerForm'), loginForm: $('loginForm'), authMessage: $('authMessage'),
    registerName: $('registerName'), registerPhone: $('registerPhone'), registerPin: $('registerPin'), registerPinConfirm: $('registerPinConfirm'),
    loginPhone: $('loginPhone'), loginPin: $('loginPin'),
    winModal: $('winModal'), winModalTitle: $('winModalTitle'), winModalMessage: $('winModalMessage'), winModalOk: $('winModalOk'),
    transactionModal: $('transactionModal'), transactionModalIcon: $('transactionModalIcon'), transactionModalEyebrow: $('transactionModalEyebrow'),
    transactionModalTitle: $('transactionModalTitle'), transactionModalAmount: $('transactionModalAmount'), transactionModalMessage: $('transactionModalMessage'),
    transactionModalReference: $('transactionModalReference'), transactionModalOk: $('transactionModalOk')
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

  async function checkFunds(gameType, amount) {
    return rpc('jl_check_funds', {
      p_token: state.token,
      p_game_type: gameType,
      p_amount: Number(amount)
    });
  }

  function directToDeposit(check, context = 'esta operação') {
    const missing = Math.max(1, Math.ceil(Number(check?.shortfall || 0)));
    if (els.depositAmount) els.depositAmount.value = String(missing);
    openAccountPanel('depositPanel');
    const message = `Saldo insuficiente para ${context}. Faltam ${formatMoney(missing)} MZN. Faça um depósito para continuar.`;
    setMessage(els.depositMessage, message, 'error');
    showToast(message, 'error');
    try { history.replaceState(null, '', '#depositPanel'); } catch {}
  }

  async function ensureFunds(gameType, amount, context) {
    if (!state.token) return false;
    const check = await checkFunds(gameType, amount);
    if (check?.ok) return true;

    if (check?.reason === 'deposit_not_played') {
      const message = `Este valor ainda não pode ser sacado: ${formatMoney(check.deposit_locked || 0)} MZN de depósito ainda precisa ser jogado.`;
      setMessage(els.withdrawMessage, message, 'error');
      showToast(message, 'error');
      return false;
    }

    if (check?.redirect_to_deposit) {
      directToDeposit(check, context);
      return false;
    }

    showToast('Saldo insuficiente para continuar.', 'error');
    return false;
  }

  function showTransactionModal({ kind, amount, message, reference = '', ok = true }) {
    if (!els.transactionModal) return;
    const isDeposit = kind === 'deposit';
    const card = els.transactionModal.querySelector('.transaction-modal-card');
    card?.classList.toggle('error', !ok);
    els.transactionModalIcon.textContent = ok ? (isDeposit ? '↓' : '↑') : '!';
    els.transactionModalEyebrow.textContent = isDeposit ? 'DEPÓSITO' : 'SAQUE';
    els.transactionModalTitle.textContent = ok
      ? (isDeposit ? 'Pedido de depósito enviado' : 'Pedido de saque enviado')
      : (isDeposit ? 'Depósito não enviado' : 'Saque não enviado');
    els.transactionModalAmount.textContent = Number.isFinite(Number(amount)) ? `${formatMoney(amount)} MZN` : '—';
    els.transactionModalMessage.textContent = message || (ok ? 'Pedido recebido.' : 'Não foi possível concluir o pedido.');
    if (reference) {
      els.transactionModalReference.textContent = `Confirmação: ${reference}`;
      els.transactionModalReference.classList.remove('hidden');
    } else {
      els.transactionModalReference.textContent = '';
      els.transactionModalReference.classList.add('hidden');
    }
    els.transactionModal.classList.remove('hidden');
    document.body.classList.add('modal-open');
  }

  function closeTransactionModal() {
    if (!els.transactionModal) return;
    els.transactionModal.classList.add('hidden');
    document.body.classList.remove('modal-open');
  }

  const quickTransaction = { kind: null, amount: 0 };

  function ensureQuickTransactionModal() {
    let modal = document.getElementById('quickTransactionModal');
    if (modal) return modal;
    modal = document.createElement('div');
    modal.id = 'quickTransactionModal';
    modal.className = 'transaction-modal hidden';
    modal.setAttribute('role','dialog');
    modal.setAttribute('aria-modal','true');
    modal.innerHTML = `
      <div class="transaction-modal-card">
        <button id="quickTransactionClose" class="modal-close" type="button" aria-label="Fechar">×</button>
        <p id="quickTransactionEyebrow" class="eyebrow">OPERAÇÃO</p>
        <h2 id="quickTransactionTitle">Valor</h2>
        <form id="quickTransactionAmountForm" class="stack-form">
          <label class="field"><span>Valor</span><div class="money-input"><span>MZN</span><input id="quickTransactionAmount" type="number" min="1" step="1" required></div></label>
          <button class="button primary" type="submit">Continuar</button>
        </form>
        <form id="quickTransactionNoteForm" class="stack-form hidden">
          <div id="quickTransferInfo" class="transaction-modal-reference hidden"></div>
          <label class="field"><span id="quickTransactionNoteLabel">Referência ou mensagem opcional</span><input id="quickTransactionNote" maxlength="160" placeholder="Opcional"></label>
          <button id="quickTransactionSubmit" class="button primary" type="submit">Enviar pedido</button>
        </form>
        <p id="quickTransactionMessage" class="form-message"></p>
      </div>`;
    document.body.appendChild(modal);
    const close=()=>{modal.classList.add('hidden');document.body.classList.remove('modal-open');};
    document.getElementById('quickTransactionClose').addEventListener('click',close);
    modal.addEventListener('click',e=>{if(e.target===modal)close();});
    document.getElementById('quickTransactionAmountForm').addEventListener('submit',async e=>{
      e.preventDefault();
      const amount=Number(document.getElementById('quickTransactionAmount').value);
      if(!Number.isInteger(amount)||amount<1){document.getElementById('quickTransactionMessage').textContent='Informe um valor inteiro válido.';return;}
      if(quickTransaction.kind==='withdraw' && !(await ensureFunds('withdrawal',amount,'fazer este saque'))) return;
      quickTransaction.amount=amount;
      document.getElementById('quickTransactionAmountForm').classList.add('hidden');
      document.getElementById('quickTransactionNoteForm').classList.remove('hidden');
      document.getElementById('quickTransactionTitle').textContent=quickTransaction.kind==='deposit'?'Referência da transferência':'Mensagem opcional';
      const info=document.getElementById('quickTransferInfo');
      if(quickTransaction.kind==='deposit'){
        info.innerHTML='Transfira para <strong>869954518</strong> · Bernardo Pedro <button id="quickCopyDepositPhone" class="button ghost tiny" type="button">Copiar</button>';
        info.classList.remove('hidden');
        document.getElementById('quickTransactionNoteLabel').textContent='Referência da transferência ou mensagem opcional';
        document.getElementById('quickCopyDepositPhone')?.addEventListener('click',async()=>{try{await navigator.clipboard.writeText('869954518');showToast('Número copiado.','success');}catch{showToast('Número: 869954518');}});
      }else{
        info.classList.add('hidden');
        document.getElementById('quickTransactionNoteLabel').textContent='Mensagem opcional para o administrador';
      }
      document.getElementById('quickTransactionNote').focus();
    });
    document.getElementById('quickTransactionNoteForm').addEventListener('submit',async e=>{
      e.preventDefault();
      const amount=quickTransaction.amount,note=document.getElementById('quickTransactionNote').value.trim();
      const btn=document.getElementById('quickTransactionSubmit');btn.disabled=true;
      try{
        const result=quickTransaction.kind==='deposit'
          ? await rpc('jl_request_deposit',{p_token:state.token,p_amount:amount,p_note:note})
          : await rpc('jl_request_withdrawal',{p_token:state.token,p_amount:amount,p_note:note});
        const ok=result?.ok!==false,reference=result?.request_id?result.request_id.slice(0,8).toUpperCase():'';
        close();
        showTransactionModal({kind:quickTransaction.kind,amount,message:result?.message,reference,ok});
        await refresh(true);
      }catch(error){
        document.getElementById('quickTransactionMessage').textContent=error.message;
      }finally{btn.disabled=false;}
    });
    return modal;
  }

  function openQuickTransaction(kind,presetAmount=0){
    if(!state.token||!state.data?.player){openAuth('login');return;}
    const modal=ensureQuickTransactionModal();
    quickTransaction.kind=kind;quickTransaction.amount=0;
    document.getElementById('quickTransactionEyebrow').textContent=kind==='deposit'?'DEPÓSITO':'SAQUE';
    document.getElementById('quickTransactionTitle').textContent=kind==='deposit'?'Quanto deseja depositar?':'Quanto deseja sacar?';
    document.getElementById('quickTransactionAmount').value=presetAmount>0?String(Math.ceil(presetAmount)):'';
    document.getElementById('quickTransactionNote').value='';
    document.getElementById('quickTransactionMessage').textContent='';
    document.getElementById('quickTransactionAmountForm').classList.remove('hidden');
    document.getElementById('quickTransactionNoteForm').classList.add('hidden');
    modal.classList.remove('hidden');document.body.classList.add('modal-open');
    setTimeout(()=>document.getElementById('quickTransactionAmount')?.focus(),30);
  }


  const WIN_SEEN_KEY = 'jl_seen_wins_v1';

  function winSeen() {
    try { return new Set(JSON.parse(localStorage.getItem(WIN_SEEN_KEY) || '[]')); }
    catch { return new Set(); }
  }

  function saveWinSeen(seen) {
    try { localStorage.setItem(WIN_SEEN_KEY, JSON.stringify([...seen].slice(-300))); } catch {}
  }

  function winKey(bet, type) {
    return [type, bet.id ?? '', bet.round_id ?? '', bet.round_no ?? '', bet.created_at ?? '', bet.amount ?? '', type === 'pair' ? `${bet.number_a}+${bet.number_b}` : bet.selected_number].join(':');
  }

  function showWinModal(title, message, key) {
    if (!els.winModal) return;
    els.winModalTitle.textContent = title;
    els.winModalMessage.textContent = message;
    els.winModal.dataset.winKey = key || '';
    els.winModal.classList.remove('hidden');
    document.body.classList.add('modal-open');
  }

  function closeWinModal() {
    if (!els.winModal) return;
    const key = els.winModal.dataset.winKey;
    if (key) {
      const seen = winSeen();
      seen.add(key);
      saveWinSeen(seen);
    }
    els.winModal.classList.add('hidden');
    document.body.classList.remove('modal-open');
    delete els.winModal.dataset.winKey;
  }

  function winRoundTime(bet) {
    const candidates = [bet.published_at, bet.drawn_at, bet.draw_at, bet.round_draw_at, bet.resolved_at, bet.updated_at, bet.created_at];
    const raw = candidates.find(Boolean);
    if (!raw) return 'hora não disponível';
    const d = new Date(raw);
    return Number.isNaN(d.getTime()) ? 'hora não disponível' : d.toLocaleTimeString('pt-MZ',{hour:'2-digit',minute:'2-digit'});
  }

  function checkWinNotifications() {
    if (!state.token || !state.data?.player || !els.winModal?.classList.contains('hidden')) return;
    const seen = winSeen();
    const wins = [
      ...(state.data?.bets || []).filter(b => b.won === true).map(b => ({...b, game_type:'number'})),
      ...(state.data?.pair_bets || []).filter(b => b.won === true).map(b => ({...b, game_type:'pair'}))
    ].sort((a,b) => new Date(b.created_at || 0) - new Date(a.created_at || 0));

    const winner = wins.find(b => !seen.has(winKey(b, b.game_type)));
    if (!winner) return;
    const pair = winner.game_type === 'pair';
    const gameName = pair ? 'Dupla Lendária' : 'Número Lendário';
    showWinModal('Parabéns!', `Você ganhou ${formatMoney(winner.payout)} MZN no ${gameName}! Rodada ${winner.round_no ?? '—'} · hora ${winRoundTime(winner)}. O valor foi creditado no seu saldo.`, winKey(winner, winner.game_type));
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
      const bonusUsed=Number(bet.bonus_amount||0),cashUsed=Number(bet.cash_amount||0);
      const source=bonusUsed>0?` · Bónus ${formatMoney(bonusUsed)} MZN${cashUsed>0?` + saldo ${formatMoney(cashUsed)} MZN`:''}`:'';
      return `<div class="history-item">
        <div class="history-number">${escapeHtml(choice)}</div>
        <div class="history-main"><strong>${gameName} · Rodada ${bet.round_no} · MZN ${formatMoney(bet.amount)}</strong><span>${formatDate(bet.created_at)}${source}</span></div>
        <div class="history-result ${resultClass}"><strong>${escapeHtml(resultLabel)}</strong><span>${escapeHtml(resultValue)}</span></div>
      </div>`;
    }).join('');
  }

  function closeAccountMenu() {
    if (!els.accountMenu) return;
    els.accountMenu.classList.add('hidden');
    els.accountButton.setAttribute('aria-expanded', 'false');
  }

  function renderPlayer() {
    const player = state.data?.player;
    if (!state.token || !player) {
      els.playerArea.classList.add('hidden');
      els.accountButton.textContent = 'Entrar';
      closeAccountMenu();
      return;
    }
    els.playerArea.classList.remove('hidden');
    els.playerName.textContent = player.name;
    els.playerPhone.textContent = `+${player.phone}`;
    const bonus=state.data?.bonus||{};
    els.balance.textContent = formatMoney(player.balance);
    if(els.bonusBalance)els.bonusBalance.textContent=formatMoney(bonus.total||0);
    if(els.bonusBreakdown)els.bonusBreakdown.textContent=`Número ${formatMoney(bonus.number||0)} · Dupla ${formatMoney(bonus.pair||0)} MZN`;
    els.accountButton.textContent = player.name.split(/\s+/)[0] || 'Minha conta';
    els.accountMenuPlayer.textContent = player.name;
    els.accountMenuBalance.textContent = `${formatMoney(player.balance)} MZN`;
    if(els.accountMenuBonus)els.accountMenuBonus.textContent=`Bónus ${formatMoney(bonus.total||0)} MZN`;
    if(els.withdrawableBalance)els.withdrawableBalance.textContent=`${formatMoney(player.withdrawable_balance??player.balance)} MZN`;
    if(els.depositLockedBalance)els.depositLockedBalance.textContent=`${formatMoney(player.deposit_locked||0)} MZN`;
    handleDepositRedirectFromUrl();
    renderHistory();
    checkWinNotifications();
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
      if (!(await ensureFunds('number', amount, 'apostar no Número Lendário'))) return;
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
      if (!(await ensureFunds('pair', amount, 'apostar na Dupla Lendária'))) return;
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

  els.betAmount?.addEventListener('change',()=>{const amount=Number(els.betAmount.value);if(state.token&&Number.isInteger(amount)&&amount>0)ensureFunds('number',amount,'apostar no Número Lendário').catch(err=>showToast(err.message,'error'));});
  els.pairBetAmount?.addEventListener('change',()=>{const amount=Number(els.pairBetAmount.value);if(state.token&&Number.isInteger(amount)&&amount>0)ensureFunds('pair',amount,'apostar na Dupla Lendária').catch(err=>showToast(err.message,'error'));});
  els.withdrawAmount?.addEventListener('change',()=>{const amount=Number(els.withdrawAmount.value);if(state.token&&Number.isFinite(amount)&&amount>0)ensureFunds('withdrawal',amount,'fazer este saque').catch(err=>showToast(err.message,'error'));});

  els.winModalOk?.addEventListener('click', closeWinModal);
  els.transactionModalOk?.addEventListener('click', closeTransactionModal);
  els.transactionModal?.addEventListener('click', (event) => { if (event.target === els.transactionModal) closeTransactionModal(); });

  els.betForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const settings = gameSettings('number');
    const amount = Number(els.betAmount.value);
    if (state.selectedNumber === null) return showToast('Escolha um número primeiro.', 'error');
    if (!Number.isFinite(amount) || !Number.isInteger(amount) || amount < Number(settings.min_bet) || amount > Number(settings.max_bet)) return showToast(`A aposta deve ser um valor inteiro entre ${settings.min_bet} e ${settings.max_bet} MZN.`, 'error');
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
    if (!Number.isFinite(amount) || !Number.isInteger(amount) || amount < Number(settings.min_bet) || amount > Number(settings.max_bet)) return showToast(`A aposta deve ser um valor inteiro entre ${settings.min_bet} e ${settings.max_bet} MZN.`, 'error');
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
    const amount = Number(els.depositAmount.value);
    try {
      const result = await rpc('jl_request_deposit', { p_token: state.token, p_amount: amount, p_note: els.depositNote.value.trim() });
      const reference = result.request_id ? result.request_id.slice(0, 8).toUpperCase() : '';
      setMessage(els.depositMessage, `${result.message}${reference ? ` Confirmação: ${reference}` : ''}`, 'success');
      showTransactionModal({ kind: 'deposit', amount, message: result.message || 'O pedido foi recebido e aguarda confirmação.', reference, ok: true });
      els.depositForm.reset();
      await refresh(true);
    } catch (error) {
      setMessage(els.depositMessage, error.message, 'error');
      showTransactionModal({ kind: 'deposit', amount, message: error.message, ok: false });
    }
  });

  els.withdrawForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const amount = Number(els.withdrawAmount.value);
    try {
      if (!(await ensureFunds('withdrawal', amount, 'fazer este saque'))) return;
      const result = await rpc('jl_request_withdrawal', { p_token: state.token, p_amount: amount });
      const ok = result.ok !== false;
      const reference = result.request_id ? result.request_id.slice(0, 8).toUpperCase() : '';
      setMessage(els.withdrawMessage, result.message, ok ? 'success' : 'error');
      showTransactionModal({ kind: 'withdraw', amount, message: result.message, reference, ok });
      if (ok) els.withdrawForm.reset();
      await refresh(true);
    } catch (error) {
      setMessage(els.withdrawMessage, error.message, 'error');
      showTransactionModal({ kind: 'withdraw', amount, message: error.message, ok: false });
    }
  });

  async function logoutPlayer() {
    if (!window.confirm('Tem certeza que deseja sair da sua conta?')) return;
    try { if (state.token) await rpc('jl_logout_player', { p_token: state.token }); } catch {}
    saveToken('');
    state.data = null;
    state.pendingBet = null;
    closeAccountMenu();
    await refresh(true);
    showToast('Sessão encerrada.');
  }

  function openAccountPanel(id) {
    closeAccountMenu();
    document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function handleDepositRedirectFromUrl() {
    if (state.depositRedirectHandled || !state.token || !state.data?.player) return;
    const params = new URLSearchParams(window.location.search);
    const needed = Number(params.get('deposit_needed') || 0);
    const requested = params.get('open');
    const hash = String(window.location.hash || '').replace('#','');
    const target = requested === 'withdraw' || hash === 'withdrawPanel'
      ? 'withdrawPanel'
      : (requested === 'deposit' || hash === 'depositPanel' || needed > 0 ? 'depositPanel' : '');
    if (!target) return;
    state.depositRedirectHandled = true;
    if (target === 'depositPanel' && needed > 0 && els.depositAmount) {
      els.depositAmount.value = String(Math.max(1, Math.ceil(needed)));
    }
    setTimeout(() => openQuickTransaction(target === 'withdrawPanel' ? 'withdraw' : 'deposit', needed), 0);
    if (target === 'depositPanel' && needed > 0) {
      setMessage(els.depositMessage, `Faltam ${formatMoney(needed)} MZN para continuar a operação anterior.`, 'error');
      showToast(`Faltam ${formatMoney(needed)} MZN. Faça o depósito para continuar.`, 'error');
    }
  }

  els.accountButton.addEventListener('click', () => {
    if (!state.token || !state.data?.player) return openAuth('login');
    const willOpen = els.accountMenu.classList.contains('hidden');
    els.accountMenu.classList.toggle('hidden', !willOpen);
    els.accountButton.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
  });

  els.accountMenuDeposit?.addEventListener('click', () => openQuickTransaction('deposit'));
  els.accountMenuWithdraw?.addEventListener('click', () => openQuickTransaction('withdraw'));
  els.accountMenuLogout?.addEventListener('click', logoutPlayer);
  els.logoutButton.addEventListener('click', logoutPlayer);

  document.addEventListener('click', (event) => {
    if (!els.accountMenu || els.accountMenu.classList.contains('hidden')) return;
    if (event.target.closest('#accountButton') || event.target.closest('#accountMenu')) return;
    closeAccountMenu();
  });

  document.getElementById('copyDepositPhone')?.addEventListener('click',async()=>{
    try{await navigator.clipboard.writeText('869954518');showToast('Número 869954518 copiado.','success');}
    catch{showToast('Número de transferência: 869954518');}
  });
  els.refreshButton.addEventListener('click', () => refresh());
  els.closeAuth.addEventListener('click', closeAuth);
  els.registerTab.addEventListener('click', () => switchAuth('register'));
  els.loginTab.addEventListener('click', () => switchAuth('login'));
  els.authModal.addEventListener('click', (event) => { if (event.target === els.authModal) closeAuth(); });
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    if (els.transactionModal && !els.transactionModal.classList.contains('hidden')) return closeTransactionModal();
    if (!els.authModal.classList.contains('hidden')) closeAuth();
  });

  buildNumbers();
  buildPairNumbers();
  refresh();
  state.refreshTimer = setInterval(() => refresh(true), 10000);
})();
