'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('admin mostra exposição da rodada do Aviator a partir do snapshot do servidor',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  assert.match(html,/EXPOSIÇÃO DA RODADA/);
  assert.match(html,/id="aviatorStaked"/);
  assert.match(html,/id="aviatorPotentialPayout"/);
  assert.match(html,/id="aviatorPlayers"/);
  assert.match(html,/id="aviatorCashouts"/);
  assert.match(html,/id="aviatorCashoutsPaid"/);

  assert.match(js,/const roundExposure=d\.exposure\|\|\{\}/);
  assert.match(js,/roundExposure\.total_staked/);
  assert.match(js,/roundExposure\.potential_payment/);
  assert.match(js,/roundExposure\.players/);
  assert.match(js,/roundExposure\.cashouts/);
  assert.match(js,/roundExposure\.cashout_paid/);

  assert.doesNotMatch(js,/potential_payment\s*=|players\s*=\s*new Set|cashouts\s*=\s*.*filter/);
});
