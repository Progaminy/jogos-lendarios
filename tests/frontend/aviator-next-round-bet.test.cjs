'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const primary=fs.readFileSync('aviator.js','utf8');
const secondary=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const html=fs.readFileSync('aviator.html','utf8');
const manifest=JSON.parse(fs.readFileSync('games/manifest.json','utf8'));

test('Aviator não carrega etapa de preparar próxima aposta',()=>{
  assert.doesNotMatch(html,/js\/aviator\/next-bet\.js/);
  assert.doesNotMatch(primary,/JLAviatorNextBet|queue-next|cancel-next|Prepare a próxima|Próxima aposta preparada/);
  assert.doesNotMatch(secondary,/queue-next|cancel-next|Prepare a próxima|Próxima aposta preparada/);
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game);
  assert.ok(!game.assets.includes('./js/aviator/next-bet.js'));
});

test('durante OPEN Apostar envia diretamente a aposta da rodada atual',()=>{
  assert.match(primary,/round\.status!=='OPEN'\|\|round\.betting_open===false/);
  assert.match(primary,/financial\.placeBetSlot\(\{[\s\S]*?slot:1/);
  assert.match(secondary,/financial\.placeBetSlot\(\{[\s\S]*?slot,/);
});

test('depois de zero LOCKED bloqueia novas apostas e apenas aguarda o voo',()=>{
  const locked=primary.match(/function renderLocked\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(locked,/setBetInputsLocked\(true\)/);
  assert.match(locked,/renderBetAction\([\s\S]*?true,[\s\S]*?'Apostas encerradas',[\s\S]*?'Apostar'/);
  assert.doesNotMatch(locked,/queue-next|cancel-next|Próxima/);

  const locked2=secondary.match(/if\(r\.status==='LOCKED'\)\{[\s\S]*?return;\n      \}/)?.[0]||'';
  assert.match(locked2,/setInputsLocked\(true\)/);
  assert.match(locked2,/disabled:true/);
  assert.match(locked2,/label:'Apostar'/);
});

test('durante voo não existe preparação da próxima aposta',()=>{
  const flying=primary.match(/function renderFlying\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(flying,/setBetInputsLocked\(true\)/);
  assert.doesNotMatch(flying,/queue-next|cancel-next|Próxima aposta|Prepare/);

  const flying2=secondary.match(/if\(r\.status==='FLYING'\)\{[\s\S]*?return;\n      \}/)?.[0]||'';
  assert.match(flying2,/setInputsLocked\(true\)/);
  assert.doesNotMatch(flying2,/queue-next|cancel-next|Próxima aposta|Prepare/);
});

test('estado antigo de fila é descartado ao abrir a nova interface',()=>{
  assert.match(primary,/removeItem\('jl_aviator_next_bet_v1_slot_1'\)/);
  assert.match(secondary,/removeItem\('jl_aviator_next_bet_v1_slot_'\+slot\)/);
});
