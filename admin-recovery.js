(() => {
  'use strict';
  const cfg=window.JL_CONFIG||{};
  const TOKEN_KEY='jl_admin_token';
  const $=id=>document.getElementById(id);
  let timer=null;

  function token(){return localStorage.getItem(TOKEN_KEY)||'';}
  function esc(v){return String(v??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));}
  function dt(v){return v?new Date(v).toLocaleString('pt-MZ',{dateStyle:'short',timeStyle:'short'}):'—';}

  async function rpc(name,args={}){
    const r=await fetch(cfg.supabaseUrl+'/rest/v1/rpc/'+name,{
      method:'POST',
      headers:{apikey:cfg.supabaseKey,Authorization:'Bearer '+cfg.supabaseKey,'Content-Type':'application/json',Accept:'application/json'},
      body:JSON.stringify(args)
    });
    const raw=await r.text();let data=null;try{data=raw?JSON.parse(raw):null}catch{data=raw}
    if(!r.ok)throw new Error((data&&data.message)||(data&&data.hint)||(data&&data.error)||('Erro '+r.status));
    return data;
  }

  async function approveSend(id){
    const r=await fetch(cfg.supabaseUrl+'/functions/v1/jogos-recovery/approve-send',{
      method:'POST',
      headers:{apikey:cfg.supabaseKey,Authorization:'Bearer '+token(),'Content-Type':'application/json',Accept:'application/json'},
      body:JSON.stringify({requestId:id})
    });
    const raw=await r.text();let data=null;try{data=raw?JSON.parse(raw):null}catch{data=raw}
    if(!r.ok)throw new Error((data&&data.error)||(data&&data.message)||'Não foi possível enviar o código.');
    return data;
  }

  function stateLabel(status){
    return ({
      pending_admin:'Aguardando confirmação',
      sending:'A enviar',
      code_sent:'Código enviado',
      rejected:'Rejeitado',
      completed:'Concluído',
      expired:'Expirado',
      cancelled:'Cancelado'
    })[status]||status;
  }

  function rowHtml(r){
    const actions=r.status==='pending_admin'
      ? '<button class="button success small" data-recovery-send="'+esc(r.id)+'">Confirmar identidade e enviar código</button>'+
        '<button class="button danger small" data-recovery-reject="'+esc(r.id)+'">Rejeitar</button>'
      : '';
    const sent=r.sent_at?' · enviado: '+esc(dt(r.sent_at)):'';
    const expires=r.otp_expires_at?' · expira: '+esc(dt(r.otp_expires_at)):'';
    const badgeClass=r.status==='pending_admin'?'warning':(r.status==='code_sent'?'success':'muted');
    return '<div class="recovery-admin-row">'+
      '<div>'+
        '<div class="recovery-admin-head"><strong>'+esc(r.name)+'</strong><span class="badge '+badgeClass+'">'+esc(stateLabel(r.status))+'</span></div>'+
        '<div class="recovery-admin-contact"><span>📞 '+esc(r.phone)+'</span><span>✉️ '+esc(r.recovery_email)+'</span></div>'+
        '<small>Pedido: '+esc(dt(r.requested_at))+sent+expires+'</small>'+
      '</div>'+
      '<div class="row-actions">'+actions+'</div>'+
    '</div>';
  }

  async function load(){
    if(!$('recoveryAdminList')||!token())return;
    try{
      const rows=await rpc('jl_admin_recovery_requests',{p_token:token()});
      const pending=rows.filter(r=>r.status==='pending_admin').length;
      $('recoveryAdminCount').textContent=String(pending);
      $('recoveryAdminList').innerHTML=rows.length?rows.map(rowHtml).join(''):'<div class="empty">Nenhum pedido de recuperação.</div>';
    }catch(err){
      $('recoveryAdminList').innerHTML='<div class="empty">'+esc(err.message)+'</div>';
    }
  }

  function toast(msg,type=''){
    const el=$('toast');if(!el)return;
    el.textContent=msg;el.className=('toast show '+type).trim();
    clearTimeout(toast.t);toast.t=setTimeout(()=>el.className='toast',4000);
  }

  function wire(){
    const list=$('recoveryAdminList');if(!list)return;
    list.addEventListener('click',async e=>{
      const send=e.target.closest('[data-recovery-send]');
      const reject=e.target.closest('[data-recovery-reject]');
      if(!send&&!reject)return;
      try{
        if(send){
          if(!confirm('Confirma que ligou para o contacto, confirmou a identidade do jogador e quer enviar o código de recuperação por email?'))return;
          send.disabled=true;send.textContent='A enviar…';
          const data=await approveSend(send.dataset.recoverySend);
          toast((data&&data.message)||'Código enviado.','success');
        }else{
          if(!confirm('Rejeitar este pedido de recuperação?'))return;
          await rpc('jl_admin_reject_recovery',{p_token:token(),p_request_id:reject.dataset.recoveryReject});
          toast('Pedido de recuperação rejeitado.','success');
        }
        await load();
      }catch(err){toast(err.message,'error');await load();}
    });
    $('refreshRecoveryAdmin')?.addEventListener('click',load);
    clearInterval(timer);timer=setInterval(()=>{if(token())load();},5000);
    load();
  }

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',wire,{once:true});else wire();
})();