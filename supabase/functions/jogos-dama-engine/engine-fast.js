const N = 8;
const EMPTY = 0, M0 = 1, K0 = 2, M1 = -1, K1 = -2;
const MATE = 1_000_000;
const SEARCH_MS = 620;
const QMAX = 7;
const TIMEOUT = Symbol('timeout');
const DIRS = [[-1,-1],[-1,1],[1,-1],[1,1]];
const DARK = [];
for (let r=0;r<N;r++) for (let c=0;c<N;c++) if ((r+c)&1) DARK.push(r*8+c);

const ix=(r,c)=>r*8+c, row=s=>Math.floor(s/8), col=s=>s%8;
const inside=(r,c)=>r>=0&&r<8&&c>=0&&c<8;
const side=p=>p>0?0:1, king=p=>Math.abs(p)===2;
const man=s=>s?M1:M0, queen=s=>s?K1:K0, promo=dr=>dr>0?7:0;
const bit=s=>1n<<BigInt(s), was=(m,s)=>(m&bit(s))!==0n;
const clone=b=>new Int8Array(b);
const mkey=m=>`${m.from}>${m.to}:${(m.captures||[]).join(',')}`;

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
  walk(from,0n,[from],[]);
  return out;
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
  const b=clone(board), p=b[m.from], s=side(p);
  b[m.from]=EMPTY;
  for(const q of m.captures||[]) b[q]=EMPTY;
  b[m.to]=!king(p)&&row(m.to)===promo(forward[s])?queen(s):p;
  return b;
}

function rootMove(board,m,idSq){
  const from=ix(+m.from_row,+m.from_col),to=ix(+m.to_row,+m.to_col),p=board[from];
  if(!p) throw new Error('ROOT_PIECE_NOT_FOUND');
  const caps=[];
  for(const id of m.captures||[]){const q=idSq.get(String(id));if(q!=null)caps.push(q);}
  return {from,to,path:Array.isArray(m.path)?m.path:[],captures:caps,captureCount:+(m.capture_count||caps.length||0),piece:p,promotes:false,route:m};
}

function phaseInfo(board){
  let total=0,kings=0,m0=0,k0=0,m1=0,k1=0;
  for(const q of DARK){
    const p=board[q]; if(!p) continue; total++;
    if(p===M0)m0++; else if(p===K0){k0++;kings++;}
    else if(p===M1)m1++; else {k1++;kings++;}
  }
  return {total,kings,m0,k0,m1,k1};
}

function sideStats(board,s){
  let m=0,k=0,long=false;
  for(const q of DARK){
    const p=board[q]; if(!p||side(p)!==s) continue;
    if(king(p)){k++; if(row(q)+col(q)===7) long=true;} else m++;
  }
  return {m,k,long:k===1&&m===0&&long};
}

function regulationState(board,seatOfSide){
  const a0=sideStats(board,0),a1=sideStats(board,1);
  const seat1=seatOfSide[0]===1?a0:a1;
  const seat2=seatOfSide[0]===2?a0:a1;
  const ak=seat1.k,am=seat1.m,bk=seat2.k,bm=seat2.m;
  const aLong=seat1.long,bLong=seat2.long;
  let limit=0;
  if(ak===1&&am===0&&bk===1&&bm===0) limit=2;
  else if((ak===2&&am===0&&bk===1&&bm===0)||(bk===2&&bm===0&&ak===1&&am===0)||(ak===1&&am===1&&bk===1&&bm===0)||(bk===1&&bm===1&&ak===1&&am===0)||(ak===1&&am===1&&bk===1&&bm===1)||(ak===2&&am===0&&bk===2&&bm===0)||(bLong&&((ak===3&&am===0)||(ak===2&&am===1)||(ak===1&&am===2)))||(aLong&&((bk===3&&bm===0)||(bk===2&&bm===1)||(bk===1&&bm===2)))) limit=5;
  const key=limit?`${ak}:${am}:${bk}:${bm}:${aLong?'t':'f'}:${bLong?'t':'f'}:${limit}`:null;
  return {key,limit};
}

function initialDraw(snapshot,mine,other){
  const d=snapshot?.draw||{}, room=snapshot?.room||{};
  const quietBySeat={1:+(d.quiet_light||0),2:+(d.quiet_dark||0)};
  const regBySeat={1:+(d.regulation_light||0),2:+(d.regulation_dark||0)};
  return {quiet:[quietBySeat[+mine.seat]||0,quietBySeat[+other.seat]||0],reg:[regBySeat[+mine.seat]||0,regBySeat[+other.seat]||0],regKey:room.regulation_key??null,regLimit:+(room.regulation_limit||d.regulation_limit||0)};
}

