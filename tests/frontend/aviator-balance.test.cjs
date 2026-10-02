'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const html=fs.readFileSync('aviator.html','utf8');
const css=fs.readFileSync('aviator.css','utf8');
const js=fs.readFileSync('aviator.js','utf8');
const balance=fs.readFileSync('js/aviator/balance.js','utf8');
const financial=fs.readFileSync('js/aviator/financial.js','utf8');
const manifest=JSON.parse(fs.readFileSync('games/manifest.json','utf8'));

test('saldo do jogador aparece no topo direito do Aviator',()=>{
  assert.match(html,/id="aviatorBalance" class="aviator-top-balance"/);
  assert.match(html,/<span>Saldo<\/span>/);
  assert.match(css,/\.aviator-top-balance\{[\s\S]*?margin-left:auto/);
  assert.match(css,/\.aviator-top-balance strong\{[\s\S]*?font-variant-numeric:tabular-nums/);
});

test('saldo usa estado privado autoritativo do jogador',()=>{
  assert.match(balance,/jl_aviator_player_state/);
  assert.match(balance,/player\.balance/);
  assert.match(balance,/toLocaleString\('pt-MZ'/);
  assert.match(js,/balance\?\.applyPlayerState\(player\)/);
});

test('operações financeiras disparam atualização do saldo',()=>{
  assert.match(financial,/jl-player-finance-changed/);
  assert.ok((financial.match(/balanceChanged\(\);/g)||[]).length>=4);
  assert.match(balance,/jl-player-finance-changed/);
  assert.match(balance,/void refresh\(\)/);
});

test('saldo desaparece quando não existe sessão de jogador',()=>{
  assert.match(balance,/element\.hidden=!authenticated/);
  assert.match(balance,/jl-player-session-changed/);
  assert.match(balance,/else render\(null\)/);
});

test('módulo de saldo carrega antes do orquestrador e está no manifesto',()=>{
  assert.ok(html.indexOf('./js/aviator/balance.js')>=0);
  assert.ok(html.indexOf('./aviator.js')>html.indexOf('./js/aviator/balance.js'));
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game?.assets.includes('./js/aviator/balance.js'));
});
