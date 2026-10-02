(() => {
  'use strict';

  const STORAGE_KEY='jl_aviator_sound_enabled';

  function create({button,storage=localStorage,win=window}={}) {
    let enabled=false;
    let audioCtx=null;
    let lastRoundId=null;
    let lastStatus=null;
    let terminalRoundId=null;

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

    function tone(freq,duration=.08,volume=.025,delay=0,type='sine'){
      const ctx=ensureAudio();
      if(!ctx)return;
      const start=ctx.currentTime+Math.max(0,delay);
      const osc=ctx.createOscillator();
      const gain=ctx.createGain();
      osc.type=type;
      osc.frequency.setValueAtTime(freq,start);
      gain.gain.setValueAtTime(.0001,start);
      gain.gain.exponentialRampToValueAtTime(Math.max(.0002,volume),start+.008);
      gain.gain.exponentialRampToValueAtTime(.0001,start+duration);
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start(start);
      osc.stop(start+duration+.02);
    }

    function playEnable(){
      tone(520,.07,.025,0,'triangle');
      tone(720,.09,.022,.07,'triangle');
    }
    function playLocked(){tone(300,.055,.018,0,'sine');}
    function playTakeoff(){
      tone(360,.10,.024,0,'triangle');
      tone(520,.12,.026,.08,'triangle');
      tone(720,.14,.023,.17,'sine');
    }
    function playCrash(){
      tone(240,.13,.034,0,'sawtooth');
      tone(150,.20,.032,.08,'triangle');
    }
    function playCashout(){
      tone(640,.07,.026,0,'triangle');
      tone(860,.09,.028,.06,'triangle');
      tone(1080,.11,.024,.13,'sine');
    }
    function playBet(){
      tone(460,.065,.018,0,'sine');
      tone(620,.075,.018,.055,'triangle');
    }

    function setEnabled(next){
      enabled=Boolean(next);
      try{storage.setItem(STORAGE_KEY,enabled?'1':'0');}catch{}
      updateButton();
      if(enabled){
        ensureAudio();
        playEnable();
      }
      return enabled;
    }

    function toggle(){return setEnabled(!enabled);}

    function syncRound(round){
      if(!round?.id||!round?.status)return;
      const roundId=Number(round.id);
      const status=String(round.status).toUpperCase();

      if(lastRoundId===roundId&&lastStatus===status)return;
      lastRoundId=roundId;
      lastStatus=status;

      if(!enabled)return;
      if(status==='LOCKED'){playLocked();return;}
      if(status==='FLYING'){
        terminalRoundId=null;
        playTakeoff();
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

    button?.addEventListener('click',toggle);
    win.addEventListener?.('pointerdown',unlock,{once:true,passive:true});
    win.addEventListener?.('keydown',unlock,{once:true});
    updateButton();

    return Object.freeze({
      isEnabled:()=>enabled,
      setEnabled,
      toggle,
      syncRound,
      playBet,
      playCashout,
      updateButton
    });
  }

  window.JLAviatorSound=Object.freeze({create,STORAGE_KEY});
})();
