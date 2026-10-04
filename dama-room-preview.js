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
      @media(max-width:520px){
        .dama-room-head{
          grid-template-columns:minmax(0,1fr) auto!important;
          padding:10px!important;
          gap:8px!important;
        }
        .dama-room-actions .button{padding:7px 9px!important;font-size:.72rem!important}
        .dama-room-preview-board{border-width:3px!important}
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

  function sync() {
    const preview = ensurePreview();
    const actualGameVisible = !game.classList.contains('hidden');
    preview.classList.toggle('hidden', actualGameVisible);
    if (!actualGameVisible) renderPreviewBoard();
  }

  injectStyle();
  ensurePreview();
  sync();

  const observer = new MutationObserver(sync);
  observer.observe(room, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
})();