function applyDraw(boardBefore,boardAfter,m,draw,seatOfSide){
  const mover=side(boardBefore[m.from]), wasKing=king(boardBefore[m.from]);
  const next={quiet:[draw.quiet[0],draw.quiet[1]],reg:[draw.reg[0],draw.reg[1]],regKey:draw.regKey,regLimit:draw.regLimit};
  if(wasKing&&(m.captureCount||0)===0) next.quiet[mover]++;
  else next.quiet=[0,0];
  const rs=regulationState(boardAfter,seatOfSide);
  if(rs.limit>0){if(next.regKey!==rs.key) next.reg=[0,0]; else next.reg[mover]++;}
  else next.reg=[0,0];
  next.regKey=rs.key; next.regLimit=rs.limit;
  return next;
}

function boardKey(board,turn){
  let k=turn?'1':'0';
  for(const q of DARK){const p=board[q];k+=p===0?'0':p===M0?'1':p===K0?'2':p===M1?'3':'4';}
  return k;
}
function drawKey(d){return `${Math.min(20,d.quiet[0])},${Math.min(20,d.quiet[1])};${Math.min(9,d.reg[0])},${Math.min(9,d.reg[1])};${d.regKey||'-'};${d.regLimit||0}`;}
function isRuleDraw(draw){if(draw.quiet[0]>=20&&draw.quiet[1]>=20) return true;return draw.regLimit>0&&draw.reg[0]>=draw.regLimit&&draw.reg[1]>=draw.regLimit;}

function quietMobility(board,s,forward){
  let count=0;
  for(const q of DARK){
    const p=board[q]; if(!p||side(p)!==s) continue;
    const r=row(q),c=col(q);
    if(king(p)){
      for(const [dr,dc] of DIRS){let rr=r+dr,cc=c+dc;while(inside(rr,cc)&&!board[ix(rr,cc)]){count++;rr+=dr;cc+=dc;}}
    }else{
      const rr=r+forward[s];
      for(const dc of[-1,1]){const cc=c+dc;if(inside(rr,cc)&&!board[ix(rr,cc)])count++;}
    }
  }
  return count;
}

function immediateCapturePressure(board,attacker){
  const seen=new Set(); let routes=0;
  for(const q of DARK){
    const p=board[q]; if(!p||side(p)!==attacker) continue;
    const r=row(q),c=col(q);
    if(!king(p)){
      for(const [dr,dc] of DIRS){
        const er=r+dr,ec=c+dc,lr=r+2*dr,lc=c+2*dc;
        if(!inside(er,ec)||!inside(lr,lc))continue;
        const e=ix(er,ec),land=ix(lr,lc),occ=board[e];
        if(occ&&side(occ)!==attacker&&!board[land]){routes++;seen.add(e);}
      }
    }else{
      for(const [dr,dc] of DIRS){
        let rr=r+dr,cc=c+dc,enemy=-1;
        while(inside(rr,cc)){
          const sq=ix(rr,cc),occ=board[sq];
          if(occ){if(enemy>=0||side(occ)===attacker)break;enemy=sq;rr+=dr;cc+=dc;continue;}
          if(enemy>=0){routes++;seen.add(enemy);break;}
          rr+=dr;cc+=dc;
        }
      }
    }
  }
  return seen.size*20+Math.min(routes,8)*3;
}

function structureScore(board,s,forward,phase){
  let score=0,pieces=0,connected=0,isolated=0,backGuard=0,nearPromo=0,edge=0;
  const home=forward[s]>0?0:7;
  for(const q of DARK){
    const p=board[q]; if(!p||side(p)!==s)continue;
    pieces++; const r=row(q),c=col(q); let friends=0;
    for(const [dr,dc] of DIRS){const rr=r+dr,cc=c+dc;if(inside(rr,cc)){const z=board[ix(rr,cc)];if(z&&side(z)===s)friends++;}}
    if(friends)connected+=Math.min(2,friends); else isolated++;
    if(c===0||c===7)edge++;
    if(!king(p)){
      const dist=Math.abs(promo(forward[s])-r);
      if(r===home)backGuard++;
      if(dist===1)nearPromo+=2; else if(dist===2)nearPromo++;
      let forwardFree=0,rr=r+forward[s];
      for(const dc of[-1,1]){const cc=c+dc;if(inside(rr,cc)&&!board[ix(rr,cc)])forwardFree++;}
      if(!forwardFree&&r!==promo(forward[s]))score-=6;
    }
  }
  score+=connected*6-isolated*5+nearPromo*8;
  if(phase.total>=12)score+=Math.min(backGuard,2)*8;
  else if(phase.total<=8)score-=Math.max(0,backGuard-1)*3;
  score+=Math.min(edge,3)*(phase.total>=14?2:0);
  if(pieces===1)score-=4;
  return score;
}

