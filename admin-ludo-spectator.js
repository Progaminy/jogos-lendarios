(() => {
  'use strict';

  const cfg=window.JL_CONFIG||{};
  const TOKEN_KEY='jl_admin_token';
  const $=(id)=>document.getElementById(id);

  const PATH=[[6,1],[6,2],[6,3],[6,4],[6,5],[5,6],[4,6],[3,6],[2,6],[1,6],[0,6],[0,7],[0,8],[1,8],[2,8],[3,8],[4,8],[5,8],[6,9],[6,10],[6,11],[6,12],[6,13],[6,14],[7,14],[8,14],[8,13],[8,12],[8,11],[8,10],[8,9],[9,8],[10,8],[11,8],[12,8],[13,8],[14,8],[14,7],[14,6],[13,6],[12,6],[11,6],[10,6],[9,6],[8,5],[8,4],[8,3],[8,2],[8,1],[8,0],[7,0],[6,0]];
  const START={red:0,green:13,yellow:26,blue:39};
  const HOME={red:[[7,1],[7,2],[7,3],[7,4],[7,5]],green:[[1,7],[2,7],[3,7],[4,7],[5,7]],yellow:[[7,13],[7,12],[7,11],[7,10],[7,9]],blue:[[13,7],[12,7],[11,7],[10,7],[9,7]]};
  const BASE={red:[[1,1],[1,4],[4,1],[4,4]],green:[[1,10],[1,13],[4,10],[4,13]],yellow:[[10,10],[10,13],[13,10],[13,13]],blue:[[10,1],[10,4],[13,1],[13,4]]};
  const FINISH={red:[7,6],green:[6,7],yellow:[7,8],blue:[8,7]};
  const TRACK_LAST=50,HOME_FIRST=51,HOME_LAST=55,FINISH_STEP=56;
  const SAFE=new Set([0,8,13,21,26,34,39,47]);

  const ui={
    panel:$('ludoSpectatorPanel'),
    title:$('ludoSpectatorTitle'),
    connection:$('ludoSpectatorConnection'),
    meta:$('ludoSpectatorMeta'),
    board:$('ludoSpectatorBoard'),
    turn:$('ludoSpectatorTurn'),
    players:$('ludoSpectatorPlayers'),
    events:$('ludoSpectatorEvents'),
    message:$('ludoSpectatorMessage'),
    refresh:$('ludoSpectatorRefresh'),
    fullscreen:$('ludoSpectatorFullscreen'),
    close:$('ludoSpectatorClose'),
    roomList:$('ludoEmergencyRoomList'),
    toast:$('toast')
  };

  if(!ui.panel)return;

  let roomId='';
  let roomCode='';
  let busy=false;
  let realtimeConnected=false;
  let fallbackTimer=0;
  let clockTimer=0;
  let lastSnapshot=null;

  const esc=(v)=>String(v??'').replace(/[&<>'"]/g,(c)=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  const money=(v)=>Number(v||0).toLocaleString('pt-MZ',{minimumFractionDigits:2,maximumFractionDigits:2});
  const statusLabel=(value)=>({
    waiting:'Aguardando',
    negotiating:'Negociação',
    funding:'Confirmação',
    playing:'Em jogo',
    finished:'Finalizada',
    cancelled:'Cancelada',
    active:'Ativo',
    reentry:'Reentrada',
    left:'Saiu'
  })[String(value||'').toLowerCase()]||String(value||'—');
  const token=()=>window.JLSession?.getAdminToken?.()||sessionStorage.getItem(TOKEN_KEY)||'';

  async function rpc(name,args={}){
    const response=await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`,{
      method:'POST',
      headers:{apikey:cfg.supabaseKey,Authorization:`Bearer ${cfg.supabaseKey}`,'Content-Type':'application/json',Accept:'application/json'},
      body:JSON.stringify(args)
    });
    const raw=await response.text();
    let payload=null;
    try{payload=raw?JSON.parse(raw):null;}catch{payload=raw;}
    if(!response.ok)throw new Error(payload?.message||payload?.error||payload?.hint||`Erro ${response.status}`);
    return payload;
  }

  function toast(message,type=''){
    if(!ui.toast)return;
    ui.toast.textContent=message;
    ui.toast.className=`toast show ${type}`.trim();
    clearTimeout(toast.t);
    toast.t=setTimeout(()=>{ui.toast.className='toast';},3500);
  }

  function tokenCoord(color,step,tokenNo){
    const n=Number(step);
    if(n===-1)return BASE[color]?.[Number(tokenNo)-1]||null;
    if(n<=TRACK_LAST)return PATH[(START[color]+n)%52]||null;
    if(n<=HOME_LAST)return HOME[color]?.[n-HOME_FIRST]||null;
    if(n>=FINISH_STEP)return FINISH[color]||[7,7];
    return null;
  }

  function cellKey(rc){return rc?rc.join(','):'';}

  function boardClass(r,c){
    const classes=['ludo-watch-cell'];

    if(r<6&&c<6)classes.push('base-red');
    if(r<6&&c>8)classes.push('base-green');
    if(r>8&&c>8)classes.push('base-yellow');
    if(r>8&&c<6)classes.push('base-blue');

    const yards=[
      ['red',1,1],
      ['green',1,10],
      ['yellow',10,10],
      ['blue',10,1]
    ];
    for(const [color,r0,c0] of yards){
      if(r>=r0&&r<r0+4&&c>=c0&&c<c0+4)classes.push('yard',`yard-${color}`);
    }

    const pathIndex=PATH.findIndex(([rr,cc])=>rr===r&&cc===c);
    if(pathIndex>=0){
      classes.push('track');
      if(SAFE.has(pathIndex))classes.push('safe');
    }

    for(const color of ['red','green','yellow','blue']){
      if(HOME[color].some(([rr,cc])=>rr===r&&cc===c))classes.push(`home-${color}`);
    }

    if(r===7&&c===0)classes.push('entry-red');
    if(r===0&&c===7)classes.push('entry-green');
    if(r===7&&c===14)classes.push('entry-yellow');
    if(r===14&&c===7)classes.push('entry-blue');

    if(r>=6&&r<=8&&c>=6&&c<=8)classes.push('center');
    return classes.join(' ');
  }

  function renderBoard(snapshot){
    const players=Array.isArray(snapshot?.players)?snapshot.players:[];
    const tokens=Array.isArray(snapshot?.tokens)?snapshot.tokens:[];
    const playerMap=new Map(players.map((p)=>[String(p.player_id),p]));
    const grouped=new Map();

    for(const t of tokens){
      const p=playerMap.get(String(t.player_id));
      if(!p)continue;
      const coord=tokenCoord(String(p.color||''),Number(t.steps),Number(t.token_no));
      if(!coord)continue;
      const key=cellKey(coord);
      if(!grouped.has(key))grouped.set(key,[]);
      grouped.get(key).push({t,p});
    }

    let html='';
    for(let r=0;r<15;r++){
      for(let c=0;c<15;c++){
        const stack=grouped.get(`${r},${c}`)||[];
        html+=`<div class="${boardClass(r,c)}">`;
        if(stack.length){
          html+='<div class="ludo-watch-stack">'+stack.map(({t,p})=>{
            const pawnStyle=['current','classic','video'].includes(String(p.pawn_style||''))?String(p.pawn_style):'current';
            return `<span class="ludo-watch-piece ${esc(p.color)} pawn-style-${esc(pawnStyle)}" title="${esc(p.name||p.code)} · peão ${Number(t.token_no)}" aria-label="${esc(p.name||p.code)} peão ${Number(t.token_no)}"></span>`;
          }).join('')+'</div>';
        }
        html+='</div>';
      }
    }
    html+='<div class="ludo-watch-center" aria-hidden="true"></div>';
    ui.board.innerHTML=html;
  }

  function eventLabel(e,players){
    const p=players.find((x)=>String(x.player_id)===String(e.player_id));
    const who=p?.name||p?.code||'Jogo';
    const payload=e.payload||{};
    switch(e.event_type){
      case 'dice_rolled': return `${who} lançou ${payload.dice??(Array.isArray(payload.dice_values)?payload.dice_values.join(', '):'o dado')}`;
      case 'token_moved': return `${who} moveu o peão ${payload.token_no??''}`;
      case 'token_captured': return `${who} fez uma captura`;
      case 'turn_started': return `Vez de ${who}`;
      case 'no_legal_move': return `${who} ficou sem jogada legal`;
      case 'game_finished': return 'Partida terminada';
      case 'player_joined': return `${who} entrou na sala`;
      default:return String(e.event_type||'Atualização').replaceAll('_',' ');
    }
  }

  function updateClock(){
    const r=lastSnapshot?.room;
    if(!r||!ui.turn)return;
    const current=(lastSnapshot.players||[]).find((p)=>String(p.player_id)===String(r.current_player_id));
    let remaining='';
    if(r.action_deadline){
      const sec=Math.max(0,Math.ceil((new Date(r.action_deadline).getTime()-Date.now())/1000));
      remaining=` · ${sec}s`;
    }
    const phase=r.turn_phase==='move'?'escolher peão':r.turn_phase==='roll'?'lançar dado':(r.turn_phase||'');
    const die=Number(r.dice_result);
    ui.turn.innerHTML=r.status==='playing'
      ? `<strong>Vez de ${esc(current?.name||current?.code||'—')}</strong><span class="muted-text"> · ${esc(phase)}${remaining}</span>${Number.isFinite(die)&&die>0?`<span class="ludo-watch-die">${die}</span>`:''}`
      : `<strong>${esc(statusLabel(r.status))}</strong>`;
  }

  function render(snapshot){
    lastSnapshot=snapshot;
    const r=snapshot?.room||{};
    const players=Array.isArray(snapshot?.players)?snapshot.players:[];
    ui.title.textContent=`Assistindo ${r.code||roomCode||'Ludo'}`;
    ui.connection.innerHTML=realtimeConnected
      ? '<span class="ludo-watch-live">● Ao vivo</span>'
      : '<span class="ludo-watch-fallback">● Reconectando</span>';
    ui.meta.innerHTML=[
      `<span class="badge">${esc(statusLabel(r.status))}</span>`,
      `<span class="badge muted">${players.length}/${Number(r.player_count||0)} jogadores</span>`,
      `<span class="badge muted">${esc(r.mode==='partners'?'Parceiros':'Cada um por si')}</span>`,
      `<span class="badge muted">MZN ${money(r.bet_amount||0)} por jogador</span>`,
      `<span class="badge muted">Pote MZN ${money(r.pot||0)}</span>`
    ].join('');

    ui.players.innerHTML=players.length?players.map((p)=>{
      const current=String(p.player_id)===String(r.current_player_id);
      return `<div class="ludo-watch-player ${current?'current':''}">
        <span class="ludo-watch-dot ${esc(p.color)}"></span>
        <div><strong>${esc(p.name||p.code||'Jogador')}</strong><small>${esc(p.code||'')} · assento ${Number(p.seat||0)}${p.team?` · equipa ${Number(p.team)}`:''}</small></div>
        <small>${esc(statusLabel(p.status))}</small>
      </div>`;
    }).join(''):'<div class="empty">Nenhum jogador na sala.</div>';

    const events=Array.isArray(snapshot?.events)?snapshot.events.slice(-10).reverse():[];
    ui.events.innerHTML=events.length?events.map((e)=>`<div class="ludo-watch-event">${esc(eventLabel(e,players))}</div>`).join(''):'<div class="empty">Sem eventos recentes.</div>';

    renderBoard(snapshot);
    updateClock();
  }

  function scheduleFallback(){
    clearTimeout(fallbackTimer);
    if(!roomId)return;
    fallbackTimer=setTimeout(async()=>{
      await refresh(true);
      scheduleFallback();
    },realtimeConnected?15000:3000);
  }

  function connectRealtime(){
    if(!roomId||!window.JLLudoRealtime){
      realtimeConnected=false;
      scheduleFallback();
      return;
    }
    window.JLLudoRealtime.connect(roomId,{
      onSignal:()=>{void refresh(true);},
      onStatus:(connected)=>{
        realtimeConnected=Boolean(connected);
        if(lastSnapshot)render(lastSnapshot);
        scheduleFallback();
      }
    });
  }

  async function refresh(silent=false){
    if(!roomId||busy||!token())return;
    busy=true;
    if(ui.refresh)ui.refresh.disabled=true;
    try{
      const snapshot=await rpc('jl_admin_ludo_watch_room',{p_token:token(),p_room:roomId});
      render(snapshot);
      ui.message.textContent='';
    }catch(error){
      ui.message.textContent=error.message;
      if(!silent)toast(error.message,'error');
    }finally{
      busy=false;
      if(ui.refresh)ui.refresh.disabled=false;
    }
  }

  async function watch(id,code=''){
    roomId=String(id||'');
    roomCode=String(code||'');
    if(!roomId)return;
    ui.panel.classList.remove('hidden');
    ui.title.textContent=`A abrir ${roomCode||'partida'}…`;
    ui.message.textContent='';
    realtimeConnected=false;
    connectRealtime();
    await refresh(false);
    scheduleFallback();
    clearInterval(clockTimer);
    clockTimer=setInterval(updateClock,250);
    ui.panel.scrollIntoView({behavior:'smooth',block:'start'});
  }

  function toggleFullscreen(){
    const enabled=!ui.panel.classList.contains('ludo-spectator-fullscreen');
    ui.panel.classList.toggle('ludo-spectator-fullscreen',enabled);
    document.body.style.overflow=enabled?'hidden':'';
    ui.fullscreen?.setAttribute('aria-pressed',String(enabled));
    if(ui.fullscreen)ui.fullscreen.textContent=enabled?'↙':'⛶';
  }

  async function close(){
    roomId='';
    roomCode='';
    lastSnapshot=null;
    realtimeConnected=false;
    clearTimeout(fallbackTimer);
    clearInterval(clockTimer);
    fallbackTimer=0;
    clockTimer=0;
    try{await window.JLLudoRealtime?.disconnect?.();}catch{}
    ui.panel.classList.remove('ludo-spectator-fullscreen');
    document.body.style.overflow='';
    if(ui.fullscreen){
      ui.fullscreen.textContent='⛶';
      ui.fullscreen.setAttribute('aria-pressed','false');
    }
    ui.panel.classList.add('hidden');
  }

  ui.roomList?.addEventListener('click',(event)=>{
    const b=event.target.closest('[data-watch-ludo-room]');
    if(!b)return;
    void watch(b.dataset.watchLudoRoom,b.dataset.roomCode||'');
  });
  ui.refresh?.addEventListener('click',()=>refresh(false));
  ui.fullscreen?.addEventListener('click',toggleFullscreen);
  ui.close?.addEventListener('click',()=>{void close();});

  window.addEventListener('jl-admin-session-changed',(event)=>{
    if(!event.detail?.authenticated)void close();
  });
  document.addEventListener('visibilitychange',()=>{
    if(document.visibilityState==='visible'&&roomId)void refresh(true);
  });
  window.addEventListener('beforeunload',()=>{void window.JLLudoRealtime?.disconnect?.();},{once:true});
})();
