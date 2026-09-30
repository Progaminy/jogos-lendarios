'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('Realtime reduz polling do Aviator a fallback de segurança',()=>{
  const js=fs.readFileSync('aviator.js','utf8');

  assert.match(js,/realtimeConnected/);
  assert.match(js,/return runtime\.pollDelay\(round\?\.status\|\|'',document\.hidden,realtimeConnected\)/);
  assert.match(js,/scheduleState\(connected\?30000:2000\)/);
  assert.match(js,/return document\.hidden\?60000:30000/);
});

test('mudança de visibilidade força reconciliação sem reativar polling agressivo',()=>{
  const js=fs.readFileSync('aviator.js','utf8');
  const block=js.match(/document\.addEventListener\('visibilitychange',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(block,/if\(!document\.hidden\)[\s\S]*?reconnectState\(\)/);
  assert.match(block,/scheduleState\(\)/);
  assert.doesNotMatch(block,/scheduleState\(500|scheduleState\(1000/);
});
