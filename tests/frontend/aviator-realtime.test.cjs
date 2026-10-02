'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const runtime=require('../../js/aviator/runtime.js');

test('Aviator usa Broadcast público e não Postgres Changes',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../js/realtime/aviator.js'),'utf8');
  assert.match(js,/channel\('aviator:round'/);
  assert.match(js,/\.on\('broadcast',\{event:'state'\}/);
  assert.doesNotMatch(js,/postgres_changes/);
  assert.doesNotMatch(js,/from\(['"]jl_aviator_rounds/);
});

test('cliente Supabase está fixado e carrega antes do controlador',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../aviator.html'),'utf8');
  const sdk=html.indexOf('@supabase/supabase-js@2.117.2/dist/umd/supabase.min.js');
  const realtime=html.indexOf('./js/realtime/aviator.js');
  const controller=html.indexOf('./aviator.js');
  assert.ok(sdk>=0);
  assert.ok(realtime>sdk);
  assert.ok(controller>realtime);
});

test('Realtime saudável reconcilia o voo a cada frame autoritativo',()=>{
  assert.equal(runtime.pollDelay('FLYING',false,true),250);
  assert.equal(runtime.pollDelay('OPEN',false,true),750);
  assert.equal(runtime.pollDelay('SETTLED',false,true),750);
  assert.equal(runtime.pollDelay('FLYING',true,true),300000);
});

test('fallback sem WebSocket mantém o voo preso ao servidor',()=>{
  assert.equal(runtime.pollDelay('FLYING',false,false),250);
  assert.equal(runtime.pollDelay('LOCKED',false,false),1000);
  assert.equal(runtime.pollDelay('OPEN',false,false),750);
  assert.equal(runtime.pollDelay('SETTLED',false,false),750);
});

test('multiplicador visual não extrapola além do frame confirmado pelo servidor',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  const engine=fs.readFileSync(path.join(__dirname,'../../js/aviator/engine.js'),'utf8');
  const finance=fs.readFileSync(path.join(__dirname,'../../js/aviator/financial.js'),'utf8');
  assert.match(js,/requestAnimationFrame\(flightPaintLoop\)/);
  assert.match(engine,/round\?\.current_multiplier/);
  assert.doesNotMatch(engine,/runtime\.liveMultiplier\(/);

  const financial=finance.match(/async function requestFinancialCashout\(betId,requestKey\)[\s\S]*?\n    \}/)?.[0]||'';
  assert.match(financial,/jl_aviator_cashout/);
  assert.match(financial,/p_bet_id:id/);
  assert.doesNotMatch(financial,/p_multiplier|current_multiplier|started_at/);
});

test('controller recebe estado Realtime e mantém polling somente como reconciliação',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/async function applyRealtimeSnapshot\(x\)/);
  assert.match(js,/startRealtime\(\)/);
  assert.match(js,/if\(connected\)[\s\S]*?scheduleState\(\)/);
  assert.match(js,/syncServerClock\(x\)/);
});