function diagonalScore(board,s){
  let score=0;
  for(const q of DARK){
    const p=board[q]; if(!p||side(p)!==s||!king(p))continue;
    const r=row(q),c=col(q);
    if(r===c)score+=6;
    if(r+c===7)score+=8;
    if(r>=2&&r<=5&&c>=2&&c<=5)score+=5;
  }
  return score;
}
function promotionRace(board,s,forward){
  let best=99,count=0;
  for(const q of DARK){const p=board[q];if(!p||side(p)!==s||king(p))continue;count++;best=Math.min(best,Math.abs(promo(forward[s])-row(q)));}
  if(!count)return 0;return best===1?24:best===2?10:best===3?3:0;
}

function staticEval(board,forward,turn,moves,draw){
  const phase=phaseInfo(board);
  if(!phase.m0&&!phase.k0)return-MATE;
  if(!phase.m1&&!phase.k1)return MATE;
  const end=phase.total<=10,deepEnd=phase.total<=6;
  const kingValue=deepEnd?415:end?385:350;
  let score=0;
  for(const q of DARK){
    const p=board[q]; if(!p)continue;
    const s=side(p),sign=s===0?1:-1,r=row(q),c=col(q);
    const central=Math.max(0,7-(Math.abs(3.5-r)+Math.abs(3.5-c)));
    if(king(p)){
      let v=kingValue+central*(end?8:4);if(c===0||c===7)v-=end?10:4;score+=sign*v;
    }else{
      const adv=forward[s]>0?r:7-r,dist=Math.abs(promo(forward[s])-r);
      let v=100+adv*(end?9:6)+central*2;if(dist===1)v+=end?42:30;else if(dist===2)v+=end?18:11;if(c===0||c===7)v+=3;score+=sign*v;
    }
  }
  score+=structureScore(board,0,forward,phase)-structureScore(board,1,forward,phase);
  score+=diagonalScore(board,0)-diagonalScore(board,1);
  score+=promotionRace(board,0,forward)-promotionRace(board,1,forward);
  const mob0=quietMobility(board,0,forward),mob1=quietMobility(board,1,forward);
  score+=Math.max(-55,Math.min(55,(mob0-mob1)*(end?3:2)));
  score+=immediateCapturePressure(board,0)-immediateCapturePressure(board,1);
  if(Array.isArray(moves)&&moves.length){const cap=moves[0].captureCount||0;if(cap)score+=(turn===0?1:-1)*Math.min(110,cap*32);score+=(turn===0?1:-1)*Math.min(20,moves.length);}
  const materialLead=(phase.m0+phase.k0*3)-(phase.m1+phase.k1*3);
  if(end&&materialLead!==0){const simplify=(12-phase.total)*4;score+=materialLead>0?simplify:-simplify;}
  if(draw){
    const q=Math.min(draw.quiet[0],draw.quiet[1]);
    const r=draw.regLimit>0?Math.min(draw.reg[0],draw.reg[1])/draw.regLimit:0;
    const danger=Math.max(q/20,r);
    if(danger>0.55&&Math.abs(score)>70){const penalty=Math.round(55*danger);score+=score>0?-penalty:penalty;}
  }
  return score;
}

