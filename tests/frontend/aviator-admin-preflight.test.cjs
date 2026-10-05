'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const html=fs.readFileSync(path.join(root,'admin.html'),'utf8');
const admin=fs.readFileSync(path.join(root,'js/aviator/admin.js'),'utf8');

test('painel mostra estado e botão de testes automáticos',()=>{
  assert.match(html,/id="aviatorEnginePreflight"/);
  assert.match(html,/id="aviatorEngineTestStatus"/);
  assert.match(html,/>Testar motor</);
});

test('refresh lê certificação do motor separadamente',()=>{
  assert.match(admin,/jl_aviator_admin_engine_test_state/);
  assert.match(admin,/engineTest/);
  assert.match(admin,/TESTES OK/);
  assert.match(admin,/TESTES NECESSÁRIOS/);
});

test('botão manual executa certificação completa no servidor',()=>{
  assert.match(admin,/jl_aviator_admin_release_gate/);
  assert.match(admin,/Testando motor/);
  assert.match(admin,/Certificação aprovada/);
  assert.match(admin,/repeated_flow/);
  assert.match(admin,/financial_consistency/);
});

test('reabertura permanece decisão administrativa separada da certificação',()=>{
  const block=admin.match(/\$\('aviatorMaintenanceReopen'\)\?\.addEventListener\('click',[\s\S]*?\n    \}\);/)?.[0]||'';
  assert.match(block,/jl_aviator_admin_reopen/);
  assert.match(block,/Reabrindo…/);
  assert.match(block,/Aviator reaberto\. Novas rodadas e apostas estão permitidas/);
  assert.doesNotMatch(block,/engine_test|jl_aviator_admin_release_gate|jl_aviator_admin_set_enabled/);
});
