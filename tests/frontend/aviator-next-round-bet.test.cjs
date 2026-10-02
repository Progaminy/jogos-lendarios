'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const primary=fs.readFileSync('aviator.js','utf8');
const secondary=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const html=fs.readFileSync('aviator.html','utf8');
const manifest=JSON.parse(fs.readFileSync('games/manifest.json','utf8'));

test('não existe aposta silenciosa preparada para a próxima rodada',()=>{
  assert.doesNotMatch(html,/next-bet\.js/);
  assert.doesNotMatch(primary,/queue-next|cancel-next|JLAviatorNextBet/);
  assert.doesNotMatch(secondary,/queue-next|cancel-next|JLAviatorNextBet/);
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(!game.assets.some(x=>/next-bet\.js$/.test(x)));
});

test('somente OPEN aceita clique de aposta',()=>{
  const submit=primary.match(/\$\('#aviatorBetForm'\)\.addEventListener\('submit',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(submit,/round\.status!=='OPEN'\|\|round\.betting_open===false/);
  assert.match(submit,/financial\.placeBetSlot/);

  const renderFlying=primary.match(/function renderFlying\(\)[\s\S]*?function renderFinished/)?.[0]||'';
  const renderFinished=primary.match(/function renderFinished\(\)[\s\S]*?function renderWaiting/)?.[0]||'';
  const renderWaiting=primary.match(/function renderWaiting\(\)[\s\S]*?function renderCurrentRound/)?.[0]||'';
  assert.match(renderFlying,/renderBetAction\(\s*true/);
  assert.match(renderFlying,/myBet\?'Foi apostado':'Aguarde'/);
  assert.match(renderFinished,/renderBetAction\(\s*true/);
  assert.match(renderFinished,/'Aguarde a próxima rodada',[\s\S]*?'Aguarde'/);
  assert.match(renderWaiting,/renderBetAction\(\s*true/);
  assert.match(renderWaiting,/'Aguarde a próxima rodada',[\s\S]*?'Aguarde'/);
});

test('aposta confirmada nunca vira Cancelar',()=>{
  assert.match(primary,/myBet\?'Foi apostado':'Apostar'/);
  assert.match(secondary,/label:betId\?'Foi apostado':'Apostar'/);
  assert.doesNotMatch(primary,/['"`]Cancelar['"`]/);
  assert.doesNotMatch(secondary,/['"`]Cancelar['"`]/);
});
