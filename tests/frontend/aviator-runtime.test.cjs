const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const runtime=require('../../js/aviator/runtime.js');
const fairness=require('../../js/aviator/fairness.js');
const engineSource=fs.readFileSync(path.join(__dirname,'../../js/aviator/engine.js'),'utf8');
const uiSource=fs.readFileSync(path.join(__dirname,'../../js/aviator/ui.js'),'utf8');
const financialSource=fs.readFileSync(path.join(__dirname,'../../js/aviator/financial.js'),'utf8');
const historySource=fs.readFileSync(path.join(__dirname,'../../js/aviator/history.js'),'utf8');

test('runtime mantém apenas relógio visual derivado do snapshot autoritativo',()=>{
  assert.equal(typeof runtime.liveMultiplier,'function');
  assert.equal(typeof runtime.secondsUntil,'function');
  assert.equal(runtime.multiplier,undefined);
  assert.equal(runtime.clockSample,undefined);

  const started='2026-09-30T10:00:00.000Z';
  const now=Date.parse(started)+10_000;
  assert.ok(Math.abs(runtime.liveMultiplier(started,now)-Math.pow(1.06,10))<1e-10);
  assert.equal(runtime.secondsUntil('2026-09-30T10:00:05.000Z',Date.parse(started)),5);
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

test('Realtime reduz polling a fallback de baixa frequência',()=>{
  assert.equal(runtime.pollDelay('FLYING',false,true),120000);
  assert.equal(runtime.pollDelay('OPEN',false,true),120000);
  assert.equal(runtime.pollDelay('FLYING',true,true),300000);
  assert.equal(runtime.pollDelay('FLYING',false,false),3000);
  assert.equal(runtime.pollDelay('OPEN',false,false),5000);
  assert.equal(runtime.pollDelay('SETTLED',false,false),15000);
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

test('HTML carrega cliente Realtime fixado antes do controlador',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  assert.match(html,/@supabase\/supabase-js@2\.117\.2\/dist\/umd\/supabase\.min\.js/);
  const realtimeAt=html.indexOf('./js/realtime/aviator.js');
  const controllerAt=html.indexOf('./aviator.js');
  assert.ok(realtimeAt>=0);
  assert.ok(controllerAt>realtimeAt);
});

test('controlador usa Broadcast como caminho principal e polling apenas como fallback',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  const realtime=fs.readFileSync(path.join(__dirname,'../../js/realtime/aviator.js'),'utf8');
  assert.match(realtime,/channel\('aviator:round'/);
  assert.match(realtime,/\.on\('broadcast',\{event:'state'\}/);
  assert.match(js,/applyRealtimeSnapshot/);
  assert.match(js,/realtimeConnected/);
  assert.match(js,/scheduleState\(120000\)/);
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
  assert.match(historySource,/jl_aviator_recent_results/);
  const publicStateCalls=(js.match(/jl_aviator_public_state/g)||[]).length;
  const historyCalls=(historySource.match(/jl_aviator_recent_results/g)||[]).length;
  assert.equal(publicStateCalls,1);
  assert.equal(historyCalls,1);
});


test('cash-out na fronteira do crash não mostra erro técnico cru',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(uiSource,/Confirmando cash-out/);
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

test('controlador usa timestamps do servidor para interpolação apenas visual',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/syncServerClock\(x\)/);
  assert.match(engineSource,/runtime\.liveMultiplier\(round\.started_at,serverNowMs\(\)\)/);
  assert.match(engineSource,/runtime\.secondsUntil\(round\[field\],serverNowMs\(\)\)/);
  assert.doesNotMatch(js,/p_multiplier\s*:/);
});


test('resposta de recuperação antiga é descartada se a rodada mudou',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/const requestedRoundId=Number\(round\.id\)/);
  assert.match(js,/if\(Number\(round\?\.id\)!==requestedRoundId\)/);
  assert.match(js,/runtime\.pickActiveBet\(bets,requestedRoundId\)/);
});


test('cash-out ambíguo é persistido e reconciliado sem retry automático',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(financialSource,/jl_aviator_pending_cashout_v1/);
  assert.match(js,/savePendingCashout\(id,cashoutRoundId,requestKey\)/);
  assert.match(js,/reconcilePendingCashout\(\)/);
  assert.match(js,/bet\.status==='CASHED_OUT'/);
  assert.match(js,/cashoutMessage\(/);
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

test('controlador verifica a rodada sem expor detalhes técnicos ao jogador',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/jl_aviator_round_proof/);
  assert.match(js,/fairness\.verify\(data\)/);
  assert.match(html,/Verificação da rodada/);
  assert.match(html,/class="proof-status"/);
  assert.match(js,/Rodada protegida antes do voo\./);
  assert.match(js,/Rodada verificada ✓/);
  assert.doesNotMatch(js,/Hash pré-aposta|Hash do fecho|Seed:/);
  assert.doesNotMatch(html,/<code id="proof"/);
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
  assert.match(js,/renderBetAction\(true,'Apostas fechadas'\)/);
  assert.equal(runtime.pollDelay('LOCKED',false,false),3000);
  assert.equal(runtime.phase('LOCKED'),'locked');
});


test('auto cash-out e opcional na UI mas executado pelo servidor',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(html,/id="aviatorAutoCashout"[^>]*min="1\.01"[^>]*step="0\.01"/);
  assert.match(html,/id="activeBetAuto"/);
  assert.match(financialSource,/p_auto_cashout_multiplier:autoCashoutMultiplier/);
  assert.match(js,/myAutoCashout=Number\(r\.auto_cashout_multiplier\)\|\|null/);
  assert.match(js,/Cash-out automático/);
  assert.match(js,/auto<1\.01/);
  assert.equal((financialSource.match(/jl_aviator_cashout'/g)||[]).length,1,
    'auto cash-out nao deve disparar jl_aviator_cashout pelo navegador');
});


test('confirmação visual usa o valor confirmado pelo servidor antes do voo',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');

  assert.match(html,/id="betConfirmation"/);
  assert.match(html,/id="betConfirmationText"/);
  assert.match(html,/role="status"[^>]*aria-live="polite"/);
  assert.match(js,/function moneyCompact\(value\)/);
  assert.match(uiSource,/Aposta confirmada: '\+moneyCompact\(state\.myStake\)/);
  assert.match(js,/myStake=Number\(r\.stake\);/);
  assert.doesNotMatch(js,/myStake=Number\(r\.stake\)\|\|amount/);
  assert.match(uiSource,/\['OPEN','LOCKED'\]\.includes\(round\?\.status\)/);
});


test('termos da aposta confirmada ficam imutáveis e campos podem preparar a próxima',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/function setBetInputsLocked\(locked\)/);
  assert.match(js,/Boolean\(myBet\)\|\|betting\|\|closed/);
  assert.match(uiSource,/if\(amount\)amount\.disabled=value/);
  assert.match(uiSource,/if\(auto\)auto\.disabled=value/);
  assert.match(js,/myStake=Number\(r\.stake\);/);
  assert.match(js,/myAutoCashout=Number\(r\.auto_cashout_multiplier\)\|\|null/);
  assert.match(js,/function renderLocked\(\)[\s\S]*?setBetInputsLocked\(!connectionOnline\|\|!enabled\)/);
  assert.match(js,/function renderFlying\(\)[\s\S]*?setBetInputsLocked\(!connectionOnline\|\|!enabled\)/);
});


