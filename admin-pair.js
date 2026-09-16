(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_admin_token';
  const $ = (id) => document.getElementById(id);

  const els = {
    metricPairDraw: $('metricPairDraw'),
    pairStats: $('pairStats'),
    recentPairBets: $('recentPairBets'),
    refreshAdmin: $('refreshAdmin')
  };

  function money(value) {
    return Number(value || 0).toLocaleString('pt-MZ', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function dateTime(value) {
    return value ? new Date(value).toLocaleString('pt-MZ', { dateStyle: 'short', timeStyle: 'short' }) : '—';
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (c) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', "'":'&#39;', '"':'&quot;' }[c]));
  }

  async function dashboard() {
    const token = localStorage.getItem(TOKEN_KEY) || '';
    if (!token || !cfg.supabaseUrl || !cfg.supabaseKey) return null;

    const response = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/jl_admin_dashboard`, {
      method: 'POST',
      headers: {
        apikey: cfg.supabaseKey,
        Authorization: `Bearer ${cfg.supabaseKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify({ p_token: token })
    });

    if (!response.ok) return null;
    return response.json();
  }

  function render(data) {
    const last = data?.last_result;
    if (els.metricPairDraw) {
      els.metricPairDraw.textContent = last?.pair_drawn_a != null && last?.pair_drawn_b != null
        ? `${last.pair_drawn_a} + ${last.pair_drawn_b}`
        : '—';
    }

    if (els.pairStats) {
      if (!data?.round) {
        els.pairStats.innerHTML = '<div class="empty">Abra ou programe uma rodada para acompanhar as combinações.</div>';
      } else {
        const stats = data?.pair_stats || [];
        els.pairStats.innerHTML = stats.map((item) => `
          <div class="number-stat">
            <strong>${item.number_a}+${item.number_b}</strong>
            <span>${item.bets} aposta${Number(item.bets) === 1 ? '' : 's'}</span>
            <small>MZN ${money(item.total)}</small>
          </div>`).join('');
      }
    }

    if (els.recentPairBets) {
      const bets = data?.recent_pair_bets || [];
      els.recentPairBets.innerHTML = bets.length ? bets.map((b) => `
        <div class="request-row">
          <div><strong>${escapeHtml(b.name)}</strong><br><small>Rodada ${b.round_no} · combinação ${b.number_a}+${b.number_b} · ${dateTime(b.created_at)}</small></div>
          <strong>MZN ${money(b.amount)}</strong>
          <div>${b.won === true ? '<span class="win">Vencedora</span>' : b.won === false ? '<span class="lose">Não premiada</span>' : '<span class="pending">Pendente</span>'}</div>
        </div>`).join('') : '<div class="empty">Ainda não há apostas na Dupla Lendária.</div>';
    }
  }

  async function refreshPairAdmin() {
    try {
      const data = await dashboard();
      if (data) render(data);
    } catch {}
  }

  els.refreshAdmin?.addEventListener('click', () => setTimeout(refreshPairAdmin, 150));
  refreshPairAdmin();
  setInterval(refreshPairAdmin, 10000);
})();
