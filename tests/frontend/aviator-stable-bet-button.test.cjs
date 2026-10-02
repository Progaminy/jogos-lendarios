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
const panel=read('js/aviator/bet-panel.js');
const ui=read('js/aviator/ui.js');

test('ação principal vive num único slot estrutural fixo',()=>{
  assert.match(html,/class="aviator-primary-action-slot"[\s\S]*id="betBtn"[\s\S]*id="cashoutAction"[\s\S]*id="cashoutBtn"/);
  assert.match(css,/\.aviator-primary-action-slot\{display:grid/);
});

test('botão de aposta nunca possui estado Cancelar',()=>{
  assert.doesNotMatch(js,/['"`]Cancelar['"`]/);
  assert.doesNotMatch(panel,/['"`]Cancelar['"`]/);
});

test('OPEN usa Apostar ou Foi apostado e envia fila do voo automaticamente',()=>{
  const clock=js.match(/function updateRoundClock\(\)[\s\S]*?function startOpenUiTick/)?.[0]||'';
  assert.match(clock,/myBet\|\|queued\?'Foi apostado':'Apostar'/);
  assert.match(clock,/nextBet\?\.schedule\?\.\(\)/);

  const secondary=panel.match(/function renderRound\(\)[\s\S]*?function betSlotOf/)?.[0]||'';
  assert.match(secondary,/label:betId\|\|queued\?'Foi apostado':'Apostar'/);
  assert.match(secondary,/nextBet\?\.schedule\?\.\(\)/);
});

test('FLYING permite Apostar quando não há aposta ativa nem fila',()=>{
  const flying=js.match(/function renderFlying\(\)[\s\S]*?function renderFinished/)?.[0]||'';
  assert.match(flying,/const canQueue=enabled&&connectionOnline&&!myBet&&!queued&&!betting/);
  assert.match(flying,/myBet\|\|queued\?'Foi apostado':'Apostar'/);
  assert.match(flying,/renderCashoutAction\([\s\S]*?active:Boolean\(myBet\)/);
  assert.match(ui,/liveReturn=active&&hasMultiplier&&hasStake\?money\(s\*m\):null/);
});

test('Apostar é verde e cash-out prioritário é vermelho',()=>{
  assert.match(css,/\.aviator-bet-action:not\(\.is-cancel\) button:not\(:disabled\)\{[\s\S]*?background:#36c979!important/);
  assert.match(css,/\.aviator-cashout-action\.is-priority button:not\(:disabled\)\{[\s\S]*?background:#d83b42!important/);
});
