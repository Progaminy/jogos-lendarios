(() => {
  'use strict';

  function create({
    state,
    els,
    path,
    start,
    home,
    base,
    safe,
    finishStep,
    trackLastStep,
    homeFirstStep,
    roomPlayers,
    me,
    moveToken
  }) {
    function decorateClassicBoard(cells) {
      const at = (r, c) => cells[r * 15 + c];
      const yards = [
        ['red', 1, 1],
        ['green', 1, 10],
        ['yellow', 10, 10],
        ['blue', 10, 1]
      ];
      for (const [color, r0, c0] of yards) {
        for (let r = r0; r < r0 + 4; r += 1) {
          for (let c = c0; c < c0 + 4; c += 1) at(r, c).classList.add('yard', `yard-${color}`);
        }
      }
      at(7, 0).classList.add('entry-arrow', 'entry-red');
      at(0, 7).classList.add('entry-arrow', 'entry-green');
      at(7, 14).classList.add('entry-arrow', 'entry-yellow');
      at(14, 7).classList.add('entry-arrow', 'entry-blue');
    }

    function classicCenter() {
      const center = document.createElement('div');
      center.className = 'ludo-center';
      center.setAttribute('aria-hidden', 'true');
      return center;
    }

    function makeCells() {
      const cells = [];
      for (let i = 0; i < 225; i += 1) {
        const d = document.createElement('div');
        d.className = 'cell';
        d.dataset.row = String(Math.floor(i / 15));
        d.dataset.col = String(i % 15);
        cells.push(d);
      }
      const at = (row, col) => cells[row * 15 + col];

      for (let rr = 0; rr < 6; rr += 1) for (let cc = 0; cc < 6; cc += 1) at(rr, cc).classList.add('base', 'red');
      for (let rr = 0; rr < 6; rr += 1) for (let cc = 9; cc < 15; cc += 1) at(rr, cc).classList.add('base', 'green');
      for (let rr = 9; rr < 15; rr += 1) for (let cc = 9; cc < 15; cc += 1) at(rr, cc).classList.add('base', 'yellow');
      for (let rr = 9; rr < 15; rr += 1) for (let cc = 0; cc < 6; cc += 1) at(rr, cc).classList.add('base', 'blue');

      path.forEach(([r, c], i) => {
        at(r, c).classList.add('path');
        if (safe.has(i)) {
          const cell = at(r, c);
          cell.classList.add('safe');
          for (const [color, startIndex] of Object.entries(start)) {
            const secondSafe = (Number(startIndex) + 8) % path.length;
            if (i === Number(startIndex) || i === secondSafe) {
              cell.classList.add(`safe-${color}`);
              break;
            }
          }
        }
      });
      Object.entries(home).forEach(([color, coords]) => {
        coords.forEach(([r, c]) => at(r, c).classList.add(`home-${color}`));
      });
      for (let r = 6; r <= 8; r += 1) for (let c = 6; c <= 8; c += 1) at(r, c).classList.add('center');

      decorateClassicBoard(cells);
      return { cells, at };
    }

    function renderStaticBoard(target, pieces = ['red', 'green', 'yellow', 'blue']) {
      if (!target) return;
      const { cells, at } = makeCells();
      for (const item of pieces) {
        const color = typeof item === 'string' ? item : item.color;
        const pawnStyle = ['current','classic','video'].includes(item?.pawn_style) ? item.pawn_style : 'current';
        const pawnCount=Math.max(1,Math.min(4,+item?.pawn_count||4));
        if (!base[color]) continue;
        base[color].slice(0,pawnCount).forEach(([r, c], index) => {
          const p = document.createElement('span');
          p.className = `piece ${color} preview-piece pawn-style-${pawnStyle}`;
          p.textContent = '';
          p.dataset.tokenNo = String(index + 1);
          p.setAttribute('aria-hidden', 'true');
          at(r, c).appendChild(p);
        });
      }
      target.replaceChildren(...cells, classicCenter());
    }

    function renderLobbyBoard() {
      renderStaticBoard(els.ludoLobbyBoard);
    }

    function renderPregameBoard() {
      const pieces = roomPlayers()
        .filter((p) => p.status !== 'left' && base[p.color])
        .map(p=>({color:p.color,pawn_style:p.pawn_style||'current',pawn_count:state.room?.room?.pawn_count||4}));
      renderStaticBoard(els.ludoBoard, pieces);
    }

    function renderBoard(legal = []) {
      if (state.animating && els.ludoBoard?.childElementCount) return;

      const { cells, at } = makeCells();
      const players = roomPlayers();
      const grouped = new Map();
      const finished = [];

      for (const t of state.room.tokens || []) {
        const p = players.find((x) => x.player_id === t.player_id);
        if (!p) continue;

        if (Number(t.steps) >= finishStep) {
          finished.push({ t, p });
          continue;
        }

        let coord;
        if (t.steps === -1) coord = base[p.color][t.token_no - 1];
        else if (t.steps <= trackLastStep) coord = path[(start[p.color] + t.steps) % 52];
        else coord = home[p.color][Math.max(0, t.steps - homeFirstStep)];

        const key = coord.join(',');
        if (!grouped.has(key)) grouped.set(key, []);
        grouped.get(key).push({ t, p, coord });
      }

      for (const list of grouped.values()) {
        const [r, c] = list[0].coord;
        const cell = at(r, c);
        if (list.length > 1) cell.classList.add('multi');

        const legalMineInCell = list.filter((it) => it.p.player_id === me() && legal.includes(Number(it.t.token_no)));
        if (list.length > 1 && legalMineInCell.length) {
          cell.classList.add('has-legal-piece');
          cell.title = 'Toque nesta casa para mover um dos seus peões jogáveis.';
          cell.addEventListener('click', (event) => {
            if (event.target.closest('.piece.legal')) return;
            moveToken(Number(legalMineInCell[0].t.token_no));
          });
        }

        list.forEach((it, idx) => {
          const b = document.createElement('button');
          b.type = 'button';
          const isMine = it.p.player_id === me();
          const isLegalMine = isMine && legal.includes(Number(it.t.token_no));
          const pawnStyle=['current','classic','video'].includes(it.p.pawn_style)?it.p.pawn_style:'current';
          b.className = `piece ${it.p.color} pawn-style-${pawnStyle} ${isMine ? 'mine' : ''} ${isLegalMine ? 'legal' : ''}`;
          b.textContent = '';
          b.title = `${it.p.code} · peão ${it.t.token_no}`;
          b.dataset.playerId = String(it.p.player_id);
          b.dataset.tokenNo = String(it.t.token_no);

          const colorName = ({
            red: 'vermelho',
            green: 'verde',
            yellow: 'amarelo',
            blue: 'azul'
          })[it.p.color] || it.p.color;

          b.tabIndex = isLegalMine ? 0 : -1;
          b.setAttribute(
            'aria-label',
            isLegalMine
              ? `Peão ${it.t.token_no}, ${colorName}, jogável. Pressione Enter ou Espaço para mover.`
              : `Peão ${it.t.token_no}, ${colorName}, não jogável neste momento.`
          );

          if (isLegalMine) {
            b.setAttribute('aria-keyshortcuts', 'Enter Space');
            b.removeAttribute('aria-disabled');
          } else {
            b.setAttribute('aria-disabled', 'true');
          }

          if (list.length > 1) {
            const layouts = {
              2: [[-44, 0], [44, 0]],
              3: [[-42, -30], [42, -30], [0, 38]],
              4: [[-42, -34], [42, -34], [-42, 34], [42, 34]]
            };
            const pos = (layouts[Math.min(4, list.length)] || layouts[4])[idx % Math.min(4, list.length)];
            b.style.setProperty('--dx', `${pos[0]}%`);
            b.style.setProperty('--dy', `${pos[1]}%`);
          }

          b.style.zIndex = isLegalMine ? '25' : (isMine ? '12' : String(7 + idx));
          if (isLegalMine) b.addEventListener('click', () => moveToken(it.t.token_no));
          cell.appendChild(b);
        });
      }

      const center = classicCenter();
      const finishedByColor = new Map();
      for (const it of finished) {
        if (!finishedByColor.has(it.p.color)) finishedByColor.set(it.p.color, []);
        finishedByColor.get(it.p.color).push(it);
      }

      for (const [color, list] of finishedByColor.entries()) {
        list.forEach((it, idx) => {
          const b = document.createElement('button');
          b.type = 'button';
          b.disabled = true;
          const pawnStyle=['current','classic','video'].includes(it.p.pawn_style)?it.p.pawn_style:'current';
          b.className = `piece ${color} pawn-style-${pawnStyle} finish-piece`;
          b.textContent = '';
          b.title = `${it.p.code} · peão ${it.t.token_no} · chegou`;
          b.dataset.playerId = String(it.p.player_id);
          b.dataset.tokenNo = String(it.t.token_no);
          b.dataset.finishColor = color;
          b.dataset.finishIndex = String(idx);
          center.appendChild(b);
        });
      }

      els.ludoBoard.replaceChildren(...cells, center);
    }

    return Object.freeze({
      renderStaticBoard,
      renderLobbyBoard,
      renderPregameBoard,
      renderBoard
    });
  }

  window.JLLudoRender = Object.freeze({ create });
})();