'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const primary=fs.readFileSync('aviator.js','utf8');
const secondary=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const html=fs.readFileSync('aviator.html','utf8');
const manifest=JSON.parse(fs.readFileSync('games/manifest.json','utf8'));

test('um clique durante OPEN envia a aposta real diretamente',()=>{
  const submit=primary.match(/\$\('#aviatorBetForm'\)\.addEventListener\('submit',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(submit,/round\.status!=='OPEN'\|\|round\.betting_open===false/);
  assert.match(submit,/financial\.placeBetSlot\(\{[\s\S]*?slot:1/);
  assert.doesNotMatch(submit,/requestSubmit|queue-next|cancel-next|handleAction/);

  const submit2=secondary.match(/async function submit\(event\)\{[\s\S]*?async function cashout/)?.[0]||'';
  assert.match(submit2,/financial\.placeBetSlot\(\{[\s\S]*?slot,/);
  assert.doesNotMatch(submit2,/requestSubmit|queue-next|cancel-next|handleAction/);
});

test('módulo de aposta para próxima rodada não é carregado',()=>{
  assert.doesNotMatch(html,/js\/aviator\/next-bet\.js/);
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game);
  assert.ok(!game.assets.includes('./js/aviator/next-bet.js'));
});
