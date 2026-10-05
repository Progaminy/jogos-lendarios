const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const enginePath = path.join(root, 'supabase/functions/jogos-dama-engine/engine-verified.js');
const indexPath = path.join(root, 'supabase/functions/jogos-dama-engine/index.ts');

async function loadEngine() {
  let source = fs.readFileSync(enginePath, 'utf8');
  source = source.replace(
    'import { analyze as analyzeBase } from "./engine-fast.js";',
    `const analyzeBase = (snapshot) => {
      globalThis.__jlBaseCalls = (globalThis.__jlBaseCalls || 0) + 1;
      const routes = Array.isArray(snapshot?.legal_moves) ? snapshot.legal_moves : [];
      if (snapshot?.__stable) return { route_id: routes[0]?.route_id, depth: 12, stable_rounds: 3, proven: false };
      if (routes.length > 3) return { route_id: 'normal', depth: 7, stable_rounds: 0, proven: false };
      const promo = routes.find((route) => String(route?.route_id) === 'promo');
      return { route_id: promo?.route_id || routes[0]?.route_id, depth: 13, stable_rounds: 2, proven: false };
    };`
  );
  const url = `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`;
  return import(url);
}

function promotionSnapshot(extra = {}) {
  return {
    identity: { player_id: 'me' },
    players: [
      { player_id: 'me', color: 'red', seat: 2 },
      { player_id: 'op', color: 'white', seat: 1 }
    ],
    pieces: [
      { id: 'p1', player_id: 'me', row: 6, col: 1, is_king: false },
      { id: 'p2', player_id: 'me', row: 5, col: 4, is_king: false },
      { id: 'e1', player_id: 'op', row: 3, col: 2, is_king: false },
      { id: 'e2', player_id: 'op', row: 2, col: 5, is_king: false }
    ],
    legal_moves: [
      { route_id: 'normal', piece_id: 'p2', from_row: 5, from_col: 4, to_row: 6, to_col: 5, capture_count: 0, captures: [] },
      { route_id: 'promo', piece_id: 'p1', from_row: 6, from_col: 1, to_row: 7, to_col: 0, capture_count: 0, captures: [] },
      { route_id: 'other', piece_id: 'p2', from_row: 5, from_col: 4, to_row: 6, to_col: 3, capture_count: 0, captures: [] },
      { route_id: 'other2', piece_id: 'p2', from_row: 5, from_col: 4, to_row: 4, to_col: 3, capture_count: 0, captures: [] }
    ],
    ...extra
  };
}

test('Dama v13 rechecks an ignored immediate promotion and can correct the hint', async () => {
  globalThis.__jlBaseCalls = 0;
  const engine = await loadEngine();
  const result = engine.analyze(promotionSnapshot());
  assert.equal(globalThis.__jlBaseCalls, 2);
  assert.equal(result.route_id, 'promo');
  assert.equal(result.verified, true);
  assert.equal(result.corrected, true);
  assert.equal(result.verification_reason, 'promotion_guard');
  assert.ok(result.challenger_route_ids.includes('promo'));
});

test('Dama v13 keeps a stable hint fast instead of always spending a second search', async () => {
  globalThis.__jlBaseCalls = 0;
  const engine = await loadEngine();
  const result = engine.analyze(promotionSnapshot({
    __stable: true,
    legal_moves: [
      { route_id: 'normal', piece_id: 'p2', from_row: 5, from_col: 4, to_row: 6, to_col: 5, capture_count: 0, captures: [] },
      { route_id: 'other', piece_id: 'p2', from_row: 5, from_col: 4, to_row: 6, to_col: 3, capture_count: 0, captures: [] }
    ]
  }));
  assert.equal(globalThis.__jlBaseCalls, 1);
  assert.equal(result.verified, false);
  assert.equal(result.mode, 'strategic_v13_guarded');
  assert.equal(result.confidence, 'high');
});

test('Dama edge function uses the verified v13 engine', () => {
  const source = fs.readFileSync(indexPath, 'utf8');
  assert.match(source, /import \{ analyze \} from "\.\/engine-verified\.js";/);
});
