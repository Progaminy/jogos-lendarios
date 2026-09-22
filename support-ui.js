(() => {
  'use strict';
  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const $ = (id) => document.getElementById(id);
  let pollTimer = null;

  function token(){ return localStorage.getItem(TOKEN_KEY) || ''; }
  function escapeHtml(v){ return String(v ?? '').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c])); }
  function when(v){ return v ? new Date(v).toLocaleString('pt-MZ',{dateStyle:'short',timeStyle:'short'}) : '—'; }

  async function rpc(name,args={}){
    if(!cfg.supabaseUrl||!cfg.supabaseKey) throw new Error('Configuração do Supabase ausente.');
    const res=await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`,{
      method:'POST',
      headers:{apikey:cfg.supabaseKey,Authorization:`Bearer ${cfg.supabaseKey}`,'Content-Type':'application/json',Accept:'application/json'},
      body:JSON.stringify(args)
    });
    const raw=await res.text(); let data=null;
    try{ data=raw?JSON.parse(raw):null; }catch{ data=raw; }
    if(!res.ok) throw new Error(data?.message||data?.hint||data?.error||`Erro ${res.status}`);
    return data;
  }

  function ensureModal(){
    if($('supportModal')) return;
    const wrap=document.createElement('div');
    wrap.innerHTML=`
      <div id="supportModal" class="support-modal hidden" role="dialog" aria-modal="true" aria-labelledby="supportTitle">
        <div class="support-card">
          <div class="support-head">
            <div><p class="eyebrow">LINHA DE CLIENTE</p><h2 id="supportTitle">Mensagem ao atendimento</h2></div>
            <button id="supportClose" class="support-close" type="button" aria-label="Fechar">×</button>
          </div>
          <p class="support-intro">Escreva a sua dúvida, preocupação ou problema. O administrador pode responder aqui mesmo.</p>
          <div id="supportMessages" class="support-messages"><div class="support-empty">Ainda não há mensagens.</div></div>
          <form id="supportForm" class="support-form">
            <textarea id="supportInput" maxlength="1000" rows="3" placeholder="Escreva a sua mensagem…" required></textarea>
            <button class="button primary" type="submit">Enviar mensagem</button>
          </form>
          <p id="supportStatus" class="support-status"></p>
        </div>
      </div>`;
    document.body.appendChild(wrap.firstElementChild);

    $('supportClose').addEventListener('click',close);
    $('supportModal').addEventListener('click',e=>{if(e.target===$('supportModal'))close();});
    $('supportForm').addEventListener('submit',async e=>{
      e.preventDefault();
      const input=$('supportInput'), status=$('supportStatus');
      const message=input.value.trim();
      if(!message) return;
      try{
        status.textContent='Enviando…';
        await rpc('jl_support_send',{p_token:token(),p_message:message});
        input.value='';
        status.textContent='Mensagem enviada.';
        await loadThread();
      }catch(err){ status.textContent=err.message; }
    });
  }

  async function loadThread(){
    if(!$('supportMessages')||!token()) return;
    try{
      const data=await rpc('jl_support_thread',{p_token:token()});
      const messages=data?.messages||[];
      $('supportMessages').innerHTML=messages.length?messages.map(m=>`
        <div class="support-message ${m.sender==='admin'?'admin':'player'}">
          <div class="support-message-label">${m.sender==='admin'?'Atendimento':'Você'}</div>
          <div>${escapeHtml(m.message)}</div>
          <small>${when(m.created_at)}</small>
        </div>`).join(''):'<div class="support-empty">Ainda não há mensagens. Envie a primeira.</div>';
      $('supportMessages').scrollTop=$('supportMessages').scrollHeight;
    }catch(err){
      if($('supportStatus')) $('supportStatus').textContent=err.message;
    }
  }

  async function open(){
    if(!token()) return;
    ensureModal();
    $('supportModal').classList.remove('hidden');
    document.body.classList.add('support-open');
    await loadThread();
    clearInterval(pollTimer);
    pollTimer=setInterval(loadThread,4000);
    $('supportInput')?.focus();
  }

  function close(){
    $('supportModal')?.classList.add('hidden');
    document.body.classList.remove('support-open');
    clearInterval(pollTimer); pollTimer=null;
  }

  document.querySelectorAll('[data-open-support]').forEach(b=>b.addEventListener('click',e=>{
    e.preventDefault(); e.stopPropagation(); open();
  }));
  document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('supportModal')?.classList.contains('hidden'))close();});
})();