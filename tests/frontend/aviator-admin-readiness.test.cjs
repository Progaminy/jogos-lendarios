'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('admin mostra prontidão e tetos de referência do Aviator',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('admin.js','utf8');

  assert.match(html,/id="aviatorReadiness"/);
  assert.match(html,/id="aviatorReferenceCeilings"/);
  assert.match(js,/\[1,5,10,50\]/);
  assert.match(js,/BANCA MUITO BAIXA/);
  assert.match(js,/PRONTO PARA TESTE/);
});

test('botão Fechar Aviator é dedicado e não contém lógica de reabertura',()=>{
  const js=fs.readFileSync('admin.js','utf8');
  assert.match(js,/jl_aviator_admin_close/);
  assert.match(js,/Fechar Aviator agora\?/);
  assert.match(js,/Novas apostas e novas rodadas serão bloqueadas imediatamente/);

  const closeBlock=js.match(
    /\$\('aviatorMaintenanceClose'\)\?\.addEventListener\('click',[\s\S]*?\n  \}\);/
  )?.[0]||'';

  assert.match(closeBlock,/jl_aviator_admin_close/);
  assert.doesNotMatch(closeBlock,/Abrir o Aviator/);
  assert.doesNotMatch(closeBlock,/jl_aviator_admin_set_enabled/);
  assert.doesNotMatch(closeBlock,/p_enabled:true/);

  assert.match(js,/1\+\(bankBalance\*exposure\/10\)/);
  assert.doesNotMatch(js,/bankBalance\s*=\s*bankBalance\s*\+/);
});
