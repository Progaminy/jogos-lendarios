'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('painel mostra auditoria administrativa do Aviator',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  assert.match(html,/id="aviatorAuditWrap"/);
  assert.match(html,/Auditoria administrativa/);
  assert.match(html,/id="aviatorAuditList"/);
  assert.match(html,/Quem fez, quando fez, o alvo e o estado antes\/depois/);

  assert.match(js,/jl_aviator_admin_audit_history/);
  assert.match(js,/p_limit:40/);
  assert.match(js,/actor_name/);
  assert.match(js,/actor_role/);
  assert.match(js,/before_state/);
  assert.match(js,/after_state/);
  assert.match(js,/target_type/);
  assert.match(js,/target_id/);
});

test('ações administrativas críticas têm rótulos legíveis e fallback para ações futuras',()=>{
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  for(const action of [
    'aviator.admin.closed',
    'aviator.admin.reopened',
    'aviator.admin.bank_adjusted',
    'aviator.admin.one_round_test_started',
    'aviator.round_admin_cancelled'
  ]){
    assert.ok(js.includes(action),action+' precisa de rótulo');
  }

  assert.match(js,/return labels\[action\]\|\|String\(action\|\|'Ação administrativa'\)/);
});

test('histórico administrativo atualiza sozinho enquanto estiver aberto',()=>{
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  assert.match(js,/Date\.now\(\)-aviatorAuditLastLoad<5000/);
  assert.match(js,/if\(\$\('aviatorAuditWrap'\)\?\.open\)/);
  assert.match(js,/refreshAviatorAudit\(false\)/);
});