function moveOrderScore(m,ttBest,killer){
  let s=(m.captureCount||0)*13000+(m.promotes?3500:0)+(king(m.piece)?90:0);
  const r=row(m.to),c=col(m.to);s+=Math.round((7-(Math.abs(3.5-r)+Math.abs(3.5-c)))*7);
  const k=mkey(m);if(ttBest&&k===ttBest)s+=1_000_000;if(killer&&k===killer)s+=18_000;return s;
}
function ordered(ms,ttBest,killer){return [...ms].sort((a,b)=>moveOrderScore(b,ttBest,killer)-moveOrderScore(a,ttBest,killer));}
function tick(ctx){ctx.nodes++;if((ctx.nodes&31)===0&&performance.now()>=ctx.deadline)throw TIMEOUT;}
function pushRep(ctx,key){const n=(ctx.rep.get(key)||0)+1;ctx.rep.set(key,n);if(n===2)ctx.repeated++;return n;}
function popRep(ctx,key){const n=ctx.rep.get(key)||0;if(n===2)ctx.repeated--;if(n<=1)ctx.rep.delete(key);else ctx.rep.set(key,n-1);}

function search(board,turn,depth,alpha,beta,qdepth,ply,draw,extLeft,ctx){
  tick(ctx);
  const ms=legal(board,turn,ctx.forward);
  if(!ms.length)return turn===0?-MATE+ply:MATE-ply;
  if(isRuleDraw(draw))return 0;
  const posKey=boardKey(board,turn);
  const currentReps=ctx.rep.get(posKey)||0;
  if(currentReps>=3)return 0;
  const ttKey=`${posKey}|${drawKey(draw)}`;
  const alpha0=alpha,beta0=beta;
  const useTT=ctx.repeated===0;
  const hit=useTT?ctx.tt.get(ttKey):null;
  if(depth>0&&hit&&hit.depth>=depth){if(hit.flag===0)return hit.score;if(hit.flag===1)alpha=Math.max(alpha,hit.score);else beta=Math.min(beta,hit.score);if(alpha>=beta)return hit.score;}
  const capture=(ms[0].captureCount||0)>0;
  if(depth<=0&&(!capture||qdepth>=QMAX))return staticEval(board,ctx.forward,turn,ms,draw);
  const canExtend=depth>0&&extLeft>0&&depth<=3&&(capture||ms.length===1);
  const nd=depth>0?Math.max(0,depth-1+(canExtend?1:0)):0;
  const nq=depth>0?0:qdepth+1;
  const nextExt=canExtend?extLeft-1:extLeft;
  const moves=ordered(ms,hit?.best,ctx.killers[ply]||'');
  let best=turn===0?-Infinity:Infinity,bestMove='';
  if(turn===0){
    for(const m of moves){
      const b2=play(board,m,ctx.forward),d2=applyDraw(board,b2,m,draw,ctx.seatOfSide),rk=boardKey(b2,1),reps=pushRep(ctx,rk);let v;
      try{v=reps>=3?0:search(b2,1,nd,alpha,beta,nq,ply+1,d2,nextExt,ctx);}finally{popRep(ctx,rk);}
      if(v>best){best=v;bestMove=mkey(m);}if(v>alpha)alpha=v;if(alpha>=beta){if(!(m.captureCount||0))ctx.killers[ply]=mkey(m);break;}
    }
  }else{
    for(const m of moves){
      const b2=play(board,m,ctx.forward),d2=applyDraw(board,b2,m,draw,ctx.seatOfSide),rk=boardKey(b2,0),reps=pushRep(ctx,rk);let v;
      try{v=reps>=3?0:search(b2,0,nd,alpha,beta,nq,ply+1,d2,nextExt,ctx);}finally{popRep(ctx,rk);}
      if(v<best){best=v;bestMove=mkey(m);}if(v<beta)beta=v;if(alpha>=beta){if(!(m.captureCount||0))ctx.killers[ply]=mkey(m);break;}
    }
  }
  if(depth>0&&useTT){const flag=best<=alpha0?2:best>=beta0?1:0;if(ctx.tt.size<45000)ctx.tt.set(ttKey,{depth,score:best,flag,best:bestMove});}
  return best;
}

function tacticalFloor(boardAfterRoot,rootLocal,drawAfter,ctx){
  const replies=legal(boardAfterRoot,1,ctx.forward);if(!replies.length)return MATE-1;
  let worst=Infinity;
  for(const reply of replies){
    const b2=play(boardAfterRoot,reply,ctx.forward),d2=applyDraw(boardAfterRoot,b2,reply,drawAfter,ctx.seatOfSide),ourMoves=legal(b2,0,ctx.forward);let v;
    if(!ourMoves.length)v=-MATE+2;
    else if(isRuleDraw(d2))v=0;
    else{v=staticEval(b2,ctx.forward,0,ourMoves,d2);const oppCaps=reply.captureCount||0;if(oppCaps)v-=oppCaps*225;const ourCap=ourMoves[0].captureCount||0;if(ourCap)v+=ourCap*175;}
    if(v<worst)worst=v;
  }
  return worst;
}

