(() => {
  'use strict';

  const room = document.getElementById('damaRoom');
  const head = room?.querySelector('.dama-room-head');
  const game = document.getElementById('damaGame');
  const settingsSummary = document.getElementById('damaSettingsSummary');
  const guestDecision = document.getElementById('damaGuestDecision');
  const funding = document.getElementById('damaFunding');
  if (!room || !head || !game) return;

  function installStyles() {
    if (document.getElementById('damaLudoFlowStyle')) return;
    const style = document.createElement('style');
    style.id = 'damaLudoFlowStyle';
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
        overflow:hidden;
        text-overflow:ellipsis;
        white-space:nowrap;
      }
      .dama-room-head #damaRoomMeta{margin:0!important;font-size:.76rem!important}
      .dama-room-actions{align-self:start!important;justify-content:flex-end!important}
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
      .dama-room-preview-board .dama-piece{width:74%!important;height:74%!important}

      /* Dama usa o mesmo fluxo em janela do Ludo. */
      .dama-flow-modal{
        position:fixed;
        z-index:1700;
        inset:0;
        display:grid;
        place-items:center;
        padding:18px;
        background:rgba(0,0,0,.78);
        backdrop-filter:blur(8px);
      }
      .dama-flow-modal.hidden{display:none!important}
      .dama-flow-card{
        width:min(520px,100%);
        max-height:min(86vh,760px);
        overflow:auto;
        padding:26px;
        border:1px solid rgba(255,255,255,.13);
        border-radius:22px;
        background:linear-gradient(160deg,#17263d,#0c1727);
        box-shadow:0 30px 100px rgba(0,0,0,.65);
      }
      .dama-flow-card h2{margin:3px 0 8px;font-size:clamp(1.7rem,6vw,2.4rem)}
      .dama-flow-step{
        float:right;
        padding:5px 9px;
        border-radius:999px;
        background:rgba(255,255,255,.08);
        font-size:.75rem;
        font-weight:900;
      }
      .dama-flow-summary{display:grid;gap:7px;margin:16px 0;max-height:42vh;overflow:auto}
      .dama-flow-summary .dama-setting-chip{font-size:.82rem}
      .dama-flow-actions{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:18px}
      .dama-flow-value{
        margin:18px 0 6px;
        padding:16px;
        border:1px solid rgba(244,189,66,.4);
        border-radius:14px;
        background:rgba(244,189,66,.08);
        text-align:center;
        font-size:1.45rem;
        font-weight:900;
        color:#f4bd42;
      }
      body.dama-flow-open{overflow:hidden}
      #damaGuestDecision,#damaFunding{display:none!important}

      .dama-pin-row{
        display:flex;
        align-items:center;
        justify-content:center;
        margin:8px 0 2px;
      }
      #pinDama[aria-pressed="true"]{
        border-color:rgba(244,189,66,.65);
        background:rgba(244,189,66,.12);
        color:#ffd15a;
      }

      /* Fixar funciona tanto antes como durante a partida. */
      body.dama-pinned{overflow:auto!important}
      body.dama-pinned #jlGlobalStatusStrip,
      body.dama-pinned #ludoStatusStrip,
      body.dama-pinned #damaPlayers,
      body.dama-pinned #damaSettingsPanel,
      body.dama-pinned #damaDrawOffer,
      body.dama-pinned #damaResult,
      body.dama-pinned #damaGame>.dama-side,
      body.dama-pinned #jlGlobalAccountFooter,
      body.dama-pinned #playerArea{
        display:none!important;
      }
      body.dama-pinned.dama-game-active #damaRoom>.dama-room-head{
        display:none!important;
      }
      body.dama-pinned #damaRoom{
        display:block!important;
        margin-top:6px!important;
      }
      body.dama-pinned:not(.dama-game-active) #damaGame{
        display:none!important;
      }
      body.dama-pinned.dama-game-active #damaGame{
        display:block!important;
        width:100%!important;
        max-width:none!important;
        margin:0!important;
      }
      body.dama-pinned.dama-game-active #damaGame>.dama-board-panel{
        position:static!important;
        inset:auto!important;
        width:100%!important;
        max-width:none!important;
        margin:0!important;
        transform:none!important;
        overflow:visible!important;
      }
      body.dama-pinned.dama-game-active #damaBoard{
        width:min(100%,720px)!important;
        max-height:none!important;
        margin:8px auto 0!important;
      }

      @media(max-width:600px){
        .dama-room-head{padding:10px!important;gap:8px!important}
        .dama-room-actions .button{padding:7px 9px!important;font-size:.72rem!important}
        .dama-room-preview-board{border-width:3px!important}
        .dama-flow-modal{padding:10px}
        .dama-flow-card{padding:20px 16px;border-radius:18px}
        .dama-flow-actions{grid-template-columns:1fr}
        .dama-flow-actions .button{width:100%}
        body.dama-pinned .dama-shell{width:calc(100% - 10px)!important;margin-top:6px!important}
        body.dama-pinned.dama-game-active #damaGame>.dama-board-panel{padding:10px!important;border-radius:14px!important}
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

  function myColor() {
    const cards = [...document.querySelectorAll('#damaPlayers .dama-player')];
    const mine = cards.find((card) => /\bvocê\b/i.test(card.textContent || ''));
    if (mine?.querySelector('.dama-player-piece.red')) return 'red';
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

  function ensureAcceptModal() {
    let modal = document.getElementById('damaAcceptModal');
    if (modal) return modal;
    modal = document.createElement('div');
    modal.id = 'damaAcceptModal';
    modal.className = 'dama-flow-modal hidden';
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');
    modal.setAttribute('aria-labelledby', 'damaAcceptModalTitle');
    modal.innerHTML = `
      <div class="dama-flow-card">
        <span class="dama-flow-step">1 / 2</span>
        <p class="eyebrow">ANTES DE JOGAR</p>
        <h2 id="damaAcceptModalTitle">Aceitar regras</h2>
        <p class="muted">Leia as definições atuais desta sala. Não existe prazo para aceitar.</p>
        <div id="damaAcceptModalSummary" class="dama-flow-summary"></div>
        <div class="dama-flow-actions">
          <button id="damaModalDecline" class="button danger" type="button">Recusar</button>
          <button id="damaModalAccept" class="button success" type="button">Aceitar regras</button>
        </div>
      </div>`;
    document.body.appendChild(modal);
    modal.querySelector('#damaModalDecline').addEventListener('click', () => document.getElementById('damaDeclineSettings')?.click());
    modal.querySelector('#damaModalAccept').addEventListener('click', () => document.getElementById('damaAcceptSettings')?.click());
    return modal;
  }

  function ensureStakeModal() {
    let modal = document.getElementById('damaStakeModal');
    if (modal) return modal;
    modal = document.createElement('div');
    modal.id = 'damaStakeModal';
    modal.className = 'dama-flow-modal hidden';
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');
    modal.setAttribute('aria-labelledby', 'damaStakeModalTitle');
    modal.innerHTML = `
      <div class="dama-flow-card">
        <span class="dama-flow-step">2 / 2</span>
        <p class="eyebrow">CONFIRMAR APOSTA</p>
        <h2 id="damaStakeModalTitle">Aceitar valor</h2>
        <div id="damaStakeModalValue" class="dama-flow-value">—</div>
        <p class="muted">Confirme o valor para entrar na partida.</p>
        <div class="dama-flow-actions">
          <button id="damaStakeCancel" class="button ghost" type="button">Agora não</button>
          <button id="damaStakeConfirm" class="button success" type="button">Confirmar aposta</button>
        </div>
      </div>`;
    document.body.appendChild(modal);
    modal.querySelector('#damaStakeCancel').addEventListener('click', () => modal.classList.add('hidden'));
    modal.querySelector('#damaStakeConfirm').addEventListener('click', () => document.getElementById('damaFund')?.click());
    return modal;
  }

  function ensurePinPlacement(actualGameVisible) {
    const button = document.getElementById('pinDama');
    if (!button) return null;

    button.classList.add('small', 'dama-pin-button');
    button.classList.remove('hidden');

    if (!actualGameVisible) {
      const actions = head.querySelector('.dama-room-actions');
      if (actions && button.parentElement !== actions) actions.prepend(button);
      return button;
    }

    const boardPanel = game.querySelector('.dama-board-panel');
    if (!boardPanel) return button;
    let row = boardPanel.querySelector('.dama-pin-row');
    if (!row) {
      row = document.createElement('div');
      row.className = 'dama-pin-row';
      const board = document.getElementById('damaBoard');
      if (board) board.insertAdjacentElement('afterend', row);
      else boardPanel.appendChild(row);
    }
    if (button.parentElement !== row) row.appendChild(button);
    return button;
  }

  function syncDialogs() {
    const acceptModal = ensureAcceptModal();
    const stakeModal = ensureStakeModal();
    const acceptNeeded = Boolean(guestDecision && !guestDecision.classList.contains('hidden'));
    const fundingNeeded = Boolean(funding && !funding.classList.contains('hidden'));

    acceptModal.classList.toggle('hidden', !acceptNeeded);
    if (acceptNeeded) {
      const summary = document.getElementById('damaAcceptModalSummary');
      if (summary && settingsSummary) summary.innerHTML = settingsSummary.innerHTML;
    }

    if (!acceptNeeded) stakeModal.classList.toggle('hidden', !fundingNeeded);
    else stakeModal.classList.add('hidden');

    if (fundingNeeded) {
      const fundText = document.getElementById('damaFund')?.textContent || 'Confirmar aposta';
      const value = document.getElementById('damaStakeModalValue');
      if (value) value.textContent = fundText.replace(/^Confirmar\s*/i, '') || fundText;
    }

    document.body.classList.toggle('dama-flow-open', acceptNeeded || (!stakeModal.classList.contains('hidden')));
  }

  function sync() {
    const preview = ensurePreview();
    const actualGameVisible = !game.classList.contains('hidden');
    document.body.classList.toggle('dama-game-active', actualGameVisible);

    preview.classList.toggle('hidden', actualGameVisible);
    if (!actualGameVisible) renderPreviewBoard();

    ensurePinPlacement(actualGameVisible);
    syncDialogs();
  }

  installStyles();
  ensurePreview();
  ensureAcceptModal();
  ensureStakeModal();
  sync();

  const observer = new MutationObserver(sync);
  observer.observe(room, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
})();