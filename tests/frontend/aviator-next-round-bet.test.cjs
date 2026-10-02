'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const primary=fs.readFileSync('aviator.js','utf8');
const secondary=fs.readFileSync('js/aviator/bet-panel.js','utf8');

test('painel principal permite preparar a próxima aposta durante LOCKED/FLYING',()=>{
  assert.match(primary,/queuedNextBetStorageKey='jl_aviator_next_bet_v1_slot_1'/);
  assert.match(primary,/\['LOCKED','FLYING'\]\.includes\(round\.status\)/);
  assert.match(primary,/Prepare a próxima rodada/);
  assert.match(primary,/Preparar próxima/);
  assert.match(primary,/Próxima aposta preparada/);
});

test('painel 2 permite preparar a próxima aposta durante LOCKED/FLYING',()=>{
  assert.match(secondary,/queuedNextBetStorageKey='jl_aviator_next_bet_v1_slot_'\+slot/);
  assert.match(secondary,/\['LOCKED','FLYING'\]\.includes\(round\(\)\.status\)/);
  assert.match(secondary,/Prepare a próxima rodada/);
  assert.match(secondary,/Preparar próxima/);
  assert.match(secondary,/Próxima aposta preparada/);
});

test('aposta preparada só é enviada quando a nova rodada está OPEN',()=>{
  assert.match(primary,/function scheduleQueuedNextBetForOpenRound\(\)/);
  assert.match(primary,/round\?\.status!=='OPEN'/);
  assert.match(primary,/queuedBetSubmittingRoundId=roundId;[\s\S]*?requestSubmit/);

  assert.match(secondary,/function scheduleQueuedNextBet\(\)/);
  assert.match(secondary,/r\?\.status!=='OPEN'/);
  assert.match(secondary,/queuedBetSubmittingRoundId=roundId;[\s\S]*?requestSubmit/);
});

test('fila manual tem prioridade sobre auto-bet e é removida após confirmação',()=>{
  assert.match(primary,/Boolean\(queuedNextBet\)/);
  assert.match(primary,/if\(queuedTriggered\)\{[\s\S]*?saveQueuedNextBet\(null\)/);
  assert.match(secondary,/Boolean\(queuedNextBet\)/);
  assert.match(secondary,/if\(queuedTriggered\)\{[\s\S]*?saveQueuedNextBet\(null\)/);
});
