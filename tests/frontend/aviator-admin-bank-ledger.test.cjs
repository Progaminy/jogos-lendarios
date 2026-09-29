'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('historico da banca do Aviator fica recolhido e sob demanda',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('admin.js','utf8');

  assert.match(html,/<details id="aviatorBankLedgerWrap"/);
  assert.match(html,/id="aviatorBankLedger"/);
  assert.match(js,/jl_aviator_admin_bank_ledger/);
  assert.match(js,/p_limit:30/);
  assert.match(js,/if\(!wrap\.open&&!force\)return/);
  assert.match(js,/Date\.now\(\)-aviatorBankLedgerLastLoad<10000/);
});

test('historico distingue movimentos e escapa texto do banco',()=>{
  const js=fs.readFileSync('admin.js','utf8');

  assert.match(js,/Lucro pago no cash-out/);
  assert.match(js,/Stake perdido creditado/);
  assert.match(js,/Ajuste manual/);
  assert.match(js,/escapeHtml\(item\.reason\|\|'—'\)/);
  assert.match(js,/delta>0\?'positive':delta<0\?'negative':'neutral'/);
});
