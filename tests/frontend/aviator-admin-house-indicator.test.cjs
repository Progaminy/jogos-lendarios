'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('indicador financeiro da casa usa snapshot do servidor e atualização automática',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('admin.js','utf8');
  const css=fs.readFileSync('styles.css','utf8');

  assert.match(html,/FINANCEIRO DA CASA · TEMPO REAL/);
  for(const id of [
    'aviatorHouseIndicator',
    'aviatorHouseStatus',
    'aviatorHouseBank',
    'aviatorHouseLiability',
    'aviatorHouseAvailable',
    'aviatorHouseRiskUsage',
    'aviatorHouseRoundResult',
    'aviatorHouseUpdated'
  ]){
    assert.match(html,new RegExp('id="'+id+'"'));
  }

  assert.match(js,/const house=d\.house\|\|\{\}/);
  assert.match(js,/house\.bank_balance/);
  assert.match(js,/house\.active_liability/);
  assert.match(js,/house\.available_after_worst_case/);
  assert.match(js,/house\.risk_usage_pct/);
  assert.match(js,/house\.round_realized_result/);
  assert.match(js,/HEALTHY:'Saudável'/);
  assert.match(js,/ATTENTION:'Atenção'/);
  assert.match(js,/CRITICAL:'Crítico'/);

  assert.match(js,/setInterval\(\(\)=>\{if\(state\.token\)refreshAviatorAdmin\(\)\},3000\)/);

  assert.match(css,/aviator-house-indicator\[data-state="ATTENTION"\]/);
  assert.match(css,/aviator-house-indicator\[data-state="CRITICAL"\]/);

  // O navegador apenas apresenta; a responsabilidade financeira fica no backend.
  assert.doesNotMatch(js,/active_liability\s*=|risk_usage_pct\s*=|available_after_worst_case\s*=/);
});
