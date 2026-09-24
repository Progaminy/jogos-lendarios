(() => {
  'use strict';
  const cfg=window.JL_CONFIG||{},TOKEN_KEY='jl_admin_token',$=id=>document.getElementById(id);
  const token=()=>localStorage.getItem(TOKEN_KEY)||'';
  const money=v=>Number(v||0).toLocaleString('pt-MZ',{minimumFractionDigits:2,maximumFractionDigits:2});
  const toLocalInput=date=>new Date(date.getTime()-date.getTimezoneOffset()*60000).toISOString().slice(0,16);
  async function rpc(name,args={}){
    const r=await fetch(cfg.supabaseUrl+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:'Bearer '+cfg.supabaseKey,'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify(args)});
    const raw=await r.text();let data=null;try{data=raw?JSON.parse(raw):null}catch{data=raw}
    if(!r.ok)throw new Error(data?.message||data?.hint||data?.error||('Erro '+r.status));return data;
  }
  function toast(msg,type=''){const el=$('toast');if(!el)return;el.textContent=msg;el.className=('toast show '+type).trim();clearTimeout(toast.t);toast.t=setTimeout(()=>el.className='toast',4500);}
  function setWindow(type,hours){
    const startInput=$(type+'ScheduleStart'),endInput=$(type+'ScheduleEnd');if(!startInput||!endInput)return;
    let start=startInput.value?new Date(startInput.value):null;
    if(!start||Number.isNaN(start.getTime())||start.getTime()<=Date.now()+10000){start=new Date();start.setMinutes(0,0,0);start.setHours(start.getHours()+1);startInput.value=toLocalInput(start);}
    endInput.value=toLocalInput(new Date(start.getTime()+hours*3600000));
  }
  function ensurePanel(){
    const app=$('adminApp');if(!app||$('adminFinancialPower'))return;
    const s=document.createElement('section');s.id='adminFinancialPower';s.className='card admin-card';
    s.innerHTML='<div class="section-head"><div><p class="eyebrow">CONTROLO GERAL</p><h2>Resumo financeiro da plataforma</h2></div><button id="resetFinancialCounters" class="button danger small" type="button">Zerar contadores dos jogos</button></div><p class="muted-text">Zerar cria um novo ponto de partida visual. Não apaga saldos, apostas nem histórico financeiro.</p><div class="admin-grid"><div class="card metric"><span>Saldo dos utilizadores</span><strong id="metricUserBalance">—</strong><small>MZN</small></div><div class="card metric"><span>Número</span><strong id="metricNumberTotal">—</strong><small>MZN desde o último zero</small></div><div class="card metric"><span>Dupla</span><strong id="metricPairTotal">—</strong><small>MZN desde o último zero</small></div><div class="card metric"><span>Ludo</span><strong id="metricLudoTotal">—</strong><small>MZN desde o último zero</small></div></div><div class="card metric" style="margin-top:12px"><span>Total movimentado nos jogos</span><strong id="metricGamesTotal">—</strong><small id="metricSince">—</small></div>';
    app.prepend(s);
    $('resetFinancialCounters').addEventListener('click',async()=>{
      if(!confirm('Zerar apenas os contadores administrativos dos jogos? Saldos e histórico serão preservados.'))return;
      const pin=prompt('Digite o PIN administrativo para confirmar:');if(pin===null)return;
      try{const r=await rpc('jl_admin_reset_financial_counters',{p_token:token(),p_admin_pin:pin});toast(r?.message||'Contadores zerados.','success');await refreshFinancial();}catch(e){toast(e.message,'error');}
    });
  }
  async function refreshFinancial(){
    if(!token()||document.visibilityState!=='visible')return;
    try{
      const f=await rpc('jl_admin_financial_summary',{p_token:token()});
      if($('metricUserBalance'))$('metricUserBalance').textContent=money(f.user_balance_total);
      if($('metricNumberTotal'))$('metricNumberTotal').textContent=money(f.number_total);
      if($('metricPairTotal'))$('metricPairTotal').textContent=money(f.pair_total);
      if($('metricLudoTotal'))$('metricLudoTotal').textContent=money(f.ludo_total);
      if($('metricGamesTotal'))$('metricGamesTotal').textContent=money(f.games_total);
      if($('metricSince'))$('metricSince').textContent='Desde '+new Date(f.since).toLocaleString('pt-MZ');
    }catch{}
  }
  async function refreshExposure(){
    if(!token()||document.visibilityState!=='visible')return;
    try{const data=await rpc('jl_admin_dashboard',{p_token:token()});for(const type of ['number','pair']){const f=data?.games?.[type]?.financial||{};const a=$(type+'TotalStaked'),b=$(type+'MinExposure'),c=$(type+'HouseFloor'),d=$(type+'SafeOutcomes');if(a)a.textContent=money(f.total_staked);if(b)b.textContent=money(f.min_exposure);if(c)c.textContent=money(f.house_floor_at_min);if(d)d.textContent=String(f.safe_outcomes??0)+'/'+String(f.outcome_count??0);}}catch{}
  }
  $('numberQuick12')?.addEventListener('click',()=>setWindow('number',12));
  $('numberQuick24')?.addEventListener('click',()=>setWindow('number',24));
  $('pairQuick12')?.addEventListener('click',()=>setWindow('pair',12));
  $('pairQuick24')?.addEventListener('click',()=>setWindow('pair',24));
  $('refreshAdmin')?.addEventListener('click',()=>setTimeout(()=>{refreshExposure();refreshFinancial();},150));
  $('playersList')?.addEventListener('click',async e=>{
    const force=e.target.closest('[data-force-logout]'),del=e.target.closest('[data-delete-player]');
    if(force){if(!confirm('Encerrar todas as sessões de '+(force.dataset.name||'este jogador')+'?'))return;try{const r=await rpc('jl_admin_force_logout_player',{p_token:token(),p_player_id:force.dataset.forceLogout});toast(r?.message||'Sessões encerradas.','success');}catch(err){toast(err.message,'error');}return;}
    if(del){if(!confirm('Eliminar a conta de '+(del.dataset.name||'este jogador')+'? O histórico financeiro será preservado e anonimizado.'))return;const pin=prompt('Digite o PIN administrativo para confirmar a eliminação:');if(pin===null)return;try{const r=await rpc('jl_admin_delete_player',{p_token:token(),p_player_id:del.dataset.deletePlayer,p_admin_pin:pin});toast(r?.message||'Conta eliminada.','success');$('refreshAdmin')?.click();}catch(err){toast(err.message,'error');}}
  });
  function init(){ensurePanel();refreshExposure();refreshFinancial();setInterval(()=>{refreshExposure();refreshFinancial();},15000);}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init,{once:true});else init();
})();
