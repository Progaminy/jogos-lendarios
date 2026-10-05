(() => {
  'use strict';
  const $=(s,r=document)=>r.querySelector(s);
  const path=String(location.pathname||'').toLowerCase();
  const query=new URL(location.href).searchParams;
  const freeMode=query.get('mode')==='free';
  const board=path.endsWith('/tabuleiro.html');
  const ludo=path.endsWith('/ludo.html');
  const dama=path.endsWith('/dama.html');
  const token=()=>window.JLSession?.getPlayerToken?.()||localStorage.getItem('jl_player_token')||'';
  const rpc=(name,args={})=>window.JLApi?.rpc?.(name,args);
  let status=null,gameHref='';

  const money=v=>Number(v||0).toLocaleString('pt-MZ',{minimumFractionDigits:0,maximumFractionDigits:2});

  function style(){
    if($('#jlFreeAccessStyle'))return;
    const s=document.createElement('style');s.id='jlFreeAccessStyle';s.textContent=`
    .jl-free-account{border-color:#38d179!important;color:#9ff0bd!important}
    .jl-free-modal{position:fixed;inset:0;z-index:10000;display:grid;place-items:center;padding:18px;background:rgba(0,0,0,.72);backdrop-filter:blur(8px)}
    .jl-free-modal.hidden{display:none!important}.jl-free-card{width:min(430px,100%);padding:20px;border:1px solid rgba(255,255,255,.12);border-radius:20px;background:#0c1420;box-shadow:0 24px 70px rgba(0,0,0,.48)}
    .jl-free-card h2{margin:0 0 14px;font-size:1.2rem}.jl-free-choice{display:grid;grid-template-columns:1fr 1fr;gap:10px}.jl-free-choice .button{width:100%;justify-content:center;min-height:48px}
    .jl-free-access-box{display:grid;gap:10px;margin-top:12px;padding-top:12px;border-top:1px solid rgba(255,255,255,.08)}.jl-free-state{font-size:.84rem;color:#aebcd0}.jl-free-state.success{color:#85e3a8}.jl-free-state.warning{color:#ffd66b}.jl-free-state.error{color:#ff929c}
    .jl-free-close{margin-top:12px;width:100%}.jl-free-mode-badge{display:inline-flex;align-items:center;justify-content:center;padding:5px 10px;border-radius:999px;border:1px solid #38d179;color:#8fe9b0;font-weight:900;font-size:.72rem;letter-spacing:.08em}
    html.jl-free-mode .jl-free-bet-hidden{display:none!important}@media(max-width:520px){.jl-free-card{padding:16px}.jl-free-choice{grid-template-columns:1fr}}`;
    document.head.appendChild(s);
  }

  function accountButton(){
    const a=$('.account-menu-actions');if(!a||$('#accountMenuFree',a))return;
    const b=document.createElement('button');b.id='accountMenuFree';b.className='button ghost small jl-free-account';b.type='button';b.textContent='FREE';
    b.onclick=e=>{e.preventDefault();e.stopPropagation();location.href='./tabuleiro.html#free'};a.prepend(b);
  }

  function modal(){
    let m=$('#jlFreeModal');if(m)return m;
    m=document.createElement('div');m.id='jlFreeModal';m.className='jl-free-modal hidden';m.innerHTML=`<div class="jl-free-card" role="dialog" aria-modal="true" aria-labelledby="jlFreeTitle"><h2 id="jlFreeTitle">Jogar</h2><div id="jlFreeChoices" class="jl-free-choice"><button id="jlFreeBet" class="button primary" type="button">APOSTAS</button><button id="jlFreeMode" class="button success" type="button">FREE</button></div><div id="jlFreeAccess" class="jl-free-access-box hidden"><strong id="jlFreePrice">FREE</strong><div id="jlFreeState" class="jl-free-state"></div><button id="jlFreePay" class="button success" type="button">Pagar</button><a id="jlFreeDeposit" class="button secondary hidden" href="./index.html?open=deposit&from=free#depositPanel">Depósito</a></div><button id="jlFreeClose" class="button ghost jl-free-close" type="button">Fechar</button></div>`;
    document.body.appendChild(m);
    $('#jlFreeClose',m).onclick=close;
    m.onclick=e=>{if(e.target===m)close()};
    $('#jlFreeBet',m).onclick=()=>{if(!gameHref)return;const u=new URL(gameHref,location.href);u.searchParams.delete('mode');location.href=u.href};
    $('#jlFreeMode',m).onclick=()=>gameHref?chooseFree():accessOnly();
    $('#jlFreePay',m).onclick=pay;
    return m;
  }

  function close(){
    $('#jlFreeModal')?.classList.add('hidden');
    if(location.hash==='#free')history.replaceState(null,'',location.pathname+location.search);
  }
  function stateText(text,type=''){const e=$('#jlFreeState');if(e){e.textContent=text||'';e.className=`jl-free-state ${type}`.trim()}}
  function accessBox(show=true){$('#jlFreeAccess')?.classList.toggle('hidden',!show)}

  async function load(silent=false){
    if(!token()||!rpc){status=null;if(!silent)stateText('Entre na conta.','warning');return null}
    try{status=await rpc('jl_free_access_status',{p_token:token()});return status}
    catch(e){status=null;if(!silent)stateText(e?.message||'FREE indisponível.','error');return null}
  }

  function render(s){
    accessBox(true);const price=$('#jlFreePrice'),payBtn=$('#jlFreePay'),dep=$('#jlFreeDeposit');
    if(price)price.textContent=s?`${money(s.price)} MZN`:'FREE';dep?.classList.add('hidden');
    if(!token()){stateText('Entre na conta.','warning');if(payBtn){payBtn.disabled=false;payBtn.textContent='Entrar'}return}
    if(!s){stateText('FREE indisponível.','error');if(payBtn)payBtn.disabled=true;return}
    if(s.enabled===false){stateText('FREE desativado.','warning');if(payBtn)payBtn.disabled=true;return}
    if(s.active){stateText('FREE ATIVO','success');if(payBtn){payBtn.disabled=true;payBtn.textContent='ATIVO'}return}
    if(s.status==='pending'){stateText('Aguardando aprovação.','warning');if(payBtn){payBtn.disabled=true;payBtn.textContent='PENDENTE'}return}
    stateText('Pagamento + aprovação.');if(payBtn){payBtn.disabled=false;payBtn.textContent=`Pagar ${money(s.price)} MZN`}
  }

  async function pay(){
    if(!token()){location.href='./index.html#login';return}
    const b=$('#jlFreePay');if(b)b.disabled=true;
    try{status=await rpc('jl_free_access_request',{p_token:token()});render(status)}
    catch(e){const msg=String(e?.message||'Não foi possível pagar.');stateText(msg,'error');if(/saldo insuficiente/i.test(msg))$('#jlFreeDeposit')?.classList.remove('hidden');if(b)b.disabled=false}
  }

  async function chooseFree(){
    const s=await load();if(!s)return render(s);
    if(s.active){const u=new URL(gameHref,location.href);u.searchParams.set('mode','free');location.href=u.href;return}
    render(s);
  }

  async function openChooser(anchor){
    const m=modal();gameHref=anchor?.href||'';
    const card=anchor?.closest('.board-game-card');
    $('#jlFreeTitle',m).textContent=card?.querySelector('h2')?.textContent?.trim()||(gameHref.includes('dama')?'Dama Lendária':gameHref.includes('ludo')?'Ludo Lendário':'Jogar');
    $('#jlFreeChoices',m)?.classList.remove('hidden');accessBox(false);m.classList.remove('hidden');await load(true);
  }

  async function accessOnly(){
    const m=modal();gameHref='';$('#jlFreeTitle',m).textContent='FREE';$('#jlFreeChoices',m)?.classList.add('hidden');m.classList.remove('hidden');render(await load());
  }

  function boardChooser(){
    document.addEventListener('click',e=>{
      const a=e.target.closest?.('.board-game-preview[href*="ludo.html"],.board-game-preview[href*="dama.html"],a[href*="ludo.html?board_invite"],a[href*="dama.html?board_invite"]');
      if(!a)return;e.preventDefault();e.stopImmediatePropagation();void openChooser(a);
    },true);
    if(location.hash==='#free')setTimeout(()=>void accessOnly(),0);
  }

  function badge(){
    if(!freeMode||$('#jlFreeModeBadge'))return;
    const b=document.createElement('span');b.id='jlFreeModeBadge';b.className='jl-free-mode-badge';b.textContent='FREE';
    const t=$('.product-tag')||$('.hero .eyebrow')||$('.dama-lobby-head .eyebrow')||$('.topbar .brand');t?.insertAdjacentElement('afterend',b);
  }

  function hideBet(){
    if(!freeMode)return;document.documentElement.classList.add('jl-free-mode');
    const ids=ludo?['createBet','queueForm','queueBet','rematchBet','stakeProposalAmount','stakeProposalSend']:dama?['damaBet','damaRematchBet']:[];
    ids.forEach(id=>{const e=document.getElementById(id);if(!e)return;(e.closest('.quick-start-step,label,.field,form#queueForm')||e).classList.add('jl-free-bet-hidden')});
    if(ludo)document.getElementById('queueForm')?.closest('.panel,.card')?.classList.add('jl-free-bet-hidden');
  }

  function gameMoney(){
    if(!freeMode)return;
    const selectors=ludo?['#publicChallengeList','#roomMeta','#roomPot','#roomPrize','#fundingText','#resultPayouts','#rematchHelp']:dama?['#damaPublicRooms','#damaRoomMeta','#damaSettingsSummary','#damaFunding','#damaResultMoney']:[];
    for(const selector of selectors){const root=$(selector);if(!root)continue;const w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);const nodes=[];while(w.nextNode())nodes.push(w.currentNode);for(const n of nodes){if(/0(?:[,.]00)?\s*MZN/i.test(n.nodeValue||''))n.nodeValue=n.nodeValue.replace(/0(?:[,.]00)?\s*MZN/gi,'FREE')}}
  }

  async function guard(){
    if(!freeMode||(!ludo&&!dama)||!token())return;const s=await load(true);if(s&&!s.active)location.replace('./tabuleiro.html#free');
  }

  function freePage(){
    if(!freeMode||(!ludo&&!dama))return;badge();hideBet();gameMoney();
    new MutationObserver(()=>{hideBet();badge();gameMoney()}).observe(document.body,{subtree:true,childList:true});void guard();
  }

  function init(){
    style();accountButton();modal();new MutationObserver(accountButton).observe(document.documentElement,{subtree:true,childList:true});
    if(board)boardChooser();freePage();
  }
  window.addEventListener('jl-player-session-changed',()=>{accountButton();if(freeMode)void guard();if(board&&location.hash==='#free')void accessOnly()});
  document.readyState==='loading'?document.addEventListener('DOMContentLoaded',init,{once:true}):init();
})();
