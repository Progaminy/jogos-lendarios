const N = 8;
const EMPTY = 0, M0 = 1, K0 = 2, M1 = -1, K1 = -2;
const MATE = 1_000_000;
const SEARCH_MS = 700;
const MAX_DEPTH = 8;
const QMAX = 4;
const TIMEOUT = Symbol('timeout');
const DIRS = [[-1,-1],[-1,1],[1,-1],[1,1]];
const DARK = [];
for (let r=0;r<N;r++) for (let c=0;c<N;c++) if ((r+c)&1) DARK.push(r*8+c);

const ix=(r,c)=>r*8+c, row=s=>Math.floor(s/8), col=s=>s%8;
const inside=(r,c)=>r>=0&&r<8&&c>=0&&c<8;
const side=p=>p>0?0:1, foe=s=>s?0:1, king=p=>Math.abs(p)===2;
const man=s=>s?M1:M0, queen=s=>s?K1:K0, promo=dr=>dr>0?7:0;
const bit=s=>1n<<BigInt(s), was=(m,s)=>(m&bit(s))!==0n;
const clone=b=>new Int8Array(b);

function captureRoutes(board, from, piece){
  const out=[], owner=side(piece), start=from;
  function walk(at, mask, path, caps){
    let more=false; const r=row(at), c=col(at);
    if(!king(piece)){
      for(const [dr,dc] of DIRS){
        const er=r+dr, ec=c+dc, lr=r+2*dr, lc=c+2*dc;
        if(!inside(er,ec)||!inside(lr,lc)) continue;
        const e=ix(er,ec), land=ix(lr,lc), occ=board[e];
        if(!occ || side(occ)===owner || was(mask,e) || board[land]) continue;
        more=true; board[at]=EMPTY; board[land]=piece;
        walk(land, mask|bit(e), [...path,land], [...caps,e]);
        board[land]=EMPTY; board[at]=piece;
      }
    } else {
      for(const [dr,dc] of DIRS){
        let rr=r+dr, cc=c+dc, enemy=-1;
        while(inside(rr,cc)){
          const q=ix(rr,cc), occ=board[q];
          if(occ){
            if(enemy>=0 || side(occ)===owner || was(mask,q)) break;
            enemy=q; rr+=dr; cc+=dc; continue;
          }
          if(enemy>=0){
            more=true; board[at]=EMPTY; board[q]=piece;
            walk(q, mask|bit(enemy), [...path,q], [...caps,enemy]);
            board[q]=EMPTY; board[at]=piece;
          }
          rr+=dr; cc+=dc;
        }
      }
    }
    if(!more && caps.length) out.push({from:start,to:path.at(-1),path:[...path],captures:[...caps],captureCount:caps.length,piece});
  }
  walk(from,0n,[from],[]); return out;
}

function legal(board, turn, forward){
  let caps=[], max=0;
  for(const q of DARK){
    const p=board[q]; if(!p || side(p)!==turn) continue;
    for(const m of captureRoutes(board,q,p)){
      m.promotes=!king(p) && row(m.to)===promo(forward[turn]);
      if(m.captureCount>max){max=m.captureCount;caps=[m];}
      else if(m.captureCount===max && max) caps.push(m);
    }
  }
  if(max) return caps;
  const out=[];
  for(const q of DARK){
    const p=board[q]; if(!p || side(p)!==turn) continue;
    const r=row(q), c=col(q);
    if(king(p)){
      for(const [dr,dc] of DIRS){
        let rr=r+dr, cc=c+dc;
        while(inside(rr,cc)){
          const to=ix(rr,cc); if(board[to]) break;
          out.push({from:q,to,path:[q,to],captures:[],captureCount:0,piece:p,promotes:false});
          rr+=dr; cc+=dc;
        }
      }
    } else {
      const dr=forward[turn];
      for(const dc of [-1,1]){
        const rr=r+dr, cc=c+dc; if(!inside(rr,cc)) continue;
        const to=ix(rr,cc); if(board[to]) continue;
        out.push({from:q,to,path:[q,to],captures:[],captureCount:0,piece:p,promotes:rr===promo(dr)});
      }
    }
  }
  return out;
}

function play(board,m,forward){
  const b=clone(board), p=b[m.from], s=side(p); b[m.from]=EMPTY;
  for(const q of m.captures||[]) b[q]=EMPTY;
  b[m.to]=!king(p)&&row(m.to)===promo(forward[s])?queen(s):p; return b;
}

function rootPlay(board,m,idSq,forward){
  const b=clone(board), from=ix(+m.from_row,+m.from_col), to=ix(+m.to_row,+m.to_col), p=b[from];
  if(!p) throw new Error('ROOT_PIECE_NOT_FOUND'); const s=side(p); b[from]=EMPTY;
  for(const id of m.captures||[]){const q=idSq.get(String(id));if(q!=null)b[q]=EMPTY;}
  b[to]=!king(p)&&row(to)===promo(forward[s])?queen(s):p; return b;
}

function staticEval(board,forward){
  let score=0, mine=0, theirs=0;
  for(const q of DARK){
    const p=board[q]; if(!p) continue;
    const s=side(p), sign=s===0?1:-1, r=row(q), c=col(q), center=r>=2&&r<=5&&c>=2&&c<=5;
    if(s===0) mine++; else theirs++;
    if(king(p)) score += sign*(350 + (center?18:0) - ((c===0||c===7)?4:0));
    else {
      const adv=forward[s]>0?r:7-r, dist=Math.abs(promo(forward[s])-r);
      score += sign*(100 + adv*7 + (center?10:0) + (dist===1?22:dist===2?8:0));
    }
  }
  if(!mine) return -MATE; if(!theirs) return MATE; return score;
}

