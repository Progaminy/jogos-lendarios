(() => {
  'use strict';

  const parseMoney = (value) => Number(String(value || '').replace(/\./g, '').replace(',', '.'));
  const formatMoney = (value) => Number(value || 0).toLocaleString('pt-MZ', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });

  function enforceMinimums() {
    const inputs = [
      document.getElementById('createBet'),
      document.getElementById('queueBet'),
      document.querySelector('input[name="reentry_amount"]')
    ].filter(Boolean);

    for (const input of inputs) {
      input.min = '10';
      if (!input.value || Number(input.value) < 10) input.value = '10';
    }
  }

  function normalizeCommissionPreview() {
    const el = document.getElementById('roomPrize');
    if (!el) return;
    const text = el.textContent || '';
    if (!text.includes('comissão')) return;

    const grossMatch = text.match(/(?:Vencedor:|Dupla vencedora:)\s*([\d.,]+)\s*MZN/);
    if (!grossMatch) return;

    const gross = parseMoney(grossMatch[1]);
    if (!Number.isFinite(gross) || gross <= 0) return;

    const commission = Math.min(gross, Math.max(1, Math.ceil(gross * 0.01)));
    const net = gross - commission;
    const next = text.startsWith('Dupla vencedora:')
      ? `Dupla vencedora: ${formatMoney(gross)} MZN brutos por parceiro · comissão ${formatMoney(commission)} MZN por parceiro · ${formatMoney(net)} MZN líquidos cada.`
      : `Vencedor: ${formatMoney(gross)} MZN brutos · comissão ${formatMoney(commission)} MZN · ${formatMoney(net)} MZN líquidos.`;

    if (el.textContent !== next) el.textContent = next;
  }

  document.addEventListener('DOMContentLoaded', () => {
    enforceMinimums();
    normalizeCommissionPreview();

    const prize = document.getElementById('roomPrize');
    if (prize) {
      new MutationObserver(normalizeCommissionPreview).observe(prize, {
        childList: true,
        characterData: true,
        subtree: true
      });
    }
  });
})();
