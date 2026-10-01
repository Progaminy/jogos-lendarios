'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

const source=fs.readFileSync('js/api/rpc.js','utf8');

function harness({storedToken,requestMessage='Sessão do jogador inválida ou expirada.'}){
  let token=storedToken;
  const events=[];
  const local=new Map(storedToken ? [['jl_player_token',storedToken]] : []);

  const window={
    JL_CONFIG:{supabaseUrl:'https://example.invalid',supabaseKey:'anon-test-key'},
    JLSession:{
      getPlayerToken:()=>token,
      setPlayerToken:(value)=>{
        token=String(value||'');
        if(token)local.set('jl_player_token',token);
        else local.delete('jl_player_token');
        return token;
      }
    },
    dispatchEvent:(event)=>events.push(event)
  };

  const context={
    window,
    localStorage:{
      getItem:(key)=>local.get(key)||null,
      setItem:(key,value)=>local.set(key,String(value)),
      removeItem:(key)=>local.delete(key)
    },
    CustomEvent:class CustomEvent{
      constructor(type,init={}){this.type=type;this.detail=init.detail;}
    },
    fetch:async()=>({
      ok:false,
      status:400,
      text:async()=>JSON.stringify({message:requestMessage})
    }),
    JSON,
    Error,
    String,
    Boolean,
    Object
  };

  vm.runInNewContext(source,context,{filename:'js/api/rpc.js'});

  return {
    rpc:window.JLApi.rpc,
    token:()=>token,
    events
  };
}

test('token rejeitado da sessao atual encerra a sessao local',async()=>{
  const h=harness({storedToken:'token-antigo'});

  await assert.rejects(
    h.rpc('jl_player_state',{p_token:'token-antigo'}),
    /Sessão do jogador inválida ou expirada/
  );

  assert.equal(h.token(),'');
  assert.equal(h.events.length,2);
  assert.equal(h.events[0].type,'jl-player-session-changed');
  assert.equal(h.events[1].type,'jl-player-session-invalidated');
});

test('resposta atrasada do token antigo nao derruba o login mais recente',async()=>{
  const h=harness({storedToken:'token-novo'});

  await assert.rejects(
    h.rpc('jl_player_state',{p_token:'token-antigo'}),
    /Sessão do jogador inválida ou expirada/
  );

  assert.equal(h.token(),'token-novo');
  assert.equal(h.events.length,0);
});

test('erros que nao sao de sessao nao encerram a conta',async()=>{
  const h=harness({
    storedToken:'token-atual',
    requestMessage:'Saldo insuficiente.'
  });

  await assert.rejects(
    h.rpc('jl_place_bet',{p_token:'token-atual'}),
    /Saldo insuficiente/
  );

  assert.equal(h.token(),'token-atual');
  assert.equal(h.events.length,0);
});
