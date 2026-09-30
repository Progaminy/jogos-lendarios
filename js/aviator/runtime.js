(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports){
    module.exports=api;
  }else{
    root.JLAviatorRuntime=api;
  }
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';

  function pickActiveBet(bets,roundId){
    const target=Number(roundId);
    if(!Array.isArray(bets)||!Number.isFinite(target))return null;

    let selected=null;
    for(const bet of bets){
      if(Number(bet?.round_id)!==target||bet?.status!=='ACTIVE')continue;
      if(!selected||Number(bet?.id)>Number(selected?.id))selected=bet;
    }
    return selected;
  }

  function findBetById(bets,betId){
    const target=Number(betId);
    if(!Array.isArray(bets)||!Number.isFinite(target))return null;
    return bets.find((bet)=>Number(bet?.id)===target)||null;
  }

  function pollDelay(status,hidden,realtimeConnected=false){
    if(realtimeConnected)return hidden?60000:30000;
    if(hidden)return 15000;
    if(status==='FLYING'||status==='LOCKED')return 2000;
    if(status==='OPEN')return 5000;
    return 10000;
  }

  function liveMultiplier(startedAt,serverNowMs){
    const start=Date.parse(startedAt);
    const now=Number(serverNowMs);
    if(!Number.isFinite(start)||!Number.isFinite(now))return 1;
    const seconds=Math.max(0,(now-start)/1000);
    return Math.max(1,Math.pow(1.06,seconds));
  }

  function secondsUntil(isoTime,serverNowMs){
    const target=Date.parse(isoTime);
    const now=Number(serverNowMs);
    if(!Number.isFinite(target)||!Number.isFinite(now))return null;
    return Math.max(0,Math.ceil((target-now)/1000));
  }

  function phase(status){
    if(status==='OPEN')return 'open';
    if(status==='LOCKED')return 'locked';
    if(status==='FLYING')return 'flying';
    if(status==='CRASHED'||status==='SETTLED')return 'crashed';
    return 'waiting';
  }

  function shouldAcceptSnapshot(previousSeq,nextSeq){
    const next=Number(nextSeq);
    if(!Number.isFinite(next))return false;
    const previous=Number(previousSeq);
    if(!Number.isFinite(previous))return true;
    return next>=previous;
  }

  return Object.freeze({
    pickActiveBet,
    findBetById,
    pollDelay,
    liveMultiplier,
    secondsUntil,
    phase,
    shouldAcceptSnapshot
  });
});
