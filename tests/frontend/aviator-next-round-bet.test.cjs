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
  assert.match(primary,/\['FLYING','CRASHED','SETTLED'\]\.includes\(round\?\.status\)/);
  assert.match(primary,/nextBet\?\.queue\?\.\(\)/);
  assert.match(secondary,/nextBet\?\.queue\?\.\(\)/);
  assert.match(nextBet,/function queue\(\)/);
  assert.doesNotMatch(nextBet,/Cancelar|cancel-next/);
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game.assets.includes('./js/aviator/next-bet.js'));
});

test('aposta registada no voo é enviada automaticamente quando OPEN começa',()=>{
  assert.match(nextBet,/r\?\.status!=='OPEN'/);
  assert.match(nextBet,/current\?\.status!=='OPEN'/);
  assert.match(nextBet,/form\.requestSubmit\(\)/);
  assert.match(primary,/nextBet\?\.schedule\?\.\(\)/);
  assert.match(secondary,/nextBet\?\.schedule\?\.\(\)/);
  assert.match(primary,/nextBet\?\.consume\?\.\(round\?\.id\)/);
  assert.match(secondary,/nextBet\?\.consume\?\.\(round\(\)\?\.id\)/);
});

test('LOCKED não recebe nova aposta e não existe Cancelar',()=>{
  const locked=primary.match(/function renderLocked\(\)[\s\S]*?function renderFlying/)?.[0]||'';
  assert.match(locked,/renderBetAction\(\s*true/);
  assert.doesNotMatch(primary,/['"`]Cancelar['"`]/);
  assert.doesNotMatch(secondary,/['"`]Cancelar['"`]/);
  assert.doesNotMatch(nextBet,/['"`]Cancelar['"`]/);
});
