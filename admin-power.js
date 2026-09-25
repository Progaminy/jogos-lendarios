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
    s.innerHTML='<div class="section-head"><div><p class="eyebrow">VISÃO GERAL</p><h2>Dinheiro e jogadores</h2></div><button id="resetFinancialCounters" class="button danger small" type="button">Reiniciar contagem</button></div><p class="muted-text">Os valores acumulados e a lista de movimentos contam desde o último reinício. Dados anteriores não reaparecem ao atualizar. O saldo atual dos jogadores e as contas continuam intactos.</p><div class="admin-grid"><div class="card metric"><span>Jogadores ativos</span><strong id="metricPlayerCount">—</strong><small>contas</small></div><div class="card metric"><span>Valor total dos jogadores</span><strong id="metricPlayerBalance">—</strong><small>MZN em saldos</small></div><div class="card metric"><span>Comissão ganha no Ludo</span><strong id="metricLudoCommission">—</strong><small>MZN desde o reinício</small></div><div class="card metric"><span>Valor total da casa</span><strong id="metricHouseTotal">—</strong><small>MZN · resultado líquido</small></div></div><div class="admin-grid" style="margin-top:12px"><div class="card metric"><span>Apostado no Número</span><strong id="metricNumberTotal">—</strong><small>MZN</small></div><div class="card metric"><span>Apostado na Dupla</span><strong id="metricPairTotal">—</strong><small>MZN</small></div><div class="card metric"><span>Apostado no Ludo</span><strong id="metricLudoTotal">—</strong><small>MZN</small></div><div class="card metric"><span>Total movimentado</span><strong id="metricGamesTotal">—</strong><small id="metricSince">—</small></div></div>';
    app.prepend(s);
    $('resetFinancialCounters').addEventListener('click',async()=>{
      if(!confirm('Reiniciar a contagem acumulada? Os saldos, apostas, prémios e histórico serão preservados.'))return;
      const pin=prompt('Digite o PIN administrativo para confirmar:');if(pin===null)return;
      try{const r=await rpc('jl_admin_reset_financial_counters',{p_token:token(),p_admin_pin:pin});toast(r?.message||'Contagem reiniciada.','success');await refreshFinancial();}catch(e){toast(e.message,'error');}
    });
  }
  async function refreshFinancial(){
    if(!token()||document.visibilityState!=='visible')return;
    try{
      const f=await rpc('jl_admin_financial_summary',{p_token:token()});
      const nextResetAt=String(f.since||'');
      const previousResetAt=String(window.__JL_ADMIN_RESET_AT||'');
      window.__JL_ADMIN_RESET_AT=nextResetAt;
      if(nextResetAt&&nextResetAt!==previousResetAt)document.dispatchEvent(new CustomEvent('jl-admin-reset-since',{detail:{since:nextResetAt}}));
      if($('metricPlayerCount'))$('metricPlayerCount').textContent=String(f.player_count??0);
      if($('metricPlayerBalance'))$('metricPlayerBalance').textContent=money(f.player_balance_total??f.user_balance_total);
      if($('metricLudoCommission'))$('metricLudoCommission').textContent=money(f.ludo_commission);
      if($('metricHouseTotal'))$('metricHouseTotal').textContent=money(f.house_total);
      if($('metricNumberTotal'))$('metricNumberTotal').textContent=money(f.number_total);
      if($('metricPairTotal'))$('metricPairTotal').textContent=money(f.pair_total);
      if($('metricLudoTotal'))$('metricLudoTotal').textContent=money(f.ludo_total);
      if($('metricGamesTotal'))$('metricGamesTotal').textContent=money(f.games_total);
      if($('metricSince'))$('metricSince').textContent='Desde '+new Date(f.since).toLocaleString('pt-MZ');
    }catch{}
  }
  function ensureAuditPanel(){
    const app=$('adminApp');if(!app||$('adminAuditPanel'))return;
    const s=document.createElement('section');s.id='adminAuditPanel';s.className='card admin-card';
    s.innerHTML='<div class="section-head"><div><p class="eyebrow">AUDITORIA</p><h2>Histórico recente de ações</h2></div><button id="refreshAdminAudit" class="button ghost small" type="button">Atualizar histórico</button></div><div id="adminAuditList" class="request-list"><div class="empty">A carregar histórico…</div></div>';
    app.appendChild(s);
    $('refreshAdminAudit')?.addEventListener('click',refreshAudit);
  }
  const esc=v=>String(v??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  async function refreshAudit(){
    if(!token()||document.visibilityState!=='visible')return;
    const box=$('adminAuditList');if(!box)return;
    try{
      const rows=await rpc('jl_admin_recent_audit',{p_token:token(),p_limit:80});
      box.innerHTML=rows.length?rows.map(r=>'<div class="request-row"><div><strong>'+esc(r.action)+'</strong><br><small>'+new Date(r.created_at).toLocaleString('pt-MZ')+'</small></div><small style="max-width:58%;word-break:break-word">'+esc(JSON.stringify(r.details||{}))+'</small></div>').join(''):'<div class="empty">Nenhuma ação registada.</div>';
    }catch(e){box.innerHTML='<div class="empty">'+esc(e.message)+'</div>';}
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
  function init(){ensurePanel();ensureAuditPanel();refreshExposure();refreshFinancial();refreshAudit();setInterval(()=>{refreshExposure();refreshFinancial();},15000);setInterval(refreshAudit,30000);}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init,{once:true});else init();
})();
