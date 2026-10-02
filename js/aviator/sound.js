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
        masterGain.gain.setValueAtTime(.78,audioCtx.currentTime);
        masterCompressor.threshold.setValueAtTime(-18,audioCtx.currentTime);
        masterCompressor.knee.setValueAtTime(18,audioCtx.currentTime);
        masterCompressor.ratio.setValueAtTime(2.4,audioCtx.currentTime);
        masterCompressor.attack.setValueAtTime(.008,audioCtx.currentTime);
        masterCompressor.release.setValueAtTime(.20,audioCtx.currentTime);
        masterGain.connect(masterCompressor);
        masterCompressor.connect(audioCtx.destination);
      }
      if(audioCtx.state==='suspended')audioCtx.resume().catch(()=>{});
      return audioCtx;
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
        voice.pulse.stop(now+.20);
        voice.drift.stop(now+.20);
      }catch(_){}
    }

    function startFlight(){
      if(!enabled||flightVoice)return;
      const ctx=ensureAudio();
      if(!ctx)return;

      const osc=ctx.createOscillator();
      const air=ctx.createOscillator();
      const shimmer=ctx.createOscillator();
      const pulse=ctx.createOscillator();
      const drift=ctx.createOscillator();
      const gain=ctx.createGain();
      const airGain=ctx.createGain();
      const shimmerGain=ctx.createGain();
      const pulseDepth=ctx.createGain();
      const driftDepth=ctx.createGain();
      const filter=ctx.createBiquadFilter();
      const airFilter=ctx.createBiquadFilter();
      const shimmerFilter=ctx.createBiquadFilter();
      const panner=typeof ctx.createStereoPanner==='function'?ctx.createStereoPanner():null;
      const shimmerPanner=typeof ctx.createStereoPanner==='function'?ctx.createStereoPanner():null;

      osc.type='triangle';
      air.type='sine';
      shimmer.type='sine';
      pulse.type='sine';
      drift.type='sine';

      osc.frequency.setValueAtTime(92,ctx.currentTime);
      air.frequency.setValueAtTime(184,ctx.currentTime);
      shimmer.frequency.setValueAtTime(368,ctx.currentTime);
      pulse.frequency.setValueAtTime(.18,ctx.currentTime);
      drift.frequency.setValueAtTime(.11,ctx.currentTime);

      osc.detune.setValueAtTime(-3,ctx.currentTime);
      air.detune.setValueAtTime(4,ctx.currentTime);
      shimmer.detune.setValueAtTime(7,ctx.currentTime);

      filter.type='lowpass';
      filter.frequency.setValueAtTime(1200,ctx.currentTime);
      filter.Q.setValueAtTime(.7,ctx.currentTime);
      airFilter.type='lowpass';
      airFilter.frequency.setValueAtTime(1600,ctx.currentTime);
      airFilter.Q.setValueAtTime(.5,ctx.currentTime);
      shimmerFilter.type='lowpass';
      shimmerFilter.frequency.setValueAtTime(2400,ctx.currentTime);
      shimmerFilter.Q.setValueAtTime(.45,ctx.currentTime);

      gain.gain.setValueAtTime(.0001,ctx.currentTime);
      gain.gain.exponentialRampToValueAtTime(.045,ctx.currentTime+.38);
      airGain.gain.setValueAtTime(.0001,ctx.currentTime);
      airGain.gain.exponentialRampToValueAtTime(.018,ctx.currentTime+.44);
      shimmerGain.gain.setValueAtTime(.0001,ctx.currentTime);
      shimmerGain.gain.exponentialRampToValueAtTime(.010,ctx.currentTime+.60);

      pulseDepth.gain.setValueAtTime(.008,ctx.currentTime);
      pulse.connect(pulseDepth);
      pulseDepth.connect(gain.gain);

      if(panner){
        driftDepth.gain.setValueAtTime(.55,ctx.currentTime);
        drift.connect(driftDepth);
        driftDepth.connect(panner.pan);
      }

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
      pulse.start();
      drift.start();

      flightVoice={
        osc,air,shimmer,pulse,drift,
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
      const base=92+(progress*118);
      const overtone=184+(progress*236);
      const shimmer=368+(progress*330);
      const volume=.045+(progress*.020);

      try{
        flightVoice.osc.frequency.setTargetAtTime(base,now,.20);
        flightVoice.air.frequency.setTargetAtTime(overtone,now,.24);
        flightVoice.shimmer.frequency.setTargetAtTime(shimmer,now,.28);
        flightVoice.gain.gain.setTargetAtTime(volume,now,.22);
        flightVoice.airGain.gain.setTargetAtTime(.018+(progress*.010),now,.26);
        flightVoice.shimmerGain.gain.setTargetAtTime(.010+(progress*.008),now,.30);
        flightVoice.filter.frequency.setTargetAtTime(1200+(progress*900),now,.28);
        flightVoice.airFilter.frequency.setTargetAtTime(1600+(progress*1100),now,.30);
        flightVoice.shimmerFilter.frequency.setTargetAtTime(2400+(progress*1500),now,.32);
      }catch(_){}
    }

    function playCrash(){
      stopFlight();
      tone(330,.18,.070,0,'triangle',150);
      tone(180,.28,.055,.018,'sine',82);
      tone(620,.065,.028,.012,'sine',360);
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

    function unlock(){
      if(enabled)ensureAudio();
    }

    function destroy(){
      stopFlight();
      try{audioCtx?.close?.()}catch(_){}
      audioCtx=null;
      masterGain=null;
      masterCompressor=null;
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
