'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('cancelamento administrativo do Aviator exige motivo e reembolsa via servidor',()=>{
  const html=fs.readFileSync('admin.html','utf8');
  const js=fs.readFileSync('js/aviator/admin.js','utf8');

  assert.match(html,/CANCELAMENTO DA RODADA/);
  assert.match(html,/id="aviatorCancelReason"/);
  assert.match(html,/minlength="5"/);
  assert.match(html,/maxlength="240"/);
  assert.match(html,/id="aviatorCancelRound"/);
  assert.match(html,/Cancelar rodada e reembolsar/);

  assert.match(js,/\['OPEN','LOCKED','FLYING'\]\.includes/);
  assert.match(js,/jl_aviator_admin_cancel_round/);
  assert.match(js,/p_round_id:roundId/);
  assert.match(js,/p_reason:reason/);
  assert.match(js,/reason\.length<5/);
  assert.match(js,/refunded_bets/);
  assert.match(js,/refunded_total/);
  assert.match(js,/cashouts_kept/);
  assert.doesNotMatch(js,/status='REFUNDED'|balance=round\(balance\+/);
});

test('CRASHED e estados finais não ficam canceláveis no painel',()=>{
  const js=fs.readFileSync('js/aviator/admin.js','utf8');
  const cancellable=js.match(
    /const cancellable=\['OPEN','LOCKED','FLYING'\]\.includes\(String\(r\.status\|\|''\)\)/
  )?.[0]||'';

  assert.ok(cancellable);
  assert.doesNotMatch(cancellable,/CRASHED|SETTLED|CANCELLED/);
});
