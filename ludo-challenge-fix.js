(() => {
  'use strict';
  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const $ = (sel, root=document) => root.querySelector(sel);
  let busy = false;

  async function rpc(name,args={}){
    const token = localStorage.getItem(TOKEN_KEY);
    if(!token || !cfg.supabaseUrl || !cfg.supabaseKey) return null;
    const res = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`,{
      method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:`Bearer ${cfg.supabaseKey}`,'Content-Type':'application/json',Accept:'application/json'},
      body:JSON.stringify(args)
    });
    const text = await res.text();
    let data=null; try{data=text?JSON.parse(text):null}catch{data=text}
    if(!res.ok) throw new Error(data?.message||data?.hint||data?.error||`Erro ${res.status}`);
    return data;
  }

  function toast(msg,type=''){
    const el=$('#toast'); if(!el) return;
    el.textContent=msg; el.className=`toast show ${type}`;
    clearTimeout(toast.t); toast.t=setTimeout(()=>el.className='toast',3500);
  }

  function forceInitialTen(){
    for(const id of ['createBet','queueBet']){
      const el=document.getElementById(id);
      if(!el) continue;
      el.min='10'; el.step='1';
      if(!el.dataset.userChanged){ el.value='10'; }
      el.addEventListener('input',()=>{el.dataset.userChanged='1';},{once:true});
    }
    const re=document.querySelector('input[name="reentry_amount"]');
    if(re){re.min='10'; if(Number(re.value)<10||!re.value) re.value='10';}
  }

  function renderChallenges(rows, hasActiveRoom){
    const list=$('#publicChallengeList');
    if(!list) return;
    if(!Array.isArray(rows)||!rows.length){
      list.innerHTML='<div class="challenge-empty">Nenhum desafio público neste momento.</div>';
      return;
    }
    list.innerHTML=rows.map(c=>{
      const mode=c.mode==='partners'?'Parceiros 2×2':'Cada um por si';
      const place=c.play_location==='presential'?'Presencial':'Online';
      const dice=Number(c.dice_count||1);
      const disabled=hasActiveRoom?'disabled title="Saia da sua sala atual para entrar nesta"':'';
      const label=hasActiveRoom?'Já estás noutra sala':'Aceitar e entrar';
      return `<article class="challenge-card"><div><strong>${String(c.host_name||'Jogador')}</strong> · ${String(c.host_code||'')}<small>${String(c.code||'')} · ${c.joined_count}/${c.player_count} jogadores · ${Number(c.bet_amount||0).toLocaleString('pt-MZ')} MZN</small><div class="challenge-tags"><span>${mode}</span><span>${place}</span><span>${dice} ${dice===1?'dado':'dados'}</span><span>${c.open_slots} vaga(s)</span></div></div><button class="challenge-accept" data-accept-public-challenge="${String(c.code||'')}" ${disabled}>${label}</button></article>`;
    }).join('');
  }

  async function refreshAllChallenges(){
    try{
      const token=localStorage.getItem(TOKEN_KEY); if(!token) return;
      const status=await rpc('jl_ludo_my_status',{p_token:token});
      const rows=await rpc('jl_ludo_public_challenges',{p_token:token});
      renderChallenges(rows||[],Boolean(status?.active_room_id));
    }catch(_){}
  }

  function bindQueroJogar(){
    const form=$('#queueForm'); const button=$('#queueButton');
    if(!form||!button||form.dataset.challengeFixBound==='1') return;
    form.dataset.challengeFixBound='1';
    button.textContent='📣 Quero jogar · anunciar para todos';
    form.addEventListener('submit',async e=>{
      e.preventDefault(); e.stopImmediatePropagation();
      if(busy) return;
      const token=localStorage.getItem(TOKEN_KEY); if(!token) return;
      busy=true; button.disabled=true; const old=button.textContent; button.textContent='Abrindo sala…';
      try{
        try{await rpc('jl_ludo_leave_queue',{p_token:token});}catch(_){}
        const roomState=await rpc('jl_ludo_create_room',{
          p_token:token,
          p_player_count:Number($('#queuePlayers')?.value||4),
          p_bet_amount:Number($('#queueBet')?.value||10),
          p_mode:$('#queueMode')?.value||'solo',
          p_is_public:true,
          p_rules:{}
        });
        const roomId=roomState?.room?.id;
        if(roomId) await rpc('jl_ludo_rebroadcast_challenge',{p_token:token,p_room:roomId});
        sessionStorage.setItem('jl_public_challenge_created','1');
        location.reload();
      }catch(err){toast(err.message,'error'); button.disabled=false; button.textContent=old; busy=false;}
    },true);
  }

  function init(){
    forceInitialTen();
    bindQueroJogar();
    refreshAllChallenges();
    setInterval(refreshAllChallenges,2000);
  }

  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init,{once:true}); else init();
})();
