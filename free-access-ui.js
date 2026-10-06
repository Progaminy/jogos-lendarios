(() => {
  'use strict';

  const $ = (s, r = document) => r.querySelector(s);
  const path = String(location.pathname || '').toLowerCase().replace(/\\/+$/, '');
  const page = path.split('/').pop()?.replace(/\.html$/, '') || '';
  const query = new URL(location.href).searchParams;
  // The production site rewrites *.html routes to extensionless paths
  // (/tabuleiro, /ludo, /dama). Accept both forms so the FREE interceptor
  // is installed on the real published URL as well as the source URL.
  const board = page === 'tabuleiro';
  const ludo = page === 'ludo';
  const dama = page === 'dama';
  const freeMode = query.get('mode') === 'free';
  const gameKey = ludo ? 'ludo' : dama ? 'dama' : '';
  const token = () => window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  const rpc = (name, args = {}) => window.JLApi?.rpc?.(name, args);

  let status = null;
  let catalog = null;
  let gameHref = '';
  let selectedGame = '';

  const money = (v) => Number(v || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  const date = (v) => {
    if (!v) return '';
    const d = new Date(v);
    return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString('pt-MZ');
  };

  function keyFromHref(href, node = null) {
    const dataKey = node?.dataset?.gameKey || node?.closest?.('[data-game-key]')?.dataset?.gameKey;
    if (dataKey) return String(dataKey).trim().toLowerCase();
    try {
      const p = new URL(href, location.href).pathname.toLowerCase();
      const name = p.split('/').pop()?.replace(/\.html$/, '') || '';
      return name.replace(/[^a-z0-9_-]/g, '');
    } catch {
      return '';
    }
  }

  function gameState(s, key) {
    return (s?.games || []).find((g) => g.game_key === key) || null;
  }

  function addStyle() {
    if ($('#jlFreeAccessStyle')) return;
    const s = document.createElement('style');
    s.id = 'jlFreeAccessStyle';
    s.textContent = `
      .jl-free-account{border-color:rgba(219,174,76,.72)!important;color:#f0cd7b!important}
      .jl-free-modal{position:fixed;inset:0;z-index:10000;display:grid;place-items:center;padding:18px;background:rgba(2,7,13,.76);backdrop-filter:blur(7px)}
      .jl-free-modal.hidden{display:none!important}
      .jl-free-card{width:min(420px,100%);padding:18px;border:1px solid rgba(219,174,76,.34);border-radius:18px;background:#0b1420;box-shadow:0 22px 65px rgba(0,0,0,.46)}
      .jl-free-card h2{margin:0 0 14px;font-size:1.08rem}
      .jl-free-choice{display:grid;grid-template-columns:1fr 1fr;gap:10px}
      .jl-free-choice .button{width:100%;justify-content:center;min-height:48px;border-color:rgba(219,174,76,.42)}
      .jl-free-choice #jlFreeMode{background:rgba(219,174,76,.11);color:#f2d38d}
      .jl-free-choice #jlFreeBet{background:#121d2a;color:#f6f8fb}
      .jl-free-access{display:grid;gap:10px;margin-top:12px;padding-top:12px;border-top:1px solid rgba(219,174,76,.2)}
      .jl-free-access.hidden{display:none!important}
      .jl-free-state{min-height:20px;font-size:.82rem;color:#aebcd0}
      .jl-free-state.success{color:#8be1aa}.jl-free-state.warning{color:#f2cf78}.jl-free-state.error{color:#ff959d}
      .jl-free-months{display:grid;grid-template-columns:42px 1fr 42px;gap:8px;align-items:center}
      .jl-free-months button,.jl-free-months input{min-height:42px;border:1px solid rgba(219,174,76,.28);border-radius:10px;background:#101b28;color:#f4f6f8;text-align:center}
      .jl-free-months input{width:100%;font-weight:800}
      .jl-free-price{text-align:center;font-weight:900;color:#f0cd7b}
      .jl-free-close{margin-top:10px;width:100%}
      .jl-free-mode-badge{display:inline-flex;align-items:center;justify-content:center;padding:5px 10px;border-radius:999px;border:1px solid rgba(219,174,76,.55);color:#f0cd7b;font-weight:900;font-size:.7rem;letter-spacing:.08em}
      .jl-free-manage{display:inline-flex;align-items:center;justify-content:center;min-height:34px;padding:6px 11px;border:1px solid rgba(219,174,76,.44);border-radius:10px;background:rgba(219,174,76,.08);color:#f0cd7b;font-weight:900;cursor:pointer}
      html.jl-free-mode .quick-start-step:has(#createBet),
      html.jl-free-mode form#queueForm,
      html.jl-free-mode label:has(#rematchBet),
      html.jl-free-mode label:has(#damaBet),
      html.jl-free-mode label:has(#damaRematchBet),
      html.jl-free-mode #rulesForm label:has([name="reentry_amount"]),
      html.jl-free-mode #rulesForm label.toggle:has([name="reentry_allowed"]),
      html.jl-free-mode #capturePenaltyField,
      html.jl-free-mode #stakeProposalAmount,
      html.jl-free-mode #stakeProposalSend{display:none!important}
      @media(max-width:520px){.jl-free-card{padding:15px}.jl-free-choice{grid-template-columns:1fr 1fr}}
    `;
    document.head.appendChild(s);
  }

  function injectAccountButton() {
    const actions = $('.account-menu-actions');
    if (!actions || $('#accountMenuFree', actions)) return false;
    const b = document.createElement('button');
    b.id = 'accountMenuFree';
    b.className = 'button ghost small jl-free-account';
    b.type = 'button';
    b.textContent = 'FREE';
    b.onclick = (e) => {
      e.preventDefault();
      e.stopPropagation();
      location.href = './tabuleiro.html?mode=free';
    };
    actions.prepend(b);
    return true;
  }

  function watchAccountButton() {
    if (injectAccountButton()) return;
    const observer = new MutationObserver(() => {
      if (injectAccountButton()) observer.disconnect();
    });
    observer.observe(document.documentElement, { subtree: true, childList: true });
    setTimeout(() => observer.disconnect(), 5000);
  }

  function ensureModal() {
    let m = $('#jlFreeModal');
    if (m) return m;
    m = document.createElement('div');
    m.id = 'jlFreeModal';
    m.className = 'jl-free-modal hidden';
    m.innerHTML = `
      <div class="jl-free-card" role="dialog" aria-modal="true" aria-labelledby="jlFreeTitle">
        <h2 id="jlFreeTitle">Jogar</h2>
        <div id="jlFreeChoices" class="jl-free-choice">
          <button id="jlFreeMode" class="button" type="button">FREE</button>
          <button id="jlFreeBet" class="button" type="button">APOSTAS</button>
        </div>
        <div id="jlFreeAccess" class="jl-free-access hidden">
          <div id="jlFreeState" class="jl-free-state"></div>
          <div class="jl-free-months">
            <button id="jlFreeMonthsMinus" type="button" aria-label="Menos um período">−</button>
            <input id="jlFreeMonths" type="number" min="1" max="120" step="1" value="1" inputmode="numeric" aria-label="Quantidade de períodos">
            <button id="jlFreeMonthsPlus" type="button" aria-label="Mais um período">+</button>
          </div>
          <div id="jlFreePrice" class="jl-free-price">—</div>
          <button id="jlFreePay" class="button primary" type="button">Pagar</button>
          <a id="jlFreeDeposit" class="button secondary hidden" href="./index.html?open=deposit&from=free#depositPanel">Depósito</a>
        </div>
        <button id="jlFreeClose" class="button ghost jl-free-close" type="button">Fechar</button>
      </div>`;
    document.body.appendChild(m);

    $('#jlFreeClose', m).onclick = closeModal;
    m.onclick = (e) => { if (e.target === m) closeModal(); };
    $('#jlFreeBet', m).onclick = () => {
      if (!gameHref) return;
      const u = new URL(gameHref, location.href);
      u.searchParams.delete('mode');
      u.searchParams.delete('pay');
      location.href = u.href;
    };
    $('#jlFreeMode', m).onclick = () => { if (gameHref) void chooseFree(); };
    $('#jlFreePay', m).onclick = () => void pay();
    $('#jlFreeMonthsMinus', m).onclick = () => changeMonths(-1);
    $('#jlFreeMonthsPlus', m).onclick = () => changeMonths(1);
    $('#jlFreeMonths', m).oninput = updatePrice;
    return m;
  }

  function closeModal() {
    $('#jlFreeModal')?.classList.add('hidden');
  }

  function setState(text, type = '') {
    const e = $('#jlFreeState');
    if (!e) return;
    e.textContent = text || '';
    e.className = `jl-free-state ${type}`.trim();
  }

  function showAccess(show = true) {
    $('#jlFreeAccess')?.classList.toggle('hidden', !show);
  }

  function months() {
    const input = $('#jlFreeMonths');
    const value = Math.max(1, Math.min(120, Math.trunc(Number(input?.value) || 1)));
    if (input) input.value = String(value);
    return value;
  }

  function changeMonths(delta) {
    const input = $('#jlFreeMonths');
    if (!input) return;
    input.value = String(Math.max(1, Math.min(120, months() + delta)));
    updatePrice();
  }

  function updatePrice() {
    const price = Number(status?.price || 0);
    const n = months();
    const unit = status?.price_period === 'day' ? 'dia' : 'mês';
    const e = $('#jlFreePrice');
    if (e) e.textContent = `${n} ${n === 1 ? unit : unit === 'dia' ? 'dias' : 'meses'} · ${money(price * n)} MZN`;
  }

  async function loadStatus(silent = false) {
    if (!token() || !rpc) {
      status = null;
      if (!silent) setState('Entrar', 'warning');
      return null;
    }
    try {
      status = await rpc('jl_free_access_status', { p_token: token() });
      return status;
    } catch (e) {
      status = null;
      if (!silent) setState(e?.message || 'FREE indisponível.', 'error');
      return null;
    }
  }

  async function loadCatalog() {
    if (catalog) return catalog;
    try {
      catalog = await rpc('jl_free_catalog', {});
    } catch {
      catalog = [];
    }
    return catalog;
  }

  function renderAccess(s, key = '') {
    showAccess(true);
    const payBtn = $('#jlFreePay');
    const dep = $('#jlFreeDeposit');
    dep?.classList.add('hidden');
    updatePrice();

    if (!token()) {
      setState('Entrar', 'warning');
      if (payBtn) { payBtn.disabled = false; payBtn.textContent = 'Entrar'; }
      return;
    }
    if (!s || s.enabled === false) {
      setState('FREE indisponível.', 'warning');
      if (payBtn) payBtn.disabled = true;
      return;
    }
    if (s.status === 'pending') {
      const pendingUnit = s.pending_period_unit === 'day' ? 'dia' : 'mês';
      const pendingCount = Number(s.pending_periods || s.pending_months || 1);
      setState(`Pendente · ${pendingCount} ${pendingCount === 1 ? pendingUnit : pendingUnit === 'dia' ? 'dias' : 'meses'}`, 'warning');
      if (payBtn) { payBtn.disabled = true; payBtn.textContent = 'PENDENTE'; }
      return;
    }

    const g = key ? gameState(s, key) : null;
    if (s.active) {
      const until = date(s.valid_until);
      setState(until ? `Ativo até ${until}` : 'ATIVO', 'success');
    } else if (g) {
      setState(`${g.remaining_trials || 0}/${g.trial_limit || 0} FREE`, g.remaining_trials > 0 ? 'success' : 'warning');
    } else {
      setState('FREE', 'success');
    }
    if (payBtn) { payBtn.disabled = false; payBtn.textContent = 'Pagar'; }
  }

  async function pay() {
    if (!token()) {
      location.href = './index.html#login';
      return;
    }
    const b = $('#jlFreePay');
    if (b) b.disabled = true;
    try {
      status = await rpc('jl_free_access_request', { p_token: token(), p_months: months() });
      renderAccess(status, selectedGame);
    } catch (e) {
      const msg = String(e?.message || 'Não foi possível pagar.');
      setState(msg, 'error');
      if (/saldo insuficiente/i.test(msg)) $('#jlFreeDeposit')?.classList.remove('hidden');
      if (b) b.disabled = false;
    }
  }

  async function chooseFree() {
    if (!token()) {
      location.href = './index.html#login';
      return;
    }
    const s = await loadStatus();
    if (!s) return renderAccess(s, selectedGame);
    const g = gameState(s, selectedGame);
    if (g?.eligible) {
      const u = new URL(gameHref, location.href);
      u.searchParams.set('mode', 'free');
      u.searchParams.delete('pay');
      location.href = u.href;
      return;
    }
    renderAccess(s, selectedGame);
  }

  async function openChooser(anchor, cfg = null) {
    const m = ensureModal();
    gameHref = anchor?.href || '';
    selectedGame = keyFromHref(gameHref, anchor);
    const card = anchor?.closest('.board-game-card');
    $('#jlFreeTitle', m).textContent = card?.querySelector('h2')?.textContent?.trim() || cfg?.label || 'Jogar';
    const choices = $('#jlFreeChoices', m);
    choices?.classList.remove('hidden');
    $('#jlFreeMode', m)?.classList.toggle('hidden', cfg?.free_enabled === false);
    $('#jlFreeBet', m)?.classList.toggle('hidden', cfg?.bet_enabled === false);
    showAccess(false);
    m.classList.remove('hidden');
  }

  async function openAccess(key = '') {
    const m = ensureModal();
    selectedGame = key || '';
    gameHref = '';
    $('#jlFreeTitle', m).textContent = 'FREE';
    $('#jlFreeChoices', m)?.classList.add('hidden');
    m.classList.remove('hidden');
    renderAccess(await loadStatus(), selectedGame);
  }

  async function directFree(anchor, key) {
    if (!token()) {
      location.href = './index.html#login';
      return;
    }
    selectedGame = key;
    gameHref = anchor.href;
    const s = await loadStatus(true);
    const g = gameState(s, key);
    if (g?.eligible) {
      const u = new URL(anchor.href, location.href);
      u.searchParams.set('mode', 'free');
      location.href = u.href;
      return;
    }
    await openAccess(key);
  }

  function boardClick(anchor) {
    const key = keyFromHref(anchor.href, anchor);
    if (!key) return;

    // FREE hub keeps its direct-entry behaviour; normal board opens the
    // choice immediately, without waiting for a network/RPC response.
    if (freeMode) {
      void loadCatalog().then((list) => {
        const cfg = (Array.isArray(list) ? list : list?.games || [])
          .find((g) => g.game_key === key);
        if (cfg?.free_enabled) void directFree(anchor, key);
      });
      return;
    }

    void openChooser(anchor, { free_enabled: true, bet_enabled: true });
    void loadCatalog().then((list) => {
      const cfg = (Array.isArray(list) ? list : list?.games || [])
        .find((g) => g.game_key === key);
      if (!cfg) return;
      const modal = $('#jlFreeModal');
      if (!modal || modal.classList.contains('hidden') || selectedGame !== key) return;
      $('#jlFreeMode', modal)?.classList.toggle('hidden', cfg.free_enabled === false);
      $('#jlFreeBet', modal)?.classList.toggle('hidden', cfg.bet_enabled === false);
      if (cfg.free_enabled && !cfg.bet_enabled) void directFree(anchor, key);
    });
  }

  function installBoard() {
    // Bind directly to the game cards as a second, more reliable interception
    // layer. This prevents the anchor's native href from winning the race
    // before the FREE/APOSTAS chooser is opened.
    const bindGameCards = () => {
      document.querySelectorAll('.board-game-preview[href]').forEach((a) => {
        if (a.dataset.jlFreeBound === '1') return;
        a.dataset.jlFreeBound = '1';
        a.onclick = (e) => {
          e.preventDefault();
          e.stopImmediatePropagation();
          void boardClick(a);
          return false;
        };
      });
    };
    bindGameCards();

    // Capture at window level as the first reliable interception layer.
    // Some page scripts can stop propagation before a document listener runs.
    window.addEventListener('click', (e) => {
      const a = e.target?.closest?.('.board-game-preview[href]');
      if (!a) return;
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      void boardClick(a);
    }, true);

    document.addEventListener('click', (e) => {
      const a = e.target.closest?.('.board-game-preview[href]');
      if (!a) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      void boardClick(a);
    }, true);

    if (freeMode) {
      const head = $('.board-hub-head');
      if (head && !$('#jlFreeManage')) {
        const b = document.createElement('button');
        b.id = 'jlFreeManage';
        b.className = 'jl-free-manage';
        b.type = 'button';
        b.textContent = 'FREE +';
        b.onclick = () => void openAccess(query.get('game') || '');
        head.appendChild(b);
      }
      void filterFreeCards();
      if (query.get('pay') === '1') setTimeout(() => void openAccess(query.get('game') || ''), 0);
    }
  }

  async function filterFreeCards() {
    const list = await loadCatalog();
    for (const card of document.querySelectorAll('.board-game-card')) {
      const a = $('.board-game-preview[href]', card);
      if (!a) continue;
      const key = keyFromHref(a.href, a);
      const cfg = list.find((g) => g.game_key === key);
      card.classList.toggle('hidden', !cfg?.free_enabled);
    }
  }

  function badge() {
    if (!freeMode || $('#jlFreeModeBadge')) return;
    const b = document.createElement('span');
    b.id = 'jlFreeModeBadge';
    b.className = 'jl-free-mode-badge';
    b.textContent = 'FREE';
    const t = $('.product-tag') || $('.hero .eyebrow') || $('.dama-lobby-head .eyebrow') || $('.topbar .brand');
    t?.insertAdjacentElement('afterend', b);
  }

  async function guardFreeGame() {
    if (!freeMode || !gameKey) return;
    if (!token()) {
      location.replace('./index.html#login');
      return;
    }
    const s = await loadStatus(true);
    const g = gameState(s, gameKey);
    if (!g?.eligible) {
      location.replace(`./tabuleiro.html?mode=free&pay=1&game=${encodeURIComponent(gameKey)}`);
    }
  }

  function initFreeGame() {
    if (!freeMode || !gameKey) return;
    document.documentElement.classList.add('jl-free-mode');
    badge();
    void guardFreeGame();
  }

  // Public bridge for the board page. Keeping this on window also lets
  // inline/page-level handlers delegate to the same chooser without
  // navigating directly to Ludo or Dama.
  window.JLFreeAccess = {
    openChooser,
    boardClick
  };

  function init() {
    addStyle();
    watchAccountButton();
    ensureModal();
    if (board) installBoard();
    initFreeGame();
  }

  window.addEventListener('jl-player-session-changed', () => {
    injectAccountButton();
    if (freeMode && gameKey) void guardFreeGame();
  });

  document.readyState === 'loading'
    ? document.addEventListener('DOMContentLoaded', init, { once: true })
    : init();
})();
