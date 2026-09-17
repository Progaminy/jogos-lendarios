(() => {
  'use strict';
  if (window.__JL_LUDO_STABLE_UI__) return;
  window.__JL_LUDO_STABLE_UI__ = true;

  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

  const PATH = [[6,1],[6,2],[6,3],[6,4],[6,5],[5,6],[4,6],[3,6],[2,6],[1,6],[0,6],[0,7],[0,8],[1,8],[2,8],[3,8],[4,8],[5,8],[6,9],[6,10],[6,11],[6,12],[6,13],[6,14],[7,14],[8,14],[8,13],[8,12],[8,11],[8,10],[8,9],[9,8],[10,8],[11,8],[12,8],[13,8],[14,8],[14,7],[14,6],[13,6],[12,6],[11,6],[10,6],[9,6],[8,5],[8,4],[8,3],[8,2],[8,1],[8,0],[7,0],[6,0]];
  const HOME = {red:[[7,1],[7,2],[7,3],[7,4],[7,5]],green:[[1,7],[2,7],[3,7],[4,7],[5,7]],yellow:[[7,13],[7,12],[7,11],[7,10],[7,9]],blue:[[13,7],[12,7],[11,7],[10,7],[9,7]]};
  const BASE = {red:[[1,1],[1,4],[4,1],[4,4]],green:[[1,10],[1,13],[4,10],[4,13]],yellow:[[10,10],[10,13],[13,10],[13,13]],blue:[[10,1],[10,4],[13,1],[13,4]]};
  const SAFE = new Set([0,8,13,21,26,34,39,47]);

  function injectStyles(){
    if ($('#jlStableLudoStyles')) return;
    const s = document.createElement('style');
    s.id = 'jlStableLudoStyles';
    s.textContent = `
      body.ludo-stable-room .hero{display:none!important}
      body.ludo-stable-room .room{margin-top:10px!important}
      body.ludo-stable-room .room-header{order:0!important}
      body.ludo-stable-room #gamePanel{order:1!important;grid-template-columns:minmax(0,1fr)!important}
      body.ludo-stable-room #playersPanel{order:2!important}
      body.ludo-stable-room #deadlineBar{order:3!important}
      body.ludo-stable-room #fundingPanel{order:4!important}
      body.ludo-stable-room .room-grid{order:5!important}
      body.ludo-stable-room #resultPanel{order:6!important}
      body.ludo-stable-room #gamePanel .side-column{display:none!important}
      body.ludo-stable-room #gamePanel.hidden{display:grid!important}
      body.ludo-stable-room #gamePanel.hidden #dice,
      body.ludo-stable-room #gamePanel.hidden #rollDice,
      body.ludo-stable-room #gamePanel.hidden #reenterButton{display:none!important}
      body.ludo-stable-room #gamePanel .board-panel{padding:14px!important;border-color:rgba(244,189,66,.25)!important}
      body.ludo-stable-room #gamePanel.hidden #moveHint{display:block!important;text-align:center!important;padding:9px 12px!important;border-radius:11px!important;background:rgba(244,189,66,.07)!important;border:1px solid rgba(244,189,66,.18)!important;color:#d8e0eb!important}
      .jl-pregame-piece{position:relative;z-index:4;width:62%;aspect-ratio:1;border-radius:50%;border:3px solid rgba(255,255,255,.94);box-shadow:0 3px 6px rgba(0,0,0,.42),inset 0 2px 3px rgba(255,255,255,.30)}
      .jl-pregame-piece.red{background:#e72735}.jl-pregame-piece.green{background:#139b58}.jl-pregame-piece.yellow{background:#e6b800}.jl-pregame-piece.blue{background:#168fd8}
      .jl-pregame-label{position:absolute;z-index:8;left:50%;top:50%;transform:translate(-50%,-50%);padding:8px 11px;border-radius:999px;background:rgba(8,14,23,.88);border:1px solid rgba(244,189,66,.42);color:#ffda6a;font-size:.72rem;font-weight:900;white-space:nowrap;pointer-events:none}
      .ludo-board{position:relative!important}
      .ludo-board .cell.base-inner{background:#fff!important}
      @media(max-width:700px){body.ludo-stable-room #gamePanel .board-panel{padding:7px!important}.jl-pregame-label{font-size:.64rem;max-width:82%;white-space:normal;text-align:center}}
    `;
    document.head.appendChild(s);
  }

  function roomActive(){
    const room = $('#room');
    return Boolean(room && !room.classList.contains('hidden'));
  }

  function markInner(cells){
    [[1,4,1,4],[1,4,10,13],[10,13,10,13],[10,13,1,4]].forEach(([r1,r2,c1,c2])=>{
      for(let r=r1;r<=r2;r++) for(let c=c1;c<=c2;c++) cells[r*15+c]?.classList.add('base-inner');
    });
  }

  function pregameMessage(){
    const funding = $('#fundingPanel');
    if (funding && !funding.classList.contains('hidden')) return 'Apostas · confirme para começar';
    const deadline = ($('#deadlineLabel')?.textContent || '').toLowerCase();
    const cards = $$('#playersPanel .player-card');
    const filled = cards.filter(c => !/aguardando jogador/i.test(c.textContent || '')).length;
    const total = cards.length;
    if (deadline.includes('regras')) {
      const accepted = cards.filter(c => /✓ regras/i.test(c.textContent || '')).length;
      return `Regras · ${accepted}/${total || '?'} confirmaram`;
    }
    return `Aguardando jogadores · ${filled}/${total || '?'}`;
  }

  function buildPregameBoard(){
    const panel = $('#gamePanel');
    const board = $('#ludoBoard');
    if (!roomActive() || !panel || !board || !panel.classList.contains('hidden')) return;

    const colors = $$('#playersPanel .player-card').map(card => ['red','green','yellow','blue'].find(c => card.classList.contains(c))).filter(Boolean);
    const message = pregameMessage();
    const signature = colors.join('|') + '|' + message;
    if (board.dataset.jlStablePregame === signature && board.querySelectorAll(':scope > .cell').length === 225) {
      const label = $('.jl-pregame-label', board); if(label && label.textContent !== message) label.textContent = message;
      return;
    }
    board.dataset.jlStablePregame = signature;

    const cells = Array.from({length:225},()=>{const d=document.createElement('div');d.className='cell';return d;});
    const at=(r,c)=>cells[r*15+c];
    for(let r=0;r<6;r++)for(let c=0;c<6;c++)at(r,c).classList.add('base','red');
    for(let r=0;r<6;r++)for(let c=9;c<15;c++)at(r,c).classList.add('base','green');
    for(let r=9;r<15;r++)for(let c=9;c<15;c++)at(r,c).classList.add('base','yellow');
    for(let r=9;r<15;r++)for(let c=0;c<6;c++)at(r,c).classList.add('base','blue');
    PATH.forEach(([r,c],i)=>{at(r,c).classList.add('path');if(SAFE.has(i))at(r,c).classList.add('safe');});
    Object.entries(HOME).forEach(([color,coords])=>coords.forEach(([r,c])=>at(r,c).classList.add(`home-${color}`)));
    for(let r=6;r<=8;r++)for(let c=6;c<=8;c++)at(r,c).classList.add('center');
    markInner(cells);

    colors.forEach(color=>BASE[color].forEach(([r,c])=>{const p=document.createElement('span');p.className=`jl-pregame-piece ${color}`;at(r,c).appendChild(p);}));
    board.replaceChildren(...cells);
    const label=document.createElement('div');label.className='jl-pregame-label';label.textContent=message;board.appendChild(label);
  }

  function setText(el, value){
    if (el && el.textContent !== value) el.textContent = value;
  }

  function sync(){
    const active = roomActive();
    document.body.classList.toggle('ludo-stable-room', active);
    if (!active) return;
    const panel = $('#gamePanel');
    if (panel?.classList.contains('hidden')) {
      const message = pregameMessage();
      setText($('#turnTitle'), message);
      setText($('#moveHint'), 'Complete a preparação da sala. O jogo começa automaticamente quando todos estiverem prontos.');
      buildPregameBoard();
    } else {
      $('#ludoBoard')?.removeAttribute('data-jl-stable-pregame');
    }
  }

  function normalizeLegacyInviteToast(){
    const toast = $('#toast');
    if (!toast) return;
    if (/Convite enviado por 60 segundos/i.test(toast.textContent || '')) {
      toast.textContent = 'Convite enviado. Ele continua válido enquanto a sala puder receber o jogador.';
    }
  }

  function start(){
    injectStyles();
    sync();

    const observer = new MutationObserver(sync);
    const room = $('#room');
    const panel = $('#gamePanel');
    const players = $('#playersPanel');
    const deadline = $('#deadlineLabel');
    const funding = $('#fundingPanel');
    if (room) observer.observe(room,{attributes:true,attributeFilter:['class']});
    if (panel) observer.observe(panel,{attributes:true,attributeFilter:['class']});
    if (players) observer.observe(players,{childList:true,subtree:true});
    if (deadline) observer.observe(deadline,{childList:true,characterData:true,subtree:true});
    if (funding) observer.observe(funding,{attributes:true,attributeFilter:['class']});

    const toast = $('#toast');
    if (toast) new MutationObserver(normalizeLegacyInviteToast).observe(toast,{childList:true,characterData:true,subtree:true});

    window.addEventListener('focus',sync);
  }

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
