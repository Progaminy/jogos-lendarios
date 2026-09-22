(() => {
  'use strict';
  const cfg=window.JL_CONFIG||{};
  const $=id=>document.getElementById(id);
  function rpc(name,args={}){
    return fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`,{
      method:'POST',
      headers:{apikey:cfg.supabaseKey,Authorization:`Bearer ${cfg.supabaseKey}`,'Content-Type':'application/json',Accept:'application/json'},
      body:JSON.stringify(args)
    }).then(async r=>{
      const raw=await r.text();let data=null;try{data=raw?JSON.parse(raw):null}catch{data=raw}
      if(!r.ok)throw new Error(data?.message||data?.hint||data?.error||`Erro ${r.status}`);
      return data;
    });
  }
  function ensureModal(){
    if($('pinRecoveryModal'))return;
    const wrap=document.createElement('div');
    wrap.innerHTML=`
      <div id="pinRecoveryModal" class="recovery-modal hidden" role="dialog" aria-modal="true" aria-labelledby="pinRecoveryTitle">
        <div class="recovery-card">
          <button id="pinRecoveryClose" class="recovery-close" type="button" aria-label="Fechar">×</button>
          <p class="eyebrow">RECUPERAÇÃO DE ACESSO</p>
          <h2 id="pinRecoveryTitle">Recuperar PIN</h2>
          <p class="recovery-help">Informe o número da conta e um email para receber o código. O administrador verá estes contactos e deverá ligar para confirmar a sua identidade antes de autorizar o envio.</p>

          <div id="pinRecoveryRequestStage">
            <form id="pinRecoveryRequestForm" class="stack-form">
              <label><span>Número de telefone da conta</span><input id="pinRecoveryPhone" inputmode="tel" required placeholder="Ex.: 84xxxxxxx"></label>
              <label><span>Email para receber o código</span><input id="pinRecoveryEmail" type="email" required placeholder="seuemail@gmail.com"></label>
              <button class="button primary" type="submit">Pedir recuperação</button>
            </form>
          </div>

          <div id="pinRecoveryConfirmStage" class="hidden">
            <div class="recovery-waiting">
              <strong>Pedido enviado ao administrador.</strong>
              <span>Depois da confirmação por telefone, o código será enviado por email.</span>
            </div>
            <form id="pinRecoveryConfirmForm" class="stack-form">
              <label><span>Código de 6 dígitos</span><input id="pinRecoveryCode" inputmode="numeric" maxlength="6" pattern="[0-9]{6}" required></label>
              <label><span>Novo PIN</span><input id="pinRecoveryNewPin" type="password" inputmode="numeric" minlength="4" maxlength="8" pattern="[0-9]{4,8}" required></label>
              <label><span>Confirmar novo PIN</span><input id="pinRecoveryConfirmPin" type="password" inputmode="numeric" minlength="4" maxlength="8" pattern="[0-9]{4,8}" required></label>
              <button class="button success" type="submit">Confirmar código e alterar PIN</button>
            </form>
          </div>
          <p id="pinRecoveryMessage" class="recovery-message"></p>
        </div>
      </div>`;
    document.body.appendChild(wrap.firstElementChild);

    $('pinRecoveryClose').onclick=close;
    $('pinRecoveryModal').onclick=e=>{if(e.target===$('pinRecoveryModal'))close();};

    $('pinRecoveryRequestForm').onsubmit=async e=>{
      e.preventDefault();
      const phone=$('pinRecoveryPhone').value.trim(),email=$('pinRecoveryEmail').value.trim().toLowerCase();
      setMessage('A enviar o pedido…');
      try{
        const data=await rpc('jl_request_pin_recovery',{p_phone:phone,p_email:email});
        $('pinRecoveryRequestStage').classList.add('hidden');
        $('pinRecoveryConfirmStage').classList.remove('hidden');
        setMessage(data?.message||'Pedido recebido. Aguarde a confirmação do administrador.','success');
      }catch(err){setMessage(err.message,'error');}
    };

    $('pinRecoveryConfirmForm').onsubmit=async e=>{
      e.preventDefault();
      const pin=$('pinRecoveryNewPin').value,confirm=$('pinRecoveryConfirmPin').value;
      if(pin!==confirm)return setMessage('A confirmação do novo PIN não coincide.','error');
      setMessage('A validar o código…');
      try{
        const data=await rpc('jl_confirm_pin_recovery',{
          p_phone:$('pinRecoveryPhone').value.trim(),
          p_email:$('pinRecoveryEmail').value.trim().toLowerCase(),
          p_code:$('pinRecoveryCode').value.trim(),
          p_new_pin:pin
        });
        setMessage(data?.message||'PIN alterado com sucesso.','success');
        setTimeout(()=>{close();document.querySelector('#loginPhone')?.focus();},900);
      }catch(err){setMessage(err.message,'error');}
    };
  }
  function setMessage(text,type=''){
    const el=$('pinRecoveryMessage');if(!el)return;
    el.textContent=text||'';el.className=`recovery-message ${type}`.trim();
  }
  function open(){
    ensureModal();
    $('pinRecoveryRequestStage').classList.remove('hidden');
    $('pinRecoveryConfirmStage').classList.add('hidden');
    $('pinRecoveryCode').value='';$('pinRecoveryNewPin').value='';$('pinRecoveryConfirmPin').value='';
    const loginPhone=$('loginPhone');
    if(loginPhone?.value)$('pinRecoveryPhone').value=loginPhone.value;
    setMessage('');
    $('pinRecoveryModal').classList.remove('hidden');
    document.body.classList.add('recovery-open');
    setTimeout(()=>$('pinRecoveryPhone')?.focus(),50);
  }
  function close(){
    $('pinRecoveryModal')?.classList.add('hidden');
    document.body.classList.remove('recovery-open');
  }
  function installButton(){
    const login=document.getElementById('loginForm');
    if(!login||document.getElementById('forgotPinButton'))return;
    const b=document.createElement('button');
    b.id='forgotPinButton';b.type='button';b.className='button ghost recovery-link';b.textContent='Esqueci o PIN';
    b.addEventListener('click',open);
    login.appendChild(b);
  }
  document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('pinRecoveryModal')?.classList.contains('hidden'))close();});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',installButton,{once:true});else installButton();
})();