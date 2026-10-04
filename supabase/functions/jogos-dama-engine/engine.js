const N = 8;
const EMPTY = 0, M0 = 1, K0 = 2, M1 = -1, K1 = -2;
const MATE = 1_000_000, MAX_DEPTH = 18, SEARCH_MS = 2600, QMAX = 6;
const TIMEOUT = Symbol('timeout');
const DIRS = [[-1,-1],[-1,1],[1,-1],[1,1]];
const DARK = [];
for (let r=0;r<N;r++) for (let c=0;c<N;c++) if ((r+c)&1) DARK.push(r*8+c);

const ix=(r,c)=>r*8+c, row=s=>Math.floor(s/8), col=s=>s%8;
const inside=(r,c)=>r>=0&&r<8&&c>=0&&c<8;
const side=p=>p>0?0:1, king=p=>Math.abs(p)===2, foe=s=>s?0:1;
const man=s=>s?M1:M0, queen=s=>s?K1:K0, promo=f=>f>0?7:0;
const bit=s=>1n<<BigInt(s), was=(m,s)=>(m&bit(s))!==0n;
const clone=b=>new Int8Array(b);

function key(board, turn){
  let s=turn?'1':'0';
  for(const q of DARK){const v=board[q];s+=v===0?'0':v===1?'1':v===2?'2':v===-1?'3':'4';}
  return s;
}
const moveKey=m=>`${m.from}>${m.to}:${m.captures.join(',')}`;

function captureRoutes(board, from, piece){
  const out=[], owner=side(piece), start=from;
  function walk(at, mask, path, caps){
    let more=false; const r=row(at), c=col(at);
    if(!king(piece)){
      for(const [dr,dc] of DIRS){
        const er=r+dr,ec=c+dc,lr=r+2*dr,lc=c+2*dc;
        if(!inside(er,ec)||!inside(lr,lc)) continue;
        const e=ix(er,ec), land=ix(lr,lc), occ=board[e];
        if(!occ||side(occ)===owner||was(mask,e)||board[land]) continue;
        more=true; board[at]=EMPTY; board[land]=piece;
        walk(land,mask|bit(e),[...path,land],[...caps,e]);
        board[land]=EMPTY; board[at]=piece;
      }
    }else{
      for(const [dr,dc] of DIRS){
        let rr=r+dr,cc=c+dc,enemy=-1;
        while(inside(rr,cc)){
          const q=ix(rr,cc),occ=board[q];
          if(occ){
            if(enemy>=0||side(occ)===owner||was(mask,q)) break;
            enemy=q; rr+=dr; cc+=dc; continue;
          }
          if(enemy>=0){
            more=true; board[at]=EMPTY; board[q]=piece;
            walk(q,mask|bit(enemy),[...path,q],[...caps,enemy]);
            board[q]=EMPTY; board[at]=piece;
          }
          rr+=dr; cc+=dc;
        }
      }
    }
    if(!more&&caps.length) out.push({from:start,to:path.at(-1),path:[...path],captures:[...caps],captureCount:caps.length,piece,promotes:false});
  }
  walk(from,0n,[from],[]); return out;
}

function legal(board, turn, forward){
  let caps=[],max=0;
  for(const q of DARK){
    const p=board[q]; if(!p||side(p)!==turn) continue;
    for(const m of captureRoutes(board,q,p)){
      m.promotes=!king(p)&&row(m.to)===promo(forward[turn]);
      if(m.captureCount>max){max=m.captureCount;caps=[m];}
      else if(m.captureCount===max&&max) caps.push(m);
    }
  }
  if(max) return caps;
  const out=[];
  for(const q of DARK){
    const p=board[q]; if(!p||side(p)!==turn) continue;
    const r=row(q),c=col(q);
    if(king(p)){
      for(const [dr,dc] of DIRS){let rr=r+dr,cc=c+dc;while(inside(rr,cc)){const to=ix(rr,cc);if(board[to])break;out.push({from:q,to,path:[q,to],captures:[],captureCount:0,piece:p,promotes:false});rr+=dr;cc+=dc;}}
    }else{
      const dr=forward[turn];
      for(const dc of[-1,1]){const rr=r+dr,cc=c+dc;if(!inside(rr,cc))continue;const to=ix(rr,cc);if(board[to])continue;out.push({from:q,to,path:[q,to],captures:[],captureCount:0,piece:p,promotes:rr===promo(dr)});}
    }
  }
  return out;
}

function play(board,m,forward){
  const b=clone(board),p=b[m.from],s=side(p); b[m.from]=EMPTY;
  for(const q of m.captures)b[q]=EMPTY;
  b[m.to]=!king(p)&&row(m.to)===promo(forward[s])?queen(s):p; return b;
}

function rootPlay(board,m,idSq,forward){
  const b=clone(board),from=ix(+m.from_row,+m.from_col),to=ix(+m.to_row,+m.to_col),p=b[from];
  if(!p) throw new Error('ROOT_PIECE_NOT_FOUND'); const s=side(p); b[from]=EMPTY;
  for(const id of m.captures||[]){const q=idSq.get(String(id));if(q!=null)b[q]=EMPTY;}
  b[to]=!king(p)&&row(to)===promo(forward[s])?queen(s):p; return b;
}

