'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

test('Aviator usa betting_open do servidor apenas como guarda visual',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/round\?\.betting_open===false\|\|seconds===0/);
  assert.match(js,/round\.status!=='OPEN'\|\|round\.betting_open===false/);
});

test('pedido de aposta nunca envia timestamp do telemóvel',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  const block=js.match(/JLApi\.rpc\('jl_aviator_place_bet',[\s\S]*?\n\s*\}\);/)?.[0]||'';
  assert.match(block,/p_token:/);
  assert.match(block,/p_amount:/);
  assert.match(block,/p_request_key:/);
  assert.doesNotMatch(block,/Date\.now|created_at|timestamp|client_time|server_time/);
});

test('Date.now no Aviator não decide aceitação financeira da aposta',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  const submit=js.match(/\$\('#aviatorBetForm'\)\.addEventListener\('submit',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.doesNotMatch(submit,/Date\.now/);
});
