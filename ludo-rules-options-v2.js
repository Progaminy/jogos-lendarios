(() => {
  'use strict';
  if (window.__JL_LUDO_RULE_OPTIONS_V2__) return;
  window.__JL_LUDO_RULE_OPTIONS_V2__ = true;

  const $ = (sel, root = document) => root.querySelector(sel);

  function ensureRuleFields() {
    const form = $('#rulesForm');
    if (!form || form.querySelector('[name="dice_count"]')) return;

    const location = document.createElement('label');
    location.innerHTML = '<span>Tipo de partida</span><select name="play_location"><option value="online">Online</option><option value="presential">Presencial</option></select>';

    const dice = document.createElement('label');
    dice.innerHTML = '<span>Quantidade de dados</span><select name="dice_count"><option value="1">1 dado · clássico</option><option value="3">3 dados</option><option value="4">4 dados</option></select>';

    const first = form.firstElementChild;
    if (first) {
      form.insertBefore(dice, first);
      form.insertBefore(location, dice);
    } else {
      form.append(location, dice);
    }
  }

  function syncValues() {
    ensureRuleFields();
    const summary = $('#rulesSummary');
    const roomMeta = $('#roomMeta');
    const form = $('#rulesForm');
    if (!form) return;

    // ludo.js preenche os campos existentes sempre que renderiza a sala.
    // Estes campos extras passam a fazer parte do mesmo formulário e são enviados pelo mesmo fluxo.
    const dice = form.elements.dice_count;
    const location = form.elements.play_location;
    if (dice && !['1','3','4'].includes(String(dice.value))) dice.value = '1';
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

    if (roomMeta && !roomMeta.dataset.diceHintBound) roomMeta.dataset.diceHintBound = '1';
  }

  function fixInviteTexts() {
    const hero = document.querySelector('.hero-rules');
    if (hero) {
      const first = hero.querySelector('div');
      if (first) first.innerHTML = '<strong>∞</strong><span>convites sem expiração</span>';
    }

    document.querySelectorAll('.rf-broadcast').forEach(el => {
      if (/ativo por|não está ativo|60s|60 s/i.test(el.textContent || '')) {
        el.innerHTML = '<span>📣 Convite para todos: <strong>ativo enquanto houver vaga</strong></span><span>Sem cronómetro.</span>';
      }
    });

    document.querySelectorAll('.rf-invite-item small').forEach(el => {
      if (/responde em até/i.test(el.textContent || '')) el.textContent = 'Convite sem expiração';
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
