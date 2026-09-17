(() => {
  'use strict';
  if (window.__JL_LUDO_INVITES_DICE_FIX__) return;
  window.__JL_LUDO_INVITES_DICE_FIX__ = true;

  function ensureDiceOptions() {
    const select = document.querySelector('#rulesForm select[name="dice_count"]');
    if (!select) return;
    const current = String(select.value || '1');
    const expected = [
      ['1', '1 dado · clássico'],
      ['2', '2 dados'],
      ['3', '3 dados'],
      ['4', '4 dados']
    ];
    const signature = Array.from(select.options).map(o => `${o.value}:${o.textContent}`).join('|');
    const target = expected.map(([v,t]) => `${v}:${t}`).join('|');
    if (signature !== target) {
      select.innerHTML = expected.map(([v,t]) => `<option value="${v}">${t}</option>`).join('');
      select.value = expected.some(([v]) => v === current) ? current : '1';
      select.dispatchEvent(new Event('change', { bubbles: true }));
    }

    const note = document.querySelector('#rulesForm .variant-note');
    if (note) note.textContent = 'Com 2, 3 ou 4 dados, todos são lançados juntos e usados um por vez, na ordem sorteada. Um dado sem movimento possível é pulado automaticamente. Nesse modo, 6 e captura não geram nova jogada extra.';
  }

  function persistentInviteTexts() {
    const heroRule = document.querySelector('.hero-rules > div:first-child');
    if (heroRule) heroRule.innerHTML = '<strong>SEM PRAZO</strong><span>convites até a sala fechar</span>';

    const note = document.querySelector('#globalChallengePanel .gc-note');
    if (note) note.textContent = 'Quem clica “Quero jogar” abre uma sala e o convite fica visível para todos enquanto houver vaga.';

    const queue = document.getElementById('queueStatus');
    if (queue && /60 segundos/i.test(queue.textContent || '')) {
      queue.innerHTML = 'Valor inicial <strong>10 MZN</strong>. Pode aumentar antes de lançar. O convite fica visível para todos enquanto a sala tiver vaga.';
    }

    const broadcast = document.getElementById('rfBroadcast');
    if (broadcast && /convite para todos/i.test(broadcast.textContent || '')) {
      const roomIsPublic = !/sala privada/i.test(broadcast.textContent || '');
      if (roomIsPublic) broadcast.innerHTML = '<span>📣 Convite para todos: <strong>ATIVO · sem prazo</strong></span><span>Fica visível enquanto a sala estiver aberta e houver vaga.</span>';
    }

    document.querySelectorAll('#rfInviteList .rf-invite-item small').forEach(el => {
      if (/responde em até|convite registrado/i.test(el.textContent || '')) el.textContent = 'Convite sem prazo · válido enquanto a sala estiver disponível';
    });

    const toast = document.getElementById('toast');
    if (toast && /por 60 segundos/i.test(toast.textContent || '')) {
      toast.textContent = toast.textContent.replace(/por 60 segundos/ig, 'sem prazo enquanto a sala estiver aberta');
    }
  }

  function fixMetaText() {
    const meta = document.getElementById('roomMeta');
    if (!meta) return;
    meta.textContent = (meta.textContent || '').replace(/·\s*([134])\s+dados?/g, (m,n) => `· ${n} ${n === '1' ? 'dado' : 'dados'}`);
  }

  function run() {
    ensureDiceOptions();
    persistentInviteTexts();
    fixMetaText();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true });
  else run();

  new MutationObserver(run).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
  setInterval(run, 750);
})();
