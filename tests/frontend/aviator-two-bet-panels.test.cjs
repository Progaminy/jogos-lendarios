'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const html=fs.readFileSync('aviator.html','utf8');
const css=fs.readFileSync('aviator.css','utf8');
const player=fs.readFileSync('aviator.js','utf8');
const panel=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const financial=fs.readFileSync('js/aviator/financial.js','utf8');

test('Aviator expõe dois painéis independentes de aposta',()=>{
  for(const id of [
    'aviatorBetForm','aviatorAmount','aviatorAutoCashout','aviatorAutoBet','betBtn','cashoutBtn',
    'aviatorBetForm2','aviatorAmount2','aviatorAutoCashout2','aviatorAutoBet2','betBtn2','cashoutBtn2'
  ]) assert.match(html,new RegExp('id="'+id+'"'));
});

test('desktop usa dois cartões e mobile empilha os painéis',()=>{
  assert.match(css,/\.aviator-controls\{display:grid;grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(css,/@media\(max-width:650px\)[\s\S]*?\.aviator-controls\{grid-template-columns:1fr/);
});

test('mobile distribui espaço sem esmagar cash-out automático nem desperdiçar no valor',()=>{
  assert.match(css,/grid-template-columns:minmax\(0,1fr\) minmax\(0,\.8fr\) minmax\(126px,1\.2fr\)/);
  assert.match(css,/\.stake-stepper \.money-input input\{[\s\S]*?text-align:center/);
  assert.match(css,/field:nth-of-type\(2\) \.money-input input\{[\s\S]*?text-align:center/);
});

test('cada painel usa slot financeiro próprio',()=>{
  assert.match(player,/financial\.placeBetSlot\(\{[\s\S]*?slot:1/);
  assert.match(panel,/slot=2/);
  assert.match(panel,/financial\.placeBetSlot\(\{[\s\S]*?slot,/);
  assert.match(financial,/jl_aviator_place_bet_slot/);
});

test('painel 2 pode cancelar fila e aposta confirmada antes do fecho',()=>{
  assert.match(panel,/action==='cancel-next'/);
  assert.match(panel,/action==='cancel'/);
  assert.match(panel,/financial\.cancelBet\(/);
  assert.match(panel,/financial\.resetBetKeyForSlot\(slot\)/);
  assert.match(panel,/label:queued\?'Cancelar'/);
});

test('painel 2 mantém cash-out próprio durante voo',()=>{
  assert.match(panel,/financial\.requestFinancialCashout\(/);
  assert.match(panel,/liveReturn=active&&hasMultiplier&&hasStake\?money\(stake\*m\):null/);
  assert.match(panel,/cashoutButton\.textContent=pending\?'Confirmando…':liveReturn\|\|'Sacar'/);
});

test('orquestrador continua abaixo do limite modular',()=>{
  assert.ok(player.length<43000,'aviator.js deve permanecer apenas como orquestrador');
});
