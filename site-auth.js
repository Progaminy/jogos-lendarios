(() => {
  'use strict';

  const TOKEN_KEY='jl_player_token';
  const $=(selector,root=document)=>root.querySelector(selector);
  const token=()=>window.JLSession?.getPlayerToken?.()||localStorage.getItem(TOKEN_KEY)||'';
  const rpc=(name,args={})=>window.JLApi?.rpc?.(name,args);
  let lastFocus=null;

  function ensureStyle(){
    if(document.querySelector('link[data-jl-shared-auth-style]'))return;
    const existing=[...document.styleSheets].some(sheet=>String(sheet.href||'').includes('/site-auth.css'));
    if(existing)return;
    const link=document.createElement('link');
    link.rel='stylesheet';
    link.href='./site-auth.css?v=20261004-1';
    link.dataset.jlSharedAuthStyle='1';
    document.head.appendChild(link);
  }

  function markup(){
    return `
      <section class="jl-auth-window" role="document">
        <div class="jl-auth-bar">
          <div class="jl-auth-brand"><span class="jl-auth-dot" aria-hidden="true"></span><span>Jogos <strong>Lendários</strong></span></div>
          <button id="jlAuthClose" class="jl-auth-close" type="button" aria-label="Fechar">×</button>
        </div>
        <div class="jl-auth-body">
          <p class="jl-auth-kicker">CONTA ÚNICA</p>
          <h2 id="jlAuthTitle">Entrar</h2>
          <p class="jl-auth-lead">A mesma conta e o mesmo saldo em todos os Jogos Lendários.</p>

          <div class="jl-auth-tabs" role="tablist" aria-label="Conta">
            <button id="jlAuthLoginTab" class="jl-auth-tab active" type="button" role="tab" aria-selected="true">↪ Entrar</button>
            <button id="jlAuthRegisterTab" class="jl-auth-tab" type="button" role="tab" aria-selected="false">＋ Criar conta</button>
          </div>

          <form id="jlAuthLoginForm" class="jl-auth-form" autocomplete="on">
            <label class="jl-auth-field">
              <span>Celular</span>
              <span class="jl-auth-input"><span class="jl-auth-icon" aria-hidden="true">☎</span><input id="jlAuthLoginPhone" inputmode="tel" autocomplete="tel" placeholder="84 / 85 / 86 / 87…" required></span>
            </label>
            <label class="jl-auth-field">
              <span>PIN</span>
              <span class="jl-auth-input"><span class="jl-auth-icon" aria-hidden="true">●</span><input id="jlAuthLoginPin" type="password" inputmode="numeric" autocomplete="current-password" minlength="4" maxlength="8" placeholder="••••" required></span>
            </label>
            <button class="jl-auth-submit" type="submit"><span class="jl-auth-submit-icon" aria-hidden="true">↪</span>Entrar</button>
          </form>

          <form id="jlAuthRegisterForm" class="jl-auth-form hidden" autocomplete="on">
            <label class="jl-auth-field">
              <span>Nome</span>
              <span class="jl-auth-input"><span class="jl-auth-icon" aria-hidden="true">♟</span><input id="jlAuthRegisterName" autocomplete="name" maxlength="80" placeholder="Seu nome" required></span>
            </label>
            <label class="jl-auth-field">
              <span>Celular</span>
              <span class="jl-auth-input"><span class="jl-auth-icon" aria-hidden="true">☎</span><input id="jlAuthRegisterPhone" inputmode="tel" autocomplete="tel" placeholder="84 / 85 / 86 / 87…" required></span>
            </label>
            <label class="jl-auth-field">
              <span>PIN</span>
              <span class="jl-auth-input"><span class="jl-auth-icon" aria-hidden="true">●</span><input id="jlAuthRegisterPin" type="password" inputmode="numeric" autocomplete="new-password" minlength="4" maxlength="8" placeholder="4 a 8 dígitos" required></span>
            </label>
            <label class="jl-auth-field">
              <span>Confirmar PIN</span>
              <span class="jl-auth-input"><span class="jl-auth-icon" aria-hidden="true">✓</span><input id="jlAuthRegisterPinConfirm" type="password" inputmode="numeric" autocomplete="new-password" minlength="4" maxlength="8" placeholder="Repita o PIN" required></span>
            </label>
            <label class="jl-auth-field">
              <span>Código de convite <small>(opcional)</small></span>
              <span class="jl-auth-input"><span class="jl-auth-icon" aria-hidden="true">#</span><input id="jlAuthInviteCode" autocomplete="off" maxlength="40" placeholder="Código"></span>
              <small id="jlAuthInviteStatus" class="jl-auth-invite-status"></small>
            </label>
            <button class="jl-auth-submit" type="submit"><span class="jl-auth-submit-icon" aria-hidden="true">＋</span>Criar conta</button>
          </form>
          <p id="jlAuthMessage" class="jl-auth-message" role="status" aria-live="polite"></p>
        </div>
      </section>`;
  }

  function ensureModal(){
    ensureStyle();
    let modal=$('#jlSharedAuth');
    if(modal)return modal;
    modal=document.createElement('div');
    modal.id='jlSharedAuth';
    modal.className='jl-auth-overlay hidden';
    modal.setAttribute('role','dialog');
    modal.setAttribute('aria-modal','true');
    modal.setAttribute('aria-labelledby','jlAuthTitle');
    modal.innerHTML=markup();
    document.body.appendChild(modal);

    $('#jlAuthClose',modal)?.addEventListener('click',close);
    $('#jlAuthLoginTab',modal)?.addEventListener('click',()=>switchMode('login'));
    $('#jlAuthRegisterTab',modal)?.addEventListener('click',()=>switchMode('register'));
    modal.addEventListener('click',event=>{if(event.target===modal)close();});
    $('#jlAuthLoginForm',modal)?.addEventListener('submit',login);
    $('#jlAuthRegisterForm',modal)?.addEventListener('submit',register);
    $('#jlAuthInviteCode',modal)?.addEventListener('input',()=>setInviteStatus(''));
    $('#jlAuthInviteCode',modal)?.addEventListener('blur',()=>validateInvite(false));
    return modal;
  }

  function setMessage(text='',type=''){
    const el=$('#jlAuthMessage');
    if(!el)return;
    el.textContent=String(text||'');
    el.className=`jl-auth-message ${type}`.trim();
  }

  function setInviteStatus(text='',type=''){
    const el=$('#jlAuthInviteStatus');
    if(!el)return;
    el.textContent=String(text||'');
    el.style.color=type==='success'?'#82e8b3':type==='error'?'#ff929a':'';
  }

  function switchMode(mode='login'){
    ensureModal();
    const loginMode=mode!=='register';
    $('#jlAuthLoginForm')?.classList.toggle('hidden',!loginMode);
    $('#jlAuthRegisterForm')?.classList.toggle('hidden',loginMode);
    $('#jlAuthLoginTab')?.classList.toggle('active',loginMode);
    $('#jlAuthRegisterTab')?.classList.toggle('active',!loginMode);
    $('#jlAuthLoginTab')?.setAttribute('aria-selected',loginMode?'true':'false');
    $('#jlAuthRegisterTab')?.setAttribute('aria-selected',loginMode?'false':'true');
    if($('#jlAuthTitle'))$('#jlAuthTitle').textContent=loginMode?'Entrar':'Criar conta';
    setMessage('');
    requestAnimationFrame(()=>$(loginMode?'#jlAuthLoginPhone':'#jlAuthRegisterName')?.focus?.());
  }

  function open(mode='login'){
    const modal=ensureModal();
    lastFocus=document.activeElement;
    modal.classList.remove('hidden');
    document.body.classList.add('jl-auth-open','modal-open');
    switchMode(mode);
  }

  function close(){
    const modal=$('#jlSharedAuth');
    if(!modal||modal.classList.contains('hidden'))return;
    modal.classList.add('hidden');
    document.body.classList.remove('jl-auth-open','modal-open');
    setMessage('');
    lastFocus?.focus?.();
    lastFocus=null;
  }

  function saveToken(value){
    const v=String(value||'');
    if(window.JLSession?.setPlayerToken)window.JLSession.setPlayerToken(v);
    else{
      if(v)localStorage.setItem(TOKEN_KEY,v);else localStorage.removeItem(TOKEN_KEY);
      window.dispatchEvent(new CustomEvent('jl-player-session-changed',{detail:{authenticated:Boolean(v)}}));
    }
    window.JLNotifications?.setActive?.(Boolean(v));
  }

  async function validateInvite(showEmpty=true){
    const input=$('#jlAuthInviteCode');
    if(!input)return true;
    const code=String(input.value||'').trim().toUpperCase();
    input.value=code;
    if(!code){
      if(showEmpty)setInviteStatus('');
      return true;
    }
    setInviteStatus('A validar código…');
    try{
      const result=await rpc('jl_validate_invite_code',{p_code:code});
      if(!result?.valid){setInviteStatus('Código inválido ou inativo.','error');return false;}
      setInviteStatus(`✓ Código válido · ${result.influencer||'Influenciador'}`,'success');
      return true;
    }catch(error){
      setInviteStatus(error?.message||'Não foi possível validar o código.','error');
      return false;
    }
  }

  async function login(event){
    event.preventDefault();
    if(!rpc){setMessage('Serviço indisponível.','error');return;}
    const form=event.currentTarget;
    const button=form.querySelector('button[type="submit"]');
    button.disabled=true;
    setMessage('A entrar…');
    try{
      const result=await rpc('jl_login_player',{
        p_phone:String($('#jlAuthLoginPhone')?.value||'').trim(),
        p_pin:String($('#jlAuthLoginPin')?.value||'').trim()
      });
      if(!result?.token)throw new Error('Não foi possível iniciar a sessão.');
      saveToken(result.token);
      setMessage('✓ Sessão iniciada.','success');
      setTimeout(()=>location.reload(),120);
    }catch(error){setMessage(error?.message||'Não foi possível entrar.','error');}
    finally{button.disabled=false;}
  }

  async function register(event){
    event.preventDefault();
    if(!rpc){setMessage('Serviço indisponível.','error');return;}
    const pin=String($('#jlAuthRegisterPin')?.value||'').trim();
    const confirm=String($('#jlAuthRegisterPinConfirm')?.value||'').trim();
    if(pin!==confirm){setMessage('Os PINs não coincidem.','error');return;}
    if(!(await validateInvite())){setMessage('Verifique o código de convite.','error');return;}
    const form=event.currentTarget;
    const button=form.querySelector('button[type="submit"]');
    button.disabled=true;
    setMessage('A criar conta…');
    try{
      const result=await rpc('jl_register_player',{
        p_name:String($('#jlAuthRegisterName')?.value||'').trim(),
        p_phone:String($('#jlAuthRegisterPhone')?.value||'').trim(),
        p_pin:pin,
        p_invite_code:String($('#jlAuthInviteCode')?.value||'').trim()||null
      });
      if(!result?.token)throw new Error('Não foi possível criar a conta.');
      saveToken(result.token);
      setMessage(result.referral?'✓ Conta criada com convite validado.':'✓ Conta criada.','success');
      setTimeout(()=>location.reload(),120);
    }catch(error){setMessage(error?.message||'Não foi possível criar a conta.','error');}
    finally{button.disabled=false;}
  }

  function bridgeLegacyAuth(){
    const legacy=$('#authModal');
    if(!legacy||legacy.dataset.jlSharedBridge==='1')return;
    legacy.dataset.jlSharedBridge='1';
    const sync=()=>{
      if(legacy.classList.contains('hidden'))return;
      const register=legacy.querySelector('#registerForm')&&!legacy.querySelector('#registerForm').classList.contains('hidden');
      legacy.classList.add('hidden');
      document.body.classList.remove('modal-open');
      open(register?'register':'login');
    };
    new MutationObserver(sync).observe(legacy,{attributes:true,attributeFilter:['class']});
  }

  function interceptAccountEntry(){
    document.addEventListener('click',event=>{
      const account=event.target.closest?.('#accountButton');
      if(account&&!token()){
        event.preventDefault();
        event.stopImmediatePropagation();
        open('login');
        return;
      }
      const trigger=event.target.closest?.('[data-open-auth],[data-jl-auth-login],[data-jl-auth-register]');
      if(!trigger)return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const mode=trigger.dataset.jlAuthRegister!==undefined||trigger.dataset.openAuth==='register'?'register':'login';
      open(mode);
    },true);
  }

  function boot(){
    ensureModal();
    bridgeLegacyAuth();
    interceptAccountEntry();
    new MutationObserver(()=>bridgeLegacyAuth()).observe(document.body,{childList:true,subtree:true});
    document.addEventListener('keydown',event=>{if(event.key==='Escape'&&!$('#jlSharedAuth')?.classList.contains('hidden'))close();});
  }

  window.JLSharedAuth=Object.freeze({open,close,switchMode,validateInvite});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
})();