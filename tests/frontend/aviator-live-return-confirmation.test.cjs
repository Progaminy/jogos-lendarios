const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'../..');
const ui=fs.readFileSync(path.join(root,'js/aviator/ui.js'),'utf8');
const panel=fs.readFileSync(path.join(root,'js/aviator/bet-panel.js'),'utf8');
const main=fs.readFileSync(path.join(root,'aviator.js'),'utf8');
const runtime=fs.readFileSync(path.join(root,'js/aviator/runtime.js'),'utf8');
const engine=fs.readFileSync(path.join(root,'js/aviator/engine.js'),'utf8');

test('cash-out button shows the live monetary return in both bet slots',()=>{
  assert.match(ui,/liveReturn=active&&hasMultiplier&&hasStake\?money\(s\*m\):null/);
  assert.match(panel,/liveReturn=active&&hasMultiplier&&hasStake\?money\(stake\*m\):null/);
  assert.doesNotMatch(ui,/nextText=pending\?'Confirmando…':active\?'Sacar'/);
  assert.doesNotMatch(panel,/textContent=pending\?'Confirmando…':'Sacar'/);
});

test('confirmed bet no longer falls back to Apostar after the window closes',()=>{
  assert.match(main,/myBet\?'Foi apostado':'Apostar'/);
  assert.match(panel,/label:betId\?'Foi apostado':'Apostar'/);
  assert.match(panel,/label:betId\?'Foi apostado':queued\?'Cancelar':'Apostar'/);
});


test('browser display cannot exceed the 500x server ceiling',()=>{
  assert.match(runtime,/Math\.min\(500,Math\.max\(1,Math\.pow\(1\.06,seconds\)\)\)/);
  assert.match(engine,/Math\.min\(500,value\)/);
});
