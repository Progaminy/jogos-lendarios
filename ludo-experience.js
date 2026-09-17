(() => {
  'use strict';

  const cfg = window.JL_CONFIG || {};
  const TOKEN_KEY = 'jl_player_token';
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  const PATH = [[6,1],[6,2],[6,3],[6,4],[6,5],[5,6],[4,6],[3,6],[2,6],[1,6],[0,6],[0,7],[0,8],[1,8],[2,8],[3,8],[4,8],[5,8],[6,9],[6,10],[6,11],[6,12],[6,13],[6,14],[7,14],[8,14],[8,13],[8,12],[8,11],[8,10],[8,9],[9,8],[10,8],[11,8],[12,8],[13,8],[14,8],[14,7],[14,6],[13,6],[12,6],[11,6],[10,6],[9,6],[8,5],[8,4],[8,3],[8,2],[8,1],[8,0],[7,0],[6,0]];
  const START = { red:0, green:13, yellow:26, blue:39 };
  const HOME = {
    red:[[7,1],[7,2],[7,3],[7,4],[7,5]],
    green:[[1,7],[2,7],[3,7],[4,7],[5,7]],
    yellow:[[7,13],[7,12],[7,11],[7,10],[7,9]],
    blue:[[13,7],[12,7],[11,7],[10,7],[9,7]]
  };
  const BASE = {
    red:[[1,1],[1,4],[4,1],[4,4]],
    green:[[1,10],[1,13],[4,10],[4,13]],
    yellow:[[10,10],[10,13],[13,10],[13,13]],
    blue:[[10,1],[10,4],[13,1],[13,4]]
  };
  const SAFE = new Set([0,8,13,21,26,34,39,47]);

  let state = null;
  let lastRoomId = null;
  let lastPlayerCount = -1;
  let pollTimer = null;

  function injectStyles() {
    if ($('#jlLudoExperienceStyles')) return;
    const style = document.createElement('style');
    style.id = 'jlLudoExperienceStyles';
    style.textContent = `
      body.ludo-room-active .hero{display:none!important}
      body.ludo-room-active .room{margin-top:12px!important}
      body.ludo-room-active #gamePanel.hidden{display:grid!important}
      body.ludo-room-active #gamePanel{order:2!important;grid-template-columns:minmax(0,1fr)!important}
      body.ludo-room-active #gamePanel .side-column{display:none!important}
      body.ludo-room-active #gamePanel .board-panel{padding:18px!important;border-color:rgba(244,181,31,.28)!important;box-shadow:0 18px 50px rgba(0,0,0,.30)!important}
      body.ludo-room-active .room-header{order:1!important}
      body.ludo-room-active #playersPanel{order:3!important}
      body.ludo-room-active #deadlineBar{order:4!important}
      body.ludo-room-active #fundingPanel{order:5!important}
      body.ludo-room-active .room-grid{order:6!important}
      body.ludo-room-active #resultPanel{order:7!important}
      body.ludo-room-active #gamePanel.hidden #rollDice,
      body.ludo-room-active #gamePanel.hidden #reenterButton,
      body.ludo-room-active #gamePanel.hidden #dice{display:none!important}
      body.ludo-room-active #gamePanel.hidden #turnTitle{font-size:0!important}
      body.ludo-room-active #gamePanel.hidden #turnTitle::after{content:'Tabuleiro pronto · aguardando jogadores';font-size:1.22rem;font-weight:900;color:#f7f8fb}
      body.ludo-room-active #gamePanel.hidden #moveHint{display:block!important;text-align:center!important;padding:9px 12px!important;border-radius:12px!important;background:rgba(244,181,31,.07)!important;border:1px solid rgba(244,181,31,.18)!important;color:#d7dfeb!important}
      .ludo-quickbar{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin:0 0 14px;padding:10px 12px;border:1px solid rgba(244,181,31,.20);border-radius:13px;background:linear-gradient(135deg,rgba(244,181,31,.10),rgba(255,255,255,.025))}
      .ludo-quickbar .room-state{display:flex;align-items:center;gap:9px;min-width:0}.ludo-quickbar .room-state strong{white-space:nowrap}.ludo-quickbar .room-state span{color:#9fb0c6;font-size:.78rem}.ludo-quickbar .pulse-dot{width:9px;height:9px;border-radius:50%;background:#f4b51f;box-shadow:0 0 0 5px rgba(244,181,31,.10);animation:jlPulse 1.4s infinite}.ludo-quick-actions{display:flex;gap:7px;flex-wrap:wrap}.ludo-quick-actions button{border:1px solid rgba(255,255,255,.12);border-radius:9px;background:#182337;color:#f7f8fb;padding:8px 10px;font-weight:800;cursor:pointer}.ludo-quick-actions button.primary{background:#f4b51f;color:#191208;border-color:#f4b51f}
      @keyframes jlPulse{50%{opacity:.45;transform:scale(.82)}}
      .ludo-room-jump{display:inline-flex!important;align-items:center;gap:7px;padding:8px 11px!important;border-radius:8px!important;background:#f4b51f!important;color:#171109!important;border:1px solid #f4b51f!important;font-size:.77rem!important;font-weight:900!important;cursor:pointer!important}
      .ludo-board{position:relative!important;background:#e9edf1!important;border:5px solid #111820!important;border-radius:12px!important;box-shadow:0 10px 30px rgba(0,0,0,.24),inset 0 0 0 1px rgba(0,0,0,.12)!important}
      .ludo-board .cell{background:#f9fafb;border-color:rgba(25,33,43,.16)!important}
      .ludo-board .cell.base.red{background:#e84b56!important}.ludo-board .cell.base.green{background:#2db876!important}.ludo-board .cell.base.yellow{background:#f0c52d!important}.ludo-board .cell.base.blue{background:#35a6e8!important}
      .ludo-board .cell.base-inner{background:#fff!important}
      .ludo-board .cell.path{background:#fff!important}
      .ludo-board .cell.home-red{background:#e84b56!important}.ludo-board .cell.home-green{background:#2db876!important}.ludo-board .cell.home-yellow{background:#f0c52d!important}.ludo-board .cell.home-blue{background:#35a6e8!important}
      .ludo-board .cell.start-red{background:#e84b56!important}.ludo-board .cell.start-green{background:#2db876!important}.ludo-board .cell.start-yellow{background:#f0c52d!important}.ludo-board .cell.start-blue{background:#35a6e8!important}
      .ludo-board .cell.safe::after{content:'☆'!important;font-size:clamp(10px,1.7vw,20px)!important;color:#6f7782!important;opacity:.72!important;font-weight:900!important}
      .ludo-board::after{content:'';position:absolute;z-index:2;left:40%;top:40%;width:20%;height:20%;background:conic-gradient(#2db876 0 25%,#f0c52d 0 50%,#35a6e8 0 75%,#e84b56 0);clip-path:polygon(0 0,100% 0,100% 100%,0 100%);pointer-events:none;box-shadow:0 0 0 1px rgba(0,0,0,.12)}
      .ludo-board .piece{z-index:5!important;width:64%!important;max-width:32px!important;aspect-ratio:1!important;border:3px solid #f7fbff!important;border-radius:50% 50% 45% 45%!important;box-shadow:0 3px 6px rgba(0,0,0,.42),inset 0 2px 3px rgba(255,255,255,.35)!important;font-size:clamp(7px,1vw,10px)!important}
      .ludo-board .piece.placeholder{pointer-events:none!important}.ludo-board .piece.placeholder::after{content:'';position:absolute;left:50%;bottom:-16%;width:52%;height:32%;transform:translateX(-50%);border-radius:0 0 55% 55%;background:inherit;z-index:-1}
      .ludo-board .piece.red{background:#e82735!important}.ludo-board .piece.green{background:#139b58!important}.ludo-board .piece.yellow{background:#f3c400!important;color:#282000!important}.ludo-board .piece.blue{background:#168fd8!important}
      .ludo-board .piece.legal{outline:4px solid #f4b51f!important;outline-offset:2px!important;animation:jlLegal .8s infinite alternate!important}
      @keyframes jlLegal{to{transform:scale(1.10)}}
      .ludo-wait-label{position:absolute;z-index:10;left:50%;top:50%;transform:translate(-50%,-50%);padding:9px 12px;border-radius:999px;background:rgba(9,13,21,.88);border:1px solid rgba(244,181,31,.45);color:#ffda6a;font-size:.72rem;font-weight:900;letter-spacing:.04em;pointer-events:none;box-shadow:0 8px 22px rgba(0,0,0,.28)}
      .game-nav a[data-my-room='1']{position:relative}.game-nav a[data-my-room='1']::after{content:'•';position:absolute;right:8px;top:6px;color:#4ed58a;font-size:1rem;text-shadow:0 0 8px rgba(78,213,138,.8)}
      @media(max-width:760px){body.ludo-room-active #gamePanel .board-panel{padding:8px!important}.ludo-quickbar{align-items:flex-start}.ludo-quick-actions{width:100%}.ludo-quick-actions button{flex:1}.ludo-room-jump{padding:7px 8px!important}.ludo-board{border-width:3px!important}}
    `;
    document.head.appendChild(style);
  }

  async function rpc(name, args = {}) {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token || !cfg.supabaseUrl || !cfg.supabaseKey) return null;
    const res = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: { apikey: cfg.supabaseKey, Authorization: `Bearer ${cfg.supabaseKey}`, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(args)
    });
    if (!res.ok) return null;
    try { return await res.json(); } catch (_) { return null; }
  }

  function markBaseInner(cells) {
    const areas = [
      [1,4,1,4],[1,4,10,13],[10,13,10,13],[10,13,1,4]
    ];
    for (const [r1,r2,c1,c2] of areas) {
      for (let r=r1;r<=r2;r++) for (let c=c1;c<=c2;c++) cells[r*15+c]?.classList.add('base-inner');
    }
  }

  function decorateBoardCells(cells) {
    const at = (r,c) => cells[r*15+c];
    if (cells.length !== 225) return;
    markBaseInner(cells);
    Object.entries(START).forEach(([color, idx]) => {
      const [r,c] = PATH[idx];
      at(r,c)?.classList.add(`start-${color}`);
    });
  }

  function buildPregameBoard() {
    const board = $('#ludoBoard');
    if (!board || !state?.room || ['playing','finished'].includes(state.room.status)) return;
    const sig = `${state.room.id}|${(state.players||[]).map(p=>`${p.player_id}:${p.color}:${p.status}`).join(',')}`;
    if (board.dataset.pregameSignature === sig && board.children.length === 225) return;
    board.dataset.pregameSignature = sig;

    const cells = [];
    for (let i=0;i<225;i++) { const d=document.createElement('div'); d.className='cell'; cells.push(d); }
    const at = (r,c) => cells[r*15+c];
    for(let r=0;r<6;r++)for(let c=0;c<6;c++)at(r,c).classList.add('base','red');
    for(let r=0;r<6;r++)for(let c=9;c<15;c++)at(r,c).classList.add('base','green');
    for(let r=9;r<15;r++)for(let c=9;c<15;c++)at(r,c).classList.add('base','yellow');
    for(let r=9;r<15;r++)for(let c=0;c<6;c++)at(r,c).classList.add('base','blue');
    PATH.forEach(([r,c],i)=>{at(r,c).classList.add('path');if(SAFE.has(i))at(r,c).classList.add('safe');});
    Object.entries(HOME).forEach(([color,coords])=>coords.forEach(([r,c])=>at(r,c).classList.add(`home-${color}`)));
    for(let r=6;r<=8;r++)for(let c=6;c<=8;c++)at(r,c).classList.add('center');
    decorateBoardCells(cells);

    for (const p of state.players || []) {
      if (!BASE[p.color] || p.status === 'left') continue;
      BASE[p.color].forEach(([r,c], index) => {
        const b = document.createElement('span');
        b.className = `piece placeholder ${p.color}`;
        b.textContent = index + 1;
        b.title = `${p.code || p.name || 'Jogador'} · peça ${index+1}`;
        at(r,c).appendChild(b);
      });
    }
    board.replaceChildren(...cells);
    const label = document.createElement('div');
    label.className = 'ludo-wait-label';
    const joined = (state.players || []).filter(p=>p.status!=='left').length;
    label.textContent = joined < Number(state.room.player_count || 0) ? `Aguardando jogadores · ${joined}/${state.room.player_count}` : 'Jogadores completos · acertem as regras';
    board.appendChild(label);
  }

  function enhanceLiveBoard() {
    const board = $('#ludoBoard');
    if (!board || !state?.room || !['playing','finished'].includes(state.room.status)) return;
    const cells = $$('.cell', board);
    if (cells.length !== 225) return;
    decorateBoardCells(cells);
    board.querySelector('.ludo-wait-label')?.remove();
  }

  function ensureQuickBar() {
    const panel = $('#gamePanel .board-panel');
    if (!panel || $('#ludoQuickBar', panel)) return;
    const bar = document.createElement('div');
    bar.id = 'ludoQuickBar';
    bar.className = 'ludo-quickbar';
    bar.innerHTML = `<div class="room-state"><span class="pulse-dot"></span><div><strong id="ludoQuickTitle">Minha sala</strong><br><span id="ludoQuickText">Tabuleiro pronto</span></div></div><div class="ludo-quick-actions"><button type="button" id="ludoQuickInvite" class="primary">+ Convidar</button><button type="button" id="ludoQuickRules">Regras</button><button type="button" id="ludoQuickCopy">Copiar sala</button></div>`;
    panel.prepend(bar);
    $('#ludoQuickInvite', bar).addEventListener('click',()=>$('.invite-panel')?.scrollIntoView({behavior:'smooth',block:'center'}));
    $('#ludoQuickRules', bar).addEventListener('click',()=>$('.rules-panel')?.scrollIntoView({behavior:'smooth',block:'center'}));
    $('#ludoQuickCopy', bar).addEventListener('click', async ()=>{
      const code = state?.room?.code || $('#roomCode')?.textContent?.trim();
      if (!code) return;
      try { await navigator.clipboard.writeText(code); $('#ludoQuickText').textContent='Código da sala copiado'; } catch (_) {}
    });
  }

  function updateQuickBar() {
    if (!state?.room) return;
    ensureQuickBar();
    const title = $('#ludoQuickTitle');
    const text = $('#ludoQuickText');
    const joined = (state.players||[]).filter(p=>p.status!=='left').length;
    const total = Number(state.room.player_count||0);
    if (title) title.textContent = `${state.room.code || 'Minha sala'} · ${joined}/${total}`;
    if (text) {
      const status = state.room.status;
      text.textContent = status === 'waiting' ? 'Aguardando quem aceitar o convite' : status === 'negotiating' ? 'Jogadores na sala · acertem as regras' : status === 'funding' ? 'Regras aceites · confirmem a aposta' : status === 'playing' ? 'Partida em andamento' : status === 'finished' ? 'Partida terminada' : 'Sala ativa';
    }
  }

  function ensureRoomJump() {
    const nav = $('.game-nav a[href*="ludo"]');
    if (nav) {
      nav.dataset.myRoom = state?.room ? '1' : '0';
      if (state?.room) nav.childNodes.forEach(n=>{ if(n.nodeType===Node.TEXT_NODE) n.textContent=' MINHA SALA '; });
    }
    const actions = $('.top-actions');
    if (!actions) return;
    let btn = $('#ludoRoomJump');
    if (!state?.room) { btn?.remove(); return; }
    if (!btn) {
      btn = document.createElement('button');
      btn.id = 'ludoRoomJump';
      btn.type = 'button';
      btn.className = 'ludo-room-jump';
      btn.textContent = '🎲 Entrar na sala';
      btn.addEventListener('click',()=>{
        if ($('#room')) $('#gamePanel')?.scrollIntoView({behavior:'smooth',block:'start'});
        else location.href = './ludo.html#room';
      });
      actions.prepend(btn);
    }
    btn.textContent = location.pathname.endsWith('/ludo.html') || location.pathname.endsWith('ludo.html') ? '🎲 Minha sala' : '🎲 Entrar na sala';
  }

  function reorderRoom() {
    const room = $('#room');
    const game = $('#gamePanel');
    const header = $('.room-header', room || document);
    if (!room || !game || !header) return;
    if (header.nextElementSibling !== game) header.after(game);
  }

  function renderExperience(autoScroll = false) {
    const hasRoom = Boolean(state?.room);
    document.body.classList.toggle('ludo-room-active', hasRoom && Boolean($('#ludoBoard')));
    ensureRoomJump();
    if (!hasRoom || !$('#ludoBoard')) return;
    reorderRoom();
    updateQuickBar();
    if (['playing','finished'].includes(state.room.status)) enhanceLiveBoard(); else buildPregameBoard();
    if (autoScroll) setTimeout(()=>$('#gamePanel')?.scrollIntoView({behavior:'smooth',block:'start'}),120);
  }

  async function refresh() {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token) { state=null; renderExperience(); return; }
    const status = await rpc('jl_ludo_my_status', {p_token:token});
    if (!status?.active_room_id) { state=null; renderExperience(); return; }
    const room = await rpc('jl_ludo_room_state', {p_token:token,p_room:status.active_room_id});
    if (!room?.room) return;
    state = room;
    const roomChanged = room.room.id !== lastRoomId;
    const playersChanged = (room.players||[]).length !== lastPlayerCount;
    lastRoomId = room.room.id;
    lastPlayerCount = (room.players||[]).length;
    renderExperience(roomChanged || playersChanged);
  }

  function watchDom() {
    const board = $('#ludoBoard');
    if (board) new MutationObserver(()=>setTimeout(enhanceLiveBoard,0)).observe(board,{childList:true,subtree:true});
    document.addEventListener('click', e=>{
      if (e.target.closest('[data-invite-player]')) {
        setTimeout(()=>{
          const t=$('#ludoQuickText'); if(t)t.textContent='Convite enviado · fique na sala aguardando a resposta';
          $('#gamePanel')?.scrollIntoView({behavior:'smooth',block:'start'});
        },350);
      }
    });
  }

  function start() {
    injectStyles();
    watchDom();
    refresh();
    pollTimer = setInterval(refresh, 1800);
    window.addEventListener('focus', refresh);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once:true});
  else start();
})();
