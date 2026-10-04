'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const ui = fs.readFileSync(path.join(root, 'dama-stake-edit.js'), 'utf8');
const flow = fs.readFileSync(path.join(root, 'dama-flow-actions-fix.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'dama.html'), 'utf8');
const sql = fs.readFileSync(path.join(root, 'supabase/migrations/20261004081500_dama_edit_bet_before_stake.sql'), 'utf8');

test('valor da aposta vira campo editável para o criador', () => {
  assert.match(ui, /damaStakeModalInput/);
  assert.match(ui, /input\.type = 'number'/);
  assert.match(ui, /input\.readOnly = !host/);
  assert.match(ui, /input\.min = '10'/);
});

test('alterar o valor antes do débito exige nova aceitação', () => {
  assert.match(flow, /jl_dama_update_bet_before_stake/);
  assert.match(flow, /requested !== original/);
  assert.match(sql, /r\.status not in \('waiting','negotiating','funding'\)/);
  assert.match(sql, /and rp\.stake_paid/);
  assert.match(sql, /status=case when guest_id is null then 'waiting' else 'negotiating' end/);
  assert.match(sql, /settings_accepted=\(seat=1\)/);
});

test('pagina força carregamento das versões novas', () => {
  assert.match(html, /dama-stake-edit\.js\?v=20261004-1/);
  assert.match(html, /dama-flow-actions-fix\.js\?v=20261004-2/);
});
