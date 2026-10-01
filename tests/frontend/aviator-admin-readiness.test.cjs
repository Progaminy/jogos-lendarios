'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('admin mostra prontidão e tetos de referência do Aviator',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  assert.match(html,/id="aviatorReadiness"/);
  assert.match(html,/id="aviatorReferenceCeilings"/);
  assert.match(js,/\[1,5,10,50\]/);
  assert.match(js,/TESTES NECESSÁRIOS/);
  assert.match(js,/TESTES OK/);
  assert.match(js,/BANCA BAIXA/);
});

test('botão Fechar Aviator é dedicado, direto e não contém lógica de reabertura',()=>{
  const js=fs.readFileSync('js/aviator/admin.js','utf8');
  assert.match(js,/async function closeAviatorFromAdmin/);
  assert.match(js,/jl_aviator_admin_close/);
  assert.match(js,/window\.JLCloseAviator=closeAviatorFromAdmin/);
  assert.match(js,/document\.addEventListener\('click'/);
  assert.doesNotMatch(js,/Fechar Aviator agora\?/);
  assert.doesNotMatch(js,/jl_aviator_admin_set_enabled/);

  assert.match(js,/1\+\(bankBalance\*exposure\/10\)/);
  assert.doesNotMatch(js,/bankBalance\s*=\s*bankBalance\s*\+/);
});
