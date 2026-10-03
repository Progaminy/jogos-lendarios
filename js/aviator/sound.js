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
        voice.motorGain.gain.cancelScheduledValues(now);
        voice.motorGain.gain.setTargetAtTime(.0001,now,.055);
        voice.harmonicGain.gain.cancelScheduledValues(now);
        voice.harmonicGain.gain.setTargetAtTime(.0001,now,.06);
        voice.windGain.gain.cancelScheduledValues(now);
        voice.windGain.gain.setTargetAtTime(.0001,now,.065);
        voice.motor.stop(now+.20);
        voice.harmonic.stop(now+.20);
        voice.wind.stop(now+.20);
      }catch(_){}
    }

    function startFlight(){
      if(!enabled||flightVoice)return;
      const ctx=ensureAudio();
      if(!ctx||ctx.state!=='running')return;

      const motor=ctx.createOscillator();
      const harmonic=ctx.createOscillator();
      const wind=ctx.createBufferSource();
      const motorGain=ctx.createGain();
      const harmonicGain=ctx.createGain();
      const windGain=ctx.createGain();
      const motorFilter=ctx.createBiquadFilter();
      const harmonicFilter=ctx.createBiquadFilter();
      const windFilter=ctx.createBiquadFilter();

      motor.type='sine';
      harmonic.type='triangle';
      motor.frequency.setValueAtTime(74,ctx.currentTime);
      harmonic.frequency.setValueAtTime(148,ctx.currentTime);

      const seconds=2;
      const noiseBuffer=ctx.createBuffer(1,Math.max(1,Math.floor(ctx.sampleRate*seconds)),ctx.sampleRate);
      const noise=noiseBuffer.getChannelData(0);
      for(let i=0;i<noise.length;i++)noise[i]=(Math.random()*2-1);
      wind.buffer=noiseBuffer;
      wind.loop=true;

      motorFilter.type='lowpass';
      motorFilter.frequency.setValueAtTime(520,ctx.currentTime);
      motorFilter.Q.setValueAtTime(.7,ctx.currentTime);
      harmonicFilter.type='lowpass';
      harmonicFilter.frequency.setValueAtTime(900,ctx.currentTime);
      harmonicFilter.Q.setValueAtTime(.55,ctx.currentTime);
      windFilter.type='bandpass';
      windFilter.frequency.setValueAtTime(780,ctx.currentTime);
      windFilter.Q.setValueAtTime(.55,ctx.currentTime);

      motorGain.gain.setValueAtTime(.0001,ctx.currentTime);
      motorGain.gain.exponentialRampToValueAtTime(.040,ctx.currentTime+.28);
      harmonicGain.gain.setValueAtTime(.0001,ctx.currentTime);
      harmonicGain.gain.exponentialRampToValueAtTime(.018,ctx.currentTime+.34);
      windGain.gain.setValueAtTime(.0001,ctx.currentTime);
      windGain.gain.exponentialRampToValueAtTime(.028,ctx.currentTime+.36);

      motor.connect(motorFilter);
      motorFilter.connect(motorGain);
      harmonic.connect(harmonicFilter);
      harmonicFilter.connect(harmonicGain);
      wind.connect(windFilter);
      windFilter.connect(windGain);

      motorGain.connect(masterGain||ctx.destination);
      harmonicGain.connect(masterGain||ctx.destination);
      windGain.connect(masterGain||ctx.destination);

      motor.start();
      harmonic.start();
      wind.start();

      flightVoice={
        motor,harmonic,wind,
        motorGain,harmonicGain,windGain,
        motorFilter,harmonicFilter,windFilter
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
      const motorHz=74+(progress*82);
      const harmonicHz=148+(progress*164);

      try{
        flightVoice.motor.frequency.setTargetAtTime(motorHz,now,.18);
        flightVoice.harmonic.frequency.setTargetAtTime(harmonicHz,now,.20);
        flightVoice.motorGain.gain.setTargetAtTime(.040+(progress*.020),now,.22);
        flightVoice.harmonicGain.gain.setTargetAtTime(.018+(progress*.012),now,.24);
        flightVoice.windGain.gain.setTargetAtTime(.028+(progress*.026),now,.20);
        flightVoice.motorFilter.frequency.setTargetAtTime(520+(progress*420),now,.22);
        flightVoice.harmonicFilter.frequency.setTargetAtTime(900+(progress*700),now,.24);
        flightVoice.windFilter.frequency.setTargetAtTime(780+(progress*1550),now,.18);
      }catch(_){}
    }

    function playCrash(){
      stopFlight();
      const ctx=ensureAudio();
      if(ctx&&ctx.state==='running'){
        const source=ctx.createBufferSource();
        const duration=.18;
        const buffer=ctx.createBuffer(1,Math.max(1,Math.floor(ctx.sampleRate*duration)),ctx.sampleRate);
        const data=buffer.getChannelData(0);
        for(let i=0;i<data.length;i++)data[i]=(Math.random()*2-1)*(1-(i/data.length));
        const filter=ctx.createBiquadFilter();
        const gain=ctx.createGain();
        filter.type='lowpass';
        filter.frequency.setValueAtTime(1150,ctx.currentTime);
        gain.gain.setValueAtTime(.085,ctx.currentTime);
        gain.gain.exponentialRampToValueAtTime(.0001,ctx.currentTime+duration);
        source.buffer=buffer;
        source.connect(filter);
        filter.connect(gain);
        gain.connect(masterGain||ctx.destination);
        source.start();
      }
      tone(190,.20,.050,0,'sine',78);
      tone(460,.07,.026,.012,'triangle',240);
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
