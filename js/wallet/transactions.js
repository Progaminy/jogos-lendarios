(() => {
  'use strict';

  function create({
    state,
    els,
    formatMoney,
    showToast,
    copyTextToClipboard,
    checkFunds,
    directToDeposit,
    openAuth,
    refresh
  }) {
    const quickTransaction = { kind: null, amount: 0 };

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

      if (ok) {
        const noticeKey = reference || `${kind}:${Number(amount) || 0}:${Date.now()}`;
        window.JLNotifications?.push({
          id: `finance:${kind}:${noticeKey}`,
          title: isDeposit ? 'Depósito solicitado' : 'Saque solicitado',
          message: `${formatMoney(amount)} MZN · ${message || 'Pedido recebido.'}${reference ? ` · confirmação ${reference}` : ''}`,
          type: 'finance',
          href: isDeposit ? './index.html#depositPanel' : './index.html#withdrawPanel'
        });
      }
    }

    function closeTransactionModal() {
      if (!els.transactionModal) return;
      els.transactionModal.classList.add('hidden');
      document.body.classList.remove('modal-open');
    }

    function ensureQuickTransactionModal() {
      let modal = document.getElementById('quickTransactionModal');
      if (modal) return modal;

      modal = document.createElement('div');
      modal.id = 'quickTransactionModal';
      modal.className = 'transaction-modal hidden';
      modal.setAttribute('role', 'dialog');
      modal.setAttribute('aria-modal', 'true');
      modal.setAttribute('aria-labelledby', 'quickTransactionTitle');
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
            <label class="field"><span id="quickTransactionNoteLabel">Referência da transferência</span><input id="quickTransactionNote" maxlength="160" placeholder="Ex.: referência do pagamento"></label>
            <button id="quickTransactionSubmit" class="button primary" type="submit">Enviar pedido</button>
          </form>
          <p id="quickTransactionMessage" class="form-message"></p>
        </div>`;

      document.body.appendChild(modal);
      const close = () => {
        modal.classList.add('hidden');
        document.body.classList.remove('modal-open');
      };

      document.getElementById('quickTransactionClose').addEventListener('click', close);
      modal.addEventListener('click', (event) => { if (event.target === modal) close(); });

      document.getElementById('quickTransactionAmountForm').addEventListener('submit', async (event) => {
        event.preventDefault();
        const amount = Number(document.getElementById('quickTransactionAmount').value);
        if (!Number.isInteger(amount) || amount < 1) {
          document.getElementById('quickTransactionMessage').textContent = 'Informe um valor inteiro válido.';
          return;
        }

        if (quickTransaction.kind === 'withdraw') {
          const button = event.currentTarget.querySelector('button[type="submit"]');
          const message = document.getElementById('quickTransactionMessage');
          if (button) {
            button.disabled = true;
            button.textContent = 'Enviando saque…';
          }
          if (message) message.textContent = 'A verificar o saque…';

          try {
            let check = null;
            try { check = await checkFunds('withdrawal', amount); } catch {}

            if (check?.reason === 'deposit_not_played') {
              if (message) {
                message.textContent = `Este valor ainda não pode ser sacado: ${formatMoney(check.deposit_locked || 0)} MZN de depósito ainda precisa ser jogado.`;
              }
              return;
            }

            if (check?.redirect_to_deposit) {
              close();
              directToDeposit(check, 'fazer este saque');
              return;
            }

            const result = await window.JLFinancial.rpc('withdrawal', 'jl_request_withdrawal_idempotent', {
              p_token: state.token,
              p_amount: amount
            });
            const ok = result?.ok !== false;
            const reference = result?.request_id ? result.request_id.slice(0, 8).toUpperCase() : '';
            close();
            showTransactionModal({ kind: 'withdraw', amount, message: result?.message, reference, ok });
            await refresh(true);
          } catch (error) {
            if (message) message.textContent = error?.message || 'Não foi possível enviar o saque.';
            showToast(error?.message || 'Não foi possível enviar o saque.', 'error');
          } finally {
            if (button) {
              button.disabled = false;
              button.textContent = 'Pedir saque';
            }
          }
          return;
        }

        quickTransaction.amount = amount;
        document.getElementById('quickTransactionAmountForm').classList.add('hidden');
        document.getElementById('quickTransactionNoteForm').classList.remove('hidden');
        document.getElementById('quickTransactionTitle').textContent = 'Referência da transferência';

        const info = document.getElementById('quickTransferInfo');
        info.innerHTML = 'Transfira para <strong class="transfer-phone">869954518</strong> · Nome de confirmação: <strong class="transfer-account-name">Bernardo Pedro</strong> <button id="quickCopyDepositPhone" class="button ghost tiny" type="button">Copiar</button>';
        info.classList.remove('hidden');

        document.getElementById('quickTransactionNoteLabel').textContent = 'Referência da transferência ou mensagem opcional';
        document.getElementById('quickCopyDepositPhone')?.addEventListener('click', async () => {
          const copied = await copyTextToClipboard('869954518');
          showToast(copied ? 'Número copiado.' : 'Não foi possível copiar o número.', copied ? 'success' : 'error');
        });
        document.getElementById('quickTransactionNote').focus();
      });

      document.getElementById('quickTransactionNoteForm').addEventListener('submit', async (event) => {
        event.preventDefault();
        const amount = quickTransaction.amount;
        const note = document.getElementById('quickTransactionNote').value.trim();
        const button = document.getElementById('quickTransactionSubmit');
        button.disabled = true;

        try {
          const result = quickTransaction.kind === 'deposit'
            ? await window.JLFinancial.rpc('deposit', 'jl_request_deposit_idempotent', {
                p_token: state.token,
                p_amount: amount,
                p_note: note
              })
            : await window.JLFinancial.rpc('withdrawal', 'jl_request_withdrawal_idempotent', {
                p_token: state.token,
                p_amount: amount
              });

          const ok = result?.ok !== false;
          const reference = result?.request_id ? result.request_id.slice(0, 8).toUpperCase() : '';
          close();
          showTransactionModal({ kind: quickTransaction.kind, amount, message: result?.message, reference, ok });
          await refresh(true);
        } catch (error) {
          document.getElementById('quickTransactionMessage').textContent = error.message;
        } finally {
          button.disabled = false;
        }
      });

      return modal;
    }

    function openQuickTransaction(kind, presetAmount = 0) {
      if (!state.token || !state.data?.player) {
        openAuth('login');
        return;
      }

      const modal = ensureQuickTransactionModal();
      quickTransaction.kind = kind;
      quickTransaction.amount = 0;
      document.getElementById('quickTransactionEyebrow').textContent = kind === 'deposit' ? 'DEPÓSITO' : 'SAQUE';
      document.getElementById('quickTransactionTitle').textContent = kind === 'deposit' ? 'Quanto deseja depositar?' : 'Quanto deseja sacar?';

      const amountButton = document.querySelector('#quickTransactionAmountForm button[type="submit"]');
      if (amountButton) amountButton.textContent = kind === 'deposit' ? 'Continuar' : 'Pedir saque';

      document.getElementById('quickTransactionAmount').value = presetAmount > 0 ? String(Math.ceil(presetAmount)) : '';
      document.getElementById('quickTransactionNote').value = '';
      document.getElementById('quickTransactionMessage').textContent = '';
      document.getElementById('quickTransactionAmountForm').classList.remove('hidden');
      document.getElementById('quickTransactionNoteForm').classList.add('hidden');
      modal.classList.remove('hidden');
      document.body.classList.add('modal-open');
      setTimeout(() => document.getElementById('quickTransactionAmount')?.focus(), 30);
    }

    return Object.freeze({
      showTransactionModal,
      closeTransactionModal,
      openQuickTransaction
    });
  }

  window.JLWalletTransactions = Object.freeze({ create });
})();