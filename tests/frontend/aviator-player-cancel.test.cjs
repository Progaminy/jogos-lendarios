'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const js=fs.readFileSync('aviator.js','utf8');
const financial=fs.readFileSync('js/aviator/financial.js','utf8');

test('cancelamento antes da descolagem usa RPC autoritativo e chave idempotente',()=>{
  assert.match(financial,/jl_aviator_cancel_bet/);
  assert.match(financial,/p_bet_id:id/);
  assert.match(financial,/p_request_key:String\(requestKey\|\|cancelBetRequestKey\(id\)/);
  assert.match(financial,/function cancelBetRequestKey\(betId\)/);
});

test('formulário diferencia apostar de cancelar sem botão extra',()=>{
  const submit=js.match(/\$\('#aviatorBetForm'\)\.addEventListener\('submit',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(submit,/dataset\.action\|\|'bet'/);
  assert.match(submit,/if\(action==='cancel'\)/);
  assert.match(submit,/financial\.cancelBet\(/);
  assert.match(submit,/status:'REFUNDED'/);
  assert.match(submit,/myBet=null/);
  assert.doesNotMatch(submit,/confirm\(|prompt\(/);
});

test('cancelamento fecha quando servidor já encerrou janela',()=>{
  const submit=js.match(/\$\('#aviatorBetForm'\)\.addEventListener\('submit',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(submit,/Cancelamento encerrado para esta rodada/);
  assert.match(submit,/await reconnectState\(\)/);
});