function orderMoves(ms){
  return [...ms].sort((a,b)=>{
    const sa=(a.captureCount||0)*10000+(a.promotes?2500:0)+(king(a.piece)?80:0);
    const sb=(b.captureCount||0)*10000+(b.promotes?2500:0)+(king(b.piece)?80:0);
    return sb-sa;
  });
}

function tick(ctx){ ctx.nodes++; if((ctx.nodes & 31)===0 && performance.now()>=ctx.deadline) throw TIMEOUT; }

function search(board,turn,depth,alpha,beta,qdepth,ctx){
  tick(ctx);
  const ms=legal(board,turn,ctx.forward);
  if(!ms.length) return turn===0 ? -MATE+ctx.ply : MATE-ctx.ply;
  const capture=(ms[0].captureCount||0)>0;
  if(depth<=0 && (!capture || qdepth>=QMAX)) return staticEval(board,ctx.forward);
  const nd=depth>0?depth-1:0, nq=depth>0?qdepth:qdepth+1;
  ctx.ply++;
  try {
    if(turn===0){
      let best=-Infinity;
      for(const m of orderMoves(ms)){
        const v=search(play(board,m,ctx.forward),1,nd,alpha,beta,nq,ctx);
        if(v>best) best=v; if(v>alpha) alpha=v; if(alpha>=beta) break;
      }
      return best;
    }
    let best=Infinity;
    for(const m of orderMoves(ms)){
      const v=search(play(board,m,ctx.forward),0,nd,alpha,beta,nq,ctx);
      if(v<best) best=v; if(v<beta) beta=v; if(alpha>=beta) break;
    }
    return best;
  } finally { ctx.ply--; }
}

function tacticalFloor(boardAfterRoot,forward){
  const replies=legal(boardAfterRoot,1,forward);
  if(!replies.length) return MATE-1;
  let worst=Infinity;
  for(const reply of replies){
    const b2=play(boardAfterRoot,reply,forward), ourMoves=legal(b2,0,forward);
    let v;
    if(!ourMoves.length) v=-MATE+2;
    else {
      v=staticEval(b2,forward);
      const oppCaps=reply.captureCount||0; if(oppCaps) v-=oppCaps*180;
      const ourForcedCap=(ourMoves[0].captureCount||0); if(ourForcedCap) v+=ourForcedCap*140;
    }
    if(v<worst) worst=v;
  }
  return worst;
}

export function analyze(snapshot){
  const me=String(snapshot?.identity?.player_id||''), players=Array.isArray(snapshot?.players)?snapshot.players:[];
  const mine=players.find(p=>String(p?.player_id||'')===me), other=players.find(p=>String(p?.player_id||'')!==me);
  if(!me||!mine||!other) throw new Error('INVALID_PLAYERS');
  const forward=[mine?.color==='red'?1:-1, other?.color==='red'?1:-1];
  const board=new Int8Array(64), idSq=new Map();
  for(const p of snapshot?.pieces||[]){
    const s=String(p?.player_id||'')===me?0:1, q=ix(+p.row,+p.col);
    board[q]=p.is_king?queen(s):man(s); idSq.set(String(p.id),q);
  }
  const roots=[...(snapshot?.legal_moves||[])]; if(!roots.length) throw new Error('NO_LEGAL_MOVES');

  const started=performance.now(), rootBoards=new Map();
  let best=roots[0], bestScore=-Infinity;
  for(const r of roots){
    const b=rootPlay(board,r,idSq,forward); rootBoards.set(String(r.route_id),b);
    const s=tacticalFloor(b,forward); if(s>bestScore){bestScore=s;best=r;}
  }
  roots.sort((a,b)=>String(a.route_id)===String(best.route_id)?-1:String(b.route_id)===String(best.route_id)?1:0);

  let depthDone=2, nodes=0; const deadline=started+SEARCH_MS;
  for(let depth=3; depth<=MAX_DEPTH; depth++){
    let roundBest=best, roundScore=-Infinity, complete=true; const ctx={deadline,nodes:0,forward,ply:1};
    try {
      for(const r of roots){
        if(performance.now()>=deadline) throw TIMEOUT;
        const v=search(rootBoards.get(String(r.route_id)),1,depth-1,-MATE,MATE,0,ctx);
        if(v>roundScore){roundScore=v;roundBest=r;}
      }
    } catch(e){ if(e!==TIMEOUT) throw e; complete=false; }
    nodes+=ctx.nodes; if(!complete) break;
    best=roundBest; bestScore=roundScore; depthDone=depth;
    roots.sort((a,b)=>String(a.route_id)===String(best.route_id)?-1:String(b.route_id)===String(best.route_id)?1:0);
    if(Math.abs(bestScore)>=MATE-1000) break;
  }

  const path=Array.isArray(best?.path)&&best.path.length>=2?best.path:[{row:+best.from_row,col:+best.from_col},{row:+best.to_row,col:+best.to_col}];
  return {
    route_id:best.route_id,piece_id:best.piece_id,path,
    from:{row:+best.from_row,col:+best.from_col},to:{row:+best.to_row,col:+best.to_col},capture_count:+(best.capture_count||0),
    depth:depthDone,nodes,elapsed_ms:Math.round(performance.now()-started),score:bestScore,
    board_version:snapshot?.room?.board_version??null,move_seq:snapshot?.room?.move_seq??null,mode:'tactical_search'
  };
}
