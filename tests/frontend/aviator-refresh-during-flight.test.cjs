const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const runtime=require('../../js/aviator/runtime.js');

test('ponto 58: refresh durante FLYING reconstrói a mesma rodada pelo snapshot autoritativo',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');

  const reconnect=js.match(/async function reconnectState\(\)[\s\S]*?\n}\n\nasync function state/)?.[0]||'';
  assert.match(reconnect,/jl_aviator_reconnect/);
  assert.match(reconnect,/syncServerClock\(x\)/);
  assert.match(reconnect,/round=x\.round\|\|null/);
  assert.match(reconnect,/applyReconnectPlayerState\(x\?\.player\)/);
  assert.match(reconnect,/renderCurrentRound\(\)/);
  assert.match(reconnect,/round\?\.status==='FLYING'&&myBet/);

  const boot=js.slice(js.lastIndexOf('renderHistory();'));
  assert.match(boot,/startRealtime\(\)/);
  assert.match(boot,/if\(connectionOnline\)\{\s*reconnectState\(\);\s*\}/);
  assert.doesNotMatch(boot,/\bstate\(\);/);
});

test('ponto 58: snapshot de refresh preserva aposta ACTIVE e não reinicia multiplicador em 1x',()=>{
  const roundId=581;
  const bets=[
    {id:91,round_id:roundId,status:'ACTIVE',stake:25},
    {id:90,round_id:580,status:'LOST',stake:10}
  ];

  assert.equal(runtime.pickActiveBet(bets,roundId)?.id,91);

  const started='2026-10-01T20:00:00.000Z';
  const serverNow=Date.parse(started)+8000;
  const multiplier=runtime.liveMultiplier(started,serverNow);

  assert.ok(multiplier>1,'refresh não pode reiniciar visualmente o voo em 1x');
  assert.ok(Math.abs(multiplier-Math.pow(1.06,8))<1e-10);
  assert.equal(runtime.phase('FLYING'),'flying');
});

test('ponto 58: snapshot antigo depois do refresh não pode fazer a UI andar para trás',()=>{
  assert.equal(runtime.shouldAcceptSnapshot(undefined,5800),true);
  assert.equal(runtime.shouldAcceptSnapshot(5800,5801),true);
  assert.equal(runtime.shouldAcceptSnapshot(5801,5800),false);
});
