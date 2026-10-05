(() => {
  'use strict';
  if (window.__JL_DAMA_HISTORY_COPY__) return;
  window.__JL_DAMA_HISTORY_COPY__ = true;

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

  function toast(message, type = 'success') {
    const el = $('#damaToast');
    if (!el) return;
    el.textContent = message;
    el.className = `toast show ${type}`.trim();
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { el.className = 'toast'; }, 2600);
  }

  function clean(value) {
    return String(value || '').replace(/\s+/g, ' ').trim();
  }

  function historyRows() {
    return $$('#damaHistory .dama-history-row').map((row) => clean(row.textContent)).filter(Boolean);
  }

  function buildHistoryText() {
    const rows = historyRows();
    if (!rows.length) return '';

    const room = clean($('#damaRoomCode')?.textContent);
    const players = $$('#damaPlayers .dama-player-info strong')
      .map((el) => clean(el.textContent).replace(/\s*·\s*você$/i, ''))
      .filter(Boolean);
    const resultVisible = $('#damaResult') && !$('#damaResult').classList.contains('hidden');
    const result = resultVisible ? clean($('#damaResultTitle')?.textContent) : '';

    const lines = ['Dama Lendária'];
    if (room && room !== '—') lines.push(`Sala: ${room}`);
    if (players.length) lines.push(`Jogadores: ${players.join(' × ')}`);
    if (result && result !== 'Partida terminada') lines.push(`Resultado: ${result}`);
    lines.push('', 'Jogadas:', ...rows);
    return lines.join('\n');
  }

  async function copyText(text) {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return;
    }

    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand('copy');
    area.remove();
    if (!ok) throw new Error('COPY_FAILED');
  }

  function injectStyle() {
    if ($('#jlDamaHistoryCopyStyle')) return;

    const style = document.createElement('style');
    style.id = 'jlDamaHistoryCopyStyle';
    style.textContent = `
      .dama-history summary{
        display:flex;align-items:center;gap:8px;list-style:none;user-select:none
      }
      .dama-history summary::-webkit-details-marker{display:none}
      .dama-history summary::after{
        content:'⌄';margin-left:auto;color:#8fa0b4;font-size:1rem;font-weight:900;
        transform:rotate(0deg);transition:transform .16s ease,color .16s ease
      }
      .dama-history[open] summary::after{transform:rotate(180deg);color:#f4bd42}
      .dama-history-tools{
        display:flex;align-items:center;justify-content:flex-end;padding:0 14px 8px
      }
      .dama-history-copy{
        min-height:28px;padding:4px 9px;border-radius:8px;display:inline-flex;align-items:center;gap:5px;
        border:1px solid rgba(255,255,255,.11);background:rgba(255,255,255,.045);
        color:#dce5ef;font-size:.7rem;font-weight:850;line-height:1;cursor:pointer
      }
      .dama-history-copy:hover,.dama-history-copy:focus-visible{
        background:rgba(244,189,66,.1);border-color:rgba(244,189,66,.32);color:#f4bd42
      }
      .dama-history-copy:disabled{opacity:.34;cursor:default}
      .dama-history-copy-icon{font-size:.85rem;line-height:1}
    `;
    document.head.appendChild(style);
  }

  function syncButton() {
    const button = $('#damaCopyHistory');
    if (!button) return;

    const hasMoves = historyRows().length > 0;
    button.disabled = !hasMoves;
    button.setAttribute('aria-disabled', hasMoves ? 'false' : 'true');
    button.title = hasMoves ? 'Copiar histórico do jogo' : 'Ainda sem jogadas';
  }

  function install() {
    injectStyle();

    const details = $('.dama-history');
    const summary = details?.querySelector('summary');
    const history = $('#damaHistory');
    if (!details || !summary || !history) return setTimeout(install, 200);

    summary.textContent = 'Histórico do jogo';
    if ($('#damaCopyHistory')) return syncButton();

    const tools = document.createElement('div');
    tools.className = 'dama-history-tools';

    const button = document.createElement('button');
    button.id = 'damaCopyHistory';
    button.className = 'dama-history-copy';
    button.type = 'button';
    button.setAttribute('aria-label', 'Copiar histórico do jogo');
    button.innerHTML = '<span class="dama-history-copy-icon" aria-hidden="true">⧉</span><span>Copiar</span>';

    tools.appendChild(button);
    history.insertAdjacentElement('beforebegin', tools);

    button.addEventListener('click', async () => {
      const text = buildHistoryText();
      if (!text) return toast('Ainda sem jogadas.', 'error');

      try {
        await copyText(text);
        toast('Histórico copiado.', 'success');
      } catch {
        toast('Não foi possível copiar o histórico.', 'error');
      }
    });

    new MutationObserver(syncButton).observe(history, {
      childList: true,
      subtree: true,
      characterData: true
    });
    syncButton();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();
