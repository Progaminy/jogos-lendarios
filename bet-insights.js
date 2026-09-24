(() => {
  'use strict';
  if (window.__JL_BET_INSIGHTS__) return;
  window.__JL_BET_INSIGHTS__ = true;

  const cfg = window.JL_CONFIG || {};
  const PLAYER_TOKEN = 'jl_player_token';
  const ADMIN_TOKEN = 'jl_admin_token';
  let playerFilter = 'all';
  let poll = null;
  const HIDDEN_HISTORY_KEY = 'jl_hidden_bet_history_v1';
  const HISTORY_COLLAPSED_KEY = 'jl_bet_history_collapsed_v1';

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const money = (v) => Number(v || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  async function rpc(name, args = {}) {
    const response = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {
        apikey: cfg.supabaseKey,
        Authorization: `Bearer ${cfg.supabaseKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(args)
    });
    const raw = await response.text();
    let payload = null;
    try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }
    if (!response.ok) throw new Error(payload?.message || payload?.error || payload?.hint || `Erro ${response.status}`);
    return payload;
  }

  function toast(message, type = 'error') {
    const el = $('#toast');
    if (!el) return;
    el.textContent = message;
    el.className = `toast show ${type}`;
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.className = 'toast'; }, 3800);
  }

  function injectStyles() {
    if ($('#betInsightsStyles')) return;
    const style = document.createElement('style');
    style.id = 'betInsightsStyles';
    style.textContent = `
      .bet-summary-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin:14px 0 18px}
      .bet-summary-card{padding:16px;border:1px solid rgba(255,255,255,.09);border-radius:16px;background:linear-gradient(145deg,rgba(25,35,52,.96),rgba(13,20,31,.98));box-shadow:0 12px 28px rgba(0,0,0,.16)}
      .bet-summary-card span{display:block;color:#96a6ba;font-size:.72rem;font-weight:800;text-transform:uppercase;letter-spacing:.07em}.bet-summary-card strong{display:block;margin-top:6px;font-size:1.45rem}.bet-summary-card small{display:block;margin-top:4px;color:#bec9d8}
      .bet-filter-row{display:flex;gap:7px;flex-wrap:wrap;margin:0 0 10px}.bet-filter{border:1px solid rgba(255,255,255,.1);border-radius:999px;background:rgba(255,255,255,.035);color:#b9c5d5;padding:7px 11px;font-weight:850;font-size:.75rem;cursor:pointer}.bet-filter.active{background:#f4b51f;color:#171109;border-color:#f4b51f}.bet-filter .count{opacity:.75;margin-left:3px}
      .history-head-actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:flex-end}
      .history-clear-row{display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap;margin:0 0 14px}
      .history-card.history-collapsed .history-collapsible{display:none!important}
      .needs-selection{outline:3px solid rgba(244,181,31,.72)!important;outline-offset:6px!important;border-radius:14px;animation:needPick .65s ease 2}@keyframes needPick{50%{outline-color:rgba(244,181,31,.18)}}
      .admin-bet-overview{margin:0 0 20px}.admin-bet-overview .section-head{margin-bottom:8px}.admin-house-net{padding:10px 12px;border-radius:11px;border:1px solid rgba(244,181,31,.16);background:rgba(244,181,31,.05);color:#cbd5e2;font-size:.78rem}
      @media(max-width:900px){.bet-summary-grid{grid-template-columns:1fr 1fr}}
      @media(max-width:560px){.bet-summary-grid{grid-template-columns:1fr}.bet-summary-card{padding:13px}.bet-summary-card strong{font-size:1.25rem}}
    `;
    document.head.appendChild(style);
  }

  function metricCard(kind, title) {
    return `<div class="bet-summary-card ${kind}"><span>${title}</span><strong data-${kind}-count>0</strong><small data-${kind}-amount>0,00 MZN</small></div>`;
  }

  function hiddenHistory() {
    try {
      const raw = JSON.parse(localStorage.getItem(HIDDEN_HISTORY_KEY) || '[]');
      return new Set(Array.isArray(raw) ? raw : []);
    } catch {
      return new Set();
    }
  }

  function saveHiddenHistory(set) {
    localStorage.setItem(HIDDEN_HISTORY_KEY, JSON.stringify([...set].slice(-1200)));
  }

  function historyKind(item) {
    return item.dataset.historyKind ||
      ($('.history-result', item)?.classList.contains('win') ? 'win' :
       $('.history-result', item)?.classList.contains('lose') ? 'lose' : 'pending');
  }

  function setHistoryCollapsed(history, collapsed) {
    history.classList.toggle('history-collapsed', collapsed);
    localStorage.setItem(HISTORY_COLLAPSED_KEY, collapsed ? '1' : '0');
    const button = history.querySelector('[data-history-toggle]');
    if (button) {
      button.textContent = collapsed ? 'Expandir' : 'Recolher';
      button.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
    }
  }

  function clearVisibleHistory(scope) {
    const hidden = hiddenHistory();
    const items = $$('#betHistory .history-item');
    let targets = [];

    if (scope === 'all') {
      targets = items;
    } else if (playerFilter !== 'all') {
      targets = items.filter(item => historyKind(item) === playerFilter);
    }

    if (!targets.length) {
      toast(scope === 'all' ? 'Não há histórico para limpar.' : 'Escolha Pendentes, Perdas ou Ganhos para limpar parcialmente.', 'error');
      return;
    }

    for (const item of targets) {
      const id = item.dataset.historyId;
      if (id) hidden.add(id);
    }
    saveHiddenHistory(hidden);
    applyHistoryFilter();
    toast(scope === 'all' ? 'Histórico limpo.' : 'Histórico parcial limpo.', 'success');
  }

  function ensurePlayerDashboard() {
    const area = $('#playerArea');
    if (!area) return;
    const history = $('.history-card', area);
    if (!history || history.dataset.historyControlsReady === '1') return;
    history.dataset.historyControlsReady = '1';

    const head = $('.section-head', history);
    if (head) {
      const refresh = $('#refreshButton', head);
      const actions = document.createElement('div');
      actions.className = 'history-head-actions';
      if (refresh) actions.appendChild(refresh);
      const toggle = document.createElement('button');
      toggle.type = 'button';
      toggle.className = 'button ghost small';
      toggle.dataset.historyToggle = '1';
      toggle.addEventListener('click', () => setHistoryCollapsed(history, !history.classList.contains('history-collapsed')));
      actions.appendChild(toggle);
      head.appendChild(actions);
    }

    const filters = document.createElement('div');
    filters.className = 'bet-filter-row history-collapsible';
    filters.innerHTML = `<button class="bet-filter active" data-bet-filter="all" type="button">Todas <span class="count" data-filter-count="all"></span></button>
      <button class="bet-filter" data-bet-filter="pending" type="button">Pendentes <span class="count" data-filter-count="pending"></span></button>
      <button class="bet-filter" data-bet-filter="lose" type="button">Perdas <span class="count" data-filter-count="lose"></span></button>
      <button class="bet-filter" data-bet-filter="win" type="button">Ganhos <span class="count" data-filter-count="win"></span></button>`;

    const controls = document.createElement('div');
    controls.className = 'history-clear-row history-collapsible';
    controls.innerHTML = `<button class="button ghost small" data-clear-history="filter" type="button">Limpar filtro</button>
      <button class="button danger small" data-clear-history="all" type="button">Limpar tudo</button>`;

    if (head) {
      head.after(filters);
      filters.after(controls);
    } else {
      history.prepend(controls);
      history.prepend(filters);
    }

    $('#betHistory', history)?.classList.add('history-collapsible');

    filters.addEventListener('click', (e) => {
      const b = e.target.closest('[data-bet-filter]');
      if (!b) return;
      playerFilter = b.dataset.betFilter;
      $$('.bet-filter', filters).forEach(x => x.classList.toggle('active', x === b));
      applyHistoryFilter();
    });

    controls.addEventListener('click', (e) => {
      const b = e.target.closest('[data-clear-history]');
      if (!b) return;
      clearVisibleHistory(b.dataset.clearHistory);
    });

    const list = $('#betHistory');
    if (list) new MutationObserver(applyHistoryFilter).observe(list, {childList:true, subtree:true});

    setHistoryCollapsed(history, true);
    applyHistoryFilter();
  }

  function applyHistoryFilter() {
    const items = $$('#betHistory .history-item');
    const hidden = hiddenHistory();
    const counts = {all:0,pending:0,lose:0,win:0};

    for (const item of items) {
      const id = item.dataset.historyId;
      const kind = historyKind(item);
      const cleared = Boolean(id && hidden.has(id));
      if (!cleared) {
        counts.all++;
        counts[kind]++;
      }
      const matches = playerFilter === 'all' || playerFilter === kind;
      item.style.display = !cleared && matches ? '' : 'none';
    }

    Object.entries(counts).forEach(([k,v]) => {
      const el = document.querySelector(`[data-filter-count="${k}"]`);
      if (el) el.textContent = `(${v})`;
    });

    const clearFilter = document.querySelector('[data-clear-history="filter"]');
    if (clearFilter) {
      clearFilter.disabled = playerFilter === 'all';
      clearFilter.textContent = playerFilter === 'pending'
        ? 'Limpar pendentes'
        : playerFilter === 'lose'
          ? 'Limpar perdas'
          : playerFilter === 'win'
            ? 'Limpar ganhos'
            : 'Limpar filtro';
    }
  }

  function ensureAdminDashboard() {
    const app = $('#adminApp');
    if (!app || $('#adminBetSummary')) return;
    const section = document.createElement('section');
    section.id = 'adminBetSummary';
    section.className = 'card admin-card admin-bet-overview';
    section.innerHTML = `<div class="section-head"><div><p class="eyebrow">APOSTAS · VISÃO GERAL</p><h2>Movimento dos jogadores</h2></div></div>
      <div class="bet-summary-grid">
        ${metricCard('total','Apostas feitas')}
        ${metricCard('pending','Apostas pendentes')}
        ${metricCard('loss','Perdas dos jogadores')}
        ${metricCard('win','Ganhos pagos')}
      </div>
      <div id="adminHouseNet" class="admin-house-net">Resultado liquidado da casa: —</div>`;
    app.prepend(section);
  }

  function setAdminSummary(s) {
    const root = $('#adminBetSummary');
    if (!root || !s) return;
    const set = (kind, count, amount, prefix='') => {
      const c = root.querySelector(`[data-${kind}-count]`);
      const a = root.querySelector(`[data-${kind}-amount]`);
      if (c) c.textContent = Number(count || 0).toLocaleString('pt-MZ');
      if (a) a.textContent = `${prefix}${money(amount)} MZN`;
    };
    set('total', s.total_count, s.total_amount);
    set('pending', s.pending_count, s.pending_amount);
    set('loss', s.loss_count, s.loss_amount);
    set('win', s.win_count, s.win_payout_amount);
    const house = $('#adminHouseNet');
    if (house) house.textContent = `Resultado liquidado da casa: ${money(s.house_net_settled)} MZN · Número: ${Number(s.number_count||0)} apostas · Dupla: ${Number(s.pair_count||0)} apostas.`;
  }

  function guideToNumbers(type) {
    const grid = type === 'pair' ? $('#pairNumberGrid') : $('#numberGrid');
    if (!grid) return;
    const msg = type === 'pair' ? 'Escolha dois números antes de apostar.' : 'Escolha um número antes de apostar.';
    toast(msg, 'error');
    grid.classList.add('needs-selection');
    grid.scrollIntoView({behavior:'smooth', block:'center'});
    setTimeout(() => grid.querySelector('button')?.focus({preventScroll:true}), 450);
    setTimeout(() => grid.classList.remove('needs-selection'), 1800);
  }

  function bindSelectionGuidance() {
    const bind = (formSel, gridSel, required, type) => {
      const form = $(formSel);
      if (!form || form.dataset.selectionGuideBound) return;
      form.dataset.selectionGuideBound = '1';
      form.addEventListener('submit', (e) => {
        const selected = $$(`${gridSel} .number-button.selected`).length;
        if (selected >= required) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        guideToNumbers(type);
      }, true);
    };
    bind('#betForm','#numberGrid',1,'number');
    bind('#pairBetForm','#pairNumberGrid',2,'pair');

    // O estado enabled/disabled pertence exclusivamente ao app.js.
    // Aqui mantemos apenas a orientação quando o utilizador tenta submeter sem seleção.

  }

  async function refreshSummaries() {
    ensurePlayerDashboard(); ensureAdminDashboard(); applyHistoryFilter();
    const adminToken = localStorage.getItem(ADMIN_TOKEN);
    if (adminToken && $('#adminApp') && !$('#adminApp').classList.contains('hidden')) {
      try { setAdminSummary(await rpc('jl_admin_bet_summary', {p_token:adminToken})); } catch (_) {}
    }
  }

  function init() {
    injectStyles();
    ensurePlayerDashboard();
    ensureAdminDashboard();
    bindSelectionGuidance();
    applyHistoryFilter();
    refreshSummaries();
    clearInterval(poll);
    poll = setInterval(()=>{if(document.visibilityState==='visible')refreshSummaries();}, 15000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
  else init();
})();