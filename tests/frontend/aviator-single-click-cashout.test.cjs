'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const js=read('aviator.js');
const ui=read('js/aviator/ui.js');
const css=read('aviator.css');
const html=read('aviator.html');
const financial=read('js/aviator/financial.js');

test('cash-out continua sendo uma única ação sem confirmação extra',()=>{
  const click=js.match(/\$\('#cashoutBtn'\)\.addEventListener\('click',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(click,/if\(!cashoutGestureGuard\.shouldAcceptClick\(event\)\)return/);
  assert.match(click,/cashingOut=true/);
  assert.match(click,/requestFinancialCashout\(id,requestKey\)/);
  assert.doesNotMatch(click,/confirm\(|prompt\(|alert\(|setTimeout|hold|segunda|tem certeza/i);
});

test('arrasto ou scroll sobre o botão não dispara cash-out',()=>{
  assert.match(ui,/function createCashoutGestureGuard\(button,\{maxTravelPx=14\}=\{\}\)/);
  assert.match(ui,/Math\.hypot\(dx,dy\)>maxTravelPx/);
  assert.match(ui,/pointer\.moved=true/);
  assert.match(ui,/const accepted=Boolean\(pointer\)&&!pointer\.moved/);
});

test('teclado e navegadores sem Pointer Events continuam com um clique',()=>{
  assert.match(ui,/event\?\.detail===0\|\|!supportsPointer/);
  assert.match(ui,/typeof globalThis\.PointerEvent==='function'/);
});

test('primeiro clique válido trava imediatamente repetições',()=>{
  const click=js.match(/\$\('#cashoutBtn'\)\.addEventListener\('click',[\s\S]*?\n\}\);/)?.[0]||'';
  const guardAt=click.indexOf('if(cashingOut||!myBet');
  const lockAt=click.indexOf('cashingOut=true');
  const rpcAt=click.indexOf('requestFinancialCashout');
  assert.ok(guardAt>=0);
  assert.ok(lockAt>guardAt);
  assert.ok(rpcAt>lockAt);
  assert.match(click,/renderCashoutAction\(\{[\s\S]*?pending:true/);
});

test('touch é otimizado sem atraso artificial',()=>{
  assert.match(css,/touch-action:manipulation/);
  assert.match(css,/user-select:none/);
  assert.doesNotMatch(js,/cashout.*debounce|cashout.*setTimeout|cashout.*delay/i);
});

test('cash-out mantém proteção financeira/idempotente no servidor',()=>{
  assert.match(financial,/jl_aviator_cashout/);
  assert.match(financial,/p_request_key:String\(requestKey/);
  assert.match(financial,/p_bet_id:id/);
});

test('estado do cash-out é associado ao botão para acessibilidade',()=>{
  assert.match(html,/id="cashoutBtn"[^>]*aria-describedby="cashoutActionStatus"/);
});
