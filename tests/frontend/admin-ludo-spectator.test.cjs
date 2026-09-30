'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

test('admin tem botão Assistir em cada partida ativa',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../admin-ludo-emergency.js'),'utf8');
  assert.match(js,/data-watch-ludo-room/);
  assert.match(js,/>Assistir</);
});

test('espectador usa snapshot administrativo somente-leitura',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../admin-ludo-spectator.js'),'utf8');
  assert.match(js,/jl_admin_ludo_watch_room/);
  assert.match(js,/JLLudoRealtime\.connect/);
  assert.doesNotMatch(js,/jl_ludo_move|jl_ludo_roll|jl_ludo_choose_color|jl_ludo_commit_stake/);
});

test('Realtime é principal e polling vira reconciliação',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../admin-ludo-spectator.js'),'utf8');
  assert.match(js,/realtimeConnected\?15000:3000/);
  assert.match(js,/onSignal:\(\)=>\{void refresh\(true\);\}/);
});

test('admin carrega SDK, realtime e espectador',()=>{
  const html=fs.readFileSync(path.join(__dirname,'../../admin.html'),'utf8');
  const sdk=html.indexOf('@supabase/supabase-js@2.117.2/dist/umd/supabase.min.js');
  const rt=html.indexOf('./js/realtime/ludo.js');
  const spectator=html.indexOf('./admin-ludo-spectator.js');
  assert.ok(sdk>=0);
  assert.ok(rt>sdk);
  assert.ok(spectator>rt);
});
