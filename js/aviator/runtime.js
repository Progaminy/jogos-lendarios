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

  return Object.freeze({multiplier,secondsUntil,pollDelay,phase});
});
