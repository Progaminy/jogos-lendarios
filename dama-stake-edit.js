(() => {
  'use strict';

  if (!String(location.pathname || '').toLowerCase().endsWith('/dama.html')) return;

  function parseMoney(text) {
    const raw = String(text || '')
      .replace(/[^0-9,.-]/g, '')
      .replace(/\./g, '')
      .replace(',', '.');
    const value = Number(raw);
    return Number.isFinite(value) ? value : 0;
  }

  function currentBet() {
    const fundText = document.getElementById('damaFund')?.textContent || '';
    return parseMoney(fundText.replace(/^Confirmar\s*/i, ''));
  }

  function isHostUi() {
    const cards = [...document.querySelectorAll('#damaPlayers .dama-player')];
    return Boolean(cards[0] && /\bvocê\b/i.test(cards[0].textContent || ''));
  }

  function installStyle() {
    if (document.getElementById('damaStakeEditStyle')) return;
    const style = document.createElement('style');
    style.id = 'damaStakeEditStyle';
    style.textContent = `
      #damaStakeModalValue.dama-flow-value{
        display:flex;
        align-items:center;
        justify-content:center;
        gap:8px;
      }
      #damaStakeModalInput{
        width:min(180px,60vw);
        border:0;
        outline:0;
        background:transparent;
        color:inherit;
        font:inherit;
        font-weight:900;
        text-align:center;
      }
      #damaStakeModalInput:not([readonly]){
        border-bottom:2px solid currentColor;
      }
      #damaStakeModalInput[readonly]{
        cursor:default;
      }
      .dama-stake-currency{font-size:.72em;white-space:nowrap}
    `;
    document.head.appendChild(style);
  }

  function ensureInput() {
    const holder = document.getElementById('damaStakeModalValue');
    if (!holder) return null;

    let input = document.getElementById('damaStakeModalInput');
    if (!input) {
      holder.textContent = '';
      input = document.createElement('input');
      input.id = 'damaStakeModalInput';
      input.type = 'number';
      input.min = '10';
      input.step = '1';
      input.inputMode = 'numeric';
      input.autocomplete = 'off';
      input.setAttribute('aria-label', 'Valor da aposta');

      const currency = document.createElement('span');
      currency.className = 'dama-stake-currency';
      currency.textContent = 'MZN';

      holder.append(input, currency);
    }
    return input;
  }

  function sync() {
    installStyle();
    const input = ensureInput();
    if (!input) return;

    const host = isHostUi();
    input.readOnly = !host;
    input.setAttribute('aria-readonly', String(!host));

    const bet = currentBet();
    if (bet <= 0) return;

    const normalized = String(Math.trunc(bet));
    if (document.activeElement !== input && input.dataset.roomValue !== normalized) {
      input.value = normalized;
      input.dataset.originalValue = normalized;
      input.dataset.roomValue = normalized;
    }
  }

  const observer = new MutationObserver(sync);
  observer.observe(document.documentElement, {
    subtree: true,
    childList: true,
    characterData: true,
    attributes: true,
    attributeFilter: ['class']
  });

  sync();
})();
