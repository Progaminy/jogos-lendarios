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

test('OPEN alterna entre Apostar e Cancelar até o fecho',()=>{
  const clock=js.match(/function updateRoundClock\(\)[\s\S]*?function startOpenUiTick/)?.[0]||'';
  assert.match(clock,/myBet\|\|queued\?'Cancelar':'Apostar'/);
  assert.match(clock,/myBet\?'cancel':queued\?'cancel-next':'bet'/);

  const secondary=panel.match(/function renderRound\(\)[\s\S]*?function betSlotOf/)?.[0]||'';
  assert.match(secondary,/label:betId\|\|queued\?'Cancelar':'Apostar'/);
  assert.match(secondary,/mode:betId\?'cancel':queued\?'cancel-next':'bet'/);
});

test('FLYING permite Apostar e depois Cancelar a fila da próxima rodada',()=>{
  const flying=js.match(/function renderFlying\(\)[\s\S]*?function renderFinished/)?.[0]||'';
  assert.match(flying,/const canQueue=enabled&&connectionOnline&&!myBet&&!queued&&!betting/);
  assert.match(flying,/queued\?'Cancelar':myBet\?'Foi apostado':'Apostar'/);
  assert.match(flying,/queued\?'cancel-next':myBet\?'confirmed':'bet'/);
  assert.match(ui,/liveReturn=active&&hasMultiplier&&hasStake\?money\(s\*m\):null/);
});

test('Cancelar é vermelho, Apostar verde e cash-out prioritário vermelho',()=>{
  assert.match(css,/\.aviator-bet-action\.is-cancel #betBtn:not\(:disabled\)/);
  assert.match(css,/\.aviator-bet-action:not\(\.is-cancel\) button:not\(:disabled\)\{[\s\S]*?background:#36c979!important/);
  assert.match(css,/\.aviator-cashout-action\.is-priority button:not\(:disabled\)\{[\s\S]*?background:#d83b42!important/);
});
