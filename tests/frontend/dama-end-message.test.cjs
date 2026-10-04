'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'dama-end-message.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'dama.html'), 'utf8');

test('Dama mostra modal quando o resultado final deixa de estar oculto', () => {
  assert.match(source, /MutationObserver\(showEndMessage\)/);
  assert.match(source, /result\.classList\.contains\('hidden'\)/);
  assert.match(source, /title\.textContent = 'Fim do Jogo'/);
  assert.match(source, /modal\.classList\.remove\('hidden'\)/);
});

test('modal final da Dama está carregado na página', () => {
  assert.match(html, /id="damaEndModal"/);
  assert.match(html, /id="damaEndMessage"/);
  assert.match(html, /id="damaEndOk"/);
  assert.match(html, /dama-end-message\.js\?v=20261004-1/);
});
