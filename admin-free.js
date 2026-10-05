(()=>{
'use strict';
const $=id=>document.getElementById(id),cfg=window.JL_CONFIG||{};
const tok=()=>window.JLSession?.getAdminToken?.()||sessionStorage.getItem('jl_admin_token')||'';
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=v=>v?new Date(v).toLocaleDateString('pt-MZ'):'—';
async function rpc(name,args){const r=await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:`Bearer ${cfg.supabaseKey}`,'Content-Type':'application/json'},body:JSON.stringify(args)});const raw=await r.text();let x=null;try{x=raw?JSON.parse(raw):null}catch{x=raw}if(!r.ok)throw new Error(x?.message||x?.error||`Erro ${r.status}`);return x}
function card(){
  if($('freeAccessAdmin'))return $('freeAccessAdmin');
  const root=$('adminApp');if(!root)return null;
  const s=document.createElement('section');s.id='freeAccessAdmin';s.className='card admin-card';
  s.innerHTML=`<div class="section-head"><div><p class="eyebrow">FREE</p><h2>Mensalidade e jogos</h2></div><button id="freeRefresh" class="button ghost small" type="button">⟳</button></div><div class="admin-actions"><label class="field"><span>MZN / mês</span><input id="freePrice" type="number" min="0" step="0.01" value="10"></label><label class="field"><span>FREE</span><select id="freeEnabled"><option value="true">Ativo</option><option value="false">Desativado</option></select></label><button id="freeSave" class="button primary" type="button">Guardar</button></div><div id="freeGames" class="request-list" style="margin-top:12px"></div><p class="eyebrow" style="margin-top:18px">PENDENTES</p><div id="freePending" class="request-list"></div><p class="eyebrow" style="margin-top:18px">ATIVOS</p><div id="freeMembers" class="request-list"></div>`;
  root.insertBefore(s,$('ludoLiveAdmin')||root.firstChild);
  s.addEventListener('click',click);$('freeRefresh').onclick=load;$('freeSave').onclick=save;
  return s;
}
function render(d){
  $('freePrice').value=d?.settings?.price??10;$('freeEnabled').value=String(d?.settings?.enabled!==false);
  const games=d?.games||[];
  $('freeGames').innerHTML=games.map(g=>`<div class="request-row" data-free-game-row="${esc(g.game_key)}"><div><strong>${esc(g.label)}</strong><br><small>${esc(g.game_key)}</small></div><label class="field"><span>FREE</span><select data-g-free><option value="true" ${g.free_enabled?'selected':''}>Sim</option><option value="false" ${!g.free_enabled?'selected':''}>Não</option></select></label><label class="field"><span>APOSTAS</span><select data-g-bet><option value="true" ${g.bet_enabled?'selected':''}>Sim</option><option value="false" ${!g.bet_enabled?'selected':''}>Não</option></select></label><label class="field"><span>Jogos grátis</span><input data-g-limit type="number" min="0" max="1000" step="1" value="${Number(g.trial_limit||0)}"></label><button class="button primary small" data-g-save="${esc(g.game_key)}" type="button">Guardar</button></div>`).join('');
  const p=d?.pending||[];
  $('freePending').innerHTML=p.length?p.map(x=>`<div class="request-row"><div><strong>${esc(x.name)}</strong><br><small>${esc(x.phone||'')} · ${Number(x.months||1)} ${Number(x.months||1)===1?'mês':'meses'}</small></div><strong>${Number(x.amount||0)} MZN</strong><div class="row-actions"><button class="button danger small" data-r="${x.id}" data-d="rejected">Rejeitar</button><button class="button success small" data-r="${x.id}" data-d="approved">Aprovar</button></div></div>`).join(''):'<div class="empty">Nenhum pedido.</div>';
  const m=d?.members||[];
  $('freeMembers').innerHTML=m.length?m.map(x=>`<div class="request-row"><div><strong>${esc(x.name)}</strong><br><small>${esc(x.phone||'')} · até ${fmt(x.valid_until)}</small></div><strong>${x.paid_active?'ATIVO':x.active?'EXPIRADO':'DESATIVADO'}</strong><div class="row-actions"><button class="button ${x.active?'danger':'success'} small" data-p="${x.player_id}" data-a="${!x.active}">${x.active?'Desativar':'Ativar'}</button></div></div>`).join(''):'<div class="empty">Nenhum acesso pago.</div>';
}
async function load(){if(!tok())return;card();try{render(await rpc('jl_admin_free_access_overview',{p_token:tok()}))}catch(e){console.warn('FREE admin',e)}}
async function save(){try{render(await rpc('jl_admin_free_access_settings',{p_token:tok(),p_price:Number($('freePrice').value||0),p_enabled:$('freeEnabled').value==='true'}))}catch(e){alert(e.message)}}
async function click(e){
  const r=e.target.closest('[data-r]'),p=e.target.closest('[data-p]'),g=e.target.closest('[data-g-save]');
  try{
    if(r)render(await rpc('jl_admin_free_access_review',{p_token:tok(),p_request_id:r.dataset.r,p_decision:r.dataset.d}));
    if(p)render(await rpc('jl_admin_free_access_set_player',{p_token:tok(),p_player_id:p.dataset.p,p_active:p.dataset.a==='true'}));
    if(g){const row=g.closest('[data-free-game-row]');render(await rpc('jl_admin_free_game_settings',{p_token:tok(),p_game:g.dataset.gSave,p_free_enabled:row.querySelector('[data-g-free]').value==='true',p_bet_enabled:row.querySelector('[data-g-bet]').value==='true',p_trial_limit:Math.trunc(Number(row.querySelector('[data-g-limit]').value||0))}))}
  }catch(x){alert(x.message)}
}
function init(){card();load()}
window.addEventListener('jl-admin-session-changed',()=>setTimeout(load,50));document.readyState==='loading'?document.addEventListener('DOMContentLoaded',init,{once:true}):init();
})();
