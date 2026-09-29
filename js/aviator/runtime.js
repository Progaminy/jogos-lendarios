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

  function pollDelay(status,hidden){
    if(hidden)return 5000;
    if(status==='FLYING')return 500;
    if(status==='OPEN')return 1000;
    return 1400;
  }

  function phase(status){
    if(status==='OPEN')return 'open';
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
    phase,
    shouldAcceptSnapshot
  });
});
