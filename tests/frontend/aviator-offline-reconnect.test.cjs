const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');

test('ponto 59: offline congela ações financeiras e o estado visual local',()=>{
  const setConnection=js.match(/function setConnectionState\(online\)[\s\S]*?\n}\n\nfunction money/)?.[0]||'';
  assert.match(setConnection,/connectionOnline=Boolean\(online\)/);
  assert.match(setConnection,/cancelStateRequest\(\)/);
  assert.match(setConnection,/stopOpenUiTick\(\)/);
  assert.match(setConnection,/stopFlight\(\)/);
  assert.match(setConnection,/renderBetAction\(true,'Sem ligação'\)/);
  assert.match(setConnection,/renderCashoutAction\(\{[\s\S]*?disabled:true/);
  assert.match(setConnection,/SEM LIGAÇÃO/);
  assert.match(setConnection,/RECONEXÃO/);

  const cashout=js.match(/\$\('#cashoutBtn'\)\.addEventListener\('click',[\s\S]*?\n}\);/)?.[0]||'';
  assert.match(cashout,/if\(!connectionOnline\)/);
  assert.match(cashout,/Cash-out indisponível até reconectar/);

  const bet=js.match(/\$\('#aviatorBetForm'\)\.addEventListener\('submit',[\s\S]*?\n}\);/)?.[0]||'';
  assert.match(bet,/if\(!connectionOnline\)throw new Error\('Sem ligação/);
});

test('ponto 59: ao religar a internet cancela snapshot antigo e recupera servidor antes de reconciliar cash-out pendente',()=>{
  const online=js.match(/window\.addEventListener\('online',async\(\)=>\{[\s\S]*?\n}\);/)?.[0]||'';

  assert.match(online,/cancelStateRequest\(\)/);
  assert.match(online,/setConnectionState\(true\)/);
  assert.match(online,/lastRecoveredRoundId=null/);
  assert.match(online,/clearTimeout\(stateTimer\)/);
  assert.match(online,/Ligação restabelecida\. A sincronizar…/);

  const reconnectAt=online.indexOf('await reconnectState()');
  const reconcileAt=online.indexOf('await reconcilePendingCashout()');

  assert.ok(reconnectAt>=0,'reconexão deve buscar snapshot autoritativo');
  assert.ok(reconcileAt>reconnectAt,'cash-out pendente só deve ser reconciliado depois do snapshot');
  assert.doesNotMatch(online,/requestFinancialCashout|jl_aviator_cashout/);
});

test('ponto 59: reconciliação de cash-out ambíguo consulta status e nunca reenvia automaticamente',()=>{
  const reconcile=js.match(/async function reconcilePendingCashout\(\)[\s\S]*?\n}\n\nasync function recover/)?.[0]||'';

  assert.match(reconcile,/readPendingCashout\(\)/);
  assert.match(reconcile,/fetchBetStatus\(pending\.bet_id\)/);
  assert.match(reconcile,/bet\.status==='CASHED_OUT'/);
  assert.match(reconcile,/bet\.status==='ACTIVE'/);
  assert.match(reconcile,/bet\.status==='LOST'/);
  assert.match(reconcile,/clearPendingCashout\(\)/);
  assert.doesNotMatch(reconcile,/requestFinancialCashout|jl_aviator_cashout/);
});

test('ponto 59: evento offline e online estão ligados ao controlador de conexão',()=>{
  const offline=js.match(/window\.addEventListener\('offline',[\s\S]*?\n}\);/)?.[0]||'';
  const online=js.match(/window\.addEventListener\('online',[\s\S]*?\n}\);/)?.[0]||'';

  assert.match(offline,/setConnectionState\(false\)/);
  assert.match(online,/setConnectionState\(true\)/);
  assert.match(online,/await reconnectState\(\)/);
  assert.match(online,/await reconcilePendingCashout\(\)/);
});
