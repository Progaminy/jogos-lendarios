(() => {
  'use strict';

  function create({
    slot=1,
    $,
    playerToken,
    getRound,
    isEnabled,
    isOnline,
    isBusy,
    hasActiveBet,
    playerMessage,
    form,
    onMessage
  }) {
    const suffix=Number(slot)===1?'':String(slot);
    const storageKey='jl_aviator_next_bet_v1_slot_'+slot;
    let queued=read();
    let attemptedRoundId=null;
    let submittingRoundId=null;

    function read(){
      try{
        const parsed=JSON.parse(sessionStorage.getItem(storageKey)||'null');
        const amount=Number(parsed?.amount);
        const auto=parsed?.auto_cashout===null?null:Number(parsed?.auto_cashout);
        if(!Number.isFinite(amount)||amount<0.5||amount>500)return null;
        if(auto!==null&&(!Number.isFinite(auto)||auto<1.01))return null;
        return {amount,auto_cashout:auto};
      }catch(_){
        return null;
      }
    }

    function save(value){
      queued=value||null;
      try{
        if(queued)sessionStorage.setItem(storageKey,JSON.stringify(queued));
        else sessionStorage.removeItem(storageKey);
      }catch(_){}
    }

    function amountInput(){return $('#aviatorAmount'+suffix);}
    function autoInput(){return $('#aviatorAutoCashout'+suffix);}

    function parseCurrent(){
      const amount=Number(amountInput()?.value);
      if(!Number.isFinite(amount)||amount<0.5||amount>500){
        throw new Error('Informe um valor entre 0,50 e 500 MZN.');
      }

      const raw=String(autoInput()?.value||'').trim();
      const auto=raw===''?null:Number(raw);
      if(
        auto!==null&&(
          !Number.isFinite(auto)||
          auto<1.01||
          Math.abs(auto*100-Math.round(auto*100))>1e-8
        )
      ){
        throw new Error('Cash-out automático deve ser 1,01x ou maior, com até 2 casas decimais.');
      }

      return {amount,auto_cashout:auto};
    }

    function handleAction(action){
      if(action!=='queue-next'&&action!=='cancel-next')return false;

      if(action==='cancel-next'){
        save(null);
        onMessage?.('Próxima aposta cancelada.');
        return true;
      }

      try{
        if(!isOnline?.())throw new Error('Sem ligação. Aguarde a reconexão.');
        if(!playerToken?.())throw new Error('Entre na sua conta primeiro.');
        if(!isEnabled?.())throw new Error('Aviator brevemente.');

        const r=getRound?.();
        if(!r||!['LOCKED','FLYING'].includes(r.status)){
          throw new Error('Aguarde a rodada em curso.');
        }

        save(parseCurrent());
        onMessage?.('');
      }catch(error){
        onMessage?.(playerMessage?.(
          error,
          'Não foi possível preparar a próxima aposta.'
        )||'Não foi possível preparar a próxima aposta.');
      }

      return true;
    }

    function schedule(){
      const r=getRound?.();
      const roundId=Number(r?.id);
      if(
        !queued||
        !isEnabled?.()||
        !isOnline?.()||
        !playerToken?.()||
        !Number.isFinite(roundId)||
        r?.status!=='OPEN'||
        r?.betting_open===false||
        hasActiveBet?.()||
        isBusy?.()||
        attemptedRoundId===roundId
      ) return;

      attemptedRoundId=roundId;
      queueMicrotask(()=>{
        const current=getRound?.();
        if(
          !queued||
          !isOnline?.()||
          !playerToken?.()||
          Number(current?.id)!==roundId||
          current?.status!=='OPEN'||
          current?.betting_open===false||
          hasActiveBet?.()||
          isBusy?.()
        ) return;

        const amount=amountInput();
        const auto=autoInput();
        if(amount)amount.value=String(queued.amount);
        if(auto)auto.value=queued.auto_cashout===null?'':String(queued.auto_cashout);
        submittingRoundId=roundId;
        form?.requestSubmit?.();
      });
    }

    function isSubmitting(roundId){
      return submittingRoundId===Number(roundId);
    }

    function consume(roundId){
      if(!isSubmitting(roundId))return false;
      save(null);
      attemptedRoundId=Number(roundId);
      return true;
    }

    function clearSubmitting(roundId){
      if(isSubmitting(roundId))submittingRoundId=null;
    }

    function resetRound(){
      attemptedRoundId=null;
      submittingRoundId=null;
    }

    return Object.freeze({
      hasQueued:()=>Boolean(queued),
      handleAction,
      schedule,
      isSubmitting,
      consume,
      clearSubmitting,
      resetRound
    });
  }

  window.JLAviatorNextBet=Object.freeze({create});
})();
