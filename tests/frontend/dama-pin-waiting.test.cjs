'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'dama-room-preview.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'dama.html'), 'utf8');

test('botão Fixar permanece disponível enquanto espera adversário', () => {
  assert.match(source, /function ensurePinPlacement\(actualGameVisible\)/);
  assert.match(source, /if \(!actualGameVisible\) \{[\s\S]*?dama-room-actions[\s\S]*?actions\.prepend\(button\)/);
  assert.doesNotMatch(source, /pin\.classList\.toggle\('hidden', !actualGameVisible\)/);
});

test('modo fixado não força o tabuleiro ativo antes do início', () => {
  assert.match(source, /body\.dama-pinned:not\(\.dama-game-active\) #damaGame/);
  assert.match(source, /display:none!important/);
  assert.match(source, /document\.body\.classList\.toggle\('dama-game-active', actualGameVisible\)/);
});

test('versão nova do fluxo de sala está carregada sem cache antigo', () => {
  assert.match(html, /dama-room-preview\.js\?v=20261004-4/);
});
