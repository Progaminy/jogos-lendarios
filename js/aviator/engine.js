(() => {
  'use strict';

  function detectPerformance(win=window, doc=document) {
    const mobileViewport=win.matchMedia?.('(max-width: 650px)').matches===true;
    const coarsePointer=win.matchMedia?.('(pointer: coarse)').matches===true;
    const isMobile=mobileViewport||coarsePointer;
    const memory=Number(win.navigator?.deviceMemory);
    const cores=Number(win.navigator?.hardwareConcurrency);
    const saveData=win.navigator?.connection?.saveData===true;
    const lowPower=
      saveData||
      (Number.isFinite(memory)&&memory<=4)||
      (Number.isFinite(cores)&&cores<=4);

    const profile=Object.freeze({
      isMobile,
      lowPower,
      frameIntervalMs:lowPower?125:isMobile?100:50,
      hudIntervalMs:lowPower?300:isMobile?250:100,
      openClockIntervalMs:lowPower?750:isMobile?500:250
    });

    doc.documentElement?.classList.toggle('aviator-mobile-lite',isMobile);
    doc.documentElement?.classList.toggle('aviator-low-power',lowPower);
    return profile;
  }

  function create({runtime,getRound,win=window,doc=document}) {
    let serverClockOffsetMs=0;
    const performance=detectPerformance(win,doc);

    function syncServerClock(snapshot){
      const server=Date.parse(snapshot?.server_time);
      if(Number.isFinite(server))serverClockOffsetMs=server-Date.now();
    }

    function serverNowMs(){
      return Date.now()+serverClockOffsetMs;
    }

    function multiplier(){
      const round=getRound?.();
      if(round?.status==='FLYING'&&round?.started_at&&runtime?.liveMultiplier){
        return runtime.liveMultiplier(round.started_at,serverNowMs());
      }
      const value=Number(round?.current_multiplier);
      return Number.isFinite(value)&&value>=1?value:1;
    }

    function secondsUntil(field,fallbackField){
      const round=getRound?.();
      if(round?.[field]&&runtime?.secondsUntil){
        return runtime.secondsUntil(round[field],serverNowMs());
      }
      const value=Number(round?.[fallbackField]);
      return Number.isFinite(value)&&value>=0?Math.floor(value):null;
    }

    function pollDelay({status,hidden,realtimeConnected,enabled=true,hasBet=false}){
      const protectedFlight=!enabled&&status==='FLYING'&&hasBet;
      if(!enabled&&!protectedFlight){
        if(realtimeConnected)return hidden?300000:120000;
        return hidden?60000:30000;
      }
      return runtime.pollDelay(status||'',hidden,realtimeConnected);
    }

    return Object.freeze({
      performance,
      syncServerClock,
      serverNowMs,
      multiplier,
      secondsToClose:()=>secondsUntil('betting_closes_at','seconds_to_close'),
      secondsToTakeoff:()=>secondsUntil('takeoff_at','seconds_to_takeoff'),
      pollDelay
    });
  }

  window.JLAviatorEngine=Object.freeze({create,detectPerformance});
})();
