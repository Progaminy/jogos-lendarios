'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const personal=read('js/aviator/personal-history.js');
const css=read('aviator.css');
const html=read('aviator.html');

test('cada aposta mostra painel e os detalhes financeiros pedidos',()=>{
  for(const label of ['Painel','Rodada','Apostado','Cash-out','Crash','Pagamento','Horário']){
    assert.ok(personal.includes("['"+label+"'"),label+' ausente');
  }
  assert.match(personal,/row\?\.cashout_multiplier/);
  assert.match(personal,/row\?\.crash_multiplier/);
  assert.match(personal,/row\?\.payout/);
  assert.match(personal,/row\?\.created_at/);
  assert.match(personal,/row\?\.bet_slot/);
  assert.match(personal,/\['Painel','Aposta '\+slot\]/);
});

test('valores desconhecidos aparecem como traço em vez de zero ou data inventada',()=>{
  assert.match(personal,/if\(value===null\|\|value===undefined\|\|value===''\)return null/);
  assert.match(personal,/return n===null\?'—':formatter\(n\)/);
  assert.match(personal,/if\(value===null\|\|value===undefined\|\|value===''\)return ''/);
  assert.doesNotMatch(personal,/new Date\(value\)[\s\S]{0,80}1970/);
});

test('pagamento diferencia ganho, perda, reembolso e aposta ativa',()=>{
  assert.match(personal,/status==='CASHED_OUT'/);
  assert.match(personal,/return payout===null\?'—':money\(payout\)/);
  assert.match(personal,/status==='LOST'/);
  assert.match(personal,/return money\(0\)/);
  assert.match(personal,/status==='REFUNDED'/);
  assert.match(personal,/stake===null\?'Reembolsada':money\(stake\)\+' \(reembolso\)'/);
});

test('horário usa created_at retornado pelo servidor',()=>{
  assert.match(personal,/\['Horário',formatTime\(row\?\.created_at\)\|\|'—'\]/);
  assert.match(personal,/day:'2-digit',month:'2-digit'/);
  assert.match(personal,/hour:'2-digit',minute:'2-digit'/);
});

test('detalhes são uma grelha responsiva sem scroll horizontal obrigatório',()=>{
  assert.match(css,/\.aviator-my-history-fields\{display:grid;grid-template-columns:repeat\(3,minmax\(0,1fr\)\)/);
  assert.match(css,/\.aviator-my-history-fields\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(html,/personal-history\.js\?v=\d{8}-\d+/);
});
