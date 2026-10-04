'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'dama-flow-actions-fix.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'dama.html'), 'utf8');

test('modal da Dama responde diretamente sem depender dos botões escondidos', () => {
  assert.match(source, /jl_dama_accept_settings/);
  assert.match(source, /p_accept: Boolean\(accept\)/);
  assert.match(source, /event\.stopImmediatePropagation\(\)/);
  assert.doesNotMatch(source, /damaAcceptSettings'\)\?\.click\(\)/);
  assert.doesNotMatch(source, /damaDeclineSettings'\)\?\.click\(\)/);
});

test('recusar ou sair antes do início liberta a sala e bloqueia reabertura durante a saída', () => {
  assert.match(source, /localStorage\.removeItem\(ROOM_KEY\)/);
  assert.match(source, /jl_dama_cancel/);
  assert.match(source, /location\.replace\(cleanDamaUrl\(\)\)/);
  assert.match(source, /let leaving = false/);
  assert.match(source, /freezeLeavingUi/);
  assert.match(source, /if \(busy \|\| leaving\) return/);
});

test('confirmação da aposta usa RPC direto e hotfix versionado está carregado', () => {
  assert.match(source, /jl_dama_commit_stake/);
  assert.match(html, /dama-flow-actions-fix\.js\?v=\d{8}-\d+/);
});
