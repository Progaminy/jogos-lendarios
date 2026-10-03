'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const html=fs.readFileSync('aviator.html','utf8');
const css=fs.readFileSync('aviator.css','utf8');
const js=fs.readFileSync('aviator.js','utf8');
const ui=fs.readFileSync('js/aviator/ui.js','utf8');

test('histórico recente de multiplicadores fica no topo do Aviator',()=>{
  const historyAt=html.indexOf('id="aviatorHistoryCard"');
  const stageAt=html.indexOf('id="aviatorStage"');
  assert.ok(historyAt>=0&&stageAt>=0&&historyAt<stageAt);
  assert.match(html,/Últimos multiplicadores/);
  assert.match(css,/\.aviator-history-top/);
});

test('durante voo permite Apostar e cancelar a próxima aposta antes de confirmar',()=>{
  const flying=js.match(/function renderFlying\(\)[\s\S]*?function renderFinished/)?.[0]||'';
  assert.match(flying,/Aposte para a próxima rodada/);
  assert.match(flying,/queued\?'Cancelar'/);
  assert.match(flying,/queued\?'cancel-next'/);
  assert.match(flying,/renderCashoutAction\(\{[\s\S]*?active:Boolean\(myBet\)/);
});

test('auto-bet só dispara quando servidor informa OPEN e não disputa fila do voo',()=>{
  const fn=js.match(/function scheduleAutoBetForOpenRound\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(fn,/round\?\.status!=='OPEN'/);
  assert.match(fn,/round\?\.betting_open===false/);
  assert.match(fn,/nextBet\?\.hasQueued\?\.\(\)/);
  assert.match(fn,/requestSubmit/);
});

test('a única contagem numérica visível continua sendo 10 a 0',()=>{
  assert.match(html,/id="preflightCountdown"/);
  assert.match(html,/id="nextRoundCountdown" class="next-round-countdown hidden"/);
});


test('avião segue curva contínua, não recua e usa escala maior da referência',()=>{
  assert.match(ui,/progress=Math\.max\(lastPlaneProgress,progress\)/);
  assert.match(ui,/const sweep=1-Math\.pow\(1-progress,1\.28\)/);
  assert.match(ui,/const climb=Math\.pow\(progress,\.86\)/);
  assert.match(ui,/stageWidth\*\(mobile\?\.68:\.76\)/);
  assert.match(ui,/stageHeight\*\(mobile\?\.50:\.56\)/);
  assert.match(ui,/translate3d\('\+x\.toFixed\(2\)\+'px,/);
  assert.match(css,/\.plane\{[^}]*font-size:76px[^}]*left:6%[^}]*bottom:10%/);
  assert.match(css,/@media\(max-width:650px\)[\s\S]*?\.plane\{font-size:64px/);
});
