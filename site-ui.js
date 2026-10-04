(() => {
  'use strict';

  const token=()=>window.JLSession?.getPlayerToken?.()||localStorage.getItem('jl_player_token')||'';

  function ensureStyle(){
    if(document.querySelector('link[data-jl-site-ui-style]'))return;
    const existing=[...document.styleSheets].some(sheet=>String(sheet.href||'').includes('/site-ui.css'));
    if(existing)return;
    const link=document.createElement('link');
    link.rel='stylesheet';
    link.href='./site-ui.css?v=20261004-1';
    link.dataset.jlSiteUiStyle='1';
    document.head.appendChild(link);
  }

  const symbolRules=[
    [/^entrar$/i,'↪'],[/^criar conta$/i,'＋'],[/^sair$/i,'↩'],[/^cancelar/i,'×'],[/^recusar/i,'×'],[/^aceitar/i,'✓'],[/^confirmar/i,'✓'],[/^copiar/i,'⧉'],[/^dep[oó]sito$/i,'↓'],[/^saque$/i,'↑'],[/^mensagem$/i,'✉'],[/^sess[oõ]es$/i,'▣'],[/^fixar\b/i,'⌖'],[/^desfixar\b/i,'⌖'],[/^convidar/i,'＋'],[/^abrir$/i,'↗'],[/^fechar$/i,'×'],[/^atualizar$/i,'⟳'],[/^desistir/i,'⚑'],[/^propor empate/i,'=']
  ];

  function shouldSkip(el){
    return Boolean(el.closest('.game-nav,.number-grid,.ludo-color-picker,.ludo-pawn-style-picker,.player-count-picker,.turn-time-picker')||el.classList.contains('top-refresh-button')||el.classList.contains('status-metric')||el.classList.contains('dice')||el.classList.contains('number-button'));
  }

  function decorate(root=document){
    const nodes=root.querySelectorAll?.('button,a.button')||[];
    nodes.forEach(el=>{
      if(el.dataset.jlSymbolized==='1'||shouldSkip(el))return;
      const text=String(el.textContent||'').replace(/\s+/g,' ').trim();
      if(!text)return;
      for(const [pattern,symbol] of symbolRules){
        if(!pattern.test(text))continue;
        el.dataset.jlSymbol=symbol;
        el.dataset.jlSymbolized='1';
        el.classList.add('jl-symbolized');
        break;
      }
    });
  }

  function standardizeDamaLoggedOut(){
    const section=document.getElementById('damaLoggedOut');
    const form=document.getElementById('damaLoginForm');
    if(!section||!form||section.dataset.jlSharedAccountEntry==='1')return;
    section.dataset.jlSharedAccountEntry='1';
    form.classList.add('jl-legacy-inline-auth');
    const oldCreate=[...section.querySelectorAll('a,button')].find(el=>/criar conta/i.test(el.textContent||''));
    oldCreate?.classList.add('jl-legacy-inline-auth');

    const callout=document.createElement('div');
    callout.className='jl-shared-login-callout';
    callout.innerHTML=`
      <p>A mesma conta e o mesmo saldo são usados em todos os Jogos Lendários.</p>
      <div class="jl-shared-login-actions">
        <button class="button primary" type="button" data-open-auth="login">Entrar</button>
        <button class="button ghost" type="button" data-open-auth="register">Criar conta</button>
      </div>`;
    section.appendChild(callout);
    decorate(callout);
  }

  function standardizeLoggedOutCallouts(){
    document.querySelectorAll('[data-open-auth]').forEach(el=>{
      if(el.dataset.openAuth==='login'&&!/^\s*entrar\s*$/i.test(el.textContent||''))return;
      if(el.dataset.openAuth==='register'&&!/criar conta/i.test(el.textContent||''))return;
      decorate(el.parentElement||document);
    });
  }

  function refresh(){
    ensureStyle();
    decorate();
    standardizeLoggedOutCallouts();
  }

  function afterPageInit(){
    standardizeDamaLoggedOut();
    decorate();
  }

  function boot(){
    refresh();
    const observer=new MutationObserver(records=>{
      let needs=false;
      for(const record of records){
        if(record.type==='childList'&&record.addedNodes.length){needs=true;break;}
        if(record.type==='characterData'){needs=true;break;}
      }
      if(needs)requestAnimationFrame(refresh);
    });
    observer.observe(document.body,{subtree:true,childList:true,characterData:true});
    window.addEventListener('jl-player-session-changed',()=>{
      if(!token())setTimeout(refresh,0);
    });
    if(document.readyState==='complete')setTimeout(afterPageInit,0);
    else window.addEventListener('load',()=>setTimeout(afterPageInit,0),{once:true});
  }

  window.JLSiteUI=Object.freeze({refresh,decorate});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
})();