(() => {
  'use strict';

  const MONEY = (value) => Number(value || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const token = () => window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  const rpc = (name, args = {}) => window.JLApi.rpc(name, args);
  const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));

  let root = null;
  let actionModal = null;
  const actionState = { kind: 'deposit' };

  function message(el, text = '', type = '') {
    if (!el) return;
    el.textContent = text;
    el.className = `jl-account-message ${type}`.trim();
  }

  async function copy(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {}
    const area = document.createElement('textarea');
    area.value = text;
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch {}
    area.remove();
    return ok;
  }

  function nativeAccountAtBottom() {
    const existing = document.getElementById('playerArea');
    const main = document.querySelector('main');
    if (!existing || !main) return false;
    existing.classList.add('jl-account-footer-native');
    main.appendChild(existing);
    return true;
  }

  function createFooter() {
    const main = document.querySelector('main');
    if (!main) return null;
    let section = document.getElementById('jlGlobalAccountFooter');
    if (section) return section;
    section = document.createElement('section');
    section.id = 'jlGlobalAccountFooter';
    section.className = 'jl-account-footer';
    section.setAttribute('aria-label', 'Conta');
    main.appendChild(section);
    return section;
  }

  function wireLocalAccountLinks() {
    const localTarget = document.getElementById('jlGlobalAccountFooter') ? '#jlGlobalAccountFooter' : '#playerArea';
    const navAccount = document.querySelector('.game-nav [data-jl-nav="conta"]');
    if (navAccount) navAccount.setAttribute('href', localTarget);
    const headerAccount = document.getElementById('jlHeaderAccount');
    if (headerAccount) headerAccount.setAttribute('href', localTarget);
  }

  async function confirmLogout() {
    if (typeof window.JLConfirmLogout === 'function') return Boolean(await window.JLConfirmLogout());
    return window.confirm('Sair da conta?');
  }

  async function logoutHere(button) {
    const pageLogout = document.getElementById('accountMenuLogout');
    if (pageLogout && pageLogout !== button) {
      pageLogout.click();
      return;
    }

    if (!(await confirmLogout())) return;
    const current = token();
    if (button) button.disabled = true;
    try {
      try { if (current) await rpc('jl_logout_player', { p_token: current }); } catch {}
      if (window.JLSession?.setPlayerToken) window.JLSession.setPlayerToken('');
      else {
        localStorage.removeItem('jl_player_token');
        window.dispatchEvent(new CustomEvent('jl-player-session-changed', { detail: { authenticated: false } }));
      }

      closeActionModal();
      if (root) renderLoggedOut(root);
      const headerAccount = document.getElementById('jlHeaderAccount');
      if (headerAccount) headerAccount.textContent = 'Entrar';
      setTimeout(() => location.reload(), 80);
    } finally {
      if (button) button.disabled = false;
    }
  }

  function renderLoggedOut(target) {
    target.innerHTML = `
      <section class="jl-account-card jl-account-login">
        <p class="jl-account-kicker">MINHA CONTA</p>
        <h2>Conta dos Jogos Lendários</h2>
        <p class="jl-account-muted">Entre na sua conta para ver saldo, depósito e saque.</p>
        <a class="jl-account-btn primary" href="./index.html#playerArea">Entrar na conta</a>
      </section>`;
  }

  function closeHeaderMenu() {
    document.getElementById('accountMenu')?.classList.add('hidden');
    document.getElementById('accountButton')?.setAttribute('aria-expanded', 'false');
  }

  function ensureActionModal() {
    if (actionModal?.isConnected) return actionModal;
    actionModal = document.createElement('div');
    actionModal.id = 'jlAccountActionModal';
    actionModal.className = 'jl-account-modal hidden';
    actionModal.setAttribute('role', 'dialog');
    actionModal.setAttribute('aria-modal', 'true');
    actionModal.setAttribute('aria-labelledby', 'jlAccountActionTitle');
    actionModal.innerHTML = `
      <section class="jl-account-dialog">
        <button id="jlAccountActionClose" class="jl-account-modal-close" type="button" aria-label="Fechar">×</button>
        <p id="jlAccountActionKicker" class="jl-account-kicker">DEPÓSITO</p>
        <h3 id="jlAccountActionTitle">Solicitar depósito</h3>
        <div id="jlAccountActionInfo" class="jl-account-action-info"></div>
        <form id="jlAccountActionForm" class="jl-account-form">
          <label class="jl-account-field"><span>Valor</span><div class="jl-account-money"><span>MZN</span><input id="jlAccountActionAmount" type="number" min="1" step="1" inputmode="numeric" required></div></label>
          <label id="jlAccountActionNoteField" class="jl-account-field"><span>Referência da transferência ou mensagem de confirmação</span><input id="jlAccountActionNote" maxlength="160" placeholder="Ex.: referência do pagamento"></label>
          <button id="jlAccountActionSubmit" class="jl-account-btn primary" type="submit">Enviar solicitação de depósito</button>
        </form>
        <p id="jlAccountActionMessage" class="jl-account-message" aria-live="polite"></p>
      </section>`;
    document.body.appendChild(actionModal);

    document.getElementById('jlAccountActionClose')?.addEventListener('click', closeActionModal);
    actionModal.addEventListener('click', (event) => {
      if (event.target === actionModal) closeActionModal();
    });

    document.getElementById('jlAccountActionForm')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const form = event.currentTarget;
      const amount = Number(document.getElementById('jlAccountActionAmount')?.value);
      const note = String(document.getElementById('jlAccountActionNote')?.value || '').trim();
      const out = document.getElementById('jlAccountActionMessage');
      const button = document.getElementById('jlAccountActionSubmit');

      if (!Number.isInteger(amount) || amount < 1) {
        message(out, 'Informe um valor inteiro válido.', 'error');
        return;
      }

      if (button) button.disabled = true;
      message(out, actionState.kind === 'deposit' ? 'A enviar pedido…' : 'A verificar e enviar o saque…');

      try {
        if (actionState.kind === 'withdraw') {
          let check = null;
          try { check = await rpc('jl_check_funds', { p_token: token(), p_game_type: 'withdrawal', p_amount: amount }); } catch {}
          if (check?.reason === 'deposit_not_played') {
            message(out, `Este valor ainda não pode ser sacado: ${MONEY(check.deposit_locked || 0)} MZN de depósito ainda precisa ser jogado.`, 'error');
            return;
          }
          if (check && check.ok === false && check.redirect_to_deposit) {
            message(out, 'Saldo insuficiente para este saque.', 'error');
            return;
          }
        }

        const isDeposit = actionState.kind === 'deposit';
        const result = await window.JLFinancial.rpc(
          isDeposit ? 'deposit' : 'withdrawal',
          isDeposit ? 'jl_request_deposit_idempotent' : 'jl_request_withdrawal_idempotent',
          isDeposit
            ? { p_token: token(), p_amount: amount, p_note: note }
            : { p_token: token(), p_amount: amount }
        );
        const ok = result?.ok !== false;
        const ref = result?.request_id ? ` · confirmação ${String(result.request_id).slice(0, 8).toUpperCase()}` : '';
        message(out, `${result?.message || (isDeposit ? 'Pedido de depósito enviado.' : 'Pedido de saque enviado.')}${ref}`, ok ? 'success' : 'error');

        if (ok) {
          // Guardar a referência do formulário antes dos awaits evita o erro
          // "Cannot read properties of null (reading 'reset')".
          form.reset();
          setTimeout(() => refresh(), 450);
          setTimeout(() => closeActionModal(), 1500);
        }
      } catch (error) {
        message(out, error?.message || 'Não foi possível concluir o pedido.', 'error');
      } finally {
        if (button) button.disabled = false;
      }
    });

    return actionModal;
  }

  function closeActionModal() {
    if (!actionModal) return;
    actionModal.classList.add('hidden');
    document.body.classList.remove('modal-open');
  }

  function openTransaction(kind = 'deposit', presetAmount = 0) {
    if (!token()) return;
    const modal = ensureActionModal();
    const isDeposit = kind !== 'withdraw';
    actionState.kind = isDeposit ? 'deposit' : 'withdraw';

    const kicker = document.getElementById('jlAccountActionKicker');
    const title = document.getElementById('jlAccountActionTitle');
    const info = document.getElementById('jlAccountActionInfo');
    const noteField = document.getElementById('jlAccountActionNoteField');
    const submit = document.getElementById('jlAccountActionSubmit');
    const amount = document.getElementById('jlAccountActionAmount');
    const note = document.getElementById('jlAccountActionNote');
    const out = document.getElementById('jlAccountActionMessage');

    if (kicker) kicker.textContent = isDeposit ? 'DEPÓSITO' : 'SAQUE';
    if (title) title.textContent = isDeposit ? 'Solicitar depósito' : 'Solicitar saque';
    if (noteField) noteField.classList.toggle('hidden', !isDeposit);
    if (submit) submit.textContent = isDeposit ? 'Enviar solicitação de depósito' : 'Pedir saque';
    if (amount) amount.value = presetAmount > 0 ? String(Math.ceil(presetAmount)) : '';
    if (note) note.value = '';
    message(out);

    if (info) {
      if (isDeposit) {
        info.innerHTML = `
          <p>Transfira para <strong>869954518</strong> <button id="jlAccountModalCopyPhone" class="jl-account-btn ghost tiny" type="button">Copiar</button></p>
          <p>Confirmação: <strong>Bernardo Pedro</strong>.</p>
          <small>Depois de aprovado, o valor depositado precisa ser jogado pelo menos uma vez antes de poder ser sacado.</small>`;
        document.getElementById('jlAccountModalCopyPhone')?.addEventListener('click', async () => {
          const ok = await copy('869954518');
          message(out, ok ? 'Número copiado.' : 'Não foi possível copiar o número.', ok ? 'success' : 'error');
        });
      } else {
        const player = window.JLAccountFooter?.lastData?.player || {};
        const withdrawable = Number.isFinite(Number(player.withdrawable_balance)) ? `${MONEY(player.withdrawable_balance)} MZN` : '—';
        const locked = Number.isFinite(Number(player.deposit_locked)) ? `${MONEY(player.deposit_locked)} MZN` : '—';
        info.innerHTML = `<p>Disponível para saque: <strong>${escapeHtml(withdrawable)}</strong></p><small>Depósito ainda por jogar: ${escapeHtml(locked)}</small>`;
      }
    }

    closeHeaderMenu();
    modal.classList.remove('hidden');
    document.body.classList.add('modal-open');
    setTimeout(() => amount?.focus(), 30);
  }

  function triggerHeaderAction(id) {
    closeHeaderMenu();
    const trigger = document.getElementById(id);
    if (trigger) trigger.click();
  }

  function renderAccount(target, data) {
    const player = data?.player || {};
    const bonus = data?.bonus || {};
    const confirmed = player.balance_confirmed === true && Number.isFinite(Number(player.balance));
    const balance = confirmed ? `${MONEY(player.balance)} MZN` : 'Saldo a confirmar';
    const withdrawable = confirmed && Number.isFinite(Number(player.withdrawable_balance)) ? `${MONEY(player.withdrawable_balance)} MZN` : '—';
    const phone = player.phone ? `+${String(player.phone).replace(/^\+/, '')}` : '—';

    target.innerHTML = `
      <section class="jl-account-card jl-account-head">
        <div>
          <p class="jl-account-kicker">MINHA CONTA</p>
          <h2>${escapeHtml(player.name || 'Jogador')}</h2>
          <p class="jl-account-phone">${escapeHtml(phone)}</p>
        </div>
        <div class="jl-account-stat"><span>Saldo disponível</span><strong>${balance}</strong><small>saldo comum</small></div>
        <div class="jl-account-stat"><span>Bónus para jogar</span><strong class="jl-account-bonus">${MONEY(bonus.total || 0)} MZN</strong><small>Número ${MONEY(bonus.number || 0)} · Dupla ${MONEY(bonus.pair || 0)}</small></div>
        <div class="jl-account-stat"><span>Disponível para saque</span><strong>${withdrawable}</strong><small>conforme regras</small></div>
      </section>

      <section class="jl-account-card jl-account-actions-card">
        <div class="jl-account-actions" aria-label="Ações da conta">
          <button id="jlAccountDeposit" class="jl-account-btn primary" type="button">Depósito</button>
          <button id="jlAccountWithdraw" class="jl-account-btn ghost" type="button">Saque</button>
          <button id="jlAccountSupport" class="jl-account-btn ghost" type="button">Mensagem</button>
          <button id="jlAccountSessions" class="jl-account-btn ghost" type="button">Sessões</button>
        </div>
        <div class="jl-account-logout-row">
          <button id="jlAccountLogout" class="jl-account-btn danger" type="button">Sair</button>
        </div>
      </section>`;

    document.getElementById('jlAccountDeposit')?.addEventListener('click', () => openTransaction('deposit'));
    document.getElementById('jlAccountWithdraw')?.addEventListener('click', () => openTransaction('withdraw'));
    document.getElementById('jlAccountSupport')?.addEventListener('click', () => triggerHeaderAction('accountMenuSupport'));
    document.getElementById('jlAccountSessions')?.addEventListener('click', () => triggerHeaderAction('accountMenuSessions'));
    document.getElementById('jlAccountLogout')?.addEventListener('click', (event) => logoutHere(event.currentTarget));
  }

  function bindHeaderFinancialActions() {
    if (document.documentElement.dataset.jlAccountFooterFinancialBound === '1') return;
    document.documentElement.dataset.jlAccountFooterFinancialBound = '1';
    document.addEventListener('click', (event) => {
      const trigger = event.target.closest?.('#accountMenuDeposit,#accountMenuWithdraw');
      if (!trigger || !root || !token()) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      closeHeaderMenu();
      openTransaction(trigger.id === 'accountMenuWithdraw' ? 'withdraw' : 'deposit');
    }, true);
  }

  async function refresh() {
    if (!root) return;
    const current = token();
    if (!current) {
      renderLoggedOut(root);
      return;
    }
    try {
      const data = await rpc('jl_player_state', { p_token: current });
      window.JLAccountFooter.lastData = data || null;
      if (!data?.player) {
        renderLoggedOut(root);
        return;
      }
      renderAccount(root, data);
    } catch (error) {
      if (/sess[aã]o|session/i.test(String(error?.message || ''))) {
        renderLoggedOut(root);
      } else {
        root.innerHTML = '<section class="jl-account-card jl-account-login"><p class="jl-account-kicker">MINHA CONTA</p><h2>Não foi possível carregar a conta</h2><p id="jlAccountLoadError" class="jl-account-muted"></p></section>';
        const out = document.getElementById('jlAccountLoadError');
        if (out) out.textContent = String(error?.message || 'Tente atualizar a página.');
      }
    }
  }

  function boot() {
    if (nativeAccountAtBottom()) {
      wireLocalAccountLinks();
      return;
    }
    root = createFooter();
    if (!root) return;
    wireLocalAccountLinks();
    bindHeaderFinancialActions();
    refresh();
    window.addEventListener('jl-player-session-changed', refresh);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') refresh();
    });
  }

  window.JLAccountFooter = {
    lastData: null,
    refresh,
    openTransaction,
    closeTransaction: closeActionModal
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();
