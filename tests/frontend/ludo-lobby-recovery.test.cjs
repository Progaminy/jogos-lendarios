'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'js/platform/ludo-feature-loader.js'), 'utf8');

test('Ludo recupera lobby quando existe sessão mas nenhuma sala está visível', () => {
  assert.match(source, /function restoreLobbyIfStranded\(\)/);
  assert.match(source, /if\(!hasToken\(\)\)return;/);
  assert.match(source, /if\(roomVisible\|\|lobbyVisible\)return;/);
  assert.match(source, /lobby\.classList\.remove\('hidden'\)/);
  assert.match(source, /notificationCenter/);
});

test('recuperação é repetida após carregamento e retorno à página', () => {
  assert.match(source, /setTimeout\(run,1800\)/);
  assert.match(source, /setTimeout\(run,4200\)/);
  assert.match(source, /pageshow/);
  assert.match(source, /jl-player-session-changed/);
});
