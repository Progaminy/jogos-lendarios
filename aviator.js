(()=>{'use strict';

const $=s=>document.querySelector(s);

let round=null;
let myBet=null;
let myStake=0;
let myAutoCashout=null;
let recovering=false;
let lastRecoveredRoundId=null;
let enabled=true;
let stateBusy=false;
let stateController=null;
let lastDisplaySeq=null;
let stateTimer=0;
let betting=false;
let cashingOut=false;
let openUiTimer=0;
let connectionOnline=navigator.onLine!==false;
let preserveMessageOnNextRoundSync=false;
let recentResults=[];
let historyBusy=false;
let historyRemoteLoaded=false;
let historyRetryAt=0;
let fairnessProofBusy=false;
let fairnessProofRoundId=null;
let fairnessProofData=null;

const playerToken=()=>JLSession.getPlayerToken();
const pendingCashoutKey='jl_aviator_pending_cashout_v1';
const fairness=window.JLAviatorFairness||null;
const runtime=window.JLAviatorRuntime||{
  pickActiveBet:(bets,roundId)=>{
    if(!Array.isArray(bets))return null;
    return bets.filter(b=>Number(b?.round_id)===Number(roundId)&&b?.status==='ACTIVE')
      .sort((a,b)=>Number(b?.id)-Number(a?.id))[0]||null;
  },
  findBetById:(bets,betId)=>{
    if(!Array.isArray(bets))return null;
    return bets.find(b=>Number(b?.id)===Number(betId))||null;
  },
  pollDelay:(status,hidden)=>hidden?5000:(status==='FLYING'||status==='LOCKED')?500:status==='OPEN'?1000:1400,
  shouldAcceptSnapshot:(previousSeq,nextSeq)=>{
    const next=Number(nextSeq);
    if(!Number.isFinite(next))return false;
    const previous=Number(previousSeq);
    return !Number.isFinite(previous)||next>=previous;
  }
};

function readPendingCashout(){
  try{
    const value=JSON.parse(sessionStorage.getItem(pendingCashoutKey)||'null');
    const betId=Number(value?.bet_id),roundId=Number(value?.round_id),createdAt=Number(value?.created_at);
    if(!Number.isFinite(betId)||!Number.isFinite(roundId)||!Number.isFinite(createdAt))return null;
    if(Date.now()-createdAt>6*60*60*1000){
      sessionStorage.removeItem(pendingCashoutKey);
      return null;
    }
    return {bet_id:betId,round_id:roundId,created_at:createdAt};
  }catch(_){
    return null;
  }
}

function savePendingCashout(betId,roundId){
  try{
    sessionStorage.setItem(pendingCashoutKey,JSON.stringify({
      bet_id:Number(betId),
      round_id:Number(roundId),
      created_at:Date.now()
    }));
  }catch(_){}
}

function clearPendingCashout(){
  try{sessionStorage.removeItem(pendingCashoutKey)}catch(_){}
}

function cancelStateRequest(){
  const controller=stateController;
  stateController=null;
  stateBusy=false;
  if(controller){
    try{controller.abort()}catch(_){}
  }
}

function setConnectionState(online){
  connectionOnline=Boolean(online);
  document.body.classList.toggle('aviator-offline',!connectionOnline);

  const banner=$('#aviatorConnectionBanner');
  if(banner)banner.classList.toggle('hidden',connectionOnline);

  if(connectionOnline)return;

  clearTimeout(stateTimer);
  cancelStateRequest();
  stopOpenUiTick();
  stopFlight();

  const betBtn=$('#betBtn');
  if(betBtn)betBtn.disabled=true;

  const cashout=$('#cashoutBtn');
  if(cashout){
    cashout.disabled=true;
    cashout.textContent=myBet?'Cash-out indisponível':'Cash-out';
  }

  if(round?.status==='FLYING'){
    $('#roundState').textContent='SEM LIGAÇÃO';
    $('#clockLabel').textContent='RECONEXÃO';
    $('#roundCountdown').textContent='AGUARDE';
  }
}

function money(value){
  const n=Number(value);
  return (Number.isFinite(n)?n:0).toLocaleString('pt-MZ',{
    minimumFractionDigits:2,
    maximumFractionDigits:2
  })+' MZN';
}

function moneyCompact(value){
  const n=Number(value);
  return (Number.isFinite(n)?n:0).toLocaleString('pt-MZ',{
    minimumFractionDigits:0,
    maximumFractionDigits:2
  })+' MZN';
}

function show(selector,visible){
  const el=typeof selector==='string'?$(selector):selector;
  if(el)el.classList.toggle('hidden',!visible);
}

function mul(){
  const value=Number(round?.current_multiplier);
  return Number.isFinite(value)&&value>=1?value:1;
}

function secondsToClose(){
  const value=Number(round?.seconds_to_close);
  return Number.isFinite(value)&&value>=0?Math.floor(value):null;
}

function secondsToTakeoff(){
  const value=Number(round?.seconds_to_takeoff);
  return Number.isFinite(value)&&value>=0?Math.floor(value):null;
}

function betKey(){
  if(!round?.id)return null;
  const key='jl_aviator_bet_key_'+round.id;
  let value=sessionStorage.getItem(key);
  if(!value){
    value=crypto.randomUUID?crypto.randomUUID():Date.now()+'-'+Math.random().toString(36).slice(2);
    sessionStorage.setItem(key,value);
  }
  return value;
}

function setStagePhase(phase){
  const stage=$('#aviatorStage');
  if(!stage)return;
  const next='is-'+phase;
  if(stage.classList.contains(next))return;
  stage.classList.remove('is-open','is-locked','is-flying','is-crashed','is-waiting');
  stage.classList.add(next);
}

function stopFlight(){}

function renderMultiplier(value){
  const el=$('#multiplier');
  if(!el)return;
  const n=Number(value);
  const text=(Number.isFinite(n)&&n>=1?n:1).toFixed(2)+'×';
  el.textContent=text;
  el.classList.toggle('long',text.length>=8);
}

function resetCashout(){
  const button=$('#cashoutBtn');
  if(!button)return;
  button.disabled=true;
  button.textContent='Cash-out';
}

function renderRoundNumber(){
  const el=$('#roundNumber');
  if(el)el.textContent=round?.id?'#'+round.id:'—';
}

function stopOpenUiTick(){
  if(openUiTimer){
    clearInterval(openUiTimer);
    openUiTimer=0;
  }
}

function setBetInputsLocked(locked){
  const value=Boolean(locked);
  const amount=$('#aviatorAmount');
  const auto=$('#aviatorAutoCashout');
  if(amount)amount.disabled=value;
  if(auto)auto.disabled=value;
}

function updateOpenClock(){
  if(!connectionOnline){
    stopOpenUiTick();
    return;
  }

  if(round?.status!=='OPEN'){
    stopOpenUiTick();
    return;
  }

  const seconds=secondsToClose();
  const takeoffSeconds=secondsToTakeoff();
  const display=seconds===null?'—':String(seconds);
  const takeoffDisplay=takeoffSeconds===null?'—':String(takeoffSeconds);
  const closed=seconds===0;

  $('#roundState').textContent=closed?'APOSTAS FECHADAS':'APOSTAS ABERTAS';
  $('#clockLabel').textContent=closed?'DESCOLAGEM':'FECHA EM';
  $('#roundCountdown').textContent=closed?'AGUARDE':seconds===null?'—':display+'s';
  $('#preflightCountdown').textContent=takeoffDisplay;

  const inputsLocked=
    !enabled||!connectionOnline||Boolean(myBet)||betting||closed;
  setBetInputsLocked(inputsLocked);

  const betBtn=$('#betBtn');
  if(betBtn){
    betBtn.disabled=inputsLocked;
    betBtn.textContent=myBet
      ?'Aposta confirmada'
      :closed
        ?'Apostas fechadas'
        :'Apostar';
  }
}

function startOpenUiTick(){
  if(openUiTimer)return;
  openUiTimer=setInterval(updateOpenClock,200);
}

function renderTicket(multiplierValue=null){
  const panel=$('#activeBetPanel');
  if(!panel)return;

  const active=Boolean(myBet)&&myStake>0;
  panel.classList.toggle('hidden',!active);
  if(!active)return;

  $('#activeBetStake').textContent=money(myStake);
  const auto=$('#activeBetAuto');
  if(auto)auto.textContent=myAutoCashout
    ?'Auto '+Number(myAutoCashout).toFixed(2)+'×'
    :'Auto desligado';

  if(round?.status==='FLYING'){
    const m=Number(multiplierValue??mul());
    const safeMultiplier=Number.isFinite(m)&&m>=1?m:1;
    $('#activeBetMultiplier').textContent=safeMultiplier.toFixed(2)+'×';
    $('#activeBetPayout').textContent=money(myStake*safeMultiplier);
  }else{
    $('#activeBetMultiplier').textContent='A aguardar';
    $('#activeBetPayout').textContent=money(myStake);
  }
}

function renderBetConfirmation(){
  const box=$('#betConfirmation');
  const text=$('#betConfirmationText');
  const auto=$('#betConfirmationAuto');
  if(!box||!text)return;

  const visible=
    Boolean(myBet)&&
    myStake>0&&
    ['OPEN','LOCKED'].includes(round?.status);

  box.classList.toggle('hidden',!visible);
  if(!visible)return;

  text.textContent='Aposta confirmada: '+moneyCompact(myStake);

  if(auto){
    const hasAuto=Number.isFinite(Number(myAutoCashout))&&Number(myAutoCashout)>=1.01;
    auto.classList.toggle('hidden',!hasAuto);
    auto.textContent=hasAuto
      ?'Auto cash-out: '+Number(myAutoCashout).toFixed(2)+'×'
      :'';
  }
}

function normalizeHistoryItem(item){
  const id=Number(item?.id);
  const multiplier=Number(item?.crash_multiplier);
  if(!Number.isFinite(id)||id<=0||!Number.isFinite(multiplier)||multiplier<1)return null;
  return {
    id,
    crash_multiplier:multiplier,
    ended_at:item?.ended_at||null
  };
}

function renderHistory(){
  const wrap=$('#aviatorHistory');
  const status=$('#historyStatus');
  if(!wrap||!status)return;

  const rows=recentResults
    .map(normalizeHistoryItem)
    .filter(Boolean)
    .sort((a,b)=>b.id-a.id)
    .slice(0,12);

  if(!rows.length){
    wrap.innerHTML='<span class="aviator-history-empty">Sem resultados recentes.</span>';
    status.textContent=historyRemoteLoaded?'Atualizado':'—';
    return;
  }

  wrap.innerHTML=rows.map((item,index)=>
    '<span class="aviator-history-value" title="Rodada #'+item.id+'">'+
      item.crash_multiplier.toFixed(2)+'x'+
    '</span>'+
    (index<rows.length-1
      ?'<span class="aviator-history-separator" aria-hidden="true">·</span>'
      :'')
  ).join('');

  wrap.setAttribute(
    'aria-label',
    'Multiplicadores recentes: '+
      rows.map(item=>item.crash_multiplier.toFixed(2)+' vezes').join(', ')
  );

  status.textContent=rows.length+' recentes';
}

function rememberCurrentResult(){
  if(!round||!['CRASHED','SETTLED'].includes(round.status))return;
  const item=normalizeHistoryItem({
    id:round.id,
    crash_multiplier:round.crash_multiplier,
    ended_at:round.crashed_at||round.settled_at||null
  });
  if(!item)return;

  recentResults=[
    item,
    ...recentResults.filter(x=>Number(x?.id)!==item.id)
  ].slice(0,12);

  renderHistory();
}

async function loadHistory(force=false){
  const now=Date.now();
  if(historyBusy||now<historyRetryAt)return;
  if(historyRemoteLoaded&&!force)return;

  historyBusy=true;
  const status=$('#historyStatus');
  if(status)status.textContent='A atualizar…';

  try{
    const raw=await JLApi.rpc('jl_aviator_recent_results',{p_limit:12});
    const rows=Array.isArray(raw)?raw:[];
    const normalized=rows.map(normalizeHistoryItem).filter(Boolean);

    if(normalized.length){
      const localOnly=recentResults.filter(local=>
        !normalized.some(remote=>remote.id===Number(local?.id))
      );
      recentResults=[...normalized,...localOnly]
        .sort((a,b)=>b.id-a.id)
        .slice(0,12);
    }

    historyRemoteLoaded=true;
    historyRetryAt=0;
  }catch(_){
    historyRemoteLoaded=false;
    historyRetryAt=Date.now()+60000;
  }finally{
    historyBusy=false;
    renderHistory();
  }
}

function paintFlight(){
  if(!connectionOnline||round?.status!=='FLYING')return;

  const m=mul();
  renderMultiplier(m);
  renderTicket(m);

  const cashout=$('#cashoutBtn');
  if(cashout){
    cashout.textContent=myBet?'Cash-out · '+m.toFixed(2)+'×':'Cash-out';
    cashout.disabled=!connectionOnline||!myBet||cashingOut;
  }
}

function startFlightPaint(){
  paintFlight();
}

function cashoutMessage(source,multiplier,payout){
  const label=source==='AUTO'?'Cash-out automático':'Cash-out';
  return label+' em '+Number(multiplier).toFixed(2)+'× · '+money(payout);
}

function requestFinancialCashout(betId){
  return JLApi.rpc('jl_aviator_cashout',{
    p_token:playerToken(),
    p_bet_id:Number(betId)
  });
}

async function reconcilePendingCashout(){
  const pending=readPendingCashout();
  if(!pending||!connectionOnline||!playerToken())return false;

  try{
    const x=await JLApi.rpc('jl_aviator_player_state',{p_token:playerToken()});
    const bet=runtime.findBetById(x?.bets,pending.bet_id);

    if(!bet)return false;

    if(bet.status==='CASHED_OUT'){
      clearPendingCashout();
      myBet=null;
      myStake=0;
      myAutoCashout=null;
      lastRecoveredRoundId=pending.round_id;
      resetCashout();
      renderTicket();
      $('#aviatorMessage').textContent=cashoutMessage(
        bet.cashout_source,
        bet.cashout_multiplier,
        bet.payout
      );
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    if(bet.status==='ACTIVE'){
      clearPendingCashout();
      if(Number(round?.id)===pending.round_id){
        myBet=bet.id;
        myStake=Number(bet.stake)||0;
        myAutoCashout=Number(bet.auto_cashout_multiplier)||null;
        lastRecoveredRoundId=pending.round_id;
        renderTicket();
      }
      $('#aviatorMessage').textContent='Cash-out não foi confirmado. A aposta continua ativa.';
      return true;
    }

    if(bet.status==='LOST'){
      clearPendingCashout();
      myBet=null;
      myStake=0;
      myAutoCashout=null;
      resetCashout();
      renderTicket();
      $('#aviatorMessage').textContent='Fim da rodada. Cash-out não disponível.';
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    if(bet.status==='REFUNDED'){
      clearPendingCashout();
      myBet=null;
      myStake=0;
      myAutoCashout=null;
      resetCashout();
      renderTicket();
      $('#aviatorMessage').textContent='A aposta foi reembolsada pelo servidor.';
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    return false;
  }catch(_){
    return false;
  }
}

async function recover(force=false){
  if(recovering||!playerToken()||!round)return;
  if(!force&&lastRecoveredRoundId===round.id)return;

  const requestedRoundId=Number(round.id);
  recovering=true;

  try{
    const x=await JLApi.rpc('jl_aviator_player_state',{p_token:playerToken()});

    if(Number(round?.id)!==requestedRoundId){
      return;
    }

    const bets=Array.isArray(x?.bets)?x.bets:[];
    const current=runtime.pickActiveBet(bets,requestedRoundId);
    const latest=bets
      .filter(b=>Number(b?.round_id)===requestedRoundId)
      .sort((a,b)=>Number(b?.id)-Number(a?.id))[0]||null;

    myBet=current?.id??null;
    myStake=current?Number(current.stake)||0:0;
    myAutoCashout=current?Number(current.auto_cashout_multiplier)||null:null;
    lastRecoveredRoundId=requestedRoundId;
    renderTicket();
    renderBetConfirmation();

    if(myBet&&round.status==='FLYING'){
      $('#aviatorMessage').textContent='Aposta ativa recuperada.';
    }else if(latest?.status==='CASHED_OUT'){
      myAutoCashout=null;
      resetCashout();
      $('#aviatorMessage').textContent=cashoutMessage(
        latest.cashout_source,
        latest.cashout_multiplier,
        latest.payout
      );
    }
  }catch(_){
    lastRecoveredRoundId=null;
  }finally{
    recovering=false;
  }
}

async function loadFairnessProof(roundId){
  if(!fairness||fairnessProofBusy)return;
  if(fairnessProofRoundId===Number(roundId)&&fairnessProofData)return;

  fairnessProofBusy=true;
  try{
    const data=await JLApi.rpc('jl_aviator_round_proof',{p_round_id:Number(roundId)});
    if(Number(round?.id)!==Number(roundId))return;
    const check=await fairness.verify(data);
    if(Number(round?.id)!==Number(roundId))return;
    fairnessProofRoundId=Number(roundId);
    fairnessProofData={data,check};
    renderProof();
  }catch(_){
    if(Number(round?.id)===Number(roundId)){
      fairnessProofRoundId=Number(roundId);
      fairnessProofData={error:true};
      renderProof();
    }
  }finally{
    fairnessProofBusy=false;
  }
}

function renderProof(){
  const wrap=$('#proofWrap');
  const proof=$('#proof');
  if(!wrap||!proof)return;

  const commit=round?.round_seed_commit||round?.visual_seed_commit;
  if(!commit){
    wrap.hidden=true;
    proof.textContent='';
    proof.removeAttribute('data-valid');
    return;
  }

  wrap.hidden=false;
  proof.removeAttribute('data-valid');

  const lockCommit=round?.lock_proof_commit||null;
  const reveal=round?.round_seed_reveal||round?.visual_seed_reveal||null;
  const finished=['CRASHED','SETTLED'].includes(round?.status);

  let text='Hash pré-aposta: '+commit;
  if(lockCommit)text+=' · Hash do fecho: '+lockCommit;

  if(!finished||!reveal){
    text+=lockCommit
      ?' · Inputs da rodada selados antes do voo.'
      :' · Seed comprometida antes das apostas.';
    proof.textContent=text;
    return;
  }

  if(fairnessProofRoundId===Number(round.id)&&fairnessProofData?.check){
    const {data,check}=fairnessProofData;
    const valid=Boolean(check.valid);
    proof.dataset.valid=valid?'true':'false';
    proof.textContent=(valid?'Prova criptográfica válida ✓':'Prova criptográfica inválida ✕')+
      ' · Hash pré-aposta: '+commit+
      (lockCommit?' · Hash do fecho: '+lockCommit:'')+
      ' · Seed: '+reveal+
      (data?.result?.actual_crash_multiplier!=null
        ?' · Resultado: '+Number(data.result.actual_crash_multiplier).toFixed(6)+'×'
        :'');
    return;
  }

  if(fairnessProofRoundId===Number(round.id)&&fairnessProofData?.error){
    proof.textContent=text+' · Seed: '+reveal+' · Não foi possível verificar agora.';
    return;
  }

  proof.textContent=text+' · Seed: '+reveal+' · A verificar…';
  void loadFairnessProof(round.id);
}

function renderMaintenanceView(){
  const protectedFlight=
    !enabled&&['LOCKED','FLYING'].includes(round?.status)&&Boolean(myBet);
  const maintenanceOnly=!enabled&&!protectedFlight;

  document.body.classList.toggle('aviator-maintenance',!enabled);
  document.body.classList.toggle('aviator-maintenance-only',maintenanceOnly);

  const notice=$('#aviatorMaintenanceNotice');
  if(notice)notice.hidden=!maintenanceOnly;

  return maintenanceOnly;
}

function renderOpen(){
  stopFlight();
  setStagePhase('open');
  renderRoundNumber();
  updateOpenClock();
  startOpenUiTick();

  show('#preflight',true);
  show('#multiplierWrap',false);
  show('#crashText',false);

  resetCashout();
  renderTicket();
  renderBetConfirmation();

  if(myBet&&!$('#aviatorMessage').textContent.trim()){
    $('#aviatorMessage').textContent='Aposta confirmada. Aguarde a descolagem.';
  }
}

function renderLocked(){
  stopOpenUiTick();
  stopFlight();
  setStagePhase('locked');
  renderRoundNumber();

  const seconds=secondsToTakeoff();
  const display=seconds===null?'—':String(seconds);

  $('#roundState').textContent='APOSTAS FECHADAS';
  $('#clockLabel').textContent='DESCOLAGEM EM';
  $('#roundCountdown').textContent=seconds===null?'—':display+'s';
  $('#preflightCountdown').textContent=display;

  show('#preflight',true);
  show('#multiplierWrap',false);
  show('#crashText',false);

  setBetInputsLocked(true);

  setBetInputsLocked(true);

  const betBtn=$('#betBtn');
  if(betBtn){
    betBtn.disabled=true;
    betBtn.textContent='Apostas fechadas';
  }

  resetCashout();
  renderTicket();
  renderBetConfirmation();

  if(myBet){
    $('#aviatorMessage').textContent='Aposta confirmada. Aguardando descolagem.';
  }
}

function renderFlying(){
  stopOpenUiTick();
  setStagePhase('flying');
  renderRoundNumber();

  $('#roundState').textContent='EM VOO';
  $('#clockLabel').textContent='VOO';
  $('#roundCountdown').textContent='AO VIVO';

  show('#preflight',false);
  show('#multiplierWrap',true);
  show('#crashText',false);

  const betBtn=$('#betBtn');
  if(betBtn){
    betBtn.disabled=true;
    betBtn.textContent='Apostas fechadas';
  }

  const cashout=$('#cashoutBtn');
  if(cashout){
    cashout.disabled=!connectionOnline||!myBet||cashingOut;
  }

  renderTicket(mul());
  renderBetConfirmation();
  startFlightPaint();
}

function renderFinished(){
  stopOpenUiTick();
  stopFlight();
  setStagePhase('crashed');
  renderRoundNumber();

  const result=Number(round?.crash_multiplier||1);
  const resultText=(Number.isFinite(result)&&result>=1?result:1).toFixed(2)+'×';

  $('#roundState').textContent='FIM DA RODADA';
  $('#clockLabel').textContent='PRÓXIMA RODADA';
  $('#roundCountdown').textContent='A AGUARDAR';
  $('#crashMultiplier').textContent=resultText;

  show('#preflight',false);
  show('#multiplierWrap',false);
  show('#crashText',true);

  setBetInputsLocked(true);

  setBetInputsLocked(true);

  const betBtn=$('#betBtn');
  if(betBtn){
    betBtn.disabled=true;
    betBtn.textContent='Aguarde';
  }

  myBet=null;
  myStake=0;
  myAutoCashout=null;
  resetCashout();
  renderTicket();
  renderBetConfirmation();
  rememberCurrentResult();
}

function renderWaiting(){
  stopOpenUiTick();
  stopFlight();
  setStagePhase('waiting');
  renderRoundNumber();

  $('#roundState').textContent='AGUARDANDO';
  $('#clockLabel').textContent='PRÓXIMA RODADA';
  $('#roundCountdown').textContent='—';
  $('#preflightCountdown').textContent='—';

  show('#preflight',true);
  show('#multiplierWrap',false);
  show('#crashText',false);

  const betBtn=$('#betBtn');
  if(betBtn){
    betBtn.disabled=true;
    betBtn.textContent='Aguarde';
  }

  resetCashout();
  renderTicket();
  renderBetConfirmation();
}

function renderCurrentRound(){
  renderProof();

  if(!round){
    renderWaiting();
    return;
  }

  if(round.status==='OPEN'){
    renderOpen();
    return;
  }

  if(round.status==='LOCKED'){
    renderLocked();
    return;
  }

  if(round.status==='FLYING'){
    renderFlying();
    return;
  }

  if(round.status==='CRASHED'||round.status==='SETTLED'){
    renderFinished();
    return;
  }

  renderWaiting();
}

function nextPollDelay(){
  const protectedFlight=!enabled&&round?.status==='FLYING'&&Boolean(myBet);
  if(!enabled&&!protectedFlight){
    return document.hidden?30000:10000;
  }
  return runtime.pollDelay(round?.status||'',document.hidden);
}

function scheduleState(delay=nextPollDelay()){
  clearTimeout(stateTimer);
  if(!connectionOnline)return;
  stateTimer=setTimeout(state,delay);
}

function applyReconnectPlayerState(player){
  const bets=Array.isArray(player?.bets)?player.bets:[];
  const roundId=Number(round?.id);
  const current=Number.isFinite(roundId)
    ?runtime.pickActiveBet(bets,roundId)
    :null;
  const latest=Number.isFinite(roundId)
    ?bets
      .filter(b=>Number(b?.round_id)===roundId)
      .sort((a,b)=>Number(b?.id)-Number(a?.id))[0]||null
    :null;

  myBet=current?.id??null;
  myStake=current?Number(current.stake)||0:0;
  myAutoCashout=current?Number(current.auto_cashout_multiplier)||null:null;
  lastRecoveredRoundId=round?.id??null;

  if(latest?.status==='CASHED_OUT'){
    clearPendingCashout();
    myBet=null;
    myStake=0;
    myAutoCashout=null;
    $('#aviatorMessage').textContent=cashoutMessage(
      latest.cashout_source,
      latest.cashout_multiplier,
      latest.payout
    );
    preserveMessageOnNextRoundSync=true;
  }else if(latest?.status==='LOST'){
    clearPendingCashout();
    myBet=null;
    myStake=0;
    myAutoCashout=null;
    $('#aviatorMessage').textContent='Fim da rodada. A aposta foi perdida.';
    preserveMessageOnNextRoundSync=true;
  }else if(latest?.status==='REFUNDED'){
    clearPendingCashout();
    myBet=null;
    myStake=0;
    myAutoCashout=null;
    $('#aviatorMessage').textContent='A aposta foi reembolsada pelo servidor.';
    preserveMessageOnNextRoundSync=true;
  }

  renderTicket();
  renderBetConfirmation();
}

async function reconnectState(){
  if(stateBusy||!connectionOnline)return;
  if(!playerToken()){
    return state();
  }

  const controller=new AbortController();
  stateController=controller;
  stateBusy=true;

  try{
    const x=await JLApi.rpc(
      'jl_aviator_reconnect',
      {p_token:playerToken()},
      {signal:controller.signal}
    );

    if(!runtime.shouldAcceptSnapshot(lastDisplaySeq,x?.display_seq)){
      return;
    }

    lastDisplaySeq=Number(x.display_seq);
    enabled=x.enabled!==false;

    const previousId=round?.id??null;
    const previousStatus=round?.status??null;
    round=x.round||null;

    const changedRound=previousId!==round?.id;
    const justFinished=
      previousStatus!==round?.status&&
      ['CRASHED','SETTLED'].includes(round?.status);

    if(changedRound){
      fairnessProofRoundId=null;
      fairnessProofData=null;
      fairnessProofBusy=false;
      stopFlight();
      resetCashout();
    }

    applyReconnectPlayerState(x?.player);

    if(justFinished)rememberCurrentResult();

    if(changedRound||justFinished){
      void loadHistory(true);
    }else if(!historyRemoteLoaded&&!historyBusy){
      void loadHistory(false);
    }

    if(renderMaintenanceView()){
      stopOpenUiTick();
      stopFlight();
      resetCashout();
      return;
    }

    renderCurrentRound();

    if(round?.status==='FLYING'&&myBet){
      $('#aviatorMessage').textContent=
        'Ligação restabelecida. Voo atual: '+mul().toFixed(2)+'× · Aposta ativa.';
    }else if(round?.status==='LOCKED'&&myBet){
      $('#aviatorMessage').textContent=
        'Ligação restabelecida. Aposta confirmada; aguardando descolagem.';
    }
  }catch(e){
    if(e?.name==='AbortError')return;
    if(navigator.onLine===false)setConnectionState(false);
    const message=$('#aviatorMessage');
    if(message)message.textContent=e.message;
  }finally{
    if(stateController===controller){
      stateController=null;
      stateBusy=false;
      if(connectionOnline)scheduleState();
    }
  }
}

async function state(){
  if(stateBusy||!connectionOnline)return;

  const controller=new AbortController();
  stateController=controller;
  stateBusy=true;

  try{
    const x=await JLApi.rpc(
      'jl_aviator_public_state',
      {},
      {signal:controller.signal}
    );

    if(!runtime.shouldAcceptSnapshot(lastDisplaySeq,x?.display_seq)){
      return;
    }

    lastDisplaySeq=Number(x.display_seq);
    enabled=x.enabled!==false;

    const previousId=round?.id??null;
    const previousStatus=round?.status??null;
    round=x.round||null;

    const changedRound=previousId!==round?.id;
    const justFinished=
      previousStatus!==round?.status&&
      ['CRASHED','SETTLED'].includes(round?.status);

    if(changedRound){
      fairnessProofRoundId=null;
      fairnessProofData=null;
      fairnessProofBusy=false;
      myBet=null;
      myStake=0;
      myAutoCashout=null;
      lastRecoveredRoundId=null;
      stopFlight();
      resetCashout();
      renderTicket();
      renderBetConfirmation();
      const message=$('#aviatorMessage');
      if(message){
        if(preserveMessageOnNextRoundSync)preserveMessageOnNextRoundSync=false;
        else message.textContent='';
      }
    }

    if(round&&playerToken()&&(changedRound||lastRecoveredRoundId!==round.id)){
      await recover();
    }

    if(justFinished)rememberCurrentResult();

    if(changedRound||justFinished){
      void loadHistory(true);
    }else if(!historyRemoteLoaded&&!historyBusy){
      void loadHistory(false);
    }

    if(renderMaintenanceView()){
      stopOpenUiTick();
      stopFlight();
      resetCashout();
      return;
    }

    renderCurrentRound();

    if(
      round?.status==='FLYING'&&
      myBet&&
      myAutoCashout&&
      mul()>=myAutoCashout
    ){
      await recover(true);
      renderCurrentRound();
    }

    if(!enabled&&round?.status==='FLYING'&&myBet){
      $('#aviatorMessage').textContent=
        'Manutenção ativada. A sua aposta em voo continua protegida; o cash-out permanece disponível.';
    }
  }catch(e){
    if(e?.name==='AbortError')return;
    if(navigator.onLine===false)setConnectionState(false);
    const message=$('#aviatorMessage');
    if(message)message.textContent=e.message;
  }finally{
    if(stateController===controller){
      stateController=null;
      stateBusy=false;
      if(connectionOnline)scheduleState();
    }
  }
}

$('#aviatorBetForm').addEventListener('submit',async e=>{
  e.preventDefault();
  if(betting)return;

  betting=true;
  const button=$('#betBtn');
  if(button)button.disabled=true;

  try{
    if(!connectionOnline)throw new Error('Sem ligação. Aguarde a reconexão.');
    if(!playerToken())throw new Error('Entre na sua conta primeiro.');
    if(!enabled)throw new Error('Aviator brevemente');
    if(!round||round.status!=='OPEN')throw new Error('Apostas fechadas.');

    const amount=Number($('#aviatorAmount').value);
    if(!Number.isFinite(amount)||amount<0.5||amount>500){
      throw new Error('Informe um valor entre 0,50 e 500 MZN.');
    }

    const autoRaw=$('#aviatorAutoCashout').value.trim();
    const auto=autoRaw===''?null:Number(autoRaw);
    if(
      auto!==null&&(
        !Number.isFinite(auto)||
        auto<1.01||
        Math.abs(auto*100-Math.round(auto*100))>1e-8
      )
    ){
      throw new Error('Cash-out automático deve ser 1,01x ou maior, com até 2 casas decimais.');
    }

    const r=await JLApi.rpc('jl_aviator_place_bet',{
      p_token:playerToken(),
      p_amount:amount,
      p_request_key:betKey(),
      p_auto_cashout_multiplier:auto
    });

    myBet=r.bet_id;
    myStake=Number(r.stake);
    myAutoCashout=Number(r.auto_cashout_multiplier)||null;
    lastRecoveredRoundId=round.id;
    renderTicket();
    renderBetConfirmation();

    $('#aviatorMessage').textContent='Aposta confirmada. Aguarde a descolagem.';
  }catch(e){
    $('#aviatorMessage').textContent=e.message;
  }finally{
    betting=false;
    renderCurrentRound();
  }
});

$('#cashoutBtn').addEventListener('click',async()=>{
  if(!connectionOnline){
    $('#aviatorMessage').textContent='Sem ligação. Cash-out indisponível até reconectar.';
    return;
  }
  if(cashingOut||!myBet||round?.status!=='FLYING')return;

  cashingOut=true;
  const id=myBet;
  const cashoutRoundId=Number(round.id);
  savePendingCashout(id,cashoutRoundId);
  const button=$('#cashoutBtn');
  if(button){
    button.disabled=true;
    button.textContent='Confirmando cash-out…';
  }

  try{
    const r=await requestFinancialCashout(id);

    clearPendingCashout();
    $('#aviatorMessage').textContent=cashoutMessage(
      r.source,
      r.multiplier,
      r.payout
    );

    myBet=null;
    myStake=0;
    myAutoCashout=null;
    resetCashout();
    renderTicket();
    lastRecoveredRoundId=round?.id??null;
  }catch(e){
    const raw=String(e?.message||'');
    const reconciled=await reconcilePendingCashout();
    if(reconciled)return;

    const roundEnded=/Crash ja atingido|Aposta ja liquidada|Voo nao esta ativo/i.test(raw);

    if(roundEnded){
      clearPendingCashout();
      myBet=null;
      myStake=0;
      myAutoCashout=null;
      lastRecoveredRoundId=round?.id??null;
      resetCashout();
      renderTicket();
      $('#aviatorMessage').textContent='Fim da rodada. Cash-out não disponível.';
      clearTimeout(stateTimer);
      await state();
    }else if(!connectionOnline||navigator.onLine===false){
      setConnectionState(false);
      $('#aviatorMessage').textContent='Sem ligação. A confirmar o cash-out quando reconectar.';
    }else{
      clearPendingCashout();
      $('#aviatorMessage').textContent=raw||'Não foi possível confirmar o cash-out.';
      lastRecoveredRoundId=null;
      await recover(true);
    }
  }finally{
    cashingOut=false;
    renderMaintenanceView();
    renderCurrentRound();
  }
});

window.addEventListener('offline',()=>{
  setConnectionState(false);
});

window.addEventListener('online',async()=>{
  cancelStateRequest();
  setConnectionState(true);
  lastRecoveredRoundId=null;
  historyRetryAt=0;
  historyRemoteLoaded=false;
  clearTimeout(stateTimer);
  const message=$('#aviatorMessage');
  if(message)message.textContent='Ligação restabelecida. A sincronizar…';
  await reconnectState();
});

document.addEventListener('visibilitychange',()=>{
  clearTimeout(stateTimer);
  if(!document.hidden){
    lastRecoveredRoundId=null;
    reconnectState();
  }else{
    stopOpenUiTick();
    scheduleState();
  }
});

renderHistory();
setConnectionState(connectionOnline);
if(connectionOnline){
  reconnectState();
}
})();