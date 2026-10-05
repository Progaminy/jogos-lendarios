(()=>{
'use strict';
const K='jl_player_token';
function freeRoute(name,args={}){
  let u;
  try{u=new URL(location.href)}catch{return{name,args}}
  if(u.searchParams.get('mode')!=='free')return{name,args};
  const path=String(u.pathname||'').toLowerCase();
  if(name==='jl_check_funds')return{local:{ok:true,balance_confirmed:true,shortfall:0,redirect_to_deposit:false}};
  if(path.endsWith('/ludo.html')){
    if(name==='jl_ludo_create_room')return{name:'jl_ludo_create_free_room',args:{p_token:args.p_token,p_player_count:args.p_player_count,p_mode:args.p_mode,p_is_public:args.p_is_public,p_rules:args.p_rules}};
    if(name==='jl_ludo_create_from_board_invite')return{name:'jl_ludo_create_free_from_board_invite',args:{p_token:args.p_token,p_board_invite:args.p_board_invite,p_rules:args.p_rules}};
    if(name==='jl_ludo_public_challenges')return{name:'jl_ludo_free_public_challenges',args:{p_token:args.p_token}};
    if(name==='jl_ludo_join_public_room')return{name:'jl_ludo_join_free_public_room',args:{p_token:args.p_token,p_code:args.p_code}};
    if(name==='jl_ludo_accept_public_challenge')return{name:'jl_ludo_accept_free_public_challenge',args:{p_token:args.p_token,p_code:args.p_code}};
    if(name==='jl_ludo_rematch_v2')return{name:'jl_ludo_free_rematch',args:{p_token:args.p_token,p_room:args.p_room,p_mode:args.p_mode,p_rules:args.p_rules}};
  }
  if(path.endsWith('/dama.html')){
    if(name==='jl_dama_create_room')return{name:'jl_dama_create_free_room',args:{p_token:args.p_token,p_turn_seconds:args.p_turn_seconds,p_host_color:args.p_host_color,p_first_player:args.p_first_player,p_is_public:args.p_is_public}};
    if(name==='jl_dama_create_from_board_invite')return{name:'jl_dama_create_free_from_board_invite',args:{p_token:args.p_token,p_board_invite:args.p_board_invite,p_turn_seconds:args.p_turn_seconds,p_host_color:args.p_host_color,p_first_player:args.p_first_player}};
    if(name==='jl_dama_public_rooms')return{name:'jl_dama_free_public_rooms',args:{p_token:args.p_token}};
    if(name==='jl_dama_join_room')return{name:'jl_dama_join_free_room',args:{p_token:args.p_token,p_code:args.p_code}};
    if(name==='jl_dama_rematch')return{name:'jl_dama_free_rematch',args:{p_token:args.p_token,p_room:args.p_room,p_turn_seconds:args.p_turn_seconds,p_host_color:args.p_host_color,p_first_player:args.p_first_player,p_is_public:args.p_is_public}};
  }
  return{name,args};
}
async function rpc(name,args={},options={}){
  const routed=freeRoute(name,args);
  if(routed.local)return routed.local;
  name=routed.name;args=routed.args;
  const c=window.JL_CONFIG||{};
  if(!c.supabaseUrl||!c.supabaseKey)throw new Error('Configuração do Supabase ausente.');
  const r=await fetch(`${c.supabaseUrl}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:c.supabaseKey,Authorization:`Bearer ${c.supabaseKey}`,'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify(args),keepalive:Boolean(options.keepalive),signal:options.signal});
  const raw=await r.text();let p=null;
  try{p=raw?JSON.parse(raw):null}catch{p=raw}
  if(!r.ok){
    const m=p?.message||p?.error||p?.hint||`Erro ${r.status}`,t=typeof args?.p_token==='string'?args.p_token:'',a=window.JLSession?.getPlayerToken?.()||localStorage.getItem(K)||'';
    if(t&&a===t&&/sess[aã]o.*(?:inv[aá]lida|expirada)/i.test(m))window.JLSession?.setPlayerToken?window.JLSession.setPlayerToken(''):localStorage.removeItem(K);
    throw new Error(m);
  }
  return p;
}
window.JLApi=Object.freeze({rpc});
if(!document.querySelector('script[data-jl-free-access-ui]')){
  const s=document.createElement('script');
  s.src='./free-access-ui.js?v=20261005-1';
  s.defer=true;
  s.dataset.jlFreeAccessUi='1';
  document.head.appendChild(s);
}
})();
