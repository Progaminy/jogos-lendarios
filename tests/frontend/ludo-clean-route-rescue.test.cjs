'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const routeCompat = fs.readFileSync(path.join(root, 'js/ludo/route-compat.js'), 'utf8');
const rescue = fs.readFileSync(path.join(root, 'js/ludo/active-room-recovery.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'ludo.html'), 'utf8');

test('rota limpa /ludo repara o refresh antes de iniciar o Ludo', () => {
  assert.match(routeCompat, /endsWith\('\/ludo'\)/);
  assert.match(routeCompat, /genericRefresh\.id = 'refreshLobby'/);
  assert.match(routeCompat, /link\.dataset\.jlNav === 'tabuleiro'/);
});

test('resgate de sala busca snapshot autoritativo e força a sala visível', () => {
  assert.match(rescue, /jl_ludo_room_state_light/);
  assert.match(rescue, /jl_ludo_room_state/);
  assert.match(rescue, /room\.classList\.remove\('hidden'\)/);
  assert.match(rescue, /document\.querySelector\('\.invite-panel'\)/);
  assert.match(rescue, /jl_ludo_find_players/);
  assert.match(rescue, /jl_ludo_invite/);
  assert.match(rescue, /jl_ludo_cancel_or_leave/);
});

test('compatibilidade de rota é carregada antes do ludo.js', () => {
  const compatIndex = html.indexOf('js/ludo/route-compat.js');
  const ludoIndex = html.indexOf('./ludo.js');
  assert.ok(compatIndex >= 0, 'route-compat.js precisa estar no HTML');
  assert.ok(ludoIndex >= 0, 'ludo.js precisa estar no HTML');
  assert.ok(compatIndex < ludoIndex, 'route-compat.js deve executar antes de ludo.js');
});
