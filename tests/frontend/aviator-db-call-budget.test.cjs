'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');

test('multiplicador do voo não chama banco por frame',()=>{
  const paint=js.match(/function paintFlight\([\s\S]*?\n\}/)?.[0]||'';
  const loop=js.match(/function flightPaintLoop\([\s\S]*?\n\}/)?.[0]||'';
  assert.doesNotMatch(paint,/JLApi\.rpc|jl_aviator_public_state|jl_aviator_player_state/);
  assert.doesNotMatch(loop,/JLApi\.rpc|jl_aviator_public_state|jl_aviator_player_state/);
  assert.match(loop,/requestAnimationFrame\(flightPaintLoop\)/);
});

test('auto cash-out visual usa status mínimo por bet_id, não player_state',()=>{
  const light=js.match(/async function refreshCurrentBetLight\(\)[\s\S]*?\n\}/)?.[0]||'';
  const fetch=js.match(/async function fetchBetStatus\(betId\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(fetch,/jl_aviator_bet_status/);
  assert.match(fetch,/p_bet_id:id/);
  assert.doesNotMatch(fetch,/jl_aviator_player_state/);
  assert.match(light,/fetchBetStatus\(requestedBetId\)/);
});

test('mudança pública de rodada não consulta player_state para todos',()=>{
  const block=js.match(/async function applyRealtimeSnapshot\(x\)[\s\S]*?\n\}/)?.[0]||'';
  assert.doesNotMatch(block,/recover\(true\)/);
  assert.match(block,/Boolean\(myBet\).*changedStatus/s);
  assert.match(block,/refreshCurrentBetLight\(\)/);
});

test('reconciliação de cash-out pendente usa consulta mínima',()=>{
  const block=js.match(/async function reconcilePendingCashout\(\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(block,/fetchBetStatus\(pending\.bet_id\)/);
  assert.doesNotMatch(block,/jl_aviator_player_state/);
});

test('polling com Realtime continua somente como fallback lento',()=>{
  assert.match(js,/if\(realtimeConnected\)return document\.hidden\?300000:120000/);
});
