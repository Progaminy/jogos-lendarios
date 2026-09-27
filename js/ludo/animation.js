(() => {
  'use strict';

  function create({
    els,
    path,
    start,
    home,
    base,
    finishCell,
    trackLastStep,
    homeFirstStep,
    homeLastStep,
    finishStep,
    stepMs,
    playStepSound
  }) {
    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    function tokenCoord(color, step, tokenNo) {
      if (step === -1) return base[color]?.[Number(tokenNo) - 1] || null;
      if (step <= trackLastStep) return path[(start[color] + step) % 52];
      if (step <= homeLastStep) return home[color]?.[step - homeFirstStep] || null;
      if (step === finishStep) return finishCell[color] || [7, 7];
      return finishCell[color] || [7, 7];
    }

    async function animateTokenPath(playerId, tokenNo, color, fromSteps, toSteps) {
      if (!els.ludoBoard || !Number.isFinite(fromSteps) || !Number.isFinite(toSteps) || toSteps <= fromSteps) return;
      const selector = `[data-player-id="${CSS.escape(String(playerId))}"][data-token-no="${Number(tokenNo)}"]`;
      const piece = els.ludoBoard.querySelector(selector);
      if (!piece) return;

      const totalSteps = toSteps - fromSteps;
      els.ludoBoard.classList.add('piece-moving');
      piece.classList.add('path-moving');
      els.rollDice.disabled = true;
      let visualIndex = 0;

      try {
        for (let step = fromSteps + 1; step <= toSteps; step += 1) {
          const coord = tokenCoord(color, step, tokenNo);
          if (!coord) continue;
          const cell = els.ludoBoard.querySelector(`[data-row="${coord[0]}"][data-col="${coord[1]}"]`);
          if (!cell) continue;

          visualIndex += 1;
          els.moveHint.textContent = `Peão em movimento · ${visualIndex}/${totalSteps}`;
          piece.style.setProperty('--dx', '0%');
          piece.style.setProperty('--dy', '0%');
          cell.appendChild(piece);
          piece.classList.remove('step-hop');
          void piece.offsetWidth;
          piece.classList.add('step-hop');
          playStepSound(visualIndex);
          await wait(stepMs);
        }
      } finally {
        piece.classList.remove('step-hop', 'path-moving');
        els.ludoBoard.classList.remove('piece-moving');
      }
    }

    function detectForwardMove(previous, next) {
      if (!previous?.tokens || !next?.tokens) return null;
      const prev = new Map(previous.tokens.map((t) => [`${t.player_id}:${t.token_no}`, Number(t.steps)]));
      for (const t of next.tokens) {
        const from = prev.get(`${t.player_id}:${t.token_no}`);
        const to = Number(t.steps);
        if (from === undefined) continue;
        if ((from === -1 && to === 0) || (from >= 0 && to > from)) {
          const p = (next.players || []).find((x) => x.player_id === t.player_id);
          if (p) return {
            playerId: t.player_id,
            tokenNo: Number(t.token_no),
            color: p.color,
            fromSteps: from,
            toSteps: to
          };
        }
      }
      return null;
    }

    return Object.freeze({ tokenCoord, animateTokenPath, detectForwardMove });
  }

  window.JLLudoAnimation = Object.freeze({ create });
})();