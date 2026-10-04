(() => {
  'use strict';

  const room = document.getElementById('damaRoom');
  const head = room?.querySelector('.dama-room-head');
  const game = document.getElementById('damaGame');
  if (!room || !head || !game) return;

  function injectStyle() {
    if (document.getElementById('damaRoomPreviewStyle')) return;
    const style = document.createElement('style');
    style.id = 'damaRoomPreviewStyle';
    style.textContent = `
      .dama-room-head{
        display:grid!important;
        grid-template-columns:minmax(0,1fr) auto!important;
        align-items:start!important;
        gap:10px 12px!important;
        padding:14px!important;
      }
      .dama-room-head>div:first-child{min-width:0}
      .dama-room-head h1{
        margin:1px 0 2px!important;
        font-size:clamp(1rem,4.8vw,1.45rem)!important;
        line-height:1.05!important;
        letter-spacing:.01em!important;
        overflow:hidden;
        text-overflow:ellipsis;
        white-space:nowrap;
      }
      .dama-room-head #damaRoomMeta{
        margin:0!important;
        font-size:.76rem!important;
      }
      .dama-room-actions{
        align-self:start!important;
        justify-content:flex-end!important;
      }
      .dama-room-preview{
        grid-column:1/-1;
        width:100%;
        margin-top:2px;
        padding-top:8px;
        border-top:1px solid rgba(255,255,255,.07);
      }
      .dama-room-preview.hidden{display:none!important}
      .dama-room-preview-board{
        width:min(100%,620px)!important;
        margin:0 auto!important;
        pointer-events:none!important;
        border-width:4px!important;
      }
      .dama-room-preview-board .dama-piece{
        width:74%!important;
        height:74%!important;
      }

      /* Aceitação da partida volta a ser uma janela, não um bloco da página. */
      #damaGuestDecision.dama-accept-window{
        position:fixed!important;
        inset:0!important;
        z-index:1700!important;
        display:grid!important;
        place-items:center!important;
        padding:14px!important;
        margin:0!important;
        background:rgba(1,6,14,.78)!important;
        backdrop-filter:blur(7px);
      }
      #damaGuestDecision.dama-accept-window.hidden{display:none!important}
      .dama-accept-card{
        width:min(430px,100%);
        max-height:min(86dvh,700px);
        overflow:auto;
        padding:20px;
        border:1px solid rgba(244,189,66,.35);
        border-radius:20px;
        background:linear-gradient(160deg,#17263b,#0d1726);
        box-shadow:0 28px 90px rgba(0,0,0,.62);
      }
      .dama-accept-card .eyebrow{margin-bottom:5px}
      .dama-accept-card h2{margin:0 0 7px;font-size:1.55rem}
      .dama-accept-card>p:not(.eyebrow){margin:0;color:#9fb0c2;line-height:1.45}
      .dama-accept-summary{
        display:grid;
        grid-template-columns:repeat(2,minmax(0,1fr));
        gap:7px;
        margin:16px 0;
      }
      .dama-accept-summary .dama-setting-chip{
        display:block;
        min-width:0;
        padding:9px 10px;
        border:1px solid rgba(255,255,255,.07);
        border-radius:11px;
        background:rgba(255,255,255,.045);
        overflow-wrap:anywhere;
      }
      .dama-accept-actions{
        display:grid!important;
        grid-template-columns:1fr 1fr;
        gap:9px!important;
        margin-top:4px!important;
      }
      .dama-accept-actions .button{width:100%;min-height:48px}
      body.dama-accept-open{overflow:hidden}

      /* Fixar Dama = modo foco, igual ao conceito de Fixar Ludo. */
      .dama-board-head-actions{
        display:flex;
        align-items:center;
        justify-content:flex-end;
        gap:7px;
        flex:0 0 auto;
      }
      .dama-pin-button{
        min-height:38px;
        padding:7px 10px;
        white-space:nowrap;
      }
      body.dama-pinned #damaRoom>.dama-room-head,
      body.dama-pinned #damaRoom>#damaPlayers,
      body.dama-pinned #damaRoom>#damaSettingsPanel,
      body.dama-pinned #damaGame>.dama-side,
      body.dama-pinned #damaDrawOffer,
      body.dama-pinned #damaResult,
      body.dama-pinned #jlGlobalAccountFooter{
        display:none!important;
      }
      body.dama-pinned #damaRoom{
        display:block!important;
        margin-top:5px!important;
      }
      body.dama-pinned #damaGame{
        display:block!important;
        width:100%!important;
        max-width:820px!important;
        margin:4px auto 0!important;
      }
      body.dama-pinned #damaGame>.dama-board-panel{
        position:static!important;
        width:100%!important;
        max-width:none!important;
        margin:0!important;
        padding:12px!important;
        overflow:visible!important;
      }
      body.dama-pinned .dama-pin-button{
        border-color:rgba(244,189,66,.65)!important;
        background:rgba(244,189,66,.12)!important;
        color:#ffd15a!important;
      }
      body.dama-pinned #damaBoard{
        width:min(100%,720px)!important;
        margin-top:8px!important;
      }
      #damaGame>.dama-board-panel{scroll-margin-top:155px}

      @media(max-width:520px){
        .dama-room-head{
          grid-template-columns:minmax(0,1fr) auto!important;
          padding:10px!important;
          gap:8px!important;
        }
        .dama-room-actions .button{padding:7px 9px!important;font-size:.72rem!important}
        .dama-room-preview-board{border-width:3px!important}
        .dama-accept-card{padding:17px 14px;border-radius:17px}
        .dama-accept-summary{grid-template-columns:1fr 1fr;gap:6px}
        .dama-board-head-actions{gap:5px}
        .dama-pin-button{min-height:34px;padding:5px 7px;font-size:.68rem}
        body.dama-pinned .dama-shell{
          width:calc(100% - 8px)!important;
          margin-left:auto!important;
          margin-right:auto!important;
        }
        body.dama-pinned #damaGame>.dama-board-panel{
          padding:8px!important;
          border-radius:14px!important;
        }
        body.dama-pinned #damaBoard{margin-top:6px!important}
      }
    `;
    document.head.appendChild(style);
  }

  function ensurePreview() {
    let preview = document.getElementById('damaRoomPreview');
    if (preview) return preview;

    preview = document.createElement('div');
    preview.id = 'damaRoomPreview';
    preview.className = 'dama-room-preview';
    preview.innerHTML = '<div id="damaRoomPreviewBoard" class="dama-board dama-room-preview-board" aria-label="Tabuleiro de Dama antes do início da partida"></div>';
    head.appendChild(preview);
    return preview;
  }

  function ensureAcceptWindow() {
    const decision = document.getElementById('damaGuestDecision');
    if (!decision || decision.dataset.damaWindow === '1') return decision;

    const decline = document.getElementById('damaDeclineSettings');
    const accept = document.getElementById('damaAcceptSettings');
    if (!decline || !accept) return decision;

    decision.dataset.damaWindow = '1';
    decision.className = 'dama-modal dama-accept-window hidden';
    decision.setAttribute('role', 'dialog');
    decision.setAttribute('aria-modal', 'true');
    decision.setAttribute('aria-labelledby', 'damaAcceptWindowTitle');

    const card = document.createElement('div');
    card.className = 'dama-accept-card';
    card.innerHTML = `
      <p class="eyebrow">DAMA LENDÁRIA</p>
      <h2 id="damaAcceptWindowTitle">Aceitar partida?</h2>
      <p>Confira as definições antes de aceitar.</p>
      <div id="damaAcceptWindowSummary" class="dama-accept-summary"></div>
      <div class="dama-decision dama-accept-actions"></div>`;

    const actions = card.querySelector('.dama-accept-actions');
    actions.append(decline, accept);
    decision.replaceChildren(card);
    document.body.appendChild(decision);
    return decision;
  }

  function syncAcceptSummary() {
    const summary = document.getElementById('damaAcceptWindowSummary');
    const source = document.getElementById('damaSettingsSummary');
    if (!summary || !source) return;

    const chips = [...source.querySelectorAll('.dama-setting-chip')]
      .filter((chip) => !/aguardando aceitação/i.test(chip.textContent || ''));
    const html = chips.map((chip) => `<span class="dama-setting-chip">${chip.innerHTML}</span>`).join('');
    if (summary.innerHTML !== html) summary.innerHTML = html;
  }

  function myColor() {
    const cards = [...document.querySelectorAll('#damaPlayers .dama-player')];
    const mine = cards.find((card) => /\bvocê\b/i.test(card.textContent || ''));
    if (mine?.querySelector('.dama-player-piece.red')) return 'red';
    if (mine?.querySelector('.dama-player-piece.white')) return 'white';
    return 'white';
  }

  function renderPreviewBoard() {
    const board = document.getElementById('damaRoomPreviewBoard');
    if (!board) return;

    const color = myColor();
    if (board.childElementCount === 64 && board.dataset.orientation === color) return;
    board.dataset.orientation = color;

    const rotate = color === 'red';
    const frag = document.createDocumentFragment();
    for (let displayRow = 0; displayRow < 8; displayRow++) {
      for (let displayCol = 0; displayCol < 8; displayCol++) {
        const row = rotate ? 7 - displayRow : displayRow;
        const col = rotate ? 7 - displayCol : displayCol;
        const dark = (row + col) % 2 === 1;
        const cell = document.createElement('span');
        cell.className = `dama-cell ${dark ? 'dark' : 'light'}`;

        if (dark && (row <= 2 || row >= 5)) {
          const piece = document.createElement('span');
          piece.className = `dama-piece ${row <= 2 ? 'red' : 'white'}`;
          cell.appendChild(piece);
        }
        frag.appendChild(cell);
      }
    }
    board.replaceChildren(frag);
  }

  function setPinned(value, scroll = true) {
    const pin = document.getElementById('damaPin');
    const pinned = Boolean(value);
    document.body.classList.toggle('dama-pinned', pinned);
    if (pin) {
      pin.setAttribute('aria-pressed', pinned ? 'true' : 'false');
      pin.textContent = pinned ? 'Desfixar Dama' : 'Fixar Dama';
    }
    if (pinned && scroll) {
      requestAnimationFrame(() => {
        game.querySelector('.dama-board-panel')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      });
    }
  }

  function ensurePinButton() {
    const gameHead = game.querySelector('.dama-game-head');
    if (!gameHead) return null;

    let pin = document.getElementById('damaPin');
    if (pin) return pin;

    const timerWrap = gameHead.querySelector('.dama-timer-wrap');
    let tools = gameHead.querySelector('.dama-board-head-actions');
    if (!tools) {
      tools = document.createElement('div');
      tools.className = 'dama-board-head-actions';
      if (timerWrap) gameHead.insertBefore(tools, timerWrap);
      else gameHead.appendChild(tools);
    }

    pin = document.createElement('button');
    pin.id = 'damaPin';
    pin.className = 'button ghost small dama-pin-button';
    pin.type = 'button';
    pin.setAttribute('aria-pressed', 'false');
    pin.textContent = 'Fixar Dama';
    pin.addEventListener('click', () => setPinned(!document.body.classList.contains('dama-pinned')));
    tools.appendChild(pin);
    return pin;
  }

  function sync() {
    const preview = ensurePreview();
    const decision = ensureAcceptWindow();
    ensurePinButton();

    const actualGameVisible = !game.classList.contains('hidden');
    preview.classList.toggle('hidden', actualGameVisible);
    if (!actualGameVisible) renderPreviewBoard();

    syncAcceptSummary();
    const acceptOpen = Boolean(decision && !decision.classList.contains('hidden'));
    document.body.classList.toggle('dama-accept-open', acceptOpen);

    const result = document.getElementById('damaResult');
    if ((!actualGameVisible || (result && !result.classList.contains('hidden'))) && document.body.classList.contains('dama-pinned')) {
      setPinned(false, false);
    }
  }

  injectStyle();
  ensurePreview();
  ensureAcceptWindow();
  ensurePinButton();
  sync();

  const observer = new MutationObserver(sync);
  observer.observe(room, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });

  window.addEventListener('beforeunload', () => {
    document.body.classList.remove('dama-pinned', 'dama-accept-open');
  });
})();
