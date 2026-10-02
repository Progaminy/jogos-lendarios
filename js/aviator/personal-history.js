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
      if(value===null||value===undefined||value==='')return '';
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

    function numeric(value){
      if(value===null||value===undefined||value==='')return null;
      const n=Number(value);
      return Number.isFinite(n)?n:null;
    }

    function valueOrDash(value,formatter){
      const n=numeric(value);
      return n===null?'—':formatter(n);
    }

    function paymentText(row){
      const status=String(row?.status||'').toUpperCase();
      const payout=numeric(row?.payout);
      const stake=numeric(row?.stake);

      if(status==='CASHED_OUT'){
        return payout===null?'—':money(payout);
      }
      if(status==='LOST'){
        return money(0);
      }
      if(status==='REFUNDED'){
        return stake===null?'Reembolsada':money(stake)+' (reembolso)';
      }
      return '—';
    }

    function fields(row){
      const roundNo=Number(row?.round_no)||Number(row?.round_id)||0;
      const slot=Number(row?.bet_slot)===2?2:1;
      return [
        ['Painel','Aposta '+slot],
        ['Rodada','#'+String(roundNo||'—')],
        ['Apostado',valueOrDash(row?.stake,money)],
        ['Cash-out',valueOrDash(row?.cashout_multiplier,n=>n.toFixed(2)+'×')],
        ['Crash',valueOrDash(row?.crash_multiplier,n=>n.toFixed(2)+'×')],
        ['Pagamento',paymentText(row)],
        ['Horário',formatTime(row?.created_at)||'—']
      ];
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
        const items=fields(row);
        return '<article class="aviator-my-history-row is-'+m.kind+'" data-bet-id="'+esc(row?.id)+'">'+
          '<div class="aviator-my-history-head">'+
            '<span class="aviator-my-history-icon" aria-hidden="true">'+m.icon+'</span>'+
            '<strong>'+m.label+'</strong>'+
          '</div>'+
          '<dl class="aviator-my-history-fields">'+
            items.map(([label,value])=>
              '<div class="aviator-my-history-field">'+
                '<dt>'+esc(label)+'</dt>'+
                '<dd>'+esc(value)+'</dd>'+
              '</div>'
            ).join('')+
          '</dl>'+
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
