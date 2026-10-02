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

test('botão de aposta não possui estado Cancelar fantasma',()=>{
  assert.doesNotMatch(js,/['"`]Cancelar['"`]/);
  assert.doesNotMatch(js,/queue-next|cancel-next/);
  assert.doesNotMatch(panel,/['"`]Cancelar['"`]/);
  assert.doesNotMatch(panel,/queue-next|cancel-next/);
});

test('OPEN usa apenas Apostar ou Foi apostado conforme confirmação do servidor',()=>{
  const clock=js.match(/function updateRoundClock\(\)[\s\S]*?function startOpenUiTick/)?.[0]||'';
  assert.match(clock,/myBet\?'Foi apostado':'Apostar'/);
  assert.match(clock,/myBet\?'confirmed':'bet'/);
  assert.doesNotMatch(clock,/canCancel|cancel-next|queue-next/);

  const secondary=panel.match(/function renderRound\(\)[\s\S]*?function betSlotOf/)?.[0]||'';
  assert.match(secondary,/label:betId\?'Foi apostado':'Apostar'/);
  assert.doesNotMatch(secondary,/queued|cancel-next|queue-next/);
});

test('FLYING esconde aposta confirmada e mostra retorno monetário para sacar',()=>{
  const flying=js.match(/function renderFlying\(\)[\s\S]*?function renderFinished/)?.[0]||'';
  assert.match(flying,/renderBetAction\([\s\S]*?Boolean\(myBet\)/);
  assert.match(flying,/renderCashoutAction\([\s\S]*?active:Boolean\(myBet\)/);
  assert.match(ui,/liveReturn=active&&hasMultiplier&&hasStake\?money\(s\*m\):null/);
  assert.match(panel,/liveReturn=active&&hasMultiplier&&hasStake\?money\(stake\*m\):null/);
});

test('Apostar é verde e cash-out prioritário é vermelho',()=>{
  assert.match(css,/\.aviator-bet-action:not\(\.is-cancel\) button:not\(:disabled\)\{[\s\S]*?background:#36c979!important/);
  assert.match(css,/\.aviator-cashout-action\.is-priority button:not\(:disabled\)\{[\s\S]*?background:#d83b42!important/);
});
