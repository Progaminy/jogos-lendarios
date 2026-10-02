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
  assert.match(submit,/financial\.placeBetSlot\(\{[\s\S]*?slot:1/);

  const submit2=secondary.match(/async function submit\(event\)\{[\s\S]*?async function cashout/)?.[0]||'';
  assert.match(submit2,/financial\.placeBetSlot\(\{[\s\S]*?slot,/);
});

test('um clique durante voo não exige segundo clique quando OPEN chegar',()=>{
  assert.match(primary,/nextBet\?\.queue\?\.\(\)/);
  assert.match(secondary,/nextBet\?\.queue\?\.\(\)/);
  assert.match(html,/js\/aviator\/next-bet\.js/);
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game);
  assert.ok(game.assets.includes('./js/aviator/next-bet.js'));
});
