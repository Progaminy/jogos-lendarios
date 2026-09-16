(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_admin_token';
  const $ = (id) => document.getElementById(id);

  function money(value) {
    return Number(value || 0).toLocaleString('pt-MZ', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    });
  }

  function toLocalInput(date) {
    return new Date(date.getTime() - date.getTimezoneOffset() * 60000)
      .toISOString()
      .slice(0, 16);
  }

  function setWindow(type, hours) {
    const startInput = $(`${type}ScheduleStart`);
    const endInput = $(`${type}ScheduleEnd`);
    if (!startInput || !endInput) return;

    let start = startInput.value ? new Date(startInput.value) : null;
    if (!start || Number.isNaN(start.getTime()) || start.getTime() <= Date.now() + 10000) {
      start = new Date();
      start.setMinutes(0, 0, 0);
      start.setHours(start.getHours() + 1);
      startInput.value = toLocalInput(start);
    }

    endInput.value = toLocalInput(new Date(start.getTime() + hours * 60 * 60 * 1000));
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

  function renderGame(type, data) {
    const financial = data?.games?.[type]?.financial || {};
    const total = $(`${type}TotalStaked`);
    const min = $(`${type}MinExposure`);
    const floor = $(`${type}HouseFloor`);
    const safe = $(`${type}SafeOutcomes`);

    if (total) total.textContent = money(financial.total_staked);
    if (min) min.textContent = money(financial.min_exposure);
    if (floor) floor.textContent = money(financial.house_floor_at_min);
    if (safe) safe.textContent = `${financial.safe_outcomes ?? 0}/${financial.outcome_count ?? 0}`;
  }

  async function refreshPower() {
    try {
      const data = await dashboard();
      if (!data) return;
      renderGame('number', data);
      renderGame('pair', data);
    } catch {}
  }

  $('numberQuick12')?.addEventListener('click', () => setWindow('number', 12));
  $('numberQuick24')?.addEventListener('click', () => setWindow('number', 24));
  $('pairQuick12')?.addEventListener('click', () => setWindow('pair', 12));
  $('pairQuick24')?.addEventListener('click', () => setWindow('pair', 24));
  $('refreshAdmin')?.addEventListener('click', () => setTimeout(refreshPower, 200));

  refreshPower();
  setInterval(refreshPower, 5000);
})();
