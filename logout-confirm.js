(() => {
  'use strict';

  let resolver=null;
  let lastFocus=null;

  function ensureWindow(){
    let modal=document.getElementById('jlLogoutConfirm');
    if(modal)return modal;

    modal=document.createElement('div');
    modal.id='jlLogoutConfirm';
    modal.className='jl-logout-modal hidden';
    modal.setAttribute('role','dialog');
    modal.setAttribute('aria-modal','true');
    modal.setAttribute('aria-labelledby','jlLogoutTitle');

    modal.innerHTML=`
      <div class="jl-logout-window">
        <div class="jl-logout-windowbar">
          <div class="jl-logout-windowbrand">
            <span class="jl-logout-windowdot" aria-hidden="true"></span>
            <strong>Jogos Lendários</strong>
          </div>
          <button id="jlLogoutClose" class="jl-logout-windowclose" type="button" aria-label="Fechar">×</button>
        </div>

        <div class="jl-logout-windowbody">
          <h2 id="jlLogoutTitle">Sair da conta?</h2>
          <p>Tem certeza que deseja encerrar a sua sessão?</p>

          <div class="jl-logout-actions">
            <button id="jlLogoutCancel" class="button ghost" type="button">Cancelar</button>
            <button id="jlLogoutConfirmButton" class="button danger jl-logout-danger" type="button">Sair</button>
          </div>
        </div>
      </div>`;

    document.body.appendChild(modal);

    const finish=(value)=>{
      if(modal.classList.contains('hidden'))return;
      modal.classList.add('hidden');
      document.body.classList.remove('modal-open');
      const done=resolver;
      resolver=null;
      lastFocus?.focus?.();
      lastFocus=null;
      done?.(value);
    };

    modal.querySelector('#jlLogoutCancel').addEventListener('click',()=>finish(false));
    modal.querySelector('#jlLogoutClose').addEventListener('click',()=>finish(false));
    modal.querySelector('#jlLogoutConfirmButton').addEventListener('click',()=>finish(true));
    modal.addEventListener('click',e=>{if(e.target===modal)finish(false);});
    document.addEventListener('keydown',e=>{
      if(e.key==='Escape'&&!modal.classList.contains('hidden'))finish(false);
    });

    return modal;
  }

  window.JLConfirmLogout=function(){
    const modal=ensureWindow();
    if(resolver)return Promise.resolve(false);

    lastFocus=document.activeElement;
    modal.classList.remove('hidden');
    document.body.classList.add('modal-open');

    return new Promise(resolve=>{
      resolver=resolve;
      requestAnimationFrame(()=>modal.querySelector('#jlLogoutCancel')?.focus());
    });
  };
})();