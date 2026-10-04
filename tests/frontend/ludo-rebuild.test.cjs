'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const html = fs.readFileSync(path.join(root, 'ludo.html'), 'utf8');
const css = fs.readFileSync(path.join(root, 'ludo.css'), 'utf8');
const js = fs.readFileSync(path.join(root, 'ludo.js'), 'utf8');
const realtimePath = path.join(root, 'js/realtime/ludo.js');
const realtime = fs.existsSync(realtimePath) ? fs.readFileSync(realtimePath, 'utf8') : '';

const forbiddenRuntimeAssets = [
  'active-room-recovery.js',
  'room-authority-v1.js',
  'route-compat.js',
  'ludo-feature-loader.js',
  'ludo-sync.js',
  'js/ludo/state.js',
  'js/ludo/room-state.js',
  'js/ludo/movement-guard.js',
  'js/ludo/render.js',
  'js/ludo/animation.js',
  'js/ludo/voice.js'
];

test('Ludo usa um único controlador de jogo e nenhum patch legado no runtime', () => {
  assert.match(html, /<script src="\.\/ludo\.js\?v=20261004-rebuild1" defer><\/script>/);
  assert.match(html, /<link rel="stylesheet" href="\.\/ludo\.css\?v=20261004-rebuild1">/);
  for (const asset of forbiddenRuntimeAssets) {
    assert.doesNotMatch(html, new RegExp(asset.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  if (realtime) {
    assert.match(html, /js\/realtime\/ludo\.js\?v=20261004-rebuild1/);
    assert.doesNotMatch(realtime, /state\.room|classList|MutationObserver|JLLudoState/);
    assert.match(realtime, /handlers\.onSignal/);
  }
});

test('estado é único e sincronização concorrente é serializada', () => {
  assert.match(js, /const\s+state\s*=\s*\{/);
  assert.doesNotMatch(js, /JLLudoState\.create/);
  assert.doesNotMatch(js, /MutationObserver/);
  assert.doesNotMatch(js, /__JL_LUDO_ACTIVE_ROOM_RECOVERY__/);
  assert.doesNotMatch(js, /__JL_LUDO_ROOM_AUTHORITY/);

  const serializedWithPromise = /refreshPromise/.test(js) && /refreshQueued/.test(js) && /if\s*\(state\.refreshPromise\)/.test(js);
  const serializedWithFlag = /syncing\s*:\s*false/.test(js) && /pendingRefresh\s*:\s*false/.test(js);
  assert.equal(serializedWithPromise || serializedWithFlag, true, 'refresh do Ludo precisa ser serializado');
});

test('recuperação usa status e snapshot leve server-authoritative', () => {
  assert.match(js, /rpc\('jl_ludo_my_status'/);
  assert.match(js, /rpc\('jl_ludo_room_state_light'/);
  assert.match(js, /state\.room\s*=\s*(?:nextRoom|snapshot|base)/);
  assert.match(js, /state\.(?:roomIdHint|recoveringRoomId)\s*=\s*activeRoomId/);
  assert.match(html, /id="bootPanel"/);
  assert.match(html, /id="roomLoading"/);
  assert.match(js, /const\s+activeKnown\s*=\s*Boolean\(state\.(?:roomIdHint|recoveringRoomId)/);
  assert.match(js, /ui\.lobby.*toggle\('hidden',activeKnown\)/);
});

test('lobby e sala possuem controles essenciais', () => {
  for (const id of ['createRoomForm','joinCodeForm','queueForm','inviteList','publicChallengeList','room','leaveRoom','forfeitRoom','deadlineBar','deadlineClock','invitePanel','searchPlayerForm','waitingPlayers','ludoBoard']) {
    assert.match(html, new RegExp(`id="${id}"`));
  }
  assert.match(html, /id="(?:dice|rollDice)"/);
  assert.match(html, />Convidar</);
  assert.match(html, />Sair</);
  assert.match(html, />Desistir</);
  assert.match(html, /id="deadlineClock"/);
});

test('ações críticas permanecem no servidor', () => {
  for (const rpcName of [
    'jl_ludo_create_room',
    'jl_ludo_join_public_room',
    'jl_ludo_invite',
    'jl_ludo_accept_invite',
    'jl_ludo_cancel_or_leave',
    'jl_ludo_forfeit',
    'jl_ludo_update_rules',
    'jl_ludo_accept_rules',
    'jl_ludo_commit_stake',
    'jl_ludo_roll',
    'jl_ludo_move',
    'jl_ludo_process_timeouts',
    'jl_ludo_reenter',
    'jl_ludo_rematch_v2'
  ]) assert.match(js, new RegExp(`rpc\\('${rpcName}'`));
});

test('tabuleiro reconstruído preserva geometria e quatro cores', () => {
  assert.match(js, /const\s+PATH\s*=\s*\[\[6,1\]/);
  assert.match(js, /const\s+START\s*=\s*\{\s*red:0,\s*green:13,\s*yellow:26,\s*blue:39\s*\}/);
  assert.match(js, /const\s+SAFE\s*=\s*new Set\(\[0,8,13,21,26,34,39,47\]\)/);
  assert.match(js, /(?:FINISH|FINISH_CELL)\s*=\s*\{\s*red:\[7,6\],\s*green:\[6,7\],\s*yellow:\[7,8\],\s*blue:\[8,7\]\s*\}/);
  assert.match(css, /--red:#ef4c55/);
  assert.match(css, /--green:#38c783/);
  assert.match(css, /--yellow:#f1c843/);
  assert.match(css, /--blue:#4c8bf5/);
  assert.match(css, /grid-template-columns:repeat\(15,1fr\)/);
});

test('timeout não é tratado como desistência no cliente', () => {
  assert.match(js, /jl_ludo_process_timeouts/);
  assert.match(js, /jl_ludo_forfeit/);
  assert.doesNotMatch(js, /timeout.*forfeit/i);
  assert.doesNotMatch(js, /timeout.*elimin/i);
});
