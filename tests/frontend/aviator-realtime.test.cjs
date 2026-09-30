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

test('Realtime saudável reduz polling a 30s/60s',()=>{
  assert.equal(runtime.pollDelay('FLYING',false,true),30000);
  assert.equal(runtime.pollDelay('OPEN',false,true),30000);
  assert.equal(runtime.pollDelay('FLYING',true,true),60000);
});

test('fallback sem WebSocket não volta ao polling agressivo antigo',()=>{
  assert.equal(runtime.pollDelay('FLYING',false,false),2000);
  assert.equal(runtime.pollDelay('LOCKED',false,false),2000);
  assert.equal(runtime.pollDelay('OPEN',false,false),5000);
  assert.equal(runtime.pollDelay('SETTLED',false,false),10000);
});

test('multiplicador visual interpola fórmula do servidor sem decidir cash-out',()=>{
  const started='2026-09-30T10:00:00.000Z';
  const now=Date.parse(started)+10_000;
  assert.ok(Math.abs(runtime.liveMultiplier(started,now)-Math.pow(1.06,10))<1e-10);

  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/requestAnimationFrame\(flightPaintLoop\)/);
  assert.match(js,/runtime\.liveMultiplier\(round\.started_at,serverNowMs\(\)\)/);

  const financial=js.match(/async function requestFinancialCashout\(betId,requestKey\)[\s\S]*?\n\}/)?.[0]||'';
  assert.match(financial,/jl_aviator_cashout/);
  assert.match(financial,/p_bet_id:Number\(betId\)/);
  assert.doesNotMatch(financial,/p_multiplier|current_multiplier|started_at/);
});

test('controller recebe estado Realtime e mantém polling somente como reconciliação',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../aviator.js'),'utf8');
  assert.match(js,/async function applyRealtimeSnapshot\(x\)/);
  assert.match(js,/startRealtime\(\)/);
  assert.match(js,/scheduleState\(connected\?30000:2000\)/);
  assert.match(js,/syncServerClock\(x\)/);
});
