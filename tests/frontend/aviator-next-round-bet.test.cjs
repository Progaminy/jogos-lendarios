'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const primary=fs.readFileSync('aviator.js','utf8');
const secondary=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const nextBet=fs.readFileSync('js/aviator/next-bet.js','utf8');
const html=fs.readFileSync('aviator.html','utf8');
const manifest=JSON.parse(fs.readFileSync('games/manifest.json','utf8'));

test('um clique durante FLYING regista a aposta para a próxima rodada',()=>{
  assert.match(html,/js\/aviator\/next-bet\.js/);
  assert.match(primary,/nextBet\?\.queue\?\.\(\)/);
  assert.match(secondary,/nextBet\?\.queue\?\.\(\)/);
  assert.match(nextBet,/function queue\(\)/);
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game.assets.includes('./js/aviator/next-bet.js'));
});

test('fila do voo pode ser cancelada antes da confirmação',()=>{
  assert.match(nextBet,/function cancel\(\)/);
  assert.match(primary,/queued\?'Cancelar'/);
  assert.match(secondary,/label:queued\?'Cancelar'/);
  assert.match(primary,/queued\?'cancel-next'/);
  assert.match(secondary,/mode:queued\?'cancel-next'/);
});

test('aposta registada é enviada automaticamente quando OPEN começa',()=>{
  assert.match(nextBet,/r\?\.status!=='OPEN'/);
  assert.match(nextBet,/form\.requestSubmit\(\)/);
  assert.match(primary,/nextBet\?\.schedule\?\.\(\)/);
  assert.match(secondary,/nextBet\?\.schedule\?\.\(\)/);
});

test('LOCKED não recebe aposta nova nem permite cancelamento',()=>{
  const locked=primary.match(/function renderLocked\(\)[\s\S]*?function renderFlying/)?.[0]||'';
  assert.match(locked,/renderBetAction\(\s*true/);
  assert.doesNotMatch(locked,/'Cancelar'/);
});
