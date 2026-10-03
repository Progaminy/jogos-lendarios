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
    let initialized=false;
    let lastRoundId=null;
    let lastStatus=null;
    let terminalRoundId=null;
    let countdownRoundId=null;
    let lastCountdownSecond=null;
    let flightVoice=null;
    let masterGain=null;
    let masterCompressor=null;

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
      if(!audioCtx){
        audioCtx=new AudioCtx();
        masterGain=audioCtx.createGain();
        masterCompressor=audioCtx.createDynamicsCompressor();
        masterGain.gain.setValueAtTime(.74,audioCtx.currentTime);
        masterCompressor.threshold.setValueAtTime(-18,audioCtx.currentTime);
        masterCompressor.knee.setValueAtTime(18,audioCtx.currentTime);
        masterCompressor.ratio.setValueAtTime(2.4,audioCtx.currentTime);
        masterCompressor.attack.setValueAtTime(.008,audioCtx.currentTime);
        masterCompressor.release.setValueAtTime(.20,audioCtx.currentTime);
        masterGain.connect(masterCompressor);
        masterCompressor.connect(audioCtx.destination);
      }
      return audioCtx;
    }

    function audioRunning(){
      return audioCtx?.state==='running';
    }

    async function activateAudio(){
      if(!enabled)return false;
      const ctx=ensureAudio();
      if(!ctx)return false;

      if(ctx.state!=='running'){
        try{await ctx.resume()}catch(_){}
      }

      if(ctx.state!=='running')return false;

      const current=getRound?.();
      if(String(current?.status||'').toUpperCase()==='FLYING'){
        startFlight();
        updateFlight(getMultiplier?.());
      }
      return true;
    }

    function tone(freq,duration=.08,volume=.025,delay=0,type='sine',endFreq=null){
      const ctx=ensureAudio();
      if(!ctx)return;
      const start=ctx.currentTime+Math.max(0,delay);
      const osc=ctx.createOscillator();
      const gain=ctx.createGain();
      const filter=ctx.createBiquadFilter();
      filter.type='lowpass';
      filter.frequency.setValueAtTime(2200,start);
      filter.Q.setValueAtTime(.55,start);
      osc.type=type;
      osc.frequency.setValueAtTime(Math.max(20,freq),start);
      if(Number.isFinite(Number(endFreq))){
        osc.frequency.exponentialRampToValueAtTime(Math.max(20,Number(endFreq)),start+duration);
      }
      gain.gain.setValueAtTime(.0001,start);
      gain.gain.exponentialRampToValueAtTime(Math.max(.0002,volume),start+.008);
      gain.gain.exponentialRampToValueAtTime(.0001,start+duration);
      osc.connect(filter);
      filter.connect(gain);
      gain.connect(masterGain||ctx.destination);
      osc.start(start);
      osc.stop(start+duration+.03);
    }

    function playCountdown(second){
      const s=Number(second);
      if(!Number.isFinite(s)||s<0||s>10)return;
      if(s===0){
        tone(780,.11,.055,0,'sine');
        tone(980,.10,.032,.055,'triangle');
        return;
      }
      const urgent=s<=3;
      const freq=urgent?720:580;
      const duration=urgent?0.085:0.06;
      const volume=urgent?0.048:0.036;
      tone(freq,duration,volume,0,'sine');
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
        voice.gain.gain.setTargetAtTime(.0001,now,.055);
        voice.airGain.gain.cancelScheduledValues(now);
        voice.airGain.gain.setTargetAtTime(.0001,now,.06);
        voice.shimmerGain.gain.cancelScheduledValues(now);
        voice.shimmerGain.gain.setTargetAtTime(.0001,now,.06);
        voice.osc.stop(now+.20);
        voice.air.stop(now+.20);
        voice.shimmer.stop(now+.20);
      }catch(_){}
    }

    function startFlight(){
      if(!enabled||flightVoice)return;
      const ctx=ensureAudio();
      if(!ctx||ctx.state!=='running')return;

      const osc=ctx.createOscillator();
      const air=ctx.createOscillator();
      const shimmer=ctx.createOscillator();
      const gain=ctx.createGain();
      const airGain=ctx.createGain();
      const shimmerGain=ctx.createGain();
      const filter=ctx.createBiquadFilter();
      const airFilter=ctx.createBiquadFilter();
      const shimmerFilter=ctx.createBiquadFilter();
      const panner=typeof ctx.createStereoPanner==='function'?ctx.createStereoPanner():null;
      const shimmerPanner=typeof ctx.createStereoPanner==='function'?ctx.createStereoPanner():null;

      osc.type='triangle';
      air.type='sine';
      shimmer.type='sine';

      osc.frequency.setValueAtTime(108,ctx.currentTime);
      air.frequency.setValueAtTime(216,ctx.currentTime);
      shimmer.frequency.setValueAtTime(432,ctx.currentTime);

      osc.detune.setValueAtTime(-2,ctx.currentTime);
      air.detune.setValueAtTime(3,ctx.currentTime);
      shimmer.detune.setValueAtTime(5,ctx.currentTime);

      filter.type='lowpass';
      filter.frequency.setValueAtTime(1100,ctx.currentTime);
      filter.Q.setValueAtTime(.62,ctx.currentTime);
      airFilter.type='lowpass';
      airFilter.frequency.setValueAtTime(1700,ctx.currentTime);
      airFilter.Q.setValueAtTime(.46,ctx.currentTime);
      shimmerFilter.type='lowpass';
      shimmerFilter.frequency.setValueAtTime(2800,ctx.currentTime);
      shimmerFilter.Q.setValueAtTime(.4,ctx.currentTime);

      gain.gain.setValueAtTime(.0001,ctx.currentTime);
      gain.gain.exponentialRampToValueAtTime(.038,ctx.currentTime+.42);
      airGain.gain.setValueAtTime(.0001,ctx.currentTime);
      airGain.gain.exponentialRampToValueAtTime(.016,ctx.currentTime+.48);
      shimmerGain.gain.setValueAtTime(.0001,ctx.currentTime);
      shimmerGain.gain.exponentialRampToValueAtTime(.007,ctx.currentTime+.64);

      if(panner)panner.pan.setValueAtTime(-.04,ctx.currentTime);

      osc.connect(filter);
      filter.connect(gain);
      air.connect(airFilter);
      airFilter.connect(airGain);
      shimmer.connect(shimmerFilter);
      shimmerFilter.connect(shimmerGain);

      if(panner){
        gain.connect(panner);
        airGain.connect(panner);
        panner.connect(masterGain||ctx.destination);
      }else{
        gain.connect(masterGain||ctx.destination);
        airGain.connect(masterGain||ctx.destination);
      }

      if(shimmerPanner){
        shimmerPanner.pan.setValueAtTime(.35,ctx.currentTime);
        shimmerGain.connect(shimmerPanner);
        shimmerPanner.connect(masterGain||ctx.destination);
      }else{
        shimmerGain.connect(masterGain||ctx.destination);
      }

      osc.start();
      air.start();
      shimmer.start();

      flightVoice={
        osc,air,shimmer,
        gain,airGain,shimmerGain,
        filter,airFilter,shimmerFilter,
        panner,shimmerPanner
      };
      updateFlight(getMultiplier?.());
    }

    function updateFlight(multiplier){
      if(!enabled)return;
      if(!flightVoice)startFlight();
      if(!flightVoice||!audioCtx)return;

      const m=Math.max(1,Math.min(500,Number(multiplier)||1));
      const progress=Math.log(m)/Math.log(500);
      const now=audioCtx.currentTime;
      const base=108+(progress*112);
      const overtone=216+(progress*224);
      const shimmer=432+(progress*310);
      const volume=.038+(progress*.018);

      try{
        flightVoice.osc.frequency.setTargetAtTime(base,now,.24);
        flightVoice.air.frequency.setTargetAtTime(overtone,now,.28);
        flightVoice.shimmer.frequency.setTargetAtTime(shimmer,now,.32);
        flightVoice.gain.gain.setTargetAtTime(volume,now,.26);
        flightVoice.airGain.gain.setTargetAtTime(.016+(progress*.008),now,.30);
        flightVoice.shimmerGain.gain.setTargetAtTime(.007+(progress*.006),now,.34);
        flightVoice.filter.frequency.setTargetAtTime(1100+(progress*800),now,.30);
        flightVoice.airFilter.frequency.setTargetAtTime(1700+(progress*950),now,.32);
        flightVoice.shimmerFilter.frequency.setTargetAtTime(2800+(progress*1200),now,.36);
      }catch(_){}
    }

    function playCrash(){
      stopFlight();
      tone(300,.14,.064,0,'triangle',165);
      tone(170,.22,.045,.018,'sine',95);
      tone(520,.055,.022,.008,'sine',330);
    }

    function setEnabled(next){
      enabled=Boolean(next);
      try{storage.setItem(STORAGE_KEY,enabled?'1':'0');}catch{}
      updateButton();

      if(!enabled){
        stopFlight();
        return enabled;
      }

      void activateAudio();
      return enabled;
    }

    function toggle(){return setEnabled(!enabled);}

    async function handleButtonClick(event){
      if(enabled&&!audioRunning()){
        event?.preventDefault?.();
        await activateAudio();
        return enabled;
      }
      return toggle();
    }

    function syncRound(round){
      if(!round?.id||!round?.status)return;
      const roundId=Number(round.id);
      const status=String(round.status).toUpperCase();

      if(!initialized){
        initialized=true;
        lastRoundId=roundId;
        lastStatus=status;
        if(status==='CRASHED'||status==='SETTLED')terminalRoundId=roundId;
        if(enabled&&status==='FLYING'){
          startFlight();
          updateFlight(getMultiplier?.());
        }
        return;
      }

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

    function unlock(event){
      if(button&&event?.target&&button.contains?.(event.target))return;
      if(enabled)void activateAudio();
    }

    function destroy(){
      stopFlight();
      try{audioCtx?.close?.()}catch(_){}
      audioCtx=null;
      masterGain=null;
      masterCompressor=null;
    }

    button?.addEventListener('click',handleButtonClick);
    win.addEventListener?.('pointerdown',unlock,{passive:true});
    win.addEventListener?.('keydown',unlock);
    updateButton();

    return Object.freeze({
      isEnabled:()=>enabled,
      setEnabled,
      toggle,
      activateAudio,
      audioRunning,
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
