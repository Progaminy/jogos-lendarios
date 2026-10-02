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
  ]){
    assert.match(html,new RegExp('id="'+id+'"'));
  }
  assert.match(html,/>Aposta 1</);
  assert.match(html,/>Aposta 2</);
});

test('desktop usa dois cartões e mobile empilha os painéis',()=>{
  assert.match(css,/\.aviator-controls\{display:grid;grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(css,/@media\(max-width:650px\)[\s\S]*?\.aviator-controls\{grid-template-columns:1fr/);
  assert.match(css,/\.aviator-bet-panel\{/);
});

test('cada painel usa slot financeiro próprio',()=>{
  assert.match(player,/financial\.placeBetSlot\(\{[\s\S]*?slot:1/);
  assert.match(player,/JLAviatorBetPanel\?\.create/);
  assert.match(panel,/slot=2/);
  assert.match(panel,/financial\.placeBetSlot\(\{[\s\S]*?slot,/);
  assert.match(financial,/jl_aviator_place_bet_slot/);
  assert.match(financial,/p_bet_slot:n/);
});

test('request keys e cash-out pendente são separados por slot',()=>{
  assert.match(financial,/function betKeyForSlot\(slot=1\)/);
  assert.match(financial,/jl_aviator_bet_key_'\+roundId\+'_slot_'\+n/);
  assert.match(financial,/function pendingCashoutKey\(slot=1\)/);
  assert.match(financial,/pendingCashoutPrefix\+'_slot_'\+n/);
  assert.match(panel,/financial\.readPendingCashout\(slot\)/);
  assert.match(panel,/financial\.savePendingCashout\(id,roundId,requestKey,slot\)/);
  assert.match(panel,/financial\.clearPendingCashout\(slot\)/);
});

test('painel 2 tem auto-bet e cash-out próprios sem Cancelar fantasma',()=>{
  assert.match(panel,/aviatorAutoBet'\+suffix/);
  assert.match(panel,/financial\.requestFinancialCashout\(/);
  assert.match(panel,/Aposta automática confirmada para esta rodada/);
  assert.match(panel,/liveReturn=active&&hasMultiplier&&hasStake\?money\(stake\*m\):null/);
  assert.match(panel,/cashoutButton\.textContent=pending\?'Confirmando…':liveReturn\|\|'Sacar'/);
  assert.doesNotMatch(panel,/Cancelar|queue-next|cancel-next/);
});

test('reconexão do painel 2 escolhe apenas bet_slot 2',()=>{
  assert.match(panel,/betSlotOf\(b\)===Number\(slot\)/);
  assert.match(panel,/activeBetForRound\(bets,roundId\)/);
  assert.match(panel,/latestBetForRound\(bets,roundId\)/);
  assert.match(player,/p2\?\.applyPlayerState\(player\)/);
});

test('orquestrador continua abaixo do limite modular',()=>{
  assert.ok(player.length<40000,'aviator.js deve permanecer apenas como orquestrador');
});
