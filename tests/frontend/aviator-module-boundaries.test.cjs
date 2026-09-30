'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const html=read('aviator.html');
const player=read('aviator.js');
const admin=read('admin.js');
const engine=read('js/aviator/engine.js');
const ui=read('js/aviator/ui.js');
const financial=read('js/aviator/financial.js');
const history=read('js/aviator/history.js');
const aviatorAdmin=read('js/aviator/admin.js');
const manifest=JSON.parse(read('games/manifest.json'));

test('Aviator carrega módulos próprios antes do orquestrador',()=>{
  const order=[
    'js/aviator/engine.js',
    'js/aviator/ui.js',
    'js/aviator/financial.js',
    'js/aviator/history.js',
    'aviator.js'
  ].map(x=>html.indexOf(x));
  assert.ok(order.every(x=>x>=0));
  assert.deepEqual([...order].sort((a,b)=>a-b),order);
});

test('engine é apresentação/tempo e não financeiro',()=>{
  assert.match(engine,/JLAviatorEngine/);
  assert.match(engine,/syncServerClock/);
  assert.match(engine,/multiplier/);
  assert.match(engine,/pollDelay/);
  assert.doesNotMatch(engine,/jl_aviator_cashout|jl_aviator_place_bet|payout_transaction|balance/);
});

test('UI não chama RPC nem conhece endpoints financeiros',()=>{
  assert.match(ui,/JLAviatorUI/);
  assert.match(ui,/renderMultiplier/);
  assert.match(ui,/renderTicket/);
  assert.doesNotMatch(ui,/JLApi\.rpc|jl_aviator_|fetch\(/);
});

test('financeiro contém cash-out/idempotência e não renderiza DOM',()=>{
  assert.match(financial,/JLAviatorFinancial/);
  assert.match(financial,/jl_aviator_cashout/);
  assert.match(financial,/jl_aviator_bet_status/);
  assert.match(financial,/cashoutRequestKey/);
  assert.doesNotMatch(financial,/querySelector|innerHTML|textContent|classList/);
});

test('histórico é módulo próprio e isolado do financeiro',()=>{
  assert.match(history,/JLAviatorHistory/);
  assert.match(history,/jl_aviator_recent_results/);
  assert.doesNotMatch(history,/jl_aviator_cashout|jl_aviator_place_bet|jl_player_ledger_balance/);
});

test('admin geral delega toda administração Aviator ao módulo próprio',()=>{
  assert.match(aviatorAdmin,/JLAviatorAdmin/);
  assert.match(aviatorAdmin,/jl_aviator_admin_state/);
  assert.match(aviatorAdmin,/jl_aviator_admin_close/);
  assert.match(aviatorAdmin,/jl_aviator_admin_cancel_round/);
  assert.match(admin,/JLAviatorAdmin\?\.create/);
  assert.doesNotMatch(admin,/function refreshAviatorAdmin\(/);
  assert.doesNotMatch(admin,/function closeAviatorFromAdmin\(/);
});

test('orquestrador usa módulos em vez de reimplementar responsabilidades',()=>{
  assert.match(player,/JLAviatorEngine\.create/);
  assert.match(player,/JLAviatorUI\.create/);
  assert.match(player,/JLAviatorFinancial\.create/);
  assert.match(player,/JLAviatorHistory\.create/);
  assert.match(player,/return financial\.requestFinancialCashout/);
  assert.match(player,/return history\.load/);
  assert.ok(player.length<40000,'aviator.js voltou a crescer além da função de orquestrador');
});

test('manifesto registra bundles e admin próprios do Aviator',()=>{
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game);
  for(const asset of [
    './js/aviator/engine.js',
    './js/aviator/ui.js',
    './js/aviator/financial.js',
    './js/aviator/history.js'
  ]) assert.ok(game.assets.includes(asset));
  assert.deepEqual(game.adminAssets,['./js/aviator/admin.js']);
});
