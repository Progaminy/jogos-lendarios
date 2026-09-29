(()=>{'use strict';

const $=s=>document.querySelector(s);

let round=null;
let myBet=null;
let raf=0;
let offset=0;
let recovering=false;
let lastRecoveredRoundId=null;
let enabled=true;
let stateBusy=false;
let stateTimer=0;
let betting=false;
let cashingOut=false;

const playerToken=()=>JLSession.getPlayerToken();
const serverNow=()=>Date.now()+offset;
const runtime=window.JLAviatorRuntime||{
  multiplier:(start,now)=>Math.pow(1.06,Math.max(0,(now-start)/1000)),
  secondsUntil:(close,now)=>Math.max(0,Math.ceil((close-now)/1000)),
  pollDelay:(status,hidden)=>hidden?5000:status==='FLYING'?700:status==='OPEN'?1000:1400
};

function show(selector,visible){
  const el=typeof selector==='string'?$(selector):selector;
  if(el)el.classList.toggle('hidden',!visible);
}

function mul(){
  if(!round?.started_at)return 1;
  return runtime.multiplier(new Date(round.started_at).getTime(),serverNow());
}

function secondsToClose(){
  if(!round?.betting_closes_at)return null;
  return runtime.secondsUntil(new Date(round.betting_closes_at).getTime(),serverNow());
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
  stage.classList.remove('is-open','is-flying','is-crashed','is-waiting');
  stage.classList.add('is-'+phase);
}

function stopFlight(){
  if(raf){
    cancelAnimationFrame(raf);
    raf=0;
  }
}

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

function paintFlight(){
  raf=0;
  if(round?.status!=='FLYING')return;

  const m=mul();
  renderMultiplier(m);

  const cashout=$('#cashoutBtn');
  if(cashout){
    cashout.textContent=myBet?'Cash-out · '+m.toFixed(2)+'×':'Cash-out';
    cashout.disabled=!myBet||cashingOut;
  }

  raf=requestAnimationFrame(paintFlight);
}

function startFlightPaint(){
  if(!raf)raf=requestAnimationFrame(paintFlight);
}

async function recover(force=false){
  if(recovering||!playerToken()||!round)return;
  if(!force&&lastRecoveredRoundId===round.id)return;

  recovering=true;
  try{
    const x=await JLApi.rpc('jl_aviator_player_state',{p_token:playerToken()});
    const bets=Array.isArray(x.bets)?x.bets:[];
    const active=bets.filter(b=>Number(b.round_id)===Number(round.id)&&b.status==='ACTIVE');
    myBet=active.length?active[active.length-1].id:null;
    lastRecoveredRoundId=round.id;

    if(myBet&&round.status==='FLYING'){
      $('#aviatorMessage').textContent='Aposta ativa recuperada.';
    }
  }catch(_){
    lastRecoveredRoundId=null;
  }finally{
    recovering=false;
  }
}

function renderProof(){
  const wrap=$('#proofWrap');
  const proof=$('#proof');
  if(!wrap||!proof)return;

  if(!round?.visual_seed_commit){
    wrap.hidden=true;
    proof.textContent='';
    return;
  }

  wrap.hidden=false;
  proof.textContent='Commit: '+round.visual_seed_commit+
    (round.visual_seed_reveal?' · Seed revelada: '+round.visual_seed_reveal:'');
}

function renderMaintenanceView(){
  const protectedFlight=!enabled&&round?.status==='FLYING'&&Boolean(myBet);
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

  const seconds=secondsToClose();
  const display=seconds===null?'—':String(seconds);

  $('#roundState').textContent='APOSTAS ABERTAS';
  $('#clockLabel').textContent='FECHA EM';
  $('#roundCountdown').textContent=seconds===null?'—':display+'s';
  $('#preflightCountdown').textContent=display;

  show('#preflight',true);
  show('#multiplierWrap',false);
  show('#crashText',false);

  const betBtn=$('#betBtn');
  if(betBtn){
    betBtn.disabled=!enabled||Boolean(myBet)||betting||seconds===0;
    betBtn.textContent=myBet?'Aposta confirmada':seconds===0?'Apostas fechando':'Apostar';
  }

  resetCashout();

  if(myBet&&!$('#aviatorMessage').textContent.trim()){
    $('#aviatorMessage').textContent='Aposta confirmada. Aguarde a descolagem.';
  }
}

function renderFlying(){
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
    cashout.disabled=!myBet||cashingOut;
  }

  startFlightPaint();
}

function renderFinished(){
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

  const betBtn=$('#betBtn');
  if(betBtn){
    betBtn.disabled=true;
    betBtn.textContent='Aguarde';
  }

  myBet=null;
  resetCashout();
}

function renderWaiting(){
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
  return runtime.pollDelay(round?.status||'',document.hidden);
}

function scheduleState(delay=nextPollDelay()){
  clearTimeout(stateTimer);
  stateTimer=setTimeout(state,delay);
}

async function state(){
  if(stateBusy)return;
  stateBusy=true;

  try{
    const x=await JLApi.rpc('jl_aviator_public_state');
    offset=new Date(x.server_time).getTime()-Date.now();
    enabled=x.enabled!==false;

    const previousId=round?.id??null;
    round=x.round||null;

    if(previousId!==round?.id){
      myBet=null;
      lastRecoveredRoundId=null;
      stopFlight();
      resetCashout();
      const message=$('#aviatorMessage');
      if(message&&!/Cash-out em/i.test(message.textContent))message.textContent='';
    }

    if(round&&playerToken()&&(previousId!==round.id||lastRecoveredRoundId!==round.id)){
      await recover();
    }

    if(renderMaintenanceView()){
      stopFlight();
      resetCashout();
      return;
    }

    renderCurrentRound();

    if(!enabled&&round?.status==='FLYING'&&myBet){
      $('#aviatorMessage').textContent='Manutenção ativada. A sua aposta em voo continua protegida; o cash-out permanece disponível.';
    }
  }catch(e){
    const message=$('#aviatorMessage');
    if(message)message.textContent=e.message;
  }finally{
    stateBusy=false;
    scheduleState();
  }
}

$('#aviatorBetForm').addEventListener('submit',async e=>{
  e.preventDefault();
  if(betting)return;

  betting=true;
  const button=$('#betBtn');
  if(button)button.disabled=true;

  try{
    if(!playerToken())throw new Error('Entre na sua conta primeiro.');
    if(!enabled)throw new Error('Aviator brevemente');
    if(!round||round.status!=='OPEN')throw new Error('Apostas fechadas.');

    const amount=Number($('#aviatorAmount').value);
    if(!Number.isFinite(amount)||amount<1)throw new Error('Informe um valor válido.');

    const r=await JLApi.rpc('jl_aviator_place_bet',{
      p_token:playerToken(),
      p_amount:amount,
      p_request_key:betKey()
    });

    myBet=r.bet_id;
    lastRecoveredRoundId=round.id;
    $('#aviatorMessage').textContent=r.already_processed
      ?'Aposta já confirmada. Aguarde a descolagem.'
      :'Aposta confirmada. Aguarde a descolagem.';
  }catch(e){
    $('#aviatorMessage').textContent=e.message;
  }finally{
    betting=false;
    renderCurrentRound();
  }
});

$('#cashoutBtn').addEventListener('click',async()=>{
  if(cashingOut||!myBet||round?.status!=='FLYING')return;

  cashingOut=true;
  const id=myBet;
  const button=$('#cashoutBtn');
  if(button)button.disabled=true;

  try{
    const r=await JLApi.rpc('jl_aviator_cashout',{
      p_token:playerToken(),
      p_bet_id:id
    });

    $('#aviatorMessage').textContent=
      'Cash-out em '+Number(r.multiplier).toFixed(2)+'× · '+Number(r.payout).toFixed(2)+' MZN';

    myBet=null;
    resetCashout();
    lastRecoveredRoundId=round?.id??null;
  }catch(e){
    $('#aviatorMessage').textContent=e.message;
    lastRecoveredRoundId=null;
    await recover(true);
  }finally{
    cashingOut=false;
    renderMaintenanceView();
    renderCurrentRound();
  }
});

window.addEventListener('online',()=>{
  lastRecoveredRoundId=null;
  clearTimeout(stateTimer);
  state();
});

document.addEventListener('visibilitychange',()=>{
  clearTimeout(stateTimer);
  if(!document.hidden){
    lastRecoveredRoundId=null;
    state();
  }else{
    scheduleState(5000);
  }
});

state();
})();