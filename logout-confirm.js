(() => {
  'use strict';

  let resolver = null;
  let lastFocus = null;

  function ensureModal() {
    let modal = document.getElementById('jlLogoutConfirm');
    if (modal) return modal;

    modal = document.createElement('div');
    modal.id = 'jlLogoutConfirm';
    modal.className = 'jl-logout-modal hidden';
    modal.setAttribute('role','dialog');
    modal.setAttribute('aria-modal','true');
    modal.setAttribute('aria-labelledby','jlLogoutTitle');
    modal.innerHTML = `
      <div class="jl-logout-card">
        <div class="jl-logout-icon" aria-hidden="true">↪</div>
        <p class="jl-logout-kicker">JOGOS LENDÁRIOS</p>
        <h2 id="jlLogoutTitle">Deseja sair da conta?</h2>
        <p class="jl-logout-text">A sua sessão será encerrada neste dispositivo. O seu saldo, apostas e histórico permanecem guardados.</p>
        <div class="jl-logout-actions">
          <button id="jlLogoutCancel" class="button ghost" type="button">Cancelar</button>
          <button id="jlLogoutConfirmButton" class="button danger jl-logout-danger" type="button">Sair da conta</button>
        </div>
      </div>`;
    document.body.appendChild(modal);

    const finish=(value)=>{
      if(modal.classList.contains('hidden')) return;
      modal.classList.add('hidden');
      document.body.classList.remove('modal-open');
      const done=resolver; resolver=null;
      if(lastFocus?.focus) lastFocus.focus();
      lastFocus=null;
      done?.(value);
    };

    modal.querySelector('#jlLogoutCancel').addEventListener('click',()=>finish(false));
    modal.querySelector('#jlLogoutConfirmButton').addEventListener('click',()=>finish(true));
    modal.addEventListener('click',e=>{if(e.target===modal)finish(false);});
    document.addEventListener('keydown',e=>{
      if(e.key==='Escape'&&!modal.classList.contains('hidden')) finish(false);
    });

    modal._finish=finish;
    return modal;
  }

  window.JLConfirmLogout = function JLConfirmLogout() {
    const modal=ensureModal();
    if(resolver) return Promise.resolve(false);
    lastFocus=document.activeElement;
    modal.classList.remove('hidden');
    document.body.classList.add('modal-open');
    setTimeout(()=>modal.querySelector('#jlLogoutCancel')?.focus(),0);
    return new Promise(resolve=>{resolver=resolve;});
  };
})();