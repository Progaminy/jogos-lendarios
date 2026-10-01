(()=>{
'use strict';
const K='jl_player_token';
async function rpc(name,args={},options={}){
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
})();
