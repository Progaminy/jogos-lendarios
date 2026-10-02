'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const html=fs.readFileSync('aviator.html','utf8');
const css=fs.readFileSync('aviator.css','utf8');
const js=fs.readFileSync('aviator.js','utf8');

test('histórico recente de multiplicadores fica no topo do Aviator',()=>{
  const historyAt=html.indexOf('id="aviatorHistoryCard"');
  const stageAt=html.indexOf('id="aviatorStage"');
  assert.ok(historyAt>=0&&stageAt>=0&&historyAt<stageAt);
  assert.match(html,/Últimos multiplicadores/);
  assert.match(html,/id="aviatorHistory" class="aviator-history-strip"/);
  assert.match(css,/\.aviator-history-top/);
});

test('durante voo permite Apostar para a próxima rodada sem Cancelar',()=>{
  const flying=js.match(/function renderFlying\(\)[\s\S]*?function renderFinished/)?.[0]||'';
  assert.match(flying,/Aposte para a próxima rodada/);
  assert.match(flying,/myBet\|\|queued\?'Foi apostado':'Apostar'/);
  assert.match(flying,/renderCashoutAction\(\{[\s\S]*?active:Boolean\(myBet\)/);
  assert.doesNotMatch(flying,/Cancelar/);
});

test('auto-bet só dispara quando servidor informa OPEN e não disputa fila do voo',()=>{
  const fn=js.match(/function scheduleAutoBetForOpenRound\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(fn,/round\?\.status!=='OPEN'/);
  assert.match(fn,/round\?\.betting_open===false/);
  assert.match(fn,/nextBet\?\.hasQueued\?\.\(\)/);
  assert.match(fn,/requestSubmit/);
});

test('contagem visível de aposta permanece separada do multiplicador',()=>{
  assert.match(html,/id="preflightCountdown"/);
  assert.match(html,/id="multiplier"/);
  assert.match(html,/id="nextRoundCountdown" class="next-round-countdown hidden"/);
});
