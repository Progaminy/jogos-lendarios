(() => {
  'use strict';

  const MONEY = (value) => Number(value || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const token = () => window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  const rpc = (name, args = {}) => window.JLApi.rpc(name, args);

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
    if (!main || document.getElementById('jlGlobalAccountFooter')) return null;
    const section = document.createElement('section');
    section.id = 'jlGlobalAccountFooter';
    section.className = 'jl-account-footer';
    section.setAttribute('aria-label', 'Conta, depósito e saque');
    main.appendChild(section);
    return section;
  }

  function renderLoggedOut(root) {
    root.innerHTML = `
      <section class="jl-account-card jl-account-login">
        <p class="jl-account-kicker">MINHA CONTA</p>
        <h2>Conta dos Jogos Lendários</h2>
        <p class="jl-account-muted">Entre na sua conta para ver saldo, depósito e saque.</p>
        <a class="jl-account-btn primary" href="./index.html#playerArea">Entrar na conta</a>
      </section>`;
  }

  function renderAccount(root, data) {
    const player = data?.player || {};
    const bonus = data?.bonus || {};
    const confirmed = player.balance_confirmed === true && Number.isFinite(Number(player.balance));
    const balance = confirmed ? `${MONEY(player.balance)} MZN` : 'Saldo a confirmar';
    const withdrawable = confirmed && Number.isFinite(Number(player.withdrawable_balance)) ? `${MONEY(player.withdrawable_balance)} MZN` : '—';
    const locked = confirmed && Number.isFinite(Number(player.deposit_locked)) ? `${MONEY(player.deposit_locked)} MZN` : '—';
    const phone = player.phone ? `+${String(player.phone).replace(/^\+/, '')}` : '—';

    root.innerHTML = `
      <section class="jl-account-card jl-account-head">
        <div>
          <p class="jl-account-kicker">MINHA CONTA</p>
          <h2>${String(player.name || 'Jogador')}</h2>
          <p class="jl-account-phone">${phone}</p>
        </div>
        <div class="jl-account-stat"><span>Saldo disponível</span><strong>${balance}</strong><small>saldo comum</small></div>
        <div class="jl-account-stat"><span>Bónus para jogar</span><strong class="jl-account-bonus">${MONEY(bonus.total || 0)} MZN</strong><small>Número ${MONEY(bonus.number || 0)} · Dupla ${MONEY(bonus.pair || 0)}</small></div>
        <div class="jl-account-stat"><span>Disponível para saque</span><strong>${withdrawable}</strong><small>conforme regras</small></div>
      </section>

      <div class="jl-account-grid">
        <section class="jl-account-card jl-account-panel">
          <p class="jl-account-kicker">DEPÓSITO</p>
          <h3>Solicitar depósito</h3>
          <p class="jl-account-muted jl-account-transfer">Transfira para <strong>869954518</strong> <button id="jlAccountCopyPhone" class="jl-account-btn ghost tiny" type="button">Copiar</button> · confirmação: <strong>Bernardo Pedro</strong>.</p>
          <p class="jl-account-note">O saldo é comum a todos os Jogos Lendários. Depois de aprovado, o valor depositado precisa ser jogado pelo menos uma vez antes de poder ser sacado.</p>
          <form id="jlAccountDepositForm" class="jl-account-form">
            <label class="jl-account-field"><span>Valor</span><div class="jl-account-money"><span>MZN</span><input id="jlAccountDepositAmount" type="number" min="1" step="1" required></div></label>
            <label class="jl-account-field"><span>Referência da transferência ou mensagem de confirmação</span><input id="jlAccountDepositNote" maxlength="160" placeholder="Ex.: referência do pagamento"></label>
            <button class="jl-account-btn primary" type="submit">Enviar solicitação de depósito</button>
          </form>
          <p id="jlAccountDepositMessage" class="jl-account-message"></p>
        </section>

        <section class="jl-account-card jl-account-panel">
          <p class="jl-account-kicker">SAQUE</p>
          <h3>Solicitar saque</h3>
          <p class="jl-account-muted">Depósitos aprovados precisam ser jogados pelo menos uma vez antes de poderem ser sacados.</p>
          <div class="jl-account-status">
            <div><small>Disponível para saque</small><strong>${withdrawable}</strong></div>
            <div><small>Depósito ainda por jogar</small><strong>${locked}</strong></div>
          </div>
          <form id="jlAccountWithdrawForm" class="jl-account-form">
            <label class="jl-account-field"><span>Valor</span><div class="jl-account-money"><span>MZN</span><input id="jlAccountWithdrawAmount" type="number" min="1" step="1" required></div></label>
            <button class="jl-account-btn primary" type="submit">Pedir saque</button>
          </form>
          <p id="jlAccountWithdrawMessage" class="jl-account-message"></p>
        </section>
      </div>`;

    document.getElementById('jlAccountCopyPhone')?.addEventListener('click', async () => {
      const ok = await copy('869954518');
      message(document.getElementById('jlAccountDepositMessage'), ok ? 'Número copiado.' : 'Não foi possível copiar o número.', ok ? 'success' : 'error');
    });

    document.getElementById('jlAccountDepositForm')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const amount = Number(document.getElementById('jlAccountDepositAmount')?.value);
      const note = String(document.getElementById('jlAccountDepositNote')?.value || '').trim();
      const out = document.getElementById('jlAccountDepositMessage');
      const button = event.currentTarget.querySelector('button[type="submit"]');
      if (!Number.isInteger(amount) || amount < 1) {
        message(out, 'Informe um valor inteiro válido.', 'error');
        return;
      }
      button.disabled = true;
      message(out, 'A enviar pedido…');
      try {
        const result = await window.JLFinancial.rpc('deposit', 'jl_request_deposit_idempotent', {
          p_token: token(), p_amount: amount, p_note: note
        });
        const ref = result?.request_id ? ` · confirmação ${String(result.request_id).slice(0, 8).toUpperCase()}` : '';
        message(out, `${result?.message || 'Pedido de depósito enviado.'}${ref}`, result?.ok === false ? 'error' : 'success');
        if (result?.ok !== false) {
          event.currentTarget.reset();
          setTimeout(refresh, 600);
        }
      } catch (error) {
        message(out, error?.message || 'Não foi possível enviar o depósito.', 'error');
      } finally {
        button.disabled = false;
      }
    });

    document.getElementById('jlAccountWithdrawForm')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const amount = Number(document.getElementById('jlAccountWithdrawAmount')?.value);
      const out = document.getElementById('jlAccountWithdrawMessage');
      const button = event.currentTarget.querySelector('button[type="submit"]');
      if (!Number.isInteger(amount) || amount < 1) {
        message(out, 'Informe um valor inteiro válido.', 'error');
        return;
      }
      button.disabled = true;
      message(out, 'A verificar o saque…');
      try {
        let check = null;
        try {
          check = await rpc('jl_check_funds', { p_token: token(), p_game_type: 'withdrawal', p_amount: amount });
        } catch {}
        if (check?.reason === 'deposit_not_played') {
          message(out, `Este valor ainda não pode ser sacado: ${MONEY(check.deposit_locked || 0)} MZN de depósito ainda precisa ser jogado.`, 'error');
          return;
        }
        if (check && check.ok === false && check.redirect_to_deposit) {
          message(out, 'Saldo insuficiente para este saque.', 'error');
          return;
        }
        const result = await window.JLFinancial.rpc('withdrawal', 'jl_request_withdrawal_idempotent', {
          p_token: token(), p_amount: amount
        });
        const ref = result?.request_id ? ` · confirmação ${String(result.request_id).slice(0, 8).toUpperCase()}` : '';
        message(out, `${result?.message || 'Pedido de saque enviado.'}${ref}`, result?.ok === false ? 'error' : 'success');
        if (result?.ok !== false) {
          event.currentTarget.reset();
          setTimeout(refresh, 600);
        }
      } catch (error) {
        message(out, error?.message || 'Não foi possível enviar o saque.', 'error');
      } finally {
        button.disabled = false;
      }
    });
  }

  let root = null;
  async function refresh() {
    if (!root) return;
    const t = token();
    if (!t) {
      renderLoggedOut(root);
      return;
    }
    try {
      const data = await rpc('jl_player_state', { p_token: t });
      if (!data?.player) {
        renderLoggedOut(root);
        return;
      }
      renderAccount(root, data);
    } catch (error) {
      if (/sess[aã]o|session/i.test(String(error?.message || ''))) renderLoggedOut(root);
      else root.innerHTML = `<section class="jl-account-card jl-account-login"><p class="jl-account-kicker">MINHA CONTA</p><h2>Não foi possível carregar a conta</h2><p class="jl-account-muted">${String(error?.message || 'Tente atualizar a página.')}</p></section>`;
    }
  }

  function boot() {
    if (nativeAccountAtBottom()) return;
    root = createFooter();
    if (!root) return;
    refresh();
    window.addEventListener('jl-player-session-changed', refresh);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') refresh();
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();