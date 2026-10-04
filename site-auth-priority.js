(() => {
  'use strict';
  const token=()=>window.JLSession?.getPlayerToken?.()||localStorage.getItem('jl_player_token')||'';

  window.addEventListener('click',event=>{
    const target=event.target?.closest?.('#accountButton,.game-nav [data-jl-nav="conta"],[data-open-auth],[data-jl-auth-login],[data-jl-auth-register]');
    if(!target)return;

    const explicit=target.matches('[data-open-auth],[data-jl-auth-login],[data-jl-auth-register]');
    if(!explicit&&token())return;

    const auth=window.JLSharedAuth;
    if(!auth?.open)return;

    event.preventDefault();
    event.stopImmediatePropagation();
    const mode=target.dataset?.openAuth==='register'||target.hasAttribute('data-jl-auth-register')?'register':'login';
    auth.open(mode);
  },true);
})();