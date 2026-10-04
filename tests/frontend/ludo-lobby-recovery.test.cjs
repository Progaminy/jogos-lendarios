'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'js/platform/ludo-feature-loader.js'), 'utf8');

test('Ludo recupera lobby quando existe sessão mas nenhuma sala está visível', () => {
  assert.match(source, /function restoreLobbyIfStranded\(force=false\)/);
  assert.match(source, /if\(!hasToken\(\)\)return;/);
  assert.match(source, /if\(roomVisible\|\|lobbyVisible\)return;/);
  assert.match(source, /function showLobby\(\)/);
  assert.match(source, /lobby\.classList\.remove\('hidden'\)/);
  assert.match(source, /notificationCenter/);
});

test('sala ativa confirmada tem prioridade sem esconder convite para sempre', () => {
  assert.match(source, /if\(recovery\?\.activeRoomId\)return;/);
  assert.match(source, /if\(!force&&recovery\?\.pending&&recovery\?\.resolved!==true\)return;/);
  assert.match(source, /setTimeout\(\(\)=>restoreLobbyIfStranded\(true\),2600\)/);
  assert.match(source, /setTimeout\(\(\)=>restoreLobbyIfStranded\(true\),5000\)/);
});

test('recuperação volta a avaliar após retorno à página e sessão', () => {
  assert.match(source, /pageshow/);
  assert.match(source, /jl-ludo-active-room-recovery/);
  assert.match(source, /jl-player-session-changed/);
  assert.match(source, /visibilitychange/);
});
