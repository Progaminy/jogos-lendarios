(() => {
  'use strict';

  const STORAGE_KEY='jl_aviator_sound_enabled';

  function create({
    button,
    storage=localStorage,
    win=window,
    getRound=()=>null,
    getMultiplier=()=>1
  }={}) {
    let enabled=false;
    let audioCtx=null;
    let lastRoundId=null;
    let lastStatus=null;
    let terminalRoundId=null;
    let countdownRoundId=null;
    let lastCountdownSecond=null;
    let flightVoice=null;

    try{enabled=storage.getItem(STORAGE_KEY)==='1';}catch{}

    function updateButton(){
      if(!button)return;
      button.textContent=enabled?'🔊':'🔇';
      button.setAttribute('aria-pressed',enabled?'true':'false');
      button.setAttribute('aria-label',enabled?'Desativar som do Aviator':'Ativar som do Aviator');
      button.title=enabled?'Desativar som':'Ativar som';
      button.classList.toggle('is-on',enabled);
    }

    function ensureAudio(){
      if(!enabled)return null;
      const AudioCtx=win.AudioContext||win.webkitAudioContext;
      if(!AudioCtx)return null;
      if(!audioCtx)audioCtx=new AudioCtx();
      if(audioCtx.state==='suspended')audioCtx.resume().catch(()=>{});
      return audioCtx;
    }

    function tone(freq,duration=.08,volume=.025,delay=0,type='sine',endFreq=null){
      const ctx=ensureAudio();
      if(!ctx)return;
      const start=ctx.currentTime+Math.max(0,delay);
      const osc=ctx.createOscillator();
      const gain=ctx.createGain();
      osc.type=type;
      osc.frequency.setValueAtTime(Math.max(20,freq),start);
      if(Number.isFinite(Number(endFreq))){
        osc.frequency.exponentialRampToValueAtTime(Math.max(20,Number(endFreq)),start+duration);
      }
      gain.gain.setValueAtTime(.0001,start);
      gain.gain.exponentialRampToValueAtTime(Math.max(.0002,volume),start+.008);
      gain.gain.exponentialRampToValueAtTime(.0001,start+duration);
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start(start);
      osc.stop(start+duration+.03);
    }

    function playEnable(){
      tone(620,.05,.016,0,'sine');
    }

    function playCountdown(second){
      const s=Number(second);
      if(!Number.isFinite(s)||s<0||s>10)return;
      if(s===0){
        tone(1320,.12,.030,0,'square');
        tone(1680,.08,.018,.07,'sine');
        return;
      }
      const urgent=s<=3;
      const freq=urgent?1120:860;
      const duration=urgent?.075:.055;
      const volume=urgent?.026:.019;
      tone(freq,duration,volume,0,'square');
    }

    function syncCountdown(roundId,second){
      if(!enabled)return;
      const id=Number(roundId);
      const s=Number(second);
      if(!Number.isFinite(id)||!Number.isFinite(s)||s<0||s>10)return;
      const whole=Math.max(0,Math.min(10,Math.floor(s)));
      if(countdownRoundId!==id){
        countdownRoundId=id;
        lastCountdownSecond=null;
      }
      if(lastCountdownSecond===whole)return;
      lastCountdownSecond=whole;
      playCountdown(whole);
    }

    function stopFlight(){
      const voice=flightVoice;
      flightVoice=null;
      if(!voice)return;
      const ctx=audioCtx;
      try{
        const now=ctx?.currentTime||0;
        voice.gain.gain.cancelScheduledValues(now);
        voice.gain.gain.setTargetAtTime(.0001,now,.035);
        voice.osc.stop(now+.16);
        voice.air.stop(now+.16);
      }catch(_){}
    }

    function startFlight(){
      if(!enabled||flightVoice)return;
      const ctx=ensureAudio();
      if(!ctx)return;

      const osc=ctx.createOscillator();
      const air=ctx.createOscillator();
      const gain=ctx.createGain();
      const airGain=ctx.createGain();

      osc.type='sawtooth';
      air.type='triangle';
      osc.frequency.setValueAtTime(118,ctx.currentTime);
      air.frequency.setValueAtTime(238,ctx.currentTime);

      gain.gain.setValueAtTime(.0001,ctx.currentTime);
      gain.gain.exponentialRampToValueAtTime(.018,ctx.currentTime+.18);
      airGain.gain.setValueAtTime(.0001,ctx.currentTime);
      airGain.gain.exponentialRampToValueAtTime(.006,ctx.currentTime+.22);

      osc.connect(gain);
      air.connect(airGain);
      gain.connect(ctx.destination);
      airGain.connect(ctx.destination);
      osc.start();
      air.start();

      flightVoice={osc,air,gain,airGain};
      updateFlight(getMultiplier?.());
    }

    function updateFlight(multiplier){
      if(!enabled)return;
      if(!flightVoice)startFlight();
      if(!flightVoice||!audioCtx)return;

      const m=Math.max(1,Math.min(500,Number(multiplier)||1));
      const progress=Math.log(m)/Math.log(500);
      const now=audioCtx.currentTime;
      const base=118+(progress*250);
      const overtone=238+(progress*520);
      const volume=.018+(progress*.012);

      try{
        flightVoice.osc.frequency.setTargetAtTime(base,now,.09);
        flightVoice.air.frequency.setTargetAtTime(overtone,now,.11);
        flightVoice.gain.gain.setTargetAtTime(volume,now,.10);
        flightVoice.airGain.gain.setTargetAtTime(.006+(progress*.005),now,.12);
      }catch(_){}
    }

    function playCrash(){
      stopFlight();
      tone(210,.22,.045,0,'sawtooth',58);
      tone(92,.32,.038,.03,'square',34);
      tone(420,.08,.018,.02,'triangle',120);
    }

    function setEnabled(next){
      enabled=Boolean(next);
      try{storage.setItem(STORAGE_KEY,enabled?'1':'0');}catch{}
      updateButton();

      if(!enabled){
        stopFlight();
        return enabled;
      }

      ensureAudio();
      playEnable();

      const current=getRound?.();
      if(String(current?.status||'').toUpperCase()==='FLYING'){
        startFlight();
        updateFlight(getMultiplier?.());
      }
      return enabled;
    }

    function toggle(){return setEnabled(!enabled);}

    function syncRound(round){
      if(!round?.id||!round?.status)return;
      const roundId=Number(round.id);
      const status=String(round.status).toUpperCase();

      if(lastRoundId===roundId&&lastStatus===status){
        if(enabled&&status==='FLYING'&&!flightVoice)startFlight();
        return;
      }

      const previousStatus=lastStatus;
      lastRoundId=roundId;
      lastStatus=status;

      if(status!=='FLYING'&&previousStatus==='FLYING')stopFlight();

      if(!enabled)return;

      if(status==='FLYING'){
        terminalRoundId=null;
        startFlight();
        updateFlight(getMultiplier?.());
        return;
      }

      if((status==='CRASHED'||status==='SETTLED')&&terminalRoundId!==roundId){
        terminalRoundId=roundId;
        playCrash();
      }
    }

    function unlock(){
      if(enabled)ensureAudio();
    }

    function destroy(){
      stopFlight();
      try{audioCtx?.close?.()}catch(_){}
      audioCtx=null;
    }

    button?.addEventListener('click',toggle);
    win.addEventListener?.('pointerdown',unlock,{once:true,passive:true});
    win.addEventListener?.('keydown',unlock,{once:true});
    updateButton();

    return Object.freeze({
      isEnabled:()=>enabled,
      setEnabled,
      toggle,
      syncRound,
      syncCountdown,
      updateFlight,
      stopFlight,
      updateButton,
      destroy
    });
  }

  window.JLAviatorSound=Object.freeze({create,STORAGE_KEY});
})();
