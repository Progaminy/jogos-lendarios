(()=>{'use strict';

const $=s=>document.querySelector(s);

let round=null;
let myBet=null;
let myStake=0;
let myAutoCashout=null;
let lastBetResult=null;
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
let fairnessProofBusy=false;
let fairnessProofRoundId=null;
let fairnessProofData=null;
let realtimeConnected=false;
let flightFrame=0;
let lastFlightPaintAt=0;
let autoRecoveryRoundId=null;
let lastFlightHudAt=0;
let autoBetEnabled=sessionStorage.getItem('jl_aviator_auto_bet_v1')==='1';
let autoBetAttemptedRoundId=null;
let autoBetSubmittingRoundId=null;

const playerToken=()=>JLSession.getPlayerToken();
const fairness=window.JLAviatorFairness||null;
const runtime=window.JLAviatorRuntime;

const engine=window.JLAviatorEngine.create({
  runtime,
  getRound:()=>round
});
const visualPerformance=engine.performance;
const ui=window.JLAviatorUI.create({
  $,
  getRound:()=>round,
  getBetState:()=>({myBet,myStake,myAutoCashout}),
  multiplier:()=>engine.multiplier()
});
const financial=window.JLAviatorFinancial.create({
  rpc:(name,args)=>JLApi.rpc(name,args),
  playerToken,
  getRoundId:()=>round?.id
});
const balance=window.JLAviatorBalance?.create({element:$('#aviatorBalance'),rpc:(n,a)=>JLApi.rpc(n,a),playerToken})||null;
const nextBet=window.JLAviatorNextBet?.create({
  slot:1,$,playerToken,getRound:()=>round,isEnabled:()=>enabled,
  isOnline:()=>connectionOnline,isBusy:()=>betting,hasActiveBet:()=>Boolean(myBet),
  playerMessage,form:$('#aviatorBetForm'),
  onMessage:text=>{const el=$('#aviatorMessage');if(el)el.textContent=text}
})||null;
const history=window.JLAviatorHistory.create({
  $,
  rpc:(name,args)=>JLApi.rpc(name,args),
  multiplierTier:(value)=>ui.multiplierTier(value)
});
const personalHistory=window.JLAviatorPersonalHistory?.create({
  $,
  rpc:(name,args)=>JLApi.rpc(name,args),
  playerToken,
  money:(value)=>ui.money(value)
})||null;
const sound=window.JLAviatorSound?.create({
  button:$('#aviatorSoundToggle')
})||null;
const haptics=window.JLAviatorHaptics?.create({
  button:$('#aviatorVibrationToggle')
})||null;
const p2=window.JLAviatorBetPanel?.create({$,financial,playerToken,
  getRound:()=>round,isEnabled:()=>enabled,isOnline:()=>connectionOnline,
  multiplier:mul,secondsToClose,money,moneyCompact,playerMessage,sound,personalHistory,
  createGestureGuard:ui.createCashoutGestureGuard})||null;

function cashoutRequestKey(betId){return financial.cashoutRequestKey(betId);}

function readPendingCashout(){return financial.readPendingCashout();}

function savePendingCashout(betId,roundId,requestKey){return financial.savePendingCashout(betId,roundId,requestKey);}

function clearPendingCashout(){return financial.clearPendingCashout();}

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

  p2?.setConnectionState(connectionOnline);
  if(connectionOnline)return;

  clearTimeout(stateTimer);
  cancelStateRequest();
  stopOpenUiTick();
  stopFlight();

  renderBetAction(true,'Sem ligação');

  renderCashoutAction({
    active:Boolean(myBet)&&round?.status==='FLYING',
    disabled:true,
    pending:false,
    multiplier:mul(),
    stake:myStake,
    status:myBet?'Sem ligação — cash-out indisponível':'Disponível durante o voo'
  });

  if(round?.status==='FLYING'){
    $('#roundState').textContent='SEM LIGAÇÃO';
    $('#clockLabel').textContent='RECONEXÃO';
    $('#roundCountdown').textContent='AGUARDE';
  }
}

function money(value){return ui.money(value);}

function moneyCompact(value){return ui.moneyCompact(value);}

function playerMessage(error,fallback='Não foi possível concluir. Tente novamente.'){return ui.playerMessage(error,fallback);}

function show(selector,visible){return ui.show(selector,visible);}

function syncServerClock(snapshot){return engine.syncServerClock(snapshot);}

function serverNowMs(){return engine.serverNowMs();}

function mul(){return engine.multiplier();}

function secondsToClose(){return engine.secondsToClose();}

function secondsToNextRound(){return engine.secondsToNextRound();}

function betKey(){return financial.betKey();}

function setStagePhase(phase){return ui.setStagePhase(phase);}

function stopFlight(){
  if(flightFrame){
    cancelAnimationFrame(flightFrame);
    flightFrame=0;
  }
  lastFlightPaintAt=0;
  lastFlightHudAt=0;
}

function multiplierTier(value){return ui.multiplierTier(value);}

function applyMultiplierTier(el,value){return ui.applyMultiplierTier(el,value);}

function renderMultiplier(value){return ui.renderMultiplier(value);}

function resetCashout(){return ui.resetCashout();}
function renderCashoutAction(options){return ui.renderCashoutAction(options);}
const cashoutGestureGuard=ui.createCashoutGestureGuard($('#cashoutBtn'));

function renderRoundNumber(){return ui.renderRoundNumber();}

function stopOpenUiTick(){
  if(openUiTimer){
    clearInterval(openUiTimer);
    openUiTimer=0;
  }
}

function setBetInputsLocked(locked){return ui.setBetInputsLocked(locked);}
function renderBetAction(disabled,status,label='Apostar',mode='bet',hidden=false){
  return ui.renderBetAction({disabled,status,label,mode,hidden});
}

function renderAutoBetStatus(){
  const toggle=$('#aviatorAutoBet');
  const status=$('#aviatorAutoBetStatus');
  if(toggle&&toggle.checked!==autoBetEnabled)toggle.checked=autoBetEnabled;
  if(!status)return;

  if(!autoBetEnabled){
    status.textContent='Desligado';
    return;
  }

  if(!playerToken()){
    status.textContent='Entre na conta';
    return;
  }

  if(round?.status==='OPEN'&&myBet){
    status.textContent='Confirmada nesta rodada';
    return;
  }

  status.textContent=round?.status==='OPEN'?'Ativo':'Aguardando';
}

function scheduleAutoBetForOpenRound(){
  renderAutoBetStatus();

  const roundId=Number(round?.id);
  if(
    !autoBetEnabled||
    !enabled||
    !connectionOnline||
    !playerToken()||
    !Number.isFinite(roundId)||
    round?.status!=='OPEN'||
    round?.betting_open===false||
    myBet||
    betting||
    autoBetAttemptedRoundId===roundId||
    Boolean(nextBet?.hasQueued())
  ){
    return;
  }

  autoBetAttemptedRoundId=roundId;

  queueMicrotask(()=>{
    if(
      !autoBetEnabled||
      !connectionOnline||
      !playerToken()||
      Number(round?.id)!==roundId||
      round?.status!=='OPEN'||
      round?.betting_open===false||
      myBet||
      betting
    ){
      return;
    }

    autoBetSubmittingRoundId=roundId;
    $('#aviatorBetForm')?.requestSubmit?.();
  });
}

function updateRoundClock(){
  if(!connectionOnline){
    stopOpenUiTick();
    return;
  }

  if(round?.status==='OPEN'){
    const seconds=secondsToClose();
    const display=seconds===null?'—':String(seconds);
    const closed=round?.betting_open===false||seconds===0;

    $('#roundState').textContent=closed?'APOSTAS FECHADAS':'APOSTAS ABERTAS';
    $('#clockLabel').textContent=closed?'AGUARDE':'APOSTE';
    $('#roundCountdown').textContent=display;
    $('#preflightLabel').textContent=closed?'AGUARDE':'APOSTE';
    $('#preflightCountdown').textContent=display;
    $('#preflightHint').textContent='Contagem em segundos';

    const inputsLocked=
      !enabled||!connectionOnline||Boolean(myBet)||betting||closed;
    const canCancel=
      enabled&&connectionOnline&&Boolean(myBet)&&!betting&&!closed;
    setBetInputsLocked(inputsLocked);

    if(canCancel){
      renderBetAction(
        false,
        'Aposta confirmada · toque para cancelar',
        'Cancelar',
        'cancel'
      );
    }else{
      renderBetAction(
        inputsLocked,
        myBet
          ?closed?'Apostas fechadas':'Aposta confirmada'
          :closed
            ?'Apostas fechadas'
            :'Disponível',
        'Apostar',
        'bet'
      );
    }
    return;
  }

  if(round?.status==='LOCKED'){
    $('#roundState').textContent='APOSTAS FECHADAS';
    $('#clockLabel').textContent='AGUARDE';
    $('#roundCountdown').textContent='0';
    $('#preflightLabel').textContent='AGUARDE';
    $('#preflightCountdown').textContent='0';
    $('#preflightHint').textContent='Bloqueio de segurança';
    return;
  }

  if(round?.status==='CRASHED'||round?.status==='SETTLED'){
    const seconds=secondsToNextRound();
    const display=seconds===null?'—':String(seconds)+'s';
    $('#clockLabel').textContent='NOVA RODADA EM';
    $('#roundCountdown').textContent=display;
    const next=$('#nextRoundSeconds');
    if(next)next.textContent=display;
    return;
  }

  stopOpenUiTick();
}

function startOpenUiTick(){
  if(openUiTimer)return;
  openUiTimer=setInterval(updateRoundClock,visualPerformance.openClockIntervalMs);
}

function renderTicket(multiplierValue=null){return ui.renderTicket(multiplierValue);}

function renderBetConfirmation(){return ui.renderBetConfirmation();}
function setBetResult(result=null){
  lastBetResult=result||null;
  ui.renderBetResult(lastBetResult);
  if(result)personalHistory?.invalidate();
}
function setBetResultFromBet(bet){
  if(!bet){
    setBetResult(null);
    return;
  }
  const status=String(bet.status||'').toUpperCase();
  if(!['CASHED_OUT','LOST','REFUNDED'].includes(status)){
    if(status==='ACTIVE')setBetResult(null);
    return;
  }
  setBetResult({
    status,
    stake:Number(bet.stake),
    payout:Number(bet.payout),
    cashout_multiplier:Number(bet.cashout_multiplier)
  });
}

function normalizeHistoryItem(item){return history.normalize(item);}

function renderHistory(){return history.render();}

function rememberCurrentResult(){return history.remember(round);}

async function loadHistory(force=false){return history.load(force);}

function paintFlight(timestamp=performance.now()){
  if(!connectionOnline||round?.status!=='FLYING'||document.hidden)return;

  const m=mul();
  renderMultiplier(m);

  if(timestamp-lastFlightHudAt<visualPerformance.hudIntervalMs)return;
  lastFlightHudAt=timestamp;
  renderTicket(m);

  renderCashoutAction({
    active:Boolean(myBet),
    disabled:!connectionOnline||!myBet||cashingOut,
    pending:cashingOut,
    multiplier:m,
    stake:myStake
  });

  p2?.paintFlight(m);
}

function flightPaintLoop(timestamp){
  if(!connectionOnline||round?.status!=='FLYING'||document.hidden){
    stopFlight();
    return;
  }

  if(timestamp-lastFlightPaintAt>=visualPerformance.frameIntervalMs){
    lastFlightPaintAt=timestamp;
    paintFlight(timestamp);

    if(
      myBet&&
      myAutoCashout&&
      Number(round?.id)!==Number(autoRecoveryRoundId)&&
      mul()>=myAutoCashout
    ){
      autoRecoveryRoundId=Number(round.id);
      void refreshCurrentBetLight();
    }
  }

  flightFrame=requestAnimationFrame(flightPaintLoop);
}

function startFlightPaint(){
  if(flightFrame||document.hidden)return;
  paintFlight(performance.now());
  flightFrame=requestAnimationFrame(flightPaintLoop);
}

function cashoutMessage(source,multiplier,payout){return financial.cashoutMessage(source,multiplier,payout);}

async function requestFinancialCashout(betId,requestKey){return financial.requestFinancialCashout(betId,requestKey);}

async function fetchBetStatus(betId){return financial.fetchBetStatus(betId);}

async function refreshCurrentBetLight(){
  if(!myBet||!playerToken()||!round)return false;

  const requestedBetId=Number(myBet);
  const requestedRoundId=Number(round.id);

  try{
    const bet=await fetchBetStatus(requestedBetId);
    if(!bet||Number(round?.id)!==requestedRoundId)return false;

    if(bet.status==='ACTIVE'){
      setBetResult(null);
      myStake=Number(bet.stake)||myStake;
      myAutoCashout=Number(bet.auto_cashout_multiplier)||null;
      renderTicket();
      return true;
    }

    myBet=null;
    myStake=0;
    myAutoCashout=null;
    lastRecoveredRoundId=requestedRoundId;
    resetCashout();
    renderTicket();
    renderBetConfirmation();

    if(bet.status==='CASHED_OUT'){
      setBetResultFromBet(bet);
      $('#aviatorMessage').textContent=cashoutMessage(
        bet.cashout_source,
        bet.cashout_multiplier,
        bet.payout
      );
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    if(bet.status==='LOST'){
      setBetResultFromBet(bet);
      $('#aviatorMessage').textContent='Fim da rodada. Cash-out não disponível.';
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    if(bet.status==='REFUNDED'){
      setBetResultFromBet(bet);
      $('#aviatorMessage').textContent='A aposta foi reembolsada pelo servidor.';
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    return false;
  }catch(_){
    return false;
  }
}

async function reconcilePendingCashout(){
  const pending=readPendingCashout();
  if(!pending||!connectionOnline||!playerToken())return false;

  try{
    const bet=await fetchBetStatus(pending.bet_id);

    if(!bet)return false;

    if(bet.status==='CASHED_OUT'){
      clearPendingCashout();
      setBetResultFromBet(bet);
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
      setBetResult(null);
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
      setBetResultFromBet(bet);
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
      setBetResultFromBet(bet);
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
    const current=runtime.pickActiveBet(bets,requestedRoundId,1);
    const latest=runtime.latestBet(bets,requestedRoundId,1);

    myBet=current?.id??null;
    myStake=current?Number(current.stake)||0:0;
    myAutoCashout=current?Number(current.auto_cashout_multiplier)||null:null;
    if(current)setBetResult(null);
    lastRecoveredRoundId=requestedRoundId;
    renderTicket();
    renderBetConfirmation();
    p2?.applyPlayerState(x);

    if(myBet&&round.status==='FLYING'){
      setBetResult(null);
      $('#aviatorMessage').textContent='Aposta ativa recuperada.';
    }else if(latest?.status==='CASHED_OUT'){
      setBetResultFromBet(latest);
      myAutoCashout=null;
      resetCashout();
      $('#aviatorMessage').textContent=cashoutMessage(
        latest.cashout_source,
        latest.cashout_multiplier,
        latest.payout
      );
    }else if(latest?.status==='LOST'){
      setBetResultFromBet(latest);
      $('#aviatorMessage').textContent='Fim da rodada. A aposta foi perdida.';
    }else if(latest?.status==='REFUNDED'){
      setBetResultFromBet(latest);
      $('#aviatorMessage').textContent='A aposta foi reembolsada pelo servidor.';
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

  const reveal=round?.round_seed_reveal||round?.visual_seed_reveal||null;
  const finished=['CRASHED','SETTLED'].includes(round?.status);

  if(!finished||!reveal){
    proof.textContent='Rodada protegida antes do voo.';
    return;
  }

  if(fairnessProofRoundId===Number(round.id)&&fairnessProofData?.check){
    const valid=Boolean(fairnessProofData.check.valid);
    proof.dataset.valid=valid?'true':'false';
    proof.textContent=valid
      ?'Rodada verificada ✓'
      :'Não foi possível validar esta rodada.';
    return;
  }

  if(fairnessProofRoundId===Number(round.id)&&fairnessProofData?.error){
    proof.textContent='Verificação indisponível neste momento.';
    return;
  }

  proof.textContent='A verificar rodada…';
  void loadFairnessProof(round.id);
}

function renderMaintenanceView(){
  const protectedFlight=
    !enabled&&['LOCKED','FLYING'].includes(round?.status)&&
    Boolean(myBet||p2?.hasActiveBet());
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
  updateRoundClock();
  startOpenUiTick();

  show('#preflight',true);
  show('#multiplierWrap',false);
  show('#crashText',false);

  resetCashout();
  renderTicket();
  renderBetConfirmation();

  if(myBet&&!$('#aviatorMessage').textContent.trim()){
    $('#aviatorMessage').textContent='Aposta confirmada.';
  }
  nextBet?.schedule();
  scheduleAutoBetForOpenRound();
}

function renderLocked(){
  stopOpenUiTick();
  stopFlight();
  setStagePhase('locked');
  renderRoundNumber();

  updateRoundClock();
  startOpenUiTick();

  show('#preflight',true);
  show('#multiplierWrap',false);
  show('#crashText',false);

  const queued=Boolean(nextBet?.hasQueued());
  setBetInputsLocked(!connectionOnline||!enabled||queued);
  renderBetAction(
    !connectionOnline||!enabled,
    queued?'Aposta registada':'Disponível',
    queued?'Cancelar':'Apostar',
    queued?'cancel-next':'queue-next'
  );

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

  const queued=Boolean(nextBet?.hasQueued());
  setBetInputsLocked(!connectionOnline||!enabled||Boolean(myBet)||queued);
  renderAutoBetStatus();
  renderBetAction(
    Boolean(myBet)||!connectionOnline||!enabled,
    queued?'Aposta registada':'Disponível',
    queued?'Cancelar':'Apostar',
    queued?'cancel-next':'queue-next',
    Boolean(myBet)
  );

  renderCashoutAction({
    active:Boolean(myBet),
    disabled:!connectionOnline||!myBet||cashingOut,
    pending:cashingOut,
    multiplier:mul(),
    stake:myStake
  });

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
  updateRoundClock();
  startOpenUiTick();
  $('#crashMultiplier').textContent=resultText;
  applyMultiplierTier($('#crashMultiplier'),result);

  show('#preflight',false);
  show('#multiplierWrap',false);
  show('#crashText',true);

  const queued=Boolean(nextBet?.hasQueued());
  setBetInputsLocked(!connectionOnline||!enabled||queued);
  renderAutoBetStatus();

  renderBetAction(
    !connectionOnline||!enabled,
    queued?'Aposta registada':'Disponível',
    queued?'Cancelar':'Apostar',
    queued?'cancel-next':'queue-next'
  );

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
  $('#preflightLabel').textContent='PRÓXIMA RODADA';
  $('#preflightCountdown').textContent='—';
  $('#preflightHint').textContent='A preparar';

  show('#preflight',true);
  show('#multiplierWrap',false);
  show('#crashText',false);

  const queued=Boolean(nextBet?.hasQueued());
  setBetInputsLocked(!connectionOnline||!enabled||queued);
  renderAutoBetStatus();

  renderBetAction(
    !connectionOnline||!enabled,
    queued?'Aposta registada':'Disponível',
    queued?'Cancelar':'Apostar',
    queued?'cancel-next':'queue-next'
  );

  resetCashout();
  renderTicket();
  renderBetConfirmation();
}

function renderCurrentRound(){
  renderProof();
  sound?.syncRound(round);
  haptics?.syncRound(round);

  if(!round){
    renderWaiting();
  }else if(round.status==='OPEN'){
    renderOpen();
  }else if(round.status==='LOCKED'){
    renderLocked();
  }else if(round.status==='FLYING'){
    renderFlying();
  }else if(round.status==='CRASHED'||round.status==='SETTLED'){
    renderFinished();
  }else{
    renderWaiting();
  }

  p2?.renderRound();
}

function nextPollDelay(){
  return engine.pollDelay({
    status:round?.status||'',
    hidden:document.hidden,
    realtimeConnected,
    enabled,
    hasBet:Boolean(myBet||p2?.hasActiveBet())
  });
}

function scheduleState(delay=nextPollDelay()){
  clearTimeout(stateTimer);
  if(!connectionOnline)return;
  stateTimer=setTimeout(state,delay);
}

function applyReconnectPlayerState(player){
  balance?.applyPlayerState(player);
  const bets=Array.isArray(player?.bets)?player.bets:[];
  const roundId=Number(round?.id);
  const current=Number.isFinite(roundId)?runtime.pickActiveBet(bets,roundId,1):null;
  const latest=Number.isFinite(roundId)?runtime.latestBet(bets,roundId,1):null;

  myBet=current?.id??null;
  myStake=current?Number(current.stake)||0:0;
  myAutoCashout=current?Number(current.auto_cashout_multiplier)||null:null;
  if(current)setBetResult(null);
  lastRecoveredRoundId=round?.id??null;

  if(latest?.status==='CASHED_OUT'){
    clearPendingCashout();
    setBetResultFromBet(latest);
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
    setBetResultFromBet(latest);
    myBet=null;
    myStake=0;
    myAutoCashout=null;
    $('#aviatorMessage').textContent='Fim da rodada. A aposta foi perdida.';
    preserveMessageOnNextRoundSync=true;
  }else if(latest?.status==='REFUNDED'){
    clearPendingCashout();
    setBetResultFromBet(latest);
    myBet=null;
    myStake=0;
    myAutoCashout=null;
    $('#aviatorMessage').textContent='A aposta foi reembolsada pelo servidor.';
    preserveMessageOnNextRoundSync=true;
  }

  renderTicket();
  renderBetConfirmation();
  renderAutoBetStatus();
  p2?.applyPlayerState(player);
}

async function reconnectState(){
  if(stateBusy||!connectionOnline)return;
  if(!playerToken()){
    return state();
  }

  const metricStartedAt=Date.now();
  const controller=new AbortController();
  stateController=controller;
  stateBusy=true;

  try{
    const x=await JLApi.rpc(
      'jl_aviator_reconnect',
      {p_token:playerToken()},
      {signal:controller.signal}
    );

    void financial.recordClientMetric(
      'RECONNECT',
      Date.now()-metricStartedAt,
      true,
      null,
      x?.round?.id,
      null
    );

    if(!runtime.shouldAcceptSnapshot(lastDisplaySeq,x?.display_seq)){
      return;
    }

    lastDisplaySeq=Number(x.display_seq);
    syncServerClock(x);
    enabled=x.enabled!==false;

    const previousId=round?.id??null;
    const previousStatus=round?.status??null;
    round=x.round||null;

    const changedRound=previousId!==round?.id;
    const justFinished=
      previousStatus!==round?.status&&
      ['CRASHED','SETTLED'].includes(round?.status);

    if(changedRound){
      nextBet?.resetRound();
      fairnessProofRoundId=null;
      fairnessProofData=null;
      fairnessProofBusy=false;
      stopFlight();
      resetCashout();
    }

    applyReconnectPlayerState(x?.player);

    if(justFinished&&playerToken()){
      if(myBet)await refreshCurrentBetLight();
      if(p2?.hasActiveBet())await p2.refreshOnStatusChange();
    }

    if(justFinished)rememberCurrentResult();

    if(changedRound||justFinished){
      void loadHistory(true);
    }else if(!history.remoteLoaded()&&!history.busy()){
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
    void financial.recordClientMetric(
      'RECONNECT',
      Date.now()-metricStartedAt,
      false,
      e?.code||e?.message||'RECONNECT_FAILED',
      round?.id,
      null
    );
    if(navigator.onLine===false)setConnectionState(false);
    const message=$('#aviatorMessage');
    if(message)message.textContent=playerMessage(e,'Não foi possível sincronizar o jogo.');
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
    syncServerClock(x);
    enabled=x.enabled!==false;

    const previousId=round?.id??null;
    const previousStatus=round?.status??null;
    round=x.round||null;

    const changedRound=previousId!==round?.id;
    const justFinished=
      previousStatus!==round?.status&&
      ['CRASHED','SETTLED'].includes(round?.status);

    if(changedRound){
      nextBet?.resetRound();
      fairnessProofRoundId=null;
      fairnessProofData=null;
      fairnessProofBusy=false;
      p2?.onRoundChanged();
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
    }else if(!history.remoteLoaded()&&!history.busy()){
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
    if(message)message.textContent=playerMessage(e,'Não foi possível atualizar o jogo.');
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

  const action=String($('#betBtn')?.dataset.action||'bet');
  if(nextBet?.handleAction(action)){renderCurrentRound();return}

  const queuedTriggered=
    action==='bet'&&Boolean(nextBet?.isSubmitting(round?.id));
  const autoTriggered=
    action==='bet'&&
    autoBetSubmittingRoundId===Number(round?.id);
  betting=true;

  if(action==='cancel'){
    const id=myBet;
    const stake=myStake;
    renderBetAction(true,'Cancelando aposta…','Cancelar','cancel');

    try{
      if(!connectionOnline)throw new Error('Sem ligação. Aguarde a reconexão.');
      if(!playerToken())throw new Error('Entre na sua conta primeiro.');
      if(!id||!round||round.status!=='OPEN'||round.betting_open===false){
        throw new Error('Cancelamento encerrado para esta rodada.');
      }

      const result=await financial.cancelBet(
        id,
        financial.cancelBetRequestKey(id)
      );

      personalHistory?.invalidate();
      setBetResult({
        status:'REFUNDED',
        stake,
        payout:Number(result.refund)||stake
      });

      myBet=null;
      myStake=0;
      myAutoCashout=null;
      lastRecoveredRoundId=round?.id??null;
      renderTicket();
      renderBetConfirmation();
      $('#aviatorMessage').textContent=
        'Aposta cancelada. '+money(Number(result.refund)||stake)+' devolvidos.';
    }catch(error){
      $('#aviatorMessage').textContent=playerMessage(
        error,
        'Não foi possível cancelar a aposta.'
      );
      if(/Cancelamento encerrado|Apostas fechadas/i.test(String(error?.message||error))){
        lastRecoveredRoundId=null;
        await reconnectState();
      }
    }finally{
      betting=false;
      renderCurrentRound();
    }
    return;
  }

  renderBetAction(true,'Confirmando aposta…','Apostar','bet');

  try{
    if(!connectionOnline)throw new Error('Sem ligação. Aguarde a reconexão.');
    if(!playerToken())throw new Error('Entre na sua conta primeiro.');
    if(!enabled)throw new Error('Aviator brevemente.');
    if(!round||round.status!=='OPEN'||round.betting_open===false)throw new Error('Apostas fechadas.');

    const amount=Number($('#aviatorAmount').value);
    if(!Number.isFinite(amount)||amount<0.5||amount>500){
      throw new Error('Informe um valor entre 0,50 e 500.');
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

    const r=await financial.placeBetSlot({
      slot:1,
      amount,
      requestKey:betKey(),
      autoCashoutMultiplier:auto
    });

    setBetResult(null);
    personalHistory?.invalidate();
    myBet=r.bet_id;
    myStake=Number(r.stake);
    myAutoCashout=Number(r.auto_cashout_multiplier)||null;
    sound?.playBet();
    if(queuedTriggered)nextBet?.consume(round?.id);
    lastRecoveredRoundId=round.id;
    renderTicket();
    renderBetConfirmation();

    $('#aviatorMessage').textContent=autoTriggered
      ?'Aposta automática confirmada para esta rodada.'
      :'Aposta confirmada. Aguarde o voo.';
    renderAutoBetStatus();
  }catch(e){
    $('#aviatorMessage').textContent=playerMessage(e,'Não foi possível confirmar a aposta.');
  }finally{
    if(autoBetSubmittingRoundId===Number(round?.id)){
      autoBetSubmittingRoundId=null;
    }
    nextBet?.clearSubmitting(round?.id);
    betting=false;
    renderCurrentRound();
  }
});

$('#cashoutBtn').addEventListener('click',async event=>{
  event.preventDefault();
  if(!cashoutGestureGuard.shouldAcceptClick(event))return;
  if(!connectionOnline){
    $('#aviatorMessage').textContent='Sem ligação. Cash-out indisponível até reconectar.';
    return;
  }
  if(cashingOut||!myBet||round?.status!=='FLYING')return;

  cashingOut=true;
  const id=myBet;
  const cashoutRoundId=Number(round.id);
  const requestKey=cashoutRequestKey(id);
  savePendingCashout(id,cashoutRoundId,requestKey);
  renderCashoutAction({
    active:true,
    disabled:true,
    pending:true,
    multiplier:mul(),
    stake:myStake,
    status:'A confirmar no servidor'
  });

  try{
    const r=await requestFinancialCashout(id,requestKey);

    clearPendingCashout();
    $('#aviatorMessage').textContent=cashoutMessage(
      r.source,
      r.multiplier,
      r.payout
    );
    sound?.playCashout();
    setBetResult({
      status:'CASHED_OUT',
      stake:myStake,
      payout:Number(r.payout),
      cashout_multiplier:Number(r.multiplier)
    });

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
      $('#aviatorMessage').textContent=playerMessage(
        raw,
        'Não foi possível confirmar o cash-out.'
      );
      lastRecoveredRoundId=null;
      await recover(true);
    }
  }finally{
    cashingOut=false;
    renderMaintenanceView();
    renderCurrentRound();
  }
});

async function applyRealtimeSnapshot(x){
  if(!x||!runtime.shouldAcceptSnapshot(lastDisplaySeq,x?.display_seq))return;

  lastDisplaySeq=Number(x.display_seq);
  syncServerClock(x);
  enabled=x.enabled!==false;

  const previousId=round?.id??null;
  const previousStatus=round?.status??null;
  round=x.round||null;

  const changedRound=previousId!==round?.id;
  const changedStatus=previousStatus!==round?.status;
  const justFinished=
    changedStatus&&['CRASHED','SETTLED'].includes(round?.status);

  if(changedRound){
    fairnessProofRoundId=null;
    fairnessProofData=null;
    fairnessProofBusy=false;
    p2?.onRoundChanged();
    myBet=null;
    myStake=0;
    myAutoCashout=null;
    autoRecoveryRoundId=null;
    lastRecoveredRoundId=null;
    stopFlight();
    resetCashout();
    renderTicket();
    renderBetConfirmation();
  }

  if(
    round&&
    playerToken()&&
    Boolean(myBet)&&
    changedStatus
  ){
    await refreshCurrentBetLight();
  }

  if(round&&playerToken()&&changedStatus&&p2?.hasActiveBet()){
    await p2.refreshOnStatusChange();
  }

  if(justFinished){
    rememberCurrentResult();
    void loadHistory(true);
  }

  if(renderMaintenanceView()){
    stopOpenUiTick();
    stopFlight();
    resetCashout();
    return;
  }

  renderCurrentRound();
  clearTimeout(stateTimer);
  if(connectionOnline)scheduleState();
}

function startRealtime(){
  if(!window.JLAviatorRealtime)return;

  window.JLAviatorRealtime.connect({
    onState:(payload)=>{
      void applyRealtimeSnapshot(payload);
    },
    onStatus:(connected)=>{
      realtimeConnected=Boolean(connected);
      clearTimeout(stateTimer);
      if(!connectionOnline)return;
      if(connected){
        if(!stateBusy)void reconnectState();
        scheduleState(120000);
      }else{
        scheduleState(3000);
      }
    }
  });
}

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
  await reconcilePendingCashout();
  await p2?.reconcilePendingCashout?.();
});

document.addEventListener('visibilitychange',()=>{
  clearTimeout(stateTimer);
  if(!document.hidden){
    lastRecoveredRoundId=null;
    reconnectState();
  }else{
    stopOpenUiTick();
    stopFlight();
    scheduleState();
  }
});

const autoBetToggle=$('#aviatorAutoBet');
if(autoBetToggle){
  autoBetToggle.checked=autoBetEnabled;
  autoBetToggle.addEventListener('change',()=>{
    autoBetEnabled=Boolean(autoBetToggle.checked);
    try{
      sessionStorage.setItem(
        'jl_aviator_auto_bet_v1',
        autoBetEnabled?'1':'0'
      );
    }catch(_){}
    if(!autoBetEnabled){
      autoBetSubmittingRoundId=null;
      autoBetAttemptedRoundId=null;
    }
    renderAutoBetStatus();
    if(autoBetEnabled)scheduleAutoBetForOpenRound();
  });
}

renderAutoBetStatus();
renderHistory();
setConnectionState(connectionOnline);
startRealtime();
if(connectionOnline){
  reconnectState();
}

window.addEventListener('pagehide',()=>{
  window.JLAviatorRealtime?.disconnect?.();
});

})();