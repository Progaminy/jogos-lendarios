(() => {
  'use strict';
  const cfg=window.JL_CONFIG||{};
  const TOKEN_KEY='jl_admin_token';
  const $=id=>document.getElementById(id);
  let data={players:[],recent_grants:[]};
  let timer=null;

  function token(){return localStorage.getItem(TOKEN_KEY)||'';}
  function esc(v){return String(v??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));}
  function money(v){return Number(v||0).toLocaleString('pt-MZ',{minimumFractionDigits:2,maximumFractionDigits:2});}
  function dt(v){return v?new Date(v).toLocaleString('pt-MZ',{dateStyle:'short',timeStyle:'short'}):'—';}
  function labelScope(v){return ({number:'Número Lendário',pair:'Dupla Lendária',both:'Número + Dupla'})[v]||v;}
  function labelType(v){return ({promotional:'Promocional',welcome:'Boas-vindas',loyalty:'Fidelidade',compensation:'Compensação',manual:'Manual'})[v]||v;}

  async function rpc(name,args={}){
    const r=await fetch(cfg.supabaseUrl+'/rest/v1/rpc/'+name,{
      method:'POST',
      headers:{apikey:cfg.supabaseKey,Authorization:'Bearer '+cfg.supabaseKey,'Content-Type':'application/json',Accept:'application/json'},
      body:JSON.stringify(args)
    });
    const raw=await r.text();let payload=null;try{payload=raw?JSON.parse(raw):null}catch{payload=raw}
    if(!r.ok)throw new Error(payload?.message||payload?.hint||payload?.error||('Erro '+r.status));
    return payload;
  }

  function toast(msg,type=''){
    const el=$('toast');if(!el)return;
    el.textContent=msg;el.className=('toast show '+type).trim();
    clearTimeout(toast.t);toast.t=setTimeout(()=>el.className='toast',4200);
  }

  function selectedIds(){
    return [...document.querySelectorAll('#bonusPlayerList input[data-bonus-player]:checked')].map(x=>x.dataset.bonusPlayer);
  }

  function renderPlayers(){
    const box=$('bonusPlayerList');if(!box)return;
    const q=($('bonusPlayerSearch')?.value||'').trim().toLowerCase();
    const rows=(data.players||[]).filter(p=>!String(p.phone||'').startsWith('deleted-')).filter(p=>!q||String(p.name||'').toLowerCase().includes(q)||String(p.phone||'').includes(q));
    box.innerHTML=rows.length?rows.map(p=>`
      <label class="bonus-player-row">
        <input type="checkbox" data-bonus-player="${esc(p.id)}">
        <span class="bonus-player-info">
          <strong>${esc(p.name)}</strong>
          <small>+${esc(p.phone)} · Saldo ${money(p.balance)} MZN</small>
        </span>
        <span class="bonus-player-balances">
          <small>Bónus total</small>
          <strong>${money(p.bonus_total)} MZN</strong>
        </span>
      </label>`).join(''):'<div class="empty">Nenhum jogador encontrado.</div>';
    updateSelectedCount();
  }

  function renderRecent(){
    const box=$('bonusRecentList');if(!box)return;
    const rows=data.recent_grants||[];
    box.innerHTML=rows.length?rows.map(r=>`
      <div class="request-row">
        <div><strong>${esc(r.name)}</strong><br><small>+${esc(r.phone)} · ${esc(labelType(r.bonus_type))} · ${esc(labelScope(r.game_scope))} · ${dt(r.created_at)}</small></div>
        <strong>${money(r.remaining_amount)} / ${money(r.original_amount)} MZN</strong>
        <span class="badge ${r.status==='active'?'success':'muted'}">${esc(r.status)}</span>
      </div>`).join(''):'<div class="empty">Ainda não há bónus distribuídos.</div>';
  }

  function updateSelectedCount(){
    const el=$('bonusSelectedCount');if(el)el.textContent=String(selectedIds().length);
  }

  async function load(silent=false){
    if(!$('bonusPlayerList')||!token())return;
    try{
      const selected=new Set(selectedIds());
      data=await rpc('jl_admin_bonus_overview',{p_token:token()});
      renderPlayers();
      document.querySelectorAll('#bonusPlayerList input[data-bonus-player]').forEach(x=>{if(selected.has(x.dataset.bonusPlayer))x.checked=true;});
      updateSelectedCount();
      renderRecent();
    }catch(err){if(!silent)toast(err.message,'error');}
  }

  function wire(){
    const form=$('bonusGrantForm');if(!form)return;
    $('bonusPlayerSearch')?.addEventListener('input',renderPlayers);
    $('bonusPlayerList')?.addEventListener('change',updateSelectedCount);
    $('bonusSelectAll')?.addEventListener('click',()=>{
      document.querySelectorAll('#bonusPlayerList input[data-bonus-player]').forEach(x=>x.checked=true);updateSelectedCount();
    });
    $('bonusClearAll')?.addEventListener('click',()=>{
      document.querySelectorAll('#bonusPlayerList input[data-bonus-player]').forEach(x=>x.checked=false);updateSelectedCount();
    });
    $('bonusRefresh')?.addEventListener('click',()=>load());
    form.addEventListener('submit',async e=>{
      e.preventDefault();
      const ids=selectedIds(),amount=Number($('bonusAmount').value);
      if(!ids.length)return toast('Selecione pelo menos um jogador.','error');
      if(!Number.isInteger(amount)||amount<1)return toast('O bónus deve ser um valor inteiro a partir de 1 MZN.','error');
      const btn=$('bonusGrantButton');btn.disabled=true;btn.textContent='A distribuir…';
      try{
        const result=await rpc('jl_admin_grant_bonus',{
          p_token:token(),
          p_player_ids:ids,
          p_game_scope:$('bonusGameScope').value,
          p_bonus_type:$('bonusType').value,
          p_amount:amount,
          p_note:$('bonusNote').value.trim()
        });
        toast(`Bónus distribuído a ${result.players} jogador(es). Total: ${money(result.total_amount)} MZN.`,'success');
        $('bonusNote').value='';
        await load(true);
      }catch(err){toast(err.message,'error');}
      finally{btn.disabled=false;btn.textContent='Distribuir bónus';}
    });

    load(true);
    clearInterval(timer);timer=setInterval(()=>{if(token()&&document.visibilityState==='visible')load(true);},20000);
  }

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',wire,{once:true});else wire();
})();