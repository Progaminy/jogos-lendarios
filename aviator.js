(()=>{'use strict';

const $=s=>document.querySelector(s);

let round=null;
let myBet=null;
let myStake=0;
let raf=0;
let offset=0;
let recovering=false;
let lastRecoveredRoundId=null;
let enabled=true;
let stateBusy=false;
let stateTimer=0;
let betting=false;
let cashingOut=false;
let openUiTimer=0;
let recentResults=[];
let historyBusy=false;
let historyRemoteLoaded=false;
let historyRetryAt=0;

const playerToken=()=>JLSession.getPlayerToken();
const serverNow=()=>Date.now()+offset;
const runtime=window.JLAviatorRuntime||{
  multiplier:(start,now)=>Math.pow(1.06,Math.max(0,(now-start)/1000)),
  secondsUntil:(close,now)=>Math.max(0,Math.ceil((close-now)/1000)),
  pollDelay:(status,hidden)=>hidden?5000:status==='FLYING'?700:status==='OPEN'?1000:1400
};

function money(value){
  const n=Number(value);
  return (Number.isFinite(n)?n:0).toLocaleString('pt-MZ',{
    minimumFractionDigits:2,
    maximumFractionDigits:2
  })+' MZN';
}

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

function stopOpenUiTick(){
  if(openUiTimer){
    clearInterval(openUiTimer);
    openUiTimer=0;
  }
}

function updateOpenClock(){
  if(round?.status!=='OPEN'){
    stopOpenUiTick();
    return;
  }

  const seconds=secondsToClose();
  const display=seconds===null?'—':String(seconds);
  const closed=seconds===0;

  $('#roundState').textContent=closed?'APOSTAS FECHADAS':'APOSTAS ABERTAS';
  $('#clockLabel').textContent=closed?'DESCOLAGEM':'FECHA EM';
  $('#roundCountdown').textContent=closed?'AGUARDE':seconds===null?'—':display+'s';
  $('#preflightCountdown').textContent=display;

  const betBtn=$('#betBtn');
  if(betBtn){
    betBtn.disabled=!enabled||Boolean(myBet)||betting||closed;
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

  wrap.innerHTML=rows.map(item=>
    '<div class="aviator-history-chip" title="Rodada #'+item.id+'">'+
      '<strong>'+item.crash_multiplier.toFixed(2)+'×</strong>'+
      '<small>#'+item.id+'</small>'+
    '</div>'
  ).join('');

  status.textContent=historyRemoteLoaded?'Atualizado':'Nesta sessão';
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
  raf=0;
  if(round?.status!=='FLYING')return;

  const m=mul();
  renderMultiplier(m);
  renderTicket(m);

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
    const active=bets.filter(b=>
      Number(b.round_id)===Number(round.id)&&b.status==='ACTIVE'
    );
    const current=active.length?active[active.length-1]:null;

    myBet=current?.id??null;
    myStake=current?Number(current.stake)||0:0;
    lastRecoveredRoundId=round.id;
    renderTicket();

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
  updateOpenClock();
  startOpenUiTick();

  show('#preflight',true);
  show('#multiplierWrap',false);
  show('#crashText',false);

  resetCashout();
  renderTicket();

  if(myBet&&!$('#aviatorMessage').textContent.trim()){
    $('#aviatorMessage').textContent='Aposta confirmada. Aguarde a descolagem.';
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
    cashout.disabled=!myBet||cashingOut;
  }

  renderTicket(mul());
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

  const betBtn=$('#betBtn');
  if(betBtn){
    betBtn.disabled=true;
    betBtn.textContent='Aguarde';
  }

  myBet=null;
  myStake=0;
  resetCashout();
  renderTicket();
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
    const previousStatus=round?.status??null;
    round=x.round||null;

    const changedRound=previousId!==round?.id;
    const justFinished=
      previousStatus!==round?.status&&
      ['CRASHED','SETTLED'].includes(round?.status);

    if(changedRound){
      myBet=null;
      myStake=0;
      lastRecoveredRoundId=null;
      stopFlight();
      resetCashout();
      renderTicket();
      const message=$('#aviatorMessage');
      if(message)message.textContent='';
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

    if(!enabled&&round?.status==='FLYING'&&myBet){
      $('#aviatorMessage').textContent=
        'Manutenção ativada. A sua aposta em voo continua protegida; o cash-out permanece disponível.';
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
    if(!Number.isFinite(amount)||amount<1){
      throw new Error('Informe um valor válido a partir de 1 MZN.');
    }

    const r=await JLApi.rpc('jl_aviator_place_bet',{
      p_token:playerToken(),
      p_amount:amount,
      p_request_key:betKey()
    });

    myBet=r.bet_id;
    myStake=Number(r.stake)||amount;
    lastRecoveredRoundId=round.id;
    renderTicket();

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
  if(button){
    button.disabled=true;
    button.textContent='Confirmando cash-out…';
  }

  try{
    const r=await JLApi.rpc('jl_aviator_cashout',{
      p_token:playerToken(),
      p_bet_id:id
    });

    $('#aviatorMessage').textContent=
      'Cash-out em '+Number(r.multiplier).toFixed(2)+'× · '+money(r.payout);

    myBet=null;
    myStake=0;
    resetCashout();
    renderTicket();
    lastRecoveredRoundId=round?.id??null;
  }catch(e){
    const raw=String(e?.message||'');
    const roundEnded=/Crash ja atingido|Aposta ja liquidada|Voo nao esta ativo/i.test(raw);

    if(roundEnded){
      myBet=null;
      myStake=0;
      lastRecoveredRoundId=round?.id??null;
      resetCashout();
      renderTicket();
      $('#aviatorMessage').textContent='Fim da rodada. Cash-out não disponível.';
      clearTimeout(stateTimer);
      await state();
    }else{
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

window.addEventListener('online',()=>{
  lastRecoveredRoundId=null;
  historyRetryAt=0;
  historyRemoteLoaded=false;
  clearTimeout(stateTimer);
  void loadHistory(true);
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

renderHistory();
state();
})();