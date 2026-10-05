(() => {
  'use strict';

  const qs = (s, root = document) => root.querySelector(s);
  const qsa = (s, root = document) => [...root.querySelectorAll(s)];
  const path = String(location.pathname || '').toLowerCase();
  const params = new URL(location.href).searchParams;
  const isFreeMode = params.get('mode') === 'free';
  const isBoard = path.endsWith('/tabuleiro.html');
  const isLudo = path.endsWith('/ludo.html');
  const isDama = path.endsWith('/dama.html');
  const token = () => window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  const rpc = (name, args = {}) => window.JLApi?.rpc?.(name, args);
  let freeStatus = null;
  let currentGameHref = '';

  function money(v) {
    return Number(v || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  }

  function addStyle() {
    if (qs('#jlFreeAccessStyle')) return;
    const style = document.createElement('style');
    style.id = 'jlFreeAccessStyle';
    style.textContent = `
      .jl-free-account{border-color:#38d179!important;color:#9ff0bd!important}
      .jl-free-modal{position:fixed;inset:0;z-index:10000;display:grid;place-items:center;padding:18px;background:rgba(0,0,0,.72);backdrop-filter:blur(8px)}
      .jl-free-modal.hidden{display:none!important}
      .jl-free-card{width:min(430px,100%);padding:20px;border:1px solid rgba(255,255,255,.12);border-radius:20px;background:#0c1420;box-shadow:0 24px 70px rgba(0,0,0,.48)}
      .jl-free-card h2{margin:0 0 14px;font-size:1.2rem}
      .jl-free-choice{display:grid;grid-template-columns:1fr 1fr;gap:10px}
      .jl-free-choice .button{width:100%;justify-content:center;min-height:48px}
      .jl-free-access-box{display:grid;gap:10px;margin-top:12px;padding-top:12px;border-top:1px solid rgba(255,255,255,.08)}
      .jl-free-access-state{font-size:.84rem;color:#aebcd0}
      .jl-free-access-state.success{color:#85e3a8}
      .jl-free-access-state.warning{color:#ffd66b}
      .jl-free-access-state.error{color:#ff929c}
      .jl-free-close{margin-top:12px;width:100%}
      .jl-free-mode-badge{display:inline-flex;align-items:center;justify-content:center;padding:5px 10px;border-radius:999px;border:1px solid #38d179;color:#8fe9b0;font-weight:900;font-size:.72rem;letter-spacing:.08em}
      html.jl-free-mode .jl-free-bet-hidden{display:none!important}
      @media(max-width:520px){.jl-free-card{padding:16px}.jl-free-choice{grid-template-columns:1fr}}
    `;
    document.head.appendChild(style);
  }

  function injectAccountButton() {
    const actions = qs('.account-menu-actions');
    if (!actions || qs('#accountMenuFree', actions)) return;
    const button = document.createElement('button');
    button.id = 'accountMenuFree';
    button.className = 'button ghost small jl-free-account';
    button.type = 'button';
    button.textContent = 'FREE';
    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      location.href = './tabuleiro.html#free';
    });
    actions.prepend(button);
  }

  function observeHeader() {
    injectAccountButton();
    const observer = new MutationObserver(injectAccountButton);
    observer.observe(document.documentElement, { subtree: true, childList: true });
  }

  function ensureModal() {
    let modal = qs('#jlFreeModal');
    if (modal) return modal;
    modal = document.createElement('div');
    modal.id = 'jlFreeModal';
    modal.className = 'jl-free-modal hidden';
    modal.innerHTML = `
      <div class="jl-free-card" role="dialog" aria-modal="true" aria-labelledby="jlFreeTitle">
        <h2 id="jlFreeTitle">Jogar</h2>
        <div id="jlFreeGameChoices" class="jl-free-choice">
          <button id="jlFreeBetMode" class="button primary" type="button">APOSTAS</button>
          <button id="jlFreeFreeMode" class="button success" type="button">FREE</button>
        </div>
        <div id="jlFreeAccessBox" class="jl-free-access-box hidden">
          <strong id="jlFreePrice">FREE</strong>
          <div id="jlFreeAccessState" class="jl-free-access-state"></div>
          <button id="jlFreePay" class="button success" type="button">Pagar</button>
          <a id="jlFreeDeposit" class="button secondary hidden" href="./index.html?open=deposit&from=free#depositPanel">Depósito</a>
        </div>
        <button id="jlFreeClose" class="button ghost jl-free-close" type="button">Fechar</button>
      </div>`;
    document.body.appendChild(modal);

    qs('#jlFreeClose', modal).addEventListener('click', () => closeModal());
    modal.addEventListener('click', (event) => { if (event.target === modal) closeModal(); });
    qs('#jlFreeBetMode', modal).addEventListener('click', () => {
      if (!currentGameHref) return;
      const url = new URL(currentGameHref, location.href);
      url.searchParams.delete('mode');
      location.href = url.href;
    });
    qs('#jlFreeFreeMode', modal).addEventListener('click', async () => {
      if (!currentGameHref) return showAccessOnly();
      await chooseFreeGame();
    });
    qs('#jlFreePay', modal).addEventListener('click', requestFree);
    return modal;
  }

  function closeModal() {
    qs('#jlFreeModal')?.classList.add('hidden');
    if (location.hash === '#free') history.replaceState(null, '', location.pathname + location.search);
  }

  function setAccessState(text, type = '') {
    const el = qs('#jlFreeAccessState');
    if (!el) return;
    el.textContent = text || '';
    el.className = `jl-free-access-state ${type}`.trim();
  }

  function showAccessBox(show = true) {
    qs('#jlFreeAccessBox')?.classList.toggle('hidden', !show);
  }

  async function loadFreeStatus(silent = false) {
    const t = token();
    if (!t || !rpc) {
      freeStatus = null;
      if (!silent) setAccessState('Entre na conta.', 'warning');
      return null;
    }
    try {
      freeStatus = await rpc('jl_free_access_status', { p_token: t });
      return freeStatus;
    } catch (error) {
      freeStatus = null;
      if (!silent) setAccessState(error?.message || 'FREE indisponível.', 'error');
      return null;
    }
  }

  function renderAccess(status) {
    showAccessBox(true);
    const price = qs('#jlFreePrice');
    const pay = qs('#jlFreePay');
    const deposit = qs('#jlFreeDeposit');
    if (price) price.textContent = status ? `${money(status.price)} MZN` : 'FREE';
    deposit?.classList.add('hidden');

    if (!token()) {
      setAccessState('Entre na conta.', 'warning');
      if (pay) { pay.disabled = false; pay.textContent = 'Entrar'; }
      return;
    }
    if (!status) {
      setAccessState('FREE indisponível.', 'error');
      if (pay) pay.disabled = true;
      return;
    }
    if (status.enabled === false) {
      setAccessState('FREE desativado.', 'warning');
      if (pay) pay.disabled = true;
      return;
    }
    if (status.active) {
      setAccessState('FREE ATIVO', 'success');
      if (pay) { pay.disabled = true; pay.textContent = 'ATIVO'; }
      return;
    }
    if (status.status === 'pending') {
      setAccessState('Aguardando aprovação.', 'warning');
      if (pay) { pay.disabled = true; pay.textContent = 'PENDENTE'; }
      return;
    }
    setAccessState('Pagamento + aprovação.', '');
    if (pay) { pay.disabled = false; pay.textContent = `Pagar ${money(status.price)} MZN`; }
  }

  async function requestFree() {
    if (!token()) {
      location.href = './index.html#login';
      return;
    }
    const pay = qs('#jlFreePay');
    if (pay) pay.disabled = true;
    try {
      const status = await rpc('jl_free_access_request', { p_token: token() });
      freeStatus = status;
      renderAccess(status);
    } catch (error) {
      const message = String(error?.message || 'Não foi possível pagar.');
      setAccessState(message, 'error');
      if (/saldo insuficiente/i.test(message)) qs('#jlFreeDeposit')?.classList.remove('hidden');
      if (pay) pay.disabled = false;
    }
  }

  async function chooseFreeGame() {
    const status = await loadFreeStatus();
    if (!status) return renderAccess(status);
    if (status.active) {
      const url = new URL(currentGameHref, location.href);
      url.searchParams.set('mode', 'free');
      location.href = url.href;
      return;
    }
    renderAccess(status);
  }

  async function openGameModal(anchor) {
    const modal = ensureModal();
    currentGameHref = anchor?.href || '';
    const title = anchor?.closest('.board-game-card')?.querySelector('h2')?.textContent?.trim() || 'Jogar';
    qs('#jlFreeTitle', modal).textContent = title;
    qs('#jlFreeGameChoices', modal)?.classList.remove('hidden');
    showAccessBox(false);
    modal.classList.remove('hidden');
    await loadFreeStatus(true);
  }

  async function showAccessOnly() {
    const modal = ensureModal();
    currentGameHref = '';
    qs('#jlFreeTitle', modal).textContent = 'FREE';
    qs('#jlFreeGameChoices', modal)?.classList.add('hidden');
    modal.classList.remove('hidden');
    const status = await loadFreeStatus();
    renderAccess(status);
  }

  function installBoardChooser() {
    document.addEventListener('click', (event) => {
      const anchor = event.target.closest?.('.board-game-preview[href*="ludo.html"],.board-game-preview[href*="dama.html"]');
      if (!anchor) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      void openGameModal(anchor);
    }, true);
    if (location.hash === '#free') setTimeout(() => void showAccessOnly(), 0);
  }

  function addFreeBadge() {
    if (!isFreeMode || qs('#jlFreeModeBadge')) return;
    const badge = document.createElement('span');
    badge.id = 'jlFreeModeBadge';
    badge.className = 'jl-free-mode-badge';
    badge.textContent = 'FREE';
    const target = qs('.product-tag') || qs('.hero .eyebrow') || qs('.dama-lobby-head .eyebrow') || qs('.topbar .brand');
    target?.insertAdjacentElement('afterend', badge);
  }

  function hideFreeBetControls() {
    if (!isFreeMode) return;
    document.documentElement.classList.add('jl-free-mode');
    const ids = isLudo
      ? ['createBet','queueForm','queueBet','rematchBet','stakeProposalAmount','stakeProposalSend']
      : isDama
        ? ['damaBet','damaRematchBet']
        : [];
    ids.forEach((id) => {
      const el = document.getElementById(id);
      if (!el) return;
      const holder = el.closest('.quick-start-step,label,.field,form#queueForm') || el;
      holder.classList.add('jl-free-bet-hidden');
    });
    if (isLudo) {
      const queue = document.getElementById('queueForm');
      queue?.closest('.panel,.card')?.classList.add('jl-free-bet-hidden');
    }
  }

  function replaceZeroMoney(root = document) {
    if (!isFreeMode) return;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach((node) => {
      if (!node.nodeValue || !/0(?:[,.]00)?\s*MZN/i.test(node.nodeValue)) return;
      node.nodeValue = node.nodeValue.replace(/0(?:[,.]00)?\s*MZN/gi, 'FREE');
    });
  }

  async function guardFreePage() {
    if (!isFreeMode || (!isLudo && !isDama) || !token()) return;
    const status = await loadFreeStatus(true);
    if (status && !status.active) location.replace('./tabuleiro.html#free');
  }

  function installFreeModeUi() {
    if (!isFreeMode || (!isLudo && !isDama)) return;
    addFreeBadge();
    hideFreeBetControls();
    replaceZeroMoney(document.body);
    const observer = new MutationObserver((records) => {
      hideFreeBetControls();
      addFreeBadge();
      for (const record of records) {
        for (const node of record.addedNodes) if (node.nodeType === 1) replaceZeroMoney(node);
      }
    });
    observer.observe(document.body, { subtree: true, childList: true });
    void guardFreePage();
  }

  function init() {
    addStyle();
    observeHeader();
    ensureModal();
    if (isBoard) installBoardChooser();
    installFreeModeUi();
  }

  window.addEventListener('jl-player-session-changed', () => {
    injectAccountButton();
    if (isFreeMode) void guardFreePage();
    if (isBoard && location.hash === '#free') void showAccessOnly();
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, { once: true });
  else init();
})();
