(() => {
  'use strict';
  const orb=document.getElementById('lotteryNumberOrb');
  if(!orb)return;

  let current=0;
  let timer=null;

  function tick(){
    let next;
    do{next=Math.floor(Math.random()*11);}while(next===current);
    current=next;
    orb.classList.add('is-changing');
    setTimeout(()=>{
      orb.textContent=String(current);
      orb.classList.remove('is-changing');
    },90);
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