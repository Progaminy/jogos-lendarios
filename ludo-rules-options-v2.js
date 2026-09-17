(() => {
  'use strict';
  if (window.__JL_LUDO_RULE_OPTIONS_V2__) return;
  window.__JL_LUDO_RULE_OPTIONS_V2__ = true;

  const $ = (sel, root = document) => root.querySelector(sel);

  function ensureRuleFields() {
    const form = $('#rulesForm');
    if (!form) return;

    let location = form.querySelector('[name="play_location"]')?.closest('label');
    if (!location) {
      location = document.createElement('label');
      location.innerHTML = '<span>Tipo de partida</span><select name="play_location"><option value="online">Online</option><option value="presential">Presencial</option></select>';
    }

    let diceSelect = form.querySelector('[name="dice_count"]');
    let dice = diceSelect?.closest('label');
    if (!diceSelect) {
      dice = document.createElement('label');
      dice.innerHTML = '<span>Quantidade de dados</span><select name="dice_count"></select>';
      diceSelect = dice.querySelector('select');
    }

    const current = String(diceSelect.value || '1');
    const wanted = [['1','1 dado · clássico'],['2','2 dados'],['3','3 dados'],['4','4 dados']];
    const signature = Array.from(diceSelect.options).map(o => o.value).join(',');
    if (signature !== '1,2,3,4') {
      diceSelect.innerHTML = wanted.map(([v,t]) => `<option value="${v}">${t}</option>`).join('');
      diceSelect.value = wanted.some(([v]) => v === current) ? current : '1';
    }

    if (!location.isConnected || !dice.isConnected) {
      const first = form.firstElementChild;
      if (first) {
        if (!dice.isConnected) form.insertBefore(dice, first);
        if (!location.isConnected) form.insertBefore(location, dice);
      } else {
        if (!location.isConnected) form.append(location);
        if (!dice.isConnected) form.append(dice);
      }
    }
  }

  function syncValues() {
    ensureRuleFields();
    const summary = $('#rulesSummary');
    const form = $('#rulesForm');
    if (!form) return;

    const dice = form.elements.dice_count;
    const location = form.elements.play_location;
    if (dice && !['1','2','3','4'].includes(String(dice.value))) dice.value = '1';
    if (location && !['online','presential'].includes(String(location.value))) location.value = 'online';

    if (summary && !summary.querySelector('[data-extra-rule="dice"]')) {
      const d = document.createElement('div');
      d.className = 'rule-chip';
      d.dataset.extraRule = 'dice';
      d.textContent = `Dados: ${dice?.value || 1}`;
      summary.prepend(d);
      const l = document.createElement('div');
      l.className = 'rule-chip';
      l.dataset.extraRule = 'location';
      l.textContent = `Partida: ${location?.value === 'presential' ? 'Presencial' : 'Online'}`;
      summary.prepend(l);
    } else if (summary) {
      const d = summary.querySelector('[data-extra-rule="dice"]');
      const l = summary.querySelector('[data-extra-rule="location"]');
      if (d) d.textContent = `Dados: ${dice?.value || 1}`;
      if (l) l.textContent = `Partida: ${location?.value === 'presential' ? 'Presencial' : 'Online'}`;
    }
  }

  function fixInviteTexts() {
    const hero = document.querySelector('.hero-rules');
    if (hero) {
      const first = hero.querySelector('div');
      if (first) first.innerHTML = '<strong>∞</strong><span>convites sem expiração</span>';
    }

    document.querySelectorAll('.rf-broadcast').forEach(el => {
      if (/convite para todos/i.test(el.textContent || '')) {
        el.innerHTML = '<span>📣 Convite para todos: <strong>ativo enquanto houver vaga</strong></span><span>Sem cronómetro.</span>';
      }
    });

    document.querySelectorAll('.rf-invite-item small').forEach(el => {
      if (/responde em até|convite registrado/i.test(el.textContent || '')) el.textContent = 'Convite sem expiração';
    });
  }

  function setDefaultBets() {
    for (const id of ['createBet','queueBet']) {
      const el = document.getElementById(id);
      if (el && (el.value === '100' || Number(el.value) < 10)) el.value = '10';
    }
  }

  function tick() {
    ensureRuleFields();
    syncValues();
    fixInviteTexts();
    setDefaultBets();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', tick, {once:true});
  else tick();
  setInterval(tick, 1200);
})();
