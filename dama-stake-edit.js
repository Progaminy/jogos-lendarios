(() => {
  'use strict';

  if (!String(location.pathname || '').toLowerCase().endsWith('/dama.html')) return;

  let timeOptions = null;
  let timeLoadPromise = null;
  let timeLoadedAt = 0;

  function playerToken() {
    return window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token') || '';
  }

  async function rpc(name, args = {}) {
    if (window.JLApi?.rpc) return window.JLApi.rpc(name, args);
    const c = window.JL_CONFIG || {};
    if (!c.supabaseUrl || !c.supabaseKey) throw new Error('Configuração ausente.');
    const response = await fetch(`${c.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {
        apikey: c.supabaseKey,
        Authorization: `Bearer ${c.supabaseKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(args),
      cache: 'no-store'
    });
    const raw = await response.text();
    let payload = null;
    try { payload = raw ? JSON.parse(raw) : null; } catch { payload = raw; }
    if (!response.ok) throw new Error(payload?.message || payload?.error || `Erro ${response.status}`);
    return payload;
  }

  function formatSeconds(value) {
    const seconds = Math.max(0, Math.trunc(Number(value) || 0));
    if (seconds < 60) return `${seconds} s`;
    const minutes = Math.floor(seconds / 60);
    const rest = seconds % 60;
    return rest ? `${minutes} min ${rest} s` : `${minutes} min`;
  }

  function normalizeTimeOptions(data) {
    const first = Math.trunc(Number(data?.option_one_seconds));
    const second = Math.trunc(Number(data?.option_two_seconds));
    if (!Number.isInteger(first) || !Number.isInteger(second) || first < 10 || second < 10 || first === second) return null;
    return [first, second];
  }

  function applyTimeOptions() {
    if (!Array.isArray(timeOptions) || timeOptions.length !== 2) return;
    const [first, second] = timeOptions;
    const allowed = new Set(timeOptions.map(String));

    const group = document.querySelector('.dama-choice-row[data-choice="time"]');
    const hidden = document.getElementById('damaTime');
    if (group) {
      const buttons = [...group.querySelectorAll('button[data-value]')].slice(0, 2);
      if (buttons.length === 2) {
        buttons[0].dataset.value = String(first);
        buttons[0].textContent = formatSeconds(first);
        buttons[1].dataset.value = String(second);
        buttons[1].textContent = formatSeconds(second);

        let selected = hidden?.value && allowed.has(String(hidden.value)) ? String(hidden.value) : '';
        if (!selected) {
          const active = buttons.find((button) => button.classList.contains('active') && allowed.has(String(button.dataset.value)));
          selected = active?.dataset.value || String(first);
        }
        if (hidden) hidden.value = selected;
        buttons.forEach((button) => button.classList.toggle('active', button.dataset.value === selected));
      }
    }

    const rematch = document.getElementById('damaRematchTime');
    if (rematch) {
      const previous = allowed.has(String(rematch.value)) ? String(rematch.value) : String(first);
      rematch.replaceChildren(...timeOptions.map((seconds) => {
        const option = document.createElement('option');
        option.value = String(seconds);
        option.textContent = formatSeconds(seconds);
        return option;
      }));
      rematch.value = previous;
    }
  }

  async function loadTimeOptions(force = false) {
    const currentToken = playerToken();
    if (!currentToken) return;
    if (!force && timeOptions && Date.now() - timeLoadedAt < 30000) {
      applyTimeOptions();
      return;
    }
    if (timeLoadPromise) return timeLoadPromise;
    timeLoadPromise = (async () => {
      try {
        const data = await rpc('jl_dama_time_options', { p_token: currentToken });
        const next = normalizeTimeOptions(data);
        if (next) {
          timeOptions = next;
          timeLoadedAt = Date.now();
          applyTimeOptions();
        }
      } catch (error) {
        console.warn('[Dama] Não foi possível atualizar os tempos configurados:', error?.message || error);
      } finally {
        timeLoadPromise = null;
      }
    })();
    return timeLoadPromise;
  }

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
    applyTimeOptions();
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

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) loadTimeOptions(true);
  });
  window.addEventListener('jl-player-session-changed', () => {
    timeOptions = null;
    timeLoadedAt = 0;
    loadTimeOptions(true);
  });

  sync();
  loadTimeOptions(true);
})();