function adaptiveDepth(board){
  const p=phaseInfo(board);
  if(p.total<=4)return 20;
  if(p.total<=6)return 18;
  if(p.total<=8)return 15;
  if(p.total<=12)return 12;
  if(p.total<=18)return 10;
  return 9;
}

export function analyze(snapshot){
  const me=String(snapshot?.identity?.player_id||'');
  const players=Array.isArray(snapshot?.players)?snapshot.players:[];
  const mine=players.find(p=>String(p?.player_id||'')===me),other=players.find(p=>String(p?.player_id||'')!==me);
  if(!me||!mine||!other)throw new Error('INVALID_PLAYERS');
  const forward=[mine?.color==='red'?1:-1,other?.color==='red'?1:-1];
  const seatOfSide=[+mine.seat,+other.seat];
  const board=new Int8Array(64),idSq=new Map();
  for(const p of snapshot?.pieces||[]){const s=String(p?.player_id||'')===me?0:1,q=ix(+p.row,+p.col);board[q]=p.is_king?queen(s):man(s);idSq.set(String(p.id),q);}
  const roots=[...(snapshot?.legal_moves||[])];if(!roots.length)throw new Error('NO_LEGAL_MOVES');
  const initial=initialDraw(snapshot,mine,other);
  const started=performance.now(),deadline=started+SEARCH_MS;
  const rootData=new Map();
  const shared={forward,seatOfSide};
  let best=roots[0],bestScore=-Infinity;
  for(const r of roots){
    const lm=rootMove(board,r,idSq);lm.promotes=!king(lm.piece)&&row(lm.to)===promo(forward[0]);
    const b=play(board,lm,forward),d=applyDraw(board,b,lm,initial,seatOfSide);
    rootData.set(String(r.route_id),{board:b,draw:d,move:lm});
    const s=tacticalFloor(b,lm,d,{...shared});if(s>bestScore){bestScore=s;best=r;}
  }
  roots.sort((a,b)=>String(a.route_id)===String(best.route_id)?-1:String(b.route_id)===String(best.route_id)?1:0);
  const maxDepth=adaptiveDepth(board),tt=new Map(),killers=[];
  let depthDone=2,totalNodes=0,pv=String(best.route_id),proven=false;
  const rootKey=boardKey(board,0);
  for(let depth=3;depth<=maxDepth;depth++){
    const rep=new Map([[rootKey,1]]);
    const ctx={deadline,nodes:0,forward,seatOfSide,tt,killers,rep,repeated:0};
    let roundBest=best,roundScore=-Infinity,complete=true,alpha=-MATE;
    roots.sort((a,b)=>String(a.route_id)===pv?-1:String(b.route_id)===pv?1:0);
    try{
      for(const r of roots){
        if(performance.now()>=deadline)throw TIMEOUT;
        const data=rootData.get(String(r.route_id)),rk=boardKey(data.board,1);pushRep(ctx,rk);let v;
        try{v=search(data.board,1,depth-1,alpha,MATE,0,1,data.draw,2,ctx);}finally{popRep(ctx,rk);}
        if(v>roundScore){roundScore=v;roundBest=r;}if(v>alpha)alpha=v;
      }
    }catch(e){if(e!==TIMEOUT)throw e;complete=false;}
    totalNodes+=ctx.nodes;if(!complete)break;
    best=roundBest;bestScore=roundScore;depthDone=depth;pv=String(best.route_id);
    if(Math.abs(bestScore)>=MATE-1000){proven=true;break;}
  }
  const path=Array.isArray(best?.path)&&best.path.length>=2?best.path:[{row:+best.from_row,col:+best.from_col},{row:+best.to_row,col:+best.to_col}];
  const phase=phaseInfo(board);
  return {route_id:best.route_id,piece_id:best.piece_id,path,from:{row:+best.from_row,col:+best.from_col},to:{row:+best.to_row,col:+best.to_col},capture_count:+(best.capture_count||0),depth:depthDone,nodes:totalNodes,elapsed_ms:Math.round(performance.now()-started),score:bestScore,board_version:snapshot?.room?.board_version??null,move_seq:snapshot?.room?.move_seq??null,mode:'strategic_v7',max_depth:maxDepth,tt_entries:tt.size,endgame:phase.total<=8,proven};
}
