(() => {
  'use strict';
  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const SOUND_KEY = 'jl_ludo_sound_enabled';
  const $ = (id) => document.getElementById(id);
  const state = {
    token: localStorage.getItem(TOKEN_KEY) || '', status: null, room: null,
    pollTimer: null, timeoutTimer: null, clockTimer: null, signalTimer: null,
    lastSignalId: 0, localStream: null, micMuted: true, peers: new Map(), busy: false,
    animating: false, soundEnabled: localStorage.getItem(SOUND_KEY) !== '0', audioCtx: null,
    rulesFormDirty: false, rulesFormVersion: null, rulesDeclinedVersion: null, lastFxEventId: 0, autoMoveKey: null, lastDirectInviteCount: 0
  };
  const els = Object.fromEntries([
    'toast','identityBadge','accountButton','accountMenu','accountMenuCode','accountMenuBalance','accountMenuDeposit','accountMenuWithdraw','accountMenuLogout','ludoStatusStrip','onlinePlayerCount','directNotificationMetric','publicNotificationMetric','topDirectInviteCount','topPublicInviteCount','loggedOut','lobby','boardLobby','ludoLobbyBoard','balanceBadge','createRoomForm','createPlayers','createMode','createBet','createPublic',
    'joinCodeForm','joinCode','queueForm','queuePlayers','queueMode','queueBet','queueButton','queueStatus','notificationCenter','inviteList','directInviteCount','publicChallengeList','publicChallengeCount','refreshLobby',
    'room','roomCode','roomMeta','roomPot','roomPrize','copyRoomCode','leaveRoom','forfeitRoom','deadlineBar','deadlineLabel','deadlineClock','playersPanel',
    'rulesVersion','rulesSummary','rulesForm','rulesDecision','acceptRules','declineRules','rulesAcceptModal','rulesAcceptTitle','rulesAcceptSummary','rulesModalAccept','rulesModalDecline','stakeAcceptModal','stakeAcceptTitle','stakeAcceptText','stakeBalanceText','stakeModalAccept','searchPlayerForm','searchPlayer','playerSearchResults','refreshWaiting','waitingPlayers',
    'fundingPanel','fundingText','fundButton','gamePanel','turnTitle','dice','ludoBoard','rollDice','soundToggle','micQuickButton','moveHint','reenterButton','voiceState','micButton','remoteAudio',
    'chatMessages','chatForm','chatInput','resultPanel','resultTitle','resultPayouts','rematchBet','rematchButton','rematchHelp','authModal','closeAuth','loginTab','registerTab','loginForm','registerForm','loginPhone','loginPin',
    'registerName','registerPhone','registerPin','registerPinConfirm','authMessage','winModal','winModalTitle','winModalMessage','winModalOk'
  ].map(k => [k, $(k)]));

  const PATH = [[6,1],[6,2],[6,3],[6,4],[6,5],[5,6],[4,6],[3,6],[2,6],[1,6],[0,6],[0,7],[0,8],[1,8],[2,8],[3,8],[4,8],[5,8],[6,9],[6,10],[6,11],[6,12],[6,13],[6,14],[7,14],[8,14],[8,13],[8,12],[8,11],[8,10],[8,9],[9,8],[10,8],[11,8],[12,8],[13,8],[14,8],[14,7],[14,6],[13,6],[12,6],[11,6],[10,6],[9,6],[8,5],[8,4],[8,3],[8,2],[8,1],[8,0],[7,0],[6,0]];
  const START = { red:0, green:13, yellow:26, blue:39 };
  const HOME = { red:[[7,1],[7,2],[7,3],[7,4],[7,5]], green:[[1,7],[2,7],[3,7],[4,7],[5,7]], yellow:[[7,13],[7,12],[7,11],[7,10],[7,9]], blue:[[13,7],[12,7],[11,7],[10,7],[9,7]] };
  const BASE = { red:[[1,1],[1,4],[4,1],[4,4]], green:[[1,10],[1,13],[4,10],[4,13]], yellow:[[10,10],[10,13],[13,10],[13,13]], blue:[[10,1],[10,4],[13,1],[13,4]] };
  const SAFE = new Set([0,8,13,21,26,34,39,47]);
  const TRACK_LAST_STEP=50;
  const HOME_FIRST_STEP=51;
  const HOME_LAST_STEP=55;
  const FINISH_STEP=56;
  const DICE_LAYOUTS={1:[5],2:[1,9],3:[1,5,9],4:[1,3,7,9],5:[1,3,5,7,9],6:[1,3,4,6,7,9]};

  function renderDiceFace(value){
    if(!els.dice)return;
    const n=Number(value);
    els.dice.classList.remove('rolling');
    els.dice.replaceChildren();
    if(!Number.isInteger(n)||n<1||n>6){
      els.dice.classList.add('empty');
      els.dice.removeAttribute('data-value');
      els.dice.setAttribute('aria-label','Dado ainda não lançado');
      const q=document.createElement('span');q.className='dice-placeholder';q.textContent='?';els.dice.appendChild(q);return;
    }
    els.dice.classList.remove('empty');
    els.dice.dataset.value=String(n);
    els.dice.setAttribute('aria-label',`Dado: ${n}`);
    const visible=new Set(DICE_LAYOUTS[n]);
    for(let i=1;i<=9;i++){const pip=document.createElement('span');pip.className=`pip p${i}${visible.has(i)?' on':''}`;els.dice.appendChild(pip);}
  }

  function updateSoundButton(){
    if(!els.soundToggle)return;
    els.soundToggle.textContent=state.soundEnabled?'🔊 Som':'🔇 Som';
    els.soundToggle.setAttribute('aria-pressed',state.soundEnabled?'true':'false');
    els.soundToggle.title=state.soundEnabled?'Desativar sons do Ludo':'Ativar sons do Ludo';
  }
  function toggleSound(){
    state.soundEnabled=!state.soundEnabled;
    localStorage.setItem(SOUND_KEY,state.soundEnabled?'1':'0');
    if(state.soundEnabled)ensureAudio();
    updateSoundButton();
  }
  function ensureAudio(){
    if(!state.soundEnabled)return null;
    const AudioCtx=window.AudioContext||window.webkitAudioContext;
    if(!AudioCtx)return null;
    if(!state.audioCtx)state.audioCtx=new AudioCtx();
    if(state.audioCtx.state==='suspended')state.audioCtx.resume().catch(()=>{});
    return state.audioCtx;
  }
  function soundTone(freq,duration,volume=.035,delay=0,type='triangle'){
    const ctx=ensureAudio();if(!ctx)return;
    const start=ctx.currentTime+delay;
    const osc=ctx.createOscillator(),gain=ctx.createGain();
    osc.type=type;osc.frequency.setValueAtTime(freq,start);
    gain.gain.setValueAtTime(.0001,start);
    gain.gain.exponentialRampToValueAtTime(Math.max(.0002,volume),start+.008);
    gain.gain.exponentialRampToValueAtTime(.0001,start+duration);
    osc.connect(gain);gain.connect(ctx.destination);osc.start(start);osc.stop(start+duration+.02);
  }
  function playRollSound(){
    if(!state.soundEnabled)return;
    ensureAudio();
    [0,.055,.11,.165,.22,.275,.33,.385].forEach((d,i)=>soundTone(170+(i%3)*45,.05,.035,d,i%2?'square':'triangle'));
  }
  function playStepSound(stepIndex){
    if(!state.soundEnabled)return;
    soundTone(300+(stepIndex%2)*55,.045,.022,0,'sine');
  }
  function playCaptureSound(){
    if(!state.soundEnabled)return;
    soundTone(620,.07,.07,0,'square');
    soundTone(310,.11,.075,.07,'sawtooth');
  }
  function playHomeSound(){
    if(!state.soundEnabled)return;
    [440,660,880].forEach((f,i)=>soundTone(f,.12,.055,i*.08,'triangle'));
  }
  function noiseBurst(delay=0,duration=.18,volume=.08){
    const ctx=ensureAudio();if(!ctx)return;
    const length=Math.max(1,Math.floor(ctx.sampleRate*duration));
    const buffer=ctx.createBuffer(1,length,ctx.sampleRate);
    const data=buffer.getChannelData(0);
    for(let i=0;i<length;i++)data[i]=(Math.random()*2-1)*(1-i/length);
    const src=ctx.createBufferSource(),gain=ctx.createGain();
    src.buffer=buffer;
    const start=ctx.currentTime+delay;
    gain.gain.setValueAtTime(Math.max(.001,volume),start);
    gain.gain.exponentialRampToValueAtTime(.0001,start+duration);
    src.connect(gain);gain.connect(ctx.destination);src.start(start);
  }
  function playFireworksSound(){
    if(!state.soundEnabled)return;
    [0,.22,.46,.72].forEach((d,i)=>{
      soundTone(520+i*90,.18,.045,d,'sine');
      soundTone(980+i*70,.10,.035,d+.08,'triangle');
      noiseBurst(d+.12,.24,.10);
    });
  }
  function processGameEffects(room){
    const events=(room?.events||[]).slice().sort((a,b)=>Number(a.id)-Number(b.id));
    if(!events.length)return;
    const maxId=Math.max(...events.map(e=>Number(e.id)||0));
    if(!state.lastFxEventId){state.lastFxEventId=maxId;return;}
    const fresh=events.filter(e=>(Number(e.id)||0)>state.lastFxEventId);
    for(const event of fresh){
      if(event.event_type==='token_captured')playCaptureSound();
      if(event.event_type==='token_moved'&&Number(event.payload?.to_steps)===56)playHomeSound();
      if(event.event_type==='game_finished')setTimeout(playFireworksSound,120);
    }
    state.lastFxEventId=Math.max(state.lastFxEventId,maxId);
  }
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const TOKEN_STEP_MS=95;
  function tokenCoord(color,step,tokenNo){
    if(step===-1)return BASE[color]?.[Number(tokenNo)-1]||null;
    if(step<=TRACK_LAST_STEP)return PATH[(START[color]+step)%52];
    if(step<=HOME_LAST_STEP)return HOME[color]?.[step-HOME_FIRST_STEP]||null;
    return [7,7];
  }
  async function animateTokenPath(playerId,tokenNo,color,fromSteps,toSteps){
    if(!els.ludoBoard||!Number.isFinite(fromSteps)||!Number.isFinite(toSteps)||toSteps<=fromSteps)return;
    const selector=`[data-player-id="${CSS.escape(String(playerId))}"][data-token-no="${Number(tokenNo)}"]`;
    const piece=els.ludoBoard.querySelector(selector);
    if(!piece)return;
    const totalSteps=toSteps-fromSteps;
    els.ludoBoard.classList.add('piece-moving');
    els.rollDice.disabled=true;
    let visualIndex=0;
    for(let step=fromSteps+1;step<=toSteps;step++){
      const coord=tokenCoord(color,step,tokenNo);
      if(!coord)continue;
      const cell=els.ludoBoard.querySelector(`[data-row="${coord[0]}"][data-col="${coord[1]}"]`);
      if(!cell)continue;
      visualIndex+=1;
      els.moveHint.textContent=`Peão em movimento · ${visualIndex}/${totalSteps}`;
      piece.style.setProperty('--dx','0%');
      piece.style.setProperty('--dy','0%');
      cell.appendChild(piece);
      piece.classList.remove('step-hop');
      void piece.offsetWidth;
      piece.classList.add('step-hop');
      playStepSound(visualIndex);
      await wait(TOKEN_STEP_MS);
    }
    piece.classList.remove('step-hop');
    els.ludoBoard.classList.remove('piece-moving');
  }
  function detectForwardMove(previous,next){
    if(!previous?.tokens||!next?.tokens)return null;
    const prev=new Map(previous.tokens.map(t=>[`${t.player_id}:${t.token_no}`,Number(t.steps)]));
    for(const t of next.tokens){
      const from=prev.get(`${t.player_id}:${t.token_no}`);
      const to=Number(t.steps);
      if(from===undefined)continue;
      if((from===-1&&to===0)||(from>=0&&to>from)){
        const p=(next.players||[]).find(x=>x.player_id===t.player_id);
        if(p)return {playerId:t.player_id,tokenNo:Number(t.token_no),color:p.color,fromSteps:from,toSteps:to};
      }
    }
    return null;
  }

  function decorateClassicBoard(cells){
    const at=(r,c)=>cells[r*15+c];
    const yards=[
      ['red',1,1],['green',1,10],['yellow',10,10],['blue',10,1]
    ];
    for(const [color,r0,c0] of yards)for(let r=r0;r<r0+4;r++)for(let c=c0;c<c0+4;c++)at(r,c).classList.add('yard',`yard-${color}`);
    at(7,0).classList.add('entry-arrow','entry-red');
    at(0,7).classList.add('entry-arrow','entry-green');
    at(7,14).classList.add('entry-arrow','entry-yellow');
    at(14,7).classList.add('entry-arrow','entry-blue');
  }
  function classicCenter(){
    const center=document.createElement('div');
    center.className='ludo-center';
    center.setAttribute('aria-hidden','true');
    return center;
  }

  function escapeHtml(v){return String(v ?? '').replace(/[&<>'\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','\"':'&quot;'}[c]));}
  function money(v){return Number(v||0).toLocaleString('pt-MZ',{minimumFractionDigits:2,maximumFractionDigits:2});}
  function showToast(msg,type=''){els.toast.textContent=msg;els.toast.className=`toast show ${type}`;clearTimeout(showToast.t);showToast.t=setTimeout(()=>els.toast.className='toast',3500);}
  function wholeStake(value,label='A aposta'){const amount=Number(value);if(!Number.isFinite(amount)||!Number.isInteger(amount)||amount<10){showToast(`${label} deve ser um valor inteiro a partir de 10 MZN.`,'error');return null;}return amount;}

  function redirectToDeposit(check, context='continuar no Ludo'){
    const missing=Math.max(1,Math.ceil(Number(check?.shortfall||0)));
    const message=`Saldo insuficiente para ${context}. Faltam ${money(missing)} MZN. Você será levado ao depósito.`;
    showToast(message,'error');
    const url=`./index.html?deposit_needed=${encodeURIComponent(missing)}&from=ludo#depositPanel`;
    setTimeout(()=>{window.location.href=url;},350);
  }

  async function ensureLudoFunds(amount,context){
    const check=await rpc('jl_check_funds',{
      p_token:state.token,
      p_game_type:'ludo',
      p_amount:Number(amount)
    });
    if(check?.ok)return true;
    if(check?.redirect_to_deposit){
      redirectToDeposit(check,context);
      return false;
    }
    showToast('Saldo insuficiente para continuar.','error');
    return false;
  }

  function handleLudoMoneyError(err,context='continuar no Ludo'){
    const message=String(err?.message||err||'');
    const m=message.match(/Faltam\s+([\d.,]+)\s+MZN/i);
    if(/saldo insuficiente/i.test(message)){
      const shortfall=m?Number(m[1].replace(/\./g,'').replace(',','.')):Math.max(1,10-Number(state.status?.identity?.balance||0));
      redirectToDeposit({shortfall,redirect_to_deposit:true},context);
      return true;
    }
    return false;
  }
  function latestDiceRoll(){const events=state.room?.events||[];for(let i=events.length-1;i>=0;i--){const event=events[i];if(event?.event_type!=='dice_rolled')continue;const payload=event.payload||{};const values=Array.isArray(payload.dice_values)?payload.dice_values.map(Number).filter(v=>Number.isInteger(v)&&v>=1&&v<=6):[];if(values.length)return{values,playerId:event.player_id,createdAt:event.created_at};const die=Number(payload.dice);if(Number.isInteger(die)&&die>=1&&die<=6)return{values:[die],playerId:event.player_id,createdAt:event.created_at};}return null;}
  function visibleDiceValue(room){const active=Number(room?.dice_result);if(Number.isInteger(active)&&active>=1&&active<=6)return active;return latestDiceRoll()?.values?.[0]??null;}
  function setAuthMessage(msg='',type=''){els.authMessage.textContent=msg;els.authMessage.style.color=type==='error'?'#ff8994':type==='success'?'#8df1bb':'';}

  const LUDO_WIN_SEEN_KEY='jl_seen_ludo_wins_v1';
  function ludoWinSeen(){try{return new Set(JSON.parse(localStorage.getItem(LUDO_WIN_SEEN_KEY)||'[]'));}catch{return new Set();}}
  function saveLudoWinSeen(seen){try{localStorage.setItem(LUDO_WIN_SEEN_KEY,JSON.stringify([...seen].slice(-100)));}catch{}}
  function ludoRoundTime(r){const raw=r?.finished_at||r?.ended_at||r?.updated_at||r?.created_at;if(!raw)return'hora não disponível';const d=new Date(raw);return Number.isNaN(d.getTime())?'hora não disponível':d.toLocaleTimeString('pt-MZ',{hour:'2-digit',minute:'2-digit'});}
  function showLudoWinNotice(key,amount,roundLabel,roundTime){if(!els.winModal)return;els.winModalTitle.textContent='Parabéns!';els.winModalMessage.textContent=`Você venceu a partida de Ludo e ganhou ${money(amount)} MZN. Partida ${roundLabel} · hora ${roundTime}. O valor foi creditado no seu saldo.`;els.winModal.dataset.winKey=key;els.winModal.classList.remove('hidden');document.body.classList.add('modal-open');}
  function closeLudoWinNotice(){if(!els.winModal)return;const key=els.winModal.dataset.winKey;if(key){const seen=ludoWinSeen();seen.add(key);saveLudoWinSeen(seen);}els.winModal.classList.add('hidden');document.body.classList.remove('modal-open');delete els.winModal.dataset.winKey;}
  function checkLudoWinNotice(){const r=roomData();if(!r||r.status!=='finished'||!els.winModal?.classList.contains('hidden'))return;const payout=(state.room?.payouts||[]).find(p=>p.player_id===me()&&Number(p.net||0)>0);if(!payout)return;const key=`${r.id||r.code||'room'}:${me()}:${payout.net}`;if(ludoWinSeen().has(key))return;showLudoWinNotice(key,payout.net,r.code||r.id||'—',ludoRoundTime(r));}
  async function rpc(name,args={}){if(!cfg.supabaseUrl||!cfg.supabaseKey)throw new Error('Configuração do Supabase ausente.');const res=await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:`Bearer ${cfg.supabaseKey}`,'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify(args)});const text=await res.text();let data=null;try{data=text?JSON.parse(text):null}catch{data=text}if(!res.ok)throw new Error(data?.message||data?.hint||data?.error||`Erro ${res.status}`);return data;}
  function saveToken(t){state.token=t||'';if(t)localStorage.setItem(TOKEN_KEY,t);else localStorage.removeItem(TOKEN_KEY);}
  function openAuth(mode='login'){els.authModal.classList.remove('hidden');switchAuth(mode);} function closeAuth(){els.authModal.classList.add('hidden');setAuthMessage('');}
  function switchAuth(mode){const login=mode==='login';els.loginForm.classList.toggle('hidden',!login);els.registerForm.classList.toggle('hidden',login);els.loginTab.classList.toggle('active',login);els.registerTab.classList.toggle('active',!login);}
  function me(){return state.room?.identity?.player_id||state.status?.identity?.player_id||null;} function roomData(){return state.room?.room||null;} function roomPlayers(){return state.room?.players||[];} function myRoomPlayer(){return roomPlayers().find(p=>p.player_id===me());} function isHost(){return roomData()?.host_id===me();} function rules(){return roomData()?.rules||{};}
  function syncPlayerCountPicker(selectId){const select=$(selectId);const picker=document.querySelector(`.player-count-picker[data-select-id="${selectId}"]`);if(!select||!picker)return;picker.querySelectorAll('[data-player-count]').forEach(b=>{const active=String(b.dataset.playerCount)===String(select.value);b.classList.toggle('active',active);b.setAttribute('aria-pressed',active?'true':'false');});}
  function setPlayerCount(selectId,value){const select=$(selectId);if(!select)return;select.value=String(value);syncPlayerCountPicker(selectId);select.dispatchEvent(new Event('change',{bubbles:true}));}
  function wirePlayerCountPicker(selectId){const picker=document.querySelector(`.player-count-picker[data-select-id="${selectId}"]`);if(!picker)return;picker.addEventListener('click',e=>{const b=e.target.closest('[data-player-count]');if(!b)return;setPlayerCount(selectId,b.dataset.playerCount);});syncPlayerCountPicker(selectId);}
  function syncCapturePenaltyAvailability(){const r=roomData();const form=els.rulesForm;if(!form)return;const penalty=form.elements.capture_penalty;const help=$('capturePenaltyHelp');if(!penalty)return;const twoPlayers=Number(r?.player_count)===2;if(twoPlayers){penalty.value='lose_turn';for(const opt of penalty.options)opt.disabled=opt.value!=='lose_turn';if(help)help.textContent='Com 2 jogadores, ignorar captura apenas faz perder a vez; eliminação só existe com 3 ou 4 jogadores.';}else{for(const opt of penalty.options)opt.disabled=false;if(help)help.textContent='Com 3 ou 4 jogadores, o anfitrião pode escolher perder a vez, eliminar ou permitir reentrada.';}}

  function renderStaticBoard(target,colors=['red','green','yellow','blue']){if(!target)return;const cells=[];for(let i=0;i<225;i++){const d=document.createElement('div');d.className='cell';d.dataset.row=String(Math.floor(i/15));d.dataset.col=String(i%15);cells.push(d);}const at=(row,col)=>cells[row*15+col];for(let rr=0;rr<6;rr++)for(let cc=0;cc<6;cc++)at(rr,cc).classList.add('base','red');for(let rr=0;rr<6;rr++)for(let cc=9;cc<15;cc++)at(rr,cc).classList.add('base','green');for(let rr=9;rr<15;rr++)for(let cc=9;cc<15;cc++)at(rr,cc).classList.add('base','yellow');for(let rr=9;rr<15;rr++)for(let cc=0;cc<6;cc++)at(rr,cc).classList.add('base','blue');PATH.forEach(([r,c],i)=>{at(r,c).classList.add('path');if(SAFE.has(i))at(r,c).classList.add('safe');});Object.entries(HOME).forEach(([color,coords])=>coords.forEach(([r,c])=>at(r,c).classList.add(`home-${color}`)));for(let r=6;r<=8;r++)for(let c=6;c<=8;c++)at(r,c).classList.add('center');decorateClassicBoard(cells);for(const color of colors){if(!BASE[color])continue;BASE[color].forEach(([r,c],index)=>{const p=document.createElement('span');p.className=`piece ${color} preview-piece`;p.textContent=index+1;p.setAttribute('aria-hidden','true');at(r,c).appendChild(p);});}target.replaceChildren(...cells,classicCenter());}
  function renderLobbyBoard(){renderStaticBoard(els.ludoLobbyBoard);}
  function renderPregameBoard(){const colors=roomPlayers().filter(p=>p.status!=='left'&&BASE[p.color]).map(p=>p.color);renderStaticBoard(els.ludoBoard,colors);}

  async function loadStatus(silent=false){
    if(state.animating)return;
    if(!state.token){state.status=null;state.room=null;renderAll();return;}
    try{
      const nextStatus=await rpc('jl_ludo_my_status',{p_token:state.token});
      let nextRoom=null;
      if(nextStatus?.active_room_id){
        nextRoom=await rpc('jl_ludo_room_state',{p_token:state.token,p_room:nextStatus.active_room_id});
      }
      try{nextStatus.public_challenges=await rpc('jl_ludo_public_challenges',{p_token:state.token});}
      catch{nextStatus.public_challenges=[];}
      if(state.animating)return;
      const movement=state.room&&nextRoom&&state.room.room?.id===nextRoom.room?.id?detectForwardMove(state.room,nextRoom):null;
      state.status=nextStatus;
      if(movement&&els.ludoBoard?.childElementCount){
        state.animating=true;
        try{await animateTokenPath(movement.playerId,movement.tokenNo,movement.color,movement.fromSteps,movement.toSteps);}finally{state.animating=false;}
      }
      if(state.room&&!nextRoom)closeVoice();
      state.room=nextRoom;
      renderAll();
    }catch(e){
      if(/Sessão/.test(e.message)){saveToken('');state.status=null;state.room=null;renderAll();}
      if(!silent)showToast(e.message,'error');
    }
  }
  async function processTimeouts(){if(!state.token||!state.room?.room?.id||state.busy||state.animating)return;try{const nextRoom=await rpc('jl_ludo_process_timeouts',{p_token:state.token,p_room:state.room.room.id});processGameEffects(nextRoom);state.room=nextRoom;renderRoom();}catch{}}
  function renderAll(){const authed=Boolean(state.token&&state.status?.identity);els.ludoStatusStrip?.classList.toggle('hidden',!authed);els.loggedOut.classList.toggle('hidden',authed);els.lobby.classList.toggle('hidden',!authed||Boolean(state.room));els.notificationCenter?.classList.toggle('hidden',!authed);els.room.classList.toggle('hidden',!state.room);els.boardLobby.classList.toggle('hidden',Boolean(state.room));if(!state.room)renderLobbyBoard();if(authed){const i=state.status.identity;els.identityBadge.textContent=`${i.code} · ${money(i.balance)} MZN`;els.accountButton.textContent=i.name||i.code;els.accountMenuCode.textContent=`${i.name||'Jogador'} · ${i.code}`;els.accountMenuBalance.textContent=`${money(i.balance)} MZN`;els.balanceBadge.textContent=`${money(i.balance)} MZN`;renderLobby();}else{els.identityBadge.textContent='Não autenticado';els.accountButton.textContent='Entrar';els.accountMenu?.classList.add('hidden');els.accountButton.setAttribute('aria-expanded','false');}if(state.room)renderRoom();}
  function renderLobby(){
    const s=state.status;if(!s)return;
    if(s.queue){
      els.queueStatus.classList.remove('hidden');
      els.queueStatus.innerHTML=`Em espera: <strong>${s.queue.player_count} jogadores</strong> · ${escapeHtml(s.queue.mode)} · <strong>${money(s.queue.bet_amount)} MZN</strong><br><small>Expira ${new Date(s.queue.expires_at).toLocaleTimeString('pt-MZ')}</small>`;
      els.queueButton.textContent='Sair da espera';els.queueButton.dataset.queued='1';
    }else{
      els.queueStatus.classList.add('hidden');els.queueButton.textContent='Quero jogar';delete els.queueButton.dataset.queued;
    }

    const invites=s.invites||[];
    const challenges=s.public_challenges||[];
    const roomBusy=Boolean(state.room);
    const canSwitchOwnRoom=Boolean(state.room&&isHost()&&['waiting','negotiating'].includes(roomData()?.status));
    const onlineCount=Math.max(0,Number(s.online_count)||0);
    if(els.onlinePlayerCount)els.onlinePlayerCount.textContent=String(onlineCount);
    if(els.directInviteCount)els.directInviteCount.textContent=String(invites.length);
    if(els.topDirectInviteCount)els.topDirectInviteCount.textContent=String(invites.length);
    if(els.publicChallengeCount)els.publicChallengeCount.textContent=String(challenges.length);
    if(els.topPublicInviteCount)els.topPublicInviteCount.textContent=String(challenges.length);
    els.directNotificationMetric?.classList.toggle('has-items',invites.length>0);
    els.publicNotificationMetric?.classList.toggle('has-items',challenges.length>0);
    els.notificationCenter?.classList.toggle('has-direct',invites.length>0);
    if(invites.length>state.lastDirectInviteCount&&state.lastDirectInviteCount>=0)showToast(`🔔 Você recebeu ${invites.length-state.lastDirectInviteCount} novo(s) convite(s) individual(is).`,'success');
    state.lastDirectInviteCount=invites.length;
    els.inviteList.innerHTML=invites.length?invites.map(i=>`<div class="invite-card direct-invite"><div><span class="notice-kind direct">INDIVIDUAL</span><strong>${escapeHtml(i.host)} · ${escapeHtml(i.host_code)}</strong><br><small>${escapeHtml(i.room_code)} · ${i.player_count} jogadores · ${escapeHtml(i.mode)} · ${money(i.bet_amount)} MZN</small>${canSwitchOwnRoom?'<span class="invite-switch-note">Pode aceitar: você sairá da sua sala atual e entrará nesta.</span>':''}</div><div class="notice-actions"><button class="button success small" data-invite-accept="${i.id}" data-bet-amount="${Number(i.bet_amount||0)}" ${roomBusy&&!canSwitchOwnRoom?'disabled title="Termine ou saia da sala atual para aceitar outro convite."':''}>Aceitar</button><button class="button danger small" data-invite-decline="${i.id}">Recusar</button></div></div>`).join(''):'<div class="empty">Nenhum convite individual recebido.</div>';
    els.publicChallengeList.innerHTML=challenges.length?challenges.map(c=>{
      const raw=String(c.expires_at||'');
      const ms=Date.parse(raw);
      const expiry=raw&&!/infinity/i.test(raw)&&Number.isFinite(ms)
        ? `Disponível por ${Math.max(0,Math.ceil((ms-Date.now())/1000))}s`
        : 'Sem prazo enquanto houver vaga';
      return `<div class="invite-card public-challenge"><div><span class="notice-kind public">POPULAR</span><strong>${escapeHtml(c.host_name)} · ${escapeHtml(c.host_code)}</strong><br><small>${escapeHtml(c.code)} · ${c.joined_count}/${c.player_count} jogadores · ${escapeHtml(c.mode)} · ${money(c.bet_amount)} MZN${c.play_location?` · ${escapeHtml(c.play_location)}`:''}</small><br><small class="challenge-expiry">${expiry}</small></div><div class="notice-actions"><button class="button secondary small" data-public-accept="${escapeHtml(c.code)}" data-bet-amount="${Number(c.bet_amount||0)}" ${roomBusy?'disabled title="Termine ou desista da partida atual para entrar noutro convite."':''}>Entrar</button></div></div>`;
    }).join(''):'<div class="empty">Nenhum convite popular disponível agora.</div>';
  }
  function commissionText(){const r=roomData();if(!r)return '—';const pot=Number(r.pot||0)||Number(r.bet_amount||0)*Number(r.player_count||0);if(r.mode==='partners'){const gross=pot/2,comm=Math.min(gross,Math.max(1,Math.ceil(gross*.01)));return `Dupla vencedora: ${money(gross)} MZN brutos por parceiro · comissão ${money(comm)} MZN por parceiro · ${money(gross-comm)} MZN líquidos cada.`;}const comm=Math.min(pot,Math.max(1,Math.ceil(pot*.01)));return `Vencedor: ${money(pot)} MZN brutos · comissão ${money(comm)} MZN · ${money(pot-comm)} MZN líquidos.`;}
  function renderRoom(){const r=roomData();if(!r)return;els.roomCode.textContent=r.code;els.roomMeta.textContent=`${r.player_count} jogadores · ${r.mode==='partners'?'Parceiros 2 × 2':'Cada um por si'} · ${money(r.bet_amount)} MZN por jogador · ${r.is_public?'Pública':'Privada'}`;els.roomPot.textContent=`${money(r.pot)} MZN`;els.roomPrize.textContent=commissionText();els.rulesVersion.textContent=`v${r.rules_version}`;const playing=r.status==='playing';els.leaveRoom?.classList.toggle('hidden',playing);els.forfeitRoom?.classList.toggle('hidden',!playing);renderPlayers();renderRules();renderDeadline();renderFunding();renderGame();renderResult();renderInviter();syncEntryFlowModals();}
  function entryRuleRows(){
    const r=roomData(),x=rules();
    const rows=[
      `Jogada: ${x.turn_seconds}s · escolher peça: ${x.move_seconds}s`,
      'Saída da base: somente 6',
      boolLabel(x.capture_required,`Captura obrigatória · penalização: ${x.capture_penalty}`,'Captura não obrigatória'),
      boolLabel(x.reentry_allowed,`Reentrada: ${money(x.reentry_amount)} MZN`,'Sem reentrada'),
      boolLabel(x.safe_cells,'Casas seguras ativas','Sem casas seguras'),
      'Passagem livre: peças nunca bloqueiam o caminho',
      boolLabel(x.exact_finish,'Chegada exige valor exato','Pode ultrapassar e concluir'),
      'Tempo esgotado: passa a vez; o jogador permanece na partida',
      'Microfone pode ser ligado ou desligado durante o jogo'
    ];
    if(r?.mode==='partners')rows.push(boolLabel(x.partner_capture,'Parceiros podem capturar-se','Parceiros não podem capturar-se'));
    return rows;
  }
  function closeEntryFlowModals(){
    els.rulesAcceptModal?.classList.add('hidden');
    els.stakeAcceptModal?.classList.add('hidden');
    document.body.classList.remove('flow-modal-open');
  }
  function syncEntryFlowModals(){
    const r=roomData(),mine=myRoomPlayer();
    if(!r||!mine||['playing','finished','cancelled'].includes(r.status)){closeEntryFlowModals();return;}
    const needsRules=['waiting','negotiating'].includes(r.status)&&mine.accepted_rules_version!==r.rules_version&&state.rulesDeclinedVersion!==r.rules_version;
    const needsStake=r.status==='funding'&&!mine.stake_paid;
    if(needsRules){
      els.stakeAcceptModal?.classList.add('hidden');
      els.rulesAcceptSummary.innerHTML=entryRuleRows().map(v=>`<div class="rule-chip">${escapeHtml(v)}</div>`).join('');
      els.rulesAcceptTitle.textContent=`Aceitar regras · v${r.rules_version}`;
      els.rulesAcceptModal?.classList.remove('hidden');
      document.body.classList.add('flow-modal-open');
      return;
    }
    els.rulesAcceptModal?.classList.add('hidden');
    if(needsStake){
      els.stakeAcceptTitle.textContent='Aceitar valor da aposta';
      els.stakeAcceptText.textContent=`${money(r.bet_amount)} MZN por jogador`;
      const balance=Number(state.status?.identity?.balance??0);
      els.stakeBalanceText.textContent=`Seu saldo: ${money(balance)} MZN · depois da confirmação: ${money(Math.max(0,balance-Number(r.bet_amount||0)))} MZN`;
      els.stakeModalAccept.textContent=`Confirmar ${money(r.bet_amount)} MZN e entrar`;
      els.stakeAcceptModal?.classList.remove('hidden');
      document.body.classList.add('flow-modal-open');
      return;
    }
    closeEntryFlowModals();
  }
  function renderPlayers(){const r=roomData(),list=roomPlayers();els.playersPanel.innerHTML=Array.from({length:r.player_count},(_,idx)=>{const seat=idx+1,p=list.find(x=>x.seat===seat);if(!p)return `<div class="player-card"><small>Vaga ${seat}</small><h3>Aguardando jogador…</h3></div>`;const accepted=p.accepted_rules_version===r.rules_version,current=r.current_player_id===p.player_id;return `<div class="player-card ${p.color} ${current?'current':''}"><span class="color-dot"></span><small> ${p.team?`Equipa ${p.team} · `:''}posição ${p.seat}</small><h3>${escapeHtml(p.name)}</h3><small>${escapeHtml(p.code)}</small><div class="player-flags"><span class="flag ${accepted?'ok':'wait'}">${accepted?'✓ regras':'regras…'}</span><span class="flag ${p.stake_paid?'ok':'wait'}">${p.stake_paid?'✓ aposta':'aposta…'}</span><span class="flag">${escapeHtml(p.status)}</span>${p.timeout_strikes?`<span class="flag wait">${p.timeout_strikes} atraso(s)</span>`:''}</div></div>`;}).join('');}
  const boolLabel=(v,a,b)=>v?a:b;
  function renderRules(){const r=roomData(),x=rules();const rows=[`Jogada: ${x.turn_seconds}s · escolher peça: ${x.move_seconds}s`,'Saída da base: somente 6',boolLabel(x.capture_required,`Captura obrigatória · penalização: ${x.capture_penalty}`,'Captura não obrigatória'),boolLabel(x.reentry_allowed,`Reentrada: ${money(x.reentry_amount)} MZN em ${x.reentry_seconds}s`,'Sem reentrada'),boolLabel(x.six_extra_turn,'6 dá nova jogada','6 não dá nova jogada'),boolLabel(x.capture_extra_turn,'Captura dá nova jogada','Captura não dá nova jogada'),boolLabel(x.three_sixes_penalty,'Três 6 seguidos perdem a jogada','Sem penalização de três 6'),boolLabel(x.safe_cells,'Casas seguras ativas','Sem casas seguras'),'Passagem livre: peças nunca bloqueiam o caminho',boolLabel(x.exact_finish,'Chegada exata','Pode ultrapassar e concluir'),`Tempo esgotado: passa a vez; o jogador permanece na partida`,'Microfone: cada jogador pode ligar ou desligar durante a partida',boolLabel(x.chat_enabled,'Chat permitido','Chat desativado')];if(r.mode==='partners')rows.push(boolLabel(x.partner_capture,'Parceiros podem capturar-se','Parceiros não podem capturar-se'));els.rulesSummary.innerHTML=rows.map(v=>`<div class="rule-chip">${escapeHtml(v)}</div>`).join('');const canEdit=isHost()&&['waiting','negotiating'].includes(r.status);els.rulesForm.classList.toggle('hidden',!canEdit);document.querySelectorAll('.partner-rule').forEach(el=>el.classList.toggle('hidden',r.mode!=='partners'));if(canEdit){if(state.rulesFormVersion!==r.rules_version){state.rulesFormVersion=r.rules_version;state.rulesFormDirty=false;}if(!state.rulesFormDirty)fillRulesForm(x);syncCapturePenaltyAvailability();}const mine=myRoomPlayer();const declined=mine?.accepted_rules_version!==r.rules_version&&state.rulesDeclinedVersion===r.rules_version;if(els.rulesDecision){els.rulesDecision.classList.toggle('hidden',!declined);els.rulesDecision.innerHTML=declined?'<span class="muted">Você recusou esta versão, mas pode reconsiderar sem esperar novas regras.</span><button class="button success small" type="button" data-reconsider-rules>Reconsiderar regras</button>':'<span class="muted">A aceitação é feita na janela de confirmação.</span>';}if(els.acceptRules)els.acceptRules.disabled=mine?.accepted_rules_version===r.rules_version;}
  function fillRulesForm(x){for(const [k,v] of Object.entries(x)){const el=els.rulesForm.elements[k];if(!el)continue;if(el.type==='checkbox')el.checked=Boolean(v);else el.value=String(v);}}
  function readRulesForm(){const out={};for(const el of els.rulesForm.elements){if(!el.name)continue;out[el.name]=el.type==='checkbox'?el.checked:(el.type==='number'||['turn_seconds','move_seconds','idle_strikes_limit'].includes(el.name)?Number(el.value):el.value);}out.rules_response_seconds=60;out.stake_seconds=60;out.invite_seconds=60;out.reentry_seconds=60;return out;}
  function renderDeadline(){const r=roomData();let label='';if(r.status==='negotiating')label='Aceitação das regras · sem prazo';else if(r.status==='funding')label='Tempo para confirmar a aposta';else if(r.status==='playing')label=r.turn_phase==='move'?'Tempo para escolher a peça':'Tempo da jogada';else if(r.status==='waiting')label='Aguardando completar a sala';else if(r.status==='finished')label='Partida terminada';else label=r.status;els.deadlineLabel.textContent=label;updateClock();}
  function updateClock(){const r=roomData();if(r?.status==='negotiating'){els.deadlineClock.textContent='Sem prazo';els.deadlineBar.style.borderColor='';return;}if(!r?.action_deadline){els.deadlineClock.textContent='—';els.deadlineBar.style.borderColor='';return;}const s=Math.max(0,Math.ceil((new Date(r.action_deadline)-Date.now())/1000));els.deadlineClock.textContent=`${String(Math.floor(s/60)).padStart(2,'0')}:${String(s%60).padStart(2,'0')}`;els.deadlineBar.style.borderColor=s<=10?'#b44b59':'';}
  function renderFunding(){const r=roomData(),mine=myRoomPlayer(),show=r.status==='funding';els.fundingPanel.classList.toggle('hidden',!show);if(!show)return;els.fundingText.textContent=`${roomPlayers().filter(p=>p.stake_paid).length}/${r.player_count} jogadores já confirmaram ${money(r.bet_amount)} MZN. A sua confirmação é feita na janela.`;els.fundButton.classList.add('hidden');els.fundButton.disabled=Boolean(mine?.stake_paid);}
  function renderGame(){const r=roomData(),playing=['playing','finished'].includes(r.status);els.gamePanel.classList.remove('hidden');const current=roomPlayers().find(p=>p.player_id===r.current_player_id);if(!playing){els.turnTitle.textContent=r.status==='waiting'?'Tabuleiro pronto · aguardando jogadores':r.status==='negotiating'?'Tabuleiro pronto · negociação das regras':r.status==='funding'?'Tabuleiro pronto · aguardando apostas':'Tabuleiro pronto';renderDiceFace(null);els.rollDice.disabled=true;els.rollDice.classList.add('hidden');els.moveHint.textContent=r.status==='waiting'?'Convide ou aguarde os outros jogadores.':r.status==='negotiating'?'Todos devem concordar com as mesmas regras antes de jogar.':r.status==='funding'?'Confirme a aposta para iniciar a partida.':'Aguardando preparação da partida.';els.reenterButton.classList.add('hidden');renderPregameBoard();renderChat();renderVoice();return;}els.turnTitle.textContent=r.status==='finished'?'Partida terminada':current?`Vez de ${current.name} · ${current.code}`:'Aguardando…';renderDiceFace(visibleDiceValue(r));const myTurn=r.current_player_id===me();els.rollDice.disabled=!(r.status==='playing'&&myTurn&&r.turn_phase==='roll');els.rollDice.classList.toggle('hidden',r.status!=='playing');const legal=(state.room.legal_moves||[]).map(x=>Number(x.token_no));if(myTurn&&r.turn_phase==='move')els.moveHint.textContent=`Dado ${r.dice_result}: escolha uma peça destacada em até ${rules().move_seconds}s.`;else if(myTurn)els.moveHint.textContent='É a sua vez. Lance o dado.';else els.moveHint.textContent=current?`Aguardando ${current.code}.`:'Aguardando.';const mine=myRoomPlayer();els.reenterButton.classList.toggle('hidden',mine?.status!=='reentry');if(mine?.status==='reentry')els.reenterButton.textContent=`Pagar ${money(rules().reentry_amount)} MZN e continuar`;renderBoard(legal);renderChat();renderVoice();maybeAutoMove();}
  function renderBoard(legal=[]){const cells=[];for(let i=0;i<225;i++){const d=document.createElement('div');d.className='cell';d.dataset.row=String(Math.floor(i/15));d.dataset.col=String(i%15);cells.push(d);}const at=(row,col)=>cells[row*15+col];for(let rr=0;rr<6;rr++)for(let cc=0;cc<6;cc++)at(rr,cc).classList.add('base','red');for(let rr=0;rr<6;rr++)for(let cc=9;cc<15;cc++)at(rr,cc).classList.add('base','green');for(let rr=9;rr<15;rr++)for(let cc=9;cc<15;cc++)at(rr,cc).classList.add('base','yellow');for(let rr=9;rr<15;rr++)for(let cc=0;cc<6;cc++)at(rr,cc).classList.add('base','blue');PATH.forEach(([r,c],i)=>{at(r,c).classList.add('path');if(SAFE.has(i))at(r,c).classList.add('safe');});Object.entries(HOME).forEach(([color,coords])=>coords.forEach(([r,c])=>at(r,c).classList.add(`home-${color}`)));for(let r=6;r<=8;r++)for(let c=6;c<=8;c++)at(r,c).classList.add('center');decorateClassicBoard(cells);const players=roomPlayers(),grouped=new Map();for(const t of state.room.tokens||[]){const p=players.find(x=>x.player_id===t.player_id);if(!p)continue;let coord;if(t.steps===-1)coord=BASE[p.color][t.token_no-1];else if(t.steps<=TRACK_LAST_STEP)coord=PATH[(START[p.color]+t.steps)%52];else if(t.steps<=HOME_LAST_STEP)coord=HOME[p.color][Math.max(0,t.steps-HOME_FIRST_STEP)];else coord=[7,7];const key=coord.join(',');if(!grouped.has(key))grouped.set(key,[]);grouped.get(key).push({t,p,coord});}for(const list of grouped.values()){const [r,c]=list[0].coord,cell=at(r,c);if(list.length>1)cell.classList.add('multi');list.forEach((it,idx)=>{const b=document.createElement('button');b.type='button';b.className=`piece ${it.p.color} ${it.p.player_id===me()?'mine':''} ${it.p.player_id===me()&&legal.includes(Number(it.t.token_no))?'legal':''}`;b.textContent=it.t.token_no;b.title=`${it.p.code} · peão ${it.t.token_no}`;b.dataset.playerId=String(it.p.player_id);b.dataset.tokenNo=String(it.t.token_no);if(list.length>1){const pos=[[-20,-20],[20,-20],[-20,20],[20,20]][idx%4];b.style.setProperty('--dx',`${pos[0]}%`);b.style.setProperty('--dy',`${pos[1]}%`);}if(it.p.player_id===me()&&legal.includes(Number(it.t.token_no)))b.addEventListener('click',()=>moveToken(it.t.token_no));cell.appendChild(b);});}els.ludoBoard.replaceChildren(...cells,classicCenter());}
  function renderChat(){const enabled=Boolean(rules().chat_enabled);els.chatForm.classList.toggle('hidden',!enabled);const msgs=state.room.chat||[];els.chatMessages.innerHTML=msgs.length?msgs.map(m=>`<div class="chat-msg"><strong>${escapeHtml(m.code)}</strong><span>${escapeHtml(m.message)}</span></div>`).join(''):'<div class="empty">Sem mensagens.</div>';els.chatMessages.scrollTop=els.chatMessages.scrollHeight;}
  function renderResult(){const r=roomData();els.resultPanel.classList.toggle('hidden',r.status!=='finished');if(r.status!=='finished')return;checkLudoWinNotice();if(els.rematchBet&&els.rematchBet.dataset.room!==String(r.id)){els.rematchBet.value=String(Math.max(10,Math.trunc(Number(r.bet_amount)||10)));els.rematchBet.dataset.room=String(r.id);}if(els.rematchHelp)els.rematchHelp.textContent=`Mesmos ${r.player_count} jogadores e modo ${r.mode==='partners'?'Parceiros 2 × 2':'Cada um por si'}. Ajuste apenas o valor se quiser.`;const winner=r.mode==='partners'?`Equipa ${r.winner_team}`:(roomPlayers().find(p=>p.player_id===r.winner_player_id)?.code||'Vencedor');els.resultTitle.textContent=`${winner} venceu`;const p=state.room.payouts||[];els.resultPayouts.innerHTML=`<div class="payout-grid">${p.map(x=>{const pl=roomPlayers().find(y=>y.player_id===x.player_id);return `<div class="payout-card"><strong>${escapeHtml(pl?.code||'Jogador')}</strong><br>Bruto ${money(x.gross)} MZN<br>Casa ${money(x.commission)} MZN<br><strong>Líquido ${money(x.net)} MZN</strong></div>`}).join('')}</div>`;}
  async function renderInviter(){const r=roomData(),host=isHost()&&['waiting','negotiating'].includes(r.status);document.querySelector('.invite-panel').classList.toggle('hidden',!host);if(host)await loadWaiting(true);}
  async function loadWaiting(silent=false){if(!state.room||!isHost())return;try{const rows=await rpc('jl_ludo_waiting_players',{p_token:state.token,p_room:roomData().id});els.waitingPlayers.innerHTML=rows.length?rows.map(p=>`<div class="mini-item"><div><strong>${escapeHtml(p.name)}</strong><br><small>${escapeHtml(p.code)}</small></div><button class="button ghost small" data-invite-player="${p.player_id}">Convidar</button></div>`).join(''):'<div class="empty">Nenhum compatível agora.</div>';}catch(e){if(!silent)showToast(e.message,'error');}}
  async function withBusy(fn){if(state.busy)return;state.busy=true;try{await fn();}finally{state.busy=false;}} async function moveToken(n){
    await withBusy(async()=>{
      const move=(state.room?.legal_moves||[]).find(x=>Number(x.token_no)===Number(n));
      const player=myRoomPlayer();
      state.animating=true;
      try{
        const nextRoom=await rpc('jl_ludo_move',{p_token:state.token,p_room:roomData().id,p_token_no:Number(n)});
        const finalToken=(nextRoom?.tokens||[]).find(t=>t.player_id===me()&&Number(t.token_no)===Number(n));
        if(move&&player&&finalToken&&Number(finalToken.steps)===Number(move.to_steps)){
          await animateTokenPath(me(),Number(n),player.color,Number(move.from_steps),Number(move.to_steps));
        }
        processGameEffects(nextRoom);
        state.room=nextRoom;
        renderRoom();
      }catch(e){showToast(e.message,'error');}
      finally{state.animating=false;els.ludoBoard?.classList.remove('piece-moving');}
    });
  }
  function maybeAutoMove(){
    const r=roomData(),moves=state.room?.legal_moves||[];
    const eligible=Boolean(r&&r.status==='playing'&&r.current_player_id===me()&&r.turn_phase==='move'&&moves.length===1);
    if(!eligible){state.autoMoveKey=null;return;}
    const only=moves[0];
    const key=`${r.id}:${r.dice_position}:${r.dice_result}:${only.token_no}`;
    if(state.autoMoveKey===key)return;
    state.autoMoveKey=key;
    if(els.moveHint)els.moveHint.textContent=`Única jogada possível · peão ${only.token_no} vai mover automaticamente.`;
    setTimeout(()=>{
      const rr=roomData(),currentMoves=state.room?.legal_moves||[];
      const still=rr&&rr.status==='playing'&&rr.current_player_id===me()&&rr.turn_phase==='move'&&currentMoves.length===1&&Number(currentMoves[0].token_no)===Number(only.token_no);
      if(!still){state.autoMoveKey=null;return;}
      if(state.busy||state.animating){state.autoMoveKey=null;maybeAutoMove();return;}
      moveToken(Number(only.token_no));
    },280);
  }
  function stopVoiceIfRoomEnded(){if(!state.room||['finished','cancelled'].includes(roomData()?.status))closeVoice();}
  function renderVoice(){const available=Boolean(state.room&&roomData()?.status!=='finished'&&roomData()?.status!=='cancelled');if(!available){closeVoice();els.voiceState.textContent='Indisponível';for(const b of [els.micButton,els.micQuickButton])if(b){b.disabled=true;b.textContent='🎙️ Microfone indisponível';}return;}const on=Boolean(state.localStream);els.voiceState.textContent=!available?'Indisponível':on?'Ligado':'Desligado';const label=!available?'🎙️ Microfone indisponível':on?'🔇 Desligar microfone':'🎙️ Ligar microfone';for(const b of [els.micButton,els.micQuickButton])if(b){b.disabled=!available;b.textContent=label;}if(available)startSignalPolling();else stopSignalPolling();}
  async function toggleMic(){if(!state.room)return;try{if(!state.localStream){state.localStream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true},video:false});state.micMuted=false;for(const p of roomPlayers())if(p.player_id!==me())ensurePeer(p.player_id,true);}else{state.localStream.getTracks().forEach(t=>t.stop());state.localStream=null;state.micMuted=true;}renderVoice();}catch(e){showToast(`Microfone: ${e.message}`,'error');}}
  function startSignalPolling(){if(state.signalTimer||!state.room)return;state.signalTimer=setInterval(pullSignals,1000);pullSignals();} function stopSignalPolling(){clearInterval(state.signalTimer);state.signalTimer=null;}
  async function sendSignal(to,type,payload){try{await rpc('jl_ludo_signal_send',{p_token:state.token,p_room:roomData().id,p_to_player:to,p_signal_type:type,p_payload:payload});}catch(e){console.warn('signal',e.message);}}
  function ensurePeer(peerId,addTracks=false){let wrap=state.peers.get(peerId);if(wrap){if(addTracks&&state.localStream)attachTracks(wrap.pc);return wrap;}const pc=new RTCPeerConnection({iceServers:[{urls:'stun:stun.l.google.com:19302'}]});wrap={pc,makingOffer:false,ignoreOffer:false,polite:String(me())>String(peerId)};state.peers.set(peerId,wrap);pc.onicecandidate=e=>{if(e.candidate)sendSignal(peerId,'ice',e.candidate.toJSON());};pc.ontrack=e=>{let audio=document.getElementById(`audio-${peerId}`);if(!audio){audio=document.createElement('audio');audio.id=`audio-${peerId}`;audio.autoplay=true;audio.playsInline=true;els.remoteAudio.appendChild(audio);}audio.srcObject=e.streams[0];audio.play().catch(()=>{});};pc.onnegotiationneeded=async()=>{try{wrap.makingOffer=true;await pc.setLocalDescription(await pc.createOffer());await sendSignal(peerId,'offer',pc.localDescription);}catch(e){console.warn(e)}finally{wrap.makingOffer=false;}};if(addTracks&&state.localStream)attachTracks(pc);return wrap;}
  function attachTracks(pc){if(!state.localStream)return;for(const track of state.localStream.getTracks()){const sender=pc.getSenders().find(s=>s.track?.kind===track.kind);if(sender){if(sender.track!==track)sender.replaceTrack(track).catch(()=>{});}else pc.addTrack(track,state.localStream);}}
  async function pullSignals(){if(!state.room)return;try{const rows=await rpc('jl_ludo_signal_pull',{p_token:state.token,p_room:roomData().id,p_after_id:state.lastSignalId});for(const s of rows){state.lastSignalId=Math.max(state.lastSignalId,Number(s.id));await handleSignal(s);}}catch(e){console.warn('pull signal',e.message);}}
  async function handleSignal(s){const wrap=ensurePeer(s.from_player_id,Boolean(state.localStream)),pc=wrap.pc;try{if(s.signal_type==='offer'){const desc=new RTCSessionDescription(s.payload),collision=wrap.makingOffer||pc.signalingState!=='stable';wrap.ignoreOffer=!wrap.polite&&collision;if(wrap.ignoreOffer)return;await pc.setRemoteDescription(desc);if(state.localStream)attachTracks(pc);await pc.setLocalDescription(await pc.createAnswer());await sendSignal(s.from_player_id,'answer',pc.localDescription);}else if(s.signal_type==='answer'){await pc.setRemoteDescription(new RTCSessionDescription(s.payload));}else if(s.signal_type==='ice'){try{await pc.addIceCandidate(new RTCIceCandidate(s.payload));}catch(e){if(!wrap.ignoreOffer)throw e;}}}catch(e){console.warn('handle signal',e);}}
  function closeVoice(){stopSignalPolling();for(const w of state.peers.values())w.pc.close();state.peers.clear();if(state.localStream)state.localStream.getTracks().forEach(t=>t.stop());state.localStream=null;state.micMuted=true;state.lastSignalId=0;els.remoteAudio.innerHTML='';}

  els.winModalOk?.addEventListener('click',closeLudoWinNotice);
  els.soundToggle?.addEventListener('click',toggleSound);
  els.micQuickButton?.addEventListener('click',toggleMic);
  updateSoundButton();
    els.accountButton.addEventListener('click',()=>{
    if(!state.token)return openAuth('login');
    els.accountMenu.classList.toggle('hidden');
    els.accountButton.setAttribute('aria-expanded',els.accountMenu.classList.contains('hidden')?'false':'true');
  });
  els.accountMenuDeposit?.addEventListener('click',()=>{window.location.href='./index.html?open=deposit#depositPanel';});
  els.accountMenuWithdraw?.addEventListener('click',()=>{window.location.href='./index.html?open=withdraw#withdrawPanel';});
  els.accountMenuLogout?.addEventListener('click',async()=>{
    try{if(state.token)await rpc('jl_logout_player',{p_token:state.token});}catch{}
    saveToken('');
    closeVoice();
    state.status=null;
    state.room=null;
    els.accountMenu?.classList.add('hidden');
    els.accountButton.setAttribute('aria-expanded','false');
    renderAll();
    showToast('Sessão encerrada.');
  });
  document.addEventListener('click',e=>{
    if(!els.accountMenu||els.accountMenu.classList.contains('hidden'))return;
    if(e.target.closest('#accountButton')||e.target.closest('#accountMenu'))return;
    els.accountMenu.classList.add('hidden');
    els.accountButton.setAttribute('aria-expanded','false');
  });document.querySelectorAll('[data-open-auth]').forEach(b=>b.addEventListener('click',()=>openAuth(b.dataset.openAuth)));els.closeAuth.addEventListener('click',closeAuth);els.loginTab.addEventListener('click',()=>switchAuth('login'));els.registerTab.addEventListener('click',()=>switchAuth('register'));els.authModal.addEventListener('click',e=>{if(e.target===els.authModal)closeAuth();});
  els.loginForm.addEventListener('submit',async e=>{e.preventDefault();try{setAuthMessage('Entrando…');const res=await rpc('jl_login_player',{p_phone:els.loginPhone.value.trim(),p_pin:els.loginPin.value.trim()});saveToken(res.token);closeAuth();await loadStatus();showToast('Sessão iniciada.','success');}catch(err){setAuthMessage(err.message,'error');}});
  els.registerForm.addEventListener('submit',async e=>{e.preventDefault();if(els.registerPin.value!==els.registerPinConfirm.value)return setAuthMessage('Os PINs não coincidem.','error');try{setAuthMessage('Criando conta…');const res=await rpc('jl_register_player',{p_name:els.registerName.value.trim(),p_phone:els.registerPhone.value.trim(),p_pin:els.registerPin.value.trim()});saveToken(res.token);closeAuth();await loadStatus();showToast('Conta criada. O seu código Ludo foi atribuído pela casa.','success');}catch(err){setAuthMessage(err.message,'error');}});
  wirePlayerCountPicker('createPlayers');wirePlayerCountPicker('queuePlayers');
  els.createBet?.addEventListener('change',()=>{const amount=wholeStake(els.createBet.value);if(amount!==null)ensureLudoFunds(amount,'criar uma sala com este valor').catch(err=>showToast(err.message,'error'));});
  els.queueBet?.addEventListener('change',()=>{const amount=wholeStake(els.queueBet.value);if(amount!==null)ensureLudoFunds(amount,'entrar na fila com este valor').catch(err=>showToast(err.message,'error'));});
  els.rematchBet?.addEventListener('change',()=>{const amount=wholeStake(els.rematchBet.value,'A nova aposta');if(amount!==null)ensureLudoFunds(amount,'repetir o jogo com este valor').catch(err=>showToast(err.message,'error'));});
  els.createPlayers.addEventListener('change',()=>{syncPlayerCountPicker('createPlayers');if(els.createMode.value==='partners'&&els.createPlayers.value!=='4')els.createMode.value='solo';});els.createMode.addEventListener('change',()=>{if(els.createMode.value==='partners')setPlayerCount('createPlayers',4);});els.queuePlayers.addEventListener('change',()=>{syncPlayerCountPicker('queuePlayers');if(els.queueMode.value==='partners'&&els.queuePlayers.value!=='4')els.queueMode.value='solo';});els.queueMode.addEventListener('change',()=>{if(els.queueMode.value==='partners')setPlayerCount('queuePlayers',4);});
  els.createRoomForm.addEventListener('submit',e=>{e.preventDefault();const amount=wholeStake(els.createBet.value);if(amount===null)return;withBusy(async()=>{try{if(!(await ensureLudoFunds(amount,'criar esta sala')))return;state.room=await rpc('jl_ludo_create_room',{p_token:state.token,p_player_count:Number(els.createPlayers.value),p_bet_amount:amount,p_mode:els.createMode.value,p_is_public:els.createPublic.checked,p_rules:{}});await loadStatus(true);showToast('Sala criada. Convide os jogadores e negociem as regras.','success');}catch(err){if(!handleLudoMoneyError(err,'criar esta sala'))showToast(err.message,'error');}});});
  els.joinCodeForm.addEventListener('submit',e=>{e.preventDefault();withBusy(async()=>{try{state.room=await rpc('jl_ludo_join_public_room',{p_token:state.token,p_code:els.joinCode.value.trim()});await loadStatus(true);showToast('Entrou na sala.','success');}catch(err){if(!handleLudoMoneyError(err,'entrar nesta sala'))showToast(err.message,'error');}});});
  els.queueForm.addEventListener('submit',e=>{e.preventDefault();withBusy(async()=>{try{if(els.queueButton.dataset.queued)await rpc('jl_ludo_leave_queue',{p_token:state.token});else{const amount=wholeStake(els.queueBet.value);if(amount===null)return;if(!(await ensureLudoFunds(amount,'entrar na fila com este valor')))return;await rpc('jl_ludo_enter_queue',{p_token:state.token,p_bet_amount:amount,p_player_count:Number(els.queuePlayers.value),p_mode:els.queueMode.value});}await loadStatus(true);}catch(err){if(!handleLudoMoneyError(err,'entrar na fila'))showToast(err.message,'error');}});});els.refreshLobby.addEventListener('click',()=>loadStatus());
  els.directNotificationMetric?.addEventListener('click',()=>{els.notificationCenter?.scrollIntoView({behavior:'smooth',block:'start'});setTimeout(()=>els.inviteList?.scrollIntoView({behavior:'smooth',block:'center'}),250);});
  els.publicNotificationMetric?.addEventListener('click',()=>{els.notificationCenter?.scrollIntoView({behavior:'smooth',block:'start'});setTimeout(()=>els.publicChallengeList?.scrollIntoView({behavior:'smooth',block:'center'}),250);});
  els.inviteList.addEventListener('click',e=>{const a=e.target.closest('[data-invite-accept]'),d=e.target.closest('[data-invite-decline]');if(!a&&!d)return;withBusy(async()=>{try{if(a){const amount=Number(a.dataset.betAmount||0);if(amount>0&&!(await ensureLudoFunds(amount,'aceitar este convite')))return;}await rpc('jl_ludo_accept_invite',{p_token:state.token,p_invitation:(a||d).dataset[a?'inviteAccept':'inviteDecline'],p_accept:Boolean(a)});await loadStatus(true);}catch(err){if(!handleLudoMoneyError(err,'aceitar este convite'))showToast(err.message,'error');}});});
  els.publicChallengeList.addEventListener('click',e=>{const b=e.target.closest('[data-public-accept]');if(!b)return;withBusy(async()=>{try{const amount=Number(b.dataset.betAmount||0);if(amount>0&&!(await ensureLudoFunds(amount,'entrar neste desafio')))return;state.room=await rpc('jl_ludo_accept_public_challenge',{p_token:state.token,p_code:b.dataset.publicAccept});await loadStatus(true);showToast('Entrou no desafio público.','success');}catch(err){if(!handleLudoMoneyError(err,'entrar neste desafio'))showToast(err.message,'error');}});});

  els.copyRoomCode.addEventListener('click',()=>navigator.clipboard.writeText(roomData().code).then(()=>showToast('Código copiado.','success')).catch(()=>showToast(roomData().code)));els.leaveRoom.addEventListener('click',()=>withBusy(async()=>{try{await rpc('jl_ludo_cancel_or_leave',{p_token:state.token,p_room:roomData().id});closeVoice();await loadStatus(true);showToast('Saiu da sala.');}catch(err){showToast(err.message,'error');}}));els.forfeitRoom?.addEventListener('click',()=>{if(!confirm('Desistir desta partida? Esta ação é voluntária e não pode ser anulada.'))return;withBusy(async()=>{try{await rpc('jl_ludo_forfeit',{p_token:state.token,p_room:roomData().id});closeVoice();await loadStatus(true);showToast('Você desistiu da partida.');}catch(err){showToast(err.message,'error');}});});
  els.rulesForm.addEventListener('input',()=>{state.rulesFormDirty=true;});
  els.rulesForm.addEventListener('change',()=>{state.rulesFormDirty=true;});
  els.rulesForm.addEventListener('submit',e=>{e.preventDefault();const proposed=readRulesForm();if(wholeStake(proposed.reentry_amount,'O valor de reentrada')===null)return;withBusy(async()=>{try{state.room=await rpc('jl_ludo_update_rules',{p_token:state.token,p_room:roomData().id,p_rules:proposed});state.rulesFormDirty=false;state.rulesFormVersion=roomData()?.rules_version??null;renderRoom();showToast('Nova versão das regras proposta. Todos podem aceitar quando quiserem.','success');}catch(err){showToast(err.message,'error');}});});
  els.rulesModalAccept?.addEventListener('click',()=>withBusy(async()=>{try{state.rulesDeclinedVersion=null;state.room=await rpc('jl_ludo_accept_rules',{p_token:state.token,p_room:roomData().id,p_accept:true});renderRoom();showToast('Regras aceites.','success');}catch(err){showToast(err.message,'error');}}));
  els.rulesModalDecline?.addEventListener('click',()=>withBusy(async()=>{try{const version=roomData()?.rules_version;state.room=await rpc('jl_ludo_accept_rules',{p_token:state.token,p_room:roomData().id,p_accept:false});state.rulesDeclinedVersion=version??null;renderRoom();showToast('Você recusou esta versão. Pode reconsiderar a mesma versão quando quiser.');}catch(err){showToast(err.message,'error');}}));
  els.rulesDecision?.addEventListener('click',e=>{if(!e.target.closest('[data-reconsider-rules]'))return;state.rulesDeclinedVersion=null;syncEntryFlowModals();});
  
  els.searchPlayerForm.addEventListener('submit',e=>{e.preventDefault();withBusy(async()=>{try{const rows=await rpc('jl_ludo_find_players',{p_token:state.token,p_query:els.searchPlayer.value.trim()});els.playerSearchResults.innerHTML=rows.length?rows.map(p=>`<div class="mini-item"><div><strong>${escapeHtml(p.name)}</strong><br><small>${escapeHtml(p.code)}${p.waiting?' · à espera':''}</small></div><button class="button ghost small" data-invite-player="${p.player_id}">Convidar</button></div>`).join(''):'<div class="empty">Nenhum jogador encontrado.</div>';}catch(err){showToast(err.message,'error');}});});document.addEventListener('click',e=>{const b=e.target.closest('[data-invite-player]');if(!b)return;withBusy(async()=>{try{await rpc('jl_ludo_invite',{p_token:state.token,p_room:roomData().id,p_target_player:b.dataset.invitePlayer});showToast('Convite enviado por 60 segundos.','success');}catch(err){showToast(err.message,'error');}});});els.refreshWaiting.addEventListener('click',()=>loadWaiting());
  els.fundButton.addEventListener('click',()=>withBusy(async()=>{try{const amount=Number(roomData()?.bet_amount||0);if(!(await ensureLudoFunds(amount,'confirmar esta aposta')))return;state.room=await rpc('jl_ludo_commit_stake',{p_token:state.token,p_room:roomData().id});await loadStatus(true);showToast('Aposta confirmada.','success');}catch(err){if(!handleLudoMoneyError(err,'confirmar esta aposta'))showToast(err.message,'error');}}));
  els.stakeModalAccept?.addEventListener('click',()=>withBusy(async()=>{try{els.stakeModalAccept.disabled=true;const amount=Number(roomData()?.bet_amount||0);if(!(await ensureLudoFunds(amount,'confirmar este valor')))return;state.room=await rpc('jl_ludo_commit_stake',{p_token:state.token,p_room:roomData().id});await loadStatus(true);showToast('Valor confirmado.','success');}catch(err){if(!handleLudoMoneyError(err,'confirmar este valor'))showToast(err.message,'error');}finally{els.stakeModalAccept.disabled=false;syncEntryFlowModals();}}));els.rollDice.addEventListener('click',()=>withBusy(async()=>{
    if(state.animating)return;
    els.rollDice.disabled=true;
    els.dice.classList.add('rolling');
    playRollSound();
    try{
      const nextRoom=await rpc('jl_ludo_roll',{p_token:state.token,p_room:roomData().id});
      await wait(320);
      processGameEffects(nextRoom);
      state.room=nextRoom;
      renderRoom();
    }catch(err){renderDiceFace(null);showToast(err.message,'error');}
    finally{els.dice.classList.remove('rolling');}
  }));
  els.rematchButton?.addEventListener('click',()=>withBusy(async()=>{try{const amount=wholeStake(els.rematchBet?.value,'A nova aposta');if(amount===null)return;if(!(await ensureLudoFunds(amount,'repetir o jogo com este valor')))return;const oldRoom=roomData()?.id;const nextRoom=await rpc('jl_ludo_rematch',{p_token:state.token,p_room:oldRoom,p_bet_amount:amount});state.lastFxEventId=0;state.autoMoveKey=null;state.room=nextRoom;await loadStatus(true);showToast('Nova partida criada. Os mesmos jogadores receberam convite particular.','success');}catch(err){if(!handleLudoMoneyError(err,'repetir o jogo'))showToast(err.message,'error');}}));
  els.reenterButton.addEventListener('click',()=>withBusy(async()=>{try{const amount=Number(rules().reentry_amount||0);if(!(await ensureLudoFunds(amount,'pagar a reentrada')))return;state.room=await rpc('jl_ludo_reenter',{p_token:state.token,p_room:roomData().id});renderRoom();showToast('Reentrada confirmada.','success');}catch(err){if(!handleLudoMoneyError(err,'pagar a reentrada'))showToast(err.message,'error');}}));
  els.chatForm.addEventListener('submit',e=>{e.preventDefault();const m=els.chatInput.value.trim();if(!m)return;withBusy(async()=>{try{await rpc('jl_ludo_send_chat',{p_token:state.token,p_room:roomData().id,p_message:m});els.chatInput.value='';state.room=await rpc('jl_ludo_room_state',{p_token:state.token,p_room:roomData().id});renderChat();}catch(err){showToast(err.message,'error');}});});els.micButton.addEventListener('click',toggleMic);
  state.pollTimer=setInterval(()=>{if(document.visibilityState==='visible')loadStatus(true);},3500);state.timeoutTimer=setInterval(()=>{if(document.visibilityState==='visible')processTimeouts();},4000);state.clockTimer=setInterval(updateClock,250);window.addEventListener('beforeunload',closeVoice);loadStatus();
})();
