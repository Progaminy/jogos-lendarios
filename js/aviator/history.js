(() => {
  'use strict';

  function create({$,rpc,multiplierTier}) {
    let recentResults=[];
    let historyBusy=false;
    let historyRemoteLoaded=false;
    let historyRetryAt=0;

    function normalize(item){
      const id=Number(item?.id);
      const multiplier=Number(item?.crash_multiplier);
      if(!Number.isFinite(id)||id<=0||!Number.isFinite(multiplier)||multiplier<1)return null;
      const roundNo=Number(item?.round_no);
      return {
        id,
        round_no:Number.isFinite(roundNo)&&roundNo>0?roundNo:id,
        crash_multiplier:multiplier,
        ended_at:item?.ended_at||null
      };
    }

    function render(){
      const wrap=$('#aviatorHistory');
      const status=$('#historyStatus');
      if(!wrap||!status)return;
      const rows=recentResults.map(normalize).filter(Boolean).sort((a,b)=>b.id-a.id).slice(0,12);
      if(!rows.length){
        wrap.innerHTML='<span class="aviator-history-empty">Sem resultados recentes.</span>';
        status.textContent=historyRemoteLoaded?'Atualizado':'—';
        return;
      }
      wrap.innerHTML=rows.map((item,index)=>
        '<span class="aviator-history-value tier-'+multiplierTier(item.crash_multiplier)+'" title="Rodada #'+item.round_no+'">'+
          item.crash_multiplier.toFixed(2)+'x'+
        '</span>'+
        (index<rows.length-1?'<span class="aviator-history-separator" aria-hidden="true">·</span>':'')
      ).join('');
      wrap.setAttribute('aria-label','Multiplicadores recentes: '+rows.map(item=>item.crash_multiplier.toFixed(2)+' vezes').join(', '));
      status.textContent=rows.length+' recentes';
    }

    function remember(round){
      if(!round||!['CRASHED','SETTLED'].includes(round.status))return;
      const item=normalize({
        id:round.id,
        round_no:round.round_no,
        crash_multiplier:round.crash_multiplier,
        ended_at:round.crashed_at||round.settled_at||null
      });
      if(!item)return;
      recentResults=[item,...recentResults.filter(x=>Number(x?.id)!==item.id)].slice(0,12);
      render();
    }

    async function load(force=false){
      const now=Date.now();
      if(historyBusy||now<historyRetryAt)return;
      if(historyRemoteLoaded&&!force)return;
      historyBusy=true;
      const status=$('#historyStatus');
      if(status)status.textContent='A atualizar…';
      try{
        const raw=await rpc('jl_aviator_recent_results',{p_limit:12});
        const rows=Array.isArray(raw)?raw:[];
        const normalized=rows.map(normalize).filter(Boolean);
        if(normalized.length){
          const localOnly=recentResults.filter(local=>!normalized.some(remote=>remote.id===Number(local?.id)));
          recentResults=[...normalized,...localOnly].sort((a,b)=>b.id-a.id).slice(0,12);
        }
        historyRemoteLoaded=true;
        historyRetryAt=0;
      }catch(_){
        historyRemoteLoaded=false;
        historyRetryAt=Date.now()+60000;
      }finally{
        historyBusy=false;
        render();
      }
    }

    return Object.freeze({
      normalize,render,remember,load,
      busy:()=>historyBusy,
      remoteLoaded:()=>historyRemoteLoaded
    });
  }

  window.JLAviatorHistory=Object.freeze({create});
})();
