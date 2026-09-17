(() => {
  'use strict';
  if (window.__JL_PUBLIC_CHALLENGES_V3__) return;
  window.__JL_PUBLIC_CHALLENGES_V3__ = true;

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const $ = (s,r=document)=>r.querySelector(s);
  let busy=false, timer=null;

  async function rpc(name,args={}){
    const token=localStorage.getItem(TOKEN_KEY);
    if(!token||!cfg.supabaseUrl||!cfg.supabaseKey) return null;
    const res=await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:`Bearer ${cfg.supabaseKey}`,'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify(args)});
    const text=await res.text(); let data=null; try{data=text?JSON.parse(text):null}catch{data=text}
    if(!res.ok) throw new Error(data?.message||data?.hint||data?.error||`Erro ${res.status}`);
    return data;
  }

  function toast(msg,type=''){
    const el=$('#toast'); if(!el) return;
    el.textContent=msg; el.className=`toast show ${type}`;
    clearTimeout(toast.t); toast.t=setTimeout(()=>el.className='toast',4000);
  }

  function setInitialValues(){
    for(const id of ['createBet','queueBet']){
      const el=document.getElementById(id); if(!el) continue;
      el.min='10'; el.step='1';
      if(!el.dataset.jlUserChanged){el.value='10';el.defaultValue='10';}
      el.addEventListener('input',()=>el.dataset.jlUserChanged='1',{once:true});
    }
    const re=document.querySelector('input[name="reentry_amount"]');
    if(re){re.min='10';if(!re.value||Number(re.value)<10)re.value='10';}
  }

  function ensurePanel(){
    let p=$('#globalChallengePanel'); if(p) return p;
    const main=$('main.shell'); if(!main) return null;
    p=document.createElement('section'); p.id='globalChallengePanel'; p.className='panel hidden';
    p.innerHTML='<div class="gc-head"><div><p class="eyebrow">CHAMADAS DE LUDO</p><h2>Alguém quer jogar agora</h2><p>Convites públicos atualizados automaticamente.</p></div><span class="gc-live">AO VIVO</span></div><div id="globalChallengeList"><div class="gc-empty">Procurando desafios…</div></div><div class="gc-note">Quem clica “Quero jogar” entra na própria sala e anuncia para todos por 60 segundos.</div>';
    const hero=$('.hero',main); if(hero)hero.after(p); else main.prepend(p); return p;
  }

  function ensureStyles(){
    if($('#jlChallengeV3Styles'))return;
    const s=document.createElement('style');s.id='jlChallengeV3Styles';s.textContent=`#globalChallengePanel{margin:14px 0 18px;padding:18px!important;border:1px solid rgba(244,181,31,.28)!important;background:linear-gradient(135deg,rgba(244,181,31,.09),rgba(15,24,38,.98))!important}#globalChallengePanel.hidden{display:none!important}.gc-head{display:flex;justify-content:space-between;gap:12px;margin-bottom:12px}.gc-head h2{margin:0}.gc-head p{margin:3px 0;color:#91a4bd}.gc-live{align-self:start;padding:6px 9px;border-radius:999px;border:1px solid rgba(78,213,138,.28);background:rgba(78,213,138,.08);color:#8df1bb;font-size:.7rem;font-weight:900}#globalChallengeList{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:9px}.gc-card{display:grid;grid-template-columns:1fr auto;gap:12px;align-items:center;padding:13px;border:1px solid rgba(255,255,255,.08);border-radius:13px;background:rgba(255,255,255,.035)}.gc-card small{display:block;margin-top:4px;color:#91a4bd}.gc-tags{display:flex;flex-wrap:wrap;gap:5px;margin-top:7px}.gc-tags span{font-size:.65rem;font-weight:800;color:#ffda6a;border:1px solid rgba(244,181,31,.18);background:rgba(244,181,31,.07);border-radius:999px;padding:3px 6px}.gc-accept{border:0;border-radius:10px;background:#f4b51f;color:#181108;padding:10px 12px;font-weight:1000;cursor:pointer}.gc-accept:disabled{opacity:.45;cursor:not-allowed}.gc-empty{grid-column:1/-1;padding:12px;color:#91a4bd;text-align:center}.gc-note{margin-top:9px;color:#c8d2df;font-size:.75rem}.room-broadcast{background:rgba(244,181,31,.1)!important;color:#ffda6a!important;border-color:rgba(244,181,31,.34)!important}@media(max-width:760px){#globalChallengeList{grid-template-columns:1fr}.gc-card{grid-template-columns:1fr}.gc-accept{width:100%}}`;
    document.head.appendChild(s);
  }

  function render(rows,activeRoom){
    const panel=ensurePanel(),list=$('#globalChallengeList'); if(!panel||!list)return;
    const arr=Array.isArray(rows)?rows:[]; panel.classList.toggle('hidden',arr.length===0);
    if(!arr.length){list.innerHTML='<div class="gc-empty">Nenhum convite público ativo.</div>';return;}
    list.innerHTML=arr.map(c=>{const d=Number(c.dice_count||1);const blocked=Boolean(activeRoom);return `<article class="gc-card"><div><strong>${String(c.host_name||'Jogador')} · ${String(c.host_code||'')}</strong><small>${String(c.code||'')} · ${c.joined_count}/${c.player_count} jogadores · ${Number(c.bet_amount||0).toLocaleString('pt-MZ')} MZN</small><div class="gc-tags"><span>${c.mode==='partners'?'Parceiros 2×2':'Cada um por si'}</span><span>${c.play_location==='presential'?'Presencial':'Online'}</span><span>${d} ${d===1?'dado':'dados'}</span><span>${c.open_slots} vaga(s)</span></div></div><button class="gc-accept" data-accept-public-challenge="${String(c.code||'')}" ${blocked?'disabled':''}>${blocked?'Saia da sua sala para entrar':'Aceitar e entrar'}</button></article>`}).join('');
  }

  async function refresh(){
    const token=localStorage.getItem(TOKEN_KEY); if(!token)return;
    try{
      const [status,rows]=await Promise.all([rpc('jl_ludo_my_status',{p_token:token}),rpc('jl_ludo_public_challenges',{p_token:token})]);
      render(rows||[],status?.active_room_id||null);
      if(status?.active_room_id) await ensureBroadcast(status.active_room_id);
    }catch(_){}
  }

  async function ensureBroadcast(roomId){
    const token=localStorage.getItem(TOKEN_KEY); if(!token||!roomId)return;
    try{
      const st=await rpc('jl_ludo_room_state',{p_token:token,p_room:roomId}); const r=st?.room;
      if(!r||r.host_id!==st?.identity?.player_id||!r.is_public||!['waiting','negotiating'].includes(r.status))return;
      if((st.players||[]).filter(p=>p.status!=='left').length>=Number(r.player_count||0))return;
      const host=$('#ludoQuickBar .ludo-quick-actions')||$('.room-actions'); if(!host||$('#broadcastEveryone',host))return;
      const b=document.createElement('button');b.id='broadcastEveryone';b.type='button';b.className='room-broadcast';b.textContent='📣 Convidar todos';
      b.onclick=async()=>{if(busy)return;busy=true;b.disabled=true;try{await rpc('jl_ludo_rebroadcast_challenge',{p_token:token,p_room:r.id});toast('Convite enviado para todos por 60 segundos.','success');await refresh()}catch(e){toast(e.message,'error')}finally{busy=false;b.disabled=false}};
      host.prepend(b);
    }catch(_){}
  }

  function bindQueroJogar(){
    const form=$('#queueForm'),btn=$('#queueButton'); if(!form||!btn||form.dataset.jlV3Bound)return;
    form.dataset.jlV3Bound='1';btn.textContent='📣 Quero jogar · convidar todos';
    const info=$('#queueStatus');if(info){info.classList.remove('hidden');info.innerHTML='Valor inicial <strong>10 MZN</strong>. Pode aumentar antes de lançar. O convite fica visível para todos por 60 segundos.'}
    form.addEventListener('submit',async e=>{e.preventDefault();e.stopImmediatePropagation();if(busy)return;const token=localStorage.getItem(TOKEN_KEY);if(!token)return;busy=true;btn.disabled=true;const old=btn.textContent;btn.textContent='Abrindo sala…';try{try{await rpc('jl_ludo_leave_queue',{p_token:token})}catch(_){}const st=await rpc('jl_ludo_create_room',{p_token:token,p_player_count:Number($('#queuePlayers')?.value||4),p_bet_amount:Number($('#queueBet')?.value||10),p_mode:$('#queueMode')?.value||'solo',p_is_public:true,p_rules:{}});const roomId=st?.room?.id;if(!roomId)throw new Error('Sala criada sem identificação.');await rpc('jl_ludo_rebroadcast_challenge',{p_token:token,p_room:roomId});sessionStorage.setItem('jl_public_v3_created','1');location.reload()}catch(err){toast(err.message,'error');btn.textContent=old;btn.disabled=false;busy=false}},true);
  }

  function bindAccept(){
    document.addEventListener('click',async e=>{const b=e.target.closest('[data-accept-public-challenge]');if(!b||b.disabled||busy)return;const token=localStorage.getItem(TOKEN_KEY);if(!token)return;busy=true;b.disabled=true;const old=b.textContent;b.textContent='Entrando…';try{await rpc('jl_ludo_join_public_room',{p_token:token,p_code:b.dataset.acceptPublicChallenge});sessionStorage.setItem('jl_public_v3_joined','1');location.reload()}catch(err){toast(err.message,'error');b.disabled=false;b.textContent=old;busy=false}});
  }

  function messages(){if(sessionStorage.getItem('jl_public_v3_created')){sessionStorage.removeItem('jl_public_v3_created');setTimeout(()=>toast('Sala aberta. O convite está visível para todos por 60 segundos.','success'),400)}if(sessionStorage.getItem('jl_public_v3_joined')){sessionStorage.removeItem('jl_public_v3_joined');setTimeout(()=>toast('Entrou na sala. O tabuleiro está pronto.','success'),400)}}

  function init(){ensureStyles();setInitialValues();ensurePanel();bindQueroJogar();bindAccept();messages();refresh();clearInterval(timer);timer=setInterval(refresh,2000)}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init,{once:true});else init();
})();
