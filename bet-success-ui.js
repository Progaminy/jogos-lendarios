(() => {
  'use strict';
  if (window.__JL_BET_SUCCESS_UI__) return;
  window.__JL_BET_SUCCESS_UI__ = true;

  function money(value) {
    return Number(value || 0).toLocaleString('pt-MZ', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    });
  }

  function injectStyles() {
    if (document.getElementById('jlBetSuccessStyles')) return;
    const style = document.createElement('style');
    style.id = 'jlBetSuccessStyles';
    style.textContent = `
      .toast.bet-success-strong {
        top: 50% !important;
        width: min(540px, calc(100% - 28px)) !important;
        max-width: 540px !important;
        padding: 22px 24px !important;
        border: 2px solid #68e7a1 !important;
        border-radius: 22px !important;
        background: linear-gradient(145deg, #123322, #0b2318) !important;
        color: #effff5 !important;
        box-shadow: 0 28px 90px rgba(0,0,0,.58), 0 0 0 7px rgba(78,213,138,.12) !important;
        transform: translate(-50%, -50%) scale(.92) !important;
        text-align: left !important;
        opacity: 0 !important;
        pointer-events: none !important;
      }
      .toast.bet-success-strong.show {
        opacity: 1 !important;
        transform: translate(-50%, -50%) scale(1) !important;
        animation: jlBetSuccessPop .32s ease-out;
      }
      .jl-bet-success-box {
        display: grid;
        grid-template-columns: 62px minmax(0,1fr);
        gap: 16px;
        align-items: center;
      }
      .jl-bet-success-icon {
        width: 62px;
        height: 62px;
        display: grid;
        place-items: center;
        border-radius: 50%;
        background: #4ed58a;
        color: #062414;
        font-size: 2rem;
        font-weight: 1000;
        box-shadow: 0 10px 28px rgba(78,213,138,.28);
      }
      .jl-bet-success-title {
        display: block;
        margin: 0 0 6px;
        color: #a9f6ca;
        font-size: clamp(1rem, 4vw, 1.28rem);
        font-weight: 1000;
        letter-spacing: .035em;
      }
      .jl-bet-success-detail {
        display: block;
        color: #ffffff;
        font-size: clamp(1.15rem, 5vw, 1.6rem);
        font-weight: 950;
        line-height: 1.25;
      }
      .jl-bet-success-note {
        display: block;
        margin-top: 6px;
        color: #b9d8c6;
        font-size: .82rem;
        font-weight: 700;
      }
      @keyframes jlBetSuccessPop {
        0% { transform: translate(-50%, -50%) scale(.78); opacity: 0; }
        70% { transform: translate(-50%, -50%) scale(1.035); opacity: 1; }
        100% { transform: translate(-50%, -50%) scale(1); opacity: 1; }
      }
      @media (max-width: 520px) {
        .toast.bet-success-strong { padding: 19px 18px !important; }
        .jl-bet-success-box { grid-template-columns: 52px minmax(0,1fr); gap: 13px; }
        .jl-bet-success-icon { width: 52px; height: 52px; font-size: 1.65rem; }
      }
    `;
    document.head.appendChild(style);
  }

  function upgradeToast(toast) {
    if (!toast) return;
    if (!toast.classList.contains('show') || !toast.classList.contains('success')) {
      delete toast.dataset.jlBetSuccessSignature;
      return;
    }
    if (toast.classList.contains('bet-success-strong') && toast.dataset.jlBetSuccessSignature) return;

    const raw = (toast.textContent || '').trim();
    let title = '';
    let detail = '';
    let signature = '';

    const numberMatch = raw.match(/^Número Lendário:\s*aposta\s*(\d+)\s*confirmada\.?$/i);
    if (numberMatch) {
      const amount = document.getElementById('betAmount')?.value;
      title = 'APOSTA REALIZADA COM SUCESSO';
      detail = `Número ${numberMatch[1]} · ${money(amount)} MZN`;
      signature = `number:${numberMatch[1]}:${amount}`;
    }

    const pairMatch = raw.match(/^Dupla Lendária:\s*(\d+)\+(\d+)\s*confirmada\.?$/i);
    if (!signature && pairMatch) {
      const amount = document.getElementById('pairBetAmount')?.value;
      title = 'APOSTA REALIZADA COM SUCESSO';
      detail = `Números ${pairMatch[1]} + ${pairMatch[2]} · ${money(amount)} MZN`;
      signature = `pair:${pairMatch[1]}:${pairMatch[2]}:${amount}`;
    }

    if (!signature) return;
    toast.dataset.jlBetSuccessSignature = signature;
    toast.classList.add('bet-success-strong');
    toast.innerHTML = '';

    const box = document.createElement('div');
    box.className = 'jl-bet-success-box';
    const icon = document.createElement('span');
    icon.className = 'jl-bet-success-icon';
    icon.textContent = '✓';
    const copy = document.createElement('div');
    const strong = document.createElement('strong');
    strong.className = 'jl-bet-success-title';
    strong.textContent = title;
    const value = document.createElement('span');
    value.className = 'jl-bet-success-detail';
    value.textContent = detail;
    const note = document.createElement('small');
    note.className = 'jl-bet-success-note';
    note.textContent = 'A aposta foi registrada e já aparece no seu histórico.';
    copy.append(strong, value, note);
    box.append(icon, copy);
    toast.appendChild(box);
  }

  function init() {
    const toast = document.getElementById('toast');
    if (!toast) return;
    injectStyles();
    upgradeToast(toast);
    new MutationObserver(() => upgradeToast(toast)).observe(toast, {
      childList: true,
      characterData: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class']
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, { once: true });
  else init();
})();
