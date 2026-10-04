function n(v, fallback = 0) {
  const x = Number(v);
  return Number.isFinite(x) ? x : fallback;
}

function centerScore(row, col) {
  const dr = Math.abs(3.5 - row);
  const dc = Math.abs(3.5 - col);
  return Math.max(0, 7 - (dr + dc));
}

function routeScore(route, piece, myColor) {
  const toRow = n(route.to_row);
  const toCol = n(route.to_col);
  const captures = n(route.capture_count, Array.isArray(route.captures) ? route.captures.length : 0);
  const isKing = Boolean(piece?.is_king);
  const promotes = !isKing && ((myColor === 'red' && toRow === 7) || (myColor !== 'red' && toRow === 0));

  let score = captures * 10000;
  if (promotes) score += 4000;
  score += centerScore(toRow, toCol) * (isKing ? 20 : 35);
  if (toCol === 0 || toCol === 7) score += isKing ? -25 : 30;

  const path = Array.isArray(route.path) ? route.path : [];
  score += Math.min(path.length, 12) * 3;
  return score;
}

export function analyze(snapshot) {
  const legal = Array.isArray(snapshot?.legal_moves) ? snapshot.legal_moves : [];
  if (!legal.length) throw new Error('NO_LEGAL_MOVES');

  const me = String(snapshot?.identity?.player_id || '');
  const mine = (Array.isArray(snapshot?.players) ? snapshot.players : []).find(
    (p) => String(p?.player_id || '') === me
  );
  const myColor = String(mine?.color || 'white');
  const pieces = new Map(
    (Array.isArray(snapshot?.pieces) ? snapshot.pieces : []).map((p) => [String(p?.id || ''), p])
  );

  let best = legal[0];
  let bestScore = -Infinity;
  for (const route of legal) {
    const score = routeScore(route, pieces.get(String(route?.piece_id || '')), myColor);
    if (score > bestScore || (score === bestScore && String(route?.route_id || '') < String(best?.route_id || ''))) {
      best = route;
      bestScore = score;
    }
  }

  const path = Array.isArray(best?.path) && best.path.length >= 2
    ? best.path
    : [
        { row: n(best?.from_row), col: n(best?.from_col) },
        { row: n(best?.to_row), col: n(best?.to_col) }
      ];

  return {
    route_id: best.route_id,
    piece_id: best.piece_id,
    path,
    from: { row: n(best.from_row), col: n(best.from_col) },
    to: { row: n(best.to_row), col: n(best.to_col) },
    capture_count: n(best.capture_count),
    depth: 0,
    nodes: legal.length,
    elapsed_ms: 0,
    score: bestScore,
    board_version: snapshot?.room?.board_version ?? null,
    move_seq: snapshot?.room?.move_seq ?? null,
    mode: 'resource_safe'
  };
}
