(() => {
  'use strict';
  if (window.__JL_BET_INSIGHTS__) return;
  window.__JL_BET_INSIGHTS__ = true;

  const cfg = window.JL_CONFIG || {};
  const PLAYER_TOKEN = 'jl_player_token';
  const ADMIN_TOKEN = 'jl_admin_token';
  let playerFilter = 'all';
  let poll = null;

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
      .bet-summary-card.pending{border-color:rgba(244,181,31,.28)}.bet-summary-card.loss{border-color:rgba(255,116,116,.25)}.bet-summary-card.win{border-color:rgba(78,213,138,.27)}
      .bet-filter-row{display:flex;gap:7px;flex-wrap:wrap;margin:0 0 14px}.bet-filter{border:1px solid rgba(255,255,255,.1);border-radius:999px;background:rgba(255,255,255,.035);color:#b9c5d5;padding:7px 11px;font-weight:850;font-size:.75rem;cursor:pointer}.bet-filter.active{background:#f4b51f;color:#171109;border-color:#f4b51f}.bet-filter .count{opacity:.75;margin-left:3px}
      .bet-summary-note{margin-top:-8px;margin-bottom:14px;color:#91a1b6;font-size:.76rem}
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

  function ensurePlayerDashboard() {
    const area = $('#playerArea');
    if (!area || $('#playerBetSummary')) return;
    const history = $('.history-card', area);
    if (!history) return;

    const wrap = document.createElement('section');
    wrap.id = 'playerBetSummary';
    wrap.innerHTML = `<div class="bet-summary-grid">
      ${metricCard('total','Apostas feitas')}
      ${metricCard('pending','Apostas pendentes')}
      ${metricCard('loss','Perda')}
      ${metricCard('win','Ganho')}
    </div><div class="bet-summary-note">Resumo acumulado do Número Lendário e Dupla Lendária.</div>`;
    history.before(wrap);

    const filters = document.createElement('div');
    filters.className = 'bet-filter-row';
    filters.innerHTML = `<button class="bet-filter active" data-bet-filter="all" type="button">Todas <span class="count" data-filter-count="all"></span></button>
      <button class="bet-filter" data-bet-filter="pending" type="button">Pendentes <span class="count" data-filter-count="pending"></span></button>
      <button class="bet-filter" data-bet-filter="lose" type="button">Perdas <span class="count" data-filter-count="lose"></span></button>
      <button class="bet-filter" data-bet-filter="win" type="button">Ganhos <span class="count" data-filter-count="win"></span></button>`;
    const head = $('.section-head', history);
    if (head) head.after(filters); else history.prepend(filters);
    filters.addEventListener('click', (e) => {
      const b = e.target.closest('[data-bet-filter]');
      if (!b) return;
      playerFilter = b.dataset.betFilter;
      $$('.bet-filter', filters).forEach(x => x.classList.toggle('active', x === b));
      applyHistoryFilter();
    });

    const list = $('#betHistory');
    if (list) new MutationObserver(applyHistoryFilter).observe(list, {childList:true, subtree:true});
  }

  function applyHistoryFilter() {
    const items = $$('#betHistory .history-item');
    const counts = {all:items.length,pending:0,lose:0,win:0};
    for (const item of items) {
      const result = $('.history-result', item);
      const kind = result?.classList.contains('win') ? 'win' : result?.classList.contains('lose') ? 'lose' : 'pending';
      counts[kind]++;
      item.style.display = playerFilter === 'all' || playerFilter === kind ? '' : 'none';
    }
    Object.entries(counts).forEach(([k,v]) => {
      const el = document.querySelector(`[data-filter-count="${k}"]`);
      if (el) el.textContent = `(${v})`;
    });
  }

  function setPlayerSummary(s) {
    const root = $('#playerBetSummary');
    if (!root || !s) return;
    const set = (kind, count, amount, sign='') => {
      const c = root.querySelector(`[data-${kind}-count]`);
      const a = root.querySelector(`[data-${kind}-amount]`);
      if (c) c.textContent = Number(count || 0).toLocaleString('pt-MZ');
      if (a) a.textContent = `${sign}${money(amount)} MZN`;
    };
    set('total', s.total_count, s.total_amount);
    set('pending', s.pending_count, s.pending_amount);
    set('loss', s.loss_count, s.loss_amount, s.loss_amount > 0 ? '−' : '');
    set('win', s.win_count, s.win_payout_amount, s.win_payout_amount > 0 ? '+' : '');
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

    const sync = () => {
      const numberOpen = /apostas abertas/i.test($('#numberRoundStatus')?.textContent || '');
      const pairOpen = /apostas abertas/i.test($('#pairRoundStatus')?.textContent || '');
      const nb = $('#betButton');
      const pb = $('#pairBetButton');
      if (nb) nb.disabled = !numberOpen;
      if (pb) pb.disabled = !pairOpen;
    };
    sync();
    for (const id of ['numberRoundStatus','pairRoundStatus']) {
      const el = document.getElementById(id);
      if (el) new MutationObserver(sync).observe(el, {childList:true,characterData:true,subtree:true});
    }
    setInterval(sync, 1000);
  }

  async function refreshSummaries() {
    ensurePlayerDashboard(); ensureAdminDashboard(); applyHistoryFilter();
    const playerToken = localStorage.getItem(PLAYER_TOKEN);
    if (playerToken && $('#playerArea') && !$('#playerArea').classList.contains('hidden')) {
      try { setPlayerSummary(await rpc('jl_player_bet_summary', {p_token:playerToken})); } catch (_) {}
    }
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
    poll = setInterval(refreshSummaries, 5000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
  else init();
})();