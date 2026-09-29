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

test('abrir com banca baixa exige confirmação sem alterar fórmula',()=>{
  const js=fs.readFileSync('admin.js','utf8');
  assert.match(js,/referenceCeiling<1\.5/);
  assert.match(js,/window\.confirm/);
  assert.match(js,/Abrir o Aviator mesmo assim/);
  assert.match(js,/1\+\(bankBalance\*exposure\/10\)/);
  assert.doesNotMatch(js,/bankBalance\s*=\s*bankBalance\s*\+/);
});
