'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');

test('manutencao desacelera polling sem afetar voo protegido',()=>{
  const js=fs.readFileSync('aviator.js','utf8');

  assert.match(js,/const protectedFlight=!enabled&&round\?\.status==='FLYING'&&Boolean\(myBet\)/);
  assert.match(js,/if\(!enabled&&!protectedFlight\)/);
  assert.match(js,/return document\.hidden\?30000:10000/);
  assert.match(js,/return runtime\.pollDelay\(round\?\.status\|\|'',document\.hidden\)/);
});

test('mudanca de visibilidade volta a usar o calculo central de polling',()=>{
  const js=fs.readFileSync('aviator.js','utf8');
  const block=js.match(/document\.addEventListener\('visibilitychange',[\s\S]*?\n}\);/)?.[0]||'';
  assert.match(block,/if\(!document\.hidden\)[\s\S]*?state\(\)/);
  assert.match(block,/scheduleState\(\)/);
  assert.doesNotMatch(block,/scheduleState\(5000\)/);
});
