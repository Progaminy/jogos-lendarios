(()=>{'use strict';

const $=s=>document.querySelector(s);

let round=null;
let myBet=null;
let myStake=0;
let myAutoCashout=null;
let myBet2=null;
let myStake2=0;
let myAutoCashout2=null;
let lastBetResult=null;
let lastBetResult2=null;
let recovering=false;
let lastRecoveredRoundId=null;
let enabled=true;
let stateBusy=false;
let stateController=null;
let lastDisplaySeq=null;
let stateTimer=0;
let betting=false;
let betting2=false;
let cashingOut=false;
let cashingOut2=false;
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
let autoRecoveryRoundId2=null;
let lastFlightHudAt=0;
let autoBetEnabled=sessionStorage.getItem('jl_aviator_auto_bet_v1')==='1';
let autoBetEnabled2=sessionStorage.getItem('jl_aviator_auto_bet_v1_slot_2')==='1';
let autoBetAttemptedRoundId=null;
let autoBetAttemptedRoundId2=null;
let autoBetSubmittingRoundId=null;
let autoBetSubmittingRoundId2=null;

const playerToken=()=>JLSession.getPlayerToken();
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
  pollDelay:(status,hidden,realtimeConnected=false)=>{
    if(realtimeConnected)return hidden?300000:120000;
    if(hidden)return 30000;
    if(status==='FLYING'||status==='LOCKED')return 3000;
    if(status==='OPEN')return 5000;
    return 15000;
  },
  liveMultiplier:(startedAt,serverNowMs)=>{
    const start=Date.parse(startedAt);
    const now=Number(serverNowMs);
    if(!Number.isFinite(start)||!Number.isFinite(now))return 1;
    return Math.max(1,Math.pow(1.06,Math.max(0,(now-start)/1000)));
  },
  secondsUntil:(isoTime,serverNowMs)=>{
    const target=Date.parse(isoTime);
    const now=Number(serverNowMs);
    if(!Number.isFinite(target)||!Number.isFinite(now))return null;
    return Math.max(0,Math.ceil((target-now)/1000));
  },
  shouldAcceptSnapshot:(previousSeq,nextSeq)=>{
    const next=Number(nextSeq);
    if(!Number.isFinite(next))return false;
    const previous=Number(previousSeq);
    return !Number.isFinite(previous)||next>=previous;
  }
};

function betSlotOf(bet){
  return Number(bet?.bet_slot)===2?2:1;
}

function activeBetForSlot(bets,roundId,slot){
  if(!Array.isArray(bets))return null;
  return bets
    .filter(b=>
      Number(b?.round_id)===Number(roundId)&&
      String(b?.status)==='ACTIVE'&&
      betSlotOf(b)===Number(slot)
    )
    .sort((a,b)=>Number(b?.id)-Number(a?.id))[0]||null;
}

function latestBetForSlot(bets,roundId,slot){
  if(!Array.isArray(bets))return null;
  return bets
    .filter(b=>
      Number(b?.round_id)===Number(roundId)&&
      betSlotOf(b)===Number(slot)
    )
    .sort((a,b)=>Number(b?.id)-Number(a?.id))[0]||null;
}

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

function cashoutRequestKey(betId){return financial.cashoutRequestKey(betId);}

function readPendingCashout(){return financial.readPendingCashout(1);}
function readPendingCashout2(){return financial.readPendingCashout(2);}

function savePendingCashout(betId,roundId,requestKey){return financial.savePendingCashout(betId,roundId,requestKey,1);}
function savePendingCashout2(betId,roundId,requestKey){return financial.savePendingCashout(betId,roundId,requestKey,2);}

function clearPendingCashout(){return financial.clearPendingCashout(1);}
function clearPendingCashout2(){return financial.clearPendingCashout(2);}

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

function secondsToTakeoff(){return engine.secondsToTakeoff();}
function secondsToNextRound(){return engine.secondsToNextRound();}

function betKey(){return financial.betKeyForSlot(1);}
function betKey2(){return financial.betKeyForSlot(2);}

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
const cashoutGestureGuard2=ui.createCashoutGestureGuard($('#cashoutBtn2'));

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

function setBetInputsLocked2(locked){
  const amount=$('#aviatorAmount2');
  const auto=$('#aviatorAutoCashout2');
  if(amount)amount.disabled=Boolean(locked);
  if(auto)auto.disabled=Boolean(locked);
}

function renderBetAction2(disabled,status,label='Apostar',mode='bet',hidden=false){
  const wrap=$('.aviator-bet-action-2');
  const button=$('#betBtn2');
  const statusEl=$('#betActionStatus2');
  if(wrap){
    wrap.classList.toggle('hidden',Boolean(hidden));
    wrap.classList.toggle('is-cancel',mode==='cancel');
  }
  if(button){
    button.textContent=String(label||'Apostar');
    button.disabled=Boolean(disabled);
    button.dataset.action=String(mode||'bet');
  }
  if(statusEl)statusEl.textContent=String(status||'');
}

function renderCashoutAction2({
  active=false,
  disabled=true,
  pending=false,
  multiplier=null,
  stake=0,
  status=''
}={}){
  const wrap=$('#cashoutAction2');
  const button=$('#cashoutBtn2');
  const statusEl=$('#cashoutActionStatus2');
  const m=Number(multiplier);
  const s=Number(stake);
  const hasMultiplier=Number.isFinite(m)&&m>=1;
  const hasStake=Number.isFinite(s)&&s>0;
  const priority=Boolean(active)&&!disabled&&!pending;

  if(wrap){
    wrap.classList.toggle('hidden',!active&&!pending);
    wrap.classList.toggle('is-priority',priority);
    wrap.classList.toggle('is-pending',Boolean(pending));
  }
  if(button){
    button.disabled=Boolean(disabled);
    button.textContent=pending
      ?'Confirmando cash-out…'
      :active&&hasMultiplier&&hasStake
        ?'Cash-out · '+money(s*m)
        :'Cash-out';
  }
  if(statusEl){
    statusEl.textContent=status
      ?String(status)
      :active&&hasMultiplier&&hasStake
        ?moneyCompact(s)+' × '+m.toFixed(2)+' = '+money(s*m)
        :'Disponível durante o voo';
  }
}

function resetCashout2(){
  renderCashoutAction2({
    active:false,
    disabled:true,
    pending:false,
    multiplier:null,
    stake:0,
    status:'Disponível durante o voo'
  });
}

function renderTicket2(multiplierValue=null){
  const panel=$('#activeBetPanel2');
  if(!panel)return;
  const active=Boolean(myBet2)&&myStake2>0;
  panel.classList.toggle('hidden',!active);
  if(!active)return;

  $('#activeBetStake2').textContent=money(myStake2);
  $('#activeBetAuto2').textContent=myAutoCashout2
    ?'Auto '+Number(myAutoCashout2).toFixed(2)+'×'
    :'Auto desligado';

  if(round?.status==='FLYING'){
    const m=Number(multiplierValue??mul());
    const safe=Number.isFinite(m)&&m>=1?m:1;
    $('#activeBetMultiplier2').textContent=safe.toFixed(2)+'×';
    $('#activeBetPayout2').textContent=money(myStake2*safe);
  }else{
    $('#activeBetMultiplier2').textContent='A aguardar';
    $('#activeBetPayout2').textContent=money(myStake2);
  }
}

function renderBetConfirmation2(){
  const box=$('#betConfirmation2');
  const text=$('#betConfirmationText2');
  const auto=$('#betConfirmationAuto2');
  if(!box||!text)return;

  const visible=
    Boolean(myBet2)&&
    myStake2>0&&
    ['OPEN','LOCKED'].includes(round?.status);

  box.classList.toggle('hidden',!visible);
  if(!visible)return;

  text.textContent='Aposta confirmada: '+moneyCompact(myStake2);
  if(auto){
    const hasAuto=Number.isFinite(Number(myAutoCashout2))&&Number(myAutoCashout2)>=1.01;
    auto.classList.toggle('hidden',!hasAuto);
    auto.textContent=hasAuto?'Auto cash-out: '+Number(myAutoCashout2).toFixed(2)+'×':'';
  }
}

function setBetResult2(result=null){
  lastBetResult2=result||null;
  const panel=$('#betResultPanel2');
  const icon=$('#betResultIcon2');
  const label=$('#betResultLabel2');
  const detail=$('#betResultDetail2');
  if(!panel||!icon||!label||!detail)return;

  const status=String(result?.status||'').toUpperCase();
  const stake=Number(result?.stake);
  const payout=Number(result?.payout);
  const multiplier=Number(result?.cashout_multiplier);

  panel.classList.remove('is-won','is-lost','is-refunded');

  if(!['CASHED_OUT','LOST','REFUNDED'].includes(status)){
    panel.classList.add('hidden');
    panel.removeAttribute('data-result');
    return;
  }

  panel.classList.remove('hidden');
  if(status==='CASHED_OUT'){
    panel.classList.add('is-won');
    panel.dataset.result='won';
    icon.textContent='✓';
    label.textContent='GANHA';
    detail.textContent=Number.isFinite(payout)
      ?'Recebido '+money(payout)+(Number.isFinite(multiplier)?' · '+multiplier.toFixed(2)+'×':'')
      :'Cash-out confirmado';
  }else if(status==='LOST'){
    panel.classList.add('is-lost');
    panel.dataset.result='lost';
    icon.textContent='✕';
    label.textContent='PERDIDA';
    detail.textContent=Number.isFinite(stake)&&stake>0
      ?'Valor perdido '+money(stake)
      :'Rodada encerrada sem cash-out';
  }else{
    panel.classList.add('is-refunded');
    panel.dataset.result='refunded';
    icon.textContent='↩';
    label.textContent='REEMBOLSADA';
    detail.textContent=Number.isFinite(payout)&&payout>0
      ?'Devolvido '+money(payout)
      :Number.isFinite(stake)&&stake>0?'Devolvido '+money(stake):'Valor devolvido';
  }
  personalHistory?.invalidate();
}

function setBetResultFromBet2(bet){
  if(!bet){
    setBetResult2(null);
    return;
  }
  const status=String(bet.status||'').toUpperCase();
  if(!['CASHED_OUT','LOST','REFUNDED'].includes(status)){
    if(status==='ACTIVE')setBetResult2(null);
    return;
  }
  setBetResult2({
    status,
    stake:Number(bet.stake),
    payout:Number(bet.payout),
    cashout_multiplier:Number(bet.cashout_multiplier)
  });
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

  status.textContent=round?.status==='OPEN'
    ?'A preparar envio'
    :'Próxima aposta preparada';
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
    autoBetAttemptedRoundId===roundId
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

function renderAutoBetStatus2(){
  const toggle=$('#aviatorAutoBet2');
  const status=$('#aviatorAutoBetStatus2');
  if(toggle&&toggle.checked!==autoBetEnabled2)toggle.checked=autoBetEnabled2;
  if(!status)return;

  if(!autoBetEnabled2){
    status.textContent='Desligado';
    return;
  }

  if(!playerToken()){
    status.textContent='Entre na conta';
    return;
  }

  if(round?.status==='OPEN'&&myBet2){
    status.textContent='Confirmada nesta rodada';
    return;
  }

  status.textContent=round?.status==='OPEN'
    ?'A preparar envio'
    :'Próxima aposta preparada';
}

function scheduleAutoBetForOpenRound2(){
  renderAutoBetStatus2();

  const roundId=Number(round?.id);
  if(
    !autoBetEnabled2||
    !enabled||
    !connectionOnline||
    !playerToken()||
    !Number.isFinite(roundId)||
    round?.status!=='OPEN'||
    round?.betting_open===false||
    myBet2||
    betting2||
    autoBetAttemptedRoundId2===roundId
  ){
    return;
  }

  autoBetAttemptedRoundId2=roundId;

  queueMicrotask(()=>{
    if(
      !autoBetEnabled2||
      !connectionOnline||
      !playerToken()||
      Number(round?.id)!==roundId||
      round?.status!=='OPEN'||
      round?.betting_open===false||
      myBet2||
      betting2
    ){
      return;
    }

    autoBetSubmittingRoundId2=roundId;
    $('#aviatorBetForm2')?.requestSubmit?.();
  });
}

function updateRoundClock(){
  if(!connectionOnline){
    stopOpenUiTick();
    return;
  }

  if(round?.status==='OPEN'){
    const seconds=secondsToClose();
    const takeoffSeconds=secondsToTakeoff();
    const display=seconds===null?'—':String(seconds)+'s';
    const takeoffDisplay=takeoffSeconds===null?'—':String(takeoffSeconds)+'s';
    const closed=round?.betting_open===false||seconds===0;

    $('#roundState').textContent=closed?'APOSTAS FECHADAS':'APOSTAS ABERTAS';
    $('#clockLabel').textContent=closed?'DESCOLAGEM EM':'APOSTAS FECHAM EM';
    $('#roundCountdown').textContent=closed?takeoffDisplay:display;
    $('#preflightLabel').textContent='DESCOLAGEM EM';
    $('#preflightCountdown').textContent=takeoffDisplay;
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

    const inputsLocked2=
      !enabled||!connectionOnline||Boolean(myBet2)||betting2||closed;
    const canCancel2=
      enabled&&connectionOnline&&Boolean(myBet2)&&!betting2&&!closed;
    setBetInputsLocked2(inputsLocked2);

    if(canCancel2){
      renderBetAction2(
        false,
        'Aposta confirmada · toque para cancelar',
        'Cancelar',
        'cancel'
      );
    }else{
      renderBetAction2(
        inputsLocked2,
        myBet2
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
    const seconds=secondsToTakeoff();
    const display=seconds===null?'—':String(seconds)+'s';
    $('#roundState').textContent='APOSTAS FECHADAS';
    $('#clockLabel').textContent='DESCOLAGEM EM';
    $('#roundCountdown').textContent=display;
    $('#preflightLabel').textContent='DESCOLAGEM EM';
    $('#preflightCountdown').textContent=display;
    $('#preflightHint').textContent='Contagem em segundos';
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
  renderTicket2(m);

  renderCashoutAction({
    active:Boolean(myBet),
    disabled:!connectionOnline||!myBet||cashingOut,
    pending:cashingOut,
    multiplier:m,
    stake:myStake
  });

  renderCashoutAction2({
    active:Boolean(myBet2),
    disabled:!connectionOnline||!myBet2||cashingOut2,
    pending:cashingOut2,
    multiplier:m,
    stake:myStake2
  });
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

    if(
      myBet2&&
      myAutoCashout2&&
      Number(round?.id)!==Number(autoRecoveryRoundId2)&&
      mul()>=myAutoCashout2
    ){
      autoRecoveryRoundId2=Number(round.id);
      void refreshCurrentBetLight2();
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

async function refreshCurrentBetLight2(){
  if(!myBet2||!playerToken()||!round)return false;

  const requestedBetId=Number(myBet2);
  const requestedRoundId=Number(round.id);

  try{
    const bet=await fetchBetStatus(requestedBetId);
    if(!bet||Number(round?.id)!==requestedRoundId)return false;

    if(bet.status==='ACTIVE'){
      setBetResult2(null);
      myStake2=Number(bet.stake)||myStake2;
      myAutoCashout2=Number(bet.auto_cashout_multiplier)||null;
      renderTicket2();
      return true;
    }

    myBet2=null;
    myStake2=0;
    myAutoCashout2=null;
    lastRecoveredRoundId=requestedRoundId;
    resetCashout2();
    renderTicket2();
    renderBetConfirmation2();

    if(bet.status==='CASHED_OUT'){
      setBetResultFromBet2(bet);
      $('#aviatorMessage2').textContent=cashoutMessage(
        bet.cashout_source,
        bet.cashout_multiplier,
        bet.payout
      );
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    if(bet.status==='LOST'){
      setBetResultFromBet2(bet);
      $('#aviatorMessage2').textContent='Fim da rodada. Cash-out não disponível.';
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    if(bet.status==='REFUNDED'){
      setBetResultFromBet2(bet);
      $('#aviatorMessage2').textContent='A aposta foi reembolsada pelo servidor.';
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

async function reconcilePendingCashout2(){
  const pending=readPendingCashout2();
  if(!pending||!connectionOnline||!playerToken())return false;

  try{
    const bet=await fetchBetStatus(pending.bet_id);
    if(!bet)return false;

    if(bet.status==='CASHED_OUT'){
      clearPendingCashout2();
      setBetResultFromBet2(bet);
      myBet2=null;
      myStake2=0;
      myAutoCashout2=null;
      lastRecoveredRoundId=pending.round_id;
      resetCashout2();
      renderTicket2();
      $('#aviatorMessage2').textContent=cashoutMessage(
        bet.cashout_source,
        bet.cashout_multiplier,
        bet.payout
      );
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    if(bet.status==='ACTIVE'){
      clearPendingCashout2();
      setBetResult2(null);
      if(Number(round?.id)===pending.round_id){
        myBet2=bet.id;
        myStake2=Number(bet.stake)||0;
        myAutoCashout2=Number(bet.auto_cashout_multiplier)||null;
        lastRecoveredRoundId=pending.round_id;
        renderTicket2();
      }
      $('#aviatorMessage2').textContent='Cash-out não foi confirmado. A aposta continua ativa.';
      return true;
    }

    if(bet.status==='LOST'){
      clearPendingCashout2();
      setBetResultFromBet2(bet);
      myBet2=null;
      myStake2=0;
      myAutoCashout2=null;
      resetCashout2();
      renderTicket2();
      $('#aviatorMessage2').textContent='Fim da rodada. Cash-out não disponível.';
      preserveMessageOnNextRoundSync=true;
      return true;
    }

    if(bet.status==='REFUNDED'){
      clearPendingCashout2();
      setBetResultFromBet2(bet);
      myBet2=null;
      myStake2=0;
      myAutoCashout2=null;
      resetCashout2();
      renderTicket2();
      $('#aviatorMessage2').textContent='A aposta foi reembolsada pelo servidor.';
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
    if(Number(round?.id)!==requestedRoundId)return;

    applyReconnectPlayerState(x);

    if(myBet&&round.status==='FLYING'){
      $('#aviatorMessage').textContent='Aposta 1 ativa recuperada.';
    }
    if(myBet2&&round.status==='FLYING'){
      $('#aviatorMessage2').textContent='Aposta 2 ativa recuperada.';
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
    !enabled&&['LOCKED','FLYING'].includes(round?.status)&&Boolean(myBet||myBet2);
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
  resetCashout2();
  renderTicket();
  renderTicket2();
  renderBetConfirmation();
  renderBetConfirmation2();
  renderAutoBetStatus();
  renderAutoBetStatus2();

  if(myBet&&!$('#aviatorMessage').textContent.trim()){
    $('#aviatorMessage').textContent='Aposta confirmada. Pode cancelar enquanto as apostas estiverem abertas.';
  }
  if(myBet2&&!$('#aviatorMessage2').textContent.trim()){
    $('#aviatorMessage2').textContent='Aposta confirmada. Pode cancelar enquanto as apostas estiverem abertas.';
  }

  scheduleAutoBetForOpenRound();
  scheduleAutoBetForOpenRound2();
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

  setBetInputsLocked(!connectionOnline||!enabled);
  setBetInputsLocked2(!connectionOnline||!enabled);
  renderAutoBetStatus();
  renderAutoBetStatus2();

  renderBetAction(true,'Apostas fechadas');
  renderBetAction2(true,'Apostas fechadas');

  resetCashout();
  resetCashout2();
  renderTicket();
  renderTicket2();
  renderBetConfirmation();
  renderBetConfirmation2();

  if(myBet){
    $('#aviatorMessage').textContent='Aposta confirmada. Aguardando descolagem.';
  }
  if(myBet2){
    $('#aviatorMessage2').textContent='Aposta confirmada. Aguardando descolagem.';
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

  setBetInputsLocked(!connectionOnline||!enabled);
  setBetInputsLocked2(!connectionOnline||!enabled);
  renderAutoBetStatus();
  renderAutoBetStatus2();

  renderBetAction(
    true,
    'Apostas fechadas',
    'Apostar',
    'bet',
    Boolean(myBet)
  );
  renderBetAction2(
    true,
    'Apostas fechadas',
    'Apostar',
    'bet',
    Boolean(myBet2)
  );

  renderCashoutAction({
    active:Boolean(myBet),
    disabled:!connectionOnline||!myBet||cashingOut,
    pending:cashingOut,
    multiplier:mul(),
    stake:myStake
  });
  renderCashoutAction2({
    active:Boolean(myBet2),
    disabled:!connectionOnline||!myBet2||cashingOut2,
    pending:cashingOut2,
    multiplier:mul(),
    stake:myStake2
  });

  renderTicket(mul());
  renderTicket2(mul());
  renderBetConfirmation();
  renderBetConfirmation2();
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

  setBetInputsLocked(!connectionOnline||!enabled);
  setBetInputsLocked2(!connectionOnline||!enabled);
  renderAutoBetStatus();
  renderAutoBetStatus2();

  renderBetAction(true,'Aguarde a próxima rodada');
  renderBetAction2(true,'Aguarde a próxima rodada');

  myBet=null;
  myStake=0;
  myAutoCashout=null;
  myBet2=null;
  myStake2=0;
  myAutoCashout2=null;
  resetCashout();
  resetCashout2();
  renderTicket();
  renderTicket2();
  renderBetConfirmation();
  renderBetConfirmation2();
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

  setBetInputsLocked(!connectionOnline||!enabled);
  setBetInputsLocked2(!connectionOnline||!enabled);
  renderAutoBetStatus();
  renderAutoBetStatus2();

  renderBetAction(true,'Aguarde a próxima rodada');
  renderBetAction2(true,'Aguarde a próxima rodada');

  resetCashout();
  resetCashout2();
  renderTicket();
  renderTicket2();
  renderBetConfirmation();
  renderBetConfirmation2();
}

function renderCurrentRound(){
  renderProof();
  sound?.syncRound(round);
  haptics?.syncRound(round);

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
  return engine.pollDelay({
    status:round?.status||'',
    hidden:document.hidden,
    realtimeConnected,
    enabled,
    hasBet:Boolean(myBet||myBet2)
  });
}

function scheduleState(delay=nextPollDelay()){
  clearTimeout(stateTimer);
  if(!connectionOnline)return;
  stateTimer=setTimeout(state,delay);
}

function applyReconnectPlayerState(player){
  const bets=Array.isArray(player?.bets)?player.bets:[];
  const roundId=Number(round?.id);
  const current1=Number.isFinite(roundId)?activeBetForSlot(bets,roundId,1):null;
  const current2=Number.isFinite(roundId)?activeBetForSlot(bets,roundId,2):null;
  const latest1=Number.isFinite(roundId)?latestBetForSlot(bets,roundId,1):null;
  const latest2=Number.isFinite(roundId)?latestBetForSlot(bets,roundId,2):null;

  myBet=current1?.id??null;
  myStake=current1?Number(current1.stake)||0:0;
  myAutoCashout=current1?Number(current1.auto_cashout_multiplier)||null:null;
  myBet2=current2?.id??null;
  myStake2=current2?Number(current2.stake)||0:0;
  myAutoCashout2=current2?Number(current2.auto_cashout_multiplier)||null:null;

  if(current1)setBetResult(null);
  if(current2)setBetResult2(null);
  lastRecoveredRoundId=round?.id??null;

  if(!current1&&latest1){
    if(latest1.status==='CASHED_OUT'){
      clearPendingCashout();
      setBetResultFromBet(latest1);
      $('#aviatorMessage').textContent=cashoutMessage(
        latest1.cashout_source,
        latest1.cashout_multiplier,
        latest1.payout
      );
      preserveMessageOnNextRoundSync=true;
    }else if(latest1.status==='LOST'){
      clearPendingCashout();
      setBetResultFromBet(latest1);
      $('#aviatorMessage').textContent='Fim da rodada. A aposta foi perdida.';
      preserveMessageOnNextRoundSync=true;
    }else if(latest1.status==='REFUNDED'){
      clearPendingCashout();
      setBetResultFromBet(latest1);
      $('#aviatorMessage').textContent='A aposta foi reembolsada pelo servidor.';
      preserveMessageOnNextRoundSync=true;
    }
  }

  if(!current2&&latest2){
    if(latest2.status==='CASHED_OUT'){
      clearPendingCashout2();
      setBetResultFromBet2(latest2);
      $('#aviatorMessage2').textContent=cashoutMessage(
        latest2.cashout_source,
        latest2.cashout_multiplier,
        latest2.payout
      );
      preserveMessageOnNextRoundSync=true;
    }else if(latest2.status==='LOST'){
      clearPendingCashout2();
      setBetResultFromBet2(latest2);
      $('#aviatorMessage2').textContent='Fim da rodada. A aposta foi perdida.';
      preserveMessageOnNextRoundSync=true;
    }else if(latest2.status==='REFUNDED'){
      clearPendingCashout2();
      setBetResultFromBet2(latest2);
      $('#aviatorMessage2').textContent='A aposta foi reembolsada pelo servidor.';
      preserveMessageOnNextRoundSync=true;
    }
  }

  renderTicket();
  renderTicket2();
  renderBetConfirmation();
  renderBetConfirmation2();
  renderAutoBetStatus();
  renderAutoBetStatus2();
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
    lastRecoveredRoundId=round.id;
    renderTicket();
    renderBetConfirmation();

    $('#aviatorMessage').textContent=autoTriggered
      ?'Aposta automática confirmada para esta rodada.'
      :'Aposta confirmada. Aguarde a descolagem.';
    renderAutoBetStatus();
  }catch(e){
    $('#aviatorMessage').textContent=playerMessage(e,'Não foi possível confirmar a aposta.');
  }finally{
    if(autoBetSubmittingRoundId===Number(round?.id)){
      autoBetSubmittingRoundId=null;
    }
    betting=false;
    renderCurrentRound();
  }
});

$('#aviatorBetForm2').addEventListener('submit',async e=>{
  e.preventDefault();
  if(betting2)return;

  const action=String($('#betBtn2')?.dataset.action||'bet');
  const autoTriggered=
    action==='bet'&&
    autoBetSubmittingRoundId2===Number(round?.id);
  betting2=true;

  if(action==='cancel'){
    const id=myBet2;
    const stake=myStake2;
    renderBetAction2(true,'Cancelando aposta…','Cancelar','cancel');

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
      setBetResult2({
        status:'REFUNDED',
        stake,
        payout:Number(result.refund)||stake
      });

      myBet2=null;
      myStake2=0;
      myAutoCashout2=null;
      lastRecoveredRoundId=round?.id??null;
      renderTicket2();
      renderBetConfirmation2();
      $('#aviatorMessage2').textContent=
        'Aposta cancelada. '+money(Number(result.refund)||stake)+' devolvidos.';
    }catch(error){
      $('#aviatorMessage2').textContent=playerMessage(
        error,
        'Não foi possível cancelar a aposta.'
      );
      if(/Cancelamento encerrado|Apostas fechadas/i.test(String(error?.message||error))){
        lastRecoveredRoundId=null;
        await reconnectState();
      }
    }finally{
      betting2=false;
      renderCurrentRound();
    }
    return;
  }

  renderBetAction2(true,'Confirmando aposta…','Apostar','bet');

  try{
    if(!connectionOnline)throw new Error('Sem ligação. Aguarde a reconexão.');
    if(!playerToken())throw new Error('Entre na sua conta primeiro.');
    if(!enabled)throw new Error('Aviator brevemente.');
    if(!round||round.status!=='OPEN'||round.betting_open===false)throw new Error('Apostas fechadas.');

    const amount=Number($('#aviatorAmount2').value);
    if(!Number.isFinite(amount)||amount<0.5||amount>500){
      throw new Error('Informe um valor entre 0,50 e 500 MZN.');
    }

    const autoRaw=$('#aviatorAutoCashout2').value.trim();
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
      slot:2,
      amount,
      requestKey:betKey2(),
      autoCashoutMultiplier:auto
    });

    setBetResult2(null);
    personalHistory?.invalidate();
    myBet2=r.bet_id;
    myStake2=Number(r.stake);
    myAutoCashout2=Number(r.auto_cashout_multiplier)||null;
    sound?.playBet();
    lastRecoveredRoundId=round.id;
    renderTicket2();
    renderBetConfirmation2();

    $('#aviatorMessage2').textContent=autoTriggered
      ?'Aposta automática confirmada para esta rodada.'
      :'Aposta confirmada. Aguarde a descolagem.';
    renderAutoBetStatus2();
  }catch(error){
    $('#aviatorMessage2').textContent=playerMessage(
      error,
      'Não foi possível confirmar a aposta.'
    );
  }finally{
    if(autoBetSubmittingRoundId2===Number(round?.id)){
      autoBetSubmittingRoundId2=null;
    }
    betting2=false;
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

$('#cashoutBtn2').addEventListener('click',async event=>{
  event.preventDefault();
  if(!cashoutGestureGuard2.shouldAcceptClick(event))return;
  if(!connectionOnline){
    $('#aviatorMessage2').textContent='Sem ligação. Cash-out indisponível até reconectar.';
    return;
  }
  if(cashingOut2||!myBet2||round?.status!=='FLYING')return;

  cashingOut2=true;
  const id=myBet2;
  const cashoutRoundId=Number(round.id);
  const requestKey=cashoutRequestKey(id);
  savePendingCashout2(id,cashoutRoundId,requestKey);
  renderCashoutAction2({
    active:true,
    disabled:true,
    pending:true,
    multiplier:mul(),
    stake:myStake2,
    status:'A confirmar no servidor'
  });

  try{
    const r=await requestFinancialCashout(id,requestKey);

    clearPendingCashout2();
    $('#aviatorMessage2').textContent=cashoutMessage(
      r.source,
      r.multiplier,
      r.payout
    );
    sound?.playCashout();
    setBetResult2({
      status:'CASHED_OUT',
      stake:myStake2,
      payout:Number(r.payout),
      cashout_multiplier:Number(r.multiplier)
    });

    myBet2=null;
    myStake2=0;
    myAutoCashout2=null;
    resetCashout2();
    renderTicket2();
    lastRecoveredRoundId=round?.id??null;
  }catch(error){
    const raw=String(error?.message||'');
    const reconciled=await reconcilePendingCashout2();
    if(reconciled)return;

    const roundEnded=/Crash ja atingido|Aposta ja liquidada|Voo nao esta ativo/i.test(raw);

    if(roundEnded){
      clearPendingCashout2();
      myBet2=null;
      myStake2=0;
      myAutoCashout2=null;
      lastRecoveredRoundId=round?.id??null;
      resetCashout2();
      renderTicket2();
      $('#aviatorMessage2').textContent='Fim da rodada. Cash-out não disponível.';
      clearTimeout(stateTimer);
      await state();
    }else if(!connectionOnline||navigator.onLine===false){
      setConnectionState(false);
      $('#aviatorMessage2').textContent='Sem ligação. A confirmar o cash-out quando reconectar.';
    }else{
      clearPendingCashout2();
      $('#aviatorMessage2').textContent=playerMessage(
        raw,
        'Não foi possível confirmar o cash-out.'
      );
      lastRecoveredRoundId=null;
      await recover(true);
    }
  }finally{
    cashingOut2=false;
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