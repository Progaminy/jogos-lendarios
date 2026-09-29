'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('admin oferece uma unica rodada real de teste',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('admin.js','utf8');
  assert.match(html,/id="aviatorOneRoundTest"/);
  assert.match(js,/jl_aviator_admin_start_one_round_test/);
  assert.match(js,/Abrir exatamente 1 rodada real de teste/);
  assert.match(js,/voltará à manutenção após liquidá-la/);
});

test('botao de one-round test fica indisponivel quando Aviator ja esta aberto',()=>{
  const js=fs.readFileSync('admin.js','utf8');
  assert.match(js,/oneRound\.disabled=Boolean\(d\.enabled\)/);
  assert.match(js,/Feche o Aviator antes de iniciar uma rodada de teste/);
});
