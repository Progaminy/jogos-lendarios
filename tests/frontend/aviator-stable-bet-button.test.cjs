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

test('ação principal vive num único slot estrutural fixo',()=>{
  assert.match(html,/class="aviator-primary-action-slot"[\s\S]*id="betBtn"[\s\S]*id="cashoutAction"[\s\S]*id="cashoutBtn"/);
  assert.match(css,/\.aviator-primary-action-slot\{display:grid/);
  assert.match(css,/\.aviator-primary-action-slot>\.aviator-bet-action,\.aviator-primary-action-slot>\.aviator-cashout-action\{grid-area:1\/1\}/);
});

test('mobile mantém o mesmo slot grande sem deslocamento',()=>{
  assert.match(css,/\.aviator-primary-action-slot\{grid-column:1\/-1\}/);
  assert.match(css,/\.aviator-bet-action #betBtn\{height:72px;min-height:72px;font-size:1\.28rem\}/);
  assert.match(css,/\.aviator-cashout-action #cashoutBtn\{height:72px;min-height:72px;font-size:1\.28rem\}/);
});

test('ação muda Apostar -> Cancelar -> Cash-out conforme estado',()=>{
  assert.match(ui,/label='Apostar'/);
  assert.match(ui,/mode='bet'/);
  assert.match(ui,/wrap\.classList\.toggle\('is-cancel',mode==='cancel'\)/);
  assert.match(js,/'Cancelar',[\s\S]*?'cancel'/);
  assert.match(js,/renderCashoutAction\(\{[\s\S]*?active:Boolean\(myBet\)/);
});

test('OPEN com aposta confirmada disponibiliza cancelamento real',()=>{
  assert.match(js,/const canCancel=[\s\S]*?Boolean\(myBet\)[\s\S]*?!closed/);
  assert.match(js,/Aposta confirmada · toque para cancelar/);
  assert.match(js,/financial\.cancelBet\(/);
  assert.match(js,/financial\.cancelBetRequestKey\(id\)/);
});

test('FLYING esconde ação de aposta quando existe cash-out',()=>{
  const flying=js.match(/function renderFlying\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(flying,/renderBetAction\([\s\S]*?Boolean\(myBet\)/);
  assert.match(flying,/renderCashoutAction\([\s\S]*?active:Boolean\(myBet\)/);
});


test('mobile mantém os botões dos dois slots dentro da largura disponível',()=>{
  assert.match(css,/\.aviator-bet-action button,[\s\S]*?\.aviator-cashout-action button\{[\s\S]*?min-width:0;[\s\S]*?max-width:100%;[\s\S]*?white-space:normal/);
  assert.match(css,/#betBtn2,#cashoutBtn2\{[\s\S]*?min-height:91px/);
  assert.match(css,/@media\(max-width:650px\)[\s\S]*?#betBtn2,#cashoutBtn2\{[\s\S]*?min-height:77px/);
  assert.match(css,/overflow-wrap:anywhere/);
});
