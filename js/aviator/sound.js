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
        voice.riseGain.gain.cancelScheduledValues(now);
        voice.riseGain.gain.setValueAtTime(Math.max(.0001,voice.riseGain.gain.value),now);
        voice.riseGain.gain.linearRampToValueAtTime(.0001,now+.015);
        voice.edgeGain.gain.cancelScheduledValues(now);
        voice.edgeGain.gain.setValueAtTime(Math.max(.0001,voice.edgeGain.gain.value),now);
        voice.edgeGain.gain.linearRampToValueAtTime(.0001,now+.015);
        voice.whooshGain.gain.cancelScheduledValues(now);
        voice.whooshGain.gain.setValueAtTime(Math.max(.0001,voice.whooshGain.gain.value),now);
        voice.whooshGain.gain.linearRampToValueAtTime(.0001,now+.015);
        voice.rise.stop(now+.025);
        voice.edge.stop(now+.025);
        voice.whoosh.stop(now+.025);
      }catch(_){}
    }

    function startFlight(){
      if(!enabled||flightVoice)return;
      const ctx=ensureAudio();
      if(!ctx||ctx.state!=='running')return;

      const rise=ctx.createOscillator();
      const edge=ctx.createOscillator();
      const whoosh=ctx.createBufferSource();
      const riseGain=ctx.createGain();
      const edgeGain=ctx.createGain();
      const whooshGain=ctx.createGain();
      const riseFilter=ctx.createBiquadFilter();
      const edgeFilter=ctx.createBiquadFilter();
      const whooshFilter=ctx.createBiquadFilter();

      rise.type='sine';
      edge.type='triangle';
      rise.frequency.setValueAtTime(185,ctx.currentTime);
      edge.frequency.setValueAtTime(370,ctx.currentTime);
      edge.detune.setValueAtTime(6,ctx.currentTime);

      const seconds=2;
      const noiseBuffer=ctx.createBuffer(1,Math.max(1,Math.floor(ctx.sampleRate*seconds)),ctx.sampleRate);
      const noise=noiseBuffer.getChannelData(0);
      for(let i=0;i<noise.length;i++)noise[i]=(Math.random()*2-1);
      whoosh.buffer=noiseBuffer;
      whoosh.loop=true;

      riseFilter.type='bandpass';
      riseFilter.frequency.setValueAtTime(420,ctx.currentTime);
      riseFilter.Q.setValueAtTime(.75,ctx.currentTime);
      edgeFilter.type='lowpass';
      edgeFilter.frequency.setValueAtTime(1450,ctx.currentTime);
      edgeFilter.Q.setValueAtTime(.45,ctx.currentTime);
      whooshFilter.type='bandpass';
      whooshFilter.frequency.setValueAtTime(900,ctx.currentTime);
      whooshFilter.Q.setValueAtTime(.62,ctx.currentTime);

      riseGain.gain.setValueAtTime(.0001,ctx.currentTime);
      riseGain.gain.exponentialRampToValueAtTime(.024,ctx.currentTime+.22);
      edgeGain.gain.setValueAtTime(.0001,ctx.currentTime);
      edgeGain.gain.exponentialRampToValueAtTime(.011,ctx.currentTime+.28);
      whooshGain.gain.setValueAtTime(.0001,ctx.currentTime);
      whooshGain.gain.exponentialRampToValueAtTime(.040,ctx.currentTime+.24);

      rise.connect(riseFilter);
      riseFilter.connect(riseGain);
      edge.connect(edgeFilter);
      edgeFilter.connect(edgeGain);
      whoosh.connect(whooshFilter);
      whooshFilter.connect(whooshGain);

      riseGain.connect(masterGain||ctx.destination);
      edgeGain.connect(masterGain||ctx.destination);
      whooshGain.connect(masterGain||ctx.destination);

      rise.start();
      edge.start();
      whoosh.start();

      flightVoice={
        rise,edge,whoosh,
        riseGain,edgeGain,whooshGain,
        riseFilter,edgeFilter,whooshFilter
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
      const tension=Math.pow(progress,.62);
      const riseHz=185+(tension*520);
      const edgeHz=370+(tension*1040);

      try{
        flightVoice.rise.frequency.setTargetAtTime(riseHz,now,.12);
        flightVoice.edge.frequency.setTargetAtTime(edgeHz,now,.14);
        flightVoice.riseGain.gain.setTargetAtTime(.024+(tension*.020),now,.16);
        flightVoice.edgeGain.gain.setTargetAtTime(.011+(tension*.011),now,.18);
        flightVoice.whooshGain.gain.setTargetAtTime(.040+(tension*.035),now,.14);
        flightVoice.riseFilter.frequency.setTargetAtTime(420+(tension*950),now,.14);
        flightVoice.edgeFilter.frequency.setTargetAtTime(1450+(tension*1750),now,.16);
        flightVoice.whooshFilter.frequency.setTargetAtTime(900+(tension*2700),now,.12);
      }catch(_){}
    }

    function playCrash(){
      stopFlight();
      const ctx=ensureAudio();
      if(ctx&&ctx.state==='running'){
        const source=ctx.createBufferSource();
        const duration=.14;
        const buffer=ctx.createBuffer(1,Math.max(1,Math.floor(ctx.sampleRate*duration)),ctx.sampleRate);
        const data=buffer.getChannelData(0);
        for(let i=0;i<data.length;i++){
          const decay=Math.pow(1-(i/data.length),2.4);
          data[i]=(Math.random()*2-1)*decay;
        }
        const filter=ctx.createBiquadFilter();
        const gain=ctx.createGain();
        filter.type='lowpass';
        filter.frequency.setValueAtTime(820,ctx.currentTime);
        filter.Q.setValueAtTime(.5,ctx.currentTime);
        gain.gain.setValueAtTime(.11,ctx.currentTime);
        gain.gain.exponentialRampToValueAtTime(.0001,ctx.currentTime+duration);
        source.buffer=buffer;
        source.connect(filter);
        filter.connect(gain);
        gain.connect(masterGain||ctx.destination);
        source.start();
      }
      tone(145,.16,.060,0,'sine',58);
      tone(520,.035,.018,.006,'triangle',220);
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
