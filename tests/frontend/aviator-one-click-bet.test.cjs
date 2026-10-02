'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

function loadModule(){
  const source=fs.readFileSync('js/aviator/next-bet.js','utf8');
  const store=new Map();
  let now=1_000;

  class FakeDate extends Date {
    static now(){return now}
  }

  const sandbox={
    window:{},
    sessionStorage:{
      getItem:k=>store.has(k)?store.get(k):null,
      setItem:(k,v)=>store.set(k,String(v)),
      removeItem:k=>store.delete(k)
    },
    queueMicrotask,
    Date:FakeDate,
    JSON,
    Number,
    String,
    Math
  };
  vm.createContext(sandbox);
  vm.runInContext(source,sandbox);
  return {
    api:sandbox.window.JLAviatorNextBet,
    advance:ms=>{now+=ms}
  };
}

test('um clique continua válido mesmo se a primeira tentativa automática não entrar',async()=>{
  const {api,advance}=loadModule();
  let round={id:10,status:'FLYING',betting_open:false};
  let submits=0;
  const amount={value:'0.5'};
  const auto={value:''};
  const button={dataset:{action:'queue-next'}};
  const form={requestSubmit(){submits+=1}};

  const query=selector=>({
    '#aviatorAmount':amount,
    '#aviatorAutoCashout':auto,
    '#betBtn':button
  })[selector]||null;

  const q=api.create({
    slot:1,
    $:query,
    playerToken:()=> 'token',
    getRound:()=>round,
    isEnabled:()=>true,
    isOnline:()=>true,
    isBusy:()=>false,
    hasActiveBet:()=>false,
    playerMessage:()=> 'erro',
    form,
    onMessage:()=>{}
  });

  assert.equal(q.handleAction('queue-next'),true);
  assert.equal(q.hasQueued(),true);

  round={id:11,status:'OPEN',betting_open:true};
  q.resetRound();
  q.schedule();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(submits,1);
  assert.equal(button.dataset.action,'bet');

  q.clearSubmitting(11);
  assert.equal(q.hasQueued(),true,'falha não pode apagar o primeiro clique');

  advance(300);
  q.schedule();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(submits,2,'deve tentar novamente sozinho');
  assert.equal(q.hasQueued(),true);

  assert.equal(q.consume(11),true);
  assert.equal(q.hasQueued(),false,'só remove depois de confirmação');
});

test('não existe marcador prematuro de rodada já tentada',()=>{
  const source=fs.readFileSync('js/aviator/next-bet.js','utf8');
  assert.doesNotMatch(source,/attemptedRoundId/);
  assert.match(source,/submittingRoundId===roundId\|\|Date\.now\(\)<retryAfter/);
  assert.match(source,/if\(queued\)retryAfter=Date\.now\(\)\+250/);
});
