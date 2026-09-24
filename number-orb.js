(() => {
  'use strict';

  const single=document.getElementById('lotteryNumberOrb');
  const pairA=document.getElementById('lotteryPairOrbA');
  const pairB=document.getElementById('lotteryPairOrbB');
  if(!single||!pairA||!pairB)return;

  let singleValue=0;
  let pairValueA=0;
  let pairValueB=1;
  let timer=null;

  function randomDifferent(current,avoid=null){
    let next;
    do{next=Math.floor(Math.random()*11);}while(next===current||next===avoid);
    return next;
  }

  function changeOrb(orb,value){
    orb.classList.add('is-changing');
    setTimeout(()=>{
      orb.textContent=String(value);
      orb.classList.remove('is-changing');
    },90);
  }

  function tick(){
    singleValue=randomDifferent(singleValue);
    pairValueA=randomDifferent(pairValueA,pairValueB);
    pairValueB=randomDifferent(pairValueB,pairValueA);

    changeOrb(single,singleValue);
    changeOrb(pairA,pairValueA);
    changeOrb(pairB,pairValueB);
  }

  function start(){
    clearInterval(timer);
    timer=setInterval(()=>{
      if(document.visibilityState==='visible')tick();
    },700);
  }

  document.addEventListener('visibilitychange',()=>{
    if(document.visibilityState==='visible')start();
    else clearInterval(timer);
  });

  start();
})();