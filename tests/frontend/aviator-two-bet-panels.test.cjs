'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

const html=fs.readFileSync('aviator.html','utf8');
const css=fs.readFileSync('aviator.css','utf8');
const player=fs.readFileSync('aviator.js','utf8');
const panel=fs.readFileSync('js/aviator/bet-panel.js','utf8');
const financial=fs.readFileSync('js/aviator/financial.js','utf8');
const nextBet=fs.readFileSync('js/aviator/next-bet.js','utf8');

test('Aviator expõe dois painéis independentes de aposta',()=>{
  for(const id of [
    'aviatorBetForm','aviatorAmount','aviatorAutoCashout','aviatorAutoCashoutEnabled','aviatorAutoBet','betBtn','cashoutBtn',
    'aviatorBetForm2','aviatorAmount2','aviatorAutoCashout2','aviatorAutoCashoutEnabled2','aviatorAutoBet2','betBtn2','cashoutBtn2'
  ]) assert.match(html,new RegExp('id="'+id+'"'));
});

test('desktop usa dois cartões e mobile empilha os painéis',()=>{
  assert.match(css,/\.aviator-controls\{display:grid;grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(css,/@media\(max-width:650px\)[\s\S]*?\.aviator-controls\{grid-template-columns:1fr/);
});

test('mobile mantém multiplicador limpo e confirmação em linha própria',()=>{
  assert.match(css,/grid-template-columns:minmax\(0,1\.08fr\) minmax\(78px,\.78fr\) minmax\(126px,1\.2fr\)/);
  assert.match(html,/class="field bet-amount-field"/);
  assert.match(css,/form>\.bet-amount-field\{[\s\S]*?grid-column:1!important;[\s\S]*?grid-row:1!important/);
  assert.match(css,/form>\.auto-cashout-field\{[\s\S]*?grid-column:2!important;[\s\S]*?grid-row:1!important/);
  assert.match(css,/form>\.aviator-primary-action-slot\{[\s\S]*?grid-column:3!important;[\s\S]*?grid-row:1\/3!important/);
  assert.match(css,/form>\.auto-cashout-enable\{[\s\S]*?grid-column:2!important;[\s\S]*?grid-row:2!important/);
  assert.match(css,/form>\.aviator-auto-bet-toggle\{[\s\S]*?grid-column:1!important;[\s\S]*?grid-row:2!important/);
  assert.match(css,/\.stake-stepper \.money-input input\{[\s\S]*?text-align:center/);
  assert.match(css,/\.auto-cashout-field \.money-input input\{[\s\S]*?text-align:center/);
  assert.doesNotMatch(html,/class="auto-cashout-config"/);
});

test('multiplicador só ativa saída automática quando a caixa está marcada',()=>{
  assert.match(player,/const autoEnabled=Boolean\(\$\('#aviatorAutoCashoutEnabled'\)\?\.checked\)/);
  assert.match(player,/const auto=autoEnabled\?Number\(autoRaw\):null/);
  assert.match(panel,/const autoEnabled=Boolean\(\$\('#aviatorAutoCashoutEnabled'\+suffix\)\?\.checked\)/);
  assert.match(panel,/const auto=autoEnabled\?Number\(autoRaw\):null/);
  assert.match(nextBet,/const enabled=Boolean\(\$\('#aviatorAutoCashoutEnabled'\+suffix\)\?\.checked\)/);
  assert.match(nextBet,/const auto=enabled\?Number\(raw\):null/);
  assert.match(nextBet,/autoEnabled\.checked=queued\.auto_cashout!==null/);
});

test('cada painel usa slot financeiro próprio',()=>{
  assert.match(player,/financial\.placeBetSlot\(\{[\s\S]*?slot:1/);
  assert.match(panel,/slot=2/);
  assert.match(panel,/financial\.placeBetSlot\(\{[\s\S]*?slot,/);
  assert.match(financial,/jl_aviator_place_bet_slot/);
});

test('painel 2 pode cancelar fila e aposta confirmada antes do fecho',()=>{
  assert.match(panel,/action==='cancel-next'/);
  assert.match(panel,/action==='cancel'/);
  assert.match(panel,/financial\.cancelBet\(/);
  assert.match(panel,/financial\.resetBetKeyForSlot\(slot\)/);
  assert.match(panel,/label:queued\?'Cancelar'/);
});

test('painel 2 mantém cash-out próprio durante voo',()=>{
  assert.match(panel,/financial\.requestFinancialCashout\(/);
  assert.match(panel,/liveReturn=active&&hasMultiplier&&hasStake\?money\(stake\*m\):null/);
  assert.match(panel,/cashoutButton\.textContent=pending\?'Confirmando…':liveReturn\|\|'Sacar'/);
});

test('orquestrador continua abaixo do limite modular',()=>{
  assert.ok(player.length<43000,'aviator.js deve permanecer apenas como orquestrador');
});
