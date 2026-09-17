(() => {
  'use strict';
  if (window.__JL_LUDO_PRO_UI__) return;
  window.__JL_LUDO_PRO_UI__ = true;

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const $ = (s, r=document) => r.querySelector(s);
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const money = (v) => Number(v || 0).toLocaleString('pt-MZ',{maximumFractionDigits:2});
  const DIE = ['','⚀','⚁','⚂','⚃','⚄','⚅'];
  let state = null;
  let timer = null;
  let busy = false;

  async function rpc(name,args={}){
    const token=localStorage.getItem(TOKEN_KEY);
    if(!token||!cfg.supabaseUrl||!cfg.supabaseKey)return null;
    const res=await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:`Bearer ${cfg.supabaseKey}`,'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify(args)});
    if(!res.ok)return null;
    try{return await res.json()}catch{return null}
  }

  function ensureCss(){
    if(document.querySelector('link[data-jl-ludo-pro]'))return;
    const l=document.createElement('link');
    l.rel='stylesheet';l.href='./ludo-pro.css?v=1';l.dataset.jlLudoPro='1';document.head.appendChild(l);
  }

  function ensureHud(){
    const panel=$('#gamePanel .board-panel');
    if(!panel)return null;
    let hud=$('#jlProHud',panel);
    if(!hud){hud=document.createElement('div');hud.id='jlProHud';panel.prepend(hud)}
    let dock=$('#jlActionDock');
    if(!dock){dock=document.createElement('div');dock.id='jlActionDock';dock.className='hidden';document.body.appendChild(dock)}
    return hud;
  }

  function colorLabel(c){return ({red:'Vermelho',green:'Verde',yellow:'Amarelo',blue:'Azul'})[c]||c||'—'}
  function roomPlayers(){return (state?.players||[]).filter(p=>p.status!=='left')}
  function mine(){const id=state?.identity?.player_id;return roomPlayers().find(p=>p.player_id===id)}

  function renderHud(){
    const hud=ensureHud();
    if(!state?.room||!hud){document.body.classList.remove('ludo-pro-room');$('#jlActionDock')?.classList.add('hidden');return}
    document.body.classList.add('ludo-pro-room');
    const r=state.room, players=roomPlayers(), total=Number(r.player_count||0);
    const accepted=players.filter(p=>p.accepted_rules_version===r.rules_version).length;
    const paid=players.filter(p=>p.stake_paid).length;
    const diceCount=Number(r.rules?.dice_count||1);
    const location=r.rules?.play_location==='presential'?'Presencial':'Online';
    const cards=Array.from({length:total},(_,i)=>{
      const p=players.find(x=>Number(x.seat)===i+1);
      if(!p)return `<div class="jl-pro-player empty"><div class="top"><span class="jl-pro-dot"></span><b>Vaga ${i+1}</b></div><small>Aguardando jogador</small></div>`;
      const current=r.current_player_id===p.player_id;
      const okRules=p.accepted_rules_version===r.rules_version;
      return `<div class="jl-pro-player ${current?'current':''}"><div class="top"><span class="jl-pro-dot ${esc(p.color)}"></span><b>${esc(p.code||p.name)}</b></div><small>${colorLabel(p.color)}${p.team?` · equipa ${p.team}`:''}</small><div class="checks"><span class="${okRules?'ok':''}">${okRules?'✓ regras':'regras'}</span><span class="${p.stake_paid?'ok':''}">${p.stake_paid?'✓ aposta':'aposta'}</span></div></div>`
    }).join('');
    hud.innerHTML=`<div class="jl-pro-head"><div><strong><span class="jl-pro-code">${esc(r.code)}</span> · ${r.mode==='partners'?'Parceiros':'Cada um por si'}</strong></div><div class="jl-pro-meta"><span class="jl-pro-chip ${players.length===total?'ok':'wait'}">Jogadores ${players.length}/${total}</span><span class="jl-pro-chip ${accepted===total?'ok':'wait'}">Regras ${accepted}/${total}</span><span class="jl-pro-chip ${paid===total&&r.status!=='waiting'&&r.status!=='negotiating'?'ok':'wait'}">Apostas ${paid}/${total}</span><span class="jl-pro-chip">🎲 ${diceCount}</span><span class="jl-pro-chip">${location}</span></div></div><div class="jl-pro-players">${cards}</div><div class="jl-pro-nav"><button data-jl-jump="board">Tabuleiro</button><button data-jl-jump="rules">Regras</button><button data-jl-jump="invite">Convites</button><button data-jl-jump="chat">Chat</button></div>`;
    renderDock();
    renderDice();
  }

  function dockButton(label, action, cls='primary'){return `<button class="jl-dock-btn ${cls}" data-jl-dock="${action}">${label}</button>`}
  function renderDock(){
    const dock=$('#jlActionDock'); if(!dock||!state?.room)return;
    const r=state.room, players=roomPlayers(), me=mine(), myId=state.identity?.player_id;
    const total=Number(r.player_count||0), full=players.length===total;
    const accepted=players.filter(p=>p.accepted_rules_version===r.rules_version).length;
    const paid=players.filter(p=>p.stake_paid).length;
    let title='',text='',actions='';

    if(r.status==='waiting'||!full){
      const missing=Math.max(0,total-players.length); title=missing?`Falta ${missing} jogador${missing===1?'':'es'}`:'Sala completa';
      text=r.host_id===myId?'Você já está na sala. Convide e continue vendo o tabuleiro.':'Aguardando o anfitrião completar a sala.';
      if(r.host_id===myId) actions=`${dockButton('+ Convidar','invite')}${dockButton('📣 Todos','broadcast','')}`;
    }else if(r.status==='negotiating'){
      const mineAccepted=me?.accepted_rules_version===r.rules_version;
      if(!mineAccepted){title='Confirme as regras';text='Revise e aceite para liberar a aposta.';actions=`${dockButton('✓ Aceitar regras','accept','success')}${dockButton('Ver regras','rules','')}`}
      else{title='Regras aceites por você';text=`${accepted}/${total} jogadores confirmaram. Aguardando os restantes.`;actions=dockButton('Ver regras','rules','')}
    }else if(r.status==='funding'){
      if(!me?.stake_paid){title='Confirme a aposta';text=`Aposta desta sala: ${money(r.bet_amount)} MZN.`;actions=dockButton(`Confirmar ${money(r.bet_amount)} MZN`,'fund','success')}
      else{title='Sua aposta está confirmada ✓';text=`${paid}/${total} jogadores pagaram. O jogo começa automaticamente.`}
    }else if(r.status==='playing'){
      const current=players.find(p=>p.player_id===r.current_player_id);
      if(r.current_player_id===myId&&r.turn_phase==='roll'){title='Sua vez';text='Lance o dado para jogar.';actions=dockButton(Number(r.rules?.dice_count||1)>1?`🎲 Lançar ${Number(r.rules?.dice_count)} dados`:'🎲 Lançar dado','roll')}
      else if(r.current_player_id===myId&&r.turn_phase==='move'){title='Escolha uma peça';text='Toque numa peça destacada no tabuleiro.';actions=dockButton('Ir ao tabuleiro','board','')}
      else{title=`Vez de ${esc(current?.code||current?.name||'outro jogador')}`;text='Acompanhe a jogada. O estado atualiza automaticamente.';actions=dockButton('Chat','chat','')}
    }else if(r.status==='finished'){title='Partida terminada';text='Veja o resultado e os pagamentos registrados.';actions=dockButton('Ver resultado','result','')}
    else{title='Sala atualizando';text='Sincronizando o estado da partida.'}

    dock.classList.remove('hidden');
    dock.innerHTML=`<div class="jl-dock-copy"><strong>${title}</strong><span>${text}</span></div><div class="jl-dock-actions">${actions}</div>`;
  }

  function renderDice(){
    const el=$('#dice'); if(!el||!state?.room)return;
    const r=state.room, count=Number(r.rules?.dice_count||1);
    let values=Array.isArray(r.dice_values)?r.dice_values.map(Number):[];
    if(!values.length&&r.dice_result)values=[Number(r.dice_result)];
    el.classList.add('jl-dice-live');
    if(count===1){el.classList.remove('multi');el.innerHTML=values[0]?DIE[values[0]]:'🎲';return}
    el.classList.add('multi');
    const pos=Number(r.dice_position??-1);
    const display=values.length?values:Array.from({length:count},()=>0);
    el.innerHTML=display.map((v,i)=>`<span class="jl-die ${i<pos?'used':i===pos&&r.turn_phase==='move'?'current':''}">${v?DIE[v]:'🎲'}</span>`).join('');
  }

  function jump(kind){
    const map={board:'#gamePanel',rules:'.rules-panel',invite:'.invite-panel',chat:'.chat-panel',result:'#resultPanel'};
    $(map[kind]||'#gamePanel')?.scrollIntoView({behavior:'smooth',block:'start'});
  }

  async function doAction(action){
    if(busy)return;
    if(['board','rules','invite','chat','result'].includes(action)){jump(action);if(action==='invite')setTimeout(()=>$('#searchPlayer')?.focus({preventScroll:true}),400);return}
    if(action==='accept'){ $('#acceptRules')?.click(); return }
    if(action==='fund'){ $('#fundButton')?.click(); return }
    if(action==='roll'){ $('#rollDice')?.click(); return }
    if(action==='broadcast'){
      const b=$('#broadcastEveryone'); if(b){b.click();return}
      const token=localStorage.getItem(TOKEN_KEY); if(!token||!state?.room?.id)return;
      busy=true;try{await rpc('jl_ludo_rebroadcast_challenge',{p_token:token,p_room:state.room.id});await refresh()}finally{busy=false}
    }
  }

  async function refresh(){
    const token=localStorage.getItem(TOKEN_KEY); if(!token){state=null;renderHud();return}
    const status=await rpc('jl_ludo_my_status',{p_token:token});
    if(!status?.active_room_id){state=null;renderHud();return}
    const st=await rpc('jl_ludo_room_state',{p_token:token,p_room:status.active_room_id});
    if(st?.room){state=st;renderHud()}
  }

  function bind(){
    document.addEventListener('click',e=>{
      const a=e.target.closest('[data-jl-dock]'); if(a){e.preventDefault();doAction(a.dataset.jlDock);return}
      const j=e.target.closest('[data-jl-jump]'); if(j){e.preventDefault();jump(j.dataset.jlJump)}
    });
    document.addEventListener('click',e=>{if(e.target.closest('#rollDice')){const d=$('#dice');d?.animate?.([{transform:'rotate(0) scale(1)'},{transform:'rotate(18deg) scale(1.12)'},{transform:'rotate(-10deg) scale(1.04)'},{transform:'rotate(0) scale(1)'}],{duration:420})}});
  }

  function start(){ensureCss();bind();refresh();clearInterval(timer);timer=setInterval(refresh,1200);window.addEventListener('focus',refresh);document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh()})}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
