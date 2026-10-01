(() => {
  'use strict';

  function create({rpc,playerToken,getRoundId,storage=sessionStorage,cryptoRef=crypto}) {
    const pendingCashoutKey='jl_aviator_pending_cashout_v1';
    const pendingMetricsKey='jl_aviator_metric_queue_v1';
    let metricFlushBusy=false;

    function uuid(){
      return cryptoRef.randomUUID?cryptoRef.randomUUID():Date.now()+'-'+Math.random().toString(36).slice(2);
    }

    function requestKeyFor(prefix,betId){
      const id=Number(betId);
      if(!Number.isFinite(id))return null;
      const storageKey='jl_aviator_'+prefix+'_request_key_'+id;
      let value=storage.getItem(storageKey);
      if(!value){
        value=uuid();
        storage.setItem(storageKey,value);
      }
      return value;
    }

    function cashoutRequestKey(betId){
      return requestKeyFor('cashout',betId);
    }

    function cancelBetRequestKey(betId){
      return requestKeyFor('cancel',betId);
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

    function metricPayload(operation,durationMs,success,errorCode=null,roundId=null,betId=null){
      return {
        operation:String(operation||'').toUpperCase(),
        duration_ms:Math.max(0,Math.min(60000,Math.round(Number(durationMs)||0))),
        success:Boolean(success),
        error_code:errorCode?String(errorCode).slice(0,80):null,
        round_id:Number.isFinite(Number(roundId))?Number(roundId):null,
        bet_id:Number.isFinite(Number(betId))?Number(betId):null,
        queued_at:Date.now()
      };
    }

    function readMetricQueue(){
      try{
        const parsed=JSON.parse(storage.getItem(pendingMetricsKey)||'[]');
        return Array.isArray(parsed)?parsed.slice(-20):[];
      }catch(_){
        return [];
      }
    }

    function writeMetricQueue(items){
      try{
        const bounded=(Array.isArray(items)?items:[]).slice(-20);
        if(bounded.length)storage.setItem(pendingMetricsKey,JSON.stringify(bounded));
        else storage.removeItem(pendingMetricsKey);
      }catch(_){}
    }

    function queueMetric(metric){
      const queued=readMetricQueue();
      queued.push(metric);
      writeMetricQueue(queued);
    }

    async function sendMetric(metric){
      const token=playerToken();
      if(!token)throw new Error('NO_PLAYER_TOKEN');

      return rpc('jl_aviator_record_client_metric',{
        p_token:token,
        p_operation:metric.operation,
        p_duration_ms:metric.duration_ms,
        p_success:metric.success,
        p_error_code:metric.error_code,
        p_round_id:metric.round_id,
        p_bet_id:metric.bet_id
      });
    }

    async function flushPendingMetrics(){
      if(metricFlushBusy||!playerToken())return;
      const queued=readMetricQueue();
      if(!queued.length)return;

      metricFlushBusy=true;
      let index=0;
      try{
        for(;index<queued.length;index+=1){
          await sendMetric(queued[index]);
        }
        writeMetricQueue([]);
      }catch(_){
        writeMetricQueue(queued.slice(index));
      }finally{
        metricFlushBusy=false;
      }
    }

    async function recordClientMetric(operation,durationMs,success,errorCode=null,roundId=null,betId=null){
      const metric=metricPayload(operation,durationMs,success,errorCode,roundId,betId);
      if(!playerToken())return;

      try{
        await sendMetric(metric);
        void flushPendingMetrics();
      }catch(_){
        queueMetric(metric);
      }
    }

    async function placeBet({amount,requestKey,autoCashoutMultiplier}){
      const started=Date.now();
      try{
        const result=await rpc('jl_aviator_place_bet',{
          p_token:playerToken(),
          p_amount:Number(amount),
          p_request_key:String(requestKey||betKey()||''),
          p_auto_cashout_multiplier:autoCashoutMultiplier===null
            ?null
            :Number(autoCashoutMultiplier)
        });
        void recordClientMetric(
          'BET',
          Date.now()-started,
          true,
          null,
          result?.round_id,
          result?.bet_id
        );
        return result;
      }catch(error){
        void recordClientMetric(
          'BET',
          Date.now()-started,
          false,
          error?.code||error?.message||'BET_FAILED',
          getRoundId?.(),
          null
        );
        throw error;
      }
    }

    function isTransientCashoutError(error){
      const raw=String(error?.message||error||'');
      const code=String(error?.code||'');
      const status=Number(error?.status||error?.statusCode||0);
      return status===502||status===503||status===504
        || code==='PGRST003'
        || /timed out acquiring connection|connection pool|gateway timeout|fetch failed|network/i.test(raw);
    }

    async function requestFinancialCashout(betId,requestKey){
      const started=Date.now();
      const id=Number(betId);
      const key=String(requestKey||cashoutRequestKey(id)||'');
      let firstError=null;

      for(let attempt=0;attempt<2;attempt+=1){
        try{
          const result=await rpc('jl_aviator_cashout',{
            p_token:playerToken(),
            p_bet_id:id,
            p_request_key:key
          });
          if(!result?.ok){
            const error=new Error(result?.message||'Cash-out rejeitado.');
            error.code=result?.error_code||'CASHOUT_REJECTED';
            throw error;
          }
          void recordClientMetric(
            'CASHOUT',
            Date.now()-started,
            true,
            null,
            result?.round_id||getRoundId?.(),
            id
          );
          return result;
        }catch(error){
          firstError=firstError||error;
          if(attempt===0&&isTransientCashoutError(error)){
            const settled=await fetchBetStatus(id).catch(()=>null);
            if(settled?.status==='CASHED_OUT'){
              void recordClientMetric(
                'CASHOUT',
                Date.now()-started,
                true,
                null,
                settled.round_id||getRoundId?.(),
                id
              );
              return {
                ok:true,
                already_processed:true,
                bet_id:id,
                round_id:settled.round_id,
                transaction_id:settled.payout_transaction_id,
                source:settled.cashout_source,
                multiplier:settled.cashout_multiplier,
                payout:settled.payout
              };
            }
            continue;
          }
          break;
        }
      }

      void recordClientMetric(
        'CASHOUT',
        Date.now()-started,
        false,
        firstError?.code||firstError?.message||'CASHOUT_FAILED',
        getRoundId?.(),
        id
      );
      throw firstError||new Error('Não foi possível concluir o cash-out.');
    }

    async function cancelBet(betId,requestKey){
      const id=Number(betId);
      const result=await rpc('jl_aviator_cancel_bet',{
        p_token:playerToken(),
        p_bet_id:id,
        p_request_key:String(requestKey||cancelBetRequestKey(id)||'')
      });
      if(!result?.ok){
        const error=new Error(result?.message||'Cancelamento rejeitado.');
        error.code=result?.error_code||'CANCEL_REJECTED';
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
      cashoutRequestKey,cancelBetRequestKey,
      readPendingCashout,savePendingCashout,clearPendingCashout,
      betKey,placeBet,cancelBet,requestFinancialCashout,fetchBetStatus,cashoutMessage,
      recordClientMetric,flushPendingMetrics
    });
  }

  window.JLAviatorFinancial=Object.freeze({create});
})();
