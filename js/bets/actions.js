(() => {
  'use strict';

  function create({ state, els, ensureFunds, showToast, refresh, updateBetButtons }) {
    async function placeNumberBet(number, amount) {
      try {
        if (!(await ensureFunds('number', amount, 'apostar no Número Lendário'))) return;
        els.betButton.disabled = true;
        const result = await window.JLFinancial.rpc('number-bet', 'jl_place_bet_idempotent', {
          p_token: state.token,
          p_selected_number: Number(number),
          p_amount: Number(amount)
        });
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
        const result = await window.JLFinancial.rpc('pair-bet', 'jl_place_pair_bet_idempotent', {
          p_token: state.token,
          p_number_a: a,
          p_number_b: b,
          p_amount: Number(amount)
        });
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

    return Object.freeze({ placeNumberBet, placePairBet, continuePendingBet });
  }

  window.JLBetActions = Object.freeze({ create });
})();