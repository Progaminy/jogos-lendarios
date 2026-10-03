'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'../..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

const main=read('aviator.js');
const panel=read('js/aviator/bet-panel.js');

test('auto cash-out keeps reconciling until server marks bet settled',()=>{
  for(const source of [main,panel]){
    assert.match(source,/autoRecoveryLastCheckAt=0/);
    assert.match(source,/now-autoRecoveryLastCheckAt>=500/);
    assert.match(source,/autoRecoveryLastCheckAt=now/);
  }
});

test('auto cash-out retry remains gated by active bet and target multiplier',()=>{
  assert.match(main,/myBet&&[\s\S]*?myAutoCashout&&[\s\S]*?mul\(\)>=myAutoCashout/);
  assert.match(panel,/betId&&[\s\S]*?autoCashout&&[\s\S]*?Number\(value\)>=autoCashout/);
});

test('round change clears auto cash-out reconciliation throttle',()=>{
  assert.match(main,/autoRecoveryRoundId=null;\s*autoRecoveryLastCheckAt=0;\s*lastRecoveredRoundId=null/);
  assert.match(panel,/autoRecoveryRoundId=null;\s*autoRecoveryLastCheckAt=0;\s*autoBetAttemptedRoundId=null/);
});
