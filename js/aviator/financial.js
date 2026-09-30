(() => {
  'use strict';

  function create({rpc,playerToken,getRoundId,storage=sessionStorage,cryptoRef=crypto}) {
    const pendingCashoutKey='jl_aviator_pending_cashout_v1';

    function uuid(){
      return cryptoRef.randomUUID?cryptoRef.randomUUID():Date.now()+'-'+Math.random().toString(36).slice(2);
    }

    function cashoutRequestKey(betId){
      const id=Number(betId);
      if(!Number.isFinite(id))return null;
      const storageKey='jl_aviator_cashout_request_key_'+id;
      let value=storage.getItem(storageKey);
      if(!value){
        value=uuid();
        storage.setItem(storageKey,value);
      }
      return value;
    }

    function readPendingCashout(){
      try{
        const value=JSON.parse(storage.getItem(pendingCashoutKey)||'null');
        const betId=Number(value?.bet_id),roundId=Number(value?.round_id),createdAt=Number(value?.created_at);
        if(!Number.isFinite(betId)||!Number.isFinite(roundId)||!Number.isFinite(createdAt))return null;
        if(Date.now()-createdAt>6*60*60*1000){
          storage.removeItem(pendingCashoutKey);
          return null;
        }
        const requestKey=String(value?.request_key||cashoutRequestKey(betId)||'');
        return {bet_id:betId,round_id:roundId,request_key:requestKey,created_at:createdAt};
      }catch(_){ return null; }
    }

    function savePendingCashout(betId,roundId,requestKey){
      try{
        storage.setItem(pendingCashoutKey,JSON.stringify({
          bet_id:Number(betId),
          round_id:Number(roundId),
          request_key:String(requestKey||cashoutRequestKey(betId)||''),
          created_at:Date.now()
        }));
      }catch(_){}
    }

    function clearPendingCashout(){
      try{storage.removeItem(pendingCashoutKey)}catch(_){}
    }

    function betKey(){
      const roundId=Number(getRoundId?.());
      if(!Number.isFinite(roundId)||roundId<=0)return null;
      const key='jl_aviator_bet_key_'+roundId;
      let value=storage.getItem(key);
      if(!value){
        value=uuid();
        storage.setItem(key,value);
      }
      return value;
    }

    async function placeBet({amount,requestKey,autoCashoutMultiplier}){
      return rpc('jl_aviator_place_bet',{
        p_token:playerToken(),
        p_amount:Number(amount),
        p_request_key:String(requestKey||betKey()||''),
        p_auto_cashout_multiplier:autoCashoutMultiplier===null
          ?null
          :Number(autoCashoutMultiplier)
      });
    }

    async function requestFinancialCashout(betId,requestKey){
      const result=await rpc('jl_aviator_cashout',{
        p_token:playerToken(),
        p_bet_id:Number(betId),
        p_request_key:String(requestKey||cashoutRequestKey(betId)||'')
      });
      if(!result?.ok){
        const error=new Error(result?.message||'Cash-out rejeitado.');
        error.code=result?.error_code||'CASHOUT_REJECTED';
        throw error;
      }
      return result;
    }

    async function fetchBetStatus(betId){
      const id=Number(betId);
      if(!Number.isFinite(id)||!playerToken())return null;
      const x=await rpc('jl_aviator_bet_status',{p_token:playerToken(),p_bet_id:id});
      return x?.ok===true&&x?.bet?x.bet:null;
    }

    function cashoutMessage(source,multiplier,payout){
      const auto=String(source||'').toUpperCase()==='AUTO';
      return (auto?'Auto cash-out confirmado em ':'Cash-out confirmado em ')+
        Number(multiplier||1).toFixed(2)+'× · '+Number(payout||0).toLocaleString('pt-MZ',{
          minimumFractionDigits:2,maximumFractionDigits:2
        })+' MZN';
    }

    return Object.freeze({
      cashoutRequestKey,readPendingCashout,savePendingCashout,clearPendingCashout,
      betKey,placeBet,requestFinancialCashout,fetchBetStatus,cashoutMessage
    });
  }

  window.JLAviatorFinancial=Object.freeze({create});
})();
