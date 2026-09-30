'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const html=read('aviator.html');
const css=read('aviator.css');
const js=read('aviator.js');
const ui=read('js/aviator/ui.js');
const financial=read('js/aviator/financial.js');

test('cash-out tem slot próprio e grande',()=>{
  assert.match(html,/id="cashoutAction" class="aviator-cashout-action"[\s\S]*id="cashoutBtn"/);
  assert.match(css,/\.aviator-cashout-action\{display:grid;grid-template-rows:64px 16px/);
  assert.match(css,/\.aviator-cashout-action #cashoutBtn\{width:100%;height:64px;min-height:64px/);
});

test('mobile aumenta ainda mais a ação de cash-out',()=>{
  assert.match(css,/\.aviator-cashout-action\{grid-template-rows:72px 18px/);
  assert.match(css,/\.aviator-cashout-action #cashoutBtn\{height:72px;min-height:72px;font-size:1\.28rem\}/);
});

test('voo com aposta ativa recebe prioridade visual forte',()=>{
  assert.match(ui,/wrap\.classList\.toggle\('is-priority',Boolean\(active\)&&!disabled&&!pending\)/);
  assert.match(css,/\.aviator-cashout-action\.is-priority #cashoutBtn:not\(:disabled\)/);
  assert.match(css,/background:#36c979/);
  assert.match(css,/box-shadow:0 0 0 2px rgba\(78,213,138,\.28\),0 14px 34px rgba\(78,213,138,\.24\)/);
});

test('cash-out mostra multiplicador e retorno estimado apenas como apresentação',()=>{
  assert.match(ui,/'Cash-out · '\+m\.toFixed\(2\)\+'×'/);
  assert.match(ui,/'Recebe agora '\+money\(s\*m\)/);
  assert.doesNotMatch(ui,/JLApi\.rpc|jl_aviator_cashout|payout_transaction/);
});

test('orquestrador ativa prioridade somente durante voo com aposta',()=>{
  const flying=js.match(/function renderFlying\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(flying,/renderCashoutAction\(/);
  assert.match(flying,/active:Boolean\(myBet\)/);
  assert.match(flying,/disabled:!connectionOnline\|\|!myBet\|\|cashingOut/);
});

test('confirmação mantém o mesmo slot sem deslocar a ação',()=>{
  const click=js.match(/\$\('#cashoutBtn'\)\.addEventListener\('click',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(click,/renderCashoutAction\(\{/);
  assert.match(click,/pending:true/);
  assert.match(click,/status:'A confirmar no servidor'/);
  assert.doesNotMatch(click,/appendChild|insertBefore|replaceWith/);
});

test('financeiro continua autoritativo no servidor',()=>{
  assert.match(financial,/jl_aviator_cashout/);
  assert.match(financial,/p_bet_id:Number\(betId\)/);
  assert.doesNotMatch(financial,/p_multiplier|estimated_payout|client_payout/);
});
