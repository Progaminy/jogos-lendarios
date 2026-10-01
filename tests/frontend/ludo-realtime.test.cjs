'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

test('Ludo usa Broadcast por sala e não Postgres Changes',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../js/realtime/ludo.js'),'utf8');
  assert.match(js,/channel\(\`ludo:room:\$\{id\}\`/);
  assert.match(js,/\.on\('broadcast',\{event:'sync'\}/);
  assert.doesNotMatch(js,/postgres_changes/);
});

test('SDK e módulo Realtime carregam antes do controlador do Ludo',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../ludo.html'),'utf8');
  const sdk=html.indexOf('@supabase/supabase-js@2.117.2/dist/umd/supabase.min.js');
  const realtime=html.indexOf('./js/realtime/ludo.js');
  const controller=html.indexOf('./ludo.js');
  assert.ok(sdk>=0);
  assert.ok(realtime>sdk);
  assert.ok(controller>realtime);
});

test('Ludo reduz polling quando Realtime está conectado',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../ludo.js'),'utf8');
  assert.match(js,/ludoRealtimeConnected\?15000:3000/);
  assert.match(js,/JLLudoRealtime\.connect/);
  assert.match(js,/JLLudoSync\?\.kick\?\.\('ludo-state'\)/);
});

test('Realtime é apenas gatilho para buscar estado autoritativo',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../ludo.js'),'utf8');
  assert.match(js,/loadRoomSnapshot\(nextStatus\.active_room_id,state\.room\)/);
  assert.doesNotMatch(
    fs.readFileSync(path.join(__dirname,'../../js/realtime/ludo.js'),'utf8'),
    /players|tokens|balance|stake_amount/
  );
});

test('resultado do dado do adversario chega sem esperar polling',()=>{
  const realtime=fs.readFileSync(path.join(__dirname,'../../js/realtime/ludo.js'),'utf8');
  const controller=fs.readFileSync(path.join(__dirname,'../../ludo.js'),'utf8');
  assert.match(realtime,/payload\?\.kind==='dice_rolled'/);
  assert.match(realtime,/handlers\.onSignal\?\.\(payload\)/);
  assert.match(controller,/onSignal:\(p\)=>\{showRealtimeDice\(p,id\);queueLudoRealtimeRefresh\(\);\}/);
  assert.match(controller,/function showRealtimeDice\(p,id\)/);
  assert.match(controller,/renderDiceFace\(n\);playDiceLanding\(\)/);
  assert.match(controller,/moveHint\.textContent=.*tirou/);
});
