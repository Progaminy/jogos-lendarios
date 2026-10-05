import { analyze as analyzeBase } from "./engine-fast.js";

const BOARD = 8;
const DIRS = [[-1, -1], [-1, 1], [1, -1], [1, 1]];
const n = (value, fallback = 0) => Number.isFinite(Number(value)) ? Number(value) : fallback;
const routeId = (route) => String(route?.route_id ?? '');
const sqKey = (row, col) => `${Number(row)},${Number(col)}`;
const inside = (row, col) => row >= 0 && row < BOARD && col >= 0 && col < BOARD;

function currentPlayer(snapshot) {
  const me = String(snapshot?.identity?.player_id || '');
  return (snapshot?.players || []).find((player) => String(player?.player_id || '') === me) || null;
}

function movingPiece(snapshot, route) {
  const me = String(snapshot?.identity?.player_id || '');
  const pieceId = String(route?.piece_id || '');
  const pieces = Array.isArray(snapshot?.pieces) ? snapshot.pieces : [];
  return pieces.find((piece) => String(piece?.id || '') === pieceId)
    || pieces.find((piece) => String(piece?.player_id || '') === me
      && n(piece?.row) === n(route?.from_row)
      && n(piece?.col) === n(route?.from_col))
    || null;
}

function promotes(snapshot, route) {
  const piece = movingPiece(snapshot, route);
  if (!piece || piece.is_king) return false;
  const mine = currentPlayer(snapshot);
  const targetRow = mine?.color === 'red' ? 7 : 0;
  return n(route?.to_row, -1) === targetRow;
}

function boardAfter(snapshot, route) {
  const me = String(snapshot?.identity?.player_id || '');
  const board = new Map();
  const pieces = Array.isArray(snapshot?.pieces) ? snapshot.pieces : [];
  const captured = new Set((route?.captures || []).map((id) => String(id)));
  const moving = movingPiece(snapshot, route);

  for (const piece of pieces) {
    if (captured.has(String(piece?.id || ''))) continue;
    if (moving && String(piece?.id || '') === String(moving.id || '')) continue;
    board.set(sqKey(piece?.row, piece?.col), {
      id: String(piece?.id || ''),
      playerId: String(piece?.player_id || ''),
      king: Boolean(piece?.is_king),
      mine: String(piece?.player_id || '') === me
    });
  }

  if (moving) {
    board.set(sqKey(route?.to_row, route?.to_col), {
      id: String(moving.id || ''),
      playerId: String(moving.player_id || ''),
      king: Boolean(moving.is_king) || promotes(snapshot, route),
      mine: true,
      moved: true
    });
  }

  return board;
}

function movedPieceCaptureRisk(snapshot, route) {
  const board = boardAfter(snapshot, route);
  const targetRow = n(route?.to_row, -1);
  const targetCol = n(route?.to_col, -1);
  if (!inside(targetRow, targetCol)) return 0;
  let attackers = 0;

  for (const [key, piece] of board.entries()) {
    if (piece.mine) continue;
    const [rRaw, cRaw] = key.split(',');
    const row = Number(rRaw), col = Number(cRaw);
    if (!piece.king) {
      for (const [dr, dc] of DIRS) {
        if (row + dr !== targetRow || col + dc !== targetCol) continue;
        const landingRow = row + 2 * dr;
        const landingCol = col + 2 * dc;
        if (inside(landingRow, landingCol) && !board.has(sqKey(landingRow, landingCol))) attackers++;
      }
      continue;
    }

    for (const [dr, dc] of DIRS) {
      let rr = row + dr, cc = col + dc;
      let first = null;
      while (inside(rr, cc)) {
        const occupant = board.get(sqKey(rr, cc));
        if (occupant) {
          first = { row: rr, col: cc, occupant };
          break;
        }
        rr += dr;
        cc += dc;
      }
      if (!first || first.row !== targetRow || first.col !== targetCol) continue;
      rr = first.row + dr;
      cc = first.col + dc;
      if (inside(rr, cc) && !board.has(sqKey(rr, cc))) attackers++;
    }
  }
  return attackers;
}

