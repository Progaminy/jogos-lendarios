'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'dama-end-message.js'), 'utf8');

test('Dama oferece saída explícita depois do fim da partida', () => {
  assert.match(source, /id = 'damaLeaveFinished'/);
  assert.match(source, /id = 'damaEndLeave'/);
  assert.match(source, /textContent = 'Sair'/);
});

test('sair limpa sala terminada e remove parâmetros que a reabriam', () => {
  assert.match(source, /localStorage\.removeItem\(ROOM_KEY\)/);
  assert.match(source, /url\.searchParams\.delete\('room'\)/);
  assert.match(source, /url\.searchParams\.delete\('board_invite'\)/);
  assert.match(source, /location\.replace\(cleanDamaUrl\(\)\)/);
});
