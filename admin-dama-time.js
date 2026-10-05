(()=>{
'use strict';
const ID='adminDamaTimeCard',TK='jl_admin_token';
let busy=false;
const token=()=>window.JLSession?.getAdminToken?.()||sessionStorage.getItem(TK)||'';
async function rpc(name,args={}){
  const c=window.JL_CONFIG||{};
  const r=await fetch(`${c.supabaseUrl}/rest/v1/rpc/${name}`,{
    method:'POST',
    headers:{apikey:c.supabaseKey,Authorization:`Bearer ${c.supabaseKey}`,'Content-Type':'application/json',Accept:'application/json'},
    body:JSON.stringify(args),cache:'no-store'
  });
  const raw=await r.text();let p=null;
  try{p=raw?JSON.parse(raw):null}catch{p=raw}
  if(!r.ok)throw new Error(p?.message||p?.error||p?.hint||`Erro ${r.status}`);
  return p;
}
function fmt(seconds){
  const s=Math.max(0,Math.trunc(Number(seconds)||0));
  if(s<60)return `${s} s`;
  const m=Math.floor(s/60),r=s%60;
  return r?`${m} min ${r} s`:`${m} min`;
}
function style(){
  if(document.getElementById('adminDamaTimeStyle'))return;
  const s=document.createElement('style');
  s.id='adminDamaTimeStyle';
  s.textContent=`#${ID}{margin-top:16px}#${ID} .jl-dt-fields{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin:12px 0}#${ID} .jl-dt-preview{display:block;margin-top:5px;opacity:.72;font-size:.78rem}#${ID} .jl-dt-note{opacity:.72;font-size:.86rem}#${ID} .jl-dt-status{min-height:20px;margin-top:8px}.jl-dt-status.error{color:#ff8585}.jl-dt-status.success{color:#72f29a}@media(max-width:680px){#${ID} .jl-dt-fields{grid-template-columns:1fr}}`;
  document.head.appendChild(s);
}
function card(){
  let x=document.getElementById(ID);if(x)return x;
  const app=document.getElementById('adminApp');if(!app)return null;
  x=document.createElement('section');x.id=ID;x.className='card admin-card';
  x.innerHTML=`<div class="section-head"><div><p class="eyebrow">DAMA LENDÁRIA</p><h2>Tempos por jogada</h2></div><button id="jlDtRefresh" class="button ghost small" type="button">⟳</button></div><p class="jl-dt-note">Defina os dois tempos que os jogadores podem escolher ao criar uma partida ou revanche. Partidas já iniciadas mantêm o tempo com que começaram.</p><div class="jl-dt-fields"><label class="field"><span>Tempo 1 (segundos)</span><input id="jlDtOne" type="number" min="10" max="3600" step="1" inputmode="numeric"><small id="jlDtOnePreview" class="jl-dt-preview">—</small></label><label class="field"><span>Tempo 2 (segundos)</span><input id="jlDtTwo" type="number" min="10" max="3600" step="1" inputmode="numeric"><small id="jlDtTwoPreview" class="jl-dt-preview">—</small></label></div><button id="jlDtSave" class="button primary" type="button">Guardar tempos da Dama</button><div id="jlDtStatus" class="jl-dt-status" role="status" aria-live="polite"></div>`;
  app.appendChild(x);
  x.querySelector('#jlDtRefresh').addEventListener('click',()=>load(true));
  x.querySelector('#jlDtSave').addEventListener('click',save);
  x.querySelector('#jlDtOne').addEventListener('input',preview);
  x.querySelector('#jlDtTwo').addEventListener('input',preview);
  return x;
}
function status(m='',t=''){const e=document.getElementById('jlDtStatus');if(e){e.textContent=m;e.className=`jl-dt-status ${t}`.trim()}}
function preview(){
  const a=document.getElementById('jlDtOne'),b=document.getElementById('jlDtTwo');
  const ap=document.getElementById('jlDtOnePreview'),bp=document.getElementById('jlDtTwoPreview');
  if(ap)ap.textContent=a?.value?fmt(a.value):'—';
  if(bp)bp.textContent=b?.value?fmt(b.value):'—';
}
function apply(data){
  const a=document.getElementById('jlDtOne'),b=document.getElementById('jlDtTwo');
  if(a)a.value=String(data?.option_one_seconds??120);
  if(b)b.value=String(data?.option_two_seconds??180);
  preview();
}
async function load(show=false){
  if(busy)return;
  const t=token(),c=card();if(!c)return;
  if(!t){c.classList.add('hidden');return}
  c.classList.remove('hidden');busy=true;
  try{const d=await rpc('jl_admin_dama_time_settings',{p_token:t});apply(d);if(show)status('Tempos atualizados.','success')}
  catch(e){status(e.message,'error')}
  finally{busy=false}
}
async function save(){
  if(busy)return;
  const a=Math.trunc(Number(document.getElementById('jlDtOne')?.value));
  const b=Math.trunc(Number(document.getElementById('jlDtTwo')?.value));
  if(!Number.isInteger(a)||!Number.isInteger(b)||a<10||a>3600||b<10||b>3600)return status('Cada tempo deve ficar entre 10 e 3600 segundos.','error');
  if(a===b)return status('Os dois tempos devem ser diferentes.','error');
  busy=true;status('A guardar…');
  try{
    const d=await rpc('jl_admin_update_dama_time_settings',{p_token:token(),p_option_one_seconds:a,p_option_two_seconds:b});
    apply(d);status(`Guardado: ${fmt(d.option_one_seconds)} e ${fmt(d.option_two_seconds)}.`, 'success');
  }catch(e){status(e.message,'error')}
  finally{busy=false}
}
function boot(){style();if(!card())return setTimeout(boot,250);load();window.addEventListener('jl-admin-session-changed',()=>setTimeout(load,80));}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
})();
