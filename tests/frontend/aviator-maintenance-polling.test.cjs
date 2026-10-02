'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('Realtime mantém fallback de segurança sem perder a janela de aposta',()=>{
  const js=fs.readFileSync('aviator.js','utf8');
  const runtime=fs.readFileSync('js/aviator/runtime.js','utf8');

  assert.match(js,/realtimeConnected/);
  assert.match(js,/return engine\.pollDelay\(/);
  assert.match(js,/if\(connected\)[\s\S]*?scheduleState\(\)/);
  assert.match(runtime,/if\(status==='OPEN'\)return 750/);
  assert.match(runtime,/if\(status==='CRASHED'\|\|status==='SETTLED'\|\|!status\)return 750/);
});

test('mudança de visibilidade força reconciliação sem reativar polling agressivo',()=>{
  const js=fs.readFileSync('aviator.js','utf8');
  const block=js.match(/document\.addEventListener\('visibilitychange',[\s\S]*?\n\}\);/)?.[0]||'';
  assert.match(block,/if\(!document\.hidden\)[\s\S]*?reconnectState\(\)/);
  assert.match(block,/scheduleState\(\)/);
  assert.doesNotMatch(block,/scheduleState\(500|scheduleState\(1000/);
});