function material(board,s,forward){
  let score=0,men=0,kings=0;
  for(const q of DARK){const p=board[q];if(!p||side(p)!==s)continue;const r=row(q),c=col(q),center=r>=2&&r<=5&&c>=2&&c<=5;
    if(king(p)){kings++;score+=335+(center?14:0)-(c===0||c===7?3:0);}
    else{men++;const adv=forward[s]>0?r:7-r,dist=Math.abs(promo(forward[s])-r);score+=100+adv*7+(center?9:0)+(dist===1?18:dist===2?8:0);}
  }
  return{score,men,kings};
}
function evaluate(board,s,forward){
  const a=material(board,s,forward),b=material(board,foe(s),forward);
  if(!a.men&&!a.kings)return-MATE;if(!b.men&&!b.kings)return MATE;
  let v=a.score-b.score;
  const am=legal(board,s,forward).length,bm=legal(board,foe(s),forward).length;
  v+=Math.max(-40,Math.min(40,(am-bm)*2)); return v;
}

function ordered(ms,best){
  return ms.map(m=>{let s=m.captureCount*10000+(m.promotes?3000:0)+(king(m.piece)?100:0);const r=row(m.to),c=col(m.to);if(r>=2&&r<=5&&c>=2&&c<=5)s+=50;if(best&&moveKey(m)===best)s+=1e6;return{m,s};}).sort((a,b)=>b.s-a.s).map(x=>x.m);
}
function tick(ctx){ctx.nodes++;if((ctx.nodes&1023)===0&&performance.now()>=ctx.deadline)throw TIMEOUT;}
function negamax(board,turn,depth,alpha,beta,ply,qdepth,ctx){
  tick(ctx);const k=key(board,turn),hit=ctx.tt.get(k),a0=alpha;
  if(hit&&hit.depth>=depth){if(hit.flag===0)return hit.score;if(hit.flag===1)alpha=Math.max(alpha,hit.score);else beta=Math.min(beta,hit.score);if(alpha>=beta)return hit.score;}
  const ms=legal(board,turn,ctx.forward);if(!ms.length)return-MATE+ply;
  const capture=ms[0].captureCount>0;if(depth<=0&&(!capture||qdepth>=QMAX))return evaluate(board,turn,ctx.forward);
  const nd=depth>0?depth-1:0,nq=depth>0?qdepth:qdepth+1;let best=-Infinity,bk='';
  for(const m of ordered(ms,hit?.best)){const score=-negamax(play(board,m,ctx.forward),foe(turn),nd,-beta,-alpha,ply+1,nq,ctx);if(score>best){best=score;bk=moveKey(m);}if(score>alpha)alpha=score;if(alpha>=beta)break;}
  const flag=best<=a0?2:best>=beta?1:0;ctx.tt.set(k,{depth,score:best,flag,best:bk});return best;
}

function rootOrder(m,board,forward){const from=ix(+m.from_row,+m.from_col),p=board[from];let s=+(m.capture_count||0)*10000;if(p&&!king(p)&&+m.to_row===promo(forward[side(p)]))s+=3000;const r=+m.to_row,c=+m.to_col;if(r>=2&&r<=5&&c>=2&&c<=5)s+=50;return s;}

export function analyze(snapshot){
  const me=String(snapshot.identity?.player_id||''),players=Array.isArray(snapshot.players)?snapshot.players:[];
  const mine=players.find(p=>String(p.player_id)===me),other=players.find(p=>String(p.player_id)!==me),opp=String(other?.player_id||'');
  if(!me||!opp)throw new Error('INVALID_PLAYERS');
  const forward=[mine?.color==='red'?1:-1,other?.color==='red'?1:-1];
  const board=new Int8Array(64),idSq=new Map();
  for(const p of snapshot.pieces||[]){const s=String(p.player_id)===me?0:1,q=ix(+p.row,+p.col);board[q]=p.is_king?queen(s):man(s);idSq.set(String(p.id),q);}
  let roots=[...(snapshot.legal_moves||[])];if(!roots.length)throw new Error('NO_LEGAL_MOVES');roots.sort((a,b)=>rootOrder(b,board,forward)-rootOrder(a,board,forward));
  const started=performance.now(),deadline=started+SEARCH_MS,tt=new Map();let depthDone=0,best=roots[0],bestScore=-Infinity,nodes=0,pv=best.route_id;
  for(let depth=1;depth<=MAX_DEPTH;depth++){
    const ctx={deadline,nodes:0,tt,forward};let ib=roots[0],is=-Infinity,alpha=-MATE,complete=true;const beta=MATE;
    roots.sort((a,b)=>a.route_id===pv?-1:b.route_id===pv?1:rootOrder(b,board,forward)-rootOrder(a,board,forward));
    try{for(const r of roots){if(performance.now()>=deadline)throw TIMEOUT;const score=-negamax(rootPlay(board,r,idSq,forward),1,depth-1,-beta,-alpha,1,0,ctx);if(score>is){is=score;ib=r;}if(score>alpha)alpha=score;}}catch(e){if(e!==TIMEOUT)throw e;complete=false;}
    nodes+=ctx.nodes;if(!complete)break;depthDone=depth;best=ib;bestScore=is;pv=ib.route_id;if(Math.abs(bestScore)>=MATE-1000)break;
  }
  if(!depthDone){best=roots[0];bestScore=rootOrder(best,board,forward);}
  return{route_id:best.route_id,piece_id:best.piece_id,path:best.path,from:{row:best.from_row,col:best.from_col},to:{row:best.to_row,col:best.to_col},capture_count:+(best.capture_count||0),depth:depthDone,nodes,elapsed_ms:Math.round(performance.now()-started),score:bestScore,board_version:snapshot.room?.board_version??null,move_seq:snapshot.room?.move_seq??null};
}
