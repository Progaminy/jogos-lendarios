'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'ludo.js'), 'utf8');

test('perdedor vê somente Fim do Jogo no modal final', () => {
  assert.match(source, /function showLudoLossNotice\(key\)/);
  assert.match(source, /winModalTitle\.textContent='Fim do Jogo'/);
  assert.match(source, /winModalMessage\.textContent=''/);
  assert.match(source, /if\(!won\)\{[\s\S]*showLudoLossNotice\(lossKey\)/);
});

test('vencedor mantém o modal de parabéns separado', () => {
  assert.match(source, /function showLudoWinNotice\(key,amount,roundLabel,roundTime\)/);
  assert.match(source, /winModalTitle\.textContent='Parabéns!'/);
});