test('reconexão usa snapshot autoritativo e não reinicia a fase visual',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');

  assert.match(js,/jl_aviator_reconnect/);
  assert.match(js,/async function reconnectState\(\)/);
  assert.match(js,/applyReconnectPlayerState\(x\?\.player\)/);
  assert.match(js,/Ligação restabelecida\. Voo atual:/);
  assert.match(uiSource,/if\(stage\.classList\.contains\(next\)\)return/);

  const onlineBlock=js.match(/window\.addEventListener\('online',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(onlineBlock,/await reconnectState\(\)/);
  assert.doesNotMatch(onlineBlock,/jl_aviator_public_state/);

  const visibilityBlock=js.match(/document\.addEventListener\('visibilitychange',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(visibilityBlock,/reconnectState\(\)/);
});


test('animação local é somente visual e cash-out continua autoritativo no servidor',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  const css=fs.readFileSync(path.join(__dirname,'../../aviator.css'),'utf8');

  assert.match(html,/id="flightArea"[^>]*data-visual-only="true"/);
  assert.match(html,/id="plane"[^>]*aria-hidden="true"/);
  assert.match(css,/\.plane,\.flight-grid,\.flight-area::after\{pointer-events:none\}/);

  const paint=js.match(/function paintFlight\([^)]*\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(paint,/const m=mul\(\)/);
  assert.doesNotMatch(paint,/JLApi\.rpc|jl_aviator_cashout|jl_aviator_tick/);

  const financial=financialSource.match(/async function requestFinancialCashout\(betId,requestKey\)[\s\S]*?\n    \}/)?.[0]||'';
  assert.match(financial,/jl_aviator_cashout/);
  assert.match(financial,/p_bet_id:id/);
  assert.match(financial,/p_request_key:/);
  assert.doesNotMatch(financial,/p_multiplier|current_multiplier|started_at/);

  assert.match(js,/requestAnimationFrame\(flightPaintLoop\)/);
});


test('tela do Aviator mantém voo como foco e multiplicadores recentes no topo',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const css=fs.readFileSync(path.join(__dirname,'../../aviator.css'),'utf8');

  assert.match(html,/id="aviatorStage" class="aviator-stage card aviator-focus"/);
  assert.match(html,/id="aviatorHistoryCard" class="aviator-history aviator-history-top card"/);
  assert.ok(
    html.indexOf('id="aviatorHistoryCard"')<html.indexOf('id="aviatorStage"'),
    'multiplicadores recentes devem aparecer acima do voo'
  );
  assert.match(html,/class="aviator-controls"/);
  assert.doesNotMatch(html,/class="card aviator-controls"/);
  assert.match(html,/class="aviator-ticket-main aviator-ticket-return"/);
  assert.match(html,/class="aviator-ticket-meta"/);

  assert.match(css,/\.flight-area\{height:405px/);
  assert.match(css,/\.multiplier\{font-size:clamp\(72px,16vw,145px\)/);
  assert.match(css,/\.aviator-history-top/);
  assert.match(css,/@media\(max-width:650px\)[\s\S]*?\.flight-area\{height:360px/);

  assert.match(uiSource,/Auto '\+Number\(state\.myAutoCashout\)\.toFixed\(2\)\+'×'/);
  assert.match(uiSource,/'Auto desligado'/);
});


test('histórico recente usa linha pequena no topo com multiplicadores separados por ponto',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const css=fs.readFileSync(path.join(__dirname,'../../aviator.css'),'utf8');

  assert.match(html,/id="aviatorHistoryCard" class="aviator-history aviator-history-top card"/);
  assert.match(historySource,/class="aviator-history-value tier-/);
  assert.match(historySource,/class="aviator-history-separator"[^>]*>·<\/span>/);
  assert.match(historySource,/crash_multiplier\.toFixed\(2\)\+'x'/);
  assert.doesNotMatch(historySource,/aviator-history-chip/);
  assert.match(css,/\.aviator-history-value\{[^}]*font-size:\.84rem/);
  assert.match(css,/\.aviator-history-top \.aviator-history-strip\{[^}]*overflow-x:auto/);
});


test('multiplicadores baixos medios e altos usam tiers visuais sem animação extra',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  const css=fs.readFileSync(path.join(__dirname,'../../aviator.css'),'utf8');

  assert.match(uiSource,/function multiplierTier\(value\)/);
  assert.match(uiSource,/if\(!Number\.isFinite\(n\)\|\|n<2\)return 'low'/);
  assert.match(uiSource,/if\(n<10\)return 'medium'/);
  assert.match(uiSource,/return 'high'/);
  assert.match(historySource,/tier-'\+multiplierTier\(item\.crash_multiplier\)/);
  assert.match(js,/applyMultiplierTier\(\$\('#crashMultiplier'\),result\)/);

  assert.match(css,/\.multiplier\.tier-low/);
  assert.match(css,/\.multiplier\.tier-medium/);
  assert.match(css,/\.multiplier\.tier-high/);
  assert.match(css,/\.aviator-history-value\.tier-low/);
  assert.match(css,/\.aviator-history-value\.tier-medium/);
  assert.match(css,/\.aviator-history-value\.tier-high/);

  const tierCss=css.match(/\.multiplier,\.crash-text span,\.aviator-history-value[\s\S]*?\.multiplier-wrap small/)?.[0]||'';
  assert.doesNotMatch(tierCss,/animation:/);
});


test('mensagens do jogador nunca exibem erro técnico bruto nem quebras \\n',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');

  assert.match(uiSource,/function playerMessage\(error,fallback=/);
  assert.match(uiSource,/replace\(\/\\\\n\|\\r\|\\n\/g,' '\)/);
  assert.doesNotMatch(js,/message\.textContent=e\.message/);
  assert.doesNotMatch(js,/aviatorMessage'\)\.textContent=e\.message/);
  assert.doesNotMatch(js,/textContent=raw\|\|/);
  assert.match(uiSource,/Saldo insuficiente\./);
  assert.match(uiSource,/Apostas fechadas\. Aguarde a próxima rodada\./);
  assert.match(js,/Não foi possível confirmar o cash-out\./);
});


test('Aviator fechado mostra somente a mensagem definida',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  const css=fs.readFileSync(path.join(__dirname,'../../aviator.css'),'utf8');

  assert.match(
    html,
    /id="aviatorMaintenanceNotice"[^>]*hidden>Aviator brevemente\.<\/section>/
  );
  assert.match(js,/Aviator brevemente\./);
  assert.match(js,/const maintenanceOnly=!enabled&&!protectedFlight/);
  assert.match(js,/notice\.hidden=!maintenanceOnly/);

  const hiddenRule=css.match(
    /\.aviator-maintenance-only \.topbar[\s\S]*?\{display:none!important\}/
  )?.[0]||'';

  for(const selector of [
    '.topbar',
    '.aviator-connection-banner',
    '.aviator-stage',
    '.aviator-history',
    '.aviator-controls'
  ]){
    assert.ok(hiddenRule.includes(selector),selector+' deve ficar oculto');
  }

  assert.match(
    css,
    /\.aviator-maintenance-only \.aviator-maintenance-notice\{display:block!important\}/
  );
});
