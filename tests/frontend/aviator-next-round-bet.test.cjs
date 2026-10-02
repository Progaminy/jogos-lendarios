'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const primary=fs.readFileSync('aviator.js','utf8');
const secondary=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const nextBet=fs.readFileSync('js/aviator/next-bet.js','utf8');
const html=fs.readFileSync('aviator.html','utf8');
const manifest=JSON.parse(fs.readFileSync('games/manifest.json','utf8'));

test('Aviator usa Apostar sem expor etapa preparar aposta',()=>{
  assert.match(html,/js\/aviator\/next-bet\.js/);
  assert.doesNotMatch(primary,/Prepare a próxima|Próxima aposta preparada/);
  assert.doesNotMatch(secondary,/Prepare a próxima|Próxima aposta preparada/);
  assert.doesNotMatch(nextBet,/Prepare a próxima|Próxima aposta preparada/);
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game?.assets.includes('./js/aviator/next-bet.js'));
});

test('durante OPEN Apostar envia imediatamente para a rodada atual',()=>{
  assert.match(primary,/round\.status!=='OPEN'\|\|round\.betting_open===false/);
  assert.match(primary,/financial\.placeBetSlot\(\{[\s\S]*?slot:1/);
  assert.match(secondary,/financial\.placeBetSlot\(\{[\s\S]*?slot,/);
});

test('durante LOCKED ou FLYING Apostar guarda silenciosamente para a próxima rodada',()=>{
  assert.match(nextBet,/\['LOCKED','FLYING','CRASHED','SETTLED','CANCELLED'\]\.includes\(r\.status\)/);
  assert.match(primary,/queued\?'Cancelar':'Apostar'/);
  assert.match(primary,/queued\?'cancel-next':'queue-next'/);
  assert.match(secondary,/label:queued\?'Cancelar':'Apostar'/);
  assert.match(secondary,/mode:queued\?'cancel-next':'queue-next'/);
  assert.doesNotMatch(nextBet,/prepar/i);
});

test('aposta silenciosa é enviada automaticamente quando a nova rodada fica OPEN',()=>{
  assert.match(nextBet,/function schedule\(\)/);
  assert.match(nextBet,/r\?\.status!=='OPEN'/);
  assert.match(nextBet,/current\?\.status!=='OPEN'/);
  assert.match(nextBet,/typeof form\?\.requestSubmit==='function'[\s\S]*?form\.requestSubmit\(\)/);
  assert.match(primary,/nextBet\?\.schedule\(\)/);
  assert.match(secondary,/nextBet\?\.schedule\(\)/);
});

test('fila manual tem prioridade sobre auto-bet',()=>{
  assert.match(primary,/Boolean\(nextBet\?\.hasQueued\(\)\)/);
  assert.match(secondary,/Boolean\(nextBet\?\.hasQueued\(\)\)/);
  assert.match(primary,/if\(queuedTriggered\)nextBet\?\.consume/);
  assert.match(secondary,/if\(queuedTriggered\)nextBet\?\.consume/);
});


test('fila força submit como aposta real quando OPEN chega',()=>{
  assert.match(nextBet,/if\(button\)button\.dataset\.action='bet'/);
  assert.match(nextBet,/submittingRoundId=roundId/);
  assert.match(nextBet,/typeof form\?\.requestSubmit==='function'[\s\S]*?form\.requestSubmit\(\)/);
});

test('entre rodadas Apostar continua disponível para os dois painéis',()=>{
  const finished=primary.match(/function renderFinished\(\)[\s\S]*?\n\}/)?.[0]||'';
  const waiting=primary.match(/function renderWaiting\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(finished,/queued\?'Cancelar':'Apostar'/);
  assert.match(waiting,/queued\?'Cancelar':'Apostar'/);
  assert.match(secondary,/status:queued\?'Aposta registada':'Disponível'/);
});
