(() => {
  'use strict';
  if (window.__JL_LUDO_BOARD_FIRST__) return;
  window.__JL_LUDO_BOARD_FIRST__ = true;

  const $ = (s, r = document) => r.querySelector(s);
  const TOKEN_KEY = 'jl_player_token';
  const PATH = [[6,1],[6,2],[6,3],[6,4],[6,5],[5,6],[4,6],[3,6],[2,6],[1,6],[0,6],[0,7],[0,8],[1,8],[2,8],[3,8],[4,8],[5,8],[6,9],[6,10],[6,11],[6,12],[6,13],[6,14],[7,14],[8,14],[8,13],[8,12],[8,11],[8,10],[8,9],[9,8],[10,8],[11,8],[12,8],[13,8],[14,8],[14,7],[14,6],[13,6],[12,6],[11,6],[10,6],[9,6],[8,5],[8,4],[8,3],[8,2],[8,1],[8,0],[7,0],[6,0]];
  const HOME = {red:[[7,1],[7,2],[7,3],[7,4],[7,5]],green:[[1,7],[2,7],[3,7],[4,7],[5,7]],yellow:[[7,13],[7,12],[7,11],[7,10],[7,9]],blue:[[13,7],[12,7],[11,7],[10,7],[9,7]]};
  const BASE = {red:[[1,1],[1,4],[4,1],[4,4]],green:[[1,10],[1,13],[4,10],[4,13]],yellow:[[10,10],[10,13],[13,10],[13,13]],blue:[[10,1],[10,4],[13,1],[13,4]]};
  const SAFE = new Set([0,8,13,21,26,34,39,47]);
  let lastRoom = null;

  function styles(){
    if ($('#ludoBoardFirstStyles')) return;
    const s = document.createElement('style');
    s.id = 'ludoBoardFirstStyles';
    s.textContent = `
      body.lbf-ready:not(.ludo-room-active) .hero{display:none!important}
      body.lbf-ready .shell{margin-top:10px!important}
      #ludoFirstView{margin:0 0 16px}
      .lbf-stage{display:grid;grid-template-columns:minmax(0,1.45fr) minmax(280px,.55fr);gap:18px;padding:18px;border-color:rgba(244,181,31,.25)!important;overflow:hidden}
      .lbf-board-wrap{min-width:0;position:relative}
      .lbf-topline{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px}
      .lbf-title strong{display:block;font-size:1.05rem}.lbf-title span{display:block;color:#91a4bd;font-size:.76rem;margin-top:2px}
      .lbf-live{display:inline-flex;align-items:center;gap:7px;padding:6px 9px;border:1px solid rgba(78,213,138,.25);border-radius:999px;background:rgba(78,213,138,.07);color:#92efbc;font-size:.7rem;font-weight:900;white-space:nowrap}.lbf-live::before{content:'';width:7px;height:7px;border-radius:50%;background:#4ed58a;box-shadow:0 0 0 4px rgba(78,213,138,.09)}
      .lbf-board{position:relative;display:grid;grid-template-columns:repeat(15,1fr);aspect-ratio:1;width:min(100%,720px);margin:auto;border:4px solid #0b111b;border-radius:14px;overflow:hidden;background:#f5f7fa;box-shadow:0 20px 45px rgba(0,0,0,.34)}
      .lbf-cell{position:relative;display:grid;place-items:center;border:1px solid rgba(12,22,34,.14);background:#f9fafb}.lbf-cell.path{background:#fff}.lbf-cell.base.red{background:#e64b55}.lbf-cell.base.green{background:#28b675}.lbf-cell.base.yellow{background:#efc52f}.lbf-cell.base.blue{background:#359fe2}.lbf-cell.inner{background:#fff!important}.lbf-cell.home-red{background:#ee6971}.lbf-cell.home-green{background:#57cf92}.lbf-cell.home-yellow{background:#efd363}.lbf-cell.home-blue{background:#67a5ef}.lbf-cell.safe::after{content:'☆';font-size:clamp(8px,1.5vw,17px);color:#677484;font-weight:900;opacity:.7}.lbf-cell.center{background:conic-gradient(#28b675 0 25%,#efc52f 0 50%,#359fe2 0 75%,#e64b55 0)}
      .lbf-piece{width:62%;aspect-ratio:1;border-radius:50%;border:3px solid rgba(255,255,255,.95);box-shadow:0 3px 7px rgba(0,0,0,.38),inset 0 2px 3px rgba(255,255,255,.35);z-index:3}.lbf-piece.red{background:#e72735}.lbf-piece.green{background:#129e59}.lbf-piece.yellow{background:#e7b900}.lbf-piece.blue{background:#148fd8}
      .lbf-center-mark{position:absolute;z-index:5;left:50%;top:50%;transform:translate(-50%,-50%);width:20%;aspect-ratio:1;display:grid;place-items:center;border-radius:50%;background:#101826;border:2px solid rgba(244,181,31,.7);color:#ffda6a;font-weight:1000;font-size:clamp(.55rem,1.5vw,.9rem);box-shadow:0 6px 18px rgba(0,0,0,.3);pointer-events:none}
      .lbf-panel{display:flex;flex-direction:column;justify-content:center;gap:14px;padding:8px 6px}.lbf-panel .eyebrow{margin:0}.lbf-panel h1{margin:0;font-size:clamp(1.8rem,3.5vw,3rem);line-height:1.02;letter-spacing:-.04em}.lbf-panel p{margin:0;color:#a4b3c7;line-height:1.55}.lbf-actions{display:grid;gap:9px}.lbf-actions .button{min-height:52px;font-size:.95rem}.lbf-chips{display:flex;gap:7px;flex-wrap:wrap}.lbf-chip{padding:6px 8px;border-radius:999px;border:1px solid rgba(255,255,255,.09);background:rgba(255,255,255,.035);font-size:.68rem;color:#c7d3e2;font-weight:850}.lbf-tip{padding:10px 11px;border:1px solid rgba(244,181,31,.18);border-radius:12px;background:rgba(244,181,31,.055);color:#d8e0eb!important;font-size:.76rem}
      body.ludo-room-active #gamePanel{order:0!important}
      body.ludo-room-active .room-header{order:1!important}
      body.ludo-room-active #playersPanel{order:2!important}
      body.ludo-room-active #deadlineBar{order:3!important}
      body.ludo-room-active #fundingPanel{order:4!important}
      body.ludo-room-active .room-grid{order:5!important}
      body.ludo-room-active #resultPanel{order:6!important}
      body.ludo-room-active #gamePanel .board-panel{padding-top:12px!important}
      @media(max-width:860px){.lbf-stage{grid-template-columns:1fr}.lbf-panel{padding:2px}.lbf-panel h1{font-size:1.65rem}.lbf-board{width:min(100%,640px)}}
      @media(max-width:600px){#ludoFirstView{margin-top:0}.lbf-stage{padding:8px;gap:10px;border-radius:14px!important}.lbf-topline{padding:3px 3px 0}.lbf-board{border-width:3px;border-radius:10px}.lbf-panel{padding:4px 3px 6px}.lbf-panel h1{font-size:1.35rem}.lbf-panel p{font-size:.82rem}.lbf-chips{gap:5px}.lbf-chip{font-size:.62rem;padding:5px 7px}.lbf-actions{grid-template-columns:1fr 1fr}.lbf-actions .button:first-child{grid-column:1/-1}.lbf-actions .button{min-height:46px;padding:9px}.lbf-tip{display:none}}
    `;
    document.head.appendChild(s);
  }

  function paintBoard(board){
    if (!board || board.children.length) return;
    const cells = Array.from({length:225},()=>{const d=document.createElement('div');d.className='lbf-cell';return d});
    const at=(r,c)=>cells[r*15+c];
    for(let r=0;r<6;r++)for(let c=0;c<6;c++)at(r,c).classList.add('base','red');
    for(let r=0;r<6;r++)for(let c=9;c<15;c++)at(r,c).classList.add('base','green');
    for(let r=9;r<15;r++)for(let c=9;c<15;c++)at(r,c).classList.add('base','yellow');
    for(let r=9;r<15;r++)for(let c=0;c<6;c++)at(r,c).classList.add('base','blue');
    [[1,4,1,4],[1,4,10,13],[10,13,10,13],[10,13,1,4]].forEach(([r1,r2,c1,c2])=>{for(let r=r1;r<=r2;r++)for(let c=c1;c<=c2;c++)at(r,c).classList.add('inner')});
    PATH.forEach(([r,c],i)=>{at(r,c).classList.add('path');if(SAFE.has(i))at(r,c).classList.add('safe')});
    Object.entries(HOME).forEach(([color,coords])=>coords.forEach(([r,c])=>at(r,c).classList.add(`home-${color}`)));
    for(let r=6;r<=8;r++)for(let c=6;c<=8;c++)at(r,c).classList.add('center');
    Object.entries(BASE).forEach(([color,coords])=>coords.forEach(([r,c])=>{const p=document.createElement('span');p.className=`lbf-piece ${color}`;at(r,c).appendChild(p)}));
    board.replaceChildren(...cells);
    const mark=document.createElement('div');mark.className='lbf-center-mark';mark.textContent='LUDO';board.appendChild(mark);
  }

  function ensureFirstView(){
    const shell=$('.shell');
    if(!shell||$('#ludoFirstView'))return;
    const section=document.createElement('section');
    section.id='ludoFirstView';
    section.innerHTML=`<div class="panel lbf-stage"><div class="lbf-board-wrap"><div class="lbf-topline"><div class="lbf-title"><strong>Tabuleiro Ludo Lendário</strong><span>O jogo começa aqui</span></div><span class="lbf-live">PRONTO</span></div><div id="lbfBoard" class="lbf-board" aria-label="Tabuleiro Ludo pronto para jogar"></div></div><div class="lbf-panel"><p class="eyebrow">LUDO LENDÁRIO</p><h1>Tabuleiro pronto. Entre e jogue.</h1><p>Não precisa procurar a sala no meio da página. Comece daqui e, quando a partida abrir, este espaço dá lugar ao tabuleiro real.</p><div class="lbf-chips"><span class="lbf-chip">2–4 jogadores</span><span class="lbf-chip">mín. 10 MZN</span><span class="lbf-chip">1–4 dados</span><span class="lbf-chip">convites sem prazo</span></div><div id="lbfActions" class="lbf-actions"></div><p class="lbf-tip">Ao criar uma sala ou aceitar um convite, você entra diretamente no tabuleiro e continua vendo-o enquanto espera os outros jogadores.</p></div></div>`;
    shell.prepend(section);
    paintBoard($('#lbfBoard'));
  }

  function renderActions(){
    const root=$('#lbfActions');if(!root)return;
    const token=localStorage.getItem(TOKEN_KEY);
    if(!token){root.innerHTML='<button class="button primary" data-lbf="login">Entrar e jogar</button><button class="button secondary" data-lbf="register">Criar conta</button><button class="button ghost" data-lbf="code">Tenho código</button>';return}
    root.innerHTML='<button class="button primary" data-lbf="quick">🎲 Quero jogar agora</button><button class="button secondary" data-lbf="create">Criar minha sala</button><button class="button ghost" data-lbf="code">Entrar por código</button>';
  }

  function roomActive(){return document.body.classList.contains('ludo-room-active') || Boolean($('#room:not(.hidden)'))}
  function sync(){
    ensureFirstView();renderActions();
    const active=roomActive();
    $('#ludoFirstView')?.classList.toggle('hidden',active);
    document.body.classList.add('lbf-ready');
    if(active){
      const room=$('#room');const game=$('#gamePanel');
      if(room&&game&&room.firstElementChild!==game) room.prepend(game);
      const code=$('#roomCode')?.textContent?.trim();
      if(code&&code!=='—'&&code!==lastRoom){lastRoom=code;setTimeout(()=>game?.scrollIntoView({behavior:'smooth',block:'start'}),80)}
    }else lastRoom=null;
  }

  function click(action){
    if(action==='login'||action==='register'){$(`[data-open-auth="${action}"]`)?.click()||$('#accountButton')?.click();return}
    if(action==='quick'){const b=$('#queueButton');if(b){b.scrollIntoView({behavior:'smooth',block:'center'});setTimeout(()=>b.click(),280)}return}
    if(action==='create'){const f=$('#createRoomForm');f?.scrollIntoView({behavior:'smooth',block:'center'});setTimeout(()=>$('#createBet')?.focus({preventScroll:true}),350);return}
    if(action==='code'){const f=$('#joinCodeForm');f?.scrollIntoView({behavior:'smooth',block:'center'});setTimeout(()=>$('#joinCode')?.focus({preventScroll:true}),350)}
  }

  function start(){styles();ensureFirstView();sync();document.addEventListener('click',e=>{const b=e.target.closest('[data-lbf]');if(b){e.preventDefault();click(b.dataset.lbf)}});setInterval(sync,700);window.addEventListener('focus',sync)}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
