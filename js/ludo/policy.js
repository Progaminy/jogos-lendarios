(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const nativeFetch = window.fetch.bind(window);
  let latestRoomState = null;

  const parseMoney = (value) => Number(String(value || '')
    .replace(/[\s\u00A0]/g, '')
    .replace(/\./g, '')
    .replace(',', '.'));

  const formatMoney = (value) => Number(value || 0).toLocaleString('pt-MZ', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });

  function captureRoomState(data) {
    if (!data || !data.room || !data.room.rules) return;
    latestRoomState = data;
    queueMicrotask(renderVariantState);
  }

  window.fetch = async (...args) => {
    const response = await nativeFetch(...args);
    try {
      const url = String(args[0] || '');
      if (url.includes('/rest/v1/rpc/jl_ludo_')) {
        const data = await response.clone().json();
        captureRoomState(data);
      }
    } catch (_) {}
    return response;
  };

  async function variantRpc(name, args = {}) {
    try { return await window.JLApi.rpc(name, args); }
    catch (_) { return null; }
  }

  async function refreshVariantState() {
    const token = window.JLSession?.getPlayerToken?.() || localStorage.getItem('jl_player_token');
    if (!token) return;
    const status = await variantRpc('jl_ludo_my_status', { p_token: token });
    if (!status?.active_room_id) return;
    const room = await variantRpc('jl_ludo_room_state', {
      p_token: token,
      p_room: status.active_room_id
    });
    captureRoomState(room);
  }

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

  // A comissão é calculada apenas pelo motor principal do Ludo.

  function injectVariantStyles() {
    if (document.getElementById('ludoVariantStyles')) return;
    const style = document.createElement('style');
    style.id = 'ludoVariantStyles';
    style.textContent = `
      .variant-note{grid-column:1/-1;padding:11px 12px;border:1px solid rgba(244,189,66,.25);border-radius:12px;background:rgba(244,189,66,.06);color:#c8d5e6;font-size:.78rem;line-height:1.45}
      .dice.multi-dice{width:auto;min-width:58px;height:auto;min-height:58px;padding:7px;display:flex;gap:6px;flex-wrap:wrap;background:#0d1725;color:inherit}
      .dice.multi-dice .die-face{display:grid;place-items:center;width:42px;height:42px;border-radius:11px;background:#f6f0dd;color:#142033;font-size:1.35rem;font-weight:900;box-shadow:inset 0 0 0 2px rgba(0,0,0,.12)}
      .dice.multi-dice .die-face.used{opacity:.38}
      .dice.multi-dice .die-face.current{outline:3px solid #f4bd42;outline-offset:2px}
      .variant-chip{border-color:rgba(76,139,245,.28)!important;background:rgba(76,139,245,.07)!important}
    `;
    document.head.appendChild(style);
  }

  function injectVariantControls() {
    const form = document.getElementById('rulesForm');
    if (!form || form.querySelector('[name="dice_count"]')) return;

    const location = document.createElement('label');
    location.dataset.ludoVariantControl = '1';
    location.innerHTML = '<span>Local da partida</span><select name="play_location"><option value="online">Online</option><option value="presential">Presencial</option></select>';

    const dice = document.createElement('label');
    dice.dataset.ludoVariantControl = '1';
    dice.innerHTML = '<span>Quantidade de dados</span><select name="dice_count"><option value="1">1 dado · clássico</option><option value="2">2 dados</option><option value="3">3 dados</option><option value="4">4 dados</option></select>';

    const fragment = document.createDocumentFragment();
    fragment.append(location, dice);
    form.prepend(fragment);

    dice.querySelector('select').addEventListener('change', syncMultiDiceForm);
    location.querySelector('select').addEventListener('change', () => {
      const presential = location.querySelector('select').value === 'presential';
      if (presential) {
        const voice = form.elements.voice_enabled;
        if (voice) voice.checked = false;
      }
    });

    syncControlsFromState();
    syncMultiDiceForm();
  }

  function syncControlsFromState() {
    const form = document.getElementById('rulesForm');
    const rules = latestRoomState?.room?.rules;
    if (!form || !rules) return;
    if (form.elements.play_location) form.elements.play_location.value = rules.play_location || 'online';
    if (form.elements.dice_count) form.elements.dice_count.value = String(rules.dice_count || 1);
    syncMultiDiceForm();
  }

  function syncMultiDiceForm() {
    const form = document.getElementById('rulesForm');
    if (!form?.elements.dice_count) return;
    const multi = Number(form.elements.dice_count.value) > 1;
    for (const name of ['six_extra_turn', 'capture_extra_turn', 'three_sixes_penalty']) {
      const input = form.elements[name];
      if (!input) continue;
      if (multi) input.checked = false;
      input.disabled = multi;
      const label = input.closest('label');
      if (label) label.style.opacity = multi ? '.5' : '';
    }
  }

  function renderRuleSummary() {
    const box = document.getElementById('rulesSummary');
    const rules = latestRoomState?.room?.rules;
    if (!box || !rules || box.querySelector('[data-variant-chip]')) return;

    const location = document.createElement('div');
    location.className = 'rule-chip variant-chip';
    location.dataset.variantChip = '1';
    location.textContent = `Local: ${rules.play_location === 'presential' ? 'Presencial' : 'Online'}`;

    const dice = document.createElement('div');
    dice.className = 'rule-chip variant-chip';
    dice.dataset.variantChip = '1';
    const count = Number(rules.dice_count || 1);
    dice.textContent = count === 1 ? 'Dados: 1 · clássico' : `Dados: ${count} · usados um por vez`;

    box.prepend(dice);
    box.prepend(location);
  }

  function renderRoomMeta() {
    const el = document.getElementById('roomMeta');
    const rules = latestRoomState?.room?.rules;
    if (!el || !rules) return;
    const mobile = window.matchMedia?.('(max-width:600px)')?.matches;
    const base = (el.textContent || '').replace(/\s·\s(?:Online|Presencial|On|Pres\.)\s·\s(?:[1-4])(?:\s+dados?|D).*$/,'');
    const count = Number(rules.dice_count || 1);
    const location = mobile
      ? (rules.play_location === 'presential' ? 'Pres.' : 'On')
      : (rules.play_location === 'presential' ? 'Presencial' : 'Online');
    const dice = mobile ? `${count}D` : `${count} ${count === 1 ? 'dado' : 'dados'}`;
    const next = `${base} · ${location} · ${dice}`;
    if (el.textContent !== next) el.textContent = next;
  }

  function lastRolledValues() {
    const events = latestRoomState?.events || [];
    for (let i = events.length - 1; i >= 0; i -= 1) {
      const event = events[i];
      if (event?.event_type !== 'dice_rolled') continue;
      const payload = event.payload || {};
      const multi = Array.isArray(payload.dice_values)
        ? payload.dice_values.map(Number).filter(v => Number.isInteger(v) && v >= 1 && v <= 6)
        : [];
      if (multi.length) return multi;
      const single = Number(payload.dice);
      if (Number.isInteger(single) && single >= 1 && single <= 6) return [single];
    }
    return [];
  }

  function renderDice() {
    const el = document.getElementById('dice');
    const room = latestRoomState?.room;
    if (!el || !room) return;
    if (el.classList.contains('rolling') || el.dataset.jlRolling === '1') return;

    const count = Number(room.rules?.dice_count || 1);
    const activeValues = Array.isArray(room.dice_values)
      ? room.dice_values.map(Number).filter(v => Number.isInteger(v) && v >= 1 && v <= 6)
      : [];
    const values = activeValues.length ? activeValues : lastRolledValues();
    const position = activeValues.length ? Number(room.dice_position ?? -1) : -1;
    const direct = Number(room.dice_result);
    const current = Number.isInteger(direct) && direct >= 1 && direct <= 6
      ? direct
      : Number.isInteger(position) && position >= 0 && position < values.length
        ? Number(values[position])
        : Number(values[0]);

    const roll = document.getElementById('rollDice');
    if (roll) roll.textContent = count === 1 ? '🎲 Lançar dado' : `🎲 Lançar ${count} dados`;

    // Mesmo quando a regra usa vários dados, a interface mostra somente
    // o dado que está ativo naquele momento. Nunca renderizar duas ou mais faces.
    el.classList.remove('multi-dice');
    delete el.dataset.variantSignature;

    if (Number.isInteger(current) && current >= 1 && current <= 6) {
      const layouts = {1:[5],2:[1,9],3:[1,5,9],4:[1,3,7,9],5:[1,3,5,7,9],6:[1,3,4,6,7,9]};
      const visible = new Set(layouts[current]);
      const signature = `single:${current}`;
      if (el.dataset.singleDiceSignature !== signature || el.querySelector('.die-face')) {
        el.dataset.singleDiceSignature = signature;
        el.classList.remove('empty');
        el.dataset.value = String(current);
        el.setAttribute('aria-label', `Dado: ${current}`);
        el.replaceChildren();
        for (let i = 1; i <= 9; i += 1) {
          const pip = document.createElement('span');
          pip.className = `pip p${i}${visible.has(i) ? ' on' : ''}`;
          el.appendChild(pip);
        }
      }
    }

    const hint = document.getElementById('moveHint');
    if (hint && room.turn_phase === 'move' && Number.isInteger(current)) {
      hint.textContent = count > 1 && position >= 0
        ? `Dado atual: ${current} (${position + 1}/${Math.max(values.length, count)}). Escolha uma peça válida.`
        : `Dado ${current}: escolha uma peça válida.`;
    }
  }

  function renderVariantState() {
    injectVariantControls();
    syncControlsFromState();
    renderRuleSummary();
    renderRoomMeta();
    renderDice();
  }

  document.addEventListener('DOMContentLoaded', () => {
    injectVariantStyles();
    injectVariantControls();
    enforceMinimums();
    refreshVariantState();

    const summary = document.getElementById('rulesSummary');
    if (summary) new MutationObserver(renderRuleSummary).observe(summary, { childList: true });

    const dice = document.getElementById('dice');
    if (dice) new MutationObserver(renderDice).observe(dice, { childList: true, characterData: true, subtree: true });

    const meta = document.getElementById('roomMeta');
    if (meta) new MutationObserver(renderRoomMeta).observe(meta, { childList: true, characterData: true, subtree: true });
  });
})();
