(() => {
  'use strict';

  function create({$,rpc,playerToken,money}) {
    let rows=[];
    let busy=false;
    let loaded=false;
    let nextBeforeId=null;
    let hasMore=false;

    const details=$('#aviatorMyHistoryCard');
    const statusEl=$('#myHistoryStatus');
    const list=$('#aviatorMyHistory');
    const moreBtn=$('#myHistoryMore');

    function esc(value){
      return String(value??'')
        .replaceAll('&','&amp;')
        .replaceAll('<','&lt;')
        .replaceAll('>','&gt;')
        .replaceAll('"','&quot;')
        .replaceAll("'",'&#39;');
    }

    function formatTime(value){
      const d=new Date(value);
      if(Number.isNaN(d.getTime()))return '';
      try{
        return new Intl.DateTimeFormat('pt-MZ',{
          day:'2-digit',month:'2-digit',
          hour:'2-digit',minute:'2-digit'
        }).format(d);
      }catch{
        return '';
      }
    }

    function meta(row){
      const status=String(row?.status||'').toUpperCase();
      if(status==='CASHED_OUT')return {icon:'✓',label:'GANHA',kind:'won'};
      if(status==='LOST')return {icon:'✕',label:'PERDIDA',kind:'lost'};
      if(status==='REFUNDED')return {icon:'↩',label:'REEMBOLSADA',kind:'refunded'};
      return {icon:'●',label:'ATIVA',kind:'active'};
    }

    function detail(row){
      const status=String(row?.status||'').toUpperCase();
      const stake=Number(row?.stake);
      const payout=Number(row?.payout);
      const cashout=Number(row?.cashout_multiplier);
      const crash=Number(row?.crash_multiplier);

      if(status==='CASHED_OUT'){
        return (Number.isFinite(stake)?money(stake):'—')+
          ' → '+(Number.isFinite(payout)?money(payout):'—')+
          (Number.isFinite(cashout)?' · '+cashout.toFixed(2)+'×':'');
      }
      if(status==='LOST'){
        return 'Apostado '+(Number.isFinite(stake)?money(stake):'—')+
          (Number.isFinite(crash)?' · Crash '+crash.toFixed(2)+'×':'');
      }
      if(status==='REFUNDED'){
        return 'Devolvido '+(Number.isFinite(stake)?money(stake):'—');
      }
      return 'Aposta '+(Number.isFinite(stake)?money(stake):'—')+' · Em curso';
    }

    function render(){
      if(!list||!statusEl)return;

      if(!playerToken()){
        list.innerHTML='<div class="aviator-my-history-empty">Entre na conta para ver as suas apostas.</div>';
        statusEl.textContent='Conta necessária';
        if(moreBtn)moreBtn.hidden=true;
        return;
      }

      if(!rows.length){
        list.innerHTML='<div class="aviator-my-history-empty">Ainda não há apostas do Aviator.</div>';
        statusEl.textContent=loaded?'0 apostas':'—';
        if(moreBtn)moreBtn.hidden=true;
        return;
      }

      list.innerHTML=rows.map(row=>{
        const m=meta(row);
        const roundNo=Number(row?.round_no)||Number(row?.round_id)||0;
        const time=formatTime(row?.created_at);
        return '<article class="aviator-my-history-row is-'+m.kind+'" data-bet-id="'+esc(row?.id)+'">'+
          '<span class="aviator-my-history-icon" aria-hidden="true">'+m.icon+'</span>'+
          '<div class="aviator-my-history-main">'+
            '<div class="aviator-my-history-title"><strong>'+m.label+'</strong><span>Rodada #'+esc(roundNo)+'</span></div>'+
            '<div class="aviator-my-history-detail">'+esc(detail(row))+'</div>'+
          '</div>'+
          '<time>'+esc(time)+'</time>'+
        '</article>';
      }).join('');

      statusEl.textContent=rows.length+' apostas';
      if(moreBtn){
        moreBtn.hidden=!hasMore;
        moreBtn.disabled=busy;
      }
    }

    async function load(reset=false){
      if(busy)return;
      const token=playerToken();
      if(!token){
        loaded=true;
        rows=[];
        render();
        return;
      }
      if(loaded&&!reset&&!hasMore)return;

      busy=true;
      if(statusEl)statusEl.textContent='A atualizar…';
      if(moreBtn)moreBtn.disabled=true;

      try{
        const result=await rpc('jl_aviator_my_history',{
          p_token:token,
          p_limit:20,
          p_before_id:reset?null:nextBeforeId
        });
        if(result?.ok!==true)throw new Error('HISTORY_FAILED');

        const incoming=Array.isArray(result?.bets)?result.bets:[];
        if(reset){
          rows=incoming;
        }else{
          const known=new Set(rows.map(x=>Number(x?.id)));
          rows=[...rows,...incoming.filter(x=>!known.has(Number(x?.id)))];
        }

        nextBeforeId=result?.next_before_id??null;
        hasMore=result?.has_more===true;
        loaded=true;
      }catch(_){
        if(statusEl)statusEl.textContent='Não foi possível atualizar';
      }finally{
        busy=false;
        render();
      }
    }

    function invalidate(){
      loaded=false;
      nextBeforeId=null;
      hasMore=false;
      if(details?.open)void load(true);
    }

    details?.addEventListener('toggle',()=>{
      if(details.open&&!loaded)void load(true);
    });
    moreBtn?.addEventListener('click',()=>void load(false));

    render();

    return Object.freeze({
      load,
      invalidate,
      isLoaded:()=>loaded,
      rows:()=>[...rows]
    });
  }

  window.JLAviatorPersonalHistory=Object.freeze({create});
})();
