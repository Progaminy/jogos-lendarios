(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports){
    module.exports=api;
  }else{
    root.JLAviatorRuntime=api;
  }
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';

  function multiplier(startedAtMs,atMs){
    const start=Number(startedAtMs);
    const now=Number(atMs);
    if(!Number.isFinite(start)||!Number.isFinite(now))return 1;
    const elapsed=Math.max(0,(now-start)/1000);
    return Math.pow(1.06,elapsed);
  }

  function secondsUntil(closeAtMs,atMs){
    const close=Number(closeAtMs);
    const now=Number(atMs);
    if(!Number.isFinite(close)||!Number.isFinite(now))return null;
    return Math.max(0,Math.ceil((close-now)/1000));
  }

  function clockSample(serverTimeMs,requestStartedMs,responseReceivedMs){
    const server=Number(serverTimeMs);
    const started=Number(requestStartedMs);
    const received=Number(responseReceivedMs);
    if(!Number.isFinite(server)||!Number.isFinite(started)||!Number.isFinite(received)||received<started){
      return null;
    }
    const rtt=received-started;
    const midpoint=started+(rtt/2);
    return Object.freeze({
      offset:server-midpoint,
      rtt
    });
  }

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

  function pollDelay(status,hidden){
    if(hidden)return 5000;
    if(status==='FLYING')return 700;
    if(status==='OPEN')return 1000;
    return 1400;
  }

  function phase(status){
    if(status==='OPEN')return 'open';
    if(status==='FLYING')return 'flying';
    if(status==='CRASHED'||status==='SETTLED')return 'crashed';
    return 'waiting';
  }

  return Object.freeze({multiplier,secondsUntil,clockSample,pickActiveBet,findBetById,pollDelay,phase});
});
