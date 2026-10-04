(() => {
  'use strict';
  const token=()=>window.JLSession?.getPlayerToken?.()||localStorage.getItem('jl_player_token')||'';

  function openWhenReady(mode,attempt=0){
    const auth=window.JLSharedAuth;
    if(auth?.open){auth.open(mode);return;}
    if(attempt>=20)return;
    setTimeout(()=>openWhenReady(mode,attempt+1),35);
  }

  window.addEventListener('click',event=>{
    const target=event.target?.closest?.('#accountButton,.game-nav [data-jl-nav="conta"],[data-open-auth],[data-jl-auth-login],[data-jl-auth-register]');
    if(!target)return;

    const explicit=target.matches('[data-open-auth],[data-jl-auth-login],[data-jl-auth-register]');
    if(!explicit&&token())return;

    event.preventDefault();
    event.stopImmediatePropagation();
    const mode=target.dataset?.openAuth==='register'||target.hasAttribute('data-jl-auth-register')?'register':'login';
    openWhenReady(mode);
  },true);
})();