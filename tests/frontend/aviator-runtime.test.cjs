const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const runtime=require('../../js/aviator/runtime.js');
const fairness=require('../../js/aviator/fairness.js');

test('runtime do navegador não contém motor de multiplicador nem relógio do jogo',()=>{
  assert.equal(runtime.multiplier,undefined);
  assert.equal(runtime.secondsUntil,undefined);
  assert.equal(runtime.clockSample,undefined);
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
  assert.equal(runtime.pollDelay('FLYING',false),500);
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

test('HTML carrega fairness e runtime antes do controlador principal',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const fairnessAt=html.indexOf('./js/aviator/fairness.js');
  const runtimeAt=html.indexOf('./js/aviator/runtime.js');
  const controllerAt=html.indexOf('./aviator.js');
  assert.ok(fairnessAt>=0,'verificador provably fair deve estar incluído');
  assert.ok(runtimeAt>fairnessAt,'runtime deve carregar depois do verificador');
  assert.ok(controllerAt>runtimeAt,'controlador deve carregar por último');
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

test('controlador usa somente snapshots de voo calculados pelo servidor',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/round\?\.current_multiplier/);
  assert.match(js,/round\?\.seconds_to_close/);
  assert.doesNotMatch(js,/Math\.pow\(1\.06/);
  assert.doesNotMatch(js,/clockSample/);
  assert.doesNotMatch(js,/serverNow/);
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


test('provably fair v2 verifica seed, lock e resultado sem confiar no controlador',async()=>{
  const seed='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const seedCommit=await fairness.sha256Hex(seed);
  const visual=fairness.visualTarget(seedCommit);
  const payload=[
    fairness.VERSION,
    '42',
    seedCommit,
    '10.00',
    '2.000000',
    visual.toFixed(6),
    '2.000000'
  ].join('|');
  const lockCommit=await fairness.sha256Hex(payload);

  const proof={
    available:true,
    fairness_version:fairness.VERSION,
    seed,
    seed_commit:seedCommit,
    lock_payload:payload,
    lock_commit:lockCommit,
    inputs:{
      visual_target:visual,
      locked_effective_target:2,
      visual_extension:false,
      zero_exposure_at_multiplier:null
    },
    result:{actual_crash_multiplier:2}
  };

  const ok=await fairness.verify(proof);
  assert.equal(ok.valid,true);

  const tampered=await fairness.verify({
    ...proof,
    result:{actual_crash_multiplier:2.1}
  });
  assert.equal(tampered.valid,false);
  assert.equal(tampered.resultValid,false);
});

test('controlador pede prova pública somente para conferir rodada concluída',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/jl_aviator_round_proof/);
  assert.match(js,/fairness\.verify\(data\)/);
  assert.match(js,/Hash pré-aposta/);
  assert.match(js,/Hash do fecho/);
});


test('snapshots do Aviator nunca podem andar para trás',()=>{
  assert.equal(runtime.shouldAcceptSnapshot(null,100),true);
  assert.equal(runtime.shouldAcceptSnapshot(100,100),true);
  assert.equal(runtime.shouldAcceptSnapshot(100,101),true);
  assert.equal(runtime.shouldAcceptSnapshot(101,100),false);
  assert.equal(runtime.shouldAcceptSnapshot(101,undefined),false);
});

test('controlador usa display_seq e cancela estado antigo na reconexão',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  const rpc=fs.readFileSync(path.join(__dirname,'../../js/api/rpc.js'),'utf8');
  assert.match(js,/lastDisplaySeq/);
  assert.match(js,/shouldAcceptSnapshot\(lastDisplaySeq,x\?\.display_seq\)/);
  assert.match(js,/new AbortController\(\)/);
  assert.match(js,/cancelStateRequest\(\)/);
  assert.match(rpc,/signal:\s*options\.signal/);
});


test('UI do Aviator espelha limites 0.50 a 500 MZN sem ser autoridade financeira',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(html,/id="aviatorAmount"[^>]*min="0\.5"[^>]*max="500"/);
  assert.match(js,/amount<0\.5\|\|amount>500/);
  assert.match(js,/entre 0,50 e 500 MZN/);
});


test('Aviator mostra LOCKED separado do voo e bloqueia nova aposta',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/function secondsToTakeoff\(\)/);
  assert.match(js,/function renderLocked\(\)/);
  assert.match(js,/round\.status==='LOCKED'/);
  assert.match(js,/APOSTAS FECHADAS/);
  assert.match(js,/DESCOLAGEM EM/);
  assert.match(js,/betBtn\.disabled=true/);
  assert.equal(runtime.pollDelay('LOCKED',false),500);
  assert.equal(runtime.phase('LOCKED'),'locked');
});
