'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const js=fs.readFileSync('aviator.js','utf8');
const panel=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const financial=fs.readFileSync('js/aviator/financial.js','utf8');

test('RPC legado de cancelamento permanece isolado no módulo financeiro',()=>{
  assert.match(financial,/jl_aviator_cancel_bet/);
  assert.doesNotMatch(js,/financial\.cancelBet\(/);
  assert.doesNotMatch(panel,/financial\.cancelBet\(/);
});

test('formulários de jogador não transformam aposta confirmada em Cancelar',()=>{
  assert.doesNotMatch(js,/action==='cancel'/);
  assert.doesNotMatch(panel,/action==='cancel'/);
  assert.doesNotMatch(js,/['"`]Cancelar['"`]/);
  assert.doesNotMatch(panel,/['"`]Cancelar['"`]/);
});
