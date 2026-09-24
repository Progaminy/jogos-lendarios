(() => {
  'use strict';

  function showToast(message, type = 'error') {
    const toast = document.getElementById('toast');
    if (!toast) return;
    toast.textContent = message;
    toast.className = `toast show ${type}`.trim();
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => { toast.className = 'toast'; }, 3600);
  }

  function parseMoney(value) {
    const raw = String(value ?? '').trim();
    const normalized = raw.includes(',')
      ? raw.replace(/\s/g, '').replace(/\./g, '').replace(',', '.')
      : raw.replace(/\s/g, '').replace(/[^0-9.-]/g, '');
    const number = Number(normalized.replace(/[^0-9.-]/g, ''));
    return Number.isFinite(number) ? number : NaN;
  }

  function goToDeposit(message = 'Saldo insuficiente. Faça um depósito para continuar a apostar.') {
    const playerArea = document.getElementById('playerArea');
    const depositForm = document.getElementById('depositForm');
    const depositAmount = document.getElementById('depositAmount');

    if (!depositForm || playerArea?.classList.contains('hidden')) return;
    showToast(message, 'error');
    depositForm.scrollIntoView({ behavior: 'smooth', block: 'center' });
    window.setTimeout(() => depositAmount?.focus({ preventScroll: true }), 450);
  }

  function guardForm(formId, amountId) {
    const form = document.getElementById(formId);
    form?.addEventListener('submit', (event) => {
      const amountInput = document.getElementById(amountId);
      const amount = Number(amountInput?.value);
      const min = Number(amountInput?.min);
      const max = Number(amountInput?.max);

      if (!Number.isFinite(amount) ||
          !Number.isInteger(amount) ||
          (Number.isFinite(min) && amount < min) ||
          (Number.isFinite(max) && amount > max)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        showToast(`A aposta deve ser um valor inteiro entre ${min} e ${max} MZN.`, 'error');
        amountInput?.focus();
        return;
      }

      // Não comparar aqui apenas com saldo em dinheiro.
      // O motor principal chama jl_check_funds, que considera saldo + bónus elegível por jogo.
    }, true);
  }

  guardForm('betForm', 'betAmount');
  guardForm('pairBetForm', 'pairBetAmount');

  const originalFetch = window.fetch.bind(window);
  window.fetch = async (...args) => {
    const response = await originalFetch(...args);
    const url = typeof args[0] === 'string' ? args[0] : args[0]?.url || '';
    const isBetRpc =
      url.includes('/rest/v1/rpc/jl_place_bet') ||
      url.includes('/rest/v1/rpc/jl_place_pair_bet');

    if (isBetRpc && !response.ok) {
      response.clone().text().then((text) => {
        if (/saldo insuficiente/i.test(text)) goToDeposit();
      }).catch(() => {});
    }

    return response;
  };
})();