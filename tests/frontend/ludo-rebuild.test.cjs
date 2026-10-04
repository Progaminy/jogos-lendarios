'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const html = fs.readFileSync(path.join(root, 'ludo.html'), 'utf8');
const css = fs.readFileSync(path.join(root, 'ludo.css'), 'utf8');
const js = fs.readFileSync(path.join(root, 'ludo.js'), 'utf8');

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
  'js/ludo/voice.js',
  'js/realtime/ludo.js'
];

test('Ludo usa somente o controlador reconstruído no runtime', () => {
  assert.match(html, /<script src="\.\/ludo\.js\?v=20261004-rebuild1" defer><\/script>/);
  assert.match(html, /<link rel="stylesheet" href="\.\/ludo\.css\?v=20261004-rebuild1">/);
  for (const asset of forbiddenRuntimeAssets) assert.doesNotMatch(html, new RegExp(asset.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('estado é único e sincronização concorrente é serializada', () => {
  assert.match(js, /const state = \{/);
  assert.match(js, /syncing: false/);
  assert.match(js, /pendingRefresh: false/);
  assert.match(js, /if \(state\.syncing\) \{\s*state\.pendingRefresh = true;/);
  assert.match(js, /do \{\s*state\.pendingRefresh = false;\s*await performSync\(reason\);\s*\} while \(state\.pendingRefresh\);/);
  assert.doesNotMatch(js, /MutationObserver/);
  assert.doesNotMatch(js, /JLLudoState\.create/);
  assert.doesNotMatch(js, /__JL_LUDO_ACTIVE_ROOM_RECOVERY__/);
  assert.doesNotMatch(js, /__JL_LUDO_ROOM_AUTHORITY/);
});

test('recuperação usa status e snapshot leve server-authoritative', () => {
  assert.match(js, /rpc\('jl_ludo_my_status'/);
  assert.match(js, /rpc\('jl_ludo_room_state_light'/);
  assert.match(js, /state\.room = snapshot/);
  assert.match(js, /state\.recoveringRoomId = activeRoomId/);
  assert.match(html, /id="bootPanel"/);
  assert.match(html, /id="bootMessage"/);
});

test('lobby e sala possuem controles essenciais', () => {
  for (const id of ['createRoomForm','joinCodeForm','queueForm','inviteList','publicChallengeList','room','leaveRoom','forfeitRoom','deadlineBar','deadlineClock','invitePanel','searchPlayerForm','waitingPlayers','rollDice','ludoBoard']) {
    assert.match(html, new RegExp(`id="${id}"`));
  }
  assert.match(html, />Convidar</);
  assert.match(html, />Sair</);
  assert.match(html, />Desistir</);
  assert.match(html, /Contagem/);
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
  assert.match(js, /const PATH = \[\[6,1\]/);
  assert.match(js, /const START = \{ red:0, green:13, yellow:26, blue:39 \}/);
  assert.match(js, /const SAFE = new Set\(\[0,8,13,21,26,34,39,47\]\)/);
  assert.match(js, /const FINISH = \{ red:\[7,6\], green:\[6,7\], yellow:\[7,8\], blue:\[8,7\] \}/);
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
