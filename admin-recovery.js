(() => {
  'use strict';
  const cfg=window.JL_CONFIG||{}, TOKEN_KEY='jl_admin_token', $=id=>document.getElementById(id);
  let timer=null,emailConfigured=false;
  const token=()=>localStorage.getItem(TOKEN_KEY)||'';
  const esc=v=>String(v??'').replace(/[&<>'\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','\"':'&quot;'}[c]));
  const dt=v=>v?new Date(v).toLocaleString('pt-MZ',{dateStyle:'short',timeStyle:'short'}):'—';
  async function rpc(name,args={}){
    const r=await fetch(cfg.supabaseUrl+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:'Bearer '+cfg.supabaseKey,'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify(args)});
    const raw=await r.text();let data=null;try{data=raw?JSON.parse(raw):null}catch{data=raw}
    if(!r.ok)throw new Error(data?.message||data?.hint||data?.error||('Erro '+r.status));return data;
  }
  async function checkEmailHealth(){
    const box=$('recoveryEmailStatus');
    try{
      const r=await fetch(cfg.supabaseUrl+'/functions/v1/jogos-recovery/health',{headers:{Accept:'application/json'},cache:'no-store'});
      const data=await r.json();emailConfigured=Boolean(r.ok&&data?.emailConfigured);
      if(box){box.textContent=emailConfigured?'Modo manual ativo · envio automático por email também disponível.':'Modo manual ativo · email automático não configurado.';box.className='status-box success';}
    }catch{emailConfigured=false;if(box){box.textContent='Modo manual ativo · não foi possível verificar o email automático.';box.className='status-box success';}}
  }
  async function approveSend(id){
    const r=await fetch(cfg.supabaseUrl+'/functions/v1/jogos-recovery/approve-send',{method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:'Bearer '+token(),'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify({requestId:id})});
    const raw=await r.text();let data=null;try{data=raw?JSON.parse(raw):null}catch{data=raw}
    if(!r.ok)throw new Error(data?.error||data?.message||'Não foi possível enviar o código.');return data;
  }
  const stateLabel=s=>({pending_admin:'Aguardando confirmação',sending:'A enviar',code_sent:'Código ativo',rejected:'Rejeitado',completed:'Concluído',expired:'Expirado',cancelled:'Cancelado'})[s]||s;
  function rowHtml(r){
    const hasEmail=Boolean(String(r.recovery_email||'').trim());
    const accountFound=Boolean(r.account_found&&r.player_id);
    let actions='';
    if(accountFound&&['pending_admin','code_sent','expired'].includes(r.status)) actions+='<button class="button success small" data-recovery-manual="'+esc(r.id)+'">'+(r.status==='pending_admin'?'Confirmar e gerar código':'Gerar novo código')+'</button>';
    if(accountFound&&r.status==='pending_admin'&&emailConfigured&&hasEmail) actions+='<button class="button secondary small" data-recovery-email="'+esc(r.id)+'">Confirmar e enviar por email</button>';
    if(r.status==='pending_admin') actions+='<button class="button danger small" data-recovery-reject="'+esc(r.id)+'">Rejeitar</button>';
    const sent=r.sent_at?' · criado/enviado: '+esc(dt(r.sent_at)):'', expires=r.otp_expires_at?' · expira: '+esc(dt(r.otp_expires_at)):'';
    const badge=!accountFound?'danger':(r.status==='pending_admin'?'warning':(r.status==='code_sent'?'success':'muted'));
    const emailText=hasEmail?'✉️ '+esc(r.recovery_email):'✉️ Email não informado';
    const accountNote=accountFound?'':'<div class="form-message error" style="margin-top:8px">Conta não localizada para este telefone. Confirme o número com o jogador e peça novo pedido com o telefone correto.</div>';
    return '<div class="recovery-admin-row"><div><div class="recovery-admin-head"><strong>'+esc(r.name)+'</strong><span class="badge '+badge+'">'+esc(accountFound?stateLabel(r.status):'Conta não localizada')+'</span></div><div class="recovery-admin-contact"><span>📞 '+esc(r.phone)+'</span><span>'+emailText+'</span></div><small>Pedido: '+esc(dt(r.requested_at))+sent+expires+'</small>'+accountNote+'</div><div class="row-actions">'+actions+'</div></div>';
  }
  function toast(msg,type=''){const el=$('toast');if(!el)return;el.textContent=msg;el.className=('toast show '+type).trim();clearTimeout(toast.t);toast.t=setTimeout(()=>el.className='toast',4500);}
  function generateCode(){const a=new Uint32Array(1);let n;do{crypto.getRandomValues(a);n=a[0];}while(n>=4294000000);return String(n%1000000).padStart(6,'0');}
  function showCode(code,data){
    let m=$('manualRecoveryCodeModal');
    if(!m){
      m=document.createElement('div');m.id='manualRecoveryCodeModal';m.className='modal hidden';
      m.innerHTML='<div class="modal-card" style="max-width:460px"><button class="modal-close" data-close-manual-code type="button">×</button><p class="eyebrow">CÓDIGO DE RECUPERAÇÃO</p><h2>Envie ao jogador</h2><p class="muted-text">Confirme a identidade por um canal conhecido antes de entregar o código.</p><div id="manualRecoveryCodeValue" style="font-size:2.4rem;font-weight:950;letter-spacing:.18em;text-align:center;padding:18px;margin:16px 0;border:1px solid var(--line);border-radius:16px"></div><p id="manualRecoveryCodeExpiry" class="muted-text"></p><div class="row-actions"><button id="copyManualRecoveryCode" class="button primary" type="button">Copiar código</button><button class="button ghost" data-close-manual-code type="button">Fechar</button></div></div>';
      document.body.appendChild(m);
      m.addEventListener('click',e=>{if(e.target===m||e.target.closest('[data-close-manual-code]')){m.classList.add('hidden');$('manualRecoveryCodeValue').textContent='';}});
      $('copyManualRecoveryCode').addEventListener('click',async()=>{const v=$('manualRecoveryCodeValue').textContent;try{await navigator.clipboard.writeText(v);toast('Código copiado.','success');}catch{toast('Copie manualmente o código exibido.','error');}});
    }
    $('manualRecoveryCodeValue').textContent=code;
    $('manualRecoveryCodeExpiry').textContent='Válido até '+dt(data?.expires_at)+' · máximo de 5 tentativas inválidas.';
    m.classList.remove('hidden');
  }
  async function load(){
    if(!$('recoveryAdminList')||!token())return;
    try{const rows=await rpc('jl_admin_recovery_requests',{p_token:token()});$('recoveryAdminCount').textContent=String(rows.filter(r=>r.status==='pending_admin').length);$('recoveryAdminList').innerHTML=rows.length?rows.map(rowHtml).join(''):'<div class="empty">Nenhum pedido de recuperação.</div>';}
    catch(err){$('recoveryAdminList').innerHTML='<div class="empty">'+esc(err.message)+'</div>';}
  }
  function wire(){
    const list=$('recoveryAdminList');if(!list)return;
    list.addEventListener('click',async e=>{
      const manual=e.target.closest('[data-recovery-manual]'),email=e.target.closest('[data-recovery-email]'),reject=e.target.closest('[data-recovery-reject]');if(!manual&&!email&&!reject)return;
      try{
        if(manual){if(!confirm('Confirma que verificou a identidade do jogador e quer criar um código de recuperação?'))return;const code=generateCode();manual.disabled=true;const data=await rpc('jl_admin_issue_recovery_code',{p_token:token(),p_request_id:manual.dataset.recoveryManual,p_code:code});showCode(code,data);toast('Código criado. Envie-o ao jogador.','success');}
        else if(email){if(!confirm('Confirma a identidade e quer enviar o código por email?'))return;email.disabled=true;const data=await approveSend(email.dataset.recoveryEmail);toast(data?.message||'Código enviado.','success');}
        else{if(!confirm('Rejeitar este pedido de recuperação?'))return;await rpc('jl_admin_reject_recovery',{p_token:token(),p_request_id:reject.dataset.recoveryReject});toast('Pedido rejeitado.','success');}
        await load();
      }catch(err){toast(err.message,'error');await load();}
    });
    $('refreshRecoveryAdmin')?.addEventListener('click',load);checkEmailHealth().then(load);
    clearInterval(timer);timer=setInterval(()=>{if(token()&&document.visibilityState==='visible'&&!document.querySelector('#manualRecoveryCodeModal:not(.hidden)'))load();},15000);
    setInterval(()=>{if(document.visibilityState==='visible')checkEmailHealth();},60000);
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',wire,{once:true});else wire();
})();
