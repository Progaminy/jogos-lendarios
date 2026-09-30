(() => {
  'use strict';

  const STORAGE_KEY='jl_aviator_vibration_enabled';

  function create({button,storage=localStorage,navigatorRef=navigator}={}) {
    const supported=typeof navigatorRef?.vibrate==='function';
    let enabled=false;
    let initialized=false;
    let lastRoundId=null;
    let lastStatus=null;
    let terminalRoundId=null;

    try{enabled=supported&&storage.getItem(STORAGE_KEY)==='1';}catch{}

    function updateButton(){
      if(!button)return;
      button.hidden=!supported;
      button.disabled=!supported;
      button.textContent=enabled?'📳 Vib.':'🚫 Vib.';
      button.setAttribute('aria-pressed',enabled?'true':'false');
      button.setAttribute(
        'aria-label',
        enabled?'Desativar vibração do Aviator':'Ativar vibração do Aviator'
      );
      button.title=enabled?'Desativar vibração':'Ativar vibração';
      button.classList.toggle('is-on',enabled);
    }

    function setEnabled(next){
      enabled=supported&&Boolean(next);
      try{storage.setItem(STORAGE_KEY,enabled?'1':'0');}catch{}
      updateButton();
      return enabled;
    }

    function toggle(){
      return setEnabled(!enabled);
    }

    function vibrateCrash(){
      if(!supported||!enabled)return false;
      try{
        return navigatorRef.vibrate(60)!==false;
      }catch{
        return false;
      }
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
        return;
      }

      if(lastRoundId===roundId&&lastStatus===status)return;

      const previousRoundId=lastRoundId;
      const previousStatus=lastStatus;
      lastRoundId=roundId;
      lastStatus=status;

      if(roundId!==previousRoundId){
        terminalRoundId=(status==='CRASHED'||status==='SETTLED')?roundId:null;
        return;
      }

      const terminal=status==='CRASHED'||status==='SETTLED';
      const wasTerminal=previousStatus==='CRASHED'||previousStatus==='SETTLED';

      if(terminal&&!wasTerminal&&terminalRoundId!==roundId){
        terminalRoundId=roundId;
        vibrateCrash();
      }
    }

    button?.addEventListener('click',toggle);
    updateButton();

    return Object.freeze({
      supported,
      isEnabled:()=>enabled,
      setEnabled,
      toggle,
      syncRound,
      vibrateCrash,
      updateButton
    });
  }

  window.JLAviatorHaptics=Object.freeze({create,STORAGE_KEY});
})();
