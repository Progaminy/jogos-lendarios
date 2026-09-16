(() => {
  'use strict';

  const MIN_BET = 10;
  const MAX_BET = 500;

  function showToast(message, type = 'error') {
    const toast = document.getElementById('toast');
    if (!toast) return;
    toast.textContent = message;
    toast.className = `toast show ${type}`.trim();
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => { toast.className = 'toast'; }, 3600);
  }

  function parseMoney(value) {
    const normalized = String(value ?? '')
      .replace(/\s/g, '')
      .replace(/\./g, '')
      .replace(',', '.')
      .replace(/[^0-9.-]/g, '');
    const number = Number(normalized);
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

  const betForm = document.getElementById('betForm');
  betForm?.addEventListener('submit', (event) => {
    const betAmount = document.getElementById('betAmount');
    const amount = Number(betAmount?.value);

    if (!Number.isFinite(amount) || amount < MIN_BET || amount > MAX_BET) {
      event.preventDefault();
      event.stopImmediatePropagation();
      showToast(`A aposta deve ser entre ${MIN_BET} e ${MAX_BET} MZN.`, 'error');
      betAmount?.focus();
      return;
    }

    // Se o jogador já está autenticado, evita uma chamada desnecessária
    // quando o saldo visível já é inferior ao valor escolhido.
    const playerArea = document.getElementById('playerArea');
    if (!playerArea || playerArea.classList.contains('hidden')) return;

    const balance = parseMoney(document.getElementById('balance')?.textContent);
    if (Number.isFinite(balance) && balance < amount) {
      event.preventDefault();
      event.stopImmediatePropagation();
      goToDeposit();
    }
  }, true);

  // Proteção adicional: se o saldo mudou entretanto e o Supabase rejeitar
  // a aposta, o jogador também é levado automaticamente ao depósito.
  const originalFetch = window.fetch.bind(window);
  window.fetch = async (...args) => {
    const response = await originalFetch(...args);
    const url = typeof args[0] === 'string' ? args[0] : args[0]?.url || '';

    if (url.includes('/rest/v1/rpc/jl_place_bet') && !response.ok) {
      response.clone().text().then((text) => {
        if (/saldo insuficiente/i.test(text)) goToDeposit();
      }).catch(() => {});
    }

    return response;
  };
})();
