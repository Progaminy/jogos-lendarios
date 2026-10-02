'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const primary=fs.readFileSync('aviator.js','utf8');
const nextBet=fs.readFileSync('js/aviator/next-bet.js','utf8');
const secondary=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const html=fs.readFileSync('aviator.html','utf8');

test('painel principal delega preparação da próxima aposta a módulo próprio',()=>{
  assert.match(html,/js\/aviator\/next-bet\.js/);
  assert.match(primary,/JLAviatorNextBet\?\.create/);
  assert.match(primary,/nextBet\?\.handleAction\(action\)/);
  assert.match(primary,/nextBet\?\.schedule\(\)/);
  assert.match(primary,/nextBet\?\.hasQueued\(\)/);
});

test('módulo permite preparar a próxima aposta durante LOCKED ou FLYING',()=>{
  assert.match(nextBet,/storageKey='jl_aviator_next_bet_v1_slot_'\+slot/);
  assert.match(nextBet,/\['LOCKED','FLYING'\]\.includes\(r\.status\)/);
  assert.match(nextBet,/Próxima aposta preparada\./);
});

test('aposta preparada só é enviada quando a nova rodada está OPEN',()=>{
  assert.match(nextBet,/function schedule\(\)/);
  assert.match(nextBet,/r\?\.status!=='OPEN'/);
  assert.match(nextBet,/current\?\.status!=='OPEN'/);
  assert.match(nextBet,/submittingRoundId=roundId;[\s\S]*?requestSubmit/);
});

test('fila manual tem prioridade sobre auto-bet e é removida após confirmação',()=>{
  assert.match(primary,/Boolean\(nextBet\?\.hasQueued\(\)\)/);
  assert.match(primary,/if\(queuedTriggered\)nextBet\?\.consume\(round\?\.id\)/);
  assert.match(nextBet,/function consume\(roundId\)/);
  assert.match(nextBet,/save\(null\)/);
});

test('painel 2 mantém preparação independente da próxima aposta',()=>{
  assert.match(secondary,/queuedNextBetStorageKey='jl_aviator_next_bet_v1_slot_'\+slot/);
  assert.match(secondary,/\['LOCKED','FLYING'\]\.includes\(round\(\)\.status\)/);
  assert.match(secondary,/scheduleQueuedNextBet\(\)/);
  assert.match(secondary,/Próxima aposta preparada/);
});
