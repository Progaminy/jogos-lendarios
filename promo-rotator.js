(() => {
  'use strict';
  const root=document.getElementById('heroPromo');
  const dots=document.getElementById('heroPromoDots');
  if(!root||!dots)return;

  const slides=[...root.querySelectorAll('.hero-promo-slide')];
  if(slides.length<2)return;

  let current=0;
  let timer=null;
  let paused=false;

  const buttons=slides.map((slide,i)=>{
    const b=document.createElement('button');
    b.type='button';
    b.setAttribute('aria-label','Publicidade '+(i+1));
    b.addEventListener('click',()=>{show(i);restart();});
    dots.appendChild(b);
    return b;
  });

  function show(i){
    current=(i+slides.length)%slides.length;
    slides.forEach((s,n)=>s.classList.toggle('active',n===current));
    buttons.forEach((b,n)=>b.classList.toggle('active',n===current));
  }

  function next(){if(!paused)show(current+1);}
  function restart(){
    clearInterval(timer);
    timer=setInterval(next,4000);
  }

  root.addEventListener('mouseenter',()=>{paused=true;});
  root.addEventListener('mouseleave',()=>{paused=false;});
  root.addEventListener('focusin',()=>{paused=true;});
  root.addEventListener('focusout',()=>{paused=false;});
  document.addEventListener('visibilitychange',()=>{
    if(document.visibilityState==='visible')restart();
    else clearInterval(timer);
  });

  show(0);
  restart();
})();