function centrality(row, col) {
  return Math.max(0, 7 - (Math.abs(3.5 - row) + Math.abs(3.5 - col)));
}

function routePriority(snapshot, route) {
  const piece = movingPiece(snapshot, route);
  const fromRow = n(route?.from_row), fromCol = n(route?.from_col);
  const toRow = n(route?.to_row), toCol = n(route?.to_col);
  const distance = Math.max(Math.abs(toRow - fromRow), Math.abs(toCol - fromCol));
  const captureCount = n(route?.capture_count, Array.isArray(route?.captures) ? route.captures.length : 0);
  const risk = movedPieceCaptureRisk(snapshot, route);
  let score = captureCount * 1800;
  if (promotes(snapshot, route)) score += 5200;
  if (piece?.is_king) score += centrality(toRow, toCol) * 18 - distance * 9;
  else {
    const mine = currentPlayer(snapshot);
    const progress = mine?.color === 'red' ? toRow : (7 - toRow);
    score += progress * 22 + centrality(toRow, toCol) * 5;
  }
  score -= risk * 2400;
  return score;
}

function confidence(result) {
  if (result?.proven) return 'proven';
  const stable = n(result?.stable_rounds);
  if (stable >= 2) return 'high';
  if (stable >= 1) return 'medium';
  return 'guarded';
}

function verificationPlan(snapshot, primary) {
  const roots = Array.isArray(snapshot?.legal_moves) ? snapshot.legal_moves : [];
  const primaryRoot = roots.find((route) => routeId(route) === String(primary?.route_id ?? '')) || null;
  if (!primaryRoot || roots.length <= 1) return null;

  const alternatives = roots.filter((route) => routeId(route) !== routeId(primaryRoot));
  const promotionAlternative = alternatives.some((route) => promotes(snapshot, route));
  const pieces = Array.isArray(snapshot?.pieces) ? snapshot.pieces.length : 24;
  const unstable = !primary?.proven && n(primary?.stable_rounds) < 2;
  const crowdedEndgameChoice = pieces <= 10 && roots.length >= 4 && unstable;

  if (!promotionAlternative && !crowdedEndgameChoice) return null;

  const challengers = alternatives
    .map((route) => ({ route, score: routePriority(snapshot, route) }))
    .sort((a, b) => b.score - a.score)
    .slice(0, 2)
    .map((entry) => entry.route);

  if (!challengers.length) return null;
  return {
    primaryRoot,
    challengers,
    reason: promotionAlternative ? 'promotion_guard' : 'endgame_stability'
  };
}

export function analyze(snapshot) {
  const started = performance.now();
  const primary = analyzeBase(snapshot);
  const plan = verificationPlan(snapshot, primary);
  if (!plan) {
    return {
      ...primary,
      mode: 'strategic_v13_guarded',
      verifier: 'selective_head_to_head',
      verified: false,
      corrected: false,
      confidence: confidence(primary),
      total_elapsed_ms: Math.round(performance.now() - started)
    };
  }

  try {
    const verifySnapshot = {
      ...snapshot,
      legal_moves: [plan.primaryRoot, ...plan.challengers]
    };
    const verified = analyzeBase(verifySnapshot);
    const corrected = String(verified?.route_id ?? '') !== String(primary?.route_id ?? '');
    return {
      ...verified,
      mode: 'strategic_v13_verified',
      verifier: 'selective_head_to_head',
      verified: true,
      corrected,
      base_route_id: primary?.route_id ?? null,
      challenger_route_ids: plan.challengers.map((route) => route.route_id),
      verification_reason: plan.reason,
      base_depth: primary?.depth ?? null,
      confidence: confidence(verified),
      total_elapsed_ms: Math.round(performance.now() - started)
    };
  } catch (error) {
    return {
      ...primary,
      mode: 'strategic_v13_guarded',
      verifier: 'selective_head_to_head',
      verified: false,
      corrected: false,
      verification_error: error instanceof Error ? error.message : 'verification_failed',
      confidence: confidence(primary),
      total_elapsed_ms: Math.round(performance.now() - started)
    };
  }
}

export const __test = { promotes, movedPieceCaptureRisk, routePriority, verificationPlan };
