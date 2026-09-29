const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const runtime=require('../../js/aviator/runtime.js');

test('multiplicador começa em 1x e usa crescimento determinístico',()=>{
  assert.equal(runtime.multiplier(1000,1000),1);
  assert.equal(runtime.multiplier(2000,1000),1);
  const tenSeconds=runtime.multiplier(1000,11000);
  assert.ok(Math.abs(tenSeconds-Math.pow(1.06,10))<1e-12);
});

test('contagem de pré-voo arredonda para cima e nunca fica negativa',()=>{
  assert.equal(runtime.secondsUntil(11000,1000),10);
  assert.equal(runtime.secondsUntil(10999,1000),10);
  assert.equal(runtime.secondsUntil(1001,1000),1);
  assert.equal(runtime.secondsUntil(1000,1000),0);
  assert.equal(runtime.secondsUntil(500,1000),0);
  assert.equal(runtime.secondsUntil(Number.NaN,1000),null);
});

test('relógio do servidor compensa metade da latência de ida e volta',()=>{
  const sample=runtime.clockSample(2000,1000,1400);
  assert.deepEqual(sample,{offset:800,rtt:400});
  assert.equal(runtime.clockSample(2000,1400,1000),null);
  assert.equal(runtime.clockSample(Number.NaN,1000,1400),null);
});

test('recuperação escolhe apenas aposta ACTIVE da rodada pedida',()=>{
  const bets=[
    {id:4,round_id:10,status:'ACTIVE',stake:20},
    {id:7,round_id:11,status:'ACTIVE',stake:30},
    {id:8,round_id:11,status:'CASHED_OUT',stake:40},
    {id:9,round_id:11,status:'ACTIVE',stake:50}
  ];
  assert.equal(runtime.pickActiveBet(bets,10).id,4);
  assert.equal(runtime.pickActiveBet(bets,11).id,9);
  assert.equal(runtime.pickActiveBet(bets,12),null);
});

test('reconciliação encontra uma aposta específica pelo bet_id',()=>{
  const bets=[
    {id:11,round_id:3,status:'ACTIVE'},
    {id:12,round_id:3,status:'CASHED_OUT',cashout_multiplier:2.4,payout:24}
  ];
  assert.equal(runtime.findBetById(bets,12).status,'CASHED_OUT');
  assert.equal(runtime.findBetById(bets,99),null);
});

test('polling reduz carga fora da aba e acelera apenas durante voo',()=>{
  assert.equal(runtime.pollDelay('FLYING',false),700);
  assert.equal(runtime.pollDelay('OPEN',false),1000);
  assert.equal(runtime.pollDelay('SETTLED',false),1400);
  assert.equal(runtime.pollDelay('FLYING',true),5000);
});

test('fases públicas mapeiam para estados visuais estáveis',()=>{
  assert.equal(runtime.phase('OPEN'),'open');
  assert.equal(runtime.phase('FLYING'),'flying');
  assert.equal(runtime.phase('CRASHED'),'crashed');
  assert.equal(runtime.phase('SETTLED'),'crashed');
  assert.equal(runtime.phase('CANCELLED'),'waiting');
});

test('HTML carrega runtime antes do controlador principal',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const runtimeAt=html.indexOf('./js/aviator/runtime.js');
  const controllerAt=html.indexOf('./aviator.js');
  assert.ok(runtimeAt>=0,'runtime do Aviator deve estar incluído');
  assert.ok(controllerAt>runtimeAt,'runtime deve carregar antes de aviator.js');
});

test('HTML mantém histórico e bilhete ao vivo com ids estáveis',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  for(const id of [
    'aviatorHistory',
    'historyStatus',
    'activeBetPanel',
    'activeBetStake',
    'activeBetMultiplier',
    'activeBetPayout'
  ]){
    assert.match(html,new RegExp('id="'+id+'"'));
  }
});

test('controlador busca histórico em RPC separado do estado de voo',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/jl_aviator_recent_results/);
  const publicStateCalls=(js.match(/jl_aviator_public_state/g)||[]).length;
  const historyCalls=(js.match(/jl_aviator_recent_results/g)||[]).length;
  assert.equal(publicStateCalls,1);
  assert.equal(historyCalls,1);
});


test('cash-out na fronteira do crash não mostra erro técnico cru',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/Confirmando cash-out/);
  assert.match(js,/Fim da rodada\. Cash-out não disponível\./);
  assert.match(js,/Crash ja atingido\|Aposta ja liquidada\|Voo nao esta ativo/);
});


test('modo offline bloqueia aposta e cash-out até reconectar',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(html,/id="aviatorConnectionBanner"/);
  assert.match(js,/addEventListener\('offline'/);
  assert.match(js,/addEventListener\('online'/);
  assert.match(js,/Cash-out indisponível até reconectar/);
  assert.match(js,/if\(!connectionOnline\)throw new Error\('Sem ligação/);
});

test('estado público mede RTT para sincronizar o relógio do voo',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/const requestStarted=Date\.now\(\)/);
  assert.match(js,/const responseReceived=Date\.now\(\)/);
  assert.match(js,/applyClockSample\(x\.server_time,requestStarted,responseReceived\)/);
});


test('resposta de recuperação antiga é descartada se a rodada mudou',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/const requestedRoundId=Number\(round\.id\)/);
  assert.match(js,/if\(Number\(round\?\.id\)!==requestedRoundId\)/);
  assert.match(js,/runtime\.pickActiveBet\(x\?\.bets,requestedRoundId\)/);
});


test('cash-out ambíguo é persistido e reconciliado sem retry automático',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/jl_aviator_pending_cashout_v1/);
  assert.match(js,/savePendingCashout\(id,cashoutRoundId\)/);
  assert.match(js,/reconcilePendingCashout\(\)/);
  assert.match(js,/bet\.status==='CASHED_OUT'/);
  assert.match(js,/Cash-out confirmado em/);
  assert.match(js,/bet\.status==='ACTIVE'/);
  assert.match(js,/A aposta continua ativa/);
  const reconcileBlock=js.match(/async function reconcilePendingCashout\(\)[\s\S]*?\n}\n\nasync function recover/)?.[0]||'';
  assert.doesNotMatch(reconcileBlock,/jl_aviator_cashout/);
});


test('confirmação reconciliada sobrevive à primeira sincronização de rodada',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/preserveMessageOnNextRoundSync=true/);
  assert.match(js,/if\(preserveMessageOnNextRoundSync\)preserveMessageOnNextRoundSync=false/);
});
