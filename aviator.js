(()=>{'use strict';
const $=s=>document.querySelector(s);
let round=null,myBet=null,raf=0,offset=0,recovering=false,lastRecoveredRoundId=null,enabled=true;

const playerToken=()=>JLSession.getPlayerToken();

function mul(){
  if(!round?.started_at)return 1;
  const elapsed=Math.max(0,(Date.now()+offset-new Date(round.started_at).getTime())/1000);
  return Math.pow(1.06,elapsed);
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

function stopFlight(){
  if(raf){
    cancelAnimationFrame(raf);
    raf=0;
  }
  $('.flight-area')?.classList.remove('flying');
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

function paint(){
  if(round?.status!=='FLYING'){
    stopFlight();
    return;
  }
  const m=mul();
  renderMultiplier(m);
  const cashout=$('#cashoutBtn');
  if(cashout){
    cashout.textContent=myBet?'Cash-out · '+m.toFixed(2)+'×':'Cash-out';
    cashout.disabled=!myBet;
  }
  $('.flight-area')?.classList.add('flying');
  raf=requestAnimationFrame(paint);
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
    if(myBet&&round.status==='FLYING')$('#aviatorMessage').textContent='Aposta ativa recuperada.';
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
  proof.textContent='Commit: '+round.visual_seed_commit+(round.visual_seed_reveal?' · Seed revelada: '+round.visual_seed_reveal:'');
}

function renderRoundState(){
  const stateEl=$('#roundState');
  if(!stateEl)return;
  if(!enabled){
    stateEl.textContent=round?.status==='FLYING'&&myBet?'MANUTENÇÃO · VOO ATIVO':'MANUTENÇÃO';
    return;
  }
  if(!round){
    stateEl.textContent='AGUARDANDO';
    return;
  }
  stateEl.textContent=round.status==='OPEN'
    ?'APOSTAS ABERTAS'
    :round.status==='FLYING'
      ?'EM VOO'
      :round.status;
}

async function state(){
  try{
    const x=await JLApi.rpc('jl_aviator_public_state');
    offset=new Date(x.server_time).getTime()-Date.now();
    enabled=x.enabled!==false;
    document.body.classList.toggle('aviator-maintenance',!enabled);

    const previousId=round?.id??null;
    round=x.round||null;

    if(previousId!==round?.id){
      myBet=null;
      lastRecoveredRoundId=null;
      stopFlight();
      resetCashout();
    }

    if(round&&playerToken()&&(previousId!==round.id||lastRecoveredRoundId!==round.id)){
      await recover();
    }

    renderRoundState();
    renderProof();

    const betBtn=$('#betBtn');
    if(betBtn)betBtn.disabled=!enabled||!round||round.status!=='OPEN';

    if(!round){
      stopFlight();
      renderMultiplier(1);
      resetCashout();
      $('#crashText')?.classList.add('hidden');
      if(!enabled)$('#aviatorMessage').textContent=x.maintenance_message||'Aviator em manutenção. Volte em breve.';
      return;
    }

    if(round.status==='CRASHED'||round.status==='SETTLED'){
      stopFlight();
      renderMultiplier(round.crash_multiplier||1);
      $('#crashText')?.classList.remove('hidden');
      myBet=null;
      resetCashout();
    }else{
      $('#crashText')?.classList.add('hidden');
      if(round.status==='FLYING'){
        if(!raf)paint();
      }else{
        stopFlight();
        renderMultiplier(1);
        resetCashout();
      }
    }

    if(!enabled){
      const activeFlight=round.status==='FLYING'&&myBet;
      $('#aviatorMessage').textContent=activeFlight
        ?'Manutenção ativada. A sua aposta em voo continua protegida; o cash-out permanece disponível.'
        :(x.maintenance_message||'Aviator em manutenção. Volte em breve.');
    }
  }catch(e){
    $('#aviatorMessage').textContent=e.message;
  }
}

$('#aviatorBetForm').addEventListener('submit',async e=>{
  e.preventDefault();
  try{
    if(!playerToken())throw new Error('Entre na sua conta primeiro.');
    if(!enabled)throw new Error('Aviator em manutenção. Volte em breve.');
    if(!round||round.status!=='OPEN')throw new Error('Apostas fechadas.');
    const r=await JLApi.rpc('jl_aviator_place_bet',{
      p_token:playerToken(),
      p_amount:Number($('#aviatorAmount').value),
      p_request_key:betKey()
    });
    myBet=r.bet_id;
    lastRecoveredRoundId=round.id;
    $('#aviatorMessage').textContent=r.already_processed?'Aposta já confirmada.':'Aposta aceite.';
    await state();
  }catch(e){
    $('#aviatorMessage').textContent=e.message;
  }
});

$('#cashoutBtn').addEventListener('click',async()=>{
  if(!myBet||round?.status!=='FLYING')return;
  const id=myBet;
  $('#cashoutBtn').disabled=true;
  try{
    const r=await JLApi.rpc('jl_aviator_cashout',{p_token:playerToken(),p_bet_id:id});
    $('#aviatorMessage').textContent='Cash-out em '+Number(r.multiplier).toFixed(2)+'× · '+Number(r.payout).toFixed(2)+' MZN';
    myBet=null;
    resetCashout();
  }catch(e){
    $('#aviatorMessage').textContent=e.message;
    lastRecoveredRoundId=null;
    await recover(true);
  }
});

window.addEventListener('online',()=>{
  lastRecoveredRoundId=null;
  state();
});

document.addEventListener('visibilitychange',()=>{
  if(!document.hidden){
    lastRecoveredRoundId=null;
    state();
  }
});

state();
setInterval(state,1000);
})();