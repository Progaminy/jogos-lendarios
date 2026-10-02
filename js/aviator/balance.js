(() => {
  'use strict';

  function create({element,rpc,playerToken,win=window}={}) {
    let value=null;
    let busy=false;

    function format(amount){
      const n=Number(amount);
      if(!Number.isFinite(n))return '—';
      return n.toLocaleString('pt-MZ',{
        minimumFractionDigits:2,
        maximumFractionDigits:2
      })+' MZN';
    }

    function render(next=value){
      value=Number.isFinite(Number(next))?Number(next):null;
      if(!element)return;
      const authenticated=Boolean(playerToken?.());
      element.hidden=!authenticated;
      const strong=element.querySelector('strong');
      if(strong)strong.textContent=format(value);
    }

    function applyPlayerState(player){
      if(player&&Object.prototype.hasOwnProperty.call(player,'balance')){
        render(player.balance);
      }else if(!playerToken?.()){
        render(null);
      }
    }

    async function refresh(){
      if(busy)return value;
      if(!playerToken?.()){
        render(null);
        return null;
      }
      busy=true;
      try{
        const state=await rpc('jl_aviator_player_state',{p_token:playerToken()});
        applyPlayerState(state);
        return value;
      }catch(_){
        return value;
      }finally{
        busy=false;
      }
    }

    render(null);
    win.addEventListener?.('jl-player-session-changed',()=>{
      if(playerToken?.())void refresh();
      else render(null);
    });
    win.addEventListener?.('jl-player-finance-changed',()=>{ void refresh(); });
    if(playerToken?.())void refresh();

    return Object.freeze({
      render,
      refresh,
      applyPlayerState,
      value:()=>value
    });
  }

  window.JLAviatorBalance=Object.freeze({create});
})();
