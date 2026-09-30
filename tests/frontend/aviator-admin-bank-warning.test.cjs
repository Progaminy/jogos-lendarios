'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('admin avisa quando a banca do Aviator implica teto muito baixo',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('js/aviator/admin.js','utf8');
  assert.match(html,/id="aviatorBankWarning"/);
  assert.match(js,/const referenceStake=10,referenceCeiling=1\+\(bankBalance\*exposure\/referenceStake\)/);
  assert.match(js,/referenceCeiling<1\.5/);
  assert.match(js,/teto financeiro estimado seria/);
});

test('aviso de banca é apenas informativo e não altera saldo',()=>{
  const js=fs.readFileSync('js/aviator/admin.js','utf8');
  const warningBlock=js.match(/const referenceStake=10[\s\S]*?const mt=\$\('aviatorMaintenanceToggle'\)/)?.[0]||'';
  assert.doesNotMatch(warningBlock,/jl_aviator_admin_adjust_bank/);
  assert.doesNotMatch(warningBlock,/p_delta/);
});
