'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const html=read('aviator.html');
const personal=read('js/aviator/personal-history.js');
const globalHistory=read('js/aviator/history.js');
const js=read('aviator.js');
const manifest=JSON.parse(read('games/manifest.json'));

test('histórico pessoal e global são secções diferentes',()=>{
  assert.match(html,/id="aviatorMyHistoryCard"/);
  assert.match(html,/>Minhas apostas</);
  assert.match(html,/id="aviatorHistoryCard"/);
  assert.match(html,/>Histórico global</);
  assert.ok(html.indexOf('aviatorMyHistoryCard')<html.indexOf('aviatorHistoryCard'));
});

test('histórico pessoal é lazy e não carrega no arranque',()=>{
  assert.match(personal,/details\?\.addEventListener\('toggle'/);
  assert.match(personal,/if\(details\.open&&!loaded\)void load\(true\)/);
  assert.doesNotMatch(js,/personalHistory\.load\(/);
});

test('histórico pessoal usa RPC dedicado e nunca o RPC pesado de saldo',()=>{
  assert.match(personal,/jl_aviator_my_history/);
  assert.doesNotMatch(personal,/jl_aviator_player_state|jl_player_ledger_balance/);
  assert.match(personal,/p_limit:20/);
  assert.match(personal,/p_before_id:reset\?null:nextBeforeId/);
});

test('carregar mais usa paginação por cursor',()=>{
  assert.match(personal,/nextBeforeId=result\?\.next_before_id\?\?null/);
  assert.match(personal,/hasMore=result\?\.has_more===true/);
  assert.match(personal,/moreBtn\?\.addEventListener\('click',\(\)=>void load\(false\)\)/);
});

test('linhas pessoais têm estados textuais, símbolos e campos detalhados',()=>{
  assert.match(personal,/icon:'✓',label:'GANHA'/);
  assert.match(personal,/icon:'✕',label:'PERDIDA'/);
  assert.match(personal,/icon:'↩',label:'REEMBOLSADA'/);
  assert.match(personal,/icon:'●',label:'ATIVA'/);
  for(const label of ['Rodada','Apostado','Cash-out','Crash','Pagamento','Horário']){
    assert.ok(personal.includes("['"+label+"'"));
  }
});

test('histórico global continua independente',()=>{
  assert.match(globalHistory,/jl_aviator_recent_results/);
  assert.doesNotMatch(globalHistory,/jl_aviator_my_history/);
});

test('nova aposta ou liquidação invalida cache pessoal',()=>{
  assert.match(js,/personalHistory\?\.invalidate\(\)/);
});

test('manifesto registra módulo pessoal separado',()=>{
  const game=manifest.games.find(x=>x.id==='aviator');
  assert.ok(game);
  assert.ok(game.assets.includes('./js/aviator/personal-history.js'));
});
