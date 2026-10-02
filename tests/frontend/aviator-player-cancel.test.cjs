'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const js=fs.readFileSync('aviator.js','utf8');
const panel=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const nextBet=fs.readFileSync('js/aviator/next-bet.js','utf8');
const financial=fs.readFileSync('js/aviator/financial.js','utf8');

test('aposta apenas registada para a próxima rodada pode ser cancelada localmente',()=>{
  assert.match(nextBet,/function cancel\(\)/);
  assert.match(nextBet,/save\(null\)/);
  assert.match(js,/action==='cancel-next'/);
  assert.match(panel,/action==='cancel-next'/);
  assert.match(js,/nextBet\?\.cancel\?\.\(\)/);
  assert.match(panel,/nextBet\?\.cancel\?\.\(\)/);
});

test('aposta confirmada pode ser cancelada enquanto OPEN',()=>{
  assert.match(financial,/jl_aviator_cancel_bet/);
  assert.match(js,/async function cancelConfirmedBet\(\)/);
  assert.match(panel,/async function cancelConfirmedBet\(\)/);
  assert.match(js,/financial\.cancelBet\(/);
  assert.match(panel,/financial\.cancelBet\(/);
  assert.match(js,/round\?\.status!=='OPEN'/);
  assert.match(panel,/round\(\)\?\.status!=='OPEN'/);
});

test('cancelamento devolve saldo e permite nova aposta com nova chave',()=>{
  assert.match(financial,/function resetBetKeyForSlot\(slot=1\)/);
  assert.match(js,/financial\.resetBetKeyForSlot\(1\)/);
  assert.match(panel,/financial\.resetBetKeyForSlot\(slot\)/);
  assert.match(js,/Aposta cancelada\./);
  assert.match(panel,/Aposta cancelada\./);
});

test('depois do zero LOCKED não oferece Cancelar',()=>{
  const locked=js.match(/function renderLocked\(\)[\s\S]*?function renderFlying/)?.[0]||'';
  assert.match(locked,/renderBetAction\(\s*true/);
  assert.doesNotMatch(locked,/'Cancelar'/);
});
