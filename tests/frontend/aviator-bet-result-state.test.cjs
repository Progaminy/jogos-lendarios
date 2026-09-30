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

test('resultado da aposta usa símbolo, palavra e detalhe textual',()=>{
  assert.match(html,/id="betResultPanel"[^>]*role="status"[^>]*aria-live="polite"[^>]*aria-atomic="true"/);
  assert.match(html,/id="betResultIcon"/);
  assert.match(html,/id="betResultLabel"/);
  assert.match(html,/id="betResultDetail"/);

  assert.match(ui,/icon\.textContent='✓'/);
  assert.match(ui,/label\.textContent='GANHA'/);
  assert.match(ui,/icon\.textContent='✕'/);
  assert.match(ui,/label\.textContent='PERDIDA'/);
  assert.match(ui,/icon\.textContent='↩'/);
  assert.match(ui,/label\.textContent='REEMBOLSADA'/);
});

test('estados não dependem apenas de cor',()=>{
  assert.match(css,/\.aviator-bet-result\.is-won\{border-style:solid\}/);
  assert.match(css,/\.aviator-bet-result\.is-lost\{border-style:double\}/);
  assert.match(css,/\.aviator-bet-result\.is-refunded\{border-style:dashed\}/);
  assert.match(ui,/panel\.dataset\.result='won'/);
  assert.match(ui,/panel\.dataset\.result='lost'/);
  assert.match(ui,/panel\.dataset\.result='refunded'/);
});

test('ganha mostra payout confirmado e multiplicador',()=>{
  assert.match(ui,/status==='CASHED_OUT'/);
  assert.match(ui,/'Recebido '\+money\(payout\)/);
  assert.match(ui,/multiplier\.toFixed\(2\)\+'×'/);
});

test('perdida e reembolsada mostram valor textual quando disponível',()=>{
  assert.match(ui,/status==='LOST'/);
  assert.match(ui,/'Valor perdido '\+money\(stake\)/);
  assert.match(ui,/'Devolvido '\+money\(stake\)/);
});

test('orquestrador usa somente estados autoritativos de liquidação',()=>{
  assert.match(js,/\['CASHED_OUT','LOST','REFUNDED'\]\.includes\(status\)/);
  assert.match(js,/setBetResultFromBet\(bet\)/);
  assert.match(js,/setBetResultFromBet\(latest\)/);
  assert.doesNotMatch(js,/Math\.random\(\).*setBetResult|setBetResult\(.*current_multiplier/);
});

test('cash-out direto registra resultado antes de limpar stake',()=>{
  const click=js.match(/\$\('#cashoutBtn'\)\.addEventListener\('click',[\s\S]*?\n\}\);/)?.[0]||'';
  const resultAt=click.indexOf("setBetResult({");
  const clearAt=click.indexOf("myStake=0");
  assert.ok(resultAt>=0);
  assert.ok(clearAt>resultAt);
  assert.match(click,/status:'CASHED_OUT'/);
  assert.match(click,/payout:Number\(r\.payout\)/);
});

test('resultado anterior só é limpo quando uma aposta ativa assume o contexto',()=>{
  assert.match(js,/if\(status==='ACTIVE'\)setBetResult\(null\)/);
  assert.match(js,/if\(current\)setBetResult\(null\)/);
  assert.match(js,/setBetResult\(null\);\n    personalHistory\?\.invalidate\(\);\n    myBet=r\.bet_id/);

  const changedRound=js.match(/if\(changedRound\)\{[\s\S]*?\n  \}/)?.[0]||'';
  assert.doesNotMatch(changedRound,/setBetResult\(null\)/);
});
