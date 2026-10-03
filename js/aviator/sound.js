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
      const now=ctx?.currentTime||0;
      for(const note of voice.activeNotes){
        try{
          note.gain.gain.cancelScheduledValues(now);
          note.gain.gain.setValueAtTime(Math.max(.0001,note.gain.gain.value),now);
          note.gain.gain.linearRampToValueAtTime(.0001,now+.018);
          note.osc.stop(now+.025);
          note.harmonic.stop(now+.025);
        }catch(_){}
      }
      voice.activeNotes.clear();
    }

    function playPianoNote(freq,volume=.040,duration=.72){
      const ctx=ensureAudio();
      const voice=flightVoice;
      if(!ctx||ctx.state!=='running'||!voice)return;

      const start=ctx.currentTime;
      const osc=ctx.createOscillator();
      const harmonic=ctx.createOscillator();
      const gain=ctx.createGain();
      const harmonicGain=ctx.createGain();
      const filter=ctx.createBiquadFilter();

      osc.type='triangle';
      harmonic.type='sine';
      osc.frequency.setValueAtTime(freq,start);
      harmonic.frequency.setValueAtTime(freq*2,start);

      filter.type='lowpass';
      filter.frequency.setValueAtTime(3600,start);
      filter.frequency.exponentialRampToValueAtTime(1500,start+duration);
      filter.Q.setValueAtTime(.35,start);

      gain.gain.setValueAtTime(.0001,start);
      gain.gain.exponentialRampToValueAtTime(volume,start+.008);
      gain.gain.exponentialRampToValueAtTime(Math.max(.00012,volume*.22),start+.16);
      gain.gain.exponentialRampToValueAtTime(.0001,start+duration);

      harmonicGain.gain.setValueAtTime(.0001,start);
      harmonicGain.gain.exponentialRampToValueAtTime(volume*.20,start+.006);
      harmonicGain.gain.exponentialRampToValueAtTime(.0001,start+Math.min(.34,duration));

      osc.connect(filter);
      filter.connect(gain);
      harmonic.connect(harmonicGain);
      gain.connect(masterGain||ctx.destination);
      harmonicGain.connect(masterGain||ctx.destination);

      const note={osc,harmonic,gain};
      voice.activeNotes.add(note);
      osc.onended=()=>voice.activeNotes.delete(note);

      osc.start(start);
      harmonic.start(start);
      osc.stop(start+duration+.03);
      harmonic.stop(start+Math.min(.38,duration)+.03);
    }

    function startFlight(){
      if(!enabled||flightVoice)return;
      const ctx=ensureAudio();
      if(!ctx||ctx.state!=='running')return;

      flightVoice={
        activeNotes:new Set(),
        lastNoteAt:-Infinity,
        noteIndex:0
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
      const interval=.52-(Math.min(1,progress)*.20);
      if(now-flightVoice.lastNoteAt<interval)return;

      const scale=[261.63,293.66,329.63,392.00,440.00,523.25,587.33,659.25];
      const lift=Math.min(1,progress);
      const baseShift=Math.min(3,Math.floor(lift*4));
      const pattern=[0,2,4,2,5,4,6,4];
      const rawIndex=pattern[flightVoice.noteIndex%pattern.length]+baseShift;
      const octave=Math.floor(rawIndex/scale.length);
      const noteIndex=rawIndex%scale.length;
      const freq=scale[noteIndex]*Math.pow(2,octave);
      const volume=.032+(lift*.018);
      const duration=.78-(lift*.18);

      playPianoNote(freq,volume,duration);
      flightVoice.noteIndex+=1;
      flightVoice.lastNoteAt=now;
    }

    function playCrash(){
      stopFlight();
      tone(392.00,.18,.044,0,'triangle',261.63);
      tone(261.63,.34,.040,.035,'sine',130.81);
      tone(196.00,.26,.028,.055,'triangle',98.00);
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
